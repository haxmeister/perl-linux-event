use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer;
use Linux::Event::Stream::Framer::Varint;

my $framer = Linux::Event::Stream::Framer->varint;
isa_ok($framer, 'Linux::Event::Stream::Framer::Varint');
is($framer->frame(''), "\x00", 'zero-length payload has one-byte prefix');
is(substr($framer->frame('x' x 127), 0, 1), "\x7f", '127 uses one prefix byte');
is(substr($framer->frame('x' x 128), 0, 2), "\x80\x01", '128 uses two prefix bytes');
is(substr($framer->frame('x' x 300), 0, 2), "\xac\x02", '300 uses canonical LEB128');

my $limited = Linux::Event::Stream::Framer->varint(max_frame => 3);
eval { $limited->frame('four') };
like($@, qr/exceeds max_frame=3/, 'outbound frame enforces max_frame');

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my @got;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh => $a,
    read_size => 1,
    framer => $framer,
    on_message => sub ($s, $message) {
        push @got, $message;
        $loop->stop if @got == 3;
    },
);
is($stream->{framing_backend}, 'xs', 'exact Varint selects native framing');
my $wire = $framer->frame('')
    . $framer->frame('x' x 128)
    . $framer->frame('done')
    . "\x80";
is(syswrite($b, $wire), length($wire), 'peer wrote complete frames and partial prefix');
$loop->run;
is_deeply(\@got, ['', 'x' x 128, 'done'], 'native Varint handles split prefixes and multiple messages');
is($stream->{xs_state}->stats->{input_buffered_bytes}, 1, 'partial trailing prefix remains buffered');
$stream->close;
close $b;

socketpair(my $pa, my $pb, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $perl_loop = Linux::Event::XSLoop->new;
my $perl_got;
my $perl_framed = Linux::Event::Stream->new(
    loop => $perl_loop,
    fh => $pa,
    read_size => 1,
    framer => $framer,
    _framing_backend => 'xs-perl',
    on_message => sub ($s, $message) { $perl_got = $message; $perl_loop->stop },
);
syswrite($pb, $framer->frame('x' x 300));
$perl_loop->run;
is($perl_got, 'x' x 300, 'Perl fallback decodes the same multi-byte Varint wire format');
$perl_framed->close;
close $pb;

socketpair(my $c, my $d, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop2 = Linux::Event::XSLoop->new;
my $with_prefix = Linux::Event::Stream::Framer->varint(include_prefix => 1);
my $got_prefix;
my $prefixed = Linux::Event::Stream->new(
    loop => $loop2,
    fh => $c,
    framer => $with_prefix,
    on_message => sub ($s, $message) { $got_prefix = $message; $loop2->stop },
);
syswrite($d, $with_prefix->frame('x' x 128));
$loop2->run;
is(substr($got_prefix, 0, 2), "\x80\x01", 'include_prefix preserves the actual variable-width prefix');
is(length($got_prefix), 130, 'include_prefix message has prefix plus payload');
$prefixed->close;
close $d;

sub native_error ($wire, $configured_framer) {
    socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    my $error_loop = Linux::Event::XSLoop->new;
    my $error;
    my $bad = Linux::Event::Stream->new(
        loop => $error_loop,
        fh => $left,
        framer => $configured_framer,
        on_message => sub { die 'unexpected message' },
        on_error => sub ($s, $e) { $error = "$e"; $error_loop->stop },
    );
    syswrite($right, $wire);
    $error_loop->run;
    $bad->close;
    close $right;
    return $error;
}

like(
    native_error("\x80\x00", Linux::Event::Stream::Framer->varint),
    qr/non-canonical varint length/,
    'native Varint rejects an overlong zero',
);
like(
    native_error(("\x80" x 10), Linux::Event::Stream::Framer->varint),
    qr/(?:prefix too long|overflow)/,
    'native Varint rejects a prefix longer than ten bytes',
);
like(
    native_error(("\xff" x 9) . "\x02", Linux::Event::Stream::Framer->varint),
    qr/varint length overflow/,
    'native Varint rejects values beyond unsigned 64-bit',
);
like(
    native_error("\x04four", Linux::Event::Stream::Framer->varint(max_frame => 3)),
    qr/frame exceeds max_frame=3/,
    'native Varint enforces max_frame',
);

done_testing;
