# Linux::Event XS Reduction Roadmap

This document starts a deliberate effort to reduce the amount of XS/C code in
Linux::Event without giving back the performance advantages that justified the
native implementation.

The goal is not "less XS at any cost." The goal is to keep the native data
plane small, obvious, and fast, while moving cold policy, validation, lifecycle,
and presentation work back to Perl when benchmarks show that doing so is
performance-neutral or close enough to neutral to justify the maintenance win.

This roadmap is intentionally conservative. Every extraction is an experiment
with a before/after performance gate and regression coverage.

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

These are directional observations from prior Linux::Event development, not
permanent acceptance baselines. Current decisions must use paired measurements
on the same machine and build.

| Historical observation | What it suggests |
|---|---|
| Native framing was commonly about 85-103k msg/s versus roughly 45-67k msg/s for the XS-to-Perl framing path at 100 clients / 64-byte messages. | Frame parsing and repeated buffer scanning belong in native code. |
| The direct callback/watch-fd awaitable path measured about 225k / 65k / 17k msg/s at roughly 2.5K / 35K / 200K payloads, while the Stream-based awaitable was roughly half as fast in the same line of experiments. | Repeated abstraction and boundary work on the per-message path is expensive; protect it carefully. |
| Earlier Stream lifecycle measurements were materially slower than manual/raw lifecycle paths, but those costs were per connection rather than per established-message operation. | Connection setup/teardown can tolerate somewhat more Perl policy if established-stream throughput is preserved. |
| The permanent reactor comparison intentionally gives Linux::Event and competitors the same named Perl echo callback, while `run-callback-ceiling.pl` separately decomposes native echo, empty callback entry, and normal Perl read/write work. | Perl application callbacks are compatible with a fast reactor; the key is avoiding unnecessary crossings and Perl syscall/buffer work inside the repeated I/O path. |
| The current release performance suite measures construction/lifecycle separately from raw/framed established Stream throughput. | XS-reduction experiments can be judged independently for cold lifecycle cost and hot established-connection cost. |

The repository benchmark guide and current harnesses should be treated as the
canonical way to re-measure these claims. Historical values above are context,
not gates.

## Protected native data plane

The following areas should be assumed to remain XS/C unless a dedicated
experiment demonstrates otherwise.

### Keep native by default

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

These are the places where historical measurements have repeatedly shown that
an extra Perl layer can matter.

## First extraction candidates

These are the best starting candidates because they are cold, already partly
policy-oriented, or have no evidence that native execution materially improves
established Stream throughput.

| Candidate | Expected performance risk | Potential value | Initial direction |
|---|---|---|---|
| XSDescriptor argument decoding and declaration validation | Very low | High | Keep a compact immutable native descriptor, but move more declaration/spec validation and normalization to Perl before constructing it. |
| Readable-sink and declaration invariant validation | Very low | Medium | Prefer one Perl-side policy implementation where possible, with native assertions only as defensive backstops. |
| Stream construction policy and failure orchestration | Very low to low | High | Keep fd/native-state creation primitives small; keep ownership/error sequencing in Perl. |
| Close/read-close/detach orchestration | Low for established throughput | Very high | Native code should perform small atomic state/buffer/fd primitives; exception policy, callback ordering, cleanup guarantees, and ownership decisions belong in Perl where practical. |
| Error/lifecycle callback orchestration | Low | High | Keep native error detection; construct/report typed errors and decide lifecycle in Perl. |
| Descriptor transition eligibility/policy | Low | High | Keep native descriptor pointer/framer swap and buffered-input continuation; move class/transport/option policy out of C. |
| Timeout/deadline policy | Low | Medium | Continue the existing model: Perl chooses deadlines/policy, native code supplies activity timestamps and the Timer core. Move any remaining Stream-specific scheduling policy out of XS where possible. |
| Transport setup/shutdown policy | Low to medium | Medium | Keep TLS/OpenSSL operations native; keep connection/handshake/shutdown state policy in Perl when it is not part of a repeated read/write loop. |
| `stats()` result formatting | Very low | Medium | Keep counters native; expose a compact snapshot and build user-facing hash/structure in Perl rather than maintaining large native `hv_stores` code. |
| Test/conformance consumer implementation | None in production | Medium | Move test-only provider code out of production translation units. This reduces native production complexity even though it does not change runtime behavior. |
| Socket-specific validation/configuration glue | Very low | Medium | Keep syscalls that need C only when they are measurably better or required; prefer Perl policy and option validation. |

## Candidate details

### 1. Descriptor construction: keep native representation, move policy out

The native descriptor is read repeatedly by the hot path, so replacing it with
Perl hash lookups would be the wrong direction.

However, the large native constructor does not need to own all validation and
normalization. A likely smaller boundary is:

```text
Perl class declaration
  -> validate/normalize immutable spec
  -> XSDescriptor->new(compact validated spec)
  -> hot native descriptor
```

This should pair naturally with the named-descriptor-spec cleanup already on
the Stream review roadmap.

### 2. Lifecycle orchestration: shrink native close primitives

The recent Stream/Socket reviews exposed disproportionate complexity around
close ordering, callback exceptions, terminal consumer flushes, ownership, and
reentrancy. Much of this is policy rather than data-plane work.

A reduction experiment should ask whether native close entry points can become
small primitives such as:

- mark native read/write direction terminal;
- invalidate native fds;
- discard or finalize native buffers/queues;
- perform only the terminal consumer operation that must remain adjacent to
  native consumer state;
- return enough state/status for Perl to complete watcher, handle, callback,
  and error orchestration.

Do not change consumer ABI semantics merely to reduce C code. Correctness work
on `fix/review-bugfix-simplify` comes first.

### 3. Transition policy: native mechanism, Perl decision

The parser must still notice descriptor changes without bouncing through Perl
for every frame. The actual descriptor swap and preserved-input interpretation
therefore remain native candidates.

But these decisions are cold:

- whether the target class is legal;
- whether Stream/Socket boundaries are compatible;
- timeout-policy changes;
- readable-sink validation;
- user-facing transition errors.

Keep those decisions in Perl where possible.

### 4. Stats/introspection: native counters, Perl presentation

Counters must remain next to the operations they count. Formatting those
counters into a Perl hash is not a hot-path requirement.

An experiment can compare:

```text
current: C builds full stats hash
candidate: C returns compact snapshot -> Perl names/formats fields
```

This is especially attractive if the embedded `les_xsstats_t` cleanup is done
first.

### 5. Transport control plane

TLS encryption/decryption and OpenSSL state transitions that must be driven by
read/write readiness should remain native.

The surrounding policy is a different question:

- choosing when a transport starts;
- timeout/error translation;
- public lifecycle semantics;
- shutdown policy;
- option validation.

Where those paths occur once per connection or shutdown, Perl is the preferred
home unless benchmarks say otherwise.

## Medium-risk candidates for later study

Do not start here.

1. **Consumer flush/status machinery**
   - Some operations are per drain or per message.
   - It is intertwined with `Linux::Event::Async` ABI semantics and reentrancy.
   - First finish the consumer lifetime/correctness work, then measure whether
     any terminal/cold portion can move out while the message path remains C.

2. **Outbound frame construction**
   - Historical framing work shows meaningful wins from native framing.
   - The recent LengthPrefix whole-call optimization result was also material.
   - Configuration/template preparation can be Perl, but actual per-message
     prefix construction should remain native until a direct experiment says
     otherwise.

3. **Callback dispatch wrappers**
   - Cached native CV dispatch is part of the performance model.
   - Simplify code structure if possible, but do not replace direct cached-CV
     calls with repeated method lookup or closure layers on hot paths.

4. **Activity/stat counter updates**
   - Presentation can move to Perl; increments and timestamps should remain
     where the native event occurs.

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

Use paired baseline/candidate runs on the same machine, Perl build, compiler,
and power/load conditions.

At minimum run:

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

The permanent performance-regression harness already separates construction,
lifecycle, raw Stream throughput, framed Stream throughput, deadlines, and
connect/listen lifecycle. Use that separation to distinguish an acceptable
cold-path change from an unacceptable established-message regression.

Do not approve a hot-path regression merely because XS source shrank.

## Proposed experiment sequence

### Phase 0 - establish a reduction baseline

1. Finish the correctness work in `STREAM-REVIEW-FOLLOWUPS.md` first.
2. Capture the full performance-regression baseline.
3. Record current XS/C file sizes and approximate functional ownership.
4. Mark every Stream native function as one of:
   - per message/frame;
   - per read/write readiness;
   - per connection;
   - per transition;
   - per teardown;
   - introspection/debug only.

This frequency map should drive extraction order.

### Phase 1 - cold-path reductions

Try independently, with one benchmarked commit per extraction:

1. descriptor declaration/spec validation;
2. stats result formatting;
3. construction/failure policy;
4. transition eligibility/policy;
5. close/error/lifecycle orchestration;
6. transport setup/shutdown policy.

Do not combine these initially. We want to know which movement costs anything.

### Phase 2 - consolidate the native data plane

After cold policy is extracted, reorganize the remaining native Stream code
around a smaller conceptual core:

```text
epoll readiness
  -> transport read/write
  -> native buffer
  -> framer
  -> native message/batch delivery
  -> write queue
```

The desired result is not merely fewer lines; it is a native core whose files
mostly correspond to operations that actually need to be native.

### Phase 3 - reconsider medium-risk code

Only after the boundary is measured and stable should we test whether any
consumer flush, terminal handling, or outbound framing code can move further
out without measurable cost.

## Initial success criteria

The first XS-reduction series is successful if it:

- materially reduces Stream XS/C source and state-machine complexity;
- reduces callback/reentrancy/ownership logic implemented in C;
- makes native files easier to reason about individually;
- preserves the native framing, drain, buffering, and write-queue advantages;
- produces no meaningful regression in established raw/framed Stream
  throughput or CPU cost;
- keeps `Linux::Event::Async` performance and ABI behavior intact;
- accepts small lifecycle cost only when the maintenance/correctness gain is
  clear and the cost is isolated to cold connection/teardown paths.

## Starting recommendation

The safest first real reduction experiment after the current review fixes is:

1. move descriptor declaration/validation work toward Perl while preserving the
   compact native descriptor;
2. move stats presentation out of XS;
3. then prototype a smaller native lifecycle/close primitive with Perl owning
   orchestration.

Those three should give us useful evidence about how much XS can be removed
before touching the native operations that historical testing has shown to be
responsible for Linux::Event's throughput.
