use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $got = '';

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    on_data => sub ($s, $bytes) {
        $got .= $bytes;
        $loop->stop if $got eq 'hello stream';
    },
);

is($stream->write(''), 1, 'empty write is successful');
is(syswrite($b, 'hello stream'), 12, 'peer wrote bytes');
$loop->run;

is($got, 'hello stream', 'on_data receives incoming bytes');
is($stream->pending_bytes, 0, 'nothing queued for output');
ok(!$stream->is_closed, 'stream remains open');

$stream->close;
ok($stream->is_closed, 'close is immediate');

done_testing;
