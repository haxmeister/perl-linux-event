use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

{
    package T::BadFramer;
    use v5.36;
    sub new ($class) { bless {}, $class }
    sub next_frame ($self, $buffer) { die 'bad packet marker' }
}

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my ($error, $closed) = (undef, 0);

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    framer => T::BadFramer->new,
    on_message => sub ($s, $message) { fail('bad framer must not emit message') },
    on_error => sub ($s, $err) {
        $error = $err;
    },
    on_close => sub ($s) {
        $closed++;
        $loop->stop;
    },
);

syswrite($b, 'x');
$loop->run;

isa_ok($error, 'Linux::Event::Stream::Error');
is($error->type, 'framing', 'custom framer exception becomes framing error');
like($error->message, qr/bad packet marker/, 'framing error preserves plugin message');
is($closed, 1, 'framing failure closes stream exactly once');
ok($stream->is_closed, 'stream is closed');

done_testing;
