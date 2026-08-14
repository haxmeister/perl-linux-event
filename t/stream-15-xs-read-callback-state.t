use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

# Closing from on_data must stop the native drain before a second callback.
socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $calls = 0;
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    read_size => 4,
    on_data => sub ($s, $bytes) {
        $calls++;
        $s->close;
        $loop->stop;
    },
);
syswrite($b, 'abcdefgh');
$loop->run;
is($calls, 1, 'close inside on_data stops native read drain safely');
close $b;

# Pausing from on_data must also stop the native drain until resumed.
socketpair(my $c, my $d, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop2 = Linux::Event::XSLoop->new;
my $got = '';
my $pause_calls = 0;
my $stream2 = Linux::Event::Stream->new(
    loop => $loop2,
    fh   => $c,
    read_size => 4,
    on_data => sub ($s, $bytes) {
        $got .= $bytes;
        $pause_calls++;
        if ($pause_calls == 1) {
            $s->pause_read;
            $loop2->stop;
        } else {
            $loop2->stop if length($got) == 8;
        }
    },
);
syswrite($d, 'abcdefgh');
$loop2->run;
is(length($got), 4, 'pause inside callback stops further native reads');
$stream2->resume_read;
$loop2->run;
is($got, 'abcdefgh', 'resume continues native read drain');
$stream2->close;
close $d;

done_testing;
