use v5.36;
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);

use Linux::Event::Loop;
use Linux::Event::Stream;
use Linux::Event::TLS;

our ($LOOP, $STATE, $CERT, $KEY, $CLIENT_ID);

{
    package T::IntegratedTLSServer;
    use parent 'Linux::Event::Stream';

    sub accepted_stream_options ($class, $listener, $peer) {
        return (
            data => $main::STATE,
            transport => Linux::Event::TLS->server(
                cert_file => $main::CERT,
                key_file  => $main::KEY,
                alpn      => ['les-integrated/1'],
            ),
        );
    }

    sub on_ready ($stream) {
        $stream->data->{server_ready}++;
        $stream->data->{server_ready_transport} = $stream->is_transport_ready;
    }

    sub on_data ($stream, $bytes) {
        $stream->data->{server_input} .= $bytes;
        $stream->write('pong') if $stream->data->{server_input} eq 'ping';
    }

    sub on_error ($stream, $error) {
        $stream->data->{error} = "$error";
        $stream->loop->stop;
    }

    sub on_listener_error ($class, $listener, $error) {
        $main::STATE->{error} = "$error";
        $listener->loop->stop;
    }
}

{
    package T::IntegratedTLSClient;
    use parent 'Linux::Event::Stream';

    sub on_ready ($stream) {
        die 'TLS connecting Stream identity changed'
            if Scalar::Util::refaddr($stream) != $main::CLIENT_ID;
        $stream->data->{client_ready}++;
        $stream->data->{client_ready_transport} = $stream->is_transport_ready;
    }

    sub on_data ($stream, $bytes) {
        $stream->data->{client_input} .= $bytes;
        $stream->loop->stop if $stream->data->{client_input} eq 'pong';
    }

    sub on_error ($stream, $error) {
        $stream->data->{error} = "$error";
        $stream->loop->stop;
    }
}

$CERT = "$Bin/tls-certs/server-cert.pem";
$KEY = "$Bin/tls-certs/server-key.pem";
$STATE = {
    server_ready => 0,
    client_ready => 0,
    server_input => '',
    client_input => '',
    error => '',
};
$LOOP = Linux::Event::Loop->new;

my $listener = $LOOP->add(T::IntegratedTLSServer->listen(
    host => '127.0.0.1', port => 0,
));
my $client = T::IntegratedTLSClient->connect(
    host => '127.0.0.1', port => $listener->port, timeout => 5,
    data => $STATE,
    transport => Linux::Event::TLS->client(
        server_name => 'localhost',
        ca_file => $CERT,
        alpn => ['les-integrated/1'],
    ),
);
$CLIENT_ID = refaddr($client);
ok(!$client->write('ping'), 'TLS client queues application data before add');
$LOOP->add($client);
$LOOP->run_for(5);

is($STATE->{error}, '', 'integrated TLS client/server path has no error');
is($STATE->{client_ready}, 1, 'client on_ready follows verified TLS handshake');
is($STATE->{server_ready}, 1, 'accepted server on_ready follows TLS handshake');
ok($STATE->{client_ready_transport}, 'client transport is ready inside on_ready');
ok($STATE->{server_ready_transport}, 'server transport is ready inside on_ready');
is($STATE->{server_input}, 'ping', 'server receives queued client plaintext');
is($STATE->{client_input}, 'pong', 'client receives server plaintext');
is(refaddr($client), $CLIENT_ID, 'TLS Stream identity remains stable');

$client->close;
$listener->close;
done_testing;
