package Linux::Event::Socket;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use parent 'Linux::Event::Stream';
use Carp qw(croak);
use Scalar::Util qw(blessed);
use Socket qw(SOL_SOCKET SO_ERROR SO_TYPE SOCK_STREAM SHUT_RD SHUT_WR);

use Linux::Event::Address;
use Linux::Event::Error;
use Linux::Event::Socket::_Connection ();
use Linux::Event::Socket::_Descriptor ();
use Linux::Event::_SocketConfig ();

sub _declare_tls ($base, $target, $definition) {
    Linux::Event::Socket::_Descriptor::declare_tls($base, $target, $definition);
}

sub _socket_type ($fh) {
    my $packed = getsockopt($fh, SOL_SOCKET, SO_TYPE);
    croak 'new(): fh is not a socket' if !defined($packed) || length($packed) < 4;
    croak 'new(): fh is not a SOCK_STREAM socket'
        if unpack('i', $packed) != SOCK_STREAM;
    return;
}

sub _socket_setup ($fh, $descriptor, $override, $peer) {
    _socket_type($fh);
    my $packed_local = getsockname($fh);
    croak 'new(): could not obtain local socket address'
        if !defined $packed_local;
    my $local = Linux::Event::Address->new($packed_local);
    my %policy = map {
        $_ => exists($override->{$_})
            ? $override->{$_} : $descriptor->{options}{$_}
    } Linux::Event::_SocketConfig::names();
    Linux::Event::_SocketConfig::apply_policy(
        $fh, $local->family_number, \%policy,
    );
    if (!defined $peer) {
        my $packed_peer = getpeername($fh);
        $peer = Linux::Event::Address->new($packed_peer)
            if defined $packed_peer;
    }
    croak 'new(): fh is not a connected SOCK_STREAM socket' if !defined $peer;
    return ($local, $peer, \%policy);
}

sub new ($class, %opt) {
    croak 'new(): must be called as a class method' if ref $class;
    my $loop = delete $opt{loop};
    croak 'new(): loop must be an object implementing add() and watch_fd()'
        if defined($loop) && (!ref($loop) || !$loop->can('add')
            || !$loop->can('watch_fd'));
    my $fh = delete $opt{fh};
    croak 'new(): Socket requires fh' if !defined($fh) || !defined(fileno($fh));
    croak 'new(): Socket does not accept read_fh or write_fh'
        if exists($opt{read_fh}) || exists($opt{write_fh});
    my $accepted = delete($opt{_accepted}) // 0;
    my $peer = delete $opt{peer};
    my $tls_role = delete $opt{tls_role};
    my $transport = delete $opt{transport};
    croak 'new(): transport must be an object implementing _stream_transport_bind()'
        if defined($transport)
        && (!blessed($transport) || !$transport->can('_stream_transport_bind'));
    croak 'new(): tls_role cannot be combined with accepted mode'
        if $accepted && defined $tls_role;
    my $override = Linux::Event::_SocketConfig::extract('new', \%opt);
    my $socket_descriptor = Linux::Event::Socket::_Descriptor::for_class($class);
    my ($local, $resolved_peer, $policy) = _socket_setup(
        $fh, $socket_descriptor, $override, $peer,
    );
    if (my $tls = $socket_descriptor->{tls}) {
        croak 'new(): transport cannot be supplied for a TLS-declared Socket'
            if defined $transport;
        require Linux::Event::TLS;
        my $role = $accepted ? 'server' : $tls_role;
        croak 'new(): a TLS-declared adopted fh requires tls_role'
            if !defined $role;
        croak 'new(): tls_role must be client or server'
            if $role ne 'client' && $role ne 'server';
        $transport = $role eq 'server'
            ? Linux::Event::TLS->_server_from_declaration($tls)
            : Linux::Event::TLS->_client_from_declaration($tls);
    } elsif (defined $tls_role) {
        croak 'new(): tls_role requires a Socket subclass declaring TLS';
    }
    my $self = $class->SUPER::new(fh => $fh, _transport => $transport, %opt);
    $self->{socket_descriptor} = $socket_descriptor;
    $self->{socket_policy} = $policy;
    $self->{local} = $local;
    $self->{peer} = $resolved_peer;
    my $configured = eval {
        $self->_configure_socket(
            $fh, $accepted ? 'accepted' : 'adopted', $resolved_peer,
        );
        $self->_attach_to_loop($loop) if $loop;
        1;
    };
    if (!$configured) {
        my $failure = $@;
        eval { $self->close; 1 };
        die $failure;
    }
    return $self;
}

sub connect ($class, %opt) {
    croak 'connect(): must be called as a class method' if ref $class;
    my %stream;
    for my $name (qw(loop data transport idle_timeout read_timeout write_timeout deadline)) {
        $stream{$name} = delete $opt{$name} if exists $opt{$name};
    }
    my $loop = delete $stream{loop};
    croak 'connect(): loop must be an object implementing add() and watch_fd()'
        if defined($loop) && (!ref($loop) || !$loop->can('add')
            || !$loop->can('watch_fd'));
    my $override = Linux::Event::_SocketConfig::extract('connect', \%opt);
    my $socket_descriptor = Linux::Event::Socket::_Descriptor::for_class($class);
    my %policy = map {
        $_ => exists($override->{$_}) ? $override->{$_}
            : $socket_descriptor->{options}{$_}
    } Linux::Event::_SocketConfig::names();
    my $transport = delete $stream{transport};
    croak 'connect(): transport must be an object implementing _stream_transport_bind()'
        if defined($transport)
        && (!blessed($transport) || !$transport->can('_stream_transport_bind'));
    if (my $tls = $socket_descriptor->{tls}) {
        croak 'connect(): transport cannot be supplied for a TLS-declared Socket'
            if defined $transport;
        require Linux::Event::TLS;
        $transport = Linux::Event::TLS->_client_from_declaration(
            $tls, $opt{host},
        );
    }
    my $self = $class->SUPER::new(
        %stream, _pending => 1, _transport => $transport,
    );
    $self->{socket_descriptor} = $socket_descriptor;
    $self->{socket_policy} = \%policy;
    $self->{preconnect_output} = [];
    $self->{preconnect_bytes} = 0;
    $self->{read_capable} = 1;
    $self->{write_capable} = 1;
    $self->{write_ended} = 0;
    $self->{read_closed} = 0;
    $self->{connection} = Linux::Event::Socket::_Connection->new(
        %opt, stream => $self, socket_policy => \%policy,
    );
    $self->_attach_to_loop($loop) if $loop;
    return $self;
}

sub _validate_accepted_configuration ($class) {
    my $descriptor = Linux::Event::Socket::_Descriptor::for_class($class);
    if (my $tls = $descriptor->{tls}) {
        require Linux::Event::TLS;
        Linux::Event::TLS->_server_from_declaration($tls);
    }
    return;
}

sub _configure_socket ($self, $fh, $role, $address) {
    my $callback = $self->{socket_descriptor}{configure_socket} or return;
    my $ok = eval { $callback->($self, $fh, $role, $address); 1 };
    return if $ok;
    my $message = "$@";
    $message =~ s/\s+\z//;
    die Linux::Event::Error->new(
        type => 'socket_configuration', operation => 'configure_socket',
        message => $message || 'configure_socket callback failed',
    );
}

sub _attach_pending ($self, $loop) {
    $self->{connection}->_attach_to_loop($loop);
    return;
}

sub _cancel_pending ($self) {
    if (my $connection = delete $self->{connection}) { $connection->cancel }
    return;
}

sub _connect_succeeded ($self, $fh) {
    return if $self->{closed};
    delete $self->{connection};
    my $packed_local = getsockname($fh);
    $self->{local} = Linux::Event::Address->new($packed_local);
    my $packed_peer = getpeername($fh);
    $self->{peer} = Linux::Event::Address->new($packed_peer)
        if defined $packed_peer;
    $self->{read_fh} = $fh;
    $self->{write_fh} = $fh;
    my $prepared = eval { $self->_prepare_handles; $self->_register_handles; 1 };
    if (!$prepared) {
        $self->_fail(Linux::Event::Error->new(
            type => 'connect', operation => 'attach', message => $@,
        ));
        return;
    }
    my $transport = $self->{transport};
    if ($transport && $transport->can('_stream_transport_start')) {
        my $started = eval { $transport->_stream_transport_start($self); 1 };
        if (!$started) {
            $self->_fail(Linux::Event::Error->new(
                type => 'transport', operation => 'start', message => $@,
            ));
            return;
        }
    }
    $self->_flush_preconnect_output;
    if (!$transport) {
        $self->_start_stream_deadlines;
        $self->_fire_ready;
    }
    return;
}

sub _connect_failed ($self, $error) {
    return if $self->{closed};
    delete $self->{connection};
    $self->_fail($error);
}

sub _on_read_terminal_ready ($self) {
    return if $self->{closed};
    my $packed = getsockopt($self->fh, SOL_SOCKET, SO_ERROR);
    if (defined($packed) && length($packed) >= 4) {
        my $errno = unpack('i', $packed);
        if ($errno) { $self->_fail_io('socket', $errno); return }
    }
    $self->SUPER::_on_read_terminal_ready;
}

sub _finish_transport_write ($self) {
    if (!$self->{transport_shutdown_started}++ && $self->{transport}
        && $self->{transport}->can('_stream_transport_begin_shutdown')) {
        my $ok = eval {
            $self->{transport}->_stream_transport_begin_shutdown($self); 1;
        };
        if (!$ok) {
            $self->_fail(Linux::Event::Error->new(
                type => $self->transport_name, operation => 'shutdown',
                message => $@ || 'transport shutdown setup failed',
            ));
            return 0;
        }
    }
    my ($status, $errno, $message) = $self->{xs_state}->_shutdown_write;
    if ($status == 2) { $self->{read_watcher}->enable_read; return 0 }
    if ($status == 3) { $self->{write_watcher}->enable_write; return 0 }
    if ($status == 5) {
        if (($self->transport_name // 'plain') ne 'plain') {
            $self->_fail(Linux::Event::Error->new(
                type => $self->transport_name, operation => 'shutdown',
                message => $message || 'transport shutdown failed',
            ));
        } else {
            $self->_fail_io('shutdown', $errno);
        }
        return 0;
    }
    return 1;
}

sub close_read ($self) {
    return $self if $self->{closed} || $self->{read_closed} || $self->{read_eof};
    croak 'close_read(): directional close is unavailable for TLS sockets'
        if ($self->transport_name // 'plain') ne 'plain';
    shutdown($self->fh, SHUT_RD) or do {
        my $errno = 0 + $!;
        $self->_fail_io('shutdown_read', $errno);
        return $self;
    };
    return $self->SUPER::close_read;
}

sub close_write ($self) {
    return $self if $self->{closed} || $self->{write_ended};
    croak 'close_write(): use end() for TLS sockets'
        if ($self->transport_name // 'plain') ne 'plain';
    shutdown($self->fh, SHUT_WR) or do {
        my $errno = 0 + $!;
        $self->_fail_io('shutdown_write', $errno);
        return $self;
    };
    return $self->SUPER::close_write;
}

sub detach ($self) {
    my $handles = $self->SUPER::detach;
    return $handles->{read_fh};
}

sub local ($self) { $self->{local} }
sub peer ($self) { $self->{peer} }
sub fd ($self) { $self->read_fd }

sub _socket_option ($self, $name, @argument) {
    croak "$name(): Socket is not established" if $self->{closed} || !$self->fh;
    croak "$name(): expected zero or one argument" if @argument > 1;
    my $family = $self->{local}->family_number;
    Linux::Event::_SocketConfig::set_option(
        $self->fh, $family, $name, $argument[0],
    ) if @argument;
    return Linux::Event::_SocketConfig::get_option($self->fh, $family, $name);
}

sub tcp_nodelay ($self, @arg) { $self->_socket_option('tcp_nodelay', @arg) }
sub keepalive ($self, @arg) { $self->_socket_option('keepalive', @arg) }
sub keepalive_idle ($self, @arg) { $self->_socket_option('keepalive_idle', @arg) }
sub keepalive_interval ($self, @arg) { $self->_socket_option('keepalive_interval', @arg) }
sub keepalive_count ($self, @arg) { $self->_socket_option('keepalive_count', @arg) }
sub tcp_user_timeout ($self, @arg) { $self->_socket_option('tcp_user_timeout', @arg) }
sub send_buffer ($self, @arg) { $self->_socket_option('send_buffer', @arg) }
sub receive_buffer ($self, @arg) { $self->_socket_option('receive_buffer', @arg) }

sub selected_alpn ($self) { my $t = $self->{transport}; $t && $t->can('selected_alpn') ? $t->selected_alpn : undef }
sub tls_protocol ($self) { my $t = $self->{transport}; $t && $t->can('protocol') ? $t->protocol : undef }
sub tls_cipher ($self) { my $t = $self->{transport}; $t && $t->can('cipher') ? $t->cipher : undef }
sub tls_stats ($self) { my $t = $self->{transport}; $t && $t->can('stats') ? $t->stats : undef }

sub CLONE ($class) { Linux::Event::Socket::_Descriptor::clear_cache(); return }
sub CLONE_SKIP ($class) { 1 }

1;

__END__
=head1 NAME

Linux::Event::Socket - connected stream-socket specialization of Stream

=head1 SYNOPSIS

An outbound framed protocol:

  package Client;
  use parent 'Linux::Event::Socket';
  use Linux::Event::Framer 'Delimiter', "\n";

  sub on_ready ($socket) {
      $socket->send('hello');
  }

  sub on_message ($socket, $message) {
      process_message($message);
  }

  package main;
  my $client = Client->connect(
      loop => $loop,
      host => '127.0.0.1',
      port => 9999,
  );

Adopt an already-connected stream socket:

  my $socket = Client->new(
      loop => $loop,
      fh   => $connected_socket,
      data => $state,
  );

=head1 DESCRIPTION

C<Linux::Event::Socket> inherits L<Linux::Event::Stream> and adds only
connected C<SOCK_STREAM> behavior: validation, outbound connection acquisition,
local and peer addresses, local binding, socket policy, kernel half-close, and
TLS transport semantics.

The native read, write, framing, batching, backpressure, deadline, and consumer
engine remains in Stream and is not duplicated. Socket accepts one shared
socket handle. Generic handles, split read/write pairs, pipes, terminals, and
process standard I/O belong directly to L<Linux::Event::Stream>.

C<Linux::Event::Socket> is a base class. Applications construct subclasses
whose callbacks and framing describe one protocol type.

=head1 DEFINING A SOCKET TYPE

Socket subclasses use the same raw and framed callback model as Stream:

  package EchoSocket;
  use parent 'Linux::Event::Socket';
  use Linux::Event::Framer 'Delimiter', "\n";

  sub on_message ($socket, $message) {
      $socket->send($message);
  }

Generic buffering policy remains in C<stream_options>. Socket acquisition policy
belongs in the separate C<socket_options> method. Both descriptors are cached
once per class.

=head1 CONSTRUCTION

=head2 new(fh => $socket)

Adopts an already-connected C<SOCK_STREAM> socket. The handle must have both a
local address and a peer address. Datagram sockets, listening sockets,
unconnected sockets, and non-socket handles are rejected.

C<read_fh> and C<write_fh> are not accepted by Socket. Use generic
L<Linux::Event::Stream> when the directions use different handles.

C<loop> attaches immediately, and C<data> stores application state. Generic
Stream timeout and deadline overrides are accepted. Socket options supplied to
C<new> override C<socket_options> for this instance.

An advanced caller may supply C<transport =E<gt> $provider> for an established
socket. The provider must implement the published native Stream transport
binding contract. It cannot be combined with a class-declared TLS transport.

A TLS-declared adopted socket also requires
C<tls_role =E<gt> 'client'> or C<tls_role =E<gt> 'server'>. Listener supplies
the server role internally for accepted sockets.

=head2 connect

  my $socket = Client->connect(
      loop         => $loop,
      host         => 'example.com',
      port         => 443,
      timeout      => 10,
      local_host   => '192.0.2.10',
      local_port   => 0,
      tcp_nodelay  => 1,
      data         => $state,
  );

Returns one Socket object that survives resolution, nonblocking connection
attempts, optional TLS negotiation, established I/O, and close. Supply C<loop>
to start immediately, or attach later with
C<< $loop->add($socket) >>. Writes may be queued before attachment or
connection readiness.

Exactly one remote form is required:

=over 4

=item * C<host> and C<port>

Resolve and connect to a TCP endpoint. Resolution uses the Loop's private
native worker pool, and staggered IPv6/IPv4 attempts are nonblocking.

=item * C<unix =E<gt> $path>

Connect to a Unix stream socket.

=item * C<sockaddr =E<gt> $packed, family =E<gt> $family>

Connect to a caller-packed address.

=back

C<timeout> is the connection deadline in seconds, defaults to 10, and may be
zero to disable it. C<local_host> and C<local_port> select a TCP source address
and port. C<bind_device> constrains an outbound socket to a Linux interface and
may require privilege.

C<data>, C<idle_timeout>, C<read_timeout>, C<write_timeout>, and C<deadline>
are generic Stream instance policy. Socket option overrides are applied to
every outbound candidate before local bind and remote connect.

C<transport =E<gt> $provider> retains an explicit native transport provider
and binds it after a candidate connects. It cannot be combined with a
class-declared TLS transport.

A Socket subclass declaring L<Linux::Event::TLS> automatically selects the
client role and defaults certificate hostname verification and SNI from
C<host>.

=head1 LISTENER ACCEPTANCE

L<Linux::Event::Listener> requires C<stream_class> to name a Socket subclass.
It constructs each accepted connection through the same Socket setup path,
applies socket policy before transport setup, supplies the peer address, and
selects the TLS server role when applicable.

  my $listener = Linux::Event::Listener->new(
      loop         => $loop,
      stream_class => 'EchoSocket',
      host         => '0.0.0.0',
      port         => 9999,
  );

=head1 SOCKET POLICY

A subclass may define C<socket_options>:

  sub socket_options ($class) {
      return (
          tcp_nodelay        => 1,
          keepalive          => 1,
          keepalive_idle     => 60,
          keepalive_interval => 10,
          keepalive_count    => 5,
          tcp_user_timeout   => 15,
          send_buffer        => 262_144,
          receive_buffer     => 262_144,
      );
  }

The method runs once when the cached Socket descriptor is built. Constructor or
C<connect> values override class policy. An option omitted from both places is
left unchanged rather than replaced by a library default.

C<tcp_nodelay>, C<keepalive_idle>, C<keepalive_interval>,
C<keepalive_count>, and C<tcp_user_timeout> require a TCP socket.
C<keepalive>, C<send_buffer>, and C<receive_buffer> also apply where supported
to Unix stream sockets. Public timeout values are seconds;
C<tcp_user_timeout> is converted to the Linux millisecond kernel value.

=head1 CONFIGURATION HOOK

An advanced subclass may define:

  sub configure_socket ($socket, $fh, $role, $address) {
      ...
  }

The cached callback runs after built-in policy for each socket and before
transport setup. C<$role> is C<connect>, C<accepted>, or C<adopted>.
C<$address> is the remote candidate or peer when known. An exception becomes a
C<socket_configuration> L<Linux::Event::Error>; configuration never falls back
silently.

=head1 CALLBACKS AND FRAMING

Socket inherits all Stream callbacks, framing declarations, batching modes,
limits, backpressure, and established deadlines. See
L<Linux::Event::Stream/CALLBACKS> and L<Linux::Event::Framer>.

C<on_ready> runs after a plain outbound connection or TLS handshake is ready
for application traffic. Accepted plain sockets are ready after Listener
attachment. C<on_transport_ready> is the lower-level provider notification and
normally need not be implemented by applications.

=head1 LIFECYCLE

Read and write remain independent as documented by
L<Linux::Event::Stream/DIRECTIONAL LIFECYCLE>.

For a plain Socket, C<end> drains queued output and then performs
C<shutdown(SHUT_WR)>. Peer EOF ends only input, so remaining output may still
be written. C<close_read> and C<close_write> immediately use
C<shutdown(SHUT_RD)> and C<shutdown(SHUT_WR)> respectively. C<close> closes the
socket immediately.

C<detach> requires an established plain transport and an empty output queue.
It cancels Socket ownership and returns the one shared socket handle rather
than Stream's directional hash reference.

TLS uses provider shutdown and C<close_notify> for graceful C<end>. Immediate
directional close is rejected for TLS because it would bypass the provider's
wire lifecycle.

=head1 SOCKET METHODS

All generic methods are inherited from L<Linux::Event::Stream>. The following
methods are Socket-specific or specialize the generic result.

=head2 connect

Class method described in L</CONSTRUCTION>. Generic Stream does not provide
outbound connection acquisition.

=head2 fh / fd

Return the shared socket handle and descriptor number.

=head2 local / peer

Return lazy L<Linux::Event::Address> values for the local and peer socket
addresses.

=head2 tcp_nodelay / keepalive / keepalive_idle / keepalive_interval / keepalive_count / tcp_user_timeout

With no argument, return the current effective Linux socket value. With one
argument, update the option and return the value read back from the kernel.
TCP-only accessors reject Unix sockets.

=head2 send_buffer / receive_buffer

With no argument, return the effective socket-buffer size. With one argument,
request a new size and return the kernel value read back. Linux may round or
double buffer requests.

=head2 selected_alpn / tls_protocol / tls_cipher / tls_stats

Return negotiated TLS details when a TLS transport is active. The scalar
methods return undef for a plain Socket; C<tls_stats> likewise returns undef
without an active TLS provider.

=head2 close_read / close_write / detach

Specialize the inherited generic lifecycle with socket C<shutdown> and the
single-handle detach return described above.

=head1 TLS

TLS is declared only after Socket inheritance:

  package SecureClient;
  use parent 'Linux::Event::Socket';
  use Linux::Event::TLS
      ca_file => '/etc/ssl/certs/ca-certificates.crt',
      verify  => 1,
      alpn    => ['http/1.1'];

The same declaration becomes a server policy when a Listener accepts the
subclass; server use requires certificate and key configuration. See
L<Linux::Event::TLS> for declaration options, role selection, verification,
handshake deadlines, and shutdown behavior.

TLS belongs to Socket transport acquisition. Framing still belongs to generic
Stream and operates on plaintext bytes above the active transport.

=head1 ERRORS

Connection, resolver, bind, socket configuration, TLS, and established I/O
failures are reported through the inherited C<on_error> callback as
L<Linux::Event::Error> values, then close the Socket.

=head1 PERFORMANCE

Socket adds policy only at acquisition and lifecycle boundaries. Established
plain and TLS traffic uses the inherited native Stream state, parser, direct
write path, segmented queue, and transient writable readiness. There is no
second socket-specific read, write, or framing engine.

=cut
