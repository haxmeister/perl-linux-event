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

Linux::Event::Socket::_Descriptor - private historical socket descriptor forwarding package

=head1 DESCRIPTION

Stream-socket descriptor storage now lives in
L<Linux::Event::_Socket::Descriptor>. This historical package forwards to that
implementation because the stable private socket engine still references its
package name.

It is not a public API and is excluded from distribution indexing.

=cut
