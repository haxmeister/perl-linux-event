use v5.36;
use strict;
use warnings;
use Test::More;

my $cmd = join ' ',
    $^X,
    'bench/run-stream-microbench.pl',
    '--clients', 1,
    '--warmup', 1,
    '--messages', 5,
    '--bytes', 16,
    '--repeats', 1,
    '2>&1';

my $out = qx{$cmd};
is($?, 0, 'reference microbenchmark exits successfully') or diag $out;
like($out, qr/raw clients=1/, 'raw baseline ran');
like($out, qr/reference-stream clients=1/, 'Perl reference Stream baseline ran');
like($out, qr/xs-read-stream clients=1/, 'XS-read Stream ran');
like($out, qr/xs-rw-stream clients=1/, 'XS read+write Stream ran');
like($out, qr/Median Stream microbenchmark/, 'summary emitted');

done_testing;
