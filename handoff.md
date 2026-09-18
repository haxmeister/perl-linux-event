# Linux::Event Handoff

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
