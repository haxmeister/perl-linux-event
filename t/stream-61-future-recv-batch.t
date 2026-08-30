use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event;
use Linux::Event::Loop;
use Linux::Event::Stream;

{
    package T::FutureBatchDelimitedStream;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', '|';

    sub stream_options ($class) {
        return (
            read_size         => 64,
            read_budget_bytes => 1_048_576,
        );
    }
}

{
    package T::FutureBudgetDelimitedStream;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', '|';

    sub stream_options ($class) {
        return (
            read_size         => 64,
            read_budget_bytes => 64,
        );
    }
}

sub stream_pair () {
    socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    my $loop = Linux::Event::Loop->new;
    my $stream = T::FutureBatchDelimitedStream->new(
        loop => $loop,
        fh   => $left,
    );
    return ($loop, $stream, $right);
}

subtest 'bounded batches preserve order and queue ownership' => sub {
    my ($loop, $stream, $peer) = stream_pair();

    my $batch = $stream->recv_batch(2);
    isa_ok($batch, 'Linux::Event::Future', 'recv_batch returns a Future');
    ok(!$batch->is_ready, 'recv_batch waits for input');
    syswrite($peer, 'one|two|three|');
    is_deeply($loop->run($batch), [qw(one two)],
        'pending batch returns at most its requested maximum');

    my $queued = $stream->recv_batch(8);
    ok($queued->is_ready, 'remaining decoded messages are already ready');
    is_deeply($loop->run($queued), ['three'],
        'remaining message stays ordered in the native queue');

    $stream->close;
    close $peer;
};

subtest 'native queue grows without losing order' => sub {
    my ($loop, $stream, $peer) = stream_pair();
    my @expected = map { "message-$_" } 0 .. 99;

    my $first = $stream->recv_batch(1);
    syswrite($peer, join('|', @expected) . '|');
    is_deeply($loop->run($first), [$expected[0]],
        'first batch consumes one message');

    my $rest = $stream->recv_batch(200);
    ok($rest->is_ready, 'native queue supplies the rest immediately');
    is_deeply($loop->run($rest), [@expected[1 .. $#expected]],
        'ring growth and wrap preserve all message order');

    $stream->close;
    close $peer;
};

subtest 'read budget ends a native drain after its byte limit' => sub {
    socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    my $loop = Linux::Event::Loop->new;
    my $stream = T::FutureBudgetDelimitedStream->new(
        loop => $loop,
        fh   => $left,
    );
    my @expected = map { sprintf 'm%02d', $_ } 0 .. 99;
    my $future = $stream->recv_batch(100);
    syswrite($right, join('|', @expected) . '|');

    my $got = $loop->run($future);
    ok(@$got > 0 && @$got < @expected,
        'one budgeted turn completes a partial batch');
    cmp_ok($stream->{xs_state}->stats->{bytes_read}, '<=', 64,
        'native bytes consumed in the turn do not exceed the budget');
    is($stream->{xs_state}->stats->{read_ready_calls}, 1,
        'budget returns control to the reactor after one read turn');

    my @all = @$got;
    while (@all < @expected) {
        my $more = $loop->run($stream->recv_batch(100));
        push @all, @$more;
    }
    is_deeply(\@all, \@expected,
        'one-shot rearming drains all remaining input in later turns');
    cmp_ok($stream->{xs_state}->stats->{read_ready_calls}, '>', 1,
        'budgeted input required multiple reactor turns');

    $stream->close;
    close $right;
};

subtest 'maximum validation rejects non-positive and fractional values' => sub {
    my ($loop, $stream, $peer) = stream_pair();

    for my $invalid (undef, 0, -1, 1.5, 'two') {
        my $accepted = eval { $stream->recv_batch($invalid); 1 };
        ok(!$accepted, 'invalid maximum is rejected');
        like($@, qr/maximum must be a positive integer/,
            'validation error identifies the maximum contract');
    }

    $stream->close;
    close $peer;
};

subtest 'cancellation does not discard a message arriving afterward' => sub {
    my ($loop, $stream, $peer) = stream_pair();

    my $cancelled = $stream->recv_batch(4);
    $cancelled->cancel;
    syswrite($peer, 'kept|');
    $loop->run_once(100);

    my $next = $stream->recv;
    ok($next->is_ready, 'cancelled batch leaves the next message queued');
    is($loop->run($next), 'kept', 'queued message is delivered exactly once');

    $stream->close;
    close $peer;
};

subtest 'recv and recv_batch share one active reader' => sub {
    my ($loop, $stream, $peer) = stream_pair();

    my $single = $stream->recv;
    my $batch_error = eval { $stream->recv_batch(2); 1 };
    ok(!$batch_error, 'recv_batch rejects a concurrent recv');
    like($@, qr/another receive is already pending/,
        'concurrent receive error is explicit');
    $single->cancel;

    my $batch = $stream->recv_batch(2);
    my $single_error = eval { $stream->recv; 1 };
    ok(!$single_error, 'recv rejects a concurrent recv_batch');
    like($@, qr/another receive is already pending/,
        'reverse concurrent receive error is explicit');
    $batch->cancel;

    $stream->close;
    close $peer;
};

subtest 'batch resolves undef at clean EOF' => sub {
    my ($loop, $stream, $peer) = stream_pair();
    my $eof = $stream->recv_batch(8);
    close $peer;
    is($loop->run($eof), undef, 'empty clean EOF resolves to undef');
    $stream->close;
};

done_testing;
