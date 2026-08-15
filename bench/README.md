# Benchmark Guide

The benchmark directory contains current reactor, callback, Stream transport,
framing, native-framer, and lifecycle measurements. Older optimization
experiments are preserved under `bench/archive/` and are not the recommended
way to measure the current implementation.

## 1. Permanent reactor comparison

`run-reactor-comparison.pl` is the canonical same-work comparison.

Default leaderboard:

1. Linux::Event XSLoop
2. EV
3. AnyEvent `AE::io` on EV
4. `UV::Poll`
5. `IO::Async::Loop::Epoll`
6. `Mojo::Reactor::Epoll`

Diagnostic AnyEvent variants are still selectable but are not part of the
default leaderboard.

### Fairness contract

Every ranked system receives the same workload:

- TCP IPv4 loopback
- all connections established and accepted before timing
- watcher registration outside timing
- identical named Perl `echo_read()` function
- `sysread(..., 8192)` drain logic
- identical `syswrite` loop
- serial request/reply: at most one outstanding message per client
- warmup outside timing
- teardown outside timing
- no framework timeout watcher during timing
- fresh process for each system/client/repeat case
- parent process provides catastrophic timeout protection
- balanced rotating execution order

The benchmark checks exact messages/bytes and rejects cases with client
failures, partial writes, unexpected closes, or write EAGAIN.

### Dependencies

Build Linux::Event first and check installed competitor versions:

```bash
perl bench/run-reactor-comparison.pl --build --check-deps
```

Typical dependency installation:

```bash
cpanm EV AnyEvent UV IO::Async IO::Async::Loop::Epoll Mojolicious Mojo::Reactor::Epoll
```

### Recommended reference run

Increase the open-file limit before high-client tests:

```bash
ulimit -n 100000
```

Then:

```bash
perl bench/run-reactor-comparison.pl --build \
  --systems linuxevent,ev,anyevent-ae,uv,ioasync-epoll,mojo-epoll \
  --clients 1000,5000,10000,20000 \
  --warmup 1 \
  --messages 100 \
  --bytes 64 \
  --client-workers 4 \
  --repeats 6 \
  --timeout 180 \
  --out bench/results/reactor-comparison.html \
  --json bench/results/reactor-comparison.json
```

Six repeats matter when the default six systems are selected: each system then
occupies every execution position exactly once at each client scale.

### Reading the report

The JSON contains raw records, summary records, the fairness contract, backend
information, CPU, RSS, latency, syscall/callback counters, and correctness
fields.

The HTML is self-contained and works without a web server or internet access.
It provides:

- click-to-sort on every table header
- text search across result rows
- exact system filter
- exact client-count filter
- reset button
- visible-row counter

For close reactor comparisons, prefer **server CPU microseconds/message** over
small differences in wall-clock msg/s. Wall throughput is more sensitive to
client-worker scheduling and machine load.

Do not compare `reactor_iterations` across unrelated frameworks unless their
counters have identical semantics. `n/a` is intentional when a backend does
not expose a comparable counter.

## 2. Callback/I/O decomposition diagnostic

`run-callback-ceiling.pl` exists to study where echo CPU is spent. It separates
native echo, empty Perl callback entry, and the normal Perl read/write body.
It is a diagnostic tool, not the public competitor leaderboard.

## Historical experiments

`bench/archive/` contains the scripts used during earlier optimization phases,
including capacity, watcher reclaim/reuse, older comparison harnesses, and EV /
AnyEvent studies. They are retained to make the research reproducible but may
refer to phase-era names and assumptions.

## 3. Stream transport comparison

`run-stream-microbench.pl` compares direct raw-reactor echo with a raw
subclass-defined Stream using the same AF_UNIX request/reply workload. It
measures the cost and benefit of owned native Stream transport above readiness
dispatch; it is not the public cross-runtime leaderboard.

```bash
perl -Mblib bench/run-stream-microbench.pl \
  --clients=1,10,100,1000 --warmup=10 --messages=100 \
  --bytes=64 --repeats=8
```

## 4. Framing measurements

`run-framing-microbench.pl` compares two canonical Stream subclasses on the
same delimiter wire protocol:

- `raw-on-data` buffers and searches for boundaries in the named Perl callback
- `native-delimiter` uses the built-in native Delimiter parser

Both use the same XS read/write engine. This isolates the practical reason to
add a general framing family natively while preserving raw `on_data` as the
fallback for application-specific protocols.

`run-native-framers-microbench.pl` measures each canonical native built-in
through a declarative Stream subclass. The current matrix is Delimiter, Fixed,
LengthPrefix, U32BE, Netstring, Varint, and DecimalLength. There is no custom
Perl parser mode or factory-object row in the current API.

```bash
perl -Mblib bench/run-native-framers-microbench.pl \
  --framers=delimiter,fixed,length,u32be,netstring,varint,decimal \
  --clients=1,10,100 --warmup=10 --messages=100 --bytes=64 --repeats=6
```

Compare framer rows only at identical payload sizes, client counts, host load,
and build flags. Different wire formats have different prefix sizes and parser
work.

## 5. Stream lifecycle and retained memory

`run-stream-lifecycle-bench.pl` is the versioned before/after measurement for
the subclass-descriptor redesign. It reports:

- construction/detach operations per second and process CPU microseconds per
  operation over pre-created socketpairs
- retained RSS delta for live objects in fresh child processes after socket,
  loop, and retention-vector setup

Benchmark contract 1 preserves the object-configured baseline workloads. The
current adapter is `subclass-descriptor`; `framed-full-named` is the primary
comparable case. `watcher` is an internal registration-shaped floor, not a
Stream feature-equivalence claim.

Build, raise the file-descriptor limit, and run the after snapshot with the same
settings used for the baseline:

```bash
perl Makefile.PL
make
ulimit -n 100000
perl -Mblib bench/run-stream-lifecycle-bench.pl \
  --api-style=subclass-descriptor \
  --iterations=100000 \
  --pool=256 \
  --live=1000,10000,20000 \
  --warmup=1000 \
  --repeats=7 \
  --memory-repeats=3 \
  --json=bench/results/stream-lifecycle-after.json
```

The old source revision produced the matching baseline with
`--api-style=object-configured`. Do not try to pass that label to the redesigned
source: the constructor no longer exists. Compare the two JSON files only when
`benchmark_contract_version`, `workload`, case list, iteration counts, live
counts, Perl, compiler flags, and machine are equivalent.

For `framed-full-named`, compare median CPU time per operation first, then
operations/second and retained bytes/object. RSS is page-granular, so the larger
live counts are the meaningful memory samples. Each socketpair consumes two
file descriptors; increase `ulimit -n` or lower `--live` if creation fails.
