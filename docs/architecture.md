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
- Shipped today: the bottom rows of the table below. Everything else is
  staged in [roadmap.md](roadmap.md) and is described here as design, not
  as behaviour you can call.

## Layering

Read bottom-up; each layer may use only the layers below it.

| Layer | Units | Role | Status |
| --- | --- | --- | --- |
| Host surface | `Wasm.Wasi.*` | WASI preview1 host; component decode and canonical ABI are post-v1 ([ADR-0014](adr/0014-the-component-model-is-deferred-to-post-v1.md)) | planned |
| Embedding API | `Wasm.Engine` | what a Pascal host calls: load, instantiate, invoke | planned |
| Runtime state | `Wasm.Runtime`, `Wasm.Memory`, `Wasm.Gc` | store, instances, memories, tables, globals; guard-page and bounds-checked memory; the precise collector | planned |
| Execution tiers | `Wasm.Exec.Interp`, `Wasm.Exec.Jit.*`, `Wasm.Exec.Aot` | three implementations of one seam | planned |
| Tier seam | `Wasm.Exec` | the contract every tier implements; trap trampoline, epoch check, safepoints | planned |
| IR | `Wasm.Ir` | register-based lowered form every tier consumes | planned |
| Validation | `Wasm.Validate` | the spec's static type check, run once, emitting the IR | planned |
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

`Wasm.Wast` sits beside the library rather than in this stack: it is the
staged first slice of the conformance harness ([roadmap.md](roadmap.md),
Track C) — a `.wast` lexer, s-expression parser, and command classifier
with no execution and no module decoding behind it yet.

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

The decode path, end to end:

```text
bytes ──► TWasmReader ──► DecodeModule ──► TWasmModule
          (Wasm.Binary)   (Wasm.Decoder)   (Wasm.Module)
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

`wasmlight inspect` is the shipped consumer of this path: the section
table plus an entity-count summary per index space.

## Related documents

- [Roadmap](roadmap.md) — what exists and what is next
- [Code style](code-style.md) — including the hot-path RTL policy
- [Testing](testing.md) — the test tiers and the spec testsuite
- [CONTEXT.md](../CONTEXT.md) — canonical glossary
- [docs/adr/](adr/) — architectural decisions
