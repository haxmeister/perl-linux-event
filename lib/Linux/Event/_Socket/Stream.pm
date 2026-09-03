package Linux::Event::_Socket::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent qw(
    Linux::Event::_Socket
    Linux::Event::Socket
);

1;

__END__

=head1 NAME

Linux::Event::_Socket::Stream - private C<SOCK_STREAM> implementation boundary

=head1 DESCRIPTION

This package is internal. During migration it bridges the corrected socket
architecture to the proven connected C<SOCK_STREAM> implementation. Later
commits may move that implementation behind this boundary without changing the
public L<Linux::Event::IO::Sock::Stream> leaf.

=cut
