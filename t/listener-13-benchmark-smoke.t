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
    'help lists legacy accepted Stream callback styles');
like($help, qr/native_seed_shared_closure/,
    'help lists native-seed accepted Stream callback styles');
like($help, qr/Listener->on_accept/,
    'help documents reliable Listener completion event');

my $dir = tempdir(CLEANUP => 1);

sub run_matrix ($spec, $name) {
    my $json = File::Spec->catfile($dir, "$name.json");
    my @cmd = (
        $^X, '-Mblib', $script,
        "--accepted-callbacks=$spec",
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

    is($?, 0, "$name progress run succeeds")
        or diag $stdout . $stderr;
    like($stdout,
        qr/^Accepted Stream callback construction benchmark - progress driver$/m,
        "$name identifies benchmark");
    like($stdout, qr/^\[1\/3\] START /m,
        "$name prints first row immediately");
    like($stdout, qr/^\[3\/3\] DONE /m,
        "$name reports final completed row");
    like($stdout, qr/^Final paired summary$/m,
        "$name prints final paired summary");

    open my $json_fh, '<', $json or die "open benchmark JSON: $!";
    my $report = decode_json(do { local $/; <$json_fh> });
    close $json_fh;
    return $report;
}

my $legacy = run_matrix('all', 'legacy');
is($legacy->{benchmark},
    'linux-event-accepted-stream-callback-construction',
    'legacy JSON identifies callback construction contract');
is($legacy->{status}, 'complete', 'legacy JSON reaches complete status');
is($legacy->{progress}{completed_rows}, 3,
    'legacy JSON records all completed rows');
is($legacy->{progress}{total_rows}, 3,
    'legacy JSON records expected row count');
is($legacy->{configuration}{completion_event}, 'listener_on_accept',
    'legacy JSON records Listener completion event');
is($legacy->{configuration}{clients_wait_for_server_close}, 1,
    'legacy JSON records race-free client lifetime contract');
is(scalar @{ $legacy->{raw} }, 3,
    'legacy retains one raw row for each callback style');
is(scalar @{ $legacy->{summary} }, 3,
    'legacy retains one summary row for each callback style');

for my $row (@{ $legacy->{raw} }) {
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

my $native = run_matrix('native_seed', 'native-seed');
is($native->{status}, 'complete',
    'native-seed JSON reaches complete status');
is($native->{configuration}{native_seed_matrix}, 1,
    'native-seed JSON identifies direct native-state construction matrix');
is_deeply(
    $native->{configuration}{callback_styles},
    [qw(
        native_seed_method
        native_seed_shared_closure
        native_seed_fresh_closure
    )],
    'native-seed JSON records all three direct construction styles',
);
is(scalar @{ $native->{raw} }, 3,
    'native-seed retains one raw row for each callback style');
is(scalar @{ $native->{summary} }, 3,
    'native-seed retains one summary row for each callback style');

for my $row (@{ $native->{raw} }) {
    is($row->{accepted}, 20,
        "$row->{callback_style} accepted every connection");
    if ($row->{callback_style} eq 'native_seed_fresh_closure') {
        is($row->{fresh_closures_created}, 20,
            'native-seed fresh mode allocates one closure per accepted Stream');
    } else {
        is($row->{fresh_closures_created}, 0,
            "$row->{callback_style} allocates no per-connection closures");
    }
}

my %summary = map { $_->{callback_style} => $_ } @{ $native->{summary} };
ok(!defined($summary{native_seed_method}{throughput_delta_percent}),
    'native-seed method is the paired baseline');
ok(defined($summary{native_seed_shared_closure}{throughput_delta_percent}),
    'native-seed shared closure reports paired throughput delta');
ok(defined($summary{native_seed_shared_closure}{parent_cpu_delta_percent}),
    'native-seed shared closure reports paired CPU delta');
ok(defined($summary{native_seed_fresh_closure}{throughput_delta_percent}),
    'native-seed fresh closure reports paired throughput delta');
ok(defined($summary{native_seed_fresh_closure}{parent_cpu_delta_percent}),
    'native-seed fresh closure reports paired CPU delta');

done_testing;
