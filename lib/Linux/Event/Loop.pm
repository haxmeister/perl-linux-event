package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

use Carp qw(croak);
use Linux::Event::Reactor ();
use Linux::Event::Proactor ();

use constant READABLE => 0x01;
use constant WRITABLE => 0x02;
use constant PRIO     => 0x04;
use constant RDHUP    => 0x08;
use constant ET       => 0x10;
use constant ONESHOT  => 0x20;
use constant ERR      => 0x40;
use constant HUP      => 0x80;

sub new ($class, %arg) {
  my $model   = delete $arg{model};
  my $backend = delete $arg{backend};

  $model //= _infer_model_from_backend($backend) // 'reactor';

  my ($impl_class, $default_backend) = _resolve_model($model);
  $backend //= $default_backend;

  my $self = bless {
    model => $model,
    impl  => undef,
  }, $class;

  my %impl_arg = (%arg, backend => $backend);
  $impl_arg{loop} = $self if $model eq 'reactor';

  $self->{impl} = $impl_class->new(%impl_arg);
  return $self;
}

sub _infer_model_from_backend ($backend) {
  return undef if !defined $backend || ref($backend);
  return 'reactor'  if $backend eq 'epoll';
  return 'proactor' if $backend eq 'uring' || $backend eq 'fake';
  return undef;
}

sub _resolve_model ($model) {
  return ('Linux::Event::Reactor', 'epoll')   if $model eq 'reactor';
  return ('Linux::Event::Proactor', 'uring')  if $model eq 'proactor';
  croak "unknown model '$model'";
}

sub model ($self) { return $self->{model} }
sub impl  ($self) { return $self->{impl} }

sub _delegate ($self, $method, @arg) {
  my $impl = $self->{impl};
  croak "loop model '$self->{model}' does not support $method()" if !$impl->can($method);
  return $impl->$method(@arg);
}

sub backend_name ($self) { return $self->_delegate('backend_name') }
sub clock        ($self) { return $self->_delegate('clock') }
sub is_running   ($self) { return $self->_delegate('is_running') }
sub run          ($self, @arg) { return $self->_delegate('run', @arg) }
sub run_once     ($self, @arg) { return $self->_delegate('run_once', @arg) }
sub stop         ($self, @arg) { return $self->_delegate('stop', @arg) }

# Reactor surface
sub timer   ($self, @arg) { return $self->_delegate('timer', @arg) }
sub backend ($self, @arg) { return $self->_delegate('backend', @arg) }
sub sched   ($self, @arg) { return $self->_delegate('sched', @arg) }
sub signal  ($self, @arg) { return $self->_delegate('signal', @arg) }
sub waker   ($self, @arg) { return $self->_delegate('waker', @arg) }
sub pid     ($self, @arg) { return $self->_delegate('pid', @arg) }
sub watch   ($self, @arg) { return $self->_delegate('watch', @arg) }
sub unwatch ($self, @arg) { return $self->_delegate('unwatch', @arg) }
sub cancel  ($self, @arg) { return $self->_delegate('cancel', @arg) }
sub after   ($self, @arg) { return $self->_delegate('after', @arg) }
sub at      ($self, @arg) { return $self->_delegate('at', @arg) }

# Proactor surface
sub read            ($self, @arg) { return $self->_delegate('read', @arg) }
sub write           ($self, @arg) { return $self->_delegate('write', @arg) }
sub recv            ($self, @arg) { return $self->_delegate('recv', @arg) }
sub send            ($self, @arg) { return $self->_delegate('send', @arg) }
sub accept          ($self, @arg) { return $self->_delegate('accept', @arg) }
sub connect         ($self, @arg) { return $self->_delegate('connect', @arg) }
sub shutdown        ($self, @arg) { return $self->_delegate('shutdown', @arg) }
sub close           ($self, @arg) { return $self->_delegate('close', @arg) }
sub live_op_count   ($self, @arg) { return $self->_delegate('live_op_count', @arg) }
sub drain_callbacks ($self, @arg) { return $self->_delegate('drain_callbacks', @arg) }

# Private watcher hooks used by Linux::Event::Watcher.
sub _watcher_update ($self, @arg) { return $self->_delegate('_watcher_update', @arg) }
sub _watcher_cancel ($self, @arg) { return $self->_delegate('_watcher_cancel', @arg) }

1;

__END__

=head1 NAME

Linux::Event::Loop - Front-door loop selector for the Linux::Event ecosystem

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $reactor = Linux::Event::Loop->new(
    model   => 'reactor',
    backend => 'epoll',
  );

  my $proactor = Linux::Event::Loop->new(
    model   => 'proactor',
    backend => 'uring',
  );

  # model defaults to reactor
  my $loop = Linux::Event->new;

=head1 DESCRIPTION

B<Linux::Event::Loop> is the public front door and selector for loop engines in
the Linux::Event ecosystem.

It constructs and delegates to one of two engine classes:

=over 4

=item * L<Linux::Event::Reactor>

Readiness-based event loop built on epoll and related Linux primitives.

=item * L<Linux::Event::Proactor>

Completion-based event loop built for io_uring-style operations.

=back

The default model is C<reactor>.

=head1 CONSTRUCTOR

=head2 new(%args)

Recognized top-level selector arguments:

=over 4

=item * C<model>

Either C<reactor> or C<proactor>. Defaults to C<reactor>.

=item * C<backend>

Backend name or backend object appropriate to the selected model.

=back

All remaining arguments are passed through to the selected engine constructor.

=head1 DELEGATION

This module is intentionally thin. It delegates public methods to the selected
engine instance. Reactor-specific methods are available when the selected model
is a reactor; proactor-specific methods are available when the selected model is
a proactor.

=head1 SEE ALSO

L<Linux::Event>,
L<Linux::Event::Reactor>,
L<Linux::Event::Reactor::Backend>,
L<Linux::Event::Reactor::Backend::Epoll>,
L<Linux::Event::Proactor>,
L<Linux::Event::Proactor::Backend>

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
