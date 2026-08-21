# Stream connection design

Outbound connection acquisition is part of `Linux::Event::Stream`. There is no
public Connect or Connector object. The application creates the object it wants
to use after establishment, and that same object owns every later state.

## Public API

```perl
package ClientStream;
use parent 'Linux::Event::Stream';
use Linux::Event::TLS
    verify => 1,              # default
    alpn   => ['http/1.1'];   # optional

package main;
my $state = { requests => {} };
my $stream = ClientStream->connect(
    loop    => $loop,              # optional: attach immediately
    host    => 'example.com',      # required
    port    => 443,                # required
    timeout => 10,                 # default
    data    => $state,             # optional
);
```

The TLS declaration is part of the Stream type. `connect()` selects the client
role automatically and defaults SNI and hostname verification to its `host`.
Specify `server_name` in the declaration only when it must differ from the
connection host.

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
disables the connection deadline. The deadline covers hostname resolution and
every socket attempt. Numeric IPv4/IPv6 literals, Unix addresses, and packed
sockaddrs bypass the resolver.

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
lifecycle path. XS provides the timerfd, resolver workers, eventfd wakeup, and
established Stream hot paths. This keeps policy readable without adding Perl
dispatch to steady-state I/O.

## Resolver and Happy Eyeballs

Each Loop lazily acquires one private resolver service with two native pthread
workers. Workers call `getaddrinfo`, copy complete address results into native
memory, and write the service eventfd. They never enter the Perl interpreter or
touch Perl values. The Loop watches that eventfd through its ordinary raw
`watch()` mechanism, drains completions on the Loop thread, and resumes the
private connection engine there. This is intentionally not a public eventfd,
poster, or general cross-thread callback API.

IPv6 and IPv4 candidates are interleaved. The first connection attempt starts
immediately; while it remains pending, the next family starts after 250 ms.
Further candidates use the same stagger. A failure may advance immediately,
the first successful socket wins, and every losing watcher and socket is
cancelled deterministically.

Cancellation removes the resolver request's Loop-thread recipient. A native
`getaddrinfo` already running may finish, but its late completion is discarded
safely. Applications do not need a threaded Perl build: the distribution uses
native C threads and keeps Perl confined to the Loop thread. Fork before a Loop
starts hostname resolution; a resolver service is not reusable in a forked
child.
