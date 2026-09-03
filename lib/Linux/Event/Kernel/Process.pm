package Linux::Event::Kernel::Process;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Process';

1;

__END__

=head1 NAME

Linux::Event::Kernel::Process - Linux::Event process lifecycle abstraction

=head1 DESCRIPTION

This class is the process leaf of the corrected Kernel namespace. It retains
process observation, spawning, pidfd lifecycle handling, signaling, reaping,
and asynchronous standard-I/O behavior.

=cut
