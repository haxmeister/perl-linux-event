#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::PP qw(encode_json);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use Linux::Event;
use Linux::Event::Loop;
use Linux::Event::Stream;

{
    package LE::Bench::FutureRecv::Producer;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { return }
}

{
    package LE::Bench::FutureRecv::Callback;
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
    package LE::Bench::FutureRecv::Await;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";
}

async sub consume_messages ($stream, $target) {
    my $count = 0;
    while ($count < $target) {
        my $message = await $stream->recv;
        die "unexpected EOF after $count messages" if !defined $message;
        $count++;
    }
    return $count;
}

my $messages = 20_000;
my $payload_size = 32;
my $repeat = 5;
my $warmup = 1;
my $mode = 'all';
my $json = 0;

GetOptions(
    'messages=i'     => \$messages,
    'payload-size=i' => \$payload_size,
    'repeat=i'       => \$repeat,
    'warmup=i'       => \$warmup,
    'mode=s'         => \$mode,
    'json!'          => \$json,
) or die "invalid options\n";

die "messages must be positive\n" if $messages < 1;
die "payload-size must be non-negative\n" if $payload_size < 0;
die "repeat must be positive\n" if $repeat < 1;
die "warmup must be non-negative\n" if $warmup < 0;
die "mode must be callback, future, or all\n"
    if $mode ne 'callback' && $mode ne 'future' && $mode ne 'all';

my $payload = 'x' x $payload_size;
my $wire = ($payload . "\n") x $messages;

sub run_once ($kind) {
    socketpair(my $receiver_fh, my $producer_fh,
        AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

    my $loop = Linux::Event::Loop->new;
    my $state = {
        count  => 0,
        loop   => $loop,
        target => $messages,
    };
    my $class = $kind eq 'callback'
        ? 'LE::Bench::FutureRecv::Callback'
        : 'LE::Bench::FutureRecv::Await';
    my $receiver = $class->new(
        loop => $loop,
        fh   => $receiver_fh,
        data => $state,
    );
    my $producer = LE::Bench::FutureRecv::Producer->new(
        loop => $loop,
        fh   => $producer_fh,
    );
    my $task = $kind eq 'future'
        ? consume_messages($receiver, $messages) : undef;

    my $started = clock_gettime(CLOCK_MONOTONIC);
    $producer->write($wire);
    my $count;
    if ($kind eq 'future') {
        $count = $loop->run($task);
    } else {
        $loop->run;
        $count = $state->{count};
    }
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $started;

    die "$kind delivered $count of $messages messages\n"
        if $count != $messages;
    $receiver->close;
    $producer->close;
    return $elapsed;
}

sub summarize ($seconds) {
    my @seconds = sort { $a <=> $b } @$seconds;
    my $median = $seconds[int(@seconds / 2)];
    return {
        seconds             => $median,
        messages_per_second => $messages / $median,
        samples_seconds     => \@seconds,
    };
}

my @kind = $mode eq 'all' ? qw(callback future) : ($mode);
if ($warmup) {
    for (1 .. $warmup) {
        run_once($_) for @kind;
    }
}
my %seconds = map { $_ => [] } @kind;
for my $sample (1 .. $repeat) {
    my @order = $sample % 2 ? @kind : reverse @kind;
    push $seconds{$_}->@*, run_once($_) for @order;
}
my %case = map { $_ => summarize($seconds{$_}) } @kind;
my $result = {
    messages     => $messages,
    payload_size => $payload_size,
    repeat       => $repeat,
    warmup       => $warmup,
    cases        => \%case,
};
if (exists $case{callback} && exists $case{future}) {
    $result->{future_to_callback_rate} =
        $case{future}{messages_per_second}
        / $case{callback}{messages_per_second};
}

if ($json) {
    say encode_json($result);
    exit 0;
}

say "messages=$messages payload_size=$payload_size repeat=$repeat warmup=$warmup";
for my $kind (@kind) {
    printf "%s %.0f messages/s (%.6f s)\n",
        $kind,
        $case{$kind}{messages_per_second},
        $case{$kind}{seconds};
}
printf "future/callback rate %.3f\n", $result->{future_to_callback_rate}
    if exists $result->{future_to_callback_rate};
