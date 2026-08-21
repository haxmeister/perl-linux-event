use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_INET pack_sockaddr_in inet_aton);

use Linux::Event::Address;
use Linux::Event::Error;
use Linux::Event::Loop;
use Linux::Event::Stream;

{
    package T::ListenerProbeStream;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { }
}

my $loop = Linux::Event::Loop->new;

like(exception(sub { T::ListenerProbeStream->listen(loop => $loop) }),
    qr/exactly one socket source/, 'one socket source is required');
like(exception(sub {
    T::ListenerProbeStream->listen(
        loop => $loop, host => '127.0.0.1', port => 0, unix => '/unused',
    );
}), qr/exactly one socket source/, 'mixed socket sources are rejected');
like(exception(sub {
    T::ListenerProbeStream->listen(loop => $loop, host => '127.0.0.1');
}), qr/port must be an integer/, 'TCP source requires a port');
like(exception(sub {
    T::ListenerProbeStream->listen(
        loop => $loop, host => '127.0.0.1', port => 70_000,
    );
}), qr/port must be at most 65535/, 'out-of-range port is rejected');
like(exception(sub {
    T::ListenerProbeStream->listen(
        loop => $loop, host => '127.0.0.1', port => 0,
        edge_triggered => 1, max_accept_per_tick => 1,
    );
}), qr/requires max_accept_per_tick => 0/,
    'bounded accept drain cannot be edge-triggered');
like(exception(sub {
    T::ListenerProbeStream->listen(
        loop => $loop, host => '127.0.0.1', port => 0, surprise => 1,
    );
}), qr/unknown options: surprise/, 'unknown options are rejected');
like(exception(sub {
    T::ListenerProbeStream->listen(
        loop => $loop, host => '127.0.0.1', port => 0, permissions => 0600,
    );
}), qr/options not valid.*permissions/,
    'source-specific options cannot silently affect another mode');

my $address = Linux::Event::Address->new(
    pack_sockaddr_in(4321, inet_aton('127.0.0.1')),
);
is($address->family, 'inet', 'Address parses IPv4 family lazily');
is($address->family_number, AF_INET, 'Address exposes numeric family');
is($address->host, '127.0.0.1', 'Address exposes host');
is($address->port, 4321, 'Address exposes port');

my $error = Linux::Event::Error->new(
    type => 'resource', operation => 'accept', errno => 24,
    message => 'Too many open files', fatal => 0,
);
is($error->type, 'resource', 'Error exposes type');
ok(!$error->fatal, 'Error exposes fatality');
is("$error", 'accept: Too many open files (errno=24)',
    'Error stringifies with operation and errno');

done_testing;

sub exception ($code) {
    my $error = '';
    eval { $code->(); 1 } or $error = $@;
    return $error;
}
