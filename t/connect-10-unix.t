use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Socket qw(AF_UNIX SOCK_STREAM SOMAXCONN pack_sockaddr_un);

use Linux::Event::Connect;
use Linux::Event::XSLoop;

{
    package T::UnixConnect;
    use parent 'Linux::Event::Connect';
    our ($CALLED, $FH, $ERROR);
    sub on_connect ($self, $fh) {
        $CALLED++;
        $FH = $fh;
        $self->loop->stop;
    }
    sub on_error ($self, $error) {
        $ERROR = $error;
        $self->loop->stop;
    }
}

my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/connect.sock";
socket(my $listener, AF_UNIX, SOCK_STREAM, 0)
    or plan skip_all => "Unix stream sockets unavailable: $!";
bind($listener, pack_sockaddr_un($path)) or die "bind: $!";
listen($listener, SOMAXCONN) or die "listen: $!";

my $loop = Linux::Event::XSLoop->new;
my $data = { target => 'unix' };
my $request = T::UnixConnect->new(
    loop    => $loop,
    unix    => $path,
    timeout => 1,
    data    => $data,
);

is($T::UnixConnect::CALLED // 0, 0,
    'immediate Unix success is not delivered inside constructor');
ok($request->is_pending, 'request remains pending until loop dispatch');
is($request->path, $path, 'path accessor preserves Unix target');
is($request->data, $data, 'data accessor preserves application state');

accept(my $server_peer, $listener) or die "accept: $!";
$loop->run;

is($T::UnixConnect::CALLED, 1, 'success callback runs once');
ok(!$T::UnixConnect::ERROR, 'success does not report an error');
is($request->state, 'connected', 'successful request enters connected state');
ok($request->is_done, 'successful request is done');
ok(defined fileno($T::UnixConnect::FH), 'callback owns connected filehandle');
is($request->attempts, 1, 'one Unix socket was attempted');

syswrite($T::UnixConnect::FH, 'ok');
is(sysread($server_peer, my $bytes, 2), 2, 'transferred socket remains usable');
is($bytes, 'ok', 'transferred socket carries bytes');

close $T::UnixConnect::FH;
close $server_peer;
close $listener;

done_testing;
