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
my $json = "$dir/first-class-framed-callback.json";
my $script = "$Bin/../bench/run-first-class-framed-callback-bench.pl";
my @cmd = (
    $^X, '-Mblib', $script,
    '--payload-sizes=16', '--idle-connections=0',
    '--target-mib=0.015625', '--minimum-messages=100',
    '--warmup=0', '--repeats=1', "--json=$json",
);

my $err = gensym;
my $pid = open3(my $in, my $out, $err, @cmd);
close $in;
my $stdout = do { local $/; <$out> // '' };
my $stderr = do { local $/; <$err> // '' };
waitpid($pid, 0);

is($?, 0, 'first-class framed callback benchmark exits successfully')
    or diag $stdout . $stderr;
for my $case (qw(
    subclass_method constructor_coderef closure_one closure_four
)) {
    like($stdout, qr/^\Q$case\E bytes=16 idle=0 repeat=1/m,
        "$case row ran");
}

open my $fh, '<', $json or die "open benchmark JSON: $!";
my $report = decode_json(do { local $/; <$fh> });
close $fh;
is($report->{benchmark}, 'linux-event-first-class-framed-callback-dispatch',
    'report identifies benchmark contract');
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
    is($row->{frames_emitted}, 1024,
        "$row->{case} validates every native frame");
    is($row->{callback_calls}, 1024,
        "$row->{case} validates every callback invocation");
}

done_testing;
