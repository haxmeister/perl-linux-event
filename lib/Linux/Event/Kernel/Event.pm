package Linux::Event::Kernel::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Wakeup';
use Carp qw(croak);

sub new ($class, %option) {
    croak 'new(): must be called as a class method' if ref $class;
    croak "$class must define on_event()" if !$class->can('on_event');
    return $class->SUPER::new(%option);
}

sub on_wakeup ($self, $count) {
    return $self->on_event($count);
}

1;

__END__

=head1 NAME

Linux::Event::Kernel::Event - Linux::Event eventfd notification abstraction

=head1 DESCRIPTION

This class is the event leaf of the corrected Kernel namespace. It is backed by
the existing eventfd implementation but presents C<on_event> as the public
callback name rather than carrying the old C<Wakeup> terminology forward.

Subclasses define:

  sub on_event ($event, $count) {
      ...
  }

The C<signal> method retains eventfd counter semantics.

The temporary C<on_wakeup> bridge is an implementation detail used while the
native eventfd implementation is moved under this final class name.

=cut
