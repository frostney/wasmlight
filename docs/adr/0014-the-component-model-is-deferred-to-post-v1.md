# The Component Model is deferred to post-v1

v1's host surface is **WASI preview1 only**. Component decoding and
canonical ABI lowering — the Component Model half of
[ADR-0002](./0002-wasi-p1-and-component-model.md), which this record
supersedes — move to post-v1. Deferred, not dropped: the direction
ADR-0002 pointed at is still real; its timing was wrong. The
deny-by-default capability model of ADR-0002 carries forward unchanged —
no ambient filesystem, clock, environment, or network; a capability is a
value the host hands over, with preopens as the pattern. That part of
the decision was never in question.

The assessment, as of August 2026: the Component Model remains a phase 1
CG proposal specified out-of-band in
[WebAssembly/component-model](https://github.com/WebAssembly/component-model),
with no formal spec, no reference interpreter, no browser-engine
implementation, and effectively one runtime implementation (Wasmtime,
plus the jco transpiler). The published
[1.0 roadmap](https://bytecodealliance.org/articles/the-road-to-component-model-1-0)
announces a breaking canonical-ABI rework — lazy lowering replacing
`cabi_realloc`, multivalue returns — so a canonical ABI faithfully
implemented today is scheduled to be obsoleted before 1.0, and WASI 1.0
is explicitly gated behind Component Model 1.0 with no date. Every peer
independent runtime (wazero, WAMR, Wasmer) has stayed core + preview1.
Meanwhile preview1 — frozen upstream, but universally emitted by
wasi-sdk's default lineage, Zig, Go, CPython, and Rust's lowest-friction
target — is exactly what makes the runtime useful the day the
interpreter lands, and wasi-testsuite covers preview1 today, so the v1
surface is verifiable now. Deferring also cures a contradiction: the
project's own conformance rule
([ADR-0004](./0004-conformance-target-is-the-3-0-draft.md): a claim must
be checkable against a pinned target) is one the Component Model cannot
yet meet.

The re-entry condition is a condition, not a date. The Component Model
returns to scope by a new ADR once (a) the post-rework canonical ABI has
landed and (b) the component-model reference test suite
(`WebAssembly/component-model/test`) covers it. At that point it needs
its own conformance corpus wired up — nothing in the core spec testsuite
exercises components.

Rejected: **keeping it in v1**, which builds against an ABI scheduled to
break and cannot be verified against the project's own Definition of
Ready. **Dropping it entirely** — the component-native ecosystem
(wasmCloud, Spin, Fastly) and Rust's tier-2 wasip2 target are real, and
the fence in [VISION.md](../../VISION.md) should not close against it.

Consequences:

- [ADR-0002](./0002-wasi-p1-and-component-model.md) is superseded by
  this ADR; its WASI preview1 half and its capability model continue
  here.
- "Module" and "component" remain distinct vocabulary in
  [CONTEXT.md](../../CONTEXT.md), so the deferral does not blur terms.
- The embedding track's scope (`Wasm.Engine`, `wasmlight run`) is
  preview1 only for v1.
- When components return, the canonical ABI's lifting and lowering
  remain hot-path code under the RTL policy in
  [code-style.md](../code-style.md).
