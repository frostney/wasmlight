# Validation emits the lowered IR that every tier consumes

The validation pass does not merely accept or reject a module — it emits a
lowered intermediate representation as it goes, and that IR is what the
interpreter, the baseline JIT, and the AOT compiler consume. No tier ever
reads the raw binary.

Validation already walks every instruction and already computes, for its
own purposes, the facts a tier would otherwise have to re-derive: the type
of every operand, the height of the operand stack at every point, and the
target of every branch. Throwing that away and making three consumers
recompute it is the waste this decision avoids. Pre-resolved branch
targets in particular take label resolution off the interpreter's hot path
entirely.

Rejected: **validation as a pure checking pass**, with tiers consuming the
raw bytes. It keeps the validator smaller and gives the IR no chance to
drift from the binary format — but it duplicates the same structural
analysis in three places, which is three places for a spec rule to be
re-derived slightly differently. That is precisely the divergence the tier
seam ([ADR-0001](./0001-tiered-execution-seam.md)) exists to forbid.

Consequences:

- The tier seam is defined over the IR, not over module bytes. This makes
  the seam concrete: a tier is a function from IR to execution.
- The IR is an internal format with no compatibility promise to hosts. It
  is, however, the input to AOT artifacts, so an artifact records the IR
  version it was compiled from and is rejected when that does not match.
- The IR carries the static type of every stack slot, which is what makes
  a **precise** garbage collector tractable under
  [ADR-0004](./0004-conformance-target-is-the-3-0-draft.md) — the runtime
  can know which slots hold references without tagging values.
- This diverges from every production runtime surveyed. None shares one
  lowered IR across interpreter and compiler tiers — the industry
  pattern is each tier re-walking validated bytecode, and
  JavaScriptCore migrated its interpreter *back* to in-place execution
  specifically to cut memory and startup. The closest kin — wasm3,
  WAMR's fast interpreter, Wasmtime's Pulley — are translate-then-
  interpret designs whose cost is measured: a translated form occupies
  roughly 2–4× the original bytecode in resident memory, against about
  +30% for in-place interpretation with a control-flow sidetable
  (Titzer, ["A fast in-place interpreter for
  WebAssembly"](https://arxiv.org/abs/2205.01183), 2022) — plus
  whole-module IR emission latency before anything executes, where a
  lazy per-function pipeline pays only for what runs.
- The decision stands despite that divergence. The single-copy
  conformance argument is load-bearing for this project in a way it is
  not for engines with large teams and fuzzer farms; the IR is the
  input to AOT artifacts regardless, so the emission path exists either
  way; and wasmlight is not a browser, so instantiation is not
  page-load-critical.
- Diverging carries a measurement obligation: `wasmbench` measures IR
  bytes per bytecode byte and instantiation latency from the first
  IR-producing milestone. The named escape hatch, adopted only if
  measurement demands it, is splitting a validate-only pass from
  per-function lazy IR emission — which would weaken "validation emits
  the IR" but never "no tier reads the raw binary".
