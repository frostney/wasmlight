# 32-bit targets stay supported, on the explicit-bounds-check path

wasmlight supports 32-bit targets as conformant platforms, not as
build-only legs. A 32-bit process cannot reserve the 4 GiB region that
guard-page memory needs
([ADR-0005](./0005-guard-page-linear-memory.md)), so those targets take
that ADR's fallback: an explicit bounds check on every linear-memory
access. The `i386-win32` leg in `ci.yml` stays, and it runs the full gate.

The cost is honest and worth stating: there are two memory-access
strategies in the runtime, permanently, and both are on the hottest path
in the system. Each is a correctness surface, and both must produce
identical observable behaviour — a module that traps under guard pages
traps at the same access under bounds checks.

Rejected: **64-bit only**, which would delete a second strategy from the
hot path and simplify every tier. It was rejected because FreePascal's
reach onto smaller and older targets is part of why this runtime is
written in Pascal at all; a WebAssembly runtime that only runs on modern
64-bit hosts is competing where the competition is strongest and giving up
the ground it is unusually well placed to hold.

Consequences:

- This is a **platform** difference, never a tier difference. The
  observational-identity rule in
  [ADR-0001](./0001-tiered-execution-seam.md) is untouched, and the
  conformance corpus must pass on both strategies rather than on the
  64-bit one plus an assumption.
- Whether the baseline JIT and AOT compiler target 32-bit at all is a
  separate, still-open decision. Interpreter-only on 32-bit would be a
  defensible answer and does not conflict with this ADR.
- Both strategies go through the one memory-access chokepoint required by
  ADR-0005; adding a third caller that bypasses it is the failure mode
  this arrangement is most exposed to.
