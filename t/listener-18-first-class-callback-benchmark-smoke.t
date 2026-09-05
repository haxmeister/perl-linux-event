use v5.36;
use strict;
use warnings;

use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use Test::More;

my $directory = tempdir(CLEANUP => 1);
my $json = "$directory/callback-construction.json";
my $script = "$Bin/../bench/run-first-class-callback-construction-bench.pl";
my @command = (
    $^X, '-Mblib', $script,
    '--clients=2', '--connections=20', '--repeats=1', "--json=$json",
);
my $output = qx{@command 2>&1};
is($?, 0, 'first-class callback construction benchmark succeeds')
    or diag $output;
for my $style (qw(
    subclass_method listener_shared_closure fresh_closure
)) {
    like($output, qr/^\Q$style\E repeat=1 /m, "$style row runs");
}

open my $fh, '<', $json or die "open $json: $!";
my $report = decode_json(do { local $/; <$fh> });
close $fh;
is($report->{benchmark},
    'linux-event-first-class-callback-construction',
    'JSON identifies benchmark contract');
is(scalar @{ $report->{raw} }, 3, 'JSON retains every raw row');
is(scalar @{ $report->{summary} }, 3, 'JSON summarizes every style');
my %row = map { $_->{style} => $_ } @{ $report->{raw} };
is($row{subclass_method}{fresh_closures_created}, 0,
    'subclass baseline allocates no closure per accept');
is($row{listener_shared_closure}{fresh_closures_created}, 0,
    'Listener-shared case allocates no closure per accept');
is($row{fresh_closure}{fresh_closures_created}, 20,
    'diagnostic allocates exactly one closure per accepted Stream');

done_testing;
