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
my $delimiter = "\x02\xffEND\x00\x03";
my @messages;

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    framer => Linux::Event::Stream::Framer::Delimiter->new(
        delimiter => $delimiter,
    ),
    on_message => sub ($s, $message) {
        push @messages, $message;
        $loop->stop if @messages == 2;
    },
);

my $wire = "alpha${delimiter}beta${delimiter}";
my $cut = index($wire, $delimiter) + 3;
syswrite($b, substr($wire, 0, $cut));
$loop->run_once(0);
is(scalar @messages, 0, 'binary delimiter may be split across reads');

syswrite($b, substr($wire, $cut));
$loop->run;
is_deeply(\@messages, ['alpha', 'beta'], 'arbitrary binary delimiter frames messages correctly');

$stream->close;
done_testing;
