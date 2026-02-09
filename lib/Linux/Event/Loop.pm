package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001_001';

use Carp qw(croak);

use Linux::Event::Clock;
use Linux::Event::Timer;
use Linux::Event::Scheduler;

use Linux::Event::Backend::Epoll;

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
  for my $m (qw(watch_fh unwatch_fh run_once)) {
    croak "backend missing method '$m'" if !$backend->can($m);
  }

  my $sched = Linux::Event::Scheduler->new(clock => $clock);

  my $self = bless {
    clock   => $clock,
    timer   => $timer,
    backend => $backend,
    sched   => $sched,
    running => 0,
    _timer_fd => undef,
  }, $class;

  my $t_fh = $timer->fh;
  my $t_fd = fileno($t_fh);
  croak "timer fh has no fileno" if !defined $t_fd;

  $self->{_timer_fd} = $backend->watch_fh(
    $t_fh,
    READABLE,
    sub ($loop, $fh, $fd, $mask, $tag) {
      $timer->read_ticks;
      $clock->tick;
      $loop->_dispatch_due;
      $loop->_rearm_timer;
    },
    tag   => 'timerfd',
    _loop => $self,
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

sub at_ns ($self, $deadline_ns, $cb) {
  my $id = $self->{sched}->at_ns($deadline_ns, $cb);
  $self->_rearm_timer;
  return $id;
}

sub after_ns ($self, $delta_ns, $cb) {
  my $id = $self->{sched}->after_ns($delta_ns, $cb);
  $self->_rearm_timer;
  return $id;
}

sub after_us ($self, $delta_us, $cb) {
  my $id = $self->{sched}->after_us($delta_us, $cb);
  $self->_rearm_timer;
  return $id;
}

sub after_ms ($self, $delta_ms, $cb) {
  my $id = $self->{sched}->after_ms($delta_ms, $cb);
  $self->_rearm_timer;
  return $id;
}

sub cancel ($self, $id) {
  my $ok = $self->{sched}->cancel($id);
  $self->_rearm_timer if $ok;
  return $ok;
}

sub watch_fh ($self, $fh, $mask, $cb, %opt) {
  $opt{_loop} = $self;
  return $self->{backend}->watch_fh($fh, $mask, $cb, %opt);
}

sub unwatch_fh ($self, $fh_or_fd) {
  return $self->{backend}->unwatch_fh($fh_or_fd);
}

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
    # (Perl signatures will die on extra args.)
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

=head1 DESCRIPTION

Backend-agnostic loop. All readiness waiting and dispatch is delegated to a
backend object (currently epoll via L<Linux::Event::Backend::Epoll>).

=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

The API is not yet considered stable and may change without notice.

=head1 METHODS

=head2 new(%args)

=head2 after_ms / after_us / after_ns / at_ns

=head2 cancel($id)

=head2 watch_fh($fh, $mask, $cb, %opt)

=head2 run / run_once / stop

=head1 REPOSITORY

The project repository is hosted on GitHub:

L<https://github.com/haxmeister/perl-linux-event>


=cut
