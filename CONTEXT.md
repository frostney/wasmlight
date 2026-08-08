# wasmlight

A WebAssembly runtime for Object Pascal. This glossary is the project's
ubiquitous language: code, docs, issues, and commit messages use these
terms in exactly this sense. Where the WebAssembly specification defines a
term, this file records which sense wasmlight uses — it does not redefine
it.

Implementation details do not belong here. Decisions live in
[docs/adr/](docs/adr/); this is a glossary and nothing else.

## Language

### Artifacts

**Module**:
A decoded `.wasm` binary — types, functions, tables, memories, globals.
Passive: it holds no host state and no executable code, which is why one
module can feed any execution tier.
_Avoid_: binary, program, wasm file, component (a component is not a module)

**Component**:
A Component Model artifact: a WIT-described unit wrapping one or more core
modules behind typed, language-neutral interfaces.
_Avoid_: module, package, bundle

**Instance**:
A module joined to its imports and its store-side state. Instantiation is
where linking fails, distinct from decoding and validation.
_Avoid_: instantiation, runtime module, live module

**Store**:
The host-owned collection of instances and the state they reference. One
store is one isolation domain, and it is confined to one thread
([ADR-0008](docs/adr/0008-a-store-is-confined-to-one-thread.md)).
_Avoid_: context, world, universe, VM

**IR**:
The lowered representation the validation pass emits and every execution
tier consumes — pre-resolved branch targets, resolved indices, static
types for every stack slot
([ADR-0007](docs/adr/0007-validation-emits-the-lowered-ir.md)). Internal;
no compatibility promise to hosts.
_Avoid_: bytecode, opcodes, lowered form, internal format

### Execution

**Execution tier**:
One implementation of "run this function" — interpreter, baseline JIT, or
ahead-of-time. Selected per function by the runtime, never per module by
the embedder, and observationally identical across tiers, traps included
([ADR-0001](docs/adr/0001-tiered-execution-seam.md)).
_Avoid_: backend, engine, mode, JIT level

**Tier seam**:
The contract every execution tier implements, defined over the IR. The
project's central architectural boundary; the embedding API is defined
against the seam, never against a tier.
_Avoid_: interface, abstraction layer, plugin point

**Validation**:
The specification's static type check over a decoded module, run once
before any tier sees the code, emitting the IR as it goes. A module that
fails validation never reaches a tier.
_Avoid_: verification, type checking, analysis pass

**Trap**:
A run-time failure of well-typed code — out-of-bounds access, integer
divide by zero, `unreachable`. Distinct from a decode error (the bytes are
not a module) and a validation error (the module is not well-typed); the
error hierarchy in `Wasm.Core` keeps the three apart because hosts
discriminate on them.
_Avoid_: exception, error, fault, panic, crash

**Epoch interruption**:
The mechanism by which a host stops a running guest: the host advances a
counter, and guest code checks it at loop back-edges and function entries
([ADR-0006](docs/adr/0006-epoch-interruption-not-fuel.md)). Interruption
timing is not deterministic.
_Avoid_: fuel, gas, metering, timeout, watchdog

**Safepoint**:
A program point where the runtime may take control — currently the same
locations as the epoch check, and where garbage collection may run.
_Avoid_: yield point, checkpoint, GC point

**Hot path**:
Code on the per-instruction or per-byte route: the LEB128 reader, the
interpreter dispatch loop, memory access, canonical ABI lifting and
lowering. Subject to the RTL policy in
[docs/code-style.md](docs/code-style.md).
_Avoid_: fast path, critical path, inner loop

### Host boundary

**Host function**:
A Pascal routine exposed to a module as an import. The only channel
through which a guest can affect anything outside its own linear memory.
_Avoid_: native function, callback, external, syscall

**Capability**:
An explicitly granted host permission — a preopened directory, a clock, an
environment variable. Deny-by-default: a guest gets exactly what the
embedder passed it, and never obtains one by asking.
_Avoid_: permission, grant, right, privilege

**Guest**:
The WebAssembly code running inside a store. Always untrusted.
_Avoid_: client, sandbox, user code, the wasm

**Embedder**:
The Pascal program that owns a store and grants its capabilities.
_Avoid_: host application, consumer, user (a user is a person)

**Canonical ABI**:
The Component Model's rules for lowering component types onto core
WebAssembly types and linear memory.
_Avoid_: marshalling, serialization, bindings

### Verification

**Spec testsuite**:
The upstream WebAssembly conformance corpus, pinned to a commit matching
the spec pin. The external judge the project does not get to grade itself
against.
_Avoid_: conformance tests, the suite, official tests

**Pinned commit**:
The exact upstream specification revision wasmlight is conformant to.
Because the 3.0 target is a draft
([ADR-0004](docs/adr/0004-conformance-target-is-the-3-0-draft.md)), "the
spec" without a pin is not a statement anyone can check.
_Avoid_: spec version, latest spec, upstream
