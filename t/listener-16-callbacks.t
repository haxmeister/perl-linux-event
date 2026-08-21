use v5.36;
use strict;
use warnings;

use Test::More;
use Socket qw(AF_INET SOCK_STREAM inet_aton pack_sockaddr_in);

use Linux::Event::Listener;
use Linux::Event::Loop;
use Linux::Event::Stream;

{
    package T::CallbackStream;
    use parent 'Linux::Event::Stream';

    sub on_ready ($stream) {
        $stream->data->{ready}++;
        return;
    }

    sub on_data ($stream, $bytes) { return }

    sub on_close ($stream) {
        $stream->data->{closed}++;
        return;
    }
}

{
    package T::FailingAcceptListener;
    use parent 'Linux::Event::Listener';

    sub on_accept ($listener, $stream) {
        $listener->data->{stream} = $stream;
        die "application rejected accept\n";
    }

    sub on_error ($listener, $error) {
        $listener->data->{error} = $error;
        $listener->loop->stop;
        return;
    }
}

my $loop = Linux::Event::Loop->new;
my $state = { ready => 0, closed => 0 };
my $listener = T::FailingAcceptListener->new(
    loop         => $loop,
    stream_class => 'T::CallbackStream',
    host         => '127.0.0.1',
    port         => 0,
    data         => $state,
);

socket(my $client, AF_INET, SOCK_STREAM, 0) or die "socket: $!";
connect($client, pack_sockaddr_in($listener->port, inet_aton('127.0.0.1')))
    or die "connect: $!";
$loop->run;

isa_ok($state->{error}, 'Linux::Event::Error');
is($state->{error}->type, 'callback',
    'on_accept exception becomes a callback error');
is($state->{error}->operation, 'on_accept',
    'callback error identifies on_accept');
like($state->{error}->message, qr/application rejected accept/,
    'callback error retains the exception message');
ok(!$state->{error}->fatal, 'on_accept callback failure is not Listener-fatal');
is($listener->last_error, $state->{error},
    'Listener retains the callback error');
ok($state->{stream}->is_closed,
    'on_accept exception closes the constructed Stream');
is($state->{closed}, 1, 'failed accepted Stream closes exactly once');
is($state->{ready}, 0, 'failed on_accept suppresses Stream on_ready');
is($listener->state, 'listening',
    'handled callback error leaves Listener accepting');

$listener->close;
close $client;
done_testing;
