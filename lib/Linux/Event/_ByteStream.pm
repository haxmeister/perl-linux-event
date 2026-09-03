package Linux::Event::_ByteStream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent qw(
    Linux::Event::_IO
    Linux::Event::Stream
);

1;

__END__

=head1 NAME

Linux::Event::_ByteStream - private ordered-byte I/O implementation layer

=head1 DESCRIPTION

This package is an internal implementation boundary for ordered byte streams.
It is not a public subclassing API.

During the architecture migration it inherits the proven
L<Linux::Event::Stream> implementation so new public leaves can depend on this
private boundary rather than on the old public name. Existing byte-stream
implementation will move behind this boundary in later commits.

The byte-stream layer owns behavior shared by pipe-like I/O and C<SOCK_STREAM>
sockets: directional handles, nonblocking reads and writes, input buffering,
output queues, backpressure, framing, message batching, deadlines, EOF, and
directional lifecycle.

Socket identity, addressing, connection acquisition, listening, and datagram
semantics do not belong to this layer.

=cut
