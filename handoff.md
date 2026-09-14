# Linux::Event Handoff

Before architectural, performance, dependency, or ecosystem work, read
`docs/ECOSYSTEM-CHARTER.md`. It is authoritative.

For planned core work and the release path after 0.114, read
`docs/V1-ROADMAP.md`. That roadmap covers:

- the foreign-loop `poll_fd()`/nonblocking-pump boundary;
- owner-interpreter deferred/next-turn callbacks;
- the post-fork Loop contract;
- native filesystem notification using inotify;
- the possible replacement of the obsolete Stream tuning-explorer branch;
- the tests, documentation, integration, and release gates for 1.000.

## Current state: 0.114 release preparation

0.114 is a narrow correctness release. It fixes the documented
`transition_to()` invariant that remained incomplete on 0.113: Pipe and TTY
subclasses could previously transition into each other because the guard only
distinguished connected sockets from all non-socket ordered-byte resources.

The current implementation classifies the source and target as `pipe`, `tty`,
or `stream-socket` on the cold transition path and rejects a kind change before
descriptor/native-state mutation. The regression matrix verifies all six
cross-kind directions, all three same-kind transitions, informative errors,
and atomic preservation of source class, descriptor, and native state after
rejection. Existing socket/Pipe boundary coverage uses the new diagnostic.

Release bookkeeping is set to version 0.114 dated 2026-09-13. The new test is
in `MANIFEST`; checked-in metadata is synchronized; the repository-only v1
roadmap is excluded from the CPAN distribution alongside the other strategic
documents.

Verification completed so far:

- focused protocol/resource transition suite: PASS, 3 files, 69 tests;
- complete 0.114 source build and suite: PASS, 158 files, 3,065 tests;
- generated-distribution build and suite: PASS, 158 files, 3,063 tests (the
  two-test difference is expected from repository-only material excluded by
  `MANIFEST.SKIP`);
- `make distcheck`: PASS;
- `META.json` and `META.yml`: parse successfully and report 0.114;
- all 25 indexed public POD files: PASS;
- generated tarball: gzip integrity PASS, and repository-only roadmap,
  handoff, and optional foreign-loop tooling are absent;
- `git diff --check`: PASS.

`Linux-Event-0.114.tar.gz` is generated and ready for final clean-tree release
handling after the release-preparation commit is pushed and CI passes.

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
