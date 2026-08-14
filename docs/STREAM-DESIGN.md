# Stream rewrite design contract

## Purpose

`Linux::Event::Stream` is the byte-stream abstraction above the raw
`Linux::Event::XSLoop` reactor. The reactor reports readiness. Stream owns the
mechanical byte-transport and framing work and calls Perl for semantic events.

The old 0.002 API is a design reference, not a compatibility constraint.

## Public event model

Raw mode:

```text
epoll readiness
  -> native read drain
  -> on_data($stream, $bytes)
```

Built-in framed mode:

```text
epoll readiness
  -> read() directly into native input storage
  -> native built-in frame boundary detection/consume
  -> on_message($stream, $message)
```

Custom framed mode:

```text
epoll readiness
  -> read() directly into native input storage
  -> stable Framer::Buffer view
  -> custom Perl next_frame()
  -> native extract/consume
  -> on_message($stream, $message)
```

Write side:

```text
write($bytes)
  -> native immediate write()
  -> queue remainder on partial/EAGAIN
  -> writable readiness
  -> native writev() drain
```

## Native Stream state

`XSStream.xs` does not include Linux::Event private C structures. The core
passes `Linux::Event::Stream::XSState` directly as watcher callback data.
Native state contains:

```text
fd
read size and read/eof/pause state
native framed-input buffer
custom-framer need(N) threshold
native built-in framer configuration/state
max-buffer/max-frame state
Stream and semantic callback references
native segmented output queue
pending byte count
high/low watermarks and blocked state
read/write/framing instrumentation counters
```

Normal readiness therefore avoids a Perl watcher lookup. Raw reads avoid Perl
`sysread`; writes avoid Perl `syswrite`; framed reads avoid per-read Perl byte
scalars whenever native input storage is selected.

## Native input storage

Framed data is stored as a native byte region with a logical start and length.
Consuming a frame advances the logical start rather than immediately moving the
remaining bytes. Storage compacts only when necessary to make room, and grows
geometrically when capacity must increase.

Built-in framing definitions are normally created through `Linux::Event::Stream::Framer` and may be shared safely across Streams. Each Stream copies the definition into independent native parser state during construction.

Built-in Delimiter, Fixed, LengthPrefix/U32BE, Netstring, and Varint framers inspect
this storage directly. Delimiter scanning remembers the earliest position that
can still begin a cross-read delimiter; fixed and length-framed modes wait for
the exact required byte count; Netstring validates its decimal length and
terminator; Varint decodes a canonical unsigned LEB128 prefix without exposing
storage to Perl.

Custom Perl framers use exactly the same native bytes through Framer::Buffer.
Only explicit `peek()` calls copy header bytes into Perl.

## Pluggable framing boundary

A custom framer returns only frame boundaries:

```text
(offset, length, consume)
```

It never owns Stream storage. Stream validates the boundaries, creates the
semantic message, consumes the requested prefix, and invokes `on_message`.

`need(N)` records a minimum total byte count in native state. The reactor can
continue reading without re-entering the Perl framer until N bytes are present.

Built-in framers may execute entirely in XS while preserving the same
application-level `on_message` contract.

## Native output queue

When there is no queued output, `write()` makes one immediate native `write()`
attempt. Partial/EAGAIN output enters independent native queue segments.
Writable readiness builds an iovec over queued segments and calls `writev()`.

The current queued representation copies only bytes that actually enter the
queue. This guarantees ordinary value semantics if the caller later mutates
its scalar. Retained-SV/COW output is a separate future benchmark experiment.

## Backpressure

`write($bytes)` returns false after queued bytes exceed the high watermark. The
data has still been accepted. Once a blocked Stream drains to or below the low
watermark, native state clears the blocked flag before `on_drain` runs.

## Duplex lifetime

- peer EOF -> `on_eof`; writing remains legal
- `end()` -> drain output, then `shutdown(SHUT_WR)`
- both directions ended -> close fd, `on_close`
- `close()` -> immediate close
- `detach()` -> transfer the still-open filehandle back to the application

Pause/close state is checked after semantic callbacks, so callbacks may safely
pause or close the Stream while native drains are active. Resuming a framed
Stream immediately processes complete frames already present in native input;
it does not require another kernel readiness event.

## Private decomposition paths

Development-only constructor switches preserve measurable historical paths:

```text
_read_backend       perl | xs
_write_backend      perl | xs
_framing_backend    perl | xs-perl | xs
```

They are not application API. Public construction chooses the fastest valid
path automatically: built-in Delimiter uses native framing; third-party
framers use native input storage plus the Perl plug-in contract.
