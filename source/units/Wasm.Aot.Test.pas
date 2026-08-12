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
  Wasm.Runtime.Values;

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

{ One export descriptor: name, kind byte $00 (func), function index. }
function FuncExport(const AName: string; const AIndex: UInt32): TWasmBytes;
begin
  Result := Cat([ULeb(UInt32(Length(AName))), StrBytes(AName), BLit([$00]),
    ULeb(AIndex)]);
end;

{ A four-function module for the Wave-2 multi-function + declined proof
  (aot-spec §7.3):
    f0 "add"            (i32 i32)->i32  local.get0 local.get1 i32.add   [leaf, compiled]
    f1 "addcaller"      (i32 i32)->i32  local.get0 local.get1 call 0    [compiled -> compiled]
    f2 "declined"       ()->i32         block (try_table (catch_all) empty-body) i32.const 7
                                        [DECLINED: owns a try_table handler table (EH),
                                         so JitCanCompile refuses it — runs interpreted,
                                         returns 7 with no throw]
    f3 "declinedcaller" ()->i32         call 2                          [compiled -> DECLINED/interpreted]
  It needs no tag section: catch_all references a label, not a tag, and nothing
  throws — so f2 simply runs its empty try body and returns 7. The point is the
  compiled/interpreted mix: f1 (compiled) calls f0 (compiled), and f3 (compiled)
  calls f2 (interpreted), all across the CompiledEntry seam. }
function MultiFuncModuleBytes: TWasmBytes;
var
  Type0, Type1: TWasmBytes;
  Body0, Body1, Body2, Body3: TWasmBytes;
begin
  Type0 := BLit([$60, $02, $7F, $7F, $01, $7F]);   { (i32 i32) -> i32 }
  Type1 := BLit([$60, $00, $01, $7F]);             { () -> i32 }
  Body0 := BLit([$00, $20, $00, $20, $01, $6A, $0B]);
  Body1 := BLit([$00, $20, $00, $20, $01, $10, $00, $0B]);
  { $00 locals; $02 $40 block void; $1F $40 try_table void; $01 catch count;
    $02 $00 catch_all -> label0 (the block); $0B end try_table; $0B end block;
    $41 $07 i32.const 7; $0B end func. }
  Body2 := BLit([$00, $02, $40, $1F, $40, $01, $02, $00, $0B, $0B, $41, $07, $0B]);
  Body3 := BLit([$00, $10, $02, $0B]);
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([Type0, Type1])),
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$01]), BLit([$01])])),
    Sect(7, VecOf([
      FuncExport('add', 0),
      FuncExport('addcaller', 1),
      FuncExport('declined', 2),
      FuncExport('declinedcaller', 3)])),
    Sect(10, VecOf([CodeEntry(Body0), CodeEntry(Body1), CodeEntry(Body2),
      CodeEntry(Body3)]))
  ]);
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
    procedure TestJitAndAotCodeAreByteIdentical;
    procedure TestGuardRejectsWrongIrVersion;
    procedure TestGuardRejectsWrongArch;
    procedure TestGuardRejectsCorruptChecksum;
    procedure TestGuardRejectsModuleHashMismatch;
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
    Fresh := JitStageFunctionBytes(Store, @Loaded.Ir.Functions[0],
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

    { The whole module serialized: four records, f2 (EH) declined, the rest
      compiled. A declined record carries no code. }
    ParseRes := ParseAotArtifact(Artifact, Parsed);
    Expect<Integer>(Ord(ParseRes)).ToBe(Ord(aprOk));
    Expect<Integer>(Length(Parsed.Funcs)).ToBe(4);
    Expect<Boolean>(Parsed.Funcs[0].Compiled).ToBe(True);
    Expect<Boolean>(Parsed.Funcs[1].Compiled).ToBe(True);
    Expect<Boolean>(Parsed.Funcs[2].Compiled).ToBe(False);
    Expect<Boolean>(Parsed.Funcs[3].Compiled).ToBe(True);
    Expect<Integer>(Length(Parsed.Funcs[2].Code)).ToBe(0);

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

    { declined(): interpreted f2 -> 7. }
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, Declined, nil, @Res[0]);
    Expect<UInt64>(Res[0].Bits).ToBe(InterpResult1(Bytes_, 'declined', []));
    Expect<Integer>(Res[0].I32).ToBe(7);

    { declinedcaller(): compiled f3 calls DECLINED/interpreted f2 across the
      seam -> 7 (compiled<->interpreted interop). }
    Res[0].Bits := High(UInt64);
    InterpInvoke(Store, DeclinedCaller, nil, @Res[0]);
    Expect<UInt64>(Res[0].Bits)
      .ToBe(InterpResult1(Bytes_, 'declinedcaller', []));
    Expect<Integer>(Res[0].I32).ToBe(7);
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
    Staged := JitStageFunctionBytes(JitStore, @JitLoaded.Ir.Functions[0],
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

procedure TAotTests.SetupTests;
begin
  Test('AOT-compiled i32.add loads from the artifact and matches the interpreter',
    TestMilestoneAddViaArtifact);
  Test('the artifact code is position-independent (byte-identical to a JIT staging)',
    TestArtifactCodeIsPositionIndependent);
  Test('a whole multi-function module AOT-loads, declined function stays interpreted',
    TestMultiFunctionWithDeclined);
  Test('AOT-loaded code is byte-identical to a fresh JIT compilation',
    TestJitAndAotCodeAreByteIdentical);
  Test('a wrong IR-version artifact is rejected (interpret fall-back)',
    TestGuardRejectsWrongIrVersion);
  Test('a wrong-arch artifact is rejected (interpret fall-back)',
    TestGuardRejectsWrongArch);
  Test('a corrupted-checksum artifact is rejected (interpret fall-back)',
    TestGuardRejectsCorruptChecksum);
  Test('an artifact loaded against a different module is rejected (moduleHash)',
    TestGuardRejectsModuleHashMismatch);
end;

begin
  TestRunnerProgram.AddSuite(TAotTests.Create('Wasm.Aot'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
