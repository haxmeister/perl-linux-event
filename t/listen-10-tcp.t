use v5.36;
use strict;
use warnings;
use Test::More;
use Fcntl qw(F_GETFD F_GETFL FD_CLOEXEC O_NONBLOCK);
use Socket qw(AF_INET SOCK_STREAM inet_aton pack_sockaddr_in);

use Linux::Event::XSLoop;

{
    package T::TCPListener;
    use parent 'Linux::Event::Listen';
    sub on_accept ($self, $fh, $peer) {
        my $state = $self->data;
        $state->{peer} = $peer;
        $state->{status_flags} = fcntl($fh, Fcntl::F_GETFL(), 0);
        $state->{fd_flags} = fcntl($fh, Fcntl::F_GETFD(), 0);
        $state->{written} = syswrite($fh, 'ok');
        $state->{accepted_fh} = $fh;
        $self->loop->stop;
    }
    sub on_error ($self, $error) {
        $self->data->{error} = $error;
        $self->loop->stop;
    }
}

my $loop = Linux::Event::XSLoop->new;
my $state = {};
my $listener = T::TCPListener->new(
    loop => $loop, host => '127.0.0.1', port => 0, data => $state,
);

is($listener->state, 'listening', 'listener starts active');
is($listener->host, '127.0.0.1', 'listener reports bound host');
ok($listener->port > 0, 'port zero reports kernel-assigned port');

socket(my $client, AF_INET, SOCK_STREAM, 0) or die "socket: $!";
connect($client, pack_sockaddr_in($listener->port, inet_aton('127.0.0.1')))
    or die "connect: $!";
$loop->run;

ok(!$state->{error}, 'accept succeeds without listener error');
is($listener->accepted, 1, 'accepted counter advances');
is($state->{peer}->family, 'inet', 'accepted peer reports IPv4');
is($state->{peer}->host, '127.0.0.1', 'accepted peer reports loopback host');
ok($state->{peer}->port > 0, 'accepted peer reports client port');
ok($state->{status_flags} & O_NONBLOCK, 'accept4 sets nonblocking atomically');
ok($state->{fd_flags} & FD_CLOEXEC, 'accept4 sets close-on-exec atomically');
is($state->{written}, 2, 'accepted socket remains usable in callback');
is(sysread($client, my $bytes, 2), 2, 'client receives callback output');
is($bytes, 'ok', 'accepted connection carries bytes');

$listener->pause;
ok($listener->is_paused, 'pause disables accepting');
$listener->resume;
is($listener->state, 'listening', 'resume restores accepting');
$listener->close;
is($listener->state, 'closed', 'close ends listener lifecycle');
ok(!defined($listener->fd), 'owned listener socket is closed');

close $state->{accepted_fh};
close $client;
done_testing;
