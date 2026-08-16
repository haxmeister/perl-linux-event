package Linux::Event::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_024';

use Carp qw(croak);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use mro ();
use Socket qw(SOL_SOCKET SO_ERROR);

use parent 'Linux::Event::Watcher';
use Linux::Event::Connect ();
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
        high_watermark   => 1_048_576,
        low_watermark    =>   262_144,
        max_pending_bytes =>         0,
        read_size        =>    65_536,
        max_buffer       => 8_388_608,
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
    croak "$class max_pending_bytes must be a non-negative integer"
        if $option{max_pending_bytes} !~ /\A\d+\z/;
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
        qw(on_data on_message on_drain on_eof on_error on_close
           on_ready on_transport_ready);

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
        $option->{max_pending_bytes},
        $option->{max_buffer},
        $native->{read_mode},
        $callback{on_data},
        $callback{on_message},
        $callback{on_drain},
        \&_xs_read_eof,
        \&_xs_read_error,
        \&_xs_write_error,
        \&_xs_output_limit,
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

sub _xs_output_limit ($self, $pending_bytes, $limit) {
    my $error = Linux::Event::Stream::Error->new(
        type          => 'output_limit',
        operation     => 'write',
        message       => "pending output would exceed $limit bytes",
        pending_bytes => $pending_bytes,
        limit         => $limit,
    );
    $self->_fail($error);
    return;
}

sub _xs_write_empty ($self) {
    return if $self->{closed};
    $self->{watcher}->disable_write if $self->{watcher};
    $self->_finish_write_side if $self->{write_ending} && !$self->{write_ended};
    return;
}

sub _xs_transport_event ($self, $status, $operation, $message) {
    return if $self->{closed};

    if ($status == 2) {
        $self->{watcher}->enable_read if $self->{watcher};
        return;
    }
    if ($status == 3) {
        $self->{watcher}->enable_write if $self->{watcher};
        return;
    }
    if ($status == 5) {
        my $error = Linux::Event::Stream::Error->new(
            type      => $self->transport_name // 'transport',
            operation => $operation,
            message   => $message || 'transport error',
        );
        $self->_fail($error);
        return;
    }

    if ($self->{xs_state} && $self->{xs_state}->transport_ready
        && !($self->{transport_ready_fired} & 0x01)) {
        $self->{transport_ready_fired} |= 0x01;
        if ($self->{transport}
            && $self->{transport}->can('_stream_transport_ready')) {
            $self->{transport}->_stream_transport_ready($self);
        }
        if ($self->{read_paused} && $self->{watcher}) {
            $self->{watcher}->disable_read;
        }
        if (my $callback = $self->{descriptor}{callbacks}{on_transport_ready}) {
            $callback->($self);
        }
        $self->_fire_ready;
    }
    if (($status == 0 || $status == 1) && $self->{write_ending}
        && !$self->pending_bytes) {
        $self->_finish_write_side;
        return if $self->{closed};
    }
    if ($self->{watcher} && !$self->pending_bytes
        && !$self->{write_ending}) {
        $self->{watcher}->disable_write;
    }
    return;
}

sub _watch_error_xs_cb ($state) {
    my $self = $state->stream or return;
    $self->_on_terminal_ready;
}

sub new ($class, %opt) {
    croak 'new(): must be called as a class method' if ref $class;
    my $loop = delete $opt{loop};
    croak 'new(): loop must be an object implementing add() and watch_fd()'
        if defined($loop) && (!ref($loop) || !$loop->can('add')
            || !$loop->can('watch_fd'));
    my $fh = delete $opt{fh};
    my $connect = delete $opt{_connect};
    my $data = delete $opt{data};
    my $peer = delete $opt{peer};
    my $transport = delete $opt{transport};
    croak 'new(): unknown options: ' . join(', ', sort keys %opt) if %opt;
    croak 'new(): exactly one of fh or an outbound connection is required'
        if defined($fh) == defined($connect);
    croak 'new(): fh must be a filehandle'
        if defined($fh) && !defined(fileno($fh));
    croak 'new(): internal connection options must be a hash reference'
        if defined($connect) && ref($connect) ne 'HASH';
    croak 'new(): transport must be an object implementing _stream_transport_bind()'
        if defined($transport)
        && (!ref($transport) || !$transport->can('_stream_transport_bind'));

    my $descriptor = _descriptor_for($class);
    my $self = bless {
        descriptor  => $descriptor,
        loop        => undef,
        fh          => $fh,
        watcher     => undef,
        data        => $data,
        transport   => $transport,
        xs_state    => undef,
        read_paused => 0,
        read_eof    => 0,
        write_ending => 0,
        write_ended  => 0,
        closed       => 0,
        detached     => 0,
        close_fired  => 0,
        last_error   => undef,
        transport_ready_fired => 0,
        transport_deadline_watcher => undef,
        transport_shutdown_started => 0,
    }, $class;
    $self->{peer} = $peer if defined $peer;

    $self->_prepare_fh($fh) if defined $fh;
    if ($connect) {
        $self->{preconnect_output} = [];
        $self->{preconnect_bytes} = 0;
        $self->{connector} = Linux::Event::Stream::_Connector->new(
            %$connect,
            data => $self,
        );
    }
    $self->_attach_to_loop($loop) if $loop;
    return $self;
}

sub connect ($class, %opt) {
    croak 'connect(): must be called as a class method' if ref $class;
    my %stream;
    for my $name (qw(loop data transport)) {
        $stream{$name} = delete $opt{$name} if exists $opt{$name};
    }
    return $class->new(%stream, _connect => \%opt);
}

sub listen ($class, %opt) {
    croak 'listen(): must be called as a class method' if ref $class;
    require Linux::Event::Listener;
    return Linux::Event::Listener->new(stream_class => $class, %opt);
}

sub _prepare_fh ($self, $fh) {
    _set_nonblocking($fh);
    my $descriptor = $self->{descriptor};
    my $xs_state = Linux::Event::Stream::XSState->new(
        $self,
        fileno($fh),
        $descriptor->{xs},
    );
    $self->{xs_state} = $xs_state;

    my $initial_interest = 0x01;
    my $transport = $self->{transport};
    if (defined $transport) {
        my @binding;
        my $attached = eval {
            @binding = $transport->_stream_transport_bind(fileno($fh));
            $xs_state->_attach_transport(
                $transport, @binding[0, 1, 2],
            );
            1;
        };
        if (!$attached) {
            my $error = $@ || 'transport attachment failed';
            $xs_state->_close;
            $self->{xs_state} = undef;
            CORE::close($fh);
            $self->{fh} = undef;
            die $error;
        }
        $initial_interest = $binding[3] // 0;
    }

    $self->{initial_interest} = $initial_interest
        if $initial_interest != 0x01;
    return;
}

sub _attach_to_loop ($self, $loop) {
    croak 'add(): Stream is not unattached'
        if $self->{closed} || $self->{loop};
    $self->{loop} = $loop;
    if (my $connector = $self->{connector}) {
        $connector->_attach_to_loop($loop);
        return $self;
    }

    my $initial_interest = delete($self->{initial_interest}) // 0x01;
    my $watcher = $loop->watch_fd(
        fileno($self->{fh}),
        fh    => $self->{fh},
        data  => $self->{xs_state},
        read  => \&Linux::Event::Stream::XSState::_read_ready,
        write => \&Linux::Event::Stream::XSState::_write_ready,
        error => \&_watch_error_xs_cb,
        _callback_data_arg => 1,
    );
    $self->{watcher} = $watcher;
    $watcher->disable_write if !($initial_interest & 0x02);
    $watcher->disable_read if !($initial_interest & 0x01);
    my $transport = $self->{transport};
    if ($transport && $transport->can('_stream_transport_start')) {
        my $started = eval { $transport->_stream_transport_start($self); 1 };
        if (!$started) {
            my $error = $@ || 'transport startup failed';
            $self->_close_now(1);
            die $error;
        }
    }
    $self->_flush_preconnect_output if exists $self->{preconnect_output};
    return $self;
}

sub _connect_succeeded ($self, $fh) {
    return if $self->{closed};
    delete $self->{connector};
    $self->{fh} = $fh;
    my $prepared = eval { $self->_prepare_fh($fh); 1 };
    if (!$prepared) {
        my $message = $@ || 'connected Stream setup failed';
        my $error = Linux::Event::Stream::Error->new(
            type => 'connect', operation => 'attach', message => $message,
        );
        $self->_fail($error);
        return;
    }
    my $initial_interest = delete($self->{initial_interest}) // 0x01;
    my $watcher = $self->{loop}->watch_fd(
        fileno($self->{fh}),
        fh    => $self->{fh},
        data  => $self->{xs_state},
        read  => \&Linux::Event::Stream::XSState::_read_ready,
        write => \&Linux::Event::Stream::XSState::_write_ready,
        error => \&_watch_error_xs_cb,
        _callback_data_arg => 1,
    );
    $self->{watcher} = $watcher;
    $watcher->disable_write if !($initial_interest & 0x02);
    $watcher->disable_read if !($initial_interest & 0x01);
    my $transport = $self->{transport};
    if ($transport && $transport->can('_stream_transport_start')) {
        my $started = eval { $transport->_stream_transport_start($self); 1 };
        if (!$started) {
            my $message = $@ || 'transport startup failed';
            my $error = Linux::Event::Stream::Error->new(
                type => 'transport', operation => 'start', message => $message,
            );
            $self->_fail($error);
            return;
        }
    }
    $self->_flush_preconnect_output;
    $self->_fire_ready if !$self->{transport};
    return;
}

sub _connect_failed ($self, $connect_error) {
    return if $self->{closed};
    delete $self->{connector};
    my $error = Linux::Event::Stream::Error->new(
        type      => 'connect',
        operation => $connect_error->operation,
        errno     => $connect_error->errno,
        message   => $connect_error->message,
    );
    $self->_fail($error);
    return;
}

sub _fire_ready ($self) {
    return if $self->{closed} || ($self->{transport_ready_fired} & 0x02);
    $self->{transport_ready_fired} |= 0x02;
    if (my $callback = $self->{descriptor}{callbacks}{on_ready}) {
        $callback->($self);
    }
    return;
}

sub _flush_preconnect_output ($self) {
    my $queued = delete $self->{preconnect_output} // [];
    $self->{preconnect_output} = [];
    $self->{preconnect_bytes} = 0;
    for my $bytes (@$queued) {
        my $status = $self->{xs_state}->_write($bytes);
        $self->{watcher}->enable_write if $status & 0x02;
        last if $self->{closed};
    }
    if ($self->{write_ending} && !$self->{closed} && !$self->pending_bytes) {
        $self->_finish_write_side;
    }
    return;
}

sub fh ($self) { $self->{fh} }
sub loop ($self) { $self->{loop} }
sub peer ($self) { $self->{peer} }
sub state ($self) {
    return 'detached' if $self->{closed} && $self->{detached};
    return 'closed' if $self->{closed};
    return 'unattached' if !$self->{loop};
    return 'connecting' if $self->{connector};
    return 'active';
}
sub last_error ($self) { $self->{last_error} }
sub transport ($self) { $self->{transport} }
sub is_closed ($self) { !!$self->{closed} }
sub is_terminal ($self) { !!$self->{closed} }
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
    my $pending = $self->{preconnect_bytes} // 0;
    $pending += $self->{xs_state}->pending_bytes if $self->{xs_state};
    return $pending;
}

sub transport_name ($self) {
    return $self->{xs_state}->transport_name if $self->{xs_state};
    return undef;
}

sub is_transport_ready ($self) {
    return !!$self->{xs_state}->transport_ready if $self->{xs_state};
    return 0;
}

sub write ($self, $bytes) {
    croak 'write(): stream is closed' if $self->{closed};
    croak 'write(): writable side has ended'
        if $self->{write_ending} || $self->{write_ended};
    return 1 if !defined($bytes) || $bytes eq '';

    if (!$self->{xs_state}) {
        croak 'write(): stream has no pending or active transport'
            if !$self->{connector};
        my $pending = ($self->{preconnect_bytes} // 0) + length($bytes);
        my $limit = $self->{descriptor}{options}{max_pending_bytes};
        if ($limit && $pending > $limit) {
            my $error = Linux::Event::Stream::Error->new(
                type          => 'output_limit',
                operation     => 'write',
                message       => "pending output would exceed $limit bytes",
                pending_bytes => $pending,
                limit         => $limit,
            );
            $self->_fail($error);
            return 0;
        }
        push @{ $self->{preconnect_output} //= [] }, "$bytes";
        $self->{preconnect_bytes} = $pending;
        return 0;
    }

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
    $self->_finish_write_side
        if $self->{xs_state} && $self->pending_bytes == 0;
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

sub transition_to ($self, $class, %opt) {
    croak 'transition_to(): stream is closed' if $self->{closed};
    croak 'transition_to(): target class is required'
        if !defined($class) || ref($class) || $class eq '';
    croak "transition_to(): $class is already active"
        if ref($self) eq $class;

    my $input = delete $opt{input};
    croak 'transition_to(): input must be a byte string'
        if defined($input) && ref($input);
    croak 'transition_to(): unknown options: ' . join(', ', sort keys %opt)
        if %opt;

    my $descriptor = _descriptor_for($class);
    my $xs_state = $self->{xs_state}
        // croak 'transition_to(): stream has no native state';

    # XS validates and swaps the immutable descriptor without invoking a
    # callback. Update the Perl object's type before buffered input is allowed
    # to enter the new callback set.
    $xs_state->_transition($descriptor->{xs}, $input);
    $self->{descriptor} = $descriptor;
    bless $self, $class;
    $xs_state->_transition_ready;
    return $self;
}

sub close ($self) {
    $self->_close_now(1);
    return $self;
}

sub detach ($self) {
    croak 'detach(): stream is already closed' if $self->{closed};
    croak 'detach(): stream is not established' if !defined $self->{fh};
    croak 'detach(): cannot detach a non-plain transport'
        if ($self->transport_name // 'plain') ne 'plain';
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

    if (!$self->{transport_shutdown_started}++ && $self->{transport}
        && $self->{transport}->can('_stream_transport_begin_shutdown')) {
        my $started = eval {
            $self->{transport}->_stream_transport_begin_shutdown($self);
            1;
        };
        if (!$started) {
            my $error = Linux::Event::Stream::Error->new(
                type      => $self->transport_name,
                operation => 'shutdown',
                message   => $@ || 'transport shutdown setup failed',
            );
            $self->_fail($error);
            return;
        }
    }

    my ($status, $errno, $message) = $self->{xs_state}->_shutdown_write;
    if ($status == 2) {
        $self->{watcher}->enable_read if $self->{watcher};
        return;
    }
    if ($status == 3) {
        $self->{watcher}->enable_write if $self->{watcher};
        return;
    }
    if ($status == 5) {
        if (($self->transport_name // 'plain') ne 'plain') {
            my $error = Linux::Event::Stream::Error->new(
                type      => $self->transport_name,
                operation => 'shutdown',
                message   => $message || 'transport shutdown failed',
            );
            $self->_fail($error);
            return;
        }
        local $! = $errno;
        $self->_fail_io('shutdown', $errno);
        return;
    }

    $self->{write_ending} = 0;
    $self->{write_ended} = 1;
    $self->_clear_transport_deadline;
    $self->_close_now(1) if $self->{read_eof};
}

sub _set_transport_deadline_watcher ($self, $watcher) {
    return if $self->{transport_deadline_watcher};
    $self->{transport_deadline_watcher} = $watcher;
    return;
}

sub _has_transport_deadline_watcher ($self) {
    return !!$self->{transport_deadline_watcher};
}

sub _clear_transport_deadline ($self) {
    if ($self->{transport}
        && $self->{transport}->can('_stream_transport_cancel_deadline')) {
        $self->{transport}->_stream_transport_cancel_deadline;
    }
    return;
}

sub _destroy_transport_deadline ($self) {
    if (my $watcher = delete $self->{transport_deadline_watcher}) {
        $watcher->cancel;
    }
    if ($self->{transport}
        && $self->{transport}->can('_stream_transport_close_deadline')) {
        $self->{transport}->_stream_transport_close_deadline;
    }
    return;
}

sub _transport_deadline_expired ($self, $operation, $message) {
    return if $self->{closed};
    my $error = Linux::Event::Stream::Error->new(
        type      => $self->transport_name // 'transport',
        operation => $operation,
        message   => $message,
    );
    $self->_fail($error);
    return;
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
    if (my $connector = delete $self->{connector}) {
        $connector->cancel;
    }
    $self->{preconnect_output} = [];
    $self->{preconnect_bytes} = 0;
    $self->_destroy_transport_deadline;

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

{
    package Linux::Event::Stream::_Connector;
    use parent -norequire, 'Linux::Event::Connect';

    sub _callback_target_data ($class) { 1 }
    *on_connect = \&Linux::Event::Stream::_connect_succeeded;
    *on_error = \&Linux::Event::Stream::_connect_failed;
}

1;

__END__

=head1 NAME

Linux::Event::Stream - subclass-defined native buffered streams

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::Loop;

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
  my $loop = Linux::Event::Loop->new;
  my $stream = $loop->add(EchoStream->new(
      fh   => $socket,
      data => { user_id => 42 },
  ));
  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Stream> is a Watcher backed by the native buffered byte-stream
engine above L<Linux::Event::Loop>. It is a base class rather than a configurable Stream
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

=head2 new(fh => $fh, data => $value, transport => $provider)

C<fh> is required for an already-established Stream. Construction is detached;
attach the result with C<< $loop->add($stream) >>. Stream takes ownership of
the filehandle and sets it nonblocking. C<data> is optional per-connection state. C<transport> is
an optional native byte-transport provider such as C<Linux::Event::TLS>. The
provider is bound to the established descriptor and retained for the Stream's
lifetime. Use C<detach> to transfer a still-open plain handle back to the
application; non-plain transports cannot be detached.

Callbacks, framing, and buffer policy are class behavior and are not accepted
as constructor options.

The former C<loop =E<gt> $loop> option remains compatibility syntax and is
equivalent to adding the constructed Stream before C<new> returns.

=head2 connect

  my $stream = MyStream->connect(
      host => '127.0.0.1', port => 9999, timeout => 10,
  );
  $loop->add($stream);

Returns one detached Stream in the outbound-acquisition state. The same object
survives connection setup, optional TLS negotiation, established I/O, and
close. C<host>/C<port>, C<unix>, and packed C<sockaddr>/C<family> address modes
match L<Linux::Event::Connector>. C<write> and C<send> may queue output before
attachment or readiness.

=head2 listen

  my $listener = $loop->add(MyStream->listen(
      host => '0.0.0.0', port => 9999,
  ));

Returns a detached L<Linux::Event::Listener> that constructs and attaches this
Stream subclass for every accepted connection.

=head1 CLASS TRANSPORT OPTIONS

A subclass that needs non-default transport settings may define
C<stream_options>. It runs once when the class descriptor is built, not once
per connection:

  sub stream_options ($class) {
      return (
          read_size         => 32_768,
          high_watermark    => 2 * 1024 * 1024,
          low_watermark     => 512 * 1024,
          max_pending_bytes => 8 * 1024 * 1024,
          max_buffer        => 16 * 1024 * 1024,
      );
  }

The defaults are 65,536 bytes per read, a 1 MiB high watermark, a 256 KiB low
watermark, no hard pending-output limit, and an 8 MiB maximum framed input
buffer. Set C<max_pending_bytes> to a positive byte count to impose a hard
limit; zero keeps the default unlimited policy.

=head1 CALLBACKS

Subclasses may define these ordinary named methods:

  sub on_data    ($stream, $bytes)   { ... }
  sub on_message ($stream, $message) { ... }
  sub on_drain   ($stream)           { ... }
  sub on_eof     ($stream)           { ... }
  sub on_error   ($stream, $error)   { ... }
  sub on_close   ($stream)           { ... }
  sub on_ready   ($stream)           { ... }
  sub on_transport_ready ($stream)   { ... }

The resolved CVs are cached and invoked directly; readiness dispatch does not
perform Perl method lookup. Inheritance works normally, so a derived Stream type
may reuse callbacks and framing from its parent. Per-user or per-connection
permissions belong in C<data>, which callbacks access through C<< $stream->data >>.
C<on_ready> is called once when an asynchronously acquired Stream becomes
usable. For TLS, this means handshake and verification have completed. Accepted
Streams are ready after Listener attachment. C<on_transport_ready> is retained
as the provider-specific compatibility callback and runs immediately before
C<on_ready> for an asynchronous non-plain transport.

Application callback exceptions are not swallowed.

=head1 METHODS

=head2 write($bytes)

Writes immediately when possible and queues any remainder. Returns false after
queued bytes exceed the high watermark; the bytes were still accepted. Wait for
C<on_drain> before producing more.

When C<max_pending_bytes> is nonzero, a write whose unsent remainder would put
the native queue above that limit is not queued. Stream reports an
C<output_limit> L<Linux::Event::Stream::Error> through C<on_error> and closes.
The error's C<pending_bytes> and C<limit> accessors describe the attempted
queue size and configured bound. An immediate kernel write may already have
sent a prefix before its remainder is found to exceed the limit; Stream never
adds that remainder to its queue. The ordinary false return remains reserved
for accepted cooperative backpressure.

=head2 send($payload)

Available only to framed subclasses. Applies the subclass's declared outbound
wire framing and then uses C<write>. Serialization remains separate.

=head2 pause_read / resume_read

Disable and re-enable input readiness without destroying the Stream.

=head2 transition_to($class, input => $bytes)

Changes a live connection to another loaded C<Linux::Event::Stream> subclass.
The same object is reblessed into C<$class>, and the same filehandle, watcher,
native connection state, output queue, backpressure state, lifecycle state, and
C<data> are retained. Future callbacks, C<send> framing, parser rules, and class
transport policy come from the target subclass's cached descriptor.

Unread bytes already held by a framed parser are preserved and reinterpreted by
the target parser. A raw C<on_data> callback may pass the unconsumed suffix of
its current chunk with C<< input => $bytes >>:

  sub on_data ($stream, $bytes) {
      my ($request, $remaining) = parse_upgrade($bytes);
      return if !$request;
      $stream->write(upgrade_response());
      $stream->transition_to('My::WebSocketStream', input => $remaining);
      return;
  }

Existing native input is ordered before the explicit C<input> suffix. Complete
target frames may be delivered before C<transition_to> returns when the method
is called outside input dispatch. During C<on_data> or C<on_message>, target
dispatch begins after the old callback returns. Code should normally return
immediately after requesting a transition.

Read pause is retained and continues to gate preserved input. Queued output
keeps its original byte ordering; only later C<send> calls use the new outbound
framing. If preserved input exceeds the target class's C<max_buffer>, or
existing queued output exceeds its nonzero C<max_pending_bytes>, the transition
fails atomically and the old type remains active. Transitioning to the
already-active class is rejected.

This method changes Stream protocol behavior; it does not replace the active
byte transport. In particular, a TLS Stream remains TLS across protocol
transitions.

=head2 end($final_bytes = undef)

Drains queued output and ends the transport's writable side. Plain Streams use
C<shutdown(SHUT_WR)>; TLS providers send C<close_notify>. Peer EOF and the local
writable half-close remain independent.

=head2 close

Immediately cancels the watcher and closes the owned descriptor. Queued output
may be lost.

=head2 detach

Cancels Stream ownership and returns the still-open filehandle for the plain
transport. C<on_close> is not called because the underlying resource remains
open. Non-plain transports reject detach because the descriptor carries
provider-owned wire state rather than application plaintext.

=head2 pending_bytes / is_write_blocked

Report native output-queue and flow-control state.

=head2 transport / transport_name / is_transport_ready

Returns the configured provider object, active native byte transport name, and
whether its asynchronous setup has completed. Ordinary filehandle-backed
Streams have no provider object, report C<plain>, and are immediately ready.

=head2 is_read_paused / is_read_eof / is_write_ended / is_closed

Report Stream lifecycle state.

=head2 data([$value])

Gets or replaces per-connection application state.

=head2 loop / state / peer

Return the owning Loop, C<unattached>, C<connecting>, C<active>, C<detached>, or
C<closed> lifecycle state, and the lazy accepted peer when the Stream came from
a Listener.

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
