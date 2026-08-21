use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_INET pack_sockaddr_in inet_aton);

use Linux::Event::Address;
use Linux::Event::Error;
use Linux::Event::Listener;
use Linux::Event::Loop;
use Linux::Event::Stream;

{
    package T::ListenerProbeStream;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { }
    sub on_listener_error ($class, $listener, $error) {
        $main::STREAM_LISTENER_ERROR_CALLED++;
    }
}

{
    package T::RecoveringListener;
    use parent 'Linux::Event::Listener';
    sub on_error ($listener, $error) {
        $main::LISTENER_ERROR = $error;
        return;
    }
}

our ($STREAM_LISTENER_ERROR_CALLED, $LISTENER_ERROR);

my $loop = Linux::Event::Loop->new;

ok(!T::ListenerProbeStream->can('listen'),
    'Stream does not expose Listener construction');

like(exception(sub { Linux::Event::Listener->new(
    stream_class => 'T::ListenerProbeStream', loop => $loop,
) }),
    qr/exactly one socket source/, 'one socket source is required');
like(exception(sub {
    Linux::Event::Listener->new(
        stream_class => 'T::ListenerProbeStream',
        loop => $loop, host => '127.0.0.1', port => 0, unix => '/unused',
    );
}), qr/exactly one socket source/, 'mixed socket sources are rejected');
like(exception(sub {
    Linux::Event::Listener->new(
        stream_class => 'T::ListenerProbeStream',
        loop => $loop, host => '127.0.0.1',
    );
}), qr/port must be an integer/, 'TCP source requires a port');
like(exception(sub {
    Linux::Event::Listener->new(
        stream_class => 'T::ListenerProbeStream',
        loop => $loop, host => '127.0.0.1', port => 70_000,
    );
}), qr/port must be at most 65535/, 'out-of-range port is rejected');
like(exception(sub {
    Linux::Event::Listener->new(
        stream_class => 'T::ListenerProbeStream',
        loop => $loop, host => '127.0.0.1', port => 0,
        edge_triggered => 1, max_accept_per_tick => 1,
    );
}), qr/requires max_accept_per_tick => 0/,
    'bounded accept drain cannot be edge-triggered');
like(exception(sub {
    Linux::Event::Listener->new(
        stream_class => 'T::ListenerProbeStream',
        loop => $loop, host => '127.0.0.1', port => 0, surprise => 1,
    );
}), qr/unknown options: surprise/, 'unknown options are rejected');
like(exception(sub {
    Linux::Event::Listener->new(
        stream_class => 'T::ListenerProbeStream',
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

my $fatal_listener = Linux::Event::Listener->new(
    stream_class => 'T::ListenerProbeStream',
    host => '127.0.0.1', port => 0,
);
like(exception(sub { $fatal_listener->on_error($error) }),
    qr/^listener failed: accept: Too many open files/,
    'base Listener owns the fatal runtime-error policy');
is($STREAM_LISTENER_ERROR_CALLED, undef,
    'Listener errors are not delegated to the Stream class');
$fatal_listener->close;

my $recovering = T::RecoveringListener->new(
    stream_class => 'T::ListenerProbeStream',
    host => '127.0.0.1', port => 0,
);
$recovering->on_error($error);
is($LISTENER_ERROR, $error,
    'Listener subclass may replace runtime-error policy');
$recovering->close;

done_testing;

sub exception ($code) {
    my $error = '';
    eval { $code->(); 1 } or $error = $@;
    return $error;
}
