# Future-first contract

This branch tests a Future-first public model without moving framing, TLS, or
stream tuning out of core. The experiment starts with one complete vertical
slice rather than converting every resource at once.

## Syntax and completion values

`use Linux::Event` lexically enables `async` and `await` through
`Future::AsyncAwait` and selects `Linux::Event::Future` as the future class.
Application files do not also need `use Future::AsyncAwait`.

`Linux::Event::Future` implements the
`Future::AsyncAwait::Awaitable` interface. Its readiness state, result list,
failure, cancellation callbacks, readiness callbacks, and cancellation chains
are native. `Future::AsyncAwait` supplies the suspended Perl coroutine state
machine in XS.

The common one-result and one-readiness-continuation cases occupy inline
native slots. Stream uses a private versioned C API table to construct, query,
and complete these Futures without dynamically invoking their Perl methods.

Every pending Linux::Event Future is associated with at most one Loop. Cloning
an awaitable while an `async sub` suspends preserves that association.

## Root driver

`$loop->run($future)` dispatches epoll readiness until the Future is ready,
then returns its results or throws its failure in the caller's context. A
Future associated with another Loop is rejected. Calling `$loop->run` without
an argument retains the callback control path during this experiment.

Top-level `await` delegates to the associated Loop through `AWAIT_WAIT`.
Already-ready Futures need no Loop.

## Framed Stream receive

A framed Stream subclass may omit `on_message` and use:

```perl
package LineStream;
use parent 'Linux::Event::Stream';
use Linux::Event::Framer 'Delimiter', "\n";

package main;
use Linux::Event;

async sub read_request ($stream) {
    my $line = await $stream->recv;
    return undef if !defined $line;
    return $line;
}
```

`recv` permits one pending receiver per Stream. It resolves with the next
decoded message, resolves with `undef` at clean EOF, and fails with the
Stream's structured error on failure or explicit close. Complete messages
that arrive without a pending receiver remain ordered in native Stream state.
Cancellation releases the receiver slot without consuming the next message.

The native parser finishes the frames already present in its current input
batch before it wakes one pending receiver. The resumed coroutine consumes the
remaining queued frames through already-ready Futures instead of repeatedly
suspending and re-entering the parser once per frame. This changes scheduling,
not wire order: the first waiter still receives the first decoded message.

Callback delivery and `recv` are mutually exclusive for one Stream class.
The existing `on_message` and `on_messages` paths remain available as controls
for correctness and performance comparisons during the branch experiment.
Raw byte reads and batched Future receives are not part of this first slice.

`bench/run-future-recv-microbench.pl` compares the retained `on_message` path
with serial `await recv` while holding the AF_UNIX transport, payload, native
delimiter parser, and write path constant. The ratio is a diagnostic for this
experiment, not yet a release threshold.

## Native boundaries retained

Built-in framing still parses in the existing XS/C implementations. The
Future receive path changes only the delivery target after a complete message
has been decoded. Socket options, watermarks, output limits, native write
queues, protocol transitions, TLS transport operations, and instrumentation
retain their existing implementation boundaries.

## Next contract candidates

The next slices should settle the semantics of Future-returning `connect`,
`send`/`drain`, graceful close, Listener acceptance, timers, cancellation,
and bounded receive-queue backpressure before callback APIs are considered for
removal.
