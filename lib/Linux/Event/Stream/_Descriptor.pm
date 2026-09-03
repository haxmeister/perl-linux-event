package Linux::Event::Stream::_Descriptor;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use Linux::Event::_ByteStream::Descriptor ();

sub _validate_xs_spec ($spec) {
    return Linux::Event::_ByteStream::Descriptor::_validate_xs_spec($spec);
}

sub declare_framer ($base, $target, $definition) {
    return Linux::Event::_ByteStream::Descriptor::declare_framer(
        $base, $target, $definition,
    );
}

sub declare_consumer ($base, $target, $definition) {
    return Linux::Event::_ByteStream::Descriptor::declare_consumer(
        $base, $target, $definition,
    );
}

sub for_class ($class) {
    return Linux::Event::_ByteStream::Descriptor::for_class($class);
}

sub clear_cache () {
    return Linux::Event::_ByteStream::Descriptor::clear_cache();
}

1;

__END__

=head1 NAME

Linux::Event::Stream::_Descriptor - temporary private migration shim

=head1 DESCRIPTION

Descriptor storage and validation now live in
L<Linux::Event::_ByteStream::Descriptor>. This package remains only while the
old Stream implementation and its XS wrapper are migrated to the corrected
private byte-stream namespace.

It is not a public API.

=cut
