# Traps unwind to a per-invocation trampoline, not out of the fault handler

Guard-page memory ([ADR-0005](./0005-guard-page-linear-memory.md)) means a
trap can originate inside a POSIX signal handler or a Windows SEH filter,
raised by the MMU while guest code holds live registers. The handler does
the minimum: it records the trap and transfers control — `siglongjmp` on
POSIX, structured unwind on Windows — to a trampoline installed once per
host-to-guest invocation. The trampoline, on ordinary ground, raises the
`EWasmTrap`.

This is sound because **a WebAssembly trap is not resumable**. A trap
unwinds the entire guest activation back to the host, so there is no guest
state worth preserving across the transfer, and the usual objection to
long-jumping out of a fault is not in play.

Rejected: **raising a Pascal exception directly from the handler**, which
is not async-signal-safe and asks FPC's exception machinery to be entered
from a context it was never built for. Also rejected: **rewriting the
faulting context's program counter to a trap stub in generated code** —
what production JITs do, and the fastest option, but it needs a trap stub
and register-context surgery per tier, three times over
([ADR-0001](./0001-tiered-execution-seam.md)), for a path that by
definition runs once per failed execution.

Consequences:

- The trampoline is the single guest-entry chokepoint, so it is also where
  epoch interruption ([ADR-0006](./0006-epoch-interruption-not-fuel.md))
  surfaces and where WebAssembly exception handling
  ([ADR-0004](./0004-conformance-target-is-the-3-0-draft.md)) will hook
  in. Wasm exceptions are resumable in a way traps are not, so they need
  their own path through the same entry point — not a reuse of this one.
- The platform difference is confined to the handler and the transfer.
  Everything above sees one `EWasmTrap`.
- Every tier must be re-entrant through the trampoline; a tier that keeps
  mutable state across a guest call has to make it trampoline-safe.
