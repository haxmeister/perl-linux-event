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
- optional hard native pending-output limits with typed terminal errors
- native transport operation contract with a specialized plain-fd fast path
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
- in-place raw/framed protocol transitions that retain unread native input,
  queued output, registration identity, lifecycle, and application state
- one shared timerfd plus an indexed native deadline heap per Loop
- cached subclass callbacks, fixed-rate recurrence, coalescing, and bounded
  dispatch for public Timer objects
- one shared signalfd, native fan-out registry, aggregate delivery, and exact
  mask restoration for public Signal objects

These are permanent regression targets. New work must not trade them away
without benchmark evidence.

## Completed - unified object lifecycle

`Linux::Event::Loop` owns high-level Stream, Listener, Timer, and Signal objects through
`add()`, while `watch()` creates an immediately attached opaque native
registration. There is no public Watcher or IO base class. One logical object
may own several internal epoll registrations.

Timer uses that same attachment contract without adding Loop-specific factory
methods. The abstract public Timer class caches `on_timer` once per subclass;
active instances live entirely in the Loop's native scheduler.

Signal uses the same attachment contract. Its abstract public class caches
`on_signal` once per subclass, while each Loop's private native service owns
the signalfd mask and supports multiple numbers per object plus multiple
objects per number.

`MyStream->connect()` keeps one Stream identity through outbound acquisition
and optional TLS readiness. `MyStream->listen()` creates the Listener that
constructs accepted Streams. The public hierarchy adds no generic Perl call to
steady-state native readiness dispatch.

## Completed - initial TLS provider implementation

HTTPS, secure WebSocket, and Discord require TLS. TLS is a byte transport
transform, not a message framer. The internal native operation boundary and
plain provider now exist. The bundled `Linux::Event::TLS` provider attaches
without adding OpenSSL policy or calls to XSLoop or the plain Stream path.

The design must cover handshake readiness, encrypted and plaintext buffering,
certificate/hostname errors, shutdown, deadlines, ALPN, and transitions such as
STARTTLS without putting TLS policy into XSLoop. Initial client/server TLS,
verification, ALPN, cross-direction readiness, and close notification landed
with the 0.100_015 transport ABI. Version 0.100_016 added provider-owned
deadline-watcher lifecycle and the original external Linux::Event::TLS 0.002
added default handshake and shutdown deadlines, clean/unclean EOF
classification, native counters, and a same-Stream plain-versus-TLS benchmark.
Version 0.100_017 merged that provider into the main distribution without
merging its OpenSSL implementation into XSStream.

The released attachment exact-versions the common ABI, retains provider
lifetime, and implements cross-direction readiness (`SSL_read` wanting write
and `SSL_write` wanting read). Deadlines, richer shutdown diagnostics, provider
bounded-buffer observability and live transport replacement remain follow-up
work.

## Completed - Stream connection layer

`MyStream->connect()` owns the public outbound lifecycle. Its private
`Linux::Event::Stream::_Connection` engine implements strict
IPv4/IPv6/Unix/packed address modes, typed errors, silent cancellation, and a
default connection deadline. Socket creation uses
`SOCK_NONBLOCK | SOCK_CLOEXEC` atomically. Immediate results are deferred so
network callbacks never run inside the constructor.

The policy/state machine remains in cold Perl code. A small native timerfd
helper supplies monotonic deadlines and deferred dispatch. Same-fd native
replacement uses one `EPOLL_CTL_MOD` where an fd registration is replaced.

## Completed - native Listener layer

`Linux::Event::Listener` creates or adopts listening stream sockets and
constructs a configured Stream subclass for each accepted connection. A small
private native extension drains `accept4()` with atomic nonblocking and
close-on-exec flags and retains packed peer addresses for lazy conversion.

The default level-triggered fairness cap is safe because epoll reports a
remaining backlog again. Edge-triggered listeners require an unlimited drain.
No temporary accepted-socket registration is created before Stream attachment.
Resource exhaustion pauses readiness before typed error delivery.

## Completed - asynchronous Resolver and Happy Eyeballs

Hostname resolution is mechanically separate from Stream connection policy in
a private XS extension. Each Loop lazily owns two native resolver workers and
one eventfd completion queue. Workers never enter Perl. The normal raw Loop
watch path drains complete candidate collections, cancelled requests discard
late results, IPv6/IPv4 attempts are staggered by 250 ms, and first-success
ownership closes all losers. Literal, Unix, and packed addresses bypass the
resolver. Dedicated integration, cancellation, ordering, and microbenchmark
coverage protects the boundary.

## Completed - signalfd signal handling

`Linux::Event::Signal` provides synchronous Loop-thread delivery without Perl
signal handlers. One lazy signalfd and native subscription registry per Loop
drain and aggregate records before fan-out. Cancellation is safe during
callbacks, last-subscriber removal restores only mask entries Linux::Event
changed, and one signal number has one owning Loop per process. Resolver
workers block signals independently so native DNS cannot intercept them.

## Priority 2 - General native framing families

Expand the built-in framing catalog while keeping one rule: built-in boundary
detection is native, while application-specific protocols parse raw `on_data`
bytes. Do not reintroduce a second arbitrary framer-object contract.

Near-term framing families include:

- a configurable `HeaderLength` family with header size, field offset/width,
  byte order, length adjustment, header inclusion, and frame limit
- additional standardized variable-integer length prefixes
- escaped/stuffed serial framing such as SLIP and COBS
- other general wire-framing families that can be expressed without embedding
  application protocol semantics

Keep protocol-specific state machines separate when the work is more than
message-boundary detection. A new general family needs a declarative module,
corresponding XS parser mode, wire-contract tests, and a native-framer benchmark
row. Its exact package name becomes the declaration name automatically.

## Priority 3 - Native Stream watcher-state transitions

Reduce remaining Perl transitions for writable interest, read suspension,
close, and half-close when profiling shows the boundary is material.

## Priority 4 - Callback coalescing/batching

Investigate fewer Perl entries without changing the ordinary one-message API:

- drain multiple reads before notifying Perl
- optionally deliver multiple complete frames together
- keep batching explicit where it changes application semantics

## Priority 5 - Native connect attempt completion

Profile before moving the remaining attempt state machine below Perl. If
high-churn connection workloads justify it, native code may:

- handle EINPROGRESS
- wait for writable readiness
- check `SO_ERROR`
- coordinate concurrent attempt readiness
- cancel timeout state
- notify Perl once with success or failure

The public Stream connection contract must not change merely to eliminate a
few cold Perl calls.

## Priority 6 - Linux fd drain helpers

Profile native draining/aggregation for remaining Linux descriptors such as
pidfd so Perl receives meaningful aggregate events.

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
transport/output-limit, framing, protocol-transition, and
lifecycle/retained-memory benchmarks separate.
Cross-runtime Stream
benchmarks compare high-level facilities and must continue to report exact
fairness contracts, server CPU per message, throughput, latency, and memory.
