use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use JSON::PP qw(decode_json);
use Symbol qw(gensym);

my $dir = tempdir(CLEANUP => 1);
my $json = "$dir/cached-closure-raw-dispatch.json";
my $script = "$Bin/../bench/run-cached-closure-raw-dispatch-bench.pl";
my @cmd = (
    $^X, '-Mblib', $script,
    '--read-sizes=16', '--idle-connections=0',
    '--target-mib=0.015625', '--minimum-deliveries=100',
    '--warmup=0', '--repeats=1', "--json=$json",
);

my $err = gensym;
my $pid = open3(my $in, my $out, $err, @cmd);
close $in;
my $stdout = do { local $/; <$out> // '' };
my $stderr = do { local $/; <$err> // '' };
waitpid($pid, 0);

is($?, 0, 'cached-closure raw dispatch benchmark exits successfully')
    or diag $stdout . $stderr;
for my $case (qw(
    subclass_method constructor_coderef closure_one closure_four
)) {
    like($stdout, qr/^\Q$case\E read=16 idle=0 repeat=1/m,
        "$case row ran");
}

open my $fh, '<', $json or die "open benchmark JSON: $!";
my $report = decode_json(do { local $/; <$fh> });
close $fh;
is($report->{benchmark}, 'linux-event-cached-closure-raw-native-dispatch',
    'report identifies raw benchmark contract');
is($report->{configuration}{read_batch_bytes}, 0,
    'raw benchmark disables read batching');
is(scalar @{ $report->{raw} }, 4,
    'report retains one raw result per callback case');
is(scalar @{ $report->{summary} }, 4,
    'report summarizes every callback case');
is_deeply(
    [sort map { $_->{case} } @{ $report->{summary} }],
    [sort qw(subclass_method constructor_coderef closure_one closure_four)],
    'summary contains the four matched callback forms',
);
for my $row (@{ $report->{raw} }) {
    is($row->{bytes_read}, 16_384,
        "$row->{case} validates every raw byte");
    is($row->{frames_emitted}, 0,
        "$row->{case} stays on the raw delivery path");
    is($row->{callback_calls}, $row->{deliveries},
        "$row->{case} validates every raw callback invocation");
    cmp_ok($row->{deliveries}, '>=', 1_024,
        "$row->{case} performs at least the read-size callback count");
}

done_testing;
