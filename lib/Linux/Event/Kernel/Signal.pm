package Linux::Event::Kernel::Signal;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Signal';

1;

__END__

=head1 NAME

Linux::Event::Kernel::Signal - Linux::Event signal abstraction

=head1 DESCRIPTION

This class is the signal leaf of the corrected Kernel namespace. It preserves
Linux::Event signal subscription and callback semantics while the implementation
remains backed by signalfd and the Loop's native fan-out machinery.

=cut
