# Linux::Event Architecture & Design

## Overview

Linux::Event is a high-performance event framework built on top of IO::Uring::Easy, which itself wraps IO::Uring. This layered architecture provides both high performance and ease of use.

## Architecture Layers

```
┌─────────────────────────────────────────────────────┐
│              Application Code                        │
│  (Your servers, scripts, applications)              │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│              Linux::Event                            │
│  • Event loop management                            │
│  • Watcher abstraction (I/O, timers, signals)       │
│  • Callback dispatch                                │
│  • Resource lifecycle management                    │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│           IO::Uring::Easy                            │
│  • Named parameter API                              │
│  • Success/error callback split                     │
│  • Automatic buffer management                      │
│  • High-level operations (read_file, write_file)    │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│              IO::Uring                               │
│  • Low-level io_uring bindings                      │
│  • Direct kernel interface                          │
│  • Zero-copy operations                             │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│        Linux Kernel (io_uring subsystem)            │
│  • Async I/O operations                             │
│  • Submission/completion queues                     │
│  • Kernel-side polling (sqpoll)                     │
└─────────────────────────────────────────────────────┘
```

## Core Components

### 1. Event Loop (`Linux::Event`)

The main event loop object that manages all event sources and dispatches callbacks.

**Responsibilities:**
- Create and manage watchers
- Run the event loop
- Process deferred callbacks
- Coordinate with io_uring
- Handle idle processing

**Key Methods:**
- `new()` - Create event loop
- `run()` - Execute event loop
- `stop()` - Halt execution
- `defer()` - Queue callbacks

### 2. Watcher System (`Linux::Event::Watcher`)

Watchers are objects that monitor specific event sources.

**Watcher Types:**

```
Watcher (base)
├── I/O Watcher      - File descriptor events
├── Timer            - One-shot delayed callback
├── Periodic         - Repeated callback
├── Signal           - Unix signal handling
└── Idle             - Run when loop is idle
```

**Watcher Lifecycle:**
```
Create → Active → Stopped → Destroyed
   ↓       ↓        ↓
   └───────┴────────┴──→ Callbacks fired when active
```

**Methods:**
- `start()` - Activate watcher
- `stop()` - Pause watcher
- `is_active()` - Check state
- `destroy()` - Remove and cleanup

### 3. I/O Watcher Implementation

I/O watchers use io_uring's multishot poll feature for continuous monitoring:

```perl
# User creates watcher
$loop->io(fh => $sock, poll => 'r', cb => sub { ... });

# Internally:
# 1. Register with io_uring poll_multishot
# 2. Store callback reference
# 3. On readiness: invoke callback
# 4. Multishot continues until stopped
```

**Flow:**
```
User registers I/O watcher
        ↓
Linux::Event calls IO::Uring::Easy
        ↓
io_uring poll_multishot registered
        ↓
Kernel monitors file descriptor
        ↓
Data available → completion event
        ↓
Callback invoked with event details
        ↓
Multishot continues (if active)
```

### 4. Timer System

Timers use io_uring's timeout operations:

**One-shot Timer:**
```
Create timer(after => 5)
        ↓
Schedule io_uring timeout
        ↓
Kernel tracks timeout
        ↓
Timeout expires
        ↓
Callback fired
        ↓
Watcher becomes inactive
```

**Periodic Timer:**
```
Create periodic(interval => 1)
        ↓
Schedule io_uring timeout
        ↓
Timeout expires
        ↓
Callback fired
        ↓
Reschedule timeout (if active)
        ↓
Loop back to timeout expires
```

### 5. Signal Handling

Signals use Perl's `%SIG` hash with coordination:

```
User registers signal handler
        ↓
Linux::Event installs %SIG handler
        ↓
Signal delivered to process
        ↓
Perl invokes %SIG handler
        ↓
Handler looks up watchers for signal
        ↓
Invoke all matching watcher callbacks
```

**Multiple Handlers:**
```perl
# Both handlers fire on SIGINT
$loop->signal(signal => 'INT', cb => sub { ... });
$loop->signal(signal => 'INT', cb => sub { ... });
```

### 6. Deferred Execution

Deferred callbacks run in the next event loop iteration:

```
User calls defer(sub { ... })
        ↓
Callback added to deferred queue
        ↓
Event loop iteration starts
        ↓
Process all deferred callbacks
        ↓
Continue with I/O, timers, etc.
```

## Event Loop Execution Flow

```
┌─────────────────────────────────────┐
│ run() called                         │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│ running = true                       │
└─────────────────────────────────────┘
              ↓
        ╔═════════════════════════╗
        ║   Main Event Loop       ║
        ╚═════════════════════════╝
              ↓
┌─────────────────────────────────────┐
│ Process deferred callbacks           │
│ (FIFO order)                        │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│ Check for work:                     │
│ - Pending I/O operations?           │
│ - Active watchers?                  │
│ - Deferred callbacks?               │
└─────────────────────────────────────┘
              ↓
         Has work? ─No──→ Exit loop
              ↓ Yes
┌─────────────────────────────────────┐
│ Pending I/O? ──Yes──→ run_once()    │
│      ↓ No                           │
│ Run idle callbacks                  │
│ Small sleep (prevent busy loop)     │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│ Check running flag                  │
└─────────────────────────────────────┘
              ↓
         Still running? ──Yes──→ Loop back
              ↓ No
┌─────────────────────────────────────┐
│ running = false                      │
│ Return to caller                    │
└─────────────────────────────────────┘
```

## Memory Management

### Watcher Storage

```perl
$loop->{watchers} = {
    1 => $io_watcher,
    2 => $timer_watcher,
    3 => $signal_watcher,
    ...
};

$loop->{io_watchers} = {
    3 => $io_watcher,  # Indexed by fileno
    ...
};

$loop->{signals} = {
    2 => [$sig_watcher1, $sig_watcher2],  # Indexed by signum
    ...
};
```

### Callback References

Callbacks are stored in watcher objects, keeping them alive:

```perl
# User callback
my $cb = sub { ... };

# Stored in watcher
$watcher->{cb} = $cb;

# Watcher stored in loop
$loop->{watchers}{$id} = $watcher;

# All kept alive until watcher destroyed
```

### Cleanup on Destroy

```perl
$watcher->destroy();
    ↓
1. Set active = 0
2. Remove from $loop->{watchers}
3. Remove from type-specific indexes
4. Callback reference dropped
5. Memory freed (when no more refs)
```

## Performance Characteristics

### io_uring Advantages

1. **Batch Operations**
   - Multiple I/O operations submitted together
   - One syscall for multiple operations
   - Reduced kernel/userspace transitions

2. **Zero-Copy**
   - Data moved by kernel DMA
   - No CPU involvement for transfers
   - Lower CPU usage

3. **Kernel Polling (sqpoll)**
   - Kernel thread polls for I/O
   - No syscalls needed for polling
   - Lowest possible latency

### Overhead Analysis

```
Traditional epoll approach:
    User code
    ↓ (syscall)
    Kernel: epoll_wait()
    ↓ (return)
    User code: process events
    ↓ (syscall for each operation)
    Kernel: read()/write()
    ↓ (return)
    User code

io_uring approach:
    User code
    ↓ (submit batch)
    Kernel: io_uring processes all
    ↓ (completions ready)
    User code: process completions
```

**Syscall Reduction:**
- epoll: ~3-5 syscalls per I/O operation
- io_uring: ~0.5 syscalls per I/O operation (with batching)

## Error Handling Strategy

### Error Propagation

```
Kernel error
    ↓
io_uring completion with error code
    ↓
IO::Uring error handling
    ↓
IO::Uring::Easy on_error callback
    ↓
Linux::Event callback with error
    ↓
User code handles error
```

### Error Types

1. **I/O Errors** - File not found, permission denied
2. **System Errors** - Out of memory, too many files open
3. **Application Errors** - Invalid watcher state

### Recovery Strategy

```perl
# Automatic cleanup on errors
$loop->read_file(
    path => $file,
    cb => sub {
        my ($data, $error) = @_;
        if ($error) {
            # Resources automatically cleaned up
            # User handles error
            warn "Error: $error\n";
        }
    }
);
```

## Threading Model

Linux::Event is **NOT thread-safe**. Design principles:

1. **One Loop Per Thread**
   ```perl
   # Each thread creates its own loop
   use threads;
   threads->create(sub {
       my $loop = Linux::Event->new();
       $loop->run();
   });
   ```

2. **No Shared State**
   - Each loop has independent watcher storage
   - No shared io_uring queues
   - Callbacks execute in creating thread

3. **Signal Handling**
   - Signals delivered to specific thread
   - Only that thread's loop handles them

## Extension Points

### Adding New Watcher Types

1. Create watcher in `Linux::Event::Watcher`
2. Add creation method in `Linux::Event`
3. Implement activation logic
4. Add to watcher storage
5. Handle in event loop

### Custom I/O Operations

```perl
# Access underlying io_uring
my $ring = $loop->{uring}->ring();

# Use low-level operations
$ring->splice(...);
$ring->sendmsg(...);
```

## Future Enhancements

Planned features:

1. **Child Process Watchers**
   - Monitor process exit using waitid
   
2. **Filesystem Watchers**
   - inotify integration
   
3. **Better Signal Handling**
   - signalfd integration
   
4. **Buffer Pools**
   - Reduce memory allocation overhead
   
5. **Async DNS**
   - Non-blocking name resolution

## Best Practices

### 1. Watcher Lifecycle

```perl
# Good: Store watchers you need to control
my $w = $loop->io(...);
# Later...
$w->stop();

# Bad: Watcher lost, can't control
$loop->io(...);
```

### 2. Error Handling

```perl
# Good: Handle all errors
$loop->read_file(
    path => $file,
    cb => sub {
        my ($data, $error) = @_;
        return warn $error if $error;
        process($data);
    }
);

# Bad: Ignore errors
$loop->read_file(
    path => $file,
    cb => sub {
        my ($data) = @_;
        process($data);  # May be undef!
    }
);
```

### 3. Cleanup

```perl
# Good: Clean shutdown
$loop->signal(signal => 'INT', cb => sub {
    cleanup_resources();
    $loop->stop();
});

# Bad: Abrupt exit
$loop->signal(signal => 'INT', cb => sub {
    exit(0);  # Resources leaked!
});
```

## Debugging

### Enable Tracing

```perl
# Add debug wrapper
my $orig_run = \&Linux::Event::run;
*Linux::Event::run = sub {
    my $self = shift;
    warn "Event loop starting\n";
    $orig_run->($self, @_);
    warn "Event loop stopped\n";
};
```

### Monitor Watchers

```perl
# Periodic watcher count
$loop->periodic(interval => 5, cb => sub {
    my $count = scalar keys %{$loop->{watchers}};
    warn "Active watchers: $count\n";
});
```

### Trace Callbacks

```perl
# Wrap all callbacks
sub traced_callback {
    my $name = shift;
    my $cb = shift;
    return sub {
        warn "Callback $name firing\n";
        $cb->(@_);
        warn "Callback $name complete\n";
    };
}

$loop->timer(
    after => 1,
    cb => traced_callback('timer1', sub { ... })
);
```
