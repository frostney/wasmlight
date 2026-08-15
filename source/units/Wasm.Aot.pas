{ Wasm.Aot — the ahead-of-time compile and load drivers (.agent/design/aot-spec.md
  §3, §4). Serializes a module's JIT-compiled functions into a `.waot` artifact
  (AotCompileModule) and, in a fresh store, re-decodes+re-validates the module,
  checks every guard, maps the artifact's code executable, fills the helper
  table, and wires each CompiledEntry (AotLoadAndWire) — the serialize -> guard
  -> relocate(=fill-table) -> execute spine.

  THE SECURITY BOUNDARY (§2.4, §4, §8) IS A HARD CODE PATH. The module is ALWAYS
  re-decoded and re-validated at load, and that FRESH validation — never the
  artifact — is the safety oracle. AotLoadAndWire takes an ALREADY-loaded
  TWasmLoadedModule (which, by construction, came from Wasm.Engine.LoadModule =
  decode + validate on the SOURCE bytes) and the artifact only supplies
  COMPILED CODE. The code is used ONLY IF every guard passes:

    1 magic / 2 aotFormatVer      (structural, in Wasm.Aot.Artifact)
    3 irFormatVer  = IR_FORMAT_VERSION   (ADR-0007 — IR the code was built from)
    4 targetArch   = host arch
    5 abiFingerprint = live runtime       (§1.4 — same wasmlight build/ABI)
    6 selfChecksum recomputes             (corruption / truncation)
    7 moduleHash   = FNV128(source bytes) (§2.4 — this exact module)

  ANY mismatch -> the artifact is ignored and the module runs interpreted (a
  tampered artifact for a DIFFERENT module has a mismatching moduleHash and is
  rejected). A tampered code blob for the SAME module (matching hash) WOULD run —
  but that is content-integrity, NOT authentication: an attacker who can rewrite
  the `.waot` can equally rewrite the `wasmlight` binary, so the artifact and the
  runtime are the SAME trust domain and authenticating one against the other buys
  nothing (§2.4 threat model). What is preserved unconditionally is the wasm
  sandbox: the guest cannot exceed the freshly-validated IR, because decode +
  validate always run and the loaded code is a function of that validated IR
  produced by our own backend.

  NO NEW SEAM. AOT-loaded code is the JIT's code (the unified emitter, §1.2/§1.3),
  wired to the SAME TWasmFuncInst.CompiledEntry and reached through the SAME
  JitDispatch / *InvokeCompiled dispatcher (Wasm.Jit) with the SAME per-process
  helper table (RegisterJit) and the freshly-decoded IR base passed per call. So
  the frame, GC stack map, epoch check, trap unwind, tail-call trampoline, and
  EH seam are all inherited unchanged (§4.4) — this unit changes only where a
  function's code BYTES came from.

  WAVE 1 SCOPE: the host arch (aarch64 here; x86-64 is Wave 4). AotCompileModule
  walks every defined function (compilable ones compiled, the rest recorded
  declined), which naturally covers the one-function milestone (§7.2).

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Depends on
  Wasm.Aot.Artifact (format), Wasm.Jit (driver + helper table + stage/adopt),
  Wasm.Jit.CodeBuffer (host support probe), Wasm.Interp (ABI fingerprint),
  Wasm.Engine (the loaded module), Wasm.Ir (IR_FORMAT_VERSION), and
  Wasm.Runtime.Store. }
unit Wasm.Aot;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Aot.Artifact,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit,
  Wasm.Jit.CodeBuffer,
  Wasm.Runtime.Store;

type
  { The load outcome (aot-spec §4.5). alrLoaded means the artifact passed every
    guard and its code is now wired; every other value is a transparent
    fall-back reason the caller may log — the module then runs interpreted (or
    JIT-on-hot, a caller policy). Each guard has a DISTINCT reason so a log says
    exactly why the cache was not used. }
  TWasmAotLoadResult = (
    alrLoaded,
    alrBadMagic,             { not a `.waot` }
    alrBadFormatVer,         { container version we cannot read }
    alrBadChecksum,          { corrupt / truncated / partially written }
    alrMalformed,            { a length ran past the buffer }
    alrIrVersionMismatch,    { compiled from a since-moved IR (ADR-0007) }
    alrArchMismatch,         { code for a different CPU }
    alrAbiMismatch,          { a different wasmlight build/ABI (§1.4) }
    alrModuleHashMismatch,   { a stale artifact for a since-changed module }
    alrNoBackend             { this host has no JIT/AOT backend }
  );

{ The AOT target arch id for THIS host (Wasm.Aot.Artifact's WAOT_ARCH_*), or
  WAOT_ARCH_UNKNOWN off a supported CPU. Guard 4 compares the artifact's
  targetArch against this. }
function AotHostArch: Byte;

{ Compile every DEFINED function of ALoaded to a `.waot` byte buffer (§3):
  compilable functions (JitCanCompile) are staged to position-independent bytes
  (JitStageFunctionBytes, the JIT's own driver), the rest recorded declined
  (compiled=0, run interpreted at load). Stamps irFormatVer = ALoaded.Ir's
  version, targetArch = host, abiFingerprint = live runtime, moduleHash =
  FNV128(source `.wasm` bytes). AStore supplies the record-layout offsets the
  code bakes (constant across stores of the same build); it need not be the
  instantiated store. Returns the artifact bytes the caller writes to
  `<name>.waot` (or keeps in memory, as the differential harness does). }
function AotCompileModule(const AStore: TWasmStore;
  const ALoaded: TWasmLoadedModule): TWasmBytes;

{ The raw-IR form of AotCompileModule for callers that already hold the
  freshly-validated IR and the source bytes and have no TWasmLoadedModule to
  wrap them (the `.wast` corpus runner, which decodes+validates a module itself
  and instantiates from that same IR — aot-spec §5.1). moduleHash is FNV128 over
  [ABytesPtr, ABytesPtr+ABytesLength), exactly the bytes the loader re-hashes,
  so the round-trip's module-hash guard binds artifact to source with no
  redundant second decode. AotCompileModule is a thin wrapper over this. }
function AotCompileModuleIr(const AStore: TWasmStore; const AIr: TWasmIrModule;
  const ABytesPtr: PByte; const ABytesLength: NativeUInt): TWasmBytes;

{ Load AArtifact against the freshly-validated ALoaded + its live AInstance in
  AStore, applying every guard (§2.3), and — only if all pass — map each compiled
  function's code executable and wire its CompiledEntry (§4.2). ALoaded MUST be
  the decode+validate result for the SAME source bytes the artifact was compiled
  from (the caller's LoadModule is the security boundary); moduleHash binds the
  two. Returns the owning TWasmJitContext when alrLoaded (the CALLER frees it
  BEFORE the store, the JIT's teardown discipline), or NIL on any fall-back with
  AResult naming the reason — in which case NOTHING is installed and the store
  runs interpreted. }
function AotLoadAndWire(const AStore: TWasmStore;
  const ALoaded: TWasmLoadedModule; const AInstance: TWasmModuleInstance;
  const AArtifact: TWasmBytes; out AResult: TWasmAotLoadResult): TWasmJitContext;

{ The raw-IR form of AotLoadAndWire (aot-spec §5.1). AIr is the freshly-decoded
  +validated IR for the SAME source bytes the artifact was compiled from —
  [ABytesPtr, ABytesPtr+ABytesLength) — and the moduleHash guard hashes those
  bytes to bind the two. The caller's own decode+validate that produced AIr IS
  the security boundary; the artifact only supplies compiled code, used solely
  when every guard passes. AotLoadAndWire is a thin wrapper over this. }
function AotLoadAndWireIr(const AStore: TWasmStore; const AIr: TWasmIrModule;
  const ABytesPtr: PByte; const ABytesLength: NativeUInt;
  const AInstance: TWasmModuleInstance; const AArtifact: TWasmBytes;
  out AResult: TWasmAotLoadResult): TWasmJitContext;

implementation

function AotHostArch: Byte;
begin
  {$IF DEFINED(CPUAARCH64)}
  Result := WAOT_ARCH_AARCH64;
  {$ELSEIF DEFINED(CPUX86_64)}
  Result := WAOT_ARCH_X64;
  {$ELSE}
  Result := WAOT_ARCH_UNKNOWN;
  {$ENDIF}
end;

function AotCompileModule(const AStore: TWasmStore;
  const ALoaded: TWasmLoadedModule): TWasmBytes;
begin
  Result := AotCompileModuleIr(AStore, ALoaded.Ir, ALoaded.BytesPtr,
    ALoaded.BytesLength);
end;

function AotCompileModuleIr(const AStore: TWasmStore; const AIr: TWasmIrModule;
  const ABytesPtr: PByte; const ABytesLength: NativeUInt): TWasmBytes;
var
  Ir: TWasmIrModule;
  Funcs: TWasmAotFuncRecords;
  Params: TWasmAotWriteParams;
  I: Integer;
  Fn: PWasmIrFunctionRec;
  Code: TWasmBytes;
  EntryOffset: NativeUInt;
  RegCount: UInt32;
begin
  Ir := AIr;
  SetLength(Funcs, Length(Ir.Functions));
  for I := 0 to High(Ir.Functions) do
  begin
    Fn := @Ir.Functions[I];
    Funcs[I].FuncIrIndex := UInt32(I);
    Funcs[I].RegisterCount := Fn^.RegisterCount;
    Funcs[I].EntryOffset := 0;
    Funcs[I].Code := nil;
    Funcs[I].Relocs := nil;    { empty in the unified emitter (§1.2/§1.5) }
    Funcs[I].Compiled := False;
    if JitCanCompile(Fn) then
    begin
      Code := JitStageFunctionBytes(AStore, Fn,
        Ir.FuncImportCount + UInt32(I), EntryOffset, RegCount);
      if Length(Code) > 0 then
      begin
        Funcs[I].Compiled := True;
        Funcs[I].Code := Code;
        Funcs[I].EntryOffset := UInt32(EntryOffset);
        Funcs[I].RegisterCount := RegCount;
      end;
      { Length(Code) = 0 here means the backend declined late (e.g. branch
        range) — recorded un-compiled, run interpreted at load. }
    end;
  end;

  Params.IrFormatVer := UInt16(Ir.FormatVersion);
  Params.TargetArch := AotHostArch;
  Params.Flags := 0;
  Params.AbiFingerprint := WasmAotAbiFingerprint(AStore);
  Params.ModuleHash := WaotHash128(ABytesPtr, ABytesLength);

  Result := WriteAotArtifact(Params, Funcs);
end;

function AotLoadAndWire(const AStore: TWasmStore;
  const ALoaded: TWasmLoadedModule; const AInstance: TWasmModuleInstance;
  const AArtifact: TWasmBytes; out AResult: TWasmAotLoadResult): TWasmJitContext;
begin
  Result := AotLoadAndWireIr(AStore, ALoaded.Ir, ALoaded.BytesPtr,
    ALoaded.BytesLength, AInstance, AArtifact, AResult);
end;

function AotLoadAndWireIr(const AStore: TWasmStore; const AIr: TWasmIrModule;
  const ABytesPtr: PByte; const ABytesLength: NativeUInt;
  const AInstance: TWasmModuleInstance; const AArtifact: TWasmBytes;
  out AResult: TWasmAotLoadResult): TWasmJitContext;
var
  Parsed: TWasmAotArtifact;
  Parse: TWasmAotParseResult;
  LiveHash: TWasmAotHash128;
  Ir: TWasmIrModule;
  Jit: TWasmJitContext;
  I: Integer;
  Rec: ^TWasmAotFuncRecord;
  ModuleFuncIndex: UInt32;
  Addr: TWasmFuncAddr;
begin
  Result := nil;

  { Structural parse + magic/format/checksum (Wasm.Aot.Artifact). }
  Parse := ParseAotArtifact(AArtifact, Parsed);
  case Parse of
    aprOk:;
    aprBadMagic: begin AResult := alrBadMagic; Exit; end;
    aprBadFormatVer: begin AResult := alrBadFormatVer; Exit; end;
    aprBadChecksum: begin AResult := alrBadChecksum; Exit; end;
  else
    AResult := alrMalformed;
    Exit;
  end;

  { Guard 3 — the IR the code was compiled from must match ours (ADR-0007). }
  if Parsed.Header.IrFormatVer <> UInt16(IR_FORMAT_VERSION) then
  begin
    AResult := alrIrVersionMismatch;
    Exit;
  end;

  { Guard 4 — arch-specific code for THIS CPU only (§6). A host with no backend
    arch is reported separately so the log distinguishes "wrong CPU" from "no
    JIT here at all". }
  if AotHostArch = WAOT_ARCH_UNKNOWN then
  begin
    AResult := alrNoBackend;
    Exit;
  end;
  if Parsed.Header.TargetArch <> AotHostArch then
  begin
    AResult := alrArchMismatch;
    Exit;
  end;

  { Guard 5 — same wasmlight build/ABI (§1.4): the baked record offsets, slot
    strides, helper count, and emitter revision. }
  if Parsed.Header.AbiFingerprint <> WasmAotAbiFingerprint(AStore) then
  begin
    AResult := alrAbiMismatch;
    Exit;
  end;

  { Guard 7 — THIS module: the freshly-loaded source bytes (§2.4). ALoaded came
    from decode+validate, so hashing its bytes rejects a stale/foreign artifact.
    (Guard 6, selfChecksum, was verified inside ParseAotArtifact.) }
  LiveHash := WaotHash128(ABytesPtr, ABytesLength);
  if not WaotHash128Equal(Parsed.Header.ModuleHash, LiveHash) then
  begin
    AResult := alrModuleHashMismatch;
    Exit;
  end;

  { All whole-artifact guards passed. The executable-memory path must exist on
    this host; if not, fall back (the interpreter is always correct). }
  if not JitExecMemSupported then
  begin
    AResult := alrNoBackend;
    Exit;
  end;

  Ir := AIr;

  { Install the SAME dispatcher + per-process helper table the JIT uses
    (RegisterJit), then adopt each compiled function's bytes. The context owns
    the loaded code blocks and, on teardown, clears the CompiledEntry pointers
    and the hook — one ownership discipline shared with the JIT. }
  Jit := RegisterJit(AStore);
  try
    for I := 0 to High(Parsed.Funcs) do
    begin
      Rec := @Parsed.Funcs[I];
      if not Rec^.Compiled then
        Continue;                          { declined -> interpreted (§4.2 step 6) }
      if Rec^.FuncIrIndex >= UInt32(Length(Ir.Functions)) then
        Continue;                          { defensive: record names no such func }

      { Cross-check the artifact's registerCount against the FRESH IR (§2.3): a
        hash collision or a subtly-different validated IR declines this one
        function, which then runs interpreted — never runs wrong-frame code. }
      if Rec^.RegisterCount <> Ir.Functions[Rec^.FuncIrIndex].RegisterCount then
        Continue;

      { funcIrIndex is the DEFINED-function index; the module function index adds
        the import count, and the instance maps that to the store func addr. }
      ModuleFuncIndex := Ir.FuncImportCount + Rec^.FuncIrIndex;
      if ModuleFuncIndex >= UInt32(Length(AInstance.FuncAddrs)) then
        Continue;                          { defensive }
      Addr := AInstance.FuncAddrs[ModuleFuncIndex];

      { Map the bytes executable + wire CompiledEntry. The reloc table is empty
        (§1.2), so there is nothing to patch — filling the helper table and
        passing the pinned IR base per call IS the whole relocation. }
      Jit.LoadPrecompiled(Addr, Rec^.Code, Rec^.EntryOffset);
    end;
  except
    { A failure mid-wiring must not leak the context or leave a half-installed
      hook; drop it and fall back. }
    Jit.Free;
    AResult := alrMalformed;
    Exit;
  end;

  AResult := alrLoaded;
  Result := Jit;
end;

end.
