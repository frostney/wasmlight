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

**Connector**:
A declarative binding from a module import to a function exported through a
native library's C ABI. Its guest-visible name may alias a different native
entry point; custom host logic belongs in an embedder.
_Avoid_: adapter, wrapper, plugin, native module

**Connector language**:
The declaration-only language in which connectors describe data shapes,
external functions, aliases, and callbacks. It resembles C# P/Invoke but has
no general-purpose behaviour.
_Avoid_: C#, C# subset, scripting language, configuration file

**Connector plan**:
The immutable set of connector bindings selected and resolved for one compiled
executable. It contains only bindings required by that executable's imports.
_Avoid_: connector manifest, registry, dependency graph

**Runtime shell**:
The prebuilt, interpreter-free Pascal executable template (`wasmlight-shell`)
into which `wasmlight compile` embeds a validated module, complete native
code, and its connector plan. It retains validation and runtime helpers but
contains no interpreter or JIT compiler
([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md)).
The template is shipped; the compile command that populates it is not.
_Avoid_: launcher, stub, wrapper executable, bundled runtime

**Target triple**:
The architecture-vendor-os string that names a native compilation target
independently of the compiler host. The released 64-bit Unix set is
`aarch64-apple-darwin`, `aarch64-unknown-linux-gnu`, `x86_64-apple-darwin`,
and `x86_64-unknown-linux-gnu`.
_Avoid_: host triple, platform string, LLVM target

**Target ABI descriptor**:
The published pointer size, object format, calling convention, page size,
and runtime-shell layout offsets for one target triple. Artifact
fingerprints and foreign-target baked offsets come from this descriptor,
not from `SizeOf`. Host-native JIT/AOT still bake the live store so a
compiler-profile layout shift cannot crash the running binary
([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md)).
_Avoid_: host ABI, process fingerprint

**Strict compilation**:
All-or-fail ahead-of-time compilation of every defined guest function. A
successful result contains native code for each function; any predicate,
backend, range, or target decline fails with a structured non-trap error and
publishes no output. Distinct from `.waot` cache generation, which may record
declined functions for interpreter fallback
([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md)).
_Avoid_: full AOT, forced AOT, trusted compile

**Compiled capability set**:
The immutable WASI permissions and values embedded by `wasmlight compile` in a
native executable. The executable cannot expand this set at run time, and its
invocation arguments belong entirely to the guest.
_Avoid_: runtime configuration, ambient permissions, launcher options

**Entry point alias**:
A connector method whose guest-visible name differs from its native symbol.
The two signatures remain compatible after the method's declared marshalling.
_Avoid_: adapter, wrapper, function mapping

**Queued callback**:
A native callback whose copied notification is delivered later on the store's
owning thread. It has no synchronous result or borrowed-memory access.
_Avoid_: asynchronous callback, background callback, cross-thread call

**Retained callback**:
A callback whose native entry remains valid for the connector's lifetime.
Connector callbacks are retained unless their declaration marks them scoped.
_Avoid_: persistent callback, global callback, owned callback

**Deferred callback failure**:
A guest failure held at a native callback boundary and surfaced unchanged once
native execution returns. The native caller receives the result type's zero
value while the failure is pending.
_Avoid_: swallowed error, native exception, callback error code

**Scoped borrow**:
A bounds-checked view of guest memory granted to a connector only for one
synchronous host call. It cannot be retained or used across guest re-entry.
_Avoid_: raw pointer, memory pointer, shared buffer

**Opaque handle**:
A guest-visible reference that a connector resolves to a native resource
without exposing its address or representation.
_Avoid_: pointer, address, native reference

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

**Embedding ABI**:
The versioned C calling-convention surface exported by `libwasmlight`. It is
the sole foreign-language boundary over the Pascal embedding facade and uses
opaque handles, fixed-width values, explicit errors, and user-data callbacks.
_Avoid_: C API, foreign runtime, language runtime

**Language binding**:
A thin, idiomatic package that exposes the embedding ABI to one language
without reimplementing runtime behavior. First-party bindings share one
language-neutral conformance kit.
_Avoid_: runtime port, alternate engine, connector

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
