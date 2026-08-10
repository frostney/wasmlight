{ Wasm.Jit — the baseline-JIT driver, the compiled-function dispatcher, and the
  per-store code cache (.agent/design/jit-spec.md §4, §5, §10.3, §12.2/§12.3
  Wave 1).

  This is the unit that plugs the JIT in behind the tier seam (§4.1). It does
  NOT replace the interpreter (the tier of record, ADR-0001): it is a companion
  on the same store that

    - registers a dispatcher (JitDispatch) as the store's JitInvokeCompiled hook
      (Wasm.Runtime.Store), which the interpreter already calls at every
      wasm-callee seam — and at the top-level entry — whenever a wasm function's
      CompiledEntry <> nil (Wasm.Interp);
    - compiles one TWasmIrFunction to native code through the active backend
      (Wasm.Jit.Arm64 for aarch64, the only backend this wave), sets the
      function's CompiledEntry, and owns the resulting code block for the store's
      lifetime;
    - falls back to the interpreter for anything it cannot yet compile
      (JitCanCompile — the scope fence, §10.3), so the JIT is always correct and
      only ever faster where it applies.

  THE HAND-OFF (§5.1, the frame IS the interpreter's frame). The compiled code
  never carves its own frame. JitDispatch builds the frame through the SHARED
  helper Wasm.Interp.JitEnterFrame — exhaustion check, register-file carve,
  zero, param marshal, GC-frame push — which returns @Values[Base], the
  register-file base. It passes that base to the compiled entry in the first
  argument register (x0 on AAPCS64); the compiled body reads and writes ONLY the
  in-memory register file (Reg[k] = base + k*8) and returns; then
  Wasm.Interp.JitLeaveFrame marshals the result slots out and pops the frame.
  Because the carve/zero/push/pop and the param/result marshaling are the
  interpreter's exact code, the exhaustion threshold, the GC contract, and the
  flat-slot calling convention are identical by construction — the observational
  -identity property (§13). It passes that base and the store to the compiled
  entry in x0/x1 (AAPCS64); the Wave-2 prologue pins the base in the callee-
  saved x19 (surviving helper calls) and the store in x20 (for the epoch word),
  and the epilogue restores them before returning to JitLeaveFrame.

  TIERING. The baseline compiles on-hot in principle (§4.2), but the milestone
  and the differential harness FORCE compilation (§11.1): JitForceCompile
  compiles a named function regardless of CallCount so the diff runner can drive
  every input through the compiled path. A hot-counter policy is a one-`if`
  addition on top and is left to a later wave.

  OWNERSHIP. The code cache is a per-store TWasmJitContext the caller owns
  (RegisterJit returns it). It must be freed BEFORE the store: its teardown
  clears the compiled functions' CompiledEntry pointers and the store's hook
  (so any later call falls back to the interpreter) and munmaps every code
  block. The store has no JIT field to hang teardown on — the interpreter's
  TierContext is the interpreter's — so the context's lifetime is explicit, the
  same discipline the reservation registry uses (blocks freed only when nothing
  can be running, §3.4).

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Depends on the backend
  (Wasm.Jit.Arm64), Wasm.Jit.CodeBuffer, Wasm.Interp (the shared frame helpers),
  Wasm.Ir, and Wasm.Runtime.Store (§12.1). }
unit Wasm.Jit;

{$I Shared.inc}

{ The backend is aarch64-only this wave (§2.1). The unit COMPILES on every
  target (so `lwpt build` stays green on the x86-64 and 32-bit CI legs), but
  JitCanCompile returns False off the supported leg and every function runs
  interpreted. WASM_JIT_EXEC (a 64-bit UNIX host) is recomputed here because
  define symbols do not cross unit boundaries. }
{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  {$DEFINE WASM_JIT_ARM64}
{$ENDIF}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit.CodeBuffer,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

type
  PWasmIrFunctionRec = ^TWasmIrFunction;

  { The per-store JIT context: the code cache. Owns the code blocks it produced
    and the list of functions it flagged compiled, so its teardown can reverse
    both. Confined to the store's thread (ADR-0008); no synchronisation. }
  TWasmJitContext = class
  private
    FStore: TWasmStore;
    FBuffers: array of TWasmCodeBuffer;
    FCompiledAddrs: array of TWasmFuncAddr;
    FHookInstalled: Boolean;
    function IrFunctionFor(const AAddr: TWasmFuncAddr): PWasmIrFunctionRec;
  public
    constructor Create(const AStore: TWasmStore);
    destructor Destroy; override;

    { Compile the function at AAddr regardless of CallCount and install its
      CompiledEntry (§11.1, the harness force-tier control). Returns True if the
      function is now compiled — whether by this call or an earlier one. Returns
      False if the predicate declined it, in which case it stays interpreted,
      which is correct. Idempotent per address: a second call is a no-op. Raises
      only on a genuine internal inconsistency (a predicate-passing op the
      backend then cannot emit). }
    function ForceCompile(const AAddr: TWasmFuncAddr): Boolean;

    property Store: TWasmStore read FStore;
  end;

  { The compiled entry's calling convention (§5.2/§5.3). TWO arguments: the
    register-file base pointer JitEnterFrame returned (@Values[Base]) and the
    store. AAPCS64 passes them in x0 and x1; the Wave-2 prologue moves x0 -> x19
    (the pinned register-file base the templates address as [x19, #k*8]) and
    x1 -> x20 (the store, for the epoch word, §6). cdecl selects the platform C
    convention, matching the backend's hand-emitted prologue/epilogue. }
  TWasmJitCompiledEntry = procedure(const ARegBase: PWasmValue;
    const AStore: TWasmStore); cdecl;

{ Register the JIT on AStore: allocate the code cache and point the store's
  JitInvokeCompiled hook at JitDispatch, leaving TierInvoke on the interpreter
  (§4.1 — the interpreter stays the entry dispatcher; the JIT is reached through
  CompiledEntry). Returns the context the CALLER owns and must free before the
  store. Idempotent-ish: a second call returns a fresh context and re-points the
  hook; normal use is once per store. }
function RegisterJit(const AStore: TWasmStore): TWasmJitContext;

{ The compile predicate and scope fence (§10.3): True only if the active backend
  can emit EVERY op in the function AND the frame fits the backend's addressing.
  False for any un-templated op (EH, v128, un-implemented ops), an over-large
  frame, or an unsupported target — the function then runs interpreted. }
function JitCanCompile(const AFn: PWasmIrFunctionRec): Boolean;

{ Convenience wrapper: force-compile AAddr on AJit (delegates to the method). }
function JitForceCompile(const AJit: TWasmJitContext;
  const AAddr: TWasmFuncAddr): Boolean;

implementation

uses
  {$IFDEF WASM_JIT_ARM64}
  Wasm.Jit.Arm64,
  {$ENDIF}
  Wasm.Runtime.Traps;

{ --- the compiled-function dispatcher (the JitInvokeCompiled hook) --------

  Signature is TWasmJitInvokeProc (Wasm.Runtime.Store). Reached from the
  interpreter's top-level entry (InterpTierInvoke) and from every wasm-callee
  seam (CompiledCall / ReturnCompiledCall) when CompiledEntry <> nil — always
  inside the per-invocation trampoline (ADR-0009), so a stack-exhaustion trap
  from JitEnterFrame unwinds correctly. Builds the frame, runs the machine code
  over the in-memory register file, marshals the results out. }
procedure JitDispatch(const AStore: TWasmStore; const AFuncAddr: TWasmFuncAddr;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: PWasmInterpContext;
  Base: PWasmValue;
  Entry: TWasmJitCompiledEntry;
begin
  Ctx := InterpContextFor(AStore);
  { Carve + zero + marshal params + push the GC frame; returns the register-file
    base. Identical to the interpreter's own entry (both call this). }
  Base := JitEnterFrame(Ctx, AStore, AFuncAddr, AParams, AResults);
  { Run the native code. It reads params from slots, writes the result
    register(s), and returns — touching ONLY the in-memory register file, so the
    frame + GC contract is exactly the interpreter's. }
  Entry := TWasmJitCompiledEntry(AStore.Funcs[AFuncAddr].CompiledEntry);
  Entry(Base, AStore);
  { Marshal the result slots into AResults and pop the frame (the same
    result-marshal/pop iroReturn uses on an entry frame). }
  JitLeaveFrame(Ctx);
end;

{ --- the predicate (§10.3) ----------------------------------------------- }

function JitCanCompile(const AFn: PWasmIrFunctionRec): Boolean;
{$IFDEF WASM_JIT_ARM64}
var
  I: Integer;
{$ENDIF}
begin
  {$IFDEF WASM_JIT_ARM64}
  Result := False;
  if AFn = nil then
    Exit;
  { The frame must fit the backend's scaled-offset addressing (§10.3). }
  if AFn^.RegisterCount > ARM64_MAX_SLOT then
    Exit;
  { Every op must have a template. The FIRST un-templated op declines the whole
    function — the scope fence that keeps the baseline shippable while op
    coverage is partial. }
  for I := 0 to High(AFn^.Code) do
    if not Arm64CanEmitOp(AFn^.Code[I].Op) then
      Exit;
  Result := True;
  {$ELSE}
  { No backend for this target: everything runs interpreted (§2.2). AFn is a
    const param, so an unused one on this leg draws no warning. }
  Result := False;
  {$ENDIF}
end;

{ --- compilation --------------------------------------------------------- }

{$IFDEF WASM_JIT_ARM64}
{ Single-pass template walk (§1.1/§4.3/§5). Emit the Wave-2 frame prologue and
  the epoch snapshot capture (§6), then walk Fn^.Code once emitting each op's
  template. Control flow is resolved with the CodeBuffer label map: one label
  per IR instruction, bound (in order) at the native offset where that
  instruction's code begins, so the branch templates can reference a target
  instruction's label by its IR index directly — forward and backward branches
  alike. After the walk every label is bound; Arm64ResolvePatches back-patches
  the branch words while the buffer is still writable; then it is made
  executable. iroReturn emits the epilogue, so the prologue's saves are always
  balanced by a restore. }
function JitCompileToBuffer(const AFn: PWasmIrFunctionRec;
  const AEpochOffset, ASnapshotOffset: NativeUInt): TWasmCodeBuffer;
var
  I: Integer;
  Buf: TWasmCodeBuffer;
begin
  Result := TWasmCodeBuffer.Create;
  Buf := Result;
  try
    { One label per IR instruction, created in order so label id = IR index
      (the invariant the branch templates rely on). }
    for I := 0 to High(AFn^.Code) do
      Buf.NewLabel;

    Arm64EmitPrologue(Buf);
    Arm64EmitEpochCapture(Buf, AEpochOffset, ASnapshotOffset);

    for I := 0 to High(AFn^.Code) do
    begin
      Buf.BindLabel(TWasmJitLabel(I));
      if not Arm64EmitOp(Buf, AFn^.Code[I], AFn^.AuxU32) then
        { The predicate guaranteed every op is emittable; reaching here is an
          internal inconsistency, not a fall-back path. }
        raise EWasmError.CreateFmt(
          'internal: JIT predicate passed but op %d has no template',
          [Ord(AFn^.Code[I].Op)]);
    end;

    Arm64ResolvePatches(Buf);
    Buf.MakeExecutable;
  except
    Result.Free;
    raise;
  end;
end;
{$ENDIF}

{ --- TWasmJitContext ----------------------------------------------------- }

constructor TWasmJitContext.Create(const AStore: TWasmStore);
begin
  inherited Create;
  FStore := AStore;
  FBuffers := nil;
  FCompiledAddrs := nil;
  FHookInstalled := False;
end;

destructor TWasmJitContext.Destroy;
var
  I: Integer;
begin
  { Reverse everything this context did, while the store is still whole (freed
    before the store per the ownership contract): drop the compiled entries so
    any later call falls back to the interpreter, then the hook, then munmap the
    code blocks. }
  if FStore <> nil then
  begin
    for I := 0 to High(FCompiledAddrs) do
      if FCompiledAddrs[I] <= High(FStore.Funcs) then
        FStore.Funcs[FCompiledAddrs[I]].CompiledEntry := nil;
    { We installed the hook (RegisterJit); clear it so a later call finds no
      dispatcher and runs interpreted. Normal use is one JIT context per store,
      so an unconditional clear is correct. }
    if FHookInstalled then
      FStore.JitInvokeCompiled := nil;
  end;
  for I := 0 to High(FBuffers) do
    FBuffers[I].Free;
  FBuffers := nil;
  FCompiledAddrs := nil;
  inherited Destroy;
end;

function TWasmJitContext.IrFunctionFor(
  const AAddr: TWasmFuncAddr): PWasmIrFunctionRec;
var
  Inst: TWasmModuleInstance;
begin
  Inst := FStore.Funcs[AAddr].Instance;
  Result := @Inst.Ir.Functions[FStore.Funcs[AAddr].FuncIrIndex];
end;

function TWasmJitContext.ForceCompile(const AAddr: TWasmFuncAddr): Boolean;
var
  Fn: PWasmIrFunctionRec;
  {$IFDEF WASM_JIT_ARM64}
  N: Integer;
  {$ENDIF}
begin
  Result := False;
  if AAddr > High(FStore.Funcs) then
    Exit;
  { Only a wasm function has IR to compile; a host function has no body. }
  if FStore.Funcs[AAddr].Kind <> wfkWasm then
    Exit;
  { Already compiled — idempotent. }
  if FStore.Funcs[AAddr].CompiledEntry <> nil then
  begin
    Result := True;
    Exit;
  end;

  Fn := IrFunctionFor(AAddr);
  if not JitCanCompile(Fn) then
    Exit;

  {$IFDEF WASM_JIT_ARM64}
  N := Length(FBuffers);
  SetLength(FBuffers, N + 1);
  FBuffers[N] := nil;
  { The epoch words' byte offsets from the store object pointer — read from the
    live record layout (O-J5, WasmJitOffsets) so a store-layout change is caught
    rather than miscompiled. The prologue reloads the LIVE Store.Epoch at
    StoreEpoch and captures the SHARED per-invocation snapshot at
    StoreEpochSnapshot (jit-spec §6). A function whose branch displacements
    overflow the A64 immediate fields raises EWasmJitBranchRange from the patch
    resolver; catch it, drop the half-built buffer, and DECLINE — the function
    then stays interpreted, which is always correct (jit-spec §4.3). Any other
    exception is a genuine internal fault and propagates. }
  try
    FBuffers[N] := JitCompileToBuffer(Fn, WasmJitOffsets(FStore).StoreEpoch,
      WasmJitOffsets(FStore).StoreEpochSnapshot);
  except
    on EWasmJitBranchRange do
    begin
      { JitCompileToBuffer already freed the buffer before re-raising. }
      SetLength(FBuffers, N);
      Result := False;
      Exit;
    end;
  end;

  FStore.Funcs[AAddr].CompiledEntry := FBuffers[N].EntryPoint;

  N := Length(FCompiledAddrs);
  SetLength(FCompiledAddrs, N + 1);
  FCompiledAddrs[N] := AAddr;
  Result := True;
  {$ELSE}
  { Off the supported leg JitCanCompile already returned False above, so this
    point is unreachable; Result stays False and the function runs interpreted. }
  {$ENDIF}
end;

{ --- registration -------------------------------------------------------- }

function RegisterJit(const AStore: TWasmStore): TWasmJitContext;
begin
  { TEARDOWN ORDER (jit-spec §3.4): the returned context MUST be freed BEFORE
    the store. Its destructor reaches back into the still-whole store to clear
    the compiled entries and the hook; freeing the store first would leave
    those dangling. The store has no field to hang this on (TierContext is the
    interpreter's), so the ordering is the caller's explicit responsibility. }
  Result := TWasmJitContext.Create(AStore);
  { Point the store's compiled-invocation hook at our dispatcher. The
    interpreter checks CompiledEntry <> nil AND Assigned(JitInvokeCompiled) at
    every seam, so until a function is actually compiled nothing changes. }
  AStore.JitInvokeCompiled := @JitDispatch;
  Result.FHookInstalled := True;
end;

function JitForceCompile(const AJit: TWasmJitContext;
  const AAddr: TWasmFuncAddr): Boolean;
begin
  Result := AJit.ForceCompile(AAddr);
end;

end.
