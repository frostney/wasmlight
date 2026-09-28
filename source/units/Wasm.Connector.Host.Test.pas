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
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  TestingPascalLibrary,
  Wasm.Abi,
  Wasm.Compile,
  Wasm.Compile.Catalog,
  Wasm.Connector,
  Wasm.Connector.Callbacks,
  Wasm.Connector.Host,
  Wasm.Connector.Memory,
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
  Wasm.Runtime.Traps,
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

  { Buffers, handles, and callbacks, run through the interpreter. Table 0:
    1 $double i32(i32), 2 $tick void(), 3 $get i32(), 4 $note void(i32),
    5 $boom i32(i32) traps, 6 $wrong i32(i64); 0 and 7 are null. }
  SHAPES_WAT =
    '(module' + sLineBreak +
    '  (import "Conn" "SumBytes" (func $sum (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Fill" (func $fill (param i32 i32 i32)))' + sLineBreak +
    '  (import "Conn" "Reverse4" (func $rev (param i32)))' + sLineBreak +
    '  (import "Conn" "ScaleInPlace" (func $scale (param i32 i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "CounterNew" (func $cnew (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "CounterAdd" (func $cadd (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Apply" (func $apply (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "ApplyTwice" (func $twice (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "CallVoid" (func $cvoid (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "CallGet" (func $cget (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Register" (func $reg (param i32)))' + sLineBreak +
    '  (import "Conn" "Fire" (func $fire (param i32)))' + sLineBreak +
    '  (import "Conn" "Post" (func $post (param i32 i32)))' + sLineBreak +
    '  (import "Conn" "BorrowAndCall" (func $bac (param i32 i32 i32) (result i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (global $seen (mut i32) (i32.const 0))' + sLineBreak +
    '  (table 8 funcref)' + sLineBreak +
    '  (elem (i32.const 1) func $double $tick $get $note $boom $wrong)' + sLineBreak +
    '  (func $double (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2)))' + sLineBreak +
    '  (func $tick (global.set $seen (i32.add (global.get $seen) (i32.const 1))))' + sLineBreak +
    '  (func $get (result i32) (i32.const 21))' + sLineBreak +
    '  (func $note (param i32) (global.set $seen (local.get 0)))' + sLineBreak +
    '  (func $boom (param i32) (result i32) (unreachable))' + sLineBreak +
    '  (func $wrong (param i64) (result i32) (i32.const 0))' + sLineBreak +
    '  (func (export "seen") (result i32) (global.get $seen))' + sLineBreak +
    '  (func (export "sum") (param i32 i32) (result i32) (call $sum (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "fill") (param i32 i32 i32) (call $fill (local.get 0) (local.get 1) (local.get 2)))' + sLineBreak +
    '  (func (export "rev") (param i32) (call $rev (local.get 0)))' + sLineBreak +
    '  (func (export "scale") (param i32 i32 i32) (result i32)' + sLineBreak +
    '    (call $scale (local.get 0) (local.get 1) (local.get 2)))' + sLineBreak +
    '  (func (export "cnew") (param i32) (result i32) (call $cnew (local.get 0)))' + sLineBreak +
    '  (func (export "cadd") (param i32 i32) (result i32) (call $cadd (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "apply") (param i32 i32) (result i32) (call $apply (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "twice") (param i32 i32) (result i32) (call $twice (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "cvoid") (param i32) (result i32) (call $cvoid (local.get 0)))' + sLineBreak +
    '  (func (export "cget") (param i32) (result i32) (call $cget (local.get 0)))' + sLineBreak +
    '  (func (export "reg") (param i32) (call $reg (local.get 0)))' + sLineBreak +
    '  (func (export "fire") (param i32) (call $fire (local.get 0)))' + sLineBreak +
    '  (func (export "post") (param i32 i32) (call $post (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "bac") (param i32 i32 i32) (result i32)' + sLineBreak +
    '    (call $bac (local.get 0) (local.get 1) (local.get 2))))';

  { The same shapes from a compiled `_start`: bytes 1..4 summed (10), a
    handle counter (5 + 3 = 8), a retained callback through the table (6
    doubled + 1 = 13), a scoped one (3 doubled twice = 12), a void callback
    (7), and a queued notification of 50 read back from the global — 100.
    Then copy-out (Fill writes 7, 8, 9 at 200), inout (Reverse4 turns 1..4
    at 300 into 4..1), and a scoped borrow (ScaleInPlace doubles 1, 2, 3 at
    400 and returns 12) are read back from guest memory: 9 - 8 + 4 - 1 + 12
    - 6 = 10. Exit code 110. }
  NATIVE_SHAPES_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))' + sLineBreak +
    '  (import "Conn" "Fill" (func $fill (param i32 i32 i32)))' + sLineBreak +
    '  (import "Conn" "Reverse4" (func $rev (param i32)))' + sLineBreak +
    '  (import "Conn" "ScaleInPlace" (func $scale (param i32 i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "SumBytes" (func $sum (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "CounterNew" (func $cnew (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "CounterAdd" (func $cadd (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Apply" (func $apply (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "ApplyTwice" (func $twice (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "CallVoid" (func $cvoid (param i32) (result i32)))' + sLineBreak +
    '  (import "Conn" "Post" (func $post (param i32 i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (data (i32.const 100) "\01\02\03\04")' + sLineBreak +
    '  (data (i32.const 300) "\01\00\00\00\02\00\00\00' +
    '\03\00\00\00\04\00\00\00")' + sLineBreak +
    '  (data (i32.const 400) "\01\00\02\00\03\00")' + sLineBreak +
    '  (global $seen (mut i32) (i32.const 0))' + sLineBreak +
    '  (table 4 funcref)' + sLineBreak +
    '  (elem (i32.const 1) func $double $tick $note)' + sLineBreak +
    '  (func $double (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2)))' + sLineBreak +
    '  (func $tick (global.set $seen (i32.add (global.get $seen) (i32.const 1))))' + sLineBreak +
    '  (func $note (param i32) (global.set $seen (local.get 0)))' + sLineBreak +
    '  (func (export "_start")' + sLineBreak +
    '    (local $acc i32)' + sLineBreak +
    '    (local.set $acc (call $sum (i32.const 100) (i32.const 4)))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc)' + sLineBreak +
    '      (call $cadd (call $cnew (i32.const 5)) (i32.const 3))))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc) (call $apply (i32.const 1) (i32.const 6))))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc) (call $twice (i32.const 1) (i32.const 3))))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc) (call $cvoid (i32.const 2))))' + sLineBreak +
    '    (call $post (i32.const 3) (i32.const 50))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc) (global.get $seen)))' + sLineBreak +
    '    (call $fill (i32.const 200) (i32.const 3) (i32.const 7))' + sLineBreak +
    '    (call $rev (i32.const 300))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc)' + sLineBreak +
    '      (call $scale (i32.const 400) (i32.const 3) (i32.const 2))))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc) (i32.sub' + sLineBreak +
    '      (i32.load8_u (i32.const 202)) (i32.load8_u (i32.const 201)))))' + sLineBreak +
    '    (local.set $acc (i32.add (local.get $acc) (i32.sub' + sLineBreak +
    '      (i32.load (i32.const 300)) (i32.load (i32.const 312)))))' + sLineBreak +
    '    (local.set $acc (i32.sub (local.get $acc) (i32.load16_s (i32.const 404))))' + sLineBreak +
    '    (call $exit (local.get $acc))))';

  { A callback that traps inside a native connector call. }
  NATIVE_CALLBACK_TRAP_WAT =
    '(module' + sLineBreak +
    '  (import "Conn" "Apply" (func $apply (param i32 i32) (result i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (table 2 funcref)' + sLineBreak +
    '  (elem (i32.const 1) func $boom)' + sLineBreak +
    '  (func $boom (param i32) (result i32) (unreachable))' + sLineBreak +
    '  (func (export "_start") (drop (call $apply (i32.const 1) (i32.const 1)))))';

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
    function LowerError(const AParamDecl: string;
      const AWatParams: string = 'i32'): string;
    function CommandWlc(const ALibrary: string): string;
    function ShapesWlc(const ALibrary: string): string;
    procedure WriteGuest(const AOffset: UInt32; const ABytes: array of Byte);
    function ReadGuest(const AOffset, ALength: UInt32): TBytes;
    function CallError(const AName: string; const AArgs: array of TWasmValue;
      out AClass: string): string;
    procedure CallVoid(const AName: string; const AArgs: array of TWasmValue);
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
    procedure ExpectUnsupported(const AMessage, ADetail: string);
    procedure TestUnsupportedShapesFailClosed;
    procedure TestArrayLowering;
    procedure TestArrayRulesFailClosed;
    procedure TestHandleAndCallbackLowering;
    procedure TestIncompatibleTargetIsALinkError;
    procedure TestScalarCallsThroughTheGate;
    procedure TestNarrowIntegersExtend;
    procedure TestBoolIsNormalised;
    procedure TestStackArgumentsAndVoid;
    procedure TestMissingLibraryIsALinkError;
    procedure TestMissingSymbolIsALinkError;
    procedure TestUnusedLibraryIsNeverLoaded;
    procedure TestSignaturesLinkWithoutLoading;
    procedure TestBuffersCopyThroughTheChokepoint;
    procedure TestBufferRangesTrap;
    procedure TestScopedBorrowWritesInPlace;
    procedure TestHandlesAreOpaque;
    procedure TestCallbacksReenterTheGuest;
    procedure TestQueuedNotificationDrainsAfterTheCall;
    procedure TestCallbackTableEntriesTrap;
    procedure TestCallbackFailureIsDeferred;
    procedure TestBorrowCannotJoinACallback;
    procedure TestNinthCallbackIsRejected;
    procedure TestMissingMemoryIsALinkError;
    procedure TestCompiledExecutableCallsTheLibrary;
    procedure TestCompiledExecutableRunsEveryShape;
    procedure TestCompiledCallbackTrapUnwinds;
    procedure TestCompiledMissingSymbolFailsAtStartup;
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
  Cmd := 'cc -dynamiclib -pthread -o ';
  {$ELSE}
  Cmd := 'cc -shared -fPIC -pthread -o ';
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
var
  Search: TSearchRec;
begin
  FreeAndNil(FInstance);
  FreeAndNil(FHost);
  FreeAndNil(FLinker);
  FreeAndNil(FStore);
  FreeAndNil(FEngine);
  FreeAndNil(FLoaded);
  if FindFirst(IncludeTrailingPathDelimiter(FWork) + '*', faAnyFile,
    Search) = 0 then
  try
    repeat
      if (Search.Name <> '.') and (Search.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(FWork) + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
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
  FHost := TWasmConnectorHost.Create(FStore,
    ResolveConnectorModule([ParseConnector(AWlc)], FLoaded.Model,
      [WLC_WASI_MODULE]), FWork, nil);
  FHost.DefineImports(FLinker);
  FInstance := Wasm.Engine.Instantiate(FStore, FLinker, FLoaded);
  FHost.Attach(FInstance);
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

function TConnectorHostTests.LowerError(const AParamDecl: string;
  const AWatParams: string): string;
var
  Plan: TWlcConnectorPlan;
begin
  Result := '';
  Plan := PlanFor(
    'static class C {' + sLineBreak +
    '  public struct S { public int A; }' + sLineBreak +
    '  public delegate void Cb(int x);' + sLineBreak +
    '  public delegate long Wide(long x);' + sLineBreak +
    '  public delegate int Two(int a, int b);' + sLineBreak +
    '  [Queued] public delegate int QGet();' + sLineBreak +
    '  [DllImport("libc")] static extern int f(' + AParamDecl + ');' +
    sLineBreak + '}',
    '(module (import "C" "f" (func (param ' + AWatParams +
    ') (result i32))))');
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
  Expect<Integer>(Ord(Call.Params[0].Scalar)).ToBe(Ord(wcsF64));
  Expect<Integer>(Ord(Call.Params[1].Scalar)).ToBe(Ord(wcsF32));
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsF64));
  Call := LowerConnectorThunk(Plan, 4);
  Expect<Integer>(Ord(Call.Params[0].Scalar)).ToBe(Ord(wcsI8));
  Call := LowerConnectorThunk(Plan, 5);
  Expect<Integer>(Ord(Call.Params[0].Scalar)).ToBe(Ord(wcsU8));
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsU16));
  Call := LowerConnectorThunk(Plan, 7);
  Expect<Integer>(Ord(Call.Params[0].Kind)).ToBe(Ord(wcpBool));
  Expect<Integer>(Ord(Call.ResultKind)).ToBe(Ord(wcrBool));
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(wcsU8));
  Call := LowerConnectorThunk(Plan, 9);
  Expect<Integer>(Ord(Call.ResultKind)).ToBe(Ord(wcrVoid));
  Expect<Boolean>(Call.NeedsMemory).ToBe(False);
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
  Expect<Integer>(Ord(Call.Params[0].Scalar)).ToBe(Ord(wcsU16));
  Expect<Integer>(Ord(Call.ResultScalar)).ToBe(Ord(Wasm.Abi.wcsI32));
end;

procedure TConnectorHostTests.ExpectUnsupported(const AMessage,
  ADetail: string);
begin
  Expect<Boolean>(Pos(MSG_WLC_UNSUPPORTED_TYPE + ': "C"."f"', AMessage) = 1)
    .ToBe(True);
  Expect<Boolean>(Pos(ADetail, AMessage) > 0).ToBe(True);
end;

procedure TConnectorHostTests.TestUnsupportedShapesFailClosed;
begin
  { D14: strings, structs, and by-reference parameters have no lowering. }
  ExpectUnsupported(LowerError('string s'), 'string');
  ExpectUnsupported(LowerError('S s'), 'S');
  ExpectUnsupported(LowerError('ref int p'), 'by reference');
  ExpectUnsupported(LowerError('out int p'), 'by reference');
  ExpectUnsupported(LowerError('[MarshalAs(UnmanagedType.LPStr)] string s'),
    'string');
  ExpectUnsupported(LowerError('[Scoped] int p'), '[Scoped]');
  { D13: only void(), void(i32), i32(), and i32(i32) delegates. }
  ExpectUnsupported(LowerError('Wide w'), 'delegate Wide');
  ExpectUnsupported(LowerError('Two t'), 'delegate Two');
  ExpectUnsupported(LowerError('QGet q'), '[Queued] delegate QGet');
end;

procedure TConnectorHostTests.TestArrayLowering;
var
  Plan: TWlcConnectorPlan;
  Call: TWasmConnectorCall;
begin
  Plan := PlanFor(
    'static class C {' + sLineBreak +
    '  [DllImport("libc")] static extern int f(' +
    '[In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] short[] a,' +
    ' uint n, [Out, MarshalAs(UnmanagedType.LPArray, SizeConst = 3)] long[] b,' +
    ' [Scoped, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] byte[] c,' +
    ' [In, Out, MarshalAs(UnmanagedType.LPArray, SizeConst = 2)] double[] d);' +
    sLineBreak + '}',
    '(module (import "C" "f" (func (param i32 i32 i32 i32 i32) (result i32))))');
  Call := LowerConnectorThunk(Plan, 0);
  Expect<Boolean>(Call.NeedsMemory).ToBe(True);
  Expect<Integer>(Ord(Call.Params[0].Kind)).ToBe(Ord(wcpBuffer));
  Expect<Integer>(Ord(Call.Params[0].Direction)).ToBe(Ord(wldIn));
  Expect<Integer>(Integer(Call.Params[0].ElemSize)).ToBe(2);
  Expect<Integer>(Call.Params[0].SizeConst).ToBe(-1);
  Expect<Integer>(Call.Params[0].SizeParam).ToBe(1);
  Expect<Integer>(Ord(Call.Params[2].Direction)).ToBe(Ord(wldOut));
  Expect<Integer>(Integer(Call.Params[2].ElemSize)).ToBe(8);
  Expect<Integer>(Call.Params[2].SizeConst).ToBe(3);
  Expect<Integer>(Ord(Call.Params[3].Kind)).ToBe(Ord(wcpBorrow));
  Expect<Integer>(Ord(Call.Params[4].Direction)).ToBe(Ord(wldInOut));
end;

procedure TConnectorHostTests.TestArrayRulesFailClosed;
begin
  { D11: a direction or [Scoped] is required, and exactly one length. }
  ExpectUnsupported(LowerError(
    '[MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] byte[] b'),
    'needs [In], [Out], or [Scoped]');
  ExpectUnsupported(LowerError('[In] byte[] b'),
    'exactly one of SizeConst or SizeParamIndex');
  ExpectUnsupported(LowerError(
    '[In, MarshalAs(UnmanagedType.LPArray, SizeConst = 4, SizeParamIndex = 1)]' +
    ' byte[] b, int n', 'i32 i32'), 'exactly one of');
  ExpectUnsupported(LowerError(
    '[In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] byte[] b'),
    'names no count parameter');
  ExpectUnsupported(LowerError(
    '[In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 5)] byte[] b'),
    'names no count parameter');
  ExpectUnsupported(LowerError(
    '[In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] byte[] b,' +
    ' float n', 'i32 f32'), 'not an integer');
  ExpectUnsupported(LowerError(
    '[In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] byte[] b,' +
    ' bool n', 'i32 i32'), 'not an integer');
  ExpectUnsupported(LowerError('[In, MarshalAs(UnmanagedType.LPArray,' +
    ' SizeConst = 2)] string[] b'), 'string[]');
  ExpectUnsupported(LowerError('[In, MarshalAs(UnmanagedType.ByValArray,' +
    ' SizeConst = 2)] int[] b'), 'int[]');
end;

procedure TConnectorHostTests.TestHandleAndCallbackLowering;
var
  Plan: TWlcConnectorPlan;
  Call: TWasmConnectorCall;
begin
  Plan := PlanFor(
    'static class C {' + sLineBreak +
    '  [Scoped] public delegate int Map(int x);' + sLineBreak +
    '  [Queued] public delegate void Note(uint x);' + sLineBreak +
    '  public delegate void Tick();' + sLineBreak +
    '  [DllImport("libc")] static extern IntPtr f(nint a, UIntPtr b,' +
    ' [MarshalAs(UnmanagedType.SysInt)] int c, Map m, Note n, Tick t);' +
    sLineBreak + '}',
    '(module (import "C" "f" (func (param i32 i32 i32 i32 i32 i32) (result i32))))');
  Call := LowerConnectorThunk(Plan, 0);
  Expect<Integer>(Ord(Call.ResultKind)).ToBe(Ord(wcrHandle));
  Expect<Integer>(Ord(Call.Params[0].Kind)).ToBe(Ord(wcpHandle));
  Expect<Integer>(Ord(Call.Params[1].Kind)).ToBe(Ord(wcpHandle));
  Expect<Integer>(Ord(Call.Params[2].Kind)).ToBe(Ord(wcpHandle));
  Expect<Integer>(Ord(Call.Params[3].Kind)).ToBe(Ord(wcpCallback));
  Expect<Integer>(Ord(Call.Params[3].Lifetime)).ToBe(Ord(wckScoped));
  Expect<Integer>(Ord(Call.Params[4].Lifetime)).ToBe(Ord(wckQueued));
  Expect<Integer>(Ord(Call.Params[5].Lifetime)).ToBe(Ord(wckRetained));
  Expect<Boolean>(Call.NeedsMemory).ToBe(False);
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
  { A literal absolute path (forward slashes, so it is also a valid `.wlc`
    string on a Windows host) that does not exist. }
  Msg := LinkErrorOf(LiveWlc('/wasmlight-absent-dir/libabsent.so'),
    ANSWER_WAT);
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

{ --- buffers, handles, and callbacks ---------------------------------------- }

function TConnectorHostTests.ShapesWlc(const ALibrary: string): string;

  function Ext(const AEntry, ADecl: string): string;
  begin
    Result := '  [DllImport("' + ALibrary + '", EntryPoint = "' + AEntry +
      '")] static extern ' + ADecl + ';' + sLineBreak;
  end;

begin
  Result :=
    'static class Conn {' + sLineBreak +
    '  public delegate int Map(int x);' + sLineBreak +
    '  [Scoped] public delegate int ScopedMap(int x);' + sLineBreak +
    '  public delegate void Tick();' + sLineBreak +
    '  public delegate int Get();' + sLineBreak +
    '  public delegate void Notify(int v);' + sLineBreak +
    '  [Queued] public delegate void Posted(int v);' + sLineBreak +
    Ext('conn_sum_bytes', 'int SumBytes([In, MarshalAs(UnmanagedType.LPArray,' +
      ' SizeParamIndex = 1)] byte[] buf, int n)') +
    Ext('conn_fill', 'void Fill([Out, MarshalAs(UnmanagedType.LPArray,' +
      ' SizeParamIndex = 1)] byte[] buf, int n, byte v)') +
    Ext('conn_reverse4', 'void Reverse4([In, Out, MarshalAs(' +
      'UnmanagedType.LPArray, SizeConst = 4)] int[] vals)') +
    Ext('conn_scale_in_place', 'int ScaleInPlace([Scoped, MarshalAs(' +
      'UnmanagedType.LPArray, SizeParamIndex = 1)] short[] vals, uint n,' +
      ' short k)') +
    Ext('conn_counter_new', 'IntPtr CounterNew(int start)') +
    Ext('conn_counter_add', 'int CounterAdd(IntPtr c, int by)') +
    Ext('conn_apply', 'int Apply(Map f, int x)') +
    Ext('conn_apply_twice', 'int ApplyTwice(ScopedMap f, int x)') +
    Ext('conn_call_void', 'int CallVoid(Tick f)') +
    Ext('conn_call_get', 'int CallGet(Get f)') +
    Ext('conn_register', 'void Register(Notify f)') +
    Ext('conn_fire', 'void Fire(int v)') +
    Ext('conn_post', 'void Post(Posted f, int v)') +
    Ext('conn_borrow_and_call', 'int BorrowAndCall([Scoped, MarshalAs(' +
      'UnmanagedType.LPArray, SizeParamIndex = 1)] byte[] buf, int n, Map f)') +
    '}' + sLineBreak;
end;

procedure TConnectorHostTests.WriteGuest(const AOffset: UInt32;
  const ABytes: array of Byte);
var
  Mem: TWasmMemoryRef;
begin
  Expect<Boolean>(FInstance.FindExportMemory('memory', Mem)).ToBe(True);
  Expect<Boolean>(MemWrite(Mem, AOffset, Length(ABytes), @ABytes[0]))
    .ToBe(True);
end;

function TConnectorHostTests.ReadGuest(const AOffset, ALength: UInt32): TBytes;
var
  Mem: TWasmMemoryRef;
begin
  Result := nil;
  SetLength(Result, ALength);
  Expect<Boolean>(FInstance.FindExportMemory('memory', Mem)).ToBe(True);
  Expect<Boolean>(MemRead(Mem, AOffset, ALength, @Result[0])).ToBe(True);
end;

function TConnectorHostTests.CallError(const AName: string;
  const AArgs: array of TWasmValue; out AClass: string): string;
var
  Fn: TWasmFunc;
  Results: array of TWasmValue;
begin
  Result := '';
  AClass := '';
  Expect<Boolean>(FInstance.FindExportFunc(AName, Fn)).ToBe(True);
  SetLength(Results, Length(Fn.ResultTypes));
  try
    Call(Fn, AArgs, Results);
  except
    on E: EWasmError do
    begin
      AClass := E.ClassName;
      Result := E.Message;
    end;
  end;
end;

procedure TConnectorHostTests.CallVoid(const AName: string;
  const AArgs: array of TWasmValue);
var
  Fn: TWasmFunc;
  NoResults: array of TWasmValue;
begin
  Expect<Boolean>(FInstance.FindExportFunc(AName, Fn)).ToBe(True);
  NoResults := nil;
  Call(Fn, AArgs, NoResults);
end;

procedure TConnectorHostTests.TestBuffersCopyThroughTheChokepoint;
var
  Got: TBytes;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  { Copy-in with a SizeParamIndex count. }
  WriteGuest(100, [1, 2, 3, 4, 250]);
  Expect<Int32>(CallI32('sum', [MakeValueI32(100), MakeValueI32(4)])).ToBe(10);
  Expect<Int32>(CallI32('sum', [MakeValueI32(100), MakeValueI32(0)])).ToBe(0);
  { Copy-out writes exactly the counted bytes. }
  WriteGuest(200, [0, 0, 0, 99]);
  CallVoid('fill', [MakeValueI32(200), MakeValueI32(3), MakeValueI32(7)]);
  Got := ReadGuest(200, 4);
  Expect<Integer>(Got[0]).ToBe(7);
  Expect<Integer>(Got[2]).ToBe(9);
  Expect<Integer>(Got[3]).ToBe(99);
  { Inout with SizeConst = 4 int elements. }
  WriteGuest(300, [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0]);
  CallVoid('rev', [MakeValueI32(300)]);
  Got := ReadGuest(300, 16);
  Expect<Integer>(Got[0]).ToBe(4);
  Expect<Integer>(Got[12]).ToBe(1);
end;

procedure TConnectorHostTests.TestBufferRangesTrap;
var
  Cls, Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  Msg := CallError('sum', [MakeValueI32(65534), MakeValueI32(4)], Cls);
  Expect<string>(Cls).ToBe('EWasmTrap');
  Expect<string>(Msg).ToBe(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
  { A negative signed count names no range. }
  Msg := CallError('sum', [MakeValueI32(0), MakeValueI32(-1)], Cls);
  Expect<string>(Cls).ToBe('EWasmTrap');
  { An out-only range is checked before the native call runs. }
  Msg := CallError('rev', [MakeValueI32(65530)], Cls);
  Expect<string>(Cls).ToBe('EWasmTrap');
  Msg := CallError('scale', [MakeValueI32(65535), MakeValueI32(1),
    MakeValueI32(2)], Cls);
  Expect<string>(Cls).ToBe('EWasmTrap');
end;

procedure TConnectorHostTests.TestScopedBorrowWritesInPlace;
var
  Got: TBytes;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  { int16 1, -2, 3 scaled by 10 in guest memory. }
  WriteGuest(400, [1, 0, $FE, $FF, 3, 0]);
  Expect<Int32>(CallI32('scale', [MakeValueI32(400), MakeValueI32(3),
    MakeValueI32(10)])).ToBe(20);
  Got := ReadGuest(400, 6);
  Expect<Integer>(Got[0]).ToBe(10);
  Expect<Integer>(Got[2]).ToBe($EC);
  Expect<Integer>(Got[3]).ToBe($FF);
  Expect<Integer>(Got[4]).ToBe(30);
end;

procedure TConnectorHostTests.TestHandlesAreOpaque;
var
  H1, H2: Int32;
  Cls, Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  H1 := CallI32('cnew', [MakeValueI32(5)]);
  H2 := CallI32('cnew', [MakeValueI32(100)]);
  { Small table indexes, never the native address. }
  Expect<Int32>(H1).ToBe(1);
  Expect<Int32>(H2).ToBe(2);
  Expect<Int32>(CallI32('cadd', [MakeValueI32(H1), MakeValueI32(3)])).ToBe(8);
  Expect<Int32>(CallI32('cadd', [MakeValueI32(H2), MakeValueI32(1)])).ToBe(101);
  { NULL is handle 0 both ways. }
  Expect<Int32>(CallI32('cnew', [MakeValueI32(-1)])).ToBe(0);
  Expect<Int32>(CallI32('cadd', [MakeValueI32(0), MakeValueI32(1)])).ToBe(-1);
  Msg := CallError('cadd', [MakeValueI32(99), MakeValueI32(1)], Cls);
  Expect<string>(Cls).ToBe('EWasmConnectorError');
  Expect<string>(Msg).ToBe(MSG_CONNECTOR_STALE_HANDLE);
end;

procedure TConnectorHostTests.TestCallbacksReenterTheGuest;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  Expect<Int32>(CallI32('apply', [MakeValueI32(1), MakeValueI32(6)])).ToBe(13);
  { A scoped delegate is valid for the call that received it. }
  Expect<Int32>(CallI32('twice', [MakeValueI32(1), MakeValueI32(3)])).ToBe(12);
  Expect<Int32>(CallI32('cvoid', [MakeValueI32(2)])).ToBe(7);
  Expect<Int32>(CallI32('seen', [])).ToBe(1);
  Expect<Int32>(CallI32('cget', [MakeValueI32(3)])).ToBe(42);
  { A retained delegate outlives the call that registered it. }
  CallVoid('reg', [MakeValueI32(4)]);
  CallVoid('fire', [MakeValueI32(55)]);
  Expect<Int32>(CallI32('seen', [])).ToBe(55);
end;

procedure TConnectorHostTests.TestQueuedNotificationDrainsAfterTheCall;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  { The library notifies from its own thread; the guest runs on the store
    thread once the connector call returns. }
  CallVoid('post', [MakeValueI32(4), MakeValueI32(77)]);
  Expect<Int32>(CallI32('seen', [])).ToBe(77);
end;

procedure TConnectorHostTests.TestCallbackTableEntriesTrap;
var
  Cls, Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  Msg := CallError('apply', [MakeValueI32(0), MakeValueI32(1)], Cls);
  Expect<string>(Cls).ToBe('EWasmTrap');
  Expect<string>(Msg).ToBe(MSG_TRAP_UNINITIALIZED_ELEMENT + ' 0');
  Msg := CallError('apply', [MakeValueI32(8), MakeValueI32(1)], Cls);
  Expect<string>(Msg).ToBe(MSG_TRAP_UNDEFINED_ELEMENT);
  Msg := CallError('apply', [MakeValueI32(6), MakeValueI32(1)], Cls);
  Expect<string>(Msg).ToBe(MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH);
  Msg := CallError('apply', [MakeValueI32(2), MakeValueI32(1)], Cls);
  Expect<string>(Msg).ToBe(MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH);
end;

procedure TConnectorHostTests.TestCallbackFailureIsDeferred;
var
  Cls, Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  { $boom traps inside the native call; the trap surfaces unchanged once
    conn_apply has returned. }
  Msg := CallError('apply', [MakeValueI32(5), MakeValueI32(1)], Cls);
  Expect<string>(Cls).ToBe('EWasmTrap');
  Expect<string>(Msg).ToBe(MSG_TRAP_UNREACHABLE);
  Expect<Int32>(CallI32('apply', [MakeValueI32(1), MakeValueI32(2)])).ToBe(5);
end;

procedure TConnectorHostTests.TestBorrowCannotJoinACallback;
var
  Cls, Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Instantiate(ShapesWlc(FLibPath), SHAPES_WAT);
  Msg := CallError('bac', [MakeValueI32(100), MakeValueI32(1),
    MakeValueI32(1)], Cls);
  Expect<string>(Cls).ToBe('EWasmConnectorError');
  Expect<string>(Msg).ToBe(MSG_CONNECTOR_BORROW_CALLBACK);
  { The borrow ended with the call. }
  Expect<Int32>(CallI32('apply', [MakeValueI32(1), MakeValueI32(2)])).ToBe(5);
end;

procedure TConnectorHostTests.TestNinthCallbackIsRejected;
var
  Wat: string;
  I: Integer;
  Cls, Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Wat := '(module (import "Conn" "Register" (func $reg (param i32)))' +
    ' (table 9 funcref) (elem (i32.const 0) func';
  for I := 0 to 8 do
    Wat := Wat + ' $n' + IntToStr(I);
  Wat := Wat + ')';
  for I := 0 to 8 do
    Wat := Wat + ' (func $n' + IntToStr(I) + ' (param i32))';
  Wat := Wat + ' (func (export "reg") (param i32) (call $reg (local.get 0))))';
  Instantiate(ShapesWlc(FLibPath), Wat);
  for I := 0 to WASM_CALLBACK_SLOT_COUNT - 1 do
    CallVoid('reg', [MakeValueI32(I)]);
  { Re-registering a bound function reuses its thunk. }
  CallVoid('reg', [MakeValueI32(0)]);
  Msg := CallError('reg', [MakeValueI32(8)], Cls);
  Expect<string>(Cls).ToBe('EWasmCallbackError');
  Expect<string>(Msg).ToBe(MSG_CALLBACK_SLOTS);
end;

procedure TConnectorHostTests.TestMissingMemoryIsALinkError;
var
  Msg: string;
begin
  if not BuildFixture then
  begin
    Expect<Boolean>(NativeCallSupported).ToBe(False);
    Exit;
  end;
  Msg := LinkErrorOf(ShapesWlc(FLibPath),
    '(module (import "Conn" "SumBytes" (func (param i32 i32) (result i32))))');
  Expect<Boolean>(Pos('exported "memory"', Msg) > 0).ToBe(True);
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

procedure TConnectorHostTests.TestCompiledExecutableRunsEveryShape;
var
  Payload: TWasmBytes;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
begin
  if not CanRunNative then
    Exit;
  { Copy-in, handles, retained / scoped / void callbacks re-entering
    through the native invoke, and a queued notification drained after
    its call. }
  Res := CompileCommand(NATIVE_SHAPES_WAT, ShapesWlc(FLibPath), Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Run := RunPayload(Payload);
  Expect<string>(Run.Diagnostic).ToBe('');
  Expect<Integer>(Run.ExitCode).ToBe(110);
end;

procedure TConnectorHostTests.TestCompiledMissingSymbolFailsAtStartup;
var
  Payload: TWasmBytes;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
begin
  if not CanRunNative then
    Exit;
  Res := CompileCommand(COMMAND_WAT, StringReplace(CommandWlc(FLibPath),
    'EntryPoint = "conn_add"', 'EntryPoint = "conn_absent"', []), Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Run := RunPayload(Payload);
  Expect<Integer>(Run.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError: ' + MSG_LINK_UNKNOWN_SYMBOL,
    Run.Diagnostic) = 1).ToBe(True);
end;

procedure TConnectorHostTests.TestCompiledCallbackTrapUnwinds;
var
  Payload: TWasmBytes;
  Res: TWasmCompileResult;
  Run: TWasmShellResult;
begin
  if not CanRunNative then
    Exit;
  { The trap never unwinds through conn_apply's C frame: it is retained at
    the thunk and rethrown when the connector call returns. }
  Res := CompileCommand(NATIVE_CALLBACK_TRAP_WAT, ShapesWlc(FLibPath),
    Payload);
  Expect<string>(Res.Diagnostic).ToBe('');
  Run := RunPayload(Payload);
  Expect<Integer>(Run.ExitCode).ToBe(WASM_SHELL_EXIT_TRAP);
  Expect<string>(Run.Diagnostic).ToBe('trap: ' + MSG_TRAP_UNREACHABLE);
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
  Request: TWasmCompileRequest;
  Res: TWasmCompileResult;
begin
  { A released target, so a Windows or 32-bit host still reaches link. }
  WriteText(IncludeTrailingPathDelimiter(FWork) + 'conn.wlc',
    'static class C { [DllImport("libc")] static extern void f(string s); }');
  Request.ModulePath := '';
  Request.OutputPath := IncludeTrailingPathDelimiter(FWork) + 'app';
  Request.Target := WASM_COMPILE_TARGET_X64_LINUX;
  Request.CatalogRoot := IncludeTrailingPathDelimiter(FWork) + 'no-catalog';
  Request.Connectors := nil;
  SetLength(Request.Connectors, 1);
  Request.Connectors[0] := IncludeTrailingPathDelimiter(FWork) + 'conn.wlc';
  Res := CompileModuleBytes(AssembleWatText(
    '(module (import "C" "f" (func (param i32)))' +
    '  (memory (export "memory") 1) (func (export "_start")))'), Request);
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
  Test('arrays lower to buffers and borrows with their counts',
    TestArrayLowering);
  Test('array direction and length rules fail closed',
    TestArrayRulesFailClosed);
  Test('handles and delegates lower with their lifetimes',
    TestHandleAndCallbackLowering);
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
  Test('buffers copy in, out, and both ways', TestBuffersCopyThroughTheChokepoint);
  Test('out-of-range buffers trap before the call', TestBufferRangesTrap);
  Test('a scoped borrow writes guest memory in place',
    TestScopedBorrowWritesInPlace);
  Test('handles are opaque and NULL is zero', TestHandlesAreOpaque);
  Test('retained, scoped, and void callbacks re-enter the guest',
    TestCallbacksReenterTheGuest);
  Test('a queued notification drains after the call',
    TestQueuedNotificationDrainsAfterTheCall);
  Test('null, out-of-range, and mistyped table entries trap',
    TestCallbackTableEntriesTrap);
  Test('a callback trap is deferred to Pascal ground',
    TestCallbackFailureIsDeferred);
  Test('a live borrow cannot join a callback', TestBorrowCannotJoinACallback);
  Test('a ninth distinct callback is rejected', TestNinthCallbackIsRejected);
  Test('buffers without an exported memory are a link error',
    TestMissingMemoryIsALinkError);
  Test('a compiled executable calls the connector library',
    TestCompiledExecutableCallsTheLibrary);
  Test('a compiled executable runs every connector shape',
    TestCompiledExecutableRunsEveryShape);
  Test('a compiled callback trap unwinds on Pascal ground',
    TestCompiledCallbackTrapUnwinds);
  Test('a missing symbol fails the executable at startup',
    TestCompiledMissingSymbolFailsAtStartup);
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
