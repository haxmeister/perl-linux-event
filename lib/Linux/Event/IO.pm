package Linux::Event::IO;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_024';

use parent 'Linux::Event::XSWatcher';

1;

__END__

=head1 NAME

Linux::Event::IO - raw descriptor Watcher

=head1 DESCRIPTION

C<Linux::Event::IO> is the concrete Watcher returned by C<< $loop->watch >>.
It exposes raw readable, writable, and terminal readiness. Most network
applications should use L<Linux::Event::Stream> or L<Linux::Event::Listener>.

=cut
