# Choosing a Stream framer

TCP delivers an ordered stream of bytes. It does **not** preserve your
application's message boundaries. A framer is the rule that turns those bytes
back into complete messages.

Normal application code only needs to remember one factory:

```perl
use Linux::Event::Stream::Framer;
```

The easiest way to choose a framer is to ask **how the protocol says a message
ends**.

| What the wire format says | Factory method | Example |
|---|---|---|
| "Each message ends with newline" | `->line` | `HELLO\n` |
| "Read until these bytes appear" | `->delimiter($bytes)` | CRLF, NUL, `\x02END\x03` |
| "Every record is exactly N bytes" | `->fixed(size => N)` | 32-byte device records |
| "A fixed-width integer says how many payload bytes follow" | `->length_prefix(...)` | `[00 05][HELLO]` |
| "The first four bytes are an unsigned big-endian payload length" | `->u32be` | `[00 00 00 05][HELLO]` |
| "A compact base-128 integer says how many payload bytes follow" | `->varint` | `[05][HELLO]` |
| "ASCII decimal length, separator, then payload" | `->decimal_length` | `5 HELLO` |
| "Decimal length, colon, payload, comma" | `->netstring` | `5:HELLO,` |
| None of these | custom framer | proprietary or stateful framing rule |

## Newline-delimited messages

For the common newline case:

```perl
my $framer = Linux::Event::Stream::Framer->line;
```

Incoming `\n` is stripped from the delivered message and `send()` appends it on
output.

## Delimiter

`delimiter()` searches for a specific byte sequence. Everything before the
marker is one message unless `include_delimiter` is requested.

```perl
my $framer = Linux::Event::Stream::Framer->delimiter("\r\n");
```

Use it when the protocol talks about **terminators**, **separators**, **line
endings**, or **sentinel bytes**. The marker may be binary and may cross socket
read boundaries.

## Fixed

`fixed()` waits until exactly the configured number of bytes are available and
emits that many bytes as one message.

```perl
my $framer = Linux::Event::Stream::Framer->fixed(size => 32);
```

Use it for fixed-width records, device telemetry packets, or file-like binary
records whose size never changes.

## Length prefix

`length_prefix()` reads an unsigned integer from the beginning of the frame,
then waits for that many payload bytes.

```text
00 05  H E L L O
^^^^^  ^^^^^^^^^
length payload
```

```perl
my $framer = Linux::Event::Stream::Framer->length_prefix(
    bytes     => 2,
    endian    => 'big',
    max_frame => 1_048_576,
);
```

Use it when protocol documentation says **length field**, **payload length**,
**message size**, or **record size** near the start of each message.

## U32BE

`u32be()` is the common special case of a four-byte unsigned big-endian length
prefix.

```perl
my $framer = Linux::Event::Stream::Framer->u32be;
```

Use it when the protocol explicitly describes a **32-bit network-order** or
**unsigned big-endian 32-bit** payload length.

## Varint

`varint()` is length-prefix framing where small lengths use fewer prefix bytes.
It uses canonical unsigned LEB128, also called an unsigned base-128 varint.

```perl
my $framer = Linux::Event::Stream::Framer->varint(
    max_frame => 1_048_576,
);
```

Use it only when the protocol explicitly says **unsigned LEB128**, **base-128
varint**, or documents the same low-seven-bits plus continuation-bit encoding.
It is not interchangeable with every format that happens to be called a
“varint.”

## Netstring

A netstring writes the payload length in decimal text, then `:`, the payload,
and `,`.

```text
5:HELLO,
```

```perl
my $framer = Linux::Event::Stream::Framer->netstring;
```

This is still length-based framing; the length is simply represented as ASCII
instead of a binary integer.

## Decimal length

`decimal_length()` writes the payload size as ASCII digits followed by one
separator byte. Its default form is used by RFC 6587 octet-counted syslog:

```text
5 HELLO
```

```perl
my $framer = Linux::Event::Stream::Framer->decimal_length(
    max_frame => 1_048_576,
);
```

Use `separator => '|'` for a protocol whose wire form is `5|HELLO`.

## Reuse one built-in framer across connections

Built-in framer objects describe the wire format; they do not store a
connection's partial bytes or scan position. A server can therefore construct
one and reuse it safely:

```perl
my $lines = Linux::Event::Stream::Framer->line;

for my $socket (@sockets) {
    Linux::Event::Stream->new(
        loop       => $loop,
        fh         => $socket,
        framer     => $lines,
        on_message => sub ($stream, $message) { ... },
    );
}
```

Each Stream still owns independent native parser state. Reuse saves duplicate
framer/configuration objects and does not add a per-message method call.

Custom framers may keep arbitrary Perl state and should only be shared when the
custom implementation itself is designed to be share-safe.

## What if I do not know the name?

Do not start by looking for a framer class name. Read the protocol's packet
format and identify the boundary rule:

1. Newline? -> `line`.
2. Another terminating marker? -> `delimiter`.
3. Every packet the same size? -> `fixed`.
4. A fixed-width binary length? -> `length_prefix` or `u32be`.
5. An unsigned LEB128/base-128 length? -> `varint`.
6. ASCII digits plus a separator? -> `decimal_length`.
7. Written specifically as `length:data,`? -> `netstring`.
8. Otherwise, use a custom framer until an appropriate native built-in exists.

## Native versus custom

Factory methods return the exact built-in classes recognized by Stream, so
incoming boundary detection runs in XS directly against Stream's native input
buffer. The factory call occurs only when the framing definition is created;
it is not part of the message hot path.

Outbound `send()` calls the built-in's Perl `frame()` method, then queues the
result through the native write engine. “Native framer” currently refers to the
incoming parser.

Custom Perl framers use the same native storage through
`Linux::Event::Stream::Framer::Buffer`, so unusual protocols remain possible
without exposing internal pointers or buffer representation.

See `docs/FRAMING.md` for the custom-framer API contract.
