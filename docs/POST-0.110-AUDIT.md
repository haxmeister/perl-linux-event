# Post-0.110 public-surface audit

This audit was performed after Linux::Event 0.110 was released because several
source files still showed older last-modified dates and the release work had
not included a complete semantic review of every current documentation surface.

## Scope

Reviewed surfaces include:

- README and every current production document under `docs/`;
- public module POD and examples;
- benchmark documentation and comparison plans;
- Loop introspection type names and tests;
- distribution metadata/manpage exposure for retained private implementation
  packages.

Historical records such as `Changes` entries for old releases and
`docs/DEVELOPMENT-HISTORY.md` are intentionally allowed to describe the API that
existed at the time.

## Findings

The audit found real post-release inconsistencies:

- Loop introspection still classified public resources with the retired
  `stream/listener/datagram/wakeup` taxonomy and exposed `stream_kind`.
- `docs/INTROSPECTION.md` documented those obsolete type names.
- several current design documents still described the IO/Kernel architecture
  as an unfinished migration or pre-release plan;
- benchmark documentation still presented retained historical implementation
  classes as the public benchmark surface;
- retained `no_index` implementation modules can contain historical embedded
  POD even though they are not public providers.

## Corrections

The follow-up work:

- aligns `census()`, `inspect()`, and `why_alive()` type reporting with public
  `IO::*` / `Kernel::*` semantics;
- gives Pipe and TTY distinct introspection types and uses `dgram` and `event`
  for the public Dgram and Event leaves;
- removes the redundant historical `stream_kind` inspection field;
- rewrites current architecture, lifecycle, Event, Timer, Signal, Process,
  Dgram, Listener, transport, ordered-byte, consumer-ABI, introspection, and
  benchmark documentation in present tense;
- makes benchmark documentation distinguish historical script/private-engine
  names from the public application API;
- restricts generated installed manpages to the modules listed as public by
  `Makefile.PL`;
- adds a CI contract that rejects pre-release/migration-state language and
  retired top-level subclass examples in current production documentation.

## Private implementation names

Historical implementation and XS identifiers remain intentionally stable where
renaming them would add native ABI risk or unnecessary hot-path churn. Their
presence in the source tree is not itself a documentation defect.

The contract is:

- public application APIs are the IO/Kernel leaves and supporting public
  modules listed by `Makefile.PL`;
- retained historical implementation packages are `no_index` and excluded from
  META `provides`;
- installed manpage generation is limited to the public module list;
- current guidance must not present a private implementation host as an
  application construction or subclassing API.
