# Testing

## Executive Summary

- `lwpt test` discovers, compiles, and runs `source/units/*.Test.pas` as
  independent programs. Thirty-three suites today, 974 tests, all green.
- Unit suites are co-located with the unit they cover and carry the
  malformed-input cases as literal bytes.
- The upstream WebAssembly spec testsuite **is wired up** through
  `build/wasmspec`, which assembles text modules, decodes, validates,
  instantiates, and *executes* `assert_return` / `assert_trap` / `invoke`
  / `assert_exhaustion` / `assert_exception` through the interpreter — SIMD
  judged per lane (Track G) and exception-handling throwing judged (Track
  H), so the `staged` column is 0. The measured conformance is reported
  below; what still skips is a few host-import cases and
  `assert_unlinkable`.
- Two framework gotchas bite newcomers; both are listed below.

## Running

```bash
lwpt test               # every suite
lwpt test --jobs 4      # cap concurrency
lwpt test --bail 1      # stop at the first failure
lwpt test --verbose     # replay successful logs
```

Each `*.Test.pas` is a self-contained program using
`TestingPascalLibrary` from lwpt's `testing` package. The runner exits
non-zero if any test or compile fails.

## The three tiers

| Tier | What it proves | Status |
| --- | --- | --- |
| Co-located unit suites | The decoder and validator match *our reading* of the spec | shipped |
| Fixture cross-check | It matches *what toolchains actually emit* | shipped |
| Spec testsuite | It matches *the spec*, judged externally | shipped — assembles, validates, instantiates, and executes all of core wasm 3.0, SIMD and exception handling judged; a few host-import and `assert_unlinkable` edges still skip |

The middle tier exists because the first two claims are not the same one.
The section-order bug this project fixed was invisible to hand-written
tests precisely because the same misreading produced both the code and
the fixture that was supposed to check it. Real toolchain output does not
share our misconceptions.

## Fixture cross-check

`tests/fixtures/` holds 22 real modules — 11 valid, 11 malformed —
assembled by **wabt 1.0.41** and independently validated by
**wasm-tools 1.255.0** as an oracle. `Wasm.Fixtures.Test` decodes every
one: valid modules must decode, malformed ones must be rejected, and no
section extent may fall outside its module. Every valid fixture must also
*validate* — `simd.wasm` included now that Track G has landed — and two of
them are checked against the IR their `.wat` source implies. `simd.wasm`
is the only fixture that exercises the vector path end to end, and it both
decodes and validates.

Neither tool is needed to *run* the tests — the `.wasm` files are
committed. They are needed only to regenerate the corpus, via
`tests/fixtures/regenerate.sh`. Each fixture's `.wat` source sits beside
it; see [`tests/fixtures/README.md`](../tests/fixtures/README.md) for what
each one covers.

Two fixtures earn their place specifically:

- **`datacount.wasm`** — a passive data segment plus `memory.init` forces
  a data count section, which the grammar places *before* the code
  section. Id 12 precedes id 10. This is real wabt output, and a decoder
  written on "ids must increase" rejects it.
- **`tags.wasm`** — the second divergence, tag (id 13) between memory
  (id 5) and global (id 6).

The corpus size is asserted against a floor, so a corpus that vanishes
fails loudly instead of passing vacuously.

One trap worth knowing before regenerating: **`wat2wasm --enable-all` does
not produce Wasm 3.0.** It silently enables the experimental compact-imports
proposal, which re-encodes the import section into a grouped form that
`wasm-tools` rejects. `regenerate.sh` pins an explicit feature list
instead.

## What the unit suites cover

| Suite | Covers |
| --- | --- |
| `Wasm.Binary.Test` | LEB128 boundary encodings (u32/u64/s32/s64 extremes), and every rejection path: overlong, over-wide, truncated, unterminated. Plus fixed-width reads, names, sub-reader bounds, cursor arithmetic. |
| `Wasm.Core.Test` | The type vocabulary and the section-order table — the two encodings this project once got wrong: signed type codes sharing an encoding space with type indices, and section ids not being the encoding order. |
| `Wasm.Decoder.Common.Test` | The shared type-form readers: type codes as literal bytes (overlong sLEB spellings of valid codes are malformed), limits with exactly four assigned flag bytes under both address types, the mut/attribute bytes' tiny assigned ranges. |
| `Wasm.Decoder.Types.Test` | The type section's 3.0 recursive-type grammar: rec/sub/comptype form codes as literal bytes, `$4F` final vs `$50` non-final, both shorthands normalising into one model shape, exact body consumption. |
| `Wasm.Decoder.Entities.Test` | Imports through tags: all five extern kinds, both table forms (default-init and 3.0 explicit-init), init-expression spans pinned exactly, start, and duplicate export names decoding fine (name disjointness is validity). |
| `Wasm.Decoder.Segments.Test` | Element, code, data, and data count: all eight element flag encodings, code entries with run-length locals and body spans, all three data flags, span offsets asserted absolute against nonzero bases. |
| `Wasm.Decoder.Expr.Test` | The expression skipper over every immediate-shape family, including the `$FB`/`$FC`/`$FD` prefixed spaces; exact span arithmetic; non-constant instructions skipping fine (constness is validation). |
| `Wasm.Decoder.Test` | Preamble acceptance and rejection, section walk and extents, ordering rules, duplicate sections, custom-section names and the overrun case, section lookup, end-to-end decodes, and the cross-section function/code and data-count rules. |
| `Wasm.Module.Test` | The model's storage contract: entity lists round-trip, indexed getters range-check, `Clear` resets everything, and index-space counts include imports first. |
| `Wasm.Ir.Test` | The IR as a contract every tier will be held to: the op enum dense and its ordinals pinned, `IR_OP_INFO` total over it, the instruction record's fixed layout, packed index pairs and float *bit patterns* round-tripping, length-prefixed aux blocks, safepoint classification, the reference-register bitset, `IR_FORMAT_VERSION` stamped on the module, and the disassembler's line layout — which the validator suites then assert against. |
| `Wasm.Validator.Types.Test` | Canonicalisation and matching: alpha-renamed rec groups interning to the same ids and structurally different ones staying distinct; the four abstract hierarchies disjoint, each with its own bottom; supertype displays; one-way nullability; params contravariant and results covariant; struct width/depth and array element subtyping with invariant mutable fields. Plus the rectype rejections — a supertype in a later group, inside the declaring group, or `final`. |
| `Wasm.Validator.Const.Test` | Constant expressions and the IR they lower to: `t.const`, the extended-const arithmetic, `ref.null` / `ref.func`, `global.get` of an imported or previously defined **immutable** global, and the GC allocation set. The rejections carry the same weight — `nop`, `local.get`, `i32.eqz`, `array.new_data`, a mutable or forward `global.get`, and a global reading itself. `v128.const` is a constant instruction and is accepted (Track G). |
| `Wasm.Validator.Body.Test` | The fused walk, at 105 tests the largest suite: control flow lowering (block/loop/if merges as explicit moves, the only safepoint-flagged jump being a loop back-edge, `br_table` stubs, parallel moves breaking cycles), local initialization tracking for non-defaultable locals, calls and tail calls, globals, tables, memory including multi-memory and memory64 address types, references, the `$FB` GC space with `br_on_cast` edges, the `$FD` vector space (operands and results typed, lane immediates bounds-checked, `v128` results allocated into even-aligned slot pairs), and `try_table` handler ranges. It also pins the malformed/invalid split: a body ending before its span, a misplaced `else`, an unassigned opcode, and `memory.init` without a data count section are decode errors, not validation errors. |
| `Wasm.Validator.Test` | Module-level rules and the assembled IR: a module exercising every index space validates and its IR carries each space imports-first, plus canonical types, per-function code, initialisers, segments, start, and C.REFS. The phase-order rules are the point of the rejections — a global initialiser reading a later global, a table initialiser reading a defined global, a duplicate export name, a start function with parameters, a tag whose type has results, limits out of range. |
| `Wasm.Fixtures.Test` | The fixture cross-check described above: every valid fixture decodes and validates — `simd.wasm` included, the one fixture exercising the vector path end to end (Track G) — every malformed one is rejected, two lower to the IR their source implies, and no section extent escapes its module. |
| `Wasm.Wast.Test` | The `.wast` lexer, s-expression parser, and command classifier (Track C's first slice): nesting block comments, string literals decoding to bytes, testsuite-local directives classifying as unknown rather than failing the script. |
| `Wasm.Wast.Runner.Test` | The command runner over inline scripts: `assert_malformed` / `assert_invalid` passing on a prefix match and failing on a wrong prefix or wrong error class (text operands keyed on `EWasmTextError`, binary on `EWasmDecodeError`), top-level modules assembled/decoded/validated/instantiated, `assert_return` / `assert_trap` / `invoke` executed through the interpreter and compared (SIMD results compared per lane), `assert_exception` judged against a thrown wasm exception (Track H) with the staged carve-out retired, and the empty-expected-string degrading to a class-only match. |
| `Wasm.Wast.Values.Test` | The assertion value parser and result comparator: hex and decimal float text packed to exact bits, `nan:canonical` / `nan:arithmetic` matched as classes rather than bit patterns, `±0` and subnormal boundaries, the reference matchers `ref.null` / `ref.extern` / `ref.func`, `v128.const` parsed and compared **per lane** (a NaN class can sit in one lane while its neighbours are exact), and the relaxed-SIMD `(either …)` matcher accepting any listed alternative. |
| `Wasm.Wat.Numbers.Test` | The numeric-literal parser at its boundaries: `iN` magnitudes in the union `[-2^(N-1), 2^N-1]`, overlong/over-range rejections with upstream prefixes, and hex/decimal floats — subnormals, rounding ties, NaN payloads — to exact bits. |
| `Wasm.Wat.Lexer.Test` | The strict tokenizer: keyword/reserved/identifier/number/string/paren classification, the maximal-munch reserved-token rule the corpus's `assert_malformed` cases hinge on, string-escape decoding, and block-comment nesting. |
| `Wasm.Wat.Emit.Test` | The binary emitter as the inverse of the decoder: canonical (shortest) LEB128, the type/limits/composite encoders, and section size backpatching — proven by feeding emitted bytes back through `DecodeModule` and comparing the model. |
| `Wasm.Wat.Opcodes.Test` | The mnemonic table: every non-vector spelling mapped to its opcode byte(s), immediate shape, and natural alignment, cross-checked against the ranges `Wasm.Decoder.Expr` already enforces. |
| `Wasm.Wat.Names.Test` | Identifier and label resolution across the twelve index contexts: forward references in module scope, the shadowing label stack, per-type field namespaces, `duplicate <space>` detection, and the implicit-typeuse dedup/insert table. |
| `Wasm.Wat.Assembler.Test` | The assembler end to end: every module field (types with rec/sub/final/struct/array and field names, imports/exports with inline abbreviations, memories, tables, globals, tags, elem/data sugar, start, funcs with param/result/local merging) and the instruction skeleton lowering to bytes that decode and validate. |
| `Wasm.Runtime.Values.Test` | The 8-byte value slot: `i31` payload boundaries and zero-extension, references keeping the low bit clear, narrow writes zeroing the whole slot, and `aux-default` defaults. |
| `Wasm.Runtime.Traps.Test` | The trap path: confirmed trap messages against the pinned spec, kinds kept distinct, the fault-attribution reservation registry exact at both ends, and the trampoline converting a trap into exactly one `EWasmTrap` — nested invocations unwinding to their own. |
| `Wasm.Runtime.Memory.Test` | The chokepoint: the strategy matrix decided by (platform, address type), the off-by-one bound with static offset and access size folded in, every strategy trapping at the same access, guard reservations registered for attribution, and growth preserving/zeroing pages and respecting both maxima. |
| `Wasm.Runtime.Store.Test` | The engine type table and instances: alpha-equivalent rec groups from two modules sharing engine ids and distinct ones staying apart, the supertype display agreeing with the validator, import matching (functions, tables, memories, globals, tags) with the right variance, runtime casts across modules, and host-root rooting. |
| `Wasm.Runtime.Instantiate.Test` | The instantiation sequence: global initialisers in order, active data and element segments reaching memory and tables through the chokepoint, segments dropped and buffers released, constant-expression GC allocation, link errors raised before any mutation, and out-of-bounds active segments trapping after their partial effect. |
| `Wasm.Runtime.Gc.Test` | The precise collector: field offsets by declaration order and packed width, eight-byte alignment per size class, packed fields extending and stores truncating, null/OOB access trapping, reclamation and reuse, host roots and root scopes, unreachable cycles collected, the frame walk keeping exactly the flagged registers, and allocation-site triggering. |
| `Wasm.Interp.Numeric.Test` | The numeric leaf functions on raw bit patterns: modulo-2^N integer arithmetic, the trapping conversions, sign extension, and float ops preserving NaN payloads across the call boundary — each case a literal input and expected bits. |
| `Wasm.Interp.Vector.Test` | The `v128` vector leaf functions on literal 16-byte vectors: lane-wise arithmetic wrapping the lane width, saturating/narrowing clamps, shift counts taken mod the lane width, the per-lane NaN discipline (canonicalise to the positive pattern; `pmin`/`pmax` and `min`/`max` selecting bit-for-bit), swizzle/shuffle lane indexing, and relaxed SIMD reducing to its non-relaxed twin on the deterministic profile (R=0). |
| `Wasm.Interp.Test` | The dispatch loop over the IR: numeric/parametric/variable/control/call flow, the explicit activation stack with `return_call` replacing the top frame in bounded stack, traps long-jumping to the trampoline as exactly one `EWasmTrap`, the epoch check at loop back-edges, the frame register file zeroed at entry, and exception handling (Track H) — `throw` / `throw_ref` / `try_table` unwinding the activation stack, handler matching by tag store-address, `catch`/`catch_ref`/`catch_all`/`catch_all_ref` binding, and an uncaught throw surfacing as exactly one `EWasmException`. |

Malformed modules are assembled byte-by-byte next to the assertion rather
than loaded from fixtures: each case *is* a specific malformation, and
spelling it inline puts the defect where the reader is already looking.
Broad well-formed coverage is the spec testsuite's job, not theirs.

## Framework gotchas

Both of these produce confusing failures and both are already worked
around in the existing suites — follow the existing pattern rather than
rediscovering them:

1. **FPC will not parse a generic call as the lone statement of an
   `on ... do`.** `on E: EFoo do Expect<Boolean>(True).ToBe(True);` fails
   to compile with "Illegal expression". Set a flag in the handler and
   assert after the `try`.
2. **The runner fails any test that records no assertion.** A rejection
   test that only calls `Fail` on the bad path asserts nothing when it
   passes. Assert the outcome instead — the suites use an
   `AssertRejected` helper that compares a `'<case>: rejected'` string, so
   the happy path records an assertion and the failure message names the
   case.

## Spec testsuite

The upstream corpus at
[WebAssembly/testsuite](https://github.com/WebAssembly/testsuite) is the
external conformance net, in the role the Autobahn suite plays for the
sibling duetto project: an independent judge that the project does not
get to grade itself against. It is wired up through `build/wasmspec`
(`source/apps/wasmspec.pas`), which now assembles text modules, decodes,
validates, instantiates, and executes assertions through the interpreter.
See [`tests/spec/README.md`](../tests/spec/README.md) for fetching the
corpus, running the harness, and the full failure breakdown.

Its shape, measured against `WebAssembly/testsuite@main`: **288 `.wast`
files** (257 of them the 3.0 root corpus), ~192,500 lines, and **~64,100
assertions** — `assert_return` 53,291, `assert_trap` 5,252,
`assert_invalid` 3,009, `assert_malformed` 2,208, `assert_unlinkable` 262,
`assert_exception` 41, `assert_exhaustion` 15.

### What is judged, and what is measured

Decode, validation, the wat text-format assembler, and the interpreter are
all shipped, so `wasmspec` gives a real verdict to most of the corpus.
Top-level modules (text, `(module quote ...)`, or binary) assemble, decode,
validate, and instantiate; `assert_malformed` and `assert_invalid` judge
the rejection (text operands via `EWasmTextError`, binary via
`EWasmDecodeError`, `assert_invalid` via `EWasmValidationError`); and
`assert_return`, `assert_trap`, `invoke`, and `assert_exhaustion` run
through the interpreter and compare. Everything not judged is `SKIP` with a
reason, and the skip column is never folded into the totals, so a report
cannot read as more conformance than was measured.

The current run over the whole checkout
(`WebAssembly/testsuite@de54fd27ecf3e68dfd16b6199c548df77b6a2cc1`):

```text
ROOT      pass=64651 fail=52  skip=611  staged=0 total=65314
PROPOSALS pass=533   fail=356 skip=922  staged=0 total=1811
TOTAL files=288 errors=0 pass=65184 fail=408 skip=1533 staged=0 total=67125
```

Judged commands — `pass + fail` — are **~65,592** of the corpus's
~67,000. The `staged` column is now **0**: Track H shipped the exception
throwing that used to sit there, so `try_table`, `throw`, and `throw_ref`
execute and `assert_exception` is judged.

This is honest conformance, and it now reaches execution across the
**whole 3.0 instruction set** — SIMD and exception handling included: the
assembler builds what upstream builds, the validator rejects what upstream
rejects with the right class and a prefix-matching message, and the
interpreter produces the results — lane by lane for `v128` — the traps, and
the exceptions the corpus asserts. The 408 failures are **not** 3.0-core
gaps — 356 of them are `PROPOSALS` (post-3.0 features outside the pinned
target), and the 52 `ROOT` failures are the legacy `try`/`catch`/`delegate`/
`rethrow` encoding (out of 3.0 scope), the pre-existing `binary-leb128`
wording divergences, the M7 `extern`/`any` convert imprecision, two
validator-message-wording edges on the 3.0 `throw`, and a few
assembler/decoder edges (see
[`tests/spec/README.md`](../tests/spec/README.md)). None is a SIMD or
exception-handling execution failure.

`STAGED` remains a distinct status in the harness — a case attempted and
deliberately set aside, never counted as a pass — but nothing populates it
now. Before Track H it held the exception-throwing forms; before Track G,
the ~1,620 vector-text cases the assembler could not emit. Both ship, so
the column reads 0.

### What the corpus imposes, and where each stands

1. **Lazy decoding — met.** `(module quote ...)` and `(module binary ...)`
   — 1,311 and 1,069 occurrences — are assembled or decoded at *command
   execution* time, not script-parse time, so `assert_malformed` observes
   the failure it exists to observe.
2. **Failure strings are prefix-matched — met.** The reference interpreter
   checks that the expected string is a prefix of the actual message, so
   our error messages are part of conformance. Running this corpus settled
   the decode, validation, assembler, and trap-message prefixes; any prefix
   no shipped path reaches yet still carries an `UNCONFIRMED` marker.
3. **NaN classes, not bit patterns — met.** `nan:canonical` (3,283) and
   `nan:arithmetic` (3,391) are matched as classes, so `assert_return`
   over a NaN result compares the class rather than the payload bits.
4. **`(either ...)` results** (32 occurrences) for relaxed-SIMD outcomes
   that are implementation-defined within a documented set — met: the
   matcher accepts any listed alternative, and the interpreter ships the
   deterministic profile (R=0), so its result is one of them.
5. **Per-lane SIMD comparison — met.** `assert_return` over a `v128`
   result compares each lane at the shape's width (Track G), so a
   `nan:canonical` lane can sit beside an exact one.
6. **Host references** — `(ref.extern n)` (140) and `(ref.host n)` — parse
   into identity matchers in `Wasm.Wast.Values`; imports the harness does
   not provide still skip (`import not provided by the harness`).

What still skips, never as a silent pass: host imports the harness does
not provide, and `assert_unlinkable` (linkage is not yet judged).
Exception handling no longer skips — `assert_exception` is judged and the
throwing forms execute (Track H). Two traps, both handled:
`assert_malformed_custom` and `assert_invalid_custom` are testsuite-local
extensions absent from the reference grammar, so the runner classifies
them as unknown and skips rather than choking; and `assert_return` is 83%
of all assertions but is concentrated in the SIMD files, so **sequence by
file, not by assertion count** — a majority of assertions is not a
majority of features.

Once a second execution tier exists, the harness runs per tier: every tier
must produce identical outcomes
([ADR-0001](adr/0001-tiered-execution-seam.md)), so the suite doubles as
the differential test between them. [roadmap.md](roadmap.md) is where that
sits in the order of work.

## Boundaries

- Nothing in the test stack touches the external network.
- Benchmarks are not tests. `wasmbench` numbers never become CI
  assertions — see the "Honest measurement" principle in
  [VISION.md](../VISION.md).
