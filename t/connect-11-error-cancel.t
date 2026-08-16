use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Socket qw(AF_UNIX SOCK_STREAM SOMAXCONN pack_sockaddr_un);

use Linux::Event::Connect;
use Linux::Event::Connect::Error;
use Linux::Event::XSLoop;

{
    package T::FailedConnect;
    use parent 'Linux::Event::Connect';
    our ($CONNECTED, $ERROR);
    sub on_connect ($self, $fh) { $CONNECTED++ }
    sub on_error ($self, $error) {
        $ERROR = $error;
        $self->loop->stop;
    }
}

my $loop = Linux::Event::XSLoop->new;
my $failed = T::FailedConnect->new(
    loop     => $loop,
    sockaddr => '',
    family   => 9999,
    timeout  => 1,
);
ok(!$T::FailedConnect::ERROR,
    'immediate socket failure is not delivered inside constructor');
ok($failed->is_pending, 'immediate operational failure is initially pending');
$loop->run;

isa_ok($T::FailedConnect::ERROR, 'Linux::Event::Connect::Error');
is($T::FailedConnect::ERROR->type, 'socket', 'socket creation failure is typed');
is($failed->state, 'failed', 'failed request enters failed state');
is($failed->error, $T::FailedConnect::ERROR,
    'request retains terminal error object');
is($T::FailedConnect::CONNECTED // 0, 0, 'failure does not call on_connect');

{
    package T::CancelledConnect;
    use parent 'Linux::Event::Connect';
    our $CALLS = 0;
    sub on_connect ($self, $fh) { $CALLS++ }
    sub on_error ($self, $error) { $CALLS++ }
}

my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/cancel.sock";
SKIP: {
    socket(my $listener, AF_UNIX, SOCK_STREAM, 0)
        or skip "Unix stream sockets unavailable: $!", 4;
    bind($listener, pack_sockaddr_un($path)) or die "bind: $!";
    listen($listener, SOMAXCONN) or die "listen: $!";

    my $cancelled = T::CancelledConnect->new(
        loop => $loop,
        unix => $path,
    );
    accept(my $server_peer, $listener) or die "accept: $!";
    ok($cancelled->cancel, 'cancel reports pending request was cancelled');
    ok(!$cancelled->cancel, 'second cancel is idempotent and reports no change');
    is($cancelled->state, 'cancelled', 'cancelled request records state');
    $loop->run_once(20);
    is($T::CancelledConnect::CALLS, 0, 'cancellation suppresses callbacks');

    close $server_peer;
    close $listener;
}

done_testing;
