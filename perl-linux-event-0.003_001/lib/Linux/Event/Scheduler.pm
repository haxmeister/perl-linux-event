package Linux::Event::Scheduler;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.003_001';

use Carp qw(croak);

sub new ($class, %args) {
  my $clock = delete $args{clock};
  croak "clock is required" if !$clock;
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  for my $m (qw(now_ns deadline_in_ns)) {
    croak "clock missing method '$m'" if !$clock->can($m);
  }

  return bless {
    clock     => $clock,
    d_ns      => [],
    cb        => [],
    id        => [],
    size      => 0,
    next_id   => 1,
    live      => {},
    cancelled => 0,
  }, $class;
}

sub at_ns ($self, $deadline_ns, $cb) {
  croak "deadline_ns is required" if !defined $deadline_ns;
  croak "callback is required"    if !defined $cb;
  croak "callback must be a coderef" if ref($cb) ne 'CODE';

  $deadline_ns = int($deadline_ns);

  my $id = $self->{next_id}++;
  $self->{live}{$id} = 1;

  my $i = $self->{size}++;
  $self->{d_ns}[$i] = $deadline_ns;
  $self->{cb}[$i]   = $cb;
  $self->{id}[$i]   = $id;

  _sift_up($self, $i);
  return $id;
}

sub after_ns ($self, $delta_ns, $cb) {
  croak "delta_ns is required" if !defined $delta_ns;
  $delta_ns = int($delta_ns);
  my $deadline = $self->{clock}->deadline_in_ns($delta_ns);
  return $self->at_ns($deadline, $cb);
}

sub after_us ($self, $delta_us, $cb) {
  croak "delta_us is required" if !defined $delta_us;
  $delta_us = int($delta_us);
  return $self->after_ns($delta_us * 1_000, $cb);
}

sub after_ms ($self, $delta_ms, $cb) {
  croak "delta_ms is required" if !defined $delta_ms;
  $delta_ms = int($delta_ms);
  return $self->after_ns($delta_ms * 1_000_000, $cb);
}

sub cancel ($self, $id) {
  return 0 if !defined $id;
  return 0 if !$self->{live}{$id};
  delete $self->{live}{$id};
  $self->{cancelled}++;
  return 1;
}

sub count ($self) {
  return scalar keys $self->{live}->%*;
}

sub next_deadline_ns ($self) {
  _discard_cancelled_root($self);
  return undef if $self->{size} == 0;
  return $self->{d_ns}[0];
}

sub pop_expired ($self) {
  my $now = $self->{clock}->now_ns;

  my @out;
  while (1) {
    _discard_cancelled_root($self);
    last if $self->{size} == 0;

    my $d = $self->{d_ns}[0];
    last if $d > $now;

    my ($id, $cb, $deadline) = _pop_root($self);

    next if !$self->{live}{$id};
    delete $self->{live}{$id};

    push @out, [$id, $cb, $deadline];
  }

  return @out;
}

sub _discard_cancelled_root ($self) {
  while ($self->{size} > 0) {
    my $id = $self->{id}[0];
    last if $self->{live}{$id};
    _pop_root($self);
    $self->{cancelled}-- if $self->{cancelled} > 0;
  }
  return;
}

sub _pop_root ($self) {
  my $size = $self->{size};
  croak "pop on empty heap" if $size <= 0;

  my $root_deadline = $self->{d_ns}[0];
  my $root_cb       = $self->{cb}[0];
  my $root_id       = $self->{id}[0];

  my $last = --$self->{size};
  if ($last > 0) {
    $self->{d_ns}[0] = $self->{d_ns}[$last];
    $self->{cb}[0]   = $self->{cb}[$last];
    $self->{id}[0]   = $self->{id}[$last];
    _sift_down($self, 0);
  }

  $self->{d_ns}[$last] = undef;
  $self->{cb}[$last]   = undef;
  $self->{id}[$last]   = undef;

  return ($root_id, $root_cb, $root_deadline);
}

sub _sift_up ($self, $i) {
  my $d_ns = $self->{d_ns};
  my $cb   = $self->{cb};
  my $id   = $self->{id};

  while ($i > 0) {
    my $p = int(($i - 1) / 2);
    last if $d_ns->[$p] <= $d_ns->[$i];

    ($d_ns->[$i], $d_ns->[$p]) = ($d_ns->[$p], $d_ns->[$i]);
    ($cb->[$i],   $cb->[$p])   = ($cb->[$p],   $cb->[$i]);
    ($id->[$i],   $id->[$p])   = ($id->[$p],   $id->[$i]);

    $i = $p;
  }

  return;
}

sub _sift_down ($self, $i) {
  my $d_ns = $self->{d_ns};
  my $cb   = $self->{cb};
  my $id   = $self->{id};
  my $n    = $self->{size};

  while (1) {
    my $l = $i * 2 + 1;
    last if $l >= $n;

    my $r = $l + 1;
    my $m = ($r < $n && $d_ns->[$r] < $d_ns->[$l]) ? $r : $l;

    last if $d_ns->[$i] <= $d_ns->[$m];

    ($d_ns->[$i], $d_ns->[$m]) = ($d_ns->[$m], $d_ns->[$i]);
    ($cb->[$i],   $cb->[$m])   = ($cb->[$m],   $cb->[$i]);
    ($id->[$i],   $id->[$m])   = ($id->[$m],   $id->[$i]);

    $i = $m;
  }

  return;
}

1;

__END__

=head1 NAME

Linux::Event::Scheduler - Deadline scheduler (nanoseconds) for Linux::Event

=head1 SYNOPSIS

  use Linux::Event::Clock;
  use Linux::Event::Scheduler;

  my $clock = Linux::Event::Clock->new(clock => 'monotonic');
  my $sched = Linux::Event::Scheduler->new(clock => $clock);

  $clock->tick;
  $sched->after_ms(25, sub { say "fired" });

=head1 DESCRIPTION

Stores callbacks keyed by absolute deadlines in nanoseconds.

Pairs with:

=over 4

=item * L<Linux::Event::Clock> for cached monotonic time and deadline math

=item * L<Linux::Event::Timer> (timerfd) for kernel wakeups in an event loop

=back

This module does not block and does not manage file descriptors.

The scheduler stores callbacks, but the event loop decides the callback invocation signature.


=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

The API is not yet considered stable and may change without notice.

=head1 CLOCK CONTRACT

Constructor accepts a duck-typed C<clock> object which must implement:

=over 4

=item * C<now_ns>

=item * C<deadline_in_ns>

=back

The clock is expected to be ticked externally by the loop.

=head1 METHODS

=head2 new(clock => $clock)

=head2 at_ns($deadline_ns, $cb) -> $id

=head2 after_ns($delta_ns, $cb) -> $id

=head2 after_us($delta_us, $cb) -> $id

=head2 after_ms($delta_ms, $cb) -> $id

=head2 cancel($id) -> $bool

=head2 next_deadline_ns() -> $deadline_ns|undef

=head2 pop_expired() -> @items

Each item is:

  [ $id, $coderef, $deadline_ns ]

=head2 count() -> $n

=cut
