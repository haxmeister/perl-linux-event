# Linux::Event Stream/Socket Follow-up List

Created after review of PR #9 / branch `refactor/stream-simplify` ("Fix Stream/Socket correctness bugs and reduce complexity").

Purpose: preserve the worthwhile discoveries and unresolved review items for the next high-effort/work-model session. Do not merge PR #9 unchanged.

## Priority A - correctness / lifetime fixes to carry forward

1. **Terminal consumer flush ordering and single-terminal-event guarantee**
   - Keep the discovery that end-of-drain flush must happen before the terminal event.
   - But after `les_consumer_flush()` returns, re-check `closed` / `consumer_terminal` before sending the original terminal event.
   - Explicitly test a provider whose `flush()` returns `LES_CONSUMER_CLOSE` during EOF/read-close so it cannot receive both CLOSED and EOF.

2. **Complete XS state lifetime protection for reentrant callbacks**
   - The `LES_GUARD_STATE()` idea is worthwhile and should be kept.
   - Audit *every* path capable of entering Perl and then touching `les_xsstate_t` again.
   - In particular, `_consumer_resume` / host `resume()` can synchronously dispatch buffered messages and therefore still needs lifetime-safe handling.
   - Add a regression where consumer resume -> message callback -> `$stream->close` occurs reentrantly.

3. **Complete construction-failure cleanup**
   - Keep `_abort_construction()` and the accepted-fd cleanup in `Listener`.
   - Extend the same failure-safe construction region to generic `Stream->new(loop => ...)`: watcher-registration failure after XS state creation must break the Perl<->XS cycle and close owned handles.
   - Audit detached/pending `Socket->connect()` ownership cycles as well.

4. **Readable transition sink validation**
   - Keep `les_require_read_sink()` and enforce it both at construction and `transition_to()`.
   - A readable raw target must have `on_data`; a readable framed target must have `on_message`, message batching, or a native consumer.

5. **Native fd invalidation on directional close**
   - Keep invalidating cached native `write_fd` / plain transport `write_fd` on `_close_write` so a recycled descriptor cannot be targeted by a late write path.

6. **Deadline timer lifecycle fixes**
   - Keep object identity comparison via `refaddr` rather than numeric comparison.
   - Keep explicit cancellation of a fired-but-still-registered timer before replacing it.
   - Add regression coverage for fired/rearm/replacement cases.

## Priority B - native consumer ABI semantics to decide deliberately

7. **Define `LES_CONSUMER_CONTINUE` / pause / flush semantics precisely**
   - The branch's observation about possible backpressure inversion is valuable, but changing `CONTINUE` to a pure no-op is not yet proven correct for the public ABI.
   - Specify the interaction of:
     - host `pause()`
     - host `resume()`
     - `message -> CONTINUE`
     - `message -> PAUSE`
     - `flush -> CONTINUE`
     - `flush -> PAUSE`
   - Do not silently change ABI behavior while still calling it API-compatible.
   - Cross-test the final semantics against `Linux::Event::Async`, which is a real external native-consumer implementation.

8. **Terminal consumer liveness guard**
   - Keep the unified `les_consumer_live()` concept for pause/resume/flush entry points.
   - Ensure no provider callback is made after terminal state except destruction.

## Priority C - simplifications worth keeping

9. **Named XSDescriptor fields**
   - Keep replacing the 29 positional `XSDescriptor::new` arguments with one named hash/spec.
   - Reject unknown fields.
   - This is cold construction code and the maintainability/safety gain is worthwhile.

10. **Framer outbound prefix optimization**
    - Keep pre-resolving LengthPrefix `pack` templates (`C`, `n`/`v`, `N`/`V`) at declaration time.
    - Keep the Varint `< 128` one-octet fast path.
    - Add byte-equivalence tests at width/endian/boundary values and retain an end-to-end microbenchmark.

11. **Test consumer source split**
    - Keep moving the test-only native consumer provider out of `stream_consumer.c` into its own translation unit.

12. **POD cleanup after Stream/Socket split**
    - Keep deleting the hidden ~540-line obsolete pre-split Stream POD.
    - Keep adding the Socket METHODS documentation.
    - Correct wording: `end()` is the graceful TLS write-side replacement for `close_write`; it is not a replacement for `close_read`. For total immediate TLS shutdown, `close()` is closer semantically.

13. **Callback null checks**
    - Keep failing loudly rather than reaching `call_sv(NULL)` if an internal callback invariant is broken.

## Priority D - changes to rework rather than merge as written

14. **Stats layout refactor: keep organization, reject pointer justification unless benchmarked**
    - The branch's claim that the 40 counters sat between hot read and hot write fields is incorrect; the hot write fields already precede the counters.
    - The pointer/tail-allocation version grows total per-stream memory and adds indirection to counter updates without an obvious cache-layout benefit.
    - Worth keeping: a dedicated `les_xsstats_t`, `LES_STAT` macro, and table-driven `stats()` export.
    - Preferred first version: embed `les_xsstats_t stats;` at the tail of `les_xsstate_t` rather than storing `les_xsstats_t *stats`.
    - Only use a separate pointer/block if an end-to-end Stream benchmark demonstrates a real win.

15. **Future outbound zero-copy/COW work must preserve write value semantics**
    - Do not simply retain the caller's mutable SV in queued write segments.
    - Existing `write()` semantics allow the caller to modify/release its scalar immediately without changing queued bytes.
    - Explore an owned/COW-safe SV representation or equivalent, benchmarked as a separate experiment.

## Priority E - API/documentation hygiene

16. **Do not call PR #9 fully API-compatible as written**
    - Rejecting `socket_options()` / `configure_socket()` names on generic Stream subclasses is observable behavior and should be an intentional reservation if kept.
    - `Socket->connect(transport => ...)` is effectively a new supported option, not merely a hidden fix; document/test it or split it into its own change.

17. **Regression tests are required for every correctness claim**
    - The old 1,788 tests passed with the original bugs, so simply retaining the same passing count does not validate the fixes.
    - Add targeted tests for terminal-flush reentrancy, resume-close UAF, construction fd leaks, transition sink validation, deadline replacement, stale fd invalidation, and framer byte equivalence.

## Integration / workflow note

18. **Retarget PR #9 to `main` before further work**
    - `feature/stream-socket-split` has already been merged.
    - Salvage the good commits/ideas above, fix the blockers, run core regression + Linux::Event::Async compatibility tests, and only then consider merging.

## Follow-up from independent review of `fix/stream-socket-review` (`2681a0c`)

This section records code-only findings from the later independent review. Ignore documentation and packaging concerns for implementation planning.

### Verified fixes worth preserving

19. **Terminal flush-before-event ordering is now substantially correct**
    - Keep the new guard on ordinary consumer flushes against closed / terminal / read-EOF state.
    - Keep a distinct terminal-flush path so owed consumer work can be flushed before the terminal event.
    - Keep the sequence-counter regression assertions proving `last_flush_sequence < last_event_sequence`; this tests the actual ordering contract, not merely call counts.

20. **Reentrant XS-state lifetime guarding is now broad enough on the real callback paths**
    - Keep `ENTER` / `SAVEFREESV(SvREFCNT_inc(state_obj))` / `LEAVE` protection on `_read_ready`, `_write`, `_write_ready`, `_transition`, `_close`, `_close_read`, `_consumer_resume`, and the test arm path.
    - Moving consumer terminal-event dispatch to the end of `_close` / `_close_read` is preferable to dispatching early and then attempting to re-check potentially stale state.

21. **Readable transition validation is fixed in the correct layer**
    - Keep rejecting readable raw targets without `on_data` and readable framed targets without a message sink.
    - Keep defensive NULL callback checks as a backstop even though descriptor/transition validation should make them unreachable.

22. **Consumer re-drive after a flush releases backpressure is worthwhile**
    - Keep the behavior that, when a consumer was paused and flush resumes it while buffered input remains, buffered input is immediately re-driven rather than waiting for another fd readiness event.
    - Preserve this for both existing-input processing and read-drain boundaries.

23. **Directional native fd invalidation is correct and should remain**
    - Keep setting the closed direction's cached native fd and matching plain-transport fd to `-1`.
    - Keep explicit `EBADF` handling in plain transport operations so late native access cannot hit a recycled descriptor.

24. **Construction/accept fd cleanup fixes are validated and worth keeping**
    - Keep Listener's `defined fileno($fh)` guard before closing an accepted handle after failed construction.
    - Keep Socket construction cleanup when socket configuration throws.
    - Continue applying the same ownership principle to any generic Stream construction failure discovered later.

25. **Purpose-built native consumer test modes are valuable infrastructure**
    - Keep dedicated test consumers for cases such as `flush -> CONTINUE` and `message()` croaking.
    - Keep them restricted to the test context so they cannot accidentally become public runtime providers.

### New blocker discovered by the second review

26. **BLOCKER: Perl-side close teardown must be exception-safe**
    - `_close_now()` currently marks the Stream closed and then calls native `_close(4)` before cancelling watchers or closing owned handles.
    - Native `_close(4)` can invoke terminal consumer flush and terminal consumer event callbacks, either of which may throw.
    - If that happens, watcher cancellation and handle closure are skipped, while `{closed}` remains true. A later `close()` immediately returns, leaving a permanently stuck Stream with live fd(s) and epoll registration.
    - Required invariant: once close begins, resource teardown must complete even when provider/application code throws.
    - Preferred implementation: capture the first exception from native terminal dispatch, always complete watcher cancellation and requested handle closure, run any remaining close lifecycle that must be guaranteed, then rethrow the captured exception.
    - Add a regression where a terminal consumer event throws and assert: fd delta returns to zero, watchers are gone, and the original exception still reaches the caller.

### Additional correctness fix worth making

27. **Flush native-consumer work at a protocol-change boundary**
    - A message callback may call `transition_to()` while the old protocol still owes a deferred consumer flush.
    - Current parsing can continue immediately under the new descriptor, causing old- and new-protocol deliveries to share one consumer flush interval.
    - Preserve the useful property that `les_transition_descriptor()` itself remains callback-free.
    - Therefore do NOT blindly add provider flush dispatch inside the descriptor-swapping primitive.
    - Instead, when the parser detects that a callback changed the descriptor, flush consumer work owed by the old parsing phase before continuing buffered input under the new descriptor.
    - Add a regression that proves the old protocol's flush happens before the first message under the new protocol.

### Consumer-path simplifications worth doing

28. **Remove `JMPENV` bookkeeping for `consumer_flush_pending` if set-after-success is sufficient**
    - Current code sets `consumer_flush_pending = 1` before calling provider `message()` and uses `JMPENV` only to clear the flag if `message()` throws.
    - Prefer setting the flag after `message()` returns successfully.
    - This is simpler and also avoids a nested close/terminal-flush seeing `flush_pending == 1` while the provider's `message()` call is still on the stack.
    - The independent benchmark found `JMPENV` overhead negligible, so this is a state-machine simplicity improvement rather than a performance optimization.

29. **Separate consumer status validation from status application**
    - A provider return value should be validated even if the Stream became closed / EOF / terminal during the `message()` callback.
    - Current early return can silently ignore `LES_CONSUMER_ERROR` or an invalid enum in that situation.
    - Preferred flow: call `message()` -> validate returned status unconditionally -> if Stream became terminal, stop -> mark flush pending as appropriate -> apply CONTINUE/PAUSE/CLOSE behavior.
    - This preserves diagnostics without performing inappropriate state transitions after terminal state.

30. **Factor the common consumer flush primitive**
    - `les_consumer_flush()` and `les_consumer_flush_terminal()` duplicate pending checks, `WANT_FLUSH`, pending-flag clearing, counter increment, provider invocation, and return-status validation.
    - Factor a small shared helper that performs the common "call pending flush and validate result" operation.
    - Keep ordinary-vs-terminal post-call behavior separate: ordinary flush applies PAUSE/CONTINUE/CLOSE semantics; terminal flush must not restart ordinary flow.

31. **Factor the duplicated resumed-with-buffered-input predicate**
    - The subtle condition `was_consumer_paused && !LES_INPUT_PAUSED(st) && !st->closed && !st->read_eof && st->input_len` appears in more than one path.
    - Move it behind a small predicate/helper so future changes to pause/liveness semantics cannot diverge between the read-boundary and existing-input paths.

### Known architectural limitation - do not "fix" casually

32. **Loop-attached Stream lifetime cycle requires an ownership redesign, not a local refcount tweak**
    - Constructed-and-dropped loop-attached Streams remain retained through the Stream <-> XS-state lifetime mechanism.
    - The independent review confirmed this is unchanged rather than introduced by the hardening branch.
    - Do not weaken that cycle locally: doing so could free a live Stream still owned operationally by the loop.
    - If this becomes a target, solve it with an explicit loop-owned registry / ownership model and benchmark its hot-path and lifecycle cost separately.

### Updated integration recommendation

33. **Use `fix/stream-socket-review` as the correctness baseline before salvaging PR #9 simplifications**
    - The branch now contains targeted regression coverage and most of the important correctness hardening.
    - Fix Priority 26 first, then 27-31.
    - After that, rebase/salvage only the genuinely useful simplifications from PR #9 (named descriptor spec, framer templates/fast paths, test-provider source split, and a carefully reworked stats grouping).
    - Avoid re-importing duplicate Stage-1 correctness changes from PR #9.
