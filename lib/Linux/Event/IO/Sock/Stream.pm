package Linux::Event::IO::Sock::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Socket';

1;

__END__

=head1 NAME

Linux::Event::IO::Sock::Stream - Linux C<SOCK_STREAM> I/O

=head1 DESCRIPTION

This class is the public C<SOCK_STREAM> leaf of the corrected Linux::Event I/O
taxonomy. IPv4, IPv6, and Unix-domain stream sockets share this class; socket
family is configuration rather than a different public type.

The class currently delegates to the proven connected-socket implementation
while byte-stream and socket responsibilities are moved behind private layers.

=cut
