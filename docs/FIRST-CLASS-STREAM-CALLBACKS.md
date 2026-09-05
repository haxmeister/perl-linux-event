# First-class ordered-byte callbacks

Linux::Event ordered-byte objects support both subclass methods and
constructor-supplied coderefs. Constructor callbacks are ordinary Perl
closures, so they retain lexical application state without target objects,
method injection, caller-pad access, or package globals.

```perl
my $database = ...;
my $config = ...;

my $stream = MyStream->new(
    fh => $fh,
    on_data => sub ($stream, $bytes) {
        process($database, $config, $stream, $bytes);
    },
);
```

## Surface and precedence

The callback options are:

- `on_data` for raw ordered-byte delivery;
- `on_message` for ordinary framed delivery;
- `on_messages` when the class enables `message_batch_size`;
- `on_ready`, `on_transport_ready`, `on_drain`, `on_eof`, `on_error`, and
  `on_close` for lifecycle events.

`IO::Sock::Stream->new`, `IO::Sock::Stream->connect`, `IO::Pipe->new`, and
`IO::TTY->new` use the same ordered-byte callback surface. A constructor
callback overrides the corresponding class method for that instance. If no
constructor callback is supplied, existing subclass behavior is unchanged.

Raw, framed, batched, and native-consumer modes remain explicit. `on_data`
cannot be used on a framed class; `on_message` and `on_messages` cannot be used
on a raw class; `on_messages` requires `message_batch_size`; and Perl message
callbacks cannot replace a native consumer. Invalid combinations fail during
construction rather than during dispatch.

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

An `IO::Sock::Listener` accepts the same callback names as templates for its
accepted Streams:

```perl
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    stream_class => 'Linux::Event::IO::Sock::Stream',
    host => '127.0.0.1',
    port => 9999,
    on_data => sub ($stream, $bytes) {
        $stream->write($bytes);
    },
);
```

The Listener retains one CV and supplies that same CV to every accepted
Stream. Per-connection identity and mutable state normally belong in the
Stream's `data`. Creating a fresh closure per connection is unnecessary unless
the application truly needs distinct lexical state, and carries measurable
construction cost.

The Listener constructor's callback options configure accepted Streams. The
Listener's own `on_accept` and `on_error` policies remain subclass methods.

## Performance evidence

The cached-closure experiment measured raw and framed native dispatch with
4,194,304 callbacks per small-message row. Capturing one or four lexicals did
not produce a scaling penalty; closure rows remained approximately within
1-1.5% of the cached subclass method path in the decisive framed runs, with
raw delivery showing the same practical equivalence.

Accepted-Stream construction showed that post-construction setter/wrapper work
was the material cost, not retaining a shared closure. Direct native seeding
reduced the shared-closure CPU difference to about 1.35% in the official paired
result, with the distribution crossing zero. Fresh per-connection closure
allocation remained measurably more expensive.

Permanent regression harnesses are:

- `bench/run-first-class-framed-callback-bench.pl`;
- `bench/run-first-class-raw-callback-bench.pl`;
- `bench/run-first-class-callback-construction-bench.pl`.
