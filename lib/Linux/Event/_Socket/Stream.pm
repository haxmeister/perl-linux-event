package Linux::Event::_Socket::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent qw(
    Linux::Event::_Socket
    Linux::Event::Socket
);

sub transition_to ($self, $class, %option) {
    Linux::Event::_IO::_guard_transition_resource_kind($self, $class);
    return Linux::Event::Stream::transition_to($self, $class, %option);
}

1;

__END__

=head1 NAME

Linux::Event::_Socket::Stream - private C<SOCK_STREAM> implementation boundary

=head1 DESCRIPTION

This package is internal. It joins the private socket classification with the
proven connected C<SOCK_STREAM> implementation hosted under the historical
C<Linux::Event::Socket> package name. That historical package is retained as a
private implementation/ABI host and is not an application subclassing API.

Protocol transitions may change the application protocol subclass but remain
on the same connected C<SOCK_STREAM> resource kind.

The public leaf is L<Linux::Event::IO::Sock::Stream>.

=cut