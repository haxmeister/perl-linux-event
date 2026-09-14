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

Design a small public contract that lets another event system drive a
Linux::Event loop without adopting Linux::Event as the application's top-level
loop. The leading design is:

```perl
my $fd = $loop->poll_fd;
$loop->poll;
```

`poll_fd()` would expose the epoll readiness descriptor as a supported
integration surface. `poll()` would perform exactly one nonblocking dispatch
turn. Do not make integrations depend on the diagnostic shape of
`resources()` or on undocumented `run_once(0)` knowledge.

Acceptance requires:

- dependency-free core contract tests shipped in the CPAN distribution;
- repository/CI integration tests against representative CPAN loops such as
  EV/AnyEvent, IO::Async, and Mojo;
- no runtime or installation dependency on those event systems;
- documented ownership, readiness, draining, error, and reentrancy semantics;
- proof that timers, signals, processes, eventfd notifications, and I/O remain
  driveable through the single integration boundary.

Adapters should normally live outside Linux::Event core.

### 2. Deferred next-turn execution

Add an owner-interpreter scheduling primitive, provisionally:

```perl
$loop->defer(sub { ... });
```

Its purpose is non-reentrant, next-turn delivery for protocol and lifecycle
code. It is not a cross-thread or cross-process callback queue and must not be
named or documented in a way that implies that guarantee.

Before freezing the API, define:

- whether callbacks queued during a deferred drain run in the same or next
  turn;
- FIFO ordering and cancellation behavior;
- exception propagation and loop recovery;
- whether deferred callbacks keep the loop alive;
- fairness and a bounded-drain rule so self-scheduling callbacks cannot starve
  kernel events.

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

Add inotify as a semantic Linux resource rather than emulating a portable stat
watcher. The design should fit the existing explicit Loop/object lifecycle and
deliver decoded filesystem events without making applications parse raw
`inotify_event` records.

The design investigation must settle:

- the public class name and callback signature;
- one inotify instance per Loop versus independently owned instances;
- watch-descriptor sharing when multiple objects observe the same path;
- recursive-tree policy, including newly created directories;
- rename-cookie pairing and queue-overflow reporting;
- path replacement, watch invalidation, deletion, and unmount semantics;
- coalescing, batching, fairness, teardown, and fork behavior;
- whether recursive and higher-level convenience belongs in core or a layer
  above the primitive watcher.

Acceptance requires focused Linux integration tests, lifecycle/introspection
coverage, and evidence that idle watches add no cost to unrelated hot paths.

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
