use v5.36;
use strict;
use warnings;

use Test::More;
use File::Spec;

my $bench = File::Spec->catfile('bench', 'run-stream-tuning-sweep.pl');
my $html = File::Spec->catfile('tools', 'stream-tuning-explorer', 'index.html');
my $readme = File::Spec->catfile('tools', 'stream-tuning-explorer', 'README.md');

ok -f $bench, 'Stream tuning sweep benchmark is present';
ok -f $html, 'Stream tuning explorer HTML is present';
ok -f $readme, 'Stream tuning explorer documentation is present';

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

open my $hfh, '<', $html or die "open $html: $!";
my $html_text = do { local $/; <$hfh> };
close $hfh;
like $html_text, qr/EXACT MEASURED/,
    'UI identifies exact measured data';
like $html_text, qr/MEASURED INTERPOLATION/,
    'UI identifies interpolated measured data';
like $html_text, qr/HEURISTIC PREVIEW/,
    'UI labels unmeasured preview data';
like $html_text, qr/Copy stream_options/,
    'UI can export selected Stream policy';

# Keep the artifact dependency-free so it works from a CPAN checkout without
# npm, a CDN, or a local web service.
unlike $html_text, qr/<script\s+src=/i,
    'UI has no external JavaScript dependency';
unlike $html_text, qr/<link\s+[^>]*href=["']https?:/i,
    'UI has no external stylesheet dependency';

done_testing;
