# Testing

## Executive Summary

- `lwpt test` discovers, compiles, and runs `source/units/*.Test.pas` as
  independent programs. Twenty-three suites today, 590 tests, all green.
- Unit suites are co-located with the unit they cover and carry the
  malformed-input cases as literal bytes.
- The upstream WebAssembly spec testsuite **is wired up** through
  `build/wasmspec`, which judges the binary-module subset (decode and
  validation) and skips what needs an execution tier. The measured
  binary-subset conformance is reported below; `assert_return` and
  `assert_trap` remain out of reach until a tier lands.
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
| Spec testsuite | It matches *the spec*, judged externally | shipped for the binary subset; execution assertions await a tier |

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
section extent may fall outside its module. Every valid fixture but
`simd.wasm` must also *validate*, and two of them are checked against the
IR their `.wat` source implies. `simd.wasm` is asserted to fail with the
staged-SIMD message rather than being quietly skipped, so the day Track G
lands, that assertion is what fails first.

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
| `Wasm.Validator.Const.Test` | Constant expressions and the IR they lower to: `t.const`, the extended-const arithmetic, `ref.null` / `ref.func`, `global.get` of an imported or previously defined **immutable** global, and the GC allocation set. The rejections carry the same weight — `nop`, `local.get`, `i32.eqz`, `array.new_data`, a mutable or forward `global.get`, a global reading itself, and `v128.const`, which is constant in the spec but staged to Track G. |
| `Wasm.Validator.Body.Test` | The fused walk, at 81 tests the largest suite: control flow lowering (block/loop/if merges as explicit moves, the only safepoint-flagged jump being a loop back-edge, `br_table` stubs, parallel moves breaking cycles), local initialization tracking for non-defaultable locals, calls and tail calls, globals, tables, memory including multi-memory and memory64 address types, references, the `$FB` GC space with `br_on_cast` edges, and `try_table` handler ranges. It also pins the malformed/invalid split: a body ending before its span, a misplaced `else`, an unassigned opcode, and `memory.init` without a data count section are decode errors, not validation errors. |
| `Wasm.Validator.Test` | Module-level rules and the assembled IR: a module exercising every index space validates and its IR carries each space imports-first, plus canonical types, per-function code, initialisers, segments, start, and C.REFS. The phase-order rules are the point of the rejections — a global initialiser reading a later global, a table initialiser reading a defined global, a duplicate export name, a start function with parameters, a tag whose type has results, limits out of range. |
| `Wasm.Fixtures.Test` | The fixture cross-check described above: every valid fixture decodes and (bar `simd.wasm`) validates, every malformed one is rejected, two lower to the IR their source implies, and no section extent escapes its module. |
| `Wasm.Wast.Test` | The `.wast` lexer, s-expression parser, and command classifier (Track C's first slice): nesting block comments, string literals decoding to bytes, testsuite-local directives classifying as unknown rather than failing the script. |
| `Wasm.Wast.Runner.Test` | The command runner over inline scripts (modules as literal `\hh` bytes): `assert_malformed` / `assert_invalid` passing on a prefix match and failing on a wrong prefix or wrong error class, top-level modules judged, everything needing a tier or an assembler skipped, the staged-SIMD carve-out gated on the wanted class, and the empty-expected-string degrading to a class-only match. |
| `Wasm.Runtime.Values.Test` | The 8-byte value slot: `i31` payload boundaries and zero-extension, references keeping the low bit clear, narrow writes zeroing the whole slot, and `aux-default` defaults. |
| `Wasm.Runtime.Traps.Test` | The trap path: confirmed trap messages against the pinned spec, kinds kept distinct, the fault-attribution reservation registry exact at both ends, and the trampoline converting a trap into exactly one `EWasmTrap` — nested invocations unwinding to their own. |
| `Wasm.Runtime.Memory.Test` | The chokepoint: the strategy matrix decided by (platform, address type), the off-by-one bound with static offset and access size folded in, every strategy trapping at the same access, guard reservations registered for attribution, and growth preserving/zeroing pages and respecting both maxima. |
| `Wasm.Runtime.Store.Test` | The engine type table and instances: alpha-equivalent rec groups from two modules sharing engine ids and distinct ones staying apart, the supertype display agreeing with the validator, import matching (functions, tables, memories, globals, tags) with the right variance, runtime casts across modules, and host-root rooting. |
| `Wasm.Runtime.Instantiate.Test` | The instantiation sequence: global initialisers in order, active data and element segments reaching memory and tables through the chokepoint, segments dropped and buffers released, constant-expression GC allocation, link errors raised before any mutation, and out-of-bounds active segments trapping after their partial effect. |
| `Wasm.Runtime.Gc.Test` | The precise collector: field offsets by declaration order and packed width, eight-byte alignment per size class, packed fields extending and stores truncating, null/OOB access trapping, reclamation and reuse, host roots and root scopes, unreachable cycles collected, the frame walk keeping exactly the flagged registers, and allocation-site triggering. |

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
get to grade itself against. It is wired up now, through `build/wasmspec`
(`source/apps/wasmspec.pas`), over the subset the shipped layers can
judge. See [`tests/spec/README.md`](../tests/spec/README.md) for fetching
the corpus, running the harness, and the full failure breakdown.

Its shape, measured against `WebAssembly/testsuite@main`: **288 `.wast`
files** (257 of them the 3.0 root corpus), ~192,500 lines, and **~64,100
assertions** — `assert_return` 53,291, `assert_trap` 5,252,
`assert_invalid` 3,009, `assert_malformed` 2,208, `assert_unlinkable` 262,
`assert_exception` 41, `assert_exhaustion` 15.

### What is judged, and what is measured

Decode and validation are shipped; there is no execution tier and no
text-format assembler. So `wasmspec` gives a real verdict to exactly the
commands that carry the module in `(module binary "...")` form — top-level
`module` (must decode **and** validate), `assert_malformed` (must raise
`EWasmDecodeError`), and `assert_invalid` (must raise
`EWasmValidationError`) — and reports everything else as `SKIP` with a
reason. The skip column is never folded into the totals, so a report
cannot read as more conformance than was measured.

The current run over the whole checkout
(`WebAssembly/testsuite@de54fd27ecf3e68dfd16b6199c548df77b6a2cc1`):

```text
TOTAL files=288 errors=0 pass=1034 fail=35 skip=66050 staged=6 total=67125
```

The 3.0 root corpus alone is `pass=787 fail=17 staged=6`; the non-root
trees add `pass=247 fail=18`. Judged commands — `pass + fail + staged` =
**1,075** — are the `(module binary ...)` cases the runner reached, which
is the ceiling until a text assembler exists. The `skip` column is the size
of the unbuilt work, not a coverage gap in the shipped layers.

This is honest, bounded conformance: within the binary subset, the decoder
and validator reject what upstream rejects, with the right error class, and
with a message upstream's expected string is a prefix of — bar the 35
documented failures, which are post-3.0 proposals outside the pinned target
plus a handful of message-wording divergences (see
[`tests/spec/README.md`](../tests/spec/README.md)). It is **not** a claim
about execution: `assert_return`, `assert_trap`, and the rest still skip,
so nothing here says a module *runs* correctly.

`STAGED` (6) is its own status: a case that trips the staged `$FD` vector
message and would otherwise fail, kept apart so the vector files cannot
bury a real divergence. It is never counted as a pass.

### What the corpus still imposes, for the tiers to come

Two of the harness requirements are already met and two more are pinned by
construction; the rest wait on an execution tier:

1. **Lazy decoding — met.** `(module quote ...)` and `(module binary ...)`
   — 1,311 and 1,069 occurrences — are assembled or decoded at *command
   execution* time, not script-parse time, so `assert_malformed` observes
   the failure it exists to observe.
2. **Failure strings are prefix-matched — met for the binary subset.** The
   reference interpreter checks that the expected string is a prefix of the
   actual message, so our error messages are part of conformance. Running
   this corpus is what settled the decode- and validation-reachable
   prefixes; the prefixes only an execution tier can reach still carry
   `UNCONFIRMED` markers in the source.
3. **NaN classes, not bit patterns.** `nan:canonical` (3,283) and
   `nan:arithmetic` (3,391) will rule out bitwise float comparison once
   `assert_return` is judged.
4. **`(either ...)` results** (32 occurrences) for relaxed-SIMD outcomes
   that are implementation-defined within a documented set.
5. **Host references** — `(ref.extern n)` (140) and `(ref.host n)` — will
   need a host-reference notion in the harness once actions run.

Two traps, both handled: `assert_malformed_custom` and
`assert_invalid_custom` are testsuite-local extensions absent from the
reference grammar, so the runner classifies them as unknown and skips
rather than choking; and `assert_return` is 83% of all assertions but is
concentrated in the SIMD files, so **sequence by file, not by assertion
count** — a majority of assertions is not a majority of features.

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
