#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use IO::Poll qw(POLLIN POLLOUT POLLERR POLLHUP);
use IO::Select;
use IO::Socket::INET;
use JSON::PP qw(encode_json decode_json);
use POSIX qw(:sys_wait_h);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Time::HiRes qw(time usleep);

my $systems = 'linuxevent,node,python,ruby';
my $clients = '100,500,1000,2500';
my $bytes = '64';
my $messages = 100;
my $warmup = 10;
my $repeats = 4;
my $client_workers = 4;
my $latency_sample_every = 10;
my $timeout = 90;
my $host = '127.0.0.1';
my $build = 0;
my $check_deps = 0;
my $out = 'bench/results/line-runtime-comparison.html';
my $json_out = 'bench/results/line-runtime-comparison.json';

my @live_pids;
my $cleaning_up = 0;
$SIG{INT} = sub { cleanup_live_children('INT'); exit 130; };
$SIG{TERM} = sub { cleanup_live_children('TERM'); exit 143; };
$SIG{PIPE} = 'IGNORE';
END { cleanup_live_children('END') if @live_pids; }

GetOptions(
    'systems=s' => \$systems,
    'clients=s' => \$clients,
    'bytes=s' => \$bytes,
    'messages=i' => \$messages,
    'warmup=i' => \$warmup,
    'repeats=i' => \$repeats,
    'client-workers=i' => \$client_workers,
    'latency-sample-every=i' => \$latency_sample_every,
    'timeout=f' => \$timeout,
    'host=s' => \$host,
    'build!' => \$build,
    'check-deps!' => \$check_deps,
    'out=s' => \$out,
    'json=s' => \$json_out,
) or die usage();

my @systems = grep length, split /,/, $systems;
my @clients = map { int($_) } grep length, split /,/, $clients;
my @byte_sizes = map { int($_) } grep length, split /,/, $bytes;
my %known = map { $_ => 1 } qw(linuxevent node python ruby);

die "unknown system in --systems\n" if grep { !$known{$_} } @systems;
die "clients must all be > 0\n" if !@clients || grep { $_ <= 0 } @clients;
die "bytes must all be > 0\n" if !@byte_sizes || grep { $_ <= 0 } @byte_sizes;
die "messages must be > 0\n" unless $messages > 0;
die "warmup must be >= 0\n" unless $warmup >= 0;
die "repeats must be > 0\n" unless $repeats > 0;
die "client-workers must be > 0\n" unless $client_workers > 0;
die "latency-sample-every must be > 0\n" unless $latency_sample_every > 0;

warn "NOTE: --repeats=$repeats is not a multiple of the selected system count ("
    . scalar(@systems) . "); execution positions will rotate but will not be perfectly balanced.\n"
    if $repeats % @systems;

if ($build) {
    system($^X, 'Makefile.PL') == 0 or die "Makefile.PL failed\n";
    system('make') == 0 or die "make failed\n";
}

if ($check_deps) {
    check_dependencies();
    exit 0;
}

my %runtime = map { $_ => runtime_metadata($_) } @systems;
my @results;

for my $byte_index (0 .. $#byte_sizes) {
    my $payload_bytes = $byte_sizes[$byte_index];
    for my $client_index (0 .. $#clients) {
        my $count = $clients[$client_index];
        for my $repeat (1 .. $repeats) {
            my $offset = (($repeat - 1) + $client_index + $byte_index) % @systems;
            my @order = (@systems[$offset .. $#systems], @systems[0 .. $offset - 1]);
            for my $position (0 .. $#order) {
                my $system = $order[$position];
                my $order_position = $position + 1;
                warn "== $system bytes=$payload_bytes clients=$count repeat=$repeat order=$order_position/"
                    . scalar(@order) . " ==\n";

                my $result = eval {
                    run_case($system, $count, $payload_bytes, $repeat);
                };
                if (!$result) {
                    my $error = $@ || 'unknown case error';
                    chomp $error;
                    warn "FAILED: $error\n";
                    $result = failure_result(
                        $system, $count, $payload_bytes, $repeat, $error,
                    );
                }

                $result->{execution_order_mode} = 'balanced-rotation';
                $result->{execution_order_position} = $order_position;
                $result->{execution_order_width} = scalar @order;
                $result->{runtime} = $runtime{$system}{runtime};
                $result->{runtime_version} = $runtime{$system}{runtime_version};
                $result->{framework} = $runtime{$system}{framework};
                $result->{framework_version} = $runtime{$system}{framework_version};
                push @results, $result;
            }
        }
    }
}

my @summary = summarize(\@results);
my $document = {
    benchmark => 'line-delimited TCP runtime comparison',
    benchmark_contract_version => 1,
    ranking_metric => 'median_lines_per_second',
    fairness_contract => fairness_contract(),
    runtimes => \%runtime,
    results => \@results,
    summary => \@summary,
};
write_json($json_out, $document);
write_html($out, $document);
print_summary(\@summary);
print "wrote $json_out\n";
print "wrote $out\n";

exit((grep { !$_->{ok} } @results) ? 1 : 0);

sub usage {
    return <<'USAGE';
Usage:
  perl bench/run-line-runtime-comparison.pl --build \
    --systems linuxevent,node,python,ruby \
    --clients 100,500,1000,2500 --bytes 64 \
    --warmup 10 --messages 100 --repeats 4 \
    --client-workers 4 --latency-sample-every 10 \
    --out bench/results/line-runtime-comparison.html \
    --json bench/results/line-runtime-comparison.json

The payload size excludes the trailing LF delimiter. A --bytes value of 64
therefore sends 65 bytes on the wire per line.

Systems:
  linuxevent  Linux::Event IO::Sock::Listener + native Delimiter("\\n") framer
  node        node:net Socket + node:readline 'line' events
  python      asyncio.start_server + StreamReader.readline()
  ruby        async scheduler + Ruby Socket#gets

Fairness rules:
  * TCP IPv4 loopback
  * fresh server process for every case
  * all clients connected before warmup
  * warmup outside timing
  * serial one-line request / one-line reply per connection
  * identical Perl IO::Poll load generator for every server
  * TCP_NODELAY on both client and server sockets
  * server startup, accept setup, and teardown excluded from timing
  * balanced rotating runtime order across repeats
  * exact echoed bytes verified by every client
  * failed cases are retained but never ranked

Use --check-deps to print runtime/module availability without benchmarking.
USAGE
}

sub fairness_contract {
    return {
        transport => 'TCP IPv4 loopback',
        delimiter => 'LF (0x0a)',
        payload_bytes_excludes_delimiter => JSON::PP::true,
        protocol => 'serial request/reply; one outstanding line per connection',
        clients_preconnected => JSON::PP::true,
        warmup_outside_timing => JSON::PP::true,
        startup_outside_timing => JSON::PP::true,
        teardown_outside_timing => JSON::PP::true,
        tcp_nodelay => JSON::PP::true,
        common_client_driver => 'Perl IO::Poll',
        client_workers => $client_workers,
        measured_lines_per_client => $messages,
        warmup_lines_per_client => $warmup,
        latency_sample_every => $latency_sample_every,
        runtime_line_apis => {
            linuxevent => 'native Delimiter("\\n") framer + on_message closure',
            node => 'node:readline line event',
            python => 'asyncio StreamReader.readline()',
            ruby => 'async scheduler + Socket#gets',
        },
    };
}

sub check_dependencies {
    print "Perl $^V ($^X)\n";
    my $missing = 0;

    if (grep { $_ eq 'linuxevent' } @systems) {
        my $ok = eval {
            require Linux::Event;
            require Linux::Event::Loop;
            require Linux::Event::Framer;
            require Linux::Event::IO::Sock::Listener;
            require Linux::Event::IO::Sock::Stream;
            1;
        };
        printf "  %-16s %s\n", 'Linux::Event',
            $ok ? "OK ($Linux::Event::VERSION)" : "MISSING ($@)";
        $missing++ unless $ok;
    }

    if (grep { $_ eq 'node' } @systems) {
        my $v = capture_command('node', '--version');
        printf "  %-16s %s\n", 'Node.js', $v ? "OK ($v)" : 'MISSING';
        $missing++ unless $v;
    }

    if (grep { $_ eq 'python' } @systems) {
        my $v = capture_command('python3', '--version');
        printf "  %-16s %s\n", 'Python', $v ? "OK ($v)" : 'MISSING';
        $missing++ unless $v;
    }

    if (grep { $_ eq 'ruby' } @systems) {
        my $v = capture_command('ruby', '--version');
        my $async = capture_command(
            'ruby', '-e',
            'begin; require "async"; puts Gem.loaded_specs["async"].version; rescue LoadError; exit 2; end',
        );
        printf "  %-16s %s\n", 'Ruby', $v ? "OK ($v)" : 'MISSING';
        printf "  %-16s %s\n", 'Ruby async', $async ? "OK ($async)" : 'MISSING';
        $missing++ unless $v && $async;
    }

    print $missing ? "Dependency check: $missing missing item(s)\n" : "Dependency check: OK\n";
    return !$missing;
}

sub runtime_metadata ($system) {
    if ($system eq 'linuxevent') {
        my $version = eval {
            require Linux::Event;
            $Linux::Event::VERSION;
        } // 'unknown';
        return {
            runtime => 'Perl',
            runtime_version => "$^V",
            framework => 'Linux::Event',
            framework_version => "$version",
        };
    }
    if ($system eq 'node') {
        my $version = capture_command('node', '--version') || 'unknown';
        return {
            runtime => 'Node.js',
            runtime_version => $version,
            framework => 'node:net + node:readline',
            framework_version => $version,
        };
    }
    if ($system eq 'python') {
        my $version = capture_command('python3', '--version') || 'unknown';
        return {
            runtime => 'Python',
            runtime_version => $version,
            framework => 'asyncio streams',
            framework_version => $version,
        };
    }
    if ($system eq 'ruby') {
        my $version = capture_command('ruby', '--version') || 'unknown';
        my $async = capture_command(
            'ruby', '-e',
            'begin; require "async"; puts Gem.loaded_specs["async"].version; rescue LoadError; print "missing"; end',
        ) || 'unknown';
        return {
            runtime => 'Ruby',
            runtime_version => $version,
            framework => 'async + Socket#gets',
            framework_version => $async,
        };
    }
    die "unknown runtime metadata system $system";
}

sub run_case ($system, $count, $payload_bytes, $repeat) {
    my $server = start_server($system);
    my $tmp = tempdir(CLEANUP => 1);
    my $message = ('x' x $payload_bytes) . "\n";
    my $wire_bytes = length($message);

    my $workers = $client_workers > $count ? $count : $client_workers;
    my $base = int($count / $workers);
    my $extra = $count % $workers;

    my @ready_files;
    my @warmup_done_files;
    my @measure_done_files;
    my @result_files;
    my @pids;
    my $warmup_gate = "$tmp/warmup-go";
    my $measure_gate = "$tmp/measure-go";
    my $teardown_gate = "$tmp/teardown-go";

    my $result = eval {
        for my $worker (1 .. $workers) {
            my $worker_clients = $base + ($worker <= $extra ? 1 : 0);
            my $ready = "$tmp/ready-$worker";
            my $warmup_done = "$tmp/warmup-done-$worker";
            my $measure_done = "$tmp/measure-done-$worker";
            my $worker_result = "$tmp/result-$worker.json";
            push @ready_files, $ready;
            push @warmup_done_files, $warmup_done;
            push @measure_done_files, $measure_done;
            push @result_files, $worker_result;

            my $pid = fork();
            die "client worker fork failed: $!" unless defined $pid;
            if ($pid == 0) {
                @live_pids = ();
                $cleaning_up = 0;
                $SIG{PIPE} = 'IGNORE';
                $SIG{TERM} = sub { exit 143 };
                client_worker(
                    $server->{port}, $worker_clients, $message,
                    $ready, $warmup_gate, $warmup_done,
                    $measure_gate, $measure_done,
                    $teardown_gate, $worker_result,
                );
                exit 0;
            }
            push @pids, $pid;
            add_live_pid($pid);
        }

        my $setup_deadline = time + $timeout + 30;
        wait_for_files(\@ready_files, $setup_deadline, 'client ready barrier');

        touch_gate($warmup_gate);
        wait_for_files(\@warmup_done_files, time + $timeout + 30, 'warmup barrier');

        my $cpu_before = proc_cpu_seconds($server->{pid});
        my $measure_wall_start = time;
        touch_gate($measure_gate);
        wait_for_files(\@measure_done_files, time + $timeout + 30, 'measure barrier');
        my $measure_wall_end = time;
        my $cpu_after = proc_cpu_seconds($server->{pid});
        my $rss_hwm_kb = proc_hwm_kb($server->{pid});

        touch_gate($teardown_gate);
        my $client_failures = reap_children(\@pids, 30);
        @pids = ();

        my ($worker_results, $file_failures) = load_worker_results(\@result_files);
        $client_failures += $file_failures;

        my @latency;
        my $measured_lines = 0;
        my $connected_clients = 0;
        my @starts;
        my @ends;
        for my $one (@$worker_results) {
            $measured_lines += $one->{measured_lines} // 0;
            $connected_clients += $one->{connected_clients} // 0;
            push @latency, @{ $one->{latency_us} || [] };
            push @starts, $one->{measure_start}
                if defined $one->{measure_start};
            push @ends, $one->{measure_end}
                if defined $one->{measure_end};
        }
        @latency = sort { $a <=> $b } @latency;

        my $elapsed = @starts && @ends
            ? max(@ends) - min(@starts)
            : $measure_wall_end - $measure_wall_start;
        $elapsed = $measure_wall_end - $measure_wall_start if $elapsed <= 0;

        my $target_lines = $count * $messages;
        my $case_ok = !$client_failures
            && $connected_clients == $count
            && $measured_lines == $target_lines;

        my $cpu_seconds = defined($cpu_before) && defined($cpu_after)
            ? $cpu_after - $cpu_before : undef;

        stop_server($server);
        $server = undef;

        {
            system => display_system($system),
            system_key => $system,
            clients => $count,
            connected_clients => $connected_clients,
            payload_bytes => $payload_bytes,
            wire_bytes => $wire_bytes,
            delimiter_hex => '0a',
            messages_per_client => $messages,
            warmup_per_client => $warmup,
            measured_lines => $target_lines,
            client_measured_lines => $measured_lines,
            client_workers => $workers,
            repeat => $repeat,
            elapsed_seconds => num($elapsed),
            lines_per_second => $case_ok ? num($target_lines / $elapsed) : undef,
            attempt_lines_per_second => num($target_lines / $elapsed),
            mib_per_second => $case_ok
                ? num((($target_lines * $wire_bytes) / 1_048_576) / $elapsed)
                : undef,
            server_cpu_seconds => defined($cpu_seconds) ? num($cpu_seconds) : undef,
            server_cpu_us_per_line => defined($cpu_seconds) && $target_lines
                ? num(($cpu_seconds / $target_lines) * 1_000_000)
                : undef,
            server_cpu_percent => defined($cpu_seconds) && $elapsed > 0
                ? num(($cpu_seconds / $elapsed) * 100)
                : undef,
            server_max_rss_kb => $rss_hwm_kb,
            latency_samples => scalar @latency,
            lat_p50_us => pct(\@latency, 50),
            lat_p95_us => pct(\@latency, 95),
            lat_p99_us => pct(\@latency, 99),
            lat_max_us => @latency ? $latency[-1] : undef,
            ok => $case_ok ? JSON::PP::true : JSON::PP::false,
            rankable => $case_ok ? JSON::PP::true : JSON::PP::false,
            failure_reason => $case_ok ? undef : join('; ', grep length,
                ($client_failures ? "client failures=$client_failures" : ''),
                ($connected_clients != $count
                    ? "connected=$connected_clients/$count" : ''),
                ($measured_lines != $target_lines
                    ? "measured=$measured_lines/$target_lines" : ''),
            ),
            work_signature => sprintf(
                'tcp=ipv4-loopback;nodelay=1;line=lf;payload=%d;wire=%d;serial=1;preconnected=1',
                $payload_bytes, $wire_bytes,
            ),
        };
    };

    my $error = $@;
    if (!$result) {
        kill_children(\@pids);
        stop_server($server) if $server;
        die $error;
    }

    return $result;
}

sub start_server ($system) {
    my @command;
    if ($system eq 'linuxevent') {
        @command = ($^X, "$Bin/runtime-line/line-linuxevent.pl", $host, 0);
    }
    elsif ($system eq 'node') {
        @command = ('node', "$Bin/runtime-line/line-node.js", $host, 0);
    }
    elsif ($system eq 'python') {
        @command = ('python3', "$Bin/runtime-line/line-asyncio.py", $host, 0);
    }
    elsif ($system eq 'ruby') {
        @command = ('ruby', "$Bin/runtime-line/line-ruby.rb", $host, 0);
    }
    else {
        die "unsupported server $system";
    }

    pipe(my $ready_read, my $ready_write) or die "server ready pipe failed: $!";
    my $pid = fork();
    die "server fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        close $ready_read;
        open STDOUT, '>&', $ready_write or die "redirect server stdout: $!";
        close $ready_write;
        exec @command;
        die "exec $command[0] failed: $!";
    }

    close $ready_write;
    add_live_pid($pid);
    my $select = IO::Select->new($ready_read);
    my $deadline = time + 15;
    my $line;
    while (time < $deadline) {
        if ($select->can_read(0.1)) {
            $line = <$ready_read>;
            last;
        }
        if (waitpid($pid, WNOHANG) == $pid) {
            remove_live_pid($pid);
            close $ready_read;
            die "$system server exited before READY";
        }
    }
    if (!defined $line || $line !~ /^READY\s+(\d+)\s*$/) {
        stop_process($pid);
        close $ready_read;
        die "$system server did not report READY";
    }

    return {
        pid => $pid,
        port => 0 + $1,
        ready_read => $ready_read,
    };
}

sub stop_server ($server) {
    return unless $server && $server->{pid};
    close $server->{ready_read} if $server->{ready_read};
    stop_process($server->{pid});
}

sub client_worker (
    $port, $count, $message,
    $ready_file, $warmup_gate, $warmup_done_file,
    $measure_gate, $measure_done_file,
    $teardown_gate, $result_file,
) {
    my $poll = IO::Poll->new;
    my %state;
    my $failures = 0;

    for my $id (1 .. $count) {
        my $sock;
        for (1 .. 5000) {
            $sock = IO::Socket::INET->new(
                PeerAddr => $host,
                PeerPort => $port,
                Proto => 'tcp',
            );
            last if $sock;
            usleep(1000);
        }
        if (!$sock) {
            $failures++;
            next;
        }
        setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, pack('i', 1));
        $sock->blocking(0);
        my $fd = fileno($sock);
        $state{$fd} = { sock => $sock };
        $poll->mask($sock => POLLIN | POLLERR | POLLHUP);
    }

    write_marker($ready_file, scalar keys %state);
    wait_for_gate($warmup_gate, $timeout + 30);

    if ($warmup > 0 && %state) {
        my ($phase_ok) = client_run_phase($poll, \%state, $message, $warmup, 0);
        $failures++ unless $phase_ok;
    }
    write_marker($warmup_done_file, 1);

    wait_for_gate($measure_gate, $timeout + 30);
    my $measure_start = time;
    my ($phase_ok, $measured, $latency) = %state
        ? client_run_phase($poll, \%state, $message, $messages, 1)
        : (0, 0, []);
    my $measure_end = time;
    $failures++ unless $phase_ok;

    write_json($result_file, {
        ok => $failures ? JSON::PP::false : JSON::PP::true,
        failures => $failures,
        connected_clients => scalar keys %state,
        measured_lines => $measured,
        measure_start => $measure_start,
        measure_end => $measure_end,
        latency_us => $latency,
    });
    write_marker($measure_done_file, 1);

    wait_for_gate($teardown_gate, 60);
    close $_->{sock} for values %state;
    exit($failures ? 1 : 0);
}

sub client_run_phase ($poll, $state, $message, $phase_messages, $record_latency) {
    my $active = 0;
    my $failed = 0;
    my $total_done = 0;
    my @latency;
    my $message_length = length($message);

    for my $st (values %$state) {
        $st->{phase_sent} = 0;
        $st->{phase_done} = 0;
        $st->{recv_len} = 0;
        $st->{recv_buf} = '';
        $st->{write_off} = 0;
        $st->{write_active} = 1;
        $st->{awaiting_reply} = 0;
        $st->{lat_start} = undef;
        $poll->mask($st->{sock} => POLLIN | POLLOUT | POLLERR | POLLHUP);
        $active++;
    }

    my $deadline = time + $timeout;
    while ($active > 0 && time < $deadline) {
        my $ready = $poll->poll(0.05);
        next unless $ready;

        for my $fh ($poll->handles(POLLERR | POLLHUP | POLLIN | POLLOUT)) {
            my $fd = fileno($fh);
            my $st = $state->{$fd} or next;
            next if $st->{phase_done} >= $phase_messages;
            my $events = $poll->events($fh);

            if (($events & (POLLERR | POLLHUP)) && !($events & POLLIN)) {
                $failed++;
                $st->{phase_done} = $phase_messages;
                $active--;
                $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                next;
            }

            if (($events & POLLOUT) && $st->{write_active}) {
                my $remaining = $message_length - $st->{write_off};
                my $written = syswrite(
                    $fh, $message, $remaining, $st->{write_off},
                );
                if (defined $written && $written > 0) {
                    $st->{write_off} += $written;
                    if ($st->{write_off} >= $message_length) {
                        $st->{write_active} = 0;
                        $st->{awaiting_reply} = 1;
                        $st->{write_off} = 0;
                        $st->{phase_sent}++;
                        $st->{lat_start} = $record_latency
                            && $st->{phase_sent} % $latency_sample_every == 0
                            ? time : undef;
                        $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                    }
                }
                elsif (!defined $written && ($!{EAGAIN} || $!{EWOULDBLOCK})) {
                }
                else {
                    $failed++;
                    $st->{phase_done} = $phase_messages;
                    $active--;
                    $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                    next;
                }
            }

            if (($events & POLLIN) && $st->{awaiting_reply}) {
                my $need = $message_length - $st->{recv_len};
                my $read = sysread($fh, my $buffer, $need);
                if (defined $read && $read > 0) {
                    $st->{recv_len} += $read;
                    $st->{recv_buf} .= $buffer;
                    if ($st->{recv_len} >= $message_length) {
                        if ($st->{recv_buf} ne $message) {
                            $failed++;
                            $st->{phase_done} = $phase_messages;
                            $active--;
                            $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                            next;
                        }

                        if (defined $st->{lat_start}) {
                            push @latency,
                                int((time - $st->{lat_start}) * 1_000_000);
                        }

                        $st->{recv_len} = 0;
                        $st->{recv_buf} = '';
                        $st->{awaiting_reply} = 0;
                        $st->{phase_done}++;
                        $total_done++;

                        if ($st->{phase_done} >= $phase_messages) {
                            $active--;
                            $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                        }
                        else {
                            $st->{write_active} = 1;
                            $st->{lat_start} = undef;
                            $poll->mask(
                                $fh => POLLIN | POLLOUT | POLLERR | POLLHUP,
                            );
                        }
                    }
                }
                elsif (defined $read && $read == 0) {
                    $failed++;
                    $st->{phase_done} = $phase_messages;
                    $active--;
                }
                elsif (!defined $read && ($!{EAGAIN} || $!{EWOULDBLOCK})) {
                }
                else {
                    $failed++;
                    $st->{phase_done} = $phase_messages;
                    $active--;
                }
            }
        }
    }

    $failed++ if $active > 0;
    return ($failed ? 0 : 1, $total_done, \@latency);
}

sub proc_cpu_seconds ($pid) {
    return undef unless $pid && -r "/proc/$pid/stat";
    open my $fh, '<', "/proc/$pid/stat" or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    return undef unless $line =~ /^\d+\s+\(.*\)\s+\S\s+(.*)$/;
    my @field = split /\s+/, $1;
    return undef unless @field > 11;
    my $ticks = ($field[10] // 0) + ($field[11] // 0);
    state $ticks_per_second = do {
        my $value = capture_command('getconf', 'CLK_TCK');
        $value && $value =~ /^\d+$/ ? 0 + $value : 100;
    };
    return $ticks / $ticks_per_second;
}

sub proc_hwm_kb ($pid) {
    return undef unless $pid && -r "/proc/$pid/status";
    open my $fh, '<', "/proc/$pid/status" or return undef;
    while (<$fh>) {
        if (/^VmHWM:\s+(\d+)\s+kB/) {
            close $fh;
            return 0 + $1;
        }
    }
    close $fh;
    return undef;
}

sub load_worker_results ($files) {
    my @results;
    my $failures = 0;
    for my $file (@$files) {
        if (!-e $file) {
            $failures++;
            next;
        }
        open my $fh, '<', $file or do { $failures++; next; };
        local $/;
        my $result = eval { decode_json(<$fh>) };
        close $fh;
        if (!$result) {
            $failures++;
            next;
        }
        push @results, $result;
    }
    return (\@results, $failures);
}

sub reap_children ($pids, $seconds) {
    my $failures = 0;
    for my $pid (@$pids) {
        my $deadline = time + $seconds;
        my $done = 0;
        while (time < $deadline) {
            my $waited = waitpid($pid, WNOHANG);
            if ($waited == $pid || $waited == -1) {
                $done = 1;
                $failures++ if $waited == $pid && $? != 0;
                remove_live_pid($pid);
                last;
            }
            usleep(10_000);
        }
        if (!$done) {
            $failures++;
            stop_process($pid);
        }
    }
    return $failures;
}

sub kill_children ($pids) {
    stop_process($_) for @$pids;
}

sub stop_process ($pid) {
    return unless $pid && $pid > 0;
    my $waited = waitpid($pid, WNOHANG);
    if ($waited == $pid || $waited == -1) {
        remove_live_pid($pid);
        return;
    }

    kill 'TERM', $pid;
    my $deadline = time + 2;
    while (time < $deadline) {
        $waited = waitpid($pid, WNOHANG);
        if ($waited == $pid || $waited == -1) {
            remove_live_pid($pid);
            return;
        }
        usleep(10_000);
    }

    kill 'KILL', $pid;
    waitpid($pid, 0);
    remove_live_pid($pid);
}

sub add_live_pid ($pid) {
    push @live_pids, $pid;
}

sub remove_live_pid ($pid) {
    @live_pids = grep { $_ != $pid } @live_pids;
}

sub cleanup_live_children ($why) {
    return if $cleaning_up++;
    my @pids = @live_pids;
    warn "== cleaning up " . scalar(@pids) . " child process(es) after $why ==\n"
        if @pids && $why ne 'END';
    stop_process($_) for @pids;
    @live_pids = ();
    $cleaning_up = 0;
}

sub wait_for_files ($files, $deadline, $label) {
    while (time < $deadline) {
        return unless grep { !-e $_ } @$files;
        usleep(100);
    }
    die "$label timeout" if grep { !-e $_ } @$files;
}

sub wait_for_gate ($path, $seconds) {
    my $deadline = time + $seconds;
    until (-e $path) {
        die "gate timeout: $path" if time >= $deadline;
        usleep(100);
    }
}

sub touch_gate ($path) {
    open my $fh, '>', $path or die "write gate $path: $!";
    print {$fh} "go\n";
    close $fh;
}

sub write_marker ($path, $value) {
    open my $fh, '>', $path or die "write marker $path: $!";
    print {$fh} "$value\n";
    close $fh;
}

sub capture_command (@command) {
    my $pid = open my $fh, '-|', @command;
    return '' unless defined $pid;
    local $/;
    my $text = <$fh> // '';
    close $fh;
    return '' if $? != 0;
    $text =~ s/^\s+|\s+$//g;
    return $text;
}

sub failure_result ($system, $count, $payload_bytes, $repeat, $error) {
    return {
        system => display_system($system),
        system_key => $system,
        clients => $count,
        payload_bytes => $payload_bytes,
        wire_bytes => $payload_bytes + 1,
        delimiter_hex => '0a',
        messages_per_client => $messages,
        warmup_per_client => $warmup,
        measured_lines => $count * $messages,
        client_workers => $client_workers > $count ? $count : $client_workers,
        repeat => $repeat,
        ok => JSON::PP::false,
        rankable => JSON::PP::false,
        failure_reason => $error,
        lines_per_second => undef,
        mib_per_second => undef,
        work_signature => sprintf(
            'tcp=ipv4-loopback;nodelay=1;line=lf;payload=%d;wire=%d;serial=1;preconnected=1',
            $payload_bytes, $payload_bytes + 1,
        ),
    };
}

sub display_system ($system) {
    return 'Linux::Event Delimiter(LF)' if $system eq 'linuxevent';
    return 'Node.js readline' if $system eq 'node';
    return 'Python asyncio readline' if $system eq 'python';
    return 'Ruby async Socket#gets' if $system eq 'ruby';
    return $system;
}

sub summarize ($results) {
    my @summary;
    for my $payload_bytes (@byte_sizes) {
        for my $count (@clients) {
            my @group;
            for my $system (@systems) {
                my @rows = grep {
                    $_->{system_key} eq $system
                        && $_->{clients} == $count
                        && $_->{payload_bytes} == $payload_bytes
                        && $_->{ok}
                } @$results;
                next unless @rows;

                push @group, {
                    system => display_system($system),
                    system_key => $system,
                    payload_bytes => $payload_bytes,
                    clients => $count,
                    repeats => scalar @rows,
                    median_lines_per_second => median(
                        map { $_->{lines_per_second} } @rows,
                    ),
                    mean_lines_per_second => mean(
                        map { $_->{lines_per_second} } @rows,
                    ),
                    median_mib_per_second => median(
                        map { $_->{mib_per_second} } @rows,
                    ),
                    median_cpu_us_per_line => median(
                        grep { defined } map { $_->{server_cpu_us_per_line} } @rows,
                    ),
                    median_cpu_percent => median(
                        grep { defined } map { $_->{server_cpu_percent} } @rows,
                    ),
                    median_rss_kb => median(
                        grep { defined } map { $_->{server_max_rss_kb} } @rows,
                    ),
                    median_p50_us => median(
                        grep { defined } map { $_->{lat_p50_us} } @rows,
                    ),
                    median_p95_us => median(
                        grep { defined } map { $_->{lat_p95_us} } @rows,
                    ),
                    median_p99_us => median(
                        grep { defined } map { $_->{lat_p99_us} } @rows,
                    ),
                };
            }

            @group = sort {
                $b->{median_lines_per_second} <=> $a->{median_lines_per_second}
                    || $a->{system_key} cmp $b->{system_key}
            } @group;
            for my $index (0 .. $#group) {
                $group[$index]{throughput_rank} = $index + 1;
            }
            push @summary, @group;
        }
    }
    return @summary;
}

sub print_summary ($summary) {
    return unless @$summary;
    print "\nLine-delimited runtime comparison\n";
    printf "%-30s %7s %8s %5s %14s %12s %10s %10s\n",
        'system', 'bytes', 'clients', 'rank', 'median line/s',
        'CPU us/line', 'p99 us', 'RSS KiB';
    for my $row (@$summary) {
        printf "%-30s %7d %8d %5d %14.2f %12s %10s %10s\n",
            $row->{system}, $row->{payload_bytes}, $row->{clients},
            $row->{throughput_rank}, $row->{median_lines_per_second},
            defined($row->{median_cpu_us_per_line})
                ? sprintf('%.3f', $row->{median_cpu_us_per_line}) : 'n/a',
            defined($row->{median_p99_us})
                ? sprintf('%.0f', $row->{median_p99_us}) : 'n/a',
            defined($row->{median_rss_kb})
                ? sprintf('%.0f', $row->{median_rss_kb}) : 'n/a';
    }
    print "\n";
}

sub write_json ($path, $document) {
    if ($path =~ m{^(.+)/[^/]+$}) {
        make_path($1) unless -d $1;
    }
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} JSON::PP->new->canonical(1)->pretty(1)->encode($document);
    close $fh;
}

sub write_html ($path, $document) {
    if ($path =~ m{^(.+)/[^/]+$}) {
        make_path($1) unless -d $1;
    }
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} <<'HTML';
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Line-delimited runtime comparison</title>
<style>body{font-family:system-ui,sans-serif;margin:2rem;line-height:1.4;max-width:1500px}table{border-collapse:collapse;width:100%;margin:1rem 0 2rem}th,td{border:1px solid #888;padding:.4rem .55rem;text-align:right}th:first-child,td:first-child{text-align:left}code{background:#eee;padding:.1rem .25rem}.note{padding:1rem;border:1px solid #888;border-radius:8px}</style></head><body>
<h1>Line-delimited runtime comparison</h1>
<div class="note">TCP IPv4 loopback; all clients preconnected; warmup outside timing; serial one-line request/reply; LF delimiter; identical Perl IO::Poll load generator; TCP_NODELAY; fresh server process per case; balanced runtime order.</div>
<h2>Median throughput ranking</h2>
<table><thead><tr><th>System</th><th>Payload bytes</th><th>Clients</th><th>Rank</th><th>Repeats</th><th>median line/s</th><th>mean line/s</th><th>MiB/s</th><th>CPU us/line</th><th>CPU %</th><th>p50 us</th><th>p95 us</th><th>p99 us</th><th>RSS KiB</th></tr></thead><tbody>
HTML
    for my $row (@{ $document->{summary} }) {
        print {$fh} '<tr>';
        print {$fh} join('',
            td($row->{system}),
            td($row->{payload_bytes}),
            td($row->{clients}),
            td($row->{throughput_rank}),
            td($row->{repeats}),
            td(sprintf('%.2f', $row->{median_lines_per_second})),
            td(sprintf('%.2f', $row->{mean_lines_per_second})),
            td(sprintf('%.3f', $row->{median_mib_per_second})),
            td(defined($row->{median_cpu_us_per_line})
                ? sprintf('%.3f', $row->{median_cpu_us_per_line}) : 'n/a'),
            td(defined($row->{median_cpu_percent})
                ? sprintf('%.2f', $row->{median_cpu_percent}) : 'n/a'),
            td(defined($row->{median_p50_us})
                ? sprintf('%.0f', $row->{median_p50_us}) : 'n/a'),
            td(defined($row->{median_p95_us})
                ? sprintf('%.0f', $row->{median_p95_us}) : 'n/a'),
            td(defined($row->{median_p99_us})
                ? sprintf('%.0f', $row->{median_p99_us}) : 'n/a'),
            td(defined($row->{median_rss_kb})
                ? sprintf('%.0f', $row->{median_rss_kb}) : 'n/a'),
        );
        print {$fh} "</tr>\n";
    }
    print {$fh} <<'HTML';
</tbody></table>
<h2>Runtime APIs</h2>
<table><thead><tr><th>System</th><th>Runtime</th><th>Runtime version</th><th>Line API</th><th>API version</th></tr></thead><tbody>
HTML
    for my $system (@systems) {
        my $runtime = $document->{runtimes}{$system};
        print {$fh} '<tr>' . join('',
            td(display_system($system)),
            td($runtime->{runtime}),
            td($runtime->{runtime_version}),
            td($runtime->{framework}),
            td($runtime->{framework_version}),
        ) . "</tr>\n";
    }
    print {$fh} "</tbody></table></body></html>\n";
    close $fh;
}

sub td ($value) {
    return '<td>' . html_escape($value) . '</td>';
}

sub html_escape ($value) {
    $value = '' unless defined $value;
    $value = "$value";
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

sub median (@values) {
    return undef unless @values;
    @values = sort { $a <=> $b } @values;
    my $count = @values;
    return $values[int($count / 2)] if $count % 2;
    return ($values[$count / 2 - 1] + $values[$count / 2]) / 2;
}

sub mean (@values) {
    return undef unless @values;
    my $sum = 0;
    $sum += $_ for @values;
    return $sum / @values;
}

sub pct ($values, $percent) {
    return undef unless @$values;
    my $index = int((@$values - 1) * ($percent / 100));
    return $values->[$index];
}

sub min (@values) {
    my $min = $values[0];
    for my $value (@values) {
        $min = $value if $value < $min;
    }
    return $min;
}

sub max (@values) {
    my $max = $values[0];
    for my $value (@values) {
        $max = $value if $value > $max;
    }
    return $max;
}

sub num ($value) {
    return 0 + sprintf('%.6f', $value);
}
