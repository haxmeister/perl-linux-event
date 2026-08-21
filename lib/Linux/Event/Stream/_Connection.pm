package Linux::Event::Stream::_Connection;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_025';

use Carp qw(croak);
use Errno ();
use Scalar::Util qw(refaddr);
use Socket qw(
    AF_INET AF_INET6 AF_UNIX
    SOCK_STREAM SOCK_NONBLOCK SOCK_CLOEXEC
    SOL_SOCKET SO_ERROR
    getaddrinfo inet_pton
    pack_sockaddr_in pack_sockaddr_in6 pack_sockaddr_un
);

use Linux::Event::Error;

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

sub _timeout ($value) {
    $value = 10 if !defined $value;
    croak 'new(): timeout must be a non-negative number of seconds'
        if ref($value)
        || $value !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/
        || $value < 0;
    return 0 + $value;
}

sub _target_error_fields ($self) {
    return (
        host   => $self->{host},
        port   => $self->{port},
        path   => $self->{unix},
        family => $self->{family},
        attempts => $self->{attempt_count},
    );
}

sub _error ($self, %arg) {
    return Linux::Event::Error->new(
        _target_error_fields($self),
        %arg,
    );
}

sub _system_message ($errno) {
    local $! = $errno;
    return "$!";
}

sub new ($class, %opt) {
    croak 'new(): must be called as a class method' if ref $class;
    croak 'new(): internal connection must be created for a Stream'
        if $class ne __PACKAGE__;
    my $loop = delete $opt{loop};
    croak 'new(): loop must be an object implementing add(), watch(), and watch_fd()'
        if defined($loop) && (!ref($loop) || !$loop->can('add')
            || !$loop->can('watch') || !$loop->can('watch_fd'));
    my $stream = delete $opt{stream};
    croak 'new(): stream must be a Linux::Event::Stream object'
        if !ref($stream) || !$stream->isa('Linux::Event::Stream');
    my $timeout = _timeout(delete $opt{timeout});

    my $host_mode = exists($opt{host}) || exists($opt{port});
    my $unix_mode = exists $opt{unix};
    my $sockaddr_mode = exists $opt{sockaddr};
    my $mode_count = ($host_mode ? 1 : 0) + ($unix_mode ? 1 : 0)
        + ($sockaddr_mode ? 1 : 0);
    croak 'new(): exactly one address mode is required '
        . '(host/port, unix, or sockaddr)'
        if $mode_count != 1;

    my ($host, $port, $unix, $sockaddr, $family);
    if ($host_mode) {
        $host = delete $opt{host};
        $port = delete $opt{port};
        croak 'new(): host is required' if !defined $host;
        croak 'new(): host must be a non-empty string'
            if ref($host) || $host eq '';
        croak 'new(): port is required' if !defined $port;
        croak 'new(): port must be an integer'
            if ref($port) || $port !~ /\A\d+\z/;
        $port = 0 + $port;
        croak 'new(): port must be between 0 and 65535'
            if $port < 0 || $port > 65535;
        croak 'new(): family is not allowed with host/port'
            if exists $opt{family};
    } elsif ($unix_mode) {
        $unix = delete $opt{unix};
        croak 'new(): unix must be a non-empty string'
            if !defined($unix) || ref($unix) || $unix eq '';
        croak 'new(): family is not allowed with unix'
            if exists $opt{family};
    } else {
        $sockaddr = delete $opt{sockaddr};
        $family = delete $opt{family};
        croak 'new(): sockaddr must be a defined scalar'
            if !defined($sockaddr) || ref($sockaddr);
        croak 'new(): family is required with sockaddr'
            if !defined $family;
        croak 'new(): family must be a non-negative integer'
            if ref($family) || $family !~ /\A\d+\z/;
        $family = 0 + $family;
    }
    croak 'new(): unknown options: ' . join(', ', sort keys %opt) if %opt;

    my $self = bless {
        loop          => undef,
        stream        => $stream,
        timeout       => $timeout,
        host          => $host,
        port          => $port,
        unix          => $unix,
        sockaddr      => $sockaddr,
        family        => $family,
        state         => 'detached',
        error         => undef,
        candidates    => [],
        candidate_at  => 0,
        attempts      => {},
        attempt_count => 0,
        next_attempt  => 1,
        last_errno    => undef,
        last_operation => undef,
        timer_fd      => undef,
        timer_watcher => undef,
        timer_role    => undef,
        pending_result => undef,
    }, $class;

    $self->_resolve_candidates;
    $self->_attach_to_loop($loop) if $loop;
    return $self;
}

sub loop       ($self) { $self->{loop} }
sub host       ($self) { $self->{host} }
sub port       ($self) { $self->{port} }
sub path       ($self) { $self->{unix} }
sub family     ($self) { $self->{family} }
sub timeout    ($self) { $self->{timeout} }
sub state      ($self) { $self->{state} }
sub error      ($self) { $self->{error} }
sub attempts   ($self) { $self->{attempt_count} }
sub is_pending ($self) { $self->{state} eq 'pending' }
sub is_done    ($self) {
    return $self->{state} eq 'connected' || $self->{state} eq 'failed'
        || $self->{state} eq 'cancelled';
}
sub is_terminal ($self) { $self->is_done }

sub _attach_to_loop ($self, $loop) {
    croak 'add(): Stream connection is not detached'
        if $self->{state} ne 'detached' || $self->{loop};
    $self->{loop} = $loop;
    $self->{state} = 'pending';
    if ($self->{pending_result}) {
        my $fd = $self->_ensure_timer;
        $self->{timer_role} = 'dispatch';
        __PACKAGE__->_timerfd_arm($fd, 0.000000001);
    } else {
        $self->_arm_timeout if $self->{timeout} > 0;
        $self->_attempt_next;
    }
    return $self;
}

sub cancel ($self) {
    return 0 if $self->is_done;
    $self->{state} = 'cancelled';
    $self->{pending_result} = undef;
    $self->_close_attempts;
    $self->_close_timer;
    return 1;
}

sub _resolve_candidates ($self) {
    if (defined $self->{unix}) {
        push @{ $self->{candidates} }, {
            family   => AF_UNIX,
            protocol => 0,
            sockaddr => pack_sockaddr_un($self->{unix}),
        };
        return;
    }
    if (defined $self->{sockaddr}) {
        push @{ $self->{candidates} }, {
            family   => $self->{family},
            protocol => 0,
            sockaddr => $self->{sockaddr},
        };
        return;
    }

    my $literal = $self->{host};
    $literal =~ s/\A[ \t\r\n]+//;
    $literal =~ s/[ \t\r\n]+\z//;
    if (length($literal) >= 2 && substr($literal, 0, 1) eq '['
        && substr($literal, -1, 1) eq ']') {
        $literal = substr($literal, 1, length($literal) - 2);
    }

    my $packed4 = inet_pton(AF_INET, $literal);
    if (defined $packed4) {
        push @{ $self->{candidates} }, {
            family   => AF_INET,
            protocol => 0,
            sockaddr => pack_sockaddr_in($self->{port}, $packed4),
        };
        return;
    }
    my $packed6 = inet_pton(AF_INET6, $literal);
    if (defined $packed6) {
        push @{ $self->{candidates} }, {
            family   => AF_INET6,
            protocol => 0,
            sockaddr => pack_sockaddr_in6($self->{port}, $packed6),
        };
        return;
    }

    my ($resolver_error, @result) = getaddrinfo(
        $self->{host}, $self->{port}, { socktype => SOCK_STREAM },
    );
    if ($resolver_error) {
        my $message = "$resolver_error";
        my $errno = $message =~ /NONAME|NODATA|NO_DATA/i
            ? Errno::ENOENT() : Errno::EIO();
        $self->_queue_error($self->_error(
            type             => 'resolve',
            operation        => 'resolve',
            errno            => $errno,
            message          => $message,
            resolver_message => $message,
        ));
        return;
    }
    for my $result (@result) {
        next if !defined($result->{family}) || !defined($result->{addr});
        push @{ $self->{candidates} }, {
            family   => $result->{family},
            protocol => $result->{protocol} // 0,
            sockaddr => $result->{addr},
        };
    }
    if (!@{ $self->{candidates} }) {
        $self->_queue_error($self->_error(
            type      => 'resolve',
            operation => 'resolve',
            errno     => Errno::ENOENT(),
            message   => 'hostname resolution returned no stream addresses',
        ));
    }
    return;
}

sub _attempt_next ($self) {
    return if $self->{state} ne 'pending' || $self->{pending_result};

    while ($self->{candidate_at} < @{ $self->{candidates} }) {
        my $candidate = $self->{candidates}[ $self->{candidate_at}++ ];
        my $fh;
        $self->{attempt_count}++;
        if (!socket(
            $fh,
            $candidate->{family},
            SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC,
            $candidate->{protocol},
        )) {
            $self->{last_errno} = 0 + $!;
            $self->{last_operation} = 'socket';
            next;
        }

        my $id = $self->{next_attempt}++;
        my $attempt = {
            request => $self,
            id      => $id,
            fh      => $fh,
            watcher => undef,
        };
        $self->{attempts}{$id} = $attempt;

        if (connect($fh, $candidate->{sockaddr})) {
            $self->_queue_success($attempt);
            return;
        }

        my $errno = 0 + $!;
        if ($errno == Errno::EINPROGRESS()
            || $errno == Errno::EALREADY()
            || $errno == Errno::EWOULDBLOCK()) {
            my $watcher = $self->{loop}->watch_fd(
                fileno($fh),
                fh    => $fh,
                data  => $attempt,
                write => \&_attempt_ready,
                error => \&_attempt_ready,
                _callback_data_arg => 1,
            );
            $attempt->{watcher} = $watcher;
            return;
        }

        $self->{last_errno} = $errno;
        $self->{last_operation} = 'connect';
        delete $self->{attempts}{$id};
        close $fh;
    }

    my $errno = $self->{last_errno} // Errno::EIO();
    my $operation = $self->{last_operation} // 'connect';
    my $type = $operation eq 'socket' ? 'socket' : 'connect';
    $self->_queue_error($self->_error(
        type      => $type,
        operation => $operation,
        errno     => $errno,
        message   => _system_message($errno),
    ));
    return;
}

sub _attempt_ready ($attempt) {
    my $self = $attempt->{request};
    return if !$self || $self->{state} ne 'pending';
    return if !exists $self->{attempts}{ $attempt->{id} };

    my $raw = getsockopt($attempt->{fh}, SOL_SOCKET, SO_ERROR);
    my $errno;
    if (!defined $raw) {
        $errno = 0 + $!;
    } elsif (length($raw) < 4) {
        $errno = Errno::EIO();
    } else {
        $errno = unpack('i', $raw);
    }

    if ($errno == 0) {
        $self->_finish_success($attempt);
        return;
    }
    $self->{last_errno} = $errno;
    $self->{last_operation} = 'connect';
    $self->_close_attempt($attempt);
    $self->_attempt_next;
    return;
}

sub _ensure_timer ($self) {
    return $self->{timer_fd} if defined $self->{timer_fd};
    my $fd = __PACKAGE__->_timerfd_new;
    my $watcher = $self->{loop}->watch(
        fd   => $fd,
        data => $self,
        read => \&_timer_ready,
        _callback_data_arg => 1,
    );
    $self->{timer_fd} = $fd;
    $self->{timer_watcher} = $watcher;
    return $fd;
}

sub _arm_timeout ($self) {
    my $fd = $self->_ensure_timer;
    $self->{timer_role} = 'timeout';
    __PACKAGE__->_timerfd_arm($fd, $self->{timeout});
    return;
}

sub _queue_success ($self, $attempt) {
    return if ($self->{state} ne 'pending' && $self->{state} ne 'detached')
        || $self->{pending_result};
    $self->{pending_result} = [ success => $attempt ];
    return if !$self->{loop};
    my $fd = $self->_ensure_timer;
    $self->{timer_role} = 'dispatch';
    __PACKAGE__->_timerfd_arm($fd, 0.000000001);
    return;
}

sub _queue_error ($self, $error) {
    return if ($self->{state} ne 'pending' && $self->{state} ne 'detached')
        || $self->{pending_result};
    $self->{pending_result} = [ error => $error ];
    return if !$self->{loop};
    my $fd = $self->_ensure_timer;
    $self->{timer_role} = 'dispatch';
    __PACKAGE__->_timerfd_arm($fd, 0.000000001);
    return;
}

sub _timer_ready ($self) {
    return if $self->{state} ne 'pending';
    __PACKAGE__->_timerfd_consume($self->{timer_fd});
    if (my $result = delete $self->{pending_result}) {
        my ($kind, $value) = @$result;
        if ($kind eq 'success') {
            $self->_finish_success($value);
        } else {
            $self->_finish_error($value);
        }
        return;
    }

    return if ($self->{timer_role} // '') ne 'timeout';
    $self->_finish_error($self->_error(
        type      => 'timeout',
        operation => 'connect',
        errno     => Errno::ETIMEDOUT(),
        message   => 'connection deadline expired',
    ));
    return;
}

sub _close_attempt ($self, $attempt, $keep_fh = 0) {
    return if !$attempt;
    delete $self->{attempts}{ $attempt->{id} };
    if (my $watcher = delete $attempt->{watcher}) {
        $watcher->cancel;
    }
    my $fh = delete $attempt->{fh};
    close $fh if $fh && !$keep_fh;
    $attempt->{request} = undef;
    return $fh;
}

sub _close_attempts ($self, $except = undef) {
    for my $attempt (values %{ $self->{attempts} }) {
        next if $except && refaddr($attempt) == refaddr($except);
        $self->_close_attempt($attempt);
    }
    return;
}

sub _close_timer ($self) {
    if (my $watcher = delete $self->{timer_watcher}) {
        $watcher->cancel;
    }
    if (defined(my $fd = delete $self->{timer_fd})) {
        __PACKAGE__->_timerfd_close($fd);
    }
    $self->{timer_role} = undef;
    return;
}

sub _finish_success ($self, $attempt) {
    return if $self->{state} ne 'pending';
    return if !exists $self->{attempts}{ $attempt->{id} };

    $self->{state} = 'connected';
    $self->_close_attempts($attempt);
    $self->_close_timer;

    my $watcher = delete $attempt->{watcher};
    my $fh = delete $attempt->{fh};
    delete $self->{attempts}{ $attempt->{id} };
    $attempt->{request} = undef;

    my $stream = $self->{stream};
    my $ok = eval { $stream->_connect_succeeded($fh); 1 };
    my $callback_error = $@;

    # If the callback registered Stream or another watcher for this fd, the
    # old handle is already inactive and cancel() is harmless. Otherwise this
    # removes connection's now-unused writable registration.
    $watcher->cancel if $watcher;
    die $callback_error if !$ok;
    return;
}

sub _finish_error ($self, $error) {
    return if $self->{state} ne 'pending';
    $self->{state} = 'failed';
    $self->{error} = $error;
    $self->{pending_result} = undef;
    $self->_close_attempts;
    $self->_close_timer;
    $self->{stream}->_connect_failed($error);
    return;
}

1;
