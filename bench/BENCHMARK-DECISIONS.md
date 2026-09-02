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
| BD-2026-09-01-002 | 2026-09-01 | Native-consumer status reconciliation | KEEP |
| BD-2026-09-02-001 | 2026-09-02 | Outbound LengthPrefix and Varint fast paths | KEEP |

---

## BD-2026-09-02-001 - Outbound LengthPrefix and Varint fast paths

**Decision:** KEEP

**Hypothesis:** Resolving LengthPrefix's pack template and capacity once at
declaration time, plus directly encoding one-octet Varint lengths, reduces
per-send framing work without changing wire bytes or harming larger messages.

**Workload:**

- complete `Stream->send()` path, including Perl framing, native write/queue
  submission, Loop-driven `writev` draining, and peer receipt;
- write-only framed Stream over one AF_UNIX `SOCK_STREAM` socketpair;
- LengthPrefix with four-byte big-endian prefixes and Varint with canonical
  unsigned LEB128 prefixes;
- 64 B, 256 B, 1 KiB, 4 KiB, 16 KiB, 32 KiB, 64 KiB, 128 KiB, and 200,000 B;
- one warmup and five measured repeats per framer and size;
- message counts scaled to roughly 16 MiB of payload, bounded to 128–200,000;
- default 64 KiB `read_size`, unlimited read budget, no callback batching,
  default buffer/watermark settings, one producer, level-triggered readiness,
  OS-default 212,992-byte socket buffers, no TLS.

The raw JSON records every repeat, exact commands, resolved descriptor and
Stream configuration, runtime/compiler details, and write/queue statistics.

**Measured medians:**

| Payload | LengthPrefix throughput | CPU ns/B | Varint throughput | CPU ns/B |
|---:|---:|---:|---:|---:|
| 64 B | +31.0% | -23.6% | +16.6% | -14.2% |
| 256 B | +28.4% | -22.1% | +5.3% | -5.0% |
| 1 KiB | +26.2% | -20.8% | +2.4% | -2.4% |
| 4 KiB | +24.9% | -20.1% | +31.1% | -23.7% |
| 16 KiB | +3.8% | -3.6% | +0.4% | -0.4% |
| 32 KiB | +3.7% | -3.5% | +19.9% | -16.5% |
| 64 KiB | +2.5% | -2.5% | -2.7% | +2.8% |
| 128 KiB | +3.3% | -3.1% | +1.6% | -1.5% |
| 200,000 B | +5.0% | -4.8% | -0.9% | +0.9% |

**Reason:** LengthPrefix shows a large, consistent end-to-end gain through
4 KiB with lower CPU cost. Varint's intended one-octet 64 B path also improves
materially, while the largest rows remain neutral. Boundary regressions prove
byte equivalence for every supported LengthPrefix width/endian combination and
across canonical Varint width transitions.

**Caveat:** The eager send queue and peer drain exhibit substantial scheduling
variance for large frames. Scattered Varint gains at 4 KiB and 32 KiB are not
treated as causal evidence; only the small-prefix signal and absence of a
repeatable large-message regression drive the decision.

**Evidence:**
`bench/decisions/BD-2026-09-02-001-framer-fast-paths/`

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

---

## BD-2026-09-01-002 - Native-consumer status reconciliation

**Decision:** KEEP

**Hypothesis:** Separating provider status validation from lifecycle
application, sharing ordinary/terminal pending-flush mechanics, and factoring
buffered-input re-drive eligibility would preserve hot-path performance while
fixing post-terminal validation.

**Workload:** The same real `Linux::Event::Async::Stream` delimiter-consumer
harness and resolved configuration used by BD-2026-09-01-001: AF_UNIX
socketpair, gated producer, one receiver, one callback per message, 256 KiB
read size/budget, Async 64-message/256-KiB prefetch limits, OS-default socket
options, one warmup, five measured repeats, and the full nine-size sweep from
64 B through 200,000 B. Both core builds used the exact same lifetime-safe
Async provider binary.

**Measured medians:**

| Payload | Baseline msg/s | Candidate msg/s | Change | Baseline CPU ns/B | Candidate CPU ns/B | Baseline reads/msg | Candidate reads/msg |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 64 B | 1,911,350 | 1,907,018 | -0.2% | 8.047 | 8.125 | 0.0005 | 0.0005 |
| 256 B | 1,767,403 | 1,843,969 | +4.3% | 2.207 | 2.109 | 0.0020 | 0.0020 |
| 1 KiB | 1,448,282 | 1,365,235 | -5.7% | 0.664 | 0.713 | 0.0088 | 0.0086 |
| 4 KiB | 986,481 | 707,962 | -28.2% | 0.244 | 0.288 | 0.0317 | 0.0858 |
| 16 KiB | 190,728 | 140,347 | -26.4% | 0.199 | 0.238 | 0.4154 | 0.7079 |
| 32 KiB | 79,174 | 61,854 | -21.9% | 0.205 | 0.212 | 0.9874 | 1.4192 |
| 64 KiB | 36,121 | 41,516 | +14.9% | 0.211 | 0.238 | 2.4751 | 2.3611 |
| 128 KiB | 14,621 | 14,866 | +1.7% | 0.250 | 0.250 | 5.3930 | 5.1259 |
| 200,000 B | 22,095 | 24,631 | +11.5% | 0.145 | 0.132 | 3.5042 | 3.1233 |

**Reason:** The 64-byte row, which is most sensitive to fixed per-message
validation cost, is neutral in both wall and receiver CPU. The 256-byte row
improves and the 1-KiB row remains within single-digit run variance. Apparent
4-32-KiB losses coincide with 1.4-2.7 times as many reads/message in the
candidate, while the 64-KiB through 200-KB rows reverse direction or remain
neutral. Those medium/large differences reflect producer scheduling and
socket read splitting, not a consistent status-validation cost.

The candidate fixes a demonstrated correctness bug: invalid or `ERROR` status
cannot escape validation merely because provider code made the Stream
terminal reentrantly. It retains immediate flush debt, terminal advisory
statuses, and operation-sensitive `CONTINUE` behavior.

**Retest if:** Status handling gains new per-message work, validation becomes
data-dependent, or a CPU-isolated/interleaved runner becomes available. Keep
reads/message in the interpretation because socket splitting materially
affects the medium and large rows.

**Evidence:**
`bench/decisions/BD-2026-09-01-002-consumer-status/`

---

## BD-2026-09-02-002 - XS-reduction Phase 0 baseline

**Decision:** RETEST

**Hypothesis:** Independent cold/control-plane XS reductions can be evaluated
without confusing lifecycle cost with established Stream data-plane cost if
the branch first records both the complete release suite and a realistic
raw/framed payload sweep.

**Baseline workload:**

- all nine performance-regression workloads, seven rotated repeats, including
  100,000-operation construction/lifecycle rows, 100 concurrent serial echo
  clients, and 10,000 complete TCP connect/listener lifecycles;
- raw and native Delimiter inbound Streams at 64 B, 256 B, 1 KiB, 4 KiB,
  16 KiB, 32 KiB, 64 KiB, 128 KiB, and 200,000 B;
- one warmup and five measured payload-sweep repeats, a gated forked producer,
  256 KiB native reads/budget, disabled callback batching, OS-default AF_UNIX
  socket buffers, and size-adjusted message counts;
- full runtime/compiler, Stream/framer, transport, batching, buffer, socket,
  concurrency, read/write/callback, CPU, and input-peak configuration retained
  in the JSON evidence.

**Release-suite medians:**

| Workload | Rate | CPU |
|---|---:|---:|
| raw Stream lifecycle | 59,864 streams/s | 16.668 us/stream |
| framed Stream lifecycle | 60,945 streams/s | 16.364 us/stream |
| raw Stream throughput | 212,839 msg/s | 4.698 us/message |
| deadline Stream throughput | 209,805 msg/s | 4.766 us/message |
| framed Stream throughput | 169,135 msg/s | 5.912 us/message |
| connect/listener lifecycle | 5,970 connections/s | 166.635 us/connection |

The evidence also retains registration and Timer lifecycle/expiration rows.

**Payload-sweep medians:**

| Payload | Raw MiB/s | Raw CPU ns/B | Delimiter MiB/s | Delimiter CPU ns/B |
|---:|---:|---:|---:|---:|
| 64 B | 2,326.0 | 0.375 | 99.7 | 9.433 |
| 256 B | 6,392.7 | 0.141 | 365.1 | 2.593 |
| 1 KiB | 6,888.7 | 0.133 | 1,133.2 | 0.796 |
| 4 KiB | 6,777.0 | 0.126 | 2,770.1 | 0.320 |
| 16 KiB | 7,495.4 | 0.120 | 3,940.3 | 0.200 |
| 32 KiB | 7,133.8 | 0.121 | 4,711.0 | 0.186 |
| 64 KiB | 7,216.5 | 0.124 | 4,729.5 | 0.182 |
| 128 KiB | 7,145.8 | 0.123 | 4,541.3 | 0.184 |
| 200,000 B | 7,316.4 | 0.123 | 4,776.1 | 0.183 |

**Complexity baseline:** 3,908 physical lines in tracked Stream native
`.c`/`.h`/`.xs` sources, of which 3,287 are production and 621 are the private
test provider. The inventory identifies 146 functions (121 production, 25
test-only), classifies each by dominant invocation frequency, and records 18
direct Perl/provider callers.

**Reason:** This entry approves no extraction by itself. `RETEST` means each
candidate must be built and measured independently against this exact tree and
configuration, then receive its own KEEP/REJECT/DEFER/RETEST decision. The
payload sweep is intentionally one-way and saturated; the release suite
supplies the complementary serial request/reply and lifecycle coverage.

**Evidence:**
`bench/decisions/BD-2026-09-02-002-xs-reduction-baseline/`

---

## BD-2026-09-02-003 - descriptor specification policy extraction

**Decision:** KEEP

**Hypothesis:** The private 29-field descriptor declaration/specification
validation and normalization can move to the once-per-class Perl path while
the compact immutable native descriptor and native memory/consumer-ABI safety
checks remain in XS, reducing native policy without affecting established
Stream performance.

**Change:** The public `XSDescriptor->new` wrapper now rejects incomplete or
unknown specifications, copies the specification, and normalizes boolean and
numeric representation in Perl. The renamed private `_new_validated` XSUB
retains a 29-field completeness backstop, safe field access, native size and
parser-memory bounds, and consumer operations-table validation. Existing
framer, callback, transport, and consumer policy continues to be validated by
the earlier Perl class-descriptor path.

**Adjacent release comparison:** Seven measured repeats after warmup; the
candidate remained inside the permanent 10% gate for every row. The
Stream-relevant medians were:

| Workload | Throughput delta | CPU delta |
|---|---:|---:|
| raw Stream lifecycle | -0.03% | -0.02% |
| framed Stream lifecycle | -1.91% | +1.96% |
| raw Stream throughput | -1.79% | +1.81% |
| deadline Stream throughput | +0.50% | -0.50% |
| framed Stream throughput | +0.29% | -0.29% |
| connect/listener lifecycle | -4.59% | +4.81% |

The first non-adjacent comparison is also retained: it crossed the gate on
framed lifecycle while registration, Timer, raw, and connect rows degraded
together. Fresh adjacent baseline/candidate builds did not reproduce it.

**Full payload sweep:** Raw and native Delimiter modes used 64 B, 256 B,
1 KiB, 4 KiB, 16 KiB, 32 KiB, 64 KiB, 128 KiB, and 200,000 B, one warmup and
five measured repeats. Effective descriptor/framer settings, AF_UNIX
transport, 256 KiB reads/budget, batching, buffer limits, socket settings,
concurrency, reads/writes/callbacks, CPU, and input peaks are embedded in the
raw JSON. Delimiter candidate medians ranged from +1.13% to +29.69% MiB/s;
raw rows were noisy at small sizes as reads/message varied and ranged from
-10.14% to +205.19%. No candidate code runs after the cached descriptor is
built, and the adjacent release throughput rows were -1.79% raw and +0.29%
framed, so the payload scatter is treated as host/socket splitting noise rather
than an extraction effect.

**Focused cold-path cost:** With the complete descriptor cache cleared before
every iteration, nine repeats of 50,000 constructions per mode measured:

| Descriptor | Baseline | Candidate | Wall-time delta |
|---|---:|---:|---:|
| raw | 16.915 us | 23.976 us | +41.74% |
| Delimiter | 17.449 us | 24.600 us | +40.99% |

This is an intentional approximately 7.1 us cost when creating a previously
unseen class descriptor, not a per-Stream or per-message cost. Normal operation
caches one descriptor per class.

**Complexity/correctness:** Production native source falls from 3,287 to
3,226 lines and from 121 to 119 detected functions. Adding 48 Perl production
lines leaves a net 13-line production reduction while making declaration
policy readable and testable without entering XS. The core suite passes 142
files/1,917 tests and the real `Linux::Event::Async` cross-repository suite
passes 8 files/65 tests.

**Reason:** Keep the extraction. Its measured cost is isolated to deliberately
uncached class-descriptor construction, the established data plane remains
neutral, native ABI and memory-safety checks remain native, and the result
shrinks the native policy surface without changing consumer semantics.

**Evidence:**
`bench/decisions/BD-2026-09-02-003-descriptor-spec-perl/`
