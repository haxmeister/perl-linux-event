

# Linux::Event

A high-performance event framework for Linux built on io_uring via IO::Uring::Easy.

## Overview

Linux::Event provides a familiar, easy-to-use event loop API similar to EV, AnyEvent, and POE, but with the exceptional performance of io_uring. It's designed for building high-performance network servers, real-time systems, and async applications on Linux.

## Features

- ✅ **I/O Watchers** - Monitor file descriptors for read/write readiness
- ✅ **Timers** - One-shot and periodic timers with sub-millisecond precision
- ✅ **Signal Handlers** - Asynchronous signal handling
- ✅ **File Watching** - Monitor files/directories with inotify (Linux 2.6.13+)
- ✅ **Filesystem Monitoring** - Monitor entire filesystems with fanotify (Linux 5.1+)
- ✅ **Idle Callbacks** - Run code when event loop is idle
- ✅ **Deferred Execution** - Schedule callbacks for next iteration
- ✅ **Watcher Management** - Start, stop, modify watchers dynamically
- ✅ **Priority Support** - Control callback execution order
- ✅ **io_uring Backend** - Leverage Linux's fastest I/O interface
- ✅ **Clean API** - Simple, intuitive interface

## Quick Start

### Basic Event Loop

```perl
use Linux::Event;

my $loop = Linux::Event->new();

# One-shot timer
$loop->timer(
    after => 5,
    cb => sub {
        print "5 seconds elapsed!\n";
        $loop->stop();
    }
);

$loop->run();
```

### I/O Watcher Example

```perl
use Linux::Event;

my $loop = Linux::Event->new();

# Monitor a socket for incoming data
$loop->io(
    fh => $socket,
    poll => 'r',  # 'r' = read, 'w' = write, 'rw' = both
    cb => sub {
        my ($watcher, $revents) = @_;
        
        my $data = <$socket>;
        print "Received: $data\n";
        
        # Stop watching if needed
        $watcher->stop() if $done;
    }
);

$loop->run();
```

### File Watching Example (inotify)

```perl
# Monitor a directory for changes
$loop->watch(
    path => '/var/log',
    events => ['create', 'modify', 'delete'],
    cb => sub {
        my ($watcher, $event, $filename) = @_;
        print "$event: $filename\n";
    }
);

# Recursive monitoring
$loop->watch(
    path => '/home/user/documents',
    events => ['modify'],
    recursive => 1,
    cb => sub {
        my ($watcher, $event, $filename) = @_;
        print "File changed: $filename\n";
    }
);

$loop->run();
```

### Filesystem Monitoring Example (fanotify)

```perl
# Requires root privileges
# Monitor all file opens on a mount point
$loop->fswatch(
    path => '/home',
    events => ['open', 'close_write'],
    cb => sub {
        my ($watcher, $event, $path, $pid) = @_;
        print "PID $pid: $event on $path\n";
    }
);

$loop->run();
```

## Installation

```bash
cpanm Linux::Event
```

## Examples

See the [examples/](examples/) directory for complete working examples:
- **http_server.pl** - Full-featured HTTP server
- **echo_server.pl** - Multi-client TCP echo server  
- **timers.pl** - Timer and periodic timer examples
- **deferred_idle.pl** - Deferred and idle callback examples

## Documentation

Full API documentation is available in the module POD:

```bash
perldoc Linux::Event
```

## Requirements

### Core Requirements
- Linux kernel 5.1+ with io_uring support
- IO::Uring::Easy
- Perl 5.10+

### Optional Features
- **File watching (inotify)**: Linux::Inotify2, kernel 2.6.13+
- **Filesystem monitoring (fanotify)**: Linux::Fanotify, kernel 5.1+, root privileges

## Performance

Linux::Event leverages io_uring for exceptional performance with minimal syscalls, zero-copy operations where possible, and native async I/O support.

## See Also

- [IO::Uring::Easy](../IO-Uring-Easy/) - The underlying I/O framework
- [IO::Uring](https://metacpan.org/pod/IO::Uring) - Low-level io_uring bindings

## License

Same as Perl itself (Artistic License 2.0 or GPL 1+).
