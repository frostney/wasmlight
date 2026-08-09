# Handoff

Updated: 2026-08-09 (Track C — the wat text-format assembler)

## Current state

- **Tracks A, B, D, E delivered; Track C substantially delivered.** The
  runtime decodes, validates, instantiates, and EXECUTES WebAssembly,
  and the wat assembler now assembles text + (module quote) modules so
  the conformance harness judges the corpus at scale.
- Gates on the merged tree: `lwpt format`, `lwpt build`, `lwpt test`
  (32 suites, 852 tests), `lwpt install --frozen` — all green. Docs
  markdownlint-clean.
- **Corpus (WebAssembly/testsuite@de54fd27, 288 files, errors=0):**
  pass=38900 fail=444 skip=26161 staged=1620. Judged (pass+fail+staged)
  rose from ~1,075 to ~40,900. ROOT (3.0): pass=38367 fail=88.
  PROPOSALS (post-3.0, outside ADR-0004): pass=533 fail=356.
- **Everything is UNCOMMITTED** (the user commits between turns; HEAD is
  an early commit, so `git stash`/HEAD is NOT a valid baseline — the
  whole runtime + assembler is untracked working state).

## What shipped this session (Track C wat assembler)

Six flat Wasm.Wat.* units (design doc: .agent/design/wat-assembler.md):
- Wasm.Wat.Numbers — int/float literals→bits; one bignum rounder for
  hex + decimal floats (round-half-to-even, subnormals, overflow-after-
  rounding), INT64_MIN edge, nan payloads. Canonical-NaN consts now in
  Wasm.Core.
- Wasm.Wat.Lexer — strict tokenizer; the reserved-token maximal-munch
  rule (owns the 555-command 'unknown operator' bucket), annotation
  validation, UTF-8 source decoding.
- Wasm.Wat.Emit — the single home for LEB/byte emission + section
  builder with size backpatching (no name section).
- Wasm.Wat.Opcodes — 238 mnemonics → opcode+immediate-shape+natural
  align; the deliberate mirror of Wasm.Decoder.Expr (guarded by a
  no-duplicate build check). $FD SIMD gap → Track G.
- Wasm.Wat.Names — the twelve identifier spaces, label stack
  (innermost-first shadowing), implicit-typeuse dedup/insert (the §7
  risk, isolated).
- Wasm.Wat.Assembler — two-pass declare/emit, full instruction grammar,
  folded-instruction unfold (folded-if arm order proven at byte level),
  inline segments. AssembleWat/AssembleQuote → bytes → the shipped
  DecodeModule/ValidateModule/instantiate/interpret path.
- Integration: EWasmTextError promoted to Wasm.Core (sibling of
  EWasmDecodeError); Wasm.Wast.Runner wires text/quote modules and runs
  assert_return/trap/invoke/exhaustion AND assert_trap-over-module
  (instantiation traps + persisted segments); wasmspec ROOT/PROPOSALS
  split.

## Review outcome (Opus-5 standards review + the corpus as behavior oracle)

The six units came back HIGH QUALITY — clean leaf-to-root DAG, single-
homed emission, exemplary bignum boundary tests, correct error
hierarchy; findings were comment/vocabulary/dedup only, all applied.
Corpus-driven fixes this session:
- SERIOUS: far-OOB guard-page access raised EStackOverflow (first
  in-process SIGSEGV doesn't reach the trampoline) and aborted a whole
  file. Fixed: the interpreter now does EXPLICIT bounds checks on every
  memory strategy; guard pages are reserved as a future JIT (Track I)
  optimization once signal->trampoline delivery is proven. Plus
  defense-in-depth: foreign RTL exceptions converted at the invoke
  boundary, per-command isolation so one bad command can't abort a run.
- Assembler bugs: br_on_cast double-$FB-prefix; unknown-type false
  rejection (numeric typeidx now deferred to validation); typeuse-in-
  instruction parse gap; data-count emission; inline-function-type check;
  reserved/unexpected-token boundary.
- Validator: 12 'unknown <thing> N' prefixes (index-in-prefix,
  generalized from the historic unknown-memory fix); table.init/
  memory.init check order; immutable-global/field/array wording;
  offset-out-of-range (i32 memory, offset >= 2^32).
- Runtime: zero-member (rec) group accepted; uninitialized-element index
  detail; array.new_elem check-before-alloc; bare (ref.extern) matcher.

## Remaining fails (characterized, NOT 3.0 regressions)

- ~356 PROPOSALS fails: custom-descriptors, custom-page-sizes, threads,
  wide-arithmetic — post-3.0, outside the ADR-0004 pinned target.
- ~1,620 staged: SIMD ($FD) — validation staged to Track G; the
  assembler emits vector text so the marker stays a validator concern.
- ~88 ROOT fails: legacy exception-handling text encodings (Track H),
  the pre-existing binary-leb128 wording (limits read at u64 vs address-
  type u32 width — structural, deliberately deferred), a few edges.
- ~25,700 skips: assertions against staged (SIMD) modules, and
  assert_return/trap needing modules the assembler stages.

## Next steps (dependency order)

1. **Track G — SIMD**: decode done; validation staged (raises the
   staged message, IR_FORMAT_VERSION->2); execution needs the v128 value
   side-vector the interpreter reserved; the assembler's Wave 7 adds
   vector text forms (Wasm.Wat.Opcodes gap + lane literals). This
   retires the ~1,620 staged + a large chunk of skips.
2. **Track H — exception handling**: try_table IR + handler tables
   already emitted; iroThrow/iroThrowRef staged in the interpreter;
   Track E's runner already handles non-throwing try_table. Retires the
   legacy-EH ROOT fails (modulo the legacy vs 3.0 encoding note).
3. **Track I/J — baseline JIT / AOT**: differential-tested against the
   interpreter (ADR-0001); interp-spec §8 lists the observational-
   identity items. Guard-page memory becomes the JIT's inline-access
   optimization once signal->trampoline delivery is proven robust
   in-process (the interpreter uses explicit checks today).
4. Small residuals if desired: the binary-leb128 limits-width decode
   fix; a spectest host module in the runner would unlock more linking
   assertions; the throw.wast full-form 'type mismatch [i32]' bracket
   wording (4 fails, low value).
5. User decision standing: NO GitHub issues until the roadmap is done.
6. Local hygiene: builds drop gitignored .o/.ppu into
   .lwpt/modules/testing/, breaking a LOCAL `lwpt install --frozen`
   (fresh CI clone unaffected). `rm` them if frozen complains.
