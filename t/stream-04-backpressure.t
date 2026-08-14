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
my $payload = 'x' x (2 * 1024 * 1024);
my $received = 0;
my $drain_calls = 0;

my $reader = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $b,
    read_size => 65_536,
    on_data => sub ($s, $bytes) {
        $received += length($bytes);
        $loop->stop if $received == length($payload) && $drain_calls;
    },
);

my $writer = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    high_watermark => 4096,
    low_watermark  => 1024,
    on_drain => sub ($s) {
        $drain_calls++;
        $loop->stop if $received == length($payload);
    },
);

ok(!$writer->write($payload), 'large write crosses high watermark');
ok($writer->is_write_blocked, 'blocked state is visible');
ok($writer->pending_bytes > 4096, 'bytes are queued in user space');

$loop->run;

is($received, length($payload), 'all queued bytes are delivered');
is($drain_calls, 1, 'on_drain fires exactly once for blocked transition');
ok(!$writer->is_write_blocked, 'blocked state clears below low watermark');
is($writer->pending_bytes, 0, 'write queue is empty');

$writer->close;
$reader->close;
done_testing;
