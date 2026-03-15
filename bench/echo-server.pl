use v5.36;
use strict;
use warnings;

use IO::Socket::INET;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);
use Linux::Event::Loop;
use IO::Handle ();

STDOUT->autoflush(1);
STDERR->autoflush(1);

my %opt = (
    model              => 'proactor',
    backend            => undef,
    host               => '127.0.0.1',
    port               => 8082,
    accept_concurrency => 64,
    recv_len           => 4096,
    report_interval    => 1,
);

GetOptions(
    'model=s'              => \$opt{model},
    'backend=s'            => \$opt{backend},
    'host=s'               => \$opt{host},
    'port=i'               => \$opt{port},
    'accept-concurrency=i' => \$opt{accept_concurrency},
    'recv-len=i'           => \$opt{recv_len},
    'report-interval=i'    => \$opt{report_interval},
) or die _usage();

die _usage() unless $opt{model} eq 'reactor' || $opt{model} eq 'proactor';
$opt{backend} //= ($opt{model} eq 'reactor' ? 'epoll' : 'uring');

die "accept-concurrency must be >= 1\n" if $opt{accept_concurrency} < 1;
die "recv-len must be >= 1\n"           if $opt{recv_len} < 1;
die "report-interval must be >= 1\n"    if $opt{report_interval} < 1;

my %loop_arg = (
    model   => $opt{model},
    backend => $opt{backend},
);

$loop_arg{queue_size} = 1024 if $opt{model} eq 'proactor';

my $loop = Linux::Event::Loop->new(%loop_arg);

my $listen = IO::Socket::INET->new(
    LocalAddr => $opt{host},
    LocalPort => $opt{port},
    Proto     => 'tcp',
    Listen    => 1024,
    ReuseAddr => 1,
) or die "listen socket failed: $!";

_set_nonblocking($listen);

my %stats = (
    start_time   => time,
    last_time    => time,
    accepts      => 0,
    reads        => 0,
    writes       => 0,
    bytes_in     => 0,
    bytes_out    => 0,
    active_conns => 0,
);

print "echo-server model=$opt{model} backend=$opt{backend} listening on $opt{host}:$opt{port}\n";
print "accept_concurrency=$opt{accept_concurrency} recv_len=$opt{recv_len} report_interval=$opt{report_interval}s\n";

_start_report_timer(\%stats, $opt{report_interval});

if ($opt{model} eq 'proactor') {
    for (1 .. $opt{accept_concurrency}) {
        _post_proactor_accept($loop, $listen, \%opt, \%stats);
    }
}
else {
    _start_reactor_acceptor($loop, $listen, \%opt, \%stats);
}

$loop->run;

sub _post_proactor_accept ($loop, $listen, $opt, $stats) {
    $loop->accept(
        fh => $listen,
        on_complete => sub ($op, $res, $ctx) {
            _post_proactor_accept($loop, $listen, $opt, $stats);

            if ($op->is_cancelled) {
                _log("accept cancelled");
                return;
            }

            if ($op->failed) {
                _log("accept failed: " . _op_error_string($op));
                return;
            }

            my $fh = $res->{fh};
            if (!$fh) {
                _log("accept completed without fh");
                return;
            }

            $stats->{accepts}++;
            $stats->{active_conns}++;

            my $conn = {
                loop   => $loop,
                fh     => $fh,
                opt    => $opt,
                stats  => $stats,
                closed => 0,
            };

            _post_proactor_recv($conn);
        },
    );

    return;
}
sub _post_proactor_recv ($conn) {
    return if $conn->{closed};

    $conn->{loop}->recv(
        fh  => $conn->{fh},
        len => $conn->{opt}{recv_len},
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};

            if ($op->is_cancelled) {
                _log("recv cancelled");
                return;
            }

            if ($op->failed) {
                _log("recv failed: " . _op_error_string($op));
                _close_proactor_conn($conn);
                return;
            }

            my $bytes = $res->{bytes};
            my $data  = $res->{data};
            my $eof   = $res->{eof};

            if ($bytes > 0) {
                $conn->{stats}{reads}++;
                $conn->{stats}{bytes_in} += $bytes;
                _post_proactor_send($conn, $data);
                return;
            }

            if ($eof) {
                _log("recv eof");
                _close_proactor_conn($conn);
                return;
            }

            _log("recv completed with no bytes and no eof");
            _post_proactor_recv($conn);
        },
    );

    return;
}

sub _post_proactor_send ($conn, $data) {
    return if $conn->{closed};

    $conn->{loop}->send(
        fh  => $conn->{fh},
        buf => $data,
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};

            if ($op->is_cancelled) {
                _log("send cancelled");
                return;
            }

            if ($op->failed) {
                _log("send failed: " . _op_error_string($op));
                _close_proactor_conn($conn);
                return;
            }

            my $bytes = $res->{bytes};

            if (!defined $bytes) {
                _log("send completed with undef bytes");
                _close_proactor_conn($conn);
                return;
            }

            $conn->{stats}{writes}++;
            $conn->{stats}{bytes_out} += $bytes;

            if ($bytes < length($data)) {
                my $rest = substr($data, $bytes);
                _log("short send: wrote=$bytes expected=" . length($data));
                _post_proactor_send($conn, $rest);
                return;
            }

            _post_proactor_recv($conn);
        },
    );

    return;
}

sub _close_proactor_conn ($conn) {
    return if $conn->{closed};
    $conn->{closed} = 1;
    $conn->{stats}{active_conns}-- if $conn->{stats}{active_conns} > 0;
    close delete $conn->{fh} if $conn->{fh};
    return;
}

sub _start_reactor_acceptor ($loop, $listen, $opt, $stats) {
    $loop->watch(
        $listen,
        edge_triggered => 1,
        read => sub ($loop, $fh, $watcher) {
            while (1) {
                my $client = $fh->accept;
                if (!$client) {
                    last if $!{EAGAIN} || $!{EWOULDBLOCK};
                    die "accept failed: $!";
                }

                _set_nonblocking($client);

                $stats->{accepts}++;
                $stats->{active_conns}++;

                _start_reactor_conn($loop, $client, $opt, $stats);
            }
        },
    );

    return;
}

sub _start_reactor_conn ($loop, $fh, $opt, $stats) {
    my $conn = {
        loop     => $loop,
        fh       => $fh,
        opt      => $opt,
        stats    => $stats,
        outbuf   => '',
        closed   => 0,
        watcher  => undef,
    };

    my $watcher;
    $watcher = $loop->watch(
        $fh,
        edge_triggered => 1,

        read => sub ($loop, $fh, $watcher) {
            return if $conn->{closed};

            while (1) {
                my $n = sysread($fh, my $chunk, $opt->{recv_len});

                if (!defined $n) {
                    last if $!{EAGAIN} || $!{EWOULDBLOCK};
                    _close_reactor_conn($conn);
                    return;
                }

                if ($n == 0) {
                    _close_reactor_conn($conn);
                    return;
                }

                $stats->{reads}++;
                $stats->{bytes_in} += $n;
                $conn->{outbuf} .= $chunk;
            }

            if (length $conn->{outbuf}) {
                $watcher->enable_write;
            }
        },

        write => sub ($loop, $fh, $watcher) {
            return if $conn->{closed};

            while (length $conn->{outbuf}) {
                my $n = syswrite($fh, $conn->{outbuf});

                if (!defined $n) {
                    last if $!{EAGAIN} || $!{EWOULDBLOCK};
                    _close_reactor_conn($conn);
                    return;
                }

                substr($conn->{outbuf}, 0, $n, '');
                $stats->{writes}++;
                $stats->{bytes_out} += $n;
            }

            if (!length $conn->{outbuf}) {
                $watcher->disable_write;
            }
        },
    );

    $watcher->disable_write;
    $conn->{watcher} = $watcher;

    return;
}

sub _close_reactor_conn ($conn) {
    return if $conn->{closed};
    $conn->{closed} = 1;
    $conn->{stats}{active_conns}-- if $conn->{stats}{active_conns} > 0;
    $conn->{watcher}->cancel if $conn->{watcher};
    close delete $conn->{fh} if $conn->{fh};
    return;
}

sub _set_nonblocking ($fh) {
    my $flags = fcntl($fh, F_GETFL, 0);
    die "fcntl(F_GETFL) failed: $!" if !defined $flags;

    my $ok = fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
    die "fcntl(F_SETFL) failed: $!" if !$ok;

    return;
}

sub _start_report_timer ($stats, $interval) {
    $SIG{ALRM} = sub {
        my $now = time;
        my $uptime = $now - $stats->{start_time};
        $uptime = 1 if $uptime <= 0;

        printf(
            "uptime=%ds active=%d accepts=%d reads=%d writes=%d bytes_in=%d bytes_out=%d read_ops/sec=%.1f write_ops/sec=%.1f MiB_in/sec=%.2f MiB_out/sec=%.2f\n",
            int($uptime),
            $stats->{active_conns},
            $stats->{accepts},
            $stats->{reads},
            $stats->{writes},
            $stats->{bytes_in},
            $stats->{bytes_out},
            $stats->{reads}  / $uptime,
            $stats->{writes} / $uptime,
            ($stats->{bytes_in}  / $uptime) / (1024 * 1024),
            ($stats->{bytes_out} / $uptime) / (1024 * 1024),
        );

        alarm($interval);
    };

    alarm($interval);
    return;
}
sub _log ($msg) {
    my $ts = scalar localtime;
    print STDERR "[$ts] $msg\n";
    return;
}

sub _op_error_string ($op) {
    return 'unknown failure' if !$op;

    my $err = eval { $op->error };
    return 'operation failed' if !$err;

    if (ref $err eq 'HASH') {
        my @parts;
        push @parts, "code=$err->{code}"       if exists $err->{code};
        push @parts, "errno=$err->{errno}"     if exists $err->{errno};
        push @parts, "name=$err->{name}"       if exists $err->{name};
        push @parts, "message=$err->{message}" if exists $err->{message};
        push @parts, "syscall=$err->{syscall}" if exists $err->{syscall};
        return join(' ', @parts) if @parts;
    }

    for my $meth (qw(code errno name message syscall as_string to_string)) {
        next if !eval { $err->can($meth) };
        my $v = eval { $err->$meth() };
        return $v if defined($v) && length($v);
    }

    return "$err";
}
sub _usage {
    return <<"USAGE";
usage: $0 [options]

  --model reactor|proactor      default: proactor
  --backend NAME                default: epoll for reactor, uring for proactor
  --host HOST                   default: 127.0.0.1
  --port PORT                   default: 8082
  --accept-concurrency N        default: 64
  --recv-len BYTES              default: 4096
  --report-interval SECONDS     default: 1

examples:

  perl -Ilib $0 --model proactor --backend uring --port 8082
  perl -Ilib $0 --model reactor  --backend epoll --port 8083

notes:

  - reactor mode uses nonblocking sysread/syswrite with readiness watchers
  - proactor mode uses accept/recv/send operations
  - the periodic report is intentionally minimal to reduce benchmark distortion
USAGE
}
