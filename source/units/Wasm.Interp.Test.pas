{ Unit suite for Wasm.Interp — Track E: the activation stack and the dispatch
  core, and the memory / table / reference / GC / host-call families.

  Every module is assembled byte by byte, pushed through the real decoder and
  validator to a TWasmIrModule, instantiated via Track D, wired to the
  interpreter with RegisterInterpreter, and invoked through InterpInvoke (the
  WasmInvoke trampoline), so a trap surfaces as a catchable EWasmTrap. Nothing
  is stubbed: results are read back exactly as a host would see them.

  Core-dispatch coverage: numeric compute end to end (add, a function with locals, a
  loop with a counter); if/else and block/br control; select; global get/set;
  direct calls with args and multiple results; call_indirect (hit and the
  three traps, in the confirmed order); a tail-recursive countdown of a
  million iterations returning in BOUNDED stack (proof of O(1) return_call);
  a deep NON-tail recursion trapping 'call stack exhausted'; unreachable;
  an epoch interrupt.

  Memory/table/reference/GC/host coverage: memory load/store round-trip through the chokepoint, load
  OOB (explicit-check path), size/grow, fill/copy, fill OOB, init + data.drop;
  table get/set/grow/size, get OOB, init/copy; ref.null/is_null/eq/as_non_null;
  struct round-trip incl. packed get_s/get_u and the null-structure trap; array
  round-trip, OOB, overlapping array.copy, array.new_data/new_elem; ref.test /
  ref.cast (hit / miss / null / cast failure); br_on_cast reference threading;
  i31 get_s/get_u and the null-i31 trap; a collection triggered MID-CONSTRUCTION
  (proves publish-first + RefRegBits rooting); host-call round-trip, a host trap
  propagating, host->guest re-entrancy; and the STAGED M7 extern/any conversion
  imprecision, pinned rather than hidden.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
program Wasm.Interp.Test;

{$I Shared.inc}
{ Host callbacks index the PWasmValue param/result slices directly. }
{$POINTERMATH ON}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator;

{ --- byte-assembly helpers ----------------------------------------------- }

function ULeb(const AValue: UInt32): TWasmBytes;
var
  Rest: UInt32;
  Count: Integer;
begin
  Result := nil;
  Rest := AValue;
  Count := 0;
  repeat
    SetLength(Result, Count + 1);
    if Rest < $80 then
      Result[Count] := Byte(Rest)
    else
      Result[Count] := Byte((Rest and $7F) or $80);
    Rest := Rest shr 7;
    Inc(Count);
  until Rest = 0;
end;

function BLit(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function Cat(const AParts: array of TWasmBytes): TWasmBytes;
var
  I, J, N: Integer;
begin
  N := 0;
  for I := 0 to High(AParts) do
    Inc(N, Length(AParts[I]));
  SetLength(Result, N);
  N := 0;
  for I := 0 to High(AParts) do
    for J := 0 to High(AParts[I]) do
    begin
      Result[N] := AParts[I][J];
      Inc(N);
    end;
end;

{ Length-prefixed vector: ULeb(count) ++ concat(items). }
function VecOf(const AItems: array of TWasmBytes): TWasmBytes;
var
  Body: TWasmBytes;
  I, J, N: Integer;
begin
  N := 0;
  for I := 0 to High(AItems) do
    Inc(N, Length(AItems[I]));
  SetLength(Body, N);
  N := 0;
  for I := 0 to High(AItems) do
    for J := 0 to High(AItems[I]) do
    begin
      Body[N] := AItems[I][J];
      Inc(N);
    end;
  Result := Cat([ULeb(UInt32(Length(AItems))), Body]);
end;

{ A section: id ++ ULeb(size) ++ body. }
function Sect(const AId: Byte; const ABody: TWasmBytes): TWasmBytes;
begin
  Result := Cat([BLit([AId]), ULeb(UInt32(Length(ABody))), ABody]);
end;

{ A code entry: ULeb(size) ++ body (body already carries local decls and the
  terminating 0x0B). }
function CodeEntry(const ABody: array of Byte): TWasmBytes;
var
  Body: TWasmBytes;
begin
  Body := BLit(ABody);
  Result := Cat([ULeb(UInt32(Length(Body))), Body]);
end;

const
  WASM_HEADER: array[0 .. 7] of Byte = ($00, $61, $73, $6D, $01, $00, $00, $00);

{ The bump host callback for the epoch test: the one documented cross-thread
  write, here reached synchronously from guest code (ADR-0006). }
procedure BumpEpochCallback(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  AStore.Epoch := AStore.Epoch + 1;
end;

type
  TInterpTests = class(TTestSuite)
  private
    FBytes: TWasmBytes;
    FModule: TWasmModule;
    FIr: TWasmIrModule;
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FImports: TWasmImports;
    FInstance: TWasmModuleInstance;

    procedure DecodeValidate(const ABytes: TWasmBytes);
    procedure DoInstantiate;
    function FuncAddr(const AName: string): TWasmFuncAddr;
    function Call1(const AName: string;
      const AParams: array of TWasmValue): TWasmValue;
    procedure ExpectTrap(const AName: string;
      const AParams: array of TWasmValue; const AExpectedPrefix: string);
    procedure ExpectError(const AName: string;
      const AParams: array of TWasmValue; const AExpectedSubstring: string);
    procedure ExpectException(const AName: string;
      const AParams: array of TWasmValue);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestAddFunction;
    procedure TestLocalsAndLoop;
    procedure TestIfElse;
    procedure TestBlockBr;
    procedure TestSelect;
    procedure TestGlobalGetSet;
    procedure TestDirectCallMultiResult;
    procedure TestCallIndirectHit;
    procedure TestCallIndirectUndefinedElement;
    procedure TestCallIndirectUninitializedElement;
    procedure TestCallIndirectTypeMismatch;
    procedure TestCallIndirectSubtypeDispatches;
    procedure TestCallIndirectUnrelatedTypeTraps;
    procedure TestTailCallBoundedStack;
    procedure TestDeepRecursionExhausts;
    procedure TestUnreachableTraps;
    procedure TestEpochInterrupt;
    procedure TestRefNullIsNull;
    { Memory / table / reference. }
    procedure TestMemoryRoundTrip;
    procedure TestMemoryLoadOutOfBounds;
    procedure TestMemoryGrowAndSize;
    procedure TestMemoryFillCopy;
    procedure TestMemoryFillOutOfBounds;
    procedure TestMemoryInitAndDataDrop;
    procedure TestTableGetSetGrow;
    procedure TestTableGetOutOfBounds;
    procedure TestTableInitCopy;
    procedure TestRefEqAsNonNull;
    { GC / host calls. }
    procedure TestStructRoundTrip;
    procedure TestStructNullTraps;
    procedure TestArrayRoundTrip;
    procedure TestVec128StructAndArrayRoundTrip;
    procedure TestArrayOutOfBounds;
    procedure TestArrayCopyOverlap;
    procedure TestArrayNewData;
    procedure TestArrayNewElem;
    procedure TestRefTestCast;
    procedure TestBrOnCastRefinement;
    procedure TestI31;
    procedure TestMidConstructionCollection;
    procedure TestHostCallRoundTrip;
    procedure TestHostCallTrapPropagates;
    procedure TestHostCallReentrancy;
    procedure TestM7ExternConvertCrossHierarchy;
    { SIMD / v128 (Track G). }
    procedure TestSimdSplatAddExtract;
    procedure TestSimdMemoryRoundTrip;
    procedure TestSimdLoadOutOfBounds;
    procedure TestSimdGlobalGetSet;
    procedure TestSimdParamResult;
    procedure TestSimdCallPaddedParams;
    procedure TestSimdReturnCallPaddedParams;
    procedure TestSimdCallVecFirstParamsRegression;
    procedure TestSimdEntryPaddedResults;
    { Exception handling (Track H). }
    procedure TestThrowCatchPayload;
    procedure TestCatchAll;
    procedure TestCatchRefDeliversExnref;
    procedure TestUncaughtThrowRaisesException;
    procedure TestThrowRefRethrowCaughtByOuter;
    procedure TestThrowRefNullTraps;
    procedure TestTagAddressMatching;
    procedure TestThrowUnwindsAcrossCall;
    procedure TestRefPayloadSurvivesCollection;
    { Baseline-JIT tier seam (O-J1, O-J2, O-J5). }
    procedure TestCallCountIncrementsPerInterpretedCall;
    procedure TestJitHookDispatchedAtEntry;
    procedure TestJitHookDispatchedForInternalCall;
    procedure TestJitEntryClearsSemanticSlots;
    procedure TestJitFrameOffsetsMatchLayout;
    procedure TestAotAbiFingerprintDeterministic;
  end;

{ --- host callbacks ------------------------------------------------------ }

var
  { Set by the re-entrancy test after instantiation so its host callback can
    reach the exported guest function it re-invokes on the same store. }
  GReenterStore: TWasmStore;
  GReenterDouble: TWasmFuncAddr;

  { The baseline-JIT seam tests register FakeJitAddHundred as the store's
    JitInvokeCompiled hook and flag a function "compiled" with a sentinel
    CompiledEntry. The hook records that it ran, which function it ran, and
    marshals a result the interpreter would NOT produce (param + 100), so the
    tests can prove the interpreter dispatched to the hook rather than running
    the body itself. }
  GJitHookCalls: Integer;
  GJitHookLastAddr: TWasmFuncAddr;

{ A stand-in for compiled code, satisfying TWasmJitInvokeProc: flat params in,
  flat results out (O-J1). It never touches the register file — it only proves
  the seam hands off at the flat boundary. }
procedure FakeJitAddHundred(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams: PWasmValue;
  const AResults: PWasmValue);
begin
  Inc(GJitHookCalls);
  GJitHookLastAddr := AFuncAddr;
  AResults[0] := MakeValueI32(AParams[0].I32 + 100);
end;

procedure HostAddCallback(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  { Marshal two i32 params in, one i32 result out. }
  AResults[0] := MakeValueI32(AParams[0].I32 + AParams[1].I32);
end;

procedure HostBoomCallback(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  { A host callback raising EWasmTrap traps the guest — it propagates out to
    the invocation's trampoline exactly as a wasm trap would. }
  raise EWasmTrap.Create('host boom');
end;

procedure HostReenterCallback(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Inner: array[0 .. 0] of TWasmValue;
begin
  { Host -> guest re-entrancy: invoke an export on the SAME store through the
    trampoline. The nested activation region sits above the outer frames. }
  Inner[0] := AParams[0];
  InterpInvoke(GReenterStore, GReenterDouble, @Inner[0], @AResults[0]);
end;

{ --- fixture ------------------------------------------------------------- }

procedure TInterpTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FIr := nil;
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  FInstance := nil;
  FImports.Funcs := nil;
  FImports.Tables := nil;
  FImports.Mems := nil;
  FImports.Globals := nil;
  FImports.Tags := nil;
  { Test-scale reservations: small enough to be cheap per store, large enough
    for every module here. A test may shrink them further before instantiate. }
  WasmInterpValueSlots := 1 shl 16;
  WasmInterpMaxDepth := 256;
end;

procedure TInterpTests.AfterEach;
begin
  { The store owns the instance, which borrows the IR, which borrows the
    buffer — so free in that order. }
  FreeAndNil(FStore);
  FreeAndNil(FEngine);
  FreeAndNil(FIr);
  FreeAndNil(FModule);
end;

procedure TInterpTests.DecodeValidate(const ABytes: TWasmBytes);
begin
  FBytes := ABytes;
  DecodeModule(FBytes, FModule);
  FreeAndNil(FIr);
  FIr := ValidateModule(FModule, FBytes);
end;

procedure TInterpTests.DoInstantiate;
begin
  FInstance := InstantiateModule(FStore, FIr, @FBytes[0],
    NativeUInt(Length(FBytes)), FImports);
  RegisterInterpreter(FStore);
end;

function TInterpTests.FuncAddr(const AName: string): TWasmFuncAddr;
var
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  if not FInstance.FindExport(AName, Kind, Addr) then
    raise EWasmError.CreateFmt('no export named %s', [AName]);
  Result := Addr;
end;

{ Invoke an export with one result, returning it. }
function TInterpTests.Call1(const AName: string;
  const AParams: array of TWasmValue): TWasmValue;
var
  ParamArr: array of TWasmValue;
  ResArr: array of TWasmValue;
  ParamPtr, ResPtr: PWasmValue;
  I: Integer;
begin
  SetLength(ParamArr, Length(AParams));
  for I := 0 to High(AParams) do
    ParamArr[I] := AParams[I];
  SetLength(ResArr, 1);
  if Length(ParamArr) > 0 then
    ParamPtr := @ParamArr[0]
  else
    ParamPtr := nil;
  ResPtr := @ResArr[0];
  InterpInvoke(FStore, FuncAddr(AName), ParamPtr, ResPtr);
  Result := ResArr[0];
end;

procedure TInterpTests.ExpectTrap(const AName: string;
  const AParams: array of TWasmValue; const AExpectedPrefix: string);
var
  ParamArr: array of TWasmValue;
  ParamPtr: PWasmValue;
  I: Integer;
  Cls, Msg: string;
begin
  SetLength(ParamArr, Length(AParams));
  for I := 0 to High(AParams) do
    ParamArr[I] := AParams[I];
  if Length(ParamArr) > 0 then
    ParamPtr := @ParamArr[0]
  else
    ParamPtr := nil;

  Cls := 'NO-TRAP';
  Msg := '';
  try
    { A trap fires before any clean return, so no result buffer is needed. }
    InterpInvoke(FStore, FuncAddr(AName), ParamPtr, nil);
  except
    on E: EWasmTrap do
    begin Cls := 'trap'; Msg := E.Message; end;
    on E: EWasmError do
    begin Cls := 'error'; Msg := E.Message; end;
  end;

  { Class must be a guest trap; message must start with the canonical prefix
    (the .wast runner's prefix rule — the uninitialized-element form carries a
    trailing index). }
  Expect<string>('class=' + Cls).ToBe('class=trap');
  Expect<string>('prefix=' + Copy(Msg, 1, Length(AExpectedPrefix)))
    .ToBe('prefix=' + AExpectedPrefix);
end;

procedure TInterpTests.ExpectError(const AName: string;
  const AParams: array of TWasmValue; const AExpectedSubstring: string);
var
  ParamPtr: PWasmValue;
  Cls, Msg: string;
begin
  { The placeholder module under test takes no parameters. }
  ParamPtr := nil;

  Cls := 'NO-ERROR';
  Msg := '';
  try
    InterpInvoke(FStore, FuncAddr(AName), ParamPtr, nil);
  except
    on E: EWasmTrap do
    begin Cls := 'trap'; Msg := E.Message; end;
    on E: EWasmError do
    begin Cls := 'error'; Msg := E.Message; end;
  end;

  Expect<string>('class=' + Cls).ToBe('class=error');
  Expect<Boolean>(Pos(AExpectedSubstring, Msg) > 0).ToBe(True);
end;

{ --- numeric: add -------------------------------------------------------- }

procedure TInterpTests.TestAddFunction;
begin
  { (func $add (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
    exported "add". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $02, $7F, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$03, $61, $64, $64, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $20, $00, $20, $01, $6A, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('add', [MakeValueI32(40), MakeValueI32(2)]).I32).ToBe(42);
end;

{ --- locals + block + loop + br/br_if ------------------------------------ }

procedure TInterpTests.TestLocalsAndLoop;
begin
  { (func $sumto (param i32) (result i32) (local i32 i32)   ; sum, i
      local.get 0 local.set 2
      block (loop
        local.get 2 i32.eqz br_if 1
        local.get 1 local.get 2 i32.add local.set 1
        local.get 2 i32.const 1 i32.sub local.set 2
        br 0))
      local.get 1) exported "sumto". Sums 1..n. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$05, $73, $75, $6D, $74, $6F, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $01, $02, $7F,                { locals: 2 x i32 }
      $20, $00, $21, $02,           { i := p }
      $02, $40,                     { block }
      $03, $40,                     { loop }
      $20, $02, $45, $0D, $01,      { if i==0 br 1 (exit block) }
      $20, $01, $20, $02, $6A, $21, $01,  { sum += i }
      $20, $02, $41, $01, $6B, $21, $02,  { i -= 1 }
      $0C, $00,                     { br 0 (loop) }
      $0B,                          { end loop }
      $0B,                          { end block }
      $20, $01,                     { local.get sum }
      $0B])]))                      { end func }
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('sumto', [MakeValueI32(5)]).I32).ToBe(15);
  Expect<Int32>(Call1('sumto', [MakeValueI32(0)]).I32).ToBe(0);
  Expect<Int32>(Call1('sumto', [MakeValueI32(100)]).I32).ToBe(5050);
end;

{ --- if / else ----------------------------------------------------------- }

procedure TInterpTests.TestIfElse;
begin
  { (func $absval (param i32) (result i32)
      local.get 0 i32.const 0 i32.lt_s
      if (result i32) i32.const 0 local.get 0 i32.sub
      else local.get 0 end) exported "absval". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$06, $61, $62, $73, $76, $61, $6C, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $20, $00, $41, $00, $48,      { p < 0 }
      $04, $7F,                     { if (result i32) }
      $41, $00, $20, $00, $6B,      { 0 - p }
      $05,                          { else }
      $20, $00,                     { p }
      $0B,                          { end if }
      $0B])]))                      { end func }
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('absval', [MakeValueI32(-5)]).I32).ToBe(5);
  Expect<Int32>(Call1('absval', [MakeValueI32(7)]).I32).ToBe(7);
end;

{ --- block + br (early exit carrying a value) ---------------------------- }

procedure TInterpTests.TestBlockBr;
begin
  { (func $pick (param i32) (result i32)
      block (result i32)
        i32.const 111
        local.get 0 br_if 0     ; if p!=0 exit block with 111
        drop i32.const 222      ; else 222
      end) exported "pick". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$04, $70, $69, $63, $6B, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $02, $7F,                     { block (result i32) }
      $41, $EF, $00,                { i32.const 111 (SLEB: 0x6F alone is -17) }
      $20, $00, $0D, $00,           { br_if 0 (value 111 stays) }
      $1A,                          { drop }
      $41, $DE, $01,                { i32.const 222 }
      $0B,                          { end block }
      $0B])]))                      { end func }
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('pick', [MakeValueI32(1)]).I32).ToBe(111);
  Expect<Int32>(Call1('pick', [MakeValueI32(0)]).I32).ToBe(222);
end;

{ --- select -------------------------------------------------------------- }

procedure TInterpTests.TestSelect;
begin
  { (func $sel (param i32 i32 i32) (result i32)
      local.get 0 local.get 1 local.get 2 select) exported "sel". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $03, $7F, $7F, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$03, $73, $65, $6C, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00, $20, $00, $20, $01, $20, $02, $1B, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('sel',
    [MakeValueI32(11), MakeValueI32(22), MakeValueI32(1)]).I32).ToBe(11);
  Expect<Int32>(Call1('sel',
    [MakeValueI32(11), MakeValueI32(22), MakeValueI32(0)]).I32).ToBe(22);
end;

{ --- global.get / global.set --------------------------------------------- }

procedure TInterpTests.TestGlobalGetSet;
begin
  { (global (mut i32) (i32.const 7))
    (func $gs (param i32) (result i32)
      local.get 0 global.set 0 global.get 0) exported "gs". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(6, VecOf([BLit([$7F, $01, $41, $07, $0B])])),
    Sect(7, VecOf([BLit([$02, $67, $73, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00, $20, $00, $24, $00, $23, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('gs', [MakeValueI32(99)]).I32).ToBe(99);
  { The store cell now holds the written value. }
  Expect<Int32>(Call1('gs', [MakeValueI32(-3)]).I32).ToBe(-3);
end;

{ --- direct call with args and TWO results ------------------------------- }

procedure TInterpTests.TestDirectCallMultiResult;
begin
  { type0 = (i32 i32)->(i32 i32), type1 = (i32 i32)->(i32)
    func0 $swap (type0) local.get 1 local.get 0
    func1 $caller (type1) local.get 0 local.get 1 call 0 i32.sub
    exported "caller". caller(10,3): swap->(3,10); 3-10 = -7. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $02, $7F, $7F, $02, $7F, $7F]),
      BLit([$60, $02, $7F, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([BLit([$06, $63, $61, $6C, $6C, $65, $72, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $01, $20, $00, $0B]),
      CodeEntry([$00, $20, $00, $20, $01, $10, $00, $6B, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('caller',
    [MakeValueI32(10), MakeValueI32(3)]).I32).ToBe(-7);
end;

{ --- call_indirect: build once, reuse across the hit and trap cases ------ }

function BuildCallIndirectModule: TWasmBytes;
begin
  { type0 (i32)->(i32), type1 ()->(i32), type2 (i32 i32)->(i32)
    func0 $addone (type0) local.get 0 i32.const 1 i32.add
    func1 $wrongsig (type1) i32.const 99
    func2 $callit (type2) local.get 1 local.get 0 call_indirect (type0)
    table 3 funcref; elem[0]=addone, elem[2]=wrongsig (elem[1] left null).
    exported "callit". Invoke callit(index, arg). }
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $01, $7F]),
      BLit([$60, $00, $01, $7F]),
      BLit([$60, $02, $7F, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$02])])),
    Sect(4, VecOf([BLit([$70, $00, $03])])),
    Sect(7, VecOf([BLit([$06, $63, $61, $6C, $6C, $69, $74, $00, $02])])),
    Sect(9, VecOf([
      BLit([$00, $41, $00, $0B, $01, $00]),
      BLit([$00, $41, $02, $0B, $01, $01])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $41, $01, $6A, $0B]),
      CodeEntry([$00, $41, $63, $0B]),
      CodeEntry([$00, $20, $01, $20, $00, $11, $00, $00, $0B])]))
  ]);
end;

procedure TInterpTests.TestCallIndirectHit;
begin
  DecodeValidate(BuildCallIndirectModule);
  DoInstantiate;
  { callit(index=0, arg=41) -> addone(41) = 42. }
  Expect<Int32>(Call1('callit',
    [MakeValueI32(0), MakeValueI32(41)]).I32).ToBe(42);
end;

procedure TInterpTests.TestCallIndirectUndefinedElement;
begin
  DecodeValidate(BuildCallIndirectModule);
  DoInstantiate;
  { index 5 is past the table (size 3): bounds trap fires first. }
  ExpectTrap('callit', [MakeValueI32(5), MakeValueI32(0)], 'undefined element');
end;

procedure TInterpTests.TestCallIndirectUninitializedElement;
begin
  DecodeValidate(BuildCallIndirectModule);
  DoInstantiate;
  { index 1 is in bounds but null. }
  ExpectTrap('callit', [MakeValueI32(1), MakeValueI32(0)],
    'uninitialized element');
end;

procedure TInterpTests.TestCallIndirectTypeMismatch;
begin
  DecodeValidate(BuildCallIndirectModule);
  DoInstantiate;
  { index 2 is wrongsig (type1); call_indirect expects type0. }
  ExpectTrap('callit', [MakeValueI32(2), MakeValueI32(0)],
    'indirect call type mismatch');
end;

{ Regression for call_indirect SUBTYPE dispatch (wasm 3.0 match-deftype, not
  engine-id equality). Types:
    type0 = sub (func ()->i32)          ; non-final supertype (call-site type)
    type1 = sub final $0 (func ()->i32) ; a DECLARED proper subtype of type0
    type2 = func (i32)->i32             ; the caller "callit"
    type3 = func ()->i64                ; genuinely unrelated
  func0:type1 sits at table[0], func1:type3 at table[1]. "callit" runs
  call_indirect (type0) on the param index. type1 and type0 are DISTINCT engine
  ids, so the old equality check trapped the subtype at index 0 — this module
  proves index 0 DISPATCHES (subtype) while index 1 still traps (unrelated). }
function BuildCallIndirectSubtypeModule: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$50, $00, $60, $00, $01, $7F]),        { type0: sub (func ->i32) }
      BLit([$4F, $01, $00, $60, $00, $01, $7F]),   { type1: sub final $0 (func ->i32) }
      BLit([$60, $01, $7F, $01, $7F]),             { type2: (i32)->i32 }
      BLit([$60, $00, $01, $7E])])),               { type3: ()->i64 }
    Sect(3, VecOf([BLit([$01]), BLit([$03]), BLit([$02])])),
    Sect(4, VecOf([BLit([$70, $00, $03])])),
    Sect(7, VecOf([BLit([$06, $63, $61, $6C, $6C, $69, $74, $00, $02])])),
    Sect(9, VecOf([
      BLit([$00, $41, $00, $0B, $01, $00]),        { table[0] = func0 (type1) }
      BLit([$00, $41, $01, $0B, $01, $01])])),      { table[1] = func1 (type3) }
    Sect(10, VecOf([
      CodeEntry([$00, $41, $2A, $0B]),             { func0 ()->i32: i32.const 42 }
      CodeEntry([$00, $42, $00, $0B]),             { func1 ()->i64: i64.const 0 }
      CodeEntry([$00, $20, $00, $11, $00, $00, $0B])]))  { callit: call_indirect(type0) }
  ]);
end;

procedure TInterpTests.TestCallIndirectSubtypeDispatches;
begin
  DecodeValidate(BuildCallIndirectSubtypeModule);
  DoInstantiate;
  { table[0] holds func0 whose type1 is a proper subtype of the call-site
    type0. Subtyping must DISPATCH (the old equality check wrongly trapped). }
  Expect<Int32>(Call1('callit', [MakeValueI32(0)]).I32).ToBe(42);
end;

procedure TInterpTests.TestCallIndirectUnrelatedTypeTraps;
begin
  DecodeValidate(BuildCallIndirectSubtypeModule);
  DoInstantiate;
  { table[1] holds func1 whose type3 (()->i64) is not a subtype of type0:
    still 'indirect call type mismatch'. }
  ExpectTrap('callit', [MakeValueI32(1)], 'indirect call type mismatch');
end;

{ --- tail-recursive countdown: a million iterations in bounded stack ----- }

procedure TInterpTests.TestTailCallBoundedStack;
begin
  { (func $count (param i32) (result i32)
      local.get 0 i32.eqz
      if (result i32) i32.const 0
      else local.get 0 i32.const 1 i32.sub return_call 0 end)
    exported "count". A non-tail interpreter would blow the Pascal stack at
    a million frames; return_call replaces the frame in place, so Depth
    stays at one. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$05, $63, $6F, $75, $6E, $74, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $20, $00, $45,                { p == 0 }
      $04, $7F,                     { if (result i32) }
      $41, $00,                     { 0 }
      $05,                          { else }
      $20, $00, $41, $01, $6B,      { p - 1 }
      $12, $00,                     { return_call 0 }
      $0B,                          { end if }
      $0B])]))                      { end func }
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('count', [MakeValueI32(1000000)]).I32).ToBe(0);
end;

{ --- deep NON-tail recursion trips the depth cap ------------------------- }

procedure TInterpTests.TestDeepRecursionExhausts;
begin
  { Same shape as the countdown but with a plain (non-tail) call, so every
    call pushes a frame. A small depth cap makes 'call stack exhausted' fire
    deterministically. }
  WasmInterpMaxDepth := 64;
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$03, $72, $65, $63, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $20, $00, $45,
      $04, $7F,
      $41, $00,
      $05,
      $20, $00, $41, $01, $6B,
      $10, $00,                     { call 0 (non-tail) }
      $0B,
      $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('rec', [MakeValueI32(1000000)], 'call stack exhausted');
end;

{ --- unreachable --------------------------------------------------------- }

procedure TInterpTests.TestUnreachableTraps;
begin
  { (func $boom unreachable) exported "boom". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $00])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$04, $62, $6F, $6F, $6D, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $00, $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('boom', [], 'unreachable');
end;

{ --- epoch interrupt ----------------------------------------------------- }

procedure TInterpTests.TestEpochInterrupt;
var
  Canon, TypeIdx: TWasmEngineTypeIds;
  HostAddr: TWasmFuncAddr;
begin
  { import "e"."bump" (func) ; func 0
    (func $run (loop (call 0) (br 0))) ; func 1
    exported "run". The host bump increments Store.Epoch; the loop back-edge
    carries IR_JUMP_SAFEPOINT, so the changed epoch traps 'interrupt'. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $00])])),
    Sect(2, VecOf([BLit([$01, $65, $04, $62, $75, $6D, $70, $00, $00])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$03, $72, $75, $6E, $00, $01])])),
    Sect(10, VecOf([CodeEntry([
      $00, $03, $40, $10, $00, $0C, $00, $0B, $0B])]))
  ]));

  { Supply the host import: its engine type id must be the module's type 0. }
  FEngine.InternModule(FIr, Canon, TypeIdx);
  HostAddr := FStore.AddHostFunc(TypeIdx[0], @BumpEpochCallback, nil);
  SetLength(FImports.Funcs, 1);
  FImports.Funcs[0] := HostAddr;

  DoInstantiate;
  ExpectTrap('run', [], 'interrupt');
end;

{ --- ref.null / ref.is_null ---------------------------------------------- }

procedure TInterpTests.TestRefNullIsNull;
begin
  { (func $p (result i32) ref.null func ref.is_null) exported "p" -> 1. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$01, $70, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $D0, $70, $D1, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('p', []).I32).ToBe(1);
end;

{ --- memory: store/load round trip + narrow load ------------------------- }

procedure TInterpTests.TestMemoryRoundTrip;
begin
  { (memory 1)
    (func $rw (param i32 i32) (result i32)   ; addr, val
      local.get 0 local.get 1 i32.store local.get 0 i32.load)
    (func $rb8 (param i32) (result i32) local.get 0 i32.load8_u) }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $02, $7F, $7F, $01, $7F]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([
      BLit([$02, $72, $77, $00, $00]),
      BLit([$03, $72, $62, $38, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $20, $01, $36, $02, $00,
        $20, $00, $28, $02, $00, $0B]),
      CodeEntry([$00, $20, $00, $2D, $00, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('rw',
    [MakeValueI32(4), MakeValueI32($12345678)]).I32).ToBe($12345678);
  { The low byte of the little-endian store is at the base address. }
  Expect<Int32>(Call1('rb8', [MakeValueI32(4)]).I32).ToBe($78);
end;

procedure TInterpTests.TestMemoryLoadOutOfBounds;
begin
  { i32.load with a 2 GiB static offset. On this 64-bit POSIX host the memory
    uses guard pages, and an offset past the guard forces the chokepoint's
    explicit full-precision check — so the trap is a deterministic TrapNow
    (`out of bounds memory access`) rather than an in-process MMU fault, whose
    end-to-end path Track D deliberately exercises only in a forked child. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([BLit([$04, $6C, $6F, $61, $64, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $20, $00,
      $28, $02, $80, $80, $80, $80, $08, $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('load', [MakeValueI32(0)], 'out of bounds memory access');
end;

procedure TInterpTests.TestMemoryGrowAndSize;
begin
  { (func $size (result i32) memory.size)
    (func $grow (param i32) (result i32) local.get 0 memory.grow) }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $01, $7F]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([
      BLit([$04, $73, $69, $7A, $65, $00, $00]),
      BLit([$04, $67, $72, $6F, $77, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$00, $3F, $00, $0B]),
      CodeEntry([$00, $20, $00, $40, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('size', []).I32).ToBe(1);
  { grow returns the PREVIOUS size (1), then size reports 3. }
  Expect<Int32>(Call1('grow', [MakeValueI32(2)]).I32).ToBe(1);
  Expect<Int32>(Call1('size', []).I32).ToBe(3);
end;

procedure TInterpTests.TestMemoryFillCopy;
begin
  { (func $fillread (param i32) (result i32)
      i32.const 0 i32.const 0xAB i32.const 4 memory.fill
      local.get 0 i32.load8_u)
    (func $copytest (param i32) (result i32)
      i32.const 0 i32.const 0xCD i32.const 4 memory.fill
      i32.const 8 i32.const 0 i32.const 4 memory.copy
      local.get 0 i32.load8_u) }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([
      BLit([$08, $66, $69, $6C, $6C, $72, $65, $61, $64, $00, $00]),
      BLit([$04, $63, $6F, $70, $79, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$00, $41, $00, $41, $AB, $01, $41, $04, $FC, $0B, $00,
        $20, $00, $2D, $00, $00, $0B]),
      CodeEntry([$00, $41, $00, $41, $CD, $01, $41, $04, $FC, $0B, $00,
        $41, $08, $41, $00, $41, $04, $FC, $0A, $00, $00,
        $20, $00, $2D, $00, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('fillread', [MakeValueI32(2)]).I32).ToBe($AB);
  { mem[8..12) was copied from mem[0..4), which fill set to 0xCD. }
  Expect<Int32>(Call1('copy', [MakeValueI32(9)]).I32).ToBe($CD);
end;

procedure TInterpTests.TestMemoryFillOutOfBounds;
begin
  { fill starting at 100000 (past one 64 KiB page) traps. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $00])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([BLit([$05, $66, $6F, $6F, $6F, $62, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00,
      $41, $A0, $8D, $06, $41, $00, $41, $04, $FC, $0B, $00, $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('fooob', [], 'out of bounds memory access');
end;

procedure TInterpTests.TestMemoryInitAndDataDrop;
begin
  { passive data seg 0 = [0xDE, 0xAD]
    (func $initread (param i32) (result i32)
      i32.const 0 i32.const 0 i32.const 2 memory.init 0 local.get 0 i32.load8_u)
    (func $drop data.drop 0)
    (func $initoob i32.const 0 i32.const 0 i32.const 2 memory.init 0)
    Section order puts the DataCount section (id 12) before Code. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $01, $7F]),
      BLit([$60, $00, $00])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$01])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([
      BLit([$08, $69, $6E, $69, $74, $72, $65, $61, $64, $00, $00]),
      BLit([$04, $64, $72, $6F, $70, $00, $01]),
      BLit([$07, $69, $6E, $69, $74, $6F, $6F, $62, $00, $02])])),
    Sect(12, BLit([$01])),
    Sect(10, VecOf([
      CodeEntry([$00, $41, $00, $41, $00, $41, $02, $FC, $08, $00, $00,
        $20, $00, $2D, $00, $00, $0B]),
      CodeEntry([$00, $FC, $09, $00, $0B]),
      CodeEntry([$00, $41, $00, $41, $00, $41, $02, $FC, $08, $00, $00, $0B])])),
    Sect(11, VecOf([BLit([$01, $02, $DE, $AD])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('initread', [MakeValueI32(0)]).I32).ToBe($DE);
  Expect<Int32>(Call1('initread', [MakeValueI32(1)]).I32).ToBe($AD);
  { Drop empties the segment; a subsequent non-empty init traps. }
  Call1('drop', []);
  ExpectTrap('initoob', [], 'out of bounds memory access');
end;

{ --- table: get/set/grow, bounds, copy/init ------------------------------ }

procedure TInterpTests.TestTableGetSetGrow;
begin
  { (func $f) exported (declares it for ref.func)
    (func $setget (result i32)
      i32.const 0 ref.func 0 table.set 0
      i32.const 0 table.get 0 ref.is_null)          ; -> 0 (non-null)
    (func $grow (param i32) (result i32)
      ref.null func local.get 0 table.grow 0)        ; old size
    (func $size (result i32) table.size 0)
    (table 3 funcref) }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$02]), BLit([$01])])),
    Sect(4, VecOf([BLit([$70, $00, $03])])),
    Sect(7, VecOf([
      BLit([$01, $66, $00, $00]),
      BLit([$06, $73, $65, $74, $67, $65, $74, $00, $01]),
      BLit([$04, $67, $72, $6F, $77, $00, $02]),
      BLit([$04, $73, $69, $7A, $65, $00, $03])])),
    Sect(10, VecOf([
      CodeEntry([$00, $0B]),
      CodeEntry([$00, $41, $00, $D2, $00, $26, $00,
        $41, $00, $25, $00, $D1, $0B]),
      CodeEntry([$00, $D0, $70, $20, $00, $FC, $0F, $00, $0B]),
      CodeEntry([$00, $FC, $10, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('setget', []).I32).ToBe(0);
  Expect<Int32>(Call1('size', []).I32).ToBe(3);
  Expect<Int32>(Call1('grow', [MakeValueI32(2)]).I32).ToBe(3);
  Expect<Int32>(Call1('size', []).I32).ToBe(5);
end;

procedure TInterpTests.TestTableGetOutOfBounds;
begin
  { (func $g (param i32) (result i32) local.get 0 table.get 0 ref.is_null) }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(4, VecOf([BLit([$70, $00, $03])])),
    Sect(7, VecOf([BLit([$01, $67, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $20, $00, $25, $00, $D1, $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('g', [MakeValueI32(9)], 'out of bounds table access');
end;

procedure TInterpTests.TestTableInitCopy;
begin
  { passive elem seg 0 = [f, f] funcref
    (func $ic (param i32) (result i32)
      i32.const 0 i32.const 0 i32.const 2 table.init 0 0
      i32.const 2 i32.const 0 i32.const 2 table.copy 0 0
      local.get 0 table.get 0 ref.is_null)
    (func $ed elem.drop 0)
    (table 5 funcref) }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $01, $7F, $01, $7F]),
      BLit([$60, $00, $00])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$02])])),
    Sect(4, VecOf([BLit([$70, $00, $05])])),
    Sect(7, VecOf([
      BLit([$01, $66, $00, $00]),
      BLit([$02, $69, $63, $00, $01]),
      BLit([$02, $65, $64, $00, $02])])),
    Sect(9, VecOf([BLit([$01, $00, $02, $00, $00])])),
    Sect(10, VecOf([
      CodeEntry([$00, $0B]),
      CodeEntry([$00,
        $41, $00, $41, $00, $41, $02, $FC, $0C, $00, $00,
        $41, $02, $41, $00, $41, $02, $FC, $0E, $00, $00,
        $20, $00, $25, $00, $D1, $0B]),
      CodeEntry([$00, $FC, $0D, $00, $0B])]))
  ]));
  DoInstantiate;
  { init sets table[0..2) = f; copy sets table[2..4) = table[0..2) = f. }
  Expect<Int32>(Call1('ic', [MakeValueI32(0)]).I32).ToBe(0);
  Expect<Int32>(Call1('ic', [MakeValueI32(3)]).I32).ToBe(0);
  { index 4 was never written: still null. }
  Expect<Int32>(Call1('ic', [MakeValueI32(4)]).I32).ToBe(1);
end;

procedure TInterpTests.TestRefEqAsNonNull;
begin
  { ref.eq needs eqref operands, so use i31 references for it.
    (func $f) exported (declares func 0 for ref.func)
    (func $eqself (result i32) ref.i31 5 ref.i31 5 ref.eq)       ; -> 1
    (func $eqnull (result i32) ref.i31 5 ref.null eq ref.eq)     ; -> 0
    (func $nn (result i32) ref.func 0 ref.as_non_null ref.is_null) ; -> 0
    (func $nntrap ref.null func ref.as_non_null drop)  the last one traps }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$01]),
      BLit([$01]), BLit([$00])])),
    Sect(7, VecOf([
      BLit([$01, $66, $00, $00]),
      BLit([$06, $65, $71, $73, $65, $6C, $66, $00, $01]),
      BLit([$06, $65, $71, $6E, $75, $6C, $6C, $00, $02]),
      BLit([$02, $6E, $6E, $00, $03]),
      BLit([$06, $6E, $6E, $74, $72, $61, $70, $00, $04])])),
    Sect(10, VecOf([
      CodeEntry([$00, $0B]),
      CodeEntry([$00, $41, $05, $FB, $1C, $41, $05, $FB, $1C, $D3, $0B]),
      CodeEntry([$00, $41, $05, $FB, $1C, $D0, $6D, $D3, $0B]),
      CodeEntry([$00, $D2, $00, $D4, $D1, $0B]),
      CodeEntry([$00, $D0, $70, $D4, $1A, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('eqself', []).I32).ToBe(1);
  Expect<Int32>(Call1('eqnull', []).I32).ToBe(0);
  Expect<Int32>(Call1('nn', []).I32).ToBe(0);
  ExpectTrap('nntrap', [], 'null reference');
end;

{ --- GC: struct round trip incl. packed get_s / get_u -------------------- }

procedure TInterpTests.TestStructRoundTrip;
begin
  { type0 = (struct (field (mut i32)) (field (mut i8)))
    $roundtrip (param i32 i32)(result i32) struct.new 0; struct.get 0 0
    $get_s / $get_u read the packed i8 field 1 with sign / zero extension
    $setget mutates field 0 through struct.set. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $02, $7F, $01, $78, $01]),
      BLit([$60, $02, $7F, $7F, $01, $7F]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$01]), BLit([$01]), BLit([$01]), BLit([$02])])),
    Sect(7, VecOf([
      BLit([$02, $72, $74, $00, $00]),
      BLit([$02, $67, $73, $00, $01]),
      BLit([$02, $67, $75, $00, $02]),
      BLit([$02, $73, $67, $00, $03])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $20, $01, $FB, $00, $00, $FB, $02, $00, $00, $0B]),
      CodeEntry([$00, $20, $00, $20, $01, $FB, $00, $00, $FB, $03, $00, $01, $0B]),
      CodeEntry([$00, $20, $00, $20, $01, $FB, $00, $00, $FB, $04, $00, $01, $0B]),
      CodeEntry([$01, $01, $63, $00,
        $41, $00, $41, $00, $FB, $00, $00, $21, $01,
        $20, $01, $20, $00, $FB, $05, $00, $00,
        $20, $01, $FB, $02, $00, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('rt', [MakeValueI32(42), MakeValueI32(7)]).I32).ToBe(42);
  { field 1 is i8: 200 truncates to 0xC8; get_s sign-extends to -56. }
  Expect<Int32>(Call1('gs', [MakeValueI32(0), MakeValueI32(200)]).I32).ToBe(-56);
  Expect<Int32>(Call1('gu', [MakeValueI32(0), MakeValueI32(200)]).I32).ToBe(200);
  Expect<Int32>(Call1('sg', [MakeValueI32(99)]).I32).ToBe(99);
end;

procedure TInterpTests.TestStructNullTraps;
begin
  { $getnull (result i32) ref.null 0; struct.get 0 0 -> traps. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7F, $01]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(7, VecOf([BLit([$02, $67, $6E, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $D0, $00, $FB, $02, $00, $00, $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('gn', [], 'null structure reference');
end;

{ --- GC: array round trip, bounds, overlap ------------------------------- }

procedure TInterpTests.TestArrayRoundTrip;
begin
  { type0 = (array (mut i32))
    $mkget (param len val)(result i32) array.new 0; array.get 0 [0]
    $arrlen (param len val)(result i32) array.new 0; array.len }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5E, $7F, $01]),
      BLit([$60, $02, $7F, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$01]), BLit([$01])])),
    Sect(7, VecOf([
      BLit([$02, $6D, $67, $00, $00]),
      BLit([$02, $6C, $6E, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$01, $01, $63, $00,
        $20, $01, $20, $00, $FB, $06, $00, $21, $02,
        $20, $02, $41, $00, $FB, $0B, $00, $0B]),
      CodeEntry([$00, $20, $01, $20, $00, $FB, $06, $00, $FB, $0F, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('mg', [MakeValueI32(3), MakeValueI32(55)]).I32).ToBe(55);
  Expect<Int32>(Call1('ln', [MakeValueI32(3), MakeValueI32(55)]).I32).ToBe(3);
end;

{ End-to-end (decode -> validate -> instantiate -> invoke) that a v128
  survives a round trip through a GC struct field AND an array element,
  driven entirely by the *Vec IR ops the validator now emits. The param and
  the result each span two flat slots (SIMD design §1.6); a lost high half
  or a mis-sized field store would corrupt the top 8 bytes. }
procedure TInterpTests.TestVec128StructAndArrayRoundTrip;
var
  Params, Results: array[0 .. 1] of TWasmValue;
begin
  { type0 (struct (mut v128)); type1 (array (mut v128));
    type2 (func (param v128) (result v128)).
    "sr": store the param into a fresh struct's field 0, read it back.
    "ar": store the param into a fresh 1-element array, read it back. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7B, $01]),
      BLit([$5E, $7B, $01]),
      BLit([$60, $01, $7B, $01, $7B])])),
    Sect(3, VecOf([BLit([$02]), BLit([$02])])),
    Sect(7, VecOf([
      BLit([$02, $73, $72, $00, $00]),
      BLit([$02, $61, $72, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$01, $01, $63, $00,
        $FB, $01, $00, $21, $01,           { struct.new_default 0; local.set 1 }
        $20, $01, $20, $00, $FB, $05, $00, $00,  { struct.set 0 0 }
        $20, $01, $FB, $02, $00, $00, $0B]),     { struct.get 0 0 }
      CodeEntry([$01, $01, $63, $01,
        $41, $01, $FB, $07, $01, $21, $01, { array.new_default 1 (len 1); set 1 }
        $20, $01, $41, $00, $20, $00, $FB, $0E, $01,  { array.set 1 }
        $20, $01, $41, $00, $FB, $0B, $01, $0B])]))   { array.get 1 }
  ]));
  DoInstantiate;

  Params[0].Bits := UInt64($1122334455667788);
  Params[1].Bits := UInt64($99AABBCCDDEEFF00);

  Results[0].Bits := 0;
  Results[1].Bits := 0;
  InterpInvoke(FStore, FuncAddr('sr'), @Params[0], @Results[0]);
  Expect<UInt64>(Results[0].Bits).ToBe(UInt64($1122334455667788));
  Expect<UInt64>(Results[1].Bits).ToBe(UInt64($99AABBCCDDEEFF00));

  Results[0].Bits := 0;
  Results[1].Bits := 0;
  InterpInvoke(FStore, FuncAddr('ar'), @Params[0], @Results[0]);
  Expect<UInt64>(Results[0].Bits).ToBe(UInt64($1122334455667788));
  Expect<UInt64>(Results[1].Bits).ToBe(UInt64($99AABBCCDDEEFF00));
end;

procedure TInterpTests.TestArrayOutOfBounds;
begin
  { $getoob (param i32)(result i32) array.new 0 [len 2]; array.get 0 [param] }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5E, $7F, $01]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(7, VecOf([BLit([$02, $67, $6F, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00,
      $41, $00, $41, $02, $FB, $06, $00, $20, $00, $FB, $0B, $00, $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('go', [MakeValueI32(5)], 'out of bounds array access');
end;

procedure TInterpTests.TestArrayCopyOverlap;
begin
  { Build [10,20,30,40], array.copy dst=1 src=0 count=3 (overlapping, dst>src
    so a correct memmove copies backward), then read [param]. Naive forward
    copy would corrupt; [3] must read 30. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5E, $7F, $01]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(7, VecOf([BLit([$02, $63, $70, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$01, $01, $63, $00,
      $41, $00, $41, $04, $FB, $06, $00, $21, $01,
      $20, $01, $41, $00, $41, $0A, $FB, $0E, $00,
      $20, $01, $41, $01, $41, $14, $FB, $0E, $00,
      $20, $01, $41, $02, $41, $1E, $FB, $0E, $00,
      $20, $01, $41, $03, $41, $28, $FB, $0E, $00,
      $20, $01, $41, $01, $20, $01, $41, $00, $41, $03, $FB, $11, $00, $00,
      $20, $01, $20, $00, $FB, $0B, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('cp', [MakeValueI32(0)]).I32).ToBe(10);
  Expect<Int32>(Call1('cp', [MakeValueI32(3)]).I32).ToBe(30);
end;

procedure TInterpTests.TestArrayNewData;
begin
  { type0 = (array (mut i8)); passive data = [1,2,3,4]
    $fromdata (param i32)(result i32) array.new_data 0 0 [off 0 len 4];
      array.get_u 0 [param] }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5E, $78, $01]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(7, VecOf([BLit([$02, $66, $64, $00, $00])])),
    Sect(12, BLit([$01])),
    Sect(10, VecOf([CodeEntry([$00,
      $41, $00, $41, $04, $FB, $09, $00, $00, $20, $00, $FB, $0D, $00, $0B])])),
    Sect(11, VecOf([BLit([$01, $04, $01, $02, $03, $04])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('fd', [MakeValueI32(0)]).I32).ToBe(1);
  Expect<Int32>(Call1('fd', [MakeValueI32(3)]).I32).ToBe(4);
end;

procedure TInterpTests.TestArrayNewElem;
begin
  { type0 = (array (mut funcref)); passive elem = [f, f]
    $fromelem (param i32)(result i32) array.new_elem 0 0 [off 0 len 2];
      array.get 0 [param]; ref.is_null }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5E, $70, $01]),
      BLit([$60, $00, $00]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$01]), BLit([$02])])),
    Sect(7, VecOf([BLit([$02, $66, $65, $00, $01])])),
    Sect(9, VecOf([BLit([$01, $00, $02, $00, $00])])),
    Sect(10, VecOf([
      CodeEntry([$00, $0B]),
      CodeEntry([$00,
        $41, $00, $41, $02, $FB, $0A, $00, $00, $20, $00, $FB, $0B, $00, $D1, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('fe', [MakeValueI32(0)]).I32).ToBe(0);
  Expect<Int32>(Call1('fe', [MakeValueI32(1)]).I32).ToBe(0);
end;

{ --- GC: ref.test / ref.cast / br_on_cast / i31 -------------------------- }

procedure TInterpTests.TestRefTestCast;
begin
  { type0 = (struct (field (mut i32)))
    $istype    struct.new_default 0; ref.test (ref 0)      -> 1
    $isnoti31  struct.new_default 0; ref.test (ref i31)    -> 0
    $castok    struct.new 0 [42]; ref.cast (ref 0); get 0  -> 42
    $castnull  ref.null 0; ref.test (ref 0)                -> 0
    $nullable  ref.null 0; ref.test (ref null 0)           -> 1
    $castfail  struct.new_default 0; ref.cast (ref i31)    -> traps }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7F, $01]),
      BLit([$60, $00, $01, $7F]),
      BLit([$60, $00, $00])])),
    Sect(3, VecOf([BLit([$01]), BLit([$01]), BLit([$01]),
      BLit([$01]), BLit([$01]), BLit([$02])])),
    Sect(7, VecOf([
      BLit([$02, $69, $74, $00, $00]),
      BLit([$02, $69, $33, $00, $01]),
      BLit([$02, $63, $6B, $00, $02]),
      BLit([$02, $63, $6E, $00, $03]),
      BLit([$02, $6E, $62, $00, $04]),
      BLit([$02, $63, $66, $00, $05])])),
    Sect(10, VecOf([
      CodeEntry([$00, $FB, $01, $00, $FB, $14, $00, $0B]),
      CodeEntry([$00, $FB, $01, $00, $FB, $14, $6C, $0B]),
      CodeEntry([$00, $41, $2A, $FB, $00, $00, $FB, $16, $00, $FB, $02, $00, $00, $0B]),
      CodeEntry([$00, $D0, $00, $FB, $14, $00, $0B]),
      CodeEntry([$00, $D0, $00, $FB, $15, $00, $0B]),
      CodeEntry([$00, $FB, $01, $00, $FB, $16, $6C, $1A, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('it', []).I32).ToBe(1);
  Expect<Int32>(Call1('i3', []).I32).ToBe(0);
  Expect<Int32>(Call1('ck', []).I32).ToBe(42);
  Expect<Int32>(Call1('cn', []).I32).ToBe(0);
  Expect<Int32>(Call1('nb', []).I32).ToBe(1);
  ExpectTrap('cf', [], 'cast failure');
end;

procedure TInterpTests.TestBrOnCastRefinement;
begin
  { $brcast (result i32)
      block (result (ref 0))
        struct.new 0 [99]
        br_on_cast 0 (ref 0) (ref 0)   ; always succeeds, branches with the ref
        unreachable
      end
      struct.get 0 0                    ; reads 99 from the threaded ref }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7F, $01]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(7, VecOf([BLit([$02, $62, $63, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00,
      $02, $64, $00,
      $41, $E3, $00, $FB, $00, $00,
      $FB, $18, $00, $00, $00, $00,
      $00,
      $0B,
      $FB, $02, $00, $00, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('bc', []).I32).ToBe(99);
end;

procedure TInterpTests.TestI31;
begin
  { $i31s (param i32)(result i32) ref.i31; i31.get_s
    $i31u (param i32)(result i32) ref.i31; i31.get_u
    $i31null (result i32) ref.null i31; i31.get_s -> traps }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $01, $7F]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([
      BLit([$02, $69, $73, $00, $00]),
      BLit([$02, $69, $75, $00, $01]),
      BLit([$02, $69, $6E, $00, $02])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $FB, $1C, $FB, $1D, $0B]),
      CodeEntry([$00, $20, $00, $FB, $1C, $FB, $1E, $0B]),
      CodeEntry([$00, $D0, $6C, $FB, $1D, $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('is', [MakeValueI32(-5)]).I32).ToBe(-5);
  Expect<Int32>(Call1('iu', [MakeValueI32(5)]).I32).ToBe(5);
  { -1 wraps to all 31 payload bits; get_s reads -1, get_u reads 0x7FFFFFFF. }
  Expect<Int32>(Call1('is', [MakeValueI32(-1)]).I32).ToBe(-1);
  Expect<Int32>(Call1('iu', [MakeValueI32(-1)]).U32).ToBe(UInt32($7FFFFFFF));
  ExpectTrap('in', [], 'null i31 reference');
end;

procedure TInterpTests.TestMidConstructionCollection;
begin
  { type0 = (struct (field (mut i32)))         inner
    type1 = (struct (field (mut (ref null 0))))  outer, field is a ref to inner
    $nest (param i32)(result i32)
      inner  = struct.new 0 [param]
      outer  = struct.new 1 [inner]       ; allocation here may collect
      struct.get 1 0                       ; -> inner ref
      struct.get 0 0                       ; -> param, iff inner survived
    With the GC threshold floored to 0 every allocation collects, so building
    the outer proves the inner survives via publish-first + RefRegBits rooting. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7F, $01]),
      BLit([$5F, $01, $63, $00, $01]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$02])])),
    Sect(7, VecOf([BLit([$04, $6E, $65, $73, $74, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00,
      $20, $00, $FB, $00, $00, $FB, $00, $01,
      $FB, $02, $01, $00, $FB, $02, $00, $00, $0B])]))
  ]));
  DoInstantiate;
  FStore.Heap.Threshold := 0;   { collect at every allocation }
  Expect<Int32>(Call1('nest', [MakeValueI32(1234)]).I32).ToBe(1234);
end;

{ --- host calls ---------------------------------------------------------- }

procedure TInterpTests.TestHostCallRoundTrip;
var
  Canon, TypeIdx: TWasmEngineTypeIds;
begin
  { import "h"."add" (func (i32 i32)->(i32))
    $callhost (param i32 i32)(result i32) local.get 0 local.get 1 call 0 }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $02, $7F, $7F, $01, $7F])])),
    Sect(2, VecOf([BLit([$01, $68, $03, $61, $64, $64, $00, $00])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$02, $63, $68, $00, $01])])),
    Sect(10, VecOf([CodeEntry([$00, $20, $00, $20, $01, $10, $00, $0B])]))
  ]));
  FEngine.InternModule(FIr, Canon, TypeIdx);
  SetLength(FImports.Funcs, 1);
  FImports.Funcs[0] := FStore.AddHostFunc(TypeIdx[0], @HostAddCallback, nil);
  DoInstantiate;
  Expect<Int32>(Call1('ch', [MakeValueI32(20), MakeValueI32(22)]).I32).ToBe(42);
end;

procedure TInterpTests.TestHostCallTrapPropagates;
var
  Canon, TypeIdx: TWasmEngineTypeIds;
begin
  { import "h"."boom" (func) ; $callboom () call 0 }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $00])])),
    Sect(2, VecOf([BLit([$01, $68, $04, $62, $6F, $6F, $6D, $00, $00])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$02, $63, $62, $00, $01])])),
    Sect(10, VecOf([CodeEntry([$00, $10, $00, $0B])]))
  ]));
  FEngine.InternModule(FIr, Canon, TypeIdx);
  SetLength(FImports.Funcs, 1);
  FImports.Funcs[0] := FStore.AddHostFunc(TypeIdx[0], @HostBoomCallback, nil);
  DoInstantiate;
  ExpectTrap('cb', [], 'host boom');
end;

procedure TInterpTests.TestHostCallReentrancy;
var
  Canon, TypeIdx: TWasmEngineTypeIds;
begin
  { import "h"."reenter" (func (i32)->(i32))
    $double (param i32)(result i32) local.get 0 local.get 0 i32.add
    $callreenter (param i32)(result i32) local.get 0 call 0
    The host callback re-invokes $double on the same store. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(2, VecOf([BLit([$01, $68, $07, $72, $65, $65, $6E, $74, $65, $72,
      $00, $00])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      BLit([$02, $64, $62, $00, $01]),
      BLit([$02, $63, $72, $00, $02])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $20, $00, $6A, $0B]),
      CodeEntry([$00, $20, $00, $10, $00, $0B])]))
  ]));
  FEngine.InternModule(FIr, Canon, TypeIdx);
  SetLength(FImports.Funcs, 1);
  FImports.Funcs[0] := FStore.AddHostFunc(TypeIdx[0], @HostReenterCallback, nil);
  DoInstantiate;
  GReenterStore := FStore;
  GReenterDouble := FuncAddr('db');
  Expect<Int32>(Call1('cr', [MakeValueI32(21)]).I32).ToBe(42);
end;

{ --- M7: extern/any conversion crosses the hierarchy (interp-spec §3.9 O-4) -
  extern.convert_any / any.convert_extern move a value between the `any` and
  `extern` hierarchies through Wasm.Runtime.Gc's wrapper pair, so a ref.test
  after a conversion classifies the value by its NEW hierarchy. Both functions
  externalize the same freshly allocated struct; the value that was `any` now
  answers `(ref extern)` true and `(ref any)` false — the exact flip the
  kind-only representation could not express before. The `.wast` corpus
  (ref_test / ref_cast / extern) covers every shape; this pins the observable
  interpreter behaviour directly. }
procedure TInterpTests.TestM7ExternConvertCrossHierarchy;
begin
  { Both exports allocate a struct and cross the boundary. A ref.test may
    only name a heap type in the operand's OWN hierarchy, so the flip is
    observed by re-typing the value through the convert ops:
      $m7e: struct.new_default; extern.convert_any;
            ref.test (ref extern)                (0xFB 0x14 0x6F) -> 1
            (the externalized struct now answers `extern`; before the fix
             the kind-only map answered 0)
      $m7r: struct.new_default; extern.convert_any; any.convert_extern;
            ref.test (ref struct)                (0xFB 0x14 0x6B) -> 1
            (the round trip recovers the concrete struct, which is a
             struct again) }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7F, $01]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01]), BLit([$01])])),
    Sect(7, VecOf([
      BLit([$03, $6D, $37, $65, $00, $00]),
      BLit([$03, $6D, $37, $72, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$00, $FB, $01, $00, $FB, $1B, $FB, $14, $6F, $0B]),
      CodeEntry([$00, $FB, $01, $00, $FB, $1B, $FB, $1A,
        $FB, $14, $6B, $0B])]))
  ]));
  DoInstantiate;
  { Externalized struct answers `extern`; the round trip recovers a struct. }
  Expect<Int32>(Call1('m7e', []).I32).ToBe(1);
  Expect<Int32>(Call1('m7r', []).I32).ToBe(1);
end;

{ --- SIMD / v128 (Track G) ----------------------------------------------- }

{ Compute with a v128 intermediate and return an i32: splat two i32 params
  into i32x4 vectors, add lane-wise, extract lane 0. Exercises i32x4.splat
  ($FD 17), i32x4.add ($FD 174, a two-byte subopcode) and i32x4.extract_lane
  ($FD 27) — the whole splat/binop/extract spine — end to end. }
procedure TInterpTests.TestSimdSplatAddExtract;
begin
  { (func $vadd (param i32 i32) (result i32)
      local.get 0 i32x4.splat local.get 1 i32x4.splat
      i32x4.add i32x4.extract_lane 0) exported "vadd". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $02, $7F, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$04, $76, $61, $64, $64, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $20, $00, $FD, $11,           { local.get 0 ; i32x4.splat }
      $20, $01, $FD, $11,           { local.get 1 ; i32x4.splat }
      $FD, $AE, $01,                { i32x4.add (subopcode 174) }
      $FD, $1B, $00,                { i32x4.extract_lane 0 }
      $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('vadd', [MakeValueI32(40), MakeValueI32(2)]).I32).ToBe(42);
  Expect<Int32>(Call1('vadd',
    [MakeValueI32(-5), MakeValueI32(9)]).I32).ToBe(4);
end;

{ v128.store then v128.load through linear memory, then extract a lane to
  observe the round trip — both instructions go through the one memory
  chokepoint (simd-spec §4.5). }
procedure TInterpTests.TestSimdMemoryRoundTrip;
begin
  { (memory 1)
    (func $rt (param i32) (result i32)
      i32.const 0 local.get 0 i32x4.splat v128.store
      i32.const 0 v128.load i32x4.extract_lane 2) exported "rt". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([BLit([$02, $72, $74, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $41, $00, $20, $00, $FD, $11, { i32.const 0 ; local.get 0 ; i32x4.splat }
      $FD, $0B, $00, $00,           { v128.store align=0 offset=0 }
      $41, $00, $FD, $00, $00, $00, { i32.const 0 ; v128.load align=0 offset=0 }
      $FD, $1B, $02,                { i32x4.extract_lane 2 }
      $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('rt', [MakeValueI32(1234)]).I32).ToBe(1234);
  Expect<Int32>(Call1('rt', [MakeValueI32(-77)]).I32).ToBe(-77);
end;

{ A v128.load whose 16-byte access escapes the single page traps the
  ordinary 'out of bounds memory access', before any byte moves. }
procedure TInterpTests.TestSimdLoadOutOfBounds;
begin
  { (memory 1)
    (func $oob (param i32) (result i32)
      local.get 0 v128.load i32x4.extract_lane 0) exported "oob". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([BLit([$03, $6F, $6F, $62, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $20, $00, $FD, $00, $00, $00, { local.get 0 ; v128.load align=0 offset=0 }
      $FD, $1B, $00,                { i32x4.extract_lane 0 }
      $0B])]))
  ]));
  DoInstantiate;
  { 65530 + 16 = 65546 > 65536: the whole access is out of bounds. }
  ExpectTrap('oob', [MakeValueI32(65530)], 'out of bounds memory access');
end;

{ A mutable v128 global: set it from a splat, read it back, extract a lane.
  The global cell is the store's 16-byte Vec side (simd-spec §1.7). }
procedure TInterpTests.TestSimdGlobalGetSet;
begin
  { (global (mut v128) (v128.const i32x4 0 0 0 0))
    (func $sg (param i32) (result i32)
      local.get 0 i32x4.splat global.set 0
      global.get 0 i32x4.extract_lane 1) exported "sg". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(6, VecOf([Cat([
      BLit([$7B, $01]),             { valtype v128, mutable }
      BLit([$FD, $0C]),             { v128.const }
      BLit([$00, $00, $00, $00, $00, $00, $00, $00,
            $00, $00, $00, $00, $00, $00, $00, $00]),
      BLit([$0B])])])),             { end init expr }
    Sect(7, VecOf([BLit([$02, $73, $67, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $20, $00, $FD, $11,           { local.get 0 ; i32x4.splat }
      $24, $00,                     { global.set 0 }
      $23, $00,                     { global.get 0 }
      $FD, $1B, $01,                { i32x4.extract_lane 1 }
      $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('sg', [MakeValueI32(555)]).I32).ToBe(555);
  Expect<Int32>(Call1('sg', [MakeValueI32(-1)]).I32).ToBe(-1);
end;

{ A v128 argument in and a v128 result out — the two-slot seam (simd-spec
  §1.6): each v128 occupies TWO consecutive flat TWasmValue slots, low half
  first. The function doubles each i32x4 lane; the harness builds the param
  across two slots and reads the result across two slots. }
procedure TInterpTests.TestSimdParamResult;
var
  Params: array[0 .. 1] of TWasmValue;
  Results: array[0 .. 1] of TWasmValue;
begin
  { (func $vdouble (param v128) (result v128)
      local.get 0 local.get 0 i32x4.add) exported "vdouble". }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7B, $01, $7B])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$07, $76, $64, $6F, $75, $62, $6C, $65, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $20, $00, $20, $00, $FD, $AE, $01,   { local.get 0 x2 ; i32x4.add }
      $0B])]))
  ]));
  DoInstantiate;

  { i32x4 [1, 2, 3, 4] packed into two slots, low lanes first. }
  Params[0].U64 := (UInt64(2) shl 32) or UInt64(1);
  Params[1].U64 := (UInt64(4) shl 32) or UInt64(3);
  Results[0].Bits := 0;
  Results[1].Bits := 0;
  InterpInvoke(FStore, FuncAddr('vdouble'), @Params[0], @Results[0]);

  { Each lane doubled: [2, 4, 6, 8], again across two slots. }
  Expect<UInt64>(Results[0].U64).ToBe((UInt64(4) shl 32) or UInt64(2));
  Expect<UInt64>(Results[1].U64).ToBe((UInt64(8) shl 32) or UInt64(6));
end;

{ Finding 1 (wasm->wasm args). A callee whose signature is
  (param v128 i32 v128 i32) has an even-alignment PAD before its second v128
  param (params land at slots 0,2,4,6 with a pad at slot 3). The dense arg
  block a caller builds has no pad, so the old positional per-slot copy in
  PushWasmFrame misplaced every operand at/after the pad: the second v128 was
  read from the wrong half and the trailing i32 dropped to zero. The scatter
  through the callee's LocalRegs fixes it. The callee returns
  lane0(v0) + i1 + lane0(v2) + i3; the caller passes distinct-lane v128.const
  values so a half-misread is observable, plus i1=7 and i3=9. Correct total is
  100 + 7 + 200 + 9 = 316; the old code produced 309 (v2 half-misread to 202,
  i3 dropped). }
procedure TInterpTests.TestSimdCallPaddedParams;
begin
  { type0 callee (param v128 i32 v128 i32)->(i32); type1 caller ()->(i32). }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $04, $7B, $7F, $7B, $7F, $01, $7F]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([BLit([$03, $72, $75, $6E, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([
        $00,
        $20, $00, $FD, $1B, $00,       { local.get 0 ; i32x4.extract_lane 0 }
        $20, $01, $6A,                 { local.get 1 ; i32.add }
        $20, $02, $FD, $1B, $00,       { local.get 2 ; i32x4.extract_lane 0 }
        $6A,                           { i32.add }
        $20, $03, $6A,                 { local.get 3 ; i32.add }
        $0B]),
      CodeEntry([
        $00,
        $FD, $0C, $64, $00, $00, $00, $65, $00, $00, $00,
                  $66, $00, $00, $00, $67, $00, $00, $00,  { v0 = i32x4(100,101,102,103) }
        $41, $07,                      { i32.const 7 }
        $FD, $0C, $C8, $00, $00, $00, $C9, $00, $00, $00,
                  $CA, $00, $00, $00, $CB, $00, $00, $00,  { v2 = i32x4(200,201,202,203) }
        $41, $09,                      { i32.const 9 }
        $10, $00,                      { call 0 }
        $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('run', []).I32).ToBe(316);
end;

{ Finding 1 (tail-call args). The same padded (param v128 i32 v128 i32)
  callee, reached through return_call instead of call, so the fix must apply
  in ReplaceWasmFrame too. Same expected total, 316. }
procedure TInterpTests.TestSimdReturnCallPaddedParams;
begin
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $04, $7B, $7F, $7B, $7F, $01, $7F]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([BLit([$03, $72, $75, $6E, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([
        $00,
        $20, $00, $FD, $1B, $00,
        $20, $01, $6A,
        $20, $02, $FD, $1B, $00,
        $6A,
        $20, $03, $6A,
        $0B]),
      CodeEntry([
        $00,
        $FD, $0C, $64, $00, $00, $00, $65, $00, $00, $00,
                  $66, $00, $00, $00, $67, $00, $00, $00,
        $41, $07,
        $FD, $0C, $C8, $00, $00, $00, $C9, $00, $00, $00,
                  $CA, $00, $00, $00, $CB, $00, $00, $00,
        $41, $09,
        $12, $00,                      { return_call 0 }
        $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('run', []).I32).ToBe(316);
end;

{ Regression: a v128-FIRST call signature (param v128 v128)->(v128) has no
  internal pad, exactly the shape the corpus exercises. The unified scatter
  must still marshal it correctly. Callee adds the two i32x4 vectors; caller
  passes i32x4(1,2,3,4) and i32x4(10,20,30,40) and extracts lane 2 of the
  result: 3 + 30 = 33. }
procedure TInterpTests.TestSimdCallVecFirstParamsRegression;
begin
  { type0 callee (param v128 v128)->(v128); type1 caller ()->(i32). }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $02, $7B, $7B, $01, $7B]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([BLit([$03, $72, $75, $6E, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([
        $00,
        $20, $00, $20, $01, $FD, $AE, $01,   { local.get 0/1 ; i32x4.add }
        $0B]),
      CodeEntry([
        $00,
        $FD, $0C, $01, $00, $00, $00, $02, $00, $00, $00,
                  $03, $00, $00, $00, $04, $00, $00, $00,  { i32x4(1,2,3,4) }
        $FD, $0C, $0A, $00, $00, $00, $14, $00, $00, $00,
                  $1E, $00, $00, $00, $28, $00, $00, $00,  { i32x4(10,20,30,40) }
        $10, $00,                      { call 0 }
        $FD, $1B, $02,                 { i32x4.extract_lane 2 }
        $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('run', []).I32).ToBe(33);
end;

{ Finding 2 (results). A plain entry (invoke) of functions whose result
  signature interleaves a scalar before a v128, so the return block carries an
  even-alignment pad and the results are NOT contiguous from ReturnRegBase.
  DoReturn and ResultSlotCount must walk ResultRegs pad-aware. Two shapes:
  (result i32 v128) and (result v128 i32 v128). The old contiguous copy read
  the pad slot as a result and dropped a v128. }
procedure TInterpTests.TestSimdEntryPaddedResults;
var
  Res2: array[0 .. 2] of TWasmValue;
  Res5: array[0 .. 4] of TWasmValue;
begin
  { Module A: func "ra" ()->(i32 v128): i32.const 42, v128.const
    i32x4(10,11,12,13). Flat results: [42, (11<<32)|10, (13<<32)|12]. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $02, $7F, $7B])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$02, $72, $61, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $41, $2A,                        { i32.const 42 }
      $FD, $0C, $0A, $00, $00, $00, $0B, $00, $00, $00,
                $0C, $00, $00, $00, $0D, $00, $00, $00,  { i32x4(10,11,12,13) }
      $0B])]))
  ]));
  DoInstantiate;
  Res2[0].Bits := 0;
  Res2[1].Bits := 0;
  Res2[2].Bits := 0;
  InterpInvoke(FStore, FuncAddr('ra'), nil, @Res2[0]);
  Expect<Int32>(Res2[0].I32).ToBe(42);
  Expect<UInt64>(Res2[1].U64).ToBe((UInt64(11) shl 32) or UInt64(10));
  Expect<UInt64>(Res2[2].U64).ToBe((UInt64(13) shl 32) or UInt64(12));

  { Module B: func "rb" ()->(v128 i32 v128): v128.const i32x4(1,2,3,4),
    i32.const 55, v128.const i32x4(90,91,92,93). Flat results (5 slots):
    [(2<<32)|1, (4<<32)|3, 55, (91<<32)|90, (93<<32)|92]. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $03, $7B, $7F, $7B])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$02, $72, $62, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $FD, $0C, $01, $00, $00, $00, $02, $00, $00, $00,
                $03, $00, $00, $00, $04, $00, $00, $00,  { i32x4(1,2,3,4) }
      $41, $37,                        { i32.const 55 }
      $FD, $0C, $5A, $00, $00, $00, $5B, $00, $00, $00,
                $5C, $00, $00, $00, $5D, $00, $00, $00,  { i32x4(90,91,92,93) }
      $0B])]))
  ]));
  DoInstantiate;
  Res5[0].Bits := 0;
  Res5[1].Bits := 0;
  Res5[2].Bits := 0;
  Res5[3].Bits := 0;
  Res5[4].Bits := 0;
  InterpInvoke(FStore, FuncAddr('rb'), nil, @Res5[0]);
  Expect<UInt64>(Res5[0].U64).ToBe((UInt64(2) shl 32) or UInt64(1));
  Expect<UInt64>(Res5[1].U64).ToBe((UInt64(4) shl 32) or UInt64(3));
  Expect<Int32>(Res5[2].I32).ToBe(55);
  Expect<UInt64>(Res5[3].U64).ToBe((UInt64(91) shl 32) or UInt64(90));
  Expect<UInt64>(Res5[4].U64).ToBe((UInt64(93) shl 32) or UInt64(92));
end;

{ --- exception handling (Track H) ---------------------------------------- }

{ Assert the action leaves the guest as an uncaught wasm exception —
  EWasmException, distinct from a trap (EWasmTrap) and from any other error.
  The three arms are ordered most-derived first: EWasmException and EWasmTrap
  are siblings under EWasmError, and the base clause must come last or it would
  swallow both. }
procedure TInterpTests.ExpectException(const AName: string;
  const AParams: array of TWasmValue);
var
  ParamArr: array of TWasmValue;
  ParamPtr: PWasmValue;
  I: Integer;
  Cls: string;
begin
  SetLength(ParamArr, Length(AParams));
  for I := 0 to High(AParams) do
    ParamArr[I] := AParams[I];
  if Length(ParamArr) > 0 then
    ParamPtr := @ParamArr[0]
  else
    ParamPtr := nil;

  Cls := 'NO-EXCEPTION';
  try
    InterpInvoke(FStore, FuncAddr(AName), ParamPtr, nil);
  except
    on E: EWasmException do
      Cls := 'exception';
    on E: EWasmTrap do
      Cls := 'trap';
    on E: EWasmError do
      Cls := 'error';
  end;

  Expect<string>('class=' + Cls).ToBe('class=exception');
end;

procedure TInterpTests.TestThrowCatchPayload;
begin
  { type0 tag (param i32), type1 () -> (i32).
    (func (result i32)
      (try_table (result i32) (catch 0 0)
        i32.const 5 (throw 0)))
    catch 0 delivers the tag's i32 payload to label 0 (the try_table result). }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(13, VecOf([BLit([$00, $00])])),
    Sect(7, VecOf([BLit([$01, $66, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $1F, $7F, $01, $00, $00, $00,   { try_table (result i32) (catch tag0 label0) }
      $41, $05,                       { i32.const 5 }
      $08, $00,                       { throw tag0 }
      $0B,                            { end try_table }
      $0B])]))                        { end func }
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('f', []).I32).ToBe(5);
end;

procedure TInterpTests.TestCatchAll;
begin
  { type0 tag (), type1 () -> (i32).
    (func (result i32)
      (block $h (try_table (catch_all $h) (throw 0)))
      i32.const 7)
    catch_all catches the throw and branches to $h (arity 0); control then
    falls through to i32.const 7. Returning (not raising) proves the catch. The
    catch label is resolved in the enclosing scope, so label 0 is $h. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(13, VecOf([BLit([$00, $00])])),
    Sect(7, VecOf([BLit([$01, $66, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $02, $40,                       { block $h [] }
      $1F, $40, $01, $02, $00,        { try_table [] (catch_all label0=$h) }
      $08, $00,                       { throw tag0 }
      $0B,                            { end try_table }
      $0B,                            { end block $h }
      $41, $07,                       { i32.const 7 }
      $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('f', []).I32).ToBe(7);
end;

procedure TInterpTests.TestCatchRefDeliversExnref;
begin
  { type0 tag (), type1 () -> (i32).
    (func (result i32)
      (block $h (result exnref) (try_table (catch_ref 0 $h) (throw 0)))
      ref.is_null)
    catch_ref delivers the exnref to $h (result exnref); ref.is_null on the
    delivered value is 0, proving a real (non-null) exnref reached the handler. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(13, VecOf([BLit([$00, $00])])),
    Sect(7, VecOf([BLit([$01, $66, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $02, $69,                       { block $h (result exnref) }
      $1F, $69, $01, $01, $00, $00,   { try_table (result exnref) (catch_ref tag0 label0=$h) }
      $08, $00,                       { throw tag0 }
      $0B,                            { end try_table }
      $0B,                            { end block $h }
      $D1,                            { ref.is_null }
      $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('f', []).I32).ToBe(0);
end;

procedure TInterpTests.TestUncaughtThrowRaisesException;
begin
  { type0 tag (), type1 () -> (i32).
    (func (result i32) (throw 0))   ; no handler -> EWasmException escapes. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(13, VecOf([BLit([$00, $00])])),
    Sect(7, VecOf([BLit([$01, $66, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $08, $00, $0B])]))
  ]));
  DoInstantiate;
  ExpectException('f', []);
end;

procedure TInterpTests.TestThrowRefRethrowCaughtByOuter;
begin
  { type0 tag (), type1 () -> (i32).
    (func (result i32)
      (block $outer
        (try_table (catch_all $outer)                       ; OUTER
          (block $inner (result exnref)
            (try_table (catch_ref 0 $inner) (throw 0)))      ; INNER
          (throw_ref)))                                      ; re-throw
      i32.const 42)
    The inner catch_ref binds the exnref into $inner; throw_ref reactivates it
    and the OUTER catch_all catches the rethrow, branching to $outer and
    falling through to 42. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(13, VecOf([BLit([$00, $00])])),
    Sect(7, VecOf([BLit([$01, $66, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $02, $40,                       { block $outer [] }
      $1F, $40, $01, $02, $00,        { OUTER try_table [] (catch_all label0=$outer) }
      $02, $69,                       { block $inner (result exnref) }
      $1F, $69, $01, $01, $00, $00,   { INNER try_table (result exnref) (catch_ref tag0 label0=$inner) }
      $08, $00,                       { throw tag0 }
      $0B,                            { end INNER try_table }
      $0B,                            { end block $inner }
      $0A,                            { throw_ref (the bound exnref) }
      $0B,                            { end OUTER try_table }
      $0B,                            { end block $outer }
      $41, $2A,                       { i32.const 42 }
      $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('f', []).I32).ToBe(42);
end;

procedure TInterpTests.TestThrowRefNullTraps;
begin
  { (func (result i32) ref.null exn throw_ref) -> traps 'null reference'. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$01, $66, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $00,
      $D0, $69,                       { ref.null exn }
      $0A,                            { throw_ref }
      $0B])]))
  ]));
  DoInstantiate;
  ExpectTrap('f', [], 'null reference');
end;

procedure TInterpTests.TestTagAddressMatching;
begin
  { Two distinct tags, both (). One try_table shape (catch tag1 label0).
    "cB" throws tag1 -> caught, returns 1.
    "tA" throws tag0 -> NOT matched by the tag1 clause -> escapes as an
    EWasmException. Identical handler, different thrown tag: matching is by tag
    address, not structural type (the two tags share a type). }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01]), BLit([$01])])),
    Sect(13, VecOf([BLit([$00, $00]), BLit([$00, $00])])),  { tag0, tag1 : type0 }
    Sect(7, VecOf([
      BLit([$02, $63, $42, $00, $00]),                      { "cB" -> func0 }
      BLit([$02, $74, $41, $00, $01])])),                   { "tA" -> func1 }
    Sect(10, VecOf([
      CodeEntry([                       { func0: catch tag1, throw tag1 -> 1 }
        $00,
        $02, $40,                       { block $h [] }
        $1F, $40, $01, $00, $01, $00,   { try_table [] (catch tag1 label0=$h) }
        $08, $01,                       { throw tag1 }
        $0B,                            { end try_table }
        $0B,                            { end block $h }
        $41, $01,                       { i32.const 1 }
        $0B]),
      CodeEntry([                       { func1: catch tag1, throw tag0 -> escapes }
        $00,
        $02, $40,                       { block $h [] }
        $1F, $40, $01, $00, $01, $00,   { try_table [] (catch tag1 label0=$h) }
        $08, $00,                       { throw tag0 }
        $0B,                            { end try_table }
        $0B,                            { end block $h }
        $41, $01,                       { i32.const 1 }
        $0B])]))
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('cB', []).I32).ToBe(1);
  ExpectException('tA', []);
end;

procedure TInterpTests.TestThrowUnwindsAcrossCall;
begin
  { type0 tag (param i32), type1 () (thrower), type2 () -> (i32) (caller).
    func0 $thrower: i32.const 7 (throw 0)
    func1 $caller (result i32):
      (block $h (result i32)
        (try_table (catch 0 $h) (call 0)) (unreachable))
    The throw fires in the callee (no handler there); the unwind pops the
    callee frame and the caller's try_table catches it, delivering 7 to $h. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $00]),
      BLit([$60, $00, $00]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$01]), BLit([$02])])),
    Sect(13, VecOf([BLit([$00, $00])])),
    Sect(7, VecOf([BLit([$01, $63, $00, $01])])),           { "c" -> func1 }
    Sect(10, VecOf([
      CodeEntry([$00, $41, $07, $08, $00, $0B]),             { thrower }
      CodeEntry([                                            { caller }
        $00,
        $02, $7F,                       { block $h (result i32) }
        $1F, $40, $01, $00, $00, $00,   { try_table [] (catch tag0 label0=$h) }
        $10, $00,                       { call func0 }
        $0B,                            { end try_table }
        $00,                            { unreachable (callee always throws) }
        $0B,                            { end block $h }
        $0B])]))                        { end func }
  ]));
  DoInstantiate;
  Expect<Int32>(Call1('c', []).I32).ToBe(7);
end;

procedure TInterpTests.TestRefPayloadSurvivesCollection;
begin
  { type0 struct (field (mut i32)), type1 tag (param (ref null 0)),
    type2 (param i32) -> (i32).
    (func (param i32) (result i32)
      (block $h (result (ref null 0))
        (try_table (catch 0 $h)
          (struct.new 0 (local.get 0)) (throw 0)))
      (struct.get 0 0))
    The thrown payload is a struct ref; with the GC threshold floored to 0 the
    exn allocation collects. The field reads back the original value, proving
    the exn carries and the collector traces a ref-typed payload. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7F, $01]),
      BLit([$60, $01, $63, $00, $00]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$02])])),
    Sect(13, VecOf([BLit([$00, $01])])),                    { tag0 : type1 }
    Sect(7, VecOf([BLit([$01, $72, $00, $00])])),           { "r" -> func0 }
    Sect(10, VecOf([CodeEntry([
      $00,
      $02, $63, $00,                       { block $h (result (ref null 0)) }
      $1F, $63, $00, $01, $00, $00, $00,   { try_table (result (ref null 0)) (catch tag0 label0=$h) }
      $20, $00,                            { local.get 0 }
      $FB, $00, $00,                       { struct.new 0 }
      $08, $00,                            { throw tag0 }
      $0B,                                 { end try_table }
      $0B,                                 { end block $h }
      $FB, $02, $00, $00,                  { struct.get 0 field 0 }
      $0B])]))
  ]));
  DoInstantiate;
  FStore.Heap.Threshold := 0;   { collect at every allocation }
  Expect<Int32>(Call1('r', [MakeValueI32(1234)]).I32).ToBe(1234);
end;

{ --- baseline-JIT tier seam (O-J1, O-J2, O-J5) --------------------------- }

{ The identity function (param i32)(result i32) local.get 0, exported "id". }
procedure TInterpTests.TestCallCountIncrementsPerInterpretedCall;
var
  Addr: TWasmFuncAddr;
begin
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$02, $69, $64, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $20, $00, $0B])]))
  ]));
  DoInstantiate;
  Addr := FuncAddr('id');

  { O-J1: not compiled, and the compile-on-hot counter starts at zero. }
  Expect<Boolean>(FStore.Funcs[Addr].CompiledEntry = nil).ToBe(True);
  Expect<Int32>(Integer(FStore.Funcs[Addr].CallCount)).ToBe(0);

  Expect<Int32>(Call1('id', [MakeValueI32(9)]).I32).ToBe(9);
  Expect<Int32>(Call1('id', [MakeValueI32(9)]).I32).ToBe(9);
  Expect<Int32>(Call1('id', [MakeValueI32(9)]).I32).ToBe(9);

  { Each interpreted top-level entry bumped the counter once. }
  Expect<Int32>(Integer(FStore.Funcs[Addr].CallCount)).ToBe(3);
end;

procedure TInterpTests.TestJitHookDispatchedAtEntry;
var
  Addr: TWasmFuncAddr;
  R: TWasmValue;
begin
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([BLit([$02, $69, $64, $00, $00])])),
    Sect(10, VecOf([CodeEntry([$00, $20, $00, $0B])]))
  ]));
  DoInstantiate;
  Addr := FuncAddr('id');

  { Fake a compiled entry: register the hook and flag the function compiled
    with a sentinel pointer. The top-level entry must dispatch to the hook
    (flat params in, flat results out) instead of running the interpreter's
    identity body — proving the seam before any real codegen exists. }
  GJitHookCalls := 0;
  GJitHookLastAddr := High(TWasmFuncAddr);
  FStore.JitInvokeCompiled := @FakeJitAddHundred;
  FStore.Funcs[Addr].CompiledEntry := Pointer(1);

  R := Call1('id', [MakeValueI32(7)]);

  { 7 + 100 is the hook's answer; the interpreter's identity would be 7. }
  Expect<Int32>(R.I32).ToBe(107);
  Expect<Int32>(GJitHookCalls).ToBe(1);
  Expect<Boolean>(GJitHookLastAddr = Addr).ToBe(True);
  { The interpreter never ran the body, so the counter stayed at zero. }
  Expect<Int32>(Integer(FStore.Funcs[Addr].CallCount)).ToBe(0);
end;

procedure TInterpTests.TestJitHookDispatchedForInternalCall;
var
  OuterAddr, TargetAddr: TWasmFuncAddr;
  R: TWasmValue;
begin
  { Two functions of type (i32)->(i32): func0 "target" is the identity, func1
    "outer" returns target(x) via a direct call. Flag target compiled: the
    interpreter runs outer but EnterCall must route the internal call through
    the hook and thread its flat result back into outer's dest register. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      BLit([$06, $74, $61, $72, $67, $65, $74, $00, $00]),   { "target" f0 }
      BLit([$05, $6F, $75, $74, $65, $72, $00, $01])])),     { "outer"  f1 }
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $0B]),                       { target: local 0 }
      CodeEntry([$00, $20, $00, $10, $00, $0B])]))           { outer: call 0 }
  ]));
  DoInstantiate;
  OuterAddr := FuncAddr('outer');
  TargetAddr := FuncAddr('target');

  GJitHookCalls := 0;
  GJitHookLastAddr := High(TWasmFuncAddr);
  FStore.JitInvokeCompiled := @FakeJitAddHundred;
  FStore.Funcs[TargetAddr].CompiledEntry := Pointer(1);

  R := Call1('outer', [MakeValueI32(5)]);

  { outer returns the compiled target's answer (5 + 100), threaded back through
    the flat seam. }
  Expect<Int32>(R.I32).ToBe(105);
  Expect<Int32>(GJitHookCalls).ToBe(1);
  Expect<Boolean>(GJitHookLastAddr = TargetAddr).ToBe(True);
  { outer ran interpreted at the top level (its counter bumped once); the
    compiled target's counter stayed at zero. }
  Expect<Int32>(Integer(FStore.Funcs[OuterAddr].CallCount)).ToBe(1);
  Expect<Int32>(Integer(FStore.Funcs[TargetAddr].CallCount)).ToBe(0);
end;

procedure TInterpTests.TestJitFrameOffsetsMatchLayout;
var
  Off: TWasmJitFrameOffsets;
begin
  { O-J5: the register-file / frame offsets the JIT's generated code reads. }
  Off := WasmJitFrameOffsets;

  { Reg[k] = Values[Base + k]: an 8-byte slot stride, the invariant every
    frame-relative load assumes (jit-spec §1.1). TWasmValue is a union over a
    UInt64, so the slot is 8 bytes on every target. }
  Expect<Int32>(Integer(Off.ValueSlotSize)).ToBe(8);

  { The prologue publishes a TWasmGcFrame laid out Prev, Slots, RefRegBits,
    RegisterCount, Instance; the collector reads Slots / RefRegBits /
    RegisterCount at these fixed offsets (jit-spec §9.1). }
  Expect<Int32>(Integer(Off.GcFrameSlots)).ToBe(SizeOf(Pointer));
  Expect<Int32>(Integer(Off.GcFrameRefRegBits)).ToBe(2 * SizeOf(Pointer));
  Expect<Int32>(Integer(Off.GcFrameRegisterCount)).ToBe(3 * SizeOf(Pointer));

  { The context cursors the JIT reads to carve a frame: Store is first, Values
    right after it, and ValueTop past Values. Pointer-aligned. }
  Expect<Int32>(Integer(Off.CtxValues)).ToBe(SizeOf(Pointer));
  Expect<Boolean>(Off.CtxValues < Off.CtxValueTop).ToBe(True);
  Expect<Boolean>((Off.CtxValueTop and (SizeOf(Pointer) - 1)) = 0).ToBe(True);
  Expect<Boolean>(Off.ActBase < Off.ActStride).ToBe(True);
  {$IFDEF CPUAARCH64}
  { JitFinishDirectCallScalar is a naked AAPCS64 leaf over these exact fields.
    Keep its immediates pinned to the live record layout. }
  Expect<Int32>(Integer(Off.CtxValueTop)).ToBe(32);
  Expect<Int32>(Integer(Off.CtxDepth)).ToBe(56);
  Expect<Int32>(Integer(Off.ActBase)).ToBe(32);
  Expect<Int32>(Integer(Off.ActGcFrame + Off.GcFramePrev)).ToBe(40);
  Expect<Int32>(Integer(Off.ActEntryResults)).ToBe(112);
  {$ENDIF}
end;

procedure TInterpTests.TestJitEntryClearsSemanticSlots;
const
  STALE_BITS = UInt64($A5A5A5A5DEADBEEF);
var
  Base: PWasmValue;
  Ctx: PWasmInterpContext;
  Fn: PWasmIrFunction;
  I, Reg, TempReg: UInt32;
begin
  { The shared compiled-entry frame starts over reused reservation storage.
    Give it a numeric local, an aligned v128 local, a reference local, a
    reference temporary, and a numeric temporary. Every reference slot must be
    null before the frame's entry safepoint; declared numeric/vector locals must
    have wasm's default zero; definition-dominated numeric temporaries may keep
    stale bits and are deliberately not on the GC map. }
  DecodeValidate(Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $00]),
      BLit([$60, $00, $00])])),
    Sect(3, VecOf([BLit([$01])])),
    Sect(7, VecOf([BLit([$03, $72, $75, $6E, $00, $00])])),
    Sect(10, VecOf([CodeEntry([
      $03, $01, $7F, $01, $7B, $01, $63, $00,
      $D0, $00, $1A,
      $41, $01, $1A,
      $0B])]))
  ]));
  DoInstantiate;
  Fn := @FIr.Functions[0];
  Ctx := InterpContextFor(FStore);
  I := 0;
  while I < Fn^.RegisterCount do
  begin
    Ctx^.Values[I].Bits := STALE_BITS;
    Inc(I);
  end;

  Base := JitEnterFrame(Ctx, FStore, FuncAddr('run'), nil, nil, rtEntry);
  Reg := Fn^.LocalRegs[0];
  Expect<UInt64>(Base[Reg].Bits).ToBe(0);
  Reg := Fn^.LocalRegs[1];
  Expect<UInt64>(Base[Reg].Bits).ToBe(0);
  Expect<UInt64>(Base[Reg + 1].Bits).ToBe(0);

  I := 0;
  while I < Fn^.RegisterCount do
  begin
    if IrRegIsRef(Fn^, I) then
      Expect<UInt64>(Base[I].Bits).ToBe(0);
    Inc(I);
  end;

  TempReg := IR_NO_REG;
  I := 0;
  while I < UInt32(Length(Fn^.Code)) do
  begin
    if Fn^.Code[I].Op = iroI32Const then
      TempReg := Fn^.Code[I].Dest;
    Inc(I);
  end;
  Expect<Boolean>(TempReg <> IR_NO_REG).ToBe(True);
  if TempReg <> IR_NO_REG then
    Expect<UInt64>(Base[TempReg].Bits).ToBe(STALE_BITS);

  { Collection here models the first entry safepoint. Stale numeric bits are
    ignored; stale reference bits would be observable to the precise walker. }
  FStore.Heap.Collect;
  JitLeaveFrame(Ctx);
end;

procedure TInterpTests.TestAotAbiFingerprintDeterministic;
var
  A, B: UInt64;
  Store2: TWasmStore;
begin
  { The AOT ABI fingerprint (aot-spec §1.4) is the "same build" guard: a
    deterministic hash over the offset records, the IR/value strides, the helper
    count, and AOT_ABI_REVISION. It must be stable and non-zero for a given
    build, and independent of WHICH live store computes it (the offsets are
    object-relative but layout-identical across stores). }
  A := WasmAotAbiFingerprint(FStore);
  Expect<Boolean>(A <> 0).ToBe(True);
  Expect<UInt64>(WasmAotAbiFingerprint(FStore)).ToBe(A);

  Store2 := TWasmStore.Create(FEngine);
  try
    B := WasmAotAbiFingerprint(Store2);
  finally
    Store2.Free;
  end;
  Expect<UInt64>(B).ToBe(A);
end;

procedure TInterpTests.SetupTests;
begin
  Test('a numeric add function computes end to end', TestAddFunction);
  Test('a function with locals and a loop sums a counter', TestLocalsAndLoop);
  Test('if/else selects the right branch', TestIfElse);
  Test('block and br exit early carrying a value', TestBlockBr);
  Test('select picks by condition', TestSelect);
  Test('global.get and global.set reach the store cell', TestGlobalGetSet);
  Test('a direct call marshals args and multiple results',
    TestDirectCallMultiResult);
  Test('call_indirect dispatches to the right function', TestCallIndirectHit);
  Test('call_indirect traps undefined element out of bounds',
    TestCallIndirectUndefinedElement);
  Test('call_indirect traps uninitialized element on a null',
    TestCallIndirectUninitializedElement);
  Test('call_indirect traps on a type mismatch', TestCallIndirectTypeMismatch);
  Test('call_indirect dispatches to a proper subtype of the expected type',
    TestCallIndirectSubtypeDispatches);
  Test('call_indirect traps on a genuinely unrelated type',
    TestCallIndirectUnrelatedTypeTraps);
  Test('a million-iteration tail recursion returns in bounded stack',
    TestTailCallBoundedStack);
  Test('deep non-tail recursion traps call stack exhausted',
    TestDeepRecursionExhausts);
  Test('unreachable traps', TestUnreachableTraps);
  Test('a moved epoch interrupts at a loop back-edge', TestEpochInterrupt);
  Test('ref.null and ref.is_null evaluate a null reference',
    TestRefNullIsNull);
  Test('memory store/load round-trips through the chokepoint',
    TestMemoryRoundTrip);
  Test('a memory load out of bounds traps', TestMemoryLoadOutOfBounds);
  Test('memory.size and memory.grow report and grow pages',
    TestMemoryGrowAndSize);
  Test('memory.fill and memory.copy move bytes', TestMemoryFillCopy);
  Test('memory.fill out of bounds traps', TestMemoryFillOutOfBounds);
  Test('memory.init copies a data segment and data.drop empties it',
    TestMemoryInitAndDataDrop);
  Test('table get/set/grow/size', TestTableGetSetGrow);
  Test('a table.get out of bounds traps', TestTableGetOutOfBounds);
  Test('table.init and table.copy move references', TestTableInitCopy);
  Test('ref.eq and ref.as_non_null', TestRefEqAsNonNull);
  Test('a struct round-trips incl. packed get_s/get_u', TestStructRoundTrip);
  Test('struct.get on a null traps null structure reference',
    TestStructNullTraps);
  Test('an array round-trips through new/get/len', TestArrayRoundTrip);
  Test('a v128 round-trips through a struct field and array element',
    TestVec128StructAndArrayRoundTrip);
  Test('array.get out of bounds traps', TestArrayOutOfBounds);
  Test('array.copy handles overlap (memmove)', TestArrayCopyOverlap);
  Test('array.new_data initialises from a data segment', TestArrayNewData);
  Test('array.new_elem initialises from an element segment', TestArrayNewElem);
  Test('ref.test and ref.cast, hit / miss / null / cast failure',
    TestRefTestCast);
  Test('br_on_cast threads the refined reference', TestBrOnCastRefinement);
  Test('ref.i31 and i31.get_s/get_u, and the null i31 trap', TestI31);
  Test('a collection mid-construction keeps the fresh aggregate rooted',
    TestMidConstructionCollection);
  Test('a host call round-trips params and results', TestHostCallRoundTrip);
  Test('a host callback trap propagates', TestHostCallTrapPropagates);
  Test('a host callback re-enters guest code', TestHostCallReentrancy);
  Test('M7: extern.convert_any moves a struct into the extern hierarchy, so '
    + 'ref.test flips across the boundary', TestM7ExternConvertCrossHierarchy);
  Test('v128 splat/add/extract_lane computes end to end',
    TestSimdSplatAddExtract);
  Test('v128.store/load round-trips through the memory chokepoint',
    TestSimdMemoryRoundTrip);
  Test('a v128.load out of bounds traps', TestSimdLoadOutOfBounds);
  Test('a mutable v128 global round-trips through global.set/get',
    TestSimdGlobalGetSet);
  Test('a v128 argument and result marshal across two flat slots',
    TestSimdParamResult);
  Test('a wasm->wasm call with an internal v128 param pad marshals args '
    + 'to the padded callee registers', TestSimdCallPaddedParams);
  Test('a return_call with an internal v128 param pad marshals args to the '
    + 'padded callee registers', TestSimdReturnCallPaddedParams);
  Test('a v128-first call signature still marshals (no regression)',
    TestSimdCallVecFirstParamsRegression);
  Test('an entry invoke returns padded results (scalar before v128) across '
    + 'the right slots', TestSimdEntryPaddedResults);
  { Exception handling (Track H). }
  Test('a throw is caught by try_table catch and resumes with the payload',
    TestThrowCatchPayload);
  Test('catch_all catches a throw of any tag', TestCatchAll);
  Test('catch_ref delivers the exnref to its label', TestCatchRefDeliversExnref);
  Test('an uncaught throw raises EWasmException at the host boundary',
    TestUncaughtThrowRaisesException);
  Test('throw_ref re-throws a caught exnref, caught by an outer handler',
    TestThrowRefRethrowCaughtByOuter);
  Test('throw_ref of a null exnref traps null reference',
    TestThrowRefNullTraps);
  Test('catch matches by tag address: tag A is not caught by a clause for B',
    TestTagAddressMatching);
  Test('an exception unwinds across a call, caught in the caller''s try_table',
    TestThrowUnwindsAcrossCall);
  Test('a caught exception whose payload is a ref survives a forced collection',
    TestRefPayloadSurvivesCollection);
  { Baseline-JIT tier seam (O-J1, O-J2, O-J5). }
  Test('the compile-on-hot counter increments once per interpreted call',
    TestCallCountIncrementsPerInterpretedCall);
  Test('a compiled top-level entry dispatches through the JIT hook',
    TestJitHookDispatchedAtEntry);
  Test('a compiled internal callee dispatches through the JIT hook',
    TestJitHookDispatchedForInternalCall);
  Test('compiled entry clears default locals and all GC-visible ref slots',
    TestJitEntryClearsSemanticSlots);
  Test('the JIT register-file and frame offsets match the layout',
    TestJitFrameOffsetsMatchLayout);
  Test('the AOT ABI fingerprint is deterministic and non-zero',
    TestAotAbiFingerprintDeterministic);
end;

begin
  TestRunnerProgram.AddSuite(TInterpTests.Create('Wasm.Interp'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
