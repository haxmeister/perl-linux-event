# Linux::Event Handoff

## Investigation branch: ordered-byte timer fairness

Branch `investigate/stream-timer-fairness` contains investigation-only work;
no production default or runtime behavior has been changed.

Linux::Event::WebSocket exposed nominal 1.5-second timers being delayed by tens
of seconds during sustained external echo traffic. Core-only reproduction now
confirms the cause: the ordered-byte default `read_budget_bytes => 0` permits a
single Stream/Pipe/TTY readiness callback to drain successful reads until
EAGAIN. A concurrently replenished fd can therefore monopolize Loop dispatch
while the shared timerfd and other descriptors remain ready but unserviced.

The decisive fixed-frame feedback reproducer keeps a 32-message window against
a forked echo peer. With 64-byte messages and a 1.5-second Timer, unlimited
drain had median timer lateness 1556.807 ms and one of three measured cases hit
the independent five-second watchdog. Finite budgets kept throughput essentially
flat at about 214k-217k msg/s. Median timer lateness was 1.459 ms at 16 KiB,
2.848 ms at 32 KiB, 7.930 ms at 64 KiB, 15.539 ms at 128 KiB, and 30.904 ms at
256 KiB.

A representative raw/Delimiter payload sweep through 200,000 B held
`read_size=64 KiB` constant. 64 KiB is the measured knee: smaller budgets
materially reduce medium/large payload throughput, while 128 KiB provides only
modest extra raw throughput and approximately doubles feedback timer lateness.
The current candidate fix is therefore to change the shared ordered-byte
default to `read_budget_bytes => 65_536`, retaining explicit zero as the
unlimited opt-in.

Full findings, exact tables, workflow run/artifact IDs, and implementation
follow-ups are in
`bench/decisions/BD-2026-09-19-001-stream-timer-fairness/README.md`.

Do not change the production default or merge this branch without explicit user
authorization. If approved, preserve final JSON under `bench/decisions`,
append the benchmark decision record, update all tuning-default documentation
and tests, run the full suite/performance gates, and separately audit the
queued-write drain for the analogous replenishment hazard.

Before architectural, performance, dependency, or ecosystem work, read
`docs/ECOSYSTEM-CHARTER.md`. It is authoritative.

For planned core work beyond this narrow correctness release, read
`docs/V1-ROADMAP.md`. No roadmap feature work is part of 0.115.

## Current state: 0.115 protocol-subclass close correctness

0.115 is a narrow correctness release prompted by Linux::Event::WebSocket
integration. Protocol subclasses may give their public `close()` method
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
the fix. No unrelated core architecture or roadmap work is included.

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
