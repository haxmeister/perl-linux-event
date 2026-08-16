use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);

use Linux::Event::Loop;
use Linux::Event::Listener;
use Linux::Event::Stream;

our ($LOOP, $CLIENT_ID, $READY, $REPLY, $SERVER_PEER, $ERROR);

{
    package T::AutomaticEcho;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Stream::Framer 'Delimiter', "\n";

    sub on_message ($stream, $message) {
        $main::SERVER_PEER = $stream->peer;
        $stream->send($message);
    }

    sub on_error ($stream, $error) {
        $main::ERROR = "$error";
        $main::LOOP->stop;
    }
}

{
    package T::AutomaticClient;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Stream::Framer 'Delimiter', "\n";

    sub on_ready ($stream) {
        $main::READY++;
        die 'connecting Stream identity changed'
            if Scalar::Util::refaddr($stream) != $main::CLIENT_ID;
    }

    sub on_message ($stream, $message) {
        $main::REPLY = $message;
        $stream->close;
        $main::LOOP->stop;
    }

    sub on_error ($stream, $error) {
        $main::ERROR = "$error";
        $main::LOOP->stop;
    }
}

$LOOP = Linux::Event::Loop->new;
my $listener = T::AutomaticEcho->listen(
    host => '127.0.0.1',
    port => 0,
);
isa_ok($listener, 'Linux::Event::Listener');
isa_ok($listener, 'Linux::Event::Watcher');
is($listener->state, 'unattached', 'Listener construction is detached');
$LOOP->add($listener);
is($listener->state, 'listening', 'add starts the Listener');

my $client = T::AutomaticClient->connect(
    host => '127.0.0.1',
    port => $listener->port,
    timeout => 5,
);
$CLIENT_ID = refaddr($client);
is($client->state, 'unattached', 'connecting Stream construction is detached');
ok(!$client->send('hello'), 'send queues before connection readiness');
is($client->pending_bytes, 6, 'pre-connect queue includes outbound framing');
$LOOP->add($client);
is($client->state, 'connecting', 'add starts outbound connection');

$LOOP->run;

is($ERROR, undef, 'automatic client/server path has no error');
is($READY, 1, 'on_ready fires once after the connection is usable');
is($REPLY, 'hello', 'automatic accepted Stream echoes one framed message');
isa_ok($SERVER_PEER, 'Linux::Event::Listen::Peer');
is(refaddr($client), $CLIENT_ID, 'client retains identity through connection');
is($client->state, 'closed', 'client reaches terminal state');

$listener->close;
done_testing;
