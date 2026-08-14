package Linux::Event::XSWatcher;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_008';

# XS methods are installed by Linux::Event::XSLoop's bootstrap.

1;

__END__

=head1 NAME

Linux::Event::XSWatcher - native watcher handle used by Linux::Event::XSLoop

=head1 DESCRIPTION

C<Linux::Event::XSWatcher> is returned by C<Linux::Event::XSLoop-E<gt>watch>. The low-level C<watch_fd> entry point returns the same watcher type.
The loop owns the underlying native watcher record; this Perl object is a handle
used by callbacks and application code.

=head1 METHODS

=head2 fd

Returns the watched integer file descriptor.

=head2 fh

Returns the stored Perl filehandle when the watcher retained one.

=head2 data

Returns the stored application data value when present.

=head2 loop

Returns the owning loop when the watcher retained the loop reference.

=head2 cancel

Removes this watcher from epoll if it is still the active watcher for its fd.
Calling C<cancel> on an already inactive watcher is harmless.

=head2 enable_read / disable_read

Changes C<EPOLLIN> interest in place.

=head2 enable_write / disable_write

Changes C<EPOLLOUT> interest in place. This is the primitive that a future
native write queue can use to enable writable notifications only while output
is blocked.

=head2 lean

Returns true for a lean no-argument watcher. Lean watchers intentionally omit
Perl accessor references to reduce hot-path memory/refcount work.

=cut
