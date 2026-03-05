package Linux::Event::Signal;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

use Carp qw(croak);
use Scalar::Util qw(weaken);
use POSIX ();

# External dependency for signalfd integration.
#
# This is loaded lazily so that the core loop can be used even when
# Linux::FD::Signal is not installed.

sub new ($class, %args) {
  my $loop = delete $args{loop};
  croak "loop is required" if !$loop;
  croak "unknown args: " . join(", ", sort keys %args) if %args;

  weaken($loop);

  return bless {
    loop => $loop,

    _fh      => undef,  # Linux::FD::Signal filehandle
    _watcher => undef,  # Linux::Event::Watcher for the signalfd

    _mask    => POSIX::SigSet->new(),
    _blocked => POSIX::SigSet->new(),

    # signum -> { cb => CODE, data => any, sub => $sub }
    _handlers => {},
  }, $class;
}

sub loop ($self) { return $self->{loop} }

sub signal ($self, $sig_or_list, $cb, %opt) {
  croak "signal is required" if !defined $sig_or_list;
  croak "cb is required" if !$cb;
  croak "cb must be a coderef" if ref($cb) ne 'CODE';

  my $data = delete $opt{data};
  croak "unknown args: " . join(", ", sort keys %opt) if %opt;

  my @sigs;
  if (ref($sig_or_list) eq 'ARRAY') {
    @sigs = @$sig_or_list;
  }
  elsif (!ref($sig_or_list)) {
    @sigs = ($sig_or_list);
  }
  else {
    croak "signal must be a number, string, or arrayref";
  }

  @sigs = map { _sig_to_num($_) } @sigs;
  croak "no signals provided" if !@sigs;

  $self->_ensure_fd;

  my $sub = Linux::Event::Signal::Subscription->_new($self, \@sigs);

  # Replacement semantics: one handler per signal, last registration wins.
  for my $sig (@sigs) {
    $self->{_handlers}{$sig} = {
      cb   => $cb,
      data => $data,
      sub  => $sub,
    };

    # Our semantics freeze: the mask and blocked-set only grow for the lifetime
    # of the loop. We do not attempt to restore legacy signal state.
    if (!$self->{_mask}->ismember($sig)) {
      $self->{_mask}->addset($sig);
      $self->_block_signal($sig);
      $self->{_fh}->set_mask($self->{_mask});
    }
  }

  return $sub;
}

sub _sig_to_num ($sig) {
  croak "signal is undef" if !defined $sig;

  if (!ref($sig) && $sig =~ /\A\d+\z/) {
    return int($sig);
  }

  croak "signal must be a string or integer" if ref($sig);

  my $name = uc($sig);
  $name =~ s/\A\s+|\s+\z//g;
  $name =~ s/\A(SIG)//;

  my $const = "SIG$name";
  my $sub = POSIX->can($const);
  croak "unknown signal '$sig'" if !$sub;
  return int($sub->());
}

sub _ensure_fd ($self) {
  return if $self->{_fh};

  eval { require Linux::FD::Signal; 1 }
    or croak "Linux::FD::Signal is required for signal() support: $@";

  # Non-blocking is critical: epoll read readiness may be spuriously invoked
  # when multiple records are pending; we drain to EAGAIN.
  my $fh = Linux::FD::Signal->new($self->{_mask}, 'non-blocking');
  $self->{_fh} = $fh;

  my $loop = $self->{loop} or croak "loop has been destroyed";
  $self->{_watcher} = $loop->watch(
    $fh,
    read => sub ($loop, $fh2, $w) {
      $self->_drain_and_dispatch;
    },
  );

  return;
}

sub _block_signal ($self, $sig) {
  return if $self->{_blocked}->ismember($sig);
  $self->{_blocked}->addset($sig);
  POSIX::sigprocmask(POSIX::SIG_BLOCK(), $self->{_blocked});
  return;
}

sub _drain_and_dispatch ($self) {
  my $loop = $self->{loop};
  return if !$loop;

  my $fh = $self->{_fh} or return;

  my %count;

  while (1) {
    my $info = eval { $fh->receive };
    if (!$info) {
      # Linux::FD::Signal returns undef on EAGAIN (non-blocking), and sets $!.
      last if $!{EAGAIN} || $!{EWOULDBLOCK};
      last if $@ && ($@ =~ /EAGAIN/);
      die $@ if $@;
      last;
    }

    my $sig = $info->{signo};
    $count{$sig}++ if defined $sig;
  }

  return if !%count;

  # Dispatch: per-signal callback, once per dispatch cycle.
  for my $sig (sort { $a <=> $b } keys %count) {
    my $h = $self->{_handlers}{$sig} or next;
    my $cb = $h->{cb} or next;
    $cb->($loop, $sig, $count{$sig}, $h->{data});
  }

  return;
}

sub _cancel_subscription ($self, $sub) {
  # Remove mappings only if they still point at this subscription.
  for my $sig (@{ $sub->{_sigs} }) {
    my $h = $self->{_handlers}{$sig} or next;
    next if !$h->{sub} || $h->{sub} != $sub;
    delete $self->{_handlers}{$sig};
  }
  return;
}


package Linux::Event::Signal::Subscription;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(weaken);

sub _new ($class, $signal, $sigs) {
  weaken($signal);
  return bless {
    _signal => $signal,
    _sigs   => [@$sigs],
    _active => 1,
  }, $class;
}

sub cancel ($self) {
  return 0 if !$self->{_active};
  $self->{_active} = 0;
  my $signal = $self->{_signal};
  $signal->_cancel_subscription($self) if $signal;
  return 1;
}

sub is_active ($self) { return $self->{_active} ? 1 : 0 }

1;

__END__

=head1 NAME

Linux::Event::Signal - signalfd integration for Linux::Event

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new;

  # Subscribe via the loop convenience method:
  my $sub = $loop->signal('INT', sub ($loop, $sig, $count, $data) {
    $loop->stop;
  });

  $loop->run;

  # Cancel the subscription (idempotent):
  $sub->cancel;

=head1 DESCRIPTION

B<Linux::Event::Signal> provides Linux C<signalfd(2)> integration for
L<Linux::Event::Loop>.

The loop exposes this via C<< $loop->signal(...) >>, but the implementation lives
in this module to keep C<Loop.pm> small and to avoid forcing a hard dependency
on signalfd support for users who do not need it.

This module uses L<Linux::FD::Signal> lazily. You only need it installed if you
use signal subscriptions.

=head1 LAYERING

This distribution is a loop primitive.

It does not perform socket acquisition or buffered I/O. For sockets and I/O
stack composition, see:

=over 4

=item * L<Linux::Event::Listen> - accept produces an accepted fh

=item * L<Linux::Event::Connect> - connect produces a connected fh

=item * L<Linux::Event::Stream> - buffered I/O + backpressure, owns the fh

=back

=head1 LOOP CONVENIENCE API

Most users will subscribe via the loop method:

  my $sub = $loop->signal($sig_or_list, $cb, %opt);

This delegates to an internal L<Linux::Event::Signal> instance owned by the
loop. The returned value is a subscription object (see L</SUBSCRIPTIONS>).

=head1 SUBSCRIPTIONS

Subscribing returns a subscription object:

  my $sub = $loop->signal('TERM', $cb, data => $data);

The subscription object supports:

=over 4

=item * C<< $sub->cancel >>

Cancel the subscription (idempotent).

=item * C<< $sub->is_active >>

True if the subscription is still active.

=back

=head1 CALLBACK CONTRACT

Signal callbacks are invoked with this signature:

  sub ($loop, $signum, $count, $data) { ... }

Where:

=over 4

=item * C<$loop>

The L<Linux::Event::Loop> instance.

=item * C<$signum>

The numeric signal number.

=item * C<$count>

Number of signal records drained for this signal since the last dispatch cycle.

This module drains the signalfd in nonblocking mode and aggregates counts per
signal. Dispatch occurs once per signal per cycle (not once per record).

=item * C<$data>

The C<data> option you provided when registering the handler (or undef).

=back

=head1 SEMANTICS

=head2 Signal name and number inputs

You may subscribe using a numeric signal number, a string name, or an arrayref:

  $loop->signal(2,       $cb);
  $loop->signal('INT',   $cb);
  $loop->signal(['HUP','TERM'], $cb);

String names may be provided with or without a leading C<SIG> prefix.

=head2 Replacement semantics (one handler per signal)

This module stores one handler per numeric signal.

If you register a handler for a signal that already has a handler, the new
registration replaces the old one (last registration wins).

If you want fan-out, do it explicitly in your callback.

=head2 Mask growth and signal blocking

For the lifetime of the loop, the signal mask and blocked-set only grow.

When you first subscribe to a signal:

=over 4

=item * the signalfd mask is extended to include that signal

=item * the process signal mask is updated to block that signal (SIG_BLOCK)

=back

This module does not attempt to restore the prior signal disposition or unblock
signals on cancel. This is a deliberate semantics freeze to keep behavior
explicit and stable.

=head2 Nonblocking drain

The underlying signalfd is created in nonblocking mode. When readability fires,
this module drains signalfd records until C<EAGAIN>/C<EWOULDBLOCK>, aggregates
counts by signal, and then dispatches callbacks.

=head1 API

=head2 Linux::Event::Signal->new

  my $sig = Linux::Event::Signal->new(loop => $loop);

Create a signal dispatcher bound to a loop.

=head2 $sig->signal

  my $sub = $sig->signal($sig_or_list, $cb, %opt);

Register (or replace) a handler for one or more signals.

Required:

=over 4

=item * C<$sig_or_list>

A signal number, a signal name string, or an arrayref of numbers/names.

=item * C<$cb>

A coderef.

=back

Optional:

=over 4

=item * C<data>

Opaque user data passed to the callback as the last argument.

=back

Returns a subscription object that can be cancelled.

=head2 $sig->cancel

  $sig->cancel;

Cancel the internal signalfd watcher and detach from the loop. This is an
internal control method; most users only cancel individual subscriptions.

=head2 $sig->is_active

  if ($sig->is_active) { ... }

True if the internal watcher is installed and the dispatcher is active.

=head1 DEPENDENCIES

This module requires L<Linux::FD::Signal> only when signal support is used. It is
loaded lazily, and an informative error is thrown if it is missing.

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
