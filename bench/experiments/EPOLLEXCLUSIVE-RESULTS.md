# First EPOLLEXCLUSIVE benchmark results — 2026-10-29

GitHub Actions run:
https://github.com/haxmeister/perl-linux-event/actions/runs/40976555921

Kernel in first run: Linux 7.0.0-1017-azure; CI runner reported 4 available CPUs.
Three repeats per case, real local TCP connects, 1,200 connections per burst
case, independent epoll instance per worker, accept4 with 64-accept batch cap.
Median per test group. All attempts were accepted; all tests passed.

The numbers below use the **second/extended run**, not the original run
40976363793. Host and scheduler conditions can change between runs.

## 8 workers, empty accept-and-close handlers

| Mode | Rate / sec | Workers' CPU sec | Epoll readiness events | Zero-accept wakeups | Min/max accepted per worker |
| --- | ---: | ---: | ---: | ---: | ---: |
| Shared ordinary | 18,265 | 0.0697 | 2,581 | 1,384 | 0 / 823 |
| EPOLLEXCLUSIVE | 28,513 | 0.0184 | 1,197 | 0 | 0 / 1,193 |
| SO_REUSEPORT | 31,948 | 0.0173 | 1,199 | 0 | 138 / 171 |

The kernel exclusive registration eliminates empty accepts in this test and
substantially reduces worker CPU. However, most connections can be handled
by one exclusive worker while other workers handle none. `SO_REUSEPORT`
distributes accepts much more evenly. `SO_REUSEPORT` is a distinct
deployment arrangement, not interchangeable with the same shared socket.

## 8 workers, 150 microseconds of simulated CPU per accepted connection

| Mode | Rate / sec | Workers' CPU sec | Epoll readiness events | Zero-accept wakeups | Min/max accepted per worker |
| --- | ---: | ---: | ---: | ---: | ---: |
| Shared ordinary | 18,596 | 0.1929 | 321 | 94 | 104 / 198 |
| EPOLLEXCLUSIVE | 20,043 | 0.1876 | 97 | 0 | 63 / 353 |
| SO_REUSEPORT | 18,676 | 0.1879 | 150 | 0 | 138 / 164 |

As handlers become busy, more workers participate and the relative importance
of accept wakeups declines. Exclusive is slightly faster than shared in this
specific median, but not by a margin that yet justifies a production change
without repeated real application benchmarks. `SO_REUSEPORT` remains the
strongest in connection distribution.

## 8 workers, sparse arrivals (2 ms between connections)

| Mode | Rate / sec | Workers' CPU sec | Zero-accept wakeups | Min/max accepted per worker |
| --- | ---: | ---: | ---: | ---: |
| Shared ordinary | 471 | 0.0215 | 312 | 0 / 206 |
| EPOLLEXCLUSIVE | 477 | 0.0059 | 0 | 0 / 300 |
| SO_REUSEPORT | 477 | 0.0064 | 0 | 30 / 46 |

This throughput is limited by the generator's arrival rate. `EPOLLEXCLUSIVE`
can save CPU even at low rates but shows very uneven worker usage.

## Preliminary decision

The kernel primitive appears useful as a way to reduce wasted wakeups in a
shared-socket deployment, but not as an unconditional optimization:

1. A single exclusive worker can dominate a lightly loaded shared listener.
2. A real server does more work than accept-and-close; gains may shrink once
   Stream construction, framing/TLS, and callbacks dominate CPU.
3. `SO_REUSEPORT` is a useful alternate design with different ownership and
   more even distribution in this benchmark.
4. Existing Listener `pause/resume` performs `EPOLL_CTL_MOD`, illegal after
   an exclusive ADD; native watcher lifecycle needs experimental changes.
5. In `fork(share => ...)`, both parent and child registrations need exclusive
   treatment. Leaving any ordinary registration preserves its wakeups.

**Do not change the public Listener API or default registration mode yet.**

Next stage: build an opt-in *internal-only* EPOLLEXCLUSIVE prototype in this
feature branch, with proper parent-before-fork registration and lifecycle
handling, then run actual Linux::Event Listener+Stream workloads. Keep the
prototype off main until correctness and performance have been demonstrated.
The current benchmark is a research harness, not proof of application-level
speedup.
