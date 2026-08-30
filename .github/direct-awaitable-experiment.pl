#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use Linux::Event;
use Linux::Event::Loop;
use Linux::Event::Future;

{
    package LE::Experiment::DirectAwaitable;

    sub new ($class) {
        return bless {
            state    => 'pending',
            results  => [],
            failure  => undef,
            callback => undef,
        }, $class;
    }

    sub _notify ($self) {
        if (my $callback = delete $self->{callback}) {
            $callback->();
        }
        return;
    }

    sub complete ($self, @results) {
        die "direct awaitable completed twice" if $self->{state} ne 'pending';
        $self->{results} = [@results];
        $self->{state} = 'done';
        $self->_notify;
        return;
    }

    sub AWAIT_CLONE ($self) {
        return ref($self)->new;
    }

    sub AWAIT_DONE ($self, @results) {
        $self->complete(@results);
        return;
    }

    sub AWAIT_FAIL ($self, $failure) {
        die "direct awaitable completed twice" if $self->{state} ne 'pending';
        $self->{failure} = $failure;
        $self->{state} = 'failed';
        $self->_notify;
        return;
    }

    sub AWAIT_IS_READY ($self) { $self->{state} ne 'pending' }
    sub AWAIT_IS_CANCELLED ($self) { 0 }

    sub AWAIT_GET ($self) {
        die "direct awaitable is not ready" if $self->{state} eq 'pending';
        die $self->{failure} if $self->{state} eq 'failed';
        return wantarray ? $self->{results}->@* : $self->{results}[0];
    }

    sub AWAIT_ON_READY ($self, $callback) {
        die "direct awaitable callback must be a coderef"
            if ref($callback) ne 'CODE';
        if ($self->{state} ne 'pending') {
            $callback->();
        } else {
            die "direct awaitable already has a waiter"
                if $self->{callback};
            $self->{callback} = $callback;
        }
        return;
    }

    sub AWAIT_ON_CANCEL ($self, $callback) { return }
    sub AWAIT_CHAIN_CANCEL ($self, $target) { return }
}

my $iterations = 50_000;
my $repeat = 7;
my $warmup = 2;

GetOptions(
    'iterations=i' => \$iterations,
    'repeat=i'     => \$repeat,
    'warmup=i'     => \$warmup,
) or die "invalid options\n";

die "iterations must be positive\n" if $iterations < 1;
die "repeat must be positive\n" if $repeat < 1;
die "warmup must be non-negative\n" if $warmup < 0;

async sub consume_future ($loop, $iterations, $pending_ref) {
    my $count = 0;
    while ($count < $iterations) {
        my $future = Linux::Event::Future->new($loop);
        $$pending_ref = $future;
        my $byte = await $future;
        die "unexpected future byte" if !defined($byte) || length($byte) != 1;
        $count++;
    }
    return $count;
}

async sub consume_direct ($iterations, $pending_ref) {
    my $count = 0;
    while ($count < $iterations) {
        my $awaitable = LE::Experiment::DirectAwaitable->new;
        $$pending_ref = $awaitable;
        my $byte = await $awaitable;
        die "unexpected direct byte" if !defined($byte) || length($byte) != 1;
        $count++;
    }
    return $count;
}

sub run_once ($kind) {
    socketpair(my $reader, my $writer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";

    my $loop = Linux::Event::Loop->new;
    my $pending;
    my $registration = $loop->watch(
        fh      => $reader,
        no_args => 1,
        lean    => 1,
        read    => sub {
            my $n = sysread($reader, my $byte, 1);
            die "sysread failed: $!" if !defined $n;
            die "unexpected EOF" if $n == 0;
            my $target = $pending // die "read readiness without pending awaitable";
            $pending = undef;
            if ($kind eq 'future') {
                $target->done($byte);
            } else {
                $target->complete($byte);
            }
        },
        error   => sub {
            die "socketpair registration reported terminal readiness";
        },
    );

    my $wire = 'x' x $iterations;
    my $offset = 0;
    while ($offset < length($wire)) {
        my $n = syswrite($writer, $wire, length($wire) - $offset, $offset);
        die "syswrite failed: $!" if !defined $n;
        $offset += $n;
    }

    my $task = $kind eq 'future'
        ? consume_future($loop, $iterations, \$pending)
        : consume_direct($iterations, \$pending);

    my $done = Linux::Event::Future->new($loop);
    $task->AWAIT_ON_READY(sub {
        my $count = eval { $task->AWAIT_GET };
        if ($@) {
            $done->fail($@);
        } else {
            $done->done($count);
        }
    });

    my $started = clock_gettime(CLOCK_MONOTONIC);
    my $count = $loop->run($done);
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $started;

    die "$kind completed $count of $iterations iterations\n"
        if $count != $iterations;

    $registration->cancel;
    close $reader;
    close $writer;
    return $elapsed;
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    return $values[int(@values / 2)];
}

for (1 .. $warmup) {
    run_once('future');
    run_once('direct');
}

my %samples = (future => [], direct => []);
for my $sample (1 .. $repeat) {
    my @order = $sample % 2 ? qw(future direct) : qw(direct future);
    push $samples{$_}->@*, run_once($_) for @order;
}

my $future_seconds = median($samples{future}->@*);
my $direct_seconds = median($samples{direct}->@*);
my $future_rate = $iterations / $future_seconds;
my $direct_rate = $iterations / $direct_seconds;
my $ratio = $direct_rate / $future_rate;

say "direct-awaitable experiment";
say "iterations=$iterations repeat=$repeat warmup=$warmup";
printf "future %.0f resumes/s (%.6f s)\n", $future_rate, $future_seconds;
printf "direct %.0f resumes/s (%.6f s)\n", $direct_rate, $direct_seconds;
printf "direct/future %.3fx\n", $ratio;
say "future samples: " . join(' ', map { sprintf '%.6f', $_ } $samples{future}->@*);
say "direct samples: " . join(' ', map { sprintf '%.6f', $_ } $samples{direct}->@*);
