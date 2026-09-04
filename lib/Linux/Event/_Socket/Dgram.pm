package Linux::Event::_Socket::Dgram;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent qw(
    Linux::Event::_Socket
    Linux::Event::Datagram
);

1;

__END__

=head1 NAME

Linux::Event::_Socket::Dgram - private C<SOCK_DGRAM> implementation boundary

=head1 DESCRIPTION

This package is internal. It joins the private socket classification with the
proven datagram implementation hosted under the historical
C<Linux::Event::Datagram> package name. That implementation name is private and
is not an application subclassing API.

Datagram message boundaries remain kernel-provided and do not use the
ordered-byte framing layer. The public leaf is
L<Linux::Event::IO::Sock::Dgram>.

=cut
