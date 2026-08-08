# Three execution tiers behind one seam, selected per function

wasmlight commits to an interpreter, a baseline JIT, and an ahead-of-time
compiler, all implementing one internal contract — the **tier seam** — and
selected per function by the runtime rather than per module by the
embedder. The interpreter is the tier of record: it runs on every platform
FPC targets, needs no executable-memory permission, and is the reference
against which the other two are judged. The baseline JIT earns its keep
where a function is hot enough to repay compilation; AOT moves that cost
to build time for deployments that want native code and instant startup.

The seam is what makes three tiers affordable. Decode and validation
happen once, above every tier, so a tier receives code already known to be
well-typed and never re-derives a spec rule. A tier's only freedom is
*how fast* it produces the specified behaviour — never *what* behaviour.
Traps included: if the interpreter traps on the third iteration of a loop
and the JIT traps on the fourth, the JIT is wrong. This is the constraint
that keeps the conformance argument single-copy; without it, shipping
three tiers would mean shipping three runtimes to certify.

Rejected: **interpreter only**, which forfeits the performance target that
motivates the project. **AOT only**, which cannot instantiate a module
that arrives at run time and needs a code generator per architecture
before anything executes at all. **Tier chosen by the embedder**, which
turns an implementation detail into public API and invites hosts to
depend on tier-specific behaviour — exactly the divergence the seam
exists to forbid.

Consequences: the JIT and AOT backends are per-architecture work
(x86-64 and aarch64 first), and each new backend inherits a
differential-testing obligation against the interpreter rather than a
fresh conformance campaign. Platforms that forbid writable-executable
memory remain fully supported at interpreter speed.
