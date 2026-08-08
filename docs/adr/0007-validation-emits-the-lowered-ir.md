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
