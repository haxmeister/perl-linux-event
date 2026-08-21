package Linux::Event::Listener;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_028';

use Carp qw(croak);
use parent 'Linux::Event::Listener::_Engine';

sub new ($class, %opt) {
    my $loop = delete $opt{loop};
    croak 'new(): loop must be an object implementing add() and watch()'
        if defined($loop) && (!ref($loop) || !$loop->can('add')
            || !$loop->can('watch'));
    my $stream_class = delete $opt{stream_class}
        // croak 'new(): missing stream_class';
    croak 'new(): stream_class must name a Linux::Event::Stream subclass'
        if ref($stream_class) || !$stream_class->isa('Linux::Event::Stream');

    my $self = $class->SUPER::new(%opt);
    $self->{stream_class} = $stream_class;
    $self->_attach_to_loop($loop) if $loop;
    return $self;
}

sub stream_class ($self) { $self->{stream_class} }

sub on_accept ($self, $fh, $peer) {
    my $class = $self->{stream_class};
    my %option = (fh => $fh, peer => $peer);
    if (my $configure = $class->can('accepted_stream_options')) {
        my @extra = $configure->($class, $self, $peer);
        croak "$class accepted_stream_options() returned an odd option list"
            if @extra % 2;
        my %extra = @extra;
        croak "$class accepted_stream_options() cannot replace fh or peer"
            if exists($extra{fh}) || exists($extra{peer});
        %option = (%option, @extra);
    }
    my $stream = $class->new(%option);
    $stream->_attach_to_loop($self->loop);
    $stream->_fire_ready if !$stream->transport;
    return;
}

sub on_error ($self, $error) {
    my $class = $self->{stream_class};
    if (my $callback = $class->can('on_listener_error')) {
        $callback->($class, $self, $error);
        return;
    }
    die "listener failed: $error\n";
}

1;

__END__

=head1 NAME

Linux::Event::Listener - accepting socket that constructs Stream instances

=head1 SYNOPSIS

  use Linux::Event::Loop;

  my $loop = Linux::Event::Loop->new;
  my $listener = EchoStream->listen(
      loop => $loop,
      host => '0.0.0.0',
      port => 7000,
  );

=head1 DESCRIPTION

Listener creates or adopts a listening TCP or Unix stream socket, drains
accepted connections with native C<accept4>, constructs the configured Stream
subclass for every accepted connection, and attaches each Stream to the same
Loop. Application code never handles accepted descriptors directly.

For per-connection construction policy, the Stream class may define
C<accepted_stream_options($class, $listener, $peer)> and return additional
constructor options such as C<data> or a fresh server transport provider.

=head1 CONSTRUCTION

Applications normally call C<< MyStream->listen(...) >>. This is equivalent to
calling C<< Linux::Event::Listener->new(stream_class =E<gt> 'MyStream', ...) >>
and ensures that each accepted connection uses the calling Stream class.

Every Listener can be attached in either form:

  my $listener = MyStream->listen(loop => $loop, %socket_options);

  my $listener = MyStream->listen(%socket_options);
  $loop->add($listener);

C<< $loop->add >> sets C<loop>, starts accepting, and returns the same Listener.
A Listener may be attached only once and to only one Loop.

=head1 SOCKET SOURCES

Exactly one of these sources is required:

=over 4

=item * C<host =E<gt> $host, port =E<gt> $port>

Creates a TCP listener. C<$host> may be an address, hostname, or C<*> for a
passive wildcard bind. C<port =E<gt> 0> asks the kernel to choose a port;
C<port()> then returns the assigned value.

=item * C<unix =E<gt> $path>

Creates a filesystem Unix stream listener.

=item * C<fh =E<gt> $listening_socket>

Adopts an existing listening socket. Listener sets nonblocking and
close-on-exec flags. It does not close the handle by default; pass
C<owns_socket =E<gt> 1> to transfer ownership.

=back

=head1 OPTIONS

C<loop> optionally attaches immediately. C<data> stores application state.
C<backlog> defaults to 4096. C<max_accept_per_tick> defaults to 256 and bounds
the number of accepts per level-triggered dispatch; zero drains until
C<EAGAIN>. C<edge_triggered =E<gt> 1> requires the zero/unbounded setting.

TCP creation accepts C<reuseaddr> (default true), C<reuseport> (default false),
and optional C<v6only>. Unix creation accepts C<unlink> to replace an existing
socket path, C<unlink_on_close> (default true), and numeric C<permissions>.
Source-specific options are rejected for other source types.

=head1 ACCEPTED STREAMS

Listener uses native C<accept4> with C<SOCK_NONBLOCK> and C<SOCK_CLOEXEC>.
For every success it constructs C<stream_class> with C<fh> and a lazy
L<Linux::Event::Address> C<peer>, attaches the Stream to this Listener's Loop,
and fires readiness for a plain Stream.

The Stream class may customize construction:

  sub accepted_stream_options ($class, $listener, $peer) {
      return data => {
          server_state => $listener->data,
          peer         => $peer,
      };
  }

The result must be an even option list and cannot replace C<fh> or C<peer>.
TLS servers return a fresh C<transport =E<gt> Linux::Event::TLS->server(...)>
provider for each accepted connection.

=head1 ERROR POLICY

Runtime failures are L<Linux::Event::Error> objects. Resource exhaustion pauses
acceptance before notification to prevent an error spin. A Stream class can
define:

  sub on_listener_error ($class, $listener, $error) {
      warn "$error\n";
  }

Without this method Listener dies on a runtime listener failure. Constructor
validation errors throw immediately, and socket-setup failures throw a
structured Error.

=head1 METHODS

=head2 pause / resume

Disable or re-enable acceptance without closing the listening socket. Both
return the Listener.

=head2 close / cancel

Stop accepting, cancel native registration, close an owned handle, and remove
an owned Unix path when configured. C<cancel> is an alias for C<close>.

=head2 detach

Stop accepting and return the still-open listener handle, transferring
ownership to the caller. Returns undef after a terminal state.

=head2 loop / fh / fd / host / port / path / family

Return attachment and bound-socket information. Fields that do not apply to the
socket family are undefined.

=head2 state

Returns C<unattached>, C<listening>, C<paused>, C<closed>, C<failed>, or
C<detached>.

=head2 accepted / last_error / data

Return the cumulative accepted connection count, most recent runtime error,
and optional application value. C<data($new_value)> replaces the value.

=head2 is_paused / is_running / is_terminal

Convenience predicates for the current lifecycle state.

=head1 PERFORMANCE

The Listener class caches its resolved native callbacks. XS drains accept4 in
batches, while Perl is entered only for Stream construction and application
policy. Accepted sockets never receive a temporary public registration before
Stream attachment.

=cut
