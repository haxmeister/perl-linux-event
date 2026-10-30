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

## Real Linux::Event Listener/Stream results (2026-10-29)

**Sequential round trips:**
https://github.com/haxmeister/perl-linux-event/actions/runs/40980410396

Each request required a completed one-byte Stream reply before the next
request started. 500 requests per trial, three trials per case; all 500
responses completed in every trial. Rates are *completed application
transactions* per second, not just TCP connect attempts.

| Workers | Simulated work | Mode | Completed/s | Worker CPU s | Epoll waits | Median min/max accepted per worker |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 4 | 0 us | Shared | 3,206 | 0.12 | 2,352 | 0/247 |
| 4 | 0 us | EPOLLEXCLUSIVE | 3,547 | 0.10 | 1,482 | 0/499 |
| 4 | 0 us | SO_REUSEPORT | 3,024 | 0.09 | 1,249 | 118/136 |
| 4 | 150 us | Shared | 2,033 | 0.21 | 2,288 | 5/305 |
| 4 | 150 us | EPOLLEXCLUSIVE | 2,194 | 0.19 | 1,394 | 0/500 |
| 4 | 150 us | SO_REUSEPORT | 2,130 | 0.18 | 1,356 | 113/133 |

**Concurrent outstanding requests:**
https://github.com/haxmeister/perl-linux-event/actions/runs/40980753795

The client opens and writes up to 500 requests, then waits for all
acknowledgments. This is a more realistic burst-contention case, though not a
fully representative persistent-connection workload. Three trials per case,
500 transactions; every request received its reply.

| Workers | Simulated work | Mode | Completed/s | Worker CPU s | Epoll waits | Median min/max accepted per worker |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 4 | 0 us | Shared | 3,550 | 0.14 | 2,083 | 34/307 |
| 4 | 0 us | EPOLLEXCLUSIVE | 4,590 | 0.11 | 1,131 | 0/406 |
| 4 | 0 us | SO_REUSEPORT | 3,840 | 0.12 | 1,457 | 119/135 |
| 4 | 150 us | Shared | 3,625 | 0.21 | 1,792 | 75/181 |
| 4 | 150 us | EPOLLEXCLUSIVE | 4,061 | 0.20 | 1,400 | 4/230 |
| 4 | 150 us | SO_REUSEPORT | 3,704 | 0.19 | 1,373 | 109/143 |
| 8 | 0 us | Shared | 3,457 | 0.12 | 1,977 | 10/249 |
| 8 | 0 us | EPOLLEXCLUSIVE | 4,742 | 0.12 | 1,107 | 0/350 |
| 8 | 0 us | SO_REUSEPORT | 3,762 | 0.08 | 1,464 | 54/72 |
| 8 | 150 us | Shared | 3,305 | 0.20 | 1,880 | 40/98 |
| 8 | 150 us | EPOLLEXCLUSIVE | 3,558 | 0.19 | 1,476 | 0/229 |
| 8 | 150 us | SO_REUSEPORT | 3,483 | 0.16 | 1,428 | 54/74 |

The raw per-worker arrays are included in workflow artifacts and log JSON.
Reported worker CPU uses Perl's `times()` and has relatively coarse timing
resolution for short trials; the comparison is indicative only.

**Interpretation:** The exclusive mode consistently reduces epoll activity
and completed more transactions per second than ordinary shared epoll in the
tested four/eight-worker scenarios. However, exclusive registration still
produces uneven worker allocation even for concurrent batches. Sometimes
a worker gets no accepts, while another receives most. SO_REUSEPORT has much
more even distribution, and at eight workers with application CPU work its
measured total worker CPU is lower.

All tests were conducted on shared GitHub Actions runner hardware and
short loopback TCP workloads. Workload ordering and OS scheduling introduce
noise. These numbers do **not** justify making EPOLLEXCLUSIVE the default
for shared Listeners yet.

**Next stage:** Focus on fairness and correctness under worker pauses,
restarts, failed fork/registration, and concurrent long-lived connections;
test the `defer_fork` path. A dedicated-machine A/B test should precede
any public integration decision. Keep all of this on the feature branch.

## Accept-budget fairness matrix — 2026-10-30

[Passing CI measurement run 40986208593](https://github.com/haxmeister/perl-linux-event/actions/runs/40986208593),
48 completed trials; two repeats per worker/budget/mode combination.
The benchmark used four and eight worker processes, 500 concurrently
outstanding one-byte requests, 150 microseconds of synthetic per-message
CPU work, and `max_accept_per_tick` of 1, 8, 32, or 256.
All requested Stream replies were delivered. Medians below are computed
from two trials, so do not overinterpret small throughput differences.

### Four workers

| Budget | Exclusive completed/s | Exclusive worker CPU s | Exclusive min/max accepted | SO_REUSEPORT completed/s |
| --- | ---: | ---: | ---: | ---: |
| 1 | 6,691 | 0.130 | 40/186 | 6,768 |
| 8 | 6,605 | 0.120 | 26/194 | 6,757 |
| 32 | 6,690 | 0.135 | 33/178 | 6,629 |
| 256 | 6,350 | 0.120 | 18/200 | 6,539 |

### Eight workers

| Budget | Exclusive completed/s | Exclusive worker CPU s | Exclusive min/max accepted | SO_REUSEPORT completed/s |
| --- | ---: | ---: | ---: | ---: |
| 1 | 6,236 | 0.125 | 2/201 | 6,042 |
| 8 | 6,421 | 0.120 | 5/168 | 6,033 |
| 32 | 6,347 | 0.115 | 4/194 | 6,082 |
| 256 | 6,370 | 0.120 | 1/198 | 6,088 |

In these trials a smaller accept budget sometimes modestly improved
distribution for four workers, but did not eliminate the imbalance and did
not consistently improve throughput. With eight workers some exclusive
processes still accepted almost nothing. SO_REUSEPORT was much more balanced
at every budget. Absolute rates were higher in this CI run than in the
previous 500-request experiment, which reinforces the caution about
benchmark host and scheduling variance.

**Conclusion:** accept-budget tuning does not make EPOLLEXCLUSIVE a fair
worker-selection mechanism. Do not change the default `max_accept_per_tick`
or automatically select EPOLLEXCLUSIVE for shared listeners based on this
experiment. Next useful evaluation is a longer application workload on a
dedicated multicore host and a kernel-version compatibility matrix.
