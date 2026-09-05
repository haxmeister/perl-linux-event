use v5.36;
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP qw(decode_json);
use Symbol qw(gensym);

my $root = File::Spec->catdir($Bin, '..');
my $script = File::Spec->catfile($root, 'bench',
    'run-listen-microbench.pl');

my $help_command = qq{$^X -Mblib "$script" --help 2>&1};
my $help = qx{$help_command};
is($? >> 8, 0, 'Listen benchmark help exits successfully');
like($help, qr/Listen lifecycle benchmark|run-listen-microbench/,
    'Listen benchmark help identifies the permanent script');
like($help, qr/manual,add,loop/,
    'help lists raw baseline and both Listener attachment modes');
like($help, qr/--timeout=SECONDS/, 'help documents catastrophic deadline');
like($help, qr/--accepted-callbacks=LIST/,
    'help documents accepted Stream callback construction mode');
like($help, qr/subclass_method,shared_closure,fresh_closure/,
    'help lists all accepted Stream callback styles');

my $dir = tempdir(CLEANUP => 1);
my $json = File::Spec->catfile($dir, 'listener-callback-construction.json');
my @cmd = (
    $^X, '-Mblib', $script,
    '--accepted-callbacks=all',
    '--clients=2',
    '--connections=12',
    '--repeats=1',
    '--timeout=10',
    "--json=$json",
);
my $err = gensym;
my $pid = open3(my $in, my $out, $err, @cmd);
close $in;
my $stdout = do { local $/; <$out> // '' };
my $stderr = do { local $/; <$err> // '' };
waitpid($pid, 0);

is($?, 0, 'accepted Stream callback construction smoke run succeeds')
    or diag $stdout . $stderr;
like($stdout, qr/^Accepted Stream callback construction benchmark$/m,
    'smoke run identifies callback construction benchmark');
for my $style (qw(subclass_method shared_closure fresh_closure)) {
    like($stdout, qr/^\Q$style\E\s+2\s+/m, "$style summary row ran");
}

open my $json_fh, '<', $json or die "open benchmark JSON: $!";
my $report = decode_json(do { local $/; <$json_fh> });
close $json_fh;

is($report->{benchmark},
    'linux-event-accepted-stream-callback-construction',
    'JSON identifies accepted Stream callback construction contract');
is($report->{configuration}{connections}, 12,
    'JSON records accepted connection count');
is($report->{configuration}{parent_cpu_excludes_client_workers}, 1,
    'JSON records isolated parent CPU contract');
is(scalar @{ $report->{raw} }, 3,
    'one raw row is retained for each callback style');
is(scalar @{ $report->{summary} }, 3,
    'one summary row is retained for each callback style');

for my $row (@{ $report->{raw} }) {
    is($row->{accepted}, 12,
        "$row->{callback_style} accepted every connection");
    if ($row->{callback_style} eq 'fresh_closure') {
        is($row->{fresh_closures_created}, 12,
            'fresh closure mode allocates one closure per accepted Stream');
    } else {
        is($row->{fresh_closures_created}, 0,
            "$row->{callback_style} allocates no per-connection closures");
    }
    cmp_ok($row->{accepts_per_second}, '>', 0,
        "$row->{callback_style} reports positive accept throughput");
    cmp_ok($row->{parent_cpu_us_per_accept}, '>=', 0,
        "$row->{callback_style} reports non-negative parent CPU");
}

done_testing;
