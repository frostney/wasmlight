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
  Wasm.Core,
  Wasm.Engine,
  Wasm.Jit.CodeBuffer,
  Wasm.Runtime.Store,
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

type
  TShellTests = class(TTestSuite)
  private
    FConfig: TWasmWasiConfig;
    function CapturedStdout: string;
    function BuildNative(const ABytes: TWasmBytes): TWasmBytes;
    function PayloadForWat(const AWat: string): TWasmBytes;
    function WriteTempPayload(const ABytes: TWasmBytes): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestEmptyPayload;
    procedure TestMalformedPayload;
    procedure TestGarbageModuleIsDecodeError;
    procedure TestInvalidModuleIsValidationError;
    procedure TestIncompleteNativeRejected;
    procedure TestStaleNativeRejected;
    procedure TestConnectorStubRejected;
    procedure TestCapabilityStubRejected;
    procedure TestNoStart;
    procedure TestReactor;
    procedure TestBadImport;
    procedure TestHelloNativeOrClosed;
    procedure TestTrapNativeOrClosed;
    procedure TestAddExitNativeOrClosed;
    procedure TestProcExitNativeOrClosed;
    procedure TestCallNativeOrClosed;
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

procedure TShellTests.TestCapabilityStubRejected;
var
  Module, Caps, Payload: TWasmBytes;
  Res: TWasmShellResult;
begin
  Module := AssembleWatText(HELLO_WAT);
  SetLength(Caps, 1);
  Caps[0] := 1;
  Payload := WriteShellPayload(Module, BuildNative(Module), nil, Caps);
  FConfig := TWasmWasiConfig.Create;
  Res := RunShellBytes(Payload, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(WASM_SHELL_EXIT_ERROR);
  Expect<Boolean>(Pos('capability set', Res.Diagnostic) > 0).ToBe(True);
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

procedure TShellTests.SetupTests;
begin
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
  Test('a non-empty capability set is rejected (stub until #40)',
    TestCapabilityStubRejected);
  Test('a module with no _start is rejected', TestNoStart);
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
