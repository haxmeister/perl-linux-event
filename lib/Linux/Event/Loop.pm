package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.116';

use Carp qw(croak);
use Errno ();
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed refaddr weaken);
use utf8 ();

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

require Linux::Event::Loop::Introspection;
our @ISA = ('Linux::Event::Loop::Introspection');

fieldhash my %DEFER_STATE;
my $DEFER_CALLBACK_BATCH = 1024;

sub _fork_write_all ($fh, $bytes) {
    my $offset = 0;
    while ($offset < length($bytes)) {
        my $written = syswrite($fh, $bytes, length($bytes) - $offset, $offset);
        next if !defined($written) && $! == Errno::EINTR();
        die "fork(): handshake write failed: $!\n" if !defined $written;
        die "fork(): handshake write returned zero bytes\n" if !$written;
        $offset += $written;
    }
    return;
}

sub _fork_read_exact ($fh, $length) {
    my $bytes = '';
    while (length($bytes) < $length) {
        my $chunk = '';
        my $read = sysread($fh, $chunk, $length - length($bytes));
        next if !defined($read) && $! == Errno::EINTR();
        die "fork(): handshake read failed: $!\n" if !defined $read;
        return undef if !$read;
        $bytes .= $chunk;
    }
    return $bytes;
}

sub _fork_child_failure ($fh, $error) {
    $error = "$error";
    $error = "child reconstruction failed\n" if $error eq '';
    utf8::encode($error) if utf8::is_utf8($error);
    $error = substr($error, 0, 1_048_576);
    eval { _fork_write_all($fh, 'E' . pack('N', length($error)) . $error); 1 };
    require POSIX;
    POSIX::_exit(255);
}

sub _fork_child_reset_deferred ($self) {
    my $state = delete $DEFER_STATE{$self};
    $state->_fork_child_drop if $state;
    return;
}

sub fork ($self, %option) {
    $self->_assert_owner_native('fork');
    croak 'fork(): Loop must be quiescent and cannot fork during dispatch'
        if $self->running;

    my %known = map { $_ => 1 } qw(share clone move);
    my @unknown = sort grep { !$known{$_} } keys %option;
    croak 'fork(): unknown options: ' . join(', ', @unknown) if @unknown;

    my %disposition;
    my %selected;
    for my $mode (qw(share clone move)) {
        my $list = exists($option{$mode}) ? $option{$mode} : [];
        croak "fork(): $mode must be an array reference" if ref($list) ne 'ARRAY';
        for my $object (@$list) {
            croak "fork(): $mode entries must be resource objects"
                if !blessed($object);
            my $id = refaddr($object);
            croak 'fork(): a resource may appear in only one disposition list'
                if $selected{$id}++;
            croak "fork(): $mode resource is not current in this Loop"
                if !$self->has($object);
            $disposition{$id} = $mode;
        }
    }

    my $objects = $self->objects;
    for my $object (@$objects) {
        my $mode = $disposition{ refaddr($object) } // 'drop';
        croak 'fork(): resource does not implement fork disposition hooks'
            if !$object->can('_fork_preflight') || !$object->can('_fork_child_drop');
        $object->_fork_preflight($mode, $self);
        croak "fork(): resource does not implement child '$mode' disposition"
            if $mode ne 'drop' && !$object->can("_fork_child_$mode");
        croak 'fork(): moved resource does not implement parent disposition'
            if $mode eq 'move' && !$object->can('_fork_parent_move');
    }

    require Linux::Event::_Resolver;
    Linux::Event::_Resolver->_fork_prepare_loop($self);

    require Socket;
    socketpair(my $parent_channel, my $child_channel,
        Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC())
        or croak "fork(): socketpair failed: $!";

    my $pid = CORE::fork();
    if (!defined $pid) {
        my $errno = 0 + $!;
        close $parent_channel;
        close $child_channel;
        $! = $errno;
        return undef;
    }

    if ($pid == 0) {
        close $parent_channel;
        my $ok = eval {
            $self->_fork_child_reset;
            $self->_fork_child_reset_deferred;
            require Linux::Event::Kernel::Signal;
            Linux::Event::Kernel::Signal->_fork_child_drop_loop($self);

            for my $object (@$objects) {
                my $mode = $disposition{ refaddr($object) } // 'drop';
                my $method = $mode eq 'drop'
                    ? '_fork_child_drop' : "_fork_child_$mode";
                $object->$method($self);
            }
            1;
        };
        _fork_child_failure($child_channel, $@) if !$ok;

        my $ready = eval { _fork_write_all($child_channel, 'R'); 1 };
        _fork_child_failure($child_channel, $@) if !$ready;
        my $commit = eval { _fork_read_exact($child_channel, 1) };
        if ($@ || !defined($commit) || $commit ne 'C') {
            require POSIX;
            POSIX::_exit(255);
        }
        close $child_channel;
        return 0;
    }

    close $child_channel;
    my $status = eval { _fork_read_exact($parent_channel, 1) };
    if ($@ || !defined $status) {
        my $error = $@ || "fork(): child reconstruction channel closed\n";
        waitpid($pid, 0);
        close $parent_channel;
        die $error;
    }
    if ($status eq 'E') {
        my $length_bytes = _fork_read_exact($parent_channel, 4);
        my $length = defined($length_bytes) ? unpack('N', $length_bytes) : 0;
        my $message = $length ? _fork_read_exact($parent_channel, $length) : undef;
        waitpid($pid, 0);
        close $parent_channel;
        $message //= 'child reconstruction failed';
        croak "fork(): $message";
    }
    if ($status ne 'R') {
        waitpid($pid, 0);
        close $parent_channel;
        croak 'fork(): invalid child reconstruction handshake';
    }

    my $moved = eval {
        for my $object (@$objects) {
            next if ($disposition{ refaddr($object) } // '') ne 'move';
            $object->_fork_parent_move($pid);
        }
        1;
    };
    if (!$moved) {
        my $error = $@ || "fork(): parent move disposition failed\n";
        eval { _fork_write_all($parent_channel, 'A'); 1 };
        waitpid($pid, 0);
        close $parent_channel;
        die $error;
    }

    _fork_write_all($parent_channel, 'C');
    close $parent_channel;
    return $pid;
}

sub add ($self, $object) {
    $self->_assert_owner_native('add');
    croak 'add(): object must support loop attachment'
        if !blessed($object) || !$object->can('_attach_to_loop');
    $object->_attach_to_loop($self);
    return $object;
}
sub _defer_state ($self) {
    return $DEFER_STATE{$self} if $DEFER_STATE{$self};

    require Linux::Event::Kernel::Event;
    my $fd = Linux::Event::Kernel::Event::_new_fd();
    my $state = bless {
        fd       => $fd,
        queue    => [],
        pending  => 0,
        signaled => 0,
    }, 'Linux::Event::Loop::_DeferService';

    my $ok = eval {
        $self->watch(
            fd        => $fd,
            _internal => 1,
            read      => sub { $state->_dispatch },
            error     => sub { die "Linux::Event defer event source failed\n" },
            no_args   => 1,
            lean      => 1,
        );
        1;
    };
    if (!$ok) {
        my $error = $@;
        my $close_fd = delete $state->{fd};
        eval { Linux::Event::Kernel::Event::_close_fd($close_fd); 1 }
            if defined $close_fd;
        die $error;
    }

    $DEFER_STATE{$self} = $state;
    return $state;
}

sub defer ($self, $callback) {
    $self->_assert_owner_native('defer');
    croak 'defer(): callback must be a coderef' if ref($callback) ne 'CODE';
    my $state = $self->_defer_state;
    my $deferred = bless {
        state    => $state,
        callback => $callback,
        active   => 1,
    }, 'Linux::Event::_Deferred';
    weaken($deferred->{state});
    $state->_enqueue($deferred);
    return $deferred;
}

sub _deferred_count ($self) {
    my $state = $DEFER_STATE{$self};
    return $state ? $state->{pending} : 0;
}

sub _deferred_fd ($self) {
    my $state = $DEFER_STATE{$self};
    return $state ? $state->{fd} : undef;
}

sub CLONE_SKIP ($class) { 1 }

package Linux::Event::Loop::_DeferService;

sub _signal ($self) {
    return if $self->{signaled};
    Linux::Event::Kernel::Event::_signal_fd($self->{fd}, 1);
    $self->{signaled} = 1;
    return;
}

sub _enqueue ($self, $deferred) {
    push @{ $self->{queue} }, $deferred;
    $self->{pending}++;
    my $ok = eval { $self->_signal; 1 };
    return if $ok;

    my $error = $@;
    pop @{ $self->{queue} };
    $self->{pending}--;
    $deferred->{active} = 0;
    delete $deferred->{callback};
    die $error;
}

sub _cancel ($self, $deferred) {
    return if !$deferred->{active};
    $deferred->{active} = 0;
    delete $deferred->{callback};
    $self->{pending}-- if $self->{pending};
    $self->{queue} = [] if !$self->{pending};
    return;
}

sub _fork_child_drop ($self) {
    for my $deferred (@{ $self->{queue} // [] }) {
        next if !$deferred;
        $deferred->{active} = 0;
        delete $deferred->{callback};
    }
    $self->{queue} = [];
    $self->{pending} = 0;
    $self->{signaled} = 0;
    my $fd = delete $self->{fd};
    eval { Linux::Event::Kernel::Event::_close_fd($fd); 1 } if defined $fd;
    return;
}

sub _dispatch ($self) {
    return if !defined $self->{fd};
    Linux::Event::Kernel::Event::_drain_fd($self->{fd});
    $self->{signaled} = 0;

    my $eligible = scalar @{ $self->{queue} };
    $eligible = $DEFER_CALLBACK_BATCH
        if $eligible > $DEFER_CALLBACK_BATCH;

    my $error;
    for (1 .. $eligible) {
        my $deferred = shift @{ $self->{queue} };
        next if !$deferred || !$deferred->{active};

        $deferred->{active} = 0;
        $self->{pending}-- if $self->{pending};
        my $callback = delete $deferred->{callback};

        local $@;
        my $ok = eval { $callback->(); 1 };
        if (!$ok) {
            $error = $@ || "deferred callback failed\n";
            last;
        }
    }

    if (!$self->{pending}) {
        $self->{queue} = [];
    }
    else {
        local $@;
        my $ok = eval { $self->_signal; 1 };
        $error = $@ || "defer event source signal failed\n"
            if !$ok && !defined $error;
    }

    die $error if defined $error;
    return;
}

sub CLONE_SKIP ($class) { 1 }

sub DESTROY ($self) {
    for my $deferred (@{ $self->{queue} // [] }) {
        next if !$deferred;
        $deferred->{active} = 0;
        delete $deferred->{callback};
    }
    $self->{queue} = [];
    $self->{pending} = 0;
    my $fd = delete $self->{fd};
    eval { Linux::Event::Kernel::Event::_close_fd($fd); 1 } if defined $fd;
    return;
}

package Linux::Event::_Deferred;

sub cancel ($self) {
    return $self if !$self->{active};
    my $state = $self->{state};
    if ($state) {
        $state->_cancel($self);
    }
    else {
        $self->{active} = 0;
        delete $self->{callback};
    }
    return $self;
}

sub is_active ($self) { !!$self->{active} }
sub CLONE_SKIP ($class) { 1 }

package Linux::Event::_Registration;
sub CLONE_SKIP ($class) { 1 }

package Linux::Event::Loop;

1;

__END__

=head1 NAME

Linux::Event::Loop - Linux-native epoll event loop

=head1 SYNOPSIS

  use Linux::Event::Loop;
  use Linux::Event::IO::Sock::Stream;

  package Client;
  use parent 'Linux::Event::IO::Sock::Stream';

  sub on_data ($self, $bytes) {
      print $bytes;
  }

  package main;
  my $loop = Linux::Event::Loop->new;
  my $connection = $loop->add(Client->connect(
      host => '127.0.0.1',
      port => 9999,
  ));
  $loop->run;

=head1 DESCRIPTION

Linux::Event::Loop owns the native epoll instance, descriptor registry, event
buffer, shared timer source, and readiness dispatch. It is the only public loop
class.

Public resource objects may be attached during construction with
C<loop =E<gt> $loop>, or constructed detached and passed to C<add>. C<add>
invokes the object's attachment implementation and returns that same object.

Ordered-byte resources may receive their application callbacks as subclass
methods or constructor coderefs. This does not change Loop attachment or
ownership; see F<docs/FIRST-CLASS-STREAM-CALLBACKS.md>.

The public resource leaves are L<Linux::Event::IO::Pipe>,
L<Linux::Event::IO::TTY>, L<Linux::Event::IO::Sock::Stream>,
L<Linux::Event::IO::Sock::Listener>, L<Linux::Event::IO::Sock::Dgram>,
L<Linux::Event::Kernel::Timer>, L<Linux::Event::Kernel::Signal>,
L<Linux::Event::Kernel::Event>, L<Linux::Event::Kernel::Inotify>, and
L<Linux::Event::Kernel::Process>.
A resource rejects attachment to a second Loop or attachment after reaching a
terminal state.

C<watch> is the low-level descriptor API. It registers immediately and returns
an opaque native registration handle. The handle is not a public class or a
subclassing API.

=head1 HIGH-LEVEL OBJECTS

=head2 add($object)

Attach a detached public I/O or Kernel resource and return that exact object.
The object becomes owned by this Loop until its normal terminal lifecycle
releases it.

The following styles are equivalent:

  my $a = Client->connect(
      loop => $loop,
      host => '127.0.0.1',
      port => 9999,
  );

  my $b = $loop->add(Client->connect(
      host => '127.0.0.1',
      port => 9999,
  ));

A timer uses the same attachment contract:

  package Delay;
  use parent 'Linux::Event::Kernel::Timer';
  sub on_timer ($self) { ... }

  my $timer = $loop->add(Delay->new(after => 0.25));

The C<loop> constructor option and C<add> are both primary public APIs. Loop has
no resource-specific factory hierarchy.

=head1 DEFERRED WORK

=head2 defer($callback)

Queue a no-argument callback for non-reentrant delivery by this Loop and
return an opaque one-shot handle:

  my $pending = $loop->defer(sub {
      finish_protocol_transition();
  });

C<defer> never invokes the callback inline. Deferred callbacks are delivered
FIFO. Work queued while a deferred drain is already running is not eligible
for that drain and runs on a later Loop turn.

The returned handle supports C<cancel> and C<is_active>. Cancellation is
idempotent. Dropping the handle does not cancel the work; the Loop retains
pending callbacks until delivery, cancellation, or Loop destruction.

A deferred callback exception propagates through the active Loop driver after
the remaining queue has been made runnable again. The failed callback is
consumed, while later callbacks remain pending for a subsequent drive after
the exception is caught.

Each deferred drain examines at most 1,024 queued entries. Remaining work
re-signals the private eventfd source so kernel readiness gets another epoll
turn instead of a self-scheduling deferred chain monopolizing the Loop.

C<defer> is owner-interpreter scheduling only. It is not a thread-safe or
cross-process callback queue. Cross-context producers should publish data
through an appropriate queue or IPC mechanism and use
L<Linux::Event::Kernel::Event> to wake the owning Loop.

The defer source is created lazily and is internal to the Loop. Because it is
an eventfd registered with the same epoll instance, deferred work also makes
C<poll_fd> readable for supported foreign-loop integration.

=head1 PROCESS FORKING

=head2 fork(%disposition)

Fork the current process while giving Linux::Event an explicit resource
ownership plan:

  my $pid = $loop->fork(
      share => [$listener],
      clone => [$timer, $inotify],
      move  => [$connection],
  );

The return value follows C<CORE::fork>: the parent receives the positive child
PID, the child receives zero, and a syscall failure returns undef with C<$!>
preserved.

This first contract is intentionally quiescent-only. Calling C<fork> while the
Loop is running or dispatching throws. Forking from a callback should therefore
be scheduled by application control flow outside the active Loop driver; a
future C<defer_fork> convenience may be added separately.

Managed fork also requires that the calling process have no unrelated live
threads. Linux::Event shuts down its own idle resolver worker service before
the syscall and rejects active resolver requests, but it cannot make arbitrary
third-party pthread state, native-library locks, or application-created threads
safe for continued Perl execution in the child.

Every listed object must already be current in this Loop, and one object may
appear in only one list. Unsupported resource/disposition combinations throw
before C<fork(2)> when they can be determined in advance. Unlisted managed
resources are parent-only: their child copies are closed or made terminal
without application lifecycle callbacks.

The initial supported dispositions are:

=over 4

=item * Listener: C<share>, C<move>

C<share> registers the inherited listening socket in both independent reactors.
C<move> keeps it in the child and poisons the parent object after the child has
finished reconstruction.

=item * Timer: C<clone>, C<move>

The child receives an independent timer scheduled for the same absolute
monotonic deadline. C<move> additionally cancels the parent copy only after the
child is ready.

=item * Inotify: C<clone>, C<move>

C<clone> creates a fresh child inotify instance and rebuilds live logical
watches. C<move> transfers use of the inherited instance to the child reactor.

=item * established plain socket Stream: C<move>

The child keeps the inherited connected socket and existing ordered-byte native
state. The parent closes its descriptor and marks the Stream C<moved>. Stream
C<share> is deliberately unsupported.

=back

Other public resource types currently support only the default child drop.
Pending socket connections, non-plain Stream transports, and active resolver
requests reject managed fork.

The child never reuses the parent's epoll instance or Loop-owned timerfd.
C<fork> replaces them with fresh child reactor infrastructure before any
selected resource is registered. Pending C<defer> callbacks are not inherited.

Move uses a private parent/child handshake. The child first completes its
reactor reconstruction, then the parent performs its move-side descriptor
teardown, and only then is the child released to continue. This prevents both
processes from concurrently treating a moved resource as active during the
handoff.

A Loop also records its creating process. After an ordinary C<CORE::fork>,
using the inherited Loop for registration, driving, introspection, statistics,
or tuning throws instead of silently operating on copied reactor state.
C<Loop-E<gt>fork> is the supported path that deliberately establishes a fresh
child reactor and reassigns ownership.

=head1 RAW DESCRIPTOR API

=head2 watch(fh => $fh, read => $callback) / watch(fd => $fd, read => $callback)

Register exactly one filehandle or integer descriptor. Supported options are:

=over 4

=item * C<read>, C<write>, C<error>

Coderefs for readable, writable, and terminal/error readiness. Only C<read>
and C<write> control ordinary interest; terminal flags are always observed.
For one returned event, callback order is error, read, then write. Cancellation
after any callback suppresses the remaining callbacks for that event.

=item * C<data>

An arbitrary retained value available through C<< $registration->data >>.

=item * C<no_args =E<gt> 1>

Call readiness coderefs without an argument. By default each receives the
opaque registration handle.

=item * C<lean =E<gt> 1>

With C<no_args>, avoid retaining references used only by handle accessors.
This is an expert registration-throughput optimization.

=item * C<edge_triggered =E<gt> 1>

Use C<EPOLLET>. The callback must drain the descriptor until C<EAGAIN>.

=item * C<oneshot =E<gt> 1>

Use C<EPOLLONESHOT>. The application is responsible for its rearm policy.

=back

Registering an fd that is already registered replaces its native registration
with C<EPOLL_CTL_MOD>. Cancelling the obsolete handle cannot remove the new
registration.

=head2 watch_fd($fd, read => $callback)

Low-level positional form used by Linux::Event internals and specialized code.
It creates the same native registration and has the same dispatch path as
C<watch>. Normal application code should prefer C<watch>.

=head2 unwatch_fd($fd)

Cancel the current registration for C<$fd>, if any. Prefer the registration's
C<cancel> method when the handle is available.

=head1 REGISTRATION METHODS

The opaque result of C<watch> supports C<fd>, C<fh>, C<data>, C<loop>, C<lean>,
C<cancel>, C<enable_read>, C<disable_read>, C<enable_write>, and
C<disable_write>. C<cancel> is idempotent and makes an obsolete handle inert,
including after native watcher storage is reused. Cancellation releases the
registration's retained Perl state. An fd-only registration returns undef from
C<fh>.

=head1 DRIVING THE LOOP

=head2 poll_fd

Return the Loop-owned epoll descriptor used to integrate Linux::Event beneath
another event system. The descriptor becomes readable whenever Linux::Event has
kernel readiness pending, including its timerfd, signalfd, pidfds, eventfds, inotify descriptors,
and ordinary I/O registrations.

The returned descriptor is borrowed. Linux::Event owns it and closes it when
the Loop is destroyed; foreign adapters must not close it. An adapter that
requires a Perl filehandle may duplicate the descriptor and watch the duplicate.

Foreign loops should normally watch C<poll_fd> for level-triggered read
readiness and call C<poll> once from that readiness callback.

=head2 poll

Perform exactly one nonblocking C<epoll_wait> and dispatch the returned batch.
Returns the number of events returned by epoll. This is the supported
foreign-loop drive primitive; adapters should not depend on C<resources()> or
use C<run_once(0)> as an integration convention.

If more than C<event_capacity> events are pending, the epoll descriptor remains
readable so a level-triggered foreign loop can schedule another turn. C<poll>
does not run or stop the foreign event system. A prior C<stop> request does not
suppress C<poll>.

Like the other driver methods, C<poll> cannot recursively drive the same Loop
from one of its callbacks. An interrupted C<epoll_wait> returns zero events;
other C<epoll_wait> failures throw. Callback exceptions propagate after native
driver state is restored.

=head2 run

Wait and dispatch until C<stop> is called.

=head2 run_once($timeout_ms = -1)

Run one C<epoll_wait>. A negative timeout blocks indefinitely, zero polls, and
a positive value is a maximum wait in milliseconds. Returns the number of
events returned by epoll. A prior C<stop> request does not suppress a later
C<run_once> call.

=head2 run_for($seconds)

Run against a monotonic deadline for the supplied non-negative number of
seconds.

Only one driver method may be active for a given Loop. Calling C<poll>,
C<run>, C<run_once>, or C<run_for> recursively on that same Loop throws an
exception;
a callback may drive a different Loop. C<set_event_capacity> is likewise
rejected while its Loop is running or dispatching.

=head2 stop

Request that the active C<run> or C<run_for> return after the current dispatch
work completes.

=head1 INTROSPECTION

=head2 running

True while this Loop is inside C<poll>, C<run>, C<run_once>, or C<run_for>,
including from a callback. This is an O(1) query of native driver state.

=head2 count

Return the number of current managed public resource objects. Opaque raw
registrations and private helper objects are excluded.

=head2 has($object)

Return true only when the exact object is current in this Loop. An object owned
by another Loop, detached, or terminal returns false.

=head2 objects

Return a new array reference containing the actual current managed resource
objects. Order is unspecified. The query reads authoritative native and service
registries without maintaining a duplicate public-object registry.

=head2 inspect($object)

Return a new type-specific snapshot. Every result contains C<type>, C<class>,
and C<registered>. A supported object which is not current in this Loop returns
only those common fields with C<registered =E<gt> 0>. Current objects also
include C<state> and resource-specific fields. See F<docs/INTROSPECTION.md> for
the complete field table and the stable introspection type labels.

=head2 census

Return a new hash reference containing the documented introspection counts for
ordered-byte resources, listeners, datagrams, timers, signals, eventfd
notifications, inotify resources, and processes. See F<docs/INTROSPECTION.md> for exact keys.

=head2 resources

Return a native resource snapshot: epoll and timer fds, total/public/internal
registration counts, public registration fds, active timers, and current
registry, timer-heap, and event-buffer capacities. C<timer_fd> is undef until
the first L<Linux::Event::Kernel::Timer> creates the Loop's shared timer source.
This scans native state and does not create resources.

=head2 why_alive

Return an array reference of actionable user-visible liveness reasons. Managed
resource entries contain the same snapshot as C<inspect> plus the exact
C<object>. Direct raw C<watch> registrations appear as C<registration> entries
with their fd. Private backing registrations are not repeated as reasons.

=head2 pressure

Return conservative C<registrations>, C<timers>, and C<event_batch> capacity
and utilization snapshots. Event-batch maximum and utilization are undef until
an epoll wait has completed. This is implementation pressure, not a synthesized
health or latency score.

=head1 DIAGNOSTICS AND TUNING

C<stats> returns counters for epoll waits, event classes, callbacks,
registrations, timer scheduling and delivery, dispatch batching, and lifecycle
activity. C<reset_stats> resets them without changing profiling state.
C<profile($boolean)> returns the Loop and changes future nanosecond timing
collection without resetting existing statistics. Statistics remain readable
while profiling is disabled. Profiling changes the measured workload, so it
should be disabled for normal benchmarks.

C<event_capacity> returns the reusable epoll event-array capacity, default
8,192. C<set_event_capacity($capacity)> accepts an integer from 1 through
1,048,576 while the Loop is neither running nor dispatching. A larger value can
return more ready registrations from one C<epoll_wait>; it also allocates a
larger reusable array.

C<callback_scope_limit> returns the maximum callbacks sharing one bounded Perl
temporary scope, default 128. C<set_callback_scope_limit($limit)> accepts an
integer from 0 through 1,048,576. Zero uses one scope for the whole dispatch
batch; a positive value rotates the scope after that many callbacks.

C<enable_watcher_reclaim($boolean = 1)> toggles immediate watcher-structure
recycling after dispatch. It defaults off and exposes an experimental native
memory/throughput tradeoff. The measured defaults should normally remain
unchanged unless application-specific benchmarks justify tuning them.

Loop tuning uses instance methods rather than subclass policy:

  my $loop = Linux::Event::Loop->new;
  $loop->set_event_capacity(16_384);
  $loop->set_callback_scope_limit(256);
  $loop->enable_watcher_reclaim(1); # experimental

=head1 INTERPRETER OWNERSHIP

A Loop and every native object it owns belong to the Perl interpreter that
created them. They are not cloned into a new ithread. A cloned
L<Linux::Event::Kernel::Event> handle is deliberately restricted to signaling
its owner through eventfd; it cannot manage the Loop, invoke callbacks, or
access owner-interpreter data.

=head1 PLATFORM

Linux only. The implementation uses epoll directly.

=cut
