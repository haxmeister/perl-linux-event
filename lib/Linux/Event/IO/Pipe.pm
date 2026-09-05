package Linux::Event::IO::Pipe;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.112';

use parent 'Linux::Event::_ByteStream';
use Carp qw(croak);

# Linux fcntl.h: F_LINUX_SPECIFIC_BASE + 8. Linux::Event is Linux-only and
# F_GETPIPE_SZ succeeds only for pipe/FIFO descriptors, so this avoids the
# heavier stat-backed -p file test while preserving the concrete leaf contract.
use constant _F_GETPIPE_SZ => 1032;

sub _is_pipe ($fh) {
    return defined fcntl($fh, _F_GETPIPE_SZ, 0);
}

sub new ($class, %option) {
    if (defined(my $fh = $option{fh})) {
        croak 'new(): fh is not a pipe or FIFO' if !_is_pipe($fh);
    } else {
        croak 'new(): read_fh is not a pipe or FIFO'
            if defined($option{read_fh}) && !_is_pipe($option{read_fh});
        croak 'new(): write_fh is not a pipe or FIFO'
            if defined($option{write_fh}) && !_is_pipe($option{write_fh});
    }
    return $class->SUPER::new(%option);
}

1;

__END__

=head1 NAME

Linux::Event::IO::Pipe - asynchronous ordered-byte I/O for pipes and FIFOs

=head1 SYNOPSIS

Raw Pipe callbacks do not require a subclass:

  pipe(my $read, my $write) or die "pipe: $!";

  my $pipe = $loop->add(Linux::Event::IO::Pipe->new(
      read_fh => $read,
      on_data => sub ($pipe, $bytes) {
          say "received: $bytes";
      },
  ));

A subclass remains useful for reusable framing or other class policy:

  package LinePipe;
  use parent 'Linux::Event::IO::Pipe';
  use Linux::Event::Framer 'Delimiter', "\n";

  package main;
  my $lines = LinePipe->new(
      read_fh => $read,
      on_message => sub ($pipe, $line) {
          say "line: $line";
      },
  );

=head1 DESCRIPTION

C<Linux::Event::IO::Pipe> is the public ordered-byte I/O class for anonymous
pipes and FIFOs. It uses the same native buffering, framing, output queue,
backpressure, deadlines, and directional lifecycle as the other ordered-byte
Linux::Event leaves without giving a pipe socket semantics.

A Pipe may be read-only, write-only, or duplex. Duplex operation may use two
different descriptors, which is useful for child stdin/stdout pairs and other
one-way pipe combinations.

=head1 CONSTRUCTION

C<new> accepts exactly one of these handle shapes:

  MyPipe->new(fh => $duplex_handle);
  MyPipe->new(read_fh => $input, write_fh => $output);
  MyPipe->new(read_fh => $input);
  MyPipe->new(write_fh => $output);

C<fh> means that one descriptor supplies both directions and cannot be combined
with C<read_fh> or C<write_fh>. Every supplied handle must be a Linux pipe or
FIFO. Linux::Event validates that identity before generic ordered-byte setup,
then makes owned descriptors nonblocking and close-on-exec.

C<loop =E<gt> $loop> attaches immediately. Otherwise construct detached and
pass the object to C<< $loop->add($pipe) >>. C<data> stores arbitrary
application state.

Ordered-byte deadline overrides C<idle_timeout>, C<read_timeout>, and
C<write_timeout>, plus an explicit C<deadline>, are also accepted. See
F<docs/ORDERED-BYTE-DEADLINES.md>.

=head1 CALLBACKS

A readable raw Pipe requires an effective C<on_data($pipe, $bytes)> callback.
It may be supplied as a class method or as C<on_data =E<gt> sub { ... }> to
C<new>.

With L<Linux::Event::Framer>, a framed Pipe instead requires an effective
C<on_message($pipe, $message)> callback, or
C<on_messages($pipe, $messages)> when C<message_batch_size> is enabled.
C<$messages> is an array reference. Constructor callbacks may provide either
sink even when the class has no same-named method.

Lifecycle constructor callbacks use the same first-class model. Supported
names include C<on_ready>, C<on_transport_ready>, C<on_drain>, C<on_eof>,
C<on_error>, and C<on_close>. C<on_error> receives
C<($pipe, $error)>; the others receive the Pipe object.

A constructor callback overrides the corresponding class method for that Pipe
and retains ordinary Perl lexical scope. Input callbacks are cached in the same
native ordered-byte state as method callbacks rather than looked up for each
read or message. Lifecycle callbacks are also resolved once during
construction.

=head1 OUTPUT AND LIFECYCLE

C<write($bytes)> queues raw bytes. C<send($payload)> applies the subclass's
framer when one is declared. High/low watermarks provide cooperative
backpressure and C<max_pending_bytes> can impose a hard queue bound.

C<pause_read> and C<resume_read> control input delivery. C<end> drains accepted
output and ends the writable direction. C<close_read> and C<close_write> stop
one direction immediately; C<close> terminates the whole object.

C<detach> requires an empty output queue and transfers the still-open handles
back to the caller as a hash containing C<read_fh> and C<write_fh>. It is a
terminal ownership transfer and does not invoke C<on_close>.

=head1 CLASS POLICY

Subclasses may define C<stream_options> for the shared ordered-byte engine.
Important options include C<read_size>, C<read_budget_bytes>,
C<read_batch_bytes>, C<message_batch_size>, C<high_watermark>,
C<low_watermark>, C<max_pending_bytes>, C<max_buffer>, and established timeout
values. These are cached once per concrete subclass rather than parsed for each
instance.

Framing is valid for pipes because framing describes ordered application bytes,
not sockets. Framing and C<stream_options> remain class-level policy; constructor
callbacks select application behavior for an individual Pipe. See
L<Linux::Event::Framer> and F<docs/FRAMING.md>.

=head1 SEE ALSO

L<Linux::Event::IO::TTY>, L<Linux::Event::IO::Sock::Stream>,
L<Linux::Event::Loop>, F<docs/ORDERED-BYTE-IO-DESIGN.md>,
F<docs/FIRST-CLASS-STREAM-CALLBACKS.md>.

=cut
