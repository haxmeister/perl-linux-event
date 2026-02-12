package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.003_001';

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

  croak "fd already watched: $fd" if exists $self->{_watchers}{$fd};

  my $w = Linux::Event::Watcher->new(
    loop           => $self,
    fh             => $fh,
    fd             => $fd,
    read           => $read,
    write          => $write,
    error          => $error,
    data           => $data,
    edge_triggered => $edge_triggered ? 1 : 0,
    oneshot        => $oneshot ? 1 : 0,
  );

  # Backend callback dispatch:
  # backend calls this with ($loop,$fh,$fd,$mask,$tag). We map mask->handlers.
  
my $dispatch = sub ($loop, $fh, $fd2, $mask, $tag) {
  my $ww = $loop->{_watchers}{$fd2} or return;

  # Frozen dispatch contract:
  # - ERR: call error handler first if installed+enabled; otherwise treat as read+write.
  # - HUP: also triggers read (EOF detection).
  my $read_trig  = ($mask & READABLE) ? 1 : 0;
  my $write_trig = ($mask & WRITABLE) ? 1 : 0;

  if ($mask & ERR) {
    if ($ww->{error_cb} && $ww->{error_enabled}) {
      $ww->{error_cb}->($loop, $fh, $ww);
      return;
    }
    $read_trig  = 1;
    $write_trig = 1;
  }

  $read_trig = 1 if ($mask & HUP);

  if ($read_trig && $ww->{read_cb} && $ww->{read_enabled}) {
    $ww->{read_cb}->($loop, $fh, $ww);
  }
  if ($write_trig && $ww->{write_cb} && $ww->{write_enabled}) {
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


# -- Listening sockets ----------------------------------------------------

sub listen ($self, %spec) {
  my $type = delete $spec{type};
  croak "type is required" if !defined $type;

  # Listener watcher spec (aligned with watch()):
  my $accept_cb = delete $spec{read};
  croak "read callback is required" if !$accept_cb || ref($accept_cb) ne 'CODE';

  croak "write is not valid for listening sockets" if exists $spec{write};

  my $error_cb = delete $spec{error};
  if (defined $error_cb && ref($error_cb) ne 'CODE') {
    croak "error must be a coderef or undef";
  }

  my $data = delete $spec{data};

  my $edge_triggered = delete $spec{edge_triggered} ? 1 : 0;
  my $oneshot        = delete $spec{oneshot}        ? 1 : 0;

  # Socket options / policy (frozen defaults)
  my $reuseaddr  = exists $spec{reuseaddr}  ? (delete $spec{reuseaddr}  ? 1 : 0) : 1;
  my $reuseport  = exists $spec{reuseport}  ? (delete $spec{reuseport}  ? 1 : 0) : 0;
  my $max_accept = exists $spec{max_accept} ? int(delete $spec{max_accept})       : 64;
  $max_accept = 1 if $max_accept < 1;

  my $backlog = exists $spec{backlog} ? int(delete $spec{backlog}) : 0;
  $backlog = Socket::SOMAXCONN() if $backlog <= 0;

  my $fh;

  require Socket;
  require Fcntl;

  if ($type eq 'tcp4') {
    my $host = exists $spec{host} ? delete $spec{host} : '0.0.0.0';
    my $port = delete $spec{port};
    croak "port is required" if !defined $port;

    socket($fh, Socket::AF_INET(), Socket::SOCK_STREAM(), 0) or croak "socket: $!";

    if ($reuseaddr) {
      setsockopt($fh, Socket::SOL_SOCKET(), Socket::SO_REUSEADDR(), pack("l", 1))
        or croak "setsockopt(SO_REUSEADDR): $!";
    }
    if ($reuseport) {
      setsockopt($fh, Socket::SOL_SOCKET(), Socket::SO_REUSEPORT(), pack("l", 1))
        or croak "setsockopt(SO_REUSEPORT): $!";
    }

    my $addr = Socket::sockaddr_in($port, Socket::inet_aton($host));
    bind($fh, $addr) or croak "bind: $!";
    listen($fh, $backlog) or croak "listen: $!";
  }
  elsif ($type eq 'tcp6') {
    my $host = exists $spec{host} ? delete $spec{host} : '::';
    my $port = delete $spec{port};
    croak "port is required" if !defined $port;

    socket($fh, Socket::AF_INET6(), Socket::SOCK_STREAM(), 0) or croak "socket: $!";

    if ($reuseaddr) {
      setsockopt($fh, Socket::SOL_SOCKET(), Socket::SO_REUSEADDR(), pack("l", 1))
        or croak "setsockopt(SO_REUSEADDR): $!";
    }
    if ($reuseport) {
      setsockopt($fh, Socket::SOL_SOCKET(), Socket::SO_REUSEPORT(), pack("l", 1))
        or croak "setsockopt(SO_REUSEPORT): $!";
    }

    my $ip = Socket::inet_pton(Socket::AF_INET6(), $host);
    croak "inet_pton(AF_INET6) failed for host '$host'" if !$ip;
    my $addr = Socket::sockaddr_in6($port, $ip);
    bind($fh, $addr) or croak "bind: $!";
    listen($fh, $backlog) or croak "listen: $!";
  }
  elsif ($type eq 'unix') {
    my $path = delete $spec{path};
    croak "path is required" if !defined $path;

    my $do_unlink = delete $spec{unlink} ? 1 : 0;
    unlink $path if $do_unlink;

    socket($fh, Socket::AF_UNIX(), Socket::SOCK_STREAM(), 0) or croak "socket: $!";
    my $addr = Socket::sockaddr_un($path);
    bind($fh, $addr) or croak "bind: $!";
    listen($fh, $backlog) or croak "listen: $!";
  }
  else {
    croak "unknown listen type '$type'";
  }

  # nonblocking
  my $flags = fcntl($fh, Fcntl::F_GETFL(), 0);
  croak "fcntl(F_GETFL): $!" if !defined $flags;
  fcntl($fh, Fcntl::F_SETFL(), $flags | Fcntl::O_NONBLOCK()) or croak "fcntl(F_SETFL): $!";

  croak "unknown args: " . join(", ", sort keys %spec) if %spec;

  my $w;
  $w = $self->watch(
    $fh,
    read => sub ($loop, $server_fh, $ww) {

      my $count = 0;

      while (1) {
        last if $count >= $max_accept;

        my $client;
        if (!accept($client, $server_fh)) {
          last if $!{EAGAIN} || $!{EWOULDBLOCK};

          if ($error_cb) {
            $error_cb->($loop, $server_fh, $ww);
            return;
          }

          croak "accept: $!";
        }

        my $cflags = fcntl($client, Fcntl::F_GETFL(), 0);
        croak "fcntl(F_GETFL client): $!" if !defined $cflags;
        fcntl($client, Fcntl::F_SETFL(), $cflags | Fcntl::O_NONBLOCK()) or croak "fcntl(F_SETFL client): $!";

        # Invoke the accept callback with the accepted client socket as $fh.
        $accept_cb->($loop, $client, $ww);
        $count++;
      }

      return;
    },
    (defined $error_cb ? (error => $error_cb) : ()),
    data           => $data,
    edge_triggered => $edge_triggered,
    oneshot        => $oneshot,
  );

  return wantarray ? ($fh, $w) : $fh;
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

Linux::Event::Loop - Backend-agnostic Linux event loop (timers + epoll watchers)

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;

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

  $w->disable_write; # enable later when output buffered

  # Timers (seconds, float ok)
  $loop->after(0.250, sub ($loop) {
    warn "250ms elapsed\n";
  });

  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Loop> ties together:

=over 4

=item * L<Linux::Event::Clock> (monotonic time, cached)

=item * L<Linux::Event::Timer> (timerfd wrapper)

=item * L<Linux::Event::Scheduler> (deadline scheduler in nanoseconds)

=item * A backend mechanism (currently epoll via L<Linux::Event::Backend::Epoll>)

=back

The loop owns policy (timer scheduling and dispatch ordering). The backend owns
readiness waiting and low-level polling.

=head1 WATCHERS

=head2 watch($fh, %spec) -> Linux::Event::Watcher

Create a mutable watcher for a filehandle. Interest is inferred from installed
handlers and enable/disable state.

Supported keys in C<%spec>:

=over 4

=item * C<read> - coderef (optional)

=item * C<write> - coderef (optional)

=item * C<error> - coderef (optional). Called on EPOLLERR (see Dispatch).

=item * C<data> - user data (optional). Stored on the watcher to avoid closure captures.

=item * C<edge_triggered> - boolean (optional, advanced). Defaults to false.

=item * C<oneshot> - boolean (optional, advanced). Defaults to false.

=back

Handlers are invoked as:

  read  => sub ($loop, $fh, $watcher) { ... }
  write => sub ($loop, $fh, $watcher) { ... }
  error => sub ($loop, $fh, $watcher) { ... }

The watcher can be modified later using its methods (enable/disable write, swap
handlers, cancel, etc).

=head2 Dispatch contract

When the backend reports events for a file descriptor, the loop dispatches as:

=over 4

=item * If EPOLLERR is present and an C<error> handler is installed and enabled, call C<error> first and return.

=item * Otherwise EPOLLERR behaves like both readable and writable readiness (read+write may be invoked).

=item * EPOLLHUP also triggers C<read> readiness (EOF detection via read() returning 0).

=item * C<read> is invoked before C<write> when both are ready.

=back

The loop does not auto-close filehandles and does not auto-cancel watchers; user
code decides lifecycle (cancel then close is recommended).

=head1 LISTENING SOCKETS

=head2 listen(%spec) -> $socket
=head2 listen(%spec) -> ($socket, $watcher)

Create a nonblocking listening socket and register it with the loop. This is a
convenience wrapper around raw socket/bind/listen plus a watcher that drains
accept() in a bounded loop.

The listener uses the normal watcher key C<read> as the "accept callback".
Each accepted client socket is passed as C<$fh> to that callback.

Required keys:

=over 4

=item * C<type> - one of C<tcp4>, C<tcp6>, C<unix>

=item * C<read> - coderef, invoked for each accepted client socket

=back

Common keys:

=over 4

=item * C<host> - for tcp4/tcp6 (defaults: C<0.0.0.0> / C<::>)

=item * C<port> - for tcp4/tcp6 (required)

=item * C<path> - for unix (required)

=item * C<unlink> - for unix (optional). If true, unlink path before bind.

=item * C<reuseaddr> - boolean (default true)

=item * C<reuseport> - boolean (default false)

=item * C<max_accept> - integer (default 64). Bounds accept-drain per readiness event.

=item * C<backlog> - integer (default SOMAXCONN)

=item * C<error> - coderef (optional). If accept() fails with a non-EAGAIN error.

=item * C<data>, C<edge_triggered>, C<oneshot> - forwarded to the listener watcher.

=back

Callback signature:

  read => sub ($loop, $client_fh, $listener_watcher) {
    my $server_state = $listener_watcher->data;
    ...
  }

Notes:

=over 4

=item * C<write> is not valid for listening sockets and will croak.

=item * Accepted sockets are set to nonblocking before callback.

=item * This method returns the listening socket; the watcher is returned in list context.

=back

=head1 TIMERS

=head2 after($seconds, $cb) -> $id

Schedule C<$cb> to run after C<$seconds>. Fractions are allowed. Callback is
invoked as C<< $cb->($loop) >>.

=head2 at($deadline_seconds, $cb) -> $id

Schedule at an absolute monotonic deadline in seconds (same timebase as Clock).

=head2 cancel($id) -> bool

Cancel a scheduled timer by id.

=head1 VERSION

0.003_001

=head1 AUTHOR

Joshua S. Day and contributors.

=head1 LICENSE

Same terms as Perl itself.
