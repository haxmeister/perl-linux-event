package Linux::Event::Kernel::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Wakeup';
use Carp qw(croak);

sub on_wakeup ($self, $count) {
    my $callback = $self->can('on_event')
        // croak ref($self) . ' must define on_event()';
    return $callback->($self, $count);
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
