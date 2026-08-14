use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer;

my $framer = Linux::Event::Stream::Framer->decimal_length;
isa_ok($framer, 'Linux::Event::Stream::Framer::DecimalLength');
is($framer->frame('HELLO'), '5 HELLO', 'default wire form is decimal length, space, payload');
is($framer->frame(''), '0 ', 'empty payload has canonical zero length');

my $pipe = Linux::Event::Stream::Framer->decimal_length(separator => '|');
is($pipe->frame('abc'), '3|abc', 'custom one-byte separator is supported');
eval { Linux::Event::Stream::Framer->decimal_length(separator => '12') };
like($@, qr/exactly one byte/, 'multi-byte separator is rejected');
eval { Linux::Event::Stream::Framer->decimal_length(separator => '7') };
like($@, qr/must not be an ASCII digit/, 'digit separator is rejected');

my $limited = Linux::Event::Stream::Framer->decimal_length(max_frame => 3);
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
is($stream->{framing_backend}, 'xs', 'exact DecimalLength selects native framing');
my $wire = $framer->frame('')
    . $framer->frame('x' x 128)
    . $framer->frame('done')
    . '12';
is(syswrite($b, $wire), length($wire), 'peer wrote complete frames and a partial decimal prefix');
$loop->run;
is_deeply(\@got, ['', 'x' x 128, 'done'], 'native parser handles split prefixes and multiple messages');
is($stream->{xs_state}->stats->{input_buffered_bytes}, 2, 'partial decimal prefix remains buffered');
$stream->close;
close $b;

socketpair(my $c, my $d, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop2 = Linux::Event::XSLoop->new;
my $with_prefix = Linux::Event::Stream::Framer->decimal_length(
    separator => '|',
    include_prefix => 1,
);
my $got_prefix;
my $prefixed = Linux::Event::Stream->new(
    loop => $loop2,
    fh => $c,
    framer => $with_prefix,
    on_message => sub ($s, $message) { $got_prefix = $message; $loop2->stop },
);
syswrite($d, $with_prefix->frame('hello'));
$loop2->run;
is($got_prefix, '5|hello', 'include_prefix preserves decimal length and separator');
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
    native_error('05 hello', Linux::Event::Stream::Framer->decimal_length),
    qr/leading zero/,
    'native DecimalLength rejects a non-canonical leading zero',
);
like(
    native_error('x bad', Linux::Event::Stream::Framer->decimal_length),
    qr/invalid decimal length/,
    'native DecimalLength rejects a non-digit length',
);
like(
    native_error(' hello', Linux::Event::Stream::Framer->decimal_length),
    qr/invalid decimal length/,
    'native DecimalLength requires at least one length digit',
);
like(
    native_error(('1' x 21), Linux::Event::Stream::Framer->decimal_length),
    qr/decimal length field too long/,
    'native DecimalLength bounds an unterminated length field',
);
like(
    native_error('4 four', Linux::Event::Stream::Framer->decimal_length(max_frame => 3)),
    qr/frame exceeds max_frame=3/,
    'native DecimalLength enforces max_frame',
);

done_testing;
