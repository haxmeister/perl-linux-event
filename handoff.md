# Linux::Event Handoff

## CORRECTION AFTER FIRST LOCAL RUN (2026-10-30)

The first user-provided sustained file
(`epollexclusive-local-v1`) finished all 24 combinations with valid
acknowledgments and nearly even work distribution on a four-core Linux host.
But the generated client closed sockets with TCP SO_LINGER(0): **every**
completed request induced one server Stream `on_error` callback.
This was a benchmark flaw, not evidence of a Linux::Event runtime error.

The local generator now waits for the server's FIN, closes normally,
and reports `pending_eof` if the FIN does not arrive. The experiment
version in JSONL is `epollexclusive-local-v2`, and the focused smoke
workflow now asserts zero Stream error callbacks, zero incomplete replies,
and zero FIN timeouts in each mode. A fresh local run is required before
using measured throughput/CPU/latency to decide whether to enable
EPOLLEXCLUSIVE. Previous v1 CPU/throughput comparisons are contaminated
by their error path. No user machine details or private results are
committed to the repo.

## USER-RUN LOCAL SUSTAINED BENCHMARK

A sustained local Linux::Event comparison has been added on the experiment
branch: `bench/experiments/epollexclusive-local.pl`.
Instructions: `bench/experiments/EPOLLEXCLUSIVE-LOCAL.md`.

Runs normal shared epoll vs EPOLLEXCLUSIVE vs independent SO_REUSEPORT
over 2 and 4 worker processes, two synthetic CPU workloads, 15-second
trials, two repetitions. Uses multiple local client load-generator
processes to avoid a single generator's CPU ceiling. Captures completed
round trips, CPU per worker and per generator, client latency distribution,
worker fairness and errors. Stores one gitignored timestamped JSONL file.
Run `perl -Mblib bench/experiments/epollexclusive-local.pl` after
building this branch. No sudo or kernel tuning required.

The local sustained runner was verified in CI smoke run 40989609434:
https://github.com/haxmeister/perl-linux-event/actions/runs/40989609434
The script compiled and ran ordinary shared, EPOLLEXCLUSIVE, and SO_REUSEPORT
with 2 separate client generators and 2 worker processes, producing a parsed
JSONL file with complete acknowledgments and per-worker stats.
The dedicated smoke workflow is
`.github/workflows/epollexclusive-local-smoke.yml`. Keep main untouched,
PR #36 draft and 0.118 unreleased.

## VERIFIED CHECKPOINT — EXCLUSIVE LIFECYCLE EXPERIMENT (2026-10-30)

Current implemented branch includes transactional experimental epoll
ADD/DEL mask rollback, Listener replacement/teardown/fork failure tests,
and accept-budget fairness benchmarks.

**Validated:**
- Focused lifecycle CI run 40986880882 passed all 33 top-level tests,
  including deliberate exclusive ADD and DEL failures in an isolated process.
  Earlier failure was test setup only: closing a pipe and reusing its numeric
  fd before canceling the old registry entry. The test now cancels the old
  registration before creating the next pipe.
- Full CI run 40986887272 has passed all eight Perl configurations
  (including threaded) plus generated-distribution integrity. Its long
  full performance-regression job was still in progress at this checkpoint.
- Previously completed full nine-workload performance check 40981156061
  passed the 10% gate; the largest throughput regression was -2.80% in
  deadline Stream throughput and raw Stream was -0.06%.
- The 48-case fair-accept budget run 40986208593 passed but showed that
  budgets 1/8/32/256 cannot reliably balance exclusive workers.
  SO_REUSEPORT was consistently better balanced.

**Decision:** Do not merge, bump, tag, or publish. Keep PR #36 draft;
the prototype has no new public API and runs only behind
`LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE=1`. No main-branch changes were made.
The next meaningful performance check should use long-running realistic
servers with independently measured CPU and fairness on dedicated hardware,
and evaluate the burden of switching existing ordinary listeners to
exclusive registrations during managed fork.

## CONTINUATION — EXCLUSIVE LIFECYCLE AND FAIRNESS (2026-10-30)

This feature branch now includes additional safety checks beyond the first
Linux::Event multi-worker benchmark:

- Native `xsloop/Loop.xs` restores the prior read-interest mask if an
  experimental exclusive EPOLL_CTL_ADD or EPOLL_CTL_DEL fails. Unmodified
  ordinary watcher behavior is preserved.
- `t/loop-epollexclusive-experiment.t` now checks rejected active/paused
  watcher replacement, paused Listener detach and re-adoption, unsupported
  fork disposition preflight, forced child reconstruction failure with parent
  rollback, Listener closure during on_accept, child worker shutdown,
  `fork(move => [$listener])`, and deliberately failed epoll DEL and ADD
  in an isolated child process.
- The benchmark accepts an optional `ACCEPT_BUDGET` argument after
  `serial|batch`; all old invocations still default to 256.
- Fairness workflow `.github/workflows/epollexclusive-fairness.yml`
  completed run 40986208593 successfully: 48 tests, budgets 1/8/32/256,
  4/8 workers, 500 batch requests and 150us synthetic work.
  A budget of 1 did not solve the uneven exclusive worker allocation,
  particularly with eight workers. SO_REUSEPORT was consistently much
  more balanced. Full table and source caveats are in
  `bench/experiments/EPOLLEXCLUSIVE-RESULTS.md`.
- Full baseline-versus-feature performance check previously passed in
  CI run 40981156061, all nine workloads under the existing 10% gate,
  including raw Stream throughput -0.06% and deadline Stream -2.80%.
- The newest CI and performance check should be verified after the last
  regression test amendment before considering further integration.

Decision: **do not automatically enable EPOLLEXCLUSIVE yet**.
The kernel primitive helps wakeup efficiency but is not an even worker
scheduler. Keep this implementation research-only while testing realistic,
long-running servers and kernel compatibility. Main and version 0.118
remain untouched/unreleased. Draft PR #36 is not for merging yet.

## ACTIVE EXPERIMENT — EPOLLEXCLUSIVE shared listeners (2026-10-29)

Branch: `feature/epollexclusive-evaluation`, from main
`08d775cc2287fb63942c2a27b3a6bfeb59a28aa3`.
Draft PR #36: https://github.com/haxmeister/perl-linux-event/pull/36

**Main has not changed for this experiment.** No merge, public API change,
version bump, tag, GitHub release, or CPAN release is authorized. The
development version on main remains 0.118 (unreleased).

The branch includes an **opt-in internal** EPOLLEXCLUSIVE Listener/Loop
prototype. The switch `LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE=1` applies
only when creating an experimental Listener. Ordinary Listener behavior is
unchanged without it. No public constructor option was added.

Implementation:
- `xsloop/Loop.xs`: internal exclusive watcher option; reject incompatible
  flag combinations; omit EPOLLRDHUP from exclusive ADD; use DEL on pause,
  ADD on resume; keep native watcher and Perl handle stable.
- `lib/Linux/Event/_Socket/Listener.pm`: read the experimental environment
  flag on Listener construction and pass the internal registration option
  during attachment. The parent registers before fork; the child re-attaches
  after the managed Loop reset.
- `t/loop-epollexclusive-experiment.t` plus MANIFEST: default-mode control,
  paused/resumed exclusive Listener, pending readiness, repeat cycles,
  active/suspended close, `fork(share => [$listener])` with a paused
  Listener, and callback-triggered `defer_fork(share => [$listener])`
  followed by child pause/resume.
- `bench/experiments/epollexclusive-accept.c` and
  `bench/experiments/epollexclusive-linux-event.pl`: native standalone
  kernel experiment plus real Perl Listener/Stream request/response
  comparison, including serial and batch concurrent-requests mode.
- Workflows `epollexclusive-evaluation.yml` and
  `epollexclusive-linux-event.yml` run measurement matrices.

The first C measurement run 40976555921 passed. Real Linux::Event
sequential app-response run 40980410396 and concurrent batch run
40980753795 passed, with every expected request and Stream reply delivered.

Representative real Linux::Event medians (four workers, 500 batch requests,
three trials; mode: shared / exclusive / SO_REUSEPORT):
- Zero synthetic processing: 3550 / 4590 / 3840 completed/s.
- 150 us synthetic CPU per message: 3625 / 4061 / 3704 completed/s.
- With 150 us CPU, total worker CPU: .21 / .20 / .19 seconds.
- Exclusive worker fairness is poor despite useful wakeup reduction:
  median min/max per-worker accepts 4/230 in four-worker batch mode;
  with eight workers and 150 us work, 0/229, vs SO_REUSEPORT 54/74.
- Sequential mode can strongly favor one exclusive worker (0/500 accepted).

Read the exact benchmark table and caveats in
`bench/experiments/EPOLLEXCLUSIVE-RESULTS.md`, and the architecture
details in `docs/EPOLLEXCLUSIVE-EVALUATION.md`.

Functional validation: the version of the prototype prior to the
client-concurrency benchmark passed eight Perl configurations and
distribution integrity in CI run 40980121599. The final comparison
branch (including batch generator) has passed all eight Perl
configurations and distribution integrity in CI run 40980758678;
its long performance regression job should be checked before proceeding.
The later CI run 40981156061 (after adding deferred-fork integration coverage)
also passed all eight Perl configurations and distribution integrity; the
full performance regression remained in progress at this checkpoint.
Foreign-loop integration and deferred-fork driver overhead workflows
also passed on the feature branch.

NEXT:
1. Extend correctness tests for fork preflight/rollback, watcher
   replacement, and teardown during active callbacks.
2. Test fairness under long-lived connections and a controlled
   multi-core environment, not only short loopback requests.
3. Verify the current full performance regression gate and
   compare CPU cost on dedicated hardware.
4. Only then decide whether to enable automatic exclusive shared
   Listener registration. Do not modify main without explicit approval.

## CURRENT STATE - 0.118 development on main (UNRELEASED)

The callback-safe deferred managed fork feature was squash-merged to main from
PR #35 at commit `1e1426303ef0d7d676ae991af11a325c4461e39b`
on 2026-10-28 (America/Chicago; 2026-10-29 UTC).

Current source/development version: **0.118**. All 30 versioned Perl modules,
both checked-in META files, and `Changes` are updated. The 0.118 changelog
entry is intentionally marked `(unreleased)`, because the user plans to make
additional core additions before the next public release.

**Do not tag, publish a GitHub release, or upload to CPAN yet.** The user
explicitly authorized the merge and version bump, but not a release.
The previous published version remains 0.117 until a future release decision.

The new public API is `$loop->defer_fork(%options)`, with existing managed
resource dispositions `share`, `clone`, and `move`, plus optional callbacks
`on_parent => sub ($pid) { ... }`, `on_child => sub { ... }`, and
`on_error => sub ($error) { ... }`.

It returns a one-shot request handle supporting `cancel` and `is_active`.
A callback queues the request; native dispatch unwinds before the existing
managed fork reconstructs resources in the new child. Completion callbacks run
in their own processes, outside native dispatch, and ordinary Loop driving
continues. Direct `$loop->fork()` remains quiescent-only. Pending parent
requests are not inherited by children; explicit `stop()` takes priority.
The existing resource matrix remains unchanged (established plain socket
Streams support `move`, TLS Streams do not).

Public documentation covers the API in README, the top-level and Loop POD,
`docs/CORE.md`, and `docs/V1-ROADMAP.md`. The examples use framed
`on_message` where they discuss commands such as `FORK`, because raw
`on_data` callbacks do not guarantee message boundaries.
Tests include `t/loop-defer-fork.t` and `t/20-public-surface.t`; the latter
was updated to admit the new benchmark in the supported `bench/` inventory.
The benchmark and its guide/CI workflow are retained.

Validation before merge:
- The original feature implementation passed all eight Perl configurations,
  distribution integrity and the full 10-percent performance gate
  (CI run 40801811654); foreign-loop integration run 40801811559 passed.
- Full performance regression deltas on that implementation stayed within
  the 10% gate; raw Stream throughput -0.66%, deadline -1.51%, framed -1.58%.
- Focused Perl 5.44 microbenchmark run 40804777781 found an additional
  +818.1 ns for empty `poll()` and +906.1 ns for empty `run_once(0)` public
  wrapper calls, versus the private native entry points.
- The 0.118 version/doc pass initially exposed a single test inventory issue
  for the added benchmark, corrected in `t/20-public-surface.t`. The
  final pre-merge CI run 40814675688 passed all eight Perl configurations
  and distribution integrity; foreign-loop integration and focused driver
  benchmark checks were also green. Its long performance comparison was
  still running when the user-approved merge was performed.

Main-branch CI after the merge and this handoff update should be checked
before any future release preparation. No other Linux::Event subproject or
Unblock distribution was changed for this work.

## HISTORICAL STATE - 0.117 release on main (prior to 0.118 work)


Release PR #31 was squash-merged to main as
`3338169bd8ba6d56a554b05556e0c049d9a43fa0` on 2026-09-24.
The merged `release/0.117` branch has been deleted; only main remains.
Preparation started from `f29283989bdd1b91aef1758fb6d68063de81726c`
(the merged public POD rewrite).
All 30 versioned Perl modules and both checked-in META files now consistently
declare 0.117. `Changes` is dated 2026-09-24 and includes the public POD rewrite
alongside defer, Inotify, managed fork, and borrowed TTY ownership.

The initial source audit found two failing documentation test programs after
the POD rewrite. SYNOPSIS validation now compiles only verbatim Perl paragraphs,
while retaining an assertion that every synopsis contains code. Address, Inotify
Watch, and TLS examples now provide their missing lexical context, and the
Process tuning guard checks the current section and option headings. The source
suite passes: 166 files, 3,460 tests on threaded Perl 5.38.2. Two Unix-domain
socket tests skip because this execution environment denies those socket calls;
CI supplies that coverage. Both META formats validate and all 28 public
module PODs pass Pod::Checker without errors.

MANIFEST.SKIP now excludes generated Inotify build products just like the other
XS directories. Generated-distribution testing passes (166 files, 3,458 tests),
`make distcheck` is clean, and `make dist` creates `Linux-Event-0.117.tar.gz`.
The archive contains exactly its 348 MANIFEST entries, matches the prepared
source bytes, and contains no generated build products. The source/distribution
test-count difference comes from repository-only documentation checks.

Release PR #31 contains the verified implementation head
`dfbe2a90400022c16b8ec51b2003f7d3c5b27c36`. CI run #495
(`35936706283`) passed all eight Perl configurations (5.36, 5.38, 5.40, 5.42,
5.44, latest, threaded 5.36, and latest threaded), distribution integrity,
and the full same-run performance regression gate. The threaded 5.36 run passed
3,480 tests, including both locally skipped Unix-domain socket tests. Every
performance workload stayed within the 10 percent gate. Foreign-loop
integration run #54 (`35936706186`) also passed on Perl 5.36 and 5.44.

The tested archive SHA-256 is
`66f8e079a980f9dd9e9e43e56bf5d002faa6351545863c585444067b9eaaaae5`.
Release preparation and merge are complete. Release tagging and CPAN upload
remain separate release actions. No CPAN upload or release tag has been
created. This verification-only handoff update does not alter the CPAN archive.

The sections below are historical implementation records. In particular, the
TTY and public documentation work described as branch work below is now merged
into main and included in this release.

## Netlink architecture decision

Netlink is approved as future work with an explicit two-layer split.

Linux::Event core will provide only the reusable
`Linux::Event::Kernel::Netlink` transport/resource machinery: AF_NETLINK
lifecycle, Loop integration, request/reply correlation, multipart completion,
ACK/error handling, multicast plumbing, overflow/loss detection, fairness,
cancellation, teardown, and related generic mechanics.

The complete user-facing Netlink ecosystem will live in a separate
`Linux::Event::Netlink` distribution. Its first substantial target will be
NETLINK_ROUTE, with semantic APIs for links, addresses, routes, neighbors,
initial dumps, and asynchronous change notifications. Generic Netlink and
additional family-specific interpretation belong there rather than in core.

Both layers are intended to be implemented, but not immediately. When work
starts, the core primitive should be designed against real NETLINK_ROUTE needs
and the Route distribution should serve as the proof that the boundary is
correct.

## Linux-native expansion roadmap

The authoritative `docs/V1-ROADMAP.md` now makes the Linux-first development
rule explicit: a Linux-specific primitive belongs on the exploration roadmap
when it provides a broadly useful event-driven/communications capability or a
credible performance, scalability, fairness, or observability benefit.

The near-term exploration set is Netlink, `EPOLLEXCLUSIVE` for managed-fork
shared Listeners, `recvmmsg()` / `sendmmsg()` Datagram batching,
`sendfile()` / `splice()` zero-copy transfer paths, fanotify, and
incremental Linux UDP metadata/acceleration facilities. Specialized follow-up
targets include AF_VSOCK, SocketCAN/AF_CAN, and AF_PACKET/PACKET_MMAP. Measured
performance candidates include TCP_FASTOPEN, TCP_NOTSENT_LOWAT,
SO_ZEROCOPY/MSG_ZEROCOPY, and affinity hints such as SO_INCOMING_CPU.

The roadmap also preserves the existing architectural discipline: exploration
does not imply automatic integration. Each candidate must earn its API and
maintenance cost through a clean semantic fit, correctness coverage, and
realistic measurement where performance is the motivation. io_uring remains
outside the current epoll/reactor architecture unless future evidence shows a
requirement that epoll cannot satisfy cleanly.

## TTY borrowed-handle lifecycle merged into docs branch

PR #28 was squash-merged into `docs/pod-clarity` as
`5444a158af71945b6b1d2151152214f0060fae00`
("Borrow TTY handles by default").

`Linux::Event::IO::TTY` now borrows supplied terminal handles by default.
This makes the ordinary console case
`read_fh => \\*STDIN, write_fh => \\*STDOUT` safe to close without
destroying the process standard handles.

The public constructor option `owns_handles => 1` opts into explicit ownership.
Default borrowed construction captures each distinct descriptor's original
`F_GETFL` and `F_GETFD` state before the shared ordered-byte engine applies
`O_NONBLOCK` and `FD_CLOEXEC`. Complete TTY close and detach restore those
captured flags and leave the caller's handles open. Directional close stops
Linux::Event use without closing borrowed handles; if another direction remains
active, restoration waits until the complete TTY becomes terminal.

The private `_ByteStream` ownership mode preserves the existing owning
semantics for Pipe and connected Stream. Natural input EOF and graceful
`end()` were audited and corrected so they also respect borrowed TTY
ownership. Managed-fork child drop deliberately does not restore borrowed TTY
flags in the child because Linux file-status flags belong to the inherited
open-file description and restoration there would mutate the still-active
parent TTY.

Focused coverage spans `t/architecture-10-public-leaves.t`,
`t/stream-66-resource-kind-transition.t`, and `t/loop-fork.t`, covering
default borrowing, active nonblocking/close-on-exec state, close/detach
restoration, explicit ownership, directional shutdown, EOF, graceful end,
same-kind transition, and managed-fork child drop.

CI run #492 passed Perl 5.36/5.38/5.40/5.42/5.44/latest, threaded 5.36/latest,
distribution integrity, and the permanent performance regression gate.

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
