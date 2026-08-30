use v5.36;
use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use JSON::PP qw(decode_json);
use Symbol qw(gensym);
use Test::More;

my $bench = File::Spec->catfile('bench', 'run-stream-tuning-sweep.pl');
my $html = File::Spec->catfile('tools', 'stream-tuning-explorer', 'index.html');
my $readme = File::Spec->catfile('tools', 'stream-tuning-explorer', 'README.md');
my $js = File::Spec->catfile('tools', 'stream-tuning-explorer', 'explorer.js');
my $css = File::Spec->catfile('tools', 'stream-tuning-explorer', 'explorer.css');

ok -f $bench, 'Stream tuning sweep benchmark is present';
ok -f $html, 'Stream tuning explorer HTML is present';
ok -f $readme, 'Stream tuning explorer documentation is present';
ok -f $js, 'Stream tuning explorer JavaScript is present';
ok -f $css, 'Stream tuning explorer stylesheet is present';

open my $bfh, '<', $bench or die "open $bench: $!";
my $bench_text = do { local $/; <$bfh> };
close $bfh;
like $bench_text, qr/linux-event-stream-tuning-sweep/,
    'benchmark declares tuning sweep contract';
like $bench_text, qr/read_budget_bytes/,
    'benchmark sweeps read budget';
like $bench_text, qr/message_batch_size/,
    'benchmark sweeps framed callback batching';
like $bench_text, qr/read_batch_bytes/,
    'benchmark sweeps raw callback batching';
like $bench_text, qr{\.\./blib/arch.*\.\./lib}s,
    'benchmark roots itself to the current checkout build';

open my $hfh, '<', $html or die "open $html: $!";
my $html_text = do { local $/; <$hfh> };
close $hfh;
open my $jfh, '<', $js or die "open $js: $!";
my $js_text = do { local $/; <$jfh> };
close $jfh;

like $js_text, qr/EXACT MEASURED/,
    'UI identifies exact measured data';
like $js_text, qr/MEASURED INTERPOLATION/,
    'UI identifies interpolated measured data';
like $html_text, qr/HEURISTIC PREVIEW/,
    'UI labels unmeasured preview data';
like $html_text, qr/Copy stream_options/,
    'UI can export selected Stream policy';

# Keep the artifact dependency-free so it works from a CPAN checkout without
# npm, a CDN, or a local web service. Local CSS/JS files are intentional.
unlike $html_text, qr/(?:src|href)=["']https?:/i,
    'UI has no external browser dependency';
like $html_text, qr/src=["']explorer\.js["']/i,
    'UI loads the local JavaScript implementation';
like $html_text, qr/href=["']explorer\.css["']/i,
    'UI loads the local stylesheet';

my $dir = tempdir(CLEANUP => 1);
my $json = "$dir/stream-tuning.json";
my $script = "$Bin/../bench/run-stream-tuning-sweep.pl";
my @cmd = (
    $^X, $script,
    '--modes=framed', '--transports=unix',
    '--message-sizes=16,64', '--read-sizes=4096',
    '--read-budgets=0', '--message-batch-sizes=0,4',
    '--max-buffers=8388608', '--target-bytes=4096',
    '--min-messages=32', '--max-messages=32',
    '--warmup=0', '--repeats=1', "--json=$json",
);

my $err = gensym;
my $pid = open3(my $in, my $out, $err, @cmd);
close $in;
my $stdout = do { local $/; <$out> // '' };
my $stderr = do { local $/; <$err> // '' };
waitpid($pid, 0);
is($?, 0, 'tuning sweep executes against the current built Stream without external include flags')
    or diag $stdout . $stderr;

SKIP: {
    skip 'benchmark sweep failed', 5 if $? != 0 || !-f $json;
    open my $fh, '<', $json or die "open benchmark JSON: $!";
    my $report = decode_json(do { local $/; <$fh> });
    close $fh;
    is($report->{benchmark}, 'linux-event-stream-tuning-sweep',
        'smoke report identifies tuning contract');
    is($report->{benchmark_contract_version}, 1,
        'smoke report uses contract version 1');
    is(scalar @{ $report->{series} }, 2,
        'smoke report contains both batch configurations');
    is(scalar @{ $report->{raw} }, 4,
        'smoke report contains every measured point');
    ok(!grep({ ($_->{median_messages_per_second} // 0) <= 0 }
        map { @{ $_->{points} } } @{ $report->{series} }),
        'every smoke point reports positive throughput');
}

done_testing;
