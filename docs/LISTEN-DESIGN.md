# Listener design

The common server API is `MyStream->listen(...)`. It returns one detached
`Linux::Event::Listener`; `$loop->add($listener)` starts accepting. Each
accepted descriptor is converted directly into the configured Stream subclass
and attached to the same Loop. Application code does not receive or configure
the socket.

`Linux::Event::Listen` remains the compatibility generic-handoff Watcher for
advanced consumers that intentionally need the accepted filehandle.

The Listener engine is the inbound stream-socket acquisition layer. It
creates or adopts a listening socket, owns accept readiness, and transfers each
connected filehandle to application code. It does not read application bytes,
choose a protocol, or require `Linux::Event::Stream`.

## Public shape

Concrete listeners are subclasses with two named methods:

```perl
package ServiceListener;
use parent 'Linux::Event::Listen';

sub on_accept ($listener, $fh, $peer) {
    ServiceStream->new(loop => $listener->loop, fh => $fh);
}

sub on_error ($listener, $error) {
    warn "listener failed: $error\n";
}
```

The first construction resolves those methods into one class descriptor.
Per-listener state then contains only socket, watcher, address, lifecycle,
counters, policy, and application data.

Exactly one source is required:

- `host` plus `port` creates, binds, and listens on TCP
- `unix` creates, binds, and listens on a filesystem Unix socket
- `fh` adopts an existing listening stream socket

Internally created sockets are owned. Adopted sockets are borrowed unless
`owns_socket => 1` is explicit. `detach` always stops watching and transfers
the listening handle without closing it.

## Accept boundary

XSLoop remains the only readiness reactor. Its read callback enters the small
Listen XS extension, which drains `accept4()` and requests
`SOCK_NONBLOCK | SOCK_CLOEXEC` atomically. XS returns descriptor/address pairs;
Perl constructs a filehandle and enters `on_accept` once per semantic
connection.

The default watcher is level-triggered and accepts at most 256 connections per
dispatch. This bounds one busy listener's reactor occupancy; remaining backlog
causes another readiness report. Edge-triggered operation is allowed only with
`max_accept_per_tick => 0`, because an edge plus a bounded drain could strand
connections already in the queue.

Peer text conversion is lazy. `Linux::Event::Listen::Peer` retains the packed
sockaddr and formats host, port, path, and IPv6 fields only when requested.

## Stream handoff

The accepted handle has no required consumer. `on_accept` may:

- construct a Stream for buffered I/O and framing
- construct a Stream with the TLS server transport
- register a raw XSLoop watcher
- pass the handle to another protocol engine
- close or reject the connection immediately

When Stream is selected, it registers the accepted descriptor once; Listen
never creates a per-connection watcher that Stream must replace. The only
listener watcher remains on the separate listening descriptor.

## Failures and recovery

Setup failures throw a typed `Linux::Event::Listen::Error` synchronously.
Runtime failures call `on_error`.

`EMFILE`, `ENFILE`, `ENOBUFS`, and `ENOMEM` pause accept readiness before the
callback. This prevents a permanently readable listener from spinning while
the process or system lacks resources. Application code can release reserved
resources and call `resume`. Terminal listener errors enter `failed` state and
close an owned socket before notification.

## Deliberate limits

Address resolution for a hostname is synchronous during construction. UDP is
not represented: datagram reception has different ownership, message, peer,
and backpressure semantics and will receive a separate design. Listen is only
for connected stream sockets.

## Benchmark contract

`bench/run-listen-microbench.pl` measures loopback TCP connection lifecycle
through `Linux::Event::Connect`. Its `manual` row uses explicit listener setup,
a raw watcher, and native descriptor close. `handoff` adds the Perl filehandle
and lazy Peer representation without Listen callback machinery. `raw` accepts
through Listen, and `stream` additionally constructs and closes a minimal
Stream. The consecutive gaps expose representation, Listen control/callback,
and Stream lifecycle cost separately. All rows use abortive client teardown to
prevent earlier rows from filling the host's client-side `TIME_WAIT` table and
corrupting later measurements.
