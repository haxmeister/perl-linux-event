# Linux::Event Roadmap to 1.000

Linux::Event 1.000 will mark a stable reactor contract, not the end of
development. The core will remain focused on reusable Linux-native facilities
for communications systems. Protocol policy, Futures, async/await, and
framework conveniences remain outside core unless a concrete cross-protocol
need proves otherwise.

This roadmap is authoritative for planned core work after 0.114. An item is a
candidate, not a promise to preserve an API designed without implementation
and integration evidence.

Linux::Event is intentionally Linux-focused. Portability to non-Linux systems
is not a reason to ignore a useful Linux facility. A Linux-specific primitive
belongs on the exploration roadmap when it provides a broadly useful capability
for communications/event-driven software or has a credible path to measurable
performance, scalability, fairness, or observability improvement.

Exploration does not imply automatic integration. Each candidate still needs a
clean semantic fit, focused correctness tests, realistic benchmarks where
performance is the reason for the work, and an acceptable maintenance cost.
Rejected and neutral experiments remain useful evidence.

## 0.114 correctness release

0.114 is intentionally narrow. It fixes the `transition_to()` invariant so a
protocol transition cannot change the underlying ordered-byte resource kind.
Pipe protocols remain pipes, TTY protocols remain TTYs, and connected
`SOCK_STREAM` protocols remain connected stream sockets. The release adds no
new public API.

## Required path to 1.000

### 1. Foreign-loop integration boundary

Implemented as the small public contract:

```perl
my $fd = $loop->poll_fd;
$loop->poll;
```

`poll_fd()` exposes the Loop-owned epoll readiness descriptor as a borrowed
integration surface. `poll()` performs exactly one nonblocking dispatch turn.
Integrations must not depend on the diagnostic shape of `resources()` or use
`run_once(0)` as an undocumented adapter convention.

The shipped dependency-free contract test drives ordinary I/O, timers, signals,
processes, and eventfd notifications through an external `IO::Select` owner and
covers borrowed-fd stability, nonblocking polling, stale-stop behavior, driver
state, and same-Loop reentrancy rejection.

Repository-only integration coverage exercises EV, AnyEvent, IO::Async, and
Mojo in a separate CI workflow. Those modules are development validation only
and are not runtime, configure, or CPAN test prerequisites.

Adapters remain outside Linux::Event core.

### 2. Deferred next-turn execution

Implemented as the owner-interpreter scheduling primitive:

```perl
$loop->defer(sub { ... });
```

The contract is deliberately narrow:

- callbacks are never invoked inline and eligible work is FIFO;
- callbacks queued while a deferred drain is executing wait for a later drain;
- the returned opaque handle supports idempotent cancellation and `is_active`;
  dropping the handle does not cancel Loop-owned pending work;
- exceptions propagate after remaining work is re-armed, so later callbacks
  survive and can run after the caller catches the exception;
- pending callbacks are visible as a Loop liveness reason;
- each drain examines at most 1,024 queued entries and re-signals its private
  eventfd when work remains, preventing recursive/self-scheduling starvation;
- the eventfd is lazy and internal, so deferred work naturally participates in
  the existing `poll_fd` / `poll` foreign-loop boundary; and
- the API is not a cross-thread or cross-process Perl callback queue.

Cross-context producers continue to use an application-owned payload channel
plus `Linux::Event::Kernel::Event` when they need to wake the owner interpreter.

### 3. Post-fork Loop contract

Implemented as an explicit resource-disposition contract on
`Loop->fork(%disposition)`.

The Loop remains process-owned: ordinary `CORE::fork` does not make an
inherited Loop reusable, and child-side driver, registration, introspection,
statistics, and tuning operations fail on the PID mismatch. Managed
`Loop->fork` is different: it is quiescent-only, replaces the child's epoll
and shared timer infrastructure, and then reconstructs only the resource
ownership requested by the application.

The first supported matrix is deliberately small:

- Listener: `share` or `move`;
- Timer: `clone` or `move`, preserving the absolute deadline;
- Inotify: independent `clone` or inherited-instance `move`;
- established plain socket Stream: `move`;
- unlisted resources: parent-only and dropped from the child.

Unsupported combinations, pending connections, non-plain Stream transports,
and active resolver requests are rejected. Move uses a child-ready/parent-commit
handshake so parent descriptor teardown does not happen until child
reconstruction succeeds. Deferred callbacks are not inherited.

### 4. Native filesystem notification with inotify

Implemented as the semantic Linux resource
`Linux::Event::Kernel::Inotify`. One public parent owns one nonblocking
inotify fd and an internal Loop registration; logical
`Linux::Event::Kernel::Inotify::Watch` objects describe independent
subscriptions and may share one kernel watch descriptor when they resolve to
the same inode.

The contract is deliberately primitive and Linux-native:

- normal `loop => $loop` and explicit `$loop->add($inotify)` attachment are
  equivalent; detached child watches do not begin kernel monitoring;
- specific callbacks define the watch mask and optional `on_event` runs last
  for the same decoded record;
- rename cookies are exposed without delaying or pairing records in core;
- queue overflow is parent-level and never silently ignored;
- cancellation and parent close are terminal and reentrant-safe;
- shared-inode masks are unioned and reduced when logical subscriptions leave;
- decoded bursts are bounded and continued through `Loop->defer()`; and
- recursive tree watching, rescan/reconciliation policy, and synthesized rename
  handling remain above the primitive core resource.

Focused Linux integration tests cover activation, real filesystem events,
invalidation, shared inodes, mask reduction, callback ordering, rename cookies,
reentrant teardown, fairness, and Loop introspection. See
`INOTIFY-DESIGN.md` for the complete contract.

## Linux-native expansion program

The four required reactor-contract items above complete the original path to
1.000, but they do not exhaust the useful Linux kernel facilities available to
Linux::Event. Linux-native expansion remains an active core program.

The default rule is:

1. Explore a Linux-specific facility when it offers a useful event-driven or
   communications capability, or a credible performance/scalability benefit.
2. Prefer a small semantic resource or capability over exposing a syscall-shaped
   API directly.
3. Keep repeated mechanical data-plane work native when measurement justifies
   it; keep policy, interpretation, and application semantics in Perl.
4. Benchmark performance-motivated changes against the current implementation
   under realistic load, including fairness and CPU cost rather than only peak
   throughput.
5. Do not merge a facility merely because Linux provides it. The result must
   improve the library's communications-engine role enough to justify its API
   and maintenance surface.

### Near-term Linux facilities to explore

#### Netlink

Netlink is the most conspicuous missing Linux event source.

Initial investigation should focus on a reusable
`Linux::Event::Kernel::Netlink` primitive and the event-loop semantics needed
for kernel-originated messages. `NETLINK_ROUTE` is the first practical target
because it can surface link, address, route, and neighbor changes useful to
long-running network services.

The primitive should expose kernel messages without turning core into a network
configuration framework. Higher-level route/device interpretation and policy
can live above the core resource. Generic Netlink families may be added later
when a concrete consumer demonstrates the need.

#### EPOLLEXCLUSIVE for shared listeners

Managed `Loop->fork()` can intentionally share a Listener while parent and
child own independent epoll instances. Evaluate `EPOLLEXCLUSIVE` for that
case to reduce unnecessary wakeups and thundering-herd behavior.

This work is both correctness-sensitive and performance-sensitive. It must
cover shared-listener lifecycle, accept fairness, edge cases around replacement
and teardown, and paired multi-process accept benchmarks before changing the
default registration policy.

#### recvmmsg() and sendmmsg() for Datagram

The Datagram engine currently preserves packet semantics with repeated
`recvmsg()` and send operations. Evaluate Linux `recvmmsg()` and
`sendmmsg()` batching to reduce syscall and dispatch overhead under packet
load.

The experiment must preserve one-datagram/one-callback semantics, peer address
accuracy, oversized-packet handling, output ordering, backpressure, and
`max_datagrams_per_tick` fairness. Measure packet rate, CPU per packet,
latency, and fairness across small and larger datagrams.

#### sendfile() and splice() zero-copy paths

Evaluate Linux zero-copy data movement for workloads where bytes do not need
application-level transformation.

`sendfile()` is directly relevant to file-to-socket transfer such as static
HTTP content. `splice()` is potentially more general for Linux::Event's
communications-engine role because it can move bytes between suitable pipes and
sockets without surfacing the payload through Perl.

These must not silently bypass Stream framing, TLS, transition, backpressure,
or lifecycle semantics. A separate explicit transfer capability may be cleaner
than adding magic to ordinary `send()`. Benchmark copies, CPU, throughput,
backpressure behavior, cancellation, partial progress, and fallback paths.

#### fanotify

Evaluate `fanotify` as the broader Linux filesystem-notification companion to
Inotify.

The useful scope is system/daemon monitoring where mount- or filesystem-wide
observation is needed. Permission-event modes, privilege requirements, and
kernel-version behavior make this a more specialized resource than Inotify, so
the initial design should keep privileged policy out of the ordinary event
path.

#### Linux UDP metadata and acceleration

Evaluate Linux packet facilities as concrete upper-layer needs appear. High
value candidates include:

- `IP_PKTINFO` and `IPV6_PKTINFO` for destination/interface metadata;
- `SO_RXQ_OVFL` for receive-queue loss visibility;
- `MSG_ERRQUEUE` for asynchronous network errors and related metadata;
- kernel receive/transmit timestamping where protocols need it;
- UDP GSO through `UDP_SEGMENT`; and
- UDP GRO where batching semantics can be preserved cleanly.

These should be integrated incrementally rather than as one large socket-option
dump. Each addition needs a demonstrated consumer and packet-level tests.

### Specialized Linux transports and packet interfaces

The following facilities are useful enough to remain on the roadmap, but they
should follow the general primitives above unless a real project creates an
earlier requirement.

#### AF_VSOCK

Explore `AF_VSOCK` for host/guest communication in virtual-machine
environments. It is a Linux communications transport with clear server/client
use cases and may fit a socket resource cleanly without inventing protocol
policy.

#### SocketCAN / AF_CAN

Explore `AF_CAN` when industrial, automotive, robotics, or device workloads
become active targets. Preserve CAN frame semantics rather than forcing CAN
through the ordered-byte Stream abstraction.

#### AF_PACKET and PACKET_MMAP

Explore raw packet capture/transmit only when a concrete packet-processing
application requires it. If ordinary `AF_PACKET` proves insufficient at the
required rate, evaluate Linux PACKET_MMAP rings such as `PACKET_RX_RING` and
`PACKET_TX_RING`.

This is potentially high-performance but substantially lower-level than
Datagram, so privilege requirements, memory ownership, ring lifetime, and
fairness need a deliberate API rather than exposing kernel structures directly.

### Additional performance candidates

The following Linux facilities merit measured experiments when the matching
workload appears:

- `TCP_FASTOPEN` for connection setup latency;
- `TCP_NOTSENT_LOWAT` for controlling unsent TCP queueing and latency;
- `SO_ZEROCOPY` / `MSG_ZEROCOPY` for very large plain-socket writes when
  completion/error-queue handling can be integrated safely; and
- additional socket/device affinity hints such as `SO_INCOMING_CPU` when
  multi-core server benchmarks show a real scheduling benefit.

These are not default API promises. They are explicit performance exploration
targets.

### Linux facilities deliberately not pulled into core by default

Linux also provides useful mechanisms whose primary role is outside the
communications reactor: seccomp policy, cgroup management, namespace
orchestration, general `memfd` object management, and similar process/system
administration facilities. They should enter core only if a concrete
Linux::Event resource requires them for its own semantics.

`io_uring` remains outside the current architecture. Linux::Event deliberately
uses an epoll reactor model; a second proactor execution model would duplicate
core lifecycle and ownership machinery. Reconsider it only if future evidence
shows a capability or performance requirement that the epoll design cannot
satisfy cleanly.

## Developer tooling before 1.000

Reevaluate the old Stream tuning explorer against the current
`stream_tuning()`, live `tune()`, Listener `stream => { tuning => {...} }`, and
payload-through-200-KB benchmark policy. The old feature branch is not a merge
candidate. If revived, implement it fresh as repository tooling; it must not
delay 1.000 or become an installed runtime dependency.

## Deliberately not required for 1.000

Idle, prepare/check phases, watcher priorities, a default singleton Loop,
Futures, condition variables, and generic cross-thread Perl callback posting
are not missing release blockers. They should be considered only when a real
communications workload demonstrates a need that cannot be served cleanly by
the existing reactor model.

## 1.000 release gate

Before publishing 1.000:

1. Complete and document the four required items above.
2. Run source and generated-distribution suites across supported Perl and
   threaded-Perl configurations.
3. Run `distcheck`, POD/example compilation, metadata, manifest, and public API
   audits.
4. Run the permanent performance-regression gate, including payloads through
   approximately 200 KB for changes that can affect Stream processing.
5. Verify foreign-loop integrations without adding their modules to CPAN
   prerequisites or shipped installation tests.
6. State the compatibility promise: ordinary public API and core conceptual
   model changes after 1.000 require a compelling correctness or architectural
   reason.
