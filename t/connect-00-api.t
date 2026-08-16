use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX);

use Linux::Event::Connect;
use Linux::Event::Connect::Error;
use Linux::Event::XSLoop;

{
    package T::ConnectMissingBoth;
    use parent 'Linux::Event::Connect';
}

{
    package T::ConnectMissingError;
    use parent 'Linux::Event::Connect';
    sub on_connect ($self, $fh) { }
}

{
    package T::ConnectValid;
    use parent 'Linux::Event::Connect';
    sub on_connect ($self, $fh) { }
    sub on_error ($self, $error) { }
}

my $loop = Linux::Event::XSLoop->new;

like(exception(sub {
    T::ConnectValid->new(
        loop => 'not-a-loop', sockaddr => '', family => AF_UNIX,
    );
}), qr/loop must be an object/, 'loop must provide the reactor watch API');

like(exception(sub {
    Linux::Event::Connect->new(
        loop => $loop, sockaddr => '', family => AF_UNIX,
    );
}), qr/base class/, 'Connect base class is not constructible');

like(exception(sub {
    T::ConnectMissingBoth->new(
        loop => $loop, sockaddr => '', family => AF_UNIX,
    );
}), qr/must define on_connect/, 'subclass requires on_connect');

like(exception(sub {
    T::ConnectMissingError->new(
        loop => $loop, sockaddr => '', family => AF_UNIX,
    );
}), qr/must define on_error/, 'subclass requires on_error');

like(exception(sub { T::ConnectValid->new(loop => $loop) }),
    qr/exactly one address mode/, 'one address mode is required');
like(exception(sub {
    T::ConnectValid->new(loop => $loop, host => '127.0.0.1', port => 1,
        unix => '/tmp/not-used');
}), qr/exactly one address mode/, 'mixed address modes are rejected');
like(exception(sub {
    T::ConnectValid->new(loop => $loop, host => '', port => 1);
}), qr/non-empty string/, 'empty host is rejected');
like(exception(sub {
    T::ConnectValid->new(loop => $loop, host => '127.0.0.1', port => 70_000);
}), qr/between 0 and 65535/, 'out-of-range port is rejected');
like(exception(sub {
    T::ConnectValid->new(loop => $loop, unix => '/tmp/not-used', timeout => -1);
}), qr/non-negative number/, 'negative timeout is rejected');
like(exception(sub {
    T::ConnectValid->new(loop => $loop, unix => '/tmp/not-used', surprise => 1);
}), qr/unknown options: surprise/, 'unknown options are rejected');

my $error = Linux::Event::Connect::Error->new(
    type      => 'connect',
    operation => 'connect',
    errno     => 111,
    message   => 'Connection refused',
    host      => '127.0.0.1',
    port      => 9,
    attempts  => 2,
);
is($error->type, 'connect', 'typed error exposes type');
is($error->host, '127.0.0.1', 'typed error exposes host');
is($error->attempts, 2, 'typed error exposes attempt count');
is("$error", 'connect: Connection refused (errno=111)',
    'typed error stringifies with operation and errno');

done_testing;

sub exception ($code) {
    my $error = '';
    eval { $code->(); 1 } or $error = $@;
    return $error;
}
