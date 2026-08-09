# Architecture

## Executive Summary

- Layering is strictly bottom-up, and the vertical rule is that **spec
  rules live below the execution tiers**: decode and validation enforce
  them once, and no tier re-derives one.
- The **tier seam** ([ADR-0001](adr/0001-tiered-execution-seam.md)) is the
  central boundary: interpreter, baseline JIT, and AOT implement one
  contract and are selected per function by the runtime.
- The host surface — WASI preview1
  ([ADR-0002](adr/0002-wasi-p1-and-component-model.md)) — sits above the
  seam and reaches a guest only through imports, deny-by-default. The
  Component Model is post-v1
  ([ADR-0014](adr/0014-the-component-model-is-deferred-to-post-v1.md)).
- A decoded module **borrows** the caller's bytes
  ([ADR-0003](adr/0003-module-borrows-its-buffer.md)).
- The target is the **3.0 draft at a pinned commit**
  ([ADR-0004](adr/0004-conformance-target-is-the-3-0-draft.md)), so
  garbage collection and exception handling are layers in this diagram,
  not future additions to it.
- Shipped today: decode, validation and the IR, the runtime state below
  the tier seam (store, instances, the memory chokepoint, traps,
  instantiation, the precise collector), and the `.wast` runner over the
  corpus's binary subset. That runtime row landed ahead of the tiers that
  will sit on it, so the shipped rows in the table below are no longer
  contiguous. The execution tiers, the embedding API, and the host surface
  are staged in [roadmap.md](roadmap.md) and described here as design, not
  as behaviour you can call.

## Layering

Read bottom-up; each layer may use only the layers below it.

| Layer | Units | Role | Status |
| --- | --- | --- | --- |
| Host surface | `Wasm.Wasi.*` | WASI preview1 host; component decode and canonical ABI are post-v1 ([ADR-0014](adr/0014-the-component-model-is-deferred-to-post-v1.md)) | planned |
| Embedding API | `Wasm.Engine` | what a Pascal host calls: load, instantiate, invoke | planned |
| Runtime state | `Wasm.Runtime.Values`, `Wasm.Runtime.Traps`, `Wasm.Runtime.Memory`, `Wasm.Runtime.Store`, `Wasm.Runtime.Instantiate`, `Wasm.Runtime.Gc` | the untagged value slot; store, instances, memories, tables, globals; the memory-access chokepoint (guard-page and bounds-checked); the trap path; instantiation; the precise collector | **shipped** |
| Execution tiers | `Wasm.Exec.Interp`, `Wasm.Exec.Jit.*`, `Wasm.Exec.Aot` | three implementations of one seam | planned |
| Tier seam | `Wasm.Exec` | the contract every tier implements; trap trampoline, epoch check, safepoints | planned |
| IR | `Wasm.Ir` | register-based lowered form every tier consumes | **shipped** |
| Validation | `Wasm.Validator` | the spec's static type check, run once, emitting the IR | **shipped** |
| Module model | `Wasm.Module` | decoded module: populated entity lists, with unparsed payloads kept as spans | **shipped** |
| Decode | `Wasm.Decoder` | binary → module model | **shipped** |
| Primitives | `Wasm.Binary` | bounds-checked cursor, LEB128, little-endian reads | **shipped** |
| Vocabulary | `Wasm.Core` | value/heap/reference types, section ids and their prescribed order, tiers, error hierarchy | **shipped** |

The Decode layer is one unit in the table and five behind it:
`Wasm.Decoder` owns the preamble and the section walk, and hands each
section body to `Wasm.Decoder.Common` (the shared type-form readers),
`Wasm.Decoder.Types` (the 3.0 recursive-type grammar),
`Wasm.Decoder.Entities` (imports through tags), `Wasm.Decoder.Segments`
(element, code, data), and `Wasm.Decoder.Expr` (the expression skipper).
They are one layer — all of them sit between `Wasm.Binary` and
`Wasm.Module`.

The Validation layer is one row and four units behind it. `Wasm.Validator`
owns the module-shape rules and the order the phases run in, and delegates
to `Wasm.Validator.Types` (type-section well-formedness, recursive-group
canonicalisation, and the matching relation), `Wasm.Validator.Const`
(constant expressions), and `Wasm.Validator.Body` (the fused per-function
walk). None of them re-implements another's rule, and the validation entry
point is `ValidateModule` on `Wasm.Validator`: it takes the decoded model
plus the buffer it borrows and returns a `TWasmIrModule`. Two façade
functions cross the layer boundary on purpose: `IsStagedFeatureMessage`
(the staged-SIMD message the conformance harness keys its STAGED status on)
and `GroupMemberCount` (a rolled rec-group key's member count, which the
runtime store needs). Both are re-exported by `Wasm.Validator` so the
harness and the store read them through it rather than reaching into a
validation sub-unit whose constants are private.

`Wasm.Ir` sits below all four and depends on `Wasm.Core` alone. It is data
structures plus a disassembler, with no validation logic in it — which is
also why the IR module carries its own index-space snapshots instead of
pointing back at `TWasmModule`.

`Wasm.Wast` and `Wasm.Wast.Runner` sit beside the library rather than in
this stack: they are the conformance harness ([roadmap.md](roadmap.md),
Track C). `Wasm.Wast` is the front end — a `.wast` lexer, s-expression
parser, and command classifier that keeps module payloads as raw trees so
decoding stays lazy. `Wasm.Wast.Runner` is what turns those trees into
verdicts: it assembles each `(module binary ...)` case and runs it through
decode and validation, judging `assert_malformed`, `assert_invalid`, and
top-level `module` commands and tallying everything that needs an
execution tier as skipped. `wasmspec` is the program that points it at the
corpus.

`Wasm.Core` depends on nothing in the project. Nothing depends on
`source/apps/` — the programs are consumers of the library, never a place
for library logic.

## The rule that matters

Every WebAssembly conformance rule is enforced **below** the tier seam.

- **Decode** rejects bytes that are not a module: wrong preamble, unknown
  section id, a section longer than the module, known sections out of the
  grammar's prescribed order, a malformed LEB128, a section body the
  grammar rejects.
- **Validation** rejects modules that are not well-typed. It runs once,
  over the whole module, before any tier sees a function body.
- **Tiers** receive code already known to be well-typed. A tier's only
  freedom is how fast it produces the specified behaviour.

The consequence is worth stating plainly: three tiers are three
implementations of *speed*, not three implementations of *the spec*. A
tier that is faster because it behaves differently — including which trap
fires, and when — is a bug. This is why adding a fourth backend later is
a differential-testing exercise against the interpreter rather than a new
conformance campaign.

## Two encodings that are easy to get wrong

Both of these have already produced a bug in this codebase, so they are
recorded here rather than left to be rediscovered.

**Section ids are not the encoding order.** The spec is explicit: "Section
ids do not always correspond to the order of sections in the encoding of a
module." Two sections deviate — the data count section is id 12 but occurs
*before* the code section (id 10), deliberately, so a single-pass
validator can check `memory.init` and `data.drop` segment indices without
deferring; and the tag section is id 13 but occurs between memory (id 5)
and global (id 6). `Wasm.Core.SectionOrderPosition` holds the grammar's
order as a table, and the decoder compares positions, not ids. A rule
written on ids rejects valid modules.

**Type codes are signed LEB128 small negatives, not bytes.** `i32` is not
"the byte $7F", it is the value −1, whose single-byte sLEB128 encoding
happens to be $7F. The spec chose a signed encoding so that type codes
share an encoding space with (non-negative) type indices — which they do,
in block types and heap types. A reference type compounds this: it is
`REF NULL? ht`, a nullability flag plus a heap type that is itself either
an abstract code or a type index. The single-byte spellings are a *short
form* for the nullable-abstract case, not the whole grammar.

## Error boundaries

`Wasm.Core` defines four error classes and the distinction is
load-bearing, because a host discriminates on them:

| Class | Means | Raised by |
| --- | --- | --- |
| `EWasmDecodeError` | the bytes are not a module | decode |
| `EWasmValidationError` | it is a module, but not well-typed | validation |
| `EWasmLinkError` | imports could not be satisfied | instantiation |
| `EWasmTrap` | well-typed code failed at run time | execution |

Never collapse them, and never raise a bare `EWasmError` where a specific
one applies.

One tooling-side subclass sits outside this contract: `Wasm.Wast`
defines `EWastParseError` (under `EWasmError`) for problems in its own
`.wast` script text. A script is harness input, not a module, so it is
not part of what a host discriminates on when decoding modules.

## What is shipped today

The decode and validation path, end to end:

```text
bytes ──► TWasmReader ──► DecodeModule ──► TWasmModule
          (Wasm.Binary)   (Wasm.Decoder)   (Wasm.Module)
                                                │
                                                ▼
                                          ValidateModule ──► TWasmIrModule
                                          (Wasm.Validator)   (Wasm.Ir)
```

`TWasmReader` is a record over a raw pointer, not a class over a stream:
every byte of every module passes through it. It bounds-checks each read
and rejects malformed LEB128 — including encodings that are overlong, or
that set bits above the value's width — so nothing downstream has to
re-validate widths.

`DecodeModule` walks the section sequence, enforces the structural rules
listed above, and decodes every known section's body into the model
through the per-section decoders: types with the full 3.0 recursive-type
grammar (rec groups, sub types, func/struct/array composites), imports,
functions, tables (including the 3.0 explicit-init form), memories,
globals, exports, start, element and data segments, code entries with
their local groups and body spans, and tags. It also enforces the two
cross-section rules the module grammar itself imposes — function/code
section lengths must agree, and a data count must match the data
section. Custom sections are exempt from ordering and have their names
read through a sub-reader bounded by the declared section size, so a
name length that overruns its section cannot read into the next one.

Expressions — init expressions and offsets — carry no size prefix, so
`Wasm.Decoder.Expr` walks the full 3.0 opcode immediate table to find
where each one ends, recording the extent as a span without interpreting
anything. Function bodies are bounded by their size prefix and are
deliberately **not** instruction-walked here: the instruction grammar
inside them belongs to the fused validation walk that emits the IR
([ADR-0007](adr/0007-validation-emits-the-lowered-ir.md)).

`ValidateModule` runs that walk. It validates the type section
incrementally, canonicalising each recursive group into interned
module-local ids so that type equality is a constant-time comparison and
concrete subtyping is a lookup in a precomputed supertype display; then
imports, the function section's type uses, tables, memories, tags,
globals, element and data segments, start, and exports, in an order the
spec's own module rule fixes; then every function body. Constant
expressions are validated and lowered wherever they occur. The one staged
family is `$FD`: vector typing is Track G, and the walk raises a clear
"SIMD validation is not implemented" error rather than accepting a `v128`
instruction it has not checked.

The IR is register-based rather than stack-based
([ADR-0012](adr/0012-the-ir-is-register-based.md)): virtual registers are
assigned during the symbolic stack walk, every register carries exactly
one value type for the whole function (so
[ADR-0011](adr/0011-precise-gc-from-ir-derived-stack-maps.md)'s stack map
is a projection of that array rather than a second analysis), branches are
already resolved to instruction indices with control-flow merges
materialised as explicit moves instead of phi nodes, and loop back-edges
carry a safepoint flag so the epoch check
([ADR-0006](adr/0006-epoch-interruption-not-fuel.md)) has a fixed place to
sit. `try_table` handler and catch-clause tables are emitted from day one;
throwing arrives with Track H. Every IR module is stamped with
`IR_FORMAT_VERSION`; an ahead-of-time artifact compiled against an older
shape is rejected on it rather than misread.

**Both error classes come out of the one walk**, and which one a failure
gets is decided by the rule it broke, not by where the walk happened to be.
Binary-grammar violations inside a body are `EWasmDecodeError` — an
unassigned opcode or prefixed subopcode, a truncated immediate, a
misplaced `else`, a malformed block type, a body whose terminating `end`
is not the last byte of its span, and a body naming a data segment with no
data count section. Everything about typing is `EWasmValidationError`. The
body walk is the *first* structural pass over a function body, which is
why it is the only place a decode error can still be raised this late.

`wasmlight inspect` and `wasmlight validate` are the shipped consumers of
this path: the section table plus an entity-count summary per index space,
and decode-then-validate reporting the lowered IR.

### The runtime state below the tier seam

The runtime layer is shipped too, ahead of the tiers that will run on it.
It is everything the interpreter (Track E) will read but does not execute
a single instruction itself:

- **`Wasm.Runtime.Values`** — the 8-byte untagged value slot. A slot
  carries no discriminator; register `i`'s type is
  `TWasmIrFunction.RegTypes[i]` statically, and the collector learns which
  slots are references from `RefRegBits`, a projection of that same table
  ([ADR-0011](adr/0011-precise-gc-from-ir-derived-stack-maps.md)). Narrow
  writes zero the whole slot so a stale high half is never traced as a
  pointer.
- **`Wasm.Runtime.Store`** — the engine-wide canonical type table, the
  store, and the instance records. Validation's canonical type ids are
  module-local; the engine re-interns each rolled rec-group key so two
  structurally identical groups from different modules compare equal, and
  hands each module a remap into engine ids. This is what
  `call_indirect`, `ref.cast`, and `ref.test` check against.
- **`Wasm.Runtime.Memory`** — linear memory and the one memory-access
  chokepoint. The strategy is chosen **statically** per memory from
  (platform, address type) alone: guard pages for i32 memories on 64-bit
  POSIX, guard-assisted checks for i64 memories, explicit checks on 32-bit
  hosts and Windows
  ([ADR-0005](adr/0005-guard-page-linear-memory.md),
  [ADR-0013](adr/0013-i64-memories-take-guard-assisted-bounds-checks.md)).
  Every consumer goes through it; a caller that bypasses it is the failure
  mode this design is most exposed to.
- **`Wasm.Runtime.Traps`** — the trap vocabulary, the fault-attribution
  registry, the fault handler, and the per-invocation trampoline. A trap
  raised by the MMU inside a signal handler is attributed there and
  re-raised as `EWasmTrap` by a trampoline on ordinary ground, never out
  of the handler
  ([ADR-0009](adr/0009-traps-unwind-to-a-per-invocation-trampoline.md)).
- **`Wasm.Runtime.Instantiate`** — the constant-expression evaluator and
  the instantiation sequence, in the order `aux-rundata` fixes:
  pre-allocate function instances, evaluate initialisers allocating
  globals as it goes, then the rest of the instance.
- **`Wasm.Runtime.Gc`** — the precise, non-moving, stop-the-world
  mark-sweep collector, triggered at allocation sites only. Precise
  because validation already recorded every register's static type;
  non-moving so a host can hold a raw reference across a call with only a
  registration; single-threaded because a store is confined to one thread
  ([ADR-0008](adr/0008-a-store-is-confined-to-one-thread.md)). It carries
  the runtime subtyping check behind `ref.test` / `ref.cast` /
  `br_on_cast*`.

What is **not** built is the tier seam itself: no execution tier consumes
this state yet. The interpreter (Track E) is the next unbuilt layer, and it
consumes the IR, the store, and the GC's frame-walk contract — nothing
re-derived and no second read of the binary.

`wasmspec` is the third shipped program: it runs the `.wast` corpus through
`Wasm.Wast.Runner`, judging the binary-module subset (decode and
validation) and skipping what needs a tier. See [testing.md](testing.md)
for the measured tallies.

## Related documents

- [Roadmap](roadmap.md) — what exists and what is next
- [Code style](code-style.md) — including the hot-path RTL policy
- [Testing](testing.md) — the test tiers and the spec testsuite
- [CONTEXT.md](../CONTEXT.md) — canonical glossary
- [docs/adr/](adr/) — architectural decisions
