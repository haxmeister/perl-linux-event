#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(strftime);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID usleep);
use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;

# Sustained Linux::Event listener test: no root, external tool or system tuning.
# From repo root, after perl Makefile.PL && make:
#   perl -Mblib bench/experiments/epollexclusive-local.pl

my %opt = (
    seconds => 15, repeats => 2, workers => '2,4',
    work_us => '0,150', clients => 32, generators => 2, accept_budget => 256,
);
GetOptions(
    'seconds=f'       => \$opt{seconds},
    'repeats=i'       => \$opt{repeats},
    'workers=s'       => \$opt{workers},
    'work-us=s'       => \$opt{work_us},
    'clients=i'       => \$opt{clients},
    'generators=i'    => \$opt{generators},
    'accept-budget=i' => \$opt{accept_budget},
    'output=s'        => \$opt{output},
    'help'            => \$opt{help},
) or die "Invalid option. Use --help.\n";
if ($opt{help}) {
    print <<'HELP';
Linux::Event EPOLLEXCLUSIVE local sustained benchmark

  perl -Mblib bench/experiments/epollexclusive-local.pl

  --seconds 15         Measured seconds per configuration
  --repeats 2          Repeats per configuration
  --workers 2,4        Worker counts
  --work-us 0,150      Synthetic microseconds CPU work per reply
  --clients 32         Maximum outstanding requests PER generator (1..128)
  --generators 2        Independent local client processes (1..4)
  --accept-budget 256  max_accept_per_tick for all modes
  --output PATH        JSONL results file (created automatically by default)
  --help               Show this screen

Uses normal shared epoll, shared EPOLLEXCLUSIVE, and independent SO_REUSEPORT.
Each request is one byte followed by a one-byte Stream acknowledgment.
Client load generators run in independent processes, not server workers.
Worker processes are recreated for each trial.
Only the JSONL result file is needed to analyze the measurements.
The file omits hostname, username and local IP address.
HELP
    exit 0;
}
die "Linux required\n" unless $^O eq 'linux';
die "--seconds must be between 0.5 and 120\n"
    unless $opt{seconds} >= 0.5 && $opt{seconds} <= 120;
die "--repeats must be 1..10\n"
    unless $opt{repeats} >= 1 && $opt{repeats} <= 10;
die "--clients must be 1..128\n"
    unless $opt{clients} >= 1 && $opt{clients} <= 128;
die "--generators must be 1..4\n"
    unless $opt{generators} >= 1 && $opt{generators} <= 4;
die "--accept-budget must be 1..4096\n"
    unless $opt{accept_budget} >= 1 && $opt{accept_budget} <= 4096;
my @workers = split /,/, $opt{workers};
my @work_us = split /,/, $opt{work_us};
die "Invalid --workers list (valid 1..16)\n"
    unless @workers && !grep { !/^\d+$/ || $_ < 1 || $_ > 16 } @workers;
die "Invalid --work-us list (valid 0..10000)\n"
    unless @work_us && !grep { !/^\d+$/ || $_ > 10_000 } @work_us;

sub mono () { clock_gettime(CLOCK_MONOTONIC) }
sub cpu () { clock_gettime(CLOCK_PROCESS_CPUTIME_ID) }
sub median ($v) {
    my @a = sort { $a <=> $b } @$v;
    return undef unless @a;
    return @a % 2 ? $a[int(@a / 2)] : ($a[@a / 2 - 1] + $a[@a / 2]) / 2;
}
sub percentile_ms ($sorted, $p) {
    return undef unless @$sorted;
    my $at = int(($p / 100) * (@$sorted - 1) + 0.999999);
    return sprintf('%.3f', $sorted->[$at] / 1000) + 0;
}
sub machine_info () {
    my ($model, $cpu_count);
    if (open my $fh, '<', '/proc/cpuinfo') {
        my $n = 0;
        while (my $s = <$fh>) {
            $model //= $1 if $s =~ /^model name\s*:\s*(.+?)\s*$/;
            $n++ if $s =~ /^processor\s*:/;
        }
        close $fh;
        $cpu_count = $n || undef;
    }
    my $kernel = 'unknown';
    if (open my $fh, '<', '/proc/sys/kernel/osrelease') {
        chomp($kernel = <$fh> // 'unknown');
        close $fh;
    }
    return {
        kernel => $kernel, cpu_model => $model // 'unknown',
        logical_cpus => $cpu_count, perl => "$^V",
    };
}
sub new_listener ($loop, $port, $reuseport, $work, $budget, $counts) {
    return Linux::Event::IO::Sock::Listener->new(
        (defined $loop ? (loop => $loop) : ()),
        host => '127.0.0.1', port => $port, reuseport => $reuseport ? 1 : 0,
        backlog => 4096, max_accept_per_tick => $budget,
        on_accept => sub ($listener, $stream) { $counts->{accepted}++ },
        stream => {
            on_data => sub ($stream, $bytes) {
                $counts->{messages}++;
                if ($work) {
                    my $until = mono() + $work / 1_000_000;
                    1 while mono() < $until;
                }
                $stream->write('y');
                $stream->end;
            },
            on_error => sub ($stream, $error) {
                $counts->{errors}++;
                $stream->close;
            },
        },
    );
}
sub close_client ($client) {
    # Let the server's Stream->end() deliver TCP FIN. We wait for that EOF
    # after reading the acknowledgment, then close normally. Abruptly
    # resetting the client socket with SO_LINGER(0) caused one server-side
    # on_error callback for *every* completed request, badly contaminating
    # the original benchmark with error-handling work.
    close $client;
}
sub generate_requests ($port, $seconds, $concurrency) {
    my $selector = IO::Select->new;
    my %issued;
    my %received_reply;
    my @lat_us;
    my ($connected, $completed, $within, $connect_errors,
        $write_errors, $reply_errors) = (0,0,0,0,0,0);
    my $cpu_start = cpu();
    my $deadline = mono() + $seconds;
    my $last_drain = $deadline + 0.8;
    while (1) {
        my $now = mono();
        while ($now < $deadline && $selector->count < $concurrency) {
            my $issued_at = mono();
            my $client = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp',
                Timeout => 1,
            );
            if (!$client) {
                $connect_errors++;
                usleep(1000);
                $now = mono();
                next;
            }
            $connected++;
            $client->blocking(0);
            my $written = syswrite($client, 'x');
            if (!defined($written) || $written != 1) {
                $write_errors++;
                close_client($client);
                $now = mono();
                next;
            }
            $issued{fileno($client)} = $issued_at;
            $selector->add($client);
            $now = mono();
        }
        last if !$selector->count && mono() >= $deadline;
        last if mono() >= $last_drain;
        for my $client ($selector->can_read(0.01)) {
            my $fd = fileno($client);
            my $received_at = mono();
            my $read = sysread($client, my $reply, 1);
            if (defined($read) && $read == 1 && $reply eq 'y'
                    && !$received_reply{$fd}) {
                $received_reply{$fd} = 1;
                $completed++;
                $within++ if $received_at <= $deadline;
                push @lat_us, int(($received_at - $issued{$fd}) * 1_000_000)
                    if exists $issued{$fd};
                # Keep socket until the server's FIN; avoids sending RST.
                next;
            }
            if (!defined($read) || $read != 0 || !$received_reply{$fd}) {
                $reply_errors++;
            }
            $selector->remove($client);
            delete $issued{$fd};
            delete $received_reply{$fd};
            close_client($client);
        }
    }
    my $unanswered = 0;
    my $pending_eof = 0;
    for my $client ($selector->handles) {
        if ($received_reply{fileno($client)}) { $pending_eof++ }
        else { $unanswered++ }
        $selector->remove($client);
        close_client($client);
    }
    my $client_cpu = cpu() - $cpu_start;
    @lat_us = sort { $a <=> $b } @lat_us;
    my %hist;
    $hist{int($_ / 100)}++ for @lat_us;
    return {
        latency_hist_100us => \%hist,
        connected => $connected, completed => $completed,
        completed_in_time => $within, completed_per_s => $within / $seconds,
        failed_connect => $connect_errors, failed_write => $write_errors,
        failed_reply => $reply_errors, unanswered => $unanswered,
        pending_eof => $pending_eof,
        client_cpu_s => sprintf('%.6f', $client_cpu) + 0,
        client_cpu_fraction => sprintf('%.3f', $client_cpu / $seconds) + 0,
        latency_ms => {
            p50 => percentile_ms(\@lat_us, 50),
            p95 => percentile_ms(\@lat_us, 95),
            p99 => percentile_ms(\@lat_us, 99),
            max => @lat_us ? $lat_us[-1] / 1000 : undef,
        },
    };
}
# Merge individual generator counts and 0.1-ms latency histograms without
# averaging percentiles (which would give incorrect pooled latency figures).
sub histogram_percentile_ms ($hist, $percent) {
    my $total = 0;
    $total += $_ for values %$hist;
    return undef unless $total;
    my $threshold = int(($percent / 100) * ($total - 1) + 0.999999) + 1;
    my $seen = 0;
    for my $bucket (sort { $a <=> $b } keys %$hist) {
        $seen += $hist->{$bucket};
        return $bucket / 10 if $seen >= $threshold;
    }
    return undef;
}
sub combine_generators ($data, $seconds) {
    my %total = map { $_ => 0 } qw(
        connected completed completed_in_time failed_connect
        failed_write failed_reply unanswered pending_eof client_cpu_s
    );
    my %hist;
    my $max_cpu_fraction = 0;
    my $max_latency_ms = 0;
    for my $gen (@$data) {
        $total{$_} += $gen->{$_} for keys %total;
        while (my ($bucket, $count) = each %{$gen->{latency_hist_100us}}) {
            $hist{$bucket} += $count;
        }
        $max_cpu_fraction = $gen->{client_cpu_fraction}
            if $gen->{client_cpu_fraction} > $max_cpu_fraction;
        $max_latency_ms = $gen->{latency_ms}{max}
            if defined($gen->{latency_ms}{max})
                && $gen->{latency_ms}{max} > $max_latency_ms;
    }
    return {
        %total,
        generators => scalar(@$data),
        completed_per_s => $total{completed_in_time} / $seconds,
        client_cpu_fraction => $total{client_cpu_s} / $seconds,
        max_generator_cpu_fraction => $max_cpu_fraction,
        latency_ms => {
            p50 => histogram_percentile_ms(\%hist, 50),
            p95 => histogram_percentile_ms(\%hist, 95),
            p99 => histogram_percentile_ms(\%hist, 99),
            max => $max_latency_ms,
        },
        latency_hist_100us => \%hist,
        # Per-generator numbers are retained for diagnosing load limitations.
        generator => [map {
            my %copy = %$_;
            delete $copy{latency_hist_100us};
            \%copy;
        } @$data],
    };
}

# Start the server worker loops and client generators at the same barrier.
# Clients are separate processes so one CPU-bound generator cannot silently
# cap the server benchmark. Their CPU consumption is tracked separately.
sub run_client_generators ($port, $config, $server_start, $server_count) {
    pipe(my $ready_r, my $ready_w) or die "client generator start pipe: $!";
    my @children;
    my $merged = eval {
        for my $index (0 .. $config->{generators} - 1) {
            pipe(my $read, my $write) or die "client generator result pipe: $!";
            my $pid = CORE::fork();
            die "client generator fork failed: $!" unless defined $pid;
            if ($pid == 0) {
                close $read;
                close $ready_w;
                close $_->{reader} for @children;
                my $ok = eval {
                    my $token;
                    sysread($ready_r, $token, 1) == 1 && $token eq 'C'
                        or die "client generator start failed";
                    close $ready_r;
                    my $data = generate_requests(
                        $port, $config->{seconds}, $config->{clients}
                    );
                    print {$write} JSON::PP->new->canonical->encode($data), "\n"
                        or die "client generator result write failed";
                    close $write or die "client generator result close failed";
                    1;
                };
                warn "Client generator $index: $@\n" unless $ok;
                POSIX::_exit($ok ? 0 : 2);
            }
            close $write;
            push @children, {pid => $pid, reader => $read};
        }
        close $ready_r;
        my $server_go = 'G' x $server_count;
        syswrite($server_start, $server_go) == length($server_go)
            or die "server start barrier failed";
        close $server_start;
        my $client_go = 'C' x $config->{generators};
        syswrite($ready_w, $client_go) == length($client_go)
            or die "client start barrier failed";
        close $ready_w;
        my @data;
        for my $client (@children) {
            my $line = readline($client->{reader});
            die "client generator produced no data" unless defined $line;
            push @data, JSON::PP->new->decode($line);
            close $client->{reader};
        }
        my $failed = 0;
        for my $client (@children) {
            $failed++ if waitpid($client->{pid}, 0) != $client->{pid} || $?;
        }
        @children = ();
        die "$failed client generator process(es) failed" if $failed;
        combine_generators(\@data, $config->{seconds});
    };
    if (my $err = $@) {
        kill 'TERM', map { $_->{pid} } @children;
        waitpid($_->{pid}, 0) for @children;
        die $err;
    }
    return $merged;
}
sub run_trial ($mode, $workers, $work, $config) {
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} =
        $mode eq 'exclusive' ? 1 : 0;
    my $loop = $mode eq 'reuseport' ? undef : Linux::Event::Loop->new;
    my %shared_counts;
    my $seed = new_listener($loop, 0, $mode eq 'reuseport',
                            $work, $config->{accept_budget}, \%shared_counts);
    my $port = $seed->port;
    pipe(my $ready_r, my $ready_w) or die "ready pipe: $!";
    pipe(my $start_r, my $start_w) or die "start pipe: $!";
    pipe(my $results_r, my $results_w) or die "results pipe: $!";
    my @pids;
    my $record = eval {
        for my $index (0 .. $workers-1) {
            my $pid = $mode eq 'reuseport' ? CORE::fork()
                : $loop->fork(share => [$seed]);
            die "fork failed: $!" if !defined $pid;
            if ($pid == 0) {
                close $ready_r; close $start_w; close $results_r;
                my $ok = eval {
                    my $worker_loop;
                    my %private_counts;
                    if ($mode eq 'reuseport') {
                        $seed->close;
                        $worker_loop = Linux::Event::Loop->new;
                        $seed = new_listener(
                            $worker_loop, $port, 1, $work,
                            $config->{accept_budget}, \%private_counts,
                        );
                    }
                    else {
                        $worker_loop = $loop;
                    }
                    syswrite($ready_w, 'R') == 1 or die "ready failure";
                    close $ready_w;
                    my $token;
                    sysread($start_r, $token, 1) == 1 && $token eq 'G'
                        or die "start barrier failed";
                    close $start_r;
                    my $cpu_at = cpu();
                    my $start = mono();
                    $worker_loop->run_for($config->{seconds} + 2);
                    my $used_cpu = cpu() - $cpu_at;
                    my $counts = $mode eq 'reuseport'
                        ? \%private_counts : \%shared_counts;
                    my $data = {
                        index => $index,
                        accepted => $counts->{accepted} // 0,
                        messages => $counts->{messages} // 0,
                        stream_errors => $counts->{errors} // 0,
                        cpu_s => sprintf('%.6f', $used_cpu) + 0,
                        elapsed_s => sprintf('%.4f', mono() - $start) + 0,
                        epoll_wait_calls => $worker_loop->stats->{epoll_wait_calls} // 0,
                    };
                    my $line = JSON::PP->new->canonical->encode($data) . "\n";
                    syswrite($results_w, $line) == length($line)
                        or die "worker result write failed";
                    close $results_w;
                    $seed->close;
                    1;
                };
                warn "Worker $index ($mode): $@\n" unless $ok;
                POSIX::_exit($ok ? 0 : 2);
            }
            push @pids, $pid;
        }
        close $ready_w; close $start_r; close $results_w;
        for (1 .. $workers) {
            my $n = sysread($ready_r, my $token, 1);
            die "worker did not become ready: $!" if !defined($n) || $n != 1;
        }
        close $ready_r;
        $seed->close;
        my $traffic = run_client_generators($port, $config, $start_w, $workers);
        my $child_failures = 0;
        for my $pid (@pids) {
            $child_failures++ if waitpid($pid, 0) != $pid || $?;
        }
        @pids = ();
        my @workers_data;
        while (my $line = <$results_r>) {
            push @workers_data, JSON::PP->new->decode($line);
        }
        close $results_r;
        @workers_data = sort { $a->{index} <=> $b->{index} } @workers_data;

        my ($total_accepts, $total_messages, $total_cpu, $waits, $sum_sq)
            = (0,0,0,0,0);
        my ($min_accept, $max_accept);
        for my $w (@workers_data) {
            $total_accepts += $w->{accepted};
            $total_messages += $w->{messages};
            $total_cpu += $w->{cpu_s};
            $waits += $w->{epoll_wait_calls};
            $sum_sq += $w->{accepted} ** 2;
            $min_accept = $w->{accepted}
                if !defined($min_accept) || $w->{accepted} < $min_accept;
            $max_accept = $w->{accepted}
                if !defined($max_accept) || $w->{accepted} > $max_accept;
        }
        my $fairness = $sum_sq
            ? ($total_accepts ** 2) / (@workers_data * $sum_sq) : 0;
        {
            mode => $mode, workers => $workers, work_us => $work,
            seconds => $config->{seconds}, clients => $config->{clients},
            generators => $config->{generators},
            accept_budget => $config->{accept_budget},
            traffic => $traffic, worker => \@workers_data,
            accepted => $total_accepts, messages => $total_messages,
            worker_cpu_s => sprintf('%.6f', $total_cpu) + 0,
            epoll_wait_calls => $waits,
            min_worker_accepted => $min_accept // 0,
            max_worker_accepted => $max_accept // 0,
            fairness_jain => sprintf('%.4f', $fairness) + 0,
            child_failures => $child_failures,
            complete_worker_reports => @workers_data == $workers
                ? JSON::PP::true : JSON::PP::false,
        };
    };
    if (my $error = $@) {
        kill 'TERM', @pids if @pids;
        waitpid($_, 0) for @pids;
        die "Trial $mode, workers=$workers, work=$work failed: $error";
    }
    return $record;
}

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
$opt{output} //= "bench/results/epollexclusive/local-$stamp-$$.jsonl";
make_path(dirname($opt{output}));
open my $out, '>', $opt{output} or die "Cannot open output file: $!";
$out->autoflush(1);
my $json = JSON::PP->new->canonical;
print {$out} $json->encode({
    type => 'metadata', benchmark => 'epollexclusive-local-v2',
    machine => machine_info(), settings => \%opt,
    created_local => $stamp, branch => 'feature/epollexclusive-evaluation',
}), "\n";

my @all;
my $total_trials = $opt{repeats} * @workers * @work_us * 3;
my $case_number = 0;
say "Linux::Event sustained EPOLLEXCLUSIVE benchmark";
say "Workers: $opt{workers}; synthetic work (us): $opt{work_us}; "
    . "clients per generator: $opt{clients}; generators: $opt{generators}";
say "Duration per trial: $opt{seconds}s; repetitions: $opt{repeats}";
say "Results: $opt{output}";
for my $repeat (1 .. $opt{repeats}) {
    for my $workers (@workers) {
        for my $work (@work_us) {
            my @modes = qw(shared exclusive reuseport);
            push @modes, shift @modes for 1 .. (($repeat - 1) % 3);
            for my $mode (@modes) {
                ++$case_number;
                say "[$case_number/$total_trials] $mode workers=$workers work_us=$work";
                my $trial = run_trial($mode, $workers, $work, \%opt);
                $trial->{type} = 'trial';
                $trial->{repeat} = $repeat;
                $trial->{warnings} = [];
                push @{$trial->{warnings}}, 'worker failed'
                    if $trial->{child_failures};
                push @{$trial->{warnings}}, 'worker report missing'
                    unless $trial->{complete_worker_reports};
                push @{$trial->{warnings}}, 'client may be CPU-bound'
                    if $trial->{traffic}{max_generator_cpu_fraction} > 0.9;
                push @{$trial->{warnings}}, 'some requests have no reply'
                    if $trial->{traffic}{completed} < $trial->{traffic}{connected};
                push @{$trial->{warnings}}, 'clients closed before server FIN'
                    if $trial->{traffic}{pending_eof};
                push @{$trial->{warnings}}, 'server Stream error callbacks occurred'
                    if grep { $_->{stream_errors} } @{$trial->{worker}};
                print {$out} $json->encode($trial), "\n";
                push @all, $trial;
                printf "    %7.0f replies/s; worker CPU %.2fs; p95 %.3fms"
                    . "; fairness %.3f; accepts min/max %d/%d\n",
                    $trial->{traffic}{completed_per_s},
                    $trial->{worker_cpu_s},
                    $trial->{traffic}{latency_ms}{p95} // 0,
                    $trial->{fairness_jain},
                    $trial->{min_worker_accepted},
                    $trial->{max_worker_accepted};
                warn "    Note: " . join('; ', @{$trial->{warnings}}) . "\n"
                    if @{$trial->{warnings}};
            }
        }
    }
}
say "\nMedian completed replies per second by scenario:";
for my $workers (@workers) {
    for my $work (@work_us) {
        for my $mode (qw(shared exclusive reuseport)) {
            my @selected = grep {
                $_->{workers} == $workers && $_->{work_us} == $work
                    && $_->{mode} eq $mode
            } @all;
            printf "  workers=%d work=%4dus %-9s %8.0f/s fairness=%.3f\n",
                $workers, $work, $mode,
                median([map { $_->{traffic}{completed_per_s} } @selected]),
                median([map { $_->{fairness_jain} } @selected]);
        }
    }
}
close $out or die "Cannot finish results: $!";
say "\nSaved results file: $opt{output}";
say "Please share that one .jsonl file to compare throughput, CPU, latency and fairness.";
