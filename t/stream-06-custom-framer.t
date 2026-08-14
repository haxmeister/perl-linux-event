use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

{
    package T::U32Framer;
    use v5.36;
    sub new ($class) { bless { calls => 0 }, $class }
    sub calls ($self) { $self->{calls} }
    sub next_frame ($self, $buffer) {
        $self->{calls}++;
        return $buffer->need(4) if $buffer->length < 4;
        my $length = unpack('N', $buffer->peek(0, 4));
        die 'frame too large' if $length > 1024;
        my $total = 4 + $length;
        return $buffer->need($total) if $buffer->length < $total;
        return (4, $length, $total);
    }
}

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $framer = T::U32Framer->new;
my @messages;

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    framer => $framer,
    on_message => sub ($s, $message) {
        push @messages, $message;
        $loop->stop;
    },
);

my $packet = pack('N', 6) . 'abcdef';
syswrite($b, substr($packet, 0, 2));
$loop->run_once(0);
is($framer->calls, 1, 'framer called for first partial header');

syswrite($b, substr($packet, 2, 2));
$loop->run_once(0);
is($framer->calls, 2, 'framer called when requested 4-byte threshold reached');

syswrite($b, substr($packet, 4, 3));
$loop->run_once(0);
is($framer->calls, 2, 'need(total) suppresses avoidable Perl framer callback');

syswrite($b, substr($packet, 7));
$loop->run;
is($framer->calls, 3, 'framer called when complete frame threshold reached');
is_deeply(\@messages, ['abcdef'], 'custom framer strips length prefix and emits payload');

$stream->close;
done_testing;
