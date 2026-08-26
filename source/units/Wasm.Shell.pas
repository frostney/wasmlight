{ Wasm.Shell — the interpreter-free startup path for the runtime shell.

  Sequence:
    1. Locate the payload: an explicit `.wshl` attach file, bytes already
       in hand, or the ELF trailer / Mach-O `__WSHL,__payload` of this
       executable (ADR-0015 / ADR-0016).
    2. Parse the product native-executable payload (Wasm.Native.Payload)
       or, for the attach-seam tests, the temporary WSHL envelope.
    3. Re-decode and re-validate the embedded module (LoadModule). That
       fresh validation is the safety oracle, same as `run --aot`.
    4. Reject a non-empty connector plan or capability set — compiled
       WASI is deny-by-default (stdio + clock + random); connector host
       functions and compiled `--dir`/`--env` apply later.
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

{ Run a parsed-or-raw shell image against AConfig's deny-by-default WASI
  grants. AConfig is borrowed. Never raises a guest outcome: decode,
  validation, link, trap, exception, and proc_exit become a result. }
function RunShellBytes(const APayload: TWasmBytes;
  const AConfig: TWasmWasiConfig): TWasmShellResult;

{ Same, from an already-parsed image. }
function RunShellImage(const AImage: TWasmShellImage;
  const AConfig: TWasmWasiConfig): TWasmShellResult;

{ File path of the payload (the template attach seam, or a packaged
  ELF/Mach-O executable whose payload `wasmlight compile` attached). }
function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmShellResult;

{ Copy the attached native-executable payload out of a packaged ELF or
  Mach-O image. False when ABytes is not a packaged shell or the payload
  is empty (the unfilled template). }
function ExtractPackagedPayload(const ABytes: TWasmBytes;
  out APayload: TWasmBytes): Boolean;

{ Read APath and ExtractPackagedPayload. }
function ExtractPackagedPayloadFromFile(const APath: string;
  out APayload: TWasmBytes): Boolean;

implementation

type
  PWasmNativePayload = ^TWasmNativePayload;

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

function RunLoadedShellCore(const ALoaded: TWasmLoadedModule;
  const AConnector, ACapability: TWasmBytes;
  const AConfig: TWasmWasiConfig; const AWaot: TWasmBytes;
  const AWnep: PWasmNativePayload): TWasmShellResult;
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
begin
  Result.ExitCode := 0;
  Result.Diagnostic := '';
  Result.NativeStatus := '';

  if (AConfig = nil) or (ALoaded = nil) then
    Exit(FailResult('shell needs a module and a WASI config'));

  if Length(AConnector) > 0 then
    Exit(FailResult('EWasmLinkError: connector plan is not yet loadable'));
  if Length(ACapability) > 0 then
    Exit(FailResult('EWasmLinkError: compiled capability set is not yet loadable'));

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
  const AImage: TWasmShellImage;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
begin
  Result := RunLoadedShellCore(ALoaded, AImage.ConnectorPlan,
    AImage.CapabilitySet, AConfig, AImage.Native, nil);
end;

function RunShellImage(const AImage: TWasmShellImage;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
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
    Result := RunLoadedShell(Loaded, AImage, AConfig);
  finally
    Loaded.Free;
  end;
end;

function RunNativePayload(const APayload: TWasmNativePayload;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
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
      Payload.CapabilitySet, AConfig, nil, @Payload);
  finally
    Loaded.Free;
  end;
end;

function ExtractPackagedPayload(const ABytes: TWasmBytes;
  out APayload: TWasmBytes): Boolean;
var
  Elf: TWasmElfPackageInfo;
  Mach, Appended: TWasmBytes;
begin
  APayload := nil;
  Result := False;
  if ParseElfPackage(ABytes, Elf) = eprOk then
    APayload := Elf.Payload
  else if ExtractMachOPayload(ABytes, Mach) = mmrOk then
    APayload := Mach
  else if ParseAppendedPayload(ABytes, Appended) = eprOk then
    APayload := Appended
  else
    Exit;
  { An unfilled template may reserve `__WSHL,__payload` with a dummy byte.
    Only a WNEP or WSHL magic is a real attach. }
  if Length(APayload) < 4 then
  begin
    APayload := nil;
    Exit;
  end;
  if ((APayload[0] = WNEP_MAGIC0) and (APayload[1] = WNEP_MAGIC1) and
    (APayload[2] = WNEP_MAGIC2) and (APayload[3] = WNEP_MAGIC3)) or
    ((APayload[0] = WSHL_MAGIC0) and (APayload[1] = WSHL_MAGIC1) and
    (APayload[2] = WSHL_MAGIC2) and (APayload[3] = WSHL_MAGIC3)) then
    Result := True
  else
    APayload := nil;
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
  const AConfig: TWasmWasiConfig): TWasmShellResult;
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
    Exit(RunNativePayload(Wnep, AConfig));
  Parse := ParseShellPayload(APayload, Image);
  if Parse <> sprOk then
  begin
    if WnepParse <> nprBadMagic then
      Exit(FailResult(WnepParseFailText(WnepParse)));
    Exit(FailResult(ParseFailText(Parse)));
  end;
  Result := RunShellImage(Image, AConfig);
end;

function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
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
  if ExtractPackagedPayload(Bytes, Extracted) then
    Result := RunShellBytes(Extracted, AConfig)
  else
    Result := RunShellBytes(Bytes, AConfig);
end;

end.
