package Linux::Event::IO::TTY;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::_ByteStream';
use Carp qw(croak);

sub new ($class, %option) {
    for my $handle (Linux::Event::_IO::_constructor_handles('new', \%option)) {
        my ($name, $fh) = @$handle;
        croak "new(): $name is not a TTY or PTY" if !-t $fh;
    }
    return $class->SUPER::new(%option);
}

1;

__END__

=head1 NAME

Linux::Event::IO::TTY - ordered byte I/O over terminal handles

=head1 DESCRIPTION

This class is the public terminal-oriented leaf of the corrected Linux::Event
I/O taxonomy. Its byte-stream behavior is provided through the private
L<Linux::Event::_ByteStream> implementation boundary.

A TTY object may have C<read_fh>, C<write_fh>, or both. The two directions may
use different handles, such as standard input and standard output associated
with the same logical terminal interaction. Every supplied handle is validated
as a terminal or pseudo-terminal before byte-stream setup.

=cut
