package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.011';

use Carp qw(croak);
use Linux::Event::Reactor ();

use constant READABLE => 0x01;
use constant WRITABLE => 0x02;
use constant PRIO     => 0x04;
use constant RDHUP    => 0x08;
use constant ET       => 0x10;
use constant ONESHOT  => 0x20;
use constant ERR      => 0x40;
use constant HUP      => 0x80;

sub new ($class, %arg) {
  croak "model is no longer supported; Linux::Event is reactor-only" if exists $arg{model};

  my $self = bless {
    reactor => undef,
  }, $class;

  $arg{loop} = $self;
  $self->{reactor} = Linux::Event::Reactor->new(%arg);
  return $self;
}


sub _delegate ($self, $method, @arg) {
  return $self->{reactor}->$method(@arg);
}

sub backend_name ($self) { return $self->_delegate('backend_name') }
sub clock        ($self) { return $self->_delegate('clock') }
sub is_running   ($self) { return $self->_delegate('is_running') }
sub run          ($self, @arg) { return $self->_delegate('run', @arg) }
sub run_once     ($self, @arg) { return $self->_delegate('run_once', @arg) }
sub stop         ($self, @arg) { return $self->_delegate('stop', @arg) }

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

# Private watcher hooks used by Linux::Event::Watcher.
sub _watcher_update ($self, @arg) { return $self->_delegate('_watcher_update', @arg) }
sub _watcher_cancel ($self, @arg) { return $self->_delegate('_watcher_cancel', @arg) }

1;

__END__

=head1 NAME

Linux::Event::Loop - Reactor event loop facade for Linux::Event

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::Loop;

  my $loop = Linux::Event::Loop->new;

  $loop->after(0.100, sub ($loop) {
    say "timer fired";
    $loop->stop;
  });

  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Loop> is the public event loop facade for this distribution.
It builds a single readiness-based L<Linux::Event::Reactor> engine backed by
Linux epoll, timerfd, signalfd, eventfd, and pidfd primitives.

The old model selector API has been removed. C<Linux::Event> is now
reactor-only, so C<model> is not a constructor argument.

=head1 CONSTRUCTOR

=head2 new(%args)

Create a new reactor loop. Recognized arguments are forwarded to
L<Linux::Event::Reactor/new>, including:

=over 4

=item * C<backend>

Either C<epoll>, omitted for the default epoll backend, or a backend object
implementing the reactor backend contract.

=item * C<clock>

Optional clock object.

=item * C<timer>

Optional timerfd wrapper object.

=back

Passing C<model> is an error.

=head1 METHODS

=over 4

=item * C<backend_name>

=item * C<clock>

=item * C<is_running>

=item * C<run>

=item * C<run_once>

=item * C<stop>

=item * C<timer>

=item * C<backend>

=item * C<sched>

=item * C<signal>

=item * C<waker>

=item * C<pid>

=item * C<watch>

=item * C<unwatch>

=item * C<cancel>

=item * C<after>

=item * C<at>

=back

=head1 SEE ALSO

L<Linux::Event>,
L<Linux::Event::Reactor>,
L<Linux::Event::Reactor::Backend>,
L<Linux::Event::Reactor::Backend::Epoll>

=cut
