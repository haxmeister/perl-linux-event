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

our ($LOOP, $STATE);

{
    package T::TLSNativeConsumerSource;
    use parent 'Linux::Event::IO::Sock::Stream';

    BEGIN {
        Linux::Event::Framer->declare_native_consumer(
            __PACKAGE__,
            Linux::Event::_ByteStream::TestSupport->_test_consumer_definition(
                'raw-active-stream-ref',
            ),
        );
    }

    sub on_transport_ready ($stream) {
        $stream->data->{source_transport_ready} = 1;
    }

    sub on_ready ($stream) {
        my $state = $stream->data;
        return if $state->{transition_scheduled}++;

        $state->{source_ready} = 1;
        $state->{selected_alpn} = $stream->selected_alpn;
        $stream->pause_read;
        $state->{paused_before_transition} = $stream->is_read_paused ? 1 : 0;

        $state->{deferred} = $stream->loop->defer(sub {
            $state->{deferred_ran} = 1;
            $stream->transition_to('T::TLSOrdinaryRawTarget');
            $state->{class_after_transition} = ref($stream);
            $state->{transport_after_transition} = $stream->transport_name;
            $state->{fd_after_transition} = $stream->read_fd;
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

{
    package T::TLSTransitionClient;
    use parent 'Linux::Event::IO::Sock::Stream';
    use Linux::Event::TLS
        ca_file => "$FindBin::Bin/tls-certs/server-cert.pem",
        alpn    => ['h2', 'http/1.1'];

    sub on_ready ($stream) { return }

    sub on_data ($stream, $bytes) { return }

    sub on_error ($stream, $error) {
        $stream->data->{error} = "$error";
        $stream->loop->stop;
    }
}

{
    package T::TLSNativeConsumerListener;
    use parent 'Linux::Event::IO::Sock::Listener';

    sub on_accept ($listener, $stream) {
        my $state = $stream->data;
        $state->{accepted} = $stream;
        $state->{source_identity} = Scalar::Util::refaddr($stream);
        $state->{source_fd} = $stream->read_fd;
        $state->{consumer_active_before_ready}
            = $stream->{xs_state}->consumer_paused ? 0 : 1;
    }

    sub on_error ($listener, $error) {
        $main::STATE->{error} = "$error";
        $listener->loop->stop;
    }
}


{
    package T::TLSDuplexExecutor;

    sub new ($class, %arg) {
        return bless \%arg, $class;
    }

    sub input ($self, $bytes) {
        my $state = $self->{state};
        if ($self->{role} eq 'server') {
            $state->{duplex_server_input} .= $bytes;
            if ($state->{duplex_server_input} =~ /ping\n/) {
                $self->{stream}->write("pong\n");
            }
        } else {
            $state->{duplex_client_input} .= $bytes;
            if ($state->{duplex_client_input} =~ /pong\n/) {
                $state->{duplex_complete} = 1;
                $self->{stream}->loop->stop;
            }
        }
        return;
    }
}

{
    package T::TLSDuplexServerSource;
    use parent 'Linux::Event::IO::Sock::Stream';

    BEGIN {
        Linux::Event::Framer->declare_native_consumer(
            __PACKAGE__,
            Linux::Event::_ByteStream::TestSupport->_test_consumer_definition(
                'raw-active-stream-ref',
            ),
        );
    }

    sub on_ready ($stream) {
        my $state = $stream->data;
        $state->{duplex_server_alpn} = $stream->selected_alpn;
        $stream->pause_read;
        $stream->loop->defer(sub {
            my $executor = T::TLSDuplexExecutor->new(
                role => 'server', state => $state, stream => $stream,
            );
            $stream->{duplex_executor} = $executor;
            $stream->transition_to('T::TLSDuplexServerTarget');
            $state->{duplex_server_class} = ref($stream);
            $state->{duplex_server_transport} = $stream->transport_name;
            $stream->resume_read;
        });
    }

    sub on_error ($stream, $error) {
        $stream->data->{duplex_error} = "$error";
        $stream->loop->stop;
    }
}

{
    package T::TLSDuplexClientSource;
    use parent 'Linux::Event::IO::Sock::Stream';

    BEGIN {
        Linux::Event::Framer->declare_native_consumer(
            __PACKAGE__,
            Linux::Event::_ByteStream::TestSupport->_test_consumer_definition(
                'raw-active-stream-ref',
            ),
        );
    }

    sub on_ready ($stream) {
        my $state = $stream->data;
        $state->{duplex_client_alpn} = $stream->selected_alpn;
        $stream->pause_read;
        $stream->loop->defer(sub {
            my $executor = T::TLSDuplexExecutor->new(
                role => 'client', state => $state, stream => $stream,
            );
            $stream->{duplex_executor} = $executor;
            $stream->transition_to('T::TLSDuplexClientTarget');
            $state->{duplex_client_class} = ref($stream);
            $state->{duplex_client_transport} = $stream->transport_name;
            $stream->resume_read;
            $stream->write("ping\n");
        });
    }

    sub on_error ($stream, $error) {
        $stream->data->{duplex_error} = "$error";
        $stream->loop->stop;
    }
}

{
    package T::TLSDuplexServerTarget;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) {
        $stream->{duplex_executor}->input($bytes);
    }

    sub on_error ($stream, $error) {
        $stream->data->{duplex_error} = "$error";
        $stream->loop->stop;
    }
}

{
    package T::TLSDuplexClientTarget;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) {
        $stream->{duplex_executor}->input($bytes);
    }

    sub on_error ($stream, $error) {
        $stream->data->{duplex_error} = "$error";
        $stream->loop->stop;
    }
}

{
    package T::TLSDuplexListener;
    use parent 'Linux::Event::IO::Sock::Listener';

    sub on_accept ($listener, $stream) {
        $stream->data->{duplex_server} = $stream;
    }

    sub on_error ($listener, $error) {
        $main::STATE->{duplex_error} = "$error";
        $listener->loop->stop;
    }
}

$LOOP = Linux::Event::Loop->new;
$STATE = {
    bytes => '',
    error => '',
};

my $destroyed_before =
    Linux::Event::_ByteStream::TestSupport->_test_consumer_destroy_count;

my $listener = $LOOP->add(T::TLSNativeConsumerListener->new(
    host => '127.0.0.1',
    port => 0,
    stream => {
        class => 'T::TLSNativeConsumerSource',
        data => $STATE,
        tls => {
            cert_file => "$Bin/tls-certs/server-cert.pem",
            key_file => "$Bin/tls-certs/server-key.pem",
            alpn => ['h2', 'http/1.1'],
        },
    },
));

my $client = T::TLSTransitionClient->connect(
    host => 'localhost',
    port => $listener->port,
    timeout => 5,
    data => $STATE,
);
$STATE->{client} = $client;
$client->write("early-input\n");
$LOOP->add($client);

my $ok = eval {
    $LOOP->run_for(5);
    1;
};
ok($ok,
    'accepted TLS native-consumer may transition to ordinary raw Stream')
    or diag $@;
ok($STATE->{accepted},
    'Listener accepted the native-consumer Stream');
ok($STATE->{consumer_active_before_ready},
    'source native consumer is active before TLS readiness');
ok($STATE->{source_transport_ready},
    'TLS transport-ready callback fires before application readiness');
ok($STATE->{source_ready},
    'accepted TLS Stream on_ready schedules the transition');
is($STATE->{selected_alpn}, 'h2',
    'server-side TLS ALPN selects h2 before transition');
ok($STATE->{paused_before_transition},
    'source read side is paused before deferred transition');
ok($STATE->{deferred_ran},
    'transition runs from Loop defer rather than TLS callback stack');
is($STATE->{class_after_transition}, 'T::TLSOrdinaryRawTarget',
    'same live accepted Stream changes to ordinary raw target class');
is($STATE->{transport_after_transition}, 'tls',
    'transition retains TLS transport');
is($STATE->{fd_after_transition}, $STATE->{source_fd},
    'transition retains the same readable fd');
is(refaddr($STATE->{accepted}), $STATE->{source_identity},
    'transition retains the same Stream object');
ok($STATE->{resumed_after_transition},
    'read side resumes after transition');
is($STATE->{error}, '',
    'transition and later TLS input report no Stream error');
like($STATE->{bytes}, qr/early-input\n/,
    'ordinary raw target receives plaintext queued before TLS readiness');
like($STATE->{bytes}, qr/after-transition\n/,
    'ordinary raw target receives input written after transition');
is($STATE->{retired_consumer_called} // 0, 0,
    'later input is not delivered to retired native consumer');
is(
    Linux::Event::_ByteStream::TestSupport->_test_consumer_destroy_count,
    $destroyed_before + 1,
    'retired native-consumer context is destroyed exactly once',
);

$client->write("later-input\n");
$LOOP->run_for(0.05);
like($STATE->{bytes}, qr/later-input\n\z/,
    'ordinary raw target continues receiving later TLS input');


$client->close;
$STATE->{accepted}->close if !$STATE->{accepted}->is_closed;
$listener->close;

{
    my $loop = Linux::Event::Loop->new;
    my $state = {
        duplex_error => '',
        duplex_server_input => '',
        duplex_client_input => '',
    };

    my $duplex_listener = $loop->add(T::TLSDuplexListener->new(
        host => '127.0.0.1',
        port => 0,
        stream => {
            class => 'T::TLSDuplexServerSource',
            data => $state,
            tls => {
                cert_file => "$Bin/tls-certs/server-cert.pem",
                key_file => "$Bin/tls-certs/server-key.pem",
                alpn => ['h2', 'http/1.1'],
            },
        },
    ));

    my $duplex_client = T::TLSDuplexClientSource->connect(
        loop => $loop,
        host => 'localhost',
        port => $duplex_listener->port,
        timeout => 5,
        data => $state,
        transport => Linux::Event::TLS->client(
            server_name => 'localhost',
            ca_file => "$Bin/tls-certs/server-cert.pem",
            alpn => ['h2', 'http/1.1'],
        ),
    );
    $loop->add($duplex_client);

    my $ok = eval {
        $loop->run_for(5);
        1;
    };
    ok($ok,
        'both TLS native consumers may retire and exchange target raw data')
        or diag $@;
    is($state->{duplex_error}, '',
        'duplex transition path reports no transport error');
    is($state->{duplex_client_alpn}, 'h2',
        'duplex client selects h2 before transition');
    is($state->{duplex_server_alpn}, 'h2',
        'duplex server selects h2 before transition');
    is($state->{duplex_client_class}, 'T::TLSDuplexClientTarget',
        'duplex client changes to ordinary raw target');
    is($state->{duplex_server_class}, 'T::TLSDuplexServerTarget',
        'duplex server changes to ordinary raw target');
    is($state->{duplex_client_transport}, 'tls',
        'duplex client retains TLS transport');
    is($state->{duplex_server_transport}, 'tls',
        'duplex server retains TLS transport');
    like($state->{duplex_server_input}, qr/ping\n/,
        'duplex server target receives post-transition plaintext');
    like($state->{duplex_client_input}, qr/pong\n/,
        'duplex client target receives post-transition plaintext reply');
    ok($state->{duplex_complete},
        'post-transition TLS raw exchange completes');

    $duplex_client->close if !$duplex_client->is_closed;
    if (my $server = $state->{duplex_server}) {
        $server->close if !$server->is_closed;
    }
    $duplex_listener->close;
}

done_testing;
