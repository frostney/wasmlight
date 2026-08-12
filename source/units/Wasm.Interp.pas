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

  WHAT SHIPS HERE: the full non-throwing dispatch over the register IR —
  numeric (dispatched to Wasm.Interp.Numeric), SIMD/v128 (dispatched to
  Wasm.Interp.Vector; a v128 register is a pair of adjacent slots read
  through VecAt, simd-spec §1.3, and the load/store family goes through the
  one memory chokepoint via MemLoadV128/MemStoreV128), parametric (select),
  variable (global.get/set; local get/set/tee are register iroMove in the IR),
  all lowered control (jump/branch/br_table/return, call/call_indirect/call_ref
  and the three tail-call forms, the epoch safepoint check per ADR-0006),
  memory and table ops through the one chokepoint, references, and the GC
  struct/array/i31 family — plus the tier seam (RegisterInterpreter wires the
  store's TierInvoke/TierContext), host calls across that boundary, and precise
  GC frame discharge at every safepoint. call_indirect dispatch matches by
  deftype SUBTYPING (see ResolveIndirect).

  extern.convert_any / any.convert_extern (M7) cross the any<->extern
  hierarchy boundary through Wasm.Runtime.Gc's ExternalizeAny /
  InternalizeExtern wrapper pair, so a subsequent ref.test/ref.cast classifies
  a converted value correctly (interp-spec §3.9 O-4).

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

  Wasm.Core,
  Wasm.Ir,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

type
  { The interpreter's activation and per-store context, exposed so the
    baseline JIT can build a frame through the shared helpers below (O-J2).
    Both tiers run in ONE TWasmInterpContext — the same value-stack and
    activation reservations — so a compiled frame and an interpreted frame
    are bit-identical (jit-spec §5.1). }
  PWasmIrFunction = ^TWasmIrFunction;
  PWasmIrInstr = ^TWasmIrInstr;

  PWasmActivation = ^TWasmActivation;

  { How a frame's results are delivered, and — crucially for Track H's unwind —
    what an escaping exception does when it reaches this frame (Fix A).
      rtCaller       — a wasm->wasm call inside ONE Run: results go to the
                       caller's dest registers; the exception unwind pops it and
                       keeps scanning in the SAME Run (transparent, same native
                       context).
      rtCompiledSeam — a TIER-SEAM entry: the frame JitEnterFrame carved for a
                       compiled body, or for an interpreted callee reached ACROSS
                       the seam from compiled code (a nested native invocation).
                       Results go to EntryResults (like rtEntry). The exception
                       unwind pops it and LongJmps (SeamHop) to the innermost
                       seam catch of the enclosing native invocation, which re-enters
                       the unwind — so a throw crosses a compiled frame to reach
                       an interpreted try_table further out (Finding 3). NOT an
                       invocation boundary.
      rtEntry        — the GENUINE outermost guest entry of this trampoline
                       (empty GC chain at entry, or a host->guest re-entry).
                       Results go to EntryResults. An uncaught exception here
                       RaiseUncaughts (EWasmException) — the true boundary. }
  TWasmRetKind = (rtCaller, rtEntry, rtCompiledSeam);

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
    { Values is 16-byte aligned so slot 0 — and, since every frame Base is
      even (the validator keeps RegisterCount even and even-aligns each
      v128 register), every even slot — sits on a 16-byte boundary. That is
      what lets a v128 register pair be read/written as an aligned 16-byte
      unit (simd-spec §1.5). ValuesRaw is the un-aligned GetMem result kept
      for FreeMem. }
    Values: PWasmValue;              { aligned into ValuesRaw }
    ValuesRaw: Pointer;              { GetMem base, for FreeMem }
    ValueCap: NativeUInt;
    ValueTop: NativeUInt;            { next free slot }
    Acts: PWasmActivation;           { GetMem(DepthCap * SizeOf activation) }
    DepthCap: NativeUInt;
    Depth: NativeUInt;               { number of live activations }
  end;

  { O-J5: the register-file / frame offsets the JIT's generated code reads
    at fixed offsets — the slot stride for Reg[k] = Values[Base + k]
    addressing, the context cursors, and the TWasmGcFrame fields a prologue
    publishes. Layout-only (no instance needed); the co-located test asserts
    the values the JIT hard-codes. Store.Epoch and the memory-instance
    offsets live in Wasm.Runtime.Store's WasmJitOffsets. }
  TWasmJitFrameOffsets = record
    ValueSlotSize: NativeUInt;       { SizeOf(TWasmValue) — the slot stride }
    CtxValues: NativeUInt;           { TWasmInterpContext.Values }
    CtxValueTop: NativeUInt;         { TWasmInterpContext.ValueTop }
    CtxValueCap: NativeUInt;         { TWasmInterpContext.ValueCap }
    CtxDepth: NativeUInt;            { TWasmInterpContext.Depth }
    ActStride: NativeUInt;           { SizeOf(TWasmActivation) }
    ActBase: NativeUInt;             { TWasmActivation.Base }
    GcFrameSlots: NativeUInt;        { TWasmGcFrame.Slots }
    GcFrameRefRegBits: NativeUInt;   { TWasmGcFrame.RefRegBits }
    GcFrameRegisterCount: NativeUInt;{ TWasmGcFrame.RegisterCount }
  end;

  { The two live values a generated direct-call site needs after the shared
    frame helper has resolved and entered a compiled callee. Kept pointer-only
    so both native backends use the same 16-byte stack layout. }
  PWasmJitDirectCallState = ^TWasmJitDirectCallState;
  TWasmJitDirectCallState = record
    RegBase: PWasmValue;
    IrBase: PWasmIrInstr;
  end;

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

{ --- the shared tier-seam frame helpers (O-J2, jit-spec §5.1) ------------

  These are the ONE implementation of the frame carve / zero / GC-push /
  param-marshal / result-marshal / pop discipline. The interpreter's own
  entry path (InterpTierInvoke) builds its frame through JitEnterFrame, and
  the baseline JIT's compiled-function dispatcher calls the identical pair —
  so a compiled frame and an interpreted frame are carved, zeroed, pushed,
  and popped by the same code, and the exhaustion threshold, the GC contract,
  and the null/default-init discipline are identical by construction rather
  than by parallel re-implementation (jit-spec §5.1, §5.4). }

{ Return the interpreter/JIT execution context for a store, creating it on
  first use. The JIT shares this exact context (its value stack, activation
  array, depth accounting) so stack-exhaustion, GC, and epoch behaviour stay
  bit-identical across tiers. }
function InterpContextFor(const AStore: TWasmStore): PWasmInterpContext;

const
  { Cap on a cross-tier pending tail's argument slots — the same marshal cap the
    interpreter's own call paths use. }
  WASM_TIER_TAIL_CAP = 1024;

type
  { The cross-tier pending-tail channel (Fix A, Finding 1). One per thread (a
    store is single-threaded, ADR-0008). Written by BOTH a compiled body's
    return_call* helper AND the interpreter's Run when an ENTRY-level tail
    crosses tiers; read by the backend trampoline loop, which re-dispatches the
    target with ZERO native-stack growth so an alternating compiled<->interp
    tail chain stays O(1). }
  PWasmTierTail = ^TWasmTierTail;

  TWasmTierTail = record
    Pending: Boolean;
    Addr: TWasmFuncAddr;
    ArgCount: UInt32;
    Args: array[0 .. WASM_TIER_TAIL_CAP - 1] of TWasmValue;
  end;

{ @GTierTail (the per-thread pending-tail slot) so the backend loops and the
  interpreter share ONE channel. }
function TierTailSlot: PWasmTierTail;

{ Record a resolved cross-tier tail target + its collected argument slots into
  the shared channel. Args are COPIED because the frame they came from is about
  to be torn down. Raises on an over-cap arity. }
procedure SetTierPendingTail(const AAddr: TWasmFuncAddr;
  const AArgs: PWasmValue; const ACount: UInt32);

{ The seam-reentry flag (Fix A). A tier-seam launcher (interp->compiled,
  compiled->interp, compiled->compiled) calls MarkJitSeamReentry immediately
  before crossing a fixed-signature dispatch hook; the tier-entry it reaches
  (InterpTierInvoke, or a backend InvokeCompiled) calls ConsumeJitSeamReentry
  once at entry to learn whether its frame is a nested seam (rtCompiledSeam) or
  a genuine outermost entry (rtEntry). Defaults cleared, so with no JIT every
  frame is rtEntry and the unwind behaves exactly as before. }
procedure MarkJitSeamReentry;
function ConsumeJitSeamReentry: TWasmRetKind;

{ Mark the next tier entry as a trampoline-driven interpreted TAIL target (Fix
  A, Finding 1): the backend loop calls this before running an interpreted tail
  target so that target's Run may BOUNCE a cross-tier tail back to the loop
  (O(1)) rather than nesting a native invocation. }
procedure MarkTierTailTarget;

{ The unwind entry point, exposed so a seam catch can CONTINUE the unwind in its
  own native context after a rtCompiledSeam hop (Fix A). AThrowFrame is True only
  when called straight from iroThrow/iroThrowRef (the top frame is the throwing
  frame, scanned at its own IP); a seam catch passes False (the top frame is a
  caller suspended at a call site, scanned at IP-1). Either resumes a matching
  handler (some frame's IP is set; returns), or SeamHops to the innermost
  seam catch to hop further out, or raises EWasmException (genuinely uncaught at
  the outermost entry). }
procedure UnwindException(const ACtx: PWasmInterpContext; const AExn: TWasmRef;
  const AThrowFrame: Boolean);

{ Prologue. Exhaustion-check both caps (-> TrapNow(wtkStackExhausted), the
  same threshold every path uses); carve the register file at ValueTop; zero
  every slot (a ref reads null, a numeric local defaults 0); marshal the FLAT
  AParams into the callee's padded param registers (a v128 param spans two
  consecutive flat slots); wire the frame to deliver its results to the flat
  AResults; push the TWasmGcFrame before the first safepoint; Inc(Depth).
  Returns @Values[Base], the register-file base the compiled body reads and
  writes. AParams may be nil for a 0-parameter function. ARetKind is the frame's
  return/unwind kind (Fix A): rtEntry for a genuine outermost guest entry,
  rtCompiledSeam for a nested tier-seam entry (a compiled body, or an
  interpreted callee reached across the seam). }
function JitEnterFrame(const ACtx: PWasmInterpContext; const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue;
  const ARetKind: TWasmRetKind): PWasmValue;

{ Epilogue. The compiled body has written its result registers; marshal them
  into the AResults handed to JitEnterFrame and pop the frame — identical to
  iroReturn on an rtEntry frame. Pops the top activation of ACtx. }
procedure JitLeaveFrame(const ACtx: PWasmInterpContext);

{ Fast path for a statically indexed compiled-to-compiled call. Prepare
  resolves the caller's module function index, returns nil without changing
  state for host/interpreted callees, or pushes a transparent rtCaller frame
  and returns the native entry. Finish switches that already-completed frame
  to flat-result delivery and pops it. Keeping rtCaller while native code runs
  lets the outer invocation's one LongJmp barrier unwind through any number of
  direct native calls without installing a Pascal seam per call. }
function JitPrepareDirectCall(const AStore: TWasmStore;
  const AFuncIdx: PtrUInt; const AArgs, AResults: PWasmValue;
  const AState: PWasmJitDirectCallState): Pointer; cdecl;
procedure JitFinishDirectCall(const AStore: TWasmStore); cdecl;

{ O-J5: the register-file / frame offsets the JIT hard-codes (see the record
  above). Layout-only; the co-located test asserts them. }
function WasmJitFrameOffsets: TWasmJitFrameOffsets;

const
  { The AOT ABI revision (aot-spec §1.4). A hand-bumped integer for any emitter
    change the fingerprint's structural inputs cannot otherwise see — a
    template's byte layout, a pinned-register reassignment, the entry-ABI shape.
    Bump it whenever position-independent codegen changes in a way that would
    make an existing artifact's bytes wrong. }
  AOT_ABI_REVISION = 3;

{ A deterministic 64-bit fingerprint over everything a serialized artifact's
  code bakes as a constant and the loading runtime must therefore agree on
  (aot-spec §1.4): all WasmJitOffsets fields, all WasmJitFrameOffsets fields,
  SizeOf(TWasmIrInstr) (the pinned-IR-base stride), SizeOf(TWasmValue) (the slot
  stride), the helper-table slot count, and AOT_ABI_REVISION. The AOT loader
  recomputes this from the LIVE runtime and rejects an artifact on mismatch —
  the "same build/ABI" guard beside the IR-version and arch guards. Wave 0
  ships the compute function; the AOT tier consumes it in Wave 1. Needs a live
  store because StoreEpoch et al. are measured from the object reference. }
function WasmAotAbiFingerprint(const AStore: TWasmStore): UInt64;

implementation

uses
  Wasm.Interp.Numeric,
  Wasm.Interp.Vector,
  Wasm.Runtime.Traps;

const
  { A fixed ceiling on the parameter/result count a single call marshals
    through a stack-local scratch buffer (interp-spec §1.4 TRAP-1: the
    scratch must be plain stack data, not a managed dynamic array a TrapNow
    could skip). Comfortably above the spec's function-arity implementation
    limits; a module exceeding it raises a loud internal error rather than
    misbehaving. }
  WASM_INTERP_MAX_MARSHAL = 1024;

threadvar
  { Fix A. See the interface comments. All default cleared per thread, so with
    no JIT registered none is ever set and every tier entry is rtEntry with no
    tail bounce. }
  GJitSeamReentry: Boolean;
  { Set by the backend trampoline loop's interpreted arm before it runs an
    interpreted TAIL target (Fix A, Finding 1): tells that target's Run it may
    hand a cross-tier tail back to the loop (BOUNCE) instead of nesting. A plain
    (non-tail) compiled->interp call never sets it, so the callee completes
    normally and its results flow to the caller. }
  GTierTailTarget: Boolean;
  GTierTail: TWasmTierTail;

function TierTailSlot: PWasmTierTail;
begin
  Result := @GTierTail;
end;

procedure SetTierPendingTail(const AAddr: TWasmFuncAddr;
  const AArgs: PWasmValue; const ACount: UInt32);
var
  I: UInt32;
begin
  if ACount > WASM_TIER_TAIL_CAP then
    raise EWasmError.Create(
      'internal: cross-tier tail-call arity exceeds the marshal cap');
  I := 0;
  while I < ACount do
  begin
    GTierTail.Args[I] := AArgs[I];
    Inc(I);
  end;
  GTierTail.Addr := AAddr;
  GTierTail.ArgCount := ACount;
  GTierTail.Pending := True;
end;

procedure MarkJitSeamReentry;
begin
  GJitSeamReentry := True;
end;

function ConsumeJitSeamReentry: TWasmRetKind;
begin
  if GJitSeamReentry then
    Result := rtCompiledSeam
  else
    Result := rtEntry;
  GJitSeamReentry := False;
end;

{ Mark / consume the tail-target flag (Fix A, Finding 1). Interface-exposed via
  the two procs below so the backend trampoline loops can set it. }
procedure MarkTierTailTarget;
begin
  GTierTailTarget := True;
end;

function ConsumeTierTailTarget: Boolean;
begin
  Result := GTierTailTarget;
  GTierTailTarget := False;
end;

{ Forward decls — the seam catches in CompiledCall / ReturnCompiledCall use
  these unwind leaves, which are defined later beside Run (Fix A). }
procedure RaiseUncaught(const AExn: TWasmRef; const ATagAddr: UInt32); forward;

{ TWasmActivation, TWasmInterpContext and the IR pointer types now live in
  the interface (moved for O-J2 so the JIT can build a frame through the
  shared helpers). }

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

{ --- the padded-slot calling convention (simd-spec §1.5-§1.6) ------------

  A v128 register occupies two adjacent 8-byte slots and its low slot is
  EVEN, so IrAllocReg inserts an i32 pad whenever a v128 param/result would
  otherwise land on an odd slot. Every boundary that moves values between a
  DENSE, wasm-operand-order block (the caller's SlotList, the entry seam's
  flat AParams/AResults, the host ABI buffers) and a callee's or a frame's
  PADDED registers must therefore scatter through LocalRegs / ResultRegs
  rather than copy positionally — otherwise every operand at or after an
  internal pad is misplaced. These four helpers are the single place that
  translation lives, so the entry seam, wasm->wasm calls, tail calls, and the
  result paths cannot drift apart. }

{ Scatter a flat, dense argument block (v128 = two consecutive low-then-high
  entries, in wasm operand order) into a callee's PADDED parameter registers.
  Param i lands at AFn^.LocalRegs[i] (+1 for the v128 high half). A scalar-only
  signature walks 1:1. }
procedure ScatterParamsFlat(const AFn: PWasmIrFunction;
  const ADest, AFlatSrc: PWasmValue);
var
  I, FlatCur, LowReg: UInt32;
begin
  FlatCur := 0;
  I := 0;
  while I < AFn^.ParamCount do
  begin
    LowReg := AFn^.LocalRegs[I];
    ADest[LowReg] := AFlatSrc[FlatCur];
    if AFn^.RegTypes[LowReg].Kind = wvkVec then
    begin
      ADest[LowReg + 1] := AFlatSrc[FlatCur + 1];
      Inc(FlatCur, 2);
    end
    else
      Inc(FlatCur);
    Inc(I);
  end;
end;

{ As ScatterParamsFlat, but the source is the caller's dense arg block read
  indirectly through the caller's registers (the SlotList aux block). Used by
  PushWasmFrame, whose source and destination frames never overlap. }
procedure ScatterParamsFromBlock(const AFn: PWasmIrFunction;
  const ADest, ACallerRegs: PWasmValue; const ACallerAux: TWasmIrAuxU32;
  const AArgBlock: UInt32);
var
  I, FlatCur, LowReg: UInt32;
begin
  FlatCur := 0;
  I := 0;
  while I < AFn^.ParamCount do
  begin
    LowReg := AFn^.LocalRegs[I];
    ADest[LowReg] := ACallerRegs[IrAuxBlockItem(ACallerAux, AArgBlock, FlatCur)];
    if AFn^.RegTypes[LowReg].Kind = wvkVec then
    begin
      ADest[LowReg + 1] :=
        ACallerRegs[IrAuxBlockItem(ACallerAux, AArgBlock, FlatCur + 1)];
      Inc(FlatCur, 2);
    end
    else
      Inc(FlatCur);
    Inc(I);
  end;
end;

{ Scatter a flat, dense result block (v128 = two consecutive entries) into a
  frame's PADDED result registers, so a subsequent DoReturn reads them back
  pad-aware. Used by the host return path. }
procedure ScatterResultsFlat(const AFn: PWasmIrFunction;
  const AFrameBase, AFlatSrc: PWasmValue);
var
  K, FlatCur, LowReg: UInt32;
begin
  FlatCur := 0;
  K := 0;
  while K < AFn^.ResultCount do
  begin
    LowReg := AFn^.ResultRegs[K];
    AFrameBase[LowReg] := AFlatSrc[FlatCur];
    if AFn^.RegTypes[LowReg].Kind = wvkVec then
    begin
      AFrameBase[LowReg + 1] := AFlatSrc[FlatCur + 1];
      Inc(FlatCur, 2);
    end
    else
      Inc(FlatCur);
    Inc(K);
  end;
end;

{ --- return (interp-spec §1.4) ------------------------------------------- }

procedure DoReturn(const ACtx: PWasmInterpContext; const ATop: PWasmActivation);
var
  FrameBase, DestRegs: PWasmValue;
  Fn: PWasmIrFunction;
  K, FlatCur, LowReg: UInt32;
begin
  { The merge moves that fill the result registers were materialised by
    validation before the iroReturn. Those registers are PADDED (a scalar
    result before a v128 leaves an even-alignment pad, simd-spec §1.5), so the
    results are gathered through ResultRegs rather than as a contiguous run
    from ReturnRegBase. The destination is dense in both cases: EntryResults is
    the flat AResults array (low half then high), and RetDest names the
    caller's dense SlotList block, so a v128 result fills two consecutive
    destination entries. }
  Fn := ATop^.Fn;
  FrameBase := Frame(ACtx^.Values, ATop^.Base);
  FlatCur := 0;
  { rtCompiledSeam delivers to EntryResults exactly as rtEntry: both are frames
    JitEnterFrame carved with EntryResults set and no caller-register wiring. }
  if ATop^.RetKind <> rtCaller then
  begin
    K := 0;
    while K < Fn^.ResultCount do
    begin
      LowReg := Fn^.ResultRegs[K];
      ATop^.EntryResults[FlatCur] := FrameBase[LowReg];
      if Fn^.RegTypes[LowReg].Kind = wvkVec then
      begin
        ATop^.EntryResults[FlatCur + 1] := FrameBase[LowReg + 1];
        Inc(FlatCur, 2);
      end
      else
        Inc(FlatCur);
      Inc(K);
    end;
  end
  else
  begin
    DestRegs := Frame(ACtx^.Values, ATop^.RetBase);
    K := 0;
    while K < Fn^.ResultCount do
    begin
      LowReg := Fn^.ResultRegs[K];
      DestRegs[ATop^.RetDest[FlatCur]] := FrameBase[LowReg];
      if Fn^.RegTypes[LowReg].Kind = wvkVec then
      begin
        DestRegs[ATop^.RetDest[FlatCur + 1]] := FrameBase[LowReg + 1];
        Inc(FlatCur, 2);
      end
      else
        Inc(FlatCur);
      Inc(K);
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

  { Marshal args into the callee's PADDED param registers. NewBase >= the
    caller's frame end, so source and destination never overlap. The arg block
    is dense (wasm operand order, v128 = two consecutive source slots); the
    callee's params carry an even-alignment pad, so the scatter places each arg
    at LocalRegs[i] instead of copying positionally (simd-spec §1.6). }
  CallerRegs := Frame(ACtx^.Values, ACaller^.Base);
  ScatterParamsFromBlock(CalleeFn, Slots, CallerRegs, ACaller^.Fn^.AuxU32,
    AArgAux);

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
  { Tmp is the flat, dense arg block gathered from the old frame; scatter it
    into the callee's PADDED param registers exactly as PushWasmFrame and the
    entry seam do (simd-spec §1.6). }
  ScatterParamsFlat(CalleeFn, Slots, @Tmp[0]);

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
  TopRegs: PWasmValue;
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

  { ResBuf is the flat, dense host-result block; scatter it into this frame's
    PADDED result registers so DoReturn reads it back pad-aware (simd-spec
    §1.6). }
  ScatterResultsFlat(ATop^.Fn, Frame(ACtx^.Values, ATop^.Base), @ResBuf[0]);
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
    { The corpus spells the INDEXED form, 'uninitialized element 2'
      (bulk.wast:222), where the trailing number is the element index that
      was null; it rides in the trampoline Detail and is appended after the
      jump. The runner prefix-matches, so a corpus expecting the bare
      'uninitialized element' still passes against the indexed spelling. }
    TrapNowDetail(wtkUninitializedElement, UInt32(Idx));

  FuncAddr := ACtx^.Store.FuncRefAddr(R);
  Expected := ACaller^.Instance.EngineTypeIds[TypeIdx];
  if not ACtx^.Store.Engine.Matches(ACtx^.Store.Funcs[FuncAddr].TypeId,
    Expected) then
    TrapNow(wtkIndirectCallTypeMismatch);

  Result := FuncAddr;
end;

{ --- compiled callee dispatch (O-J1, jit-spec §4.4) ----------------------

  A wasm callee whose CompiledEntry <> nil is run through the JIT hook, and
  from the interpreter's side it behaves EXACTLY like a host function: gather
  the caller's args into a flat buffer, hand them to the hook, scatter the
  flat results back into the caller's dest registers. The flat buffer format
  (v128 = two consecutive entries, wasm operand order) is the same one the
  entry seam uses, so params/results marshal identically whether the callee
  is compiled or interpreted — the observational-identity property. The
  compiled callee runs to completion and returns; no interpreter frame is
  pushed for it. }
procedure CompiledCall(const ACtx: PWasmInterpContext;
  const ACaller: PWasmActivation; const AArgAux, ADstAux: UInt32;
  const AAddr: TWasmFuncAddr);
var
  CallerRegs: PWasmValue;
  ArgN, ResN, I: UInt32;
  Seam: TWasmSeamCatch;
  ParamBuf, ResBuf: array[0 .. WASM_INTERP_MAX_MARSHAL - 1] of TWasmValue;
begin
  ArgN := IrAuxBlockCount(ACaller^.Fn^.AuxU32, AArgAux);
  ResN := IrAuxBlockCount(ACaller^.Fn^.AuxU32, ADstAux);
  if (ArgN > WASM_INTERP_MAX_MARSHAL) or (ResN > WASM_INTERP_MAX_MARSHAL) then
    raise EWasmError.Create('internal: compiled-call arity exceeds the marshal cap');

  CallerRegs := Frame(ACtx^.Values, ACaller^.Base);
  I := 0;
  while I < ArgN do
  begin
    ParamBuf[I] := CallerRegs[IrAuxBlockItem(ACaller^.Fn^.AuxU32, AArgAux, I)];
    Inc(I);
  end;

  { Fix A: the compiled callee's frame is a tier seam. An exception thrown
    beneath it LongJmps up to THIS seam catch (a Pascal raise cannot cross the
    callee's native frame on this target). On the hop, CONTINUE the unwind in
    this caller's context (the caller frame is on top now that the callee's
    frames were popped as the unwind climbed). If a handler in this Run matches,
    ResumeAtClause set its IP and the unwind returned — we Exit and the dispatch
    loop's LoadTop resumes it (the result scatter is correctly skipped). If no
    handler matches, UnwindException SeamHops further out / RaiseUncaughts, so
    control never returns here. }
  MarkJitSeamReentry;
  Seam.Prev := CurrentSeamCatch;
  CurrentSeamCatch := @Seam;
  if SetJmp(Seam.JmpBuf) = 0 then
    ACtx^.Store.JitInvokeCompiled(ACtx^.Store, AAddr, @ParamBuf[0], @ResBuf[0])
  else
  begin
    CurrentSeamCatch := Seam.Prev;
    UnwindException(ACtx, TWasmRef(Seam.ExnRef), False);
    Exit;
  end;
  CurrentSeamCatch := Seam.Prev;

  { The value stack is fixed, so CallerRegs is still valid even if the
    compiled callee re-entered guest code (the guarantee HostCall relies on). }
  I := 0;
  while I < ResN do
  begin
    CallerRegs[IrAuxBlockItem(ACaller^.Fn^.AuxU32, ADstAux, I)] := ResBuf[I];
    Inc(I);
  end;
end;

{ return_call to a COMPILED function (jit-spec §4.5): run the compiled callee
  to completion, take its results as THIS frame's results, and return them to
  this frame's caller — the interpreter's ReturnHostCall shape, keeping the
  tail call O(1) (no wasm frame added). }
procedure ReturnCompiledCall(const ACtx: PWasmInterpContext;
  const ATop: PWasmActivation; const AArgAux: UInt32;
  const AAddr: TWasmFuncAddr);
var
  TopRegs: PWasmValue;
  ArgN, ResN, I: UInt32;
  Seam: TWasmSeamCatch;
  ExnR: TWasmRef;
  ParamBuf, ResBuf: array[0 .. WASM_INTERP_MAX_MARSHAL - 1] of TWasmValue;
begin
  ArgN := IrAuxBlockCount(ATop^.Fn^.AuxU32, AArgAux);
  ResN := ATop^.Fn^.ResultCount;   { equals the tail callee's result arity }
  if (ArgN > WASM_INTERP_MAX_MARSHAL) or (ResN > WASM_INTERP_MAX_MARSHAL) then
    raise EWasmError.Create('internal: compiled-call arity exceeds the marshal cap');

  TopRegs := Frame(ACtx^.Values, ATop^.Base);
  I := 0;
  while I < ArgN do
  begin
    ParamBuf[I] := TopRegs[IrAuxBlockItem(ATop^.Fn^.AuxU32, AArgAux, I)];
    Inc(I);
  end;

  { Fix A: a return_call ERASES the current frame's handlers (eh-spec §6.3) — a
    throw beneath the tail callee must not be caught by THIS frame's try_table.
    On the seam hop, pop THIS frame WITHOUT scanning its handlers, then continue
    the unwind from its caller (rtCaller) or hop/uncaught (seam/entry). The
    non-throwing path is unchanged: scatter results + DoReturn. }
  MarkJitSeamReentry;
  Seam.Prev := CurrentSeamCatch;
  CurrentSeamCatch := @Seam;
  if SetJmp(Seam.JmpBuf) <> 0 then
  begin
    CurrentSeamCatch := Seam.Prev;
    ExnR := TWasmRef(Seam.ExnRef);
    ACtx^.Store.Heap.PopFrame;
    ACtx^.ValueTop := ATop^.Base;
    Dec(ACtx^.Depth);
    case ATop^.RetKind of
      rtCompiledSeam:
        if CurrentSeamCatch <> nil then
          SeamHop(NativeUInt(ExnR))
        else
          RaiseUncaught(ExnR, ACtx^.Store.Heap.ExnTagAddr(ExnR));
      rtEntry:
        RaiseUncaught(ExnR, ACtx^.Store.Heap.ExnTagAddr(ExnR));
    else
      { rtCaller: keep scanning this frame's caller in the same Run. }
      UnwindException(ACtx, ExnR, False);
    end;
    Exit;
  end;
  ACtx^.Store.JitInvokeCompiled(ACtx^.Store, AAddr, @ParamBuf[0], @ResBuf[0]);
  CurrentSeamCatch := Seam.Prev;

  { ResBuf is the flat result block; scatter it into this frame's padded
    result registers so DoReturn reads it back pad-aware, exactly as
    ReturnHostCall does for a host tail callee. }
  ScatterResultsFlat(ATop^.Fn, Frame(ACtx^.Values, ATop^.Base), @ResBuf[0]);
  DoReturn(ACtx, ATop);
end;

{ --- call dispatch (wasm vs host vs compiled) ---------------------------- }

procedure EnterCall(const ACtx: PWasmInterpContext; const ACaller: PWasmActivation;
  const AArgAux, ADstAux: UInt32; const AAddr: TWasmFuncAddr);
begin
  if ACtx^.Store.Funcs[AAddr].Kind = wfkHost then
    HostCall(ACtx, ACaller, AArgAux, ADstAux, AAddr)
  else if Assigned(ACtx^.Store.JitInvokeCompiled) and
    (ACtx^.Store.Funcs[AAddr].CompiledEntry <> nil) then
    { Tier up: the JIT compiled this callee. The Assigned test comes first so
      the common no-JIT case is a single predicted-not-taken branch. }
    CompiledCall(ACtx, ACaller, AArgAux, ADstAux, AAddr)
  else
  begin
    { O-J1: the compile-on-hot counter — bumped on each interpreted call so
      the JIT can decide to compile this function. Invisible without a JIT. }
    Inc(ACtx^.Store.Funcs[AAddr].CallCount);
    PushWasmFrame(ACtx, ACaller, AArgAux, ADstAux, AAddr);
  end;
end;

procedure EnterTailCall(const ACtx: PWasmInterpContext; const ATop: PWasmActivation;
  const AArgAux: UInt32; const AAddr: TWasmFuncAddr);
begin
  if ACtx^.Store.Funcs[AAddr].Kind = wfkHost then
    ReturnHostCall(ACtx, ATop, AArgAux, AAddr)
  else if Assigned(ACtx^.Store.JitInvokeCompiled) and
    (ACtx^.Store.Funcs[AAddr].CompiledEntry <> nil) then
    ReturnCompiledCall(ACtx, ATop, AArgAux, AAddr)
  else
  begin
    Inc(ACtx^.Store.Funcs[AAddr].CallCount);
    ReplaceWasmFrame(ACtx, ATop, AArgAux, AAddr);
  end;
end;

{ True if AAddr is a COMPILED wasm callee — the cross-tier tail case a trampoline
  -driven interpreted tail target hands back to the backend loop (Fix A). Host
  and interpreted tails are NOT bounced (host completes in place; interp stays
  O(1) via ReplaceWasmFrame in this same Run). }
function IsCompiledCrossTier(const AStore: TWasmStore;
  const AAddr: TWasmFuncAddr): Boolean;
begin
  Result := (AStore.Funcs[AAddr].Kind <> wfkHost)
    and Assigned(AStore.JitInvokeCompiled)
    and (AStore.Funcs[AAddr].CompiledEntry <> nil);
end;

{ Hand an ENTRY-level cross-tier tail back to the backend trampoline loop (Fix A,
  Finding 1): gather the tail args from this (entry) frame, publish them in the
  shared channel, and pop the frame — WITHOUT running the callee. The backend
  loop that drove this interpreted tail target re-dispatches the pending target
  with zero native-stack growth, so an alternating compiled<->interp tail chain
  is O(1). The callee inherits this frame's EntryResults because the loop passes
  the SAME results buffer on the next iteration. }
procedure BouncePendingTail(const ACtx: PWasmInterpContext;
  const ATop: PWasmActivation; const AArgAux: UInt32;
  const AAddr: TWasmFuncAddr);
var
  TopRegs: PWasmValue;
  ArgN, I: UInt32;
begin
  ArgN := IrAuxBlockCount(ATop^.Fn^.AuxU32, AArgAux);
  if ArgN > WASM_TIER_TAIL_CAP then
    raise EWasmError.Create(
      'internal: cross-tier tail-call arity exceeds the marshal cap');
  TopRegs := Frame(ACtx^.Values, ATop^.Base);
  I := 0;
  while I < ArgN do
  begin
    GTierTail.Args[I] := TopRegs[IrAuxBlockItem(ATop^.Fn^.AuxU32, AArgAux, I)];
    Inc(I);
  end;
  GTierTail.Addr := AAddr;
  GTierTail.ArgCount := ArgN;
  GTierTail.Pending := True;
  { Pop the entry frame (drop its GcFrame, reset the cursors) — the same pop
    DoReturn performs, minus the result delivery the callee will do instead. }
  ACtx^.Store.Heap.PopFrame;
  ACtx^.ValueTop := ATop^.Base;
  Dec(ACtx^.Depth);
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

{ --- the SIMD load/store family: the SAME chokepoint (simd-spec §4.5) ----

  A v128 access is bounds-checked EXACTLY once, for its whole width, through
  Store.MemAddressAt — the one memory chokepoint every tier shares
  (AGENTS.md's named top failure mode). The range check runs before any byte
  moves, so a trapping v128.store writes nothing and the trap is the ordinary
  'out of bounds memory access'. The byte-transform leaf then produces or
  consumes the v128 from the checked pointer. Both are leaves (no managed
  Pascal locals), so a chokepoint TrapNow's LongJmp abandons nothing (TRAP-1).

  Register/immediate shapes, straight from the validator's HandleVector:
    plain load : Dest=v128, A=addr, B=mem index, Imm=static offset
    lane load  : Dest=v128, A=addr, B=source v128, Imm=aux[mem,offset,lane]
    plain store: Dest=v128 value, A=addr, B=mem index, Imm=static offset
    lane store : Dest=v128 value, A=addr, Imm=aux[mem,offset,lane] }
procedure MemLoadV128(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  MemAddr: TWasmMemAddr;
  Index, Offset: UInt64;
  MemIdx, Lane: UInt32;
  Dst: PWasmV128;
  P: PByte;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Index := Reg[AIns^.A].U64;
  Dst := VecAt(Reg, AIns^.Dest);
  { The lane forms carry mem index, offset and lane in an aux block; the
    plain forms carry mem index in B and offset in Imm. }
  case AIns^.Op of
    iroV128Load8Lane, iroV128Load16Lane, iroV128Load32Lane, iroV128Load64Lane:
      IrAuxReadLaneMemArg(AAct^.Fn^.AuxU32, UInt32(AIns^.Imm),
        MemIdx, Offset, Lane);
  else
    MemIdx := AIns^.B;
    Offset := UInt64(AIns^.Imm);
    Lane := 0;
  end;
  MemAddr := AAct^.Instance.MemAddrs[MemIdx];
  case AIns^.Op of
    iroV128Load:
      V128Load(Store.MemAddressAt(MemAddr, Index, Offset, 16), Dst);
    iroV128Load8x8S:
      V128Load8x8S(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load8x8U:
      V128Load8x8U(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load16x4S:
      V128Load16x4S(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load16x4U:
      V128Load16x4U(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load32x2S:
      V128Load32x2S(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load32x2U:
      V128Load32x2U(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load8Splat:
      V128Load8Splat(Store.MemAddressAt(MemAddr, Index, Offset, 1), Dst);
    iroV128Load16Splat:
      V128Load16Splat(Store.MemAddressAt(MemAddr, Index, Offset, 2), Dst);
    iroV128Load32Splat:
      V128Load32Splat(Store.MemAddressAt(MemAddr, Index, Offset, 4), Dst);
    iroV128Load64Splat:
      V128Load64Splat(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load32Zero:
      V128Load32Zero(Store.MemAddressAt(MemAddr, Index, Offset, 4), Dst);
    iroV128Load64Zero:
      V128Load64Zero(Store.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load8Lane:
      begin
        P := Store.MemAddressAt(MemAddr, Index, Offset, 1);
        V128Load8Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
    iroV128Load16Lane:
      begin
        P := Store.MemAddressAt(MemAddr, Index, Offset, 2);
        V128Load16Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
    iroV128Load32Lane:
      begin
        P := Store.MemAddressAt(MemAddr, Index, Offset, 4);
        V128Load32Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
    iroV128Load64Lane:
      begin
        P := Store.MemAddressAt(MemAddr, Index, Offset, 8);
        V128Load64Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
  end;
end;

procedure MemStoreV128(const ACtx: PWasmInterpContext;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Store: TWasmStore;
  Reg: PWasmValue;
  MemAddr: TWasmMemAddr;
  Index, Offset: UInt64;
  MemIdx, Lane: UInt32;
  Src: PWasmV128;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  Index := Reg[AIns^.A].U64;
  Src := VecAt(Reg, AIns^.Dest);   { the value register (ifkSrcReg in Dest) }
  case AIns^.Op of
    iroV128Store8Lane, iroV128Store16Lane, iroV128Store32Lane,
    iroV128Store64Lane:
      IrAuxReadLaneMemArg(AAct^.Fn^.AuxU32, UInt32(AIns^.Imm),
        MemIdx, Offset, Lane);
  else
    MemIdx := AIns^.B;
    Offset := UInt64(AIns^.Imm);
    Lane := 0;
  end;
  MemAddr := AAct^.Instance.MemAddrs[MemIdx];
  case AIns^.Op of
    iroV128Store:
      V128Store(Src, Store.MemAddressAt(MemAddr, Index, Offset, 16));
    iroV128Store8Lane:
      V128Store8Lane(Src, Lane, Store.MemAddressAt(MemAddr, Index, Offset, 1));
    iroV128Store16Lane:
      V128Store16Lane(Src, Lane, Store.MemAddressAt(MemAddr, Index, Offset, 2));
    iroV128Store32Lane:
      V128Store32Lane(Src, Lane, Store.MemAddressAt(MemAddr, Index, Offset, 4));
    iroV128Store64Lane:
      V128Store64Lane(Src, Lane, Store.MemAddressAt(MemAddr, Index, Offset, 8));
  end;
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
  ElemOffset, Count, SrcLen: UInt32;
begin
  Store := ACtx^.Store;
  Reg := Frame(ACtx^.Values, AAct^.Base);
  { Imm = IrPack(typeIndex, elemIndex); A = element offset, B = length. }
  IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
  ElemAddr := AAct^.Instance.ElemAddrs[ElemIdx];
  { exec-array.new_elem checks the ELEMENT-SEGMENT source range BEFORE
    allocating the array; otherwise an overflowing count allocates gigabytes
    and traps 'out of memory' where the spec (and corpus array.wast:283) want
    'out of bounds table access'. AllocArray is the safepoint, so the check
    has to precede it. The array-range half of the check is trivially
    satisfied here (dest is the fresh array, offset 0, length = count), so
    only the segment side matters. A dropped segment reads as empty. }
  ElemOffset := Reg[AIns^.A].U32;
  Count := Reg[AIns^.B].U32;
  SrcLen := UInt32(Length(Store.Elems[ElemAddr].Refs));
  if (ElemOffset > SrcLen) or (Count > SrcLen - ElemOffset) then
    TrapNow(wtkTableOutOfBounds);
  Obj := Store.Heap.AllocArray(AAct^.Instance.EngineTypeIds[TypeIdx], Count);
  Reg[AIns^.Dest].Bits := UInt64(Obj);
  Store.Heap.ArrayInitFromElem(Obj, 0, Store.Elems[ElemAddr].Refs,
    ElemOffset, Count);
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

{ array.fill with a v128 value (iroArrayFillVec): same aux block as the
  scalar form — [ref, index, valueLowReg, count] — but the value names a
  v128 register pair (simd-spec §2.4). }
procedure ExecArrayFillVec(const ACtx: PWasmInterpContext;
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
  Store.Heap.ArrayFillVec(
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
    Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
    VecAt(Reg, IrAuxBlockItem(Fn^.AuxU32, Aux, 2)));
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

{ --- Track H: the uncaught-exception boundary ---------------------------- }

{ The one place a wasm exception becomes a Pascal exception: the explicit
  unwind (UnwindException, in Run) found no matching handler in any frame of
  this invocation. Kept OUT of Run like the trap helpers so Run keeps no
  managed local — the constructed EWasmException and its message string live
  in this leaf's frame. This is an ORDINARY raise, NOT a longjmp: Run's locals
  are all unmanaged pointers/scalars, so a normal raise unwinds Run cleanly and
  runs WasmInvoke's finally, exactly as ADR-0009/eh-spec §2.4 require. }
procedure RaiseUncaught(const AExn: TWasmRef; const ATagAddr: UInt32);
begin
  raise EWasmException.CreateExn(NativeUInt(AExn), ATagAddr);
end;

{ Kept OUT of Run: building the message string would give Run a managed
  local, hence an implicit finalisation frame that a trap's raw LongJmp
  abandons — corrupting the exception-frame stack (TRAP-1). Run must have no
  managed locals, so every string lives in a leaf like this one. }
procedure UnhandledOp(const AOp: TWasmIrOp);
begin
  raise EWasmError.Create('internal: unhandled IR op ' + IrOpMnemonic(AOp));
end;

{ --- exception delivery + the explicit unwind (eh-spec §2.3) -------------
  Lifted to unit level (Fix A) so a tier-seam catch — a compiled body run in a
  backend InvokeCompiled, or a CompiledCall / ReturnCompiledCall launcher — can
  RE-ENTER the unwind in its own native context after a rtCompiledSeam hop.
  ResumeAtClause and the pop/scan logic are byte-for-byte the Track-H originals;
  the ONLY additions are the rtCompiledSeam arm and the AThrowFrame parameter. }

{ Deliver a matched exception to a clause: write its payload into the target
  label's merge registers and set the frame's IP to the clause target. The epoch
  poll reads ACtx^.Store.EpochSnapshot — the shared per-invocation snapshot Run
  also seeds its EpochCache from (equal by construction after Fix B), so the
  resume-time interrupt check is unchanged. }
procedure ResumeAtClause(const ACtx: PWasmInterpContext;
  const ATop: PWasmActivation; const AClause: TWasmIrCatchClause;
  const AExn: TWasmRef);
var
  Store: TWasmStore;
  ClauseRegs: PWasmValue;
  ArgC, I, Dst: UInt32;
begin
  Store := ACtx^.Store;
  ClauseRegs := Frame(ACtx^.Values, ATop^.Base);
  ArgC := Store.Heap.ExnArgCount(AExn);
  case AClause.Kind of
    wickCatch:
      begin
        I := 0;
        while I < ArgC do
        begin
          ClauseRegs[IrAuxBlockItem(ATop^.Fn^.AuxU32, AClause.PayloadAux, I)] :=
            Store.Heap.ExnArg(AExn, I);
          Inc(I);
        end;
      end;
    wickCatchRef:
      begin
        I := 0;
        while I < ArgC do
        begin
          ClauseRegs[IrAuxBlockItem(ATop^.Fn^.AuxU32, AClause.PayloadAux, I)] :=
            Store.Heap.ExnArg(AExn, I);
          Inc(I);
        end;
        { The exnref follows the payload. Canonical whole-slot ref write
          (.Bits := 0 then .Ref) so the collector's root scan never reads a
          stale high half (runtime-spec §1.1). }
        Dst := IrAuxBlockItem(ATop^.Fn^.AuxU32, AClause.PayloadAux, ArgC);
        ClauseRegs[Dst].Bits := 0;
        ClauseRegs[Dst].Ref := AExn;
      end;
    wickCatchAll:;   { nothing delivered }
    wickCatchAllRef:
      begin
        Dst := IrAuxBlockItem(ATop^.Fn^.AuxU32, AClause.PayloadAux, 0);
        ClauseRegs[Dst].Bits := 0;
        ClauseRegs[Dst].Ref := AExn;
      end;
  end;
  { EPOCH obligation (ADR-0006; Wasm.Ir TWasmIrHandlers comment). Resuming at
    TargetInstr bypasses the safepoint-flagged iroJump that every other path to
    a loop header runs, so poll the epoch here before resuming. }
  if Store.Epoch <> Store.EpochSnapshot then
    TrapNow(wtkEpochInterrupt);
  ATop^.IP := AClause.TargetInstr;
end;

procedure UnwindException(const ACtx: PWasmInterpContext; const AExn: TWasmRef;
  const AThrowFrame: Boolean);
var
  Store: TWasmStore;
  Top: PWasmActivation;
  Fn2: PWasmIrFunction;
  TagAddr, Ip, H, C: UInt32;
  Matched, ThrowFrame: Boolean;
  Clause: TWasmIrCatchClause;
begin
  Store := ACtx^.Store;
  { The thrown tag's store ADDRESS. Matching is by address, never by tag type
    (eh-spec §2.3/§4): this is what makes catch-imported-alias catch and
    imported-mismatch fall through. }
  TagAddr := Store.Heap.ExnTagAddr(AExn);
  ThrowFrame := AThrowFrame;
  while True do
  begin
    Top := @ACtx^.Acts[ACtx^.Depth - 1];
    Fn2 := Top^.Fn;
    { Which instruction is this frame "at"? The throwing frame published the
      throw's own index (always inside its try_table range). An unwound-through
      CALLER — including one re-entered from a seam catch (AThrowFrame False) —
      was suspended at a call and holds the RESUME IP = callsite+1; scan it at
      IP-1, the call site. (See the Track-H note on test-throw-1-2.) }
    if ThrowFrame or (Top^.IP = 0) then
      { A throwing frame is scanned at its own IP. A compiled seam frame's IP is
        always 0 (native code never advances Act^.IP) and it carries no handler
        table anyway, so scanning at 0 finds nothing and — crucially — avoids the
        0-1 underflow that a checked build traps as a range error (Fix A). }
      Ip := Top^.IP
    else
      Ip := Top^.IP - 1;

    { Scan the static handler table IN ORDER (inner appended before outer). A
      covering entry whose clauses do not match must NOT stop the scan — keep
      going to the next-outer covering entry in this same frame. A compiled
      frame carries an empty Handlers table (fence 1 declines handler-bearing
      functions), so this loop simply finds nothing for it and falls through to
      the rtCompiledSeam hop below — the frame is transparent to the unwind. }
    H := 0;
    while H < UInt32(Length(Fn2^.Handlers)) do
    begin
      if (Ip >= Fn2^.Handlers[H].StartInstr) and
        (Ip < Fn2^.Handlers[H].EndInstr) then
      begin
        C := 0;
        while C < Fn2^.Handlers[H].ClauseCount do
        begin
          Clause := Fn2^.HandlerClauses[Fn2^.Handlers[H].ClauseStart + C];
          case Clause.Kind of
            wickCatch, wickCatchRef:
              Matched := Top^.Instance.TagAddrs[Clause.TagIndex] = TagAddr;
          else
            Matched := True;
          end;
          if Matched then
          begin
            ResumeAtClause(ACtx, Top, Clause, AExn);
            Exit;   { back to the dispatch loop (or the seam catch's caller) }
          end;
          Inc(C);
        end;
      end;
      Inc(H);
    end;

    { No clause in this frame matched. Pop it (PopFrame unregisters the GC frame;
      ValueTop resets to the popped frame's Base — the pop DoReturn performs) and
      continue per its RetKind. }
    Store.Heap.PopFrame;
    ACtx^.ValueTop := Top^.Base;
    Dec(ACtx^.Depth);
    case Top^.RetKind of
      rtCaller:
        { A same-Run call frame: keep scanning the caller in THIS context. }
        ThrowFrame := False;
      rtCompiledSeam:
        { A tier-seam entry: hop to the innermost seam catch (a compiled body's
          wrapper, or an interp->compiled launcher) via a LongJmp — NOT a Pascal
          raise, which cannot unwind across a JIT body's native frame on this
          target. The catch re-enters this unwind (AThrowFrame False) to scan the
          frame(s) below the seam. A rtCompiledSeam frame exists only beneath a
          compiled body, so a seam catch is always installed; the nil guard is
          defensive. }
        if CurrentSeamCatch <> nil then
          SeamHop(NativeUInt(AExn))
        else
          RaiseUncaught(AExn, TagAddr);
      else
        { rtEntry — the genuine outermost boundary: uncaught (eh-spec §2.4). }
        RaiseUncaught(AExn, TagAddr);
    end;
  end;
end;

{ --- the dispatch loop (interp-spec §1.3) -------------------------------- }

{ One flat loop, no Pascal recursion per wasm call. Runs until the top-level
  invoke's entry frame returns — i.e. Depth drops back to AStopDepth. AAllowBounce
  (Fix A) is set only when the backend trampoline drives this Run as a tail
  target: it lets an ENTRY-level cross-tier tail hand back to that loop (O(1))
  instead of nesting. }
procedure Run(const ACtx: PWasmInterpContext; const AStopDepth: NativeUInt;
  const AAllowBounce: Boolean);
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
  { A thrown exception object, live across UnwindException. A bare TWasmRef
    (NativeUInt) — the unwind performs no allocation, so no collection can run
    while it is unrooted (eh-spec §2.5). }
  Exn: TWasmRef;
  N, Sel: UInt32;
  { Scratch for IrUnpack of packed immediates (struct field / table + segment
    index pairs). Plain integers — no managed state across a TrapNow. }
  U1, U2: UInt32;
  { Scratch for the two 16-byte SIMD immediates (v128.const literal /
    i8x16.shuffle lane mask). TWasmV128 has no managed fields, so a plain
    stack local here is TRAP-1 safe. }
  VTmp: TWasmV128;

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
  { ADR-0006 / jit-spec §6: source the back-edge snapshot from the SHARED
    per-invocation slot InterpTierInvoke seeded at the outermost guest-entry,
    NOT a fresh Store.Epoch read here. This keeps EpochCache a Run-local (so a
    nested host->guest re-entry, which re-seeds the shared slot for its own
    Run, never disturbs this outer Run's snapshot) while making the value the
    SAME one a compiled leaf's prologue loads — so both tiers observe an
    interrupt at exactly the same back-edges. }
  EpochCache := Store.EpochSnapshot;
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
          if AAllowBounce and (ACtx^.Depth = AStopDepth + 1) and
            IsCompiledCrossTier(Store, Addr) then
          begin
            BouncePendingTail(ACtx, Act, Ins^.A, Addr);
            Exit;   { the backend loop re-dispatches the pending target O(1) }
          end;
          EnterTailCall(ACtx, Act, Ins^.A, Addr);
          if ACtx^.Depth = AStopDepth then   { host tail from the entry frame }
            Exit;
          LoadTop;
        end;
      iroReturnCallIndirect:
        begin
          Addr := ResolveIndirect(ACtx, Act, Reg, Ins);
          if AAllowBounce and (ACtx^.Depth = AStopDepth + 1) and
            IsCompiledCrossTier(Store, Addr) then
          begin
            BouncePendingTail(ACtx, Act, Ins^.A, Addr);
            Exit;
          end;
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
          if AAllowBounce and (ACtx^.Depth = AStopDepth + 1) and
            IsCompiledCrossTier(Store, Addr) then
          begin
            BouncePendingTail(ACtx, Act, Ins^.A, Addr);
            Exit;
          end;
          EnterTailCall(ACtx, Act, Ins^.A, Addr);
          if ACtx^.Depth = AStopDepth then
            Exit;
          LoadTop;
        end;

      { --- parametric ---------------------------------------------------- }
      iroSelect:
        begin
          { Condition register rides in Imm (ifkSrcReg); a single-slot copy.
            A v128 select is a 16-byte copy and the validator emits the
            dedicated iroSelectVec op for it (SIMD design §2.4), so this
            scalar arm never sees a vector. }
          if Reg[UInt32(Ins^.Imm)].I32 <> 0 then
            Reg[Ins^.Dest].Bits := Reg[Ins^.A].Bits
          else
            Reg[Ins^.Dest].Bits := Reg[Ins^.B].Bits;
          Inc(IP);
        end;

      { --- variable (locals are register moves; globals are store cells) - }
      iroGlobalGet:
        begin
          { A v128 global's 16-byte cell is read by the dedicated
            iroGlobalGetVec op the validator emits (SIMD design §1.7/§2.4),
            so this scalar arm only reads the 8-byte Value cell. }
          Addr := Act^.Instance.GlobalAddrs[UInt32(Ins^.Imm)];
          Reg[Ins^.Dest].Bits := Store.Globals[Addr].Value.Bits;
          Inc(IP);
        end;
      iroGlobalSet:
        begin
          Addr := Act^.Instance.GlobalAddrs[UInt32(Ins^.Imm)];
          if Store.Globals[Addr].GlobalType.ValueType.Kind = wvkRef then
            { WriteBarrier(oldRef, newRef). The v1 barrier is empty, so the
              old-value argument is unused and passed as null. A future
              non-empty/generational barrier MUST first read the global
              cell's CURRENT value (Store.Globals[Addr].Value.Ref) and pass
              THAT as the old ref before the store below overwrites it (F4,
              spec review). }
            Store.Heap.WriteBarrier(WASM_REF_NULL, Reg[Ins^.A].Ref);
          { A v128 global is written by iroGlobalSetVec (SIMD design §2.4). }
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

      { --- exception handling (eh-spec §1, §2, §6) ----------------------- }
      iroThrow:
        begin
          { Publish the throw site so UnwindException scans THIS instruction's
            enclosing handlers (the throw index lies inside its try_table's
            [StartInstr, EndInstr) range). }
          Act^.IP := IP;
          U1 := Act^.Instance.TagAddrs[UInt32(Ins^.Imm)];   { tag store addr }
          N := IrAuxBlockCount(Fn^.AuxU32, Ins^.A);          { tag param count }
          { Allocate the exn object FIRST — the throw's only safepoint. The tag
            args are still live in this frame's rooted registers, and the fresh
            ref roots the object for the copy that follows; no safepoint sits
            between the allocation and the unwind, so Exn is never exposed to a
            collection while unrooted (eh-spec §2.5). }
          Exn := Store.Heap.AllocExn(U1, Store.Tags[U1].TypeId, N);
          U2 := 0;
          while U2 < N do
          begin
            Store.Heap.ExnSetArg(Exn, U2,
              Reg[IrAuxBlockItem(Fn^.AuxU32, Ins^.A, U2)]);
            Inc(U2);
          end;
          { AThrowFrame True: scan the top (throwing) frame at its own IP. }
          UnwindException(ACtx, Exn, True);   { resumes, or raises to leave Run }
          LoadTop;                { the catching frame may be an ancestor }
        end;
      iroThrowRef:
        begin
          Act^.IP := IP;
          R := Reg[Ins^.A].Ref;
          { throw_ref of ref.null exn traps (eh-spec §1.3, UNCONFIRMED): reuse
            the existing null-reference trap kind and message, on the trap route
            (siglongjmp), NOT the exception route. }
          if RefIsNull(R) then
            TrapNow(wtkNullReference);
          UnwindException(ACtx, R, True);
          LoadTop;
        end;

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
      { extern.convert_any / any.convert_extern (M7). The wrap/unwrap and the
        hierarchy switch live in the shared Gc helper so every tier gives the
        same answer (ADR-0001); the operand stays in a frame slot the stack
        map covers across the allocation safepoint inside the helper. }
      iroAnyConvertExtern:
        begin
          ValueSetRef(Reg[Ins^.Dest],
            Store.Heap.InternalizeExtern(Reg[Ins^.A].Ref));
          Inc(IP);
        end;
      iroExternConvertAny:
        begin
          ValueSetRef(Reg[Ins^.Dest],
            Store.Heap.ExternalizeAny(Reg[Ins^.A].Ref));
          Inc(IP);
        end;
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

      { === SIMD (Track G) — vector dispatch, one arm per iro* op ===
        A v128 register k occupies slots k and k+1; VecAt(Reg, k) aliases
        the pair as a TWasmV128 (simd-spec §1.3). Leaves live in
        Wasm.Interp.Vector and never touch the store, IR, or frames. }
      { --- SIMD memory loads: one chokepoint, explicit bounds check --- }
      iroV128Load, iroV128Load16Lane, iroV128Load16Splat, iroV128Load16x4S, iroV128Load16x4U, iroV128Load32Lane, iroV128Load32Splat, iroV128Load32Zero, iroV128Load32x2S, iroV128Load32x2U, iroV128Load64Lane, iroV128Load64Splat, iroV128Load64Zero, iroV128Load8Lane, iroV128Load8Splat, iroV128Load8x8S, iroV128Load8x8U:
        begin MemLoadV128(ACtx, Act, Ins); Inc(IP); end;
      { --- SIMD memory stores --------------------------------------- }
      iroV128Store, iroV128Store16Lane, iroV128Store32Lane, iroV128Store64Lane, iroV128Store8Lane:
        begin MemStoreV128(ACtx, Act, Ins); Inc(IP); end;
      { --- SIMD const / shuffle (16-byte immediate) ----------------- }
      iroV128Const:
        begin IrAuxReadV128(Fn^.AuxU32, UInt32(Ins^.Imm), VecAt(Reg, Ins^.Dest)^); Inc(IP); end;
      iroI8x16Shuffle:
        begin
          IrAuxReadV128(Fn^.AuxU32, UInt32(Ins^.Imm), VTmp);
          I8x16Shuffle(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), @VTmp.B[0],
            VecAt(Reg, Ins^.Dest));
          Inc(IP);
        end;
      iroI8x16Swizzle: begin I8x16Swizzle(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Splat: begin I8x16Splat(Reg[Ins^.A].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Splat: begin I16x8Splat(Reg[Ins^.A].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Splat: begin I32x4Splat(Reg[Ins^.A].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Splat: begin I64x2Splat(Reg[Ins^.A].U64, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Splat: begin F32x4Splat(Reg[Ins^.A].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Splat: begin F64x2Splat(Reg[Ins^.A].U64, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16ExtractLaneS: begin ValueSetU32(Reg[Ins^.Dest], I8x16ExtractLaneS(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm))); Inc(IP); end;
      iroI8x16ExtractLaneU: begin ValueSetU32(Reg[Ins^.Dest], I8x16ExtractLaneU(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm))); Inc(IP); end;
      iroI8x16ReplaceLane: begin I8x16ReplaceLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtractLaneS: begin ValueSetU32(Reg[Ins^.Dest], I16x8ExtractLaneS(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm))); Inc(IP); end;
      iroI16x8ExtractLaneU: begin ValueSetU32(Reg[Ins^.Dest], I16x8ExtractLaneU(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm))); Inc(IP); end;
      iroI16x8ReplaceLane: begin I16x8ReplaceLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtractLane: begin ValueSetU32(Reg[Ins^.Dest], I32x4ExtractLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm))); Inc(IP); end;
      iroI32x4ReplaceLane: begin I32x4ReplaceLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtractLane: begin Reg[Ins^.Dest].Bits := I64x2ExtractLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm)); Inc(IP); end;
      iroI64x2ReplaceLane: begin I64x2ReplaceLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm), Reg[Ins^.B].U64, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4ExtractLane: begin ValueSetU32(Reg[Ins^.Dest], F32x4ExtractLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm))); Inc(IP); end;
      iroF32x4ReplaceLane: begin F32x4ReplaceLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2ExtractLane: begin Reg[Ins^.Dest].Bits := F64x2ExtractLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm)); Inc(IP); end;
      iroF64x2ReplaceLane: begin F64x2ReplaceLane(VecAt(Reg, Ins^.A), UInt32(Ins^.Imm), Reg[Ins^.B].U64, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Eq: begin I8x16Eq(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Ne: begin I8x16Ne(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16LtS: begin I8x16LtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16LtU: begin I8x16LtU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16GtS: begin I8x16GtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16GtU: begin I8x16GtU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16LeS: begin I8x16LeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16LeU: begin I8x16LeU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16GeS: begin I8x16GeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16GeU: begin I8x16GeU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Eq: begin I16x8Eq(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Ne: begin I16x8Ne(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8LtS: begin I16x8LtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8LtU: begin I16x8LtU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8GtS: begin I16x8GtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8GtU: begin I16x8GtU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8LeS: begin I16x8LeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8LeU: begin I16x8LeU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8GeS: begin I16x8GeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8GeU: begin I16x8GeU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Eq: begin I32x4Eq(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Ne: begin I32x4Ne(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4LtS: begin I32x4LtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4LtU: begin I32x4LtU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4GtS: begin I32x4GtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4GtU: begin I32x4GtU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4LeS: begin I32x4LeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4LeU: begin I32x4LeU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4GeS: begin I32x4GeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4GeU: begin I32x4GeU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Eq: begin F32x4Eq(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Ne: begin F32x4Ne(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Lt: begin F32x4Lt(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Gt: begin F32x4Gt(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Le: begin F32x4Le(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Ge: begin F32x4Ge(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Eq: begin F64x2Eq(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Ne: begin F64x2Ne(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Lt: begin F64x2Lt(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Gt: begin F64x2Gt(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Le: begin F64x2Le(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Ge: begin F64x2Ge(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroV128Not: begin V128Not(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroV128And: begin V128And(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroV128Andnot: begin V128Andnot(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroV128Or: begin V128Or(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroV128Xor: begin V128Xor(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroV128Bitselect: begin V128Bitselect(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroV128AnyTrue: begin ValueSetU32(Reg[Ins^.Dest], V128AnyTrue(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroF32x4DemoteF64x2Zero: begin F32x4DemoteF64x2Zero(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2PromoteLowF32x4: begin F64x2PromoteLowF32x4(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Abs: begin I8x16Abs(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Neg: begin I8x16Neg(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Popcnt: begin I8x16Popcnt(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16AllTrue: begin ValueSetU32(Reg[Ins^.Dest], I8x16AllTrue(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI8x16Bitmask: begin ValueSetU32(Reg[Ins^.Dest], I8x16Bitmask(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI8x16NarrowI16x8S: begin I8x16NarrowI16x8S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16NarrowI16x8U: begin I8x16NarrowI16x8U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Ceil: begin F32x4Ceil(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Floor: begin F32x4Floor(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Trunc: begin F32x4Trunc(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Nearest: begin F32x4Nearest(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Shl: begin I8x16Shl(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16ShrS: begin I8x16ShrS(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16ShrU: begin I8x16ShrU(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Add: begin I8x16Add(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16AddSatS: begin I8x16AddSatS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16AddSatU: begin I8x16AddSatU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16Sub: begin I8x16Sub(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16SubSatS: begin I8x16SubSatS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16SubSatU: begin I8x16SubSatU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Ceil: begin F64x2Ceil(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Floor: begin F64x2Floor(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16MinS: begin I8x16MinS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16MinU: begin I8x16MinU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16MaxS: begin I8x16MaxS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16MaxU: begin I8x16MaxU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Trunc: begin F64x2Trunc(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16AvgrU: begin I8x16AvgrU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtaddPairwiseI8x16S: begin I16x8ExtaddPairwiseI8x16S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtaddPairwiseI8x16U: begin I16x8ExtaddPairwiseI8x16U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtaddPairwiseI16x8S: begin I32x4ExtaddPairwiseI16x8S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtaddPairwiseI16x8U: begin I32x4ExtaddPairwiseI16x8U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Abs: begin I16x8Abs(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Neg: begin I16x8Neg(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Q15mulrSatS: begin I16x8Q15mulrSatS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8AllTrue: begin ValueSetU32(Reg[Ins^.Dest], I16x8AllTrue(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI16x8Bitmask: begin ValueSetU32(Reg[Ins^.Dest], I16x8Bitmask(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI16x8NarrowI32x4S: begin I16x8NarrowI32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8NarrowI32x4U: begin I16x8NarrowI32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtendLowI8x16S: begin I16x8ExtendLowI8x16S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtendHighI8x16S: begin I16x8ExtendHighI8x16S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtendLowI8x16U: begin I16x8ExtendLowI8x16U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtendHighI8x16U: begin I16x8ExtendHighI8x16U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Shl: begin I16x8Shl(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ShrS: begin I16x8ShrS(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ShrU: begin I16x8ShrU(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Add: begin I16x8Add(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8AddSatS: begin I16x8AddSatS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8AddSatU: begin I16x8AddSatU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Sub: begin I16x8Sub(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8SubSatS: begin I16x8SubSatS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8SubSatU: begin I16x8SubSatU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Nearest: begin F64x2Nearest(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8Mul: begin I16x8Mul(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8MinS: begin I16x8MinS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8MinU: begin I16x8MinU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8MaxS: begin I16x8MaxS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8MaxU: begin I16x8MaxU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8AvgrU: begin I16x8AvgrU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtmulLowI8x16S: begin I16x8ExtmulLowI8x16S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtmulHighI8x16S: begin I16x8ExtmulHighI8x16S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtmulLowI8x16U: begin I16x8ExtmulLowI8x16U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8ExtmulHighI8x16U: begin I16x8ExtmulHighI8x16U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Abs: begin I32x4Abs(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Neg: begin I32x4Neg(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4AllTrue: begin ValueSetU32(Reg[Ins^.Dest], I32x4AllTrue(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI32x4Bitmask: begin ValueSetU32(Reg[Ins^.Dest], I32x4Bitmask(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI32x4ExtendLowI16x8S: begin I32x4ExtendLowI16x8S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtendHighI16x8S: begin I32x4ExtendHighI16x8S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtendLowI16x8U: begin I32x4ExtendLowI16x8U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtendHighI16x8U: begin I32x4ExtendHighI16x8U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Shl: begin I32x4Shl(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ShrS: begin I32x4ShrS(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ShrU: begin I32x4ShrU(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Add: begin I32x4Add(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Sub: begin I32x4Sub(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4Mul: begin I32x4Mul(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4MinS: begin I32x4MinS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4MinU: begin I32x4MinU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4MaxS: begin I32x4MaxS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4MaxU: begin I32x4MaxU(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4DotI16x8S: begin I32x4DotI16x8S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtmulLowI16x8S: begin I32x4ExtmulLowI16x8S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtmulHighI16x8S: begin I32x4ExtmulHighI16x8S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtmulLowI16x8U: begin I32x4ExtmulLowI16x8U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4ExtmulHighI16x8U: begin I32x4ExtmulHighI16x8U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Abs: begin I64x2Abs(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Neg: begin I64x2Neg(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2AllTrue: begin ValueSetU32(Reg[Ins^.Dest], I64x2AllTrue(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI64x2Bitmask: begin ValueSetU32(Reg[Ins^.Dest], I64x2Bitmask(VecAt(Reg, Ins^.A))); Inc(IP); end;
      iroI64x2ExtendLowI32x4S: begin I64x2ExtendLowI32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtendHighI32x4S: begin I64x2ExtendHighI32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtendLowI32x4U: begin I64x2ExtendLowI32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtendHighI32x4U: begin I64x2ExtendHighI32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Shl: begin I64x2Shl(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ShrS: begin I64x2ShrS(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ShrU: begin I64x2ShrU(VecAt(Reg, Ins^.A), Reg[Ins^.B].U32, VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Add: begin I64x2Add(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Sub: begin I64x2Sub(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Mul: begin I64x2Mul(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Eq: begin I64x2Eq(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2Ne: begin I64x2Ne(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2LtS: begin I64x2LtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2GtS: begin I64x2GtS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2LeS: begin I64x2LeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2GeS: begin I64x2GeS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtmulLowI32x4S: begin I64x2ExtmulLowI32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtmulHighI32x4S: begin I64x2ExtmulHighI32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtmulLowI32x4U: begin I64x2ExtmulLowI32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2ExtmulHighI32x4U: begin I64x2ExtmulHighI32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Abs: begin F32x4Abs(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Neg: begin F32x4Neg(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Sqrt: begin F32x4Sqrt(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Add: begin F32x4Add(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Sub: begin F32x4Sub(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Mul: begin F32x4Mul(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Div: begin F32x4Div(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Min: begin F32x4Min(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Max: begin F32x4Max(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Pmin: begin F32x4Pmin(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4Pmax: begin F32x4Pmax(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Abs: begin F64x2Abs(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Neg: begin F64x2Neg(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Sqrt: begin F64x2Sqrt(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Add: begin F64x2Add(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Sub: begin F64x2Sub(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Mul: begin F64x2Mul(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Div: begin F64x2Div(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Min: begin F64x2Min(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Max: begin F64x2Max(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Pmin: begin F64x2Pmin(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2Pmax: begin F64x2Pmax(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4TruncSatF32x4S: begin I32x4TruncSatF32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4TruncSatF32x4U: begin I32x4TruncSatF32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4ConvertI32x4S: begin F32x4ConvertI32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4ConvertI32x4U: begin F32x4ConvertI32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4TruncSatF64x2SZero: begin I32x4TruncSatF64x2SZero(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4TruncSatF64x2UZero: begin I32x4TruncSatF64x2UZero(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2ConvertLowI32x4S: begin F64x2ConvertLowI32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2ConvertLowI32x4U: begin F64x2ConvertLowI32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16RelaxedSwizzle: begin I8x16RelaxedSwizzle(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4RelaxedTruncF32x4S: begin I32x4RelaxedTruncF32x4S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4RelaxedTruncF32x4U: begin I32x4RelaxedTruncF32x4U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4RelaxedTruncF64x2S: begin I32x4RelaxedTruncF64x2S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4RelaxedTruncF64x2U: begin I32x4RelaxedTruncF64x2U(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4RelaxedMadd: begin F32x4RelaxedMadd(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4RelaxedNmadd: begin F32x4RelaxedNmadd(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2RelaxedMadd: begin F64x2RelaxedMadd(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2RelaxedNmadd: begin F64x2RelaxedNmadd(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI8x16RelaxedLaneselect: begin I8x16RelaxedLaneselect(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8RelaxedLaneselect: begin I16x8RelaxedLaneselect(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4RelaxedLaneselect: begin I32x4RelaxedLaneselect(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI64x2RelaxedLaneselect: begin I64x2RelaxedLaneselect(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4RelaxedMin: begin F32x4RelaxedMin(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF32x4RelaxedMax: begin F32x4RelaxedMax(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2RelaxedMin: begin F64x2RelaxedMin(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroF64x2RelaxedMax: begin F64x2RelaxedMax(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8RelaxedQ15mulrS: begin I16x8RelaxedQ15mulrS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI16x8RelaxedDotI8x16I7x16S: begin I16x8RelaxedDotI8x16I7x16S(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
      iroI32x4RelaxedDotI8x16I7x16AddS: begin I32x4RelaxedDotI8x16I7x16AddS(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, UInt32(Ins^.Imm)), VecAt(Reg, Ins^.Dest)); Inc(IP); end;

      { --- IR-only vector ops (simd-spec §2.4): the validator emits these
        so the interpreter never asks a register's width at run time ------ }
      iroMoveVec:
        begin VecAt(Reg, Ins^.Dest)^ := VecAt(Reg, Ins^.A)^; Inc(IP); end;
      iroSelectVec:
        begin
          { Condition register rides in Imm (ifkSrcRegImm); 16-byte copy. }
          if Reg[UInt32(Ins^.Imm)].I32 <> 0 then
            VecAt(Reg, Ins^.Dest)^ := VecAt(Reg, Ins^.A)^
          else
            VecAt(Reg, Ins^.Dest)^ := VecAt(Reg, Ins^.B)^;
          Inc(IP);
        end;
      iroGlobalGetVec:
        begin
          VecAt(Reg, Ins^.Dest)^ :=
            Store.Globals[Act^.Instance.GlobalAddrs[UInt32(Ins^.Imm)]].Vec;
          Inc(IP);
        end;
      iroGlobalSetVec:
        begin
          Store.Globals[Act^.Instance.GlobalAddrs[UInt32(Ins^.Imm)]].Vec :=
            VecAt(Reg, Ins^.A)^;
          Inc(IP);
        end;
      iroStructGetVec:
        begin
          IrUnpack(Ins^.Imm, U1, U2);
          Store.Heap.StructGetVec(Reg[Ins^.A].Ref, U2, VecAt(Reg, Ins^.Dest));
          Inc(IP);
        end;
      iroStructSetVec:
        begin
          IrUnpack(Ins^.Imm, U1, U2);
          Store.Heap.StructSetVec(Reg[Ins^.A].Ref, U2, VecAt(Reg, Ins^.B));
          Inc(IP);
        end;
      iroArrayGetVec:
        begin
          Store.Heap.ArrayGetVec(Reg[Ins^.A].Ref, Reg[Ins^.B].U32,
            VecAt(Reg, Ins^.Dest));
          Inc(IP);
        end;
      iroArraySetVec:
        begin
          Store.Heap.ArraySetVec(Reg[Ins^.Dest].Ref, Reg[Ins^.A].U32,
            VecAt(Reg, Ins^.B));
          Inc(IP);
        end;
      iroArrayFillVec:
        begin ExecArrayFillVec(ACtx, Act, Ins); Inc(IP); end;
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
    until used. Never grown or moved while a frame is live (interp-spec §1.1).
    Over-allocate 16 bytes and round the base up to a 16-byte boundary rather
    than trusting GetMem's alignment, so every even slot is 16-aligned for
    v128 (simd-spec §1.5). ValuesRaw keeps the real allocation for FreeMem. }
  Result^.ValuesRaw := GetMem(Result^.ValueCap * SizeOf(TWasmValue) + 16);
  Result^.Values := PWasmValue((NativeUInt(Result^.ValuesRaw) + 15)
    and not NativeUInt(15));
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
  if Ctx^.ValuesRaw <> nil then
    FreeMem(Ctx^.ValuesRaw);
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

{ Result SLOT count: a v128 result occupies two consecutive slots, every
  other result one. Counted through ResultRegs so an even-alignment pad
  between results is skipped rather than counted as a slot (simd-spec §1.6).
  This sizes the flat AResults array the runner reads, so it must equal the
  number of flat entries DoReturn writes. }
function ResultSlotCount(const AFn: PWasmIrFunction): UInt32;
var
  K: UInt32;
begin
  Result := 0;
  K := 0;
  while K < AFn^.ResultCount do
  begin
    if AFn^.RegTypes[AFn^.ResultRegs[K]].Kind = wvkVec then
      Inc(Result, 2)
    else
      Inc(Result);
    Inc(K);
  end;
end;

{ --- the shared tier-seam frame helpers (O-J2) --------------------------- }

function JitEnterFrame(const ACtx: PWasmInterpContext; const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue;
  const ARetKind: TWasmRetKind): PWasmValue;
var
  Inst: TWasmModuleInstance;
  Fn: PWasmIrFunction;
  Entry: PWasmActivation;
  Slots: PWasmValue;
begin
  Inst := AStore.Funcs[AFuncAddr].Instance;
  Fn := @Inst.Ir.Functions[AStore.Funcs[AFuncAddr].FuncIrIndex];

  { Exhaustion guard BEFORE any mutation (interp-spec §5.2 / jit-spec §5.1),
    against BOTH caps and the same threshold every frame push uses. }
  if (ACtx^.Depth >= ACtx^.DepthCap) or
    (ACtx^.ValueTop + Fn^.RegisterCount > ACtx^.ValueCap) then
    TrapNow(wtkStackExhausted);

  Entry := @ACtx^.Acts[ACtx^.Depth];
  Entry^.Fn := Fn;
  Entry^.Instance := Inst;
  Entry^.Base := ACtx^.ValueTop;
  Entry^.IP := 0;
  ACtx^.ValueTop := Entry^.Base + Fn^.RegisterCount;

  { GC-1: zero the whole register file — an unwritten ref slot reads null,
    numeric locals default 0. }
  Slots := Frame(ACtx^.Values, Entry^.Base);
  ValueZeroSlots(Slots, Fn^.RegisterCount);

  { Marshal AParams into the padded param registers. SEAM (simd-spec §1.6):
    AParams is a FLAT slot array in which a v128 param occupies TWO
    consecutive entries, low half first. ScatterParamsFlat places each param
    at its register (LocalRegs[k]) so the v128 even-alignment pad is honoured,
    the same translation the wasm->wasm and tail-call paths use. A scalar-only
    function walks 1:1. AParams may be nil for a no-parameter entry
    (ParamCount = 0 skips the loop). }
  ScatterParamsFlat(Fn, Slots, AParams);

  { Fix A: rtEntry for a genuine outermost entry, rtCompiledSeam for a nested
    tier-seam entry (a compiled body, or a cross-seam interpreted callee) — this
    is what makes the frame transparent-to or a boundary-for the unwind. }
  Entry^.RetKind := ARetKind;
  { RetCount is a SLOT count so a v128 result flows into two flat AResults
    slots (simd-spec §1.6); DoReturn's per-slot copy then needs no change. }
  Entry^.RetCount := ResultSlotCount(Fn);
  Entry^.RetDest := nil;
  Entry^.RetBase := 0;
  Entry^.EntryResults := AResults;

  { GC-1: push before the IP-0 safepoint (the body's first op may allocate). }
  PushGcFrame(ACtx, Entry, Fn, Entry^.Base);
  Inc(ACtx^.Depth);
  Result := Slots;
end;

procedure JitLeaveFrame(const ACtx: PWasmInterpContext);
begin
  { The compiled body wrote its result registers; DoReturn on an rtEntry
    frame marshals them into EntryResults and pops — the ONE result-marshal /
    pop implementation the interpreter's iroReturn also uses. }
  DoReturn(ACtx, @ACtx^.Acts[ACtx^.Depth - 1]);
end;

function JitPrepareDirectCall(const AStore: TWasmStore;
  const AFuncIdx: PtrUInt; const AArgs, AResults: PWasmValue;
  const AState: PWasmJitDirectCallState): Pointer; cdecl;
var
  Ctx: PWasmInterpContext;
  Inst: TWasmModuleInstance;
  Addr: TWasmFuncAddr;
  Fn: PWasmIrFunction;
begin
  Result := nil;
  Ctx := InterpContextFor(AStore);
  Inst := Ctx^.Acts[Ctx^.Depth - 1].Instance;
  Addr := Inst.FuncAddrs[UInt32(AFuncIdx)];
  if (AStore.Funcs[Addr].Kind <> wfkWasm) or
    (AStore.Funcs[Addr].CompiledDirectEntry = nil) then
    Exit;

  AState^.RegBase := JitEnterFrame(Ctx, AStore, Addr, AArgs, AResults,
    rtCaller);
  Fn := @AStore.Funcs[Addr].Instance.Ir.Functions[
    AStore.Funcs[Addr].FuncIrIndex];
  if Length(Fn^.Code) > 0 then
    AState^.IrBase := @Fn^.Code[0]
  else
    AState^.IrBase := nil;
  Result := AStore.Funcs[Addr].CompiledDirectEntry;
end;

procedure JitFinishDirectCall(const AStore: TWasmStore); cdecl;
var
  Ctx: PWasmInterpContext;
begin
  Ctx := InterpContextFor(AStore);
  { During execution rtCaller made the frame transparent to the outer native
    unwind barrier. No exception is live now, so select the existing flat
    result-marshalling branch immediately before the shared pop. }
  Ctx^.Acts[Ctx^.Depth - 1].RetKind := rtCompiledSeam;
  JitLeaveFrame(Ctx);
end;

function WasmJitFrameOffsets: TWasmJitFrameOffsets;
var
  C: TWasmInterpContext;
  A: TWasmActivation;
  G: TWasmGcFrame;
begin
  { Only field ADDRESSES are taken, so the uninitialised locals are not read. }
  Result.ValueSlotSize := SizeOf(TWasmValue);
  Result.CtxValues := PtrUInt(@C.Values) - PtrUInt(@C);
  Result.CtxValueTop := PtrUInt(@C.ValueTop) - PtrUInt(@C);
  Result.CtxValueCap := PtrUInt(@C.ValueCap) - PtrUInt(@C);
  Result.CtxDepth := PtrUInt(@C.Depth) - PtrUInt(@C);
  Result.ActStride := SizeOf(TWasmActivation);
  Result.ActBase := PtrUInt(@A.Base) - PtrUInt(@A);
  Result.GcFrameSlots := PtrUInt(@G.Slots) - PtrUInt(@G);
  Result.GcFrameRefRegBits := PtrUInt(@G.RefRegBits) - PtrUInt(@G);
  Result.GcFrameRegisterCount := PtrUInt(@G.RegisterCount) - PtrUInt(@G);
end;

{ FNV-1a hashing wraps modulo 2^64 by design, so overflow/range checks must be
  off for the multiply below (they are on project-wide via Shared.inc). }
{$push}{$Q-}{$R-}
function WasmAotAbiFingerprint(const AStore: TWasmStore): UInt64;
var
  H: UInt64;
  JO: TWasmJitOffsets;
  FO: TWasmJitFrameOffsets;

  { FNV-1a-64 fold of one 64-bit datum: enough to make an accidental ABI drift
    change the fingerprint deterministically (this is an identity guard, not a
    cryptographic one). }
  procedure Fold(const AValue: UInt64);
  var
    I: Integer;
    V: UInt64;
  begin
    V := AValue;
    for I := 0 to 7 do
    begin
      H := H xor (V and $FF);
      H := H * UInt64($00000100000001B3);
      V := V shr 8;
    end;
  end;

begin
  JO := WasmJitOffsets(AStore);
  FO := WasmJitFrameOffsets;
  H := UInt64($CBF29CE484222325);   { FNV-1a-64 offset basis }

  Fold(JO.StoreEpoch);
  Fold(JO.StoreEpochSnapshot);
  Fold(JO.StoreJitHelperTable);
  Fold(JO.FuncInstStride);
  Fold(JO.FuncKind);
  Fold(JO.FuncCompiledEntry);
  Fold(JO.FuncCompiledDirectEntry);
  Fold(JO.FuncCallCount);
  Fold(JO.MemInstStride);
  Fold(JO.MemBase);
  Fold(JO.MemByteSize);

  Fold(FO.ValueSlotSize);
  Fold(FO.CtxValues);
  Fold(FO.CtxValueTop);
  Fold(FO.CtxValueCap);
  Fold(FO.CtxDepth);
  Fold(FO.ActStride);
  Fold(FO.ActBase);
  Fold(FO.GcFrameSlots);
  Fold(FO.GcFrameRefRegBits);
  Fold(FO.GcFrameRegisterCount);

  Fold(SizeOf(TWasmIrInstr));
  Fold(SizeOf(TWasmValue));
  Fold(AOT_HELPER_COUNT);
  Fold(AOT_ABI_REVISION);

  Result := H;
end;
{$pop}

procedure InterpTierInvoke(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: PWasmInterpContext;
  SavedDepth, SavedTop: NativeUInt;
  RetKind: TWasmRetKind;
  AllowBounce: Boolean;
begin
  AStore.CheckThread;                     { ADR-0008 }
  Ctx := InterpContextFor(AStore);

  { Fix A: learn whether this entry is a nested tier seam (rtCompiledSeam) or a
    genuine outermost entry (rtEntry), and whether the backend loop drives it as
    a tail target that may bounce a cross-tier tail. Consume BOTH once, up front,
    so neither leaks past a host early-return. }
  RetKind := ConsumeJitSeamReentry;
  AllowBounce := ConsumeTierTailTarget;

  { Wasm float ops never trap: mask the FPU on whatever thread runs guest
    code (Wasm.Interp.Numeric masked only its init thread). }
  MaskFpuExceptions;

  { Cursor resync (interp-spec §5.3/§7.3). An empty GC chain means a genuine
    top level — either a fresh invoke or a prior trap whose unwind dropped
    the chain via Heap.ResetFrames, leaving Ctx cursors stale. A nested
    host->guest re-entry always has the outer frames on the chain, so its
    cursors are trusted.

    ADR-0006 / jit-spec §6 (Fix B): capture the epoch snapshot ONCE, HERE, at
    the genuine OUTERMOST guest entry — the empty-GC-chain case — and NOT on a
    nested re-entry. This is the ONE fix for a lost interrupt across the tier
    seam: a compiled caller reaches an interpreted callee through
    Arm64/X64CallInterpreted -> TierInvoke -> InterpTierInvoke, i.e. this
    function IS re-entered on a nested wasm->wasm call. Re-seeding there would
    reset the snapshot to the just-read (already-bumped) Store.Epoch, so a
    pre-call epoch bump would go UNOBSERVED inside the nested callee (its
    back-edge sees Epoch = Snapshot). The interpreter-only path keeps ONE
    shared EpochCache across a nested call (nested interp calls stay in the
    same Run and never re-enter here), so seeding only at the outermost entry
    is what makes both tiers observe the interrupt identically. Both tiers read
    this shared slot: Run seeds its EpochCache from it, and a compiled entry's
    prologue loads it into x22/its snapshot register. A top-level compiled
    entry (the JitInvokeCompiled dispatch below) is also covered because it too
    runs only after this outermost seed. }
  if AStore.Heap.CurrentFrame = nil then
  begin
    Ctx^.Depth := 0;
    Ctx^.ValueTop := 0;
    AStore.EpochSnapshot := AStore.Epoch;
  end;

  if AStore.Funcs[AFuncAddr].Kind = wfkHost then
  begin
    InvokeHostEntry(AStore, AFuncAddr, AParams, AResults);
    Exit;
  end;

  { O-J1 tier check at the top-level entry: if the JIT compiled this function,
    dispatch to it through the same flat seam an interpreted entry uses, so
    the params/results marshal identically. Assigned() first keeps the no-JIT
    case a single predicted-not-taken branch. }
  if Assigned(AStore.JitInvokeCompiled) and
    (AStore.Funcs[AFuncAddr].CompiledEntry <> nil) then
  begin
    { Propagate a nested seam through the fixed-signature hook so the backend
      marks the compiled frame rtCompiledSeam too (Fix A). }
    if RetKind = rtCompiledSeam then
      MarkJitSeamReentry;
    AStore.JitInvokeCompiled(AStore, AFuncAddr, AParams, AResults);
    Exit;
  end;

  { The compile-on-hot counter (O-J1): bumped on each interpreted entry so the
    JIT can decide to compile. Invisible without a JIT registered. }
  Inc(AStore.Funcs[AFuncAddr].CallCount);

  SavedDepth := Ctx^.Depth;
  SavedTop := Ctx^.ValueTop;

  { Build the entry frame through the SAME helper the JIT uses (O-J2), then
    run the interpreter loop over it. AllowBounce lets an entry-level cross-tier
    tail hand back to the backend loop (O(1), Fix A) — only ever set when the
    backend drives this as a tail target. }
  JitEnterFrame(Ctx, AStore, AFuncAddr, AParams, AResults, RetKind);

  Run(Ctx, SavedDepth, AllowBounce);

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
    on E: EWasmError do
    begin
      { Our own hierarchy — EWasmTrap and the staged-op EWasmError included
        (EWasmTrap is an EWasmError). Re-raise unchanged so a host, and the
        .wast runner, classify it exactly. }
      if Outermost then
      begin
        AStore.Heap.ResetFrames;
        ResetInterpContext(AStore);
      end;
      raise;
    end;
    on E: Exception do
    begin
      { Defense in depth (Track C Wave 6b, Bug 3): a NON-EWasm exception
        escaping guest execution is a guest-triggered RTL fault the
        interpreter failed to convert at its source — historically an
        EStackOverflow from the first-in-process guard fault (now fixed by
        the explicit memory check), or a stray EAccessViolation /
        EDivByZero / ERangeError. ADR-0009's whole point is that a guest
        fault surfaces as one catchable EWasmError, never as a raw RTL
        exception that escapes the trampoline and aborts an entire corpus
        file. Convert it to EWasmError so exactly one honest, catchable
        error reaches the host. It is deliberately NOT laundered into a
        specific EWasmTrap: the interpreter raises its own canonical traps
        at each fault site (out-of-bounds, divide-by-zero, exhaustion,
        ...), so anything reaching here is unexpected and must stay VISIBLE
        as an error rather than pass as a trap. }
      if Outermost then
      begin
        AStore.Heap.ResetFrames;
        ResetInterpContext(AStore);
      end;
      raise EWasmError.CreateFmt(
        'unexpected runtime fault in guest execution: %s (%s)',
        [E.Message, E.ClassName]);
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
