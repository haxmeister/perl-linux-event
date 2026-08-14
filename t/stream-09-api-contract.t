use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Delimiter;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $stream = Linux::Event::Stream->new(loop => $loop, fh => $a, data => { name => 'x' });

is($stream->data->{name}, 'x', 'optional user data retrieved explicitly');
$stream->data({ name => 'y' });
is($stream->data->{name}, 'y', 'user data can be replaced');
$stream->end;
ok($stream->is_write_ended, 'end with empty queue half-closes immediately');

my $ok = eval { $stream->write('late'); 1 };
ok(!$ok, 'write after end is rejected');
like($@, qr/writable side has ended/, 'write-after-end error is clear');
$stream->close;

socketpair(my $c, my $d, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $bad = eval {
    Linux::Event::Stream->new(
        loop => $loop,
        fh => $c,
        on_data => sub {},
        framer => Linux::Event::Stream::Framer::Delimiter->new(delimiter => "\n"),
        on_message => sub {},
    );
    1;
};
ok(!$bad, 'raw and framed callback modes cannot be mixed');
like($@, qr/mutually exclusive/, 'mode error is clear');
close $c;
close $d;
close $b;

done_testing;
