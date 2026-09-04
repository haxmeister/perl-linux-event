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

Linux::Event::Stream::_Descriptor - private historical descriptor forwarding package

=head1 DESCRIPTION

Ordered-byte descriptor storage and validation live in
L<Linux::Event::_ByteStream::Descriptor>. This historical package forwards to
that implementation because the stable private Stream engine still references
its package name.

It is not a public API and is excluded from distribution indexing.

=cut
