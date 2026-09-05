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
