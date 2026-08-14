use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Fixed;

{
    package T::FixedSubclass;
    our @ISA = ('Linux::Event::Stream::Framer::Fixed');
    sub next_frame ($self, $buffer) {
        my $pos = $buffer->index('!');
        return if $pos < 0;
        return (0, $pos, $pos + 1);
    }
}

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $got;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh => $a,
    framer => T::FixedSubclass->new(size => 4),
    on_message => sub ($s, $message) { $got = $message; $loop->stop },
);
is($stream->{framing_backend}, 'xs-perl', 'built-in subclass stays on custom framer path');
syswrite($b, 'custom!');
$loop->run;
is($got, 'custom', 'subclass next_frame remains authoritative');
$stream->close;
close $b;

done_testing;
