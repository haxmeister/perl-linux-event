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

The 0.118 development line extends managed fork with callback-safe
`Loop->defer_fork(%options)`. It queues managed fork requests and uses the
existing deferred wakeup service to unwind the active native driver before
forking at a quiescent boundary. Parent and child callbacks run only after
resource reconstruction; pending parent requests are not inherited by the
child. The API supports `run`, `run_for`, `run_once`, and `poll` without
loosening the direct `fork` rule. The established resource matrix is
unchanged. This is implemented in source but not yet released on CPAN.

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

### Current status at a glance (2026-10-31)

The version on `main` is **0.118 (unreleased)**. The latest published
CPAN version is **0.117**. The four original reactor-contract milestones
above are implemented. The version 0.118 development line also includes
`Loop->defer_fork()` and native Stream `sendfile()`.
Completion of these milestones does **not** by itself authorize a 1.000
release; the release gates below still apply.

The distinctions below are deliberate. **Experimented and not merged**
does not mean **not investigated**; **designed and deferred** does not
mean **not designed**.

| Facility or work | Status | Decision / next condition |
| --- | --- | --- |
| Foreign-loop `poll_fd()`/`poll()`, `defer()`, managed `fork()`, Inotify | Implemented and merged (0.115–0.117) | Maintain existing contracts |
| `defer_fork()` | Implemented and merged (0.118 unreleased) | No additional fork API required by this plan |
| Stream `sendfile()` | Implemented and merged (0.118 unreleased) | Documented; 64 KiB private drain budget |
| `EPOLLEXCLUSIVE` shared listeners | Fully prototyped, benchmarked, **not merged** | Hold after mixed sustained results; do not enable by default |
| `recvmmsg()` Datagram receive batching | Prototyped, benchmarked, **not merged** | Modest small-packet gain, 8 KiB regression; do not enable by default |
| `splice()` | Syscall/file-to-TCP experiment completed; no core integration | Reopen only with a concrete socket/pipe relay use case |
| Netlink | **Core + separate-distribution design approved**; implementation deferred | Begin only on a new explicit priority decision |
| `sendmmsg()` | **Not experimentally investigated** | Evaluate only for significant outgoing Datagram queue/burst workloads |
| `fanotify`, UDP metadata/GSO/GRO, specialized socket families, TCP knobs | Roadmap candidates, **not yet investigated as core features** | Need a real user or performance case |

Research branches and PRs are preserved for evidence, not as work awaiting
automatic merge. The key records are
[exclusive shared listeners, PR #36](https://github.com/haxmeister/perl-linux-event/pull/36),
[UDP receive batching, PR #37](https://github.com/haxmeister/perl-linux-event/pull/37),
[zero-copy syscall study, PR #38](https://github.com/haxmeister/perl-linux-event/pull/38), and
[merged Stream sendfile, PR #39](https://github.com/haxmeister/perl-linux-event/pull/39).
A cross-version summary and the actual research decisions are kept in
[`DEVELOPMENT-HISTORY.md`](DEVELOPMENT-HISTORY.md).
No specific feature has been approved as the next implementation after
`sendfile()`.

### Implemented and merged: native Stream file transfer

Established plain socket Streams now provide
`sendfile($fh, offset => ..., length => ...)` on the unreleased 0.118
development line. It adds owned file-range entries to the existing native
ordered output queue and retains the `write()` ordering, backpressure,
hard output limits, deadlines, graceful end, teardown and managed-fork
contracts. The method emits raw bytes rather than framed messages; TLS
and pending outbound connections are deliberately unsupported.

A private **64 KiB** per-readiness file/mixed-output budget was retained
after real Stream and Timer sweeps showed no meaningful reason to enlarge
it. Correctness tests, the actual Stream benchmark, the ordinary-byte
performance regression, and post-merge CI passed. See
[`STREAM-SENDFILE-DESIGN.md`](STREAM-SENDFILE-DESIGN.md) and
[merged PR #39](https://github.com/haxmeister/perl-linux-event/pull/39).
The separate research PR #38 remains open for historical evidence,
not because `sendfile()` is incomplete.

### Investigated, measured, and deliberately not integrated

#### EPOLLEXCLUSIVE for fork-shared Listeners

[Draft PR #36](https://github.com/haxmeister/perl-linux-event/pull/36)
contains a real opt-in native Listener/Loop prototype, the
`fork(share => [...])` and `defer_fork()` integration tests, lifecycle
and failed-registration rollback coverage, and comparisons against
ordinary fork-shared epoll and independent `SO_REUSEPORT` sockets.
The prototype is behind
`LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE=1` and is **not** in `main`.

Kernel-level and shorter real-Stream experiments reduced empty accept
wakeups and sometimes improved transaction rate, but short bursts
also showed uneven distribution across workers. We then built and
corrected a sustained local quad-core benchmark: its first version
used TCP reset closes and contaminated server error handling, so
only corrected **v2** results are suitable for performance decisions.
Across the five-repeat v2 local comparison, 5,694,682 request/reply
transactions completed with no losses or Stream errors. For four
workers, medians were:

| Synthetic handler work | Ordinary shared | EPOLLEXCLUSIVE | SO_REUSEPORT |
| --- | ---: | ---: | ---: |
| 0 microseconds | 10,684 replies/s | 11,120 (+4.1%) | 10,573 |
| 150 microseconds | 7,903 replies/s | 6,951 (**−12.0%**) | 7,448 |

The sustained test distributed work much more evenly than short bursts
(fairness above 0.998), but did **not** show a dependable performance
win. The local raw dataset was supplied during development and was not
committed to the public branch; the branch retains its benchmark driver,
CI measurements, and [test instructions](https://github.com/haxmeister/perl-linux-event/blob/feature/epollexclusive-evaluation/bench/experiments/EPOLLEXCLUSIVE-LOCAL.md).
**Decision:** stop this investigation for now; preserve draft PR #36.
Do not enable exclusive registration by default or merge the prototype.
Reopen only with new representative evidence and a concrete shared-socket need.

#### recvmmsg() Datagram receive batching

[Draft PR #37](https://github.com/haxmeister/perl-linux-event/pull/37)
contains an experimental bounded native receive path controlled by
`LINUX_EVENT_EXPERIMENT_RECVMMSG=8|32`. It preserves one callback per
packet, peer information, truncation, zero-length packets and the
`max_datagrams_per_tick` bound. The existing `recvmsg()` path is the
production default. Full branch CI
[passed](https://github.com/haxmeister/perl-linux-event/actions/runs/41133753891).

The local four-core follow-up verified **5,280,000 packets across
150/150 trials** with no losses or corruption. In the complete
Loop/`on_datagram` workload, native receive batching yielded about
2.5–5.1% less CPU for 64-byte datagrams and 1.0–2.8% less for
1,400-byte datagrams, but approximately **1.9–2.8% more CPU at 8 KiB**.
Serial ping-pong did not establish a consistent gain. The raw local
measurement was discussed during development; the feature branch
retains its reproducible benchmark programs and initial CI results in
[`UDP-RECVMMSG-EVALUATION.md`](https://github.com/haxmeister/perl-linux-event/blob/feature/udp-recvmmsg-evaluation/docs/UDP-RECVMMSG-EVALUATION.md).

**Decision:** keep PR #37 as research; do not make batching the
default or merge it based on these results. This concludes the
`recvmmsg()` investigation for now; it does **not** include
`sendmmsg()`.

#### splice() and the earlier zero-copy comparison

[Draft research PR #38](https://github.com/haxmeister/perl-linux-event/pull/38)
compared copied file-to-TCP transmission with Linux `sendfile()` and
`splice()` using verified real TCP transfers and backpressure cases.
A five-repeat local run delivered **90/90 byte-verified transfers**.
For 200 KiB and 1 MiB, `sendfile()` reduced sender CPU per MiB by
approximately 79–80% against copying. That evidence led to the
now-merged `sendfile()` feature.

`splice()` was **measured but not integrated**. Its possible value
is a distinct socket/pipe bridge for proxy and relay workloads, not
an unfinished file-sending implementation. Any future bridge needs
its own ordering, TLS/framing eligibility, queue ownership, fairness,
backpressure, cancellation and lifecycle design. **Do not restart
the existing syscall comparison without new evidence.**

### Designed and intentionally deferred

#### Netlink — approved two-layer architecture, not implemented

Netlink is the most conspicuous missing Linux event source, and the project has
made an explicit architectural decision to support it in two layers.

Linux::Event core will eventually provide the reusable
`Linux::Event::Kernel::Netlink` transport/resource primitive. Core owns the
mechanical Linux integration that every Netlink family needs:

- `AF_NETLINK` socket lifecycle and Loop integration;
- nonblocking receive/send mechanics and message-boundary validation;
- sequence-number allocation and request/reply correlation;
- multipart dump completion;
- ACK, error, and extended-ACK handling;
- multicast subscription plumbing;
- receive-overflow/loss detection and resynchronization signals;
- cancellation, teardown, fairness, and managed-fork lifecycle rules; and
- native batching or parsing only where measurement justifies it.

Core deliberately does not become a complete Netlink protocol catalog. It
should not accumulate family-specific interpretation such as route attributes,
interface policy, ethtool commands, nl80211 semantics, or other subsystem
meaning merely because those protocols travel over Netlink.

The thorough user-facing Netlink implementation will therefore live in a
separate `Linux::Event::Netlink` distribution layered on the core primitive.
Its first major target is `NETLINK_ROUTE`, with easy semantic APIs for links,
addresses, routes, neighbors, initial state dumps, and asynchronous change
notifications. Generic Netlink and additional families can then grow in that
distribution without expanding the Linux::Event core surface for every kernel
subsystem.

The intended layering is:

```text
Linux::Event core
    Linux::Event::Kernel::Netlink
        generic Netlink transport and lifecycle machinery

Linux::Event::Netlink distribution
    Linux::Event::Netlink::Route
    Linux::Event::Netlink::Generic
    family-specific event/value objects and higher-level semantics
```

This is an **approved design decision**, recorded in
[merged PR #33](https://github.com/haxmeister/perl-linux-event/pull/33);
no Netlink primitive or high-level distribution has been implemented.
The user deliberately deferred this work. It is a valid future
capability, but **not automatically the next task**.

When implementation begins, design the core primitive first around real
`NETLINK_ROUTE` requirements, then build the Route layer in the separate
distribution as the integration test of that primitive. Avoid designing an
overly generic Netlink API in isolation before the first real family proves the
boundary.

### Genuinely uninvestigated Linux-native candidates

#### sendmmsg() Datagram transmit batching

`sendmmsg()` has **not** been implemented or measured in this
project. It must not be grouped with the completed `recvmmsg()`
receive investigation. The current Datagram write path sends
individual packets; transmit batching is worth measuring only when
a real workload creates enough queued outbound datagrams for
one syscall to send multiple packets. Preserve packet boundaries,
addresses, order, errors, backpressure and per-tick fairness.
Do not promise a speedup from immediate serial sends.

#### fanotify — candidate, not investigated

Evaluate `fanotify` as the broader Linux filesystem-notification companion to
Inotify.

The useful scope is system/daemon monitoring where mount- or filesystem-wide
observation is needed. Permission-event modes, privilege requirements, and
kernel-version behavior make this a more specialized resource than Inotify, so
the initial design should keep privileged policy out of the ordinary event
path.

#### Linux UDP metadata and acceleration — candidates, not investigated

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

### Specialized Linux transports and packet interfaces — candidates only

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

### Additional performance candidates — not yet experimentally evaluated

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
