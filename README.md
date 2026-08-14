# Linux::Event

Linux::Event is a Linux-only event and stream-processing foundation for Perl.
It combines an XS-first `epoll` reactor with a high-level native buffered Stream
layer in one distribution.

The layers remain deliberately separate:

```text
application / protocol
        |
Linux::Event::Stream       buffered reads, writes, backpressure, framing
        |
Linux::Event::XSLoop       generic fd readiness and timers
        |
      epoll
```

## Current capabilities

### Reactor

- native `epoll_create1` / `epoll_wait` loop
- native watcher registry and direct `epoll_event.data.ptr` dispatch
- read, write, and terminal/error readiness callbacks
- watcher replacement and idempotent removal
- level-triggered operation with optional edge-triggered/oneshot flags
- no-argument callback fast path and bounded callback scopes
- runtime read/write interest changes
- profiling/statistics support

### Stream

- native read draining
- native immediate writes and segmented queued output
- `writev()` queue draining
- high/low-watermark backpressure with `on_drain`
- pause/resume reads
- independent peer EOF and writable half-close
- graceful `end()`, immediate `close()`, and ownership-transfer `detach()`
- native framed input storage
- native `Delimiter`, `Fixed`, `LengthPrefix`, `U32BE`, `Netstring`, `Varint`, and `DecimalLength` framing
- custom Perl framers through a stable native-backed Buffer view

The raw reactor never performs application I/O automatically. Stream is the
higher-level layer for applications that want owned byte-stream I/O.

## Build and test

```bash
perl Makefile.PL
make
make test
```

Both native extensions are built by the same distribution and placed in the
same `blib` tree.

To use the just-built copy without installing it:

```bash
export PERL5LIB="$PWD/blib/lib:$PWD/blib/arch"
```

## Minimal Stream example

```perl
use v5.36;
use Linux::Event::XSLoop;
use Linux::Event::Stream;

my $loop = Linux::Event::XSLoop->new;

my $watcher = $loop->watch(
    fh   => $listener,
    read => sub ($watcher) { ... },
);

my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $socket,
    on_data => sub ($stream, $bytes) {
        $stream->write($bytes);
    },
);

$loop->run;
```

## Framing

Framing turns TCP's byte stream into complete application messages. Built-in
framers execute their boundary detection in XS. Construct them through the
user-facing factory:

```perl
use Linux::Event::Stream::Framer;

my $lines = Linux::Event::Stream::Framer->line;
my $binary = Linux::Event::Stream::Framer->length_prefix(
    bytes => 4, endian => 'big',
);
my $compact_binary = Linux::Event::Stream::Framer->varint;
my $octet_counted = Linux::Event::Stream::Framer->decimal_length;
```

Built-in framing definitions are safe to share across Streams; each Stream
keeps independent native parser state.

“Native framing” here means incoming boundary detection. `send()` uses the
built-in's Perl `frame()` method, then hands the framed bytes to the native
Stream write engine.

If you know what a protocol's wire format looks like but not the framer name,
start with [`docs/CHOOSING-A-FRAMER.md`](docs/CHOOSING-A-FRAMER.md).

Detailed framing internals and the custom-framer contract are in
[`docs/FRAMING.md`](docs/FRAMING.md).

## Documentation

- [`docs/CORE.md`](docs/CORE.md) - raw reactor API and watcher lifecycle
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - native reactor architecture
- [`docs/STREAM-DESIGN.md`](docs/STREAM-DESIGN.md) - Stream contract and design
- [`docs/CHOOSING-A-FRAMER.md`](docs/CHOOSING-A-FRAMER.md) - novice-friendly framer selection
- [`docs/FRAMING.md`](docs/FRAMING.md) - framing plug-in contract and native built-ins
- [`docs/XS-ROADMAP.md`](docs/XS-ROADMAP.md) - remaining native work
- [`bench/README.md`](bench/README.md) - reactor and Stream benchmarks
- [`docs/DEVELOPMENT-HISTORY.md`](docs/DEVELOPMENT-HISTORY.md) - historical optimization notes

## Project direction

Linux::Event intentionally targets Linux rather than carrying a portability
layer. The core principle is to keep mechanical event, byte, buffer, and framing
work native while delivering semantic events to ordinary Perl application code.

## License

This project is distributed under the same terms as Perl itself.
