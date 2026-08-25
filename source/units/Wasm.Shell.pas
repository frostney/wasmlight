{ Wasm.Shell — the interpreter-free startup path for the runtime shell.

  Sequence:
    1. Parse the attach/embed envelope (Wasm.Shell.Payload).
    2. Re-decode and re-validate the embedded module (LoadModule). That
       fresh validation is the safety oracle, same as `run --aot`.
    3. Reject a non-empty connector plan or capability set — those values
       belong to later issues (#40, #41+); the stub is "empty means
       deny-by-default WASI, no extra imports".
    4. Link deny-by-default WASI, instantiate, and require exported
       memory + `_start`.
    5. Wire ONLY a complete native image (Wasm.Native). Incomplete or
       incompatible code is EWasmLinkError; there is no interpreter
       fallback.
    6. Run the module start function (if any) and `_start` through
       NativeInvoke.

  This unit is the testable core of `wasmlight-shell`. The program adds
  only process argv, real stdio, and payload location. `wasmlight compile`
  (#39) and ELF/Mach-O packaging (#36/#37) are not implemented here. }
unit Wasm.Shell;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  Wasm.Core,
  Wasm.Engine,
  Wasm.Native,
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

{ File path of the payload (the template attach seam until #36/#37 embed
  the image in the executable). }
function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmShellResult;

implementation

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

function IsReactor(const AInstance: TWasmInstance): Boolean;
var
  Fn: TWasmFunc;
begin
  Result := AInstance.FindExportFunc('_initialize', Fn);
end;

function RunLoadedShell(const ALoaded: TWasmLoadedModule;
  const AImage: TWasmShellImage;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
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

  if Length(AImage.ConnectorPlan) > 0 then
    Exit(FailResult('EWasmLinkError: connector plan is not yet loadable'));
  if Length(AImage.CapabilitySet) > 0 then
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

    Native := NativeLoadComplete(Store, ALoaded, Instance.Raw, AImage.Native,
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

function RunShellBytes(const APayload: TWasmBytes;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
var
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  Parse := ParseShellPayload(APayload, Image);
  if Parse <> sprOk then
    Exit(FailResult(ParseFailText(Parse)));
  Result := RunShellImage(Image, AConfig);
end;

function RunShellFile(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmShellResult;
var
  Stream: TFileStream;
  Bytes: TWasmBytes;
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
  Result := RunShellBytes(Bytes, AConfig);
end;

end.
