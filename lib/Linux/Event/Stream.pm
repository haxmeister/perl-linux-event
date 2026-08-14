package Linux::Event::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_009';

use Carp qw(croak);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Scalar::Util qw(blessed);
use Socket qw(SHUT_WR SOL_SOCKET SO_ERROR);

use Linux::Event::Stream::Error;
use Linux::Event::Stream::Framer::Buffer;

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

# The public Stream contract is backed by native read, write, and built-in
# framing engines. Private decomposition switches preserve slower reference paths
# so benchmarks can isolate transport I/O and framing costs. Private
# _read_backend/_write_backend switches preserve executable reference paths for
# decomposition benchmarks; they are not application API.

# Reference-read callbacks used only by the benchmark compatibility path.
sub _watch_read_cb ($watcher) {
    my $self = $watcher->data or return;
    $self->_on_read_ready;
}

sub _watch_write_cb ($watcher) {
    my $self = $watcher->data or return;
    $self->_on_write_ready;
}

sub _watch_error_cb ($watcher) {
    my $self = $watcher->data or return;
    $self->_on_terminal_ready;
}

# Native watchers receive XSState directly from the reactor.  When the write
# backend remains Perl for decomposition benchmarking this shim deliberately
# preserves the old Perl drain path; the default XS write backend bypasses it.
sub _watch_write_xs_cb ($state) {
    my $self = $state->stream or return;
    $self->_on_write_ready;
}

sub _watch_error_xs_cb ($state) {
    my $self = $state->stream or return;
    $self->_on_terminal_ready;
}

sub _xs_discard_data ($self, $bytes) { return }
sub _xs_feed_framed ($self, $bytes) { $self->_accept_read_bytes($bytes); return }
sub _xs_framed_ready ($self) { $self->_dispatch_frames; return }
sub _xs_framing_error ($self, $message) { $self->_fail_framing($message); return }
sub _xs_read_eof ($self) { $self->_mark_eof; return }
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

# Native queue-empty is a semantic transition: stop EPOLLOUT and, if end() is
# pending, perform the writable half-close in Perl where lifecycle policy lives.
sub _xs_write_empty ($self) {
    return if $self->{closed};
    $self->{watcher}->disable_write if $self->{watcher};
    $self->_finish_write_side if $self->{write_ending} && !$self->{write_ended};
    return;
}

sub new ($class, %opt) {
    my $loop = delete $opt{loop} // croak 'new(): missing loop';
    my $fh   = delete $opt{fh}   // croak 'new(): missing fh';

    my $on_data    = _take_cb(\%opt, 'on_data');
    my $on_message = _take_cb(\%opt, 'on_message');
    my $on_drain   = _take_cb(\%opt, 'on_drain');
    my $on_eof     = _take_cb(\%opt, 'on_eof');
    my $on_error   = _take_cb(\%opt, 'on_error');
    my $on_close   = _take_cb(\%opt, 'on_close');

    my $framer = delete $opt{framer};
    croak 'new(): on_data and framer/on_message modes are mutually exclusive'
        if defined($on_data) && (defined($framer) || defined($on_message));
    croak 'new(): framer requires on_message'
        if defined($framer) && !defined($on_message);
    croak 'new(): on_message requires framer'
        if defined($on_message) && !defined($framer);
    croak 'new(): framer must provide next_frame()'
        if defined($framer) && (!blessed($framer) || !$framer->can('next_frame'));

    my $high = delete $opt{high_watermark} // 1_048_576;
    my $low  = delete $opt{low_watermark}  //   262_144;
    croak 'high_watermark must be >= 0' if $high < 0;
    croak 'low_watermark must be >= 0' if $low < 0;
    croak 'low_watermark must be <= high_watermark' if $low > $high;

    my $read_size = delete $opt{read_size} // 65_536;
    croak 'read_size must be > 0' if $read_size <= 0;

    my $read_backend = delete $opt{_read_backend} // 'xs';
    croak '_read_backend must be xs or perl'
        if $read_backend ne 'xs' && $read_backend ne 'perl';

    my $write_backend = delete $opt{_write_backend} // 'xs';
    croak '_write_backend must be xs or perl'
        if $write_backend ne 'xs' && $write_backend ne 'perl';
    croak '_write_backend=xs currently requires _read_backend=xs'
        if $write_backend eq 'xs' && $read_backend ne 'xs';

    # Private framing backends exist only for development decomposition:
    #   perl    - XS read delivers chunks to the old Perl scalar buffer/framer
    #   xs-perl - bytes stay in native storage; a custom Perl framer sees Buffer
    #   xs      - exact built-in framing executes entirely in XS
    # The public default chooses the fastest compatible path automatically.
    my $framing_backend = delete $opt{_framing_backend};
    if ($framer) {
        my %native_builtin = map { $_ => 1 } qw(
            Linux::Event::Stream::Framer::Delimiter
            Linux::Event::Stream::Framer::Fixed
            Linux::Event::Stream::Framer::LengthPrefix
            Linux::Event::Stream::Framer::U32BE
            Linux::Event::Stream::Framer::Netstring
            Linux::Event::Stream::Framer::Varint
            Linux::Event::Stream::Framer::DecimalLength
        );
        my $is_native_builtin = $native_builtin{ref($framer)} // 0;
        $framing_backend //= $read_backend eq 'perl' ? 'perl'
            : $is_native_builtin ? 'xs'
            : 'xs-perl';
        croak '_framing_backend must be perl, xs-perl, or xs'
            if $framing_backend ne 'perl'
            && $framing_backend ne 'xs-perl'
            && $framing_backend ne 'xs';
        croak '_framing_backend=xs-perl or xs requires _read_backend=xs'
            if $read_backend ne 'xs' && $framing_backend ne 'perl';
        croak '_framing_backend=xs requires an exact built-in native framer class'
            if $framing_backend eq 'xs' && !$is_native_builtin;
    } else {
        croak '_framing_backend is only valid in framed mode'
            if defined $framing_backend;
        $framing_backend = 'none';
    }

    my $max_buffer = delete $opt{max_buffer} // 8_388_608;
    croak 'max_buffer must be > 0 when defined'
        if defined($max_buffer) && $max_buffer <= 0;

    my $data = delete $opt{data};
    croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;

    _set_nonblocking($fh);

    my $rbuf = '';
    my $self = bless {
        loop      => $loop,
        fh        => $fh,
        watcher   => undef,
        data      => $data,

        on_data    => $on_data,
        on_message => $on_message,
        on_drain   => $on_drain,
        on_eof     => $on_eof,
        on_error   => $on_error,
        on_close   => $on_close,

        framer      => $framer,
        rbuf_ref    => \$rbuf,
        frame_view  => undef,
        max_buffer   => $max_buffer,
        read_size    => $read_size,
        read_backend  => $read_backend,
        write_backend => $write_backend,
        framing_backend => $framing_backend,
        xs_state      => undef,

        wbuf          => '',
        woff          => 0,
        high_watermark => $high,
        low_watermark  => $low,
        write_blocked  => 0,

        read_paused => 0,
        read_eof    => 0,
        write_ending => 0,
        write_ended  => 0,
        closed       => 0,
        detached     => 0,
        close_fired  => 0,
        last_error   => undef,
    }, $class;

    if ($framer && $framing_backend eq 'perl') {
        $self->{frame_view} = Linux::Event::Stream::Framer::Buffer->_new($self->{rbuf_ref});
    }

    my $watcher;

    if ($read_backend eq 'xs') {
        my ($read_mode, $deliver_cb, $framed_ready_cb, $message_cb);
        my ($delimiter, $include_delimiter, $max_frame, $fixed_size,
            $prefix_bytes, $prefix_little, $include_prefix);

        if (!$framer) {
            $read_mode = 0;
            $deliver_cb = $on_data // \&_xs_discard_data;
        } elsif ($framing_backend eq 'perl') {
            $read_mode = 0;
            $deliver_cb = \&_xs_feed_framed;
        } elsif ($framing_backend eq 'xs-perl') {
            $read_mode = 1;
            $framed_ready_cb = \&_xs_framed_ready;
        } else {
            my $cfg = $framer->_native_config;
            croak 'native framer _native_config() must return a hashref'
                if ref($cfg) ne 'HASH';
            $read_mode         = $cfg->{read_mode};
            $delimiter         = $cfg->{delimiter};
            $include_delimiter = $cfg->{include_delimiter} // 0;
            $max_frame         = $cfg->{max_frame};
            $fixed_size        = $cfg->{fixed_size} // 0;
            $prefix_bytes      = $cfg->{prefix_bytes} // 0;
            $prefix_little     = $cfg->{prefix_little} // 0;
            $include_prefix    = $cfg->{include_prefix} // 0;
            $message_cb = $on_message;
        }

        my $xs_state = Linux::Event::Stream::XSState->new(
            $self,
            fileno($fh),
            $read_size,
            $deliver_cb,
            \&_xs_read_eof,
            \&_xs_read_error,
            $high,
            $low,
            $on_drain,
            \&_xs_write_error,
            \&_xs_write_empty,
            $read_mode,
            $framed_ready_cb,
            $message_cb,
            \&_xs_framing_error,
            $delimiter,
            $include_delimiter // 0,
            $max_frame,
            $max_buffer,
            $fixed_size // 0,
            $prefix_bytes // 0,
            $prefix_little // 0,
            $include_prefix // 0,
        );
        $self->{xs_state} = $xs_state;

        if ($framer && $framing_backend eq 'xs-perl') {
            $self->{frame_view} = Linux::Event::Stream::Framer::Buffer->_new_xs($xs_state);
        }

        my $write_cb = $write_backend eq 'xs'
            ? \&Linux::Event::Stream::XSState::_write_ready
            : \&_watch_write_xs_cb;

        # Stream uses the low-level registration entry point internally so the
        # public named watcher API adds no connection-setup overhead here.
        $watcher = $loop->watch_fd(
            fileno($fh),
            fh   => $fh,
            data => $xs_state,
            read => \&Linux::Event::Stream::XSState::_read_ready,
            write => $write_cb,
            error => \&_watch_error_xs_cb,
            _callback_data_arg => 1,
        );
    } else {
        $watcher = $loop->watch_fd(
            fileno($fh),
            fh    => $fh,
            data  => $self,
            read  => \&_watch_read_cb,
            write => \&_watch_write_cb,
            error => \&_watch_error_cb,
        );
    }

    $self->{watcher} = $watcher;
    $watcher->disable_write;

    return $self;
}

sub _take_cb ($opt, $name) {
    my $cb = delete $opt->{$name};
    croak "$name must be a coderef" if defined($cb) && ref($cb) ne 'CODE';
    return $cb;
}

sub fh ($self) { $self->{fh} }
sub loop ($self) { $self->{loop} }
sub last_error ($self) { $self->{last_error} }
sub is_closed ($self) { !!$self->{closed} }
sub is_read_paused ($self) { !!$self->{read_paused} }
sub is_read_eof ($self) { !!$self->{read_eof} }
sub is_write_ended ($self) { !!$self->{write_ended} }
sub is_write_blocked ($self) {
    return !!$self->{xs_state}->is_write_blocked
        if $self->{write_backend} eq 'xs' && $self->{xs_state};
    return !!$self->{write_blocked};
}

sub data ($self, @arg) {
    $self->{data} = $arg[0] if @arg;
    return $self->{data};
}

sub pending_bytes ($self) {
    return $self->{xs_state}->pending_bytes
        if $self->{write_backend} eq 'xs' && $self->{xs_state};

    my $pending = length($self->{wbuf}) - $self->{woff};
    return $pending > 0 ? $pending : 0;
}

# write() follows the familiar stream/backpressure convention:
#   true  => producer may continue writing
#   false => high watermark exceeded; wait for on_drain before producing more
# Data is still accepted when false is returned. This is flow control, not an
# I/O failure indication.
sub write ($self, $bytes) {
    croak 'write(): stream is closed' if $self->{closed};
    croak 'write(): writable side has ended' if $self->{write_ending} || $self->{write_ended};
    return 1 if !defined($bytes) || $bytes eq '';

    if ($self->{write_backend} eq 'xs') {
        # Internal result bit 0 is the public flow-control result. Bit 1 means
        # native output is queued and EPOLLOUT must be armed.
        my $status = $self->{xs_state}->_write($bytes);
        $self->{watcher}->enable_write if $status & 0x02;
        return $status & 0x01 ? 1 : 0;
    }

    if ($self->pending_bytes == 0) {
        while (1) {
            my $n = syswrite($self->{fh}, $bytes);
            if (defined $n) {
                return 1 if $n == length($bytes);
                substr($bytes, 0, $n, '');
                last;
            }

            my $errno = 0 + $!;
            next if $errno == EINTR;
            last if _would_block($errno);
            $self->_fail_io('write', $errno);
            return 0;
        }
    }

    $self->_compact_write_buffer;
    $self->{wbuf} .= $bytes;
    $self->{watcher}->enable_write if $self->{watcher};

    my $pending = $self->pending_bytes;
    $self->{write_blocked} = 1 if $pending > $self->{high_watermark};
    return $self->{write_blocked} ? 0 : 1;
}

# end() gracefully ends only the local writable side. Incoming data and peer
# EOF remain independently observable. Once both directions have ended the
# Stream closes the fd and fires on_close.
# send() is the framed-mode counterpart to write(). Framing is not
# serialization: the payload is already application bytes. A custom framer may
# optionally provide frame($payload) for its outbound wire representation.
sub send ($self, $payload) {
    my $framer = $self->{framer}
        // croak 'send(): requires framed mode';
    croak 'send(): framer does not provide frame()' if !$framer->can('frame');
    my $bytes = $framer->frame($payload);
    return $self->write($bytes);
}

sub end ($self, $final_bytes = undef) {
    return $self if $self->{closed} || $self->{write_ending} || $self->{write_ended};
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

# close() is intentionally abortive/immediate at the Stream abstraction level.
# Use end() when queued output must be delivered first.
sub close ($self) {
    $self->_close_now(1);
    return $self;
}

# detach() removes Linux::Event ownership without closing the underlying fh.
# No on_close callback is emitted because the resource itself was not closed.
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

    # The reactor groups EPOLLERR/HUP/RDHUP into the terminal callback. SO_ERROR
    # distinguishes a real pending socket error from an orderly half-close. For
    # HUP/RDHUP with no socket error, drain read data and let sysread(0) produce
    # the normal on_eof transition.
    my $packed = getsockopt($self->{fh}, SOL_SOCKET, SO_ERROR);
    if (defined $packed) {
        my $errno = unpack('i', $packed);
        if ($errno) {
            local $! = $errno;
            $self->_fail_io('socket', $errno);
            return;
        }
    }

    if (!$self->{read_paused} && !$self->{read_eof}) {
        if (my $xs_state = $self->{xs_state}) {
            $xs_state->_read_ready;
        } else {
            $self->_on_read_ready;
        }
    }
}

sub _on_read_ready ($self) {
    return if $self->{closed} || $self->{read_paused} || $self->{read_eof};

    while (1) {
        my $bytes = '';
        my $n = sysread($self->{fh}, $bytes, $self->{read_size});

        if (defined $n) {
            if ($n == 0) {
                $self->_mark_eof;
                return;
            }

            $self->_accept_read_bytes($bytes);

            return if $self->{closed} || $self->{read_paused} || $self->{read_eof};
            next;
        }

        my $errno = 0 + $!;
        next if $errno == EINTR;
        return if _would_block($errno);
        $self->_fail_io('read', $errno);
        return;
    }
}

sub _accept_read_bytes ($self, $bytes) {
    if ($self->{framer}) {
        ${ $self->{rbuf_ref} } .= $bytes;
        my $max = $self->{max_buffer};
        if (defined($max) && length(${ $self->{rbuf_ref} }) > $max) {
            $self->_fail_framing("input buffer exceeds max_buffer=$max");
            return;
        }
        $self->_dispatch_frames;
    } elsif (my $cb = $self->{on_data}) {
        $cb->($self, $bytes);
    }
    return;
}

sub _dispatch_frames ($self) {
    my $framer = $self->{framer};
    my $view   = $self->{frame_view};
    my $cb     = $self->{on_message};

    while (!$self->{closed} && !$self->{read_paused}) {
        # Do not cross into a custom Perl framer when there are no bytes to
        # inspect. After emitting the last buffered frame we can return
        # directly to the reactor.
        return if $view->length == 0;

        my $needed = $view->_needed;
        return if $needed && $view->length < $needed;
        $view->_clear_need;

        my @frame;
        my $ok = eval {
            @frame = $framer->next_frame($view);
            1;
        };
        if (!$ok) {
            my $message = $@ || 'framer failed';
            $message =~ s/\s+\z//;
            $self->_fail_framing($message);
            return;
        }

        return if !@frame;
        if (@frame != 3) {
            $self->_fail_framing('next_frame() must return (offset, length, consume)');
            return;
        }

        my ($offset, $length, $consume) = @frame;
        if (!defined($offset) || !defined($length) || !defined($consume)
            || $offset !~ /\A\d+\z/ || $length !~ /\A\d+\z/ || $consume !~ /\A\d+\z/
            || $consume <= 0
            || $offset + $length > $consume
            || $consume > $view->length) {
            $self->_fail_framing('invalid frame boundaries returned by next_frame()');
            return;
        }

        my $message = $view->_extract_consume($offset, $length, $consume);
        $view->_clear_need;
        $cb->($self, $message);
    }
}

sub _on_write_ready ($self) {
    return if $self->{closed};

    while ($self->pending_bytes > 0) {
        my $pending = $self->pending_bytes;
        my $n = syswrite($self->{fh}, $self->{wbuf}, $pending, $self->{woff});

        if (defined $n) {
            $self->{woff} += $n;
            $self->_maybe_drain_transition;
            next;
        }

        my $errno = 0 + $!;
        next if $errno == EINTR;
        return if _would_block($errno);
        $self->_fail_io('write', $errno);
        return;
    }

    $self->{wbuf} = '';
    $self->{woff} = 0;
    $self->{watcher}->disable_write if $self->{watcher};
    $self->_maybe_drain_transition;
    $self->_finish_write_side if $self->{write_ending} && !$self->{write_ended};
}

sub _maybe_drain_transition ($self) {
    return if !$self->{write_blocked};
    return if $self->pending_bytes > $self->{low_watermark};

    $self->{write_blocked} = 0;
    if (my $cb = $self->{on_drain}) {
        $cb->($self);
    }
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

    if (my $cb = $self->{on_eof}) {
        $cb->($self);
    }

    $self->_close_now(1) if $self->{write_ended};
}

sub _fail_io ($self, $operation, $errno) {
    local $! = $errno;
    my $message = "$!";
    my $error = Linux::Event::Stream::Error->new(
        type      => 'io',
        operation => $operation,
        errno     => $errno,
        message   => $message,
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
    if (my $cb = $self->{on_error}) {
        $cb->($self, $error);
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

    if ($close_fh && defined $self->{fh}) {
        CORE::close($self->{fh});
    }

    $self->{fh} = undef;

    if (!$self->{detached} && !$self->{close_fired}++) {
        if (my $cb = $self->{on_close}) {
            $cb->($self);
        }
    }
}

sub _compact_write_buffer ($self) {
    my $off = $self->{woff};
    return if !$off;

    if ($off > 65_536 || $off > (length($self->{wbuf}) >> 1)) {
        substr($self->{wbuf}, 0, $off, '');
        $self->{woff} = 0;
    }
}

sub _would_block ($errno) {
    return $errno == EAGAIN || $errno == EWOULDBLOCK;
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

Linux::Event::Stream - buffered byte streams for Linux::Event

=head1 STATUS

This development version extends the XS-backed Stream rewrite with a native
built-in framer family. Mechanical read/write transport and framed input storage
are native, as are Delimiter, Fixed, LengthPrefix, U32BE, Netstring, Varint,
and DecimalLength framing.
Custom Perl framers remain fully pluggable through a stable Buffer view backed
by the same native input storage.

=head1 SYNOPSIS

  use Linux::Event::XSLoop;
  use Linux::Event::Stream;

  my $loop = Linux::Event::XSLoop->new;

  my $stream = Linux::Event::Stream->new(
      loop => $loop,
      fh   => $socket,

      on_data => sub ($stream, $bytes) {
          $stream->write($bytes);
      },

      on_drain => sub ($stream) {
          # resume an upstream producer
      },

      on_eof => sub ($stream) {
          $stream->end;
      },

      on_error => sub ($stream, $error) {
          warn "$error\n";
      },
  );

  $loop->run;

=head1 DESIGN

The public API exposes semantic stream events. The reactor and eventual XS
implementation own mechanical fd readiness, read draining, write draining,
buffering, and flow-control transitions.

C<write> returns false when the high watermark has been exceeded. Data is still
accepted; the false return is a producer flow-control signal. C<on_drain> fires
once when queued output falls to or below the low watermark.

Read EOF is independent from the writable side. C<on_eof> does not implicitly
make further writes impossible. C<end> gracefully drains queued output and
then performs a writable half-close. C<close> is immediate.

=head1 CONSTRUCTOR

=head2 new(%args)

Required arguments are C<loop> and C<fh>. Stream takes ownership of the supplied
filehandle and sets it nonblocking. Use C<detach> to transfer an open handle
back to the application.

Raw mode accepts C<on_data>. Framed mode accepts C<framer> plus C<on_message>.
Those two modes are mutually exclusive.

Optional callbacks are C<on_drain>, C<on_eof>, C<on_error>, and C<on_close>.
Optional flow-control settings are C<high_watermark> and C<low_watermark>.
C<read_size> controls the native/read-reference syscall chunk size and
C<max_buffer> bounds framed input buffering. These implementation-oriented
knobs may evolve as framed storage moves native.

=head1 METHODS

=head2 write($bytes)

Writes immediately when possible and queues any remainder. Returns true when
the producer may continue or false when queued output has exceeded the high
watermark. A false return means the data was accepted; wait for C<on_drain>
before producing more if bounded memory is desired.

=head2 send($payload)

Available in framed mode when the framer implements C<frame($payload)>. Applies
wire framing and then uses C<write>. Serialization is intentionally separate.

=head2 pause_read / resume_read

Disable and re-enable input readiness without destroying the Stream.

=head2 end($final_bytes = undef)

Gracefully ends the local writable side. Queued output drains first, then
C<shutdown(SHUT_WR)> is performed. The readable side remains independent.

=head2 close

Immediately cancels the watcher and closes the owned fd. Queued output may be
lost.

=head2 detach

Cancels Stream ownership and returns the still-open filehandle. C<on_close> is
not fired because the underlying resource was not closed.

=head2 pending_bytes

Returns user-space bytes still queued for output.

=head2 is_write_blocked

Reports current high/low-watermark flow-control state. Normally applications
should use the C<write> return value and C<on_drain> instead of polling this.

=head2 is_read_paused / is_read_eof / is_write_ended / is_closed

Expose Stream lifetime state for diagnostics and stateful protocols.

=head2 data([$value])

Gets or replaces optional application state. It is deliberately not appended
to every callback argument list.

=head1 CALLBACKS

The intended callback signatures are:

  on_data    => sub ($stream, $bytes) { ... }
  on_message => sub ($stream, $message) { ... }
  on_drain   => sub ($stream) { ... }
  on_eof     => sub ($stream) { ... }
  on_error   => sub ($stream, $error) { ... }
  on_close   => sub ($stream) { ... }

Application callback exceptions are not swallowed. A custom framer exception
is different: it is converted to a C<Linux::Event::Stream::Error> with type
C<framing>, passed to C<on_error>, and closes the Stream.

=head1 FRAMING

Raw mode uses C<on_data>. Framed mode supplies a framer plus C<on_message>.
Custom framers receive a C<Linux::Event::Stream::Framer::Buffer> view and return
C<(offset, length, consume)> for one complete frame, no values when more bytes
are required, or die on invalid input. A framer may additionally implement
C<frame($payload)> to support outbound C<send>. See L<Linux::Event::Stream::Framer> for framer selection and F<docs/FRAMING.md> for the plug-in contract.

=head1 PERFORMANCE NOTE

The default transport path is native for read draining, immediate writes,
queued writev() draining, backpressure accounting, and exact built-in framing.
Third-party/custom framing still runs in Perl by design through the native Buffer
view. Private development backends remain available for decomposition benchmarks.

=cut
