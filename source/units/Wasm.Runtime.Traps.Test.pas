{ Unit suite for Wasm.Runtime.Traps.

  A real MMU fault is not raised HERE: the design's acceptance test is a
  SIGSEGV raised inside a WasmInvoke at an address inside a registered
  reservation, arriving as an EWasmTrap. Run in-process, a wrong handler
  would kill the whole runner with no diagnostic, so it runs in a FORKED
  CHILD — and it now exists, as TestGuardFaultTrapsInAForkedChild in
  Wasm.Runtime.Memory.Test (it needs a guard memory to fault, so it lives
  with the memory suite). The parent asserts the child trapped and exited
  cleanly rather than crashing.

  Everything the fault path is made of is testable without faulting, and
  is tested below: the registry decides membership exactly (that is the
  whole of attribution), and the trampoline converts a recorded trap into
  an EWasmTrap through the same longjmp the handler would use — the
  explicit-check route and the fault route differ only in who writes the
  kind. }
program Wasm.Runtime.Traps.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Runtime.Traps;

type
  TRuntimeTrapsTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestConfirmedMessages;
    procedure TestNullReferenceMessagesPerKind;
    procedure TestCorpusConfirmedMessages;
    procedure TestUninitializedElementCarriesIndex;
    procedure TestTrapKindsAreNotCollapsed;
    procedure TestInvokeRestoresTrampolineAfterPascalError;
    procedure TestRegistryMembershipIsExact;
    procedure TestRegistryHandlesSeveralReservations;
    procedure TestUnregisterRemovesMembership;
    procedure TestUnregisterTombstonesAndSlotsAreReused;
    procedure TestZeroLengthReservationIsIgnored;
    procedure TestInvokeReturnsCleanly;
    procedure TestInvokeConvertsATrap;
    procedure TestTrapOutsideAnInvocationRaisesDirectly;
    procedure TestNestedInvocationsUnwindToTheirOwn;
    procedure TestHandlerInstallationIsIdempotent;
  end;

var
  { Guest regions are plain procedures, not methods: a method reference
    is managed state on a frame the jump can skip (TRAP-1). Their
    bookkeeping therefore lives in globals. }
  GGuestRan: Boolean;
  GGuestSawTrap: Boolean;
  GOuterResumed: Boolean;

procedure GuestThatReturns(const AData: Pointer);
begin
  GGuestRan := True;
end;

procedure GuestThatTraps(const AData: Pointer);
begin
  GGuestRan := True;
  TrapNow(wtkMemoryOutOfBounds);
  { Unreachable: TrapNow never returns. }
  GGuestRan := False;
end;

procedure GuestThatTrapsWithDetail(const AData: Pointer);
begin
  TrapNowDetail(wtkTableOutOfBounds, 7);
end;

{ Raises an ORDINARY Pascal exception (not a trap): it does not longjmp,
  so it unwinds through WasmInvoke's finally rather than its else branch. }
procedure GuestThatRaisesError(const AData: Pointer);
begin
  raise EWasmError.Create('guest boom');
end;

procedure GuestTrapsUninitializedElement(const AData: Pointer);
begin
  TrapNowDetail(wtkUninitializedElement, 2);
end;

{ A host function called from guest code, itself invoking guest code.
  The inner trap must raise at the INNER trampoline and propagate as an
  ordinary Pascal exception through this frame, which is host ground. }
procedure OuterGuest(const AData: Pointer);
begin
  try
    WasmInvoke(GuestThatTrapsWithDetail, nil);
  except
    on E: EWasmTrap do
    begin
      GGuestSawTrap := E.Message = MSG_TRAP_TABLE_OUT_OF_BOUNDS;
    end;
  end;
  GOuterResumed := True;
end;

procedure TRuntimeTrapsTests.TestConfirmedMessages;
begin
  { Read from wasm-mcp instruction_get at the pin
    d7b37e4170d8315f2f1283aed4e8076591a9a333. These are the spellings
    the .wast corpus prefix-matches, so a typo here is a conformance
    failure everywhere at once. }
  Expect<string>(string(TrapMessage(wtkUnreachable))).ToBe('unreachable');
  Expect<string>(string(TrapMessage(wtkMemoryOutOfBounds)))
    .ToBe('out of bounds memory access');
  Expect<string>(string(TrapMessage(wtkTableOutOfBounds)))
    .ToBe('out of bounds table access');
  Expect<string>(string(TrapMessage(wtkUndefinedElement)))
    .ToBe('undefined element');
  Expect<string>(string(TrapMessage(wtkUninitializedElement)))
    .ToBe('uninitialized element');
  Expect<string>(string(TrapMessage(wtkIndirectCallTypeMismatch)))
    .ToBe('indirect call type mismatch');
  Expect<string>(string(TrapMessage(wtkNullReference))).ToBe('null reference');
  Expect<string>(string(TrapMessage(wtkDivideByZero)))
    .ToBe('integer divide by zero');
  Expect<string>(string(TrapMessage(wtkIntegerOverflow)))
    .ToBe('integer overflow');
  Expect<string>(string(TrapMessage(wtkInvalidConversion)))
    .ToBe('invalid conversion to integer');
end;

procedure TRuntimeTrapsTests.TestNullReferenceMessagesPerKind;
begin
  { H5: the null-dereference family is NOT one message. Each spelling is
    the one the corpus prefix-matches for that hierarchy. }
  Expect<string>(string(TrapMessage(wtkNullReference))).ToBe('null reference');
  Expect<string>(string(TrapMessage(wtkNullStructReference)))
    .ToBe('null structure reference');
  Expect<string>(string(TrapMessage(wtkNullArrayReference)))
    .ToBe('null array reference');
  Expect<string>(string(TrapMessage(wtkNullFuncReference)))
    .ToBe('null function reference');
  Expect<string>(string(TrapMessage(wtkNullI31Reference)))
    .ToBe('null i31 reference');
  { Distinct — collapsing any pair is a conformance bug. The bare message
    is a prefix of none of the typed ones, so prefix-matching keeps them
    apart. }
  Expect<Boolean>(string(TrapMessage(wtkNullStructReference)) =
    string(TrapMessage(wtkNullArrayReference))).ToBe(False);
  Expect<Boolean>(string(TrapMessage(wtkNullFuncReference)) =
    string(TrapMessage(wtkNullReference))).ToBe(False);
end;

procedure TRuntimeTrapsTests.TestCorpusConfirmedMessages;
begin
  { Settled from the Track C corpus, not the MCP — the pinned server
    reports can_trap:false for ref.cast and array.get, and does not carry
    the exhaustion message at all. }
  Expect<string>(string(TrapMessage(wtkCastFailure))).ToBe('cast failure');
  Expect<string>(string(TrapMessage(wtkArrayOutOfBounds)))
    .ToBe('out of bounds array access');
  Expect<string>(string(TrapMessage(wtkStackExhausted)))
    .ToBe('call stack exhausted');
end;

procedure TRuntimeTrapsTests.TestUninitializedElementCarriesIndex;
var
  Caught: string;
begin
  { L1: the corpus spells 'uninitialized element 2' (corpus bulk.wast:222);
    Detail carries the index and RaiseTrapDirect appends it. The runner
    prefix-matches, so the bare 'uninitialized element' cases pass against
    this same message too. }
  Caught := '';
  try
    WasmInvoke(GuestTrapsUninitializedElement, nil);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe('uninitialized element 2');

  { The direct-raise path (no invocation) appends the index as well. }
  Caught := '';
  try
    TrapNowDetail(wtkUninitializedElement, 5);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe('uninitialized element 5');
end;

procedure TRuntimeTrapsTests.TestTrapKindsAreNotCollapsed;
begin
  { call_indirect's out-of-range message is NOT table.get's. The two are
    separately confirmed and unifying them is a conformance bug. }
  Expect<Boolean>(string(TrapMessage(wtkUndefinedElement)) =
    string(TrapMessage(wtkTableOutOfBounds))).ToBe(False);
  { wtkNone is not a trap and must not spell like one. }
  Expect<string>(string(TrapMessage(wtkNone))).ToBe('no trap');
end;

procedure TRuntimeTrapsTests.TestInvokeRestoresTrampolineAfterPascalError;
var
  SawError: Boolean;
  Caught: string;
begin
  { H2: an ORDINARY Pascal exception escaping the guest — not a trap,
    hence no longjmp — must still restore the trampoline chain via
    WasmInvoke's finally. Without it, CurrentTrampoline would dangle at a
    reclaimed frame and the next TrapNow would longjmp into a dead
    jmp_buf. }
  SawError := False;
  try
    WasmInvoke(GuestThatRaisesError, nil);
  except
    on E: EWasmError do
      SawError := True;
  end;
  Expect<Boolean>(SawError).ToBe(True);
  Expect<Boolean>(CurrentTrampoline = nil).ToBe(True);

  { The proof it matters: a fresh invocation that traps still works,
    landing one EWasmTrap on ordinary ground rather than crashing. }
  GGuestRan := False;
  Caught := '';
  try
    WasmInvoke(GuestThatTraps, nil);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<Boolean>(GGuestRan).ToBe(True);
  Expect<string>(Caught).ToBe(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
  Expect<Boolean>(CurrentTrampoline = nil).ToBe(True);
end;

procedure TRuntimeTrapsTests.TestRegistryMembershipIsExact;
var
  Base: Pointer;
begin
  { The attribution question in full: is this address inside a mapping we
    made. Getting the ends wrong either swallows an unrelated SIGSEGV or
    misses a real guard fault. }
  Base := Pointer(NativeUInt($10000000));
  ReservationRegister(Base, 4096);

  Expect<Boolean>(ReservationContains(Base)).ToBe(True);
  Expect<Boolean>(ReservationContains(Pointer(NativeUInt(Base) + 4095)))
    .ToBe(True);
  { Half-open: the limit itself is outside. }
  Expect<Boolean>(ReservationContains(Pointer(NativeUInt(Base) + 4096)))
    .ToBe(False);
  Expect<Boolean>(ReservationContains(Pointer(NativeUInt(Base) - 1)))
    .ToBe(False);
  Expect<Boolean>(ReservationContains(nil)).ToBe(False);

  ReservationUnregister(Base);
end;

procedure TRuntimeTrapsTests.TestRegistryHandlesSeveralReservations;
var
  First: Pointer;
  Second: Pointer;
  Live: Integer;
begin
  First := Pointer(NativeUInt($20000000));
  Second := Pointer(NativeUInt($30000000));
  Live := ReservationLiveCount;

  ReservationRegister(First, 65536);
  ReservationRegister(Second, 65536);
  Expect<Integer>(ReservationLiveCount).ToBe(Live + 2);
  Expect<Boolean>(ReservationContains(First)).ToBe(True);
  Expect<Boolean>(ReservationContains(Second)).ToBe(True);
  { The gap between them belongs to nobody. }
  Expect<Boolean>(ReservationContains(Pointer(NativeUInt($28000000))))
    .ToBe(False);

  ReservationUnregister(First);
  ReservationUnregister(Second);
  Expect<Integer>(ReservationLiveCount).ToBe(Live);
end;

procedure TRuntimeTrapsTests.TestUnregisterRemovesMembership;
var
  Base: Pointer;
begin
  { Deregistration must precede the unmap, or a fault at a reused address
    is attributed to us. The property that makes that work is simply that
    it takes effect immediately. }
  Base := Pointer(NativeUInt($40000000));
  ReservationRegister(Base, 8192);
  Expect<Boolean>(ReservationContains(Base)).ToBe(True);
  ReservationUnregister(Base);
  Expect<Boolean>(ReservationContains(Base)).ToBe(False);
end;

procedure TRuntimeTrapsTests.TestUnregisterTombstonesAndSlotsAreReused;
var
  Base: Pointer;
  Slots: Integer;
begin
  { A tombstone is reused rather than appended past, so the handler's
    scan stays proportional to the number of LIVE reservations rather
    than to how many have ever existed. }
  Base := Pointer(NativeUInt($50000000));
  ReservationRegister(Base, 4096);
  Slots := ReservationSlotCount;
  ReservationUnregister(Base);
  Expect<Integer>(ReservationSlotCount).ToBe(Slots);

  ReservationRegister(Base, 4096);
  Expect<Integer>(ReservationSlotCount).ToBe(Slots);
  Expect<Boolean>(ReservationContains(Base)).ToBe(True);
  ReservationUnregister(Base);
end;

procedure TRuntimeTrapsTests.TestZeroLengthReservationIsIgnored;
var
  Live: Integer;
begin
  { An empty range can never contain an address, so recording one would
    only lengthen the handler's scan. }
  Live := ReservationLiveCount;
  ReservationRegister(Pointer(NativeUInt($60000000)), 0);
  Expect<Integer>(ReservationLiveCount).ToBe(Live);
  Expect<Boolean>(ReservationContains(Pointer(NativeUInt($60000000))))
    .ToBe(False);
end;

procedure TRuntimeTrapsTests.TestInvokeReturnsCleanly;
begin
  GGuestRan := False;
  WasmInvoke(GuestThatReturns, nil);
  Expect<Boolean>(GGuestRan).ToBe(True);
  { The trampoline chain must be back where it started, or the next
    invocation would jump into a dead frame. }
  Expect<Boolean>(CurrentTrampoline = nil).ToBe(True);
end;

procedure TRuntimeTrapsTests.TestInvokeConvertsATrap;
var
  Caught: string;
begin
  GGuestRan := False;
  Caught := '';
  try
    WasmInvoke(GuestThatTraps, nil);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<Boolean>(GGuestRan).ToBe(True);
  { One EWasmTrap, one message, raised on ordinary ground above the
    jump — which is what makes both memory strategies indistinguishable
    to a host (ADR-0005). }
  Expect<string>(Caught).ToBe(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
  Expect<Boolean>(CurrentTrampoline = nil).ToBe(True);
end;

procedure TRuntimeTrapsTests.TestTrapOutsideAnInvocationRaisesDirectly;
var
  Caught: string;
begin
  { With no trampoline there are no guest frames to skip, so the trap is
    raised directly. This is what makes the memory chokepoint callable,
    and testable, outside an invocation. }
  Caught := '';
  try
    TrapNow(wtkNullReference);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_REFERENCE);
end;

procedure TRuntimeTrapsTests.TestNestedInvocationsUnwindToTheirOwn;
begin
  GGuestSawTrap := False;
  GOuterResumed := False;
  { host -> guest -> host -> guest. The inner trap raises at the inner
    trampoline; the frame above it is host code, which may hold managed
    state because it is above a trampoline. The outer invocation must
    survive and return normally. }
  WasmInvoke(OuterGuest, nil);
  Expect<Boolean>(GGuestSawTrap).ToBe(True);
  Expect<Boolean>(GOuterResumed).ToBe(True);
  Expect<Boolean>(CurrentTrampoline = nil).ToBe(True);
end;

procedure TRuntimeTrapsTests.TestHandlerInstallationIsIdempotent;
begin
  InstallFaultHandler;
  InstallFaultHandler;
  { POSIX installs; Windows has no guard strategy this wave and so has
    nothing to install (ADR-0009's SEH leg is unbuilt). }
  {$IFDEF UNIX}
  Expect<Boolean>(FaultHandlerInstalled).ToBe(True);
  {$ELSE}
  Expect<Boolean>(FaultHandlerInstalled).ToBe(False);
  {$ENDIF}
end;

procedure TRuntimeTrapsTests.SetupTests;
begin
  Test('confirmed trap messages match the pinned spec',
    TestConfirmedMessages);
  Test('the null-reference family has one message per hierarchy',
    TestNullReferenceMessagesPerKind);
  Test('cast/array/exhaustion messages are corpus-confirmed',
    TestCorpusConfirmedMessages);
  Test('an uninitialized-element trap carries the element index',
    TestUninitializedElementCarriesIndex);
  Test('separately confirmed trap kinds are not collapsed',
    TestTrapKindsAreNotCollapsed);
  Test('an ordinary Pascal error escaping a guest restores the trampoline',
    TestInvokeRestoresTrampolineAfterPascalError);
  Test('reservation membership is exact at both ends',
    TestRegistryMembershipIsExact);
  Test('the registry separates several reservations',
    TestRegistryHandlesSeveralReservations);
  Test('unregistering removes membership immediately',
    TestUnregisterRemovesMembership);
  Test('unregistering tombstones and the slot is reused',
    TestUnregisterTombstonesAndSlotsAreReused);
  Test('a zero-length reservation is never recorded',
    TestZeroLengthReservationIsIgnored);
  Test('an invocation that does not trap returns cleanly',
    TestInvokeReturnsCleanly);
  Test('the trampoline converts a trap into one EWasmTrap',
    TestInvokeConvertsATrap);
  Test('a trap outside an invocation raises directly',
    TestTrapOutsideAnInvocationRaisesDirectly);
  Test('nested invocations unwind to their own trampoline',
    TestNestedInvocationsUnwindToTheirOwn);
  Test('fault handler installation is idempotent',
    TestHandlerInstallationIsIdempotent);
end;

begin
  TestRunnerProgram.AddSuite(TRuntimeTrapsTests.Create('Wasm.Runtime.Traps'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
