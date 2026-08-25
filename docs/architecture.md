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
  instantiation, the precise collector), and **all three execution tiers**
  over that IR — the interpreter (Track E), the baseline JIT (Track I), and
  the AOT compiler (Track J) — each executing the full `v128` vector set
  (Track G) and exception handling (Track H), so **all of core wasm 3.0
  executes** and does so identically in every tier. Around that core: the
  wat text-format assembler, the `.wast` runner that assembles, decodes,
  validates, instantiates, and executes over the whole corpus, and the
  embedding API (`Wasm.Engine`) and WASI preview1 host surface
  (`Wasm.Wasi.*`) that run that core as real programs, deny-by-default,
  from a Pascal host or from `wasmlight run` (Track F). The JIT and AOT are
  a 64-bit-UNIX acceleration (two backends, aarch64 and x86-64); on Windows
  and 32-bit targets the runtime is interpreter-only and still fully
  conformant.   [roadmap.md](roadmap.md) is the honest picture of what
  remains: the planned native-compiler spine
  ([ADR-0015](adr/0015-strict-native-compiler-and-runtime-shell.md)),
  broader optimizing-compiler work, and later platform and host-surface
  releases. Nothing in v1 Core 3 behaviour is staged.

## Layering

Read bottom-up; each layer may use only the layers below it.

| Layer | Units | Role | Status |
| --- | --- | --- | --- |
| Host surface | `Wasm.Wasi.*`, `Wasm.Run` | deny-by-default WASI preview1 host and the `wasmlight run` driver; component decode and canonical ABI are post-v1 ([ADR-0014](adr/0014-the-component-model-is-deferred-to-post-v1.md)) | **shipped** |
| Embedding API | `Wasm.Engine` | what a Pascal host calls: load, link, instantiate, invoke, memory, host roots | **shipped** |
| Runtime state | `Wasm.Runtime.Values`, `Wasm.Runtime.Traps`, `Wasm.Runtime.Memory`, `Wasm.Runtime.Store`, `Wasm.Runtime.Instantiate`, `Wasm.Runtime.Gc` | the untagged value slot; store, instances, memories, tables, globals; the memory-access chokepoint (guard-page and bounds-checked); the trap path; instantiation; the precise collector | **shipped** |
| Execution tiers | `Wasm.Interp` (+ `Wasm.Interp.Numeric`, `Wasm.Interp.Vector`); baseline JIT (`Wasm.Jit`, `Wasm.Jit.CodeBuffer`, `Wasm.Jit.Arm64`, `Wasm.Jit.X64`); AOT (`Wasm.Aot`, `Wasm.Aot.Artifact`) | three implementations of one seam — the interpreter is the tier of record; JIT/AOT accelerate a 64-bit UNIX host | interpreter **shipped** (every platform); JIT + AOT **shipped** (64-bit UNIX, two backends) |
| Tier seam | the trampoline in `Wasm.Runtime.Traps` + the IR's safepoint flags | the contract every tier implements; trap trampoline, epoch check, safepoints | **shipped** (the interpreter honours it) |
| IR | `Wasm.Ir` | register-based lowered form every tier consumes | **shipped** |
| Validation | `Wasm.Validator` | the spec's static type check, run once, emitting the IR | **shipped** |
| Module model | `Wasm.Module` | decoded module: populated entity lists, with unparsed payloads kept as spans | **shipped** |
| Decode | `Wasm.Decoder` | binary → module model | **shipped** |
| Primitives | `Wasm.Binary` | bounds-checked cursor, LEB128, little-endian reads | **shipped** |
| Native target | `Wasm.Target` | host-independent 64-bit Unix triples and ABI descriptors ([ADR-0015](adr/0015-strict-native-compiler-and-runtime-shell.md)); staging and fingerprints consume a requested target, executable memory stays host-gated, and foreign-ISA backends remain compile-time | **shipped** |
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
plus the buffer it borrows and returns a `TWasmIrModule`. One façade
function crosses the layer boundary on purpose: `GroupMemberCount` (a
rolled rec-group key's member count, which the runtime store needs),
re-exported by `Wasm.Validator` so the store reads it through the layer
rather than reaching into a validation sub-unit whose constants are
private. (The conformance harness no longer records any `STAGED` case:
Track H shipped throwing, which was the last thing `Wasm.Wast.Runner`
keyed that status on, and the staged-SIMD message before it is gone too.)

`Wasm.Ir` sits below all four and depends on `Wasm.Core` alone. It is data
structures plus a disassembler, with no validation logic in it — which is
also why the IR module carries its own index-space snapshots instead of
pointing back at `TWasmModule`.

`Wasm.Wast`, `Wasm.Wast.Values`, `Wasm.Wast.Runner`, and the six
`Wasm.Wat.*` units sit beside the library rather than in this stack: they
are the conformance harness ([roadmap.md](roadmap.md), Track C).
`Wasm.Wast` is the front end — a `.wast` lexer, s-expression parser, and
command classifier that keeps module payloads as raw trees so decoding
stays lazy — and `Wasm.Wast.Values` parses assertion arguments and
expected results. The `Wasm.Wat.*` units are the **text-format
assembler**: a strict tokenizer, a numeric-literal parser, an
identifier/label resolver, an opcode table, and a binary emitter, driven
by `Wasm.Wat.Assembler`, which lowers module text and `(module quote ...)`
to bytes. Those bytes re-enter the *same* shipped
`DecodeModule → ValidateModule → instantiate → interpret` path a binary
module takes — the assembler is a producer of bytes, never a second
decoder or a second validator, so it is a clean inverse of the decode
stack and shares none of the runtime path. `Wasm.Wast.Runner` turns the
command trees into verdicts: it assembles or decodes each module,
validates and instantiates it, and *executes* `assert_return`,
`assert_trap`, `invoke`, and `assert_exhaustion` through the interpreter,
prefix-matching messages and comparing results. `wasmspec` is the program
that points it at the corpus.

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
| `EWasmException` | a wasm `throw` escaped uncaught | execution |

Never collapse them, and never raise a bare `EWasmError` where a specific
one applies.

A fifth class, `EWasmExit`, is declared in `Wasm.Engine` rather than
`Wasm.Core`, because a clean exit is a host-surface concept, not a guest
fault. It is what WASI `proc_exit(n)` raises: a request to stop, carrying
the exit code, propagated unchanged through the invocation trampoline. It
is an `EWasmError` subtype so the trampoline carries it out, but a distinct
sibling — neither a trap nor a `throw` — so a host classifies it exactly;
`wasmlight run` maps it to the process exit code and everything else is an
error.

`EWasmException` is a **sibling of `EWasmTrap`, not a subclass** — both
under `EWasmError`, but a host discriminates between a trap and an escaped
exception. It is the exception route made distinct from the trap route:
the interpreter unwinds `throw` / `throw_ref` over its own activation
stack, and only a throw that matches no handler in any frame becomes
`EWasmException`, reaching the trampoline on its own path
([ADR-0009](adr/0009-traps-unwind-to-a-per-invocation-trampoline.md)). A
caught throw never surfaces as any error class.

Two tooling-side subclasses sit outside this contract, both under
`EWasmError` and neither part of what a host discriminates on when
decoding modules. `Wasm.Wast` defines `EWastParseError` for problems in
its own `.wast` script text. And `Wasm.Core` defines `EWasmTextError` (a
sibling of the four, carrying `Line`/`Column`) for malformed *text-format*
source, raised by the wat assembler with upstream's canonical prefixes: a
`.wat` module that will not assemble is a text error, not a bad module.
`assert_malformed` over a text operand keys on this class where over a
binary operand it keys on `EWasmDecodeError`.

## What is shipped today

The path from bytes — or from text — to a running module, end to end:

```text
text ──► AssembleWat ──┐
         (Wasm.Wat.*)  │  (harness-side front door; produces bytes only)
                       ▼
bytes ─► TWasmReader ─► DecodeModule ─► TWasmModule
         (Wasm.Binary)  (Wasm.Decoder)  (Wasm.Module)
                                            │
                                            ▼
                                      ValidateModule ─► TWasmIrModule
                                      (Wasm.Validator)  (Wasm.Ir)
                                            │
                                            ▼
                                      InstantiateModule ─► TWasmInstance
                                      (Wasm.Runtime.Instantiate)
                                            │
                                            ▼
                                      InterpInvoke ─► results / EWasmTrap
                                      (Wasm.Interp)
```

The text front door is the wat assembler and belongs to the conformance
harness, not the runtime: it converts `.wat` source to bytes and hands
them to `DecodeModule` like any other module, so text modules and binary
modules share one decode/validate/instantiate/execute path from that point
on. Everything below the `bytes` row is the shipped runtime.

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
expressions are validated and lowered wherever they occur — including
`v128.const`, which is a constant instruction in the spec. The `$FD`
vector space is fully typed (Track G): every `v128` operand and result is
checked, lane immediates are bounds-checked against the shape, and a
mismatch is the ordinary `type mismatch`.

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
sit. A `v128` value occupies **two adjacent register slots** (low half
first, low slot always even and 16-byte aligned), and since neither slot
is ever a reference the GC stack map leaves both clear. `try_table`
handler and catch-clause tables are emitted from day one, and the
interpreter now executes the throwing they describe (Track H). Every IR
module is stamped with `IR_FORMAT_VERSION`, still **2** — it was 1 before
Track G appended the vector ops, and Track H moved it no further because
the handler tables were already in the IR; an ahead-of-time artifact
compiled against an older shape is rejected on it rather than misread.

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

The runtime layer sits below the tier seam. It is everything the
interpreter (Track E) reads but that executes no instruction itself:

- **`Wasm.Runtime.Values`** — the 8-byte untagged value slot. A slot
  carries no discriminator; register `i`'s type is
  `TWasmIrFunction.RegTypes[i]` statically, and the collector learns which
  slots are references from `RefRegBits`, a projection of that same table
  ([ADR-0011](adr/0011-precise-gc-from-ir-derived-stack-maps.md)). Narrow
  writes zero the whole slot so a stale high half is never traced as a
  pointer. A `v128` value spans two adjacent slots (Track G) — the low slot
  even and 16-byte aligned — and neither is ever a reference.
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

### The interpreter over the seam

`Wasm.Interp` (with the numeric leaf functions in `Wasm.Interp.Numeric`
and the vector leaf functions in `Wasm.Interp.Vector`) is the first tier
over the seam and the tier of record. It consumes the IR, the store, and
the GC's frame-walk contract — nothing re-derived and no second read of
the binary. Its activation stack is explicit, so a self-tail-recursive
loop runs in bounded Pascal stack (`return_call` replaces the top frame in
place), and each frame's register file is zeroed at entry so the collector
never traces a stale slot. It runs inside the per-invocation trampoline: a
spec trap long-jumps to the trampoline and re-raises as `EWasmTrap`, never
out of a signal handler. `Wasm.Interp.Vector` executes the `$FD` space
(Track G) with bit-exact per-lane operators — relaxed SIMD on the
deterministic profile (R=0). Exception handling (Track H) executes here
too: `throw` / `throw_ref` / `try_table` unwind over the same activation
stack, matching each frame's handler table by tag store-address, and an
uncaught throw raises `EWasmException` — the exception route, distinct
from the trap route. Every instruction the register IR emits dispatches
here; nothing is staged.

### The compiling tiers over the seam

Two more tiers sit over the same seam, both differentially proven
byte-identical to the interpreter — the seam's whole point
([ADR-0001](adr/0001-tiered-execution-seam.md)): a tier is faster, never
different.

- **The baseline JIT** (`Wasm.Jit` driver, `Wasm.Jit.CodeBuffer` W^X code
  buffer, and the two backends `Wasm.Jit.Arm64` / `Wasm.Jit.X64`) compiles
  a function to native code the first time it runs. JIT staging and AOT
  consume a requested `Wasm.Target` for arch stamps, fingerprints, and
  published foreign-target offsets; executable-memory allocation, native
  invocation, and ISA selection stay host-gated (`JitCompileToBuffer`
  remains host-ifdef'd, so foreign-ISA byte emission is still declined).
  The design choice that
  makes it cheap: the compiled frame *is* the interpreter's frame, so the
  GC stack map, the tail-call frame replacement, and stack-exhaustion
  handling are inherited rather than re-derived. It emits the epoch check
  at every back-edge and keeps live references discoverable, honouring the
  same safepoint obligations as the interpreter. It carries the full
  non-EH op set; a function that throws or hosts a `try_table` handler is
  declined and stays interpreted, and compiled and interpreted functions
  interoperate transparently across the seam (a throw from a compiled
  callee reaches an outer interpreted handler, and a cross-tier tail call
  stays O(1)).
- **The AOT compiler** (`Wasm.Aot`, `Wasm.Aot.Artifact`) runs the same
  backends ahead of time, emitting **position-independent** code — helper
  calls go through a per-process indirect table and the IR base arrives in
  a pinned register, so nothing absolute is baked — and serializes it to a
  `.waot` artifact. Target architecture and ABI fingerprints come from the
  selected `Wasm.Target` descriptor, not from host CPU/OS defines; host-
  native emission still bakes the live store so release and debug binaries
  cannot miscompile themselves, while a requested foreign target consumes
  the published descriptor. `run --aot` still loads only a host-arch,
  host-ABI artifact and maps it executable through the host-gated code
  buffer. The **security
  invariant**: AOT always re-decodes and re-validates the module, and the
  artifact's code is used only if its magic, AOT version, IR version,
  target arch, ABI fingerprint, module hash, and self-checksum all match
  the freshly validated module — otherwise the run falls back to the
  interpreter. The artifact is a per-module perf cache bound by hash,
  never a trust bypass.

Both compiling tiers run only where `WASM_JIT_EXEC` holds — a **64-bit
UNIX host**. On Windows and 32-bit targets they are inactive and the
interpreter, the tier of record, runs alone; that leg is unaccelerated but
fully conformant. The compiling tiers include measured native fast paths
without changing that seam: conservative machine-register allocation for
helper-free numeric loops, scalar memory access inlined according to the
memory chokepoint's selected strategy, native scalar-numeric and integer-SIMD
subsets, compare/branch fusion, and redundant-move folding. Helper-free numeric
loops keep two allocated values and four expression temporaries in machine
registers across epoch-only back-edges; the epoch check still runs, and exits
restore the canonical frame. On aarch64, a function that addresses one static
memory pins that memory instance once at entry while every access still loads
its live base and required size. A narrower helper-free shape with only
zero-offset i32 guard-page accesses and no call or `memory.grow` pins the stable
base itself and retains cached operands across accesses. Compiled frame entry
clears the validation-computed set of semantic local and reference slots, not
definition-dominated numeric temporaries. Direct compiled calls reuse resolved
function metadata and specialize their normal result gather and frame pop; no
Pascal helper frame spans the native callee. Delicate or unsupported operations
continue through the exact shared helpers. The code-generation plan is a side
table over the validated IR, so no optimization rewrites or re-validates it.

`wasmspec` is the third shipped program: it runs the `.wast` corpus through
`Wasm.Wast.Runner`, which assembles text modules, decodes, validates,
instantiates, and executes assertions through the interpreter — SIMD judged
per lane and `assert_exception` judged (Track H), so the `staged` column is
0. It also supplies the standard `spectest` host, judges
`assert_unlinkable`, and executes module definitions/instances; the pinned
core scripts have no failures or skips. See [testing.md](testing.md) for the
measured tallies and the separately classified recursive residue.

### The embedding API and the host surface

Above the runtime sits the layer a host actually calls (Track F). It adds
no runtime logic — every entry point delegates to a shipped procedure —
but it is where the runtime becomes reachable and where the capability
boundary is drawn.

- **`Wasm.Engine`** is the facade: load (decode + validate), link through
  the typed `TWasmLinker`, instantiate, call, and read/write guest memory.
  Two invariants are enforced here rather than merely inherited. The
  **capability boundary is explicit** — a host import reaches the guest
  only if the linker defines it; an undefined import is absent, so
  instantiation fails with `EWasmLinkError`, and there is no ambient
  fallback. And **memory stays behind the chokepoint** — reads and writes
  route to the store's range check with an overflow-safe pre-check, so the
  facade never sees a memory's base pointer. It re-exports the collector's
  host-root API (contract HOST-1) so a host holding a reference across an
  allocation can root it, and declares `EWasmExit`.
- **`Wasm.Wasi.*`** is the deny-by-default host module, wired entirely over
  `Wasm.Engine`. The capability model is the point: a bare config grants
  stdio + clock + random and nothing else — no environment, no filesystem,
  argv only as set, **no ambient authority**. Preopened directories are the
  only route to the filesystem, and the memory chokepoint plus preopen
  containment together form the sandbox boundary — every guest pointer is
  bounds-checked through the store, and every filesystem path is contained
  to the preopen it derives from, so an absolute path, a `..` escape, or an
  escaping symlink is `ENOTCAPABLE` before any OS call. The clock, entropy
  (a real platform CSPRNG), and filesystem seams are injectable, which is
  what makes the host module hermetically testable.
- **`Wasm.Run`** is the driver behind `wasmlight run`: decode + validate a
  WASI command, link it against the granted surface, run `_start`, and map
  the outcome to a process exit code — `EWasmExit` to its code, a trap to
  134, an uncaught exception to 1, a decode/validate/link failure to 1. It
  is factored out of the program entry point so it is unit-testable with
  injected streams, never touching real stdio.

## Related documents

- [Roadmap](roadmap.md) — what exists and what is next
- [Code style](code-style.md) — including the hot-path RTL policy
- [Testing](testing.md) — the test tiers and the spec testsuite
- [CONTEXT.md](../CONTEXT.md) — canonical glossary
- [docs/adr/](adr/) — architectural decisions
