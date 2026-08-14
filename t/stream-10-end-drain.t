use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_SNDBUF);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
setsockopt($a, SOL_SOCKET, SO_SNDBUF, pack('i', 4096)) or die "setsockopt SO_SNDBUF: $!";

my $loop = Linux::Event::XSLoop->new;
my $payload = 'q' x (1024 * 1024);
my $received = 0;
my $closed = 0;

my ($writer, $reader);
$reader = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $b,
    on_data => sub ($s, $bytes) {
        $received += length($bytes);
    },
    on_eof => sub ($s) {
        is($received, length($payload), 'reader sees all bytes before EOF');
        $s->end;
    },
    on_close => sub ($s) {
        $closed++;
        $loop->stop if $closed == 2;
    },
);

$writer = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    high_watermark => 4096,
    low_watermark  => 1024,
    on_eof => sub ($s) {
        # Peer has now ended too. Because our writable side was already ended,
        # the Stream can finish the full-duplex lifetime.
    },
    on_close => sub ($s) {
        $closed++;
        $loop->stop if $closed == 2;
    },
);

ok(!$writer->write($payload), 'payload is queued and backpressured');
$writer->end;
$loop->run;

is($received, length($payload), 'end drains queued output rather than dropping it');
is($closed, 2, 'both streams close after both half-closes complete');
ok($writer->is_closed, 'writer closed');
ok($reader->is_closed, 'reader closed');

done_testing;
