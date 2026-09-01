# Stream and Socket design

`Linux::Event::Stream` is the generic buffered sequential-byte abstraction.
`Linux::Event::Socket` is its connected `SOCK_STREAM` specialization.

```text
Linux::Event::Stream
    `-- Linux::Event::Socket
```

This boundary is semantic, not an implementation split. Both classes use the
same native descriptor, parser, consumer context, input storage, segmented
output queue, activity counters, and read/write engines.

## Generic Stream handles

A Stream owns at least one byte-oriented handle:

```perl
MyStream->new(fh => $duplex_fh);
MyStream->new(read_fh => $input, write_fh => $output);
MyStream->new(read_fh => $input);
MyStream->new(write_fh => $output);
```

`fh` means that one descriptor supplies both directions. It is mutually
exclusive with `read_fh` and `write_fh`. `fh()` returns that shared handle and
returns `undef` for split streams; `read_fh`, `write_fh`, `read_fd`, and
`write_fd` are unambiguous.

Each unique descriptor is set nonblocking and close-on-exec. A shared handle
uses one Loop watcher. Distinct handles use one read watcher and one write
watcher, both pointing at the same XS state. The write watcher is registered
without permanent writable interest: `write()` first attempts an immediate
native write, EPOLLOUT is enabled only after partial output or EAGAIN, and is
disabled again when the native queue empties.

The class descriptor may omit inbound callbacks for a write-only instance. A
readable raw instance requires `on_data`; a readable framed instance requires
`on_message`, `on_messages`, or a native consumer.

## Directional lifecycle

Read and write termination are independent normal states.

- Read EOF disables the read direction and calls `on_eof`. It does not end an
  independent write direction.
- `end($final_bytes)` accepts optional final bytes, drains queued output, then
  ends the write direction. For a distinct write handle, Stream closes that
  handle so its peer observes EOF.
- For one generic shared non-socket handle, Stream can stop accepting writes
  but cannot manufacture a kernel half-close that the descriptor type does
  not provide. Socket maps the same operation to `shutdown(SHUT_WR)`.
- `close_read` and `close_write` stop one direction immediately. They do not
  report `on_eof`, because application closure is not peer EOF.
- `close` immediately cancels both directions, discards queued output, closes
  every unique owned handle, and calls `on_close` once.
- Normal completion calls `on_close` only after both available directions are
  terminal. Thus read-only EOF and write-only completed `end` close the object,
  while duplex read EOF alone does not.
- Generic `detach` requires an empty output queue, cancels the abstraction,
  and returns `{ read_fh => ..., write_fh => ... }` without closing either
  handle. Socket always has one shared handle and returns that handle directly.
- `pause_read` and `resume_read` affect only the read direction. Output
  backpressure remains producer-driven through `write`, `on_drain`, and
  `pending_bytes`; Stream never permanently watches writable readiness.

I/O, framing, output-limit, deadline, and transport errors retain the existing
terminal-object policy. Normal EOF and normal local write completion are the
directional cases; errors do not silently leave a potentially inconsistent
protocol half alive.

## Native organization

`les_xsstate_t` contains `read_fd` and `write_fd`, which may be equal or may be
`-1` when a direction is absent. It still owns exactly one of each expensive or
stateful mechanism:

- immutable shared class descriptor;
- reusable raw read buffer or framed input storage;
- native framer scan state;
- optional native consumer context;
- segmented output queue and watermarks;
- optional activity timestamps and counters.

The plain fast path calls `read(read_fd)`, `write(write_fd)`, and
`writev(write_fd)` directly. No reader/writer object pair, duplicate queue,
extra Perl callback, or closure was introduced. Socket's common same-fd path
therefore differs only in field naming and retains one watcher.

## Stream responsibilities

Stream owns native reads and queued writes, input and output buffering, native
framing, raw and framed callback delivery, native consumer delivery, batching,
pause/resume, high/low watermarks, hard limits, established idle/read/write
deadlines, protocol transitions, and directional handle ownership.

Framing is a property of incoming bytes, not of sockets. `send()` likewise
uses the declared framer's outbound encoding before entering the generic write
engine.

## Socket responsibilities

Socket requires one connected `SOCK_STREAM` handle and adds:

- adopted and accepted socket validation;
- outbound `connect` and its resolver/Happy Eyeballs engine;
- local and peer `Linux::Event::Address` values;
- `socket_options` class policy and constructor overrides;
- `configure_socket` acquisition hook;
- TCP and socket buffer accessors;
- kernel read/write shutdown and half-close behavior;
- connection, handshake, and TLS shutdown deadlines;
- declarative TLS transport setup and TLS information accessors.

Listener requires its `stream_class` to inherit from Socket. TCP, Unix stream
socket, socketpair, and TLS protocol subclasses therefore inherit from Socket.
Datagram remains separate.

## Deadlines

Established idle, read, write, and explicit operation deadlines remain generic
Stream policy. Candidates are generated only for directions that exist and are
active. Socket connection timeout and TLS handshake/shutdown deadlines remain
socket acquisition or transport policy.

## Protocol transitions

`transition_to` swaps only the generic class descriptor and retains the native
state, handles, queue, transport, parser storage, and consumer context. A
transition may not cross the Stream/Socket inheritance boundary: doing so
would change handle and shutdown semantics while retaining the same live
object.

## Native consumer ABI

The framed-message consumer ABI remains owned by generic Stream and remains
independent of Linux::Event::Async. Its v1 tables, message ownership,
pause/resume behavior, and existing event values are unchanged. Two additive
input-terminal semantics distinguish explicit directional read closure with
the additive `READ_CLOSED` event. Socket subclasses use the same ABI without a
Socket-specific consumer path.
