package Linux::Event::Kernel::Timer;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.110';

use parent 'Linux::Event::Timer';

1;

__END__

=head1 NAME

Linux::Event::Kernel::Timer - monotonic one-shot and recurring Loop timers

=head1 SYNOPSIS

  package Heartbeat;
  use parent 'Linux::Event::Kernel::Timer';

  sub on_timer ($timer) {
      $timer->data->send('ping');
  }

  package main;
  my $timer = $loop->add(Heartbeat->new(
      every => 15,
      data  => $connection,
  ));

=head1 DESCRIPTION

C<Linux::Event::Kernel::Timer> is the public timer leaf. Applications create a
subclass with one named C<on_timer> callback. All active timers on a Loop share
the Loop's timerfd-backed native scheduler and indexed minimum heap; one Timer
object does not mean one kernel timer descriptor.

=head1 SCHEDULES

Construction accepts one schedule:

=over 4

=item C<after =E<gt> $seconds>

Relative one-shot deadline.

=item C<at =E<gt> $monotonic_seconds>

Absolute one-shot deadline using the same monotonic clock returned by
C<< Linux::Event::Kernel::Timer->now >>.

=item C<every =E<gt> $seconds>

Fixed-rate recurrence. C<after> or C<at> may be combined with C<every> to set a
different first deadline.

=back

C<after> and C<at> are mutually exclusive. Public durations are seconds and may
be fractional. Zero-delay work is delivered on a later Loop turn rather than
reentrantly from construction.

=head1 CALLBACK AND RECURRENCE

  sub on_timer ($timer) { ... }

Recurring timers advance from the previous scheduled deadline rather than from
callback completion. If the Loop is late, missed intervals are coalesced into
one callback; C<expirations> reports how many ticks that callback represents.

The callback is cached per subclass. C<data> holds arbitrary application state
and C<loop> returns the owning Loop while attached.

=head1 RESCHEDULING AND CANCELLATION

C<reschedule> accepts the same schedule grammar as construction and returns the
same object. It may be called while active or from C<on_timer>.

C<cancel> is idempotent and terminal. A completed one-shot timer is also
terminal. Active timers are retained by the Loop even if the application drops
its own reference; cancellation, final expiration, or Loop destruction releases
that ownership safely.

=head1 ATTACHMENT

C<loop =E<gt> $loop> attaches during construction. Otherwise construct
detached and use C<< $loop->add($timer) >>. Timer callbacks are ordinary Loop
callbacks and may close I/O objects, schedule other timers, or stop the Loop.

=head1 SEE ALSO

L<Linux::Event::Loop>, F<docs/TIMER-DESIGN.md>,
F<docs/ORDERED-BYTE-DEADLINES.md>.

=cut
