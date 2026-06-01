# Linux::Event examples

These examples demonstrate the readiness-backend Linux::Event API.

## Basic loop examples

- `01-after.pl` - relative timer
- `02-at.pl` - absolute timer deadline
- `03-watch-pipe.pl` - readiness watch on a pipe
- `04-signal.pl` - signalfd signal delivery
- `05-waker-thread.pl` - eventfd wakeup from another thread
- `06-pid.pl` - pidfd child exit notification

## Compatibility and regression examples

The remaining examples exercise watcher replacement, oneshot rearming, safe
unwatch behavior, wakeups, pidfds, and epoll regression cases.
