use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Fixed;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my @got;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh => $a,
    read_size => 3,
    framer => Linux::Event::Stream::Framer::Fixed->new(size => 4),
    on_message => sub ($s, $message) {
        push @got, $message;
        $loop->stop if @got == 2;
    },
);
is($stream->{framing_backend}, 'xs', 'Fixed selects native framing');
is(syswrite($b, 'abcdefghij'), 10, 'peer wrote fixed frames plus tail');
$loop->run;
is_deeply(\@got, [qw(abcd efgh)], 'native Fixed emits complete frames');
is($stream->{xs_state}->stats->{input_buffered_bytes}, 2, 'Fixed leaves incomplete tail buffered');

is($stream->send('WXYZ'), 1, 'send accepts exact fixed payload');
my $wire = '';
is(sysread($b, $wire, 4), 4, 'peer reads outbound fixed payload');
is($wire, 'WXYZ', 'Fixed outbound framing is payload itself');

my $ok = eval { $stream->send('bad'); 1 };
ok(!$ok, 'send rejects wrong fixed payload length');
like($@, qr/does not equal fixed size 4/, 'fixed-size send error is descriptive');

$stream->close;
close $b;
done_testing;
