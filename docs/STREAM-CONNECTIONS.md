# Stream connection design

Outbound connection acquisition is part of `Linux::Event::Stream`. There is no
public Connect or Connector object. The application creates the object it wants
to use after establishment, and that same object owns every later state.

## Public API

```perl
my $stream = ClientStream->connect(
    loop    => $loop,
    host    => 'example.com',
    port    => 443,
    timeout => 10,
    data    => $application_state,
    transport => Linux::Event::TLS->client(
        server_name => 'example.com',
    ),
);
```

Detached construction is equivalent:

```perl
my $stream = ClientStream->connect(
    host => '127.0.0.1', port => 9999,
);
$loop->add($stream);
```

The Stream accepts `write()` and `send()` before it is ready. Pending output is
bounded by the Stream class's normal `max_pending_bytes` policy and is flushed
in order after establishment.

## Address modes

Exactly one address mode is required:

- `host => $host, port => $port` resolves IPv4/IPv6 candidates;
- `unix => $path` connects to a filesystem Unix stream socket;
- `sockaddr => $packed, family => $af` uses a caller-packed address.

`timeout` is a non-negative number of seconds and defaults to 10. A zero value
disables the connection deadline. Hostname resolution currently uses
synchronous `getaddrinfo`; socket establishment itself is nonblocking.

## State sequence

```text
unattached -> connecting -> active -> closed
     |             |                    ^
     +-------------+------ failure -----+
```

Supplying `loop =>` performs the first transition before the constructor
returns. Detached construction remains `unattached` until `Loop->add()`.
Closing during connection cancels all attempts and the deadline without firing
a later readiness or error callback.

## Readiness

`on_ready($stream)` runs once when the Stream is usable by the application. For
a plain connection that means the socket connected successfully. For TLS it
means TCP establishment, TLS handshake, and certificate/hostname verification
all completed. Accepted plain Streams are ready after Listener attaches them.

Connection failure is delivered to `on_error($stream, $error)`, followed by
the ordinary close lifecycle. The error is a `Linux::Event::Error`; its
`type`, `operation`, `errno`, address fields, and `attempts` distinguish resolve,
socket, connect, and deadline failures.

## Internal implementation

`Linux::Event::Stream::_Connection` is a private acquisition engine. It owns
candidate attempts and a Linux timerfd while the public Stream is connecting.
On success it hands the connected handle directly back to that Stream, which
installs its established native read/write state. No second public object or
callback adapter is created.

The private engine is deliberately in Perl because connection setup is a cold
lifecycle path. XS provides the timerfd and established Stream hot paths. This
keeps policy readable without adding Perl dispatch to steady-state I/O.

## Future resolver work

Candidate storage is separate from attempt state so asynchronous DNS and a
staggered Happy Eyeballs policy can be introduced without changing the public
Stream API or its ownership model.
