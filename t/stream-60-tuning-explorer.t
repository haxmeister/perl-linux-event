use v5.36;
use strict;
use warnings;

use Test::More;
use File::Spec;

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

done_testing;
