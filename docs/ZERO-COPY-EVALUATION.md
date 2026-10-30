# File-to-TCP sendfile/splice evaluation

Research branch: `feature/sendfile-splice-evaluation`
Main baseline: `08d775cc2287fb63942c2a27b3a6bfeb59a28aa3`,
Linux::Event **0.118 unreleased**.

## Boundary

This first stage is deliberately a standalone Linux syscall experiment under
`bench/experiments`, not a new application-facing Stream feature. There are
**no changes to public or private Linux::Event engine code**, and no change
to main, distribution version, or release state.

Compare exactly three paths for transferring an immutable, cached regular
file into a real IPv4 TCP loopback connection:

1. `pread()` into a 64-KiB userspace buffer + nonblocking `send()`.
2. Nonblocking `sendfile()` directly from file to TCP socket.
3. `splice()` from file to a nonblocking pipe, then pipe to TCP socket.

A receiving thread validates **every byte** against the original file,
including wraparound for repeated file transfers. All modes use the same
source pattern, size, rounds, receiver, and nonblocking TCP output. Sender
and receiver CPU are measured separately by thread CPU clocks.

Partial progress and EAGAIN are retried after bounded `poll(POLLOUT)`.
The `--pressure-us 40` run induces receiver-side delay and exercises
that recovery. The benchmark rotates mode order across repetitions.
Throughput measures end-to-end TCP delivery through receiver EOF, not just
sender enqueue completion. The output records sender enqueue duration
separately from end-to-end wall time.

## CI evidence

Research workflow:
[sendfile/splice Linux TCP research](https://github.com/haxmeister/perl-linux-event/actions/workflows/zero-copy-evaluation.yml).
First verified corrected-throughput run:
[41137609523](https://github.com/haxmeister/perl-linux-event/actions/runs/41137609523).

The corrected run compiled with `-O2 -Wall -Wextra -Werror -pthread`
and verified **84/84 TCP trials** (five data sizes, three modes, five repeats,
plus pressured 32-KiB trials). Every received byte matched the source.
No root privileges or network interface tuning were used.

### First CI medians — sender CPU ms per MiB

| File chunk | Copied pread/send | sendfile | splice |
|---|---:|---:|---:|
| 64 bytes | 56.7280 | 55.4956 | 52.0595 |
| 4 KiB | 0.8491 | 0.7423 | 0.8403 |
| 32 KiB | 0.6895 | 0.1981 | 0.2555 |
| 200 KiB | 0.4904 | 0.0980 | 0.1181 |
| 1 MiB | 0.3958 | 0.1094 | 0.1942 |
| 32 KiB, receiver delay | 0.2471 | 0.1149 | 0.1372 |

These preliminary values show `sendfile` using about 72–80% less **sender
thread CPU** at 32 KiB–1 MiB, and `splice` showing 51–76% savings in
those larger-transfer cases. These are kernel-transfer measurements, not
Linux::Event application speedups. Shared GitHub runners are noisy; repetition
on a consistent, dedicated host is recommended before deciding on integration.

Avoid interpreting 64-byte results as a meaningful win: syscall overhead and
normal run-to-run variance dominate tiny transfers. The test repeatedly
reads the same page-cached source file, so it does **not** represent cold
disk reads, TLS encryption, ordinary file-system latency, or full HTTP
request handling.

## Dedicated four-core Linux results (2026-10-30)

The project owner ran the checked-in local runner (five repetitions) on
a dedicated four-core Linux host and supplied a complete JSONL result
file for analysis. The dataset contains **90/90 verified transfers**
(5 sizes + 32 KiB slowed-receiver case, 3 modes, 5 repeats);
no transfer had missing or corrupt bytes.

The local file itself is **not committed**; only these aggregated measurements
are recorded. All medians below are computed directly from the submitted
JSONL rows. Lower sender CPU per MiB is better, while higher verified
end-to-end MiB/s is better.

### Median sender CPU time (milliseconds per MiB)

| Transfer size | Copied pread/send | sendfile | splice | sendfile CPU reduction |
|---|---:|---:|---:|---:|
| 64 B | 26.5289 | 25.1567 | 25.4467 | 5.2% |
| 4 KiB | 0.4478 | 0.3076 | 0.3901 | 31.3% |
| 32 KiB | 0.2704 | 0.1002 | 0.0766 | 63.0% |
| 200 KiB | 0.2565 | 0.0546 | 0.0663 | 78.7% |
| 1 MiB | 0.2605 | 0.0528 | 0.0602 | 79.7% |
| 32 KiB, 40 us delayed receiver | 0.3714 | 0.1401 | 0.1314 | 62.3% |

### Median verified end-to-end throughput (MiB/s)

| Transfer size | Copied pread/send | sendfile | splice |
|---|---:|---:|---:|
| 64 B | 37.6 | 39.7 | 39.2 |
| 4 KiB | 2,227.7 | 3,205.5 | 2,539.2 |
| 32 KiB | 3,673.0 | 9,846.8 | 8,026.9 |
| 200 KiB | 3,889.5 | 6,978.0 | 7,297.7 |
| 1 MiB | 3,756.0 | 7,191.9 | 6,875.8 |
| 32 KiB, delayed receiver | 415.3 | 531.9 | 554.6 |

Each of the five local repetitions showed lower sender CPU for
`sendfile()` and `splice()` than copied writes in every scenario,
including the slowed-receiver run. At 200 KiB and 1 MiB,
`sendfile()` reduced sender CPU time by 78.7% and 79.7%
respectively, relative to the median copy values.

The receiver thread also uses CPU. Adding each trial's sender and
receiver CPU and then taking medians, `sendfile()` reduced **combined
sender+receiver thread CPU per MiB** by approximately 55.0% at 200 KiB
and 56.3% at 1 MiB. This is a useful sanity check: the 80% sender
CPU figure is **not** an 80% whole-process or system-wide CPU saving.

The 32-KiB case favors `splice()` in sender CPU per MiB,
but `sendfile()` was faster in verified end-to-end throughput in
four of five repeats. For file-to-TCP transfers overall, `sendfile()`
is generally preferable due to the smaller setup/lifecycle surface.
`splice()` should be assessed separately for pipe/socket bridging.

All tests transfer the same cached source file repeatedly over
loopback with a consumer in another thread. The extremely high
loopback MiB/s values are not estimates of physical network capacity.
The comparison uses a straightforward C `pread()+send()` control,
not Linux::Event's actual optimized native `writev()` queue. No
Linux::Event Stream/TLS/framing integration is measured here.

### Decision after dedicated run

The large, repeatable file-transfer savings justify exploring a
**feature-branch native Stream output-queue integration of sendfile**.
They do not justify a synchronous sendfile call bypassing that queue.
Prioritize ordered file offset/range accounting, cancellation,
nonblocking readiness, fairness budget, deadlines, backpressure,
shutdown and TLS rejection before attempting user-facing API design.
Retain `splice()` for a distinct socket/pipe transport investigation.
Do not merge the standalone research branch as a feature.

## Run on a dedicated Linux machine

From repository root:

```sh
git fetch origin
git switch feature/sendfile-splice-evaluation
git pull --ff-only
bash bench/experiments/run-zero-copy-local.sh
```

The script compiles the standalone helper with the local C compiler, runs the
same five-size and backpressure matrix, prints median sender CPU per MiB,
and writes one machine-readable file to
`bench/results/zero-copy/local-*.jsonl`. Upload that file for review.
Use `--quick` for a dry run with two repetitions.

Required tools: Bash, C compiler, Python 3, Linux TCP loopback. No extra
Perl modules, sudo, sysctl changes, or system-wide networking tweaks.

## Architectural questions before any Stream API

Current `Linux::Event::IO::Sock::Stream` uses a native segmented
`writev()` queue, supports application framing, transition preservation,
TLS, deadlines, backpressure, and graceful `end()`.
A naive `sendfile(fd)` call can overtake queued writes and violate
those contracts. Any future transfer feature must:

- Be an **explicit** operation eligible only for appropriate plain sockets
  and regular-file sources. TLS cannot bypass the encryption provider.
- Queue a file-transfer descriptor **in order** behind already accepted
  output; headers, file bytes and any trailers must stay ordered.
- Track file-offset ownership, partial transfers, EAGAIN, readiness,
  cancellation, close, half-close, end, deadlines and progress.
- Preserve existing output backpressure and avoid an unlimited sendfile
  drain that starves unrelated Loop resources.
- Decide whether the source fd is borrowed/duplicated, and prevent
  mutation of source pages while the kernel is still transmitting.
- Preserve raw framed-output semantics; do not reframe binary file bytes
  or bypass existing application policy silently.
- Test before/after with actual `Linux::Event::Stream` workloads and
  payloads 64 B through at least 200 KiB. Measure CPU per MiB,
  throughput, p95/p99 response time, partial writes, correctness and
  impact on unrelated streams.

**Integration preference to evaluate**: `sendfile` for file-to-TCP
output first. `splice` adds an intermediary pipe and complexity for
the same file-to-TCP case; its distinct potential value is pipe/socket
bridging. Evaluate socket-to-socket splice separately rather than
claiming the file transfer microbenchmark establishes that benefit.

No public method name or argument shape has been approved yet.
Keep the experiment draft and do not merge/release it automatically.
