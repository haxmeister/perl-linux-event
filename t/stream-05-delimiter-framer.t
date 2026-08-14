use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Delimiter;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my @messages;

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    framer => Linux::Event::Stream::Framer::Delimiter->new(
        delimiter => '<END>',
    ),
    on_message => sub ($s, $message) {
        push @messages, $message;
        $loop->stop if @messages == 2;
    },
);

syswrite($b, 'hello<EN');
$loop->run_once(0);
is_deeply(\@messages, [], 'delimiter split across reads is retained');

syswrite($b, 'D>world<END>tail');
$loop->run;
is_deeply(\@messages, ['hello', 'world'], 'multiple frames are emitted and delimiter stripped');

ok($stream->send('reply'), 'send uses outbound framing');
my $wire = '';
is(sysread($b, $wire, 1024), 10, 'peer receives framed payload');
is($wire, 'reply<END>', 'delimiter framer appends delimiter on send');

$stream->close;
done_testing;
