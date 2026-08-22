---
name: codebase-audit
description: >-
  Audits the current repository for systemic correctness, architecture,
  churn, simplification, clarity, test value, and operational risks using
  current source and reproducible probes. It can delegate evidence gathering
  across bounded capability and perspective lanes. Use when the user runs
  /codebase-audit or asks for an evidence-backed repository or subsystem audit.
license: Unlicense OR MIT
compatibility: >-
  Requires the project's declared build and test tools plus network access for
  current third-party documentation and source verification.
---

# Codebase audit

Assess the repository's current state rather than a branch diff. Produce a
truthful coverage map, actionable findings, and coherent remediation batches.

## Modes and boundaries

The audit is non-remediating by default. It may run safe local tests, builds,
servers, browser flows, disposable repros, isolated test data, temporary
artifacts, and revert-clean falsification probes. A falsification probe
temporarily introduces one targeted wrong behavior to prove the relevant test
or gate fails for the right reason. Record the initial tree state, prefer a
disposable worktree or copy, restore the mutation immediately, compare the
final tree byte-for-byte with the recorded state, and report the mutation and
observed failure. Skip the probe and mark the evidence static-only when exact
restoration is not safe. The audit must not leave any edit to repository content
or create persistent or externally visible side effects. Clean up disposable
artifacts and report anything retained.

`subagents` is an additive execution input. Without it, do not delegate any part
of the audit.

A request to save JSON authorizes only the named findings artifact; it does not
authorize remediation. Read
[references/findings-json.md](references/findings-json.md) only when JSON output
is requested.

There is no `fix-all` mode. After reporting, offer remediation batches. A fix
follow-up begins only when the user selects a coherent batch or finding IDs. It
authorizes focused local edits and validation on a focused branch, not commits,
pushes, publication, issue creation, deployments, or shared-state mutation.

## Map before judging

1. Read applicable project instructions, vision and product documentation,
   current source, tests, fixtures, configuration, lockfiles, generated
   interfaces, schemas, public APIs, examples, templates, completion contracts,
   packaging, CI, scripts, release, deployment, and operational definitions.
2. Map user-visible capabilities, entry points, modules, trust boundaries, data
   and state flows, background work, external dependencies, tests, tooling, and
   operational paths.
3. Choose perspectives from the actual codebase:
   - always cover behavior, correctness, architecture and consistency,
     simplification, self-documentation, test value, and operations;
   - add UI/UX and accessibility when interfaces exist;
   - add security and adversarial-input analysis at trust boundaries;
   - add persistence, migration, transaction, concurrency, and idempotency
     analysis for stateful paths;
   - add API, CLI, library, packaging, compatibility, deployment, rollback,
     observability, performance, and discoverability analysis only where those
     surfaces exist; activate discoverability for a public web surface.
4. For a shallow subsystem, trace its complete path and direct interactions. For
   a layered codebase, partition work by capability and perspective so later
   areas do not receive progressively thinner analysis.
5. Build a bounded churn map from repository history. Rank frequently changed
   files, then inspect function, method, class, or module history where symbols
   are reliable. Use the repository's declared churn window or 90 days when none
   exists. Prefer its code-health tool; otherwise use Git file history and
   `git log -L` for stable symbols. Follow renames; state the window, touch
   count, and line churn, and label file-level fallback.

## Sub-agent lanes

When the user supplies `subagents`, the coordinating agent still owns the audit
scope, coverage map, capability map, active and skipped perspectives, validation,
final findings, remediation batches, and report.

1. Publish a bounded lane map before delegation. Form lanes from capability and
   perspective intersections so no worker receives an unbounded whole-repository
   perspective. Give each lane one worker; tightly coupled or individually small
   perspectives may share a lane. Queue excess lanes when platform capacity is
   temporarily full.
2. Give each worker its lane ID, assigned capability and perspectives, bounded
   scope, relevant project instructions, and known evidence. A worker may inspect
   and run the safe probes allowed by this skill, but it must not edit, create
   persistent or external side effects, delegate further, assign final finding
   IDs or severities, propose final remediation batches, or issue an overall
   conclusion.
3. Require each worker to return its lane ID, assigned capability and
   perspectives, bounded scope, inspected supporting context, exact probes and
   observed results, candidate findings with evidence, impact, and smallest
   remedy, verified claims, limitations, and `complete` or `incomplete` status.
4. Validate every candidate against the current checkout, apply the
   de-duplication model below, reconcile conflicts across lanes, then assign
   final IDs, severities, categories, remediation batches, and conclusions. Do
   not repeat a completed lane wholesale.
5. If sub-agents are unsupported, unavailable after any applicable bounded
   retry, or leave a lane incomplete, complete that lane directly. Report the
   affected lane and reason as a single-agent fallback. Temporary capacity
   exhaustion queues work rather than triggering immediate fallback.

## Establish current evidence

- Treat documentation, tests, issue text, prior audits, model memory, and
  generic best practice as leads, not proof.
- Exercise representative behavior through the real UI, API, CLI, library
  entry point, job, migration, package, or deployment path. Cover success plus
  the most consequential failure or boundary case.
- Record setup, action or command, input, expected result, and observed result.
  Mark anything not executed `static only`.
- Verify test value: relevant wrong behavior should fail; assertions should
  cover outcomes and meaningful failure paths without excessive mocks,
  snapshots, or implementation coupling.
- Verify third-party claims against the exact locked version and current
  official documentation or source. Check whether a current supported version
  removes custom code, workarounds, adapters, or configuration.
- Compare documentation and declared operational flows with current
  implementation. A passing unit suite does not validate a broken build,
  migration, package, deployment, or rollback path.

## Audit checks

### De-duplication

Apply four separate checks across the repository and its delivery surface:

- **Implementation:** find repeated code, logic, tests, fixtures, generated
  forms, schemas, APIs, configuration, workflows, documentation, examples,
  templates, release or deployment paths, operational scripts, dependencies,
  custom tooling, and competing representations of one concept.
- **Work:** find repeated investigations, questions, decisions, findings,
  tickets, remediation, reruns, and recurring repair patterns across current
  issue and pull-request history and decision records. Reuse and revalidate
  existing work.
- **Evidence:** coalesce the same event reported by multiple checks, logs,
  ledgers, or tools so it is counted once while retaining every source.
- **Output:** combine candidates with the same cause, impact, and remedy into one
  finding, preserve provenance, and explicitly reconcile contradictory evidence.

The default scope may inspect direct consumers and sibling components to test a
public contract or competing representation. Report a cross-repository finding
only when the user included that scope or current public-contract evidence makes
the external impact part of the repository finding.

### Technical checks

- Trace boundary inputs, authorization, state changes, failures, partial
  success, retries, concurrency, idempotency, deletions, and side effects where
  relevant.
- Check dependency direction, module cohesion, ownership, public interfaces, and
  whether multiple patterns or representations compete for the same concept.
- Search the live repository before proposing anything new. Prefer deletion,
  reuse, direct control flow, consolidation, the standard platform, and existing
  dependencies over new layers.
- Report dead code, duplication, speculative abstractions, needless wrappers,
  one-use indirection, stale compatibility paths, and dependencies that no
  longer earn their cost.
- Require names, types, boundaries, and interfaces to communicate intent. Match
  the surrounding comment density; comments should preserve rationale and
  constraints, not narrate syntax.
- Treat repeated changes to the same symbol or file as an architectural-risk
  signal, not a defect by itself. Raise an `ARCHITECTURE_RISK` finding when the
  measured churn coincides with mixed responsibilities, recurring fixes or
  reverts, competing representations, broad blast radius, unstable interfaces,
  or weak regression coverage. Cite the window, touch count, granularity, and
  co-signal.
- Suppress generic advice when repository evidence documents a deliberate
  alternative. Every best-practice finding must cite current project and
  authoritative-source evidence plus the concrete simplification or risk.

### Discoverability

For a public web surface, verify crawl and index controls, canonical and
descriptive metadata, internal discovery paths, structured data that matches
visible content, semantic content structure, rendering, and material web
performance. Assess conventional search and AI-assisted discovery together,
while keeping crawler access, search inclusion, and model-training controls
distinct. Use current official search-engine and publisher guidance; do not
invent special AEO markup, keywords, or guarantees.

## Report

Search the complete mapped scope for evidence-backed candidates before
filtering the report; do not stop after the first or highest-severity issue.

Lead with the highest-value current conclusion. Include:

- a coverage map of inspected, executed, sampled, static-only, and unreached
  capabilities;
- active and skipped perspectives with reasons;
- when `subagents` was supplied, the capability-and-perspective lane map,
  completed and incomplete lanes, and every coordinator-completed fallback with
  its reason;
- the churn window, symbol/file coverage, and architectural-risk hotspots;
- exact probes and project gates with observed results;
- de-duplication coverage across implementation, work, evidence, and output,
  including coalesced sources and reconciled conflicts;
- actionable findings as
  `[CA-N][BLOCKING|IMPORTANT|IMPROVEMENT][BEHAVIOR|QUALITY|ARCHITECTURE_RISK|
  OPERATIONS|DISCOVERABILITY] file:line: evidence, impact, smallest remedy`;
- grouped remediation batches ordered by risk reduction, dependency, and
  reviewability;
- limitations and retained probe artifacts.

`BLOCKING` is a current exploitable, corrupting, or deployment-blocking defect.
`IMPORTANT` has material correctness, security, operability, test-value,
maintainability, simplification, or comprehension cost. `IMPROVEMENT` is a
verified worthwhile simplification or current-practice alignment. Omit praise,
inventory narration, style nits, and findings without concrete impact.

## Fix follow-up

After the user selects a batch or IDs, create or reuse a focused branch and
implement the smallest complete remedies. Do not absorb unrelated findings.
Promote useful probes into regression tests, remove disposable artifacts, run
affected behavioral probes and project gates, and report fixed and unresolved
IDs with observed evidence. The coordinator makes every edit. Do not redispatch
completed lanes after fixes; re-engage a worker only to resolve incomplete or
contradictory evidence. Use the repository's separate git and PR workflows only
when the user requests publication.
