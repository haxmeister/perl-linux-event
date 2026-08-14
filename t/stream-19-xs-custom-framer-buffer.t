use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

{
    package T::NativeViewFramer;
    use v5.36;
    sub new ($class) { bless { calls => 0 }, $class }
    sub calls ($self) { $self->{calls} }
    sub next_frame ($self, $buffer) {
        $self->{calls}++;
        return $buffer->need(4) if $buffer->length < 4;
        die 'bad marker' if $buffer->byte(0) != 0x7e;
        my $length = unpack('n', $buffer->peek(1, 2));
        my $total = 3 + $length;
        return $buffer->need($total) if $buffer->length < $total;
        return (3, $length, $total);
    }
}

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $framer = T::NativeViewFramer->new;
my @messages;

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    read_size => 2,
    framer => $framer,
    on_message => sub ($s, $message) {
        push @messages, $message;
        $loop->stop if @messages == 1;
    },
);

is($stream->{framing_backend}, 'xs-perl', 'custom framer defaults to native storage plus Perl parser');
my $packet = "\x7e" . pack('n', 5) . 'hello';
is(syswrite($b, $packet), length($packet), 'peer wrote custom frame');
$loop->run;

is_deeply(\@messages, ['hello'], 'custom Perl framer works over native Buffer view');
my $stats = $stream->{xs_state}->stats;
is($stats->{delivery_calls}, 0, 'custom native-buffer mode avoids Perl read-chunk delivery');
ok($stats->{framing_ready_calls} >= 2, 'custom framer entered only through framing-ready callback');
is($stats->{input_buffered_bytes}, 0, 'custom frame consumption advances native buffer');

$stream->close;
close $b;
done_testing;
