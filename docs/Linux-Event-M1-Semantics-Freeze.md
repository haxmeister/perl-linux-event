# Linux::Event

# M1 Semantics Freeze Document

## Core Watcher and Timer Semantics (Authoritative)

This document formally defines the behavior of Linux::Event for
Milestone 1.

These semantics must not drift.

------------------------------------------------------------------------

# 1. Watcher Identity, Close Safety, and FD Reuse Protection

## 1.1 Watcher Key

-   Watchers are keyed internally by integer file descriptor (`fd`).
-   The `fd` is captured at watch-time via `fileno($fh)`.

Lookup is O(1) using integer fd.

------------------------------------------------------------------------

## 1.2 Watcher Stores FD and Weak FH

Each watcher stores:

-   The integer `fd`
-   A weakened reference to the original Perl filehandle (`$fh`), if it
    is a reference.

This prevents strong ownership and avoids memory cycles.

------------------------------------------------------------------------

## 1.3 Dispatch-Time Validation

Before dispatching callbacks for an epoll event:

1.  Lookup watcher by `fd`.
2.  Validate:
    -   Weak `$fh` still exists.
    -   `fileno($fh)` is defined.
    -   `fileno($fh) == fd`.

If validation fails:

-   The watcher is removed from the internal table.
-   Any `epoll_ctl(DEL)` failure is ignored.
-   No callback is invoked.
-   The event is discarded.

This guarantees:

-   Safe behavior if user closes a watched filehandle.
-   Safe handling of fd reuse.
-   Safe handling of stale epoll events.

------------------------------------------------------------------------

## 1.4 Close Behavior

If a user closes a watched filehandle without calling `unwatch()`:

-   The kernel removes the fd from epoll.
-   Linux::Event may still have an internal watcher temporarily.
-   On the next epoll event for that fd, validation fails and the
    watcher is purged.
-   No callback will be invoked for a closed handle.

------------------------------------------------------------------------

## 1.5 Unwatch Behavior

`unwatch($fh)`:

-   If not currently watched:
    -   nothing happens.
    -   no warning.
    -   no exception.
-   If currently watched:
    -   watcher removed from internal table.
    -   removed from epoll (best effort).

Calling `unwatch()` multiple times is safe.

------------------------------------------------------------------------

## 1.6 Re-watch Replacement

Calling `watch($fh, %spec)` on an already watched fd:

-   Replaces the existing watcher.
-   Old watcher removed immediately.
-   No callback triggered due to replacement.
-   Replacement is atomic.

There is never more than one active watcher per fd.

------------------------------------------------------------------------

# 2. Epoll Event Mapping and Dispatch Order

## 2.1 Validation Precondition

Section 1 validation is applied before dispatch.

------------------------------------------------------------------------

## 2.2 Dispatch Order (Strict)

For each epoll event:

Order is strictly:

1.  error
2.  read
3.  write

Never reordered.

------------------------------------------------------------------------

## 2.3 EPOLLERR Semantics

If EPOLLERR is present:

-   If error callback exists:
    -   call error only.
    -   suppress read/write.
-   If no error callback:
    -   treat as readiness.
    -   read and/or write may run.

------------------------------------------------------------------------

## 2.4 EPOLLHUP Semantics

-   EPOLLHUP triggers read callback.
-   This allows EOF discovery.
-   EPOLLHUP does not imply write unless EPOLLOUT is also set.

------------------------------------------------------------------------

## 2.5 edge_triggered Semantics

If `edge_triggered => 1`:

-   Dispatch occurs once per edge.
-   The loop does not drain.
-   The user must read/write until EAGAIN.
-   Failure to drain results in no further events, as defined by epoll.

No auto-drain option exists.

------------------------------------------------------------------------

## 2.6 oneshot Semantics

If `oneshot => 1`:

-   After the first dispatch (even if multiple flags), watcher is
    disarmed.
-   Disarm happens after callbacks complete.
-   User must explicitly re-watch.

------------------------------------------------------------------------

## 2.7 edge_triggered + oneshot

-   Allowed.
-   Behaves exactly like oneshot.
-   Single dispatch.
-   Explicit re-watch required.

------------------------------------------------------------------------

## 2.8 Exception Behavior

The loop does not trap exceptions.

If a callback dies, the exception propagates.

------------------------------------------------------------------------

# 3. Mutation During Dispatch

## 3.1 Removing Watchers During Callbacks

If a callback calls `unwatch()`:

-   The watcher is removed immediately.
-   Before invoking each callback step (error, read, write), the loop
    checks that the watcher still exists.
-   If removed, remaining callbacks for that event are skipped.

Example:

If read callback calls `unwatch()`, write will not run.

------------------------------------------------------------------------

## 3.2 No Nested Dispatch

The loop does not re-enter epoll dispatch while callbacks are executing.

Callbacks run sequentially.

Changes take effect for future events unless removal cancels remaining
callbacks for the current event.

------------------------------------------------------------------------

## 3.3 epoll_ctl(DEL) Failures

Kernel errors during removal (ENOENT, EBADF, etc.) are ignored.

The internal watcher table is authoritative.

------------------------------------------------------------------------

# 4. Timer Semantics (timerfd)

## 4.1 Clock Source

All timers use:

-   CLOCK_MONOTONIC

System wall-clock adjustments do not affect timers.

CLOCK_REALTIME is not used.

------------------------------------------------------------------------

## 4.2 Internal Representation

-   Deadlines stored as signed 64-bit integer nanoseconds.
-   Maximum range approximately 292 years.

Scheduling beyond representable range is an error.

------------------------------------------------------------------------

## 4.3 Absolute Deadlines

Internally:

-   All timers use absolute monotonic deadlines.
-   timerfd is programmed using TFD_TIMER_ABSTIME.

Relative durations may be accepted in API, but are immediately converted
to absolute deadlines.

This prevents cumulative drift.

------------------------------------------------------------------------

## 4.4 One-Shot Timers

-   A one-shot timer fires once.
-   After callback:
    -   timerfd disarmed.
    -   timer removed.
-   User must reschedule for repetition.

No automatic repeating timers in M1.

------------------------------------------------------------------------

## 4.5 Drift Guarantees

-   Timers fire as close as possible to the scheduled absolute deadline.
-   Loop latency may delay callback execution.
-   Loop latency does not shift other deadlines.

------------------------------------------------------------------------

## 4.6 Expiration Count Handling

If timerfd reports multiple expirations:

-   Treated as a single firing.
-   Expiration count is not exposed in M1.

------------------------------------------------------------------------

## 4.7 Cancellation

If a timer is cancelled before firing:

-   It is disarmed.
-   Removed from internal structures.

Cancelling an already fired or already cancelled timer does nothing.

------------------------------------------------------------------------

## 4.8 Timer Scope Boundary

Linux::Event timers are monotonic-deadline timers.

Scheduling by wall-clock time (e.g., "3pm local time") is out of scope
and must be implemented above the loop by converting wall-clock instants
into monotonic deadlines.

------------------------------------------------------------------------

# Final Statement

These M1 semantics define:

-   Watcher identity
-   Close safety
-   FD reuse protection
-   Deterministic dispatch
-   Explicit mutation rules
-   Monotonic timer guarantees

M1 is now formally frozen.
