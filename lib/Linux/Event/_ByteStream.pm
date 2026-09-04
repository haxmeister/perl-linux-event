package Linux::Event::_ByteStream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent qw(
    Linux::Event::_IO
    Linux::Event::Stream
);

sub transition_to ($self, $class, %option) {
    Linux::Event::_IO::_guard_transition_resource_kind($self, $class);
    return Linux::Event::Stream::transition_to($self, $class, %option);
}

1;

__END__

=head1 NAME

Linux::Event::_ByteStream - private ordered-byte I/O implementation layer

=head1 DESCRIPTION

This package is the internal implementation boundary for ordered-byte I/O. It
is not a public subclassing API.

The proven native byte engine is hosted under historical
C<Linux::Event::Stream> XS/Perl package identifiers. Those names are retained
privately for native ABI stability; public classes depend on this boundary
instead of treating that implementation package as an application API.

The byte-stream layer owns behavior shared by pipe-like I/O, terminals, and
C<SOCK_STREAM> sockets: directional handles, nonblocking reads and writes,
input buffering, output queues, backpressure, framing, message batching,
deadlines, EOF, and directional lifecycle.

Protocol transitions may change the application protocol subclass but must
retain the concrete public resource kind. Pipe and TTY transitions are checked
here before the historical Stream transition machinery swaps descriptors.

Socket identity, addressing, connection acquisition, listening, and datagram
semantics do not belong to this layer.

=cut
