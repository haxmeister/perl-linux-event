package Linux::Event::IO::Sock::Listener;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.112';

use parent 'Linux::Event::_Socket::Listener';
use Carp qw(croak);

sub new ($class, %option) {
    if (exists $option{stream_class}) {
        my $stream_class = $option{stream_class};
        croak 'new(): stream_class must name a Linux::Event::IO::Sock::Stream subclass'
            if ref($stream_class)
            || !$stream_class->isa('Linux::Event::IO::Sock::Stream');
    }
    return $class->SUPER::new(%option);
}

1;

__END__

=head1 NAME

Linux::Event::IO::Sock::Listener - asynchronous listening C<SOCK_STREAM> socket

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::Loop;
  use Linux::Event::IO::Sock::Listener;
  use Linux::Event::IO::Sock::Stream;

  my $loop = Linux::Event::Loop->new;
  my $listener = Linux::Event::IO::Sock::Listener->new(
      loop         => $loop,
      stream_class => 'Linux::Event::IO::Sock::Stream',
      host         => '127.0.0.1',
      port         => 9999,
      on_data      => sub ($stream, $bytes) {
          $stream->write($bytes);
      },
  );

  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::IO::Sock::Listener> owns a listening Linux C<SOCK_STREAM>
socket and constructs the configured L<Linux::Event::IO::Sock::Stream>
subclass for every accepted connection. It is a separate public object because
bind/listen/accept lifecycle is different from connected byte-stream I/O.

TCP and Unix-domain listeners share this class. Socket family is selected by
constructor options, not by subclass hierarchy.

=head1 ACCEPTED STREAM SUBCLASS POLICY AND TUNING

C<stream_class> is a prominent part of the Listener design. The selected
L<Linux::Event::IO::Sock::Stream> subclass gives every accepted connection the
same native framer, TLS server identity and verification policy, socket policy,
and C<stream_options> tuning for fairness, batching, limits, watermarks, and
deadlines. Linux::Event validates and caches that policy once per stream class.

Listener constructor callbacks are complementary: C<on_data>, C<on_message>,
and the other accepted-Stream callback templates can capture lexical server
state, override same-named stream methods, and are shared rather than rebuilt
for every accept. This keeps reusable protocol and tuning policy in the Stream
subclass while preserving ordinary closure scope for a particular listener.

The Listener's own C<on_accept> and listener-error policy remain named subclass
methods because C<on_error> in the constructor belongs to accepted Streams.

=head1 CONSTRUCTION

C<stream_class> is required and names the stream-socket subclass created for
each accepted connection. Exactly one listener source is selected:

  Listener->new(
      stream_class => 'ServerConnection',
      host         => '0.0.0.0',
      port         => 9999,
  );

  Listener->new(
      stream_class => 'ServerConnection',
      unix         => '/run/example.sock',
  );

  Listener->new(
      stream_class => 'ServerConnection',
      fh           => $existing_listener,
  );

C<loop =E<gt> $loop> attaches immediately; otherwise add the detached object
with C<< $loop->add($listener) >>. Listener C<data> is supplied to each accepted
connection as its initial C<data> value.

The Listener may also receive accepted-Stream callback templates directly:

  my $database = ...;
  my $listener = Listener->new(
      stream_class => 'Linux::Event::IO::Sock::Stream',
      host         => '0.0.0.0',
      port         => 9999,
      on_data      => sub ($stream, $bytes) {
          persist($database, $stream, $bytes);
      },
  );

Supported templates and signatures are C<on_data($stream, $bytes)>,
C<on_message($stream, $message)>, C<on_messages($stream, $messages)>,
C<on_ready($stream)>, C<on_transport_ready($stream)>, C<on_drain($stream)>,
C<on_eof($stream)>, C<on_error($stream, $error)>, and C<on_close($stream)>.
These constructor options belong to each accepted Stream;
C<on_error($listener, $error)> for the Listener itself remains a Listener
subclass method. One template CV is retained by the Listener and passed to
every accepted Stream. Linux::Event does not create a new closure per accept.

TCP listener policy includes C<backlog>, C<reuseaddr>, C<reuseport>, optional
C<v6only>, and C<bind_device>. Unix listeners support path ownership controls
including C<unlink>, C<unlink_on_close>, and C<permissions>. Adopted handles
default to caller ownership unless C<owns_socket> is true.

=head1 ACCEPTANCE

Native code drains C<accept4> with nonblocking and close-on-exec flags.
C<max_accept_per_tick> bounds level-triggered acceptance for fairness; zero
drains until C<EAGAIN> and is required with edge-triggered operation.

For each accepted socket Linux::Event constructs C<stream_class>, attaches it to
the same Loop, then invokes optional C<on_accept($listener, $stream)>.
A plain stream's C<on_ready> follows. For TLS, C<on_accept> still observes the
new connection immediately after attachment while C<on_ready> waits for the TLS
handshake and verification to complete.

An C<on_accept> exception closes only that accepted connection and is reported
as a callback error; it does not silently kill the listener.

=head1 TLS

TLS policy belongs to the accepted stream-socket class, not the listener. A
server class declares L<Linux::Event::TLS> with C<cert_file> and C<key_file>.
Listener validates that server policy during construction and creates fresh TLS
state for every accepted connection.

=head1 METHODS AND LIFECYCLE

C<port> reports the bound TCP port, including the kernel-selected value after
C<port =E<gt> 0>. C<family>, C<family_number>, C<is_tcp>, and C<is_unix>
identify the listening socket family.

C<pause> and C<resume> control acceptance while retaining the listening socket.
C<close> ends ownership. C<detach> returns the still-open listening handle and
is terminal. C<state> reports listener lifecycle such as C<unattached>,
C<listening>, C<paused>, C<closed>, C<failed>, or C<detached>.

Runtime errors are L<Linux::Event::Error> values. Resource exhaustion pauses
acceptance before error delivery to prevent a readable-backlog error spin. A
subclass may define C<on_error($listener, $error)> to implement application
policy.

=head1 SEE ALSO

L<Linux::Event::IO::Sock::Stream>, L<Linux::Event::TLS>,
F<docs/LISTENER-DESIGN.md>, F<docs/SOCKET-CONFIGURATION.md>,
F<docs/FIRST-CLASS-STREAM-CALLBACKS.md>.

=cut
