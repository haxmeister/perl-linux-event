use v5.36;
use strict;
use warnings;
use Test::More;

my $out = qx{$^X bench/run-framing-microbench.pl --clients 1 --warmup 1 --messages 5 --bytes 16 --repeats 1 2>&1};
is($?, 0, 'framing microbenchmark exits successfully') or diag $out;
like($out, qr/perl-buffer clients=1/, 'Perl buffer/framer path ran');
like($out, qr/xs-buffer-perl clients=1/, 'native buffer/custom Perl framer path ran');
like($out, qr/xs-delimiter clients=1/, 'native delimiter path ran');
like($out, qr/Median framing microbenchmark/, 'framing summary emitted');

done_testing;
