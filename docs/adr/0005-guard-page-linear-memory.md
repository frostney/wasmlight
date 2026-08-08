# Linear memory is guard-page based; explicit bounds checks are the fallback

Linear memory reserves a 4 GiB region plus a guard region and lets the MMU
catch out-of-bounds access, converting the resulting SIGSEGV (POSIX) or
structured exception (Windows) into a WebAssembly trap. A wasm memory
access therefore compiles to the load or store and nothing else — no
compare, no branch, no register pressure spent on a bound.

This is the largest single performance decision in the runtime and the
hardest to reverse, because all three execution tiers
([ADR-0001](./0001-tiered-execution-seam.md)) bake the access sequence in.
It is decided before the first tier exists for exactly that reason.

Rejected: **explicit bounds checks on every access** — portable, trivially
correct, works in a 32-bit address space, and costs a compare-and-branch
per access on the hottest path in the system. It remains the fallback
path, not a discarded option: targets that cannot reserve the address
space use it.

Consequences:

- Every tier goes through one memory-access chokepoint. Two access
  strategies are permitted only as a **platform** difference, never as a
  tier difference — the observational-identity rule in ADR-0001 is
  unaffected, and a module must trap identically under either.
- Trap delivery must work from a signal handler / SEH filter. That
  constrains the trap mechanism, which is why it is decided separately
  rather than assumed here.
- 32-bit targets cannot reserve 4 GiB. Their fate is an open decision, and
  it is a real one: the CI matrix currently includes an `i386-win32` leg.
- The signal/SEH handler is correctness-critical and sits between the OS
  and the trap semantics, so it is exercised by the conformance corpus
  rather than trusted.
