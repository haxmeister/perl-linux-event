# Linux::Event Stream Tuning Explorer

This is a dependency-free browser UI for exploring how inbound
`Linux::Event::Stream` tuning changes throughput across message sizes.

The page understands the actual inbound Stream policy knobs:

- `read_size`
- `read_budget_bytes`
- `message_batch_size` for framed Streams
- `read_batch_bytes` for raw Streams
- `max_buffer`

Output watermarks and `max_pending_bytes` are deliberately not shown because
those govern outbound buffering rather than the inbound throughput curve.

## Open the explorer

Open `index.html` in a browser. No web server and no JavaScript package install
are required.

Without benchmark data, the page runs in **HEURISTIC PREVIEW** mode. The preview
exists only so the controls and chart can be exercised; its numbers are not
Linux::Event benchmark results.

## Generate measured data

Build Linux::Event first, then run the tuning sweep from the distribution root:

```sh
perl -Iblib/lib -Iblib/arch bench/run-stream-tuning-sweep.pl \
  --json bench/results/stream-tuning.json
```

For a denser sweep:

```sh
perl -Iblib/lib -Iblib/arch bench/run-stream-tuning-sweep.pl \
  --message-sizes=16,32,64,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,200000 \
  --read-sizes=4096,16384,65536,262144 \
  --read-budgets=0,65536,262144 \
  --message-batch-sizes=0,4,16,64,256 \
  --json bench/results/stream-tuning-dense.json
```

Then click **Load sweep JSON** in the explorer and select the generated file.

The browser distinguishes three data states:

- **EXACT MEASURED**: the selected configuration exists in the loaded sweep.
- **MEASURED INTERPOLATION**: the curve is interpolated from nearby measured
  configurations in log-throughput space.
- **HEURISTIC PREVIEW**: no compatible measured series is loaded.

The dashed best-known line is the fastest loaded series at each measured
message size. It is an envelope and may therefore be made from different
tuning configurations at different message sizes.

## Benchmark scope

The sweep measures application-side receive throughput over either an AF_UNIX
socketpair or loopback TCP. It excludes remote network latency. It still
includes the Linux socket path, Stream dispatch, native framing/buffering, and
Perl callback cost.

This first benchmark uses either raw byte delivery or the native delimiter
framer. It is intended to measure Stream tuning, not compare framer families.
Framer-family sweeps can be added to the same JSON contract later.
