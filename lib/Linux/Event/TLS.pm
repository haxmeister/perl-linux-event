package Linux::Event::TLS;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_026';

use Carp qw(croak);

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

sub _alpn_wire ($protocols) {
    return '' if !defined $protocols;
    croak 'alpn must be an array reference' if ref($protocols) ne 'ARRAY';
    my $wire = '';
    for my $protocol (@$protocols) {
        croak 'each ALPN protocol must be a byte string of 1..255 bytes'
            if !defined($protocol) || ref($protocol)
            || length($protocol) < 1 || length($protocol) > 255;
        $wire .= pack('C', length($protocol)) . $protocol;
    }
    return $wire;
}

sub _timeout ($method, $name, $value, $default) {
    $value = $default if !defined $value;
    croak "$method(): $name must be a non-negative number of seconds"
        if ref($value)
        || $value !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/
        || $value < 0;
    return 0 + $value;
}

sub client ($class, %opt) {
    croak 'client(): must be called as a class method' if ref $class;
    my $server_name = delete $opt{server_name}
        // croak 'client(): missing server_name';
    my $verify = exists $opt{verify} ? delete($opt{verify}) : 1;
    my $ca_file = delete $opt{ca_file};
    my $ca_path = delete $opt{ca_path};
    my $alpn = _alpn_wire(delete $opt{alpn});
    my $handshake_timeout = _timeout(
        'client', 'handshake_timeout', delete($opt{handshake_timeout}), 10,
    );
    my $shutdown_timeout = _timeout(
        'client', 'shutdown_timeout', delete($opt{shutdown_timeout}), 5,
    );
    croak 'client(): unknown options: ' . join(', ', sort keys %opt) if %opt;
    croak 'client(): server_name must be a non-empty string'
        if ref($server_name) || $server_name eq '';
    return $class->_new_client(
        $server_name, $verify ? 1 : 0, $ca_file, $ca_path, $alpn,
        $handshake_timeout, $shutdown_timeout,
    );
}

sub server ($class, %opt) {
    croak 'server(): must be called as a class method' if ref $class;
    my $cert_file = delete $opt{cert_file}
        // croak 'server(): missing cert_file';
    my $key_file = delete $opt{key_file}
        // croak 'server(): missing key_file';
    my $alpn = _alpn_wire(delete $opt{alpn});
    my $handshake_timeout = _timeout(
        'server', 'handshake_timeout', delete($opt{handshake_timeout}), 10,
    );
    my $shutdown_timeout = _timeout(
        'server', 'shutdown_timeout', delete($opt{shutdown_timeout}), 5,
    );
    croak 'server(): unknown options: ' . join(', ', sort keys %opt) if %opt;
    return $class->_new_server(
        $cert_file, $key_file, $alpn,
        $handshake_timeout, $shutdown_timeout,
    );
}

sub _stream_transport_bind ($self, $fd) {
    return $self->_bind_fd($fd);
}

sub _install_deadline ($self, $stream, $operation) {
    my $fd = $self->_arm_deadline($operation);
    return if !defined $fd;
    return if $stream->_has_transport_deadline_watcher;
    my $watcher = $stream->loop->watch(
        fd   => $fd,
        data => {
            provider  => $self,
            stream    => $stream,
        },
        read => \&_deadline_ready,
    );
    $stream->_set_transport_deadline_watcher($watcher);
    return;
}

sub _deadline_ready ($watcher) {
    my $state = $watcher->data;
    my $stream = $state->{stream};
    my $operation = $state->{provider}->_deadline_operation;
    my $message = $state->{provider}->_consume_deadline(
        $operation,
    );
    $stream->_transport_deadline_expired(
        $operation, $message,
    );
    return;
}

sub _stream_transport_start ($self, $stream) {
    $self->_install_deadline($stream, 'handshake');
}

sub _stream_transport_ready ($self, $stream) {
    $stream->_clear_transport_deadline;
}

sub _stream_transport_begin_shutdown ($self, $stream) {
    $self->_install_deadline($stream, 'shutdown');
}

sub _stream_transport_cancel_deadline ($self) {
    $self->_cancel_deadline;
}

sub _stream_transport_close_deadline ($self) {
    $self->_close_deadline;
}

1;

__END__

=head1 NAME

Linux::Event::TLS - OpenSSL transport provider for Linux::Event::Stream

=head1 SYNOPSIS

  my $stream = MyStream->connect(
      loop => $loop,
      host => 'example.com', port => 443,
      transport => Linux::Event::TLS->client(
          server_name => 'example.com',
          alpn        => ['http/1.1'],
      ),
  );

=head1 DESCRIPTION

This module supplies TLS byte transport to C<Linux::Event::Stream> from the
same C<Linux::Event> distribution. Stream continues to own buffering, framing,
backpressure, and descriptor readiness. OpenSSL owns TLS protocol state,
cryptography, certificate verification, ALPN, and close notification.

Each provider is stateful and belongs to exactly one Stream. It uses one
timerfd registration while attached. The timer is
disarmed between the handshake and shutdown phases, reused for both deadlines,
and destroyed with the Stream. This deadline machinery remains outside the
plain Stream path.

Client verification and hostname checking are enabled by default. Passing
C<verify =E<gt> 0> is intended only for explicitly controlled environments.
Clean peer C<close_notify> is reported through ordinary Stream EOF handling.
Socket EOF without C<close_notify> is a typed C<tls> read error.
TLS socket writes use Linux C<MSG_NOSIGNAL>, so an abrupt peer close becomes a
typed Stream error without changing the process-wide C<SIGPIPE> disposition.

=head1 METHODS

=head2 client

Creates a client provider. C<server_name> is required. Optional arguments are
C<ca_file>, C<ca_path>, C<verify>, an array reference C<alpn>,
C<handshake_timeout>, and C<shutdown_timeout>. Timeouts are seconds and default
to 10 and 5 respectively. Zero disables the corresponding deadline.

Verification is enabled by default and checks both the certificate chain and
C<server_name>. C<ca_file> and C<ca_path> override trust-source selection.
C<verify =E<gt> 0> disables peer verification and should be limited to
controlled test or private environments.

=head2 server

Creates a server provider. C<cert_file> and C<key_file> are required. C<alpn>
is optional. C<handshake_timeout> and C<shutdown_timeout> have the same defaults
and zero-disable behavior as the client provider.

Create a fresh provider for every accepted Stream, normally from the Stream
class's C<accepted_stream_options> method.

=head2 selected_alpn

Returns the negotiated ALPN protocol, or undef when none was negotiated.

=head2 protocol

Returns the negotiated TLS protocol name after the handshake.

=head2 cipher

Returns the negotiated cipher name after the handshake.

=head2 stats

Returns native counters for handshake, read, write, shutdown, readiness retry,
clean EOF, unclean EOF, error, and deadline activity.

=head1 STREAM INTEGRATION

TLS is a transport provider, not a Stream subclass and not a framer. Stream
continues to expose plaintext to C<on_data> or C<on_message>, applies framing
above TLS, and manages its ordinary output queue and backpressure. C<on_ready>
runs only after the TLS handshake and verification succeed.

C<< $stream->end >> drains plaintext output and performs TLS shutdown with
C<close_notify>. C<< $stream->close >> is immediate. A TLS Stream cannot be
detached because its socket contains provider-owned encrypted protocol state.

=head1 REQUIREMENTS

Linux and OpenSSL 1.1.1 or newer, including development headers at build time.

=cut
