# Linux::Event Handoff

## TTY borrowed-handle lifecycle in progress

Branch `feature/tty-borrowed-handles` changes `Linux::Event::IO::TTY` so
supplied terminal handles are borrowed by default. This is motivated by the
ordinary console case `read_fh => \\*STDIN, write_fh => \\*STDOUT`: closing
the Linux::Event TTY should stop event-loop management, not permanently close
the process standard handles.

The public constructor option `owns_handles => 1` explicitly restores the old
owning behavior. Default borrowed construction captures each distinct
descriptor's original `F_GETFL` and `F_GETFD` state before the shared
ordered-byte engine applies `O_NONBLOCK` and `FD_CLOEXEC`. Complete TTY
close and detach restore those captured flags and leave the caller's handles
open. Directional close stops Linux::Event use without closing a borrowed
handle; if another TTY direction remains active, flag restoration waits until
the complete TTY becomes terminal so a shared open-file description is not
changed out from under the active direction.

The private `_ByteStream` machinery carries this as an internal ownership
mode; Pipe and connected Stream behavior remains owning. Managed-fork child
drop deliberately does not restore borrowed TTY flags in the child because
Linux file-status flags belong to the inherited open-file description and
restoring them there would mutate the still-active parent's TTY.

Focused coverage is in `t/architecture-10-public-leaves.t` using
`/dev/ptmx`: default borrowing, active nonblocking/close-on-exec state,
restoration on close, explicit `owns_handles => 1`, boolean validation,
detach restoration, directional close, graceful write end, and input EOF are
all exercised. `t/stream-66-resource-kind-transition.t` verifies a same-kind
TTY transition retains borrowed ownership. `t/loop-fork.t` verifies default
managed-fork child drop does not restore shared open-file flags out from under
the still-active parent TTY.

## Loop-aware process fork merged to main

PR #26 was squash-merged to `main` as
`e00c4a1b6ff1cd18da3f84e2415cad2ddb39bd27`
("Add Loop-aware fork resource dispositions").

The verified implementation head before squash was
`f48a038ecb95299bed7410a07426c3ce1f4f9c77`. The public API is
`$loop->fork(%disposition)`. The initial contract is deliberately
quiescent-only and uses strict `share => [...]`, `clone => [...]`, and
`move => [...]` lists. Every selected object must already be current in the
Loop and may appear in only one list. Unlisted managed resources are
parent-only and their child copies are made inert without application lifecycle
callbacks.

The first supported disposition matrix is intentionally narrow:

- Listener: `share` and `move`.
- Timer: `clone` and `move`, preserving the same absolute monotonic
  deadline in the child.
- Inotify: independent child `clone` and inherited-instance `move`.
- Established plain socket Stream: `move`.
- Event, Process, Datagram, Signal, Pipe, TTY, and unsupported combinations:
  child drop only in this first version.

Pending socket connections, non-plain Stream transports, and active resolver
requests reject managed fork. Idle resolver workers are shut down before the
fork and recreated lazily later if the parent needs resolution again. Pending
`Loop->defer()` work is not inherited. Managed fork is documented for a
process without unrelated live threads; Linux::Event can quiesce its own
resolver workers but cannot repair arbitrary third-party pthread/native-library
state after fork.

The child never reuses the parent's epoll instance or Loop-owned timerfd.
Native Loop state records process ownership. Ordinary `CORE::fork()` reuse is
guarded through a PID cache updated by `pthread_atfork()`, so steady-state
registration pays only a memory comparison instead of a `getpid()` call.
Driving, registration, introspection, statistics, tuning, and direct attached
Timer cancellation/rescheduling reject inherited parent Loop state. Managed
`Loop->fork` explicitly replaces the child reactor infrastructure and changes
Loop ownership before selected resources are reconstructed. Child diagnostic
counters restart from zero while parent statistics are unchanged.

Move uses a private child-ready/parent-commit handshake. The child reconstructs
its fresh reactor and selected resources first. Only after successful child
reconstruction does the parent close/cancel moved descriptors and poison moved
parent objects. Child reconstruction failure is returned to the parent before
parent-side move commit. The child does not return from `fork` until the
parent commits the move.

Signal has special child teardown because the process inherits the blocked
signal mask and signalfd descriptor. Child cleanup closes only its copied
signalfd state and restores child-side signal-mask entries without modifying the
parent's signalfd configuration.

Focused coverage is in `t/loop-fork.t`, including empty managed fork,
quiescence rejection, ordinary-fork ownership rejection, default child drop,
Timer clone/move, Listener share/move, Inotify clone/move, Stream move,
unsupported Stream share, strict disposition validation, and failed child
reconstruction without parent move commit.

The final implementation SHA was independently validated through temporary PR
#27 because a cancelled intermediate PR #26 Actions job held the original
concurrency slot. PR #27 used the exact same SHA and was closed after
validation. CI run #480 passed Perl 5.36/5.38/5.40/5.42/5.44/latest, threaded
5.36/latest, distribution integrity, and the permanent performance regression
gate. Foreign loop integration run #50 also passed.

Final performance comparison versus the 0.116 baseline reported:

- registration lifecycle: +0.34% rate, -0.33% CPU;
- timer lifecycle: +5.08% rate, -4.84% CPU;
- timer expiration: +12.39% rate, -12.03% CPU;
- raw Stream lifecycle: +5.78% rate;
- framed Stream lifecycle: +6.88% rate;
- raw Stream throughput: +2.81% rate;
- deadline Stream throughput: +2.25% rate;
- framed Stream throughput: +3.05% rate; and
- connect/listener lifecycle: +6.76% rate.

No workload exceeded the 10 percent regression threshold. The temporary
validation PR is closed and both fork work branches were removed after the
merge.

## Inotify merged to main

PR #25 was merged to `main` as
`551d1db012c182ee8b28ef00ce8fb08373ddc0cb`
("Add native inotify filesystem notifications"). Inotify is therefore part of
the current 0.117 development baseline; the former `feature/inotify` branch
state is no longer the active handoff.

## Post-0.116 main: Loop defer scheduling

PR #24 was squash-merged to `main` as
`0726b268f5ee11279a7dec118b97103e134e636f`.

Linux::Event now provides `$loop->defer(sub { ... })` for owner-interpreter,
non-reentrant deferred work. Eligible callbacks are FIFO; callbacks queued while
a deferred drain is executing wait for a later drain. The opaque one-shot handle
supports `cancel` and `is_active`, while dropping the handle does not cancel
Loop-owned pending work.

The implementation uses one lazily-created private eventfd and an internal Loop
registration. A drain examines at most 1,024 queue entries and re-signals when
work remains. Callback exceptions consume the failing callback, re-arm remaining
work, and then propagate through the active Loop driver. Deferred work is exposed
through `resources()` and `why_alive` without becoming a managed public
resource object.

The eventfd design means deferred work participates automatically in the
existing `poll_fd` / `poll` foreign-loop boundary. It is deliberately not a
generic cross-thread or cross-process Perl callback queue; those cases remain
the domain of an application payload channel plus `Kernel::Event`.

Focused coverage is in `t/41-loop-defer.t`, with additional foreign-loop
coverage in `t/loop-foreign-integration.t` and a current-documentation guard in
`t/37-current-doc-taxonomy.t`.

The exact feature head `61edf17cb7a5d0459a086c61328e48e9e0e33c85` passed
CI run #446 and Foreign loop integration run #16 before merge.

## 0.116 release

Linux::Event 0.116 is the patch release for the native-consumer retirement
generalization merged by PR #22. Release PR #23 passed all release gates and
was squash-merged to `main` as
`bf0c56b7443cd91d559e7a8d7fe580e59eb1e5b6`.

Release bookkeeping is updated from 0.115 to 0.116 across every versioned Perl
module, including the private versioned support modules, and both checked-in
META files. `Changes` now has a distinct 0.116 entry dated 2026-09-20. The
0.115 history is restored to its released provider-to-provider transition
contract; native-consumer removal belongs only to 0.116.

The functional release change is deliberately narrow: a live native consumer
may retire into an ordinary Perl Stream input sink while preserving unread
ordered bytes and the existing provider flush/retain lifetime guarantees.
Ordinary -> native live transition remains rejected. No ordinary read hot-path
bookkeeping was added.

PR #23 passed CI run #439: Perl 5.36/5.38/5.40/5.42/5.44/latest,
threaded 5.36/latest, generated-distribution integrity, metadata/POD validation,
and the permanent same-run performance regression gate. Foreign-loop integration
run #9 also passed on Perl 5.36 and 5.44. The 0.116 release commit for
tagging/distribution is `bf0c56b7443cd91d559e7a8d7fe580e59eb1e5b6`.

## 0.116 native-consumer retirement transition

The raw native-consumer integration work in upper protocol layers exposed one
remaining transition boundary: a native consumer could be replaced by another
native consumer, but could not retire into an ordinary Perl Stream input sink.
This was merged to `main` by PR #22 at core implementation commit
`51f2e1eab28f6f1234024a0cf37be03b36780e84`.

The chosen scope is deliberately one-way. `transition_to()` may remove an
active native consumer and move the same live ordered-byte object to an
ordinary target such as a raw `on_data` Stream. Adding a native consumer to an
already-ordinary live Stream remains rejected because there is no demonstrated
caller and ordinary callbacks may already have surfaced bytes into Perl. This
keeps the new contract as small as the HTTP Upgrade/CONNECT requirement needs.

No ordinary read hot-path bookkeeping was added. The implementation reuses the
existing provider-handoff state: the target provider is simply NULL. The source
provider remains alive until its active provider frame, pending flush work, and
host lifetime retains are settled; its descriptor lifetime token remains held
until destruction. The connection-local ordered-byte input buffer is unchanged.
After the source prefix reported by raw `input()` is consumed, any unread tail
is re-driven under the ordinary target descriptor. Ordinary raw delivery
consumes that native tail before invoking `on_data`, so a reentrant close from
the new target cannot cause a second consume or stale-buffer accounting.

Focused coverage extends `t/stream-59-native-consumer-abi.t` for:

- native raw consumer -> ordinary `on_data` from inside `input()`;
- same-read unread native tail preservation, ordering, and exact-once delivery;
- later kernel input through the ordinary target;
- source flush/destruction and host-retain lifetime across retirement;
- reentrant ordinary-target close while retained bytes are re-driven;
- explicit read pause across transition and synchronous tail delivery on resume;
- no extra source-consumer input call after transition; and
- continued rejection of ordinary -> native transitions.

This is the functional change being released as 0.116. PR #22 already passed
the full Perl/threaded matrix, distribution-integrity checks, and the permanent
same-run performance regression gate before merge. The underlying core
implementation commit remains `51f2e1eab28f6f1234024a0cf37be03b36780e84`.

## 0.115 raw-consumer reentrant-close correction

Raw native-consumer `input()` callbacks may enter application code that closes
the Stream before returning a consumed-byte count. Terminal teardown clears
the native input buffer, so `les_process_existing_input()` now treats that
teardown as owning buffer disposal and does not apply the stale count afterward.
Returned status and consumed-count validation still run.

This does not weaken provider replacement. A nonterminal provider-changing
`transition_to()` still applies the source consumer's consumed prefix before
settling its flush/destruction obligations and re-driving the preserved native
tail through the target consumer. `t/stream-59-native-consumer-abi.t` covers
both reentrant terminal close and the HTTP-to-WebSocket-shaped provider handoff.

## 0.115 release review

PR #21 completed the 0.115 release-readiness audit and was merged to `main` as
`6d8195b0fe593cc0e3efdd58081194a1f0f6ccb1`. The audit covered version
bookkeeping, checked-in META files, MANIFEST/MANIFEST.SKIP, public POD, Markdown
documentation, examples, current API taxonomy, Linux/system prerequisites,
generated-distribution tests, and the permanent performance gate.

Release-facing corrections made by that audit:

- stamp the 0.115 Changes entry with the final 2026-09-19 release date;
- surface the supported Loop `poll_fd` / `poll` foreign-loop boundary in the
  README;
- surface raw native consumer input and provider-to-provider `transition_to()`
  handoff in README, Framer POD, and the framing guide;
- align README build prerequisites with the module POD: Perl 5.36+, pidfd-capable
  Linux headers, Linux 5.4+ for pidfd process status, libc
  `posix_spawn_file_actions_addchdir_np`, a C compiler, and OpenSSL 1.1.1+
  development files;
- add documentation regressions so the new 0.115 public surfaces remain visible.

The exact PR head `74084902b0d6972359682217c4ae470abf32a162` passed CI run
#433: Perl 5.36/5.38/5.40/5.42/5.44/latest, threaded 5.36/latest,
generated-distribution `disttest` / `distcheck`, metadata and public POD
validation, and the permanent performance comparison. The performance gate
reported every workload within its 10 percent regression threshold.

The repository is ready for the 0.115 release process. CPAN upload and creation
of the 0.115 tag/release remain explicit release actions rather than part of
the preparation audit.


## Foreign-loop integration

The first required post-0.114 roadmap item is implemented in PR #19.

`Linux::Event::Loop->poll_fd` returns the Loop-owned epoll descriptor as a
borrowed readiness fd. Foreign loops must not close it; adapters that need a
Perl filehandle may duplicate it. `Loop->poll` performs exactly one
nonblocking epoll wait and dispatch turn and returns the kernel event count.
It has the same single-driver/reentrancy guard as `run`, `run_once`, and
`run_for`, but it is a separate supported integration contract rather than
an alias convention around `run_once(0)`.

The shipped dependency-free regression `t/loop-foreign-integration.t` drives
raw I/O, Timer, Event, Signal, and Process readiness through `IO::Select`
watching a duplicate of `poll_fd`. Repository-only
`xt/foreign-loop-cpan.t` covers EV, AnyEvent, IO::Async, and Mojo, with those
modules installed only by `.github/workflows/foreign-loop-integration.yml`.
They are not CPAN prerequisites.

`poll_calls` is exposed in Loop statistics and reset by `reset_stats`.
The existing `run_once` implementation and counters remain unchanged.

## 0.115 integration: ordered-byte fairness and raw native input

The timer-starvation investigation is now an approved 0.115 integration rather
than investigation-only work. The shared ordered-byte default is
`read_budget_bytes => 65_536` for Stream, Pipe, and TTY. Explicit
`read_budget_bytes => 0` remains the unlimited drain-until-EAGAIN opt-in.

Linux::Event::WebSocket exposed nominal 1.5-second timers being delayed by tens
of seconds during sustained external echo traffic. The core reproducer showed
that unlimited draining allowed one continuously replenished ordered-byte fd to
remain inside a single readiness callback while timerfd and other descriptors
were already ready.

The decisive fixed-frame feedback benchmark measured median timer lateness of
1556.807 ms for unlimited drain, with one of three measured cases reaching the
independent five-second watchdog. Finite budgets kept throughput essentially
flat at about 214k-217k msg/s. Median timer lateness was 1.459 ms at 16 KiB,
2.848 ms at 32 KiB, 7.930 ms at 64 KiB, 15.539 ms at 128 KiB, and 30.904 ms at
256 KiB. A raw/Delimiter payload sweep through 200,000 B identified 64 KiB as
the throughput/fairness knee.

The benchmark programs remain under `bench/`. Raw machine-readable evidence is
committed under
`bench/decisions/BD-2026-09-19-001-stream-timer-fairness/`, and the KEEP
decision is indexed in `bench/BENCHMARK-DECISIONS.md`.

Native consumer protocol handoff is also generalized for protocol upgrades.
`transition_to()` may now replace one native consumer operations table with
another while preserving the same ordered-byte input buffer. Target context
creation is validated before the source is disturbed; source flush debt and
provider-frame/host-retain lifetime are settled before source destruction; the
retiring descriptor stays referenced until that destruction so its provider
lifetime token cannot disappear early; then the retained tail is re-driven
through the target provider. This directly
supports cases such as HTTP native parsing handing same-read post-Upgrade bytes
to a WebSocket native parser without a Perl byte-buffer round trip. The later
native-consumer retirement work documented above additionally permits a native
provider to hand unread input to an ordinary Perl target; adding a native
consumer to an already-ordinary live Stream remains rejected.

The native consumer ABI v1 is also generalized for upper protocol libraries
that cannot use one of the built-in native framers. A provider can request
`LES_CONSUMER_F_RAW_INPUT` and receive a borrowed contiguous `(data, length)`
window directly from the ordered-byte native input buffer before payload bytes
are converted to a Perl SV. The provider reports the leading byte count it
consumed; the core retains any tail natively and can re-drive it after later
reads or consumer resume. This is an append-only ABI-v1 extension guarded by
`struct_size`, so original providers remain compatible.

Regression coverage lives in `t/stream-14-class-options.t` for the resolved
bounded default, `t/stream-68-read-fairness.t` for one-turn 64 KiB yielding
and the explicit-zero unlimited opt-in, and
`t/stream-59-native-consumer-abi.t` for raw-input lifetime, retained tails,
CONTINUE re-drive, callback conflicts, original-v1 compatibility, and
native-buffer delivery.

Before architectural, performance, dependency, or ecosystem work, read
`docs/ECOSYSTEM-CHARTER.md`. It is authoritative.

For remaining planned core work, read `docs/V1-ROADMAP.md`. The
foreign-loop boundary is the first roadmap item completed in 0.115; later
roadmap items remain out of scope for this release.

## Current state: 0.115 protocol-subclass close correctness

0.115 includes the protocol-subclass close correctness work prompted by
Linux::Event::WebSocket integration. Protocol subclasses may give their public
`close()` method
protocol-level semantics, so core-internal involuntary teardown must not assume
that virtual `$self->close` still means immediate raw transport destruction.

Three forced-cleanup sites now bypass subclass `close()` and call the existing
private terminal primitive `_close_now(1)` directly:

- adopted/accepted Stream configuration failure in
  `Linux::Event::_Socket::Stream`;
- accepted Stream preparation/attachment failure in
  `Linux::Event::_Socket::Listener`;
- Listener `on_accept` callback failure after a Stream has been constructed.

The native-consumer path `_xs_consumer_close()` intentionally still dispatches
through public `close()`. `LES_CONSUMER_CLOSE` is documented as an explicit
semantic request to close the host through normal lifecycle, not an involuntary
transport failure.

Regression coverage in `t/stream-49-socket-options.t` and
`t/listener-16-callbacks.t` installs Stream subclasses whose public `close()`
does not tear down the transport. The tests require forced cleanup to bypass
that override while still closing descriptors and preserving the existing
`on_close` behavior.

Distribution version bookkeeping is bumped from 0.114 to 0.115, including
public/private versioned modules and checked-in META files. `Changes` records
the fix. The separately documented foreign-loop boundary is the only roadmap
feature added to 0.115.

The browser development environment cannot execute the compiled XS suite
locally. GitHub CI is therefore the verification gate for this commit before a
0.115 CPAN release.

## Branch cleanup

The obsolete PRs are closed: #12's resource-kind intent has been ported to the
current architecture, and #7's tuning explorer targets retired APIs.

The authenticated GitHub interface used for this preparation can update refs
but does not expose ref deletion. The following merged/obsolete remote branches
remain and may be deleted through GitHub or an authenticated Git client:

- `feature/foreign-loop-integration`;
- `feature/native-consumer-transition`;
- `feature/stream-tuning-explorer`;
- `fix/transition-resource-kind`;
- `investigate/stream-timer-fairness`;
- `release/0.115-review`;
- `verify/core-0.115-fairness-abi`;
- `verify/core-0.115-fairness-abi-v2`.

Any future tuning explorer should be implemented fresh under the constraints in
`docs/V1-ROADMAP.md`. After cleanup, `main` should be the only remote branch
unless a new, current piece of work deliberately creates another one.
