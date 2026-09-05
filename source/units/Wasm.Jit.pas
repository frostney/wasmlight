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

  THE HAND-OFF (§5.1, the frame IS the interpreter's frame). JitDispatch builds
  an entry frame, and a generic direct compiled call reaches the same logic through
  JitPrepareDirectCall — exhaustion check, register-file carve,
  zero, param marshal, GC-frame push — which returns @Values[Base], the
  register-file base. It passes that base to the compiled entry in the first
  argument register (x0 on AAPCS64); the compiled body reads and writes ONLY the
  in-memory register file (Reg[k] = base + k*8) and returns; then
  JitLeaveFrame/JitFinishDirectCall marshal the result slots out and pop it.
  Because the carve/zero/push/pop and the param/result marshaling are the
  interpreter's exact code, the exhaustion threshold, the GC contract, and the
  flat-slot calling convention are identical by construction — the observational
  -identity property (§13). It passes that base and the store to the compiled
  entry in x0/x1 (AAPCS64); the Wave-2 prologue pins the base in the callee-
  saved x19 (surviving helper calls) and the store in x20 (for the epoch word),
  and the epilogue restores them before returning to JitLeaveFrame.

  The one narrow exception is the proof-gated AArch64 scalar self-call path:
  a closed helper-free numeric function uses a native-stack register file for
  recursion and edits only the shared Depth/ValueTop counters. Its external
  AAPCS wrapper saves and pins the full callee-saved state once, then calls a
  local position-independent core; recursion preserves only x19/LR beside the
  native register file. The wrapper pins the exact remaining depth/value-frame
  budget in x26; recursion checks and adjusts it without publishing counters.
  Ordinary calls do not invent epoch safepoints, while IR-marked loop
  back-edges still poll;
  references, allocation, handlers, host/interpreted escape, indirect/tail
  calls, and cross-function calls all retain the full shared-frame path above.

  WAVE 3 CHANGES EXACTLY TWO THINGS HERE. (1) JitDispatch delegates to the
  backend's Arm64InvokeCompiled, because a compiled body may end in a
  `return_call*` and the frame replacement has to run in a LOOP rather than a
  native call to keep tail calls O(1) (§4.5) — the frame is still built and torn
  down by the shared Wasm.Interp helpers, so the hand-off contract above is
  unchanged. (2) Handler tables and `throw` / `throw_ref` compile. Matching
  stays in UnwindException (tag store-address, eh-spec §2.3/§4). Direct
  compiled-to-compiled calls still decline handler-bearing and throwing
  functions so each keeps its own InvokeCompiled seam.

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
  Wasm.Runtime.Values,
  Wasm.Target;

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

    { Adopt already-compiled, position-independent machine code (aot-spec §4.2
      step 4/5) instead of compiling it here: map ACode executable through the
      SAME Wasm.Jit.CodeBuffer W^X + cache-flush path a JIT compile uses, then
      wire the function's CompiledEntry to the loaded region's entry
      (EntryPoint + AEntryOffset). The bytes are the artifact's — the AOT loader
      produced them by serializing exactly what JitCompileToBuffer would have
      emitted (the unified emitter, §1.2/§1.3), so the loaded code runs through
      the same JitDispatch / *InvokeCompiled path with the same helper table and
      pinned IR base. Returns True when wired. Idempotent per address (a second
      call for an already-compiled addr is a no-op that returns True). Off the
      backend / on an unsupported host it returns False and the function stays
      interpreted, which is always correct. }
    function LoadPrecompiled(const AAddr: TWasmFuncAddr;
      const ACode: TWasmBytes; const AEntryOffset: NativeUInt): Boolean;

    property Store: TWasmStore read FStore;
  end;

  { The backend-free compiled-entry declaration. It receives the
    register-file base pointer JitEnterFrame returned (@Values[Base]), the
    store, and the IR-code base @Fn^.Code[0]. The AArch64 backend extends this
    private ABI with additional generated-call state; each backend's local
    declaration is fingerprinted with the AOT ABI.
    cdecl selects the platform C convention, matching each backend's
    hand-emitted prologue/epilogue. }
  TWasmJitCompiledEntry = procedure(const ARegBase: PWasmValue;
    const AStore: TWasmStore; const AIrBase: PWasmIrInstr); cdecl;

  { Why JitCanCompile would refuse AFn. jdNone means the function is inside
    the current fence; every other value is the first failing check, in the
    same order JitCanCompile walks. AOT's strict path uses this so a decline
    names the reason instead of collapsing to "not compiled". }
  TWasmJitDecline = (
    jdNone,
    jdNoBackend,
    jdNilFunction,
    jdFrameTooLarge,
    jdExceptionHandling,
    jdUnsupportedOp,
    jdUnsupportedInstr
  );

{ Register the JIT on AStore: allocate the code cache and point the store's
  JitInvokeCompiled hook at JitDispatch, leaving TierInvoke on the interpreter
  (§4.1 — the interpreter stays the entry dispatcher; the JIT is reached through
  CompiledEntry). Returns the context the CALLER owns and must free before the
  store. Idempotent-ish: a second call returns a fresh context and re-points the
  hook; normal use is once per store. }
function RegisterJit(const AStore: TWasmStore): TWasmJitContext;

function JitCompileDecline(const AFn: PWasmIrFunctionRec): TWasmJitDecline;

{ The compile predicate and scope fence (§10.3): True only if the active backend
  can emit EVERY op in the function. False for EH ops / handler tables
  (issue #32), an unsupported target, or a return_call* past WASM_TIER_TAIL_CAP
  — the function then runs interpreted. Frame size and non-tail call arity
  are encoded: both backends form large slots and large call-scratch frames. }
function JitCanCompile(const AFn: PWasmIrFunctionRec): Boolean;

{ A deliberately narrow proof for the AArch64 native self-call ABI: one
  scalar parameter/result, no default-initialized locals or references, and
  only helper-free numeric/control ops whose direct calls all target the same
  function. Other shapes retain the shared logical-frame call path. }
function JitCanNativeScalarSelf(const AFn: PWasmIrFunctionRec;
  const ASelfFuncIdx: UInt32): Boolean;

{ A bounded cross-function companion for both native backends: a
  one/two-parameter, one-result numeric
  leaf whose body cannot trap, allocate, call, or reach a safepoint. It may use
  a lightweight native-stack frame because no operation inside it can observe
  the temporarily unpublished logical frame. }
function JitCanNativeScalarLeaf(const AFn: PWasmIrFunctionRec): Boolean;

{ Convenience wrapper: force-compile AAddr on AJit (delegates to the method). }
function JitForceCompile(const AJit: TWasmJitContext;
  const AAddr: TWasmFuncAddr): Boolean;

{ Compile AFn to its finalized, branch-resolved, POSITION-INDEPENDENT code bytes
  WITHOUT mapping them executable (aot-spec §3.2) — the blob the AOT artifact
  writer serializes. Returns the bytes (SnapshotBytes), the entry stub's byte
  offset within them (0 — the prologue is first), and the frame's slot count
  (AFn^.RegisterCount, stored so the loader can cross-check the fresh IR). The
  same compilation driver the JIT uses produces these bytes, so AOT-loaded code
  IS the JIT's code. Returns nil (declined) off the backend, for a nil function,
  or when the function is nil / the host has no backend. An out-of-range
  branch is relaxed in the backend; a remaining overflow is an internal
  fault, not a silent decline. }
function JitStageFunctionBytes(const AStore: TWasmStore;
  const AFn: PWasmIrFunctionRec; out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes; overload;
function JitStageFunctionBytes(const AStore: TWasmStore;
  const AFn: PWasmIrFunctionRec; const AFuncIdx: UInt32;
  out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes; overload;
function JitStageFunctionBytes(const AStore: TWasmStore;
  const AIr: TWasmIrModule; const AFn: PWasmIrFunctionRec;
  const AFuncIdx: UInt32; out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes; overload;
function JitStageFunctionBytes(const AStore: TWasmStore;
  const AIr: TWasmIrModule; const AFn: PWasmIrFunctionRec;
  const AFuncIdx: UInt32; const ATarget: TWasmTarget;
  out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes; overload;

{ True when the requested target's ISA can be emitted and AFn passes the
  host compile predicate. Foreign-OS same-arch targets are emittable;
  foreign-ISA targets decline until both backends are runtime-selectable. }
function JitCanEmitForTarget(const AFn: PWasmIrFunctionRec;
  const ATarget: TWasmTarget): Boolean;

implementation

uses
  {$IFDEF WASM_JIT_ARM64}
  Wasm.Jit.Arm64,
  {$ENDIF}
  {$IFDEF WASM_JIT_X64}
  Wasm.Jit.X64,
  {$ENDIF}
  Wasm.Runtime.Gc,
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

function JitCanDirectCall(const AFn: PWasmIrFunctionRec): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AFn = nil then
    Exit;
  { A handler-bearing or throwing function needs its own InvokeCompiled seam
    so a matched clause can resume at a landing pad without returning through
    a popped native frame. Tail calls already decline this path. }
  if Length(AFn^.Handlers) > 0 then
    Exit;
  for I := 0 to High(AFn^.Code) do
    if AFn^.Code[I].Op in
      [iroReturnCall, iroReturnCallIndirect, iroReturnCallRef,
       iroThrow, iroThrowRef] then
      Exit;
  Result := True;
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
    unreachable; kept as the plain single-shot hand-off. }
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

function JitCompileDecline(const AFn: PWasmIrFunctionRec): TWasmJitDecline;
{$IFDEF WASM_JIT_BACKEND}
var
  I: Integer;
{$ENDIF}
begin
  {$IFDEF WASM_JIT_BACKEND}
  if AFn = nil then
    Exit(jdNilFunction);
  { Handler tables compile: throw / throw_ref have templates, and
    UnwindException scans the same IR table the interpreter uses (tag
    store-address matching, eh-spec §2.3/§4). Native scalar fast paths still
    decline handlers — they have no helper/seam to resume a clause. }
  { Every op must have a template, and every instruction must be one this
    template can actually emit. Frame size and non-tail call arity are
    encoded, not declined. The remaining fence is a `return_call*` whose
    argument block exceeds the shared tail channel, or an op with no
    template. }
  for I := 0 to High(AFn^.Code) do
  begin
    {$IFDEF WASM_JIT_ARM64}
    if not Arm64CanEmitOp(AFn^.Code[I].Op) then
      Exit(jdUnsupportedOp);
    if not Arm64CanEmitInstr(AFn^.Code[I], AFn^.AuxU32) then
      Exit(jdUnsupportedInstr);
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    if not X64CanEmitOp(AFn^.Code[I].Op) then
      Exit(jdUnsupportedOp);
    if not X64CanEmitInstr(AFn^.Code[I], AFn^.AuxU32) then
      Exit(jdUnsupportedInstr);
    {$ENDIF}
  end;
  Result := jdNone;
  {$ELSE}
  { No backend for this target: everything runs interpreted (§2.2). AFn is a
    const param, so an unused one on this leg draws no warning. }
  Result := jdNoBackend;
  {$ENDIF}
end;

function JitCanCompile(const AFn: PWasmIrFunctionRec): Boolean;
begin
  Result := JitCompileDecline(AFn) = jdNone;
end;

function JitCanNativeScalarSelf(const AFn: PWasmIrFunctionRec;
  const ASelfFuncIdx: UInt32): Boolean;
var
  I: Integer;
  Ins: TWasmIrInstr;
  HasSelfCall: Boolean;
begin
  Result := False;
  {$IFDEF WASM_JIT_BACKEND}
  if (AFn = nil) or (AFn^.ParamCount <> 1) or (AFn^.ResultCount <> 1) or
    (Length(AFn^.LocalRegs) <> 1) or (Length(AFn^.ResultRegs) <> 1) or
    (Length(AFn^.EntryZeroRegs) <> 0) or (Length(AFn^.Handlers) <> 0) or
    (AFn^.RegisterCount = 0) or (AFn^.RegisterCount > 32) then
    Exit;
  for I := 0 to High(AFn^.RegTypes) do
    if AFn^.RegTypes[I].Kind <> wvkNum then
      Exit;
  HasSelfCall := False;
  for I := 0 to High(AFn^.Code) do
  begin
    Ins := AFn^.Code[I];
    case Ins.Op of
      iroMove, iroJump, iroBranchIf, iroBranchIfNot, iroReturn,
      iroI32Const, iroI64Const, iroF32Const, iroF64Const,
      iroI32Eqz, iroI64Eqz,
      iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
      iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
      iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
      iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
      iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
      iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
      iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
      iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr,
      iroSelect:;
      iroCall:
        begin
          if (UInt32(Ins.Imm) <> ASelfFuncIdx) or
            (IrAuxBlockCount(AFn^.AuxU32, Ins.A) <> 1) or
            (IrAuxBlockCount(AFn^.AuxU32, Ins.B) <> 1) then
            Exit;
          HasSelfCall := True;
        end;
    else
      Exit;
    end;
  end;
  Result := HasSelfCall;
  {$ENDIF}
end;

function JitCanNativeScalarLeaf(const AFn: PWasmIrFunctionRec): Boolean;
var
  I: Integer;
begin
  Result := False;
  {$IFDEF WASM_JIT_BACKEND}
  if (AFn = nil) or (AFn^.ParamCount < 1) or (AFn^.ParamCount > 2) or
    (AFn^.ResultCount <> 1) or
    (Length(AFn^.LocalRegs) <> Integer(AFn^.ParamCount)) or
    (Length(AFn^.ResultRegs) <> 1) or
    (Length(AFn^.EntryZeroRegs) <> 0) or (Length(AFn^.Handlers) <> 0) or
    (AFn^.RegisterCount = 0) or (AFn^.RegisterCount > 32) then
    Exit;
  for I := 0 to High(AFn^.RegTypes) do
    if AFn^.RegTypes[I].Kind <> wvkNum then
      Exit;
  for I := 0 to High(AFn^.Code) do
    case AFn^.Code[I].Op of
      iroMove, iroReturn,
      iroI32Const, iroI64Const,
      iroI32Eqz, iroI64Eqz,
      iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
      iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
      iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
      iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
      iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
      iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
      iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
      iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr,
      iroSelect:;
    else
      Exit;
    end;
  Result := True;
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
function JitCompileToBuffer(const AIr: TWasmIrModule;
  const AFn: PWasmIrFunctionRec;
  const AFuncIdx: UInt32;
  const AEpochOffset, ASnapshotOffset, AHelperTableOffset: NativeUInt;
  const AFinalize: Boolean = True): TWasmCodeBuffer;
var
  I, J: Integer;
  Buf: TWasmCodeBuffer;
  Emitted: Boolean;
  Targets: array of Boolean;
  TargetCount: UInt32;
  AllocatedSlots: array[0..2] of UInt32;
  SlotScores: array of UInt32;
  SlotUseCounts: array of UInt32;
  VisibleSlots: array of Boolean;
  Fusion: array of Integer;
  PlannedCode: TWasmIrCode;
  SkipPlanned: array of Boolean;
  ImmediateFusion: array of Boolean;
  ImmediateValues: array of UInt32;
  MaskedShiftSource: array of Integer;
  MaskedShiftShape: array of UInt32;
  UseStaticCache: Boolean;
  UseThirdStatic: Boolean;
  ConstSlots: array[0..0] of UInt32;
  ConstSlotBits: array[0..0] of UInt64;
  GcShapes: array of UInt64;
  {$IFDEF WASM_JIT_ARM64}
  GcAllocShapes: array of TWasmGcAllocShape;
  GcAllocInfo: TWasmGcAllocInfo;
  {$ENDIF}
  UsePinnedMemory: Boolean;
  UsePinnedMemoryBase: Boolean;
  PinnedMemoryIndex: UInt32;
  UseNativeScalarSelf: Boolean;
  UseNativeScalarLeaf: Boolean;
  UseNativeScalarCore: Boolean;
  UseNativeScalarCall: Boolean;
  UseX64ExtendedFrame: Boolean;
  NativeScalarCall: Boolean;
  {$IFDEF WASM_JIT_ARM64}
  InlineBodies: array of TWasmBytes;
  InlineRegisterCounts: array of UInt32;
  InlineResultSlots: array of UInt32;
  InlineArgSlots: array of array[0..1] of UInt32;
  NativeResultSource: UInt32;
  UsePreservedInlineCache: Boolean;
  {$ENDIF}
  UseExtendedFrame: Boolean;
  NativeParamCount: UInt32;
  NativeParamReg: UInt32;
  NativeParam1Reg: UInt32;
  NativeResultReg: UInt32;
  NativeCoreLabel: TWasmJitLabel;
  NativeExhaustedLabel: TWasmJitLabel;
  NativeExternalLabel: TWasmJitLabel;
  EhTableLabel: TWasmJitLabel;
  EhEndLabel: TWasmJitLabel;
  HasHandlers: Boolean;
  {$IFDEF WASM_JIT_ARM64}
  ArmCache: TArm64RegCache;
  {$ENDIF}
  {$IFDEF WASM_JIT_X64}
  X64Cache: TX64RegCache;
  {$ENDIF}

  procedure MarkTarget(const ATarget: UInt32);
  begin
    if ATarget < UInt32(Length(Targets)) then
      Targets[ATarget] := True;
  end;

  function IntegerCompare(const AOp: TWasmIrOp): Boolean;
  begin
    Result := AOp in [iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU,
      iroI32GtS, iroI32GtU, iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
      iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
      iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU];
  end;

  function PlannedProducer(const AOp: TWasmIrOp): Boolean;
  begin
    Result := (AOp in [iroI32Const, iroI64Const, iroF32Const, iroF64Const,
      iroI32Eqz, iroI64Eqz, iroI32Add, iroI32Sub, iroI32Mul, iroI32And,
      iroI32Or, iroI32Xor, iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotr,
      iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
      iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotr]) or IntegerCompare(AOp);
  end;

  function SimpleUseCount(const AReg: UInt32): UInt32;
  var
    K: Integer;
  begin
    Result := 0;
    for K := 0 to High(AFn^.Code) do
      case AFn^.Code[K].Op of
        iroMove, iroBranchIf, iroBranchIfNot, iroI32Eqz, iroI64Eqz:
          if AFn^.Code[K].A = AReg then Inc(Result);
        iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
        iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
        iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
        iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
        iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
        iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotr,
        iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
        iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotr:
          begin
            if AFn^.Code[K].A = AReg then Inc(Result);
            if AFn^.Code[K].B = AReg then Inc(Result);
          end;
      end;
  end;

  function RegisterUseCount(const AReg: UInt32): UInt32;
  var
    Info: TWasmIrOpInfo;
    K, N: Integer;

    procedure CountIfSame(const ASource: UInt32);
    begin
      if ASource = AReg then
        Inc(Result);
    end;

  begin
    Result := 0;
    for K := 0 to High(AFn^.Code) do
    begin
      Info := IR_OP_INFO[AFn^.Code[K].Op];
      if Info.DestKind = ifkSrcReg then
        CountIfSame(AFn^.Code[K].Dest);
      if Info.AKind = ifkSrcReg then
        CountIfSame(AFn^.Code[K].A)
      else if Info.AKind = ifkAuxIndex then
        { Every A aux block is a source-register list. B aux blocks carry
          call results or control targets; Imm aux blocks carry literals,
          masks, or memory arguments. }
        for N := 0 to Integer(IrAuxBlockCount(AFn^.AuxU32,
          AFn^.Code[K].A)) - 1 do
          CountIfSame(IrAuxBlockItem(AFn^.AuxU32, AFn^.Code[K].A,
            UInt32(N)));
      if Info.BKind = ifkSrcReg then
        CountIfSame(AFn^.Code[K].B);
      if Info.ImmKind in [ifkSrcReg, ifkSrcRegImm] then
        CountIfSame(UInt32(AFn^.Code[K].Imm));
    end;
  end;

  function IsVisibleFrameReg(const AReg: UInt32): Boolean; forward;

  function NativeScalarLeafTarget(const AFuncIdx: UInt32): Boolean;
  var
    DefinedIdx: UInt32;
  begin
    Result := False;
    if (AIr = nil) or (AFuncIdx < AIr.FuncImportCount) then
      Exit;
    DefinedIdx := AFuncIdx - AIr.FuncImportCount;
    if DefinedIdx >= UInt32(Length(AIr.Functions)) then
      Exit;
    Result := JitCanNativeScalarLeaf(@AIr.Functions[DefinedIdx]);
  end;

  {$IFDEF WASM_JIT_ARM64}
  procedure PrepareInlineBodies;
  var
    K, N, UsedBytes, StartOffset: Integer;
    Target: UInt32;
    Leaf: PWasmIrFunctionRec;
    LeafBuffer: TWasmCodeBuffer;
    Body: TWasmBytes;
    SingleReturn: Boolean;
  begin
    SetLength(InlineBodies, Length(AFn^.Code));
    SetLength(InlineRegisterCounts, Length(AFn^.Code));
    SetLength(InlineResultSlots, Length(AFn^.Code));
    SetLength(InlineArgSlots, Length(AFn^.Code));
    UsedBytes := 0;
    for K := 0 to High(AFn^.Code) do
    begin
      if (AFn^.Code[K].Op <> iroCall) or (UsedBytes >= 256) then
        Continue;
      Target := UInt32(AFn^.Code[K].Imm);
      if not NativeScalarLeafTarget(Target) then
        Continue;
      Leaf := @AIr.Functions[Target - AIr.FuncImportCount];
      if (Length(Leaf^.Code) = 0) or (Length(Leaf^.Code) > 24) or
        (Leaf^.Code[High(Leaf^.Code)].Op <> iroReturn) then
        Continue;
      SingleReturn := True;
      for N := 0 to High(Leaf^.Code) - 1 do
        if Leaf^.Code[N].Op = iroReturn then
          SingleReturn := False;
      if not SingleReturn then
        Continue;
      { A defined funcidx denotes the immutable body in this module, unlike
        an import. Use the existing numeric-leaf proof and emitter; neither a
        live compiled entry nor a store address is part of these semantics
        (pinned core exec-call / exec-invoke). No process pointer is copied. }
      LeafBuffer := JitCompileToBuffer(AIr, Leaf, Target, AEpochOffset,
        ASnapshotOffset, AHelperTableOffset, False);
      try
        StartOffset := LeafBuffer.LabelOffset(0);
        Body := LeafBuffer.SnapshotBytes;
        { All core paths end in exactly one RET. Keep its result move but
          replace the return itself with ordinary caller fallthrough. }
        if (Length(Body) < StartOffset + 4) or
          (Body[High(Body) - 3] <> $C0) or
          (Body[High(Body) - 2] <> $03) or
          (Body[High(Body) - 1] <> $5F) or
          (Body[High(Body)] <> $D6) then
          Continue;
        Body := Copy(Body, StartOffset, Length(Body) - StartOffset - 4);
        if (UsedBytes + Length(Body) > 256) or
          not Arm64CanInlineScalarBody(Body) then
          Continue;
        InlineBodies[K] := Body;
        InlineRegisterCounts[K] := Leaf^.RegisterCount;
        InlineResultSlots[K] := IrAuxBlockItem(AFn^.AuxU32,
          AFn^.Code[K].B, 0);
        for N := 0 to Integer(IrAuxBlockCount(AFn^.AuxU32,
          AFn^.Code[K].A)) - 1 do
          InlineArgSlots[K][N] := IrAuxBlockItem(AFn^.AuxU32,
            AFn^.Code[K].A, UInt32(N));
        Inc(UsedBytes, Length(Body));
      finally
        LeafBuffer.Free;
      end;
    end;
  end;
  {$ENDIF}

  procedure AnalyzeAdjacentMoves;
  var
    K: Integer;
  begin
    SetLength(PlannedCode, Length(AFn^.Code));
    SetLength(SkipPlanned, Length(AFn^.Code));
    for K := 0 to High(AFn^.Code) do
      PlannedCode[K] := AFn^.Code[K];
    {$IFDEF WASM_JIT_ARM64}
    for K := 1 to High(PlannedCode) do
      if (PlannedCode[K].Op = iroMoveVec) and
        Arm64NativeVecOp(PlannedCode[K - 1].Op) and
        (PlannedCode[K - 1].Dest = PlannedCode[K].A) and
        (PlannedCode[K - 1].Dest < UInt32(Length(AFn^.RegTypes))) and
        (AFn^.RegTypes[PlannedCode[K - 1].Dest].Kind = wvkVec) and
        (RegisterUseCount(PlannedCode[K - 1].Dest) = 1) and
        not IsVisibleFrameReg(PlannedCode[K - 1].Dest) and
        IsVisibleFrameReg(PlannedCode[K].Dest) and
        not Targets[K - 1] and not Targets[K] then
      begin
        { A validated expression result is consumed by the immediately
          following lowering move. Store the native Q result in the move's
          canonical local/result slot directly; both IR labels remain bound at
          the same fallthrough point and no vector state crosses an edge. }
        PlannedCode[K - 1].Dest := PlannedCode[K].Dest;
        SkipPlanned[K] := True;
      end;
    {$ENDIF}
    if not UseStaticCache then
      Exit;
    for K := 1 to High(PlannedCode) do
      if (PlannedCode[K].Op = iroMove) and
        PlannedProducer(PlannedCode[K - 1].Op) and
        (PlannedCode[K - 1].Dest = PlannedCode[K].A) and
        (RegisterUseCount(PlannedCode[K].A) = 1) and
        IsVisibleFrameReg(PlannedCode[K].Dest) and
        not Targets[K - 1] and not Targets[K] then
      begin
        { Fold a single-use expression result directly into the local/result
          slot that the following lowering move would populate. Call argument
          aux lists count as uses too: local.tee can feed both. The original
          IR and its instruction labels remain intact; the skipped move binds
          an empty label at the producer's fallthrough address. }
        PlannedCode[K - 1].Dest := PlannedCode[K].Dest;
        SkipPlanned[K] := True;
      end;
  end;

  {$IFDEF WASM_JIT_ARM64}
  procedure AnalyzeResultCopies;
  var
    K, Last: Integer;
    SingleReturn: Boolean;
    ResultSlot: UInt32;
  begin
    NativeResultSource := NativeResultReg;
    Last := High(PlannedCode);
    if UseNativeScalarLeaf and (Last >= 1) and (Last < 24) and
      (PlannedCode[Last].Op = iroReturn) and
      (PlannedCode[Last - 1].Op = iroMove) and
      (PlannedCode[Last - 1].Dest = NativeResultReg) and
      not SkipPlanned[Last - 1] and not Targets[Last - 1] and
      not Targets[Last] then
    begin
      SingleReturn := True;
      for K := 0 to Last - 1 do
        if PlannedCode[K].Op = iroReturn then
          SingleReturn := False;
      if SingleReturn then
      begin
        { The final copy has no intervening instruction or other return path.
          Read its already-planned source into x12 at return; the external
          wrapper still publishes x12 to canonical NativeResultReg. }
        NativeResultSource := PlannedCode[Last - 1].A;
        SkipPlanned[Last - 1] := True;
      end;
    end;
    if not UsePreservedInlineCache then
      Exit;
    for K := 0 to Last - 1 do
      if (Length(InlineBodies[K]) <> 0) and
        (PlannedCode[K + 1].Op = iroMove) and
        not SkipPlanned[K + 1] and not Targets[K] and
        not Targets[K + 1] then
      begin
        ResultSlot := InlineResultSlots[K];
        if (PlannedCode[K + 1].A = ResultSlot) and
          not IsVisibleFrameReg(ResultSlot) and
          IsVisibleFrameReg(PlannedCode[K + 1].Dest) and
          (RegisterUseCount(ResultSlot) = 1) then
        begin
          { The proven body produces one numeric result, used only by this
            adjacent lowering move. Count aux-list uses too; preserve both
            labels and the call's exact capacity checks before computation. }
          InlineResultSlots[K] := PlannedCode[K + 1].Dest;
          SkipPlanned[K + 1] := True;
        end;
      end;
  end;
  {$ENDIF}

  function IsVisibleFrameReg(const AReg: UInt32): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to High(AFn^.LocalRegs) do
      if AFn^.LocalRegs[K] = AReg then
        Exit(True);
    for K := 0 to High(AFn^.ResultRegs) do
      if AFn^.ResultRegs[K] = AReg then
        Exit(True);
    Result := False;
  end;

  procedure AnalyzeFusion;
  var
    K: Integer;
  begin
    SetLength(Fusion, Length(AFn^.Code));
    for K := 0 to High(Fusion) do
      Fusion[K] := -1;
    for K := 0 to High(AFn^.Code) - 1 do
      if IntegerCompare(PlannedCode[K].Op) and
        (PlannedCode[K + 1].Op in [iroBranchIf, iroBranchIfNot]) and
        (PlannedCode[K + 1].A = PlannedCode[K].Dest) and
        not SkipPlanned[K] and not SkipPlanned[K + 1] and
        not Targets[K] and not Targets[K + 1] and
        not IsVisibleFrameReg(PlannedCode[K].Dest) then
      begin
        { Validation allocates expression temporaries monotonically. An
          immediately consumed compare result cannot be named again, so the
          codegen plan may keep it in flags without changing the canonical IR
          or any instruction-index label. }
        Fusion[K] := -2;
        Fusion[K + 1] := K;
      end;
  end;

  procedure AnalyzeImmediateFusion;
  var
    K: Integer;
    Value: UInt32;
  begin
    SetLength(ImmediateFusion, Length(AFn^.Code));
    SetLength(ImmediateValues, Length(AFn^.Code));
    {$IFDEF WASM_JIT_ARM64}
    { Keep this narrower than general constant folding: only helper-free,
      base-pinned scalar-memory loops may erase an adjacent single-use
      i32.const. Broad loop folding previously regressed nonlinear code. }
    if not (UsePinnedMemoryBase and UseStaticCache) then
      Exit;
    for K := 0 to High(PlannedCode) - 1 do
      if (PlannedCode[K].Op = iroI32Const) and
        (PlannedCode[K + 1].B = PlannedCode[K].Dest) and
        (SimpleUseCount(PlannedCode[K].Dest) = 1) and
        not IsVisibleFrameReg(PlannedCode[K].Dest) and
        not SkipPlanned[K] and not SkipPlanned[K + 1] and
        not Targets[K] and not Targets[K + 1] then
      begin
        Value := UInt32(PlannedCode[K].Imm and $FFFFFFFF);
        if Arm64CanUseI32Immediate(PlannedCode[K + 1].Op, Value) then
        begin
          SkipPlanned[K] := True;
          ImmediateFusion[K + 1] := True;
          ImmediateValues[K + 1] := Value;
        end;
      end;
    {$ENDIF}
  end;

  {$IFDEF WASM_JIT_ARM64}
  procedure AnalyzeMaskedShiftFusion;
  var
    K, Width: Integer;
    Mask, Shift: UInt32;
    Source: UInt32;
  begin
    SetLength(MaskedShiftSource, Length(PlannedCode));
    SetLength(MaskedShiftShape, Length(PlannedCode));
    for K := 0 to High(MaskedShiftSource) do
      MaskedShiftSource[K] := -1;
    for K := 0 to High(PlannedCode) - 3 do
      if (PlannedCode[K].Op = iroI32Const) and
        (PlannedCode[K + 1].Op = iroI32And) and
        (PlannedCode[K + 2].Op = iroI32Const) and
        (PlannedCode[K + 3].Op = iroI32Shl) and
        not SkipPlanned[K] and not SkipPlanned[K + 1] and
        not SkipPlanned[K + 2] and not SkipPlanned[K + 3] and
        not Targets[K] and not Targets[K + 1] and
        not Targets[K + 2] and not Targets[K + 3] and
        (SimpleUseCount(PlannedCode[K].Dest) = 1) and
        (SimpleUseCount(PlannedCode[K + 1].Dest) = 1) and
        (SimpleUseCount(PlannedCode[K + 2].Dest) = 1) and
        (PlannedCode[K + 1].Dest = PlannedCode[K + 3].A) and
        (PlannedCode[K + 2].Dest = PlannedCode[K + 3].B) and
        not IsVisibleFrameReg(PlannedCode[K].Dest) and
        not IsVisibleFrameReg(PlannedCode[K + 1].Dest) and
        not IsVisibleFrameReg(PlannedCode[K + 2].Dest) then
      begin
        if PlannedCode[K + 1].A = PlannedCode[K].Dest then
          Source := PlannedCode[K + 1].B
        else if PlannedCode[K + 1].B = PlannedCode[K].Dest then
          Source := PlannedCode[K + 1].A
        else
          Continue;
        Mask := UInt32(PlannedCode[K].Imm);
        if Mask = 0 then
          Continue;
        if Mask = High(UInt32) then
          Width := 32
        else
        begin
          if (Mask and (Mask + 1)) <> 0 then
            Continue;
          Width := 0;
          while Mask <> 0 do
          begin
            Inc(Width);
            Mask := Mask shr 1;
          end;
        end;
        Shift := UInt32(PlannedCode[K + 2].Imm) and 31;
        if UInt32(Width) + Shift > 32 then
          Continue;
        SkipPlanned[K] := True;
        SkipPlanned[K + 1] := True;
        SkipPlanned[K + 2] := True;
        MaskedShiftSource[K + 3] := Integer(Source);
        MaskedShiftShape[K + 3] := Shift or (UInt32(Width) shl 8);
      end;
  end;
  {$ENDIF}

  procedure AnalyzeMemoryMoves;
  var
    K, P, First: Integer;
    Source, Temp: UInt32;

    function IsAllocatedSlot(const ASlot: UInt32): Boolean;
    begin
      Result := (ASlot = AllocatedSlots[0]) or
        (ASlot = AllocatedSlots[1]) or
        ((AllocatedSlots[2] <> High(UInt32)) and
          (ASlot = AllocatedSlots[2]));
    end;

    function ScalarMemoryOp(const AOp: TWasmIrOp): Boolean;
    begin
      Result := AOp in [
        iroI32Load, iroI64Load, iroF32Load, iroF64Load,
        iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
        iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
        iroI64Load32S, iroI64Load32U,
        iroI32Store, iroI64Store, iroF32Store, iroF64Store,
        iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
        iroI64Store32];
    end;

    function MemoryUseCount(const AReg: UInt32): UInt32;
    var
      J: Integer;
    begin
      Result := 0;
      for J := 0 to High(AFn^.Code) do
        if ScalarMemoryOp(AFn^.Code[J].Op) then
        begin
          if AFn^.Code[J].A = AReg then Inc(Result);
          if (AFn^.Code[J].Op in [iroI32Store, iroI64Store, iroF32Store,
            iroF64Store, iroI32Store8, iroI32Store16, iroI64Store8,
            iroI64Store16, iroI64Store32]) and
            (AFn^.Code[J].Dest = AReg) then
            Inc(Result);
        end;
    end;

  begin
    {$IFDEF WASM_JIT_ARM64}
    if not (UsePinnedMemoryBase and UseStaticCache) then
      Exit;
    for K := 0 to High(PlannedCode) do
      if ScalarMemoryOp(PlannedCode[K].Op) then
      begin
        First := K - 2;
        if First < 0 then First := 0;
        for P := K - 1 downto First do
          if (PlannedCode[P].Op = iroMove) and not SkipPlanned[P] and
            not Targets[P] and not Targets[K] then
          begin
            Source := PlannedCode[P].A;
            Temp := PlannedCode[P].Dest;
            if IsAllocatedSlot(Source) and
              (SimpleUseCount(Temp) + MemoryUseCount(Temp) = 1) then
            begin
              if PlannedCode[K].A = Temp then
              begin
                PlannedCode[K].A := Source;
                SkipPlanned[P] := True;
              end
              else if (PlannedCode[K].Op in [iroI32Store, iroI64Store,
                iroF32Store, iroF64Store, iroI32Store8, iroI32Store16,
                iroI64Store8, iroI64Store16, iroI64Store32]) and
                (PlannedCode[K].Dest = Temp) then
              begin
                PlannedCode[K].Dest := Source;
                SkipPlanned[P] := True;
              end;
            end;
          end;
      end;
    {$ENDIF}
  end;

  procedure AnalyzeLocalAliases;
  var
    K, L, Last, Arg: Integer;
    Source, Alias_: UInt32;

    function IsAllocatedSlot(const ASlot: UInt32): Boolean;
    begin
      Result := (ASlot = AllocatedSlots[0]) or
        (ASlot = AllocatedSlots[1]) or
        ((AllocatedSlots[2] <> High(UInt32)) and
          (ASlot = AllocatedSlots[2]));
    end;

    function RewriteUse(var AIns: TWasmIrInstr; const AOld,
      ANew: UInt32): Boolean;
    begin
      Result := False;
      case AIns.Op of
        iroMove, iroBranchIf, iroBranchIfNot, iroI32Eqz, iroI64Eqz,
        iroI32Load, iroI64Load, iroF32Load, iroF64Load,
        iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
        iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
        iroI64Load32S, iroI64Load32U:
          if AIns.A = AOld then
          begin
            AIns.A := ANew;
            Result := True;
          end;
        iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
        iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
        iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
        iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
        iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
        iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotr,
        iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
        iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotr:
          begin
            if AIns.A = AOld then
            begin
              AIns.A := ANew;
              Result := True;
            end;
            if AIns.B = AOld then
            begin
              AIns.B := ANew;
              Result := True;
            end;
          end;
        iroI32Store, iroI64Store, iroF32Store, iroF64Store,
        iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
        iroI64Store32:
          begin
            if AIns.A = AOld then
            begin
              AIns.A := ANew;
              Result := True;
            end;
            if AIns.Dest = AOld then
            begin
              AIns.Dest := ANew;
              Result := True;
            end;
          end;
      end;
    end;

    function DefinesSlot(const AIns: TWasmIrInstr;
      const ASlot: UInt32): Boolean;
    begin
      Result := (AIns.Dest = ASlot) and
        (AIns.Op in [iroMove, iroI32Const, iroI64Const, iroF32Const,
          iroF64Const, iroI32Eqz, iroI64Eqz,
          iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
          iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
          iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
          iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
          iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
          iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotr,
          iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
          iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotr,
          iroI32Load, iroI64Load, iroF32Load, iroF64Load,
          iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
          iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
          iroI64Load32S, iroI64Load32U]);
    end;

  begin
    {$IFDEF WASM_JIT_ARM64}
    { Validation lowers local.get to a move into a one-use expression slot.
      Forward that exact alias into an already-cached consumer without
      changing the canonical IR or labels — in the helper-free base-pinned
      loop shape, and in the closed native-scalar core whose parameters sit
      in fixed hosts, or a closed caller preserving statics across inline
      bodies. The four-instruction window covers the bounded lowering
      shapes while a target, safepoint, or intervening write to the visible
      source ends the proof. }
    if not ((UsePinnedMemoryBase and UseStaticCache) or
        UseNativeScalarCore or UsePreservedInlineCache) then
      Exit;
    for K := 0 to High(PlannedCode) - 1 do
      if (PlannedCode[K].Op = iroMove) and not SkipPlanned[K] and
        (not Targets[K] or IsAllocatedSlot(PlannedCode[K].A)) and
        IsVisibleFrameReg(PlannedCode[K].A) and
        not IsVisibleFrameReg(PlannedCode[K].Dest) and
        (RegisterUseCount(PlannedCode[K].Dest) = 1) then
      begin
        Source := PlannedCode[K].A;
        Alias_ := PlannedCode[K].Dest;
        Last := K + 4;
        if Last > High(PlannedCode) then
          Last := High(PlannedCode);
        for L := K + 1 to Last do
        begin
          if Targets[L] then
            Break;
          if SkipPlanned[L] then
            Continue;
          if UsePreservedInlineCache and (Length(InlineBodies[L]) <> 0) then
          begin
            { A proven call is the endpoint, never an instruction to cross.
              Keep canonical AuxU32 immutable; only its local argument plan
              adopts the single-use alias. Both arguments are still read
              before the body clobbers dynamic hosts. }
            for Arg := 0 to Integer(IrAuxBlockCount(AFn^.AuxU32,
              PlannedCode[L].A)) - 1 do
              if InlineArgSlots[L][Arg] = Alias_ then
              begin
                InlineArgSlots[L][Arg] := Source;
                SkipPlanned[K] := True;
              end;
            Break;
          end;
          if IrInstrIsSafepoint(PlannedCode[L]) or
            (UsePreservedInlineCache and
            (PlannedCode[L].Op in [iroJump, iroBranchIf, iroBranchIfNot,
            iroReturn, iroUnreachable])) then
            Break;
          if RewriteUse(PlannedCode[L], Alias_, Source) then
          begin
            SkipPlanned[K] := True;
            Break;
          end;
          if DefinesSlot(PlannedCode[L], Source) then
            Break;
        end;
      end;
    {$ENDIF}
  end;

  procedure AnalyzeStoreLoadForwarding;
  var
    K, L, Last: Integer;
    StoreIns, LoadIns: TWasmIrInstr;

    function IsAllocatedSlot(const ASlot: UInt32): Boolean;
    begin
      Result := (ASlot = AllocatedSlots[0]) or
        (ASlot = AllocatedSlots[1]) or
        ((AllocatedSlots[2] <> High(UInt32)) and
          (ASlot = AllocatedSlots[2]));
    end;

  begin
    {$IFDEF WASM_JIT_ARM64}
    { This is deliberately not general memory value numbering. In the
      helper-free, base-pinned shape, forward only across at most two pure
      lowering moves to an exact same-address i32 load.
      The store is still emitted and therefore keeps its normal fault/trap and
      memory side effect; after it succeeds, the store-confined thread cannot
      change that memory before the immediately following load. }
    if not (UsePinnedMemoryBase and UseStaticCache) then
      Exit;
    for K := 0 to High(PlannedCode) - 1 do
    begin
      StoreIns := PlannedCode[K];
      if SkipPlanned[K] or (StoreIns.Op <> iroI32Store) or
        not IsAllocatedSlot(StoreIns.A) or
        not IsAllocatedSlot(StoreIns.Dest) then
        Continue;
      Last := K + 3;
      if Last > High(PlannedCode) then
        Last := High(PlannedCode);
      for L := K + 1 to Last do
      begin
        if Targets[L] then
          Break;
        LoadIns := PlannedCode[L];
        if LoadIns.Op = iroI32Load then
        begin
          if not SkipPlanned[L] and
            (LoadIns.A = StoreIns.A) and
            (LoadIns.B = StoreIns.B) and
            (LoadIns.Imm = StoreIns.Imm) and
            (LoadIns.Dest <> StoreIns.A) and
            (LoadIns.Dest <> StoreIns.Dest) and
            not IsVisibleFrameReg(LoadIns.Dest) and
            (SimpleUseCount(LoadIns.Dest) = 1) and
            (L < High(PlannedCode)) and not Targets[L + 1] and
            not SkipPlanned[L + 1] and
            (PlannedCode[L + 1].Op = iroI32Add) then
          begin
            if PlannedCode[L + 1].A = LoadIns.Dest then
            begin
              PlannedCode[L + 1].A := StoreIns.Dest;
              SkipPlanned[L] := True;
            end
            else if PlannedCode[L + 1].B = LoadIns.Dest then
            begin
              PlannedCode[L + 1].B := StoreIns.Dest;
              SkipPlanned[L] := True;
            end;
          end;
          Break;
        end;
        { At this analysis point only lowering moves can have been skipped;
          they emit no code. A surviving move may be crossed only when it
          cannot redefine the exact address or stored-value slot. Checking the
          IR safepoint bit explicitly keeps this proof independent of move's
          current non-safepoint classification. }
        if (LoadIns.Op <> iroMove) or IrInstrIsSafepoint(LoadIns) then
          Break;
        if SkipPlanned[L] then
          Continue;
        if (LoadIns.Dest = StoreIns.A) or
          (LoadIns.Dest = StoreIns.Dest) then
          Break;
      end;
    end;
    {$ENDIF}
  end;

  function StaticCacheOp(const AOp: TWasmIrOp): Boolean;
  begin
    case AOp of
      iroMove, iroJump, iroBranchIf, iroBranchIfNot, iroUnreachable,
      iroReturn, iroI32Const, iroI64Const, iroF32Const, iroF64Const,
      iroI32Eqz, iroI64Eqz,
      iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
      iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
      iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
      iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
      iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
      iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotr,
      iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
      iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotr:
        Result := True;
      {$IFDEF WASM_JIT_ARM64}
      iroI32Load, iroI64Load, iroF32Load, iroF64Load,
      iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
      iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
      iroI64Load32S, iroI64Load32U,
      iroI32Store, iroI64Store, iroF32Store, iroF64Store,
      iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
      iroI64Store32:
        { Only base-pinned memory functions are helper-free and keep x14/x15
          available for the static cache's expression-value side. }
        Result := UsePinnedMemoryBase;
      {$ENDIF}
    else
      Result := False;
    end;
  end;

  procedure ScoreSlot(const ASlot: UInt32; const AWeight: UInt32 = 1);
  begin
    if ASlot < UInt32(Length(SlotScores)) then
      Inc(SlotScores[ASlot], AWeight);
  end;

  procedure ScoreInstruction(const AIns: TWasmIrInstr);
  begin
    case AIns.Op of
      iroMove:
        begin
          { Local traffic is represented by moves between stable local slots
            and short-lived expression registers. Give both ends enough weight
            for frequently reused locals to beat one-use temporaries. }
          ScoreSlot(AIns.A, 2);
          ScoreSlot(AIns.Dest, 2);
        end;
      iroI32Const, iroI64Const, iroF32Const, iroF64Const:
        ScoreSlot(AIns.Dest);
      iroBranchIf, iroBranchIfNot:
        ScoreSlot(AIns.A);
      iroI32Eqz, iroI64Eqz:
        begin
          ScoreSlot(AIns.A);
          ScoreSlot(AIns.Dest);
        end;
      iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
      iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
      iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
      iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
      iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
      iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotr,
      iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
      iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotr:
        begin
          ScoreSlot(AIns.A);
          ScoreSlot(AIns.B);
          ScoreSlot(AIns.Dest);
        end;
    end;
  end;

  procedure CountSlotUse(const ASlot: UInt32);
  begin
    if ASlot < UInt32(Length(SlotUseCounts)) then
      Inc(SlotUseCounts[ASlot]);
  end;

  procedure CountInstructionUses(const AIns: TWasmIrInstr);
  var
    N: Integer;
  begin
    case AIns.Op of
      iroMove, iroBranchIf, iroBranchIfNot, iroI32Eqz, iroI64Eqz:
        CountSlotUse(AIns.A);
      iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
      iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
      iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
      iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
      iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
      iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
      iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
      iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr:
        begin
          CountSlotUse(AIns.A);
          CountSlotUse(AIns.B);
        end;
      iroSelect:
        begin
          CountSlotUse(AIns.A);
          CountSlotUse(AIns.B);
          CountSlotUse(UInt32(AIns.Imm));
        end;
      iroI32Load, iroI64Load, iroF32Load, iroF64Load,
      iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
      iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
      iroI64Load32S, iroI64Load32U:
        CountSlotUse(AIns.A);
      iroI32Store, iroI64Store, iroF32Store, iroF64Store,
      iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
      iroI64Store32:
        begin
          CountSlotUse(AIns.A);
          CountSlotUse(AIns.Dest);
        end;
      iroCall:
        for N := 0 to Integer(IrAuxBlockCount(AFn^.AuxU32, AIns.A)) - 1 do
          CountSlotUse(IrAuxBlockItem(AFn^.AuxU32, AIns.A, UInt32(N)));
      {$IFDEF WASM_JIT_ARM64}
      iroReturn:
        if UseNativeScalarCore then
          { Result-copy planning may make the actual return source an
            expression slot. Retain its final read across dynamic eviction. }
          CountSlotUse(NativeResultSource);
      {$ENDIF}
    end;
  end;

  procedure AnalyzeDynamicWriteBack;
  var
    K, Arg: Integer;

    procedure MarkLoopCarried(const AFirst, ALast: Integer);
    var
      Defined: array of Boolean;
      Ins: TWasmIrInstr;
      J, N: Integer;

      procedure MarkUse(const ASlot: UInt32);
      begin
        if (ASlot < UInt32(Length(Defined))) and not Defined[ASlot] then
          VisibleSlots[ASlot] := True;
      end;

      procedure MarkDefinition(const ASlot: UInt32);
      begin
        if ASlot < UInt32(Length(Defined)) then
          Defined[ASlot] := True;
      end;
    begin
      SetLength(Defined, AFn^.RegisterCount);
      for N := AFirst to ALast do
      begin
        if SkipPlanned[N] or (Fusion[N] = -2) then
          Continue;
        Ins := PlannedCode[N];
        if MaskedShiftSource[N] >= 0 then
        begin
          MarkUse(UInt32(MaskedShiftSource[N]));
          MarkDefinition(Ins.Dest);
          Continue;
        end;
        if Fusion[N] >= 0 then
          Ins := PlannedCode[Fusion[N]]
        else
          Ins := PlannedCode[N];
        case Ins.Op of
          iroMove, iroBranchIf, iroBranchIfNot, iroI32Eqz, iroI64Eqz:
            MarkUse(Ins.A);
          iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
          iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
          iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
          iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
          iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
          iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
          iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
          iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr:
            begin
              MarkUse(Ins.A);
              MarkUse(Ins.B);
            end;
          iroSelect:
            begin
              MarkUse(Ins.A);
              MarkUse(Ins.B);
              MarkUse(UInt32(Ins.Imm));
            end;
          iroCall:
            for J := 0 to Integer(IrAuxBlockCount(AFn^.AuxU32, Ins.A)) - 1 do
              {$IFDEF WASM_JIT_ARM64}
              if Length(InlineBodies[N]) <> 0 then
                MarkUse(InlineArgSlots[N][J])
              else
              {$ENDIF}
                MarkUse(IrAuxBlockItem(AFn^.AuxU32, Ins.A, UInt32(J)));
          iroI32Load, iroI64Load, iroF32Load, iroF64Load,
          iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
          iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
          iroI64Load32S, iroI64Load32U:
            MarkUse(Ins.A);
          iroI32Store, iroI64Store, iroF32Store, iroF64Store,
          iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
          iroI64Store32:
            begin
              MarkUse(Ins.A);
              MarkUse(Ins.Dest);
            end;
        end;
        if Fusion[N] < 0 then
          case Ins.Op of
            iroMove, iroI32Const, iroI64Const, iroF32Const, iroF64Const,
            iroI32Eqz, iroI64Eqz,
            iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
            iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
            iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
            iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
            iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
            iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
            iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
            iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr,
            iroSelect,
            iroI32Load, iroI64Load, iroF32Load, iroF64Load,
            iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
            iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
            iroI64Load32S, iroI64Load32U:
              MarkDefinition(Ins.Dest);
            iroCall:
              for J := 0 to
                Integer(IrAuxBlockCount(AFn^.AuxU32, Ins.B)) - 1 do
                MarkDefinition(IrAuxBlockItem(AFn^.AuxU32, Ins.B,
                  UInt32(J)));
          end;
      end;
    end;
  begin
    SetLength(SlotUseCounts, AFn^.RegisterCount);
    SetLength(VisibleSlots, AFn^.RegisterCount);
    for K := 0 to High(AFn^.LocalRegs) do
      if AFn^.LocalRegs[K] < UInt32(Length(VisibleSlots)) then
        VisibleSlots[AFn^.LocalRegs[K]] := True;
    for K := 0 to High(AFn^.ResultRegs) do
      if AFn^.ResultRegs[K] < UInt32(Length(VisibleSlots)) then
        VisibleSlots[AFn^.ResultRegs[K]] := True;
    for K := 0 to High(PlannedCode) do
      if not SkipPlanned[K] then
      begin
        {$IFDEF WASM_JIT_ARM64}
        if Length(InlineBodies[K]) <> 0 then
        begin
          for Arg := 0 to Integer(IrAuxBlockCount(AFn^.AuxU32,
            PlannedCode[K].A)) - 1 do
            CountSlotUse(InlineArgSlots[K][Arg]);
        end
        else
        {$ENDIF}
        if MaskedShiftSource[K] >= 0 then
          CountSlotUse(UInt32(MaskedShiftSource[K]))
        else if Fusion[K] >= 0 then
          CountInstructionUses(PlannedCode[Fusion[K]])
        else if Fusion[K] <> -2 then
          CountInstructionUses(PlannedCode[K]);
      end;
    { A finite lexical use count alone cannot see a use reached by a backward
      edge. Preserve every slot read before it is redefined in each loop
      region, while still allowing values produced inside the loop to die at
      the back-edge flush. }
    for K := 0 to High(PlannedCode) do
      if (PlannedCode[K].Op = iroJump) and
        (PlannedCode[K].A <= UInt32(K)) then
        MarkLoopCarried(Integer(PlannedCode[K].A), K)
      else if (PlannedCode[K].Op in [iroBranchIf, iroBranchIfNot]) and
        (PlannedCode[K].B <= UInt32(K)) then
        MarkLoopCarried(Integer(PlannedCode[K].B), K);
  end;

  procedure AnalyzeStaticCache;
  var
    K, Best, Second, Third: Integer;
    HasBackEdge, Eligible: Boolean;
    {$IFDEF WASM_JIT_ARM64}
    HasInlineCall: Boolean;
    {$ENDIF}
  begin
    UseStaticCache := False;
    {$IFDEF WASM_JIT_ARM64}
    UsePreservedInlineCache := False;
    {$ENDIF}
    AllocatedSlots[2] := High(UInt32);
    if AFn^.RegisterCount = 0 then
      Exit;
    SetLength(SlotScores, AFn^.RegisterCount);
    HasBackEdge := False;
    Eligible := True;
    {$IFDEF WASM_JIT_ARM64}
    HasInlineCall := False;
    {$ENDIF}
    for K := 0 to High(AFn^.Code) do
    begin
      {$IFDEF WASM_JIT_ARM64}
      if (AFn^.Code[K].Op = iroCall) and
        (Length(InlineBodies[K]) <> 0) then
        HasInlineCall := True
      else
      {$ENDIF}
        Eligible := Eligible and StaticCacheOp(AFn^.Code[K].Op);
      if (AFn^.Code[K].Op = iroJump) and
        (AFn^.Code[K].A <= UInt32(K)) then
        HasBackEdge := True;
      ScoreInstruction(AFn^.Code[K]);
    end;
    {$IFDEF WASM_JIT_ARM64}
    if HasInlineCall then
    begin
      Eligible := Eligible and not UsePinnedMemory and not HasHandlers;
      for K := 0 to High(AFn^.RegTypes) do
        Eligible := Eligible and (AFn^.RegTypes[K].Kind = wvkNum) and
          ((AFn^.RegTypes[K].Num = wntI32) or
          (AFn^.RegTypes[K].Num = wntI64));
    end;
    {$ENDIF}
    if not Eligible or not HasBackEdge then
      Exit;

    Best := -1;
    Second := -1;
    Third := -1;
    for K := 0 to High(SlotScores) do
      if (Best < 0) or (SlotScores[K] > SlotScores[Best]) then
      begin
        Third := Second;
        Second := Best;
        Best := K;
      end
      else if (Second < 0) or (SlotScores[K] > SlotScores[Second]) then
      begin
        Third := Second;
        Second := K;
      end
      else if (Third < 0) or (SlotScores[K] > SlotScores[Third]) then
        Third := K;
    { Loading and preserving a one-use expression register costs more than the
      old write-through cache. Require both physical registers to serve slots
      that occur repeatedly in the loop-shaped function. }
    if (Best < 0) or (Second < 0) or
      (SlotScores[Best] < 3) or (SlotScores[Second] < 3) then
      Exit;
    AllocatedSlots[0] := UInt32(Best);
    AllocatedSlots[1] := UInt32(Second);
    if (Third >= 0) and (SlotScores[Third] >= 3) then
      AllocatedSlots[2] := UInt32(Third)
    else
      AllocatedSlots[2] := High(UInt32);
    {$IFDEF WASM_JIT_ARM64}
    UsePreservedInlineCache := HasInlineCall;
    if UsePreservedInlineCache then
      { Reserve the third preserved host for the existing one-constant plan;
        every dynamic host remains inside the body's x14-x17 clobber set. }
      AllocatedSlots[2] := High(UInt32);
    {$ENDIF}
    UseStaticCache := True;
  end;

  { Loop-invariant constants (loop limits, multipliers) sit inside the loop
    body in IR order, so their materialization re-executes on every iteration.
    A constant-defined slot with a dedicated static host register is seeded
    once at frame entry instead; the defining const instruction then emits
    nothing. Only slots written by exactly one const instruction qualify, and
    never a slot the ordinary static allocation already claimed. }
  procedure AnalyzeConstSlots;
  type
    TSpan = record
      Lo: UInt32;
      Hi: UInt32;
    end;
  var
    K, M, Slot: Integer;
    UniqueWriter: Boolean;
    InLoop: Boolean;
    ConstInLoop: array[0..0] of Boolean;
    ConstLoopSpans: array of TSpan;

    function SlotBeats(const AInLoop: Boolean; const AScore: UInt32;
      const ABInLoop: Boolean; const ABScore: UInt32): Boolean;
    begin
      if AInLoop <> ABInLoop then
        Result := AInLoop
      else
        Result := AScore > ABScore;
    end;

    function CoveredByLoop(const AIndex: UInt32): Boolean;
    var
      N: Integer;
    begin
      Result := False;
      for N := 0 to High(ConstLoopSpans) do
        if (ConstLoopSpans[N].Lo <= AIndex) and
          (AIndex <= ConstLoopSpans[N].Hi) then
          Exit(True);
    end;

    function AlreadyClaimed(const ASlot: UInt32): Boolean;
    var
      N: Integer;
    begin
      Result := True;
      for N := 0 to High(ConstSlots) do
        if ConstSlots[N] = ASlot then
          Exit;
      for N := 0 to High(AllocatedSlots) do
        if AllocatedSlots[N] = ASlot then
          Exit;
      Result := False;
    end;

  procedure OfferConstSlot(const ASlot: UInt32; const ABits: UInt64;
    const AInLoop: Boolean);
    var
      N: Integer;
    begin
      for N := 0 to High(ConstSlots) do
      begin
        if ConstSlots[N] = ASlot then
          Exit;
        if (ConstSlots[N] = High(UInt32)) or
          SlotBeats(AInLoop, SlotScores[ASlot],
          ConstInLoop[N], SlotScores[ConstSlots[N]]) then
        begin
          ConstSlots[N] := ASlot;
          ConstSlotBits[N] := ABits;
          ConstInLoop[N] := AInLoop;
          Exit;
        end;
      end;
    end;

  begin
    ConstSlots[0] := High(UInt32);
    ConstInLoop[0] := False;
    if not UseStaticCache or (Length(SlotScores) = 0) then
      Exit;
    { Loop spans from backward jumps: a constant defined between a back-edge
      target and its jump re-materializes on every iteration, which is exactly
      the cost a static host removes. Out-of-loop constants only save their
      single emission, so they rank strictly below in-loop candidates. }
    SetLength(ConstLoopSpans, 0);
    for K := 0 to High(AFn^.Code) do
      if (AFn^.Code[K].Op = iroJump) and
        (AFn^.Code[K].A <= UInt32(K)) then
      begin
        SetLength(ConstLoopSpans, Length(ConstLoopSpans) + 1);
        ConstLoopSpans[High(ConstLoopSpans)].Lo := AFn^.Code[K].A;
        ConstLoopSpans[High(ConstLoopSpans)].Hi := UInt32(K);
      end;
    for K := 0 to High(AFn^.Code) do
    begin
      if not (AFn^.Code[K].Op in [iroI32Const, iroI64Const,
        iroF32Const, iroF64Const]) then
        Continue;
      { A constant folded into a consumer never emits, so there is nothing
        per-iteration to save. }
      if SkipPlanned[K] then
        Continue;
      Slot := Integer(AFn^.Code[K].Dest);
      if (Slot < 0) or (Slot >= Length(SlotScores)) then
        Continue;
      UniqueWriter := True;
      for M := 0 to High(AFn^.Code) do
        if (M <> K) and (AFn^.Code[M].Dest = AFn^.Code[K].Dest) then
        begin
          UniqueWriter := False;
          Break;
        end;
      if not UniqueWriter or AlreadyClaimed(AFn^.Code[K].Dest) then
        Continue;
      InLoop := CoveredByLoop(UInt32(K));
      case AFn^.Code[K].Op of
        iroI32Const, iroF32Const:
          OfferConstSlot(AFn^.Code[K].Dest,
            UInt64(UInt32(AFn^.Code[K].Imm and $FFFFFFFF)), InLoop);
        iroI64Const, iroF64Const:
          OfferConstSlot(AFn^.Code[K].Dest, UInt64(AFn^.Code[K].Imm), InLoop);
      end;
    end;
  end;

  { Fixed-type struct and array access bake their field shape instead of
    paying a helper crossing that re-resolves the layout per access. Struct
    offsets mirror TWasmGcTypes' layout math; arrays have a fixed 16-byte
    element base and a statically known element width. }
  procedure AnalyzeGcFieldAccess;
  var
    K, F, CanonIdx: Integer;
    TargetIdx, FieldIdx, Offset, Width: UInt32;
    IsRef, IsPacked: Boolean;
    PackedKind: TWasmPackedType;
    Comp: ^TWasmCompType;

    function StorageWidthOf(const AStorage: TWasmStorageType): UInt32;
    begin
      if AStorage.IsPacked then
      begin
        if AStorage.PackedType = wpkI8 then
          Result := 1
        else
          Result := 2;
        Exit;
      end;
      case AStorage.ValueType.Kind of
        wvkNum:
          if (AStorage.ValueType.Num = wntI32) or
            (AStorage.ValueType.Num = wntF32) then
            Result := 4
          else
            Result := 8;
        wvkVec:
          Result := 16;
      else
        Result := 8;
      end;
    end;

  begin
    SetLength(GcShapes, Length(AFn^.Code));
    for K := 0 to High(AFn^.Code) do
      GcShapes[K] := 0;
    for K := 0 to High(AFn^.Code) do
    begin
      if not ((AFn^.Code[K].Op = iroStructGet) or
        (AFn^.Code[K].Op = iroStructGetS) or
        (AFn^.Code[K].Op = iroStructGetU) or
        (AFn^.Code[K].Op = iroStructSet)) then
        Continue;
      IrUnpack(AFn^.Code[K].Imm, TargetIdx, FieldIdx);
      if TargetIdx >= UInt32(Length(AIr.CanonTypes)) then
        Continue;
      CanonIdx := Integer(AIr.TypeIndexToCanon[TargetIdx]);
      if (CanonIdx < 0) or (CanonIdx >= Length(AIr.CanonTypes)) then
        Continue;
      Comp := @AIr.CanonTypes[CanonIdx].Comp;
      if (Comp^.Kind <> wckStruct) or
        (FieldIdx >= UInt32(Length(Comp^.Struct.Fields))) then
        Continue;
      IsRef := False;
      IsPacked := False;
      PackedKind := wpkI8;
      Width := 0;
      Offset := 8;
      for F := 0 to Integer(FieldIdx) do
      begin
        Width := StorageWidthOf(
          Comp^.Struct.Fields[F].Storage);
        Offset := (Offset + Width - 1) and not (Width - 1);
        if F = Integer(FieldIdx) then
        begin
          IsRef := (not Comp^.Struct.Fields[F].Storage.IsPacked) and
            (Comp^.Struct.Fields[F].Storage.ValueType.Kind = wvkRef);
          IsPacked := Comp^.Struct.Fields[F].Storage.IsPacked;
          PackedKind := Comp^.Struct.Fields[F].Storage.PackedType;
        end
        else
          Offset := Offset + Width;
      end;
      if IsRef or (Width > 8) or (Offset >= $10000) or
        ((Offset div Width) >= $1000) then
        Continue;
      case AFn^.Code[K].Op of
        iroStructGet:
          if IsPacked then
            Continue;
        iroStructGetS, iroStructGetU:
          if not IsPacked then
            Continue;
      end;
      { bit0 native | bit1 signed | bits8-15 width | bits16-31 offset }
      GcShapes[K] := 1 or
        (Ord(AFn^.Code[K].Op = iroStructGetS) shl 1) or
        (UInt64(Width) shl 8) or
        (UInt64(Offset) shl 16);
    end;

    for K := 0 to High(AFn^.Code) do
    begin
      if not (AFn^.Code[K].Op in [iroArrayGet, iroArrayGetS,
        iroArrayGetU, iroArraySet]) then
        Continue;
      TargetIdx := UInt32(AFn^.Code[K].Imm);
      if (TargetIdx >= UInt32(Length(AIr.TypeIndexToCanon))) then
        Continue;
      CanonIdx := Integer(AIr.TypeIndexToCanon[TargetIdx]);
      if (CanonIdx < 0) or (CanonIdx >= Length(AIr.CanonTypes)) then
        Continue;
      Comp := @AIr.CanonTypes[CanonIdx].Comp;
      if Comp^.Kind <> wckArray then
        Continue;
      Width := StorageWidthOf(Comp^.Arr.Elem.Storage);
      IsRef := (not Comp^.Arr.Elem.Storage.IsPacked) and
        (Comp^.Arr.Elem.Storage.ValueType.Kind = wvkRef);
      IsPacked := Comp^.Arr.Elem.Storage.IsPacked;
      if (Width > 8) or
        ((AFn^.Code[K].Op = iroArrayGet) and IsPacked) or
        ((AFn^.Code[K].Op in [iroArrayGetS, iroArrayGetU]) and
          not IsPacked) then
        Continue;
      { bit0 native | bit1 signed | bit2 array | bit3 reference |
        bits8-15 width | bits16-31 element-zero offset }
      GcShapes[K] := 1 or
        (Ord(AFn^.Code[K].Op = iroArrayGetS) shl 1) or 4 or
        (Ord(IsRef) shl 3) or (UInt64(Width) shl 8) or
        (UInt64(WASM_ARRAY_ELEMS_OFFSET) shl 16);
    end;
  end;

  {$IFDEF WASM_JIT_ARM64}
  { Wave 11 — inline struct.new allocation. For a FIXED struct type the whole
    Allocate sequence except collection is compile-time: layout size, size
    class, cell size, field offsets. When the class size is a power of two
    and every field is a numeric <=64-bit member, the backend emits the
    free-list-hit fast path with these shapes; the helper path stays as the
    miss branch and remains the only collect trigger. Ref fields stay off
    (the barrier shape belongs to the helper), v128 fields, struct.new_default,
    non-pow2 classes, and large objects all decline. Baked runtime offsets are
    range-checked here so emission can use scaled-imm12 addressing directly. }
  procedure AnalyzeGcInlineAlloc;
  var
    K, F, C, CanonIdx, ClassIndex, Log2Cell: Integer;
    TypeIdx: UInt32;
    Offset, Width, Size, CellSize, FreeOff: UInt32;
    Ok: Boolean;
    Comp: ^TWasmCompType;

    function StorageWidthOf(const AStorage: TWasmStorageType): UInt32;
    begin
      if AStorage.IsPacked then
      begin
        if AStorage.PackedType = wpkI8 then
          Result := 1
        else
          Result := 2;
        Exit;
      end;
      case AStorage.ValueType.Kind of
        wvkNum:
          if (AStorage.ValueType.Num = wntI32) or
            (AStorage.ValueType.Num = wntF32) then
            Result := 4
          else
            Result := 8;
        wvkVec:
          Result := 16;
      else
        Result := 8;
      end;
    end;

    function Log2OfPow2(const AValue: UInt32): Integer;
    begin
      if (AValue <> 0) and ((AValue and (AValue - 1)) = 0) then
      begin
        Result := 0;
        while (UInt32(1) shl Result) <> AValue do
          Inc(Result);
      end
      else
        Result := -1;
    end;

  begin
    SetLength(GcAllocShapes, Length(AFn^.Code));
    for K := 0 to High(AFn^.Code) do
      GcAllocShapes[K].Word := 0;
    if UseNativeScalarCore then
      Exit;
    with WasmJitStoreAllocOffsets do
    begin
      GcAllocInfo.FHeapOffset := FHeapOffset;
      GcAllocInfo.TierContextOffset := TierContextOffset;
      GcAllocInfo.EngineTypeIdsOffset := EngineTypeIdsOffset;
      if (FHeapOffset >= $8000) or (TierContextOffset >= $8000) or
        (EngineTypeIdsOffset >= $8000) then
        Exit;
    end;
    with WasmJitFrameOffsets do
      if (CtxDepth >= $8000) or (CtxActs >= $8000) or
        (ActInstance >= $8000) or (ActStride > High(UInt16)) then
        Exit;
    with WasmJitGcHeapOffsets do
      if (HeapFFree0 + WASM_GC_CLASS_COUNT * 8 >= $8000) or
        (HeapMarkState >= $8000) or (HeapBytesLive >= $8000) or
        (HeapBytesAllocated >= $8000) or (HeapObjectCount >= $8000) or
        (BlockBase >= $8000) or (BlockAllocated >= $8000) then
        Exit;

    for K := 0 to High(AFn^.Code) do
    begin
      if AFn^.Code[K].Op <> iroStructNew then
        Continue;
      TypeIdx := UInt32(AFn^.Code[K].Imm);
      if TypeIdx >= UInt32(Length(AIr.CanonTypes)) then
        Continue;
      CanonIdx := Integer(AIr.TypeIndexToCanon[TypeIdx]);
      if (CanonIdx < 0) or (CanonIdx >= Length(AIr.CanonTypes)) then
        Continue;
      Comp := @AIr.CanonTypes[CanonIdx].Comp;
      if (Comp^.Kind <> wckStruct) then
        Continue;
      F := Length(Comp^.Struct.Fields);
      if (F = 0) or (F > 16) then
        Continue;

      { Field walk — identical arithmetic to TWasmGcTypes' layout pass and
        AnalyzeGcFieldAccess above: header 8, per-field align-up to storage
        width, cumulative advance. }
      Offset := 8;
      Ok := True;
      for C := 0 to F - 1 do
      begin
        Width := StorageWidthOf(Comp^.Struct.Fields[C].Storage);
        if Width > 8 then
        begin
          Ok := False;
          Break;
        end;
        if (not Comp^.Struct.Fields[C].Storage.IsPacked) and
          (Comp^.Struct.Fields[C].Storage.ValueType.Kind = wvkRef) then
        begin
          Ok := False;
          Break;
        end;
        Offset := (Offset + Width - 1) and not (Width - 1);
        GcAllocShapes[K].Fields[C].Slot :=
          IrAuxBlockItem(AFn^.AuxU32, AFn^.Code[K].A, UInt32(C));
        GcAllocShapes[K].Fields[C].Offset := Offset;
        GcAllocShapes[K].Fields[C].Width := Width;
        Offset := Offset + Width;
      end;
      if not Ok then
        Continue;

      { Size-class math mirrors TWasmGcHeap.Allocate exactly: Layout.Size is
        the align-up-8 of the field span, sizes below the first class bump to
        it, ClassOf takes the first class >= the size. A power-of-two class
        means CellSize == Size exactly, so the cell tail past the aligned
        layout is zero bytes and nothing needs an inline zero fill. }
      Size := (Offset + 7) and not UInt32(7);
      if Size < WASM_GC_SIZE_CLASSES[0] then
        Size := WASM_GC_SIZE_CLASSES[0];
      ClassIndex := -1;
      for C := 0 to WASM_GC_CLASS_COUNT - 1 do
        if Size <= WASM_GC_SIZE_CLASSES[C] then
        begin
          ClassIndex := C;
          Break;
        end;
      if ClassIndex < 0 then
        Continue;
      CellSize := WASM_GC_SIZE_CLASSES[ClassIndex];
      Log2Cell := Log2OfPow2(CellSize);
      if (Log2Cell < 0) or (CellSize <> Size) then
        Continue;
      FreeOff := WasmJitGcHeapOffsets.HeapFFree0 + UInt32(ClassIndex) * 8;
      if (FreeOff >= $8000) or (TypeIdx >= 4096) then
        Continue;

      { bit0 enabled | bits8-15 count | bits16-23 log2(CellSize) |
        bits24-31 class index }
      GcAllocShapes[K].Word := 1 or
        (UInt64(F) shl 8) or
        (UInt64(Log2Cell) shl 16) or
        (UInt64(ClassIndex) shl 24);
    end;
  end;
  {$ENDIF}

  procedure AnalyzePinnedMemory;
  var
    K: Integer;
    Index: UInt32;
    Found, Multiple: Boolean;
  begin
    UsePinnedMemory := False;
    UsePinnedMemoryBase := False;
    PinnedMemoryIndex := 0;
    Found := False;
    Multiple := False;
    for K := 0 to High(AFn^.Code) do
      if AFn^.Code[K].Op in [
        iroI32Load, iroI64Load, iroF32Load, iroF64Load,
        iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
        iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
        iroI64Load32S, iroI64Load32U,
        iroI32Store, iroI64Store, iroF32Store, iroF64Store,
        iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
        iroI64Store32] then
      begin
        Index := AFn^.Code[K].B;
        if not Found then
        begin
          Found := True;
          PinnedMemoryIndex := Index;
        end
        else if Index <> PinnedMemoryIndex then
          Multiple := True;
      end;
    UsePinnedMemory := Found and not Multiple;
    UsePinnedMemoryBase := UsePinnedMemory;
    if UsePinnedMemoryBase then
      for K := 0 to High(AFn^.Code) do
      begin
        { A host/direct/tail call can re-enter the embedder, and memory.grow can
          change the live base in this frame. Keep pinning the instance for
          those functions. Base-only pinning is restricted further to the
          zero-offset i32 guard-page form, which consumes neither ByteSize nor
          an explicit address-add sequence. }
        if AFn^.Code[K].Op in [iroCall, iroCallIndirect, iroCallRef,
          iroReturnCall, iroReturnCallIndirect, iroReturnCallRef,
          iroMemoryGrow] then
          UsePinnedMemoryBase := False
        else if AFn^.Code[K].Op in [
          iroI32Load, iroI64Load, iroF32Load, iroF64Load,
          iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
          iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
          iroI64Load32S, iroI64Load32U,
          iroI32Store, iroI64Store, iroF32Store, iroF64Store,
          iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
          iroI64Store32] then
          if (AFn^.Code[K].Imm <> 0) or
            (AFn^.Code[K].A >= UInt32(Length(AFn^.RegTypes))) or
            (AFn^.RegTypes[AFn^.Code[K].A].Kind <> wvkNum) or
            (AFn^.RegTypes[AFn^.Code[K].A].Num <> wntI32) then
            UsePinnedMemoryBase := False;
      end;
  end;

begin
  Result := TWasmCodeBuffer.Create;
  Buf := Result;
  try
    UseNativeScalarSelf := JitCanNativeScalarSelf(AFn, AFuncIdx);
    UseNativeScalarLeaf := JitCanNativeScalarLeaf(AFn);
    UseNativeScalarCore := UseNativeScalarSelf or UseNativeScalarLeaf;
    UseNativeScalarCall := False;
    NativeParamCount := 0;
    NativeParamReg := 0;
    NativeParam1Reg := 0;
    NativeResultReg := 0;
    NativeCoreLabel := -1;
    NativeExhaustedLabel := -1;
    NativeExternalLabel := -1;
    if UseNativeScalarCore then
    begin
      NativeParamCount := AFn^.ParamCount;
      NativeParamReg := AFn^.LocalRegs[0];
      if NativeParamCount = 2 then
        NativeParam1Reg := AFn^.LocalRegs[1];
      NativeResultReg := AFn^.ResultRegs[0];
    end;
    { One label per IR instruction, created in order so label id = IR index
      (the invariant the branch templates rely on). }
    for I := 0 to High(AFn^.Code) do
      Buf.NewLabel;
    HasHandlers := Length(AFn^.Handlers) > 0;
    if HasHandlers then
    begin
      EhTableLabel := Buf.NewLabel;
      EhEndLabel := Buf.NewLabel;
    end
    else
    begin
      EhTableLabel := 0;
      EhEndLabel := 0;
    end;
    {$IFDEF WASM_JIT_ARM64}
    { Recursive leaf emission must finish before installing the caller's EH
      labels in the backend emission context. }
    PrepareInlineBodies;
    Arm64BeginEhEmit(HasHandlers, EhTableLabel, EhEndLabel,
      UInt32(Length(AFn^.Code)));
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    X64BeginEhEmit(HasHandlers, EhTableLabel, EhEndLabel,
      UInt32(Length(AFn^.Code)));
    {$ENDIF}
    if UseNativeScalarCore then
    begin
      NativeCoreLabel := Buf.NewLabel;
      if UseNativeScalarSelf then
        NativeExhaustedLabel := Buf.NewLabel;
      if UseNativeScalarLeaf then
        NativeExternalLabel := Buf.NewLabel;
    end;

    { A cache is valid only along one straight-line predecessor. Mark every IR
      branch destination up front so a join invalidates compile-time cache
      metadata before its label is bound. Values are write-through, therefore
      no generated flush is needed. }
    SetLength(Targets, Length(AFn^.Code));
    for I := 0 to High(AFn^.Code) do
    begin
      if (AFn^.Code[I].Op = iroCall) and
        NativeScalarLeafTarget(UInt32(AFn^.Code[I].Imm)) then
        UseNativeScalarCall := True;
      case AFn^.Code[I].Op of
        iroJump: MarkTarget(AFn^.Code[I].A);
        iroBranchIf, iroBranchIfNot,
        iroBrOnNull, iroBrOnNonNull, iroBrOnCast, iroBrOnCastFail:
          MarkTarget(AFn^.Code[I].B);
        iroBrTable:
          begin
            TargetCount := IrAuxBlockCount(AFn^.AuxU32, AFn^.Code[I].B);
            for J := 0 to Integer(TargetCount) - 1 do
              MarkTarget(IrAuxBlockItem(AFn^.AuxU32, AFn^.Code[I].B,
                UInt32(J)));
          end;
      end;
    end;
    for I := 0 to High(AFn^.HandlerClauses) do
      MarkTarget(AFn^.HandlerClauses[I].TargetInstr);

    AnalyzePinnedMemory;
    AnalyzeStaticCache;
    if HasHandlers then
      { A landing pad is reached by the EH jump table, not a fall-through.
        Host-register cache would observe stale slots after ResumeAtClause
        writes the payload (eh-spec §2.3). }
      UseStaticCache := False;
    if UseNativeScalarCore then
    begin
      { x26 is unavailable to the shared native core cache: recursion pins its
        additional-frame budget there, while a leaf uses the wider x14-x17
        dynamic set and does not need a third static entry. }
      AllocatedSlots[2] := High(UInt32);
      { The native core seeds x12/x13 before any canonical register-file load;
        use its bounded write-back cache rather than the ordinary entry loads. }
      UseStaticCache := False;
    end;
    UseThirdStatic := UseStaticCache and
      (AllocatedSlots[2] <> High(UInt32));
    AnalyzeAdjacentMoves;
    AnalyzeMemoryMoves;
    AnalyzeLocalAliases;
    {$IFDEF WASM_JIT_ARM64}
    AnalyzeResultCopies;
    {$ENDIF}
    AnalyzeStoreLoadForwarding;
    {$IFDEF WASM_JIT_ARM64}
    AnalyzeMaskedShiftFusion;
    {$ENDIF}
    AnalyzeImmediateFusion;
    AnalyzeFusion;
    { After fusion planning, so already-folded constants are not offered a
      host register their defining instruction would never have used. }
    AnalyzeConstSlots;
    AnalyzeGcFieldAccess;
    {$IFDEF WASM_JIT_ARM64}
    AnalyzeGcInlineAlloc;
    {$ENDIF}
    {$IFDEF WASM_JIT_ARM64}
    AnalyzeDynamicWriteBack;
    {$ENDIF}

    {$IFDEF WASM_JIT_ARM64}
    UseExtendedFrame := UseThirdStatic or UseNativeScalarSelf or
      UsePreservedInlineCache;
    if UseNativeScalarLeaf then
    begin
      Arm64EmitNativeLeafEntry(Buf, AFn^.RegisterCount, NativeCoreLabel,
        NativeExternalLabel);
      Buf.BindLabel(NativeExternalLabel);
    end;
    if UseExtendedFrame then
      Arm64EmitPrologueExtended(Buf, UsePreservedInlineCache)
    else
      Arm64EmitPrologue(Buf);
    Arm64EmitPinHelperTable(Buf, AHelperTableOffset);
    Arm64EmitEpochCapture(Buf, AEpochOffset, ASnapshotOffset);
    if UseNativeScalarSelf then
      Arm64EmitNativeSelfBudget(Buf, AFn^.RegisterCount);
    if UsePinnedMemory then
      Arm64EmitPinMemory(Buf, PinnedMemoryIndex, UsePinnedMemoryBase);
    if UseNativeScalarCore then
    begin
      { The external AAPCS entry owns the full callee-saved frame once. The
        recursive path targets this position-independent local core directly. }
      Arm64EmitNativeCoreWrapperCall(Buf, NativeParamCount, NativeParamReg,
        NativeParam1Reg, NativeResultReg, NativeCoreLabel);
      if UseExtendedFrame then
        Arm64EmitEpilogueExtended(Buf)
      else
        Arm64EmitEpilogue(Buf);
      Buf.BindLabel(NativeCoreLabel);
    end;
    Arm64InitRegCache(ArmCache);
    if UseStaticCache then
    begin
      Arm64EnableStaticRegCache(Buf, ArmCache, AllocatedSlots,
        UsePreservedInlineCache);
      if ConstSlots[0] <> High(UInt32) then
        Arm64EnableConstSlots(Buf, ArmCache, ConstSlots, ConstSlotBits);
      { StaticCacheOp admits only helper-free scalar operations or base-pinned
        memory. Both retain the same dynamic registers and can defer temporary
        stores: locals, results, and loop-carried values stay visible to the
        existing branch/exit reconciliation plan. }
      Arm64EnableDynamicWriteBack(ArmCache, @SlotUseCounts[0],
        @VisibleSlots[0], AFn^.RegisterCount);
    end;
    if UseNativeScalarCore then
      { The closed helper-free native core may defer block-local numeric
        stores. Calls flush only values the lexical liveness plan still needs;
        generic call-bearing functions never enable this mode. }
      Arm64EnableDynamicWriteBack(ArmCache, @SlotUseCounts[0],
        @VisibleSlots[0], AFn^.RegisterCount);
    if UseNativeScalarCore then
      Arm64SeedNativeCoreCache(ArmCache, NativeParamCount, NativeParamReg,
        NativeParam1Reg, UseNativeScalarLeaf and not UseNativeScalarSelf);
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    UseX64ExtendedFrame := UseNativeScalarCall or UseNativeScalarSelf;
    if UseNativeScalarLeaf then
    begin
      X64EmitNativeLeafEntry(Buf, AFn^.RegisterCount, NativeParamCount,
        NativeParamReg, NativeParam1Reg, NativeCoreLabel,
        NativeExternalLabel);
      Buf.BindLabel(NativeExternalLabel);
    end;
    X64EmitPrologue(Buf, UseX64ExtendedFrame);
    X64EmitPinHelperTable(Buf, AHelperTableOffset);
    X64EmitEpochCapture(Buf, AEpochOffset, ASnapshotOffset);
    if UseNativeScalarSelf then
      X64EmitNativeSelfBudget(Buf, AFn^.RegisterCount);
    if UsePinnedMemory then
      X64EmitPinMemory(Buf, PinnedMemoryIndex);
    X64InitRegCache(X64Cache);
    if UseNativeScalarCore then
      X64SeedNativeCoreCache(X64Cache, NativeParamCount, NativeParamReg,
        NativeParam1Reg, UseNativeScalarLeaf)
    else if UseStaticCache then
      X64EnableStaticRegCache(Buf, X64Cache, AllocatedSlots);
    if UseNativeScalarCore then
    begin
      X64EmitNativeCoreWrapperCall(Buf, NativeParamCount, NativeParamReg,
        NativeParam1Reg, NativeResultReg, NativeCoreLabel);
      X64EmitEpilogue(Buf, UseX64ExtendedFrame);
      Buf.BindLabel(NativeCoreLabel);
    end;
    {$ENDIF}

    {$IFDEF WASM_JIT_ARM64}
    Arm64EmitEhResumeCheck(Buf);
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    X64EmitEhResumeCheck(Buf);
    {$ENDIF}

    for I := 0 to High(AFn^.Code) do
    begin
      if Targets[I] then
      begin
        {$IFDEF WASM_JIT_ARM64}
        Arm64FlushDynamicRegCache(Buf, ArmCache);
        Arm64InvalidateRegCache(ArmCache);
        {$ENDIF}
        {$IFDEF WASM_JIT_X64}
        X64InvalidateRegCache(X64Cache);
        {$ENDIF}
      end;
      Buf.BindLabel(TWasmJitLabel(I));
      if SkipPlanned[I] or (Fusion[I] = -2) then
        Continue;
      { Position-independent IR reference (aot-spec §1.3): pass the instruction
        INDEX; the runtime-op templates compute @Fn^.Code[i] from the pinned IR
        base (x23/rbp), which the entry receives freshly per invocation — no
        heap IR pointer is ever baked. }
      {$IFDEF WASM_JIT_ARM64}
      if not UsePinnedMemory and (Length(InlineBodies[I]) <> 0) then
      begin
        Arm64EmitScalarBodyCall(Buf, InlineBodies[I],
          InlineRegisterCounts[I],
          IrAuxBlockCount(AFn^.AuxU32, AFn^.Code[I].A),
          InlineArgSlots[I][0], InlineArgSlots[I][1], InlineResultSlots[I],
          ArmCache);
        Emitted := True;
      end
      else if MaskedShiftSource[I] >= 0 then
      begin
        Arm64EmitMaskedShiftCached(Buf, UInt32(MaskedShiftSource[I]),
          PlannedCode[I].Dest, Byte(MaskedShiftShape[I] and $FF),
          Byte(MaskedShiftShape[I] shr 8), ArmCache);
        Emitted := True;
      end
      else if Fusion[I] >= 0 then
      begin
        Arm64EmitCompareBranchCached(Buf, PlannedCode[Fusion[I]],
          PlannedCode[I], ArmCache);
        Emitted := True;
      end
      else
      begin
        if ImmediateFusion[I] then
          Emitted := Arm64EmitOpCachedImmediate(Buf, PlannedCode[I],
            ImmediateValues[I], ArmCache)
        else
          Emitted := Arm64EmitOpCached(Buf, PlannedCode[I], AFn^.AuxU32,
            UInt32(I),
            (AFn^.Code[I].A < UInt32(Length(AFn^.RegTypes))) and
              (AFn^.RegTypes[AFn^.Code[I].A].Kind = wvkNum) and
            (AFn^.RegTypes[AFn^.Code[I].A].Num = wntI64),
            UsePinnedMemory, UsePinnedMemoryBase, UseExtendedFrame,
            UseNativeScalarCore, AFn^.RegisterCount, NativeParamReg,
            NativeResultSource, NativeCoreLabel, NativeExhaustedLabel, ArmCache,
            @GcShapes[0], @GcAllocShapes[0], GcAllocInfo);
      end;
      {$ENDIF}
      {$IFDEF WASM_JIT_X64}
      NativeScalarCall := (AFn^.Code[I].Op = iroCall) and
        NativeScalarLeafTarget(UInt32(AFn^.Code[I].Imm));
      if Fusion[I] >= 0 then
      begin
        X64EmitCompareBranchCached(Buf, PlannedCode[Fusion[I]],
          PlannedCode[I], X64Cache);
        Emitted := True;
      end
      else
        Emitted := X64EmitOpCached(Buf, PlannedCode[I], AFn^.AuxU32,
          UInt32(I),
          (AFn^.Code[I].A < UInt32(Length(AFn^.RegTypes))) and
            (AFn^.RegTypes[AFn^.Code[I].A].Kind = wvkNum) and
            (AFn^.RegTypes[AFn^.Code[I].A].Num = wntI64),
          UsePinnedMemory, UseNativeScalarCore, UseNativeScalarSelf,
          AFn^.RegisterCount, NativeParamReg, NativeResultReg,
          NativeCoreLabel, NativeExhaustedLabel, UseX64ExtendedFrame,
          NativeScalarCall,
          X64Cache, @GcShapes[0]);
      {$ENDIF}
      if not Emitted then
        { The predicate guaranteed every op is emittable; reaching here is an
          internal inconsistency, not a fall-back path. }
        raise EWasmInternal.CreateFmt(
          'internal: JIT predicate passed but op %d has no template',
          [Ord(AFn^.Code[I].Op)]);
    end;

    {$IFDEF WASM_JIT_ARM64}
    if UseNativeScalarSelf then
    begin
      { All ordinary native-core paths return through iroReturn. Keep the rare
        exhaustion helper out of line so successful recursive calls need no
        branch around a per-call trap block. }
      Buf.BindLabel(NativeExhaustedLabel);
      Arm64EmitLoadImm32(Buf, 0, UInt32(Ord(wtkStackExhausted)));
      Arm64EmitCallHelper(Buf, aohTrapKind);
    end;
    if HasHandlers then
    begin
      Buf.BindLabel(EhEndLabel);
      if UseExtendedFrame then
        Arm64EmitEpilogueExtended(Buf)
      else
        Arm64EmitEpilogue(Buf);
    end;
    Arm64EmitEhTable(Buf, Length(AFn^.Code));
    Arm64ResolvePatches(Buf);
    {$ENDIF}
    {$IFDEF WASM_JIT_X64}
    if UseNativeScalarSelf then
    begin
      Buf.BindLabel(NativeExhaustedLabel);
      X64EmitMovRegImm32(Buf, X64_ARG0, UInt32(Ord(wtkStackExhausted)));
      X64EmitCallHelper(Buf, aohTrapKind);
    end;
    if HasHandlers then
    begin
      Buf.BindLabel(EhEndLabel);
      X64EmitEpilogue(Buf, UseX64ExtendedFrame);
    end;
    X64EmitEhTable(Buf, Length(AFn^.Code));
    X64ResolvePatches(Buf);
    {$ENDIF}
    { AOT staging (aot-spec §3.2) stops HERE, before MakeExecutable: the caller
      wants the finalized, branch-resolved, position-independent BYTES
      (SnapshotBytes), not an executable mapping in this process. The JIT path
      passes AFinalize = True and maps + flushes as before. }
    if AFinalize then
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
      begin
        FStore.Funcs[FCompiledAddrs[I]].CompiledEntry := nil;
        FStore.Funcs[FCompiledAddrs[I]].CompiledDirectEntry := nil;
        FStore.Funcs[FCompiledAddrs[I]].CompiledNativeScalarEntry := nil;
      end;
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
    more functions compile (compiled=N goes up). Fence 1 is retired: handler
    tables and throw / throw_ref now compile; UnwindException still matches by
    tag store-address. Handler-bearing and throwing functions decline only
    JitCanDirectCall so they keep an InvokeCompiled seam. }
  {$IFDEF WASM_JIT_BACKEND}
  N := Length(FBuffers);
  SetLength(FBuffers, N + 1);
  FBuffers[N] := nil;
  { The epoch words' byte offsets from the store object pointer — read from the
    live record layout (O-J5, WasmJitOffsets) so a store-layout change is caught
    rather than miscompiled. The prologue reloads the LIVE Store.Epoch at
    StoreEpoch and captures the SHARED per-invocation snapshot at
    StoreEpochSnapshot (jit-spec §6). Conditional branches that miss imm19
    are rewritten to invert+B in the resolver. A remaining B/BL overflow
    is an internal fault, not a decline. }
  try
    FBuffers[N] := JitCompileToBuffer(FStore.Funcs[AAddr].Instance.Ir, Fn,
      FStore.Funcs[AAddr].Instance.Ir.FuncImportCount +
        FStore.Funcs[AAddr].FuncIrIndex,
      WasmJitOffsets(FStore).StoreEpoch,
      WasmJitOffsets(FStore).StoreEpochSnapshot,
      WasmJitOffsets(FStore).StoreJitHelperTable);
  except
    on E: EWasmJitBranchRange do
    begin
      SetLength(FBuffers, N);
      raise EWasmInternal.CreateFmt(
        'internal: branch range after veneer: %s', [E.Message]);
    end;
  end;

  FStore.Funcs[AAddr].CompiledEntry := FBuffers[N].EntryPoint;
  if JitCanDirectCall(Fn) then
    FStore.Funcs[AAddr].CompiledDirectEntry := FBuffers[N].EntryPoint;
  if JitCanNativeScalarLeaf(Fn) then
    FStore.Funcs[AAddr].CompiledNativeScalarEntry := FBuffers[N].EntryPoint;

  N := Length(FCompiledAddrs);
  SetLength(FCompiledAddrs, N + 1);
  FCompiledAddrs[N] := AAddr;
  Result := True;
  {$ELSE}
  { Off the supported leg JitCanCompile already returned False above, so this
    point is unreachable; Result stays False and the function runs interpreted. }
  {$ENDIF}
end;

function TWasmJitContext.LoadPrecompiled(const AAddr: TWasmFuncAddr;
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
  { Already wired (by an earlier record or a prior JIT compile) — idempotent. }
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
    { Stage the pre-made bytes and flip to executable through the same W^X +
      I-cache-flush machinery a JIT compile finalizes with — the ONLY difference
      from JitCompileToBuffer is the bytes were emitted in another process/run
      and travel in the artifact rather than being emitted here (aot-spec §4.2). }
    Buf.EmitBytes(ACode);
    Buf.MakeExecutable;
  except
    Buf.Free;
    SetLength(FBuffers, N);
    Exit;
  end;
  FBuffers[N] := Buf;
  { The entry point of the LOADED region, offset to the entry stub. For the
    unified emitter the prologue is at offset 0, so AEntryOffset is 0; the field
    is honoured for a future layout that prefixes the code. }
  FStore.Funcs[AAddr].CompiledEntry :=
    Pointer(PtrUInt(Buf.EntryPoint) + AEntryOffset);
  if JitCanDirectCall(IrFunctionFor(AAddr)) then
    FStore.Funcs[AAddr].CompiledDirectEntry :=
      FStore.Funcs[AAddr].CompiledEntry;
  if JitCanNativeScalarLeaf(IrFunctionFor(AAddr)) then
    FStore.Funcs[AAddr].CompiledNativeScalarEntry :=
      FStore.Funcs[AAddr].CompiledEntry;

  N := Length(FCompiledAddrs);
  SetLength(FCompiledAddrs, N + 1);
  FCompiledAddrs[N] := AAddr;
  Result := True;
  {$ELSE}
  { No backend on this target: the executable-memory path is unavailable, so the
    function stays interpreted (AThe tier of record), which is correct. }
  {$ENDIF}
end;

{ --- registration -------------------------------------------------------- }

function JitStageFunctionBytes(const AStore: TWasmStore;
  const AFn: PWasmIrFunctionRec; out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes;
begin
  { Preserve the pre-native staging surface for code-shape tests and callers
    that do not have a module function index. High(UInt32) cannot match a
    validated call target, so the proof-gated self-call ABI stays disabled. }
  Result := JitStageFunctionBytes(AStore, AFn, High(UInt32), AEntryOffset,
    ARegisterCount);
end;

function JitStageFunctionBytes(const AStore: TWasmStore;
  const AFn: PWasmIrFunctionRec; const AFuncIdx: UInt32;
  out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes;
begin
  Result := JitStageFunctionBytes(AStore, nil, AFn, AFuncIdx, AEntryOffset,
    ARegisterCount);
end;

function JitCanEmitForTarget(const AFn: PWasmIrFunctionRec;
  const ATarget: TWasmTarget): Boolean;
begin
  Result := WasmTargetCanEmit(ATarget) and JitCanCompile(AFn);
end;

function JitStageFunctionBytes(const AStore: TWasmStore;
  const AIr: TWasmIrModule; const AFn: PWasmIrFunctionRec;
  const AFuncIdx: UInt32; out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes;
begin
  Result := JitStageFunctionBytes(AStore, AIr, AFn, AFuncIdx, WasmTargetHost,
    AEntryOffset, ARegisterCount);
end;

function JitStageFunctionBytes(const AStore: TWasmStore;
  const AIr: TWasmIrModule; const AFn: PWasmIrFunctionRec;
  const AFuncIdx: UInt32; const ATarget: TWasmTarget;
  out AEntryOffset: NativeUInt;
  out ARegisterCount: UInt32): TWasmBytes;
{$IFDEF WASM_JIT_BACKEND}
var
  Buf: TWasmCodeBuffer;
  Abi: TWasmTargetAbi;
  JO: TWasmJitOffsets;
  EpochOffset, SnapshotOffset, HelperTableOffset: NativeUInt;
{$ENDIF}
begin
  Result := nil;
  AEntryOffset := 0;
  ARegisterCount := 0;
  if AFn = nil then
    Exit;
  ARegisterCount := AFn^.RegisterCount;
  if not WasmTargetCanEmit(ATarget) then
    Exit;
  {$IFDEF WASM_JIT_BACKEND}
  { Host emission uses the live store offsets ForceCompile bakes, so a
    compiler-profile layout shift cannot miscompile the running binary.
    A requested foreign target consumes the published descriptor. }
  if WasmTargetEqual(ATarget, WasmTargetHost) and (AStore <> nil) then
  begin
    JO := WasmJitOffsets(AStore);
    EpochOffset := JO.StoreEpoch;
    SnapshotOffset := JO.StoreEpochSnapshot;
    HelperTableOffset := JO.StoreJitHelperTable;
  end
  else
  begin
    Abi := WasmTargetAbi(ATarget);
    EpochOffset := NativeUInt(Abi.Layout.StoreEpoch);
    SnapshotOffset := NativeUInt(Abi.Layout.StoreEpochSnapshot);
    HelperTableOffset := NativeUInt(Abi.Layout.StoreJitHelperTable);
  end;
  try
    Buf := JitCompileToBuffer(AIr, AFn, AFuncIdx,
      EpochOffset, SnapshotOffset, HelperTableOffset, { AFinalize } False);
  except
    on E: EWasmJitBranchRange do
      raise EWasmInternal.CreateFmt(
        'internal: branch range after veneer: %s', [E.Message]);
  end;
  try
    Result := Buf.SnapshotBytes;
    AEntryOffset := 0;
  finally
    Buf.Free;
  end;
  {$ELSE}
  { No backend: nothing to stage; Result stays nil (declined). }
  if AStore = nil then;   { AStore/AFn are const params, silence unused hints }
  {$ENDIF}
end;

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
