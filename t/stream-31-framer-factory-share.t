use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer;

my $line = Linux::Event::Stream::Framer->line;
isa_ok($line, 'Linux::Event::Stream::Framer::Delimiter');

isa_ok(
    Linux::Event::Stream::Framer->delimiter("\x00"),
    'Linux::Event::Stream::Framer::Delimiter',
);
isa_ok(
    Linux::Event::Stream::Framer->fixed(size => 4),
    'Linux::Event::Stream::Framer::Fixed',
);
isa_ok(
    Linux::Event::Stream::Framer->length_prefix(bytes => 2, endian => 'big'),
    'Linux::Event::Stream::Framer::LengthPrefix',
);
isa_ok(
    Linux::Event::Stream::Framer->u32be,
    'Linux::Event::Stream::Framer::U32BE',
);
isa_ok(
    Linux::Event::Stream::Framer->netstring,
    'Linux::Event::Stream::Framer::Netstring',
);
isa_ok(
    Linux::Event::Stream::Framer->varint,
    'Linux::Event::Stream::Framer::Varint',
);

socketpair(my $sa, my $ca, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
socketpair(my $sb, my $cb, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

my $loop = Linux::Event::XSLoop->new;
my %got;
my $done = 0;

my $a = Linux::Event::Stream->new(
    loop => $loop,
    fh => $sa,
    framer => $line,
    on_message => sub ($stream, $message) {
        $got{a} = $message;
        $loop->stop if ++$done == 2;
    },
);
my $b = Linux::Event::Stream->new(
    loop => $loop,
    fh => $sb,
    framer => $line,
    on_message => sub ($stream, $message) {
        $got{b} = $message;
        $loop->stop if ++$done == 2;
    },
);

is($a->{framing_backend}, 'xs', 'factory line keeps native framing path');
is($b->{framing_backend}, 'xs', 'shared factory framer keeps native path on second Stream');

# Interleaved partial input verifies that parser state remains per Stream even
# when both Streams share the same framing definition object.
syswrite($ca, 'hel');
syswrite($cb, "world\n");
syswrite($ca, "lo\n");
$loop->run;

is($got{a}, 'hello', 'shared framer keeps Stream A state independent');
is($got{b}, 'world', 'shared framer keeps Stream B state independent');

$a->close;
$b->close;
close $ca;
close $cb;

done_testing;
