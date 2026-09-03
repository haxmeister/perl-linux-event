# Linux::Event IO and Kernel Architecture

## Status

This document records the namespace and responsibility model agreed before the
next public release. The migration must preserve tested behavior and measured
performance before old public names are removed.

## Public namespace model

Linux::Event separates application data I/O from kernel event/state
abstractions.

```text
Linux::Event
|-- IO
|   |-- Pipe
|   |-- TTY
|   `-- Sock
|       |-- Stream
|       |-- Listener
|       |-- Dgram
|       `-- SeqPacket       future
|
|-- Kernel
|   |-- Timer
|   |-- Signal
|   |-- Event
|   `-- Process
|
|-- Loop
|-- Error
|-- Address
|-- Framer
`-- TLS
```

The namespace is semantic rather than an inheritance declaration. Public leaf
classes name completed facilities that applications use. Internal behavior may
be shared through private classes or helpers without exposing that
implementation taxonomy.

## IO branch

C<Linux::Event::IO> is a namespace category, not the generic replacement for
the old C<Linux::Event::Stream> class.

### IO::Pipe

Represents pipe-like ordered-byte I/O. It may have a readable handle, a
writable handle, or both. Two handles need not be the same descriptor.
Anonymous pipes, FIFOs, and child-process pipe pairs are the primary use cases.

### IO::TTY

Represents terminal and pseudo-terminal ordered-byte I/O. It may have a
readable handle, a writable handle, or both. Terminal configuration remains a
terminal concern rather than a reason to duplicate the common byte-stream
engine.

### IO::Sock::Stream

Represents C<SOCK_STREAM> socket I/O. IPv4, IPv6, and Unix-domain addressing
are socket-family configuration rather than different stream classes.
Connected stream sockets use the common ordered-byte engine plus socket
semantics.

### IO::Sock::Listener

Represents a listening C<SOCK_STREAM> socket. It is a separate Linux::Event
public object because its useful interface is bind/listen/accept rather than
connected byte-stream processing. Namespace placement states that it is a
socket role; it does not imply inheritance from IO::Sock::Stream.

### IO::Sock::Dgram

Represents C<SOCK_DGRAM> sockets. Datagram boundaries are kernel-provided, so
stream framing is not part of this class.

### IO::Sock::SeqPacket

Reserved for future C<SOCK_SEQPACKET> support. Like datagrams, kernel message
boundaries make byte-stream framing inappropriate.

## Kernel branch

The Kernel branch exposes Linux::Event abstractions over Linux kernel
notification/state facilities. The public names describe the abstraction,
while the backing fd mechanism remains an implementation fact.

- C<Kernel::Timer> uses timerfd-backed scheduling machinery.
- C<Kernel::Signal> uses signalfd-backed signal delivery.
- C<Kernel::Event> uses eventfd-backed counter/notification semantics.
- C<Kernel::Process> uses pidfd lifecycle observation and also owns Linux::Event
  process spawning and asynchronous stdio behavior.

C<Process> remains the correct leaf name because the existing object is richer
than a pidfd wrapper.

## Private behavior layers

The first private roots are:

```text
Linux::Event::_IO
|-- Linux::Event::_ByteStream
`-- Linux::Event::_Socket
```

This is an implementation taxonomy only.

### _IO

Shared descriptor/reactor/lifecycle mechanics for application I/O facilities.
It must not become a public catch-all object.

### _ByteStream

Shared ordered-byte behavior used where message boundaries are not supplied by
the kernel. This is the intended home for behavior currently concentrated in
C<Linux::Event::Stream>:

- readable and writable directions;
- one shared handle or split directional handles;
- nonblocking read/write machinery;
- input buffering;
- output queues and drain notification;
- high/low watermarks and output limits;
- pause/resume;
- framing;
- message batching;
- established deadlines;
- EOF and directional lifecycle.

The public C<IO::Pipe>, C<IO::TTY>, and C<IO::Sock::Stream> leaves may all use
this behavior without claiming that one public facility is a subtype of
another.

### _Socket

Shared behavior that exists because a descriptor is a socket:

- socket type validation;
- socket family and address handling;
- socket creation/configuration;
- socket options;
- common ownership/lifecycle support.

Connection acquisition, listen/accept, stream-byte processing, and datagram
processing stay in their specialized layers.

## Migration rule

The migration is behavior-first:

1. Add private architecture boundaries without changing the public API.
2. Move existing implementation responsibilities behind those boundaries in
   small testable steps.
3. Establish the new IO and Kernel leaf classes while retaining equivalent
   behavior and performance tests.
4. Migrate examples, POD, design documents, benchmarks, and tests.
5. Remove the old misleading public names only after the complete replacement
   surface is tested.
6. Run the full test matrix, distribution checks, and performance regression
   suite before release.

The refactor must not preserve an old name merely for compatibility if that
name contradicts the corrected architecture. The release is intentionally
allowed to make incompatible API changes once the replacement is complete.
