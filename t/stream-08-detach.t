use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $loop = Linux::Event::XSLoop->new;
my ($data_calls, $close_calls) = (0, 0);

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    on_data => sub ($s, $bytes) { $data_calls++ },
    on_close => sub ($s) { $close_calls++ },
);

my $fh = $stream->detach;
ok(defined fileno($fh), 'detach returns an open filehandle');
ok($stream->is_closed, 'Stream abstraction is no longer active');
is($close_calls, 0, 'detach does not claim underlying resource was closed');

syswrite($b, 'still open');
my $buf = '';
is(sysread($fh, $buf, 1024), 10, 'detached handle remains usable');
is($buf, 'still open', 'detached handle receives bytes');
$loop->run_once(0);
is($data_calls, 0, 'detached Stream watcher was cancelled');

close $fh;
close $b;
done_testing;
