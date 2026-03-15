use v5.36;
use strict;
use warnings;

use IO::Socket::INET;
use Getopt::Long qw(GetOptions);
use Linux::Event::Loop;

my %opt = (
    host               => '127.0.0.1',
    port               => 8081,
    accept_concurrency => 32,
    recv_len           => 4096,
    debug              => 1,
);

GetOptions(
    'host=s'               => \$opt{host},
    'port=i'               => \$opt{port},
    'accept-concurrency=i' => \$opt{accept_concurrency},
    'recv-len=i'           => \$opt{recv_len},
    'debug!'               => \$opt{debug},
) or die _usage();

die _usage() if !$opt{port};
die "accept-concurrency must be >= 1\n" if $opt{accept_concurrency} < 1;
die "recv-len must be >= 1\n"           if $opt{recv_len} < 1;

my $loop = Linux::Event::Loop->new(
    model   => 'proactor',
    backend => 'uring',
);

my $listen = IO::Socket::INET->new(
    LocalAddr => $opt{host},
    LocalPort => $opt{port},
    Proto     => 'tcp',
    Listen    => 1024,
    ReuseAddr => 1,
) or die "listen socket failed: $!";

_log(\%opt, "proactor echo server listening on $opt{host}:$opt{port}");
_log(\%opt, "accept concurrency = $opt{accept_concurrency}, recv len = $opt{recv_len}");

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

            my $fh   = $res->{fh};
            my $peer = eval { $fh->peerhost . ':' . $fh->peerport } // 'unknown';

            my $conn = {
                loop   => $loop,
                opt    => $opt,
                fh     => $fh,
                peer   => $peer,
                closed => 0,
            };

            _clog($conn, "accepted");
            _post_recv($conn);
        },
    );

    return;
}

sub _post_recv ($conn) {
    return if $conn->{closed};
    _clog($conn, "arming recv len=$conn->{opt}{recv_len}");
    $conn->{loop}->recv(
        fh  => $conn->{fh},
        len => $conn->{opt}{recv_len},
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};
            return if $op->is_cancelled;

            if ($op->failed) {
                _clog($conn, "recv failed: " . $op->error->message);
                _close_conn($conn);
                return;
            }

            my $bytes = $res->{bytes};
            my $data  = $res->{data};
            my $eof   = $res->{eof};

            _clog($conn, "recv bytes=$bytes eof=$eof");

            if ($bytes > 0) {
                _post_send($conn, $data);
                return;
            }

            if ($eof) {
                _clog($conn, "peer closed");
                _close_conn($conn);
                return;
            }

            _post_recv($conn);
        },
    );

    return;
}

sub _post_send ($conn, $data) {
    return if $conn->{closed};
    _clog($conn, "arming send len=" . length($data));
    $conn->{loop}->send(
        fh  => $conn->{fh},
        buf => $data,
        on_complete => sub ($op, $res, $ctx) {
            return if $conn->{closed};
            return if $op->is_cancelled;

            if ($op->failed) {
                _clog($conn, "send failed: " . $op->error->message);
                _close_conn($conn);
                return;
            }

            my $bytes = $res->{bytes};
            _clog($conn, "send bytes=$bytes");

            if ($bytes < length($data)) {
                my $rest = substr($data, $bytes);
                _post_send($conn, $rest);
                return;
            }

            _post_recv($conn);
        },
    );

    return;
}

sub _close_conn ($conn) {
    return if $conn->{closed};
    $conn->{closed} = 1;

    _clog($conn, "closing");

    if (my $fh = delete $conn->{fh}) {
        close $fh;
    }

    return;
}

sub _log ($opt, $msg) {
    return unless $opt->{debug};
    warn "$msg\n";
    return;
}

sub _clog ($conn, $msg) {
    return unless $conn->{opt}{debug};
    warn "[$conn->{peer}] $msg\n";
    return;
}

sub _usage {
    return <<"USAGE";
usage: $0 [options]

  --host HOST                default: 127.0.0.1
  --port PORT                default: 8081
  --accept-concurrency N     default: 32
  --recv-len BYTES           default: 4096
  --debug / --no-debug       default: debug enabled

example:

  perl $0 --port 8081

test:

  printf 'hello echo\n' | nc -N 127.0.0.1 8081

USAGE
}
