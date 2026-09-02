# Linux::Event Stream/Socket Review Roadmap

This is the reconciled code-only roadmap after review of:

- `feature/stream-socket-split`
- `fix/stream-socket-review` (`2681a0c`)
- PR #9 / `refactor/stream-simplify`
- the independent reviews of both branches
- direct verification against the current core and `Linux::Event::Async` consumer implementation

The intended continuation branch is `fix/review-bugfix-simplify`.

Do not merge PR #9 unchanged. Use `fix/stream-socket-review` as the correctness baseline, then carry only the verified fixes and worthwhile simplifications forward.

Documentation and packaging work are intentionally excluded from this roadmap.

## Working rules

1. Every correctness claim needs a targeted regression that fails without the fix.
2. Any change that adds/removes work on a per-message, per-write, per-frame, or per-readiness path needs a before/after hot-path benchmark.
3. Preserve externally visible Stream and native-consumer semantics unless a change is explicitly designed, tested, and cross-checked against `Linux::Event::Async`.
4. Prefer removing duplicated state-machine rules over adding more local guards.
5. Performance decisions must not be based on tiny-message benchmarks alone. Any Stream, framing, buffering, write-queue, callback-boundary, native-consumer, or transport-I/O change that could affect payload processing must include representative message sizes through 200 KB.
6. Every benchmark-driven engineering decision must be recorded in `bench/BENCHMARK-DECISIONS.md`, with the actual machine-readable baseline/candidate evidence committed under `bench/decisions/<decision-id>/`. Rejected and neutral experiments are retained too.

## Priority 1 - remaining correctness and lifetime blockers

**Status (2026-09-01): complete on `fix/review-bugfix-simplify`.** The tested
`2681a0c` baseline was carried forward first. The four items below now have
targeted regressions in `t/stream-61-teardown-exceptions.t` through
`t/stream-64-transition-consumer-flush.t`. The exported lifetime contract was
also exercised through a real `Linux::Event::Async` provider build and full
cross-repository suite. The current reentrant message/terminal-flush behavior
was intentionally preserved; its separate semantic decision remains Priority
2 work.

### 1. Make callback-capable teardown exception-safe

The current Perl lifecycle can mark an object terminal, invoke native terminal consumer work, and then fail before watcher/handle teardown if provider code throws.

This is proven for full `close()` and applies to any lifecycle path that invokes callback-capable native terminal dispatch before finishing ownership teardown.

Required invariant:

> Once terminal teardown begins, required watcher, fd, handle, and ownership cleanup must complete even if terminal provider/application code throws.

Apply this invariant to:

- full `close()` / `_close_now()`
- `close_read()`
- `detach()`

The native `_close_write` path itself does not perform consumer terminal flush/event dispatch, so it needs no separate native exception-safety fix. However, public `close_write()` can call `_close_now(1)` when the read side is already terminal, so it reaches the proven full-close bug transitively. Cover that call path in the teardown regression matrix.

Implementation direction:

- capture the first exception from callback-capable native terminal dispatch;
- always complete required watcher cancellation and handle/ownership teardown;
- define and test whether `on_close` still runs when an earlier terminal provider callback threw;
- preserve the original exception after teardown unless a more fundamental teardown failure must take precedence.

Required regressions:

- terminal consumer `event()` throws during full close;
- terminal consumer `flush()` returns `LES_CONSUMER_ERROR` during full close;
- the same two failure shapes through `close_read()` where applicable;
- terminal provider work throws during `detach()`;
- `close_write()` with an already-terminal read side reaches `_close_now()` and still completes teardown if terminal provider work throws;
- assert no fd leak, no live watcher/epoll registration, correct final object state, and exception propagation.

For `detach()`, define the failure-state contract explicitly. If native terminal dispatch throws, the object must not be left apparently live with watchers/handles but no XS state. Because an exception prevents normal handle return, ownership must still resolve deterministically: either retain a coherent detachable object or close/release the handles as part of failed teardown. No watcher or fd may be stranded.

### 2. Define and enforce the exported consumer host/provider lifetime contract

The core XSUB `_consumer_resume` is guarded, but that does not protect the native-consumer host API as a whole.

The ABI gives external providers a host table containing `resume(host_context)`. `Linux::Event::Async` already calls that host function directly from its own XS receive-arm path, so the call can enter `les_consumer_resume(st)` without passing through the guarded core `_consumer_resume` XSUB.

The lifetime hole is broader than the duration of the core `resume()` call. `Linux::Event::Async` continues to read its provider `ctx` and can call another host-table function after `resume()` returns. Synchronous delivery inside `resume()` may invoke provider/user code that closes the Stream, allowing core XS state and provider context destruction while the provider's own calling frame is still active. A core-side guard that keeps only `les_xsstate_t` alive until `resume()` returns therefore cannot by itself make the provider's post-call accesses safe.

Treat this as an ABI ownership/lifetime design decision before implementation.

Required work:

- state the lifetime invariant for every exported host-table entry point, not only `resume()`;
- audit every host function for callback/reentrancy and post-callback state access; `resume()` is the known live case, while `pause()` is currently safe only because its callback-capable notification is the last stateful action;
- ensure a provider can make a synchronous/reentrant host call without losing either the host object/context or the provider context underneath its active C frame;
- do not require third-party consumers to know private `les_xsstate_t` details;
- evaluate designs such as a stable/generation-checked host handle, a supported provider-held lifetime reference, or another explicit ownership mechanism. Merely returning a closed bit from `resume()` is not sufficient if the provider context itself can already have been destroyed;
- preserve ABI-v1 append-only/versioning rules unless an intentional ABI revision is chosen;
- add a cross-repository regression using the real `Linux::Event::Async` path: provider XSUB -> host `resume()` -> synchronous message -> user closes Stream -> provider frame continues and returns safely.

Keep the existing XSUB guards; they are still useful for core entry points.

### 3. Complete generic Stream construction-failure cleanup

`Socket` construction cleanup and Listener accepted-fd cleanup are now validated and should be preserved.

The remaining generic case is `Stream->new(loop => ...)` after XS state creation when watcher registration/attachment fails. The constructor must not strand the Perl <-> XS state ownership cycle or owned handles. This does not conflict with Priority 15: on a failed construction/attachment path there is no successful loop-owned Stream lifetime to preserve, so explicitly breaking the partial cycle is safe and required. On a successfully attached Stream, the existing cycle remains part of the current lifetime mechanism until an ownership redesign replaces it.

Required regression:

- deliberately force watcher registration failure after XS state creation;
- verify fd delta returns to zero and no Stream/XS state remains stranded.

Also audit pending `Socket->connect()` ownership for equivalent failure cycles, but do not claim a bug without a reproducer.

### 4. Flush deferred consumer work at a protocol-change boundary

If a message callback calls `transition_to()` while the old protocol still owes a consumer flush, parsing can continue under the new descriptor before the old protocol's deferred consumer work is flushed.

Keep `les_transition_descriptor()` callback-free.

Fix the parser boundary instead:

- detect that message delivery changed the descriptor;
- flush consumer work owed by the old parsing phase;
- only then continue buffered input under the new descriptor.

Required regression:

- prove the old protocol's flush occurs before the first message delivered under the new protocol.

## Priority 2 - native consumer semantics and simplification

**Status (2026-09-01): complete.** Message entry remains immediately
flush-owed, including reentrant terminal flush before `message()` returns.
Provider statuses are now validated unconditionally before terminal lifecycle
application is skipped, ordinary and terminal pending-flush calls share one
mechanic, the operation-sensitive `CONTINUE` behavior is covered explicitly,
and the resumed-with-buffered-input rule has one predicate.

### 5. Reconcile `message`, flush, and terminal status handling as one coherent change

`les_consumer_message()`, `les_consumer_flush()`, and `les_consumer_flush_terminal()` should be simplified together because their state/status rules are coupled.

First decide one semantic question explicitly:

> Does a successfully entered `message()` become flush-owed immediately, including if it reentrantly closes the Stream before `message()` returns, or only after `message()` returns successfully?

The current ABI explicitly permits a reentrant terminal flush while `message()` is still on the stack. Therefore simply moving `consumer_flush_pending = 1` after `message()` is not a behavior-preserving cleanup.

Until that decision is made, do not remove `JMPENV` merely for aesthetics.

Regardless of the chosen ordering:

- validate every provider status value unconditionally;
- separate status validation from status application;
- after validation, do not apply ordinary pause/resume/close transitions if the Stream became terminal during the provider call;
- factor a shared helper for the duplicated "call pending flush and validate result" mechanics;
- keep ordinary-vs-terminal post-flush behavior separate.

At a terminal boundary, valid `CONTINUE`, `PAUSE`, and `CLOSE` are intentionally advisory/no-op lifecycle results because the Stream is already becoming terminal. `ERROR` and invalid values remain provider failures.

### 6. Preserve current CONTINUE semantics unless deliberately changed

Current behavior is:

- `message -> CONTINUE`: does not clear an existing pause;
- `flush -> CONTINUE`: may clear consumer pause and resume delivery.

Do not import PR #9's blanket "CONTINUE is always a no-op" change without an explicit ABI decision.

Before changing this contract, specify and test the interaction of:

- host `pause()`
- host `resume()`
- `message -> CONTINUE`
- `message -> PAUSE`
- `flush -> CONTINUE`
- `flush -> PAUSE`

Cross-test the result against `Linux::Event::Async`.

### 7. Factor the resumed-with-buffered-input predicate

The condition describing "consumer was paused, flush resumed it, Stream remains live, and buffered input remains" appears in multiple paths.

Move it behind one small helper/predicate so read-boundary and existing-input behavior cannot drift.

## Priority 3 - completed fixes to preserve, with duplication cleanup

**Status (2026-09-02): complete.** The `2681a0c` hardening remains covered,
and construction plus transition now use one readable-sink validation helper.

### 8. Preserve the verified hardening from `2681a0c`

Keep:

- terminal flush-before-event ordering;
- terminal event as the last callback-capable action in `_close` / `_close_read`;
- guarded XSUB paths that can reenter Perl/provider code and then continue touching XS state. Current audit: guarded `_read_ready`, `_write`, `_write_ready`, `_transition`, `_close`, `_close_read`, `_consumer_resume`, `_test_consumer_arm`; intentionally unguarded but currently benign `DESTROY` and `_test_consumer_cancel` because neither continues touching live context after its callback-capable final action;
- re-drive after `flush -> CONTINUE` releases consumer backpressure;
- directional native fd invalidation and explicit `EBADF` protection;
- Socket construction cleanup and Listener accepted-fd cleanup;
- defensive NULL callback checks;
- purpose-built native test consumers and sequence-order assertions.

Do not re-import duplicate Stage-1 fixes from PR #9.

### 9. Centralize readable-sink validation

The original construction/transition sink bug is fixed in both places.

What remains is duplication risk: construction and transition independently encode the same readable-sink rule.

Factor one internal helper such as `les_require_read_sink()` and use it from both sites.

This is cleanup/hardening, not an open correctness bug.

Implemented by `les_require_read_sink()`, with construction and raw/framed
transition diagnostics retained and tested.

## Priority 4 - simplifications worth salvaging from PR #9

### 10. Named XSDescriptor specification

Replace the large positional `XSDescriptor::new` argument list with a named hash/spec and reject unknown fields.

This is cold construction code, so maintainability and correctness are more important than avoiding hash lookup during descriptor creation.

**Status (2026-09-02): complete.** The private XS constructor now accepts one
named specification, rejects unknown and missing fields, and retains the
existing descriptor validation after extraction.

### 11. Framer fast paths

Keep the worthwhile native framer simplifications:

- pre-resolve LengthPrefix template/width/endian information;
- Varint `< 128` one-octet fast path;
- other clearly equivalent local parser simplifications.

Require byte-equivalence boundary tests and an end-to-end benchmark before merging. Historical review measurement for the LengthPrefix template pre-resolution was about 1.85x for the whole `_frame` call (roughly 1.19M/s -> 2.19M/s on that reviewer's machine). Do not use the earlier ~6.3x bare-`pack` micro-operation number as the expected end-to-end gain.

**Status (2026-09-02): complete, KEEP.** Boundary tests cover all supported
LengthPrefix widths/endianness and Varint width transitions. The full
64 B–200 KB `Stream->send()` sweep is recorded as `BD-2026-09-02-001`;
LengthPrefix improved 25–31% through 4 KB, Varint improved 16.6% at 64 B, and
the largest rows remained neutral within queue/drain scheduling variance.

### 12. Split test-only native consumer code from production consumer code

Move the private conformance/test provider into its own translation unit.

Keep test-only providers unavailable to normal runtime declaration paths.

### 13. Rework stats organization as an embedded struct

Keep the maintainability win:

- one `les_xsstats_t` definition;
- one counter-name/offset table;
- table-driven `stats()` export;
- optional `LES_STAT()` macro if it improves readability.

Do not use the PR #9 pointer/tail-allocation form merely for cache-layout reasons. The counters already live after the hot write fields, and the branch allocates the stats block unconditionally anyway.

Preferred first form:

```c
les_xsstats_t stats;
```

embedded at the tail of `les_xsstate_t`.

Any separate allocation/pointer version requires a demonstrated end-to-end win.

## Priority 5 - future write-path experiments

### 14. Preserve write value semantics in any zero-copy/COW experiment

Current queued writes own their bytes. A caller may modify or release the scalar supplied to `write()` immediately without changing bytes already queued.

Do not replace that with a borrowed/refcounted caller SV that aliases mutable application memory.

Potential experiments:

- an owned/COW-safe SV representation;
- native length-prefix construction queued as its own internal segment;
- other segment representations that preserve snapshot/value semantics.

Treat this as a separate benchmarked experiment, not part of the correctness merge.

## Priority 6 - architectural limitation to leave alone for now

### 15. Loop-attached Stream lifetime ownership

The Stream <-> XS-state retention cycle is currently part of the lifetime mechanism for loop-attached Streams.

Do not weaken it locally just to make constructed-and-dropped objects disappear; that risks freeing a live Stream still operationally owned by the loop.

If this becomes a target, solve it as an explicit loop-owned registry/ownership redesign and measure lifecycle/hot-path cost separately.

## Removed or demoted claims

The following should not remain as open correctness items without new evidence:

- **Deadline timer replacement/cancellation bug:** not demonstrated. One-shot timers are removed from the heap before callback, are `FIRING`/active during the callback so they can be rescheduled in place, and release loop ownership when finally expired. `refaddr` may still be stylistic hardening, but there is no current basis for a correctness fix.
- **Post-terminal-event recheck in `_close` / `_close_read`:** stale after moving terminal event dispatch to the end; there is no subsequent XS state work to protect there.
- **Readable sink validation as an open bug:** both construction and transition checks now exist; only deduplication remains.
- **`flush_terminal -> CLOSE` as an unhandled bug:** valid terminal `CONTINUE`/`PAUSE`/`CLOSE` results are intentionally lifecycle no-ops at an already-terminal boundary.
- **native `_close_write()` as the same callback-exception teardown bug:** its native path performs no consumer terminal dispatch and needs no separate fix. Public `close_write()` can still enter `_close_now()` when the read side is already terminal, so that transitive call path belongs in the full-close regression matrix.

## Required validation gate before merge

### Correctness regression status

Completed in the Priority 1 implementation:

1. exception-safe full close, `close_read`, failed `detach`, and transitive
   `close_write` teardown;
2. terminal provider `event` exceptions and terminal flush `ERROR` while
   teardown still completes;
3. exported host/provider reentrancy and lifetime through synchronous
   `resume()`, including a real `Linux::Event::Async` cross-test;
4. generic Stream watcher-registration construction failure;
5. old-protocol consumer flush before the first new-protocol message.

Still required with their later roadmap work:

1. terminal `flush -> CLOSE` ordering/single-terminal-event behavior for the
   Priority 2 status-semantics reconciliation;
2. framer byte-equivalence boundaries for any Priority 4 parser optimization.

### Performance gate

For every change touching a hot path, run paired baseline/candidate measurements on the same host, Perl build, compiler/build flags, benchmark parameters, and workload. Use repeated runs and compare medians or another stable summary. Investigate any regression larger than normal run-to-run variance before merge.

Tiny-message benchmarks remain useful diagnostics for fixed per-message and callback overhead, but they are not sufficient evidence for an architectural or merge decision. The required payload policy is:

- quick development sweep: 64 B, 4 KB, 32 KB, 200 KB;
- full architectural/merge sweep: 64 B, 256 B, 1 KB, 4 KB, 16 KB, 32 KB, 64 KB, 128 KB, 200 KB.

A benchmark may substitute a nearby size when a protocol has a natural boundary, but the sweep must still cover small, medium, read-size-adjacent, and large payloads up to approximately 200 KB. For larger payloads report MiB/s and CPU per byte or per MiB in addition to messages/s; also record reads/message, writes/message, callbacks/message, and p50/p99 latency when relevant.

At minimum watch:

- `_write` / queued-write throughput;
- framed message dispatch throughput;
- read-drain throughput;
- callbacks/message and syscalls/message where relevant;
- latency for representative small and large messages when a change could alter batching/re-drive behavior.

Historical measurements from the independent review are useful reference points, not permanent acceptance thresholds:

- `ENTER` / `SAVEFREESV(SvREFCNT_inc)` / `LEAVE`: reviewer measured about 6.96 ns incremental cost per guarded XSUB call in a scratch microbenchmark;
- `JMPENV_PUSH` / `JMPENV_POP`: reviewer measured about 1.32 ns incremental cost per call;
- queued 64-byte `write()` with the socket buffer pre-filled: about 787,635/s on `c791e81` vs 814,642/s on `2681a0c`, showing no observed hardening regression within that run set;
- LengthPrefix pre-resolved framing: about 1.19M/s -> 2.19M/s for the whole `_frame` call (~1.85x), which supersedes the misleading earlier ~6.3x bare-`pack` figure.

Microbenchmarks may explain a result, but the merge decision should use an end-to-end Stream benchmark. Reproduce the relevant paired benchmark rather than treating the historical absolute values as machine-independent gates.

## Integration sequence

1. Merge or selectively cherry-pick the tested correctness baseline from `fix/stream-socket-review` onto `fix/review-bugfix-simplify`. The branches diverged from `668d3a0`, so this is not a fast-forward and conflicts should be expected/reviewed deliberately.
2. Fix exception-safe teardown first.
3. Decide the exported consumer host/provider lifetime contract and ABI constraints before coding the host-lifetime fix; then implement and test it.
4. Fix the protocol-transition flush boundary.
5. Decide the flush-owed/reentrant-message semantic, then refactor consumer status/flush handling coherently.
6. Centralize duplicated predicates/invariants.
7. Run targeted regressions and the hot-path performance gate.
8. Cross-test `Linux::Event::Async` against the candidate core. Build the core branch first, then build/test Async with its `PERL5LIB`/test environment pointed at the candidate core `blib` so the external native-consumer ABI is exercised against the exact code being proposed.
9. Salvage only the useful PR #9 simplifications: named descriptor spec, framer fast paths, test-provider source split, and embedded stats grouping.
10. Re-run the full core suite, integration suite, Async compatibility suite, and performance regression set before merge.
