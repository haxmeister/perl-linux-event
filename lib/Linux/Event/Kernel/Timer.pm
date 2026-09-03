package Linux::Event::Kernel::Timer;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Timer';

1;

__END__

=head1 NAME

Linux::Event::Kernel::Timer - Linux::Event timer abstraction

=head1 DESCRIPTION

This class is the timer leaf of the corrected Kernel namespace. It preserves
Linux::Event timer semantics while the implementation remains backed by the
existing timerfd-driven scheduler.

=cut
