# Linux::Event Handoff

Before doing architectural, performance, dependency, or ecosystem work in this
repository, read `docs/ECOSYSTEM-CHARTER.md` first.

That charter is authoritative. Local benchmark goals, experiments, or short-term
implementation convenience must not override it.

Current strategic direction:

- Linux::Event core is the reusable high-performance communications engine.
- Performance work in core should favor improvements that benefit many upper
  layers.
- Protocol distributions should prioritize correctness, simple APIs,
  maintainability, composability, and ease of correct use.
- Protocols live directly under `Linux::Event::*`; there is no `Linux::Event::Net`
  umbrella.
- Reuse suitable CPAN/community libraries where practical while preserving a
  simple Linux::Event-owned public API.
- Maintainer relationships are a legitimate dependency-selection criterion;
  prefer projects and authors the Linux::Event maintainer wants to support.
- Bridgeability between protocols is a first-class design goal.
- Do not drift into building a full web/application framework.
- Protocol-specific native optimization requires realistic evidence of a
  material bottleneck.

## Next priority: runtime deployment configuration

The next Linux::Event core design/implementation task is to make deployment-time
configuration available without giving up subclass-cached defaults or adding
steady-state hot-path overhead.

The design principle is:

> Subclasses define reusable defaults and structural policy. Listener/server
> instances may override deployment configuration, and individual live streams
> may override tunable byte-I/O policy.

Precedence should be:

1. subclass defaults;
2. listener/server-instance overrides;
3. individual connection runtime tuning.

### Stream tuning

Keep `stream_options()` as the subclass-level default mechanism, but add
instance-level effective tuning. Preferred public APIs are:

```perl
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop          => $loop,
    stream_class  => 'MyConnection',
    host          => $host,
    port          => $port,
    stream_tuning => {
        read_size         => $read_size,
        read_budget_bytes => $read_budget,
        read_timeout      => $read_timeout,
        idle_timeout      => $idle_timeout,
        high_watermark    => $high_watermark,
    },
);
```

and, for an already-created connection:

```perl
$stream->tune(
    read_size         => 262_144,
    read_budget_bytes => 1_048_576,
    idle_timeout      => 30,
);
```

The mutable set should include the existing ordered-byte tuning values that are
reasonably deployment/runtime policy, including:

- `read_size`
- `read_budget_bytes`
- `read_batch_bytes`
- `message_batch_size`
- `high_watermark`
- `low_watermark`
- `max_pending_bytes`
- `max_buffer`
- `idle_timeout`
- `read_timeout`
- `write_timeout`

Implement this so effective numeric tuning lives in per-stream native state.
Class descriptors remain the source of defaults and structural policy, but the
hot read/write path must not perform Perl hash lookups, method calls, or an
"override present?" branch. The expected steady-state cost of runtime tunability
should therefore be zero or effectively zero; tuning cost is paid only when
construction or `tune()` changes a value.

Runtime changes must have explicit transition semantics. In particular:

- changing `message_batch_size` should deterministically resolve any partial
  current batch before installing the new policy;
- changing watermarks should immediately reconcile backpressure state;
- lowering `max_pending_bytes` or `max_buffer` should not silently discard
  already-buffered data; define the new limit as applying to subsequent growth
  unless a safer explicit rule is chosen;
- changing timeout values should re-arm/cancel the relevant deadline state as
  needed.

Framer type, callback structure, and native-consumer identity are structural
connection-class policy and are not part of ordinary runtime tuning.

### Listener deployment tuning

Listener-owned settings such as `backlog`, `max_accept_per_tick`,
`edge_triggered`, `reuseaddr`, `reuseport`, `v6only`, and `bind_device` already
belong on the Listener constructor. Preserve that model. A command-line server
should be able to map deployment options directly into Listener construction.

### Runtime TLS configuration

The current subclass-only TLS declaration is insufficient for generic server
executables that receive certificate paths and related settings from command
line arguments or configuration files.

Preserve `use Linux::Event::TLS ...` as a convenient subclass/default policy,
but add a public Listener/server-instance override path. Preferred shape:

```perl
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop         => $loop,
    stream_class => 'MyConnection',
    host         => $host,
    port         => $port,
    tls          => {
        cert_file         => $cert_file,
        key_file          => $key_file,
        ca_file           => $ca_file,
        alpn              => ['http/1.1'],
        handshake_timeout => $handshake_timeout,
        shutdown_timeout  => $shutdown_timeout,
    },
);
```

The Listener must turn this into reusable TLS server configuration while each
accepted connection still receives independent OpenSSL/TLS connection state.
Listener-supplied TLS configuration overrides subclass TLS defaults for that
Listener. Do not require runtime package generation, `BEGIN`-time command-line
parsing, or private API use.

TLS identity/handshake settings such as certificate/key, verification policy,
CA sources, server name, and ALPN are acquisition policy and generally are not
mutable after a connection handshake has completed. Stream tuning underneath
TLS remains independently mutable through `stream_tuning` / `tune()`.

### Keep protocol policy out of core

Do not copy every option exposed by higher-level servers into Linux::Event core.
For example:

- `backlog` is Listener/kernel policy and belongs in core;
- generic read/write/idle byte-I/O timeouts belong in Stream tuning;
- TLS certificate/key paths belong in Listener TLS acquisition configuration;
- HTTP `max_requests` is server/application lifecycle policy and belongs in the
  HTTP/server layer, not Linux::Event core;
- HTTP keepalive timeout is protocol-state policy and should normally belong in
  the HTTP layer rather than being confused with generic Stream `read_timeout`.

The motivating requirement is that a Starman-style or other reusable server
executable must be able to accept deployment arguments for socket tuning,
stream tuning, and TLS material without encoding those values into Perl
subclasses.

When in doubt, use the decision filter at the end of
`docs/ECOSYSTEM-CHARTER.md`.
