{ Wasm.Compile — the testable core of `wasmlight compile` (ADR-0015).

  `wasmlight compile <module.wasm> -o <executable>` is the native-application
  command: validate once, compile every guest function, and emit a complete
  interpreter-free executable. Sibling work still owns the strict AOT API,
  runtime shells, and payload format. Selected `--connector` files are
  parsed through `Wasm.Connector`; resolution and embedding remain later
  work. This unit wires the command contract around those stages so the
  CLI, `--target`, and `--connector` exist and fail with structured
  diagnostics rather than silently falling back to a `.waot` cache, the
  JIT, the interpreter, ambient discovery, or the network.

  It is a THIN driver over the shipped decode/validate path, adding no tier
  logic and never publishing output until every stage succeeds:

    1. Request check     — module path and `-o` are required; `--target`
                           defaults to the host and must be a released
                           compile target (or fail before decode).
    2. LoadModuleFromFile / LoadModule — decode + validate, keeping
                           EWasmDecodeError and EWasmValidationError
                           distinct.
    3. Connectors        — explicit `--connector` paths only. A selected
                           file that cannot be read, a duplicate path, or
                           malformed `.wlc` is EWasmConnectorError from
                           Wasm.Connector. Resolution is later work.
    4. Link              — deny-by-default: any import is an
                           EWasmLinkError until compiled WASI (#40) and
                           connector resolution (#42) exist.
    5. Strict compile    — all-or-fail native emission. Until #31 this
                           stage is EWasmCompileError.
    6. Packaging         — runtime-shell assembly. Until #34–#38 this
                           stage is EWasmPackagingError.
    7. Atomic write      — only after the stages above succeed; an I/O
                           failure is EStreamError and leaves no new
                           executable.

  Diagnostics are RETURNED (never printed here) so the CLI sends them to
  stderr and a test asserts on the class + message without a real
  process. }
unit Wasm.Compile;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  CLI.Options,
  Wasm.Core,
  Wasm.Engine;

const
  { Released 0.2.0 compile targets (ADR-0015, issue #30). Host-native
    selection is only the default, not a special emission path. }
  WASM_COMPILE_TARGET_AARCH64_DARWIN = 'aarch64-darwin';
  WASM_COMPILE_TARGET_X64_DARWIN = 'x86_64-darwin';
  WASM_COMPILE_TARGET_AARCH64_LINUX = 'aarch64-linux';
  WASM_COMPILE_TARGET_X64_LINUX = 'x86_64-linux';

  { Named follow-on targets: accepted as known, rejected as unreleased. }
  WASM_COMPILE_TARGET_X64_WIN64 = 'x86_64-win64';
  WASM_COMPILE_TARGET_I386_WIN32 = 'i386-win32';

type
  { A strict-compile decline: a function could not be compiled, or the
    all-or-fail AOT entry is not available yet. Not a trap and not a
    `.waot` decline record. Connector failures use Wasm.Connector's
    EWasmConnectorError — this unit does not redeclare it. }
  EWasmCompileError = class(EWasmError);

  { Runtime-shell / target-packaging failure, including an unreleased or
    unknown `--target`. Distinct from strict-compile so a missing shell is
    not reported as a declined function. }
  EWasmPackagingError = class(EWasmError);

  { Inputs the CLI maps onto the compile pipeline. Connectors are the
    explicit `--connector` paths in the order named; an empty Target means
    "use the host default". }
  TWasmCompileRequest = record
    ModulePath: string;
    OutputPath: string;
    Target: string;
    Connectors: array of string;
  end;

  { The outcome of a compile: the process exit code and a diagnostic the
    caller prints to stderr. Diagnostic is '' only on success. On failure
    it leads with the error class name when one applies, so hosts and tests
    can discriminate decode / validation / link / connector / compile /
    packaging / I/O without collapsing them. }
  TWasmCompileResult = record
    ExitCode: Integer;
    Diagnostic: string;
  end;

{ The host's compile-target name. This is the `--target` default, not a
  permission to emit host-only code. }
function CompileHostTarget: string;

{ True when ATarget is one of the four released 64-bit UNIX triples. }
function IsReleasedCompileTarget(const ATarget: string): Boolean;

{ True when ATarget is a named follow-on triple that is not released yet. }
function IsUnreleasedCompileTarget(const ATarget: string): Boolean;

{ Comma-separated released target names for help and diagnostics. }
function CompileReleasedTargetsHelp: string;

{ Registry-owned compile options: `--output`/`-o`, `--target`, repeatable
  `--connector`. The caller (the subcommand registry, or a test) owns the
  objects. }
function CreateCompileOptions(out AOutput, ATarget: TStringOption;
  out AConnector: TRepeatableOption): TOptionArray;

{ Map already-parsed positionals and the compile option objects onto a
  request. Does not read ParamStr. }
function CompileRequestFromOptions(const APositionals: TStringList;
  const AOptions: TOptionArray; out ARequest: TWasmCompileRequest;
  out AError: string): Boolean;

{ Decode + validate APath, then run the remaining compile stages against
  ARequest. Never writes ARequest.OutputPath unless every stage succeeds. }
function CompileConfiguredModule(
  const ARequest: TWasmCompileRequest): TWasmCompileResult;

{ Same pipeline from an in-memory module image — the hermetic path a test
  drives (assemble wat -> bytes, no module file). ARequest.OutputPath is
  still the would-be executable, and is left untouched on failure. }
function CompileModuleBytes(const ABytes: TWasmBytes;
  const ARequest: TWasmCompileRequest): TWasmCompileResult;

{ CLI entry: option objects + positionals -> compile result. }
function CompileFromOptions(const APositionals: TStringList;
  const AOptions: TOptionArray): TWasmCompileResult;

{ Atomic write of a successful compile. Writes APath + '.tmp' then renames
  onto APath; a failure deletes the temp and leaves any pre-existing APath
  unchanged. Exported so I/O failures can be tested without a successful
  compile. }
procedure WriteCompileOutput(const APath: string; const ABytes: TWasmBytes);

{ Runtime-shell packaging stub. Always raises EWasmPackagingError until
  the shell/payload work lands. }
procedure PackageCompilePayload(const ATarget: string);

implementation

uses
  Wasm.Connector,
  Wasm.Module,
  Wasm.Runtime.Traps;

const
  WASM_COMPILE_EXIT_ERROR = 1;

  RELEASED_TARGETS: array[0..3] of string = (
    WASM_COMPILE_TARGET_AARCH64_DARWIN,
    WASM_COMPILE_TARGET_X64_DARWIN,
    WASM_COMPILE_TARGET_AARCH64_LINUX,
    WASM_COMPILE_TARGET_X64_LINUX
  );

  UNRELEASED_TARGETS: array[0..1] of string = (
    WASM_COMPILE_TARGET_X64_WIN64,
    WASM_COMPILE_TARGET_I386_WIN32
  );

function CompileHostTarget: string;
var
  Arch, OsName: string;
begin
  {$IFDEF CPUAARCH64}
  Arch := 'aarch64';
  {$ELSE}
    {$IFDEF CPUX86_64}
    Arch := 'x86_64';
    {$ELSE}
      {$IF DEFINED(CPU386) OR DEFINED(CPUI386)}
      Arch := 'i386';
      {$ELSE}
      Arch := 'unknown';
      {$ENDIF}
    {$ENDIF}
  {$ENDIF}

  {$IFDEF DARWIN}
  OsName := 'darwin';
  {$ELSE}
    {$IFDEF LINUX}
    OsName := 'linux';
    {$ELSE}
      {$IFDEF WINDOWS}
      if Arch = 'x86_64' then
        OsName := 'win64'
      else if Arch = 'i386' then
        OsName := 'win32'
      else
        OsName := 'windows';
      {$ELSE}
      OsName := 'unknown';
      {$ENDIF}
    {$ENDIF}
  {$ENDIF}

  Result := Arch + '-' + OsName;
end;

function IsReleasedCompileTarget(const ATarget: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(RELEASED_TARGETS) do
    if ATarget = RELEASED_TARGETS[I] then
      Exit(True);
  Result := False;
end;

function IsUnreleasedCompileTarget(const ATarget: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(UNRELEASED_TARGETS) do
    if ATarget = UNRELEASED_TARGETS[I] then
      Exit(True);
  Result := False;
end;

function CompileReleasedTargetsHelp: string;
var
  I: Integer;
begin
  Result := RELEASED_TARGETS[0];
  for I := 1 to High(RELEASED_TARGETS) do
    Result := Result + ', ' + RELEASED_TARGETS[I];
end;

function FailResult(const AClassName, AMessage: string): TWasmCompileResult;
begin
  Result.ExitCode := WASM_COMPILE_EXIT_ERROR;
  if AClassName = '' then
    Result.Diagnostic := AMessage
  else
    Result.Diagnostic := AClassName + ': ' + AMessage;
end;

function FailException(const E: Exception): TWasmCompileResult;
begin
  Result := FailResult(E.ClassName, E.Message);
end;

function CreateCompileOptions(out AOutput, ATarget: TStringOption;
  out AConnector: TRepeatableOption): TOptionArray;
begin
  Result := nil;
  AOutput := TStringOption.Create('output',
    'write the native executable to this path (required)');
  AOutput.ShortName := 'o';

  ATarget := TStringOption.Create('target',
    'compile target (default: host); released: ' +
    CompileReleasedTargetsHelp);

  AConnector := TRepeatableOption.Create('connector',
    'select a .wlc connector (repeatable; no discovery)');

  SetLength(Result, 3);
  Result[0] := AOutput;
  Result[1] := ATarget;
  Result[2] := AConnector;
end;

function CompileRequestFromOptions(const APositionals: TStringList;
  const AOptions: TOptionArray; out ARequest: TWasmCompileRequest;
  out AError: string): Boolean;
var
  OutputOpt: TStringOption;
  TargetOpt: TStringOption;
  ConnectorOpt: TRepeatableOption;
  I: Integer;
begin
  ARequest.ModulePath := '';
  ARequest.OutputPath := '';
  ARequest.Target := '';
  ARequest.Connectors := nil;
  AError := '';

  if APositionals.Count < 1 then
  begin
    AError := 'expected <module.wasm>';
    Exit(False);
  end;
  if APositionals.Count > 1 then
  begin
    AError := 'unexpected argument: ' + APositionals[1];
    Exit(False);
  end;

  OutputOpt := TStringOption(AOptions[0]);
  TargetOpt := TStringOption(AOptions[1]);
  ConnectorOpt := TRepeatableOption(AOptions[2]);

  if (not OutputOpt.Present) or (OutputOpt.Value = '') then
  begin
    AError := 'expected -o <executable>';
    Exit(False);
  end;

  ARequest.ModulePath := APositionals[0];
  ARequest.OutputPath := OutputOpt.Value;
  if TargetOpt.Present then
    ARequest.Target := TargetOpt.Value;
  SetLength(ARequest.Connectors, ConnectorOpt.Values.Count);
  for I := 0 to ConnectorOpt.Values.Count - 1 do
    ARequest.Connectors[I] := ConnectorOpt.Values[I];
  Result := True;
end;

function ResolvedCompileTarget(const ARequested: string;
  out ATarget: string; out AError: TWasmCompileResult): Boolean;
begin
  if ARequested = '' then
    ATarget := CompileHostTarget
  else
    ATarget := ARequested;

  if IsReleasedCompileTarget(ATarget) then
    Exit(True);

  if IsUnreleasedCompileTarget(ATarget) or (ARequested = '') then
    AError := FailResult(EWasmPackagingError.ClassName,
      'compile target "' + ATarget + '" is not a released compile target')
  else
    AError := FailResult(EWasmPackagingError.ClassName,
      'unknown compile target "' + ATarget + '": valid targets are ' +
      CompileReleasedTargetsHelp);
  Result := False;
end;

function ReadConnectorSource(const APath: string): string;
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

procedure CheckConnectors(const AConnectors: array of string);
var
  I, J: Integer;
  Path: string;
begin
  for I := 0 to High(AConnectors) do
  begin
    Path := AConnectors[I];
    if Path = '' then
      raise EWasmConnectorError.Create('empty --connector path');
    for J := 0 to I - 1 do
      if SameFileName(Path, AConnectors[J]) then
        raise EWasmConnectorError.Create('duplicate --connector "' +
          Path + '"');
    if not FileExists(Path) then
      raise EWasmConnectorError.Create('cannot read connector "' +
        Path + '"');
    try
      { Parse for validity. Resolution and unused-declaration stripping
        belong to issue #42; the document is discarded here. }
      ParseConnector(ReadConnectorSource(Path));
    except
      on E: EWasmConnectorError do
        raise;
      on E: EStreamError do
        raise EWasmConnectorError.Create('cannot read connector "' +
          Path + '"');
    end;
  end;
end;

procedure CheckLink(const ALoaded: TWasmLoadedModule);
var
  Imp: TWasmImport;
begin
  if ALoaded.Model.ImportCount = 0 then
    Exit;
  Imp := ALoaded.Model.Imports[0];
  raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
    [string(MSG_LINK_UNKNOWN_IMPORT), Imp.ModuleName, Imp.Name]);
end;

procedure StrictCompileNative;
begin
  raise EWasmCompileError.Create('strict compile is not available');
end;

procedure PackageCompilePayload(const ATarget: string);
begin
  raise EWasmPackagingError.Create(
    'runtime shell packaging is not available for target "' + ATarget + '"');
end;

procedure WriteCompileOutput(const APath: string; const ABytes: TWasmBytes);
var
  TmpPath, BackupPath: string;
  Stream: TFileStream;
begin
  if DirectoryExists(APath) then
    raise EStreamError.Create('cannot write executable "' + APath +
      '": path is a directory');

  TmpPath := APath + '.tmp';
  BackupPath := APath + '.bak';
  Stream := TFileStream.Create(TmpPath, fmCreate);
  try
    try
      if Length(ABytes) > 0 then
        Stream.WriteBuffer(ABytes[0], Length(ABytes));
    finally
      Stream.Free;
    end;
    if FileExists(APath) then
    begin
      if FileExists(BackupPath) then
        DeleteFile(BackupPath);
      if not RenameFile(APath, BackupPath) then
        raise EStreamError.Create('cannot replace "' + APath + '"');
    end;
    if not RenameFile(TmpPath, APath) then
    begin
      if FileExists(BackupPath) then
        RenameFile(BackupPath, APath);
      raise EStreamError.Create('cannot publish executable "' + APath + '"');
    end;
    if FileExists(BackupPath) then
      DeleteFile(BackupPath);
  except
    if FileExists(TmpPath) then
      DeleteFile(TmpPath);
    raise;
  end;
end;

function CompileLoaded(const ALoaded: TWasmLoadedModule;
  const ARequest: TWasmCompileRequest): TWasmCompileResult;
var
  Target: string;
begin
  if not ResolvedCompileTarget(ARequest.Target, Target, Result) then
    Exit;

  try
    CheckConnectors(ARequest.Connectors);
    CheckLink(ALoaded);
    StrictCompileNative;
    PackageCompilePayload(Target);
    WriteCompileOutput(ARequest.OutputPath, nil);
    Result.ExitCode := 0;
    Result.Diagnostic := '';
  except
    on E: EWasmError do
      Result := FailException(E);
    on E: EStreamError do
      Result := FailException(E);
  end;
end;

function CompileConfiguredModule(
  const ARequest: TWasmCompileRequest): TWasmCompileResult;
var
  Loaded: TWasmLoadedModule;
  Target: string;
begin
  if ARequest.ModulePath = '' then
    Exit(FailResult('', 'expected <module.wasm>'));
  if ARequest.OutputPath = '' then
    Exit(FailResult('', 'expected -o <executable>'));
  if not ResolvedCompileTarget(ARequest.Target, Target, Result) then
    Exit;

  Loaded := nil;
  try
    try
      Loaded := LoadModuleFromFile(ARequest.ModulePath);
    except
      on E: EWasmError do
        Exit(FailException(E));
      on E: Exception do
        Exit(FailResult('internal error', E.ClassName + ': ' + E.Message));
    end;
    Result := CompileLoaded(Loaded, ARequest);
  finally
    Loaded.Free;
  end;
end;

function CompileModuleBytes(const ABytes: TWasmBytes;
  const ARequest: TWasmCompileRequest): TWasmCompileResult;
var
  Loaded: TWasmLoadedModule;
  Target: string;
begin
  if ARequest.OutputPath = '' then
    Exit(FailResult('', 'expected -o <executable>'));
  if not ResolvedCompileTarget(ARequest.Target, Target, Result) then
    Exit;

  Loaded := nil;
  try
    try
      Loaded := LoadModule(ABytes);
    except
      on E: EWasmError do
        Exit(FailException(E));
      on E: Exception do
        Exit(FailResult('internal error', E.ClassName + ': ' + E.Message));
    end;
    Result := CompileLoaded(Loaded, ARequest);
  finally
    Loaded.Free;
  end;
end;

function CompileFromOptions(const APositionals: TStringList;
  const AOptions: TOptionArray): TWasmCompileResult;
var
  Request: TWasmCompileRequest;
  Err: string;
begin
  if not CompileRequestFromOptions(APositionals, AOptions, Request, Err) then
    Exit(FailResult('', Err));
  Result := CompileConfiguredModule(Request);
end;

end.
