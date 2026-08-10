# Handoff

Updated: 2026-08-09 (Track F — embedding API + WASI preview1)

## Current state — CORE 3.0 COMPLETE + RUNS REAL WASI PROGRAMS

- **Tracks A, B, C, D, E, F, G, H delivered.** The runtime decodes,
  validates, instantiates, and executes the COMPLETE core wasm 3.0
  instruction set, AND runs real WASI preview1 programs via
  `wasmlight run` with a deny-by-default sandbox.
- Gates on the merged tree: `lwpt format`, `lwpt build`, `lwpt test`
  (38 suites, ~1,044 tests), `lwpt install --frozen` — all green. Docs
  markdownlint-clean.
- `./build/wasmlight run tests/fixtures/wasi/hello.wasm` → prints hello,
  exit 0. proc_exit(n)→n, trap→134, uncaught exception→1.
- Core corpus (WebAssembly/testsuite@de54fd27) unchanged: pass=65184
  fail=408 skip=1533 staged=0 errors=0 (Track F doesn't touch the core
  corpus; its own tests are the coverage).
- **Everything is UNCOMMITTED** (the user commits between turns; the
  whole runtime is untracked working state).

## What shipped this session (Track F)

Design doc: .agent/design/embedding-spec.md. Waves F0–F4:
- Wasm.Wasi.Types: the preview1 errno/filetype/rights/oflags/fdflags/
  clockid/whence consts + struct sizes/offsets (CONFIRMED except the
  wave-3 poll_oneoff values).
- Wasm.Engine: the embedding facade over the shipped runtime —
  TWasmLoadedModule (owns bytes, ADR-0003), TWasmLinker (DefineFunc/
  Memory/Global; the engine-type-id import matching), TWasmInstance,
  load/instantiate/call/memory accessors (through the chokepoint, never
  raw Base), and the HOST-1 host-root registration that closes Track H's
  forward-hazard (RootRegister/RootExceptionRef). EWasmExit lives here
  (clean guest-requested exit, sibling under EWasmError).
- Wasm.Wasi.Memory: the guest-pointer helpers (GuestReadBytes/WriteBytes/
  ReadU32/ReadIoVec) — overflow-safe bounds → EFAULT, the sandbox's
  memory boundary. Never touches Base.
- Wasm.Wasi: deny-by-default TWasmWasiConfig (argv/env/preopens +
  injectable stdio/clock/random), the fd table, and the preview1 host
  functions — wave-1 (args/env/clock/random/stdio/proc_exit) + wave-2 fs
  via preopens (path_open with STRICT containment, file/dir ops,
  fd_readdir, filestat). Real CSPRNG (/dev/urandom / RtlGenRandom, fails
  closed → EIO). clock_gettime nanosecond precision.
- Wasm.Run + wasmlight run: the CLI (`run [--dir g=h] [--env K=V] [--]
  <mod.wasm> [args]`), the `--` guest-argv pre-scan (a 2nd sanctioned
  cli exception, now documented in AGENTS.md), the exit-code mapping.

## Review outcome (Opus-5 SECURITY + standards + corpus)

Security review of the sandbox boundary: **core sandbox sound** — no
guest-only escape in the shipped function set; guest-memory bounds are
overflow-safe at every level (incl. the iovec double-indirection);
the memory chokepoint is never bypassed (no raw Base anywhere in the
WASI units); deny-by-default holds (no ambient fs/env/argv; bare config
= stdio only); CSPRNG fails closed. Found + FIXED:
- **F1 (MEDIUM, containment)**: path_open with O_CREAT to a non-existent
  target validated only the parent, so a dangling symlink in the
  operator's preopen let the guest create/write OUTSIDE the sandbox.
  Fixed: lstat the leaf, reject a final-component symlink on create
  (weNotCapable) — regression test proves the outside file is not
  created.
- Hardened (LOW): reject embedded-NUL paths (weInval); rights check on
  fd_filestat_get; per-context fd cap (weMFile); clamp 64-bit I/O
  lengths; one central OsErrnoToWasi translator (was fixed guesses).
- Documented residuals: F2 (path-string TOCTOU — external-writer-only,
  the guest can't race under single-thread ADR-0008; openat/*at is the
  full fix), F5 (host dev/ino/nlink/timestamps passthrough — kept real
  st_ino so hardlink/cycle detection in real programs works).
Standards review: high quality, clean layering DAG, no inversion; fixed
a dead wxkTable arm, added a non-EWasmError catch-all to run, documented
the run CLI exception + the EWasmExit/EWasmException hierarchy, and
covered the hello.wasm fixture with a load-and-run test.

## Honest scope (Track F)

- Preview1 COMMAND modules (_start) run; reactors (_initialize-only) are
  detected/reported, not driven, in v1.
- fs is wave-1 (stdio/args/env/clock/random) + wave-2 (path_open + file/
  dir ops via preopens). The long tail (path_link/symlink/readlink/
  rename, fd_advise/allocate/sync, poll_oneoff) is NOT defined — a module
  importing one fails to link (honest deny-by-default). sock_* stays
  ENOTCAPABLE (no network by design). A future F5 wave stubs the tail
  ENOSYS + wires the external wasi-testsuite as a conformance net.
- Component Model OUT (ADR-0014). Threads/shared-memory OUT (ADR-0008).
- UNCONFIRMED: Windows CSPRNG link path + non-UNIX clock fidelity; the
  wave-3 poll_oneoff constants; a few witx struct details (F5/wasi-
  testsuite validates them).

## Next steps (dependency order)

1. **Track I — baseline JIT** (x86-64 + aarch64). The interpreter is the
   differential reference (ADR-0001). Inherits the epoch check at
   back-edges, stack maps at safepoints (RefRegBits is the projection),
   live-ref discoverability constraining regalloc. Guard-page memory
   becomes the JIT's inline-access optimization once signal→trampoline
   delivery is proven in-process (interpreter uses explicit checks).
   Observational-identity contracts: interp-spec §8, simd-spec §9,
   eh-spec §9 (unwind semantics, tag-address match, exn alloc safepoint,
   relaxed-op R=0, per-lane NaN, FP rounding, trap timing).
2. **Track J — AOT + artifact cache** (needs I). Artifacts record the IR
   version (currently 2), rejected on mismatch.
3. WASI F5 (long-tail stubs + wasi-testsuite net) if broader WASI
   conformance is wanted; the openat/*at fs rewrite to close F2's TOCTOU.
4. Small residuals: the `(module definition/instance)` linking-harness
   forms; the binary-leb128 limits-width decode; the 2 throw.wast
   wording edges; a spectest host module in the wast runner.
5. User decision standing: NO GitHub issues until the roadmap is done.
6. Local hygiene: builds drop gitignored .o/.ppu into
   .lwpt/modules/testing/, breaking a LOCAL `lwpt install --frozen`
   (fresh CI clone unaffected). `rm` them if frozen complains.
