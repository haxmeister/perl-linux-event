# EPOLLEXCLUSIVE shared-listener evaluation

This is a **measurement-only** branch. It does not change Linux::Event's
public API or production epoll registrations. Main stays untouched.

## Why this experiment

When managed `$loop->fork(share => [$listener])` forks workers, each process
has an independent epoll instance watching the same listening socket.
Ordinary level-triggered readiness can wake multiple workers for one incoming
connection. Linux `EPOLLEXCLUSIVE` can reduce unnecessary wakeups.

We must compare it with two alternatives:

- `shared`: one inherited socket, ordinary `EPOLLIN` in each epoll.
- `exclusive`: one inherited socket, `EPOLLIN | EPOLLEXCLUSIVE` in each epoll.
- `reuseport`: independent listening sockets bound to the same port with
  `SO_REUSEPORT`, each monitored by its own ordinary epoll instance.

The latter is a **different deployment model**, so compare it as a useful
alternative, not a drop-in replacement for shared sockets.

## Tooling

`bench/experiments/epollexclusive-accept.c` is a standalone Linux benchmark.
It uses actual `fork()`, independent epoll instances, real loopback TCP
connections and nonblocking `accept4()`. No Perl runtime is needed for this
first-stage kernel behavior comparison.

Compile and try one case:

```sh
cc -O2 -Wall -Wextra -std=gnu11 \
  -o /tmp/le-exclusive bench/experiments/epollexclusive-accept.c
/tmp/le-exclusive exclusive 4 1000 0
```

Arguments: mode, workers, number of connections, microseconds between
connection attempts. Output is a single JSON object containing accepted
count, elapsed time, worker CPU, epoll wakeups, epoll wakeups with no accepts,
accept syscalls, and the least/most accepts per worker. A successful run
requires all connections to be accounted for. A matching GitHub Actions
workflow runs 1/2/4/8 workers with sparse and burst arrival patterns, repeats
each case, and uploads raw JSON for comparison.

**Interpretation:** `zero_accept_wakeups` is a useful thundering-herd
indicator but does not measure every scheduler wakeup. CPU time excludes the
client generator and startup overhead; elapsed time includes client connection
generation. For the sparse test, arrival rate is deliberately limited and
throughput is therefore not an independent capacity metric. Repeat benchmarks
on a quiet dedicated machine before making product decisions. CI's shared
runner is a smoke-and-directional measurement, not a performance guarantee.

## Linux constraints to verify before integration

Linux man-pages document that `EPOLLEXCLUSIVE`:

- is available since Linux 4.5;
- is accepted on `EPOLL_CTL_ADD`, not `EPOLL_CTL_MOD`;
- causes later `MOD` requests on an exclusive (epoll fd, target fd) pair
  to fail with `EINVAL`;
- can be combined with `EPOLLIN` and optionally `EPOLLET`;
- wakes **one or more** exclusive observers, not necessarily exactly one;
- does *not* suppress notification to any ordinary, nonexclusive observer
  of the same listening socket.

Reference: https://man7.org/linux/man-pages/man2/epoll_ctl.2.html

These rules matter for the existing Listener implementation:

- `_Socket::Listener::_attach_to_loop` uses an ordinary internal
  `$loop->watch(... read => ...)` registration.
- `pause` and `resume` call `disable_read`/`enable_read`; in native XS,
  these issue `EPOLL_CTL_MOD`. Exclusive watchers must use a different path.
- `fork(share => [$listener])` rebuilds the child Loop but leaves the parent
  Listener registration in place. Enabling exclusivity on the child alone is
  ineffective because the parent ordinary registration still wakes.
- A future integration must cover setup *before* the fork, rollback if the
  fork fails, registration replacement, teardown, fairness, source ownership,
  and the effect of fork callbacks that modify the Listener.

## Stage gates

1. Establish paired kernel measurements on the three cases.
2. Add focused regression tests for `EPOLLEXCLUSIVE` registration behavior,
   lifecycle, and paused / resumed listeners in an experimental feature branch.
3. Only if useful, prototype the minimal internal Loop/Listener integration
   and exercise `fork(share => [...])` and `defer_fork(share => [...])`.
4. Compare a real Linux::Event multi-worker server under identical workloads
   and revisit CPU usage, fairness and the baseline 10% performance gate.
5. Decide whether to merge. Do not add a public option or set any new default
   until the evidence supports it.

No main merge, tagging, version bump, or release is authorized for this
evaluation.
