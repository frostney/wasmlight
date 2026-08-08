# A decoded module borrows the caller's bytes; sections are offsets

`TWasmModule` records each section as an offset and length into the
buffer it was decoded from, and copies nothing. Decoding is therefore
proportional to a module's section count rather than its size, and an
execution tier reads a function body straight out of the embedder's
bytes — no second copy of the code, and no per-section allocation on the
instantiation path.

The cost is a lifetime rule, and it is a real one: the buffer must outlive
the module. `DecodeModuleFile` returns the bytes it read as an `out`
parameter for exactly this reason — so the caller is handed the thing it
must keep alive instead of discovering the requirement through a crash.
The same rule governs `TWasmReader`, which borrows rather than owns; the
existing unit suites keep their byte buffers in a suite field for this
reason, not as a style preference.

Rejected: **copying each section body into the module**, which doubles
peak memory for a large module and adds an allocation per section to a
path that should be close to free. **Reference-counting the buffer inside
the module**, which makes the model own host memory, complicates handing
the same bytes to two stores, and hides a lifetime question rather than
answering it.

Consequences: memory-mapping a `.wasm` file is a natural later
optimisation, since nothing in the model assumes the bytes are on the
heap. Any future API that returns a module while dropping its buffer is a
bug. The borrow contract is invisible to the Pascal compiler — no borrow
checker exists to catch an embedder freeing the buffer under a live
module — so documentation is the only line of defence: the lifetime rule
must appear in the doc comment of every entry point that produces a
module, not merely somewhere in the docs. The contract has production
precedent: WAMR's embedder API holds the caller's buffer for the module's
whole life and pairs the rule with an explicit "is the underlying binary
freeable" query. When wasmlight's embedding API lands, an equivalent
query is the honest way to make the contract checkable at run time rather
than by crash.
