package Linux::Event::Kernel::Process;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.111';

use parent 'Linux::Event::Process';

1;

__END__

=head1 NAME

Linux::Event::Kernel::Process - pidfd process lifecycle and asynchronous stdio

=head1 SYNOPSIS

  package Worker;
  use parent 'Linux::Event::Kernel::Process';

  sub on_stdout ($process, $bytes) {
      print $bytes;
  }

  sub on_exit ($process) {
      say 'exit code: ' . $process->exit_code
          if defined $process->exit_code;
      $process->loop->stop;
  }

  package main;
  my $worker = $loop->add(Worker->spawn(
      command => ['/usr/bin/example', '--once'],
      stdout  => 'pipe',
      stderr  => 'pipe',
  ));

=head1 DESCRIPTION

C<Linux::Event::Kernel::Process> is the public process leaf. One object combines
process creation or observation, pidfd identity-safe lifecycle notification,
optional asynchronous stdin/stdout/stderr, decoded exit status, and
pidfd-based signaling.

Linux::Event uses C<posix_spawnp> for spawned children and never runs Perl code
in a post-fork child. pidfd operations avoid directing signals or lifecycle
state at an unrelated process after numeric PID reuse.

=head1 SPAWNING

C<spawn> accepts a command argument vector and does not insert a shell:

  my $process = Worker->spawn(
      loop    => $loop,                       # optional
      command => ['/usr/bin/make', '-j4'],    # required
      cwd     => '/srv/project',              # optional
      env     => { BUILD_MODE => 'test' },    # optional replacement env
      stdin   => 'pipe',                      # optional
      stdout  => 'pipe',                      # optional
      stderr  => 'pipe',                      # optional
      data    => $state,                      # optional
  );

Construction is side-effect free while detached. The child is created when the
object attaches through C<loop =E<gt> $loop> or C<< $loop->add($process) >>.
Consequently C<pid> is undefined before attachment.

C<env> replaces the complete environment when supplied; omit it to inherit the
current environment. Use an explicit shell in C<command> only when shell syntax
is intentionally required.

=head1 STANDARD I/O

Each stdio option accepts C<inherit>, C<pipe>, C<null>, or a caller filehandle.
C<stderr> may additionally be C<stdout> to merge child stderr into child
stdout.

Pipe callbacks are:

  sub on_stdout ($process, $bytes) { ... }
  sub on_stdout_eof ($process) { ... }
  sub on_stderr ($process, $bytes) { ... }
  sub on_stderr_eof ($process) { ... }
  sub on_stdin_drain ($process) { ... }

Readable child pipes are drained by the native process I/O helper while
preserving C<read_size> callback chunking and C<max_reads_per_tick> fairness.

C<write_stdin($bytes)> writes immediately when possible and queues the remainder.
High/low watermarks provide cooperative flow control and C<max_pending_stdin>
can impose a hard safety bound. C<close_stdin> drains already accepted input,
then closes the child's input pipe to deliver EOF.

=head1 OBSERVING AN EXISTING PROCESS

An existing PID may be observed instead of spawned:

  my $process = Worker->new(
      pid  => $pid,
      reap => 1,
  );
  $loop->add($process);

C<reap =E<gt> 1> is the default and requires a child process whose status this
object owns. C<reap =E<gt> 0> permits lifecycle notification for a non-child but
leaves decoded wait-status fields undefined.

=head1 EXIT CALLBACK AND STATUS

A concrete subclass defines C<on_exit($process)>. When a reaped child exits,
Linux::Event records either C<exit_code> or C<term_signal>, plus the core-dump
flag and conventional raw wait status. Remaining available stdout/stderr bytes
are drained before C<on_exit>.

The Loop remains available during C<on_exit> and is released after callback
completion. Callback exceptions propagate after native cleanup.

=head1 SIGNALS

C<signal($number)> uses C<pidfd_send_signal> rather than a bare numeric PID and
returns the Process object. Failures are structured L<Linux::Event::Error>
values.

There is deliberately no generic C<cancel>. Stopping observation, closing
stdin, asking a child to terminate, and confirming process exit are distinct
operations. Applications choose an explicit signal and continue running the
Loop until C<on_exit> confirms lifecycle completion.

=head1 ERRORS AND OWNERSHIP

Optional C<on_error($process, $error)> receives asynchronous process or stdio
failures. Without it Linux::Event warns and retains C<last_error>.

The Loop retains a running Process. Destroying the Loop closes Linux::Event
resources but does not secretly kill the child. Spawned processes and observed
children with C<reap =E<gt> 1> exclusively own their wait status; do not also
use a competing C<waitpid> or SIGCHLD reaper for the same child.

=head1 PLATFORM

Process requires Linux pidfd support and build headers for C<pidfd_open> and
C<pidfd_send_signal>. The runtime lifecycle/status path targets Linux 5.4 or
newer. The build also requires libc support for
C<posix_spawn_file_actions_addchdir_np>.

=head1 SEE ALSO

L<Linux::Event::Loop>, F<docs/PROCESS-DESIGN.md>.

=cut
