use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Socket qw(AF_UNIX SOCK_STREAM pack_sockaddr_un);

use Linux::Event::Loop;

{
    package T::UnixStream;
    use parent 'Linux::Event::Stream';
    sub accepted_stream_options ($class, $listener, $peer) {
        return data => $listener->data;
    }
    sub on_ready ($stream) {
        $stream->data->{peer} = $stream->peer;
        $stream->data->{stream} = $stream;
        $stream->loop->stop;
    }
    sub on_data ($stream, $bytes) { }
}

my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/listen.sock";
my $loop = Linux::Event::Loop->new;
my $state = {};
my $listener;
eval {
    $listener = T::UnixStream->listen(
        loop => $loop, unix => $path, permissions => 0600, data => $state,
    );
    1;
} or plan skip_all => "Unix stream listeners unavailable: $@";

ok(-S $path, 'created Unix listener has a socket path');
is((stat($path))[2] & 0777, 0600, 'Unix listener applies permissions');
socket(my $client, AF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
connect($client, pack_sockaddr_un($path)) or die "connect: $!";
$loop->run;
ok(!$state->{error}, 'Unix accept succeeds');
is($state->{peer}->family, 'unix', 'Unix peer exposes address family');

$state->{stream}->close;
close $client;
$listener->close;
ok(!-e $path, 'owned Unix listener removes path on close');

done_testing;
