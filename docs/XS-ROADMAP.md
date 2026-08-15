# XS Roadmap

The generic reactor and the first native Stream engine are now implemented in
the same Linux::Event distribution. The guiding rule remains:

> Perl should receive semantic events; XS should absorb repetitive mechanical
> events whenever doing so preserves a clean, general API.

## Completed foundation

- XS-first epoll loop and native watcher registry
- direct native watcher dispatch
- native Stream readable draining
- reusable native framed-input storage
- native immediate writes and segmented `writev()` queue draining
- native backpressure byte accounting
- native Delimiter framing
- native Fixed framing
- native configurable LengthPrefix framing
- native U32BE framing
- native Netstring framing
- native Varint framing
- native DecimalLength framing
- one immutable callback/framer/transport descriptor per Stream subclass
- lightweight per-connection references to shared descriptors
- exact-name declarative loading without a duplicate framer keyword registry
- raw `on_data` fallback for application-specific protocols

These are permanent regression targets. New work must not trade them away
without benchmark evidence.

## Priority 1 - Comprehensive native framing families

Expand the built-in framing catalog while keeping one rule: built-in boundary
detection is native, while application-specific protocols parse raw `on_data`
bytes. Do not reintroduce a second arbitrary framer-object contract.

Near-term framing families include:

- delimiter configurations for line-oriented protocols
- additional standardized variable-integer length prefixes
- embedded/header length fields
- escaped/stuffed serial framing such as SLIP and COBS
- other general wire-framing families that can be expressed without embedding
  application protocol semantics

Keep protocol-specific state machines separate when the work is more than
message-boundary detection. A new general family needs a declarative module,
corresponding XS parser mode, wire-contract tests, and a native-framer benchmark
row. Its exact package name becomes the declaration name automatically.

## Priority 2 - Native Stream watcher-state transitions

Reduce remaining Perl transitions for writable interest, read suspension,
close, and half-close when profiling shows the boundary is material.

## Priority 3 - Callback coalescing/batching

Investigate fewer Perl entries without changing the ordinary one-message API:

- drain multiple reads before notifying Perl
- optionally deliver multiple complete frames together
- keep batching explicit where it changes application semantics

## Priority 4 - Native listener accept drain

For high connection churn:

- drain `accept4()` until EAGAIN
- request `SOCK_NONBLOCK | SOCK_CLOEXEC` at accept time
- create/register connection state efficiently
- enter Perl for accepted-connection semantics, not mechanical setup

## Priority 5 - Native connect completion

Move the nonblocking connect state machine below Perl where useful:

- handle EINPROGRESS
- wait for writable readiness
- check `SO_ERROR`
- transition watcher interest
- cancel timeout state
- notify Perl once with success or failure

## Priority 6 - Linux fd drain helpers

Profile native draining/aggregation for Linux descriptors such as eventfd,
signalfd, and pidfd so Perl receives meaningful aggregate events.

## Priority 7 - Buffer representation experiments

Only if profiling justifies them:

- sliding-buffer refinements
- ring-buffer alternatives
- allocation reuse or slabs

Do not optimize allocation speculatively.

## Priority 8 - Protocol acceleration above Stream

After the generic framing catalog is broad, consider reusable protocol engines
such as HTTP or WebSocket parsing. Application semantics remain Perl even when
mechanical parsing moves native.

## Benchmark policy

Keep the reactor comparison as the low-level regression standard. Keep Stream
transport, framing, and lifecycle/retained-memory benchmarks separate.
Cross-runtime Stream
benchmarks compare high-level facilities and must continue to report exact
fairness contracts, server CPU per message, throughput, latency, and memory.
