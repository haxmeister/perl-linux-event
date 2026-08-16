use v5.36;
use strict;
use warnings;
use Test::More;
use Fcntl qw(F_GETFD F_GETFL FD_CLOEXEC O_NONBLOCK);
use Socket qw(
    AF_INET SOCK_STREAM SOL_SOCKET SO_ACCEPTCONN
    INADDR_LOOPBACK pack_sockaddr_in
);

use Linux::Event::XSLoop;

{
    package T::OwnedListener;
    use parent 'Linux::Event::Listen';
    sub on_accept ($self, $fh, $peer) { close $fh }
    sub on_error ($self, $error) { die "$error\n" }
}

sub raw_listener () {
    socket(my $fh, AF_INET, SOCK_STREAM, 0) or die "socket: $!";
    bind($fh, pack_sockaddr_in(0, INADDR_LOOPBACK)) or die "bind: $!";
    listen($fh, 16) or die "listen: $!";
    return $fh;
}

my $borrowed = raw_listener();
my $borrowed_fd = fileno($borrowed);
my $loop = Linux::Event::XSLoop->new;
my $listener = T::OwnedListener->new(loop => $loop, fh => $borrowed);
is($listener->fd, $borrowed_fd, 'adopted listener preserves descriptor');
ok(fcntl($borrowed, F_GETFL, 0) & O_NONBLOCK,
    'adopted listener is made nonblocking');
ok(fcntl($borrowed, F_GETFD, 0) & FD_CLOEXEC,
    'adopted listener is made close-on-exec');
$listener->close;
is($listener->state, 'closed', 'borrowed listener wrapper closes');
ok(!defined($listener->fd), 'closed wrapper releases borrowed handle reference');
ok(defined(fileno($borrowed)), 'borrowed listening handle remains open');
ok(unpack('i', getsockopt($borrowed, SOL_SOCKET, SO_ACCEPTCONN)),
    'borrowed handle remains a listener');
close $borrowed;

my $detached_source = raw_listener();
my $detached_fd = fileno($detached_source);
my $loop2 = Linux::Event::XSLoop->new;
my $detaching = T::OwnedListener->new(
    loop => $loop2, fh => $detached_source, owns_socket => 1,
);
my $detached = $detaching->detach;
is($detaching->state, 'detached', 'detach ends watcher lifecycle');
ok(!defined($detaching->fd), 'detached listener drops object handle');
is(fileno($detached), $detached_fd, 'detach returns the listening handle');
close $detached;

done_testing;
