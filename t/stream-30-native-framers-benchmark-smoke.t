use v5.36;
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);
use IPC::Open3 qw(open3);
use JSON::PP qw(decode_json);
use Symbol qw(gensym);

my $script = "$Bin/../bench/run-native-framers-microbench.pl";
my @cmd = (
    $^X,
    $script,
    '--framers=fixed,length,u32be,netstring,varint,decimal',
    '--clients=1',
    '--warmup=1',
    '--messages=5',
    '--bytes=8',
    '--repeats=2',
);

my $err = gensym;
my $pid = open3(my $in, my $out, $err, @cmd);
close $in;

my $stdout = do { local $/; <$out> // '' };
my $stderr = do { local $/; <$err> // '' };
waitpid($pid, 0);

my $status = $?;
my $output = $stdout . $stderr;

is($status, 0, 'native-framers benchmark smoke exits successfully') or diag $output;
like($output, qr/fixed\/native\s+clients=1/, 'fixed native row ran');
like($output, qr/length\/native\s+clients=1/, 'length native row ran');
like($output, qr/u32be\/native\s+clients=1/, 'u32be native row ran');
like($output, qr/netstring\/native\s+clients=1/, 'netstring native row ran');
like($output, qr/varint\/native\s+clients=1/, 'varint native row ran');
like($output, qr/decimal\/native\s+clients=1/, 'decimal-length native row ran');

my ($json_fh, $json_path) = tempfile();
close $json_fh;
my @send_cmd = (
    $^X,
    "$Bin/../bench/run-framer-send-bench.pl",
    '--sizes=64',
    '--framers=length,varint',
    '--repeats=1',
    '--warmup=0',
    '--target-bytes=640',
    '--min-messages=10',
    '--max-messages=10',
    '--variant=smoke',
    '--commit=test',
    "--output=$json_path",
);
is(system(@send_cmd), 0, 'framer send benchmark smoke exits successfully');
open my $report_fh, '<:raw', $json_path or die "open $json_path: $!";
my $report = decode_json(do { local $/; <$report_fh> });
close $report_fh;
is($report->{benchmark}, 'framer-send', 'send benchmark JSON names its contract');
is(scalar @{ $report->{samples} }, 2,
    'send benchmark retains one raw sample per framer');
for my $case (qw(length/64 varint/64)) {
    my $effective = $report->{effective_config_by_case}{$case};
    is($effective->{transport}, 'AF_UNIX SOCK_STREAM socketpair',
        "$case records its transport");
    ok(exists $effective->{read_size}, "$case records Stream tuning");
    ok(exists $effective->{framer_parameters},
        "$case records framer parameters");
}

done_testing;
