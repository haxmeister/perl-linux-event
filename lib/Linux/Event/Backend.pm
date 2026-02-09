package Linux::Event::Backend;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001_001';

1;

__END__

=head1 NAME

Linux::Event::Backend - Backend contract for Linux::Event::Loop

=head1 DESCRIPTION

This module documents the minimal backend interface expected by
L<Linux::Event::Loop>. Backends are intentionally duck-typed.

The loop owns scheduling policy (clock/timer/scheduler). The backend owns the
wait/dispatch mechanism (epoll now, io_uring later).

=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

The API is not yet considered stable and may change without notice.

=head1 REQUIRED METHODS

=head2 new(%args)

Create the backend instance.

=head2 watch_fh($fh, $mask, $cb, %opt) -> $fd

Register a filehandle for readiness notifications.

Callback signature (standardized by this project):

  $cb->($loop, $fh, $fd, $mask, $tag);

=head2 unwatch_fh($fh_or_fd) -> $bool

Remove a watcher.

=head2 run_once($loop, $timeout_s=undef) -> $n

Block until events occur (or timeout) and dispatch them.

=cut
