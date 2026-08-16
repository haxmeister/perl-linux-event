package Linux::Event::Listener;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_024';

use Carp qw(croak);
use parent 'Linux::Event::Listen';

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

Linux::Event::Listener - accepting Watcher that constructs Stream instances

=head1 SYNOPSIS

  my $listener = EchoStream->listen(
      host => '0.0.0.0',
      port => 7000,
  );

  $loop->add($listener);

=head1 DESCRIPTION

Listener uses the native accept engine from L<Linux::Event::Listen>, constructs
the configured Stream subclass for every accepted connection, and attaches the
Stream to the same Loop. The common API never exposes accepted socket setup.

For per-connection construction policy, the Stream class may define
C<accepted_stream_options($class, $listener, $peer)> and return additional
constructor options such as C<data> or a fresh server transport provider.

=cut
