use v5.36;
use strict;
use warnings;

use IO::Socket::INET;
use Socket qw(AF_INET SOCK_STREAM inet_aton pack_sockaddr_in);
use Getopt::Long qw(GetOptions);
use Linux::Event::Loop;

my %opt = (
    listen_host        => '127.0.0.1',
    listen_port        => 8080,
    upstream_host      => '127.0.0.1',
    upstream_port      => 9000,
    accept_concurrency => 32,
    splice_len         => 65536,
    debug              => 1,
);

GetOptions(
    'listen-host=s'        => \$opt{listen_host},
    'listen-port=i'        => \$opt{listen_port},
    'upstream-host=s'      => \$opt{upstream_host},
    'upstream-port=i'      => \$opt{upstream_port},
    'accept-concurrency=i' => \$opt{accept_concurrency},
    'splice-len=i'         => \$opt{splice_len},
    'debug!'               => \$opt{debug},
) or die _usage();

die _usage() if !$opt{listen_port} || !$opt{upstream_port};
die "accept-concurrency must be >= 1\n" if $opt{accept_concurrency} < 1;
die "splice-len must be >= 1\n"         if $opt{splice_len} < 1;

my $loop = Linux::Event::Loop->new(
    model   => 'proactor',
    backend => 'uring',
);

my $listen = IO::Socket::INET->new(
    LocalAddr => $opt{listen_host},
    LocalPort => $opt{listen_port},
    Proto     => 'tcp',
    Listen    => 1024,
    ReuseAddr => 1,
) or die "listen socket failed: $!";

my $listen_desc = $listen->sockhost . ':' . $listen->sockport;
_log(\%opt, "splice proxy listening on $listen_desc");
_log(\%opt, "upstream target is $opt{upstream_host}:$opt{upstream_port}");
_log(\%opt, "accept concurrency = $opt{accept_concurrency}, splice len = $opt{splice_len}");

for (1 .. $opt{accept_concurrency}) {
    _post_accept($loop, $listen, \%opt);
}

$loop->run;

sub _post_accept ($loop, $listen, $opt) {
    $loop->accept(
        fh => $listen,
        on_complete => sub ($op, $res, $ctx) {
            _post_accept($loop, $listen, $opt);

            return if $op->is_cancelled;

            if ($op->failed) {
                _log($opt, "accept failed: " . $op->error->message);
                return;
            }

            my $client = $res->{fh};
            my $peer   = eval { _sockdesc($client) } // 'unknown';
            _log($opt, "accepted client $peer");

            _start_proxy_connection($loop, $client, $opt);
        },
    );

    return;
}

sub _start_proxy_connection ($loop, $client, $opt) {
    my $upstream_ip = inet_aton($opt->{upstream_host});
    if (!$upstream_ip) {
        _log($opt, "failed to resolve upstream host $opt->{upstream_host}");
        close $client;
        return;
    }

    socket(my $upstream, AF_INET, SOCK_STREAM, 0)
        or do {
            _log($opt, "upstream socket() failed: $!");
            close $client;
            return;
        };

    my $addr = pack_sockaddr_in($opt->{upstream_port}, $upstream_ip);

    my $conn = {
        loop        => $loop,
        opt         => $opt,
        id          => _next_conn_id(),
        client      => $client,
        upstream    => $upstream,
        closed      => 0,
        splice_len  => $opt->{splice_len},
        dir_done    => {
            c2u => 0,
            u2c => 0,
        },
    };

    pipe(my $c2u_r, my $c2u_w) or do {
        _log($opt, "pipe(c2u) failed: $!");
        _close_conn($conn);
        return;
    };

    pipe(my $u2c_r, my $u2c_w) or do {
        _log($opt, "pipe(u2c) failed: $!");
        _close_conn($conn);
        return;
    };

    $conn->{c2u_r} = $c2u_r;
    $conn->{c2u_w} = $c2u_w;
    $conn->{u2c_r} = $u2c_r;
    $conn->{u2c_w} = $u2c_w;

    _clog($conn, "connecting upstream to $opt->{upstream_host}:$opt->{upstream_port}");

    $loop->connect(
        fh   => $upstream,
        addr => $addr,
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};
            return if $op->is_cancelled;

            if ($op->failed) {
                _clog($conn, "connect failed: " . $op->error->message);
                _close_conn($conn);
                return;
            }

            _clog($conn, "upstream connected");

            _start_direction(
                $conn,
                name              => 'c2u',
                from_fh           => $conn->{client},
                pipe_r            => $conn->{c2u_r},
                pipe_w            => $conn->{c2u_w},
                to_fh             => $conn->{upstream},
                shutdown_target   => $conn->{upstream},
                shutdown_how      => 'write',
            );

            _start_direction(
                $conn,
                name              => 'u2c',
                from_fh           => $conn->{upstream},
                pipe_r            => $conn->{u2c_r},
                pipe_w            => $conn->{u2c_w},
                to_fh             => $conn->{client},
                shutdown_target   => $conn->{client},
                shutdown_how      => 'write',
            );
        },
    );

    return;
}

sub _start_direction ($conn, %arg) {
    return if $conn->{closed};

    _clog($conn, "starting direction $arg{name}");

    _pump_into_pipe(
        $conn,
        name            => $arg{name},
        from_fh         => $arg{from_fh},
        pipe_r          => $arg{pipe_r},
        pipe_w          => $arg{pipe_w},
        to_fh           => $arg{to_fh},
        shutdown_target => $arg{shutdown_target},
        shutdown_how    => $arg{shutdown_how},
    );

    return;
}

sub _pump_into_pipe ($conn, %arg) {
    return if $conn->{closed};
    return if $conn->{dir_done}{ $arg{name} };

    _clog($conn, "$arg{name}: splice socket -> pipe");

    $conn->{loop}->splice(
        in_fh  => $arg{from_fh},
        out_fh => $arg{pipe_w},
        len    => $conn->{splice_len},
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};
            return if $op->is_cancelled;

            if ($op->failed) {
                _fail_direction($conn, $arg{name}, "splice into pipe failed: " . $op->error->message);
                return;
            }

            my $bytes = $res->{bytes};
            _clog($conn, "$arg{name}: socket -> pipe moved $bytes bytes");

            if ($bytes == 0) {
                _clog($conn, "$arg{name}: got EOF");
                _finish_direction($conn, $arg{name}, $arg{shutdown_target}, $arg{shutdown_how});
                return;
            }

            _drain_pipe(
                $conn,
                remaining       => $bytes,
                name            => $arg{name},
                from_fh         => $arg{from_fh},
                pipe_r          => $arg{pipe_r},
                pipe_w          => $arg{pipe_w},
                to_fh           => $arg{to_fh},
                shutdown_target => $arg{shutdown_target},
                shutdown_how    => $arg{shutdown_how},
            );
        },
    );

    return;
}

sub _drain_pipe ($conn, %arg) {
    return if $conn->{closed};
    return if $conn->{dir_done}{ $arg{name} };

    _clog($conn, "$arg{name}: splice pipe -> socket remaining=$arg{remaining}");

    $conn->{loop}->splice(
        in_fh  => $arg{pipe_r},
        out_fh => $arg{to_fh},
        len    => $arg{remaining},
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};
            return if $op->is_cancelled;

            if ($op->failed) {
                _fail_direction($conn, $arg{name}, "splice out of pipe failed: " . $op->error->message);
                return;
            }

            my $bytes = $res->{bytes};
            _clog($conn, "$arg{name}: pipe -> socket moved $bytes bytes");

            if ($bytes == 0) {
                _clog($conn, "$arg{name}: pipe drain returned 0");
                _finish_direction($conn, $arg{name}, $arg{shutdown_target}, $arg{shutdown_how});
                return;
            }

            my $left = $arg{remaining} - $bytes;

            if ($left > 0) {
                _drain_pipe($conn, %arg, remaining => $left);
                return;
            }

            _pump_into_pipe(
                $conn,
                name            => $arg{name},
                from_fh         => $arg{from_fh},
                pipe_r          => $arg{pipe_r},
                pipe_w          => $arg{pipe_w},
                to_fh           => $arg{to_fh},
                shutdown_target => $arg{shutdown_target},
                shutdown_how    => $arg{shutdown_how},
            );
        },
    );

    return;
}

sub _finish_direction ($conn, $name, $shutdown_target, $shutdown_how) {
    return if $conn->{closed};
    return if $conn->{dir_done}{$name};

    $conn->{dir_done}{$name} = 1;
    _clog($conn, "finishing direction $name with shutdown($shutdown_how)");

    $conn->{loop}->shutdown(
        fh  => $shutdown_target,
        how => $shutdown_how,
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};
            _clog($conn, "shutdown for $name completed");
            _maybe_close_conn($conn);
        },
    );

    _maybe_close_conn($conn);
    return;
}

sub _fail_direction ($conn, $name, $message) {
    return if $conn->{closed};
    _clog($conn, "$name failed: $message");
    _close_conn($conn);
    return;
}

sub _maybe_close_conn ($conn) {
    return if $conn->{closed};

    if ($conn->{dir_done}{c2u} && $conn->{dir_done}{u2c}) {
        _clog($conn, "both directions done, closing connection");
        _close_conn($conn);
    }

    return;
}

sub _close_conn ($conn) {
    return if $conn->{closed};
    $conn->{closed} = 1;

    _clog($conn, "closing connection");

    for my $key (qw(
        c2u_r c2u_w
        u2c_r u2c_w
        client upstream
    )) {
        my $fh = delete $conn->{$key} or next;
        close $fh;
    }

    return;
}

sub _sockdesc ($fh) {
    my $peer = eval { $fh->peerhost . ':' . $fh->peerport };
    return $peer if defined $peer;

    my $sock = eval { $fh->sockhost . ':' . $fh->sockport };
    return $sock if defined $sock;

    return 'unknown';
}

{
    my $NEXT_ID = 1;
    sub _next_conn_id () { return $NEXT_ID++ }
}

sub _log ($opt, $msg) {
    return unless $opt->{debug};
    warn "$msg\n";
    return;
}

sub _clog ($conn, $msg) {
    return unless $conn->{opt}{debug};
    warn "[conn $conn->{id}] $msg\n";
    return;
}

sub _usage {
    return <<"USAGE";
usage: $0 [options]

  --listen-host HOST        default: 127.0.0.1
  --listen-port PORT        default: 8080
  --upstream-host HOST      default: 127.0.0.1
  --upstream-port PORT      default: 9000
  --accept-concurrency N    default: 32
  --splice-len BYTES        default: 65536
  --debug / --no-debug      default: debug enabled

example:

  perl $0 --listen-port 8080 --upstream-host 127.0.0.1 --upstream-port 9000

notes:

  - this is a compact demonstration of a splice-based TCP proxy
  - each relay direction uses socket -> pipe -> socket
  - ordinary accept() calls transparently benefit from internal multishot accept
USAGE
}
