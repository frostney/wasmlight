{ Unit suite for Wasm.Compile — the `wasmlight compile` core (ADR-0015).

  The command is wired before the strict AOT and runtime-shell work
  land: these tests prove the CLI contract, selected-connector parse,
  and the structured failure stages, not a shipped native executable. Every module
  is assembled from wat through the shipped assembler. Output paths are
  temp files that must stay absent (or unchanged) after a failed compile.
  No network, no `.waot` fallback, no interpreter/JIT execution. }
program Wasm.Compile.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  CLI.Options,
  TestingPascalLibrary,
  Wasm.Compile,
  Wasm.Connector,
  Wasm.Core,
  Wasm.Wat.Assembler;

const
  EMPTY_WAT = '(module)';

  INVALID_WAT =
    '(module (func (result i32)))';

  IMPORT_WAT =
    '(module' + sLineBreak +
    '  (import "env" "foo" (func $foo))' + sLineBreak +
    '  (func (export "_start") (call $foo)))';

  WASI_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit"' + sLineBreak +
    '    (func $proc_exit (param i32)))' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "_start") (call $proc_exit (i32.const 0))))';

type
  TCompileTests = class(TTestSuite)
  private
    FTempDir: string;
    FOutputPath: string;
    FModulePath: string;

    FPositionals: TStringList;
    FOptions: TOptionArray;
    FOutputOpt: TStringOption;
    FTargetOpt: TStringOption;
    FConnectorOpt: TRepeatableOption;

    function NewRequest(const ATarget: string): TWasmCompileRequest;
    function CompileWat(const AWat: string): TWasmCompileResult;
    function CompileWatToFile(const AWat: string): TWasmCompileResult;
    function OutputExists: Boolean;
    procedure WriteUtf8File(const APath, AText: string);
    function ReadUtf8File(const APath: string): string;
    procedure BeginOptions;
    procedure EndOptions;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestErrorClassesAreSiblings;
    procedure TestHelpDocumentsOwnedOptions;
    procedure TestMissingModuleIsUsageError;
    procedure TestMissingOutputIsUsageError;
    procedure TestUnexpectedArgumentIsUsageError;
    procedure TestDefaultTargetIsHost;
    procedure TestExplicitReleasedTargetIsAccepted;
    procedure TestUnknownTargetFailsBeforeDecode;
    procedure TestUnreleasedTargetFailsAsPackaging;
    procedure TestFlagShapedOutputAndConnectorValues;
    procedure TestRepeatableConnectors;
    procedure TestDuplicateConnectorIsError;
    procedure TestMissingConnectorFileIsError;
    procedure TestValidConnectorDoesNotSatisfyImports;
    procedure TestMalformedConnectorIsParseError;
    procedure TestDecodeFailure;
    procedure TestValidationFailure;
    procedure TestImportWithoutConnectorIsLinkError;
    procedure TestWasiImportWithoutConnectorIsLinkError;
    procedure TestEmptyModuleFailsAtStrictCompile;
    procedure TestFailedCompileLeavesNoOutput;
    procedure TestFailedCompileLeavesExistingOutput;
    procedure TestSiblingWaotIsIgnored;
    procedure TestWriteOutputRejectsDirectory;
    procedure TestWriteOutputIsAtomic;
    procedure TestPackageStubIsPackagingError;
  end;

function TCompileTests.NewRequest(const ATarget: string): TWasmCompileRequest;
begin
  Result.ModulePath := FModulePath;
  Result.OutputPath := FOutputPath;
  Result.Target := ATarget;
  Result.Connectors := nil;
end;

function TCompileTests.CompileWat(const AWat: string): TWasmCompileResult;
begin
  { Pipeline tests name a released target so a Windows/i386 host default
    cannot turn every case into a packaging error. }
  Result := CompileModuleBytes(AssembleWatText(AWat),
    NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN));
end;

function TCompileTests.CompileWatToFile(const AWat: string): TWasmCompileResult;
var
  Bytes: TWasmBytes;
  Stream: TFileStream;
  Request: TWasmCompileRequest;
begin
  Bytes := AssembleWatText(AWat);
  Stream := TFileStream.Create(FModulePath, fmCreate);
  try
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Request := NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  Result := CompileConfiguredModule(Request);
end;

function TCompileTests.OutputExists: Boolean;
begin
  Result := FileExists(FOutputPath);
end;

procedure TCompileTests.WriteUtf8File(const APath, AText: string);
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

function TCompileTests.ReadUtf8File(const APath: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure TCompileTests.BeginOptions;
begin
  FPositionals := TStringList.Create;
  FOptions := CreateCompileOptions(FOutputOpt, FTargetOpt, FConnectorOpt);
end;

procedure TCompileTests.EndOptions;
var
  I: Integer;
begin
  for I := 0 to High(FOptions) do
    FOptions[I].Free;
  FOptions := nil;
  FreeAndNil(FPositionals);
end;

procedure TCompileTests.BeforeEach;
begin
  FPositionals := nil;
  FOptions := nil;
  FTempDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight-compile-' + IntToHex(Random(MaxInt), 8);
  CreateDir(FTempDir);
  FOutputPath := IncludeTrailingPathDelimiter(FTempDir) + 'app';
  FModulePath := IncludeTrailingPathDelimiter(FTempDir) + 'mod.wasm';
end;

procedure TCompileTests.AfterEach;
var
  Search: TSearchRec;
begin
  if FPositionals <> nil then
    EndOptions;
  if DirectoryExists(FTempDir) then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(FTempDir) + '*',
      faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Name <> '.') and (Search.Name <> '..') then
          DeleteFile(IncludeTrailingPathDelimiter(FTempDir) + Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    RemoveDir(FTempDir);
  end;
end;

procedure TCompileTests.TestErrorClassesAreSiblings;
begin
  Expect<Boolean>(EWasmConnectorError.InheritsFrom(EWasmError)).ToBe(True);
  Expect<Boolean>(EWasmCompileError.InheritsFrom(EWasmError)).ToBe(True);
  Expect<Boolean>(EWasmPackagingError.InheritsFrom(EWasmError)).ToBe(True);
  Expect<Boolean>(EWasmConnectorError.InheritsFrom(EWasmLinkError)).ToBe(False);
  Expect<Boolean>(EWasmCompileError.InheritsFrom(EWasmTrap)).ToBe(False);
  Expect<Boolean>(EWasmPackagingError.InheritsFrom(EWasmCompileError)).ToBe(False);
end;

procedure TCompileTests.TestHelpDocumentsOwnedOptions;
begin
  BeginOptions;
  try
    Expect<string>(FOptions[0].LongName).ToBe('output');
    Expect<string>(FOptions[0].ShortName).ToBe('o');
    Expect<Boolean>(Pos('executable', FOptions[0].HelpText) > 0).ToBe(True);
    Expect<string>(FOptions[0].FormatForHelp).ToBe('--output=<value>');
    Expect<string>(FOptions[1].LongName).ToBe('target');
    Expect<Boolean>(Pos('aarch64-darwin', FOptions[1].HelpText) > 0).ToBe(True);
    Expect<Boolean>(Pos('x86_64-linux', FOptions[1].HelpText) > 0).ToBe(True);
    Expect<string>(FOptions[2].LongName).ToBe('connector');
    Expect<Boolean>(Pos('repeatable', FOptions[2].HelpText) > 0).ToBe(True);
    Expect<string>(FOptions[2].FormatForHelp).ToBe('--connector <value>');
  finally
    EndOptions;
  end;
end;

procedure TCompileTests.TestMissingModuleIsUsageError;
var
  Res: TWasmCompileResult;
begin
  BeginOptions;
  try
    FOutputOpt.Apply(FOutputPath);
    Res := CompileFromOptions(FPositionals, FOptions);
    Expect<Integer>(Res.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('expected <module.wasm>', Res.Diagnostic) > 0).ToBe(True);
    Expect<Boolean>(Pos('EWasm', Res.Diagnostic) > 0).ToBe(False);
  finally
    EndOptions;
  end;
end;

procedure TCompileTests.TestMissingOutputIsUsageError;
var
  Res: TWasmCompileResult;
begin
  BeginOptions;
  try
    FPositionals.Add(FModulePath);
    Res := CompileFromOptions(FPositionals, FOptions);
    Expect<Integer>(Res.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('expected -o <executable>', Res.Diagnostic) > 0)
      .ToBe(True);
  finally
    EndOptions;
  end;
end;

procedure TCompileTests.TestUnexpectedArgumentIsUsageError;
var
  Res: TWasmCompileResult;
begin
  BeginOptions;
  try
    FPositionals.Add(FModulePath);
    FPositionals.Add('--verbose');
    FOutputOpt.Apply(FOutputPath);
    Res := CompileFromOptions(FPositionals, FOptions);
    Expect<Integer>(Res.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('unexpected argument: --verbose', Res.Diagnostic) > 0)
      .ToBe(True);
  finally
    EndOptions;
  end;
end;

procedure TCompileTests.TestDefaultTargetIsHost;
var
  Request: TWasmCompileRequest;
  Err: string;
begin
  BeginOptions;
  try
    FPositionals.Add(FModulePath);
    FOutputOpt.Apply(FOutputPath);
    Expect<Boolean>(CompileRequestFromOptions(FPositionals, FOptions,
      Request, Err)).ToBe(True);
    Expect<string>(Request.Target).ToBe('');
    Expect<Boolean>(CompileHostTarget <> '').ToBe(True);
  finally
    EndOptions;
  end;
end;

procedure TCompileTests.TestExplicitReleasedTargetIsAccepted;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
begin
  Request := NewRequest(WASM_COMPILE_TARGET_X64_LINUX);
  Res := CompileModuleBytes(AssembleWatText(EMPTY_WAT), Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmCompileError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestUnknownTargetFailsBeforeDecode;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
begin
  { Garbage bytes would be a decode error if the target check did not run
    first. The class must stay packaging, not decode. }
  Request := NewRequest('sparc-solaris');
  Request.ModulePath := FModulePath;
  WriteUtf8File(FModulePath, 'not a module');
  Res := CompileConfiguredModule(Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmPackagingError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('unknown compile target', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('EWasmDecodeError', Res.Diagnostic) > 0).ToBe(False);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestUnreleasedTargetFailsAsPackaging;
var
  Res: TWasmCompileResult;
begin
  Res := CompileModuleBytes(AssembleWatText(EMPTY_WAT),
    NewRequest(WASM_COMPILE_TARGET_X64_WIN64));
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmPackagingError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('not a released compile target', Res.Diagnostic) > 0)
    .ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestFlagShapedOutputAndConnectorValues;
var
  Request: TWasmCompileRequest;
  Err: string;
begin
  { CLI.Parser accepts a short `-o` value that begins with `-`, and the
    `--output=--out` / `--connector=--lib.wlc` equals form. The request
    mapping must keep those paths verbatim. }
  BeginOptions;
  try
    FPositionals.Add('--mod.wasm');
    FOutputOpt.Apply('--out.bin');
    FConnectorOpt.Apply('--lib.wlc');
    FConnectorOpt.Apply('--other.wlc');
    Expect<Boolean>(CompileRequestFromOptions(FPositionals, FOptions,
      Request, Err)).ToBe(True);
    Expect<string>(Request.ModulePath).ToBe('--mod.wasm');
    Expect<string>(Request.OutputPath).ToBe('--out.bin');
    Expect<Integer>(Length(Request.Connectors)).ToBe(2);
    Expect<string>(Request.Connectors[0]).ToBe('--lib.wlc');
    Expect<string>(Request.Connectors[1]).ToBe('--other.wlc');
  finally
    EndOptions;
  end;
end;

procedure TCompileTests.TestRepeatableConnectors;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
  One, Two: string;
begin
  One := IncludeTrailingPathDelimiter(FTempDir) + 'one.wlc';
  Two := IncludeTrailingPathDelimiter(FTempDir) + 'two.wlc';
  WriteUtf8File(One, '// first connector' + sLineBreak);
  WriteUtf8File(Two, '// second connector' + sLineBreak);
  Request := NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  SetLength(Request.Connectors, 2);
  Request.Connectors[0] := One;
  Request.Connectors[1] := Two;
  Res := CompileModuleBytes(AssembleWatText(EMPTY_WAT), Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmCompileError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('EWasmConnectorError', Res.Diagnostic) > 0).ToBe(False);
  Expect<Boolean>(OutputExists).ToBe(False);
  DeleteFile(One);
  DeleteFile(Two);
end;

procedure TCompileTests.TestDuplicateConnectorIsError;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
  One: string;
begin
  One := IncludeTrailingPathDelimiter(FTempDir) + 'dup.wlc';
  WriteUtf8File(One, '// duplicate connector' + sLineBreak);
  Request := NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  SetLength(Request.Connectors, 2);
  Request.Connectors[0] := One;
  Request.Connectors[1] := One;
  Res := CompileModuleBytes(AssembleWatText(EMPTY_WAT), Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmConnectorError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('duplicate --connector', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
  DeleteFile(One);
end;

procedure TCompileTests.TestMissingConnectorFileIsError;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
begin
  Request := NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  SetLength(Request.Connectors, 1);
  Request.Connectors[0] := IncludeTrailingPathDelimiter(FTempDir) +
    'missing.wlc';
  Res := CompileModuleBytes(AssembleWatText(EMPTY_WAT), Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmConnectorError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('cannot read connector', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestValidConnectorDoesNotSatisfyImports;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
  Connector: string;
begin
  { Parsing a selected connector does not resolve guest imports; that is
    issue #42. Until then an import stays an EWasmLinkError. }
  Connector := IncludeTrailingPathDelimiter(FTempDir) + 'env.wlc';
  WriteUtf8File(Connector,
    'static class Env {' + sLineBreak +
    '  [DllImport("env")]' + sLineBreak +
    '  static extern void foo();' + sLineBreak +
    '}' + sLineBreak);
  Request := NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  SetLength(Request.Connectors, 1);
  Request.Connectors[0] := Connector;
  Res := CompileModuleBytes(AssembleWatText(IMPORT_WAT), Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('"env"."foo"', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('EWasmConnectorError', Res.Diagnostic) > 0).ToBe(False);
  Expect<Boolean>(OutputExists).ToBe(False);
  DeleteFile(Connector);
end;

procedure TCompileTests.TestMalformedConnectorIsParseError;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
  Connector: string;
begin
  Connector := IncludeTrailingPathDelimiter(FTempDir) + 'bad.wlc';
  WriteUtf8File(Connector,
    'static class C { [DllImport("x")] static extern int f() { return 1; } }');
  Request := NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  SetLength(Request.Connectors, 1);
  Request.Connectors[0] := Connector;
  Res := CompileModuleBytes(AssembleWatText(EMPTY_WAT), Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmConnectorError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos(MSG_WLC_METHOD_BODY, Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(False);
  Expect<Boolean>(OutputExists).ToBe(False);
  DeleteFile(Connector);
end;

procedure TCompileTests.TestDecodeFailure;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
begin
  WriteUtf8File(FModulePath, 'not a wasm module');
  Request := NewRequest(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  Res := CompileConfiguredModule(Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmDecodeError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestValidationFailure;
var
  Res: TWasmCompileResult;
begin
  Res := CompileWat(INVALID_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmValidationError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestImportWithoutConnectorIsLinkError;
var
  Res: TWasmCompileResult;
begin
  Res := CompileWat(IMPORT_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('unknown import', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('"env"."foo"', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestWasiImportWithoutConnectorIsLinkError;
var
  Res: TWasmCompileResult;
begin
  { Compile-time WASI is issue #40. Until then a WASI import is unsatisfied
    and must not fall through to the interpreter or `wasmlight run`. }
  Res := CompileWat(WASI_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmLinkError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('wasi_snapshot_preview1', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);
end;

procedure TCompileTests.TestEmptyModuleFailsAtStrictCompile;
var
  Res: TWasmCompileResult;
  Request: TWasmCompileRequest;
begin
  Res := CompileWat(EMPTY_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmCompileError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('strict compile is not available', Res.Diagnostic) > 0)
    .ToBe(True);
  Expect<Boolean>(OutputExists).ToBe(False);

  { The host default is only a default: on a released host it reaches the
    same stub; on Windows/i386 it is an unreleased packaging error. }
  Request := NewRequest('');
  Res := CompileModuleBytes(AssembleWatText(EMPTY_WAT), Request);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  if IsReleasedCompileTarget(CompileHostTarget) then
    Expect<Boolean>(Pos('EWasmCompileError', Res.Diagnostic) > 0).ToBe(True)
  else
    Expect<Boolean>(Pos('EWasmPackagingError', Res.Diagnostic) > 0).ToBe(True);
end;

procedure TCompileTests.TestFailedCompileLeavesNoOutput;
var
  Res: TWasmCompileResult;
begin
  Res := CompileWatToFile(EMPTY_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(OutputExists).ToBe(False);
  Expect<Boolean>(FileExists(FOutputPath + '.tmp')).ToBe(False);
end;

procedure TCompileTests.TestFailedCompileLeavesExistingOutput;
var
  Res: TWasmCompileResult;
begin
  WriteUtf8File(FOutputPath, 'keep-me');
  Res := CompileWat(EMPTY_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<string>(ReadUtf8File(FOutputPath)).ToBe('keep-me');
end;

procedure TCompileTests.TestSiblingWaotIsIgnored;
var
  Res: TWasmCompileResult;
  WaotPath: string;
begin
  { A sibling `.waot` is the `run --aot` cache. Compile must not load it,
    fall back to it, or treat it as success. }
  WaotPath := ChangeFileExt(FModulePath, '.waot');
  WriteUtf8File(WaotPath, 'not an artifact');
  Res := CompileWatToFile(EMPTY_WAT);
  Expect<Integer>(Res.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('EWasmCompileError', Res.Diagnostic) > 0).ToBe(True);
  Expect<Boolean>(Pos('waot', LowerCase(Res.Diagnostic)) > 0).ToBe(False);
  Expect<Boolean>(OutputExists).ToBe(False);
  DeleteFile(WaotPath);
end;

procedure TCompileTests.TestWriteOutputRejectsDirectory;
var
  Raised: Boolean;
  Msg: string;
begin
  Raised := False;
  Msg := '';
  try
    WriteCompileOutput(FTempDir, nil);
  except
    on E: EStreamError do
    begin
      Raised := True;
      Msg := E.Message;
    end;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(Pos('directory', Msg) > 0).ToBe(True);
end;

procedure TCompileTests.TestWriteOutputIsAtomic;
var
  Payload: TWasmBytes;
begin
  SetLength(Payload, 4);
  Payload[0] := Byte('W');
  Payload[1] := Byte('A');
  Payload[2] := Byte('S');
  Payload[3] := Byte('M');
  WriteUtf8File(FOutputPath, 'old');
  WriteCompileOutput(FOutputPath, Payload);
  Expect<string>(ReadUtf8File(FOutputPath)).ToBe('WASM');
  Expect<Boolean>(FileExists(FOutputPath + '.tmp')).ToBe(False);
end;

procedure TCompileTests.TestPackageStubIsPackagingError;
var
  Raised: Boolean;
  Msg: string;
begin
  Raised := False;
  Msg := '';
  try
    PackageCompilePayload(WASM_COMPILE_TARGET_AARCH64_DARWIN);
  except
    on E: EWasmPackagingError do
    begin
      Raised := True;
      Msg := E.Message;
    end;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(Pos('runtime shell packaging is not available', Msg) > 0)
    .ToBe(True);
end;

procedure TCompileTests.SetupTests;
begin
  Test('compile error classes are siblings under EWasmError',
    TestErrorClassesAreSiblings);
  Test('help documents every owned compile option',
    TestHelpDocumentsOwnedOptions);
  Test('missing module is a usage error', TestMissingModuleIsUsageError);
  Test('missing -o is a usage error', TestMissingOutputIsUsageError);
  Test('a second positional is a usage error',
    TestUnexpectedArgumentIsUsageError);
  Test('omitted --target means the host default', TestDefaultTargetIsHost);
  Test('an explicit released --target reaches strict compile',
    TestExplicitReleasedTargetIsAccepted);
  Test('an unknown --target fails before decode',
    TestUnknownTargetFailsBeforeDecode);
  Test('an unreleased --target is a packaging error',
    TestUnreleasedTargetFailsAsPackaging);
  Test('flag-shaped -o and --connector values are kept',
    TestFlagShapedOutputAndConnectorValues);
  Test('repeatable --connector parses every selected file',
    TestRepeatableConnectors);
  Test('a duplicate --connector is a connector error',
    TestDuplicateConnectorIsError);
  Test('a missing --connector file is a connector error',
    TestMissingConnectorFileIsError);
  Test('a parsed connector does not satisfy imports',
    TestValidConnectorDoesNotSatisfyImports);
  Test('a malformed --connector file is a connector error',
    TestMalformedConnectorIsParseError);
  Test('garbage bytes are a decode error', TestDecodeFailure);
  Test('an ill-typed module is a validation error', TestValidationFailure);
  Test('an import without a connector is a link error',
    TestImportWithoutConnectorIsLinkError);
  Test('a WASI import without compile-time WASI is a link error',
    TestWasiImportWithoutConnectorIsLinkError);
  Test('a valid module fails at the strict-compile stub',
    TestEmptyModuleFailsAtStrictCompile);
  Test('a failed compile writes no executable',
    TestFailedCompileLeavesNoOutput);
  Test('a failed compile leaves an existing output untouched',
    TestFailedCompileLeavesExistingOutput);
  Test('a sibling .waot is not a compile fallback', TestSiblingWaotIsIgnored);
  Test('writing onto a directory is an I/O error',
    TestWriteOutputRejectsDirectory);
  Test('a successful write replaces the output atomically',
    TestWriteOutputIsAtomic);
  Test('packaging is a distinct stub error', TestPackageStubIsPackagingError);
end;

begin
  Randomize;
  TestRunnerProgram.AddSuite(TCompileTests.Create('Wasm.Compile'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
