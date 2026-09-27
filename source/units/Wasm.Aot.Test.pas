{ Unit suite for Wasm.Aot — the Wave-1 AOT milestone and the load-time guards
  (aot-spec §7.2, §4, §8).

  THE MILESTONE (§7.2). Build the JIT milestone function
    (func (export "add") (param i32 i32) (result i32) local.get0 local.get1
     i32.add),
  decode + validate it, AOT-COMPILE the function, and SERIALIZE it to a `.waot`
  byte buffer. Then in a FRESH store: re-decode + re-validate the SAME module
  bytes (the security boundary), AotLoadAndWire the artifact, and invoke
  add(17,25) — which must go through the LOADED machine code (CompiledEntry set
  from the artifact, NOT re-JITted) and return 42, bit-identical to the
  interpreter across several input pairs. This exercises the whole serialize ->
  guard -> relocate(=fill-table) -> map -> execute spine at minimum size.

  PROOF IT CAME FROM THE ARTIFACT, NOT A FRESH JIT. The load path never calls
  ForceCompile/JitForceCompile; CompiledEntry is wired by LoadPrecompiled from
  the artifact's bytes. The test reads back the EXECUTABLE memory at CompiledEntry
  and asserts it equals the artifact's serialized code bytes — so the running
  code IS the artifact. As bonuses (§7.2): the reloc table is EMPTY, and the
  artifact's code is byte-identical to a fresh JIT staging of the same function
  (the position-independence claim, mechanically checked).

  THE GUARDS (§2.3, §8). A wrong-irFormatVer artifact, a wrong-arch artifact, a
  corrupted-checksum artifact, and an artifact loaded against a DIFFERENT module
  (moduleHash mismatch) are each rejected with their DISTINCT reason and wire
  nothing — the module then runs interpreted, always correct.

  Every test asserts an outcome (never only Fail on a bad path), and no generic
  Expect<T>(...) is the lone statement of an `on..do` (AGENTS.md FPC gotchas). }
program Wasm.Aot.Test;

{$I Shared.inc}
{$POINTERMATH ON}

{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  {$DEFINE WASM_JIT_ARM64}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUX86_64)}
  {$DEFINE WASM_JIT_X64}
{$ENDIF}
{$IF DEFINED(WASM_JIT_ARM64) OR DEFINED(WASM_JIT_X64)}
  {$DEFINE WASM_JIT_BACKEND}
{$ENDIF}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Wasm.Aot,
  Wasm.Aot.Artifact,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit,
  Wasm.Jit.CodeBuffer,
  Wasm.Jit.X64,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Target;

{ --- byte-assembly helpers (mirrors Wasm.Jit.Test) ---------------------- }

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

{ A one-function module: functype ASig, code body ABody, exported as AName. }
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

{ The milestone module (§7.2): (func (export "add") (param i32 i32) (result i32)
  local.get0 local.get1 i32.add). }
function AddModuleBytes: TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]),
    BLit([$00, $20, $00, $20, $01, $6A, $0B]), 'add');
end;

{ A DIFFERENT module (i32.sub, different export name) — used for the moduleHash
  guard: loading the add-artifact against these bytes must be rejected. }
function SubModuleBytes: TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]),
    BLit([$00, $20, $00, $20, $01, $6B, $0B]), 'sub');
end;

{ run(n): three `acc += 1` then a loop acc := acc*3 + i while ++i < n. }
function LoopModuleBytes: TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $01, $7F, $01, $7F]),
    BLit([$01, $02, $7F,
      $20, $01, $41, $01, $6A, $21, $01,
      $20, $01, $41, $01, $6A, $21, $01,
      $20, $01, $41, $01, $6A, $21, $01,
      $03, $40,
      $20, $01, $41, $03, $6C, $20, $02, $6A, $21, $01,
      $20, $02, $41, $01, $6A, $22, $02, $20, $00, $49, $0D, $00,
      $0B,
      $20, $01, $0B]), 'run');
end;

function OracleLoop(const AN: UInt32): UInt32;
var
  I: UInt32;
begin
  {$PUSH}
  {$OVERFLOWCHECKS OFF}
  {$RANGECHECKS OFF}
  Result := 3;
  I := 0;
  repeat
    Result := Result * 3 + I;
    Inc(I);
  until I >= AN;
  {$POP}
end;

procedure AotBumpEpochCallback(const AStore: TWasmStore;
  const AData: Pointer; const AParams: PWasmValue;
  const AResults: PWasmValue);
begin
  AStore.Epoch := AStore.Epoch + 1;
end;

{ Host bump followed by acyclic non-tail self recursion. Calls are not epoch
  safepoints, so an AOT-loaded native self-call must not trap merely because
  Epoch differs from the invocation snapshot. }
function EpochAcyclicRecModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $00]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(2, VecOf([BLit([$01, $65, $04, $62, $75, $6D, $70, $00, $00])])),
    Sect(3, VecOf([BLit([$01]), BLit([$01])])),
    Sect(7, VecOf([
      BLit([$03, $72, $65, $63, $00, $01]),
      BLit([$03, $72, $75, $6E, $00, $02])])),
    Sect(10, VecOf([
      CodeEntry([$00,
        $20, $00, $45, $04, $40, $41, $00, $0F, $0B,
        $20, $00, $41, $01, $6B, $10, $01, $41, $01, $6A,
        $0B]),
      CodeEntry([$00, $10, $00, $20, $00, $10, $01, $0B])]))
  ]);
end;

{ One export descriptor: name, kind byte $00 (func), function index. }
function FuncExport(const AName: string; const AIndex: UInt32): TWasmBytes;
begin
  Result := Cat([ULeb(UInt32(Length(AName))), StrBytes(AName), BLit([$00]),
    ULeb(AIndex)]);
end;

function RepeatByte(const AByte: Byte; const ACount: Integer): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := AByte;
end;

function RepeatBytes(const AItem: TWasmBytes; const ACount: Integer): TWasmBytes;
var
  I: Integer;
begin
  Result := nil;
  for I := 1 to ACount do
    Result := Cat([Result, AItem]);
end;

function U64Le(const AValue: UInt64): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, 8);
  for I := 0 to 7 do
    Result[I] := Byte(AValue shr (8 * I));
end;

const
  { One past the 1024-slot inline tail and marshal buffers. }
  WIDE_ARITY = 1025;
  { $wide's result: argument 1024 minus argument 3. }
  WIDE_RESULT = 1021;
  { 513 v128 results: 1026 flat slots, past the inline buffers. }
  WIDE_V128 = 513;
  { What "widecatch" returns when the throw beneath the wide call is caught;
    7 means the call returned normally. }
  WIDE_CAUGHT = 42;
  { The functions the mixed-tier test declines by hand: they run
    interpreted beside compiled callers and callees. }
  WIDE_DECLINED: array[0 .. 3] of Integer = (3, 6, 8, 10);

{ `i32.const AValue` for 0 <= AValue < 8192: a one- or two-byte SLEB128
  whose last byte has the sign bit (0x40) clear. }
function I32ConstSmall(const AValue: Integer): TWasmBytes;
begin
  if AValue < 64 then
    Result := BLit([$41, Byte(AValue)])
  else
    Result := BLit([$41, Byte((AValue and $7F) or $80), Byte(AValue shr 7)]);
end;

function WideLane(const AK, ALane: Integer): UInt64;
begin
  Result := UInt64(AK) * 7919 + UInt64(ALane) * 104729 + 1;
end;

{ A twelve-function module for the multi-function proof (aot-spec §7.3),
  every wide block one past the 1024-slot inline buffers:
    f0  "add"        (i32 i32)->i32   local.get0 local.get1 i32.add
    f1  "addcaller"  (i32 i32)->i32   call 0
    f2  $wide        (i32×1025)->i32  local.get 1024 - local.get 3
    f3  "widetail"   ()->i32          return_call 2, arguments 0..1024
    f4  "widecaller" ()->i32          call 3
    f5  "widebounce" ()->i32          return_call 3
    f6  "widecall"   ()->i32          call 2, arguments 0..1024
    f7  $widethrow   (i32×1025)->i32  throw tag 0
    f8  "widecatch"  ()->i32          try_table catch_all around call 7
    f9  $manyv       ()->(v128×513)   513 v128.const
    f10 $tailv       ()->(v128×513)   return_call 9
    f11 "wideresult" ()->i64          call 10; fold every lane
  Strict compilation compiles all twelve; the mixed-tier test declines
  WIDE_DECLINED by hand, so interpreted f3/f6/f8/f10 meet compiled callers,
  callees, a tail bounce, a throw, and a wide result block. }
function MultiFuncModuleBytes: TWasmBytes;
var
  TypeWide, TypeVecOut, Args, VecConsts: TWasmBytes;
  I: Integer;
begin
  TypeWide := Cat([BLit([$60]), ULeb(WIDE_ARITY), RepeatByte($7F, WIDE_ARITY),
    BLit([$01, $7F])]);
  TypeVecOut := Cat([BLit([$60, $00]), ULeb(WIDE_V128),
    RepeatByte($7B, WIDE_V128)]);
  Args := nil;
  for I := 0 to WIDE_ARITY - 1 do
    Args := Cat([Args, I32ConstSmall(I)]);
  VecConsts := nil;
  for I := 0 to WIDE_V128 - 1 do
    VecConsts := Cat([VecConsts, BLit([$FD, $0C]), U64Le(WideLane(I, 0)),
      U64Le(WideLane(I, 1))]);
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $02, $7F, $7F, $01, $7F]),   { 0: (i32 i32) -> i32 }
      BLit([$60, $00, $01, $7F]),             { 1: () -> i32 }
      TypeWide,                               { 2: (i32×1025) -> i32 }
      BLit([$60, $00, $00]),                  { 3: () -> (), the tag }
      TypeVecOut,                             { 4: () -> (v128×513) }
      BLit([$60, $00, $01, $7E])])),          { 5: () -> i64 }
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$02]), BLit([$01]),
      BLit([$01]), BLit([$01]), BLit([$01]), BLit([$02]), BLit([$01]),
      BLit([$04]), BLit([$04]), BLit([$05])])),
    Sect(13, VecOf([BLit([$00, $03])])),
    Sect(7, VecOf([
      FuncExport('add', 0),
      FuncExport('addcaller', 1),
      FuncExport('widetail', 3),
      FuncExport('widecaller', 4),
      FuncExport('widebounce', 5),
      FuncExport('widecall', 6),
      FuncExport('widecatch', 8),
      FuncExport('wideresult', 11)])),
    Sect(10, VecOf([
      CodeEntry(BLit([$00, $20, $00, $20, $01, $6A, $0B])),
      CodeEntry(BLit([$00, $20, $00, $20, $01, $10, $00, $0B])),
      { local.get 1024; local.get 3; i32.sub }
      CodeEntry(Cat([BLit([$00, $20]), ULeb(WIDE_ARITY - 1),
        BLit([$20, $03, $6B, $0B])])),
      CodeEntry(Cat([BLit([$00]), Args, BLit([$12, $02, $0B])])),
      CodeEntry(BLit([$00, $10, $03, $0B])),
      CodeEntry(BLit([$00, $12, $03, $0B])),
      CodeEntry(Cat([BLit([$00]), Args, BLit([$10, $02, $0B])])),
      CodeEntry(BLit([$00, $08, $00, $0B])),
      { block (try_table (catch_all 0) args call 7 drop i32.const 7 return)
        i32.const 42 }
      CodeEntry(Cat([BLit([$00, $02, $40, $1F, $40, $01, $02, $00]), Args,
        BLit([$10, $07, $1A, $41, $07, $0F, $0B, $0B, $41, WIDE_CAUGHT,
          $0B])])),
      CodeEntry(Cat([BLit([$00]), VecConsts, BLit([$0B])])),
      CodeEntry(BLit([$00, $12, $09, $0B])),
      { call 10; 512 x i64x2.sub folds v_k - acc from the top; then
        lane0 xor rotl(lane1, 17) through v128 local 0 }
      CodeEntry(Cat([BLit([$01, $01, $7B, $10, $0A]),
        RepeatBytes(BLit([$FD, $D1, $01]), WIDE_V128 - 1),
        BLit([$21, $00, $20, $00, $FD, $1D, $00, $20, $00, $FD, $1D, $01,
          $42, $11, $89, $85, $0B])]))]))
  ]);
end;

{ Re-serialize AArtifact with every function in AIndices recorded as
  declined — the shape a `.waot` cache records for interpreter fallback. No
  valid module declines on a backend host any more, so the mixed-tier load
  is exercised on hand-declined records. }
function DeclineArtifactRecords(const AArtifact: TWasmBytes;
  const AIndices: array of Integer): TWasmBytes;
var
  Parsed: TWasmAotArtifact;
  Params: TWasmAotWriteParams;
  I: Integer;
begin
  if ParseAotArtifact(AArtifact, Parsed) <> aprOk then
    raise EWasmError.Create('DeclineArtifactRecords: artifact does not parse');
  for I := 0 to High(AIndices) do
  begin
    Parsed.Funcs[AIndices[I]].Compiled := False;
    Parsed.Funcs[AIndices[I]].Code := nil;
    Parsed.Funcs[AIndices[I]].Relocs := nil;
    Parsed.Funcs[AIndices[I]].EntryOffset := 0;
  end;
  Params.IrFormatVer := Parsed.Header.IrFormatVer;
  Params.TargetArch := Parsed.Header.TargetArch;
  Params.Flags := Parsed.Header.Flags;
  Params.AbiFingerprint := Parsed.Header.AbiFingerprint;
  Params.ModuleHash := Parsed.Header.ModuleHash;
  Result := WriteAotArtifact(Params, Parsed.Funcs);
end;

{ 2048 i32 locals — past the historical Arm64 short-form slot cap. }
function LargeFrameModuleBytes: TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $00, $01, $7F]),
    Cat([
      BLit([$01]),
      ULeb(2048),
      BLit([$7F, $41, 42, $21]),
      ULeb(2047),
      BLit([$20]),
      ULeb(2047),
      BLit([$0B])
    ]), 'big');
end;

{ try_table catch_all with no throw: handler tables compile, so strict
  compile must publish native code for every function. }
function TryTableModuleBytes: TWasmBytes;
var
  Type0, Type1: TWasmBytes;
  Body0, Body1, Body2, Body3: TWasmBytes;
begin
  Type0 := BLit([$60, $02, $7F, $7F, $01, $7F]);
  Type1 := BLit([$60, $00, $01, $7F]);
  Body0 := BLit([$00, $20, $00, $20, $01, $6A, $0B]);
  Body1 := BLit([$00, $20, $00, $20, $01, $10, $00, $0B]);
  Body2 := BLit([$00, $02, $40, $1F, $40, $01, $02, $00, $0B, $0B, $41, $07, $0B]);
  Body3 := BLit([$00, $10, $02, $0B]);
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([Type0, Type1])),
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$01]), BLit([$01])])),
    Sect(7, VecOf([
      FuncExport('add', 0),
      FuncExport('addcaller', 1),
      FuncExport('handled', 2),
      FuncExport('handledcaller', 3)])),
    Sect(10, VecOf([CodeEntry(Body0), CodeEntry(Body1), CodeEntry(Body2),
      CodeEntry(Body3)]))
  ]);
end;

function TempArtifactPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight-aot-strict-' + IntToStr(GetProcessID) + '-' +
    IntToStr(GetTickCount64) + '.waot';
end;

function ReadFileBytes(const APath: string): TWasmBytes;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure WriteFileBytes(const APath: string; const ABytes: TWasmBytes);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
end;

type
  TAotTests = class(TTestSuite)
  private
    function ExportAddr(const AInstance: TWasmModuleInstance;
      const AName: string): TWasmFuncAddr;
    { Run add(a,b) INTERPRETED on a fresh store — the oracle. }
    function InterpAdd(const ABytes: TWasmBytes; const AA, AB: Int32): UInt64;
    { Run AName(AParams...) INTERPRETED on a fresh store — the general oracle. }
    function InterpResult1(const ABytes: TWasmBytes; const AName: string;
      const AParams: array of TWasmValue): UInt64;
    { Run MultiFuncModuleBytes' wide exports on AStore and expect each to
      match a fresh interpreter run and its model value, with no wide
      marshal block left on the context afterwards. }
    procedure ExpectWideExportsMatchInterp(const AStore: TWasmStore;
      const AInstance: TWasmModuleInstance; const ABytes: TWasmBytes);
  public
    procedure SetupTests; override;

    procedure TestMilestoneAddViaArtifact;
    procedure TestArtifactCodeIsPositionIndependent;
    procedure TestMultiFunctionWithDeclined;
    procedure TestLargeFrameAllCompiled;
    procedure TestJitAndAotCodeAreByteIdentical;
    procedure TestLoadedLoopHeadsKeepAlignment;
    procedure TestEpochBumpBeforeAcyclicNativeRecursion;
    procedure TestGuardRejectsWrongIrVersion;
    procedure TestGuardRejectsWrongArch;
    procedure TestGuardRejectsCorruptChecksum;
    procedure TestGuardRejectsModuleHashMismatch;
    procedure TestHostTargetMatchesDefaultCompile;
    procedure TestForeignOsDescriptorFingerprintRejected;
    procedure TestForeignIsaEmissionDeclined;
    procedure TestStrictSuccessCompilesEveryFunction;
    procedure TestStrictPredicateDeclineExceptionHandling;
    procedure TestStrictCompilesWideReturnCall;
    procedure TestStrictTargetDecline;
    procedure TestStrictRangeAndBackendDiagnostics;
    procedure TestCacheStillRecordsDeclinedFunctions;
    procedure TestStrictFailedCompileLeavesNoOutput;
    procedure TestStrictSuccessPublishesAtomically;
  end;

function TAotTests.ExportAddr(const AInstance: TWasmModuleInstance;
  const AName: string): TWasmFuncAddr;
var
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  if not AInstance.FindExport(AName, Kind, Addr) then
    raise EWasmError.CreateFmt('no export named %s', [AName]);
  Result := Addr;
end;

function TAotTests.InterpAdd(const ABytes: TWasmBytes;
  const AA, AB: Int32): UInt64;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Params: array[0 .. 1] of TWasmValue;
  Res: array[0 .. 0] of TWasmValue;
begin
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  try
    Loaded := LoadModule(ABytes);
    Store := TWasmStore.Create(Engine);
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    Params[0] := MakeValueI32(AA);
    Params[1] := MakeValueI32(AB);
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, ExportAddr(Instance, 'add'), @Params[0], @Res[0]);
    Result := Res[0].Bits;
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;

function TAotTests.InterpResult1(const ABytes: TWasmBytes; const AName: string;
  const AParams: array of TWasmValue): UInt64;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Res: array[0 .. 0] of TWasmValue;
  ParamPtr: PWasmValue;
begin
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  try
    Loaded := LoadModule(ABytes);
    Store := TWasmStore.Create(Engine);
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    if Length(AParams) > 0 then
      ParamPtr := @AParams[0]
    else
      ParamPtr := nil;
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, ExportAddr(Instance, AName), ParamPtr, @Res[0]);
    Result := Res[0].Bits;
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;

procedure TAotTests.ExpectWideExportsMatchInterp(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance; const ABytes: TWasmBytes);
const
  NAMES: array[0 .. 4] of string = ('widetail', 'widecaller', 'widebounce',
    'widecall', 'widecatch');
  EXPECTED: array[0 .. 4] of Integer = (WIDE_RESULT, WIDE_RESULT, WIDE_RESULT,
    WIDE_RESULT, WIDE_CAUGHT);
var
  I, K: Integer;
  Res: array[0 .. 0] of TWasmValue;
  Lane0, Lane1: UInt64;
begin
  for I := 0 to High(NAMES) do
  begin
    Res[0].Bits := High(UInt64);
    InterpInvoke(AStore, ExportAddr(AInstance, NAMES[I]), nil, @Res[0]);
    Expect<UInt64>(Res[0].Bits).ToBe(InterpResult1(ABytes, NAMES[I], []));
    Expect<Integer>(Res[0].I32).ToBe(EXPECTED[I]);
    { Every wide call site released its block before the invocation
      returned, including the one a caught throw unwound through. }
    Expect<Boolean>(InterpContextFor(AStore)^.WideScratch = nil).ToBe(True);
  end;

  {$PUSH}
  {$OVERFLOWCHECKS OFF}
  {$RANGECHECKS OFF}
  Lane0 := WideLane(WIDE_V128 - 1, 0);
  Lane1 := WideLane(WIDE_V128 - 1, 1);
  for K := WIDE_V128 - 2 downto 0 do
  begin
    Lane0 := WideLane(K, 0) - Lane0;
    Lane1 := WideLane(K, 1) - Lane1;
  end;
  {$POP}
  Res[0].Bits := 0;
  InterpInvoke(AStore, ExportAddr(AInstance, 'wideresult'), nil, @Res[0]);
  Expect<UInt64>(Res[0].Bits).ToBe(InterpResult1(ABytes, 'wideresult', []));
  Expect<UInt64>(Res[0].Bits).ToBe(Lane0 xor RolQWord(Lane1, 17));
  Expect<Boolean>(InterpContextFor(AStore)^.WideScratch = nil).ToBe(True);
end;

procedure TAotTests.TestMilestoneAddViaArtifact;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_: TWasmBytes;
  Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  ParseRes: TWasmAotParseResult;
  Engine, CompileEngine: TWasmEngine;
  CompileStore, Store: TWasmStore;
  CompileLoaded, Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  Addr: TWasmFuncAddr;
  Entry: PByte;
  Params: array[0 .. 1] of TWasmValue;
  Res: array[0 .. 0] of TWasmValue;
  I: Integer;
  BytesEqual: Boolean;
  InterpBits, AotBits: UInt64;
  Pairs: array[0 .. 3, 0 .. 1] of Int32;
begin
  Bytes_ := AddModuleBytes;

  { --- COMPILE PHASE: decode+validate, AOT-compile, serialize --------- }
  CompileEngine := TWasmEngine.Create;
  CompileLoaded := nil;
  CompileStore := nil;
  Engine := nil;
  Loaded := nil;
  Store := nil;
  Jit := nil;
  try
    CompileLoaded := LoadModule(Bytes_);
    CompileStore := TWasmStore.Create(CompileEngine);
    Artifact := AotCompileModule(CompileStore, CompileLoaded);
    Expect<Boolean>(Length(Artifact) > 0).ToBe(True);

    { The artifact parses, has one function, and it is compiled with an EMPTY
      reloc table (position-independence, §1.2/§7.2 bonus). }
    ParseRes := ParseAotArtifact(Artifact, Parsed);
    Expect<Integer>(Ord(ParseRes)).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(1);
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(True);
    Expect<Integer>(Length(Parsed.Funcs[0].Relocs)).ToBe(0);
    Expect<Boolean>(Length(Parsed.Funcs[0].Code) > 0).ToBe(True);

    { --- LOAD PHASE: FRESH store, re-decode+re-validate, wire ---------- }
    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    Engine := TWasmEngine.Create;
    Loaded := LoadModule(Bytes_);            { the security boundary, ALWAYS run }
    Store := TWasmStore.Create(Engine);
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);

    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, LoadRes);
    Expect<Integer>(Ord(LoadRes)).ToBe(Ord(alrLoaded));
    Expect<Boolean>(Jit <> nil).ToBe(True);

    { CompiledEntry is wired (from the artifact, not re-JITted). }
    Addr := ExportAddr(Instance, 'add');
    Expect<Boolean>(Store.Funcs[Addr].CompiledEntry <> nil).ToBe(True);

    { PROOF it came from the artifact: the EXECUTABLE bytes at CompiledEntry are
      exactly the serialized code bytes. }
    Entry := PByte(Store.Funcs[Addr].CompiledEntry);
    BytesEqual := True;
    for I := 0 to High(Parsed.Funcs[0].Code) do
      if Entry[I] <> Parsed.Funcs[0].Code[I] then
        BytesEqual := False;
    Expect<Boolean>(BytesEqual).ToBe(True);

    { add(17,25) = 42 through the LOADED machine code. }
    Params[0] := MakeValueI32(17);
    Params[1] := MakeValueI32(25);
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, Addr, @Params[0], @Res[0]);
    Expect<Integer>(Res[0].I32).ToBe(42);

    { Differential: several pairs, bit-identical to the interpreter. }
    Pairs[0, 0] := 17; Pairs[0, 1] := 25;
    Pairs[1, 0] := -1; Pairs[1, 1] := 1;
    Pairs[2, 0] := Integer($7FFFFFFF); Pairs[2, 1] := 1;   { wrap }
    Pairs[3, 0] := -100; Pairs[3, 1] := -200;
    for I := 0 to High(Pairs) do
    begin
      InterpBits := InterpAdd(Bytes_, Pairs[I, 0], Pairs[I, 1]);
      Params[0] := MakeValueI32(Pairs[I, 0]);
      Params[1] := MakeValueI32(Pairs[I, 1]);
      Res[0].Bits := High(UInt64);
      InterpInvoke(Store, Addr, @Params[0], @Res[0]);
      AotBits := Res[0].Bits;
      Expect<UInt64>(AotBits).ToBe(InterpBits);
    end;
  finally
    FreeAndNil(Jit);                { context freed BEFORE its store }
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
    FreeAndNil(CompileStore);
    FreeAndNil(CompileLoaded);
    FreeAndNil(CompileEngine);
  end;
end;
{$ELSE}
begin
  { No backend on this target: the milestone cannot map+execute. CPU identity
    and executable-code capability are separate (Windows x86-64 has the former
    but not the latter), so assert the capability directly. }
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestArtifactCodeIsPositionIndependent;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_, Artifact, Fresh: TWasmBytes;
  Parsed: TWasmAotArtifact;
  ParseRes: TWasmAotParseResult;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  EntryOffset: NativeUInt;
  RegCount: UInt32;
  I: Integer;
  BytesEqual: Boolean;
begin
  Bytes_ := AddModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Artifact := AotCompileModule(Store, Loaded);
    ParseRes := ParseAotArtifact(Artifact, Parsed);
    Expect<Integer>(Ord(ParseRes)).ToBe(Ord(aprOk));

    { The artifact's code is byte-identical to a FRESH JIT staging of the same
      function — the unified emitter emits the same position-independent bytes
      whether it finalizes to executable memory (JIT) or to bytes (AOT). }
    Fresh := JitStageFunctionBytes(Store, @Loaded.Ir.Functions[0], 0,
      EntryOffset, RegCount);
    Expect<Integer>(Length(Fresh)).ToBe(Length(Parsed.Funcs[0].Code));
    BytesEqual := Length(Fresh) > 0;
    for I := 0 to High(Fresh) do
      if Fresh[I] <> Parsed.Funcs[0].Code[I] then
        BytesEqual := False;
    Expect<Boolean>(BytesEqual).ToBe(True);
    { The staged register count matches the artifact's stored cross-check value. }
    Expect<Integer>(Integer(RegCount)).ToBe(Integer(Parsed.Funcs[0].RegisterCount));
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

{ Wave 2 (aot-spec §7.3): a WHOLE multi-function module, AOT-compiled,
  serialized, and loaded into a fresh store with WIDE_DECLINED recorded as
  declined (by hand — no valid function declines on a backend host). A
  compiled function calls a compiled function; a compiled function calls
  the interpreted f3; the interpreted f3 tail-calls the compiled $wide with
  1025 arguments; a compiled tail call bounces through f3 as a tail target;
  interpreted f6 calls $wide with 1025 arguments; interpreted f8 catches a
  throw from beneath a wide compiled call; and interpreted f10 tail-calls a
  compiled function returning 513 v128. Every export runs identically to the
  interpreter, and each declined function's CompiledEntry stays nil while
  the others are AOT-loaded. }
procedure TAotTests.TestMultiFunctionWithDeclined;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_, Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  ParseRes: TWasmAotParseResult;
  CompileEngine, Engine: TWasmEngine;
  CompileStore, Store: TWasmStore;
  CompileLoaded, Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  AddAddr, AddCaller: TWasmFuncAddr;
  Params: array[0 .. 1] of TWasmValue;
  Res: array[0 .. 0] of TWasmValue;
  I, J: Integer;
  Declined: Boolean;
begin
  Bytes_ := MultiFuncModuleBytes;
  CompileEngine := TWasmEngine.Create;
  CompileLoaded := nil;
  CompileStore := nil;
  Engine := nil;
  Loaded := nil;
  Store := nil;
  Jit := nil;
  try
    CompileLoaded := LoadModule(Bytes_);
    CompileStore := TWasmStore.Create(CompileEngine);
    Artifact := AotCompileModule(CompileStore, CompileLoaded);

    { The cache compile declines nothing, including the wide return_call. }
    ParseRes := ParseAotArtifact(Artifact, Parsed);
    Expect<Integer>(Ord(ParseRes)).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(12);
    for I := 0 to High(Parsed.Funcs) do
      Expect<Boolean>(Parsed.Funcs[I].Compiled).ToBe(True);

    { The declined records, the shape a cache fallback carries. }
    Artifact := DeclineArtifactRecords(Artifact, WIDE_DECLINED);
    ParseRes := ParseAotArtifact(Artifact, Parsed);
    Expect<Integer>(Ord(ParseRes)).ToBe(Ord(aprOk));
    for J := 0 to High(WIDE_DECLINED) do
    begin
      Expect<Boolean>(Parsed.Funcs[WIDE_DECLINED[J]].Compiled).ToBe(False);
      Expect<Integer>(Length(Parsed.Funcs[WIDE_DECLINED[J]].Code)).ToBe(0);
    end;

    { --- LOAD into a fresh store --- }
    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    Engine := TWasmEngine.Create;
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, LoadRes);
    Expect<Integer>(Ord(LoadRes)).ToBe(Ord(alrLoaded));

    AddAddr := ExportAddr(Instance, 'add');
    AddCaller := ExportAddr(Instance, 'addcaller');
    { The compiled functions are AOT-wired; the declined ones are left nil,
      so they run interpreted (aot-spec §4.2 step 6). }
    Expect<Boolean>(Store.Funcs[AddAddr].CompiledNativeScalarEntry =
      Store.Funcs[AddAddr].CompiledEntry).ToBe(True);
    for I := 0 to High(Instance.FuncAddrs) do
    begin
      Declined := False;
      for J := 0 to High(WIDE_DECLINED) do
        if WIDE_DECLINED[J] = I then
          Declined := True;
      Expect<Boolean>(Store.Funcs[Instance.FuncAddrs[I]].CompiledEntry = nil)
        .ToBe(Declined);
    end;

    { addcaller(17,25): compiled f1 calls compiled f0 -> 42. }
    Params[0] := MakeValueI32(17);
    Params[1] := MakeValueI32(25);
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, AddCaller, @Params[0], @Res[0]);
    Expect<UInt64>(Res[0].Bits)
      .ToBe(InterpResult1(Bytes_, 'addcaller', [Params[0], Params[1]]));
    Expect<Integer>(Res[0].I32).ToBe(42);

    { Interpreted f3 tail-calls compiled $wide past the inline buffers; the
      compiled f4 calls it; the compiled f5 bounces through it as a tail
      target. }
    ExpectWideExportsMatchInterp(Store, Instance, Bytes_);
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
    FreeAndNil(CompileStore);
    FreeAndNil(CompileLoaded);
    FreeAndNil(CompileEngine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestLargeFrameAllCompiled;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_, Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  ParseRes: TWasmAotParseResult;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
begin
  Bytes_ := LargeFrameModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Expect<Boolean>(Loaded.Ir.Functions[0].RegisterCount >= 2048).ToBe(True);
    Expect<Boolean>(JitCanCompile(@Loaded.Ir.Functions[0])).ToBe(True);
    Artifact := AotCompileModule(Store, Loaded);
    ParseRes := ParseAotArtifact(Artifact, Parsed);
    Expect<Integer>(Ord(ParseRes)).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(1);
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(True);
    Expect<Boolean>(Length(Parsed.Funcs[0].Code) > 0).ToBe(True);
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

{ Wave 3, the JIT-vs-AOT round-trip identity test (aot-spec §5.2). The AOT-loaded
  machine code IS the JIT's code, serialized and reloaded — so a fresh JIT
  compilation of a function and the AOT-loaded region for the same function are
  byte-for-byte identical, and both produce the same result. This is the strong
  invariant the unified emitter buys: only WHERE the bytes came from differs. }
procedure TAotTests.TestLoadedLoopHeadsKeepAlignment;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_, Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Engine, CompileEngine: TWasmEngine;
  CompileStore, Store: TWasmStore;
  CompileLoaded, Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  Addr: TWasmFuncAddr;
  Entry: PByte;
  Params: array[0 .. 0] of TWasmValue;
  Res: array[0 .. 0] of TWasmValue;
  {$IFDEF WASM_JIT_X64}
  Site, Target, Edges: Integer;
  {$ENDIF}
begin
  Bytes_ := LoopModuleBytes;
  CompileEngine := TWasmEngine.Create;
  CompileLoaded := nil;
  CompileStore := nil;
  Engine := nil;
  Loaded := nil;
  Store := nil;
  Jit := nil;
  try
    CompileLoaded := LoadModule(Bytes_);
    CompileStore := TWasmStore.Create(CompileEngine);
    Artifact := AotCompileModule(CompileStore, CompileLoaded);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(True);
    Expect<Integer>(Length(Parsed.Funcs[0].Relocs)).ToBe(0);

    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    Engine := TWasmEngine.Create;
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, LoadRes);
    Expect<Integer>(Ord(LoadRes)).ToBe(Ord(alrLoaded));
    Addr := ExportAddr(Instance, 'run');
    Entry := PByte(Store.Funcs[Addr].CompiledEntry);
    Expect<Boolean>(Entry <> nil).ToBe(True);
    {$IFDEF WASM_JIT_X64}
    { The artifact carries offsets only; the loader's own page-aligned mapping
      makes the loop head's ADDRESS land where the emitter placed it. }
    Edges := 0;
    for Site := 0 to Length(Parsed.Funcs[0].Code) - 14 do
      if (Entry[Site] = $0F) and (Entry[Site + 1] = $84) and
        (Entry[Site + 6] = $BF) and
        (Entry[Site + 7] = Byte(Ord(wtkEpochInterrupt))) and
        (Entry[Site + 11] = $41) and (Entry[Site + 12] = $FF) and
        (Entry[Site + 13] = $17) then
      begin
        Target := Site + 6 + Integer(UInt32(Entry[Site + 2]) or
          (UInt32(Entry[Site + 3]) shl 8) or
          (UInt32(Entry[Site + 4]) shl 16) or
          (UInt32(Entry[Site + 5]) shl 24));
        Expect<PtrUInt>((PtrUInt(Entry) + PtrUInt(Target)) mod
          X64_LOOP_HEAD_ALIGN).ToBe(X64_LOOP_HEAD_OFFSET);
        Inc(Edges);
      end;
    Expect<Integer>(Edges).ToBe(1);
    {$ENDIF}
    Params[0] := MakeValueI32(1000);
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, Addr, @Params[0], @Res[0]);
    Expect<UInt32>(UInt32(Res[0].I32)).ToBe(OracleLoop(1000));
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
    FreeAndNil(CompileStore);
    FreeAndNil(CompileLoaded);
    FreeAndNil(CompileEngine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestJitAndAotCodeAreByteIdentical;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_, Artifact, Staged: TWasmBytes;
  JitEngine, AotEngine: TWasmEngine;
  JitStore, AotStore: TWasmStore;
  JitLoaded, AotLoaded: TWasmLoadedModule;
  JitInst, AotInst: TWasmModuleInstance;
  Imports: TWasmImports;
  JitCtx, AotCtx: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  JitAddr, AotAddr: TWasmFuncAddr;
  JitEntry, AotEntry: PByte;
  EntryOffset: NativeUInt;
  RegCount: UInt32;
  I, Len: Integer;
  Equal: Boolean;
  P: array[0 .. 1] of TWasmValue;
  R: array[0 .. 0] of TWasmValue;
begin
  Bytes_ := AddModuleBytes;
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  JitEngine := nil;
  JitLoaded := nil;
  JitStore := nil;
  JitCtx := nil;
  AotEngine := nil;
  AotLoaded := nil;
  AotStore := nil;
  AotCtx := nil;
  try
    { A store that FORCE-COMPILES add through the live JIT. }
    JitEngine := TWasmEngine.Create;
    JitLoaded := LoadModule(Bytes_);
    JitStore := TWasmStore.Create(JitEngine);
    JitInst := InstantiateModule(JitStore, JitLoaded.Ir, JitLoaded.BytesPtr,
      JitLoaded.BytesLength, Imports);
    RegisterInterpreter(JitStore);
    JitCtx := RegisterJit(JitStore);
    JitAddr := ExportAddr(JitInst, 'add');
    Expect<Boolean>(JitCtx.ForceCompile(JitAddr)).ToBe(True);
    JitEntry := PByte(JitStore.Funcs[JitAddr].CompiledEntry);
    Expect<Boolean>(JitEntry <> nil).ToBe(True);

    { The code length, via a stage of the same function (the same finalized
      bytes the JIT mapped). }
    Staged := JitStageFunctionBytes(JitStore, @JitLoaded.Ir.Functions[0], 0,
      EntryOffset, RegCount);
    Len := Length(Staged);
    Expect<Boolean>(Len > 0).ToBe(True);

    { A store that AOT-compiles, serializes, and LOADS the same function. }
    AotEngine := TWasmEngine.Create;
    AotLoaded := LoadModule(Bytes_);
    AotStore := TWasmStore.Create(AotEngine);
    AotInst := InstantiateModule(AotStore, AotLoaded.Ir, AotLoaded.BytesPtr,
      AotLoaded.BytesLength, Imports);
    RegisterInterpreter(AotStore);
    Artifact := AotCompileModule(AotStore, AotLoaded);
    AotCtx := AotLoadAndWire(AotStore, AotLoaded, AotInst, Artifact, LoadRes);
    Expect<Integer>(Ord(LoadRes)).ToBe(Ord(alrLoaded));
    AotAddr := ExportAddr(AotInst, 'add');
    AotEntry := PByte(AotStore.Funcs[AotAddr].CompiledEntry);
    Expect<Boolean>(AotEntry <> nil).ToBe(True);

    { §5.2 byte-identity: the AOT-loaded region equals a fresh JIT compilation of
      the same function, byte for byte. }
    Equal := True;
    for I := 0 to Len - 1 do
      if JitEntry[I] <> AotEntry[I] then
        Equal := False;
    Expect<Boolean>(Equal).ToBe(True);

    { Behavioural identity: both return 42. }
    P[0] := MakeValueI32(30);
    P[1] := MakeValueI32(12);
    R[0].Bits := High(UInt64);
    InterpInvoke(JitStore, JitAddr, @P[0], @R[0]);
    Expect<Integer>(R[0].I32).ToBe(42);
    R[0].Bits := High(UInt64);
    InterpInvoke(AotStore, AotAddr, @P[0], @R[0]);
    Expect<Integer>(R[0].I32).ToBe(42);
  finally
    FreeAndNil(JitCtx);
    FreeAndNil(JitStore);
    FreeAndNil(JitLoaded);
    FreeAndNil(JitEngine);
    FreeAndNil(AotCtx);
    FreeAndNil(AotStore);
    FreeAndNil(AotLoaded);
    FreeAndNil(AotEngine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestEpochBumpBeforeAcyclicNativeRecursion;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_, Artifact: TWasmBytes;
  CompileEngine, Engine: TWasmEngine;
  CompileStore, Store: TWasmStore;
  CompileLoaded, Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Canon, TypeIds: TWasmEngineTypeIds;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  Param, Res: TWasmValue;
begin
  Bytes_ := EpochAcyclicRecModuleBytes;
  CompileEngine := TWasmEngine.Create;
  CompileStore := nil;
  CompileLoaded := nil;
  Engine := nil;
  Store := nil;
  Loaded := nil;
  Jit := nil;
  try
    CompileLoaded := LoadModule(Bytes_);
    CompileStore := TWasmStore.Create(CompileEngine);
    Artifact := AotCompileModule(CompileStore, CompileLoaded);

    Engine := TWasmEngine.Create;
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Engine.InternModule(Loaded.Ir, Canon, TypeIds);
    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    SetLength(Imports.Funcs, 1);
    Imports.Funcs[0] := Store.AddHostFunc(TypeIds[0],
      @AotBumpEpochCallback, nil);
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, LoadRes);
    Expect<Integer>(Ord(LoadRes)).ToBe(Ord(alrLoaded));
    Expect<Boolean>(Store.Funcs[ExportAddr(Instance, 'rec')].CompiledEntry <>
      nil).ToBe(True);

    Store.Epoch := 0;
    Store.EpochSnapshot := 0;
    Param := MakeValueI32(8);
    Res.Bits := High(UInt64);
    InterpInvoke(Store, ExportAddr(Instance, 'run'), @Param, @Res);
    Expect<Integer>(Res.I32).ToBe(8);
    Expect<UInt64>(Store.Epoch).ToBe(1);
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
    FreeAndNil(CompileStore);
    FreeAndNil(CompileLoaded);
    FreeAndNil(CompileEngine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

{ --- guard tests: build the artifact, mutate/misuse, assert the reason --- }

{$IFDEF WASM_JIT_BACKEND}
{ Build the add-artifact and a fresh, instantiated add-store ready to load it.
  The caller mutates ARTIFACT (or passes a foreign store) before AotLoadAndWire.
  Frees are the caller's via the returned handles. }
procedure BuildLoadFixture(out AArtifact: TWasmBytes;
  out AEngine: TWasmEngine; out AStore: TWasmStore;
  out ALoaded: TWasmLoadedModule; out AInstance: TWasmModuleInstance);
var
  Bytes_: TWasmBytes;
  CompileEngine: TWasmEngine;
  CompileStore: TWasmStore;
  CompileLoaded: TWasmLoadedModule;
  Imports: TWasmImports;
begin
  Bytes_ := AddModuleBytes;
  CompileEngine := TWasmEngine.Create;
  CompileLoaded := LoadModule(Bytes_);
  CompileStore := TWasmStore.Create(CompileEngine);
  try
    AArtifact := AotCompileModule(CompileStore, CompileLoaded);
  finally
    CompileStore.Free;
    CompileLoaded.Free;
    CompileEngine.Free;
  end;

  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  AEngine := TWasmEngine.Create;
  ALoaded := LoadModule(Bytes_);
  AStore := TWasmStore.Create(AEngine);
  AInstance := InstantiateModule(AStore, ALoaded.Ir, ALoaded.BytesPtr,
    ALoaded.BytesLength, Imports);
  RegisterInterpreter(AStore);
end;
{$ENDIF}

procedure TAotTests.TestGuardRejectsWrongIrVersion;
{$IFDEF WASM_JIT_BACKEND}
var
  Artifact: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Jit: TWasmJitContext;
  Res: TWasmAotLoadResult;
begin
  BuildLoadFixture(Artifact, Engine, Store, Loaded, Instance);
  Jit := nil;
  try
    { irFormatVer is the u16 at header offset 6; set it to a version we reject.
      The checksum covers only the body, so this stays a well-formed file that
      fails the IR-version guard specifically. }
    Artifact[6] := $63;
    Artifact[7] := $00;
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, Res);
    Expect<Integer>(Ord(Res)).ToBe(Ord(alrIrVersionMismatch));
    Expect<Boolean>(Jit = nil).ToBe(True);
    Expect<Boolean>(Store.Funcs[ExportAddr(Instance, 'add')].CompiledEntry = nil)
      .ToBe(True);
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestGuardRejectsWrongArch;
{$IFDEF WASM_JIT_BACKEND}
var
  Artifact: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Jit: TWasmJitContext;
  Res: TWasmAotLoadResult;
begin
  BuildLoadFixture(Artifact, Engine, Store, Loaded, Instance);
  Jit := nil;
  try
    { targetArch is the u8 at header offset 8. Set it to a DIFFERENT arch than
      the host so guard 4 fires. }
    if AotHostArch = WAOT_ARCH_AARCH64 then
      Artifact[8] := WAOT_ARCH_X64
    else
      Artifact[8] := WAOT_ARCH_AARCH64;
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, Res);
    Expect<Integer>(Ord(Res)).ToBe(Ord(alrArchMismatch));
    Expect<Boolean>(Jit = nil).ToBe(True);
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestGuardRejectsCorruptChecksum;
{$IFDEF WASM_JIT_BACKEND}
var
  Artifact: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Jit: TWasmJitContext;
  Res: TWasmAotLoadResult;
begin
  BuildLoadFixture(Artifact, Engine, Store, Loaded, Instance);
  Jit := nil;
  try
    { Flip a byte in the body (offset >= header size): selfChecksum fails. }
    Artifact[WAOT_HEADER_SIZE] := Artifact[WAOT_HEADER_SIZE] xor $FF;
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, Res);
    Expect<Integer>(Ord(Res)).ToBe(Ord(alrBadChecksum));
    Expect<Boolean>(Jit = nil).ToBe(True);
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestGuardRejectsModuleHashMismatch;
{$IFDEF WASM_JIT_BACKEND}
var
  AddArtifact, SubBytes: TWasmBytes;
  AddEngine, SubEngine: TWasmEngine;
  AddStore, SubStore: TWasmStore;
  AddLoaded, SubLoaded: TWasmLoadedModule;
  AddInstance, SubInstance: TWasmModuleInstance;
  Imports: TWasmImports;
  Jit: TWasmJitContext;
  Res: TWasmAotLoadResult;
begin
  { The add-artifact, compiled from the add module. }
  BuildLoadFixture(AddArtifact, AddEngine, AddStore, AddLoaded, AddInstance);
  { A DIFFERENT module (i32.sub), freshly loaded + instantiated. }
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  SubBytes := SubModuleBytes;
  SubEngine := TWasmEngine.Create;
  SubLoaded := nil;
  SubStore := nil;
  Jit := nil;
  try
    SubLoaded := LoadModule(SubBytes);
    SubStore := TWasmStore.Create(SubEngine);
    SubInstance := InstantiateModule(SubStore, SubLoaded.Ir, SubLoaded.BytesPtr,
      SubLoaded.BytesLength, Imports);
    RegisterInterpreter(SubStore);

    { Loading the add-artifact against the SUB module: moduleHash mismatch. This
      is the tampered/stale-cache defence — a tampered artifact for a different
      module is rejected, never run with wrong-module code (§8). }
    Jit := AotLoadAndWire(SubStore, SubLoaded, SubInstance, AddArtifact, Res);
    Expect<Integer>(Ord(Res)).ToBe(Ord(alrModuleHashMismatch));
    Expect<Boolean>(Jit = nil).ToBe(True);
  finally
    FreeAndNil(Jit);
    FreeAndNil(SubStore);
    FreeAndNil(SubLoaded);
    FreeAndNil(SubEngine);
    FreeAndNil(AddStore);
    FreeAndNil(AddLoaded);
    FreeAndNil(AddEngine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestHostTargetMatchesDefaultCompile;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  DefaultArt, HostArt: TWasmBytes;
  DefaultParsed, HostParsed: TWasmAotArtifact;
begin
  Bytes_ := AddModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := LoadModule(Bytes_);
  Store := TWasmStore.Create(Engine);
  try
    DefaultArt := AotCompileModule(Store, Loaded);
    HostArt := AotCompileModule(Store, Loaded, WasmTargetHost);
    Expect<Integer>(Ord(ParseAotArtifact(DefaultArt, DefaultParsed)))
      .ToBe(Ord(aprOk));
    Expect<Integer>(Ord(ParseAotArtifact(HostArt, HostParsed)))
      .ToBe(Ord(aprOk));
    Expect<Integer>(Integer(DefaultParsed.Header.TargetArch))
      .ToBe(Integer(AotHostArch));
    Expect<UInt64>(DefaultParsed.Header.AbiFingerprint).ToBe(
      WasmTargetAbiFingerprint(WasmTargetAbi(WasmTargetHost)));
    Expect<UInt64>(HostParsed.Header.AbiFingerprint).ToBe(
      DefaultParsed.Header.AbiFingerprint);
  finally
    Store.Free;
    Loaded.Free;
    Engine.Free;
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestForeignOsDescriptorFingerprintRejected;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Foreign: TWasmTarget;
  Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Jit: TWasmJitContext;
  Res: TWasmAotLoadResult;
begin
  Foreign := WasmTargetOf(WasmTargetHost.Arch,
    TWasmTargetOs(Ord(wtoDarwin) + Ord(wtoLinux) - Ord(WasmTargetHost.Os)));
  Bytes_ := AddModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := LoadModule(Bytes_);
  Store := TWasmStore.Create(Engine);
  Jit := nil;
  try
    Artifact := AotCompileModule(Store, Loaded, Foreign);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    Expect<Integer>(Integer(Parsed.Header.TargetArch)).ToBe(Integer(AotHostArch));
    Expect<UInt64>(Parsed.Header.AbiFingerprint).ToBe(
      WasmTargetAbiFingerprint(WasmTargetAbi(Foreign)));
    Expect<Boolean>(
      Parsed.Header.AbiFingerprint <> WasmAotAbiFingerprint(Store)).ToBe(True);

    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, Res);
    Expect<Integer>(Ord(Res)).ToBe(Ord(alrAbiMismatch));
    Expect<Boolean>(Jit = nil).ToBe(True);
  finally
    FreeAndNil(Jit);
    Store.Free;
    Loaded.Free;
    Engine.Free;
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestForeignIsaEmissionDeclined;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Foreign: TWasmTarget;
  Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Jit: TWasmJitContext;
  Res: TWasmAotLoadResult;
  I: Integer;
  AnyCompiled: Boolean;
begin
  Foreign := WasmTargetOf(
    {$IFDEF CPUAARCH64}wtaX86_64{$ELSE}wtaAArch64{$ENDIF},
    WasmTargetHost.Os);
  Bytes_ := AddModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := LoadModule(Bytes_);
  Store := TWasmStore.Create(Engine);
  Jit := nil;
  try
    Expect<Boolean>(JitCanEmitForTarget(@Loaded.Ir.Functions[0], Foreign))
      .ToBe(False);
    Artifact := AotCompileModule(Store, Loaded, Foreign);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    Expect<Integer>(Integer(Parsed.Header.TargetArch))
      .ToBe(Integer(AotTargetArch(Foreign)));
    Expect<Boolean>(Parsed.Header.TargetArch <> AotHostArch).ToBe(True);
    AnyCompiled := False;
    for I := 0 to High(Parsed.Funcs) do
      if Parsed.Funcs[I].Compiled then
        AnyCompiled := True;
    Expect<Boolean>(AnyCompiled).ToBe(False);

    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, Res);
    Expect<Integer>(Ord(Res)).ToBe(Ord(alrArchMismatch));
    Expect<Boolean>(Jit = nil).ToBe(True);
  finally
    FreeAndNil(Jit);
    Store.Free;
    Loaded.Free;
    Engine.Free;
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestStrictSuccessCompilesEveryFunction;
{$IFDEF WASM_JIT_BACKEND}
var
  Bytes_, Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  I: Integer;
begin
  Bytes_ := AddModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Artifact := AotCompileModuleStrict(Store, Loaded);
    Expect<Boolean>(Length(Artifact) > 0).ToBe(True);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(Length(Loaded.Ir.Functions));
    for I := 0 to High(Parsed.Funcs) do
    begin
      Expect<Boolean>(Parsed.Funcs[I].Compiled).ToBe(True);
      Expect<Boolean>(Length(Parsed.Funcs[I].Code) > 0).ToBe(True);
    end;
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.TestStrictPredicateDeclineExceptionHandling;
var
  Bytes_, Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Caught: Boolean;
  Kind: TWasmAotDeclineKind;
  I: Integer;
begin
  Bytes_ := TryTableModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  Caught := False;
  Artifact := nil;
  Kind := wadTarget;
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    try
      Artifact := AotCompileModuleStrict(Store, Loaded);
    except
      on E: EWasmAotError do
      begin
        Caught := True;
        Kind := E.Kind;
      end;
    end;
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Caught).ToBe(False);
    Expect<Boolean>(Length(Artifact) > 0).ToBe(True);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    for I := 0 to High(Parsed.Funcs) do
      Expect<Boolean>(Parsed.Funcs[I].Compiled).ToBe(True);
    {$ELSE}
    Expect<Boolean>(Caught).ToBe(True);
    Expect<Integer>(Length(Artifact)).ToBe(0);
    Expect<Integer>(Ord(Kind)).ToBe(Ord(wadTarget));
    {$ENDIF}
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;

{ ADR-0015 is all-or-fail with no structural decline: a `return_call` whose
  argument block is one past the 1024-slot inline tail buffer compiles
  strictly, and the all-native load runs every wide-tail export identically
  to the interpreter. Off a backend host strict compile is a target decline. }
procedure TAotTests.TestStrictCompilesWideReturnCall;
var
  Bytes_, Artifact: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Caught: Boolean;
  Kind: TWasmAotDeclineKind;
  {$IFDEF WASM_JIT_BACKEND}
  Parsed: TWasmAotArtifact;
  I: Integer;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  {$ENDIF}
begin
  Bytes_ := MultiFuncModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  Caught := False;
  Artifact := nil;
  Kind := wadBackend;
  {$IFDEF WASM_JIT_BACKEND}
  Jit := nil;
  {$ENDIF}
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    try
      Artifact := AotCompileModuleStrict(Store, Loaded);
    except
      on E: EWasmAotError do
      begin
        Caught := True;
        Kind := E.Kind;
      end;
    end;
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Caught).ToBe(False);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(12);
    for I := 0 to High(Parsed.Funcs) do
      Expect<Boolean>(Parsed.Funcs[I].Compiled).ToBe(True);

    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    Instance := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    RegisterInterpreter(Store);
    Jit := AotLoadAndWire(Store, Loaded, Instance, Artifact, LoadRes);
    Expect<Integer>(Ord(LoadRes)).ToBe(Ord(alrLoaded));
    for I := 0 to High(Instance.FuncAddrs) do
      Expect<Boolean>(Store.Funcs[Instance.FuncAddrs[I]].CompiledEntry <> nil)
        .ToBe(True);
    ExpectWideExportsMatchInterp(Store, Instance, Bytes_);
    {$ELSE}
    Expect<Boolean>(Caught).ToBe(True);
    Expect<Integer>(Length(Artifact)).ToBe(0);
    Expect<Integer>(Ord(Kind)).ToBe(Ord(wadTarget));
    {$ENDIF}
  finally
    {$IFDEF WASM_JIT_BACKEND}
    FreeAndNil(Jit);
    {$ENDIF}
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;

procedure TAotTests.TestStrictTargetDecline;
var
  Bytes_, Artifact: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Caught: Boolean;
  Kind: TWasmAotDeclineKind;
  FuncIdx: UInt32;
  Msg: string;
  ClassNm: string;
begin
  Bytes_ := AddModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  Caught := False;
  Artifact := nil;
  Kind := wadTarget;
  FuncIdx := 0;
  Msg := '';
  ClassNm := '';
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    {$IFDEF WASM_JIT_BACKEND}
    Artifact := AotCompileModuleStrict(Store, Loaded);
    Expect<Boolean>(Length(Artifact) > 0).ToBe(True);
    Expect<Integer>(Ord(JitCompileDecline(nil))).ToBe(Ord(jdNilFunction));
    {$ELSE}
    try
      Artifact := AotCompileModuleStrict(Store, Loaded);
    except
      on E: EWasmAotError do
      begin
        Caught := True;
        Kind := E.Kind;
        FuncIdx := E.FuncIrIndex;
        Msg := E.Message;
        ClassNm := E.ClassName;
      end;
    end;
    Expect<Boolean>(Caught).ToBe(True);
    Expect<Integer>(Length(Artifact)).ToBe(0);
    Expect<string>(ClassNm).ToBe('EWasmAotError');
    Expect<Integer>(Ord(Kind)).ToBe(Ord(wadTarget));
    Expect<Integer>(Integer(FuncIdx)).ToBe(Integer(WASM_AOT_NO_FUNC));
    Expect<Boolean>(Pos('target', Msg) > 0).ToBe(True);
    {$ENDIF}
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;

procedure TAotTests.TestStrictRangeAndBackendDiagnostics;
var
  RangeErr, BackendErr, PredicateErr: EWasmAotError;
begin
  { A live function large enough to overflow a branch immediate is impractical
    in this suite (jit-spec §11.4). The kinds and messages the strict path
    raises are the regression surface. }
  RangeErr := EWasmAotError.CreateDecline(0, wadRange, jdNone);
  try
    Expect<Integer>(Ord(RangeErr.Kind)).ToBe(Ord(wadRange));
    Expect<Integer>(Integer(RangeErr.FuncIrIndex)).ToBe(0);
    Expect<string>(RangeErr.ClassName).ToBe('EWasmAotError');
    Expect<Boolean>(Pos('function 0', RangeErr.Message) > 0).ToBe(True);
    Expect<Boolean>(Pos('range', RangeErr.Message) > 0).ToBe(True);
  finally
    RangeErr.Free;
  end;
  BackendErr := EWasmAotError.CreateDecline(1, wadBackend, jdNone);
  try
    Expect<Integer>(Ord(BackendErr.Kind)).ToBe(Ord(wadBackend));
    Expect<Integer>(Integer(BackendErr.FuncIrIndex)).ToBe(1);
    Expect<Boolean>(Pos('backend', BackendErr.Message) > 0).ToBe(True);
  finally
    BackendErr.Free;
  end;
  { The op fence (an op with no template) has no valid-module reproducer:
    every IR op has a template on both backends. }
  PredicateErr := EWasmAotError.CreateDecline(3, wadPredicate,
    jdUnsupportedOp);
  try
    Expect<Integer>(Ord(PredicateErr.Kind)).ToBe(Ord(wadPredicate));
    Expect<Integer>(Ord(PredicateErr.Predicate)).ToBe(Ord(jdUnsupportedOp));
    Expect<Integer>(Integer(PredicateErr.FuncIrIndex)).ToBe(3);
    Expect<Boolean>(Pos('function 3', PredicateErr.Message) > 0).ToBe(True);
    Expect<Boolean>(Pos('predicate (unsupported-op)', PredicateErr.Message) > 0)
      .ToBe(True);
  finally
    PredicateErr.Free;
  end;
end;

{ A target the host cannot emit: the other ISA on a backend host, and the
  host itself where there is no backend. No valid module declines a
  function on an emitting target, so a strict failure is a target decline. }
function NonEmittingTarget: TWasmTarget;
begin
  {$IFDEF WASM_JIT_BACKEND}
  Result := WasmTargetOf(
    {$IFDEF CPUAARCH64}wtaX86_64{$ELSE}wtaAArch64{$ENDIF},
    WasmTargetHost.Os);
  {$ELSE}
  Result := WasmTargetHost;
  {$ENDIF}
end;

{ The cache path records a function it cannot compile for interpreter
  fallback, where strict compilation of the same module and target fails. }
procedure TAotTests.TestCacheStillRecordsDeclinedFunctions;
var
  Bytes_, Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Caught: Boolean;
  I: Integer;
begin
  Bytes_ := MultiFuncModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  Caught := False;
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Artifact := AotCompileModule(Store, Loaded, NonEmittingTarget);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(12);
    for I := 0 to High(Parsed.Funcs) do
    begin
      Expect<Boolean>(Parsed.Funcs[I].Compiled).ToBe(False);
      Expect<Integer>(Length(Parsed.Funcs[I].Code)).ToBe(0);
    end;
    try
      AotCompileModuleStrict(Store, Loaded, NonEmittingTarget);
    except
      on E: EWasmAotError do
        Caught := E.Kind = wadTarget;
    end;
    Expect<Boolean>(Caught).ToBe(True);
  finally
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;

procedure TAotTests.TestStrictFailedCompileLeavesNoOutput;
var
  Path, Staging: string;
  Marker: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Caught: Boolean;
  I: Integer;
begin
  Path := TempArtifactPath;
  Staging := Path + '.publishing';
  SetLength(Marker, 4);
  Marker[0] := Byte('K');
  Marker[1] := Byte('E');
  Marker[2] := Byte('E');
  Marker[3] := Byte('P');
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  Caught := False;
  try
    Loaded := LoadModule(MultiFuncModuleBytes);
    Store := TWasmStore.Create(Engine);

    Expect<Boolean>(FileExists(Path)).ToBe(False);
    try
      AotCompileModuleStrictToFile(Store, Loaded, NonEmittingTarget, Path);
    except
      on E: EWasmAotError do
        Caught := True;
    end;
    Expect<Boolean>(Caught).ToBe(True);
    Expect<Boolean>(FileExists(Path)).ToBe(False);
    Expect<Boolean>(FileExists(Staging)).ToBe(False);

    WriteFileBytes(Path, Marker);
    Caught := False;
    try
      AotCompileModuleStrictToFile(Store, Loaded, NonEmittingTarget, Path);
    except
      on E: EWasmAotError do
        Caught := True;
    end;
    Expect<Boolean>(Caught).ToBe(True);
    Expect<Boolean>(FileExists(Path)).ToBe(True);
    Expect<Boolean>(FileExists(Staging)).ToBe(False);
    Marker := ReadFileBytes(Path);
    Expect<Integer>(Length(Marker)).ToBe(4);
    for I := 0 to 3 do
      Expect<Integer>(Marker[I]).ToBe(Ord('KEEP'[I + 1]));
  finally
    if FileExists(Staging) then
      DeleteFile(Staging);
    if FileExists(Path) then
      DeleteFile(Path);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;

procedure TAotTests.TestStrictSuccessPublishesAtomically;
{$IFDEF WASM_JIT_BACKEND}
var
  Path, Staging: string;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Parsed: TWasmAotArtifact;
  OnDisk: TWasmBytes;
begin
  Path := TempArtifactPath;
  Staging := Path + '.publishing';
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  try
    Loaded := LoadModule(AddModuleBytes);
    Store := TWasmStore.Create(Engine);
    AotCompileModuleStrictToFile(Store, Loaded, Path);
    Expect<Boolean>(FileExists(Path)).ToBe(True);
    Expect<Boolean>(FileExists(Staging)).ToBe(False);
    OnDisk := ReadFileBytes(Path);
    Expect<Integer>(Ord(ParseAotArtifact(OnDisk, Parsed))).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(1);
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(True);
  finally
    if FileExists(Staging) then
      DeleteFile(Staging);
    if FileExists(Path) then
      DeleteFile(Path);
    FreeAndNil(Store);
    FreeAndNil(Loaded);
    FreeAndNil(Engine);
  end;
end;
{$ELSE}
begin
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
end;
{$ENDIF}

procedure TAotTests.SetupTests;
begin
  Test('AOT-compiled i32.add loads from the artifact and matches the interpreter',
    TestMilestoneAddViaArtifact);
  Test('the artifact code is position-independent (byte-identical to a JIT staging)',
    TestArtifactCodeIsPositionIndependent);
  Test('a whole multi-function module AOT-loads, declined function stays interpreted',
    TestMultiFunctionWithDeclined);
  Test('a large-frame module records its non-EH function compiled',
    TestLargeFrameAllCompiled);
  Test('AOT-loaded code is byte-identical to a fresh JIT compilation',
    TestJitAndAotCodeAreByteIdentical);
  Test('an AOT-loaded loop runs with its head at the aligned address',
    TestLoadedLoopHeadsKeepAlignment);
  Test('an epoch bump before acyclic AOT recursion does not invent a safepoint',
    TestEpochBumpBeforeAcyclicNativeRecursion);
  Test('a wrong IR-version artifact is rejected (interpret fall-back)',
    TestGuardRejectsWrongIrVersion);
  Test('a wrong-arch artifact is rejected (interpret fall-back)',
    TestGuardRejectsWrongArch);
  Test('a corrupted-checksum artifact is rejected (interpret fall-back)',
    TestGuardRejectsCorruptChecksum);
  Test('an artifact loaded against a different module is rejected (moduleHash)',
    TestGuardRejectsModuleHashMismatch);
  Test('an explicit host target stamps the same descriptor fingerprint',
    TestHostTargetMatchesDefaultCompile);
  Test('a foreign-OS same-arch artifact is rejected on ABI fingerprint',
    TestForeignOsDescriptorFingerprintRejected);
  Test('a foreign-ISA target stamps the other arch and declines emission',
    TestForeignIsaEmissionDeclined);
  Test('strict compile succeeds only when every defined function is native',
    TestStrictSuccessCompilesEveryFunction);
  Test('strict compile publishes native code for try_table handlers',
    TestStrictPredicateDeclineExceptionHandling);
  Test('strict compile publishes a return_call wider than the tail buffer',
    TestStrictCompilesWideReturnCall);
  Test('strict compile fails a target decline off the AOT host',
    TestStrictTargetDecline);
  Test('strict range, backend, and predicate diagnostics name the function '
    + 'and kind', TestStrictRangeAndBackendDiagnostics);
  Test('cache compile still records declined functions for fallback',
    TestCacheStillRecordsDeclinedFunctions);
  Test('a failed strict compile leaves no partial output',
    TestStrictFailedCompileLeavesNoOutput);
  Test('a successful strict compile publishes atomically',
    TestStrictSuccessPublishesAtomically);
end;

begin
  TestRunnerProgram.AddSuite(TAotTests.Create('Wasm.Aot'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
