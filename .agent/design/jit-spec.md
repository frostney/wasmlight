# Track I — the baseline JIT (`Wasm.Jit.*`)

Design spec. **Not source. Scratchpad only — never commit.** The deliverable
is this document; implementation spans several waves and agents (§12). It
builds on the shipped source of `Wasm.Ir`, `Wasm.Runtime.*`, `Wasm.Interp`,
and `Wasm.Wast.Runner`, and on the design docs `ir-spec.md`,
`interp-spec.md`, `runtime-spec.md`, `simd-spec.md`, and `eh-spec.md`, which
it **may not contradict**. The interpreter (Track E) is and stays the **tier
of record** (ADR-0001); this document describes a second tier that must be
**observationally identical** to it.

Spec pin (every wasm-semantic anchor below, inherited through the specs it
builds on): `wasm-mcp` 0.2.16, `spec/main`
`d7b37e4170d8315f2f1283aed4e8076591a9a333` (ADR-0004),
`proposals/main` `e007b5c9f2e510573869985cbc635c7f4fc0b566`, verified via
`spec_version` at authoring time.

**Confidence markers.** Facts read from wasm-mcp at the pin, or from the
current source tree, are unmarked. Machine-code **encodings** (aarch64 A64
and x86-64) are asserted from knowledge of the ISAs and carry
**UNCONFIRMED** wherever a byte-level detail is not certain: an encoding bug
is not a design risk because the differential harness (§11) catches it
mechanically — a wrong instruction diverges from the interpreter on the first
input that exercises it. Never delete a marker.

---

## 0. What Track I is, and the invariants it inherits

The baseline JIT compiles one `TWasmIrFunction` (`Wasm.Ir`) to native
machine code at run time, in FreePascal, by **emitting raw bytes into an
executable buffer**. That the compiler is written in Pascal and emits bytes
is not a loophole in "FreePascal only" — it is the reason the rule matters
(AGENTS.md). There is no inline assembler for the *guest* code: the guest
code is data this unit writes. FPC inline asm / intrinsics are used only for
the host glue in §3 (the W^X toggle, the cache flush).

Hard obligations, inherited and non-negotiable — each is discharged in the
section named:

- **Observationally identical to the interpreter** (ADR-0001, interp-spec
  §8). Same results, same **which trap fires and when**, same NaN bits, same
  FP rounding, same side-effect order at a trap, same final memory / globals
  / table / GC-heap state, same reference identity, same epoch-observation
  points. A divergence is a bug, not a tier characteristic. §13 is the
  checklist; §11 is the proof.
- **Consumes the IR and nothing else** (ADR-0007/0012). The JIT never reads
  raw wasm bytes and never re-derives a spec rule the validator enforced. Its
  input is `TWasmIrModule`/`TWasmIrFunction`; validation has already run.
- **Emit the epoch check at every back-edge and function entry** (ADR-0006).
  §6.
- **Produce a stack map at every safepoint and keep live references
  discoverable** (ADR-0011). This is the obligation that would normally
  constrain register allocation; the design in §1 makes it fall out for free.
  §9.
- **Memory through one chokepoint, trapping identically across strategies**
  (ADR-0005/0010/0013). §7.
- **Traps unwind to the per-invocation trampoline** (ADR-0009); the JIT'd
  code calls `TrapNow` or faults, never raises `EWasmTrap` itself. §8.
- **A store is confined to one thread** (ADR-0008); no synchronisation on the
  code cache or the runtime structures the JIT'd code touches.
- **The error hierarchy is load-bearing**; a guest fault is `EWasmTrap`, an
  uncaught wasm `throw` is `EWasmException` (a sibling), reached through the
  trampoline. The JIT reuses the interpreter's exact `MSG_*` constants — it
  never re-spells a message, because for the messages it produces it **calls
  the same runtime helper the interpreter calls**.

The single design idea that discharges most of the above at once is in §1.

---

## 1. Scope & strategy — the register file stays in memory

### 1.1 The decision

**Track I is a single-pass template compiler over a memory-resident register
file.** For each `TWasmIrFunction`, walk `Code` once, in order, and emit for
each IR instruction a short, fixed machine-code template. The virtual
registers of the IR (`ir-spec.md` §3) are **not** allocated to machine
registers; they stay exactly where the interpreter keeps them — as a
contiguous slice of the interpreter's value-stack reservation, addressed
`Reg[k] = Values[Base + k]`. A template:

1. loads its operand slot(s) from memory into scratch machine registers,
2. computes,
3. stores the result to its destination slot in memory.

Machine registers are **scratch within one template only**. They are dead at
every IR-instruction boundary. No wasm value ever lives in a machine register
across an IR-op boundary.

This is the "register file in memory" baseline. It is the simplest correct
approach and it is chosen for Track I.

### 1.2 Why this, and not linear-scan into machine registers

The alternative — a real allocator that keeps hot values in machine
registers with spill slots — is faster but pays for it exactly where Track I
cannot afford to pay:

- **The stack map becomes hard.** ADR-0011 requires that at every safepoint
  the collector can find every live reference. With values in machine
  registers, that needs a per-safepoint liveness map describing which machine
  register (or spill slot) holds which reference at that program point — the
  second analysis ADR-0011 exists to avoid, and the exact thing Wasmtime
  moved *away* from (regalloc-derived maps caused miscompiles; ADR-0011
  cites this). With the register file in memory, the stack map is the frame
  itself: `TWasmGcFrame { Slots = @Values[Base], RefRegBits = @Fn^.RefRegBits[0],
  RegisterCount = Fn^.RegisterCount }` — **bit-identical to the interpreter's
  frame** (§9). The collector walks a compiled frame and an interpreted frame
  with the same code and cannot tell them apart.
- **Observational identity gets cheaper.** Because the frame layout, the
  zeroing discipline, and the safepoint set are the interpreter's, the JIT
  inherits the interpreter's answers for the whole structural surface (frame
  carve, exhaustion threshold, GC precision, tail-call replacement) for free,
  and only has to match the interpreter on the *arithmetic* of each op — which
  it does by inlining the simple ops and **calling the interpreter's own leaf
  functions** for the subtle ones (§3.3, §10, §13).
- **Correctness first is the Track I mandate.** ADR-0001 makes the JIT
  opt-in and differentially validated; its job is to be *right and faster than
  the interpreter*, not to be optimal. A later optimizer (a Track-I sub-wave
  or a successor track) earns the machine registers, and when it does it
  takes on the per-safepoint liveness-map obligation with its own measurement.

### 1.3 Where the speedup comes from (and the honesty about "rivals C/Rust")

A baseline JIT's win over the interpreter is **removing interpreter dispatch
overhead**, not optimal register allocation. The interpreter pays, per IR
instruction: a `case Op of` jump-table dispatch, an instruction-pointer
increment, a re-load of the instruction record, and the per-op field decode
(interp-spec §1.3). The template JIT pays none of that on the straight-line
spine — the ops are laid down as native code in order, branches are native
branches, and the epoch check is a fused load-compare-branch. That is the
measured win `wasmbench` will report (§13); it does not by itself reach
C/Rust throughput, because values still round-trip through memory slots. The
"performance rivals C/Rust by design" goal (AGENTS.md) is the *destination*
the tier ladder climbs toward; Track I is the first rung, and the memory
register file is deliberately the correctness-first rung. The machine-register
optimizer is where the remaining gap is closed, on `wasmbench` evidence, once
the baseline is proven identical.

### 1.4 The op split: inline vs. helper call

Not every op is inlined. The template for a "heavy" or "subtle" op is a call
to an existing Pascal runtime helper — the same one the interpreter uses — so
that identity is free and the trap/allocation/barrier logic stays
single-source. The split:

- **Inlined as native code** (the hot spine): `iroMove`; the four const ops;
  i32/i64 `add/sub/mul/and/or/xor/shl/shr_s/shr_u/rotl/rotr`; i32/i64
  test/compare (`eqz`, `eq`…`ge_u`); `iroSelect`; the control ops
  (`iroJump`, `iroBranchIf`, `iroBranchIfNot`, `iroBrTable`, `iroReturn`); the
  epoch check; and the frame-relative loads/stores those need. `clz/ctz/popcnt`
  inline via the ISA's count instructions where available, else a helper.
- **Helper call** (subtle, trapping, allocating, or barriered — call the
  interpreter's exact function): **all float ops** (call `Wasm.Interp.Numeric`
  — this is what buys NaN-bit and rounding identity, §13); div/rem and all
  float→int truncations (trapping numerics — call the same leaf that calls
  `TrapNow`); all conversions; all `v128` ops (call `Wasm.Interp.Vector`,
  §10); memory loads/stores/bulk (§7); table ops; `global.get/set` (the
  barrier is inside the store method); every GC op (`struct.*`, `array.*`,
  `i31.*`, `ref.test/cast`) via `Wasm.Runtime.Gc`; every call form via the
  dispatch helper (§4, §5); and the reference ops.

The rule of thumb: **if the interpreter dispatches to a leaf function or a
store/heap method for an op, the JIT emits a call to that same function.** The
JIT only *inlines* the ops the interpreter handles inline in its dispatch
loop with plain integer arithmetic. This keeps the machine-code surface small
(the risk surface for encoding bugs) and the identity surface trivial.

---

## 2. Which architecture first, and the host matrix

### 2.1 First backend: aarch64

The development host is **aarch64-darwin** (HANDOFF). The first backend is
therefore **aarch64 (A64)**: it is the only target that can be built, run, and
differentially tested on the dev machine without emulation, so the whole
develop→run→diff loop is local. **x86-64 is the second backend**, encoder-only
work behind the same driver once the aarch64 path is proven identical over the
corpus.

CI covers x86-64 + aarch64 × {linux, darwin} and a 32-bit windows leg. The
aarch64 and x86-64 backends both run their full differential gate on CI; the
Darwin and Linux legs differ only in the W^X host glue (§3).

### 2.2 64-bit only; 32-bit stays interpreter-only

The roadmap leaves it open "whether the baseline JIT and AOT target 32-bit at
all," and names "interpreter-only on 32-bit" as defensible (docs/roadmap.md,
ADR-0010). **Decision: the JIT is 64-bit only (aarch64 + x86-64). 32-bit
targets (the `i386-win32` leg, and any 32-bit UNIX) stay interpreter-only.**

Justification:

- The whole design is 64-bit-shaped. The register file, the flat slot
  addressing, `NativeUInt` pointer math, and the eventual guard-page inline
  path (§7.3) all assume a 64-bit address space. ADR-0010 keeps 32-bit on the
  explicit-bounds-check memory path with an index-width reduction; the JIT
  gains nothing there over the interpreter it would replace.
- **It costs no conformance.** The interpreter is the tier of record and runs
  everywhere (ADR-0001: "Platforms that forbid writable-executable memory
  remain fully supported at interpreter speed"). A 32-bit host runs the exact
  same, already-conformant interpreter; the JIT is a pure opt-in accelerator
  for the 64-bit hosts where it is worth the executable-memory machinery.
- W^X + guard pages + a second instruction encoder are real cost per target;
  spending them on 32-bit, which cannot host the guard-page optimization the
  JIT ultimately exists to unlock, is a poor trade.

The tier selector's compile predicate (§10.3) returns *false* on a 32-bit
build unconditionally, so every function transparently runs interpreted there.

---

## 3. W^X and executable memory (`Wasm.Jit.CodeBuffer`)

Generated code is written to a **writable** mapping and executed from an
**executable** one; the two permissions are never simultaneously granted to
the same page for the same access (W^X). `Wasm.Jit.CodeBuffer` owns this and
the byte-emission primitives. It is the one unit with per-OS `{$IFDEF}` glue.

### 3.1 macOS aarch64 — MAP_JIT + the per-thread W^X toggle

The dev host, and the fiddliest path. The macOS hardened runtime forbids a
page that is both writable and executable; a JIT page must be allocated with
`MAP_JIT` and the process must carry the `com.apple.security.cs.allow-jit`
entitlement (or run unsigned in development). The write/execute switch is
**per thread**, not per page:

1. Allocate the code region once (or per code block) with
   `mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE |
   MAP_ANON | MAP_JIT, -1, 0)`. `MAP_JIT` is required; the region is created
   in the executable-but-write-protected state.
2. To emit: call `pthread_jit_write_protect_np(0)` (make JIT memory writable
   for *this thread*), write the bytes, then `pthread_jit_write_protect_np(1)`
   (make it executable again).
3. Flush the instruction cache for the written range (§3.3) **after** step 2's
   protect-back and **before** first execution.

`MAP_JIT` and `pthread_jit_write_protect_np` are bound directly as `external
'c'` (they are not surfaced by FPC's RTL on this target) — the same
direct-binding pattern `Wasm.Runtime.Traps` already uses for `sigaltstack`.
Because the toggle is per thread and a store is single-threaded (ADR-0008),
there is no cross-thread W^X hazard: the thread that compiles is the thread
that runs. **UNCONFIRMED:** the exact `libc` symbol availability of
`pthread_jit_write_protect_np` on the minimum macOS target — a build-time
probe or a documented minimum version settles it.

### 3.2 Linux/POSIX (aarch64 + x86-64) — RW then mprotect RX

The portable path, no per-thread toggle:

1. `mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)`.
2. Write the bytes.
3. `mprotect(base, size, PROT_READ | PROT_EXEC)` — the page becomes RX,
   dropping W. This is the W^X transition.
4. Flush the instruction cache on aarch64 (§3.3).

A code block is written whole, then flipped to RX once; it is never patched
after being made executable (all forward-branch patching happens while the
buffer is still RW — §12.1 first milestone and the two-pass encoder in §4.3).
This avoids any RW↔RX churn.

`Wasm.Jit.CodeBuffer` presents one interface over both worlds:
`BeginWrite` / `EndWrite` bracket every emission (on macOS they toggle the
per-thread protection; on Linux `BeginWrite` is a no-op at allocation time and
`EndWrite` does the `mprotect` + flush), so the encoders (§4) never see the
platform difference.

### 3.3 Cache invalidation

- **aarch64:** the instruction and data caches are not coherent; after writing
  code the range must be flushed or the CPU may execute stale bytes. The
  operation is the sequence `dc cvau` (clean D-cache to point of unification)
  over the range, `dsb ish`, `ic ivau` (invalidate I-cache to PoU) over the
  range, `dsb ish`, `isb`. The FPC equivalent of C's
  `__builtin___clear_cache(begin, end)` is either (a) a tiny FPC `assembler`
  procedure emitting that sequence, or (b) binding `sys_icache_invalidate` on
  Darwin / the `cacheflush` syscall on Linux-aarch64. **Decision:** bind the
  platform call where one exists (`sys_icache_invalidate(base, len)` on
  Darwin; `cacheflush`/`__clear_cache` on Linux-aarch64) rather than
  hand-rolling the barrier sequence, because the cache-line size and the exact
  barrier flavour are details the OS routine already gets right. **UNCONFIRMED:**
  the precise Linux-aarch64 binding (`__clear_cache` via `external` vs. the
  `cacheflush` syscall number); a one-line probe settles it. This host glue is
  the one place FPC `assembler`/intrinsics are permitted (§0).
- **x86-64:** the I-cache is coherent with stores on the same core; no flush
  is needed. The `mprotect` (or, on the same thread, the ordinary store
  ordering) suffices. `Wasm.Jit.CodeBuffer.EndWrite` is a no-op flush on x86-64.

### 3.4 Code-cache lifecycle

- A compiled function is one **code block**: a contiguous region holding that
  function's native code plus its trap stubs (§8) and any constant island
  (large immediates, the function's `label map`). Blocks may be sub-allocated
  from a larger arena mapping to amortise `mmap`, but a block is the unit of
  ownership and its bytes are immutable once RX.
- **Ownership:** the code cache is owned by a per-store JIT context (§4.1),
  which is tied to the store's lifetime exactly as the interpreter's
  `TierContext` is (Store.pas, the `TierContext`/`TierContextFree` pair). When
  the store is destroyed, the JIT context frees every code block
  (`munmap`). Blocks are **never freed during execution** — there is no
  deopt, no code GC in Track I; a compiled function lives until the store
  dies. This mirrors the reservation-registry discipline in
  `Wasm.Runtime.Traps` (retired blocks are freed only when nothing can be
  running).
- The IR module is borrowed and outlives the instance (interp-spec §1.2), so a
  code block may hold raw pointers into the IR (e.g. `@Fn^.RefRegBits[0]`) for
  its whole life.

---

## 4. The tier seam and tier selection (ADR-0001)

### 4.1 How the JIT plugs in behind the seam

The interpreter registered itself by setting three store fields
(`RegisterInterpreter`, interp-spec §1.5, §7.3): `TierInvoke`,
`TierContext`, `TierContextFree`. The JIT is a **companion** on the same
store, not a replacement: it keeps its own per-store state (the code cache,
per-function call counters and compiled-entry pointers) in a JIT context, and
it hooks the same call boundaries the interpreter uses.

Two integration points, both minimal:

1. **A per-function compiled entry pointer.** Add one field to
   `TWasmFuncInst` (wfkWasm), `CompiledEntry: Pointer` (nil = not compiled),
   plus a `CallCount: UInt32`. This is a one-field store change, coordinated
   exactly like the `TierContext` addition was (an "O-" item, §12.4). The
   interpreter's `DoCall`/`DoReturnCall`/`call_indirect`/entry already look up
   `Store.Funcs[Addr]`; they gain **one predicted-not-taken branch**
   `if Funcs[Addr].CompiledEntry <> nil then → dispatch compiled`. When the
   JIT is not enabled the field is nil and the branch costs a load and a
   never-taken conditional — the standard, cheap tiering check.

2. **`RegisterJit(Store)`** allocates the JIT context, stores it beside the
   interpreter's (a second opaque pointer, or the JIT context embeds a pointer
   to the interpreter context it shares reservations with — §5.1), and leaves
   `TierInvoke` pointing at the interpreter. The interpreter stays the entry
   dispatcher; the JIT is reached through `CompiledEntry`.

The JIT does **not** get its own `TWasmTierInvokeProc`. A compiled function is
invoked by a native call to `CompiledEntry`, marshalled identically to a wasm
call (§5). Reusing the interpreter's activation context (its value stack,
depth accounting, GC chain) is what keeps stack-exhaustion, GC, and epoch
behaviour bit-identical (§5.1).

### 4.2 The tiering policy — compile hot, use from the next call, no OSR

- **Policy: compile-on-hot, whole function.** Each wfkWasm function carries a
  `CallCount`. On each call into it (from the interpreter's `DoCall` or from
  compiled code's dispatch), if `CompiledEntry = nil`, increment `CallCount`;
  when it crosses a threshold `WASM_JIT_HOT_THRESHOLD` (a tunable; default
  e.g. 10, and 1 for an "eager" test/bench mode), compile the whole function
  and store `CompiledEntry`. **This call still runs interpreted**; the
  compiled code is used from the *next* call.
- **No OSR (ADR-0001, interp-spec §8).** A running activation never migrates
  tiers. A hot loop entered under the interpreter finishes under the
  interpreter; a function is only ever run compiled from a fresh entry where
  `CompiledEntry` is already set. This is why "used from the next call" is
  correct and sufficient: the back-edge safepoints (§6) are structurally where
  an OSR entry *would* go, so nothing here forecloses a future OSR, but Track I
  does not build one.
- **Alternative rejected: compile-eagerly-on-first-call.** Simpler to reason
  about but pays full compile latency on every function's first use even for
  functions called once (module `_start`, one-shot init). Compile-on-hot skips
  cold functions entirely. Both are one `if` apart in the driver; the
  threshold is a `wasmbench`-tuned constant, and the differential harness
  (§11) forces the threshold to 1 to compile *everything* so the corpus
  exercises the compiled path maximally.

### 4.3 The driver (`Wasm.Jit`)

`Wasm.Jit` is the compiler driver: `JitCompileFunction(Ctx, Fn) : Pointer`
walks `Fn^.Code` once and drives the active backend's encoder (§12) to emit a
code block, returning its entry pointer. It also owns:

- the **compile predicate** `JitCanCompile(Fn) : Boolean` (§10.3) — the scope
  fence that makes the baseline shippable by falling back to the interpreter
  for anything it does not yet handle;
- **branch patching**: the encoder runs two passes, or one pass with a patch
  list. A **label map** `IrInstrIndex → nativeOffset` is filled as each IR
  instruction's code is emitted; forward branches record a patch site
  (native offset + branch kind) and are back-patched once the whole function's
  label map is known, while the buffer is still RW (§3.2). Loop back-edges
  resolve immediately (the loop header's native offset is already in the
  label map — the interpreter's IR already resolved targets to instruction
  indices, `ir-spec.md` §4).

### 4.4 A compiled function calling another function

A call op inside compiled code cannot know statically whether the callee is
interpreted, compiled, or a host function. The compiled call sequence
therefore emits a call to a **dispatch helper** `JitDispatchCall(Ctx, Addr,
argSlots, resultSlots)` (Pascal), which is the single place the tier decision
is made for a wasm→wasm call:

- `Store.Funcs[Addr].Kind = wfkHost` → the interpreter's `HostCall` path
  (marshal, call callback, marshal back) — identical to interp-spec §4.
- compiled callee (`CompiledEntry <> nil`) → native-call the entry (§5).
- interpreted callee → re-enter the interpreter's `Run` for that callee on the
  shared context (`JitCallInterp`, §5.1), which is just the interpreter
  executing one nested activation.

Direct-`iroCall` (statically known `funcidx`) can be specialised later to
skip the helper when the callee is already compiled at emit time, but the
baseline always goes through the helper for uniformity and correctness; that
is a measured optimization, not a Track I requirement. `iroCallIndirect` and
`iroCallRef` **always** go through a helper that does the resolution
(bounds→null→type order for indirect; null check for ref) exactly as the
interpreter does (§8.3), then dispatches like `JitDispatchCall`.

### 4.5 Tail calls (`return_call*`) — O(1) frame replacement

The interpreter replaces the current frame in place (interp-spec §1.4,
`DoReturnCall`) with guaranteed O(1) stack growth. The compiled tail-call
sequence must do the **same**: it calls a helper `JitReturnCall(Ctx, Addr,
argSlots)` that performs the interpreter's exact replacement (collect args to
the context scratch, exhaustion-check against the *replaced* frame's base,
pop the old GcFrame, reuse the same `Base`, zero, re-marshal, re-push) and
then transfers control to the callee. Because the callee may be compiled or
interpreted, and because a self-tail-loop must run in bounded native stack,
the transfer must **not** grow the native (C) call stack per tail call. The
concrete mechanism: `JitReturnCall` replaces the frame and returns a
"continue with this entry" token to a **trampoline loop** the compiled entry
prologue sits under (§5.2) — the same shape the interpreter uses to keep tail
recursion O(1) without Pascal recursion. A million-iteration self-tail-loop
runs in bounded native stack and bounded value stack, the acceptance test the
interpreter already passes (interp-spec §5.2). A `return_call` to a host
function does the host call and routes its results to this frame's caller
(interp-spec §4.4), via the same helper.

---

## 5. Calling convention and frame layout

### 5.1 The frame IS the interpreter's frame

A compiled function shares the interpreter's `TWasmInterpContext` (the two
fixed reservations: the value stack `Values`/`ValueCap`/`ValueTop` and the
activation array `Acts`/`Depth`, interp-spec §1.1). The JIT context (§4.1)
holds a pointer to it. Frame entry and exit are **not** open-coded in machine
code; the prologue and epilogue call the interpreter's frame helpers (factored
out to be shared — §12.1), so a compiled frame is carved, zeroed, pushed, and
popped by the *exact same Pascal code* that does it for an interpreted frame:

- **Prologue** (`JitEnterFrame(Ctx, Fn) : NativeUInt` returns `Base`):
  exhaustion-check `Depth`/`ValueTop` against the caps (→
  `TrapNow(wtkStackExhausted)`, the same threshold, §13); carve the register
  file `NewBase := ValueTop; ValueTop := NewBase + Fn^.RegisterCount`; **zero
  every slot** (`ValueZeroSlots`, GC-1 obligation 1 — refs read null, numeric
  locals default 0); set up the `TWasmGcFrame` (Slots, RefRegBits,
  RegisterCount) and `Heap.PushFrame` it **before the first safepoint**;
  `Inc(Depth)`.
- **Body** operates on `Reg = @Values[Base]` held in a pinned machine register
  (§5.3).
- **Epilogue** (`iroReturn`): marshal the return block `[ReturnRegBase..)` to
  the caller's destination slots (or to the entry `AResults` for an entry
  frame), `Heap.PopFrame`, `ValueTop := Base`, `Dec(Depth)`; native `ret`.

Because the carve/zero/push/pop is the interpreter's, the GC contract (§9),
the exhaustion threshold, and the null/default-init discipline are identical
by construction, not by parallel re-implementation. Params arrive and results
leave through the **flat slot array**, exactly matching
`InterpTierInvoke`/`DoCall`: on an entry, `AParams[i]` is copied into param
slots `[0..ParamCount)` (respecting `LocalRegs`/`ResultRegs` for v128's
two-slot values, `ir-spec.md` §... — a v128 occupies two adjacent slots,
never a reference, so marshaling copies two slots); results are copied out via
`ResultRegs`. This is the same marshaling the interpreter does, so a compiled
function and an interpreted function are call-compatible in both directions
(§4.4).

### 5.2 The compiled entry and the tail-call trampoline

`CompiledEntry` points at a small **entry stub** that: sets up the pinned
registers (§5.3), calls `JitEnterFrame`, and then enters the function body.
On `return_call*`, the body does not `ret`; it calls `JitReturnCall` (§4.5)
and loops back to dispatch the replacement callee's entry — so a chain of
tail calls runs under one native stack frame (the trampoline loop), giving the
O(1) property. On ordinary `iroReturn`, the epilogue runs and the stub
`ret`s to its native caller (the interpreter's `DoCall`-compiled-branch, or
another compiled function's call site, or `JitDispatchCall`).

### 5.3 Pinned machine registers

The baseline pins a small, fixed set for the whole function body (callee-saved
where the ABI requires them to survive helper calls):

| role | aarch64 (A64) | x86-64 (SysV / Win64) | notes |
| --- | --- | --- | --- |
| `Reg` = `@Values[Base]` (register-file base) | `x19` | `rbx` | callee-saved; survives helper calls |
| `Ctx` (interpreter/JIT context) | `x20` | `r12` | callee-saved; passed to every helper |
| `Store` / `Instance` (for globals, memory, calls) | `x21` | `r13` | callee-saved |
| scratch (operand load / compute / address) | `x0..x17` | `rax, rcx, rdx, r8..r11` | caller-saved; dead at op boundaries |

The **epoch word** and the **memory base/bound** are *not* pinned in the
baseline: they are re-loaded from `Ctx`/`Store` at each use. Pinning them is a
later optimization (the epoch cache lives in a register across a loop; the
memory base folds into loads). The baseline reloads, which is simpler and
still far cheaper than interpreter dispatch. The choice of *which* registers is
UNCONFIRMED against the precise FPC-emitted ABI at the call sites into Pascal
helpers — the encoder must respect the platform C ABI for helper calls
(argument registers, stack alignment: 16-byte on both ISAs), and the
differential harness plus a handful of targeted helper-call tests confirm it.
On Windows x64 (not a Track I target for the JIT — §2.2 — but noted for a
future port) the shadow space and different callee-saved set would apply.

### 5.4 Prologue/epilogue and the GC push/pop, precisely

The prologue's `Heap.PushFrame` happens **after** zeroing and arg marshaling
and **before** the body's first instruction (which may be an allocation or a
call — function entry is an implicit safepoint, ADR-0011). The epilogue's
`Heap.PopFrame` happens **after** the result copy (a plain value copy, no
allocation). Between the last in-body safepoint and the pop nothing can
collect. This is the interpreter's discipline verbatim (interp-spec §2.3),
reached through the shared helpers.

---

## 6. The epoch check (ADR-0006)

At every **back-edge** (an `iroJump` carrying `IR_JUMP_SAFEPOINT` in its
`Imm`, `ir-spec.md` §1.4) and at **function entry**, the compiled code emits
the same cheap inline sequence the ADR mandates: load `Store.Epoch`, compare
against the value captured at frame entry (`EpochCache`), and on inequality
call the trap stub `TrapNow(wtkEpochInterrupt)` (→ `MSG_TRAP_EPOCH_INTERRUPT
= 'interrupt'`). Concretely at a back-edge, before taking the branch:

```
; aarch64 sketch (UNCONFIRMED encodings)
ldr   x9, [x21, #EPOCH_OFF]     ; x21 = Store; load Store.Epoch
cmp   x9, xEPOCHCACHE           ; compare against frame-entry snapshot
b.ne  epoch_trap_stub           ; changed -> trap 'interrupt'
b     loop_header               ; the resolved back-edge target
```

`EpochCache` is captured once at entry (a slot in the frame, or a pinned
register if §5.3's optimization is taken; baseline keeps it in a frame slot
and reloads, or in a callee-saved register reserved for it). Function-entry
safepoints do **not** poll (interp-spec §3.5: nothing to poll for — the
collector is allocation-triggered and the epoch is only meaningful at
back-edges where a loop could otherwise spin uninterruptibly); entry is a GC
safepoint (frame pushed) but not an epoch poll. The epoch check is emitted at
**exactly** the `IR_JUMP_SAFEPOINT` sites, so an interrupt is observed at the
same program points as under the interpreter (§13, item 6). This is the same
safepoint set as the GC stack map (§9) — deliberately shared, per ADR-0006/0011.

The epoch trap stub is one per code block (§8): it sets up the
`TrapNow(wtkEpochInterrupt)` call and does not return. Emitting the check as a
call-to-a-stub, rather than an inline `TrapNow`, keeps the hot back-edge to
three instructions and moves the cold path out of line.

---

## 7. Memory access and the chokepoint (ADR-0005/0010/0013)

### 7.1 The decision: explicit bounds checks in the baseline

The interpreter reaches memory only through the chokepoint (`MemAddressAt` /
`MemRangeAt` → `Wasm.Runtime.Memory.MemAddress`/`MemRange`), and it uses an
**explicit full-precision bounds check on every strategy** — including
guard-page memories — because in-process guard-page fault delivery proved
**unreliable**: the source comment in `Wasm.Runtime.Memory.MemCheck` records
that the first SIGSEGV in a fresh process surfaced through the FPC RTL as
`EStackOverflow` instead of reaching the handler→trampoline, aborting
`address.wast` on `i32.load8_u offset=1` at index `0xFFFFFFFF`. The guard-page
no-check fold was therefore **removed** from the interpreter and explicitly
**deferred to a future JIT tier** that "emits inline accesses and can first
prove signal→trampoline delivery robust in-process."

**Decision: the Track I baseline also uses explicit bounds checks, and does
not rely on guard-page faults.** Two forms, both correct and both
observationally identical to the interpreter:

1. **First sub-wave — call the chokepoint.** A load/store emits a call to a
   thin helper `JitMemAddress(Store, memIdx, index, offset, size) : PByte`
   that is `Store.MemAddressAt` (it runs `MemCheck` and traps
   `wtkMemoryOutOfBounds` via the trampoline, or returns a checked pointer);
   the template then does the inline load/store from that pointer. This is the
   *simplest correct* path — it uses the exact chokepoint, so identity is free
   — and it is already faster than the interpreter because it removes dispatch
   overhead around the access.
2. **Second sub-wave (measured) — inline the explicit check.** Emit inline:
   load `Mem.ByteSize` and `Mem.Base` from the instance/store at known
   offsets, compute `index + offset + size`, unsigned-compare against
   `ByteSize`, branch to the OOB trap stub on failure (matching
   `MemInBounds`'s unsigned `UInt64` comparison, which subsumes the 32-bit
   index-width reduction — but 32-bit is interpreter-only anyway, §2.2), then
   inline the load/store from `Base + index + offset`. This is still an
   **explicit-check** strategy (`wmsBoundsChecked`-shaped semantics), so it
   traps at the same access with the same message as the interpreter. Bulk ops
   (`memory.copy/fill/init`) always call the range helpers (`MemRangeAt`),
   which check before any write (write-nothing-on-trap, §13 item 4).

Justification: **correctness and observational identity first.** The epoch
check (§6) already proves the "call `TrapNow` from generated code and unwind
to the trampoline" path works from compiled code on ordinary ground; explicit
memory checks reuse exactly that proven path and **avoid the fragile
in-process fault delivery the earlier review flagged**. `memory.grow` and
`memory.size` call the store methods (grow never traps, never collects).

### 7.2 Why not guard-page inline access now

Guard-page inline access (emit the load/store with *no* check and let the MMU
fault into the signal handler → trampoline → trap) is the optimization the
whole guard-page reservation exists for, and it is where the JIT would finally
pay it off. It is **deferred to a Track I follow-up sub-wave** because it
requires proving, in-process, the exact thing the interpreter could not rely
on:

- the SIGSEGV/SIGBUS from a faulting *JIT'd* access reaches `WasmFaultHandler`
  (not the RTL's `EStackOverflow` interception) — the security/robustness
  work the memory comment names;
- the handler attributes the fault to the right memory via the **reservation
  registry** (`ReservationContains`, already built and populated for
  guard/guard-assisted strategies) and maps the **faulting PC** in generated
  code to the correct trap unwind — the reservation registry gives the memory
  attribution; the trampoline (`CurrentTrampoline`) is thread-local and
  already installed around every guest entry, so a fault in compiled code
  `LongJmp`s to it exactly as ADR-0009 set up;
- the alternate signal stack (`EnsureAltSignalStack`) and cache/altstack
  interactions hold for the compiled-code fault case.

The guard-page reservation and the fault handler **stay mapped and installed
as latent capability** (the memory unit keeps them); Track I's baseline simply
does not use them for access. When the follow-up lands, the exact requirements
above are its acceptance criteria, and it is gated behind a `wasmbench`
measurement showing the inline access is worth the robustness work. Until
then, explicit checks are correct, identical, and faster than the interpreter.

### 7.3 The guard-page follow-up, stated for the record

The follow-up sub-wave's inline load/store emits *just* the access; the
faulting-PC→trap mapping needs a side table (native PC range → the trap kind
`wtkMemoryOutOfBounds`, or simply "any fault in this block's access region is
OOB") consulted by an extended `WasmFaultHandler`. This is real per-tier
signal-path work (ADR-0009 rejected PC-rewriting-per-tier as the *general*
trap mechanism, but a fault→trampoline map is compatible with the trampoline
design). It is out of Track I's baseline scope and named here so the roadmap
inherits it in writing.

---

## 8. Trap generation (ADR-0009)

### 8.1 Every trap is a call to a runtime helper that unwinds to the trampoline

The interpreter produces each trap by calling `TrapNow(kind)` (or
`TrapNowDetail(kind, index)`), which records the kind on `CurrentTrampoline`
and `LongJmp`s to the per-invocation trampoline, where `RaiseTrapDirect`
allocates the message and raises `EWasmTrap` on ordinary ground
(`Wasm.Runtime.Traps`). **The JIT'd code does the same**: at a trap condition
it branches to a per-kind **trap stub** in its code block, and the stub calls
`TrapNow(kind)`. Because the message and kind come from the same
`Wasm.Runtime.Traps` machinery, **the JIT's trap messages match the
interpreter's for free** — the JIT never spells a message. `TrapNow` never
returns; the stub needs no epilogue.

Every trap the interpreter can raise is reachable from compiled code the same
way: `wtkDivideByZero`, `wtkIntegerOverflow` (div/rem — inlined checks or the
same leaf), `wtkInvalidConversion`/`wtkIntegerOverflow` (float→int trunc — the
same `Wasm.Interp.Numeric` leaf, which itself calls `TrapNow`),
`wtkMemoryOutOfBounds` (§7), `wtkTableOutOfBounds`/`wtkUndefinedElement`/
`wtkUninitializedElement`/`wtkIndirectCallTypeMismatch` (call_indirect and
table ops — helper), the split null family (`wtkNullStruct/Array/Func/I31Reference`
and the bare `wtkNullReference` — the GC/ref helpers already raise the split
kinds, interp-spec §3.10 O-5), `wtkCastFailure`, `wtkArrayOutOfBounds`,
`wtkUnreachable` (`iroUnreachable` → a direct call to `TrapNow(wtkUnreachable)`),
`wtkStackExhausted` (the shared `JitEnterFrame`/`JitReturnCall` exhaustion
check, §5.1), and `wtkEpochInterrupt` (§6).

### 8.2 Trap timing and order must match

ADR-0001 makes *when* a trap fires part of the contract. The generated code
must check conditions in the **same order** the interpreter does, so the same
trap fires for a given state:

- `call_indirect`: **bounds → null → type** (interp-spec §3.6; confirmed
  `undefined element`, then `uninitialized element`, then `indirect call type
  mismatch`). The baseline routes `call_indirect` through one helper that does
  exactly this sequence, so order is inherited, not re-implemented.
- `div_s`: divide-by-zero **before** the `INT_MIN / -1` overflow check;
  `rem_s`: divide-by-zero, and `INT_MIN % -1` does **not** trap (result 0).
  Inlined checks emit the same two branches in the same order, or call the same
  leaf.
- bulk memory/table/array ops: the **range check precedes any write**
  (write-nothing-on-trap) — guaranteed because these are helper calls into the
  chokepoint / Gc helpers that check first.

Because the subtle-order ops are all helper calls to the interpreter's own
code, timing/order identity is structural. Only the inlined ops (div/rem
inline form, memory inline-check form) require the encoder to lay the branches
in the interpreter's order — a small, testable surface.

### 8.3 Wasm exceptions (`throw`/`throw_ref`/`try_table`) are not compiled

See §10.2: a function containing any EH op is not compiled; it runs
interpreted, so its exception unwind is the interpreter's (`EWasmException`,
the sibling route, eh-spec §9). The JIT never has to interoperate with the
throw unwind in Track I.

---

## 9. GC safepoints and stack maps (ADR-0011)

### 9.1 The stack map is the frame — trivially

At every safepoint — function entry, back-edges, and every allocation /
runtime-call site (the `IrOpIsSafepoint` set: `iroCall*`, `iroReturnCall*`,
`iroStructNew*`, `iroArrayNew*`, `iroRefI31`, and back-edge `iroJump`,
`ir-spec.md` §1.4) — the collector walks the compiled frame's `TWasmGcFrame`
and finds every live reference, **because §1's design keeps the register file
in memory as the interpreter's frame**. The compiled prologue publishes the
same record the interpreter publishes:

```
GcFrame.Slots        := @Values[Base];        { the register file, in memory }
GcFrame.RefRegBits   := @Fn^.RefRegBits[0];   { the IR's precomputed projection }
GcFrame.RegisterCount:= Fn^.RegisterCount;
GcFrame.Instance     := Pointer(Instance);
Store.Heap.PushFrame(@GcFrame);
```

`MarkFrames` iterates the set bits of `RefRegBits` over `[0, RegisterCount)`
treating `Slots[i].Ref` as a root (`Wasm.Runtime.Gc`, verified). It cannot
distinguish a compiled frame from an interpreted one — same `Slots`, same
`RefRegBits`, same `RegisterCount`. **The stack map falls out of the
memory-register-file choice; there is nothing extra to produce.** This is the
key simplification and the whole reason §1 chose the memory register file.

### 9.2 The invariant the encoder must preserve

The trivial stack map is correct **only if** every live wasm value is in its
memory slot at every safepoint. The baseline guarantees this by construction:
each template stores its result to the destination slot immediately, and
machine registers are scratch that is dead at IR-op boundaries (§1.1).
Safepoints occur *at* IR-op boundaries (a call op, an alloc op, a back-edge
jump), so at every safepoint all live values are in memory and no wasm
reference is in a machine register. The encoder must therefore **never keep a
wasm value in a machine register across a template boundary** — this is the
one discipline the baseline codegen must hold, and it is the natural shape of
a template compiler anyway.

Ref-typed slots read null until written (the prologue zeroes the whole
register file, GC-1 obligation 1), and a register has one static type for the
whole function (monotonic temporaries, `ir-spec.md` §3.2), so `RefRegBits`
names precisely the ref slots — over-approximation impossible (only ref slots
traced), under-approximation impossible (every ref slot traced). Same
precision as the interpreter, same reason.

### 9.3 Allocation sites are safepoints — and they are helper calls

Every op that allocates (`struct.new`, `array.new*`, and `ref.i31`
conservatively) is a **helper call** into `Wasm.Runtime.Gc` (§1.4). The
collector may run inside that call; the frame is on the chain and walkable
(§9.1), and the interpreter's **publish-first** discipline (write the new
object into its destination slot before any subsequent field write that could
allocate — interp-spec §3.10) is the helper's discipline, inherited. No
machine-register liveness map is needed anywhere in the baseline — the deferred
win of the memory-register-file choice.

### 9.4 What a future machine-register JIT would owe

A later optimizer that keeps values in machine registers must emit a
**per-safepoint liveness map** (which machine register / spill slot holds
which reference at each safepoint) and register it so the collector can find
those roots — the analysis ADR-0011's IR-derived approach avoids for the
baseline. Deferred, named for the record.

---

## 10. SIMD and EH in the JIT

### 10.1 SIMD (`v128`): call the shipped leaf functions

For a baseline, the simplest correct approach for the `v128` ops is to emit a
**call to the same scalar/vector leaf function the interpreter uses**
(`Wasm.Interp.Vector`) rather than native NEON/SSE/AVX codegen. This
**guarantees observational identity** — the per-lane NaN discipline, the
saturating/narrowing arithmetic, and the relaxed-SIMD deterministic profile
(R=0) are the interpreter's exact bits (simd-spec §9), and a v128 occupies two
adjacent 8-byte slots (never a reference), so the memory register file and the
GC walk handle it unchanged. **Recommendation: Track I compiles `v128` ops as
leaf-function calls.** Native SIMD codegen (NEON on aarch64, SSE/AVX on
x86-64) is a later, `wasmbench`-gated optimization that must reproduce the leaf
functions' exact lane/NaN/relaxed semantics — a real cost, deferred. Until it
lands, `v128` functions still tier up and still run faster than the
interpreter (dispatch removed around the leaf calls).

Alternatively, and even simpler for the very first waves: SIMD is a *later
sub-wave* and the compile predicate (§10.3) can decline `v128`-containing
functions entirely, leaving them interpreted, until the leaf-call templates
land. Decision: **decline v128 functions in the first numeric/control/call/
memory/GC waves; add v128-via-leaf-calls as a distinct later wave.** Both
choices are observationally identical (same interpreter or same leaf
functions); the predicate is the switch.

### 10.2 EH (`throw`/`throw_ref`/`try_table`): not compiled

The wasm exception unwind is complex (an explicit walk over the activation
stack, tag-address matching, the `EWasmException` sibling route, eh-spec §9).
**Track I's JIT does not compile a function that contains any EH op**
(`iroThrow`, `iroThrowRef`, or that carries a non-empty `Handlers` table from a
`try_table`). The compile predicate (§10.3) returns false for such functions,
and they run **interpreted** — which is observationally identical because it
*is* the interpreter. This is a clean scope fence: no throw unwind has to
interoperate with compiled frames in Track I, and the corpus's EH files pass
under the JIT run exactly because those functions transparently fall back.

A `try_table` whose body never actually throws is still lowered to
straight-line IR by Track B (`try_table` "vanishes at lowering",
`ir-spec.md` §1.2), and the interpreter runs such a body normally. The
predicate keys on the presence of `iroThrow`/`iroThrowRef` and a non-empty
`Handlers` table, so a function that merely *has* a `try_table` region but
contains a throw is declined; a function with no EH ops at all compiles. (A
finer predicate — compile a `try_table` body with no reachable throw — is a
possible later refinement, not baseline.)

### 10.3 The compile predicate is the scope fence

`JitCanCompile(Fn) : Boolean` is what makes a shippable baseline out of a
partial op-coverage compiler: it returns true only if **every** op in
`Fn^.Code` is one the active backend can emit. Anything else — an EH op, a
`v128` op before the SIMD wave, any op a wave has not yet implemented, or a
32-bit build (§2.2) — makes it return false, and the tier selector leaves
`CompiledEntry = nil` so the function **transparently runs on the
interpreter**. This is the key to shipping incrementally and always correctly:
**compile the common case, fall back to the interpreter for the rest, always
identical.** As waves add op coverage, the predicate's declined set shrinks;
the corpus passes identically under the JIT for the compilable subset at every
wave, and the declined subset is the interpreter's already-passing behaviour.

---

## 11. The differential test harness — how correctness is proven (ADR-0001)

The JIT's entire correctness argument is "identical to the interpreter." The
harness turns that into a mechanical check, and it is the single most
important testing decision in the track.

### 11.1 Force-tier control

Add a **force-tier** control to the runtime, used only by tests/harness:

- **force-interpret**: the tier selector never compiles (predicate forced
  false, or `CompiledEntry` never set) — the current behaviour, the reference.
- **force-JIT**: the threshold is forced to 0/1 so **every compilable function
  is compiled and run compiled** from its first eligible call; declined
  functions (§10.3) still run interpreted (that is correct — they are the
  interpreter's reference behaviour, and both runs agree on them trivially).

This is a per-store setting on the JIT context (`RegisterJit(Store,
ForceMode)`), not a public embedder API (ADR-0001 forbids embedder tier
selection); it exists for the harness and `wasmbench`.

### 11.2 Run every module under both tiers and diff everything

The differential runner takes a module (from the existing corpus, the fixture
corpus, or a unit test), instantiates it **twice on two fresh stores** — once
force-interpret, once force-JIT — and, for each exported action / assertion,
compares **everything the oracle can see** (ADR-0001: "compare which trap
fires and when, and the final contents of exported memories and globals"):

- **return values** — bitwise (NaN payloads, ±0), per-lane for v128,
  reference identity for refs;
- **trap outcome** — did it trap, which kind, which **message** (prefix-match
  as the corpus does), and — where observable via a deterministic probe —
  *when* (e.g. a module that writes a marker to memory before a trapping
  access proves write-nothing-on-trap and ordering);
- **final state** — the contents of every exported memory, every exported
  global, table contents, and (where reachable) GC-heap-observable state, after
  the action;
- **exit behaviour** — `EWasmExit` code, uncaught `EWasmException` vs.
  `EWasmTrap` classification.

Any difference is a JIT bug and fails the test with both sides' values.

### 11.3 The corpus is the JIT's conformance net for free

`Wasm.Wast.Runner` already assembles, decodes, validates, instantiates, and
executes the whole corpus through the interpreter (~65,184 pass). The JIT adds
**no new corpus assertions** — it **re-runs the same assertions under a new
tier**. The harness hook: a runner mode (`wasmspec --tier=jit`, or a
`Wasm.Wast.Runner.Test` variant) that runs each executing assertion
(`assert_return`/`assert_trap`/`assert_exhaustion`/`assert_exception`/`invoke`)
under force-JIT and compares against the interpreter's verdict. The deliverable
claim is **"the corpus passes identically under the JIT for the compilable
subset"** — not a new pass count. Declined functions (EH, pre-SIMD-wave v128)
run interpreted under both, so they agree by construction. Because the
interpreter is already conformant, an identical JIT is conformant, and the
65k-assertion corpus becomes the JIT's net at zero authoring cost.

### 11.4 Unit-level differential tests

Below the corpus, each wave (§12) ships direct differential unit tests:
hand-build a module (literal bytes → decode → validate → instantiate), invoke
an export force-interpret and force-JIT, assert equal. The first milestone
(§12.1) is exactly this for `i32.add`. Trap, memory-state, and tail-call cases
follow per wave.

---

## 12. Unit layout and wave plan

### 12.1 Units (bottom-up; `Wasm.Jit.*` sit above `Wasm.Interp`, below the apps)

- **`Wasm.Jit.CodeBuffer`** — executable-memory allocation and the W^X
  transition (§3): `mmap`/`MAP_JIT`, `pthread_jit_write_protect_np`,
  `mprotect`, cache flush, and raw byte/word emission primitives
  (`EmitByte`/`EmitU32`/`EmitU64`, the label map, the patch list). The one unit
  with per-OS `{$IFDEF}` and the permitted host-glue asm/intrinsics. Depends on
  `Wasm.Core` and the OS bindings only.
- **`Wasm.Jit.Arm64`** — the A64 encoder and per-op templates: the instruction
  emitters (mov/movz/movk, ldr/str frame-relative, add/sub/mul, logical,
  shifts, cmp, conditional branches, bl to a helper, ret) and the template for
  each inlined IR op. Depends on `Wasm.Jit.CodeBuffer`, `Wasm.Ir`.
- **`Wasm.Jit.X64`** — the x86-64 encoder and templates (second backend).
  Same shape as Arm64. ModRM/REX/immediate encoding is the fiddly part;
  UNCONFIRMED at the byte level, caught by the harness.
- **`Wasm.Jit`** — the driver: `JitCompileFunction` (the single-pass walk that
  drives the active backend), `JitCanCompile` (the predicate, §10.3), the
  tiering policy and `CallCount`/`CompiledEntry` management (§4), the dispatch
  helpers (`JitDispatchCall`, `JitCallInterp`, `JitReturnCall`,
  `JitMemAddress`), `RegisterJit`, and the per-store JIT context (the code
  cache). Depends on `Wasm.Jit.Arm64`/`.X64`, `Wasm.Interp` (for the shared
  frame helpers, the numeric/vector leaves, and re-entering `Run`),
  `Wasm.Runtime.*`.
- **`Wasm.Jit.Diff`** (or a mode in `Wasm.Wast.Runner` + a
  `Wasm.Jit.Test.pas`) — the differential harness (§11): force-tier control and
  the two-tier comparison. The corpus hook lands in `wasmspec` (`--tier=jit`).
- Co-located tests: `Wasm.Jit.CodeBuffer.Test`, `Wasm.Jit.Arm64.Test`,
  `Wasm.Jit.X64.Test`, `Wasm.Jit.Test`.

Layering rule: nothing in `Wasm.Runtime.*` or `Wasm.Interp` depends on
`Wasm.Jit.*` (that would invert the seam). The interpreter reaches the JIT only
through the `CompiledEntry` field it checks at call sites (§4.1); the JIT
reaches the interpreter through the shared helpers it calls. The one shared
lower dependency is the frame-carve/marshal helpers, which are factored out of
`Wasm.Interp` (exposed in its interface, or lifted to a small
`Wasm.Interp.Frame` unit) so both tiers call the identical code (interp-spec
§7.1 already anticipates this split).

### 12.2 The first milestone

**Compile a trivial function — `(func (param i32 i32) (result i32) local.get
0; local.get 1; i32.add)` — on aarch64, run it, diff against the
interpreter.** This exercises the whole spine end to end at minimum size:
`Wasm.Jit.CodeBuffer` allocates and flips W^X and flushes the cache;
`Wasm.Jit.Arm64` emits the prologue (call `JitEnterFrame`), two frame-relative
loads (the `iroMove`s that `local.get` lowered to, or direct slot reads), an
`add`, a store to the return slot, the epilogue (marshal + `JitLeaveFrame` +
`ret`); the driver wires `CompiledEntry`; the differential test invokes it
both tiers and asserts equal. When this passes on the dev host, every
subsequent op is an incremental template plus a differential test.

### 12.3 Waves (each gate-green, each differentially tested)

- **Wave 1 — `Wasm.Jit.CodeBuffer` + the first milestone.** W^X on
  macOS-aarch64 and Linux-aarch64, cache flush, byte emission, the label map,
  and the `i32.add` end-to-end diff (§12.2). No op coverage beyond the
  milestone; proves the executable-memory machinery and the seam.
- **Wave 2 — numeric + parametric + variable + control + local-move (aarch64).**
  The inlined hot spine (§1.4): const, move, i32/i64 integer arithmetic and
  compares, select, jumps/branches/br_table, return, the epoch check (§6), and
  the frame prologue/epilogue via the shared helpers. Trapping numerics
  (div/rem — inline checks or the same leaf) and **all float ops via
  `Wasm.Interp.Numeric` calls** (identity, §13). Predicate declines everything
  else. Differential unit tests per family + the numeric/control corpus subset
  under `--tier=jit`.
- **Wave 3 — calls (aarch64).** `iroCall`/`iroReturnCall` via
  `JitDispatchCall`/`JitReturnCall`, `iroCallIndirect`/`iroCallRef` via the
  resolution helpers (bounds→null→type / null), host-call interop, and the
  tail-call trampoline loop (O(1), §4.5, §5.2). Diff: `call*.wast`, a
  1e6-iteration self-tail-loop in bounded stack, deep non-tail recursion trapping
  `call stack exhausted` at the same logical depth.
- **Wave 4 — memory + table + reference + global (aarch64).** Loads/stores/bulk
  via the chokepoint helper (§7.1 form 1), table ops, ref ops, `global.get/set`
  (barriered store method). Diff: `memory*.wast`, `table*.wast`, `address.wast`
  (OOB traps identical), reference cases.
- **Wave 5 — GC (aarch64).** `struct.*`, `array.*`, `i31.*`, `ref.test/cast`,
  `br_on_cast*` via `Wasm.Runtime.Gc` helpers (safepoints, publish-first,
  §9.3). Diff: the GC corpus (minus the M7 cross-hierarchy residue the
  interpreter also fails, interp-spec §3.9 — both tiers fail identically, which
  is a *pass* for the differential oracle).
- **Wave 6 — `v128` via leaf calls (aarch64).** Add the `Wasm.Interp.Vector`
  call templates; predicate stops declining v128 functions (§10.1). Diff: the
  SIMD corpus under `--tier=jit`, per-lane.
- **Wave 7 — x86-64 backend.** `Wasm.Jit.X64` reimplements the templates for
  x86-64 behind the same driver; the differential gate runs on the x86-64 CI
  legs. No new semantics — encoder work only.

Waves 2–6 are independently testable by direct invoke of hand-built modules
before the full corpus mode; the corpus `--tier=jit` mode is the running proof
at each wave. Waves 4 and 5 can proceed in parallel once Wave 3 lands
(disjoint op families, disjoint helpers).

### 12.4 What is staged, and the mechanism

Everything staged is behind the **compile predicate** (§10.3) — an
un-compilable function transparently runs interpreted, always correct:

- **Exception handling** — never compiled in Track I (§10.2); stays
  interpreted.
- **Native SIMD codegen** — v128 runs via leaf calls (§10.1); native NEON/SSE
  is a `wasmbench`-gated later optimization.
- **Guard-page inline memory access** — deferred follow-up (§7.2); the baseline
  uses explicit checks.
- **Machine-register allocation** (and its per-safepoint liveness maps) —
  deferred (§9.4); the baseline keeps the register file in memory.
- **x86-64** — the second backend (Wave 7); aarch64 first.
- **32-bit** — never (§2.2); interpreter-only.

Estimate nothing about corpus pass counts. The JIT adds **no** corpus passes —
it re-runs the existing passes under a new tier. The deliverable is *"the
corpus passes identically under the JIT for the compilable subset."*

### 12.5 Open items to settle during implementation (the "O-" list)

- **O-J1** Add `TWasmFuncInst.CompiledEntry: Pointer` and `CallCount: UInt32`
  and the call-site tiering check in `Wasm.Interp` (§4.1). One-field store
  change, coordinate with the store/interp owners (as the `TierContext`
  addition was coordinated).
- **O-J2** Factor the interpreter's frame carve/zero/push/pop and
  call/return marshaling into shared helpers callable from `Wasm.Jit`
  (§5.1, §12.1) — expose in `Wasm.Interp`'s interface or lift to
  `Wasm.Interp.Frame`.
- **O-J3** Confirm the exact C-ABI helper-call convention the encoders must
  respect on each (OS, arch) leg (argument registers, 16-byte stack alignment,
  callee-saved set) against what FPC emits at the call boundary (§5.3).
- **O-J4** Confirm the `pthread_jit_write_protect_np` minimum-version /
  entitlement story on the macOS target, and the Linux-aarch64 cache-flush
  binding (§3.1, §3.3).
- **O-J5** Field offsets the inlined paths read (`Store.Epoch`,
  `Mem.ByteSize`, `Mem.Base`, the func-inst fields) — read them from the
  Pascal record layout at build time (a generated offsets table, or
  `PtrUInt(@rec.field) - PtrUInt(@rec)` probes in a test) rather than
  hard-coding, so a record-layout change is caught (§6, §7.1 form 2).

---

## 13. Observational-identity checklist (ADR-0001) + wasmbench

Every way the JIT could diverge from the interpreter, and how the design
prevents it. The through-line: **for anything subtle, call the same runtime
helper or leaf function the interpreter calls**, and **keep the frame the
interpreter's frame**.

1. **NaN bits.** Every payload-affecting float op yields the interpreter's
   positive canonical NaN (`$7FC00000` / `$7FF8000000000000`);
   `neg/abs/copysign/reinterpret` preserve bits (interp-spec §8 item 1).
   *Prevented by* compiling all float ops as calls to `Wasm.Interp.Numeric`
   (§1.4, §12.3 Wave 2) — the JIT computes no float arithmetic of its own in
   the baseline, so it cannot produce a different NaN. (Native FP codegen, if
   ever taken, must canonicalize identically — the budgeted cost interp-spec §8
   names.)
2. **Trap kind and timing/order.** div-by-zero before overflow; `call_indirect`
   bounds→null→type; write-nothing-on-trap for bulk ops; the split null
   messages; cast failure; stack exhaustion at the same logical depth (§8.2).
   *Prevented by* routing subtle-order and trapping ops through the same
   helpers/leaves (which call the same `TrapNow` with the same kind → the same
   `MSG_*` message), and, for the few inlined trap checks, laying the branches
   in the interpreter's order (a small, harness-covered surface). Stack
   exhaustion uses the shared `JitEnterFrame` check against the same caps
   (§5.1); the harness uses programs whose outcome does not hinge on the exact
   threshold (interp-spec §8 item 2).
3. **FP rounding mode.** Round-to-nearest-ties-to-even throughout; `nearest`
   ties-to-even, `trunc` toward zero (interp-spec §8 item 3). *Prevented by*
   the same leaf-function calls (the rounding lives in
   `Wasm.Interp.Numeric`); the JIT sets/assumes no FPU mode of its own in the
   baseline.
4. **Side-effect order at a trap.** A trapping bulk op writes nothing before it
   traps; active-segment order and partial-store-on-trap are Track D's,
   inherited. *Prevented by* using the chokepoint range helpers (`MemRangeAt`)
   and the Gc bulk helpers, which check before any write.
5. **Tail-call frame replacement.** O(1), in place, same `Base`, no native or
   value-stack growth per tail call. *Prevented by* `JitReturnCall` doing the
   interpreter's exact replacement under the trampoline loop (§4.5, §5.2).
6. **Epoch interruption points.** Observed at back-edge safepoints only, not at
   function entry. *Prevented by* emitting the epoch check at exactly the
   `IR_JUMP_SAFEPOINT` sites (§6), the same set the interpreter polls.
7. **Integer overflow / wrap behaviour.** Modulo-2^N wrap on add/sub/mul,
   masked shift amounts, `div_s` `INT_MIN/-1` trap. *Prevented by* inlining the
   two's-complement machine ops (which wrap natively) with the shift-amount mask
   and the div checks in the interpreter's order — a directly diffable surface
   (Wave 2).
8. **Reference identity.** `ref.func` returns the same store handle every time;
   `ref.eq` is raw handle equality; i31/null compare by encoding. *Prevented by*
   the ref/GC ops being helper calls into the store/heap, which mint and compare
   the same handles regardless of tier (the handles come from the store, not the
   tier — interp-spec §8 item 5).
9. **GC precision and heap state.** Same roots traced, same objects retained.
   *Prevented by* the identical `TWasmGcFrame` (§9) and the shared allocation
   helpers with publish-first.

The proof that all nine hold is the differential harness (§11): the corpus and
the unit modules run under both tiers and every observable is compared. A
divergence is a bug the harness catches on the first exercising input.

**wasmbench** measures the speedup — the interpreter-dispatch overhead the
template compiler removes (§1.3) — and reports it alongside the metrics the
tier design already tracks (frame slots per function, host-to-guest call
overhead, IR bytes per bytecode byte). Per AGENTS.md and ADR-0006/0009,
`wasmbench` numbers are **measurement only and never wired into a CI
assertion**; the correctness gate is the differential harness, not a
throughput threshold.
