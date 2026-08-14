use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::U32BE;

my $framer = Linux::Event::Stream::Framer::U32BE->new;
is($framer->frame('hello'), "\x00\x00\x00\x05hello", 'U32BE outbound wire format');

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $got;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh => $a,
    read_size => 3,
    framer => $framer,
    on_message => sub ($s, $message) { $got = $message; $loop->stop },
);
is($stream->{framing_backend}, 'xs', 'U32BE selects native framing');
syswrite($b, "\x00\x00\x00\x07payload");
$loop->run;
is($got, 'payload', 'native U32BE decodes payload');
$stream->close;
close $b;

done_testing;
