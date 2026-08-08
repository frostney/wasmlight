# A store is confined to one thread

A store — and every instance, memory, table, and global reachable from it —
belongs to exactly one thread for its whole lifetime. wasmlight does no
internal synchronisation, and a host that wants parallelism runs several
stores rather than sharing one.

This is recorded as an explicit *no* rather than left as an unstated
assumption, because the opposite assumption is the expensive one. A store
that might be touched concurrently needs atomics or locks on the
structures the hot paths walk — memory bases, table entries, global
cells, the GC's allocation path — and that cost is paid on every access
whether or not any host actually shares a store. Confinement can be
relaxed later behind an opt-in; synchronisation, once threaded through the
runtime, cannot be taken back out.

Rejected: **a shared store with internal synchronisation**, and with it,
for now, the threads/atomics proposal and shared memories. That is a scope
decision, not a judgement that the proposal is unimportant; revisiting it
means revisiting this ADR.

Consequences:

- The garbage collector required by
  [ADR-0004](./0004-conformance-target-is-the-3-0-draft.md) is
  single-threaded, which removes concurrent marking and cross-thread
  safepoint coordination from its design.
- The embedding API can hand out raw pointers into linear memory for the
  duration of a host call without a borrow-tracking scheme.
- Violating confinement is undefined behaviour rather than a detected
  error unless a debug-build check makes it detectable. If it is worth
  detecting, that is a deliberate feature with a cost, not a free
  guarantee.
- If the threads proposal is ever adopted — post-3.0 work, and already
  flagged above as requiring this ADR's revisit — the correct shape is a
  separate, internally-synchronised shared-memory type. The shared memory
  is the only shared piece; no lock is ever added to the store itself.
  Wasmtime's split between its exclusive-access store and its dedicated
  thread-safe shared-memory type is the production template. Recording
  this now keeps the lazy alternative — sprinkling locks on the store —
  from looking acceptable later.
