use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer;
use Linux::Event::Stream::Framer::DecimalLength;

{
    package T::DecimalLengthSubclass;
    our @ISA = ('Linux::Event::Stream::Framer::DecimalLength');
    sub next_frame ($self, $buffer) {
        my $pos = $buffer->index('!');
        return if $pos < 0;
        return (0, $pos, $pos + 1);
    }
}

socketpair(my $sa, my $ca, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $sub_loop = Linux::Event::XSLoop->new;
my $custom;
my $sub_stream = Linux::Event::Stream->new(
    loop => $sub_loop,
    fh => $sa,
    framer => T::DecimalLengthSubclass->new,
    on_message => sub ($s, $message) { $custom = $message; $sub_loop->stop },
);
is($sub_stream->{framing_backend}, 'xs-perl', 'DecimalLength subclass stays on custom plug-in path');
syswrite($ca, 'custom!');
$sub_loop->run;
is($custom, 'custom', 'subclass next_frame remains authoritative');
$sub_stream->close;
close $ca;

my $shared = Linux::Event::Stream::Framer->decimal_length;
socketpair(my $sx, my $cx, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
socketpair(my $sy, my $cy, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my %got;
my $done = 0;
my $x = Linux::Event::Stream->new(
    loop => $loop,
    fh => $sx,
    framer => $shared,
    on_message => sub ($s, $message) { $got{x} = $message; $loop->stop if ++$done == 2 },
);
my $y = Linux::Event::Stream->new(
    loop => $loop,
    fh => $sy,
    framer => $shared,
    on_message => sub ($s, $message) { $got{y} = $message; $loop->stop if ++$done == 2 },
);
is($x->{framing_backend}, 'xs', 'shared DecimalLength is native on Stream X');
is($y->{framing_backend}, 'xs', 'shared DecimalLength is native on Stream Y');
syswrite($cx, '128');
syswrite($cy, $shared->frame('other'));
syswrite($cx, ' ' . ('x' x 128));
$loop->run;
is($got{x}, 'x' x 128, 'Stream X retains its own partial decimal prefix state');
is($got{y}, 'other', 'Stream Y parses independently with the shared definition');
$x->close;
$y->close;
close $cx;
close $cy;

socketpair(my $pa, my $pb, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $perl_loop = Linux::Event::XSLoop->new;
my $perl_got;
my $perl_stream = Linux::Event::Stream->new(
    loop => $perl_loop,
    fh => $pa,
    read_size => 1,
    framer => $shared,
    _framing_backend => 'xs-perl',
    on_message => sub ($s, $message) { $perl_got = $message; $perl_loop->stop },
);
syswrite($pb, $shared->frame('x' x 300));
$perl_loop->run;
is($perl_got, 'x' x 300, 'Perl fallback decodes the same decimal-length wire format');
$perl_stream->close;
close $pb;

done_testing;
