# Linux::Event Roadmap to 1.000

Linux::Event 1.000 will mark a stable reactor contract, not the end of
development. The core will remain focused on reusable Linux-native facilities
for communications systems. Protocol policy, Futures, async/await, and
framework conveniences remain outside core unless a concrete cross-protocol
need proves otherwise.

This roadmap is authoritative for planned core work after 0.114. An item is a
candidate, not a promise to preserve an API designed without implementation
and integration evidence.

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

Audit and document what happens when a process forks after creating a Loop.
The default candidate contract is that a Loop belongs to the process that
created it and the child must construct a new Loop. Narrow inherited-descriptor
behavior, such as a child notifying a parent-owned eventfd, remains documented
by the relevant resource.

Add a loop reinitialization API only if implementation and tests show that it
is safe, understandable, and materially useful. In either case, 1.000 requires
tests that make accidental child-side Loop reuse fail predictably rather than
silently misbehave.

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
