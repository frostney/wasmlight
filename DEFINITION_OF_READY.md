# Definition of Ready

Use this gate before implementing an issue, idea, refactor, or
documentation change in wasmlight. A requirement may be marked not
applicable only with a recorded reason.

## Ready to investigate

- The desired outcome, current behaviour, affected surface, and non-goals
  are stated clearly enough to verify later.
- The work has been checked against [VISION.md](VISION.md). Any conflict
  with the performance-on-conformance direction or the not-goals fence is
  explicit and accepted before implementation.
- The root [AGENTS.md](AGENTS.md) hard constraints have been read.
- Applicable project skills under `.agents/skills/` have been identified
  before planning.
- The relevant docs have been identified before forming a plan:
  [Architecture](docs/architecture.md), [Code style](docs/code-style.md),
  [Testing](docs/testing.md), [Tooling](docs/tooling.md),
  [Roadmap](docs/roadmap.md), [CONTEXT.md](CONTEXT.md), and the ADRs under
  [docs/adr/](docs/adr/).

## Ready to plan

- The relevant code path has been traced in source; documentation or
  memory alone is not treated as proof.
- The owning layer is identified and respects the layering. In
  particular: spec rules belong to decode and validation, never to an
  execution tier, and the tier seam
  ([ADR-0001](docs/adr/0001-tiered-execution-seam.md)) is not widened to
  let one tier expose something the others cannot.
- Claimed WebAssembly behaviour has been checked against the spec text,
  not remembered. Cite the section.
- Tier impact is explicit: which of interpreter, baseline JIT, and AOT the
  change touches, and how the others stay observationally identical.
- Sandbox impact is explicit: whether the change adds, widens, or relaxes
  any host capability, and what denies it by default.
- Any hot-path plan that bypasses the RTL cites the `wasmbench`
  measurement that justifies it (RTL policy in
  [code-style.md](docs/code-style.md)).
- The testing strategy is identified: which co-located suites, which
  malformed-input cases, and what it means for the spec testsuite once
  that harness exists.
- The important design questions have been grilled one decision at a time,
  and the chosen behaviour is recorded. If implementation will make or
  reverse an architectural decision, the issue or mini-spec says the
  implementation PR requires an ADR.

## Ready to edit

- Work starts from freshly fetched remote `main` on a focused feature
  branch, following the project `git-workflow` skill (merge, never
  rebase).
- Generated-file ownership is known: `lwpt.cfg`, `lwpt.lock`, and `.lwpt/`
  state come from `lwpt install`; `source/units/Version.inc` comes from
  `scripts/stamp-version.pas`; `build/` is never committed.
- The validation commands needed for completion are known before editing
  (see [DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md)).
- Existing local changes have been inspected and will not be overwritten.
