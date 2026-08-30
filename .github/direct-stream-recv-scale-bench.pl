#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use XSLoader;

use Linux::Event;
use Linux::Event::Loop;
use Linux::Event::Future;
use Linux::Event::Stream;

XSLoader::load('Linux::Event::DirectAwaitable', $Linux::Event::VERSION);

{
    package LE::Experiment::ScaleProducer;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { return }
}

{
    package LE::Experiment::ScaleCallback;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";

    sub on_message ($stream, $message) {
        my $state = $stream->data;
        $state->{count}++;
        $state->{loop}->stop if $state->{count} == $state->{target};
        return;
    }
}

{
    package LE::Experiment::ScaleAwait;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";
}

async sub consume_future ($stream, $target) {
    my $count = 0;
    while ($count < $target) {
        my $message = await $stream->recv;
        die "future: unexpected EOF after $count messages" if !defined $message;
        $count++;
    }
    return $count;
}

async sub consume_direct ($stream, $target) {
    my $count = 0;
    while ($count < $target) {
        my $message = await Linux::Event::DirectAwaitable->_recv_stream_state(
            $stream->{xs_state});
        die "direct: unexpected EOF after $count messages" if !defined $message;
        $count++;
    }
    return $count;
}

async sub consume_batch ($stream, $target, $maximum) {
    my $count = 0;
    while ($count < $target) {
        my $batch = await $stream->recv_batch($maximum);
        die "batch: unexpected EOF after $count messages" if !defined $batch;
        $count += @$batch;
        die "batch consumer received too many messages" if $count > $target;
    }
    return $count;
}

my $sizes = '64,1024,16384,65536';
my $clients = '1,10,100';
my $repeat = 3;
my $warmup = 1;
my $batch_size = 32;

GetOptions(
    'sizes=s'      => \$sizes,
    'clients=s'    => \$clients,
    'repeat=i'     => \$repeat,
    'warmup=i'     => \$warmup,
    'batch-size=i' => \$batch_size,
) or die "invalid options\n";

die "repeat must be positive\n" if $repeat < 1;
die "warmup must be non-negative\n" if $warmup < 0;
die "batch-size must be positive\n" if $batch_size < 1;

my @sizes = map { 0 + $_ } split /,/, $sizes;
my @clients = map { 0 + $_ } split /,/, $clients;
die "sizes must contain positive integers\n"
    if !@sizes || grep { $_ < 1 } @sizes;
die "clients must contain positive integers\n"
    if !@clients || grep { $_ < 1 } @clients;

sub total_messages_for_size ($size) {
    return 50_000 if $size <= 64;
    return 30_000 if $size <= 1_024;
    return 3_000  if $size <= 16_384;
    return 1_000;
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    return $values[int(@values / 2)];
}

sub run_once ($kind, $payload_size, $client_count) {
    my $requested_total = total_messages_for_size($payload_size);
    my $per_client = int(($requested_total + $client_count - 1) / $client_count);
    my $total = $per_client * $client_count;
    my $loop = Linux::Event::Loop->new;
    my $state = { count => 0, loop => $loop, target => $total };
    my (@receivers, @producers, @tasks);

    for (1 .. $client_count) {
        socketpair(my $receiver_fh, my $producer_fh,
            AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
        my $class = $kind eq 'callback'
            ? 'LE::Experiment::ScaleCallback'
            : 'LE::Experiment::ScaleAwait';
        push @receivers, $class->new(
            loop => $loop,
            fh   => $receiver_fh,
            data => $state,
        );
        push @producers, LE::Experiment::ScaleProducer->new(
            loop => $loop,
            fh   => $producer_fh,
        );
    }

    if ($kind ne 'callback') {
        for my $stream (@receivers) {
            push @tasks,
                $kind eq 'future' ? consume_future($stream, $per_client)
              : $kind eq 'direct' ? consume_direct($stream, $per_client)
              : consume_batch($stream, $per_client, $batch_size);
        }
    }

    my $done;
    if (@tasks) {
        $done = Linux::Event::Future->new($loop);
        my $remaining = scalar @tasks;
        my $received = 0;
        for my $task (@tasks) {
            $task->AWAIT_ON_READY(sub {
                return if $done->is_ready;
                my $count = eval { $task->AWAIT_GET };
                if ($@) {
                    $done->fail($@);
                    return;
                }
                $received += $count;
                $remaining--;
                $done->done($received) if $remaining == 0;
            });
        }
    }

    my $payload = 'x' x $payload_size;
    my $wire = ($payload . "\n") x $per_client;
    my $started = clock_gettime(CLOCK_MONOTONIC);
    $_->write($wire) for @producers;

    my $count;
    if ($done) {
        $count = $loop->run($done);
    } else {
        $loop->run;
        $count = $state->{count};
    }
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $started;

    die "$kind delivered $count of $total messages at size $payload_size clients=$client_count\n"
        if $count != $total;
    $_->close for @receivers;
    $_->close for @producers;
    return ($elapsed, $total);
}

my @kinds = qw(callback future direct batch);
printf "%-7s %-7s %-10s %12s %12s %11s\n",
    qw(size clients mode messages/s MiB/s vs_future);

for my $payload_size (@sizes) {
    for my $client_count (@clients) {
        if ($warmup) {
            for (1 .. $warmup) {
                run_once($_, $payload_size, $client_count) for @kinds;
            }
        }

        my (%samples, %totals);
        $samples{$_} = [] for @kinds;
        for my $sample (1 .. $repeat) {
            my @order = $sample % 2 ? @kinds : reverse @kinds;
            for my $kind (@order) {
                my ($elapsed, $total) = run_once(
                    $kind, $payload_size, $client_count);
                push $samples{$kind}->@*, $elapsed;
                $totals{$kind} = $total;
            }
        }

        my %median = map { $_ => median($samples{$_}->@*) } @kinds;
        my %rate = map { $_ => $totals{$_} / $median{$_} } @kinds;
        for my $kind (@kinds) {
            my $wire_bytes = $totals{$kind} * ($payload_size + 1);
            my $mib = ($wire_bytes / $median{$kind}) / (1024 * 1024);
            my $ratio = $rate{$kind} / $rate{future};
            printf "%-7d %-7d %-10s %12.0f %12.1f %10.3fx\n",
                $payload_size, $client_count, $kind,
                $rate{$kind}, $mib, $ratio;
        }
        say "samples size=$payload_size clients=$client_count";
        for my $kind (@kinds) {
            say "  $kind " . join(' ', map { sprintf '%.6f', $_ }
                $samples{$kind}->@*);
        }
    }
}
