package Linux::Event::Kernel::Inotify;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.116';

use Carp qw(croak);
use File::Spec ();
use Scalar::Util qw(refaddr weaken);

require Linux::Event::Kernel::Inotify::Event;
require Linux::Event::Kernel::Inotify::Watch;
require Linux::Event::Loop;
require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

use constant {
    IN_ACCESS        => 0x00000001,
    IN_MODIFY        => 0x00000002,
    IN_ATTRIB        => 0x00000004,
    IN_CLOSE_WRITE   => 0x00000008,
    IN_CLOSE_NOWRITE => 0x00000010,
    IN_OPEN          => 0x00000020,
    IN_MOVED_FROM    => 0x00000040,
    IN_MOVED_TO      => 0x00000080,
    IN_CREATE        => 0x00000100,
    IN_DELETE        => 0x00000200,
    IN_DELETE_SELF   => 0x00000400,
    IN_MOVE_SELF     => 0x00000800,
    IN_ALL_EVENTS    => 0x00000fff,
    IN_UNMOUNT       => 0x00002000,
    IN_Q_OVERFLOW    => 0x00004000,
    IN_IGNORED       => 0x00008000,
    IN_ONLYDIR       => 0x01000000,
    IN_DONT_FOLLOW   => 0x02000000,
    IN_EXCL_UNLINK   => 0x04000000,
    IN_MASK_ADD      => 0x20000000,
    IN_ISDIR         => 0x40000000,
};

my @MONITORABLE = (
    [on_access        => IN_ACCESS],
    [on_modify        => IN_MODIFY],
    [on_attrib        => IN_ATTRIB],
    [on_close_write   => IN_CLOSE_WRITE],
    [on_close_nowrite => IN_CLOSE_NOWRITE],
    [on_open          => IN_OPEN],
    [on_moved_from    => IN_MOVED_FROM],
    [on_moved_to      => IN_MOVED_TO],
    [on_create        => IN_CREATE],
    [on_delete        => IN_DELETE],
    [on_delete_self   => IN_DELETE_SELF],
    [on_move_self     => IN_MOVE_SELF],
);

my @DISPATCH_ORDER = (
    [on_create        => IN_CREATE],
    [on_open          => IN_OPEN],
    [on_access        => IN_ACCESS],
    [on_modify        => IN_MODIFY],
    [on_attrib        => IN_ATTRIB],
    [on_close_write   => IN_CLOSE_WRITE],
    [on_close_nowrite => IN_CLOSE_NOWRITE],
    [on_moved_from    => IN_MOVED_FROM],
    [on_moved_to      => IN_MOVED_TO],
    [on_move_self     => IN_MOVE_SELF],
    [on_delete        => IN_DELETE],
    [on_delete_self   => IN_DELETE_SELF],
    [on_unmount       => IN_UNMOUNT],
    [on_ignored       => IN_IGNORED],
);

my %WATCH_CALLBACK = map { $_->[0] => 1 } @DISPATCH_ORDER;
$WATCH_CALLBACK{on_event} = 1;

my %CLASS_DESCRIPTOR;
my %LIVE;
my $NEXT_ID = 1;

sub _class_descriptor ($class) {
    return $CLASS_DESCRIPTOR{$class} if exists $CLASS_DESCRIPTOR{$class};
    croak "$class is not a Linux::Event::Kernel::Inotify subclass"
        if !$class->isa(__PACKAGE__);
    return $CLASS_DESCRIPTOR{$class} = {
        on_overflow => $class->can('on_overflow'),
        on_error    => $class->can('on_error'),
    };
}

sub _effective_descriptor ($class, $option) {
    my %descriptor = %{ _class_descriptor($class) };
    for my $name (qw(on_overflow on_error)) {
        next if !exists $option->{$name};
        my $callback = delete $option->{$name};
        croak "new(): $name must be a coderef" if ref($callback) ne 'CODE';
        $descriptor{$name} = $callback;
    }
    return \%descriptor;
}

sub new ($class, %option) {
    croak 'new(): must be called as a class method' if ref $class;
    my $descriptor = _effective_descriptor($class, \%option);
    my $loop = delete $option{loop};
    croak 'new(): loop must be an object implementing add() and watch()'
        if defined($loop) && (!ref($loop) || !$loop->can('add')
            || !$loop->can('watch'));
    my $data = delete $option{data};
    croak 'new(): unknown options: ' . join(', ', sort keys %option) if %option;

    my $id = $NEXT_ID++;
    my $self = bless {
        id             => $id,
        descriptor     => $descriptor,
        data           => $data,
        state          => 'unattached',
        terminal       => 0,
        loop           => undef,
        fd             => undef,
        watcher        => undef,
        next_watch_id  => 1,
        watches        => {},
        watch_order    => [],
        groups         => {},
        pending_events => [],
        resume_defer   => undef,
    }, $class;
    $LIVE{$id} = $self;
    weaken($LIVE{$id});

    $loop->add($self) if defined $loop;
    return $self;
}

sub _watch_event_mask ($callback) {
    my $mask = 0;
    for my $entry (@MONITORABLE) {
        $mask |= $entry->[1] if $callback->{ $entry->[0] };
    }
    $mask = IN_ALL_EVENTS if !$mask && $callback->{on_event};
    croak 'watch(): at least one monitorable callback or on_event is required'
        if !$mask;
    return $mask;
}

sub watch ($self, $path, %option) {
    croak 'watch(): Inotify is closed' if $self->{terminal};
    croak 'watch(): path must be a nonempty scalar'
        if !defined($path) || ref($path) || $path eq '';
    croak 'watch(): path must not contain NUL' if index($path, "\0") >= 0;

    my %callback;
    for my $name (keys %WATCH_CALLBACK) {
        next if !exists $option{$name};
        my $value = delete $option{$name};
        croak "watch(): $name must be a coderef" if ref($value) ne 'CODE';
        $callback{$name} = $value;
    }

    my %flag;
    for my $name (qw(only_dir dont_follow excl_unlink)) {
        next if !exists $option{$name};
        my $value = delete $option{$name};
        croak "watch(): $name must be 0 or 1"
            if !defined($value) || ref($value)
            || "$value" !~ /\A(?:0|1)\z/;
        $flag{$name} = $value ? 1 : 0;
    }

    croak 'watch(): unknown options: ' . join(', ', sort keys %option) if %option;
    my $event_mask = _watch_event_mask(\%callback);
    my $absolute = File::Spec->rel2abs($path);
    my $id = $self->{next_watch_id}++;

    my $watch = Linux::Event::Kernel::Inotify::Watch->_new(
        $self, $id, $absolute, $event_mask, \%callback, \%flag,
    );
    $self->{watches}{$id} = $watch;
    push @{ $self->{watch_order} }, $id;

    if ($self->{state} eq 'active') {
        my $ok = eval { $self->_activate_watch($watch); 1 };
        if (!$ok) {
            my $error = $@ || 'watch activation failed';
            delete $self->{watches}{$id};
            $watch->_terminate('failed');
            die $error;
        }
    }

    return $watch;
}

sub _attach_to_loop ($self, $loop) {
    croak 'add(): Inotify is not unattached'
        if $self->{terminal} || $self->{state} ne 'unattached' || $self->{loop};

    my $fd = _new_fd();
    $self->{fd} = $fd;
    $self->{loop} = $loop;

    my $ok = eval {
        for my $id (@{ $self->{watch_order} }) {
            my $watch = $self->{watches}{$id} // next;
            next if $watch->is_terminal;
            $self->_activate_watch($watch);
        }

        $self->{watcher} = $loop->watch(
            fd => $fd,
            _internal => 1,
            data => $self,
            read => \&_ready,
            error => \&_source_error,
            _callback_data_arg => 1,
        );
        1;
    };

    if (!$ok) {
        my $error = $@ || 'could not attach Inotify';
        eval { $self->{watcher}->cancel if $self->{watcher}; 1 };
        $self->{watcher} = undef;
        eval { _close_fd($fd); 1 };
        $self->{fd} = undef;
        $self->{loop} = undef;
        $self->{groups} = {};
        for my $watch (values %{ $self->{watches} }) {
            $watch->_reset_pending if $watch->is_active;
        }
        die $error;
    }

    $self->{state} = 'active';
    return $self;
}

sub _activate_watch ($self, $watch) {
    my $mask = $watch->_event_mask | IN_MASK_ADD;
    $mask |= IN_ONLYDIR if $watch->_flag('only_dir');
    $mask |= IN_DONT_FOLLOW if $watch->_flag('dont_follow');

    my $wd = _add_watch($self->{fd}, $watch->path, $mask);
    my $group = $self->{groups}{$wd};

    if ($group) {
        if (!!$group->{excl_unlink} != !!$watch->_flag('excl_unlink')) {
            croak 'watch(): excl_unlink must match existing watches for the same inode';
        }
    } else {
        if ($watch->_flag('excl_unlink')) {
            my $confirmed = eval {
                _add_watch($self->{fd}, $watch->path, $mask | IN_EXCL_UNLINK)
            };
            if (!defined $confirmed) {
                my $error = $@ || 'could not enable excl_unlink';
                eval { _rm_watch($self->{fd}, $wd); 1 };
                die $error;
            }
            croak 'watch(): inotify watch descriptor changed while enabling excl_unlink'
                if $confirmed != $wd;
        }
        $group = {
            wd          => $wd,
            excl_unlink => $watch->_flag('excl_unlink') ? 1 : 0,
            watches     => [],
        };
        $self->{groups}{$wd} = $group;
    }

    push @{ $group->{watches} }, $watch;
    $watch->_activate($wd);
    return $watch;
}

sub _ready ($self) {
    return if $self->{state} ne 'active';

    $self->_drain_pending if @{ $self->{pending_events} };
    return if $self->{state} ne 'active';

    my $events;
    my $ok = eval {
        $events = _read_events($self->{fd});
        1;
    };
    if (!$ok) {
        return $self->_runtime_fail($@ || 'inotify read failed');
    }

    push @{ $self->{pending_events} }, @$events if @$events;
    $self->_drain_pending if @{ $self->{pending_events} };
    return;
}

sub _drain_pending ($self) {
    while ($self->{state} eq 'active' && @{ $self->{pending_events} }) {
        my $record = shift @{ $self->{pending_events} };
        my $ok = eval {
            $self->_dispatch_record($record);
            1;
        };
        if (!$ok) {
            my $error = $@ || 'Inotify callback failed';
            $self->_schedule_resume
                if $self->{state} eq 'active'
                && @{ $self->{pending_events} };
            die $error;
        }
    }
    return;
}

sub _schedule_resume ($self) {
    return if $self->{resume_defer} || $self->{state} ne 'active';
    my $loop = $self->{loop};
    return if !$loop || !$loop->can('defer');

    $self->{resume_defer} = $loop->defer(sub {
        $self->{resume_defer} = undef;
        return if $self->{state} ne 'active';
        $self->_drain_pending;
    });
    return;
}

sub _record_relevant ($watch, $mask) {
    return 1 if $mask & $watch->_event_mask;
    return 1 if ($mask & IN_UNMOUNT) && $watch->_callback('on_unmount');
    return 1 if ($mask & IN_IGNORED) && $watch->_callback('on_ignored');
    return 1 if ($mask & (IN_UNMOUNT | IN_IGNORED))
        && $watch->_callback('on_event');
    return 0;
}

sub _dispatch_record ($self, $record) {
    my ($wd, $mask, $cookie, $name) = @$record;

    if ($mask & IN_Q_OVERFLOW) {
        my $callback = $self->{descriptor}{on_overflow};
        if ($callback) {
            $callback->($self);
            return;
        }
        die "Linux::Event Inotify queue overflow\n";
    }

    my $group = $self->{groups}{$wd} // return;
    my $ignored = !!($mask & IN_IGNORED);
    if ($ignored && $self->{groups}{$wd}
            && refaddr($self->{groups}{$wd}) == refaddr($group)) {
        delete $self->{groups}{$wd};
    }

    my @watch = @{ $group->{watches} };
    my $error;

    my $ok = eval {
        WATCH:
        for my $watch (@watch) {
            last WATCH if $self->{state} ne 'active';
            next WATCH if !$watch->is_active || $watch->_wd != $wd;
            next WATCH if !_record_relevant($watch, $mask);

            my $event = Linux::Event::Kernel::Inotify::Event->_new(
                $watch, $name, $mask, $cookie,
            );

            for my $entry (@DISPATCH_ORDER) {
                last if !$watch->is_active || $self->{state} ne 'active';
                my ($callback_name, $bit) = @$entry;
                next if !($mask & $bit);
                my $callback = $watch->_callback($callback_name) // next;
                $callback->($event);
            }

            next WATCH if !$watch->is_active || $self->{state} ne 'active';
            my $catch_all = $watch->_callback('on_event');
            $catch_all->($event) if $catch_all;
        }
        1;
    };
    $error = $@ if !$ok;

    if ($ignored) {
        for my $watch (@watch) {
            next if !$watch->is_active || $watch->_wd != $wd;
            delete $self->{watches}{ $watch->_id };
            $watch->_terminate('ignored');
        }
    }

    die $error if defined($error) && length($error);
    return;
}

sub _source_error ($self) {
    return if $self->{state} ne 'active';
    return $self->_runtime_fail("Linux::Event Inotify event source failed\n");
}

sub _runtime_fail ($self, $error) {
    my $callback = $self->{descriptor}{on_error};
    if ($callback) {
        my $ok = eval {
            $callback->($self, "$error");
            1;
        };
        my $callback_error = $@;
        $self->close if !$self->{terminal};
        die $callback_error if !$ok;
        return;
    }

    $self->close if !$self->{terminal};
    die $error;
}

sub _cancel_watch ($self, $watch) {
    return $watch if $watch->is_terminal;

    my $wd = $watch->_wd;
    my $error;

    delete $self->{watches}{ $watch->_id };

    if (defined $wd && $self->{state} eq 'active') {
        my $group = $self->{groups}{$wd};
        if ($group) {
            @{ $group->{watches} } = grep {
                $_->_id != $watch->_id
            } @{ $group->{watches} };

            if (!@{ $group->{watches} }) {
                delete $self->{groups}{$wd};
                my $ok = eval {
                    _rm_watch($self->{fd}, $wd);
                    1;
                };
                $error = $@ if !$ok;
            }
        }
    }

    $watch->_terminate('cancelled');
    die $error if defined($error) && length($error);
    return $watch;
}

sub close ($self) {
    return $self if $self->{terminal};

    if (my $defer = delete $self->{resume_defer}) {
        eval { $defer->cancel; 1 };
    }
    if (my $watcher = delete $self->{watcher}) {
        eval { $watcher->cancel; 1 };
    }

    my $close_error;
    if (defined(my $fd = delete $self->{fd})) {
        my $ok = eval {
            _close_fd($fd);
            1;
        };
        $close_error = $@ if !$ok;
    }

    for my $watch (values %{ $self->{watches} }) {
        $watch->_terminate('closed') if !$watch->is_terminal;
    }

    $self->{watches} = {};
    $self->{watch_order} = [];
    $self->{groups} = {};
    $self->{pending_events} = [];
    $self->{loop} = undef;
    $self->{data} = undef;
    $self->{state} = 'closed';
    $self->{terminal} = 1;
    delete $LIVE{ $self->{id} };

    die $close_error if defined($close_error) && length($close_error);
    return $self;
}

sub loop ($self) { $self->{terminal} ? undef : $self->{loop} }
sub fd ($self) { $self->{state} eq 'active' ? $self->{fd} : undef }
sub state ($self) { $self->{state} }
sub is_active ($self) { $self->{state} eq 'active' }
sub is_terminal ($self) { !!$self->{terminal} }
sub watch_count ($self) { scalar keys %{ $self->{watches} } }

sub data ($self, @argument) {
    croak 'data(): Inotify is closed' if $self->{terminal};
    $self->{data} = $argument[0] if @argument;
    return $self->{data};
}

sub _objects_for_loop ($class, $loop) {
    my @object;
    for my $id (keys %LIVE) {
        my $object = $LIVE{$id} // next;
        next if $object->{terminal} || $object->{state} ne 'active';
        next if !$object->{loop}
            || refaddr($object->{loop}) != refaddr($loop);
        push @object, $object;
    }
    return \@object;
}

sub CLONE ($class) {
    %CLASS_DESCRIPTOR = ();
    %LIVE = ();
    return;
}

sub CLONE_SKIP ($class) { 1 }

sub DESTROY ($self) {
    eval { $self->close if !$self->{terminal}; 1 };
    return;
}

1;

__END__

=head1 NAME

Linux::Event::Kernel::Inotify - inotify filesystem notifications on a Loop

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::Kernel::Inotify;
  use Linux::Event::Loop;

  my $loop = Linux::Event::Loop->new;
  my $inotify = Linux::Event::Kernel::Inotify->new;

  my $watch = $inotify->watch(
      'log.txt',
      on_modify => sub ($event) {
          say $event->path . ' changed';
      },
      on_close_write => sub ($event) {
          say $event->path . ' finished being written';
      },
      on_event => sub ($event) {
          say 'mask=' . $event->mask;
      },
  );

  $loop->add($inotify);
  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::Kernel::Inotify> owns one nonblocking Linux inotify instance.
C<watch()> creates logical L<Linux::Event::Kernel::Inotify::Watch>
subscriptions. Several logical watches that resolve to one kernel watch
descriptor are safely faned out by the parent.

A detached Inotify object only records watch specifications. Kernel watches
begin when the object is attached with C<< $loop->add($inotify) >>. Supplying
C<loop =E<gt> $loop> to C<new> is the equivalent immediate-attachment form.
Calling C<watch()> on an already attached object activates that watch
synchronously.

=head1 WATCH CALLBACKS

The monitorable callback names are:

  on_access
  on_modify
  on_attrib
  on_close_write
  on_close_nowrite
  on_open
  on_moved_from
  on_moved_to
  on_create
  on_delete
  on_delete_self
  on_move_self

C<on_unmount> and C<on_ignored> receive kernel lifecycle output conditions but
do not establish a watch mask by themselves. C<on_event> is an optional
catch-all. If C<on_event> is the only monitorable callback, all ordinary
inotify events are requested. When monitorable specific callbacks are present,
they define the kernel mask and C<on_event> sees those delivered records.

For one kernel record, matching specific callbacks run in this documented
order:

  on_create
  on_open
  on_access
  on_modify
  on_attrib
  on_close_write
  on_close_nowrite
  on_moved_from
  on_moved_to
  on_move_self
  on_delete
  on_delete_self
  on_unmount
  on_ignored
  on_event

The same Event object is passed to every callback for one logical Watch.
The first callback exception stops dispatch of that record and propagates
through the active Loop driver. Already-read later records are retained for a
later turn.

Cancellation is immediately terminal. Once C<< $watch->cancel >> returns, no
later callback can target that Watch, including the C<IN_IGNORED> record caused
by C<inotify_rm_watch(2)>.

=head1 WATCH OPTIONS

C<only_dir>, C<dont_follow>, and C<excl_unlink> map to the corresponding Linux
inotify watch behavior. C<excl_unlink> must agree across logical subscriptions
that resolve to the same underlying kernel watch descriptor.

Relative paths are converted to absolute paths when C<watch()> is called, so a
later C<chdir> does not retarget a pending subscription.

=head1 PARENT CALLBACKS

C<on_overflow =E<gt> sub ($inotify) { ... }> handles instance-wide inotify
queue overflow. If it is absent, queue overflow raises an exception rather
than silently accepting lost filesystem state.

C<on_error =E<gt> sub ($inotify, $error) { ... }> handles fatal inotify-source
errors. The parent is closed after this callback returns or throws.

=head1 LIFECYCLE

C<close()> is idempotent and terminal. It removes the Loop registration,
closes the inotify fd, and makes all child Watch objects terminal without
delivering callbacks.

An attached Inotify object with zero watches remains an active Loop resource
until C<close()> so applications may add watches dynamically.

=head1 SEE ALSO

L<Linux::Event::Kernel::Inotify::Watch>,
L<Linux::Event::Kernel::Inotify::Event>, L<Linux::Event::Loop>.

=cut
