use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::LengthPrefix;

my $be = Linux::Event::Stream::Framer::LengthPrefix->new(bytes => 2, endian => 'big');
is($be->frame('abc'), "\x00\x03abc", 'big-endian outbound prefix');
my $le = Linux::Event::Stream::Framer::LengthPrefix->new(bytes => 2, endian => 'little');
is($le->frame('abc'), "\x03\x00abc", 'little-endian outbound prefix');

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my @got;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh => $a,
    read_size => 2,
    framer => $be,
    on_message => sub ($s, $message) {
        push @got, $message;
        $loop->stop if @got == 2;
    },
);
is($stream->{framing_backend}, 'xs', 'LengthPrefix selects native framing');
my $wire = "\x00\x05alpha\x00\x04betaZ";
is(syswrite($b, $wire), length($wire), 'peer wrote two prefixed frames plus tail');
$loop->run;
is_deeply(\@got, [qw(alpha beta)], 'native LengthPrefix decodes split input');
is($stream->{xs_state}->stats->{input_buffered_bytes}, 1, 'length framer leaves tail buffered');
$stream->close;
close $b;

socketpair(my $c, my $d, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop2 = Linux::Event::XSLoop->new;
my $error;
my $limited = Linux::Event::Stream->new(
    loop => $loop2,
    fh => $c,
    framer => Linux::Event::Stream::Framer::LengthPrefix->new(
        bytes => 2,
        max_frame => 3,
    ),
    on_message => sub { die 'unexpected message' },
    on_error => sub ($s, $e) { $error = "$e"; $loop2->stop },
);
syswrite($d, "\x00\x04test");
$loop2->run;
like($error, qr/frame exceeds max_frame=3/, 'native length prefix enforces max_frame');
close $d;

done_testing;
