# First-class ordered-byte callbacks

Linux::Event ordered-byte objects support both subclass methods and
constructor-supplied coderefs. Constructor callbacks are ordinary Perl
closures, so they retain lexical application state without target objects,
method injection, caller-pad access, or package globals.

```perl
my $database = ...;
my $config   = ...;

my $stream = Linux::Event::IO::Sock::Stream->new(
    fh => $fh,
    on_data => sub ($stream, $bytes) {
        process($database, $config, $stream, $bytes);
    },
);
```

Subclass methods remain fully supported. The change is that inheritance is no
longer required merely to obtain performant callback scope.

## Callback surface and signatures

The ordered-byte constructor callback options are:

| Callback | Signature | Meaning |
|---|---|---|
| `on_data` | `($stream, $bytes)` | raw ordered-byte delivery |
| `on_message` | `($stream, $message)` | ordinary framed delivery |
| `on_messages` | `($stream, $messages)` | framed batch delivery; `$messages` is an array reference |
| `on_ready` | `($stream)` | application-ready lifecycle |
| `on_transport_ready` | `($stream)` | transport-ready lifecycle |
| `on_drain` | `($stream)` | output drained through the low watermark after backpressure |
| `on_eof` | `($stream)` | readable direction reached EOF |
| `on_error` | `($stream, $error)` | ordered-byte failure |
| `on_close` | `($stream)` | complete object close lifecycle |

`IO::Sock::Stream->new`, `IO::Sock::Stream->connect`, `IO::Pipe->new`, and
`IO::TTY->new` use the same ordered-byte callback surface. A constructor
callback overrides the corresponding class method for that instance. If no
constructor callback is supplied, existing subclass behavior is unchanged.

A readable raw object needs an effective `on_data` callback. A framed object
needs `on_message`, or `on_messages` when `message_batch_size` is enabled.
Those sinks may come entirely from constructor callbacks; a class does not need
a dummy method merely to satisfy callback validation.

Raw, framed, batched, and native-consumer modes remain explicit. `on_data`
cannot be used on a framed class; `on_message` and `on_messages` cannot be used
on a raw class; `on_messages` requires `message_batch_size`; and Perl message
callbacks cannot replace a native consumer. Invalid combinations fail during
construction rather than during dispatch.

## Callback configuration versus class policy

Constructor callbacks configure application behavior for one object. They do
not turn class policy into per-instance configuration.

The following remain class-level declarations or methods:

- `use Linux::Event::Framer ...`;
- `stream_options()`;
- stream-socket `socket_options()` and `configure_socket()`;
- `use Linux::Event::TLS ...`;
- native-consumer declarations.

Therefore a raw Pipe, TTY, or stream socket can use its public leaf directly
when no reusable class policy is needed. A framed protocol still needs a
concrete subclass on which to declare its framer, but its application callback
may be supplied at construction:

```perl
package LineProtocol;
use parent 'Linux::Event::IO::Sock::Stream';
use Linux::Event::Framer 'Delimiter', "\n";

package main;
my $database = ...;

my $stream = LineProtocol->new(
    fh => $fh,
    on_message => sub ($stream, $line) {
        persist_line($database, $line);
    },
);
```

This distinction keeps immutable protocol and tuning policy shared while giving
application code normal Perl lexical scope.

## Precedence

A callback supplied at construction overrides the same-named class method for
that object:

```text
constructor callback
        |
        | overrides
        v
class method callback
```

Both forms resolve to one effective callback. There is no fallback from a
constructor callback to the class method after construction, and there is no
method-versus-closure decision during delivery.

## Dispatch model

Class methods are resolved once into the class descriptor. Constructor input
callbacks are validated once and retained directly in native per-object state.
The result is one effective CV for each active input boundary:

```text
class method CV or constructor closure CV
                  |
                  v
       native per-object callback slot
                  |
                  v
          direct Perl invocation
```

There is no per-message method lookup, object-hash callback lookup, closure
creation, or method-versus-coderef branch. Native reads, buffering, framing,
and batching remain native until application code must run. Lifecycle
callbacks are also resolved once, but remain in Perl because lifecycle and
exception orchestration are cold-path policy.

Instance input callbacks and lifecycle overrides survive compatible
`transition_to()` operations. Class-derived callbacks follow the target class
descriptor. `close()` and failed construction release retained callbacks;
`detach()` releases them without invoking `on_close`.

## Listener reuse

An `IO::Sock::Listener` requires a `stream_class` because accepted connections
still need a concrete stream-socket class and its class-level policy. That class
may be the base `Linux::Event::IO::Sock::Stream` for raw delivery, or an
application subclass declaring framing, TLS, or other policy.

The Listener accepts the ordered-byte callback names as templates for its
accepted Streams:

```perl
my $database = ...;

my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    stream_class => 'Linux::Event::IO::Sock::Stream',
    host => '127.0.0.1',
    port => 9999,
    on_data => sub ($stream, $bytes) {
        store_bytes($database, $stream, $bytes);
        $stream->write($bytes);
    },
);
```

The Listener retains the template CV and supplies the same callback to every
accepted Stream. Linux::Event does not manufacture a wrapper closure for each
accepted connection.

Per-connection identity and mutable protocol state normally belong in the
Stream's `data`. Shared closures are well suited to immutable configuration,
service objects, registries, or other application scope common to all accepted
connections. An application may deliberately create a fresh closure for one
connection when it truly needs distinct lexical state, but Linux::Event does
not impose that allocation.

The Listener constructor's ordered-byte callback options configure accepted
Streams. The Listener's own `on_accept($listener, $stream)` and
`on_error($listener, $error)` policies remain Listener subclass methods.

## Performance evidence

The cached-closure experiment measured raw and framed native dispatch with
4,194,304 callbacks per small-message row. Capturing one or four lexicals did
not produce a scaling penalty; closure rows remained approximately within
1-1.5% of the cached subclass method path in the decisive framed runs, with
raw delivery showing the same practical equivalence.

Accepted-Stream construction showed that post-construction setter/wrapper work
was the material cost, not retaining a shared closure. Direct native seeding
reduced the shared-closure CPU difference to about 1.35% in the recorded paired
result, with the distribution crossing zero. Fresh per-connection closure
allocation remained measurably more expensive.

The production design therefore preserves the measured invariant: resolve or
accept the callback once, retain one effective CV, and invoke it directly at
the semantic delivery boundary.

Permanent regression harnesses are:

- `bench/run-first-class-framed-callback-bench.pl`;
- `bench/run-first-class-raw-callback-bench.pl`;
- `bench/run-first-class-callback-construction-bench.pl`.
