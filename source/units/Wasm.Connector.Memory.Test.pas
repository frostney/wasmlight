{ Unit suite for Wasm.Connector.Memory — copy-in / copy-out / inout,
  scoped borrows, and opaque handles (issue #44).

  Transfers and borrows go through the Engine chokepoint, never Base.
  Negative cases required by the issue: OOB, wrapping overflow, stale
  handle, retained borrow, guest re-entry, and callback participation.
  i32 (guard-page on 64-bit UNIX) and i64 (guard-assisted) memories are
  both exercised so trap class and message stay identical.

  Every test asserts an outcome (the runner fails a test that records
  none). }
program Wasm.Connector.Memory.Test;

{$I Shared.inc}
{$POINTERMATH ON}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Connector.Memory,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Wat.Assembler;

type
  TConnectorMemoryTests = class(TTestSuite)
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FSession: TWasmConnectorSession;
    FMem32: TWasmMemoryRef;
    FMem64: TWasmMemoryRef;
    FLoaded: array of TWasmLoadedModule;
    FInstances: array of TWasmInstance;
    FLinkers: array of TWasmLinker;

    function Load(const AWat: string): TWasmLoadedModule;
    function NewLinker: TWasmLinker;
    function Track(const AInstance: TWasmInstance): TWasmInstance;
    function ClassifyTrap(const ACaught: Boolean; const AClass,
      AMessage: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestCopyInOutRoundTrip;
    procedure TestInOutCommitWritesBack;
    procedure TestOutOfRangeOffsetTraps;
    procedure TestStraddlingRangeTraps;
    procedure TestOverflowingRangeTraps;
    procedure TestZeroLengthAtEndIsInBounds;
    procedure TestI32AndI64OobTrapIdentically;
    procedure TestBorrowRoundTripAndRelease;
    procedure TestRetainedBorrowFails;
    procedure TestReentryWhileBorrowedFails;
    procedure TestCallbackWhileBorrowedFails;
    procedure TestCallAfterReleaseSucceeds;
    procedure TestOpaqueHandleRoundTrip;
    procedure TestStaleHandleFailsDeterministically;
    procedure TestHandleIsNotARawPointer;
    procedure TestNilCopyBufferIsConnectorError;
    procedure TestForeignMemoryIsConnectorError;
    procedure TestNilInOutHostIsConnectorError;
  end;

{ --- fixture ------------------------------------------------------------- }

procedure TConnectorMemoryTests.BeforeEach;
begin
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  EnsureInterpreter(FStore);
  FSession := TWasmConnectorSession.Create(FStore);
  FMem32.Store := FStore;
  FMem32.Addr := FStore.AddMemory(MakeMemType(MakeLimits(watI32, 1)));
  FMem64.Store := FStore;
  FMem64.Addr := FStore.AddMemory(MakeMemType(MakeLimits(watI64, 1)));
  FLoaded := nil;
  FInstances := nil;
  FLinkers := nil;
end;

procedure TConnectorMemoryTests.AfterEach;
var
  Index: Integer;
begin
  for Index := 0 to High(FInstances) do
    FInstances[Index].Free;
  FInstances := nil;
  for Index := 0 to High(FLinkers) do
    FLinkers[Index].Free;
  FLinkers := nil;
  FreeAndNil(FSession);
  FreeAndNil(FStore);
  for Index := 0 to High(FLoaded) do
    FLoaded[Index].Free;
  FLoaded := nil;
  FreeAndNil(FEngine);
end;

function TConnectorMemoryTests.Load(const AWat: string): TWasmLoadedModule;
begin
  Result := LoadModule(AssembleWatText(AWat));
  SetLength(FLoaded, Length(FLoaded) + 1);
  FLoaded[High(FLoaded)] := Result;
end;

function TConnectorMemoryTests.NewLinker: TWasmLinker;
begin
  Result := TWasmLinker.Create(FStore);
  SetLength(FLinkers, Length(FLinkers) + 1);
  FLinkers[High(FLinkers)] := Result;
end;

function TConnectorMemoryTests.Track(const AInstance: TWasmInstance): TWasmInstance;
begin
  Result := AInstance;
  SetLength(FInstances, Length(FInstances) + 1);
  FInstances[High(FInstances)] := AInstance;
end;

function TConnectorMemoryTests.ClassifyTrap(const ACaught: Boolean;
  const AClass, AMessage: string): string;
begin
  if not ACaught then
    Exit('none');
  if (AClass = 'trap') and (Pos(MSG_TRAP_MEMORY_OUT_OF_BOUNDS, AMessage) = 1) then
    Exit('memory-oob');
  Result := AClass;
end;

{ --- transfers ----------------------------------------------------------- }

procedure TConnectorMemoryTests.TestCopyInOutRoundTrip;
var
  Src, Dst: array[0..3] of Byte;
begin
  Src[0] := $DE;
  Src[1] := $AD;
  Src[2] := $BE;
  Src[3] := $EF;
  FSession.CopyOut(FMem32, 64, 4, @Src[0]);
  FillChar(Dst[0], 4, 0);
  FSession.CopyIn(FMem32, 64, 4, @Dst[0]);
  Expect<Byte>(Dst[0]).ToBe($DE);
  Expect<Byte>(Dst[1]).ToBe($AD);
  Expect<Byte>(Dst[2]).ToBe($BE);
  Expect<Byte>(Dst[3]).ToBe($EF);
end;

procedure TConnectorMemoryTests.TestInOutCommitWritesBack;
var
  Seed, Host, Back: array[0..3] of Byte;
  InOut: TWasmConnectorInOut;
begin
  Seed[0] := 1;
  Seed[1] := 2;
  Seed[2] := 3;
  Seed[3] := 4;
  FSession.CopyOut(FMem32, 128, 4, @Seed[0]);
  FillChar(Host[0], 4, 0);
  InOut := TWasmConnectorInOut.Create(FSession, FMem32, 128, 4, @Host[0]);
  try
    Expect<Byte>(Host[0]).ToBe(1);
    Host[0] := 9;
    Host[3] := 8;
    Expect<Boolean>(InOut.Committed).ToBe(False);
    InOut.Commit;
    Expect<Boolean>(InOut.Committed).ToBe(True);
  finally
    InOut.Free;
  end;
  FSession.CopyIn(FMem32, 128, 4, @Back[0]);
  Expect<Byte>(Back[0]).ToBe(9);
  Expect<Byte>(Back[1]).ToBe(2);
  Expect<Byte>(Back[2]).ToBe(3);
  Expect<Byte>(Back[3]).ToBe(8);
end;

procedure TConnectorMemoryTests.TestOutOfRangeOffsetTraps;
var
  Scratch: array[0..3] of Byte;
  Caught: Boolean;
  Kind, Msg: string;
begin
  Scratch[0] := 0;
  Caught := False;
  Kind := 'none';
  Msg := '';
  try
    FSession.CopyIn(FMem32, MemSize(FMem32), 4, @Scratch[0]);
  except
    on E: EWasmException do
    begin
      Caught := True;
      Kind := 'exception';
      Msg := E.Message;
    end;
    on E: EWasmTrap do
    begin
      Caught := True;
      Kind := 'trap';
      Msg := E.Message;
    end;
    on E: EWasmError do
    begin
      Caught := True;
      Kind := 'error';
      Msg := E.Message;
    end;
  end;
  Expect<string>(ClassifyTrap(Caught, Kind, Msg)).ToBe('memory-oob');
end;

procedure TConnectorMemoryTests.TestStraddlingRangeTraps;
var
  Scratch: array[0..3] of Byte;
  Caught: Boolean;
  Kind, Msg: string;
begin
  Caught := False;
  Kind := 'none';
  Msg := '';
  try
    FSession.CopyOut(FMem32, MemSize(FMem32) - 2, 4, @Scratch[0]);
  except
    on E: EWasmTrap do
    begin
      Caught := True;
      Kind := 'trap';
      Msg := E.Message;
    end;
    on E: EWasmError do
    begin
      Caught := True;
      Kind := 'error';
      Msg := E.Message;
    end;
  end;
  Expect<string>(ClassifyTrap(Caught, Kind, Msg)).ToBe('memory-oob');
end;

procedure TConnectorMemoryTests.TestOverflowingRangeTraps;
var
  Scratch: Byte;
  Caught32, Caught64: Boolean;
  Kind32, Kind64, Msg32, Msg64: string;
begin
  { Offset near 2^64 plus a small length must not wrap into a valid range. }
  Caught32 := False;
  Kind32 := 'none';
  Msg32 := '';
  try
    FSession.CopyIn(FMem32, High(UInt64) - 2, 8, @Scratch);
  except
    on E: EWasmTrap do
    begin
      Caught32 := True;
      Kind32 := 'trap';
      Msg32 := E.Message;
    end;
    on E: EWasmError do
    begin
      Caught32 := True;
      Kind32 := 'error';
      Msg32 := E.Message;
    end;
  end;
  Caught64 := False;
  Kind64 := 'none';
  Msg64 := '';
  try
    FSession.CopyOut(FMem64, High(UInt64) - 1, 4, @Scratch);
  except
    on E: EWasmTrap do
    begin
      Caught64 := True;
      Kind64 := 'trap';
      Msg64 := E.Message;
    end;
    on E: EWasmError do
    begin
      Caught64 := True;
      Kind64 := 'error';
      Msg64 := E.Message;
    end;
  end;
  Expect<string>(ClassifyTrap(Caught32, Kind32, Msg32)).ToBe('memory-oob');
  Expect<string>(ClassifyTrap(Caught64, Kind64, Msg64)).ToBe('memory-oob');
end;

procedure TConnectorMemoryTests.TestZeroLengthAtEndIsInBounds;
var
  Scratch: Byte;
begin
  Scratch := $5A;
  FSession.CopyIn(FMem32, MemSize(FMem32), 0, @Scratch);
  FSession.CopyOut(FMem64, MemSize(FMem64), 0, nil);
  Expect<Byte>(Scratch).ToBe($5A);
end;

procedure TConnectorMemoryTests.TestI32AndI64OobTrapIdentically;
var
  Scratch: array[0..3] of Byte;
  Caught32, Caught64, Borrow32, Borrow64: Boolean;
  Kind32, Kind64, Msg32, Msg64: string;
  View: TWasmConnectorBorrow;
begin
  Caught32 := False;
  Kind32 := 'none';
  Msg32 := '';
  try
    FSession.CopyIn(FMem32, MemSize(FMem32), 1, @Scratch[0]);
  except
    on E: EWasmTrap do
    begin
      Caught32 := True;
      Kind32 := 'trap';
      Msg32 := E.Message;
    end;
    on E: EWasmError do
    begin
      Caught32 := True;
      Kind32 := 'error';
      Msg32 := E.Message;
    end;
  end;
  Caught64 := False;
  Kind64 := 'none';
  Msg64 := '';
  try
    FSession.CopyIn(FMem64, MemSize(FMem64), 1, @Scratch[0]);
  except
    on E: EWasmTrap do
    begin
      Caught64 := True;
      Kind64 := 'trap';
      Msg64 := E.Message;
    end;
    on E: EWasmError do
    begin
      Caught64 := True;
      Kind64 := 'error';
      Msg64 := E.Message;
    end;
  end;
  Expect<string>(ClassifyTrap(Caught32, Kind32, Msg32)).ToBe('memory-oob');
  Expect<string>(ClassifyTrap(Caught64, Kind64, Msg64)).ToBe('memory-oob');

  Borrow32 := False;
  Kind32 := 'none';
  Msg32 := '';
  View := nil;
  try
    View := FSession.Borrow(FMem32, High(UInt64), 1);
  except
    on E: EWasmTrap do
    begin
      Borrow32 := True;
      Kind32 := 'trap';
      Msg32 := E.Message;
    end;
    on E: EWasmError do
    begin
      Borrow32 := True;
      Kind32 := 'error';
      Msg32 := E.Message;
    end;
  end;
  View.Free;
  Borrow64 := False;
  Kind64 := 'none';
  Msg64 := '';
  View := nil;
  try
    View := FSession.Borrow(FMem64, High(UInt64), 1);
  except
    on E: EWasmTrap do
    begin
      Borrow64 := True;
      Kind64 := 'trap';
      Msg64 := E.Message;
    end;
    on E: EWasmError do
    begin
      Borrow64 := True;
      Kind64 := 'error';
      Msg64 := E.Message;
    end;
  end;
  View.Free;
  Expect<string>(ClassifyTrap(Borrow32, Kind32, Msg32)).ToBe('memory-oob');
  Expect<string>(ClassifyTrap(Borrow64, Kind64, Msg64)).ToBe('memory-oob');
end;

{ --- scoped borrows ------------------------------------------------------ }

procedure TConnectorMemoryTests.TestBorrowRoundTripAndRelease;
var
  Src: array[0..3] of Byte;
  View: TWasmConnectorBorrow;
  P: PByte;
begin
  Src[0] := $11;
  Src[1] := $22;
  Src[2] := $33;
  Src[3] := $44;
  FSession.CopyOut(FMem32, 16, 4, @Src[0]);
  View := FSession.Borrow(FMem32, 16, 4);
  try
    Expect<Boolean>(View.Active).ToBe(True);
    Expect<Boolean>(FSession.BorrowLive).ToBe(True);
    Expect<UInt64>(View.Length).ToBe(4);
    P := View.Data;
    Expect<Boolean>(P <> nil).ToBe(True);
    Expect<Byte>(P[0]).ToBe($11);
    P[1] := $99;
    View.Release;
    Expect<Boolean>(View.Active).ToBe(False);
    Expect<Boolean>(FSession.BorrowLive).ToBe(False);
  finally
    View.Free;
  end;
  FSession.CopyIn(FMem32, 16, 4, @Src[0]);
  Expect<Byte>(Src[1]).ToBe($99);
end;

procedure TConnectorMemoryTests.TestRetainedBorrowFails;
var
  View: TWasmConnectorBorrow;
  DataMsg, LenMsg: string;
begin
  View := FSession.Borrow(FMem32, 0, 4);
  try
    View.Release;
    DataMsg := 'none';
    try
      View.Data;
    except
      on E: EWasmConnectorError do
        DataMsg := E.Message;
    end;
    LenMsg := 'none';
    try
      View.Length;
    except
      on E: EWasmConnectorError do
        LenMsg := E.Message;
    end;
    Expect<string>(DataMsg).ToBe(MSG_CONNECTOR_BORROW_INACTIVE);
    Expect<string>(LenMsg).ToBe(MSG_CONNECTOR_BORROW_INACTIVE);
  finally
    View.Free;
  end;
end;

procedure TConnectorMemoryTests.TestReentryWhileBorrowedFails;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  View: TWasmConnectorBorrow;
  NoArgs, NoResults: array of TWasmValue;
  Msg: string;
begin
  Loaded := Load('(module (func (export "nop")))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportFunc('nop', Fn)).ToBe(True);
  NoArgs := nil;
  NoResults := nil;
  View := FSession.Borrow(FMem32, 0, 8);
  try
    Msg := 'none';
    try
      FSession.Call(Fn, NoArgs, NoResults);
    except
      on E: EWasmConnectorError do
        Msg := E.Message;
    end;
    Expect<string>(Msg).ToBe(MSG_CONNECTOR_BORROW_REENTRY);
  finally
    View.Free;
  end;
end;

procedure TConnectorMemoryTests.TestCallbackWhileBorrowedFails;
var
  View: TWasmConnectorBorrow;
  Msg: string;
begin
  View := FSession.Borrow(FMem64, 0, 1);
  try
    Msg := 'none';
    try
      FSession.EnsureCallbackAllowed;
    except
      on E: EWasmConnectorError do
        Msg := E.Message;
    end;
    Expect<string>(Msg).ToBe(MSG_CONNECTOR_BORROW_CALLBACK);
  finally
    View.Free;
  end;
  FSession.EnsureCallbackAllowed;
  Expect<Boolean>(FSession.BorrowLive).ToBe(False);
end;

procedure TConnectorMemoryTests.TestCallAfterReleaseSucceeds;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  View: TWasmConnectorBorrow;
  NoArgs, NoResults: array of TWasmValue;
begin
  Loaded := Load('(module (func (export "nop") (i32.const 0) drop))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportFunc('nop', Fn)).ToBe(True);
  NoArgs := nil;
  NoResults := nil;
  View := FSession.Borrow(FMem32, 32, 4);
  View.Release;
  View.Free;
  Expect<Boolean>(FSession.BorrowLive).ToBe(False);
  FSession.Call(Fn, NoArgs, NoResults);
end;

{ --- opaque handles ------------------------------------------------------ }

procedure TConnectorMemoryTests.TestOpaqueHandleRoundTrip;
var
  Resource: Integer;
  Handle: TWasmConnectorHandle;
begin
  Resource := 42;
  Handle := FSession.AllocHandle(@Resource);
  Expect<Boolean>(Handle <> 0).ToBe(True);
  Expect<Boolean>(FSession.ResolveHandle(Handle) = @Resource).ToBe(True);
end;

procedure TConnectorMemoryTests.TestStaleHandleFailsDeterministically;
var
  Resource: Integer;
  Handle: TWasmConnectorHandle;
  First, Second, Zero, Missing: string;
begin
  Resource := 7;
  Handle := FSession.AllocHandle(@Resource);
  FSession.DropHandle(Handle);
  First := 'none';
  try
    FSession.ResolveHandle(Handle);
  except
    on E: EWasmConnectorError do
      First := E.Message;
  end;
  Second := 'none';
  try
    FSession.DropHandle(Handle);
  except
    on E: EWasmConnectorError do
      Second := E.Message;
  end;
  Zero := 'none';
  try
    FSession.ResolveHandle(0);
  except
    on E: EWasmConnectorError do
      Zero := E.Message;
  end;
  Missing := 'none';
  try
    FSession.ResolveHandle(TWasmConnectorHandle(99));
  except
    on E: EWasmConnectorError do
      Missing := E.Message;
  end;
  Expect<string>(First).ToBe(MSG_CONNECTOR_STALE_HANDLE);
  Expect<string>(Second).ToBe(MSG_CONNECTOR_STALE_HANDLE);
  Expect<string>(Zero).ToBe(MSG_CONNECTOR_STALE_HANDLE);
  Expect<string>(Missing).ToBe(MSG_CONNECTOR_STALE_HANDLE);
end;

procedure TConnectorMemoryTests.TestHandleIsNotARawPointer;
var
  Resource: Integer;
  Handle: TWasmConnectorHandle;
  Guest: TWasmValue;
begin
  Resource := 1;
  Handle := FSession.AllocHandle(@Resource);
  { The guest-visible name is a small table index, never the host address. }
  Expect<Boolean>(NativeUInt(Handle) <> NativeUInt(@Resource)).ToBe(True);
  Guest := MakeValueI32(Int32(Handle));
  Expect<Boolean>(Guest.I32 = Int32(Handle)).ToBe(True);
  Expect<Boolean>(NativeUInt(Guest.Bits) <> NativeUInt(@Resource)).ToBe(True);
end;

procedure TConnectorMemoryTests.TestNilCopyBufferIsConnectorError;
var
  DestMsg, SrcMsg: string;
begin
  DestMsg := 'none';
  try
    FSession.CopyIn(FMem32, 0, 4, nil);
  except
    on E: EWasmConnectorError do
      DestMsg := E.Message;
  end;
  SrcMsg := 'none';
  try
    FSession.CopyOut(FMem32, 0, 4, nil);
  except
    on E: EWasmConnectorError do
      SrcMsg := E.Message;
  end;
  Expect<string>(DestMsg).ToBe(MSG_CONNECTOR_COPY_DEST_NIL);
  Expect<string>(SrcMsg).ToBe(MSG_CONNECTOR_COPY_SRC_NIL);
end;

procedure TConnectorMemoryTests.TestForeignMemoryIsConnectorError;
var
  OtherEngine: TWasmEngine;
  OtherStore: TWasmStore;
  OtherMem: TWasmMemoryRef;
  Scratch: Byte;
  CopyMsg, BorrowMsg: string;
  View: TWasmConnectorBorrow;
begin
  OtherEngine := TWasmEngine.Create;
  OtherStore := TWasmStore.Create(OtherEngine);
  try
    OtherMem.Store := OtherStore;
    OtherMem.Addr := OtherStore.AddMemory(MakeMemType(MakeLimits(watI32, 1)));
    Scratch := 0;
    CopyMsg := 'none';
    try
      FSession.CopyIn(OtherMem, 0, 1, @Scratch);
    except
      on E: EWasmConnectorError do
        CopyMsg := E.Message;
    end;
    BorrowMsg := 'none';
    View := nil;
    try
      View := FSession.Borrow(OtherMem, 0, 1);
    except
      on E: EWasmConnectorError do
        BorrowMsg := E.Message;
    end;
    View.Free;
    Expect<string>(CopyMsg).ToBe(MSG_CONNECTOR_FOREIGN_MEMORY);
    Expect<string>(BorrowMsg).ToBe(MSG_CONNECTOR_FOREIGN_MEMORY);
  finally
    OtherStore.Free;
    OtherEngine.Free;
  end;
end;

procedure TConnectorMemoryTests.TestNilInOutHostIsConnectorError;
var
  Msg: string;
begin
  Msg := 'none';
  try
    TWasmConnectorInOut.Create(FSession, FMem32, 0, 4, nil);
  except
    on E: EWasmConnectorError do
      Msg := E.Message;
  end;
  Expect<string>(Msg).ToBe(MSG_CONNECTOR_HOST_NIL);
end;

{ --- registration -------------------------------------------------------- }

procedure TConnectorMemoryTests.SetupTests;
begin
  Test('copy-in and copy-out round-trip through the chokepoint',
    TestCopyInOutRoundTrip);
  Test('an inout buffer copies in, then commits the host mutation',
    TestInOutCommitWritesBack);
  Test('an out-of-range offset is a memory-OOB trap',
    TestOutOfRangeOffsetTraps);
  Test('a straddling range is a memory-OOB trap',
    TestStraddlingRangeTraps);
  Test('a wrapping offset+length is a memory-OOB trap',
    TestOverflowingRangeTraps);
  Test('a zero-length transfer at the memory end is in bounds',
    TestZeroLengthAtEndIsInBounds);
  Test('i32 and i64 memories raise the same OOB trap',
    TestI32AndI64OobTrapIdentically);
  Test('a scoped borrow sees guest bytes and ends on Release',
    TestBorrowRoundTripAndRelease);
  Test('a retained borrow cannot be used after Release',
    TestRetainedBorrowFails);
  Test('a live borrow cannot re-enter the guest',
    TestReentryWhileBorrowedFails);
  Test('a live borrow cannot participate in a callback',
    TestCallbackWhileBorrowedFails);
  Test('Call succeeds after the borrow is released',
    TestCallAfterReleaseSucceeds);
  Test('an opaque handle resolves to the native resource',
    TestOpaqueHandleRoundTrip);
  Test('stale, zero, and unknown handles fail deterministically',
    TestStaleHandleFailsDeterministically);
  Test('a handle is not the raw native pointer',
    TestHandleIsNotARawPointer);
  Test('a nil host buffer on a non-empty copy is a connector error',
    TestNilCopyBufferIsConnectorError);
  Test('a memory from another store is a connector error',
    TestForeignMemoryIsConnectorError);
  Test('a nil inout host buffer is a connector error',
    TestNilInOutHostIsConnectorError);
end;

begin
  TestRunnerProgram.AddSuite(TConnectorMemoryTests.Create('Wasm.Connector.Memory'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
