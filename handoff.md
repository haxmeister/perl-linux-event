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

## Current work: remove core multiple inheritance

Development branch:

```text
refactor/remove-core-multiple-inheritance
```

The private behavioral hierarchy now uses single inheritance. In particular,
`Linux::Event::_Socket::Stream` inherits only
`Linux::Event::_ByteStream`. Socket descriptors, connection acquisition,
configuration, addresses, and transports remain explicitly composed
facilities; `_Socket::Stream` does not inherit `_Socket` merely to express a
conceptual category.

The affected Stream implementations are organized into demarcated sections in
this order:

1. constructors and class lifecycle;
2. accessors;
3. methods;
4. private helpers and internal overrides.

`tune()` now lives with the other `_ByteStream` public methods rather than in a
trailing package reopening inside `_ByteStream/Descriptor.pm`.

Public Stream subclasses may initialize, store, and expose their own ordinary
instance variables. Linux::Event does not interpret or manage that state. Do
not add an `init`, `state`, initialization callback, role, mixin, or similar
core mechanism for subclass-owned state.

Tests enforce one direct behavioral parent for the private IO layers and cover
subclass-owned state across normal Stream teardown. The full suite passes: 157
files and 2,902 tests, with the two expected Unix-socket sandbox skips. Rerun
the suite after any further edits before merging.

## Completed priority: Listener stream recipes, runtime tuning, and runtime TLS

This is the next implementation task. The API design has been discussed and is
considered settled enough to implement without reopening the basic model.

The core mental model is:

> A Listener is a stream generator.

The Listener constructor configures listening and acceptance. Its `stream => {}`
recipe describes the `Linux::Event::IO::Sock::Stream` objects it generates.

The intended public shape is:

```perl
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop    => $loop,
    host    => '0.0.0.0',
    port    => 443,

    backlog             => 8_192,
    max_accept_per_tick => 512,

    stream => {
        class => 'My::Connection',

        tuning => {
            read_size         => 131_072,
            read_budget_bytes => 524_288,
            idle_timeout      => 30,
        },

        tls => {
            cert_file => $cert_file,
            key_file  => $key_file,
        },

        on_data => sub ($stream, $bytes) {
            # application callback
        },
    },

    on_accept => sub ($listener, $stream) {
        # Listener callback
    },
);
```

The implementation must preserve Linux::Event's existing hot-path performance
principles. Recipe/configuration work is resolved up front. Accepted connections
must not repeatedly parse or merge the recipe during ordinary I/O.

## 1. Listener owns Listener settings

These remain top-level Listener constructor settings because they configure the
listening resource itself:

- `loop`
- `host`
- `port`
- `unix`
- `fh`
- `backlog`
- `max_accept_per_tick`
- `edge_triggered`
- `reuseaddr`
- `reuseport`
- `v6only`
- `bind_device`
- Unix listener ownership/permissions settings
- Listener callbacks such as `on_accept`

Do not move Listener/socket-accept policy under `stream`.

## 2. `stream => {}` is the generated-Stream recipe

The current `stream_class => ...` plus accepted-Stream constructor-template
arguments should be replaced/coherently reorganized under a single nested
`stream` recipe.

The recipe should support at least:

```perl
stream => {
    class   => 'My::Connection',
    tuning  => { ... },
    tls     => { ... },
    data    => $initial_data,

    on_data            => sub { ... },
    on_message         => sub { ... },
    on_messages        => sub { ... },
    on_ready           => sub { ... },
    on_transport_ready => sub { ... },
    on_drain           => sub { ... },
    on_eof             => sub { ... },
    on_error           => sub { ... },
    on_close           => sub { ... },
}
```

`class` is optional. If omitted, default to:

```perl
Linux::Event::IO::Sock::Stream
```

This allows a useful server without requiring a user-defined subclass:

```perl
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 9999,

    stream => {
        on_data => sub ($stream, $bytes) {
            $stream->write($bytes);
        },
    },
);
```

Subclassing remains the reusable/powerful path for framing, named callbacks,
protocol policy, and class defaults, but it must not be mandatory boilerplate
for a simple raw stream server.

## 3. Preserve existing Stream validity checks

The easier Listener API must not weaken callback/framer correctness.

A default raw `Linux::Event::IO::Sock::Stream` still requires an effective
`on_data` sink. Therefore this should fail during Listener construction, before
accepting connections:

```perl
stream => {}
```

A framed Stream class still requires the correct effective message sink according
to its existing framing/batching/native-consumer rules. Recipe callbacks may
satisfy those requirements exactly as constructor callbacks do now.

Move/extend validation so the Listener can validate its resolved stream recipe
up front rather than discovering a predictable configuration error only after
the first accept.

Do not redesign framing in this task. Framing remains class-level structural
policy using the existing `Linux::Event::Framer` declaration mechanism.

## 4. Rename `stream_options()` to `stream_tuning()`

Mixing `options` and `tuning` for the same values will become confusing once
Listener and live-object overrides exist.

Rename the subclass method:

```perl
sub stream_options ($class) { ... }
```

to:

```perl
sub stream_tuning ($class) {
    return (
        read_size         => 65_536,
        read_budget_bytes => 262_144,
        idle_timeout      => 60,
    );
}
```

The word `tuning` is specifically for adjustable operating parameters. Do not
blindly rename unrelated APIs such as `socket_options()`; socket options may
represent behavior/configuration rather than merely performance tuning.

The current ordered-byte tuning set includes:

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

## 5. Listener Stream tuning overrides

`stream_tuning()` supplies class defaults. The Listener stream recipe may
override them for every Stream generated by that Listener:

```perl
stream => {
    class => 'My::Connection',

    tuning => {
        read_size         => $read_size,
        read_budget_bytes => $read_budget,
        idle_timeout      => $idle_timeout,
    },
}
```

The effective precedence is:

1. `stream_tuning()` class defaults;
2. `stream => { tuning => { ... } }` Listener recipe overrides;
3. `$stream->tune(...)` live-object overrides.

## 6. Add `$stream->tune(...)`

A live Stream may change its effective tuning:

```perl
$stream->tune(
    read_size         => 262_144,
    read_budget_bytes => 1_048_576,
    idle_timeout      => 30,
);
```

Implement effective mutable tuning in per-Stream native state rather than
performing per-I/O override lookup against the class descriptor.

The hot read/write path must not add:

- Perl hash lookups;
- method calls;
- an `override present?` branch;
- recipe parsing;
- class-vs-instance resolution.

The expected steady-state performance cost of runtime tunability is therefore
zero or effectively zero. Cost is paid when the Stream is constructed or when
`tune()` is explicitly called.

Runtime tuning needs deterministic state-transition behavior:

- changing `message_batch_size` must safely resolve a partial batch before the
  new policy takes effect;
- changing high/low watermarks must immediately reconcile backpressure state;
- lowering `max_pending_bytes` or `max_buffer` must not silently discard data
  already queued/buffered; define a safe rule for subsequent growth;
- changing timeout values must re-arm/cancel relevant deadline state as needed.

Framer identity, callback structure, native-consumer identity, and transport
kind are not live `tune()` values.

## 7. Every Sock::Stream is TLS-capable, but TLS is dormant unless selected

Do not require users to create a special TLS Stream class.

Conceptually every `Linux::Event::IO::Sock::Stream` can use either the native
plain transport or the built-in TLS transport. Plain Streams must allocate no
TLS/OpenSSL connection state and must not pay TLS setup cost.

TLS is selected as acquisition policy for the generated Stream:

```perl
stream => {
    tls => {
        cert_file => $cert_file,
        key_file  => $key_file,
    },

    on_data => sub ($stream, $bytes) {
        ...
    },
}
```

The same Stream class can therefore be generated plain by one Listener and over
TLS by another:

```perl
my $plain = Linux::Event::IO::Sock::Listener->new(
    port => 80,
    stream => {
        class => 'My::HTTPConnection',
    },
);

my $secure = Linux::Event::IO::Sock::Listener->new(
    port => 443,
    stream => {
        class => 'My::HTTPConnection',
        tls => {
            cert_file => $cert_file,
            key_file  => $key_file,
        },
    },
);
```

TLS is transport/acquisition policy, not protocol-class identity.

## 8. Ordinary users should not need `use Linux::Event::TLS`

The old compile-time form:

```perl
use Linux::Event::TLS ...;
```

should no longer be the normal public configuration path.

`Linux::Event::TLS` remains the OpenSSL transport implementation/provider and
may be loaded lazily by Sock::Stream/Listener internals when TLS is requested.

If class-level reusable TLS defaults are retained, expose them as an ordinary
class method rather than magical compile-time declaration. The discussed name
is:

```perl
sub tls_defaults ($class) {
    return (
        verify            => 1,
        alpn              => ['http/1.1'],
        handshake_timeout => 10,
        shutdown_timeout  => 5,
    );
}
```

`tls_defaults()` supplies defaults only; it does not need to force every use of
the class to use TLS. TLS activation belongs at the acquisition site.

The exact `tls_defaults()` name can be adjusted during implementation if a
clearly better name emerges, but do not return to requiring `use
Linux::Event::TLS` merely to make a Sock::Stream TLS-capable.

## 9. Listener-owned prepared TLS server context

Runtime TLS must not sacrifice the performance advantages of the current native
transport design.

The current implementation creates a fresh TLS provider per accepted connection
and currently rebuilds `SSL_CTX` / reloads certificate material in that path.
The new Listener model should improve this.

At Listener construction:

1. resolve class TLS defaults, if any;
2. merge `stream => { tls => { ... } }` deployment overrides;
3. validate the effective server TLS configuration immediately;
4. create/prepare reusable server-wide OpenSSL context (`SSL_CTX` and associated
   server policy/material);
5. retain that prepared TLS server context in the resolved Listener stream
   recipe.

For each accepted TLS connection:

1. allocate only the independent per-connection TLS/`SSL` state required for
   that connection;
2. bind it to the accepted fd;
3. attach it through the existing native Stream transport ABI;
4. run handshake/read/write/shutdown through the native transport hot path.

Do not perform TLS configuration merging, certificate-file parsing, or Perl
policy lookup during ordinary reads/writes.

This should preserve steady-state TLS performance and may improve high-churn TLS
accept performance because certificate/key/context setup is no longer repeated
for every accepted connection.

Add a benchmark that compares current TLS accept/connection setup against the
new Listener-prepared-context design in addition to preserving existing TLS
steady-state benchmarks.

## 10. Resolve the stream recipe once

`stream => {}` is a public configuration hash, not something the native accept
hot path should repeatedly interpret.

During Listener construction, resolve it into an internal prepared stream
recipe containing what accept actually needs, such as:

- resolved Stream class/class descriptor;
- validated effective callback CVs/templates;
- effective initial tuning template;
- prepared TLS server configuration/context when enabled;
- initial data policy;
- any other already-normalized construction state.

Accepted Streams should be instantiated from this prepared recipe with minimal
work. Do not introduce per-accept package generation or per-message dynamic
configuration lookup.

## 11. Keep protocol/server policy out of Linux::Event core

Do not copy every option exposed by Starman or another higher-level server into
core.

Examples:

- `backlog` -> Listener/kernel policy, core;
- generic read/write/idle byte-I/O timeouts -> Stream tuning, core;
- TLS certificate/key paths -> generated-Stream acquisition configuration,
  core;
- HTTP keepalive timeout -> HTTP protocol/server layer;
- HTTP/server `max_requests` / worker recycling -> higher server/process layer,
  not Stream tuning.

The motivating requirement is that a reusable server executable can accept
command-line/config-file deployment values for listening, Stream tuning, and TLS
without encoding deployment values into Perl subclasses.

## 12. Framing is explicitly out of scope for this implementation

It is theoretically possible to resolve a Listener-supplied framing recipe into
prepared native descriptor state without a steady-state framing penalty, but do
not do that in this task.

Keep the existing subclass-based `Linux::Event::Framer` API unchanged while
implementing this work. Revisit framing separately only if there is a concrete
usability reason later.

## Suggested implementation order

1. Update tests/POD terminology from `stream_options()` to `stream_tuning()` and
   keep the descriptor caching behavior intact.
2. Move mutable effective ordered-byte tuning into per-Stream native state and
   add `$stream->tune(...)`; benchmark for no steady-state regression.
3. Introduce Listener `stream => {}` with default
   `Linux::Event::IO::Sock::Stream`, recipe callbacks, data, and `tuning`.
4. Move accepted-Stream validation to resolved Listener-recipe construction so
   invalid raw/framed callback combinations fail before accept.
5. Add acquisition-time TLS selection through `stream => { tls => ... }` without
   requiring a TLS-declared Stream subclass.
6. Introduce a Listener-owned prepared TLS server context and per-connection TLS
   state creation from it.
7. Remove `use Linux::Event::TLS` from normal examples/documentation and, if
   retained, replace class TLS declaration semantics with ordinary defaults
   (`tls_defaults()` or a better final name).
8. Update Listener, Stream, TLS, README, design docs, examples, and tests to teach
   the stream-generator model prominently.
9. Run full test suite and existing Stream/TLS benchmarks plus a TLS
   accept/connection-setup benchmark before considering the work complete.

Do not redesign framing as part of this implementation.

When in doubt, use the decision filter at the end of
`docs/ECOSYSTEM-CHARTER.md`.
