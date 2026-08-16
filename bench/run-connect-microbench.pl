#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Socket qw(
    AF_INET INADDR_LOOPBACK
    SOCK_STREAM SOCK_NONBLOCK SOCK_CLOEXEC
    SOL_SOCKET SO_REUSEADDR SOMAXCONN
    pack_sockaddr_in unpack_sockaddr_in
);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use Linux::Event::Connect;
use Linux::Event::Stream;
use Linux::Event::XSLoop;

my @modes = qw(raw stream);
my @clients = (1, 10, 100);
my $connections = 10_000;
my $repeats = 5;
my $help = 0;

GetOptions(
    'modes=s'       => sub { @modes = split /,/, $_[1] },
    'clients=s'     => sub { @clients = map { 0 + $_ } split /,/, $_[1] },
    'connections=i' => \$connections,
    'repeats=i'     => \$repeats,
    'help'          => \$help,
) or usage(1);
usage(0) if $help;

die "connections must be positive\n" if $connections < 1;
die "repeats must be positive\n" if $repeats < 1;
die "clients must be positive\n" if grep { $_ < 1 } @clients;
my %valid_mode = map { $_ => 1 } qw(raw stream);
die "modes must contain only raw or stream\n"
    if grep { !$valid_mode{$_} } @modes;

{
    package BenchConnectStream;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { }
    sub on_error ($stream, $error) { }
}

{
    package BenchConnectRequest;
    use parent 'Linux::Event::Connect';

    sub on_connect ($request, $fh) {
        my $run = $request->data;
        if ($run->{mode} eq 'stream') {
            my $stream = BenchConnectStream->new(
                loop => $request->loop,
                fh   => $fh,
            );
            $stream->close;
        } else {
            close $fh;
        }
        $run->{active}--;
        $run->{completed}++;
        main::launch_requests($run);
        $request->loop->stop
            if $run->{completed} == $run->{connections};
    }

    sub on_error ($request, $error) {
        die "benchmark connection failed: $error\n";
    }
}

sub accept_ready ($watcher) {
    my $run = $watcher->data;
    while (accept(my $peer, $run->{listener})) {
        close $peer;
        $run->{accepted}++;
    }
    return;
}

sub launch_requests ($run) {
    while ($run->{active} < $run->{clients}
        && $run->{started} < $run->{connections}) {
        $run->{started}++;
        $run->{active}++;
        BenchConnectRequest->new(
            loop    => $run->{loop},
            host    => '127.0.0.1',
            port    => $run->{port},
            timeout => 2,
            data    => $run,
        );
    }
    return;
}

sub one_run ($mode, $client_count) {
    socket(my $listener, AF_INET,
        SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)
        or die "listener socket: $!\n";
    setsockopt($listener, SOL_SOCKET, SO_REUSEADDR, pack('i', 1))
        or die "setsockopt SO_REUSEADDR: $!\n";
    bind($listener, pack_sockaddr_in(0, INADDR_LOOPBACK))
        or die "listener bind: $!\n";
    listen($listener, SOMAXCONN) or die "listener listen: $!\n";
    my ($port) = unpack_sockaddr_in(getsockname($listener));

    my $loop = Linux::Event::XSLoop->new;
    $loop->enable_watcher_reclaim(1);
    my $run = {
        mode        => $mode,
        clients     => $client_count,
        connections => $connections,
        loop        => $loop,
        listener    => $listener,
        port        => $port,
        started     => 0,
        active      => 0,
        completed   => 0,
        accepted    => 0,
    };
    my $accept_watcher = $loop->watch(
        fh   => $listener,
        data => $run,
        read => \&accept_ready,
    );

    my $wall_start = clock_gettime(CLOCK_MONOTONIC);
    my ($user_start, $system_start) = (times)[0, 1];
    launch_requests($run);
    $loop->run;
    my ($user_end, $system_end) = (times)[0, 1];
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $wall_start;
    my $cpu = ($user_end - $user_start) + ($system_end - $system_start);

    $accept_watcher->cancel;
    close $listener;
    return {
        rate      => $connections / $elapsed,
        cpu_us    => $cpu * 1_000_000 / $connections,
        accepted  => $run->{accepted},
        completed => $run->{completed},
    };
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    my $middle = int(@values / 2);
    return @values % 2
        ? $values[$middle]
        : ($values[$middle - 1] + $values[$middle]) / 2;
}

say 'Median loopback TCP Connect lifecycle benchmark';
printf "%-8s %8s %14s %14s\n",
    qw(mode clients connects/s cpu_us/connect);
for my $client_count (@clients) {
    for my $mode (@modes) {
        my @result = map { one_run($mode, $client_count) } 1 .. $repeats;
        printf "%-8s %8d %14.1f %14.3f\n",
            $mode,
            $client_count,
            median(map { $_->{rate} } @result),
            median(map { $_->{cpu_us} } @result);
    }
}

sub usage ($exit) {
    print <<'USAGE';
Usage: perl -Mblib bench/run-connect-microbench.pl [options]

  --modes=LIST          raw,stream (default: raw,stream)
  --clients=LIST        concurrent requests (default: 1,10,100)
  --connections=N       completed connections per row (default: 10000)
  --repeats=N           median repetitions (default: 5)
  --help

The raw row closes the transferred socket in on_connect. The stream row
constructs and closes a Stream, exercising same-fd watcher handoff when the
nonblocking TCP connection completes through epoll.
USAGE
    exit $exit;
}
