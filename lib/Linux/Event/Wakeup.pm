package Linux::Event::Wakeup;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

use Carp qw(croak);
use Scalar::Util qw(weaken);
use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);

# eventfd-backed wakeups for Linux::Event.
#
# Semantics contract (single-waker model):
# - Exactly one waker per loop (cached by Loop).
# - Lazily created on first use.
# - Never destroyed during loop lifetime.
# - The Loop installs an internal read watcher that drains the fd.
# - User code MUST NOT watch($waker->fh, ...) directly.
# - signal() is safe from any thread.
# - drain() is non-blocking and returns the coalesced count.

sub new ($class, %args) {
  my $loop = delete $args{loop};
  croak "loop is required" if !$loop;
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  weaken($loop);

  return bless {
    loop => $loop,
    _fh  => undef,
  }, $class;
}

sub loop ($self) { return $self->{loop} }

sub fh ($self) {
  $self->_ensure_fd;
  return $self->{_fh};
}

sub signal ($self, $n = 1) {
  $self->_ensure_fd;

  $n = 1 if !defined $n;
  croak "signal() increment must be a positive integer" if $n !~ /\A\d+\z/ || $n < 1;

  my $fh = $self->{_fh} or croak "waker not initialized";

  my $ok = eval { $fh->add(int($n)); 1 };
  if (!$ok) {
    # add() will fail with EAGAIN if the counter would overflow in non-blocking mode.
    croak "eventfd add failed: $@" if $@;
    croak "eventfd add failed: $!";
  }

  return 1;
}

sub drain ($self) {
  $self->_ensure_fd;

  my $fh = $self->{_fh} or return 0;

  my $total = 0;
  while (1) {
    my $v = eval { $fh->get };
    if (!defined $v) {
      last if $!{EAGAIN} || $!{EWOULDBLOCK};
      die $@ if $@;
      last;
    }
    $total += $v;
  }

  return $total;
}

sub _ensure_fd ($self) {
  return if $self->{_fh};

  # External dependency for eventfd integration.
  # Loaded lazily so the core loop can run even when Linux::FD::Event
  # is not installed.
  eval { require Linux::FD::Event; 1 }
    or croak "Linux::FD::Event is required for waker() support: $@";

  # Non-blocking is critical for epoll integration; we drain to EAGAIN.
  my $fh = Linux::FD::Event->new(0, 'non-blocking');

  # Ensure CLOEXEC (Linux::FD::Event does not currently expose this flag).
  my $fd = fileno($fh);
  if (defined $fd) {
    my $cur = fcntl($fh, F_GETFD, 0);
    if (defined $cur) {
      fcntl($fh, F_SETFD, $cur | FD_CLOEXEC);
    }
  }

  $self->{_fh} = $fh;
  return;
}

1;

__END__

=head1 NAME

Linux::Event::Wakeup - eventfd-backed wakeups for Linux::Event

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;

  # Create a wakeup handle attached to the loop:
  my $wakeup = $loop->wakeup(sub ($loop, $wakeup, $count, $data) {
    say "woken $count time(s)";
    $loop->stop;
  });

  # Trigger the wakeup (from the same thread or another thread/process with the fd):
  $wakeup->wake;

  $loop->run;

=head1 DESCRIPTION

B<Linux::Event::Wakeup> provides an explicit wakeup mechanism for a
L<Linux::Event::Loop> using Linux C<eventfd(2)>.

A wakeup is useful when you need to prompt the loop to run work "soon" even if
no file descriptors are currently becoming ready. It is also the standard tool
for cross-thread wakeups: one thread writes to the eventfd, the loop thread is
woken by readability on the eventfd.

This module is kept separate so that applications that do not need wakeups do
not pay for or depend on eventfd support.

=head1 LAYERING

This distribution is a loop primitive.

It does not perform socket acquisition or buffered I/O. For sockets and I/O
stack composition, see:

=over 4

=item * L<Linux::Event::Listen> - accept produces an accepted fh

=item * L<Linux::Event::Connect> - connect produces a connected fh

=item * L<Linux::Event::Stream> - buffered I/O + backpressure, owns the fh

=back

=head1 LOOP CONVENIENCE API

Most users create a wakeup via the loop method:

  my $wakeup = $loop->wakeup($cb, %opt);

This installs an internal watcher on the eventfd and dispatches your callback on
wakeup.

=head1 CALLBACK CONTRACT

Wakeup callbacks are invoked with this signature:

  sub ($loop, $wakeup, $count, $data) { ... }

Where:

=over 4

=item * C<$loop>

The L<Linux::Event::Loop> instance.

=item * C<$wakeup>

The wakeup object.

=item * C<$count>

The number of wakeup increments drained from the eventfd since the last dispatch
cycle. If multiple C<wake()> calls occur before the loop drains the fd, they are
coalesced into a single callback with C<$count E<gt> 1>.

=item * C<$data>

The C<data> option you supplied (or undef).

=back

=head1 SEMANTICS

=head2 Coalescing

C<eventfd> is counter-based. Each C<wake()> increments the counter. When the fd
becomes readable, the loop drains the counter and delivers the aggregate count
to your callback.

=head2 Nonblocking

The underlying eventfd is used in nonblocking mode, and draining it will not
block the loop.

=head2 Threading

The wakeup fd can be written from another thread to wake the loop thread. The
wakeups themselves are safe across threads, but the loop and watcher operations
are not thread-safe; only call loop mutation APIs from the loop thread.

=head1 CONSTRUCTOR

=head2 new

  my $wakeup = Linux::Event::Wakeup->new(
    loop => $loop,
    on_wakeup => $cb,
    %opt,
  );

Creates a wakeup object attached to a loop.

Most users should prefer C<< $loop->wakeup(...) >>.

=head1 OPTIONS

=head2 on_wakeup

  on_wakeup => sub ($loop, $wakeup, $count, $data) { ... }

Required. Handler invoked when the eventfd is drained.

=head2 data

  data => $any

Optional user data passed to C<on_wakeup> as the last argument.

=head2 cloexec

  cloexec => 1  # default

Best-effort FD_CLOEXEC on the underlying eventfd.

=head1 METHODS

=head2 wake

  $wakeup->wake;
  $wakeup->wake($n);

Increment the eventfd counter by 1 (or by C<$n> if supported by the
implementation). This causes readability on the wakeup fd and schedules a future
dispatch to C<on_wakeup>.

=head2 fh / fd

  my $fh = $wakeup->fh;
  my $fd = $wakeup->fd;

Return the underlying eventfd filehandle or numeric file descriptor.

=head2 watcher

  my $w = $wakeup->watcher;

Return the underlying L<Linux::Event::Watcher> installed on the loop.

=head2 cancel

  $wakeup->cancel;

Cancel the watcher and detach from the loop. Idempotent.

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
