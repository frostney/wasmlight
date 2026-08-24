# Strict native compilation uses an interpreter-free runtime shell

`wasmlight compile` is the next product spine: it validates a module once,
compiles every guest function, and fails with a structured diagnostic if any
function cannot be compiled. The output is a complete native executable
assembled from a prebuilt, interpreter-free Pascal runtime shell. It embeds
the original module for startup revalidation, the complete native code, the
resolved connector plan, and an immutable compiled capability set. The
executable retains validation, runtime helpers, memory protection, traps,
exceptions, epoch interruption, GC, WASI, and connector support. It contains
neither the interpreter nor the JIT compiler.

This is a different artifact from the shipped `.waot` cache
([ADR-0001](./0001-tiered-execution-seam.md)). A `.waot` file is a
per-module performance cache: load always re-decodes and re-validates, and a
declined function stays interpreted. A compiled executable has no such
fallback. The cache path remains for `wasmlight run --aot`. The compile path
is all-or-fail.

Cross-compilation is part of the same decision. Target architecture, ABI
descriptors, and shell templates are independent of the compiler host. Every
shipped compiler emits every released target through `--target`, which
defaults to the host. The first released target set is AArch64 and x86-64 on
macOS and Linux. Win64 and i386 Windows follow as later releases. ARM32 and
i386 Linux are out of scope. Executable-memory allocation and native
execution stay host-gated; byte emission does not.

Connectors are declaration-only `.wlc` bindings, not Pascal or C source and
not a C# compiler. `[DllImport]` selects an application-local dynamic
library; `EntryPoint` aliases a native symbol. Memory crosses the existing
chokepoint as copy-in, copy-out, inout, or a scoped synchronous borrow.
Persistent resources use opaque handles. Guest failures never unwind through
native C frames: the connector returns a zero value, retains the exact
failure, and rethrows it on Pascal ground. Selection is explicit
(`--connector`), unique, deny-by-default, stripped to used declarations, and
embedded immutably.

WASI configuration belongs to compile time. Generated programs expose no
Wasmlight runtime flags; every invocation argument belongs to the guest.
Relative preopened host paths resolve from the executable directory;
absolute paths remain literal. Environment values are embedded literally and
are not a secret mechanism.

Rejected: **linking through a host C compiler, Zig, or SDK**, which is the
Wasmer `create-exe` shape and requires a toolchain the Pascal embedder does
not have. **TinyCC, libffi, or per-connector source compilation**, which
imports another compiler and a second ABI planner. **Keeping the interpreter
in the generated executable as a decline fallback**, which makes
"interpreter-free" untrue and hides incomplete AOT. **Searching ambient
loader paths** for connector libraries, which widens host capability past
the deny-by-default boundary. **Skipping startup revalidation because the
artifact is local**, which would turn the payload into a trust boundary.
**Choosing the target from host CPU/OS defines**, which prevents one
compiler binary from emitting another supported target.

Consequences:

- Implementation issues cite this ADR for the compile contract, shell,
  payload, target descriptors, connector plan, and compiled capability set
  instead of redefining them.
- Validation remains the single pre-tier specification gate. Generated
  executables stay observationally identical to the interpreter on the
  pinned Core 3 corpus.
- The error hierarchy, memory chokepoint, store-thread rule
  ([ADR-0008](./0008-a-store-is-confined-to-one-thread.md)), and
  deny-by-default host boundary remain intact.
- `VISION.md`'s "not a WebAssembly compiler" fence still means wasmlight
  does not produce `.wasm` modules. Compiling a validated module to a native
  executable is planned product work, recorded here and sequenced in
  [roadmap.md](../roadmap.md), not shipped behaviour.
