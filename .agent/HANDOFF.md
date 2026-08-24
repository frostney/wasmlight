# Handoff

Updated: 2026-08-24 (issue #24 i386 pre-merge repair)

## Issue #24 — restore i386-win32 builds and PR coverage

- Started from freshly fetched `origin/main@0553507` in isolated branch
  `codex/fix-i386-pr-ci`; the pre-existing dirty retrospective worktree was not
  touched.
- Replaced the artificial multi-gigabyte `TArm64GcAllocArray` declaration with
  a typed `^TWasmGcAllocShape` pointer. The unit already enables pointer math,
  so existing indexed reads retain their behavior without declaring an array
  the 32-bit compiler cannot represent.
- Copied the existing `i386-win32` Windows target from post-merge CI into the
  PR matrix and updated the workflow comment to describe both Windows targets.
- Local evidence on macOS/Arm64: frozen install; focused Arm64/JIT suites 2/2;
  format 91/91; generated-agent check; development build 3/3; full tests 44/44;
  `actionlint` clean with the pre-existing SC2005 warning ignored; diff check.
  Exact i386 compilation, tests, smoke, and interpreter conformance await the
  new PR job on the published exact head.

Updated: 2026-08-23 (Wave 14 x64 numeric struct-field access accepted)

## Runtime optimization skill retro follow-up — adopted

- Resumed the unpublished retro follow-up from local commit `2b9a82d` onto
  freshly fetched `origin/main@92c2de3` as commit `4869b50` on
  `t3code/adopt-optimize-runtime`; the original sibling branch was stale and
  had never published this commit in a pull request.
- `.agents/skills/optimize-runtime/SKILL.md` now requires release-binary hash
  verification against the immediate predecessor, a host-load check before
  each measurement schedule, and mechanism-plus-measurement evidence for every
  rejected experiment. These are workflow safeguards only; runtime source,
  benchmark implementations, tier behavior, and architecture contracts are
  unchanged.
- The resumed change passed the skill validator in an isolated `uvx` PyYAML
  environment, frozen install, format, generated-agent check, Markdown lint,
  development build of all three programs, and all 44 default test programs.
  No runtime benchmark or spec-corpus rerun applies to this documentation-only
  workflow change.

## Wave 14 — numeric fixed-struct field access natively on x64 ACCEPTED

- Started from freshly fetched `origin/main@e7ee03be80ad713c4061308c224bb096a1df2e72`
  (merged PR #20) in clean branch `t3code/optimize-runtime-wave14`. The single
  accepted commit is `2e33b67fc8cef4d5baa7b7192d8f07f613bf129a`
  (`perf(jit): emit numeric struct fields natively on x64`), local and
  unpushed. The integration was an exact fast-forward to that measured lane
  commit, so no post-measurement source combination was introduced.
- Fresh exact-main macOS/Arm64 best/AOT baseline (one warm-up, seven rotated
  samples) left direct call as the sole goal miss: 144.659 ms versus Wasmtime
  59.792 ms (2.42x). The remaining ratios were startup 0.64x, loop 1.04x,
  fib 0.93x, memory 1.17x, memory-load 1.14x, memory-store 1.41x,
  memory-grow 0.99x, gc 0.93x, SIMD 1.29x, and host-call 0.90x. Raw evidence
  is `/tmp/wasmlight-wave14-baseline-e7ee03b.json`.
- A five-second `sample(1)` profile of a self-checking 30x scaled call module
  put all 3,875 samples in generated code. Two different bounded Arm64 call
  experiments were therefore measured and REJECTED: (1) omitting zero MOVK
  halves shortened the hot function from 269 to 242 instructions but
  regressed B-C-C-B by 38.67% forward / 63.02% reverse (raw
  `/tmp/w14-imm-{base1,cand1,cand2,base2}.json`); (2) rescheduling independent
  cap loads was flat/noisy at -0.08% with fully overlapping ranges (raw
  `/tmp/w14-call-{base1,cand1,cand2,base2}.json`). Both worktrees were fully
  reverted and remain clean with no commits. Do not retry activation-wide
  hoisting, per-instance call tables, scaled-LDR-only, zero-MOVK omission, or
  this cap-load scheduling shape without new evidence.
- The accepted x64 mechanism reuses the driver's validated per-instruction GC
  shape analysis. Eligible numeric `struct.get`, `struct.get_s`,
  `struct.get_u`, and `struct.set` sites receive only a validated width,
  signedness, and byte offset. The x64 emitter performs the cached reference
  load and null-structure trap before a direct canonical scalar load or
  truncating store. Numeric stores require no write barrier; reference/vector
  fields, arrays, and ineligible shapes retain the unchanged generic helper.
  No runtime address is baked, and allocation, GC, safepoints, barriers, and
  AOT PIC/fingerprint contracts are unchanged. Differential tests pin signed
  and unsigned packed loads, read/write round trips, exact null-trap order,
  and an unrelated cached local surviving the access; x64 byte-shape tests
  pin direct load/store emission and absence of runtime dispatch.
- Linux/x86-64 profiling ran in OrbStack 7.0.14, explicitly virtualized amd64
  over Arm. `perf_event_open` is unavailable there (`ENOSYS`), so no sampling
  claim was made. A controlled exact-release self-checking profile instead
  measured 20 million fixed-field accesses at 3,032.418 ms versus a matched
  numeric control at 193.271 ms (15.69x, about 142 ns/helper crossing). The
  first VM preparation under `/tmp` was discarded after stop/start erased the
  VM tmpfs; all accepted source, binaries, raw data, and gates were rebuilt
  durably under `/home/jstein/w14-x64-field` with checksum-verified LWPT 0.6.0.
- Exact retained binary B-C-C-B (one warm-up, seven samples per leg under the
  persistent flock gate) improved the standard GC workload
  **1265.464 -> 908.161 -> 915.298 -> 1267.813 ms**, -28.23% forward and
  -27.80% reverse, with candidate maxima below baseline minima. Raw files are
  `/home/jstein/w14-x64-field/measurement/gc-{base1,cand1,cand2,base2}.json`.
  The isolated 20M field workload measured
  **3046.743 -> 219.657 -> 220.406 -> 2966.666 ms**, -92.79%/-92.57%, with
  all legs self-checking and disjoint. Raw files use the corresponding
  `measurement/field-*` names.
- The complete x64 best-profile 11-workload guard pair measured GC at
  1032.180 -> 703.613 ms (-31.83%); loop, fib, memory, load, store, and call
  overlapped and stayed within +/-1.82%, while several other paths improved.
  Startup's apparent +6.449 ms was classified as noise by its own B-C-C-B
  (45.600, 47.478, 44.627, 47.516 ms): forward +4.12%, reverse -6.08%, all
  ranges overlapping. Guard raw files are `measurement/guards-{base,candidate}.raw.json`
  and `measurement/startup-{base1,cand1,cand2,base2}.json` in the durable VM
  evidence directory. Both OrbStack VMs were restored to running and the
  persistent timing lock was verified free.
- Exact accepted x64 gates pass: frozen install; format 91/91; agents check;
  dev and release build 3/3; all 44 test programs (focused JIT 68/68 and x64
  26/26); pinned core corpus byte-identical across interpreter/JIT/AOT at
  files=257 pass=65188 fail=0 skip=0 staged=0, with 8704 compiled functions in
  JIT/AOT. Independent exact integration gates on macOS/Arm64 pass frozen
  install, format, agents check, diff check, Markdown lint, dev/release 3/3,
  all 44 tests, and the same 65,188/0/0 core tally in every tier (8703 compiled
  in JIT/AOT). The recursive 288-file diagnostic also reproduces the documented
  65851/368/904/0 proposal-and-legacy residue tally.
- Next x64 optimization candidates, only after a fresh baseline/profile, are
  the already accepted Arm64 fixed-array access mirror and then allocation.
  On Arm64, direct calls remain the only current 1.43x goal miss, but the two
  new rejected mechanisms above remove the obvious small instruction-selection
  variations from consideration.

## Wave 13 — adjacent Arm64 vector-result moves fused ACCEPTED

- Continued from the accepted Wave 12 integration head `675213a` after a
  fresh fetch confirmed `origin/main@1a89b4779e71b855cbbac7d90ebc69aee31b6295`
  was unchanged. The accepted implementation is `93b3278` (`perf(jit): fuse
  adjacent Arm64 vector result moves`) plus the required correctness follow-up
  `85b2737` (`fix(jit): preserve live Arm64 vector temporaries`), both local
  and unpushed on `t3code/optimize-runtime-parallel`.
- The fresh seven-sample best/AOT baseline at `675213a` measured call 136.516
  ms versus Wasmtime 60.037 ms (2.27x), SIMD 8.429 versus 4.572 ms (1.84x),
  memory-load 45.281 versus 30.239 ms (1.50x), and GC 24.582 versus 26.903 ms
  (0.91x). Scaled self-checking `sample(1)` profiles put effectively every
  call and SIMD sample in generated code, so three isolated lanes covered
  local call instruction selection, adjacent SIMD traffic, and the borderline
  memory-load path.
- The retained Arm64-only compile plan recognizes a native v128 producer
  immediately followed by `iroMoveVec` into a visible local/result slot. It
  redirects the producer to that canonical slot and skips the redundant
  Q-register load/store pair only when the producer temp is a non-visible
  `wvkVec`, the destination is visible, neither instruction is a branch
  target, and an `IR_OP_INFO`-driven source scan proves the temp has exactly
  one use (including direct fields, Imm source registers, and A-aux argument
  lists). No vector value is cached across an instruction or control-flow
  boundary; the static-cache, Q-host-constant, prologue, and alignment designs
  rejected in earlier waves remain absent.
- Independent review caught a real defect in the first measured commit before
  integration: `local.tee` writes the visible local but deliberately keeps the
  producer temporary live on the operand stack. The initial peephole left that
  temp unwritten. A fresh-store `tee_both` differential reproduced the failure
  (a same-store differential could be masked by interpreter residue); the
  follow-up single-use proof now retains the 180-byte unfused shape for that
  case while the safe shapes remain 148/176 bytes.
- The corrected exact candidate (`0eb642df...`) passed a fresh serialized
  B-C-C-B: **8.602 -> 5.742 -> 5.827 -> 8.809 ms**, improving SIMD 33.25%
  forward and 33.85% reverse. Wasmtime-normalized ratios improved from
  1.736x/1.762x to 1.189x/1.176x (-31.54%/-33.25%). Raw results are
  `/tmp/w13-simd-guarded-{base1,cand1,cand2,base2}.json`. The integrated
  seven-sample full schedule independently measured SIMD at 5.412 ms versus
  Wasmtime 4.450 ms (1.22x). Its release binary
  `/tmp/wasmlight-wave13-integrated.Vsucn8/wasmlight` is byte-identical to the
  guarded lane binary.
- The full schedule's scalar call/memory medians retained their documented
  broad dispersion. Deterministic AOT comparison proved every non-SIMD
  workload artifact byte-identical between the retained Wave 12 and integrated
  Wave 13 binaries; only `simd.waot` changed, so those scalar swings are not
  codegen regressions from this wave.
- REJECTED and fully reverted with clean, uncommitted lane branches: (1) a
  scaled-immediate `LDR W` removed two instructions from the hot direct-call
  lookup, but the only clean forward pair was effectively flat (145.124 ->
  143.941 ms, -0.82%) and the reverse baseline suffered corroborated host
  drift; artifacts are under
  `/tmp/wasmlight-wave13-call-measure/{base1,cand1,cand2,base2}.json`.
  (2) preferring the widest loop constant reduced the memory-load loop from
  16 to 14 instructions, but candidate medians differed by 23.9% and the
  apparent gains (14.30%/3.90%) overlapped 21-41% dispersion; artifacts are
  `/tmp/w13-memory-{base1,cand1,cand2,base2}.json`.
- Exact integrated gates pass: frozen install; release build 3/3; format 91/91;
  agents check; diff check; all 44 unit programs. The recursive pinned corpus
  at `de54fd27` is byte-identical across interpreter/JIT/AOT:
  files=288 errors=0 pass=65851 fail=368 skip=904 staged=0 total=67123, with
  compiled=8799 in JIT/AOT. The corpus was read from the clean pinned checkout
  under `t3code-b5095128` because this isolated worktree had no local fetched
  mirror. `lantaarn-spike` and `wasmx64` were gracefully paused for timing and
  restored to running afterward.
- Begin the next wave from `85b2737`. SIMD is now inside the 1.43x Wasmtime
  goal and GC remains faster on its diagnostic. Direct calls remain the clear
  out-of-band gap, but do not retry activation-wide hoisting, per-instance
  call tables, or the scaled-LDR-only candidate; otherwise prioritize x64
  mirrors of accepted Arm64 struct/array GC paths.

## Wave 12 — fixed-type scalar array access natively on Arm64 ACCEPTED

- Exact starting point was fetched `origin/main@1a89b4779e71b855cbbac7d90ebc69aee31b6295`
  after PR #19 merged green. Delivery branch
  `t3code/optimize-runtime-parallel` now points at accepted commit `cbbc09e`
  (`perf(jit): emit fixed-type array access natively on arm64`); it is local
  and unpushed. The retained exact-main release binary is
  `/tmp/wasmlight-wave12-base.ySYtuH/wasmlight`, SHA-256 `364aa3bd…`; the
  integrated release is `f103d8f7…`, byte-identical to the accepted lane
  binary.
- Fresh exact-main comparison (Apple M5 Max, macOS 26.5.2/arm64, best/AOT,
  one warm-up discarded, seven samples) put gc at 45.705 ms versus Wasmtime
  28.858 ms. A 4-second `sample(1)` profile of a self-checking 250M-iteration
  scaled module attributed the largest named leaf to `ArraySet` (254 samples),
  plus layout resolution 189, `GcRefTypeId` 122, array length 79, the v1 empty
  write barrier 44, and 85 runtime IR-aux reads. This confirmed fixed-type
  array access as the next bottleneck on current main.
- Mechanism: the driver bakes validated fixed-array width, signedness, element
  base, and reference shape into the existing per-instruction GC shape word.
  The Arm64 emitter performs null, kind/invariant, and unsigned bounds checks
  in the runtime's original order, then uses scaled `[base,Windex,UXTW]`
  loads/stores for scalar `array.get/get_s/get_u/set`. A validator-unreachable
  kind mismatch retains the unchanged runtime `EWasmInternal` helper route.
  Reference stores are direct because the stop-the-world v1 write barrier is
  deliberately empty and the store cannot collect; the code comment requires
  reference shapes to decline or gain a PIC helper before that collector
  policy can become non-empty. No process/store/type address is baked, so AOT
  PIC, fingerprint, and artifact compatibility are unchanged.
- Clean serialized lane B-C-C-B under the persistent `fcntl` performance lock
  (release, one warm-up, seven samples) measured gc
  **44.876 -> 25.883 -> 25.663 -> 43.704 ms**: -42.33% forward and -41.28%
  reverse, with fully disjoint ranges (bases 43.616-45.091 / 43.068-44.367;
  candidates 25.529-26.275 / 25.339-26.157). Same-schedule candidate/Wasmtime
  ratios were 0.92x/0.90x. Raw full schedules are
  `/tmp/w12-array-{base1,cand1,cand2,base2}.json`.
- The post-integration target-only B-C-C-B independently confirmed the exact
  combined state: **43.551 -> 24.925 -> 24.182 -> 43.631 ms**, or -42.77%
  forward and -44.57% reverse; ranges remained disjoint. Raw results are
  `/tmp/w12-integrated-{base1,cand1,cand2,base2}.json`. The full lane schedule
  found no material guard regression: startup/fib/host-call stayed in their
  prior bands; loop/SIMD movement co-drifted with peers; memory and call kept
  their already documented broad, bimodal within-leg spreads.
- Correctness on exact `cbbc09e`: focused Arm64 27/27 and JIT 67/67; all 44
  unit programs; release builds of all three apps; frozen install; format;
  agents check; diff check. The recursive pinned corpus is byte-identical in
  interpreter/JIT/AOT: files=288 errors=0 pass=65851 fail=368 skip=904
  staged=0 total=67123, compiled=8799 in JIT/AOT. New differentials force a
  collection after a reference-array store (the stored struct is reachable
  only through the array), pin null-before-bounds, and keep an unrelated dirty
  cached local live across native `array.get`.
- A review caught and fixed the initial candidate's only correctness defect
  before measurement: a common cache invalidation could discard an unrelated
  dirty dynamic value. Native gets now use `Arm64CachedStore`; native stores
  preserve the existing cache state; the new `dirty` differential fails the
  old form. No result from the earlier loaded-VM/compiler period was accepted.
- REJECTED lanes, fully reverted with clean worktrees and no commits:
  (1) direct-call target/cap hoisting expanded the Arm64 frame and added 276
  lines but clean B-C-C-B paired medians regressed call by 8.56% (149.282 ->
  162.066 ms), guards flat; raw files under
  `/tmp/wasmlight-wave12-call-measure/`. (2) SIMD scalar static-cache admission
  was recognized as the already-rejected Wave 3 shape; one clean forward leg
  made the loop smaller (57 -> 42 A64 instructions) but regressed SIMD 12.10%
  (9.183 -> 10.294 ms, disjoint ranges), so reverse legs were deliberately not
  repeated; evidence is `/tmp/wasmlight-wave12-simd-evidence/`.
- Process notes: current `bench.py` uses `fcntl.flock` on the persistent
  zero-byte regular `/tmp/wasmlight-perf-gate.lock`; do not replace it with the
  older directory-lock protocol. Harness locks do not serialize unrelated lane
  compilers/probes, so the integration owner must grant explicit measurement
  windows. `lantaarn-spike` and `wasmx64` were gracefully paused for accepted
  timing after vmgr reached ~3 cores, then both restored to their prior running
  state.
- Remaining out-of-band priorities after this wave: direct calls (the hoist
  design lost; re-profile before a genuinely different mechanism), SIMD (do
  not retry static-cache admission or alignment), then x64 mirrors of the
  accepted Arm64 struct/array GC paths. GC itself is now faster than Wasmtime
  on this diagnostic shape and is no longer the first gap.

## PR #19 CI repair

- Exact failing head `eac9dbe`: Linux/x86-64 and runtime-comparison builds
  could not resolve the arm64-only `TWasmGcAllocShape` / `TWasmGcAllocInfo`
  types because their driver variables and analyzer were backend-shared.
- Repair: compile those declarations and the analyzer only under
  `WASM_JIT_ARM64`; keep exact-size eligibility aligned with the PR claim
  (`CellSize == Size`); remove the temporary `WASMLIGHT_DUMP_FASTPATH`
  emitter output.
- Current local evidence: macOS/arm64 focused JIT + emitter suites pass;
  Ubuntu Noble/x86-64 release builds all three programs and passes the JIT +
  X64 suites; the universal macOS gate passes frozen install, format, all
  three builds, all 44 test programs, `lwpt agents --check`, and diff check.
- PR #19 merged as `1a89b47` with every configured check green. Re-query its
  exact head and checks rather than relying on this handoff for live CI state.

## Wave 11 — inline struct.new allocation fast path ACCEPTED

- Commit `6aea5ef` (`perf(jit): inline the struct.new allocation fast path
  on arm64`) on `t3code/optimize-runtime-wasmtime-gap-2` from exact
  `12c41b7` (the post-PR-18 main tip). Published through draft PR #19.
- Mechanism per the wave-11 design: eligible `struct.new` sites emit the
  whole free-list-hit allocation inline — context-chain engine-id walk,
  heap/head load, cbz miss branch into the UNCHANGED generic emission (still
  THE collect safepoint per ADR-0011), pop, bitmap mark, counters ×3,
  two-half header, baked numeric field stores, Dest publish last. Driver
  analysis mirrors Allocate's class math exactly; pow2 classes only
  (16/32/64/128/256 — where CellSize == AlignUp(layoutSize,8), so the tail
  is zero by construction and no inline zeroing is needed); declines ref/v128
  fields, struct.new_default, arity > 16, non-pow2/large cells, offsets out
  of imm12 range. New probes (WasmJitGcHeapOffsets, WasmJitStoreAllocOffsets)
  expose the private anchors; ALL folded into the ABI fingerprint, revision
  15 (old artifacts fail closed).
- TWO emitter defects found and fixed inside the wave:
  1. Arm64MaddX used the $8B (ADD/W-MADD) base instead of $9B — the walk
     computed a garbage activation address; found by bisect + llvm-mc
     cross-check of the pinned words.
  2. The header stores preceded the link pop, overwriting [head+0] before
     the link was read — the free list was poisoned with mark-state values
     and the NEXT fast-path allocation jumped to garbage. Found only when a
     workload actually recycles cells (runtime-comparison gc module under
     --aot); the corpus never fires the fast path (tiny heaps, empty lists),
     which is why three-tier corpus identity alone did not catch it. The
     reuse test now covers this shape.
- Serialized release A/B under the perf gate (bench.py best profile, 1
  warmup discarded, 7 samples, BASE-CAND-CAND-BASE): gc **−39.9%/−39.9%**
  (76.209/76.511 → 45.780/45.773 ms; spreads disjoint: base 75.86–85.51,
  cand 45.34–46.16). Guards flat within this host's documented noise:
  fib/call/host-call/simd/startup deltas < ±2%; loop and memory-* legs
  drifted across LATER legs on BOTH binaries (base2 measured loop 362.9 ≈
  cand's 363.0), so those swings are host drift, not candidate effects —
  no guard regressed in like-for-like order pairs.
- Band status vs same-schedule Wasmtime-AOT medians: IN BAND startup 0.67x,
  host-call 0.90x, fib 0.93x, memory-grow 0.89x, loop 1.06x, memory 1.13x,
  memory-load 1.19x; BORDERLINE memory-store 1.45x; OUT OF BAND gc **1.61x**
  (was ~2.5x), call 2.30x, simd 1.82x. Goal remains every workload ≤ 1.43x.
- Correctness on the accepted head (release `8613383e…`): 44/44 unit suites;
  corpus byte-identical in interpreter/JIT/AOT at pass=65851 fail=368
  skip=904 staged=0 errors=0 (compiled=8799); format, agents check, frozen
  install, diff-check, Markdown lint green. New tests: differential
  recycled-cell reuse under threshold-0 forced collects (both tiers agree)
  and a 43-word pin of the emitted fast-path sequence.
- PROCESS NOTE: dev and release builds have DIFFERENT object layouts
  (test-only fields under {$IFNDEF PRODUCTION}); probes are self-consistent
  per build and the fingerprint keeps artifacts from crossing builds — do
  not compare dev-baked offsets against release runs.
- Next lanes in priority order: (1) native array.get/set with baked element
  offsets + bounds check (remaining gc-workload crossings + runtime IrAux
  reads); (2) hoist per-call target/cap resolution across backedges for
  proof-gated direct calls (call lane, ~22 instructions around each blr);
  (3) simd microarchitectural bisect (wave 7 ruled out alignment);
  (4) x64 mirrors of the arm64 GC lanes.

## Wave 11 design record — superseded by the execution above

- Scoping pass produced every remaining design answer; implementation did
  not start (GC-critical surface + late-session budget). Build order for the
  dedicated session:
  1. PROBES: mirror WasmJitFrameOffsets' uninitialized-local address trick.
     Needed: (a) Gc-unit probe for TWasmGcHeap privates {FFree[0] base,
     FMarkState, FBytesLive, FBytesAllocated, ObjectCount}; (b) Store-unit
     probe for {TWasmStore.FHeap} and {TWasmModuleInstance.EngineTypeIds} —
     both classes, so the probe constructs a throwaway Engine/Store/Instance,
     takes field addresses, frees, caches lazily. Block-field offsets
     (Base@8, Allocated dyn-array ptr) are computable in the backend directly
     if TWasmGcBlock is interface-visible (verify).
  2. ENTRY ABI DECISION (pick one): load the runtime engine type id via the
     context chain (~7 instructions per alloc: ctx.Acts[Depth-1].Instance.
     EngineTypeIds[idx]; all offsets already probed except EngineTypeIds),
     OR pass Instance as a new compiled-entry argument (x5) — cleaner code
     but bumps the entry ABI fingerprint (fails old artifacts closed) and
     touches both InvokeCompiled marshals + AOT wiring.
  3. FAST PATH (free-list hit ONLY; miss → existing AllocStruct dispatch
     sequence emitted inline as the slow branch — it remains THE collect
     safepoint per ADR-0011): head = [heap+FFree0+cls*8]; cbz → slow; pop
     link; bitmap word |= bit (cell = diff >> log2CellSize — POW2 CLASSES
     ONLY initially, {16,32,64,128,256}, others decline to helper); tail
     zero ≤ 8 bytes (decline larger); header := markState | kindConst<<2 |
     typeId<<32; counters BytesLive/BytesAllocated += CellSize, ObjectCount++
     (~7 instrs, non-negotiable); numeric field stores at baked offsets
     (truncating strb/strh like WriteField); publish Dest last.
  4. DECLINES: any ref field (barrier shape), v128 field, non-pow2 cell,
     tail > 8, struct.new_default (defaults loop differs).
  5. GATES: differential gc module exercising free-list reuse across a
     forced collect; corpus ×3 tiers; byte-pin test for the sequence.
- ZeroCell shrink question remains open (needs the nothing-reads-raw-bytes
  proof) but is INDEPENDENT: fast path can keep full ZeroCell semantics by
  simply declining to skip it (zeroing stays in the slow path; fast path
  writes header+fields over recycled bytes whose stale content is only
  reachable through fields it immediately overwrites or tail bytes it
  zeroes — write the argument down either way).

## Wave 10 — struct.new fills resolve layout once ACCEPTED (small)

- Commit `bbedb4a` (`perf(gc): resolve struct.new field layout once per
  fill`). New heap method `StructSetSeq(Ref, Values, Count)`: one null/kind/
  bounds check and ONE LayoutOf resolution, then N direct WriteField calls —
  replacing N per-field StructSet crossings that each re-resolved the layout
  (the fresh profile showed 78 samples of TWasmGcTypes.Layout under
  StructSet). Both tiers route through it for arities ≤ 8 via a stack temp;
  larger arities keep the legacy loop. The v1 write barrier is empty by
  design, so the sequential fill is observably identical.
- Serialized A/B vs the true wave-9 head (ec294dd, rebuilt + hash-retained at
  /tmp/wave9-head.ec294dd): gc −4.1%/−1.4% — small, forward-dominant, no
  regression in 14 samples. Corpus byte-identical in all three tiers on this
  exact tree; format green. NOTE: an earlier comparison against the WAVE-6
  baseline read −27% — always diff against the IMMEDIATE predecessor head.
- Post-wave-9 gc profile (for the next session): alloc family ~52%
  (AllocStruct 558+158, TakeCell ~414, Collect/Sweep only ~170), StructSet
  family down to ~9% after this slice, generated body ~58% — inline
  allocation is now unambiguously the next move, exactly per wave 8's design
  notes.

## Wave 9 — numeric struct.get/get_s/get_u/set natively on arm64 ACCEPTED

- Commit `ec294dd` (`perf(jit): emit numeric struct field access natively on
  arm64`). The driver's AnalyzeGcFieldAccess mirrors TWasmGcTypes' layout
  math exactly (header 8, per-field align-up to storage width, cumulative
  advance) over AIr.CanonTypes[TypeIndexToCanon[Imm.hi]].Comp, baking offset/
  width/signedness into a per-instruction shape word (bit0 native, bit1
  signed, bits8-15 width, bits16-31 offset). Ref fields and v128 stay on the
  helper path (write barrier / Q regs); offsets that do not fit the scaled
  imm12 decline. Arm64EmitGcFieldAccess emits: cached ref load → cbnz past a
  type-specific null trap (`wtkNullStructReference`, same kind and position
  as the helper) → width-sized load with sign/zero extension or width-sized
  store from the value's cache host. No engine ids are baked — offsets are
  pure functions of the module composite, so AOT artifacts stay
  instance/store-agnostic.
- Emitted shape per access ≈ 5 instructions replacing a full helper crossing
  plus internal layout resolution. Verified by carve: `ldrsb w10,[x9,#24]`
  for an i8 get_s at baked offset 24.
- Serialized release A/B vs the wave-6 baseline binary: gc **−24.8%/−25.2%**
  (101.2/101.5 → 76.1/75.9 ms; spreads fully disjoint). gc/Wasmtime ratio
  improves from ~3.5x to ~2.6x. All other workloads untouched (shapes fire
  only for struct ops).
- Correctness: 44/44 suites; corpus byte-identical interp/JIT/AOT at
  pass=65851 fail=368 skip=904 staged=0 errors=0 (compiled=8799); format
  green. x64 inert (shape array only passed to the arm64 call site).
- Follow-ups in priority order: (1) native struct.new allocation fast path
  per wave 8's design notes (now the largest remaining gc cost); (2) native
  array.get/set with baked element offsets + bounds check (kills the runtime
  IrAux reads ~140 samples and another crossing); (3) x64 mirror of both.

## Wave 8 — GC groundwork: fresh profile, layout memo REJECTED as noise

- Refreshed `sample(1)` profile of the scaled gc workload on the current head
  (3824 loop samples): alloc family ~23% (AllocStruct 602+200, TakeCell ~430,
  Collect/Sweep only ~170 ≈ 5%), StructSet family ~9% (body 138,
  **TWasmGcTypes.Layout re-resolution 85**, GcRefTypeId 37 = roots-array ref
  barrier — inherent), IrAuxBlockItem/Count runtime reads ~140 (the array-set
  dispatch reads aux tables per call at runtime), generated body ~43%.
- Tried: single-entry Layout memo in TWasmGcTypes (fields FMemoId/FMemoLayout,
  High sentinel ctor, resets in Define/Grow because SetLength reallocates).
  Correct, all suites green — but serialized release A/B measured gc
  −1.4%/+1.0%: flat within noise. REJECTED per the no-repeatable-delta rule;
  reverted; binary hash back to the exact wave-6 build.
- **PROCESS GUARD, SECOND OFFENSE**: an interim A/B compared a DEV-mode
  candidate against the RELEASE baseline again (gc "277 ms", +164%). The
  signature is unmistakable: compiled-tier workloads ~2.6x slow, perfectly
  stable across legs. RULE: after ANY `lwpt build wasmlight`, a release
  rebuild (`lwpt build --mode release`) is mandatory before any measurement;
  check `shasum build/wasmlight` against the retained baseline binary when in
  doubt. Consider a wrapper or hook to enforce this.
- DESIGN GROUNDWORK for the dedicated inline-allocation session (the only
  lane that moves gc materially): free-list pop is FFree[const class] head +
  link load/store (~4 instrs); the blocker is SetCellAllocated's bitmap word
  (cell = (head−Base)/CellSize, then div-32 index + variable-shift ORR ≈ 7-8
  instrs — CellSize is compile-time constant per fixed type so magic-multiply
  applies); ZeroCell can shrink to a tail store ONLY if nothing reads raw
  cell bytes outside layouts (needs a design-doc proof before touching);
  counters (FBytesLive/Allocated/ObjectCount) must still update (~6 instrs);
  threshold-check/collect stays as THE allocation-site safepoint per
  ADR-0011; slow path = existing helper unchanged. Estimated fast path ~25-30
  instructions vs ~40 today including crossings — worth it only together
  with native struct.get/array.set to also kill the crossing overhead.
- The array.set runtime aux reads (~140 samples) are the same shape as the
  struct.get/array.set native-template lane; bounded follow-up: bake the
  field index/count into the emitted code for fixed-type array shapes.

## Wave 7 — fetch-alignment padding for backward targets REJECTED

- Tested wave 5's residual theory directly: pad every backward-jump target
  (loop header) to a 16-byte boundary with A64 NOPs before BindLabel, so
  iterations enter on a full decode window. Semantically transparent — corpus
  identity held immediately (65851/368/904 in jit); one shape-pin test grew
  by the two NOP words as expected.
- Clean-environment serialized A/B (after catching and stopping a UTM/QEMU
  Windows VM that had been eating ~176% CPU and poisoning several earlier
  legs — always `ps aux -r` before trusting a schedule): loop −0.6%/−0.2%,
  simd +2.4%/−2.2%, fib/memory flat, memory-store unmeasurable (its samples
  are bimodal 27–49 ms even within one leg on this host). No repeatable
  positive delta → reverted; binary hash back to the exact wave-6 build.
- CONSEQUENCE FOR WAVE 5: simple loop-header alignment does NOT explain why
  the smaller vector loop measured slower. The simd retry needs a real
  microarchitectural bisect (candidates: scalar-static allocation inside vec
  functions forcing value slot round-trips; Q-bank effects; per-op cache
  invalidation patterns). Do not re-attempt on the alignment theory.

## Wave 6 — leaf-core operand cleanup ACCEPTED

- Two contained changes on top of f191e18, commit `6187bae`
  (`perf(jit): forward native-core param aliases and emit consts in place`):
  1. AnalyzeLocalAliases' gate widened from `(UsePinnedMemoryBase and
     UseStaticCache)` to also admit `UseNativeScalarCore` — the pass already
     forwarded local.get-moves into consumers for memory loops; closed
     native-scalar cores have the identical proof shape (helper-free,
     params in fixed hosts, one-use temps). ImmediateFusion and
     StoreLoadForwarding keep their narrower gates deliberately.
  2. Cached iro*Const emission now reserves its destination victim first
     (Arm64CachedDestReg) and materializes the immediate directly into it,
     removing the T0→victim mov hop per constant in write-back mode.
- Evidence: carved leaf core of a two-arg LCG leaf shrank 14 → 9
  instructions (`eor w14,w12,w13` consumes ABI regs directly; consts land in
  value positions); remaining double-bounce (`mov x15,x14; mov x12,x15`) is
  blocked by the x12 fixed-mapping conflict (result reg cannot share the
  param's cache slot) — needs a result-register mapping design if pursued.
- Serialized A/B under load (host ~3x slower than usual during this run —
  absolute medians inflated equally on both sides, relative deltas valid):
  fib(35) **−10.3%/−8.2%**, call −2.9%/−2.4%, both orders consistent.
  Fib gains most because self-recursion executes the cleaned core.
- Wasm.Jit.Arm64.Test's dynamic-write-back test re-pinned to the tighter
  emission (28 bytes dead / 32 bytes one-spill, spill word at index 6).
- x64 inert: the widened gate sits inside the ARM64 ifdef.
- Next call-lane step (unbuilt): hoist per-call target/cap resolution across
  backedges for proof-gated direct calls to compiled leaves — caller-side
  plumbing (~22 instructions around each blr) dominates over the callee now.

## Wave 5 — v128 constant Q-hosts + vector static-cache admission REJECTED

- Lane built directly on wave 4's const-slot machinery: admitted
  Arm64NativeVecOp into StaticCacheOp (vector loop functions become static-
  cache eligible), extended AnalyzeConstSlots with iroV128Const candidates
  (pair base slot, 128 bits from IrAuxReadV128, offered only when defined in
  a loop span and EVERY consumer is a native vec template — helper-dispatched
  readers would see an never-written canonical pair), seeded caller-saved
  v16/v17 once at frame entry via two LoadImm64 + INS pairs (new builder
  Arm64MovGeneralToVecD, imm5 = %01000 + lane<<4, verified against
  `mov v16.d[0],x9` = 4E081D30), parameterized every EmitNativeVec source
  load through a host-aware resolver, routed native vec ops through the
  cached path WITHOUT flush/invalidate, and made splats consume scalar cache
  hosts directly.
- Generated code was correct and much smaller: the simd loop went from ~47
  to ~28 instructions — const-B hosted in v16 (`add.4s v0,v0,v16`), limit
  hoisted to x14, splat reading w15. Measured result was a REPEATABLE
  REGRESSION: serialized simd-only A/B (7 samples, both orders) gave cand
  11.455/11.489 ms vs base 9.484/9.986 ms (+17-21%, disjoint spreads); the
  full-schedule legs agreed (+18.2%/+12.7%).
- Root cause NOT fully identified: fewer instructions but slower — the same
  wall wave 3 hit when admitting vector ops to the static cache. Suspected
  residual: changed loop-body code layout/fetch alignment (backedge target
  moved from 0x60, 16-aligned, to 0xac) and/or spill-pattern side effects of
  scalar static allocation inside vector loops. Fully reverted; nothing
  remains in the tree. Any retry must first explain WHY the smaller loop is
  slower — e.g. by bisecting eligibility-admission alone vs Q-hosting alone,
  or by measuring with forced 16-byte alignment padding before the loop
  header.

## Wave 4 — loop-invariant constants seeded once in static cache hosts

- Goal for this session was "0.7x–0.85x of Wasmtime": every wasmbench
  workload at ≥70% of Wasmtime throughput (≤1.43x time). Baseline at exact
  `origin/main@e686e0a` (release binary sha256 `d795d942…`, retained at
  `/tmp/wasmlight-wave4-baseline.e686e0a/`) measured, serialized under the
  perf gate (best profile, 1 warm-up discarded, 7 samples): startup 2.47 ms,
  loop 378/365 ms, fib 33 ms, memory 22 ms, memory-load 41→44 ms,
  memory-store 49→36 ms, call 138→155 ms, memory-grow 13 ms, gc 106→112 ms,
  simd 8.4→10.7 ms, host-call 35→38 ms across the four legs — i.e. failing
  workloads were gc (~3.65x), call (~2.2x), simd (~1.9x), memory-store
  (~1.75x time).
- Profiles captured (`sample(1)` on long scaled AOT runs, artifacts under
  `/var/folders/mv/6_sclnc96hgfcv9gknbsqr880000gn/T/opencode/wave4-profile/`):
  - **gc**: ~44% generated loop body, ~37% allocation machinery
    (AllocStruct/Allocate/TakeCell + Collect/Sweep ≈4%), ~9% StructSet helper
    re-resolving TWasmGcTypes.Layout per set, plus InterpContextFor crossings.
    Three helper blrs per iteration (struct.new/array.set/struct.get).
  - **call**: 100% generated code, zero helpers. The native leaf core wastes
    ~6 of ~13 instructions moving operands into value positions
    (`mov x14,x12; mov x15,x13 … mov x17,x16; mov x12,x17`); the caller
    re-resolves FuncAddrs×sizeof/entry/caps every call (~22 instructions of
    plumbing around one blr).
  - **simd**: two v128 constants rebuilt via 8×movz/movk + slot traffic EVERY
    iteration, accumulator spilled/reloaded through canonical slots, scalar
    limit rebuilt per iteration. ~37 instructions where ~6 do the work.
  - **memory loops**: the br_if limit constant is materialized inside the
    loop body (movz+movk+mov) every iteration because its IR instruction is.
- Accepted commit `f191e18`
  (`perf(jit): seed loop-invariant constants once in static cache hosts`,
  branch `t3code/optimize-runtime-wasmtime-gap-1`): a driver analysis picks
  up to ONE constant-defined slot (unique writer, not already allocated,
  defined inside a backward-jump loop span, not SkipPlanned by fusion),
  `Arm64EnableConstSlots` appends it behind the leading statics and seeds the
  host register once at frame entry via immediate materialization, and the
  defining const instruction then emits nothing. The dynamic victim pool is
  now `[DynBase..DynBase+DynCount)` instead of hardcoded `[3..6]`
  (`TArm64RegCache.DynBase/DynCount/ConstFrom`); FlushDynamicRegCache keeps
  starting at StaticCount because native-core non-leaf mode keeps dirty
  parameter entries below any fixed boundary — that distinction is load-
  bearing and broke fac/fib i64 until restored. Arm64-only this wave; x64
  inert (enable call sits in the ARM64 block), so x86-64 corpus identity was
  trivially preserved but must be proven in the VM before any PR.
- Serialized release A/B BASE-CAND-CAND-BASE under `/tmp/wasmlight-perf-gate.lock`
  (7 samples each leg, raw JSON in `/tmp/ab2/*.json`): loop −3.8%/−3.8%
  (367.5/367.0 → 353.4/352.9 ms, disjoint spreads); all other guards flat:
  fib +0.9/+0.4, memory-load +2.6/−6.0, memory-store −2.7/+4.8, gc
  +1.1/−0.5, simd −1.4/+0.3, host-call +2.3/+0.6, grow/startup flat. The
  call reverse-leg median (+19%) was background host load — its samples are
  bimodal (136–192 ms) while both clean legs cluster 127–155.
- REJECTED variant: two const slots (K=2). Same schedule measured loop
  −5.5%/−6.7% BUT memory-load +21.8%/+8.7% in BOTH orders — appending a
  second host shrinks the dynamic pool to two registers and the load loop's
  expression pressure thrashes. Fully reverted before acceptance; do not
  re-attempt without a pressure-aware gate.
- PROCESS NOTE: an intermediate A/B compared a DEV-mode candidate against
  the RELEASE baseline (gc +173%, host-call +165%) — build modes must match
  on both sides of every comparison; dev builds are correctness gates only.
- Correctness on the accepted head (release `76eb3fd0…`): frozen install,
  format, agents check green; 44/44 unit suites; corpus byte-identical in
  interpreter/JIT/AOT at pass=65851 fail=368 skip=904 staged=0 errors=0
  (compiled=8799); Markdown lint clean.
- Band status after the wave (same-schedule Wasmtime medians): IN BAND
  startup 0.64x, loop 1.05x, fib 0.99x, memory 1.13x, memory-grow 0.99x,
  host-call 0.92x; BORDERLINE memory-load ~1.36x / memory-store ~1.34x
  (inside 1.43x but not improved by this lane — they are store/load
  bandwidth-bound, instruction removal hides under latency); OUT OF BAND
  simd ~1.87x, call ~2.2x, gc ~3.8x.
- Next lanes, pre-seeded with profile evidence above: (1) GC native inline
  allocation fast path in both backends (bump/free-list inline, collect
  slow path as the allocation-site safepoint per ADR-0011) — largest gap;
  (2) SIMD Q-register caching of vector values + v128 constant hoisting for
  call-free functions (wave-3's counter-caching variant failed; Q-value
  caching remains unbuilt machinery in both backends); (3) native scalar
  leaf-core operand cleanup (consume x12/x13 in place, produce x12) plus
  hoisting direct-call metadata resolution across backedges.

## Wave 3 — static cache for vector loops REJECTED and reverted

- Lane `optimize/vec-static-cache` from `4d83d63`: admitted the natively
  emitted vector op set (Arm64NativeVecOp/X64NativeVecOp — identical lists)
  into StaticCacheOp and restricted cache-slot selection to wvkNum slots.
  Built clean, results verified, but serialized simd A/B measured a
  regression: cand medians 11.122/11.335 ms vs base 10.686/10.312 ms
  (+4–10%, both orders). The extended-frame prologue plus per-exit
  write-back cost more than caching the loop counter saved. Fully
  reverted; nothing remains in the tree.
- Profile facts recorded for the next lanes (both from `sample(1)` on long
  AOT runs of scaled workload modules):
  - Scalar memory-load/store: 100% of samples inside generated code, zero
    helper crossings. The ~1.34x/1.51x residual vs Wasmtime is pure
    codegen quality (loop overhead amortized over one access), not chokepoint
    or helper cost — heavily mined territory (five prior waves, several
    recorded rejections).
  - SIMD workload: also 100% generated code now (PR #10 closed the helper
    crossings). The disassembly shows the remaining cost is spill/reload
    traffic through canonical frame slots and per-iteration rebuilding of
    v128 constants (two movz/movk pairs + slot stores + Q load every
    iteration). The bounded counter-caching lane above did not pay for it;
    what remains is a Q-register static cache entry for vector locals
    (v16-v31 are caller-saved and these functions are call-free) and/or
    loop-invariant constant hoisting — both new machinery in both backends,
    each its own future wave.
- GC native inline allocation in the JIT/AOT backends remains the largest
  open gap (gc ~104 ms vs Wasmtime ~28 ms): inline bump/free-list fast path
  with the collect-slow-path call as the safepoint, per ADR-0011's
  allocation-site stack-map obligation. Also its own wave.

Updated: 2026-08-22 (wave 2: GC field access through pointers + WASI RemoveTree fix)

## Wave 2 — field/layout resolution and a test-harness hang

- Lane `optimize/gc-field-access` from `1d8f188` (the wave-1 delivery head),
  accepted commits `5bf5574` (`perf(gc): resolve struct and array fields
  through pointers`) and `6d7eb49` (`fix(test): probe symlinks in the WASI
  suite's RemoveTree`), fast-forwarded into `optimize/runtime-wave`. Local,
  unpushed, delivery not requested.
- Mechanism: StructField copied the resolved TWasmGcField record per access
  and ArrayElement added a call layer plus a second copy; both re-resolved
  layout every time. The candidate returns a PWasmGcField into the layout
  table (StructFieldPtr) and folds null/kind/bounds/offset for scalar array
  paths (ResolveElement); ReadField/WriteField/ExtendSigned take the field
  by pointer.
- Serialized gc A/B under the perf gate (7 samples, BASE-CAND-CAND-BASE):
  116.743 → 104.604 ms forward and 104.531 vs 116.949 ms reverse (-10.5%
  both orders, disjoint spreads). Guards in two rotated passes: loop
  −1.0%/+0.1%, fib +0.5%/+1.2%, memory-load −2.2%/−4.0%,
  memory-store −7.1%/−3.1%, simd +5.5%/−1.6%, startup +9.9%/−3.2% — the
  simd/startup flips are short-process noise; no material regression.
- Correctness on the combined head (`f0407e1` release binary): all 44 unit
  suites pass; recursive corpus byte-identical in interpreter/JIT/AOT at
  pass=65851 fail=368 skip=904 staged=0 errors=0, compiled=8799; format,
  agents check, diff check, Markdown lint green.
- Harness defect found by the wave: Wasm.Wasi.Test's RemoveTree relied on
  faSymLink, which Darwin's FindFirst NEVER sets (it stats entries), so
  `escape -> /etc` was recursed and system files were being unlinked; an
  unlink there now wedges forever and hung any full-suite run that executed
  the WASI suite (reproduced twice). Fixed with fpReadLink; suite drops
  from hang to 2.7 s. Any environment where full suites stall in
  Wasm.Wasi.Test should check for this class first.

Updated: 2026-08-21 (gc allocation fast-path wave)

## GC allocation fast path

- Branch `optimize/runtime-wave` from exact
  `origin/main@659fd3711dd596176b7d86bdfc9d130e9b6e5015` (post-PR #10 tip).
  Accepted commit `22053d6` (`perf(gc): consolidate the allocation fast path`)
  on lane branch `optimize/gc-alloc-fastpath`, fast-forwarded into the
  delivery branch. Delivery not requested; both branches are local and
  unpushed.
- Target selection. The previous wave's residual list named GC allocation as
  the largest measured gap (~4.4x Wasmtime). Serialized baseline (release,
  bench.py best profile, 7 samples) at the exact starting commit: gc
  124.592 ms vs Wasmtime 28.282 ms (4.41x); guards loop 374.9, fib 33.0,
  memory 21.6, memory-load 43.0, memory-store 43.2, simd 9.4, startup
  2.93 ms.
- Profile-driven mechanism. A `sample(1)` profile of a 20M-iteration gc AOT
  run attributed ~270/741 samples to `TWasmGcHeap.AllocStruct` →
  `Allocate`: duplicate size-class classification (Allocate computed
  ClassOf/CellSize, then TakeCell recomputed them), layered helper calls,
  generic FillChar→memset zeroing of every cell, plus amortized
  Collect/Sweep; a further ~90 samples re-resolved type layouts through
  `TWasmGcTypes.Layout`/`IsDefined` on every AllocStruct/StructField.
- Accepted candidate (`22053d6`, Wasm.Runtime.Gc.pas only): TakeCell takes
  the already-derived class index and cell size; per-cell zeroing uses an
  inline u64 store loop up to 128 bytes (cells are 8-aligned, sizes are
  multiples of 8) and keeps the RTL fill for large objects;
  Allocate/ClassOf/TWasmGcTypes.Layout/IsDefined marked inline. No ABI,
  artifact-format, safepoint, trap, or allocation-trigger change: Allocate
  remains the only collection trigger and every byte of a cell is still
  zero before the header goes down.
- Serialized A/B under `/tmp/wasmlight-perf-gate.lock` (one warm-up
  discarded, 7 samples, BASE-CAND-CAND-BASE): gc wasmlight median
  127.498 → 118.107 ms forward and 117.819 vs 127.231 ms reverse (-7.4%
  both orders, spreads disjoint: base 125.7–128.9, cand 115.7–119.9).
  Guards forward then reverse: loop +2.68%/+0.40%, fib +1.27%/+0.17%,
  simd +2.16%/+0.61%, memory-load −8.69%/+1.51%, memory-store
  −10.74%/−3.70% — the forward memory deltas reversed sign and the wide
  short-process spreads straddle zero, so guards are flat within noise and
  the loop/fib/simd first-pass shifts were host-load drift, not code.
- Combined integration head equals the lane head byte-for-byte (same
  sha256 release binary), so the lane A/B is the combined measurement.
- Correctness on the combined head (macOS/aarch64): frozen install, format
  90/90, agents check, diff check, dev + release builds, Markdown lint, and
  all 44 unit suites pass. The recursive 288-script corpus at `de54fd27` is
  byte-identical across interpreter/JIT/AOT:
  pass=65851 fail=368 skip=904 staged=0 errors=0 (compiled=8799).
- Not yet done before any PR: the Linux/x86-64 leg (unit suites + corpus
  identity). The change touches no generated-code emitter and no artifact
  ABI, but prior runtime waves still proved x86-64 before delivery; CI on
  the PR would cover it.
- Rejected/not pursued this wave: caching resolved layout pointers per
  object header (changes the object model for ~12% of samples — deferred);
  native inline emission of struct.new/array.set in the JIT/AOT backends
  (the shape that closed the SIMD gap, but a full backend lane — the
  natural next wave if the remaining ~118 ms vs 28 ms gap must close).

Updated: 2026-08-21 (native v128 move/const emission, both backends)

## v128 helper-crossing elimination

- Branch `codex/optimize-profile-driven` from exact
  `origin/main@8a01d6ecec2f0569daefa61068f8bdb4078d44ac`. Accepted commits:
  `0ad4959` (`perf(jit): emit v128 moves and consts natively on arm64`) and
  `6a8c238` (`perf(jit): emit v128 moves and consts natively on x64`).
  Delivery not requested; the branch is local and unpushed.
- Profile-driven target selection. Serialized wasmbench baseline (release,
  7 samples) at the exact starting commit showed compiled-tier SIMD as the
  outlier (127 ns/op). A `sample(1)` profile of a 20M-iteration simd jit run
  attributed the samples to `InterpContextFor` (82), `_platform_memmove` +
  `FPC_MOVE` (~109), and generated-code helper regions. Mechanism: every
  `iroMoveVec` (v128 local.get/set/tee) and `iroV128Const` paid the full
  `JitVecDispatch` crossing — native call, activation lookup, ~200-arm case
  dispatch, 16-byte record copy — despite the arithmetic ops already being
  native. Vector-bearing loops execute ~10+ such crossings per iteration.
- Lane A (Arm64, `0ad4959`): `iroMoveVec` emits one Q-register LDR/STR pair;
  `iroV128Const` reads its bits from the aux block at compile time and bakes
  two movz/movk immediates into the destination slot pair. Everything else
  keeps the helper fallback; no new helpers, no ABI change, no scope-fence
  change. macOS/aarch64 serialized A/B (one warm-up discarded, 7 samples,
  BASE-CAND-CAND-BASE under `/tmp/wasmlight-perf-gate.lock`): simd jit
  126/126 -> 69/69 ms and simd aot 126/126 -> 69/69 ms (-45%); loop, fib,
  memory, numeric guards flat; startup inside noise.
- Lane B (x64, `6a8c238`): mirror shape — MOVDQU load/store pair for the
  move; two movabs/MOVQ halves joined by PUNPCKLQDQ for the const.
  x86-64 evidence from OrbStack `wasmx64` (virtualized amd64 over an Arm
  host — same-VM A/B evidence, not a native hardware claim): simd jit
  1432/1457 -> 455/469 ms (-68%) and simd aot 1117/1117 -> 342/342 ms
  (-69%); loop, fib, memory, numeric guards flat.
- Correctness: all 44 unit suites pass on macOS/aarch64 and Linux/x86-64
  (LWPT 0.6.0 explicit binary at `/tmp/lwpt-0.6.0.Uq7icT/lwpt-0.6.0-linux-x64/`,
  never the stale VM-PATH 0.4.0). The recursive 288-script corpus at
  `de54fd27` is byte-identical across interpreter/JIT/AOT before and after:
  pass=65851 fail=368 skip=904 staged=0 errors=0 (compiled=8799 aarch64,
  8800 x86-64). Frozen install, format, agents check, dev + release builds,
  and Markdown lint pass on the combined head.
- Operational notes for future waves: macOS has no `flock` — use the
  mkdir-based `/tmp/wasmlight-perf-gate.lock` directory lock; a stale plain
  file of that name existed on BOTH hosts (VM one dated Aug 15) and silently
  blocked acquisition until removed. macOS bsdtar archives sprout AppleDouble
  `._*` files when extracted by GNU tar — delete them before running
  `wasmspec` or every file double-counts as an error.
- Remaining profiled bottlenecks for a later wave: GC allocation (~4.4x
  Wasmtime on the bounded-live-set workload) and scalar memory load/store
  (~1.4x); the SIMD gap that motivated this wave closed to within roughly
  2.2x on the wasmbench shape (69 vs ~30 ns/op equivalent) with the residual
  being the remaining helper-dispatched vector forms (comparisons, shifts,
  min/max, narrowing) rather than moves or consts.

Updated: 2026-08-15 (post-v1 roadmap and 0.1.0 release)

## Durable roadmap and release decisions

- `ROADMAP-260815.md` is the source-verified comparison against Wasmtime,
  Wasmer, WasmEdge, WAMR, wazero, and wasm3 at recorded source heads. It
  classifies feature gaps and records the accepted post-v1 sequence.
- Release the completed pinned-Core-3 runtime as `0.1.0` before feature
  expansion. The user separately authorized publication through the official
  project-local `create-release` workflow on 2026-08-15.
- `0.2.0` completes and governs embedding: table/tag coverage, instance
  composition, resource policy, epoch configuration, and ordinary JIT policy.
- `0.3.0` wires `wasi-testsuite` and completes the 19 missing non-network WASI
  Preview 1 functions. Sockets remain a later, separately approved capability
  slice over pre-granted handles in `wasi_snapshot_preview1`.
- `0.4.0` adds operational observability. Async hosting is deferred to the
  Component Model re-entry so the runtime designs one suspension mechanism
  against the selected Component Model and WASI async ABI.
- After the re-entry gate is met, the Component Model and current WASI
  generation become the next strategic standards programme. Threads remain a
  separate demand-led programme because they reverse ADR-0008.
- Exact-main CI run 31899074165 passed all six configured targets. The four
  64-bit UNIX legs proved interpreter/JIT/AOT tally identity; the Windows legs
  proved the interpreter.
- The first-release publisher is unambiguous: no workflow owns a tag or GitHub
  release, so `create-release` owns one unprefixed `0.1.0` tag and one GitHub
  release from the committed changelog. There is no binary or registry publish.
- The local release gate passed on the prepared diff: frozen install, format,
  generated-agent check, all three builds, all 44 unit suites, all Markdown,
  and `git diff --check`.
- Milestone, issue, Component Model, threads, and socket implementation remain
  separately confirmation-gated. Live PR, CI, tag, and release state must be
  verified from GitHub rather than inferred from this handoff.

Updated: 2026-08-15 (x64 scalar-call specialization)

## x64 scalar leaf calls and self-recursion

- Fetched the remote default and created `codex/optimize-x64-jit` from exact
  `origin/main@ed8d5d693bad9356feb914576d0dfe3f98ecec10`, after PR #6 had
  landed the accepted Arm64 optimization waves. No rebase, force-push, remote
  push, or PR creation was performed.
- The two accepted commits are `cd21c4d` (`perf(jit): specialize x64 scalar
  leaf calls`) and `9e68bb4` (`perf(jit): specialize x64 scalar self calls`).
  The final source tree is `69aeb6eee23f7d10d69b8602d4e0f180845ecd27`.
- The leaf wave adds a proof-gated x64 native scalar entry/core ABI. Eligible
  one- or two-argument numeric leaves receive arguments in r8/r9 and return in
  r8 through an aligned native-stack register file. The caller resolves the
  live function/native entry, checks the exact shared depth and value limits,
  and retains the generic compiled/interpreted/host fallback. The proof filter
  prevents ineligible targets from paying the native-entry probe.
- The self-recursion wave gives eligible one-argument numeric recursion a
  local-core path. It computes the exact additional-frame budget as the
  minimum of remaining depth and remaining value slots divided by the
  function register count. Ordinary calls do not invent an epoch safepoint;
  real IR backedges retain their existing checks. AOT ABI revision 14 rejects
  artifacts produced for older x64 entry layouts.
- Review initially found and prevented two leaf correctness defects: a mixed
  scalar-call/tail-call function restored the wrong frame shape, and
  select/rotate fallback emission could read unmaterialized parameter slots.
  The final implementation threads the retained-frame shape through every
  tail exit, materializes/coheres native parameters, and covers select and
  both rotate widths in the x64 cache. Differential tests cover those paths,
  local.set coherence, exact depth/value exhaustion and cleanup, sequential
  self-calls, store reuse, JIT, and AOT. Final focused reviews found no
  remaining ABI, PIC, cache-liveness, epoch, trap, or AOT issue.
- Exact-main release baseline and evidence remain inside OrbStack `wasmx64`
  at `/tmp/wasmlight-x64-ed8d5d6-baseline.Igxi43`. The VM-local baseline
  binary hash is `3b816d...eea3`. All measurements used the explicit,
  checksum-verified LWPT 0.6.0 binary under `/tmp/lwpt-0.6.0.Uq7icT/`, never
  the stale LWPT 0.4.0 found on the VM PATH.
- Serialized AOT command-level A/B used self-checking fresh processes,
  compilation outside timing, one warm-up plus seven samples per binary and
  order, and `/tmp/wasmlight-perf-gate.lock`. The accepted leaf path reduced
  the 50-million-call workload from 7146.799 to 1905.832 ms forward and from
  5540.303 to 1487.807 ms in reverse: 73.33% and 73.15% faster. A deliberately
  ineligible scalar target was flat at +0.03% in its stable reversed schedule.
- Against that accepted leaf baseline, native self-recursion reduced fib from
  2984.799 to 533.784 ms forward and from 2982.862 to 534.782 ms in reverse:
  82.12% and 82.07% faster. Its guard deltas were call -0.17%/+0.25%,
  ineligible fallback -0.51%/+0.20%, loop -0.04%/-0.12%, memory
  -0.13%/+0.04%, and startup order-flipped inside 10-24% short-process noise.
  Raw accepted evidence is under `/tmp/wasmlight-x64-leaf-proof/measurement/`
  and `/tmp/wasmlight-x64-self/measurement/` inside `wasmx64`.
- One reviewed intermediate leaf candidate was rejected because every
  syntactically qualifying call probed a nil native entry, producing a stable
  2.25% regression across 50 million ineligible calls. The target-proof
  filter removed that tax before acceptance. An earlier non-compact leaf
  frame was also rejected after a repeatable roughly 1% memory regression.
  Neither rejected form remains in the tree.
- Final native macOS gates on exact head: frozen install, format, generated
  agent reference, whitespace, Markdown lint, clean release/development
  builds, and all 44 suites pass. The pinned 257-script core corpus at
  `de54fd27` is byte-identical in interpreter/JIT/AOT at 65,188 pass and zero
  fail/skip/staged/errors; JIT/AOT each compile 8,703 functions.
- Final Linux/x86-64 proof used a fresh exact archive in OrbStack at
  `/tmp/wasmlight-x64-final-9e68bb4.ujf8iw` (archive SHA-256
  `cf431e7bfbf7223e5a7162917a0c67a99c2407a8f66f766c836c9be7cfc22961`).
  FPC 3.2.2, frozen install, format, agents, clean release/development builds,
  and all 44 suites pass. The same pinned core corpus is byte-identical at
  65,188/0/0/0 in interpreter/JIT/AOT; x64 JIT/AOT each compile 8,704
  functions. Timings are valid same-VM A/B evidence on virtualized amd64 over
  an Arm host, not a native x64 hardware claim.

Updated: 2026-08-15 (generic scalar direct-call specialization)

## Two-argument cross-function call path

- Started `codex/optimize-generic-direct-calls` from exact delivery head
  `cda57e8a762cffebf91f5482988d88e128cbae33`. The untouched release baseline
  and its AOT artifact remain under `/tmp/wasmlight-call-generic-base.ThFhCN`.
- The accepted Arm64 specialization covers direct calls to proof-gated numeric
  leaves with one or two parameters and one result. Eligible callees contain
  no calls, memory operations, references, allocation/GC, handlers,
  safepoints, or trapping operations. All other targets retain the existing
  direct-frame or generic/interpreted/host path.
- A lightweight caller checks the exact shared depth and value-slot limits
  before native-stack mutation, transfers scalar arguments in x12/x13, and
  receives the result in x12. The leaf uses a bounded numeric-only native
  register file and a wider x12-x17 write-back cache. Canonical external entry,
  live Store.Funcs indirection, AOT PIC, trampoline unwinding, and tier fallback
  remain intact. AOT ABI revision 12 rejects older incompatible artifacts.
- Serialized command-level A/B for 50 million checked two-argument calls,
  compilation excluded, one warm-up and seven paired samples under
  `/tmp/wasmlight-perf-gate.lock`: forward baseline/candidate medians
  722.307/143.581 ms; reverse candidate/baseline 145.594/728.319 ms. This is
  about 80% faster (roughly 5x). Same-schedule Wasmtime 47.0.3 was 63.861 ms,
  leaving Wasmlight at about 2.25x on this deliberately call-dominated test.
- Final seven-sample both-order guard medians (baseline/candidate forward,
  candidate/baseline reverse) were: scalar loop 390.123/390.195 and
  390.891/390.848 ms; varying memory 26.398/24.239 and 19.204/22.298; loads
  48.602/47.657 and 47.244/42.051; stores 42.620/38.538 and 38.862/42.209;
  memory growth 13.926/14.066 and 13.887/13.861; GC allocation
  131.028/130.549 and 131.248/131.043; SIMD 24.304/24.324 and
  24.301/24.153; host calls 35.626/35.525 and 35.852/35.398; startup
  2.710/2.641 and 2.466/2.592 ms. Short memory/startup rows show reversing
  process noise, not an order-independent regression.
- The first pinned-core run exposed three `local.set` divergences: redefining a
  native leaf parameter could create a dynamic duplicate of its seeded cache
  entry and later read the stale input. Marking x12/x13 as fixed cache entries
  corrected it; a focused compiled-to-compiled local.set regression now pins
  the failure, along with explicit leaf proof rejection and exact depth/value
  exhaustion cleanup tests.
- Final macOS/aarch64 gates: frozen install, format, agents, diff check, clean
  release and development builds, and all 44 suites pass. The pinned 257-file
  core corpus is exactly 65,188 pass and zero fail/skip/staged/errors in
  interpreter/JIT/AOT; JIT and AOT compile 8,703 functions. Linux/x86-64 in
  OrbStack (`wasmx64`, FPC 3.2.2, LWPT 0.6.0) also passes clean release/dev
  builds, all 44 suites, and the same corpus identity with 8,704 compiled
  functions in JIT/AOT. The x64 native backend remains on its generic path.
- Rejected and reverted: a per-instance native call table was slower and added
  mutable metadata; pinning the caller's FuncAddrs map removed eleven lookup
  instructions but regressed final medians to 149-163 ms. Neither experiment
  remains in the tree. Delivery is tracked by PR #6
  (`https://github.com/frostney/wasmlight/pull/6`); no rebase or force operation
  was performed.

Updated: 2026-08-15 (runtime comparison expanded)

## Diagnostic runtime workloads

- The default runtime-comparison suite now has eleven self-checking workloads.
  Seven new fixtures separate cache-resident linear-memory loads, stores,
  generic two-parameter cross-function calls, 4,096 one-page `memory.grow`
  operations, bounded-live-set GC allocation, dependent i32x4 SIMD, and one
  million WASI monotonic-clock host calls.
- `bench.py` owns a workload registry with descriptions, assembler selection,
  and verified runtime support. Capability-heavy workloads are not weakened to
  fit old peers: GC runs on wasmlight and Wasmtime, SIMD on wasmlight,
  Wasmtime, Wasmer, WasmEdge, and wazero, and host-call everywhere except
  wasm3. Missing cells render as unavailable in Markdown and the existing PR
  comment renderer. GC uses `wasm-tools parse` because WABT 1.0.41 does not
  accept the current Core 3.0 GC text forms.
- A seven-sample rotated best-profile run passed for all new applicable
  configurations. Apple M5 Max wasmlight/Wasmtime medians in ms were:
  load 46.702/33.111, store 39.013/28.915, generic call 725.350/64.599,
  memory-grow 14.584/16.173, GC 131.539/29.696, SIMD 24.063/5.959, and host
  call 36.040/39.732. These are diagnostic observations, not CI thresholds.
- A separate interpreter smoke run passed every applicable runtime/workload
  combination. All eleven modules also prepared and validated together from
  the final release build. Generated modules, artifacts, and reports remain
  under ignored `build/runtime-comparison/`.
- Added four Python harness tests covering registry/source completeness, GC
  parser and capability scope, unsupported-config omission, and unavailable
  table cells; the four existing PR-comment tests remain green.
- Gates: frozen install, clean dev and release builds (3/3 each), full unit
  suite 44/44, Python tests 8/8, format 90/90, generated-agent check,
  Markdown lint 42 files, Python byte-compilation, and diff whitespace all
  pass. No runtime implementation or conformance behavior changed, so the
  pinned external corpus was not rerun for this benchmark-only patch.

Updated: 2026-08-15 (runtime optimization goal reached)

## Within 1.5x of Wasmtime

- Fetched the remote default and started the clean
  `codex/optimize-within-1-5x-wasmtime` branch from exact
  `origin/main@c20a7d1c6c8312996b8c8d910b577fd1215f46e9`. No rebase,
  force-push, PR, or remote push was used.
- Retained exact-main release binaries under
  `/tmp/wasmlight-c20a7d1-baseline.ZSMAeO/`. The initial Apple M5 Max
  best-profile medians were startup 2.859 ms (0.63x Wasmtime), loop
  538.488 ms (1.54x), fib(35) 369.757 ms (10.45x), and varying-address
  memory 87.262 ms (4.50x).
- The final measured runtime source head is
  `68bc95303ee5617028233cfc0cd5747af6c1a7e3`. The full command-level
  `best` profile used precompiled artifacts, compilation outside the timer,
  self-checking modules, one warm-up, seven samples, rotated runtime order,
  and `/tmp/wasmlight-perf-gate.lock`. Final medians versus same-schedule
  Wasmtime 47.0.3 were:
  - startup: 2.147 vs 3.480 ms = 0.617x;
  - loop: 364.166 vs 333.697 ms = 1.091x;
  - fib: 31.522 vs 32.001 ms = 0.985x;
  - memory: 21.625 vs 16.891 ms = 1.280x.
  Every workload is below the agreed 1.5x ceiling. Raw samples and metadata
  are retained at `/tmp/wasmlight-final-68bc953/results.json`.
- The accepted aarch64 memory waves defer loop write-back, fold bounded
  immediate/local/memory operands, combine low-mask shifts with `UBFIZ`, use
  cached sources and destinations, forward exact store-load pairs, and
  propagate bounded local aliases. Every optimization is restricted to the
  existing helper-free, zero-offset, i32 guard-page/static-cache proof shape;
  stores and first OOB traps remain observable, CFG joins/backedges reconcile
  live state, and x64 analysis remains unchanged. The final memory workload is
  1.28x Wasmtime, down from 4.50x.
- The accepted call waves progressively specialized scalar compiled frames,
  emitted proof-gated native self-recursion, factored one external AAPCS
  wrapper from a PIC local core, pinned an exact depth/value-frame budget in
  x26, and use x12 as a one-slot local-core parameter/result ABI with bounded
  lexical write-back. The native subset excludes references, helpers, memory,
  handlers, host/interpreted/cross-function/indirect/tail escape, and retains
  generic fallback for every other call. Cap checks precede mutation; longjmp
  owns abnormal cleanup; actual IR backedge epoch polls remain unchanged.
- Independent review caught two tier-identity defects before closure. Commit
  `8f6849724f1c641cb5e5b94838b7375b94a0670c` removed an invented epoch poll
  from ordinary native self-calls and added host-epoch-bump JIT/AOT
  regressions. Commit `28eb4d5c1cfd17ba696dfcfa5b60eeab3ab3aa54`
  completed lexical and loop-carried liveness accounting for rotate, select,
  and call operands/results; its two-self-call select fixture fails without
  the correction. A final independent re-review found no remaining concrete
  cache, budget, AAPCS/PIC/AOT, epoch, longjmp, GC, or tier-divergence issue.
  AOT ABI revision 11 rejects artifacts generated by the superseded layouts
  and faulty liveness analysis.
- Rejected and reverted candidates include direct cached memory operands
  before deferred write-back (0.4%), several local-slot/cache/immediate loop
  experiments that regressed or overlapped noise, a bounded MADD fusion
  (0.77-1.53%, below the materiality gate), and broad call-bearing static
  caching (fib regressed from about 63 to 71 ms). A narrow write-back prototype
  missing a return flush produced a wrong AOT result and was fixed before any
  acceptance measurement.
- Final macOS/aarch64 gates on the exact final runtime tree: frozen install,
  clean release and development builds, format, generated-agent reference,
  diff check, Markdown lint, and all 44 suites pass. The pinned 257-script core
  corpus is byte-identical across interpreter/JIT/AOT at 65,188 pass and zero
  fail/skip/staged/errors; JIT/AOT compile 8,703 functions.
- Final Linux/x86-64 proof used OrbStack's native amd64 VM, FPC 3.2.2, the
  checksum-verified LWPT 0.6.0 release, and an exact `git archive` of
  `68bc953`. Clean release and development builds plus all 44 suites pass. The
  same pinned core corpus is byte-identical at 65,188/0/0/0 in all tiers;
  x64 JIT/AOT compile 8,704 functions. VM evidence remains under
  `/tmp/wasmlight-x64-final.XCWobI/` inside `wasmx64`.
- The delivery branch is intentionally local and unpushed. The measured source
  head is followed only by this handoff update; no runtime code or generated
  artifact changes after `68bc953`.

Updated: 2026-08-15 (PR runtime-comparison gate and sticky report)

## PR runtime-comparison gate

- Extended `.github/workflows/pr.yml` with a Linux x86-64
  `runtime-comparison` job and an always-running
  `runtime-comparison-comment` reporter, following GocciaScript's same-runner
  base-vs-PR artifact/comment shape.
- The gate builds release binaries for the PR base and head, runs the four
  self-checking workloads against both on the same runner, uploads raw JSON,
  and upserts one comment identified by
  `<!-- wasmlight-runtime-comparison -->`. A stale-run guard refuses to let an
  older workflow overwrite a newer head's comment.
- This is deliberately an executable gate, not a numeric threshold: build,
  fixture validation, precompilation, result verification, or runtime-command
  failure makes the job red. Timing deltas and range-overlap classifications
  are informational and cannot fail a PR, preserving the project's honest
  measurement rule.
- Added `tools/runtime-comparison/install-ci-tools.sh`: Wasmtime 47.0.3,
  Wasmer 7.2.1, WasmEdge 0.17.1, WAMR/wamrc 2.4.5, wazero 1.12.0, wasm3 0.5.0,
  wasm-tools 1.256.0, and WABT 1.0.41 are pinned to exact release assets and
  SHA-256 digests. The extracted executable tree is cached with a key derived
  from the installer, so any version/digest edit invalidates it.
- The Linux best-profile WAMR row now uses precompiled AOT. The harness passes
  an explicit `--target=x86_64`/`aarch64` to `wamrc`; this was required after a
  clean Ubuntu x86-64-emulation smoke exposed host-target misdetection. Hosts
  without a runnable `wamrc` still fall back to a clearly labelled interpreter.
- Added and unit-tested `render_comment.py`: the comment shows main vs PR,
  overlap-aware deltas, every peer, the peer ratio, method, non-gating policy,
  workflow link, and raw-artifact pointer. Missing candidate output renders a
  failure comment rather than throwing away the reporting path.
- Local verification: frozen install, formatting, generated-agent validation,
  release build, and all 44 unit suites pass. Actionlint passes for the new
  workflow (the existing SC2005 at pr.yml:91 is ignored), shellcheck passes,
  renderer 4/4 tests pass, Python byte-compilation passes, Markdown lint passes,
  YAML parsing and diff whitespace pass, and a clean Ubuntu container verified
  every cached executable plus WAMR AOT compile and execution.
- PR #5's first runtime-comparison run exposed the published wasm3 0.5.0
  x86-64 ELF exiting on GitHub's runner with SIGILL before measurement. The
  installer now builds wasm3 once from the checksum-verified archive for pinned
  commit `6b8bcb1e07bf26ebef09a7211b0a37a446eafd52`; the installer-derived cache
  retains that executable for later runs. The source-root lookup is constrained
  to the archive's top-level directory: an unconstrained `find CMakeLists.txt`
  selected wasm3's Android JNI subproject on one hosted filesystem traversal.
- Live forge check found no branch protection or repository ruleset. The new
  job makes the PR workflow red on failure, but it cannot become a mechanically
  required merge check until a ruleset is added after the workflow exists on
  the default branch.

Updated: 2026-08-14 (reproducible seven-runtime comparison delivered)

## Runtime comparison and performance scorecard

- Fetched `origin/main@a7d9565304ee1138b4e76763810559e7ba1112d1` and created
  `codex/compare-runtimes` without a rebase, force-push, or upstream tracking
  branch. The prior handoff-only change was retained in commit `3e25018`.
- Added the reusable comparison harness and four self-checking WASI workloads
  under `tools/runtime-comparison/`. Commit `83c132b9d52a` is the exact clean
  measured head. Compilation happens outside the timer; the run uses one
  warm-up, seven measured samples, a rotated round-robin schedule, and the
  shared `/tmp/wasmlight-perf-gate.lock`. Raw samples are generated under
  `build/runtime-comparison/` and are not committed.
- Added `docs/runtime-comparison.md` with a current product-shape comparison of
  Wasmtime 47.0.3, Wasmer 7.2.1, WasmEdge 0.17.1, WAMR 2.4.5, wazero 1.12.0,
  and wasm3 0.5.0, plus the full performance snapshot and limitations.
- Wasmlight's defensible position is a native Object Pascal runtime with an
  unusually complete pinned core-3.0 implementation, strict phase/error
  boundaries, deny-by-default capabilities, and observational identity across
  selected execution modes. Do not position it as a general Wasmtime
  replacement: Component Model/WASI p2, threads/shared memory, host-surface
  breadth, mature bindings/tooling, external security assurance, and peak
  native performance are material gaps.
- "Complete in every tier" is an observable-behaviour claim. The JIT and AOT
  share native backends and conservatively fall back per function when
  `JitCanCompile` declines a shape (including handler-table cases); it is not a
  claim that every core-3.0 operation is natively lowered.
- Clean-head Apple M5 Max medians: wasmlight AOT startup 2.191 ms (fastest);
  nonlinear 300M loop 503.042 ms (Wasmtime/Wasmer/WasmEdge/wazero compiled
  configurations are 1.48-1.51x faster); fib(35) 353.371 ms (compiled peers
  7.96-15.64x faster); varying-address 50M memory 82.054 ms (compiled peers
  2.66-4.66x faster). WAMR and wasm3 were interpreter-only in the installed
  best-profile configurations.
- Wasmlight's interpreter starts fastest and beats the explicit WasmEdge and
  wazero interpreters on all three heavy workloads, but WAMR and wasm3 are
  4.62-9.32x faster. The strongest optimization targets are recursive
  call/return first, then the memory chokepoint; preserve startup and artifact
  size while changing either.
- WAMR AOT/JIT remains unmeasured: WAMR supports both, but its official 2.4.5
  macOS `wamrc` asset is x86-64-only and this arm64 host has no Rosetta. Build a
  native arm64 compiler before claiming WAMR's performance ceiling.
- Next scorecard extensions are host-call and repeated-instantiation throughput,
  peak RSS/multi-instance density, then one real toolchain-compiled WASI app.
  Keep Component Model and threads as explicit product-direction decisions,
  not assumed roadmap additions.

Updated: 2026-08-14 (optimization skill PR refreshed on current main)

## Runtime optimization skill

- Added the repository-authored `optimize-runtime` skill under
  `.agents/skills/optimize-runtime/`. It turns the workflow used for PR #1
  into a repeatable protocol: exact release baseline, profiling, bounded
  isolated candidate lanes, serialized same-load A/B measurement, guard
  workloads, combined-state re-measurement, and cross-tier/platform gates.
- Candidate changes remain rejected unless their improvement is repeatable and
  larger than observed noise. Each accepted lane is re-measured after
  integration against the immediately previous accepted head; isolated wins
  are not assumed to compose.
- The workflow preserves shared validation, memory chokepoints, epoch/stack-map
  safepoints, invocation-trampoline unwinding, and interpreter/JIT/AOT identity.
  Generated-code changes require the full pinned corpus on macOS/aarch64 and
  Linux/x86-64 before delivery.
- The skill is intentionally repository-authored and therefore absent from
  `skills-lock.json`. Imported skills remain lock-managed; `docs/tooling.md`
  now records the distinction.
- PR #3, `feat: add benchmark-gated optimization skill`, is open from
  `codex/add-optimization-skill`. The branch merged current
  `origin/main@fad3c41` after PR #4 landed; no rebase or force-push was used.
  No runtime code or benchmark result changed in this workflow-only PR.
- The merged-state LWPT 0.6.0 gate is green: frozen install, formatting,
  generated-agent validation, development and release builds, all 44 unit
  suites, skill validation/discovery, CLI smoke checks, and Markdown lint.

Updated: 2026-08-14 (README status refreshed; LWPT 0.6.0 migration verified)

## 2026-08-14 README and suite-status audit

- Fetched the remote default and created
  `codex/update-readme-suite-status` directly at
  `origin/main@f3e9da573d796201ad64b60f27035dd253378f89`. The starting
  detached worktree was clean; no user changes were stashed or discarded.
- Draft PR #4, `chore: upgrade LWPT and clarify conformance status`, is open
  against the remote default. The create-PR workflow owns the transition to
  ready after the final exact-head PR and docs checks reach green.
- Updated `README.md` to lead with the reproducible 257-script pinned-core
  command and its clean result, distinguish it from the recursive mirror,
  explain every remaining recursive failure/skip class, and replace the stale
  cross-platform caveat with the exact-head six-lane CI result.
- Local pinned-core verification is byte-identical in all tiers:
  `pass=65188 fail=0 skip=0 staged=0`, with JIT/AOT `compiled=8703`.
  The recursive interpreter run is
  `pass=65851 fail=368 skip=904 staged=0 errors=0`: failures are 354 proposal
  cases (219 custom descriptors, 78 threads, 47 custom page sizes, 10 wide
  arithmetic) plus 14 legacy-EH cases; skips are 814 proposal actions and 70
  legacy actions downstream of an uninstantiated module, plus 20 custom
  directives outside the reference grammar.
- Exact-head main CI run 31798063780 is green on all six jobs: aarch64/x86-64
  macOS, aarch64/x86-64 Linux, and x86-64/i386 Windows. The four 64-bit UNIX
  jobs run interpreter/JIT/AOT; Windows runs the tier-of-record interpreter.
- The user expanded PR #4 to upgrade the project to LWPT 0.6.0. The manifest
  now selects `instantfpc` explicitly through `command` + `args`, both filtered
  dependencies resolve at 0.6.0, `lwpt install` owns the regenerated lock,
  archives, and module snapshots, and both workflows download the
  checksum-verified 0.6.0 release. The obsolete tracked 0.4.0 archives were
  removed; they remain recoverable from Git history.
- LWPT 0.6.0's generated AGENTS command block is present and enforced by
  `lwpt agents --check` on the single format lane in PR and post-merge CI;
  Lefthook refreshes it locally alongside formatting.
- The full local 0.6.0 gate is green: frozen install, formatting, generated
  agent reference, all three builds, 44/44 unit suites, Markdown lint, and the
  pinned core in interpreter/JIT/AOT at `pass=65188 fail=0 skip=0 staged=0`.
  The recursive diagnostic remains `pass=65851 fail=368 skip=904 staged=0`
  with the same outside-target breakdown recorded above.

## Pinned core conformance residue eliminated

- Continued `codex/fix-ci-skips` from fetched `origin/main@12c1a4c`; no merge
  was needed because that remote head is already an ancestor. Toolchain is FPC
  3.2.2 through lwpt 0.5.1 only.
- The runner now provides the pinned standard `spectest` module: all seven
  print functions, immutable numeric globals, i32/i64 tables, and memory. Its
  store objects are allocated once per script and shared across modules. A
  later script `(register "spectest" ...)` replaces the built-in as one whole
  module; imports never splice exports from both.
- `assert_unlinkable` now resolves and instantiates through the shipped path and
  passes only on a prefix-matching `EWasmLinkError`. Named module definitions
  retain validated model/IR/bytes; module instances are fresh and generative.
  The corpus's elided-wrapper inline module body is assembled as one module.
- The final 10 binary diagnostic mismatches are fixed at the grammar boundary:
  signed s7 composite discriminators, physical LEB width checks across declared
  body spans, missing-END versus code-section size classification, and the
  confirmed export-name list overrun. Valid function bodies retain the single
  fused validation walk; malformed-only probing is gated.
- Spec evidence was checked at `spec/main@d7b37e4170d8315f2f1283aed4e8076591a9a333`
  (`binary-int`, `binary-code`, `binary-section`, `binary-comptype`,
  `binary-name`, `binary-list`, `exec-module`, `exec-instantiation`) and the
  standard host against the pinned reference `spectest.ml`.

## Final local evidence

- `git diff --check`, `lwpt format --check`, `lwpt install --frozen`, and
  `lwpt build`: green.
- `lwpt test`: 44/44 suites, 1,224 tests, no compile/test failures.
- Markdown lint: 41 files, 0 issues.
- Pinned core, 257 scripts, identical in every tier:
  `pass=65188 fail=0 skip=0 staged=0`; JIT/AOT `compiled=8703`.
- Recursive 288-script mirror, identical in every tier:
  `pass=65851 fail=368 skip=904 staged=0`; JIT/AOT `compiled=8799`.
  The residue is explicitly outside core 3.0: 14 legacy EH failures; 354
  post-3.0 proposal failures; 20 testsuite-local custom skips; and 884
  downstream `no instantiated module` skips in legacy/proposals. There are
  zero unresolved-import or `assert_unlinkable` skips.
- Independent integration reviews found two edge risks (registered `spectest`
  precedence and an over-broad export-boundary diagnostic); both were fixed
  with counter-tests before the final gate.

## Delivery

- Draft PR [#2](https://github.com/frostney/wasmlight/pull/2),
  `fix: restore tier CI and fully judge pinned core`, is open against `main`.
  Keep it draft until the PR-triggered checks pass on the exact final head, then
  mark it ready for review.
- Implementation commit: `8dba9c1` (`fix: fully judge the pinned core corpus`).
- Current-truth documentation commit: `e2bea80`
  (`docs: record complete core conformance`).
- Full six-platform CI run `31754666992` passed at exact source/docs head
  `e2bea80`: aarch64/x86-64 macOS, aarch64/x86-64 Linux, and i386/x86-64
  Windows. The branch is pushed as `origin/codex/fix-ci-skips`.
- This handoff-only closure commit follows that tested source/docs head; no
  implementation or generated state changed after the exact-head run.

Updated: 2026-08-13 (main CI repair and corpus-residue audit)

## Main CI repair

- Synced from fetched `origin/main` at `12c1a4c` and created
  `codex/fix-ci-skips`.
- Main run `31645850311` failed only on native x86_64-darwin: the interpreter
  passed `call.wast:337`, while JIT/AOT surfaced FPC `EStackOverflow` during
  deep direct compiled recursion instead of trapping `call stack exhausted`.
- The direct-call fast path consumes native stack per non-tail call. The shared
  logical cap of 8192 frames was too generous for the Intel macOS process
  stack. A 1024-frame cap still overflowed on the heavier indirect-call path,
  so all tiers now share a conservative 256-frame cap. This is an
  implementation resource limit allowed by pinned-spec anchor `impl-exec` and
  keeps tier exhaustion identical rather than adding a Darwin-only carve-out.
- CI now retains each tier's `--failures-only` output and prints a focused diff
  on tally divergence. Diagnostic run `31673377733` proved the exact failing
  assertion; the other five platform legs were green.
- Local gates after the cap change: frozen install, format check, all three
  builds, 44/44 unit suites, and full interpreter/JIT/AOT corpus identity at
  `65204 pass / 389 fail / 1532 skip / 0 errors` (compiled=8588).

## Remaining corpus residue audit

- Root suite: 33 fail / 610 skip. Proposals: 356 fail / 922 skip.
- Root failures are 10 decode-message/framing mismatches, 5 module-definition /
  instance commands, 14 legacy EH assertions (explicitly out of the 3.0
  target), and 4 other module-definition uses in memory/table coverage.
- Root skips are 96 missing `spectest` imports, 291 cascaded commands after
  those modules do not instantiate, 200 `assert_unlinkable` commands the
  harness still does not judge, and 23 non-reference custom directives.
- The actionable next conformance wave is harness plumbing, not runtime opcode
  work: provide the standard `spectest` funcs/globals/table/table64/memory,
  then judge `assert_unlinkable` through the existing instantiator/link errors.
  That can retire most root skips. Keep proposal residue and legacy EH outside
  the pinned core-3.0 claim.

Updated: 2026-08-12 (fifth measured optimization wave integrated and
cross-architecture/cross-tier validated; PR #1 open)

## 2026-08-12 pull request delivery

- Draft PR #1, `perf: accelerate compiled execution and restore tier CI`, is
  open against `main` from `codex/fix-tests-tier-performance`.
- The exact pre-PR gate passed on macOS: frozen install, formatting, all three
  dev build entries, and 44/44 unit suites. The preceding optimization gate
  also covered release builds and the full three-tier corpus on macOS/aarch64
  and Linux/x86-64.
- The first PR docs job exposed pre-existing markdownlint failures throughout
  `.agent/design`. The blocking rule was kept intact; the internal design notes
  were mechanically repaired with fence-language tags, real appendix headings,
  spacing fixes, and no technical content changes. Repository-wide Markdown
  lint now passes all 41 files.
- Exact-head CI then exposed two checked-build portability defects. The macOS
  corpus compiled a legal `memory64` offset above `High(Int64)` through a
  checked numeric conversion, and the Windows AOT test referenced the
  executable-memory capability probe without directly importing its unit.
  The native emitters and interpreter now reinterpret the IR immediate's raw
  bits, the fold comparison is explicitly unsigned on both backends, and the
  AOT suite imports `Wasm.Jit.CodeBuffer` directly. A new differential invokes
  the maximum u64 offset and requires the same out-of-bounds trap in interpreter
  and compiled execution.
- The post-fix macOS gate is green: frozen install, format, dev and release
  builds, 44/44 unit suites, repository-wide Markdown lint, and full corpus
  tier identity at pass=65204, fail=389, skip=1532, staged=0, errors=0, with
  8588 compiled JIT/AOT functions. Push this exact head and keep the PR draft
  until its replacement CI run is green, then mark it ready for review.

## 2026-08-12 fifth measured optimization wave complete

- **Two measured commits are integrated on
  `codex/fix-tests-tier-performance`:** `e0bbd66` lets FPC inline the GC frame
  chain's leaf push/pop operations; `02f2f7f` optionally retains a third hot
  loop value in callee-saved `x26` on aarch64. Only functions whose third slot
  scores at least three uses take the extended frame and its save/restore;
  every other function retains the established 64-byte frame.
- **Serialized Apple Silicon A/B, seven release samples in both orders:** the
  300M varying-address scalar-memory loop moved from JIT/AOT 606/602ms to
  560/561ms, and reverse-order confirmation moved from 595/593ms to 558/557ms
  (about 6-8% faster). Recursive fib(35) JIT moved from 385ms to 373ms in the
  forward run and 376ms to 368ms in reverse; AOT overlapped noise at
  369-374ms versus 370-371ms. The material acceptance target is the memory
  loop. Guards were flat: the 300M integer loop 327/326ms to 325/325ms,
  constant-address memory 47/47ms, numeric 44-45ms, SIMD 136-137ms, and
  startup 7/9ms.
- **Rejected experiments were fully reverted:** four static long-lived slots
  displaced the expression cache and nearly doubled loop time; direct
  destination emission lost most of the smaller four-temporary gain; an
  unconditional `x26` save/restore regressed fib by about 5%; fused epoch
  branching and a third x86-64 static register were throughput-neutral; a
  scalar direct-call specialization regressed fib by 2-3%.
- **Safety boundaries:** `x26` is saved only by generated functions that use
  it and restored on their normal return; existing epoch/trap unwind remains
  non-returning. Static-cache eligibility is still the helper/call/reference/
  allocation-free allowlist, and exits still flush the canonical logical
  frame. The external generated-code ABI and artifact format are unchanged;
  old `.waot` code never uses `x26` and remains valid. Tests pin the third-slot
  mapping and exact extended prologue/epilogue words.
- **Correctness is exact on both architectures:** frozen install, formatting,
  release build, and all 44 unit suites pass. The complete interpreter/JIT/AOT
  corpus is tier-identical on macOS and Linux: pass=65204, fail=389,
  skip=1532, staged=0, errors=0; JIT/AOT compiled=8588 on aarch64 and 8589 on
  x86-64. The shared GC-inline change is neutral within noise on the Rosetta
  x86-64 host; the register change is aarch64-only.
- **Refreshed Wasmtime 47.0.3 comparison:** both runtimes execute identical
  precompiled command modules, one warmup discarded, seven samples. A fixture
  that exported only `run` was rejected because invoking it as a command could
  measure a no-op; the replacement exports memory and `_start`. On macOS, the
  300M varying-address loop is Wasmlight AOT 564.054ms versus Wasmtime
  94.163ms (5.99x), and fib(40) is 4.125s versus 348.578ms (11.83x). In the
  Rosetta Linux VM, 50M varying accesses are 810ms versus 224ms (3.62x), and
  fib(40) is 36.033s versus 3.699s (9.74x); Linux absolute timings describe
  the VM, not native x86-64 hardware.

## 2026-08-12 fourth measured optimization wave complete

- **Three measured commits are integrated on
  `codex/fix-tests-tier-performance`:** `e14d067` adds a permanent,
  tier-verified `memory-varying` workload; `a119423` retains shifted address
  expressions in the aarch64 cache and folds their one-use result moves;
  `e02a9c2` resolves an x86-64 function's single memory once at entry and
  retains native shift results in its register cache.
- **Apple Silicon serialized A/B, seven release samples:** for 300M iterations
  of the new varying-address store/load loop, JIT moved from 1,384ms to 594ms
  (57.1% faster) and AOT from 1,372ms to 594ms (56.7% faster). The first
  shift-cache step measured about 640ms; adjacent move folding lowered it to
  about 593ms, so both retained steps independently cleared the gate.
  Constant-address memory, the numeric loop, fib(35), numeric, SIMD, and
  startup remained in their prior bands.
- **Linux/x86-64 serialized A/B in the Rosetta OrbStack VM:** for 10M
  iterations of the same workload, JIT moved from 963ms to 147ms (84.7%
  faster) and AOT from 946ms to 148ms (84.4% faster). Resolving the memory once
  first measured 169-170ms; native cached shifts then measured 142-148ms, so
  both steps were positive. Final guards versus the exact baseline are flat:
  30M loop 208/205ms, fib(35) 3,655/3,651ms, numeric 37/37ms, SIMD 123/121ms,
  and startup 30/30ms; constant-address memory also improved 900ms to 113ms.
- **Safety boundaries:** aarch64 broadens only the existing helper-free,
  single-memory static-cache shape. x86-64 stores the stable memory-instance
  pointer in the prologue's otherwise-unused aligned stack slot, but reloads
  live `Base` and `ByteSize` at every access; multi-memory functions retain the
  per-access resolver. The generated frame size, helper table, artifact ABI,
  epoch checks, and validation IR are unchanged, so old `.waot` artifacts
  remain valid (and retain their older, slower generated sequence).
- **Correctness is exact on both architectures:** frozen install, formatting,
  release build, and all 44 unit suites pass. The complete interpreter/JIT/AOT
  corpus is tier-identical on macOS and Linux: pass=65204, fail=389,
  skip=1532, staged=0, errors=0; JIT/AOT compiled=8588 on aarch64 and 8589 on
  x86-64.
- **Refreshed Wasmtime 47.0.3 comparison for the identical new workload:**
  compilation excluded, precompiled modules, one warmup discarded, seven
  samples. On macOS at 300M iterations, Wasmlight AOT is 594ms versus Wasmtime
  94.675ms (6.27x gap). In the Rosetta Linux VM at 50M iterations, Wasmlight
  AOT is 748ms versus Wasmtime 202.832ms (3.69x gap). Linux absolute timings
  describe the VM, not native x86-64 hardware.

## 2026-08-12 third measured optimization wave complete

- **Three accepted implementations are integrated:** `468bd5e` expands the
  aarch64 helper-free numeric loop cache from two to four expression
  temporaries beside its two allocated locals; `f10181a` reuses resolved
  direct-call metadata and specializes normal result gather/frame retirement;
  `b4c7395` pins a stable memory base and retains operands only for helper-free,
  zero-offset i32 guard-page loops with no calls or `memory.grow`. `fdfeea9`
  updates the cache-rotation test for the combined emitter seam.
- **Every lane passed an immediate serialized A/B gate before integration.**
  Four retained temporaries improved loop JIT/AOT by 3.1-3.9%/4.2-4.5%.
  Streamlined call frames improved fib(35) by 3.9-18.4%/9.9-12.6% across
  forward and reverse runs. The accepted memory-loop shape improved 30M scalar
  memory by 35.7%/36.9%; direct pinned-instance addressing, register-offset
  addressing, and base pinning alone were each below the materiality threshold.
- **Rejected implementations stayed out:** allocating four long-lived loop
  slots regressed 336ms to 634ms (~89%); destination-aware ALU emission lost
  most of the temporary-cache gain; and the earlier Pascal helper spanning a
  recursive native call was not retried. No Pascal helper frame spans the
  accepted direct-call path's native callee.
- **Fresh integrated Apple Silicon release medians, seven samples:** against
  the exact pre-wave 345/342ms loop, 429/488ms fib, and 86/87ms memory medians,
  JIT/AOT now measure 320/319ms (7.2%/6.7%), 373/372ms (13.1%/23.8%), and
  46/46ms (46.5%/47.1%). Numeric 43ms, SIMD 135ms, and startup 7/9ms remain in
  their prior bands. Isolated serialized A/B figures above are the acceptance
  evidence; the combined percentages include ordinary host-load variation.
- **Safety boundaries:** the four-temporary cache retains the existing
  helper/call/reference/memory-free eligibility and flushes canonical exits;
  epoch mismatch remains non-returning. The memory-specific path is aarch64
  only and requires one memory, zero offsets, i32 guard-page addresses, a
  back-edge, and no call, tail call, or grow; every other shape retains live
  per-access state and cache invalidation. Direct calls retain stack exhaustion,
  precise GC publication, exceptional unwind, and the tail-call trampoline.
- **Combined correctness:** macOS frozen install, formatting, release build,
  all 44 unit suites, and the full three-tier corpus are green: pass=65204,
  fail=389, skip=1532, staged=0, errors=0, compiled=8588 for JIT/AOT.
  Linux/x86-64 also passes frozen install, formatting, release build, all 44
  suites, and the identical corpus tally with compiled=8589.
- **Refreshed Wasmtime 47.0.3 comparison:** end-to-end precompiled commands,
  identical fixed modules, compilation excluded, one warmup discarded. On
  macOS, Wasmlight/Wasmtime medians are 323.169/83.658ms for the 300M loop
  (3.86x), 173.011/18.536ms for 50M varying-address scalar loads (9.33x), and
  386.399/34.755ms for fib(35) (11.12x). In the Rosetta x86-64 Linux VM they
  are 2.058/0.647s (3.18x), 2.615/0.181s (14.46x), and 3.677/0.423s (8.70x).
  The Linux absolute times describe the VM, not native x86-64 hardware.

## 2026-08-12 second measured optimization wave complete

- **Three more measured commits are integrated on
  `codex/fix-tests-tier-performance`:** `749e123` pins the one static memory
  used by an aarch64 function while loading its live base and size at every
  access; `0484de4` keeps allocated numeric values in machine registers across
  epoch-only back-edges while preserving the epoch check and flushing exits;
  `65d061e` clears only validation-computed semantic local/reference slots at
  compiled-frame entry. The attempted runtime scan for sparse clearing
  regressed fib and was removed before the precomputed design was accepted.
- **Profiles selected the work:** a 1B-iteration memory sample attributed
  562/2,483 samples to per-access `JitMemoryAt` resolution and 302/2,483 to
  `InterpContextFor`; fib(40) attributed 562/2,385 samples to `ValueZeroSlots`;
  generated numeric loops showed canonical register-file writeback at every
  epoch-only back-edge.
- **Fresh integrated Apple Silicon release medians, seven samples:** versus the
  exact pre-wave build, the 300M loop moved from JIT/AOT 417/417ms to 336/335ms
  (19.4%/19.7% faster), fib(35) from 488/498ms to 422/407ms
  (13.5%/18.3%), and 30M scalar-memory iterations from 270/270ms to 84/85ms
  (68.9%/68.5%). Numeric, SIMD, and startup stayed flat at 43ms, 134ms, and
  7/9ms JIT/AOT startup batches.
- **Linux/x86-64 guard measurement:** in the Rosetta-backed OrbStack VM, JIT
  medians moved from loop 2,214ms to 2,026ms and fib(35) 5,493ms to 4,413ms;
  memory 2,697ms to 2,691ms, numeric 361ms to 365ms, SIMD 1,174ms to 1,156ms,
  and startup 29ms to 29ms are flat within VM noise. The aarch64 memory pin is
  intentionally absent on x86-64.
- **Current Wasmtime 47.0.3 comparison:** end-to-end precompiled commands over
  identical fixed modules, compilation excluded and one warmup discarded. On
  macOS, Wasmlight/Wasmtime medians are 335.686/82.917ms for the 300M loop
  (4.05x), 185.856/18.532ms for 50M scalar loads (10.03x), and
  405.980/34.810ms for fib(35) (11.66x). In the Rosetta x86-64 Linux VM they
  are 2.039/0.644s (3.17x), 2.603/0.180s (14.48x), and 4.421/0.425s
  (10.41x), respectively; those Linux absolute times describe the VM, not
  native x86-64 hardware.
- **Combined correctness is green:** frozen install, formatting, release build,
  and all 44 unit suites pass on macOS/aarch64 and Linux/x86-64. The complete
  pinned corpus is tier-identical on both: pass=65204, fail=389, skip=1532,
  staged=0, errors=0; JIT/AOT compiled=8588 on aarch64 and 8589 on x86-64.
  The memory-entry ABI change advances `.waot` ABI revision 3 to 4 so old
  artifacts fail closed; the validated IR format remains version 2.

## 2026-08-12 optimizing-codegen wave complete

- **Nine accepted commits are integrated on
  `codex/fix-tests-tier-performance`:** the isolated multi-workload benchmark
  harness; compiled scalar-memory inlining; conservative hot-loop register
  allocation; native scalar numeric lowering; the direct-call context trim;
  compare/branch and redundant-move fusion; and native integer SIMD plus its
  verified workload and x86 zero-extension correction. Each implementation was
  measured against its immediate baseline before integration.
- **Rejected experiments stayed out:** combining prepare/invoke/finish behind a
  Pascal call frame regressed recursive fib by 11.8%; scratch-free direct result
  delivery and bulk-zeroing also missed their gates. All were reverted. The
  accepted direct-call change only removes two redundant active-context checks
  and improved the immediate JIT/AOT medians by 3.0%/6.7%.
- **Fresh Apple Silicon release medians, five samples:** the 300M integer loop
  moved from JIT/AOT 740/745ms to 404/404ms (45.4%/45.8% faster); 30M scalar
  memory iterations from 847/846ms to 276/271ms (67.4%/68.0%); the 1M numeric
  workload from 97/97ms to 43/43ms (55.7%); and the 1M integer-SIMD workload
  from 322/318ms to 137/136ms (57.5%/57.2%). Recursive fib(35) moved from
  547/550ms to 495/492ms (9.5%/10.5%). Startup stayed in the same low-millisecond
  band. These are benchmark observations, not CI thresholds.
- **Current Wasmtime 47.0.3 comparison:** seven end-to-end samples, precompiled
  artifacts, identical fixed modules, with compilation excluded. For a 1.2B
  i32 mul-add loop, Wasmlight AOT is 1.651s versus Wasmtime 0.333s (5.0x gap).
  For 50M scalar loads, 0.290s versus 0.0227s (12.7x). For recursive fib(40),
  five Wasmlight samples and seven Wasmtime samples give 5.733s versus 0.354s
  (16.2x). The loop gap has narrowed materially; memory address-generation and
  recursive call mechanics are now the clearest remaining targets.
- **Terminal correctness gate is green on both backends:** macOS/aarch64 and
  Linux/x86-64 frozen install, formatting, release build, and all 44 unit suites
  pass. The complete pinned corpus is byte-identical across interpreter, JIT,
  and AOT on both architectures: pass=65204, fail=389, skip=1532, staged=0,
  errors=0; JIT/AOT compiled=8588 on aarch64 and 8589 on x86-64. The x86 SIMD
  mismatch found by the final gate was an unsigned i8/i16 lane-extract
  zero-extension bug; `MOVZX` and encoder/differential coverage fixed it before
  integration.
- **Artifact compatibility:** scalar-memory inlining appends
  `aohResolveMemory` and advances the compiled-helper ABI to revision 3, so
  older `.waot` artifacts fail closed. The validated IR format remains version
  2. The optimizer uses side tables and never rewrites or re-validates IR.

## 2026-08-12 compiled-tier optimization status

- **Both measured bottlenecks are fixed.** Static compiled-to-compiled calls
  now resolve/enter the shared logical + GC frame once and invoke the callee's
  machine-code entry directly; host/interpreted and dynamic calls retain the
  existing dispatcher. This removes the nested generic tier dispatcher and
  per-call seam catch without changing stack-exhaustion, GC, tail-call, trap,
  or exception-unwind behavior. A body containing `return_call*` deliberately
  stays on the trampoline so that invocation consumes its pending tail target.
  Both native backends also keep two clean,
  write-through values in caller-saved registers inside straight-line blocks.
  Branch joins, calls, helpers, complex control, and safepoints invalidate the
  cache; the in-memory register file remains canonical at every instruction
  boundary. The AOT ABI revision is 2 and old artifacts fail closed.
- **Correctness proof:** macOS/aarch64 release build, formatting, and 44/44
  unit suites pass. The OrbStack Linux/x86-64 release build and 44/44 suites
  pass. On both architectures the complete pinned corpus is byte-identical
  across tiers: pass=65204, fail=389, skip=1532, errors=0; compiled=8588 on
  aarch64 and 8589 on x86-64 for both JIT and AOT.
- **Fresh Apple Silicon/macOS medians:** release builds, Wasmtime 47.0.3
  default opt-level 2, fresh `.waot`/`.cwasm` artifacts. The tier-verified 300M
  i32 mul-add loop (five warmed samples) is wasmlight interp 4345ms, JIT 731ms,
  AOT 728ms; Wasmtime JIT 89.35ms and precompiled 88.02ms. Against the prior
  1132/1119ms compiled medians, register caching cuts wasmlight JIT 35.4% and
  AOT 34.9%; the Wasmtime gap narrows from 13.1x to 8.2-8.3x.
- **Recursive fib(35):** wasmlight interp 1117.84ms, AOT 551.03ms; Wasmtime JIT
  39.50ms and precompiled 39.27ms. Direct calls cut wasmlight AOT by 47.2%
  versus the prior 1044ms and narrow the compiled gap from 28.3x to 14.0x.
  No-op command startup (50 samples) remains wasmlight's advantage under the
  same current load: interp 6.15ms/AOT 6.09ms versus Wasmtime 8.18ms/7.91ms.
  These remain workload measurements, never CI assertions.

## 2026-08-12 repair status

- **Main's six red CI jobs were classified from run 31565283477 and fixed.**
  Linux/aarch64 now links `__clear_cache` from `libgcc_s`; Linux guard-fault
  delivery no longer requests `SA_ONSTACK`, which FPC 3.2.2's Linux
  `fpSigAction` combines with a missing `sa_restorer`; Windows-only tests now
  distinguish CPU architecture from executable-JIT capability, accept the
  32-bit record alignment FPC actually selects, and avoid loading a signalling
  NaN through x87. Unsupported-tier JIT tests assert a clean decline instead of
  demanding native compilation.
- **The conformance workflow no longer treats wasmspec's expected exit 1 as a
  missing tally.** Both CI workflows capture the output, require a `TOTAL` line,
  then enforce `errors=0`, the pass floor, compiled counts and byte-identical
  tier signatures. Locally: all tiers report pass=65204, fail=389, skip=1532;
  JIT/AOT compiled=8588.
- **The apparent tier performance failure was benchmark contamination.**
  `wasmlight run` auto-detects a sibling `.waot`; the old 300M-loop “interp”
  result (~1.2s) was already AOT because it did not pass `--no-aot`. The new
  `wasmbench` steady-state case creates isolated stores and refuses to report a
  JIT/AOT number unless `ForceCompile`/`AotLoadAndWire` really wired native
  code. On aarch64-darwin release: interp 4317ms, JIT 1131ms, AOT 1109ms for
  300M iterations (3.8x compiled speedup). JIT and AOT matching is correct: the
  artifact deliberately serializes the JIT's byte-identical machine code; AOT's
  separate advantage is startup.
- **Current verification:** macOS and Linux/x86-64 `lwpt test` both 44/44;
  focused Linux/x86-64 real guard-fault suite 26/26; Linux/aarch64 `wasmlight`
  direct build links; exact local three-tier corpus identity passes; frozen
  install, formatting, YAML parsing and diff whitespace checks pass. The broad
  markdown lint still reports the repository's existing 100 issues in nine
  `.agent` design/handoff files. The branch is pushed; no PR has been opened.
- **Current Wasmtime comparison:** Apple Silicon/macOS, wasmlight `c0b604a`
  release build, Wasmtime 47.0.3 at its default opt-level 2, one warmup per
  command. The tier-verified 300M i32 mul-add loop (five wasmlight samples,
  fifteen Wasmtime samples) has medians: wasmlight interp 4315ms, JIT 1132ms,
  AOT 1119ms; Wasmtime JIT 85.24ms and precompiled 85.20ms. Wasmtime is 13.1x
  faster than wasmlight's compiled tiers there. Recursive fib(35), measured as
  end-to-end CLI commands, is wasmlight interp 1122ms, AOT 1044ms, Wasmtime JIT
  36.43ms, precompiled 36.82ms: a 28.3x compiled-tier gap. No-op command startup
  medians over 50 samples are wasmlight interp 2.85ms/AOT 2.83ms versus Wasmtime
  JIT 4.88ms/precompiled 4.74ms, so wasmlight is about 1.7x faster on trivial
  startup. The loop points at memory-register-file traffic; the much larger
  recursive gap points at the per-call Pascal helper/seam. These are workload
  measurements, not CI assertions or a general benchmark-suite claim.

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
  (+8). Remaining 389 = 356 post-3.0 proposals + 14 legacy EH (both out
  of scope) + ~9 (module definition/instance) harness forms + a few
  deferred decode/framing edges.
- **Superseded perf note (measurement was contaminated):** aarch64-darwin,
  min of 4 runs.
  fib(35): interp 4682ms / aot 4567ms / wasmtime 38ms. loop(300M mul-add):
  interp 1205 / aot 1194 / wasmtime 94. noop startup: interp 3 / aot 3 /
  wasmtime 5. TAKEAWAYS, stated plainly: (1) wasmtime's optimizing
  Cranelift JIT is 13-120x faster than wasmlight's baseline on throughput
  — expected, and the VISION "rivals C/Rust" goal is NOT met by the
  current tiers. The wasmlight comparison itself is invalid: after producing a
  sibling artifact, the supposed interpreter command omitted `--no-aot`, so it
  auto-loaded AOT too. See the 2026-08-12 status above for the corrected,
  tier-verified measurement. The wasmtime numbers have not been re-measured in
  this repair and must not be combined with the corrected local numbers.

## THE ENTIRE ROADMAP (Tracks A-J) IS DELIVERED

Decode (A), validate + register IR (B), the .wast harness + wat assembler
(C), runtime + precise GC (D), interpreter (E), embedding API + WASI
preview1 (F), SIMD (G), exception handling (H), baseline JIT — aarch64 +
x86-64 (I), AOT + artifact cache (J) — all shipped and proven. The
runtime decodes, validates, instantiates, and EXECUTES the complete core
wasm 3.0 instruction set on two architectures via three interchangeable,
observationally-identical tiers (interpreter / baseline JIT / AOT), runs
real WASI programs under deny-by-default sandboxing, and is conformance-
tested byte-for-byte against the upstream corpus (65,204 pass) in every
tier on both arches.

## Track J (AOT) — COMPLETE (all 6 waves, both arches, CLI)

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

## Track I is DONE; the 4 non-corpus review findings (#48-51) are FIXED

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
