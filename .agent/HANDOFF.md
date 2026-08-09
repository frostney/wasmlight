# Handoff

Updated: 2026-08-09 (Track E — the interpreter)

## Current state

- **Tracks A, B, D delivered; C partial; E (interpreter) delivered.**
  The interpreter is the TIER OF RECORD (ADR-0001) and executes every
  non-SIMD, non-throwing IR op: numeric (full IEEE 754 + NaN rules),
  parametric, variable, control, memory (via the chokepoint), table,
  reference, and GC — plus host calls, the epoch check, O(1) tail calls,
  and the start function.
- Gates on the merged tree: `lwpt format`, `lwpt build`, `lwpt test`
  (26 suites), `lwpt install --frozen` — all green.
- **Everything is UNCOMMITTED** (the whole interpreter + runtime is
  untracked/modified work; the user commits between turns — HEAD is
  still an early commit, so `git stash` is NOT a valid baseline here).

## What shipped this session (Track E)

- `Wasm.Interp.Numeric` — leaf numeric functions, bit-exact, the
  positive-canonical-NaN rule, trapping + saturating truncations. Masks
  FP exceptions per-arch (x86_64 MXCSR / i386 x87 at 53-bit precision /
  aarch64 FPCR) — exported MaskFpuExceptions is the one shared routine.
  IMPORTANT: FP exceptions are NOT masked by default on aarch64-darwin;
  the interpreter re-masks on each thread's first invoke.
- `Wasm.Interp` — the explicit activation stack (NO Pascal recursion per
  wasm call), the dispatch loop, O(1) tail-call frame replacement, the
  GC frame-walk discharge (zero ref slots at entry, PushFrame before the
  first safepoint, RefRegBits/RegisterCount/Slots), memory chokepoint
  access only, host calls, the tier seam (RegisterInterpreter sets
  TierInvoke/TierContext/TierContextFree). TRAP-1 discipline: Run holds
  no managed Pascal local across any TrapNow (a longjmp abandons
  finalization — this bit once; every message/alloc path is a leaf).
- `Wasm.Wast.Values` + runner integration — value parser (hex floats,
  nan:canonical/arithmetic classes, ref forms), the result comparator
  (bitwise + NaN-class + ref identity), module registry / register /
  cross-module import; assert_return/assert_trap/invoke/assert_exhaustion
  now EXECUTE.
- Track D prereqs added this session: split null-trap kinds
  (struct/array/i31/func), barriered ArrayCopy/ArrayInitFromData/Elem +
  Store.TableCopy + sliced TableInitFromElem, Store.TierContext teardown,
  Store.MemoryPages/MemoryGrow accessors.
- Design docs persisted in .agent/design/: interp-spec.md (+ ir-spec,
  runtime-spec, wat-assembler from prior sessions).

## The honest ceiling (important)

The corpus barely moved (1032 vs 1034 pass) NOT because the interpreter
is weak but because **241 of 257 spec files are text-format modules**
that need the WAT ASSEMBLER (Track C's unshipped remainder) to even
instantiate. Exactly one corpus assertion governs a binary module. The
tier is proven by ~87 direct-API + value/runner unit tests (incl. a 1e6
tail-call loop in bounded stack, mid-construction GC collection,
call_indirect subtype dispatch). **The wat assembler is now the highest-
leverage next step for conformance signal** — it unlocks ~6,600 judgeable
commands per its design doc, and THEN assert_return/assert_trap execute
across the real corpus and settle the remaining execution-tier prefixes.

## Review outcome (2-axis, Opus-5 — codex still credit-limited)

Interpreter came back ship-quality: no confirmed high-sev exec defect;
chokepoint, TRAP-1, single-thread, tail-call O(1), NaN semantics, split
trap messages, comparator all verified clean. Found + fixed:
- **call_indirect used engine-id EQUALITY, needed SUBTYPING** (3.0
  func-ref/GC merge) — a table fn of a proper subtype was wrongly
  trapped; now uses Engine.Matches(actual, expected), corpus-confirmed
  (type-subtyping.wast:294).
- x87 control word forced 80-bit extended precision on i386 (double-
  rounds f32/f64) → set to 53-bit ($027F).
- Stale unit header (claimed memory/GC unimplemented), FP-mask dedup,
  Wave→Track comment vocabulary, dead locals, write-barrier old-value
  note for a future generational barrier.

Known deferrals (documented, not blocking): M7 extern/any convert
imprecision (needs a wrapper/flag at the convert site, lands with the
GC-heavy execution — currently latent, all its corpus cases are text-
format/skipped); Windows guard-page/SEH staged to bounds-checks;
`PRODUCTION` build mode still defined nowhere.

## Next steps (dependency order)

1. **Track C rest — the WAT ASSEMBLER** (design doc ready at
   .agent/design/wat-assembler.md). Highest leverage: unlocks the text
   corpus so the interpreter's assert_return/assert_trap actually run at
   scale. 7 waves, first three unlock zero corpus but are independently
   testable (numbers → lexer → emit).
2. **Track G — SIMD** (decode done; validation staged here,
   IR_FORMAT_VERSION→2; execution needs the v128 value side-vector the
   interpreter reserved).
3. **Track H — exception handling** (try_table IR + handler tables
   already emitted; iroThrow/iroThrowRef staged in the interpreter).
4. **Track I/J — baseline JIT / AOT**: differential-tested against THIS
   interpreter (ADR-0001). Observational-identity items to match are in
   interp-spec §8 (trap timing, NaN bits, FP rounding, side-effect order
   at a trap).
5. User decision standing: NO GitHub issues until the roadmap is done.
6. Local hygiene: builds drop gitignored .o/.ppu into
   .lwpt/modules/testing/, breaking a LOCAL `lwpt install --frozen`
   (fresh CI clone unaffected). `rm` them if frozen complains.
