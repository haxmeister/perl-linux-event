#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Benchmark qw(cmpthese timethese);
use Getopt::Long qw(GetOptions);

my $iterations = 20_000_000;
my $count      = -3;

GetOptions(
    'iterations=i' => \$iterations,
    'count=i'      => \$count,
) or die usage();

die "iterations must be > 0\n" unless $iterations > 0;

{
    package LinuxEventBench::Receiver;

    sub new ($class) {
        return bless { sum => 0 }, $class;
    }

    sub on_data ($self, $value) {
        $self->{sum} += $value;
        return;
    }
}

my $receiver = LinuxEventBench::Receiver->new;
my $method_cv = LinuxEventBench::Receiver->can('on_data');

my $plain_sum = 0;
my $plain_cb = sub ($target, $value) {
    $plain_sum += $value;
    return;
};

my $captured_one = 0;
my $closure_one = sub ($target, $value) {
    $captured_one += $value;
    return;
};

my $captured_a = 0;
my $captured_b = 1;
my $captured_c = 2;
my $captured_d = 3;
my $closure_many = sub ($target, $value) {
    $captured_a += $value;
    $captured_b += 0;
    $captured_c += 0;
    $captured_d += 0;
    return;
};

my %case = (
    'method lookup' => sub {
        for (1 .. $iterations) {
            $receiver->on_data(1);
        }
    },
    'cached method CV' => sub {
        for (1 .. $iterations) {
            $method_cv->($receiver, 1);
        }
    },
    'cached coderef' => sub {
        for (1 .. $iterations) {
            $plain_cb->($receiver, 1);
        }
    },
    'closure 1 lexical' => sub {
        for (1 .. $iterations) {
            $closure_one->($receiver, 1);
        }
    },
    'closure 4 lexicals' => sub {
        for (1 .. $iterations) {
            $closure_many->($receiver, 1);
        }
    },
);

print "Callback scope dispatch microbenchmark\n";
print "Per timed iteration: $iterations callback invocations\n";
print "This isolates Perl CV invocation. It does not measure epoll, I/O, framing,\n";
print "or the XS-to-Perl call boundary. The next experiment should cache supplied\n";
print "closure SVs in the native descriptor and measure the real Stream path if\n";
print "this result shows lexical capture itself is inexpensive.\n\n";

my $result = timethese($count, \%case, 'none');
cmpthese($result);

# Keep the mutations observable and make accidental optimization obvious.
my $expected_min = $iterations;
die "method case did not execute\n" unless $receiver->{sum} >= $expected_min;
die "coderef case did not execute\n" unless $plain_sum >= $expected_min;
die "one-lexical closure did not execute\n" unless $captured_one >= $expected_min;
die "many-lexical closure did not execute\n" unless $captured_a >= $expected_min;

sub usage {
    return <<'USAGE';
Usage:
  perl bench/run-callback-scope-microbench.pl [--iterations N] [--count N]

The benchmark compares repeated invocation of:
  * normal method lookup
  * a method CV resolved once with ->can
  * a cached coderef
  * a cached closure capturing one lexical
  * a cached closure capturing four lexicals

Benchmark count follows Benchmark.pm semantics. The default -3 runs each case
for at least three CPU seconds.
USAGE
}
