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

When in doubt, use the decision filter at the end of
`docs/ECOSYSTEM-CHARTER.md`.
