# Handoff

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
