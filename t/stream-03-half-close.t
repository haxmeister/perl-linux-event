use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SHUT_WR);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my ($request, $eof_calls, $close_calls) = ('', 0, 0);

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    on_data => sub ($s, $bytes) {
        $request .= $bytes;
    },
    on_eof => sub ($s) {
        $eof_calls++;
        ok($s->is_read_eof, 'read EOF state set before callback');
        ok(!$s->is_write_ended, 'writable side still open at peer EOF');
        ok($s->write('response'), 'write remains legal after peer EOF');
        $s->end;
    },
    on_close => sub ($s) {
        $close_calls++;
        $loop->stop;
    },
);

syswrite($b, 'request');
shutdown($b, SHUT_WR) or die "shutdown peer: $!";
$loop->run;

is($request, 'request', 'data is drained before EOF completion');
is($eof_calls, 1, 'on_eof fires once');
is($close_calls, 1, 'stream closes after both directions end');
ok($stream->is_write_ended, 'local writable side ended');
ok($stream->is_closed, 'stream closed after full duplex completion');

my $response = '';
my $n = sysread($b, $response, 1024);
is($n, 8, 'peer can read response written after its half-close');
is($response, 'response', 'response content is intact');

done_testing;
