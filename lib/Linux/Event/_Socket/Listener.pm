package Linux::Event::_Socket::Listener;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent qw(
    Linux::Event::_Socket
    Linux::Event::Listener
);

1;

__END__

=head1 NAME

Linux::Event::_Socket::Listener - private listening C<SOCK_STREAM> boundary

=head1 DESCRIPTION

This package is internal. During migration it bridges the corrected socket
architecture to the proven listen/accept implementation without making a
listener inherit connected byte-stream behavior.

=cut
