# The conformance target is the WebAssembly 3.0 draft, pinned

wasmlight targets the WebAssembly specification's `main` branch — the 3.0
draft — rather than the released 2.0. That brings garbage collection
(`struct`, `array`, `i31`), exception handling (the tag section and
`exnref`), and tail calls into scope as v1 requirements rather than as
future work.

The cost is not a decoding cost, and pretending otherwise is the mistake
this record exists to prevent: GC means **a garbage collector inside the
runtime**, with all the reachability, safepoint, and stack-map obligations
that implies, reaching every execution tier
([ADR-0001](./0001-tiered-execution-seam.md)) and the AOT artifact format.
Exception handling means an unwind mechanism that has to coexist with trap
delivery. These are subsystems, not opcodes.

Rejected: **Wasm 2.0**, which has a settled testsuite and is what
wasi-sdk, Rust, and TinyGo emit today, and which would have let the
runtime reach a working tier far sooner. It was rejected because the
features 3.0 adds are the ones that are structural — retrofitting a
precise GC and an unwinder through a finished interpreter and two code
generators is a rewrite, not an addition. Paying for them in the design is
cheaper than paying for them in the port.

Consequences:

- A draft moves. The target is a **pinned upstream commit**, not "latest
  main", and the pin is a deliberate, recorded bump — the same discipline
  as any dependency. `wasm-mcp` (`.mcp.json`) reports the pin it serves
  via `spec_version`, which is what makes a spec citation reproducible.
- `TWasmValueType` in `Wasm.Core` cannot stay a flat byte enum. In 3.0 a
  reference type is `REF NULL ht` — a composite of nullability and a heap
  type, drawn from `anyref`, `arrayref`, `eqref`, `exnref`, `funcref`,
  `i31ref`, `nullexnref`, `nullexternref`, `nullfuncref`, `nullref`,
  `structref`. The current two-member enum encodes a 2.0 assumption and
  must be restructured.
- The tag section (id 13) is live, not reserved.
- The conformance corpus must be pinned to a commit matching the spec pin;
  a 3.0-draft runtime judged against a 2.0 testsuite proves little.
