package Linux::Event::Stream::Framer::U32BE;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::Stream::Framer::LengthPrefix';
use Carp qw(croak);

sub new ($class, %opt) {
    croak 'bytes is fixed at 4 for U32BE' if exists $opt{bytes};
    croak 'endian is fixed at big for U32BE' if exists $opt{endian};
    return $class->SUPER::new(%opt, bytes => 4, endian => 'big');
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer::U32BE - 32-bit big-endian length-prefix framing

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $framer = Linux::Event::Stream::Framer->u32be;

=head1 DESCRIPTION

The normal user-facing constructor is provided by L<Linux::Event::Stream::Framer>. This concrete class remains available for subclassing and direct implementation-level use.

Convenience built-in for the common wire format consisting of a 4-byte unsigned
big-endian payload length followed by that many payload bytes. It shares the
native length-prefix implementation with C<LengthPrefix>.

=head1 OPTIONS

Supports C<include_prefix> and C<max_frame> from
L<Linux::Event::Stream::Framer::LengthPrefix>. Width and byte order are fixed.

=cut
