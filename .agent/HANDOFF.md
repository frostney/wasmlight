# Handoff

Updated: 2026-08-09 (Tracks C + D)

## Current state

- **Tracks A, B delivered & committed** (HEAD = "Complete section body
  decoding" is Track A; Track B is in the working tree from the prior
  session per the commit cadence — the user commits between turns).
- **Tracks C (partial) and D (complete) delivered, UNCOMMITTED** in the
  working tree (~51 files) awaiting the user's commit.
- Gates on the merged tree: `lwpt format --check`, `lwpt build`,
  `lwpt test` (23 suites), `lwpt install --frozen` — all green. Docs
  markdownlint-clean.
- **Conformance signal exists now:** `./build/wasmspec tests/spec/testsuite`
  → pass=1034 fail=35 (of 1,075 judged binary-module commands),
  skip=66,050 (need the wat assembler or an execution tier), staged=6
  (SIMD). The 35 fails are 6 false-rejections on out-of-scope proposals +
  29 message-wording divergences, all documented in tests/spec/README.md.

## What shipped this session

- **Track C slice**: Wasm.Wast.Runner + `wasmspec` CLI — judges
  assert_malformed/assert_invalid over binary modules with the
  reference-interpreter prefix rule; lazy decode; text/quote/action
  commands skip pending the wat assembler / Track E. Corpus cloned at
  tests/spec/testsuite (gitignored, commit de54fd27).
- **Track D (complete)**: Wasm.Runtime.Values (8-byte untagged value,
  0=null/low-bit-i31/else-pointer refs), .Traps (SIGSEGV/SIGBUS handler,
  reservation registry, setjmp trampoline, canonical trap messages),
  .Memory (the ONE chokepoint — ADR-0013 2×2 strategy matrix, guard
  pages + guard-assisted + bounds-checked; Windows = bounds-checks this
  wave, deliberate), .Store (engine-wide canonical re-interning, import
  matching, tables/globals/tags), .Instantiate (exec/modules order,
  init-expr evaluator, segment application with 3.0 active-OOB=trap),
  .Gc (precise non-moving mark-sweep, allocation-site triggers,
  host-root API, O(1) runtime subtyping, per-cycle mark polarity).
- **Wat assembler design doc**: .agent/design/wat-assembler.md — the
  path to the rest of Track C (~6,600 more judgeable commands). Design
  docs for B and D are in .agent/design/ (ir-spec.md, runtime-spec.md).

## Review outcome (2-axis, Opus-5 fallback — codex still credit-limited)

Found & fixed (4 parallel waves), all reproduced/corpus-confirmed:
- Guard reservation off-by-access-width in the chokepoint fold path —
  a v128/i64 access at max index+fold offset reached past the mapping
  (sandbox escape / crash). Fixed: fold only while
  `AOffset <= GuardBytes - ASize`; forked-child fault test now ships.
- Fault handler permanently disarmed itself on the first unrelated
  fault; dangling trampoline on a Pascal exception; guard-fault outside
  an invocation crashed. All fixed in .Traps.
- GC frame chain never re-established after a trap (ResetFrames had no
  caller) — now wired in the store's guest-entry try/finally.
- **Table-import element type was covariant; must be INVARIANT**
  (memory-safety: call_ref does no runtime check) — corpus-confirmed
  (linking.wast:441), fixed, test inverted.
- Null-trap messages: split into struct/array/func/i31/plain per the
  corpus (was 1 message failing 15/20).
- Cross-module interning made structural for out-of-group refs;
  root-scope leak on repeated instantiation; unknown-import link path;
  table write-barrier sites wired; ~12 UNCONFIRMED message prefixes
  settled from the corpus and marked confirmed.

Still open (documented in code, not blocking):
- extern/any externalize-internalize is invisible to ref.test/cast
  (M7) — needs a wrapper/flag at the convert site, which lands with
  Track E; staged test pins the current answer loudly.
- Windows guard-page/SEH trap path staged to bounds-checks (ADR-0005
  permits; revisit when the trap path grows SEH).
- `PRODUCTION` build mode is defined nowhere, so its optimisation block
  is never CI-compiled and safety asserts are always on — worth a
  deliberate decision.

## Next steps (dependency order)

1. **Track E — interpreter** (the critical-path next step; A/B/D done).
   Consumes TWasmIrModule + the store + the GC frame-walk contract
   (TWasmGcFrame: Slots/RefRegBits/RegisterCount; zero at entry, push
   before first safepoint, tail-call replacement not spanning a
   safepoint). Tail calls need O(1) frame replacement. Unlocks
   assert_return/assert_trap in the corpus and settles the execution-
   tier trap/link message prefixes still UNCONFIRMED.
2. **Track C rest — wat assembler** (parallel; design doc ready) —
   unblocks ~6,600 more corpus commands (text malformed/invalid).
3. Then G (SIMD; IR_FORMAT_VERSION→2), H (EH; try_table IR already
   emitted), I/J (JIT/AOT).
4. User decision standing: NO GitHub issues until roadmap done.
5. Local hygiene: builds can drop gitignored .o/.ppu into
   .lwpt/modules/testing/, breaking a LOCAL `lwpt install --frozen`
   tree-hash (CI on a fresh clone is unaffected). `rm` them if frozen
   complains.
