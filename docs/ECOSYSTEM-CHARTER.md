# Linux::Event Ecosystem Charter

This document defines the long-term direction of the Linux::Event ecosystem.
These rules are architectural constraints, not temporary preferences. New work
should be evaluated against them before implementation begins.

## Mission

Linux::Event is a Linux-native communications engine for Perl.

Its purpose is to make Perl exceptionally good at speaking many protocols,
moving messages efficiently, and bridging communication between systems.
Linux::Event should make those capabilities easy to combine without becoming
an application framework.

## 1. Core is the performance engine

Linux::Event core is where aggressive performance work belongs.

Optimize reusable low-level functionality when the improvement can benefit
multiple upper layers. Examples include:

- event dispatch and watcher machinery
- streams and datagrams
- buffering and framing primitives
- write queues and backpressure
- connection lifecycle
- timers and timeouts
- TLS integration
- request/response correlation primitives
- multiplexing primitives
- local IPC
- introspection and diagnostics that can remain off hot paths

Performance work in core should be measured carefully because improvements
there can compound across the entire ecosystem.

## 2. Protocol layers optimize for correct, easy use

Protocol distributions should prioritize, in this order:

1. correctness
2. ease of correct use
3. a clear and consistent public API
4. maintainability
5. composability and bridgeability
6. good performance

Maximum benchmark performance is not the primary goal of protocol-specific
code. Protocol-specific XS, C, or other specialized optimization should be
added only when realistic benchmarks demonstrate a material bottleneck.

A protocol that is comfortably fast, correct, easy to use, and easy to
maintain is successful even if another implementation wins a microbenchmark.

## 3. No Net umbrella

Protocol distributions live directly under the Linux::Event namespace.
Examples include:

    Linux::Event::HTTP
    Linux::Event::WebSocket
    Linux::Event::MQTT
    Linux::Event::DNS
    Linux::Event::Redis

They may remain separate CPAN distributions. Namespace simplicity does not
require combining them into the Linux-Event core distribution.

Do not introduce Linux::Event::Net as an umbrella namespace.

## 4. Linux::Event owns its public API

Third-party libraries are implementation details.

Linux::Event protocol APIs should remain simple, coherent, and consistent even
when parsing, encoding, standards handling, compression, serialization, or
other machinery is supplied by another CPAN distribution.

A dependency must not be allowed to force an awkward public API merely because
its own object model or callback model is convenient internally. Wrap it when
needed. Reject it when a clean wrapper is not practical.

Users should be able to change as little code as practical if an underlying
implementation dependency is replaced later.

## 5. Reuse the Perl community's work

Prefer using suitable existing CPAN libraries rather than reimplementing every
protocol detail from scratch.

When evaluating dependencies, consider:

- correctness and standards compliance
- API fit and ability to hide implementation details
- maturity and real-world use
- maintenance history
- documentation
- licensing
- dependency weight
- compatibility with Linux::Event's architecture
- performance when it materially affects realistic workloads

Bias toward established and commonly used community modules when they are a
good technical fit. A modest performance advantage is not, by itself, a reason
to replace mature community work with custom code.

## 6. Maintainer relationships matter

Dependency selection is not a purely technical leaderboard.

Strongly prefer suitable modules maintained by authors with whom the Linux::Event
maintainer has had friendly, constructive communication. Supporting those
projects is a positive selection factor and is part of participating in the
Perl community rather than merely consuming it.

A module may be rejected because of a strongly negative maintainer relationship,
even when doing so requires choosing another implementation or building the
needed functionality locally.

Do not infer personal judgments about maintainers. Use the Linux::Event
maintainer's stated experience and preferences when specific modules or authors
are evaluated.

## 7. Bridgeability is a first-class design goal

Protocol APIs should make it straightforward to receive meaningful data from
one protocol and send it through another.

Do not force every protocol into one universal message class. Preserve useful
protocol-specific types and semantics, but make common payloads and operations
obvious to access.

When reviewing a protocol API, ask:

    How difficult is it to take useful data received here and send it through
    another Linux::Event protocol?

An API that makes this unnecessarily difficult should be reconsidered.

## 8. Do not become an application framework

Linux::Event should provide communication machinery, not dictate application
architecture.

Appropriate territory includes transports, protocol clients and servers,
connection pools, framing, codecs, state machines, TLS, backpressure,
reconnection, keepalive, multiplexing, and related communication concerns.

Application-framework concerns such as MVC, templates, ORMs, controller
hierarchies, routing frameworks, and framework-wide middleware systems are not
the goal.

A useful boundary test is:

    Does this feature help two endpoints communicate, or does it tell the
    programmer how to structure the application?

Favor the former. Leave the latter to application frameworks.

## 9. Optimize once when possible

Prefer performance work whose benefit can be reused across protocols.

An optimization that improves Stream, framing, buffering, backpressure, TLS,
or another shared primitive deserves more attention than an equally sized
optimization that benefits only one uncommon operation in one protocol.

Before adding protocol-specific complexity, ask whether the same effort could
improve a reusable lower layer instead.

## 10. Capability demonstrations are tests, not destinations

Applications that exercise many communication patterns are useful capability
tests for the ecosystem, but they do not define its endpoint.

For example, a Discord client or bot is useful because it exercises HTTP,
WebSocket, TLS, DNS, compression, reconnect logic, heartbeats, timers, rate
limits, and stateful messaging. Linux::Event does not exist specifically to
build Discord software.

The larger goal is a system that can speak many protocols cleanly and make them
easy to combine.

## Decision filter

Before substantial ecosystem work, ask:

1. Does this improve communication?
2. If it is low-level work, can multiple protocols benefit from it?
3. Can suitable community work be reused without compromising our API?
4. Does the common case become easier to use correctly?
5. Does the design preserve or improve bridgeability?
6. Are we adding complexity for a measured real-world need rather than a
   benchmark trophy?

If a proposal repeatedly fails these questions, it probably does not belong in
Linux::Event.
