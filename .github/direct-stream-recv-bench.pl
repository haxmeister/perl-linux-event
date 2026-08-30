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
use Linux::Event::Stream;

XSLoader::load('Linux::Event::DirectAwaitable', $Linux::Event::VERSION);

{
    package LE::Experiment::RecvProducer;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { return }
}

{
    package LE::Experiment::RecvCallback;
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
    package LE::Experiment::RecvAwait;
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
        my $awaitable = Linux::Event::DirectAwaitable->_recv_stream_state(
            $stream->{xs_state});
        my $message = await $awaitable;
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

my $sizes = '32,64,256,1024,4096,16384,65536';
my $repeat = 5;
my $warmup = 1;
my $batch_size = 32;

GetOptions(
    'sizes=s'      => \$sizes,
    'repeat=i'     => \$repeat,
    'warmup=i'     => \$warmup,
    'batch-size=i' => \$batch_size,
) or die "invalid options\n";

die "repeat must be positive\n" if $repeat < 1;
die "warmup must be non-negative\n" if $warmup < 0;
die "batch-size must be positive\n" if $batch_size < 1;

my @sizes = map { 0 + $_ } split /,/, $sizes;
die "sizes must contain positive integers\n"
    if !@sizes || grep { $_ < 1 } @sizes;

sub messages_for_size ($size) {
    return 50_000 if $size <= 256;
    return 30_000 if $size <= 1_024;
    return 10_000 if $size <= 4_096;
    return 3_000  if $size <= 16_384;
    return 1_000;
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    return $values[int(@values / 2)];
}

sub run_once ($kind, $payload_size, $messages) {
    socketpair(my $receiver_fh, my $producer_fh,
        AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

    my $loop = Linux::Event::Loop->new;
    my $state = {
        count  => 0,
        loop   => $loop,
        target => $messages,
    };
    my $class = $kind eq 'callback'
        ? 'LE::Experiment::RecvCallback'
        : 'LE::Experiment::RecvAwait';
    my $receiver = $class->new(
        loop => $loop,
        fh   => $receiver_fh,
        data => $state,
    );
    my $producer = LE::Experiment::RecvProducer->new(
        loop => $loop,
        fh   => $producer_fh,
    );

    my $task = $kind eq 'future'
        ? consume_future($receiver, $messages)
        : $kind eq 'direct'
            ? consume_direct($receiver, $messages)
            : $kind eq 'batch'
                ? consume_batch($receiver, $messages, $batch_size)
                : undef;

    my $payload = 'x' x $payload_size;
    my $wire = ($payload . "\n") x $messages;
    my $started = clock_gettime(CLOCK_MONOTONIC);
    $producer->write($wire);

    my $count;
    if ($task) {
        $count = $loop->run($task);
    } else {
        $loop->run;
        $count = $state->{count};
    }
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $started;

    die "$kind delivered $count of $messages messages at size $payload_size\n"
        if $count != $messages;
    $receiver->close;
    $producer->close;
    return $elapsed;
}

my @kinds = qw(callback future direct batch);
printf "%-8s %9s %10s %12s %12s %11s\n",
    qw(size messages mode messages/s MiB/s vs_future);

for my $payload_size (@sizes) {
    my $messages = messages_for_size($payload_size);

    if ($warmup) {
        for (1 .. $warmup) {
            run_once($_, $payload_size, $messages) for @kinds;
        }
    }

    my %samples = map { $_ => [] } @kinds;
    for my $sample (1 .. $repeat) {
        my @order = $sample % 2 ? @kinds : reverse @kinds;
        push $samples{$_}->@*, run_once($_, $payload_size, $messages)
            for @order;
    }

    my %median = map { $_ => median($samples{$_}->@*) } @kinds;
    my %rate = map { $_ => $messages / $median{$_} } @kinds;
    my $wire_bytes = $messages * ($payload_size + 1);

    for my $kind (@kinds) {
        my $mib = ($wire_bytes / $median{$kind}) / (1024 * 1024);
        my $ratio = $rate{$kind} / $rate{future};
        printf "%-8d %9d %-10s %12.0f %12.1f %10.3fx\n",
            $payload_size, $messages, $kind, $rate{$kind}, $mib, $ratio;
    }
    say "samples size=$payload_size";
    for my $kind (@kinds) {
        say "  $kind " . join(' ', map { sprintf '%.6f', $_ }
            $samples{$kind}->@*);
    }
}
