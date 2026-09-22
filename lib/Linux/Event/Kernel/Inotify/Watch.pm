package Linux::Event::Kernel::Inotify::Watch;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.116';

use Scalar::Util qw(weaken);

sub _new ($class, $parent, $id, $path, $event_mask, $callback, $flag) {
    my $self = bless {
        parent     => $parent,
        id         => $id,
        path       => $path,
        event_mask => $event_mask,
        callbacks  => $callback,
        flags      => $flag,
        wd         => undef,
        state      => 'pending',
    }, $class;
    weaken($self->{parent});
    return $self;
}

sub cancel ($self) {
    return $self if $self->is_terminal;
    my $parent = $self->{parent};
    return $parent->_cancel_watch($self) if $parent;
    $self->_terminate('cancelled');
    return $self;
}

sub path ($self) { $self->{path} }
sub inotify ($self) { $self->{parent} }
sub state ($self) { $self->{state} }
sub is_active ($self) { $self->{state} eq 'active' }
sub is_terminal ($self) {
    return $self->{state} ne 'pending' && $self->{state} ne 'active';
}

sub _id ($self) { $self->{id} }
sub _wd ($self) { $self->{wd} }
sub _event_mask ($self) { $self->{event_mask} }
sub _callback ($self, $name) { $self->{callbacks}{$name} }
sub _flag ($self, $name) { $self->{flags}{$name} ? 1 : 0 }

sub _activate ($self, $wd) {
    $self->{wd} = $wd;
    $self->{state} = 'active';
    return $self;
}

sub _reset_pending ($self) {
    $self->{wd} = undef;
    $self->{state} = 'pending';
    return $self;
}

sub _terminate ($self, $state) {
    $self->{wd} = undef;
    $self->{state} = $state;
    $self->{callbacks} = {};
    return $self;
}

1;

__END__

=head1 NAME

Linux::Event::Kernel::Inotify::Watch - one logical inotify subscription

=head1 DESCRIPTION

A Watch is returned by L<Linux::Event::Kernel::Inotify/watch>. It represents
one logical subscription even when Linux coalesces several subscriptions onto
one underlying watch descriptor.

=head1 METHODS

=head2 cancel

  $watch->cancel;

Cancellation is idempotent and terminal. No callback is delivered to the Watch
after cancellation.

=head2 path

Returns the absolute path captured when the Watch was created.

=head2 inotify

Returns the owning L<Linux::Event::Kernel::Inotify> object while it still
exists.

=head2 state

Returns C<pending>, C<active>, C<cancelled>, C<ignored>, C<closed>, or
C<failed>.

=head2 is_active

True only while the kernel subscription is active.

=head2 is_terminal

True after cancellation, kernel invalidation, parent close, or failed live
activation.

=cut
