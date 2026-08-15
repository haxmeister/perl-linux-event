# Stream design

`Linux::Event::Stream` is the owned buffered byte-stream layer above the generic
`Linux::Event::XSLoop` reactor. It is intentionally Linux-only and uses native
code for repetitive I/O, queue, buffer, and built-in framing work.

## Type model

`Linux::Event::Stream` is a base class. An application defines each stream type
as an ordinary Perl package:

```perl
package ChatStream;
use parent 'Linux::Event::Stream';
use Linux::Event::Stream::Framer 'Delimiter', "\n";

sub on_message ($stream, $message) { ... }
sub on_drain   ($stream)           { ... }
sub on_eof     ($stream)           { ... }
sub on_error   ($stream, $error)   { ... }
sub on_close   ($stream)           { ... }
```

A package does not imply one global connection. It defines shared behavior.
Each object remains a distinct connection and carries its application value in
`data`:

```perl
my $stream = ChatStream->new(
    loop => $loop,
    fh   => $socket,
    data => {
        user_id    => $user_id,
        permissions => $permissions,
        rooms       => {},
    },
);
```

## Class descriptor

The first construction of each concrete subclass performs all class-level work
once:

1. resolve `on_data`, `on_message`, and optional lifecycle methods through the
   class MRO;
2. resolve the nearest inherited native framer declaration;
3. call and validate `stream_options`;
4. validate that the class is either raw or framed, never both;
5. create one immutable XS descriptor holding parser config, transport policy,
   and callback references.

Subsequent construction retrieves that descriptor from the class cache. The
Perl object and native connection state each retain a reference to it.

Immutable descriptor state includes:

- named callback CVs
- native read mode and framing constants
- delimiter or prefix policy where applicable
- `read_size`
- high and low output watermarks
- framed `max_buffer`

Per-connection native state includes:

- fd and Stream reference
- pause, EOF, close, and backpressure flags
- native input bytes and parser scan state
- segmented output queue and pending byte count
- instrumentation counters

Per-connection Perl state includes the loop, handle, watcher, optional `data`,
and semantic lifecycle flags. It does not contain callback option hashes or a
framer object.

## Input paths

### Raw subclass

```text
EPOLLIN -> XS read drain -> on_data($stream, $bytes)
```

The reusable native read buffer is copied into a Perl byte scalar only after a
successful read. XS continues until EAGAIN unless the callback pauses or closes
the Stream.

### Framed subclass

```text
EPOLLIN -> XS read drain -> native input storage -> native parser
        -> on_message($stream, $message)
```

Complete built-in frames are detected without delivering intermediate read
chunks to Perl. Multiple messages can be emitted from one readiness event.
Partial prefixes, delimiters, and payloads remain in connection-local native
state. The loop rechecks pause and close state after every callback.

## Output path

`write($bytes)` first attempts an immediate native write. Partial output or
EAGAIN creates independent native queue segments. EPOLLOUT drains those segments
with `writev()` without first concatenating them in Perl.

Crossing `high_watermark` makes `write()` return false even though the bytes are
accepted. When pending bytes reach `low_watermark` or less, XS clears the
blocked state before calling `on_drain`, allowing reentrant writes to begin a
new backpressure interval safely.

`send($payload)` is framed-only. It applies the class's outbound built-in
encoding and then uses `write()`.

## Lifecycle

- `pause_read` and `resume_read` change input interest while preserving state.
- Peer EOF marks the readable half closed and invokes `on_eof` once.
- `end` drains queued output before `shutdown(SHUT_WR)`.
- The Stream closes automatically after both halves have ended.
- `close` cancels immediately and may discard queued output.
- `detach` cancels Stream ownership and returns the still-open filehandle;
  `on_close` does not run because the resource was not closed.
- I/O and framing failures create `Linux::Event::Stream::Error`, invoke
  `on_error` if present, and close.

Application callback exceptions propagate. They are not treated as transport
or framing errors.

## Class transport policy

`stream_options` may return a key/value list or hash reference:

```perl
sub stream_options ($class) {
    return {
        read_size      => 65_536,
        high_watermark => 1_048_576,
        low_watermark  => 262_144,
        max_buffer     => 8_388_608,
    };
}
```

It runs once per concrete subclass. Unknown options, invalid integers, and a low
watermark above the high watermark fail before connection registration.

## Framing policy

Native framing is declared by exact package name. No keyword registry, factory
object, arbitrary `next_frame` object, or Buffer facade exists. This keeps the
hot model singular: built-ins are native; application-specific rules use raw
`on_data`.

A generally useful new family should add a named module and corresponding XS
parser mode. The naming convention lets the loader find that package without a
second list.

## Performance consequences

The redesign improves construction and retained memory by moving immutable work
from every object to one class descriptor. It removes per-connection callback
hash entries, framer allocation, option parsing, repeated validation, and
copies of native transport/framing configuration. Named callbacks also avoid
fresh closure allocation and are invoked through cached CVs rather than method
lookup.

It does not remove the intentional Perl crossing for semantic `on_data` or
`on_message` work. It also does not make application state global: `data`, input
storage, parser progress, output, and lifecycle remain connection-local.

Use `bench/run-stream-lifecycle-bench.pl` for constructor and retained-memory
effects, `bench/run-stream-microbench.pl` for raw transport overhead, and the
framing benchmarks for parser work.
