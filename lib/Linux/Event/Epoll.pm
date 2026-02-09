package Linux::Event::Epoll;
# ABSTRACT: Minimal epoll wrapper for Linux::Event (fd watchers + wait)
# VERSION: 0.001

use v5.36;
use strict;
use warnings;

use Carp qw(croak);

BEGIN {
  eval {
    require Linux::FD::Epoll;
    Linux::FD::Epoll->import(qw(
      epoll_create1
      epoll_ctl
      epoll_wait
      EPOLL_CTL_ADD
      EPOLL_CTL_MOD
      EPOLL_CTL_DEL
      EPOLLIN
      EPOLLOUT
      EPOLLERR
      EPOLLHUP
      EPOLLRDHUP
      EPOLLET
    ));
    1;
  } or do {
    my $e = $@ || "unknown error";
    die "Linux::Event::Epoll requires Linux::FD::Epoll (load failed: $e)";
  };
}

sub IN     () { EPOLLIN }
sub OUT    () { EPOLLOUT }
sub ERR    () { EPOLLERR }
sub HUP    () { EPOLLHUP }
sub RDHUP  () { EPOLLRDHUP }

sub new ($class, %args) {
  my $edge = delete $args{edge};
  my $size = delete $args{maxevents};

  croak "unknown args: " . join(", ", sort keys %args) if %args;

  $edge = $edge ? 1 : 0;
  $size = defined($size) ? int($size) : 256;
  croak "maxevents must be >= 1" if $size < 1;

  my $epfd = epoll_create1(0);
  croak "epoll_create1 failed: $!" if !$epfd || $epfd < 0;

  my $self = bless {
    epfd      => $epfd,
    edge      => $edge,
    maxevents => $size,
    w         => {},  # fd -> watcher
  }, $class;

  return $self;
}

sub fd ($self) { return $self->{epfd} }

sub edge ($self) { return $self->{edge} ? 1 : 0 }

sub add_fd ($self, $fd, $mask, $cb, %opt) {
  croak "fd is required" if !defined $fd;
  $fd = int($fd);
  croak "fd must be >= 0" if $fd < 0;

  croak "mask is required" if !defined $mask;
  $mask = int($mask);

  croak "cb is required" if !defined $cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

  croak "fd already registered: $fd" if exists $self->{w}{$fd};

  $mask |= EPOLLET if $self->{edge};
  my $ev = { events => $mask, data => $fd };

  epoll_ctl($self->{epfd}, EPOLL_CTL_ADD, $fd, $ev)
    or croak "epoll_ctl(ADD, fd=$fd) failed: $!";

  $self->{w}{$fd} = {
    mask => $mask,
    cb   => $cb,
    fh   => $opt{fh},
    tag  => $opt{tag},
  };

  return $fd;
}

sub add_fh ($self, $fh, $mask, $cb, %opt) {
  croak "fh is required" if !$fh;
  my $fd = fileno($fh);
  croak "fh has no fileno" if !defined $fd;

  $opt{fh} //= $fh;
  return $self->add_fd($fd, $mask, $cb, %opt);
}

sub mod_fd ($self, $fd, $mask) {
  croak "fd is required" if !defined $fd;
  $fd = int($fd);

  croak "fd not registered: $fd" if !exists $self->{w}{$fd};
  croak "mask is required" if !defined $mask;

  $mask = int($mask);
  $mask |= EPOLLET if $self->{edge};

  my $ev = { events => $mask, data => $fd };

  epoll_ctl($self->{epfd}, EPOLL_CTL_MOD, $fd, $ev)
    or croak "epoll_ctl(MOD, fd=$fd) failed: $!";

  $self->{w}{$fd}{mask} = $mask;
  return 1;
}

sub del_fd ($self, $fd) {
  croak "fd is required" if !defined $fd;
  $fd = int($fd);

  return 0 if !exists $self->{w}{$fd};

  my $ev = { events => 0, data => $fd };

  epoll_ctl($self->{epfd}, EPOLL_CTL_DEL, $fd, $ev)
    or croak "epoll_ctl(DEL, fd=$fd) failed: $!";

  delete $self->{w}{$fd};
  return 1;
}

sub del_fh ($self, $fh) {
  croak "fh is required" if !$fh;
  my $fd = fileno($fh);
  croak "fh has no fileno" if !defined $fd;
  return $self->del_fd($fd);
}

sub watcher ($self, $fd) {
  return $self->{w}{int($fd)};
}

sub wait ($self, $timeout_ms = -1) {
  $timeout_ms = int($timeout_ms);

  my @ev = epoll_wait($self->{epfd}, $self->{maxevents}, $timeout_ms);

  my @out;
  for my $e (@ev) {
    my $fd   = int($e->{data});
    my $mask = int($e->{events});
    push @out, [$fd, $mask];
  }

  return @out;
}

sub dispatch ($self, @events) {
  for my $ev (@events) {
    my ($fd, $mask) = @$ev;

    my $w = $self->{w}{$fd};
    next if !$w;

    my $cb = $w->{cb};
    next if !$cb;

    $cb->($self, $fd, $mask, $w->{fh}, $w->{tag});
  }

  return;
}

sub close ($self) {
  return 0 if !$self->{epfd};

  require POSIX;
  POSIX::close($self->{epfd});
  $self->{epfd} = 0;
  $self->{w} = {};
  return 1;
}

sub DESTROY ($self) {
  $self->close if $self->{epfd};
  return;
}

1;

__END__

=head1 NAME

Linux::Event::Epoll - Minimal epoll wrapper for Linux::Event (fd watchers + wait)

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::Epoll;

  my $ep = Linux::Event::Epoll->new(maxevents => 512);

  $ep->add_fh(\*STDIN, Linux::Event::Epoll::IN, sub ($ep, $fd, $mask, $fh, $tag) {
    my $line = <$fh>;
    warn "stdin: $line";
  });

  while (1) {
    my @ev = $ep->wait(1000);
    $ep->dispatch(@ev);
  }

=head1 DESCRIPTION

A small, loop-friendly epoll wrapper intended for use by C<Linux::Event::Loop>.

Default mode is level-triggered. Edge-triggered mode can be enabled via
C<< new(edge => 1) >>.

=head1 CONSTRUCTOR

=head2 new(%args)

  my $ep = Linux::Event::Epoll->new(
    edge      => 0,
    maxevents => 256,
  );

=head1 METHODS

=head2 fd()

=head2 add_fd($fd, $mask, $cb, %opt)

Callback signature:

  sub ($epoll, $fd, $mask, $fh, $tag) { ... }

=head2 add_fh($fh, $mask, $cb, %opt)

=head2 mod_fd($fd, $mask)

=head2 del_fd($fd)

=head2 del_fh($fh)

=head2 watcher($fd)

=head2 wait($timeout_ms)

Returns:

  [ $fd, $mask ]

=head2 dispatch(@events)

=head2 close()

=head1 CONSTANTS

  Linux::Event::Epoll::IN
  Linux::Event::Epoll::OUT
  Linux::Event::Epoll::ERR
  Linux::Event::Epoll::HUP
  Linux::Event::Epoll::RDHUP

=cut
