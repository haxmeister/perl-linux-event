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
my $script = File::Spec->catfile(
    $root, 'bench', 'tools', 'run-listen-callback-construction-progress.pl',
);

my $help_command = qq{$^X -Mblib "$script" --help 2>&1};
my $help = qx{$help_command};
is($? >> 8, 0, 'callback construction progress help exits successfully');
like($help, qr/run-listen-callback-construction-progress/,
    'help identifies progress driver');
like($help, qr/subclass_method,shared_closure,fresh_closure/,
    'help lists all accepted Stream callback styles');
like($help, qr/Listener->on_accept/,
    'help documents reliable Listener completion event');

my $dir = tempdir(CLEANUP => 1);
my $json = File::Spec->catfile($dir, 'listener-callback-construction.json');
my @cmd = (
    $^X, '-Mblib', $script,
    '--accepted-callbacks=all',
    '--clients=2',
    '--connections=20',
    '--repeats=1',
    '--timeout=10',
    '--heartbeat=0.1',
    "--json=$json",
);

my $err = gensym;
my $pid = open3(my $in, my $out, $err, @cmd);
close $in;
my $stdout = do { local $/; <$out> // '' };
my $stderr = do { local $/; <$err> // '' };
waitpid($pid, 0);

is($?, 0, 'accepted Stream callback construction progress run succeeds')
    or diag $stdout . $stderr;
like($stdout, qr/^Accepted Stream callback construction benchmark - progress driver$/m,
    'progress run identifies benchmark');
like($stdout, qr/^\[1\/3\] START /m,
    'progress run prints first row immediately');
like($stdout, qr/^\[3\/3\] DONE /m,
    'progress run reports final completed row');
like($stdout, qr/^Final paired summary$/m,
    'progress run prints final paired summary');

open my $json_fh, '<', $json or die "open benchmark JSON: $!";
my $report = decode_json(do { local $/; <$json_fh> });
close $json_fh;

is($report->{benchmark},
    'linux-event-accepted-stream-callback-construction',
    'JSON identifies accepted Stream callback construction contract');
is($report->{status}, 'complete', 'JSON checkpoint reaches complete status');
is($report->{progress}{completed_rows}, 3,
    'JSON records all completed rows');
is($report->{progress}{total_rows}, 3,
    'JSON records expected row count');
is($report->{configuration}{completion_event}, 'listener_on_accept',
    'JSON records Listener completion event');
is($report->{configuration}{clients_wait_for_server_close}, 1,
    'JSON records race-free client lifetime contract');
is(scalar @{ $report->{raw} }, 3,
    'one raw row is retained for each callback style');
is(scalar @{ $report->{summary} }, 3,
    'one summary row is retained for each callback style');

for my $row (@{ $report->{raw} }) {
    is($row->{accepted}, 20,
        "$row->{callback_style} accepted every connection");
    if ($row->{callback_style} eq 'fresh_closure') {
        is($row->{fresh_closures_created}, 20,
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
