{ Wasm.Native — load-only wiring of complete precompiled entries and the
  interpreter-free host-to-guest invoke used by the runtime shell.

  This unit maps already-emitted machine code through Wasm.Jit.CodeBuffer
  (the W^X chokepoint) and installs the backend invoke + helper table. It
  does NOT compile: no JitCanCompile, no JitStageFunctionBytes, no
  ForceCompile, and no Wasm.Aot compile driver. Incomplete, incompatible,
  or unreadable native images fail closed with EWasmLinkError — there is
  no interpreter fallback.

  Frame carve, epoch snapshot, GC push, and trap unwind stay the shipped
  runtime helpers (Wasm.Interp's JitEnterFrame pair, Wasm.Runtime.Traps).
  Those are helpers the architecture retains; they are not the interpreter
  dispatch loop. }
unit Wasm.Native;

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

interface

uses
  SysUtils,

  Wasm.Aot.Artifact,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit.CodeBuffer,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values;

type
  { Owns the mapped executable regions for one store. Free BEFORE the store
    (same teardown order as the JIT context). }
  TWasmNativeContext = class
  private
    FStore: TWasmStore;
    FBuffers: array of TWasmCodeBuffer;
    FCompiledAddrs: array of TWasmFuncAddr;
    FHookInstalled: Boolean;
  public
    constructor Create(const AStore: TWasmStore);
    destructor Destroy; override;
    function LoadPrecompiled(const AAddr: TWasmFuncAddr;
      const ACode: TWasmBytes; const AEntryOffset: NativeUInt): Boolean;
  end;

  TWasmNativeLoadResult = (
    nlrLoaded,
    nlrBadMagic,
    nlrBadFormatVer,
    nlrBadChecksum,
    nlrMalformed,
    nlrIrVersionMismatch,
    nlrArchMismatch,
    nlrAbiMismatch,
    nlrModuleHashMismatch,
    nlrNoBackend,
    nlrIncomplete
  );

{ Human-readable reason for a failed native load. }
function NativeLoadResultText(const AResult: TWasmNativeLoadResult): string;

{ Parse AArtifact (a `.waot` carrier), apply every load guard, map every
  defined wasm function's code, and fail if any defined function is missing
  compiled bytes. ALoaded must already be the decode+validate result for the
  same source bytes. Returns the owning context on nlrLoaded (caller frees
  it before the store); nil on every failure. }
function NativeLoadComplete(const AStore: TWasmStore;
  const ALoaded: TWasmLoadedModule; const AInstance: TWasmModuleInstance;
  const AArtifact: TWasmBytes; out AResult: TWasmNativeLoadResult): TWasmNativeContext;

{ Host-to-guest entry that installs the per-invocation trampoline and
  dispatches only through compiled entries. A missing compiled entry is
  EWasmLinkError, not an interpreter run. }
procedure NativeInvoke(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
  const AParams: PWasmValue; const AResults: PWasmValue);

implementation

uses
  {$IFDEF WASM_JIT_ARM64}
  Wasm.Jit.Arm64,
  {$ENDIF}
  {$IFDEF WASM_JIT_X64}
  Wasm.Jit.X64,
  {$ENDIF}
  Wasm.Interp.Numeric;

function NativeHostArch: Byte;
begin
  {$IF DEFINED(CPUAARCH64)}
  Result := WAOT_ARCH_AARCH64;
  {$ELSEIF DEFINED(CPUX86_64)}
  Result := WAOT_ARCH_X64;
  {$ELSE}
  Result := WAOT_ARCH_UNKNOWN;
  {$ENDIF}
end;

function NativeLoadResultText(const AResult: TWasmNativeLoadResult): string;
begin
  case AResult of
    nlrLoaded: Result := 'loaded';
    nlrBadMagic: Result := 'not a native-code image';
    nlrBadFormatVer: Result := 'unsupported native-code container version';
    nlrBadChecksum: Result := 'corrupt or truncated native-code image';
    nlrMalformed: Result := 'malformed native-code image';
    nlrIrVersionMismatch: Result := 'IR format version mismatch';
    nlrArchMismatch: Result := 'native image built for a different CPU';
    nlrAbiMismatch: Result := 'native image built by a different wasmlight build';
    nlrModuleHashMismatch: Result := 'native image does not match the module';
    nlrNoBackend: Result := 'no native backend on this host';
    nlrIncomplete: Result := 'incomplete native image: a defined function has no compiled entry';
  else
    Result := 'rejected';
  end;
end;

constructor TWasmNativeContext.Create(const AStore: TWasmStore);
begin
  inherited Create;
  FStore := AStore;
  FBuffers := nil;
  FCompiledAddrs := nil;
  FHookInstalled := False;
end;

destructor TWasmNativeContext.Destroy;
var
  I: Integer;
begin
  if FStore <> nil then
  begin
    for I := 0 to High(FCompiledAddrs) do
      if FCompiledAddrs[I] <= High(FStore.Funcs) then
      begin
        FStore.Funcs[FCompiledAddrs[I]].CompiledEntry := nil;
        FStore.Funcs[FCompiledAddrs[I]].CompiledDirectEntry := nil;
        FStore.Funcs[FCompiledAddrs[I]].CompiledNativeScalarEntry := nil;
      end;
    if FHookInstalled then
    begin
      FStore.JitInvokeCompiled := nil;
      FStore.TierInvoke := nil;
    end;
  end;
  for I := 0 to High(FBuffers) do
    FBuffers[I].Free;
  inherited Destroy;
end;

function TWasmNativeContext.LoadPrecompiled(const AAddr: TWasmFuncAddr;
  const ACode: TWasmBytes; const AEntryOffset: NativeUInt): Boolean;
{$IFDEF WASM_JIT_BACKEND}
var
  Buf: TWasmCodeBuffer;
  N: Integer;
{$ENDIF}
begin
  Result := False;
  if AAddr > High(FStore.Funcs) then
    Exit;
  if FStore.Funcs[AAddr].Kind <> wfkWasm then
    Exit;
  if FStore.Funcs[AAddr].CompiledEntry <> nil then
  begin
    Result := True;
    Exit;
  end;
  if Length(ACode) = 0 then
    Exit;
  {$IFDEF WASM_JIT_BACKEND}
  N := Length(FBuffers);
  SetLength(FBuffers, N + 1);
  FBuffers[N] := nil;
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitBytes(ACode);
    Buf.MakeExecutable;
  except
    Buf.Free;
    SetLength(FBuffers, N);
    Exit;
  end;
  FBuffers[N] := Buf;
  FStore.Funcs[AAddr].CompiledEntry :=
    Pointer(PtrUInt(Buf.EntryPoint) + AEntryOffset);
  N := Length(FCompiledAddrs);
  SetLength(FCompiledAddrs, N + 1);
  FCompiledAddrs[N] := AAddr;
  Result := True;
  {$ENDIF}
end;

procedure NativeDispatch(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue);
{$IFDEF WASM_JIT_ARM64}
begin
  Arm64InvokeCompiled(AStore, AFuncAddr, AParams, AResults);
end;
{$ELSE}
{$IFDEF WASM_JIT_X64}
begin
  X64InvokeCompiled(AStore, AFuncAddr, AParams, AResults);
end;
{$ELSE}
begin
  raise EWasmLinkError.Create('no native backend on this host');
end;
{$ENDIF}
{$ENDIF}

procedure NativeTierInvoke(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue);
var
  Ctx: PWasmInterpContext;
  RetKind: TWasmRetKind;
begin
  AStore.CheckThread;
  Ctx := InterpContextFor(AStore);
  RetKind := ConsumeJitSeamReentry;
  if AStore.Heap.CurrentFrame = nil then
  begin
    Ctx^.Depth := 0;
    Ctx^.ValueTop := 0;
    AStore.EpochSnapshot := AStore.Epoch;
  end;
  MaskFpuExceptions;
  if AStore.Funcs[AFuncAddr].Kind = wfkHost then
    raise EWasmInternal.Create(
      'internal: native entry reached a host function');
  if AStore.Funcs[AFuncAddr].CompiledEntry = nil then
    raise EWasmLinkError.Create(
      'incomplete native image: a defined function has no compiled entry');
  if not Assigned(AStore.JitInvokeCompiled) then
    raise EWasmLinkError.Create('native dispatcher is not installed');
  if RetKind = rtCompiledSeam then
    MarkJitSeamReentry;
  AStore.JitInvokeCompiled(AStore, AFuncAddr, AParams, AResults);
end;

function NativeLoadComplete(const AStore: TWasmStore;
  const ALoaded: TWasmLoadedModule; const AInstance: TWasmModuleInstance;
  const AArtifact: TWasmBytes; out AResult: TWasmNativeLoadResult): TWasmNativeContext;
var
  Parsed: TWasmAotArtifact;
  Parse: TWasmAotParseResult;
  LiveHash: TWasmAotHash128;
  Native: TWasmNativeContext;
  I: Integer;
  Rec: ^TWasmAotFuncRecord;
  Covered: array of Boolean;
  ModuleFuncIndex: UInt32;
  Addr: TWasmFuncAddr;
  Ir: TWasmIrModule;
begin
  Result := nil;
  if (AStore = nil) or (ALoaded = nil) or (AInstance = nil) then
  begin
    AResult := nlrMalformed;
    Exit;
  end;
  if Length(AArtifact) = 0 then
  begin
    AResult := nlrIncomplete;
    Exit;
  end;

  Parse := ParseAotArtifact(AArtifact, Parsed);
  case Parse of
    aprOk:;
    aprBadMagic: begin AResult := nlrBadMagic; Exit; end;
    aprBadFormatVer: begin AResult := nlrBadFormatVer; Exit; end;
    aprBadChecksum: begin AResult := nlrBadChecksum; Exit; end;
  else
    AResult := nlrMalformed;
    Exit;
  end;

  if Parsed.Header.IrFormatVer <> UInt16(IR_FORMAT_VERSION) then
  begin
    AResult := nlrIrVersionMismatch;
    Exit;
  end;
  if NativeHostArch = WAOT_ARCH_UNKNOWN then
  begin
    AResult := nlrNoBackend;
    Exit;
  end;
  if Parsed.Header.TargetArch <> NativeHostArch then
  begin
    AResult := nlrArchMismatch;
    Exit;
  end;
  if Parsed.Header.AbiFingerprint <> WasmAotAbiFingerprint(AStore) then
  begin
    AResult := nlrAbiMismatch;
    Exit;
  end;
  LiveHash := WaotHash128(ALoaded.BytesPtr, ALoaded.BytesLength);
  if not WaotHash128Equal(Parsed.Header.ModuleHash, LiveHash) then
  begin
    AResult := nlrModuleHashMismatch;
    Exit;
  end;
  if not JitExecMemSupported then
  begin
    AResult := nlrNoBackend;
    Exit;
  end;

  Ir := ALoaded.Ir;
  SetLength(Covered, Length(Ir.Functions));
  for I := 0 to High(Covered) do
    Covered[I] := False;

  Native := TWasmNativeContext.Create(AStore);
  try
    AStore.JitInvokeCompiled := @NativeDispatch;
    AStore.TierInvoke := @NativeTierInvoke;
    {$IFDEF WASM_JIT_ARM64}
    AStore.JitHelperTable := Arm64GetHelperTable;
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    AStore.JitHelperTable := X64GetHelperTable;
    {$ENDIF}
    Native.FHookInstalled := True;

    for I := 0 to High(Parsed.Funcs) do
    begin
      Rec := @Parsed.Funcs[I];
      if Rec^.FuncIrIndex >= UInt32(Length(Ir.Functions)) then
      begin
        AResult := nlrMalformed;
        Native.Free;
        Exit;
      end;
      if (not Rec^.Compiled) or (Length(Rec^.Code) = 0) then
      begin
        AResult := nlrIncomplete;
        Native.Free;
        Exit;
      end;
      if Rec^.RegisterCount <> Ir.Functions[Rec^.FuncIrIndex].RegisterCount then
      begin
        AResult := nlrMalformed;
        Native.Free;
        Exit;
      end;
      ModuleFuncIndex := Ir.FuncImportCount + Rec^.FuncIrIndex;
      if ModuleFuncIndex >= UInt32(Length(AInstance.FuncAddrs)) then
      begin
        AResult := nlrMalformed;
        Native.Free;
        Exit;
      end;
      Addr := AInstance.FuncAddrs[ModuleFuncIndex];
      if not Native.LoadPrecompiled(Addr, Rec^.Code, Rec^.EntryOffset) then
      begin
        AResult := nlrIncomplete;
        Native.Free;
        Exit;
      end;
      Covered[Rec^.FuncIrIndex] := True;
    end;

    for I := 0 to High(Covered) do
      if not Covered[I] then
      begin
        AResult := nlrIncomplete;
        Native.Free;
        Exit;
      end;
  except
    Native.Free;
    AResult := nlrMalformed;
    Exit;
  end;

  AResult := nlrLoaded;
  Result := Native;
end;

type
  PNativeInvokeArgs = ^TNativeInvokeArgs;
  TNativeInvokeArgs = record
    Store: TWasmStore;
    Addr: TWasmFuncAddr;
    Params: PWasmValue;
    Results: PWasmValue;
  end;

procedure NativeInvokeThunk(const AData: Pointer);
var
  Args: PNativeInvokeArgs;
begin
  Args := PNativeInvokeArgs(AData);
  NativeTierInvoke(Args^.Store, Args^.Addr, Args^.Params, Args^.Results);
end;

procedure NativeInvoke(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Args: TNativeInvokeArgs;
  Outermost: Boolean;
begin
  Outermost := CurrentTrampoline = nil;
  Args.Store := AStore;
  Args.Addr := AFuncAddr;
  Args.Params := AParams;
  Args.Results := AResults;
  try
    WasmInvoke(@NativeInvokeThunk, @Args);
  except
    on E: EWasmError do
    begin
      if Outermost then
      begin
        AStore.Heap.ResetFrames;
        ResetInterpContext(AStore);
      end;
      raise;
    end;
    on E: Exception do
    begin
      if Outermost then
      begin
        AStore.Heap.ResetFrames;
        ResetInterpContext(AStore);
      end;
      raise EWasmError.CreateFmt(
        'unexpected runtime fault in guest execution: %s (%s)',
        [E.Message, E.ClassName]);
    end;
  end;
end;

end.
