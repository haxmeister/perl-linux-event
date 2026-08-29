use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);

use Linux::Event::Future;
use Linux::Event::Loop;

my $loop = Linux::Event::Loop->new;
my $future = Linux::Event::Future->new($loop);
isa_ok($future, 'Linux::Event::Future');
is($future->loop, $loop, 'pending Future retains its Loop');
ok(!$future->is_ready, 'new Future is pending');
ok(!$future->is_cancelled, 'new Future is not cancelled');

my $ready_calls = 0;
is($future->on_ready(sub { $ready_calls++ }), $future,
    'on_ready returns the same Future');
is($ready_calls, 0, 'on_ready waits for completion');
is($future->done('first', 'second'), $future,
    'done returns the same Future');
is($ready_calls, 1, 'done invokes readiness callbacks');
ok($future->is_ready, 'done Future is ready');
is_deeply([$future->get], ['first', 'second'],
    'get preserves list results');
is(scalar $future->get, 'first', 'scalar get returns the first result');

$future->on_ready(sub { $ready_calls++ });
is($ready_calls, 2, 'on_ready runs immediately after completion');
my $second_done = eval { $future->done('again'); 1 };
ok(!$second_done, 'a Future has exactly one terminal transition');
like($@, qr/already ready/, 'duplicate completion reports its cause');

my $failure = bless { reason => 'test' }, 'T::FutureFailure';
my $failed = Linux::Event::Future->AWAIT_NEW_FAIL($failure);
ok($failed->is_ready, 'immediate failed Future is ready');
my $got = eval { $failed->get; undef };
is($got, undef, 'failed get does not return');
is(refaddr($@), refaddr($failure), 'failed get throws the stored object');

my $prototype = Linux::Event::Future->new($loop);
my $clone = $prototype->AWAIT_CLONE;
isa_ok($clone, 'Linux::Event::Future');
is($clone->loop, $loop, 'AWAIT_CLONE preserves Loop association');
ok(!$clone->is_ready, 'AWAIT_CLONE creates independent pending state');

my $cancel_calls = 0;
my $cancelled = Linux::Event::Future->new;
my $chained = Linux::Event::Future->new;
$cancelled->on_cancel(sub { $cancel_calls++ });
$cancelled->AWAIT_CHAIN_CANCEL($chained);
is($cancelled->cancel, $cancelled, 'cancel returns the same Future');
ok($cancelled->is_ready, 'cancelled Future is ready');
ok($cancelled->is_cancelled, 'cancelled Future reports cancellation');
ok($chained->is_cancelled, 'cancellation propagates one way');
is($cancel_calls, 1, 'cancellation callback runs once');
$cancelled->cancel;
is($cancel_calls, 1, 'cancellation is idempotent');

my $immediate = Linux::Event::Future->AWAIT_NEW_DONE(123);
is($loop->run($immediate), 123,
    'Loop run returns an already-ready Future result');

my $other_loop = Linux::Event::Loop->new;
my $wrong_loop_future = Linux::Event::Future->new($loop);
my $wrong_loop = eval { $other_loop->run($wrong_loop_future); 1 };
ok(!$wrong_loop, 'Loop rejects a Future owned by another Loop');
like($@, qr/different Loop/, 'Loop mismatch is explicit');

my $callback_failure = Linux::Event::Future->new;
my @notification;
$callback_failure->on_ready(sub {
    push @notification, 'first';
    die "readiness callback failed\n";
});
$callback_failure->on_ready(sub { push @notification, 'second' });
my $notified = eval { $callback_failure->done('value'); 1 };
ok(!$notified, 'readiness callback failure propagates after notification');
like($@, qr/readiness callback failed/, 'callback failure is preserved');
is_deeply(\@notification, [qw(first second)],
    'one callback failure does not skip later readiness callbacks');
ok($callback_failure->is_ready,
    'callback failure does not roll back terminal Future state');

my $bad_loop = eval { Linux::Event::Future->new(bless {}, 'T::NotALoop'); 1 };
ok(!$bad_loop, 'Future rejects a non-Loop owner');
like($@, qr/must be a Linux::Event::Loop/, 'invalid Loop error is explicit');

done_testing;
