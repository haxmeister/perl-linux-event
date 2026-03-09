package Linux::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

use Linux::Event::Loop;

sub new ($class, %args) {
  return Linux::Event::Loop->new(%args);
}

1;

__END__

=head1 NAME

Linux::Event - Front door for the Linux::Event ecosystem

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new( model => 'reactor', backend => 'epoll' );

  # Timer (seconds, fractional allowed)
  $loop->after(0.100, sub ($loop) {
    say "tick";
    $loop->stop;
  });

  # Raw I/O watcher
  my $w = $loop->watch(
    $fh,
    read => sub ($loop, $fh, $w) {
      my $buf;
      my $n = sysread($fh, $buf, 8192);

      if (!defined $n || $n == 0) {
        $w->cancel;
        close $fh;
        return;
      }

      # ... handle $buf ...
    },
  );

  $loop->run;

  # For socket acquisition and buffered I/O:
  #   see Linux::Event::Listen
  #   see Linux::Event::Connect
  #   see Linux::Event::Stream

=head1 DESCRIPTION

C<Linux::Event> is the front door for the Linux::Event ecosystem.

In this distribution, C<Linux::Event-E<gt>new> returns a L<Linux::Event::Loop>.
That keeps the common case short while allowing the loop implementation to stay
in its own module.

This distribution provides the core loop and kernel-primitive adaptors:

=over 4

=item * L<Linux::Event::Loop> - front-door selector for reactor and proactor engines

=item * L<Linux::Event::Watcher> - mutable watcher handles returned by the loop

=item * L<Linux::Event::Signal> - signalfd adaptor (signal subscriptions)

=item * L<Linux::Event::Wakeup> - eventfd-backed wakeups (loop waker)

=item * L<Linux::Event::Pid> - pidfd-backed process exit notifications

=item * L<Linux::Event::Scheduler> - internal reactor deadline scheduler (nanoseconds)

=item * L<Linux::Event::Reactor> - readiness-based event loop engine

=item * L<Linux::Event::Reactor::Backend> - reactor backend contract

=item * L<Linux::Event::Reactor::Backend::Epoll> - epoll reactor backend

=item * L<Linux::Event::Proactor> - completion-based event loop engine

=item * L<Linux::Event::Proactor::Backend> - proactor backend contract

=back

=head1 LAYERING

The ecosystem is intentionally composable and policy-light.

This distribution provides the event loop and low-level primitives. Socket
acquisition and buffered I/O live in separate distributions:

=over 4

=item * L<Linux::Event::Listen>

Server-side socket acquisition: nonblocking bind + accept. Produces accepted
nonblocking filehandles.

=item * L<Linux::Event::Connect>

Client-side socket acquisition: nonblocking outbound connect. Produces connected
nonblocking filehandles.

=item * L<Linux::Event::Stream>

Buffered I/O + backpressure for an established filehandle (accepted or
connected). Stream owns the filehandle and handles read/write buffering.

=back

Canonical composition:

  Listen/Connect -> Stream -> (your protocol/codec/state)

C<Linux::Event::Loop> deliberately does not grow into a framework layer. Higher
level composition belongs in application code (or optional glue distributions),
not in the core loop.

=head1 STATUS AND COMPATIBILITY

The public API is intended to be stable. Future releases should be additive and
should not change existing callback ABIs or dispatch order.

Linux::Event exposes Linux primitives with explicit semantics and minimal policy:

=over 4

=item * epoll for I/O readiness (via the backend)

=item * timerfd for timers

=item * signalfd for signals

=item * eventfd for explicit wakeups

=item * pidfd for process exit notifications

=back

=head1 REPOSITORY

The project repository is hosted on GitHub:

L<https://github.com/haxmeister/perl-linux-event>

=head1 SEE ALSO

L<Linux::Event::Listen> - nonblocking bind + accept

L<Linux::Event::Connect> - nonblocking outbound connect

L<Linux::Event::Stream> - buffered I/O and backpressure for sockets

L<Linux::Event::Fork> - asynchronous child process management

L<Linux::Event::Clock> - high resolution monotonic clock utilities

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
