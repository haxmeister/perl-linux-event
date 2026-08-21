# Linux::Event

Linux::Event is a Linux-only event and stream-processing foundation for Perl.
It combines an XS-first `epoll` reactor with inbound and outbound connection
acquisition, a native buffered Stream layer, and an OpenSSL TLS transport in
one distribution.

The public model is deliberately small. `Linux::Event::Loop` owns readiness
and scheduled work; `Linux::Event::Stream` owns established and connecting
byte streams; `Linux::Event::Listener` owns listening sockets; and
`Linux::Event::Timer` owns a scheduled callback. There is no public Watcher,
IO, Connect, or Connector class. Native epoll registrations remain opaque, so
one logical object may use several kernel event sources without exposing them
as more application objects.

## Public modules

- `Linux::Event::Loop` - epoll engine and object attachment
- `Linux::Event::Stream` - TCP/Unix stream endpoints and outbound connection
- `Linux::Event::Listener` - TCP/Unix listening endpoints
- `Linux::Event::Timer` - subclass-defined one-shot and recurring timers
- `Linux::Event::TLS` - optional OpenSSL transport provider for Stream
- `Linux::Event::Framer::*` - native framing declarations for Stream types
- `Linux::Event::Error` - shared structured failure value
- `Linux::Event::Address` - lazy IPv4, IPv6, and Unix address value

`Linux::Event::Listener::_Engine` and `Linux::Event::Stream::_Connection` are
private implementation packages. Applications must not construct, subclass, or
depend on them.

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

### Object lifecycle

- `loop => $loop` on every attachable public object
- equivalent detached construction followed by `$loop->add($object)`
- strict one-Loop, one-attachment ownership
- `add()` sets the Loop and returns the same object
- raw `watch()` returning an already-attached opaque registration handle
- no generic Perl dispatch layer in the readiness hot path

### Timer

- subclass-defined `on_timer($timer)` callbacks cached once per Timer type
- relative, absolute monotonic, and fixed-rate recurring schedules
- one lazily created `timerfd` and one indexed native minimum heap per Loop
- same-deadline FIFO ordering and bounded expiration batches
- coalesced missed periodic ticks exposed through `expirations`
- idempotent terminal cancellation and deterministic application-data cleanup
- in-callback rescheduling without reentrant delivery

### Stream connection

- `MyStream->connect()` as the sole public outbound connection API
- the same Stream object before, during, and after establishment
- IPv4, IPv6, Unix stream, and caller-packed address modes
- nonblocking, close-on-exec sockets created atomically
- default connection deadline implemented with Linux `timerfd`
- typed resolve, socket, connect, and timeout errors
- loop-dispatched immediate outcomes and silent cancellation
- output may be queued before attachment or readiness

### Listener

- TCP, Unix, and adopted listening stream sockets
- socket creation, options, bind, listen, and cleanup owned by one object
- native `accept4` draining with atomic nonblocking and close-on-exec flags
- bounded level-triggered batches for listener fairness
- lazy peer-address conversion and typed runtime errors
- no temporary accepted-socket registration before Stream construction

### Stream

- subclass-defined behavior with one cached descriptor per Stream type
- named callback CVs resolved once and called directly
- native read draining and framed-input storage
- native immediate writes and segmented `writev()` queue draining
- versioned transport ABI with a specialized plain path and built-in OpenSSL
  `Linux::Event::TLS` provider support
- high/low-watermark backpressure with `on_drain`
- optional hard pending-output limits with typed overflow errors
- pause/resume reads
- independent peer EOF and writable half-close
- graceful `end()`, immediate `close()`, and ownership-transfer `detach()`
- in-place transitions between Stream subclasses with unread-input preservation
- native `Delimiter`, `Fixed`, `LengthPrefix`, `U32BE`, `Netstring`, `Varint`,
  and `DecimalLength` framing

The raw reactor never performs application I/O automatically. Stream is the
higher-level layer for applications that want owned byte-stream I/O.

## Loop attachment

Stream, Listener, and Timer accept `loop => $loop`, and may instead be
constructed detached and added later:

```perl
my $client = ClientStream->connect(
    loop => $loop, host => '127.0.0.1', port => 9999,
);

my $server = $loop->add(ServerStream->listen(
    host => '0.0.0.0', port => 9999,
));

my $heartbeat = $loop->add(Heartbeat->new(every => 30));
```

These are equivalent attachment styles. `add()` stores the Loop, starts the
object, and returns that same object. An object can be attached only once and
cannot move between Loops.

## Timer example

Timers follow the same subclass and attachment style as Streams:

```perl
package SessionTimeout;
use parent 'Linux::Event::Timer';

sub on_timer ($timer) {
    $timer->data->close;
}

package main;
my $timeout = $loop->add(SessionTimeout->new(
    after => 30,
    data  => $stream,
));
```

Application context is directly available through `data`, so a timer callback
can close or modify any Stream, Listener, or other state it retains. Use
`reschedule` to replace an active schedule and `cancel` for terminal removal.

## Build and test

```bash
perl Makefile.PL
make
make test
```

All five native extensions are built into the same `blib` tree. Building TLS
requires OpenSSL 1.1.1 or newer, including its development headers and
libraries. To use that copy
without installing it:

```bash
export PERL5LIB="$PWD/blib/lib:$PWD/blib/arch"
```

Before a release, capture or compare the permanent regression suite:

```bash
perl -Mblib bench/run-performance-regression.pl \
  --baseline bench/results/performance-baseline.json \
  --fail-on-regression
```

See [`bench/README.md`](bench/README.md) for baseline capture, thresholds, and
measurement controls.

## Outbound connection example

The same Stream object exists before, during, and after connection setup:

```perl
package GatewayStream;
use parent 'Linux::Event::Stream';

sub on_ready ($stream) {
    $stream->write("GET / HTTP/1.1\r\nHost: gateway.discord.gg\r\n\r\n");
}

package main;
use Linux::Event::Loop;
use Linux::Event::TLS;

my $loop = Linux::Event::Loop->new;
my $stream = $loop->add(GatewayStream->connect(
    host    => 'gateway.discord.gg',
    port    => 443,
    timeout => 10,
    transport => Linux::Event::TLS->client(
        server_name => 'gateway.discord.gg',
    ),
));
$loop->run;
```

`on_ready` means application-ready: TCP is connected and, when configured, the
TLS handshake and verification are complete. `send()` or `write()` may be
called before readiness; bounded output is retained on the Stream and flushed
after connection establishment. Hostname resolution is still synchronous in
this release.

## Line echo server

Listener owns socket setup and automatically constructs the framed Stream.
There is no application-level socket or accepted-filehandle plumbing:

```perl
package EchoStream;
use parent 'Linux::Event::Stream';
use Linux::Event::Framer 'Delimiter', "\n";

sub on_message ($stream, $line) { $stream->send($line) }

package main;
use Linux::Event::Loop;
my $loop = Linux::Event::Loop->new;
my $server = $loop->add(
    EchoStream->listen(host => '0.0.0.0', port => 9999)
);
$loop->run;
```

Runnable versions are
[`examples/line-echo-server.pl`](examples/line-echo-server.pl) and
[`examples/line-echo-client.pl`](examples/line-echo-client.pl).

## Raw Stream example

A Stream type is an ordinary package. It may live in the same file as the rest
of the program.

```perl
use v5.36;
use Linux::Event::Loop;

package EchoStream;
use parent 'Linux::Event::Stream';

sub on_data ($stream, $bytes) {
    $stream->write($bytes);
}

sub on_error ($stream, $error) {
    warn "$error\n";
}

package main;
my $loop = Linux::Event::Loop->new;
my $stream = $loop->add(EchoStream->new(
    fh   => $socket,
    data => { user_id => 42 },
));
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
use Linux::Event::Framer 'Delimiter', "\n";

sub on_message ($stream, $message) {
    $stream->send($message);
}
```

The declaration name is the exact final component below
`Linux::Event::Framer`. There is no alias table or per-connection
framer object. Examples:

```perl
use Linux::Event::Framer 'Fixed', size => 32;
use Linux::Event::Framer 'LengthPrefix',
    bytes => 4, endian => 'big', max_frame => 16 * 1024 * 1024;
use Linux::Event::Framer 'U32BE',
    max_frame => 16 * 1024 * 1024;
use Linux::Event::Framer 'Netstring', max_frame => 1_048_576;
use Linux::Event::Framer 'Varint', max_frame => 1_048_576;
use Linux::Event::Framer 'DecimalLength',
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

## Protocol transitions

One connection does not have to use one protocol definition forever. A
handshake, protocol negotiation, or HTTP upgrade can change the live Stream to
another subclass:

```perl
sub on_data ($stream, $bytes) {
    my ($upgrade, $remaining) = parse_upgrade_request($bytes);
    return if !$upgrade;

    $stream->write(upgrade_response());
    $stream->transition_to('WebSocketStream', input => $remaining);
    return;
}
```

`transition_to()` reblesses the same object and swaps its shared native
descriptor. It retains the filehandle, native registration, XS connection state, queued
output, backpressure and half-close state, `data`, and unread native input.
Bytes already buffered by an old framed parser are reinterpreted by the target
parser. `input` supplies the unconsumed suffix held by a raw callback.

The old parser stops after the callback that requested the transition. Target
dispatch then continues without waiting for another socket read. Existing
queued output stays byte-for-byte ordered; subsequent `send()` calls use the
new framer. A paused Stream remains paused across the transition.

This is a protocol transition, not encryption or descriptor replacement. TLS
belongs at a transport boundary adjacent to Stream rather than pretending to be
a framing rule.

## Class transport options

Transport policy also belongs to the Stream type and is cached once:

```perl
sub stream_options ($class) {
    return (
        read_size         => 32_768,
        high_watermark    => 2 * 1024 * 1024,
        low_watermark     => 512 * 1024,
        max_pending_bytes => 8 * 1024 * 1024,
        max_buffer        => 16 * 1024 * 1024,
    );
}
```

Watermarks are cooperative: a false `write()` return still means the bytes
were accepted and the producer should wait for `on_drain`. A nonzero
`max_pending_bytes` is the separate hard safety boundary. If an unsent
remainder would exceed it, Stream does not queue that remainder; it reports an
`output_limit` error through `on_error` and closes. The default is zero, which
keeps pending output unlimited.

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

- [`docs/CORE.md`](docs/CORE.md) - raw reactor and registration API
- [`docs/OBJECT-LIFECYCLE.md`](docs/OBJECT-LIFECYCLE.md) - Loop attachment and resource ownership
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - native reactor and Stream architecture
- [`docs/TIMER-DESIGN.md`](docs/TIMER-DESIGN.md) - Timer API, scheduler, and lifecycle semantics
- [`docs/STREAM-DESIGN.md`](docs/STREAM-DESIGN.md) - Stream descriptor and lifecycle contract
- [`docs/TRANSPORT-BOUNDARY.md`](docs/TRANSPORT-BOUNDARY.md) - plain transport and TLS provider contract
- [`docs/STREAM-CONNECTIONS.md`](docs/STREAM-CONNECTIONS.md) - outbound acquisition and future resolver contract
- [`docs/LISTENER-DESIGN.md`](docs/LISTENER-DESIGN.md) - inbound acquisition and accept policy
- [`docs/CHOOSING-A-FRAMER.md`](docs/CHOOSING-A-FRAMER.md) - choosing a native framing family
- [`docs/FRAMING.md`](docs/FRAMING.md) - declarations, wire formats, and extension policy
- [`docs/XS-ROADMAP.md`](docs/XS-ROADMAP.md) - remaining native work
- [`bench/README.md`](bench/README.md) - reactor, Timer, and Stream benchmarks
- [`docs/DEVELOPMENT-HISTORY.md`](docs/DEVELOPMENT-HISTORY.md) - historical optimization notes

## Project direction

Linux::Event intentionally targets Linux rather than carrying a portability
layer. Mechanical event, byte, buffer, queue, and framing work belongs in
native code; ordinary named Perl callbacks receive semantic events.

Stream's fd operations pass through an exact-version native transport contract
while its ordinary `plain` provider retains a specialized direct-syscall path.
`Linux::Event::TLS` ships in this distribution as a separate native extension
and attaches at construction without making TLS a framer or adding OpenSSL
policy to XSLoop or the plain Stream path. See
[`docs/TRANSPORT-BOUNDARY.md`](docs/TRANSPORT-BOUNDARY.md).

## License

This project is distributed under the same terms as Perl itself.
