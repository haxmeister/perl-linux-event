#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use JSON::PP qw(encode_json);
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC usleep);

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;

# Research-only real Linux::Event Listener/Stream benchmark.
# Arguments: shared|exclusive|reuseport WORKERS CONNECTIONS GAP_US WORK_US
my ($mode, $workers, $total, $gap_us, $work_us) = @ARGV;
die "usage: $0 shared|exclusive|reuseport WORKERS CONNECTIONS GAP_US WORK_US\n"
    unless @ARGV == 5 && $mode =~ /\A(?:shared|exclusive|reuseport)\z/
    && $workers =~ /\A[1-9]\d*\z/ && $workers <= 16
    && $total =~ /\A[1-9]\d*\z/ && $total <= 10_000
    && $gap_us =~ /\A\d+\z/ && $gap_us <= 1_000_000
    && $work_us =~ /\A\d+\z/ && $work_us <= 10_000;

sub now () { clock_gettime(CLOCK_MONOTONIC) }
my $accepted = 0;
my $messages = 0;
my $accepted_bytes = 0;

sub stream_recipe () {
    return {
        on_data => sub ($stream, $bytes) {
            $messages++;
            $accepted_bytes += length $bytes;
            if ($work_us) {
                my $end = now() + $work_us / 1_000_000;
                1 while now() < $end;
            }
            $stream->close;
        },
        on_error => sub ($stream, $error) {
            warn "Stream error: $error\n";
            $stream->close;
        },
    };
}
sub create_listener ($loop, $port, $reuseport) {
    return Linux::Event::IO::Sock::Listener->new(
        (defined $loop ? (loop => $loop) : ()),
        host => '127.0.0.1',
        port => $port,
        reuseport => $reuseport,
        backlog => 4096,
        max_accept_per_tick => 256,
        stream => stream_recipe(),
        on_accept => sub ($listener, $stream) { $accepted++ },
    );
}

# The test-only experiment setting is sampled at Listener construction.
local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} =
    ($mode eq 'exclusive' ? 1 : 0);

my $shared_loop = $mode eq 'reuseport' ? undef : Linux::Event::Loop->new;
my $seed = create_listener($shared_loop, 0, $mode eq 'reuseport' ? 1 : 0);
my $port = $seed->port;
pipe(my $ready_read, my $ready_write) or die "ready pipe: $!";
pipe(my $result_read, my $result_write) or die "result pipe: $!";

my @children;
for my $index (0 .. $workers - 1) {
    my $pid = $mode eq 'reuseport'
        ? CORE::fork()
        : $shared_loop->fork(share => [$seed]);
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        close $ready_read;
        close $result_read;
        my $loop;
        if ($mode eq 'reuseport') {
            # Each worker listens on an independently owned SO_REUSEPORT socket.
            $seed->close;
            $loop = Linux::Event::Loop->new;
            my $listener = create_listener($loop, $port, 1);
            $seed = $listener;
        }
        else {
            $loop = $shared_loop;
        }
        syswrite($ready_write, 'R') == 1 or die "ready write failed: $!";
        close $ready_write;
        my $start = now();
        $loop->run_for(1.7);
        my $elapsed = now() - $start;
        my $stats = $loop->stats;
        my $line = join(' ', $index, $accepted, $messages, $accepted_bytes,
            $stats->{epoll_wait_calls} // 0, sprintf('%.6f', $elapsed)) . "\n";
        syswrite($result_write, $line) == length($line)
            or die "result write failed: $!";
        close $result_write;
        $seed->close;
        POSIX::_exit(0);
    }
    push @children, $pid;
}
close $ready_write;
close $result_write;
for (1 .. $workers) {
    my $n = sysread($ready_read, my $ready, 1);
    die "worker failed to initialize" if !defined($n) || $n != 1 || $ready ne 'R';
}
close $ready_read;
$seed->close;
my $start = now();
my $sent = 0;
for (1 .. $total) {
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto => 'tcp',
        Timeout => 2,
    );
    if ($client) {
        $sent++ if defined(syswrite($client, "x")) ;
        close $client;
    }
    usleep($gap_us) if $gap_us;
}
my $generator_seconds = now() - $start;
my $failed = 0;
for my $pid (@children) {
    waitpid($pid, 0) == $pid or die "waitpid failed";
    $failed++ if $? != 0;
}
my $total_seconds = now() - $start;
my @worker;
while (my $line = <$result_read>) {
    my ($index, $naccept, $nmessages, $bytes, $waits, $duration) =
        split /\s+/, $line;
    push @worker, {
        index => 0 + $index, accepted => 0 + $naccept,
        messages => 0 + $nmessages, bytes => 0 + $bytes,
        epoll_wait_calls => 0 + $waits, worker_elapsed_s => 0 + $duration,
    };
}
close $result_read;
@worker = sort { $a->{index} <=> $b->{index} } @worker;
my $accepted_total = 0;
my $messages_total = 0;
my $waits_total = 0;
for my $w (@worker) {
    $accepted_total += $w->{accepted};
    $messages_total += $w->{messages};
    $waits_total += $w->{epoll_wait_calls};
}
say encode_json({
    mode => $mode, workers => 0 + $workers, attempted => 0 + $total,
    sent => $sent, accepted => $accepted_total,
    messages => $messages_total, gap_us => 0 + $gap_us,
    work_us => 0 + $work_us,
    generator_seconds => $generator_seconds,
    total_seconds => $total_seconds,
    connection_rate => $generator_seconds > 0 ? $sent / $generator_seconds : 0,
    epoll_wait_calls => $waits_total, worker => \@worker, child_failures => $failed,
});
exit($failed || @worker != $workers || $sent != $total
    || $accepted_total != $total ? 1 : 0);
