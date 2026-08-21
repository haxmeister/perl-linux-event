# Listener design

`Linux::Event::Listener` owns an inbound TCP or Unix listening socket and
constructs one configured `Linux::Event::Stream` subclass for every accepted
connection. Listener is constructed directly; Stream does not own or proxy the
listening API. There is no separate generic Listen class.

## Public API

```perl
my $listener = Linux::Event::Listener->new(
    loop => $loop,
    stream_class => 'ServerStream',
    host => '0.0.0.0', port => 9999,
);
```

Or construct detached and attach explicitly:

```perl
my $listener = $loop->add(Linux::Event::Listener->new(
    stream_class => 'ServerStream',
    host => '0.0.0.0', port => 9999,
));
```

`stream_class` is required and names the Stream subclass constructed for each
accepted connection.

## Socket sources

Exactly one source is required:

- `host => $host, port => $port` creates a TCP listener;
- `unix => $path` creates a filesystem Unix stream listener;
- `fh => $listening_socket` adopts an existing listening handle.

Created sockets are nonblocking and close-on-exec and are owned by Listener.
An adopted handle defaults to caller ownership; pass `owns_socket => 1` to
transfer it. `host => '*'` binds a passive wildcard address. When `port => 0`
is used, `port()` reports the assigned port after construction.

TCP options include `backlog`, `reuseaddr`, `reuseport`, and `v6only`. Unix
options include `backlog`, `unlink`, `unlink_on_close`, and `permissions`.
Source-specific options are rejected when used with another source, preventing
configuration that appears to work but has no effect.

## Accept behavior

Native code drains `accept4()` with atomic `SOCK_NONBLOCK | SOCK_CLOEXEC`.
`max_accept_per_tick` defaults to 256 for level-triggered fairness. Setting it
to zero drains until `EAGAIN`; this unbounded mode is required when
`edge_triggered => 1` is selected.

The accepted descriptor is immediately used to construct the configured
Stream and attach it to the same Loop. There is no temporary accepted-socket
registration to remove or replace.

Peer addresses are represented by `Linux::Event::Address` and decoded lazily.
Applications that never inspect `peer()` do not pay for textual address
formatting.

## Per-connection options

A Stream class can provide construction state for accepted connections:

```perl
sub accepted_stream_options ($class, $listener, $peer) {
    return (
        data => { server => $listener->data, peer => $peer },
        transport => Linux::Event::TLS->server(
            cert_file => 'server-cert.pem',
            key_file  => 'server-key.pem',
        ),
    );
}
```

The method must return an even option list and cannot replace `fh` or `peer`.
A fresh stateful transport provider must be returned for each connection.

## Errors and lifecycle

`pause()` and `resume()` control acceptance without closing the socket.
`close()` ends Listener ownership. `detach()` cancels readiness and returns the
still-open listener handle. `state()` reports `unattached`, `listening`,
`paused`, `closed`, `failed`, or `detached`.

Runtime failures use `Linux::Event::Error`. Resource exhaustion errors such as
`EMFILE` pause acceptance before notification to avoid a readable-backlog error
spin. The base Listener dies after a runtime failure. A Listener subclass may
override that policy:

```perl
package AppListener;
use parent 'Linux::Event::Listener';

sub on_error ($listener, $error) {
    warn "$error\n";
}
```

Without that hook, Listener treats a runtime listener failure as fatal.
