package Linux::Event::Backend::Epoll;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.002_001';

use Carp qw(croak);
use Linux::Epoll;

use constant READABLE => 0x01;
use constant WRITABLE => 0x02;
use constant PRIO     => 0x04;
use constant RDHUP    => 0x08;
use constant ET       => 0x10;
use constant ONESHOT  => 0x20;
use constant ERR      => 0x40;
use constant HUP      => 0x80;

sub new ($class, %args) {
  # Defaults (optional): allow forcing ET/ONESHOT for all watches.
  # Note: public API uses edge_triggered => 1 on Watcher; these are backend-level defaults.
  my $edge    = delete $args{edge};
  my $oneshot = delete $args{oneshot};
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  my $ep = Linux::Epoll->new;

  return bless {
    ep      => $ep,
    watch   => {},  # fd -> watcher info
    edge    => $edge ? 1 : 0,
    oneshot => $oneshot ? 1 : 0,
  }, $class;
}

sub watch ($self, $fh, $mask, $cb, %opt) {
  croak "fh is required" if !$fh;
  croak "mask is required" if !defined $mask;
  croak "cb is required" if !$cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

  my $fd = fileno($fh);
  croak "fh has no fileno" if !defined $fd;
  $fd = int($fd);

  croak "fd already watched: $fd" if exists $self->{watch}{$fd};

  my $events = _mask_to_events($self, $mask);

  my $loop = $opt{_loop};
  my $tag  = $opt{tag};

  $self->{ep}->add($fh, $events, sub ($ev) {
    my $m = _events_to_mask($ev);
    $cb->($loop, $fh, $fd, $m, $tag);
  });

  $self->{watch}{$fd} = {
    fh   => $fh,
    cb   => $cb,
    mask => int($mask),
    tag  => $tag,
    loop => $loop,
  };

  return $fd;
}

sub modify ($self, $fh_or_fd, $mask, %opt) {
  croak "mask is required" if !defined $mask;

  my $fd = ref($fh_or_fd) ? fileno($fh_or_fd) : $fh_or_fd;
  return 0 if !defined $fd;
  $fd = int($fd);

  my $w = $self->{watch}{$fd} or return 0;

  # Allow caller to override loop/tag at modify-time (Loop passes _loop).
  my $loop = exists $opt{_loop} ? $opt{_loop} : $w->{loop};
  my $tag  = exists $opt{tag}   ? $opt{tag}   : $w->{tag};

  $w->{loop} = $loop;
  $w->{tag}  = $tag;
  $w->{mask} = int($mask);

  my $events = _mask_to_events($self, $mask);

  # If Linux::Epoll supports modify, use it; otherwise fallback to delete+add.
  # This keeps correctness even on older Linux::Epoll versions.
  if ($self->{ep}->can('modify')) {
    $self->{ep}->modify($w->{fh}, $events, sub ($ev) {
      my $m = _events_to_mask($ev);
      $w->{cb}->($loop, $w->{fh}, $fd, $m, $tag);
    });
    return 1;
  }

  # Fallback path: delete and re-add with new event set.
  $self->{ep}->delete($w->{fh});
  $self->{ep}->add($w->{fh}, $events, sub ($ev) {
    my $m = _events_to_mask($ev);
    $w->{cb}->($loop, $w->{fh}, $fd, $m, $tag);
  });

  return 1;
}

sub unwatch ($self, $fh_or_fd) {
  my $fd = ref($fh_or_fd) ? fileno($fh_or_fd) : $fh_or_fd;
  return 0 if !defined $fd;
  $fd = int($fd);

  my $w = $self->{watch}{$fd} or return 0;
  $self->{ep}->delete($w->{fh});
  delete $self->{watch}{$fd};
  return 1;
}

sub run_once ($self, $loop, $timeout_s = undef) {
  my $max = 256;
  my $ret = $self->{ep}->wait($max, $timeout_s);
  return 0 if !defined $ret;
  return 0;
}

sub _mask_to_events ($self, $mask) {
  $mask = int($mask);
  my @ev;

  push @ev, 'in'    if ($mask & READABLE);
  push @ev, 'out'   if ($mask & WRITABLE);
  push @ev, 'prio'  if ($mask & PRIO);
  push @ev, 'rdhup' if ($mask & RDHUP);

  my %have = map { $_ => 1 } @ev;
  push @ev, 'et'      if (($mask & ET)      || ($self->{edge}    && !$have{et}));
  push @ev, 'oneshot' if (($mask & ONESHOT) || ($self->{oneshot} && !$have{oneshot}));

  return \@ev;
}

sub _events_to_mask ($ev) {
  my $m = 0;
  $m |= READABLE if $ev->{in};
  $m |= WRITABLE if $ev->{out};
  $m |= PRIO     if $ev->{prio};
  $m |= RDHUP    if $ev->{rdhup};
  $m |= ET       if $ev->{et};
  $m |= ONESHOT  if $ev->{oneshot};
  $m |= ERR      if $ev->{err};
  $m |= HUP      if $ev->{hup};
  return $m;
}

1;

__END__

=head1 NAME

Linux::Event::Backend::Epoll - Epoll backend for Linux::Event::Loop (via Linux::Epoll)

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::Backend::Epoll;

  my $be = Linux::Event::Backend::Epoll->new;

  my $fd = $be->watch($fh, $mask, sub ($loop, $fh, $fd, $mask, $tag) {
    ...
  }, _loop => $loop, tag => $tag);

  $be->modify($fh, $new_mask, _loop => $loop);

  $be->unwatch($fh);

=head1 DESCRIPTION

Thin adapter over L<Linux::Epoll> used as the mechanism layer for
L<Linux::Event::Loop>.

The backend is responsible for:

=over 4

=item * Registering filehandles with epoll

=item * Waiting for readiness

=item * Converting Linux::Epoll events into an integer mask

=item * Dispatching to the callback contract expected by the loop

=back

=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

The API is not yet considered stable and may change without notice.

=head1 METHODS

=head2 new(%args)

Optional args:

=over 4

=item * C<edge> - if true, defaults registrations to edge-triggered

=item * C<oneshot> - if true, defaults registrations to one-shot

=back

=head2 watch($fh, $mask, $cb, %opt) -> $fd

Register a filehandle. C<$cb> is invoked as:

  $cb->($loop, $fh, $fd, $mask, $tag)

Options:

=over 4

=item * C<_loop> - loop reference passed through to callback

=item * C<tag> - arbitrary user value passed through to callback

=back

=head2 modify($fh_or_fd, $mask, %opt) -> $bool

Update the epoll interest set for an already-watched file descriptor.

Uses C<Linux::Epoll->modify> if available, otherwise falls back to a safe
delete+add re-registration.

=head2 unwatch($fh_or_fd) -> $bool

Unregister a file descriptor or filehandle.

=head2 run_once($loop, $timeout_s=undef)

Perform one epoll wait/dispatch cycle.

=head1 SEE ALSO

L<Linux::Event>, L<Linux::Event::Loop>, L<Linux::Epoll>

=cut
