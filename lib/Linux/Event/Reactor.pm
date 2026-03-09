package Linux::Event::Reactor;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

use Scalar::Util qw(looks_like_number);
use Carp qw(croak);
use Linux::Event::Scheduler;
use Linux::Event::Clock;
use Linux::Event::Timer;
use Linux::Event::Reactor::Backend::Epoll;
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
  my $loop    = delete $args{loop};

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
    loop    => $loop,

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
      $self->{timer}->read_ticks;
      $self->{clock}->tick;
      $self->_dispatch_due;
      $self->_rearm_timer;
    },
    data => undef,
  );

  return $self;
}

sub _build_backend ($backend) {
  return Linux::Event::Reactor::Backend::Epoll->new if !defined $backend;

  if (!ref($backend)) {
    return Linux::Event::Reactor::Backend::Epoll->new if $backend eq 'epoll';
    croak "unknown backend '$backend'";
  }

  return $backend;
}

sub clock        ($self) { return $self->{clock} }
sub timer        ($self) { return $self->{timer} }
sub backend      ($self) { return $self->{backend} }
sub backend_name ($self) { return $self->{backend}->can('name') ? $self->{backend}->name : ref($self->{backend}) }
sub sched        ($self) { return $self->{sched} }
sub is_running   ($self) { return $self->{running} ? 1 : 0 }
sub _public_loop ($self) { return $self->{loop} || $self }

# -- Signals --------------------------------------------------------------

sub signal ($self, @args) {
  return ($self->{_signal} ||= Linux::Event::Signal->new(loop => $self->_public_loop))->signal(@args);
}

# -- Wakeups --------------------------------------------------------------

sub waker ($self) {
  if (!$self->{_waker}) {
    my $w = Linux::Event::Wakeup->new(loop => $self->_public_loop);
    $self->{_waker} = $w;

    # Internal watcher: drain wakeups.
    $self->watch(
      $w->fh,
      read => sub ($loop, $fh, $watcher) {
        $w->drain;
      },
      data => undef,
    );
  }

  return $self->{_waker};
}

# -- Pidfds ---------------------------------------------------------------

sub pid ($self, @args) {
  $self->{pid_adaptor} //= Linux::Event::Pid->new(loop => $self->_public_loop);
  return $self->{pid_adaptor}->pid(@args);
}

# -- Timers ---------------------------------------------------------------

sub after ($self, $seconds, $cb) {
  croak "seconds is required" if !defined $seconds;
  croak "cb is required" if !$cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

  $self->{clock}->tick;

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
    croak "read must be a coderef or undef";
  }
  if (defined $write && ref($write) ne 'CODE') {
    croak "write must be a coderef or undef";
  }
  if (defined $error && ref($error) ne 'CODE') {
    croak "error must be a coderef or undef";
  }

  my $fd = fileno($fh);
  croak "fh has no fileno" if !defined $fd;
  $fd = int($fd);

  if (my $old = $self->{_watchers}{$fd}) {
    $self->_watcher_cancel($old);
  }

  my $w = Linux::Event::Watcher->new(
    loop           => $self->_public_loop,
    fh             => $fh,
    fd             => $fd,
    read           => $read,
    write          => $write,
    error          => $error,
    data           => $data,
    edge_triggered => $edge_triggered ? 1 : 0,
    oneshot        => $oneshot ? 1 : 0,
  );

  my $public_loop = $self->_public_loop;
  my $owner = $self;

  my $dispatch = sub ($ignored_loop, $fh_from_backend, $fd2, $mask, $tag) {
    my $ww = $owner->{_watchers}{$fd2} or return;

    my $fhw = $ww->{fh};
    if (!$fhw) {
      $owner->_watcher_cancel($ww);
      return;
    }
    my $fnow = fileno($fhw);
    if (!defined $fnow || int($fnow) != $fd2) {
      $owner->_watcher_cancel($ww);
      return;
    }

    # Frozen dispatch contract:
    #  - ERR: call error handler first if installed+enabled; otherwise treat as read+write.
    #  - HUP: also triggers read (EOF detection).
    my $read_trig  = ($mask & READABLE) ? 1 : 0;
    my $write_trig = ($mask & WRITABLE) ? 1 : 0;

    if ($mask & ERR) {
      if ($ww->{error_cb} && $ww->{error_enabled}) {
        $ww->{error_cb}->($public_loop, $fhw, $ww);
        return;
      }
      $read_trig  = 1;
      $write_trig = 1;
    }

    $read_trig = 1 if ($mask & HUP);

    if ($read_trig && $ww->{read_cb} && $ww->{read_enabled}) {
      $ww->{read_cb}->($public_loop, $fhw, $ww);
    }

    my $still = $owner->{_watchers}{$fd2};
    if (!$still || $still != $ww) {
      return;
    }

    if ($write_trig && $ww->{write_cb} && $ww->{write_enabled}) {
      $ww->{write_cb}->($public_loop, $fhw, $ww);
    }

    return;
  };

  $w->{_dispatch_cb} = $dispatch;

  $self->{_watchers}{$fd} = $w;

  my $mask = $self->_watcher_mask($w);
  $self->{backend}->watch($fh, $mask, $dispatch, _loop => $self->_public_loop, tag => undef);

  return $w;
}

sub _watcher_mask ($self, $w) {
  my $mask = 0;

  $mask |= READABLE if $w->{read_cb}  && $w->{read_enabled};
  $mask |= WRITABLE if $w->{write_cb} && $w->{write_enabled};

  $mask |= ET      if $w->{edge_triggered};
  $mask |= ONESHOT if $w->{oneshot};

  return $mask;
}

sub _watcher_update ($self, $w) {
  return 0 if !$w->{active};

  my $mask = $self->_watcher_mask($w);

  if ($self->{backend}->can('modify')) {
    return $self->{backend}->modify($w->{fh}, $mask, _loop => $self->_public_loop, tag => undef);
  }

  # Fallback: unwatch+watch, preserving dispatch cb.
  $self->{backend}->unwatch($w->{fh});
  $self->{backend}->watch($w->{fh}, $mask, $w->{_dispatch_cb}, _loop => $self->_public_loop, tag => undef);
  return 1;
}

sub _watcher_cancel ($self, $w) {
  return 0 if !$w || !$w->{active};

  $w->{active} = 0;
  delete $self->{_watchers}{ $w->{fd} };

  $self->{backend}->unwatch($w->{fh});
  $w->{fh} = undef;

  return 1;
}

sub unwatch ($self, $fh) {
  return 0 if !$fh;

  my $fd = fileno($fh);
  return 0 if !defined $fd;
  $fd = int($fd);

  my $w = delete $self->{_watchers}{$fd} or return 0;
  $self->_watcher_cancel($w);

  return 1;
}

sub run ($self) {
  # run() controls the running flag. run_once() may be called manually even
  # when the loop is not in run() mode (tests and advanced callers rely on
  # this), so run_once() must only honor running=0 when run() is active.
  local $self->{_in_run} = 1;
  $self->{running} = 1;

  while ($self->{running}) {
    $self->run_once;
  }

  return;
}

sub stop ($self) {
  $self->{running} = 0;

  # If a waker was already created (user called $loop->waker), poke it so a
  # currently-blocking backend wait can return promptly. This does not create
  # the waker implicitly (contract: no implicit watcher).
  if (my $w = $self->{_waker}) {
    eval { $w->signal; 1 };
  }

  return;
}

sub run_once ($self, $timeout_s = undef) {
  # One syscall per iteration/batch: refresh cached monotonic time.
  $self->{clock}->tick;

  # Snapshot whether we were "running" at entry. This matters because callers
  # are allowed to pump the loop manually via run_once() without calling run()
  # (so running may be false). If running *was* true and stop() flips it during
  # callback dispatch, we must not enter backend wait in the same iteration.
  my $was_running = $self->{running} ? 1 : 0;

  # Run any due timer callbacks before blocking.
  $self->_dispatch_due;

  # stop() can be called from a timer callback (or other user callback).
  # - If we're inside run(), honor running immediately.
  # - If running was true at entry, also honor it (prevents an extra backend wait)
  # - If running was false at entry, allow manual pumping.
  return 0 if (!$self->{running} && ($self->{_in_run} || $was_running));

  # If no explicit timeout was provided, derive one from the next scheduled
  # timer deadline. This is what makes $loop->run() advance timers without
  # requiring callers to manually pass a timeout.
  if (!defined $timeout_s) {
    my $next = $self->{sched}->next_deadline_ns;
    if (defined $next) {
      my $remain_ns = $self->{clock}->remaining_ns($next);
      $timeout_s = ($remain_ns <= 0) ? 0 : ($remain_ns / 1_000_000_000);
    }
  }

  # Keep timerfd state in sync for users who may be watching the timer fd
  # directly (or for future backends that integrate it). This is not relied on
  # for core scheduling.
  $self->_rearm_timer;

  # Re-check after rearm, since user callbacks can run during _rearm_timer()
  # (e.g. via a custom timer implementation).
  return 0 if (!$self->{running} && ($self->{_in_run} || $was_running));

  return $self->{backend}->run_once($self, $timeout_s);
}


sub _dispatch_due ($self) {
  my @ready = $self->{sched}->pop_expired;
  for my $item (@ready) {
    my ($id, $cb, $deadline_ns) = @$item;

    # Timer callbacks are invoked with just ($loop).
    $cb->($self->_public_loop);
  }
  return;
}


use Scalar::Util qw(looks_like_number);

sub _rearm_timer ($self) {
  my $next = $self->{sched}->next_deadline_ns;

  if (!defined $next) {
    $self->{timer}->disarm;
    return;
  }

  my $remain_ns = $self->{clock}->remaining_ns($next);

  return if !defined $remain_ns;
  return if !looks_like_number($remain_ns);

  if ($remain_ns <= 0) {
    # Minimal non-zero delay (fixed decimal, no exponent).
    my $min_s = sprintf('%.9f', 1 / 1_000_000_000);
    $self->{timer}->after($min_s);
    return;
  }

  my $after_s = $remain_ns / 1_000_000_000;

  return if !looks_like_number($after_s);

  # IMPORTANT: format to fixed decimal so Timer::_num accepts it.
  $self->{timer}->after(sprintf('%.9f', $after_s));

  return;
}

1;

__END__

=head1 NAME

Linux::Event::Reactor - Linux-native reactor loop (epoll + timerfd + signalfd + eventfd + pidfd)

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new( model => 'reactor', backend => 'epoll' );

  # Timer (seconds, fractional allowed)
  $loop->after(0.250, sub ($loop) {
    say "tick";
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

    write => sub ($loop, $fh, $w) {
      # fd became writable
    },

    error => sub ($loop, $fh, $w) {
      # error readiness
    },
  );

  $loop->run;

  # For socket acquisition and buffered I/O, see:
  #   Linux::Event::Listen
  #   Linux::Event::Connect
  #   Linux::Event::Stream

=head1 DESCRIPTION

B<Linux::Event::Reactor> is the reactor engine for Linux::Event, built on:

=over 4

=item * epoll for I/O readiness

=item * timerfd for timers

=item * signalfd for signals

=item * eventfd for explicit wakeups

=item * pidfd for process exit notifications

=back

It provides low-level primitives for readiness, timers, signals, wakeups, and
process monitoring. It does not implement higher-level socket acquisition or
buffered I/O; those live in separate distributions.

=head1 LAYERING

This module is the reactor engine layer of the ecosystem.

=over 4

=item * B<Linux::Event::Loop>

Reactor loop and kernel primitive integration.

=item * B<Linux::Event::Listen>

Server-side socket acquisition (bind + accept).

=item * B<Linux::Event::Connect>

Client-side socket acquisition (nonblocking connect).

=item * B<Linux::Event::Stream>

Buffered I/O and backpressure for established filehandles.

=back

Canonical composition:

  Listen/Connect -> Stream -> (your protocol/state)

The loop intentionally does not grow into a framework layer. Higher-level
composition belongs in application code or optional glue distributions.

=head1 CALLBACK CONTRACTS

=head2 I/O watchers

  $loop->watch($fh, %callbacks);

Callbacks use this signature:

  sub ($loop, $fh, $watcher) { ... }

Where:

=over 4

=item * C<$loop>

The loop instance.

=item * C<$fh>

The filehandle that became ready.

=item * C<$watcher>

The L<Linux::Event::Watcher> object returned by C<watch()>.

=back

Possible callback keys:

=over 4

=item * C<read>

Invoked when the fd becomes readable.

=item * C<write>

Invoked when the fd becomes writable.

=item * C<error>

Invoked when error readiness is reported.

=back

Callbacks are invoked synchronously during C<run()> dispatch.

=head2 Timers

  $loop->after($seconds, sub ($loop) { ... });

Timer callbacks receive:

  sub ($loop) { ... }

=head2 Signals

Signal callbacks receive:

  sub ($loop, $signal_number, $watcher) { ... }

(See L<Linux::Event::Signal>.)

=head2 PID notifications

PID callbacks receive:

  sub ($loop, $pid, $status, $watcher) { ... }

(See L<Linux::Event::Pid>.)

=head1 WATCHERS

=head2 watch

  my $w = $loop->watch($fh, %callbacks);

Registers readiness interest for C<$fh> and returns a
L<Linux::Event::Watcher>.

The watcher object controls readiness interest and lifetime.

=head2 Watcher semantics

=over 4

=item * Ownership

The loop does not close C<$fh>. You own the filehandle.

=item * cancel

  $w->cancel;

Removes the watcher from the loop. Idempotent.

=item * enable_read / disable_read
=item * enable_write / disable_write

Mutate readiness interest without destroying the watcher.

=item * Lifetime

When cancelled, the watcher becomes inert and will not invoke callbacks again.

=back

=head1 TIMERS

=head2 after

  $loop->after($seconds, sub ($loop) { ... });

Schedules a one-shot timer.

=head2 every (if supported)

  $loop->every($seconds, sub ($loop) { ... });

Schedules a repeating timer.

Timer precision is governed by the underlying timerfd and scheduler.

=head1 RUN CONTROL

=head2 run

  $loop->run;

Enters the event loop and dispatches events until C<stop> is called.

=head2 stop

  $loop->stop;

Stops the loop after the current dispatch iteration.

=head1 ERROR HANDLING

The loop itself does not impose global error policy. Errors are delivered to
watcher callbacks (I/O), signal callbacks, PID callbacks, or higher-level
modules such as Listen and Connect.

=head1 THREADING

This loop is not thread-safe. All operations must occur from the same thread
that owns the loop.

For cross-thread wakeups, use L<Linux::Event::Wakeup>.

=head1 SEE ALSO

L<Linux::Event::Listen> - nonblocking bind + accept

L<Linux::Event::Connect> - nonblocking outbound connect

L<Linux::Event::Stream> - buffered I/O and backpressure for sockets

L<Linux::Event::Fork> - asynchronous child process management

L<Linux::Event::Clock> - high resolution monotonic clock utilities>

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
