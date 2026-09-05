{ Unit suite for Wasm.Engine — Track F1, the host-facing embedding facade.

  Every module is a real .wasm: it is assembled from wat text through the
  shipped Wasm.Wat.Assembler, then LoadModule decodes + validates it exactly
  as an embedder would, and the linker/instantiate/call path is the same one
  `wasmlight run` and the WASI layer will use. Nothing is stubbed — a host
  callback runs guest-invoked, marshaled both ways, and a trap / uncaught
  exception / rooted ref is observed exactly as a host would see it.

  Coverage (embedding-spec §7.1):
    - host-func round trip: a Pascal host func the guest imports and an
      exported wrapper that calls it; assert it ran and both marshalings;
    - link failure: an undefined import -> EWasmLinkError (`unknown import`);
    - signature mismatch: a host defined with the wrong arity -> EWasmLinkError
      (`incompatible import type`), not a silent mis-marshal;
    - trap classification: `unreachable` -> EWasmTrap (a sibling, not a bare
      EWasmError);
    - exported-memory read/write round trip through the chokepoint, and an
      out-of-bounds MemRead returning False without a crash;
    - intern idempotency: TWasmEngine.InternModule is genuinely idempotent
      (settles embedding-spec §1.4's UNCONFIRMED — no EnsureInterned needed);
    - HOST-1 rooting: a host holds a guest struct ref, forces a collection at
      a zero threshold, and RootGet still sees it;
    - the Track H F3/F4 forward hazard: a host catches an uncaught
      EWasmException, roots its exnref immediately, forces a collection, and
      the tag payload survives;
    - a v128 result crossing the call boundary as two slots.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
program Wasm.Engine.Test;

{$I Shared.inc}
{ Host callbacks index the PWasmValue param/result slices directly. }
{$POINTERMATH ON}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Ir,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Wat.Assembler;

type
  { Opaque host state handed through the linker as AData — proves the pointer
    round-trips to the callback. }
  PHostCtx = ^THostCtx;
  THostCtx = record
    Calls: Integer;
    LastSum: Int32;
  end;

{ The host function the round-trip module imports: records it was called and
  returns the sum of its two i32 arguments. }
procedure HostAdd(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: PHostCtx;
begin
  Ctx := PHostCtx(AData);
  Inc(Ctx^.Calls);
  Ctx^.LastSum := AParams[0].I32 + AParams[1].I32;
  AResults[0] := MakeValueI32(Ctx^.LastSum);
end;

type
  TEngineTests = class(TTestSuite)
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FLoaded: array of TWasmLoadedModule;
    FInstances: array of TWasmInstance;
    FLinkers: array of TWasmLinker;

    { Assemble AWat, load it (decode + validate), and keep it alive for the
      whole test — an instance borrows its bytes (ADR-0003), so it must
      outlive the store, which AfterEach frees first. }
    function Load(const AWat: string): TWasmLoadedModule;
    function NewLinker: TWasmLinker;
    function Track(const AInstance: TWasmInstance): TWasmInstance;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestHostFuncRoundTrip;
    procedure TestMissingImportIsALinkError;
    procedure TestWrongSignatureHostIsRejected;
    procedure TestUnreachableIsATrap;
    procedure TestExportedMemoryReadWriteAndOob;
    procedure TestMemoryU64ByteOrderAndBoundaries;
    procedure TestInternModuleIsIdempotent;
    procedure TestHostRootSurvivesCollection;
    procedure TestCaughtExceptionRefSurvivesCollection;
    procedure TestV128CrossesTheCallBoundary;
  end;

{ --- fixture ------------------------------------------------------------- }

procedure TEngineTests.BeforeEach;
begin
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  EnsureInterpreter(FStore);
  FLoaded := nil;
  FInstances := nil;
  FLinkers := nil;
end;

procedure TEngineTests.AfterEach;
var
  Index: Integer;
begin
  { The store owns the underlying instances and borrows the loaded modules'
    bytes (ADR-0003), so it is torn down FIRST; then the loaded modules, then
    the engine. The instance/linker handles own nothing store-side. }
  for Index := 0 to High(FInstances) do
    FInstances[Index].Free;
  FInstances := nil;
  for Index := 0 to High(FLinkers) do
    FLinkers[Index].Free;
  FLinkers := nil;
  FreeAndNil(FStore);
  for Index := 0 to High(FLoaded) do
    FLoaded[Index].Free;
  FLoaded := nil;
  FreeAndNil(FEngine);
end;

function TEngineTests.Load(const AWat: string): TWasmLoadedModule;
begin
  Result := LoadModule(AssembleWatText(AWat));
  SetLength(FLoaded, Length(FLoaded) + 1);
  FLoaded[High(FLoaded)] := Result;
end;

function TEngineTests.NewLinker: TWasmLinker;
begin
  Result := TWasmLinker.Create(FStore);
  SetLength(FLinkers, Length(FLinkers) + 1);
  FLinkers[High(FLinkers)] := Result;
end;

function TEngineTests.Track(const AInstance: TWasmInstance): TWasmInstance;
begin
  Result := AInstance;
  SetLength(FInstances, Length(FInstances) + 1);
  FInstances[High(FInstances)] := AInstance;
end;

{ --- the round-trip module ----------------------------------------------- }

const
  ADDER_WAT =
    '(module' + sLineBreak +
    '  (import "host" "add" (func $add (param i32 i32) (result i32)))' +
    sLineBreak +
    '  (func (export "run") (param i32 i32) (result i32)' + sLineBreak +
    '    (call $add (local.get 0) (local.get 1))))';

{ --- tests --------------------------------------------------------------- }

procedure TEngineTests.TestHostFuncRoundTrip;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Ctx: THostCtx;
  Fn: TWasmFunc;
  Args: array of TWasmValue;
  Results: array of TWasmValue;
begin
  Ctx.Calls := 0;
  Ctx.LastSum := 0;

  Loaded := Load(ADDER_WAT);
  Linker := NewLinker;
  Linker.DefineFunc('host', 'add',
    [MakeNumValueType(wntI32), MakeNumValueType(wntI32)],
    [MakeNumValueType(wntI32)], @HostAdd, @Ctx);

  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportFunc('run', Fn)).ToBe(True);

  SetLength(Args, 2);
  Args[0] := MakeValueI32(7);
  Args[1] := MakeValueI32(5);
  SetLength(Results, 1);
  Call(Fn, Args, Results);

  { The host callback ran exactly once, saw its arguments, and its result
    marshaled back to the guest and out to us. }
  Expect<Int32>(Ctx.Calls).ToBe(1);
  Expect<Int32>(Ctx.LastSum).ToBe(12);
  Expect<Int32>(Results[0].I32).ToBe(12);
end;

procedure TEngineTests.TestMissingImportIsALinkError;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Caught: string;
begin
  { The linker defines nothing — deny-by-default means the import is simply
    absent and instantiation fails, never a silent no-op. }
  Loaded := Load(ADDER_WAT);
  Linker := NewLinker;

  Caught := '(no error)';
  try
    Track(Instantiate(FStore, Linker, Loaded));
  except
    on E: EWasmLinkError do
      Caught := E.Message;
  end;
  Expect<Boolean>(Pos(string(MSG_LINK_UNKNOWN_IMPORT), Caught) = 1).ToBe(True);
end;

procedure TEngineTests.TestWrongSignatureHostIsRejected;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Caught: string;
begin
  { The guest imports (param i32 i32)(result i32); the host is defined with a
    single parameter. The engine-type-id solution makes MatchFuncImport an id
    comparison, so the structural check is what must catch this — a wrong
    signature is a link error, not a mis-marshal. }
  Loaded := Load(ADDER_WAT);
  Linker := NewLinker;
  Linker.DefineFunc('host', 'add',
    [MakeNumValueType(wntI32)],
    [MakeNumValueType(wntI32)], @HostAdd, nil);

  Caught := '(no error)';
  try
    Track(Instantiate(FStore, Linker, Loaded));
  except
    on E: EWasmLinkError do
      Caught := E.Message;
  end;
  Expect<Boolean>(Pos(string(MSG_LINK_INCOMPATIBLE_IMPORT), Caught) = 1)
    .ToBe(True);
end;

procedure TEngineTests.TestUnreachableIsATrap;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  NoArgs, NoResults: array of TWasmValue;
  Kind: string;
begin
  Loaded := Load('(module (func (export "boom") unreachable))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportFunc('boom', Fn)).ToBe(True);

  NoArgs := nil;
  NoResults := nil;
  Kind := 'none';
  { EWasmException derives from EWasmError alongside EWasmTrap, so catch it
    first — a trap must classify as EWasmTrap, never fold into either. }
  try
    Call(Fn, NoArgs, NoResults);
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

procedure TEngineTests.TestExportedMemoryReadWriteAndOob;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Poke, Peek: TWasmFunc;
  Mem: TWasmMemoryRef;
  Args, Results: array of TWasmValue;
  ReadBack: UInt32;
  Scratch: array[0..3] of Byte;
begin
  Loaded := Load(
    '(module' + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "poke") (param i32 i32)' + sLineBreak +
    '    (i32.store (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "peek") (param i32) (result i32)' + sLineBreak +
    '    (i32.load (local.get 0))))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));

  Expect<Boolean>(Inst.FindExportMemory('memory', Mem)).ToBe(True);
  Expect<Boolean>(MemSize(Mem) = UInt64(65536)).ToBe(True);
  Expect<Boolean>(Inst.FindExportFunc('poke', Poke)).ToBe(True);
  Expect<Boolean>(Inst.FindExportFunc('peek', Peek)).ToBe(True);

  { Guest writes, host reads it back through the chokepoint. }
  SetLength(Args, 2);
  Args[0] := MakeValueI32(16);
  Args[1] := MakeValueI32(Int32($12345678));
  SetLength(Results, 0);
  Call(Poke, Args, Results);
  Expect<Boolean>(MemReadU32(Mem, 16, ReadBack)).ToBe(True);
  Expect<Boolean>(ReadBack = UInt32($12345678)).ToBe(True);

  { Host writes, guest reads it back. }
  Expect<Boolean>(MemWriteU32(Mem, 32, UInt32($0BADF00D))).ToBe(True);
  SetLength(Args, 1);
  Args[0] := MakeValueI32(32);
  SetLength(Results, 1);
  Call(Peek, Args, Results);
  Expect<Boolean>(UInt32(Results[0].I32) = UInt32($0BADF00D)).ToBe(True);

  { An out-of-bounds read returns False cleanly — no crash, no trap. This is
    the sandbox boundary the WASI layer builds on. }
  Expect<Boolean>(MemRead(Mem, MemSize(Mem), 4, @Scratch[0])).ToBe(False);
  Expect<Boolean>(MemReadU32(Mem, UInt64($FFFFFFF0), ReadBack)).ToBe(False);
  { A zero-length read at exactly the end is in bounds. }
  Expect<Boolean>(MemRead(Mem, MemSize(Mem), 0, @Scratch[0])).ToBe(True);
end;

procedure TEngineTests.TestMemoryU64ByteOrderAndBoundaries;
const
  Expected: array[0..7] of Byte = ($EF, $CD, $AB, $89, $67, $45, $23, $01);
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Mem: TWasmMemoryRef;
  Bytes: array[0..15] of Byte;
  I: Integer;
  Last: UInt64;
begin
  Loaded := Load('(module (memory (export "memory") 1))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportMemory('memory', Mem)).ToBe(True);
  { Judge raw guest bytes independently of MemReadU64 at an unaligned address. }
  Expect<Boolean>(MemWriteU64(Mem, 3, UInt64($0123456789ABCDEF))).ToBe(True);
  Expect<Boolean>(MemRead(Mem, 3, 8, @Bytes[0])).ToBe(True);
  for I := 0 to 7 do
    Expect<Byte>(Bytes[I]).ToBe(Expected[I]);
  Expect<Boolean>(MemWriteU64(Mem, 3, High(UInt64))).ToBe(True);
  Expect<Boolean>(MemRead(Mem, 3, 8, @Bytes[0])).ToBe(True);
  for I := 0 to 7 do
    Expect<Byte>(Bytes[I]).ToBe($FF);

  Last := MemSize(Mem);
  for I := 0 to 15 do
    Bytes[I] := $A5;
  Expect<Boolean>(MemWrite(Mem, Last - 16, 16, @Bytes[0])).ToBe(True);
  Expect<Boolean>(MemWriteU64(Mem, Last - 8, UInt64($0123456789ABCDEF))).ToBe(True);
  { Every rejected write must leave even its in-bounds prefix untouched. }
  Expect<Boolean>(MemWriteU64(Mem, Last - 7, 0)).ToBe(False);
  Expect<Boolean>(MemWriteU64(Mem, Last, 0)).ToBe(False);
  Expect<Boolean>(MemWriteU64(Mem, High(UInt64), 0)).ToBe(False);
  Expect<Boolean>(MemRead(Mem, Last - 16, 16, @Bytes[0])).ToBe(True);
  for I := 0 to 7 do
  begin
    Expect<Byte>(Bytes[I]).ToBe($A5);
    Expect<Byte>(Bytes[I + 8]).ToBe(Expected[I]);
  end;
end;

procedure TEngineTests.TestInternModuleIsIdempotent;
var
  Loaded: TWasmLoadedModule;
  CanonA, TypeA, CanonB, TypeB: TWasmEngineTypeIds;
  CountAfterFirst: Integer;
  Index: Integer;
  Same: Boolean;
begin
  { A module with one struct type, so interning allocates at least one engine
    type the second call must NOT re-append. Settles §1.4's UNCONFIRMED:
    InternModule is idempotent, so the linker needs no EnsureInterned. }
  Loaded := Load(
    '(module (type $t (struct (field i32)))' + sLineBreak +
    '  (func (export "keep") (result (ref $t)) (struct.new_default $t)))');

  FStore.Engine.InternModule(Loaded.Ir, CanonA, TypeA);
  CountAfterFirst := FStore.Engine.TypeCount;
  FStore.Engine.InternModule(Loaded.Ir, CanonB, TypeB);

  { No new engine types allocated on the second call. }
  Expect<Int32>(FStore.Engine.TypeCount).ToBe(CountAfterFirst);
  { And the ids returned are identical. }
  Expect<Int32>(Length(CanonB)).ToBe(Length(CanonA));
  Same := Length(CanonA) = Length(CanonB);
  for Index := 0 to High(CanonA) do
    if CanonA[Index] <> CanonB[Index] then
      Same := False;
  for Index := 0 to High(TypeA) do
    if TypeA[Index] <> TypeB[Index] then
      Same := False;
  Expect<Boolean>(Same).ToBe(True);
end;

procedure TEngineTests.TestHostRootSurvivesCollection;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Make, Alloc: TWasmFunc;
  NoArgs, One: array of TWasmValue;
  OrigRef, Survivor: TWasmRef;
  Handle: TWasmRootHandle;
begin
  Loaded := Load(
    '(module (type $t (struct (field i32)))' + sLineBreak +
    '  (func (export "make") (result (ref $t)) (struct.new_default $t))' +
    sLineBreak +
    '  (func (export "alloc") (result (ref $t)) (struct.new_default $t)))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportFunc('make', Make)).ToBe(True);
  Expect<Boolean>(Inst.FindExportFunc('alloc', Alloc)).ToBe(True);

  NoArgs := nil;
  SetLength(One, 1);
  Call(Make, NoArgs, One);
  OrigRef := One[0].Ref;
  Expect<Boolean>(RefIsObject(OrigRef)).ToBe(True);

  { Root it the instant we have it — before any allocation. Without this the
    ref sits only in a Pascal local the collector cannot see (HOST-1). }
  Handle := RootRegister(FStore, OrigRef);

  { Collect at every allocation, then allocate: the collection the second
    Call triggers would reclaim OrigRef were it not rooted. }
  FStore.Heap.Threshold := 0;
  SetLength(One, 1);
  Call(Alloc, NoArgs, One);

  Survivor := RootGet(FStore, Handle);
  { Non-moving, so the survivor is the same pointer; still an object, and its
    field is readable — proof it was not swept. }
  Expect<Boolean>(Survivor = OrigRef).ToBe(True);
  Expect<Boolean>(RefIsObject(Survivor)).ToBe(True);
  Expect<Boolean>(GcRefKind(Survivor) = wokStruct).ToBe(True);
  Expect<Int32>(FStore.Heap.StructGet(Survivor, 0).I32).ToBe(0);

  RootRelease(FStore, Handle);
end;

procedure TEngineTests.TestCaughtExceptionRefSurvivesCollection;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Boom, Alloc: TWasmFunc;
  NoArgs, NoResults, One: array of TWasmValue;
  Handle: TWasmRootHandle;
  Threw: Boolean;
  ExnRef: TWasmRef;
begin
  { The Track H F3/F4 forward hazard, made safe. An uncaught guest exception
    carries a raw wokExn handle; once the invocation has unwound the frame
    chain is empty, so it is collectable on the next allocation unless the
    host roots it the instant it catches. }
  Loaded := Load(
    '(module' + sLineBreak +
    '  (type $t (struct (field i32)))' + sLineBreak +
    '  (tag $e (param i32))' + sLineBreak +
    '  (func (export "boom") i32.const 99 throw $e)' + sLineBreak +
    '  (func (export "alloc") (result (ref $t)) (struct.new_default $t)))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportFunc('boom', Boom)).ToBe(True);
  Expect<Boolean>(Inst.FindExportFunc('alloc', Alloc)).ToBe(True);

  NoArgs := nil;
  NoResults := nil;
  Threw := False;
  Handle := WASM_NO_ROOT;
  try
    Call(Boom, NoArgs, NoResults);
  except
    on E: EWasmException do
    begin
      Threw := True;
      { Root the exnref immediately, before the allocating Call below. }
      Handle := RootExceptionRef(FStore, E);
    end;
  end;
  Expect<Boolean>(Threw).ToBe(True);

  { Force a collection past the caught exception. }
  FStore.Heap.Threshold := 0;
  SetLength(One, 1);
  Call(Alloc, NoArgs, One);

  ExnRef := RootGet(FStore, Handle);
  Expect<Boolean>(RefIsObject(ExnRef)).ToBe(True);
  Expect<Boolean>(GcRefKind(ExnRef) = wokExn).ToBe(True);
  { The tag payload survived the collection — the exception was not swept. }
  Expect<Boolean>(FStore.Heap.ExnArgCount(ExnRef) = 1).ToBe(True);
  Expect<Int32>(FStore.Heap.ExnArg(ExnRef, 0).I32).ToBe(99);

  RootRelease(FStore, Handle);
end;

procedure TEngineTests.TestV128CrossesTheCallBoundary;
var
  Loaded: TWasmLoadedModule;
  Linker: TWasmLinker;
  Inst: TWasmInstance;
  Fn: TWasmFunc;
  NoArgs, Results: array of TWasmValue;
begin
  { A v128 result occupies two adjacent slots, low half first (§1.6). The
    facade counts the two slots from the result type vector, so a v128
    crossing the boundary is handled without a special case. }
  Loaded := Load(
    '(module (func (export "v") (result v128)' + sLineBreak +
    '  (v128.const i32x4 1 2 3 4)))');
  Linker := NewLinker;
  Inst := Track(Instantiate(FStore, Linker, Loaded));
  Expect<Boolean>(Inst.FindExportFunc('v', Fn)).ToBe(True);

  NoArgs := nil;
  SetLength(Results, 2);
  Call(Fn, NoArgs, Results);
  { i32x4 lanes 1,2,3,4 little-endian: low slot = lanes 0..1, high = 2..3. }
  Expect<Boolean>(Results[0].Bits = UInt64($0000000200000001)).ToBe(True);
  Expect<Boolean>(Results[1].Bits = UInt64($0000000400000003)).ToBe(True);
end;

procedure TEngineTests.SetupTests;
begin
  Test('a host function round-trips arguments and results through the guest',
    TestHostFuncRoundTrip);
  Test('an undefined import is a link error (unknown import)',
    TestMissingImportIsALinkError);
  Test('a host defined with the wrong signature is rejected',
    TestWrongSignatureHostIsRejected);
  Test('calling unreachable classifies as EWasmTrap',
    TestUnreachableIsATrap);
  Test('exported memory reads and writes round-trip, and OOB is a clean False',
    TestExportedMemoryReadWriteAndOob);
  Test('u64 writes preserve byte order and reject partial boundary writes',
    TestMemoryU64ByteOrderAndBoundaries);
  Test('InternModule is idempotent so the linker needs no EnsureInterned',
    TestInternModuleIsIdempotent);
  Test('a rooted host ref survives a forced collection',
    TestHostRootSurvivesCollection);
  Test('a rooted caught exception ref survives a forced collection',
    TestCaughtExceptionRefSurvivesCollection);
  Test('a v128 result crosses the call boundary as two slots',
    TestV128CrossesTheCallBoundary);
end;

begin
  TestRunnerProgram.AddSuite(TEngineTests.Create('Wasm.Engine'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
