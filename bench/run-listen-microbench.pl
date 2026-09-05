#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX qw(_exit);
use Socket qw(
    AF_INET INADDR_LOOPBACK
    SOCK_STREAM SOCK_NONBLOCK SOCK_CLOEXEC
    SOL_SOCKET SO_LINGER SO_REUSEADDR
    inet_aton pack_sockaddr_in unpack_sockaddr_in
);
use Time::HiRes qw(
    clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID
);

use Linux::Event::IO::Sock::Stream;
use Linux::Event::IO::Sock::Listener;
use Linux::Event::Loop;

my @modes = qw(manual add loop);
my @clients = (1, 10, 100);
my $connections = 10_000;
my $repeats = 9;
my $timeout = 30;
my $accepted_callback_spec;
my $json_path;
my $help = 0;

GetOptions(
    'modes=s'              => sub { @modes = split /,/, $_[1] },
    'clients=s'            => sub { @clients = map { 0 + $_ } split /,/, $_[1] },
    'connections=i'        => \$connections,
    'repeats=i'            => \$repeats,
    'timeout=f'            => \$timeout,
    'accepted-callbacks=s' => \$accepted_callback_spec,
    'json=s'               => \$json_path,
    'help'                 => \$help,
) or usage(1);
usage(0) if $help;

die "connections must be positive\n" if $connections < 1;
die "repeats must be positive\n" if $repeats < 1;
die "timeout must be positive\n" if $timeout <= 0;
die "clients must be positive\n" if grep { $_ < 1 } @clients;

my %valid_mode = map { $_ => 1 } qw(manual add loop);
die "modes must contain only manual, add, or loop\n"
    if grep { !$valid_mode{$_} } @modes;
my %seen_mode;
die "modes must not contain duplicates\n"
    if grep { $seen_mode{$_}++ } @modes;

my @accepted_callbacks;
if (defined $accepted_callback_spec) {
    @accepted_callbacks = $accepted_callback_spec eq 'all'
        ? qw(subclass_method shared_closure fresh_closure)
        : split /,/, $accepted_callback_spec;
    my %valid = map { $_ => 1 }
        qw(subclass_method shared_closure fresh_closure);
    die "accepted-callbacks must contain subclass_method, shared_closure, "
        . "fresh_closure, or all\n"
        if !@accepted_callbacks || grep { !$valid{$_} } @accepted_callbacks;
    my %seen;
    die "accepted-callbacks must not contain duplicates\n"
        if grep { $seen{$_}++ } @accepted_callbacks;
    die "callback construction benchmark requires clients <= connections\n"
        if grep { $_ > $connections } @clients;
} elsif (defined $json_path) {
    die "--json is valid only with --accepted-callbacks\n";
}

{
    package BenchAutomaticStream;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) { }

    sub on_ready ($stream) {
        my $run = $stream->data;
        $stream->close;
        $run->{accepted}++;
        main::finish_if_done($run);
    }
}

{
    package BenchAutomaticListener;
    use parent 'Linux::Event::IO::Sock::Listener';

    sub on_error ($listener, $error) {
        die "benchmark listener failed: $error\n";
    }
}

{
    package BenchListenClient;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) { }

    sub on_ready ($stream) {
        my $run = $stream->data;
        main::enable_abortive_close($stream->fh, 'client');
        $stream->close;
        $run->{active}--;
        $run->{completed}++;
        main::launch_requests($run);
        main::finish_if_done($run);
    }

    sub on_error ($stream, $error) {
        die "benchmark connection failed: $error\n";
    }
}

{
    package BenchAcceptedBase;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) { }

    sub on_ready ($stream) {
        my $run = $stream->data;
        $stream->close;
        $run->{accepted}++;
        main::finish_callback_if_done($run);
    }

    sub on_error ($stream, $error) {
        die "accepted Stream failed: $error\n";
    }
}

{
    package BenchAcceptedSubclass;
    use parent -norequire, 'BenchAcceptedBase';
}

{
    package BenchAcceptedSharedClosure;
    use parent -norequire, 'BenchAcceptedBase';

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
    package BenchAcceptedFreshClosure;
    use parent -norequire, 'BenchAcceptedBase';

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

sub enable_abortive_close ($fh, $role) {
    setsockopt($fh, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0))
        or die "$role SO_LINGER: $!\n";
    return;
}

sub finish_if_done ($run) {
    $run->{loop}->stop
        if $run->{accepted} == $run->{connections}
            && $run->{completed} == $run->{connections};
    return;
}

sub finish_callback_if_done ($run) {
    $run->{loop}->stop if $run->{accepted} == $run->{connections};
    return;
}

sub manual_accept_ready ($registration) {
    my $run = $registration->data;
    while (accept(my $client, $run->{listener_fh})) {
        close $client;
        $run->{accepted}++;
    }
    die "manual accept failed: $!\n"
        if !$!{EAGAIN} && !$!{EWOULDBLOCK};
    finish_if_done($run);
    return;
}

sub launch_requests ($run) {
    while ($run->{active} < $run->{clients}
        && $run->{started} < $run->{connections}) {
        $run->{started}++;
        $run->{active}++;
        BenchListenClient->connect(
            loop    => $run->{loop},
            host    => '127.0.0.1',
            port    => $run->{port},
            timeout => $timeout,
            data    => $run,
        );
    }
    return;
}

sub one_run ($mode, $client_count) {
    my $loop = Linux::Event::Loop->new;
    $loop->enable_watcher_reclaim(1);
    my $run = {
        mode        => $mode,
        clients     => $client_count,
        connections => $connections,
        loop        => $loop,
        started     => 0,
        active      => 0,
        completed   => 0,
        accepted    => 0,
    };
    if ($mode eq 'manual') {
        socket(my $listener, AF_INET,
            SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)
            or die "manual listener socket: $!\n";
        setsockopt($listener, SOL_SOCKET, SO_REUSEADDR, pack('i', 1))
            or die "manual listener setsockopt: $!\n";
        bind($listener, pack_sockaddr_in(0, INADDR_LOOPBACK))
            or die "manual listener bind: $!\n";
        listen($listener, 4096) or die "manual listener listen: $!\n";
        ($run->{port}) = unpack_sockaddr_in(getsockname($listener));
        $run->{listener_fh} = $listener;
        $run->{listener_watcher} = $loop->watch(
            fh   => $listener,
            data => $run,
            read => \&manual_accept_ready,
        );
    } elsif ($mode eq 'add') {
        $run->{listener} = BenchAutomaticListener->new(
            stream_class => 'BenchAutomaticStream',
            host => '127.0.0.1', port => 0, data => $run,
        );
        $loop->add($run->{listener});
        $run->{port} = $run->{listener}->port;
    } else {
        $run->{listener} = BenchAutomaticListener->new(
            stream_class => 'BenchAutomaticStream',
            loop => $loop, host => '127.0.0.1', port => 0, data => $run,
        );
        $run->{port} = $run->{listener}->port;
    }

    my $wall_start = clock_gettime(CLOCK_MONOTONIC);
    my ($user_start, $system_start) = (times)[0, 1];
    launch_requests($run);
    $loop->run;
    my ($user_end, $system_end) = (times)[0, 1];
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $wall_start;
    my $cpu = ($user_end - $user_start) + ($system_end - $system_start);

    if ($mode eq 'manual') {
        $run->{listener_watcher}->cancel;
        close $run->{listener_fh};
    } else {
        $run->{listener}->close;
    }
    return {
        rate   => $connections / $elapsed,
        cpu_us => $cpu * 1_000_000 / $connections,
    };
}

sub callback_stream_class ($style) {
    return 'BenchAcceptedSubclass' if $style eq 'subclass_method';
    return 'BenchAcceptedSharedClosure' if $style eq 'shared_closure';
    return 'BenchAcceptedFreshClosure';
}

sub spawn_client_workers ($port, $worker_count, $total) {
    pipe(my $gate_read, my $gate_write) or die "client gate pipe: $!\n";
    my @pids;
    my $base = int($total / $worker_count);
    my $extra = $total % $worker_count;

    for my $worker (0 .. $worker_count - 1) {
        my $count = $base + ($worker < $extra ? 1 : 0);
        my $pid = fork();
        die "client worker fork: $!\n" if !defined $pid;
        if ($pid == 0) {
            close $gate_write;
            my $gate = '';
            my $read;
            do {
                $read = sysread($gate_read, $gate, 1);
            } while (!defined($read) && $!{EINTR});
            if (!defined($read) || $read != 1) {
                _exit(2);
            }
            close $gate_read;
            my $ok = eval {
                run_blocking_clients($port, $count);
                1;
            };
            warn $@ if !$ok;
            _exit($ok ? 0 : 3);
        }
        push @pids, $pid;
    }

    close $gate_read;
    return ($gate_write, \@pids);
}

sub release_client_workers ($gate_write, $worker_count) {
    my $signal = 'g' x $worker_count;
    my $offset = 0;
    while ($offset < length($signal)) {
        my $written = syswrite(
            $gate_write, $signal, length($signal) - $offset, $offset,
        );
        next if !defined($written) && $!{EINTR};
        die "release client workers: $!\n" if !defined $written;
        die "release client workers wrote zero bytes\n" if $written == 0;
        $offset += $written;
    }
    close $gate_write;
    return;
}

sub run_blocking_clients ($port, $count) {
    my $address = pack_sockaddr_in($port, inet_aton('127.0.0.1'));
    for (1 .. $count) {
        socket(my $client, AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
            or die "client worker socket: $!\n";
        enable_abortive_close($client, 'client worker');
        my $connected;
        do {
            $connected = connect($client, $address);
        } while (!$connected && $!{EINTR});
        die "client worker connect: $!\n" if !$connected;
        close $client or die "client worker close: $!\n";
    }
    return;
}

sub stop_client_workers ($pids) {
    kill 'TERM', @$pids if @$pids;
    waitpid($_, 0) for @$pids;
    return;
}

sub wait_client_workers ($pids) {
    for my $pid (@$pids) {
        waitpid($pid, 0);
        die "client worker $pid failed with status $?\n" if $? != 0;
    }
    return;
}

sub one_callback_run ($style, $client_count) {
    my $loop = Linux::Event::Loop->new;
    $loop->enable_watcher_reclaim(1);
    my $run = {
        callback_style => $style,
        clients        => $client_count,
        connections    => $connections,
        loop           => $loop,
        accepted       => 0,
    };
    my $class = callback_stream_class($style);
    my $listener = BenchAutomaticListener->new(
        stream_class => $class,
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        data => $run,
        max_accept_per_tick => 0,
    );
    my $port = $listener->port;
    my $fresh_before = $BenchAcceptedFreshClosure::CLOSURES_CREATED;
    my ($gate_write, $pids) =
        spawn_client_workers($port, $client_count, $connections);

    my $wall_start = clock_gettime(CLOCK_MONOTONIC);
    my $cpu_start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    release_client_workers($gate_write, $client_count);

    local $SIG{ALRM} = sub {
        die "accepted callback construction benchmark timed out\n";
    };
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
        stop_client_workers($pids);
        $listener->close;
        die $error;
    }

    wait_client_workers($pids);
    $listener->close;

    die "accepted $run->{accepted} of $connections connections\n"
        if $run->{accepted} != $connections;
    my $fresh_created =
        $BenchAcceptedFreshClosure::CLOSURES_CREATED - $fresh_before;
    if ($style eq 'fresh_closure') {
        die "fresh closure count is $fresh_created, expected $connections\n"
            if $fresh_created != $connections;
    } else {
        die "$style unexpectedly created $fresh_created fresh closures\n"
            if $fresh_created;
    }

    my $elapsed = $wall_end - $wall_start;
    my $cpu = $cpu_end - $cpu_start;
    return {
        callback_style => $style,
        clients => $client_count,
        accepted => $run->{accepted},
        elapsed_seconds => 0 + $elapsed,
        accepts_per_second => $connections / $elapsed,
        parent_cpu_seconds => 0 + $cpu,
        parent_cpu_us_per_accept => $cpu * 1_000_000 / $connections,
        fresh_closures_created => $fresh_created,
    };
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    my $middle = int(@values / 2);
    return @values % 2
        ? $values[$middle]
        : ($values[$middle - 1] + $values[$middle]) / 2;
}

sub run_standard_benchmark () {
    say 'Median loopback TCP Listener lifecycle benchmark';
    say "Linux::Event version $Linux::Event::IO::Sock::Listener::VERSION";
    printf "%-8s %8s %14s %14s\n",
        qw(mode clients accepts/s cpu_us/accept);
    for my $client_count (@clients) {
        my %result;
        for my $repeat (0 .. $repeats - 1) {
            my $offset = $repeat % @modes;
            my @order =
                (@modes[$offset .. $#modes], @modes[0 .. $offset - 1]);
            push @{ $result{$_} }, one_run($_, $client_count) for @order;
        }
        for my $mode (@modes) {
            printf "%-8s %8d %14.1f %14.3f\n",
                $mode,
                $client_count,
                median(map { $_->{rate} } @{ $result{$mode} }),
                median(map { $_->{cpu_us} } @{ $result{$mode} });
        }
    }
    return;
}

sub run_callback_benchmark () {
    my @raw;
    for my $client_count (@clients) {
        for my $repeat (1 .. $repeats) {
            my $offset = ($repeat - 1) % @accepted_callbacks;
            my @order = (
                @accepted_callbacks[$offset .. $#accepted_callbacks],
                @accepted_callbacks[0 .. $offset - 1],
            );
            for my $style (@order) {
                my $row = one_callback_run($style, $client_count);
                $row->{repeat} = $repeat;
                push @raw, $row;
            }
        }
    }

    my @summary;
    for my $client_count (@clients) {
        my @baseline = grep {
            $_->{callback_style} eq 'subclass_method'
                && $_->{clients} == $client_count
        } @raw;
        for my $style (@accepted_callbacks) {
            my @rows = grep {
                $_->{callback_style} eq $style
                    && $_->{clients} == $client_count
            } @raw;
            my $summary = {
                callback_style => $style,
                clients => $client_count,
                median_accepts_per_second => median(
                    map { $_->{accepts_per_second} } @rows,
                ),
                median_parent_cpu_us_per_accept => median(
                    map { $_->{parent_cpu_us_per_accept} } @rows,
                ),
                median_fresh_closures_created => median(
                    map { $_->{fresh_closures_created} } @rows,
                ),
            };
            if ($style ne 'subclass_method' && @baseline) {
                my (@throughput_delta, @cpu_delta);
                for my $row (@rows) {
                    my ($paired) = grep {
                        $_->{repeat} == $row->{repeat}
                    } @baseline;
                    push @throughput_delta, 100 * (
                        $row->{accepts_per_second}
                            / $paired->{accepts_per_second} - 1
                    );
                    push @cpu_delta, 100 * (
                        $row->{parent_cpu_us_per_accept}
                            / $paired->{parent_cpu_us_per_accept} - 1
                    );
                }
                $summary->{throughput_delta_percent} =
                    median(@throughput_delta);
                $summary->{parent_cpu_delta_percent} =
                    median(@cpu_delta);
            }
            push @summary, $summary;
        }
    }

    say 'Accepted Stream callback construction benchmark';
    say "Linux::Event version $Linux::Event::IO::Sock::Listener::VERSION";
    printf "connections=%d repeats=%d; client workers run in child processes\n",
        $connections, $repeats;
    printf "%-20s %8s %14s %16s %10s %10s\n",
        'callback', 'clients', 'accepts/s', 'parent cpu us', 'speed', 'cpu';
    for my $row (@summary) {
        printf "%-20s %8d %14.1f %16.3f %9s %9s\n",
            $row->{callback_style},
            $row->{clients},
            $row->{median_accepts_per_second},
            $row->{median_parent_cpu_us_per_accept},
            defined($row->{throughput_delta_percent})
                ? sprintf('%+.2f%%', $row->{throughput_delta_percent}) : '-',
            defined($row->{parent_cpu_delta_percent})
                ? sprintf('%+.2f%%', $row->{parent_cpu_delta_percent}) : '-';
    }

    if (defined $json_path) {
        my $report = {
            benchmark =>
                'linux-event-accepted-stream-callback-construction',
            benchmark_contract_version => 1,
            linux_event_version =>
                $Linux::Event::IO::Sock::Listener::VERSION,
            perl_version => 0 + $],
            configuration => {
                callback_styles => \@accepted_callbacks,
                clients => \@clients,
                connections => $connections,
                repeats => $repeats,
                timeout => 0 + $timeout,
                client_processes => 1,
                parent_cpu_excludes_client_workers => 1,
            },
            raw => \@raw,
            summary => \@summary,
        };
        open my $json, '>', $json_path
            or die "open $json_path: $!\n";
        print {$json} JSON::PP->new->canonical->pretty->encode($report);
        close $json or die "close $json_path: $!\n";
    }
    return;
}

if (defined $accepted_callback_spec) {
    run_callback_benchmark();
} else {
    run_standard_benchmark();
}

sub usage ($exit) {
    print <<'USAGE';
Usage: perl -Mblib bench/run-listen-microbench.pl [options]

  --modes=LIST          manual,add,loop (default: all three)
  --clients=LIST        concurrent clients (default: 1,10,100)
  --connections=N       accepted connections per row (default: 10000)
  --repeats=N           median repetitions (default: 9)
  --timeout=SECONDS     catastrophic connection deadline (default: 30)
  --accepted-callbacks=LIST
                        Run the accepted Stream callback-construction matrix
                        instead of manual/add/loop. Values:
                        subclass_method,shared_closure,fresh_closure, or all
  --json=PATH           JSON report for --accepted-callbacks mode
  --help

Default mode retains the historical Listener lifecycle comparison. All rows
acquire loopback TCP clients through Linux::Event Stream->connect. Manual uses
explicit listener setup, Loop->watch, Perl accept, and close. Add uses detached
Listener construction followed by Loop->add. Loop supplies loop => directly to
Listener->new. Both Listener rows construct and close the same minimal Stream
subclass. Every successfully connected client uses equal abortive teardown so
repeated rows do not exhaust the host with client-side TIME_WAIT sockets.
Repeat execution order rotates to reduce bias.

--accepted-callbacks measures the construction question separately. The parent
process runs the real Linux::Event Listener and constructs one accepted Stream
per TCP connection. Blocking loopback clients run in forked workers, so parent
process CPU excludes client construction and connect work. subclass_method uses
the current class callback. shared_closure installs the same captured CV into
every accepted Stream. fresh_closure allocates a new captured closure in each
accepted Stream constructor. Timing starts before the workers are released, so
fresh closure allocation is inside the measured lifecycle.
USAGE
    exit $exit;
}
