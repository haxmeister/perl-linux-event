# BD-2026-09-04-001 - IO/Kernel architecture performance regression

**Decision:** KEEP

## Hypothesis

Reorganizing the public API under `Linux::Event::IO` and
`Linux::Event::Kernel`, while retaining the proven private implementation and
native ABI hosts, should not materially change reactor, ordered-byte, framing,
timer, or connect/listener performance.

## Baseline and candidate

- baseline: `b65e389e655844346557628cc6d11c20374c3faa`
- candidate: `a3cb42cb5ec67c9baf67372776ec7f2c7bc84f11`
- Linux::Event version: 0.105 on both sides
- benchmark contract: 3
- Perl: v5.44.0
- runner: Ubuntu 24.04 GitHub Actions runner

Both builds were compiled and measured sequentially on the same runner.

## Workload

The full release `bench/run-performance-regression.pl` preset was used, not
`--quick`:

- 7 measured repeats with rotated workload order;
- 100,000 lifecycle iterations;
- 256 reusable lifecycle socketpairs;
- 100 throughput clients with 1,000 measured messages each;
- 10,000 measured connect/listener lifecycles;
- standard full warmups;
- all nine permanent release workloads.

The candidate was compared with `--threshold-percent 10 --fail-on-regression`.

## Median comparison

| Workload | Rate delta | CPU delta |
|---|---:|---:|
| registration-lifecycle | -0.42% | +0.46% |
| timer-lifecycle | -1.29% | +1.31% |
| timer-expiration | +1.18% | -1.17% |
| raw-stream-lifecycle | -0.42% | +0.42% |
| framed-stream-lifecycle | +0.14% | -0.14% |
| raw-stream-throughput | -0.02% | +0.03% |
| deadline-stream-throughput | +0.69% | -0.66% |
| framed-stream-throughput | -0.16% | +0.17% |
| connect-listener-lifecycle | -2.17% | +2.21% |

No workload crossed the 10 percent regression threshold. The ordered-byte hot
paths are effectively unchanged: raw throughput moved -0.02 percent and framed
throughput -0.16 percent, with similarly negligible CPU movement.

The largest observed change was connect/listener lifecycle at -2.17 percent
throughput and +2.21 percent CPU, small enough to treat as ordinary hosted-runner
variance rather than evidence of an architectural cost.

## Reason

The architecture correction successfully changes the public semantic model
without adding measurable overhead to the hot path. Private implementation and
XS ABI hosts continue to carry the established optimized behavior, while the
new public leaves add no per-I/O dispatch layer.

## Caveat

This is a same-runner hosted CI comparison rather than a pinned bare-metal
benchmark host. The paired baseline/candidate method controls the largest
sources of environment mismatch, and the observed differences are much smaller
than the release gate, but sub-percent deltas should not be interpreted as real
wins or losses.

## Evidence

`performance-regression-10.zip` contains the unchanged baseline and candidate
JSON reports emitted by the harness. `metadata.json` records the exact commits,
CI run/job/artifact IDs, SHA-256 digests, configuration, and comparison deltas.
