# Linux::Event

Linux::Event is a Linux-only event and stream-processing foundation for Perl.
It combines an XS-first `epoll` reactor with a native buffered Stream layer in
one distribution.

The layers remain deliberately separate: `Linux::Event::XSLoop` reports generic
descriptor readiness, while `Linux::Event::Stream` owns byte-stream reads,
writes, buffering, backpressure, lifecycle, and optional message framing.

## Current capabilities

### Reactor

- native `epoll_create1` / `epoll_wait` loop
- native watcher registry and direct `epoll_event.data.ptr` dispatch
- read, write, and terminal/error readiness callbacks
- watcher replacement and idempotent removal
- level-triggered operation with optional edge-triggered/oneshot flags
- no-argument callback fast path and bounded callback scopes
- runtime read/write interest changes
- profiling and statistics support

### Stream

- subclass-defined behavior with one cached descriptor per Stream type
- named callback CVs resolved once and called directly
- native read draining and framed-input storage
- native immediate writes and segmented `writev()` queue draining
- high/low-watermark backpressure with `on_drain`
- pause/resume reads
- independent peer EOF and writable half-close
- graceful `end()`, immediate `close()`, and ownership-transfer `detach()`
- native `Delimiter`, `Fixed`, `LengthPrefix`, `U32BE`, `Netstring`, `Varint`,
  and `DecimalLength` framing

The raw reactor never performs application I/O automatically. Stream is the
higher-level layer for applications that want owned byte-stream I/O.

## Build and test

```bash
perl Makefile.PL
make
make test
```

Both native extensions are built into the same `blib` tree. To use that copy
without installing it:

```bash
export PERL5LIB="$PWD/blib/lib:$PWD/blib/arch"
```

## Raw Stream example

A Stream type is an ordinary package. It may live in the same file as the rest
of the program.

```perl
use v5.36;
use Linux::Event::XSLoop;

package EchoStream;
use parent 'Linux::Event::Stream';

sub on_data ($stream, $bytes) {
    $stream->write($bytes);
}

sub on_error ($stream, $error) {
    warn "$error\n";
}

package main;
my $loop = Linux::Event::XSLoop->new;
my $stream = EchoStream->new(
    loop => $loop,
    fh   => $socket,
    data => { user_id => 42 },
);
$loop->run;
```

`data` is the optional per-connection application value. It is the natural
place for a user record, permissions, room membership, parser state for a raw
protocol, or other connection-specific state.

## Framed Stream example

Framing turns a byte stream into complete messages. A framed type adds one
declaration after `use parent` and implements `on_message`:

```perl
package LineEchoStream;
use parent 'Linux::Event::Stream';
use Linux::Event::Stream::Framer 'Delimiter', "\n";

sub on_message ($stream, $message) {
    $stream->send($message);
}
```

The declaration name is the exact final component below
`Linux::Event::Stream::Framer`. There is no alias table or per-connection
framer object. Examples:

```perl
use Linux::Event::Stream::Framer 'Fixed', size => 32;
use Linux::Event::Stream::Framer 'LengthPrefix',
    bytes => 4, endian => 'big', max_frame => 16 * 1024 * 1024;
use Linux::Event::Stream::Framer 'U32BE',
    max_frame => 16 * 1024 * 1024;
use Linux::Event::Stream::Framer 'Netstring', max_frame => 1_048_576;
use Linux::Event::Stream::Framer 'Varint', max_frame => 1_048_576;
use Linux::Event::Stream::Framer 'DecimalLength',
    separator => ' ', max_frame => 1_048_576;
```

Built-in boundary detection runs in XS. `send()` applies the declared outbound
wire encoding and hands the result to the native write engine. Every instance
has independent parser and queue state even though immutable configuration and
callbacks are shared through its class descriptor.

Protocols without a suitable built-in should define a raw `on_data` Stream and
parse there. Arbitrary Perl framer objects are intentionally not accepted.
Generally useful framing families can be added as native built-ins without
adding a duplicate keyword registry.

## Class transport options

Transport policy also belongs to the Stream type and is cached once:

```perl
sub stream_options ($class) {
    return (
        read_size      => 32_768,
        high_watermark => 2 * 1024 * 1024,
        low_watermark  => 512 * 1024,
        max_buffer     => 16 * 1024 * 1024,
    );
}
```

The base `Linux::Event::Stream` class is not directly constructible. The old
constructor callback, framer-object, and per-object transport options were
removed by design.

## Why subclass descriptors

The first construction of a Stream subclass resolves its callback methods,
framer declaration, native parser configuration, and transport settings into
one immutable Perl/XS descriptor. Each connection refers to that descriptor
and allocates only mutable I/O and lifecycle state. This removes repeated
callback hashes, framer objects, option parsing, validation, and native config
copies from connection construction. Hot dispatch calls cached named CVs rather
than performing method lookup.

Use `bench/run-stream-lifecycle-bench.pl` to measure construction and retained
memory against the versioned object-configured baseline.

## Documentation

- [`docs/CORE.md`](docs/CORE.md) - raw reactor API and watcher lifecycle
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - native reactor and Stream architecture
- [`docs/STREAM-DESIGN.md`](docs/STREAM-DESIGN.md) - Stream descriptor and lifecycle contract
- [`docs/CHOOSING-A-FRAMER.md`](docs/CHOOSING-A-FRAMER.md) - choosing a native framing family
- [`docs/FRAMING.md`](docs/FRAMING.md) - declarations, wire formats, and extension policy
- [`docs/XS-ROADMAP.md`](docs/XS-ROADMAP.md) - remaining native work
- [`bench/README.md`](bench/README.md) - reactor and Stream benchmarks
- [`docs/DEVELOPMENT-HISTORY.md`](docs/DEVELOPMENT-HISTORY.md) - historical optimization notes

## Project direction

Linux::Event intentionally targets Linux rather than carrying a portability
layer. Mechanical event, byte, buffer, queue, and framing work belongs in
native code; ordinary named Perl callbacks receive semantic events.

## License

This project is distributed under the same terms as Perl itself.
