# Handoff

Updated: 2026-08-10 (Track I COMPLETE — both backends, cross-arch proven,
all 4 review findings fixed; Track J AOT is next)

## Post-roadmap follow-ups (this session)

- **Corpus in CI (done):** pr.yml/ci.yml now fetch the testsuite at the
  pinned tests/spec/testsuite.commit and run wasmspec — interp on every
  platform, jit+aot three-tier IDENTITY check on the 64-bit UNIX legs.
  Not yet run on the full matrix (still unpushed).
- **Docs (done):** roadmap/README/architecture/AGENTS/testing updated to
  roadmap-complete (three tiers, two arches, UNIX-64-only JIT/AOT scope).
- **Corpus fails closed (done):** 408 -> 389 (+19 pass), all genuine
  3.0-core gaps, cross-arch + cross-tier verified: binary-leb128 overlong-
  past-section decode messages (+7); M7 extern/any convert now uses GC
  wrapper objects wokExternalized/wokInternalized so ref.test/ref.cast
  classify correctly (+4, wired through interp AND both JIT backends AND
  the const-expr evaluator so all tiers stay identical); addrtype text
  forms / anyfunc / id.wast lexer / ref.func-declared-set / throw wording
  (+8). Remaining 389 = 356 post-3.0 proposals + 16 legacy EH (both out
  of scope) + ~9 (module definition/instance) harness forms + a few
  deferred decode/framing edges.
- **Perf vs wasmtime (done, HONEST):** aarch64-darwin, min of 4 runs.
  fib(35): interp 4682ms / aot 4567ms / wasmtime 38ms. loop(300M mul-add):
  interp 1205 / aot 1194 / wasmtime 94. noop startup: interp 3 / aot 3 /
  wasmtime 5. TAKEAWAYS, stated plainly: (1) wasmtime's optimizing
  Cranelift JIT is 13-120x faster than wasmlight's baseline on throughput
  — expected, and the VISION "rivals C/Rust" goal is NOT met by the
  current tiers. (2) The baseline JIT/AOT is only ~1-3% faster than the
  interpreter here: the memory-register-file design keeps all the
  load/store traffic and calls go through the same helpers, so the JIT
  removes only dispatch overhead. The real speedup lives in the DEFERRED
  optimizations (machine-register allocation, guard-page inline memory,
  native SIMD) — genuinely future work, not shipped. (3) wasmlight's AOT
  startup marginally beats wasmtime for trivial modules (no run-time
  compile), but the margin is small.

## THE ENTIRE ROADMAP (Tracks A-J) IS DELIVERED.

Decode (A), validate + register IR (B), the .wast harness + wat assembler
(C), runtime + precise GC (D), interpreter (E), embedding API + WASI
preview1 (F), SIMD (G), exception handling (H), baseline JIT — aarch64 +
x86-64 (I), AOT + artifact cache (J) — all shipped and proven. The
runtime decodes, validates, instantiates, and EXECUTES the complete core
wasm 3.0 instruction set on two architectures via three interchangeable,
observationally-identical tiers (interpreter / baseline JIT / AOT), runs
real WASI programs under deny-by-default sandboxing, and is conformance-
tested byte-for-byte against the upstream corpus (65,184 pass) in every
tier on both arches.

## Track J (AOT) — COMPLETE (all 6 waves, both arches, CLI).

- Wave 5 (the last): `wasmlight aot <mod.wasm> [-o <art.waot>]` compiles
  ahead of time; `wasmlight run --aot <art.waot> [--] <mod.wasm> [args]`
  (+ sibling <mod>.waot auto-detect, `--no-aot`) loads it for instant
  startup, transparently FALLING BACK to interpret if the artifact is
  absent/stale/wrong-arch/hash-mismatch (a stale artifact never breaks a
  run, only loses the speedup). --aot composes with --dir/--env/--.
  wasmbench BenchStartup measures aot-load (~110us) vs jit-warmup
  (~112us) vs interpret (~220us) — MEASUREMENT ONLY. Also fixed a
  pre-existing wasmbench BenchDecodeModule crash (strict decoder rejects
  its synthetic junk sections) → made crash-safe.
- Verified end-to-end on BOTH arches: `aot` then `run --aot` prints
  hello / exit 0 identically to a plain run; arm64 44 suites green,
  format+frozen clean.

## AOT internals (Waves 0-4)

- **AOT works end-to-end on BOTH arches.** compile-a-function-to-machine-
  code at build time -> serialize to a .waot artifact -> load in a fresh
  process/store (re-decode+re-validate first) -> map+fill-helper-table+
  wire CompiledEntry from the artifact bytes -> run. Proven NOT a
  re-JIT: the load path reads the artifact bytes and the AOT-loaded
  executable memory is byte-identical to a fresh JIT compile.
- **Three-tier corpus byte-identical on both arches:**
  arm64: interp/jit/aot all pass=65184 fail=408; aot loaded=8562.
  x86-64: interp/jit/aot all pass=65184 fail=408; aot loaded=8563.
  Wave 4 (x86-64 loader) needed ZERO x86-64-specific work — the Wave-0
  position-independent code + the arch-generic load path just worked.
- Units: Wasm.Aot.Artifact (.waot read/write, FNV-1a-128 moduleHash,
  self-checksum, the guards), Wasm.Aot (AotCompileModule over every
  function via JitCanCompile + JitStageFunctionBytes; AotLoadAndWire =
  re-validate -> guard(magic/aotVer/irVer=2/arch/abiFingerprint/
  moduleHash/checksum, each a distinct reject reason) -> LoadPrecompiled).
  --tier=aot in Wasm.Wast.Runner + wasmspec (round-trips through real
  artifact bytes, not JIT-in-disguise).
- Wave 1 accessors added to Wasm.Jit.pas: JitCompileToBuffer(AFinalize),
  JitStageFunctionBytes, TWasmJitContext.LoadPrecompiled. CodeBuffer:
  SnapshotBytes/SnapshotRelocs (Wave 0).
- SECURITY INVARIANT (coded + honest comment): always re-decode+
  re-validate; the artifact is used only if all guards match the
  freshly-validated module. moduleHash binds artifact<->module (a stale/
  wrong-module artifact is rejected). A same-module tampered blob would
  run, but artifact + runtime share one trust domain (content-integrity,
  not authentication) — stated honestly, not oversold.

## AOT remaining: Wave 5 (the CLI + measurement) ONLY
`wasmlight aot <module.wasm> -o <artifact.waot>` (compile-ahead) and
`wasmlight run --aot <artifact.waot> [--] <module.wasm> [args]` (load for
instant startup, fall back to interpret/JIT if the artifact is absent/
stale/wrong-arch); a wasmbench startup measurement (AOT instant-start vs
JIT-warmup vs interp) — MEASUREMENT ONLY, never a CI assertion.

## (Wave 0 detail) position-independent codegen

- The AOT prerequisite is complete and cross-arch proven: both JIT
  backends now emit POSITION-INDEPENDENT machine code, so the generated
  code can be serialized + reloaded in another process (the basis of an
  AOT artifact). Design doc: .agent/design/aot-spec.md.
- How (aot-spec §1.2-1.4): (a) helper calls go through a per-process
  INDIRECT TABLE — a TWasmAotHelper enum (12 helpers) indexes
  Store.JitHelperTable (filled at RegisterJit); the code emits
  `ldr x9,[x24,#k*8];blr x9` (aarch64) / `call [r15+k*8]` (x86-64), so
  only the stable INDEX is baked, not the address. (b) the IR Code base
  is passed to the compiled entry in a pinned register (x23 / rbp) and
  @Fn^.Code[i] is computed `base + i*24` — no baked IR pointer (also
  subsumes the old Fix-C @AIns concern). (c) an ABI FINGERPRINT
  (WasmAotAbiFingerprint, FNV-1a-64 over all WasmJit*Offsets +
  SizeOf(TWasmIrInstr/TWasmValue) + helper count + AOT_ABI_REVISION)
  guards the baked ABI constants against a different wasmlight build.
- x86-64 pin map (6 callee-saved all pinned): rbx=regfile, r12=store,
  r13=&Epoch, r14=snapshot, r15=helper-table, rbp=IR-base (rbp is a
  general pin here, not a frame pointer — locals off rbx, scratch off
  rsp, longjmp restores it).
- CodeBuffer gained SnapshotBytes (branch-resolved bytes, no
  MakeExecutable) + SnapshotRelocs (empty — the unified emitter bakes no
  absolute; the reloc format exists for future ops).
- VERIFIED BOTH ARCHES: --tier=jit corpus byte-identical to the
  interpreter (arm64 8562, x86-64 8563, both pass=65184 fail=408), zero
  behavior change from the refactor. arm64 42 suites green; x86-64 VM 41
  pass / 1 fail (only the FpFork/Rosetta artifact).

## AOT remaining waves (aot-spec §7)

1. **Wave 1** — Wasm.Aot.Artifact (.waot format read/write, FNV-1a-128
   module hash, self-checksum, the ABI/IR-version/arch guards) + the
   FIRST milestone: AOT-compile i32.add → serialize → load in a fresh
   store → fill helper table + pass IR base → run → diff vs interp.
2. **Wave 2** — AotCompileModule over every function (drive JitCanCompile,
   record declined); --tier=aot over a corpus subset.
3. **Wave 3** — full corpus --tier=aot on aarch64 (byte-diff vs interp) +
   the JIT-vs-AOT round-trip identity test. The aarch64 deliverable.
4. **Wave 4** — x86-64 (targetArch id, the X64 loader/entry-ABI, --tier=aot
   in the amd64 VM).
5. **Wave 5** — CLI (wasmlight aot <mod> -o <artifact>; run --aot) +
   wasmbench startup measurement (measurement only).
SECURITY INVARIANT (hard): AOT always re-decodes + re-validates the
module at load; the artifact is a perf cache, NEVER a trust bypass — its
code is used only if module-hash + IR-version + arch + ABI-fingerprint +
checksum all match the freshly-validated module.

## Track I is DONE. The 4 non-corpus review findings (#48-51) are FIXED.

- **Fix A (seam-transparent unwind + O(1) cross-tier tail).** New RetKind
  rtCompiledSeam: JIT-dispatch seam frames are TRANSPARENT to the
  exception unwind (a throw from a compiled callee reaches an outer
  interpreted try_table instead of surfacing as 'uncaught') and the
  tail-call trampoline hands cross-tier tails back to a shared loop (an
  alternating compiled<->interpreted 1e6 tail loop runs in bounded stack).
  Fence 2 (decline call-bearing funcs when store has tags) retired; fence
  1 (try_table-handler funcs) + iroThrow/iroThrowRef decline stay.
  KEY DISCOVERY: a Pascal `raise` cannot unwind across a JIT native frame
  (no unwind tables on aarch64-darwin, same reason traps use LongJmp), so
  the seam hop uses LongJmp to a SetJmp seam-catch stack integrated with
  WasmInvoke's trampoline (a small, flagged +49-line change to
  Wasm.Runtime.Traps.pas so a trap resets the seam stack — load-bearing,
  traps-in-compiled-funcs are corpus-reachable).
- **Fix B (epoch reseed).** Store.EpochSnapshot seeded only at the
  outermost guest entry (Heap.CurrentFrame=nil), not on nested re-entry —
  a pre-call epoch bump is now observed in a nested callee, matching the
  interpreter. Differential test both tiers trap 'interrupt'.
- **Fix C (@AIns ABI).** Eliminated the const-record-by-ref assumption:
  the emitters take @Fn^.Code[i] (stable IR location) instead of @AIns.
  Both backends.
- **Verified on BOTH arches:** arm64 42 suites green, format+frozen clean;
  x86-64 VM 41 pass / 1 fail (only the FpFork/Rosetta artifact, unrelated
  — see honest status below). Both corpus tiers byte-identical on both
  arches (interp 65184, jit arm64 8562 / x86-64 8563, all pass=65184);
  EH corpus green both tiers. Zero regression from the delicate change.

## Track I is now cross-architecture complete (aarch64 + x86-64)

## Track I is now cross-architecture complete (aarch64 + x86-64)

- **Both JIT backends implemented and differentially proven byte-
  identical to the interpreter.** aarch64 (Waves 1-6) and x86-64 (Wave 7,
  Wasm.Jit.X64) each compile the full non-EH op set. `--tier=jit` corpus:
  arm64 compiled=8562 / x86-64 compiled=8563, both pass=65184 fail=408 —
  identical to the interpreter, zero divergence, on both arches.
- **The x86-64 backend is proven in an OrbStack amd64 Linux VM** (the
  user's idea), Rosetta-accelerated. Setup: `orb create -a amd64 ubuntu
  wasmx64`; FPC 3.2.2 via apt + lwpt 0.4.0 linux-x64 (checksum-verified)
  in ~/.local/bin; the mac repo is mounted at the same path, rsync'd to
  ~/wasmlight (VM-local, excluding build/.git/tmp) to build+test without
  polluting the mac tree. `lwpt build` → x86-64 ELF; `./build/wasmspec
  --tier=jit tests/spec/testsuite` is the differential proof.
  Re-run: `orb -m wasmx64 bash -lc 'export PATH=$HOME/.local/bin:$PATH;
  rsync -a --exclude build/ --exclude .git/ --exclude .lwpt/tmp/
  /Users/jstein/Documents/GitHub/wasmlight/ ~/wasmlight/; cd ~/wasmlight;
  lwpt build && ./build/wasmspec --tier=jit tests/spec/testsuite'`.
- **The VM immediately caught + we FIXED a real cross-arch bug:**
  f32/f64.convert_i64_u rounded wrong on x86-64 (FPC's UInt64->float
  drops the sticky bit for high-bit-set values; arm64 ucvtf is fine). A
  wasm result must not depend on host arch. Fixed in Wasm.Interp.Numeric
  with the shift-with-sticky halving sequence (`(A shr 1) or (A and 1)`,
  convert signed, double); regression tests for the exact conversions.wast
  522/523/537/538 values, verified on BOTH arches. x86-64 interp corpus
  is now 65184, matching arm64.
- **Fixed JIT test portability**: the test programs hardcoded/only-defined
  WASM_JIT_ARM64, so on x86-64 the differential tests took the "no
  backend" branch and failed. Now they derive WASM_JIT_X64 too and gate
  the (arch-agnostic) differential assertions on WASM_JIT_BACKEND
  (Wasm.Jit.Test.pas, Wasm.Wast.Runner.Test.pas). Arch-specific byte
  tests stay in Wasm.Jit.{Arm64,X64}.Test gated on their arch.
- Mac (arm64): 42 suites green, format + frozen clean. VM (x86-64):
  41 pass / 1 fail — TestGuardFaultTrapsInAForkedChild
  (Wasm.Runtime.Memory.Test).
- **HONEST STATUS of that 1 failure (an earlier claim was corrected):**
  it is NOT root-caused and is UNVERIFIED on native x86-64 (we have none
  — only arm64 + this Rosetta-emulated amd64 VM). What is known:
  - It fails on the parent's FIRST assertion `Pid > 0` in ~1ms → FpFork
    appears to return <= 0 in the wasmlight process.
  - A standalone C probe (fork + PROT_NONE mmap + SIGSEGV + siglongjmp +
    waitpid) WORKS under this same Rosetta VM (`normal=1 exit=0`). So the
    signal/guard/longjmp MECHANISM is fine under emulation — the earlier
    "signal delivery doesn't survive translation" explanation was WRONG.
  - So the failure is specific to FpFork/the FPC+fault-handler runtime
    state under Rosetta (plausibly forking a Rosetta-JIT'd process that
    has already installed the guard signal handler + altstack), NOT a
    wasm-visible correctness issue: the interp AND jit corpora pass
    65184 identically on x86-64, and memory access uses explicit bounds
    checks (the guard-fault path this test exercises is a narrow
    mechanism the tiers don't rely on).
  - It was deliberately NOT given a skip-under-emulation guard — that
    would hide an unexplained failure. It stands red in the VM until
    either root-caused or run on native x86-64 (CI). Do not re-describe
    it as a "documented benign limitation" without that evidence.

## Cross-check bonus: the interpreter is now proven on x86-64 too

Before this, only arm64 was tested. The VM ran the full interpreter
corpus + unit suites on x86-64 — after the convert fix, everything
passes identically, confirming the whole runtime (decode/validate/
instantiate/interpret) is host-arch-independent.

## (prior) Track I aarch64 status: op-complete, corpus-proven

## Track I aarch64 status: op-complete, corpus-proven

- The aarch64 baseline JIT now compiles the **full non-EH op set**
  (Waves 1-6: numeric/control/variable, calls + O(1) tail calls,
  memory/table/ref/global, GC, v128-via-leaves). `./build/wasmspec
  --tier=jit tests/spec/testsuite` → **compiled=8562**, verdicts
  BYTE-IDENTICAL to `--tier=interp` (65184 pass / 408 fail, zero
  divergence). 41 suites green, frozen clean.
- Only exception-handling functions stay interpreted (iroThrow/
  iroThrowRef declined ops; a function with a try_table handler declined;
  a conservative fence declines call-bearing functions when the store has
  tags — see the review findings below).

## Review of Waves 3-6 (Opus-5) — 4 non-corpus-reachable findings

The corpus (8562 funcs, byte-identical) is a comprehensive behavior
oracle; the review targeted edges it can't reach. Verified CLEAN: the
call ABI, self/mutual-COMPILED tail calls (genuinely O(1)), publish-first
during allocating helpers, call_indirect/memory.init trap order, v128
chokepoint, teardown ordering, epoch pinned-reg survival, iroThrow
declined independently of the fences. Four findings, ALL non-corpus-
reachable, a fix wave for them was DRAFTED then HELD (it rewrites the
verified-clean exception unwind — deferred pending a decision):

1. **(Medium) cross-tier tail loop grows the stack — O(1) violation.**
   A compiled↔interpreted ALTERNATING tail chain (needs one non-
   compilable partner, e.g. it has EH) accumulates native frames; the
   JIT config traps 'call stack exhausted'/crashes where the interpreter
   keeps it O(1). Same-tier tail chains ARE O(1) (proven, 1e6 loop).
2. **(Medium, soundness) EH fence residue.** A store that gains its
   FIRST tag AFTER a call-bearing function was compiled: a throw
   propagating through that compiled seam frame surfaces as 'uncaught
   exception' where an outer try_table would catch it. Reachable only via
   a shared store across modules where a later module adds a tag (the
   runner shares one store per .wast script; the corpus EH files have
   tags present before compile, so it doesn't trigger). The compile-time
   fence is sound for the corpus + the common single-module case.
3. **(Low) epoch interrupt LOST (not just delayed)** across a nested
   interpreted callee that never returns: compiled A calls interp B
   (infinite loop) after an epoch bump predating the call → B's fresh
   snapshot misses it → interrupt lost under JIT, caught under interp.
   Fix: don't re-seed Store.EpochSnapshot on nested wasm→wasm re-entry
   (only at the outermost guest entry — reuse the GC-chain-empty check).
4. **(Low, latent) @AIns const-record-by-reference** baked as a runtime
   pointer in the mem/table/GC/v128/branch-ref templates; relies on FPC
   passing the const record by reference through the forwarding hops.
   Holds empirically (8562 funcs, fails loudly not silently). Fix: pass
   the IR index + re-derive @Fn^.Code[i], or a startup assertion.

The clean unifying fix for #1 and #2 is making the JIT seam frames
TRANSPARENT to the unwind (pop-through) and to the tail-call trampoline
(cross-tier hand-back via a shared loop), which also retires the
over-broad tag fence and lets MORE functions compile. It touches the
Track-H-verified-clean unwind, so it needs care + the full EH corpus as
a regression net. #3 and #4 are small and low-risk. DECISION PENDING:
(a) do the seam-transparency hardening, (b) do only #3+#4 (low risk),
(c) defer all four as documented opt-in-JIT limitations and move to
Wave 7 (x86-64) or Track J (AOT).

---

## (prior) Handoff — Track I foundation + numeric/control spine

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
