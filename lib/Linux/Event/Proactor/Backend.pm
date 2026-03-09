package Linux::Event::Proactor::Backend;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

1;

__END__

=head1 NAME

Linux::Event::Proactor::Backend - Backend contract for Linux::Event::Proactor

=head1 DESCRIPTION

This module documents the contract implemented by proactor backends for
L<Linux::Event::Proactor>. Backends are intentionally duck-typed, but they are
expected to follow the submission, completion, and cancellation semantics
described here.

The proactor owns operation objects, callback queueing, lifecycle state, and
settle-once guarantees. A proactor backend owns submission to the underlying
completion mechanism and raw completion delivery.

=head1 REQUIRED METHODS

=head2 _new(%args)

Construct the backend instance. C<loop> is required.

=head2 name()

Return a short backend name such as C<uring> or C<fake>.

=head2 _submit_read($op, %args)

=head2 _submit_write($op, %args)

=head2 _submit_recv($op, %args)

=head2 _submit_send($op, %args)

=head2 _submit_accept($op, %args)

=head2 _submit_connect($op, %args)

=head2 _submit_timeout($op, %args)

=head2 _submit_shutdown($op, %args)

=head2 _submit_close($op, %args)

Submit an operation of the given kind and return a backend token that can later
be used for cancellation and bookkeeping.

=head2 _cancel($token)

Attempt to cancel an in-flight operation identified by the backend token. The
backend may complete cancellation asynchronously. The proactor remains
responsible for settle-once semantics.

=head2 _complete_backend_events() -> $count

Drive backend completion processing once and return the number of processed
backend events when available.

=head1 COMPLETION CONVENTIONS

A backend must report raw completion results back into the owning proactor in a
way that allows the proactor to decide whether the operation succeeds, fails, or
was cancelled.

For io_uring-style backends, negative completion results correspond to negative
errno values and must be normalized accordingly.

Callbacks provided by users must never be executed inline by the backend. User
callback dispatch is the responsibility of L<Linux::Event::Proactor>.

=head1 LIFETIME RULES

For operations that depend on buffer lifetime, the backend must preserve any
required Perl values until the kernel no longer needs them.

A backend must not settle an operation more than once. In cancellation races, it
must cooperate with the proactor's registry and state checks so that the final
settled state is consistent.

=head1 SEE ALSO

L<Linux::Event::Loop>,
L<Linux::Event::Proactor>,
L<Linux::Event::Proactor::Backend::Uring>,
L<Linux::Event::Proactor::Backend::Fake>,
L<Linux::Event::Reactor::Backend>

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
