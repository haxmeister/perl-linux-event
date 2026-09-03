package Linux::Event::IO::Sock::Dgram;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::_Socket::Dgram';

1;

__END__

=head1 NAME

Linux::Event::IO::Sock::Dgram - Linux C<SOCK_DGRAM> I/O

=head1 DESCRIPTION

This class is the public C<SOCK_DGRAM> leaf of the corrected Linux::Event I/O
taxonomy. IPv4, IPv6, and Unix-domain datagram sockets share this class;
socket family is configuration rather than a different public type.

Its implementation is reached through the private
L<Linux::Event::_Socket::Dgram> boundary. Datagram boundaries are supplied by
the kernel, so byte-stream framing does not belong to this class.

=cut
