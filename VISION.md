# Vision

## Mission

wasmlight is a WebAssembly runtime for Object Pascal whose execution
speed rivals the C and Rust runtimes — on a fully conformant core. Fast
numbers only count on a correct implementation: passing the WebAssembly
spec testsuite, trapping exactly where the spec says to trap, and
rejecting exactly what the spec says is invalid is the baseline the
performance claim stands on, never a trade-off against it.

The conformance target is the **WebAssembly 3.0 draft**, at a pinned
upstream commit ([ADR-0004](docs/adr/0004-conformance-target-is-the-3-0-draft.md)).
That makes garbage collection, exception handling, and tail calls v1
requirements rather than future work — and garbage collection in
particular is a subsystem, not an opcode. It is the ambitious target
deliberately: retrofitting a precise collector and an unwinder through a
finished interpreter and two code generators is a rewrite, and paying for
them in the design is cheaper than paying for them in the port.

Cross-platform coverage (Linux, macOS, Windows, 32-bit and 64-bit) and
embeddability — a runtime that compiles into the host binary via lwpt,
with no runtime dependency beyond the platform it runs on — are givens of
being a serious runtime, not goals. 32-bit stays a conformant target
([ADR-0010](docs/adr/0010-32-bit-targets-are-supported-on-bounds-checks.md)):
FreePascal's reach onto smaller hosts is part of why this runtime is
written in Pascal, and a runtime that serves only modern 64-bit machines
is competing where the competition is strongest.

## Product direction

One decoded module feeds three execution tiers behind a single seam
([ADR-0001](docs/adr/0001-tiered-execution-seam.md)): an interpreter that
runs everywhere and starts instantly, a baseline JIT for code that is hot
enough to pay for compilation, and an ahead-of-time compiler for
deployments that want native code and startup cost paid at build time.
Tier selection is per function and is the runtime's decision; the
embedding API does not change when a function moves between tiers.

Beneath the tiers, three decisions define the runtime's character.
Linear memory is guard-page based, so a memory access compiles to the
access and nothing else, with explicit bounds checks as the fallback for
targets that cannot reserve the address space
([ADR-0005](docs/adr/0005-guard-page-linear-memory.md)). Execution is
interruptible by epoch rather than metered by fuel, decided before the
first tier exists because every backend has to emit the check
([ADR-0006](docs/adr/0006-epoch-interruption-not-fuel.md)). And the
collector 3.0 requires is precise, reading its stack maps out of type
information validation already computed
([ADR-0011](docs/adr/0011-precise-gc-from-ir-derived-stack-maps.md)).

Above the core sits the host surface: WASI preview1 for modules built by
today's toolchains
([ADR-0002](docs/adr/0002-wasi-p1-and-component-model.md)). The
Component Model — component decode and canonical ABI lowering — is
deferred to post-v1, deferred rather than dropped
([ADR-0014](docs/adr/0014-the-component-model-is-deferred-to-post-v1.md)).

The next product spine, not yet shipped, is native application
compilation: `wasmlight compile` produces a complete native executable
from a validated module
([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md)).
That work is sequenced in [roadmap.md](docs/roadmap.md). The `compile`
verb is registered with `--target` and `--connector`, but producing a
native executable is not shipped: the command reports structured errors
until the remaining compiler stages land. The shipped execution CLI
remains `inspect` / `validate` / `run` / `aot`.

wasmlight is a member of the lwpt ecosystem: built, tested, formatted, and
released through lwpt, and consumable by any lwpt project.

## Principles

- **Performance counts only on conformance.** A benchmark win from a
  non-strict shortcut is a loss.
- **One validated core.** Decode and validation happen once, before any
  tier sees the code. No tier re-derives a spec rule, and no tier is
  trusted to enforce one.
- **Tiers are interchangeable, not divergent.** Every tier produces
  identical observable behaviour for the same module, including traps.
  A tier that is faster because it behaves differently is a bug.
- **Hot paths avoid the RTL** when a `wasmbench` measurement justifies it
  (see [code-style.md](docs/code-style.md)).
- **The sandbox is the product.** Host capability is granted explicitly
  and denied by default; a runtime that leaks the host is not a fast
  runtime, it is a broken one.
- **Honest measurement.** Comparisons run under identical conditions in
  one environment, published with their caveats; benchmark numbers never
  become CI assertions.
- **Current truth beats aspirational documentation.** Docs describe
  shipped behaviour; planned behaviour lives in investigated issues and
  in [roadmap.md](docs/roadmap.md).
- **Exemplary lwpt citizenship.** Manifest-driven, lockfile-verified,
  committed dependency state, one toolchain entry point.

## What wasmlight is not

- **Not a compiler that produces WebAssembly modules.** Producing `.wasm`
  is another tool's job. The sibling project
  [lakon](https://github.com/frostney/lakon) compiles Object Pascal *to*
  WebAssembly — a natural counterpart, but neither project depends on
  the other. Compiling a validated module *to* a native executable is
  planned `0.2.0` work
  ([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md)),
  not a shipped command.
- **Not a browser embedding.** No JavaScript API, no DOM, no `WebAssembly`
  namespace shim. The host is a Pascal program.
- **Not a general-purpose sandbox for native code.** The isolation
  boundary is the WebAssembly semantics, not a process or VM boundary.
- **Not a JIT for anything but WebAssembly.** The compiler backends exist
  to serve the tier seam; they are not a reusable code-generation library.
- **Not a place for unvalidated fast paths.** There is no "trusted module"
  mode that skips validation.
- **Not multi-threaded inside one store.** A store belongs to one thread
  ([ADR-0008](docs/adr/0008-a-store-is-confined-to-one-thread.md)); hosts
  that want parallelism run several. The threads/atomics proposal and
  shared memories are out of scope until that ADR is revisited.
- **Not conformant to "the latest spec".** The target is a pinned commit.
  A draft that moves under an unpinned claim of conformance is not a claim
  anyone can check.

## Related documents

- [Architecture](docs/architecture.md) — the layering and the tier seam
- [Roadmap](docs/roadmap.md) — what is shipped and what is next
- [Code style](docs/code-style.md) — including the hot-path RTL policy
- [CONTEXT.md](CONTEXT.md) — canonical glossary
- [docs/adr/](docs/adr/) — architectural decisions, including the planned
  native-compiler contract
  ([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md))
