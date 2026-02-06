# Linux::Event Quick Reference

## Basic Setup

```perl
use Linux::Event;
my $loop = Linux::Event->new();
```

## I/O Watchers

### Monitor file descriptor for reading
```perl
my $w = $loop->io(
    fh => $socket,
    poll => 'r',    # 'r', 'w', or 'rw'
    cb => sub {
        my ($watcher, $revents) = @_;
        my $data = <$socket>;
        print "Read: $data\n";
    }
);
```

### Control watcher
```perl
$w->stop();      # Pause
$w->start();     # Resume
$w->is_active(); # Check status
$w->destroy();   # Remove completely
```

## Timers

### One-shot timer
```perl
$loop->timer(
    after => 5,     # seconds (can be fractional)
    cb => sub {
        print "5 seconds elapsed\n";
    }
);
```

### Periodic timer
```perl
$loop->periodic(
    interval => 1,  # fire every second
    cb => sub {
        my ($watcher) = @_;
        print "Tick\n";
    }
);
```

## Signal Handlers

```perl
$loop->signal(
    signal => 'INT',  # or 'TERM', 'USR1', etc.
    cb => sub {
        my ($watcher, $signum) = @_;
        print "Caught signal $signum\n";
        $loop->stop();
    }
);
```

## Idle Callbacks

```perl
$loop->idle(
    cb => sub {
        print "Event loop is idle\n";
    }
);
```

## Deferred Execution

```perl
# Runs in next event loop iteration
$loop->defer(sub {
    print "Deferred\n";
});
```

## File Operations

### Read file
```perl
$loop->read_file(
    path => '/etc/hosts',
    cb => sub {
        my ($data, $error) = @_;
        if ($error) {
            warn "Error: $error\n";
        } else {
            print $data;
        }
    }
);
```

### Write file
```perl
$loop->write_file(
    path => '/tmp/output.txt',
    data => "Hello, world!",
    cb => sub {
        my ($error) = @_;
        warn "Error: $error\n" if $error;
    }
);
```

## Event Loop Control

### Run the loop
```perl
$loop->run();
```

### Stop the loop
```perl
$loop->stop();
```

### Check if running
```perl
if ($loop->is_running()) {
    print "Loop is active\n";
}
```

## Common Patterns

### TCP Echo Server
```perl
use Socket;

socket(my $server, PF_INET, SOCK_STREAM, getprotobyname('tcp'));
setsockopt($server, SOL_SOCKET, SO_REUSEADDR, 1);
bind($server, sockaddr_in(8080, INADDR_ANY));
listen($server, 5);

$loop->io(
    fh => $server,
    poll => 'r',
    cb => sub {
        my $client = accept($server, my $addr);
        
        $loop->io(
            fh => $client,
            poll => 'r',
            cb => sub {
                my $line = <$client>;
                print $client "ECHO: $line";
                close($client);
            }
        );
    }
);

$loop->run();
```

### Heartbeat
```perl
my $count = 0;
$loop->periodic(
    interval => 1,
    cb => sub {
        my ($w) = @_;
        print "Heartbeat ", ++$count, "\n";
        $w->destroy() if $count >= 10;
    }
);
```

### File Processing Pipeline
```perl
$loop->read_file(
    path => 'input.txt',
    cb => sub {
        my ($data, $error) = @_;
        return if $error;
        
        # Process
        my $processed = uc($data);
        
        $loop->write_file(
            path => 'output.txt',
            data => $processed,
            cb => sub {
                print "Done!\n";
            }
        );
    }
);
```

### Graceful Shutdown
```perl
$loop->signal(
    signal => 'INT',
    cb => sub {
        print "Shutting down...\n";
        # Cleanup
        $loop->stop();
    }
);

$loop->periodic(
    interval => 1,
    cb => sub { print "Working...\n" }
);

$loop->run();
```

### Timeout for Operation
```perl
my $done = 0;

# Start operation
$loop->read_file(
    path => '/dev/urandom',
    cb => sub { $done = 1; }
);

# Set timeout
$loop->timer(
    after => 5,
    cb => sub {
        print "Timeout!\n";
        $loop->stop();
    }
);

$loop->run();
```

### Multiple Files in Parallel
```perl
my @files = qw(/etc/hosts /etc/hostname /etc/os-release);
my $completed = 0;

for my $file (@files) {
    $loop->read_file(
        path => $file,
        cb => sub {
            my ($data, $error) = @_;
            $completed++;
            
            if ($error) {
                print "$file: ERROR\n";
            } else {
                print "$file: " . length($data) . " bytes\n";
            }
            
            $loop->stop() if $completed == @files;
        }
    );
}

$loop->run();
```

### Periodic Cleanup with Cancellation
```perl
my $cleanup_watcher = $loop->periodic(
    interval => 60,
    cb => sub {
        print "Running cleanup...\n";
        # Cleanup code
    }
);

$loop->signal(
    signal => 'INT',
    cb => sub {
        $cleanup_watcher->destroy();
        $loop->stop();
    }
);
```

## Tips & Best Practices

### 1. Always handle errors
```perl
$loop->read_file(
    path => $file,
    cb => sub {
        my ($data, $error) = @_;
        return warn $error if $error;
        # Process data
    }
);
```

### 2. Store watchers you need to control
```perl
my $w = $loop->timer(...);
# Later...
$w->stop();
```

### 3. Clean up on shutdown
```perl
$loop->signal(signal => 'INT', cb => sub {
    # Close files, sockets, etc.
    $loop->stop();
});
```

### 4. Use defer for non-blocking init
```perl
$loop->defer(sub {
    # Heavy initialization
});
```

### 5. Don't block in callbacks
```perl
# Bad
$loop->timer(after => 1, cb => sub {
    sleep(10);  # Blocks event loop!
});

# Good
$loop->timer(after => 1, cb => sub {
    $loop->timer(after => 10, cb => sub {
        # Deferred work
    });
});
```

## Watcher Types Summary

| Type | Method | Purpose |
|------|--------|---------|
| I/O | `io()` | Monitor file descriptors |
| Timer | `timer()` | One-shot delayed callback |
| Periodic | `periodic()` | Repeated callback |
| Signal | `signal()` | Handle Unix signals |
| Idle | `idle()` | Run when loop is idle |
| Defer | `defer()` | Next iteration callback |

## Event Loop Lifecycle

```
new() → add watchers → run() → process events → stop() → cleanup
         ↑                         |
         └─────────────────────────┘
               (continuous)
```

## Common Issues

### Loop exits immediately
- No active watchers
- Check if watchers are properly created
- Use `$loop->is_running()` to debug

### High CPU usage
- Too many idle callbacks
- Add small delays in periodic timers
- Check for busy-wait patterns

### Signals not working
- Signal may be blocked
- Check `$SIG{...}` for conflicts
- Use `defer()` to send signals

### File operations fail
- Check file permissions
- Verify paths exist
- Handle errors in callbacks

## Performance Tips

1. **Batch file operations** - Queue multiple reads/writes
2. **Reuse watchers** - Stop/start instead of destroy/create
3. **Avoid idle callbacks** - Use timers instead when possible
4. **Use appropriate queue_size** - Larger for high throughput
5. **Profile your code** - Find actual bottlenecks

## Debug Helpers

```perl
# Check pending I/O operations
warn "Pending: " . $loop->{uring}->pending();

# Count active watchers
warn "Watchers: " . scalar keys %{$loop->{watchers}};

# Log event loop iterations
my $iter = 0;
$loop->defer(sub {
    warn "Iteration " . ++$iter;
    $loop->defer(\&__SUB__) if $loop->is_running();
});
```
