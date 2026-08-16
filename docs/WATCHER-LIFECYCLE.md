# Watcher lifecycle

## Public model

The Loop owns Watchers. A Watcher is one logical event-producing activity,
not necessarily one file descriptor. A Stream normally owns one socket
registration. A connecting Stream may temporarily own connection and deadline
registrations. A future Process Watcher may own pipe and pidfd registrations.

Native epoll registrations remain implementation details and do not require a
separate Perl object for every descriptor owned by a composite Watcher.

## Attachment

Concrete Watcher constructors create detached objects. The canonical operation
is:

```perl
my $watcher = $loop->add(MyWatcher->new(...));
```

`add()` accepts only `Linux::Event::Watcher` objects and returns the same
object. Attachment is single-use. Adding an attached Watcher, adding it to a
second Loop, or adding a terminal Watcher is an error. Constructors and
`add()` do not invoke application callbacks.

The old `loop => $loop` constructor option is retained temporarily as
compatibility syntax and performs the same attachment before returning.

## Raw readiness

`watch()` remains the concise low-level operation for an existing descriptor.
It constructs and immediately attaches a `Linux::Event::IO` Watcher. Its
native dispatch path is unchanged.

## Terminal ownership

An active Watcher is strongly owned by the Loop's native or composite state.
Closing or cancelling it releases registrations and makes it terminal. A
terminal Watcher cannot be restarted or transferred to another Loop.

Application code closes the Watcher itself. There is no public generic
`Loop->remove()` because detachment without type-specific resource semantics is
ambiguous for buffered Streams and composite Watchers.

## Performance rule

Watcher is a construction-time type and lifecycle contract. It must not add a
generic Perl dispatch call between XS readiness and the concrete cached
callback. Concrete Watchers retain their specialized native hot paths.
