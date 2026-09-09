from pathlib import Path


def replace(path, old, new, count=1):
    file = Path(path)
    text = file.read_text()
    if text.count(old) < count:
        raise SystemExit(f"{path}: expected text not found")
    file.write_text(text.replace(old, new, count))


manifest = Path('MANIFEST')
text = manifest.read_text()
if 'bench/run-tls-accept-setup-bench.pl\n' not in text:
    text = text.replace(
        'bench/run-tls-microbench.pl\n',
        'bench/run-tls-accept-setup-bench.pl\nbench/run-tls-microbench.pl\n',
        1,
    )
if 't/tls-42-accept-setup-benchmark-smoke.t\n' not in text:
    text = text.replace(
        't/tls-41-transition-leftover.t\n',
        't/tls-41-transition-leftover.t\nt/tls-42-accept-setup-benchmark-smoke.t\n',
        1,
    )
manifest.write_text(text)

replace(
    't/20-public-surface.t',
    """    'bench/run-tls-microbench.pl',
    'bench/run-stream-transition-bench.pl',
""",
    """    'bench/run-tls-accept-setup-bench.pl',
    'bench/run-tls-microbench.pl',
    'bench/run-stream-transition-bench.pl',
""",
)

replace(
    't/20-public-surface.t',
    """    run-stream-payload-sweep.pl
    run-tls-microbench.pl
    run-stream-transition-bench.pl
""",
    """    run-stream-payload-sweep.pl
    run-tls-accept-setup-bench.pl
    run-tls-microbench.pl
    run-stream-transition-bench.pl
""",
)

replace(
    'bench/README.md',
    """## TLS

`run-tls-microbench.pl` compares established plain and OpenSSL transport paths
for public `IO::Sock::Stream` subclasses. TLS handshake cost is a separate
lifecycle concern unless a benchmark mode explicitly includes it.

Use the same certificate fixtures, OpenSSL build, Perl build, socket-buffer
settings, and host state when comparing reports.
""",
    """## TLS

`run-tls-microbench.pl` compares established plain and OpenSSL transport paths
for public `IO::Sock::Stream` subclasses. It deliberately excludes construction
and handshake from the timed message interval.

`run-tls-accept-setup-bench.pl` isolates accepted-connection TLS setup. The
`fresh_context` row constructs and loads a server `SSL_CTX` for every simulated
connection. The `prepared_clone` row prepares one Listener-style server context
and then allocates only independent per-connection TLS state:

```bash
perl -Mblib bench/run-tls-accept-setup-bench.pl \
  --iterations=1000 --repeats=7 \
  --json=bench/results/tls-accept-setup.json
```

The benchmark reports the one-time prepared-context cost separately and does
not time TLS handshake. Together the two TLS harnesses distinguish deployment
setup cost from steady-state encrypted I/O cost.

Use the same certificate fixtures, OpenSSL build, Perl build, socket-buffer
settings, and host state when comparing reports.
""",
)
