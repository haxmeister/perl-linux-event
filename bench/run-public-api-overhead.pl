#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);

use lib "$Bin/../blib/lib", "$Bin/../blib/arch", "$Bin/../lib";

require Linux::Event::Loop;
require Linux::Event::Stream;
require Linux::Event::Socket;
require Linux::Event::Timer;
require Linux::Event::IO::Pipe;
require Linux::Event::IO::Sock::Stream;
require Linux::Event::Kernel::Timer;

my $repeats = 5;
my $lifecycle_iterations = 50_000;
my $pool_size = 128;
my $clients = 16;
my @payload_sizes = (64, 4096, 65_536, 200_000);
my $target_bytes = 16 * 1024 * 1024;
my $threshold_percent = 10;
my $json_path = 'bench/results/public-api-overhead.json';
my $fail_on_regression = 0;

GetOptions(
    'repeats=i' => \$repeats,
    'lifecycle-iterations=i' => \$lifecycle_iterations,
    'pool-size=i' => \$pool_size,
    'clients=i' => \$clients,
    'payload-sizes=s' => sub { @payload_sizes = split /,/, $_[1] },
    'target-bytes=i' => \$target_bytes,
    'threshold-percent=f' => \$threshold_percent,
    'json=s' => \$json_path,
    'fail-on-regression!' => \$fail_on_regression,
) or die "invalid options\n";

die "repeats must be positive\n" if $repeats < 1;
die "lifecycle-iterations must be positive\n" if $lifecycle_iterations < 1;
die "pool-size must be positive\n" if $pool_size < 1;
die "clients must be positive\n" if $clients < 1;
die "target-bytes must be positive\n" if $target_bytes < 1;
die "payload sizes must be positive\n" if grep { $_ < 1 } @payload_sizes;

{
    package Linux::Event::Bench::PublicAPI::OldSocket;
    use parent -norequire, 'Linux::Event::Socket';
    sub on_data ($self, $bytes) { $self->write($bytes) }
    sub on_error ($self, $error) { die "old socket: $error\n" }
}
{
    package Linux::Event::Bench::PublicAPI::NewSocket;
    use parent -norequire, 'Linux::Event::IO::Sock::Stream';
    sub on_data ($self, $bytes) { $self->write($bytes) }
    sub on_error ($self, $error) { die "new socket: $error\n" }
}
{
    package Linux::Event::Bench::PublicAPI::OldPipe;
    use parent -norequire, 'Linux::Event::Stream';
    sub on_data ($self, $bytes) { return }
}
{
    package Linux::Event::Bench::PublicAPI::OldValidatedPipe;
    use parent -norequire, 'Linux::Event::Stream';
    sub on_data ($self, $bytes) { return }
    sub new ($class, %option) {
        my @handle = defined($option{fh})
            ? ($option{fh})
            : grep { defined } @option{qw(read_fh write_fh)};
        my %seen;
        for my $fh (@handle) {
            my $fd = fileno($fh);
            next if defined($fd) && $seen{$fd}++;
            die "benchmark expected a pipe or FIFO\n"
                if !defined fcntl($fh, 1032, 0);
        }
        return $class->SUPER::new(%option);
    }
}
{
    package Linux::Event::Bench::PublicAPI::NewPipe;
    use parent -norequire, 'Linux::Event::IO::Pipe';
    sub on_data ($self, $bytes) { return }
}
{
    package Linux::Event::Bench::PublicAPI::OldTimer;
    use parent -norequire, 'Linux::Event::Timer';
    sub on_timer ($self) { return }
}
{
    package Linux::Event::Bench::PublicAPI::NewTimer;
    use parent -norequire, 'Linux::Event::Kernel::Timer';
    sub on_timer ($self) { return }
}

my @comparison;
my @diagnostic;

run_pair(
    'socket-stream-lifecycle',
    sub { socket_lifecycle('Linux::Event::Bench::PublicAPI::OldSocket') },
    sub { socket_lifecycle('Linux::Event::Bench::PublicAPI::NewSocket') },
);
run_pair(
    'pipe-lifecycle-equivalent-validation',
    sub { pipe_lifecycle('Linux::Event::Bench::PublicAPI::OldValidatedPipe') },
    sub { pipe_lifecycle('Linux::Event::Bench::PublicAPI::NewPipe') },
);
run_diagnostic_pair(
    'pipe-resource-validation-cost',
    sub { pipe_lifecycle('Linux::Event::Bench::PublicAPI::OldPipe') },
    sub { pipe_lifecycle('Linux::Event::Bench::PublicAPI::OldValidatedPipe') },
);
run_pair(
    'timer-lifecycle',
    sub { timer_lifecycle('Linux::Event::Bench::PublicAPI::OldTimer') },
    sub { timer_lifecycle('Linux::Event::Bench::PublicAPI::NewTimer') },
);

for my $size (@payload_sizes) {
    run_pair(
        "socket-stream-throughput-$size",
        sub { stream_throughput('Linux::Event::Bench::PublicAPI::OldSocket', $size) },
        sub { stream_throughput('Linux::Event::Bench::PublicAPI::NewSocket', $size) },
    );
}

my $regressions = grep { $_->{regression} } @comparison;
my $report = {
    benchmark => 'linux-event-public-api-overhead',
    baseline_surface => 'historical implementation classes',
    candidate_surface => 'IO/Kernel public leaves',
    configuration => {
        repeats => $repeats,
        lifecycle_iterations => $lifecycle_iterations,
        pool_size => $pool_size,
        clients => $clients,
        payload_sizes => \@payload_sizes,
        target_bytes => $target_bytes,
        threshold_percent => $threshold_percent,
    },
    comparisons => \@comparison,
    diagnostics => \@diagnostic,
    regressions => 0 + $regressions,
};

if ($json_path ne '') {
    my ($dir) = $json_path =~ m{\A(.+)/[^/]+\z};
    if ($dir && !-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }
    open my $fh, '>:raw', $json_path or die "open $json_path: $!\n";
    print {$fh} JSON::PP->new->canonical->pretty->encode($report);
    close $fh or die "close $json_path: $!\n";
}

exit 2 if $fail_on_regression && $regressions;
exit 0;

sub run_pair ($name, $old_code, $new_code) {
    my (@old, @new);
    for my $repeat (1 .. $repeats) {
        my @order = $repeat % 2
            ? ([old => $old_code, \@old], [new => $new_code, \@new])
            : ([new => $new_code, \@new], [old => $old_code, \@old]);
        for my $entry (@order) {
            my ($label, $code, $target) = @$entry;
            my $row = $code->();
            push @$target, $row;
            printf "%-38s %-3s repeat=%d %12.1f op/s cpu=%9.3f us/op\n",
                $name, $label, $repeat,
                $row->{operations_per_second}, $row->{cpu_us_per_operation};
        }
    }

    my $old_rate = median(map { $_->{operations_per_second} } @old);
    my $new_rate = median(map { $_->{operations_per_second} } @new);
    my $old_cpu = median(map { $_->{cpu_us_per_operation} } @old);
    my $new_cpu = median(map { $_->{cpu_us_per_operation} } @new);
    my $rate_delta = percent_delta($new_rate, $old_rate);
    my $cpu_delta = percent_delta($new_cpu, $old_cpu);
    my $regression = $rate_delta <= -$threshold_percent
        || $cpu_delta >= $threshold_percent;

    printf "%-38s rate=%+7.2f%% cpu=%+7.2f%% %s\n",
        $name, $rate_delta, $cpu_delta, $regression ? 'REGRESSION' : 'ok';

    push @comparison, {
        workload => $name,
        old_operations_per_second => $old_rate,
        new_operations_per_second => $new_rate,
        rate_delta_percent => $rate_delta,
        old_cpu_us_per_operation => $old_cpu,
        new_cpu_us_per_operation => $new_cpu,
        cpu_delta_percent => $cpu_delta,
        regression => $regression ? JSON::PP::true : JSON::PP::false,
        old_records => \@old,
        new_records => \@new,
    };
}

sub run_diagnostic_pair ($name, $without_code, $with_code) {
    my (@without, @with);
    for my $repeat (1 .. $repeats) {
        my @order = $repeat % 2
            ? ([plain => $without_code, \@without], [validated => $with_code, \@with])
            : ([validated => $with_code, \@with], [plain => $without_code, \@without]);
        for my $entry (@order) {
            my ($label, $code, $target) = @$entry;
            my $row = $code->();
            push @$target, $row;
            printf "%-38s %-9s repeat=%d %12.1f op/s cpu=%9.3f us/op\n",
                $name, $label, $repeat,
                $row->{operations_per_second}, $row->{cpu_us_per_operation};
        }
    }

    my $without_rate = median(map { $_->{operations_per_second} } @without);
    my $with_rate = median(map { $_->{operations_per_second} } @with);
    my $without_cpu = median(map { $_->{cpu_us_per_operation} } @without);
    my $with_cpu = median(map { $_->{cpu_us_per_operation} } @with);
    my $rate_delta = percent_delta($with_rate, $without_rate);
    my $cpu_delta = percent_delta($with_cpu, $without_cpu);

    printf "%-38s rate=%+7.2f%% cpu=%+7.2f%% diagnostic\n",
        $name, $rate_delta, $cpu_delta;

    push @diagnostic, {
        workload => $name,
        without_validation_operations_per_second => $without_rate,
        with_validation_operations_per_second => $with_rate,
        rate_delta_percent => $rate_delta,
        without_validation_cpu_us_per_operation => $without_cpu,
        with_validation_cpu_us_per_operation => $with_cpu,
        cpu_delta_percent => $cpu_delta,
        without_validation_records => \@without,
        with_validation_records => \@with,
    };
}

sub socket_lifecycle ($class) {
    my $loop = Linux::Event::Loop->new;
    my ($server, $client) = socket_pool($pool_size);
    socket_churn($loop, $class, $server, 1_000);
    my ($wall, $cpu) = timed(sub {
        socket_churn($loop, $class, $server, $lifecycle_iterations);
    });
    close $_ for @$server, @$client;
    return measurement($lifecycle_iterations, $wall, $cpu);
}

sub socket_churn ($loop, $class, $handles, $count) {
    for my $i (0 .. $count - 1) {
        my $stream = $class->new(fh => $handles->[$i % @$handles]);
        $loop->add($stream);
        $stream->detach;
    }
}

sub pipe_lifecycle ($class) {
    my (@read, @write);
    for (1 .. $pool_size) {
        pipe(my $r, my $w) or die "pipe: $!\n";
        push @read, $r;
        push @write, $w;
    }
    my $loop = Linux::Event::Loop->new;
    pipe_churn($loop, $class, \@read, 1_000);
    my ($wall, $cpu) = timed(sub {
        pipe_churn($loop, $class, \@read, $lifecycle_iterations);
    });
    close $_ for @read, @write;
    return measurement($lifecycle_iterations, $wall, $cpu);
}

sub pipe_churn ($loop, $class, $handles, $count) {
    for my $i (0 .. $count - 1) {
        my $stream = $class->new(read_fh => $handles->[$i % @$handles]);
        $loop->add($stream);
        $stream->detach;
    }
}

sub timer_lifecycle ($class) {
    my $loop = Linux::Event::Loop->new;
    timer_churn($loop, $class, 1_000);
    my ($wall, $cpu) = timed(sub {
        timer_churn($loop, $class, $lifecycle_iterations);
    });
    return measurement($lifecycle_iterations, $wall, $cpu);
}

sub timer_churn ($loop, $class, $count) {
    for (1 .. $count) {
        my $timer = $loop->add($class->new(after => 3_600));
        $timer->cancel;
    }
}

sub socket_pool ($count) {
    my (@server, @client);
    for (1 .. $count) {
        socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
            or die "socketpair: $!\n";
        push @server, $a;
        push @client, $b;
    }
    return (\@server, \@client);
}

sub stream_throughput ($class, $payload_size) {
    my $loop = Linux::Event::Loop->new;
    my $payload = 'x' x $payload_size;
    my $messages_per_client = int($target_bytes / ($payload_size * $clients));
    $messages_per_client = 4 if $messages_per_client < 4;
    my $warmup = $messages_per_client > 100 ? 100 : 2;
    my $bench = {
        loop => $loop,
        payload => $payload,
        payload_size => $payload_size,
        messages => $messages_per_client,
        warmup => $warmup,
        clients => $clients,
        phase => 'warmup',
        warmup_done => 0,
        measured_done => 0,
        states => [],
        streams => [],
        registrations => [],
        peers => [],
    };

    for (1 .. $clients) {
        socketpair(my $server, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
            or die "socketpair: $!\n";
        my $stream = $class->new(loop => $loop, fh => $server);
        my $state = {
            bench => $bench,
            fh => $peer,
            received => 0,
            completed => 0,
        };
        my $registration = $loop->watch(
            fh => $peer,
            data => $state,
            read => \&peer_read,
        );
        push @{ $bench->{streams} }, $stream;
        push @{ $bench->{registrations} }, $registration;
        push @{ $bench->{states} }, $state;
        push @{ $bench->{peers} }, $peer;
    }

    send_payload($_) for @{ $bench->{states} };
    $loop->run;

    my $operations = $clients * $messages_per_client;
    my $wall = $bench->{wall_end} - $bench->{wall_start};
    my $cpu = $bench->{cpu_end} - $bench->{cpu_start};
    $_->cancel for @{ $bench->{registrations} };
    $_->close for @{ $bench->{streams} };
    close $_ for @{ $bench->{peers} };
    return measurement($operations, $wall, $cpu);
}

sub peer_read ($registration) {
    my $state = $registration->data;
    my $bench = $state->{bench};
    my $read = sysread($state->{fh}, my $chunk, 262_144);
    die "peer read: $!\n" if !defined $read;
    die "peer closed early\n" if !$read;
    $state->{received} += $read;
    die "echo exceeded payload boundary\n"
        if $state->{received} > $bench->{payload_size};
    return if $state->{received} < $bench->{payload_size};

    $state->{received} = 0;
    $state->{completed}++;

    if ($bench->{phase} eq 'warmup') {
        if ($state->{completed} == $bench->{warmup}) {
            $bench->{warmup_done}++;
            begin_measurement($bench) if $bench->{warmup_done} == $bench->{clients};
        } else {
            send_payload($state);
        }
        return;
    }

    if ($state->{completed} == $bench->{messages}) {
        $bench->{measured_done}++;
        if ($bench->{measured_done} == $bench->{clients}) {
            $bench->{wall_end} = clock_gettime(CLOCK_MONOTONIC);
            $bench->{cpu_end} = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
            $bench->{loop}->stop;
        }
    } else {
        send_payload($state);
    }
}

sub begin_measurement ($bench) {
    $bench->{phase} = 'measure';
    $bench->{measured_done} = 0;
    $_->{completed} = 0 for @{ $bench->{states} };
    $bench->{wall_start} = clock_gettime(CLOCK_MONOTONIC);
    $bench->{cpu_start} = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    send_payload($_) for @{ $bench->{states} };
}

sub send_payload ($state) {
    my $payload = $state->{bench}{payload};
    my $offset = 0;
    while ($offset < length($payload)) {
        my $written = syswrite($state->{fh}, $payload, length($payload) - $offset, $offset);
        die "peer write: $!\n" if !defined $written;
        $offset += $written;
    }
}

sub timed ($code) {
    my $wall_start = clock_gettime(CLOCK_MONOTONIC);
    my $cpu_start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    $code->();
    return (
        clock_gettime(CLOCK_MONOTONIC) - $wall_start,
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID) - $cpu_start,
    );
}

sub measurement ($operations, $wall, $cpu) {
    return {
        operations => $operations,
        wall_seconds => $wall,
        cpu_seconds => $cpu,
        operations_per_second => $operations / $wall,
        cpu_us_per_operation => ($cpu * 1_000_000) / $operations,
    };
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    return $values[int(@values / 2)] if @values % 2;
    return ($values[@values / 2 - 1] + $values[@values / 2]) / 2;
}

sub percent_delta ($candidate, $baseline) {
    return (($candidate / $baseline) - 1) * 100;
}
