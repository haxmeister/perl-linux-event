package Linux::Event::Watcher;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.002_001';

use Carp qw(croak);

# NOTE:
# This object is intentionally lightweight. It is a handle and a data container.
# The Loop owns policy and backend interactions; Watcher methods delegate into Loop.

sub new ($class, %args) {
  my $loop = delete $args{loop};
  my $fh   = delete $args{fh};
  my $fd   = delete $args{fd};

  my $read  = delete $args{read};
  my $write = delete $args{write};

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

  # Default enablement: if a handler exists, it's enabled.
  my $read_enabled  = $read  ? 1 : 0;
  my $write_enabled = $write ? 1 : 0;

  return bless {
    loop  => $loop,
    fh    => $fh,
    fd    => int($fd),

    data  => $data,

    read_cb  => $read,
    write_cb => $write,

    read_enabled  => $read_enabled,
    write_enabled => $write_enabled,

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

sub cancel ($self) {
  return 0 if !$self->{active};

  my $ok = $self->{loop}->_watcher_cancel($self);
  $self->{active} = 0 if $ok;
  return $ok ? 1 : 0;
}

1;

__END__

=head1 NAME

Linux::Event::Watcher - Mutable filehandle watcher handle for Linux::Event::Loop

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;

  my $conn = My::Conn->new(...);

  my $w = $loop->watch_fh($fh,
    read => sub ($loop, $fh, $w) {
      my $conn = $w->data;
      $conn->on_read($loop, $fh);
      $w->enable_write if $conn->has_pending_output;
    },
    write => sub ($loop, $fh, $w) {
      my $conn = $w->data;
      $conn->on_write($loop, $fh);
      $w->disable_write if !$conn->has_pending_output;
    },
    data => $conn,
  );

  $loop->run;

=head1 DESCRIPTION

A watcher is a lightweight, mutable handle returned by
L<Linux::Event::Loop/watch_fh>. It holds:

=over 4

=item * The watched filehandle and its file descriptor

=item * User data (C<data>) to avoid closure captures

=item * Read/write handlers (mutable)

=item * Enable/disable toggles (especially useful for write backpressure)

=item * Advanced flags like C<edge_triggered> and C<oneshot>

=back

The watcher itself does not own policy and does not talk directly to the backend.
It delegates updates and cancellation to its owning loop.

=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

This API is a developer release and may change without notice.

=head1 METHODS

=head2 new(%args)

Constructor used internally by L<Linux::Event::Loop>. Not typically called by
users.

=head2 loop

Returns the owning loop.

=head2 fh

Returns the watched filehandle.

=head2 fd

Returns the cached integer file descriptor.

=head2 is_active

True if the watcher is still registered.

=head2 data

  my $x = $w->data;
  $w->data($x);

Get or set the user data associated with this watcher.

=head2 on_read

  $w->on_read(sub ($loop, $fh, $w) { ... });
  $w->on_read(undef);

Set or clear the read handler. Clearing disables read notifications.

=head2 on_write

  $w->on_write(sub ($loop, $fh, $w) { ... });
  $w->on_write(undef);

Set or clear the write handler. Clearing disables write notifications.

=head2 enable_read / disable_read

Enable or disable read notifications for this watcher.

=head2 enable_write / disable_write

Enable or disable write notifications for this watcher.

=head2 read_enabled / write_enabled

Return the current enabled state for read/write.

=head2 edge_triggered

  $w->edge_triggered(1);  # enable edge-triggered mode
  $w->edge_triggered(0);  # level-triggered (default)

Advanced: toggles edge-triggered readiness notifications.

=head2 oneshot

  $w->oneshot(1);         # enable one-shot mode
  $w->oneshot(0);

Advanced: toggles one-shot readiness notifications.

=head2 cancel

  $w->cancel;

Cancel/unregister this watcher. Idempotent.

=head1 SEE ALSO

L<Linux::Event>, L<Linux::Event::Loop>, L<Linux::Event::Backend::Epoll>

=cut
