package Linux::Event::IO::Sock::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.111';

use parent 'Linux::Event::_Socket::Stream';

1;

__END__

=head1 NAME

Linux::Event::IO::Sock::Stream - asynchronous Linux C<SOCK_STREAM> connections

=head1 SYNOPSIS

Method callbacks remain supported:

  package EchoConnection;
  use parent 'Linux::Event::IO::Sock::Stream';
  use Linux::Event::Framer 'Delimiter', "\n";

  sub on_ready ($stream) {
      $stream->send('hello');
  }

  sub on_message ($stream, $message) {
      say $message;
      $stream->close;
  }

  package main;
  my $connection = $loop->add(EchoConnection->connect(
      host => '127.0.0.1',
      port => 9999,
  ));

Callbacks may instead be supplied at construction:

  my $stream = Linux::Event::IO::Sock::Stream->connect(
      loop => $loop,
      host => '127.0.0.1',
      port => 9999,
      on_data => sub ($stream, $bytes) {
          process_bytes($bytes);
      },
  );

=head1 DESCRIPTION

C<Linux::Event::IO::Sock::Stream> is the public class for connected Linux
C<SOCK_STREAM> sockets. TCP over IPv4 or IPv6 and Unix-domain stream sockets
use the same class; address family is connection configuration rather than a
separate type hierarchy.

The class combines the common ordered-byte engine with socket acquisition,
addresses, socket policy, kernel half-close semantics, and optional TLS.
Applications may use the public class directly for raw byte I/O or subclass it
for reusable class policy such as framing, stream/socket options, TLS, or method
callback defaults. Constructor callbacks are first-class and provide ordinary
Perl lexical scope without requiring inheritance just for callback state.

=head1 OUTBOUND CONNECTIONS

C<connect> constructs one connection object whose identity is retained through
resolution, connection, optional TLS handshake, established I/O, and close:

  my $stream = Client->connect(
      loop    => $loop,          # optional immediate attachment
      host    => 'example.com',  # TCP remote host
      port    => 443,            # TCP remote port
      timeout => 10,             # connection deadline; default 10
      data    => $state,         # optional application state
  );

Use C<unix =E<gt> $path> for a filesystem Unix-domain stream socket. Advanced
callers may supply a packed C<sockaddr> with its numeric C<family>.

C<loop> is optional. Without it, C<connect> returns a detached object that may
later be passed to C<< $loop->add($stream) >>. Writes submitted before readiness
use the normal bounded output queue and are delivered in order after the
transport becomes usable.

Optional source-side controls include numeric C<local_host>, C<local_port>, and
C<bind_device>. Hostname resolution is asynchronous and uses the Loop's private
native resolver service.

=head1 ADOPTED CONNECTED SOCKETS

C<new(fh =E<gt> $socket)> adopts an already connected C<SOCK_STREAM> handle.
The handle is validated, made nonblocking and close-on-exec, and uses the same
established I/O path as an accepted or outbound connection. A TLS-declared
class must also specify C<tls_role> for an adopted handle because acquisition
cannot infer client versus server role.

=head1 CALLBACKS

Callbacks may be methods, constructor coderefs, or a mixture:

  my $database = ...;
  my $stream = RawConnection->new(
      fh      => $socket,
      on_data => sub ($stream, $bytes) {
          process_bytes($database, $stream, $bytes);
      },
  );

A constructor callback overrides the corresponding class method for that
object. C<connect> accepts the same callback options as C<new>.

The callback surface and signatures are:

=over 4

=item * C<on_data($stream, $bytes)>

Raw ordered-byte delivery.

=item * C<on_message($stream, $message)>

Ordinary framed delivery.

=item * C<on_messages($stream, $messages)>

Batched framed delivery when C<message_batch_size> is enabled. C<$messages> is
an array reference.

=item * C<on_ready($stream)>

Runs once when the connection is application-ready. For TLS that means after
handshake and verification, not merely after TCP connect.

=item * C<on_transport_ready($stream)>

Observes transport readiness before application readiness.

=item * C<on_drain($stream)>

Runs when queued output falls through the configured low watermark after
backpressure.

=item * C<on_eof($stream)>

Runs when the readable direction reaches EOF.

=item * C<on_error($stream, $error)>

Receives a L<Linux::Event::Error> for Stream failures.

=item * C<on_close($stream)>

Runs once when the complete Stream closes normally through the callback-aware
lifecycle. C<detach> does not invoke it.

=back

A readable raw object requires an effective C<on_data> callback. It may come
from a class method or constructor option. A framed class declared with
L<Linux::Event::Framer> instead requires C<on_message>, or C<on_messages> when
explicit message batching is enabled. Constructor callbacks may provide those
sinks even when the class has no same-named method.

Method defaults are resolved into an immutable class descriptor. Constructor
input callbacks are retained once in native Stream state, producing one
effective cached CV with no event-time lookup or method-versus-coderef branch.
Lifecycle callbacks are likewise resolved once during construction. Closing or
detaching the Stream releases its retained constructor callbacks.

=head1 CLASS POLICY VERSUS CALLBACKS

Constructor callbacks configure application behavior for one object. Framing,
C<stream_options>, C<socket_options>, C<configure_socket>, and TLS declarations
remain class-level policy and therefore belong on a concrete subclass when they
are needed.

For example, a line protocol may use a class only to declare framing while
supplying message handling as a closure:

  package LineConnection;
  use parent 'Linux::Event::IO::Sock::Stream';
  use Linux::Event::Framer 'Delimiter', "\n";

  package main;
  my $stream = LineConnection->new(
      fh => $socket,
      on_message => sub ($stream, $line) {
          handle_line($line);
      },
  );

=head1 FRAMING AND OUTPUT

C<write($bytes)> sends raw ordered bytes. C<send($payload)> applies the
subclass's native framer. The native write engine attempts immediate output,
queues only unsent bytes, enables writable readiness only while necessary, and
uses high/low watermarks plus optional C<max_pending_bytes> protection.

C<pause_read> and C<resume_read> control application reads. C<transition_to>
changes protocol callback/framing descriptors in place while retaining the live
socket, transport, output queue, and unread native input according to the
transition rules in F<docs/FRAMING.md>.

=head1 SOCKET POLICY

A subclass may define C<socket_options> for acquisition-time socket policy:

  sub socket_options ($class) {
      return (
          tcp_nodelay      => 1,
          keepalive        => 1,
          tcp_user_timeout => 15,
      );
  }

Supported policy includes TCP_NODELAY, keepalive tuning, TCP_USER_TIMEOUT,
send/receive buffers, and interface binding where applicable. Constructor
values override class policy for one connection. C<configure_socket> is an
optional cached cold-path hook for Linux options not covered by the built-ins.
See F<docs/SOCKET-CONFIGURATION.md>.

=head1 ORDERED-BYTE POLICY AND DEADLINES

C<stream_options> configures read size and fairness, batching, input/output
limits, watermarks, and established C<idle_timeout>, C<read_timeout>, and
C<write_timeout>. One explicit operation C<deadline> may also be set or changed
at runtime. These policies begin when the application transport is usable; DNS,
connect, TLS handshake, and TLS shutdown retain their own lifecycle deadlines.

=head1 TLS

A stream-socket subclass opts into TLS declaratively:

  package SecureClient;
  use parent 'Linux::Event::IO::Sock::Stream';
  use Linux::Event::TLS
      verify => 1,
      alpn   => ['http/1.1'];

Outbound C<connect> selects client mode and derives the default server name from
C<host>. A listener that accepts a TLS-declared class selects server mode; that
class must declare C<cert_file> and C<key_file>. Framing and callbacks receive
plaintext. See L<Linux::Event::TLS>.

=head1 ADDRESSES AND LIFECYCLE

C<local> and C<peer> return lazy L<Linux::Event::Address> values when available.
C<fd>, C<fh>, C<state>, C<pending_bytes>, and C<last_error> expose connection
state without changing ownership.

C<end> drains accepted output then performs the transport's writable half-close.
C<close> is immediate and terminal. C<detach> transfers a plain connected socket
only when no output is pending; encrypted transports cannot be detached safely.

=head1 SEE ALSO

L<Linux::Event::IO::Sock::Listener>, L<Linux::Event::IO::Sock::Dgram>,
L<Linux::Event::Framer>, L<Linux::Event::TLS>,
F<docs/SOCKET-CONNECTIONS.md>, F<docs/ORDERED-BYTE-IO-DESIGN.md>,
F<docs/FIRST-CLASS-STREAM-CALLBACKS.md>.

=cut
