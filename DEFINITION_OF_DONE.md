# Definition of Done

A change is done only when every applicable requirement below is
satisfied. A requirement may be marked not applicable only with a
recorded reason.

## Implementation

- The delivered behaviour matches its investigated issue or
  user-confirmed mini-spec, including non-goals and failure behaviour.
- The change satisfies the [AGENTS.md](AGENTS.md) hard constraints — in
  particular: validation happens once before any tier, tiers stay
  observationally identical, the error hierarchy is not collapsed, host
  capability stays deny-by-default, and no new dependency arrives without
  explicit maintainer approval.
- Hot-path deviations from the RTL are justified by a `wasmbench`
  measurement per the RTL policy in
  [code-style.md](docs/code-style.md).
- The solution is the smallest complete change; no unrelated refactoring
  rides along.
- Terminology matches [CONTEXT.md](CONTEXT.md).

## Tests and verification

- The universal project gate passes:

  ```sh
  lwpt install --frozen
  lwpt format --check
  lwpt build
  lwpt test
  ```

- Focused tests covering the changed behaviour pass first, including the
  negative paths: a malformed module must be rejected with the right
  error class, and a trapping module must trap where the spec says.
- Every new test records at least one assertion — the runner fails a test
  that asserts nothing, so a rejection case must assert its outcome, not
  only call `Fail` on the bad path.
- Behaviour changes that affect more than one execution tier are verified
  on every tier they touch, not only the one that was edited.
- No test is silently skipped, disabled, or weakened to obtain a pass.
- Markdown changes pass markdownlint
  (`npx markdownlint-cli2 "**/*.md"`, config `.markdownlint-cli2.jsonc`) —
  the PR `docs` job is blocking.
- Benchmark numbers inform the PR description where relevant but never
  become CI assertions.

## Documentation and decisions

- Documentation describes shipped behaviour only; planned behaviour stays
  in issues and in [roadmap.md](docs/roadmap.md) (current truth beats
  aspiration). An unbuilt layer is never documented as if it exists.
- Durable architecture decisions made (or reversed) by this change are
  recorded as ADRs under [docs/adr/](docs/adr/) in the implementation PR;
  existing ADRs stay immutable except link maintenance.
- New vocabulary lands in [CONTEXT.md](CONTEXT.md) rather than being
  defined differently in three places.

## Review and handoff

- The diff has been self-reviewed against the issue or mini-spec,
  criterion by criterion.
- The pull request is opened ready-for-review (not draft) so external
  review actually runs, and the external review has completed and been
  triaged before merge — a review skipped on a draft does not count.
- Required CI checks pass before the squash-merge; deferred follow-up work
  is explicit, not hidden.
- The PR body reports the validation commands run and their results.

## Release readiness

- [ci.yml](.github/workflows/ci.yml) is green on the release commit — the
  full platform matrix.
- The release goes through `/create-release`: the changelog lands before
  the tag, and the tag is unprefixed SemVer matching `version` in
  `lwpt.toml` (see [deployment.md](docs/deployment.md)).
