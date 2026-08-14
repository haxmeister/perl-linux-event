use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Delimiter;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my @got;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    framer => Linux::Event::Stream::Framer::Delimiter->new(delimiter => '|'),
    on_message => sub ($s, $message) {
        push @got, $message;
        if (@got == 1) {
            $s->pause_read;
            $loop->stop;
        } else {
            $loop->stop;
        }
    },
);

syswrite($b, 'one|two|');
$loop->run;
is_deeply(\@got, ['one'], 'pause inside native on_message stops buffered frame dispatch');
$stream->resume_read;
is_deeply(\@got, ['one', 'two'], 'resume immediately dispatches already-buffered complete frame');

$stream->close;
close $b;
done_testing;
