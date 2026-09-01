package Linux::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

1;

__END__

=head1 NAME

Linux::Event - Linux-native reactor, streams, datagrams, and processes

=head1 SYNOPSIS

  use Linux::Event::Loop;
  use Linux::Event::Socket;

  my $loop = Linux::Event::Loop->new;
  $loop->add(MySocket->connect(
      host => '127.0.0.1', # required
      port => 9999,        # required
  ));
  $loop->run;

=head1 DESCRIPTION

Linux::Event is a Linux-only asynchronous I/O distribution. The
XS-first C<Linux::Event::Loop> reactor owns native descriptor registrations.
Public Stream, Listener, Datagram, Timer, Signal, Wakeup, and Process objects
own their logical resources and attach directly to one Loop; they do not
inherit from a generic Watcher or IO class.

The APIs deliberately remain layered.  Applications that need raw descriptor
readiness can use the reactor directly. Applications that want automatic
buffered byte I/O and native message framing can use a Stream subclass;
connected socket protocols use a Socket subclass.

Every attachable public object accepts C<loop =E<gt> $loop>. It can instead be
constructed detached and passed to C<< $loop->add($object) >>. C<add> sets the
Loop, starts the object's activity, and returns the same object.

=head1 MAIN MODULES

=over 4

=item * L<Linux::Event::Loop>

XS-first epoll reactor, native watcher registry, query-driven introspection,
and optional profiling.

=item * L<Linux::Event::Stream>

Generic subclass-defined buffered byte streams with one shared handle, split
read/write handles, or either direction alone. Stream owns framing,
backpressure, established deadlines, and directional lifecycle.

=item * L<Linux::Event::Socket>

Connected C<SOCK_STREAM> specialization adding outbound connection, addresses,
socket options, kernel half-close, and TLS transport lifecycle.

=item * L<Linux::Event::Listener>

TCP and Unix listeners that automatically construct a chosen Socket subclass.

=item * L<Linux::Event::Datagram>

Connected and unconnected UDP and Unix datagram sockets that preserve packet
boundaries and peer addresses.

=item * L<Linux::Event::Timer>

Subclass-defined one-shot and fixed-rate recurring monotonic timers.

=item * L<Linux::Event::Signal>

Subclass-defined synchronous signalfd subscriptions with native fan-out.

=item * L<Linux::Event::Wakeup>

Subclass-defined eventfd notifications that foreign threads or forked children
may signal without transferring Perl callbacks or values.

=item * L<Linux::Event::Process>

pidfd lifecycle notification, native process spawning, decoded exit status,
signals, and asynchronous standard I/O.

=item * L<Linux::Event::TLS>

Declarative OpenSSL TLS policy for Socket subclasses.

=item * L<Linux::Event::Framer>

Guide to selecting a framing strategy for message-oriented protocols.

=item * L<Linux::Event::Error>

Structured errors shared by socket, process, connection, and transport paths.

=item * L<Linux::Event::Address>

Lazy IPv4, IPv6, and Unix socket-address values.

=back

=head1 PUBLIC MODEL

Applications subclass C<Linux::Event::Stream> for generic byte handles,
C<Linux::Event::Socket> for connected stream-socket protocols, and
C<Linux::Event::Datagram> for packet-socket behavior,
C<Linux::Event::Timer> to define scheduled behavior,
C<Linux::Event::Signal> to define signal behavior,
C<Linux::Event::Wakeup> to define notification handling, and
C<Linux::Event::Process> to define child lifecycle handling. They do not
subclass Loop registrations. Outbound Socket acquisition is
C<< MySocket->connect(host =E<gt> '127.0.0.1', port =E<gt> 9999) >>. Inbound
Socket acquisition is C<< Linux::Event::Listener->new(stream_class =E<gt>
'MySocket', host =E<gt> '0.0.0.0', port =E<gt> 9999) >>. A Socket subclass
opts into TLS with C<use Linux::Event::TLS>; C<connect> and Listener acceptance
select the client or server handshake role.

C<< $loop->watch(fd =E<gt> $fd, read =E<gt> $callback) >> remains available
for low-level descriptor readiness.
It immediately returns an opaque native registration handle with methods such
as C<cancel>, C<enable_read>, and C<disable_write>. That handle is not a named
public class or a subclassing contract.

=head1 PLATFORM

Linux only. Building the complete distribution requires Linux headers with
pidfd syscall definitions, a Linux 5.4 or newer runtime for pidfd status,
a libc providing C<posix_spawn_file_actions_addchdir_np>, and OpenSSL 1.1.1 or
newer development files. Perl ithreads are not required. Configuration on an
unsupported operating system exits with an C<OS unsupported> result so
automated smoke systems can classify the distribution as not applicable.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
