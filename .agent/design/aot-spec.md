# Track J — the ahead-of-time compiler and artifact cache (`Wasm.Aot.*`)

Design spec. **Not source. Scratchpad only — never commit.** The deliverable
is this document; implementation spans several waves and agents (§7). It builds
on the shipped source of `Wasm.Jit.*` (the baseline JIT, Track I — complete on
aarch64 + x86-64, corpus-proven byte-identical to the interpreter), `Wasm.Ir`,
`Wasm.Runtime.*`, `Wasm.Interp`, `Wasm.Engine`, `Wasm.Run`, and
`Wasm.Wast.Runner`, and on the design docs `jit-spec.md`, `ir-spec.md`,
`interp-spec.md`, `runtime-spec.md`, `simd-spec.md`, and `eh-spec.md`, which it
**may not contradict**. The interpreter (Track E) is and stays the **tier of
record** (ADR-0001); the JIT (Track I) is the second tier. AOT is the **third
tier behind the same seam**, differentially tested against the interpreter
exactly as the JIT is — and, because AOT reuses the JIT's own generated code,
against the JIT too.

Track J is the **last** roadmap track (docs/roadmap.md). It adds **no wasm
semantics**: every guest-observable behaviour is already the interpreter's,
inherited through the JIT. It is pure engineering — machine-code serialization,
relocation, an artifact file format, a compile-ahead command, and a load path.

Spec pin (inherited unchanged; AOT introduces **no new wasm-semantic anchor**):
`wasm-mcp` 0.2.16, `spec/main` `d7b37e4170d8315f2f1283aed4e8076591a9a333`
(ADR-0004). `IR_FORMAT_VERSION` is **2** (`Wasm.Ir`), and an artifact records it
(§2, ADR-0007).

**Confidence markers.** Facts read from the current source tree are unmarked.
Machine-code and file-format engineering details carry **UNCONFIRMED** wherever
a byte-level detail is not certain — the differential harness (§5) catches a
mistake mechanically, exactly as it does for the JIT (jit-spec §0/§11). Never
delete a marker.

---

## 0. What Track J is, and the invariants it inherits

AOT compiles **every** compilable function of a module to native machine code
**at build time**, serializes the code into an **artifact file**, and at load
time maps the code executable and wires each function's `CompiledEntry` to it —
so a deployment that ships the artifact starts with native code already present
and pays **zero** run-time compilation latency. That is the win ADR-0001 names:
"AOT moves that cost to build time for deployments that want native code and
instant startup."

What AOT does **not** do, and must never do:

- **It does not skip decode or validation.** Decode + validate still run at load
  on the source module bytes, producing the IR fresh. This is not overhead to
  optimise away — it is the **trust boundary** (§2.4, §4). The artifact supplies
  the *compiled code*; the fresh decode/validate supplies the *IR and the safety
  guarantee*. There is no "trusted module" mode that skips validation (AGENTS.md:
  "no mode that skips validation").
- **It does not introduce a new backend.** It reuses the Track-I aarch64 and
  x86-64 backends verbatim to *generate* the code. Track J adds serialization,
  relocation, and the load path around them.
- **It does not change the seam.** A compiled function is still invoked through
  `TWasmFuncInst.CompiledEntry` and the store's `JitInvokeCompiled` hook
  (`Wasm.Runtime.Store`); AOT-loaded code and JIT-compiled code are the same
  bytes reaching the same dispatcher (§4).

Hard obligations, inherited and non-negotiable — each discharged in the section
named:

- **Observationally identical to the interpreter** (ADR-0001). AOT code *is* the
  JIT's code; if relocation is correct, identity is inherited from the JIT's
  proof. §5 is the proof.
- **Consumes the IR and nothing else** (ADR-0007/0012). The artifact records the
  IR version and is rejected on mismatch. §2.
- **Every backend emits the epoch check and can produce a stack map** (ADR-0006/
  0011). AOT emits nothing new here — it serializes what the backend already
  emits. The stack map is still the interpreter's frame (jit-spec §9), reached
  through the same shared helpers. §4.4.
- **Memory through one chokepoint** (ADR-0005/0010/0013); **traps unwind to the
  per-invocation trampoline** (ADR-0009); **a store is confined to one thread**
  (ADR-0008); **the error hierarchy is load-bearing**. All inherited from the
  JIT unchanged, because AOT executes the JIT's exact code calling the JIT's
  exact helpers.
- **64-bit UNIX only** (jit-spec §2.2). AOT exists only where the JIT does:
  aarch64 and x86-64 on UNIX. A 32-bit or Windows host has no artifact and runs
  the interpreter, transparently.

The single hard problem — the one thing this track exists to solve — is §1: the
JIT bakes **process-specific absolute addresses** into generated code, and a
file written by one process must run in another.

---

## 1. The relocation problem (the crux)

### 1.1 What the JIT bakes that is NOT position- or process-independent

The Track-I backends emit each subtle op as a **call to a Pascal runtime
helper**, and they emit that call by loading the helper's **absolute address**
as an immediate, then branching to it. Verified in the source:

- **Absolute helper-call targets.** `Wasm.Jit.Arm64` emits
  `Arm64EmitLoadImm64(Buf, T0, PtrUInt(@JitOpBinary)); blr T0` — a `movz`/`movk`
  quad materialising the 64-bit address of `@JitOpBinary`, then `blr`. The full
  set of baked helpers (each backend has its own copy, 12 apiece):

  | index | aarch64 (`Wasm.Jit.Arm64`) | x86-64 (`Wasm.Jit.X64`) | role |
  | --- | --- | --- | --- |
  | 0 | `JitTrapKind` | `X64TrapKind` | `TrapNow(kind)` — every trap stub |
  | 1 | `JitOpBinary` | `X64OpBinary` | binary numeric leaf (`Wasm.Interp.Numeric`) |
  | 2 | `JitOpUnary` | `X64OpUnary` | unary numeric leaf |
  | 3 | `JitRtDispatch` | `X64RtDispatch` | mem/table/ref/global/GC uniform dispatch |
  | 4 | `JitVecDispatch` | `X64VecDispatch` | `v128` leaf dispatch (`Wasm.Interp.Vector`) |
  | 5 | `JitRefBranchPredicate` | `X64RefBranchPredicate` | `br_on_null/cast` predicate |
  | 6 | `JitCallHelper` | `X64CallHelper` | direct `call` |
  | 7 | `JitCallIndirectHelper` | `X64CallIndirectHelper` | `call_indirect` (bounds→null→type) |
  | 8 | `JitCallRefHelper` | `X64CallRefHelper` | `call_ref` (null check) |
  | 9 | `JitReturnCallHelper` | `X64ReturnCallHelper` | `return_call` |
  | 10 | `JitReturnCallIndirectHelper` | `X64ReturnCallIndirectHelper` | `return_call_indirect` |
  | 11 | `JitReturnCallRefHelper` | `X64ReturnCallRefHelper` | `return_call_ref` |

  These live at addresses that differ per process and per build (ASLR, and any
  relink). Baked into a file, they are **wrong on the next load**.

- **The `@Fn^.Code[i]` IR-instruction pointer** (Track I "Fix C"). The uniform
  runtime-op template passes the IR instruction to its helper by baking its
  address: `Arm64EmitLoadImm64(Buf, 2, PtrUInt(AInsPtr))` where
  `AInsPtr = @AFn^.Code[i]`. That is a pointer into the **heap-allocated IR**,
  which is freshly allocated on every load (a different address every time —
  even the JIT re-derives it per compile). Baked into a file it is meaningless.

- **Runtime field offsets** (`Store.Epoch`, `Store.EpochSnapshot`, and on the
  future inline path `Mem.Base`/`Mem.ByteSize`). The epoch capture emits
  `Arm64EmitLoadImm64(Buf, T0, UInt64(AEpochOffset))` — but `AEpochOffset` is a
  **byte offset** (`WasmJitOffsets(Store).StoreEpoch`), added to the pinned store
  register. It is a *constant*, not an address, so it is position-independent —
  **provided the loading runtime has the same record layout**. This is a build/
  ABI concern, not a relocation, and it is handled by the ABI fingerprint (§1.4,
  §2.3), not by patching.

- **Wasm immediate constants** (`v128.const` bits, `i32.const` values, jump
  displacements resolved to native offsets). These are `Arm64EmitLoadImm64(..,
  UInt64(AIns.Imm))` and PC-relative branches. They **travel with the code
  correctly** — they encode guest data or intra-block offsets, nothing about the
  host process. No relocation needed.

So the relocation problem reduces to **exactly two categories**: (a) helper
addresses, and (b) the `@Fn^.Code[i]` IR pointer. Everything else is either
guest data that travels with the code, or an ABI constant guarded by a
fingerprint. Nail those two and the artifact's code is fully position- and
process-independent.

### 1.2 The design: eliminate relocation structurally, don't patch per site

The textbook fix is a **relocation table**: a list of `(site-offset-in-code,
kind, symbol)` recorded beside the code; at load, for each entry, patch the site
with the loaded process's actual address for that symbol. That works, but the
`movz`/`movk` quad (aarch64) and `movabs` imm64 (x86-64) encodings put the
address across four instruction words / eight scattered bytes, so patching is
fiddly and per-call-site, and the count is large (a call-heavy function has one
per call). We record the format for completeness (§1.5) but make it **empty in
the current op set** by two structural changes to the emitter — the standard AOT
approach (an indirection table plus a pinned base), which turns "patch N sites"
into "fill one table + pass two registers".

**Decision A — helper calls go through a per-process helper table (GOT/PLT
style).** The emitter no longer bakes a helper's absolute address. Instead it
calls **indirectly through a fixed-index slot** of a helper table:

```text
; aarch64  (xHT = pinned helper-table base, §4.3)
ldr   xT, [xHT, #k*8]     ; k = the helper's fixed index (0..11)
blr   xT
```

```text
; x86-64  (rHT = pinned helper-table base)
call  qword [rHT + k*8]
```

The 12 helper indices are a fixed enum `TWasmAotHelper` (the table above); the
table is an array of 12 pointers. It is filled **once**, at `RegisterJit`/
AOT-load time, with the live `@JitTrapKind`… addresses of *this* process. Zero
per-call-site relocations; a single 12-entry array fill covers every call in
every function. This is position-independent by construction: the code names a
*slot index*, never an address.

**Decision B — the `@Fn^.Code[i]` IR pointer comes from a pinned register.** The
emitter no longer bakes `PtrUInt(@Fn^.Code[i])`. The compiled entry receives the
function's **IR code base** (`@Fn^.Code[0]`) in a new argument register, pinned
callee-saved for the body; a template that needs `@Fn^.Code[i]` computes it
PC-independently:

```text
; aarch64  (xIR = pinned IR-code base, §4.3)
add   x2, xIR, #(i * SizeOf(TWasmIrInstr))     ; i is a compile-time constant
```

(with a `movz`+`add` fallback when `i*stride` exceeds the `add` immediate range).
The load path passes the *freshly-decoded* IR's `Code[0]` address — so the code
is never trusting a baked IR pointer, and this also **subsumes Fix C's** latent
`@AIns`-by-reference concern (jit-spec §12.5 O-J4 / HANDOFF Fix C): the pointer
is now computed from a live base, never a bet on FPC's parameter passing.

The net: **AOT code contains no host address at all.** Every value baked into it
is guest data (travels), an intra-block offset (travels), or an ABI constant
(guarded). The relocation table is therefore *empty* for the current op set —
the strongest possible outcome, and the reason load is cheap and robust.

### 1.3 Unify the emitter, or gate an AOT mode — decision

Decisions A and B change the bytes the emitter produces. Two ways to introduce
them:

- **(Chosen) Unify: the position-independent emission becomes the *only*
  emission.** The JIT adopts the helper table and the pinned IR base too, and at
  `RegisterJit` fills the same 12-entry table with in-process addresses. Then JIT
  and AOT emit **byte-identical** code, and "AOT code is the JIT's code,
  relocated" is *literally* true (relocation being: fill the table, pass two
  registers). The Track-I differential corpus (`--tier=jit`, 8562/8563 functions
  byte-identical to the interpreter) re-runs unchanged as the regression net for
  this refactor **before AOT exists** (§7, Wave 0) — the change is gated by the
  strongest oracle the project has.
- **(Fallback) A flag on the emitter.** `Arm64EmitOp(.., AotMode: Boolean)` picks
  table-indirect vs. absolute per call. JIT keeps baking; AOT emits indirect.
  Simpler to land in isolation but leaves two codegen paths and weakens the
  "same code" argument (the differential harness still covers it). Take this only
  if unifying Track I proves too invasive.

Cost of unification: one extra load per helper call in the JIT (`ldr xT,[xHT,#k]`
vs a `movz`/`movk` quad — actually *fewer* bytes and a warm-cache load), and one
prologue load to pin the table base. Negligible against the removed dispatch
overhead the JIT already wins. **Recommendation: unify.** The rest of this doc
assumes the unified emitter; where the fallback differs it is noted.

### 1.4 The ABI fingerprint (guards the baked constants)

The code still bakes **constants** the loading runtime must agree on: the
`WasmJitOffsets` fields (`Store.Epoch`, `Store.EpochSnapshot`, `Mem.Base`,
`Mem.ByteSize`, the func-inst tier fields), the `WasmJitFrameOffsets` fields
(`SizeOf(TWasmValue)` slot stride, the context/activation/GC-frame offsets),
`SizeOf(TWasmIrInstr)` (the pinned-IR-base stride), the pinned-register
assignment, the helper-enum ordering, and the entry-ABI shape. A *different
wasmlight build* could change any of these silently and the baked constants
would be wrong.

**The artifact records a 64-bit ABI fingerprint** — a deterministic hash over
`{ all WasmJitOffsets fields, all WasmJitFrameOffsets fields, SizeOf(TWasmIrInstr),
SizeOf(TWasmValue), the TWasmAotHelper count, AOT_ABI_REVISION }`. The loader
recomputes it from the *live* runtime (the offset accessors already exist and are
asserted by their co-located tests: `WasmJitOffsets`, `WasmJitFrameOffsets`) and
**rejects the artifact on mismatch** → fall back. This is the "same build" guard,
sitting beside the IR-version and arch guards (§2.3). `AOT_ABI_REVISION` is a
hand-bumped integer for any emitter change the fingerprint can't otherwise see
(a template's byte layout, a pinned-register reassignment).

### 1.5 The relocation table format (recorded for completeness / future ops)

Kept in the artifact per function, but **empty in the current op set** (§1.2). It
exists so a future template that *must* bake an absolute has a defined,
load-time-patched path, and so the format is forward-compatible.

Each entry: `SiteOffset: u32` (byte offset into the function's code blob),
`Kind: u8`, `Symbol: u16`. Kinds:

- `rkHelperAbs64` — patch an absolute helper address at the site. aarch64: patch
  the four `movz`/`movk` immediate fields (bits 20:5 of each word) at
  `SiteOffset..+16` with `helper[Symbol]`; x86-64: splat the 8 bytes of
  `helper[Symbol]` into the `movabs` imm64 at `SiteOffset+2..+10`. Used only by
  the fallback emitter (§1.3) or a template that opts out of the table.
- `rkAbsImm64` — a generic absolute 64-bit patch at `SiteOffset` (8 raw bytes),
  `Symbol` naming a runtime datum from a small enumerated symbol space.

The patch encodings are backend-specific and **UNCONFIRMED** at the bit level;
they are exercised only if the table is non-empty, and the differential harness
(§5) is the check.

---

## 2. The artifact format (`Wasm.Aot.Artifact`)

### 2.1 File identity

Extension **`.waot`** (wasm ahead-of-time). One artifact corresponds to one
source module (one `.wasm`). All integers are **fixed-width little-endian** — not
LEB128. The wasm binary format uses LEB128 for compactness over the wire; an
artifact is an *internal* file optimised for **load speed**, so fixed-width lets
the loader treat the mapped bytes as a struct and index in O(1). Both target
arches are little-endian (as is the `Wasm.Jit.CodeBuffer` emission), so LE is
the natural choice and needs no per-load byte-swap.

### 2.2 Layout

```text
Header (fixed size)
  magic          : 4 bytes  = 'W','A','O','T'  (0x57 0x41 0x4F 0x54)
  aotFormatVer   : u16      container format version (starts at 1; this doc)
  irFormatVer    : u16      = IR_FORMAT_VERSION at compile (currently 2)
  targetArch     : u8       1 = aarch64, 2 = x86-64
  flags          : u8       reserved (0)
  abiFingerprint : u64      §1.4 — rejected on mismatch
  moduleHash     : 16 bytes §2.4 — content hash of the source .wasm bytes
  funcCount      : u32      number of function records
  selfChecksum   : u64      §2.4 — hash over everything after this field
Function records  (funcCount of them, each:)
  funcIrIndex    : u32      index into Ir.Functions (DEFINED funcs, code order)
  funcFlags      : u8       bit0 = compiled (else declined → interpret at load)
  pad            : 3 bytes
  registerCount  : u32      cross-check against the freshly-validated IR
  entryOffset    : u32      byte offset of the entry stub within codeBytes
  codeLength     : u32      length of codeBytes (0 for a declined func)
  relocCount     : u32      §1.5 (0 in the current op set)
  relocs         : relocCount × (u32 siteOffset, u8 kind, u16 symbol, u8 pad)
  codeBytes      : codeLength bytes, then padded to 16-byte alignment
```

Function records appear in `funcIrIndex` order. A **declined** function (any op
`JitCanCompile` refuses — EH ops, an over-large frame, anything a wave hasn't
implemented) has `funcFlags.compiled = 0`, `codeLength = 0`, and is run
interpreted at load — exactly the JIT's fall-back, recorded so the loader need
not re-run the predicate to know it.

### 2.3 What is stored vs. re-derived (and the guards)

- **Stored:** the header, and per function the machine code + reloc table +
  `(funcIrIndex, registerCount, entryOffset)`. Nothing else. **The artifact
  stores no IR content** — not the ops, not the register bits, not the handler
  tables.
- **Re-derived at load, never stored:** the entire IR (re-decode + re-validate
  the source module → a fresh `TWasmIrModule`; cheap, and the trust anchor); the
  store/instance; the 12 live helper addresses (from *this* process); the pinned
  IR-code base per function (`@Ir.Functions[funcIrIndex].Code[0]`); the field
  offsets (live). The `registerCount` in the record is a **cross-check** against
  the freshly-validated IR, not a source of truth — a mismatch declines that
  function (defensive; should never fire if the guards pass).

The load-time reject guards, in order (any failure → ignore the artifact, fall
back transparently, §4.5):

1. `magic` ≠ `WAOT` → not our file.
2. `aotFormatVer` unknown → format we can't read.
3. `irFormatVer` ≠ `IR_FORMAT_VERSION` → IR the code was compiled from has
   moved (ADR-0007). This is the roadmap's named guard: "Artifacts record the IR
   version they were compiled from and are rejected on mismatch."
4. `targetArch` ≠ host arch → arch-specific code for a different CPU (§6).
5. `abiFingerprint` ≠ live fingerprint → different wasmlight build/ABI (§1.4).
6. `selfChecksum` ≠ recomputed → the file is corrupt/truncated/partially written.
7. `moduleHash` ≠ hash of the freshly-loaded source bytes → stale artifact for a
   changed module (§2.4).

### 2.4 The security invariant (an artifact is a cache, not a trust bypass)

**Hard invariant: the module is always re-decoded and re-validated at load, and
that fresh validation — never the artifact — is the safety oracle.** The
artifact contributes only the *compiled code*; the code is used **only if** its
`moduleHash` matches the freshly-validated module and the IR-version, arch, ABI,
and self-checksum guards all pass.

- `moduleHash` binds the artifact to a specific source module: a stale artifact
  for a since-changed module has a mismatching hash and is rejected → the module
  runs interpreted (or JIT-on-hot), never with wrong-module code.
- `selfChecksum` catches accidental corruption (bit-rot, a truncated or
  partially-written file) → reject → fall back.

**Threat model, stated honestly.** The hash and checksum are **content-identity
and corruption** guards, computed with a deterministic in-repo hash (FNV-1a-128
or an equivalent small mixing function — **no new dependency**, per AGENTS.md;
128-bit to make an identity collision negligible). They are **not** a
cryptographic authentication of the code bytes against a malicious local
attacker. An attacker who can rewrite the `.waot` on disk can equally rewrite the
`wasmlight` binary itself — the artifact and the runtime are in the **same trust
domain**, so authenticating one against the other buys nothing. What *is*
preserved, unconditionally, is the wasm **sandbox** guarantee: the guest cannot
do anything the validated IR did not permit, because (1) decode + validate always
run and are the oracle, and (2) the loaded code is a function of that validated
IR produced by our own backend. A tampered artifact cannot smuggle *unvalidated
guest behaviour* past the sandbox; at worst a same-trust-domain attacker who has
already compromised the on-disk toolchain runs their own native code — which they
could do without an artifact at all. This is the same posture as any AOT cache
(`.NET` ReadyToRun, the V8 code cache): a performance cache keyed by content, not
a code-signing boundary.

### 2.5 The writer

A small dedicated writer in `Wasm.Aot.Artifact` — **not** `Wasm.Wat.Emit` (that
is canonical-LEB wasm encoding; the artifact is fixed-width). Two-pass: compute
each function's sizes, lay out offsets, then write; backpatch `selfChecksum` and
any length placeholders last (the backpatching discipline `Wasm.Wat.Emit`
already models, applied to a fixed-width writer). Output is a `TWasmBytes` the
caller writes to `<name>.waot`.

---

## 3. The AOT compile step

### 3.1 The command

`wasmlight aot <module.wasm> -o <artifact.waot>` (a new subcommand in
`source/apps/wasmlight.pas`, registered through lwpt's `cli` package like
`inspect`/`validate`/`run`). It:

1. `LoadModule` the bytes (`Wasm.Engine` — decode + validate, keeping
   `EWasmDecodeError`/`EWasmValidationError` distinct; a module that does not
   decode or validate is not compilable and the command exits non-zero with the
   specific error, never a stale artifact).
2. For **every** wasm function in `Ir.Functions`: if `JitCanCompile(@Fn)` (the
   Track-I predicate, unchanged — the scope fence, §8), compile it in the unified
   position-independent mode capturing `(codeBytes, relocs, entryOffset,
   registerCount)`; else record it declined. **AOT compiles all**, not hot-only —
   there is no run-time profile at build time, and the whole point is that
   nothing compiles at run time.
3. Compute `moduleHash` over the loaded bytes (`LoadedModule.BytesPtr/
   BytesLength`), `abiFingerprint` over the live offsets, stamp `irFormatVer =
   Ir.FormatVersion`, `targetArch` = host.
4. Write the artifact.

The command compiles for the **host arch only** — it drives the host backend
(`Wasm.Jit.Arm64` on aarch64, `Wasm.Jit.X64` on x86-64). An aarch64 host produces
an aarch64 artifact; to produce an x86-64 artifact, run the command on x86-64
(§6). Cross-compilation (emit a foreign arch's code) is out of scope for v1 and
named in §8.

### 3.2 Capturing code + relocs from the backend

The backend already stages bytes into `Wasm.Jit.CodeBuffer` (`FStage`,
`FLength`) and resolves intra-function branches while still writable
(`ResolvePatches`). AOT needs the finalized bytes **without** mapping them
executable, plus the (empty) reloc list:

- Add `TWasmCodeBuffer.SnapshotBytes: TWasmBytes` — returns `FStage[0..FLength)`
  after `ResolvePatches`, **without** calling `MakeExecutable` (no `mmap`, no W^X
  flip). The bytes are complete, branch-resolved, position-independent code.
- Add a reloc accumulator to the buffer: in the unified emitter there is nothing
  to accumulate (helpers are table-indirect, the IR base is register-relative),
  so `SnapshotRelocs` returns empty. It exists for the fallback emitter (§1.3)
  and future ops (§1.5).

`JitCompileToBuffer` (`Wasm.Jit`) already builds exactly the per-function block
`SnapshotBytes` needs; AOT compile calls the same driver in a "stage only" mode
that stops before `MakeExecutable`. This keeps **one** compilation path shared by
JIT and AOT — the code the artifact stores is the code the JIT would have run.

### 3.3 Emitter change: AOT-mode flag vs unified — where it lands

Per §1.3 the recommendation is to **unify** (the JIT also emits table-indirect +
pinned-IR-base), so there is no "AOT mode" at emission at all — only "finalize to
executable memory" (JIT) vs "finalize to bytes" (AOT). If instead the fallback is
taken, the flag rides on `Arm64EmitOp`/`X64EmitOp` and threads through
`JitCompileToBuffer`; the AOT-mode emitter, at each helper call and IR-base site,
emits the position-independent form *and* (for any residual absolute) appends a
reloc entry. The AOT-mode-flag-on-the-emitter is the clean shape either way — the
relocation is recorded *at emission*, never diffed out of a symbol table in a
post-pass.

---

## 4. The AOT load step

### 4.1 The entry points

Two new procedures in `Wasm.Aot` (the load half; may co-locate with the writer in
`Wasm.Aot.Artifact` or split as `Wasm.Aot.Load`):

- `AotLoadArtifact(Store, Loaded, ArtifactBytes): Boolean` — the core. `Loaded`
  is the already-decoded+validated `TWasmLoadedModule` for the *same* module;
  `ArtifactBytes` is the `.waot` file. Returns True iff the artifact passed every
  guard (§2.3) and its code is now wired; False → the caller falls back.
- `AotRunConfiguredModule(...)` — the `wasmlight run --aot <file.waot>` path,
  factored into `Wasm.Run` beside `RunConfiguredModule` so it is hermetically
  testable with injected streams (as `Wasm.Run` already is).

### 4.2 The sequence

1. **Decode + validate the source module** (`LoadModule`) → fresh `Ir`. Always.
   The artifact is never opened before this succeeds — validation is the gate.
2. Parse the artifact header; apply guards 1–7 (§2.3). Any failure → return
   False (fall back).
3. Ensure the JIT/AOT runtime is registered on the store (`RegisterJit`, which
   installs the `JitInvokeCompiled` hook and fills the 12-entry helper table with
   live addresses). AOT reuses the JIT context — the code cache, the helper
   table, the dispatcher are the same.
4. For each **compiled** function record: allocate an executable region and load
   its `codeBytes` into it (a `TWasmCodeBuffer` "adopt these bytes" path:
   `mmap`/`MAP_JIT`, copy under the W^X transition, `mprotect` RX / toggle back,
   **flush the I-cache on aarch64** — the exact `Wasm.Jit.CodeBuffer` machinery,
   §3.1–3.3 of jit-spec, just fed pre-made bytes instead of freshly emitted
   ones). Apply the reloc table (empty). Cross-check `registerCount` against
   `Ir.Functions[funcIrIndex].RegisterCount`; on mismatch, skip this function
   (leave it interpreted).
5. Set `Store.Funcs[addr].CompiledEntry := region.EntryPoint + entryOffset` for
   the func addr whose `FuncIrIndex = funcIrIndex`. Register the region with the
   JIT context so it is `munmap`'d at teardown (same ownership discipline as the
   JIT's code blocks, jit-spec §3.4).
6. Declined records: nothing to do — `CompiledEntry` stays nil → interpreted.

Result: every compilable function has native code wired **before the first
call**. No `CallCount`, no threshold, no on-hot — instant startup.

### 4.3 The entry ABI and the pinned bases

The compiled entry gains one argument (the IR-code base). The unified convention:

| role | aarch64 | x86-64 | how the dispatcher supplies it |
| --- | --- | --- | --- |
| register-file base `@Values[Base]` | x19 (arg x0) | rbx | `JitEnterFrame` return |
| store pointer | x20 (arg x1) | r12 | the store |
| `&Store.Epoch` | x21 | — | `x20 + StoreEpoch` |
| epoch captured at entry | x22 | — | epoch capture |
| **IR-code base `@Fn^.Code[0]`** (new) | **x23 (arg x2)** | **new arg** | `@Inst.Ir.Functions[FuncIrIndex].Code[0]` |
| **helper-table base** (new) | **x24** | **new** | prologue loads it from the store (a `JitHelperTable` field) once |

The **helper-table base** hangs off the store (a `JitHelperTable: PPointer` field
populated at `RegisterJit`/load, one field like `JitInvokeCompiled`), and the
prologue loads it into a pinned callee-saved register **once** so per-call cost is
a single `ldr xT,[x24,#k*8]; blr xT`. The **IR-code base** is passed per call by
the dispatcher (`Arm64InvokeCompiled`/`X64InvokeCompiled` already have the func
addr → instance → IR, so `@Fn^.Code[0]` is in hand), pinned in the prologue for
the body. Both are runtime *values*, never baked — which is precisely what makes
the code position-independent. (Exact register numbers x23/x24 and the x86-64
callee-saved choices are **UNCONFIRMED** against the free callee-saved set; the
Track-I convention leaves x23–x28 free on aarch64.)

### 4.4 The frame, GC, epoch, traps, tail calls, EH-seam — all inherited

AOT-loaded code **is** the JIT's code. It calls the same helper-table entries
(`JitCallHelper`, `JitReturnCallHelper`, `JitRtDispatch`, `JitTrapKind`, …), which
are the same Pascal functions compiled into the loading `wasmlight` binary. So:

- **The frame is the interpreter's frame** — carved/zeroed/pushed/popped by the
  shared `Wasm.Interp.JitEnterFrame`/`JitLeaveFrame`. The GC stack map is the
  frame (jit-spec §9), bit-identical to interpreted and JIT frames.
- **The epoch check** reads `Store.Epoch` at the same `IR_JUMP_SAFEPOINT` sites.
- **Traps** call `TrapNow` through the table → the per-invocation trampoline
  (ADR-0009). Same kind, same message, same timing.
- **Tail calls** run through `Arm64InvokeCompiled`/`X64InvokeCompiled`'s
  trampoline loop and `JitReturnCall*` helpers → O(1) native stack (jit-spec
  §4.5).
- **The EH seam** (Track I "Fix A": `rtCompiledSeam` frames transparent to the
  throw unwind, the `SetJmp`/`LongJmp` seam-catch stack, `TierTailSlot`,
  `ConsumeJitSeamReentry`) is entirely in Pascal (`Wasm.Interp`, the backends'
  `*InvokeCompiled`), present at run time regardless of the artifact. A throw
  propagating through AOT-loaded seam frames reaches an outer interpreted
  `try_table` exactly as through JIT frames — **confirmed**: the machinery is
  reached through the same helpers and dispatchers, and AOT changes only where a
  function's code bytes came from, not the seam.

Nothing in this section is new work — it is the statement that AOT inherits the
JIT's whole contract because it executes the JIT's code.

### 4.5 Fall-back is transparent

If the artifact is absent, or **any** guard fails (§2.3), `AotLoadArtifact`
returns False and the module runs with **no** compiled entries — pure interpreter
by default, which is fully conformant (ADR-0001). A build may layer JIT-on-hot as
the fall-back instead (register the JIT and let the hot counter compile), but v1's
default is interpret-on-fall-back: predictable, and it never silently masks a
stale cache with a slow first run. The policy is one flag.

---

## 5. Differential correctness (ADR-0001)

The AOT tier must be observationally identical to the interpreter **and** to the
JIT. Because it is the JIT's code relocated, identity is *inherited* if
relocation is correct — so the differential harness's job is to prove relocation
correct, and it does so with the same 65k-assertion corpus that proved the JIT.

### 5.1 A third tier mode: `--tier=aot`

`Wasm.Wast.Runner` already has `TWastTierMode` with `interp` and `jit`
(HANDOFF/Track I). Add `aot`. Crucially, `--tier=aot` must **round-trip through
the artifact bytes**, not just call the JIT and rename it — otherwise it tests
nothing new. For each module the runner:

1. decode + validate → `Ir` (as always);
2. **serialize**: `AotCompileModule(Loaded)` → in-memory `.waot` bytes (drives the
   backend in stage-only mode, §3.2, writes the artifact to a buffer);
3. **load**: `AotLoadArtifact(freshStore, Loaded, artifactBytes)` on a fresh store
   — mapping the code executable, wiring `CompiledEntry` (§4.2);
4. run each executing assertion (`assert_return`/`assert_trap`/`assert_exhaustion`/
   `assert_exception`/`invoke`) against that store;
5. diff every observable against the interpreter's verdict (return values
   bitwise/per-lane/by-reference-identity; trap kind + prefix-matched message +
   when; final memory/globals/table/GC state; `EWasmExit` code; `EWasmException`
   vs `EWasmTrap`) — jit-spec §11.2's comparison, unchanged.

This exercises the **whole serialize → relocate → map → execute spine** on every
corpus module. Any difference is an AOT bug and fails with both sides' values.
Declined functions run interpreted under both tiers and agree by construction.
`wasmspec --tier=aot` reports `compiled=N` in the total line, beside the JIT's.

### 5.2 The round-trip identity test

A direct unit test (`Wasm.Aot.Test`): for a hand-built module, (a) JIT-compile a
function and capture its code block bytes; (b) AOT-compile the same function,
serialize, load, capture the loaded region's bytes. Assert:

- **byte-identity of the code blob** (given the unified emitter, §1.3, they are
  the same bytes — a strong, cheap invariant that catches any divergence between
  the JIT's finalize-to-exec and AOT's finalize-to-bytes paths); and
- **behavioural identity**: invoke both, diff outputs — the real check, and the
  one that still holds under the fallback emitter where bytes may differ.

### 5.3 The corpus is AOT's net for free

Exactly as for the JIT (jit-spec §11.3): AOT adds **no new corpus assertions** —
it re-runs the existing ~65k under a third tier. The deliverable claim is *"the
corpus passes identically under AOT for the compilable subset"*, not a new pass
count. Because the interpreter is conformant and AOT is identical to it, AOT is
conformant, at zero authoring cost.

---

## 6. Cross-arch and the OrbStack VM

Artifacts are **arch-specific**: an aarch64 `.waot` has `targetArch = aarch64`
and is rejected (guard 4, §2.3) on an x86-64 host, and vice versa. The `wasmlight
aot` command produces code for the host arch only (§3.1).

Operationally, mirroring Track I's cross-arch proof (HANDOFF):

- On the **aarch64-darwin dev host**: `wasmlight aot` produces aarch64 artifacts;
  `wasmspec --tier=aot tests/spec/testsuite` runs the AOT differential corpus and
  must be byte-identical to `--tier=interp`.
- In the **OrbStack amd64 Linux VM** (`orb -m wasmx64`, Rosetta-accelerated,
  FPC 3.2.2 + lwpt): the same commands produce and run **x86-64** artifacts; the
  VM re-run recipe is the JIT's with `--tier=jit` → `--tier=aot`. This is where
  the x86-64 artifact format, loader, and `X64*InvokeCompiled` entry-ABI change
  are proven, exactly as the x86-64 JIT backend was.

State plainly in the docs: the `--tier=aot` differential corpus runs on aarch64
here and x86-64 in the VM, per arch, never cross-loaded.

---

## 7. Unit layout and wave plan

### 7.1 Units (bottom-up; `Wasm.Aot.*` sit above `Wasm.Jit`, below the apps)

- **`Wasm.Aot.Artifact`** — the `.waot` format: the fixed-width reader and
  writer, the reloc-table encode/decode, the `moduleHash`/`selfChecksum` hash
  (in-repo FNV-1a-128, no dependency), and the `abiFingerprint` compute (reads
  `WasmJitOffsets`/`WasmJitFrameOffsets`). Depends on `Wasm.Core`, `Wasm.Ir` (for
  `IR_FORMAT_VERSION`), `Wasm.Runtime.Store` (offsets). Knows nothing about
  emitting or mapping code — pure format.
- **`Wasm.Aot`** — the compile and load drivers: `AotCompileModule(Loaded):
  TWasmBytes` (drive the backend stage-only over every function, assemble the
  artifact) and `AotLoadArtifact(Store, Loaded, Bytes): Boolean` (guards, map,
  relocate, wire). Depends on `Wasm.Aot.Artifact`, `Wasm.Jit` (the driver +
  context + helper table), `Wasm.Jit.CodeBuffer` (the adopt-bytes exec mapping),
  the active backend, `Wasm.Runtime.Store`, `Wasm.Interp`.
- **Emitter/CodeBuffer extensions** — `TWasmCodeBuffer.SnapshotBytes`/
  `SnapshotRelocs` and the "adopt pre-made bytes" exec path (§3.2, §4.2); the
  unified position-independent emission in `Wasm.Jit.Arm64`/`.X64` (§1.2–1.3) and
  the `JitHelperTable` store field + fill (§4.3).
- **Apps** — `wasmlight aot` (compile) and `wasmlight run --aot` (load) in
  `source/apps/wasmlight.pas` + `Wasm.Run`; `--tier=aot` in `Wasm.Wast.Runner` +
  `wasmspec`; a startup benchmark in `wasmbench`.
- Co-located tests: `Wasm.Aot.Artifact.Test`, `Wasm.Aot.Test`.

**Layering rule.** Nothing in `Wasm.Runtime.*`, `Wasm.Interp`, or `Wasm.Jit.*`
depends on `Wasm.Aot.*` (that would invert the seam). AOT reaches down into the
JIT and the runtime; they never reach up. The one field the runtime gains
(`JitHelperTable`) is set by the JIT/AOT registration, mirroring
`JitInvokeCompiled`.

### 7.2 The FIRST milestone

**AOT-compile the JIT milestone function — `(func (param i32 i32) (result i32)
local.get 0; local.get 1; i32.add)` — on aarch64: serialize it to a `.waot`
byte buffer, load it into a fresh store, run it, and diff against the
interpreter.** This proves the whole spine at minimum size: the unified emitter
produces position-independent bytes; `AotCompileModule` writes an artifact;
`AotLoadArtifact` passes every guard, maps the bytes executable, flushes the
cache, and wires `CompiledEntry`; the entry runs with the pinned IR base and
helper table; the differential test asserts equal to the interpreter. Assert as
bonuses that the reloc table is **empty** and the code blob is **byte-identical**
to the JIT's block for the same function (§1.2, §5.2) — the position-independence
claim, mechanically checked. When this passes, every further function is an
incremental format/coverage step, not new spine.

### 7.3 Waves (each gate-green, each differentially tested)

- **Wave 0 — the emitter refactor (prerequisite).** Unify the backends onto
  table-indirect helper calls + pinned-IR-base (§1.2–1.3); add the
  `JitHelperTable` store field and its fill at `RegisterJit`; add
  `SnapshotBytes`/`SnapshotRelocs`. **No AOT yet** — the gate is that the existing
  `--tier=jit` corpus (arm64 8562, x86-64 8563) stays byte-identical to the
  interpreter. The strongest oracle guards the riskiest change *before* AOT
  exists. (Skip Wave 0 if the fallback emitter is chosen, §1.3.)
- **Wave 1 — `Wasm.Aot.Artifact` + the first milestone.** The format reader/
  writer, hashes, ABI fingerprint, and the `i32.add` serialize→load→execute→diff
  (§7.2). One function; proves the spine and the format.
- **Wave 2 — all functions + declined handling.** `AotCompileModule` over every
  function of a module (drive `JitCanCompile`, record declined), the function
  table, the cross-checks. `--tier=aot` over a corpus subset on aarch64.
- **Wave 3 — full corpus `--tier=aot` on aarch64.** Byte-diff vs `--tier=interp`
  across the whole testsuite; the round-trip-vs-JIT identity test (§5.2). The
  deliverable proof for aarch64.
- **Wave 4 — x86-64.** `targetArch` id, the x86-64 loader path and entry-ABI
  change (`X64*InvokeCompiled` gains the IR-base arg), `--tier=aot` in the amd64
  VM (§6). Encoder work is already Track I's; this is format + entry-ABI + the VM
  gate.
- **Wave 5 — the CLI + measurement.** `wasmlight aot <module> -o <artifact>`,
  `wasmlight run --aot <artifact>` (+ optional sibling auto-detect, §8), and a
  `wasmbench` startup measurement (instant-start vs JIT-warmup vs interp) —
  measurement only, never a CI assertion (AGENTS.md).

Waves 2–3 are the aarch64 deliverable; Wave 4 extends it to x86-64 exactly as the
JIT did.

---

## 8. Scope and honesty

- **Staged, via the compile predicate (unchanged).** Anything `JitCanCompile`
  declines, AOT declines: **exception-handling functions stay interpreted** (the
  Track-I fence 1 — a function owning a `try_table` handler table, or containing
  `iroThrow`/`iroThrowRef` — declines; §10.2 of jit-spec), any op no wave
  implemented, an over-large frame, a 32-bit/Windows/non-JIT host. A declined
  function is recorded `compiled=0` and runs interpreted at load — identical to
  the JIT's fall-back, always correct. AOT inherits the JIT's op coverage exactly;
  it adds no coverage and removes none.
- **`v128` is compiled via leaf calls**, same as the JIT (`JitVecDispatch`,
  jit-spec §10.1). Native SIMD, guard-page inline memory access, and machine-
  register allocation remain deferred JIT optimisations (jit-spec §7.2/§9.4/
  §12.4); AOT serializes whatever the emitter produces, so it gains any of these
  for free if and when the JIT does.
- **Cache invalidation is content-keyed.** A changed module → mismatching
  `moduleHash` → reject → recompile (re-run `wasmlight aot`) or fall back. A new
  wasmlight build that moves the IR or a record layout → mismatching
  `irFormatVer`/`abiFingerprint` → reject → recompile. There is no partial trust
  of a mismatched artifact: the guards are whole-artifact (a per-function
  `registerCount` cross-check is a defensive belt-and-braces that declines a
  single function, never silently runs it).
- **Wiring into `wasmlight run` — v1 is explicit.** v1 ships `wasmlight aot`
  (compile) and `wasmlight run --aot <file.waot>` (explicit load). **Auto-detect
  a sibling `<module>.waot`** is a one-line path probe and a documented easy
  follow-up, deliberately *not* v1: an explicit flag never surprises a user with
  a stale cache, and keeps the load path's fall-back behaviour observable in
  tests. The clean progression is explicit-flag v1 → opt-in auto-detect later.
- **Cross-compilation is out of scope.** `wasmlight aot` emits host-arch code
  only; producing a foreign-arch artifact means running the command on that arch
  (or in the VM, §6). A cross-emitter (the aarch64 host emitting x86-64 bytes) is
  a possible successor, not v1 — it needs the *other* backend's encoder driven on
  a foreign host, with no local way to execute-and-diff, so it would ship without
  its own differential net until run on the target. Named, not built.
- **AOT changes no wasm behaviour and no pass count.** It re-runs the corpus under
  a third tier. Estimate nothing about pass counts; the deliverable is *"the
  corpus passes identically under AOT for the compilable subset,"* proven by §5,
  and a `wasmbench` startup number that is measurement only.

With Track J the tier ladder is complete: interpreter (record) → baseline JIT
(compile-on-hot) → AOT (compile-at-build, instant start), all three behind one
seam, all three differentially identical, the third inheriting its correctness
from the second by being the second's code — relocated.
