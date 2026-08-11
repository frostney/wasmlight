{ Unit suite for Wasm.Run — Track F3, the `wasmlight run` core.

  The hello-world milestone, tested end-to-end but HERMETICALLY: every module is
  a real .wasm assembled from wat text through the shipped Wasm.Wat.Assembler,
  run through the exact Wasm.Engine + Wasm.Wasi path `wasmlight run` uses, with
  stdout wired to the config's default in-memory capture buffer rather than the
  real process stdout. No file, no real stdio, no fs, no network — the run core
  takes bytes and a config, so the test hands it both and asserts on the
  captured buffer and the returned exit code. The CLI (source/apps/wasmlight.pas)
  is the same call with real fds and a real file.

  Coverage (embedding-spec.md §4, §6):
    - hello-world: a command importing fd_write that writes "hello\n" to fd 1
      and returns -> captured stdout is exactly "hello\n", exit 0;
    - the SAME program loaded as the committed tests/fixtures/wasi/hello.wasm
      binary (RunConfiguredModule, the CLI's file path) -> "hello\n", exit 0,
      so the fixture is exercised and cannot silently drift;
    - proc_exit(42) -> exit 42; proc_exit(256) -> exit 0 (masked to a byte);
    - a trap (unreachable in _start) -> exit 134, "trap" in the diagnostic;
    - no _start export -> exit 1, "_start" in the diagnostic;
    - a reactor (only _initialize) -> exit 1, reported as a reactor, not run;
    - a command that does not export "memory" -> exit 1;
    - an import outside wasi_snapshot_preview1 -> exit 1 (link failure);
    - garbage bytes -> exit 1 (decode failure), never a crash.

  The hello module here is byte-for-byte the source of tests/fixtures/wasi/
  hello.wat (regenerable to hello.wasm with wat2wasm), so the committed fixture
  the CLI runs and the module this suite asserts on are the same program.

  Spec pin (core, for the embedding anchors): wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
program Wasm.Run.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Aot,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Run,
  Wasm.Runtime.Store,
  Wasm.Wasi,
  Wasm.Wat.Assembler;

const
  { The hello-world command: import fd_write, export memory + _start; lay out a
    single ciovec at offset 0 pointing at "hello\n" (at offset 100) and write it
    to fd 1. Identical to tests/fixtures/wasi/hello.wat. }
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

  { unreachable in _start -> a guest trap. }
  TRAP_WAT =
    '(module (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (unreachable)))';

  { a module with a memory but no _start -> not a command. }
  NO_START_WAT =
    '(module (memory (export "memory") 1))';

  { a reactor: _initialize but no _start. }
  REACTOR_WAT =
    '(module (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_initialize")))';

  { a command with a _start but no exported memory. }
  NO_MEMORY_WAT =
    '(module (func (export "_start")))';

  { The committed binary fixture that hello.wat assembles to — the exact
    program the CLI runs, loaded from disk here so the binary stays in sync
    with its behaviour and does not drift from HELLO_WAT. The suite runs with
    the repo root as its working directory (as the other fixture suites do). }
  HELLO_FIXTURE = 'tests' + PathDelim + 'fixtures' + PathDelim + 'wasi'
    + PathDelim + 'hello.wasm';

  { a command importing something outside wasi_snapshot_preview1 -> link fail. }
  BAD_IMPORT_WAT =
    '(module' + sLineBreak +
    '  (import "env" "foo" (func $foo))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (call $foo)))';

{ A command that calls proc_exit(ACode). }
function ExitWat(const ACode: Integer): string;
begin
  Result :=
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit"' + sLineBreak +
    '    (func $proc_exit (param i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (call $proc_exit (i32.const '
    + IntToStr(ACode) + '))))';
end;

{ Build a REAL `.waot` artifact for ABYTES on THIS host (aot-spec §3): decode +
  validate the module, then AOT-compile every compilable function to the
  fixed-width artifact buffer. The moduleHash is over ABytes, so running the
  SAME ABytes through the AOT-aware run matches the hash and the code is used;
  a different module's bytes mismatch and fall back. Hermetic — no file, no
  network — the whole round-trip is in memory. }
function BuildArtifactFromBytes(const ABytes: TWasmBytes): TWasmBytes;
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

type
  TRunTests = class(TTestSuite)
  private
    { The config for the run under test — kept so the test can read the captured
      stdout after the run, freed in AfterEach. }
    FConfig: TWasmWasiConfig;

    { Assemble AWat and run it through the run core against a fresh default
      config (stdio = capture buffers). }
    function RunWat(const AWat: string): TWasmRunResult;
    { Load and run a committed .wasm from disk (RunConfiguredModule, the exact
      file path the CLI takes) against a fresh default config. }
    function RunFile(const APath: string): TWasmRunResult;
    { Everything the default stdout buffer captured, as a string. }
    function CapturedStdout: string;
    { The captured stdout of an arbitrary config (for a side-by-side compare of
      an interpreted run against an AOT-loaded one). }
    function StdoutOf(const AConfig: TWasmWasiConfig): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestHelloWorld;
    procedure TestHelloFixtureFile;
    procedure TestProcExit42;
    procedure TestProcExitMaskedToByte;
    procedure TestTrapIs134;
    procedure TestNoStartIsError;
    procedure TestReactorIsRejected;
    procedure TestMissingMemoryIsError;
    procedure TestNonWasiImportFailsToLink;
    procedure TestGarbageBytesIsError;

    { AOT-load (aot-spec §4): the outcome is identical whether a module runs
      interpreted or through a matching AOT artifact, and a stale/garbage/absent
      artifact falls back transparently and still runs. }
    procedure TestAotMatchingArtifactMatchesInterpreter;
    procedure TestAotProcExitWithArtifact;
    procedure TestAotStaleArtifactFallsBack;
    procedure TestAotGarbageArtifactFallsBack;
    procedure TestAotNoArtifactInterprets;
  end;

procedure TRunTests.BeforeEach;
begin
  FConfig := nil;
end;

procedure TRunTests.AfterEach;
begin
  { The config owns and frees its default capture streams. }
  FreeAndNil(FConfig);
end;

function TRunTests.RunWat(const AWat: string): TWasmRunResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Result := RunModuleBytes(AssembleWatText(AWat), FConfig);
end;

function TRunTests.RunFile(const APath: string): TWasmRunResult;
begin
  FConfig := TWasmWasiConfig.Create;
  Result := RunConfiguredModule(APath, FConfig);
end;

function TRunTests.CapturedStdout: string;
begin
  Result := StdoutOf(FConfig);
end;

function TRunTests.StdoutOf(const AConfig: TWasmWasiConfig): string;
var
  Bytes: TBytes;
  Index: Integer;
begin
  Result := '';
  Bytes := TWasmWasiBufferStream(AConfig.Stdout).WrittenBytes;
  SetLength(Result, Length(Bytes));
  for Index := 0 to High(Bytes) do
    Result[Index + 1] := Chr(Bytes[Index]);
end;

{ --- tests --------------------------------------------------------------- }

procedure TRunTests.TestHelloWorld;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(HELLO_WAT);
  { The milestone: a real WASI command wrote "hello\n" to stdout and returned,
    the run core captured it and mapped the clean return to exit 0. }
  Expect<Integer>(Res.ExitCode).ToBe(0);
  Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
end;

procedure TRunTests.TestHelloFixtureFile;
var
  Res: TWasmRunResult;
begin
  { The COMMITTED binary, loaded from disk through the same file path the CLI
    takes. If hello.wasm ever drifts from hello.wat (or from its documented
    behaviour), this fails where the inline HELLO_WAT would not — the fixture
    is only useful if something exercises it. }
  Res := RunFile(HELLO_FIXTURE);
  Expect<Integer>(Res.ExitCode).ToBe(0);
  Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
end;

procedure TRunTests.TestProcExit42;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(ExitWat(42));
  { proc_exit(42) raised EWasmExit, mapped to the process code 42. }
  Expect<Integer>(Res.ExitCode).ToBe(42);
end;

procedure TRunTests.TestProcExitMaskedToByte;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(ExitWat(256));
  { A Unix exit status is 8 bits: 256 and $FF = 0 (embedding-spec.md §6.2). }
  Expect<Integer>(Res.ExitCode).ToBe(0);
end;

procedure TRunTests.TestTrapIs134;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(TRAP_WAT);
  { A trap aborts: 128 + SIGABRT = 134, with the trap message on the side. }
  Expect<Integer>(Res.ExitCode).ToBe(134);
  Expect<Boolean>(Pos('trap', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TRunTests.TestNoStartIsError;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(NO_START_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('_start', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TRunTests.TestReactorIsRejected;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(REACTOR_WAT);
  { A reactor (only _initialize) is out of scope for run — reported, not run. }
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('_initialize', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TRunTests.TestMissingMemoryIsError;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(NO_MEMORY_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('memory', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TRunTests.TestNonWasiImportFailsToLink;
var
  Res: TWasmRunResult;
begin
  Res := RunWat(BAD_IMPORT_WAT);
  { deny-by-default: an import wasmlight did not grant is a link failure, exit
    1, before _start ever runs. }
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Length(Res.Diagnostic) > 0).ToBe(True);
end;

procedure TRunTests.TestGarbageBytesIsError;
var
  Res: TWasmRunResult;
  Garbage: TWasmBytes;
begin
  { Four bytes that are not a module: a decode failure is exit 1, not a crash. }
  SetLength(Garbage, 4);
  Garbage[0] := 0;
  Garbage[1] := 1;
  Garbage[2] := 2;
  Garbage[3] := 3;
  FConfig := TWasmWasiConfig.Create;
  Res := RunModuleBytes(Garbage, FConfig);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Length(Res.Diagnostic) > 0).ToBe(True);
end;

{ --- AOT-load tests ------------------------------------------------------ }

procedure TRunTests.TestAotMatchingArtifactMatchesInterpreter;
var
  Bytes, Artifact: TWasmBytes;
  ResPlain, ResAot: TWasmRunResult;
  PlainCfg: TWasmWasiConfig;
  PlainOut: string;
begin
  { The hello command, and a real `.waot` compiled for it on this host. }
  Bytes := AssembleWatText(HELLO_WAT);
  Artifact := BuildArtifactFromBytes(Bytes);

  { Baseline: the same module run purely interpreted. }
  PlainCfg := TWasmWasiConfig.Create;
  try
    ResPlain := RunModuleBytes(Bytes, PlainCfg);
    PlainOut := StdoutOf(PlainCfg);
  finally
    PlainCfg.Free;
  end;

  { With the matching artifact: the exports run through AOT-loaded native code,
    yet the outcome — exit code AND stdout — is IDENTICAL to the interpreted
    run. That equivalence is the whole point of the tier. }
  FConfig := TWasmWasiConfig.Create;
  ResAot := RunModuleBytesAot(Bytes, FConfig, Artifact);

  Expect<Integer>(ResAot.ExitCode).ToBe(ResPlain.ExitCode);
  Expect<Boolean>(CapturedStdout = PlainOut).ToBe(True);
  Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
  { An artifact was offered and processed: the hash/arch/abi all match (built on
    this host for these exact bytes), so on a backend host it loads; the status
    is non-empty either way. }
  Expect<Boolean>(Length(ResAot.AotStatus) > 0).ToBe(True);
end;

procedure TRunTests.TestAotProcExitWithArtifact;
var
  Bytes, Artifact: TWasmBytes;
  ResPlain, ResAot: TWasmRunResult;
  PlainCfg: TWasmWasiConfig;
begin
  { A compute-then-proc_exit(42) command: _start is AOT-compilable, so this
    exercises the exit-code path through the AOT tier. }
  Bytes := AssembleWatText(ExitWat(42));
  Artifact := BuildArtifactFromBytes(Bytes);

  PlainCfg := TWasmWasiConfig.Create;
  try
    ResPlain := RunModuleBytes(Bytes, PlainCfg);
  finally
    PlainCfg.Free;
  end;

  FConfig := TWasmWasiConfig.Create;
  ResAot := RunModuleBytesAot(Bytes, FConfig, Artifact);

  Expect<Integer>(ResPlain.ExitCode).ToBe(42);
  Expect<Integer>(ResAot.ExitCode).ToBe(42);
end;

procedure TRunTests.TestAotStaleArtifactFallsBack;
var
  HelloBytes, ExitBytes, WrongArtifact: TWasmBytes;
  Res: TWasmRunResult;
begin
  { An artifact compiled for a DIFFERENT module (the proc_exit command) is
    offered when running the hello command. Its moduleHash does not match the
    hello bytes, so the load is rejected and the run falls back to the
    interpreter — hello still prints "hello\n" and exits 0. A stale artifact
    only loses the speedup; it never breaks the run or runs wrong-module code. }
  HelloBytes := AssembleWatText(HELLO_WAT);
  ExitBytes := AssembleWatText(ExitWat(9));
  WrongArtifact := BuildArtifactFromBytes(ExitBytes);

  FConfig := TWasmWasiConfig.Create;
  Res := RunModuleBytesAot(HelloBytes, FConfig, WrongArtifact);

  Expect<Integer>(Res.ExitCode).ToBe(0);
  Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
  Expect<Boolean>(Pos('fell back', Res.AotStatus) > 0).ToBe(True);
end;

procedure TRunTests.TestAotGarbageArtifactFallsBack;
var
  Bytes, Garbage: TWasmBytes;
  Res: TWasmRunResult;
begin
  { Bytes that are not a `.waot` at all (bad magic): the guard rejects them and
    the run falls back to the interpreter, still correct. }
  Bytes := AssembleWatText(HELLO_WAT);
  SetLength(Garbage, 8);
  Garbage[0] := Ord('n');
  Garbage[1] := Ord('o');
  Garbage[2] := Ord('p');
  Garbage[3] := Ord('e');
  Garbage[4] := 0;
  Garbage[5] := 1;
  Garbage[6] := 2;
  Garbage[7] := 3;

  FConfig := TWasmWasiConfig.Create;
  Res := RunModuleBytesAot(Bytes, FConfig, Garbage);

  Expect<Integer>(Res.ExitCode).ToBe(0);
  Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
  Expect<Boolean>(Pos('fell back', Res.AotStatus) > 0).ToBe(True);
end;

procedure TRunTests.TestAotNoArtifactInterprets;
var
  Bytes: TWasmBytes;
  Res: TWasmRunResult;
begin
  { No artifact offered (empty buffer): the run is pure interpreter, exactly as
    before AOT existed, and AotStatus stays empty (nothing was attempted). }
  Bytes := AssembleWatText(HELLO_WAT);
  FConfig := TWasmWasiConfig.Create;
  Res := RunModuleBytesAot(Bytes, FConfig, nil);

  Expect<Integer>(Res.ExitCode).ToBe(0);
  Expect<Boolean>(CapturedStdout = 'hello' + #10).ToBe(True);
  Expect<Boolean>(Res.AotStatus = '').ToBe(True);
end;

procedure TRunTests.SetupTests;
begin
  Test('hello-world: a WASI command writes "hello\n" to captured stdout, exit 0',
    TestHelloWorld);
  Test('the committed hello.wasm fixture loads from disk, prints "hello\n", '
    + 'exit 0', TestHelloFixtureFile);
  Test('proc_exit(42) maps to process exit 42', TestProcExit42);
  Test('proc_exit(256) is masked to a byte (exit 0)', TestProcExitMaskedToByte);
  Test('a guest trap maps to exit 134 with the trap message', TestTrapIs134);
  Test('a module with no _start is a clear error, exit 1', TestNoStartIsError);
  Test('a reactor (_initialize only) is rejected, exit 1', TestReactorIsRejected);
  Test('a command with no exported memory is an error, exit 1',
    TestMissingMemoryIsError);
  Test('an import outside wasi_snapshot_preview1 fails to link, exit 1',
    TestNonWasiImportFailsToLink);
  Test('garbage bytes are a decode error, exit 1, not a crash',
    TestGarbageBytesIsError);
  Test('a matching AOT artifact gives the SAME exit code + stdout as interpreted',
    TestAotMatchingArtifactMatchesInterpreter);
  Test('proc_exit(42) through a matching AOT artifact still maps to exit 42',
    TestAotProcExitWithArtifact);
  Test('a stale AOT artifact (wrong module) falls back and still runs correctly',
    TestAotStaleArtifactFallsBack);
  Test('a garbage AOT artifact falls back and still runs correctly',
    TestAotGarbageArtifactFallsBack);
  Test('no AOT artifact runs purely interpreted, AotStatus empty',
    TestAotNoArtifactInterprets);
end;

begin
  TestRunnerProgram.AddSuite(TRunTests.Create('Wasm.Run'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
