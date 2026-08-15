# Native architecture

## Hot path

The current steady-state readiness path is intentionally short:

```text
epoll_wait()
   |
   v
epoll_event.data.ptr
   |
   v
le_watcher_t *
   |
   v
XS dispatch
   |
   v
one Perl callback
```

There is no fd-to-Perl-hash lookup in the hot dispatch path. The fd-indexed
native registry remains for registration, replacement, cancellation, and
lifetime management.

## Native loop state

`le_loop_t` owns:

- epoll fd
- reusable `struct epoll_event` array
- fd-indexed `le_watcher_t **` registry
- stop state
- callback-scope policy
- watcher lifecycle lists used by optional reclaim diagnostics
- cheap counters and optional timing buckets

The default event array capacity is 8192.

Normal application registration uses `watch(fh => ...)` or `watch(fd => ...)`.
That Perl-facing method resolves a handle to its integer fd once at construction
and then enters the existing native registration path. It adds nothing to
steady-state readiness dispatch. `watch_fd` remains the low-level positional
entry point underneath it.

## Native watcher state

`le_watcher_t` contains the fd, epoll mask/flags, owning loop pointer, callback
SV/CV references, optional accessor references, callback-mode flags, and
benchmark/lifecycle state.

`epoll_event.data.ptr` points directly at this structure, which avoids a
registry lookup after `epoll_wait()` returns.

## Callback representation

When a callback is a plain coderef the XS layer stores the CV directly rather
than retaining an extra RV wrapper. The fast path can therefore call the CV
with minimal Perl-side construction.

Normal callbacks receive the watcher handle. A no-argument mode exists for hot
closures that capture their own state.

## Temporary scopes

The dispatcher shares an `ENTER`/`SAVETMPS` scope across a bounded group of
callbacks while still running `FREETMPS` after each callback. The default scope
limit is 128 callbacks, selected from benchmark sweeps as a stable balance.

## Terminal-event semantics

For an event containing terminal flags and normal readiness, dispatch order is:

```text
EPOLLERR / EPOLLHUP / EPOLLRDHUP
EPOLLIN
EPOLLOUT
```

The watcher is re-checked after each callback so cancellation takes effect
within the same returned epoll batch.

## Watcher lifetime

The loop owns native watcher records. `cancel`/`unwatch_fd` removes the epoll
registration and marks the watcher inactive. Experimental reclamation can defer
reuse until a returned epoll batch has finished, avoiding reuse while an event
array may still contain the old `data.ptr`.

The performance default keeps aggressive reclaim disabled because the memory
savings measured in earlier experiments came with a throughput cost.

## Profiling

Cheap counters remain enabled. Nanosecond timing of epoll/callback/dispatch
regions is opt-in because instrumentation itself changes the workload.

## Benchmark-only native echo

The XS source still contains a private native echo diagnostic used to decompose
callback entry from Perl `sysread`/buffer/`syswrite` work. It is deliberately
prefixed `_bench_` and is not an application API. Its result is what motivated
the next Stream work: the larger remaining cost is above the reactor.

## Stream class descriptors

The higher-level Stream extension has a separate native state model. The first
construction of a concrete `Linux::Event::Stream` subclass creates one immutable
XS descriptor containing resolved named callbacks, read size, output
watermarks, framed-buffer limit, and native parser configuration.

Every connection's XS state retains that descriptor and owns only mutable fd,
input/parser, output-queue, lifecycle, and counter state. A framed connection
therefore does not copy callbacks, delimiters, prefix policy, or transport
settings into every allocation.

Raw input drains into a reusable native read buffer and crosses into Perl for
`on_data`. Framed input drains directly into native connection storage, runs
the built-in parser there, and crosses into Perl only for complete
`on_message` values or semantic errors. Both paths recheck pause and close state
after callbacks.

The Stream extension does not include private reactor headers. XSLoop passes
watcher data directly to Stream's private readiness entry points, preserving a
generic readiness core and an independently testable buffered Stream layer.
