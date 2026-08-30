use v5.36;
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::Loop;
use Linux::Event::Stream;
use Linux::Event::TLS;

is(Linux::Event::Stream->_native_consumer_abi_version, 1,
    'native consumer ABI v1 is discoverable');

{
    package T::ConsumerBase;
    use parent 'Linux::Event::Stream';
    BEGIN {
        Linux::Event::Stream->_declare_consumer(
            __PACKAGE__, Linux::Event::Stream->_test_consumer_definition,
        );
    }
    sub on_error ($stream, $error) { $stream->data->{error} = $error }
    sub on_eof ($stream) { $stream->data->{eof}++ }
}

{
    package T::ConsumerLine;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'Delimiter', "\n";
}

{
    package T::ConsumerShortLine;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'Delimiter', "\n", max_frame => 3;
}

{
    package T::ConsumerFixed;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'Fixed', size => 3;
}

{
    package T::ConsumerLength;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'LengthPrefix', bytes => 1;
}

{
    package T::ConsumerU32BE;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'U32BE';
}

{
    package T::ConsumerNetstring;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'Netstring';
}

{
    package T::ConsumerVarint;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'Varint';
}

{
    package T::ConsumerDecimal;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'DecimalLength', separator => ' ';
}

{
    package T::CallbackLine;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";
    sub on_message ($stream, $message) { return }
}

{
    package T::BadConsumerMessage;
    use parent -norequire, 'T::ConsumerBase';
    use Linux::Event::Framer 'Delimiter', "\n";
    sub on_message ($stream, $message) { return }
}

{
    package T::BudgetRaw;
    use parent 'Linux::Event::Stream';
    sub stream_options ($class) {
        return read_size => 4, read_budget_bytes => 4;
    }
    sub on_data ($stream, $bytes) {
        $stream->data->{bytes} .= $bytes;
        $stream->data->{loop}->stop
            if length($stream->data->{bytes}) == 12;
    }
}

{
    package T::ConsumerTLSSender;
    use parent 'Linux::Event::Stream';
    sub on_transport_ready ($stream) { $stream->write("secure\n") }
    sub on_data ($stream, $bytes) { return }
    sub on_error ($stream, $error) {
        $stream->data->{tls_error} = "$error";
        $stream->loop->stop;
    }
}

sub pair ($class, $data = {}) {
    socketpair(my $stream_fh, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    my $loop = Linux::Event::Loop->new;
    $data->{loop} = $loop;
    my $stream = $class->new(loop => $loop, fh => $stream_fh, data => $data);
    return ($loop, $stream, $peer, $stream->{xs_state});
}

sub arm ($stream, $callback = undef) {
    $stream->{xs_state}->_test_consumer_arm($callback);
    return;
}

sub cancel_arm ($stream) {
    $stream->{xs_state}->_test_consumer_cancel;
    return;
}

sub take ($stream) {
    return $stream->{xs_state}->_test_consumer_take;
}

{
    my ($loop, $stream, $peer) = pair('T::ConsumerLine');
    ok($stream->{xs_state}->consumer_paused,
        'pull consumer begins paused');
    syswrite($peer, "one\ntwo\n");
    $loop->run_for(0.01);
    is($stream->{xs_state}->stats->{consumer_message_calls}, 0,
        'paused consumer does not read eagerly');

    arm($stream, sub { $loop->stop });
    $loop->run;
    is(take($stream), 'one', 'first armed receive gets first native frame');
    ok($stream->{xs_state}->consumer_paused,
        'consumer pauses after one receive');

    my $immediate = 0;
    arm($stream, sub { $immediate++ });
    is($immediate, 1,
        'arming dispatches an already-buffered complete frame immediately');
    is(take($stream), 'two', 'buffered frame order is preserved');
    my $stats = $stream->{xs_state}->stats;
    is($stats->{consumer_message_calls}, 2,
        'consumer message instrumentation counts direct deliveries');
    is($stats->{consumer_pause_count}, 2,
        'consumer pause instrumentation counts idle boundaries');
    cmp_ok($stats->{consumer_resume_count}, '>=', 2,
        'consumer resume instrumentation counts receive arms');
    is($stats->{message_callback_calls}, 0,
        'direct consumer bypasses public on_message callback');
    $stream->close;
    close $peer;
}

{
    my ($loop, $stream, $peer) = pair('T::ConsumerLine');
    arm($stream);
    ok(!$stream->{xs_state}->consumer_paused,
        'arming clears native consumer pause');
    cancel_arm($stream);
    ok($stream->{xs_state}->consumer_paused,
        'provider can pause an armed receive before delivery');
    syswrite($peer, "preserved\n");
    $loop->run_for(0.01);
    is($stream->{xs_state}->stats->{consumer_message_calls}, 0,
        'cancel-shaped pause does not consume one extra message');
    arm($stream, sub { $loop->stop });
    $loop->run;
    is(take($stream), 'preserved',
        'input remains available after provider pause and rearm');
    $stream->close;
    close $peer;
}

{
    my ($loop, $stream, $peer) = pair('T::ConsumerLine');
    my @got;
    my $ready;
    $ready = sub {
        push @got, take($stream);
        if (@got < 3) {
            arm($stream, $ready);
        } else {
            $loop->stop;
        }
    };
    arm($stream, $ready);
    syswrite($peer, "a\nb\nc\n");
    $loop->run;
    is_deeply(\@got, [qw(a b c)],
        'consumer supports reentrant next-receive arming');
    is($stream->{xs_state}->stats->{consumer_pause_count}, 1,
        'reentrant receive loop pauses only after its final message');
    $stream->close;
    close $peer;
}

{
    my ($loop, $stream, $peer, $xs) = pair('T::ConsumerLine');
    arm($stream, sub { $loop->stop });
    close $peer;
    $loop->run;
    is_deeply($xs->_test_consumer_events, [[1, 0, '']],
        'clean EOF reaches native consumer before Stream EOF handling');
    is($stream->data->{eof}, 1, 'ordinary Stream EOF semantics remain active');
    $stream->close;
}

{
    my $data = {};
    my ($loop, $stream, $peer, $xs) = pair('T::ConsumerShortLine', $data);
    arm($stream, sub { $loop->stop });
    syswrite($peer, "toolong\n");
    $loop->run;
    is($xs->_test_consumer_events->[0][0], 3,
        'framing failure reaches native consumer');
    like($xs->_test_consumer_events->[0][2], qr/exceeds max_frame/,
        'framing failure includes diagnostic text');
    isa_ok($data->{error}, 'Linux::Event::Error');
    is($data->{error}->type, 'framing',
        'ordinary typed Stream framing error remains active');
    ok($stream->is_closed, 'framing failure closes Stream normally');
    close $peer;
}

for my $case (
    ['Fixed', 'T::ConsumerFixed', 'aaabbbccc', [qw(aaa bbb ccc)]],
    ['LengthPrefix', 'T::ConsumerLength',
        join('', map { "\x02$_" } qw(aa bb cc)), [qw(aa bb cc)]],
    ['U32BE', 'T::ConsumerU32BE',
        join('', map { pack('N', 2) . $_ } qw(aa bb cc)), [qw(aa bb cc)]],
    ['Netstring', 'T::ConsumerNetstring',
        join('', map { "2:$_," } qw(aa bb cc)), [qw(aa bb cc)]],
    ['Varint', 'T::ConsumerVarint',
        join('', map { "\x02$_" } qw(aa bb cc)), [qw(aa bb cc)]],
    ['DecimalLength', 'T::ConsumerDecimal',
        join('', map { "2 $_" } qw(aa bb cc)), [qw(aa bb cc)]],
) {
    my ($name, $class, $wire, $expected) = @$case;
    subtest "$name consumer pause boundary" => sub {
        my ($loop, $stream, $peer) = pair($class);
        my @got;
        my $ready;
        $ready = sub {
            push @got, take($stream);
            if (@got < 3) {
                arm($stream, $ready);
            } else {
                $loop->stop;
            }
        };
        arm($stream, $ready);
        syswrite($peer, $wire) == length($wire)
            or die "short $name fixture write: $!";
        $loop->run;
        is_deeply(\@got, $expected,
            "$name preserves frames through reentrant consumer rearming");
        is($stream->{xs_state}->stats->{consumer_message_calls}, 3,
            "$name delivers each frame directly to the consumer");
        $stream->close;
        close $peer;
    };
}

{
    my $before = Linux::Event::Stream->_test_consumer_destroy_count;
    my ($loop, $stream, $peer, $xs) = pair('T::ConsumerLine');
    arm($stream);
    $stream->close;
    is($xs->_test_consumer_events->[0][0], 4,
        'explicit close reaches native consumer');
    undef $stream;
    undef $xs;
    cmp_ok(Linux::Event::Stream->_test_consumer_destroy_count, '>', $before,
        'provider-owned context is destroyed with native Stream state');
    close $peer;
}

{
    my ($loop, $stream, $peer, $xs) = pair('T::ConsumerLine');
    my $detached = $stream->detach;
    is($xs->_test_consumer_events->[0][0], 5,
        'detach is distinguished from explicit close');
    close $detached;
    close $peer;
}

{
    my ($loop, $stream, $peer, $xs) = pair('T::ConsumerLine');
    my $context_identity = refaddr($xs);
    $stream->transition_to('T::ConsumerFixed');
    is(refaddr($stream->{xs_state}), $context_identity,
        'transition between classes sharing a consumer retains native state');
    arm($stream, sub { $loop->stop });
    syswrite($peer, 'abc');
    $loop->run;
    is(take($stream), 'abc',
        'retained consumer uses target native framer after transition');

    my $ok = eval { $stream->transition_to('T::CallbackLine'); 1 };
    ok(!$ok, 'transition cannot remove a live native consumer');
    like($@, qr/cannot change native consumer provider/,
        'consumer-changing transition reports the ABI boundary');
    $stream->close;
    close $peer;
}

{
    my ($loop, $stream, $peer) = pair('T::BudgetRaw', { bytes => '' });
    syswrite($peer, 'abcdefghijkl');
    $loop->run;
    is($stream->data->{bytes}, 'abcdefghijkl',
        'bounded read budget preserves raw callback bytes');
    my $stats = $stream->{xs_state}->stats;
    is($stats->{read_budget_bytes}, 4,
        'read budget is visible in Stream statistics');
    cmp_ok($stats->{read_ready_calls}, '>=', 3,
        'one-read budget yields between successful reads');
    $stream->close;
    close $peer;
}

{
    socketpair(my $client_fh, my $server_fh,
        AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    my $loop = Linux::Event::Loop->new;
    my $data = {};
    my $cert = "$Bin/tls-certs/server-cert.pem";
    my $key = "$Bin/tls-certs/server-key.pem";
    my $server = T::ConsumerTLSSender->new(
        loop => $loop, fh => $server_fh, data => $data,
        transport => Linux::Event::TLS->server(
            cert_file => $cert, key_file => $key,
        ),
    );
    my $client = T::ConsumerLine->new(
        loop => $loop, fh => $client_fh, data => $data,
        transport => Linux::Event::TLS->client(
            server_name => 'localhost', ca_file => $cert,
        ),
    );

    $loop->run_for(0.05);
    ok($client->is_transport_ready,
        'TLS handshake progresses while native consumer is paused');
    ok($client->{xs_state}->consumer_paused,
        'TLS readiness does not consume application data while unarmed');
    arm($client, sub { $loop->stop });
    $loop->run_for(2);
    is(take($client), 'secure',
        'armed native consumer receives framed TLS application data');
    is($data->{tls_error}, undef, 'native consumer TLS path has no error');
    $client->close;
    $server->close;
}

{
    my $ok = eval {
        my ($loop, $stream, $peer) = pair('T::BadConsumerMessage');
        1;
    };
    ok(!$ok, 'native consumer cannot be combined with on_message');
    like($@, qr/cannot be combined with on_message/,
        'callback/consumer exclusivity is explicit');
}

for my $case (
    ['wrong-declaration-version', qr/consumer ABI version mismatch/],
    ['wrong-table-version', qr/incompatible ABI version/],
    ['unknown-flags', qr/unsupported flags/],
    ['incomplete', qr/operations table is incomplete/],
    ['create-failure', qr/failed to create per-Stream context/],
) {
    my ($variant, $error) = @$case;
    my $base = "T::InvalidConsumer::$variant";
    my $class = "${base}::Line";
    no strict 'refs';
    @{"${base}::ISA"} = ('Linux::Event::Stream');
    Linux::Event::Stream->_declare_consumer(
        $base, Linux::Event::Stream->_test_consumer_definition($variant),
    );
    @{"${class}::ISA"} = ($base);
    Linux::Event::Stream->_declare_framer(
        $class, {
            native => {
                read_mode => 2,
                delimiter => "\n",
            },
            frame => sub ($native, $payload) { return "$payload\n" },
        },
    );
    my $ok = eval {
        socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
            or die "socketpair: $!";
        my $loop = Linux::Event::Loop->new;
        $class->new(loop => $loop, fh => $a);
        close $b;
        1;
    };
    ok(!$ok, "$variant consumer declaration is rejected");
    like($@, $error, "$variant reports a stable ABI diagnostic");
}

done_testing;
