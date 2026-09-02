# Linux::Event Benchmark Decision Record

This file is the append-only engineering record for benchmark-driven decisions
in Linux::Event.

The benchmark scripts and raw result files answer "what did the machine
measure?". This record answers "what decision did we make from those
measurements, and why?". Both are required.

## Permanent rule

A benchmark-driven architectural, optimization, or XS-boundary change is not
complete until:

1. the benchmark configuration is recorded;
2. the actual machine-readable benchmark output used for the decision is
   committed under `bench/decisions/<decision-id>/`;
3. the relevant baseline and candidate commits/branches are identified;
4. the result is summarized here;
5. the engineering decision is recorded as `KEEP`, `REJECT`, `DEFER`, or
   `RETEST`;
6. caveats and conditions for revisiting the decision are recorded.

Negative and neutral experiments are first-class results. Do not delete them
merely because the candidate was rejected.

For new Stream/data-plane decisions, the committed evidence must obey the
project payload rule: architectural conclusions require a representative sweep
through approximately 200 KB rather than a tiny-message result alone.

## Required Stream/framer configuration

For any benchmark involving `Linux::Event::Stream`, `Linux::Event::Socket`,
framing, TLS, or the native-consumer path, preserve the effective runtime
configuration that materially describes the workload. Do not record only the
options explicitly supplied on the command line; defaults must be resolved to
concrete values in the evidence whenever they can affect the result.

At minimum record, when applicable:

- raw versus framed delivery;
- exact framer class/family and all framer parameters;
- transport: AF_UNIX, TCP, TLS, pipe, or other;
- payload/message sizes and message counts;
- `read_size`;
- read fairness/budget settings;
- `read_batch_bytes`;
- `message_batch_size`;
- input/max-buffer limits;
- write-queue limits and high/low-water settings;
- write segmentation or framing mode when relevant;
- level-triggered versus edge-triggered behavior when configurable/relevant;
- socket buffer sizes, `TCP_NODELAY`, or other socket options when they can
  influence the tested path;
- TLS/provider configuration when the transport is TLS;
- Async/native-consumer queue or prefetch limits when testing that boundary;
- client count/concurrency and producer/consumer topology;
- CPU affinity or isolation when used;
- exact benchmark command line;
- benchmark script version/commit.

The preferred design is for each benchmark JSON file to emit a normalized
`effective_config` object containing these values. A separate `metadata.json`
may supplement the benchmark output when the harness cannot yet emit all of
them.

If an old result does not preserve a setting, record it as `unknown` rather
than inferring a default from today's implementation. Historical defaults may
have changed.

## Evidence retention

For new decisions, preserve the benchmark program's output unchanged whenever
possible. Prefer JSON or another machine-readable format that includes raw
repeats as well as summary values.

Recommended layout:

```text
bench/decisions/
  BD-YYYY-MM-DD-NNN-short-name/
    baseline.json
    candidate.json
    comparison.json       # when the harness emits one
    metadata.json         # effective config/context absent from benchmark output
```

Do not replace the raw files with a hand-written table. The table in this log
is an index and interpretation layer, not the evidence itself.

Some historical decisions predate this policy and their original per-repeat
output is no longer present in the repository. For those entries, an exact
recovered summary is committed as `recovered-summary.json` and explicitly
marked `evidence_level: recovered_summary`. Such an entry preserves the known
measurements but must not be represented as raw evidence. Configuration fields
that cannot be established from the surviving record must be marked `unknown`.

These decision records and evidence files are Git engineering history and are
not part of the CPAN distribution.

## Decision index

| Decision ID | Date | Experiment | Decision |
|---|---|---|---|
| BD-2026-08-28-001 | 2026-08-28 | Framed callback batching | KEEP |
| BD-2026-08-29-001 | 2026-08-29 | Native connect `SO_ERROR` completion | REJECT |
| BD-2026-08-29-002 | 2026-08-29 | Native Process pipe draining | KEEP |
| BD-2026-09-01-001 | 2026-09-01 | Native-consumer host lifetime leases | KEEP |

---

## BD-2026-08-28-001 - Framed callback batching

**Decision:** KEEP

**Hypothesis:** Amortizing Perl callback entry across multiple framed messages
produced in one native drain would improve throughput without changing the
ordinary callback contract when batching is disabled.

**Historical workload:**

- 1,000,000 pipelined 64-byte messages;
- 4 KiB native reads;
- AF_UNIX socketpair and TCP loopback;
- one warmup and five measured repeats;
- batch sizes 16, 32, and 64 compared with ordinary per-message callbacks.

The surviving summary does not identify every effective Stream/framer setting.
Those missing historical settings are intentionally marked `unknown` in the
recovered evidence rather than reconstructed from current defaults.

**Measured medians:**

| Transport | Ordinary | Batch 16 | Batch 32 | Batch 64 |
|---|---:|---:|---:|---:|
| AF_UNIX | 129.7 MiB/s | 263.4 MiB/s | 276.2 MiB/s | 305.6 MiB/s |
| TCP loopback | 126.8 MiB/s | 227.0 MiB/s | 282.1 MiB/s | 311.3 MiB/s |

Batch 32 reduced message callback entries by 96.9 percent in the measured
workload and was judged the best balance of throughput and latency. Batch 64
remained available for throughput-oriented protocols. Batch size one was
slower than ordinary `on_message` because it created an array without
amortizing callback entry.

**Reason:** The gain was large enough to justify keeping the batching mechanics
native and explicit.

**Caveat:** This experiment used 64-byte messages and predates the current
realistic-payload rule. It establishes that callback amortization can be
valuable; it does not establish a universal batch-size recommendation for
medium or large messages. Any future default/tuning decision must be retested
through approximately 200 KB.

**Evidence:**
`bench/decisions/BD-2026-08-28-001-callback-batching/recovered-summary.json`

---

## BD-2026-08-29-001 - Native connect SO_ERROR completion

**Decision:** REJECT

**Hypothesis:** Moving the readiness-time `getsockopt(SO_ERROR)` completion
probe into native Loop dispatch would materially improve outbound connection
completion throughput.

**Historical workload:**

- 600,000 loopback TCP connections;
- concurrency 10;
- Perl completion probe compared with a native completion probe;
- balanced execution order and paired analysis.

**Measured result:**

- Perl probe aggregate median: 10,614.7 connections/s;
- native probe aggregate median: 10,741.6 connections/s;
- apparent aggregate difference: about +1.2 percent;
- repeat-pair median difference: -0.5 percent.

**Reason:** The apparent aggregate gain disappeared under paired analysis and
was smaller than run variance. The extra native path did not earn its
complexity and was removed.

**Revisit only if:** A representative workload dominated by concurrent Happy
Eyeballs attempts, failed candidates, or deadline cancellation demonstrates a
material coordination cost. If revisited, move and measure the coordination as
one unit rather than relocating one syscall.

**Evidence:**
`bench/decisions/BD-2026-08-29-001-native-connect-so-error/recovered-summary.json`

---

## BD-2026-08-29-002 - Native Process pipe draining

**Decision:** KEEP

**Hypothesis:** Process stdout/stderr contained a repetitive mechanical Perl
read loop that could benefit from a private native drain helper while leaving
Process lifecycle and error policy in Perl.

**Historical workload:**

- pre-spawned children released by a start gate so spawn/setup was outside the
  timed interval;
- stdout, stderr, and both-pipe modes;
- 1, 8, and 32 workers;
- balanced seven-repeat matrices;
- multiple read sizes.

**Measured paired improvements:**

- independent 4 KiB matrices: +27.8 percent and +25.1 percent;
- 8 KiB: +19.4 percent;
- 16 KiB: +5.3 percent;
- 32 KiB: +3.3 percent;
- default 64 KiB combined 126-pair median: +0.2 percent, effectively neutral.

Parent CPU fell in every reported 4 KiB case. A saturated recurring-Timer probe
found no fairness regression at one or 64 reads per descriptor turn.

**Reason:** The native helper materially improved workloads dominated by small
mechanical reads while remaining neutral at the normal large read size. The
implementation retained only the repetitive drain mechanic in XS and kept
semantic Process policy in Perl.

**Evidence:**
`bench/decisions/BD-2026-08-29-002-process-pipe-drain/recovered-summary.json`

---

## BD-2026-09-01-001 - Native-consumer host lifetime leases

**Decision:** KEEP

**Hypothesis:** The exported native-consumer host can provide an append-only
`retain`/`release` lifetime extension that makes callback-capable provider
frames safe without an unacceptable end-to-end cost.

**Workload:**

- real `Linux::Event::Async::Stream` native Delimiter consumer;
- AF_UNIX `SOCK_STREAM` socketpair with a gated forked producer;
- 64 B, 256 B, 1 KiB, 4 KiB, 16 KiB, 32 KiB, 64 KiB, 128 KiB, and
  200,000 B payloads;
- one warmup and five measured repeats at every size;
- 256 KiB Stream `read_size` and `read_budget_bytes`;
- Async prefetch limits of 64 messages and 256 KiB;
- one Perl ready callback per message, no TLS, level-triggered readiness, one
  receiver, OS-default socket options and 212,992-byte observed socket
  buffers.

The JSON evidence resolves the remaining Stream limits, batching settings,
message counts, reads and writes per message, input peaks, compiler/runtime,
exact commands, and candidate source fingerprints.

**Measured medians:**

| Payload | Baseline msg/s | Candidate msg/s | Change | Baseline CPU ns/B | Candidate CPU ns/B |
|---:|---:|---:|---:|---:|---:|
| 64 B | 2,275,953 | 1,878,342 | -17.5% | 6.875 | 8.281 |
| 256 B | 2,152,842 | 1,801,444 | -16.3% | 1.816 | 2.148 |
| 1 KiB | 1,558,680 | 1,395,109 | -10.5% | 0.615 | 0.693 |
| 4 KiB | 523,562 | 589,932 | +12.7% | 0.308 | 0.308 |
| 16 KiB | 187,175 | 136,203 | -27.2% | 0.214 | 0.234 |
| 32 KiB | 64,692 | 204,642 | +216.3% | 0.230 | 0.146 |
| 64 KiB | 36,748 | 34,047 | -7.4% | 0.269 | 0.256 |
| 128 KiB | 18,185 | 16,019 | -11.9% | 0.247 | 0.244 |
| 200,000 B | 16,576 | 39,818 | +140.2% | 0.165 | 0.122 |

The tiny-message rows consistently expose the fixed cost of unwind-safe host
leases: about 16-17 percent wall throughput and 18-20 percent receiver CPU at
64-256 B in this intentionally severe one-callback-per-message workload. The
large-frame wall results are not directional evidence. Producer scheduling and
socket read splitting changed reads/message substantially and produced both
large apparent wins and losses across repeats.

**Reason:** The old provider can lose both its host state and its own context
under an active C frame when synchronous `resume()` delivery lets user code
close the Stream. That is a memory-safety contract failure, so retaining the
append-only lifetime mechanism is mandatory. The Async candidate limits
leases to callback-capable/provider-sensitive frames and preserves the current
reentrant message/terminal-flush semantics. Existing ABI-v1 providers that do
not opt into the appended fields pay no per-message lease cost.

**Retest if:** Async changes callback coalescing, prefetch wakeup behavior, or
can safely amortize one host lease across multiple ready callbacks. Use a
paired or CPU-isolated topology if the execution environment can load/launch
the two XS variants in an interleaved order; continue to retain the full
payload sweep.

**Evidence:**
`bench/decisions/BD-2026-09-01-001-consumer-host-lifetime/`
