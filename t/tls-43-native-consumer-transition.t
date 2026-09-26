use v5.36;
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::Loop;
use Linux::Event::_ByteStream ();
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Framer ();
use Linux::Event::TLS;

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
            $state->{resumed_after_transition} =
                $stream->is_read_paused ? 0 : 1;
            $state->{server}->write("after-transition\n");
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
    package T::TLSTransitionPeer;
    use parent 'Linux::Event::IO::Sock::Stream';

    sub on_data ($stream, $bytes) { return }

    sub on_error ($stream, $error) {
        $stream->data->{error} = "$error";
        $stream->loop->stop;
    }
}

socketpair(my $client_fh, my $server_fh,
    AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

my $loop = Linux::Event::Loop->new;
my $state = {
    bytes => '',
    error => '',
};
my $cert = "$Bin/tls-certs/server-cert.pem";
my $key = "$Bin/tls-certs/server-key.pem";
my $destroyed_before =
    Linux::Event::_ByteStream::TestSupport->_test_consumer_destroy_count;

my $server = T::TLSTransitionPeer->new(
    loop => $loop,
    fh => $server_fh,
    data => $state,
    transport => Linux::Event::TLS->server(
        cert_file => $cert,
        key_file => $key,
        alpn => ['h2', 'http/1.1'],
    ),
);
my $client = T::TLSNativeConsumerSource->new(
    loop => $loop,
    fh => $client_fh,
    data => $state,
    transport => Linux::Event::TLS->client(
        server_name => 'localhost',
        ca_file => $cert,
        alpn => ['h2', 'http/1.1'],
    ),
);
$state->{server} = $server;

my $client_identity = refaddr($client);
my $client_fd = $client->read_fd;
my $xs_state = $client->{xs_state};
$xs_state->_test_consumer_arm(sub {
    $state->{retired_consumer_called}++;
});

my $ok = eval {
    $loop->run_for(2);
    1;
};
ok($ok,
    'TLS native-consumer to ordinary raw transition does not crash')
    or diag $@;
ok($state->{source_transport_ready},
    'TLS transport-ready callback fires before application readiness');
ok($state->{source_ready},
    'TLS application on_ready schedules the transition');
is($state->{selected_alpn}, 'h2',
    'TLS ALPN selects h2 before transition');
ok($state->{paused_before_transition},
    'source read side is paused before deferred transition');
ok($state->{deferred_ran},
    'transition runs from Loop defer rather than TLS callback stack');
is($state->{class_after_transition}, 'T::TLSOrdinaryRawTarget',
    'same live Stream changes to ordinary raw target class');
is($state->{transport_after_transition}, 'tls',
    'transition retains TLS transport');
is($state->{fd_after_transition}, $client_fd,
    'transition retains the same readable fd');
is(refaddr($client), $client_identity,
    'transition retains the same Stream object');
ok($state->{resumed_after_transition},
    'read side resumes after transition');
is($state->{error}, '',
    'transition and later TLS input report no Stream error');
is($state->{bytes}, "after-transition\n",
    'ordinary raw target receives later decrypted input');
is($state->{retired_consumer_called} // 0, 0,
    'later input is not delivered to retired native consumer');
is(
    Linux::Event::_ByteStream::TestSupport->_test_consumer_destroy_count,
    $destroyed_before + 1,
    'retired native-consumer context is destroyed exactly once',
);

$server->write("later-input\n");
$loop->run_for(0.05);
is($state->{bytes}, "after-transition\nlater-input\n",
    'ordinary raw target continues receiving later TLS input');

$client->close;
$server->close;

done_testing;
