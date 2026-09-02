# Linux::Event XS Reduction Roadmap

This document starts a deliberate effort to reduce the amount of XS/C code in
Linux::Event without giving back the performance advantages that justified the
native implementation.

The goal is not "less XS at any cost." The goal is to keep the native data
plane small, obvious, and fast, while moving cold policy, validation, lifecycle,
and presentation work back to Perl when benchmarks show that doing so is
performance-neutral or close enough to neutral to justify the maintenance win.

Every extraction is an experiment with correctness coverage and paired
performance measurements.

## Permanent development rule - realistic payload coverage

Performance decisions must not be based on tiny-message benchmarks alone.
Small payloads are valuable because they expose fixed per-message, callback,
and Perl/XS boundary costs, but previous Linux::Event work showed that
performance relationships can change materially as payloads move into the
kilobyte and hundreds-of-kilobytes range.

Any experiment that can affect Stream payload processing, framing, buffering,
write queues, callback boundaries, native-consumer delivery, transport I/O, or
copying must cover message sizes through approximately 200 KB.

Use these standard sweeps unless a benchmark has a documented reason to use a
nearby protocol-specific size:

### Quick development sweep

- 64 B
- 4 KB
- 32 KB
- 200 KB

### Full architectural / merge sweep

- 64 B
- 256 B
- 1 KB
- 4 KB
- 16 KB
- 32 KB
- 64 KB
- 128 KB
- 200 KB

The intent is to cover:

- tiny payloads dominated by fixed callback/boundary overhead;
- small application/API messages;
- realistic medium web/protocol messages;
- payloads around Stream read-size boundaries;
- large messages requiring multiple reads/writes and meaningful buffering.

For medium and large payloads, messages/second is not sufficient by itself.
Record MiB/second and CPU per byte or per MiB where possible. Also record
reads/message, writes/message, callbacks/message, p50/p99 latency, and buffering
or high-water behavior when the change can affect those metrics.

Historical absolute results are context, not gates. Baseline and candidate must
be measured on the same host, Perl build, compiler/build flags, power/load
conditions, and benchmark configuration.

A benchmark-driven extraction is not complete until its decision is appended to
`bench/BENCHMARK-DECISIONS.md` and the actual machine-readable baseline,
candidate, and comparison outputs used for that decision are committed under
`bench/decisions/<decision-id>/`. Preserve rejected and neutral experiments as
carefully as successful ones. Historical entries whose original raw output is
unavailable must be marked as recovered summaries rather than presented as raw
evidence.

## Working hypothesis

Historical testing suggests that Linux::Event gets most of its speed from a
relatively small set of repeated operations:

- epoll readiness dispatch;
- draining read/write syscalls without repeatedly crossing into Perl;
- native input buffering and compaction;
- native frame boundary detection/parsing;
- processing multiple frames during one drain;
- native batching/coalescing where enabled;
- native partial-write/write-queue handling;
- keeping the async/native-consumer message path close to the buffer/framer.

By contrast, code that runs once per class, once per Stream, once per
connection, once per transition, once per close, or only when introspection is
requested is much less likely to justify a large native implementation.

## Historical evidence guiding the boundary

These observations are directional and must be re-measured under the realistic
payload rule above.

| Historical observation | What it suggests |
|---|---|
| Native framing was commonly about 85-103k msg/s versus roughly 45-67k msg/s for the XS-to-Perl framing path at 100 clients / 64-byte messages. | Frame parsing and repeated buffer scanning belong in native code, but the old 64-byte result alone is not enough to judge behavior at realistic payload sizes. |
| Direct callback/watch-fd awaitable experiments were substantially faster than a Stream-heavy awaitable path, and the gap changed with payload size. | Repeated abstraction and boundary work on the per-message path is expensive and must be tested from tiny through large messages. |
| Earlier Stream lifecycle measurements were materially slower than manual/raw lifecycle paths, but those costs were per connection rather than per established-message operation. | Connection setup/teardown can tolerate somewhat more Perl policy if established-stream throughput is preserved. |
| The permanent reactor comparison gives frameworks the same named Perl callback, while callback-ceiling diagnostics separately decompose native I/O, callback entry, and Perl read/write work. | Perl application callbacks are compatible with a fast reactor; avoid unnecessary crossings and Perl syscall/buffer work inside repeated I/O. |
| The release performance suite separates construction/lifecycle from established raw/framed Stream throughput. | Cold-path movement can be judged separately from hot established-connection cost. |
| Process pipe-drain work showed large native gains at small read sizes but near-neutral behavior at the normal 64 KiB case. | Frequency and payload size matter; do not generalize from one message/read size. |

## Protected native data plane

The following areas should remain XS/C by default unless a dedicated experiment
across the required payload matrix proves otherwise.

1. **epoll watcher dispatch and fd readiness handling**
   - direct watcher lookup/state checks;
   - readiness masks;
   - bounded dispatch machinery.

2. **Read drain loop**
   - repeated `read()` / transport reads;
   - EINTR/EAGAIN handling;
   - read budgets/fairness counters;
   - native activity timestamps.

3. **Native input storage**
   - append/grow/compact;
   - offsets and unread-byte preservation;
   - transition-safe buffered input.

4. **Framing/parsing**
   - delimiter scanning;
   - fixed/length/netstring/decimal/varint parsing;
   - frame extraction;
   - per-frame buffer position updates.

5. **Message batching and same-drain delivery mechanics**
   - frame loops;
   - message batch accumulation;
   - re-drive while buffered complete frames remain.

6. **Write queue and partial-write engine**
   - queued byte ownership;
   - `write`/`writev` handling;
   - partial segments;
   - EAGAIN/EINTR handling;
   - pending-byte accounting and watermarks.

7. **Native transport I/O**
   - plain transport syscall implementation;
   - OpenSSL read/write/handshake primitives;
   - transport operations that would otherwise require repeated Perl crossings.

8. **Native consumer per-message path**
   - provider `message()` dispatch;
   - pause/resume checks between frames;
   - the fast path used by `Linux::Event::Async`.

## First extraction candidates

| Candidate | Expected performance risk | Potential value | Initial direction |
|---|---|---|---|
| XSDescriptor argument decoding and declaration validation | Very low | High | Keep a compact immutable native descriptor, but move declaration/spec validation and normalization to Perl before constructing it. |
| Readable-sink and declaration invariant validation | Very low | Medium | Prefer one Perl-side policy implementation where possible, with native assertions only as defensive backstops. |
| Stream construction policy and failure orchestration | Very low to low | High | Keep fd/native-state creation primitives small; keep ownership/error sequencing in Perl. |
| Close/read-close/detach orchestration | Low for established throughput | Very high | Native code should perform small state/buffer/fd primitives; exception policy, callback ordering, cleanup guarantees, and ownership decisions belong in Perl where practical. |
| Error/lifecycle callback orchestration | Low | High | Keep native error detection; construct/report typed errors and decide lifecycle in Perl. |
| Descriptor transition eligibility/policy | Low | High | Keep native descriptor/framer swap and buffered-input continuation; move class/transport/option policy out of C. |
| Timeout/deadline policy | Low | Medium | Perl chooses deadlines/policy; native code supplies activity timestamps and Timer mechanics. |
| Transport setup/shutdown policy | Low to medium | Medium | Keep TLS/OpenSSL operations native; keep connection/handshake/shutdown policy in Perl when it is not repeated I/O. |
| `stats()` result formatting | Very low | Medium | Keep counters native; return a compact snapshot and build user-facing structures in Perl. |
| Test/conformance consumer implementation | None in production | Medium | Move test-only provider code out of production translation units. |
| Socket-specific validation/configuration glue | Very low | Medium | Keep syscalls in C only when required or measurably useful; prefer Perl policy/validation. |

## Candidate details

### 1. Descriptor construction: keep native representation, move policy out

The native descriptor is read repeatedly by the hot path, so replacing it with
Perl hash lookups would be the wrong direction. A likely smaller boundary is:

```text
Perl class declaration
  -> validate/normalize immutable spec
  -> XSDescriptor->new(compact validated spec)
  -> hot native descriptor
```

This pairs naturally with the named-descriptor-spec cleanup in
`STREAM-REVIEW-FOLLOWUPS.md`.

### 2. Lifecycle orchestration: shrink native close primitives

Recent Stream/Socket review work exposed disproportionate complexity around
close ordering, callback exceptions, terminal consumer flushes, ownership, and
reentrancy. Much of that is policy rather than data-plane work.

A reduction experiment should ask whether native close entry points can become
small primitives that:

- mark native read/write direction terminal;
- invalidate native fds;
- discard/finalize native buffers and queues;
- perform only terminal consumer work that must remain adjacent to native state;
- return enough status for Perl to complete watcher, handle, callback, and error orchestration.

Do not change consumer ABI semantics merely to reduce C code. Finish the
correctness and lifetime work first.

### 3. Transition policy: native mechanism, Perl decision

The parser must notice descriptor changes without entering Perl for every
frame, so the descriptor swap and preserved-input interpretation remain native.
Cold decisions such as target legality, Stream/Socket compatibility, timeout
policy, readable-sink validation, and user-facing errors should be Perl where
possible.

### 4. Stats/introspection: native counters, Perl presentation

Counters remain next to the native operations they count. Formatting them into
a Perl hash is not a hot-path requirement.

### 5. Transport control plane

TLS encryption/decryption and OpenSSL state transitions driven by readiness stay
native. Choosing when transport starts, timeout/error translation, public
lifecycle semantics, shutdown policy, and option validation should remain or
move to Perl when they are cold.

## Medium-risk candidates for later study

1. **Consumer flush/status machinery**
   - some operations are per drain or per message;
   - it is intertwined with `Linux::Event::Async` ABI semantics and reentrancy;
   - finish consumer lifetime/correctness work first.

2. **Outbound frame construction**
   - per-message prefix construction has shown material native wins;
   - configuration/template preparation can be Perl, but construction stays
     native until a full payload sweep proves otherwise.

3. **Callback dispatch wrappers**
   - cached native CV dispatch is part of the performance model;
   - do not replace it with repeated method lookup or closure layers.

4. **Activity/stat counter updates**
   - presentation can move to Perl;
   - increments and timestamps remain where the native event occurs.

## Explicit non-goals for the first phase

- Do not replace native framers with Perl framers.
- Do not move the read drain loop to Perl.
- Do not move queued-write/partial-write management to Perl.
- Do not introduce per-message object creation to make C code smaller.
- Do not replace cached native callback CVs with runtime method lookup.
- Do not redesign the public API merely to reduce native source lines.
- Do not weaken the native consumer path used by `Linux::Event::Async`.

## Measurement rules

Every extraction experiment must record both complexity reduction and runtime
cost.

### Complexity measurements

Record before/after:

- XS/C source lines removed;
- native functions removed or reduced;
- number of Perl/XS ownership boundaries;
- duplicated lifecycle/state-machine rules removed;
- number of native entry points capable of invoking Perl/provider code.

A change that merely moves the same complexity into another C file is not XS
reduction.

### Performance measurements

Use the permanent realistic payload rule above for any payload-sensitive
change. The quick matrix is acceptable during iteration; the full matrix is
required before accepting an architectural boundary change or merging a
performance-sensitive extraction.

At minimum run the relevant subset of:

```text
bench/run-performance-regression.pl
bench/run-stream-microbench.pl
bench/run-native-framers-microbench.pl
bench/run-callback-ceiling.pl          when callback boundaries change
bench/run-connect-microbench.pl        when connection policy changes
bench/run-listen-microbench.pl         when accept/construction changes
```

Also run the `Linux::Event::Async` comparison/compatibility benchmark whenever
consumer or Stream callback boundaries change.

Harnesses that currently test only one tiny payload should be extended or
paired with a payload-sweep harness before they are used to justify an
architectural decision.

Do not approve a hot-path regression merely because XS source shrank.

## Proposed experiment sequence

### Phase 0 - correctness and reduction baseline

1. Finish the correctness work in `STREAM-REVIEW-FOLLOWUPS.md` first.
2. Capture the full performance-regression baseline plus the full payload sweep.
3. Record current XS/C file sizes and approximate functional ownership.
4. Mark every Stream native function as one of:
   - per message/frame;
   - per read/write readiness;
   - per connection;
   - per transition;
   - per teardown;
   - introspection/debug only.

**Status (2026-09-02): complete.** `BD-2026-09-02-002` retains the seven-repeat
release baseline, full raw/Delimiter 64 B–200 KB sweep, complete effective
configuration, tracked native source sizes, functional ownership, and a
dominant-frequency category for all 146 detected Stream native functions.

### Phase 1 - cold-path reductions

Try independently, with one benchmarked commit per extraction:

1. descriptor declaration/spec validation;
2. stats result formatting;
3. construction/failure policy;
4. transition eligibility/policy;
5. close/error/lifecycle orchestration;
6. transport setup/shutdown policy.

Do not combine these initially; preserve attribution of both performance and
complexity changes.

**Extraction 1 status (2026-09-02): KEEP.** `BD-2026-09-02-003` moves the
29-field private descriptor-shape validation and scalar normalization into
Perl while retaining compact immutable native descriptors and defensive
native bounds, parser-memory, and consumer-table checks. It removes 61 native
lines and two native functions (13 net production lines after the Perl
policy), passes the core and real `Linux::Event::Async` suites, and is neutral
in adjacent established-Stream measurements. Deliberately rebuilding an
uncached descriptor costs about 7.1 microseconds more; normal construction
caches one descriptor per class.

**Extraction 2 status (2026-09-02): KEEP.** `BD-2026-09-02-004` keeps all
counters and snapshot reads native but moves the 49 public names and hash
presentation into Perl. It removes 28 native lines (two net production lines),
preserves the exact public key/value contract, and is neutral in adjacent
lifecycle and established-throughput measurements. The focused introspection
cost rises from about 3.4 to 5.0 microseconds per complete 49-key snapshot;
`stats()` is not called from readiness, framing, delivery, or teardown paths.

**Extraction 3 status (2026-09-02): KEEP.** `BD-2026-09-02-005` moves
readable-side construction policy ahead of a private validated native state
allocator, marks only an in-progress Perl construction for pre-cycle cleanup,
and keeps explicit cleanup where a native ownership cycle can already exist.
It also closes the adopted-Socket watcher-registration gap. Six native lines
move out; eight new regressions cover consumer creation and Socket attachment
failure without stranded objects or descriptors. The final narrowed guard is
within 3.6% on all Stream lifecycle/throughput rows.

**Extraction 4 status (2026-09-02): KEEP.** `BD-2026-09-02-006` moves target
consumer, readable-sink, preserved-input, and queued-output eligibility policy
into Perl. XS retains input-size overflow checks, replacement allocation,
atomic descriptor/buffer swap, and continuation. It removes 26 native lines;
established Stream rows remain within 3.3%. A dedicated 21-million-transition
comparison measures an isolated 0.96–1.21 microsecond cost per explicit swap,
with more than 160,000 transitions/second retained.

**Extraction 5 status (2026-09-02): RETAIN CURRENT BOUNDARY.** The Priority 1
correctness series already put close/error/lifecycle orchestration at the
intended boundary before the Phase 0 baseline: Perl owns first-exception
preservation, watcher and handle cleanup, typed error construction, callback
ordering, detach ownership, and transitive directional-close policy. Native
`_close` and `_close_read` retain only terminal state/buffer mutation plus the
consumer terminal flush/event sequence that must remain adjacent for the
documented reentrant ABI behavior; `_close_write` is a callback-free native
state/queue primitive. Regressions in `t/stream-61-teardown-exceptions.t`
exercise every callback-capable close shape. No further candidate was created:
moving the remaining terminal work would cross the explicitly protected
consumer semantic boundary, while merely relocating it between C files would
not reduce XS/C complexity. The retained boundary is covered by the Phase 0
performance/payload evidence and real Async compatibility results.

**Extraction 6 status (2026-09-02): RETAIN CURRENT BOUNDARY.** Transport
setup and shutdown already match the control-plane design. Perl validates
public TLS options, chooses client/server policy, enforces the shared-handle
rule, starts handshake and shutdown deadlines, translates transport results
into typed errors, and decides watcher/lifecycle action. Native code retains
the ABI table and pointer checks needed before dereferencing an external
provider, provider retention, readiness-driven transport operations, and one
`shutdown_write` operation returning a status tuple to Perl. The OpenSSL
provider likewise keeps only resource construction, cryptographic I/O/state,
BIO, and timerfd mechanics native. No further extraction candidate was
created: the remaining checks are native memory-safety backstops or the
protected repeated transport data plane. The Phase 0 full payload evidence
therefore remains the applicable performance record.

**Phase 1 status (2026-09-02): complete.** Extractions 1–4 were kept with
paired evidence. Extractions 5–6 were already at the target boundary due to
the preceding correctness and TLS architecture work, so their protected
native residue was retained without an artificial code movement.

### Phase 2 - consolidate the native data plane

After cold policy is extracted, reorganize remaining native Stream code around:

```text
epoll readiness
  -> transport read/write
  -> native buffer
  -> framer
  -> native message/batch delivery
  -> write queue
```

**Status (2026-09-02): in progress.** `BD-2026-09-02-007` centralizes the
callback-capable EOF/retry/error read-boundary rule: delivery work is settled
under the descriptor that produced the result, and re-drive occurs only for a
live, unpaused Stream whose descriptor changed. The compiler fully inlines the
helper with unchanged object text size; core, real Async, release, and full
payload gates pass. Consumer terminal and status semantics are unchanged.

### Phase 3 - reconsider medium-risk code

Only after the boundary is measured and stable should we test whether any
consumer flush, terminal handling, or outbound framing code can move further
out without measurable cost across the full payload range.

## Initial success criteria

The first XS-reduction series is successful if it:

- materially reduces Stream XS/C source and state-machine complexity;
- reduces callback/reentrancy/ownership logic implemented in C;
- makes native files easier to reason about individually;
- preserves native framing, drain, buffering, and write-queue advantages;
- produces no meaningful regression in established raw/framed Stream
  throughput or CPU cost across the required payload matrix through 200 KB;
- keeps `Linux::Event::Async` performance and ABI behavior intact;
- accepts small lifecycle cost only when the maintenance/correctness gain is
  clear and isolated to cold connection/teardown paths.
