use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_SNDBUF);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
setsockopt($a, SOL_SOCKET, SO_SNDBUF, pack('i', 4096))
    or die "setsockopt SO_SNDBUF: $!";

my $loop = Linux::Event::XSLoop->new;
my $payload = ('abcdefgh' x (256 * 1024)); # 2 MiB, deterministic byte pattern
my $received = '';
my $drains = 0;

my $reader = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $b,
    on_data => sub ($s, $bytes) {
        $received .= $bytes;
        $loop->stop if length($received) == length($payload) && $drains;
    },
);

my $writer = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    high_watermark => 4096,
    low_watermark  => 1024,
    on_drain => sub ($s) {
        $drains++;
        $loop->stop if length($received) == length($payload);
    },
);

is($writer->{write_backend}, 'xs', 'XS write backend is the default');
isa_ok($writer->{xs_state}, 'Linux::Event::Stream::XSState');
ok(!$writer->write($payload), 'large write enters native backpressure');
ok($writer->pending_bytes > 0, 'native queue reports pending bytes');
ok($writer->is_write_blocked, 'native blocked state is visible');

$loop->run;

is($received, $payload, 'native queued writer preserves exact byte content');
is($writer->pending_bytes, 0, 'native write queue drains completely');
ok(!$writer->is_write_blocked, 'blocked state clears after drain');
is($drains, 1, 'native backpressure interval emits one drain callback');

my $stats = $writer->{xs_state}->stats;
ok($stats->{write_submit_calls} >= 1, 'native write submission ran');
ok($stats->{write_calls} >= 1, 'native immediate write syscall ran');
ok($stats->{writev_calls} >= 1, 'native queued path used writev');
is($stats->{bytes_written}, length($payload), 'native write byte accounting is exact');
ok($stats->{queued_segments} >= 1, 'native queue stored at least one segment');
is($stats->{pending_bytes}, 0, 'native stats report empty queue');

$writer->close;
$reader->close;
done_testing;
