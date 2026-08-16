use v5.36;
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $script = "$Bin/../bench/run-connect-microbench.pl";
ok(-s $script, 'Connect lifecycle benchmark is present');

my $output = qx{$^X -Mblib "$script" --help 2>&1};
is($?, 0, 'Connect lifecycle benchmark help exits successfully');
like($output, qr/--connections=N/, 'benchmark help documents connection count');
like($output, qr/raw,stream/, 'benchmark help documents both ownership rows');

done_testing;
