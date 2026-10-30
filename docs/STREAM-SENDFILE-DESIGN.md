# Native Stream file transfers — proposed contract

Status: implementation proposal, awaiting the owner's public API discussion.
Branch: `feature/stream-sendfile`, based on main
`08d775cc2287fb63942c2a27b3a6bfeb59a28aa3` (0.118 unreleased).
The completed syscall research remains on `feature/sendfile-splice-evaluation`
at `a46d77e4c199f7ba9876e5a42ebddd6123fc1af3`, PR #38.
Do not merge either branch, change versions, or prepare a release.

## Proposed public API

```perl
open my $file, '<:raw', $path or die "open $path: $!";

$stream->write($headers);
$stream->sendfile($file);
$stream->write($trailer);
$stream->end;

# Or send a byte range:
$stream->sendfile($file, offset => 1024, length => 4096);
```

Accept an open readable regular-file handle. Do not accept paths or bare fd
numbers in this first API. Default offset is zero, independent of the handle's
current position. Default length is the file's size at submission minus offset.
The range is fixed when accepted: later growth does not extend it. Explicit
offset/length must be nonnegative integers, fit native counters and off_t, and
stay within the observed file size. Zero length is a successful no-op after
argument and stream validation. Unknown options are errors.

Duplicate the descriptor with close-on-exec before accepting the range. The
queue owns that duplicate. The caller can close its original handle immediately;
the transfer continues. Every syscall uses an explicit offset pointer, so the
caller's file position is unchanged. Closing the duplicate on completion does
not close the original. Duplication does not copy the contents or isolate the
transfer from another writer.

Return the same flow-control boolean as write(): false means stop producing
output and use the existing on_drain notification (or inspect an error/closed
stream). It does not mean the accepted range should be submitted again. No
transfer object, required callback, or individual cancellation API initially.
close_write() or close() discards unsent output, including file entries; bytes
already handed to the socket cannot be recalled. end() drains everything first.
on_drain is a watermark event, not file completion or peer acknowledgment.

First implementation: established plain socket Streams, including an adopted
socket before Loop attachment. Reject pending outbound connects clearly; call
from on_ready on a connecting Stream. Ordinary preconnection write() behavior
stays unchanged. Pending connects currently use a Perl array of byte strings,
not the native queue; adding file ownership there would be a separate extension.
No Pipe/TTY public method and no new transport ABI operation are needed.

Reject TLS and every non-plain transport before any file bytes are submitted.
Check the native provider identity as well as public policy. No implicit fallback.
transition_to() retains the transport, so it cannot turn a queued plain transfer
into TLS or bypass an existing TLS provider.

sendfile() is explicitly raw output, like write(), even on a framed Stream.
It does not apply send() framing or treat a file as one message. The application
must provide a valid wire sequence if using raw output with framing. Existing
send() remains the operation that encodes a message. Protocol transitions retain
already accepted output unchanged, including file ranges, as they do today.

## Smallest native integration

Current les_write_seg_t in xsbytestream/stream_internal.h contains an owned SV,
offset, length and next pointer. stream_write.c owns append, consume, queue
cleanup, immediate byte writes and writev readiness draining. The existing
pending_bytes drives watermark state, hard limits, write deadlines, readiness,
graceful end, detach checks and transition limit checks.

Keep the byte-segment layout and allocation size. A file allocation can embed
that header as its first member, with sv == NULL marking a file entry. Its
additional fields hold the duplicated fd and off_t source offset. Reuse the
header length/progress counters with checked conversions; reject ranges that
cannot be represented rather than truncate them. This avoids enlarging every
ordinary byte entry. Validate this representation in the prototype before
treating it as fixed.

The ordered list can then contain headers, file range, trailer, another range.
The writev builder stops at the first file entry. When that entry reaches the
head, the file path calls sendfile. Partial progress updates the source offset,
segment progress, pending_bytes, byte statistics and optional write activity.
Once exhausted, release its fd and continue with the next entry. Never gather
ordinary bytes across a file entry and never issue file output ahead of the head.

les_clear_write_queue and les_consume_written need one shared entry-release rule:
release the SV for bytes, close the owned fd for a file, then free the entry.
This reaches full close, close_write, destructor and managed-fork drop/move
teardown. Preserve SAVEFREESV protection around callback-capable XSUBs. After
on_drain/on_error, re-read native state; never reuse a segment pointer that a
callback might have freed or moved out of the queue.

Keep les_write_submit's ordinary immediate syscall path intact. Mixed-queue
type checks belong in queue draining and cleanup. Do not copy the complete
write engine or add a Perl callback per file chunk. A cached file-entry count
may be useful for selecting a bounded mixed drain; measure its effect on the
ordinary queued-write path rather than claiming literally zero overhead.

## Accounting and fairness

Count all unsent file-range bytes in pending_bytes, although they do not occupy
a Perl byte buffer. Thus a 100 MiB file counts as 100 MiB pending work. Watermarks
remain cooperative and max_pending_bytes remains a limit on queued output, not
resident memory. Check the complete range against that hard limit and UV overflow
before submitting any of its bytes. On hard-limit failure use the existing
terminal output-limit behavior; do not silently trim or defer admission.

Start with a private 64 KiB byte budget per readiness drain containing file
output. Bound total progress through mixed entries for that drain, rather than
resetting the allowance at each file or from each on_drain callback. Yield even
when the socket remains writable. Leave write interest enabled; current Stream
watchers use level-triggered readiness. No new public tuning option initially.
Benchmark this choice against larger budgets with actual Streams and timers.
The normal byte-only immediate-write and readiness behavior should be preserved.

Allow at most one successful bounded immediate file syscall when the queue was
empty. Otherwise append only. Retry EINTR safely, retain position on EAGAIN,
and treat zero return with a nonempty fixed range as premature EOF, not success
or a busy retry. Limit individual requests to Linux's syscall maximum too.
Guard sendfile's SIGPIPE behavior without changing process-wide signal policy;
inspect the existing Process thread-local SIGPIPE handling for a reusable
pattern. Keep any extra signal work confined to the file path and measure it.

## File-system limits

Nonblocking socket capacity does not make regular-file storage asynchronous.
Cold pages, filesystem work or storage faults can still delay the syscall.
Do not promise hard latency bounds or implement an unrelated async disk engine.

Source content must stay immutable until the receiver has consumed it, including
after pending_bytes reaches zero: the kernel may still reference file pages.
Use immutable file versions; replacing a pathname with a new file is different
from rewriting the open source inode. Closing the caller's handle is safe.
Truncation or read errors during transmission fail the Stream and discard its
remaining queue so trailers do not follow an incomplete file as if it succeeded.
Arbitrary in-place edits cannot be reliably detected; document the requirement.

Linux syscall contract reference:
https://man7.org/linux/man-pages/man2/sendfile.2.html

## Implementation and verification sequence

1. Discuss the proposed public contract with the owner, especially raw framing,
   offset-zero default, existing boolean flow control and established-only scope.
2. Implement file entry lifetime and mixed draining, then the Stream wrapper.
   Keep native transport safety checks even when Perl rejects an invalid call.
3. Add correctness regressions: exact headers/file/trailers, alternating ranges,
   multiple files, default/explicit/empty ranges, caller offset preservation,
   original handle close and reuse, forced partial/EAGAIN, EINTR, premature EOF,
   bad source kinds, overflow, hard limits and high/low watermark transitions.
4. Add lifecycle regressions: close/close_write/end, read EOF, detach rejection,
   deadlines, exception/reentrant close from callbacks, destruction, fd counts,
   peer disconnect with default SIGPIPE policy, protocol transition, native
   consumer presence, managed-fork child drop and Stream move, and TLS rejection
   before and after handshake. Verify other resources run while a file drains.
5. Benchmark real Stream sendfile versus bounded file-read/write production and
   a clearly labelled preloaded-byte write control. Verify receiver bytes and
   EOF. Rotate paired cases; report sender and receiver CPU/MiB, end-to-end
   throughput, EAGAIN, timer latency, queue peaks and syscall counts. Use 64 B,
   256 B, 1 KiB, 4 KiB, 16 KiB, 32 KiB, 64 KiB, 128 KiB, 200 KiB, 1 MiB and a
   larger file, plus a deliberately slow receiver. No new standalone research.
6. Run the full source suite and PR CI: eight Perl configurations, distribution
   integrity and existing ordinary-write performance regression. Add actual
   file-transfer benchmark CI and a repeatable quad-core runner as appropriate.
7. Update public POD/examples and handoff with approved behavior, exact tested
   commits and measured results. Record the implementation benchmark decision.
   Leave main and the unreleased version unchanged.

No implementation or new performance result is claimed by this design checkpoint.
