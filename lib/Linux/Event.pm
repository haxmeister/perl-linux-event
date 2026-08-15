package Linux::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_011';

1;

__END__

=head1 NAME

Linux::Event - Linux-native event reactor and stream processing foundation

=head1 SYNOPSIS

  use Linux::Event::XSLoop;
  use Linux::Event::Stream;

  my $loop = Linux::Event::XSLoop->new;

=head1 DESCRIPTION

Linux::Event is a Linux-only event and stream-processing distribution.  The
low-level C<Linux::Event::XSLoop> reactor reports readiness through epoll, while
C<Linux::Event::Stream> subclasses own buffered byte-stream I/O, write
backpressure, and optional native framing.

The APIs deliberately remain layered.  Applications that need raw descriptor
readiness can use the reactor directly.  Applications that want automatic
socket reads, buffered writes, and native message framing can use a Stream
subclass on top.

=head1 MAIN MODULES

=over 4

=item * L<Linux::Event::XSLoop>

XS-first epoll reactor and native watcher registry.

=item * L<Linux::Event::XSWatcher>

Native watcher handles returned by the reactor.

=item * L<Linux::Event::Stream>

High-level buffered byte streams with native read/write engines.

=item * L<Linux::Event::Stream::Framer>

Guide to selecting a framing strategy for message-oriented protocols.

=back

=head1 PLATFORM

Linux only.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
