# Native framing declarations

Framing belongs to ordered byte I/O. It is not specifically a socket feature.
The same framing declaration can be used by subclasses of:

- `Linux::Event::IO::Pipe`
- `Linux::Event::IO::TTY`
- `Linux::Event::IO::Sock::Stream`

A framer is immutable class policy. Declaring a framer therefore still requires
a concrete ordered-byte subclass, but the application callback that receives
complete messages may be either a class method or a constructor closure.

## Public model

A framed type combines one concrete ordered-byte leaf, one declarative framer,
and one effective message callback (or a native consumer):

```perl
package MessageConnection;
use parent 'Linux::Event::IO::Sock::Stream';
use Linux::Event::Framer 'LengthPrefix',
    bytes     => 4,
    endian    => 'big',
    max_frame => 16 * 1024 * 1024;

sub on_message ($self, $message) {
    $self->data->{messages}++;
    $self->send($message);
}
```

The declaration must appear after `use parent`. The import records immutable
class metadata; it does not construct a per-connection framer object.

The first construction of a concrete subclass resolves its declaration,
method callback defaults, tuning policy, and native parser configuration into
one cached private descriptor. Each object keeps only its changing parser,
buffer, queue, lifecycle state, and any constructor-supplied callback
overrides.

An instance may replace the class callback without changing framing policy:

```perl
my $stream = MessageConnection->new(
    fh => $fh,
    on_message => sub ($stream, $message) {
        handle_message($application_state, $stream, $message);
    },
);
```

The supplied closure becomes that object's effective native message CV. It is
not looked up or selected again for each frame.

A framed class does not need an `on_message` method if construction supplies the
required callback. This makes class policy and application callback scope
independent without making framing per-instance.

## Framing pipes and terminals

Nothing about a delimiter or length prefix requires a socket. For example, an
interactive terminal can be line framed:

```perl
package Console;
use parent 'Linux::Event::IO::TTY';
use Linux::Event::Framer 'Delimiter', "\n";

package main;
my $console = Console->new(
    read_fh  => \*STDIN,
    write_fh => \*STDOUT,
    on_message => sub ($self, $line) {
        $self->write("You typed: $line\n");
    },
);
```

A child-process or application pipe can use the same delimiter or a binary
length prefix. The underlying public leaf identifies the Linux resource;
framing describes how an ordered byte sequence is divided into messages.

## Name resolution

The declaration name is validated as one Perl package component and expanded
as:

```text
Linux::Event::Framer::<Name>
```

`Delimiter` therefore loads `Linux::Event::Framer::Delimiter`. There is no
central alias table. Misspelled or incorrectly cased names fail during class
compilation.

## Built-in wire contracts

| Name | Native input | Outbound `send($payload)` |
|---|---|---|
| `Delimiter` | payload through configured delimiter | appends delimiter |
| `Fixed` | exactly `size` bytes | requires exactly `size` bytes |
| `LengthPrefix` | unsigned 1/2/4-byte payload length | prepends configured binary length |
| `U32BE` | unsigned 4-byte network-order payload length | prepends network-order length |
| `Netstring` | canonical `length:payload,` | emits canonical netstring |
| `Varint` | canonical unsigned LEB128 payload length | prepends canonical LEB128 length |
| `DecimalLength` | ASCII length plus one separator byte | prepends decimal length and separator |

All lengths and limits are byte counts. Inbound boundary detection and parser
state machines run in XS. Outbound encoding is the named built-in framing
function used by `send()`, after which bytes enter the ordinary native write
queue.

## Limits

Framers that accept `max_frame` reject larger inbound and outbound payloads.
Length-prefix families may accept `include_prefix`; `Delimiter` accepts
`include_delimiter`. Those options affect the message passed to the callback,
not the bytes consumed from the underlying resource.

The class-level ordered-byte option `max_buffer` is an independent hard bound
on framed input storage. Its default is 8 MiB:

```perl
sub stream_options ($class) {
    return max_buffer => 32 * 1024 * 1024;
}
```

Use explicit limits for untrusted protocols rather than relying on process
memory availability.

## Raw mode

A readable ordered-byte object without a framer requires an effective
`on_data($stream, $bytes)` callback. That callback may be a class method or a
constructor coderef. For example, raw application-specific parsing can use the
public Stream leaf directly:

```perl
my $buffer = '';

my $stream = Linux::Event::IO::Sock::Stream->new(
    fh => $fh,
    on_data => sub ($stream, $bytes) {
        $buffer .= $bytes;

        while ($buffer =~ s/\A([^\n]*\n)//) {
            process_record($1);
        }
    },
);
```

Read callback chunks are not protocol boundaries. A raw parser must retain
partial application state itself. A lexical buffer such as the example above
is suitable for one object; a Listener callback shared by many accepted Streams
should normally keep per-connection parser state in each Stream's `data`.

Arbitrary `next_frame` parser objects and the former native-backed Buffer view
are not public APIs. Native built-ins avoid per-connection parser objects,
repeated dynamic dispatch, and XS-to-Perl calls whose only result would be a
frame-boundary tuple.

## Inheritance

A derived ordered-byte type inherits the nearest ancestor framer declaration
through normal Perl MRO and may replace its method callback defaults:

```perl
package AuditedConnection;
use parent 'MessageConnection';

sub on_message ($self, $message) {
    push @{ $self->data->{audit_log} }, length($message);
    $self->send($message);
}
```

Each concrete subclass gets its own cached descriptor while immutable parser
configuration is still shared rather than copied per object. A constructor
`on_message` callback overrides the inherited method for one object. A class
cannot declare two framers or combine framed delivery with `on_data`.

## Explicit message batching

Ordinary framed delivery calls the effective `on_message` CV once per complete
message. A pipelined protocol can explicitly select bounded array delivery:

```perl
sub stream_options ($class) {
    return message_batch_size => 32;
}

sub on_messages ($self, $messages) {
    process_message($self, $_) for @$messages;
}
```

The `on_messages` sink may instead be supplied as a constructor callback.
`on_message` and `on_messages` are mutually exclusive. A positive
`message_batch_size` requires an `on_messages` method or constructor callback,
and defining or supplying `on_messages` without the option is rejected.

XS flushes a partial message batch when the current read drain reaches EAGAIN,
before EOF or framing error, and when the aggregate input guard requires a
flush. It never waits for a future readiness event merely to fill the configured
count.

Pause, close, and protocol transition take effect at the selected callback
boundary. A negotiation protocol that must change type immediately after one
specific message should use ordinary `on_message` delivery.

## Raw callback batching

Raw mode can set `read_batch_bytes` in `stream_options()` to combine successful
native reads before calling the effective `on_data` CV. A partial raw batch also
flushes when the current drain ends; it does not wait for a future readiness
event.

Raw read batching and framed message batching are different policies and are
validated accordingly.

## Changing framing on a live resource

A protocol may transition between loaded ordered-byte subclasses with
`transition_to()`:

```perl
$self->transition_to('BinaryProtocol', input => $remaining);
```

Unread native bytes are preserved and interpreted using the target descriptor.
The explicit `input` value represents an unconsumed suffix from a raw callback.
Native buffered bytes, when present, precede that suffix.

The old parser stops after the callback that changes the descriptor. Complete
target frames already present in buffered input can then be delivered without
waiting for another kernel readiness event. Read pause survives the transition
and postpones delivery until `resume_read()`.

The target `max_buffer` and output limits are checked before the descriptor swap
is committed. Existing queued output is not reframed; later `send()` calls use
the target framing rule.

A transition changes application protocol policy, not the Linux resource. A
connected stream socket remains a connected stream socket; a pipe remains a
pipe.

Constructor input callbacks and lifecycle overrides survive compatible
transitions. Class-derived callbacks follow the target descriptor. The origin
of the effective callback is still resolved outside steady-state delivery.

## Framing and serialization

Framing and serialization are intentionally separate layers:

```text
bytes
  -> buffering
  -> framing
  -> complete message bytes
  -> codec / serialization
  -> Perl value
```

`send()` performs framing, not arbitrary object serialization. A codec layer can
be built above the completed message boundary without changing the native I/O
engine.

## Adding a native built-in

A complete framing family requires:

1. a `Linux::Event::Framer::<Name>` module validating declaration arguments and
   providing immutable native configuration plus outbound encoding;
2. corresponding XS parser support for partial input, multiple messages,
   limits, errors, and callback reentrancy;
3. contract tests for encoding, split input, malformed input, limits,
   per-object state independence, and `send()`;
4. benchmark coverage in the native framer harness.

The module builder interface is distribution-internal. Copying a Perl module
without implementing its matching native parser is not a new framing family.
Applications with unusual protocols should use raw `on_data`; generally useful
families can be added to Linux::Event with native implementation and tests.

## Error behavior

Malformed or oversized input produces a `Linux::Event::Error` with type
`framing`. The object stores it as `last_error`, invokes its cached effective
`on_error` callback when present, and closes through the normal ordered-byte
lifecycle. Application callback exceptions propagate rather than being silently
converted.

## Performance model

Immutable parser configuration and method callback CVs are resolved once per
concrete class. An optional constructor callback replaces the corresponding CV
once in native per-object state. XS appends bytes directly to native storage,
finds all complete built-in frames available, and crosses into Perl only for
semantic messages or lifecycle errors. Optional message batching can amortize
that semantic crossing across several messages.

There is no per-message method lookup, callback-origin branch, or closure
creation. See `FIRST-CLASS-STREAM-CALLBACKS.md` for the callback architecture
and benchmark evidence.

Measure framing changes with the framing microbenchmarks, native-framer
benchmarks, callback-batching throughput/fairness tests, and the lifecycle
performance baseline under `bench/`.
