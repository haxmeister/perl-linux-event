package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.002_001';

use Carp qw(croak);

use Linux::Event::Clock;
use Linux::Event::Timer;
use Linux::Event::Scheduler;

use Linux::Event::Backend::Epoll;
use Linux::Event::Watcher;

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

# -- Timers ---------------------------------------------------------------

sub after ($self, $seconds, $cb) {
  croak "seconds is required" if !defined $seconds;
  croak "cb is required" if !$cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

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

  my $fd = fileno($fh);
  croak "fh has no fileno" if !defined $fd;
  $fd = int($fd);

  croak "fd already watched: $fd" if exists $self->{_watchers}{$fd};

  my $w = Linux::Event::Watcher->new(
    loop           => $self,
    fh             => $fh,
    fd             => $fd,
    read           => $read,
    write          => $write,
    data           => $data,
    edge_triggered => $edge_triggered ? 1 : 0,
    oneshot        => $oneshot ? 1 : 0,
  );

  # Backend callback dispatch:
  # backend calls this with ($loop,$fh,$fd,$mask,$tag). We map mask->handlers.
  my $dispatch = sub ($loop, $fh, $fd2, $mask, $tag) {
    my $ww = $loop->{_watchers}{$fd2} or return;

    if (($mask & READABLE) && $ww->{read_cb} && $ww->{read_enabled}) {
      $ww->{read_cb}->($loop, $fh, $ww);
    }
    if (($mask & WRITABLE) && $ww->{write_cb} && $ww->{write_enabled}) {
      $ww->{write_cb}->($loop, $fh, $ww);
    }
    return;
  };

  $w->{_dispatch_cb} = $dispatch; # used by modify fallback

  $self->{_watchers}{$fd} = $w;

  my $mask = $self->_watcher_mask($w);
  $self->{backend}->watch($fh, $mask, $dispatch, _loop => $self, tag => undef);

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

  my $fh = $w->{fh};
  my $fd = $w->{fd};

  my $mask = $self->_watcher_mask($w);

  if ($self->{backend}->can('modify')) {
    $self->{backend}->modify($fh, $mask, _loop => $self);
    return 1;
  }

  # Fallback: unwatch + watch (temporary until backend->modify exists).
  $self->{backend}->unwatch($fd);

  my $dispatch = $w->{_dispatch_cb};
  $self->{backend}->watch($fh, $mask, $dispatch, _loop => $self, tag => undef);

  return 1;
}

sub _watcher_cancel ($self, $w) {
  return 0 if !$w->{active};

  my $fd = $w->{fd};
  my $ok = $self->{backend}->unwatch($fd);

  delete $self->{_watchers}{$fd};

  return $ok ? 1 : 0;
}

# -- Loop ----------------------------------------------------------------

sub run ($self) {
  $self->{running} = 1;
  $self->{clock}->tick;
  $self->_rearm_timer;

  while ($self->{running}) {
    $self->run_once;
  }

  return;
}

sub stop ($self) {
  $self->{running} = 0;
  return;
}

sub run_once ($self, $timeout_s = undef) {
  return $self->{backend}->run_once($self, $timeout_s);
}

sub _dispatch_due ($self) {
  my @ready = $self->{sched}->pop_expired;
  for my $item (@ready) {
    my ($id, $cb, $deadline_ns) = @$item;

    # Timer callbacks are invoked with just ($loop).
    $cb->($self);
  }
  return;
}

sub _rearm_timer ($self) {
  my $next = $self->{sched}->next_deadline_ns;

  if (!defined $next) {
    $self->{timer}->disarm;
    return;
  }

  my $remain_ns = $self->{clock}->remaining_ns($next);

  if ($remain_ns <= 0) {
    $self->{timer}->after(0);
    return;
  }

  my $after_s = $remain_ns / 1_000_000_000;
  $self->{timer}->after($after_s);

  return;
}

1;

__END__

=head1 NAME

Linux::Event::Loop - Backend-agnostic Linux event loop (Clock + Timer + Scheduler)

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;

  my $conn = My::Conn->new(...);

  my $w = $loop->watch($fh,
    read  => \&My::Conn::on_read,
    write => \&My::Conn::on_write,
    data  => $conn,
  );

  $w->disable_write;  # enable later when output buffered

  $loop->after(0.250, sub ($loop) {
    warn "250ms elapsed\n";
  });

  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Loop> ties together:

=over 4

=item * L<Linux::Event::Clock> (monotonic time, cached)

=item * L<Linux::Event::Timer> (timerfd wrapper)

=item * L<Linux::Event::Scheduler> (pure deadline heap in nanoseconds)

=item * A backend mechanism (currently epoll via L<Linux::Event::Backend::Epoll>)

=back

The loop owns policy (scheduling, timer rearm, dispatch ordering). The backend
owns readiness waiting and dispatch mechanism.

=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

This API is a developer release and may change without notice.

=head1 TIMERS

Timers are scheduled using seconds (float allowed). Internally, the scheduler
stores deadlines in nanoseconds.

=head2 after($seconds, $cb) -> $id

Schedule C<$cb> to run after C<$seconds>. The callback is invoked as:

  $cb->($loop)

=head2 at($deadline_seconds, $cb) -> $id

Schedule C<$cb> for an absolute monotonic deadline in seconds (same timebase as
C<< $loop->clock->now_ns >>).

=head2 cancel($id) -> $bool

Cancel a scheduled timer.

=head1 WATCHERS

=head2 watch($fh, %spec) -> Linux::Event::Watcher

Create a mutable watcher for a filehandle. Interest is inferred from installed
handlers and enable/disable state.

Supported keys in C<%spec>:

=over 4

=item * C<read> - coderef (optional)

=item * C<write> - coderef (optional)

=item * C<data> - user data (optional). Use this to avoid closure captures.

=item * C<edge_triggered> - boolean (optional, advanced). Defaults to false.

=item * C<oneshot> - boolean (optional, advanced). Defaults to false.

=back

Handlers are invoked as:

  read  => sub ($loop, $fh, $watcher) { ... }
  write => sub ($loop, $fh, $watcher) { ... }

The watcher can be modified later using its methods (enable/disable write, swap
handlers, cancel, etc.).

=head1 LOOP CONTROL

=head2 run

Run until stopped.

=head2 run_once($timeout_s=undef)

Run a single wait/dispatch cycle.

=head2 stop

Stop a running loop.

=head1 REPOSITORY

The project repository is hosted on GitHub:

L<https://github.com/haxmeister/perl-linux-event>

=cut
