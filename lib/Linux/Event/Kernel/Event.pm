package Linux::Event::Kernel::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.110';

use parent 'Linux::Event::Wakeup';
use Carp qw(croak);

sub new ($class, %option) {
    croak 'new(): must be called as a class method' if ref $class;
    croak "$class must define on_event()" if !$class->can('on_event');
    return $class->SUPER::new(%option);
}

sub on_wakeup ($self, $count) {
    return $self->on_event($count);
}

1;

__END__

=head1 NAME

Linux::Event::Kernel::Event - eventfd-backed Loop notification

=head1 SYNOPSIS

  package ResultsReady;
  use parent 'Linux::Event::Kernel::Event';

  sub on_event ($event, $count) {
      my $queue = $event->data;
      process($queue->dequeue_nb) while $queue->pending;
  }

  package main;
  my $event = $loop->add(ResultsReady->new(data => $queue));

  # From a worker thread, native extension, or forked child:
  $event->signal;

=head1 DESCRIPTION

C<Linux::Event::Kernel::Event> is the public eventfd notification leaf. It lets
another execution context make the owning Loop runnable without pretending that
an eventfd transports arbitrary Perl values or callbacks.

The eventfd carries a 64-bit counter. Application payloads belong in an
appropriate queue, shared native structure, pipe, socket, or other IPC channel.
Publish the payload first, then call C<signal>.

=head1 CONSTRUCTION AND CALLBACK

A subclass must define:

  sub on_event ($event, $count) { ... }

C<data> typically contains the application-owned queue or state associated with
the notification. C<loop =E<gt> $loop> attaches immediately; otherwise add the
detached object with C<< $loop->add($event) >>.

C<$count> is the counter value drained from eventfd. Multiple producer writes
may coalesce into one callback, so the payload channel rather than C<$count> is
the source of truth for individual work items.

=head1 SIGNALING

C<signal> writes one to the counter. C<signal($increment)> adds an explicit
positive increment and returns the Event object. Signaling never invokes
C<on_event> inline; delivery occurs on the owning Loop thread.

The eventfd is nonblocking and close-on-exec. Counter saturation is reported as
a kernel write failure rather than discarding existing readiness.

=head1 THREAD AND FORK BOUNDARY

Linux::Event does not require a threaded Perl. Event is useful for native worker
threads, external libraries, and forked processes as well as Perl ithreads.

On an ithread-enabled Perl, a cloned Event handle may signal only. It cannot
manage the Loop, callback, or owner data. The clone uses its own descriptor
duplicate so destruction or descriptor reuse in one interpreter cannot corrupt
another.

A forked child may signal the inherited eventfd until exec. Cross-process
payloads still require real IPC or shared storage.

=head1 LIFECYCLE

C<cancel> is idempotent and terminal. It removes the Loop registration and
releases owner-side state. Callback exceptions propagate through ordinary Loop
dispatch and do not silently cancel the Event.

The inherited C<on_wakeup> bridge is private implementation glue for the stable
native eventfd extension; applications define and use only C<on_event>.

=head1 SEE ALSO

L<Linux::Event::Loop>, F<docs/EVENT-DESIGN.md>.

=cut
