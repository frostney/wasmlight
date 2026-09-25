{ Unit suite for Wasm.Connector.Callbacks — connector thunk lifetimes,
  queued delivery, and the deferred-failure boundary (issue #45).

  Every module is assembled through Wasm.Wat.Assembler and loaded through
  the shipped Engine path. Native libraries are not linked: cdecl thunks
  are invoked as if SDL or raylib had called them.

  Coverage:
    - direct store-thread re-entry and nested trampoline
    - retained default, scoped one-call lifetime, safe slot reuse after callers release their pointers
    - queued void notifications copied from a foreign thread, drained in
      queue order even after another hub is freed
    - rejection of queued results / pointer borrows
    - rejection of foreign-thread synchronous results
    - bind/off-thread rejects are EWasmCallbackError, distinct from
      EWasmConnectorError and from guest trap/exception/exit
    - EWasmTrap / EWasmException / EWasmExit do not unwind through the
      cdecl frame; RethrowDeferred surfaces the exact class
    - raylib-style AudioCallback and SDL-style EventFilter shapes
    - function-reference rooting and thunk deduplication

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
program Wasm.Connector.Callbacks.Test;

{$I Shared.inc}
{$POINTERMATH ON}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Connector,
  Wasm.Engine,
  Wasm.Connector.Callbacks,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Wat.Assembler;

type
  PThreadNote = ^TThreadNote;
  TThreadNote = record
    Thunk: Pointer;
    Arg: Int32;
    Done: Integer;
  end;

  TCallbackTests = class(TTestSuite)
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FHub: TWasmCallbackHub;
    FLoaded: array of TWasmLoadedModule;
    FInstances: array of TWasmInstance;
    FLinkers: array of TWasmLinker;

    procedure QueueNote(const AThunk: Pointer; const AValue: Int32);
    function Load(const AWat: string): TWasmLoadedModule;
    function NewLinker: TWasmLinker;
    function Track(const AInstance: TWasmInstance): TWasmInstance;
    function ExportFunc(const AInst: TWasmInstance;
      const AName: string): TWasmFunc;
    function InstantiatePlain(const AWat: string): TWasmInstance;
    function InstantiateDistinctIncs: TWasmInstance;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestDirectI32RoundTrip;
    procedure TestDedupSameBinding;
    procedure TestNestedTrampoline;
    procedure TestRetainedSurvivesScope;
    procedure TestScopedDiesWithScope;
    procedure TestTeardownReleasesBindings;
    procedure TestQueuedBindingReuse;
    procedure TestQueuedDuringDrainRebind;
    procedure TestHubTeardownKeepsQueueOrder;
    procedure TestQueuedFromForeignThread;
    procedure TestQueuedRejectsResultsAndBorrows;
    procedure TestForeignDirectIsRejected;
    procedure TestTrapDoesNotUnwindCFrame;
    procedure TestExceptionDoesNotUnwindCFrame;
    procedure TestExitDoesNotUnwindCFrame;
    procedure TestRaylibAudioShape;
    procedure TestSdlFilterShape;
  end;

var
  GFireHub: TWasmCallbackHub;
  GFireThunk: Pointer;
  GReplacement: TWasmFunc;

function ForeignVoidI32(AData: Pointer): PtrInt;
var
  Note: PThreadNote;
begin
  Note := PThreadNote(AData);
  TWasmCallbackProcI32(Note^.Thunk)(Note^.Arg);
  InterlockedIncrement(Note^.Done);
  Result := 0;
end;

procedure HostRebind(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  GFireHub.Unbind(GFireThunk);
  GFireThunk := GFireHub.Bind(GReplacement, wcsVoidI32, wckQueued);
end;

procedure TCallbackTests.QueueNote(const AThunk: Pointer; const AValue: Int32);
var
  Note: TThreadNote;
  Id: TThreadID;
begin
  Note.Thunk := AThunk;
  Note.Arg := AValue;
  Note.Done := 0;
  Id := BeginThread(@ForeignVoidI32, @Note);
  WaitForThreadTerminate(Id, 5000);
  Expect<Boolean>(Note.Done <> 0).ToBe(True);
end;

procedure HostFire(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Fn: TWasmCallbackFnI32I32;
  Raised: Boolean;
begin
  Fn := TWasmCallbackFnI32I32(GFireThunk);
  AResults[0] := MakeValueI32(Fn(AParams[0].I32));
  Raised := (GFireHub <> nil) and GFireHub.HasDeferredFailure;
  if Raised then
    GFireHub.RethrowDeferred;
end;

procedure HostExitNow(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  raise EWasmExit.CreateExit(7);
end;

procedure TCallbackTests.BeforeEach;
begin
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  EnsureInterpreter(FStore);
  FHub := TWasmCallbackHub.Create(FStore);
  FLoaded := nil;
  FInstances := nil;
  FLinkers := nil;
  GFireHub := FHub;
  GFireThunk := nil;
end;

procedure TCallbackTests.AfterEach;
var
  Index: Integer;
begin
  GFireThunk := nil;
  GFireHub := nil;
  for Index := 0 to High(FInstances) do
    FInstances[Index].Free;
  FInstances := nil;
  for Index := 0 to High(FLinkers) do
    FLinkers[Index].Free;
  FLinkers := nil;
  FreeAndNil(FHub);
  FreeAndNil(FStore);
  for Index := 0 to High(FLoaded) do
    FLoaded[Index].Free;
  FLoaded := nil;
  FreeAndNil(FEngine);
end;

function TCallbackTests.Load(const AWat: string): TWasmLoadedModule;
begin
  Result := LoadModule(AssembleWatText(AWat));
  SetLength(FLoaded, Length(FLoaded) + 1);
  FLoaded[High(FLoaded)] := Result;
end;

function TCallbackTests.NewLinker: TWasmLinker;
begin
  Result := TWasmLinker.Create(FStore);
  SetLength(FLinkers, Length(FLinkers) + 1);
  FLinkers[High(FLinkers)] := Result;
end;

function TCallbackTests.Track(const AInstance: TWasmInstance): TWasmInstance;
begin
  Result := AInstance;
  SetLength(FInstances, Length(FInstances) + 1);
  FInstances[High(FInstances)] := AInstance;
end;

function TCallbackTests.ExportFunc(const AInst: TWasmInstance;
  const AName: string): TWasmFunc;
begin
  Expect<Boolean>(AInst.FindExportFunc(AName, Result)).ToBe(True);
end;

function TCallbackTests.InstantiatePlain(const AWat: string): TWasmInstance;
begin
  Result := Track(Instantiate(FStore, NewLinker, Load(AWat)));
end;

procedure TCallbackTests.TestDirectI32RoundTrip;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackFnI32I32;
begin
  Inst := InstantiatePlain(
    '(module (func (export "inc") (param i32) (result i32)' +
    ' (i32.add (local.get 0) (i32.const 1))))');
  Fn := ExportFunc(Inst, 'inc');
  Thunk := TWasmCallbackFnI32I32(FHub.Bind(Fn, wcsI32I32, wckRetained));
  Expect<Int32>(Thunk(41)).ToBe(42);
  Expect<Boolean>(FHub.HasDeferredFailure).ToBe(False);
end;

procedure TCallbackTests.TestDedupSameBinding;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  First, Second: Pointer;
begin
  Inst := InstantiatePlain(
    '(module (func (export "inc") (param i32) (result i32)' +
    ' (i32.add (local.get 0) (i32.const 1))))');
  Fn := ExportFunc(Inst, 'inc');
  First := FHub.Bind(Fn, wcsI32I32, wckRetained);
  Second := FHub.Bind(Fn, wcsI32I32, wckRetained);
  Expect<Boolean>(First = Second).ToBe(True);
  Expect<Boolean>(First <> nil).ToBe(True);
end;

procedure TCallbackTests.TestNestedTrampoline;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Run, Leaf: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  Loaded := Load(
    '(module' + sLineBreak +
    '  (import "host" "fire" (func $fire (param i32) (result i32)))' +
    sLineBreak +
    '  (func (export "leaf") (param i32) (result i32)' + sLineBreak +
    '    (i32.add (local.get 0) (i32.const 1)))' + sLineBreak +
    '  (func (export "run") (param i32) (result i32)' + sLineBreak +
    '    (call $fire (local.get 0))))');
  Linker := NewLinker;
  Linker.DefineFunc('host', 'fire',
    [MakeNumValueType(wntI32)], [MakeNumValueType(wntI32)], @HostFire, nil);
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Leaf := ExportFunc(Inst, 'leaf');
  Run := ExportFunc(Inst, 'run');
  GFireThunk := FHub.Bind(Leaf, wcsI32I32, wckRetained);

  SetLength(Args, 1);
  Args[0] := MakeValueI32(20);
  SetLength(Results, 1);
  Call(Run, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(21);
end;

procedure TCallbackTests.TestRetainedSurvivesScope;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackFnI32I32;
  Mark: Integer;
begin
  Inst := InstantiatePlain(
    '(module (func (export "inc") (param i32) (result i32)' +
    ' (i32.add (local.get 0) (i32.const 1))))');
  Fn := ExportFunc(Inst, 'inc');
  Thunk := TWasmCallbackFnI32I32(FHub.Bind(Fn, wcsI32I32, wckRetained));
  Mark := FHub.BeginScope;
  FHub.EndScope(Mark);
  Expect<Int32>(Thunk(8)).ToBe(9);
end;

function TCallbackTests.InstantiateDistinctIncs: TWasmInstance;
var
  Wat: string;
  Index: Integer;
begin
  { One more function than there are slots: incN(x) = x + N + 1. }
  Wat := '(module';
  for Index := 0 to WASM_CALLBACK_SLOT_COUNT do
    Wat := Wat + ' (func (export "inc' + IntToStr(Index) +
      '") (param i32) (result i32) (i32.add (local.get 0) (i32.const ' +
      IntToStr(Index + 1) + ')))';
  Result := InstantiatePlain(Wat + ')');
end;

procedure TCallbackTests.TestScopedDiesWithScope;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackFnI32I32;
  Mark, Index: Integer;
begin
  { A distinct function per scope defeats thunk deduplication, so the pool
    is exhausted unless EndScope actually releases each slot. }
  Inst := InstantiateDistinctIncs;
  for Index := 0 to WASM_CALLBACK_SLOT_COUNT do
  begin
    Fn := ExportFunc(Inst, 'inc' + IntToStr(Index));
    Mark := FHub.BeginScope;
    Thunk := TWasmCallbackFnI32I32(FHub.Bind(Fn, wcsI32I32, wckScoped));
    Expect<Int32>(Thunk(1)).ToBe(Index + 2);
    Thunk := nil;
    FHub.EndScope(Mark);
  end;
  Expect<Boolean>(FHub.HasDeferredFailure).ToBe(False);
end;

procedure TCallbackTests.TestTeardownReleasesBindings;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackFnI32I32;
  Hub: TWasmCallbackHub;
  Index: Integer;
begin
  { A distinct function per hub keeps a reused hub address from matching a
    leaked slot through deduplication. }
  Inst := InstantiateDistinctIncs;
  for Index := 0 to WASM_CALLBACK_SLOT_COUNT do
  begin
    Fn := ExportFunc(Inst, 'inc' + IntToStr(Index));
    Hub := TWasmCallbackHub.Create(FStore);
    try
      Thunk := TWasmCallbackFnI32I32(Hub.Bind(Fn, wcsI32I32, wckRetained));
      Expect<Int32>(Thunk(1)).ToBe(Index + 2);
      Thunk := nil;
    finally
      Hub.Free;
    end;
  end;
end;

procedure TCallbackTests.TestQueuedBindingReuse;
var
  Inst: TWasmInstance;
  G: TWasmGlobalRef;
  Thunk: Pointer;
begin
  Inst := InstantiatePlain(
    '(module (global $g (export "g") (mut i32) (i32.const 0))' +
    ' (func (export "old") (param i32) local.get 0 global.set $g)' +
    ' (func (export "new") (param i32)' +
    ' local.get 0 i32.const 10 i32.mul global.set $g))');
  Expect<Boolean>(Inst.FindExportGlobal('g', G)).ToBe(True);
  Thunk := FHub.Bind(ExportFunc(Inst, 'old'), wcsVoidI32, wckQueued);
  QueueNote(Thunk, 5);
  FHub.Unbind(Thunk);
  Thunk := FHub.Bind(ExportFunc(Inst, 'new'), wcsVoidI32, wckQueued);
  FHub.DrainQueued;
  Expect<Int32>(GlobalGet(G).I32).ToBe(0);
  QueueNote(Thunk, 7);
  FHub.DrainQueued;
  Expect<Int32>(GlobalGet(G).I32).ToBe(70);
end;

procedure TCallbackTests.TestQueuedDuringDrainRebind;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  G: TWasmGlobalRef;
  Driver: Pointer;
begin
  Loaded := Load(
    '(module (import "host" "rebind" (func $rebind))' +
    ' (global $g (export "g") (mut i32) (i32.const 0))' +
    ' (func (export "driver") (param i32) call $rebind)' +
    ' (func (export "old") (param i32) local.get 0 global.set $g)' +
    ' (func (export "new") (param i32)' +
    ' local.get 0 i32.const 10 i32.mul global.set $g))');
  Linker := NewLinker;
  Linker.DefineFunc('host', 'rebind', [], [], @HostRebind, nil);
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportGlobal('g', G)).ToBe(True);
  Driver := FHub.Bind(ExportFunc(Inst, 'driver'), wcsVoidI32, wckQueued);
  GFireThunk := FHub.Bind(ExportFunc(Inst, 'old'), wcsVoidI32, wckQueued);
  GReplacement := ExportFunc(Inst, 'new');
  QueueNote(Driver, 0);
  QueueNote(GFireThunk, 5);
  FHub.DrainQueued;
  Expect<Int32>(GlobalGet(G).I32).ToBe(0);
  QueueNote(GFireThunk, 7);
  FHub.DrainQueued;
  Expect<Int32>(GlobalGet(G).I32).ToBe(70);
end;

procedure TCallbackTests.TestHubTeardownKeepsQueueOrder;
var
  Inst: TWasmInstance;
  G: TWasmGlobalRef;
  Other: TWasmCallbackHub;
  OtherThunk, Thunk: Pointer;
begin
  Inst := InstantiatePlain(
    '(module (global $g (export "g") (mut i32) (i32.const 0))' +
    ' (func (export "seq") (param i32)' +
    ' global.get $g i32.const 10 i32.mul local.get 0 i32.add global.set $g)' +
    ' (func (export "other") (param i32)))');
  Expect<Boolean>(Inst.FindExportGlobal('g', G)).ToBe(True);
  Other := TWasmCallbackHub.Create(FStore);
  try
    OtherThunk := Other.Bind(ExportFunc(Inst, 'other'), wcsVoidI32, wckQueued);
    QueueNote(OtherThunk, 9);
    Thunk := FHub.Bind(ExportFunc(Inst, 'seq'), wcsVoidI32, wckQueued);
    QueueNote(Thunk, 1);
    QueueNote(Thunk, 2);
    QueueNote(Thunk, 3);
  finally
    Other.Free;
  end;
  FHub.DrainQueued;
  Expect<Int32>(GlobalGet(G).I32).ToBe(123);
end;

procedure TCallbackTests.TestQueuedFromForeignThread;
var
  Inst: TWasmInstance;
  NoteFn: TWasmFunc;
  G: TWasmGlobalRef;
  Thunk: Pointer;
  Note: TThreadNote;
  Id: TThreadID;
  Spins: Integer;
begin
  Inst := InstantiatePlain(
    '(module' + sLineBreak +
    '  (global $g (export "g") (mut i32) (i32.const 0))' + sLineBreak +
    '  (func (export "note") (param i32)' + sLineBreak +
    '    (global.set $g (i32.add (global.get $g) (local.get 0)))))');
  NoteFn := ExportFunc(Inst, 'note');
  Expect<Boolean>(Inst.FindExportGlobal('g', G)).ToBe(True);
  Thunk := FHub.Bind(NoteFn, wcsVoidI32, wckQueued);

  Note.Thunk := Thunk;
  Note.Arg := 5;
  Note.Done := 0;
  Id := BeginThread(@ForeignVoidI32, @Note);
  Spins := 0;
  while (Note.Done = 0) and (Spins < 100000) do
  begin
    Sleep(1);
    Inc(Spins);
  end;
  WaitForThreadTerminate(Id, 2000);
  Expect<Boolean>(Note.Done <> 0).ToBe(True);
  Expect<Int32>(GlobalGet(G).I32).ToBe(0);

  FHub.DrainQueued;
  Expect<Int32>(GlobalGet(G).I32).ToBe(5);
end;

procedure TCallbackTests.TestQueuedRejectsResultsAndBorrows;
var
  Inst: TWasmInstance;
  IncFn, Audio: TWasmFunc;
  Caught: string;
begin
  Inst := InstantiatePlain(
    '(module' + sLineBreak +
    '  (func (export "inc") (param i32) (result i32) (local.get 0))' +
    sLineBreak +
    '  (func (export "audio") (param i32 i32)))');
  IncFn := ExportFunc(Inst, 'inc');
  Audio := ExportFunc(Inst, 'audio');

  Caught := '(none)';
  try
    FHub.Bind(IncFn, wcsI32I32, wckQueued);
  except
    on E: EWasmCallbackError do
      Caught := E.Message;
    on E: EWasmError do
      Caught := 'collapsed:' + E.ClassName;
  end;
  Expect<Boolean>(Pos(string(MSG_CALLBACK_QUEUED_SHAPE), Caught) = 1).ToBe(True);

  Caught := '(none)';
  try
    FHub.Bind(Audio, wcsVoidPtrU32, wckQueued);
  except
    on E: EWasmCallbackError do
      Caught := E.Message;
    on E: EWasmError do
      Caught := 'collapsed:' + E.ClassName;
  end;
  Expect<Boolean>(Pos(string(MSG_CALLBACK_QUEUED_SHAPE), Caught) = 1).ToBe(True);
end;

procedure TCallbackTests.TestForeignDirectIsRejected;
var
  Inst: TWasmInstance;
  NoteFn: TWasmFunc;
  G: TWasmGlobalRef;
  Note: TThreadNote;
  Id: TThreadID;
  Spins: Integer;
  Kind: string;
begin
  Inst := InstantiatePlain(
    '(module' + sLineBreak +
    '  (global $g (export "g") (mut i32) (i32.const 0))' + sLineBreak +
    '  (func (export "note") (param i32)' + sLineBreak +
    '    (global.set $g (i32.add (global.get $g) (local.get 0)))))');
  NoteFn := ExportFunc(Inst, 'note');
  Expect<Boolean>(Inst.FindExportGlobal('g', G)).ToBe(True);
  Note.Thunk := FHub.Bind(NoteFn, wcsVoidI32, wckRetained);
  Note.Arg := 3;
  Note.Done := 0;
  Id := BeginThread(@ForeignVoidI32, @Note);
  Spins := 0;
  while (Note.Done = 0) and (Spins < 100000) do
  begin
    Sleep(1);
    Inc(Spins);
  end;
  WaitForThreadTerminate(Id, 2000);
  Expect<Boolean>(Note.Done <> 0).ToBe(True);
  Expect<Int32>(GlobalGet(G).I32).ToBe(0);
  Expect<Boolean>(FHub.HasDeferredFailure).ToBe(True);

  Kind := 'none';
  try
    FHub.RethrowDeferred;
  except
    on E: EWasmCallbackError do
    begin
      if Pos(string(MSG_CALLBACK_OFF_THREAD), E.Message) = 1 then
        Kind := 'off-thread'
      else
        Kind := 'callback';
    end;
    on E: EWasmTrap do
      Kind := 'trap';
    on E: EWasmException do
      Kind := 'exception';
    on E: EWasmError do
      Kind := 'error';
  end;
  Expect<string>(Kind).ToBe('off-thread');
end;

procedure TCallbackTests.TestTrapDoesNotUnwindCFrame;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackProc;
  Raised: Boolean;
  Kind: string;
begin
  Inst := InstantiatePlain(
    '(module (func (export "boom") unreachable))');
  Fn := ExportFunc(Inst, 'boom');
  Thunk := TWasmCallbackProc(FHub.Bind(Fn, wcsVoid, wckRetained));
  Raised := False;
  try
    Thunk();
  except
    on E: Exception do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(False);
  Expect<Boolean>(FHub.HasDeferredFailure).ToBe(True);

  Kind := 'none';
  try
    FHub.RethrowDeferred;
  except
    on E: EWasmException do
      Kind := 'exception';
    on E: EWasmTrap do
      Kind := 'trap';
    on E: EWasmError do
      Kind := 'error';
  end;
  Expect<string>(Kind).ToBe('trap');
end;

procedure TCallbackTests.TestExceptionDoesNotUnwindCFrame;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackProc;
  Raised: Boolean;
  Kind: string;
begin
  Inst := InstantiatePlain(
    '(module (tag $e (param i32)) (func (export "boom") i32.const 1 throw $e))');
  Fn := ExportFunc(Inst, 'boom');
  Thunk := TWasmCallbackProc(FHub.Bind(Fn, wcsVoid, wckRetained));
  Raised := False;
  try
    Thunk();
  except
    on E: Exception do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(False);

  Kind := 'none';
  try
    FHub.RethrowDeferred;
  except
    on E: EWasmException do
      Kind := 'exception';
    on E: EWasmTrap do
      Kind := 'trap';
    on E: EWasmError do
      Kind := 'error';
  end;
  Expect<string>(Kind).ToBe('exception');
end;

procedure TCallbackTests.TestExitDoesNotUnwindCFrame;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackProc;
  Raised: Boolean;
  Kind: string;
  Code: Int32;
begin
  Loaded := Load(
    '(module (import "host" "exit" (func $exit))' +
    ' (func (export "go") (call $exit)))');
  Linker := NewLinker;
  Linker.DefineFunc('host', 'exit', [], [], @HostExitNow, nil);
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Fn := ExportFunc(Inst, 'go');
  Thunk := TWasmCallbackProc(FHub.Bind(Fn, wcsVoid, wckRetained));
  Raised := False;
  try
    Thunk();
  except
    on E: Exception do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(False);

  Kind := 'none';
  Code := 0;
  try
    FHub.RethrowDeferred;
  except
    on E: EWasmExit do
    begin
      Kind := 'exit';
      Code := E.ExitCode;
    end;
    on E: EWasmTrap do
      Kind := 'trap';
    on E: EWasmError do
      Kind := 'error';
  end;
  Expect<string>(Kind).ToBe('exit');
  Expect<Int32>(Code).ToBe(7);
end;

procedure TCallbackTests.TestRaylibAudioShape;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  G: TWasmGlobalRef;
  Thunk: TWasmCallbackAudio;
begin
  Inst := InstantiatePlain(
    '(module' + sLineBreak +
    '  (global $g (export "g") (mut i32) (i32.const 0))' + sLineBreak +
    '  (func (export "audio") (param i32 i32)' + sLineBreak +
    '    (global.set $g (i32.add (local.get 0) (local.get 1)))))');
  Fn := ExportFunc(Inst, 'audio');
  Expect<Boolean>(Inst.FindExportGlobal('g', G)).ToBe(True);
  Thunk := TWasmCallbackAudio(FHub.Bind(Fn, wcsVoidPtrU32, wckRetained));
  Thunk(Pointer(10), 4);
  Expect<Int32>(GlobalGet(G).I32).ToBe(14);
end;

procedure TCallbackTests.TestSdlFilterShape;
var
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  Thunk: TWasmCallbackFilter;
begin
  Inst := InstantiatePlain(
    '(module (func (export "filter") (param i32 i32) (result i32)' +
    ' (i32.add (local.get 0) (local.get 1))))');
  Fn := ExportFunc(Inst, 'filter');
  Thunk := TWasmCallbackFilter(FHub.Bind(Fn, wcsI32PtrPtr, wckRetained));
  Expect<Int32>(Thunk(Pointer(3), Pointer(4))).ToBe(7);
end;

procedure TCallbackTests.SetupTests;
begin
  Test('a direct i32 callback re-enters on the store thread',
    TestDirectI32RoundTrip);
  Test('the same function, shape, and lifetime reuse one thunk',
    TestDedupSameBinding);
  Test('a host-to-guest callback nests through the trampoline',
    TestNestedTrampoline);
  Test('a retained callback survives EndScope',
    TestRetainedSurvivesScope);
  Test('a scoped binding releases its slot when the scope ends',
    TestScopedDiesWithScope);
  Test('teardown releases slots for subsequent bindings',
    TestTeardownReleasesBindings);
  Test('unbinding cancels queued work before slot reuse', TestQueuedBindingReuse);
  Test('a private drain batch rejects a replaced binding', TestQueuedDuringDrainRebind);
  Test('freeing a hub keeps other hubs'' queued notes in order',
    TestHubTeardownKeepsQueueOrder);
  Test('a queued notification is copied off-thread and drained later',
    TestQueuedFromForeignThread);
  Test('queued bind rejects results and pointer borrows',
    TestQueuedRejectsResultsAndBorrows);
  Test('a foreign-thread direct callback is rejected',
    TestForeignDirectIsRejected);
  Test('a guest trap does not unwind through the cdecl thunk',
    TestTrapDoesNotUnwindCFrame);
  Test('a guest exception does not unwind through the cdecl thunk',
    TestExceptionDoesNotUnwindCFrame);
  Test('a guest exit does not unwind through the cdecl thunk',
    TestExitDoesNotUnwindCFrame);
  Test('a raylib-style audio callback marshals pointer and frames',
    TestRaylibAudioShape);
  Test('an SDL-style event filter returns an i32 on the store thread',
    TestSdlFilterShape);
end;

begin
  TestRunnerProgram.AddSuite(TCallbackTests.Create('Wasm.Connector.Callbacks'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
