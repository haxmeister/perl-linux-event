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
                'raw-input',
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

    sub on_ready ($stream) {
        $stream->write("early-input\n");
    }

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
        $stream->{xs_state}->_test_consumer_arm(sub {
            $state->{retired_consumer_called}++;
        });
    }

    sub on_error ($listener, $error) {
        $main::STATE->{error} = "$error";
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
    'ordinary raw target receives plaintext sent at TLS readiness');
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

done_testing;
