{ Wasm.Connector.Memory — connector copy-in / copy-out / inout, scoped
  borrows, and opaque-handle tables (issue #44, ADR-0015).

  A connector never hands the guest a native pointer and never keeps a
  borrowed view of linear memory past one synchronous host call. Every
  byte move goes through Wasm.Engine's overflow-safe MemRead / MemWrite
  pre-check and then TWasmStore.MemRangeAt — the same chokepoint every
  strategy already shares — so an out-of-range or wrapping transfer is
  EWasmTrap with MSG_TRAP_MEMORY_OUT_OF_BOUNDS on Pascal ground, without
  a strategy-specific fault. Persistent native resources cross the
  boundary as validated UInt32 handles; ResolveHandle is the only way
  back to the pointer, and a dropped or never-issued handle fails
  deterministically.

  This unit is the host-surface primitive issue #43 (C-ABI call plans)
  and issue #45 (callback thunks) consume. It does not parse .wlc, load
  libraries, or emit thunks. It adds no execution-tier logic and does
  not see a memory's Base.

  Layering: Wasm.Engine (TWasmMemoryRef, Call, MemSize) and the trap
  vocabulary. Not Wasm.Wasi.Memory — that layer returns WASI errno. }
unit Wasm.Connector.Memory;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Engine,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values;

const
  { Guest-visible handle 0 is never issued. A table lookup that names it,
    a dropped slot, or an index the session never allocated all raise the
    same message so a stale use is deterministic. }
  MSG_CONNECTOR_STALE_HANDLE = 'stale connector handle';
  MSG_CONNECTOR_BORROW_INACTIVE = 'borrowed view is not active';
  MSG_CONNECTOR_BORROW_REENTRY = 'borrowed view cannot re-enter the guest';
  MSG_CONNECTOR_BORROW_CALLBACK =
    'borrowed view cannot participate in a callback';
  MSG_CONNECTOR_COPY_DEST_NIL = 'copy destination is nil';
  MSG_CONNECTOR_COPY_SRC_NIL = 'copy source is nil';
  MSG_CONNECTOR_FOREIGN_MEMORY = 'memory does not belong to this store';
  MSG_CONNECTOR_HOST_NIL = 'inout host buffer is nil';
  MSG_CONNECTOR_SESSION_NIL = 'inout session is nil';
  MSG_CONNECTOR_STORE_NIL = 'connector session store is nil';

type
  { A connector-contract failure: stale handle, retained borrow, re-entry
    or callback while a view is live, or a nil host buffer. A SIBLING of
    EWasmTrap / EWasmExit under EWasmError — not a guest memory fault and
    not a clean exit. Hosts discriminate on the class. }
  EWasmConnectorError = class(EWasmError);

  { Guest-visible name of a persistent native resource. Never a pointer. }
  TWasmConnectorHandle = UInt32;

  TWasmConnectorSession = class;
  TWasmConnectorBorrow = class;

  { A bounds-checked view of guest memory granted for one synchronous
    host call. Data is valid only while Active; Release (or Destroy)
    ends the view. The raw pointer must not be retained. }
  TWasmConnectorBorrow = class
  private
    FSession: TWasmConnectorSession;
    FPtr: Pointer;
    FLength: UInt64;
    FActive: Boolean;
    procedure Detach;
  public
    destructor Destroy; override;
    function Data: Pointer;
    function Length: UInt64;
    function Active: Boolean;
    procedure Release;
  end;

  { Copy-in on construct; Commit writes the host buffer back. Bounds and
    length are stored once so the two directions cannot drift. }
  TWasmConnectorInOut = class
  private
    FSession: TWasmConnectorSession;
    FMem: TWasmMemoryRef;
    FOffset: UInt64;
    FLength: UInt64;
    FHost: PByte;
    FCommitted: Boolean;
  public
    constructor Create(const ASession: TWasmConnectorSession;
      const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
      const AHost: PByte);
    procedure Commit;
    function Host: PByte;
    function Length: UInt64;
    function Committed: Boolean;
  end;

  { Per-store connector memory session: transfers, the live-borrow fence,
    and the opaque-handle table. One session per store is the intended
    use; the table is not shared across stores. }
  TWasmConnectorSession = class
  private
    type
      THandleSlot = record
        Native: Pointer;
        Live: Boolean;
      end;
  private
    FStore: TWasmStore;
    FBorrowCount: Integer;
    FBorrows: array of TWasmConnectorBorrow;
    FHandles: array of THandleSlot;

    procedure CheckStore;
    procedure CheckMemory(const AMem: TWasmMemoryRef);
    function RangeValid(const AMem: TWasmMemoryRef;
      const AOffset, ALength: UInt64): Boolean;
    procedure TrapIfOutOfRange(const AMem: TWasmMemoryRef;
      const AOffset, ALength: UInt64);
    procedure RequireNoBorrow(const AMessage: string);
    procedure RegisterBorrow(const ABorrow: TWasmConnectorBorrow);
    procedure UnregisterBorrow(const ABorrow: TWasmConnectorBorrow);
    procedure InvalidateBorrows;
  public
    constructor Create(const AStore: TWasmStore);
    destructor Destroy; override;

    { Copy ALength bytes from guest [AOffset, AOffset+ALength) into ADest.
      Zero length is a no-op and accepts a nil destination. Out of range
      or a wrapping offset+length is EWasmTrap with the memory-OOB
      message, identical for i32 (guard-page) and i64 (guard-assisted)
      memories because the overflow-safe pre-check runs first. }
    procedure CopyIn(const AMem: TWasmMemoryRef;
      const AOffset, ALength: UInt64; const ADest: PByte);
    { Copy ALength bytes from ASrc into the guest range. }
    procedure CopyOut(const AMem: TWasmMemoryRef;
      const AOffset, ALength: UInt64; const ASrc: PByte);

    { Open a scoped borrow through MemRangeAt after the same pre-check.
      The view increments the session borrow count until Release. }
    function Borrow(const AMem: TWasmMemoryRef;
      const AOffset, ALength: UInt64): TWasmConnectorBorrow;

    function BorrowLive: Boolean;
    { Connector-initiated guest entry. Refuses while any borrow is live. }
    procedure Call(const AFunc: TWasmFunc; const AArgs: array of TWasmValue;
      var AResults: array of TWasmValue);
    { Callback thunks call this before re-entering the guest. }
    procedure EnsureCallbackAllowed;

    { Insert ANative and return a guest-visible handle. The pointer never
      becomes a TWasmValue; the handle is a 1-based table index. }
    function AllocHandle(const ANative: Pointer): TWasmConnectorHandle;
    function ResolveHandle(const AHandle: TWasmConnectorHandle): Pointer;
    procedure DropHandle(const AHandle: TWasmConnectorHandle);

    property Store: TWasmStore read FStore;
  end;

implementation

{ --- TWasmConnectorBorrow ------------------------------------------------ }

procedure TWasmConnectorBorrow.Detach;
begin
  FActive := False;
  FPtr := nil;
  FSession := nil;
  FLength := 0;
end;

destructor TWasmConnectorBorrow.Destroy;
begin
  Release;
  inherited;
end;

function TWasmConnectorBorrow.Data: Pointer;
begin
  if (not FActive) or (FSession = nil) then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_BORROW_INACTIVE);
  Result := FPtr;
end;

function TWasmConnectorBorrow.Length: UInt64;
begin
  if (not FActive) or (FSession = nil) then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_BORROW_INACTIVE);
  Result := FLength;
end;

function TWasmConnectorBorrow.Active: Boolean;
begin
  Result := FActive and (FSession <> nil);
end;

procedure TWasmConnectorBorrow.Release;
var
  Session: TWasmConnectorSession;
begin
  if not FActive then
    Exit;
  Session := FSession;
  Detach;
  if Session <> nil then
    Session.UnregisterBorrow(Self);
end;

{ --- TWasmConnectorInOut ------------------------------------------------- }

constructor TWasmConnectorInOut.Create(const ASession: TWasmConnectorSession;
  const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
  const AHost: PByte);
begin
  inherited Create;
  if ASession = nil then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_SESSION_NIL);
  if (ALength > 0) and (AHost = nil) then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_HOST_NIL);
  FSession := ASession;
  FMem := AMem;
  FOffset := AOffset;
  FLength := ALength;
  FHost := AHost;
  FCommitted := False;
  FSession.CopyIn(FMem, FOffset, FLength, FHost);
end;

procedure TWasmConnectorInOut.Commit;
begin
  FSession.CopyOut(FMem, FOffset, FLength, FHost);
  FCommitted := True;
end;

function TWasmConnectorInOut.Host: PByte;
begin
  Result := FHost;
end;

function TWasmConnectorInOut.Length: UInt64;
begin
  Result := FLength;
end;

function TWasmConnectorInOut.Committed: Boolean;
begin
  Result := FCommitted;
end;

{ --- TWasmConnectorSession ---------------------------------------------- }

constructor TWasmConnectorSession.Create(const AStore: TWasmStore);
begin
  inherited Create;
  if AStore = nil then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_STORE_NIL);
  FStore := AStore;
end;

destructor TWasmConnectorSession.Destroy;
begin
  InvalidateBorrows;
  inherited;
end;

procedure TWasmConnectorSession.CheckStore;
begin
  FStore.CheckThread;
end;

procedure TWasmConnectorSession.CheckMemory(const AMem: TWasmMemoryRef);
begin
  if AMem.Store <> FStore then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_FOREIGN_MEMORY);
end;

function TWasmConnectorSession.RangeValid(const AMem: TWasmMemoryRef;
  const AOffset, ALength: UInt64): Boolean;
var
  Size: UInt64;
begin
  Size := MemSize(AMem);
  { Overflow-safe: never AOffset + ALength, which wraps at 2^64. The same
    comparison Engine.MemRead uses, so guard-page and explicit-bounds
    memories reject the same ranges before MemRangeAt. }
  Result := (AOffset <= Size) and (ALength <= Size - AOffset);
end;

procedure TWasmConnectorSession.TrapIfOutOfRange(const AMem: TWasmMemoryRef;
  const AOffset, ALength: UInt64);
begin
  if not RangeValid(AMem, AOffset, ALength) then
    raise EWasmTrap.Create(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
end;

procedure TWasmConnectorSession.RequireNoBorrow(const AMessage: string);
begin
  if FBorrowCount > 0 then
    raise EWasmConnectorError.Create(AMessage);
end;

procedure TWasmConnectorSession.RegisterBorrow(
  const ABorrow: TWasmConnectorBorrow);
begin
  SetLength(FBorrows, Length(FBorrows) + 1);
  FBorrows[High(FBorrows)] := ABorrow;
  Inc(FBorrowCount);
end;

procedure TWasmConnectorSession.UnregisterBorrow(
  const ABorrow: TWasmConnectorBorrow);
var
  Index, Last: Integer;
begin
  Last := High(FBorrows);
  for Index := 0 to Last do
    if FBorrows[Index] = ABorrow then
    begin
      FBorrows[Index] := FBorrows[Last];
      SetLength(FBorrows, Last);
      if FBorrowCount > 0 then
        Dec(FBorrowCount);
      Exit;
    end;
end;

procedure TWasmConnectorSession.InvalidateBorrows;
var
  Index: Integer;
begin
  for Index := 0 to High(FBorrows) do
    if FBorrows[Index] <> nil then
      FBorrows[Index].Detach;
  FBorrows := nil;
  FBorrowCount := 0;
end;

procedure TWasmConnectorSession.CopyIn(const AMem: TWasmMemoryRef;
  const AOffset, ALength: UInt64; const ADest: PByte);
begin
  CheckStore;
  CheckMemory(AMem);
  if (ALength > 0) and (ADest = nil) then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_COPY_DEST_NIL);
  { MemRead owns the overflow-safe pre-check and the MemRangeAt copy, the
    same path Wasi.GuestReadBytes uses. False is OOB or wrap: raise the
    chokepoint trap on Pascal ground rather than returning a code. }
  if not MemRead(AMem, AOffset, ALength, ADest) then
    raise EWasmTrap.Create(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
end;

procedure TWasmConnectorSession.CopyOut(const AMem: TWasmMemoryRef;
  const AOffset, ALength: UInt64; const ASrc: PByte);
begin
  CheckStore;
  CheckMemory(AMem);
  if (ALength > 0) and (ASrc = nil) then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_COPY_SRC_NIL);
  if not MemWrite(AMem, AOffset, ALength, ASrc) then
    raise EWasmTrap.Create(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
end;

function TWasmConnectorSession.Borrow(const AMem: TWasmMemoryRef;
  const AOffset, ALength: UInt64): TWasmConnectorBorrow;
var
  View: Pointer;
begin
  CheckStore;
  CheckMemory(AMem);
  TrapIfOutOfRange(AMem, AOffset, ALength);
  View := nil;
  if ALength > 0 then
    { Pre-checked, so MemRangeAt returns the range without trapping and
      without a strategy-specific fault. }
    View := AMem.Store.MemRangeAt(AMem.Addr, AOffset, ALength);
  Result := TWasmConnectorBorrow.Create;
  Result.FSession := Self;
  Result.FPtr := View;
  Result.FLength := ALength;
  Result.FActive := True;
  RegisterBorrow(Result);
end;

function TWasmConnectorSession.BorrowLive: Boolean;
begin
  CheckStore;
  Result := FBorrowCount > 0;
end;

procedure TWasmConnectorSession.Call(const AFunc: TWasmFunc;
  const AArgs: array of TWasmValue; var AResults: array of TWasmValue);
begin
  CheckStore;
  RequireNoBorrow(MSG_CONNECTOR_BORROW_REENTRY);
  Wasm.Engine.Call(AFunc, AArgs, AResults);
end;

procedure TWasmConnectorSession.EnsureCallbackAllowed;
begin
  CheckStore;
  RequireNoBorrow(MSG_CONNECTOR_BORROW_CALLBACK);
end;

function TWasmConnectorSession.AllocHandle(
  const ANative: Pointer): TWasmConnectorHandle;
var
  Index: Integer;
begin
  CheckStore;
  SetLength(FHandles, Length(FHandles) + 1);
  Index := High(FHandles);
  FHandles[Index].Native := ANative;
  FHandles[Index].Live := True;
  { 1-based so 0 stays invalid. The guest sees this integer, never ANative. }
  Result := TWasmConnectorHandle(Index + 1);
end;

function TWasmConnectorSession.ResolveHandle(
  const AHandle: TWasmConnectorHandle): Pointer;
var
  Index: Integer;
begin
  CheckStore;
  if AHandle = 0 then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_STALE_HANDLE);
  Index := Integer(AHandle) - 1;
  if (Index < 0) or (Index > High(FHandles)) or (not FHandles[Index].Live) then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_STALE_HANDLE);
  Result := FHandles[Index].Native;
end;

procedure TWasmConnectorSession.DropHandle(const AHandle: TWasmConnectorHandle);
var
  Index: Integer;
begin
  CheckStore;
  { Resolve first so a stale drop has the same diagnostic as a stale get. }
  ResolveHandle(AHandle);
  Index := Integer(AHandle) - 1;
  FHandles[Index].Live := False;
  FHandles[Index].Native := nil;
end;

end.
