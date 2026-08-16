#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Socket qw(
    AF_INET INADDR_LOOPBACK
    SOCK_STREAM SOCK_NONBLOCK SOCK_CLOEXEC
    SOL_SOCKET SO_LINGER SO_REUSEADDR
    pack_sockaddr_in unpack_sockaddr_in
);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use Linux::Event::Connect;
use Linux::Event::Listen;
use Linux::Event::Stream;
use Linux::Event::XSLoop;

my @modes = qw(manual handoff raw stream automatic);
my @clients = (1, 10, 100);
my $connections = 10_000;
my $repeats = 10;
my $timeout = 30;
my $help = 0;

GetOptions(
    'modes=s'       => sub { @modes = split /,/, $_[1] },
    'clients=s'     => sub { @clients = map { 0 + $_ } split /,/, $_[1] },
    'connections=i' => \$connections,
    'repeats=i'     => \$repeats,
    'timeout=f'     => \$timeout,
    'help'          => \$help,
) or usage(1);
usage(0) if $help;

die "connections must be positive\n" if $connections < 1;
die "repeats must be positive\n" if $repeats < 1;
die "timeout must be positive\n" if $timeout <= 0;
die "clients must be positive\n" if grep { $_ < 1 } @clients;
my %valid_mode = map { $_ => 1 } qw(manual handoff raw stream automatic);
die "modes must contain only manual, handoff, raw, stream, or automatic\n"
    if grep { !$valid_mode{$_} } @modes;
my %seen_mode;
die "modes must not contain duplicates\n"
    if grep { $seen_mode{$_}++ } @modes;

{
    package BenchListenStream;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { }
}

{
    package BenchAutomaticStream;
    use parent 'Linux::Event::Stream';

    sub on_data ($stream, $bytes) { }

    sub accepted_stream_options ($class, $listener, $peer) {
        return data => $listener->data;
    }

    sub on_ready ($stream) {
        my $run = $stream->data;
        $stream->close;
        $run->{accepted}++;
        main::finish_if_done($run);
    }

    sub on_listener_error ($class, $listener, $error) {
        die "benchmark listener failed: $error\n";
    }
}

{
    package BenchListener;
    use parent 'Linux::Event::Listen';

    sub on_accept ($listener, $fh, $peer) {
        my $run = $listener->data;
        if ($run->{mode} eq 'stream') {
            BenchListenStream->new(loop => $listener->loop, fh => $fh)->close;
        } else {
            close $fh;
        }
        $run->{accepted}++;
        main::finish_if_done($run);
    }

    sub on_error ($listener, $error) {
        die "benchmark listener failed: $error\n";
    }
}

{
    package BenchListenClient;
    use parent 'Linux::Event::Connect';

    sub on_connect ($request, $fh) {
        my $run = $request->data;
        main::enable_abortive_close($fh, 'client');
        close $fh;
        $run->{active}--;
        $run->{completed}++;
        main::launch_requests($run);
        main::finish_if_done($run);
    }

    sub on_error ($request, $error) {
        die "benchmark connection failed: $error\n";
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

sub manual_accept_ready ($watcher) {
    my $run = $watcher->data;
    my $batch = Linux::Event::Listen->_accept4_batch(
        fileno($run->{listener_fh}), 256,
    );
    my $errno = $batch->[0];
    for (my $at = 1; $at < @$batch; $at += 2) {
        my $fd = $batch->[$at];
        if ($run->{mode} eq 'handoff') {
            open(my $client, '+<&=', $fd) or do {
                my $error = "$!";
                Linux::Event::Listen->_close_fd($fd);
                die "handoff filehandle construction failed: $error\n";
            };
            my $peer = Linux::Event::Listen::Peer->new($batch->[$at + 1]);
            close $client;
        } else {
            Linux::Event::Listen->_close_fd($fd);
        }
        $run->{accepted}++;
    }
    if ($errno) {
        local $! = $errno;
        die "manual accept4 failed: $!\n";
    }
    finish_if_done($run);
    return;
}

sub launch_requests ($run) {
    while ($run->{active} < $run->{clients}
        && $run->{started} < $run->{connections}) {
        $run->{started}++;
        $run->{active}++;
        BenchListenClient->new(
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
    my $loop = Linux::Event::XSLoop->new;
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
    if ($mode eq 'manual' || $mode eq 'handoff') {
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
    } elsif ($mode eq 'automatic') {
        $run->{listener} = BenchAutomaticStream->listen(
            host => '127.0.0.1', port => 0, data => $run,
        );
        $loop->add($run->{listener});
        $run->{port} = $run->{listener}->port;
    } else {
        $run->{listener} = BenchListener->new(
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

    if ($mode eq 'manual' || $mode eq 'handoff') {
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

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    my $middle = int(@values / 2);
    return @values % 2
        ? $values[$middle]
        : ($values[$middle - 1] + $values[$middle]) / 2;
}

say 'Median loopback TCP Listen lifecycle benchmark';
say "Linux::Event version $Linux::Event::Listen::VERSION";
printf "%-8s %8s %14s %14s\n",
    qw(mode clients accepts/s cpu_us/accept);
for my $client_count (@clients) {
    my %result;
    for my $repeat (0 .. $repeats - 1) {
        my $offset = $repeat % @modes;
        my @order = (@modes[$offset .. $#modes], @modes[0 .. $offset - 1]);
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

sub usage ($exit) {
    print <<'USAGE';
Usage: perl -Mblib bench/run-listen-microbench.pl [options]

  --modes=LIST          manual,handoff,raw,stream,automatic (default: all five)
  --clients=LIST        concurrent clients (default: 1,10,100)
  --connections=N       accepted connections per row (default: 10000)
  --repeats=N           median repetitions (default: 10)
  --timeout=SECONDS     catastrophic connection deadline (default: 30)
  --help

All rows acquire loopback TCP clients through Linux::Event::Connect. Manual
uses explicit listener setup, a raw XSLoop watcher, and native descriptor
close. Handoff adds Perl filehandle and lazy Peer construction. Raw accepts
through Linux::Event::Listen and invokes its callback. Stream additionally
constructs and closes a minimal Stream. Automatic uses MyStream->listen and
Loop->add, then closes the automatically constructed Stream from on_ready.
Every successfully connected client
uses equal abortive teardown so repeated rows do not exhaust the host with
client-side TIME_WAIT sockets. Repeat execution order rotates to reduce bias;
use a repeat count divisible by five for balanced execution order.
USAGE
    exit $exit;
}
