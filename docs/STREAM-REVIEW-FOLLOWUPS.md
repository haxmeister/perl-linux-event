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

## Priority 1 - remaining correctness and lifetime blockers

### 1. Make callback-capable teardown exception-safe

The current Perl lifecycle can mark an object terminal, invoke native terminal consumer work, and then fail before watcher/handle teardown if provider code throws.

This is proven for full `close()` and applies to any lifecycle path that invokes callback-capable native terminal dispatch before finishing ownership teardown.

Required invariant:

> Once terminal teardown begins, required watcher, fd, handle, and ownership cleanup must complete even if terminal provider/application code throws.

Apply this invariant to:

- full `close()` / `_close_now()`
- `close_read()`
- `detach()`

Do not automatically classify `close_write()` as the same bug: its native `_close_write` path currently does not perform consumer terminal flush/event dispatch. Add it only if a failing test demonstrates an equivalent exception hole.

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
- assert no fd leak, no live watcher/epoll registration, correct final object state, and exception propagation.

### 2. Make the exported consumer host `resume()` lifetime-safe

The core XSUB `_consumer_resume` is guarded, but that does not protect the public native-consumer host callback itself.

The ABI gives external providers a host table containing `resume(host_context)`. `Linux::Event::Async` already calls that host function directly from its own XS receive-arm path. Therefore the call can enter `les_consumer_resume(st)` without passing through the guarded core `_consumer_resume` XSUB.

This remains a real lifetime concern because host `resume()` may synchronously dispatch buffered messages, provider/user code may close the Stream, and `les_consumer_resume()` may then continue with the raw `les_xsstate_t *`.

Required work:

- design lifetime protection at the exported host-entry boundary, not only at core XSUB wrappers;
- do not require third-party consumers to know private `les_xsstate_t` details;
- add a cross-repository regression using the real `Linux::Event::Async` path: direct host resume -> synchronous message -> user closes Stream -> host resume returns safely.

Keep the existing XSUB guards; they are still useful for core entry points.

### 3. Complete generic Stream construction-failure cleanup

`Socket` construction cleanup and Listener accepted-fd cleanup are now validated and should be preserved.

The remaining generic case is `Stream->new(loop => ...)` after XS state creation when watcher registration/attachment fails. The constructor must not strand the Perl <-> XS state ownership cycle or owned handles.

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

### 8. Preserve the verified hardening from `2681a0c`

Keep:

- terminal flush-before-event ordering;
- terminal event as the last callback-capable action in `_close` / `_close_read`;
- guarded XSUB paths that can reenter Perl/provider code and then continue touching XS state;
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

## Priority 4 - simplifications worth salvaging from PR #9

### 10. Named XSDescriptor specification

Replace the large positional `XSDescriptor::new` argument list with a named hash/spec and reject unknown fields.

This is cold construction code, so maintainability and correctness are more important than avoiding hash lookup during descriptor creation.

### 11. Framer fast paths

Keep the worthwhile native framer simplifications:

- pre-resolve LengthPrefix template/width/endian information;
- Varint `< 128` one-octet fast path;
- other clearly equivalent local parser simplifications.

Require byte-equivalence boundary tests and an end-to-end benchmark before merging.

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
- **`close_write()` as the same callback-exception teardown bug:** not currently supported by the code path; add only with evidence.

## Required validation gate before merge

### Correctness regressions still missing

At minimum add tests for:

1. exception-safe full close teardown;
2. exception-safe `close_read` teardown;
3. exception-safe `detach` teardown;
4. terminal flush returning `ERROR` while teardown still completes;
5. external consumer host `resume()` reentrancy/lifetime using `Linux::Event::Async`;
6. generic Stream watcher-registration construction failure;
7. old-protocol consumer flush before first new-protocol message;
8. terminal `flush -> CLOSE` ordering/single-terminal-event behavior;
9. framer byte-equivalence boundaries for any salvaged parser optimization.

### Performance gate

For every change touching a hot path, capture a before/after number against an appropriate baseline.

At minimum watch:

- `_write` / queued-write throughput;
- framed message dispatch throughput;
- read-drain throughput;
- callbacks/message and syscalls/message where relevant;
- latency for representative small and large messages when a change could alter batching/re-drive behavior.

Microbenchmarks may explain a result, but the merge decision should use an end-to-end Stream benchmark.

## Integration sequence

1. Bring the tested correctness baseline from `fix/stream-socket-review` onto `fix/review-bugfix-simplify`.
2. Fix exception-safe teardown first.
3. Resolve exported host `resume()` lifetime safety.
4. Fix the protocol-transition flush boundary.
5. Decide the flush-owed/reentrant-message semantic, then refactor consumer status/flush handling coherently.
6. Centralize duplicated predicates/invariants.
7. Run targeted regressions and the hot-path performance gate.
8. Cross-test `Linux::Event::Async` against the branch.
9. Salvage only the useful PR #9 simplifications: named descriptor spec, framer fast paths, test-provider source split, and embedded stats grouping.
10. Re-run the full core suite, integration suite, and performance regression set before merge.
