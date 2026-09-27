{ Wasm.Shell — the interpreter-free startup path for the runtime shell.

  Sequence:
    1. Locate the payload: an explicit `.wshl` attach file, bytes already
       in hand, or the ELF trailer / Mach-O `__WSHL,__payload` of this
       executable (ADR-0015 / ADR-0016).
    2. Parse the product native-executable payload (Wasm.Native.Payload)
       or, for the attach-seam tests, the temporary WSHL envelope.
    3. Re-decode and re-validate the embedded module (LoadModule). That
       fresh validation is the safety oracle, same as `run --aot`.
    4. Reject a non-empty connector plan; connector host functions apply
       later. Strictly decode the compiled capability set
       (Wasm.Compile.Capabilities) and apply exactly it to the config:
       compiled preopens (relative hosts from the executable directory),
       compiled env, and argv = executable basename + every invocation
       argument. An empty set is deny-by-default WASI (stdio + clock +
       random). The set cannot be widened: apply refuses a config that
       already carries preopens or env.
    5. Link deny-by-default WASI, instantiate, and require exported
       memory + `_start`.
    6. Wire ONLY a complete native image (Wasm.Native). Incomplete or
       incompatible code is EWasmLinkError; there is no interpreter
       fallback.
    7. Run the module start function (if any) and `_start` through
       NativeInvoke.

  This unit is the testable core of `wasmlight-shell`. The program adds
  only process argv, real stdio, and payload location. }
unit Wasm.Shell;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  Wasm.Core,
  Wasm.Engine,
  Wasm.MachO,
  Wasm.Native,
  Wasm.Native.Payload,
  Wasm.Package.Elf,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Shell.Payload,
  Wasm.Wasi;

const
  WASM_SHELL_EXIT_TRAP = 134;
  WASM_SHELL_EXIT_ERROR = 1;

type
  { How this run was invoked: the running executable (relative compiled
    preopens resolve from its directory; its basename is the guest argv[0])
    and every invocation argument after it, all of which belong to the
    guest. }
  TWasmShellInvocation = record
    ExecutablePath: string;
    Args: TArray<string>;
  end;

  { Outcome of a shell run. Diagnostic is empty on a clean exit or a plain
    proc_exit. NativeStatus names the load result for tests. }
  TWasmShellResult = record
    ExitCode: Integer;
    Diagnostic: string;
    NativeStatus: string;
  end;

  { Real-OS stdio for the template program. Tests inject capture buffers
    through TWasmWasiConfig instead and never construct these. }
  TWasmShellOsOutStream = class(TWasmWasiStream)
  private
    FHandle: THandle;
  public
    constructor Create(const AHandle: THandle);
    function WriteBytes(const ABuf: PByte;
      const ALen: NativeUInt): NativeUInt; override;
    function ReadBytes(const ABuf: PByte;
      const AMax: NativeUInt): NativeUInt; override;
  end;

  TWasmShellOsInStream = class(TWasmWasiStream)
  private
    FHandle: THandle;
  public
    constructor Create(const AHandle: THandle);
    function WriteBytes(const ABuf: PByte;
      const ALen: NativeUInt): NativeUInt; override;
    function ReadBytes(const ABuf: PByte;
      const AMax: NativeUInt): NativeUInt; override;
  end;

{ Build an invocation record. }
function ShellInvocation(const AExecutablePath: string;
  const AArgs: array of string): TWasmShellInvocation;

{ The absolute, symlink-resolved path of the running executable, asked of
  the OS rather than taken from argv[0]: relative compiled preopens resolve
  from its directory whether the program was started by path, through a
  symlink, or by a PATH lookup. Linux reads /proc/self/exe; Darwin uses
  _NSGetExecutablePath + realpath; elsewhere ExpandFileName(ParamStr(0)). }
function ShellExecutablePath: string;

{ Run a parsed-or-raw shell image. The embedded compiled capability set and
  AInvocation's argv are applied to AConfig, which must carry no preopens or
  env of its own. AConfig is borrowed. Never raises a guest outcome: decode,
  validation, link, trap, exception, and proc_exit become a result. }
function RunShellBytes(const APayload: TWasmBytes;
  const AConfig: TWasmWasiConfig;
  const AInvocation: TWasmShellInvocation): TWasmShellResult; overload;

{ Same, invoked as this process's executable with no guest arguments. }
function RunShellBytes(const APayload: TWasmBytes;
  const AConfig: TWasmWasiConfig): TWasmShellResult; overload;

{ Same, from an already-parsed image, invoked as this process's executable
  with no guest arguments. }
function RunShellImage(const AImage: TWasmShellImage;
  const AConfig: TWasmWasiConfig): TWasmShellResult;

{ File path of the payload (the template attach seam, or a packaged
  ELF/Mach-O executable whose payload `wasmlight compile` attached). }
function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig;
  const AInvocation: TWasmShellInvocation): TWasmShellResult; overload;

{ Same, invoked as this process's executable with no guest arguments. }
function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmShellResult; overload;

{ Copy the attached native-executable payload out of a packaged ELF or
  Mach-O image. False when ABytes is not a packaged shell or the payload
  is empty (the unfilled template). A recognized but damaged container
  raises EWasmDecodeError instead of reopening the attach seam. }
function ExtractPackagedPayload(const ABytes: TWasmBytes;
  out APayload: TWasmBytes): Boolean;

{ Read APath and ExtractPackagedPayload. }
function ExtractPackagedPayloadFromFile(const APath: string;
  out APayload: TWasmBytes): Boolean;

implementation

uses
  {$IFDEF LINUX}
  BaseUnix,
  {$ENDIF}
  Wasm.Compile.Capabilities;

type
  PWasmNativePayload = ^TWasmNativePayload;

{$IFDEF DARWIN}
{ FPC 3.2.2 on Darwin returns raw argv[0] from ParamStr(0) (a bare name
  after a PATH lookup), so ask dyld and libc instead. Both live in
  libSystem, which every Darwin program already links. }
function NSGetExecutablePath(ABuf: PAnsiChar; var ASize: UInt32): LongInt;
  cdecl; external 'c' name '_NSGetExecutablePath';
function CRealPath(APath, AResolved: PAnsiChar): PAnsiChar;
  cdecl; external 'c' name 'realpath';
{$ENDIF}

function ShellExecutablePath: string;
{$IFDEF DARWIN}
var
  Size: UInt32;
  Raw: AnsiString;
  Resolved: array[0..4095] of AnsiChar;
{$ENDIF}
begin
  Result := '';
  {$IFDEF LINUX}
  { fpReadLink returns an unbounded AnsiString; ParamStr(0) is the same
    link read into a 255-byte shortstring. }
  Result := fpReadLink('/proc/self/exe');
  {$ENDIF}
  {$IFDEF DARWIN}
  Size := 0;
  SetLength(Raw, 1);
  NSGetExecutablePath(PAnsiChar(Raw), Size);
  if Size > 0 then
  begin
    SetLength(Raw, Size);
    if NSGetExecutablePath(PAnsiChar(Raw), Size) = 0 then
    begin
      if CRealPath(PAnsiChar(Raw), @Resolved[0]) <> nil then
        Result := StrPas(PAnsiChar(@Resolved[0]))
      else
        Result := StrPas(PAnsiChar(Raw));
    end;
  end;
  {$ENDIF}
  if Result = '' then
    Result := ParamStr(0);
  Result := ExpandFileName(Result);
end;

constructor TWasmShellOsOutStream.Create(const AHandle: THandle);
begin
  inherited Create;
  FHandle := AHandle;
end;

function TWasmShellOsOutStream.WriteBytes(const ABuf: PByte;
  const ALen: NativeUInt): NativeUInt;
var
  Wrote: Int64;
begin
  if ALen = 0 then
    Exit(0);
  Wrote := FileWrite(FHandle, ABuf^, LongInt(ALen));
  if Wrote < 0 then
    Result := 0
  else
    Result := NativeUInt(Wrote);
end;

function TWasmShellOsOutStream.ReadBytes(const ABuf: PByte;
  const AMax: NativeUInt): NativeUInt;
begin
  Result := 0;
  if AMax = 0 then;
end;

constructor TWasmShellOsInStream.Create(const AHandle: THandle);
begin
  inherited Create;
  FHandle := AHandle;
end;

function TWasmShellOsInStream.WriteBytes(const ABuf: PByte;
  const ALen: NativeUInt): NativeUInt;
begin
  Result := 0;
  if ALen = 0 then;
end;

function TWasmShellOsInStream.ReadBytes(const ABuf: PByte;
  const AMax: NativeUInt): NativeUInt;
var
  Got: Int64;
begin
  if AMax = 0 then
    Exit(0);
  Got := FileRead(FHandle, ABuf^, LongInt(AMax));
  if Got < 0 then
    Result := 0
  else
    Result := NativeUInt(Got);
end;

function FailResult(const ADiagnostic: string): TWasmShellResult;
begin
  Result.ExitCode := WASM_SHELL_EXIT_ERROR;
  Result.Diagnostic := ADiagnostic;
  Result.NativeStatus := '';
end;

function ParseFailText(const AParse: TWasmShellParseResult): string;
begin
  case AParse of
    sprEmpty: Result := 'runtime shell has no embedded module';
    sprBadMagic: Result := 'malformed shell payload: bad magic';
    sprBadFormatVer: Result := 'malformed shell payload: unsupported version';
    sprTruncated: Result := 'malformed shell payload: truncated';
    sprOverflow: Result := 'malformed shell payload: section length overflow';
  else
    Result := 'malformed shell payload';
  end;
end;

function WnepParseFailText(const AParse: TWasmNativePayloadParseResult): string;
begin
  case AParse of
    nprBadMagic: Result := 'malformed native payload: bad magic';
    nprIncompatibleVersion: Result := 'malformed native payload: unsupported version';
    nprTruncated: Result := 'malformed native payload: truncated';
    nprOverflow: Result := 'malformed native payload: section length overflow';
    nprBadChecksum: Result := 'malformed native payload: bad checksum';
    nprDuplicate: Result := 'malformed native payload: duplicate section';
    nprMissingRequired: Result := 'malformed native payload: missing required section';
    nprOverlap: Result := 'malformed native payload: overlapping sections';
    nprBadSectionHash: Result := 'malformed native payload: bad section hash';
    nprIdentityMismatch: Result := 'malformed native payload: module hash mismatch';
    nprUnknownSection: Result := 'malformed native payload: unknown section';
    nprMalformed: Result := 'malformed native payload';
  else
    Result := 'malformed native payload';
  end;
end;

function IsReactor(const AInstance: TWasmInstance): Boolean;
var
  Fn: TWasmFunc;
begin
  Result := AInstance.FindExportFunc('_initialize', Fn);
end;

function ShellInvocation(const AExecutablePath: string;
  const AArgs: array of string): TWasmShellInvocation;
var
  I: Integer;
begin
  Result.ExecutablePath := AExecutablePath;
  Result.Args := nil;
  SetLength(Result.Args, Length(AArgs));
  for I := 0 to High(AArgs) do
    Result.Args[I] := AArgs[I];
end;

function SelfInvocation: TWasmShellInvocation;
begin
  Result := ShellInvocation(ShellExecutablePath, []);
end;

{ Decode the embedded capability set and install exactly it, plus the
  invocation's argv, on AConfig. False with a diagnostic otherwise. }
function ApplyShellCapabilities(const ACapability: TWasmBytes;
  const AConfig: TWasmWasiConfig; const AInvocation: TWasmShellInvocation;
  out ADiagnostic: string): Boolean;
var
  Caps: TWasmCompiledCapabilities;
  Err: string;
begin
  ADiagnostic := '';
  if not TryDecodeCompiledCapabilities(ACapability, Caps, Err) then
  begin
    ADiagnostic := 'malformed capability set: ' + Err;
    Exit(False);
  end;
  try
    Result := Caps.ApplyToConfig(AConfig, AInvocation.ExecutablePath,
      AInvocation.Args, Err);
    if not Result then
      ADiagnostic := 'EWasmLinkError: ' + Err;
  finally
    Caps.Free;
  end;
end;

function RunLoadedShellCore(const ALoaded: TWasmLoadedModule;
  const AConnector, ACapability: TWasmBytes;
  const AConfig: TWasmWasiConfig; const AInvocation: TWasmShellInvocation;
  const AWaot: TWasmBytes; const AWnep: PWasmNativePayload): TWasmShellResult;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  Linker: TWasmLinker;
  Context: TWasmWasiContext;
  Instance: TWasmInstance;
  Native: TWasmNativeContext;
  LoadRes: TWasmNativeLoadResult;
  Mem: TWasmMemoryRef;
  StartFn: TWasmFunc;
  Imports: TWasmImports;
  Inst: TWasmModuleInstance;
  CapDiagnostic: string;
begin
  Result.ExitCode := 0;
  Result.Diagnostic := '';
  Result.NativeStatus := '';

  if (AConfig = nil) or (ALoaded = nil) then
    Exit(FailResult('shell needs a module and a WASI config'));

  if Length(AConnector) > 0 then
    Exit(FailResult('EWasmLinkError: connector plan is not yet loadable'));
  if not ApplyShellCapabilities(ACapability, AConfig, AInvocation,
    CapDiagnostic) then
    Exit(FailResult(CapDiagnostic));

  Engine := nil;
  Store := nil;
  Linker := nil;
  Context := nil;
  Instance := nil;
  Native := nil;
  try
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Context := TWasmWasiContext.Create(AConfig);
    Linker := TWasmLinker.Create(Store);
    WasiDefineAll(Linker, Context);

    try
      WasiCheckCommandEntry(ALoaded);
      Imports := Linker.ResolveImports(ALoaded);
      Inst := InstantiateModule(Store, ALoaded.Ir, ALoaded.BytesPtr,
        ALoaded.BytesLength, Imports);
      Instance := TWasmInstance.Create(Store, Inst);
    except
      on E: EWasmError do
        Exit(FailResult(E.ClassName + ': ' + E.Message));
    end;

    if not Instance.FindExportMemory('memory', Mem) then
      Exit(FailResult(
        'not a command module: no exported "memory" (a WASI command must '
        + 'export "memory")'));
    Context.SetMemory(Mem);

    if not Instance.FindExportFunc('_start', StartFn) then
    begin
      if IsReactor(Instance) then
        Exit(FailResult(
          'not a command module: exports "_initialize" but no "_start" '
          + '(reactor modules are out of scope for the runtime shell)'))
      else
        Exit(FailResult('not a command module: no "_start" export'));
    end;

    if AWnep <> nil then
      Native := NativeLoadCompletePayload(Store, ALoaded, Instance.Raw,
        AWnep^, LoadRes)
    else
      Native := NativeLoadComplete(Store, ALoaded, Instance.Raw, AWaot,
        LoadRes);
    Result.NativeStatus := NativeLoadResultText(LoadRes);
    if Native = nil then
      Exit(FailResult('EWasmLinkError: ' + NativeLoadResultText(LoadRes)));

    try
      if Inst.HasPendingStart then
        NativeInvoke(Store, Inst.FuncAddrs[Inst.PendingStartFuncIndex], nil, nil);
      Inst.HasPendingStart := False;
      NativeInvoke(StartFn.Store, StartFn.Addr, nil, nil);
      Result.ExitCode := 0;
    except
      on E: EWasmExit do
        Result.ExitCode := E.ExitCode and $FF;
      on E: EWasmTrap do
      begin
        Result.ExitCode := WASM_SHELL_EXIT_TRAP;
        Result.Diagnostic := 'trap: ' + E.Message;
      end;
      on E: EWasmException do
      begin
        Result.ExitCode := WASM_SHELL_EXIT_ERROR;
        Result.Diagnostic := 'uncaught exception: ' + E.Message;
      end;
      on E: EWasmError do
      begin
        Result.ExitCode := WASM_SHELL_EXIT_ERROR;
        Result.Diagnostic := E.ClassName + ': ' + E.Message;
      end;
      on E: Exception do
      begin
        Result.ExitCode := WASM_SHELL_EXIT_ERROR;
        Result.Diagnostic := 'internal error: ' + E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    Instance.Free;
    Native.Free;
    Context.Free;
    Linker.Free;
    FreeAndNil(Store);
    Engine.Free;
  end;
end;

function RunLoadedShell(const ALoaded: TWasmLoadedModule;
  const AImage: TWasmShellImage; const AConfig: TWasmWasiConfig;
  const AInvocation: TWasmShellInvocation): TWasmShellResult;
begin
  Result := RunLoadedShellCore(ALoaded, AImage.ConnectorPlan,
    AImage.CapabilitySet, AConfig, AInvocation, AImage.Native, nil);
end;

function RunShellImageAs(const AImage: TWasmShellImage;
  const AConfig: TWasmWasiConfig;
  const AInvocation: TWasmShellInvocation): TWasmShellResult;
var
  Loaded: TWasmLoadedModule;
begin
  Loaded := nil;
  try
    Loaded := LoadModule(AImage.Module);
  except
    on E: EWasmError do
      Exit(FailResult(E.ClassName + ': ' + E.Message));
  end;
  try
    Result := RunLoadedShell(Loaded, AImage, AConfig, AInvocation);
  finally
    Loaded.Free;
  end;
end;

function RunShellImage(const AImage: TWasmShellImage;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
begin
  Result := RunShellImageAs(AImage, AConfig, SelfInvocation);
end;

function RunNativePayload(const APayload: TWasmNativePayload;
  const AConfig: TWasmWasiConfig;
  const AInvocation: TWasmShellInvocation): TWasmShellResult;
var
  Loaded: TWasmLoadedModule;
  Payload: TWasmNativePayload;
begin
  Payload := APayload;
  Loaded := nil;
  try
    Loaded := LoadModule(Payload.ModuleBytes);
  except
    on E: EWasmError do
      Exit(FailResult(E.ClassName + ': ' + E.Message));
  end;
  try
    Result := RunLoadedShellCore(Loaded, Payload.ConnectorPlan,
      Payload.CapabilitySet, AConfig, AInvocation, nil, @Payload);
  finally
    Loaded.Free;
  end;
end;

function ExtractPackagedPayload(const ABytes: TWasmBytes;
  out APayload: TWasmBytes): Boolean;
var
  Elf: TWasmElfPackageInfo;
  Mach, Appended: TWasmBytes;
  MachRes: TWasmMachOResult;
begin
  APayload := nil;
  Result := False;
  if HasPayloadTrailer(ABytes) then
  begin
    if ParseElfPackage(ABytes, Elf) = eprOk then
      APayload := Elf.Payload
    else if ParseAppendedPayload(ABytes, Appended) = eprOk then
      APayload := Appended
    else
      raise EWasmDecodeError.Create('malformed embedded payload trailer');
  end
  else
  begin
    MachRes := ExtractMachOPayload(ABytes, Mach);
    if MachRes = mmrOk then
      APayload := Mach
    else if MachRes in [mmrMalformed, mmrTruncated, mmrSignatureInvalid] then
      raise EWasmDecodeError.Create('malformed embedded Mach-O payload')
    else
      Exit;
  end;
  { An unfilled template may reserve `__WSHL,__payload` with a dummy byte.
    Only a WNEP or WSHL magic is a real attach. }
  if Length(APayload) < 4 then
  begin
    if HasPayloadTrailer(ABytes) then
      raise EWasmDecodeError.Create('truncated embedded payload');
    APayload := nil;
    Exit;
  end;
  if ((APayload[0] = WNEP_MAGIC0) and (APayload[1] = WNEP_MAGIC1) and
    (APayload[2] = WNEP_MAGIC2) and (APayload[3] = WNEP_MAGIC3)) or
    ((APayload[0] = WSHL_MAGIC0) and (APayload[1] = WSHL_MAGIC1) and
    (APayload[2] = WSHL_MAGIC2) and (APayload[3] = WSHL_MAGIC3)) then
    Result := True
  else
    raise EWasmDecodeError.Create('malformed embedded payload magic');
end;

function ExtractPackagedPayloadFromFile(const APath: string;
  out APayload: TWasmBytes): Boolean;
var
  Stream: TFileStream;
  Bytes: TWasmBytes;
begin
  APayload := nil;
  Result := False;
  if not FileExists(APath) then
    Exit;
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Bytes, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Bytes[0], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;
  Result := ExtractPackagedPayload(Bytes, APayload);
end;

function RunShellBytes(const APayload: TWasmBytes;
  const AConfig: TWasmWasiConfig;
  const AInvocation: TWasmShellInvocation): TWasmShellResult;
var
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
  Wnep: TWasmNativePayload;
  WnepParse: TWasmNativePayloadParseResult;
begin
  if Length(APayload) = 0 then
    Exit(FailResult('runtime shell has no embedded module'));
  WnepParse := ParseNativePayload(APayload, Wnep);
  if WnepParse = nprOk then
    Exit(RunNativePayload(Wnep, AConfig, AInvocation));
  Parse := ParseShellPayload(APayload, Image);
  if Parse <> sprOk then
  begin
    if WnepParse <> nprBadMagic then
      Exit(FailResult(WnepParseFailText(WnepParse)));
    Exit(FailResult(ParseFailText(Parse)));
  end;
  Result := RunShellImageAs(Image, AConfig, AInvocation);
end;

function RunShellBytes(const APayload: TWasmBytes;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
begin
  Result := RunShellBytes(APayload, AConfig, SelfInvocation);
end;

function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
begin
  Result := RunShellFile(APath, AConfig, SelfInvocation);
end;

function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig;
  const AInvocation: TWasmShellInvocation): TWasmShellResult;
var
  Stream: TFileStream;
  Bytes, Extracted: TWasmBytes;
begin
  Bytes := nil;
  if not FileExists(APath) then
    Exit(FailResult('EWasmDecodeError: shell payload file not found'));
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Bytes, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Bytes[0], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      Exit(FailResult('EWasmDecodeError: ' + E.Message));
  end;
  try
    if ExtractPackagedPayload(Bytes, Extracted) then
      Result := RunShellBytes(Extracted, AConfig, AInvocation)
    else
      Result := RunShellBytes(Bytes, AConfig, AInvocation);
  except
    on E: EWasmDecodeError do
      Result := FailResult(E.ClassName + ': ' + E.Message);
  end;
end;

end.
