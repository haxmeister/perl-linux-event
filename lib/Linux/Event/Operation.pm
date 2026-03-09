package Linux::Event::Operation;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub _new ($class, %arg) {
    croak 'loop is required' unless $arg{loop};
    croak 'kind is required' unless defined $arg{kind};

    if (exists $arg{callback} && defined $arg{callback} && ref($arg{callback}) ne 'CODE') {
        croak 'callback must be a coderef';
    }

    my $self = bless {
        loop             => $arg{loop},
        kind             => $arg{kind},
        data             => $arg{data},
        state            => 'pending',

        result           => undef,
        error            => undef,

        callback         => $arg{callback},
        callback_queued  => 0,
        callback_ran     => 0,
        detached         => 0,

        backend_token    => undef,
        cancel_requested => 0,
    }, $class;

    return $self;
}

sub loop         ($self) { return $self->{loop} }
sub kind         ($self) { return $self->{kind} }
sub data         ($self) { return $self->{data} }
sub state        ($self) { return $self->{state} }
sub result       ($self) { return $self->{result} }
sub error        ($self) { return $self->{error} }

sub is_pending   ($self) { return $self->{state} eq 'pending'   ? 1 : 0 }
sub is_done      ($self) { return $self->{state} eq 'done'      ? 1 : 0 }
sub is_cancelled ($self) { return $self->{state} eq 'cancelled' ? 1 : 0 }
sub is_terminal  ($self) { return $self->{state} ne 'pending'   ? 1 : 0 }

sub success ($self) {
    return ($self->{state} eq 'done' && !defined $self->{error}) ? 1 : 0;
}

sub failed ($self) {
    return ($self->{state} eq 'done' && defined $self->{error}) ? 1 : 0;
}

sub on_complete ($self, $cb) {
    croak 'callback is required' unless defined $cb;
    croak 'callback must be a coderef' unless ref($cb) eq 'CODE';
    croak 'callback already set' if $self->_has_callback;

    $self->{callback} = $cb;

    if ($self->is_terminal) {
        $self->_queue_callback_if_needed;
    }

    return $self;
}

sub cancel ($self) {
    return $self->{loop}->_cancel_op($self);
}

sub detach ($self) {
    $self->{detached} = 1;
    $self->{callback} = undef;
    $self->{data}     = undef;
    return $self;
}

sub _set_backend_token ($self, $token) {
    $self->{backend_token} = $token;
    return $self;
}

sub _backend_token ($self) {
    return $self->{backend_token};
}

sub _has_callback ($self) {
    return defined $self->{callback} ? 1 : 0;
}

sub _settle_success ($self, $result) {
    croak 'operation already terminal' if $self->is_terminal;

    $self->{state}  = 'done';
    $self->{result} = $result;
    $self->{error}  = undef;

    $self->_queue_callback_if_needed;
    return $self;
}

sub _settle_error ($self, $error) {
    croak 'operation already terminal' if $self->is_terminal;

    $self->{state}  = 'done';
    $self->{result} = undef;
    $self->{error}  = $error;

    $self->_queue_callback_if_needed;
    return $self;
}

sub _settle_cancelled ($self) {
    croak 'operation already terminal' if $self->is_terminal;

    $self->{state}  = 'cancelled';
    $self->{result} = undef;
    $self->{error}  = undef;

    $self->_queue_callback_if_needed;
    return $self;
}

sub _queue_callback_if_needed ($self) {
    return $self if $self->{detached};
    return $self unless $self->_has_callback;
    return $self if $self->{callback_queued};
    return $self if $self->{callback_ran};

    $self->{callback_queued} = 1;
    $self->{loop}->_enqueue_callback($self);

    return $self;
}

sub _run_callback ($self) {
    return $self if $self->{detached};
    return $self unless $self->_has_callback;
    return $self if $self->{callback_ran};

    my $cb   = $self->{callback};
    my $data = $self->{data};

    $self->{callback_queued} = 0;
    $self->{callback_ran}    = 1;

    $cb->($self, $self->{result}, $data);

    $self->_cleanup_after_callback;
    return $self;
}

sub _cleanup_after_callback ($self) {
    $self->{callback} = undef;
    $self->{data}     = undef;
    return $self;
}

1;

__END__

=pod

=head1 NAME

Linux::Event::Operation - In-flight operation object for Linux::Event::Proactor

=head1 SYNOPSIS

  my $op = $loop->read(
    fh => $fh,
    len => 4096,
    data => $ctx,
    on_complete => sub ($op, $result, $ctx) {
      if ($op->failed) {
        warn $op->error->message;
        return;
      }

      return if $op->is_cancelled;

      my $state = $op->state;
      my $kind  = $op->kind;
      my $data  = $op->data;
      my $res   = $op->result;
    },
  );

  $op->cancel;

=head1 DESCRIPTION

Linux::Event::Operation represents one in-flight action submitted through
L<Linux::Event::Proactor>. It tracks kind, state, completion result, failure
object, user data, and the deferred completion callback.

Users normally obtain operation objects from the proactor loop; they are not
constructed directly.

=head1 STATES

An operation begins in C<pending> and then settles exactly once into one of
the following terminal states:

=over 4

=item * C<done>

Successful or failed completion. Use C<success> or C<failed> to distinguish.

=item * C<cancelled>

Cancellation won the race and the operation was not completed successfully.

=back

=head1 METHODS

=head2 loop

Returns the owning proactor loop.

=head2 kind

Returns the submitted operation kind such as C<read>, C<send>, or C<timeout>.

=head2 data

Returns the user data payload associated with the operation.

=head2 state

Returns the current state string.

=head2 result

Returns the success result hashref once the operation completes successfully.
Returns C<undef> for failed or cancelled operations.

=head2 error

Returns the L<Linux::Event::Error> object for failed operations. Returns
C<undef> otherwise.

=head2 is_pending

True while the operation is still pending.

=head2 is_done

True when the operation reached the C<done> state.

=head2 is_cancelled

True when the operation reached the C<cancelled> state.

=head2 is_terminal

True when the operation is no longer pending.

=head2 success

True for successful completion.

=head2 failed

True for terminal failure.

=head2 on_complete

  $op->on_complete(sub ($op, $result, $data) { ... });

Attaches a callback if one was not already supplied. If the operation is
already terminal, the callback is queued for later execution; it is still not
run inline.

=head2 cancel

Requests cancellation through the owning loop. Returns true if the request was
accepted, false otherwise.

=head2 detach

Drops the callback and user data from the operation. This is useful when the
user wants completion bookkeeping to continue but no longer wants a callback or
attached context retained.

=head1 CALLBACK CONTRACT

Callbacks receive:

  sub ($op, $result, $data) { ... }

On success, C<$result> is the operation-specific result hashref. On failure or
cancellation, C<$result> is C<undef> and the operation state indicates the
outcome.

Callbacks are deferred through the loop callback queue and never executed
inline. After the callback runs, the stored callback and user data are cleared
to reduce retained memory.

=head1 SEE ALSO

L<Linux::Event::Proactor>, L<Linux::Event::Error>

=cut
