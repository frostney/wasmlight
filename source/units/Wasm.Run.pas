{ Wasm.Run — the testable core of `wasmlight run` (embedding-spec.md §4, §6).

  `wasmlight run <module.wasm>` is the hello-world milestone: decode + validate
  a real WASI preview1 COMMAND, wire it to the wasi_snapshot_preview1 host
  module under a deny-by-default capability set, run its `_start`, and map the
  guest's outcome to a process exit code. This unit is that sequence, factored
  OUT of the program entry point so it is hermetically unit-testable: it takes a
  TWasmWasiConfig (whose streams the caller chooses — a test injects capturing
  buffers, the CLI injects the real process fds) and never touches real stdio,
  the filesystem, or the network itself.

  It is a THIN driver over Wasm.Engine + Wasm.Wasi, adding no runtime logic:

    1. LoadModuleFromFile    — decode + validate (EWasmDecodeError vs
                               EWasmValidationError kept distinct).
    2. TWasmWasiContext      — the fd table (stdio + any preopens) from AConfig.
    3. WasiDefineAll         — every wave-1 preview1 import on a linker.
    4. Instantiate           — link (EWasmLinkError if the module imports
                               something outside the granted surface).
    5. SetMemory             — resolve the guest's exported "memory" into the
                               context (the one instance->context handle,
                               embedding-spec.md §3).
    6. _start                — the command entry (embedding-spec.md §4.4);
                               a reactor's `_initialize`-only shape is out of v1
                               scope and reported, not run.
    7. exit-code mapping     — embedding-spec.md §6.2: normal return -> 0;
                               proc_exit(n) (EWasmExit) -> n and $FF; a trap
                               (EWasmTrap) -> 134; an uncaught wasm exception
                               (EWasmException) -> 1; a decode/validate/link
                               failure -> 1. Diagnostics are RETURNED (never
                               printed here), so the caller sends them to the
                               process stderr and a test asserts on them without
                               a real stderr.

  DENY-BY-DEFAULT (AGENTS.md, ADR-0002 via ADR-0014). This unit grants the guest
  nothing beyond what AConfig carries. A bare `wasmlight run` config is stdio +
  clock + random only — no filesystem, no environment, argv only as set. The
  --dir/--env flags add exactly the preopens/vars the user named, and nothing
  else reaches the host.

  Spec pin (core, for the embedding anchors this rests on): wasm-mcp 0.2.16,
  spec/main d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
unit Wasm.Run;

{$I Shared.inc}
{ Call marshals through PWasmValue slices, as the WASI layer does. }
{$POINTERMATH ON}

interface

uses
  SysUtils,

  Wasm.Aot,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Jit,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Wasi,
  Wasm.Wasi.Types;

const
  { A trap aborts the run (embedding-spec.md §6.2): 128 + SIGABRT(6), matching
    wasmtime's CLI convention so a shell that understands 128+signal composes. }
  WASM_RUN_EXIT_TRAP = 134;
  { An uncaught wasm exception is a program-level error, kept distinct from a
    trap so scripts can discriminate (embedding-spec.md §6.2). }
  WASM_RUN_EXIT_EXCEPTION = 1;
  { A decode/validate/link failure, or an internal error, before or around the
    run (embedding-spec.md §6.2). }
  WASM_RUN_EXIT_ERROR = 1;

  { Directory rights granted to a --dir preopen. Wave-1 only ADVERTISES the
    preopen (fd_prestat_*); path_open and the file ops are F4, which will mask
    derived fds against these. A directory-shaped bundle (open/read/stat/create/
    the common path ops) so a program discovers a usefully-capable preopen; the
    host still resolves every path under the chosen directory (embedding-spec.md
    §5.3), so the capability is the directory, not any of these bits. }
  WASM_RUN_DIR_RIGHTS: TWasmWasiRights =
    UInt64($1FFFFFFF);   { all preview1 rights bits (0..28) — F4 refines }

type
  { The outcome of a run: the process exit code and an optional diagnostic the
    caller prints to stderr (never stdout — stdout is the guest's). Diagnostic
    is '' on a clean run or a plain proc_exit.

    AotStatus is a PURELY INFORMATIONAL note about the ahead-of-time artifact
    (aot-spec §4.5): '' when no artifact was offered, otherwise "loaded" or a
    transparent fall-back reason. It NEVER affects ExitCode — a run with a
    matching artifact and a run without one produce the same code and output;
    the artifact only supplies pre-compiled code, re-checked against the fresh
    decode+validate. The caller may print this at a verbose level. }
  TWasmRunResult = record
    ExitCode: Integer;
    Diagnostic: string;
    AotStatus: string;
  end;

  { --- real-OS stdio streams (embedding-spec.md §4.5) --------------------

    Direct FileWrite/FileRead on the process handles, NOT buffered system.Write,
    so a guest's fd_write ordering is not scrambled by Pascal's own buffering.
    These are what `wasmlight run` injects into a config in place of the default
    capture buffers; a test injects the buffers instead and never constructs
    these, keeping the test hermetic. }
  TWasmWasiOsOutStream = class(TWasmWasiStream)
  private
    FHandle: THandle;
  public
    constructor Create(const AHandle: THandle);
    function WriteBytes(const ABuf: PByte;
      const ALen: NativeUInt): NativeUInt; override;
    function ReadBytes(const ABuf: PByte;
      const AMax: NativeUInt): NativeUInt; override;
  end;

  TWasmWasiOsInStream = class(TWasmWasiStream)
  private
    FHandle: THandle;
  public
    constructor Create(const AHandle: THandle);
    function WriteBytes(const ABuf: PByte;
      const ALen: NativeUInt): NativeUInt; override;
    function ReadBytes(const ABuf: PByte;
      const AMax: NativeUInt): NativeUInt; override;
  end;

{ Run the module at APath against AConfig's granted capabilities and return the
  process exit code (embedding-spec.md §4.3, §6). AConfig is BORROWED — the
  caller owns and frees it (and any streams it injected). This never raises for
  a guest outcome: a trap, an uncaught exception, a proc_exit, or a
  decode/validate/link failure all become a (code, diagnostic) result. }
function RunConfiguredModule(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmRunResult;

{ Same, from an in-memory module image — the hermetic path a test drives
  (assemble wat -> bytes -> run with a capturing config, no file, no real
  stdio). A decode/validate failure is exit 1 with the class + message in
  Diagnostic. AConfig is borrowed. }
function RunModuleBytes(const ABytes: TWasmBytes;
  const AConfig: TWasmWasiConfig): TWasmRunResult;

{ The core, from an already decoded + validated module. Instantiates against
  AConfig's WASI capabilities, runs _start, and maps the outcome. ALoaded and
  AConfig are BORROWED — the caller owns and frees both (an instance borrows the
  loaded module's bytes, ADR-0003). }
function RunLoadedModule(const ALoaded: TWasmLoadedModule;
  const AConfig: TWasmWasiConfig): TWasmRunResult;

{ The AOT-aware variants (aot-spec §4). AArtifact is a `.waot` byte buffer for
  the SAME module; before running _start the run tries to AotLoadAndWire it
  against the FRESHLY decode+validated module, and — only if every guard passes
  (IR version, arch, ABI fingerprint, self-checksum, module hash) — the exports
  run through the AOT-loaded native code for instant startup. If the artifact is
  ABSENT (AArtifact empty), stale, wrong-arch, hash-mismatched, or otherwise
  rejected, the run TRANSPARENTLY falls back to the interpreter and still runs
  correctly — a bad artifact only loses the speedup, it never changes the
  outcome. The SECURITY INVARIANT holds: the module is always decoded+validated
  regardless of the artifact (that fresh validation is the safety oracle); the
  artifact only supplies pre-compiled code that is re-checked. The exit code and
  captured output are IDENTICAL whether AOT-loaded or interpreted; AotStatus
  records which happened. AArtifact/ALoaded/AConfig are BORROWED. }
function RunLoadedModuleAot(const ALoaded: TWasmLoadedModule;
  const AConfig: TWasmWasiConfig; const AArtifact: TWasmBytes): TWasmRunResult;

function RunModuleBytesAot(const ABytes: TWasmBytes;
  const AConfig: TWasmWasiConfig; const AArtifact: TWasmBytes): TWasmRunResult;

function RunConfiguredModuleAot(const APath: string;
  const AConfig: TWasmWasiConfig; const AArtifact: TWasmBytes): TWasmRunResult;

implementation

{ --- OS stdio streams ---------------------------------------------------- }

constructor TWasmWasiOsOutStream.Create(const AHandle: THandle);
begin
  inherited Create;
  FHandle := AHandle;
end;

function TWasmWasiOsOutStream.WriteBytes(const ABuf: PByte;
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

function TWasmWasiOsOutStream.ReadBytes(const ABuf: PByte;
  const AMax: NativeUInt): NativeUInt;
begin
  { An output stream is not readable. }
  Result := 0;
end;

constructor TWasmWasiOsInStream.Create(const AHandle: THandle);
begin
  inherited Create;
  FHandle := AHandle;
end;

function TWasmWasiOsInStream.WriteBytes(const ABuf: PByte;
  const ALen: NativeUInt): NativeUInt;
begin
  { An input stream is not writable. }
  Result := 0;
end;

function TWasmWasiOsInStream.ReadBytes(const ABuf: PByte;
  const AMax: NativeUInt): NativeUInt;
var
  Got: Int64;
begin
  if AMax = 0 then
    Exit(0);
  Got := FileRead(FHandle, ABuf^, LongInt(AMax));
  if Got < 0 then
    Result := 0    { read error reads as EOF to the guest }
  else
    Result := NativeUInt(Got);
end;

{ --- the run sequence ---------------------------------------------------- }

{ Does AInstance export a zero-arg `_initialize` (and no `_start`)? Then it is a
  preview1 reactor, which `wasmlight run` does not run (embedding-spec.md §4.4). }
function IsReactor(const AInstance: TWasmInstance): Boolean;
var
  Fn: TWasmFunc;
begin
  Result := AInstance.FindExportFunc('_initialize', Fn);
end;

{ A one-line, human-readable note for an AOT load outcome (aot-spec §4.5) — a
  distinct phrase per reason so a verbose log says exactly why the cache was or
  was not used. Informational only. }
function AotLoadResultText(const AResult: TWasmAotLoadResult): string;
begin
  case AResult of
    alrLoaded: Result := 'loaded';
    alrBadMagic: Result := 'not a .waot file';
    alrBadFormatVer: Result := 'unsupported artifact container version';
    alrBadChecksum: Result := 'corrupt or truncated artifact';
    alrMalformed: Result := 'malformed artifact';
    alrIrVersionMismatch: Result := 'IR format version mismatch';
    alrArchMismatch: Result := 'artifact built for a different CPU';
    alrAbiMismatch: Result := 'artifact built by a different wasmlight build';
    alrModuleHashMismatch: Result := 'stale artifact for a since-changed module';
    alrNoBackend: Result := 'no AOT backend on this host';
  else
    Result := 'rejected';
  end;
end;

function RunLoadedModuleAot(const ALoaded: TWasmLoadedModule;
  const AConfig: TWasmWasiConfig; const AArtifact: TWasmBytes): TWasmRunResult;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  Linker: TWasmLinker;
  Context: TWasmWasiContext;
  Instance: TWasmInstance;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  Mem: TWasmMemoryRef;
  StartFn: TWasmFunc;
  NoArgs, NoResults: array of TWasmValue;
begin
  Result.ExitCode := 0;
  Result.Diagnostic := '';
  Result.AotStatus := '';

  if (AConfig = nil) or (ALoaded = nil) then
  begin
    Result.ExitCode := WASM_RUN_EXIT_ERROR;
    Result.Diagnostic := 'run needs a module and a WASI config';
    Exit;
  end;

  Engine := nil;
  Store := nil;
  Linker := nil;
  Context := nil;
  Instance := nil;
  Jit := nil;
  try
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    EnsureInterpreter(Store);
    Context := TWasmWasiContext.Create(AConfig);
    Linker := TWasmLinker.Create(Store);
    WasiDefineAll(Linker, Context);

    { Link + instantiate. A module importing anything outside the granted
      wasi_snapshot_preview1 wave-1 surface fails here (embedding-spec.md §6.2:
      link failure -> exit 1). }
    try
      Instance := Instantiate(Store, Linker, ALoaded);
    except
      on E: EWasmError do
      begin
        Result.ExitCode := WASM_RUN_EXIT_ERROR;
        Result.Diagnostic := E.ClassName + ': ' + E.Message;
        Exit;
      end;
    end;

    { A preview1 command exports "memory"; the WASI layer writes the guest's own
      linear memory through it (embedding-spec.md §3, §4.3 step 7). }
    if not Instance.FindExportMemory('memory', Mem) then
    begin
      Result.ExitCode := WASM_RUN_EXIT_ERROR;
      Result.Diagnostic :=
        'not a command module: no exported "memory" (a WASI command must '
        + 'export "memory")';
      Exit;
    end;
    Context.SetMemory(Mem);

    { The command entry (embedding-spec.md §4.4). A reactor (only _initialize)
      is out of v1 scope for `run`; report it clearly rather than running it. }
    if not Instance.FindExportFunc('_start', StartFn) then
    begin
      Result.ExitCode := WASM_RUN_EXIT_ERROR;
      if IsReactor(Instance) then
        Result.Diagnostic :=
          'not a command module: exports "_initialize" but no "_start" '
          + '(reactor modules are out of scope for run)'
      else
        Result.Diagnostic := 'not a command module: no "_start" export';
      Exit;
    end;

    { OPTIONAL AOT LOAD (aot-spec §4). If the caller offered a `.waot` buffer,
      try to wire its pre-compiled code onto this store's func insts BEFORE the
      first call — instant startup, no compilation. The module has ALREADY been
      decode+validated (ALoaded), and THAT is the safety oracle; AotLoadAndWire
      re-checks the artifact's IR version, arch, ABI, self-checksum, and module
      hash, and only wires the code when every guard passes. Any rejection (a
      stale, wrong-arch, hash-mismatched, or corrupt artifact — or none at all)
      leaves every CompiledEntry nil, so the run falls back TRANSPARENTLY to the
      interpreter and still produces the identical outcome; only the speedup is
      lost. Jit (when non-nil) owns the loaded code and MUST be freed before the
      store (the JIT's teardown discipline), handled in the finally below. }
    if Length(AArtifact) > 0 then
    begin
      Jit := AotLoadAndWire(Store, ALoaded, Instance.Raw, AArtifact, LoadRes);
      if Jit <> nil then
        Result.AotStatus := 'aot: ' + AotLoadResultText(LoadRes)
      else
        Result.AotStatus := 'aot: fell back to interpreter ('
          + AotLoadResultText(LoadRes) + ')';
    end;

    { Run the module start function (if any), then _start, through the
      trampoline, mapping the outcome (embedding-spec.md §6.2). Both go through
      InterpInvoke, so a guest fault is a catchable EWasmTrap here, an uncaught
      throw an EWasmException, and proc_exit an EWasmExit. }
    NoArgs := nil;
    NoResults := nil;
    try
      RunStart(Store, Instance);
      Call(StartFn, NoArgs, NoResults);
      { _start returned normally with no proc_exit — a clean exit 0. }
      Result.ExitCode := 0;
    except
      on E: EWasmExit do
        { A clean, guest-requested exit: the process code is the guest's value,
          masked to a byte (a Unix status is 8 bits — embedding-spec.md §6.2). }
        Result.ExitCode := E.ExitCode and $FF;
      on E: EWasmTrap do
      begin
        Result.ExitCode := WASM_RUN_EXIT_TRAP;
        Result.Diagnostic := 'trap: ' + E.Message;
      end;
      on E: EWasmException do
      begin
        Result.ExitCode := WASM_RUN_EXIT_EXCEPTION;
        Result.Diagnostic := 'uncaught exception: ' + E.Message;
      end;
      on E: EWasmError do
      begin
        { Any other engine error surfacing from the run (defensive). }
        Result.ExitCode := WASM_RUN_EXIT_ERROR;
        Result.Diagnostic := E.ClassName + ': ' + E.Message;
      end;
      on E: Exception do
      begin
        { The outer catch-all, and the point of it. A non-EWasmError escaping
          the interpreter — an EAccessViolation, an ERangeError, an
          EOutOfMemory — is a wasmlight BUG, not a guest outcome. Left
          unhandled it would abort with the RTL's raw runtime-error 217, a
          dump indistinguishable from a crash and unroutable to stderr. This
          turns it into a named "internal error" on WASM_RUN_EXIT_ERROR,
          mirroring HandleValidate's outer handler (wasmlight.pas). It fixes
          nothing — it makes the failure reportable. A genuine RTL fault is
          hard to trigger deterministically, so this is guarded by structural
          parity with HandleValidate rather than a unit test. }
        Result.ExitCode := WASM_RUN_EXIT_ERROR;
        Result.Diagnostic := 'internal error: ' + E.ClassName + ': '
          + E.Message;
      end;
    end;
  finally
    { The store owns the underlying instance and borrows the loaded module's
      bytes (ADR-0003), so the instance handle is dropped first; then the AOT/JIT
      context, which reaches back into the STILL-WHOLE store to clear the
      compiled entries and the hook, so it MUST precede the store (jit-spec §3.4
      teardown order); then the context (owns nothing), the linker, the store,
      and the engine last. The loaded module and the config are the caller's.
      Jit is nil when no artifact was offered or none loaded — Free is a no-op. }
    Instance.Free;
    Jit.Free;
    Context.Free;
    Linker.Free;
    FreeAndNil(Store);
    Engine.Free;
  end;
end;

{ The plain (no-artifact) core: run purely interpreted. }
function RunLoadedModule(const ALoaded: TWasmLoadedModule;
  const AConfig: TWasmWasiConfig): TWasmRunResult;
begin
  Result := RunLoadedModuleAot(ALoaded, AConfig, nil);
end;

{ Load ABytes (decode + validate) then run, with an optional AOT artifact. }
function RunModuleBytesAot(const ABytes: TWasmBytes;
  const AConfig: TWasmWasiConfig; const AArtifact: TWasmBytes): TWasmRunResult;
var
  Loaded: TWasmLoadedModule;
begin
  Loaded := nil;
  try
    Loaded := LoadModule(ABytes);
  except
    on E: EWasmError do
    begin
      Result.ExitCode := WASM_RUN_EXIT_ERROR;
      Result.Diagnostic := E.ClassName + ': ' + E.Message;
      Result.AotStatus := '';
      Exit;
    end;
  end;
  try
    Result := RunLoadedModuleAot(Loaded, AConfig, AArtifact);
  finally
    Loaded.Free;
  end;
end;

function RunModuleBytes(const ABytes: TWasmBytes;
  const AConfig: TWasmWasiConfig): TWasmRunResult;
begin
  Result := RunModuleBytesAot(ABytes, AConfig, nil);
end;

{ Read APath then run, with an optional AOT artifact. A file that cannot be read
  is EWasmDecodeError (the honest class for "there is no module here") — exit 1
  with the message. The module is always decode+validated here regardless of the
  artifact (the security oracle); AArtifact only supplies re-checked code. }
function RunConfiguredModuleAot(const APath: string;
  const AConfig: TWasmWasiConfig; const AArtifact: TWasmBytes): TWasmRunResult;
var
  Loaded: TWasmLoadedModule;
begin
  Loaded := nil;
  try
    Loaded := LoadModuleFromFile(APath);
  except
    on E: EWasmError do
    begin
      Result.ExitCode := WASM_RUN_EXIT_ERROR;
      Result.Diagnostic := E.ClassName + ': ' + E.Message;
      Result.AotStatus := '';
      Exit;
    end;
  end;
  try
    Result := RunLoadedModuleAot(Loaded, AConfig, AArtifact);
  finally
    Loaded.Free;
  end;
end;

function RunConfiguredModule(const APath: string;
  const AConfig: TWasmWasiConfig): TWasmRunResult;
begin
  Result := RunConfiguredModuleAot(APath, AConfig, nil);
end;

end.
