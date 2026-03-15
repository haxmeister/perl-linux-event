package Linux::Event::Proactor::Backend::Uring;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use POSIX qw(strerror);
our $VERSION = '0.010';
use Linux::Event::Error ();

use constant DEFAULT_SUBMIT_BATCH_SIZE   => 0;
use constant DEFAULT_PROVIDED_BUF_SIZE   => 4096;
use constant DEFAULT_PROVIDED_BUF_COUNT  => 512;
use constant DEFAULT_PROVIDED_BUF_GROUP  => 0;

sub name ($self) { return 'uring' }

sub _new ($class, %arg) {
    croak 'loop is required' unless $arg{loop};

    eval {
        require IO::Uring;
        1;
    } or croak "failed to load IO::Uring: $@";

    my $loop = $arg{loop};

    my %ring_arg;
    $ring_arg{cqe_entries} = $arg{cqe_entries} if exists $arg{cqe_entries};
    $ring_arg{sqpoll}      = $arg{sqpoll}      if exists $arg{sqpoll};

    my $ring = IO::Uring->new($loop->{queue_size}, %ring_arg);

    my $submit_batch_size = $arg{submit_batch_size} // DEFAULT_SUBMIT_BATCH_SIZE;
    if ($submit_batch_size) {
        croak 'submit_batch_size must be a positive integer'
            if $submit_batch_size !~ /\A\d+\z/ || $submit_batch_size < 1;
    }

    my $provided_buffer_size  = $arg{provided_buffer_size}  // DEFAULT_PROVIDED_BUF_SIZE;
    my $provided_buffer_count = $arg{provided_buffer_count} // DEFAULT_PROVIDED_BUF_COUNT;
    my $provided_buffer_group = $arg{provided_buffer_group} // DEFAULT_PROVIDED_BUF_GROUP;

    croak 'provided_buffer_size must be a positive integer'
        if $provided_buffer_size !~ /\A\d+\z/ || $provided_buffer_size < 1;
    croak 'provided_buffer_count must be a positive integer'
        if $provided_buffer_count !~ /\A\d+\z/ || $provided_buffer_count < 1;
    croak 'provided_buffer_group must be a non-negative integer'
        if $provided_buffer_group !~ /\A\d+\z/;

    croak 'provided_buffer_size must be a power of two'
        if !$class->_is_power_of_two($provided_buffer_size);
    croak 'provided_buffer_count must be a power of two'
        if !$class->_is_power_of_two($provided_buffer_count);

    my $buffer_group = $ring->add_buffer_group(
        $provided_buffer_size,
        $provided_buffer_count,
        $provided_buffer_group,
        0,
    );

    croak 'failed to create provided buffer group'
        unless $buffer_group;

    my $self = bless {
        loop                    => $loop,
        ring                    => $ring,

        provided_buffer_group   => $provided_buffer_group,
        provided_buffer_size    => $provided_buffer_size,
        provided_buffer_count   => $provided_buffer_count,
        provided_buffers        => $buffer_group,

        pending_reads           => {},
        pending_writes          => {},
        pending_splices         => {},
        pending_recvs           => {},   # single-shot fallback recv bucket
        pending_recv_waiters    => {},   # public recv ops for multishot fast path
        recv_sources            => {},   # persistent multishot recv state keyed by fd
        pending_sends           => {},
        pending_accept_waiters  => {},
        accept_sources          => {},
        pending_connects        => {},
        pending_shutdowns       => {},
        pending_closes          => {},
        pending_timers          => {},
        pending_submit_count    => 0,
        submit_batch_size       => $submit_batch_size,
    }, $class;

    return $self;
}

sub _loop ($self) { return $self->{loop} }
sub _ring ($self) { return $self->{ring} }

sub _is_power_of_two ($class, $n) {
    return 0 if !defined $n || $n < 1;
    return ($n & ($n - 1)) == 0 ? 1 : 0;
}

sub _submit_read ($self, $op, %arg) {
    my $len = $arg{len};
    my $buf = "\0" x $len;
    my $token;

    $token = $self->_ring->read(
        $arg{fh},
        $buf,
        -1,
        0,
        sub ($res, $flags) {
            $self->_complete_read($token, $res, $flags);
        },
    );

    $self->{pending_reads}{$token} = {
        op     => $op,
        fh     => $arg{fh},
        len    => $len,
        buffer => \$buf,
    };

    $self->_record_submission;
    return $token;
}

sub _submit_write ($self, $op, %arg) {
    my $buf = $arg{buf};
    my $token;

    $token = $self->_ring->write(
        $arg{fh},
        $buf,
        -1,
        0,
        sub ($res, $flags) {
            $self->_complete_write($token, $res, $flags);
        },
    );

    $self->{pending_writes}{$token} = {
        op   => $op,
        fh   => $arg{fh},
        buf  => $buf,
        size => length($buf),
    };

    $self->_record_submission;
    return $token;
}

sub _submit_recv ($self, $op, %arg) {
    my $len   = $arg{len};
    my $flags = $arg{flags} // 0;

    if ($self->_recv_uses_provided_buffers(len => $len, flags => $flags)) {
        return $self->_submit_recv_multishot($op, %arg);
    }

    return $self->_submit_recv_single($op, %arg);
}

sub _submit_recv_single ($self, $op, %arg) {
    my $len   = $arg{len};
    my $flags = $arg{flags} // 0;
    my $buf   = "\0" x $len;
    my $token;

    $token = $self->_ring->recv(
        $arg{fh},
        $buf,
        $flags,
        0,
        0,
        sub ($res, $cqe_flags) {
            $self->_complete_recv_single($token, $res, $cqe_flags);
        },
    );

    $self->{pending_recvs}{$token} = {
        op     => $op,
        fh     => $arg{fh},
        len    => $len,
        flags  => $flags,
        buffer => \$buf,
    };

    $self->_record_submission;
    return $token;
}

sub _submit_recv_multishot ($self, $op, %arg) {
    my $public_token = $self->_next_public_token;
    my $src          = $self->_get_or_create_recv_source($arg{fh});

    $self->{pending_recv_waiters}{$public_token} = {
        op    => $op,
        fh    => $arg{fh},
        src   => $src,
        len   => $arg{len},
        flags => ($arg{flags} // 0),
    };

    push @{ $src->{waiters} }, $public_token;

    $self->_dispatch_ready_recvs($src);

    if (@{ $src->{waiters} } && !$src->{armed} && !$src->{closing}) {
        $self->_arm_multishot_recv($src);
    }

    return $public_token;
}

sub _submit_send ($self, $op, %arg) {
    my $buf   = $arg{buf};
    my $flags = $arg{flags} // 0;
    my $token;

    $token = $self->_ring->send(
        $arg{fh},
        $buf,
        $flags,
        0,
        0,
        sub ($res, $cqe_flags) {
            $self->_complete_send($token, $res, $cqe_flags);
        },
    );

    $self->{pending_sends}{$token} = {
        op    => $op,
        fh    => $arg{fh},
        buf   => $buf,
        size  => length($buf),
        flags => $flags,
    };

    $self->_record_submission;
    return $token;
}

sub _submit_accept ($self, $op, %arg) {
    my $public_token = $self->_next_public_token;
    my $src          = $self->_get_or_create_accept_source($arg{fh});

    $self->{pending_accept_waiters}{$public_token} = {
        op  => $op,
        fh  => $arg{fh},
        src => $src,
    };

    push @{ $src->{waiters} }, $public_token;

    $self->_dispatch_ready_accepts($src);

    if (@{ $src->{waiters} } && !$src->{armed} && !$src->{closing}) {
        $self->_arm_multishot_accept($src);
    }

    return $public_token;
}

sub _submit_connect ($self, $op, %arg) {
    my $token;

    $token = $self->_ring->connect(
        $arg{fh},
        $arg{addr},
        0,
        sub ($res, $flags) {
            $self->_complete_connect($token, $res, $flags);
        },
    );

    $self->{pending_connects}{$token} = {
        op   => $op,
        fh   => $arg{fh},
        addr => $arg{addr},
    };

    $self->_record_submission;
    return $token;
}

sub _submit_shutdown ($self, $op, %arg) {
    my $token;

    $token = $self->_ring->shutdown(
        $arg{fh},
        $arg{how},
        0,
        sub ($res, $flags) {
            $self->_complete_shutdown($token, $res, $flags);
        },
    );

    $self->{pending_shutdowns}{$token} = {
        op  => $op,
        fh  => $arg{fh},
        how => $arg{how},
    };

    $self->_record_submission;
    return $token;
}

sub _submit_close ($self, $op, %arg) {
    my $token;

    $token = $self->_ring->close(
        $arg{fh},
        0,
        sub ($res, $flags) {
            $self->_complete_close($token, $res, $flags);
        },
    );

    $self->{pending_closes}{$token} = {
        op => $op,
        fh => $arg{fh},
    };

    $self->_record_submission;
    return $token;
}

sub _submit_timeout ($self, $op, %arg) {
    croak 'deadline_ns is required' unless exists $arg{deadline_ns};

    eval {
        require Time::Spec;
        1;
    } or croak "failed to load Time::Spec: $@";

    my $delay_ns = $self->_loop->_remaining_ns_until($arg{deadline_ns});
    my $delay_s  = $delay_ns / 1_000_000_000;
    my $spec     = Time::Spec->new($delay_s);
    my $token;

    $token = $self->_ring->timeout(
        $spec,
        0,
        0,
        0,
        sub ($res, $flags) {
            $self->_complete_timeout($token, $res, $flags);
        },
    );

    $self->{pending_timers}{$token} = {
        op          => $op,
        deadline_ns => $arg{deadline_ns},
    };

    return $token;
}

sub _submit_splice ($self, $op, %arg) {
    my $flags = $arg{flags} // 0;
    my $token;

    $token = $self->_ring->splice(
        $arg{in_fh},
        -1,
        $arg{out_fh},
        -1,
        $arg{len},
        $flags,
        0,
        sub ($res, $cqe_flags) {
            $self->_complete_splice($token, $res, $cqe_flags);
        },
    );

    $self->{pending_splices}{$token} = {
        op     => $op,
        in_fh  => $arg{in_fh},
        out_fh => $arg{out_fh},
        len    => $arg{len},
        flags  => $flags,
    };

    $self->_record_submission;
    return $token;
}

sub _record_submission ($self) {
    return if !$self->{submit_batch_size};

    my $count = ++$self->{pending_submit_count};
    my $space = $self->_ring->sq_space_left;

    if ($space <= 1 || $count >= $self->{submit_batch_size}) {
        $self->_flush_submissions;
    }

    return;
}

sub _flush_submissions ($self) {
    return 0 unless $self->{pending_submit_count};

    my $submitted = $self->_ring->submit;
    croak "io_uring submit failed: $!" unless defined $submitted;

    $self->{pending_submit_count} = 0;
    return $submitted;
}

sub _cancel_op ($self, $op) {
    return 0 if $op->is_terminal;

    if ($op->kind eq 'accept') {
        return $self->_cancel_accept_waiter($op);
    }

    if ($op->kind eq 'recv') {
        my $token = $op->_backend_token;
        if (defined $token && exists $self->{pending_recv_waiters}{$token}) {
            return $self->_cancel_recv_waiter($op);
        }
    }

    my $token = $op->_backend_token;
    return 0 unless defined $token;

    my $cancel_id = $self->_ring->cancel(
        $token,
        0,
        0,
        sub ($res, $flags) {
            return;
        },
    );

    return defined $cancel_id ? 1 : 0;
}

sub _complete_backend_events ($self) {
    return 0 if !$self->_loop->{live_op_count} && !@{ $self->_loop->{callback_queue} };

    $self->_flush_submissions;

    my $count = $self->_ring->run_once(1);
    return defined($count) ? $count : 0;
}

sub _take_pending_and_unregister ($self, $bucket, $token) {
    my $rec = delete $self->{$bucket}{$token} or return;
    my $op  = $self->_loop->_unregister_op($token) or return;
    return ($rec, $op);
}

sub _complete_read ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_reads', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    my $chunk = substr(${ $rec->{buffer} }, 0, $res);
    $op->_settle_success({ bytes => $res, data => $chunk, eof => ($res == 0 ? 1 : 0) });
    return;
}

sub _complete_write ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_writes', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    $op->_settle_success({ bytes => $res });
    return;
}

sub _complete_recv_single ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_recvs', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    my $chunk = substr(${ $rec->{buffer} }, 0, $res);
    $op->_settle_success({ bytes => $res, data => $chunk, eof => ($res == 0 ? 1 : 0) });
    return;
}

sub _complete_send ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_sends', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    $op->_settle_success({ bytes => $res });
    return;
}

sub _complete_connect ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_connects', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    $op->_settle_success({});
    return;
}

sub _complete_shutdown ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_shutdowns', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    $op->_settle_success({});
    return;
}

sub _complete_timeout ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_timers', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    $op->_settle_success({ expired => 1 });
    return;
}

sub _complete_close ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_closes', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    $op->_settle_success({});
    return;
}

sub _complete_splice ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_splices', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    $op->_settle_success({ bytes => $res });
    return;
}

sub _next_public_token ($self) {
    return $self->_loop->{next_op_id}++;
}

sub _recv_uses_provided_buffers ($self, %arg) {
    return 0 if !$self->{provided_buffers};
    return 0 if !defined $arg{len};
    return 0 if $arg{len} != $self->{provided_buffer_size};
    return 0 if ($arg{flags} // 0) != 0;
    return 1;
}

sub _recv_source_key ($self, $fh) {
    my $fd = fileno($fh);
    croak 'recv fh has no fileno' unless defined $fd;
    return $fd;
}

sub _get_or_create_recv_source ($self, $fh) {
    my $key = $self->_recv_source_key($fh);
    return $self->{recv_sources}{$key} if $self->{recv_sources}{$key};

    my $src = {
        fh            => $fh,
        fd            => $key,
        ring_token    => undef,
        armed         => 0,
        closing       => 0,
        waiters       => [],
        ready_results => [],
        recv_flags    => 0,
        poll_flags    => 0,
    };

    $self->{recv_sources}{$key} = $src;
    return $src;
}

sub _arm_multishot_recv ($self, $src) {
    return if !$src;
    return if $src->{closing};
    return if $src->{armed};

    my $token;

    $token = $self->_ring->recv_multishot(
        $src->{fh},
        $src->{recv_flags},
        $src->{poll_flags},
        $self->{provided_buffer_group},
        0,
        sub ($res, $flags) {
            $self->_complete_recv_multishot($src, $res, $flags);
        },
    );

    croak 'failed to arm multishot recv' unless defined $token;

    $src->{ring_token} = $token;
    $src->{armed}      = 1;

    $self->_record_submission;

    return $token;
}

sub _disarm_multishot_recv ($self, $src) {
    return 0 if !$src;
    return 0 if !$src->{armed};
    return 0 if !defined $src->{ring_token};

    my $token = delete $src->{ring_token};
    $src->{armed} = 0;

    my $cancel_id = $self->_ring->cancel(
        $token,
        0,
        0,
        sub ($res, $flags) {
            return;
        },
    );

    return defined $cancel_id ? 1 : 0;
}

sub _complete_recv_multishot ($self, $src, $res, $flags) {
    return if !$src;
    return if $src->{closing};

    my $code = $self->_result_error_code($res);

    if (defined $code) {
        $self->_queue_recv_source_error($src, $code);
    }
    else {
        my $chunk = '';
        if ($self->_cqe_has_buffer($flags)) {
            my $index = $self->_cqe_buffer_id($flags);
            my $buf   = $self->{provided_buffers}->consume($index, $res);
            $chunk = defined $buf ? $buf : '';
        }

        push @{ $src->{ready_results} }, {
            ok    => 1,
            bytes => $res,
            data  => $chunk,
            eof   => ($res == 0 ? 1 : 0),
        };
    }

    $self->_dispatch_ready_recvs($src);

    if (!$self->_cqe_has_more($flags)) {
        $src->{armed}      = 0;
        $src->{ring_token} = undef;

        if (@{ $src->{waiters} } && !$src->{closing}) {
            $self->_arm_multishot_recv($src);
        }
    }

    return;
}

sub _dispatch_ready_recvs ($self, $src) {
    return if !$src;

    while (@{ $src->{waiters} } && @{ $src->{ready_results} }) {
        my $token  = shift @{ $src->{waiters} };
        my $result = shift @{ $src->{ready_results} };

        next if !defined $token;

        if ($result->{ok}) {
            $self->_settle_recv_waiter_success($token, {
                bytes => $result->{bytes},
                data  => $result->{data},
                eof   => $result->{eof},
            });
        }
        else {
            $self->_settle_recv_waiter_error($token, $result->{code});
        }
    }

    if (!@{ $src->{waiters} } && $src->{armed}) {
        $self->_disarm_multishot_recv($src);
    }

    return;
}

sub _queue_recv_source_error ($self, $src, $code) {
    push @{ $src->{ready_results} }, {
        ok   => 0,
        code => $code,
    };
    return;
}

sub _settle_recv_waiter_success ($self, $token, $result) {
    my $rec = delete $self->{pending_recv_waiters}{$token} or return;
    my $op  = $self->_loop->_unregister_op($token) or return;

    $op->_settle_success($result);
    return;
}

sub _settle_recv_waiter_error ($self, $token, $code) {
    my $rec = delete $self->{pending_recv_waiters}{$token} or return;
    my $op  = $self->_loop->_unregister_op($token) or return;

    $self->_settle_terminal_error($op, $code);
    return;
}

sub _cancel_recv_waiter ($self, $op) {
    my $token = $op->_backend_token;
    return 0 unless defined $token;

    my $rec = delete $self->{pending_recv_waiters}{$token} or return 0;
    my $src = $rec->{src};

    if ($src && $src->{waiters}) {
        my @keep;
        for my $queued_token (@{ $src->{waiters} }) {
            push @keep, $queued_token if $queued_token != $token;
        }
        $src->{waiters} = \@keep;

        if (!@{ $src->{waiters} } && $src->{armed}) {
            $self->_disarm_multishot_recv($src);
        }
    }

    my $live_op = $self->_loop->_unregister_op($token) or return 0;
    $live_op->_settle_cancelled;

    return 1;
}

sub _accept_source_key ($self, $fh) {
    my $fd = fileno($fh);
    croak 'accept fh has no fileno' unless defined $fd;
    return $fd;
}

sub _get_or_create_accept_source ($self, $fh) {
    my $key = $self->_accept_source_key($fh);
    return $self->{accept_sources}{$key} if $self->{accept_sources}{$key};

    my $src = {
        fh            => $fh,
        fd            => $key,
        ring_token    => undef,
        armed         => 0,
        closing       => 0,
        waiters       => [],
        ready_results => [],
    };

    $self->{accept_sources}{$key} = $src;
    return $src;
}

sub _arm_multishot_accept ($self, $src) {
    return if !$src;
    return if $src->{closing};
    return if $src->{armed};

    my $token;

    $token = $self->_ring->accept_multishot(
        $src->{fh},
        0,
        sub ($res, $flags) {
            $self->_complete_accept_multishot($src, $res, $flags);
        },
    );

    croak 'failed to arm multishot accept' unless defined $token;

    $src->{ring_token} = $token;
    $src->{armed}      = 1;

    $self->_record_submission;

    return $token;
}

sub _disarm_multishot_accept ($self, $src) {
    return 0 if !$src;
    return 0 if !$src->{armed};
    return 0 if !defined $src->{ring_token};

    my $token = delete $src->{ring_token};
    $src->{armed} = 0;

    my $cancel_id = $self->_ring->cancel(
        $token,
        0,
        0,
        sub ($res, $flags) {
            return;
        },
    );

    return defined $cancel_id ? 1 : 0;
}

sub _complete_accept_multishot ($self, $src, $res, $flags) {
    return if !$src;
    return if $src->{closing};

    my $code = $self->_result_error_code($res);

    if (defined $code) {
        $self->_queue_accept_source_error($src, $code);
    }
    else {
        my $fh   = $self->_fh_from_fd($res);
        my $addr = defined $fh ? getpeername($fh) : undef;

        push @{ $src->{ready_results} }, {
            ok   => 1,
            fh   => $fh,
            addr => $addr,
        };
    }

    $self->_dispatch_ready_accepts($src);

    if (!$self->_cqe_has_more($flags)) {
        $src->{armed}      = 0;
        $src->{ring_token} = undef;

        if (@{ $src->{waiters} } && !$src->{closing}) {
            $self->_arm_multishot_accept($src);
        }
    }

    return;
}

sub _dispatch_ready_accepts ($self, $src) {
    return if !$src;

    while (@{ $src->{waiters} } && @{ $src->{ready_results} }) {
        my $token  = shift @{ $src->{waiters} };
        my $result = shift @{ $src->{ready_results} };

        next if !defined $token;

        if ($result->{ok}) {
            $self->_settle_accept_waiter_success($token, {
                fh   => $result->{fh},
                addr => $result->{addr},
            });
        }
        else {
            $self->_settle_accept_waiter_error($token, $result->{code});
        }
    }

    if (!@{ $src->{waiters} } && $src->{armed}) {
        $self->_disarm_multishot_accept($src);
    }

    return;
}

sub _queue_accept_source_error ($self, $src, $code) {
    push @{ $src->{ready_results} }, {
        ok   => 0,
        code => $code,
    };
    return;
}

sub _settle_accept_waiter_success ($self, $token, $result) {
    my $rec = delete $self->{pending_accept_waiters}{$token} or return;
    my $op  = $self->_loop->_unregister_op($token) or return;

    $op->_settle_success($result);
    return;
}

sub _settle_accept_waiter_error ($self, $token, $code) {
    my $rec = delete $self->{pending_accept_waiters}{$token} or return;
    my $op  = $self->_loop->_unregister_op($token) or return;

    $self->_settle_terminal_error($op, $code);
    return;
}

sub _cancel_accept_waiter ($self, $op) {
    my $token = $op->_backend_token;
    return 0 unless defined $token;

    my $rec = delete $self->{pending_accept_waiters}{$token} or return 0;
    my $src = $rec->{src};

    if ($src && $src->{waiters}) {
        my @keep;
        for my $queued_token (@{ $src->{waiters} }) {
            push @keep, $queued_token if $queued_token != $token;
        }
        $src->{waiters} = \@keep;

        if (!@{ $src->{waiters} } && $src->{armed}) {
            $self->_disarm_multishot_accept($src);
        }
    }

    my $live_op = $self->_loop->_unregister_op($token) or return 0;
    $live_op->_settle_cancelled;

    return 1;
}

sub _cqe_has_more ($self, $flags) {
    return 0 if !defined $flags;
    return ($flags & 2) ? 1 : 0;   # IORING_CQE_F_MORE
}

sub _cqe_has_buffer ($self, $flags) {
    return 0 if !defined $flags;
    return ($flags & 1) ? 1 : 0;   # IORING_CQE_F_BUFFER
}

sub _cqe_buffer_id ($self, $flags) {
    return ($flags >> 16) & 0xffff;
}

sub _result_error_code ($self, $res) {
    return undef if $res >= 0;
    return -$res;
}

sub _settle_terminal_error ($self, $op, $code) {
    if ($code == 125) {
        $op->_settle_cancelled;
        return;
    }

    $op->_settle_error($self->_error_from_errno($code));
    return;
}

sub _fh_from_fd ($self, $fd) {
    my $fh;
    open($fh, '+<&=', $fd) or return undef;
    return $fh;
}

sub _error_from_errno ($self, $code) {
    my %names = (
        32  => 'EPIPE',
        62  => 'ETIME',
        104 => 'ECONNRESET',
        110 => 'ETIMEDOUT',
        111 => 'ECONNREFUSED',
        125 => 'ECANCELED',
    );

    return Linux::Event::Error->new(
        code    => $code,
        name    => ($names{$code} // 'EUNKNOWN'),
        message => (strerror($code) // ''),
    );
}

sub DESTROY ($self) {
    if (my $group = delete $self->{provided_buffers}) {
        eval { $group->release; 1 };
    }

    return;
}

1;

__END__

=head1 NAME

Linux::Event::Proactor::Backend::Uring - io_uring backend for Linux::Event::Proactor

=head1 SYNOPSIS

  # Usually constructed internally by Linux::Event::Proactor.
  my $loop = Linux::Event::Loop->new(
    model   => 'proactor',
    backend => 'uring',
  );

=head1 DESCRIPTION

C<Linux::Event::Proactor::Backend::Uring> is the completion backend for
L<Linux::Event::Proactor>. It submits reads, writes, socket operations, timers,
and cancellation requests through L<IO::Uring>.

The backend preserves the core proactor invariants by leaving user callback
execution to the engine. It records pending operations, normalizes completion
results, and settles user-visible operations through the owning loop.

Multishot accept is used internally to service ordinary one-shot public
C<accept()> requests.

When configured provided-buffer fast-path conditions are met, ordinary one-shot
public C<recv()> requests may also be serviced internally by a shared
multishot receive source while still preserving single-settlement public
operation semantics.

=head1 CONSTRUCTOR OPTIONS

The backend is normally constructed internally. Recognized options include:

=over 4

=item * C<submit_batch_size>

Optional submission batching threshold. When non-zero, the backend flushes the
ring after this many queued submissions.

=item * C<cqe_entries>

Optional C<IO::Uring> completion queue size tuning.

=item * C<sqpoll>

Optional C<IO::Uring> SQPOLL mode toggle.

=item * C<provided_buffer_size>

Optional global provided-buffer size for the internal multishot recv fast path.
Defaults to 4096.

=item * C<provided_buffer_count>

Optional global provided-buffer count for the internal multishot recv fast
path. Defaults to 512.

=item * C<provided_buffer_group>

Optional global provided-buffer group id. Defaults to 0.

=back

=head1 SUPPORTED OPERATIONS

This backend currently implements:

=over 4

=item * C<read>

=item * C<write>

=item * C<splice>

=item * C<recv>

=item * C<send>

=item * C<accept>

=item * C<connect>

=item * C<shutdown>

=item * C<close>

=item * C<after> / C<at> via internal timeout submission

=item * cancellation of submitted operations

=back

=head1 NOTES

The backend is intentionally low-level and is not expected to be used
directly by most applications.

=head1 SEE ALSO

L<Linux::Event>,
L<Linux::Event::Proactor>,
L<Linux::Event::Operation>,
L<IO::Uring>

=cut
