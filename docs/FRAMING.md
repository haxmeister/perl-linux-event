# Pluggable framing contract

If you are not sure which built-in applies to a protocol, start with
[`CHOOSING-A-FRAMER.md`](CHOOSING-A-FRAMER.md).

Framing answers one question: **where does one message end and the next begin?**
It is separate from serialization such as JSON, MessagePack, or application
object construction.

## Stable Buffer view

Custom framers receive `Linux::Event::Stream::Framer::Buffer`, never the
Stream's storage scalar or native pointer.

```perl
$buffer->length;
$buffer->index($needle, $start);
$buffer->byte($offset);
$buffer->peek($offset, $length);
$buffer->need($minimum_total_bytes);
```

The normal implementation now backs this object with native input storage. A
private reference path still backs it with a Perl scalar. Framer code is
identical in both cases.

`peek()` copies only the requested range into Perl. `length`, `index`, `byte`,
and `need` operate against native storage without exposing ownership.

## `next_frame` contract

A custom framer implements:

```perl
sub next_frame ($self, $buffer) { ... }
```

It has three outcomes:

1. Return no values: not enough data yet.
2. Return `(offset, length, consume)`: one complete frame exists.
3. `die`: invalid input; Stream converts it to a framing error.

`offset` and `length` select the bytes delivered to `on_message`. `consume`
specifies how many bytes Stream removes from the front afterward.

## `need(N)`

A framer can say that it cannot make progress until N total bytes are present:

```perl
return $buffer->need(4) if $buffer->length < 4;
```

The threshold is stored in native Stream state. Linux::Event can continue
reading without calling the Perl framer again until that threshold is reached.

## Native built-in framers

The normal user-facing factory is `Linux::Event::Stream::Framer`. Its methods
return the exact built-in classes recognized by Stream, so message boundary
detection still executes directly in XS. They all use the same native input storage
and deliver only complete semantic messages to Perl. A subclass is deliberately
not treated as a built-in fast path: its `next_frame()` remains authoritative.

### Arbitrary delimiter

```perl
my $framer = Linux::Event::Stream::Framer->delimiter(
    "\x02END-OF-MESSAGE\x03",
);
```

Delimiters may cross reads, multiple frames may arrive in one read, and
incomplete trailing bytes remain in native storage. `include_delimiter` and
`max_frame` are supported.

### Fixed-size records

```perl
my $framer = Linux::Event::Stream::Framer->fixed(size => 32);
```

Every 32 bytes is one message. `send()` requires an exactly 32-byte payload.

### Configurable length prefix

```perl
my $framer = Linux::Event::Stream::Framer->length_prefix(
    bytes     => 2,
    endian    => 'big',
    max_frame => 1_048_576,
);
```

Unsigned 1-, 2-, and 4-byte prefixes are supported in big- or little-endian
order. The prefix describes payload bytes. `include_prefix` optionally includes
the prefix in the delivered message.

### U32BE

```perl
my $framer = Linux::Event::Stream::Framer->u32be(
    max_frame => 16 * 1024 * 1024,
);
```

This is the common four-byte unsigned big-endian length prefix as a dedicated
convenience class.

### Netstring

```perl
my $framer = Linux::Event::Stream::Framer->netstring(
    max_frame => 1_048_576,
);
```

Canonical `length:payload,` netstrings are parsed natively. Invalid decimal
lengths, noncanonical leading zeroes, excessive declared lengths, and missing
comma terminators are framing errors.

### Varint length prefix

```perl
my $framer = Linux::Event::Stream::Framer->varint(
    max_frame => 1_048_576,
);
```

The payload length is a canonical unsigned LEB128 integer occupying one to ten
bytes. The prefix describes payload bytes. `include_prefix` optionally includes
the actual variable-width prefix in the delivered message. Overflowing,
overlong, and non-canonical prefixes are framing errors.

For benchmark decomposition the same built-in objects can still be forced
through generic Perl `next_frame()` execution. These backend switches are
private test machinery, not application API.

## Reusing built-in framing definitions

Built-in framers are configuration objects and are safe to reuse across
Streams. The changing parser state remains per Stream in native storage. During
Stream construction the built-in configuration is copied into that Stream's XS
state, so reuse adds no Perl method dispatch to the frame-processing hot path.

```perl
my $lines = Linux::Event::Stream::Framer->line;

my $a = Linux::Event::Stream->new(
    loop => $loop, fh => $socket_a, framer => $lines,
    on_message => sub ($stream, $message) { ... },
);

my $b = Linux::Event::Stream->new(
    loop => $loop, fh => $socket_b, framer => $lines,
    on_message => sub ($stream, $message) { ... },
);
```

Custom framers may contain arbitrary mutable Perl state and therefore are only
share-safe when their own implementation guarantees it.

## Custom length-prefix example

```perl
package My::U32Frame;

sub new ($class) { bless {}, $class }

sub next_frame ($self, $buffer) {
    return $buffer->need(4) if $buffer->length < 4;

    my $length = unpack('N', $buffer->peek(0, 4));
    die "frame too large" if $length > 16 * 1024 * 1024;

    my $total = 4 + $length;
    return $buffer->need($total) if $buffer->length < $total;

    return (4, $length, $total);
}
```

No XS knowledge is required to define a proprietary framing format.

## Outbound framing

A framer may implement:

```perl
sub frame ($self, $payload) { ... }
```

Then applications may use:

```perl
$stream->send($payload);
```

Serialization remains separate. Built-in `frame()` methods produce their wire
representation in Perl and then use the same native Stream write engine.
Outbound framing can move lower later if profiling demonstrates that prefix or
separator construction is material.

## Native versus custom framing

The built-in family now covers arbitrary delimiter, fixed-size, configurable
binary length prefix, U32BE, netstring, and Varint framing. Third-party Perl
framers remain fully supported through `Framer::Buffer`; adding native
built-ins does not change that plug-in contract.
