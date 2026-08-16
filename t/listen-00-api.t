use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_INET pack_sockaddr_in inet_aton);

use Linux::Event::Listen;
use Linux::Event::Listen::Error;
use Linux::Event::Listen::Peer;
use Linux::Event::XSLoop;

{
    package T::ListenMissingBoth;
    use parent 'Linux::Event::Listen';
}

{
    package T::ListenMissingError;
    use parent 'Linux::Event::Listen';
    sub on_accept ($self, $fh, $peer) { }
}

{
    package T::ListenValid;
    use parent 'Linux::Event::Listen';
    sub on_accept ($self, $fh, $peer) { }
    sub on_error ($self, $error) { }
}

my $loop = Linux::Event::XSLoop->new;

like(exception(sub {
    Linux::Event::Listen->new(loop => $loop, host => '127.0.0.1', port => 0);
}), qr/base class/, 'Listen base class is not constructible');

like(exception(sub {
    T::ListenMissingBoth->new(
        loop => $loop, host => '127.0.0.1', port => 0,
    );
}), qr/must define on_accept/, 'subclass requires on_accept');

like(exception(sub {
    T::ListenMissingError->new(
        loop => $loop, host => '127.0.0.1', port => 0,
    );
}), qr/must define on_error/, 'subclass requires on_error');

like(exception(sub { T::ListenValid->new(loop => $loop) }),
    qr/exactly one socket source/, 'one socket source is required');
like(exception(sub {
    T::ListenValid->new(
        loop => $loop, host => '127.0.0.1', port => 0, unix => '/unused',
    );
}), qr/exactly one socket source/, 'mixed socket sources are rejected');
like(exception(sub {
    T::ListenValid->new(loop => $loop, host => '127.0.0.1');
}), qr/port must be an integer/, 'TCP source requires a port');
like(exception(sub {
    T::ListenValid->new(
        loop => $loop, host => '127.0.0.1', port => 70_000,
    );
}), qr/port must be at most 65535/, 'out-of-range port is rejected');
like(exception(sub {
    T::ListenValid->new(
        loop => $loop, host => '127.0.0.1', port => 0,
        edge_triggered => 1, max_accept_per_tick => 1,
    );
}), qr/requires max_accept_per_tick => 0/,
    'bounded accept drain cannot be edge-triggered');
like(exception(sub {
    T::ListenValid->new(
        loop => $loop, host => '127.0.0.1', port => 0, surprise => 1,
    );
}), qr/unknown options: surprise/, 'unknown options are rejected');
like(exception(sub {
    T::ListenValid->new(
        loop => $loop, host => '127.0.0.1', port => 0, permissions => 0600,
    );
}), qr/options not valid.*permissions/,
    'source-specific options cannot silently affect another mode');

my $peer = Linux::Event::Listen::Peer->new(
    pack_sockaddr_in(4321, inet_aton('127.0.0.1')),
);
is($peer->family, 'inet', 'peer parses IPv4 family lazily');
is($peer->family_number, AF_INET, 'peer exposes numeric family');
is($peer->host, '127.0.0.1', 'peer exposes host');
is($peer->port, 4321, 'peer exposes port');

my $error = Linux::Event::Listen::Error->new(
    type => 'resource', operation => 'accept', errno => 24,
    message => 'Too many open files', fatal => 0,
);
is($error->type, 'resource', 'typed error exposes type');
ok(!$error->fatal, 'typed error exposes fatality');
is("$error", 'accept: Too many open files (errno=24)',
    'typed error stringifies with operation and errno');

done_testing;

sub exception ($code) {
    my $error = '';
    eval { $code->(); 1 } or $error = $@;
    return $error;
}
