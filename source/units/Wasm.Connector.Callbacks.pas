{ Wasm.Connector.Callbacks — target-ABI callback thunks, lifetimes, and
  deferred failures for native connectors (issue #45, ADR-0008 / ADR-0015).

  Native libraries such as SDL and raylib call C function pointers. This
  unit hands out those pointers and re-enters a guest function through the
  existing InterpInvoke trampoline. It is embedding-layer machinery: it
  adds no spec rule, does not read a module binary, and does not sit in
  an execution tier.

  Why a Pascal slot pool rather than JIT-emitted stubs: unique C pointers
  are required (raylib's TraceLog / AudioCallback carry no userdata), but
  Wasm.Jit.CodeBuffer is a 64-bit-UNIX tier unit and Windows / 32-bit
  hosts are interpreter-only. Tiny cdecl thunks compile everywhere and
  stay observationally identical to a later specialized emitter that
  calls the same dispatch.

  INVARIANTS:

    - Direct and scoped thunks re-enter only on the store thread. A
      foreign-thread synchronous result or buffer pointer is rejected —
      that is direct-embedding work, not a queued notification.
    - [Queued] is a void notification: scalar arguments are copied; a
      result, ref, out, or borrow is refused at Bind.
    - EWasmTrap, EWasmException, and EWasmExit never leave a thunk. The
      native caller sees the result type's zero; the exact failure is
      retained and rethrown on Pascal ground (RethrowDeferred / Drain).
      Bind and off-thread rejects raise EWasmCallbackError, never a trap,
      throw, exit, or EWasmConnectorError.
    - The store itself is not locked (ADR-0008). The only synchronisation
      is the slot/queue lock around the foreign-thread edge.
    - Function-reference identity is rooted for the binding's life
      (HOST-1) and the same (store, func, shape, lifetime, scope)
      returns the same pointer.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Guest invocation
  reuses Engine.Call / InterpInvoke; no new Core 3 rule is interpreted
  here. }
unit Wasm.Connector.Callbacks;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Connector,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

const
  { Bind / dispatch prefixes. Asserted by the co-located suite; the
    corpus never sees them — this is a host-surface contract, not a
    module-facing decode/validation message. }
  MSG_CALLBACK_SHAPE = 'callback shape does not match function';
  MSG_CALLBACK_QUEUED_SHAPE =
    'queued callback cannot carry results, refs, or borrows';
  MSG_CALLBACK_OFF_THREAD = 'direct callback off store thread';
  MSG_CALLBACK_SLOTS = 'callback thunk slots exhausted';
  MSG_CALLBACK_STORE = 'callback is bound to a different store';

  WASM_CALLBACK_SLOT_COUNT = 8;

type
  { Bind/dispatch contract failure. A sibling of EWasmConnectorError (which
    is .wlc source) and of EWasmTrap / EWasmException / EWasmExit (which are
    guest outcomes). Hosts discriminate on the class; do not raise a bare
    EWasmError here. }
  EWasmCallbackError = class(EWasmError);

  { Representative C shapes. Pointers marshal as i32 tokens so the same
    guest module is valid on 32- and 64-bit hosts; the connector ABI
    planner (issue #43) will emit width-correct plans later. }
  TWasmCallbackShape = (
    wcsVoid,
    wcsVoidI32,
    wcsI32,
    wcsI32I32,
    wcsVoidPtrU32,
    wcsI32PtrPtr
  );

  TWasmCallbackProc = procedure; cdecl;
  TWasmCallbackProcI32 = procedure(AValue: Int32); cdecl;
  TWasmCallbackFnI32 = function: Int32; cdecl;
  TWasmCallbackFnI32I32 = function(AValue: Int32): Int32; cdecl;
  TWasmCallbackAudio = procedure(ABuffer: Pointer; AFrames: UInt32); cdecl;
  TWasmCallbackFilter = function(AUserData: Pointer;
    AEvent: Pointer): Int32; cdecl;

  { One hub per store. The cdecl thunks outlive the hub: after Destroy
    they return zero and do not touch the store. }
  TWasmCallbackHub = class
  private
    FStore: TWasmStore;
    FScopeDepth: Integer;
    FDeferred: EWasmError;
    FExnRoot: TWasmRootHandle;
    FDead: Boolean;
    FInFlight: Integer;

    procedure Capture(E: EWasmError);
    procedure ReleaseSlot(const AIndex: Integer);
  public
    constructor Create(const AStore: TWasmStore);
    destructor Destroy; override;

    { Return a target-ABI function pointer for AFunc. Deduplicates a live
      binding of the same function, shape, lifetime, and scope. Lifetime is
      TWlcCallbackKind — one vocabulary with the .wlc declaration model. }
    function Bind(const AFunc: TWasmFunc; const AShape: TWasmCallbackShape;
      const ALifetime: TWlcCallbackKind): Pointer;
    procedure Unbind(const AThunk: Pointer);

    function BeginScope: Integer;
    procedure EndScope(const AMark: Integer);

    { Deliver queued notifications on the store thread, then rethrow the
      first retained guest failure if any. }
    procedure DrainQueued;

    function HasDeferredFailure: Boolean;
    procedure RethrowDeferred;

    property Store: TWasmStore read FStore;
  end;

implementation

type
  TCallbackSlot = record
    Used: Boolean;
    Hub: TWasmCallbackHub;
    Store: TWasmStore;
    Func: TWasmFunc;
    Shape: TWasmCallbackShape;
    Lifetime: TWlcCallbackKind;
    ScopeDepth: Integer;
    Root: TWasmRootHandle;
  end;

  TQueuedNote = record
    Slot: Integer;
    A0: Int64;
    A1: Int64;
  end;

var
  GLock: TRTLCriticalSection;
  GSlots: array[0..WASM_CALLBACK_SLOT_COUNT - 1] of TCallbackSlot;
  GNotes: array of TQueuedNote;
  GNoteCount: Integer;

function IsI32(const AType: TWasmValueType): Boolean;
begin
  Result := (AType.Kind = wvkNum) and (AType.Num = wntI32);
end;

function ShapeAllowsQueued(const AShape: TWasmCallbackShape): Boolean;
begin
  Result := AShape in [wcsVoid, wcsVoidI32];
end;

function ShapeMatches(const AFunc: TWasmFunc;
  const AShape: TWasmCallbackShape): Boolean;
var
  P, R: Integer;
begin
  P := Length(AFunc.ParamTypes);
  R := Length(AFunc.ResultTypes);
  case AShape of
    wcsVoid:
      Result := (P = 0) and (R = 0);
    wcsVoidI32:
      Result := (P = 1) and (R = 0) and IsI32(AFunc.ParamTypes[0]);
    wcsI32:
      Result := (P = 0) and (R = 1) and IsI32(AFunc.ResultTypes[0]);
    wcsI32I32:
      Result := (P = 1) and (R = 1) and IsI32(AFunc.ParamTypes[0]) and
        IsI32(AFunc.ResultTypes[0]);
    wcsVoidPtrU32:
      Result := (P = 2) and (R = 0) and IsI32(AFunc.ParamTypes[0]) and
        IsI32(AFunc.ParamTypes[1]);
    wcsI32PtrPtr:
      Result := (P = 2) and (R = 1) and IsI32(AFunc.ParamTypes[0]) and
        IsI32(AFunc.ParamTypes[1]) and IsI32(AFunc.ResultTypes[0]);
  else
    Result := False;
  end;
end;

function SameFunc(const A, B: TWasmFunc): Boolean;
begin
  Result := (A.Store = B.Store) and (A.Addr = B.Addr);
end;

function OnStoreThread(const AStore: TWasmStore): Boolean;
begin
  Result := (AStore <> nil) and (GetCurrentThreadId = AStore.OwnerThread);
end;

procedure EnqueueNote(const ASlot: Integer; const AA0, AA1: Int64);
begin
  if GNoteCount >= Length(GNotes) then
  begin
    if Length(GNotes) = 0 then
      SetLength(GNotes, 8)
    else
      SetLength(GNotes, Length(GNotes) * 2);
  end;
  GNotes[GNoteCount].Slot := ASlot;
  GNotes[GNoteCount].A0 := AA0;
  GNotes[GNoteCount].A1 := AA1;
  Inc(GNoteCount);
end;

procedure TWasmCallbackHub.Capture(E: EWasmError);
begin
  if E = nil then
    Exit;
  { First failure wins. The lock is the only shared edge with a foreign
    thunk; the store itself is still unsynchronised (ADR-0008). }
  EnterCriticalSection(GLock);
  try
    if FDeferred <> nil then
      Exit;
    AcquireExceptionObject;
    FDeferred := E;
    if (E is EWasmException) and (FStore <> nil) and OnStoreThread(FStore) then
      FExnRoot := RootExceptionRef(FStore, EWasmException(E));
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure TWasmCallbackHub.ReleaseSlot(const AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= WASM_CALLBACK_SLOT_COUNT) then
    Exit;
  if GSlots[AIndex].Root <> WASM_NO_ROOT then
  begin
    if GSlots[AIndex].Store <> nil then
      RootRelease(GSlots[AIndex].Store, GSlots[AIndex].Root);
    GSlots[AIndex].Root := WASM_NO_ROOT;
  end;
  GSlots[AIndex].Used := False;
  GSlots[AIndex].Hub := nil;
  GSlots[AIndex].Store := nil;
  GSlots[AIndex].Func.Store := nil;
  GSlots[AIndex].Func.Addr := 0;
  GSlots[AIndex].Func.ParamTypes := nil;
  GSlots[AIndex].Func.ResultTypes := nil;
end;

constructor TWasmCallbackHub.Create(const AStore: TWasmStore);
begin
  inherited Create;
  if AStore = nil then
    raise EWasmCallbackError.Create('callback hub needs a store');
  FStore := AStore;
  FExnRoot := WASM_NO_ROOT;
  FDead := False;
  FInFlight := 0;
end;

destructor TWasmCallbackHub.Destroy;
var
  Index: Integer;
begin
  FDead := True;
  while True do
  begin
    EnterCriticalSection(GLock);
    if FInFlight = 0 then
      Break;
    LeaveCriticalSection(GLock);
    Sleep(1);
  end;
  try
    Index := 0;
    while Index < GNoteCount do
      if (GNotes[Index].Slot >= 0) and
        (GNotes[Index].Slot < WASM_CALLBACK_SLOT_COUNT) and
        (GSlots[GNotes[Index].Slot].Hub = Self) then
      begin
        GNotes[Index] := GNotes[GNoteCount - 1];
        Dec(GNoteCount);
      end
      else
        Inc(Index);
    for Index := 0 to WASM_CALLBACK_SLOT_COUNT - 1 do
      if GSlots[Index].Used and (GSlots[Index].Hub = Self) then
        ReleaseSlot(Index);
  finally
    LeaveCriticalSection(GLock);
  end;
  if (FExnRoot <> WASM_NO_ROOT) and (FStore <> nil) then
    RootRelease(FStore, FExnRoot);
  FExnRoot := WASM_NO_ROOT;
  FreeAndNil(FDeferred);
  inherited Destroy;
end;

function InvokeBound(const ASlot: Integer; const AA0, AA1: Int64): Int64;
var
  Hub: TWasmCallbackHub;
  Func: TWasmFunc;
  Shape: TWasmCallbackShape;
  Lifetime: TWlcCallbackKind;
  Params, Results: array of TWasmValue;
  OffThread: Boolean;
begin
  Result := 0;
  Hub := nil;
  OffThread := False;
  EnterCriticalSection(GLock);
  try
    if (ASlot < 0) or (ASlot >= WASM_CALLBACK_SLOT_COUNT) then
      Exit;
    if not GSlots[ASlot].Used or (GSlots[ASlot].Hub = nil) or
      GSlots[ASlot].Hub.FDead then
      Exit;
    Hub := GSlots[ASlot].Hub;
    Func := GSlots[ASlot].Func;
    Shape := GSlots[ASlot].Shape;
    Lifetime := GSlots[ASlot].Lifetime;
    OffThread := not OnStoreThread(GSlots[ASlot].Store);
    Inc(Hub.FInFlight);
    if OffThread and (Lifetime = wckQueued) then
    begin
      EnqueueNote(ASlot, AA0, AA1);
      Dec(Hub.FInFlight);
      Exit;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;

  try
    try
    if OffThread then
    begin
      try
        raise EWasmCallbackError.Create(MSG_CALLBACK_OFF_THREAD);
      except
        on E: EWasmCallbackError do
          Hub.Capture(E);
      end;
      Exit;
    end;

    case Shape of
      wcsVoid:
        begin
          Params := nil;
          Results := nil;
        end;
      wcsVoidI32:
        begin
          SetLength(Params, 1);
          Params[0] := MakeValueI32(Int32(AA0));
          Results := nil;
        end;
      wcsI32:
        begin
          Params := nil;
          SetLength(Results, 1);
        end;
      wcsI32I32:
        begin
          SetLength(Params, 1);
          Params[0] := MakeValueI32(Int32(AA0));
          SetLength(Results, 1);
        end;
      wcsVoidPtrU32:
        begin
          SetLength(Params, 2);
          Params[0] := MakeValueI32(Int32(AA0));
          Params[1] := MakeValueI32(Int32(AA1));
          Results := nil;
        end;
      wcsI32PtrPtr:
        begin
          SetLength(Params, 2);
          Params[0] := MakeValueI32(Int32(AA0));
          Params[1] := MakeValueI32(Int32(AA1));
          SetLength(Results, 1);
        end;
    end;
    Call(Func, Params, Results);
    if Length(Results) > 0 then
      Result := Results[0].I32;
  except
    on E: EWasmTrap do
      Hub.Capture(E);
    on E: EWasmException do
      Hub.Capture(E);
    on E: EWasmExit do
      Hub.Capture(E);
    on E: EWasmError do
      Hub.Capture(E);
  end;
  finally
    EnterCriticalSection(GLock);
    Dec(Hub.FInFlight);
    LeaveCriticalSection(GLock);
  end;
end;

function DispatchVoid(const ASlot: Integer): Int64;
begin
  Result := InvokeBound(ASlot, 0, 0);
end;

function DispatchI32(const ASlot: Integer; const AValue: Int32): Int64;
begin
  Result := InvokeBound(ASlot, AValue, 0);
end;

function DispatchPtrU32(const ASlot: Integer; const ABuffer: Pointer;
  const AFrames: UInt32): Int64;
begin
  Result := InvokeBound(ASlot, NativeInt(ABuffer), AFrames);
end;

function DispatchPtrPtr(const ASlot: Integer; const AUserData: Pointer;
  const AEvent: Pointer): Int64;
begin
  Result := InvokeBound(ASlot, NativeInt(AUserData), NativeInt(AEvent));
end;

procedure ThunkVoid0; cdecl;
begin
  DispatchVoid(0);
end;

procedure ThunkVoid1; cdecl;
begin
  DispatchVoid(1);
end;

procedure ThunkVoid2; cdecl;
begin
  DispatchVoid(2);
end;

procedure ThunkVoid3; cdecl;
begin
  DispatchVoid(3);
end;

procedure ThunkVoid4; cdecl;
begin
  DispatchVoid(4);
end;

procedure ThunkVoid5; cdecl;
begin
  DispatchVoid(5);
end;

procedure ThunkVoid6; cdecl;
begin
  DispatchVoid(6);
end;

procedure ThunkVoid7; cdecl;
begin
  DispatchVoid(7);
end;

procedure ThunkVoidI32_0(AValue: Int32); cdecl;
begin
  DispatchI32(0, AValue);
end;

procedure ThunkVoidI32_1(AValue: Int32); cdecl;
begin
  DispatchI32(1, AValue);
end;

procedure ThunkVoidI32_2(AValue: Int32); cdecl;
begin
  DispatchI32(2, AValue);
end;

procedure ThunkVoidI32_3(AValue: Int32); cdecl;
begin
  DispatchI32(3, AValue);
end;

procedure ThunkVoidI32_4(AValue: Int32); cdecl;
begin
  DispatchI32(4, AValue);
end;

procedure ThunkVoidI32_5(AValue: Int32); cdecl;
begin
  DispatchI32(5, AValue);
end;

procedure ThunkVoidI32_6(AValue: Int32); cdecl;
begin
  DispatchI32(6, AValue);
end;

procedure ThunkVoidI32_7(AValue: Int32); cdecl;
begin
  DispatchI32(7, AValue);
end;

function ThunkI32_0: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(0));
end;

function ThunkI32_1: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(1));
end;

function ThunkI32_2: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(2));
end;

function ThunkI32_3: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(3));
end;

function ThunkI32_4: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(4));
end;

function ThunkI32_5: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(5));
end;

function ThunkI32_6: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(6));
end;

function ThunkI32_7: Int32; cdecl;
begin
  Result := Int32(DispatchVoid(7));
end;

function ThunkI32I32_0(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(0, AValue));
end;

function ThunkI32I32_1(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(1, AValue));
end;

function ThunkI32I32_2(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(2, AValue));
end;

function ThunkI32I32_3(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(3, AValue));
end;

function ThunkI32I32_4(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(4, AValue));
end;

function ThunkI32I32_5(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(5, AValue));
end;

function ThunkI32I32_6(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(6, AValue));
end;

function ThunkI32I32_7(AValue: Int32): Int32; cdecl;
begin
  Result := Int32(DispatchI32(7, AValue));
end;

procedure ThunkAudio0(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(0, ABuffer, AFrames);
end;

procedure ThunkAudio1(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(1, ABuffer, AFrames);
end;

procedure ThunkAudio2(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(2, ABuffer, AFrames);
end;

procedure ThunkAudio3(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(3, ABuffer, AFrames);
end;

procedure ThunkAudio4(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(4, ABuffer, AFrames);
end;

procedure ThunkAudio5(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(5, ABuffer, AFrames);
end;

procedure ThunkAudio6(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(6, ABuffer, AFrames);
end;

procedure ThunkAudio7(ABuffer: Pointer; AFrames: UInt32); cdecl;
begin
  DispatchPtrU32(7, ABuffer, AFrames);
end;

function ThunkFilter0(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(0, AUserData, AEvent));
end;

function ThunkFilter1(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(1, AUserData, AEvent));
end;

function ThunkFilter2(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(2, AUserData, AEvent));
end;

function ThunkFilter3(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(3, AUserData, AEvent));
end;

function ThunkFilter4(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(4, AUserData, AEvent));
end;

function ThunkFilter5(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(5, AUserData, AEvent));
end;

function ThunkFilter6(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(6, AUserData, AEvent));
end;

function ThunkFilter7(AUserData: Pointer; AEvent: Pointer): Int32; cdecl;
begin
  Result := Int32(DispatchPtrPtr(7, AUserData, AEvent));
end;

function ThunkOf(const AShape: TWasmCallbackShape;
  const ASlot: Integer): Pointer;
begin
  Result := nil;
  case AShape of
    wcsVoid:
      case ASlot of
        0: Result := @ThunkVoid0;
        1: Result := @ThunkVoid1;
        2: Result := @ThunkVoid2;
        3: Result := @ThunkVoid3;
        4: Result := @ThunkVoid4;
        5: Result := @ThunkVoid5;
        6: Result := @ThunkVoid6;
        7: Result := @ThunkVoid7;
      end;
    wcsVoidI32:
      case ASlot of
        0: Result := @ThunkVoidI32_0;
        1: Result := @ThunkVoidI32_1;
        2: Result := @ThunkVoidI32_2;
        3: Result := @ThunkVoidI32_3;
        4: Result := @ThunkVoidI32_4;
        5: Result := @ThunkVoidI32_5;
        6: Result := @ThunkVoidI32_6;
        7: Result := @ThunkVoidI32_7;
      end;
    wcsI32:
      case ASlot of
        0: Result := @ThunkI32_0;
        1: Result := @ThunkI32_1;
        2: Result := @ThunkI32_2;
        3: Result := @ThunkI32_3;
        4: Result := @ThunkI32_4;
        5: Result := @ThunkI32_5;
        6: Result := @ThunkI32_6;
        7: Result := @ThunkI32_7;
      end;
    wcsI32I32:
      case ASlot of
        0: Result := @ThunkI32I32_0;
        1: Result := @ThunkI32I32_1;
        2: Result := @ThunkI32I32_2;
        3: Result := @ThunkI32I32_3;
        4: Result := @ThunkI32I32_4;
        5: Result := @ThunkI32I32_5;
        6: Result := @ThunkI32I32_6;
        7: Result := @ThunkI32I32_7;
      end;
    wcsVoidPtrU32:
      case ASlot of
        0: Result := @ThunkAudio0;
        1: Result := @ThunkAudio1;
        2: Result := @ThunkAudio2;
        3: Result := @ThunkAudio3;
        4: Result := @ThunkAudio4;
        5: Result := @ThunkAudio5;
        6: Result := @ThunkAudio6;
        7: Result := @ThunkAudio7;
      end;
    wcsI32PtrPtr:
      case ASlot of
        0: Result := @ThunkFilter0;
        1: Result := @ThunkFilter1;
        2: Result := @ThunkFilter2;
        3: Result := @ThunkFilter3;
        4: Result := @ThunkFilter4;
        5: Result := @ThunkFilter5;
        6: Result := @ThunkFilter6;
        7: Result := @ThunkFilter7;
      end;
  end;
end;

function SlotOfThunk(const AThunk: Pointer): Integer;
var
  Shape: TWasmCallbackShape;
  Slot: Integer;
begin
  Result := -1;
  if AThunk = nil then
    Exit;
  for Shape := Low(TWasmCallbackShape) to High(TWasmCallbackShape) do
    for Slot := 0 to WASM_CALLBACK_SLOT_COUNT - 1 do
      if ThunkOf(Shape, Slot) = AThunk then
        Exit(Slot);
end;

function TWasmCallbackHub.Bind(const AFunc: TWasmFunc;
  const AShape: TWasmCallbackShape;
  const ALifetime: TWlcCallbackKind): Pointer;
var
  Index, FreeSlot: Integer;
  Ref: TWasmRef;
begin
  if FDead or (FStore = nil) then
    raise EWasmCallbackError.Create('callback hub is torn down');
  if AFunc.Store <> FStore then
    raise EWasmCallbackError.Create(MSG_CALLBACK_STORE);
  if AFunc.Store <> nil then
    AFunc.Store.CheckThread;
  if not ShapeMatches(AFunc, AShape) then
    raise EWasmCallbackError.Create(MSG_CALLBACK_SHAPE);
  if (ALifetime = wckQueued) and not ShapeAllowsQueued(AShape) then
    raise EWasmCallbackError.Create(MSG_CALLBACK_QUEUED_SHAPE);
  if (AFunc.Addr >= UInt32(Length(FStore.Funcs))) then
    raise EWasmCallbackError.Create('callback function address is out of range');

  EnterCriticalSection(GLock);
  try
    FreeSlot := -1;
    for Index := 0 to WASM_CALLBACK_SLOT_COUNT - 1 do
    begin
      if GSlots[Index].Used and (GSlots[Index].Hub = Self) and
        SameFunc(GSlots[Index].Func, AFunc) and
        (GSlots[Index].Shape = AShape) and
        (GSlots[Index].Lifetime = ALifetime) and
        ((ALifetime <> wckScoped) or (GSlots[Index].ScopeDepth = FScopeDepth)) then
        Exit(ThunkOf(AShape, Index));
      if (not GSlots[Index].Used) and (FreeSlot < 0) then
        FreeSlot := Index;
    end;
    if FreeSlot < 0 then
      raise EWasmCallbackError.Create(MSG_CALLBACK_SLOTS);

    Ref := FStore.Funcs[AFunc.Addr].RefObject;
    GSlots[FreeSlot].Used := True;
    GSlots[FreeSlot].Hub := Self;
    GSlots[FreeSlot].Store := FStore;
    GSlots[FreeSlot].Func := AFunc;
    GSlots[FreeSlot].Shape := AShape;
    GSlots[FreeSlot].Lifetime := ALifetime;
    GSlots[FreeSlot].ScopeDepth := FScopeDepth;
    GSlots[FreeSlot].Root := RootRegister(FStore, Ref);
    Result := ThunkOf(AShape, FreeSlot);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure TWasmCallbackHub.Unbind(const AThunk: Pointer);
var
  Slot: Integer;
begin
  Slot := SlotOfThunk(AThunk);
  EnterCriticalSection(GLock);
  try
    if (Slot >= 0) and GSlots[Slot].Used and (GSlots[Slot].Hub = Self) then
      ReleaseSlot(Slot);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function TWasmCallbackHub.BeginScope: Integer;
begin
  if FStore <> nil then
    FStore.CheckThread;
  Inc(FScopeDepth);
  Result := FScopeDepth;
end;

procedure TWasmCallbackHub.EndScope(const AMark: Integer);
var
  Index: Integer;
begin
  if FStore <> nil then
    FStore.CheckThread;
  EnterCriticalSection(GLock);
  try
    for Index := 0 to WASM_CALLBACK_SLOT_COUNT - 1 do
      if GSlots[Index].Used and (GSlots[Index].Hub = Self) and
        (GSlots[Index].Lifetime = wckScoped) and
        (GSlots[Index].ScopeDepth >= AMark) then
        ReleaseSlot(Index);
  finally
    LeaveCriticalSection(GLock);
  end;
  if FScopeDepth >= AMark then
    FScopeDepth := AMark - 1;
  if FScopeDepth < 0 then
    FScopeDepth := 0;
end;

procedure TWasmCallbackHub.DrainQueued;
var
  Local: array of TQueuedNote;
  Count, Index: Integer;
begin
  if FStore <> nil then
    FStore.CheckThread;
  EnterCriticalSection(GLock);
  try
    Count := 0;
    SetLength(Local, GNoteCount);
    Index := 0;
    while Index < GNoteCount do
      if (GNotes[Index].Slot >= 0) and
        (GNotes[Index].Slot < WASM_CALLBACK_SLOT_COUNT) and
        (GSlots[GNotes[Index].Slot].Hub = Self) then
      begin
        Local[Count] := GNotes[Index];
        Inc(Count);
        GNotes[Index] := GNotes[GNoteCount - 1];
        Dec(GNoteCount);
      end
      else
        Inc(Index);
  finally
    LeaveCriticalSection(GLock);
  end;

  for Index := 0 to Count - 1 do
    InvokeBound(Local[Index].Slot, Local[Index].A0, Local[Index].A1);
  RethrowDeferred;
end;

function TWasmCallbackHub.HasDeferredFailure: Boolean;
begin
  EnterCriticalSection(GLock);
  try
    Result := FDeferred <> nil;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure TWasmCallbackHub.RethrowDeferred;
var
  Error: EWasmError;
begin
  EnterCriticalSection(GLock);
  try
    if FDeferred = nil then
      Exit;
    Error := FDeferred;
    FDeferred := nil;
  finally
    LeaveCriticalSection(GLock);
  end;
  if (FExnRoot <> WASM_NO_ROOT) and (FStore <> nil) then
  begin
    RootRelease(FStore, FExnRoot);
    FExnRoot := WASM_NO_ROOT;
  end;
  raise Error;
end;

procedure InitSlots;
var
  Index: Integer;
begin
  InitCriticalSection(GLock);
  for Index := 0 to WASM_CALLBACK_SLOT_COUNT - 1 do
  begin
    GSlots[Index].Used := False;
    GSlots[Index].Hub := nil;
    GSlots[Index].Root := WASM_NO_ROOT;
  end;
  GNotes := nil;
  GNoteCount := 0;
end;

procedure DoneSlots;
begin
  DoneCriticalSection(GLock);
end;

initialization
  InitSlots;

finalization
  DoneSlots;

end.
