package Linux::Event::Backend::Epoll;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001_001';

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

sub watch_fh ($self, $fh, $mask, $cb, %opt) {
  croak "fh is required" if !$fh;
  croak "mask is required" if !defined $mask;
  croak "cb is required" if !$cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

  my $fd = fileno($fh);
  croak "fh has no fileno" if !defined $fd;
  croak "fd already watched: $fd" if exists $self->{watch}{$fd};

  my $events = _mask_to_events($self, $mask);

  $self->{ep}->add($fh, $events, sub ($ev) {
    my $loop = $opt{_loop};
    my $tag  = $opt{tag};
    my $m    = _events_to_mask($ev);
    $cb->($loop, $fh, $fd, $m, $tag);
  });

  $self->{watch}{$fd} = {
    fh   => $fh,
    cb   => $cb,
    mask => int($mask),
    tag  => $opt{tag},
  };

  return $fd;
}

sub unwatch_fh ($self, $fh_or_fd) {
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

=head1 DESCRIPTION

Thin adapter over L<Linux::Epoll>.

=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

The API is not yet considered stable and may change without notice.

=head1 METHODS

=head2 new(%args)

=head2 watch_fh($fh, $mask, $cb, %opt) -> $fd

=head2 unwatch_fh($fh_or_fd) -> $bool

=head2 run_once($loop, $timeout_s=undef)

=cut
