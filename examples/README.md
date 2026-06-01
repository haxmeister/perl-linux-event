# Linux::Event examples

These examples demonstrate the reactor-only Linux::Event API.

## Basic loop examples

- `01-reactor-after.pl` - relative timer
- `02-reactor-at.pl` - absolute timer deadline
- `03-reactor-watch-pipe.pl` - readiness watch on a pipe
- `04-reactor-signal.pl` - signalfd signal delivery
- `05-reactor-waker-thread.pl` - eventfd wakeup from another thread
- `06-reactor-pid.pl` - pidfd child exit notification

## Compatibility and regression examples

The remaining examples exercise watcher replacement, oneshot rearming, safe
unwatch behavior, wakeups, pidfds, and epoll regression cases.
