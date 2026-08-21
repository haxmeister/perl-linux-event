# Object lifecycle and Loop attachment

Linux::Event has one owner of readiness: `Linux::Event::Loop`. It does not
require a public Watcher base class. Public objects implement their own
lifecycle and expose a private `_attach_to_loop` hook that `Loop->add()` uses.
The hook is an implementation contract between this distribution's classes,
not an application subclass API.

## Two equivalent construction styles

Every attachable public class accepts `loop => $loop`:

```perl
my $stream = ClientStream->connect(
    loop => $loop, host => '127.0.0.1', port => 9999,
);

my $listener = ServerStream->listen(
    loop => $loop, host => '0.0.0.0', port => 9999,
);
```

An object may instead be constructed detached and passed to `add()`:

```perl
my $stream = $loop->add(ClientStream->connect(
    host => '127.0.0.1', port => 9999,
));

my $listener = $loop->add(ServerStream->listen(
    host => '0.0.0.0', port => 9999,
));
```

`add()` sets the object's Loop, starts its activity, and returns the same
object. Neither style is a compatibility adapter; they are equal parts of the
public API. The constructor form is concise when the Loop is already known.
The detached form is useful when configuration and activation happen in
different parts of an application.

## Ownership rules

- An attachable object belongs to at most one Loop.
- An object can be attached only once.
- A terminal object cannot be reattached.
- Stream owns its established socket from construction or successful connect
  until `close()`, `detach()`, or destruction.
- Listener owns sockets it creates. An adopted listener is closed only when
  `owns_socket => 1` was requested.
- `add()` returns the exact object it received; it does not wrap or replace it.

Violations are rejected synchronously. This makes the Loop registry and native
descriptor ownership unambiguous.

## Logical objects and native registrations

A public object is a logical activity, not a one-to-one wrapper around an epoll
entry. A connecting Stream can temporarily own a socket registration and a
timerfd registration. After connection it owns the established socket
registration. The application continues to hold one Stream object throughout.

Listener similarly owns its listening registration and creates Stream objects
for accepted sockets. These native registrations are implementation details.

## Raw descriptor registrations

Low-level applications can register a descriptor directly:

```perl
my $registration = $loop->watch(
    fh   => $fh,
    read => sub ($registration) { ... },
);
```

`watch()` attaches immediately and returns an opaque native registration
handle. It supports readiness-interest changes, accessors, and `cancel()`, but
it is not a public class hierarchy and must not be subclassed. Use Stream or
Listener when the resource needs a higher-level ownership policy.

## Destruction

Explicit `close()` is recommended because it makes application intent and
callback timing clear. Destructors are a safety net. Stream fires `on_close`
once when it closes an owned connection, but `detach()` deliberately does not:
the resource remains open and ownership transfers to the caller.

