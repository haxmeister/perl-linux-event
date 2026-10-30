# EPOLLEXCLUSIVE shared-listener evaluation

This is a **research-only feature branch** with an opt-in internal Listener/Loop
prototype. Ordinary Linux::Event behavior and the public API remain unchanged
unless the test-only `LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE=1` environment
variable is set before constructing a Listener. Main stays untouched.

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

## Linux::Event integration prototype

The branch has a narrow internal implementation in
`lib/Linux/Event/_Socket/Listener.pm` and `xsloop/Loop.xs`.
It installs `EPOLLEXCLUSIVE` on a Listener's first `EPOLL_CTL_ADD`,
on **both parent and child** before/after a managed
`fork(share => [$listener])`. It rejects incompatible edge-triggered,
oneshot, write, and non-internal watcher combinations. It strips
`EPOLLRDHUP` because the kernel rejects that bit on an exclusive ADD.

`pause()` uses DEL, not MOD, and `resume()` uses ADD with the same
native watcher and Perl registration retained. The default registration
path, including its cheaper ordinary MOD, remains unchanged.

The internal switch is strictly for evaluation, not a public option or
a proposed default. For a local opt-in run:

```sh
LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE=1 perl -Mblib your-server.pl
```

Focused test: `t/loop-epollexclusive-experiment.t` covers ordinary behavior,
exclusive pause/resume, pending socket readiness while paused, closing a
suspended Listener, managed-fork inheritance of a paused Listener, and
callback-triggered `defer_fork(share => [$listener])` with child pause/resume.
All eight supported CI Perl configurations and generated-distribution
integrity have passed on the prototype.

The real `Linux::Event` workload is
`bench/experiments/epollexclusive-linux-event.pl`.
It constructs actual Listener and Stream objects in each worker, exercises
shared managed forks versus independent SO_REUSEPORT sockets, sends one-byte
requests, waits for acknowledged Stream responses, and records per-process
accept counts, epoll waits, and approximate worker CPU time.
`serial` (one request at a time) and `batch` (many outstanding requests)
have both been measured in CI.

Real benchmark runs:
- Sequential: https://github.com/haxmeister/perl-linux-event/actions/runs/40980410396
- Concurrent batch: https://github.com/haxmeister/perl-linux-event/actions/runs/40980753795

Results: `bench/experiments/EPOLLEXCLUSIVE-RESULTS.md`.

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
- The opt-in prototype installs exclusive registration in both parent
  and child. A production design must still cover rollback when registration
  or fork fails, watcher replacement, teardown, fairness, source ownership,
  and callback-triggered changes after forking.

## Stage gates

1. Completed: paired kernel measurements of ordinary shared, exclusive shared,
   and independent SO_REUSEPORT sockets.
2. Completed: opt-in internal prototype and regression tests of pause/resume,
   close, and managed `fork(share => [...])`.
3. Completed: real Linux::Event Listener/Stream measurements with sequential
   and concurrently outstanding request batches.
4. Remaining: more adversarial failure/rollback and teardown tests;
   CPU/fairness workloads
   across different kernels and dedicated hardware; completed baseline
   performance comparison before considering merge.
5. Decide whether to merge. Do not add a public option or set any new default
   until the evidence supports it.

No main merge, tagging, version bump, or release is authorized for this
evaluation.
