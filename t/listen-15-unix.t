use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Socket qw(AF_UNIX SOCK_STREAM pack_sockaddr_un);

use Linux::Event::XSLoop;

{
    package T::UnixListener;
    use parent 'Linux::Event::Listen';
    sub on_accept ($self, $fh, $peer) {
        $self->data->{peer} = $peer;
        $self->data->{fh} = $fh;
        $self->loop->stop;
    }
    sub on_error ($self, $error) {
        $self->data->{error} = $error;
        $self->loop->stop;
    }
}

my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/listen.sock";
my $loop = Linux::Event::XSLoop->new;
my $state = {};
my $listener;
eval {
    $listener = T::UnixListener->new(
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

close $state->{fh};
close $client;
$listener->close;
ok(!-e $path, 'owned Unix listener removes path on close');

done_testing;
