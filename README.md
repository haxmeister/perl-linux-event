# Linux::Event

Linux::Event is a Linux-only event reactor built around `epoll`, with the hot
loop, watcher registry, event dispatch, and callback path implemented in XS.
This repository snapshot represents the current optimized reactor core. The
next development stage is an XS-backed buffered stream layer; that layer is not
documented as finished functionality yet.

## What works now

- native `epoll_create1` / `epoll_wait` loop
- one native watcher per file descriptor
- direct `epoll_event.data.ptr` dispatch to the watcher record
- read, write, and terminal/error readiness callbacks
- watcher replacement and idempotent removal
- level-triggered operation by default, with optional edge-triggered/oneshot flags
- no-argument callback fast path for profiled hot code
- bounded Perl callback temporary scopes
- runtime watcher read/write interest changes
- event-loop statistics and optional profiling counters
- balanced same-work benchmark harness against EV, AnyEvent/EV, UV::Poll,
  IO::Async::Loop::Epoll, and Mojo::Reactor::Epoll

The current strict 64-byte TCP echo comparison places Linux::Event in the same
reactor-efficiency tier as EV/libev while using the exact same Perl
`sysread`/`syswrite` body for every ranked implementation.

## Build and test

```bash
perl Makefile.PL
make
make test
```

To use the just-built copy without installing it:

```bash
export PERL5LIB="$PWD/blib/lib:$PWD/blib/arch"
```

## Minimal core example

```perl
use v5.36;
use IO::Handle;
use Linux::Event::XSLoop;

pipe(my $read_fh, my $write_fh) or die "pipe: $!";
$read_fh->blocking(0);

my $loop = Linux::Event::XSLoop->new;

my $watcher = $loop->watch_fd(
    fileno($read_fh),
    fh => $read_fh,
    read => sub ($watcher) {
        my $fh = $watcher->fh;
        my $buf = '';
        my $n = sysread($fh, $buf, 8192);

        if (defined $n && $n > 0) {
            say "received: $buf";
        }

        $watcher->cancel;
        $loop->stop;
    },
);

syswrite($write_fh, "hello");
$loop->run;
```

The core is deliberately a **reactor**: readiness callbacks decide what I/O to
perform. Automatic read buffers, write queues, backpressure, and framing belong
in the upcoming Stream layer rather than in the generic fd watcher.

## Documentation

- [`docs/CORE.md`](docs/CORE.md) - core API, callback model, watcher lifecycle,
  and examples
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - how the XS reactor is laid out
- [`docs/XS-ROADMAP.md`](docs/XS-ROADMAP.md) - planned native work from this point
  forward
- [`bench/README.md`](bench/README.md) - installing competitors and running the
  permanent reactor comparison
- [`docs/DEVELOPMENT-HISTORY.md`](docs/DEVELOPMENT-HISTORY.md) - preserved
  optimization-phase notes for historical reference

## Benchmark quick start

```bash
ulimit -n 100000

perl bench/run-reactor-comparison.pl --build --check-deps

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

The HTML report is fully offline and includes sortable columns plus text,
system, and client-count filters.

## Project direction

The generic reactor is now considered performance-stable. New performance work
should move mechanical byte-stream work below Perl while preserving the raw
reactor API. See [`docs/XS-ROADMAP.md`](docs/XS-ROADMAP.md).

## License

This project is distributed under the same terms as Perl itself.
