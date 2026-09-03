package Linux::Event::Socket::_Descriptor;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use Linux::Event::_Socket::Descriptor ();

sub declare_tls ($base, $target, $definition) {
    return Linux::Event::_Socket::Descriptor::declare_tls(
        $base, $target, $definition,
    );
}

sub for_class ($class) {
    return Linux::Event::_Socket::Descriptor::for_class($class);
}

sub clear_cache () {
    return Linux::Event::_Socket::Descriptor::clear_cache();
}

1;

__END__

=head1 NAME

Linux::Event::Socket::_Descriptor - temporary private migration shim

=head1 DESCRIPTION

Socket class descriptor storage now lives in
L<Linux::Event::_Socket::Descriptor>. This package remains only while the old
Socket implementation is migrated to the corrected private socket namespace.

It is not a public API.

=cut
