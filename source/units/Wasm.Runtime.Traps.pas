{ Wasm.Runtime.Traps — the trap vocabulary, the fault-attribution
  registry, the fault handler, and the per-invocation trampoline.

  A trap can originate inside a POSIX signal handler, raised by the MMU
  while guest code holds live registers. ADR-0009 fixes what happens
  next: the handler does the minimum — attribute the fault, record the
  kind, transfer control — and the EWasmTrap is raised by a trampoline
  installed once per host-to-guest invocation, on ordinary ground.

  This unit sits BELOW Wasm.Runtime.Memory, not beside it. The memory
  chokepoint calls TrapNow, and the reservation registry is the
  handler's business rather than the memory's; inverting the dependency
  creates a cycle.

  Three constraints hold over everything below.

  TRAP-1. Every Pascal frame between a trampoline and a possible longjmp
  holds NO managed state: no string, no dynamic array local, no
  interface, no try..finally whose cleanup matters. A skipped frame never
  runs its implicit finalisation and FPC gives no diagnostic. Trap
  messages are therefore PAnsiChar constants selected AFTER the jump, and
  the fault path allocates nothing.

  Async-signal safety. The handler may read siginfo, walk the reservation
  registry, write one enum into the current thread's trampoline record,
  and jump. Nothing else: no Format, no IntToStr, no allocation, no
  SysUtils call of any kind.

  Signal mask. ADR-0009's shape wants sigsetjmp(buf, 1), so that jumping
  out of the handler does not leave SIGSEGV blocked and kill the process
  on the next fault. FPC's RTL exposes setjmp/longjmp on every target but
  not sigsetjmp, and binding libc's would mean a per-OS jmp_buf layout on
  targets this repo cannot compile locally. The equivalent guarantee is
  taken from the other end instead: the handler is installed with
  SA_NODEFER, so SIGSEGV/SIGBUS are never added to the mask in the first
  place. Plain LongJmp does not touch the signal mask, so the mask at the
  point control returns to SetJmp is exactly the pre-fault mask — with
  both signals still unblocked. No manual fpsigprocmask is needed, and it
  is deliberately NOT done: unblocking in the handler would permanently
  clear those signals from the HOST's mask, mutating state the embedder
  owns (L2). SA_NODEFER alone is the guarantee.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
unit Wasm.Runtime.Traps;

{$I Shared.inc}

interface

uses
  SysUtils,
  {$IFDEF WASM_GUARD_STRATEGIES}
  BaseUnix,
  {$ENDIF}
  Wasm.Core;

type
  { Every way guest execution can fail. The set is closed: a tier that
    needs a kind not listed here is describing a spec rule the validator
    already owns (ADR-0007). }
  TWasmTrapKind = (
    wtkNone,
    wtkUnreachable,
    wtkMemoryOutOfBounds,
    wtkTableOutOfBounds,
    wtkUndefinedElement,
    wtkUninitializedElement,
    wtkIndirectCallTypeMismatch,
    { The null-dereference family. The corpus does NOT spell them all
      'null reference': struct/array/func/i31 accesses each name their own
      hierarchy, and only ref.cast-to-non-null and ref.as_non_null use the
      bare message (fix H5). Kept as distinct kinds so a tier can raise the
      right one; Track E wires the raise sites. }
    wtkNullReference,
    wtkNullStructReference,
    wtkNullArrayReference,
    wtkNullFuncReference,
    wtkNullI31Reference,
    wtkDivideByZero,
    wtkIntegerOverflow,
    wtkInvalidConversion,
    wtkCastFailure,
    wtkArrayOutOfBounds,
    wtkAllocationFailure,
    wtkEpochInterrupt,
    wtkStackExhausted,
    wtkHostTrap
  );

const
  { Canonical trap messages, in ONE block so a corrector finds every
    marker in one place — the convention Wasm.Validator.Types set.

    C           read from wasm-mcp instruction_get at the pin.
    CONFIRMED   settled from the Track C assert_trap corpus at
     from corpus tests/spec/testsuite, cited at the site as
                'corpus <file:line> (Nx)'. This is what the served trap
                table could not give: it is reliable for 1.0/2.0
                instructions and systematically incomplete for the 3.0 GC
                family (ref.cast, array.get, array.set, array.new_data and
                i31.get_s all report can_trap:false while call_ref,
                ref.as_non_null and struct.get correctly report a null
                message), and the matching exec-* clauses are SpecTec-
                generated with empty prose. The GC/cast/array/exhaustion
                messages below are now corpus-confirmed.
    UNCONFIRMED not a spec trap AND absent from the corpus — `out of
                memory` and `interrupt` only. Left marked; the embedding
                API documents them. }
  MSG_TRAP_UNREACHABLE = 'unreachable';
  { C: `unreachable` }
  MSG_TRAP_MEMORY_OUT_OF_BOUNDS = 'out of bounds memory access';
  { C: `i32.load`, `memory.init`. corpus address0.wast:193 (892x) }
  MSG_TRAP_TABLE_OUT_OF_BOUNDS = 'out of bounds table access';
  { C: `table.get`, `table.init`. corpus bulk.wast:220 (173x) }
  MSG_TRAP_UNDEFINED_ELEMENT = 'undefined element';
  { C: `call_indirect` — deliberately NOT unified with the table message.
    corpus call.wast:354 (27x) }
  MSG_TRAP_UNINITIALIZED_ELEMENT = 'uninitialized element';
  { C: `call_indirect`. corpus call_indirect.wast:661, array_init_elem.wast:100.
    The corpus also spells an INDEXED form, `uninitialized element 2`
    (corpus bulk.wast:222), where the trailing number is the element
    index. That index rides in the trampoline's Detail field and is
    appended after the jump (see AppendUninitializedElementIndex). }
  MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH = 'indirect call type mismatch';
  { C: `call_indirect`. corpus call_indirect.wast:498 (25x) }
  MSG_TRAP_NULL_REFERENCE = 'null reference';
  { C: `call_ref`, `ref.as_non_null`, `struct.get`. The BARE message is
    used only by ref.cast-to-non-null and ref.as_non_null in the corpus.
    corpus ref_cast.wast:51, ref_as_non_null.wast:27 (5x total) }
  MSG_TRAP_NULL_STRUCT_REFERENCE = 'null structure reference';
  { CONFIRMED from corpus: struct.get/struct.set on a null.
    corpus struct.wast:155-156 (2x) }
  MSG_TRAP_NULL_ARRAY_REFERENCE = 'null array reference';
  { CONFIRMED from corpus: array.get/set/fill/copy/init_*/len on a null.
    corpus array.wast:342-343, array_fill.wast:59, array_copy.wast:97-98,
    array_init_elem.wast:85, array_init_data.wast:68 (9x total) }
  MSG_TRAP_NULL_FUNC_REFERENCE = 'null function reference';
  { CONFIRMED from corpus: call_ref/return_call_ref on a null funcref.
    corpus call_ref.wast:97, return_call_ref.wast:183 (2x) }
  MSG_TRAP_NULL_I31_REFERENCE = 'null i31 reference';
  { CONFIRMED from corpus: i31.get_s/i31.get_u on a null.
    corpus i31.wast:53-54 (2x) }
  MSG_TRAP_DIVIDE_BY_ZERO = 'integer divide by zero';
  { C: `i32.div_s`. corpus i32.wast:64 (39x) }
  MSG_TRAP_INTEGER_OVERFLOW = 'integer overflow';
  { C: `i32.div_s`, `i32.trunc_f32_s`. corpus conversions.wast:78 (41x) }
  MSG_TRAP_INVALID_CONVERSION = 'invalid conversion to integer';
  { C: `i32.trunc_f32_s` }
  MSG_TRAP_CAST_FAILURE = 'cast failure';
  { CONFIRMED from corpus: ref.cast reports can_trap:false at the pin, but
    the corpus settles it. corpus ref_cast.wast:61 (30x) }
  MSG_TRAP_ARRAY_OUT_OF_BOUNDS = 'out of bounds array access';
  { CONFIRMED from corpus: array.get reports can_trap:false at the pin, but
    the corpus settles it. corpus array_init_data.wast:71 (27x) }
  MSG_TRAP_ALLOCATION_FAILURE = 'out of memory';
  { UNCONFIRMED: not a spec trap; `impl-exec` makes it embedder-specific,
    and no `out of memory` string appears in the corpus. }
  MSG_TRAP_EPOCH_INTERRUPT = 'interrupt';
  { UNCONFIRMED: not a spec trap; ADR-0006, and no `interrupt` string
    appears in the corpus. }
  MSG_TRAP_STACK_EXHAUSTED = 'call stack exhausted';
  { CONFIRMED from corpus: `impl-exec` names the frame count as an
    implementation limit, and assert_exhaustion pins the spelling.
    corpus call.wast:337 (15x) }
  MSG_TRAP_HOST = 'host trap';
  { fallback only; a host trap normally carries the host's own message }
  MSG_TRAP_NONE = 'no trap';

  { Link-error family. All UNCONFIRMED: `exec-module` says only that
    instantiation "may fail with an error", and assert_unlinkable is what
    prefix-matches them. Kept here, next to the trap messages, for the
    same reason. }
  MSG_LINK_INCOMPATIBLE_IMPORT = 'incompatible import type';
  { UNCONFIRMED }
  MSG_LINK_UNKNOWN_IMPORT = 'unknown import';
  { UNCONFIRMED }

{ The message for a kind. A `case` over compile-time constants, so it
  allocates nothing and is callable from anywhere — but note that the
  fault path does NOT call it: the trampoline does, after the jump. }
function TrapMessage(const AKind: TWasmTrapKind): PAnsiChar;

{ --- fault attribution ------------------------------------------------

  The handler must decide whether a faulting address is ours. Guessing is
  not acceptable: swallowing an unrelated SIGSEGV turns a host bug into a
  spurious wasm trap.

  Address masking is not a substitute for this registry. Some engines
  test the fault address by mask, which assumes a fixed reservation size
  — and the guard-assisted strategy remaps to current size plus guard, so
  it has none.

  The store is a fixed-capacity, append-and-tombstone array rather than a
  dynamic one: the handler walks it, and a SetLength racing the walk is
  exactly the hazard a signal handler cannot tolerate. Growth allocates a
  NEW block, copies, and publishes the pointer with one aligned store;
  the old block stays readable for the lifetime of the process. }

{ Register [ABase, ABase + ABytes). Called at map time, BEFORE the
  mapping can fault. }
procedure ReservationRegister(const ABase: Pointer; const ABytes: NativeUInt);

{ Tombstone the entry for ABase. MUST run BEFORE the unmap — otherwise a
  fault at a freshly-unmapped-and-reused address is misattributed. }
procedure ReservationUnregister(const ABase: Pointer);

{ The handler's lookup: a linear scan, two comparisons per entry, no
  allocation, no lock. }
function ReservationContains(const AAddress: Pointer): Boolean;

{ Test visibility over the registry's bookkeeping. }
function ReservationSlotCount: Integer;
function ReservationLiveCount: Integer;

type
  PWasmTrampoline = ^TWasmTrampoline;

  { One per host-to-guest invocation, living on WasmInvoke's own stack
    frame — which is the frame longjmp returns to. }
  TWasmTrampoline = record
    JmpBuf: jmp_buf;
    Prev: PWasmTrampoline;
    Kind: TWasmTrapKind;
    { Trap-specific payload. Read after the jump by RaiseTrapDirect: for
      wtkUninitializedElement it is the element index the corpus appends
      to the message (L1). Written by TrapNowDetail and by the fault
      handler (which sets it to 0). }
    Detail: UInt32;
    { wtkHostTrap only, and BORROWED: the host owns the storage and must
      keep it alive until the invocation returns. Read by RaiseTrapDirect;
      set to non-nil only by the host-call thunk (§5.6, Track E) — nil
      until then, which is why a plain wasm trap never consults it. }
    HostMsg: PAnsiChar;
    { The TWasmStore, opaque here. This unit sits below the store, so the
      field cannot be typed; the store layer hands the pointer in and reads
      it back (Wasm.Runtime.Store casts it to TWasmStore). Live, not dead —
      do not remove. }
    Context: Pointer;
  end;

  { The guest region. A plain procedure pointer, not a method or a
    closure: a closure is managed state on a frame longjmp can skip. }
  TWasmGuestProc = procedure(const AData: Pointer);

{ The current thread's innermost trampoline. A threadvar rather than a
  store field, because the fault handler has a thread but not a store —
  and because ADR-0008 confines a store to one thread while the handler
  is process-global. }
threadvar
  CurrentTrampoline: PWasmTrampoline;

type
  PWasmSeamCatch = ^TWasmSeamCatch;

  { A tier-seam catch (Fix A / Finding 3). A wasm exception (an uncaught `throw`)
    is RESUMABLE, so it cannot ride the trap LongJmp all the way to the
    trampoline; but on FPC/aarch64 a Pascal `raise` cannot unwind across a JIT
    body's native frame either (no unwind tables — it lands on garbage). So the
    exception unwind crosses a compiled body's native frame the SAME way a trap
    does: a LongJmp to a SetJmp buffer the compiled-body wrapper (and the
    interp->compiled launchers) install just below that native frame. Each
    rtCompiledSeam frame pairs with one of these on the stack; the unwind pops
    the frame and LongJmps to the innermost seam catch, which re-enters the
    unwind in its own (now native-frame-free) context. Living on the launcher's
    own stack frame — the frame the LongJmp returns to — so, like the trampoline,
    it holds only plain data (TRAP-1). }
  TWasmSeamCatch = record
    JmpBuf: jmp_buf;
    Prev: PWasmSeamCatch;
    { The thrown exn handle (a TWasmRef as a raw NativeUInt), handed across the
      LongJmp so the landing knows what to keep unwinding. }
    ExnRef: NativeUInt;
  end;

threadvar
  { The current thread's innermost seam catch (Fix A). nil when no compiled body
    is on the stack. Reset by WasmInvoke when a trap unwinds the whole
    invocation, so a trap never leaves it dangling at a reclaimed frame. }
  CurrentSeamCatch: PWasmSeamCatch;

{ Transfer control to the innermost seam catch, carrying AExn. Never returns.
  Must only be called with CurrentSeamCatch <> nil (the unwind guarantees this
  for a rtCompiledSeam frame — such a frame exists only beneath a compiled body,
  which installed a catch). }
procedure SeamHop(const AExn: NativeUInt);

{ Record AKind and transfer to the current trampoline. Never returns.

  With no trampoline installed there are no guest frames to skip, so the
  EWasmTrap is raised directly — which is what makes the memory
  chokepoint testable, and callable, outside an invocation. }
procedure TrapNow(const AKind: TWasmTrapKind);
procedure TrapNowDetail(const AKind: TWasmTrapKind; const ADetail: UInt32);

{ Install the trampoline and run AGuest. A trap anywhere below — whether
  from an explicit check or from the MMU — surfaces here as one
  EWasmTrap with one message, which is ADR-0005's requirement that both
  memory strategies trap identically.

  Nesting is by Prev: a host function called from guest code may itself
  invoke guest code, and each WasmInvoke unwinds only to its own record. }
procedure WasmInvoke(const AGuest: TWasmGuestProc; const AData: Pointer);

{ Install the SIGSEGV/SIGBUS handler once per process. Called lazily by
  the first guard-strategy memory creation, so a store with no
  guard-page memory (32-bit hosts, Windows) installs nothing.

  A no-op where guard strategies do not exist. }
procedure InstallFaultHandler;
function FaultHandlerInstalled: Boolean;

{ Install this thread's alternate signal stack, once. SA_ONSTACK is what
  lets the handler run at all when the fault was a stack overflow; the
  stack is mapped and never released while the thread lives.

  A no-op where guard strategies do not exist. }
procedure EnsureAltSignalStack;

implementation

{ --- messages -------------------------------------------------------- }

function TrapMessage(const AKind: TWasmTrapKind): PAnsiChar;
begin
  case AKind of
    wtkUnreachable: Result := MSG_TRAP_UNREACHABLE;
    wtkMemoryOutOfBounds: Result := MSG_TRAP_MEMORY_OUT_OF_BOUNDS;
    wtkTableOutOfBounds: Result := MSG_TRAP_TABLE_OUT_OF_BOUNDS;
    wtkUndefinedElement: Result := MSG_TRAP_UNDEFINED_ELEMENT;
    wtkUninitializedElement: Result := MSG_TRAP_UNINITIALIZED_ELEMENT;
    wtkIndirectCallTypeMismatch: Result := MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH;
    wtkNullReference: Result := MSG_TRAP_NULL_REFERENCE;
    wtkNullStructReference: Result := MSG_TRAP_NULL_STRUCT_REFERENCE;
    wtkNullArrayReference: Result := MSG_TRAP_NULL_ARRAY_REFERENCE;
    wtkNullFuncReference: Result := MSG_TRAP_NULL_FUNC_REFERENCE;
    wtkNullI31Reference: Result := MSG_TRAP_NULL_I31_REFERENCE;
    wtkDivideByZero: Result := MSG_TRAP_DIVIDE_BY_ZERO;
    wtkIntegerOverflow: Result := MSG_TRAP_INTEGER_OVERFLOW;
    wtkInvalidConversion: Result := MSG_TRAP_INVALID_CONVERSION;
    wtkCastFailure: Result := MSG_TRAP_CAST_FAILURE;
    wtkArrayOutOfBounds: Result := MSG_TRAP_ARRAY_OUT_OF_BOUNDS;
    wtkAllocationFailure: Result := MSG_TRAP_ALLOCATION_FAILURE;
    wtkEpochInterrupt: Result := MSG_TRAP_EPOCH_INTERRUPT;
    wtkStackExhausted: Result := MSG_TRAP_STACK_EXHAUSTED;
    wtkHostTrap: Result := MSG_TRAP_HOST;
  else
    Result := MSG_TRAP_NONE;
  end;
end;

{ --- reservation registry -------------------------------------------- }

type
  TWasmReservation = record
    Base: NativeUInt;
    { Base + ReserveBytes, exclusive. Zero marks a tombstone: no address
      is ever in [0, 0), so the lookup skips it without a branch of its
      own. }
    Limit: NativeUInt;
  end;

  PWasmReservationBlock = ^TWasmReservationBlock;
  TWasmReservationBlock = array[0 .. (High(Integer) div
    SizeOf(TWasmReservation)) - 1] of TWasmReservation;

const
  RESERVATION_INITIAL_CAPACITY = 16;

var
  { Read by the fault handler; written only by ReservationRegister and
    ReservationUnregister, which run on the owning thread outside guest
    execution. GSlotCount is bumped only AFTER the entry it covers has
    been written, so a handler walking concurrently sees a consistent
    prefix. }
  GReservations: PWasmReservationBlock = nil;
  GSlotCount: Integer = 0;
  GCapacity: Integer = 0;
  { Retired blocks. Never freed during execution — a handler may still be
    walking one. Released at unit finalisation, when nothing can be. }
  GRetiredBlocks: array of Pointer;

procedure GrowReservations;
var
  NewCapacity: Integer;
  NewBlock: PWasmReservationBlock;
  Index: Integer;
begin
  if GCapacity = 0 then
    NewCapacity := RESERVATION_INITIAL_CAPACITY
  else
    NewCapacity := GCapacity * 2;

  NewBlock := GetMem(NativeUInt(NewCapacity) * SizeOf(TWasmReservation));
  FillChar(NewBlock^, NativeUInt(NewCapacity) * SizeOf(TWasmReservation), 0);
  for Index := 0 to GSlotCount - 1 do
    NewBlock^[Index] := GReservations^[Index];

  if GReservations <> nil then
  begin
    SetLength(GRetiredBlocks, Length(GRetiredBlocks) + 1);
    GRetiredBlocks[High(GRetiredBlocks)] := GReservations;
  end;

  { One aligned pointer store publishes the new block. }
  GReservations := NewBlock;
  GCapacity := NewCapacity;
end;

procedure ReservationRegister(const ABase: Pointer; const ABytes: NativeUInt);
var
  Index: Integer;
begin
  if ABytes = 0 then
    Exit;

  { Reuse a tombstone before growing, so the handler's scan length stays
    proportional to the number of LIVE reservations. }
  for Index := 0 to GSlotCount - 1 do
    if GReservations^[Index].Limit = 0 then
    begin
      GReservations^[Index].Base := NativeUInt(ABase);
      GReservations^[Index].Limit := NativeUInt(ABase) + ABytes;
      Exit;
    end;

  if GSlotCount = GCapacity then
    GrowReservations;

  GReservations^[GSlotCount].Base := NativeUInt(ABase);
  GReservations^[GSlotCount].Limit := NativeUInt(ABase) + ABytes;
  { Publish last: the entry is complete before the handler can see it. }
  GSlotCount := GSlotCount + 1;
end;

procedure ReservationUnregister(const ABase: Pointer);
var
  Index: Integer;
begin
  for Index := 0 to GSlotCount - 1 do
    if (GReservations^[Index].Limit <> 0) and
      (GReservations^[Index].Base = NativeUInt(ABase)) then
    begin
      GReservations^[Index].Limit := 0;
      GReservations^[Index].Base := 0;
      Exit;
    end;
end;

function ReservationContains(const AAddress: Pointer): Boolean;
var
  Index: Integer;
  Address: NativeUInt;
begin
  Address := NativeUInt(AAddress);
  for Index := 0 to GSlotCount - 1 do
    if (Address >= GReservations^[Index].Base) and
      (Address < GReservations^[Index].Limit) then
      Exit(True);
  Result := False;
end;

function ReservationSlotCount: Integer;
begin
  Result := GSlotCount;
end;

function ReservationLiveCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to GSlotCount - 1 do
    if GReservations^[Index].Limit <> 0 then
      Inc(Result);
end;

{ --- the fault handler ----------------------------------------------- }

{ Split on WASM_GUARD_STRATEGIES, not bare UNIX: a 32-bit UNIX host has no
  guard memory to attribute, so it must install nothing and honestly
  report FaultHandlerInstalled = False, exactly like Windows (fix A5). }
{$IFDEF WASM_GUARD_STRATEGIES}
type
  { Only si_addr is read, so only the prefix up to it has to be right.
    It is declared here rather than taken from BaseUnix because the RTL's
    siginfo record is shaped differently per target and this unit must
    compile identically on every CI leg.

    Linux: three ints, then (on 64-bit only) one int of padding so the
    following union is pointer-aligned, then _sigfault.si_addr.
    Darwin/BSD: si_signo, si_errno, si_code, si_pid, si_uid, si_status,
    then si_addr. }
  PWasmSigInfo = ^TWasmSigInfo;

  TWasmSigInfo = record
    si_signo: cint;
    si_errno: cint;
    si_code: cint;
    {$IF DEFINED(DARWIN) OR DEFINED(FREEBSD) OR DEFINED(NETBSD) OR DEFINED(OPENBSD)}
    si_pid: cint;
    si_uid: cint;
    si_status: cint;
    {$ELSE}
    {$IFDEF CPU64}
    si_pad0: cint;
    {$ENDIF}
    {$ENDIF}
    si_addr: Pointer;
  end;

  TWasmAltStack = record
    ss_sp: Pointer;
    {$IF DEFINED(DARWIN) OR DEFINED(FREEBSD) OR DEFINED(NETBSD) OR DEFINED(OPENBSD)}
    ss_size: NativeUInt;
    ss_flags: cint;
    {$ELSE}
    ss_flags: cint;
    ss_size: NativeUInt;
    {$ENDIF}
  end;

  { The two shapes a previously-installed disposition can take, for
    chaining a fault that is not ours (H3/A2). Which one applies is read
    from the saved action's SA_SIGINFO flag. }
  TWasmSigInfoHandler = procedure(ASig: cint; AInfo: PWasmSigInfo;
    ACtx: Pointer); cdecl;
  TWasmSimpleHandler = procedure(ASig: cint); cdecl;

  { sigaltstack is POSIX but FPC does not surface it through BaseUnix on
    every target, so it is bound directly. }
function Sigaltstack(const ANew: Pointer; const AOld: Pointer): cint; cdecl;
  external 'c' name 'sigaltstack';

{ abort(3) is async-signal-safe and terminates with SIGABRT — used only on
  the "ours but no trampoline" bug path, after a raw diagnostic write. }
procedure CAbort; cdecl; external 'c' name 'abort';

var
  GHandlerInstalled: Boolean = False;
  GOldSegv: SigActionRec;
  GOldBus: SigActionRec;

threadvar
  GAltStackReady: Boolean;

const
  WASM_ALT_STACK_BYTES = 128 * 1024;

{ Ours, but no invocation to unwind to. Chokepoint use outside WasmInvoke
  is forbidden by design (§5): a guard memory may only be touched inside an
  invocation, where a trampoline exists. A fault here is therefore a
  genuine bug, and the previous code's fall-through re-faulted forever
  (H4). Abort loudly instead — async-signal-safe: one raw write, then
  abort(). No allocation, no SysUtils. }
procedure AbortNoTrampoline;
const
  Msg: PAnsiChar =
    'wasmlight: guard-page fault with no active invocation '
    + '(memory chokepoint used outside WasmInvoke)'#10;
var
  Len: NativeUInt;
begin
  Len := 0;
  while Msg[Len] <> #0 do
    Inc(Len);
  FpWrite(StdErrorHandle, Msg^, Len);
  CAbort;
end;

{ Not ours: hand the fault to whatever disposition we replaced, WITHOUT
  ever leaving that old disposition installed in our place — the previous
  code did `fpSigAction(SIG, @GOld, nil)` and returned, uninstalling our
  handler forever while GHandlerInstalled stayed True (H3/A2). }
procedure ChainNotOurs(ASignal: cint; AInfo: PWasmSigInfo;
  AContext: Pointer);
var
  Old: PSigActionRec;
  Handler: Pointer;
begin
  if ASignal = SIGBUS then
    Old := @GOldBus
  else
    Old := @GOldSegv;
  { The disposition occupies offset 0 of the record on every target, the
    same slot the install writes through. }
  Handler := PPointer(Old)^;

  if Handler = Pointer(0) then
  begin
    { SIG_DFL: the default action for SIGSEGV/SIGBUS is to terminate.
      Restore the saved default and re-raise so the process dies with the
      right signal; ours needs no re-arming because we are ending. }
    fpSigAction(ASignal, Old, nil);
    fpKill(fpGetpid, ASignal);
    Exit;
  end;

  if Handler = Pointer(1) then
    { SIG_IGN: the previous disposition ignored the signal. Honour that —
      do nothing, ours stays installed. }
    Exit;

  { A real handler: CALL it, leaving ours in place. }
  if (Old^.sa_flags and SA_SIGINFO) <> 0 then
    TWasmSigInfoHandler(Handler)(ASignal, AInfo, AContext)
  else
    TWasmSimpleHandler(Handler)(ASignal);
end;

procedure WasmFaultHandler(ASignal: cint; AInfo: PWasmSigInfo;
  AContext: Pointer); cdecl;
var
  Trampoline: PWasmTrampoline;
begin
  if (AInfo <> nil) and ReservationContains(AInfo^.si_addr) then
  begin
    Trampoline := CurrentTrampoline;
    if Trampoline = nil then
      AbortNoTrampoline;   { never returns }
    Trampoline^.Kind := wtkMemoryOutOfBounds;
    Trampoline^.Detail := 0;
    { SA_NODEFER kept SIGSEGV/SIGBUS out of the mask and plain LongJmp
      leaves the mask untouched, so the next fault is still deliverable.
      No fpsigprocmask here — that would mutate the host's mask (L2). }
    LongJmp(Trampoline^.JmpBuf, 1);
  end;

  ChainNotOurs(ASignal, AInfo, AContext);
end;

procedure InstallFaultHandler;
var
  Action: SigActionRec;
begin
  if GHandlerInstalled then
    Exit;

  { Zeroing is also what empties the signal mask: an all-zero sigset is
    the empty set on every POSIX target, so no fpsigemptyset is needed
    and the field's per-target spelling never comes up. }
  FillChar(Action, SizeOf(Action), 0);
  { SA_SIGINFO for si_addr, SA_ONSTACK so a stack-overflow fault can still
    run the handler, SA_NODEFER so jumping out does not leave the signal
    blocked. }
  Action.sa_flags := SA_SIGINFO or SA_ONSTACK or SA_NODEFER;
  { The handler occupies offset 0 of struct sigaction on every POSIX ABI
    this project targets, but FPC spells the field differently per target
    — a plain procedure pointer on Darwin and the BSDs, a variant record
    over the one- and three-argument forms on Linux. Writing through the
    record's address is the one form that compiles unchanged on all of
    them, and the cast is what a SA_SIGINFO handler needs in any case. }
  PPointer(@Action)^ := Pointer(@WasmFaultHandler);

  { Linux delivers SIGSEGV for a guard-page access; macOS may deliver
    either, and SIGBUS is also what a truncated file-backed mapping
    raises. Both are claimed. A3: check each install and never leave a
    half-installed pair — restore SIGSEGV if SIGBUS fails — and only claim
    installation once BOTH succeed. A failure here is a resource failure,
    not a guest fault, so EWasmError is the right class. }
  if fpSigAction(SIGSEGV, @Action, @GOldSegv) <> 0 then
    raise EWasmError.Create('cannot install the SIGSEGV fault handler');
  if fpSigAction(SIGBUS, @Action, @GOldBus) <> 0 then
  begin
    fpSigAction(SIGSEGV, @GOldSegv, nil);
    raise EWasmError.Create('cannot install the SIGBUS fault handler');
  end;

  GHandlerInstalled := True;
end;

function FaultHandlerInstalled: Boolean;
begin
  Result := GHandlerInstalled;
end;

procedure EnsureAltSignalStack;
var
  Stack: TWasmAltStack;
  Memory: Pointer;
  Size: NativeUInt;
begin
  if GAltStackReady then
    Exit;

  { A fixed size rather than SIGSTKSZ: glibc 2.34 made SIGSTKSZ a runtime
    query rather than a constant, and FPC does not surface it on every
    target. 128 KiB is comfortably above every platform's minimum and the
    mapping is lazily backed, so the slack costs nothing. }
  Size := WASM_ALT_STACK_BYTES;

  Memory := Fpmmap(nil, Size, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if Memory = Pointer(-1) then
    Exit;

  Stack.ss_sp := Memory;
  Stack.ss_size := Size;
  Stack.ss_flags := 0;
  if Sigaltstack(@Stack, nil) = 0 then
    { Never unmapped: the stack must outlive every handler that could run
      on it, which is the whole life of the thread. }
    GAltStackReady := True
  else
    Fpmunmap(Memory, Size);
end;

{$ELSE}

{ No guard strategies here: Windows this wave (ADR-0005 names explicit
  checks as the fallback path, and ADR-0009's SEH leg is unbuilt) and
  every 32-bit host, UNIX included (it cannot reserve 4 GiB). With no
  guard memory there is nothing to attribute and no handler to install, so
  these are honest no-ops rather than stubs waiting to be filled. Gating on
  WASM_GUARD_STRATEGIES rather than UNIX is what keeps a 32-bit UNIX host
  from installing a real handler while reporting itself a no-op (A5). }

procedure InstallFaultHandler;
begin
end;

function FaultHandlerInstalled: Boolean;
begin
  Result := False;
end;

procedure EnsureAltSignalStack;
begin
end;

{$ENDIF}

{ --- trampoline ------------------------------------------------------ }

{ Cold, and deliberately not inlined: it allocates the exception's
  message string, which is managed state and must never appear on a frame
  the jump can skip. Only ever called on ordinary ground — after the jump
  in WasmInvoke, or directly when there is no invocation — so the
  allocation (and IntToStr below) is safe here. }
procedure RaiseTrapDirect(const AKind: TWasmTrapKind; const ADetail: UInt32;
  const AHostMsg: PAnsiChar);
var
  Msg: string;
begin
  if (AKind = wtkHostTrap) and (AHostMsg <> nil) then
    Msg := string(AnsiString(AHostMsg))
  else if AKind = wtkUninitializedElement then
    { The corpus carries the element index (corpus bulk.wast:222,
      'uninitialized element 2'); Detail holds it. The runner prefix-
      matches, so both the bare and the indexed corpus forms pass against
      this one spelling (L1). }
    Msg := string(AnsiString(TrapMessage(AKind))) + ' ' + IntToStr(ADetail)
  else
    Msg := string(AnsiString(TrapMessage(AKind)));
  raise EWasmTrap.Create(Msg);
end;

procedure TrapNowDetail(const AKind: TWasmTrapKind; const ADetail: UInt32);
var
  Trampoline: PWasmTrampoline;
begin
  Trampoline := CurrentTrampoline;
  if Trampoline = nil then
  begin
    { Outside an invocation there are no guest frames to skip, so
      ordinary Pascal exception machinery is safe — and it is what makes
      the memory chokepoint directly testable. }
    RaiseTrapDirect(AKind, ADetail, nil);
    Exit;
  end;

  Trampoline^.Kind := AKind;
  Trampoline^.Detail := ADetail;
  LongJmp(Trampoline^.JmpBuf, 1);
end;

procedure TrapNow(const AKind: TWasmTrapKind);
begin
  TrapNowDetail(AKind, 0);
end;

procedure SeamHop(const AExn: NativeUInt);
begin
  CurrentSeamCatch^.ExnRef := AExn;
  LongJmp(CurrentSeamCatch^.JmpBuf, 1);
end;

procedure WasmInvoke(const AGuest: TWasmGuestProc; const AData: Pointer);
var
  Trampoline: TWasmTrampoline;
  SavedSeam: PWasmSeamCatch;
begin
  { No managed locals here, by TRAP-1: the record is plain data and its
    address is taken, so it is on the stack rather than in a register the
    jump would clobber. }
  Trampoline.Prev := CurrentTrampoline;
  Trampoline.Kind := wtkNone;
  Trampoline.Detail := 0;
  Trampoline.HostMsg := nil;
  Trampoline.Context := nil;
  CurrentTrampoline := @Trampoline;
  { Fix A: seam catches nest within this invocation. A trap LongJmps straight to
    this trampoline, discarding every seam-catch frame above without popping the
    stack — so save the pre-invocation value and restore it on BOTH exits, or a
    later SeamHop would jump into a reclaimed frame. }
  SavedSeam := CurrentSeamCatch;

  if SetJmp(Trampoline.JmpBuf) = 0 then
  begin
    { The restore is in a finally so an ORDINARY Pascal exception escaping
      the guest — EWasmError, EWasmLinkError, EOutOfMemory — cannot leave
      CurrentTrampoline dangling at this now-reclaimed frame; the next
      TrapNow would otherwise longjmp into a dead jmp_buf (H2). This
      try..finally does not violate TRAP-1: WasmInvoke's own frame is
      ABOVE the trampoline it installs, not one of the guest frames a
      longjmp skips, so its finalisation always runs on ordinary ground.
      A trap's LongJmp lands in the else branch below and never enters
      this try. }
    try
      AGuest(AData);
    finally
      CurrentTrampoline := Trampoline.Prev;
      CurrentSeamCatch := SavedSeam;
    end;
  end
  else
  begin
    { Ordinary ground again: unwound past every guest frame, so the
      exception below is free to allocate. }
    CurrentTrampoline := Trampoline.Prev;
    CurrentSeamCatch := SavedSeam;
    RaiseTrapDirect(Trampoline.Kind, Trampoline.Detail, Trampoline.HostMsg);
  end;
end;

var
  GRetiredIndex: Integer;

initialization
  GrowReservations;

finalization
  { Safe only here: no handler can be walking a block once execution is
    over. During execution a retired block is deliberately kept alive. }
  for GRetiredIndex := 0 to High(GRetiredBlocks) do
    FreeMem(GRetiredBlocks[GRetiredIndex]);
  GRetiredBlocks := nil;
  if GReservations <> nil then
  begin
    FreeMem(GReservations);
    GReservations := nil;
  end;
  GCapacity := 0;
  GSlotCount := 0;

end.
