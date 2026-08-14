use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my $calls = 0;
my $got = '';

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    on_data => sub ($s, $bytes) {
        $calls++;
        $got .= $bytes;
        $loop->stop;
    },
);

$stream->pause_read;
ok($stream->is_read_paused, 'read side is paused');
syswrite($b, 'paused');
$loop->run_once(0);
is($calls, 0, 'paused stream does not deliver data');

$stream->resume_read;
ok(!$stream->is_read_paused, 'read side resumed');
$loop->run;
is($got, 'paused', 'queued kernel data delivered after resume');

$stream->close;
done_testing;
