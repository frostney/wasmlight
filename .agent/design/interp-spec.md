# Track E — the interpreter tier (the tier of record)

Design spec. The deliverable is this document; implementation spans several
sessions and 4–5 agents. It elaborates
`scratchpad/track-e-contract.md` (authoritative — this doc may not
contradict it) and builds on the current source of `Wasm.Ir`,
`Wasm.Runtime.*`, `Wasm.Validator.Body`, and `Wasm.Wast.Runner`. Never
commit. Gates: `lwpt format --check`, `lwpt build`, `lwpt test`.

Spec pin (every anchor below): wasm-mcp 0.2.16, spec/main
`d7b37e4170d8315f2f1283aed4e8076591a9a333` (ADR-0004), verified via
`spec_version` at authoring time.

## 0. What Track E is, and the invariants it inherits

The interpreter consumes `TWasmIrModule` and NOTHING else about the module
(ADR-0007/0012): it never reads raw wasm bytes and never re-derives a spec
rule the validator already enforced. It is the tier of record (ADR-0001):
whatever it does — which trap fires, when, what NaN bits, in what order side
effects land at a trap — is the reference every future tier (Track I JIT,
Track J AOT) is differentially tested against. §8 writes those obligations
down.

Hard obligations, inherited and non-negotiable:

- **No Pascal recursion per wasm call.** Tail calls need O(1) frame
  replacement; a self-recursive tail loop of a million iterations must run
  in bounded Pascal stack. The activation stack is EXPLICIT (§1).
- **Memory only through the chokepoint** (`Wasm.Runtime.Memory`
  `MemAddress`/`MemRange`/`MemCheck`, reached via the store's
  `MemAddressAt`/`MemRangeAt`). A new caller that bypasses it is the failure
  this design most guards against (ADR-0005/0010/0013).
- **GC frame-walk (contract GC-1/GC-2, ADR-0011).** Every activation is a
  `TWasmGcFrame` on `Heap`'s chain: ref slots zeroed at entry, frame pushed
  before the first safepoint, tail replacement not spanning a safepoint
  (§2).
- **Epoch check (ADR-0006).** At `iroJump` instructions carrying
  `IR_JUMP_SAFEPOINT`, load `Store.Epoch`, compare against the cached value,
  trap `interrupt` on change (§3.5).
- **Traps unwind to the trampoline (ADR-0009).** The interpreter runs inside
  `WasmInvoke`; a trap is `TrapNow(kind)` → `LongJmp` → `EWasmTrap`. The
  interpreter never wraps its own dispatch in `try/except`, and holds no
  managed Pascal state across a `TrapNow` (§5).
- **Store is single-threaded** (ADR-0008): no locks.
- **Error hierarchy is load-bearing**: guest faults are `EWasmTrap` (via the
  trampoline); an internal invariant violation is `EWasmError`; the
  interpreter never raises `EWasmDecodeError`/`EWasmValidationError`.
- **Reuse the canonical `MSG_*` trap constants** from `Wasm.Runtime.Traps`;
  never re-spell a message.

Staged out of Track E, and how each is handled the moment its op reaches the
tier:

- **SIMD execution → Track G.** No `$FD` IR op exists at
  `IR_FORMAT_VERSION = 1`; the validator rejects `$FD` before the tier. The
  one runtime brush with v128 is a struct/array whose field/element storage
  is a valid vector type: `Wasm.Runtime.Gc.ReadField`/`WriteField` already
  raise `MSG_GC_VEC_STORAGE_STAGED` for width 16 — the interpreter lets that
  `EWasmError` propagate, it does not invent a trap.
- **Exception throwing → Track H.** `iroThrow`/`iroThrowRef` and the
  `try_table` handler firing are staged. Decision (§4.6): Track E does NOT
  install handler tables and does NOT execute `iroThrow`/`iroThrowRef`;
  reaching one raises `EWasmError('exception handling is not implemented')`.
  Rationale below.

## 1. The activation model — the crux

### 1.1 The two reservations

The interpreter's mutable state for one thread's guest execution lives in a
per-store **interpreter context** (`TWasmInterpContext`), lazily created on
first invoke and owned by the store's tier registration (§7.3). It holds two
FIXED, NON-REALLOCATING reservations plus a depth cursor:

```
TWasmInterpContext = record
  { The value stack: every frame's register file is a contiguous slice of
    this one buffer. GetMem'd ONCE at a fixed capacity and never grown or
    moved while any frame is live — because TWasmGcFrame.Slots points into
    it and a realloc would dangle every frame on the collector's chain. The
    OS backs it lazily (untouched pages cost nothing), so a multi-MiB
    reservation is cheap. }
  Values: PWasmValue;         { GetMem(ValueCap * SizeOf(TWasmValue)) }
  ValueCap: NativeUInt;       { slots; tunable, default below }
  ValueTop: NativeUInt;       { next free slot index }

  { The activation records, one per live wasm frame. Also fixed and never
    reallocated, for the same reason: each record EMBEDS a TWasmGcFrame and
    Heap.PushFrame stores @Acts[d].GcFrame, which must stay stable. }
  Acts: PWasmActivation;      { GetMem(DepthCap * SizeOf(TWasmActivation)) }
  DepthCap: NativeUInt;       { frames; tunable, default below }
  Depth: NativeUInt;          { number of live activations }
end;
```

Both caps are tunables (constants in `Wasm.Interp`, overridable for tests):
`WASM_INTERP_VALUE_SLOTS` (default `1 shl 20` = 1 Mi slots = 8 MiB reserved)
and `WASM_INTERP_MAX_DEPTH` (default `8192`). A push that would exceed
EITHER cap is `TrapNow(wtkStackExhausted)` (§5.2) — this is how a
non-recursive interpreter honours `assert_exhaustion`. Sizing note: 1 Mi
slots is comfortably above any non-pathological program and the exhaustion
tests trip the depth cap first; both are deliberately generous and both are
observable only as the `call stack exhausted` trap.

Why fixed reservations rather than a growable value stack: a growable
`array of TWasmValue` reallocates on growth, which moves every live frame's
register file and dangles every `TWasmGcFrame.Slots` and every
`@Acts[d].GcFrame` on the collector's chain. A segmented/chunked stack fixes
that but adds a "does this frame fit in the current chunk" branch to every
call. The fixed reservation is the simplest design that keeps `Slots`
pointers stable for the life of a frame; the cost is virtual address space,
which is free until touched.

Why one context per store, reused across invokes: the store is
single-threaded (ADR-0008), so at most one guest execution is in flight per
store at the innermost level. Nested host→guest→host→guest calls (§4)
continue on the SAME `Values`/`Acts` above the outer frames — the outer
frames are never popped or moved, and the nested invoke records its base and
restores it on return. The context is created lazily (first `TierInvoke`),
grown never, freed when the store is freed.

### 1.2 The activation record

```
TWasmActivation = record
  Fn: PWasmIrFunction;        { @Instance.Ir.Functions[irIndex]; the code
                                being run. Stable — the IR is borrowed and
                                outlives the instance. }
  Instance: TWasmModuleInstance;   { borrowed; owns index spaces + engine ids }
  IP: UInt32;                 { instruction pointer: index into Fn^.Code }
  Base: NativeUInt;           { this frame's register 0 = Values[Base] }
  { The collector's view of this frame. Slots = @Values[Base],
    RefRegBits = @Fn^.RefRegBits[0], RegisterCount = Fn^.RegisterCount,
    Instance = Pointer(Instance). PushFrame sets GcFrame.Prev itself. }
  GcFrame: TWasmGcFrame;
  { How to return results to the caller. Captured from the CALL instruction
    at push time (the caller's result-dest aux block), so return needs no
    lookup. RetDest points at the first dest register in the CALLER's
    AuxU32; RetCount is the block length; the caller is the activation at
    Depth-2 once this one is on top, and its register base is Acts[Depth-2].Base.
    For the outermost frame RetKind = rtEntry and results go to the invoke
    boundary's AResults (§1.5). }
  RetKind: (rtCaller, rtEntry);
  RetDest: PUInt32;           { rtCaller: @caller.Fn^.AuxU32[block+1] }
  RetCount: UInt32;
  RetBase: NativeUInt;        { rtCaller: caller frame's Base }
end;
PWasmActivation = ^TWasmActivation;
```

The register file is `PWasmValue(Values) + Base`, addressed as `Reg[k]` for
`k in [0, Fn^.RegisterCount)`. The layout WITHIN the file is Track B's
(`Wasm.Ir` `TWasmIrFunction` header):

```
[0 .. P-1]              parameters (P = ParamCount)
[P .. P+L-1]            declared locals (L = LocalCount)
[ReturnRegBase .. +R-1] return block (R = ResultCount, ReturnRegBase = P+L)
[P+L+R .. RegisterCount-1] merge registers and temporaries
```

`RegisterCount` is the whole frame size; there is no separate operand-stack
depth. A register's static type is `Fn^.RegTypes[k]`, and it holds exactly
one type for the whole function (monotonic temporaries — §2.4).

### 1.3 The dispatch loop

One flat loop, no Pascal recursion. The loop keeps the current activation's
hot fields in locals for speed and writes them back to the record only when
the frame changes (call/return). Sketch:

```
procedure Run(Ctx: PWasmInterpContext);
var
  Act: PWasmActivation;   { = @Ctx^.Acts[Ctx^.Depth-1], the top frame }
  Fn: PWasmIrFunction;
  Reg: PWasmValue;        { = PWasmValue(Ctx^.Values) + Act^.Base }
  IP: UInt32;
  Code: PWasmIrInstr;     { = @Fn^.Code[0] }
  Ins: PWasmIrInstr;
  EpochCache: UInt64;
begin
  LoadTop;                { sets Act, Fn, Reg, IP, Code from the top record }
  EpochCache := Ctx^.Store.Epoch;
  while True do
  begin
    Ins := Code + IP;     { pointer arithmetic; Code[IP] }
    case Ins^.Op of
      iroI32Add: begin Reg[Ins^.Dest].Bits := UInt64(WrapAdd32(
                   Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      ...
      iroJump: begin
        if (Ins^.Imm and IR_JUMP_SAFEPOINT) <> 0 then
          if Ctx^.Store.Epoch <> EpochCache then TrapNow(wtkEpochInterrupt);
        IP := UInt32(Ins^.A);   { resolved target instruction index }
      end;
      iroCall: begin
        StoreTop(IP);           { write IP back before we change frames }
        DoCall(...);            { pushes a new activation, §1.4 }
        LoadTop;                { Act/Fn/Reg/IP/Code now the callee }
      end;
      iroReturn: begin
        DoReturn(...);          { marshals results, pops, §1.4 }
        if Ctx^.Depth = EntryDepth then Exit;   { invoke boundary }
        LoadTop;
      end;
      ...
    end;
  end;
end;
```

Notes:

- `case Op of` over the DENSE `TWasmIrOp` compiles to a jump table (that
  density is why Track B kept the enum gapless). No per-instruction
  allocation, no RTL call on the arithmetic path.
- `Inc(IP)` is the fall-through for every non-control op. Control ops
  (`iroJump`, `iroBranchIf`, `iroBranchIfNot`, `iroBrTable`, `iroReturn`,
  the calls, `iroBrOnNull`/`iroBrOnNonNull`/`iroBrOnCast*`) assign IP
  themselves.
- Branch targets are already RESOLVED instruction indices (Track B lowered
  `br`/`br_if`/`if`/`else`/`block`/`loop` away). Merges at joins are
  materialised as explicit `iroMove` instructions BEFORE the jump, so the
  interpreter never computes a merge — it only copies one register to
  another (`iroMove`: `Reg[Dest] := Reg[A]`).
- `EpochCache` is loaded once at entry and re-read from `Store.Epoch` only
  at safepoint jumps; the comparison against `EpochCache` (the value at
  frame entry) is what detects a host's interrupt write (§3.5). Simpler and
  equivalent: compare `Store.Epoch` against a value captured at invoke
  start; either is fine as long as a changed epoch traps.

### 1.4 Worked pseudocode: call, return, return_call

**Ordinary call** (`iroCall`; args in aux block `A`, result-dest registers
in aux block `B`, `Imm` = module function index):

```
procedure DoCall(Ctx; Caller: PWasmActivation; Ins: PWasmIrInstr);
var Addr, IrIdx, ArgAux, DstAux, ArgN, i: UInt32;
    Callee: PWasmActivation; CalleeFn: PWasmIrFunction; NewBase: NativeUInt;
begin
  Addr := Caller^.Instance.FuncAddrs[UInt32(Ins^.Imm)];  { module idx -> store addr }
  if Store.Funcs[Addr].Kind = wfkHost then
    begin HostCall(Ctx, Caller, Ins, Addr); Exit; end;   { §4 — no push }

  { --- stack-exhaustion guard, BEFORE any mutation --- }
  IrIdx    := Store.Funcs[Addr].FuncIrIndex;
  CalleeFn := @Store.Funcs[Addr].Instance.Ir.Functions[IrIdx];
  NewBase  := Ctx^.ValueTop;
  if (Ctx^.Depth >= Ctx^.DepthCap) or
     (NewBase + CalleeFn^.RegisterCount > Ctx^.ValueCap) then
    TrapNow(wtkStackExhausted);

  { --- carve the callee frame --- }
  Callee := @Ctx^.Acts[Ctx^.Depth];
  Callee^.Fn := CalleeFn;
  Callee^.Instance := Store.Funcs[Addr].Instance;      { the callee's own instance }
  Callee^.Base := NewBase;
  Callee^.IP := 0;
  Ctx^.ValueTop := NewBase + CalleeFn^.RegisterCount;

  { GC-1 obligation 1: zero EVERY slot before first use. Zeroes ref slots to
    null (so an unwritten ref reads as null, never a stale pointer) AND
    default-inits numeric locals to 0 (wasm local default). One pass covers
    both. }
  ValueZeroSlots(PWasmValue(Ctx^.Values) + NewBase, CalleeFn^.RegisterCount);

  { marshal args into param registers [0 .. ArgN-1] }
  ArgAux := Ins^.A;
  ArgN   := IrAuxBlockCount(Caller^.Fn^.AuxU32, ArgAux);
  for i := 0 to ArgN - 1 do
    (PWasmValue(Ctx^.Values) + NewBase)[i] :=
      (PWasmValue(Ctx^.Values) + Caller^.Base)[IrAuxBlockItem(Caller^.Fn^.AuxU32, ArgAux, i)];

  { return wiring: results go back into the caller's dest block }
  Callee^.RetKind  := rtCaller;
  DstAux           := Ins^.B;
  Callee^.RetCount := IrAuxBlockCount(Caller^.Fn^.AuxU32, DstAux);
  Callee^.RetDest  := @Caller^.Fn^.AuxU32[DstAux + 1];   { first dest reg }
  Callee^.RetBase  := Caller^.Base;

  { GC-1 obligation 2: push the frame BEFORE the first safepoint. Function
    entry (IP 0) is an implicit safepoint, and the callee's first
    instruction may be an allocation, so push here — after zeroing, before
    running a single instruction. }
  Callee^.GcFrame.Slots        := PWasmValue(Ctx^.Values) + NewBase;
  Callee^.GcFrame.RefRegBits   := @CalleeFn^.RefRegBits[0];
  Callee^.GcFrame.RegisterCount:= CalleeFn^.RegisterCount;
  Callee^.GcFrame.Instance     := Pointer(Callee^.Instance);
  Store.Heap.PushFrame(@Callee^.GcFrame);

  Inc(Ctx^.Depth);
end;
```

The dispatch loop `LoadTop`s after `DoCall` and continues at the callee's
`Code[0]` with no Pascal recursion. `RefRegBits` is read straight from the
IR function — Track B computed it (`IrComputeRefRegBits`), so the
interpreter only points at it. `@CalleeFn^.RefRegBits[0]` is safe because
every function has at least one register (params or the implicit frame);
if `RegisterCount = 0` the frame is degenerate and no ref bits are read —
guard `RegisterCount > 0` before taking the address (a 0-register function
has no slots to trace).

**Return** (`iroReturn`; the return block is `[ReturnRegBase .. +ResultCount)`):

```
procedure DoReturn(Ctx; Top: PWasmActivation);
var i: UInt32; Src: PWasmValue;
begin
  Src := PWasmValue(Ctx^.Values) + Top^.Base + Top^.Fn^.ReturnRegBase;
  if Top^.RetKind = rtEntry then
    for i := 0 to Top^.RetCount - 1 do EntryResults[i] := Src[i]   { §1.5 }
  else
    for i := 0 to Top^.RetCount - 1 do
      (PWasmValue(Ctx^.Values) + Top^.RetBase)[Top^.RetDest[i]] := Src[i];

  Store.Heap.PopFrame;              { balances the callee's PushFrame }
  Ctx^.ValueTop := Top^.Base;       { reclaim the callee's register file }
  Dec(Ctx^.Depth);
end;
```

`RetCount = Fn^.ResultCount` by construction (the caller's dest block has
exactly the callee's result arity — Track B checked it). Copying the return
block to the caller's dest registers is the only marshaling; there is no
value stack to unwind because the register file IS the frame.

**return_call (frame REPLACEMENT, O(1))** (`iroReturnCall`; args in aux `A`,
`Imm` = function index; NO result block — the callee returns to the current
frame's caller):

```
procedure DoReturnCall(Ctx; Top: PWasmActivation; Ins: PWasmIrInstr);
var Addr, IrIdx, ArgAux, ArgN, i: UInt32; CalleeFn: PWasmIrFunction;
    Tmp: array of TWasmValue;   { see aliasing note }
begin
  Addr := Top^.Instance.FuncAddrs[UInt32(Ins^.Imm)];
  if Store.Funcs[Addr].Kind = wfkHost then
    begin ReturnHostCall(...); Exit; end;   { §4.4 }
  IrIdx := Store.Funcs[Addr].FuncIrIndex;
  CalleeFn := @Store.Funcs[Addr].Instance.Ir.Functions[IrIdx];

  { 1. collect the argument VALUES first, into a small scratch, because they
       live in the CURRENT frame's registers which are about to be
       overwritten in place (args may alias the callee's param slots). This
       scratch is on the Pascal stack / a context-owned reusable buffer, NOT
       a managed dynamic local across a safepoint. }
  ArgAux := Ins^.A; ArgN := IrAuxBlockCount(Top^.Fn^.AuxU32, ArgAux);
  for i := 0 to ArgN - 1 do
    Tmp[i] := (PWasmValue(Ctx^.Values) + Top^.Base)[IrAuxBlockItem(Top^.Fn^.AuxU32, ArgAux, i)];

  { 2. exhaustion check against the REPLACED frame's base, not a new one:
       the callee reuses this frame's Base, so growth is O(1) and a
       self-tail-loop never advances ValueTop. Trap only if the callee's
       register file does not fit at Top^.Base. }
  if Top^.Base + CalleeFn^.RegisterCount > Ctx^.ValueCap then
    TrapNow(wtkStackExhausted);

  { 3. REPLACE in place. RetKind/RetDest/RetBase/RetCount are UNCHANGED —
       the callee returns to wherever the replaced frame would have. Update
       Fn, Instance, IP, and the register file at the SAME Base. }
  Store.Heap.PopFrame;              { drop the old frame's GcFrame }
  Top^.Fn := CalleeFn;
  Top^.Instance := Store.Funcs[Addr].Instance;
  Top^.IP := 0;
  Ctx^.ValueTop := Top^.Base + CalleeFn^.RegisterCount;

  { 4. zero the new register file, marshal args from Tmp. GC-1 obligation 3:
       the replacement must not span a safepoint — steps 3–5 run with NO
       intervening allocation, and the new frame is zeroed before it is
       published. }
  ValueZeroSlots(PWasmValue(Ctx^.Values) + Top^.Base, CalleeFn^.RegisterCount);
  for i := 0 to ArgN - 1 do (PWasmValue(Ctx^.Values) + Top^.Base)[i] := Tmp[i];

  { 5. re-push the new GcFrame (new RegisterCount/RefRegBits, same Slots base) }
  Top^.GcFrame.Slots := PWasmValue(Ctx^.Values) + Top^.Base;
  Top^.GcFrame.RefRegBits := @CalleeFn^.RefRegBits[0];
  Top^.GcFrame.RegisterCount := CalleeFn^.RegisterCount;
  Top^.GcFrame.Instance := Pointer(Top^.Instance);
  Store.Heap.PushFrame(@Top^.GcFrame);
  { Depth UNCHANGED. This is the O(1) property. }
end;
```

`Tmp` must be a fixed context-owned scratch (e.g. `Ctx^.ArgScratch:
array[0..MAX_PARAMS-1] of TWasmValue`, sized to the module's max param
count, filled at instantiation) or a stack local of bounded size — never a
`SetLength` dynamic array, which is managed state a `TrapNow` between steps 2
and 5 would skip (TRAP-1). There is no `TrapNow` between step 3 and step 5
by construction, so the frame is never observed half-replaced by a
collection. The exhaustion check (step 2) is the only trap point and it runs
BEFORE the pop, when the frame is still whole.

Correctness of GC across the replacement: `PopFrame` then `PushFrame` with no
allocation between means the collector cannot run while the frame is
absent from the chain. The re-push happens before the callee's first
instruction (its own IP-0 safepoint).

### 1.5 The invoke boundary (`TierInvoke`)

Track D wired the seam as `TWasmTierInvokeProc`:

```
procedure(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
          const AParams: PWasmValue; const AResults: PWasmValue);
```

`AParams`/`AResults` are caller-owned frame slices (host layout: params in
declaration order, results in declaration order). Track E supplies the
implementation and registers it: `AStore.TierInvoke := @InterpTierInvoke`.
Registration happens in `Wasm.Interp`'s `initialization`, or via an explicit
`RegisterInterpreter(Store)` the embedder/tests call — decision: an explicit
`RegisterInterpreter(const AStore)` procedure that sets the hook, called by
`Wasm.Wast.Runner` and the unit tests, plus a convenience that the CLI
calls. (A bare `initialization` that mutates a store it cannot see is
impossible; the hook is per-store, so it must be set per-store.)

`InterpTierInvoke` marshals into an entry frame and runs to completion:

```
procedure InterpTierInvoke(Store; Addr; AParams; AResults);
var Ctx: PWasmInterpContext; Fn: PWasmIrFunction; Entry: PWasmActivation;
    SavedDepth, SavedTop: NativeUInt; i: UInt32;
begin
  Store.CheckThread;                       { ADR-0008 }
  Ctx := InterpContextFor(Store);          { lazily create/reuse, §7.3 }

  { A host func called as the entry point: forward to the host path with no
    wasm frame. }
  if Store.Funcs[Addr].Kind = wfkHost then
    begin InvokeHostEntry(Store, Addr, AParams, AResults); Exit; end;

  SavedDepth := Ctx^.Depth;  SavedTop := Ctx^.ValueTop;   { nesting support }
  Fn := @Store.Funcs[Addr].Instance.Ir.Functions[Store.Funcs[Addr].FuncIrIndex];

  if (Ctx^.Depth >= Ctx^.DepthCap) or
     (Ctx^.ValueTop + Fn^.RegisterCount > Ctx^.ValueCap) then
    TrapNow(wtkStackExhausted);

  Entry := @Ctx^.Acts[Ctx^.Depth];
  Entry^.Fn := Fn; Entry^.Instance := Store.Funcs[Addr].Instance;
  Entry^.Base := Ctx^.ValueTop; Entry^.IP := 0;
  Ctx^.ValueTop := Entry^.Base + Fn^.RegisterCount;
  ValueZeroSlots(PWasmValue(Ctx^.Values) + Entry^.Base, Fn^.RegisterCount);

  { marshal AParams into [0 .. ParamCount-1] }
  for i := 0 to Fn^.ParamCount - 1 do
    (PWasmValue(Ctx^.Values) + Entry^.Base)[i] := AParams[i];

  Entry^.RetKind := rtEntry;
  Entry^.RetCount := Fn^.ResultCount;
  { rtEntry results are written to AResults by DoReturn; stash AResults on
    the context so DoReturn can reach it (or make EntryResults a context
    field set here). }
  Ctx^.EntryResults := AResults;
  Ctx^.EntryDepth := Ctx^.Depth;           { the depth at which Run returns }

  PushEntryGcFrame(Ctx, Entry);            { same as DoCall's push block }
  Inc(Ctx^.Depth);

  Run(Ctx);                                { the loop; returns when Depth = EntryDepth }

  { on clean return the entry frame is already popped by DoReturn; restore
    nesting cursors so an outer invocation is undisturbed. }
  Ctx^.Depth := SavedDepth; Ctx^.ValueTop := SavedTop;
end;
```

Crucially, `InterpTierInvoke` itself does NOT install a trampoline —
`WasmInvoke` does, and Track D already routes guest entry through it
(`RunPendingStart` calls `TierInvoke` inside a `try/finally` that does
`Heap.ResetFrames`; the embedding API/Track F wraps host→guest calls in
`WasmInvoke`). Track E's obligation is only to run the dispatch. A trap
inside `Run` `LongJmp`s past `Run`, past `InterpTierInvoke`, to the nearest
`WasmInvoke` — skipping the cursor-restore above, which is why the frame
chain is re-established by `Heap.ResetFrames` at the trampoline landing
(§5.3) and the context cursors are re-synced there too (§7.3).

The `.wast` runner and the direct-API tests must therefore call guest code
through `WasmInvoke` (or a thin `Wasm.Interp` helper that does), never
`InterpTierInvoke` directly, so that a trap becomes an `EWasmTrap` rather
than a `LongJmp` into a missing trampoline. §6 specifies the runner's use.

## 2. The GC frame-walk realization (contract GC-1/GC-2)

### 2.1 What each activation gives the collector

`Wasm.Runtime.Gc.TWasmGcFrame` is `{ Prev; Slots: PWasmValue; RefRegBits:
PWasmGcRefBits; RegisterCount: UInt32; Instance: Pointer }`. Per activation:

- `Slots = PWasmValue(Ctx^.Values) + Base` — a contiguous slice of the value
  stack, `RegisterCount` slots long. Contiguity holds because the value
  stack is one non-reallocating buffer (§1.1).
- `RefRegBits = @Fn^.RefRegBits[0]` — the interpreter POINTS at the IR
  function's precomputed bitset; it computes nothing. Confirmed present:
  `TWasmIrFunction.RefRegBits` is filled by `IrComputeRefRegBits` at the end
  of the function walk (Track B), bit `i` set iff `RegTypes[i].Kind =
  wvkRef`. The collector reads `RefRegBits[i div 32] and (1 shl (i mod 32))`
  over `[0, RegisterCount)`.
- `RegisterCount = Fn^.RegisterCount`.
- `Instance = Pointer(Instance)` — opaque to the collector.

The collector (`MarkFrames`, walks `Prev` from `CurrentFrame`) treats
`Slots[i].Ref` as a root for each set ref bit. Null and unboxed i31 are
skipped by encoding inside `MarkRoot`.

### 2.2 Zeroing at entry (GC-1 obligation 1)

Every `DoCall`/`DoReturnCall`/entry zeroes the ENTIRE register file with
`ValueZeroSlots(Slots, RegisterCount)` before marshaling args and before the
frame is published. This covers, in one pass:

- **All ref-typed registers** read as null until written — an unzeroed slot
  is indistinguishable from a live pointer (the single most important line
  in the contract).
- **Numeric locals** default to 0 (wasm local default value); params are
  then overwritten by marshaling.
- **Merge registers and temporaries** start at 0/null; they are only read
  after being written (SSA-like monotonic temporaries — §2.4), so their
  initial value is never observed, but zeroing keeps a ref temporary from
  tracing garbage if a collection lands before its first write.

Non-nullable reference locals (3.0 permits them with initialization
tracking): validation guarantees no read-before-write, and zero = null is a
valid GC placeholder, so zeroing is sound even though `null` is not a legal
VALUE of a non-nullable type — the collector only needs it to be traceable
(null is), and the guest never observes it.

### 2.3 Push timing and tail replacement (GC-1 obligations 2 and 3)

- **Push before the first safepoint.** The frame is pushed at the end of
  `DoCall`/entry, after zeroing and marshaling, before `Run` executes the
  callee's `Code[0]`. Function entry is an implicit safepoint
  (`IrOpIsSafepoint` note: "Function entry (instruction index 0) is an
  implicit safepoint"), and `Code[0]` may be an allocating op, so the frame
  must be discoverable before it runs. It is.
- **Pop after the last safepoint.** `DoReturn` pops after copying results
  out; results are plain-value copies (no allocation), so nothing between
  the last in-frame safepoint and the pop can collect.
- **Tail replacement not spanning a safepoint** (§1.4 steps 3–5):
  `PopFrame` then `PushFrame` with zero intervening allocation. The only
  trap point is the exhaustion check (step 2), which runs BEFORE the pop
  when the old frame is still whole and on the chain.

### 2.4 The live-refs invariant, and why it is a clean projection

At every allocation site (`iroStructNew`, `iroArrayNew*`,
`iroRefI31`, and every call/tail-call — the `IrOpIsSafepoint` set), the live
references are EXACTLY the ref-typed registers currently holding live
values. Track B's monotonic-temporary IR makes this exact rather than
conservative: each temporary is written once and every register has one
static type for the whole function, so `RefRegBits` (a projection of
`RegTypes`) names precisely the slots that can hold a reference. The
collector traces all ref-typed slots in `[0, RegisterCount)`; a ref
temporary that has been allocated a register but not yet written reads as
null (zeroed at entry) and is skipped by encoding. Over-approximation is
impossible (only ref slots are traced) and under-approximation is impossible
(every ref slot is traced). This is why the design does not need liveness
analysis: zeroing plus the static projection is precise enough.

One subtlety the interpreter must respect: when it OVERWRITES a ref register
with a non-ref value... it cannot, because a register has ONE static type
for the whole function. A ref register only ever holds refs. So there is no
"stale ref after the value became an int" hazard — that is a property Track
B guarantees and Track E relies on. The `Bits`-canonical writes in
`Wasm.Runtime.Values` (every narrow write zeroes the whole slot) keep a
non-ref register from leaving a high-half that a MISclassified scan would
read, but since scans are driven by static type, this is belt-and-braces.

### 2.5 Init-expression frames already do this

`Wasm.Runtime.Instantiate.EvalInitExpr` already builds a `TWasmGcFrame` over
a store scratch frame, derives ref bits with `ScratchRefBits`, pushes it,
runs the const ops, pops it. Track E's function frames are the same pattern
with the register file coming from the value stack instead of the store
scratch, and `RefRegBits` coming from the IR function instead of being
recomputed. The interpreter shares NO code with `EvalInitExpr` (different
storage), but the contract discharge is identical.

## 3. Dispatch by op family

Register access shorthand below: `D = Reg[Ins^.Dest]`, `A = Reg[Ins^.A]`,
`B = Reg[Ins^.B]`, `Imm = Ins^.Imm`. Writes go through the `ValueSet*`
helpers or `.Bits :=` (canonical, zeroes the whole slot). `IR_OP_INFO` is
the authority on which field is a register vs an index vs an immediate — the
interpreter reads it the same way the disassembler does; the per-op notes
below match it.

Numeric arithmetic lives in a dedicated unit `Wasm.Interp.Numeric` as leaf
functions (§7.1), each with `{$PUSH}{$OVERFLOWCHECKS OFF}{$RANGECHECKS OFF}`
where wasm requires modulo-2^N wrap (Shared.inc turns those checks ON outside
PRODUCTION, so a legal wrap would otherwise raise `EIntOverflow` — the same
reason `Wasm.Runtime.Instantiate`'s `WrapAdd32` etc. exist). The dispatch
`case` calls them; FPC inlines the small ones.

Anchor: `exec-instr-numeric` — "Where the underlying operators are partial,
the corresponding instruction will trap when the result is not defined.
Where the underlying operators are non-deterministic, because they may
return one of multiple possible NaN values, so are the corresponding
instructions."

### 3.1 Numeric — constants, compares, integer arithmetic

- **Constants** `iroI32Const/iroI64Const/iroF32Const/iroF64Const`
  (`ImmKind: ifkImmValue`): write `Imm` into `D.Bits`. i32:
  `D.Bits := UInt64(UInt32(Int32(Imm)))`. i64: `D.Bits := UInt64(Imm)`. f32:
  `D.Bits := UInt64(UInt32(Imm))` (bit pattern, zero-extended). f64:
  `D.Bits := UInt64(Imm)`. Exactly `EvalInitExpr`'s const handling; floats
  are BIT PATTERNS, never assigned through a float type (NaN payloads are
  observable — `IrBitsAsF32` uses a variant record; the interpreter reads
  `A.F32`/`A.F64` for arithmetic but stores results as bits).
- **Tests/compares** `iroI32Eqz`..`iroI64GeU`, `iroF32Eq`..`iroF64Ge`:
  produce i32 `0`/`1`. Signed compares read `.I32`/`.I64`; unsigned read
  `.U32`/`.U64`; `eqz` is `A == 0`. Float compares read `.F32`/`.F64` and
  use IEEE ordered comparison: any NaN operand makes `lt/gt/le/ge/eq` false
  and `ne` true. Write `ValueSetI32(D, Ord(cond))`.
- **i32/i64 unary** `clz/ctz/popcnt`: `clz` of 0 = width (32/64); `ctz` of 0
  = width; `popcnt` = set-bit count. No RTL: implement with a small loop or
  `BsfDWord/BsrDWord` intrinsics if measured (RTL policy — plain loop first).
- **i32/i64 binary** `add/sub/mul` (wrap, checks off); `and/or/xor`;
  `shl/shr_s/shr_u/rotl/rotr` — the shift amount is masked to `width-1`
  (`k mod 32` / `k mod 64`), a spec rule, read from `B.U32`; `shr_s` is
  arithmetic on `.I32`/`.I64`, `shr_u` logical on `.U32`/`.U64`.
- **div/rem — the trap conditions** (anchors: `i32.div_s`, `i32.rem_s`,
  `i32.div_u`, `i64.*` analogues; `instruction_get` reports these as
  trapping):
  - `div_u`/`rem_u`: if `B == 0` → `TrapNow(wtkDivideByZero)`
    (`MSG_TRAP_DIVIDE_BY_ZERO = 'integer divide by zero'`). Else unsigned
    divide/remainder.
  - `div_s`: if `B == 0` → `wtkDivideByZero`. Else if
    `A = INT_MIN and B = -1` → `TrapNow(wtkIntegerOverflow)`
    (`MSG_TRAP_INTEGER_OVERFLOW = 'integer overflow'`) — the quotient
    `2^31`/`2^63` is unrepresentable. Else signed divide (truncating toward
    zero).
  - `rem_s`: if `B == 0` → `wtkDivideByZero`. If `A = INT_MIN and B = -1`
    the result is `0` and does NOT trap (only `div_s` overflows here).
    Else signed remainder.
  INT_MIN = `Int32($80000000)` / `Int64($8000000000000000)`.

### 3.2 Numeric — floats: IEEE 754 and NaN

Float binary/unary ops read operands as `.F32`/`.F64`, compute in the FPC
float type, and store the RESULT as bits. The NaN discipline (anchor
`aux-nans`) is the reference the whole tier system is pinned to (§8), so it
is spelled exactly:

Canonical NaN bit patterns:

- f32 canonical = `$7FC00000` (sign 0, exp all-ones, payload MSB set, rest 0).
- f64 canonical = `$7FF8000000000000`.

`aux-nans` rule: for any float op OTHER than `neg`/`abs`/`copysign`, when the
mathematical result is NaN: if every NaN input's payload is canonical (or
there are no NaN inputs) the output payload is canonical; otherwise the
output is an arithmetic NaN (payload MSB = 1, other bits unspecified, sign
unspecified).

**Reference-fixing implementation decision.** The interpreter produces, for
every NaN result of a payload-affecting op, the POSITIVE CANONICAL NaN
(`$7FC00000` / `$7FF8000000000000`). This satisfies BOTH corpus result
classes: `nan:canonical` requires exactly the canonical pattern (met), and
`nan:arithmetic` requires only payload-MSB = 1 (the canonical pattern has
MSB set, so met). Producing canonical-always is the deterministic profile
`aux-nans` explicitly sanctions ("a positive canonical NaN is reliably
produced"). It is chosen as the reference because it is the cheapest rule to
state and to test, and it makes the differential obligation on Track I a
single, checkable rule (§8). Implementation: after each payload-affecting op,
`if IsNan(result) then store canonical-bits else store result-bits`. Detect
NaN by bit test (exp all-ones AND non-zero significand), NOT by `result <>
result` (FPC may fold that).

EXEMPT ops (operate on bits, must preserve payload and follow their own sign
rules — do NOT canonicalize):

- `f32.neg`/`f64.neg`: flip the sign bit (`Bits xor $80000000` /
  `xor $8000000000000000`).
- `f32.abs`/`f64.abs`: clear the sign bit (`Bits and $7FFFFFFF` /
  `and $7FFFFFFFFFFFFFFF`).
- `f32.copysign`/`f64.copysign`: `(A with A's magnitude) | (B's sign)` —
  `(A.Bits and mag_mask) or (B.Bits and sign_mask)`.
- `reinterpret` (both directions): pure bit copy.

Other float ops and their edge cases the corpus hammers:

- `add/sub/mul/div`: IEEE with the above NaN rule. `div` by zero is NOT a
  trap for floats — it yields ±inf or (0/0) NaN.
- `sqrt`: negative operand (including -0? no: sqrt(-0) = -0) yields canonical
  NaN; `sqrt(-x)` for x>0 = NaN. Use the FPU `Sqrt` then apply the NaN rule.
- `min`/`max`: wasm semantics, NOT IEEE minNum/maxNum. If either operand is
  NaN → NaN (canonicalized). `min(+0,-0) = -0`, `min(-0,+0) = -0`;
  `max(+0,-0) = +0`, `max(-0,+0) = +0` (zero sign matters — compare bit
  patterns for the ±0 tie, do not rely on `<`). Otherwise the smaller/larger
  value.
- `ceil`/`floor`/`trunc`/`nearest`: round to an integral float, preserving
  sign of zero and infinities; NaN input → canonical NaN. `nearest` is
  round-half-to-EVEN (`roundTiesToEven`), NOT FPC `Round` semantics blindly
  and NOT C `round` (half away from zero). Implement `nearest` explicitly:
  `t := Trunc(x); d := x - t;` handle `|d| < 0.5`, `> 0.5`, and the exact
  `0.5` tie by choosing the even neighbour; preserve `-0.0` when the result
  is zero and `x` was negative. `trunc` = round toward zero (FPC `Int()` /
  a manual truncation preserving sign of zero). Test against
  `f32.wast`/`f64.wast` which cover ±0, ±inf, subnormals, and the tie cases.
- `f32.demote_f64`: round f64→f32 (round-to-nearest-even); NaN → canonical
  f32 NaN; overflow → ±inf.
- `f64.promote_f32`: exact widening; NaN → canonical f64 NaN.

### 3.3 Numeric — conversions and truncations

- `i32.wrap_i64`: low 32 bits of `A.U64`.
- `i64.extend_i32_s/u`: sign/zero extend `A.I32`/`A.U32`.
- `i32.extend8_s/extend16_s`, `i64.extend8_s/16_s/32_s`: sign-extend the low
  8/16/32 bits.
- **Non-saturating float→int trunc** `i32.trunc_f32_s`..`i64.trunc_f64_u`
  (anchors: `i32.trunc_f32_s` reports traps `invalid conversion to integer`
  and `integer overflow`):
  - If operand is NaN → `TrapNow(wtkInvalidConversion)`
    (`MSG_TRAP_INVALID_CONVERSION = 'invalid conversion to integer'`).
  - If the truncated (toward zero) value is outside the target's range
    (including ±inf, and values `>= 2^31`/`< -2^31` for i32_s, `>= 2^32` for
    i32_u and negative operands `<= -1` for unsigned) →
    `TrapNow(wtkIntegerOverflow)`.
  - Else the truncated integer. Do the range test in the FLOAT domain before
    converting (compare against the exact representable bounds), because the
    conversion itself is what overflows. The precise bounds per (source,
    target, signedness) are the ones the reference interpreter uses; encode
    them as float constants and test against `conversions.wast`.
- **Saturating** `i32.trunc_sat_*`..`i64.trunc_sat_*` (2.0; never trap): NaN
  → 0; `-inf`/below-min → min; `+inf`/above-max → max; else truncated. All
  branches, no trap.
- **int→float** `f32.convert_i32_s`..`f64.convert_i64_u`: exact where
  representable, round-to-nearest-even otherwise (i64→f32 rounds). No trap.
- `reinterpret` (4 ops): bit copy, no conversion.

### 3.4 Parametric and variable

- `iroSelect` (`DestKind ifkDestReg; A,B ifkSrcReg; Imm ifkSrcReg` — the
  condition register rides in `Imm`): `if Reg[Imm].I32 <> 0 then D := A else
  D := B`. Whole-slot copy (`.Bits`), so it works for any type including
  refs (the typed select encoding lowers here too).
- `iroGlobalGet` (`Imm ifkGlobalIndex`): `D := Store.Globals[
  Instance.GlobalAddrs[Imm]].Value` (whole slot). Imported globals are
  shared cells — reading through `GlobalAddrs` reaches the exporter's cell,
  which is correct.
- `iroGlobalSet` (`A ifkSrcReg`, `Imm ifkGlobalIndex`): write `A` into the
  global cell. If the global's value type is a reference type, call
  `Store.Heap.WriteBarrier(WASM_REF_NULL, A.Ref)` before the store (a global
  of ref type is a root; the barrier is empty in v1 but the site is
  wired). Simplest: always call the barrier when
  `Fn^.RegTypes` says the source is a ref — but the cleaner source of truth
  is the global's type (`Store.Globals[addr].GlobalType.ValueType.Kind =
  wvkRef`). Mutability was checked by the validator; do not re-check.
  Local get/set do not appear — Track B lowered them to `iroMove` /
  register reuse, so there is no variable op for locals.

### 3.5 Control

The IR is already lowered to jumps/branches with resolved instruction-index
targets, so most control is IP assignment.

- `iroMove` (`D := A`, whole slot): the merge/local materialization. Copy
  `A.Bits` to `D.Bits`.
- `iroJump` (`A ifkInstrIndex`, `Imm ifkFlags`): if `Imm and
  IR_JUMP_SAFEPOINT <> 0`, run the epoch check (below), then `IP := A`.
- `iroBranchIf` (`A ifkSrcReg`, `B ifkInstrIndex`): `if Reg[A].I32 <> 0 then
  IP := B else Inc(IP)`.
- `iroBranchIfNot`: `if Reg[A].I32 = 0 then IP := B else Inc(IP)`.
- `iroBrTable` (`A ifkSrcReg` selector, `B ifkAuxIndex`): the aux block is
  `[N, s0 .. s(N-1)]` where `N = Count+1` and the LAST entry (`s[N-1]`) is
  the default (confirmed in `Wasm.Validator.Body.HandleBrTable`). Selector
  `k := Reg[A].U32`; `if k >= N-1 then target := block[N-1] else target :=
  block[k]`; `IP := target`. Each `block[i]` is a STUB instruction index
  that performs the target's merge `iroMove`s then `iroJump`s to the label —
  the interpreter just sets IP to it; it does not itself move anything.
- `iroReturn`: `DoReturn` (§1.4).
- `iroUnreachable`: `TrapNow(wtkUnreachable)`
  (`MSG_TRAP_UNREACHABLE = 'unreachable'`).
- **Epoch check** (ADR-0006): at a safepoint jump, `if Store.Epoch <>
  EpochCache then TrapNow(wtkEpochInterrupt)`
  (`MSG_TRAP_EPOCH_INTERRUPT = 'interrupt'`, UNCONFIRMED — not in the
  corpus; documented by the embedding API). `EpochCache` is the epoch
  captured at invoke start; a host writing `Store.Epoch` from another thread
  (the one documented cross-thread write, ADR-0006) is observed here. The
  IR marks back-edge jumps with `IR_JUMP_SAFEPOINT`; function-entry
  safepoints do not poll (nothing to poll for — the collector is
  allocation-triggered, and the epoch is only meaningful at back-edges where
  a loop could otherwise spin uninterruptibly).

### 3.6 Calls

- `iroCall` / `iroReturnCall`: §1.4. Arg aux from `A`, result-dest aux from
  `B` (non-tail only), `Imm` = module function index → `Instance.FuncAddrs`
  → store addr → wasm or host dispatch.
- `iroCallIndirect` (`Dest ifkSrcReg` = table-index operand, `A ifkAuxIndex`
  = args, `B ifkAuxIndex` = result dests, `Imm ifkPacked` =
  `IrPack(typeIndex, tableIndex)`):
  1. `IrUnpack(Imm, TypeIdx, TableIdx)`.
  2. `idx := Reg[Dest]` — width is the table's address type (u32 for i32
     tables, u64 for i64 tables); use `.U32`/`.U64` per
     `Store.Tables[tableAddr].TableType.Limits.AddrType`.
  3. **Bounds**: `tableAddr := Instance.TableAddrs[TableIdx]`; if `idx`
     out of bounds → `TrapNow(wtkUndefinedElement)`
     (`MSG_TRAP_UNDEFINED_ELEMENT = 'undefined element'` — note: DIFFERENT
     from the table-access message; do not use `wtkTableOutOfBounds`). Use
     the same in-bounds predicate the store uses, but raise the
     call_indirect message: read the element with a bounds test that traps
     `undefined element`, not `TableGet` (which traps `out of bounds table
     access`). Implement a local bounds check or a store helper that raises
     the right kind.
  4. **Null**: `r := Store.Tables[tableAddr].Elems[idx]`; if `RefIsNull(r)`
     → `TrapNow(wtkUninitializedElement)`
     (`MSG_TRAP_UNINITIALIZED_ELEMENT = 'uninitialized element'`).
  5. **Type**: `r` is a `wokFuncRef` handle; `funcAddr := Store.FuncRefAddr(
     r)`; if `not Store.Engine.Matches(Store.Funcs[funcAddr].TypeId,
     Instance.EngineTypeIds[TypeIdx])` → hmm — the expected type is
     `TypeIdx` in MODULE space; convert to engine via
     `Instance.EngineTypeIds[TypeIdx]`, then compare with
     `Matches(actualTypeId, expectedEngineId)`. call_indirect requires
     EXACT type match, not subtype: use equality of engine ids
     (`Store.Funcs[funcAddr].TypeId = Instance.EngineTypeIds[TypeIdx]`),
     because `match-deftype` under canonicalisation is engine-id equality.
     Mismatch → `TrapNow(wtkIndirectCallTypeMismatch)`
     (`MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH = 'indirect call type
     mismatch'`). Trap ORDER is bounds → null → type (confirmed
     `instruction_get call_indirect`: `undefined element`, then
     `uninitialized element`, then `indirect call type mismatch`).
  6. Dispatch to the resolved `funcAddr` exactly like `iroCall`
     (wasm/host), using the SAME arg/result aux blocks. Tail form replaces
     the frame.
- `iroCallRef` / `iroReturnCallRef` (`Dest ifkSrcReg` = funcref operand,
  `A/B` aux, `Imm ifkTypeIndex`): `r := Reg[Dest]`; if `RefIsNull(r)` →
  `TrapNow(wtkNullFuncReference)` (`MSG_TRAP_NULL_FUNC_REFERENCE = 'null
  function reference'` — confirmed `call_ref`/`return_call_ref`). Else
  `funcAddr := Store.FuncRefAddr(r)` and dispatch. No runtime type check —
  the funcref's static type already guarantees it (that is why table
  element type is invariant; call_ref does no check).

### 3.7 Memory

Every load/store goes through `Store.MemAddressAt(memAddr, index, offset,
size)` (which routes to the `Wasm.Runtime.Memory` chokepoint and traps
`out of bounds memory access` = `MSG_TRAP_MEMORY_OUT_OF_BOUNDS`). Bulk ops
use `Store.MemRangeAt`.

- Memory index and offset (VERIFIED against `Wasm.Validator.Body.HandleLoadStore`):
  `B = ifkMemIndex` (the memory index), and `Imm` is the RAW u64 static
  offset — align is NOT packed in (the validator emits
  `Emit(IrOp, ..., MemIdx, Int64(StaticOffset))` with `StaticOffset` the u64
  memarg offset; alignment is consumed at validation and never reaches the
  IR). So `AOffset := UInt64(Imm)` directly, no masking. The offset is u64
  (memory64), passed straight to the chokepoint.
- **Loads** `iroI32Load`..`iroI64Load32U` (`Dest`, `A` = index register,
  `B` = mem index): `idx := Reg[A]` (u32/u64 per mem addr type);
  `p := Store.MemAddressAt(Instance.MemAddrs[B], idx, offset, size)`; read
  `size` bytes; sign/zero-extend per the op; write to `D`. Access widths:
  `Load`=4/8, `Load8`=1, `Load16`=2, `Load32`=4. `_s` variants
  sign-extend to the register width, `_u` zero-extend. Read bytes with an
  unaligned-safe move (wasm allows unaligned access; do not assume `p` is
  aligned — use `Move` or byte assembly, or an unaligned typed read which
  FPC permits on the targets in scope). Endianness: wasm is
  little-endian; on the LE hosts this project targets, a direct typed read is
  correct; keep a note for a future BE target.
- **Stores** `iroI32Store`..`iroI64Store32` (`Dest` = value register per
  `IR_OP_INFO` — note store ops use `DestKind: ifkSrcReg`, so the VALUE is in
  `Reg[Dest]` and the INDEX in `Reg[A]`; `B` = mem index): compute address,
  write the low `size` bytes of `Reg[Dest]`. `Store8`/`16`/`32` truncate.
- `iroMemorySize` (`Dest`, `Imm ifkMemIndex`): `D := ` current pages. The
  store exposes pages only through metadata; add a `Store.MemoryPages(addr)`
  read accessor if not present (does not expose `Base`). Result type is the
  memory's address type (i32 or i64).
- `iroMemoryGrow` (`Dest`, `A` = delta register, `Imm ifkMemIndex`): call a
  store method `Store.MemoryGrow(addr, delta)` that wraps
  `Wasm.Runtime.Memory.MemoryGrow` (returns previous pages or -1). Write the
  result to `D` (as i32/i64 per addr type; -1 as the addr-type's
  all-ones). Growth NEVER traps and never runs the collector.
- `iroMemoryInit` (`Dest` = dst index, `A` = src offset, `B` = size, `Imm
  ifkPacked` = `IrPack(dataIndex, memIndex)`): bounds-check both the memory
  destination range (via `MemRangeAt`, traps `out of bounds memory access`)
  and the data segment source range (traps the SAME message); copy. A
  dropped data segment reads as empty (size 0) — an init from it with
  nonzero size/offset traps. Use `Store.Datas[Instance.DataAddrs[dataIndex]]`
  for the source bytes.
- `iroDataDrop` (`Imm ifkDataIndex`): set the data instance `Dropped`,
  zero its span (a store method or direct field write —
  `Store.Datas[Instance.DataAddrs[Imm]].Dropped := True`).
- `iroMemoryCopy` (`Dest` = dst, `A` = src, `B` = size, `Imm ifkPacked` =
  `IrPack(dstMem, srcMem)`): range-check dst and src via `MemRangeAt`
  (both trap `out of bounds memory access`), then `Move` with overlap
  handling (copy semantics = `memmove`, handles overlap).
- `iroMemoryFill` (`Dest` = index, `A` = byte value, `B` = size, `Imm
  ifkMemIndex`): range-check via `MemRangeAt`, `FillChar` with `Reg[A].U32
  and $FF`.

All bulk ops: the RANGE CHECK PRECEDES ANY WRITE (a trapping op writes
nothing), which `MemRangeAt` guarantees by checking before returning the
pointer. A zero-length op at exactly the boundary is in bounds.

### 3.8 Table

Reference-STORING ops go through the barriered store METHODS (never a raw
`var TWasmTableInst`) so the write barrier cannot be bypassed. Reads use the
free functions.

- `iroTableGet` (`Dest`, `A` = index, `Imm ifkTableIndex`): `D.Ref :=
  TableGet(Store.Tables[Instance.TableAddrs[Imm]], idx)` — `TableGet` traps
  `out of bounds table access` (`wtkTableOutOfBounds`).
- `iroTableSet` (`Dest` = index reg, `A` = value reg, `Imm ifkTableIndex`):
  `Store.TableSet(Instance.TableAddrs[Imm], idx, Reg[A].Ref)` (barriered,
  traps out of bounds).
- `iroTableSize` (`Dest`, `Imm`): `D := TableSize(...)`.
- `iroTableGrow` (`Dest`, `A` = init-value reg, `B` = delta reg, `Imm`):
  `D := Store.TableGrow(addr, delta, initRef)` (returns previous size or -1).
- `iroTableFill` (`Dest` = index, `A` = value, `B` = count, `Imm`):
  `Store.TableFill(addr, index, count, Reg[A].Ref)` (traps out of bounds;
  range-checked before writing).
- `iroTableInit` (`Dest` = dst, `A` = src, `B` = count, `Imm ifkPacked` =
  `IrPack(elemIndex, tableIndex)`): copy `count` refs from
  `Store.Elems[Instance.ElemAddrs[elemIndex]].Refs[src..]` to the table via
  a barriered store; range-check both (dst via table range, src via elem
  length) → `out of bounds table access`. A dropped elem reads as empty.
  Use/extend `Store.TableInitFromElem` (currently takes the whole `Refs`
  array; it needs a `src`/`count` slice — add a variant or slice at the call
  site into a temporary array; prefer extending the store method to take
  `src, count` so the barrier stays inside the store). (Open item O-2.)
- `iroTableCopy` (`Dest` = dst, `A` = src, `B` = count, `Imm ifkPacked` =
  `IrPack(dstTable, srcTable)`): range-check both, barriered copy with
  overlap handling. Add `Store.TableCopy(dstAddr, dstIdx, srcAddr, srcIdx,
  count)` (barriered) — the store owns the barrier site.
- `iroElemDrop` (`Imm ifkElemIndex`): `Store.Elems[Instance.ElemAddrs[Imm]]`
  → `Refs := nil; Dropped := True`.

The `uninitialized element N` indexed message (`bulk.wast:222`): only
`table.init`/`elem`-driven copies of a null through... actually that indexed
form arises where the corpus appends the element index; the trampoline's
`Detail` field carries it (`TrapNowDetail(wtkUninitializedElement, index)`).
The interpreter uses `TrapNowDetail` for `call_indirect`'s
`uninitialized element` only if the corpus for that instruction is indexed;
for plain table bulk OOB it is `wtkTableOutOfBounds`. Keep the bare
`wtkUninitializedElement` for call_indirect null; the runner prefix-matches,
so the bare and indexed corpus forms both pass (`RaiseTrapDirect` appends
`Detail`). (Confirm which sites are indexed against the corpus during
implementation — the message infra already supports it.)

### 3.9 Reference

- `iroRefNull` (`Dest`; heap type is in `RegTypes[Dest]`, not the op):
  `D.Bits := UInt64(WASM_REF_NULL)` (= 0). Exactly `EvalInitExpr`.
- `iroRefIsNull` (`Dest`, `A`): `ValueSetI32(D, Ord(RefIsNull(A.Ref)))`.
- `iroRefFunc` (`Dest`, `Imm ifkFuncIndex`): `D.Ref :=
  Store.Funcs[Instance.FuncAddrs[Imm]].RefObject` (the stable handle).
- `iroRefEq` (`Dest`, `A`, `B`): `ValueSetI32(D, Ord(A.Ref = B.Ref))` —
  raw reference identity; i31 and null compare by encoding, which is why the
  encoding is bitness-independent.
- `iroRefAsNonNull` (`Dest`, `A`): if `RefIsNull(A.Ref)` →
  `TrapNow(wtkNullReference)` (the BARE `MSG_TRAP_NULL_REFERENCE = 'null
  reference'` — ref.as_non_null uses the bare message). Else `D := A`.
- `iroBrOnNull` (`Dest`, `A`, `B ifkInstrIndex`): if `RefIsNull(A.Ref)` then
  `IP := B` (branch taken, null consumed) else `D := A` (the non-null value
  flows to the fallthrough dest) and `Inc(IP)`.
- `iroBrOnNonNull` (`A`, `B ifkInstrIndex`): if `not RefIsNull(A.Ref)` then
  the value is already in the merge registers (Track B materialized the
  moves at the target) — `IP := B`; else `Inc(IP)`. (`DestKind ifkUnused`:
  the value passed to the label is carried by the target stub's merge moves,
  so the interpreter only branches.)
- `iroRefTest` (`Dest`, `A`, `Imm ifkRefTypeIndex`): the reftype is
  `Fn^.AuxRefTypes[Imm]` in MODULE space; convert to engine space with
  `EngineRefType(rt, Instance.EngineTypeIds)`; `ValueSetI32(D, Ord(
  IsRefOfRefType(Store.Engine, A.Ref, engineRt)))`. `IsRefOfRefType` handles
  null (nullable target), i31, abstract, and concrete cases.
- `iroRefCast` (`Dest`, `A`, `Imm ifkRefTypeIndex`): same conversion; if
  `IsRefOfRefType(...)` then `D := A` else `TrapNow(wtkCastFailure)`
  (`MSG_TRAP_CAST_FAILURE = 'cast failure'`).
- `iroBrOnCast` (`Dest`, `A`, `B ifkInstrIndex`, `Imm ifkRefTypeIndex`): if
  the value matches the cast target → `IP := B` (with `D := A` for the
  branch's value threading, per Track B's convention — confirm whether the
  dest is written on the taken or fallthrough edge from the emission; the
  `DestKind ifkDestReg` says a value is produced). `br_on_cast` branches when
  the cast SUCCEEDS. Precise value threading: read
  `Wasm.Validator.Body`'s `br_on_cast` emission for which edge writes `Dest`
  and whether the target stub moves it. (Open item O-3.)
- `iroBrOnCastFail` (`Dest`, `A`, `B`, `Imm`): branches when the cast FAILS.
- `iroAnyConvertExtern` / `iroExternConvertAny` (`Dest`, `A`): identity on
  the representation (`D := A`) — same as `EvalInitExpr`. KNOWN LIMITATION
  M7 (`Wasm.Runtime.Gc.GcAbsKindOf` header): after
  `extern.convert_any`/`any.convert_extern` the value's HIERARCHY should
  change but the kind-only abstract map does not reflect it, so a subsequent
  `ref.test (ref extern)` / `(ref any)` gives the wrong answer for a boxed
  aggregate. Track E's identity implementation makes the gap OBSERVABLE for
  the first time. DECISION: implement the ops as identity (matching
  `EvalInitExpr`), ship the interpreter with a MARKED staged test pinning the
  current (wrong-for-cross-hierarchy) answer, and file the fix as a
  follow-up requiring either a wrapper object at the convert site or a header
  hierarchy flag (neither is in Track E's scope, and a pure header flag
  cannot cover externalized i31/null). The corpus `ref_test`/`ref_cast`
  cases that cross hierarchies will FAIL and must be enumerated in the
  Track E report, not hidden. (Open item O-4; this is the one place Track E
  knowingly diverges, inherited from Track D's M7.)

### 3.10 GC — struct, array, i31

All go through `Wasm.Runtime.Gc` (`Store.Heap`) methods, which own the
layout, packing, null traps, bounds traps, and the write barrier. The
interpreter supplies engine type ids via `Instance.EngineTypeIds[
moduleTypeIndex]` (never module-local ids — the heap needs engine ids;
`exec-type`). CAUTION (corpus dependence): the pinned server reports the GC
family as `can_trap:false` with empty `traps[]` and empty exec prose — the
served data is systematically incomplete for 3.0 GC (noted in
`Wasm.Runtime.Traps` and `Wasm.Runtime.Store`). The trap kinds/messages
below are the corpus-CONFIRMED ones Track D already settled; where a
behaviour is UNCONFIRMED it is flagged and the settling corpus file named.

- `iroStructNew` (`Dest`, `A ifkAuxIndex` = field-source regs, `Imm
  ifkTypeIndex`): `obj := Heap.AllocStruct(EngineIdOf(Instance, Imm))`;
  PUBLISH `D.Ref := obj` FIRST (the slot is a root; a Pascal local is not,
  and later field writes cannot allocate but the publish-first discipline
  matches `EvalInitExpr` and is safe); then for each field `i` in the aux
  block, `Heap.StructSet(obj, i, Reg[block[i]])`. `StructSet` truncates
  packed fields and barriers ref fields.
- `iroStructNewDefault` (`Dest`, `Imm`): `obj := AllocStruct(...)`;
  `D.Ref := obj`; `Heap.StructSetDefaults(obj)` (checks each field HAS a
  default; a missing default is an internal invariant violation — the
  validator guaranteed it).
- `iroStructGet` (`Dest`, `A` = ref, `Imm ifkPacked` = `IrPack(typeIndex,
  fieldIndex)`): `IrUnpack(Imm, _, fieldIdx)`; `D := Heap.StructGet(A.Ref,
  fieldIdx)`. `StructGet` traps `wtkNullStructReference`
  (`'null structure reference'`) on a null ref (Track D wired
  `StructField` → `TrapNow(wtkNullReference)` currently — see the note
  below), unpacked fields only.
- `iroStructGetS` / `iroStructGetU`: `Heap.StructGetSigned` /
  `StructGetUnsigned` for packed fields (sign/zero extend from the packed
  width, `aux-unpackfield`); write the Int32/UInt32 into `D`.
- `iroStructSet` (`A` = ref, `B` = value, `Imm ifkPacked`): `Heap.StructSet(
  A.Ref, fieldIdx, Reg[B])` (barriered; truncates packed).

  NOTE on the null message split: `Wasm.Runtime.Gc.StructField`/`ArrayElement`
  currently call `TrapNow(wtkNullReference)` (the BARE kind), but the corpus
  and `Wasm.Runtime.Traps` define distinct kinds — `wtkNullStructReference`
  (`'null structure reference'`, `struct.wast:155-156`) and
  `wtkNullArrayReference` (`'null array reference'`). Track D left the Gc
  null traps as the bare kind (the split kinds exist but the raise sites use
  `wtkNullReference`). Track E must make struct/array/i31 accesses raise the
  SPLIT kind. DECISION: the interpreter checks null ITSELF before calling the
  heap accessor and raises the correct split kind, OR (cleaner) Track E
  updates the `Wasm.Runtime.Gc` raise sites to the split kinds now that a
  tier drives them. Prefer the latter (one source of truth) — it is a Track E
  change to `Wasm.Runtime.Gc` raise sites, in-scope because Track E is the
  first consumer and the split kinds were added FOR it (the Traps header:
  "Track E wires the raise sites"). Update: `StructField`/`StructFieldCount`/
  `StructSetDefaults` → `wtkNullStructReference`; `ArrayElement`/
  `ArrayLength`/`FillRange`/`ArraySetDefaults` → `wtkNullArrayReference`;
  i31 accessors → `wtkNullI31Reference`. (Open item O-5.)
- `iroArrayNew` (`Dest`, `A` = element value, `B` = length, `Imm
  ifkTypeIndex`): `obj := AllocArray(engineId, Reg[B].U32)`; `D.Ref := obj`;
  `Heap.ArrayFill(obj, Reg[A])`.
- `iroArrayNewDefault` (`Dest`, `A` = length, `Imm`): `AllocArray`; publish;
  `Heap.ArraySetDefaults(obj)`.
- `iroArrayNewFixed` (`Dest`, `A ifkAuxIndex` = element regs, `Imm`): length
  = block count; `AllocArray`; publish; `ArraySet` per element.
- `iroArrayNewData` (`Dest`, `A` = offset reg, `B` = length reg, `Imm
  ifkPacked` = `IrPack(typeIndex, dataIndex)`): `AllocArray(engineId, len)`;
  publish; copy `len` elements from the data segment bytes at `offset`
  (element width from the array's element storage), trapping `out of bounds
  memory access` if `[offset, offset+len*width)` escapes the data segment
  (`array_init_data.wast:71` confirms `out of bounds array access` for the
  init form; `array.new_data` OOB on the DATA side is a memory-style
  bound — settle the exact message against `array_new_data` corpus; likely
  `out of bounds memory access` for the data source). This needs a new Gc
  helper `Heap.ArrayInitFromData` or the interpreter reads bytes and
  `ArraySet`s each — prefer a heap helper that reads layout once
  (avoid the quadratic `ArraySet` per element the Gc header warns about).
  (Open item O-6; message UNCONFIRMED — name the settling file
  `array_new_data.wast`.)
- `iroArrayNewElem` (`Dest`, `A` = offset, `B` = length, `Imm ifkPacked` =
  `IrPack(typeIndex, elemIndex)`): `AllocArray`; publish; copy `len` refs
  from the elem instance at `offset` (barriered), trapping OOB.
- `iroArrayGet` / `iroArrayGetS` / `iroArrayGetU` (`Dest`, `A` = ref, `B` =
  index, `Imm ifkTypeIndex`): `Heap.ArrayGet`/`ArrayGetSigned`/
  `ArrayGetUnsigned(A.Ref, Reg[B].U32)`. Traps `wtkNullArrayReference` on
  null, `wtkArrayOutOfBounds` (`'out of bounds array access'`,
  `array_init_data.wast:71`) on index ≥ length.
- `iroArraySet` (`Dest` = ref, `A` = index, `B` = value, `Imm`):
  `Heap.ArraySet(Reg[Dest].Ref, Reg[A].U32, Reg[B])` (barriered).
- `iroArrayLen` (`Dest`, `A` = ref): `ValueSetU32(D, Heap.ArrayLength(A.Ref))`
  (traps null array reference).
- `iroArrayFill` (`A ifkAuxIndex`, `Imm ifkTypeIndex`): the aux block holds
  `[ref, index, value, count]` register list (confirm operand order against
  `Wasm.Validator.Body`'s `array.fill` emission — `DestKind ifkUnused; AKind
  ifkAuxIndex`); `Heap.ArrayFill(ref, offset, count, value)` (the ranged
  overload; traps `out of bounds array access`). (Open item O-7 — aux
  operand order.)
- `iroArrayCopy` (`A ifkAuxIndex`, `Imm ifkPacked` = `IrPack(dstType,
  srcType)`): aux block `[dstRef, dstIdx, srcRef, srcIdx, count]`; a new Gc
  helper `Heap.ArrayCopy` (barriered, overlap-safe, per-element layout read
  once, both null checks, both bounds → `out of bounds array access`).
  (Open item O-8 — needs the helper; Gc currently has no array.copy.)
- `iroArrayInitData` / `iroArrayInitElem` (`A ifkAuxIndex`, `Imm ifkPacked`):
  aux block `[destArrayRef, destIndex, srcOffset, count]`; copy from the
  data segment / elem instance into the array, bounds-checked both sides.
  Needs Gc helpers (Open item O-8).
- `iroRefI31` (`Dest`, `A`): `D.Ref := MakeI31Ref(Reg[A].I32)` — unboxed, no
  allocation (the IR flags it a safepoint conservatively; harmless).
- `iroI31GetS` (`Dest`, `A`): if `RefIsNull(A.Ref)` →
  `TrapNow(wtkNullI31Reference)` (`'null i31 reference'`, `i31.wast:53-54`);
  else `ValueSetI32(D, I31GetSigned(A.Ref))`.
- `iroI31GetU` (`Dest`, `A`): null → `wtkNullI31Reference`; else
  `ValueSetU32(D, I31GetUnsigned(A.Ref))`.

## 4. Host calls

An imported function is a host callback. `TWasmFuncInst` with
`Kind = wfkHost` carries `Callback: TWasmHostFunc` and `HostData: Pointer`.
The signature (Track D, `Wasm.Runtime.Store`):

```
TWasmHostFunc = procedure(const AStore: TWasmStore; const AData: Pointer;
                          const AParams: PWasmValue; const AResults: PWasmValue);
```

### 4.1 The callback contract (what Track F implements against)

- `AParams` points at a contiguous array of the callee's parameter values,
  in declaration order, one `TWasmValue` each. `AResults` points at a
  contiguous array the callback FILLS IN PLACE, in result declaration order.
- Both slices are provided by the interpreter (§4.2) and owned by the
  interpreter for the call's duration; the callback must not retain them.
- **Capability boundary (deny-by-default).** The host surface is Track F;
  the interpreter's obligation is only to CALL the callback and marshal
  values. Nothing about a host call reaches the filesystem/clock/env/network
  — that is entirely the embedder's callback body, granted only via an
  import the embedder wired. The interpreter grants nothing.
- **A callback holding a `TWasmRef` across an allocation must register it**
  as a host root (`RootRegister`/`RootScopeEnter`, contract HOST-1) — the
  interpreter's param/result slices are NOT on the GC frame chain, so a ref
  the callback stashes is invisible to the collector unless rooted. This is
  Track F's obligation; Track E documents it.
- **Error propagation**: a callback raising `EWasmTrap` traps the guest — it
  propagates out of the interpreter to the same trampoline as any wasm trap
  (see §4.3). A callback raising an ordinary `EWasmError` propagates as an
  ordinary Pascal exception (the store is not in a guest-fault state); the
  `WasmInvoke` `try/finally` (Track D) restores `CurrentTrampoline`, so it
  does not corrupt the trap machinery.

### 4.2 Invoking a host call from dispatch

At `iroCall`/`iroCallIndirect`/`iroCallRef` when
`Store.Funcs[Addr].Kind = wfkHost`, the interpreter does NOT push a wasm
activation. It marshals a param buffer, calls, and marshals results back
into the caller's dest registers:

```
procedure HostCall(Ctx; Caller; Ins; Addr);
var ArgAux, DstAux, ArgN, ResN, i: UInt32;
    ParamBuf, ResBuf: PWasmValue;   { context-owned scratch, NOT dynamic locals }
begin
  ArgAux := Ins^.A; ArgN := IrAuxBlockCount(Caller^.Fn^.AuxU32, ArgAux);
  DstAux := Ins^.B; ResN := IrAuxBlockCount(Caller^.Fn^.AuxU32, DstAux);

  ParamBuf := Ctx^.HostArgScratch;   { fixed, sized to module max param count }
  ResBuf   := Ctx^.HostResScratch;   { fixed, sized to module max result count }

  for i := 0 to ArgN - 1 do
    ParamBuf[i] := (PWasmValue(Ctx^.Values) + Caller^.Base)[
                     IrAuxBlockItem(Caller^.Fn^.AuxU32, ArgAux, i)];

  Store.Funcs[Addr].Callback(Store, Store.Funcs[Addr].HostData, ParamBuf, ResBuf);

  for i := 0 to ResN - 1 do
    (PWasmValue(Ctx^.Values) + Caller^.Base)[
      IrAuxBlockItem(Caller^.Fn^.AuxU32, DstAux, i)] := ResBuf[i];

  Inc(Caller^.IP);   { fall through past the call }
end;
```

The scratch buffers are context-owned, fixed at the module's maximum param
and result arity (computed at instantiation from the IR, stored on the
context or looked up per instance), so no per-call allocation and no managed
state a `TrapNow` could skip (TRAP-1). A host call is a safepoint of sorts —
the callback may itself invoke guest code (§4.3) and allocate — but the
param/result buffers hold values, not roots the collector must find: a
`TWasmRef` argument is ALSO reachable from the caller's frame register (still
on the chain) until the callback returns and the caller's dest is
overwritten, so it stays traced. A ref RESULT the callback produces is not on
any frame until it is written back — but the callback produced it, and if it
came from an allocation inside the callback the callback had to root it
(HOST-1); once written into the caller's dest register (a ref-typed slot on
the live frame) it is traced. There is no gap because the write-back happens
before the next interpreter safepoint.

### 4.3 Re-entrancy (host calls guest)

A host callback may call `WasmInvoke`/the embedding invoke to run more guest
code (Track F). That nests: a new trampoline (its own `Prev`) and a
continuation on the SAME interpreter context above the current frames
(§1.5's `SavedDepth`/`SavedTop`). The outer frames are untouched. This is
why the context is per-store and reused, and why `InterpTierInvoke` saves
and restores the cursors.

### 4.4 Tail call to a host function

`return_call` to a host func: the spec makes it observationally a tail call,
but a host call cannot replace a wasm frame (it has none). The correct
behaviour: perform the host call, take its results as THIS frame's results,
and return them to this frame's caller (i.e., do the host call, then
`DoReturn` with the host results routed to the frame's `RetDest`). Marshal
host results into a buffer, then execute the return path. Concretely
`ReturnHostCall` = `HostCall` into a temp, then copy the temp into the
current frame's return block, then `DoReturn`. This keeps O(1) stack (no wasm
frame is added).

### 4.5 Host function as the entry point

`InterpTierInvoke` with `Addr` naming a host func (e.g. a `.wast` `invoke` of
an imported/exported host function, or `RunPendingStart` where start is
host): call the callback directly with the entry `AParams`/`AResults`, no
wasm frame. §1.5 `InvokeHostEntry`.

### 4.6 try_table and throw — staged to Track H

The IR carries `try_table` handler tables (`TWasmIrHandler`/
`TWasmIrCatchClause`) and `iroThrow`/`iroThrowRef` NOW (Track B emits them),
but no exception can be thrown until Track H. DECISION (resolving the
contract's open question): Track E does NOT install handler tables and does
NOT execute throw. Rationale:

- With no `throw`/`throw_ref` executed and no host-thrown exception model,
  a handler can never FIRE, so installing handler tables would be dead
  bookkeeping on every call boundary for zero observable effect — and the
  activation model has no exception-unwind path yet (the epoch obligation on
  handler resume, `TWasmIrHandlers` doc, is a Track H concern).
- Reaching `iroThrow`/`iroThrowRef` in a validated module means the module
  USES exceptions, which is a Track H feature; the honest response is
  `raise EWasmError('exception handling is not implemented')` — an internal
  "not yet" rather than a wrong trap or silent misbehaviour (the contract
  forbids silent misbehaviour).
- The corpus's exception tests therefore SKIP/FAIL loudly under Track E and
  are enumerated in the report; they light up with Track H. A `try_table`
  with no throw inside its body runs its body normally (the handler table is
  simply never consulted because nothing throws), so a module that has a
  `try_table` but never throws still executes — the interpreter treats the
  `try_table` region as ordinary code (Track B already lowered its body to
  straight-line IR; `try_table` itself is in the "vanish at lowering" list).
  Only an actual `iroThrow`/`iroThrowRef` op stages out. This means many
  EH-corpus modules that exercise non-throwing paths still pass.

## 5. Traps and the trampoline

### 5.1 How a mid-dispatch trap becomes an EWasmTrap

The interpreter runs INSIDE `WasmInvoke` (Track D installs the trampoline at
guest entry; `RunPendingStart` and the embedding/`.wast` runner both route
through it). When the interpreter detects a spec trap condition it calls
`TrapNow(kind)` (or `TrapNowDetail(kind, index)`), which:

- with a trampoline installed (always, during guest execution) records the
  kind in `CurrentTrampoline^.Kind` and `LongJmp`s to the trampoline's
  `SetJmp`, unwinding every interpreter Pascal frame WITHOUT running their
  finalisation;
- the trampoline's else-branch (`WasmInvoke`) then calls `RaiseTrapDirect`,
  which allocates the message string and raises `EWasmTrap` on ordinary
  ground.

The interpreter NEVER wraps its dispatch in `try/except`. It raises no
`EWasmTrap` itself — only `TrapNow`. This is ADR-0009: traps unwind to the
per-invocation trampoline, never out of a handler or an interpreter-local
`except`.

### 5.2 Stack exhaustion — how a non-recursive interpreter honours assert_exhaustion

Because the interpreter does not recurse the Pascal stack, an unbounded
recursion does not overflow the native stack — it exhausts the EXPLICIT
activation stack. A `DoCall`/`InterpTierInvoke`/`DoReturnCall` that would push
past `DepthCap` frames OR past `ValueCap` value slots calls
`TrapNow(wtkStackExhausted)` → `MSG_TRAP_STACK_EXHAUSTED = 'call stack
exhausted'` (CONFIRMED, `call.wast:337`). Both caps are tunables (§1.1). This
is the mechanism `assert_exhaustion` tests (deep non-tail recursion trips the
cap; deep TAIL recursion does NOT, because `return_call` never advances
`Depth` or `ValueTop` — the million-iteration tail loop runs in bounded
Pascal and bounded value stack, which is the acceptance test the contract
names).

The exhaustion check runs BEFORE any frame mutation, so a trapping push
leaves the activation stack and the GC chain consistent (the caller frame is
whole and on the chain).

### 5.3 No managed Pascal state live across a TrapNow (ADR-0009 amendment / TRAP-1)

Every interpreter frame between a `TrapNow` and the trampoline holds NO
managed state a skipped finalisation would leak: no `string` local, no
`SetLength` dynamic-array local, no interface, no `try/finally` whose cleanup
matters, across any point a trap can fire. Concretely:

- The dispatch loop's locals (`Act`, `Fn`, `Reg`, `IP`, `Code`, `Ins`,
  `EpochCache`) are all plain pointers/integers.
- Argument marshaling scratch (`Tmp` in `DoReturnCall`, `ParamBuf`/`ResBuf`
  in `HostCall`) is CONTEXT-OWNED FIXED storage, not a dynamic local — a
  `TrapNow` skipping the marshaling leaks nothing because the buffer belongs
  to the long-lived context.
- The value stack and activation array are the context's; a trap does not
  free them. After the trap, the context cursors (`Depth`, `ValueTop`) are
  STALE (the frames the jump skipped were never popped). They are re-synced
  at the trampoline landing: Track D's guest-entry `try/finally` calls
  `Heap.ResetFrames` (drops the whole GC chain), and Track E adds the
  companion `Ctx^.Depth := SavedDepth; Ctx^.ValueTop := SavedTop` reset at
  the SAME landing (in the same `finally`, or in a Track-E-owned wrapper that
  Track D's `RunPendingStart`/embedding invoke calls). Because the skipped
  frames held no managed state (TRAP-1), dropping them leaks nothing — this
  is exactly `Heap.ResetFrames`'s contract, extended to the interpreter's
  cursors.

  IMPLEMENTATION NOTE: the cleanest place for the cursor reset is a Track E
  wrapper `RunGuest(Ctx, ...)` that Track D's guest-entry points call
  through `WasmInvoke`, structured as
  `entrySnapshot := (Depth, ValueTop); try Run finally Depth,ValueTop :=
  snapshot`. But that `finally` is a managed-cleanup frame — is it TRAP-1
  safe? Yes, IF it lives ABOVE the trampoline (like `WasmInvoke`'s own
  `try/finally`), i.e., it is not one of the guest frames the `LongJmp`
  skips. The snapshot/reset must therefore be in the SAME frame as (or above)
  the `SetJmp`, not inside `Run`. Simplest: fold the cursor reset into
  Track D's existing `RunPendingStart` `finally` (which already resets the GC
  frames) and the embedding invoke's equivalent — the interpreter exposes
  `ResetInterpContext(Store)` for them to call there. (Open item O-9 —
  coordinate the exact wiring with whoever owns the embedding invoke, Track F;
  for `RunPendingStart` Track D's `finally` is the site.)

### 5.4 The epoch interrupt trap

Covered in §3.5: at a safepoint jump, a changed `Store.Epoch` →
`TrapNow(wtkEpochInterrupt)` → `'interrupt'`. It unwinds to the trampoline
like any trap.

## 6. The corpus result comparator (the proof of the tier)

`Wasm.Wast.Runner` today judges only `(module binary ...)` decode/validate
and `assert_malformed`/`assert_invalid`; everything needing execution is
`Skipped(WAST_REASON_NEEDS_TIER)`. Track E turns on `assert_return`,
`assert_trap`, `assert_exhaustion`, `invoke` (as an action), `register`, and
`get`/`get-global`, for BINARY modules. Text modules still skip pending the
wat assembler (Track C).

### 6.1 Instantiation in the runner

The runner keeps a running "current instance" (and a registry for
`register`). For a `(module binary ...)` command it now: decode → validate
(→ `TWasmIrModule`) → `RegisterInterpreter(Store)` → resolve imports by name
against the registry → `InstantiateModule` (via `Wasm.Runtime.Instantiate`)
→ `WasmInvoke(RunPendingStart)`. A trap during instantiation (active-segment
OOB) or start is caught as the module command's outcome. The runner needs a
`TWasmStore`/`TWasmEngine` lifecycle per script (one engine, one store,
reused across the script's commands, mirroring the reference interpreter's
per-script state). This is new plumbing in `Wasm.Wast.Runner` (it currently
uses only `Wasm.Decoder`/`Wasm.Validator`); it gains uses of
`Wasm.Runtime.Store`, `.Instantiate`, `.Traps`, `Wasm.Interp`.

### 6.2 The argument/expected value parser

Actions and `assert_return` expected results are s-expressions like
`(i32.const 5)`, `(i64.const -1)`, `(f32.const nan:canonical)`,
`(f64.const 0x1.5p3)`, `(ref.null func)`, `(ref.null extern)`,
`(ref.extern 1)`, `(ref.host 2)`, `(ref.func)`, and `(v128.const ...)`. The
runner needs a value parser producing a `TWasmValue` PLUS an expected-CLASS
tag for NaN and reference-identity cases. `Wasm.Wast` already lexes/parses
the s-expressions into `TWastNode` trees, so the parser walks a node:

- `(i32.const N)` → `MakeValueI32(parse int, allowing 0x hex and sign)`.
- `(i64.const N)` → `MakeValueI64`.
- `(f32.const X)` / `(f64.const X)`: X may be a decimal float, a hex float
  (`0x1.5p3`), `inf`/`-inf`, `nan`, `nan:canonical`, `nan:arithmetic`, or
  `nan:0x...` (a specific payload). For an ARGUMENT, produce the exact bit
  pattern (canonical for bare `nan`). For an EXPECTED result, produce a
  MATCHER: either an exact bit pattern or a NaN CLASS (`canonical` /
  `arithmetic`). Float parsing (decimal and hex, with correct rounding and
  payload handling) is the substantial new code — reuse the reference
  interpreter's grammar; it must round-trip the corpus's literals exactly
  (the corpus is where it is tested).
- `(ref.null func)` / `(ref.null extern)` / `(ref.null any)` etc. →
  `MakeValueNullRef` (null is null regardless of hierarchy — the encoding
  does not distinguish, `WASM_REF_NULL`).
- `(ref.extern N)` / `(ref.host N)`: an OPAQUE host reference with identity
  `N`. The runner must mint a stable host reference per `N` (a boxed host
  value via `Heap.AllocHostBox(N, nil)` registered as a host root, memoized
  per `N` in the runner so `(ref.extern 1)` is the SAME reference each time),
  because `assert_return` compares reference IDENTITY: an action returning
  `(ref.extern 1)` must return the exact reference the runner would mint for
  `1`. See §6.4.
- `(ref.func)` / `(ref.func N)`: a funcref matcher — matched by identity
  against the store's function handle.
- `(v128.const ...)`: SIMD — the value parser recognises it but the
  comparison STILL SKIPS (SIMD execution is Track G); §6.5.

### 6.3 The comparator

`assert_return (invoke "f" args...) expected...`: marshal the parsed args
into a host param buffer, `WasmInvoke` the export, collect results into a
host result buffer, compare each result against the corresponding expected
matcher:

- **Exact numeric** (i32/i64, and float with an exact expected pattern):
  BITWISE equality (`result.Bits = expected.Bits` for the value width — mask
  to 32 bits for i32/f32). Bitwise, not arithmetic, so `-0.0` ≠ `+0.0` and
  NaN payloads are checked exactly where the expected is exact.
- **NaN class** (`nan:canonical` / `nan:arithmetic`): per width, test the
  result's bits:
  - f32 canonical: `(bits and $7FFFFFFF) = $7FC00000` (exponent all ones,
    payload exactly the MSB). f64 canonical: `(bits and $7FFFFFFFFFFFFFFF) =
    $7FF8000000000000`. (Sign is ignored — the spec's canonical NaN class
    accepts either sign; the interpreter produces positive, which passes.)
  - f32 arithmetic: exponent all ones (`(bits and $7F800000) = $7F800000`)
    AND significand nonzero AND payload-MSB set (`(bits and $00400000) <>
    0`). f64 arithmetic: `(bits and $7FF0000000000000) = $7FF0000000000000`
    AND `(bits and $0008000000000000) <> 0` AND lower payload not requiring
    canonical. Because the interpreter always emits canonical (§3.2),
    every produced NaN passes BOTH classes; the class test still guards
    against a non-NaN or wrong-exponent result.
- **`(either ...)` multi-result** (relaxed-SIMD): a result matches if it
  equals ANY of the alternatives. Since relaxed SIMD is Track G, these
  cases still SKIP; the comparator provides the HOOK (parse `(either ...)`
  into a set of matchers, match-if-any) but the enclosing SIMD assertion is
  skipped upstream (§6.5). Wiring the hook now means Track G only flips the
  skip.
- **Reference identity** (`ref.extern N`/`ref.host N`/`ref.func`): compare
  `result.Ref` against the runner's minted reference for `N` (raw `TWasmRef`
  equality — the payload of the host box, or the function handle pointer).
  `ref.null` matches iff `RefIsNull(result.Ref)`.

`assert_trap (invoke ...) "msg"`: `WasmInvoke` the action; expect an
`EWasmTrap` whose message the expected string is a PREFIX of
(`WastMessageMatches`, the reference rule). A trap with the wrong message is
a FAIL that records both strings (this is what settles the still-UNCONFIRMED
execution-tier message prefixes). No trap → `WAST_NO_ERROR` fail.

`assert_exhaustion (invoke ...) "call stack exhausted"`: same as
`assert_trap` with the exhaustion message; the depth/value caps make it fire.

`invoke` (bare action, not under an assertion): run for effect; a trap is a
FAIL (a bare invoke is expected to succeed). `register "name"` records the
current instance under `name` in the import registry. `get`/`get-global`
reads an exported global's value and (under `assert_return`) compares it.

### 6.4 Host reference identity

The runner maintains `HostRefs: map[UInt32] -> TWasmRef`. `(ref.extern N)`
and `(ref.host N)` resolve to `HostRefs[N]`, minting a boxed host value
(`Heap.AllocHostBox(N, nil)`, kept alive as a host root for the script) on
first use. The SAME `N` always yields the SAME reference, so identity
comparison works both as an argument (passed in) and as an expected result
(compared out). `extern` vs `host` distinguishes the hierarchy the reference
is presented as, but v1 boxes both as `wokHostBox` (the M7 limitation means
hierarchy conversions are imprecise — §3.9 O-4 — so some `ref.extern`/`any`
cross-hierarchy assertions fail and are enumerated).

### 6.5 What still skips after Track E

- **SIMD** `assert_return`/`assert_trap` whose module or expected uses
  `v128` — execution is Track G. The runner recognises `v128.const` /
  `(either ...)` in the parser (so it does not crash) but classifies these
  as SKIP (or STAGED, reusing the existing staged mechanism) rather than
  running them.
- **Text/quoted modules** — the wat assembler is the rest of Track C.
- **Exception-handling** modules that actually THROW — Track H (§4.6);
  a `try_table` with no reachable throw runs.
- **`extern.convert_any`/`any.convert_extern` cross-hierarchy** ref.test/cast
  assertions — the M7 limitation (O-4); these FAIL loudly and are counted,
  not hidden.

### 6.6 Corpus pass-delta estimate

Today: pass=1034, fail=35, skip=66,050, staged=6 over the binary subset. The
overwhelming majority of the 66,050 skips are `assert_return`/`assert_trap`
over binary modules that need a tier. Turning them on lets the numeric,
reference, memory, table, and non-throwing GC suites judge for the first
time. Order-of-magnitude estimate (to be replaced by the measured tally in
the Track E report): the non-SIMD, non-EH, non-text `assert_return`/
`assert_trap`/`assert_exhaustion` commands number in the low tens of
thousands; a correct interpreter should convert most of them from SKIP to
PASS, with a residue of FAILs concentrated in (a) the M7 cross-hierarchy
cases, (b) any still-UNCONFIRMED trap-message spellings the corpus now
settles, and (c) float rounding/NaN edge cases that shake out the numeric
helpers. Expect the biggest single PASS jump from `i32.wast`/`i64.wast`/
`f32.wast`/`f64.wast`/`conversions.wast`/`memory*.wast`/`call*.wast`. SIMD
and text remain the bulk of the residual skip. The report MUST publish the
new pass/fail/skip/staged tallies and enumerate every new FAIL with both
message strings (the runner already records both).

## 7. Unit layout and wave plan

### 7.1 Units (bottom-up; interp sits above `Wasm.Runtime.*` and `Wasm.Ir`, below Track F)

- **`Wasm.Interp.Numeric`** — pure leaf functions for every numeric op:
  integer `add/sub/mul/div/rem/and/or/xor/shl/shr/rotl/rotr/clz/ctz/popcnt`
  (i32/i64), float `add/sub/mul/div/min/max/sqrt/ceil/floor/trunc/nearest/
  neg/abs/copysign` (f32/f64), all conversions and (sat) truncations, and the
  NaN-canonicalization helper. No dependency beyond `Wasm.Core`/
  `Wasm.Runtime.Values`/`Wasm.Runtime.Traps` (it calls `TrapNow` for
  div/trunc traps). `{$OVERFLOWCHECKS OFF}`/`{$RANGECHECKS OFF}` locally
  where wasm wraps. UNIT-TESTABLE IN ISOLATION with literal inputs and
  expected bit patterns — no store, no IR.
- **`Wasm.Interp.pas`** — the activation stack (`TWasmInterpContext`,
  `TWasmActivation`), the dispatch loop (`Run`), `DoCall`/`DoReturn`/
  `DoReturnCall`/`HostCall`, `InterpTierInvoke`, `RegisterInterpreter`,
  `InterpContextFor`, `ResetInterpContext`. Depends on `Wasm.Ir`,
  `Wasm.Runtime.Store`/`.Memory`/`.Gc`/`.Traps`/`.Values`, and
  `Wasm.Interp.Numeric`. This is where the frame model, the GC-1/GC-2
  discharge, the memory/table/GC op dispatch, and the seam live. Co-located
  `Wasm.Interp.Test.pas`.
- **`Wasm.Interp.Numeric.Test.pas`** — the numeric conformance micro-suite.
- **`Wasm.Wast.Runner`** (modified) — the value parser
  (`Wasm.Wast.Values` helper unit if the parser is large), the comparator,
  the per-script store/engine lifecycle, and the action/assertion execution.
  The float-literal parser and NaN-class matcher may warrant their own unit
  `Wasm.Wast.Values.pas`.

Possible split if `Wasm.Interp.pas` grows unwieldy: `Wasm.Interp.Frame.pas`
(context + activation + push/pop/tail-replace) separate from
`Wasm.Interp.pas` (dispatch). Decide during Wave 2 by size; the frame model
is small enough that one unit likely suffices.

Layering rule: nothing in `Wasm.Interp*` is used by `Wasm.Runtime.*` (that
would invert the seam). `Wasm.Runtime.Store` calls Track E only through the
`TierInvoke` hook, set at runtime.

### 7.2 The RTL policy where it bites

- The dispatch loop and `Wasm.Interp.Numeric` are the hot paths. NO RTL
  allocation per instruction: the register file is pre-reserved, the arg
  scratch is context-owned, `case Op of` is a jump table, and arithmetic is
  leaf functions. `Move`/`FillChar` (compiler intrinsics, not FCL) are the
  only RTL touched on the memory bulk path and are the correct primitive.
- `clz/ctz/popcnt` start as plain loops; switch to `BsrDWord`/`BsfDWord`/
  `PopCnt` intrinsics only behind a `wasmbench` number (RTL policy).
- Float ops use FPU primitives (`Sqrt`, arithmetic operators); AVOID the
  `Math` unit's `Min`/`Max`/`Floor`/`Ceil` (they have their own NaN/edge
  behaviour and are FCL) — implement wasm min/max/nearest/trunc/ceil/floor
  explicitly in `Wasm.Interp.Numeric` so the semantics are ours and testable.
- NaN detection by bit test, never `x <> x` (foldable) and never a `Math`
  helper.

### 7.3 The interpreter context lifecycle

`InterpContextFor(Store)` returns the store's context, creating it on first
call (lazy — a store that never runs guest code allocates nothing). Storage:
a private field on a Track-E-owned side table keyed by store, OR — cleaner —
the store already has a `TierInvoke` field; add a companion opaque
`TierContext: Pointer` field to `TWasmStore` set by `RegisterInterpreter`
and freed by a finalizer the interpreter registers. Decision: add
`TWasmStore.TierContext: Pointer` (opaque, like `TierInvoke`) so the context
lifetime is tied to the store with no external map. `RegisterInterpreter`
allocates it; `TWasmStore.Destroy` frees it via a hook or the interpreter
frees it when the store is torn down (coordinate the one-line store change,
Open item O-10). The context owns the two GetMem reservations and frees them
on teardown. `ResetInterpContext(Store)` sets `Depth := 0; ValueTop := 0`
after a trap unwind (§5.3), called at the same landing as
`Heap.ResetFrames`.

### 7.4 Open items to settle against source/corpus during implementation

- **O-1** RESOLVED — memarg `Imm` is the raw u64 offset (no align packing);
  store value in `Dest`, index in `A`, mem index in `B`
  (`Wasm.Validator.Body.HandleLoadStore`, verified).
- **O-2** `Store.TableInitFromElem` needs a `src`/`count` slice variant, and
  a `Store.TableCopy` barriered method must be added.
- **O-3** `br_on_cast`/`br_on_cast_fail` value threading — which edge writes
  `Dest`, confirmed from `Wasm.Validator.Body` emission.
- **O-4** M7 cross-hierarchy `extern.convert`/`any.convert` — ships imprecise
  with a marked staged test; enumerate failing corpus cases.
- **O-5** split null-trap kinds — Track E updates `Wasm.Runtime.Gc` raise
  sites to `wtkNullStruct/Array/I31Reference` (the kinds exist for this).
- **O-6/O-8** new `Wasm.Runtime.Gc` helpers: `ArrayInitFromData`,
  `ArrayInitFromElem`, `ArrayCopy` (layout read once, barriered, overlap-safe,
  both-sides bounds); array.new_data/new_elem source-bound messages.
- **O-7** `array.fill`/`array.copy`/`array.init_*` aux operand order —
  confirmed from `Wasm.Validator.Body`.
- **O-9/O-10** cursor-reset wiring at the trampoline landing, and the
  `TWasmStore.TierContext` field + teardown — coordinate the one-line
  Track D/store changes.

### 7.5 Waves (each gate-green and independently testable)

- **Wave 1 — `Wasm.Interp.Numeric` + its test.** No store, no frames. Unit
  tests assert bit-exact results and traps for every numeric op incl. NaN
  classes, div/rem/trunc traps, min/max/nearest/copysign edges. Unlocks
  nothing in the corpus yet but de-risks the largest correctness surface in
  isolation.
- **Wave 2 — the activation core + dispatch for numeric/parametric/variable/
  control/local-move.** `TWasmInterpContext`, `Run`, `DoCall`/`DoReturn`/
  `DoReturnCall`, `InterpTierInvoke`, `RegisterInterpreter`, epoch check,
  stack exhaustion. GC-1/GC-2 discharge for plain frames. Direct-API tests:
  hand-build a module (literal bytes → decode → validate → instantiate),
  invoke an export, assert results; a deep tail-recursive loop of 1e6
  iterations must run in bounded stack; a deep non-tail recursion must trap
  `call stack exhausted`. Unlocks: `RunPendingStart` actually executes; the
  numeric/control corpus becomes runnable once the runner lands (Wave 5).
- **Wave 3 — memory + table + reference + global.** All chokepoint loads/
  stores/bulk ops, table ops, ref ops, global get/set. Direct-API tests per
  family, traps by kind+message. Unlocks the memory/table/ref corpus.
- **Wave 4 — GC (struct/array/i31/ref.test/cast/br_on_cast) + host calls +
  the split null kinds + the new Gc helpers.** Direct-API tests incl. a
  collection triggered mid-construction (publish-first discipline), packed
  get_s/get_u, cast failure, null splits. Host-call round-trip test with a
  Pascal callback (marshaling in/out, a host trap propagating). Unlocks the
  GC corpus (minus the M7 residue) and host-import modules.
- **Wave 5 — the `.wast` runner integration.** The value parser, the
  comparator (bitwise + NaN class + reference identity + the `either` hook),
  the per-script store lifecycle, action/assertion execution, and the
  SIMD/text/EH skip classification. Report the new pass/fail/skip/staged
  tallies over `tests/spec/testsuite` and enumerate every new FAIL with both
  message strings. THIS is the deliverable that proves the tier.

Waves 2–4 are independently testable via direct invoke of hand-built modules
before the runner exists; Wave 5 is where the corpus judges. Waves 3 and 4
can proceed in parallel once Wave 2 lands (they touch disjoint op families
and disjoint store surfaces).

## 8. Observational-identity notes for the future JIT (Track I)

The interpreter is the reference (ADR-0001). Track I (baseline JIT) and
Track J (AOT) must match it EXACTLY, including which trap fires and when.
The behaviours Track E FIXES, to be written into the differential-testing
obligation now:

1. **NaN bits.** Every payload-affecting float op that produces NaN yields
   the POSITIVE CANONICAL pattern (`$7FC00000` / `$7FF8000000000000`).
   `neg`/`abs`/`copysign`/`reinterpret` preserve bits. Track I must
   canonicalize NaN results identically (a known, non-trivial cost on native
   FPU codegen — budget for it) or the differential test diverges on the
   float suites.
2. **Trap kind AND timing.** The trap that fires for a given state is fixed:
   div-by-zero vs overflow ordering; `call_indirect` bounds→null→type order;
   memory/table OOB via the chokepoint (identical across guard-page,
   guard-assisted, and bounds-checked strategies — already an ADR-0005
   requirement); the split null messages; cast failure; stack exhaustion at
   the SAME logical depth (a JIT with native frames must still trap
   exhaustion observationally when the interpreter would — its native limit
   must not let a program the interpreter rejects succeed, nor vice versa,
   within reason: this is the one place a JIT legitimately differs in the
   EXACT threshold, and the differential harness must use programs whose
   outcome does not depend on the precise cap).
3. **Float rounding mode** is round-to-nearest-ties-to-even throughout
   (wasm has no rounding-mode register); `nearest` is ties-to-even, `trunc`
   toward zero. Track I must set/assume the same FPU rounding mode.
4. **Order of side effects at a trap.** A trapping bulk op (memory/table/
   array init/copy/fill) writes NOTHING before it traps — the range check
   precedes any write (guaranteed by the chokepoint and the Gc helpers).
   Active-segment application order (elements before data) and the
   partially-mutated-store-on-trap behaviour are already fixed by Track D's
   `Instantiate`; the interpreter inherits it. Track I must preserve
   write-nothing-on-trap and the same op ordering.
5. **Reference identity.** `ref.func` returns the same handle every time;
   `ref.eq` is raw handle equality; i31/null compare by encoding. Track I
   must use the same handles (they come from the store, not the tier).
6. **Epoch interruption points.** The interrupt is observed at back-edge
   safepoints (and function entry does not poll). Track I emits the epoch
   check at exactly the `IR_JUMP_SAFEPOINT` sites (and the handler-resume
   sites Track H adds), so an interrupt is observed at the same points.

The invoke boundary (`TWasmTierInvokeProc`, `AParams`/`AResults` marshaling)
is the seam a differential harness drives: run the same module through the
interpreter and a future tier on the same store, compare results and the
trap outcome. Track E keeps that boundary clean (no interpreter state
leaks past `InterpTierInvoke`) so the harness can swap tiers without other
changes.
