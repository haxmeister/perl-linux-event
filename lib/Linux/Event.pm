package Linux::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_024';

1;

__END__

=head1 NAME

Linux::Event - Linux-native event reactor and stream processing foundation

=head1 SYNOPSIS

  use Linux::Event::Loop;
  use Linux::Event::Stream;

  my $loop = Linux::Event::Loop->new;
  $loop->add(MyStream->connect(host => '127.0.0.1', port => 9999));
  $loop->run;

=head1 DESCRIPTION

Linux::Event is a Linux-only event and stream-processing distribution.  The
the XS-first C<Linux::Event::Loop> reactor owns Watchers. Stream subclasses are
Watchers that own buffered byte-stream I/O, connection lifecycle, write
backpressure, optional native framing, and optional TLS transport.

The APIs deliberately remain layered.  Applications that need raw descriptor
readiness can use the reactor directly.  Applications that want automatic
socket reads, buffered writes, and native message framing can use a Stream
subclass on top.

=head1 MAIN MODULES

=over 4

=item * L<Linux::Event::Loop>

XS-first epoll reactor and native watcher registry.

=item * L<Linux::Event::Watcher>

Base lifecycle contract for every object accepted by C<< $loop->add >>.

=item * L<Linux::Event::IO>

Raw descriptor Watchers returned by C<< $loop->watch >>.

=item * L<Linux::Event::Stream>

High-level buffered byte streams with native read/write engines.

=item * L<Linux::Event::Connector>

Advanced standalone outbound socket acquisition. Ordinary outbound connections
use C<< MyStream->connect >>.

=item * L<Linux::Event::Listener>

Native inbound acquisition and automatic Stream construction.

=item * L<Linux::Event::TLS>

OpenSSL client/server transport provider for Stream.

=item * L<Linux::Event::Stream::Framer>

Guide to selecting a framing strategy for message-oriented protocols.

=back

=head1 PLATFORM

Linux only.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
