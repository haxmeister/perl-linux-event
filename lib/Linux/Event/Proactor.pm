package Linux::Event::Proactor;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Socket qw(SHUT_RD SHUT_WR SHUT_RDWR);

use Linux::Event::Clock ();
use Linux::Event::Operation ();
use Linux::Event::Proactor::Backend::Fake ();
use Linux::Event::Proactor::Backend::Uring ();

use constant NS_PER_S => 1_000_000_000;

sub new ($class, %arg) {
    my $backend_name = $arg{backend} // 'fake';
    croak 'backend must be fake or uring'
        unless $backend_name eq 'fake' || $backend_name eq 'uring';

    my $clock = $arg{clock} // Linux::Event::Clock->new(clock => 'monotonic');
    croak 'clock must provide tick()'
        unless $clock->can('tick');
    croak 'clock must provide now_ns()'
        unless $clock->can('now_ns');

    my $self = bless {
        backend_name   => $backend_name,
        backend        => undef,
        clock          => $clock,
        running        => 0,
        stop_requested => 0,
        next_op_id     => 1,
        queue_size     => $arg{queue_size} // 64,

        ops_by_token   => {},
        callback_queue => [],
        callback_head  => 0,
        live_op_count  => 0,
    }, $class;

    if ($backend_name eq 'fake') {
        $self->{backend} = Linux::Event::Proactor::Backend::Fake->_new(
            loop => $self,
            %arg,
        );
    }
    else {
        $self->{backend} = Linux::Event::Proactor::Backend::Uring->_new(
            loop => $self,
            %arg,
        );
    }

    return $self;
}

sub clock ($self) { return $self->{clock} }
sub backend_name ($self) { return $self->{backend_name} }
sub live_op_count ($self) { return $self->{live_op_count} }
sub is_running ($self) { return $self->{running} ? 1 : 0 }
sub drain_callbacks ($self) { return $self->_drain_callback_queue }

sub run ($self) {
    $self->{running}        = 1;
    $self->{stop_requested} = 0;

    while (!$self->{stop_requested}) {
        $self->run_once;
    }

    $self->{running} = 0;
    return;
}

sub run_once ($self) {
    my $n_events = $self->{backend}->_complete_backend_events;
    my $n_cbs    = $self->_drain_callback_queue;
    return $n_events + $n_cbs;
}

sub stop ($self) {
    $self->{stop_requested} = 1;
    return;
}

sub read ($self, %arg) {
    $self->_validate_read_args(%arg);
    return $self->_submit_op('read', %arg);
}

sub write ($self, %arg) {
    $self->_validate_write_args(%arg);
    return $self->_submit_op('write', %arg);
}

sub recv ($self, %arg) {
    $self->_validate_recv_args(%arg);
    return $self->_submit_op('recv', %arg);
}

sub send ($self, %arg) {
    $self->_validate_send_args(%arg);
    return $self->_submit_op('send', %arg);
}

sub accept ($self, %arg) {
    $self->_validate_accept_args(%arg);
    return $self->_submit_op('accept', %arg);
}

sub connect ($self, %arg) {
    $self->_validate_connect_args(%arg);
    return $self->_submit_op('connect', %arg);
}

sub shutdown ($self, %arg) {
    $self->_validate_shutdown_args(%arg);
    $arg{how} = $self->_normalize_shutdown_how($arg{how});
    return $self->_submit_op('shutdown', %arg);
}

sub close ($self, %arg) {
    $self->_validate_close_args(%arg);
    return $self->_submit_op('close', %arg);
}

sub after ($self, $seconds, %arg) {
    $self->_validate_after_args($seconds, %arg);
    my $deadline_ns = $self->_deadline_ns_after($seconds);
    return $self->_submit_op('timeout', deadline_ns => $deadline_ns, %arg);
}

sub at ($self, $deadline, %arg) {
    $self->_validate_at_args($deadline, %arg);
    my $deadline_ns = $self->_deadline_ns_at($deadline);
    return $self->_submit_op('timeout', deadline_ns => $deadline_ns, %arg);
}


sub _new_op ($self, %arg) {
    return Linux::Event::Operation->_new(
        loop     => $self,
        kind     => $arg{kind},
        data     => $arg{data},
        callback => $arg{on_complete},
    );
}

sub _submit_op ($self, $kind, %arg) {
    croak 'kind is required' unless defined $kind;

    my $method = "_submit_$kind";
    my $backend = $self->{backend};
    croak "backend does not support $method" unless $backend->can($method);

    my $op = $self->_new_op(
        kind        => $kind,
        data        => $arg{data},
        on_complete => $arg{on_complete},
    );

    my $token = $backend->$method($op, %arg);
    croak 'token is required' unless defined $token;
    croak "duplicate token registration: $token" if exists $self->{ops_by_token}{$token};

    $op->_set_backend_token($token);
    $self->{ops_by_token}{$token} = $op;
    $self->{live_op_count}++;

    return $op;
}

sub _unregister_op ($self, $token) {
    return undef unless defined $token;

    my $op = delete $self->{ops_by_token}{$token};
    return undef unless $op;

    $self->{live_op_count}-- if $self->{live_op_count} > 0;
    return $op;
}

sub _cancel_op ($self, $op) {
    return 0 if $op->is_terminal;
    return $self->{backend}->_cancel_op($op);
}

sub _enqueue_callback ($self, $op) {
    push @{ $self->{callback_queue} }, $op;
    return;
}

sub _drain_callback_queue ($self) {
    my $queue = $self->{callback_queue};
    my $head  = $self->{callback_head};
    my $tail  = scalar(@{$queue});
    my $count = 0;

    while ($head < $tail) {
        my $op = $queue->[$head++];
        $op->_run_callback if defined $op;
        $count++;
    }

    @{$queue} = ();
    $self->{callback_head} = 0;

    return $count;
}

sub _tick_clock ($self) {
    $self->{clock}->tick;
    return $self->{clock}->now_ns;
}

sub _now_ns ($self) {
    return $self->_tick_clock;
}

sub _seconds_to_ns ($self, $seconds) {
    return int($seconds * NS_PER_S);
}

sub _deadline_ns_after ($self, $seconds) {
    my $delta_ns = $self->_seconds_to_ns($seconds);
    $delta_ns = 0 if $delta_ns < 0;

    my $now_ns = $self->_now_ns;
    return $now_ns + $delta_ns;
}

sub _deadline_ns_at ($self, $deadline) {
    return $self->_seconds_to_ns($deadline);
}

sub _remaining_ns_until ($self, $deadline_ns) {
    my $now_ns = $self->_now_ns;
    my $rem = $deadline_ns - $now_ns;
    return $rem > 0 ? $rem : 0;
}

sub _fake_complete_read_success ($self, $token, $chunk) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_read_success'
        unless $backend->can('_fake_complete_read_success');
    return $backend->_fake_complete_read_success($token, $chunk);
}

sub _fake_complete_read_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_read_error'
        unless $backend->can('_fake_complete_read_error');
    return $backend->_fake_complete_read_error($token, %arg);
}

sub _fake_complete_write_success ($self, $token, $bytes) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_write_success'
        unless $backend->can('_fake_complete_write_success');
    return $backend->_fake_complete_write_success($token, $bytes);
}

sub _fake_complete_write_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_write_error'
        unless $backend->can('_fake_complete_write_error');
    return $backend->_fake_complete_write_error($token, %arg);
}

sub _fake_complete_recv_success ($self, $token, $chunk) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_recv_success'
        unless $backend->can('_fake_complete_recv_success');
    return $backend->_fake_complete_recv_success($token, $chunk);
}

sub _fake_complete_recv_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_recv_error'
        unless $backend->can('_fake_complete_recv_error');
    return $backend->_fake_complete_recv_error($token, %arg);
}

sub _fake_complete_send_success ($self, $token, $bytes) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_send_success'
        unless $backend->can('_fake_complete_send_success');
    return $backend->_fake_complete_send_success($token, $bytes);
}

sub _fake_complete_send_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_send_error'
        unless $backend->can('_fake_complete_send_error');
    return $backend->_fake_complete_send_error($token, %arg);
}

sub _fake_complete_accept_success ($self, $token, $fh, $addr = undef) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_accept_success'
        unless $backend->can('_fake_complete_accept_success');
    return $backend->_fake_complete_accept_success($token, $fh, $addr);
}

sub _fake_complete_accept_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_accept_error'
        unless $backend->can('_fake_complete_accept_error');
    return $backend->_fake_complete_accept_error($token, %arg);
}

sub _fake_complete_connect_success ($self, $token) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_connect_success'
        unless $backend->can('_fake_complete_connect_success');
    return $backend->_fake_complete_connect_success($token);
}

sub _fake_complete_connect_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_connect_error'
        unless $backend->can('_fake_complete_connect_error');
    return $backend->_fake_complete_connect_error($token, %arg);
}

sub _fake_complete_shutdown_success ($self, $token) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_shutdown_success'
        unless $backend->can('_fake_complete_shutdown_success');
    return $backend->_fake_complete_shutdown_success($token);
}

sub _fake_complete_shutdown_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_shutdown_error'
        unless $backend->can('_fake_complete_shutdown_error');
    return $backend->_fake_complete_shutdown_error($token, %arg);
}

sub _fake_complete_close_success ($self, $token) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_close_success'
        unless $backend->can('_fake_complete_close_success');
    return $backend->_fake_complete_close_success($token);
}

sub _fake_complete_close_error ($self, $token, %arg) {
    my $backend = $self->{backend};
    croak 'active backend does not support _fake_complete_close_error'
        unless $backend->can('_fake_complete_close_error');
    return $backend->_fake_complete_close_error($token, %arg);
}

sub _validate_read_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh len data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    croak 'len is required' unless exists $arg{len};
    croak 'len must be defined' unless defined $arg{len};
    croak 'len must be non-negative' if $arg{len} < 0;
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_write_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh buf data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    croak 'buf is required' unless exists $arg{buf};
    croak 'buf must be defined' unless defined $arg{buf};
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_recv_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh len flags data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    croak 'len is required' unless exists $arg{len};
    croak 'len must be defined' unless defined $arg{len};
    croak 'len must be non-negative' if $arg{len} < 0;
    if (exists $arg{flags}) {
        croak 'flags must be defined' unless defined $arg{flags};
        croak 'flags must be an integer' if $arg{flags} !~ /\A-?\d+\z/;
    }
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_send_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh buf flags data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    croak 'buf is required' unless exists $arg{buf};
    croak 'buf must be defined' unless defined $arg{buf};
    if (exists $arg{flags}) {
        croak 'flags must be defined' unless defined $arg{flags};
        croak 'flags must be an integer' if $arg{flags} !~ /\A-?\d+\z/;
    }
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_accept_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_connect_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh addr data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    croak 'addr is required' unless exists $arg{addr};
    croak 'addr must be defined' unless defined $arg{addr};
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_shutdown_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh how data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    croak 'how is required' unless exists $arg{how};
    croak 'how must be defined' unless defined $arg{how};
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_close_args ($self, %arg) {
    $self->_validate_allowed_keys(\%arg, qw(fh data on_complete));
    croak 'fh is required' unless exists $arg{fh};
    croak 'fh is required' unless defined $arg{fh};
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_after_args ($self, $seconds, %arg) {
    croak 'after requires seconds' unless defined $seconds;
    $self->_validate_allowed_keys(\%arg, qw(data on_complete));
    $self->_validate_common_args(%arg);
    return;
}

sub _validate_at_args ($self, $deadline, %arg) {
    croak 'at requires deadline' unless defined $deadline;
    $self->_validate_allowed_keys(\%arg, qw(data on_complete));
    $self->_validate_common_args(%arg);
    return;
}

sub _normalize_shutdown_how ($self, $how) {
    if (defined($how) && !ref($how) && $how =~ /\A[0-9]+\z/ && ($how == SHUT_RD || $how == SHUT_WR || $how == SHUT_RDWR)) {
        return $how;
    }

    return SHUT_RD   if defined($how) && !ref($how) && $how eq 'read';
    return SHUT_WR   if defined($how) && !ref($how) && $how eq 'write';
    return SHUT_RDWR if defined($how) && !ref($how) && $how eq 'both';

    croak "how must be 'read', 'write', 'both', SHUT_RD, SHUT_WR, or SHUT_RDWR";
}

sub _validate_common_args ($self, %arg) {
    if (exists $arg{on_complete} && defined $arg{on_complete} && ref($arg{on_complete}) ne 'CODE') {
        croak 'on_complete must be a coderef';
    }
    return;
}

sub _validate_allowed_keys ($self, $href, @allowed) {
    my %allowed = map { $_ => 1 } @allowed;
    for my $key (keys %{$href}) {
        croak "unknown argument: $key" unless $allowed{$key};
    }
    return;
}

1;

__END__

=pod

=head1 NAME

Linux::Event::Proactor - Minimal proactor loop for Linux::Event

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::Proactor;

  my $loop = Linux::Event::Proactor->new(backend => 'uring');

  my $read = $loop->read(
    fh => $fh,
    len => 4096,
    data => { id => 1 },
    on_complete => sub ($op, $result, $ctx) {
      return if $op->is_cancelled;
      die $op->error->message if $op->failed;

      my $bytes = $result->{bytes};
      my $data  = $result->{data};
      my $eof   = $result->{eof};
    },
  );

  my $timer = $loop->after(0.250, on_complete => sub ($op, $result, $ctx) {
    # $result is { expired => 1 }
  });

  $loop->run;

=head1 DESCRIPTION

Linux::Event::Proactor is a small proactor-style event loop built for the
Linux::Event ecosystem. It models each in-flight action as a
L<Linux::Event::Operation> and keeps completion callback dispatch deferred
through an internal callback queue. Callbacks are never executed inline at
submission time or completion time.

The loop itself stays intentionally small. It submits operations, tracks them
until settlement, and drains queued callbacks. Higher-level buffering, framing,
connection policy, and ownership rules are expected to live in other layers.

=head1 CONSTRUCTOR

=head2 new

  my $loop = Linux::Event::Proactor->new(%arg);

Recognized arguments:

=over 4

=item * C<backend>

Either C<fake> or C<uring>. Defaults to C<fake>.

=item * C<clock>

Clock object used for timers. If omitted, a monotonic
L<Linux::Event::Clock> is created. The object must provide C<tick> and
C<now_ns>.

=item * C<queue_size>

Submission queue size for the uring backend. Defaults to C<64>.

=item * Any additional arguments

Additional arguments are passed through to the selected backend. The uring
backend accepts tuning arguments documented in
L<Linux::Event::Proactor::Backend::Uring>.

=back

=head1 LOOP METHODS

=head2 run

Runs the loop until C<stop> is called.

=head2 run_once

Processes backend completions and then drains queued callbacks once. Returns
the number of processed completions plus drained callbacks.

=head2 stop

Requests that C<run> stop after the current iteration.

=head2 clock

Returns the loop clock object.

=head2 backend_name

Returns the backend name, either C<fake> or C<uring>.

=head2 live_op_count

Returns the number of currently registered in-flight operations.

=head2 is_running

True while C<run> is active.

=head2 drain_callbacks

Drains the deferred callback queue immediately. This is mostly useful in tests.

=head1 OPERATIONS

Each submission method returns a L<Linux::Event::Operation>. Successful result
shapes are shown below. Errors are reported through C<< $op->error >> as a
L<Linux::Event::Error>.

=head2 read

  my $op = $loop->read(
    fh => $fh,
    len => $bytes,
    data => $ctx,
    on_complete => sub ($op, $result, $ctx) { ... },
  );

Result:

  {
    bytes => N,
    data  => $string,
    eof   => 0|1,
  }

=head2 write

  my $op = $loop->write(
    fh => $fh,
    buf => $buffer,
    data => $ctx,
    on_complete => sub ($op, $result, $ctx) { ... },
  );

Result:

  { bytes => N }

Partial writes are treated as success.

=head2 recv

Socket-oriented receive with optional flags.

  my $op = $loop->recv(
    fh    => $sock,
    len   => 4096,
    flags => 0,
  );

Result:

  {
    bytes => N,
    data  => $string,
    eof   => 0|1,
  }

=head2 send

Socket-oriented send with optional flags.

  my $op = $loop->send(
    fh    => $sock,
    buf   => $bytes,
    flags => 0,
  );

Result:

  { bytes => N }

Partial sends are treated as success.

=head2 accept

  my $op = $loop->accept(
    fh => $listen_socket,
  );

Result:

  {
    fh   => $client_socket,
    addr => $sockaddr,
  }

=head2 connect

  my $op = $loop->connect(
    fh   => $socket,
    addr => $sockaddr,
  );

Result:

  {}

=head2 shutdown

  my $op = $loop->shutdown(
    fh  => $socket,
    how => 'both',
  );

C<how> accepts the semantic values C<read>, C<write>, and C<both>. Numeric
C<SHUT_RD>, C<SHUT_WR>, and C<SHUT_RDWR> values are also accepted.

Result:

  {}

=head2 close

  my $op = $loop->close(
    fh => $fh,
  );

Result:

  {}

=head2 after

  my $op = $loop->after(0.5);

Schedules a timer relative to the loop clock.

=head2 at

  my $op = $loop->at($deadline_seconds);

Schedules a timer at an absolute deadline expressed in seconds in the loop
clock domain.

Both timer methods complete with:

  { expired => 1 }

=head1 CALLBACKS

Completion callbacks receive three arguments:

  sub ($op, $result, $data) { ... }

C<$result> is the successful result hashref for successful operations and
C<undef> for failed or cancelled operations. C<$data> is the opaque value
passed at submission time.

Callbacks are queued and later drained by C<run_once> or C<drain_callbacks>.
They are never executed inline.

=head1 DESIGN NOTES

=over 4

=item * Operations settle exactly once.

=item * Cancellation is delegated to the backend but settlement rules remain
centralized in the operation object.

=item * The loop stays policy-free. It does not impose buffering, framing, or
ownership conventions on filehandles.

=item * Callback queue draining uses an indexed queue rather than repeated
C<shift> calls so callback-heavy workloads avoid unnecessary array compaction.

=back

=head1 SEE ALSO

L<Linux::Event::Operation>, L<Linux::Event::Error>,
L<Linux::Event::Proactor::Backend::Uring>,
L<Linux::Event::Proactor::Backend::Fake>, L<Linux::Event::Clock>

=cut
