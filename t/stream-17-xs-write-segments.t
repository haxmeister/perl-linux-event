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
my $first = 'A' x (1024 * 1024);
my $second = 'B' x (64 * 1024);
my $third = 'C' x (64 * 1024);
my $expected = $first . $second . $third;
my $received = '';

my $reader = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $b,
    on_data => sub ($s, $bytes) {
        $received .= $bytes;
        $loop->stop if length($received) == length($expected);
    },
);

my $writer = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    high_watermark => 4096,
    low_watermark  => 1024,
);

ok(!$writer->write($first), 'first large write establishes queued output');
$writer->write($second);
$writer->write($third);

# Queued writes have value semantics: later mutation of caller scalars must not
# change bytes already accepted by Stream.
$second =~ tr/B/X/;
$third  =~ tr/C/Y/;

$loop->run;
is($received, $expected, 'segmented native queue preserves ordering and values');

my $stats = $writer->{xs_state}->stats;
ok($stats->{queued_segments} >= 3, 'multiple native segments were queued');
ok($stats->{writev_calls} >= 1, 'segmented queue drained with writev');
is($stats->{pending_bytes}, 0, 'all native segments were consumed');

$writer->close;
$reader->close;
done_testing;
