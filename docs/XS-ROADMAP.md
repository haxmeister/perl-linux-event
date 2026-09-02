# XS Roadmap

Linux::Event is an XS-first Linux reactor with a Perl API. The guiding rule is:

> Perl should receive semantic events; XS should absorb repetitive mechanical
> events whenever doing so preserves a clean, general API.

The roadmap now has a second, equally important rule:

> Native code must earn its complexity. Keep repeated data-plane work native;
> prefer Perl for cold policy, lifecycle, validation, ownership orchestration,
> and presentation when paired benchmarks show no meaningful cost.

`docs/STREAM-REVIEW-FOLLOWUPS.md` defines the current Stream correctness work.
`docs/xs-reduction-roadmap.md` defines the deliberate program for shrinking the
native Stream surface after that correctness work is complete.

## Permanent benchmark rule - payload sizes through 200 KB

Tiny-message benchmarks are diagnostic tools, not sufficient evidence for an
architectural or performance decision. They expose fixed callback, dispatch,
and Perl/XS boundary overhead, but Linux::Event has also found important
performance differences only after testing payload sizes representative of web,
API, and other application traffic.

Any development work that can affect Stream payload processing, framing,
buffering, write queues, callback boundaries, native-consumer delivery,
transport I/O, copying, batching, or fairness must include payload sizes through
approximately 200 KB.

Standard sweeps:

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

A protocol-specific benchmark may substitute a nearby natural size, but it must
still cover tiny, medium, read-size-adjacent, and large payloads.

For medium and large payloads report MiB/s and CPU per byte or per MiB in
addition to messages/s. Also report reads/message, writes/message,
callbacks/message, p50/p99 latency, and buffering/high-water behavior whenever
the change can affect them.

Baseline and candidate must be measured on the same host, Perl build,
compiler/build flags, power/load conditions, and benchmark configuration.
Historical absolute numbers remain context, not acceptance thresholds.

## Completed native foundation - preserve unless evidence says otherwise

The performance-critical foundation includes:

- XS-first epoll loop and native watcher registry;
- direct native watcher dispatch and batched epoll processing;
- native Stream readable draining;
- reusable native framed-input storage;
- native immediate writes and segmented `writev()` queue draining;
- native backpressure accounting and output limits;
- specialized plain transport I/O plus the native TLS/OpenSSL provider path;
- native Delimiter, Fixed, LengthPrefix, U32BE, Netstring, Varint, and
  DecimalLength framing;
- native callback/message batching where explicitly enabled;
- immutable per-class callback/framer/transport descriptors with lightweight
  per-connection references;
- protocol transitions that preserve unread native input and queued output;
- native Timer/timerfd scheduling, Signal/signalfd fan-out, Wakeup/eventfd,
  Resolver workers/completion queue, Listener accept drain, Datagram packet
  mechanics, pidfd Process completion, and the Process pipe-drain helper where
  measurement justified it.

These are permanent regression targets, but "completed" does not mean every
piece of surrounding control-plane code must remain in XS.

## Permanent architectural boundaries

### Reactor hot path

Keep native by default:

- epoll readiness lookup and dispatch;
- watcher active/mask checks;
- repeated read/write syscalls and EAGAIN/EINTR loops;
- native buffers and frame scanning;
- same-drain frame processing and batching;
- partial-write/write-queue mechanics;
- TLS/OpenSSL operations driven repeatedly by readiness;
- native-consumer per-message delivery used by `Linux::Event::Async`.

### Perl control plane

Prefer Perl by default for:

- class/configuration policy;
- validation and normalization;
- construction/failure orchestration;
- connection candidate policy;
- lifecycle/error policy;
- teardown ownership decisions;
- timeout policy and user-facing errors;
- stats/introspection presentation;
- protocol/application semantics above message framing.

### Async boundary

Future, Promise, and async/await policy remain outside Linux::Event core and
belong in separate distributions such as `Linux::Event::Async`.

Core does own the correctness, lifetime, reentrancy, and versioning contract of
its generic native-consumer ABI. That is a reactor extension boundary, not
Future-specific policy.

## Priority 0 - stabilize Stream/native-consumer correctness

Complete `docs/STREAM-REVIEW-FOLLOWUPS.md` before further XS expansion or
reduction.

Current blockers include:

- exception-safe callback-capable teardown;
- a coherent exported consumer host/provider lifetime contract;
- generic Stream construction-failure ownership cleanup;
- old-protocol consumer flush ordering across descriptor transitions;
- coherent consumer message/flush/terminal status semantics.

Status as of 2026-09-01: all five blockers above are implemented with targeted
core regressions, and the lifetime/status contract has passed the real
`Linux::Event::Async` suite. The semantic decision preserves immediate
flush-owed message entry, reentrant terminal flush, and operation-sensitive
`CONTINUE` behavior.

Do not simplify or move the consumer ABI boundary until its ownership contract
is sound and cross-tested with `Linux::Event::Async`.

## Priority 1 - cold/control-plane XS reduction

After Priority 0, execute `docs/xs-reduction-roadmap.md` one independent,
benchmarked extraction at a time.

Initial targets:

1. descriptor declaration/spec validation and normalization;
2. stats result formatting;
3. construction/failure policy;
4. transition eligibility/policy;
5. close/error/lifecycle orchestration;
6. transport setup/shutdown policy.

The goal is a smaller native core organized around operations that actually
need to be native, not merely fewer files.

**Phase 0 baseline status (2026-09-02): complete.** The full release suite,
full nine-size raw/framed payload sweep, resolved benchmark configuration, and
per-file/function native ownership inventory are recorded under
`BD-2026-09-02-002`. Each extraction remains an independent paired decision.

**Extraction 1 status (2026-09-02): KEEP.** Descriptor specification shape and
normalization now live on the Perl cold path. Native code retains the immutable
runtime descriptor and memory/ABI safety checks. `BD-2026-09-02-003` records
the paired release, full payload, focused cold-construction, correctness, and
complexity evidence. Proceed independently with stats result formatting.

**Extraction 2 status (2026-09-02): KEEP.** Native code now returns a compact
ordered counter snapshot and Perl owns the named public hash presentation.
`BD-2026-09-02-004` records the direct introspection cost, adjacent release
suite, full payload sweep, correctness, and complexity evidence. Proceed
independently with construction/failure policy.

**Extraction 3 status (2026-09-02): KEEP.** Stream readable-side construction
policy and incomplete-construction cleanup now live in Perl around a private
validated native allocator. `BD-2026-09-02-005` also records and fixes an
adopted-Socket watcher-registration ownership gap, with core and real Async
coverage. Proceed independently with transition eligibility/policy.

**Extraction 4 status (2026-09-02): KEEP.** Perl now owns transition target
eligibility and limit policy; native code owns overflow safety, allocation,
atomic swap, and buffered-input continuation. `BD-2026-09-02-006` records the
direct transition cost, adjacent release suite, full payload sweep, and real
Async coverage. Proceed independently with close/error/lifecycle orchestration.

## Priority 2 - consolidate the remaining native Stream data plane

After cold policy extraction, organize the native Stream implementation around:

```text
epoll readiness
  -> transport read/write
  -> native buffer
  -> framer
  -> native message/batch delivery
  -> write queue
```

Reduce duplicated ownership and callback-capable state-machine logic. Do not
move hot work into Perl merely to reduce source lines.

## Priority 3 - preserve and extend realistic benchmarking

Existing harnesses remain useful, but any harness used to justify a Stream
architecture decision must obey the permanent payload rule through 200 KB.

The performance-regression suite should remain the release-level same-contract
gate. Specialized diagnostics may isolate callbacks, framing, lifecycle,
watcher state, or transport mechanics, but final decisions require an
end-to-end Stream workload as well.

Historical 64-byte results must be labelled for what they are: stress tests of
fixed per-message overhead. They must not be generalized to realistic medium
or large messages without a payload sweep.

## Priority 4 - watcher-state transitions: measured, leave closed

The watcher-state boundary was profiled before adding a cross-extension watcher
ABI. The measured `EPOLL_CTL_MOD` portion of forced-EAGAIN cycles was small
relative to overall Stream coordination cost, and ordinary attachment/close did
not show a compelling repeated transition problem.

Do not add a cross-extension watcher ABI unless a representative application
profile shows the remaining boundary is material.

## Priority 5 - callback coalescing/batching: implemented, keep native

Historical pipelined 64-byte tests showed large gains from explicit framed
batching and callback-count reduction. Those tests prove that callback
amortization can matter; they do not establish the best batch behavior for
larger application messages.

Keep batching mechanics native, but evaluate any future tuning or default
change across the standard payload sweep through 200 KB and include fairness
and latency measurements.

## Priority 6 - native connect completion: closed absent new evidence

The 2026-08-29 experiment moving the readiness-time `SO_ERROR` probe native did
not produce a reproducible win: the small aggregate advantage disappeared in
paired analysis and the special path was removed.

Ordinary successful single-candidate connection completion should remain in
Perl. Reopen only for a workload dominated by multiple simultaneous Happy
Eyeballs attempts, failed candidates, or deadline cancellation, and move that
coordination as one measured unit rather than relocating one syscall.

## Priority 7 - Linux fd drain helpers: evidence-driven only

The Process stdout/stderr experiment is a model for this boundary. Native drain
loops produced meaningful gains at small reads, while the normal 64 KiB case
was essentially neutral overall. The retained helper therefore moves only the
repetitive mechanical drain and leaves Process policy in Perl.

Do not add generic drain APIs or move semantic callback policy native merely
because a syscall loop can be written in C.

## Priority 8 - buffer representation experiments

Only if profiling justifies them:

- sliding-buffer refinements;
- ring-buffer alternatives;
- allocation reuse or slabs.

Native buffering itself is protected hot-path territory. Do not optimize
allocation speculatively, and benchmark across the full payload matrix.

## Priority 9 - additional native framing families, demand-driven

Existing native framing remains a protected performance feature. Expanding the
catalog is no longer the first active priority because every new native parser
increases maintenance surface.

Potential future general families include:

- configurable `HeaderLength`;
- additional standardized variable-integer prefixes;
- SLIP/COBS or other broadly useful escaped/stuffed framing.

Add a family only for a demonstrated general-purpose use case. Require wire
contract tests and the full payload benchmark matrix, not a tiny-message result
alone.

## Priority 10 - protocol acceleration above Stream, demand-driven

Reusable mechanical HTTP/WebSocket or similar parsing may eventually justify a
native engine. Application semantics remain Perl even when mechanical parsing
is native.

Do this only after the Stream native boundary has been reduced and stabilized;
do not grow protocol-specific C while simultaneously trying to understand and
shrink the Stream core.

## Benchmark interpretation rules

1. No architectural conclusion from one payload size.
2. No architectural conclusion from messages/s alone when payload size is
   medium or large.
3. Tiny-message tests measure fixed event/callback/boundary overhead.
4. Medium/large tests measure copying, buffering, syscall amortization,
   multi-read/multi-write behavior, and byte throughput.
5. Use paired baseline/candidate runs under identical conditions.
6. Preserve correctness and fairness metrics alongside throughput.
7. A small cold-path regression can be acceptable for a substantial
   correctness/maintenance win only when established data-plane performance is
   unchanged and the cost is explicitly documented.
8. Every benchmark-driven decision must be appended to
   `bench/BENCHMARK-DECISIONS.md`, and the actual machine-readable evidence used
   to make the decision must be committed under `bench/decisions/<decision-id>/`.
   Rejected and neutral experiments are retained, not discarded.

## Current execution order

1. Finish Stream/native-consumer correctness and lifetime stabilization.
2. Capture a baseline including the full 64 B -> 200 KB payload sweep.
3. Execute cold/control-plane XS reduction experiments independently.
4. Consolidate the remaining native Stream data plane.
5. Reconsider medium-risk native code only after the boundary is measured and
   stable.
6. Reopen buffer, framing-family, or protocol-acceleration work only when
   profiling or a real application requirement justifies it.
