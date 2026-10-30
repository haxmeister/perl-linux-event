# Experimental recvmmsg() receive batching (2026-10-30)

## Scope and status

Research branch: `feature/udp-recvmmsg-evaluation`, based on unreleased
Linux::Event 0.118 main commit `08d775cc2287fb63942c2a27b3a6bfeb59a28aa3`.
**Nothing has been merged into main, version bumped, tagged or released.**

This prototype changes **only the native receive engine** in
`xsdatagram/Datagram.xs`. It does not add an application API or implement
`sendmmsg()`. The switch is a private benchmark environment variable:

```sh
LINUX_EVENT_EXPERIMENT_RECVMMSG=0   # ordinary repeated recvmsg (default)
LINUX_EVENT_EXPERIMENT_RECVMMSG=8   # ask for up to 8 packets per recvmmsg
LINUX_EVENT_EXPERIMENT_RECVMMSG=32  # ask for up to 32
```

The same `_recv_batch(fd, max_size, max_count)` return contract is preserved.
The implementation bounds temporary scratch storage to 256 KiB and at most
32 packet slots. Large `max_datagram_size` settings (over 256 KiB) retain
`recvmsg` instead. The `max_datagrams_per_tick` bound still controls
each native receive drain, including unlimited (0) drains until EAGAIN.
Zero-length payloads, sockaddr bytes, datagram ordering, `MSG_TRUNC` actual
length and oversize reporting are preserved.

## Verification completed

[CI run 41133039427](https://github.com/haxmeister/perl-linux-event/actions/runs/41133039427)
and [run 41133285661](https://github.com/haxmeister/perl-linux-event/actions/runs/41133285661)
passed the focused Datagram tests across switch settings 0, 8 and 32.
The suite includes the direct XS packet/fairness/truncation/zero-byte regression,
existing UDP echo, limits, ownership/Unix, and smoke tests.

The paired queued-burst driver
`bench/experiments/udp-recvmmsg-burst.pl` sends real loopback datagrams,
prequeues a bounded burst, and measures native receive CPU around
`_recv_batch`, with packet sequence validation on every packet.

The public Loop driver
`bench/experiments/udp-recvmmsg-loop.pl` routes all packets through epoll,
`Linux::Event::IO::Sock::Dgram` and the normal `on_datagram` callback.
It measures CPU around the real public `run_once(0)` receive drain, and
compares both payload-sized `max_datagram_size` and the default 65,535
bytes. Results are JSONL with three repeats per configuration. Test packets
were 64, 512, 1400, and 8192 bytes; batch lengths 8 and 32 (8192-byte
packets use 8 for bounded receiver queue pressure).

Both CI drivers completed all tested UDP packets with no losses or callback
corruption.

## Initial CI data — 3-trial median CPU around receive drain

| Payload | Burst | Normal max datagram size | recvmsg (us/packet) | recvmmsg 8 | recvmmsg 32 |
| --- | ---: | --- | ---: | ---: | ---: |
| 64 B | 8 | default | 6.765 | 6.460 | 6.376 |
| 64 B | 32 | default | 5.587 | 5.263 | 5.263 |
| 64 B | 32 | payload-sized | 5.517 | 5.128 | 5.107 |
| 512 B | 32 | default | 5.599 | 5.304 | 5.305 |
| 512 B | 32 | payload-sized | 5.565 | 5.236 | 5.173 |
| 1400 B | 32 | default | 5.667 | 5.382 | 5.443 |
| 1400 B | 32 | payload-sized | 5.677 | 5.301 | 5.263 |
| 8192 B | 8 | default | 8.002 | 7.527 | 7.543 |

Full measurements, additional payload/burst settings, per-trial variance
and separate native-only receive comparisons are captured as workflow
artifact `udp-recvmmsg-ci-comparison` in CI run 41133285661.
The native-only receive operation showed roughly 10-37% less CPU per packet,
while the complete Loop plus callback path showed roughly 1.5-8% better
CPU-derived processing rate in all 14 measured settings. Native-only gains
do **not** translate directly into an application throughput claim.

### Important interpretation

- These are controlled, prequeued local UDP bursts, not streaming load over
  real networks. The sender is not timed in the receive-only CPU metric.
- Serial ping-pong generally offers only one waiting packet and **does not
  reliably benefit** from receive batching; the one-repeat serial CI
  sanity checks varied by a few percent in either direction.
- GitHub Actions shared runners are noisy. No claim of production improvement
  or a new core default should be based on these results alone.
- The 256-KiB memory cap means that the usual 65535-byte receive buffer
  limits each recvmmsg call to 4 packets, even with a 32-packet switch.
- Datagram callbacks remain once per packet; no multi-packet public API.

## Local repeat after CI

From the checked-out repository:

```sh
git fetch origin
git switch feature/udp-recvmmsg-evaluation
git pull --ff-only
perl Makefile.PL
make -j4
perl -Mblib bench/experiments/udp-recvmmsg-loop.pl \
  --rounds 2000 --repeats 5 --sizes 64,1400,8192 \
  --bursts 8,32 --modes 0,8,32 --max-sizes payload,default \
  --output bench/results/udp/recvmmsg-quad.jsonl
```

That one JSONL file is sufficient for comparison. Do not run as root or
change system settings. Keep other CPU-intensive workloads idle.

## Decision criteria before merge

Confirm full general CI, a repeated quad-core paired result, and performance
under both bursty and sparse traffic. Avoid applying the private environment
flag to normal programs until the tradeoffs and optimal slot policy are
established. Keep `sendmmsg()` evaluation independent: the existing immediate
send path may not benefit until outgoing packets actually queue.
