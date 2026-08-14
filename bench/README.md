# Benchmark Guide

The benchmark directory has two current entry points. Older optimization
experiments are preserved under `bench/archive/` and are not the recommended
way to measure the current core.

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

## 3. Stream transport decomposition

`run-stream-microbench.pl` compares the raw reactor path with Stream's historical
Perl path, native read path, and native read/write path. It is a development
microbenchmark rather than the public cross-runtime leaderboard.

## 4. Framing decomposition

`run-framing-microbench.pl` isolates Perl-buffer framing, native-buffer plus
Perl framing, and fully native delimiter framing.

`run-native-framers-microbench.pl` constructs built-ins through the public
`Linux::Event::Stream::Framer` factory and compares each resulting exact
built-in framer through
the generic Perl `next_frame()` path and its native XS parser. Use this when
adding or changing built-in framers so native acceleration is measured rather
than assumed. The current matrix includes delimiter, fixed, fixed-width length,
U32BE, netstring, and Varint framing.
