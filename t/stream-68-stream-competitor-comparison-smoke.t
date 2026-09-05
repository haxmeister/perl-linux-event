use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP qw(decode_json);

my $dir = tempdir(CLEANUP => 1);
my $script = "$Bin/../bench/run-stream-competitor-comparison.pl";

for my $workload (qw(raw delimiter)) {
    my $json = "$dir/$workload.json";
    my $html = "$dir/$workload.html";
    my @cmd = (
        $^X, '-Mblib', $script,
        '--systems=linuxevent', '--clients=4',
        '--warmup=1', '--messages=3', '--bytes=16',
        '--client-workers=2', '--repeats=1', '--timeout=10',
        "--workload=$workload", "--json=$json", "--out=$html",
    );

    is(system(@cmd), 0, "$workload Stream comparison smoke run exits cleanly");
    ok(-s $json, "$workload JSON report written");
    ok(-s $html, "$workload HTML report written");

    open my $fh, '<', $json or die "open $json: $!";
    my $report = decode_json(do { local $/; <$fh> });
    close $fh;

    is($report->{benchmark_contract_version}, 1,
        "$workload benchmark contract version recorded");
    is($report->{fairness_contract}{workload}, $workload,
        "$workload fairness contract recorded");
    ok($report->{fairness_contract}{stream_construction_outside_timing},
        "$workload Stream construction is outside timing");

    my $row = $report->{results}[0];
    ok($row->{ok}, "$workload Linux::Event row is rankable")
        or diag($row->{failure_reason} // 'no failure reason');
    is($row->{messages}, 12, "$workload measured message count exact");
    is($row->{latency_samples}, 12,
        "$workload records one latency sample per measured reply");
    is($row->{payload_bytes}, 16, "$workload payload size recorded");
    is($row->{bytes_read}, 12 * $row->{wire_bytes_per_message},
        "$workload received wire bytes exact");
    is($row->{bytes_queued}, 12 * $row->{wire_bytes_per_message},
        "$workload queued wire bytes exact");
    is($row->{callback_reuse}, 'one shared input CV per case',
        "$workload uses the constructor closure under comparison");
    like($row->{callback_api}, qr/^constructor on_(?:data|message) closure/,
        "$workload records the first-class callback API");
    is($row->{unexpected_closes}, 0,
        "$workload has no close during measurement");
    is($report->{summary}[0]{throughput_rank}, 1,
        "$workload summary emits an explicit throughput rank");
}

done_testing;
