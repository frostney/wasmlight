# Execution is interruptible by epoch, not metered by fuel

A guest can loop forever, so the host needs a way to stop one. wasmlight
uses **epoch interruption**: the host bumps a counter, and generated or
interpreted code checks it at loop back-edges and function entries,
trapping when it has moved. The check is a load and a compare against a
value that stays in cache, so the steady-state cost is close to nothing.

Rejected: **fuel** — decrementing a counter per instruction or per block
and trapping at zero. Fuel buys determinism (the same module interrupted
at the same instruction every run), which is genuinely valuable for
reproducible sandboxing, but it puts arithmetic on every instruction, and
the whole point of the tier design is to get arithmetic off that path.
Also rejected: **no mechanism at all**, which makes the runtime unusable
for any host that executes untrusted code — the case the sandbox exists
for.

This is decided before the interpreter exists because it is the one item
in this design that is genuinely expensive to retrofit: the check has to
be emitted by the interpreter, the baseline JIT, and the AOT compiler
([ADR-0001](./0001-tiered-execution-seam.md)), so adding it later means
reopening every code generator. Cheap now, expensive later — the opposite
trade to [ADR-0005](./0005-guard-page-linear-memory.md), where the
optimisation is the thing deferred.

Consequences:

- Interruption timing is not deterministic. A host that needs
  reproducible interruption does not get it from this mechanism, and the
  documentation must say so rather than implying a guarantee.
- Back-edges and call sites are the natural place for other periodic work.
  Garbage-collection safepoints ([ADR-0004](./0004-conformance-target-is-the-3-0-draft.md))
  want the same locations, and sharing them is intended, not incidental.
