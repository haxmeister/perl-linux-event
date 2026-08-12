# XS Roadmap

The generic reactor is now considered performance-stable. Future XS work should
move **mechanical event and byte-stream work** below Perl while leaving
**application decisions** in Perl.

Guiding rule:

> Perl should receive semantic events; XS should absorb repetitive mechanical
> events whenever doing so preserves a clean, general API.

## Priority 1 - Native Stream input path

Planned:

- drain readable sockets in XS until EAGAIN
- reusable native input buffer per stream
- avoid repeated temporary Perl scalars for every kernel read
- expose completed data to Perl only when the Stream API needs to notify user
  code

Target path:

```text
epoll -> XS watcher -> XS read -> native buffer -> Perl Stream callback
```

## Priority 2 - Native write queue and backpressure

Planned:

- attempt immediate writes in XS
- retain unwritten remainder without Perl `substr`/offset bookkeeping
- handle partial writes
- enable EPOLLOUT only while output is blocked
- drain the queue on writable readiness
- disable EPOLLOUT automatically when the queue becomes empty
- expose queue size/high-water information for application backpressure policy

## Priority 3 - Native framing/codecs

Move byte-oriented scanning/parsing out of repeated Perl string operations.
Initial candidates correspond to the existing Stream codec ideas:

- line delimiter scanning
- netstring framing
- U32BE length-prefixed frames

The native layer should detect complete frames; Perl should receive complete
application units rather than raw readiness notifications.

## Priority 4 - Callback coalescing/batching

Investigate delivering useful work with fewer Perl entries:

- drain multiple reads before notifying Perl
- optionally deliver multiple complete frames together
- preserve a simple one-message callback API as the normal interface
- make batching explicit/optional where it changes application semantics

## Priority 5 - Native Stream watcher-state transitions

Once Stream owns its native read/write state, changes such as enabling writable
interest, suspending reads for backpressure, closing, and half-closing should
happen directly against the native watcher rather than bouncing through Perl
methods.

## Priority 6 - Native listener accept drain

For high connection churn:

- drain `accept4()` until EAGAIN
- request `SOCK_NONBLOCK | SOCK_CLOEXEC` at accept time
- create/register the native connection watcher efficiently
- enter Perl for accepted-connection semantics, not for every mechanical setup
  step

This does not affect the preconnected reactor benchmark, but matters for real
server workloads.

## Priority 7 - Native connect completion

Move the nonblocking connect state machine below Perl:

- handle EINPROGRESS
- wait for writable readiness
- check `SO_ERROR`
- transition watcher interest
- cancel connection timeout state
- notify Perl once with success or failure

## Priority 8 - Linux fd drain helpers

Profile before implementing, but likely candidates include native draining and
aggregation for:

- eventfd wakeups
- signalfd records/counts
- pidfd completion state

Perl should receive the meaningful aggregate result rather than participate in
every low-level read.

## Priority 9 - Buffer representation experiments

Only after the basic Stream path is working and benchmarked:

- sliding native buffer with head/tail offsets
- ring-buffer alternatives
- allocation reuse/slabs if profiling justifies them

Do not optimize memory allocation speculatively. Earlier watcher-reclaim work
showed that reducing memory can easily cost throughput.

## Priority 10 - Protocol acceleration above Stream

After a stable Stream API exists, protocol-specific native parsing can be
considered where it offers a clear reusable benefit. A likely future candidate
is WebSocket frame parsing, relevant to the long-term Discord client/bot goal.
Application protocol logic should remain Perl.

## Benchmark plan for Stream work

Keep the existing reactor comparison unchanged as the low-level regression
standard. Add a separate stream/runtime suite comparing equivalent high-level
abstractions, for example:

- Linux::Event::Stream
- AnyEvent::Handle
- IO::Async::Stream
- Mojo stream APIs
- Node.js `net.Socket` / native Buffer path where the workload can be made fair

This separation prevents native Stream I/O from being mistaken for a generic
reactor advantage.
