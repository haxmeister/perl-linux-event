# Stream/timer fairness investigation

Date: 2026-09-19

Branch: `investigate/stream-timer-fairness`

Status: **root cause confirmed; candidate fix identified; no runtime default has
been changed on this branch.**

## Trigger

Linux::Event::WebSocket's external echo benchmark exposed nominal 1.5-second
Linux::Event timers being delayed by tens of seconds under sustained traffic.
The WebSocket benchmark's wall-clock workaround made its measurements valid but
left the core scheduling problem unresolved.

This investigation reproduces the problem using Linux::Event core only.

## Root cause

The shared ordered-byte read engine supports `read_budget_bytes`, but its
default is zero. Zero means "continue draining successful reads until EAGAIN".

That makes one ordered-byte readiness callback potentially unbounded. If a peer
running concurrently replenishes the receive queue while
`les_read_ready()` is draining it, the Loop can remain inside that single
readiness dispatch long after timerfd, eventfd, pidfd, signalfd, or another
ordinary fd has become ready.

The kernel can mark the Loop's timerfd readable on time, but Linux::Event cannot
service it until the current Stream/Pipe/TTY read drain returns to Loop
dispatch.

This is a general ordered-byte fairness issue, not a WebSocket parser or timer
heap failure.

## Reproducers

### One-way saturated producer

`bench/run-stream-timer-fairness.pl` uses a forked blocking producer feeding a
raw AF_UNIX SOCK_STREAM while a one-shot Linux::Event Timer is armed. An outer
parent process supplies a watchdog independent of Linux::Event.

This workload shows the latency tail but does not always prevent EAGAIN long
enough to reproduce severe starvation.

### Feedback-window reproducer

`bench/run-stream-feedback-timer-fairness.pl` is the decisive reproducer. It
uses:

- one Linux::Event Fixed-frame Stream;
- one forked blocking AF_UNIX echo peer;
- 64-byte messages;
- a 32-message in-flight window;
- immediate replacement of each echoed message from `on_message`;
- a nominal 1.5-second Linux::Event Timer;
- an outer process watchdog independent of the Loop.

This is the core-only analogue of the WebSocket workload that originally
exposed the problem.

## Feedback-window results

GitHub Actions run: `35409047873`

Runner result, three measured repeats after warmup:

| read budget | median timer lateness | median message rate | median read-ready calls | median bytes/readiness |
| ---: | ---: | ---: | ---: | ---: |
| unlimited (0) | 1556.807 ms | 211,859 msg/s | 4 | 12,018,536 |
| 16 KiB | 1.459 ms | 216,848 msg/s | 1,272 | 16,380 |
| 32 KiB | 2.848 ms | 215,982 msg/s | 634 | 32,693 |
| 64 KiB | 7.930 ms | 215,377 msg/s | 321 | 65,164 |
| 128 KiB | 15.539 ms | 216,771 msg/s | 161 | 130,576 |
| 256 KiB | 30.904 ms | 214,014 msg/s | 81 | 259,447 |

The unlimited samples were 1681.237 ms late and 1432.377 ms late; the third
measured case exceeded the independent five-second watchdog and was terminated.

Finite budgets did not reduce throughput in this feedback workload. All finite
rows remained around 214k-217k messages/second.

## Representative payload sweep

The existing `run-stream-payload-sweep.pl` was extended on this investigation
branch so `read_size` and `read_budget_bytes` can be varied independently.
The established payload sweep then held `read_size=64 KiB` constant and tested
64 B, 4 KiB, 32 KiB, and 200,000 B in raw and Delimiter-framed modes.

Median MiB/s:

| budget | raw 4 KiB | raw 32 KiB | raw 200k | delimiter 4 KiB | delimiter 32 KiB | delimiter 200k |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| unlimited | 1,285.8 | 1,229.7 | 4,135.9 | 511.1 | 1,145.0 | 2,696.3 |
| 16 KiB | 3,451.1 | 3,360.3 | 3,417.1 | 1,806.7 | 3,042.0 | 2,403.0 |
| 32 KiB | 5,222.0 | 4,779.9 | 4,487.9 | 2,189.4 | 3,802.6 | 3,710.9 |
| 64 KiB | 7,241.4 | 7,263.0 | 7,742.2 | 2,697.0 | 4,747.7 | 4,702.7 |
| 128 KiB | 8,068.2 | 7,800.7 | 8,386.9 | 2,692.2 | 4,979.6 | 4,539.1 |
| 256 KiB | 2,494.9 | 2,706.6 | 8,489.7 | 2,192.1 | 3,311.0 | 4,457.3 |

Hosted-runner scheduling makes the absolute one-way throughput numbers noisy,
so small row-to-row differences must not be overinterpreted. The useful signal
is the broad knee: 16/32 KiB materially underperform on medium/large payloads,
64 KiB reaches the high-throughput region, and 128 KiB offers only modest
additional raw throughput while approximately doubling feedback timer
lateness. 256 KiB is clearly too loose as a general fairness default.

The 64-byte framed rows were effectively flat across finite budgets, roughly
83-88 MiB/s.

## Candidate fix

The measured best default balance is:

```perl
read_budget_bytes => 65_536
```

That is also the current default `read_size`, so the ordinary default path
normally yields after approximately one full successful 64 KiB read instead of
draining indefinitely.

Keep `read_budget_bytes => 0` as an explicit opt-in for callers that knowingly
want drain-until-EAGAIN behavior.

The default should change in the shared ordered-byte policy rather than only in
IO::Sock::Stream. The same monopolization mechanism exists for Pipe and TTY
because all three use the same ordered-byte engine.

## Why not the other tested defaults?

- 16 KiB and 32 KiB give tighter timer latency but leave meaningful
  medium/large-payload throughput on the table.
- 128 KiB gives some raw-throughput improvement over 64 KiB, but framed results
  are mostly neutral and feedback timer lateness roughly doubles.
- 256 KiB increases feedback timer lateness to about 31 ms with no corresponding
  feedback throughput gain.
- unlimited draining is not an acceptable general default because latency is
  unbounded by Linux::Event and one measured feedback case exceeded the
  independent watchdog.

## Integration decision

**Decision: KEEP**

Change the shared ordered-byte default to:

```perl
read_budget_bytes => 65_536
```

Retain explicit zero as the unlimited drain-until-EAGAIN opt-in.

The 64 KiB default is the measured throughput/fairness knee for the tested
workloads: it removes unbounded Loop monopolization while retaining essentially
all fixed-frame feedback throughput and avoiding the medium/large-payload
throughput losses seen at smaller budgets. The change applies to the shared
ordered-byte engine so Stream, Pipe, and TTY receive the same fairness policy.

The integration updates the public tuning documentation and adds
`t/stream-68-read-fairness.t`, which proves the default yields after one
64 KiB budget with data still queued and explicit zero retains one-turn
drain-until-EAGAIN behavior. The queued-write readiness loop remains a separate follow-up audit;
this decision does not claim that output-side application replenishment has
already been analyzed.

## Evidence retention

The complete machine-readable outputs from run `35409047873` / artifact
`10572949283` (`stream-timer-fairness`) are committed unchanged in this
directory. The branch also retains both reproducer programs and the
payload-sweep enhancement used to produce the results. The corresponding KEEP
decision is recorded in `bench/BENCHMARK-DECISIONS.md`.
