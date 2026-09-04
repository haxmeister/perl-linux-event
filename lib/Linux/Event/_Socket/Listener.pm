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

This package is internal. It joins the private socket classification with the
proven listen/accept implementation hosted under the historical
C<Linux::Event::Listener> package name. That implementation name is private and
is not an application subclassing API.

A listener deliberately does not inherit connected ordered-byte behavior. The
public leaf is L<Linux::Event::IO::Sock::Listener>.

=cut
