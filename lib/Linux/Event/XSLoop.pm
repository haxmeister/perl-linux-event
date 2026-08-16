package Linux::Event::XSLoop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_019';

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

1;

__END__

=head1 NAME

Linux::Event::XSLoop - XS-first epoll reactor core for Linux::Event

=head1 SYNOPSIS

  use Linux::Event::XSLoop;

  my $loop = Linux::Event::XSLoop->new;

  my $watcher = $loop->watch(
      fh    => $fh,
      read  => sub ($watcher) {
          my $fh = $watcher->fh;
          # The callback owns the actual I/O at the reactor layer.
      },
      error => sub ($watcher) {
          $watcher->cancel;
      },
  );

  $loop->run;

=head1 DESCRIPTION

C<Linux::Event::XSLoop> is the current XS-first Linux reactor core. It owns the
epoll file descriptor, native watcher records, the epoll event buffer, watcher
registration, readiness dispatch, and the hot callback path.

The reactor deliberately reports readiness rather than performing socket I/O
for the application. Higher-level buffered stream behavior is implemented by
Linux::Event::Stream as a separate API layer so the core remains suitable for sockets, pipes, listeners,
signalfd/eventfd/pidfd integrations, and other Linux descriptors.

=head1 CORE API

=head2 new

  my $loop = Linux::Event::XSLoop->new;

Creates an epoll instance and the native loop state.

=head2 watch

  my $watcher = $loop->watch(
      fh    => $fh,
      data  => $data,
      read  => sub ($watcher) { ... },
      write => sub ($watcher) { ... },
      error => sub ($watcher) { ... },
  );

For a raw integer descriptor instead:

  my $watcher = $loop->watch(
      fd   => $fd,
      read => sub ($watcher) { ... },
  );

Exactly one of C<fh> or C<fd> is required. When C<fh> is supplied, its file
descriptor is resolved once during watcher construction and the handle is
retained for C<< $watcher-E<gt>fh >>. Every watcher always has an integer fd,
available through C<< $watcher-E<gt>fd >>. Registering a new watcher for an fd
replaces the previous watcher for that fd.

=head2 watch_fd

  my $watcher = $loop->watch_fd($fd, read => sub ($watcher) { ... });

Low-level positional-fd entry point used internally and retained for advanced
code, compatibility, and registration-rate-sensitive workloads. Normal
application code should prefer C<watch()> so the watched resource is explicitly
labeled with C<fh =E<gt>> or C<fd =E<gt>>. Both forms create the same native
watcher and use the same readiness-dispatch hot path.

C<read> is dispatched for C<EPOLLIN>. C<write> is dispatched for C<EPOLLOUT>.
C<error> is dispatched for C<EPOLLERR>, C<EPOLLHUP>, or C<EPOLLRDHUP>.
Terminal/error delivery occurs before read and write delivery for the same
epoll event.

For C<watch()> and C<watch_fd()>, optional low-level flags include C<oneshot> and C<edge_triggered>. The normal
callback receives one C<Linux::Event::XSWatcher>. For carefully profiled hot
paths, C<no_args =E<gt> 1> (or C<callback_args =E<gt> 0>) selects the no-argument
callback fast path. C<lean =E<gt> 1> is meaningful only with no-argument
callbacks and omits accessor references that such callbacks cannot use.

Options beginning with C<_bench_> are benchmark diagnostics and are not public
application APIs. The core also has a private C<_callback_data_arg> extension
hook used by higher-level XS-backed modules such as Linux::Event::Stream. It
causes a one-argument watcher callback to receive the stored C<data> object
directly instead of an C<XSWatcher> handle, avoiding a Perl C<< ->data >> lookup
on hot extension paths. It is intentionally not part of the application API.

=head2 unwatch_fd

  $loop->unwatch_fd($fd);

Removes the current watcher for the fd. Removing an fd that is not currently
watched is harmless.

=head2 run

  $loop->run;

Blocks in the native epoll loop until C<stop> is called.

=head2 run_once

  my $ready = $loop->run_once($timeout_ms);

Performs one epoll wait/dispatch cycle and returns the number of events returned
by epoll. The timeout is in milliseconds; C<-1> waits indefinitely.

=head2 run_for

  $loop->run_for($seconds);

Runs until the monotonic deadline expires or C<stop> is called. This method is
primarily useful for controlled execution and diagnostics; the persistent
C<run> method is the normal loop API.

=head2 stop

  $loop->stop;

Requests the active C<run> or C<run_for> loop to stop after the current dispatch
work reaches its stop check.

=head1 WATCHER API

A watcher supports:

  $watcher->fd;
  $watcher->fh;
  $watcher->data;
  $watcher->loop;
  $watcher->cancel;
  $watcher->enable_read;
  $watcher->disable_read;
  $watcher->enable_write;
  $watcher->disable_write;

Accessor methods return useful values only when the watcher was created with
the corresponding stored references. Lean no-argument watchers intentionally
do not retain those references.

=head1 PERFORMANCE AND DIAGNOSTICS

The default event buffer holds 8192 epoll events and the callback temporary
scope is rotated after 128 callbacks. These defaults were selected by measured
benchmarking and should normally be left alone.

  my $stats = $loop->stats;
  $loop->reset_stats;
  $loop->enable_profile(1);

C<stats> exposes epoll, callback, batching, watcher-lifecycle, and optional
nanosecond profiling counters. Profiling adds measurement overhead and should
be disabled for normal throughput benchmarks.

C<set_event_capacity>, C<set_callback_scope_limit>, and watcher-reclaim controls
remain available for regression investigation. They are tuning/diagnostic
interfaces, not recommendations for ordinary applications.

=head1 LIFETIME

The loop owns the native watcher records. Perl watcher objects are handles into
that loop-owned state; destroying a Perl watcher reference does not implicitly
remove the fd. Use C<cancel> or C<unwatch_fd> when the registration should end.
Destroying the loop releases its epoll fd, event storage, registry, and all
remaining watcher records.

=head1 PLATFORM

This implementation is intentionally Linux-only and requires epoll.

=head1 SEE ALSO

See F<README.md> and F<docs/CORE.md> for a guided introduction, and
F<docs/XS-ROADMAP.md> for the planned native higher-level work.

=cut
