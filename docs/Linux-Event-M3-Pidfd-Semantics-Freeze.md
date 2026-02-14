# Linux::Event — M3 pidfd Semantics Freeze

**Status:** Draft freeze (intended to be locked once tests/examples pass)

Linux::Event exposes Linux pid file descriptors (pidfd) as a minimal process-lifecycle
primitive integrated with the existing epoll loop. This is **not** a supervisor or
process manager.

## Non-goals

Linux::Event does **not** provide:

- process spawning policy (no restart, no retry/backoff)
- worker pools
- signal management policy for processes
- STDIO plumbing helpers
- any portability layer for non-Linux platforms

## Public API

```perl
my $sub = $loop->pid($pid, $cb, %opts);
```

Where `%opts` may include:

- `data => $any` (optional)
- `reap => 1|0` (optional, default **1**)

### Callback signature (frozen)

```perl
sub ($loop, $pid, $status, $data) { ... }
```

Exactly **four** arguments are passed.

- `$pid` is the numeric PID that was registered.
- `$status` is a raw wait status compatible with POSIX wait macros (`WIFEXITED`, `WEXITSTATUS`, etc).
  It may be `undef` if exit status is unavailable.

## Core semantics

- **One handler per PID.** Registering again replaces the previous handler (replacement semantics).
- A subscription handle is returned. `cancel` is idempotent.
- pidfds are opened lazily per subscription and watched via the normal watcher mechanism.
- Core loop dispatch order and hot-path behavior remain unchanged.

## Readiness and dispatch

- A pidfd becomes readable when the target process exits.
- On readiness:
  - If `reap => 1`, Linux::Event performs a **non-blocking** wait for exit status.
  - If a wait status is obtained, the callback is invoked once and the subscription tears down.
  - If no status is available yet (`WNOHANG` / not ready), no callback is invoked.
  - If `reap => 0`, the callback is invoked once with `$status = undef` and the subscription tears down.

## Reaping policy

- Exit status is only available when the watched PID is a **child** of the current process.
- If `reap => 1` and waiting fails (e.g. not a child / already reaped), Linux::Event throws a clear exception.
  Users who want "exited notification only" should use `reap => 0`.

## Dependencies

- Requires `Linux::FD::Pid` (pidfd_open / waitid(P_PIDFD)).
- Tests must skip cleanly if the dependency or kernel support is unavailable.
