# Connector design

The common client API is `MyStream->connect(...)`. It returns one detached
Stream, and `$loop->add($stream)` starts acquisition. The same Stream identity
survives TCP connection, optional TLS negotiation, established I/O, and close.
Output written before readiness stays in the Stream's bounded output queue.

`Linux::Event::Connector` is the advanced standalone socket-acquisition
Watcher. `Linux::Event::Connect` remains its compatibility implementation for
applications that intentionally transfer a connected handle to something other
than Stream.

The Connector engine acquires client-side connected stream sockets. It does
not read application bytes, perform TLS, construct Stream, or own application
protocol policy.

```text
Resolver -> Connector -> connected filehandle -> chosen consumer

MyStream->connect -> internal Connector -> same MyStream becomes ready
                                      |-> Stream
                                      |-> Stream + TLS
                                      |-> raw Loop watcher
                                      `-> specialized protocol engine
```

## Public model

The base class is not constructible. A concrete type provides two named
methods:

```perl
package ApplicationConnect;
use parent 'Linux::Event::Connect';

sub on_connect ($request, $fh) {
    ApplicationStream->new(
        loop => $request->loop,
        fh   => $fh,
        data => $request->data,
    );
}

sub on_error ($request, $error) {
    warn "$error\n";
}
```

The callbacks are resolved and cached once per subclass. One request starts at
construction and accepts exactly one target form:

```perl
ApplicationConnect->new(
    loop => $loop, host => $host, port => $port, timeout => 10,
);

ApplicationConnect->new(
    loop => $loop, unix => $path,
);

ApplicationConnect->new(
    loop => $loop, sockaddr => $packed, family => $family,
);
```

Timeouts are seconds. Ten seconds is the default and zero disables the
connection deadline.

## Completion semantics

Constructor validation and inability to create required internal reactor
resources throw synchronously. Network outcomes do not. Immediate socket
success, exhausted candidates, and resolver failure are queued through a
timerfd so `on_connect` or `on_error` cannot run before `new` returns.

The state sequence is one of:

```text
pending -> connected
pending -> failed
pending -> cancelled
```

State becomes terminal and internal resources become inert before an
application callback runs. Cancellation is silent because it is initiated by
the request owner rather than the network.

## Socket ownership

On success, `on_connect` receives exclusive ownership of a nonblocking,
close-on-exec filehandle. Connect neither requires nor loads Stream.

For a connection completed by writable readiness, Connect temporarily retains
its watcher while `on_connect` runs. Registering the same fd replaces that
watcher through one `EPOLL_CTL_MOD`. The old handle is inactive, so Connect can
cancel it after the callback without removing the consumer registration. If no
consumer registers the fd, Connect removes its own readiness registration and
leaves the filehandle with the callback.

## Errors

`Linux::Event::Connect::Error` preserves semantic and system details:

- `type`: `resolve`, `socket`, `connect`, or `timeout`
- `operation`
- numeric `errno` when applicable
- human-readable `message`
- request `host`, `port`, `path`, or `family`
- number of attempted sockets
- original resolver diagnostic when applicable

Errors stringify for logging without discarding structured accessors.

## Native boundary

Connection attempts are cold relative to Stream message I/O. Candidate policy,
state, errors, and callbacks therefore remain in Perl. The native Connect
extension supplies Linux timerfd creation, arming, draining, and closing for
monotonic deadlines and deferred completion.

Sockets use `SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC` in the original
`socket()` call. This removes follow-up `fcntl` calls and the close-on-exec race.

## Current limitations and next work

This release resolves non-literal hostnames with synchronous `getaddrinfo`.
That call occurs before the connection deadline is armed and can block the
reactor thread. Resolved candidates are then attempted sequentially.

The next layer is an asynchronous `Linux::Event::Resolver` backed by a native
worker and eventfd notification. Connect will consume its candidate collection
and implement staggered IPv6/IPv4 attempts. The first successful attempt wins;
losing watchers and sockets are cancelled. This Happy Eyeballs work changes
internal scheduling, not the constructor, callbacks, error object, or socket
ownership contract described here.

UDP is intentionally outside this module. A connected UDP socket has datagram
semantics and belongs to a later `Linux::Event::Datagram` layer.
