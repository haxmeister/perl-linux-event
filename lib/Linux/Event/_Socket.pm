package Linux::Event::_Socket;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::_IO';

1;

__END__

=head1 NAME

Linux::Event::_Socket - private Linux socket implementation layer

=head1 DESCRIPTION

This package is an internal implementation boundary for behavior that exists
because an underlying descriptor is a Linux socket. It is not a public
subclassing API.

Socket validation, address handling, socket options, creation/configuration,
and shared socket lifecycle belong here or in private helpers below it.
Stream-byte processing and message framing belong to the byte-stream layer;
listen/accept and datagram behavior remain specialized concerns.

=cut
