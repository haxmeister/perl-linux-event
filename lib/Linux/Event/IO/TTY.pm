package Linux::Event::IO::TTY;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Stream';

1;

__END__

=head1 NAME

Linux::Event::IO::TTY - ordered byte I/O over terminal handles

=head1 DESCRIPTION

This class is the public terminal-oriented leaf of the corrected Linux::Event
I/O taxonomy. It currently delegates to the proven byte-stream implementation
while that implementation is moved behind private architecture layers.

A TTY object may have C<read_fh>, C<write_fh>, or both. The two directions may
use different handles, such as standard input and standard output associated
with the same logical terminal interaction.

=cut
