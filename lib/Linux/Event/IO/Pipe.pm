package Linux::Event::IO::Pipe;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Stream';

1;

__END__

=head1 NAME

Linux::Event::IO::Pipe - ordered byte I/O over pipe-like handles

=head1 DESCRIPTION

This class is the public pipe-oriented leaf of the corrected Linux::Event I/O
taxonomy. It currently delegates to the proven byte-stream implementation while
that implementation is moved behind private architecture layers.

A pipe object may have C<read_fh>, C<write_fh>, or both. The two directions may
use different descriptors. Anonymous pipes, FIFOs, and child-process pipe pairs
are the intended facilities.

=cut
