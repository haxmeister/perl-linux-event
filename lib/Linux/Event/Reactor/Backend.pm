package Linux::Event::Reactor::Backend;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.009';

1;

__END__

=head1 NAME

Linux::Event::Reactor::Backend - Backend contract for Linux::Event::Reactor

=head1 DESCRIPTION

This module documents the contract implemented by reactor backends for
L<Linux::Event::Reactor>. Backends are intentionally duck-typed, but the method
surface and callback ABI described here are the forward-looking contract for
this distribution.

The reactor owns scheduling policy, timer integration, watcher state, and user
callback dispatch rules. A reactor backend owns readiness registration and the
kernel wait mechanism.

=head1 REQUIRED METHODS

=head2 new(%args)

Construct the backend instance. Backends may accept implementation-specific
arguments.

=head2 name()

Return a short backend name such as C<epoll>.

=head2 watch($fh, $mask, $cb, %opt) -> $fd

Register readiness interest for C<$fh>.

The callback ABI is:

  $cb->($loop, $fh, $fd, $mask, $tag);

Where:

=over 4

=item * C<$loop> is the public loop object used by the caller

=item * C<$fh> is the watched filehandle

=item * C<$fd> is the integer file descriptor

=item * C<$mask> is the Linux::Event readiness mask

=item * C<$tag> is an optional backend passthrough value

=back

The backend must not reinterpret the callback ABI. It may invoke the callback
inline from C<run_once>, but it must not mutate reactor policy.

The distribution uses these optional keys in C<%opt>:

=over 4

=item * C<_loop> - the public loop object to pass back to the callback

=item * C<tag> - optional passthrough tag

=back

=head2 unwatch($fh_or_fd) -> $bool

Remove an existing readiness registration. Return true if something was removed
and false otherwise.

=head2 run_once($loop, $timeout_s = undef) -> $count

Wait for readiness and dispatch backend callbacks. C<$timeout_s> is expressed in
seconds and may be fractional. Undef means block as the backend sees fit.

Return the number of processed readiness events when available, or another
backend-defined count.

=head1 OPTIONAL METHODS

=head2 modify($fh_or_fd, $mask, %opt) -> $bool

Update an existing readiness registration without removing and re-adding it.
When unsupported, the reactor may fall back to unwatch plus watch.

=head1 READINESS MASKS

The reactor uses this bit layout:

  READABLE => 0x01
  WRITABLE => 0x02
  PRIO     => 0x04
  RDHUP    => 0x08
  ET       => 0x10
  ONESHOT  => 0x20
  ERR      => 0x40
  HUP      => 0x80

Backends are expected to translate to and from native kernel representations.

=head1 DESIGN NOTES

A reactor backend does not own timers, watcher replacement policy, signal
integration, wakeups, or pidfd policy. Those remain in the reactor engine.

=head1 SEE ALSO

L<Linux::Event::Loop>,
L<Linux::Event::Reactor>,
L<Linux::Event::Reactor::Backend::Epoll>,
L<Linux::Event::Proactor::Backend>

=head1 AUTHOR

Joshua S. Day

=head1 LICENSE

Same terms as Perl itself.

=cut
