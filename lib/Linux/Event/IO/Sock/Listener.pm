package Linux::Event::IO::Sock::Listener;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Listener';

1;

__END__

=head1 NAME

Linux::Event::IO::Sock::Listener - listening Linux C<SOCK_STREAM> socket

=head1 DESCRIPTION

This class is the public listening-socket leaf of the corrected Linux::Event
I/O taxonomy. It remains distinct from L<Linux::Event::IO::Sock::Stream>
because Linux::Event exposes an accept-oriented listener API rather than the
connected byte-stream API on listening sockets.

Namespace placement records that the object is a socket role; it does not
require Listener to inherit connected-stream behavior.

=cut
