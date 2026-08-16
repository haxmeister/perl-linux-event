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
    'docs/STREAM-DESIGN.md',
    'docs/TRANSPORT-BOUNDARY.md',
    'docs/CONNECT-DESIGN.md',
    'docs/CHOOSING-A-FRAMER.md',
    'docs/FRAMING.md',
    'bench/README.md',
    'bench/run-connect-microbench.pl',
    'bench/run-reactor-comparison.pl',
    'bench/run-callback-ceiling.pl',
    'bench/run-stream-lifecycle-bench.pl',
    'bench/run-stream-microbench.pl',
    'bench/run-tls-microbench.pl',
    'bench/run-stream-transition-bench.pl',
    'bench/run-framing-microbench.pl',
    'bench/run-native-framers-microbench.pl',
    'bench/archive/README.md',
    'lib/Linux/Event/TLS.pm',
    'lib/Linux/Event/Connect.pm',
    'lib/Linux/Event/Connect/Error.pm',
    'xstls/Makefile.PL',
    'xstls/TLS.xs',
    'xstls/check_openssl.c',
    'xsconnect/Makefile.PL',
    'xsconnect/Connect.xs',
) {
    ok(-s File::Spec->catfile($root, split m{/}, $required), "$required is present");
}

for my $live (
    'README.md',
    'docs/CORE.md',
    'docs/ARCHITECTURE.md',
    'docs/XS-ROADMAP.md',
    'docs/STREAM-DESIGN.md',
    'docs/TRANSPORT-BOUNDARY.md',
    'docs/CONNECT-DESIGN.md',
    'docs/CHOOSING-A-FRAMER.md',
    'docs/FRAMING.md',
    'bench/README.md',
    'bench/run-connect-microbench.pl',
    'bench/run-reactor-comparison.pl',
    'bench/run-callback-ceiling.pl',
    'bench/run-stream-lifecycle-bench.pl',
    'bench/run-stream-microbench.pl',
    'bench/run-tls-microbench.pl',
    'bench/run-stream-transition-bench.pl',
    'bench/run-framing-microbench.pl',
    'bench/run-native-framers-microbench.pl',
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
my %allowed = map { $_ => 1 } qw(
    README.md
    STREAM-COMPETITOR-PLAN.md
    run-connect-microbench.pl
    run-reactor-comparison.pl
    run-callback-ceiling.pl
    run-stream-lifecycle-bench.pl
    run-stream-microbench.pl
    run-tls-microbench.pl
    run-stream-transition-bench.pl
    run-framing-microbench.pl
    run-native-framers-microbench.pl
);
is_deeply([grep { !$allowed{$_} } @bench_root], [], 'bench root contains only current public files');
ok(!-d File::Spec->catdir($root, 'tls'),
    'TLS does not have a nested distribution tree');

done_testing;
