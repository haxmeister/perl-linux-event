package Linux::Event::Watcher;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_024';

use Carp qw(croak);

sub _attach_to_loop ($self, $loop) {
    croak ref($self) . ' does not implement Watcher attachment';
}

sub loop ($self) { return undef }
sub is_attached ($self) { return defined $self->loop }
sub is_terminal ($self) { return 0 }

1;

__END__

=head1 NAME

Linux::Event::Watcher - lifecycle contract for loop-managed activities

=head1 DESCRIPTION

A Watcher is one logical activity owned by a L<Linux::Event::Loop>. Concrete
Watchers include raw descriptor watchers, Streams, Listeners, Connectors, and
future Timer, Signal, Child, and Process types. A Watcher may own more than one
native epoll registration.

Applications normally subclass a concrete Watcher rather than this base class.
New Watchers are detached and are attached exactly once with C<< $loop->add >>.

=cut
