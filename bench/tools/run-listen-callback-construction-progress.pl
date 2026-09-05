#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

$| = 1;

my @clients = (1, 10, 100);
my $connections = 10_000;
my $repeats = 9;
my $timeout = 30;
my $callback_spec = 'all';
my $json_path = 'bench/results/accepted-stream-callback-construction.json';
my $heartbeat = 5;
my $help = 0;

GetOptions(
    'clients=s'            => sub { @clients = map { 0 + $_ } split /,/, $_[1] },
    'connections=i'        => \$connections,
    'repeats=i'            => \$repeats,
    'timeout=f'            => \$timeout,
    'accepted-callbacks=s' => \$callback_spec,
    'json=s'               => \$json_path,
    'heartbeat=f'          => \$heartbeat,
    'help'                 => \$help,
) or usage(1);
usage(0) if $help;

die "connections must be positive\n" if $connections < 1;
die "repeats must be positive\n" if $repeats < 1;
die "timeout must be positive\n" if $timeout <= 0;
die "heartbeat must be positive\n" if $heartbeat <= 0;
die "clients must be positive\n" if grep { $_ < 1 } @clients;
die "clients must not exceed connections\n"
    if grep { $_ > $connections } @clients;

my @styles = $callback_spec eq 'all'
    ? qw(subclass_method shared_closure fresh_closure)
    : split /,/, $callback_spec;
my %valid = map { $_ => 1 } qw(subclass_method shared_closure fresh_closure);
die "accepted-callbacks must contain subclass_method, shared_closure, "
    . "fresh_closure, or all\n"
    if !@styles || grep { !$valid{$_} } @styles;
my %seen;
die "accepted-callbacks must not contain duplicates\n"
    if grep { $seen{$_}++ } @styles;
die "accepted-callbacks must include subclass_method for paired deltas\n"
    if !grep { $_ eq 'subclass_method' } @styles;

my $engine = "$Bin/run-listen-callback-construction-row.pl";
die "benchmark row runner not found: $engine\n" if !-f $engine;

my $total_rows = @clients * $repeats * @styles;
my $completed = 0;
my @raw;

say 'Accepted Stream callback construction benchmark - progress driver';
say "connections=$connections repeats=$repeats clients=" . join(',', @clients)
    . ' callbacks=' . join(',', @styles);
say "JSON checkpoint: $json_path";
say "Total measurement rows: $total_rows";
say '';

write_report('running', \@raw, [], $completed, $total_rows);

for my $client_count (@clients) {
    for my $repeat (1 .. $repeats) {
        my $offset = ($repeat - 1) % @styles;
        my @order = (
            @styles[$offset .. $#styles],
            @styles[0 .. $offset - 1],
        );

        for my $style (@order) {
            my $row_number = $completed + 1;
            printf "[%d/%d] START clients=%d repeat=%d callback=%s\n",
                $row_number, $total_rows, $client_count, $repeat, $style;

            my $row = run_row(
                $style, $client_count, $repeat, $row_number, $total_rows,
            );
            push @raw, $row;
            $completed++;

            printf "[%d/%d] DONE  clients=%d repeat=%d callback=%s "
                . "%.1f accepts/s %.3f parent-cpu-us/accept",
                $completed, $total_rows, $client_count, $repeat, $style,
                $row->{accepts_per_second},
                $row->{parent_cpu_us_per_accept};
            printf " fresh-closures=%d", $row->{fresh_closures_created}
                if $style eq 'fresh_closure';
            say '';

            write_report('running', \@raw, [], $completed, $total_rows);
        }
    }
}

my @summary = summarize(\@raw);
write_report('complete', \@raw, \@summary, $completed, $total_rows);

say '';
say 'Final paired summary';
printf "%-20s %8s %14s %16s %10s %10s\n",
    'callback', 'clients', 'accepts/s', 'parent cpu us', 'speed', 'cpu';
for my $row (@summary) {
    printf "%-20s %8d %14.1f %16.3f %9s %9s\n",
        $row->{callback_style},
        $row->{clients},
        $row->{median_accepts_per_second},
        $row->{median_parent_cpu_us_per_accept},
        defined($row->{throughput_delta_percent})
            ? sprintf('%+.2f%%', $row->{throughput_delta_percent}) : '-',
        defined($row->{parent_cpu_delta_percent})
            ? sprintf('%+.2f%%', $row->{parent_cpu_delta_percent}) : '-';
}
say "Final JSON: $json_path";

sub run_row ($style, $client_count, $repeat, $row_number, $total) {
    my $dir = tempdir(CLEANUP => 1);
    my $row_json = "$dir/row.json";
    my $stdout_path = "$dir/stdout.txt";
    my $stderr_path = "$dir/stderr.txt";

    my @cmd = (
        $^X, '-Mblib', $engine,
        "--accepted-callbacks=$style",
        "--clients=$client_count",
        "--connections=$connections",
        '--repeats=1',
        "--timeout=$timeout",
        "--json=$row_json",
    );

    my $pid = fork();
    die "benchmark row fork: $!\n" if !defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', $stdout_path or die "open child stdout: $!\n";
        open STDERR, '>', $stderr_path or die "open child stderr: $!\n";
        exec @cmd;
        die "exec benchmark row runner: $!\n";
    }

    my $started = time;
    my $next_heartbeat = $started + $heartbeat;
    my $hard_limit = $timeout + 20;
    my $status;

    while (1) {
        my $waited = waitpid($pid, WNOHANG);
        if ($waited == $pid) {
            $status = $?;
            last;
        }
        die "waitpid benchmark row: $!\n" if $waited < 0;

        my $now = time;
        if ($now >= $next_heartbeat) {
            printf "[%d/%d] ... clients=%d repeat=%d callback=%s "
                . "still running (%.0fs)\n",
                $row_number, $total, $client_count, $repeat, $style,
                $now - $started;
            $next_heartbeat = $now + $heartbeat;
        }

        if ($now - $started > $hard_limit) {
            kill 'TERM', $pid;
            sleep 0.2;
            kill 'KILL', $pid if waitpid($pid, WNOHANG) == 0;
            waitpid($pid, 0);
            my $stdout = slurp_if_exists($stdout_path);
            my $stderr = slurp_if_exists($stderr_path);
            die "benchmark row exceeded hard limit of ${hard_limit}s: "
                . "clients=$client_count repeat=$repeat callback=$style\n"
                . $stdout . $stderr;
        }
        sleep 0.1;
    }

    if ($status != 0) {
        my $stdout = slurp_if_exists($stdout_path);
        my $stderr = slurp_if_exists($stderr_path);
        die "benchmark row failed with status $status\n$stdout$stderr";
    }
    die "benchmark row did not produce JSON: $row_json\n" if !-s $row_json;

    open my $fh, '<', $row_json or die "open row JSON: $!\n";
    my $report = JSON::PP->new->decode(do { local $/; <$fh> });
    close $fh;
    die "unexpected benchmark contract in row JSON\n"
        if ($report->{benchmark} // '')
            ne 'linux-event-accepted-stream-callback-construction';
    die "expected one raw row\n" if @{ $report->{raw} // [] } != 1;

    my $row = { %{ $report->{raw}[0] } };
    $row->{repeat} = $repeat;
    return $row;
}

sub summarize ($raw) {
    my @summary;
    for my $client_count (@clients) {
        my @baseline = grep {
            $_->{callback_style} eq 'subclass_method'
                && $_->{clients} == $client_count
        } @$raw;

        for my $style (@styles) {
            my @rows = grep {
                $_->{callback_style} eq $style
                    && $_->{clients} == $client_count
            } @$raw;
            next if !@rows;

            my $summary = {
                callback_style => $style,
                clients => $client_count,
                median_accepts_per_second => median(
                    map { $_->{accepts_per_second} } @rows,
                ),
                median_parent_cpu_us_per_accept => median(
                    map { $_->{parent_cpu_us_per_accept} } @rows,
                ),
                median_fresh_closures_created => median(
                    map { $_->{fresh_closures_created} } @rows,
                ),
            };

            if ($style ne 'subclass_method' && @baseline) {
                my (@speed, @cpu);
                for my $row (@rows) {
                    my ($paired) = grep {
                        $_->{repeat} == $row->{repeat}
                    } @baseline;
                    next if !$paired;
                    push @speed, 100 * (
                        $row->{accepts_per_second}
                            / $paired->{accepts_per_second} - 1
                    );
                    push @cpu, 100 * (
                        $row->{parent_cpu_us_per_accept}
                            / $paired->{parent_cpu_us_per_accept} - 1
                    );
                }
                $summary->{throughput_delta_percent} = median(@speed)
                    if @speed;
                $summary->{parent_cpu_delta_percent} = median(@cpu)
                    if @cpu;
            }
            push @summary, $summary;
        }
    }
    return @summary;
}

sub write_report ($status, $raw, $summary, $done, $total) {
    return if !defined($json_path) || $json_path eq '';
    my $parent = dirname($json_path);
    die "JSON directory does not exist: $parent\n"
        if $parent ne '.' && !-d $parent;

    my $report = {
        benchmark => 'linux-event-accepted-stream-callback-construction',
        benchmark_contract_version => 1,
        status => $status,
        progress => {
            completed_rows => $done,
            total_rows => $total,
        },
        perl_version => 0 + $],
        configuration => {
            callback_styles => \@styles,
            clients => \@clients,
            connections => $connections,
            repeats => $repeats,
            timeout => 0 + $timeout,
            client_processes => 1,
            parent_cpu_excludes_client_workers => 1,
            completion_event => 'listener_on_accept',
            clients_wait_for_server_close => 1,
            progress_driver => 1,
        },
        raw => $raw,
        summary => $summary,
    };

    my $tmp = "$json_path.tmp.$$";
    open my $fh, '>', $tmp or die "open JSON checkpoint $tmp: $!\n";
    print {$fh} JSON::PP->new->canonical->pretty->encode($report);
    close $fh or die "close JSON checkpoint $tmp: $!\n";
    rename $tmp, $json_path
        or die "replace JSON checkpoint $json_path: $!\n";
    return;
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    my $middle = int(@values / 2);
    return @values % 2
        ? $values[$middle]
        : ($values[$middle - 1] + $values[$middle]) / 2;
}

sub slurp_if_exists ($path) {
    return '' if !-e $path;
    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh> // '';
    close $fh;
    return $text;
}

sub usage ($exit) {
    print <<'USAGE';
Usage: perl -Mblib bench/tools/run-listen-callback-construction-progress.pl [options]

  --clients=LIST            concurrent client workers (default: 1,10,100)
  --connections=N           accepted connections per row (default: 10000)
  --repeats=N               paired repetitions (default: 9)
  --timeout=SECONDS         row timeout (default: 30)
  --accepted-callbacks=LIST subclass_method,shared_closure,fresh_closure, or all
  --json=PATH               incrementally updated JSON report
  --heartbeat=SECONDS       still-running message interval (default: 5)
  --help

Each row uses a dedicated runner. Blocking clients remain connected until the
server closes the accepted Stream. Completion is counted in Listener->on_accept,
after accepted Stream construction, so rapid peer teardown cannot suppress the
completion signal. Progress I/O remains outside the measured server interval.
USAGE
    exit $exit;
}
