use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX);

use Linux::Event::Connect;
use Linux::Event::XSLoop;

{
    package T::HeldConnect;
    use parent 'Linux::Event::Connect';
    our $ERROR;
    sub on_connect ($self, $fh) { die 'held request unexpectedly connected' }
    sub on_error ($self, $error) {
        $ERROR = $error;
        $self->loop->stop;
    }
    sub _attempt_next ($self) { return }
}

my $loop = Linux::Event::XSLoop->new;
my $request = T::HeldConnect->new(
    loop     => $loop,
    sockaddr => '',
    family   => AF_UNIX,
    timeout  => 0.01,
);
is($request->timeout, 0.01, 'timeout accessor uses seconds');
ok($request->is_pending, 'held request starts pending');
$loop->run;

is($request->state, 'failed', 'deadline failure completes request');
is($T::HeldConnect::ERROR->type, 'timeout', 'deadline produces timeout type');
is($T::HeldConnect::ERROR->operation, 'connect',
    'deadline identifies connection operation');
is($T::HeldConnect::ERROR->errno + 0, Errno::ETIMEDOUT() + 0,
    'deadline exposes ETIMEDOUT');

done_testing;
