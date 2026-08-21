package Linux::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_029';

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
XS-first C<Linux::Event::Loop> reactor owns native descriptor registrations.
Public Stream, Listener, Timer, and Signal objects own their resources and
attach directly to one Loop; they do not inherit from a generic Watcher or IO
class.

The APIs deliberately remain layered.  Applications that need raw descriptor
readiness can use the reactor directly.  Applications that want automatic
socket reads, buffered writes, and native message framing can use a Stream
subclass on top.

Every attachable public object accepts C<loop =E<gt> $loop>. It can instead be
constructed detached and passed to C<< $loop->add($object) >>. C<add> sets the
Loop, starts the object's activity, and returns the same object.

=head1 MAIN MODULES

=over 4

=item * L<Linux::Event::Loop>

XS-first epoll reactor and native watcher registry.

=item * L<Linux::Event::Stream>

Subclass-defined buffered byte streams with connection, framing, backpressure,
half-close, established deadlines, protocol-transition, and transport lifecycle.

=item * L<Linux::Event::Listener>

TCP and Unix listeners that automatically construct a chosen Stream subclass.

=item * L<Linux::Event::Timer>

Subclass-defined one-shot and fixed-rate recurring monotonic timers.

=item * L<Linux::Event::Signal>

Subclass-defined synchronous signalfd subscriptions with native fan-out.

=item * L<Linux::Event::TLS>

OpenSSL client/server transport provider for Stream.

=item * L<Linux::Event::Framer>

Guide to selecting a framing strategy for message-oriented protocols.

=item * L<Linux::Event::Error>

Structured errors shared by Stream, Listener, connection, and transport paths.

=item * L<Linux::Event::Address>

Lazy IPv4, IPv6, and Unix socket-address values.

=back

=head1 PUBLIC MODEL

Applications subclass C<Linux::Event::Stream> to define protocol behavior and
C<Linux::Event::Timer> to define scheduled behavior, and
C<Linux::Event::Signal> to define signal behavior. They do not subclass Loop
registrations. Outbound acquisition is C<< MyStream->connect(...) >>. Inbound
acquisition is C<< Linux::Event::Listener->new(stream_class =E<gt> 'MyStream',
...) >>. TLS is a transport provider passed with C<transport =E<gt>>, not
another kind of Stream.

C<< $loop->watch(...) >> remains available for low-level descriptor readiness.
It immediately returns an opaque native registration handle with methods such
as C<cancel>, C<enable_read>, and C<disable_write>. That handle is not a named
public class or a subclassing contract.

=head1 PLATFORM

Linux only.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
