# Handoff

Updated: 2026-08-09 (Track H — exception handling)

## Current state — CORE WASM 3.0 IS COMPLETE

- **Tracks A, B, C, D, E, G, H delivered.** The runtime decodes,
  validates, instantiates, and EXECUTES the COMPLETE core wasm 3.0
  instruction set — numeric, reference, GC, SIMD, and exception
  handling. There is no staged core feature left.
- Gates on the merged tree: `lwpt format`, `lwpt build`, `lwpt test`
  (33 suites, 974 tests), `lwpt install --frozen` — all green. Docs
  markdownlint-clean.
- **Corpus (WebAssembly/testsuite@de54fd27, 288 files, errors=0):**
  pass=65184 fail=408 skip=1533 **staged=0**. ROOT (3.0): pass=64651
  fail=52. Judged ~65,600 of ~67,000. staged fell 38→0 (EH was the last
  staged feature).
- **Everything is UNCOMMITTED** (the user commits between turns; the
  whole runtime is untracked working state — `git stash`/HEAD is NOT a
  valid baseline).

## What shipped this session (Track H — exception handling)

Design doc: .agent/design/eh-spec.md. The groundwork was pre-shipped by
earlier tracks (the IR ops iroThrow/iroThrowRef, try_table validation +
handler tables + catch payload registers, tag validation, exn GC objects
wokExn with traced args) — Track H was mostly the interpreter unwind.
- H1 (Wasm.Core): EWasmException = class(EWasmError), a SIBLING of
  EWasmTrap (an uncaught wasm exception is distinct from a trap; the
  harness discriminates). Carries ExnRef + TagAddr.
- H2 (Wasm.Interp — the crux): un-staged throw/throw_ref; the EXPLICIT
  unwind over the activation stack (NO longjmp, NO Pascal raise except
  the uncaught case → EWasmException to the trampoline, satisfying
  ADR-0009's "own route"). throw allocates the exn (its only safepoint,
  before the arg copy), then UnwindException searches each frame's static
  handler table innermost-first, matching by TAG ADDRESS, popping frames
  (Heap.PopFrame) until a clause matches; ResumeAtClause writes the
  payload (+ exnref for _ref clauses) into the target label's merge
  registers and resumes. Deviation (correct, reviewed): popped-into
  caller frames are scanned at IP-1 (call-site), the throwing frame at
  IP — the standard return-address rule the corpus requires.
- H3 (Wasm.Wast.Runner + Wasm.Validator.Body): assert_exception judging
  (wakException, PASS iff EWasmException, handler ordered before the
  generic EWasmError); retired the EH staging; fixed the validator so
  catch_ref/catch_all_ref deliver a NON-NULL (ref exn) not a nullable
  exnref (unblocked try_table.wast:420).

## Review outcome (Opus-5; corpus = behavior oracle)

CLEAN — no correctness bugs. All unwind edges verified: GC safety during
pop-and-continue (allocation-free unwind; popped frames unregistered;
exnref rooted before resume), the IP-1 call-site scan, tag-address
matching, TRAP-1 at the uncaught raise, the (ref exn) fix. Findings all
LOW/INFO: dead wrsStaged bucket (defensible), a trivial dead ArgC
compute, and three FORWARD hazards for Track F host embedding (uncaught
ExnRef is an unrooted raw handle after the entry frame pops — safe today
because the harness reads only the message and nothing allocates between
raise and read; a real Pascal host frame between two invokes receiving
an EWasmException is untested). None are bugs; all are documented.

## Remaining fails (characterized, NOT 3.0-core gaps)

- ~356 PROPOSALS: custom-descriptors, custom-page-sizes, threads,
  wide-arithmetic — post-3.0, outside ADR-0004.
- ~52 ROOT: LEGACY EH encoding (try/catch/delegate/rethrow in
  testsuite/legacy/ — OUT of scope per the roadmap, correctly failing),
  the binary-leb128 decode wording (limits u64-vs-address-type-u32
  width, deliberately deferred), 2 throw.wast assert_invalid type-
  mismatch WORDING edges (generic "operand stack underflows" vs upstream
  "instruction requires [i32] but stack has []"), M7 extern/any convert
  imprecision, the `(module definition/instance)` multi-module linking-
  harness forms (a runner feature, not built), a couple assembler edges
  (id.wast $"quoted", obsolete anyfunc, call_indirect64 inline elem).
- staged=0, skip ~1,533 (mostly assert_unlinkable 262 + host-import-
  dependent + the linking-harness forms).

## Next steps (dependency order)

1. **Track I — baseline JIT** (x86-64 + aarch64). The interpreter is the
   differential reference (ADR-0001). Inherits: emit the epoch check at
   back-edges, produce a stack map at safepoints (RefRegBits is already
   the projection), keep live refs discoverable (constrains regalloc).
   Guard-page memory becomes the JIT's inline-access optimization once
   signal→trampoline delivery is proven in-process (interpreter uses
   explicit checks today). Observational-identity items to match are in
   interp-spec §8 + simd-spec §9 + eh-spec §9 (unwind semantics, tag-
   address matching, exn alloc as a safepoint, relaxed-op R=0, per-lane
   NaN, FP rounding, trap timing).
2. **Track J — AOT + artifact cache** (needs I). Artifacts record the IR
   version (currently 2) and are rejected on mismatch.
3. **Track F — embedding API + WASI preview1** (needs E; independent of
   I/J). Wasm.Engine, wasmlight run, deny-by-default capabilities. Track
   H's F3/F4 forward-hazards land here: host-root registration for a
   live exn/ref handle across host frames.
4. Small residuals if desired: the `(module definition/instance)`
   linking-harness support (unlocks more linking assertions + the
   `unexpected token` module cluster); the binary-leb128 limits-width
   decode fix; the 2 throw.wast type-mismatch wording edges; a spectest
   host module in the runner.
5. User decision standing: NO GitHub issues until the roadmap is done.
6. Local hygiene: builds drop gitignored .o/.ppu into
   .lwpt/modules/testing/, breaking a LOCAL `lwpt install --frozen`
   (fresh CI clone unaffected). `rm` them if frozen complains.
