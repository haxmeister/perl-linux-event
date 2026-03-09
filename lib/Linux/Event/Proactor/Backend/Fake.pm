package Linux::Event::Proactor::Backend::Fake;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Linux::Event::Error ();

sub name ($self) { return 'fake' }

sub _new ($class, %arg) {
    croak 'loop is required' unless $arg{loop};

    my $self = bless {
        loop             => $arg{loop},
        timers           => {},
        pending_reads    => {},
        pending_writes   => {},
        pending_recvs    => {},
        pending_sends    => {},
        pending_accepts   => {},
        pending_connects  => {},
        pending_shutdowns => {},
        pending_closes    => {},
    }, $class;

    return $self;
}

sub _loop ($self) { return $self->{loop} }
sub _next_token ($self) { return $self->_loop->{next_op_id}++ }

sub _submit_read ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_reads}{$token} = {
        op  => $op,
        fh  => $arg{fh},
        len => $arg{len},
    };
    return $token;
}

sub _submit_write ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_writes}{$token} = {
        op   => $op,
        fh   => $arg{fh},
        buf  => $arg{buf},
        size => length($arg{buf}),
    };
    return $token;
}

sub _submit_recv ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_recvs}{$token} = {
        op    => $op,
        fh    => $arg{fh},
        len   => $arg{len},
        flags => ($arg{flags} // 0),
    };
    return $token;
}

sub _submit_send ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_sends}{$token} = {
        op    => $op,
        fh    => $arg{fh},
        buf   => $arg{buf},
        size  => length($arg{buf}),
        flags => ($arg{flags} // 0),
    };
    return $token;
}

sub _submit_accept ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_accepts}{$token} = { op => $op, fh => $arg{fh} };
    return $token;
}

sub _submit_connect ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_connects}{$token} = {
        op   => $op,
        fh   => $arg{fh},
        addr => $arg{addr},
    };
    return $token;
}

sub _submit_shutdown ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_shutdowns}{$token} = {
        op  => $op,
        fh  => $arg{fh},
        how => $arg{how},
    };
    return $token;
}

sub _submit_close ($self, $op, %arg) {
    my $token = $self->_next_token;
    $self->{pending_closes}{$token} = {
        op => $op,
        fh => $arg{fh},
    };
    return $token;
}

sub _submit_timeout ($self, $op, %arg) {
    croak 'deadline_ns is required' unless exists $arg{deadline_ns};
    my $token = $self->_next_token;
    $self->{timers}{$token} = {
        op          => $op,
        deadline_ns => $arg{deadline_ns},
    };
    return $token;
}

sub _cancel_op ($self, $op) {
    return 0 if $op->is_terminal;

    my $token = $op->_backend_token;
    return 0 unless defined $token;

    if    ($op->kind eq 'timeout') { delete $self->{timers}{$token} }
    elsif ($op->kind eq 'read')    { delete $self->{pending_reads}{$token} }
    elsif ($op->kind eq 'write')   { delete $self->{pending_writes}{$token} }
    elsif ($op->kind eq 'recv')    { delete $self->{pending_recvs}{$token} }
    elsif ($op->kind eq 'send')    { delete $self->{pending_sends}{$token} }
    elsif ($op->kind eq 'accept')   { delete $self->{pending_accepts}{$token} }
    elsif ($op->kind eq 'connect')  { delete $self->{pending_connects}{$token} }
    elsif ($op->kind eq 'shutdown') { delete $self->{pending_shutdowns}{$token} }
    elsif ($op->kind eq 'close')    { delete $self->{pending_closes}{$token} }

    my $active = $self->_loop->_unregister_op($token);
    return 0 unless $active;

    $op->_settle_cancelled;
    return 1;
}

sub _complete_backend_events ($self) {
    my $count  = 0;
    my $now_ns = $self->_loop->_now_ns;

    for my $token (keys %{ $self->{timers} }) {
        my $rec = $self->{timers}{$token};
        next if $rec->{deadline_ns} > $now_ns;

        delete $self->{timers}{$token};

        my $op = $self->_loop->_unregister_op($token);
        next unless $op;

        $op->_settle_success({ expired => 1 });
        $count++;
    }

    return $count;
}

sub _fake_complete_read_success ($self, $token, $chunk) {
    croak 'token is required' unless defined $token;
    croak 'chunk must be defined' unless defined $chunk;

    my $rec = delete $self->{pending_reads}{$token}
        or croak "no pending read for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    croak "fake read chunk exceeds requested len for token $token"
        if length($chunk) > $rec->{len};

    $op->_settle_success({
        bytes => length($chunk),
        data  => $chunk,
        eof   => (length($chunk) == 0 ? 1 : 0),
    });

    return $op;
}

sub _fake_complete_read_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_reads}{$token}
        or croak "no pending read for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_complete_write_success ($self, $token, $bytes) {
    croak 'token is required' unless defined $token;
    croak 'bytes is required' unless defined $bytes;
    croak 'bytes must be non-negative' if $bytes < 0;

    my $rec = delete $self->{pending_writes}{$token}
        or croak "no pending write for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    croak "fake write bytes exceeds submitted buffer size for token $token"
        if $bytes > $rec->{size};

    $op->_settle_success({ bytes => $bytes });
    return $op;
}

sub _fake_complete_write_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_writes}{$token}
        or croak "no pending write for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_complete_recv_success ($self, $token, $chunk) {
    croak 'token is required' unless defined $token;
    croak 'chunk must be defined' unless defined $chunk;

    my $rec = delete $self->{pending_recvs}{$token}
        or croak "no pending recv for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    croak "fake recv chunk exceeds requested len for token $token"
        if length($chunk) > $rec->{len};

    $op->_settle_success({
        bytes => length($chunk),
        data  => $chunk,
        eof   => (length($chunk) == 0 ? 1 : 0),
    });

    return $op;
}

sub _fake_complete_recv_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_recvs}{$token}
        or croak "no pending recv for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_complete_send_success ($self, $token, $bytes) {
    croak 'token is required' unless defined $token;
    croak 'bytes is required' unless defined $bytes;
    croak 'bytes must be non-negative' if $bytes < 0;

    my $rec = delete $self->{pending_sends}{$token}
        or croak "no pending send for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    croak "fake send bytes exceeds submitted buffer size for token $token"
        if $bytes > $rec->{size};

    $op->_settle_success({ bytes => $bytes });
    return $op;
}

sub _fake_complete_send_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_sends}{$token}
        or croak "no pending send for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_complete_accept_success ($self, $token, $fh, $addr = undef) {
    croak 'token is required' unless defined $token;
    croak 'fh is required' unless defined $fh;

    delete $self->{pending_accepts}{$token}
        or croak "no pending accept for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_success({ fh => $fh, addr => $addr });
    return $op;
}

sub _fake_complete_accept_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_accepts}{$token}
        or croak "no pending accept for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_complete_connect_success ($self, $token) {
    croak 'token is required' unless defined $token;

    delete $self->{pending_connects}{$token}
        or croak "no pending connect for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_success({});
    return $op;
}

sub _fake_complete_connect_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_connects}{$token}
        or croak "no pending connect for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_complete_shutdown_success ($self, $token) {
    croak 'token is required' unless defined $token;

    delete $self->{pending_shutdowns}{$token}
        or croak "no pending shutdown for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_success({});
    return $op;
}

sub _fake_complete_shutdown_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_shutdowns}{$token}
        or croak "no pending shutdown for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_complete_close_success ($self, $token) {
    croak 'token is required' unless defined $token;

    delete $self->{pending_closes}{$token}
        or croak "no pending close for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_success({});
    return $op;
}

sub _fake_complete_close_error ($self, $token, %arg) {
    croak 'token is required' unless defined $token;
    croak 'code is required' unless exists $arg{code};

    delete $self->{pending_closes}{$token}
        or croak "no pending close for token $token";
    my $op = $self->_loop->_unregister_op($token)
        or croak "no registered op for token $token";

    $op->_settle_error(_fake_error(%arg));
    return $op;
}

sub _fake_error (%arg) {
    return Linux::Event::Error->new(
        code    => $arg{code},
        name    => $arg{name},
        message => $arg{message},
    );
}

1;

__END__

=pod

=head1 NAME

Linux::Event::Proactor::Backend::Fake - Deterministic test backend for Linux::Event::Proactor

=head1 SYNOPSIS

  my $loop = Linux::Event::Proactor->new(backend => 'fake');

  my $op = $loop->read(fh => $fh, len => 4);
  $loop->_fake_complete_read_success($op->_backend_token, 'test');
  $loop->drain_callbacks;

=head1 DESCRIPTION

This backend is intended for tests. It never performs real kernel I/O. Instead,
submitted operations are stored in predictable in-memory registries and can be
completed or failed explicitly through helper methods.

The fake backend preserves the same high-level invariants as the uring backend:
operations register once, settle once, callbacks are deferred, and cancellation
remains observable in tests.

=head1 TEST HELPERS

The backend supports completion helpers for all currently implemented operation
kinds. These helpers are normally reached through the delegators on
L<Linux::Event::Proactor>.

Examples include:

  _fake_complete_read_success
  _fake_complete_read_error
  _fake_complete_write_success
  _fake_complete_write_error
  _fake_complete_recv_success
  _fake_complete_recv_error
  _fake_complete_send_success
  _fake_complete_send_error
  _fake_complete_accept_success
  _fake_complete_accept_error
  _fake_complete_connect_success
  _fake_complete_connect_error
  _fake_complete_shutdown_success
  _fake_complete_shutdown_error
  _fake_complete_close_success
  _fake_complete_close_error

=head1 DESIGN NOTES

=over 4

=item * Timers complete when their stored deadline is less than or equal to the
current loop clock reading.

=item * Read and recv helpers validate that the supplied fake payload does not
exceed the originally requested length.

=item * Write and send helpers validate that the supplied fake byte count does
not exceed the submitted buffer size.

=item * Cancellation removes the pending record before settling the operation
as cancelled.

=back

=head1 SEE ALSO

L<Linux::Event::Proactor>, L<Linux::Event::Operation>

=cut
