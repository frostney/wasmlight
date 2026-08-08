# i64 memories take guard-assisted bounds checks

The memory-access strategy is selected statically, per memory, from the
memory's address type — the 3.0 `addrtype` that parameterises its limits
— never dynamically and never per tier. i32-addressed memories keep what
is already decided: guard pages on 64-bit hosts
([ADR-0005](./0005-guard-page-linear-memory.md)) and explicit bounds
checks on 32-bit hosts
([ADR-0010](./0010-32-bit-targets-are-supported-on-bounds-checks.md)),
unchanged.

An i64-addressed memory can address more than any reservation covers, so
no guard region can make its checks disappear; every access carries an
explicit bounds check. On 64-bit hosts that check is **guard-assisted**:
the runtime reserves the memory's current size plus a guard region, so
any static offset no larger than the guard folds into an
offset-independent compare of the index against the bound — one
deduplicable check can cover many accesses through the same base. On
32-bit hosts i64 memories take the plain explicit check, prefixed by an
index-width reduction: trap if the high 32 bits of the i64 index are
nonzero, then check the low half.

| | 64-bit host | 32-bit host |
| --- | --- | --- |
| i32 memory | guard pages, no check | explicit checks |
| i64 memory | guard-assisted explicit checks | explicit checks + index-width reduction |

This ADR fixes only the invariants: the strategy is chosen per memory,
statically, from the address type; every access still goes through the
single chokepoint of ADR-0005; static offsets no larger than the guard
fold into an offset-independent compare; and all strategies trap
identically — a module traps at the same access under every strategy and
every tier ([ADR-0001](./0001-tiered-execution-seam.md)). Guard size,
reservation policy (including whether growth remaps), and the offset
threshold above which an access gets a full-precision check are
implementation constants tuned by `wasmbench` measurements, deliberately
not pinned here.

The evidence points one way. Every surveyed production engine —
Wasmtime, V8, SpiderMonkey, WAMR — selects the strategy statically per
memory from the index type, and none elides the check for
64-bit-addressed memories; each emits at least one compare. SpiderMonkey
measured the cost of plain checks at 10% to over 100% depending on
workload
(<https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html>).
The guard-assisted shape is Wasmtime's: offsets up to the guard size are
absorbed by the guard region.

Rejected: **plain unassisted checks as the committed endpoint** —
correct and simpler, but it leaves the measured hot-loop cost on the
table, and getting arithmetic off that path is the tier design's central
purpose. It remains the natural first implementation stage, not the
destination. Also rejected: **an implementation-defined maximum for i64
memories with a constant-bound compare** — V8's shape, 16 GiB, matching
the JS-API embedder cap. It is the cheapest check, but wasmlight is not
a JS embedding, and an embedder-visible size cap is a public-contract
decision that must not ride in on a bounds-check optimisation. Also
rejected: **dynamic strategy selection** by declared maximum or by
whether a reservation succeeded — it makes the emitted access sequence
depend on runtime state, which breaks AOT artifacts that bake the
sequence from the module alone, and no surveyed engine does it.

Consequences:

- The strategy matrix is decidable from (platform, memory's address
  type) alone, so every tier — and an AOT artifact — can emit the access
  sequence with no runtime knowledge.
- The bounds-check path stops being a 32-bit-only concern. It is
  hot-path code on 64-bit hosts too, and `wasmbench` must measure it.
- Growth of an i64 memory may remap. The bound is loaded from the
  instance, so a moved memory is transparent to the check.
- Speculative-execution hardening of the check's branch (for example a
  conditional move to a poisoned address, Wasmtime's shape) is a JIT/AOT
  code-generation concern explicitly assigned to the baseline-JIT
  track's future ADR — recorded here so Track I inherits it in writing,
  not silently.
