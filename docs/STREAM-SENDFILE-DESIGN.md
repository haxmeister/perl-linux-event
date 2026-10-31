# Native Stream sendfile — implemented contract and verification

**Status:** Implemented and merged into Linux::Event `main` for the
**0.118 development version (unreleased)** on 2026-10-31.
[PR #39](https://github.com/haxmeister/perl-linux-event/pull/39) merged as
`f219f24f278cdb1319a38402d3a9a35f61523e08`.
The earlier Linux syscall comparison remains separate on
[draft research PR #38](https://github.com/haxmeister/perl-linux-event/pull/38).
It investigated `sendfile()` and `splice()`; only `sendfile()` has
been integrated into Stream.

This is the **implemented behavior**, not a proposal. The public
application-facing documentation is in
[`Linux::Event::IO::Sock::Stream`](../lib/Linux/Event/IO/Sock/Stream.pm).

## Public API

```perl
open my $file, '<:raw', $path or die "open $path: $!";

$stream->write($headers);
$stream->sendfile($file);
close $file;                 # The Stream owns its own descriptor.
$stream->write($trailer);
$stream->end;                # Finish only after queued bytes drain.

# Or send a specific byte range:
$stream->sendfile($other_file, offset => 1024, length => 4096);
```

The method accepts an open, readable **regular-file handle**, not a pathname
or bare file descriptor. `offset` defaults to zero (not the caller's current
file position), and omitted `length` means the remaining bytes from that
offset to the file size observed at submission. It validates the range and
native integer limits. Unknown options, unreadable or non-regular sources,
and ranges outside the observed file size are rejected. A zero-length
range is a successful no-op.

The Stream duplicates the source fd using close-on-exec and owns that
duplicate. The application can close its original filehandle after
submission without canceling queued output; the caller's file position
is unchanged. This **does not snapshot the file**. Source content must
remain unchanged until the receiver has consumed the data. The kernel
may still refer to source pages after the Stream's queue drains. A later
in-place edit or truncation can make output incorrect or fail the transfer.

The method is available for established plain TCP and Unix-domain
`SOCK_STREAM` sockets (including adopted sockets). A connecting outbound
Stream must use it from `on_ready`, not before establishment.
TLS and other non-plain transports reject it. No implicit copy fallback,
Pipe/TTY method, new transport ABI call, or `splice()` API was added.

`sendfile()` writes **raw bytes**, just like `write()`; it does not run
`send()` framing even on a framed Stream. Applications that mix the
method with framed protocols must supply a valid wire format themselves.

## Queue ownership, ordering and errors

The existing native ordered output queue now holds both ordinary byte
segments and file-range segments. A file segment embeds the existing
segment header with an owned duplicated fd and explicit source offset,
so ordinary byte entries did not grow. The normal immediate byte-write
path is unchanged. The queue never writes across a file entry out of order.

A submission makes at most one successful bounded immediate file write
if the queue was empty. Remaining bytes join the queue. Native
`sendfile()` progress handles partial writes, retries interrupted calls,
yields on `EAGAIN`, and treats premature source EOF as a write error.
An active range closes its duplicated fd when consumed. Queue teardown
does the same for any unfinished ranges, including on `close()`,
`close_write()`, write errors/timeouts, and managed-fork child drop.
A moved plain Stream retains its ordered file/byte queue in the child.

All unsent file bytes count toward `pending_bytes`, cooperative high/low
watermarks, `on_drain`, and `max_pending_bytes`, even though they are
not stored in a Perl string. A false flow-control result due to the high
watermark **does not cancel or reject the accepted range**; the producer
must not submit it twice. The hard output limit instead reports the
existing terminal `output_limit` error.

`end()` waits for the queued file and trailing bytes before finishing
the write side; it is not proof that the peer received the data.
`close()` and `close_write()` discard unsent ranges.
`on_drain` signals a watermark crossing, not completion of a particular
file. The usual Stream write timeout applies to a stalled range.

Linux `sendfile()` can generate `SIGPIPE` on a disconnected peer. The
native path uses temporary thread-local signal masking and restores it,
without changing the process-wide signal disposition. Failed transfers
use the existing Stream error and close handling.

## Fairness and performance

A private **64 KiB budget per writable readiness turn** bounds total
file/mixed-queue progress; readiness continues on a later Loop turn.
There is no public file-drain tuning option.

Four isolated native builds (64, 128, 256, 512 KiB) were compared using
actual Linux::Event Streams, SHA-256-verified TCP transfers and a
concurrent 1-ms native Kernel::Timer. The corrected six-trial 16-MiB
sweep found:

| Budget | Throughput (MiB/s) | Sender CPU (ms/MiB) | Timer p95 lateness (ms) |
| --- | ---: | ---: | ---: |
| 64 KiB | 307.39 | 0.2870 | 0.0165 |
| 128 KiB | 307.45 | 0.3048 | 0.0182 |
| 256 KiB | 307.08 | 0.2985 | 0.0158 |
| 512 KiB | 307.87 | 0.3035 | 0.0179 |

A larger budget did not establish a meaningful throughput, CPU or timer
fairness benefit. These are shared-runner observations, not guarantees.
The expensive four-budget sweep is available through the manual
`.github/workflows/stream-sendfile-integration.yml` workflow; ordinary
PRs run a smaller byte-verified Stream benchmark.

Socket output is nonblocking, but reading pages from regular-file
storage can still block during a `sendfile()` syscall. The feature
does not create a general asynchronous disk I/O engine or guarantee
hard latency limits.

## Verified coverage

The merged source contains regressions:

- `t/stream-69-sendfile.t` — ordered file/byte output, ranges, validation,
  backpressure, hard output limits and truncated sources.
- `t/stream-70-sendfile-lifecycle.t` — descriptor cleanup, no-op ranges,
  non-regular/write-only sources, raw framed output, TLS rejection and
  disconnected peers.
- `t/stream-71-sendfile-fairness.t` — native fairness, transition and
  callback interactions.
- `t/stream-72-sendfile-multirange.t` — multiple files and ranges,
  offsets, descriptor ownership, detach safety, graceful EOF.
- `t/stream-73-sendfile-timeout.t` — a blocked file transfer and
  the existing write inactivity deadline.
- `t/stream-74-sendfile-fork.t` — managed-fork child drop and
  `move` of an ordered file/byte queue.
- `t/stream-75-sendfile-drain-reentrancy.t` — `on_drain` submitting
  a second file and terminal marker; empty-source cases.

The exact pre-merge feature head `955a0622c56841779fd16fdc37fe0548cd04048a`
passed [all ten CI jobs](https://github.com/haxmeister/perl-linux-event/actions/runs/41166889428)
and the [actual Stream sendfile benchmark](https://github.com/haxmeister/perl-linux-event/actions/runs/41166889422).
The post-merge `main` [CI run](https://github.com/haxmeister/perl-linux-event/actions/runs/41208249334)
also passed. Performance experiments include comparisons to bounded Perl
file-read/`write()` production and to preloaded byte writes, with
receiver-side byte integrity verification.

This feature is merged and complete; `splice()` remains separate research.
No 0.118 GitHub release or CPAN upload is implied by the merge.
