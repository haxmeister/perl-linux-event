package Linux::Event::_IO;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

1;

__END__

=head1 NAME

Linux::Event::_IO - private root for Linux::Event I/O implementation classes

=head1 DESCRIPTION

This package is an internal implementation boundary. It is not a public
subclassing API and applications must not depend on it.

Public I/O classes describe completed Linux I/O facilities. Shared descriptor,
reactor, and lifecycle machinery may be factored through this package while
remaining invisible to application code.

=cut
