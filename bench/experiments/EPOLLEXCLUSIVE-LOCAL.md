# Local sustained EPOLLEXCLUSIVE benchmark

This is a **research-only** experiment on `feature/epollexclusive-evaluation`.
It does not enable EPOLLEXCLUSIVE in a regular Linux::Event program.
No root access, external benchmarking tool, sysctl changes, or CPU pinning are needed.

## Build and run (from the repository root)

```sh
git fetch origin
git switch feature/epollexclusive-evaluation
git pull --ff-only
perl Makefile.PL
make -j4
perl -Mblib bench/experiments/epollexclusive-local.pl
```

The runner prints a **Saved results file** path under
`bench/results/epollexclusive/`. Send that single `.jsonl` file back for analysis.
Result files in this directory are Git-ignored.

## What it does

Each trial creates fresh Linux::Event worker processes and runs a real TCP
request/reply exchange on localhost, with a one-byte request and a one-byte
Stream reply. It tests ordinary fork-shared epoll, shared EPOLLEXCLUSIVE,
and independently created SO_REUSEPORT listeners.

The defaults run 2 and 4 worker processes, with 0 and 150 microseconds of
simulated CPU processing per request. Every configuration runs for 15 measured
seconds, twice, rotating the configuration order between repetitions.
Two independent client-generator processes each maintain up to 32 outstanding
TCP requests. Worker event loops continue briefly after the request window
to finish pending replies, then return their statistics.

This is a single-host, short-connection **accept** benchmark, not a full
HTTP/TLS throughput benchmark. The two client processes compete with workers
for the machine's CPUs. This is intentional and is disclosed in the results.

Measurements in the JSONL file:

- Completed application replies per measured second
- Approximate worker CPU time (high-resolution process CPU clock)
- Client-generator CPU time, to detect generator saturation
- Client response latency p50/p95/p99 (pooled 0.1-ms bins)
- Each worker's accepted connection count, error count and epoll waits
- Jain fairness score, where 1 means evenly distributed acceptance
- Failed requests, missing responses, and missing worker reports
- Kernel release, CPU model and logical CPU count (not username or hostname)

Latency includes the local client-side TCP setup and request/reply time.
The server and client both use CPU, so results can vary with background load.
With a quad-core machine, especially watch for generator saturation warnings
and uneven worker distribution, not just the highest requests/second figure.

## Custom duration or shorter diagnostic run

```sh
perl -Mblib bench/experiments/epollexclusive-local.pl --seconds 20 --repeats 3
```

For a quick dry run rather than a full measurement:

```sh
perl -Mblib bench/experiments/epollexclusive-local.pl \
  --seconds 2 --repeats 1 --workers 2 --work-us 0 --clients 16
```

Use `--help` to see all switches, including `--generators`,
`--accept-budget`, and `--output`.

## Precautions

Close other CPU-heavy programs, do not run multiple copies of this test
at once, and avoid changing power profiles or kernel settings between runs.
The benchmark creates many short localhost TCP connections; it enables
SO_LINGER reset **on the test clients only** to avoid exhausting ephemeral
ports through TIME_WAIT. It never modifies global network settings.

The result file stores CPU/kernel information and timings but deliberately
omits hostname, account name, IP address, and raw application payloads.

An automated smoke run checks all three modes in GitHub Actions, but actual
performance conclusions require your local quad-core measurements.
Main is unchanged; PR #36 is a draft.
