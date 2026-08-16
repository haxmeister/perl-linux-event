# Core Reactor Guide

This document describes the low-level Linux::Event XS reactor. Applications
that want owned buffered byte-stream I/O should use a
`Linux::Event::Stream` subclass on top of this layer.

## Mental model

Linux::Event separates **readiness** from **I/O policy**:

```text
kernel epoll
    |
    v
Linux::Event::Loop
    |
    v
native watcher
    |
    +-- error callback   EPOLLERR / EPOLLHUP / EPOLLRDHUP
    +-- read callback    EPOLLIN
    `-- write callback   EPOLLOUT
```

The core tells you *what can be attempted*. Your callback decides whether to
`sysread`, `syswrite`, accept a connection, drain a Linux fd, or perform another
operation appropriate to that descriptor.

## Constructing a loop

```perl
use Linux::Event::Loop;
my $loop = Linux::Event::Loop->new;
```

Each loop owns one epoll instance, an event buffer, a native fd-indexed watcher
registry, and its attached Watchers. High-level Watchers attach through
`$loop->add($watcher)`; `watch()` is the immediate-attachment convenience for
raw IO.

## Registering a handle

Normal application code should label the watched resource explicitly:

```perl
my $watcher = $loop->watch(
    fh    => $fh,
    data  => { connection_id => 42 },
    read  => sub ($watcher) { ... },
    write => sub ($watcher) { ... },
    error => sub ($watcher) { ... },
);
```

The returned object is a `Linux::Event::IO`, which is a
`Linux::Event::Watcher` with the native raw-descriptor methods.

When `fh` is supplied, Linux::Event resolves its integer file descriptor once at
watcher construction and retains the handle for `$watcher->fh`.

If an application has only a raw descriptor, use:

```perl
my $watcher = $loop->watch(
    fd   => $fd,
    read => sub ($watcher) { ... },
);
```

Exactly one of `fh` or `fd` is required. Every watcher always has an integer fd,
available through `$watcher->fd`. A watcher created from `fd` alone has no
stored filehandle, so `$watcher->fh` is `undef`.

The lower-level positional method remains available:

```perl
$loop->watch_fd($fd, read => sub ($watcher) { ... });
```

`watch_fd` is retained for low-level/internal code, compatibility, and unusual
workloads where watcher-registration throughput itself has been measured as a
bottleneck. Prefer `watch()` in normal application code. Both forms create the
same native watcher and have the same readiness-dispatch hot path.

Only the callbacks you need are required. Read interest is enabled when a read
callback exists; write interest is enabled when a write callback exists.
Terminal/error flags are always watched so the reactor can surface fd closure
and failure conditions.

Registering the same fd again replaces its existing registration.

## Callback order

For one returned epoll event the dispatch order is:

1. terminal/error callback
2. read callback
3. write callback

After each callback the reactor checks whether the watcher is still active.
This lets a callback cancel its own watcher safely before later readiness types
for the same event are considered.

## Reading until EAGAIN

A normal level-triggered read callback can drain the fd:

```perl
read => sub ($watcher) {
    my $fh = $watcher->fh;

    while (1) {
        my $buf = '';
        my $n = sysread($fh, $buf, 8192);

        if (!defined $n) {
            last if $!{EAGAIN} || $!{EWOULDBLOCK};
            $watcher->cancel;
            last;
        }

        if ($n == 0) {
            $watcher->cancel;
            last;
        }

        handle_bytes($buf);
    }
},
```

This repeated Perl socket/buffer work is intentionally visible in the raw
reactor API. A `Linux::Event::Stream` subclass moves the mechanical
read/write/buffering work into native code when that higher-level ownership
model is desired.

## Writable interest

Writable readiness should generally be enabled only when output is blocked:

```perl
$watcher->enable_write;
$watcher->disable_write;
```

Linux::Event::Stream subclasses manage these transitions in the native write
queue.
Applications using the core directly remain free to control them.

## Stopping and driving the loop

Persistent loop:

```perl
$loop->run;
```

Stop it from a callback:

```perl
$loop->stop;
```

Single iteration:

```perl
my $events = $loop->run_once(-1);   # block indefinitely
my $events = $loop->run_once(0);    # poll without blocking
my $events = $loop->run_once(50);   # wait at most 50 ms
```

Bounded execution:

```perl
$loop->run_for(0.250);
```

`run_for` uses a monotonic deadline.

## No-argument fast callbacks

When a closure already captures everything it needs, the watcher argument can
be omitted:

```perl
my $watcher = $loop->watch(
    fh      => $fh,
    read    => sub { drain_socket($fh) },
    no_args => 1,
    lean    => 1,
);
```

`lean` is available only with the no-argument path. It avoids retaining Perl
references used solely by watcher accessors. This is an expert performance
option; prefer the normal watcher callback until profiling demonstrates that
the extra reduction matters.

## One watcher per fd

The registry enforces one active watcher per integer fd. Re-registering an fd
replaces the old watcher. `unwatch_fd` and watcher `cancel` are safe when the
registration is already absent/inactive.

This model also prevents ambiguous dispatch when file-descriptor numbers are
reused by the operating system.

## Statistics

```perl
my $stats = $loop->stats;
$loop->reset_stats;
```

Counters cover epoll waits, ready-event classes, callback calls, epoll_ctl
operations, batching, watcher allocation/lifecycle, and loop drive methods.

Optional nanosecond profiling:

```perl
$loop->enable_profile(1);
# run workload
my $stats = $loop->stats;
$loop->enable_profile(0);
```

Profiling intentionally adds overhead. Do not enable it for ordinary throughput
comparisons.

## Tuning controls

The current measured defaults are:

- event capacity: 8192
- callback scope limit: 128
- watcher reclaim: disabled

The corresponding setters remain for controlled experiments, but are not part
of the recommended application configuration. Earlier experiments found that
more aggressive watcher reclamation reduced memory while costing throughput.

## Edge-triggered and oneshot modes

`watch()` accepts:

```perl
edge_triggered => 1
oneshot        => 1
```

Use these only when your application implements the required semantics. In
particular, edge-triggered readers must fully drain until EAGAIN. Oneshot
registrations require rearming before further events can be delivered.

## What the core intentionally does not do

The raw reactor does not own:

- input buffers
- output queues
- partial-write queues
- framing or codecs
- application backpressure policy
- protocol parsing

Those responsibilities belong to `Linux::Event::Stream` subclasses. Keeping
that separation gives Linux::Event both a low-level general reactor and a
high-level native stream-processing path.
