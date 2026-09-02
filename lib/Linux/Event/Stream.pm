package Linux::Event::Stream;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use Carp qw(croak);
use Errno ();
use Fcntl qw(F_GETFD F_GETFL F_SETFD F_SETFL FD_CLOEXEC O_NONBLOCK);
use POSIX qw(isfinite);
use Scalar::Util qw(looks_like_number refaddr weaken);
use utf8 ();

use Linux::Event::Stream::_Descriptor ();
use Linux::Event::Error;

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

sub _declare_framer ($base, $target, $definition) {
    return Linux::Event::Stream::_Descriptor::declare_framer(
        $base, $target, $definition,
    );
}

sub _declare_consumer ($base, $target, $definition) {
    return Linux::Event::Stream::_Descriptor::declare_consumer(
        $base, $target, $definition,
    );
}

sub _timeout_value ($target, $name, $value) {
    my $seconds = !defined($value) || ref($value) || !looks_like_number($value)
        ? undef : 0 + $value;
    croak "$target $name must be a non-negative number of seconds"
        if !defined($seconds) || !isfinite($seconds) || $seconds < 0;
    croak "$target $name exceeds the supported timer range"
        if $seconds > 2_147_483_647;
    return $seconds;
}

sub _deadline_spec ($method, $value) {
    croak "$method(): deadline must be a hash reference"
        if ref($value) ne 'HASH';
    my %option = %$value;
    my $has_after = exists $option{after};
    my $has_at = exists $option{at};
    croak "$method(): deadline requires exactly one of after or at"
        if $has_after == $has_at;
    my $operation = delete $option{operation};
    croak "$method(): deadline operation must be a non-empty string"
        if !defined($operation) || ref($operation) || $operation eq '';
    my $name = $has_after ? 'after' : 'at';
    my $seconds = _timeout_value("$method(): deadline", $name,
        delete $option{$name});
    croak "$method(): unknown deadline options: "
        . join(', ', sort keys %option) if %option;
    return {
        absolute  => $has_at ? 1 : 0,
        seconds   => $seconds,
        operation => "$operation",
    };
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
    my $error = Linux::Event::Error->new(
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
    $self->{deadline_write_started} = undef;
    $self->_rearm_stream_deadline
        if $self->{deadline_started} && $self->{timeout}{write_timeout} > 0;
    $self->{write_watcher}->disable_write if $self->{write_watcher};
    $self->_finish_write_side if $self->{write_ending} && !$self->{write_ended};
    return;
}

sub _xs_drain ($self) {
    return if $self->{closed};
    if ($self->{preconnect_write_blocked}
        && !($self->{transport_ready_fired} & 0x02)) {
        $self->{preconnect_drain_reached} = 1;
        return;
    }
    delete $self->{preconnect_write_blocked};
    delete $self->{preconnect_drain_reached};
    my $callback = $self->{descriptor}{callbacks}{on_drain};
    $callback->($self) if $callback;
    return;
}

sub _xs_consumer_paused ($self) {
    return if $self->{closed};
    $self->{read_watcher}->disable_read
        if $self->{read_watcher} && $self->{xs_state}->transport_ready;
    return;
}

sub _xs_consumer_resumed ($self) {
    return if $self->{closed} || $self->{read_paused} || $self->{read_eof};
    $self->{read_watcher}->enable_read
        if $self->{read_watcher} && !$self->{xs_state}->consumer_paused;
    return;
}

sub _xs_consumer_close ($self) {
    $self->close if !$self->{closed};
    return;
}

sub _xs_transport_event ($self, $status, $operation, $message) {
    return if $self->{closed};

    if ($status == 2) {
        # Transport handshakes and shutdowns must make progress even when the
        # application-facing consumer is paused.
        $self->{read_watcher}->enable_read if $self->{read_watcher};
        return;
    }
    if ($status == 3) {
        $self->{write_watcher}->enable_write if $self->{write_watcher};
        return;
    }
    if ($status == 5) {
        my $error = Linux::Event::Error->new(
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
        $self->_start_stream_deadlines;
        if ($self->{transport}
            && $self->{transport}->can('_stream_transport_ready')) {
            $self->{transport}->_stream_transport_ready($self);
        }
        if (($self->{read_paused} || $self->{xs_state}->consumer_paused)
            && $self->{read_watcher}) {
            $self->{read_watcher}->disable_read;
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
    if ($self->{write_watcher} && !$self->pending_bytes
        && !$self->{write_ending}) {
        $self->{write_watcher}->disable_write;
    }
    return;
}

sub _watch_read_terminal_xs_cb ($state) {
    my $self = $state->stream or return;
    $self->_on_read_terminal_ready;
}

sub _watch_write_terminal_xs_cb ($state) {
    my $self = $state->stream or return;
    $self->_on_write_terminal_ready;
}

sub new ($class, %opt) {
    croak 'new(): must be called as a class method' if ref $class;
    my $loop = delete $opt{loop};
    croak 'new(): loop must be an object implementing add() and watch_fd()'
        if defined($loop) && (!ref($loop) || !$loop->can('add')
            || !$loop->can('watch_fd'));
    my $fh = delete $opt{fh};
    my $read_fh = delete $opt{read_fh};
    my $write_fh = delete $opt{write_fh};
    my $pending = delete($opt{_pending}) // 0;
    my $data = delete $opt{data};
    my $transport = delete $opt{_transport};
    my %timeout_override;
    for my $name (qw(idle_timeout read_timeout write_timeout)) {
        $timeout_override{$name} = _timeout_value('new():', $name,
            delete $opt{$name}) if exists $opt{$name};
    }
    my $initial_deadline = exists($opt{deadline})
        ? _deadline_spec('new', delete $opt{deadline}) : undef;
    croak 'new(): unknown options: ' . join(', ', sort keys %opt) if %opt;
    croak 'new(): fh cannot be combined with read_fh or write_fh'
        if defined($fh) && (defined($read_fh) || defined($write_fh));
    if (defined $fh) {
        $read_fh = $fh;
        $write_fh = $fh;
    }
    croak 'new(): at least one of fh, read_fh, or write_fh is required'
        if !$pending && !defined($read_fh) && !defined($write_fh);
    croak 'new(): internal pending mode cannot have filehandles'
        if $pending && (defined($read_fh) || defined($write_fh));
    for my $pair ([read_fh => $read_fh], [write_fh => $write_fh]) {
        croak "new(): $pair->[0] must be a filehandle"
            if defined($pair->[1]) && !defined(fileno($pair->[1]));
    }
    croak 'new(): internal transport must implement _stream_transport_bind()'
        if defined($transport)
        && (!ref($transport) || !$transport->can('_stream_transport_bind'));

    my $descriptor = Linux::Event::Stream::_Descriptor::for_class($class);
    my %timeout = map {
        $_ => exists($timeout_override{$_})
            ? $timeout_override{$_} : $descriptor->{options}{$_}
    } qw(idle_timeout read_timeout write_timeout);
    my $self = bless {
        descriptor  => $descriptor,
        loop        => undef,
        read_fh     => $read_fh,
        write_fh    => $write_fh,
        read_capable => defined($read_fh) ? 1 : 0,
        write_capable => defined($write_fh) ? 1 : 0,
        read_watcher => undef,
        write_watcher => undef,
        data        => $data,
        transport   => $transport,
        xs_state    => undef,
        read_paused => 0,
        read_eof    => 0,
        read_closed => defined($read_fh) ? 0 : 1,
        write_ending => 0,
        write_ended  => defined($write_fh) ? 0 : 1,
        closed       => 0,
        detached     => 0,
        close_fired  => 0,
        last_error   => undef,
        transport_ready_fired => 0,
        transport_deadline_watcher => undef,
        transport_shutdown_started => 0,
        timeout => \%timeout,
        timeout_override => \%timeout_override,
        initial_deadline => $initial_deadline,
        operation_deadline_at => undef,
        operation_deadline_name => undef,
        operation_deadline_timeout => undef,
        deadline_timer => undef,
        deadline_started => 0,
        deadline_tracking => 0,
        deadline_read_started => undef,
        deadline_write_started => undef,
    }, $class;
    $self->_prepare_handles if !$pending;
    if ($loop) {
        my $attached = eval { $self->_attach_to_loop($loop); 1 };
        if (!$attached) {
            my $failure = $@ || 'Stream construction attachment failed';
            $self->_abort_failed_construction;
            die $failure;
        }
    }
    return $self;
}

sub connect ($class, %opt) {
    croak 'connect(): available only on Linux::Event::Socket subclasses';
}

sub CLONE ($class) {
    Linux::Event::Stream::_Descriptor::clear_cache();
    return;
}

sub CLONE_SKIP ($class) { 1 }

sub _prepare_handles ($self) {
    my ($read_fh, $write_fh) = @$self{qw(read_fh write_fh)};
    my %prepared;
    for my $handle (grep { defined } ($read_fh, $write_fh)) {
        my $fd = fileno($handle);
        next if $prepared{$fd}++;
        _set_nonblocking($handle);
    }
    my $descriptor = $self->{descriptor};
    my $xs_state = Linux::Event::Stream::XSState->new(
        $self,
        defined($read_fh) ? fileno($read_fh) : -1,
        defined($write_fh) ? fileno($write_fh) : -1,
        $descriptor->{xs},
    );
    $self->{xs_state} = $xs_state;

    my $initial_interest = 0x01;
    my $transport = $self->{transport};
    if (defined $transport) {
        croak 'new(): a native transport requires one shared read/write fh'
            if !defined($read_fh) || !defined($write_fh)
            || fileno($read_fh) != fileno($write_fh);
        my @binding;
        my $attached = eval {
            @binding = $transport->_stream_transport_bind(fileno($read_fh));
            $xs_state->_attach_transport(
                $transport, @binding[0, 1, 2],
            );
            1;
        };
        if (!$attached) {
            my $error = $@ || 'transport attachment failed';
            $xs_state->_close;
            $self->{xs_state} = undef;
            $self->_close_handles;
            die $error;
        }
        $initial_interest = $binding[3] // 0;
    }

    $self->{initial_interest} = $initial_interest
        if $initial_interest != 0x01;
    return;
}

sub _register_handles ($self) {
    my ($read_fh, $write_fh) = @$self{qw(read_fh write_fh)};
    my $read_fd = defined($read_fh) ? fileno($read_fh) : undef;
    my $write_fd = defined($write_fh) ? fileno($write_fh) : undef;
    my $initial_interest = delete($self->{initial_interest}) // 0x01;
    my $state = $self->{xs_state};

    if (defined($read_fd) && defined($write_fd) && $read_fd == $write_fd) {
        my $watcher = $self->{loop}->watch_fd(
            $read_fd, _internal => 1, fh => $read_fh, data => $state,
            read  => \&Linux::Event::Stream::XSState::_read_ready,
            write => \&Linux::Event::Stream::XSState::_write_ready,
            error => \&_watch_read_terminal_xs_cb,
            _callback_data_arg => 1,
        );
        $self->{read_watcher} = $watcher;
        $self->{write_watcher} = $watcher;
        $watcher->disable_write if !($initial_interest & 0x02);
        $watcher->disable_read if !($initial_interest & 0x01);
    } else {
        if (defined $read_fd) {
            $self->{read_watcher} = $self->{loop}->watch_fd(
                $read_fd, _internal => 1, fh => $read_fh, data => $state,
                read => \&Linux::Event::Stream::XSState::_read_ready,
                error => \&_watch_read_terminal_xs_cb,
                _callback_data_arg => 1,
            );
            $self->{read_watcher}->disable_read if !($initial_interest & 0x01);
        }
        if (defined $write_fd) {
            $self->{write_watcher} = $self->{loop}->watch_fd(
                $write_fd, _internal => 1, fh => $write_fh, data => $state,
                write => \&Linux::Event::Stream::XSState::_write_ready,
                error => \&_watch_write_terminal_xs_cb,
                _callback_data_arg => 1,
            );
            $self->{write_watcher}->disable_write
                if !($initial_interest & 0x02);
        }
    }
    $self->{read_watcher}->disable_read
        if $self->{read_watcher} && ($self->{read_paused}
            || ($state->consumer_paused && $state->transport_ready));
    return;
}

sub _attach_to_loop ($self, $loop) {
    croak 'add(): Stream is not unattached'
        if $self->{closed} || $self->{loop};
    $self->{loop} = $loop;
    if (!defined($self->{read_fh}) && !defined($self->{write_fh})) {
        my $attached = eval { $self->_attach_pending($loop); 1 };
        if (!$attached) {
            my $failure = $@ || 'connection attachment failed';
            $self->{loop} = undef;
            die $failure;
        }
        return $self;
    }

    my $saved_interest = $self->{initial_interest};
    my $registered = eval { $self->_register_handles; 1 };
    if (!$registered) {
        my $failure = $@ || 'Stream registration failed';
        $self->_cancel_io_watchers;
        $self->{initial_interest} = $saved_interest
            if defined $saved_interest;
        $self->{loop} = undef;
        die $failure;
    }
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
    $self->_start_stream_deadlines if !$transport;
    return $self;
}

sub _attach_pending ($self, $loop) {
    croak 'add(): Stream has no filehandle';
}

sub _abort_failed_construction ($self) {
    my $ignored;
    $self->{closed} = 1;
    $self->{loop} = undef;
    if (my $xs_state = delete $self->{xs_state}) {
        _teardown_step(\$ignored, sub { $xs_state->_close });
    }
    _teardown_step(\$ignored, sub { $self->_cancel_io_watchers });
    _teardown_step(\$ignored, sub { $self->_close_handles });
    return;
}

sub _fire_ready ($self) {
    return if $self->{closed} || ($self->{transport_ready_fired} & 0x02);
    $self->{transport_ready_fired} |= 0x02;
    if (my $callback = $self->{descriptor}{callbacks}{on_ready}) {
        $callback->($self);
    }
    return if $self->{closed};
    if ($self->{preconnect_write_blocked}
        && ($self->{preconnect_drain_reached}
            || !$self->{xs_state}->is_write_blocked)) {
        $self->_xs_drain;
    }
    return;
}

sub _request_write_ready ($self) {
    if (my $watcher = $self->{write_watcher}) {
        $watcher->enable_write;
    } else {
        $self->{initial_interest}
            = ($self->{initial_interest} // 0x01) | 0x02;
    }
    return;
}

sub _flush_preconnect_output ($self) {
    my $queued = delete $self->{preconnect_output} // [];
    $self->{preconnect_output} = [];
    $self->{preconnect_bytes} = 0;
    for my $bytes (@$queued) {
        my $status = $self->{xs_state}->_write($bytes);
        $self->_request_write_ready if $status & 0x02;
        last if $self->{closed};
    }
    if ($self->{write_ending} && !$self->{closed} && !$self->pending_bytes) {
        $self->_finish_write_side;
    }
    return;
}

sub fh ($self) {
    return undef if !defined($self->{read_fh}) || !defined($self->{write_fh});
    return fileno($self->{read_fh}) == fileno($self->{write_fh})
        ? $self->{read_fh} : undef;
}
sub read_fh ($self) { $self->{read_fh} }
sub write_fh ($self) { $self->{write_fh} }
sub read_fd ($self) {
    return defined($self->{read_fh}) ? fileno($self->{read_fh}) : undef;
}
sub write_fd ($self) {
    return defined($self->{write_fh}) ? fileno($self->{write_fh}) : undef;
}
sub has_read ($self) { !!$self->{read_capable} }
sub has_write ($self) { !!$self->{write_capable} }
sub loop ($self) { $self->{loop} }
sub state ($self) {
    return 'detached' if $self->{closed} && $self->{detached};
    return 'closed' if $self->{closed};
    return 'unattached' if !$self->{loop};
    return 'connecting' if $self->{connection};
    return 'active';
}
sub last_error ($self) { $self->{last_error} }
sub transport ($self) { $self->{transport} }
sub is_closed ($self) { !!$self->{closed} }
sub is_terminal ($self) { !!$self->{closed} }
sub is_read_paused ($self) { !!$self->{read_paused} }
sub is_read_eof ($self) { !!$self->{read_eof} }
sub is_read_closed ($self) { !!$self->{read_closed} }
sub is_write_ended ($self) { !!$self->{write_ended} }
sub is_write_blocked ($self) {
    return !!$self->{xs_state}->is_write_blocked if $self->{xs_state};
    return !!$self->{preconnect_write_blocked};
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

sub idle_timeout  ($self) { $self->{timeout}{idle_timeout} }
sub read_timeout  ($self) { $self->{timeout}{read_timeout} }
sub write_timeout ($self) { $self->{timeout}{write_timeout} }

sub set_deadline ($self, %option) {
    croak 'set_deadline(): stream is closed' if $self->{closed};
    my $spec = _deadline_spec('set_deadline', \%option);
    if (!$self->{deadline_started}) {
        $self->{initial_deadline} = $spec;
        return $self;
    }
    my $now = _deadline_now();
    $self->{operation_deadline_at} = $spec->{absolute}
        ? $spec->{seconds} : $now + $spec->{seconds};
    $self->{operation_deadline_name} = $spec->{operation};
    $self->{operation_deadline_timeout} = $spec->{absolute}
        ? undef : $spec->{seconds};
    $self->_rearm_stream_deadline;
    return $self;
}

sub clear_deadline ($self) {
    croak 'clear_deadline(): stream is closed' if $self->{closed};
    $self->{initial_deadline} = undef;
    $self->{operation_deadline_at} = undef;
    $self->{operation_deadline_name} = undef;
    $self->{operation_deadline_timeout} = undef;
    $self->_rearm_stream_deadline if $self->{deadline_started};
    return $self;
}

sub deadline ($self) {
    return $self->{operation_deadline_at}
        if defined $self->{operation_deadline_at};
    my $spec = $self->{initial_deadline} or return undef;
    return $spec->{seconds} if $spec->{absolute};
    return undef;
}

sub deadline_operation ($self) {
    return $self->{operation_deadline_name}
        // ($self->{initial_deadline} && $self->{initial_deadline}{operation});
}

sub _deadline_now () {
    require Linux::Event::Timer;
    return Linux::Event::Stream::_Deadline->now;
}

sub _needs_activity_tracking ($self) {
    return $self->{timeout}{idle_timeout} > 0
        || $self->{timeout}{read_timeout} > 0
        || $self->{timeout}{write_timeout} > 0;
}

sub _start_stream_deadlines ($self) {
    return if $self->{closed} || $self->{deadline_started};
    return if !$self->{loop} || !$self->{xs_state};
    $self->{deadline_started} = 1;
    return if !$self->_needs_activity_tracking
        && !$self->{initial_deadline};
    my $now = _deadline_now();
    if ($self->_needs_activity_tracking) {
        $self->{xs_state}->_set_activity_tracking(1);
        $self->{deadline_tracking} = 1;
    }
    $self->{deadline_read_started} = $now;
    $self->{deadline_write_started} = $now if $self->pending_bytes > 0;
    if (my $spec = delete $self->{initial_deadline}) {
        $self->{operation_deadline_at} = $spec->{absolute}
            ? $spec->{seconds} : $now + $spec->{seconds};
        $self->{operation_deadline_name} = $spec->{operation};
        $self->{operation_deadline_timeout} = $spec->{absolute}
            ? undef : $spec->{seconds};
    }
    $self->_rearm_stream_deadline;
    return;
}

sub _deadline_candidates ($self) {
    my @candidate;
    if (defined $self->{operation_deadline_at}) {
        push @candidate, {
            at        => $self->{operation_deadline_at},
            operation => $self->{operation_deadline_name},
            timeout   => $self->{operation_deadline_timeout},
            priority  => 0,
        };
    }

    my ($last_read, $last_write);
    if ($self->{deadline_tracking} && $self->{xs_state}) {
        ($last_read, $last_write)
            = $self->{xs_state}->_activity_snapshot;
    }
    my $idle = $self->{timeout}{idle_timeout};
    if ($idle > 0) {
        my $last = $last_read > $last_write ? $last_read : $last_write;
        push @candidate, {
            at => $last + $idle, operation => 'idle', timeout => $idle,
            priority => 3,
        };
    }
    my $read = $self->{timeout}{read_timeout};
    if ($read > 0 && defined($self->{read_fh}) && !$self->{read_paused}
        && !$self->{read_eof} && !$self->{read_closed}) {
        my $last = $last_read;
        $last = $self->{deadline_read_started}
            if defined($self->{deadline_read_started})
            && $self->{deadline_read_started} > $last;
        push @candidate, {
            at => $last + $read, operation => 'read', timeout => $read,
            priority => 2,
        };
    }
    my $write = $self->{timeout}{write_timeout};
    if ($write > 0 && !$self->{write_ended} && $self->pending_bytes > 0) {
        my $last = $last_write;
        $last = $self->{deadline_write_started}
            if defined($self->{deadline_write_started})
            && $self->{deadline_write_started} > $last;
        push @candidate, {
            at => $last + $write, operation => 'write', timeout => $write,
            priority => 1,
        };
    }
    return @candidate;
}

sub _rearm_stream_deadline ($self) {
    return if !$self->{deadline_started} || $self->{closed};
    my @candidate = sort {
        $a->{at} <=> $b->{at} || $a->{priority} <=> $b->{priority}
    } $self->_deadline_candidates;
    if (!@candidate) {
        if (my $timer = delete $self->{deadline_timer}) {
            $timer->cancel;
        }
        return;
    }

    my $at = $candidate[0]{at};
    if (my $timer = $self->{deadline_timer}) {
        if ($timer->is_active) {
            $timer->reschedule(at => $at);
            return;
        }
    }

    my $state = { stream => $self };
    weaken($state->{stream});
    my $timer = Linux::Event::Stream::_Deadline->new(
        at => $at, data => $state,
    );
    $self->{deadline_timer} = $timer;
    $self->{loop}->add($timer);
    return;
}

sub _stream_deadline_fired ($self, $timer) {
    return if $self->{closed} || $self->{deadline_timer} != $timer;
    my $now = _deadline_now();
    my @candidate = sort {
        $a->{at} <=> $b->{at} || $a->{priority} <=> $b->{priority}
    } $self->_deadline_candidates;
    my ($expired) = grep { $_->{at} <= $now } @candidate;
    if (!$expired) {
        $self->_rearm_stream_deadline;
        return;
    }

    my $operation = $expired->{operation};
    my $error = Linux::Event::Error->new(
        type      => 'timeout',
        operation => $operation,
        message   => "$operation deadline expired",
        timeout   => $expired->{timeout},
        deadline  => $expired->{at},
    );
    $self->_fail($error);
    return;
}

sub _cancel_stream_deadline ($self) {
    if (my $timer = delete $self->{deadline_timer}) {
        $timer->cancel;
    }
    if ($self->{deadline_tracking} && $self->{xs_state}) {
        $self->{xs_state}->_set_activity_tracking(0);
    }
    $self->{deadline_tracking} = 0;
    $self->{deadline_started} = 0;
    return;
}

sub _apply_transition_timeouts ($self, $descriptor) {
    for my $name (qw(idle_timeout read_timeout write_timeout)) {
        $self->{timeout}{$name} = $descriptor->{options}{$name}
            if !exists $self->{timeout_override}{$name};
    }
    return if !$self->{deadline_started} || !$self->{xs_state};
    $self->{xs_state}->_set_activity_tracking(0)
        if $self->{deadline_tracking};
    $self->{deadline_tracking} = 0;
    my $now = _deadline_now();
    if ($self->_needs_activity_tracking) {
        $self->{xs_state}->_set_activity_tracking(1);
        $self->{deadline_tracking} = 1;
    }
    $self->{deadline_read_started} = $now;
    $self->{deadline_write_started} = $self->pending_bytes > 0 ? $now : undef;
    $self->_rearm_stream_deadline;
    return;
}

sub write ($self, $bytes) {
    croak 'write(): stream is closed' if $self->{closed};
    croak 'write(): stream has no writable side'
        if !defined $self->{write_fh} && !$self->{connection};
    croak 'write(): writable side has ended'
        if $self->{write_ending} || $self->{write_ended};
    return 1 if !defined $bytes;
    croak 'write(): bytes must be a scalar byte string' if ref $bytes;
    $bytes = "$bytes";
    croak 'write(): bytes must be a scalar byte string'
        if !utf8::downgrade($bytes, 1);
    return 1 if $bytes eq '';

    if (!$self->{xs_state}) {
        croak 'write(): stream has no pending or active transport'
            if !$self->{connection};
        my $pending = ($self->{preconnect_bytes} // 0) + length($bytes);
        my $limit = $self->{descriptor}{options}{max_pending_bytes};
        if ($limit && $pending > $limit) {
            my $error = Linux::Event::Error->new(
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
        if ($pending > $self->{descriptor}{options}{high_watermark}) {
            $self->{preconnect_write_blocked} = 1;
            return 0;
        }
        return 1;
    }

    my $was_pending = $self->pending_bytes;
    my $status = $self->{xs_state}->_write($bytes);
    $self->_request_write_ready if $status & 0x02;
    if ($self->{deadline_started} && $self->{timeout}{write_timeout} > 0
        && !$was_pending && $self->pending_bytes > 0) {
        $self->{deadline_write_started} = _deadline_now();
        $self->_rearm_stream_deadline;
    }
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
        if $self->{closed} || $self->{write_ending} || $self->{write_ended}
        || (!defined($self->{write_fh}) && !$self->{connection});
    $self->write($final_bytes) if defined($final_bytes) && $final_bytes ne '';
    $self->{write_ending} = 1;
    $self->_finish_write_side
        if $self->{xs_state} && $self->pending_bytes == 0;
    return $self;
}

sub pause_read ($self) {
    return $self if $self->{closed};
    croak 'pause_read(): stream has no readable side'
        if !$self->{read_capable};
    return $self
        if $self->{read_eof} || $self->{read_closed} || $self->{read_paused};
    $self->{read_paused} = 1;
    $self->{xs_state}->_pause if $self->{xs_state};
    $self->{read_watcher}->disable_read if $self->{read_watcher};
    $self->_rearm_stream_deadline
        if $self->{deadline_started} && $self->{timeout}{read_timeout} > 0;
    return $self;
}

sub resume_read ($self) {
    return $self if $self->{closed};
    croak 'resume_read(): stream has no readable side'
        if !$self->{read_capable};
    return $self
        if $self->{read_eof} || $self->{read_closed} || !$self->{read_paused};
    $self->{read_paused} = 0;
    $self->{deadline_read_started} = _deadline_now()
        if $self->{deadline_started} && $self->{timeout}{read_timeout} > 0;
    $self->{xs_state}->_resume if $self->{xs_state};
    $self->{read_watcher}->enable_read
        if $self->{read_watcher} && !$self->{xs_state}->consumer_paused;
    $self->_rearm_stream_deadline
        if $self->{deadline_started} && $self->{timeout}{read_timeout} > 0;
    return $self;
}

sub transition_to ($self, $class, %opt) {
    croak 'transition_to(): stream is closed' if $self->{closed};
    croak 'transition_to(): target class is required'
        if !defined($class) || ref($class) || $class eq '';
    croak "transition_to(): $class is already active"
        if ref($self) eq $class;
    my $source_socket = $self->isa('Linux::Event::Socket') ? 1 : 0;
    my $target_socket = $class->isa('Linux::Event::Socket') ? 1 : 0;
    croak 'transition_to(): cannot cross the Stream/Socket transport boundary'
        if $source_socket != $target_socket;

    my $input = delete $opt{input};
    croak 'transition_to(): input must be a byte string'
        if defined($input) && ref($input);
    if (defined $input) {
        $input = "$input";
        croak 'transition_to(): input must be a byte string'
            if !utf8::downgrade($input, 1);
    }
    croak 'transition_to(): unknown options: ' . join(', ', sort keys %opt)
        if %opt;

    my $descriptor = Linux::Event::Stream::_Descriptor::for_class($class);
    my $xs_state = $self->{xs_state}
        // croak 'transition_to(): stream has no native state';

    # XS validates and swaps the immutable descriptor without invoking a
    # callback. Update the Perl object's type before buffered input is allowed
    # to enter the new callback set.
    $xs_state->_transition($descriptor->{xs}, $input);
    $self->{descriptor} = $descriptor;
    bless $self, $class;
    $self->_apply_transition_timeouts($descriptor);
    $xs_state->_transition_ready;
    return $self;
}

sub close ($self) {
    $self->_close_now(1);
    return $self;
}

sub close_read ($self) {
    return $self if $self->{closed} || $self->{read_closed} || $self->{read_eof};
    $self->{read_closed} = 1;
    my $failure;
    _teardown_step(\$failure, sub {
        $self->{xs_state}->_close_read(6) if $self->{xs_state};
    });
    _teardown_step(\$failure, sub { $self->_release_read_side });
    _teardown_step(\$failure, sub { $self->_close_now(1) })
        if $self->{write_ended};
    die $failure if defined $failure;
    return $self;
}

sub close_write ($self) {
    return $self if $self->{closed} || $self->{write_ended};
    my $failure;
    _teardown_step(\$failure, sub {
        $self->{xs_state}->_close_write if $self->{xs_state};
    });
    $self->{write_ending} = 0;
    $self->{write_ended} = 1;
    _teardown_step(\$failure, sub { $self->_release_write_side });
    _teardown_step(\$failure, sub { $self->_close_now(1) })
        if $self->{read_eof} || $self->{read_closed};
    die $failure if defined $failure;
    return $self;
}

sub _release_read_side ($self) {
    my $read_watcher = delete $self->{read_watcher};
    if ($read_watcher) {
        if ($self->{write_watcher}
            && refaddr($read_watcher) == refaddr($self->{write_watcher})) {
            $read_watcher->disable_read;
        } else {
            $read_watcher->cancel;
        }
    }
    my $read_fh = $self->{read_fh};
    if (defined($read_fh) && (!$self->{write_fh}
        || fileno($read_fh) != fileno($self->{write_fh}))) {
        CORE::close($read_fh);
        $self->{read_fh} = undef;
    }
    return;
}

sub _release_write_side ($self) {
    my $write_watcher = delete $self->{write_watcher};
    if ($write_watcher) {
        if ($self->{read_watcher}
            && refaddr($write_watcher) == refaddr($self->{read_watcher})) {
            $write_watcher->disable_write;
        } else {
            $write_watcher->cancel;
        }
    }
    my $write_fh = $self->{write_fh};
    if (defined($write_fh) && (!$self->{read_fh}
        || fileno($write_fh) != fileno($self->{read_fh}))) {
        CORE::close($write_fh);
        $self->{write_fh} = undef;
    }
    return;
}

sub detach ($self) {
    croak 'detach(): stream is already closed' if $self->{closed};
    croak 'detach(): stream is not established'
        if !defined($self->{read_fh}) && !defined($self->{write_fh});
    croak 'detach(): pending output must drain before detach'
        if $self->pending_bytes;
    croak 'detach(): cannot detach a non-plain transport'
        if ($self->transport_name // 'plain') ne 'plain';
    my $handles = {
        read_fh  => $self->{read_fh},
        write_fh => $self->{write_fh},
    };
    my $failure;
    _teardown_step(\$failure, sub { $self->_cancel_stream_deadline });
    if (my $xs_state = delete $self->{xs_state}) {
        _teardown_step(\$failure, sub { $xs_state->_close(5) });
    }
    _teardown_step(\$failure, sub { $self->_cancel_io_watchers });
    $self->{closed} = 1;
    $self->{detached} = 1;
    if (defined $failure) {
        _teardown_step(\$failure, sub { $self->_close_handles });
        die $failure;
    } else {
        $self->{read_fh} = undef;
        $self->{write_fh} = undef;
    }
    return $handles;
}

sub _on_read_terminal_ready ($self) {
    return if $self->{closed};
    $self->{xs_state}->_read_ready
        if !$self->{read_paused} && !$self->{read_eof} && $self->{xs_state};
}

sub _on_write_terminal_ready ($self) {
    return if $self->{closed} || $self->{write_ended};
    if ($self->pending_bytes) {
        $self->{xs_state}->_write_ready;
        return if $self->{closed} || !$self->pending_bytes;
    }
    local $! = Errno::EPIPE();
    $self->_fail_io('write', 0 + $!);
}

sub _finish_write_side ($self) {
    return if $self->{closed} || $self->{write_ended};
    return if $self->pending_bytes > 0;

    return if !$self->_finish_transport_write;

    $self->{write_ending} = 0;
    $self->{write_ended} = 1;
    if (defined($self->{write_fh}) && (!$self->{read_fh}
        || fileno($self->{write_fh}) != fileno($self->{read_fh}))) {
        my $watcher = delete $self->{write_watcher};
        $watcher->cancel if $watcher;
        CORE::close($self->{write_fh});
        $self->{write_fh} = undef;
    }
    $self->_clear_transport_deadline;
    $self->_close_now(1) if $self->{read_eof} || $self->{read_closed};
}

sub _finish_transport_write ($self) { 1 }

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
    my $error = Linux::Event::Error->new(
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
    if (my $watcher = delete $self->{read_watcher}) {
        if (!$self->{write_watcher}
            || refaddr($watcher) != refaddr($self->{write_watcher})) {
            $watcher->cancel;
        } else {
            $watcher->disable_read;
        }
    }
    if (defined($self->{read_fh}) && (!$self->{write_fh}
        || fileno($self->{read_fh}) != fileno($self->{write_fh}))) {
        CORE::close($self->{read_fh});
        $self->{read_fh} = undef;
    }
    $self->_rearm_stream_deadline
        if $self->{deadline_started} && $self->{timeout}{read_timeout} > 0;

    if (my $callback = $self->{descriptor}{callbacks}{on_eof}) {
        $callback->($self);
    }
    $self->_close_now(1) if $self->{write_ended};
}

sub _fail_io ($self, $operation, $errno) {
    local $! = $errno;
    my $error = Linux::Event::Error->new(
        type      => 'io',
        operation => $operation,
        errno     => $errno,
        message   => "$!",
    );
    $self->_fail($error);
}

sub _fail_framing ($self, $message) {
    my $error = Linux::Event::Error->new(
        type      => 'framing',
        operation => 'frame',
        message   => $message,
    );
    $self->_fail($error);
}

sub _fail ($self, $error) {
    return if $self->{closed};
    $self->{last_error} = $error;
    my $failure;
    if (my $callback = $self->{descriptor}{callbacks}{on_error}) {
        my $reported = eval { $callback->($self, $error); 1 };
        $failure = $@ if !$reported;
    }
    my $closed = eval { $self->_close_now(1); 1 };
    $failure //= $@ if !$closed;
    die $failure if defined $failure;
    return;
}

sub _close_now ($self, $close_fh) {
    return if $self->{closed};
    $self->{closed} = 1;
    my $failure;
    _teardown_step(\$failure, sub { $self->_cancel_pending });
    $self->{preconnect_output} = [];
    $self->{preconnect_bytes} = 0;
    delete $self->{preconnect_write_blocked};
    delete $self->{preconnect_drain_reached};
    _teardown_step(\$failure, sub { $self->_cancel_stream_deadline });
    _teardown_step(\$failure, sub { $self->_destroy_transport_deadline });

    if (my $xs_state = delete $self->{xs_state}) {
        _teardown_step(\$failure, sub { $xs_state->_close(4) });
    }
    _teardown_step(\$failure, sub { $self->_cancel_io_watchers });
    _teardown_step(\$failure, sub { $self->_close_handles }) if $close_fh;

    if (!$self->{detached} && !$self->{close_fired}++) {
        if (my $callback = $self->{descriptor}{callbacks}{on_close}) {
            _teardown_step(\$failure, sub { $callback->($self) });
        }
    }
    die $failure if defined $failure;
    return;
}

sub _teardown_step ($failure, $callback) {
    my $completed = eval { $callback->(); 1 };
    if (!$completed && !defined $$failure) {
        $$failure = $@ || "Stream teardown step failed\n";
    }
    return;
}

sub _cancel_pending ($self) { return }

sub _cancel_io_watchers ($self) {
    my $read = delete $self->{read_watcher};
    my $write = delete $self->{write_watcher};
    $read->cancel if $read;
    $write->cancel if $write && (!$read || refaddr($write) != refaddr($read));
    return;
}

sub _close_handles ($self) {
    my $read = delete $self->{read_fh};
    my $write = delete $self->{write_fh};
    my $read_fd = defined($read) ? fileno($read) : undef;
    my $write_fd = defined($write) ? fileno($write) : undef;
    CORE::close($read) if defined $read;
    CORE::close($write) if defined($write)
        && (!defined($read_fd) || $write_fd != $read_fd);
    return;
}

sub _set_nonblocking ($fh) {
    my $flags = fcntl($fh, F_GETFL, 0);
    croak "new(): fcntl(F_GETFL): $!" if !defined $flags;
    if (!($flags & O_NONBLOCK)) {
        fcntl($fh, F_SETFL, $flags | O_NONBLOCK)
            or croak "new(): fcntl(F_SETFL O_NONBLOCK): $!";
    }
    my $descriptor_flags = fcntl($fh, F_GETFD, 0);
    croak "new(): fcntl(F_GETFD): $!" if !defined $descriptor_flags;
    if (!($descriptor_flags & FD_CLOEXEC)) {
        fcntl($fh, F_SETFD, $descriptor_flags | FD_CLOEXEC)
            or croak "new(): fcntl(F_SETFD FD_CLOEXEC): $!";
    }
}

1;

package Linux::Event::Stream::XSDescriptor;
sub new ($class, $spec) {
    return $class->_new_validated(
        Linux::Event::Stream::_Descriptor::_validate_xs_spec($spec),
    );
}
sub CLONE_SKIP ($class) { 1 }

package Linux::Event::Stream::XSState;
sub CLONE_SKIP ($class) { 1 }

package Linux::Event::Stream::_Deadline;
use parent -norequire, 'Linux::Event::Timer';

sub on_timer ($timer) {
    my $state = $timer->data;
    my $stream = $state->{stream};
    $stream->_stream_deadline_fired($timer) if $stream;
    return;
}

package Linux::Event::Stream;

__END__

=head1 NAME

Linux::Event::Stream - generic native buffered byte-stream I/O

=head1 SYNOPSIS

A framed console using separate handles:

  package Console;
  use parent 'Linux::Event::Stream';
  use Linux::Event::Framer 'Delimiter', "\n";

  sub on_message ($stream, $line) {
      $stream->write("You typed: $line\n");
  }

  package main;
  my $console = Console->new(
      loop     => $loop,
      read_fh  => \*STDIN,
      write_fh => \*STDOUT,
  );

A raw duplex handle:

  package ByteStream;
  use parent 'Linux::Event::Stream';

  sub on_data ($stream, $bytes) {
      $stream->write($bytes);
  }

  my $stream = ByteStream->new(fh => $handle);
  $loop->add($stream);

=head1 DESCRIPTION

C<Linux::Event::Stream> is the generic sequential-byte I/O abstraction above
L<Linux::Event::Loop>. It accepts a shared byte-oriented filehandle, separate
read and write handles, or either direction alone. Pipes, terminals, FIFOs,
process standard I/O, and connected sockets through L<Linux::Event::Socket>
all reuse the same native engine.

Stream owns native read draining, immediate and queued writes, input framing,
raw and framed callback batching, buffering limits, backpressure, established
deadlines, and directional lifecycle. It does not inspect socket addresses,
apply socket options, initiate connections, or assume that either handle is a
socket.

C<Linux::Event::Stream> is a base class. Applications define a subclass so its
callbacks, framer, native consumer, and immutable tuning policy can be resolved
once and cached outside per-instance state.

=head1 DEFINING A STREAM TYPE

A readable raw Stream defines C<on_data> and does not declare a framer:

  package RawInput;
  use parent 'Linux::Event::Stream';

  sub on_data ($stream, $bytes) {
      consume($bytes);
  }

A framed Stream declares one native framer and ordinarily defines
C<on_message>:

  package Lines;
  use parent 'Linux::Event::Stream';
  use Linux::Event::Framer 'Delimiter', "\n";

  sub on_message ($stream, $line) {
      consume_line($line);
  }

A framed subclass may instead set a positive C<message_batch_size> and define
C<on_messages>. A raw subclass may set C<read_batch_bytes> to coalesce reads
before C<on_data>. Neither batching mode waits for a future readiness event to
fill a batch; partial batches flush when the current native drain ends.

A write-only Stream needs no input callback. A readable raw Stream requires
C<on_data>. A readable framed Stream requires C<on_message>,
C<on_messages> with batching enabled, or a native framed-message consumer.

=head1 CONSTRUCTION

=head2 new

The supported handle forms are:

  MyStream->new(fh => $duplex_handle);
  MyStream->new(read_fh => $input, write_fh => $output);
  MyStream->new(read_fh => $input);
  MyStream->new(write_fh => $output);

C<fh> supplies both directions and cannot be combined with C<read_fh> or
C<write_fh>. At least one direction is required. C<loop> attaches the object
before C<new> returns; otherwise attach it later with
C<< $loop->add($stream) >>. C<data> stores arbitrary per-instance application
state.

Stream takes ownership of every distinct supplied handle and sets it
nonblocking and close-on-exec. Supplying the same descriptor in both
directional options still creates one shared native registration.

C<idle_timeout>, C<read_timeout>, and C<write_timeout> override class defaults
for one instance. C<deadline> accepts a hash reference containing exactly one
of C<after> or C<at>, plus an C<operation> label.

Constructor callbacks, framers, and tuning values are intentionally not
accepted. They are class policy. For connected stream sockets, outbound
connection acquisition, TLS roles, and socket-specific constructor options,
use L<Linux::Event::Socket>.

=head1 CLASS STREAM OPTIONS

A subclass may define C<stream_options>. It is called once when the cached
class descriptor is built:

  sub stream_options ($class) {
      return (
          read_size          => 65_536,
          read_budget_bytes  => 0,
          read_batch_bytes   => 0,
          message_batch_size => 0,
          high_watermark     => 1_048_576,
          low_watermark      => 262_144,
          max_pending_bytes  => 0,
          max_buffer         => 8_388_608,
          idle_timeout       => 0,
          read_timeout       => 0,
          write_timeout      => 0,
      );
  }

C<read_size> is the native syscall buffer size. C<read_budget_bytes> bounds one
readiness drain; zero is unlimited. C<read_batch_bytes> is raw-mode callback
coalescing, and C<message_batch_size> selects framed C<on_messages> delivery.
C<max_buffer> bounds retained framed input.

C<high_watermark> and C<low_watermark> implement cooperative write
backpressure. C<max_pending_bytes> is a hard output-queue limit; zero leaves it
unlimited. The three timeout values are non-negative seconds, with zero
disabling that policy.

C<read_batch_bytes> is valid only for raw Streams. C<message_batch_size> is
valid only for framed Streams and requires C<on_messages> instead of
C<on_message>. Invalid combinations fail when the class descriptor is first
built.

Socket tuning is deliberately separate in
L<Linux::Event::Socket/socket_options>.

=head1 CALLBACKS

Callbacks are ordinary named methods resolved once from the subclass:

=over 4

=item C<on_data($stream, $bytes)>

Receives raw byte strings. It is required for a readable unframed Stream.

=item C<on_message($stream, $message)>

Receives one complete message from a declared framer.

=item C<on_messages($stream, $messages)>

Receives an array reference of complete messages when
C<message_batch_size> is enabled.

=item C<on_drain($stream)>

Runs once after a high-watermark blocked interval falls to or below the low
watermark.

=item C<on_eof($stream)>

Runs when the readable side reaches EOF. EOF does not end an independent
writable side.

=item C<on_error($stream, $error)>

Receives a L<Linux::Event::Error> before failure closes the Stream.

=item C<on_close($stream)>

Runs once after explicit full close, failure, or both available directions
become terminal. Required watcher, handle, and ownership teardown completes
before this callback. It still runs if earlier terminal consumer/provider work
throws, after which the first teardown exception is rethrown. It is not called
by C<detach>.

=item C<on_ready($stream)>

Runs once when an attached Stream is ready for application I/O.

=item C<on_transport_ready($stream)>

Runs immediately before C<on_ready> when an asynchronous non-plain transport
becomes ready. Transport providers are internal; most applications use only
C<on_ready>.

=back

Callback exceptions are not swallowed. In ordinary framed mode, pause, close,
and protocol transition take effect after each C<on_message>. In batch mode,
they take effect after the complete array passed to C<on_messages>.

=head1 DIRECTIONAL LIFECYCLE

Read and write capability are independent.

Read EOF marks only the read direction terminal and calls C<on_eof>. For a
distinct read handle, Stream then closes that handle. A shared generic handle
has no universal kernel half-close operation, so the descriptor remains owned
while the write direction is usable.

C<end> optionally writes final bytes, drains queued output, and then ends only
the write direction. For a distinct write handle, Stream closes it after the
queue drains. For a shared generic handle, Stream records the logical end
without assuming socket C<shutdown> semantics.

C<close_read> and C<close_write> stop one direction immediately.
C<close_write> discards queued output. Neither operation calls C<on_eof>.
C<close> immediately stops both directions and may discard output.
C<on_close> runs when both configured directions are terminal.

C<detach> requires an established plain transport and an empty output queue. It
cancels Stream ownership without closing the handles and returns:

  {
      read_fh  => $read_handle_or_undef,
      write_fh => $write_handle_or_undef,
  }

The two values may refer to the same shared handle.

If terminal provider work throws during C<detach>, the handles cannot be
returned. Stream therefore cancels its watchers, closes those otherwise
unreturned handles, records the detached terminal state, and rethrows the
provider exception.

L<Linux::Event::Socket> maps these generic directional states onto socket
C<shutdown> where appropriate.

=head1 METHODS

=head2 write($bytes)

Attempts an immediate native write and queues only the unsent remainder.
Writable readiness is enabled only after partial output or C<EAGAIN> and is
disabled again after the queue drains.

The return value is true while cooperative backpressure is clear and false
after pending output exceeds C<high_watermark>. A false return does not reject
the bytes; wait for C<on_drain> before producing more.

If nonzero C<max_pending_bytes> would be exceeded, the unsent remainder is not
queued, an C<output_limit> error is reported, and the Stream closes. Input must
be a byte string.

=head2 send($payload)

Available only to a framed subclass. It applies the declared outbound framing
rule and passes the resulting bytes to C<write>. Serialization remains a
separate concern.

=head2 end($final_bytes = undef)

Queues optional final bytes, drains all accepted output, and gracefully ends
the write direction. It does not stop reading.

=head2 pause_read / resume_read

Disable and re-enable read readiness without destroying buffered parser state.
A pause requested before attachment remains in effect after attachment.
C<read_timeout> is suspended while paused and restarts on resume.

=head2 close_read / close_write / close

C<close_read> immediately stops input. C<close_write> immediately discards
queued output and stops output. C<close> immediately closes the complete
Stream. All return the Stream.

=head2 detach

Transfers the owned plain handles as described in
L</DIRECTIONAL LIFECYCLE>. Non-plain transports and Streams with queued output
cannot be detached.

=head2 transition_to($class, input => $bytes)

Reblesses an active Stream into another loaded Stream subclass while retaining
the handles, native state, parser storage, output queue, backpressure state,
deadlines, pause state, and C<data>. Future callbacks and framing come from the
target class descriptor.

Unread framed bytes are reinterpreted by the target parser. A raw callback may
supply an unconsumed suffix with C<input>. The operation is atomic if target
limits reject existing buffered input or output.

A generic Stream cannot transition to a Socket subclass, and a Socket cannot
transition to a generic Stream subclass. Transport acquisition and TLS state
are not changed by protocol transition.

=head2 fh / read_fh / write_fh

C<fh> returns the shared handle when both directions use the same descriptor,
otherwise undef. C<read_fh> and C<write_fh> return the current directional
handles.

=head2 read_fd / write_fd

Return the current directional descriptor numbers, or undef when that handle
is absent.

=head2 has_read / has_write

Return the stable capabilities configured at construction. They remain useful
after a direction reaches EOF or is closed.

=head2 pending_bytes / is_write_blocked

Report native queued output and cooperative backpressure state.

=head2 idle_timeout / read_timeout / write_timeout

Return effective established timeout policy in seconds. Idle timeout resets on
read or write progress. Read timeout tracks active input and is suspended by
C<pause_read>. Write timeout exists only while output is queued.

=head2 set_deadline / clear_deadline

  $stream->set_deadline(after => 5, operation => 'response');
  $stream->set_deadline(at => $absolute, operation => 'response');
  $stream->clear_deadline;

Set, replace, or remove one overall operation deadline. C<after> is seconds
from activation; C<at> is an absolute monotonic deadline. An overall deadline
does not reset on I/O.

=head2 deadline / deadline_operation

Return the active absolute operation deadline and its label. Before activation,
a relative deadline has no absolute value and C<deadline> returns undef.

=head2 transport / transport_name / is_transport_ready

Return the internal transport provider, active native transport name, and
readiness state. Ordinary handles report C<plain> after native activation.
These methods also support Socket TLS introspection without putting TLS policy
in generic Stream.

=head2 data([$value])

Get or replace arbitrary application state.

=head2 loop / state / last_error

Return the owning Loop, lifecycle state, and the error that caused closure.
State is C<unattached>, C<connecting> for Socket acquisition, C<active>,
C<detached>, or C<closed>.

=head2 is_read_paused / is_read_eof / is_read_closed

Report whether input is paused, ended by peer EOF, or stopped explicitly by
C<close_read>.

=head2 is_write_ended / is_closed / is_terminal

Report write-direction and complete-object terminal state.

=head1 FRAMING AND NATIVE CONSUMERS

Framers operate on incoming bytes and therefore belong to generic Stream.
Built-in declarations are documented in L<Linux::Event::Framer> and
F<docs/FRAMING.md>.

The versioned native framed-message consumer ABI is also attached to generic
Stream rather than Socket. Its provider boundary and event rules are documented
in F<docs/STREAM-CONSUMER-ABI.md>. Linux::Event core does not depend on an
async or Future implementation.

=head1 ERROR POLICY

Read, write, framing, timeout, transport, and output-limit failures are reported
as L<Linux::Event::Error> values through C<on_error>, then close the Stream.
Application callback exceptions propagate to the caller.

=head1 PERFORMANCE

One XS state owns both directions, one parser, one native consumer context, and
one segmented output queue. A shared handle uses one watcher; split handles use
two watchers pointing to that same state. Native code drains reads, finds frame
boundaries, issues immediate writes, drains queued segments with C<writev>, and
accounts for backpressure. Perl is entered only at semantic callback
boundaries.

=cut
