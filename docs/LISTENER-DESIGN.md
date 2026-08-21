# Listener design

`Linux::Event::Listener` owns an inbound TCP or Unix listening socket and
constructs one configured `Linux::Event::Stream` subclass for every accepted
connection. Listener is constructed directly; Stream does not own or proxy the
listening API. There is no separate generic Listen class.

## Public API

```perl
my $listener = Linux::Event::Listener->new(
    loop                => $loop,          # optional: attach immediately
    stream_class        => 'ServerStream', # required
    host                => '0.0.0.0',      # required for TCP
    port                => 9999,           # required for TCP
    backlog             => 4096,           # default
    max_accept_per_tick => 256,            # default
    edge_triggered      => 0,              # default
);
```

Or construct detached and attach explicitly:

```perl
my $listener = $loop->add(Linux::Event::Listener->new(
    stream_class => 'ServerStream',  # required
    unix         => '/run/app.sock', # required for Unix
    unlink       => 1,               # optional; default 0
    permissions  => 0660,            # optional
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

The complete source-specific shapes are:

```perl
my $tcp = Linux::Event::Listener->new(
    stream_class => 'ServerStream', # required
    host         => '::',           # required for TCP
    port         => 9999,           # required for TCP
    reuseaddr    => 1,              # default
    reuseport    => 0,              # default
    v6only       => 1,              # optional; kernel default if omitted
);

my $unix = Linux::Event::Listener->new(
    stream_class    => 'ServerStream',  # required
    unix            => '/run/app.sock', # required for Unix
    unlink          => 0,               # default
    unlink_on_close => 1,               # default
    permissions     => 0660,            # optional
);

my $adopted = Linux::Event::Listener->new(
    stream_class => 'ServerStream', # required
    fh           => $socket,        # required for adoption
    owns_socket  => 0,              # default
);
```

## Accept behavior

Native code drains `accept4()` with atomic `SOCK_NONBLOCK | SOCK_CLOEXEC`.
`max_accept_per_tick` defaults to 256 for level-triggered fairness. Setting it
to zero drains until `EAGAIN`; this unbounded mode is required when
`edge_triggered => 1` is selected.

The accepted descriptor is immediately used to construct the configured
Stream and attach it to the same Loop. There is no temporary accepted-socket
registration to remove or replace.

An optional Listener callback observes every fully constructed Stream:

```perl
package ServerListener;
use parent 'Linux::Event::Listener';

sub on_accept ($listener, $stream) {
    $listener->data->{connections}{ $stream->fd } = $stream;
}
```

The order is construction, Loop attachment, `on_accept`, then plain Stream
`on_ready`. For TLS, `on_accept` still runs immediately after attachment and
Stream `on_ready` waits for a successful handshake. The callback can inspect,
retain, configure, or close the Stream.

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
An exception from `on_accept` closes only that accepted Stream, suppresses its
pending `on_ready`, and delivers a nonfatal `callback` Error to `on_error`.
The Listener remains active when `on_error` handles the failure.

`family()` returns `inet`, `inet6`, `unix`, or `unknown` consistently with
`Linux::Event::Address`. `family_number()` returns the native numeric family;
`is_tcp()` and `is_unix()` provide direct predicates.
