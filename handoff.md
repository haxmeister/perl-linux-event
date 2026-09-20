# Linux::Event Handoff

## 0.115 release review

The complete 0.115 release-readiness audit is represented by PR #21. It reviews
version bookkeeping, checked-in META files, MANIFEST/MANIFEST.SKIP, public POD,
Markdown documentation, examples, current API taxonomy, Linux/system
prerequisites, generated-distribution tests, and the permanent performance gate.

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

Existing release gates already compile every shipped example and POD synopsis,
audit public modules/metadata/MANIFEST contents, run the normal suite across the
supported Perl matrix including threaded builds, run `disttest` / `distcheck`,
validate metadata/POD, and compare the permanent performance regression suite.

Do not upload to CPAN or create the 0.115 tag until PR #21 is merged and its
final exact head has passed all release gates.


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
to a WebSocket native parser without a Perl byte-buffer round trip. Adding or
removing native-consumer mode itself remains rejected.

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

The remote branches `fix/transition-resource-kind` and
`feature/stream-tuning-explorer` still need deletion. The authenticated GitHub
interface used for this preparation can close PRs and update refs but does not
expose ref deletion. Delete those exact branches through GitHub or an
authenticated Git client. Any future explorer should be implemented fresh
under the constraints in `docs/V1-ROADMAP.md`.

After cleanup, `main` should be the only remote branch unless a new, current
piece of work deliberately creates another one.
