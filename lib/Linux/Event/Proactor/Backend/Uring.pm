package Linux::Event::Proactor::Backend::Uring;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use POSIX qw(strerror);

use Linux::Event::Error ();

use constant DEFAULT_SUBMIT_BATCH_SIZE => 0;

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

    my $self = bless {
        loop             => $loop,
        ring             => $ring,
        pending_reads    => {},
        pending_writes   => {},
        pending_recvs    => {},
        pending_sends    => {},
        pending_accepts   => {},
        pending_connects  => {},
        pending_shutdowns => {},
        pending_closes    => {},
        pending_timers    => {},
        pending_submit_count => 0,
        submit_batch_size    => $submit_batch_size,
    }, $class;

    return $self;
}

sub _loop ($self) { return $self->{loop} }
sub _ring ($self) { return $self->{ring} }

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
    my $buf   = "\0" x $len;
    my $token;

    $token = $self->_ring->recv(
        $arg{fh},
        $buf,
        $flags,
        0,
        0,
        sub ($res, $cqe_flags) {
            $self->_complete_recv($token, $res, $cqe_flags);
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
    my $token;

    $token = $self->_ring->accept(
        $arg{fh},
        0,
        0,
        sub ($res, $flags) {
            $self->_complete_accept($token, $res, $flags);
        },
    );

    $self->{pending_accepts}{$token} = {
        op => $op,
        fh => $arg{fh},
    };

    $self->_record_submission;
    return $token;
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

sub _complete_recv ($self, $token, $res, $flags) {
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

sub _complete_accept ($self, $token, $res, $flags) {
    my ($rec, $op) = $self->_take_pending_and_unregister('pending_accepts', $token) or return;

    my $code = $self->_result_error_code($res);
    return $self->_settle_terminal_error($op, $code) if defined $code;

    my $fh   = $self->_fh_from_fd($res);
    my $addr = defined $fh ? getpeername($fh) : undef;
    $op->_settle_success({ fh => $fh, addr => $addr });
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

1;

__END__

=pod

=head1 NAME

Linux::Event::Proactor::Backend::Uring - io_uring backend for Linux::Event::Proactor

=head1 SYNOPSIS

  my $loop = Linux::Event::Proactor->new(
    backend => 'uring',
    queue_size => 256,
    submit_batch_size => 64,
  );

=head1 DESCRIPTION

This backend binds L<Linux::Event::Proactor> to L<IO::Uring>. It maps the
current proactor operation set onto real io_uring submissions and normalizes
completion results into the result shapes expected by the loop.

The backend is intentionally small. It owns the ring, keeps submission-time
buffers alive until completion, converts negative CQE results into
L<Linux::Event::Error> objects, and unregisters operations from the loop when
they settle.

=head1 CONSTRUCTOR ARGUMENTS

These arguments are passed through from C<< Linux::Event::Proactor->new(...) >>
when C<backend =E<gt> 'uring'> is selected.

=head2 queue_size

Submission queue size. This is owned by the loop object and passed to
L<IO::Uring>.

=head2 cqe_entries

Optional completion queue size override passed to L<IO::Uring>.

=head2 sqpoll

Optional SQPOLL idle time in milliseconds. When supported by the system, this
can reduce submission syscall overhead by letting a kernel thread poll the
submission queue.

=head2 submit_batch_size

Optional batching threshold for proactive C<submit> calls. When set to a
positive integer, the backend flushes submissions after that many queued
operations, or sooner when the submission queue is almost full. This reduces
submission-side overhead in callback-heavy or bursty workloads while preserving
existing semantics. The default of C<0> disables proactive flushing and leaves
submission to C<run_once>.

=head1 IMPLEMENTED OPERATIONS

This backend currently implements:

  read
  write
  recv
  send
  accept
  connect
  shutdown
  close
  timeout
  cancel

=head1 RESULT NORMALIZATION

=over 4

=item * Negative CQE results are treated as errno values and converted into
L<Linux::Event::Error> objects.

=item * C<accept> returns a new filehandle and peer sockaddr when available.

=item * C<read> and C<recv> preserve their submission buffers until completion
and then slice the completed byte count into the returned C<data> field.

=item * C<write> and C<send> treat partial completion as success and return the
completed byte count.

=item * Timeout completion returns C<< { expired =E<gt> 1 } >>.

=back

=head1 PERFORMANCE NOTES

This backend keeps completion handling compact and avoids repeated callback
queue array shifts in the loop. It also supports optional proactive submission
flushing via C<submit_batch_size> and optional kernel SQ polling via
C<sqpoll>. Those knobs are intentionally backend-specific so the public
proactor API remains small and cohesive.

=head1 SEE ALSO

L<Linux::Event::Proactor>, L<IO::Uring>, L<Linux::Event::Error>

=cut
