package Linux::Event::Backend::Epoll;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.003_001';

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
  $w->{mask} = int($mask);

  my $events = _mask_to_events($self, $mask);

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

=cut
