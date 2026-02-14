package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

use Linux::Event::Scheduler;

our $VERSION = '0.003_001';

use Carp qw(croak);

use Linux::Event::Clock;
use Linux::Event::Timer;
use Linux::Event::Backend::Epoll;
use Linux::Event::Watcher;
use Linux::Event::Signal;
use Linux::Event::Wakeup;
use Linux::Event::Pid;

use constant READABLE => 0x01;
use constant WRITABLE => 0x02;
use constant PRIO     => 0x04;
use constant RDHUP    => 0x08;
use constant ET       => 0x10;
use constant ONESHOT  => 0x20;
use constant ERR      => 0x40;
use constant HUP      => 0x80;

sub new ($class, %args) {
  my $backend = delete $args{backend};
  my $clock   = delete $args{clock};
  my $timer   = delete $args{timer};

  croak "unknown args: " . join(", ", sort keys %args) if %args;

  $clock //= Linux::Event::Clock->new(clock => 'monotonic');
  for my $m (qw(tick now_ns deadline_in_ns remaining_ns)) {
    croak "clock missing method '$m'" if !$clock->can($m);
  }

  $timer //= Linux::Event::Timer->new;
  for my $m (qw(after disarm read_ticks fh)) {
    croak "timer missing method '$m'" if !$timer->can($m);
  }

  $backend = _build_backend($backend);
  for my $m (qw(watch unwatch run_once)) {
    croak "backend missing method '$m'" if !$backend->can($m);
  }
  # modify is optional in this release; Loop can fall back to unwatch+watch.

  my $sched = Linux::Event::Scheduler->new(clock => $clock);

  my $self = bless {
    clock   => $clock,
    timer   => $timer,
    backend => $backend,
    sched   => $sched,
    running => 0,

    _watchers => {},     # fd -> Linux::Event::Watcher
    _timer_w  => undef,  # internal timerfd watcher
  }, $class;

  # Internal timerfd watcher: read -> dispatch due timers -> rearm kernel timer.
  my $t_fh = $timer->fh;
  my $t_fd = fileno($t_fh);
  croak "timer fh has no fileno" if !defined $t_fd;

  $self->{_timer_w} = $self->watch(
    $t_fh,
    read => sub ($loop, $fh, $w) {
      $loop->{timer}->read_ticks;
      $loop->{clock}->tick;
      $loop->_dispatch_due;
      $loop->_rearm_timer;
    },
    data => undef,
  );

  return $self;
}

sub _build_backend ($backend) {
  return Linux::Event::Backend::Epoll->new if !defined $backend;

  if (!ref($backend)) {
    return Linux::Event::Backend::Epoll->new if $backend eq 'epoll';
    croak "unknown backend '$backend'";
  }

  return $backend;
}

sub clock   ($self) { return $self->{clock} }
sub timer   ($self) { return $self->{timer} }
sub backend ($self) { return $self->{backend} }
sub sched   ($self) { return $self->{sched} }

# -- Signals --------------------------------------------------------------

sub signal ($self, @args) {
  # Thin delegator to keep Loop.pm small. The Signal object is cached.
  return ($self->{_signal} ||= Linux::Event::Signal->new(loop => $self))->signal(@args);
}

# -- Wakeups --------------------------------------------------------------

sub waker ($self) {
  # Single-waker contract: exactly one waker per loop, cached.
  return ($self->{_waker} ||= Linux::Event::Wakeup->new(loop => $self));
}

sub pid ($self, @args) {
  $self->{pid_adaptor} //= Linux::Event::Pid->new(loop => $self);
  return $self->{pid_adaptor}->pid(@args);
}

# -- Timers ---------------------------------------------------------------

sub after ($self, $seconds, $cb) {
  croak "seconds is required" if !defined $seconds;
  croak "cb is required" if !$cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

  $self->{clock}->tick;

  # Seconds may be float; store as ns internally.
  my $delta_ns = int($seconds * 1_000_000_000);
  $delta_ns = 0 if $delta_ns < 0;

  my $id = $self->{sched}->after_ns($delta_ns, $cb);
  $self->_rearm_timer;
  return $id;
}

sub at ($self, $deadline_seconds, $cb) {
  croak "deadline_seconds is required" if !defined $deadline_seconds;
  croak "cb is required" if !$cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

  # Deadline is monotonic seconds (same timebase as Clock).
  my $deadline_ns = int($deadline_seconds * 1_000_000_000);

  my $id = $self->{sched}->at_ns($deadline_ns, $cb);
  $self->_rearm_timer;
  return $id;
}

sub cancel ($self, $id) {
  my $ok = $self->{sched}->cancel($id);
  $self->_rearm_timer if $ok;
  return $ok;
}

# -- Watchers -------------------------------------------------------------

sub watch ($self, $fh, %spec) {
  croak "fh is required" if !$fh;

  my $read           = delete $spec{read};
  my $write          = delete $spec{write};
  my $error          = delete $spec{error};
  my $data           = delete $spec{data};
  my $edge_triggered = delete $spec{edge_triggered};
  my $oneshot        = delete $spec{oneshot};

  croak "unknown args: " . join(", ", sort keys %spec) if %spec;

  if (defined $read && ref($read) ne 'CODE') {
    croak "read must be a coderef";
  }
  if (defined $write && ref($write) ne 'CODE') {
    croak "write must be a coderef";
  }
  if (defined $error && ref($error) ne 'CODE') {
    croak "error must be a coderef";
  }

  my $fd = fileno($fh);
  croak "fh has no fileno" if !defined $fd;

  # Replace semantics: if a watcher already exists for this fd, cancel it first.
  if (my $old = delete $self->{_watchers}{$fd}) {
    $old->cancel;
  }

  my $w = Linux::Event::Watcher->new(
    loop           => $self,
    fh             => $fh,
    fd             => $fd,
    read_cb         => $read,
    write_cb        => $write,
    error_cb        => $error,
    data            => $data,
    edge_triggered  => $edge_triggered ? 1 : 0,
    oneshot         => $oneshot ? 1 : 0,
  );

  $self->{_watchers}{$fd} = $w;

  $self->{backend}->watch($w);

  return $w;
}

sub unwatch ($self, $fh) {
  return 0 if !$fh;

  my $fd = fileno($fh);
  return 0 if !defined $fd;

  my $w = delete $self->{_watchers}{$fd};
  return 0 if !$w;

  $w->cancel;
  return 1;
}

sub _dispatch_due ($self) {
  my $now = $self->{clock}->now_ns;

  while (1) {
    my $t = $self->{sched}->pop_due($now);
    last if !$t;

    my $cb = $t->{cb};
    $cb->($self);
  }
}

sub _rearm_timer ($self) {
  my $next = $self->{sched}->next_deadline_ns;

  if (!defined $next) {
    $self->{timer}->disarm;
    return;
  }

  my $now = $self->{clock}->now_ns;
  my $delta = $next - $now;
  $delta = 0 if $delta < 0;

  $self->{timer}->after($delta);
}

sub _dispatch_io ($self, $fh, $mask) {
  my $w = $self->{_watchers}{ fileno($fh) };
  return if !$w; # watcher removed during dispatch

  # Dispatch order is frozen:
  #   1) error
  #   2) read
  #   3) write
  if ($mask & (ERR | HUP | RDHUP)) {
    $w->_dispatch_error($self, $fh);
  }
  if ($mask & (READABLE | PRIO)) {
    $w->_dispatch_read($self, $fh);
  }
  if ($mask & WRITABLE) {
    $w->_dispatch_write($self, $fh);
  }
}

sub run ($self) {
  $self->{running} = 1;

  while ($self->{running}) {
    $self->run_once;
  }

  return;
}

sub run_once ($self, $timeout_seconds = undef) {
  $self->{clock}->tick;

  my $timeout_ns;
  if (defined $timeout_seconds) {
    $timeout_ns = int($timeout_seconds * 1_000_000_000);
    $timeout_ns = 0 if $timeout_ns < 0;
  } else {
    $timeout_ns = $self->{sched}->remaining_ns;
  }

  my $events = $self->{backend}->run_once($timeout_ns);

  for my $ev (@$events) {
    my ($fh, $mask) = @$ev;
    $self->_dispatch_io($fh, $mask);
  }

  # Timerfd is handled by its own watcher; calling _dispatch_due() here would
  # duplicate work. We only need to tick/rearm if the clock advanced, which
  # happens via timerfd reads or explicit run_once calls.

  return;
}

sub stop ($self) {
  $self->{running} = 0;
  return;
}

1;

__END__

=head1 NAME

Linux::Event::Loop - Linux-native event loop (epoll + timerfd + signalfd + eventfd + pidfd)

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;   # epoll backend, monotonic clock

  # I/O watcher (read/write) with user data stored on the watcher:
  my $conn = My::Conn->new(...);

  my $w = $loop->watch($fh,
    read  => \&My::Conn::on_read,
    write => \&My::Conn::on_write,
    error => \&My::Conn::on_error,   # optional
    data  => $conn,                   # optional (avoid closure captures)

    edge_triggered => 0,              # optional, default false
    oneshot        => 0,              # optional, default false
  );

  $w->disable_write;

  # Timers (monotonic)
  my $id = $loop->after(0.250, sub ($loop) {
    say "250ms later";
  });

  # Signals (signalfd): strict 4-arg callback
  my $sub = $loop->signal('INT', sub ($loop, $sig, $count, $data) {
    say "SIG$sig ($count)";
    $loop->stop;
  });

  # Wakeups (eventfd): watch like a normal fd
  my $waker = $loop->waker;
  $loop->watch($waker->fh,
    read => sub ($loop, $fh, $watcher) {
      my $n = $waker->drain;
      ... handle non-fd work ...
    },
  );

  # Pidfds (pidfd): one-shot exit notification
  my $pid = fork() // die "fork: $!";
  if ($pid == 0) { exit 42 }

  my $psub = $loop->pid($pid, sub ($loop, $pid, $status, $data) {
    require POSIX;
    if (POSIX::WIFEXITED($status)) {
      say "child $pid exited: " . POSIX::WEXITSTATUS($status);
    }
  });

  $loop->run;

=head1 DESCRIPTION

Linux::Event::Loop is a minimal, Linux-native event loop that exposes Linux
FD primitives cleanly and predictably. It is built around:

=over 4

=item * C<epoll(7)> for I/O readiness

=item * C<timerfd(2)> for timers

=item * C<signalfd(2)> for signal delivery

=item * C<eventfd(2)> for explicit wakeups

=item * C<pidfd_open(2)> (via L<Linux::FD::Pid>) for process lifecycle notifications

=back

Linux::Event is intentionally I<not> a networking framework, protocol layer,
retry/backoff engine, process supervisor, or socket abstraction. Ownership is
explicit; there is no implicit close, and teardown operations are idempotent.

=head1 CONSTRUCTION

=head2 new(%opts) -> $loop

  my $loop = Linux::Event->new(
    backend => 'epoll',   # default
    clock   => $clock,    # optional; must provide tick/now_ns/etc.
    timer   => $timer,    # optional; must provide after/disarm/read_ticks/fh
  );

Options:

=over 4

=item * C<backend>

Either the string C<'epoll'> (default) or a backend object that implements
C<watch>, C<unwatch>, and C<run_once>.

=item * C<clock>

An object implementing the clock interface used by the scheduler. By default,
a monotonic clock is used.

=item * C<timer>

An object implementing the timerfd interface used by the loop. By default,
L<Linux::Event::Timer> is used.

=back

=head1 RUNNING THE LOOP

=head2 run() / run_once($timeout_seconds) / stop()

C<run()> enters the dispatch loop and continues until C<stop()> is called.

C<run_once($timeout_seconds)> runs at most one backend wait/dispatch cycle. The
timeout is in seconds; fractions are allowed.

=head1 WATCHERS

=head2 watch($fh, %spec) -> Linux::Event::Watcher

Create (or replace) a watcher for a filehandle.

Watchers are keyed internally by file descriptor (fd). Calling C<watch()> again
for the same fd replaces the existing watcher atomically.

Interest is inferred from installed handlers and enable/disable state.

Supported keys in C<%spec>:

=over 4

=item * C<read>  - coderef (optional)

=item * C<write> - coderef (optional)

=item * C<error> - coderef (optional). Called on C<EPOLLERR> (see Dispatch contract).

=item * C<data>  - user data (optional). Stored on the watcher to avoid closure captures.

=item * C<edge_triggered> - boolean (optional, advanced). Defaults to false.

=item * C<oneshot> - boolean (optional, advanced). Defaults to false.

=back

Handlers are invoked as:

  read  => sub ($loop, $fh, $watcher) { ... }
  write => sub ($loop, $fh, $watcher) { ... }
  error => sub ($loop, $fh, $watcher) { ... }

=head2 unwatch($fh) -> bool

Remove the watcher for C<$fh>. Returns true if a watcher was removed, false if
C<$fh> was not watched (or had no fd). Calling C<unwatch()> multiple times is safe.

=head2 Dispatch contract

When the backend reports events for a file descriptor, the loop dispatches
callbacks in this order (when applicable):

=over 4

=item 1. C<error>

=item 2. C<read>

=item 3. C<write>

=back

This order is frozen.

=head1 SIGNALS

=head2 signal($sig_or_list, $cb, %opt) -> Linux::Event::Signal::Subscription

Register a signal handler using Linux C<signalfd>.

C<$sig_or_list> may be a signal number (e.g. C<2>), a signal name (C<'INT'> or
C<'SIGINT'>), or an arrayref of those values.

Callback ABI (strict): the callback is always invoked with 4 arguments:

  sub ($loop, $sig, $count, $data) { ... }

Where C<$sig> is the numeric signal and C<$count> is how many deliveries of that
signal were drained in this dispatch cycle.

Only one handler is stored per signal; calling C<signal()> again for the same
signal replaces the previous handler.

Options:

=over 4

=item * C<data> - arbitrary user value passed as the final callback argument.

=back

Returns a subscription handle with an idempotent C<cancel> method.

See L<Linux::Event::Signal>.

=head1 WAKEUPS

=head2 waker() -> Linux::Event::Wakeup

Returns the loop's singleton waker object (an C<eventfd(2)> handle) used to
wake the loop from another thread or process.

The waker is created lazily on first use and is never destroyed for the lifetime
of the loop.

The waker exposes a readable filehandle (C<< $waker->fh >>) suitable for
C<< $loop->watch(...) >>, and provides C<< $waker->signal >> and
C<< $waker->drain >> methods. No watcher is installed automatically.

See L<Linux::Event::Wakeup>.

=head1 PIDFDS

=head2 pid($pid, $cb, %opts) -> Linux::Event::Pid::Subscription

  my $sub = $loop->pid($pid, sub ($loop, $pid, $status, $data) {
    ...
  }, data => $any, reap => 1);

Registers a pidfd watcher for C<$pid>.

Callback ABI (strict): the callback is always invoked with 4 arguments:

  sub ($loop, $pid, $status, $data) { ... }

If C<reap =E<gt> 1> (default), the loop attempts a non-blocking reap of the PID
and passes a wait-status compatible value in C<$status>. If C<reap =E<gt> 0>,
no reap is attempted and C<$status> is C<undef>.

This is a one-shot subscription: after a defined status is observed and the
callback is invoked, the subscription is automatically canceled.

Replacement semantics apply per PID: calling C<pid()> again for the same C<$pid>
replaces the existing subscription.

See L<Linux::Event::Pid> for full semantics and caveats (child-only reaping).

=head1 TIMERS

Timers use a monotonic clock. Two scheduling styles are provided:

=over 4

=item * Relative: C<after($seconds, $cb)>

=item * Absolute: C<at($deadline_seconds, $cb)>

=back

Callbacks are invoked as:

  sub ($loop) { ... }

=head2 after($seconds, $cb) -> $id

Schedule C<$cb> to run after C<$seconds>. Fractions are allowed.

=head2 at($deadline_seconds, $cb) -> $id

Schedule C<$cb> at an absolute monotonic deadline in seconds (same timebase as
the clock used by this loop). Fractions are allowed.

=head2 cancel($id) -> bool

Cancel a scheduled timer. Returns true if a timer was removed.

=head1 METHODS

The public methods are documented in the sections above. Accessors:

=over 4

=item * C<clock> - clock object

=item * C<timer> - timerfd wrapper object

=item * C<backend> - backend object (epoll)

=back

=head1 NOTES

=head2 Threading and forking helpers

Linux::Event intentionally does not provide C<< $loop->thread >> or
C<< $loop->fork >> helpers. Concurrency helpers are policy-layer constructs
and belong in separate distributions. The core provides primitives (C<waker>,
C<pid>) that make such helpers straightforward to implement in user code.

=head1 VERSION

This document describes Linux::Event::Loop version 0.003_001.

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
