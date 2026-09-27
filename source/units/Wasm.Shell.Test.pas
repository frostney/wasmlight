{ Unit suite for Wasm.Shell — startup validate-then-run, no interpreter
  fallback.

  Positive native execution is gated to a 64-bit UNIX host with a backend.
  On every other host a complete-looking image still fails closed with
  EWasmLinkError (nlrNoBackend), which is the product rule: the shell never
  interprets. }
program Wasm.Shell.Test;

{$I Shared.inc}

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
  Wasm.Compile.Capabilities,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Jit.CodeBuffer,
  Wasm.Native,
  Wasm.Package.Elf,
  Wasm.Run,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Shell,
  Wasm.Shell.Payload,
  Wasm.Wasi,
  Wasm.Wat.Assembler;

const
  HELLO_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_write"' + sLineBreak +
    '    (func $fd_write (param i32 i32 i32 i32) (result i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (data (i32.const 100) "hello\0a")' + sLineBreak +
    '  (func (export "_start")' + sLineBreak +
    '    (i32.store (i32.const 0) (i32.const 100))' + sLineBreak +
    '    (i32.store (i32.const 4) (i32.const 6))' + sLineBreak +
    '    (drop (call $fd_write' + sLineBreak +
    '      (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))))';

  TRAP_WAT =
    '(module (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (unreachable)))';

  ADD_EXIT_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit"' + sLineBreak +
    '    (func $proc_exit (param i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start")' + sLineBreak +
    '    (call $proc_exit (i32.add (i32.const 17) (i32.const 25)))))';

  EXIT_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit"' + sLineBreak +
    '    (func $proc_exit (param i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (call $proc_exit (i32.const 42))))';

  CALL_EXIT_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit"' + sLineBreak +
    '    (func $proc_exit (param i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func $inc (param i32) (result i32)' + sLineBreak +
    '    (i32.add (local.get 0) (i32.const 1)))' + sLineBreak +
    '  (func (export "_start")' + sLineBreak +
    '    (call $proc_exit (call $inc (i32.const 41)))))';

  NO_START_WAT =
    '(module (memory (export "memory") 1))';

  REACTOR_WAT =
    '(module (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_initialize")))';

  BAD_IMPORT_WAT =
    '(module' + sLineBreak +
    '  (import "env" "foo" (func $foo))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (call $foo)))';

  INVALID_WAT =
    '(module (func (result i32) (i32.const 1) (i32.const 2)))';

  { tests/fixtures/wasi/caps.wat: exits with argc + 10 * envc, plus 100
    when fd 3 opens probe.txt. }
  CAPS_COMMAND_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "args_sizes_get"' + sLineBreak +
    '    (func $args_sizes_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "environ_sizes_get"' + sLineBreak +
    '    (func $environ_sizes_get (param i32 i32) (result i32)))' +
    sLineBreak +
    '  (import "wasi_snapshot_preview1" "path_open"' + sLineBreak +
    '    (func $path_open' + sLineBreak +
    '      (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))' +
    sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit"' + sLineBreak +
    '    (func $proc_exit (param i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (data (i32.const 64) "probe.txt")' + sLineBreak +
    '  (func (export "_start")' + sLineBreak +
    '    (local $code i32)' + sLineBreak +
    '    (drop (call $args_sizes_get (i32.const 0) (i32.const 4)))' +
    sLineBreak +
    '    (drop (call $environ_sizes_get (i32.const 8) (i32.const 12)))' +
    sLineBreak +
    '    (local.set $code' + sLineBreak +
    '      (i32.add' + sLineBreak +
    '        (i32.load (i32.const 0))' + sLineBreak +
    '        (i32.mul (i32.load (i32.const 8)) (i32.const 10))))' +
    sLineBreak +
    '    (if (i32.eqz (call $path_open' + sLineBreak +
    '          (i32.const 3) (i32.const 0) (i32.const 64) (i32.const 9)' +
    sLineBreak +
    '          (i32.const 0) (i64.const 2) (i64.const 0) (i32.const 0)' +
    sLineBreak +
    '          (i32.const 16)))' + sLineBreak +
    '      (then (local.set $code (i32.add (local.get $code)' +
    ' (i32.const 100)))))' + sLineBreak +
    '    (call $proc_exit (local.get $code))))';

type
  TShellTests = class(TTestSuite)
  private
    FConfig: TWasmWasiConfig;
    function CapturedStdout: string;
    function BuildNative(const ABytes: TWasmBytes): TWasmBytes;
    function PayloadForWat(const AWat: string): TWasmBytes;
    function WriteTempPayload(const ABytes: TWasmBytes): string;
    function CapsPayload(const ADirs, AEnvs: array of string): TWasmBytes;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestEmptyPayload;
    procedure TestMalformedPayload;
    procedure TestCorruptEmbeddedTrailer;
    procedure TestGarbageModuleIsDecodeError;
    procedure TestInvalidModuleIsValidationError;
    procedure TestIncompleteNativeRejected;
    procedure TestStaleNativeRejected;
    procedure TestConnectorStubRejected;
    procedure TestMalformedCapabilitySetRejected;
    procedure TestCapabilitySetCannotBeExpanded;
    procedure TestCompiledCapabilitiesReachGuest;
    procedure TestArgcMatchesRun;
    procedure TestCapsFixtureMatchesSource;
    procedure TestExecutablePathIsAbsolute;
    procedure TestNoStart;
    procedure TestStartParameter;
    procedure TestStartResult;
    procedure TestReactor;
    procedure TestBadImport;
    procedure TestHelloNativeOrClosed;
    procedure TestTrapNativeOrClosed;
    procedure TestAddExitNativeOrClosed;
    procedure TestProcExitNativeOrClosed;
    procedure TestCallNativeOrClosed;
    procedure TestNativeLeafEntriesWired;
    procedure TestMissingPayloadFile;
    procedure TestIncompletePayloadFile;
    procedure TestHelloViaPayloadFile;
  end;

procedure TShellTests.BeforeEach;
begin
  FConfig := nil;
end;

procedure TShellTests.AfterEach;
begin
  FreeAndNil(FConfig);
end;

function TShellTests.CapturedStdout: string;
var
  Bytes: TBytes;
  Index: Integer;
begin
  Result := '';
  if FConfig = nil then
    Exit;
  Bytes := TWasmWasiBufferStream(FConfig.Stdout).WrittenBytes;
  SetLength(Result, Length(Bytes));
  for Index := 0 to High(Bytes) do
    Result[Index + 1] := Chr(Bytes[Index]);
end;

function TShellTests.BuildNative(const ABytes: TWasmBytes): TWasmBytes;
var
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
begin
  Loaded := nil;
  Engine := nil;
  Store := nil;
  try
    Loaded := LoadModule(ABytes);
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Result := AotCompileModule(Store, Loaded);
  finally
    FreeAndNil(Store);
    Engine.Free;
    Loaded.Free;
  end;
end;

function TShellTests.PayloadForWat(const AWat: string): TWasmBytes;
var
  Module: TWasmBytes;
begin
  Module := AssembleWatText(AWat);
  Result := WriteShellPayload(Module, BuildNative(Module), nil, nil);
end;

function TShellTests.WriteTempPayload(const ABytes: TWasmBytes): string;
var
  Stream: TFileStream;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight-shell-' + IntToStr(GetTickCount64) + '.wshl';
  Stream := TFileStream.Create(Result, fmCreate);
  try
    if Length(ABytes) > 0 then
      Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
end;

procedure TShellTests.TestEmptyPayload;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(nil, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('no embedded module', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestMalformedPayload;
var
  Bytes: TWasmBytes;
  Res: TWasmShellResult;
begin
  SetLength(Bytes, 4);
  Bytes[0] := Ord('n');
  Bytes[1] := Ord('o');
  Bytes[2] := Ord('p');
  Bytes[3] := Ord('e');
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Bytes, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('malformed', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestGarbageModuleIsDecodeError;
var
  Garbage, Payload: TWasmBytes;
  Res: TWasmShellResult;
begin
  SetLength(Garbage, 8);
  Garbage[0] := Ord('n');
  Garbage[1] := Ord('o');
  Garbage[2] := Ord('t');
  Garbage[3] := Ord('w');
  Garbage[4] := Ord('a');
  Garbage[5] := Ord('s');
  Garbage[6] := Ord('m');
  Garbage[7] := Ord('!');
  Payload := WriteShellPayload(Garbage, nil, nil, nil);
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Payload, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmDecodeError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestInvalidModuleIsValidationError;
var
  Module, Payload: TWasmBytes;
  Res: TWasmShellResult;
begin
  Module := AssembleWatText(INVALID_WAT);
  Payload := WriteShellPayload(Module, nil, nil, nil);
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Payload, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmValidationError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestIncompleteNativeRejected;
var
  Module, Payload: TWasmBytes;
  Res: TWasmShellResult;
begin
  Module := AssembleWatText(HELLO_WAT);
  Payload := WriteShellPayload(Module, nil, nil, nil);
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Payload, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(CapturedStdout = '').ToBe(True);
end;

procedure TShellTests.TestStaleNativeRejected;
var
  Hello, ExitMod, Payload: TWasmBytes;
  Res: TWasmShellResult;
begin
  Hello := AssembleWatText(HELLO_WAT);
  ExitMod := AssembleWatText(EXIT_WAT);
  Payload := WriteShellPayload(Hello, BuildNative(ExitMod), nil, nil);
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Payload, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(CapturedStdout = '').ToBe(True);
end;

procedure TShellTests.TestConnectorStubRejected;
var
  Module, Plan, Payload: TWasmBytes;
  Res: TWasmShellResult;
begin
  Module := AssembleWatText(HELLO_WAT);
  SetLength(Plan, 1);
  Plan[0] := 1;
  Payload := WriteShellPayload(Module, BuildNative(Module), Plan, nil);
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Payload, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('connector plan', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestMalformedCapabilitySetRejected;
var
  Module, Caps, Payload: TWasmBytes;
  Res: TWasmShellResult;
begin
  Module := AssembleWatText(HELLO_WAT);
  { One byte: shorter than the 12-byte capability-set header. }
  SetLength(Caps, 1);
  Caps[0] := 1;
  Payload := WriteShellPayload(Module, BuildNative(Module), nil, Caps);
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Payload, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<string>(Res.Diagnostic)
    .ToBe('malformed capability set: truncated capability set header');
  Expect<Boolean>(CapturedStdout = '').ToBe(True);
end;

function TShellTests.CapsPayload(const ADirs, AEnvs: array of string):
  TWasmBytes;
var
  Module: TWasmBytes;
  Caps: TWasmCompiledCapabilities;
  Err: string;
  I: Integer;
begin
  Module := AssembleWatText(CAPS_COMMAND_WAT);
  Caps := TWasmCompiledCapabilities.Create;
  try
    for I := 0 to High(ADirs) do
      if not Caps.TryAddDirSpec(ADirs[I], Err) then
        raise EWasmError.Create(Err);
    for I := 0 to High(AEnvs) do
      if not Caps.TryAddEnvSpec(AEnvs[I], Err) then
        raise EWasmError.Create(Err);
    Result := WriteShellPayload(Module, BuildNative(Module), nil,
      EncodeCompiledCapabilities(Caps));
  finally
    Caps.Free;
  end;
end;

procedure TShellTests.TestCapabilitySetCannotBeExpanded;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  FConfig.AddEnv('AMBIENT=1');
  Res := RunShellBytes(CapsPayload([], ['A=1']), FConfig,
    ShellInvocation('/opt/app/tool', []));
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<string>(Res.Diagnostic)
    .ToBe('EWasmLinkError: cannot expand a compiled capability set');
  Expect<Integer>(Length(FConfig.Env)).ToBe(1);

  FreeAndNil(FConfig);
  FConfig := TWasmWasiConfig.Create;
  FConfig.AddPreopenDir('/ambient', GetTempDir, WASM_COMPILED_DIR_RIGHTS);
  Res := RunShellBytes(CapsPayload([], ['A=1']), FConfig,
    ShellInvocation('/opt/app/tool', []));
  Expect<string>(Res.Diagnostic)
    .ToBe('EWasmLinkError: cannot expand a compiled capability set');
  Expect<Integer>(Length(FConfig.Env)).ToBe(0);
end;

procedure TShellTests.TestCompiledCapabilitiesReachGuest;
var
  Root, AppDir: string;
  Res: TWasmShellResult;
  Probe: TFileStream;
begin
  { <root>/app/tool is the executable; <root>/app/data/probe.txt is only
    reachable if `/d=data` resolves from the executable directory. }
  Root := IncludeTrailingPathDelimiter(GetTempDir) + 'wasmlight-shell-caps-' +
    IntToStr(GetTickCount64);
  AppDir := IncludeTrailingPathDelimiter(Root) + 'app';
  ForceDirectories(IncludeTrailingPathDelimiter(AppDir) + 'data');
  Probe := TFileStream.Create(IncludeTrailingPathDelimiter(AppDir) +
    'data' + PathDelim + 'probe.txt', fmCreate);
  Probe.Free;
  try
    FConfig := TWasmWasiConfig.Create;
    Res := RunShellBytes(CapsPayload(['/d=data'], ['A=1', 'B=2']), FConfig,
      ShellInvocation(IncludeTrailingPathDelimiter(AppDir) + 'tool',
      ['a', '--dir=/etc']));
    Expect<Integer>(Length(FConfig.Argv)).ToBe(3);
    Expect<string>(FConfig.Argv[0]).ToBe('tool');
    Expect<Integer>(Length(FConfig.Env)).ToBe(2);
    Expect<Integer>(Length(FConfig.Preopens)).ToBe(1);
    {$IFDEF WASM_JIT_BACKEND}
    if JitExecMemSupported then
    begin
      { argc 3 + 10 * envc 2 + 100 for the opened probe. }
      Expect<Integer>(Res.ExitCode).ToBe(123);
      Exit;
    end;
    {$ENDIF}
    Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
    Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  finally
    DeleteFile(IncludeTrailingPathDelimiter(AppDir) + 'data' + PathDelim +
      'probe.txt');
    RemoveDir(IncludeTrailingPathDelimiter(AppDir) + 'data');
    RemoveDir(AppDir);
    RemoveDir(Root);
  end;
end;

procedure TShellTests.TestArgcMatchesRun;
const
  ARGS: array[0..2] of string = ('a', '--b', '--env=K=V');
var
  RunConfig: TWasmWasiConfig;
  RunRes: TWasmRunResult;
  Res: TWasmShellResult;
begin
  { `wasmlight run caps.wasm a --b --env=K=V` sets argv through the same
    CompiledGuestArgv; the interpreter gives the reference argc. }
  RunConfig := TWasmWasiConfig.Create;
  try
    RunConfig.SetArgv(CompiledGuestArgv('caps.wasm', ARGS));
    RunRes := RunModuleBytes(AssembleWatText(CAPS_COMMAND_WAT), RunConfig);
    Expect<Integer>(RunRes.ExitCode).ToBe(4);
  finally
    RunConfig.Free;
  end;

  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(CapsPayload([], []), FConfig,
    ShellInvocation('/opt/app/caps', ARGS));
  Expect<Integer>(Length(FConfig.Argv)).ToBe(4);
  Expect<Integer>(Length(FConfig.Env)).ToBe(0);
  {$IFDEF WASM_JIT_BACKEND}
  if JitExecMemSupported then
  begin
    Expect<Integer>(Res.ExitCode).ToBe(RunRes.ExitCode);
    Exit;
  end;
  {$ENDIF}
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestNoStart;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(NO_START_WAT), FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('_start', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestReactor;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(REACTOR_WAT), FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('reactor', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestBadImport;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(BAD_IMPORT_WAT), FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestHelloNativeOrClosed;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(HELLO_WAT), FConfig);
  {$IFDEF WASM_JIT_BACKEND}
  if JitExecMemSupported then
  begin
    Expect<Integer>(Res.ExitCode).ToBe(0);
    Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
    Expect<Boolean>(Res.NativeStatus = 'loaded').ToBe(True);
    Exit;
  end;
  {$ENDIF}
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(CapturedStdout = '').ToBe(True);
end;

procedure TShellTests.TestTrapNativeOrClosed;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(TRAP_WAT), FConfig);
  {$IFDEF WASM_JIT_BACKEND}
  if JitExecMemSupported then
  begin
    Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_TRAP);
    Expect<Boolean>(Pos('trap', Res.Diagnostic) > 0).ToBe(True);
    Exit;
  end;
  {$ENDIF}
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestAddExitNativeOrClosed;
var
  Res: TWasmShellResult;
begin
  { Pinned numeric probe: 17+25 through native _start, then proc_exit. }
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(ADD_EXIT_WAT), FConfig);
  {$IFDEF WASM_JIT_BACKEND}
  if JitExecMemSupported then
  begin
    Expect<Integer>(Res.ExitCode).ToBe(42);
    Exit;
  end;
  {$ENDIF}
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestProcExitNativeOrClosed;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(EXIT_WAT), FConfig);
  {$IFDEF WASM_JIT_BACKEND}
  if JitExecMemSupported then
  begin
    Expect<Integer>(Res.ExitCode).ToBe(42);
    Exit;
  end;
  {$ENDIF}
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestCallNativeOrClosed;
var
  Res: TWasmShellResult;
begin
  { wasm-to-wasm call through native entries: $inc then proc_exit. }
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat(CALL_EXIT_WAT), FConfig);
  {$IFDEF WASM_JIT_BACKEND}
  if JitExecMemSupported then
  begin
    Expect<Integer>(Res.ExitCode).ToBe(42);
    Exit;
  end;
  {$ENDIF}
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestNativeLeafEntriesWired;
const
  { $mrw is an x64 memory leaf (three parameters, the caller instance's
    memory); run(10) adds 1 at [64] ten times, returning 1..10, so it
    yields 10 + (1 or 2 or ... or 10) = 25. }
  LEAF_WAT =
    '(module (memory 1)' + sLineBreak +
    '  (func $mrw (export "mrw") (param $id i32) (param $d i64)' +
    ' (param $p i32) (result i32)' + sLineBreak +
    '    (i64.store (local.get $p) (i64.add (i64.load (local.get $p))' +
    ' (i64.add (local.get $d) (i64.extend_i32_u (local.get $id)))))' +
    sLineBreak +
    '    (i32.wrap_i64 (i64.load (local.get $p))))' + sLineBreak +
    '  (func (export "run") (param $n i32) (result i32)' +
    ' (local $i i32) (local $s i32)' + sLineBreak +
    '    (loop $l' + sLineBreak +
    '      (local.set $s (i32.or (local.get $s)' +
    ' (call $mrw (i32.const 1) (i64.const 0) (i32.const 64))))' +
    sLineBreak +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' +
    sLineBreak +
    '      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))' +
    sLineBreak +
    '    (i32.add (i32.load (i32.const 64)) (local.get $s))))';
var
  Bytes, Waot: TWasmBytes;
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Imports: TWasmImports;
  Inst: TWasmModuleInstance;
  Native: TWasmNativeContext;
  LoadRes: TWasmNativeLoadResult;
  Kind: TWasmExternKind;
  LeafAddr, RunAddr: UInt32;
  P, R: array[0 .. 0] of TWasmValue;
begin
  Bytes := AssembleWatText(LEAF_WAT);
  Waot := BuildNative(Bytes);
  Loaded := nil;
  Engine := nil;
  Store := nil;
  Native := nil;
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  try
    Loaded := LoadModule(Bytes);
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Inst := InstantiateModule(Store, Loaded.Ir, Loaded.BytesPtr,
      Loaded.BytesLength, Imports);
    Native := NativeLoadComplete(Store, Loaded, Inst, Waot, LoadRes);
    {$IFDEF WASM_JIT_BACKEND}
    if JitExecMemSupported then
    begin
      Expect<Boolean>(Native <> nil).ToBe(True);
      Expect<Boolean>(Inst.FindExport('mrw', Kind, LeafAddr)).ToBe(True);
      Expect<Boolean>(Inst.FindExport('run', Kind, RunAddr)).ToBe(True);
      {$IFDEF WASM_JIT_X64}
      { The leaf's code carries its lightweight entry at the canonical
        entry point (test rcx, rcx selects it); the caller's leaf-call site
        reads CompiledNativeScalarEntry and would otherwise take the helper
        fallback on every call. }
      Expect<Boolean>(Store.Funcs[LeafAddr].CompiledNativeScalarEntry =
        Store.Funcs[LeafAddr].CompiledEntry).ToBe(True);
      Expect<Boolean>(Store.Funcs[RunAddr].CompiledNativeScalarEntry = nil)
        .ToBe(True);
      {$ENDIF}
      P[0] := MakeValueI32(10);
      R[0].Bits := 0;
      NativeInvoke(Store, RunAddr, @P[0], @R[0]);
      Expect<UInt64>(R[0].Bits and $FFFFFFFF).ToBe(25);
      Exit;
    end;
    {$ENDIF}
    Expect<Boolean>(Native = nil).ToBe(True);
  finally
    Native.Free;
    Store.Free;
    Engine.Free;
    Loaded.Free;
  end;
end;

procedure TShellTests.TestMissingPayloadFile;
var
  Res: TWasmShellResult;
  Missing: string;
begin
  Missing := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight-shell-missing-' + IntToStr(GetTickCount64) + '.wshl';
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellFile(Missing, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('not found', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestIncompletePayloadFile;
var
  Module, Payload: TWasmBytes;
  Path: string;
  Res: TWasmShellResult;
begin
  Module := AssembleWatText(HELLO_WAT);
  Payload := WriteShellPayload(Module, nil, nil, nil);
  Path := WriteTempPayload(Payload);
  try
    FConfig := TWasmWasiConfig.Create;
    Res := RunShellFile(Path, FConfig);
    Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
    Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
    Expect<Boolean>(CapturedStdout = '').ToBe(True);
  finally
    DeleteFile(Path);
  end;
end;

procedure TShellTests.TestHelloViaPayloadFile;
var
  Path: string;
  Res: TWasmShellResult;
begin
  Path := WriteTempPayload(PayloadForWat(HELLO_WAT));
  try
    FConfig := TWasmWasiConfig.Create;
    Res := RunShellFile(Path, FConfig);
    {$IFDEF WASM_JIT_BACKEND}
    if JitExecMemSupported then
    begin
      Expect<Integer>(Res.ExitCode).ToBe(0);
      Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
      Exit;
    end;
    {$ENDIF}
    Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
    Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
    Expect<Boolean>(CapturedStdout = '').ToBe(True);
  finally
    DeleteFile(Path);
  end;
end;

procedure TShellTests.TestCorruptEmbeddedTrailer;
var
  Payload, Packaged: TWasmBytes;
  Path: string;
  Res: TWasmShellResult;
begin
  SetLength(Payload, 4);
  Payload[0] := Byte('W');
  Payload[1] := Byte('N');
  Payload[2] := Byte('E');
  Payload[3] := Byte('P');
  Expect<Integer>(Ord(PackageAppendedPayload(nil, Payload, Packaged))).ToBe(Ord(eprOk));
  Packaged[Length(Packaged) - WLSHELF_TRAILER_SIZE + 16] :=
    Packaged[Length(Packaged) - WLSHELF_TRAILER_SIZE + 16] xor 1;
  Path := WriteTempPayload(Packaged);
  FConfig := TWasmWasiConfig.Create;
  try
    Res := RunShellFile(Path, FConfig);
    Expect<Integer>(Res.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('malformed embedded payload trailer', Res.Diagnostic) > 0).ToBe(True);
  finally
    DeleteFile(Path);
  end;
end;

procedure TShellTests.TestStartParameter;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat('(module (memory (export "memory") 1)' +
    ' (func (export "_start") (param i32)))'), FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('must have type () -> ()', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestStartResult;
var
  Res: TWasmShellResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(PayloadForWat('(module (memory (export "memory") 1)' +
    ' (func (export "_start") (result i32) i32.const 7))'), FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('must have type () -> ()', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TShellTests.TestCapsFixtureMatchesSource;
const
  CAPS_FIXTURE = 'tests' + PathDelim + 'fixtures' + PathDelim + 'wasi' +
    PathDelim + 'caps.wasm';
var
  Stream: TFileStream;
  Fixture: TWasmBytes;
  FromFile, FromText: TWasmRunResult;
  Config: TWasmWasiConfig;
begin
  Stream := TFileStream.Create(CAPS_FIXTURE, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Fixture, Stream.Size);
    Stream.ReadBuffer(Fixture[0], Stream.Size);
  finally
    Stream.Free;
  end;
  Config := TWasmWasiConfig.Create;
  try
    Config.SetArgv(CompiledGuestArgv('caps.wasm', ['x']));
    Config.AddEnv('A=1');
    FromFile := RunModuleBytes(Fixture, Config);
  finally
    Config.Free;
  end;
  Config := TWasmWasiConfig.Create;
  try
    Config.SetArgv(CompiledGuestArgv('caps.wasm', ['x']));
    Config.AddEnv('A=1');
    FromText := RunModuleBytes(AssembleWatText(CAPS_COMMAND_WAT), Config);
  finally
    Config.Free;
  end;
  { argc 2 + 10 * envc 1, no preopen. }
  Expect<Integer>(FromFile.ExitCode).ToBe(12);
  Expect<Integer>(FromText.ExitCode).ToBe(FromFile.ExitCode);
end;

procedure TShellTests.TestExecutablePathIsAbsolute;
var
  Path: string;
begin
  Path := ShellExecutablePath;
  Expect<string>(ExpandFileName(Path)).ToBe(Path);
  Expect<Boolean>(FileExists(Path)).ToBe(True);
  Expect<string>(ExtractFileName(Path)).ToBe(ExtractFileName(ParamStr(0)));
end;

procedure TShellTests.SetupTests;
begin
  Test('corrupt embedded trailers fail before the attach seam', TestCorruptEmbeddedTrailer);
  Test('an empty payload is the unfilled template', TestEmptyPayload);
  Test('a malformed envelope is rejected before decode', TestMalformedPayload);
  Test('garbage module bytes are EWasmDecodeError', TestGarbageModuleIsDecodeError);
  Test('an ill-typed module is EWasmValidationError',
    TestInvalidModuleIsValidationError);
  Test('a missing native image is EWasmLinkError, not interpreted',
    TestIncompleteNativeRejected);
  Test('a native image for a different module is EWasmLinkError',
    TestStaleNativeRejected);
  Test('a non-empty connector plan is rejected (stub until later issues)',
    TestConnectorStubRejected);
  Test('a malformed capability set is rejected before instantiation',
    TestMalformedCapabilitySetRejected);
  Test('a config that already grants env or a preopen cannot expand the set',
    TestCapabilitySetCannotBeExpanded);
  Test('compiled preopens, env, and argv reach the guest, or fail closed',
    TestCompiledCapabilitiesReachGuest);
  Test('a compiled executable gives the guest the argc run gives',
    TestArgcMatchesRun);
  Test('the committed caps.wasm behaves as its wat source',
    TestCapsFixtureMatchesSource);
  Test('the shell asks the OS for an absolute executable path',
    TestExecutablePathIsAbsolute);
  Test('a module with no _start is rejected', TestNoStart);
  Test('_start parameters fail the command contract', TestStartParameter);
  Test('_start results fail the command contract', TestStartResult);
  Test('a reactor is rejected', TestReactor);
  Test('an import outside WASI fails to link', TestBadImport);
  Test('hello writes through native entries, or fails closed off-backend',
    TestHelloNativeOrClosed);
  Test('unreachable in _start traps through native entries, or fails closed',
    TestTrapNativeOrClosed);
  Test('17+25 then proc_exit(42) is a native numeric probe, or fails closed',
    TestAddExitNativeOrClosed);
  Test('proc_exit(42) through native _start, or fails closed',
    TestProcExitNativeOrClosed);
  Test('a wasm-to-wasm call runs natively, or fails closed',
    TestCallNativeOrClosed);
  Test('a native image wires x64 leaf entries for its leaf-call sites',
    TestNativeLeafEntriesWired);
  Test('a missing payload file is rejected', TestMissingPayloadFile);
  Test('an incomplete payload file is EWasmLinkError, not interpreted',
    TestIncompletePayloadFile);
  Test('hello through a payload file runs natively, or fails closed',
    TestHelloViaPayloadFile);
end;

begin
  TestRunnerProgram.AddSuite(TShellTests.Create('Wasm.Shell'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
