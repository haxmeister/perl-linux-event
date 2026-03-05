package Linux::Event::Pid;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

use Carp qw(croak);
use Scalar::Util qw(weaken);
use POSIX ();
# Linux waitid(2) flags. POSIX.pm does not always expose WEXITED.
# On Linux, WEXITED is 0x00000004 (from <linux/wait.h>).
use constant _WEXITED => 4;

sub _wait_flags ($self) {
  my $wnohang = eval { POSIX::WNOHANG() };
  $wnohang = 1 if !defined $wnohang;  # WNOHANG is 1 on Linux

  my $wexited = eval { POSIX::WEXITED() };
  $wexited = _WEXITED if !defined $wexited;

  return $wexited | $wnohang;
}


# pidfd-backed process exit notifications for Linux::Event.
#
# This module is a thin adaptor over Linux::FD::Pid. It opens a pidfd and
# registers a normal watcher with the loop; core dispatch remains unchanged.

sub new ($class, %args) {
  my $loop = delete $args{loop};
  croak "loop is required" if !$loop;
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  weaken($loop);

  return bless {
    loop     => $loop,
    by_pid   => {},   # pid -> entry
  }, $class;
}

sub loop ($self) { return $self->{loop} }

sub pid ($self, $pid, $cb, %opts) {
  croak "pid is required" if !defined $pid;
  croak "callback is required" if !$cb || ref($cb) ne 'CODE';

  my $data = delete $opts{data};
  my $reap = delete $opts{reap};
  $reap = 1 if !defined $reap;
  croak "unknown opts: " . join(", ", sort keys %opts) if %opts;

  croak "pid must be a positive integer" if $pid !~ /\A\d+\z/ || $pid < 1;

  # Replacement semantics per PID:
  if (my $old = $self->{by_pid}{$pid}) {
    $old->{sub}->cancel;
  }

  my $fh = $self->_open_pidfd($pid);

  my $entry = {
    pid  => $pid,
    fh   => $fh,
    cb   => $cb,
    data => $data,
    reap => $reap ? 1 : 0,
    sub  => undef,
    w    => undef,
  };

  my $sub = bless { _pid => $pid, _owner => $self, _active => 1 }, 'Linux::Event::Pid::Subscription';

  $entry->{sub} = $sub;

  # Watch pidfd like any other fd. pidfd becomes readable when the target exits.
  my $w = $self->{loop}->watch($fh,
    read  => sub ($loop, $watcher, $ud) { $self->_on_ready($pid) },
    error => sub ($loop, $watcher, $ud) { $self->_on_ready($pid) },
    data  => undef,
  );

  $entry->{w} = $w;
  $self->{by_pid}{$pid} = $entry;

  return $sub;
}

sub _open_pidfd ($self, $pid) {
  eval { require Linux::FD::Pid; 1 }
    or croak "Linux::FD::Pid is required for pid() support: $@";

  # The module accepts 'non-blocking' as a flag; we still use WNOHANG for waits
  # to guarantee we never block in dispatch.
  my $fh = Linux::FD::Pid->new($pid, 'non-blocking');
  return $fh;
}

sub _on_ready ($self, $pid) {
  my $entry = $self->{by_pid}{$pid} or return;

  # If the subscription has been canceled, ignore spurious readiness.
  return if !$entry->{sub} || !$entry->{sub}{_active};

  my $status;
  if ($entry->{reap}) {
    # Non-blocking: returns undef if not ready.
    my $ok = eval {
      $status = $entry->{fh}->wait($self->_wait_flags);
      1;
    };
    if (!$ok) {
      # Not our child, already reaped, or other waitid() failure.
      my $err = $@ || "$!";
      croak "pid() reap failed for pid $pid: $err";
    }

    # If wait returned undef, the process may not be fully ready yet.
    return if !defined $status;
  } else {
    $status = undef;
  }

  # Dispatch (strict ABI: always 4 args).
  my $cb = $entry->{cb};
  $cb->($self->{loop}, $pid, $status, $entry->{data});

  # One-shot: once the process has exited (and we've observed readiness),
  # tear down the subscription.
  $entry->{sub}->cancel;

  return;
}

package Linux::Event::Pid::Subscription;
use v5.36;
use strict;
use warnings;

sub cancel ($self) {
  return 0 if !$self->{_active};
  $self->{_active} = 0;

  my $owner = $self->{_owner} or return 1;
  my $pid   = $self->{_pid};

  my $entry = delete $owner->{by_pid}{$pid};
  return 1 if !$entry;

  # Unwatch first (idempotent in watcher).
  if (my $w = $entry->{w}) {
    $w->cancel;
  }

  # Drop pidfd handle (will close when refcount reaches zero).
  $entry->{fh} = undef;

  return 1;
}

1;

__END__

=head1 NAME

Linux::Event::Pid - pidfd-backed process exit notifications for Linux::Event

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;

  my $pid = fork() // die "fork: $!";
  if ($pid == 0) { exit 42 }

  my $sub = $loop->pid($pid, sub ($loop, $pid, $status, $data) {
    $loop->stop;

    if (defined $status) {
      my $code = $status >> 8;
      say "child $pid exited with $code";
    } else {
      say "pid $pid exited (status unavailable)";
    }
  });

  $loop->run;

=head1 DESCRIPTION

B<Linux::Event::Pid> integrates Linux pid file descriptors (pidfd) into
L<Linux::Event>. It opens a pidfd using L<Linux::FD::Pid> and watches it via the
loop like any other filehandle. When the pidfd becomes readable, the callback is
invoked.

This is a Linux-native alternative to C<SIGCHLD>-based wakeups.

Exit status is only available when the watched PID is a child of the current
process and reaping is enabled (see L</reap>).

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

Most users will subscribe via the loop method:

  my $sub = $loop->pid($pid, $cb, %opt);

This delegates to an internal L<Linux::Event::Pid> instance owned by the loop.
The returned value is a subscription object (see L</SUBSCRIPTIONS>).

=head1 SUBSCRIPTIONS

Subscribing returns a subscription object:

  my $sub = $loop->pid($pid, $cb, data => $data);

The subscription object supports:

=over 4

=item * C<< $sub->cancel >>

Cancel the subscription (idempotent).

=item * C<< $sub->is_active >> (if supported by the subscription type)

If present, true while the subscription is active.

=back

This module also uses one-shot semantics: after the exit event is observed and
delivered, the subscription cancels itself automatically.

=head1 CALLBACK CONTRACT

PID callbacks are invoked with this signature:

  sub ($loop, $pid, $status, $data) { ... }

Exactly four arguments are passed.

=over 4

=item * C<$loop>

The L<Linux::Event::Loop> instance.

=item * C<$pid>

The watched PID.

=item * C<$status>

A raw wait status compatible with the usual POSIX wait macros. For a normal
exit, you can extract an exit code with:

  my $code = $status >> 8;

If exit status is unavailable, C<$status> is C<undef>.

=item * C<$data>

The C<data> option you provided when registering (or undef).

=back

=head1 SEMANTICS

=head2 One subscription per PID (replacement semantics)

This module stores at most one handler per PID.

Registering C<pid()> again for the same PID replaces the previous subscription.

=head2 One-shot delivery

When the target exit is observed (and, if C<reap> is enabled, a defined wait
status is obtained), the callback is invoked once and the subscription is
automatically canceled.

=head2 Reaping and status availability

By default C<reap =E<gt> 1> and Linux::Event attempts a non-blocking wait via:

  Linux::FD::Pid->wait(WEXITED | WNOHANG)

Exit status is only available for child processes. If reaping fails (for example
because the PID is not a child or has already been reaped), this module throws
an exception.

If you want an exit notification without attempting to reap or obtain a status,
use C<reap =E<gt> 0>. In that mode, the callback will receive C<$status> as
C<undef>.

=head2 Nonblocking dispatch

The pidfd is watched in nonblocking style and the wait operation uses
C<WNOHANG>. Dispatch will not block the event loop.

=head2 Cancellation is idempotent

Cancelling a subscription multiple times is safe.

=head1 METHODS

=head2 pid

  my $sub = $loop->pid($pid, $cb, %opt);

Register a handler for C<$pid>. One handler per PID is allowed; registering again
replaces the previous handler.

Options:

=over 4

=item * data => $any

Optional user data passed to the callback as the last argument.

=item * reap => 1|0

Defaults to 1. If true, Linux::Event attempts to reap the child using a
non-blocking wait and passes the wait status. If false, no wait is attempted and
C<$status> will be undef.

=back

The returned subscription supports C<< $sub->cancel >> (idempotent).

=head1 DEPENDENCIES

Requires L<Linux::FD::Pid> and a kernel that supports C<pidfd_open(2)>.

The dependency is loaded lazily; you only need it installed if you use C<pid()>
support.

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
