{ Wasm.Interp — the interpreter tier (the tier of record), Track E: the whole
  interpreter (interp-spec §1/§2/§3/§4/§5/§7).

  This unit consumes TWasmIrModule and NOTHING about the raw binary
  (ADR-0007/0012). It runs inside WasmInvoke's trampoline (ADR-0009): a spec
  trap is TrapNow(kind) which LongJmps to the trampoline; the interpreter
  never wraps its own dispatch in try/except and holds no managed Pascal
  state across a TrapNow. The activation stack is EXPLICIT — no Pascal
  recursion per wasm call — so a self-tail-recursive loop of a million
  iterations runs in bounded stack (return_call REPLACES the top frame in
  place, O(1)). Every frame is a TWasmGcFrame on Heap's chain: its register
  file is zeroed at entry (GC-1), the frame is pushed before the IP-0
  safepoint, and a tail replacement is a PopFrame/PushFrame with zero
  intervening allocation so it never spans a safepoint (GC-1 obligation 3).

  WHAT SHIPS HERE: the full non-SIMD, non-throwing dispatch over the register
  IR — numeric (dispatched to Wasm.Interp.Numeric), parametric (select),
  variable (global.get/set; local get/set/tee are register iroMove in the IR),
  all lowered control (jump/branch/br_table/return, call/call_indirect/call_ref
  and the three tail-call forms, the epoch safepoint check per ADR-0006),
  memory and table ops through the one chokepoint, references, and the GC
  struct/array/i31 family — plus the tier seam (RegisterInterpreter wires the
  store's TierInvoke/TierContext), host calls across that boundary, and precise
  GC frame discharge at every safepoint. call_indirect dispatch matches by
  deftype SUBTYPING (see ResolveIndirect).

  DELIBERATELY STAGED, and named so nothing here is documented as more than it
  is: SIMD ($FD vector) EXECUTION is Track G; throwing (iroThrow/iroThrowRef)
  is Track H (interp-spec §4.6) and reaching it raises a clear not-implemented
  error; extern.convert_any / any.convert_extern are representation-identity
  only, the known M7 cross-hierarchy imprecision (interp-spec §3.9 O-4).

  THE FP MASK. Wasm float ops never trap; the FPU exception-enable bits are
  masked per THREAD, and Wasm.Interp.Numeric's initialization masks only the
  unit-initialisation thread. The interpreter therefore re-applies the mask
  on whatever thread runs guest code, at the start of each top-level
  InterpTierInvoke, by calling Wasm.Interp.Numeric.MaskFpuExceptions (the one
  cross-arch masking routine — no per-arch copy lives here).

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004), verified via
  spec_version at authoring time. Anchors cited at their sites:
  exec-instr-numeric, exec-call_indirect (trap order undefined element ->
  uninitialized element -> indirect call type mismatch), exec-unreachable,
  ADR-0006 (epoch), exec-call/exec-return. }
unit Wasm.Interp;

{$I Shared.inc}
{ The register file is addressed as Reg[k] and slices are formed as
  Values + Base, both pointer arithmetic on PWasmValue. }
{$POINTERMATH ON}

interface

uses
  SysUtils,

  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

var
  { The two reservations' sizes (interp-spec §1.1). Read once, when a store's
    interpreter context is first created. Mutable globals rather than
    constants so a test can shrink them before the first invoke to make
    assert_exhaustion trip a small cap deterministically. A push past EITHER
    cap traps 'call stack exhausted'. }
  WasmInterpValueSlots: NativeUInt = 1 shl 20;   { 1 Mi slots = 8 MiB }
  WasmInterpMaxDepth: NativeUInt = 8192;         { activation records }

{ Set AStore.TierInvoke/TierContext/TierContextFree so the store runs guest
  code through this interpreter. Allocates the per-store context (the two
  fixed reservations) if not already present. Idempotent. }
procedure RegisterInterpreter(const AStore: TWasmStore);

{ The guest-entry helper the tests and the .wast runner call: installs the
  trampoline (WasmInvoke) so a trap becomes a catchable EWasmTrap, runs the
  export, and re-establishes the frame chain and the context cursors after
  any unwind. Never call InterpTierInvoke directly from a host — a trap would
  LongJmp into a missing trampoline. }
procedure InterpInvoke(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
  const AParams: PWasmValue; const AResults: PWasmValue);

{ Zero the context cursors after a trap unwind (interp-spec §5.3/§7.3),
  called at the same landing as Heap.ResetFrames. Safe when no context
  exists. }
procedure ResetInterpContext(const AStore: TWasmStore);

implementation

uses
  Wasm.Core,
  Wasm.Interp.Numeric,
  Wasm.Ir,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Traps;

type
  { Wasm.Ir declares the records but no pointer types; the interpreter
    borrows stable pointers into the (never-modified) IR and value stack. }
  PWasmIrFunction = ^TWasmIrFunction;
  PWasmIrInstr = ^TWasmIrInstr;

const
  { A fixed ceiling on the parameter/result count a single call marshals
    through a stack-local scratch buffer (interp-spec §1.4 TRAP-1: the
    scratch must be plain stack data, not a managed dynamic array a TrapNow
    could skip). Comfortably above the spec's function-arity implementation
    limits; a module exceeding it raises a loud internal error rather than
    misbehaving. }
  WASM_INTERP_MAX_MARSHAL = 1024;

type
  PWasmActivation = ^TWasmActivation;

  TWasmRetKind = (rtCaller, rtEntry);

  { One live wasm frame (interp-spec §1.2). Its register file is the slice
    Values[Base .. Base+Fn^.RegisterCount) of the context's value stack, so
    GcFrame.Slots is stable for the life of the frame. }
  TWasmActivation = record
    Fn: PWasmIrFunction;             { the code being run; borrowed, stable }
    Instance: TWasmModuleInstance;   { borrowed; owns index spaces + ids }
    IP: UInt32;                      { index into Fn^.Code }
    Base: NativeUInt;                { register 0 = Values[Base] }
    GcFrame: TWasmGcFrame;           { the collector's view of this frame }
    RetKind: TWasmRetKind;
    { rtCaller: results are copied into the caller's dest registers. RetDest
      points at the caller's AuxU32 dest block (first item), RetBase is the
      caller's register base. rtEntry: results are copied to EntryResults. }
    RetDest: PUInt32;
    RetCount: UInt32;
    RetBase: NativeUInt;
    EntryResults: PWasmValue;        { rtEntry only: the invoke's AResults }
  end;

  PWasmInterpContext = ^TWasmInterpContext;

  { The per-store, per-thread interpreter context (interp-spec §1.1). Two
    FIXED, non-reallocating reservations plus a depth cursor. }
  TWasmInterpContext = record
    Store: TWasmStore;               { borrowed }
    Values: PWasmValue;              { GetMem(ValueCap * SizeOf(TWasmValue)) }
    ValueCap: NativeUInt;
    ValueTop: NativeUInt;            { next free slot }
    Acts: PWasmActivation;           { GetMem(DepthCap * SizeOf activation) }
    DepthCap: NativeUInt;
    Depth: NativeUInt;               { number of live activations }
  end;

{ --- register-file addressing -------------------------------------------- }

{ @Values[AOffset]. Inc on a typed pointer advances by whole elements, so
  this is the one place slice pointers are formed. }
function Frame(const ABase: PWasmValue; const AOffset: NativeUInt): PWasmValue;
  inline;
begin
  Result := ABase;
  Inc(Result, AOffset);
end;

{ --- GC frame publication (contract GC-1) -------------------------------- }

{ Point the activation's TWasmGcFrame straight at the IR function's
  precomputed ref bitset and push it before the first safepoint. A
  0-register function has no slots to trace, so RefRegBits is left nil. }
procedure PushGcFrame(const ACtx: PWasmInterpContext; const AAct: PWasmActivation;
  const AFn: PWasmIrFunction; const ABase: NativeUInt);
begin
  if AFn^.RegisterCount > 0 then
    AAct^.GcFrame.RefRegBits := PWasmGcRefBits(@AFn^.RefRegBits[0])
  else
    AAct^.GcFrame.RefRegBits := nil;
  AAct^.GcFrame.Slots := Frame(ACtx^.Values, ABase);
  AAct^.GcFrame.RegisterCount := AFn^.RegisterCount;
  AAct^.GcFrame.Instance := Pointer(AAct^.Instance);
  ACtx^.Store.Heap.PushFrame(@AAct^.GcFrame);
end;

{ --- return (interp-spec §1.4) ------------------------------------------- }

procedure DoReturn(const ACtx: PWasmInterpContext; const ATop: PWasmActivation);
var
  RetSrc, DestRegs: PWasmValue;
  I: UInt32;
begin
  { The return block is [ReturnRegBase .. +ResultCount); the merge moves that
    fill it were materialised by validation before the iroReturn. }
  RetSrc := Frame(ACtx^.Values, ATop^.Base + ATop^.Fn^.ReturnRegBase);
  if ATop^.RetKind = rtEntry then
  begin
    I := 0;
    while I < ATop^.RetCount do
    begin
      ATop^.EntryResults[I] := RetSrc[I];
      Inc(I);
    end;
  end
  else
  begin
    DestRegs := Frame(ACtx^.Values, ATop^.RetBase);
    I := 0;
    while I < ATop^.RetCount do
    begin
      DestRegs[ATop^.RetDest[I]] := RetSrc[I];
      Inc(I);
    end;
  end;

  ACtx^.Store.Heap.PopFrame;
  ACtx^.ValueTop := ATop^.Base;
  Dec(ACtx^.Depth);
end;

{ --- wasm call: push a new activation (interp-spec §1.4) ------------------ }

procedure PushWasmFrame(const ACtx: PWasmInterpContext;
  const ACaller: PWasmActivation; const AArgAux, ADstAux: UInt32;
  const AAddr: TWasmFuncAddr);
var
  CalleeInst: TWasmModuleInstance;
  CalleeFn: PWasmIrFunction;
  Callee: PWasmActivation;
  NewBase: NativeUInt;
  Slots, CallerRegs: PWasmValue;
  ArgN, I: UInt32;
begin
  CalleeInst := ACtx^.Store.Funcs[AAddr].Instance;
  CalleeFn := @CalleeInst.Ir.Functions[ACtx^.Store.Funcs[AAddr].FuncIrIndex];
  NewBase := ACtx^.ValueTop;

  { Exhaustion guard BEFORE any mutation (interp-spec §5.2), so a trapping
    push leaves the activation stack and the GC chain consistent. }
  if (ACtx^.Depth >= ACtx^.DepthCap) or
    (NewBase + CalleeFn^.RegisterCount > ACtx^.ValueCap) then
    TrapNow(wtkStackExhausted);

  Callee := @ACtx^.Acts[ACtx^.Depth];
  Callee^.Fn := CalleeFn;
  Callee^.Instance := CalleeInst;
  Callee^.Base := NewBase;
  Callee^.IP := 0;
  ACtx^.ValueTop := NewBase + CalleeFn^.RegisterCount;

  { GC-1: zero the whole register file before use — an unwritten ref slot
    reads as null, and numeric locals default to 0. }
  Slots := Frame(ACtx^.Values, NewBase);
  ValueZeroSlots(Slots, CalleeFn^.RegisterCount);

  { Marshal args into param registers [0 .. ArgN-1]. NewBase >= the caller's
    frame end, so source and destination never overlap. }
  CallerRegs := Frame(ACtx^.Values, ACaller^.Base);
  ArgN := IrAuxBlockCount(ACaller^.Fn^.AuxU32, AArgAux);
  I := 0;
  while I < ArgN do
  begin
    Slots[I] := CallerRegs[IrAuxBlockItem(ACaller^.Fn^.AuxU32, AArgAux, I)];
    Inc(I);
  end;

  { Return wiring: results flow into the caller's dest block. }
  Callee^.RetKind := rtCaller;
  Callee^.RetCount := IrAuxBlockCount(ACaller^.Fn^.AuxU32, ADstAux);
  if Callee^.RetCount > 0 then
    Callee^.RetDest := PUInt32(@ACaller^.Fn^.AuxU32[ADstAux + 1])
  else
    Callee^.RetDest := nil;
  Callee^.RetBase := ACaller^.Base;
  Callee^.EntryResults := nil;

  { GC-1: push before the IP-0 safepoint (the callee's first op may allocate). }
  PushGcFrame(ACtx, Callee, CalleeFn, NewBase);
  Inc(ACtx^.Depth);
end;

{ --- return_call: replace the top frame in place, O(1) (interp-spec §1.4) - }

procedure ReplaceWasmFrame(const ACtx: PWasmInterpContext;
  const ATop: PWasmActivation; const AArgAux: UInt32;
  const AAddr: TWasmFuncAddr);
var
  CalleeInst: TWasmModuleInstance;
  CalleeFn: PWasmIrFunction;
  TopRegs, Slots: PWasmValue;
  ArgN, I: UInt32;
  Tmp: array[0 .. WASM_INTERP_MAX_MARSHAL - 1] of TWasmValue;
begin
  CalleeInst := ACtx^.Store.Funcs[AAddr].Instance;
  CalleeFn := @CalleeInst.Ir.Functions[ACtx^.Store.Funcs[AAddr].FuncIrIndex];

  { 1. Collect argument VALUES first: they live in the CURRENT frame's
       registers, which are about to be overwritten in place. Tmp is a plain
       stack local, not managed state a TrapNow could skip. }
  ArgN := IrAuxBlockCount(ATop^.Fn^.AuxU32, AArgAux);
  if ArgN > WASM_INTERP_MAX_MARSHAL then
    raise EWasmError.Create('internal: tail-call arity exceeds the marshal cap');
  TopRegs := Frame(ACtx^.Values, ATop^.Base);
  I := 0;
  while I < ArgN do
  begin
    Tmp[I] := TopRegs[IrAuxBlockItem(ATop^.Fn^.AuxU32, AArgAux, I)];
    Inc(I);
  end;

  { 2. Exhaustion against the REPLACED frame's base — a self-tail-loop never
       advances ValueTop, so this is the only trap point and it runs while
       the old frame is still whole and on the chain. }
  if ATop^.Base + CalleeFn^.RegisterCount > ACtx^.ValueCap then
    TrapNow(wtkStackExhausted);

  { 3-5. Replace with NO intervening allocation (GC-1 obligation 3): drop the
       old GcFrame, rebuild the register file at the SAME Base, re-push the
       new GcFrame. RetKind/RetDest/RetBase/RetCount/EntryResults are
       UNCHANGED — the callee returns to wherever the replaced frame would. }
  ACtx^.Store.Heap.PopFrame;
  ATop^.Fn := CalleeFn;
  ATop^.Instance := CalleeInst;
  ATop^.IP := 0;
  ACtx^.ValueTop := ATop^.Base + CalleeFn^.RegisterCount;

  Slots := Frame(ACtx^.Values, ATop^.Base);
  ValueZeroSlots(Slots, CalleeFn^.RegisterCount);
  I := 0;
  while I < ArgN do
  begin
    Slots[I] := Tmp[I];
    Inc(I);
  end;

  PushGcFrame(ACtx, ATop, CalleeFn, ATop^.Base);
  { Depth UNCHANGED — the O(1) property. }
end;

{ --- host calls (interp-spec §4.2) --------------------------------------- }

procedure HostCall(const ACtx: PWasmInterpContext; const ACaller: PWasmActivation;
  const AArgAux, ADstAux: UInt32; const AAddr: TWasmFuncAddr);
var
  CallerRegs: PWasmValue;
  ArgN, ResN, I: UInt32;
  ParamBuf, ResBuf: array[0 .. WASM_INTERP_MAX_MARSHAL - 1] of TWasmValue;
begin
  ArgN := IrAuxBlockCount(ACaller^.Fn^.AuxU32, AArgAux);
  ResN := IrAuxBlockCount(ACaller^.Fn^.AuxU32, ADstAux);
  if (ArgN > WASM_INTERP_MAX_MARSHAL) or (ResN > WASM_INTERP_MAX_MARSHAL) then
    raise EWasmError.Create('internal: host-call arity exceeds the marshal cap');

  CallerRegs := Frame(ACtx^.Values, ACaller^.Base);
  I := 0;
  while I < ArgN do
  begin
    ParamBuf[I] := CallerRegs[IrAuxBlockItem(ACaller^.Fn^.AuxU32, AArgAux, I)];
    Inc(I);
  end;

  ACtx^.Store.Funcs[AAddr].Callback(ACtx^.Store, ACtx^.Store.Funcs[AAddr].HostData,
    @ParamBuf[0], @ResBuf[0]);

  { The value stack is fixed, so CallerRegs is still valid even if the
    callback re-entered guest code. }
  I := 0;
  while I < ResN do
  begin
    CallerRegs[IrAuxBlockItem(ACaller^.Fn^.AuxU32, ADstAux, I)] := ResBuf[I];
    Inc(I);
  end;
  { The caller's IP was advanced past the call by the dispatch loop before it
    entered here, so a host call simply falls through. }
end;

{ return_call to a host function (interp-spec §4.4): do the host call, take
  its results as THIS frame's results, and return them to this frame's
  caller. Keeps O(1) stack — no wasm frame is added. }
procedure ReturnHostCall(const ACtx: PWasmInterpContext; const ATop: PWasmActivation;
  const AArgAux: UInt32; const AAddr: TWasmFuncAddr);
var
  TopRegs, RetSlots: PWasmValue;
  ArgN, ResN, I: UInt32;
  ParamBuf, ResBuf: array[0 .. WASM_INTERP_MAX_MARSHAL - 1] of TWasmValue;
begin
  ArgN := IrAuxBlockCount(ATop^.Fn^.AuxU32, AArgAux);
  ResN := ATop^.Fn^.ResultCount;   { equals the host func's result arity }
  if (ArgN > WASM_INTERP_MAX_MARSHAL) or (ResN > WASM_INTERP_MAX_MARSHAL) then
    raise EWasmError.Create('internal: host-call arity exceeds the marshal cap');

  TopRegs := Frame(ACtx^.Values, ATop^.Base);
  I := 0;
  while I < ArgN do
  begin
    ParamBuf[I] := TopRegs[IrAuxBlockItem(ATop^.Fn^.AuxU32, AArgAux, I)];
    Inc(I);
  end;

  ACtx^.Store.Funcs[AAddr].Callback(ACtx^.Store, ACtx^.Store.Funcs[AAddr].HostData,
    @ParamBuf[0], @ResBuf[0]);

  RetSlots := Frame(ACtx^.Values, ATop^.Base + ATop^.Fn^.ReturnRegBase);
  I := 0;
  while I < ResN do
  begin
    RetSlots[I] := ResBuf[I];
    Inc(I);
  end;
  DoReturn(ACtx, ATop);
end;

{ --- call_indirect resolution (interp-spec §3.6; exec-call_indirect) ------
  Trap ORDER is bounds -> null -> type, confirmed via wasm-mcp
  instruction_get call_indirect: undefined element, uninitialized element,
  indirect call type mismatch. The type check is match-deftype SUBTYPING, not
  engine-id equality: in wasm 3.0 (func-references/GC merged) the runtime
  function's type must be a SUBTYPE of the expected call-site type — the trap
  fires only when "the runtime function type does not match the expected type"
  (instruction_get). Direction is actual <: expected, so this uses the very
  same engine deftype check ref.test/ref.cast use (TWasmEngine.Matches over the
  two engine type ids) and mirrors MatchFuncImport. A proper subtype must
  DISPATCH; only a genuinely unrelated type traps. }
function ResolveIndirect(const ACtx: PWasmInterpContext;
  const ACaller: PWasmActivation; const ARegs: PWasmValue;
  const AIns: PWasmIrInstr): TWasmFuncAddr;
var
  TypeIdx, TableIdx: UInt32;
  TableAddr: TWasmTableAddr;
  Idx: UInt64;
  R: TWasmRef;
  FuncAddr: TWasmFuncAddr;
  Expected: TWasmEngineTypeId;
begin
  IrUnpack(AIns^.Imm, TypeIdx, TableIdx);
  TableAddr := ACaller^.Instance.TableAddrs[TableIdx];

  { The table-index operand rides in Dest (ifkSrcReg); its width is the
    table's address type. }
  if ACtx^.Store.Tables[TableAddr].TableType.Limits.AddrType = watI64 then
    Idx := ARegs[AIns^.Dest].U64
  else
    Idx := ARegs[AIns^.Dest].U32;

  if Idx >= UInt64(Length(ACtx^.Store.Tables[TableAddr].Elems)) then
    TrapNow(wtkUndefinedElement);

  R := ACtx^.Store.Tables[TableAddr].Elems[Idx];
  if RefIsNull(R) then
    TrapNow(wtkUninitializedElement);

  FuncAddr := ACtx^.Store.FuncRefAddr(R);
  Expected := ACaller^.Instance.EngineTypeIds[TypeIdx];
  if not ACtx^.Store.Engine.Matches(ACtx^.Store.Funcs[FuncAddr].TypeId,
    Expected) then
    TrapNow(wtkIndirectCallTypeMismatch);

  Result := FuncAddr;
end;

{ --- call dispatch (wasm vs host) ---------------------------------------- }

procedure EnterCall(const ACtx: PWasmInterpContext; const ACaller: PWasmActivation;
  const AArgAux, ADstAux: UInt32; const AAddr: TWasmFuncAddr);
begin
  if ACtx^.Store.Funcs[AAddr].Kind = wfkHost then
    HostCall(ACtx, ACaller, AArgAux, ADstAux, AAddr)
  else
    PushWasmFrame(ACtx, ACaller, AArgAux, ADstAux, AAddr);
end;

procedure EnterTailCall(const ACtx: PWasmInterpContext; const ATop: PWasmActivation;
  const AArgAux: UInt32; const AAddr: TWasmFuncAddr);
begin
  if ACtx^.Store.Funcs[AAddr].Kind = wfkHost then
    ReturnHostCall(ACtx, ATop, AArgAux, AAddr)
  else
    ReplaceWasmFrame(ACtx, ATop, AArgAux, AAddr);
end;

{ --- memory access: everything through the chokepoint (interp-spec §3.7) ---
  MemAddressAt/MemRangeAt route to Wasm.Runtime.Memory's MemAddress/MemRange
  and trap 'out of bounds memory access'; the interpreter never touches Base
  or does raw pointer arithmetic on the memory (AGENTS.md's top failure mode).
  MemLoad/MemStore are leaves so a chokepoint TrapNow's LongJmp abandons no
  managed Pascal state (TRAP-1): every local here is a plain pointer/integer. }

function MemLoad(const AStore: TWasmStore; const AMemAddr: TWasmMemAddr;
  const AIndex, AOffset: UInt64; const ASize: NativeUInt): UInt64;
var
  P: PByte;
begin
  P := AStore.MemAddressAt(AMemAddr, AIndex, AOffset, ASize);
  { Little-endian, unaligned-safe: Move fills the low ASize bytes of a
    zeroed u64, so the caller sign/zero-extends per the op. }
  Result := 0;
  Move(P^, Result, ASize);
end;

procedure MemStore(const AStore: TWasmStore; const AMemAddr: TWasmMemAddr;
  const AIndex, AOffset: UInt64; const ASize: NativeUInt; const AValue: UInt64);
var
  P: PByte;
  V: UInt64;
begin
  P := AStore.MemAddressAt(AMemAddr, AIndex, AOffset, ASize);
  V := AValue;
  Move(V, P^, ASize);
end;

procedure ExecLoad(const ACtx: PWasmInterpContext; const AAct: PWasmActivation;
  const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  MemAddr: TWasmMemAddr;
  Index, Offset, Raw: UInt64;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  { B = mem index; A = index register (read as u64 — a narrow write zeroed the
    slot, so an i32 index reads back exactly); Imm = raw u64 static offset. }
  MemAddr := AAct^.Instance.MemAddrs[AIns^.B];
  Index := Reg[AIns^.A].U64;
  Offset := UInt64(AIns^.Imm);
  case AIns^.Op of
    iroI32Load:
      Reg[AIns^.Dest].Bits := UInt64(UInt32(MemLoad(Store, MemAddr, Index, Offset, 4)));
    iroI64Load:
      Reg[AIns^.Dest].Bits := MemLoad(Store, MemAddr, Index, Offset, 8);
    iroF32Load:
      Reg[AIns^.Dest].Bits := UInt64(UInt32(MemLoad(Store, MemAddr, Index, Offset, 4)));
    iroF64Load:
      Reg[AIns^.Dest].Bits := MemLoad(Store, MemAddr, Index, Offset, 8);
    iroI32Load8S:
      begin
        Raw := MemLoad(Store, MemAddr, Index, Offset, 1);
        Reg[AIns^.Dest].Bits := UInt64(UInt32(Int32(ShortInt(Byte(Raw)))));
      end;
    iroI32Load8U:
      Reg[AIns^.Dest].Bits := MemLoad(Store, MemAddr, Index, Offset, 1);
    iroI32Load16S:
      begin
        Raw := MemLoad(Store, MemAddr, Index, Offset, 2);
        Reg[AIns^.Dest].Bits := UInt64(UInt32(Int32(SmallInt(Word(Raw)))));
      end;
    iroI32Load16U:
      Reg[AIns^.Dest].Bits := MemLoad(Store, MemAddr, Index, Offset, 2);
    iroI64Load8S:
      begin
        Raw := MemLoad(Store, MemAddr, Index, Offset, 1);
        Reg[AIns^.Dest].Bits := UInt64(Int64(ShortInt(Byte(Raw))));
      end;
    iroI64Load8U:
      Reg[AIns^.Dest].Bits := MemLoad(Store, MemAddr, Index, Offset, 1);
    iroI64Load16S:
      begin
        Raw := MemLoad(Store, MemAddr, Index, Offset, 2);
        Reg[AIns^.Dest].Bits := UInt64(Int64(SmallInt(Word(Raw))));
      end;
    iroI64Load16U:
      Reg[AIns^.Dest].Bits := MemLoad(Store, MemAddr, Index, Offset, 2);
    iroI64Load32S:
      begin
        Raw := MemLoad(Store, MemAddr, Index, Offset, 4);
        Reg[AIns^.Dest].Bits := UInt64(Int64(Int32(UInt32(Raw))));
      end;
    iroI64Load32U:
      Reg[AIns^.Dest].Bits := MemLoad(Store, MemAddr, Index, Offset, 4);
  end;
end;

procedure ExecStore(const ACtx: PWasmInterpContext; const AAct: PWasmActivation;
  const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  MemAddr: TWasmMemAddr;
  Index, Offset, Value: UInt64;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  { Store ops carry the VALUE in Dest (ifkSrcReg) and the INDEX in A; B = mem
    index. Store8/16/32 write only the low bytes. }
  MemAddr := AAct^.Instance.MemAddrs[AIns^.B];
  Index := Reg[AIns^.A].U64;
  Offset := UInt64(AIns^.Imm);
  Value := Reg[AIns^.Dest].U64;
  case AIns^.Op of
    iroI32Store, iroF32Store: MemStore(Store, MemAddr, Index, Offset, 4, Value);
    iroI64Store, iroF64Store: MemStore(Store, MemAddr, Index, Offset, 8, Value);
    iroI32Store8, iroI64Store8: MemStore(Store, MemAddr, Index, Offset, 1, Value);
    iroI32Store16, iroI64Store16: MemStore(Store, MemAddr, Index, Offset, 2, Value);
    iroI64Store32: MemStore(Store, MemAddr, Index, Offset, 4, Value);
  end;
end;

{ memory.init: bounds-check the memory destination (via the chokepoint) AND
  the data-segment source, both trapping 'out of bounds memory access', before
  any write. Imm = IrPack(memIndex, dataIndex). }
procedure ExecMemoryInit(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  MemIdx, DataIdx: UInt32;
  MemAddr: TWasmMemAddr;
  DataAddr: TWasmDataAddr;
  DstIdx, SrcOff, Count, DataSize: UInt64;
  DstPtr, SrcPtr: PByte;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  IrUnpack(AIns^.Imm, MemIdx, DataIdx);
  MemAddr := AAct^.Instance.MemAddrs[MemIdx];
  DataAddr := AAct^.Instance.DataAddrs[DataIdx];
  DstIdx := Reg[AIns^.Dest].U64;
  SrcOff := Reg[AIns^.A].U64;
  Count := Reg[AIns^.B].U64;
  { Dest first, then source: both checked before the copy so a trap writes
    nothing. A dropped segment has Size 0, so any non-empty init traps. }
  DstPtr := Store.MemRangeAt(MemAddr, DstIdx, Count);
  DataSize := UInt64(Store.Datas[DataAddr].Size);
  if (SrcOff > DataSize) or (Count > DataSize - SrcOff) then
    TrapNow(wtkMemoryOutOfBounds);
  if Count > 0 then
  begin
    SrcPtr := Store.Datas[DataAddr].Data;
    Inc(SrcPtr, SrcOff);
    Move(SrcPtr^, DstPtr^, NativeUInt(Count));
  end;
end;

{ memory.copy: range-check both memories through the chokepoint, then Move
  (memmove — handles overlap). Imm = IrPack(dstMem, srcMem). }
procedure ExecMemoryCopy(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  DstMem, SrcMem: UInt32;
  DstIdx, SrcIdx, Count: UInt64;
  DstPtr, SrcPtr: PByte;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  IrUnpack(AIns^.Imm, DstMem, SrcMem);
  DstIdx := Reg[AIns^.Dest].U64;
  SrcIdx := Reg[AIns^.A].U64;
  Count := Reg[AIns^.B].U64;
  DstPtr := Store.MemRangeAt(AAct^.Instance.MemAddrs[DstMem], DstIdx, Count);
  SrcPtr := Store.MemRangeAt(AAct^.Instance.MemAddrs[SrcMem], SrcIdx, Count);
  if Count > 0 then
    Move(SrcPtr^, DstPtr^, NativeUInt(Count));
end;

{ memory.fill: range-check through the chokepoint, then FillChar. Imm = mem
  index; A = byte value, B = count. }
procedure ExecMemoryFill(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  DstIdx, Count: UInt64;
  DstPtr: PByte;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  DstIdx := Reg[AIns^.Dest].U64;
  Count := Reg[AIns^.B].U64;
  DstPtr := Store.MemRangeAt(AAct^.Instance.MemAddrs[UInt32(AIns^.Imm)],
    DstIdx, Count);
  if Count > 0 then
    FillChar(DstPtr^, NativeUInt(Count), Byte(Reg[AIns^.A].U32 and $FF));
end;

{ --- GC allocation and bulk ops (interp-spec §3.10) -----------------------
  All go through Store.Heap, which owns layout, packing, the null/OOB traps
  (the split kinds are wired at the Gc raise sites), and the write barrier.
  Engine type ids come from Instance.EngineTypeIds[moduleTypeIndex].

  PUBLISH-FIRST (GC-1): the fresh aggregate ref is written into its Dest
  register — a ref slot the frame's RefRegBits covers — BEFORE any subsequent
  allocation, so a collection triggered while the object is still being filled
  finds it rooted. AllocStruct/AllocArray are the only safepoints in these
  leaves; the field/element writes that follow never allocate. }

procedure ExecStructNew(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Fn: PWasmIrFunction;
  Obj: TWasmRef;
  N, I: UInt32;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Fn := AAct^.Fn;
  Obj := Store.Heap.AllocStruct(AAct^.Instance.EngineTypeIds[UInt32(AIns^.Imm)]);
  Reg[AIns^.Dest].Bits := UInt64(Obj);            { publish before filling }
  N := IrAuxBlockCount(Fn^.AuxU32, AIns^.A);
  I := 0;
  while I < N do
  begin
    Store.Heap.StructSet(Obj, I, Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)]);
    Inc(I);
  end;
end;

procedure ExecStructNewDefault(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Obj: TWasmRef;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Obj := Store.Heap.AllocStruct(AAct^.Instance.EngineTypeIds[UInt32(AIns^.Imm)]);
  Reg[AIns^.Dest].Bits := UInt64(Obj);
  Store.Heap.StructSetDefaults(Obj);
end;

procedure ExecArrayNew(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Obj: TWasmRef;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  { A = element value, B = length. }
  Obj := Store.Heap.AllocArray(AAct^.Instance.EngineTypeIds[UInt32(AIns^.Imm)],
    Reg[AIns^.B].U32);
  Reg[AIns^.Dest].Bits := UInt64(Obj);
  Store.Heap.ArrayFill(Obj, Reg[AIns^.A]);
end;

procedure ExecArrayNewDefault(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Obj: TWasmRef;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Obj := Store.Heap.AllocArray(AAct^.Instance.EngineTypeIds[UInt32(AIns^.Imm)],
    Reg[AIns^.A].U32);
  Reg[AIns^.Dest].Bits := UInt64(Obj);
  Store.Heap.ArraySetDefaults(Obj);
end;

procedure ExecArrayNewFixed(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Fn: PWasmIrFunction;
  Obj: TWasmRef;
  N, I: UInt32;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Fn := AAct^.Fn;
  N := IrAuxBlockCount(Fn^.AuxU32, AIns^.A);
  Obj := Store.Heap.AllocArray(AAct^.Instance.EngineTypeIds[UInt32(AIns^.Imm)], N);
  Reg[AIns^.Dest].Bits := UInt64(Obj);
  I := 0;
  while I < N do
  begin
    Store.Heap.ArraySet(Obj, I, Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)]);
    Inc(I);
  end;
end;

procedure ExecArrayNewData(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  TypeIdx, DataIdx: UInt32;
  DataAddr: TWasmDataAddr;
  Obj: TWasmRef;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  { Imm = IrPack(typeIndex, dataIndex); A = byte offset, B = length. }
  IrUnpack(AIns^.Imm, TypeIdx, DataIdx);
  Obj := Store.Heap.AllocArray(AAct^.Instance.EngineTypeIds[TypeIdx],
    Reg[AIns^.B].U32);
  Reg[AIns^.Dest].Bits := UInt64(Obj);
  DataAddr := AAct^.Instance.DataAddrs[DataIdx];
  Store.Heap.ArrayInitFromData(Obj, 0, Store.Datas[DataAddr].Data,
    Store.Datas[DataAddr].Size, Reg[AIns^.A].U64, Reg[AIns^.B].U32);
end;

procedure ExecArrayNewElem(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  TypeIdx, ElemIdx: UInt32;
  ElemAddr: TWasmElemAddr;
  Obj: TWasmRef;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  { Imm = IrPack(typeIndex, elemIndex); A = element offset, B = length. }
  IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
  Obj := Store.Heap.AllocArray(AAct^.Instance.EngineTypeIds[TypeIdx],
    Reg[AIns^.B].U32);
  Reg[AIns^.Dest].Bits := UInt64(Obj);
  ElemAddr := AAct^.Instance.ElemAddrs[ElemIdx];
  Store.Heap.ArrayInitFromElem(Obj, 0, Store.Elems[ElemAddr].Refs,
    Reg[AIns^.A].U32, Reg[AIns^.B].U32);
end;

{ array.fill: aux [ref, index, value, count] (Wasm.Validator.Body order). }
procedure ExecArrayFill(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Fn: PWasmIrFunction;
  Aux: UInt32;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Fn := AAct^.Fn;
  Aux := AIns^.A;
  Store.Heap.ArrayFill(
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)]);
end;

{ array.copy: aux [dstRef, dstIdx, srcRef, srcIdx, count]. }
procedure ExecArrayCopy(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Fn: PWasmIrFunction;
  Aux: UInt32;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Fn := AAct^.Fn;
  Aux := AIns^.A;
  Store.Heap.ArrayCopy(
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].Ref,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 4)].U32);
end;

{ array.init_data: aux [destRef, destIdx, srcByteOffset, count];
  Imm = IrPack(typeIndex, dataIndex). }
procedure ExecArrayInitData(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Fn: PWasmIrFunction;
  Aux, TypeIdx, DataIdx: UInt32;
  DataAddr: TWasmDataAddr;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Fn := AAct^.Fn;
  Aux := AIns^.A;
  IrUnpack(AIns^.Imm, TypeIdx, DataIdx);
  DataAddr := AAct^.Instance.DataAddrs[DataIdx];
  Store.Heap.ArrayInitFromData(
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
    Store.Datas[DataAddr].Data, Store.Datas[DataAddr].Size,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].U64,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32);
end;

{ array.init_elem: aux [destRef, destIdx, srcElemOffset, count];
  Imm = IrPack(typeIndex, elemIndex). }
procedure ExecArrayInitElem(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  Fn: PWasmIrFunction;
  Aux, TypeIdx, ElemIdx: UInt32;
  ElemAddr: TWasmElemAddr;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Fn := AAct^.Fn;
  Aux := AIns^.A;
  IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
  ElemAddr := AAct^.Instance.ElemAddrs[ElemIdx];
  Store.Heap.ArrayInitFromElem(
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
    Store.Elems[ElemAddr].Refs,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].U32,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32);
end;

{ ref.test / ref.cast / br_on_cast* runtime match. The reftype rides in
  Fn^.AuxRefTypes[Imm] in MODULE space; convert to engine space and run the
  store's O(1) subtype check (handles null-nullability, i31, abstract, and
  concrete cases). A leaf so a TWasmRefType record local never lives in Run. }
function MatchesAuxRefType(const AFn: PWasmIrFunction;
  const AInstance: TWasmModuleInstance; const AEngine: TWasmEngine;
  const ARef: TWasmRef; const AAuxIdx: UInt32): Boolean;
var
  EngRt: TWasmRefType;
begin
  EngRt := EngineRefType(AFn^.AuxRefTypes[AAuxIdx], AInstance.EngineTypeIds);
  Result := IsRefOfRefType(AEngine, ARef, EngRt);
end;

{ --- Track H staged-out helper ------------------------------------------- }

procedure StageException;
begin
  { interp-spec §4.6: Track E installs no handler tables and executes no
    throw; reaching one means the module uses exceptions (Track H). }
  raise EWasmError.Create('exception handling is not implemented');
end;

{ Kept OUT of Run: building the message string would give Run a managed
  local, hence an implicit finalisation frame that a trap's raw LongJmp
  abandons — corrupting the exception-frame stack (TRAP-1). Run must have no
  managed locals, so every string lives in a leaf like this one. }
procedure UnhandledOp(const AOp: TWasmIrOp);
begin
  raise EWasmError.Create('internal: unhandled IR op ' + IrOpMnemonic(AOp));
end;

{ --- the dispatch loop (interp-spec §1.3) -------------------------------- }

{ One flat loop, no Pascal recursion per wasm call. Runs until the top-level
  invoke's entry frame returns — i.e. Depth drops back to AStopDepth. }
procedure Run(const ACtx: PWasmInterpContext; const AStopDepth: NativeUInt);
var
  Act: PWasmActivation;
  Fn: PWasmIrFunction;
  Reg: PWasmValue;
  IP: UInt32;
  Code, Ins: PWasmIrInstr;
  EpochCache: UInt64;
  Store: TWasmStore;
  Addr: TWasmFuncAddr;
  R: TWasmRef;
  N, Sel: UInt32;
  { Scratch for IrUnpack of packed immediates (struct field / table + segment
    index pairs). Plain integers — no managed state across a TrapNow. }
  U1, U2: UInt32;

  procedure LoadTop; inline;
  begin
    Act := @ACtx^.Acts[ACtx^.Depth - 1];
    Fn := Act^.Fn;
    Reg := Frame(ACtx^.Values, Act^.Base);
    IP := Act^.IP;
    Code := @Fn^.Code[0];
  end;

begin
  Store := ACtx^.Store;
  EpochCache := Store.Epoch;
  LoadTop;

  while True do
  begin
    Ins := Code;
    Inc(Ins, IP);
    case Ins^.Op of
      { --- IR-only / merges ---------------------------------------------- }
      iroMove:
        begin Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits; Inc(IP); end;

      { --- control (lowered; targets are resolved instruction indices) --- }
      iroJump:
        begin
          { ADR-0006: a back-edge jump carries IR_JUMP_SAFEPOINT; a host
            interrupt is a changed Store.Epoch observed here. }
          if (Ins^.Imm and IR_JUMP_SAFEPOINT) <> 0 then
            if Store.Epoch <> EpochCache then
              TrapNow(wtkEpochInterrupt);
          IP := UInt32(Ins^.A);
        end;
      iroBranchIf:
        if Reg[Ins^.A].I32 <> 0 then IP := Ins^.B else Inc(IP);
      iroBranchIfNot:
        if Reg[Ins^.A].I32 = 0 then IP := Ins^.B else Inc(IP);
      iroBrTable:
        begin
          { Aux block [N, s0 .. s(N-1)]; the last entry is the default. Each
            entry is a stub instruction index that runs the target's merge
            moves then jumps. }
          N := IrAuxBlockCount(Fn^.AuxU32, Ins^.B);
          Sel := Reg[Ins^.A].U32;
          if Sel >= N - 1 then
            IP := IrAuxBlockItem(Fn^.AuxU32, Ins^.B, N - 1)
          else
            IP := IrAuxBlockItem(Fn^.AuxU32, Ins^.B, Sel);
        end;
      iroReturn:
        begin
          DoReturn(ACtx, Act);
          if ACtx^.Depth = AStopDepth then
            Exit;
          LoadTop;
        end;
      iroUnreachable:
        TrapNow(wtkUnreachable);   { exec-unreachable: unconditional trap }

      iroCall:
        begin
          Act^.IP := IP + 1;   { the caller resumes after the call }
          Addr := Act^.Instance.FuncAddrs[UInt32(Ins^.Imm)];
          EnterCall(ACtx, Act, Ins^.A, Ins^.B, Addr);
          LoadTop;
        end;
      iroCallIndirect:
        begin
          Act^.IP := IP + 1;
          Addr := ResolveIndirect(ACtx, Act, Reg, Ins);
          EnterCall(ACtx, Act, Ins^.A, Ins^.B, Addr);
          LoadTop;
        end;
      iroCallRef:
        begin
          Act^.IP := IP + 1;
          R := Reg[Ins^.Dest].Ref;
          if RefIsNull(R) then
            TrapNow(wtkNullFuncReference);
          Addr := Store.FuncRefAddr(R);
          EnterCall(ACtx, Act, Ins^.A, Ins^.B, Addr);
          LoadTop;
        end;
      iroReturnCall:
        begin
          Addr := Act^.Instance.FuncAddrs[UInt32(Ins^.Imm)];
          EnterTailCall(ACtx, Act, Ins^.A, Addr);
          if ACtx^.Depth = AStopDepth then   { host tail from the entry frame }
            Exit;
          LoadTop;
        end;
      iroReturnCallIndirect:
        begin
          Addr := ResolveIndirect(ACtx, Act, Reg, Ins);
          EnterTailCall(ACtx, Act, Ins^.A, Addr);
          if ACtx^.Depth = AStopDepth then
            Exit;
          LoadTop;
        end;
      iroReturnCallRef:
        begin
          R := Reg[Ins^.Dest].Ref;
          if RefIsNull(R) then
            TrapNow(wtkNullFuncReference);
          Addr := Store.FuncRefAddr(R);
          EnterTailCall(ACtx, Act, Ins^.A, Addr);
          if ACtx^.Depth = AStopDepth then
            Exit;
          LoadTop;
        end;

      { --- parametric ---------------------------------------------------- }
      iroSelect:
        begin
          { Condition register rides in Imm (ifkSrcReg); whole-slot copy so
            it works for any type. }
          if Reg[UInt32(Ins^.Imm)].I32 <> 0 then
            Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits
          else
            Reg[Ins^.Dest].Bits := Reg[Ins^.B].Bits;
          Inc(IP);
        end;

      { --- variable (locals are register moves; globals are store cells) - }
      iroGlobalGet:
        begin
          Reg[Ins^.Dest].Bits :=
            Store.Globals[Act^.Instance.GlobalAddrs[UInt32(Ins^.Imm)]].Value.Bits;
          Inc(IP);
        end;
      iroGlobalSet:
        begin
          Addr := Act^.Instance.GlobalAddrs[UInt32(Ins^.Imm)];
          if Store.Globals[Addr].GlobalType.ValueType.Kind = wvkRef then
            { WriteBarrier(oldRef, newRef). The v1 barrier is empty, so the
              old-value argument is unused and passed as null. A future
              non-empty/generational barrier MUST first read the global cell's
              CURRENT value (Store.Globals[Addr].Value.Ref) and pass THAT as the
              old ref before the store below overwrites it (F4, spec review). }
            Store.Heap.WriteBarrier(WASM_REF_NULL, Reg[Ins^.A].Ref);
          Store.Globals[Addr].Value.Bits := Reg[Ins^.A].Bits;
          Inc(IP);
        end;

      { --- numeric: constants (bit patterns; interp-spec §3.1) ----------- }
      iroI32Const:
        begin Reg[Ins^.Dest].Bits := UInt64(UInt32(Int32(Ins^.Imm))); Inc(IP); end;
      iroI64Const:
        begin Reg[Ins^.Dest].Bits := UInt64(Ins^.Imm); Inc(IP); end;
      iroF32Const:
        begin Reg[Ins^.Dest].Bits := UInt64(UInt32(Ins^.Imm)); Inc(IP); end;
      iroF64Const:
        begin Reg[Ins^.Dest].Bits := UInt64(Ins^.Imm); Inc(IP); end;

      { --- numeric: i32 test/compare ------------------------------------- }
      iroI32Eqz:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Eqz(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32Eq:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Eq(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Ne:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Ne(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32LtS:
        begin Reg[Ins^.Dest].Bits := UInt64(I32LtS(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32LtU:
        begin Reg[Ins^.Dest].Bits := UInt64(I32LtU(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32GtS:
        begin Reg[Ins^.Dest].Bits := UInt64(I32GtS(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32GtU:
        begin Reg[Ins^.Dest].Bits := UInt64(I32GtU(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32LeS:
        begin Reg[Ins^.Dest].Bits := UInt64(I32LeS(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32LeU:
        begin Reg[Ins^.Dest].Bits := UInt64(I32LeU(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32GeS:
        begin Reg[Ins^.Dest].Bits := UInt64(I32GeS(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32GeU:
        begin Reg[Ins^.Dest].Bits := UInt64(I32GeU(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;

      { --- numeric: i64 test/compare (result is i32) --------------------- }
      iroI64Eqz:
        begin Reg[Ins^.Dest].Bits := UInt64(I64Eqz(Reg[Ins^.A].U64)); Inc(IP); end;
      iroI64Eq:
        begin Reg[Ins^.Dest].Bits := UInt64(I64Eq(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64Ne:
        begin Reg[Ins^.Dest].Bits := UInt64(I64Ne(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64LtS:
        begin Reg[Ins^.Dest].Bits := UInt64(I64LtS(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64LtU:
        begin Reg[Ins^.Dest].Bits := UInt64(I64LtU(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64GtS:
        begin Reg[Ins^.Dest].Bits := UInt64(I64GtS(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64GtU:
        begin Reg[Ins^.Dest].Bits := UInt64(I64GtU(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64LeS:
        begin Reg[Ins^.Dest].Bits := UInt64(I64LeS(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64LeU:
        begin Reg[Ins^.Dest].Bits := UInt64(I64LeU(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64GeS:
        begin Reg[Ins^.Dest].Bits := UInt64(I64GeS(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroI64GeU:
        begin Reg[Ins^.Dest].Bits := UInt64(I64GeU(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;

      { --- numeric: f32 compare (result is i32) -------------------------- }
      iroF32Eq:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Eq(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Ne:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Ne(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Lt:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Lt(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Gt:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Gt(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Le:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Le(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Ge:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Ge(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;

      { --- numeric: f64 compare (result is i32) -------------------------- }
      iroF64Eq:
        begin Reg[Ins^.Dest].Bits := UInt64(F64Eq(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroF64Ne:
        begin Reg[Ins^.Dest].Bits := UInt64(F64Ne(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroF64Lt:
        begin Reg[Ins^.Dest].Bits := UInt64(F64Lt(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroF64Gt:
        begin Reg[Ins^.Dest].Bits := UInt64(F64Gt(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroF64Le:
        begin Reg[Ins^.Dest].Bits := UInt64(F64Le(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;
      iroF64Ge:
        begin Reg[Ins^.Dest].Bits := UInt64(F64Ge(Reg[Ins^.A].U64, Reg[Ins^.B].U64)); Inc(IP); end;

      { --- numeric: i32 unary/binary ------------------------------------- }
      iroI32Clz:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Clz(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32Ctz:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Ctz(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32Popcnt:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Popcnt(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32Add:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Add(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Sub:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Sub(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Mul:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Mul(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32DivS:
        begin Reg[Ins^.Dest].Bits := UInt64(I32DivS(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32DivU:
        begin Reg[Ins^.Dest].Bits := UInt64(I32DivU(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32RemS:
        begin Reg[Ins^.Dest].Bits := UInt64(I32RemS(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32RemU:
        begin Reg[Ins^.Dest].Bits := UInt64(I32RemU(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32And:
        begin Reg[Ins^.Dest].Bits := UInt64(I32And(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Or:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Or(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Xor:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Xor(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Shl:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Shl(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32ShrS:
        begin Reg[Ins^.Dest].Bits := UInt64(I32ShrS(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32ShrU:
        begin Reg[Ins^.Dest].Bits := UInt64(I32ShrU(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Rotl:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Rotl(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroI32Rotr:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Rotr(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;

      { --- numeric: i64 unary/binary ------------------------------------- }
      iroI64Clz:
        begin Reg[Ins^.Dest].Bits := I64Clz(Reg[Ins^.A].U64); Inc(IP); end;
      iroI64Ctz:
        begin Reg[Ins^.Dest].Bits := I64Ctz(Reg[Ins^.A].U64); Inc(IP); end;
      iroI64Popcnt:
        begin Reg[Ins^.Dest].Bits := I64Popcnt(Reg[Ins^.A].U64); Inc(IP); end;
      iroI64Add:
        begin Reg[Ins^.Dest].Bits := I64Add(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64Sub:
        begin Reg[Ins^.Dest].Bits := I64Sub(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64Mul:
        begin Reg[Ins^.Dest].Bits := I64Mul(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64DivS:
        begin Reg[Ins^.Dest].Bits := I64DivS(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64DivU:
        begin Reg[Ins^.Dest].Bits := I64DivU(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64RemS:
        begin Reg[Ins^.Dest].Bits := I64RemS(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64RemU:
        begin Reg[Ins^.Dest].Bits := I64RemU(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64And:
        begin Reg[Ins^.Dest].Bits := I64And(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64Or:
        begin Reg[Ins^.Dest].Bits := I64Or(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64Xor:
        begin Reg[Ins^.Dest].Bits := I64Xor(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64Shl:
        begin Reg[Ins^.Dest].Bits := I64Shl(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64ShrS:
        begin Reg[Ins^.Dest].Bits := I64ShrS(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64ShrU:
        begin Reg[Ins^.Dest].Bits := I64ShrU(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64Rotl:
        begin Reg[Ins^.Dest].Bits := I64Rotl(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroI64Rotr:
        begin Reg[Ins^.Dest].Bits := I64Rotr(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;

      { --- numeric: f32 unary/binary (results are f32 bit patterns) ------ }
      iroF32Abs:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Abs(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32Neg:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Neg(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32Ceil:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Ceil(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32Floor:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Floor(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32Trunc:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Trunc(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32Nearest:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Nearest(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32Sqrt:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Sqrt(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32Add:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Add(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Sub:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Sub(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Mul:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Mul(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Div:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Div(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Min:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Min(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Max:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Max(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;
      iroF32Copysign:
        begin Reg[Ins^.Dest].Bits := UInt64(F32Copysign(Reg[Ins^.A].U32, Reg[Ins^.B].U32)); Inc(IP); end;

      { --- numeric: f64 unary/binary ------------------------------------- }
      iroF64Abs:
        begin Reg[Ins^.Dest].Bits := F64Abs(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64Neg:
        begin Reg[Ins^.Dest].Bits := F64Neg(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64Ceil:
        begin Reg[Ins^.Dest].Bits := F64Ceil(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64Floor:
        begin Reg[Ins^.Dest].Bits := F64Floor(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64Trunc:
        begin Reg[Ins^.Dest].Bits := F64Trunc(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64Nearest:
        begin Reg[Ins^.Dest].Bits := F64Nearest(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64Sqrt:
        begin Reg[Ins^.Dest].Bits := F64Sqrt(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64Add:
        begin Reg[Ins^.Dest].Bits := F64Add(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroF64Sub:
        begin Reg[Ins^.Dest].Bits := F64Sub(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroF64Mul:
        begin Reg[Ins^.Dest].Bits := F64Mul(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroF64Div:
        begin Reg[Ins^.Dest].Bits := F64Div(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroF64Min:
        begin Reg[Ins^.Dest].Bits := F64Min(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroF64Max:
        begin Reg[Ins^.Dest].Bits := F64Max(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;
      iroF64Copysign:
        begin Reg[Ins^.Dest].Bits := F64Copysign(Reg[Ins^.A].U64, Reg[Ins^.B].U64); Inc(IP); end;

      { --- numeric: conversions ------------------------------------------ }
      iroI32WrapI64:
        begin Reg[Ins^.Dest].Bits := UInt64(I32WrapI64(Reg[Ins^.A].U64)); Inc(IP); end;
      iroI32TruncF32S:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncF32S(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32TruncF32U:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncF32U(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32TruncF64S:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncF64S(Reg[Ins^.A].U64)); Inc(IP); end;
      iroI32TruncF64U:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncF64U(Reg[Ins^.A].U64)); Inc(IP); end;
      iroI64ExtendI32S:
        begin Reg[Ins^.Dest].Bits := I64ExtendI32S(Reg[Ins^.A].U32); Inc(IP); end;
      iroI64ExtendI32U:
        begin Reg[Ins^.Dest].Bits := I64ExtendI32U(Reg[Ins^.A].U32); Inc(IP); end;
      iroI64TruncF32S:
        begin Reg[Ins^.Dest].Bits := I64TruncF32S(Reg[Ins^.A].U32); Inc(IP); end;
      iroI64TruncF32U:
        begin Reg[Ins^.Dest].Bits := I64TruncF32U(Reg[Ins^.A].U32); Inc(IP); end;
      iroI64TruncF64S:
        begin Reg[Ins^.Dest].Bits := I64TruncF64S(Reg[Ins^.A].U64); Inc(IP); end;
      iroI64TruncF64U:
        begin Reg[Ins^.Dest].Bits := I64TruncF64U(Reg[Ins^.A].U64); Inc(IP); end;
      iroF32ConvertI32S:
        begin Reg[Ins^.Dest].Bits := UInt64(F32ConvertI32S(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32ConvertI32U:
        begin Reg[Ins^.Dest].Bits := UInt64(F32ConvertI32U(Reg[Ins^.A].U32)); Inc(IP); end;
      iroF32ConvertI64S:
        begin Reg[Ins^.Dest].Bits := UInt64(F32ConvertI64S(Reg[Ins^.A].U64)); Inc(IP); end;
      iroF32ConvertI64U:
        begin Reg[Ins^.Dest].Bits := UInt64(F32ConvertI64U(Reg[Ins^.A].U64)); Inc(IP); end;
      iroF32DemoteF64:
        begin Reg[Ins^.Dest].Bits := UInt64(F32DemoteF64(Reg[Ins^.A].U64)); Inc(IP); end;
      iroF64ConvertI32S:
        begin Reg[Ins^.Dest].Bits := F64ConvertI32S(Reg[Ins^.A].U32); Inc(IP); end;
      iroF64ConvertI32U:
        begin Reg[Ins^.Dest].Bits := F64ConvertI32U(Reg[Ins^.A].U32); Inc(IP); end;
      iroF64ConvertI64S:
        begin Reg[Ins^.Dest].Bits := F64ConvertI64S(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64ConvertI64U:
        begin Reg[Ins^.Dest].Bits := F64ConvertI64U(Reg[Ins^.A].U64); Inc(IP); end;
      iroF64PromoteF32:
        begin Reg[Ins^.Dest].Bits := F64PromoteF32(Reg[Ins^.A].U32); Inc(IP); end;
      iroI32ReinterpretF32:
        begin Reg[Ins^.Dest].Bits := UInt64(Reg[Ins^.A].U32); Inc(IP); end;
      iroI64ReinterpretF64:
        begin Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits; Inc(IP); end;
      iroF32ReinterpretI32:
        begin Reg[Ins^.Dest].Bits := UInt64(Reg[Ins^.A].U32); Inc(IP); end;
      iroF64ReinterpretI64:
        begin Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits; Inc(IP); end;

      { --- numeric: sign extension (2.0) --------------------------------- }
      iroI32Extend8S:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Extend8S(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32Extend16S:
        begin Reg[Ins^.Dest].Bits := UInt64(I32Extend16S(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI64Extend8S:
        begin Reg[Ins^.Dest].Bits := I64Extend8S(Reg[Ins^.A].U64); Inc(IP); end;
      iroI64Extend16S:
        begin Reg[Ins^.Dest].Bits := I64Extend16S(Reg[Ins^.A].U64); Inc(IP); end;
      iroI64Extend32S:
        begin Reg[Ins^.Dest].Bits := I64Extend32S(Reg[Ins^.A].U64); Inc(IP); end;

      { --- numeric: saturating truncation -------------------------------- }
      iroI32TruncSatF32S:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncSatF32S(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32TruncSatF32U:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncSatF32U(Reg[Ins^.A].U32)); Inc(IP); end;
      iroI32TruncSatF64S:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncSatF64S(Reg[Ins^.A].U64)); Inc(IP); end;
      iroI32TruncSatF64U:
        begin Reg[Ins^.Dest].Bits := UInt64(I32TruncSatF64U(Reg[Ins^.A].U64)); Inc(IP); end;
      iroI64TruncSatF32S:
        begin Reg[Ins^.Dest].Bits := I64TruncSatF32S(Reg[Ins^.A].U32); Inc(IP); end;
      iroI64TruncSatF32U:
        begin Reg[Ins^.Dest].Bits := I64TruncSatF32U(Reg[Ins^.A].U32); Inc(IP); end;
      iroI64TruncSatF64S:
        begin Reg[Ins^.Dest].Bits := I64TruncSatF64S(Reg[Ins^.A].U64); Inc(IP); end;
      iroI64TruncSatF64U:
        begin Reg[Ins^.Dest].Bits := I64TruncSatF64U(Reg[Ins^.A].U64); Inc(IP); end;

      { --- exception handling: staged to Track H (interp-spec §4.6) ------ }
      iroThrow, iroThrowRef:
        StageException;

      { --- memory (interp-spec §3.7; all access via the chokepoint) ------- }
      iroI32Load, iroI64Load, iroF32Load, iroF64Load,
      iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
      iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
      iroI64Load32S, iroI64Load32U:
        begin ExecLoad(ACtx, Act, Ins); Inc(IP); end;
      iroI32Store, iroI64Store, iroF32Store, iroF64Store,
      iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16, iroI64Store32:
        begin ExecStore(ACtx, Act, Ins); Inc(IP); end;
      iroMemorySize:
        begin
          Reg[Ins^.Dest].Bits :=
            Store.MemoryPages(Act^.Instance.MemAddrs[UInt32(Ins^.Imm)]);
          Inc(IP);
        end;
      iroMemoryGrow:
        begin
          { Grow never traps and never runs the collector; -1 on failure, as
            the addr type's all-ones. }
          Addr := Act^.Instance.MemAddrs[UInt32(Ins^.Imm)];
          if Store.MemoryAddrType(Addr) = watI64 then
            Reg[Ins^.Dest].Bits := UInt64(Store.MemoryGrow(Addr, Reg[Ins^.A].U64))
          else
            Reg[Ins^.Dest].Bits :=
              UInt64(UInt32(Store.MemoryGrow(Addr, Reg[Ins^.A].U64)));
          Inc(IP);
        end;
      iroMemoryInit:
        begin ExecMemoryInit(ACtx, Act, Ins); Inc(IP); end;
      iroMemoryCopy:
        begin ExecMemoryCopy(ACtx, Act, Ins); Inc(IP); end;
      iroMemoryFill:
        begin ExecMemoryFill(ACtx, Act, Ins); Inc(IP); end;
      iroDataDrop:
        begin
          { A dropped segment reads as empty: zero its span so a later
            memory.init from it traps. }
          Addr := Act^.Instance.DataAddrs[UInt32(Ins^.Imm)];
          Store.Datas[Addr].Dropped := True;
          Store.Datas[Addr].Size := 0;
          Store.Datas[Addr].Data := nil;
          Inc(IP);
        end;

      { --- table (interp-spec §3.8; reference stores are barriered store
        methods, reads are free functions) -------------------------------- }
      iroTableGet:
        begin
          Reg[Ins^.Dest].Bits := UInt64(TableGet(
            Store.Tables[Act^.Instance.TableAddrs[UInt32(Ins^.Imm)]],
            Reg[Ins^.A].U64));
          Inc(IP);
        end;
      iroTableSet:
        begin
          { A = index, B = value (Dest is unused per IR_OP_INFO). }
          Store.TableSet(Act^.Instance.TableAddrs[UInt32(Ins^.Imm)],
            Reg[Ins^.A].U64, Reg[Ins^.B].Ref);
          Inc(IP);
        end;
      iroTableSize:
        begin
          Reg[Ins^.Dest].Bits := TableSize(
            Store.Tables[Act^.Instance.TableAddrs[UInt32(Ins^.Imm)]]);
          Inc(IP);
        end;
      iroTableGrow:
        begin
          { Dest = result, A = init value, B = delta; -1 on failure. }
          Addr := Act^.Instance.TableAddrs[UInt32(Ins^.Imm)];
          if Store.Tables[Addr].TableType.Limits.AddrType = watI64 then
            Reg[Ins^.Dest].Bits :=
              UInt64(Store.TableGrow(Addr, Reg[Ins^.B].U64, Reg[Ins^.A].Ref))
          else
            Reg[Ins^.Dest].Bits := UInt64(UInt32(
              Store.TableGrow(Addr, Reg[Ins^.B].U64, Reg[Ins^.A].Ref)));
          Inc(IP);
        end;
      iroTableFill:
        begin
          { Dest = index, A = value, B = count. Barriered, range-checked. }
          Store.TableFill(Act^.Instance.TableAddrs[UInt32(Ins^.Imm)],
            Reg[Ins^.Dest].U64, Reg[Ins^.B].U64, Reg[Ins^.A].Ref);
          Inc(IP);
        end;
      iroTableInit:
        begin
          { Dest = dst, A = src, B = count; Imm = IrPack(tableIndex, elemIndex).
            Sliced barriered store, both sides bounds-checked. }
          IrUnpack(Ins^.Imm, U1, U2);
          Store.TableInitFromElem(Act^.Instance.TableAddrs[U1],
            Reg[Ins^.Dest].U64,
            Store.Elems[Act^.Instance.ElemAddrs[U2]].Refs,
            Reg[Ins^.A].U64, Reg[Ins^.B].U64);
          Inc(IP);
        end;
      iroTableCopy:
        begin
          { Dest = dst, A = src, B = count; Imm = IrPack(dstTable, srcTable). }
          IrUnpack(Ins^.Imm, U1, U2);
          Store.TableCopy(Act^.Instance.TableAddrs[U1], Reg[Ins^.Dest].U64,
            Act^.Instance.TableAddrs[U2], Reg[Ins^.A].U64, Reg[Ins^.B].U64);
          Inc(IP);
        end;
      iroElemDrop:
        begin
          Addr := Act^.Instance.ElemAddrs[UInt32(Ins^.Imm)];
          Store.Elems[Addr].Refs := nil;
          Store.Elems[Addr].Dropped := True;
          Inc(IP);
        end;

      { --- reference (interp-spec §3.9) ---------------------------------- }
      iroRefNull:
        begin Reg[Ins^.Dest].Bits := UInt64(WASM_REF_NULL); Inc(IP); end;
      iroRefIsNull:
        begin
          ValueSetI32(Reg[Ins^.Dest], Ord(RefIsNull(Reg[Ins^.A].Ref)));
          Inc(IP);
        end;
      iroRefFunc:
        begin
          Reg[Ins^.Dest].Bits := UInt64(
            Store.Funcs[Act^.Instance.FuncAddrs[UInt32(Ins^.Imm)]].RefObject);
          Inc(IP);
        end;
      iroRefEq:
        begin
          ValueSetI32(Reg[Ins^.Dest],
            Ord(Reg[Ins^.A].Ref = Reg[Ins^.B].Ref));
          Inc(IP);
        end;
      iroRefAsNonNull:
        begin
          if RefIsNull(Reg[Ins^.A].Ref) then
            TrapNow(wtkNullReference);   { the BARE message (exec-ref.as_non_null) }
          Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits;
          Inc(IP);
        end;
      iroRefTest:
        begin
          ValueSetI32(Reg[Ins^.Dest], Ord(MatchesAuxRefType(Fn,
            Act^.Instance, Store.Engine, Reg[Ins^.A].Ref, UInt32(Ins^.Imm))));
          Inc(IP);
        end;
      iroRefCast:
        begin
          if MatchesAuxRefType(Fn, Act^.Instance, Store.Engine,
            Reg[Ins^.A].Ref, UInt32(Ins^.Imm)) then
            Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits
          else
            TrapNow(wtkCastFailure);
          Inc(IP);
        end;
      { The ref-consuming branch forms carry: A = source ref, B = target instr
        index, Dest = fall-through refinement reg (IR_NO_REG when the edge's
        merge moves thread the value instead), Imm = reftype aux for the cast
        forms. Branch is taken (IP := B) when the op's condition holds; the
        not-taken edge writes the refined value into Dest when present. }
      iroBrOnNull:
        begin
          if RefIsNull(Reg[Ins^.A].Ref) then
            IP := Ins^.B
          else
          begin
            if Ins^.Dest <> IR_NO_REG then
              Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits;
            Inc(IP);
          end;
        end;
      iroBrOnNonNull:
        begin
          if not RefIsNull(Reg[Ins^.A].Ref) then
            IP := Ins^.B
          else
          begin
            if Ins^.Dest <> IR_NO_REG then
              Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits;
            Inc(IP);
          end;
        end;
      iroBrOnCast:
        begin
          if MatchesAuxRefType(Fn, Act^.Instance, Store.Engine,
            Reg[Ins^.A].Ref, UInt32(Ins^.Imm)) then
            IP := Ins^.B
          else
          begin
            if Ins^.Dest <> IR_NO_REG then
              Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits;
            Inc(IP);
          end;
        end;
      iroBrOnCastFail:
        begin
          if not MatchesAuxRefType(Fn, Act^.Instance, Store.Engine,
            Reg[Ins^.A].Ref, UInt32(Ins^.Imm)) then
            IP := Ins^.B
          else
          begin
            if Ins^.Dest <> IR_NO_REG then
              Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits;
            Inc(IP);
          end;
        end;

      { --- GC: struct / array / i31 (interp-spec §3.10) ------------------ }
      iroStructNew:
        begin ExecStructNew(ACtx, Act, Ins); Inc(IP); end;
      iroStructNewDefault:
        begin ExecStructNewDefault(ACtx, Act, Ins); Inc(IP); end;
      iroStructGet:
        begin
          IrUnpack(Ins^.Imm, U1, U2);   { U2 = field index }
          Reg[Ins^.Dest] := Store.Heap.StructGet(Reg[Ins^.A].Ref, U2);
          Inc(IP);
        end;
      iroStructGetS:
        begin
          IrUnpack(Ins^.Imm, U1, U2);
          ValueSetI32(Reg[Ins^.Dest],
            Store.Heap.StructGetSigned(Reg[Ins^.A].Ref, U2));
          Inc(IP);
        end;
      iroStructGetU:
        begin
          IrUnpack(Ins^.Imm, U1, U2);
          ValueSetU32(Reg[Ins^.Dest],
            Store.Heap.StructGetUnsigned(Reg[Ins^.A].Ref, U2));
          Inc(IP);
        end;
      iroStructSet:
        begin
          IrUnpack(Ins^.Imm, U1, U2);
          Store.Heap.StructSet(Reg[Ins^.A].Ref, U2, Reg[Ins^.B]);
          Inc(IP);
        end;
      iroArrayNew:
        begin ExecArrayNew(ACtx, Act, Ins); Inc(IP); end;
      iroArrayNewDefault:
        begin ExecArrayNewDefault(ACtx, Act, Ins); Inc(IP); end;
      iroArrayNewFixed:
        begin ExecArrayNewFixed(ACtx, Act, Ins); Inc(IP); end;
      iroArrayNewData:
        begin ExecArrayNewData(ACtx, Act, Ins); Inc(IP); end;
      iroArrayNewElem:
        begin ExecArrayNewElem(ACtx, Act, Ins); Inc(IP); end;
      iroArrayGet:
        begin
          Reg[Ins^.Dest] :=
            Store.Heap.ArrayGet(Reg[Ins^.A].Ref, Reg[Ins^.B].U32);
          Inc(IP);
        end;
      iroArrayGetS:
        begin
          ValueSetI32(Reg[Ins^.Dest],
            Store.Heap.ArrayGetSigned(Reg[Ins^.A].Ref, Reg[Ins^.B].U32));
          Inc(IP);
        end;
      iroArrayGetU:
        begin
          ValueSetU32(Reg[Ins^.Dest],
            Store.Heap.ArrayGetUnsigned(Reg[Ins^.A].Ref, Reg[Ins^.B].U32));
          Inc(IP);
        end;
      iroArraySet:
        begin
          Store.Heap.ArraySet(Reg[Ins^.Dest].Ref, Reg[Ins^.A].U32, Reg[Ins^.B]);
          Inc(IP);
        end;
      iroArrayLen:
        begin
          ValueSetU32(Reg[Ins^.Dest], Store.Heap.ArrayLength(Reg[Ins^.A].Ref));
          Inc(IP);
        end;
      iroArrayFill:
        begin ExecArrayFill(ACtx, Act, Ins); Inc(IP); end;
      iroArrayCopy:
        begin ExecArrayCopy(ACtx, Act, Ins); Inc(IP); end;
      iroArrayInitData:
        begin ExecArrayInitData(ACtx, Act, Ins); Inc(IP); end;
      iroArrayInitElem:
        begin ExecArrayInitElem(ACtx, Act, Ins); Inc(IP); end;
      { extern.convert_any / any.convert_extern: identity on the
        representation (KNOWN LIMITATION M7 — the kind-only abstract map does
        not track the hierarchy switch, so a cross-hierarchy ref.test/cast
        after a convert gives the wrong answer; see the report). }
      iroAnyConvertExtern, iroExternConvertAny:
        begin Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits; Inc(IP); end;
      iroRefI31:
        begin
          Reg[Ins^.Dest].Bits := UInt64(MakeI31Ref(Reg[Ins^.A].I32));
          Inc(IP);
        end;
      iroI31GetS:
        begin
          if RefIsNull(Reg[Ins^.A].Ref) then
            TrapNow(wtkNullI31Reference);
          ValueSetI32(Reg[Ins^.Dest], I31GetSigned(Reg[Ins^.A].Ref));
          Inc(IP);
        end;
      iroI31GetU:
        begin
          if RefIsNull(Reg[Ins^.A].Ref) then
            TrapNow(wtkNullI31Reference);
          ValueSetU32(Reg[Ins^.Dest], I31GetUnsigned(Reg[Ins^.A].Ref));
          Inc(IP);
        end;
    else
      { The case is exhaustive over TWasmIrOp; this catches a future op the
        validator emits before a tier arm exists for it. Delegated to a leaf
        so Run stays free of managed locals (TRAP-1). }
      UnhandledOp(Ins^.Op);
    end;
  end;
end;

{ --- the interpreter context lifecycle (interp-spec §7.3) ---------------- }

function NewInterpContext(const AStore: TWasmStore): PWasmInterpContext;
begin
  New(Result);
  Result^.Store := AStore;
  Result^.ValueCap := WasmInterpValueSlots;
  Result^.DepthCap := WasmInterpMaxDepth;
  Result^.ValueTop := 0;
  Result^.Depth := 0;
  { The OS backs untouched pages lazily, so a multi-MiB reservation is cheap
    until used. Never grown or moved while a frame is live (interp-spec §1.1). }
  Result^.Values := GetMem(Result^.ValueCap * SizeOf(TWasmValue));
  Result^.Acts := GetMem(Result^.DepthCap * SizeOf(TWasmActivation));
end;

{ The store's TierContextFree hook: releases the two reservations and the
  record. Signature matches TWasmStore.TierContextFree. }
procedure FreeInterpContext(AContext: Pointer);
var
  Ctx: PWasmInterpContext;
begin
  Ctx := PWasmInterpContext(AContext);
  if Ctx = nil then
    Exit;
  if Ctx^.Values <> nil then
    FreeMem(Ctx^.Values);
  if Ctx^.Acts <> nil then
    FreeMem(Ctx^.Acts);
  Dispose(Ctx);
end;

function InterpContextFor(const AStore: TWasmStore): PWasmInterpContext;
begin
  if AStore.TierContext = nil then
  begin
    AStore.TierContext := NewInterpContext(AStore);
    AStore.TierContextFree := @FreeInterpContext;
  end;
  Result := PWasmInterpContext(AStore.TierContext);
end;

procedure ResetInterpContext(const AStore: TWasmStore);
var
  Ctx: PWasmInterpContext;
begin
  if AStore.TierContext = nil then
    Exit;
  Ctx := PWasmInterpContext(AStore.TierContext);
  Ctx^.Depth := 0;
  Ctx^.ValueTop := 0;
end;

{ --- host function as the entry point (interp-spec §4.5) ----------------- }

procedure InvokeHostEntry(const AStore: TWasmStore; const AAddr: TWasmFuncAddr;
  const AParams, AResults: PWasmValue);
begin
  AStore.Funcs[AAddr].Callback(AStore, AStore.Funcs[AAddr].HostData,
    AParams, AResults);
end;

{ --- the invoke boundary (interp-spec §1.5) ------------------------------ }

procedure InterpTierInvoke(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: PWasmInterpContext;
  Inst: TWasmModuleInstance;
  Fn: PWasmIrFunction;
  Entry: PWasmActivation;
  Slots: PWasmValue;
  SavedDepth, SavedTop: NativeUInt;
  I: UInt32;
begin
  AStore.CheckThread;                     { ADR-0008 }
  Ctx := InterpContextFor(AStore);

  { Wasm float ops never trap: mask the FPU on whatever thread runs guest
    code (Wasm.Interp.Numeric masked only its init thread). }
  MaskFpuExceptions;

  { Cursor resync (interp-spec §5.3/§7.3). An empty GC chain means a genuine
    top level — either a fresh invoke or a prior trap whose unwind dropped
    the chain via Heap.ResetFrames, leaving Ctx cursors stale. A nested
    host->guest re-entry always has the outer frames on the chain, so its
    cursors are trusted. }
  if AStore.Heap.CurrentFrame = nil then
  begin
    Ctx^.Depth := 0;
    Ctx^.ValueTop := 0;
  end;

  if AStore.Funcs[AFuncAddr].Kind = wfkHost then
  begin
    InvokeHostEntry(AStore, AFuncAddr, AParams, AResults);
    Exit;
  end;

  SavedDepth := Ctx^.Depth;
  SavedTop := Ctx^.ValueTop;

  Inst := AStore.Funcs[AFuncAddr].Instance;
  Fn := @Inst.Ir.Functions[AStore.Funcs[AFuncAddr].FuncIrIndex];

  if (Ctx^.Depth >= Ctx^.DepthCap) or
    (Ctx^.ValueTop + Fn^.RegisterCount > Ctx^.ValueCap) then
    TrapNow(wtkStackExhausted);

  Entry := @Ctx^.Acts[Ctx^.Depth];
  Entry^.Fn := Fn;
  Entry^.Instance := Inst;
  Entry^.Base := Ctx^.ValueTop;
  Entry^.IP := 0;
  Ctx^.ValueTop := Entry^.Base + Fn^.RegisterCount;

  Slots := Frame(Ctx^.Values, Entry^.Base);
  ValueZeroSlots(Slots, Fn^.RegisterCount);

  { Marshal AParams into param registers [0 .. ParamCount-1]. AParams may be
    nil for a no-parameter entry (e.g. RunPendingStart), which the guard
    keeps from underflowing. }
  I := 0;
  while I < Fn^.ParamCount do
  begin
    Slots[I] := AParams[I];
    Inc(I);
  end;

  Entry^.RetKind := rtEntry;
  Entry^.RetCount := Fn^.ResultCount;
  Entry^.RetDest := nil;
  Entry^.RetBase := 0;
  Entry^.EntryResults := AResults;

  PushGcFrame(Ctx, Entry, Fn, Entry^.Base);
  Inc(Ctx^.Depth);

  Run(Ctx, SavedDepth);

  { Clean return: DoReturn already popped the entry frame. Restore the
    nesting cursors so an outer invocation is undisturbed. A trap unwinds
    past this line; the trampoline landing re-syncs instead. }
  Ctx^.Depth := SavedDepth;
  Ctx^.ValueTop := SavedTop;
end;

{ --- guest entry through the trampoline (interp-spec §1.5/§5) ------------ }

type
  PInvokeArgs = ^TInvokeArgs;

  TInvokeArgs = record
    Store: TWasmStore;
    Addr: TWasmFuncAddr;
    Params: PWasmValue;
    Results: PWasmValue;
  end;

{ The guest region WasmInvoke runs. A plain procedure over a Pointer — no
  closure, which would be managed state a longjmp could skip (TRAP-1). }
procedure InvokeThunk(const AData: Pointer);
var
  Args: PInvokeArgs;
begin
  Args := PInvokeArgs(AData);
  InterpTierInvoke(Args^.Store, Args^.Addr, Args^.Params, Args^.Results);
end;

procedure InterpInvoke(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Args: TInvokeArgs;
  Outermost: Boolean;
begin
  { The finally below re-establishes the frame chain and the context cursors
    after any unwind, but only at the TRUE top level — a nested host->guest
    call must not drop the outer frames. CurrentTrampoline being nil is the
    signal that no invocation encloses this one. }
  Outermost := CurrentTrampoline = nil;
  Args.Store := AStore;
  Args.Addr := AFuncAddr;
  Args.Params := AParams;
  Args.Results := AResults;
  try
    WasmInvoke(@InvokeThunk, @Args);
  except
    { A trap (or an ordinary EWasmError from a staged op) unwound the guest.
      At the TRUE top level re-establish the frame chain and the context
      cursors before re-raising; a nested host->guest re-entry leaves the
      outer frames alone. try/except (not try/finally): matching the
      trampoline's own test pattern, the exception is re-raised on ordinary
      ground. }
    on E: Exception do
    begin
      if Outermost then
      begin
        AStore.Heap.ResetFrames;
        ResetInterpContext(AStore);
      end;
      raise;
    end;
  end;
end;

{ --- registration -------------------------------------------------------- }

procedure RegisterInterpreter(const AStore: TWasmStore);
begin
  if AStore = nil then
    raise EWasmError.Create('RegisterInterpreter: nil store');
  if AStore.TierContext = nil then
  begin
    AStore.TierContext := NewInterpContext(AStore);
    AStore.TierContextFree := @FreeInterpContext;
  end;
  AStore.TierInvoke := @InterpTierInvoke;
end;

end.
