package Linux::Event::_ByteStream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::_IO';

1;

__END__

=head1 NAME

Linux::Event::_ByteStream - private ordered-byte I/O implementation layer

=head1 DESCRIPTION

This package is an internal implementation boundary for ordered byte streams.
It is not a public subclassing API.

The byte-stream layer is intended to own behavior shared by pipe-like I/O and
C<SOCK_STREAM> sockets: directional handles, nonblocking reads and writes,
input buffering, output queues, backpressure, framing, message batching,
deadlines, EOF, and directional lifecycle.

Socket identity, addressing, connection acquisition, listening, and datagram
semantics do not belong to this layer.

=cut
