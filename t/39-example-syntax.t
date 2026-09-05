use v5.36;
use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;

my @example = sort glob "$Bin/../examples/*.pl";
ok(@example, 'distribution contains examples');

for my $path (@example) {
    my $status = system(
        $^X, "-I$Bin/../blib/lib", "-I$Bin/../blib/arch", '-c', $path,
    );
    my $name = $path =~ s{.*/}{}r;
    is($status >> 8, 0, "$name compiles");
}

done_testing;
