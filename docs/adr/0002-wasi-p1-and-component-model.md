# The host surface is WASI preview1 plus the Component Model

wasmlight targets both host-interface generations: **WASI preview1**,
because it is what today's toolchains actually emit and what makes the
runtime useful the day the interpreter lands, and the **Component
Model** — component decoding plus canonical ABI lowering — because that
is where the ecosystem's typed, language-neutral interfaces are going.
Neither is a migration away from the other: preview1 modules keep
running, and components are decoded into the core modules they wrap and
executed by the same tiers.

Both surfaces sit above the tier seam
([ADR-0001](./0001-tiered-execution-seam.md)) and reach the guest only as
imports. There is no host capability a module can obtain except one the
embedder passed in — no ambient filesystem, clock, environment, or
network. Preopened directories are the model for everything: a capability
is a value the host hands over, not a permission the guest requests.

Rejected: **core WebAssembly only**, leaving every embedder to hand-roll
WASI — which multiplies the sandbox-critical surface across hosts, and
puts the security-relevant code in the place least likely to be reviewed.
**preview1 only**, which dates the runtime against the direction the
ecosystem has already taken. **Component Model only**, which would refuse
the modules that exist today.

Consequences: the host surface is a large fraction of total scope, and it
is where sandbox escapes would live, so it carries the deny-by-default
constraint in AGENTS.md as a hard rule rather than a guideline. The
canonical ABI's lifting and lowering are hot-path code and fall under the
RTL policy in [code-style.md](../code-style.md). "Module" and "component"
stay distinct terms throughout the codebase
([CONTEXT.md](../../CONTEXT.md)).
