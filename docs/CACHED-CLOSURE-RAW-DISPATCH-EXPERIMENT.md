# Cached Closure Raw Dispatch Experiment

Branch: `experiment/cached-closure-dispatch`

## Question

Does raw `on_data` delivery expose a measurable penalty when an instance-supplied
Perl callback is retained once in native stream state and invoked through the
same direct cached-CV path as the subclass method callback?

This is the raw-delivery follow-up to
`docs/CACHED-CLOSURE-DISPATCH-EXPERIMENT.md`. The framed experiment already
showed that lexical capture itself does not produce a meaningful dispatch
penalty in the native `on_message` path. Raw delivery is worth measuring because
it removes native framing work and can therefore make callback-dispatch cost a
larger fraction of each iteration.

## Experimental implementation

The native ordered-byte state now has one effective `deliver_cb` CV, analogous
to the framed state's effective `message_cb`:

- ordinary raw subclasses retain the descriptor's already-resolved `on_data`
  method CV in per-stream native state;
- the experimental socket constructor may replace that CV once with an
  `on_data => $coderef` instance callback before the object is attached for
  reads;
- `les_call_deliver()` invokes only the effective state CV. It does not perform
  method lookup, hash lookup, callback-type branching, or closure creation.

The state owns the retained CV and releases it during native teardown. Protocol
transitions retain an installed instance raw callback, while ordinary class
callbacks follow the target descriptor.

To keep this performance experiment from deciding the production constructor
API, the temporary `on_data` constructor surface is intentionally narrow: it is
implemented on stream sockets and requires the raw class to already define an
`on_data` method. That lets the benchmark compare the two callback forms on the
same class and native path without changing the general readable-sink rules.
This restriction is experimental scaffolding, not a proposed final API.

The existing `_new_validated` state constructor ABI is unchanged. The framed
experiment already uses its final optional argument for an instance
`on_message` callback, so raw override installation uses a one-time native
setter instead of shifting that argument.

## Correctness coverage

`t/stream-67-cached-closure-raw-dispatch.t` checks:

- native retention and teardown release of the raw callback;
- captured lexical state during raw native dispatch;
- instance callback precedence over the subclass `on_data` CV;
- retained instance callback semantics across a raw protocol transition;
- construction before loop attachment;
- invalid callback and framed/raw mode diagnostics.

`t/stream-68-cached-closure-raw-benchmark-smoke.t` runs all four benchmark cases
with a small workload and validates the JSON contract plus native byte and
callback counters.

## Benchmark

`bench/run-cached-closure-raw-dispatch-bench.pl` compares:

1. cached subclass `on_data` method CV;
2. cached constructor non-capturing coderef;
3. cached constructor closure retaining one lexical;
4. cached constructor closure retaining four lexicals.

Every case runs the same callback body. `read_batch_bytes` is fixed at zero so
each successful raw read immediately enters Perl. The default sweep uses raw
read sizes of 16, 4,096, and 65,536 bytes and 0 or 63 idle connections. Cases
rotate within repeats, and relative changes are computed from same-repeat pairs
against the subclass method.

The benchmark reports callback deliveries per second, receiver CPU per
delivery, MiB/s, average bytes per delivery, read calls, EAGAIN counts,
construction cost, and RSS observations. The writer runs in a separate blocking
process so its CPU time is excluded from the receiver measurement.

Unlike framed messages, a `SOCK_STREAM` read does not preserve application
message boundaries. The benchmark therefore never assumes one callback per
requested `read_size`. It verifies the exact total byte count and checks that
the XS `delivery_calls` counter equals the number of callbacks observed by Perl,
while recording the actual average bytes per callback.

Suggested dispatch-dominant run:

```text
perl -Mblib bench/run-cached-closure-raw-dispatch-bench.pl \
  --read-sizes=16,4096,65536 --idle-connections=0,63 \
  --target-mib=64 --minimum-deliveries=512 \
  --warmup=1 --repeats=11 \
  --json=bench/results/cached-closure-raw-dispatch.json
```

## Decision criterion

The raw result should be interpreted the same way as the framed experiment.
The question is not whether two measurements are numerically identical; it is
whether an instance closure retained once and invoked as a direct native CV has
a stable material penalty relative to the cached subclass CV.

If a small-message difference appears, compare the non-capturing constructor
coderef with the capturing closures before attributing the difference to
lexical capture. Larger read sizes are convergence diagnostics because syscall,
socket buffering, scheduling, and byte-copy costs increasingly dominate the
callback-form difference.

## Status

Implementation and benchmark harness prepared for branch testing. No raw
performance numbers are recorded here until the benchmark is run in a suitable
Linux development environment. CI smoke coverage is a correctness guard, not a
performance result.
