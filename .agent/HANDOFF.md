# Handoff

Updated: 2026-08-10 (Track I — baseline JIT: foundation + numeric/control spine)

## Current state

- **Tracks A, B, C, D, E, F, G, H delivered; Track I IN PROGRESS** — the
  baseline JIT's foundation and numeric/control/variable spine are
  shipped and PROVEN. Remaining Track I: Waves 3 (calls), 4 (memory/
  table/ref), 5 (GC), 6 (v128 via leaves), 7 (x86-64 backend).
- Gates on the merged tree: `lwpt format`, `lwpt build`, `lwpt test`
  (41 suites), `lwpt install --frozen` — all green.
- **THE PROOF**: `./build/wasmspec --tier=jit tests/spec/testsuite`
  compiles **4,562 functions** to native aarch64 and produces a
  **byte-identical** pass/fail set to `--tier=interp` (both 65184 pass /
  408 fail, diff empty) — zero JIT divergence. The 65k-assertion corpus
  is the JIT's conformance net (ADR-0001: validated by being identical
  to the conformant interpreter).
- **Everything is UNCOMMITTED** (the user commits between turns).

## What shipped this session (Track I so far)

Design doc: .agent/design/jit-spec.md. Key decisions: memory-register-
file baseline (the JIT'd frame IS the interpreter's frame → trivial
stack maps, inherited GC/tail-call/exhaustion); aarch64 first, 64-bit
only (32-bit stays interpreter-only); explicit bounds checks (guard-page
inline deferred); float/div-rem via the interpreter's OWN
Wasm.Interp.Numeric leaves (identical NaN/rounding/traps); EH/GC/memory
functions declined by the compile predicate → interpreted (the scope
fence); the differential harness is the correctness proof.

- **GO/NO-GO settled: JIT'd machine code EXECUTES on aarch64-darwin.**
  The macOS MAP_JIT + pthread_jit_write_protect_np + sys_icache_invalidate
  dance works unsigned in development (proof test emits movz/add/ret,
  returns 42).
- Wasm.Jit.CodeBuffer: W^X exec-memory + emission + label/patch map.
  Builds green on all 6 CI targets; the JIT only RUNS on 64-bit
  aarch64/x86-64-UNIX (WASM_JIT_EXEC / WASM_JIT_ARM64 gates); unsupported
  legs raise "JIT not supported".
- The tier seam (in Store + Interp): TWasmFuncInst.CompiledEntry/
  CallCount, the JitInvokeCompiled hook, the SHARED JitEnterFrame/
  JitLeaveFrame frame helpers (InterpTierInvoke now routes through them
  too → ONE frame impl for both tiers), WasmJitOffsets/WasmJitFrameOffsets
  (O-J5 field-offset probes, asserted so a record reorder goes red).
- Wasm.Jit.Arm64: the A64 encoder + per-op templates. Calling convention:
  prologue pins register-file base=x19, store=x20, &Epoch=x21,
  epoch-snapshot=x22 (callee-saved, survive helper calls), saves x19-x22+
  x30 in a 48-byte 16-aligned frame; cdecl thunks (JitOpBinary/Unary/
  JitTrapKind) call the interpreter's leaves. Templated: iroMove, i32/i64
  const/add/sub/mul/and/or/xor/shl/shr/rotl/rotr/clz/ctz/eqz/relops
  (inline), popcnt/div/rem + ALL float + ALL conversions (leaf-call),
  select, jump/branch_if/br_table (compare-chain)/return/unreachable, the
  epoch check at IR_JUMP_SAFEPOINT back-edges, forward branches via the
  label/patch pass.
- Wasm.Jit: the driver — JitCanCompile (predicate/scope fence),
  JitCompileFunction, JitDispatch, RegisterJit + the per-store code cache
  (freed before the store).
- --tier=jit / --tier=interp corpus mode in Wast.Runner + wasmspec
  (compiled=N in the TOTAL line); default stays pure interpreter.

## Review outcome (Opus-5; corpus differential = behavior oracle)

Verified CLEAN: every A64 encoding (numerically checked), the AAPCS64
ABI (callee-saved pins survive helper calls, SP 16-aligned at every bl,
x30 preserved), i32 zero-extension identity (W-form stores), trap
timing/unwind (a compiled body that traps is cleaned up by the
trampoline's ResetFrames since the JIT frame IS an interp frame), W^X/
cache-flush, predicate↔template completeness, layering. Found + FIXED:
- **(Medium, Wave-3 BLOCKER) epoch snapshot** was captured per-compiled-
  entry but the interpreter captures it per-outermost-invocation → a
  compiled leaf entered after an epoch bump wouldn't interrupt where the
  interpreter would. Fixed: TWasmStore.EpochSnapshot set once at the
  outermost guest entry (InterpTierInvoke), read by BOTH tiers' back-edge
  checks. Differential test proven to have teeth (reverting fails exactly
  that test).
- **(Medium) branch-range** was masked into imm26/imm19 with no guard →
  a >1MB-code function would silently mis-encode. Fixed: the resolver
  raises EWasmJitBranchRange on overflow, ForceCompile catches it and
  declines → the over-large function stays interpreted.
- Minor: renamed a Word-shadowing local; doc note on JIT-context-before-
  store teardown ordering.

## Next steps (Track I remaining, dependency order)

1. **Wave 3 — calls (aarch64)**: iroCall/iroReturnCall (tail-call O(1)),
   iroCallIndirect/iroCallRef (bounds→null→type / null trap order),
   host-call interop — via the seam so compiled↔interpreted interoperate.
   The shared-epoch fix un-blocked this. Diff: call*.wast, a 1e6 tail
   loop in bounded stack, deep recursion trapping 'call stack exhausted'.
2. **Wave 4 — memory + table + reference + global** (explicit bounds
   checks via the chokepoint helper; table/ref/global ops). ∥ **Wave 5 —
   GC** (struct/array/i31/ref.test/cast via Wasm.Runtime.Gc helpers;
   safepoints — the frame is already GC-walkable; publish-first). Waves 4
   and 5 can parallelize (disjoint op families) once Wave 3 lands.
3. **Wave 6 — v128 via Wasm.Interp.Vector leaf calls** (predicate stops
   declining v128 functions).
4. **Wave 7 — x86-64 backend** (Wasm.Jit.X64 — same templates, ModRM/REX
   encoding; the differential gate runs on the x86-64 CI legs).
5. Then **Track J — AOT + artifact cache** (needs I): serialize compiled
   code + the IR version (currently 2), rejected on mismatch.
6. Deferred JIT optimizations (wasmbench-gated): guard-page inline memory
   access (needs in-process signal→trampoline proven robust); native SIMD
   codegen; machine-register allocation (needs per-safepoint liveness
   maps). All behind the compile predicate / measured, never required for
   correctness (the interpreter is the tier of record).
7. User decision standing: NO GitHub issues until the roadmap is done.
8. Local hygiene: builds drop gitignored .o/.ppu into
   .lwpt/modules/testing/, breaking a LOCAL `lwpt install --frozen`
   (fresh CI clone unaffected). `rm` them if frozen complains.
