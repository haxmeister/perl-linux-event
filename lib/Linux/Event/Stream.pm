package Linux::Event::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_011';

use Carp qw(croak);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use mro ();
use Socket qw(SHUT_WR SOL_SOCKET SO_ERROR);

use Linux::Event::Stream::Error;

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

my %FRAMER_DEFINITION;
my %CLASS_DESCRIPTOR;

sub _declare_framer ($base, $target, $definition) {
    croak 'a framer may be declared only for a Linux::Event::Stream subclass'
        if $target eq $base || !$target->isa($base);
    croak "$target already has a Stream descriptor"
        if exists $CLASS_DESCRIPTOR{$target};
    croak "$target already declares a framer"
        if exists $FRAMER_DEFINITION{$target};
    $FRAMER_DEFINITION{$target} = $definition;
    return;
}

sub _framer_for ($class) {
    for my $package (@{ mro::get_linear_isa($class) }) {
        return $FRAMER_DEFINITION{$package}
            if exists $FRAMER_DEFINITION{$package};
    }
    return undef;
}

sub _stream_options_for ($class) {
    my %option = (
        high_watermark => 1_048_576,
        low_watermark  =>   262_144,
        read_size      =>    65_536,
        max_buffer     => 8_388_608,
    );

    if (my $configure = $class->can('stream_options')) {
        my @configured = $configure->($class);
        my %configured;
        if (@configured == 1 && ref($configured[0]) eq 'HASH') {
            %configured = %{ $configured[0] };
        } else {
            croak "$class stream_options() returned an odd option list"
                if @configured % 2;
            %configured = @configured;
        }
        my @unknown = grep { !exists $option{$_} } keys %configured;
        croak "$class stream_options() returned unknown options: "
            . join(', ', sort @unknown) if @unknown;
        @option{keys %configured} = values %configured;
    }

    croak "$class high_watermark must be a non-negative integer"
        if $option{high_watermark} !~ /\A\d+\z/;
    croak "$class low_watermark must be a non-negative integer"
        if $option{low_watermark} !~ /\A\d+\z/;
    croak "$class low_watermark must be <= high_watermark"
        if $option{low_watermark} > $option{high_watermark};
    croak "$class read_size must be a positive integer"
        if $option{read_size} !~ /\A\d+\z/ || $option{read_size} <= 0;
    croak "$class max_buffer must be a positive integer"
        if $option{max_buffer} !~ /\A\d+\z/ || $option{max_buffer} <= 0;

    return \%option;
}

sub _descriptor_for ($class) {
    return $CLASS_DESCRIPTOR{$class} if exists $CLASS_DESCRIPTOR{$class};
    croak 'Linux::Event::Stream is a base class; construct a Stream subclass'
        if $class eq __PACKAGE__;
    croak "$class is not a Linux::Event::Stream subclass"
        if !$class->isa(__PACKAGE__);

    my $framer = _framer_for($class);
    my %callback = map { $_ => scalar $class->can($_) }
        qw(on_data on_message on_drain on_eof on_error on_close);

    if ($framer) {
        croak "$class declares a framer but does not define on_message()"
            if !$callback{on_message};
        croak "$class cannot define on_data() when it declares a framer"
            if $callback{on_data};
    } else {
        croak "$class has no framer and must define on_data()"
            if !$callback{on_data};
        croak "$class defines on_message() but does not declare a framer"
            if $callback{on_message};
    }

    my $option = _stream_options_for($class);
    my $native = $framer ? { %{ $framer->{native} } } : { read_mode => 0 };

    my $xs = Linux::Event::Stream::XSDescriptor->new(
        $option->{read_size},
        $option->{high_watermark},
        $option->{low_watermark},
        $option->{max_buffer},
        $native->{read_mode},
        $callback{on_data},
        $callback{on_message},
        $callback{on_drain},
        \&_xs_read_eof,
        \&_xs_read_error,
        \&_xs_write_error,
        \&_xs_write_empty,
        \&_xs_framing_error,
        $native->{delimiter},
        $native->{include_delimiter} // 0,
        $native->{max_frame},
        $native->{fixed_size} // 0,
        $native->{prefix_bytes} // 0,
        $native->{prefix_little} // 0,
        $native->{include_prefix} // 0,
    );

    my $descriptor = {
        class     => $class,
        xs        => $xs,
        options   => $option,
        native    => $native,
        framer    => $framer,
        callbacks => \%callback,
    };
    $CLASS_DESCRIPTOR{$class} = $descriptor;
    return $descriptor;
}

sub _xs_framing_error ($self, $message) {
    $self->_fail_framing($message);
    return;
}

sub _xs_read_eof ($self) {
    $self->_mark_eof;
    return;
}

sub _xs_read_error ($self, $errno) {
    local $! = $errno;
    $self->_fail_io('read', $errno);
    return;
}

sub _xs_write_error ($self, $errno) {
    local $! = $errno;
    $self->_fail_io('write', $errno);
    return;
}

sub _xs_write_empty ($self) {
    return if $self->{closed};
    $self->{watcher}->disable_write if $self->{watcher};
    $self->_finish_write_side if $self->{write_ending} && !$self->{write_ended};
    return;
}

sub _watch_error_xs_cb ($state) {
    my $self = $state->stream or return;
    $self->_on_terminal_ready;
}

sub new ($class, %opt) {
    croak 'new(): must be called as a class method' if ref $class;
    my $loop = delete $opt{loop} // croak 'new(): missing loop';
    my $fh   = delete $opt{fh}   // croak 'new(): missing fh';
    my $data = delete $opt{data};
    croak 'new(): unknown options: ' . join(', ', sort keys %opt) if %opt;

    my $descriptor = _descriptor_for($class);
    _set_nonblocking($fh);

    my $self = bless {
        descriptor  => $descriptor,
        loop        => $loop,
        fh          => $fh,
        watcher     => undef,
        data        => $data,
        xs_state    => undef,
        read_paused => 0,
        read_eof    => 0,
        write_ending => 0,
        write_ended  => 0,
        closed       => 0,
        detached     => 0,
        close_fired  => 0,
        last_error   => undef,
    }, $class;

    my $xs_state = Linux::Event::Stream::XSState->new(
        $self,
        fileno($fh),
        $descriptor->{xs},
    );
    $self->{xs_state} = $xs_state;

    my $watcher = $loop->watch_fd(
        fileno($fh),
        fh    => $fh,
        data  => $xs_state,
        read  => \&Linux::Event::Stream::XSState::_read_ready,
        write => \&Linux::Event::Stream::XSState::_write_ready,
        error => \&_watch_error_xs_cb,
        _callback_data_arg => 1,
    );
    $self->{watcher} = $watcher;
    $watcher->disable_write;
    return $self;
}

sub fh ($self) { $self->{fh} }
sub loop ($self) { $self->{loop} }
sub last_error ($self) { $self->{last_error} }
sub is_closed ($self) { !!$self->{closed} }
sub is_read_paused ($self) { !!$self->{read_paused} }
sub is_read_eof ($self) { !!$self->{read_eof} }
sub is_write_ended ($self) { !!$self->{write_ended} }
sub is_write_blocked ($self) {
    return !!$self->{xs_state}->is_write_blocked if $self->{xs_state};
    return 0;
}

sub data ($self, @arg) {
    $self->{data} = $arg[0] if @arg;
    return $self->{data};
}

sub pending_bytes ($self) {
    return $self->{xs_state}->pending_bytes if $self->{xs_state};
    return 0;
}

sub write ($self, $bytes) {
    croak 'write(): stream is closed' if $self->{closed};
    croak 'write(): writable side has ended'
        if $self->{write_ending} || $self->{write_ended};
    return 1 if !defined($bytes) || $bytes eq '';

    my $status = $self->{xs_state}->_write($bytes);
    $self->{watcher}->enable_write if $status & 0x02;
    return $status & 0x01 ? 1 : 0;
}

sub send ($self, $payload) {
    my $framer = $self->{descriptor}{framer}
        // croak 'send(): requires a framed Stream subclass';
    my $bytes = $framer->{frame}->($framer->{native}, $payload);
    return $self->write($bytes);
}

sub end ($self, $final_bytes = undef) {
    return $self
        if $self->{closed} || $self->{write_ending} || $self->{write_ended};
    $self->write($final_bytes) if defined($final_bytes) && $final_bytes ne '';
    $self->{write_ending} = 1;
    $self->_finish_write_side if $self->pending_bytes == 0;
    return $self;
}

sub pause_read ($self) {
    return $self if $self->{closed} || $self->{read_eof} || $self->{read_paused};
    $self->{read_paused} = 1;
    $self->{xs_state}->_pause if $self->{xs_state};
    $self->{watcher}->disable_read if $self->{watcher};
    return $self;
}

sub resume_read ($self) {
    return $self if $self->{closed} || $self->{read_eof} || !$self->{read_paused};
    $self->{read_paused} = 0;
    $self->{xs_state}->_resume if $self->{xs_state};
    $self->{watcher}->enable_read if $self->{watcher};
    return $self;
}

sub close ($self) {
    $self->_close_now(1);
    return $self;
}

sub detach ($self) {
    croak 'detach(): stream is already closed' if $self->{closed};
    my $fh = $self->{fh};
    if (my $xs_state = delete $self->{xs_state}) {
        $xs_state->_close;
    }
    if (my $watcher = delete $self->{watcher}) {
        $watcher->cancel;
    }
    $self->{closed} = 1;
    $self->{detached} = 1;
    $self->{fh} = undef;
    return $fh;
}

sub _on_terminal_ready ($self) {
    return if $self->{closed};

    my $packed = getsockopt($self->{fh}, SOL_SOCKET, SO_ERROR);
    if (defined $packed) {
        my $errno = unpack('i', $packed);
        if ($errno) {
            local $! = $errno;
            $self->_fail_io('socket', $errno);
            return;
        }
    }

    $self->{xs_state}->_read_ready
        if !$self->{read_paused} && !$self->{read_eof} && $self->{xs_state};
}

sub _finish_write_side ($self) {
    return if $self->{closed} || $self->{write_ended};
    return if $self->pending_bytes > 0;

    my $ok = shutdown($self->{fh}, SHUT_WR);
    if (!$ok) {
        my $errno = 0 + $!;
        $self->_fail_io('shutdown', $errno);
        return;
    }

    $self->{write_ending} = 0;
    $self->{write_ended} = 1;
    $self->_close_now(1) if $self->{read_eof};
}

sub _mark_eof ($self) {
    return if $self->{read_eof} || $self->{closed};
    $self->{read_eof} = 1;
    $self->{watcher}->disable_read if $self->{watcher};

    if (my $callback = $self->{descriptor}{callbacks}{on_eof}) {
        $callback->($self);
    }
    $self->_close_now(1) if $self->{write_ended};
}

sub _fail_io ($self, $operation, $errno) {
    local $! = $errno;
    my $error = Linux::Event::Stream::Error->new(
        type      => 'io',
        operation => $operation,
        errno     => $errno,
        message   => "$!",
    );
    $self->_fail($error);
}

sub _fail_framing ($self, $message) {
    my $error = Linux::Event::Stream::Error->new(
        type      => 'framing',
        operation => 'frame',
        message   => $message,
    );
    $self->_fail($error);
}

sub _fail ($self, $error) {
    return if $self->{closed};
    $self->{last_error} = $error;
    if (my $callback = $self->{descriptor}{callbacks}{on_error}) {
        $callback->($self, $error);
    }
    $self->_close_now(1);
}

sub _close_now ($self, $close_fh) {
    return if $self->{closed};
    $self->{closed} = 1;

    if (my $xs_state = delete $self->{xs_state}) {
        $xs_state->_close;
    }
    if (my $watcher = delete $self->{watcher}) {
        $watcher->cancel;
    }
    CORE::close($self->{fh}) if $close_fh && defined $self->{fh};
    $self->{fh} = undef;

    if (!$self->{detached} && !$self->{close_fired}++) {
        if (my $callback = $self->{descriptor}{callbacks}{on_close}) {
            $callback->($self);
        }
    }
}

sub _set_nonblocking ($fh) {
    my $flags = fcntl($fh, F_GETFL, 0);
    croak "new(): fcntl(F_GETFL): $!" if !defined $flags;
    return if $flags & O_NONBLOCK;
    fcntl($fh, F_SETFL, $flags | O_NONBLOCK)
        or croak "new(): fcntl(F_SETFL O_NONBLOCK): $!";
}

1;

__END__

=head1 NAME

Linux::Event::Stream - subclass-defined native buffered streams

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::XSLoop;

  package EchoStream;
  use parent 'Linux::Event::Stream';
  use Linux::Event::Stream::Framer 'Delimiter', "\n";

  sub on_message ($stream, $message) {
      $stream->send($message);
  }

  sub on_eof ($stream) {
      $stream->end;
  }

  sub on_error ($stream, $error) {
      warn "$error\n";
  }

  package main;
  my $loop = Linux::Event::XSLoop->new;
  my $stream = EchoStream->new(
      loop => $loop,
      fh   => $socket,
      data => { user_id => 42 },
  );
  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Stream> is the native buffered byte-stream layer above
L<Linux::Event::XSLoop>. It is a base class rather than a configurable Stream
type. Applications define behavior once in a subclass and construct lightweight
per-connection instances containing only changing connection state.

The first construction of each subclass resolves its inherited callback CVs,
framer declaration, parser configuration, and transport settings into one
cached descriptor. XS stores that descriptor once and every connection's native
state references it. Construction therefore avoids per-object callback hashes,
framer objects, repeated validation, and repeated native configuration copies.

=head1 DEFINING A STREAM TYPE

A raw subclass defines C<on_data> and does not declare a framer:

  package ByteStream;
  use parent 'Linux::Event::Stream';

  sub on_data ($stream, $bytes) {
      $stream->write($bytes);
  }

A framed subclass imports one native built-in and defines C<on_message>:

  package LineStream;
  use parent 'Linux::Event::Stream';
  use Linux::Event::Stream::Framer 'Delimiter', "\n";

  sub on_message ($stream, $message) {
      $stream->send($message);
  }

Framed and raw modes are mutually exclusive. A subclass with no framer must
define C<on_data>; a framed subclass must define C<on_message>. The base class
cannot be instantiated directly.

=head1 CONSTRUCTOR

=head2 new(loop => $loop, fh => $fh, data => $value)

C<loop> and C<fh> are required. Stream takes ownership of the filehandle and
sets it nonblocking. C<data> is the only optional per-connection value. Use
C<detach> to transfer the still-open handle back to the application.

Callbacks, framing, and transport defaults are class behavior and are not
accepted as constructor options.

=head1 CLASS TRANSPORT OPTIONS

A subclass that needs non-default transport settings may define
C<stream_options>. It runs once when the class descriptor is built, not once
per connection:

  sub stream_options ($class) {
      return (
          read_size      => 32_768,
          high_watermark => 2 * 1024 * 1024,
          low_watermark  => 512 * 1024,
          max_buffer     => 16 * 1024 * 1024,
      );
  }

The defaults are 65,536 bytes per read, a 1 MiB high watermark, a 256 KiB low
watermark, and an 8 MiB maximum framed input buffer.

=head1 CALLBACKS

Subclasses may define these ordinary named methods:

  sub on_data    ($stream, $bytes)   { ... }
  sub on_message ($stream, $message) { ... }
  sub on_drain   ($stream)           { ... }
  sub on_eof     ($stream)           { ... }
  sub on_error   ($stream, $error)   { ... }
  sub on_close   ($stream)           { ... }

The resolved CVs are cached and invoked directly; readiness dispatch does not
perform Perl method lookup. Inheritance works normally, so a derived Stream type
may reuse callbacks and framing from its parent. Per-user or per-connection
permissions belong in C<data>, which callbacks access through C<< $stream->data >>.

Application callback exceptions are not swallowed.

=head1 METHODS

=head2 write($bytes)

Writes immediately when possible and queues any remainder. Returns false after
queued bytes exceed the high watermark; the bytes were still accepted. Wait for
C<on_drain> before producing more when bounded memory is required.

=head2 send($payload)

Available only to framed subclasses. Applies the subclass's declared outbound
wire framing and then uses C<write>. Serialization remains separate.

=head2 pause_read / resume_read

Disable and re-enable input readiness without destroying the Stream.

=head2 end($final_bytes = undef)

Drains queued output and performs C<shutdown(SHUT_WR)>. Peer EOF and the local
writable half-close remain independent.

=head2 close

Immediately cancels the watcher and closes the owned descriptor. Queued output
may be lost.

=head2 detach

Cancels Stream ownership and returns the still-open filehandle. C<on_close> is
not called because the underlying resource remains open.

=head2 pending_bytes / is_write_blocked

Report native output-queue and flow-control state.

=head2 is_read_paused / is_read_eof / is_write_ended / is_closed

Report Stream lifecycle state.

=head2 data([$value])

Gets or replaces per-connection application state.

=head1 FRAMING POLICY

Framed Stream types use native built-ins declared through
L<Linux::Event::Stream::Framer>. Arbitrary per-connection framer objects and the
old custom Perl C<next_frame> contract are intentionally unsupported. Unusual
protocols can buffer and parse raw C<on_data> bytes. Generally useful framing
families should be implemented as native Linux::Event built-ins.

=head1 PERFORMANCE

Native code drains reads, detects built-in frame boundaries, performs immediate
writes, drains segmented queues with C<writev>, and accounts for backpressure.
The class descriptor moves immutable callbacks and parser configuration out of
each connection. Perl is entered for semantic C<on_data> or C<on_message>
delivery and lifecycle policy.

=cut
