use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";

my $loop = Linux::Event::XSLoop->new;
my $got = '';

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    read_size => 4,
    on_data => sub ($s, $bytes) {
        $got .= $bytes;
        $loop->stop if length($got) >= 10;
    },
);

isa_ok($stream->{xs_state}, 'Linux::Event::Stream::XSState');
is($stream->{read_backend}, 'xs', 'XS read backend is the default');

is(syswrite($b, 'abcdefghij'), 10, 'peer wrote test bytes');
$loop->run;
is($got, 'abcdefghij', 'native read engine drains and delivers bytes');

my $stats = $stream->{xs_state}->stats;
ok($stats->{read_ready_calls} >= 1, 'native readiness handler ran');
ok($stats->{read_calls} >= 3, 'native engine performed multiple small read calls');
is($stats->{bytes_read}, 10, 'native byte count is exact');
ok($stats->{delivery_calls} >= 3, 'delivery callback follows successful reads');

$stream->close;
close $b;

done_testing;
