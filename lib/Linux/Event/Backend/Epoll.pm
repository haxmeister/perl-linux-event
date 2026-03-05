package Linux::Event::Backend::Epoll;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

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
  # Optional backend defaults (not part of Loop's public API):
  my $edge    = delete $args{edge};
  my $oneshot = delete $args{oneshot};
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  my $ep = Linux::Epoll->new;

  return bless {
    ep      => $ep,
    watch   => {},  # fd -> { fh, cb, mask, tag, loop }
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

  my $loop = exists $opt{_loop} ? $opt{_loop} : $w->{loop};
  my $tag  = exists $opt{tag}   ? $opt{tag}   : $w->{tag};

  $w->{loop} = $loop;
  $w->{tag}  = $tag;

  my $new_mask = int($mask);
  my $old_mask = int($w->{mask});

  $w->{mask} = $new_mask;

  my $events = _mask_to_events($self, $new_mask);


  # EPOLLONESHOT rearm:
  # Rearming must be possible from inside a callback. Linux::Epoll's callback
  # dispatch is not guaranteed to be safe against a delete+add cycle performed
  # re-entrantly from within the callback. So for oneshot, prefer a real MOD.
  #
  # We still need to ensure a MOD happens even if the effective event set is
  # unchanged; Linux::Epoll->modify performs epoll_ctl(MOD) and does not elide
  # "no-op" masks.
  my $need_oneshot = (($new_mask & ONESHOT) || ($old_mask & ONESHOT) || $self->{oneshot}) ? 1 : 0;

  if ($self->{ep}->can('modify')) {
    $self->{ep}->modify($w->{fh}, $events, sub ($ev) {
      my $m = _events_to_mask($ev);
      $w->{cb}->($loop, $w->{fh}, $fd, $m, $tag);
    });
    return 1;
  }

  # Fallback: delete and re-add
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

  # Linux::Epoll->wait($number, $timeout) uses fractional seconds.
  # Keep $timeout_s in seconds (possibly fractional). undef => block, 0 => poll.
  my $ret = $self->{ep}->wait($max, $timeout_s);

  return 0 if !defined $ret;
  return $ret;
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

Linux::Event::Backend::Epoll - epoll backend for Linux::Event

=head1 DESCRIPTION

Internal backend used by L<Linux::Event::Loop>. Not intended for direct use.

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=head1 SYNOPSIS

  # Internal. See L<Linux::Event::Loop>.

=head1 VERSION

This document describes Linux::Event::Backend::Epoll version 0.006.
package Linux::Event::Backend;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

1;

__END__

=head1 NAME

Linux::Event::Backend - Backend contract for Linux::Event::Loop

=head1 DESCRIPTION

This module documents the minimal backend interface expected by
L<Linux::Event::Loop>. Backends are intentionally duck-typed.

The loop owns scheduling policy (clock/timer/scheduler). The backend owns the
wait/dispatch mechanism (epoll now, io_uring later).

=head1 STATUS

As of version 0.006, the backend contract described here is considered stable.
New optional methods may be added in future releases, but required methods and callback ABI
will not change.

=head1 REQUIRED METHODS

=head2 new(%args)

Create the backend instance.

=head2 watch($fh, $mask, $cb, %opt) -> $fd

Register a filehandle for readiness notifications.

Callback signature (standardized by this project):

  $cb->($loop, $fh, $fd, $mask, $tag);

Where:

=over 4

=item * C<$loop> is the L<Linux::Event::Loop> instance

=item * C<$fh> is the watched filehandle

=item * C<$fd> is the integer file descriptor

=item * C<$mask> is an integer readiness mask (backend-defined bit layout,
standardized within this project)

=item * C<$tag> is an arbitrary user value (optional; may be undef)

=back

Backends may accept additional options in C<%opt>. This distribution uses:

=over 4

=item * C<_loop> - the loop reference to pass through to the callback

=item * C<tag> - the tag value to pass through to the callback

=back

=head2 unwatch($fh_or_fd) -> $bool

Remove a watcher by filehandle or file descriptor.

=head2 run_once($loop, $timeout_s=undef) -> $n

Block until events occur (or timeout) and dispatch them.

Return value is backend-defined; for now callers should not rely on it.

=head1 OPTIONAL METHODS

=head2 modify($fh_or_fd, $mask, %opt) -> $bool

Update an existing watcher registration (e.g. add/remove interest in writable).
If not implemented, the loop may fall back to unwatch+watch.

=head1 SEE ALSO

L<Linux::Event::Listen> - nonblocking bind + accept

L<Linux::Event::Connect> - nonblocking outbound connect

L<Linux::Event::Stream> - buffered I/O and backpressure for sockets

L<Linux::Event::Fork> - asynchronous child process management

L<Linux::Event::Clock> - high resolution monotonic clock utilities

=head1 SYNOPSIS

  # Internal. See L<Linux::Event::Loop>.

=head1 VERSION

This document describes Linux::Event::Backend version 0.006.

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut


=cut
