package Linux::Event::Connector;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_024';

use parent 'Linux::Event::Connect';

1;

__END__

=head1 NAME

Linux::Event::Connector - advanced outbound socket-acquisition Watcher

=head1 DESCRIPTION

This is the noun-named public form of L<Linux::Event::Connect>. Most
applications should use C<< MyStream->connect(...) >> so one Stream object
retains its identity from connection setup through established I/O.

=cut
