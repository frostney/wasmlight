{ Unit suite for Wasm.Jit — the differential milestone and the Wave-2 spine
  (.agent/design/jit-spec.md §11, §12.2, §12.3 Wave 2).

  THE METHOD IS DIFFERENTIAL (ADR-0001, §11). Every test builds a small module,
  runs an export INTERPRETED (the tier of record, the oracle), then force-
  compiles the function and runs the SAME inputs COMPILED, and asserts the two
  are observationally identical: bitwise-equal results (so NaN payloads, ±0, and
  32-bit wrap are all checked), and — for a trap — the same trap message. A
  divergence is a JIT bug the harness catches on the first exercising input.

  Wave 1 proved the spine end to end for i32.add (TestMilestoneAddIdentical).
  Wave 2 grows op coverage: consts, i32/i64 integer arithmetic/logic/shift and
  compares (inlined native A64), div/rem and all float ops (leaf-called into
  Wasm.Interp.Numeric, so NaN bits / rounding / div-rem trap kind+timing are the
  interpreter's by construction), select, control flow (jumps, branches,
  br_table, an if/else, a loop with a back-edge epoch safepoint), and
  unreachable. Each is a self-contained module run under both tiers.

  THE EPOCH INTERRUPT trap IS differentially tested (TestEpochInterruptDiffer-
  ential): an interpreted caller bumps Store.Epoch through a host callback, then
  calls a COMPILED leaf whose loop back-edge must trap 'interrupt' at the same
  point the interpreter would. This exercises the shared per-invocation epoch
  snapshot (jit-spec §6) — the snapshot is seeded once at the outermost entry
  and read by both tiers, so a compiled leaf inherits the invocation's original
  value rather than re-reading the already-bumped epoch. TestLoopSum additionally
  proves the back-edge epoch-CHECK code does not false-trip when the epoch is
  unchanged.

  FPC gotchas (AGENTS.md): every test records an assertion; a generic
  Expect<T>(...) is never the lone statement of an `on..do`. }
program Wasm.Jit.Test;

{$I Shared.inc}

{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  {$DEFINE WASM_JIT_ARM64}
{$ENDIF}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit,
  Wasm.Jit.Arm64,
  Wasm.Module,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Validator;

{ --- byte-assembly helpers (mirrors Wasm.Interp.Test) -------------------- }

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

{ Signed LEB128 (i32.const / i64.const literals). FPC's `shr` is logical, so the
  arithmetic right shift is done with SarInt64 to keep the sign for negatives. }
function SLeb(const AValue: Int64): TWasmBytes;
var
  V: Int64;
  B: Byte;
  More: Boolean;
  Count: Integer;
begin
  Result := nil;
  V := AValue;
  Count := 0;
  repeat
    B := Byte(V and $7F);
    V := SarInt64(V, 7);
    if ((V = 0) and ((B and $40) = 0)) or ((V = -1) and ((B and $40) <> 0)) then
      More := False
    else
    begin
      B := B or $80;
      More := True;
    end;
    SetLength(Result, Count + 1);
    Result[Count] := B;
    Inc(Count);
  until not More;
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

function Sect(const AId: Byte; const ABody: TWasmBytes): TWasmBytes;
begin
  Result := Cat([BLit([AId]), ULeb(UInt32(Length(ABody))), ABody]);
end;

function CodeEntry(const ABody: TWasmBytes): TWasmBytes;
begin
  Result := Cat([ULeb(UInt32(Length(ABody))), ABody]);
end;

function StrBytes(const AName: string): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AName));
  for I := 1 to Length(AName) do
    Result[I - 1] := Byte(AName[I]);
end;

const
  WASM_HEADER: array[0 .. 7] of Byte = ($00, $61, $73, $6D, $01, $00, $00, $00);

{ A one-function module: type signature ASig (a full 0x60... functype), code
  body ABody (locals vector + instructions + end), exported as AName (func 0). }
function OneFunc(const ASig, ABody: TWasmBytes; const AName: string): TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([ASig])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([Cat([ULeb(UInt32(Length(AName))), StrBytes(AName),
      BLit([$00, $00])])])),
    Sect(10, VecOf([CodeEntry(ABody)]))
  ]);
end;

function VBits(const ABits: UInt64): TWasmValue;
begin
  Result.Bits := ABits;
end;

{ The bump host callback for the epoch differential: the one documented cross-
  thread epoch write (ADR-0006), reached synchronously from guest code. }
procedure JitBumpEpochCallback(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  AStore.Epoch := AStore.Epoch + 1;
end;

{ The epoch differential module (jit-spec §6). An interpreted CALLER (it has
  calls, so JitCanCompile declines it) first calls a host that BUMPS the epoch,
  then calls a COMPILED leaf that spins a loop with a safepoint back-edge:

    import "e"."bump" (func)                    ; func 0 (host)
    (func $leaf (local i32)                     ; func 1 — compilable (no calls)
      i32.const 3  local.set 0
      block loop
        local.get 0  i32.eqz  br_if 1           ; forward exit (no safepoint)
        local.get 0  i32.const 1  i32.sub  local.set 0
        br 0                                    ; UNCONDITIONAL back-edge = safepoint
      end end)
    (func $run  call 0  call 1)                 ; func 2 — declined (has calls)

  exported "run" (func 2) and "leaf" (func 1). Because the epoch is bumped
  BETWEEN the outermost entry and the leaf's entry, the leaf's first back-edge
  must trap 'interrupt' under BOTH tiers once the snapshot is shared. }
function EpochModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $00])])),
    Sect(2, VecOf([BLit([$01, $65, $04, $62, $75, $6D, $70, $00, $00])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      BLit([$03, $72, $75, $6E, $00, $02]),
      BLit([$04, $6C, $65, $61, $66, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$01, $01, $7F,
        $41, $03, $21, $00,
        $02, $40, $03, $40,
        $20, $00, $45, $0D, $01,
        $20, $00, $41, $01, $6B, $21, $00,
        $0C, $00,
        $0B, $0B, $0B]),
      CodeEntry([$00, $10, $00, $10, $01, $0B])]))
  ]);
end;

{ --- the milestone module (Wave 1, kept as the anchor) ------------------- }

function AddModuleBytes: TWasmBytes;
begin
  { (func (export "add") (param i32 i32) (result i32) local.get0 local.get1
    i32.add) }
  Result := OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]),
    BLit([$00, $20, $00, $20, $01, $6A, $0B]), 'add');
end;

type
  TInputPair = record
    A, B: Int32;
  end;

  TCallOutcome = record
    Trapped: Boolean;
    Msg: string;
    Bits: UInt64;
  end;

  TJitTests = class(TTestSuite)
  private
    FBytes: TWasmBytes;
    FModule: TWasmModule;
    FIr: TWasmIrModule;
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FImports: TWasmImports;
    FInstance: TWasmModuleInstance;
    FJit: TWasmJitContext;

    procedure BuildAdd;
    function AddAddr: TWasmFuncAddr;
    function CallAdd(const AA, AB: Int32): TWasmValue;

    { The differential driver: build ABytes, run AExport interpreted, force-
      compile it, run it compiled, assert both outcomes are identical. Uses only
      local state so a single test can drive many modules. Returns whether the
      function actually compiled (AFalse = declined, ABoth runs interpreted). }
    function DiffModule(const ABytes: TWasmBytes; const AExport: string;
      const AParams: array of TWasmValue): Boolean;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestSlotSizeMatchesInterp;
    procedure TestMilestoneAddIdentical;
    procedure TestForceCompileSetsEntry;

    procedure TestI32Arith;
    procedure TestI64Arith;
    procedure TestI32Compare;
    procedure TestF64Ops;
    procedure TestF32SqrtNan;
    procedure TestDivRemTraps;
    procedure TestConstsAndConversions;
    procedure TestSelect;
    procedure TestNestedIf;
    procedure TestLoopSum;
    procedure TestBrTable;
    procedure TestUnreachable;
    procedure TestEpochInterruptDifferential;
  end;

procedure TJitTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FIr := nil;
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  FInstance := nil;
  FJit := nil;
  FImports.Funcs := nil;
  FImports.Tables := nil;
  FImports.Mems := nil;
  FImports.Globals := nil;
  FImports.Tags := nil;
  WasmInterpValueSlots := 1 shl 16;
  WasmInterpMaxDepth := 8192;
end;

procedure TJitTests.AfterEach;
begin
  FreeAndNil(FJit);
  FreeAndNil(FStore);
  FreeAndNil(FEngine);
  FreeAndNil(FIr);
  FreeAndNil(FModule);
end;

procedure TJitTests.BuildAdd;
begin
  FBytes := AddModuleBytes;
  DecodeModule(FBytes, FModule);
  FreeAndNil(FIr);
  FIr := ValidateModule(FModule, FBytes);
  FInstance := InstantiateModule(FStore, FIr, @FBytes[0],
    NativeUInt(Length(FBytes)), FImports);
  RegisterInterpreter(FStore);
end;

function TJitTests.AddAddr: TWasmFuncAddr;
var
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  if not FInstance.FindExport('add', Kind, Addr) then
    raise EWasmError.Create('no export named add');
  Result := Addr;
end;

function TJitTests.CallAdd(const AA, AB: Int32): TWasmValue;
var
  Params: array[0 .. 1] of TWasmValue;
  Res: array[0 .. 0] of TWasmValue;
begin
  Params[0] := MakeValueI32(AA);
  Params[1] := MakeValueI32(AB);
  Res[0].Bits := High(UInt64);
  InterpInvoke(FStore, AddAddr, @Params[0], @Res[0]);
  Result := Res[0];
end;

{ --- the differential driver -------------------------------------------- }

function TJitTests.DiffModule(const ABytes: TWasmBytes; const AExport: string;
  const AParams: array of TWasmValue): Boolean;
var
  Module: TWasmModule;
  Ir: TWasmIrModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Imports: TWasmImports;
  Instance: TWasmModuleInstance;
  Jit: TWasmJitContext;
  Kind: TWasmExternKind;
  Addr: UInt32;

  function Invoke: TCallOutcome;
  var
    P: array of TWasmValue;
    Res: array[0 .. 0] of TWasmValue;
    I: Integer;
  begin
    SetLength(P, Length(AParams));
    for I := 0 to High(AParams) do
      P[I] := AParams[I];
    Res[0].Bits := High(UInt64);
    Result.Trapped := False;
    Result.Msg := '';
    Result.Bits := 0;
    try
      if Length(P) = 0 then
        InterpInvoke(Store, Addr, nil, @Res[0])
      else
        InterpInvoke(Store, Addr, @P[0], @Res[0]);
      Result.Bits := Res[0].Bits;
    except
      on E: EWasmTrap do
      begin
        Result.Trapped := True;
        Result.Msg := E.Message;
      end;
    end;
  end;

var
  InterpOut, JitOut: TCallOutcome;
begin
  Module := TWasmModule.Create;
  Engine := TWasmEngine.Create;
  Store := TWasmStore.Create(Engine);
  Ir := nil;
  Jit := nil;
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  Result := False;
  try
    DecodeModule(ABytes, Module);
    Ir := ValidateModule(Module, ABytes);
    Instance := InstantiateModule(Store, Ir, @ABytes[0],
      NativeUInt(Length(ABytes)), Imports);
    RegisterInterpreter(Store);
    if not Instance.FindExport(AExport, Kind, Addr) then
      raise EWasmError.CreateFmt('no export named %s', [AExport]);

    { Reference: interpreter, before any compilation. }
    InterpOut := Invoke;

    { Compile and run again: now every call routes through the machine code. }
    Jit := RegisterJit(Store);
    Result := Jit.ForceCompile(Addr);
    JitOut := Invoke;

    { Observational identity: same trap-or-value, bitwise. }
    Expect<Boolean>(JitOut.Trapped).ToBe(InterpOut.Trapped);
    if InterpOut.Trapped then
      Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg)
    else
      Expect<UInt64>(JitOut.Bits).ToBe(InterpOut.Bits);
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Engine);
    FreeAndNil(Ir);
    FreeAndNil(Module);
  end;
end;

{ --- the layout guard --------------------------------------------------- }

procedure TJitTests.TestSlotSizeMatchesInterp;
begin
  Expect<NativeUInt>(WasmJitFrameOffsets.ValueSlotSize)
    .ToBe(NativeUInt(ARM64_SLOT_SIZE));
end;

{ --- force-compile sets the seam --------------------------------------- }

procedure TJitTests.TestForceCompileSetsEntry;
var
  Compiled: Boolean;
begin
  BuildAdd;
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(False);

  FJit := RegisterJit(FStore);
  Compiled := FJit.ForceCompile(AddAddr);

  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(True);
  Expect<Boolean>(FJit.ForceCompile(AddAddr)).ToBe(True);
  {$ELSE}
  Expect<Boolean>(Compiled).ToBe(False);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(False);
  {$ENDIF}
end;

{ --- THE differential milestone (Wave 1) -------------------------------- }

procedure TJitTests.TestMilestoneAddIdentical;
const
  Inputs: array[0 .. 4] of TInputPair = (
    (A: 17; B: 25),
    (A: 40; B: 2),
    (A: 0; B: 0),
    (A: -1; B: 1),
    (A: MaxInt; B: 1)
  );
var
  InterpBits: array[0 .. 4] of UInt64;
  I: Integer;
  V: TWasmValue;
  Compiled: Boolean;
begin
  BuildAdd;
  for I := 0 to High(Inputs) do
    InterpBits[I] := CallAdd(Inputs[I].A, Inputs[I].B).Bits;

  V.Bits := InterpBits[0];
  Expect<Int32>(V.I32).ToBe(42);

  FJit := RegisterJit(FStore);
  Compiled := FJit.ForceCompile(AddAddr);

  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(True);
  for I := 0 to High(Inputs) do
  begin
    V := CallAdd(Inputs[I].A, Inputs[I].B);
    Expect<UInt64>(V.Bits).ToBe(InterpBits[I]);
  end;
  V := CallAdd(17, 25);
  Expect<Int32>(V.I32).ToBe(42);
  V := CallAdd(MaxInt, 1);
  Expect<Int32>(V.I32).ToBe(Low(Int32));
  {$ELSE}
  Expect<Boolean>(Compiled).ToBe(False);
  for I := 0 to High(Inputs) do
  begin
    V := CallAdd(Inputs[I].A, Inputs[I].B);
    Expect<UInt64>(V.Bits).ToBe(InterpBits[I]);
  end;
  {$ENDIF}
end;

{ --- Wave 2: numeric spine ---------------------------------------------- }

{ Build a (param i32 i32)(result i32) function whose body is
  `local.get0 local.get1 OP`. }
function I32BinModule(const AOp: Byte; const AName: string): TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]),
    BLit([$00, $20, $00, $20, $01, AOp, $0B]), AName);
end;

function I64BinModule(const AOp: Byte; const AName: string): TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7E, $7E, $01, $7E]),
    BLit([$00, $20, $00, $20, $01, AOp, $0B]), AName);
end;

procedure TJitTests.TestI32Arith;
const
  Ops: array[0 .. 12] of Byte = (
    $6A, $6B, $6C,          { add sub mul }
    $71, $72, $73,          { and or xor }
    $74, $75, $76,          { shl shr_s shr_u }
    $77, $78,               { rotl rotr }
    $6E, $70);              { div_u rem_u (leaf, non-trapping here) }
  Pairs: array[0 .. 4] of TInputPair = (
    (A: 12; B: 5),
    (A: -7; B: 3),
    (A: Integer($FFFFFFFF); B: 33),   { shift count masks to 1 }
    (A: 100; B: 7),
    (A: Integer($80000000); B: -1));
var
  I, J: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(Ops) do
    for J := 0 to High(Pairs) do
    begin
      Compiled := DiffModule(I32BinModule(Ops[I], 'op'), 'op',
        [MakeValueI32(Pairs[J].A), MakeValueI32(Pairs[J].B)]);
      {$IFDEF WASM_JIT_ARM64}
      Expect<Boolean>(Compiled).ToBe(True);
      {$ELSE}
      Expect<Boolean>(Compiled).ToBe(False);
      {$ENDIF}
    end;
end;

procedure TJitTests.TestI64Arith;
const
  Ops: array[0 .. 10] of Byte = (
    $7C, $7D, $7E,          { add sub mul }
    $83, $84, $85,          { and or xor }
    $86, $87, $88,          { shl shr_s shr_u }
    $89, $8A);              { rotl rotr }
var
  I: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(Ops) do
  begin
    Compiled := DiffModule(I64BinModule(Ops[I], 'op'), 'op',
      [VBits(UInt64($0123456789ABCDEF)), VBits(UInt64(69))]);
    {$IFDEF WASM_JIT_ARM64}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
    { Also a negative/large second operand to exercise the sign paths. }
    Compiled := DiffModule(I64BinModule(Ops[I], 'op'), 'op',
      [VBits(UInt64($FFFFFFFFFFFFFFFF)), VBits(UInt64(200))]);
    {$IFDEF WASM_JIT_ARM64}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestI32Compare;
const
  { eqz is unary; the rest are binary. }
  BinOps: array[0 .. 9] of Byte = (
    $46, $47,               { eq ne }
    $48, $49, $4A, $4B,     { lt_s lt_u gt_s gt_u }
    $4C, $4D, $4E, $4F);    { le_s le_u ge_s ge_u }
  Pairs: array[0 .. 3] of TInputPair = (
    (A: 5; B: 5),
    (A: -1; B: 1),
    (A: 1; B: -1),
    (A: Integer($80000000); B: 1));
var
  I, J: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(BinOps) do
    for J := 0 to High(Pairs) do
    begin
      Compiled := DiffModule(I32BinModule(BinOps[I], 'op'), 'op',
        [MakeValueI32(Pairs[J].A), MakeValueI32(Pairs[J].B)]);
      {$IFDEF WASM_JIT_ARM64}
      Expect<Boolean>(Compiled).ToBe(True);
      {$ENDIF}
    end;

  { i32.eqz (0x45): (param i32)(result i32) local.get0 i32.eqz. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]),
      BLit([$00, $20, $00, $45, $0B]), 'eqz'), 'eqz', [MakeValueI32(0)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]),
      BLit([$00, $20, $00, $45, $0B]), 'eqz'), 'eqz', [MakeValueI32(9)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

function F64BinModule(const AOp: Byte; const AName: string): TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7C, $7C, $01, $7C]),
    BLit([$00, $20, $00, $20, $01, AOp, $0B]), AName);
end;

procedure TJitTests.TestF64Ops;
const
  Ops: array[0 .. 6] of Byte = (
    $A0, $A1, $A2, $A3,     { add sub mul div }
    $A4, $A5,               { min max }
    $A6);                   { copysign }
  { A signalling-ish NaN payload and a quiet NaN, plus ordinary values. Both
    tiers must canonicalize a NaN result to the positive canonical pattern. }
  QNAN = UInt64($7FF8000000000001);
var
  I: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(Ops) do
  begin
    { normal x normal }
    Compiled := DiffModule(F64BinModule(Ops[I], 'op'), 'op',
      [MakeValueF64(3.5), MakeValueF64(-1.25)]);
    {$IFDEF WASM_JIT_ARM64}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
    { NaN x normal — the NaN-bit identity case (§13 item 1). }
    Compiled := DiffModule(F64BinModule(Ops[I], 'op'), 'op',
      [VBits(QNAN), MakeValueF64(2.0)]);
    {$IFDEF WASM_JIT_ARM64}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
    { division/other by zero -> inf or NaN, never a trap for floats. }
    Compiled := DiffModule(F64BinModule(Ops[I], 'op'), 'op',
      [MakeValueF64(1.0), MakeValueF64(0.0)]);
    {$IFDEF WASM_JIT_ARM64}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestF32SqrtNan;
var
  Compiled: Boolean;
begin
  { (param f32)(result f32) local.get0 f32.sqrt (0x91). sqrt(-4) is a canonical
    NaN both tiers; sqrt(16) is 4.0. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7D, $01, $7D]),
      BLit([$00, $20, $00, $91, $0B]), 'sq'), 'sq', [MakeValueF32(16.0)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7D, $01, $7D]),
      BLit([$00, $20, $00, $91, $0B]), 'sq'), 'sq', [MakeValueF32(-4.0)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

procedure TJitTests.TestDivRemTraps;
var
  Compiled: Boolean;
begin
  { div_s (0x6D): divide-by-zero and INT_MIN/-1 overflow both trap, same
    message, same tier; a normal case returns. }
  Compiled := DiffModule(I32BinModule($6D, 'ds'), 'ds',
    [MakeValueI32(20), MakeValueI32(6)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  DiffModule(I32BinModule($6D, 'ds'), 'ds',
    [MakeValueI32(10), MakeValueI32(0)]);            { divide by zero }
  DiffModule(I32BinModule($6D, 'ds'), 'ds',
    [MakeValueI32(Integer($80000000)), MakeValueI32(-1)]); { overflow }

  { rem_s (0x6F): divide-by-zero traps; INT_MIN % -1 = 0 does NOT trap. }
  DiffModule(I32BinModule($6F, 'rs'), 'rs',
    [MakeValueI32(10), MakeValueI32(0)]);            { divide by zero }
  DiffModule(I32BinModule($6F, 'rs'), 'rs',
    [MakeValueI32(Integer($80000000)), MakeValueI32(-1)]); { -> 0, no trap }

  { i64 div_s (0x7F) zero + overflow. }
  DiffModule(I64BinModule($7F, 'ds64'), 'ds64',
    [VBits(5), VBits(0)]);
  DiffModule(I64BinModule($7F, 'ds64'), 'ds64',
    [VBits(UInt64($8000000000000000)), VBits(UInt64($FFFFFFFFFFFFFFFF))]);
end;

procedure TJitTests.TestConstsAndConversions;
var
  Compiled: Boolean;
begin
  { i32.const then wrap-independent return: (result i32) i32.const 0xABCD. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $00, $01, $7F]),
      Cat([BLit([$00, $41]), SLeb(305419896), BLit([$0B])]),  { 0x12345678 }
      'k'), 'k', []);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { i64.const negative: (result i64) i64.const -3. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $00, $01, $7E]),
      Cat([BLit([$00, $42]), SLeb(-3), BLit([$0B])]), 'k64'), 'k64', []);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { i64.extend_i32_s (0xAC): (param i32)(result i64) local.get0 i64.extend_i32_s.
    Leaf-called conversion. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7E]),
      BLit([$00, $20, $00, $AC, $0B]), 'ext'), 'ext',
    [MakeValueI32(-5)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { f64.convert_i32_s (0xB7) then i32.trunc_f64_s (0xAA) round-trip a value:
    (param i32)(result i32) local.get0 f64.convert_i32_s i32.trunc_f64_s. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]),
      BLit([$00, $20, $00, $B7, $AA, $0B]), 'rt'), 'rt',
    [MakeValueI32(-1234)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { i32.trunc_f64_s of a NaN traps 'invalid conversion to integer', same both
    tiers (the leaf calls TrapNow). Feed a NaN through reinterpret-free: use a
    (param f64)(result i32) local.get0 i32.trunc_f64_s. }
  DiffModule(
    OneFunc(BLit([$60, $01, $7C, $01, $7F]),
      BLit([$00, $20, $00, $AA, $0B]), 'tr'), 'tr',
    [VBits(UInt64($7FF8000000000000))]);   { NaN -> trap }
  { And an out-of-range +inf -> 'integer overflow'. }
  DiffModule(
    OneFunc(BLit([$60, $01, $7C, $01, $7F]),
      BLit([$00, $20, $00, $AA, $0B]), 'tr'), 'tr',
    [VBits(UInt64($7FF0000000000000))]);   { +inf -> trap }
end;

procedure TJitTests.TestSelect;
var
  Compiled: Boolean;
begin
  { (param i32 i32 i32)(result i32) local.get0 local.get1 local.get2 select.
    select (0x1B) picks arg0 if the condition (arg2) is non-zero. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $03, $7F, $7F, $7F, $01, $7F]),
      BLit([$00, $20, $00, $20, $01, $20, $02, $1B, $0B]), 'sel'), 'sel',
    [MakeValueI32(111), MakeValueI32(222), MakeValueI32(1)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  Compiled := DiffModule(
    OneFunc(BLit([$60, $03, $7F, $7F, $7F, $01, $7F]),
      BLit([$00, $20, $00, $20, $01, $20, $02, $1B, $0B]), 'sel'), 'sel',
    [MakeValueI32(111), MakeValueI32(222), MakeValueI32(0)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

procedure TJitTests.TestNestedIf;
const
  Pairs: array[0 .. 2] of TInputPair = (
    (A: 9; B: 4),
    (A: 4; B: 9),
    (A: 5; B: 5));
var
  Body: TWasmBytes;
  I: Integer;
  Compiled: Boolean;
begin
  { (param i32 i32)(result i32): if a>b then a-b else b-a (an if/else, which
    lowers to branch_if_not + jumps + merge moves). }
  Body := BLit([
    $00,                    { no locals }
    $20, $00, $20, $01, $4A,{ get0 get1 gt_s }
    $04, $7F,               { if (result i32) }
    $20, $00, $20, $01, $6B,{ get0 get1 sub }
    $05,                    { else }
    $20, $01, $20, $00, $6B,{ get1 get0 sub }
    $0B,                    { end if }
    $0B]);                  { end func }
  for I := 0 to High(Pairs) do
  begin
    Compiled := DiffModule(
      OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]), Body, 'ad'), 'ad',
      [MakeValueI32(Pairs[I].A), MakeValueI32(Pairs[I].B)]);
    {$IFDEF WASM_JIT_ARM64}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestLoopSum;
var
  Body: TWasmBytes;
  Compiled: Boolean;
begin
  { (param i32)(result i32): sum i for i in n..1 via a loop whose back-edge
    carries the epoch safepoint (§6). This exercises the emitted epoch-check on
    every iteration without tripping it (Store.Epoch is unchanged), and proves
    the compiled loop result matches the interpreter's. }
  Body := BLit([
    $01, $01, $7F,          { 1 local group: 1 x i32 (the accumulator, reg 1) }
    $02, $40,               { block void (L1) }
    $03, $40,               { loop void (L0) }
    $20, $00, $45,          { local.get0; i32.eqz }
    $0D, $01,               { br_if 1 -> break out of L1 }
    $20, $01, $20, $00, $6A,{ local.get1; local.get0; i32.add }
    $21, $01,               { local.set1 (acc += i) }
    $20, $00, $41, $01, $6B,{ local.get0; i32.const 1; i32.sub }
    $21, $00,               { local.set0 (i -= 1) }
    $0C, $00,               { br 0 -> loop back-edge (safepoint) }
    $0B,                    { end loop }
    $0B,                    { end block }
    $20, $01,               { local.get1 (return acc) }
    $0B]);                  { end func }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'sum'), 'sum',
    [MakeValueI32(0)]);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  { A handful of back-edges. }
  DiffModule(OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'sum'), 'sum',
    [MakeValueI32(5)]);
  { Many back-edges -> the epoch check runs 100 times and never false-trips. }
  DiffModule(OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'sum'), 'sum',
    [MakeValueI32(100)]);
end;

procedure TJitTests.TestBrTable;
var
  Body: TWasmBytes;
  Compiled: Boolean;
  Sel: Integer;
begin
  { (param i32)(result i32): local defaults 30; br_table selects: 0 -> 10,
    anything else -> 30. }
  Body := BLit([
    $01, $01, $7F,          { local reg 1 }
    $41, $1E, $21, $01,     { i32.const 30; local.set1 }
    $02, $40,               { block (L1) }
    $02, $40,               { block (L0) }
    $20, $00,               { local.get0 (selector) }
    $0E, $01, $00, $01,     { br_table [0] default 1 }
    $0B,                    { end L0 }
    $41, $0A, $21, $01,     { i32.const 10; local.set1 }
    $0C, $00,               { br 0 -> L1 end (L0 already closed) }
    $0B,                    { end L1 }
    $20, $01,               { local.get1 }
    $0B]);                  { end func }
  for Sel := 0 to 3 do
  begin
    Compiled := DiffModule(
      OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'bt'), 'bt',
      [MakeValueI32(Sel)]);
    {$IFDEF WASM_JIT_ARM64}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestUnreachable;
var
  Compiled: Boolean;
begin
  { (result i32) unreachable — both tiers trap 'unreachable'. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $00, $01, $7F]), BLit([$00, $00, $0B]), 'boom'),
    'boom', []);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

{ FIX 1 (jit-spec §6): the epoch snapshot is shared per outermost invocation
  and read by BOTH tiers. An interpreted caller bumps the epoch via a host call
  then calls a compiled leaf; the leaf's back-edge must trap 'interrupt' exactly
  as the interpreter would. Before the fix the compiled prologue re-snapshotted
  the already-bumped epoch and did NOT trap — the differential gap this closes.
  This is the epoch-interrupt case Wave 2 explicitly deferred to Wave 3. }
procedure TJitTests.TestEpochInterruptDifferential;

  function RunOnce(const ACompileLeaf: Boolean): TCallOutcome;
  var
    Bytes: TWasmBytes;
    Module: TWasmModule;
    Ir: TWasmIrModule;
    Engine: TWasmEngine;
    Store: TWasmStore;
    Imports: TWasmImports;
    Instance: TWasmModuleInstance;
    Jit: TWasmJitContext;
    Canon, TypeIds: TWasmEngineTypeIds;
    HostAddr, LeafAddr, RunAddr: TWasmFuncAddr;
    Kind: TWasmExternKind;
    Addr: UInt32;
    Res: array[0 .. 0] of TWasmValue;
  begin
    Result.Trapped := False;
    Result.Msg := '';
    Result.Bits := 0;
    Bytes := EpochModuleBytes;
    Module := TWasmModule.Create;
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Ir := nil;
    Jit := nil;
    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    try
      DecodeModule(Bytes, Module);
      Ir := ValidateModule(Module, Bytes);
      { The host import needs its engine type id, so intern before instantiate. }
      Engine.InternModule(Ir, Canon, TypeIds);
      HostAddr := Store.AddHostFunc(TypeIds[0], @JitBumpEpochCallback, nil);
      SetLength(Imports.Funcs, 1);
      Imports.Funcs[0] := HostAddr;
      Instance := InstantiateModule(Store, Ir, @Bytes[0],
        NativeUInt(Length(Bytes)), Imports);
      RegisterInterpreter(Store);

      if not Instance.FindExport('leaf', Kind, Addr) then
        raise EWasmError.Create('no export named leaf');
      LeafAddr := Addr;
      if not Instance.FindExport('run', Kind, Addr) then
        raise EWasmError.Create('no export named run');
      RunAddr := Addr;

      if ACompileLeaf then
      begin
        Jit := RegisterJit(Store);
        { The leaf compiles (no calls); the caller declines (it HAS calls) and
          stays interpreted — exactly the interpreted-caller -> compiled-leaf
          shape the fix targets. }
        Expect<Boolean>(Jit.ForceCompile(LeafAddr)).ToBe(True);
        Expect<Boolean>(Jit.ForceCompile(RunAddr)).ToBe(False);
      end;

      Store.Epoch := 0;
      Store.EpochSnapshot := 0;
      Res[0].Bits := 0;
      try
        InterpInvoke(Store, RunAddr, nil, @Res[0]);
      except
        on E: EWasmTrap do
        begin
          Result.Trapped := True;
          Result.Msg := E.Message;
        end;
      end;
    finally
      FreeAndNil(Jit);
      FreeAndNil(Store);
      FreeAndNil(Engine);
      FreeAndNil(Ir);
      FreeAndNil(Module);
    end;
  end;

var
  InterpOut, JitOut: TCallOutcome;
begin
  { The oracle: fully interpreted, a mid-invocation epoch bump traps at the
    leaf's back-edge. }
  InterpOut := RunOnce(False);
  Expect<Boolean>(InterpOut.Trapped).ToBe(True);
  Expect<Boolean>(Pos('interrupt', InterpOut.Msg) > 0).ToBe(True);

  { The fix: the compiled leaf inherits the invocation's original snapshot and
    traps identically — same outcome, same message. }
  JitOut := RunOnce(True);
  {$IFDEF WASM_JIT_ARM64}
  Expect<Boolean>(JitOut.Trapped).ToBe(True);
  Expect<Boolean>(Pos('interrupt', JitOut.Msg) > 0).ToBe(True);
  Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg);
  {$ELSE}
  { Off the JIT leg the leaf runs interpreted too, so both sides agree by
    construction. }
  Expect<Boolean>(JitOut.Trapped).ToBe(InterpOut.Trapped);
  Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg);
  {$ENDIF}
end;

procedure TJitTests.SetupTests;
begin
  Test('slot stride matches the interpreter frame', TestSlotSizeMatchesInterp);
  Test('force-compile sets the compiled entry', TestForceCompileSetsEntry);
  Test('JIT i32.add is bitwise identical to the interpreter',
    TestMilestoneAddIdentical);
  Test('i32 arithmetic/logic/shift match the interpreter', TestI32Arith);
  Test('i64 arithmetic/logic/shift match the interpreter', TestI64Arith);
  Test('i32 compares and eqz match the interpreter', TestI32Compare);
  Test('f64 ops (incl. NaN) match the interpreter bitwise', TestF64Ops);
  Test('f32.sqrt (incl. canonical NaN) matches the interpreter',
    TestF32SqrtNan);
  Test('div/rem trap identically (zero, overflow, rem no-trap)',
    TestDivRemTraps);
  Test('consts and conversions match, incl. trunc traps',
    TestConstsAndConversions);
  Test('select matches the interpreter', TestSelect);
  Test('an if/else matches the interpreter', TestNestedIf);
  Test('a loop with a back-edge epoch safepoint matches', TestLoopSum);
  Test('br_table matches the interpreter', TestBrTable);
  Test('unreachable traps identically', TestUnreachable);
  Test('a shared epoch snapshot traps interrupt in a compiled leaf identically',
    TestEpochInterruptDifferential);
end;

begin
  TestRunnerProgram.AddSuite(TJitTests.Create('Wasm.Jit'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
