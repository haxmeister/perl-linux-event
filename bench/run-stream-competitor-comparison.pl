#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use IO::Socket::INET;
use IO::Poll qw(POLLIN POLLOUT POLLERR POLLHUP);
use IO::Select;
use Time::HiRes qw(time usleep);
use POSIX qw(:sys_wait_h);
use Getopt::Long qw(GetOptions);
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../blib/lib", "$Bin/../blib/arch", "$Bin/../lib";

my $systems = 'linuxevent,anyevent-handle,uv-tcp,ioasync-stream,mojo-stream';
my $clients = '100,500,1000,2500';
my $messages = 100;
my $warmup = 10;
my $bytes = 64;
my $workload = 'raw';
my $delimiter = "\x00\xffLE\x7f";
my $host = '127.0.0.1';
my $timeout = 90;
my $repeats = 5;
my $client_workers = 4;
my $build = 0;
my $check_deps = 0;
my $out = 'bench/results/stream-competitor-comparison.html';
my $json_out = 'bench/results/stream-competitor-comparison.json';
my $case_result_fh;
my @case_child_pids;

GetOptions(
    'systems=s' => \$systems,
    'clients=s' => \$clients,
    'messages=i' => \$messages,
    'warmup=i' => \$warmup,
    'bytes=i' => \$bytes,
    'workload=s' => \$workload,
    'timeout=f' => \$timeout,
    'repeats=i' => \$repeats,
    'client-workers=i' => \$client_workers,
    'build!' => \$build,
    'check-deps!' => \$check_deps,
    'out=s' => \$out,
    'json=s' => \$json_out,
) or die usage();

my @systems = grep length, split /,/, $systems;
my @clients = map { int($_) } grep length, split /,/, $clients;
my %known = map { $_ => 1 } qw(
    linuxevent
    anyevent-handle
    uv-tcp
    ioasync-stream
    mojo-stream
);
die "unknown system in --systems\n" if grep { !$known{$_} } @systems;
die "workload must be raw or delimiter\n"
    if $workload ne 'raw' && $workload ne 'delimiter';
die "messages must be > 0\n" unless $messages > 0;
die "warmup must be >= 0\n" unless $warmup >= 0;
die "bytes must be > 0\n" unless $bytes > 0;
die "repeats must be > 0\n" unless $repeats > 0;
die "client-workers must be > 0\n" unless $client_workers > 0;
warn "NOTE: --repeats=$repeats is not a multiple of the selected system count (" . scalar(@systems) . "); execution positions will rotate but will not be perfectly balanced.\n"
    if $repeats % @systems;

if ($build) {
    system($^X, 'Makefile.PL') == 0 or die "Makefile.PL failed\n";
    system('make') == 0 or die "make failed\n";
}

if ($check_deps) {
    check_deps();
    exit 0;
}

my @results;
# Run systems in a deterministic balanced rotation instead of system-by-system.
# When repeats is a multiple of the selected system count, every system occupies
# every execution position equally for each client count. This prevents long-run CPU
# frequency, thermal, and scheduler drift from being confounded with a
# particular Stream implementation.
for my $client_index (0 .. $#clients) {
    my $count = $clients[$client_index];
    for my $repeat (1 .. $repeats) {
        my $offset = (($repeat - 1) + $client_index) % @systems;
        my @order = (@systems[$offset .. $#systems], @systems[0 .. $offset - 1]);
        for my $position (0 .. $#order) {
            my $system = $order[$position];
            my $order_position = $position + 1;
            warn "== $system clients=$count repeat=$repeat order=$order_position/" . scalar(@order) . " ==\n";
            my $result = eval { run_case_isolated($system, $count, $repeat) };
            if (!$result) {
                my $err = $@ || 'unknown case error';
                chomp $err;
                $result = failure_result($system, $count, $repeat, $err);
                warn "FAILED: $err\n";
            }
            $result->{execution_order_mode} = 'balanced-rotation';
            $result->{execution_order_position} = $order_position;
            $result->{execution_order_width} = scalar @order;
            $result->{execution_block} =
                "workload=$workload/bytes=$bytes/clients=$count/repeat=$repeat";
            push @results, $result;
        }
    }
}

my @summary = summarize(\@results);
write_json($json_out, {
    benchmark => 'preconnected high-level stream comparison (balanced order)',
    benchmark_contract_version => 1,
    ranking_metric => 'median_messages_per_second',
    ranking_scope => 'within workload, payload size, and client count',
    fairness_contract => fairness_contract(),
    results => \@results,
    summary => \@summary,
});
write_html($out, \@results, \@summary);
print "wrote $json_out\n";
print "wrote $out\n";
if (grep { !$_->{ok} } @results) {
    warn "one or more cases failed; reports contain non-rankable rows\n";
    exit 1;
}

sub usage {
    return <<'USAGE';
Usage:
  perl bench/run-stream-competitor-comparison.pl --build \
    --systems linuxevent,anyevent-handle,uv-tcp,ioasync-stream,mojo-stream \
    --workload raw --clients 100,500,1000,2500 \
    --warmup 10 --messages 100 --bytes 64 \
    --client-workers 4 --repeats 5 --timeout 90 \
    --out bench/results/stream-competitor-raw.html \
    --json bench/results/stream-competitor-raw.json

Strict fairness contract:
  * every TCP connection is established and accepted before Stream timing
  * every server uses its normal high-level buffered Stream abstraction
  * raw and delimiter-framed workloads are ranked separately
  * every client uses the same serial one-request/one-reply protocol
  * warmup exchanges complete before server counters and timing are reset
  * clients stay connected after their final measured reply
  * connection teardown happens only after the measured server loop stops
  * no framework timeout callback runs during the measured interval
  * an external parent process provides catastrophic timeout protection
  * systems use a balanced rotating execution order across repeats

Systems:
  linuxevent       IO::Sock::Stream constructor closures
  anyevent-handle  AnyEvent::Handle on the EV backend
  uv-tcp           UV::TCP on libuv
  ioasync-stream   IO::Async::Stream on IO::Async::Loop::Epoll
  mojo-stream      Mojo::IOLoop::Stream on Mojo::Reactor::Epoll

For perfect execution-position balance, make --repeats a multiple of the
number of selected systems. The five-system default therefore uses 5 repeats.

Use --check-deps to report installed competitor versions and backend selection.
USAGE
}

sub fairness_contract {
    return {
        transport => 'TCP IPv4 loopback',
        protocol => 'serial request/reply; at most one outstanding request per client',
        workload => $workload,
        payload_bytes => $bytes,
        delimiter_hex => $workload eq 'delimiter' ? unpack('H*', $delimiter) : undef,
        wire_bytes_per_message => $bytes
            + ($workload eq 'delimiter' ? length($delimiter) : 0),
        server_api => 'normal high-level buffered Stream abstraction',
        preconnected => JSON::PP::true,
        accept_outside_timing => JSON::PP::true,
        stream_construction_outside_timing => JSON::PP::true,
        warmup_outside_timing => JSON::PP::true,
        teardown_outside_timing => JSON::PP::true,
        framework_timer_outside_timing => JSON::PP::true,
        client_workers => $client_workers,
        warmup_per_client => $warmup,
        measured_messages_per_client => $messages,
    };
}

sub check_deps {
    printf "Perl %s\n", $^V;
    my $le = eval {
        require Linux::Event::Loop;
        require Linux::Event::IO::Sock::Stream;
        1;
    };
    print $le ? "Linux::Event::IO::Sock::Stream: available\n"
        : "Linux::Event::IO::Sock::Stream: MISSING ($@)\n";

    my $ae = eval {
        local $ENV{PERL_ANYEVENT_MODEL} = 'EV';
        require AnyEvent;
        require AnyEvent::Handle;
        AnyEvent::detect();
        1;
    };
    if ($ae) {
        printf "AnyEvent::Handle: %s AnyEvent=%s model=%s\n",
            ($AnyEvent::Handle::VERSION // 'unknown'),
            ($AnyEvent::VERSION // 'unknown'),
            ($AnyEvent::MODEL // 'unknown');
    }
    else {
        print "AnyEvent: MISSING ($@)\n";
    }

    my $uv = eval {
        require UV;
        require UV::Loop;
        require UV::TCP;
        1;
    };
    if ($uv) {
        printf "UV: %s libuv=%s\n",
            ($UV::VERSION // 'unknown'),
            (eval { UV::version_string() } // 'unknown');
    }
    else {
        print "UV: MISSING ($@)\n";
    }

    my $ioa = eval {
        require IO::Async::Loop::Epoll;
        require IO::Async::Stream;
        1;
    };
    if ($ioa) {
        printf "IO::Async::Stream: %s Loop::Epoll=%s\n",
            ($IO::Async::Stream::VERSION // 'unknown'),
            ($IO::Async::Loop::Epoll::VERSION // 'unknown');
    }
    else {
        print "IO::Async::Loop::Epoll: MISSING ($@)\n";
    }

    my $mojo = eval {
        require Mojo::Reactor::Epoll;
        require Mojo::IOLoop::Stream;
        1;
    };
    if ($mojo) {
        printf "Mojo::IOLoop::Stream: %s Reactor::Epoll=%s\n",
            ($Mojo::IOLoop::Stream::VERSION // 'unknown'),
            ($Mojo::Reactor::Epoll::VERSION // 'unknown');
    }
    else {
        print "Mojo::Reactor::Epoll: MISSING ($@)\n";
    }
}

sub run_case_isolated ($system, $count, $repeat) {
    pipe(my $read_fh, my $write_fh) or die "case pipe failed: $!";
    my $pid = fork();
    die "case fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        close $read_fh;
        $case_result_fh = $write_fh;
        @case_child_pids = ();
        setpgrp(0, 0) or die "case process-group setup failed: $!";
        $SIG{PIPE} = 'IGNORE';
        my $payload;
        my $ok = eval {
            my $result = run_case($system, $count, $repeat);
            $payload = encode_json({ worker_ok => JSON::PP::true, result => $result });
            1;
        };
        if (!$ok) {
            my $err = $@ || 'unknown worker error';
            chomp $err;
            cleanup_case_children();
            $payload = encode_json({ worker_ok => JSON::PP::false, error => $err });
        }
        print {$write_fh} $payload;
        close $write_fh;
        exit($ok ? 0 : 1);
    }

    close $write_fh;
    my $guard = $timeout + 180 + int($count / 500);
    my $select = IO::Select->new($read_fh);
    if (!$select->can_read($guard)) {
        kill 'TERM', -$pid;
        usleep(100_000);
        kill 'KILL', -$pid if kill 0, $pid;
        waitpid($pid, 0);
        close $read_fh;
        die "case worker exceeded external timeout (${guard}s)";
    }

    local $/;
    my $txt = <$read_fh>;
    close $read_fh;
    waitpid($pid, 0);

    die "case worker produced no result" unless defined $txt && length $txt;
    my $envelope = decode_json($txt);
    die ($envelope->{error} || 'case worker failed') unless $envelope->{worker_ok};
    return $envelope->{result};
}

sub run_case ($system, $count, $repeat) {
    my $server = IO::Socket::INET->new(
        LocalAddr => $host,
        LocalPort => 0,
        Proto => 'tcp',
        Listen => 8192,
        ReuseAddr => 1,
    ) or die "listen failed: $!";
    $server->blocking(0);
    my $port = $server->sockport;

    my $tmp = tempdir(CLEANUP => 1);
    my $warmup_gate = "$tmp/warmup-go";
    my $measure_gate = "$tmp/measure-go";
    my $teardown_gate = "$tmp/teardown-go";
    my @ready_files;
    my @warmup_done_files;
    my @measure_done_files;
    my @client_files;
    my @pids;
    my $payload = 'x' x $bytes;
    my $msg = $payload . ($workload eq 'delimiter' ? $delimiter : '');
    my $wire_bytes = length($msg);

    my $workers = $client_workers > $count ? $count : $client_workers;
    my $base = int($count / $workers);
    my $extra = $count % $workers;
    for my $worker (1 .. $workers) {
        my $worker_clients = $base + ($worker <= $extra ? 1 : 0);
        my $ready = "$tmp/ready-$worker";
        my $warm_done = "$tmp/warmup-done-$worker";
        my $measure_done = "$tmp/measure-done-$worker";
        my $result = "$tmp/client-$worker.json";
        push @ready_files, $ready;
        push @warmup_done_files, $warm_done;
        push @measure_done_files, $measure_done;
        push @client_files, $result;
        my $pid = fork();
        die "client worker fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            close $case_result_fh if $case_result_fh;
            $SIG{PIPE} = 'IGNORE';
            $SIG{TERM} = sub { exit 143 };
            strict_client_worker(
                $port, $worker_clients, $msg,
                $ready, $warmup_gate, $warm_done,
                $measure_gate, $measure_done,
                $teardown_gate, $result,
            );
            exit 0;
        }
        push @pids, $pid;
        push @case_child_pids, $pid;
    }

    # Accept every connection directly, before any event framework is loaded or
    # any callback is registered. This removes accept-loop differences entirely.
    my @sockets;
    my $setup_deadline = time + $timeout + 120;
    while (@sockets < $count && time < $setup_deadline) {
        my $accepted = 0;
        while (my $sock = $server->accept) {
            $sock->blocking(0);
            push @sockets, $sock;
            $accepted++;
        }
        usleep(100) unless $accepted;
    }
    die "setup accepted=" . scalar(@sockets) . "/$count" if @sockets != $count;

    wait_for_files(\@ready_files, $setup_deadline, 'client ready barrier');
    close $server;

    pipe(my $control_read, my $control_write)
        or die "control pipe failed: $!";
    my $control_pid = fork();
    die "control worker fork failed: $!" if !defined $control_pid;
    if ($control_pid == 0) {
        close $case_result_fh if $case_result_fh;
        close $control_read;
        wait_for_files(\@warmup_done_files, $setup_deadline,
            'control warmup barrier');
        syswrite($control_write, 'w') == 1 or exit 2;
        wait_for_files(\@measure_done_files, time + $timeout + 120,
            'control measure barrier');
        syswrite($control_write, 'm') == 1 or exit 3;
        close $control_write;
        exit 0;
    }
    push @case_child_pids, $control_pid;
    close $control_write;

    my %c;
    reset_app_counters(\%c);
    my %phase = (done => 0, failed => 0, expected_signal => 'w', stop => sub { });
    my $driver = setup_stream(
        $system, \@sockets, \%c, \%phase, $control_read,
    );

    # A control pipe stops each framework only after every client has received
    # its final reply. This includes each Stream implementation's output queue
    # without adding a framework timer to the measured path.
    $phase{stop} = $driver->{make_stop}->(\%phase);
    touch_gate($warmup_gate);
    $driver->{run}->(\%phase);
    die "warmup failed" if $phase{failed};
    my $warmup_target_bytes = $count * $warmup * $wire_bytes;
    die "warmup bytes=$c{bytes_queued}/$warmup_target_bytes"
        if $c{bytes_queued} != $warmup_target_bytes;

    reset_app_counters(\%c);
    $driver->{reset_stats}->();

    my $target_bytes = $count * $messages * $wire_bytes;
    $phase{done} = 0;
    $phase{failed} = 0;
    $phase{expected_signal} = 'm';
    $phase{stop} = $driver->{make_stop}->(\%phase);

    my $cs_before = context_switches();
    my @times_before = times();
    my $reactor_before = $driver->{iterations}->();
    my $start = time;
    touch_gate($measure_gate);
    $driver->{run}->(\%phase);
    my $elapsed = time - $start;
    my $reactor_after = $driver->{iterations}->();
    my @times_after = times();
    my $cs_after = context_switches();

    # Clients have received all measured replies but deliberately remain open.
    # Their close/EOF/RDHUP behaviour is therefore outside the measured window.
    my $post_deadline = time + 30;
    wait_for_files(\@measure_done_files, $post_deadline, 'measure done barrier');
    waitpid($control_pid, 0);
    my $control_failure = $? != 0 ? 1 : 0;
    close $control_read;
    touch_gate($teardown_gate);

    my $client_failures = reap_clients(\@pids, 30);
    my ($client_results, $file_failures) = load_client_results(\@client_files);
    $client_failures += $file_failures;

    my @lat;
    my $client_measured = 0;
    for my $cr (@$client_results) {
        $client_measured += $cr->{measured_messages} // 0;
        push @lat, @{ $cr->{latency_us} || [] };
    }
    @lat = sort { $a <=> $b } @lat;

    my $total_messages = $count * $messages;
    my $ok = !$phase{failed}
        && !$client_failures
        && !$control_failure
        && $client_measured == $total_messages
        && $c{bytes_read} == $target_bytes
        && $c{bytes_queued} == $target_bytes
        && $c{echoed_bytes} == $target_bytes
        && ($workload ne 'delimiter' || $c{messages_read} == $total_messages)
        && $c{unexpected_closes} == 0;

    my $user_cpu = $times_after[0] - $times_before[0];
    my $sys_cpu = $times_after[1] - $times_before[1];
    my $total_cpu = $user_cpu + $sys_cpu;
    my $reactor_iterations = defined($reactor_after) && defined($reactor_before)
        ? $reactor_after - $reactor_before
        : undef;
    my $meta = $driver->{metadata}->();

    my %result = (
        system => display_system($system),
        system_key => $system,
        clients => $count,
        messages => $total_messages,
        messages_per_client => $messages,
        warmup_messages => $count * $warmup,
        warmup_per_client => $warmup,
        bytes => $bytes,
        payload_bytes => $bytes,
        wire_bytes_per_message => $wire_bytes,
        delimiter_hex => $workload eq 'delimiter' ? unpack('H*', $delimiter) : undef,
        workload => $workload,
        client_workers => $workers,
        repeat => $repeat,
        preconnected => JSON::PP::true,
        warmup_outside_timing => JSON::PP::true,
        teardown_outside_timing => JSON::PP::true,
        high_level_stream_api => JSON::PP::true,
        elapsed_seconds => num($elapsed),
        messages_per_second => $ok ? num($total_messages / $elapsed) : undef,
        attempt_messages_per_second => num($total_messages / $elapsed),
        mib_per_second => $ok ? num((($total_messages * $wire_bytes) / 1048576) / $elapsed) : undef,
        ok => $ok ? JSON::PP::true : JSON::PP::false,
        rankable => $ok ? JSON::PP::true : JSON::PP::false,
        failure_reason => $ok ? undef : join('; ', grep length,
            ($phase{failed} ? 'stream phase failed' : ''),
            ($c{last_error} ? "error=$c{last_error}" : ''),
            ($client_failures ? "client failures=$client_failures" : ''),
            ($control_failure ? 'control worker failed' : ''),
            ($client_measured != $total_messages ? "client_measured=$client_measured/$total_messages" : ''),
            ($c{bytes_read} != $target_bytes ? "bytes_read=$c{bytes_read}/$target_bytes" : ''),
            ($c{bytes_queued} != $target_bytes ? "bytes_queued=$c{bytes_queued}/$target_bytes" : ''),
            ($workload eq 'delimiter' && $c{messages_read} != $total_messages
                ? "messages_read=$c{messages_read}/$total_messages" : ''),
            ($c{unexpected_closes} ? "unexpected_closes=$c{unexpected_closes}" : ''),
        ),
        client_failures => $client_failures,
        client_measured_messages => $client_measured,
        latency_samples => scalar @lat,
        lat_p50_us => pct(\@lat, 50),
        lat_p95_us => pct(\@lat, 95),
        lat_p99_us => pct(\@lat, 99),
        lat_max_us => @lat ? $lat[-1] : undef,
        perl_version => "$^V",
        linux_kernel => scalar(`uname -r`) =~ s/\s+\z//r,
        max_rss_kb => max_rss_kb(),
        server_user_cpu_seconds => num($user_cpu),
        server_system_cpu_seconds => num($sys_cpu),
        server_total_cpu_seconds => num($total_cpu),
        server_cpu_us_per_message => $total_messages ? num(($total_cpu / $total_messages) * 1_000_000) : undef,
        server_cpu_percent => $elapsed > 0 ? num(($total_cpu / $elapsed) * 100) : 0,
        voluntary_ctxt_switches => ($cs_after->{voluntary} // 0) - ($cs_before->{voluntary} // 0),
        nonvoluntary_ctxt_switches => ($cs_after->{nonvoluntary} // 0) - ($cs_before->{nonvoluntary} // 0),
        reactor_iterations => $reactor_iterations,
        read_callbacks_per_message => $total_messages
            ? num($c{read_callbacks} / $total_messages) : undef,
        work_signature => sprintf(
            'tcp_payload=%d;wire=%d;workload=%s;delimiter=%s;serial=1;preconnected=1;stream_api=1',
            $bytes, $wire_bytes, $workload,
            $workload eq 'delimiter' ? unpack('H*', $delimiter) : 'none',
        ),
        %c,
        %$meta,
    );

    if ($driver->{stats}) {
        my $st = $driver->{stats}->();
        for my $key (keys %$st) {
            $result{$key} = $st->{$key};
        }
    }

    $driver->{cleanup}->();
    close $_ for @sockets;
    return \%result;
}

sub setup_stream ($system, $sockets, $c, $phase, $control_read) {
    return setup_linuxevent_stream($sockets, $c, $phase, $control_read)
        if $system eq 'linuxevent';
    return setup_anyevent_handle($sockets, $c, $phase, $control_read)
        if $system eq 'anyevent-handle';
    return setup_uv_tcp($sockets, $c, $phase, $control_read)
        if $system eq 'uv-tcp';
    return setup_ioasync_stream($sockets, $c, $phase, $control_read)
        if $system eq 'ioasync-stream';
    return setup_mojo_stream($sockets, $c, $phase, $control_read)
        if $system eq 'mojo-stream';
    die "unsupported system $system";
}

sub setup_linuxevent_stream ($sockets, $c, $phase, $control_read) {
    require Linux::Event::Loop;
    require Linux::Event::IO::Sock::Stream;
    my $loop = Linux::Event::Loop->new;
    my @streams;

    my $on_error = sub ($stream, $error) {
        stream_error($c, $phase, "$error");
    };
    my $on_eof = sub ($stream) {
        unexpected_stream_close($c, $phase);
    };
    my $input;
    my $class = 'Linux::Event::IO::Sock::Stream';
    if ($workload eq 'raw') {
        $input = sub ($stream, $chunk) {
            record_raw_input($c, $chunk);
            $stream->write($chunk);
            $c->{bytes_queued} += length($chunk);
            $c->{echoed_bytes} += length($chunk);
        };
    }
    else {
        require Linux::Event::Framer;
        $class = 'Linux::Event::Bench::CompetitorDelimitedStream';
        if (!$class->can('stream_options')) {
            my $ok = eval q{
                package Linux::Event::Bench::CompetitorDelimitedStream;
                use parent -norequire, 'Linux::Event::IO::Sock::Stream';
                use Linux::Event::Framer 'Delimiter', "\x00\xffLE\x7f";
                sub stream_options ($class) { return read_size => 65_536; }
                1;
            };
            die $@ if !$ok;
        }
        $input = sub ($stream, $message) {
            record_framed_input($c, $message);
            $stream->send($message);
            my $wire = length($message) + length($delimiter);
            $c->{bytes_queued} += $wire;
            $c->{echoed_bytes} += $wire;
        };
    }

    for my $sock (@$sockets) {
        my %input_option = $workload eq 'raw'
            ? (on_data => $input) : (on_message => $input);
        push @streams, $class->new(
            loop => $loop,
            fh => $sock,
            %input_option,
            on_error => $on_error,
            on_eof => $on_eof,
        );
    }

    my $control = $loop->watch(
        fh => $control_read,
        read => sub { control_ready($control_read, $phase); },
        # epoll reports HUP together with readable when the control worker
        # writes its final marker and closes the pipe. Drain the marker first.
        error => sub { control_ready($control_read, $phase); },
    );

    return {
        make_stop => sub ($p) {
            return sub {
                $p->{done} = 1;
                $loop->stop;
            };
        },
        run => sub ($p) {
            $loop->run unless $p->{done} || $p->{failed};
        },
        iterations => sub { return $loop->stats->{epoll_wait_calls} // 0; },
        reset_stats => sub { $loop->reset_stats; },
        metadata => sub {
            return {
                framework => 'Linux::Event',
                backend => 'Linux::Event::IO::Sock::Stream',
                backend_runtime => 'epoll',
                callback_api => $workload eq 'raw'
                    ? 'constructor on_data closure'
                    : 'constructor on_message closure with native Delimiter framer',
                callback_reuse => 'one shared input CV per case',
                linux_event_version => version_text($Linux::Event::VERSION),
            };
        },
        stats => sub {
            my %sum;
            for my $stream (@streams) {
                my $stats = $stream->{xs_state}->stats;
                $sum{"linuxevent_$_"} += $stats->{$_} // 0
                    for qw(read_calls write_calls delivery_calls
                        message_callback_calls frames_emitted read_eagain_count
                        write_eagain_count bytes_read bytes_written);
            }
            return \%sum;
        },
        cleanup => sub {
            $control->cancel;
            for my $stream (@streams) {
                $stream->close if !$stream->is_closed;
            }
            @streams = ();
        },
    };
}

sub setup_anyevent_handle ($sockets, $c, $phase, $control_read) {
    local $ENV{PERL_ANYEVENT_MODEL} = 'EV';
    require AnyEvent;
    require AnyEvent::Handle;
    AnyEvent::detect();
    die "AnyEvent backend is not EV: " . ($AnyEvent::MODEL // 'undef')
        if ($AnyEvent::MODEL // '') ne 'AnyEvent::Impl::EV';
    require EV;

    my $input = sub ($handle) {
        if ($workload eq 'raw') {
            my $chunk = substr($handle->{rbuf}, 0, length($handle->{rbuf}), '');
            return if $chunk eq '';
            record_raw_input($c, $chunk);
            $handle->push_write($chunk);
            $c->{bytes_queued} += length($chunk);
            $c->{echoed_bytes} += length($chunk);
            return;
        }
        consume_delimited_buffer(
            \$handle->{rbuf},
            sub ($message) { $handle->push_write($message . $delimiter); },
            $c,
        );
    };
    my @handles = map {
        AnyEvent::Handle->new(
            fh => $_,
            read_size => 65_536,
            max_read_size => 65_536,
            on_read => $input,
            on_error => sub ($handle, $fatal, $message) {
                stream_error($c, $phase, $message);
            },
            on_eof => sub ($handle) {
                unexpected_stream_close($c, $phase);
            },
        )
    } @$sockets;

    my $current_cv;
    my $control = AE::io($control_read, 0, sub {
        control_ready($control_read, $phase);
    });

    return {
        make_stop => sub ($p) {
            $current_cv = AE::cv();
            return sub {
                $p->{done} = 1;
                $current_cv->send if !$current_cv->ready;
            };
        },
        run => sub ($p) {
            $current_cv->recv unless $p->{done} || $p->{failed};
        },
        iterations => sub { return EV::iteration(); },
        reset_stats => sub { },
        metadata => sub {
            return {
                framework => 'AnyEvent',
                backend => 'AnyEvent::Handle',
                backend_runtime => ev_backend_name(),
                callback_api => $workload eq 'raw'
                    ? 'on_read closure using rbuf'
                    : 'on_read closure using buffered delimiter parsing',
                callback_reuse => 'one shared input CV per case',
                anyevent_version => version_text($AnyEvent::VERSION),
                anyevent_handle_version => version_text($AnyEvent::Handle::VERSION),
                anyevent_model => $AnyEvent::MODEL,
            };
        },
        cleanup => sub {
            undef $control;
            $_->destroy for @handles;
            @handles = ();
            undef $current_cv;
        },
    };
}

sub setup_uv_tcp ($sockets, $c, $phase, $control_read) {
    require Scalar::Util;
    require UV;
    require UV::Loop;
    require UV::Poll;
    require UV::TCP;

    my $loop = UV::Loop->new;
    my %buffers;
    my @streams;
    my $input = sub ($stream, $error, $chunk) {
        if (defined($error) && $error) {
            stream_error($c, $phase, "$error");
            return;
        }
        if (!defined($chunk) || $chunk eq '') {
            unexpected_stream_close($c, $phase);
            return;
        }
        if ($workload eq 'raw') {
            record_raw_input($c, $chunk);
            $stream->write($chunk);
            $c->{bytes_queued} += length($chunk);
            $c->{echoed_bytes} += length($chunk);
            return;
        }
        my $key = Scalar::Util::refaddr($stream);
        $buffers{$key} .= $chunk;
        consume_delimited_buffer(
            \$buffers{$key},
            sub ($message) { $stream->write($message . $delimiter); },
            $c,
        );
    };

    for my $sock (@$sockets) {
        my $stream = UV::TCP->new(loop => $loop);
        $stream->open($sock);
        $stream->on(read => $input);
        $stream->read_start;
        push @streams, $stream;
    }

    my $control = UV::Poll->new(fd => fileno($control_read), loop => $loop);
    $control->start(UV::Poll::UV_READABLE(), sub ($poll, $status, $events) {
        if ($status < 0) {
            stream_error($c, $phase, "control status $status");
            return;
        }
        control_ready($control_read, $phase)
            if $events & UV::Poll::UV_READABLE();
    });

    return {
        make_stop => sub ($p) {
            return sub {
                $p->{done} = 1;
                $loop->stop;
            };
        },
        run => sub ($p) {
            $loop->run unless $p->{done} || $p->{failed};
        },
        iterations => sub { return undef; },
        reset_stats => sub { },
        metadata => sub {
            return {
                framework => 'UV',
                backend => 'UV::TCP',
                backend_runtime => 'epoll via libuv',
                callback_api => $workload eq 'raw'
                    ? 'UV::TCP read closure'
                    : 'UV::TCP read closure using buffered delimiter parsing',
                callback_reuse => 'one shared input CV per case',
                uv_version => version_text($UV::VERSION),
                libuv_version => version_text(eval { UV::version_string() }),
            };
        },
        cleanup => sub {
            $control->stop;
            for my $stream (@streams) {
                eval { $stream->read_stop };
                eval { $stream->close };
            }
            @streams = ();
            %buffers = ();
        },
    };
}

sub setup_ioasync_stream ($sockets, $c, $phase, $control_read) {
    require IO::Async::Loop::Epoll;
    require IO::Async::Stream;
    my $loop = IO::Async::Loop::Epoll->new;

    my $input = sub ($stream, $buffer, $eof) {
        if ($eof) {
            unexpected_stream_close($c, $phase);
            return 0;
        }
        if ($workload eq 'raw') {
            my $chunk = $$buffer;
            $$buffer = '';
            return 0 if $chunk eq '';
            record_raw_input($c, $chunk);
            $stream->write($chunk);
            $c->{bytes_queued} += length($chunk);
            $c->{echoed_bytes} += length($chunk);
            return 0;
        }
        consume_delimited_buffer(
            $buffer,
            sub ($message) { $stream->write($message . $delimiter); },
            $c,
        );
        return 0;
    };

    my @streams;
    for my $sock (@$sockets) {
        my $stream = IO::Async::Stream->new(
            handle => $sock,
            on_read => $input,
            on_read_error => sub ($stream, $error) {
                stream_error($c, $phase, "$error");
            },
            on_write_error => sub ($stream, $error) {
                stream_error($c, $phase, "$error");
            },
            read_len => 65_536,
            autoflush => 1,
        );
        $loop->add($stream);
        push @streams, $stream;
    }
    $loop->watch_io(
        handle => $control_read,
        on_read_ready => sub { control_ready($control_read, $phase); },
    );

    return {
        make_stop => sub ($p) {
            return sub {
                $p->{done} = 1;
                $loop->stop;
            };
        },
        run => sub ($p) {
            $loop->run unless $p->{done} || $p->{failed};
        },
        iterations => sub { return undef; },
        reset_stats => sub { },
        metadata => sub {
            return {
                framework => 'IO::Async',
                backend => 'IO::Async::Stream',
                backend_runtime => 'IO::Async::Loop::Epoll',
                callback_api => $workload eq 'raw'
                    ? 'on_read closure'
                    : 'on_read closure using buffered delimiter parsing',
                callback_reuse => 'one shared input CV per case',
                ioasync_stream_version => version_text($IO::Async::Stream::VERSION),
                ioasync_loop_epoll_version
                    => version_text($IO::Async::Loop::Epoll::VERSION),
            };
        },
        cleanup => sub {
            $loop->unwatch_io(handle => $control_read, on_read_ready => 1);
            for my $stream (@streams) {
                eval { $loop->remove($stream) };
                eval { $stream->close_now };
            }
            @streams = ();
        },
    };
}

sub setup_mojo_stream ($sockets, $c, $phase, $control_read) {
    require Scalar::Util;
    require Mojo::IOLoop::Stream;
    require Mojo::Reactor::Epoll;
    my $reactor = Mojo::Reactor::Epoll->new;
    my %buffers;

    my $input = sub ($stream, $chunk) {
        if ($workload eq 'raw') {
            record_raw_input($c, $chunk);
            $stream->write($chunk);
            $c->{bytes_queued} += length($chunk);
            $c->{echoed_bytes} += length($chunk);
            return;
        }
        my $key = Scalar::Util::refaddr($stream);
        $buffers{$key} .= $chunk;
        consume_delimited_buffer(
            \$buffers{$key},
            sub ($message) { $stream->write($message . $delimiter); },
            $c,
        );
    };

    my @streams;
    for my $sock (@$sockets) {
        my $stream = Mojo::IOLoop::Stream->new($sock);
        $stream->reactor($reactor);
        $stream->timeout(0);
        $stream->on(read => $input);
        $stream->on(error => sub ($stream, $error) {
            stream_error($c, $phase, "$error");
        });
        $stream->on(close => sub ($stream) {
            unexpected_stream_close($c, $phase);
        });
        $stream->start;
        push @streams, $stream;
    }

    $reactor->io($control_read => sub ($r, $writable) {
        control_ready($control_read, $phase) if !$writable;
    })->watch($control_read, 1, 0);

    return {
        make_stop => sub ($p) {
            return sub {
                $p->{done} = 1;
                $reactor->stop;
            };
        },
        run => sub ($p) {
            $reactor->start unless $p->{done} || $p->{failed};
        },
        iterations => sub { return undef; },
        reset_stats => sub { },
        metadata => sub {
            return {
                framework => 'Mojolicious',
                backend => 'Mojo::IOLoop::Stream',
                backend_runtime => 'Mojo::Reactor::Epoll',
                callback_api => $workload eq 'raw'
                    ? 'read event closure'
                    : 'read event closure using buffered delimiter parsing',
                callback_reuse => 'one shared input CV per case',
                mojo_stream_version => version_text($Mojo::IOLoop::Stream::VERSION),
                mojo_reactor_epoll_version
                    => version_text($Mojo::Reactor::Epoll::VERSION),
            };
        },
        cleanup => sub {
            $reactor->remove($control_read);
            for my $stream (@streams) {
                $stream->stop;
                eval { $stream->steal_handle };
            }
            $reactor->reset;
            @streams = ();
            %buffers = ();
        },
    };
}

sub record_raw_input ($c, $chunk) {
    die "empty raw callback" if $chunk eq '';
    die "raw payload corruption" if $chunk =~ /[^x]/;
    $c->{read_callbacks}++;
    $c->{bytes_read} += length($chunk);
}

sub record_framed_input ($c, $message) {
    die "framed payload mismatch" if $message ne ('x' x $bytes);
    $c->{read_callbacks}++;
    $c->{messages_read}++;
    $c->{bytes_read} += length($message) + length($delimiter);
}

sub consume_delimited_buffer ($buffer, $writer, $c) {
    while (1) {
        my $at = index($$buffer, $delimiter);
        last if $at < 0;
        my $message = substr($$buffer, 0, $at, '');
        substr($$buffer, 0, length($delimiter), '');
        record_framed_input($c, $message);
        $writer->($message);
        my $wire = length($message) + length($delimiter);
        $c->{bytes_queued} += $wire;
        $c->{echoed_bytes} += $wire;
    }
}

sub control_ready ($control_read, $phase) {
    my $read = sysread($control_read, my $signals, 16);
    if (!defined $read || $read == 0) {
        return if $phase->{done};
        $phase->{failed} = 1;
        $phase->{stop}->() if !$phase->{done};
        return;
    }
    if (index($signals, $phase->{expected_signal}) < 0) {
        $phase->{failed} = 1;
        $phase->{stop}->() if !$phase->{done};
        return;
    }
    $phase->{stop}->() if !$phase->{done};
}

sub stream_error ($c, $phase, $message) {
    $c->{error_callbacks}++;
    $c->{last_error} = $message;
    $phase->{failed} = 1;
    $phase->{stop}->() unless $phase->{done};
}

sub unexpected_stream_close ($c, $phase) {
    return if $phase->{done};
    $c->{unexpected_closes}++;
    $phase->{failed} = 1;
    $phase->{stop}->();
}

sub reset_app_counters ($c) {
    %$c = (
        read_callbacks => 0,
        error_callbacks => 0,
        unexpected_closes => 0,
        messages_read => 0,
        bytes_read => 0,
        bytes_queued => 0,
        echoed_bytes => 0,
        last_error => undef,
    );
}

sub strict_client_worker (
    $port, $count, $msg,
    $ready_file, $warmup_gate, $warmup_done_file,
    $measure_gate, $measure_done_file,
    $teardown_gate, $out_file,
) {
    my $poll = IO::Poll->new;
    my %state;
    my $failed = 0;

    for my $id (1 .. $count) {
        my $sock;
        for (1 .. 5000) {
            $sock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp');
            last if $sock;
            usleep(1000);
        }
        if (!$sock) {
            $failed++;
            next;
        }
        $sock->blocking(0);
        my $fd = fileno($sock);
        $state{$fd} = { sock => $sock };
        $poll->mask($sock => POLLIN | POLLERR | POLLHUP);
    }

    write_marker($ready_file, scalar keys %state);
    wait_for_gate($warmup_gate, $timeout + 120);

    if ($warmup > 0 && %state) {
        my ($ok) = client_run_phase($poll, \%state, $msg, $warmup, 0);
        $failed++ unless $ok;
    }
    write_marker($warmup_done_file, 1);

    wait_for_gate($measure_gate, $timeout + 120);
    my @lat;
    my $measured = 0;
    if (%state) {
        my ($ok, $done, $lats) = client_run_phase($poll, \%state, $msg, $messages, 1);
        $failed++ unless $ok;
        $measured = $done;
        @lat = @$lats;
    }

    write_json($out_file, {
        ok => $failed ? JSON::PP::false : JSON::PP::true,
        measured_messages => $measured,
        latency_us => \@lat,
        failures => $failed,
    });
    write_marker($measure_done_file, 1);

    wait_for_gate($teardown_gate, 60);
    for my $st (values %state) {
        close $st->{sock};
    }
    exit($failed ? 1 : 0);
}

sub client_run_phase ($poll, $state, $msg, $phase_messages, $record_latency) {
    my $active = 0;
    my $failed = 0;
    my $total_done = 0;
    my @lat;

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

    my $deadline = time + $timeout + 30;
    while ($active > 0 && time < $deadline) {
        my $nready = $poll->poll(0.05);
        next unless $nready;
        for my $fh ($poll->handles(POLLERR | POLLHUP | POLLIN | POLLOUT)) {
            my $fd = fileno($fh);
            my $st = $state->{$fd} or next;
            next if $st->{phase_done} >= $phase_messages;
            my $ev = $poll->events($fh);

            if (($ev & (POLLERR | POLLHUP)) && !($ev & POLLIN)) {
                $failed++;
                $st->{phase_done} = $phase_messages;
                $active--;
                $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                next;
            }

            if (($ev & POLLOUT) && $st->{write_active}) {
                my $message_length = length($msg);
                my $remain = $message_length - $st->{write_off};
                my $wr = syswrite($fh, $msg, $remain, $st->{write_off});
                if (defined $wr && $wr > 0) {
                    $st->{write_off} += $wr;
                    if ($st->{write_off} >= $message_length) {
                        $st->{write_active} = 0;
                        $st->{awaiting_reply} = 1;
                        $st->{write_off} = 0;
                        $st->{phase_sent}++;
                        $st->{lat_start} = time if $record_latency;
                        $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                    }
                }
                elsif (!defined $wr && ($!{EAGAIN} || $!{EWOULDBLOCK})) {
                }
                else {
                    $failed++;
                    $st->{phase_done} = $phase_messages;
                    $active--;
                    $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                    next;
                }
            }

            if (($ev & POLLIN) && $st->{awaiting_reply}) {
                my $need = length($msg) - $st->{recv_len};
                my $n = sysread($fh, my $buf, $need);
                if (defined $n && $n > 0) {
                    $st->{recv_len} += $n;
                    $st->{recv_buf} .= $buf;
                    if ($st->{recv_len} >= length($msg)) {
                        if ($st->{recv_buf} ne $msg) {
                            $failed++;
                            $st->{phase_done} = $phase_messages;
                            $active--;
                            $poll->mask($fh => POLLIN | POLLERR | POLLHUP);
                            next;
                        }
                        if ($record_latency && defined $st->{lat_start}) {
                            push @lat, int((time - $st->{lat_start}) * 1_000_000);
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
                            $poll->mask($fh => POLLIN | POLLOUT | POLLERR | POLLHUP);
                        }
                    }
                }
                elsif (defined $n && $n == 0) {
                    $failed++;
                    $st->{phase_done} = $phase_messages;
                    $active--;
                }
                elsif (!defined $n && ($!{EAGAIN} || $!{EWOULDBLOCK})) {
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
    return ($failed ? 0 : 1, $total_done, \@lat);
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

sub wait_for_gate ($path, $seconds) {
    my $deadline = time + $seconds;
    until (-e $path) {
        die "gate timeout: $path" if time >= $deadline;
        usleep(100);
    }
}

sub wait_for_files ($files, $deadline, $label) {
    while (time < $deadline) {
        return unless grep { !-e $_ } @$files;
        usleep(100);
    }
    die "$label timeout" if grep { !-e $_ } @$files;
}

sub reap_clients ($pids, $seconds) {
    my $failures = 0;
    for my $pid (@$pids) {
        my $deadline = time + $seconds;
        my $done = 0;
        while (time < $deadline) {
            my $wp = waitpid($pid, WNOHANG);
            if ($wp == $pid || $wp == -1) {
                $done = 1;
                $failures++ if $wp == $pid && $? != 0;
                last;
            }
            usleep(10_000);
        }
        if (!$done && kill 0, $pid) {
            $failures++;
            kill 'TERM', $pid;
            waitpid($pid, 0);
        }
    }
    return $failures;
}

sub cleanup_case_children {
    my @live = grep { $_ > 0 && kill 0, $_ } @case_child_pids;
    kill 'TERM', @live if @live;
    for my $pid (@live) {
        my $deadline = time + 1;
        while (time < $deadline) {
            last if waitpid($pid, WNOHANG) != 0;
            usleep(10_000);
        }
        if (kill 0, $pid) {
            kill 'KILL', $pid;
            waitpid($pid, 0);
        }
    }
    @case_child_pids = ();
}

sub load_client_results ($files) {
    my @results;
    my $failures = 0;
    for my $file (@$files) {
        if (!-e $file) {
            $failures++;
            next;
        }
        open my $fh, '<', $file or do { $failures++; next; };
        local $/;
        my $cr = eval { decode_json(<$fh>) };
        close $fh;
        if (!$cr || !$cr->{ok}) {
            $failures++;
            next;
        }
        push @results, $cr;
    }
    return (\@results, $failures);
}

sub ev_backend_name {
    return 'unknown' unless defined &EV::backend;
    my $backend = EV::backend();
    for my $name (qw(SELECT POLL EPOLL KQUEUE DEVPOLL PORT LINUXAIO IOURING)) {
        my $sub = EV->can("BACKEND_$name") or next;
        my $value = eval { $sub->() };
        return "${name}($backend)" if defined $value && $value == $backend;
    }
    return "backend-$backend";
}

sub display_system ($system) {
    return 'Linux::Event IO::Sock::Stream closures'
        if $system eq 'linuxevent';
    return 'AnyEvent::Handle on EV' if $system eq 'anyevent-handle';
    return 'UV::TCP on libuv' if $system eq 'uv-tcp';
    return 'IO::Async::Stream on Loop::Epoll'
        if $system eq 'ioasync-stream';
    return 'Mojo::IOLoop::Stream on Reactor::Epoll'
        if $system eq 'mojo-stream';
    return $system;
}

sub failure_result ($system, $count, $repeat, $err) {
    my $wire_bytes = $bytes
        + ($workload eq 'delimiter' ? length($delimiter) : 0);
    return {
        system => display_system($system),
        system_key => $system,
        clients => $count,
        messages => $count * $messages,
        messages_per_client => $messages,
        warmup_per_client => $warmup,
        bytes => $bytes,
        payload_bytes => $bytes,
        wire_bytes_per_message => $wire_bytes,
        delimiter_hex => $workload eq 'delimiter'
            ? unpack('H*', $delimiter) : undef,
        workload => $workload,
        client_workers => $client_workers,
        repeat => $repeat,
        ok => JSON::PP::false,
        rankable => JSON::PP::false,
        high_level_stream_api => JSON::PP::true,
        failure_reason => $err,
        messages_per_second => undef,
        work_signature => sprintf(
            'tcp_payload=%d;wire=%d;workload=%s;delimiter=%s;serial=1;preconnected=1;stream_api=1',
            $bytes, $wire_bytes, $workload,
            $workload eq 'delimiter' ? unpack('H*', $delimiter) : 'none',
        ),
    };
}

sub summarize ($results) {
    my @summary;
    for my $system (@systems) {
        for my $count (@clients) {
            my @r = grep {
                $_->{system_key} eq $system && $_->{clients} == $count && $_->{ok}
            } @$results;
            next unless @r;
            push @summary, {
                system => display_system($system),
                system_key => $system,
                backend => ($r[0]{backend_runtime} // $r[0]{backend} // ''),
                workload => $workload,
                payload_bytes => $bytes,
                clients => $count,
                repeats => scalar @r,
                median_messages_per_second => median(map { $_->{messages_per_second} } @r),
                mean_messages_per_second => mean(map { $_->{messages_per_second} } @r),
                median_elapsed_seconds => median(map { $_->{elapsed_seconds} } @r),
                median_lat_p50_us => median(grep { defined } map { $_->{lat_p50_us} } @r),
                median_lat_p95_us => median(grep { defined } map { $_->{lat_p95_us} } @r),
                median_lat_p99_us => median(grep { defined } map { $_->{lat_p99_us} } @r),
                median_server_cpu_us_per_message => median(map { $_->{server_cpu_us_per_message} } @r),
                median_server_cpu_percent => median(map { $_->{server_cpu_percent} } @r),
                median_max_rss_kb => median(map { $_->{max_rss_kb} } @r),
                median_reactor_iterations => median(grep { defined } map { $_->{reactor_iterations} } @r),
                median_read_callbacks_per_message => median(map { $_->{read_callbacks_per_message} } @r),
            };
        }
    }
    my @ranked;
    for my $count (@clients) {
        my @group = sort {
            $b->{median_messages_per_second}
                <=> $a->{median_messages_per_second}
                || $a->{system_key} cmp $b->{system_key}
        } grep { $_->{clients} == $count } @summary;
        for my $index (0 .. $#group) {
            $group[$index]{throughput_rank} = $index + 1;
        }
        push @ranked, @group;
    }
    return @ranked;
}

sub median (@values) {
    return undef unless @values;
    @values = sort { $a <=> $b } @values;
    my $n = @values;
    return $values[int($n / 2)] if $n % 2;
    return ($values[$n / 2 - 1] + $values[$n / 2]) / 2;
}

sub mean (@values) {
    return undef unless @values;
    my $sum = 0;
    $sum += $_ for @values;
    return $sum / @values;
}

sub pct ($arr, $p) {
    return undef unless @$arr;
    my $idx = int((@$arr - 1) * ($p / 100));
    return $arr->[$idx];
}

sub version_text ($value) {
    return 'unknown' unless defined $value;
    return "$value";
}

sub num ($value) {
    return 0 + sprintf('%.6f', $value);
}

sub max_rss_kb {
    return 0 unless -r '/proc/self/status';
    open my $fh, '<', '/proc/self/status' or return 0;
    while (<$fh>) {
        return 0 + $1 if /^VmHWM:\s+(\d+)\s+kB/;
    }
    return 0;
}

sub context_switches {
    my %r = (voluntary => 0, nonvoluntary => 0);
    return \%r unless -r '/proc/self/status';
    open my $fh, '<', '/proc/self/status' or return \%r;
    while (<$fh>) {
        $r{voluntary} = 0 + $1 if /^voluntary_ctxt_switches:\s+(\d+)/;
        $r{nonvoluntary} = 0 + $1 if /^nonvoluntary_ctxt_switches:\s+(\d+)/;
    }
    return \%r;
}

sub write_json ($path, $data) {
    if ($path =~ m{^(.+)/[^/]+$}) {
        make_path($1) unless -d $1;
    }
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} JSON::PP->new->canonical(1)->pretty(1)->encode($data);
    close $fh;
}

sub write_html ($path, $results, $summary) {
    if ($path =~ m{^(.+)/[^/]+$}) {
        make_path($1) unless -d $1;
    }
    open my $fh, '>', $path or die "write $path: $!";

    my @system_names = sort { lc($a) cmp lc($b) }
        do { my %seen; grep { !$seen{$_}++ } map { $_->{system} // '' } @$results };
    my @client_counts = sort { $a <=> $b }
        do { my %seen; grep { !$seen{$_}++ } map { $_->{clients} // 0 } @$results };

    print {$fh} <<'HTML';
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>High-level stream competitor comparison</title>
<style>
:root{color-scheme:light dark}body{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:2rem;line-height:1.4;max-width:1800px}h1,h2{line-height:1.2}.note{background:color-mix(in srgb,Canvas 94%,#0969da 6%);border:1px solid color-mix(in srgb,CanvasText 20%,transparent);border-radius:8px;padding:1rem;margin:1rem 0}.toolbar{display:flex;gap:.8rem;align-items:end;flex-wrap:wrap;margin:1rem 0;padding:.8rem;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);border-radius:8px}.toolbar label{display:flex;flex-direction:column;gap:.25rem;font-size:.9rem}.toolbar input,.toolbar select,.toolbar button{font:inherit;padding:.4rem .55rem;border:1px solid color-mix(in srgb,CanvasText 30%,transparent);border-radius:6px;background:Canvas;color:CanvasText}.toolbar button{cursor:pointer}.status{margin-left:auto;font-size:.9rem;opacity:.8}.table-wrap{overflow:auto;margin:1rem 0 2rem}table{border-collapse:collapse;width:100%;min-width:1000px}th,td{border:1px solid color-mix(in srgb,CanvasText 20%,transparent);padding:.4rem .55rem;text-align:right;white-space:nowrap}th:first-child,td:first-child{text-align:left}th{background:color-mix(in srgb,Canvas 90%,CanvasText 10%);cursor:pointer;user-select:none;position:sticky;top:0;z-index:1}th:hover{background:color-mix(in srgb,Canvas 82%,#0969da 18%)}th::after{content:" \21C5";font-size:.75em;opacity:.5}th.sort-asc::after{content:" \25B2";opacity:1}th.sort-desc::after{content:" \25BC";opacity:1}tbody tr:nth-child(even){background:color-mix(in srgb,Canvas 96%,CanvasText 4%)}tbody tr:hover{background:color-mix(in srgb,Canvas 88%,#0969da 12%)}code{background:color-mix(in srgb,Canvas 90%,CanvasText 10%);padding:.1rem .25rem;border-radius:4px}.small{font-size:.9rem;opacity:.8}.hidden{display:none!important}
</style>
<script>
(function(){
  'use strict';
  function text(el){ return String(el && (el.textContent || el.innerText) || '').trim(); }
  function normalize(raw){
    raw = String(raw == null ? '' : raw).trim();
    if (raw === '') return {type:'text', value:''};
    var low = raw.toLowerCase();
    if (low === 'yes' || low === 'true' || low === 'ok') return {type:'number', value:1};
    if (low === 'no' || low === 'false' || low === 'fail') return {type:'number', value:0};
    var numeric = raw.replace(/,/g,'');
    if (numeric !== '' && !isNaN(Number(numeric))) return {type:'number', value:Number(numeric)};
    return {type:'text', value:low};
  }
  function sortTable(th){
    var table = th.closest ? th.closest('table') : null;
    if (!table) { var n=th; while(n && n.tagName !== 'TABLE') n=n.parentNode; table=n; }
    if (!table || !table.tBodies.length) return;
    var headers = Array.prototype.slice.call(th.parentNode.cells);
    var col = headers.indexOf(th);
    var same = table.getAttribute('data-sort-col') === String(col);
    var dir = same && table.getAttribute('data-sort-dir') === 'desc' ? 'asc' : 'desc';
    table.setAttribute('data-sort-col', String(col));
    table.setAttribute('data-sort-dir', dir);
    headers.forEach(function(h){ h.classList.remove('sort-asc','sort-desc'); });
    th.classList.add(dir === 'desc' ? 'sort-desc' : 'sort-asc');
    var rows = Array.prototype.slice.call(table.tBodies[0].rows);
    rows.sort(function(a,b){
      var av = normalize(a.cells[col] && (a.cells[col].getAttribute('data-sort') || text(a.cells[col])));
      var bv = normalize(b.cells[col] && (b.cells[col].getAttribute('data-sort') || text(b.cells[col])));
      var cmp = (av.type === 'number' && bv.type === 'number') ? av.value - bv.value : String(av.value).localeCompare(String(bv.value));
      return dir === 'desc' ? -cmp : cmp;
    });
    rows.forEach(function(r){ table.tBodies[0].appendChild(r); });
  }
  function applyFilters(){
    var q = document.getElementById('row-filter').value.toLowerCase().trim();
    var system = document.getElementById('system-filter').value;
    var clients = document.getElementById('clients-filter').value;
    var tables = document.querySelectorAll('table[data-filterable="1"]');
    var shown = 0, total = 0;
    Array.prototype.forEach.call(tables,function(table){
      Array.prototype.forEach.call(table.tBodies[0].rows,function(row){
        total++;
        var match = (!q || text(row).toLowerCase().indexOf(q) !== -1)
          && (!system || row.getAttribute('data-system') === system)
          && (!clients || row.getAttribute('data-clients') === clients);
        row.classList.toggle('hidden', !match);
        if (match) shown++;
      });
    });
    document.getElementById('filter-status').textContent = shown + ' of ' + total + ' rows visible';
  }
  function resetFilters(){
    document.getElementById('row-filter').value='';
    document.getElementById('system-filter').value='';
    document.getElementById('clients-filter').value='';
    applyFilters();
  }
  window.addEventListener('DOMContentLoaded',function(){
    Array.prototype.forEach.call(document.querySelectorAll('table.sortable th'),function(th){
      th.tabIndex = 0;
      th.title = 'Sort by ' + text(th);
      th.addEventListener('click',function(){ sortTable(th); });
      th.addEventListener('keydown',function(ev){ if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); sortTable(th); } });
    });
    ['row-filter','system-filter','clients-filter'].forEach(function(id){
      document.getElementById(id).addEventListener(id === 'row-filter' ? 'input' : 'change', applyFilters);
    });
    document.getElementById('reset-filters').addEventListener('click', resetFilters);
    applyFilters();
  });
})();
</script></head><body>
<h1>High-level stream competitor comparison</h1>
<p class="small">Offline report. Workload parameters and the full fairness contract are recorded in the companion JSON file. Click any column heading to sort. Use the controls below to filter both the summary and raw-repeat tables.</p>
<div class="note"><strong>Fairness contract:</strong> all TCP connections are established before timing; every server uses its normal high-level buffered Stream abstraction; warmup finishes before counters and timing reset; every client has at most one request outstanding; the server loop stops only after clients receive all replies; teardown occurs after timing; raw and delimiter-framed workloads are ranked separately.</div>
<div class="toolbar">
<label>Search rows<input id="row-filter" type="search" placeholder="system, backend, value..."></label>
<label>System<select id="system-filter"><option value="">All systems</option>
HTML
    for my $name (@system_names) {
        printf {$fh} '<option value="%s">%s</option>\n', html_escape($name), html_escape($name);
    }
    print {$fh} <<'HTML';
</select></label>
<label>Clients<select id="clients-filter"><option value="">All client counts</option>
HTML
    for my $count (@client_counts) {
        printf {$fh} '<option value="%d">%d</option>\n', $count, $count;
    }
    print {$fh} <<'HTML';
</select></label>
<button id="reset-filters" type="button">Reset</button><span id="filter-status" class="status"></span>
</div>
<h2>Median throughput ranking</h2><div class="table-wrap"><table class="sortable" data-filterable="1"><thead><tr><th>System</th><th>Backend</th><th>Workload</th><th>Bytes</th><th>Clients</th><th>Rank</th><th>Repeats</th><th>median msg/s</th><th>mean msg/s</th><th>p50 us</th><th>p95 us</th><th>p99 us</th><th>CPU us/msg</th><th>CPU %</th><th>RSS KiB</th><th>iterations</th><th>read cb/msg</th></tr></thead><tbody>
HTML
    for my $r (@$summary) {
        my $system = $r->{system} // '';
        my $clients = $r->{clients} // 0;
        printf {$fh} '<tr data-system="%s" data-clients="%d">', html_escape($system), $clients;
        print {$fh} join('',
            html_td($system), html_td($r->{backend} // ''),
            html_td($r->{workload}), html_td($r->{payload_bytes}),
            html_td($clients), html_td($r->{throughput_rank}),
            html_td($r->{repeats}),
            html_td(sprintf('%.2f', $r->{median_messages_per_second})),
            html_td(sprintf('%.2f', $r->{mean_messages_per_second})),
            html_td(sprintf('%.0f', $r->{median_lat_p50_us} // 0)),
            html_td(sprintf('%.0f', $r->{median_lat_p95_us} // 0)),
            html_td(sprintf('%.0f', $r->{median_lat_p99_us} // 0)),
            html_td(sprintf('%.3f', $r->{median_server_cpu_us_per_message})),
            html_td(sprintf('%.2f', $r->{median_server_cpu_percent})),
            html_td(sprintf('%.0f', $r->{median_max_rss_kb})),
            html_td(defined $r->{median_reactor_iterations} ? sprintf('%.0f', $r->{median_reactor_iterations}) : 'n/a'),
            html_td(sprintf('%.4f', $r->{median_read_callbacks_per_message})),
        );
        print {$fh} "</tr>\n";
    }
    print {$fh} <<'HTML';
</tbody></table></div>
<h2>Measured repeats</h2><div class="table-wrap"><table class="sortable" data-filterable="1"><thead><tr><th>System</th><th>Workload</th><th>Bytes</th><th>Clients</th><th>Repeat</th><th>Order</th><th>OK</th><th>msg/s</th><th>elapsed s</th><th>CPU us/msg</th><th>CPU %</th><th>p50 us</th><th>p95 us</th><th>p99 us</th><th>RSS KiB</th><th>iterations</th><th>read cb</th><th>messages read</th><th>queued bytes</th><th>backend</th></tr></thead><tbody>
HTML
    for my $r (@$results) {
        my $system = $r->{system} // '';
        my $clients = $r->{clients} // 0;
        printf {$fh} '<tr data-system="%s" data-clients="%d">', html_escape($system), $clients;
        print {$fh} join('',
            html_td($system), html_td($r->{workload}),
            html_td($r->{payload_bytes}), html_td($clients),
            html_td($r->{repeat}),
            html_td(defined $r->{execution_order_position} ? ($r->{execution_order_position} . '/' . ($r->{execution_order_width} // '')) : ''),
            html_td($r->{ok} ? 'yes' : 'no'),
            html_td(defined $r->{messages_per_second} ? sprintf('%.2f', $r->{messages_per_second}) : ''),
            html_td(sprintf('%.6f', $r->{elapsed_seconds} // 0)),
            html_td(defined $r->{server_cpu_us_per_message} ? sprintf('%.3f', $r->{server_cpu_us_per_message}) : ''),
            html_td(defined $r->{server_cpu_percent} ? sprintf('%.2f', $r->{server_cpu_percent}) : ''),
            html_td($r->{lat_p50_us} // ''), html_td($r->{lat_p95_us} // ''), html_td($r->{lat_p99_us} // ''),
            html_td($r->{max_rss_kb} // ''),
            html_td(defined $r->{reactor_iterations} ? $r->{reactor_iterations} : 'n/a'),
            html_td($r->{read_callbacks} // ''),
            html_td($r->{messages_read} // ''),
            html_td($r->{bytes_queued} // ''),
            html_td($r->{backend_runtime} // $r->{backend} // ''),
        );
        print {$fh} "</tr>\n";
    }
    print {$fh} "</tbody></table></div></body></html>\n";
    close $fh;
}

sub html_escape ($value) {
    $value = '' unless defined $value;
    $value = "$value";
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/\"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

sub html_td ($value) {
    return '<td>' . html_escape($value) . '</td>';
}
