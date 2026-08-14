use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Delimiter;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $error;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    framer => Linux::Event::Stream::Framer::Delimiter->new(
        delimiter => '<E>',
        max_frame => 4,
    ),
    on_message => sub { fail('oversized frame must not emit') },
    on_error => sub ($s, $err) { $error = $err },
    on_close => sub ($s) { $loop->stop },
);

syswrite($b, '12345<E>');
$loop->run;
isa_ok($error, 'Linux::Event::Stream::Error');
is($error->type, 'framing', 'native delimiter limit reports framing error');
like($error->message, qr/max_frame=4/, 'native error preserves max_frame context');
ok($stream->is_closed, 'framing error closes Stream');
close $b;
done_testing;
