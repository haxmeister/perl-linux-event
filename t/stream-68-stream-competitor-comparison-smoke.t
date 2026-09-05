use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP qw(decode_json);

my $dir = tempdir(CLEANUP => 1);
my $script = "$Bin/../bench/run-stream-competitor-comparison.pl";
my @systems = ('linuxevent');
my @optional = (
    ['anyevent-handle', q{require AnyEvent; require AnyEvent::Handle; require EV; 1}],
    ['uv-tcp', q{require UV; require UV::Loop; require UV::Poll; require UV::TCP; 1}],
    ['ioasync-stream', q{require IO::Async::Loop::Epoll; require IO::Async::Stream; 1}],
    ['mojo-stream', q{require Mojo::Reactor::Epoll; require Mojo::IOLoop::Stream; 1}],
);
for my $candidate (@optional) {
    my ($system, $probe) = @$candidate;
    if (eval $probe) {
        push @systems, $system;
    }
    else {
        note "$system optional smoke skipped: dependencies unavailable";
    }
}

for my $system (@systems) {
  for my $workload (qw(raw delimiter)) {
    my $json = "$dir/$system-$workload.json";
    my $html = "$dir/$system-$workload.html";
    my @cmd = (
        $^X, '-Mblib', $script,
        "--systems=$system", '--clients=4',
        '--warmup=1', '--messages=3', '--bytes=16',
        '--client-workers=2', '--repeats=1', '--timeout=10',
        "--workload=$workload", "--json=$json", "--out=$html",
    );

    is(system(@cmd), 0,
        "$system $workload Stream comparison smoke run exits cleanly");
    ok(-s $json, "$system $workload JSON report written");
    ok(-s $html, "$system $workload HTML report written");

    open my $fh, '<', $json or die "open $json: $!";
    my $report = decode_json(do { local $/; <$fh> });
    close $fh;

    is($report->{benchmark_contract_version}, 1,
        "$system $workload benchmark contract version recorded");
    is($report->{fairness_contract}{workload}, $workload,
        "$system $workload fairness contract recorded");
    ok($report->{fairness_contract}{stream_construction_outside_timing},
        "$system $workload Stream construction is outside timing");

    my $row = $report->{results}[0];
    ok($row->{ok}, "$system $workload row is rankable")
        or diag($row->{failure_reason} // 'no failure reason');
    is($row->{system_key}, $system, "$system adapter recorded");
    is($row->{messages}, 12,
        "$system $workload measured message count exact");
    is($row->{latency_samples}, 12,
        "$system $workload records one latency sample per measured reply");
    is($row->{payload_bytes}, 16,
        "$system $workload payload size recorded");
    is($row->{bytes_read}, 12 * $row->{wire_bytes_per_message},
        "$system $workload received wire bytes exact");
    is($row->{bytes_queued}, 12 * $row->{wire_bytes_per_message},
        "$system $workload queued wire bytes exact");
    is($row->{callback_reuse}, 'one shared input CV per case',
        "$system $workload reuses its input closure");
    if ($system eq 'linuxevent') {
        like($row->{callback_api}, qr/^constructor on_(?:data|message) closure/,
            "$workload records the first-class callback API");
    }
    is($row->{unexpected_closes}, 0,
        "$system $workload has no close during measurement");
    is($report->{summary}[0]{throughput_rank}, 1,
        "$system $workload summary emits an explicit throughput rank");
  }
}

done_testing;
