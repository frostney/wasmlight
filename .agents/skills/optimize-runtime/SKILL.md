---
name: optimize-runtime
description: >-
  Runs benchmark-gated wasmlight runtime optimization waves from a verified
  baseline through profiling, isolated implementation lanes, serialized A/B
  measurement, combined re-measurement, and cross-tier correctness gates. Use
  when asked to optimize interpreter, JIT, AOT, startup, calls, numeric, SIMD,
  or memory performance; investigate a Wasmtime gap; run another optimization
  wave; or retain only changes with a measured positive impact.
---

# Optimize runtime

Improve execution speed without trading away conformance. Treat every change
as a candidate until repeatable measurement and tier-identical correctness
accept it.

## Establish the experiment

1. Read `.agent/HANDOFF.md`, `VISION.md`, `CONTEXT.md`, the hot-path policy in
   `docs/code-style.md`, `docs/testing.md`, and the ADRs governing the affected
   seam.
2. Apply `git-workflow`. Require a clean tree, fetch the remote default, and
   start from its exact tip on a focused branch. Never benchmark an unexplained
   dirty or mixed-revision tree.
3. State the target workload, affected execution tiers, expected invariant,
   guard workloads, platforms, and non-goals before editing.
4. Use release builds for performance measurement. Use development builds as
   an additional checked-build correctness gate, never as performance evidence.
5. Make every workload verify its result independently. Do not use the
   interpreter as the compiled tiers' only oracle.

## Capture the baseline

1. Build and retain a baseline binary from the exact starting commit with the
   same compiler, dependencies, flags, and host used for candidates.
2. Verify measurement validity before every schedule. Each of these has
   invalidated whole comparison sets at least once:
   - rebuild with `--mode release` and confirm the binary hash against the
     retained predecessor before treating any run as a candidate —
     development builds are correctness gates, never candidates;
   - check `ps aux -r` and the load average for external consumers (VMs,
     browsers, builds) that the shared lock cannot exclude;
   - diff strictly against the immediate predecessor head's retained binary,
     not an older wave's.
3. Stop competing benchmark processes. Serialize measurements through one
   shared exclusive lock, conventionally `/tmp/wasmlight-perf-gate.lock`.
4. Discard at least one warm-up. Default to seven measured samples and report
   the median plus the sample spread. Use fewer only for an expensive workload
   and record why.
5. Measure the target and representative guards from `wasmbench`: startup,
   loop, fib/direct calls, scalar memory, varying-address memory, numeric, and
   SIMD as applicable. Keep iteration counts large enough to escape timer
   quantization.
6. Record the exact commit, command, OS, architecture, execution tier, workload
   size, warm-up count, sample count, order, median, spread, and verified
   result.
7. When comparing Wasmtime, run an identical module and entry point, exclude
   compilation from both sides, precompile both artifacts, verify observable
   results, and run on the same host. Label emulated or virtualized Linux
   results explicitly rather than presenting them as native hardware.

## Find the bottleneck

1. Profile a long-running version of the target workload and inspect generated
   code or the interpreter dispatch path as appropriate.
2. Trace the dominant samples to source and state the suspected cost in
   mechanism terms: dispatch, register-file traffic, helper crossings, frame
   publication, memory resolution, address generation, bounds checks, or
   another observed cause.
3. Form bounded candidate lanes only after the baseline and profile exist.
   Prefer independent lanes with disjoint ownership and one primary hypothesis
   each.
4. Preserve architectural invariants in every lane: validation remains shared,
   memory uses the chokepoint strategy, epoch checks and stack maps remain at
   safepoints, traps unwind through the trampoline, and tiers remain
   observationally identical.

## Run isolated candidate lanes

Use a bounded subagent fan-out when independent lanes can run concurrently.
Give every lane an isolated worktree and branch at the same exact baseline.
When subagents are unavailable, run the same lanes sequentially in isolated
worktrees.

Require every lane to:

- own a concrete bottleneck and a bounded set of files;
- capture its own serialized baseline before changing code;
- keep ABI, artifact, register, safepoint, GC, trap, and memory invariants
  explicit;
- measure the target immediately before and after the candidate under the
  shared lock;
- run guard workloads and focused correctness tests;
- reject and fully revert experiments that regress, overlap noise, fail result
  verification, or weaken an invariant;
- commit only an accepted candidate and return its exact hash, measurements,
  guard results, correctness evidence, and rejected experiments;
- avoid editing `.agent/HANDOFF.md`; the integration owner records the wave.

Do not let multiple lanes benchmark concurrently. Parallelize investigation,
implementation, builds, and correctness tests; serialize performance runs.

## Accept or reject a candidate

1. Run an immediate same-load A/B comparison using retained baseline and
   candidate binaries. Confirm in reverse order or an ABBA sequence.
2. Accept only a repeatable positive target delta that exceeds observed noise
   and timer resolution. A single favorable sample or a one-millisecond shift
   at one-millisecond resolution is not evidence.
3. Reject a target win if a representative guard materially regresses unless
   the user explicitly accepts that trade-off after seeing both measurements.
4. Require identical verified results and relevant focused tests before
   integration. Never turn benchmark numbers into test assertions.
5. Keep rejected work out of the accepted commit. Record why it lost — the
   mechanism and the deciding measurements — so a later wave does not
   unknowingly repeat it.

## Re-measure combined integration

1. Begin from the current accepted integration head, not the original baseline.
2. Merge one accepted lane at a time into a disposable integration branch or
   worktree. Never rebase or force-push.
3. Rebuild and compare the combined candidate against the immediately previous
   accepted head under the same serialized protocol.
4. Advance the delivery branch only when the combined state remains positive
   and its guards remain flat. Leave a lane unintegrated when interaction with
   earlier work erases its benefit or creates a regression.
5. After each accepted merge, treat that result as the next baseline. Do not
   add isolated percentages to predict the combined outcome.

## Prove correctness and report

Run the smallest focused checks first, then the repository gates on the final
combined diff:

```sh
lwpt install --frozen
lwpt format --check
lwpt agents --check
lwpt build
lwpt build --mode release
lwpt test
npx markdownlint-cli2 "**/*.md"
./build/wasmspec --tier=interp tests/spec/testsuite
./build/wasmspec --tier=jit tests/spec/testsuite
./build/wasmspec --tier=aot tests/spec/testsuite
```

Require byte-identical interpreter, JIT, and AOT corpus tallies with zero
errors on macOS/aarch64 and Linux/x86-64 for generated-code changes. Run the
ordinary cross-platform CI matrix as the final platform gate; Windows and
32-bit targets remain interpreter-only.

Update `.agent/HANDOFF.md` with:

- the exact before/after medians and method;
- accepted commits and their invariants;
- rejected experiments and measured reason;
- guard workloads and correctness gates;
- cross-architecture results and virtualization caveats;
- the remaining Wasmtime gap and next profiled bottlenecks.

Use `create-pr` when delivery is requested. Keep its PR draft until the
Definition of Ready is satisfied and exact-head CI is green, then mark it ready.

## Stop conditions

Stop and report rather than integrate when the baseline is unstable, the target
does not verify its result, the candidate's improvement is not repeatable, a
guard regresses materially, tiers diverge, a cross-architecture gate fails, or
the change depends on an unresolved ABI, safepoint, GC, trap, or memory-safety
assumption.
