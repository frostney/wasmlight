# A WebAssembly host raises traps directly

wasmlight compiles to wasm32 with [lakon](https://github.com/frostney/lakon),
so a wasmlight embedder can itself run inside a WebAssembly runtime. On such a
WebAssembly host the trampoline transfer of
[ADR-0009](./0009-traps-unwind-to-a-per-invocation-trampoline.md) does not
exist: WebAssembly gives a module no way to capture or restore its own stack,
so there is no `setjmp`/`longjmp`. lakon's RTL declares neither, and FPC's
wasm32 RTL compiles `longjmp` to a trap of the host itself. On a WebAssembly
host (`WASM_TRAPS_RAISE`, set in `Shared.inc` for wasm CPU targets)
`TrapNow` raises the `EWasmTrap` where the trap happens, and the exception
unwinds to `WasmInvoke`, whose `try`/`finally` restores the invocation state.

This is sound because the reasons ADR-0009 avoids raising do not apply.
Nothing runs in a signal handler: a WebAssembly host has no guard pages
(`WASM_GUARD_STRATEGIES` needs a 64-bit UNIX host), so every trap comes from
an explicit check on ordinary ground. Nothing has to cross a JIT frame: a
WebAssembly host is interpreter-only, so the exception unwinds through Pascal
frames that the compiler's own unwinding finalises.

Rejected: **emulating `longjmp`** (Asyncify or an exception-based shim), which
would keep one transfer mechanism at the cost of a rewritten module or a
second unwinding scheme layered on the one the compiler already provides.
Also rejected: **leaving the transfer unimplemented**, which makes the first
guest trap abort the host.

Consequences:

- `Wasm.Runtime.Traps` keeps the trampoline and seam records. Their jump
  buffers are never jumped to on a WebAssembly host: `SetJmp` there answers
  0, and `LongJmp`, reachable only from a seam around compiled code that a
  WebAssembly host never runs, raises `EWasmInternal`.
- TRAP-1 still holds on native hosts. On a WebAssembly host it is moot: a
  raise runs the finalisation a `longjmp` would skip.
- The trap message and the exit code (134) match the native hosts, and the
  pinned conformance corpus run by a lakon-compiled `wasmspec` gives the
  native interpreter's per-file tally.
- Epoch interruption ([ADR-0006](./0006-epoch-interruption-not-fuel.md))
  still trips at the same safepoints, but a single-threaded WebAssembly host
  has no second thread to bump the epoch, so a runaway guest is not
  interrupted there.
