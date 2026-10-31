# Linux::Event Handoff

## CURRENT MAIN — SENDFILE MERGED AND DOCUMENTED (2026-10-31)

Current `main` includes native ordered Stream `sendfile()`, merged from
[PR #39](https://github.com/haxmeister/perl-linux-event/pull/39)
as `f219f24f278cdb1319a38402d3a9a35f61523e08`.
The feature was validated at `955a0622c56841779fd16fdc37fe0548cd04048a`
with [ten successful CI jobs](https://github.com/haxmeister/perl-linux-event/actions/runs/41166889428)
and the [actual Stream benchmark](https://github.com/haxmeister/perl-linux-event/actions/runs/41166889422).
The post-merge `main` [CI also passed](https://github.com/haxmeister/perl-linux-event/actions/runs/41208249334).

Source version remains **0.118 (unreleased)**. Do not tag, release on
GitHub, or upload to CPAN until expressly approved. The feature adds
one public method, `sendfile($fh, offset => ..., length => ...)`, for
established plain TCP and Unix-domain socket Streams. It is ordered
with `write()`, uses the native queue and existing flow control,
duplicates the file descriptor, preserves the caller's position, and
rejects TLS and pending connections. The private file/mixed-queue
fairness budget is 64 KiB per writable readiness turn. Research
[PR #38](https://github.com/haxmeister/perl-linux-event/pull/38)
remains separate; `splice()` has not been integrated.

A documentation-only `main` change, `4ee9a4c852bad2bd6a409e002ee77f2bf03b90cc`,
updated `Changes`, the README, public Stream POD, the roadmap,
connection and ordered-byte guides, and
`docs/STREAM-SENDFILE-DESIGN.md`. Those now describe implemented
behavior and tested limitations, not an unmerged proposal. The
documentation CI is a separate check and should not be called passed
until its exact commit completes.

**All sendfile sections below this note are historical checkpoints.**
In particular, older instructions to keep PR #39 draft, await the
final callback regression, or avoid a `main` merge are superseded.
Research PRs #36 (EPOLLEXCLUSIVE), #37 (recvmmsg), and #38
(sendfile/splice syscall comparison) remain separate, unmerged
research. No core implementation of `splice()` or `sendmmsg()`
is claimed here.


## STREAM SENDFILE FINAL NATIVE REVIEW (2026-10-30)

At exact commit `978a0168288ef286f9742b57ac00d70375719da4`,
full CI #41161874475 PASSED all ten jobs (Perl configurations,
distribution integrity, and ordinary-write performance comparison).
Actual Stream benchmark #41161874446 also PASSED.

Final native review covered file segment ownership and cleanup, `F_DUPFD_CLOEXEC` and close-on-exec, explicit offset/range checks,
readable regular-file validation, mixed writev/sendfile ordering,
short writes/EAGAIN/EINTR/early EOF, SIGPIPE masking, shared pending-byte
accounting, hard output limits, graceful end/close_write/close,
write deadlines, callback teardown, managed fork (move and child drop),
TLS rejection, and the 64-KiB fairness budget. No blocking correctness
defect was identified during the source review. A redundant native
`progress` variable is removed without changing syscall behavior.

One additional targeted regression tests a producer that submits a
second file from inside `on_drain`, preserving ordering and graceful
EOF; and validates empty-source no-op semantics. Added at
`t/stream-75-sendfile-drain-reentrancy.t`. This new test and the
small README file-transfer explanation require a fresh CI run.
Do not call that follow-up CI green until actually verified.

Public API remains only `sendfile($fh, offset => ..., length => ...)`,
with existing backpressure/close/error callbacks, and no new public
tuning or transfer object. The chosen file-drain budget remains 64 KiB.
Feature branch and PR #39 only; `main`, version 0.118, research PR #38
and other distributions are untouched. PR #39 still requires a final
description update and owner approval before merge.


## STREAM SENDFILE PUBLIC SURFACE ALLOWLIST FIX (2026-10-30)

The feature commit `a474d970890f401841127f0227f71ac325f9b1f8`
passed the new `t/stream-74-sendfile-fork.t` in the observed core CI
matrix jobs and the ordinary actual-Stream benchmark workflow
#41161736615. The full CI run #41161736592 caught a packaging-only test
failure: `t/20-public-surface.t` maintains an exact allowlist of
`bench/` files, and did not yet include the new summary tool. Update
the allowlist to include `summarize-stream-sendfile-budget.pl` and
rerun full CI. Engine/fork behavior did not cause this failure.
Do not claim final full CI is green until the corrected exact commit passes.


## STREAM SENDFILE BUDGET DECISION AND MANAGED-FORK TEST (2026-10-30)

The corrected actual-Stream budget sweep passed on exact commit
`5159ebc77782accbe7524859f7f33ceb9e0165df`, workflow
#41161571136. It tested four isolated compiled budgets (64, 128, 256,
512 KiB), alternating order, six SHA-256-verified TCP cases per mode/size,
with a concurrent repeating 1-ms native Timer. The Timer measurement
reconstructs the scheduled due time, because the native scheduler advances
the recurring deadline before invoking the callback.

16-MiB sendfile medians, budget: throughput MiB/s, sender CPU ms/MiB,
timer p95 lateness ms:
- 64 KiB: 307.39, 0.2870, 0.0165
- 128 KiB: 307.45, 0.3048, 0.0182
- 256 KiB: 307.08, 0.2985, 0.0158
- 512 KiB: 307.87, 0.3035, 0.0179

On the shared CI runner, increasing 64->512 KiB gains less than 0.2%
16-MiB throughput. Timer p95 and CPU do not establish a sustained
advantage. **KEEP the private 64-KiB file-drain budget.** These are
provisional machine-specific measurements, not general hardware limits.
Keep the heavy sweep reproducible as a workflow_dispatch-only job, so
ordinary PR changes do not rebuild four copies. Normal SHA-256-verified
Stream benchmark CI continues to run on PRs.

New `t/stream-74-sendfile-fork.t` tests managed fork with a queued
file: default child drop must close only its inherited source duplicate
while the parent continues owning its queue; explicit move must transfer
the entire ordered file-plus-trailer queue to the child, with the parent
receiver verifying bytes and EOF. Include the new test in MANIFEST.
These managed-fork regressions require a fresh full CI run and must not be
called passed until verified.

`main`, versions, releases, PR #38 and other repositories remain unchanged.
Draft integration PR #39 is not merged.


## STREAM SENDFILE BENCHMARK TIMER DEADLINE CORRECTION (2026-10-30)

The native Timer scheduler advances its recurring `deadline` before calling
`on_timer`, so a simple `now - deadline` would measure the next tick and
falsely report zero lateness. The budget sweep now reconstructs the due time
from `deadline - expirations * interval` inside the callback. This also
accounts for coalesced missed intervals. The previous budget-sweep run at
`7e76bafd2b4af178a8a98c823fb641f73dee6683` must NOT be used to compare
timer fairness. Rerun the budget variants and full CI after this correction.
The production 64-KiB budget remains unchanged; main remains untouched.


## STREAM SENDFILE BUDGET SWEEP (2026-10-30)

The full ten-job core CI run #41153049081 and actual Stream TCP benchmark
#41153049094 both PASSED on exact integration commit
`207441524e19cf97c15fcacae2da187365f74c53`. This includes corrected
source-file-only FD accounting on a write timeout, multiple file ranges,
graceful EOF, and detach rejection. The previous "await CI" note is superseded.

Next feature-branch experiment adds a private budget sweep without changing
the production 64-KiB LES_FILE_DRAIN_BUDGET default. The CI workflow builds
four separate source copies with 64, 128, 256, and 512-KiB native drain
budgets. It runs real verified TCP Stream transfers with concurrent 1-ms
Kernel::Timer callbacks for each build, repeated in ascending and descending
budget order. The existing benchmark remains byte-/SHA-256-verified and now
optionally reports timer sample count, per-case p95/max lateness, and labelled
build budget. The separate summary script reports median sender CPU/MiB,
end-to-end throughput, and median timer p95/max per variant. These experiments
must be judged using all metrics, not only throughput or a noisy CI median.

A new full CI run and budget sweep will be required after the benchmark
instrumentation and workflow commit. No production default, public API, main,
research PR #38, versions, or other repositories are changed by this step.
Draft PR #39 remains unmerged.


## STREAM SENDFILE TIMEOUT TEST FIX (2026-10-30)

Exact commit `6a8cedeea512ac1ddc13d1283a161725ecd28049` passed
the actual Stream benchmark workflow #41152924126. In the core suite,
new `t/stream-72-sendfile-multirange.t` passed, and
`t/stream-73-sendfile-timeout.t` confirmed timeout behavior, but two
FD-count assertions assumed no new timerfd would be created on first
queued output. The Loop legitimately creates a timerfd when the
write-inactivity deadline becomes active. The regression now counts
only `/proc/self/fd` entries with the source file's device/inode.
This directly verifies one original FD, two while queued, and one
again after timeout. No engine change is indicated by the failure.
Await full CI on corrected exact commit.


## STREAM SENDFILE INTEGRATION COVERAGE AND CI (2026-10-30)

The exact feature HEAD `eac4cd0f5dd94cdb19cc12acc56e8df6336a485d`
passed the complete ten-job core CI run
[41144520668](https://github.com/haxmeister/perl-linux-event/actions/runs/41144520668)
and actual Stream TCP benchmark run
[41144520718](https://github.com/haxmeister/perl-linux-event/actions/runs/41144520718).
Earlier handoff entries that say tests were pending are superseded by these
confirmed results for that commit.

Next coverage additions in this feature-branch commit:
- `t/stream-72-sendfile-multirange.t`: interleaved output with several
  fixed ranges from two files, repeated use of one source, caller position and
  descriptor ownership, graceful end and EOF, queued detach rejection.
- `t/stream-73-sendfile-timeout.t`: a file stalled against a non-reading
  socket must use the normal native write inactivity deadline, close cleanly
  once, and release its duplicated source descriptor.
- Public Stream POD: short file-transfer example and the narrow API contract,
  including plain-only, raw output, ownership, and backpressure semantics.

These newly added tests require CI validation; previous clean run refers to
the earlier exact commit only. Main remains unchanged; the separate research
branch and PR #38 are untouched. Draft integration PR #39 remains unmerged.
No version bumps or release work.


## STREAM SENDFILE SOURCE PERMISSION VALIDATION (2026-10-30)

Added a cheap native F_GETFL guard during sendfile submission: a regular
file opened write-only is rejected before the socket is affected, with
the duplicated descriptor released. The new regression covers this
validation and verifies the Stream stays open after the invalid request.
This matters because sendfile uses a borrowed supplied file handle and
requires readable regular-file input. Existing byte-write path unchanged.

New code and t/stream-70 validation are pending CI after this commit.
Earlier benchmark run 41144061635 passed; do not assume its numbers
apply to changes without a separate run. Main, release, research PR
and other repositories remain untouched.

## STREAM SENDFILE FAIRNESS + TRANSITIONS REGRESSION (2026-10-30)

Follow-up regression `t/stream-71-sendfile-fairness.t` adds:
- Native writable readiness fairness (at most 64 KiB per ready drain when
  a file segment is queued); repeated Loop turns continue progress;
- sendfile mixed with ordinary output across transition_to(), keeping
  original output order and avoiding errors;
- on_drain callback closing a Stream mid-drain without use-after-free,
  duplicate callbacks, or errors.

These tests are newly added, not yet verified by CI. Await run results
before claiming passed. Previous corrected assertion commit:
`48d9d276fae4caff22fb3afec8ac32afffc0ee24`.
All changes remain on feature/stream-sendfile, draft PR #39 only.
No main/research modifications, version bump, release, or splice work.

## STREAM SENDFILE BENCHMARK VERIFIED (2026-10-30)

Actual Linux::Event Stream TCP benchmark workflow
[41144061635](https://github.com/haxmeister/perl-linux-event/actions/runs/41144061635)
PASSED 66/66 byte-verified source-to-receiver trials, including a
slowed-receiver case. These are genuine Stream sendfile() comparisons
against a bounded Perl sysread/write producer and a separate preloaded
byte-write control, not the earlier standalone syscall experiment.

Shared CI runner median sender CPU ms/MiB (sendfile vs copy producer):
- 32 KiB: 11.9202 vs 13.6687 (12.8% reduction).
- 200 KiB: 2.3546 vs 3.1560 (25.4%).
- 1 MiB: 0.8377 vs 1.5890 (47.3%).
- 8 MiB: 0.3487 vs 1.0392 (66.4%).

8 MiB end-to-end throughput medians: sendfile 213.31 MiB/s,
copy producer 221.11 MiB/s, preloaded write 179.09 MiB/s.
Native 64-KiB readiness budget may cap throughput and should be measured
against larger budgets using paired CI/dedicated machine runs.
These shared-runner figures are preliminary, not acceptance baselines.
The independent core CI at run 41144061550 caught one newly added
test expectation error: a 1-MiB range below default high watermark
correctly returns true after one immediate 64-KiB sendfile call; the test
incorrectly expected false. Correct the assertion and rerun CI.
No functional runtime failure is established by this assertion error.

## STREAM SENDFILE VERIFICATION AND EXPANDED COVERAGE (2026-10-30)

First implementation commit:
`f723089e12b5294df948ea457bb22b90d2a15e7e`.
An in-file test inheritance typo was corrected at
`505da85737446e2fb88372a6c02dbeb3d562c896`.

GitHub Actions [41143236988](https://github.com/haxmeister/perl-linux-event/actions/runs/41143236988)
PASSED ALL TEN JOBS: eight Perl configurations, distribution integrity,
and the existing full ordinary-write performance regression gate.
The earlier run failed only because the added test attempted to load an
in-file test package with unqualified 'use parent'.

Additional files now prepared for the next commit/CI:
- `t/stream-70-sendfile-lifecycle.t`: duplicate-fd cleanup on close and
  close_write, zero-range/no-regular-source validation, framed raw output,
  TLS rejection before/after handshake, SIGPIPE-safe peer disconnect.
- `bench/run-stream-sendfile-bench.pl`: ACTUAL Linux::Event Stream transfers
  using real localhost TCP; sendfile, bounded sysread/write producer, and
  separate preloaded byte-write control; forked receiver SHA256 integrity
  verification, separate sender/receiver process CPU, throughput, output
  queue and EAGAIN metrics. Rotating trials, full size sweep, optional pressure.
- `.github/workflows/stream-sendfile-integration.yml`: benchmark CI
  with retained JSONL. Benchmark outcomes are not yet known. No baseline
  performance conclusion about Stream sendfile is claimed.

All code remains on draft PR #39, feature branch only. Do not merge main,
touch research PR #38, change versions, or publish. Further review needed
for reentrant errors, protocol transitions, managed fork, deadline fairness,
performance and the provisional public API contract.

## STREAM SENDFILE PROTOTYPE CHECKPOINT (2026-10-30)

Implementation work now targets the existing `feature/stream-sendfile` branch
without modifying main or the preserved research branch. A first native
implementation has been prepared for commit, but is NOT YET CI-VERIFIED.
The public API remains provisional pending final review.

- `xsbytestream/stream_internal.h`: file entry embeds the existing small
  byte segment header; a null SV marks an owned file descriptor plus explicit
  source offset. State tracks file-entry count.
- `xsbytestream/stream_write.c`: file range admission and duplicated
  close-on-exec FD; one immediate bounded sendfile call on an empty queue;
  mixed writev/sendfile readiness draining without crossing file boundaries;
  64-KiB cumulative budget, native transport guard, thread-local SIGPIPE mask,
  partial/EAGAIN/EINTR/premature EOF handling; same pending limits, watermarks,
  byte statistics and teardown release.
- `xsbytestream/ByteStream.xs`: private _sendfile entry.
- `lib/Linux/Event/_Socket/Stream.pm`: experimental sendfile($fh, offset =>,
  length =>) wrapper only for plain established sockets. This sends raw output
  just like write(), including on framed subclasses (send() still frames).
  No new public transfer object or callback.
- `t/stream-69-sendfile.t`: initial ordering, close-source, offset, range,
  hard-limit, and truncation regressions. Further lifecycle/fairness/TLS/peer
  disconnect coverage is required, as is actual Stream performance measurement.
- `MANIFEST`: includes new test.

The previously recorded proposal is in `docs/STREAM-SENDFILE-DESIGN.md`.
Local git/network access is unavailable; GitHub connector writes and GitHub
Actions PR CI are the validation path. Do not claim tests passed until CI
has run. Next: commit the prototype, open draft PR, inspect failures,
correct and extend tests, benchmark real Streams, update exact commits here.

## ACTIVE STREAM SENDFILE INTEGRATION (2026-10-30)

Proposal checkpoint: `407e75c9227fe3bc8c44a4005b2e149211eecc85`.
Whitespace and manifest inventory checks passed; no executable code changed.

New integration branch: `feature/stream-sendfile`, based on current main
`08d775cc2287fb63942c2a27b3a6bfeb59a28aa3` (0.118 unreleased).
The completed research branch remains intact at
`a46d77e4c199f7ba9876e5a42ebddd6123fc1af3`; PR #38 is research only.
Do not modify main, bump versions, tag, release, or modify other repositories.

Read `docs/STREAM-SENDFILE-DESIGN.md` next. This checkpoint contains inspection
and a concrete proposal, not an implementation. The owner explicitly requested
public API/ownership discussion before finalizing it. Proposed API is
`sendfile($fh, offset => ..., length => ...)`, with a duplicated close-on-exec
fd, offset zero by default, size-at-submission range, unchanged caller offset,
existing boolean flow control, raw bytes like write(), and explicit TLS rejection.
Proposed first scope is established plain socket Streams; pending connects reject.
These public decisions remain proposals until the owner responds.

Inspected current native queue, transport, lifecycle, callbacks, readiness,
preconnection staging, framing, transitions, managed fork and CI. Smallest fit:
file entries embedded in the existing les_write_seg_t list; writev stops at a
file, sendfile drains only the head range. Preserve ordinary segment size and
immediate byte writes. Extend common cleanup for file fds. Remaining file bytes
participate in existing pending-byte/watermark/deadline/limit mechanisms. Proposed
mixed-drain budget starts at 64 KiB and must be tested, not assumed optimal.

Important implementation checks: callback teardown invalidates segment pointers;
SIGPIPE must not terminate the process; premature file EOF is terminal; source
contents must remain immutable until peer consumption (queue drain is not that
notification); nonblocking output does not make cold disk reads asynchronous.
The preconnection queue is a separate Perl byte-string array, so accepting file
handles there cannot be silently assumed from the native queue extension.

Next after API discussion: native implementation, focused correctness/lifecycle
regressions, actual Stream file-transfer benchmarks, full compatibility and
performance CI. Do not repeat the completed standalone syscall investigation.
No tests or Stream performance runs are claimed for this documentation checkpoint.
The working source snapshot was retrieved through GitHub and checked against
main's exact Git tree `6e617fed7b19e85fc89adadf42806cb80fedee8b`.


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
