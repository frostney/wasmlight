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

  WAVE 3 CHANGES EXACTLY TWO THINGS HERE. (1) JitDispatch delegates to the
  backend's Arm64InvokeCompiled, because a compiled body may end in a
  `return_call*` and the frame replacement has to run in a LOOP rather than a
  native call to keep tail calls O(1) (§4.5) — the frame is still built and torn
  down by the shared Wasm.Interp helpers, so the hand-off contract above is
  unchanged. (2) The predicate gains two EH fences: a function carrying a
  `try_table` handler table declines (JitCanCompile), and — where the store has
  tags at all — a function containing a CALL declines (ForceCompile). Both exist
  because exception delivery is an explicit unwind over the activation stack
  that cannot pass a tier-seam frame; see the comment on the second fence for
  the interp-side change that would retire them.

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
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUX86_64)}
  {$DEFINE WASM_JIT_X64}
{$ENDIF}
{ One symbol for the backend-agnostic driver logic (frame carve, label map,
  patch resolve, compile predicate): defined when EITHER backend is active, so
  the shared code selects Arm64* vs X64* calls with a nested backend ifdef. }
{$IF DEFINED(WASM_JIT_ARM64) OR DEFINED(WASM_JIT_X64)}
  {$DEFINE WASM_JIT_BACKEND}
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

  { The compiled entry's calling convention (§5.2/§5.3, aot-spec §1.3/§4.3).
    THREE arguments now: the register-file base pointer JitEnterFrame returned
    (@Values[Base]), the store, and the IR-code base @Fn^.Code[0]. AAPCS64/SysV
    pass them in x0/x1/x2 (rdi/rsi/rdx); the prologue pins the register-file base
    (x19/rbx), the store (x20/r12 — from which it pins &Epoch, the snapshot, and
    the per-process helper-table base), and the IR base (x23/rbp), from which
    every runtime-op template computes @Fn^.Code[i] position-independently. cdecl
    selects the platform C convention, matching the backend's hand-emitted
    prologue/epilogue. }
  TWasmJitCompiledEntry = procedure(const ARegBase: PWasmValue;
    const AStore: TWasmStore; const AIrBase: PWasmIrInstr); cdecl;

{ Register the JIT on AStore: allocate the code cache and point the store's
  JitInvokeCompiled hook at JitDispatch, leaving TierInvoke on the interpreter
  (§4.1 — the interpreter stays the entry dispatcher; the JIT is reached through
  CompiledEntry). Returns the context the CALLER owns and must free before the
  store. Idempotent-ish: a second call returns a fresh context and re-points the
  hook; normal use is once per store. }
function RegisterJit(const AStore: TWasmStore): TWasmJitContext;

{ The compile predicate and scope fence (§10.3): True only if the active backend
  can emit EVERY op in the function AND the frame fits the backend's addressing.
  False for any un-templated op (EH ops, un-implemented ops), an over-large
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
  {$IFDEF WASM_JIT_X64}
  Wasm.Jit.X64,
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
{$IFDEF WASM_JIT_BACKEND}
begin
  { Wave 3: the backend owns the invocation, because a compiled body may end
    in a `return_call*` and the frame replacement + re-dispatch has to happen
    in a LOOP rather than by a native call to keep tail calls O(1) in native
    stack (jit-spec §4.5/§5.2). The loop still builds and tears down every
    frame through the SHARED Wasm.Interp helpers, so the hand-off contract
    described in this unit's header is unchanged — only the "run it once"
    became "run it until no tail call is pending". }
  {$IFDEF WASM_JIT_ARM64}
  Arm64InvokeCompiled(AStore, AFuncAddr, AParams, AResults);
  {$ENDIF}
  {$IFDEF WASM_JIT_X64}
  X64InvokeCompiled(AStore, AFuncAddr, AParams, AResults);
  {$ENDIF}
end;
{$ELSE}
var
  Ctx: PWasmInterpContext;
  Base: PWasmValue;
  Entry: TWasmJitCompiledEntry;
  Inst: TWasmModuleInstance;
  Fn: PWasmIrFunctionRec;
  IrBase: PWasmIrInstr;
begin
  { No backend on this target, so nothing is ever compiled and this is
    unreachable; kept as the plain single-shot hand-off so the unit still
    compiles and documents the (3-arg, position-independent) contract. }
  Ctx := InterpContextFor(AStore);
  Base := JitEnterFrame(Ctx, AStore, AFuncAddr, AParams, AResults,
    ConsumeJitSeamReentry);
  Inst := AStore.Funcs[AFuncAddr].Instance;
  Fn := @Inst.Ir.Functions[AStore.Funcs[AFuncAddr].FuncIrIndex];
  if Length(Fn^.Code) > 0 then
    IrBase := @Fn^.Code[0]
  else
    IrBase := nil;
  Entry := TWasmJitCompiledEntry(AStore.Funcs[AFuncAddr].CompiledEntry);
  Entry(Base, AStore, IrBase);
  JitLeaveFrame(Ctx);
end;
{$ENDIF}

{ --- the predicate (§10.3) ----------------------------------------------- }

function JitCanCompile(const AFn: PWasmIrFunctionRec): Boolean;
{$IFDEF WASM_JIT_BACKEND}
var
  I: Integer;
{$ENDIF}
begin
  {$IFDEF WASM_JIT_BACKEND}
  Result := False;
  if AFn = nil then
    Exit;
  { The frame must fit the backend's slot addressing (§10.3). }
  {$IFDEF WASM_JIT_ARM64}
  if AFn^.RegisterCount > ARM64_MAX_SLOT then
    Exit;
  {$ENDIF}
  {$IFDEF WASM_JIT_X64}
  if AFn^.RegisterCount > X64_MAX_SLOT then
    Exit;
  {$ENDIF}
  { EXCEPTION HANDLING IS NEVER COMPILED (§8.3, §10.2) — and a `try_table`
    emits NO instruction: the validator lowers it to the static handler table
    hanging off the function, so the per-op predicate cannot see it. Before
    Wave 3 that was invisible (a handler-bearing function is only interesting
    when something inside it can throw, which needs a call), but a compiled
    body consults no handler table, so an exception thrown under it would
    escape a try_table the interpreter catches. Any handler declines the
    function, which then runs interpreted and catches exactly as before. }
  if Length(AFn^.Handlers) > 0 then
    Exit;
  { Every op must have a template, and every instruction must be one this
    template can actually emit (a call site's marshaling has to fit the
    backend's scratch, §4.4). The FIRST failure declines the whole function —
    the scope fence that keeps the baseline shippable while op coverage is
    partial. }
  for I := 0 to High(AFn^.Code) do
  begin
    {$IFDEF WASM_JIT_ARM64}
    if not Arm64CanEmitOp(AFn^.Code[I].Op) then
      Exit;
    if not Arm64CanEmitInstr(AFn^.Code[I], AFn^.AuxU32) then
      Exit;
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    if not X64CanEmitOp(AFn^.Code[I].Op) then
      Exit;
    if not X64CanEmitInstr(AFn^.Code[I], AFn^.AuxU32) then
      Exit;
    {$ENDIF}
  end;
  Result := True;
  {$ELSE}
  { No backend for this target: everything runs interpreted (§2.2). AFn is a
    const param, so an unused one on this leg draws no warning. }
  Result := False;
  {$ENDIF}
end;

{ --- compilation --------------------------------------------------------- }

{$IFDEF WASM_JIT_BACKEND}
{ Single-pass template walk (§1.1/§4.3/§5). Emit the Wave-2 frame prologue and
  the epoch snapshot capture (§6), then walk Fn^.Code once emitting each op's
  template. Control flow is resolved with the CodeBuffer label map: one label
  per IR instruction, bound (in order) at the native offset where that
  instruction's code begins, so the branch templates can reference a target
  instruction's label by its IR index directly — forward and backward branches
  alike. After the walk every label is bound; the backend's ResolvePatches
  back-patches the branch words while the buffer is still writable; then it is
  made executable. iroReturn emits the epilogue, so the prologue's saves are
  always balanced by a restore. The Arm64* / X64* calls are the only
  backend-specific part; everything else is shared. }
function JitCompileToBuffer(const AFn: PWasmIrFunctionRec;
  const AEpochOffset, ASnapshotOffset, AHelperTableOffset: NativeUInt): TWasmCodeBuffer;
var
  I: Integer;
  Buf: TWasmCodeBuffer;
  Emitted: Boolean;
begin
  Result := TWasmCodeBuffer.Create;
  Buf := Result;
  try
    { One label per IR instruction, created in order so label id = IR index
      (the invariant the branch templates rely on). }
    for I := 0 to High(AFn^.Code) do
      Buf.NewLabel;

    {$IFDEF WASM_JIT_ARM64}
    Arm64EmitPrologue(Buf);
    Arm64EmitPinHelperTable(Buf, AHelperTableOffset);
    Arm64EmitEpochCapture(Buf, AEpochOffset, ASnapshotOffset);
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    X64EmitPrologue(Buf);
    X64EmitPinHelperTable(Buf, AHelperTableOffset);
    X64EmitEpochCapture(Buf, AEpochOffset, ASnapshotOffset);
    {$ENDIF}

    for I := 0 to High(AFn^.Code) do
    begin
      Buf.BindLabel(TWasmJitLabel(I));
      { Position-independent IR reference (aot-spec §1.3): pass the instruction
        INDEX; the runtime-op templates compute @Fn^.Code[i] from the pinned IR
        base (x23/rbp), which the entry receives freshly per invocation — no
        heap IR pointer is ever baked. }
      {$IFDEF WASM_JIT_ARM64}
      Emitted := Arm64EmitOp(Buf, AFn^.Code[I], AFn^.AuxU32, UInt32(I));
      {$ENDIF}
      {$IFDEF WASM_JIT_X64}
      Emitted := X64EmitOp(Buf, AFn^.Code[I], AFn^.AuxU32, UInt32(I));
      {$ENDIF}
      if not Emitted then
        { The predicate guaranteed every op is emittable; reaching here is an
          internal inconsistency, not a fall-back path. }
        raise EWasmError.CreateFmt(
          'internal: JIT predicate passed but op %d has no template',
          [Ord(AFn^.Code[I].Op)]);
    end;

    {$IFDEF WASM_JIT_ARM64}
    Arm64ResolvePatches(Buf);
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    X64ResolvePatches(Buf);
    {$ENDIF}
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
  {$IFDEF WASM_JIT_BACKEND}
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
  { FENCE 2 IS RETIRED (Fix A). It used to decline a call-bearing function
    whenever the store had tags, because a compiled frame between a `throw` and
    an interpreted `try_table` handler would surface as 'uncaught exception': the
    unwind stopped at the compiled seam frame (an rtEntry boundary). The interp
    side now gives tier-seam frames the rtCompiledSeam kind, which the unwind
    treats as TRANSPARENT — it pops the frame and hops (a LongJmp to a seam
    catch) across the native barrier to the enclosing invocation's seam catch, continuing the
    search for a handler further out (Wasm.Interp.UnwindException). So a compiled
    call-bearing function may correctly sit between a throw and its handler, and
    more functions compile (compiled=N goes up). Fence 1 (JitCanCompile declines
    a function that OWNS a try_table handler table, since its handlers are not in
    machine code) and the iroThrow/iroThrowRef decline STAY. }
  {$IFDEF WASM_JIT_BACKEND}
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
      WasmJitOffsets(FStore).StoreEpochSnapshot,
      WasmJitOffsets(FStore).StoreJitHelperTable);
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
  { Fill the per-process helper table with THIS process's live helper addresses
    and pin its base on the store (aot-spec §1.2/§4.3), so every compiled body's
    indirect helper calls resolve. The addresses are process-global constants,
    so a single fill serves every store. }
  {$IFDEF WASM_JIT_ARM64}
  AStore.JitHelperTable := Arm64GetHelperTable;
  {$ENDIF}
  {$IFDEF WASM_JIT_X64}
  AStore.JitHelperTable := X64GetHelperTable;
  {$ENDIF}
  Result.FHookInstalled := True;
end;

function JitForceCompile(const AJit: TWasmJitContext;
  const AAddr: TWasmFuncAddr): Boolean;
begin
  Result := AJit.ForceCompile(AAddr);
end;

end.
