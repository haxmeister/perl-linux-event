package Linux::Event::Future;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use Carp qw(croak);

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

sub done ($self, @result) {
    return $self->AWAIT_DONE(@result);
}

sub fail ($self, $failure) {
    return $self->AWAIT_FAIL($failure);
}

sub get ($self) {
    return $self->AWAIT_GET;
}

sub is_ready ($self) {
    return $self->AWAIT_IS_READY;
}

sub is_cancelled ($self) {
    return $self->AWAIT_IS_CANCELLED;
}

sub on_ready ($self, $callback) {
    $self->AWAIT_ON_READY($callback);
    return $self;
}

sub on_cancel ($self, $callback) {
    $self->AWAIT_ON_CANCEL($callback);
    return $self;
}

sub AWAIT_WAIT ($self) {
    return $self->AWAIT_GET if $self->AWAIT_IS_READY;
    my $loop = $self->loop
        // croak 'cannot wait for a pending Future without a Loop';
    return $loop->run($self);
}

sub CLONE_SKIP ($class) { 1 }

1;

__END__

=head1 NAME

Linux::Event::Future - native awaitable for Linux::Event operations

=head1 SYNOPSIS

  use Linux::Event;
  use Linux::Event::Loop;

  async sub receive_one ($stream) {
      return await $stream->recv;
  }

  my $loop = Linux::Event::Loop->new;
  my $message = $loop->run(receive_one($stream));

=head1 DESCRIPTION

C<Linux::Event::Future> is the native completion value used by Future-first
Linux::Event APIs. Readiness, results, failure, cancellation, continuation
lists, and cancellation chains are stored in XS. The class implements the
C<Future::AsyncAwait::Awaitable> contract and is the future class selected by
C<use Linux::Event>.

Applications normally receive Futures from asynchronous operations rather
than constructing them directly. C<new> creates a pending Future and accepts
an optional Loop as its sole argument.

=head1 METHODS

=head2 done(@result)

Completes a pending Future successfully and returns the same Future.

=head2 fail($failure)

Completes a pending Future with an exception and returns the same Future.

=head2 cancel

Cancels a pending Future. Cancellation callbacks and one-way cancellation
chains run before readiness callbacks.

=head2 get

Returns the successful result, preserving list, scalar, or void context.
Throws the stored failure for a failed Future. Pending and cancelled Futures
cannot be read with C<get>.

=head2 is_ready

Returns true after success, failure, or cancellation.

=head2 is_cancelled

Returns true only after cancellation.

=head2 on_ready($callback)

Registers a callback to run after any terminal state. A callback registered on
an already-ready Future runs immediately.

=head2 on_cancel($callback)

Registers a callback to run on cancellation.

=head2 loop

Returns the associated L<Linux::Event::Loop>, if any.

=head1 AWAITABLE CONTRACT

The C<AWAIT_*> methods implement the interface documented by
L<Future::AsyncAwait::Awaitable>. They are public for integration code; normal
application code should use C<async>, C<await>, and the lowercase methods.

=cut
