{ Unit suite for Wasm.Connector.Host — connector host functions.

  Lowering and target-plan checks run on every host. The live cases build
  tests/fixtures/connector/wasmlightconn.c with the host C compiler, bind
  it through a parsed `.wlc` at a literal absolute path, and call it
  through an instantiated module: scalar widths, sign and zero extension,
  C bool normalisation, floats, stack arguments, EntryPoint aliases, and
  the missing-library, missing-symbol, and unused-library rules.

  The compiled-executable cases run `wasmlight compile` for the host
  target, extract the packaged payload, and start it through the runtime
  shell's own path (Wasm.Shell) in-process: the embedded plan, startup
  re-resolution, library loading beside the executable, and native
  `_start` calling the fixture. }
program Wasm.Connector.Host.Test;

{$I Shared.inc}

{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}

uses
  Classes,
  Process,
  SysUtils,

  TestingPascalLibrary,
  Wasm.Abi,
  Wasm.Compile,
  Wasm.Compile.Catalog,
  Wasm.Connector,
  Wasm.Connector.Host,
  Wasm.Connector.Plan,
  Wasm.Connector.Resolve,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Jit.CodeBuffer,
  Wasm.MachO,
  Wasm.Native.Call,
  Wasm.Native.Load,
  Wasm.Native.Payload,
  Wasm.Package.Elf,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Shell,
  Wasm.Wasi,
  Wasm.Wat.Assembler;

const
  LIVE_WAT =
    '(module' + sLineBreak +
    '  (import "Conn" "Answer" (func $answer (result i32)))' + sLineBreak +
    '  (import "Conn" "Add" (func $add (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Mul" (func $mul (param i64 i64) (result i64)))' + sLineBreak +
    '  (import "Conn" "Scale" (func $scale (param f64 f32) (result f64)))' + sLineBreak +
    '  (import "Conn" "Neg8" (func $neg8 (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Join16" (func $join16 (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "IsNegative" (func $isneg (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Not" (func $not (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Sum9" (func $sum9 (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "conn_bump" (func $bump (param i32)))' + sLineBreak +
    '  (import "Conn" "conn_counter" (func $counter (result i32)))' + sLineBreak +
    '  (func (export "answer") (result i32) (call $answer))' + sLineBreak +
    '  (func (export "add") (param i32 i32) (result i32)' + sLineBreak +
    '    (call $add (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "mul") (param i64 i64) (result i64)' + sLineBreak +
    '    (call $mul (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "scale") (param f64 f32) (result f64)' + sLineBreak +
    '    (call $scale (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "neg8") (param i32) (result i32) (call $neg8 (local.get 0)))' + sLineBreak +
    '  (func (export "join16") (param i32 i32) (result i32)' + sLineBreak +
    '    (call $join16 (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "isneg") (param i32) (result i32) (call $isneg (local.get 0)))' + sLineBreak +
    '  (func (export "not") (param i32) (result i32) (call $not (local.get 0)))' + sLineBreak +
    '  (func (export "sum9") (result i32)' + sLineBreak +
    '    (call $sum9 (i32.const 1) (i32.const 2) (i32.const 3) (i32.const 4)' + sLineBreak +
    '      (i32.const 5) (i32.const 6) (i32.const 7) (i32.const 8) (i32.const 9)))' + sLineBreak +
    '  (func (export "bump") (result i32)' + sLineBreak +
    '    (call $bump (i32.const 5)) (call $bump (i32.const 6)) (call $counter)))';

  { A WASI command whose exit status is computed by the connector. }
  COMMAND_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))' + sLineBreak +
    '  (import "Conn" "Add" (func $add (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "conn_answer" (func $answer (result i32)))' + sLineBreak +
    '  (import "Conn" "Neg8" (func $neg8 (param i32) (result i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start")' + sLineBreak +
    '    (call $exit (call $add (call $answer)' + sLineBreak +
    '      (i32.sub (i32.const 0) (call $neg8 (i32.const 58)))))))';

  WASI_ONLY_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (call $exit (i32.const 7))))';

  ANSWER_WAT =
    '(module (import "Conn" "Answer" (func $a (result i32)))' + sLineBreak +
    '  (func (export "answer") (result i32) (call $a)))';

type
  TConnectorHostTests = class(TTestSuite)
  private
    FWork: string;
    FLibPath: string;
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FLinker: TWasmLinker;
    FLoaded: TWasmLoadedModule;
    FInstance: TWasmInstance;
    FHost: TWasmConnectorHost;

    function BuildFixture: Boolean;
    function LiveWlc(const ALibrary: string): string;
    function PlanFor(const AWlc, AWat: string): TWlcConnectorPlan;
    procedure Instantiate(const AWlc, AWat: string);
    function CallI32(const AName: string; const AArgs: array of TWasmValue): Int32;
    function LinkErrorOf(const AWlc, AWat: string): string;
    function LowerError(const AParamDecl: string): string;
    function CommandWlc(const ALibrary: string): string;
    procedure WriteText(const APath, AText: string);
    procedure WriteHostCatalog;
    function CompileCommand(const AWat, AWlc: string;
      out APayload: TWasmBytes): TWasmCompileResult;
    function RunPayload(const APayload: TWasmBytes): TWasmShellResult;
    function Rewrap(const AParsed: TWasmNativePayload;
      const APlan: TWasmBytes): TWasmBytes;
    function CanRunNative: Boolean;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestScalarLowering;
    procedure TestEnumLowersToUnderlyingType;
    procedure TestUnsupportedShapesFailClosed;
    procedure TestIncompatibleTargetIsALinkError;
    procedure TestScalarCallsThroughTheGate;
    procedure TestNarrowIntegersExtend;
    procedure TestBoolIsNormalised;
    procedure TestStackArgumentsAndVoid;
    procedure TestMissingLibraryIsALinkError;
    procedure TestMissingSymbolIsALinkError;
    procedure TestUnusedLibraryIsNeverLoaded;
    procedure TestSignaturesLinkWithoutLoading;
    procedure TestCompiledExecutableCallsTheLibrary;
    procedure TestCompiledExecutableLoadsBesideItself;
    procedure TestCompiledMissingLibraryFailsAtStartup;
    procedure TestCompiledTamperedPlanFails;
    procedure TestCompiledRetargetedPlanFails;
    procedure TestCompileRejectsUnsupportedShape;
    procedure TestCompileLinksThePlanForEveryTarget;
    procedure TestWasiOnlyExecutableHasNoPlan;
  end;

function QuoteUnix(const APath: string): string;
begin
  Result := '''' + StringReplace(APath, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function FixtureSource: string;
var
  Here, Candidate: string;
begin
  Result := '';
  Here := ExcludeTrailingPathDelimiter(GetCurrentDir);
  while Here <> '' do
  begin
    Candidate := IncludeTrailingPathDelimiter(Here) +
      'tests/fixtures/connector/wasmlightconn.c';
    if FileExists(Candidate) then
      Exit(Candidate);
    if ExtractFilePath(Here) = Here then
      Break;
    Here := ExcludeTrailingPathDelimiter(ExtractFilePath(Here));
  end;
end;

function TConnectorHostTests.BuildFixture: Boolean;
var
  OutText, Cmd: string;
begin
  Result := False;
  {$IFDEF WASM_NATIVE_CALL}
  if FixtureSource = '' then
    Exit;
  {$IFDEF DARWIN}
  Cmd := 'cc -dynamiclib -o ';
  {$ELSE}
  Cmd := 'cc -shared -fPIC -o ';
  {$ENDIF}
  Cmd := Cmd + QuoteUnix(FLibPath) + ' ' + QuoteUnix(FixtureSource);
  try
    Result := RunCommand('/bin/sh', ['-c', Cmd], OutText) and
      FileExists(FLibPath);
  except
    Result := False;
  end;
  {$ENDIF}
end;

function TConnectorHostTests.LiveWlc(const ALibrary: string): string;

  function Ext(const AEntry, ADecl: string): string;
  begin
    Result := '  [DllImport("' + ALibrary + '", EntryPoint = "' + AEntry +
      '")] static extern ' + ADecl + ';' + sLineBreak;
  end;

begin
  Result :=
    'static class Conn {' + sLineBreak +
    Ext('conn_answer', 'int Answer()') +
    Ext('conn_add', 'int Add(int a, int b)') +
    Ext('conn_mul64', 'long Mul(long a, long b)') +
    Ext('conn_scale', 'double Scale(double x, float f)') +
    Ext('conn_neg8', 'sbyte Neg8(sbyte v)') +
    Ext('conn_join16', 'ushort Join16(byte lo, byte hi)') +
    Ext('conn_is_negative', 'bool IsNegative(short v)') +
    Ext('conn_not', 'bool Not(bool b)') +
    Ext('conn_sum9', 'int Sum9(int a, int b, int c, int d, int e, int f, ' +
      'int g, int h, int i)') +
    '  [DllImport("' + ALibrary + '")] static extern void conn_bump(int by);' +
    sLineBreak +
    '  [DllImport("' + ALibrary + '")] static extern int conn_counter();' +
    sLineBreak +
    '  [DllImport("libwasmlight-never-loaded")] static extern void Unused();' +
    sLineBreak +
    '}' + sLineBreak;
end;

procedure TConnectorHostTests.BeforeEach;
begin
  FWork := IncludeTrailingPathDelimiter(GetTempDir) + 'wasmlight-conn-' +
    IntToStr(GetProcessID) + '-' + IntToHex(Random(MaxInt), 8);
  ForceDirectories(FWork);
  {$IFDEF DARWIN}
  FLibPath := IncludeTrailingPathDelimiter(FWork) + 'libwasmlightconn.dylib';
  {$ELSE}
  FLibPath := IncludeTrailingPathDelimiter(FWork) + 'libwasmlightconn.so';
  {$ENDIF}
  FEngine := nil;
  FStore := nil;
  FLinker := nil;
  FLoaded := nil;
  FInstance := nil;
  FHost := nil;
end;

procedure TConnectorHostTests.AfterEach;
begin
  FreeAndNil(FInstance);
  FreeAndNil(FHost);
  FreeAndNil(FLinker);
  FreeAndNil(FStore);
  FreeAndNil(FEngine);
  FreeAndNil(FLoaded);
  if FileExists(FLibPath) then
    DeleteFile(FLibPath);
  RemoveDir(FWork);
end;

function TConnectorHostTests.PlanFor(const AWlc, AWat: string):
  TWlcConnectorPlan;
var
  Loaded: TWasmLoadedModule;
begin
  Loaded := LoadModule(AssembleWatText(AWat));
  try
    Result := ResolveConnectorModule([ParseConnector(AWlc)], Loaded.Model,
      [WLC_WASI_MODULE]);
  finally
    Loaded.Free;
  end;
end;

procedure TConnectorHostTests.Instantiate(const AWlc, AWat: string);
begin
  FLoaded := LoadModule(AssembleWatText(AWat));
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  FLinker := TWasmLinker.Create(FStore);
  FHost := TWasmConnectorHost.Create(
    ResolveConnectorModule([ParseConnector(AWlc)], FLoaded.Model,
      [WLC_WASI_MODULE]), FWork);
  FHost.DefineImports(FLinker);
  FInstance := Wasm.Engine.Instantiate(FStore, FLinker, FLoaded);
end;

function TConnectorHostTests.CallI32(const AName: string;
  const AArgs: array of TWasmValue): Int32;
var
  Fn: TWasmFunc;
  Results: array[0..0] of TWasmValue;
begin
  Expect<Boolean>(FInstance.FindExportFunc(AName, Fn)).ToBe(True);
  Call(Fn, AArgs, Results);
  Result := Results[0].I32;
end;

function TConnectorHostTests.LinkErrorOf(const AWlc, AWat: string): string;
begin
  Result := '';
  try
    Instantiate(AWlc, AWat);
  except
    on E: EWasmLinkError do
      Result := E.Message;
  end;
end;

function TConnectorHostTests.LowerError(const AParamDecl: string): string;
var
  Plan: TWlcConnectorPlan;
begin
  Result := '';
  Plan := PlanFor(
    'static class C {' + sLineBreak +
    '  public struct S { public int A; }' + sLineBreak +
    '  public delegate void Cb(int x);' + sLineBreak +
    '  [DllImport("libc")] static extern int f(' + AParamDecl + ');' +
    sLineBreak + '}',
    '(module (import "C" "f" (func (param i32) (result i32))))');
  try
    LowerConnectorThunk(Plan, 0);
  except
    on E: EWasmLinkError do
      Result := E.Message;
  end;
end;

procedure TConnectorHostTests.TestScalarLowering;
var
  Plan: TWlcConnectorPlan;
  Call: TWasmConnectorCall;
begin
  Plan := PlanFor(LiveWlc('/opt/app/libconn.so'), LIVE_WAT);
  Call := LowerConnectorThunk(Plan, 3);
  Expect<Integer>(Ord(Call.ParamScalars[0])).ToBe(Ord(wcsF64));
  Expect<Integer>(Ord(Call.ParamScalars[1])).ToBe(Ord(wcsF32));
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsF64));
  Call := LowerConnectorThunk(Plan, 4);
  Expect<Integer>(Ord(Call.ParamScalars[0])).ToBe(Ord(wcsI8));
  Call := LowerConnectorThunk(Plan, 5);
  Expect<Integer>(Ord(Call.ParamScalars[0])).ToBe(Ord(wcsU8));
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsU16));
  Call := LowerConnectorThunk(Plan, 7);
  Expect<Boolean>(Call.ParamBools[0]).ToBe(True);
  Expect<Boolean>(Call.ResultBool).ToBe(True);
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsU8));
  Call := LowerConnectorThunk(Plan, 9);
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsVoid));
end;

procedure TConnectorHostTests.TestEnumLowersToUnderlyingType;
var
  Plan: TWlcConnectorPlan;
  Call: TWasmConnectorCall;
begin
  Plan := PlanFor(
    'static class C {' + sLineBreak +
    '  public enum Small : ushort { A = 1 }' + sLineBreak +
    '  public enum Plain { B }' + sLineBreak +
    '  [DllImport("libc")] static extern Plain f(Small s);' + sLineBreak +
    '}',
    '(module (import "C" "f" (func (param i32) (result i32))))');
  Call := LowerConnectorThunk(Plan, 0);
  Expect<Integer>(Ord(Call.ParamScalars[0])).ToBe(Ord(wcsU16));
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsI32));
end;

procedure TConnectorHostTests.TestUnsupportedShapesFailClosed;
begin
  Expect<Boolean>(Pos(MSG_WLC_UNSUPPORTED_TYPE,
    LowerError('[In, MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] byte[] b')) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos(MSG_WLC_UNSUPPORTED_TYPE, LowerError('string s')) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos(MSG_WLC_UNSUPPORTED_TYPE, LowerError('S s')) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos(MSG_WLC_UNSUPPORTED_TYPE, LowerError('Cb cb')) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos(MSG_WLC_UNSUPPORTED_TYPE, LowerError('IntPtr p')) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos(MSG_WLC_UNSUPPORTED_TYPE, LowerError('ref int p')) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos('"C"."f"', LowerError('string s')) > 0).ToBe(True);
end;

procedure TConnectorHostTests.TestIncompatibleTargetIsALinkError;
var
  Plan: TWlcConnectorPlan;
  Msg: string;
begin
  Plan := PlanFor(LiveWlc('/opt/app/libconn.so'), LIVE_WAT);
  CheckConnectorPlanTarget(Plan, wabSysvX64);
  CheckConnectorPlanTarget(Plan, wabAapcs64Apple);
  Msg := '';
  try
    CheckConnectorPlanTarget(Plan, wabNone);
  except
    on E: EWasmLinkError do
      Msg := E.Message;
  end;
  Expect<Boolean>(Pos(MSG_LINK_INCOMPATIBLE_PLAN, Msg) = 1).ToBe(True);
end;

procedure TConnectorHostTests.TestScalarCallsThroughTheGate;
var
  Fn: TWasmFunc;
  Results: array[0..0] of TWasmValue;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(LiveWlc(FLibPath), LIVE_WAT);
  Expect<Int32>(CallI32('answer', [])).ToBe(42);
  Expect<Int32>(CallI32('add', [MakeValueI32(40), MakeValueI32(2)])).ToBe(42);
  Expect<Int32>(CallI32('add', [MakeValueI32(High(Int32)), MakeValueI32(1)]))
    .ToBe(Low(Int32));
  Expect<Boolean>(FInstance.FindExportFunc('mul', Fn)).ToBe(True);
  Call(Fn, [MakeValueI64(-3), MakeValueI64(Int64(1) shl 40)], Results);
  Expect<Int64>(Results[0].I64).ToBe(-3 * (Int64(1) shl 40));
  Expect<Boolean>(FInstance.FindExportFunc('scale', Fn)).ToBe(True);
  Call(Fn, [MakeValueF64(1.5), MakeValueF32(4.0)], Results);
  Expect<Boolean>(Results[0].F64 = 6.0).ToBe(True);
end;

procedure TConnectorHostTests.TestNarrowIntegersExtend;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(LiveWlc(FLibPath), LIVE_WAT);
  { sbyte result sign-extends; the i32 argument truncates to sbyte. }
  Expect<Int32>(CallI32('neg8', [MakeValueI32(5)])).ToBe(-5);
  Expect<Int32>(CallI32('neg8', [MakeValueI32(300)])).ToBe(-44);
  Expect<Int32>(CallI32('neg8', [MakeValueI32(-128)])).ToBe(-128);
  { byte arguments truncate; the ushort result zero-extends. }
  Expect<Int32>(CallI32('join16', [MakeValueI32($1FF), MakeValueI32($92)]))
    .ToBe($92FF);
  { short argument: $18000 truncates to -32768. }
  Expect<Int32>(CallI32('isneg', [MakeValueI32($18000)])).ToBe(1);
  Expect<Int32>(CallI32('isneg', [MakeValueI32(7)])).ToBe(0);
end;

procedure TConnectorHostTests.TestBoolIsNormalised;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(LiveWlc(FLibPath), LIVE_WAT);
  Expect<Int32>(CallI32('not', [MakeValueI32(0)])).ToBe(1);
  Expect<Int32>(CallI32('not', [MakeValueI32(1)])).ToBe(0);
  { Any non-zero guest value is C true. }
  Expect<Int32>(CallI32('not', [MakeValueI32(256)])).ToBe(0);
  Expect<Int32>(CallI32('not', [MakeValueI32(-1)])).ToBe(0);
end;

procedure TConnectorHostTests.TestStackArgumentsAndVoid;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(LiveWlc(FLibPath), LIVE_WAT);
  Expect<Int32>(CallI32('sum9', [])).ToBe(45);
  Expect<Int32>(CallI32('bump', [])).ToBe(11);
end;

procedure TConnectorHostTests.TestMissingLibraryIsALinkError;
var
  Msg: string;
begin
  Msg := LinkErrorOf(LiveWlc(IncludeTrailingPathDelimiter(FWork) +
    'libabsent.so'), ANSWER_WAT);
  if NativeCallSupported then
    Expect<Boolean>(Pos(MSG_LINK_UNKNOWN_LIBRARY, Msg) = 1).ToBe(True)
  else
    Expect<Boolean>(Pos(MSG_LINK_INCOMPATIBLE_PLAN, Msg) = 1).ToBe(True);
  Expect<Boolean>(FInstance = nil).ToBe(True);
end;

procedure TConnectorHostTests.TestMissingSymbolIsALinkError;
var
  Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Msg := LinkErrorOf(
    'static class Conn {' + sLineBreak +
    '  [DllImport("' + FLibPath + '", EntryPoint = "conn_absent")]' +
    ' static extern int Answer();' + sLineBreak + '}', ANSWER_WAT);
  Expect<Boolean>(Pos(MSG_LINK_UNKNOWN_SYMBOL, Msg) = 1).ToBe(True);
  Expect<Boolean>(Pos('conn_absent', Msg) > 0).ToBe(True);
end;

procedure TConnectorHostTests.TestUnusedLibraryIsNeverLoaded;
var
  Plan: TWlcConnectorPlan;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  { LiveWlc declares Unused() in a library that does not exist anywhere. }
  Plan := PlanFor(LiveWlc(FLibPath), ANSWER_WAT);
  Expect<Integer>(Length(Plan.Libraries)).ToBe(1);
  Instantiate(LiveWlc(FLibPath), ANSWER_WAT);
  Expect<Int32>(CallI32('answer', [])).ToBe(42);
end;

procedure TConnectorHostTests.TestSignaturesLinkWithoutLoading;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  Linker: TWasmLinker;
  Loaded: TWasmLoadedModule;
  Imports: TWasmImports;
begin
  { The compile-time entries resolve every import without opening the
    (absent) library. }
  Loaded := LoadModule(AssembleWatText(LIVE_WAT));
  Engine := TWasmEngine.Create;
  Store := TWasmStore.Create(Engine);
  Linker := TWasmLinker.Create(Store);
  try
    DefineConnectorSignatures(Linker, ResolveConnectorModule(
      [ParseConnector(LiveWlc('/definitely/absent/libconn.so'))],
      Loaded.Model, [WLC_WASI_MODULE]));
    Imports := Linker.ResolveImports(Loaded);
    Expect<Integer>(Length(Imports.Funcs)).ToBe(11);
  finally
    Linker.Free;
    Store.Free;
    Engine.Free;
    Loaded.Free;
  end;
end;

{ --- compiled executables -------------------------------------------------- }

function TConnectorHostTests.CommandWlc(const ALibrary: string): string;
begin
  Result :=
    'static class Conn {' + sLineBreak +
    '  [DllImport("' + ALibrary + '", EntryPoint = "conn_add")]' +
    ' static extern int Add(int a, int b);' + sLineBreak +
    '  [DllImport("' + ALibrary + '")] static extern int conn_answer();' +
    sLineBreak +
    '  [DllImport("' + ALibrary + '", EntryPoint = "conn_neg8")]' +
    ' static extern sbyte Neg8(sbyte v);' + sLineBreak +
    '  [DllImport("libwasmlight-never-loaded")] static extern void Unused();' +
    sLineBreak + '}' + sLineBreak;
end;

procedure TConnectorHostTests.WriteText(const APath, AText: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(AText) > 0 then
      Stream.WriteBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
end;

{ A one-entry catalog for the host target over a structural template. The
  packaged bytes are only extracted again; the shell runs in-process. }
procedure TConnectorHostTests.WriteHostCatalog;
var
  Entries: TWasmShellEntries;
  Template: TWasmBytes;
  Stream: TFileStream;
begin
  SetLength(Entries, 1);
  Entries[0].Target := HostTargetId;
  Entries[0].Triple := TargetTriple(HostTargetId);
  Entries[0].Version := PROGRAM_VERSION;
  case HostTargetId of
    wtiAArch64Linux:
      Template := PlaceholderElfTemplate(weptAarch64Linux);
    wtiX64Linux:
      Template := PlaceholderElfTemplate(weptX86_64Linux);
    wtiAArch64Darwin:
      Template := WriteMachOShellTemplate(wmtAarch64Darwin);
  else
    Template := WriteMachOShellTemplate(wmtX86_64Darwin);
  end;
  if HostTargetId in [wtiAArch64Linux, wtiAArch64Darwin] then
    Entries[0].Arch := wtaAArch64
  else
    Entries[0].Arch := wtaX64;
  if HostTargetId in [wtiAArch64Linux, wtiX64Linux] then
  begin
    Entries[0].Os := wtoLinux;
    Entries[0].Format := wsfElf;
  end
  else
  begin
    Entries[0].Os := wtoDarwin;
    Entries[0].Format := wsfMachO;
  end;
  Entries[0].FileName := Entries[0].Triple + '.shell';
  Entries[0].Checksum := ShellChecksumBytes(Template);
  Entries[0].ShellPath := '';
  Stream := TFileStream.Create(IncludeTrailingPathDelimiter(FWork) +
    Entries[0].FileName, fmCreate);
  try
    Stream.WriteBuffer(Template[0], Length(Template));
  finally
    Stream.Free;
  end;
  WriteText(IncludeTrailingPathDelimiter(FWork) + SHELL_CATALOG_FILENAME,
    WriteShellCatalogText(Entries));
end;

function TConnectorHostTests.CompileCommand(const AWat, AWlc: string;
  out APayload: TWasmBytes): TWasmCompileResult;
var
  Request: TWasmCompileRequest;
begin
  APayload := nil;
  WriteHostCatalog;
  Request.ModulePath := '';
  Request.OutputPath := IncludeTrailingPathDelimiter(FWork) + 'app';
  Request.Target := '';
  Request.CatalogRoot := FWork;
  Request.Connectors := nil;
  if AWlc <> '' then
  begin
    WriteText(IncludeTrailingPathDelimiter(FWork) + 'conn.wlc', AWlc);
    SetLength(Request.Connectors, 1);
    Request.Connectors[0] := IncludeTrailingPathDelimiter(FWork) + 'conn.wlc';
  end;
  Result := CompileModuleBytes(AssembleWatText(AWat), Request);
  if Result.ExitCode = 0 then
    Expect<Boolean>(ExtractPackagedPayloadFromFile(Request.OutputPath,
      APayload)).ToBe(True);
end;

function TConnectorHostTests.RunPayload(const APayload: TWasmBytes):
  TWasmShellResult;
var
  Config: TWasmWasiConfig;
begin
  Config := TWasmWasiConfig.Create;
  try
    Result := RunShellBytes(APayload, Config);
  finally
    Config.Free;
  end;
end;

{ The same payload with its connector-plan section replaced and every hash
  recomputed, so only the plan itself can reject it. }
function TConnectorHostTests.Rewrap(const AParsed: TWasmNativePayload;
  const APlan: TWasmBytes): TWasmBytes;
var
  Params: TWasmNativePayloadWriteParams;
begin
  Params.IrFormatVer := AParsed.Header.IrFormatVer;
  Params.TargetArch := AParsed.Header.TargetArch;
  Params.TargetOs := AParsed.Header.TargetOs;
  Params.Flags := AParsed.Header.Flags;
  Params.AbiFingerprint := AParsed.Header.AbiFingerprint;
  Params.ModuleHash := AParsed.Header.ModuleHash;
  Params.ShellHash := AParsed.Header.ShellHash;
  Params.ModuleBytes := AParsed.ModuleBytes;
  Params.Funcs := AParsed.Funcs;
  Params.ConnectorPlan := APlan;
  Params.CapabilitySet := AParsed.CapabilitySet;
  Result := WriteNativePayload(Params);
end;

{ Native execution needs a backend, executable memory, the C-ABI gate, and
  a host C compiler for the fixture. A released 64-bit UNIX host must have
  all of them; anywhere else the compiled path is not runnable here. }
function TConnectorHostTests.CanRunNative: Boolean;
begin
  Result := False;
  {$IFDEF WASM_JIT_EXEC}
  Result := JitExecMemSupported and NativeCallSupported and
    IsReleasedCompileTarget(CompileHostTarget);
  {$ENDIF}
  if Result then
    Expect<Boolean>(BuildFixture).ToBe(True)
  else
    Expect<Boolean>(NativeCallSupported and
      IsReleasedCompileTarget(CompileHostTarget)).ToBe(False);
end;

procedure TConnectorHostTests.TestCompiledExecutableCallsTheLibrary;
var
  Payload: TWasmBytes;
  Parsed: TWasmNativePayload;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
begin
  if not CanRunNative then
    Exit;
  Res := CompileCommand(COMMAND_WAT, CommandWlc(FLibPath), Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Expect<Integer>(Ord(ParseNativePayload(Payload, Parsed))).ToBe(Ord(nprOk));
  Expect<Boolean>(Length(Parsed.ConnectorPlan) > 0).ToBe(True);
  { 42 + -(-58), through an aliased, a plain, and a narrow import. }
  Run := RunPayload(Payload);
  Expect<string>(Run.Diagnostic).ToBe('');
  Expect<Integer>(Run.ExitCode).ToBe(100);
end;

procedure TConnectorHostTests.TestCompiledExecutableLoadsBesideItself;
var
  Payload: TWasmBytes;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
  Bare, Beside: string;
  Src, Dst: TFileStream;
begin
  if not CanRunNative then
    Exit;
  { A bare DllImport name resolves in the running executable's directory
    (here the test program's) under the platform file name. }
  Bare := 'wasmlightconn' + IntToHex(Random(MaxInt), 8);
  Beside := IncludeTrailingPathDelimiter(NativeExecutableDirectory) +
    NativeLibraryFileName(Bare);
  Src := TFileStream.Create(FLibPath, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(Beside, fmCreate);
    try
      Dst.CopyFrom(Src, 0);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
  try
    Res := CompileCommand(COMMAND_WAT, CommandWlc(Bare), Payload);
    Expect<string>(Res.Diagnostic).ToBe('');
    Run := RunPayload(Payload);
    Expect<string>(Run.Diagnostic).ToBe('');
    Expect<Integer>(Run.ExitCode).ToBe(100);
  finally
    DeleteFile(Beside);
  end;
end;

procedure TConnectorHostTests.TestCompiledMissingLibraryFailsAtStartup;
var
  Payload: TWasmBytes;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
begin
  if not CanRunNative then
    Exit;
  { Libraries are deployment dependencies: compile does not open them, and
    the executable fails at startup, before instantiation, when one is
    absent. }
  Res := CompileCommand(COMMAND_WAT,
    CommandWlc('wasmlight-absent-' + IntToHex(Random(MaxInt), 8)), Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Run := RunPayload(Payload);
  Expect<Integer>(Run.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError: ' + MSG_LINK_UNKNOWN_LIBRARY,
    Run.Diagnostic) = 1).ToBe(True);
end;

procedure TConnectorHostTests.TestCompiledTamperedPlanFails;
var
  Payload: TWasmBytes;
  Parsed: TWasmNativePayload;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
  I: Integer;
begin
  if not CanRunNative then
    Exit;
  Res := CompileCommand(COMMAND_WAT, CommandWlc(FLibPath), Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Expect<Integer>(Ord(ParseNativePayload(Payload, Parsed))).ToBe(Ord(nprOk));

  { A well-hashed payload carrying a truncated plan: the strict decoder. }
  Run := RunPayload(Rewrap(Parsed, Copy(Parsed.ConnectorPlan, 0,
    Length(Parsed.ConnectorPlan) - 1)));
  Expect<Integer>(Run.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError: ' + MSG_WLCP_MALFORMED,
    Run.Diagnostic) = 1).ToBe(True);

  { A flipped byte inside the embedded plan: the payload checksum. }
  for I := 0 to High(Parsed.Sections) do
    if Parsed.Sections[I].Kind = WNEP_SECTION_CONNECTOR_PLAN then
      Payload[Parsed.Sections[I].DataOffset + 9] :=
        Payload[Parsed.Sections[I].DataOffset + 9] xor $FF;
  Run := RunPayload(Payload);
  Expect<Integer>(Run.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('malformed native payload', Run.Diagnostic) = 1)
    .ToBe(True);
end;

procedure TConnectorHostTests.TestCompiledRetargetedPlanFails;
var
  Payload: TWasmBytes;
  Parsed: TWasmNativePayload;
  Plan: TWlcConnectorPlan;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
begin
  if not CanRunNative then
    Exit;
  Res := CompileCommand(COMMAND_WAT, CommandWlc(FLibPath), Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Expect<Integer>(Ord(ParseNativePayload(Payload, Parsed))).ToBe(Ord(nprOk));
  Expect<Integer>(Ord(DecodeConnectorPlan(Parsed.ConnectorPlan, Plan)))
    .ToBe(Ord(wpdOk));
  { Add re-pointed at a different native symbol: well formed, correctly
    hashed, but not the plan resolution produces for this module. }
  Plan.Thunks[0].NativeSymbol := 'conn_mul64';
  Run := RunPayload(Rewrap(Parsed, EncodeConnectorPlan(Plan)));
  Expect<Integer>(Run.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError: ' + MSG_WLCP_MALFORMED,
    Run.Diagnostic) = 1).ToBe(True);
end;

procedure TConnectorHostTests.TestCompileRejectsUnsupportedShape;
var
  Payload: TWasmBytes;
  Res: TWasmCompileResult;
begin
  Res := CompileCommand(
    '(module (import "C" "f" (func (param i32)))' +
    '  (memory (export "memory") 1) (func (export "_start")))',
    'static class C { [DllImport("libc")] static extern void f(string s); }',
    Payload);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmLinkError: ' + MSG_WLC_UNSUPPORTED_TYPE,
    Res.Diagnostic) = 1).ToBe(True);
  Expect<Boolean>(FileExists(IncludeTrailingPathDelimiter(FWork) + 'app'))
    .ToBe(False);
end;

procedure TConnectorHostTests.TestCompileLinksThePlanForEveryTarget;
var
  Request: TWasmCompileRequest;
  Res: TWasmCompileResult;
  I: Integer;
begin
  { The plan is host-independent: every released target links the same
    imports and plans the same C calls. Without a catalog the pipeline
    stops after link, at strict compile or packaging, never at link. }
  WriteText(IncludeTrailingPathDelimiter(FWork) + 'conn.wlc',
    CommandWlc('/opt/app/libconn.so'));
  for I := 0 to RELEASED_TARGET_COUNT - 1 do
  begin
    Request.ModulePath := '';
    Request.OutputPath := IncludeTrailingPathDelimiter(FWork) + 'app';
    Request.Target := TargetTriple(ReleasedTargetId(I));
    Request.CatalogRoot := IncludeTrailingPathDelimiter(FWork) + 'no-catalog';
    Request.Connectors := nil;
    SetLength(Request.Connectors, 1);
    Request.Connectors[0] := IncludeTrailingPathDelimiter(FWork) + 'conn.wlc';
    Res := CompileModuleBytes(AssembleWatText(COMMAND_WAT), Request);
    Expect<Integer>(Res.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(False);
    Expect<Boolean>((Pos('EWasmPackagingError', Res.Diagnostic) > 0) or
      (Pos('EWasmCompileError', Res.Diagnostic) > 0)).ToBe(True);
  end;
end;

procedure TConnectorHostTests.TestWasiOnlyExecutableHasNoPlan;
var
  Payload: TWasmBytes;
  Parsed: TWasmNativePayload;
  Res: TWasmCompileResult;
begin
  if not CanRunNative then
    Exit;
  { A selected connector that binds nothing leaves the section empty: a
    module without connector imports compiles exactly as before. }
  Res := CompileCommand(WASI_ONLY_WAT, CommandWlc(FLibPath), Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Expect<Integer>(Ord(ParseNativePayload(Payload, Parsed))).ToBe(Ord(nprOk));
  Expect<Integer>(Length(Parsed.ConnectorPlan)).ToBe(0);
  Expect<Integer>(RunPayload(Payload).ExitCode).ToBe(7);
end;

procedure TConnectorHostTests.SetupTests;
begin
  Test('scalar declarations lower to their C widths', TestScalarLowering);
  Test('an enum lowers to its underlying type',
    TestEnumLowersToUnderlyingType);
  Test('shapes without a fixed lowering fail closed',
    TestUnsupportedShapesFailClosed);
  Test('a target without a C-ABI gate is a link error',
    TestIncompatibleTargetIsALinkError);
  Test('scalar calls reach the fixture through the gate',
    TestScalarCallsThroughTheGate);
  Test('narrow integers truncate in and extend out', TestNarrowIntegersExtend);
  Test('C bool is normalised both ways', TestBoolIsNormalised);
  Test('stack arguments and void calls', TestStackArgumentsAndVoid);
  Test('a missing library is a link error', TestMissingLibraryIsALinkError);
  Test('a missing symbol is a link error', TestMissingSymbolIsALinkError);
  Test('an unused declared library is never loaded',
    TestUnusedLibraryIsNeverLoaded);
  Test('compile-time signatures link without loading',
    TestSignaturesLinkWithoutLoading);
  Test('a compiled executable calls the connector library',
    TestCompiledExecutableCallsTheLibrary);
  Test('a bare library name loads beside the executable',
    TestCompiledExecutableLoadsBesideItself);
  Test('a missing library fails the executable at startup',
    TestCompiledMissingLibraryFailsAtStartup);
  Test('a truncated or tampered plan fails the executable',
    TestCompiledTamperedPlanFails);
  Test('a plan edited away from resolution fails the executable',
    TestCompiledRetargetedPlanFails);
  Test('compile rejects a declaration without a fixed lowering',
    TestCompileRejectsUnsupportedShape);
  Test('compile links the same plan for every released target',
    TestCompileLinksThePlanForEveryTarget);
  Test('a module without connector imports embeds no plan',
    TestWasiOnlyExecutableHasNoPlan);
end;

begin
  Randomize;
  TestRunnerProgram.AddSuite(TConnectorHostTests.Create('Wasm.Connector.Host'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
