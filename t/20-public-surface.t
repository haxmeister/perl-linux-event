use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->catdir($Bin, '..');

for my $required (
    'README.md',
    'docs/CORE.md',
    'docs/ARCHITECTURE.md',
    'docs/XS-ROADMAP.md',
    'docs/DEVELOPMENT-HISTORY.md',
    'bench/README.md',
    'bench/run-reactor-comparison.pl',
    'bench/run-callback-ceiling.pl',
    'bench/archive/README.md',
) {
    ok(-s File::Spec->catfile($root, split m{/}, $required), "$required is present");
}

for my $live (
    'README.md',
    'docs/CORE.md',
    'docs/ARCHITECTURE.md',
    'docs/XS-ROADMAP.md',
    'bench/README.md',
    'bench/run-reactor-comparison.pl',
    'bench/run-callback-ceiling.pl',
) {
    my $path = File::Spec->catfile($root, split m{/}, $live);
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    unlike($src, qr/\b(?:Phase|phase)\d+[A-Za-z]?\b/, "$live has no development-phase vocabulary");
}

my @bench_root = sort map { s{^.*/}{}r }
    grep { -f $_ }
    glob(File::Spec->catfile($root, 'bench', '*'));
my %allowed = map { $_ => 1 } qw(README.md run-reactor-comparison.pl run-callback-ceiling.pl);
is_deeply([grep { !$allowed{$_} } @bench_root], [], 'bench root contains only current public files');

done_testing;
