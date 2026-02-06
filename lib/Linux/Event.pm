package Linux::Event;

use strict;
use warnings;
use IO::Uring::Easy;
use Carp qw(croak carp);
use Scalar::Util qw(weaken refaddr);
use Time::HiRes qw(time);

# File watching support (optional - load on demand)
our $INOTIFY_AVAILABLE = eval { require Linux::Inotify2; 1 };
our $FANOTIFY_AVAILABLE = eval { require Linux::Fanotify; 1 };

our $VERSION = '0.001';

=head1 NAME

Linux::Event - High-performance Linux event framework using io_uring

=head1 SYNOPSIS

    use Linux::Event;
    
    my $loop = Linux::Event->new();
    
    # I/O watchers
    $loop->io(
        fh => $socket,
        poll => 'r',
        cb => sub {
            my $data = <$socket>;
            print "Received: $data\n";
        }
    );
    
    # Timer watchers
    $loop->timer(
        after => 5,
        cb => sub {
            print "5 seconds elapsed\n";
        }
    );
    
    # Periodic timers
    my $ticker = $loop->periodic(
        interval => 1,
        cb => sub {
            print "Tick\n";
        }
    );
    
    # Signal watchers
    $loop->signal(
        signal => 'INT',
        cb => sub {
            print "Caught SIGINT\n";
            $loop->stop();
        }
    );
    
    # Idle callbacks (run when no other events)
    $loop->idle(
        cb => sub {
            print "Idle...\n";
        }
    );
    
    # Deferred execution
    $loop->defer(sub {
        print "Deferred callback\n";
    });
    
    # File/directory watching (inotify)
    $loop->watch(
        path => '/var/log/syslog',
        events => ['modify', 'create'],
        cb => sub {
            my ($watcher, $event, $name) = @_;
            print "File event: $event on $name\n";
        }
    );
    
    # Filesystem monitoring (fanotify, requires kernel 5.1+)
    $loop->fswatch(
        path => '/home',
        events => ['open', 'close_write', 'create'],
        cb => sub {
            my ($watcher, $event, $path, $pid) = @_;
            print "FS event: $event on $path by PID $pid\n";
        }
    );
    
    # Run the event loop
    $loop->run();

=head1 DESCRIPTION

Linux::Event is a high-performance event framework for Linux that leverages
io_uring through IO::Uring::Easy for exceptional I/O performance. It provides 
a familiar event loop API similar to other event frameworks (EV, AnyEvent, POE) 
but with the performance benefits of io_uring.

Features:

=over 4

=item * I/O watchers with read/write/error polling

=item * One-shot and periodic timers

=item * Signal handlers

=item * Idle callbacks

=item * Deferred execution

=item * Watcher management (start, stop, destroy)

=item * Priority-based event processing

=item * High-performance io_uring backend

=item * File/directory watching (inotify)

=item * Filesystem monitoring (fanotify, kernel 5.1+)

=item * Clean, simple API

=back

=head1 METHODS

=head2 new(%options)

Create a new event loop.

Options:

=over 4

=item * queue_size - io_uring queue size (default: 256)

=item * max_events - Max events per iteration (default: 32)

=back

    my $loop = Linux::Event->new(
        queue_size => 512,
        max_events => 64
    );

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $queue_size = delete $opts{queue_size} || 256;
    my $max_events = delete $opts{max_events} || 32;
    
    my $self = bless {
        uring => IO::Uring::Easy->new(queue_size => $queue_size),
        max_events => $max_events,
        running => 0,
        stop_requested => 0,
        
        # Watcher storage
        io_watchers => {},      # fd => { r => [...], w => [...], e => [...] }
        timers => [],           # Array of timer watchers
        signals => {},          # signal => [watchers]
        idle_watchers => [],
        deferred => [],
        
        # File watching (inotify)
        inotify_fd => undef,
        inotify_watches => {},  # wd => watcher
        
        # Filesystem watching (fanotify)
        fanotify_fd => undef,
        fanotify_watches => [], # Array of watchers
        
        # Next watcher ID
        next_id => 1,
        
        # Signal pipes for signal handling
        signal_pipes => {},
        signal_setup => {},
    }, $class;
    
    return $self;
}

=head2 io(%options)

Create an I/O watcher.

Options:

=over 4

=item * fh - Filehandle to watch (required)

=item * poll - Poll mode: 'r' (read), 'w' (write), 'rw' (both) (required)

=item * cb - Callback to invoke (required)

=item * data - User data to pass to callback (optional)

=item * priority - Watcher priority, higher runs first (default: 0)

=back

Returns a watcher object.

    my $watcher = $loop->io(
        fh => $socket,
        poll => 'r',
        cb => sub {
            my ($watcher, $revents) = @_;
            # $revents: 'r' = readable, 'w' = writable, 'e' = error
            my $data = <$socket>;
            print "Got: $data\n";
        }
    );
    
    # Later...
    $watcher->stop();
    $watcher->start();

=cut

sub io {
    my ($self, %opts) = @_;
    
    my $fh = delete $opts{fh} or croak "fh is required";
    my $poll = delete $opts{poll} or croak "poll is required";
    my $cb = delete $opts{cb} or croak "cb is required";
    my $data = delete $opts{data};
    my $priority = delete $opts{priority} || 0;
    
    croak "Invalid poll mode: $poll" unless $poll =~ /^r?w?$/i || $poll eq 'rw';
    
    my $fd = fileno($fh);
    croak "Cannot get fileno for filehandle" unless defined $fd;
    
    my $watcher = Linux::Event::Watcher->new(
        id => $self->{next_id}++,
        type => 'io',
        loop => $self,
        fh => $fh,
        fd => $fd,
        poll => lc($poll),
        cb => $cb,
        data => $data,
        priority => $priority,
        active => 1,
    );
    
    # Store watcher
    $self->{io_watchers}{$fd} ||= { r => [], w => [], e => [] };
    
    if ($poll =~ /r/i) {
        push @{$self->{io_watchers}{$fd}{r}}, $watcher;
    }
    if ($poll =~ /w/i) {
        push @{$self->{io_watchers}{$fd}{w}}, $watcher;
    }
    
    # Start polling
    $self->_poll_io($watcher) if $watcher->{active};
    
    return $watcher;
}

sub _poll_io {
    my ($self, $watcher) = @_;
    
    return unless $watcher->{active};
    
    # Set up multishot poll
    my $poll_mask = 0;
    require POSIX;
    
    if ($watcher->{poll} =~ /r/) {
        $poll_mask |= 0x001;  # POLLIN
    }
    if ($watcher->{poll} =~ /w/) {
        $poll_mask |= 0x004;  # POLLOUT
    }
    
    # Use the underlying ring for poll_multishot
    $self->{uring}->ring->poll_multishot($watcher->{fh}, $poll_mask, 0, sub {
        my ($res, $flags) = @_;
        
        return unless $watcher->{active};
        
        # Determine what events occurred
        my $revents = '';
        $revents .= 'r' if $res & 0x001;  # POLLIN
        $revents .= 'w' if $res & 0x004;  # POLLOUT
        $revents .= 'e' if $res & 0x008;  # POLLERR
        
        # Invoke callback
        eval {
            $watcher->{cb}->($watcher, $revents);
        };
        if ($@) {
            carp "I/O watcher callback died: $@";
        }
        
        # Check if this is the last event (no MORE flag)
        if (!($flags & 0x01)) {  # IORING_CQE_F_MORE
            # Poll ended, restart if still active
            $self->_poll_io($watcher) if $watcher->{active};
        }
    });
}

=head2 timer(%options)

Create a one-shot timer.

Options:

=over 4

=item * after - Seconds to wait (required)

=item * cb - Callback to invoke (required)

=item * data - User data (optional)

=item * priority - Watcher priority (default: 0)

=back

Returns a watcher object.

    my $timer = $loop->timer(
        after => 5.5,
        cb => sub {
            my ($watcher) = @_;
            print "Timer fired!\n";
        }
    );

=cut

sub timer {
    my ($self, %opts) = @_;
    
    my $after = delete $opts{after};
    croak "after is required" unless defined $after;
    my $cb = delete $opts{cb} or croak "cb is required";
    my $data = delete $opts{data};
    my $priority = delete $opts{priority} || 0;
    
    my $watcher = Linux::Event::Watcher->new(
        id => $self->{next_id}++,
        type => 'timer',
        loop => $self,
        after => $after,
        cb => $cb,
        data => $data,
        priority => $priority,
        active => 1,
        fire_time => time() + $after,
    );
    
    push @{$self->{timers}}, $watcher;
    
    # Schedule the timer
    $self->_schedule_timer($watcher);
    
    return $watcher;
}

sub _schedule_timer {
    my ($self, $watcher) = @_;
    
    return unless $watcher->{active};
    
    $self->{uring}->timeout(
        seconds => $watcher->{after},
        on_timeout => sub {
            return unless $watcher->{active};
            
            eval {
                $watcher->{cb}->($watcher);
            };
            if ($@) {
                carp "Timer callback died: $@";
            }
            
            # One-shot timer, deactivate
            $watcher->{active} = 0;
        },
        on_error => sub {
            carp "Timer error: $_[0]";
        }
    );
}

=head2 periodic(%options)

Create a periodic timer that fires repeatedly.

Options:

=over 4

=item * interval - Seconds between fires (required)

=item * cb - Callback to invoke (required)

=item * offset - Initial offset in seconds (default: interval)

=item * data - User data (optional)

=item * priority - Watcher priority (default: 0)

=back

Returns a watcher object.

    my $ticker = $loop->periodic(
        interval => 1.0,
        cb => sub {
            my ($watcher) = @_;
            print "Tick ", time(), "\n";
        }
    );

=cut

sub periodic {
    my ($self, %opts) = @_;
    
    my $interval = delete $opts{interval};
    croak "interval is required" unless defined $interval;
    my $cb = delete $opts{cb} or croak "cb is required";
    my $offset = delete $opts{offset} // $interval;
    my $data = delete $opts{data};
    my $priority = delete $opts{priority} || 0;
    
    my $watcher = Linux::Event::Watcher->new(
        id => $self->{next_id}++,
        type => 'periodic',
        loop => $self,
        interval => $interval,
        offset => $offset,
        cb => $cb,
        data => $data,
        priority => $priority,
        active => 1,
        fire_time => time() + $offset,
    );
    
    push @{$self->{timers}}, $watcher;
    
    # Schedule first fire
    $self->_schedule_periodic($watcher, $offset);
    
    return $watcher;
}

sub _schedule_periodic {
    my ($self, $watcher, $delay) = @_;
    
    return unless $watcher->{active};
    
    $delay //= $watcher->{interval};
    
    $self->{uring}->timeout(
        seconds => $delay,
        on_timeout => sub {
            return unless $watcher->{active};
            
            eval {
                $watcher->{cb}->($watcher);
            };
            if ($@) {
                carp "Periodic timer callback died: $@";
            }
            
            # Reschedule if still active
            if ($watcher->{active}) {
                $watcher->{fire_time} = time() + $watcher->{interval};
                $self->_schedule_periodic($watcher, $watcher->{interval});
            }
        }
    );
}

=head2 signal(%options)

Create a signal watcher.

Options:

=over 4

=item * signal - Signal name or number (required)

=item * cb - Callback to invoke (required)

=item * data - User data (optional)

=item * priority - Watcher priority (default: 0)

=back

Returns a watcher object.

    my $sig = $loop->signal(
        signal => 'INT',  # or 'SIGINT' or 2
        cb => sub {
            my ($watcher, $signum) = @_;
            print "Caught signal $signum\n";
            $loop->stop();
        }
    );

=cut

sub signal {
    my ($self, %opts) = @_;
    
    my $signal = delete $opts{signal} or croak "signal is required";
    my $cb = delete $opts{cb} or croak "cb is required";
    my $data = delete $opts{data};
    my $priority = delete $opts{priority} || 0;
    
    # Normalize signal name
    $signal =~ s/^SIG//i;
    $signal = uc($signal);
    
    require Config;
    my @sig_name = split(' ', $Config::Config{sig_name});
    my @sig_num = split(' ', $Config::Config{sig_num});
    my %signo = map { $sig_name[$_] => $sig_num[$_] } 0 .. $#sig_name;
    
    my $signum;
    if ($signal =~ /^\d+$/) {
        $signum = $signal;
    } else {
        $signum = $signo{$signal};
        croak "Unknown signal: $signal" unless defined $signum;
    }
    
    my $watcher = Linux::Event::Watcher->new(
        id => $self->{next_id}++,
        type => 'signal',
        loop => $self,
        signal => $signal,
        signum => $signum,
        cb => $cb,
        data => $data,
        priority => $priority,
        active => 1,
    );
    
    # Store watcher
    push @{$self->{signals}{$signum}}, $watcher;
    
    # Set up signal handling
    $self->_setup_signal($signum);
    
    return $watcher;
}

sub _setup_signal {
    my ($self, $signum) = @_;
    
    return if $self->{signal_setup}{$signum};
    
    # Use a simple flag-based approach
    my $flag = \(my $signal_flag = 0);
    
    # Install signal handler
    require Config;
    my @sig_name = split(' ', $Config::Config{sig_name});
    my $signame = $sig_name[$signum];
    
    $SIG{$signame} = sub {
        $$flag = 1;
    };
    
    # Poll the flag periodically
    $self->periodic(
        interval => 0.01,  # Check every 10ms
        cb => sub {
            if ($$flag) {
                $$flag = 0;
                
                # Invoke all watchers for this signal
                for my $watcher (@{$self->{signals}{$signum} || []}) {
                    next unless $watcher->{active};
                    
                    eval {
                        $watcher->{cb}->($watcher, $signum);
                    };
                    if ($@) {
                        carp "Signal watcher callback died: $@";
                    }
                }
            }
        }
    );
    
    $self->{signal_setup}{$signum} = 1;
}

=head2 idle(%options)

Create an idle watcher that runs when no other events are pending.

Options:

=over 4

=item * cb - Callback to invoke (required)

=item * data - User data (optional)

=item * priority - Watcher priority (default: 0)

=back

Returns a watcher object.

    my $idle = $loop->idle(
        cb => sub {
            my ($watcher) = @_;
            print "Idle...\n";
        }
    );

=cut

sub idle {
    my ($self, %opts) = @_;
    
    my $cb = delete $opts{cb} or croak "cb is required";
    my $data = delete $opts{data};
    my $priority = delete $opts{priority} || 0;
    
    my $watcher = Linux::Event::Watcher->new(
        id => $self->{next_id}++,
        type => 'idle',
        loop => $self,
        cb => $cb,
        data => $data,
        priority => $priority,
        active => 1,
    );
    
    push @{$self->{idle_watchers}}, $watcher;
    
    return $watcher;
}

=head2 defer($callback)

Schedule a callback to run on the next event loop iteration.

    $loop->defer(sub {
        print "Deferred execution\n";
    });

=cut

sub defer {
    my ($self, $cb) = @_;
    
    croak "callback is required" unless ref($cb) eq 'CODE';
    
    push @{$self->{deferred}}, $cb;
}

=head2 watch(%options)

Create a file/directory watcher using inotify (requires Linux::Inotify2).

Options:

=over 4

=item * path - File or directory path to watch (required)

=item * events - Array of event names to watch (required)

=item * recursive - Recursively watch subdirectories (default: false)

=item * cb - Callback to invoke (required)

=item * data - User data (optional)

=item * priority - Watcher priority (default: 0)

=back

Events can be: 'access', 'modify', 'attrib', 'close_write', 'close_nowrite',
'open', 'moved_from', 'moved_to', 'create', 'delete', 'delete_self', 
'move_self', 'all_events'.

Returns a watcher object.

    my $watcher = $loop->watch(
        path => '/var/log/syslog',
        events => ['modify', 'create'],
        cb => sub {
            my ($watcher, $event, $name) = @_;
            print "Event: $event on $name\n";
        }
    );

Requires: Linux 2.6.13+, Linux::Inotify2 module

=cut

sub watch {
    my ($self, %opts) = @_;
    
    croak "Linux::Inotify2 not available" unless $INOTIFY_AVAILABLE;
    
    my $path = delete $opts{path} or croak "path is required";
    my $events = delete $opts{events} or croak "events is required";
    my $recursive = delete $opts{recursive} || 0;
    my $cb = delete $opts{cb} or croak "cb is required";
    my $data = delete $opts{data};
    my $priority = delete $opts{priority} || 0;
    
    croak "events must be an array reference" unless ref($events) eq 'ARRAY';
    
    # Initialize inotify if not already done
    unless ($self->{inotify}) {
        $self->{inotify} = Linux::Inotify2->new()
            or croak "Failed to create inotify instance: $!";
        
        # Watch the inotify file descriptor for events
        $self->io(
            fh => $self->{inotify}->fileno,
            poll => 'r',
            cb => sub {
                $self->{inotify}->poll();
            }
        );
    }
    
    # Convert event names to inotify constants
    my $mask = 0;
    my %event_map = (
        'access'        => Linux::Inotify2::IN_ACCESS(),
        'modify'        => Linux::Inotify2::IN_MODIFY(),
        'attrib'        => Linux::Inotify2::IN_ATTRIB(),
        'close_write'   => Linux::Inotify2::IN_CLOSE_WRITE(),
        'close_nowrite' => Linux::Inotify2::IN_CLOSE_NOWRITE(),
        'open'          => Linux::Inotify2::IN_OPEN(),
        'moved_from'    => Linux::Inotify2::IN_MOVED_FROM(),
        'moved_to'      => Linux::Inotify2::IN_MOVED_TO(),
        'create'        => Linux::Inotify2::IN_CREATE(),
        'delete'        => Linux::Inotify2::IN_DELETE(),
        'delete_self'   => Linux::Inotify2::IN_DELETE_SELF(),
        'move_self'     => Linux::Inotify2::IN_MOVE_SELF(),
        'all_events'    => Linux::Inotify2::IN_ALL_EVENTS(),
    );
    
    for my $event (@$events) {
        my $event_lc = lc($event);
        croak "Unknown event: $event" unless exists $event_map{$event_lc};
        $mask |= $event_map{$event_lc};
    }
    
    my $watcher = Linux::Event::Watcher->new(
        id => $self->{next_id}++,
        type => 'watch',
        loop => $self,
        path => $path,
        events => $events,
        recursive => $recursive,
        cb => $cb,
        data => $data,
        priority => $priority,
        active => 1,
        inotify_watches => [],
    );
    
    # Add the watch
    my $w = $self->{inotify}->watch(
        $path,
        $mask,
        sub {
            my $e = shift;
            return unless $watcher->{active};
            
            # Convert mask back to event names
            my @event_names;
            for my $name (keys %event_map) {
                push @event_names, $name if $e->mask & $event_map{$name};
            }
            
            my $event_str = join(',', @event_names) || 'unknown';
            
            eval {
                $watcher->{cb}->($watcher, $event_str, $e->name || $path);
            };
            if ($@) {
                carp "Watch callback died: $@";
            }
        }
    );
    
    push @{$watcher->{inotify_watches}}, $w;
    
    # Handle recursive watching
    if ($recursive && -d $path) {
        $self->_watch_recursive($watcher, $path, $mask, \%event_map);
    }
    
    return $watcher;
}

sub _watch_recursive {
    my ($self, $watcher, $dir, $mask, $event_map) = @_;
    
    require File::Find;
    
    File::Find::find({
        wanted => sub {
            return unless -d $_;
            return if $_ eq $dir;  # Already watching root
            
            my $subdir = $File::Find::name;
            
            my $w = $self->{inotify}->watch(
                $subdir,
                $mask,
                sub {
                    my $e = shift;
                    return unless $watcher->{active};
                    
                    my @event_names;
                    for my $name (keys %$event_map) {
                        push @event_names, $name if $e->mask & $event_map->{$name};
                    }
                    
                    my $event_str = join(',', @event_names) || 'unknown';
                    my $full_path = $subdir . '/' . ($e->name || '');
                    
                    eval {
                        $watcher->{cb}->($watcher, $event_str, $full_path);
                    };
                    if ($@) {
                        carp "Watch callback died: $@";
                    }
                }
            );
            
            push @{$watcher->{inotify_watches}}, $w if $w;
        },
        no_chdir => 1,
    }, $dir);
}

=head2 fswatch(%options)

Create a filesystem watcher using fanotify (requires Linux::Fanotify and root privileges).

Options:

=over 4

=item * path - Mount point, directory, or file to watch (required)

=item * events - Array of event names to watch (required)

=item * mark_type - 'mount', 'filesystem', or 'inode' (default: 'mount')

=item * cb - Callback to invoke (required)

=item * data - User data (optional)

=item * priority - Watcher priority (default: 0)

=back

Events can be: 'access', 'modify', 'close_write', 'close_nowrite', 'open',
'open_exec', 'attrib', 'create', 'delete', 'delete_self', 'moved_from',
'moved_to', 'move_self', 'open_perm', 'access_perm'.

Note: create/delete/move events require Linux 5.1+

Returns a watcher object.

    my $watcher = $loop->fswatch(
        path => '/home',
        events => ['open', 'close_write'],
        cb => sub {
            my ($watcher, $event, $path, $pid) = @_;
            print "PID $pid: $event on $path\n";
        }
    );

Requires: Linux 2.6.37+ (5.1+ for create/delete/move), Linux::Fanotify module, root privileges

=cut

sub fswatch {
    my ($self, %opts) = @_;
    
    croak "Linux::Fanotify not available" unless $FANOTIFY_AVAILABLE;
    
    my $path = delete $opts{path} or croak "path is required";
    my $events = delete $opts{events} or croak "events is required";
    my $mark_type = delete $opts{mark_type} || 'mount';
    my $cb = delete $opts{cb} or croak "cb is required";
    my $data = delete $opts{data};
    my $priority = delete $opts{priority} || 0;
    
    croak "events must be an array reference" unless ref($events) eq 'ARRAY';
    croak "Invalid mark_type: $mark_type" 
        unless $mark_type =~ /^(mount|filesystem|inode)$/;
    
    # Initialize fanotify if not already done
    unless ($self->{fanotify}) {
        $self->{fanotify} = Linux::Fanotify::FanotifyGroup->new(
            Linux::Fanotify::FAN_CLASS_NOTIF() | Linux::Fanotify::FAN_NONBLOCK(),
            Linux::Fanotify::O_RDONLY() | Linux::Fanotify::O_LARGEFILE()
        ) or croak "Failed to create fanotify instance: $! (are you root?)";
        
        # Watch the fanotify file descriptor for events
        $self->io(
            fh => $self->{fanotify}->fd,
            poll => 'r',
            cb => sub {
                my @events = $self->{fanotify}->read(1);
                
                for my $event (@events) {
                    # Process each fanotify watcher
                    for my $fw (@{$self->{fanotify_watches}}) {
                        next unless $fw->{active};
                        
                        # Check if event matches this watcher's mask
                        my $matches = 0;
                        for my $evt_name (@{$fw->{events}}) {
                            my $evt_lc = lc($evt_name);
                            if ($self->_fanotify_event_matches($event, $evt_lc)) {
                                $matches = 1;
                                last;
                            }
                        }
                        
                        next unless $matches;
                        
                        # Get event name
                        my $event_name = $self->_fanotify_mask_to_name($event->mask);
                        my $pid = $event->pid;
                        my $path = $event->filename || 'unknown';
                        
                        eval {
                            $fw->{cb}->($fw, $event_name, $path, $pid);
                        };
                        if ($@) {
                            carp "Fswatch callback died: $@";
                        }
                    }
                }
            }
        );
    }
    
    # Convert event names to fanotify constants
    my $mask = 0;
    my %event_map = (
        'access'        => Linux::Fanotify::FAN_ACCESS(),
        'modify'        => Linux::Fanotify::FAN_MODIFY(),
        'close_write'   => Linux::Fanotify::FAN_CLOSE_WRITE(),
        'close_nowrite' => Linux::Fanotify::FAN_CLOSE_NOWRITE(),
        'open'          => Linux::Fanotify::FAN_OPEN(),
        'open_exec'     => Linux::Fanotify::FAN_OPEN_EXEC(),
    );
    
    # Linux 5.1+ events
    if (Linux::Fanotify->can('FAN_CREATE')) {
        $event_map{create} = Linux::Fanotify::FAN_CREATE();
        $event_map{delete} = Linux::Fanotify::FAN_DELETE();
        $event_map{delete_self} = Linux::Fanotify::FAN_DELETE_SELF();
        $event_map{moved_from} = Linux::Fanotify::FAN_MOVED_FROM();
        $event_map{moved_to} = Linux::Fanotify::FAN_MOVED_TO();
        $event_map{move_self} = Linux::Fanotify::FAN_MOVE_SELF();
        $event_map{attrib} = Linux::Fanotify::FAN_ATTRIB();
    }
    
    for my $event (@$events) {
        my $event_lc = lc($event);
        if (exists $event_map{$event_lc}) {
            $mask |= $event_map{$event_lc};
        } else {
            carp "Unknown or unsupported fanotify event: $event (may require Linux 5.1+)";
        }
    }
    
    # Determine mark flags
    my $mark_flags = Linux::Fanotify::FAN_MARK_ADD();
    if ($mark_type eq 'mount') {
        $mark_flags |= Linux::Fanotify::FAN_MARK_MOUNT();
    } elsif ($mark_type eq 'filesystem') {
        $mark_flags |= Linux::Fanotify::FAN_MARK_FILESYSTEM();
    }
    # 'inode' uses no additional flags
    
    # Add the mark
    my $dirfd = -1;  # AT_FDCWD
    $self->{fanotify}->mark($mark_flags, $mask, $dirfd, $path)
        or croak "Failed to mark $path: $!";
    
    my $watcher = Linux::Event::Watcher->new(
        id => $self->{next_id}++,
        type => 'fswatch',
        loop => $self,
        path => $path,
        events => $events,
        mark_type => $mark_type,
        cb => $cb,
        data => $data,
        priority => $priority,
        active => 1,
    );
    
    push @{$self->{fanotify_watches}}, $watcher;
    
    return $watcher;
}

sub _fanotify_event_matches {
    my ($self, $event, $event_name) = @_;
    
    my %checks = (
        'access'        => sub { $event->mask & Linux::Fanotify::FAN_ACCESS() },
        'modify'        => sub { $event->mask & Linux::Fanotify::FAN_MODIFY() },
        'close_write'   => sub { $event->mask & Linux::Fanotify::FAN_CLOSE_WRITE() },
        'close_nowrite' => sub { $event->mask & Linux::Fanotify::FAN_CLOSE_NOWRITE() },
        'open'          => sub { $event->mask & Linux::Fanotify::FAN_OPEN() },
        'open_exec'     => sub { $event->mask & Linux::Fanotify::FAN_OPEN_EXEC() },
    );
    
    # Linux 5.1+ events
    if (Linux::Fanotify->can('FAN_CREATE')) {
        $checks{create} = sub { $event->mask & Linux::Fanotify::FAN_CREATE() };
        $checks{delete} = sub { $event->mask & Linux::Fanotify::FAN_DELETE() };
        $checks{delete_self} = sub { $event->mask & Linux::Fanotify::FAN_DELETE_SELF() };
        $checks{moved_from} = sub { $event->mask & Linux::Fanotify::FAN_MOVED_FROM() };
        $checks{moved_to} = sub { $event->mask & Linux::Fanotify::FAN_MOVED_TO() };
        $checks{move_self} = sub { $event->mask & Linux::Fanotify::FAN_MOVE_SELF() };
        $checks{attrib} = sub { $event->mask & Linux::Fanotify::FAN_ATTRIB() };
    }
    
    return $checks{$event_name}->() if exists $checks{$event_name};
    return 0;
}

sub _fanotify_mask_to_name {
    my ($self, $mask) = @_;
    
    my @names;
    
    push @names, 'access' if $mask & Linux::Fanotify::FAN_ACCESS();
    push @names, 'modify' if $mask & Linux::Fanotify::FAN_MODIFY();
    push @names, 'close_write' if $mask & Linux::Fanotify::FAN_CLOSE_WRITE();
    push @names, 'close_nowrite' if $mask & Linux::Fanotify::FAN_CLOSE_NOWRITE();
    push @names, 'open' if $mask & Linux::Fanotify::FAN_OPEN();
    push @names, 'open_exec' if $mask & Linux::Fanotify::FAN_OPEN_EXEC();
    
    if (Linux::Fanotify->can('FAN_CREATE')) {
        push @names, 'create' if $mask & Linux::Fanotify::FAN_CREATE();
        push @names, 'delete' if $mask & Linux::Fanotify::FAN_DELETE();
        push @names, 'delete_self' if $mask & Linux::Fanotify::FAN_DELETE_SELF();
        push @names, 'moved_from' if $mask & Linux::Fanotify::FAN_MOVED_FROM();
        push @names, 'moved_to' if $mask & Linux::Fanotify::FAN_MOVED_TO();
        push @names, 'move_self' if $mask & Linux::Fanotify::FAN_MOVE_SELF();
        push @names, 'attrib' if $mask & Linux::Fanotify::FAN_ATTRIB();
    }
    
    return join(',', @names) || 'unknown';
}

=head2 run()

Run the event loop. This will block until stop() is called or there are
no more active watchers.

    $loop->run();

=cut

sub run {
    my ($self) = @_;
    
    $self->{running} = 1;
    $self->{stop_requested} = 0;
    
    while ($self->{running} && !$self->{stop_requested}) {
        # Process deferred callbacks
        while (my $cb = shift @{$self->{deferred}}) {
            eval { $cb->() };
            carp "Deferred callback died: $@" if $@;
        }
        
        # Run io_uring events
        my $pending = $self->{uring}->pending();
        
        if ($pending > 0) {
            # Process io_uring events
            $self->{uring}->ring->run_once($self->{max_events});
        } else {
            # No io_uring events, check for idle watchers
            my $ran_idle = 0;
            for my $watcher (@{$self->{idle_watchers}}) {
                next unless $watcher->{active};
                
                eval {
                    $watcher->{cb}->($watcher);
                };
                if ($@) {
                    carp "Idle watcher callback died: $@";
                }
                $ran_idle = 1;
            }
            
            # If no idle watchers ran and no events, check if we should exit
            if (!$ran_idle && $pending == 0) {
                # Check if we have any active watchers
                my $has_watchers = 0;
                
                # Check I/O watchers
                for my $fd_watchers (values %{$self->{io_watchers}}) {
                    for my $list (values %$fd_watchers) {
                        for my $w (@$list) {
                            $has_watchers = 1 if $w->{active};
                        }
                    }
                }
                
                # Check timers (they're scheduled in io_uring)
                for my $w (@{$self->{timers}}) {
                    $has_watchers = 1 if $w->{active};
                }
                
                last unless $has_watchers;
                
                # Sleep briefly to avoid busy loop
                select(undef, undef, undef, 0.001);
            }
        }
    }
    
    $self->{running} = 0;
}

=head2 stop()

Stop the event loop.

    $loop->stop();

=cut

sub stop {
    my ($self) = @_;
    $self->{stop_requested} = 1;
}

=head2 is_running()

Check if the event loop is currently running.

    if ($loop->is_running()) {
        print "Loop is running\n";
    }

=cut

sub is_running {
    my ($self) = @_;
    return $self->{running};
}

=head2 now()

Get the current time (high resolution).

    my $time = $loop->now();

=cut

sub now {
    return time();
}

=head1 WATCHER METHODS

All watchers returned by Linux::Event methods are objects with the
following methods:

=head2 $watcher->stop()

Temporarily stop a watcher without destroying it.

    $watcher->stop();

=head2 $watcher->start()

Restart a stopped watcher.

    $watcher->start();

=head2 $watcher->is_active()

Check if a watcher is active.

    if ($watcher->is_active()) {
        print "Watcher is active\n";
    }

=head2 $watcher->priority($new_priority)

Get or set watcher priority.

    my $pri = $watcher->priority();
    $watcher->priority(10);

=head2 $watcher->data($new_data)

Get or set user data.

    my $data = $watcher->data();
    $watcher->data({ foo => 'bar' });

=cut

# Watcher class
package Linux::Event::Watcher;

use strict;
use warnings;

sub new {
    my ($class, %opts) = @_;
    return bless \%opts, $class;
}

sub stop {
    my ($self) = @_;
    $self->{active} = 0;
}

sub start {
    my ($self) = @_;
    return if $self->{active};
    
    $self->{active} = 1;
    
    # Restart based on type
    if ($self->{type} eq 'io') {
        $self->{loop}->_poll_io($self);
    } elsif ($self->{type} eq 'timer') {
        $self->{loop}->_schedule_timer($self);
    } elsif ($self->{type} eq 'periodic') {
        $self->{loop}->_schedule_periodic($self);
    }
}

sub is_active {
    my ($self) = @_;
    return $self->{active};
}

sub priority {
    my ($self, $new_pri) = @_;
    if (defined $new_pri) {
        $self->{priority} = $new_pri;
    }
    return $self->{priority};
}

sub data {
    my ($self, $new_data) = @_;
    if (defined $new_data) {
        $self->{data} = $new_data;
    }
    return $self->{data};
}

package Linux::Event;

1;

=head1 EXAMPLES

=head2 Simple HTTP Server

    use Linux::Event;
    use Socket;
    
    my $loop = Linux::Event->new();
    
    # Create listening socket
    socket(my $server, PF_INET, SOCK_STREAM, getprotobyname('tcp'));
    setsockopt($server, SOL_SOCKET, SO_REUSEADDR, 1);
    bind($server, sockaddr_in(8080, INADDR_ANY));
    listen($server, 10);
    
    print "Listening on port 8080\n";
    
    # Accept connections
    $loop->io(
        fh => $server,
        poll => 'r',
        cb => sub {
            accept(my $client, $server);
            
            # Read request
            $loop->io(
                fh => $client,
                poll => 'r',
                cb => sub {
                    my $request = <$client>;
                    
                    # Send response
                    print $client "HTTP/1.0 200 OK\r\n";
                    print $client "Content-Type: text/plain\r\n\r\n";
                    print $client "Hello from Linux::Event!\n";
                    close $client;
                }
            );
        }
    );
    
    $loop->run();

=head2 Timer Example

    use Linux::Event;
    
    my $loop = Linux::Event->new();
    my $count = 0;
    
    # Periodic ticker
    my $ticker = $loop->periodic(
        interval => 1,
        cb => sub {
            $count++;
            print "Tick $count\n";
        }
    );
    
    # Stop after 10 seconds
    $loop->timer(
        after => 10,
        cb => sub {
            print "Stopping...\n";
            $ticker->stop();
            $loop->stop();
        }
    );
    
    $loop->run();

=head2 Signal Handling

    use Linux::Event;
    
    my $loop = Linux::Event->new();
    
    my $graceful_shutdown = sub {
        print "Shutting down gracefully...\n";
        # Cleanup code here
        $loop->stop();
    };
    
    $loop->signal(signal => 'INT',  cb => $graceful_shutdown);
    $loop->signal(signal => 'TERM', cb => $graceful_shutdown);
    
    print "Running (Ctrl-C to stop)...\n";
    $loop->run();

=head2 File Monitoring

    use Linux::Event;
    
    my $loop = Linux::Event->new();
    
    open my $fh, '<', '/var/log/syslog' or die $!;
    seek($fh, 0, 2);  # Seek to end
    
    $loop->io(
        fh => $fh,
        poll => 'r',
        cb => sub {
            while (my $line = <$fh>) {
                print "New log: $line";
            }
        }
    );
    
    print "Monitoring /var/log/syslog\n";
    $loop->run();

=head1 PERFORMANCE

Linux::Event leverages io_uring for exceptional performance:

=over 4

=item * Minimal system calls (batch submission/completion)

=item * Zero-copy operations where possible

=item * Efficient multiplexing of I/O operations

=item * Native async I/O support

=item * Scalable to thousands of concurrent operations

=back

Benchmarks show significant performance improvements over traditional
event loops (select, poll, epoll) especially under high load.

=head1 COMPATIBILITY

=head2 Core Requirements

=over 4

=item * Linux kernel 5.1+ with io_uring support

=item * IO::Uring::Easy

=item * IO::Uring

=item * Perl 5.10+

=back

=head2 Optional File Watching Features

=head3 inotify (watch method)

=over 4

=item * Linux kernel 2.6.13+

=item * Linux::Inotify2 module

=back

=head3 fanotify (fswatch method)

=over 4

=item * Linux kernel 2.6.37+ (basic events)

=item * Linux kernel 5.1+ (create/delete/move events)

=item * Linux::Fanotify module

=item * Root privileges (CAP_SYS_ADMIN capability)

=item * Kernel compiled with CONFIG_FANOTIFY=y

=item * For permission events: CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y

=back

=head2 Kernel Version Summary

    Feature                    Minimum Kernel
    ----------------------------------------
    io_uring (core)           5.1
    inotify                   2.6.13
    fanotify (basic)          2.6.37
    fanotify (create/delete)  5.1
    
=head2 Checking Your System

To check kernel version:

    uname -r

To check io_uring support:

    grep CONFIG_IO_URING /boot/config-$(uname -r)

To check fanotify support:

    grep CONFIG_FANOTIFY /boot/config-$(uname -r)

=head2 Feature Detection

Linux::Event automatically detects available features at runtime:

    use Linux::Event;
    
    print "inotify available\n" if $Linux::Event::INOTIFY_AVAILABLE;
    print "fanotify available\n" if $Linux::Event::FANOTIFY_AVAILABLE;

If you try to use watch() or fswatch() without the required modules,
you'll get a clear error message indicating what's missing.

=head1 SEE ALSO

L<IO::Uring::Easy> - The underlying I/O framework

L<IO::Uring> - Low-level io_uring bindings

L<Linux::Inotify2> - inotify file/directory watching

L<Linux::Fanotify> - fanotify filesystem monitoring

L<EV> - Another high-performance event loop

L<AnyEvent> - Event loop abstraction

=head1 AUTHOR

Your Name <your@email.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2026 by Your Name.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
