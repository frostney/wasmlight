# Garbage collection is precise, using stack maps derived from the IR

The collector required by the 3.0 target
([ADR-0004](./0004-conformance-target-is-the-3-0-draft.md)) is a precise
tracing collector. It knows exactly which slots hold references, because
the IR already records the static type of every one
([ADR-0007](./0007-validation-emits-the-lowered-ir.md)) — the stack map is
a projection of information validation computed anyway, not a second
analysis bolted on afterwards.

Two decisions already taken make this the cheap option rather than the
expensive one. WebAssembly is statically typed, so precision costs no
runtime tagging and no reserved bits in values. And a store is confined to
one thread ([ADR-0008](./0008-a-store-is-confined-to-one-thread.md)), so
there is no concurrent marking, no write barrier for cross-thread
visibility, and no cross-thread safepoint coordination to design.

Rejected: **conservative stack scanning**, which needs no maps and is the
usual choice when type information is unavailable — but it retains
garbage by accident, makes leaks depend on stack residue, and fights a
JIT's register allocator, which is free to keep the only reference to an
object somewhere the scanner cannot see. Also rejected: **reference
counting**, which cannot collect cycles; WebAssembly GC object graphs form
them freely, so this is a correctness failure, not a performance one.

Consequences:

- Every tier must be able to produce a stack map at a safepoint. That is
  an obligation on the baseline JIT and the AOT compiler, not only on the
  interpreter, and it constrains their register allocation: a live
  reference must be discoverable.
- Safepoints are the epoch-check locations from
  [ADR-0006](./0006-epoch-interruption-not-fuel.md) — loop back-edges and
  function entries. Sharing them is deliberate.
- Host code holding a reference across a call that can allocate needs a
  root registration mechanism; raw Pascal pointers into the GC heap are
  not roots the collector can see.
