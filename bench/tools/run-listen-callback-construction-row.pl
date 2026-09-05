#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX qw(_exit);
use Socket qw(AF_INET SOCK_STREAM SOCK_CLOEXEC inet_aton pack_sockaddr_in);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);

use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Loop;

my $style;
my $clients;
my $connections;
my $repeats = 1;
my $timeout = 30;
my $json_path;

GetOptions(
    'accepted-callbacks=s' => \$style,
    'clients=i'            => \$clients,
    'connections=i'        => \$connections,
    'repeats=i'            => \$repeats,
    'timeout=f'            => \$timeout,
    'json=s'               => \$json_path,
) or die "invalid options\n";

die "accepted-callbacks must be one callback style\n"
    if !defined($style)
    || $style !~ /\A(?:subclass_method|shared_closure|fresh_closure)\z/;
die "clients must be positive\n" if !defined($clients) || $clients < 1;
die "connections must be positive\n"
    if !defined($connections) || $connections < 1;
die "clients must not exceed connections\n" if $clients > $connections;
die "row runner requires repeats=1\n" if $repeats != 1;
die "timeout must be positive\n" if $timeout <= 0;
die "json path is required\n" if !defined($json_path) || $json_path eq '';

{
    package BenchAcceptedRowBase;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) { }

    sub on_error ($stream, $error) {
        die "accepted Stream failed: $error\n";
    }
}

{
    package BenchAcceptedRowSubclass;
    use parent -norequire, 'BenchAcceptedRowBase';
}

{
    package BenchAcceptedRowSharedClosure;
    use parent -norequire, 'BenchAcceptedRowBase';

    my $marker = 1;
    my $callback = sub ($stream, $bytes) {
        $marker += length($bytes) if $bytes eq '';
        return;
    };

    sub new ($class, %opt) {
        return $class->SUPER::new(%opt, on_data => $callback);
    }
}

{
    package BenchAcceptedRowFreshClosure;
    use parent -norequire, 'BenchAcceptedRowBase';

    our $CLOSURES_CREATED = 0;

    sub new ($class, %opt) {
        my $marker = ++$CLOSURES_CREATED;
        my $callback = sub ($stream, $bytes) {
            $marker += length($bytes) if $bytes eq '';
            return;
        };
        return $class->SUPER::new(%opt, on_data => $callback);
    }
}

{
    package BenchAcceptedRowListener;
    use parent 'Linux::Event::IO::Sock::Listener';

    sub on_accept ($listener, $stream) {
        my $run = $listener->data;
        $run->{accepted}++;
        $stream->close;
        $run->{loop}->stop if $run->{accepted} == $run->{connections};
        return;
    }

    sub on_error ($listener, $error) {
        die "benchmark listener failed: $error\n";
    }
}

sub stream_class ($name) {
    return 'BenchAcceptedRowSubclass' if $name eq 'subclass_method';
    return 'BenchAcceptedRowSharedClosure' if $name eq 'shared_closure';
    return 'BenchAcceptedRowFreshClosure';
}

sub spawn_workers ($port, $worker_count, $total) {
    pipe(my $gate_read, my $gate_write) or die "client gate pipe: $!\n";
    my @pid;
    my $base = int($total / $worker_count);
    my $extra = $total % $worker_count;

    for my $worker (0 .. $worker_count - 1) {
        my $count = $base + ($worker < $extra ? 1 : 0);
        my $pid = fork();
        die "client worker fork: $!\n" if !defined $pid;
        if ($pid == 0) {
            close $gate_write;
            my $gate = '';
            my $n;
            do {
                $n = sysread($gate_read, $gate, 1);
            } while (!defined($n) && $!{EINTR});
            _exit(2) if !defined($n) || $n != 1;
            close $gate_read;

            my $ok = eval {
                run_clients($port, $count);
                1;
            };
            warn $@ if !$ok;
            _exit($ok ? 0 : 3);
        }
        push @pid, $pid;
    }

    close $gate_read;
    return ($gate_write, \@pid);
}

sub release_workers ($gate_write, $worker_count) {
    my $signal = 'g' x $worker_count;
    my $offset = 0;
    while ($offset < length($signal)) {
        my $n = syswrite(
            $gate_write, $signal, length($signal) - $offset, $offset,
        );
        next if !defined($n) && $!{EINTR};
        die "release workers: $!\n" if !defined $n;
        die "release workers wrote zero bytes\n" if $n == 0;
        $offset += $n;
    }
    close $gate_write;
    return;
}

sub run_clients ($port, $count) {
    my $address = pack_sockaddr_in($port, inet_aton('127.0.0.1'));
    for (1 .. $count) {
        socket(my $client, AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
            or die "client socket: $!\n";

        my $connected;
        do {
            $connected = connect($client, $address);
        } while (!$connected && $!{EINTR});
        die "client connect: $!\n" if !$connected;

        my $buffer;
        while (1) {
            my $n = sysread($client, $buffer, 1);
            next if !defined($n) && $!{EINTR};
            die "client read: $!\n" if !defined $n;
            last if $n == 0;
        }
        close $client or die "client close: $!\n";
    }
    return;
}

sub stop_workers ($pids) {
    kill 'TERM', @$pids if @$pids;
    waitpid($_, 0) for @$pids;
    return;
}

sub wait_workers ($pids) {
    for my $pid (@$pids) {
        waitpid($pid, 0);
        die "client worker $pid failed with status $?\n" if $? != 0;
    }
    return;
}

my $loop = Linux::Event::Loop->new;
$loop->enable_watcher_reclaim(1);
my $run = {
    loop => $loop,
    accepted => 0,
    connections => $connections,
};

my $listener = BenchAcceptedRowListener->new(
    stream_class => stream_class($style),
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    data => $run,
    max_accept_per_tick => 0,
);

my $fresh_before = $BenchAcceptedRowFreshClosure::CLOSURES_CREATED;
my ($gate_write, $pids) = spawn_workers($listener->port, $clients, $connections);

my $wall_start = clock_gettime(CLOCK_MONOTONIC);
my $cpu_start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
release_workers($gate_write, $clients);

local $SIG{ALRM} = sub { die "accepted callback row timed out\n" };
alarm $timeout;
my $ok = eval {
    $loop->run;
    1;
};
my $error = $@;
alarm 0;

my $cpu_end = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
my $wall_end = clock_gettime(CLOCK_MONOTONIC);

if (!$ok) {
    stop_workers($pids);
    $listener->close;
    die $error;
}

wait_workers($pids);
$listener->close;

die "accepted $run->{accepted} of $connections connections\n"
    if $run->{accepted} != $connections;

my $fresh_created =
    $BenchAcceptedRowFreshClosure::CLOSURES_CREATED - $fresh_before;
if ($style eq 'fresh_closure') {
    die "fresh closure count is $fresh_created, expected $connections\n"
        if $fresh_created != $connections;
} else {
    die "$style unexpectedly created $fresh_created fresh closures\n"
        if $fresh_created;
}

my $elapsed = $wall_end - $wall_start;
my $cpu = $cpu_end - $cpu_start;
my $row = {
    callback_style => $style,
    clients => $clients,
    accepted => $run->{accepted},
    elapsed_seconds => 0 + $elapsed,
    accepts_per_second => $connections / $elapsed,
    parent_cpu_seconds => 0 + $cpu,
    parent_cpu_us_per_accept => $cpu * 1_000_000 / $connections,
    fresh_closures_created => $fresh_created,
};

my $report = {
    benchmark => 'linux-event-accepted-stream-callback-construction',
    benchmark_contract_version => 1,
    configuration => {
        callback_styles => [$style],
        clients => [$clients],
        connections => $connections,
        repeats => 1,
        timeout => 0 + $timeout,
        client_processes => 1,
        parent_cpu_excludes_client_workers => 1,
        completion_event => 'listener_on_accept',
        clients_wait_for_server_close => 1,
    },
    raw => [$row],
    summary => [],
};

open my $json, '>', $json_path or die "open $json_path: $!\n";
print {$json} JSON::PP->new->canonical->pretty->encode($report);
close $json or die "close $json_path: $!\n";

exit 0;
