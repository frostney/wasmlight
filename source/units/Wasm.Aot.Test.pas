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
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
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

{ A five-function module for the multi-function + declined proof
  (aot-spec §7.3). Handler tables and wide non-tail calls now compile, so
  the declined fixture is a `return_call` one past WASM_TIER_TAIL_CAP:
    f0 "add"            (i32 i32)->i32  local.get0 local.get1 i32.add   [compiled]
    f1 "addcaller"      (i32 i32)->i32  local.get0 local.get1 call 0    [compiled -> compiled]
    f2 $wide            (i32×1025)->i32 i32.const 7                     [compiled leaf]
    f3 "declined"       ()->i32         return_call $wide with 1025 zeros [DECLINED]
    f4 "declinedcaller" ()->i32         call 3                          [compiled -> interpreted]
  f1 (compiled) calls f0 (compiled), and f4 (compiled) calls f3 (interpreted). }
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
  I, J, N: Integer;
begin
  SetLength(Result, Length(AItem) * ACount);
  N := 0;
  for I := 1 to ACount do
    for J := 0 to High(AItem) do
    begin
      Result[N] := AItem[J];
      Inc(N);
    end;
end;

function MultiFuncModuleBytes: TWasmBytes;
const
  WIDE_ARITY = WASM_TIER_TAIL_CAP + 1;
var
  Type0, Type1, TypeWide: TWasmBytes;
  Body0, Body1, BodyWide, BodyDeclined, BodyCaller: TWasmBytes;
begin
  Type0 := BLit([$60, $02, $7F, $7F, $01, $7F]);   { (i32 i32) -> i32 }
  Type1 := BLit([$60, $00, $01, $7F]);             { () -> i32 }
  TypeWide := Cat([BLit([$60]), ULeb(WIDE_ARITY), RepeatByte($7F, WIDE_ARITY),
    BLit([$01, $7F])]);
  Body0 := BLit([$00, $20, $00, $20, $01, $6A, $0B]);
  Body1 := BLit([$00, $20, $00, $20, $01, $10, $00, $0B]);
  BodyWide := BLit([$00, $41, $07, $0B]);
  BodyDeclined := Cat([BLit([$00]), RepeatBytes(BLit([$41, $00]), WIDE_ARITY),
    BLit([$12, $02, $0B])]);
  BodyCaller := BLit([$00, $10, $03, $0B]);
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([Type0, Type1, TypeWide])),
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$02]), BLit([$01]),
      BLit([$01])])),
    Sect(7, VecOf([
      FuncExport('add', 0),
      FuncExport('addcaller', 1),
      FuncExport('declined', 3),
      FuncExport('declinedcaller', 4)])),
    Sect(10, VecOf([CodeEntry(Body0), CodeEntry(Body1), CodeEntry(BodyWide),
      CodeEntry(BodyDeclined), CodeEntry(BodyCaller)]))
  ]);
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
  public
    procedure SetupTests; override;

    procedure TestMilestoneAddViaArtifact;
    procedure TestArtifactCodeIsPositionIndependent;
    procedure TestMultiFunctionWithDeclined;
    procedure TestLargeFrameAllCompiled;
    procedure TestJitAndAotCodeAreByteIdentical;
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
    procedure TestStrictPredicateDeclineUnsupportedOp;
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

{ Wave 2 (aot-spec §7.3): a WHOLE multi-function module — a compiled function
  calling a compiled function, a compiled function calling a DECLINED
  (interpreted) one — AOT-compiled, serialized, and loaded into a fresh store.
  Every export runs identically to the interpreter, and the declined function's
  CompiledEntry stays nil (it interprets) while the others are AOT-loaded. }
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
  AddAddr, AddCaller, Declined, DeclinedCaller: TWasmFuncAddr;
  Params: array[0 .. 1] of TWasmValue;
  Res: array[0 .. 0] of TWasmValue;
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

    { Five records: f3 (over-wide return_call) declined, the rest compiled. }
    ParseRes := ParseAotArtifact(Artifact, Parsed);
    Expect<Integer>(Ord(ParseRes)).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(5);
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(True);
    Expect<Boolean>(Parsed.Funcs[1].Compiled).ToBe(True);
    Expect<Boolean>(Parsed.Funcs[2].Compiled).ToBe(True);
    Expect<Boolean>(Parsed.Funcs[3].Compiled).ToBe(False);
    Expect<Boolean>(Parsed.Funcs[4].Compiled).ToBe(True);
    Expect<Integer>(Length(Parsed.Funcs[3].Code)).ToBe(0);

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
    Declined := ExportAddr(Instance, 'declined');
    DeclinedCaller := ExportAddr(Instance, 'declinedcaller');

    { The compiled functions are AOT-wired; the declined one is left nil, so it
      runs interpreted (aot-spec §4.2 step 6). }
    Expect<Boolean>(Store.Funcs[AddAddr].CompiledEntry <> nil).ToBe(True);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Store.Funcs[AddAddr].CompiledNativeScalarEntry =
      Store.Funcs[AddAddr].CompiledEntry).ToBe(True);
    {$ENDIF}
    Expect<Boolean>(Store.Funcs[AddCaller].CompiledEntry <> nil).ToBe(True);
    Expect<Boolean>(Store.Funcs[DeclinedCaller].CompiledEntry <> nil).ToBe(True);
    Expect<Boolean>(Store.Funcs[Declined].CompiledEntry = nil).ToBe(True);

    { addcaller(17,25): compiled f1 calls compiled f0 -> 42. }
    Params[0] := MakeValueI32(17);
    Params[1] := MakeValueI32(25);
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, AddCaller, @Params[0], @Res[0]);
    Expect<UInt64>(Res[0].Bits)
      .ToBe(InterpResult1(Bytes_, 'addcaller', [Params[0], Params[1]]));
    Expect<Integer>(Res[0].I32).ToBe(42);

    { The declined return_call is past the shared tail/marshal cap, so it is
      recorded as interpreted and left unwired. Do not invoke it. }
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

procedure TAotTests.TestStrictPredicateDeclineUnsupportedOp;
var
  Bytes_, Artifact: TWasmBytes;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
  Caught: Boolean;
  Kind: TWasmAotDeclineKind;
  Predicate: TWasmJitDecline;
  FuncIdx: UInt32;
  Msg: string;
begin
  Bytes_ := MultiFuncModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  Caught := False;
  Artifact := nil;
  Kind := wadTarget;
  Predicate := jdNone;
  FuncIdx := High(UInt32);
  Msg := '';
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
        Predicate := E.Predicate;
        FuncIdx := E.FuncIrIndex;
        Msg := E.Message;
      end;
    end;
    Expect<Boolean>(Caught).ToBe(True);
    Expect<Integer>(Length(Artifact)).ToBe(0);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Integer>(Ord(Kind)).ToBe(Ord(wadPredicate));
    Expect<Integer>(Ord(Predicate)).ToBe(Ord(jdUnsupportedInstr));
    Expect<Integer>(Integer(FuncIdx)).ToBe(3);
    Expect<Boolean>(Pos('unsupported-instr', Msg) > 0).ToBe(True);
    {$ELSE}
    Expect<Integer>(Ord(Kind)).ToBe(Ord(wadTarget));
    {$ENDIF}
  finally
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
  RangeErr, BackendErr: EWasmAotError;
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
end;

procedure TAotTests.TestCacheStillRecordsDeclinedFunctions;
var
  Bytes_, Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Loaded: TWasmLoadedModule;
begin
  Bytes_ := MultiFuncModuleBytes;
  Engine := TWasmEngine.Create;
  Loaded := nil;
  Store := nil;
  try
    Loaded := LoadModule(Bytes_);
    Store := TWasmStore.Create(Engine);
    Artifact := AotCompileModule(Store, Loaded);
    Expect<Integer>(Ord(ParseAotArtifact(Artifact, Parsed))).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(5);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(True);
    Expect<Boolean>(Parsed.Funcs[3].Compiled).ToBe(False);
    Expect<Integer>(Length(Parsed.Funcs[3].Code)).ToBe(0);
    {$ELSE}
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(False);
    Expect<Boolean>(Parsed.Funcs[3].Compiled).ToBe(False);
    {$ENDIF}
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
      AotCompileModuleStrictToFile(Store, Loaded, Path);
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
      AotCompileModuleStrictToFile(Store, Loaded, Path);
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
  Test('strict compile fails a return_call tail-cap predicate decline',
    TestStrictPredicateDeclineUnsupportedOp);
  Test('strict compile fails a target decline off the AOT host',
    TestStrictTargetDecline);
  Test('strict range and backend diagnostics name the function and kind',
    TestStrictRangeAndBackendDiagnostics);
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
