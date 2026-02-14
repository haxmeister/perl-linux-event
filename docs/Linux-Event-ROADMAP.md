# Linux::Event Roadmap

## Project Scope (Locked)

Linux::Event is a **Linux-native event engine** built around:

-   epoll
-   timerfd
-   signalfd
-   eventfd
-   pidfd
-   optional io_uring (later)

It is **not**:

-   a networking framework
-   a DNS layer
-   a socket abstraction
-   a retry/backoff policy engine

Sockets may appear in examples, but Linux::Event does not construct or
manage them.

The focus is correctness, performance, and predictable semantics for
Linux primitives.

------------------------------------------------------------------------

# External Module Integration Plan

Linux::Event will integrate the following modules by Leon Timmermans:

## Immediate / Core

-   Linux::Epoll
-   Linux::FD (all relevant submodules)
    -   Linux::FD::Signal (signalfd)
    -   Linux::FD::Event (eventfd)
    -   Linux::FD::Timer (timerfd)
    -   Linux::FD::Pid (pidfd)

## Later

-   Linux::FD::Mem (optional, advanced)
-   Linux::uring (optional alternative backend)

------------------------------------------------------------------------

# Architectural Principles

1.  Loop is Linux-specific and unapologetic.
2.  No hidden ownership of filehandles.
3.  No implicit closing or auto-unwatching.
4.  Idempotent cancellation and teardown.
5.  Minimal hot-path overhead.
6.  Explicit semantics \> convenience.
7.  Any protocol lives above the loop, not inside it.

------------------------------------------------------------------------

# Core Semantics Contract (Must Not Drift)

## Watchers

    $loop->watch($fh,
      read  => sub ($loop, $fh, $watcher, $data?) { ... },
      write => sub ($loop, $fh, $watcher, $data?) { ... },
      error => sub ($loop, $fh, $watcher, $data?) { ... },
      data  => $user_data,
      edge_triggered => 0|1,
      oneshot        => 0|1,
    );

### Dispatch Order

For each epoll event:

1.  If EPOLLERR:
    -   If error callback exists → call error and return.
    -   Otherwise treat as READ + WRITE readiness.
2.  If EPOLLHUP:
    -   Trigger read (so EOF is discovered by user code).
3.  If EPOLLIN:
    -   Trigger read.
4.  If EPOLLOUT:
    -   Trigger write.

Order: - error - read - write

No automatic close. No automatic unwatch.

`unwatch()` is idempotent. Unknown fd in unwatch() is a silent no-op.

------------------------------------------------------------------------

## Timers

-   Implemented via Linux::FD::Timer (timerfd).
-   Scheduler uses nanosecond deadlines.
-   One-shot timers must be exact and drift-free.
-   Repeating timers will only be added once semantics are frozen.
-   Timer callback signature mirrors watcher style.

------------------------------------------------------------------------

# Milestones

## M1 --- Harden Core Semantics (Highest Priority)

Goal: Make watcher and timer behavior unambiguous and bulletproof.

Tasks:

-   Validate epoll flag mapping behavior with tests:
    -   IN
    -   OUT
    -   HUP
    -   ERR
    -   combinations
-   Ensure error callback fires first.
-   Ensure edge_triggered semantics require user drain.
-   Ensure oneshot semantics disarm correctly.
-   Ensure idempotent cancel/unwatch.
-   Handle stale epoll events safely.
-   Confirm no double-close edge cases.

Performance:

-   Avoid extra allocations in dispatch.
-   Keep watcher lookup O(1).
-   Minimize internal call stack depth.

Exit Criteria:

-   Semantics documented.
-   Comprehensive tests.
-   No undefined behavior.

------------------------------------------------------------------------

## M2 --- Linux FD Integrations

Goal: Make Linux-specific FDs trivial to integrate.

### 1. signalfd (Linux::FD::Signal)

Provide:

    $loop->signal(SIGINT, sub { ... });

-   Uses signalfd internally.
-   No legacy signal handlers.
-   Integrated via normal watcher mechanism.

### 2. pidfd (Linux::FD::Pid)

Provide:

    $loop->child_exit($pid, sub { ... });

-   No polling.
-   Uses pidfd.
-   Works cleanly with spawn() later.

### 3. eventfd (Linux::FD::Event)

Provide:

    $loop->eventfd(sub { ... });

-   Used for cross-thread or cross-process wakeups.
-   Used internally by worker pool (later).

### 4. timerfd (Linux::FD::Timer)

Already integrated. Must confirm: - no drift - no accidental blocking -
correct disarm behavior

Exit Criteria:

-   All FD types integrate seamlessly with watch().
-   No special-case dispatch logic outside Loop core.

------------------------------------------------------------------------

## M3 --- Process Spawning & Supervision

Goal: Provide Linux-native process management without becoming a
framework.

Introduce:

    $loop->spawn(
      command => [...],
      stdout  => sub { ... },
      stderr  => sub { ... },
      exit    => sub { ... },
    );

Internally:

-   fork
-   set up pipes
-   integrate stdout/stderr with watch()
-   integrate pidfd with child_exit()

No implicit restarts unless explicitly requested. No hidden protocol.

Exit Criteria:

-   Spawned child fully supervised.
-   No resource leaks.
-   Teardown is explicit and safe.

------------------------------------------------------------------------

## M4 --- Worker Pool (Prefork)

Goal: Optional prefork workers managed by the loop.

Constructor option:

    Linux::Event::Loop->new(
      workers => N,
      worker  => sub { ... },
    );

### Protocol Requirement

Worker pool requires explicit IPC protocol.

Linux::Event will provide:

-   eventfd or pipe/socketpair for communication
-   fd integration
-   lifecycle supervision

Linux::Event will NOT:

-   define message framing format
-   define serialization format
-   define RPC semantics

Protocol must live above the loop.

Exit Criteria:

-   Worker pool optional.
-   No impact on hot path if unused.
-   Clear protocol boundary.

------------------------------------------------------------------------

## M5 --- Linux::FD::Mem (Optional / Advanced)

Goal: Enable high-performance shared memory use cases.

Use cases:

-   Worker pool shared buffers.
-   High-performance IPC.
-   Large message passing without copies.

Constraints:

-   Optional.
-   Advanced.
-   No hidden policy.
-   No dependency in core dispatch path.

------------------------------------------------------------------------

## M6 --- Linux::uring Backend (Future)

Goal: Optional backend for advanced workloads.

Plan:

-   Create Linux::Event::Backend::Uring
-   Preserve watcher semantics contract
-   Maintain consistent API surface

This must not change watcher contract.

------------------------------------------------------------------------

# Versioning Strategy

-   Use development versions while semantics are evolving.
-   Each milestone completion:
    -   Bump dev version.
    -   Update Changes.
    -   Update documentation.
    -   Ensure examples match behavior exactly.

------------------------------------------------------------------------

# Non-Goals

-   Socket creation helpers.
-   DNS resolution.
-   Retry/backoff logic.
-   TLS abstraction.
-   Network protocol helpers.

------------------------------------------------------------------------

# Immediate Next Steps

1.  Complete M1 fully.
2.  Integrate signalfd.
3.  Integrate pidfd.
4.  Integrate eventfd.
5.  Implement spawn().
6.  Only then implement worker pool.
7.  Linux::FD::Mem and io_uring come later.

------------------------------------------------------------------------

# Final Philosophy

Linux::Event should become:

The most correct, predictable, and performant Linux-native event loop in
Perl.

Everything else belongs above it.


## Concurrency Helpers (Clarification)

Linux::Event intentionally does **not** provide:

- `$loop->thread(...)`
- `$loop->fork(...)`
- worker pools
- supervisors
- built-in queues or schedulers

These are considered *policy-layer* constructs and are out of scope for the
core distribution.

The core provides the necessary primitives instead:

- `waker()` (eventfd) for cross-thread / cross-process wakeups
- `pid()` (pidfd) for process lifecycle observation

Higher-level concurrency helpers may be implemented in separate distributions,
but Linux::Event itself remains a minimal, Linux-native primitive substrate.
