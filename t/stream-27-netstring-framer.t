use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;
use Linux::Event::Stream::Framer::Netstring;

my $framer = Linux::Event::Stream::Framer::Netstring->new;
is($framer->frame('hello'), '5:hello,', 'netstring outbound format');
is($framer->frame(''), '0:,', 'empty netstring outbound format');

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my @got;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh => $a,
    read_size => 2,
    framer => $framer,
    on_message => sub ($s, $message) {
        push @got, $message;
        $loop->stop if @got == 3;
    },
);
is($stream->{framing_backend}, 'xs', 'Netstring selects native framing');
my $wire = '5:alpha,0:,4:beta,2:ta';
is(syswrite($b, $wire), length($wire), 'peer wrote netstrings plus tail');
$loop->run;
is_deeply(\@got, ['alpha', '', 'beta'], 'native Netstring emits multiple messages');
is($stream->{xs_state}->stats->{input_buffered_bytes}, 4, 'netstring tail remains buffered');
$stream->close;
close $b;

socketpair(my $c, my $d, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop2 = Linux::Event::XSLoop->new;
my $error;
my $bad = Linux::Event::Stream->new(
    loop => $loop2,
    fh => $c,
    framer => Linux::Event::Stream::Framer::Netstring->new,
    on_message => sub { die 'unexpected message' },
    on_error => sub ($s, $e) { $error = "$e"; $loop2->stop },
);
syswrite($d, '03:abc,');
$loop2->run;
like($error, qr/invalid netstring leading zero/, 'native Netstring rejects noncanonical leading zero');
close $d;

done_testing;
