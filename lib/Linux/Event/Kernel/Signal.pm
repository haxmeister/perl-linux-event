package Linux::Event::Kernel::Signal;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Signal';

1;

__END__

=head1 NAME

Linux::Event::Kernel::Signal - synchronous signalfd delivery on a Loop

=head1 SYNOPSIS

  package Shutdown;
  use parent 'Linux::Event::Kernel::Signal';
  use POSIX qw(SIGINT SIGTERM);

  sub on_signal ($signal, $number, $count) {
      $signal->data->{listener}->close;
      $signal->loop->stop;
  }

  package main;
  my $signal = $loop->add(Shutdown->new(
      signals => [SIGINT, SIGTERM],
      data    => { listener => $listener },
  ));

=head1 DESCRIPTION

C<Linux::Event::Kernel::Signal> converts Linux process signals into ordinary
synchronous Loop callbacks. It does not execute application Perl from an
asynchronous C signal handler and does not install a Perl C<%SIG> callback for
the subscribed numbers.

One object may subscribe to several signal numbers, and several Signal objects
on the same Loop may subscribe to the same number. The Loop uses one shared
nonblocking signalfd plus a native fan-out registry.

=head1 CONSTRUCTION

C<signals> is required and contains the numeric signals to subscribe to.
C<data> stores arbitrary application state. C<loop =E<gt> $loop> attaches
immediately; otherwise add the detached object with C<< $loop->add($signal) >>.

=head1 CALLBACK

A concrete subclass defines:

  sub on_signal ($signal, $number, $count) { ... }

C<$count> is the number of signalfd records observed for that signal in the
current complete drain. Real-time signals retain queued records; ordinary
signals may already have coalesced in the kernel before signalfd observes them.

Subscribers for one signal are called in attachment order. Dispatch is safe
when a callback cancels itself or another subscriber.

=head1 SIGNAL MASK OWNERSHIP

signalfd receives signals that are blocked in the consuming thread.
Linux::Event records whether each subscribed signal was already blocked and
restores only mask entries that Linux::Event itself changed when the last
subscription is removed.

A signal number may be owned by only one Linux::Event Loop in a process. Do not
also expect a Perl C<%SIG> handler to receive a signal while that signal is
blocked for signalfd consumption.

Signal masks are per-thread. Applications should establish Signal subscriptions
before creating their own worker threads, or explicitly arrange equivalent
blocking in those threads. Fork before attaching Signal objects; the native
service is tied to its process and owning thread.

=head1 LIFECYCLE

C<cancel> is idempotent and terminal. The Loop retains active subscriptions.
Cancellation and Loop destruction remove native fan-out entries, restore owned
mask state, and release application data safely, including cancellation during
a callback.

=head1 SEE ALSO

L<Linux::Event::Loop>, F<docs/SIGNAL-DESIGN.md>.

=cut
