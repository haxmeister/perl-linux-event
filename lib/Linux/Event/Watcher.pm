package Linux::Event::Watcher;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

use Carp qw(croak);
use Scalar::Util qw(weaken);

# NOTE:
# This object is intentionally lightweight. It is a handle and a data container.
# The Loop owns policy and backend interactions; Watcher methods delegate into Loop.

sub new ($class, %args) {
  my $loop = delete $args{loop};
  my $fh   = delete $args{fh};
  my $fd   = delete $args{fd};

  my $read  = delete $args{read};
  my $write = delete $args{write};
  my $error = delete $args{error};

  my $data          = delete $args{data};
  my $edge_triggered = delete $args{edge_triggered};
  my $oneshot        = delete $args{oneshot};

  croak "unknown args: " . join(", ", sort keys %args) if %args;

  croak "loop is required" if !$loop;
  croak "fh is required"   if !$fh;
  croak "fd is required"   if !defined $fd;

  if (defined $read && ref($read) ne 'CODE') {
    croak "read must be a coderef or undef";
  }
  if (defined $write && ref($write) ne 'CODE') {
    croak "write must be a coderef or undef";
  }
  if (defined $error && ref($error) ne 'CODE') {
    croak "error must be a coderef or undef";
  }

  
  # Store a weak reference to the filehandle to avoid ownership and to detect closes.
  # If the user drops/closes the handle, the weak ref becomes undef and dispatch will auto-purge.
  weaken($fh) if ref($fh);

# Default enablement: if a handler exists, it's enabled.
  my $read_enabled  = $read  ? 1 : 0;
  my $write_enabled = $write ? 1 : 0;
  my $error_enabled = $error ? 1 : 0;

  return bless {
    loop  => $loop,
    fh    => $fh,
    fd    => int($fd),

    data  => $data,

    read_cb  => $read,
    write_cb => $write,
    error_cb => $error,

    read_enabled  => $read_enabled,
    write_enabled => $write_enabled,
    error_enabled => $error_enabled,

    edge_triggered => $edge_triggered ? 1 : 0,
    oneshot        => $oneshot        ? 1 : 0,

    active => 1,
  }, $class;
}

sub loop ($self) { return $self->{loop} }
sub fh   ($self) { return $self->{fh} }
sub fd   ($self) { return $self->{fd} }

sub is_active ($self) { return $self->{active} ? 1 : 0 }

sub data ($self, @args) {
  if (@args) {
    $self->{data} = $args[0];
  }
  return $self->{data};
}

sub edge_triggered ($self, @args) {
  if (@args) {
    $self->{edge_triggered} = $args[0] ? 1 : 0;
    $self->{loop}->_watcher_update($self);
  }
  return $self->{edge_triggered} ? 1 : 0;
}

sub oneshot ($self, @args) {
  if (@args) {
    $self->{oneshot} = $args[0] ? 1 : 0;
    $self->{loop}->_watcher_update($self);
  }
  return $self->{oneshot} ? 1 : 0;
}

sub on_read ($self, $cb = undef) {
  if (defined $cb && ref($cb) ne 'CODE') {
    croak "read handler must be a coderef or undef";
  }
  $self->{read_cb} = $cb;

  # If a handler is installed and read was disabled, do not silently enable.
  # Callers can explicitly enable_read() if desired.
  if (!$cb) {
    $self->{read_enabled} = 0;
  }

  $self->{loop}->_watcher_update($self);
  return $self;
}

sub on_write ($self, $cb = undef) {
  if (defined $cb && ref($cb) ne 'CODE') {
    croak "write handler must be a coderef or undef";
  }
  $self->{write_cb} = $cb;

  if (!$cb) {
    $self->{write_enabled} = 0;
  }

  $self->{loop}->_watcher_update($self);
  return $self;
}


sub on_error ($self, $cb = undef) {
  if (defined $cb && ref($cb) ne 'CODE') {
    croak "error handler must be a coderef or undef";
  }
  $self->{error_cb} = $cb;

  if (!$cb) {
    $self->{error_enabled} = 0;
  }

  # Note: error interest is not an epoll subscription bit; epoll reports ERR regardless.
  # This method only controls dispatch.
  $self->{loop}->_watcher_update($self);
  return $self;
}

sub enable_error ($self) {
  $self->{error_enabled} = 1;
  $self->{loop}->_watcher_update($self);
  return $self;
}

sub disable_error ($self) {
  $self->{error_enabled} = 0;
  $self->{loop}->_watcher_update($self);
  return $self;
}

sub enable_read ($self) {
  $self->{read_enabled} = 1;
  $self->{loop}->_watcher_update($self);
  return $self;
}

sub disable_read ($self) {
  $self->{read_enabled} = 0;
  $self->{loop}->_watcher_update($self);
  return $self;
}

sub enable_write ($self) {
  $self->{write_enabled} = 1;
  $self->{loop}->_watcher_update($self);
  return $self;
}

sub disable_write ($self) {
  $self->{write_enabled} = 0;
  $self->{loop}->_watcher_update($self);
  return $self;
}

sub read_enabled  ($self) { return $self->{read_enabled}  ? 1 : 0 }
sub write_enabled ($self) { return $self->{write_enabled} ? 1 : 0 }
sub error_enabled ($self) { return $self->{error_enabled} ? 1 : 0 }

sub cancel ($self) {
  return 0 if !$self->{active};

  my $ok = $self->{loop}->_watcher_cancel($self);
  $self->{active} = 0 if $ok;
  return $ok ? 1 : 0;
}

1;

__END__

=head1 NAME

Linux::Event::Watcher - Mutable watcher handle for Linux::Event::Loop

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;

  my $w = $loop->watch($fh,
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
      $w->disable_write; # typical: only enable when you actually have pending output
    },

    error => sub ($loop, $fh, $w) {
      # error readiness reported (see DISPATCH SEMANTICS)
      $w->cancel;
      close $fh;
    },
  );

  # stop watching (does not close the fh)
  $w->cancel;

=head1 DESCRIPTION

A watcher is the mutable handle returned by C<< $loop->watch(...) >>.

It stores:

=over 4

=item * Callback coderefs (read/write/error)

=item * Enable/disable state for each callback

=item * Optional user data (a single slot)

=item * Epoll behavior flags (edge-triggered, oneshot)

=back

The loop owns polling and dispatch. The watcher provides a small, explicit API to
mutate readiness interest and to cancel the registration.

=head1 LAYERING

L<Linux::Event::Watcher> is a core primitive used by L<Linux::Event::Loop>.

It does not perform socket acquisition or buffering. For that, see:

=over 4

=item * L<Linux::Event::Listen> - accept produces an accepted fh

=item * L<Linux::Event::Connect> - connect produces a connected fh

=item * L<Linux::Event::Stream> - buffered I/O + backpressure, owns the fh

=back

=head1 CALLBACK CONTRACT

Watcher callbacks are invoked with this signature:

  sub ($loop, $fh, $watcher) { ... }

Where:

=over 4

=item * C<$loop>

The owning loop instance.

=item * C<$fh>

The watched filehandle.

=item * C<$watcher>

This watcher object.

=back

Installed callbacks correspond to the keys passed to C<< $loop->watch >>:

  read  => sub ($loop, $fh, $w) { ... }
  write => sub ($loop, $fh, $w) { ... }
  error => sub ($loop, $fh, $w) { ... }   # optional

=head1 OWNERSHIP AND LIFETIME

=head2 Filehandle ownership

Watchers do B<not> own the filehandle. Cancelling a watcher does not close the
filehandle. User code is responsible for closing resources.

Recommended teardown order:

  $w->cancel;
  close $fh;

=head2 Idempotence

C<< $w->cancel >> is idempotent. Enabling/disabling callbacks is also safe to
call repeatedly.

=head2 Weak filehandle reference

The watcher stores a weak reference to the filehandle. If user code drops/closes
the handle and it becomes undef, the loop may auto-purge the watcher during
dispatch to prevent stale registrations.

=head1 METHODS

=head2 loop / fh / fd

  my $loop = $w->loop;
  my $fh   = $w->fh;
  my $fd   = $w->fd;

Accessors for the owning loop, the watched filehandle, and its numeric file
descriptor.

=head2 data

  my $data = $w->data;
  $w->data($new_data);

Get/set the user data slot. This is an opaque value stored on the watcher and is
not interpreted by the loop.

=head2 on_read / on_write / on_error

  $w->on_read($cb);
  $w->on_write($cb);
  $w->on_error($cb);

Install or replace handlers. Pass undef to remove the handler.

When you pass undef, the corresponding callback is also disabled.

Note: installing a new handler does not necessarily re-enable dispatch if you
previously disabled it; explicitly call enable_* if you want that behavior.

=head2 enable_read / disable_read
=head2 enable_write / disable_write
=head2 enable_error / disable_error

  $w->disable_write;
  $w->enable_write;

Enable/disable dispatch of the corresponding callback.

Interest masks are derived from (handler installed) + (enabled flag).

Important note about error readiness: epoll reports errors regardless of the
interest mask. These methods only control whether the loop dispatches to your
C<error> callback.

=head2 edge_triggered / oneshot

  my $bool = $w->edge_triggered;
  $w->edge_triggered(1);

  my $bool = $w->oneshot;
  $w->oneshot(1);

Get/set advanced epoll behaviors. Changing these updates backend registration
immediately.

=head2 is_active

  if ($w->is_active) { ... }

True if the watcher is still registered/active.

=head2 cancel

  $w->cancel;

Remove the watcher from the loop/backend. After cancellation the watcher becomes
inert and will not invoke callbacks again.

=head1 DISPATCH SEMANTICS

=head2 Error readiness ordering

If an epoll event indicates an error condition (for example C<EPOLLERR>), the loop
dispatches to the watcher’s C<error> callback first (if installed and enabled)
and returns.

If no C<error> callback is installed/enabled, error readiness may be treated as
readable and/or writable (depending on the platform and backend behavior). Do not
rely on a specific fallback; install an C<error> handler if you want explicit
error handling.

=head2 Hangup / EOF

On hangup conditions (for example C<EPOLLHUP>), readable readiness is typically
delivered so user code can observe EOF via C<read(2)> returning 0.

=head1 VERSION

This document describes Linux::Event::Watcher version 0.009.

=head1 SEE ALSO

L<Linux::Event::Listen> - nonblocking bind + accept

L<Linux::Event::Connect> - nonblocking outbound connect

L<Linux::Event::Stream> - buffered I/O and backpressure for sockets

L<Linux::Event::Fork> - asynchronous child process management

L<Linux::Event::Clock> - high resolution monotonic clock utilities

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
