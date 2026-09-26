use v5.36;
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);

use Linux::Event::Loop;
use Linux::Event::_ByteStream ();
use Linux::Event::IO::Sock::Listener;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Framer ();
use Linux::Event::TLS;

BEGIN {
    require XSLoader;
    XSLoader::load('Linux::Event::_ByteStream::ExternalTestConsumer');
}

sub external_consumer_definition () {
    return {
        provider =>
            \&Linux::Event::_ByteStream::ExternalTestConsumer::operations_address,
        abi_version => 1,
        operations_address =>
            Linux::Event::_ByteStream::ExternalTestConsumer::operations_address(),
    };
}

{
    package T::TLSNativeConsumerSource;
    use parent 'Linux::Event::IO::Sock::Stream';

    BEGIN {
        Linux::Event::Framer->declare_native_consumer(
            __PACKAGE__,
            main::external_consumer_definition(),
        );
    }

    sub on_ready ($stream) {
        my $state = $stream->data;
        return if $state->{transition_scheduled}++;

        $state->{selected_alpn} = $stream->selected_alpn;
        $state->{before_id} = Scalar::Util::refaddr($stream);
        $state->{before_fd} = $stream->read_fd;

        $stream->pause_read;
        $state->{paused_before_transition} = $stream->is_read_paused ? 1 : 0;

        $state->{deferred} = $stream->loop->defer(sub {
            $state->{deferred_ran} = 1;
            $stream->transition_to('T::TLSOrdinaryRawTarget');
            $state->{after_class} = ref($stream);
            $state->{after_id} = Scalar::Util::refaddr($stream);
            $state->{after_fd} = $stream->read_fd;
            $state->{after_transport} = $stream->transport_name;

            $stream->resume_read;
            $state->{resumed_after_transition}
                = $stream->is_read_paused ? 0 : 1;

            $state->{client}->write("after-transition\n");
        });
    }

    sub on_error ($stream, $error) {
        $stream->data->{error} = "$error";
        $stream->loop->stop;
    }
}

{
    package T::TLSOrdinaryRawTarget;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) {
        $stream->data->{bytes} .= $bytes;
        $stream->loop->stop
            if $stream->data->{bytes} =~ /after-transition\n/;
    }

    sub on_error ($stream, $error) {
        $stream->data->{error} = "$error";
        $stream->loop->stop;
    }
}

my $loop = Linux::Event::Loop->new;
my $state = {
    bytes => '',
    error => '',
};
my $cert = "$Bin/tls-certs/server-cert.pem";
my $key = "$Bin/tls-certs/server-key.pem";
my $destroyed_before =
    Linux::Event::_ByteStream::ExternalTestConsumer::destroy_count();
my $input_before =
    Linux::Event::_ByteStream::ExternalTestConsumer::input_count();

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::TLSNativeConsumerSource',
        data => $state,
        tls => {
            cert_file => $cert,
            key_file => $key,
            alpn => ['h2', 'http/1.1'],
        },
    },
    on_accept => sub ($listener, $stream) {
        $state->{accepted} = $stream;
    },
    on_error => sub ($listener, $error) {
        $state->{error} = "$error";
        $loop->stop;
    },
);

my $client = Linux::Event::IO::Sock::Stream->connect(
    host => 'localhost',
    port => $listener->port,
    timeout => 5,
    data => $state,
    transport => Linux::Event::TLS->client(
        server_name => 'localhost',
        ca_file => $cert,
        alpn => ['h2', 'http/1.1'],
    ),
    on_data => sub ($stream, $bytes) { return },
    on_error => sub ($stream, $error) {
        $state->{error} = "$error";
        $loop->stop;
    },
);
$state->{client} = $client;

$client->write("early-input\n");
$loop->add($client);

my $ok = eval {
    $loop->run_for(5);
    1;
};
ok($ok,
    'TLS native consumer may transition to ordinary raw Stream')
    or diag $@;
ok($state->{accepted},
    'Listener accepted the TLS native-consumer Stream');
is($state->{selected_alpn}, 'h2',
    'TLS handshake and ALPN complete before transition');
ok($state->{paused_before_transition},
    'source read side is paused before transition');
ok($state->{deferred_ran},
    'transition runs from Loop defer');
is($state->{after_class}, 'T::TLSOrdinaryRawTarget',
    'same live Stream changes to ordinary raw target');
is($state->{after_transport}, 'tls',
    'TLS transport remains active across transition');
is($state->{after_id}, $state->{before_id},
    'Stream object identity is retained');
is($state->{after_fd}, $state->{before_fd},
    'Stream fd identity is retained');
ok($state->{resumed_after_transition},
    'read side resumes after transition');
is($state->{error}, '',
    'transition and resumed TLS input report no error');
like($state->{bytes}, qr/early-input\n/,
    'decrypted plaintext pending at transition reaches the raw target');
like($state->{bytes}, qr/after-transition\n/,
    'raw target receives input written after transition');
is(
    Linux::Event::_ByteStream::ExternalTestConsumer::input_count(),
    $input_before,
    'retired native consumer receives no application input',
);
is(
    Linux::Event::_ByteStream::ExternalTestConsumer::destroy_count(),
    $destroyed_before + 1,
    'retired native-consumer context is destroyed exactly once',
);

$client->write("later-input\n");
$loop->run_for(0.05);
like($state->{bytes}, qr/later-input\n\z/,
    'ordinary raw target continues receiving later TLS input');

$client->close if !$client->is_closed;
$state->{accepted}->close
    if $state->{accepted} && !$state->{accepted}->is_closed;
$listener->close;

done_testing;
