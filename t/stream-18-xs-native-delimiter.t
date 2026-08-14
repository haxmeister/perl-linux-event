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
my $delimiter = "\x02END\x03";
my @messages;

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    read_size => 4,
    framer => Linux::Event::Stream::Framer::Delimiter->new(
        delimiter => $delimiter,
    ),
    on_message => sub ($s, $message) {
        push @messages, $message;
        $loop->stop if @messages == 2;
    },
);

is($stream->{framing_backend}, 'xs', 'built-in delimiter selects native framing by default');

my $wire = "alpha${delimiter}beta${delimiter}tail";
is(syswrite($b, $wire), length($wire), 'peer wrote framed bytes');
$loop->run;

is_deeply(\@messages, [qw(alpha beta)], 'native delimiter emits complete messages');

my $stats = $stream->{xs_state}->stats;
ok($stats->{input_appends} >= 2, 'small read_size appended multiple chunks directly to native input');
is($stats->{delivery_calls}, 0, 'native framed reads do not create/deliver Perl read chunks');
is($stats->{frames_emitted}, 2, 'native framer counted semantic frames');
ok($stats->{delimiter_searches} >= 2, 'delimiter search executed natively');
is($stats->{input_buffered_bytes}, 4, 'incomplete tail remains in native storage');

$stream->close;
close $b;
done_testing;
