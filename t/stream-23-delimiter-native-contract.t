use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Delimiter;

# include_delimiter is part of the public built-in contract and must survive
# native acceleration.
socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $got;
my $s = Linux::Event::Stream->new(
    loop => $loop,
    fh => $a,
    framer => Linux::Event::Stream::Framer::Delimiter->new(
        delimiter => '<X>',
        include_delimiter => 1,
    ),
    on_message => sub ($stream, $message) { $got = $message; $loop->stop },
);
syswrite($b, 'abc<X>');
$loop->run;
is($got, 'abc<X>', 'native delimiter honors include_delimiter');
$s->close;
close $b;

# A subclass is a custom framer. Do not silently bypass an overridden
# next_frame() merely because it inherits from the built-in Delimiter class.
{
    package T::DelimiterSubclass;
    our @ISA = ('Linux::Event::Stream::Framer::Delimiter');
    sub next_frame ($self, $buffer) {
        my $pos = $buffer->index('!');
        return if $pos < 0;
        return (0, $pos, $pos + 1);
    }
}

socketpair(my $c, my $d, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop2 = Linux::Event::XSLoop->new;
my $sub = T::DelimiterSubclass->new(delimiter => '<IGNORED>');
my $got2;
my $s2 = Linux::Event::Stream->new(
    loop => $loop2,
    fh => $c,
    framer => $sub,
    on_message => sub ($stream, $message) { $got2 = $message; $loop2->stop },
);
is($s2->{framing_backend}, 'xs-perl', 'Delimiter subclass stays on custom plug-in path');
syswrite($d, 'custom!');
$loop2->run;
is($got2, 'custom', 'overridden next_frame remains authoritative');
$s2->close;
close $d;

done_testing;
