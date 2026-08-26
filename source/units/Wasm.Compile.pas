{ Wasm.Compile — the testable core of `wasmlight compile` (ADR-0015).

  `wasmlight compile <module.wasm> -o <executable>` is the native-application
  command: validate once, compile every guest function, and emit a complete
  interpreter-free executable. Selected `--connector` files are parsed through
  `Wasm.Connector` and resolved through `Wasm.Connector.Resolve`. WASI
  preview1 is a built-in of the runtime shell; other imports must resolve
  uniquely. Connector host functions are not yet embedded in the generated
  executable, so a resolved non-WASI import fails closed at link.

  It is a THIN driver over shipped stages, adding no tier logic and never
  publishing output until every stage succeeds:

    1. Request check     — module path and `-o` are required; `--target`
                           defaults to the host and must be a released
                           compile target (or fail before decode).
    2. LoadModuleFromFile / LoadModule — decode + validate, keeping
                           EWasmDecodeError and EWasmValidationError
                           distinct.
    3. Connectors        — explicit `--connector` paths only. A selected
                           file that cannot be read, a duplicate path, or
                           malformed `.wlc` is EWasmConnectorError.
    4. Link              — deny-by-default: `wasi_snapshot_preview1` is
                           granted; any other import is EWasmLinkError
                           unless a selected connector binds it uniquely.
    5. Strict compile    — AotCompileModuleStrict for the requested
                           target. A decline is EWasmCompileError.
    6. Packaging         — WriteNativePayload into a catalog (or host
                           sibling) runtime shell via ELF/Mach-O. A
                           missing or unusable shell is EWasmPackagingError.
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
  { A strict-compile decline: a function could not be compiled. Not a trap
    and not a `.waot` decline record. Connector failures use Wasm.Connector's
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
    { Empty means the catalog beside the compiler, then the host sibling
      `wasmlight-shell` for the host target. Tests inject a fixture root. }
    CatalogRoot: string;
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

{ Combine APayload with the selected runtime shell for ATarget. Raises
  EWasmPackagingError when the catalog/shell is missing or the packager
  refuses the template. AOutputPath supplies the Mach-O CodeDirectory
  ident (basename). }
function PackageCompilePayload(const ATarget: string;
  const APayload: TWasmBytes; const ACatalogRoot, AOutputPath: string):
  TWasmBytes;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Wasm.Aot,
  Wasm.Aot.Artifact,
  Wasm.Compile.Catalog,
  Wasm.Connector,
  Wasm.Connector.Resolve,
  Wasm.MachO,
  Wasm.Native.Payload,
  Wasm.Package.Elf,
  Wasm.Runtime.Store,
  Wasm.Target;

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
  ARequest.CatalogRoot := '';
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

procedure CheckConnectorsAndLink(const ALoaded: TWasmLoadedModule;
  const AConnectors: array of string);
var
  I, J: Integer;
  Path: string;
  Docs: array of TWlcDocument;
  Plan: TWlcConnectorPlan;
  BuiltIn: array[0..0] of string;
begin
  SetLength(Docs, Length(AConnectors));
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
      Docs[I] := ParseConnector(ReadConnectorSource(Path));
    except
      on E: EWasmConnectorError do
        raise;
      on E: EStreamError do
        raise EWasmConnectorError.Create('cannot read connector "' +
          Path + '"');
    end;
  end;
  BuiltIn[0] := WLC_WASI_MODULE;
  Plan := ResolveConnectorModule(Docs, ALoaded.Model, BuiltIn);
  if Length(Plan.Thunks) > 0 then
    raise EWasmLinkError.Create(
      'compiled executables grant WASI only; connector host functions are not embedded');
end;

function CompileWasmTarget(const ATriple: string;
  out ATarget: TWasmTarget): Boolean;
var
  Llvm: string;
begin
  if ATriple = WASM_COMPILE_TARGET_AARCH64_DARWIN then
    Llvm := WASM_TARGET_TRIPLE_AARCH64_DARWIN
  else if ATriple = WASM_COMPILE_TARGET_X64_DARWIN then
    Llvm := WASM_TARGET_TRIPLE_X86_64_DARWIN
  else if ATriple = WASM_COMPILE_TARGET_AARCH64_LINUX then
    Llvm := WASM_TARGET_TRIPLE_AARCH64_LINUX
  else if ATriple = WASM_COMPILE_TARGET_X64_LINUX then
    Llvm := WASM_TARGET_TRIPLE_X86_64_LINUX
  else
    Llvm := '';
  Result := (Llvm <> '') and WasmTargetParse(Llvm, ATarget);
end;

function ReadAllBytes(const APath: string): TWasmBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function LoadCompileTemplate(const ATarget, ACatalogRoot: string): TWasmBytes;
var
  Root, Sibling: string;
  Entry: TWasmShellEntry;
  Sel: TWasmShellSelectResult;
begin
  Root := ACatalogRoot;
  if Root = '' then
    Root := CompilerCatalogRoot(ParamStr(0));
  Sel := ResolveShell(Root, ATarget, Entry);
  if Sel = ssrOk then
    Exit(ReadAllBytes(Entry.ShellPath));
  if (ACatalogRoot = '') and (ATarget = CompileHostTarget) then
  begin
    Sibling := IncludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0))) +
      'wasmlight-shell';
    if FileExists(Sibling) then
      Exit(ReadAllBytes(Sibling));
  end;
  raise EWasmPackagingError.Create(FormatSelectError(Sel, ATarget));
end;

function CopyLoadedBytes(const ALoaded: TWasmLoadedModule): TWasmBytes;
begin
  Result := nil;
  if ALoaded.BytesLength = 0 then
    Exit;
  SetLength(Result, ALoaded.BytesLength);
  Move(ALoaded.BytesPtr^, Result[0], ALoaded.BytesLength);
end;

function WaotToWnepHash(const AHash: TWasmAotHash128): TWasmNativeHash128;
begin
  Result.Lo := AHash.Lo;
  Result.Hi := AHash.Hi;
end;

function NativePayloadFromArtifact(const ALoaded: TWasmLoadedModule;
  const AArtifact, ATemplate: TWasmBytes;
  const ATarget: string): TWasmBytes;
var
  Parsed: TWasmAotArtifact;
  Params: TWasmNativePayloadWriteParams;
  Funcs: TWasmNativeCodeRecords;
  I: Integer;
begin
  if ParseAotArtifact(AArtifact, Parsed) <> aprOk then
    raise EWasmCompileError.Create('strict compile produced a malformed image');
  SetLength(Funcs, Length(Parsed.Funcs));
  for I := 0 to High(Parsed.Funcs) do
  begin
    if not Parsed.Funcs[I].Compiled then
      raise EWasmCompileError.CreateFmt('aot: function %d declined: incomplete',
        [Parsed.Funcs[I].FuncIrIndex]);
    Funcs[I].FuncIrIndex := Parsed.Funcs[I].FuncIrIndex;
    Funcs[I].RegisterCount := Parsed.Funcs[I].RegisterCount;
    Funcs[I].EntryOffset := Parsed.Funcs[I].EntryOffset;
    Funcs[I].Code := Parsed.Funcs[I].Code;
  end;
  Params.IrFormatVer := Parsed.Header.IrFormatVer;
  if (ATarget = WASM_COMPILE_TARGET_AARCH64_DARWIN) or
    (ATarget = WASM_COMPILE_TARGET_AARCH64_LINUX) then
    Params.TargetArch := WNEP_ARCH_AARCH64
  else
    Params.TargetArch := WNEP_ARCH_X64;
  if (ATarget = WASM_COMPILE_TARGET_AARCH64_LINUX) or
    (ATarget = WASM_COMPILE_TARGET_X64_LINUX) then
    Params.TargetOs := WNEP_OS_LINUX
  else
    Params.TargetOs := WNEP_OS_DARWIN;
  Params.Flags := 0;
  Params.AbiFingerprint := Parsed.Header.AbiFingerprint;
  Params.ModuleHash := WaotToWnepHash(Parsed.Header.ModuleHash);
  Params.ShellHash := WnepHash128Bytes(ATemplate);
  Params.ModuleBytes := CopyLoadedBytes(ALoaded);
  Params.Funcs := Funcs;
  Params.ConnectorPlan := nil;
  Params.CapabilitySet := nil;
  Result := WriteNativePayload(Params);
end;

function StrictCompileNative(const ALoaded: TWasmLoadedModule;
  const ATarget: string): TWasmBytes;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  WasmT: TWasmTarget;
begin
  if not CompileWasmTarget(ATarget, WasmT) then
    raise EWasmPackagingError.Create('unknown compile target "' + ATarget + '"');
  Engine := TWasmEngine.Create;
  Store := TWasmStore.Create(Engine);
  try
    try
      Result := AotCompileModuleStrict(Store, ALoaded, WasmT);
    except
      on E: EWasmAotError do
        raise EWasmCompileError.Create(E.Message);
    end;
  finally
    Store.Free;
    Engine.Free;
  end;
end;

function ElfPackageFailText(const ARes: TWasmElfPackageResult): string;
begin
  case ARes of
    eprBadTemplate: Result := 'template is not a usable ELF';
    eprWrongMachine: Result := 'ELF template target mismatch';
    eprMalformed: Result := 'malformed ELF template';
    eprAlreadyPackaged: Result := 'ELF template is already packaged';
    eprBadMagic: Result := 'ELF template has no payload trailer';
    eprBadVersion: Result := 'unsupported ELF payload trailer';
    eprBadChecksum: Result := 'ELF payload checksum mismatch';
    eprTruncated: Result := 'truncated ELF template';
  else
    Result := 'ELF packaging failed';
  end;
end;

function MachOPackageFailText(const ARes: TWasmMachOResult): string;
begin
  case ARes of
    mmrEmpty: Result := 'empty Mach-O template';
    mmrNotMachO: Result := 'template is not Mach-O';
    mmrUnsupported: Result := 'unsupported Mach-O template';
    mmrTruncated: Result := 'truncated Mach-O template';
    mmrMalformed: Result := 'malformed Mach-O template';
    mmrNoHeaderSlack: Result := 'Mach-O template has no header slack for payload';
    mmrPayloadMissing: Result := 'Mach-O template has no payload section';
    mmrSignatureInvalid: Result := 'Mach-O ad-hoc signature is invalid';
  else
    Result := 'Mach-O packaging failed';
  end;
end;

function PackageCompilePayload(const ATarget: string;
  const APayload: TWasmBytes; const ACatalogRoot, AOutputPath: string):
  TWasmBytes;
var
  Template: TWasmBytes;
  Packaged: TWasmBytes;
  ElfTarget: TWasmElfPackageTarget;
  ElfRes: TWasmElfPackageResult;
  MachRes: TWasmMachOResult;
  Ident: string;
begin
  Template := LoadCompileTemplate(ATarget, ACatalogRoot);
  if (ATarget = WASM_COMPILE_TARGET_AARCH64_LINUX) or
    (ATarget = WASM_COMPILE_TARGET_X64_LINUX) then
  begin
    if ATarget = WASM_COMPILE_TARGET_AARCH64_LINUX then
      ElfTarget := weptAarch64Linux
    else
      ElfTarget := weptX86_64Linux;
    ElfRes := PackageElfShell(Template, APayload, ElfTarget, Packaged);
    if ElfRes <> eprOk then
      raise EWasmPackagingError.Create(
        'runtime shell packaging failed for target "' + ATarget + '": ' +
        ElfPackageFailText(ElfRes));
    Result := Packaged;
    Exit;
  end;
  Ident := ExtractFileName(AOutputPath);
  if Ident = '' then
    Ident := MACHO_DEFAULT_IDENT;
  MachRes := PackageMachORuntimeShell(Template, APayload, Ident, Packaged);
  if MachRes = mmrNoHeaderSlack then
  begin
    if PackageAppendedPayload(Template, APayload, Packaged) <> eprOk then
      raise EWasmPackagingError.Create(
        'runtime shell packaging failed for target "' + ATarget +
        '": cannot append payload to Mach-O template');
    Result := Packaged;
    Exit;
  end;
  if MachRes <> mmrOk then
    raise EWasmPackagingError.Create(
      'runtime shell packaging failed for target "' + ATarget + '": ' +
      MachOPackageFailText(MachRes));
  Result := Packaged;
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
  {$IFDEF UNIX}
  if FpChmod(APath, &755) <> 0 then
    raise EStreamError.Create('cannot mark executable "' + APath + '"');
  {$ENDIF}
end;

function CompileLoaded(const ALoaded: TWasmLoadedModule;
  const ARequest: TWasmCompileRequest): TWasmCompileResult;
var
  Target: string;
  Artifact, Template, Payload, Packaged: TWasmBytes;
begin
  if not ResolvedCompileTarget(ARequest.Target, Target, Result) then
    Exit;

  try
    CheckConnectorsAndLink(ALoaded, ARequest.Connectors);
    Artifact := StrictCompileNative(ALoaded, Target);
    Template := LoadCompileTemplate(Target, ARequest.CatalogRoot);
    Payload := NativePayloadFromArtifact(ALoaded, Artifact, Template, Target);
    Packaged := PackageCompilePayload(Target, Payload, ARequest.CatalogRoot,
      ARequest.OutputPath);
    WriteCompileOutput(ARequest.OutputPath, Packaged);
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
