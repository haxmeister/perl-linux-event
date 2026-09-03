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

This package is internal. During migration it bridges the corrected socket
architecture to the proven datagram implementation. Datagram message boundaries
remain kernel-provided and do not use the byte-stream framing layer.

=cut
