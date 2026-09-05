# Line-delimited runtime comparison

`run-line-runtime-comparison.pl` compares Linux::Event line framing with
recognizable line-oriented TCP APIs in Node.js, Python asyncio, and Ruby.

## Systems

- Linux::Event: `IO::Sock::Listener` with a Stream class using native
  `Delimiter("\n")` framing and a first-class `on_message` closure.
- Node.js: `node:net` socket with `node:readline` `line` events.
- Python: `asyncio.start_server` with `StreamReader.readline()`.
- Ruby: the `async` scheduler with Ruby `Socket#gets`.

This benchmark intentionally compares line-oriented application surfaces. It
is not a contest between hand-written delimiter scanners. A runtime that
provides text or coroutine semantics as part of its ordinary line API pays for
those semantics in its result.

## Fairness contract

- TCP IPv4 loopback.
- Fresh server process for every case.
- All clients connect before warmup.
- Warmup completes before timing.
- One outstanding line per connection.
- Identical Perl `IO::Poll` load generator for every server.
- Four client worker processes by default to reduce load-generator saturation.
- TCP_NODELAY on both sides.
- Payload size excludes the trailing LF byte.
- Exact echoed bytes are verified by every client.
- Server startup, connection setup, and teardown are outside timing.
- Runtime order rotates across repeats.
- Failed rows are retained for diagnosis but are never ranked.

The primary ranking metric is median lines per second. The report also records
MiB/s, sampled p50/p95/p99 latency, server CPU cost per line, server CPU
utilization, and server RSS high-water mark.

## Dependencies

Linux::Event uses the local build. Node.js and Python use their standard
libraries. Ruby requires the `async` gem so blocking-looking `Socket#gets` calls
run cooperatively on an evented fiber scheduler.

Check dependencies first:

```bash
perl bench/run-line-runtime-comparison.pl --build --check-deps
```

## Reference run

```bash
ulimit -n 100000
perl bench/run-line-runtime-comparison.pl --build \
  --systems linuxevent,node,python,ruby \
  --clients 100,500,1000,2500 \
  --bytes 64 \
  --warmup 10 \
  --messages 100 \
  --client-workers 4 \
  --latency-sample-every 10 \
  --repeats 4 \
  --timeout 90 \
  --out bench/results/line-runtime-comparison.html \
  --json bench/results/line-runtime-comparison.json
```

Use a repeat count that is a multiple of the number of selected systems for
perfect execution-position balance. For payload sensitivity, use a
comma-separated `--bytes` list such as `64,512,4096,16384`.
