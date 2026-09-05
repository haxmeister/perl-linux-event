# Cached Closure Dispatch Experiment Handoff

Branch: `experiment/cached-closure-dispatch`

## Question

Can Linux::Event allow constructor-supplied Perl callbacks that retain normal lexical closure scope while preserving essentially the same native callback-dispatch performance as the current subclass method-CV model?

This is specifically about separating two claims that had previously been conflated:

1. the old object-configured Stream design was slower than the subclass design;
2. invoking an already-created Perl closure is intrinsically slower than invoking a pre-resolved subclass method CV.

The first was benchmarked historically. The second has not yet been established through the real Linux::Event native path.

## Important semantic point

Capturing or retaining a caller package or Perl pad is not the right design. A package does not provide access to caller lexicals, and Perl closures already provide the safe language-level mechanism for retaining lexical state.

The experiment should therefore retain the supplied callback CV/SV once and invoke that same closure repeatedly. It must not create a closure per message.

## Stage 1

`bench/run-callback-scope-microbench.pl` was added on this branch. It compares ordinary method lookup, a method CV resolved once, a cached coderef, and closures with captured lexical state.

This is only an isolated Perl invocation benchmark. It is not sufficient for an architectural decision because it does not include the XS-to-Perl boundary, native framing, descriptor state, or real Stream dispatch.

No performance numbers should be recorded as authoritative until the benchmark is actually run in the Linux development environment. A prior chat response incorrectly claimed local execution; that claim was explicitly corrected.

## Stage 2: next work

Implement an experimental constructor-supplied callback through the real ordered-byte native path.

The current descriptor resolves subclass callbacks once in `Linux::Event::_ByteStream::Descriptor::for_class`, including `on_data` and `on_message`, and places those CVs in the native descriptor. The experiment should add an instance callback path that retains the supplied callback SV/CV once in native per-stream state and invokes it directly from the same native delivery/framing path.

Do not implement per-message callback lookup, method lookup, closure creation, or a generic target/owner abstraction for this experiment. The purpose is specifically to measure a cached lexical closure against the current cached subclass CV.

Compare at least:

- current subclass method CV;
- cached constructor-supplied non-capturing coderef;
- cached constructor-supplied closure capturing one lexical;
- cached constructor-supplied closure capturing several application lexicals.

Use matched native framing and identical workload/validation for every case. Include small messages where callback dispatch dominates and larger messages to observe convergence. Rotate run order and use repeated runs.

Useful historical experiment requirements also include throughput, CPU/message, allocation/churn or connection churn where practical, RSS where practical, small/large messages, and long-lived versus idle cases.

## Decision criterion

The architectural question is not whether closures are literally free. It is whether the real cached-closure native path is close enough to the subclass path that Linux::Event can restore idiomatic Perl lexical callback scope without sacrificing the performance advantage that motivated subclass-only callbacks.

If the matched native-path result is close, reconsider subclass-only callback policy. If it is materially slower, isolate where the difference occurs before attributing it to closure lexical capture itself.

## Result

Status: implemented and benchmarked on 2026-09-05.

The experiment passes its decision criterion. A cached lexical closure is close
enough to the cached subclass method CV that lexical capture itself does not
justify a subclass-only callback policy.

### Implementation

The experimental constructor accepts `on_message => $coderef` for a framed
ordered-byte object. Construction validates the callback once and passes it to
the XS state. The Perl object then drops its callback reference; the native
per-stream state owns the retained CV until teardown.

Every framed stream state now has one effective `message_cb` pointer:

- the descriptor's already-resolved method CV for the subclass case;
- the retained constructor CV for an instance callback.

The native delivery loop calls that pointer directly. There is no per-message
method lookup, hash lookup, closure creation, or method-versus-instance branch.
An instance callback overrides a class `on_message` method and remains the
instance's sink across framed protocol transitions.

This experiment deliberately supports only ordinary one-message framed
delivery. Constructor `on_message` is rejected for raw delivery, native
consumers, and `message_batch_size` classes so those separate API questions do
not contaminate the measurement.

### Correctness

`t/stream-65-cached-closure-dispatch.t` verifies:

- native retention and teardown release of the supplied closure;
- lexical state remains available during native framed dispatch;
- instance callback precedence over the class method CV;
- a constructor callback can supply the sink for a methodless framed class;
- framed transitions retain the instance callback;
- closing a still-pending object releases its not-yet-native callback;
- invalid and mode-incompatible callbacks fail clearly.

`t/stream-66-cached-closure-benchmark-smoke.t` guards all four benchmark cases,
the JSON contract, and native frame/callback count validation.

The first full run exposed only two public-surface manifest assertions: the
pre-existing Stage 1 benchmark and the new test had not been added to that
contract. After correcting the manifest, the final complete suite passed all
148 test files and 2,604 assertions. Two environment-dependent Unix listener
and connect tests were skipped because those operations are unavailable in the
test container; their socketpair coverage passed.

### Benchmark environment and contract

The recorded runs used Perl 5.38.2 with threads, Linux 6.18.35, and an AMD EPYC
9V74 virtualized host. These are valid local experiment results, but a final
release-policy decision should also be repeated on the normal Perl 5.44 Linux
development machine.

`bench/run-cached-closure-dispatch-bench.pl` uses one native delimiter framer
and identical executed callback work for:

1. cached subclass method CV;
2. cached constructor non-capturing coderef;
3. cached constructor closure retaining one lexical;
4. cached constructor closure retaining four lexicals.

A forked blocking writer feeds the measured receiver process. Every callback
validates its payload, and XS counters validate frame and callback totals.
Order rotates within each repeat. Reported relative changes are medians of
same-repeat pairs against the subclass method, rather than ratios of unrelated
medians.

### Small-message dispatch result

The dispatch-dominant run used 16-byte payloads, 64 MiB per measured row
(4,194,304 callback invocations), one warmup, and eleven repeats:

```text
perl -Mblib bench/run-cached-closure-dispatch-bench.pl \
  --payload-sizes=16 --idle-connections=0,63 \
  --target-mib=64 --minimum-messages=512 \
  --warmup=1 --repeats=11
```

| Callback form | Idle | Median msg/s | Median CPU us/msg | Paired speed | Paired CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| subclass method | 0 | 1,764,549 | 0.567 | baseline | baseline |
| constructor coderef | 0 | 1,726,133 | 0.579 | -3.45% | +3.57% |
| closure, one lexical | 0 | 1,770,193 | 0.565 | -1.44% | +1.45% |
| closure, four lexicals | 0 | 1,755,567 | 0.569 | -0.77% | +0.78% |
| subclass method | 63 | 1,772,113 | 0.563 | baseline | baseline |
| constructor coderef | 63 | 1,753,692 | 0.570 | -1.19% | +1.19% |
| closure, one lexical | 63 | 1,780,769 | 0.561 | +0.81% | -0.54% |
| closure, four lexicals | 63 | 1,768,746 | 0.565 | -0.88% | +0.87% |

The one- and four-lexical closures remain within about 1.5% of the method CV in
both configurations. More captured lexicals do not produce a growing dispatch
penalty. The non-capturing constructor coderef's -3.45% single-stream result
also shows why a small difference cannot be attributed to lexical capture: it
is slower there than either capturing closure despite using the same native
storage and call path.

The middle 50% of paired CPU deltas was approximately -0.51% to +3.57% for the
plain constructor coderef, -0.54% to +1.45% for the one-lexical closure, and
-1.37% to +0.78% for the four-lexical closure with no idle streams. With 63
idle streams the corresponding bands remained similarly centered around zero.

### Larger-message convergence diagnostic

The convergence run used 512 MiB per row, one warmup, and eleven repeats:

| Callback form | Bytes | Median msg/s | Median CPU us/msg | Paired speed | Paired CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| subclass method | 4,096 | 323,146 | 1.378 | baseline | baseline |
| constructor coderef | 4,096 | 306,448 | 1.295 | +2.65% | -1.13% |
| closure, one lexical | 4,096 | 304,814 | 1.397 | +2.64% | -3.47% |
| closure, four lexicals | 4,096 | 344,376 | 1.258 | +3.50% | -2.85% |
| subclass method | 65,536 | 36,638 | 22.254 | baseline | baseline |
| constructor coderef | 65,536 | 42,021 | 18.394 | +13.08% | -15.93% |
| closure, one lexical | 65,536 | 38,909 | 18.578 | +32.18% | -17.62% |
| closure, four lexicals | 65,536 | 35,599 | 20.349 | -1.58% | -10.95% |

These larger rows are explicitly diagnostic rather than rankings. Their
double-digit positive and negative swings show that producer scheduling, read
chunking, and the local socket path dominate the callback-form difference.
They show no closure-specific ordering or penalty, which is consistent with
convergence, but they cannot support claims that any callback form is faster.

### Retention and construction observations

A separate 63-idle-stream setup run reported median construction costs between
39.6 and 42.9 microseconds per stream across the four callback forms. Current
process RSS after setup spanned only 13,000 to 13,008 KiB. Process RSS and Perl
allocator reuse are too coarse to resolve the cost of one retained CV reference
per stream, but this run found no material construction or retention signal.

### Stage 1 observation

The isolated Stage 1 script was also run for 20,000,000 invocations per timed
iteration. Cached method CV, cached coderef, and one-lexical closure rows took
2.78, 2.50, and 2.48 CPU seconds respectively. The four-lexical row took 3.23
seconds, but its callback body mutates four captured variables while the other
bodies do different work. It therefore does not measure capture-count dispatch
cost and is not used for the architectural conclusion. Stage 2's matched
executed bodies supersede it.

## Decision

Retaining a constructor-supplied closure once and calling its CV directly from
the native framed-delivery path preserves essentially the same dispatch
performance as a pre-resolved subclass method CV. The benchmark provides no
evidence that Perl lexical closure scope is intrinsically too expensive for
Linux::Event.

The subclass-only policy should therefore be reconsidered. This branch remains
an experiment: choosing the production API still requires deciding how
constructor callbacks compose with listeners, raw byte delivery, batching,
native consumers, and lifecycle callbacks. Those API questions should not be
answered by extending this performance experiment without a separate design
review.
