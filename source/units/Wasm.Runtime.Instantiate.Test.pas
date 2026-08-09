{ Unit suite for Wasm.Runtime.Instantiate — the constant-expression
  evaluator and the instantiation sequence.

  Every module here is assembled byte by byte and pushed through the real
  decoder and the real validator, so what instantiation is handed is an IR
  that a valid module actually produces. Nothing is stubbed: the
  initialiser values, the table contents and the memory bytes are read
  back through the same chokepoints a tier would use.

  NOTHING IN THIS SUITE RUNS GUEST CODE. That is the constraint the whole
  wave plan was shaped around — the first thing to execute a wasm function
  is Track E — and it is why the start function is asserted as a RECORDED
  pending state plus a clear error, rather than as a call.

  Spec anchors are cited per group, read from wasm-mcp 0.2.16 at the
  pinned commit d7b37e4170d8315f2f1283aed4e8076591a9a333. }
program Wasm.Runtime.Instantiate.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator;

type
  TByteBuf = record
    Data: TWasmBytes;
    Count: Integer;

    procedure Reset;
    procedure Add(const AValue: Byte);
    procedure AddMany(const AValues: array of Byte);
    procedure AddU32(const AValue: UInt32);
    procedure Section(const AId: TWasmSectionId; const ABody: array of Byte);
    function Finish: TWasmBytes;
  end;

  TRuntimeInstantiateTests = class(TTestSuite)
  private
    { The IR and every instance borrow this buffer (ADR-0003), so it
      outlives both — which is exactly the lifetime rule under test
      everywhere else in this file. }
    FBytes: TWasmBytes;
    FBuf: TByteBuf;
    FModule: TWasmModule;
    FIr: TWasmIrModule;
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FImports: TWasmImports;

    { The corpus test instantiates many modules into one store, and every
      instance borrows its own IR and its own buffer — so all three
      outlive the store and are released only after it. }
    FCorpusBytes: array of TWasmBytes;
    FCorpusModules: array of TWasmModule;
    FCorpusIrs: array of TWasmIrModule;

    procedure StartModule;
    procedure Sect(const AId: TWasmSectionId; const ABody: array of Byte);
    procedure FinishAndValidate;
    function Instantiate: TWasmModuleInstance;

    procedure BuildFixtureModule;
    procedure BuildConstantsModule;
    function SupplyImportedGlobal(const AMutable: Boolean;
      const AValue: Int32): TWasmGlobalAddr;

    function MemByte(const AAddr: TWasmMemAddr;
      const AIndex: UInt64): Byte;
    function GlobalI32(const AInstance: TWasmModuleInstance;
      const AIndex: Integer): Int32;
    function GlobalI64(const AInstance: TWasmModuleInstance;
      const AIndex: Integer): Int64;
    function OutcomeOf(const APrefix: string): string;
    procedure ExpectCount(const AWhat: string;
      const AActual, AExpected: Integer);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestInstantiatesTheFixtureModule;
    procedure TestGlobalInitialisersAndChains;
    procedure TestDataReachesMemoryThroughTheChokepoint;
    procedure TestElementSegmentPopulatesTheTable;
    procedure TestAppliedSegmentsAreDroppedAndTheBufferIsReleased;
    procedure TestPassiveDataKeepsBorrowingTheBuffer;
    procedure TestDeclarativeSegmentIsDroppedImmediately;

    procedure TestWrappingArithmeticInConstantExpressions;
    procedure TestReferenceConstantExpressions;
    procedure TestStructNewInitialisesAGlobal;
    procedure TestArrayConstantExpressions;
    procedure TestElementSegmentAndStructGlobalCoexist;

    procedure TestActiveDataOutOfBoundsTraps;
    procedure TestActiveElemOutOfBoundsTraps;
    procedure TestActiveDataOnImportedMemoryPersistsAfterTrap;
    procedure TestActiveElemOnImportedTablePersistsAfterTrap;

    procedure TestMissingImportIsALinkErrorBeforeAnyMutation;
    procedure TestIncompatibleImportIsALinkErrorBeforeAnyMutation;
    procedure TestUnknownImportSentinelIsALinkError;
    procedure TestRepeatedInstantiationDoesNotLeakRoots;
    procedure TestStartIsRecordedAndNeedsATier;

    procedure TestFixtureCorpusInstantiates;
  end;

const
  VALID_DIR = 'tests/fixtures/valid';

  { A corpus that shrinks silently is a suite that passes vacuously, so
    the count is asserted against a floor. Raise it when fixtures are
    added; never lower it to make a run go green. }
  MIN_INSTANTIATED_FIXTURES = 10;

  { The one valid fixture that cannot reach instantiation: $FD validation
    is staged to Track G, so it never produces an IR. }
  SIMD_FIXTURE = 'simd.wasm';

{ --- TByteBuf ------------------------------------------------------------ }

procedure TByteBuf.Reset;
begin
  Data := nil;
  Count := 0;
end;

procedure TByteBuf.Add(const AValue: Byte);
begin
  if Count >= Length(Data) then
    SetLength(Data, (Count + 1) * 2);
  Data[Count] := AValue;
  Inc(Count);
end;

procedure TByteBuf.AddMany(const AValues: array of Byte);
var
  I: Integer;
begin
  for I := 0 to High(AValues) do
    Add(AValues[I]);
end;

procedure TByteBuf.AddU32(const AValue: UInt32);
var
  Rest: UInt32;
begin
  Rest := AValue;
  repeat
    if Rest < $80 then
      Add(Byte(Rest))
    else
      Add(Byte((Rest and $7F) or $80));
    Rest := Rest shr 7;
  until Rest = 0;
end;

procedure TByteBuf.Section(const AId: TWasmSectionId;
  const ABody: array of Byte);
begin
  Add(Ord(AId));
  AddU32(UInt32(Length(ABody)));
  AddMany(ABody);
end;

function TByteBuf.Finish: TWasmBytes;
begin
  SetLength(Data, Count);
  Result := Data;
end;

{ --- fixture ------------------------------------------------------------- }

procedure TRuntimeInstantiateTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FIr := nil;
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  FImports.Funcs := nil;
  FImports.Tables := nil;
  FImports.Mems := nil;
  FImports.Globals := nil;
  FImports.Tags := nil;
end;

procedure TRuntimeInstantiateTests.AfterEach;
var
  Index: Integer;
begin
  { The store owns every instance and must go first: an instance borrows
    the IR, which borrows the buffer. }
  FreeAndNil(FStore);
  FreeAndNil(FEngine);
  FreeAndNil(FIr);
  FreeAndNil(FModule);
  for Index := 0 to High(FCorpusIrs) do
    FCorpusIrs[Index].Free;
  for Index := 0 to High(FCorpusModules) do
    FCorpusModules[Index].Free;
  FCorpusIrs := nil;
  FCorpusModules := nil;
  FCorpusBytes := nil;
end;

procedure TRuntimeInstantiateTests.StartModule;
begin
  FBuf.Reset;
  FBuf.AddMany([$00, $61, $73, $6D, $01, $00, $00, $00]);
end;

procedure TRuntimeInstantiateTests.Sect(const AId: TWasmSectionId;
  const ABody: array of Byte);
begin
  FBuf.Section(AId, ABody);
end;

procedure TRuntimeInstantiateTests.FinishAndValidate;
begin
  FBytes := FBuf.Finish;
  DecodeModule(FBytes, FModule);
  FreeAndNil(FIr);
  FIr := ValidateModule(FModule, FBytes);
end;

function TRuntimeInstantiateTests.Instantiate: TWasmModuleInstance;
begin
  Result := InstantiateModule(FStore, FIr, @FBytes[0],
    NativeUInt(Length(FBytes)), FImports);
end;

function TRuntimeInstantiateTests.SupplyImportedGlobal(
  const AMutable: Boolean; const AValue: Int32): TWasmGlobalAddr;
begin
  Result := FStore.AddGlobal(
    MakeGlobalType(AMutable, MakeNumValueType(wntI32)),
    MakeValueI32(AValue));
  SetLength(FImports.Globals, 1);
  FImports.Globals[0] := Result;
end;

{ One module touching every space instantiation has to build:

    import 0  "env"."g" (global i32)          -> global 0
    func   0  (type 0)                        -> the one defined function
    table  0  funcref 2
    memory 0  1 page
    global 1  i32 = (i32.const 7)
    global 2  i32 = (global.get 1)            -- an EARLIER DEFINED global
    global 3  i32 = (global.get 0)            -- the IMPORT
    exports   "f" func 0, "m" memory 0, "t" table 0
    elem 0    active table 0, offset 0, funcidx [0]
    data 0    active memory 0, offset 0, "ab"
    data 1    active memory 0, offset 4, "hi"

  Sections are emitted in the binary format's PRESCRIBED order, which is
  not id order. }
procedure TRuntimeInstantiateTests.BuildFixtureModule;
begin
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsImport, [$01,
    $03, $65, $6E, $76, $01, $67, $03, $7F, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsTable, [$01, $70, $00, $02]);
  Sect(wsMemory, [$01, $00, $01]);
  Sect(wsGlobal, [$03,
    $7F, $00, $41, $07, $0B,
    $7F, $00, $23, $01, $0B,
    $7F, $00, $23, $00, $0B]);
  Sect(wsExport, [$03,
    $01, $66, $00, $00,
    $01, $6D, $02, $00,
    $01, $74, $01, $00]);
  Sect(wsElement, [$01, $00, $41, $00, $0B, $01, $00]);
  Sect(wsDataCount, [$02]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  Sect(wsData, [$02,
    $00, $41, $00, $0B, $02, $61, $62,
    $00, $41, $04, $0B, $02, $68, $69]);
  FinishAndValidate;
end;

{ Globals whose initialisers exercise every arithmetic and reference form
  the evaluator supports:

    0  i32 = 0x7FFFFFFF + 1        wraps to INT32_MIN
    1  i64 = -1 + 1                wraps to 0
    2  i32 = 65536 * 65536         wraps to 0
    3  i32 = 0 - 1                 wraps to -1
    4  funcref = ref.null func
    5  (ref null i31) = ref.i31 5
    6  f32 = 1.5 }
procedure TRuntimeInstantiateTests.BuildConstantsModule;
begin
  StartModule;
  Sect(wsGlobal, [$07,
    $7F, $00, $41, $FF, $FF, $FF, $FF, $07, $41, $01, $6A, $0B,
    $7E, $00, $42, $7F, $42, $01, $7C, $0B,
    $7F, $00, $41, $80, $80, $04, $41, $80, $80, $04, $6C, $0B,
    $7F, $00, $41, $00, $41, $01, $6B, $0B,
    $70, $00, $D0, $70, $0B,
    $6C, $00, $41, $05, $FB, $1C, $0B,
    $7D, $00, $43, $00, $00, $C0, $3F, $0B]);
  FinishAndValidate;
end;

function TRuntimeInstantiateTests.MemByte(const AAddr: TWasmMemAddr;
  const AIndex: UInt64): Byte;
begin
  { Read through THE chokepoint, never by touching Base — ADR-0005: "a new
    caller that bypasses the chokepoint is the failure mode this design is
    most exposed to", and a test is a caller. }
  Result := FStore.MemAddressAt(AAddr, AIndex, 0, 1)^;
end;

function TRuntimeInstantiateTests.GlobalI32(
  const AInstance: TWasmModuleInstance; const AIndex: Integer): Int32;
begin
  Result := FStore.Globals[AInstance.GlobalAddrs[AIndex]].Value.I32;
end;

function TRuntimeInstantiateTests.GlobalI64(
  const AInstance: TWasmModuleInstance; const AIndex: Integer): Int64;
begin
  Result := FStore.Globals[AInstance.GlobalAddrs[AIndex]].Value.I64;
end;

{ Reports the outcome as one string, so a case that fails for the wrong
  reason says which rather than merely failing. }
function TRuntimeInstantiateTests.OutcomeOf(const APrefix: string): string;
var
  Message: string;
  Kind: string;
begin
  Kind := '';
  Message := '';
  try
    Instantiate;
  except
    { Most derived first: EWasmTrap and EWasmLinkError both descend from
      EWasmError, and the class is half of what each case asserts. }
    on E: EWasmTrap do
    begin
      Message := E.Message;
      Kind := 'trap';
    end;
    on E: EWasmLinkError do
    begin
      Message := E.Message;
      Kind := 'link';
    end;
    on E: EWasmError do
    begin
      Message := E.Message;
      Kind := 'error';
    end;
  end;
  if Kind = '' then
    Exit('ACCEPTED');
  if Copy(Message, 1, Length(APrefix)) = APrefix then
    Result := Kind + ': ' + APrefix
  else
    Result := Kind + ' with message: ' + Message;
end;

procedure TRuntimeInstantiateTests.ExpectCount(const AWhat: string;
  const AActual, AExpected: Integer);
begin
  Expect<string>(Format('%s=%d', [AWhat, AActual]))
    .ToBe(Format('%s=%d', [AWhat, AExpected]));
end;

{ --- the fixture module -------------------------------------------------- }

procedure TRuntimeInstantiateTests.TestInstantiatesTheFixtureModule;
var
  Instance: TWasmModuleInstance;
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  SupplyImportedGlobal(False, 11);
  BuildFixtureModule;
  Instance := Instantiate;

  ExpectCount('instances', Length(FStore.Instances), 1);
  ExpectCount('funcs', Length(FStore.Funcs), 1);
  ExpectCount('tables', Length(FStore.Tables), 1);
  ExpectCount('memories', FStore.MemoryCount, 1);
  { One import plus three definitions. }
  ExpectCount('globals', Length(FStore.Globals), 4);
  ExpectCount('elems', Length(FStore.Elems), 1);
  ExpectCount('datas', Length(FStore.Datas), 2);

  { Step 8: the function instance's MODULE field is back-patched to the
    instance that was not yet built when the function was allocated
    (`aux-rundata`'s staging note). }
  Expect<Boolean>(FStore.Funcs[Instance.FuncAddrs[0]].Instance = Instance)
    .ToBe(True);
  Expect<Boolean>(FStore.Funcs[Instance.FuncAddrs[0]].Kind = wfkWasm)
    .ToBe(True);
  { FuncIrIndex indexes the DEFINED functions, not the module index
    space — the offset is applied once, here, and never on a call path. }
  ExpectCount('ir index',
    Integer(FStore.Funcs[Instance.FuncAddrs[0]].FuncIrIndex), 0);

  Expect<Boolean>(Instance.FindExport('f', Kind, Addr)).ToBe(True);
  Expect<Boolean>(Kind = wxkFunc).ToBe(True);
  Expect<Boolean>(Addr = Instance.FuncAddrs[0]).ToBe(True);
  Expect<Boolean>(Instance.FindExport('m', Kind, Addr)).ToBe(True);
  Expect<Boolean>(Kind = wxkMem).ToBe(True);
  Expect<Boolean>(Instance.FindExport('nope', Kind, Addr)).ToBe(False);

  Expect<Boolean>(Instance.HasPendingStart).ToBe(False);
end;

procedure TRuntimeInstantiateTests.TestGlobalInitialisersAndChains;
var
  Instance: TWasmModuleInstance;
begin
  SupplyImportedGlobal(False, 11);
  BuildFixtureModule;
  Instance := Instantiate;

  { The import is SHARED, not copied: the instance's slot 0 names the
    store's existing global. }
  Expect<Boolean>(Instance.GlobalAddrs[0] = FImports.Globals[0]).ToBe(True);
  Expect<Int32>(GlobalI32(Instance, 0)).ToBe(11);
  Expect<Int32>(GlobalI32(Instance, 1)).ToBe(7);
  { A chain: global 2 reads global 1, which the validator's per-global
    window admits because it is an EARLIER global. }
  Expect<Int32>(GlobalI32(Instance, 2)).ToBe(7);
  { And a read of the import. }
  Expect<Int32>(GlobalI32(Instance, 3)).ToBe(11);
end;

procedure TRuntimeInstantiateTests.TestDataReachesMemoryThroughTheChokepoint;
var
  Instance: TWasmModuleInstance;
  Mem: TWasmMemAddr;
begin
  SupplyImportedGlobal(False, 11);
  BuildFixtureModule;
  Instance := Instantiate;
  Mem := Instance.MemAddrs[0];

  Expect<Byte>(MemByte(Mem, 0)).ToBe($61);
  Expect<Byte>(MemByte(Mem, 1)).ToBe($62);
  { The gap between the two segments is untouched, and new pages read as
    zero. }
  Expect<Byte>(MemByte(Mem, 2)).ToBe($00);
  Expect<Byte>(MemByte(Mem, 4)).ToBe($68);
  Expect<Byte>(MemByte(Mem, 5)).ToBe($69);
end;

procedure TRuntimeInstantiateTests.TestElementSegmentPopulatesTheTable;
var
  Instance: TWasmModuleInstance;
  Table: TWasmTableAddr;
  Entry: TWasmRef;
begin
  SupplyImportedGlobal(False, 11);
  BuildFixtureModule;
  Instance := Instantiate;
  Table := Instance.TableAddrs[0];

  Entry := TableGet(FStore.Tables[Table], 0);
  Expect<Boolean>(RefIsObject(Entry)).ToBe(True);
  { ref.func yields the function instance's stable handle, so the element
    is the SAME reference the store holds. }
  Expect<Boolean>(Entry = FStore.Funcs[Instance.FuncAddrs[0]].RefObject)
    .ToBe(True);
  Expect<Boolean>(FStore.FuncRefAddr(Entry) = Instance.FuncAddrs[0])
    .ToBe(True);
  { The rest of the table keeps aux-default's null. }
  Expect<Boolean>(RefIsNull(TableGet(FStore.Tables[Table], 1))).ToBe(True);
end;

procedure TRuntimeInstantiateTests
  .TestAppliedSegmentsAreDroppedAndTheBufferIsReleased;
var
  Instance: TWasmModuleInstance;
begin
  SupplyImportedGlobal(False, 11);
  BuildFixtureModule;
  Instance := Instantiate;

  { An active segment is dropped by the instantiation sequence itself. }
  Expect<Boolean>(FStore.Elems[Instance.ElemAddrs[0]].Dropped).ToBe(True);
  ExpectCount('elem refs',
    Length(FStore.Elems[Instance.ElemAddrs[0]].Refs), 0);
  Expect<Boolean>(FStore.Datas[Instance.DataAddrs[0]].Dropped).ToBe(True);
  Expect<Boolean>(FStore.Datas[Instance.DataAddrs[1]].Dropped).ToBe(True);

  { With every data segment dropped the module buffer is no longer read,
    which is what ADR-0003's "is the underlying binary freeable" query
    reports. }
  Expect<Boolean>(Instance.BorrowsBuffer(FStore)).ToBe(False);
end;

procedure TRuntimeInstantiateTests.TestPassiveDataKeepsBorrowingTheBuffer;
var
  Instance: TWasmModuleInstance;
begin
  { A passive segment is kept until memory.init reads it or data.drop
    drops it, so the buffer stays borrowed. }
  StartModule;
  Sect(wsData, [$01, $01, $02, $68, $69]);
  FinishAndValidate;
  Instance := Instantiate;

  Expect<Boolean>(FStore.Datas[Instance.DataAddrs[0]].Dropped).ToBe(False);
  ExpectCount('size',
    Integer(FStore.Datas[Instance.DataAddrs[0]].Size), 2);
  Expect<Byte>(FStore.Datas[Instance.DataAddrs[0]].Data^).ToBe($68);
  Expect<Boolean>(Instance.BorrowsBuffer(FStore)).ToBe(True);
end;

procedure TRuntimeInstantiateTests.TestDeclarativeSegmentIsDroppedImmediately;
var
  Instance: TWasmModuleInstance;
begin
  { A declarative segment exists only so ref.func may name its functions
    during validation; it holds nothing at run time. }
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsElement, [$01, $07, $70, $01, $D2, $00, $0B]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;
  Instance := Instantiate;

  Expect<Boolean>(FStore.Elems[Instance.ElemAddrs[0]].Dropped).ToBe(True);
  ExpectCount('refs', Length(FStore.Elems[Instance.ElemAddrs[0]].Refs), 0);
end;

{ --- the evaluator ------------------------------------------------------- }

procedure TRuntimeInstantiateTests.TestWrappingArithmeticInConstantExpressions;
var
  Instance: TWasmModuleInstance;
begin
  { Extended constant expressions are ordinary wasm arithmetic: modulo
    2^N, and i32.add / i32.sub / i32.mul report can_trap:false. Every
    case below is a BOUNDARY — an implementation that let FPC's overflow
    checks stand would raise instead of wrapping. }
  BuildConstantsModule;
  Instance := Instantiate;

  Expect<Int32>(GlobalI32(Instance, 0)).ToBe(Int32($80000000));
  Expect<Int64>(GlobalI64(Instance, 1)).ToBe(0);
  Expect<Int32>(GlobalI32(Instance, 2)).ToBe(0);
  Expect<Int32>(GlobalI32(Instance, 3)).ToBe(-1);
end;

procedure TRuntimeInstantiateTests.TestReferenceConstantExpressions;
var
  Instance: TWasmModuleInstance;
  Ref: TWasmRef;
begin
  BuildConstantsModule;
  Instance := Instantiate;

  Ref := FStore.Globals[Instance.GlobalAddrs[4]].Value.Ref;
  Expect<Boolean>(RefIsNull(Ref)).ToBe(True);

  { ref.i31 is UNBOXED: 31 payload bits plus one tag bit is exactly 32, so
    it needs no heap and evaluates before the collector exists. }
  Ref := FStore.Globals[Instance.GlobalAddrs[5]].Value.Ref;
  Expect<Boolean>(RefIsI31(Ref)).ToBe(True);
  Expect<Int32>(I31GetSigned(Ref)).ToBe(5);

  { Floats travel as bit patterns, never through an FPC float assignment:
    1.5 is 0x3FC00000. }
  Expect<Boolean>(FStore.Globals[Instance.GlobalAddrs[6]].Value.Bits =
    UInt64($3FC00000)).ToBe(True);
end;

procedure TRuntimeInstantiateTests.TestStructNewInitialisesAGlobal;
var
  Instance: TWasmModuleInstance;
  Ref: TWasmRef;
begin
  { struct.new IS a constant instruction and the validator accepts it;
    evaluating one allocates on the GC heap, which is the one exception to
    "evaluation of constant expressions does not affect the store".

      type 0  (struct (field i32) (field i64))
      global 0  (ref null 0) = (struct.new 0 (i32.const 7) (i64.const 9))

    The fields are read back THROUGH THE HEAP API rather than by poking at
    the object, because the byte offsets are the collector's business and
    a test that hardcoded them would pass while the layout was wrong. }
  StartModule;
  Sect(wsType, [$01, $5F, $02, $7F, $00, $7E, $00]);
  Sect(wsGlobal, [$01, $63, $00, $00,
    $41, $07, $42, $09, $FB, $00, $00, $0B]);
  FinishAndValidate;
  Instance := Instantiate;

  Ref := FStore.Globals[Instance.GlobalAddrs[0]].Value.Ref;
  Expect<Boolean>(RefIsObject(Ref)).ToBe(True);
  Expect<Boolean>(GcRefKind(Ref) = wokStruct).ToBe(True);
  Expect<Int32>(FStore.Heap.StructGet(Ref, 0).I32).ToBe(7);
  Expect<Int64>(FStore.Heap.StructGet(Ref, 1).I64).ToBe(9);

  { The object's header carries the ENGINE id, so the runtime cast agrees
    with the type the module declared. }
  Expect<Boolean>(IsRefOfType(FEngine, Ref, Instance.EngineTypeIds[0]))
    .ToBe(True);

  { And it is a live root: a collection with the global as the only holder
    must not reclaim it. }
  FStore.Heap.Collect;
  Expect<Int32>(FStore.Heap.StructGet(Ref, 0).I32).ToBe(7);
end;

procedure TRuntimeInstantiateTests.TestArrayConstantExpressions;
var
  Instance: TWasmModuleInstance;
  Fixed: TWasmRef;
  Filled: TWasmRef;
  Defaulted: TWasmRef;
begin
  { type 0  (array (mut i32))
      global 0 = (array.new_fixed 0 3 (i32.const 1) (i32.const 2)
                                      (i32.const 3))
      global 1 = (array.new 0 (i32.const 7) (i32.const 4))
      global 2 = (array.new_default 0 (i32.const 2))

    array.new_fixed takes an OPERAND LIST and gets its length from it;
    array.new takes one value and a length, with the length on top. }
  StartModule;
  Sect(wsType, [$01, $5E, $7F, $01]);
  Sect(wsGlobal, [$03,
    $63, $00, $00, $41, $01, $41, $02, $41, $03, $FB, $08, $00, $03, $0B,
    $63, $00, $00, $41, $07, $41, $04, $FB, $06, $00, $0B,
    $63, $00, $00, $41, $02, $FB, $07, $00, $0B]);
  FinishAndValidate;
  Instance := Instantiate;

  Fixed := FStore.Globals[Instance.GlobalAddrs[0]].Value.Ref;
  Expect<Boolean>(GcRefKind(Fixed) = wokArray).ToBe(True);
  ExpectCount('fixed length', Integer(FStore.Heap.ArrayLength(Fixed)), 3);
  Expect<Int32>(FStore.Heap.ArrayGet(Fixed, 0).I32).ToBe(1);
  Expect<Int32>(FStore.Heap.ArrayGet(Fixed, 2).I32).ToBe(3);

  Filled := FStore.Globals[Instance.GlobalAddrs[1]].Value.Ref;
  ExpectCount('filled length', Integer(FStore.Heap.ArrayLength(Filled)), 4);
  Expect<Int32>(FStore.Heap.ArrayGet(Filled, 3).I32).ToBe(7);

  { aux-default is zero for a defaultable element type. }
  Defaulted := FStore.Globals[Instance.GlobalAddrs[2]].Value.Ref;
  ExpectCount('default length',
    Integer(FStore.Heap.ArrayLength(Defaulted)), 2);
  Expect<Int32>(FStore.Heap.ArrayGet(Defaulted, 1).I32).ToBe(0);

  { Three distinct objects, none of them aliased. }
  Expect<Boolean>((Fixed <> Filled) and (Filled <> Defaulted)).ToBe(True);
end;

procedure TRuntimeInstantiateTests.TestElementSegmentAndStructGlobalCoexist;
var
  Instance: TWasmModuleInstance;
  Ref: TWasmRef;
  Entry: TWasmRef;
begin
  { The two root producers that only meet at instantiation:

      func   0  ()
      table  0  funcref 1
      global 0  (ref null 1) = (struct.new 1 (i32.const 42))
      elem   0  active table 0 offset 0 [func 0]

    A funcref handle IS a heap object now, so the table entry and the
    struct global are both roots and a collection must keep both. }
  StartModule;
  Sect(wsType, [$02, $60, $00, $00, $5F, $01, $7F, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsTable, [$01, $70, $00, $01]);
  Sect(wsGlobal, [$01, $63, $01, $00, $41, $2A, $FB, $00, $01, $0B]);
  Sect(wsElement, [$01, $00, $41, $00, $0B, $01, $00]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;
  Instance := Instantiate;

  Ref := FStore.Globals[Instance.GlobalAddrs[0]].Value.Ref;
  Entry := TableGet(FStore.Tables[Instance.TableAddrs[0]], 0);
  Expect<Boolean>(GcRefKind(Ref) = wokStruct).ToBe(True);
  Expect<Boolean>(GcRefKind(Entry) = wokFuncRef).ToBe(True);
  Expect<Boolean>(Entry = FStore.Funcs[Instance.FuncAddrs[0]].RefObject)
    .ToBe(True);

  FStore.Heap.Collect;

  { Both survive, and the funcref handle still names its function — the
    handover of funcref allocation to the collector must not have changed
    what ref.func means. }
  Expect<Int32>(FStore.Heap.StructGet(Ref, 0).I32).ToBe(42);
  Expect<Boolean>(FStore.FuncRefAddr(Entry) = Instance.FuncAddrs[0])
    .ToBe(True);
  Expect<Boolean>(TableGet(FStore.Tables[Instance.TableAddrs[0]], 0) = Entry)
    .ToBe(True);
end;

{ --- segment traps ------------------------------------------------------- }

procedure TRuntimeInstantiateTests.TestActiveDataOutOfBoundsTraps;
var
  Instance: TWasmModuleInstance;
begin
  { An out-of-bounds ACTIVE segment is a TRAP, not a link error: 3.0
    executes active segments as bulk-copy instructions and `exec-module`
    says instantiation "can also result in an exception or trap when
    initializing a table or memory from an active segment". It happens
    AFTER mutation, and earlier segments stay applied — that is the
    spec's behaviour, not a defect. }
  StartModule;
  Sect(wsMemory, [$01, $00, $01]);
  Sect(wsDataCount, [$02]);
  Sect(wsData, [$02,
    $00, $41, $00, $0B, $02, $61, $62,
    $00, $41, $FF, $FF, $03, $0B, $02, $68, $69]);
  FinishAndValidate;

  Expect<string>(OutcomeOf(MSG_TRAP_MEMORY_OUT_OF_BOUNDS))
    .ToBe('trap: ' + MSG_TRAP_MEMORY_OUT_OF_BOUNDS);

  { The partially-initialised store is observable, and the first segment
    was written before the second trapped. }
  ExpectCount('instances', Length(FStore.Instances), 1);
  Instance := FStore.Instances[0];
  Expect<Byte>(MemByte(Instance.MemAddrs[0], 0)).ToBe($61);
  Expect<Byte>(MemByte(Instance.MemAddrs[0], 1)).ToBe($62);
  { The trapping segment wrote nothing: the range check precedes the
    copy. }
  Expect<Byte>(MemByte(Instance.MemAddrs[0], 65535)).ToBe($00);
end;

procedure TRuntimeInstantiateTests.TestActiveElemOutOfBoundsTraps;
begin
  { table.init's message, which is the same as table.get's and is NOT
    call_indirect's `undefined element`. One element at offset 1 in a
    one-entry table is one past the end. }
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsTable, [$01, $70, $00, $01]);
  Sect(wsElement, [$01, $00, $41, $01, $0B, $01, $00]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;

  Expect<string>(OutcomeOf(MSG_TRAP_TABLE_OUT_OF_BOUNDS))
    .ToBe('trap: ' + MSG_TRAP_TABLE_OUT_OF_BOUNDS);
  { The table was allocated before the segment was applied, so it exists
    and is still null-filled. }
  ExpectCount('tables', Length(FStore.Tables), 1);
  Expect<Boolean>(RefIsNull(TableGet(FStore.Tables[0], 0))).ToBe(True);
end;

{ An active segment written to an IMPORTED memory reaches the SHARED store
  object, and the write PERSISTS after a later segment traps out of bounds —
  the behaviour linking.wast:556-563 relies on. The runner cannot judge that
  case yet (it skips `assert_trap (module ...)` as "needs an execution tier"),
  so it is confirmed here in the layer that owns it: instantiation applies
  active segments to `MemAddrs[MemIndex]`, which for an import is the supplied
  address, not a fresh memory. `exec-module` / `aux-rundata`. }
procedure TRuntimeInstantiateTests
  .TestActiveDataOnImportedMemoryPersistsAfterTrap;
var
  MemAddr: TWasmMemAddr;
begin
  { A one-page memory supplied as import "env"."m" — the shared object the
    module below writes through. }
  MemAddr := FStore.AddMemory(MakeMemType(MakeLimits(watI32, 1)));
  SetLength(FImports.Mems, 1);
  FImports.Mems[0] := MemAddr;

  { import  0  "env"."m" (memory 1)
    data    0  active memory 0 offset 0     "ab"   (in bounds)
    data    1  active memory 0 offset 65535 "hi"   (one past the end) }
  StartModule;
  Sect(wsImport, [$01,
    $03, $65, $6E, $76, $01, $6D, $02, $00, $01]);
  Sect(wsDataCount, [$02]);
  Sect(wsData, [$02,
    $00, $41, $00, $0B, $02, $61, $62,
    $00, $41, $FF, $FF, $03, $0B, $02, $68, $69]);
  FinishAndValidate;

  Expect<string>(OutcomeOf(MSG_TRAP_MEMORY_OUT_OF_BOUNDS))
    .ToBe('trap: ' + MSG_TRAP_MEMORY_OUT_OF_BOUNDS);

  { The first segment landed in the IMPORTED memory before the second trapped,
    and it is still there: no rollback, and the target is the shared object. }
  Expect<Byte>(MemByte(MemAddr, 0)).ToBe($61);
  Expect<Byte>(MemByte(MemAddr, 1)).ToBe($62);
  { The trapping segment wrote nothing — the range check precedes the copy. }
  Expect<Byte>(MemByte(MemAddr, 65535)).ToBe($00);
end;

{ The element counterpart of the test above, mirroring linking.wast:397-410:
  an active element segment applied to an IMPORTED table persists in the
  shared table after a later, partially-out-of-bounds segment traps. }
procedure TRuntimeInstantiateTests
  .TestActiveElemOnImportedTablePersistsAfterTrap;
var
  TableAddr: TWasmTableAddr;
  Instance: TWasmModuleInstance;
  FuncRef: TWasmRef;
begin
  { A 10-entry funcref table supplied as import "env"."t". }
  TableAddr := FStore.AddTable(
    MakeTableType(MakeRefType(True, MakeAbsHeapType(wahFunc)),
      MakeLimits(watI32, 10)), WASM_REF_NULL);
  SetLength(FImports.Tables, 1);
  FImports.Tables[0] := TableAddr;

  { type    0  () -> ()
    import  0  "env"."t" (table 10 funcref)
    func    0  (type 0)
    elem    0  active table 0 offset 7 [func 0]        (in bounds)
    elem    1  active table 0 offset 9 [func 0, func 0] (index 10 is one past)
    code    0  (nop body) }
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsImport, [$01,
    $03, $65, $6E, $76, $01, $74, $01, $70, $00, $0A]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsElement, [$02,
    $00, $41, $07, $0B, $01, $00,
    $00, $41, $09, $0B, $02, $00, $00]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;

  Expect<string>(OutcomeOf(MSG_TRAP_TABLE_OUT_OF_BOUNDS))
    .ToBe('trap: ' + MSG_TRAP_TABLE_OUT_OF_BOUNDS);

  { The instance was published (step 3) before the trap, so its func handle
    is the reference the first segment stored into the imported table. }
  ExpectCount('instances', Length(FStore.Instances), 1);
  Instance := FStore.Instances[0];
  FuncRef := FStore.Funcs[Instance.FuncAddrs[0]].RefObject;

  { Index 7 was written into the SHARED imported table and persists; the
    entries the trapping segment never reached stay null. }
  Expect<Boolean>(TableGet(FStore.Tables[TableAddr], 7) = FuncRef).ToBe(True);
  Expect<Boolean>(RefIsNull(TableGet(FStore.Tables[TableAddr], 9))).ToBe(True);
end;

{ --- link errors --------------------------------------------------------- }

procedure TRuntimeInstantiateTests
  .TestMissingImportIsALinkErrorBeforeAnyMutation;
var
  Before: Integer;
begin
  { `aux-rundata`: "All failure conditions are checked before any
    observable mutation of the store takes place." The count check is
    step 1 and nothing has been allocated when it fires. }
  SupplyImportedGlobal(False, 11);
  FImports.Globals := nil;
  BuildFixtureModule;
  Before := Length(FStore.Globals);

  Expect<string>(OutcomeOf(string(MSG_LINK_UNKNOWN_IMPORT)))
    .ToBe('link: ' + string(MSG_LINK_UNKNOWN_IMPORT));

  ExpectCount('instances', Length(FStore.Instances), 0);
  ExpectCount('funcs', Length(FStore.Funcs), 0);
  ExpectCount('tables', Length(FStore.Tables), 0);
  ExpectCount('memories', FStore.MemoryCount, 0);
  ExpectCount('globals', Length(FStore.Globals), Before);
end;

procedure TRuntimeInstantiateTests
  .TestIncompatibleImportIsALinkErrorBeforeAnyMutation;
var
  Before: Integer;
begin
  { A MUTABLE global cannot satisfy an immutable import: mutability must
    match exactly, or the exporter could change a value the importer
    declared constant. Step 2, still before any mutation. }
  SupplyImportedGlobal(True, 11);
  BuildFixtureModule;
  Before := Length(FStore.Globals);

  Expect<string>(OutcomeOf(string(MSG_LINK_INCOMPATIBLE_IMPORT)))
    .ToBe('link: ' + string(MSG_LINK_INCOMPATIBLE_IMPORT));

  { L14: no store category is mutated before the link check fires — every
    space, not just the ones the fixture happens to define. }
  ExpectCount('instances', Length(FStore.Instances), 0);
  ExpectCount('funcs', Length(FStore.Funcs), 0);
  ExpectCount('tables', Length(FStore.Tables), 0);
  ExpectCount('memories', FStore.MemoryCount, 0);
  ExpectCount('globals', Length(FStore.Globals), Before);
  ExpectCount('tags', Length(FStore.Tags), 0);
  ExpectCount('elems', Length(FStore.Elems), 0);
  ExpectCount('datas', Length(FStore.Datas), 0);
end;

procedure TRuntimeInstantiateTests
  .TestUnknownImportSentinelIsALinkError;
begin
  { M6: the resolver's "no export of that name" sentinel is WASM_NO_ADDR.
    The count matches, so this reaches CheckAddr, which must report it as
    `unknown import` (EWasmLinkError) — linking.wast:387 — rather than the
    bare EWasmError the out-of-range branch raises for genuine host misuse. }
  SupplyImportedGlobal(False, 11);
  BuildFixtureModule;
  SetLength(FImports.Globals, 1);
  FImports.Globals[0] := WASM_NO_ADDR;

  Expect<string>(OutcomeOf(string(MSG_LINK_UNKNOWN_IMPORT)))
    .ToBe('link: ' + string(MSG_LINK_UNKNOWN_IMPORT));
  ExpectCount('instances', Length(FStore.Instances), 0);
end;

procedure TRuntimeInstantiateTests
  .TestRepeatedInstantiationDoesNotLeakRoots;
var
  H1, H2, H3: TWasmRootHandle;
  Before: Integer;
  I: Integer;
begin
  { M4: a scope-based root cleanup truncates to a mark, but a registration
    inside the scope can be handed a free slot BELOW the mark, which the
    truncation never reclaims — a permanent root leak. The store-side fix
    releases exactly the handles it took, restoring the root arrays.

    Seed a below-mark free slot (register two, release the first, which
    tombstones rather than pops), then instantiate a module whose element
    segment registers host roots. }
  SupplyImportedGlobal(False, 11);
  BuildFixtureModule;

  H1 := RootRegister(FStore, MakeI31Ref(1));
  H2 := RootRegister(FStore, MakeI31Ref(2));
  RootRelease(FStore, H1);
  Before := FStore.Heap.RootCount;

  for I := 1 to 4 do
    Instantiate;

  { The register/release pairing inside instantiation leaves the root count
    exactly where it started — no per-instantiation creep. }
  Expect<Integer>(FStore.Heap.RootCount).ToBe(Before);

  { And the seeded free slot is still there to be reused: the leaky
    scope code would have consumed and stranded it, so a fresh registration
    would append a NEW handle instead of returning H1. }
  H3 := RootRegister(FStore, MakeI31Ref(3));
  Expect<Boolean>(H3 = H1).ToBe(True);
  RootRelease(FStore, H3);
  RootRelease(FStore, H2);
end;

procedure TRuntimeInstantiateTests.TestStartIsRecordedAndNeedsATier;
var
  Instance: TWasmModuleInstance;
  Caught: string;
begin
  { Instantiation SUCCEEDS for a module with a start function: it is
    recorded as pending and the store is complete and inspectable. Track D
    has no tier and cannot run it. }
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsStart, [$00]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;
  Instance := Instantiate;

  Expect<Boolean>(Instance.HasPendingStart).ToBe(True);
  ExpectCount('start index', Integer(Instance.PendingStartFuncIndex), 0);

  Caught := 'no error';
  try
    FStore.RunPendingStart(Instance);
  except
    on E: EWasmTrap do
    begin
      Caught := 'trap: ' + E.Message;
    end;
    on E: EWasmLinkError do
    begin
      Caught := 'link: ' + E.Message;
    end;
    on E: EWasmError do
    begin
      Caught := E.Message;
    end;
  end;
  { Deliberately EWasmError: the module linked and no guest code faulted,
    so neither EWasmLinkError nor EWasmTrap would be true. }
  Expect<string>(Caught).ToBe(MSG_START_NEEDS_TIER);
end;

{ --- the real-toolchain corpus ------------------------------------------- }

function NativePath(const APath: string): string;
var
  Index: Integer;
begin
  Result := APath;
  for Index := 1 to Length(Result) do
    if Result[Index] = '/' then
      Result[Index] := PathDelim;
end;

{ Build one external of each declared import type, so a fixture compiled by
  a real toolchain can be instantiated without knowing what it asks for.
  Every external is constructed FROM the declared type, so it satisfies the
  matching relation by construction — the point of the corpus test is the
  sequence and the store shape, not the variance directions, which have
  their own one-per-direction cases in the store suite. }
procedure SatisfyImports(const AStore: TWasmStore; const AIr: TWasmIrModule;
  out AImports: TWasmImports);
var
  Canon: TWasmEngineTypeIds;
  TypeIds: TWasmEngineTypeIds;
  Index: Integer;
  GlobalType: TWasmGlobalType;
  Value: TWasmValue;
begin
  { Interning is idempotent, so doing it here and again inside
    InstantiateModule yields the same ids. }
  AStore.Engine.InternModule(AIr, Canon, TypeIds);

  SetLength(AImports.Funcs, AIr.FuncImportCount);
  for Index := 0 to High(AImports.Funcs) do
    AImports.Funcs[Index] := AStore.AddHostFunc(
      Canon[AIr.FuncCanonTypes[Index]], nil, nil);

  SetLength(AImports.Tables, AIr.TableImportCount);
  for Index := 0 to High(AImports.Tables) do
  begin
    if not AIr.Tables[Index].RefType.Nullable then
      raise EWasmError.Create(
        'the corpus satisfier cannot fill a non-nullable table import');
    AImports.Tables[Index] := AStore.AddTable(
      EngineTableType(AIr.Tables[Index], TypeIds), WASM_REF_NULL);
  end;

  SetLength(AImports.Mems, AIr.MemoryImportCount);
  for Index := 0 to High(AImports.Mems) do
    AImports.Mems[Index] := AStore.AddMemory(AIr.Memories[Index]);

  SetLength(AImports.Globals, AIr.GlobalImportCount);
  for Index := 0 to High(AImports.Globals) do
  begin
    GlobalType := EngineGlobalType(AIr.Globals[Index], TypeIds);
    if not TryDefaultValue(GlobalType.ValueType, Value) then
      raise EWasmError.Create(
        'the corpus satisfier cannot default a global import');
    AImports.Globals[Index] := AStore.AddGlobal(GlobalType, Value);
  end;

  SetLength(AImports.Tags, AIr.TagImportCount);
  for Index := 0 to High(AImports.Tags) do
    AImports.Tags[Index] := AStore.AddTag(Canon[AIr.Tags[Index]]);
end;

procedure TRuntimeInstantiateTests.TestFixtureCorpusInstantiates;
var
  Search: TSearchRec;
  Dir: string;
  Path: string;
  Names: array of string;
  Index: Integer;
  Slot: Integer;
  Instance: TWasmModuleInstance;
  Imports: TWasmImports;
  Kind: TWasmExternKind;
  Addr: UInt32;
  ExportIndex: Integer;
  Instantiated: Integer;
  Resolved: Integer;
begin
  { Real toolchain-compiled modules through the whole pipeline: decode,
    validate, intern, link, instantiate. The hand-assembled cases above
    each isolate one rule; this one asserts that nothing in the sequence
    falls over on input nobody in this repo wrote. }
  Names := nil;
  Dir := NativePath(VALID_DIR);
  if FindFirst(Dir + PathDelim + '*.wasm', faAnyFile, Search) = 0 then
    try
      repeat
        if ((Search.Attr and faDirectory) = 0) and
          (Search.Name <> SIMD_FIXTURE) then
        begin
          SetLength(Names, Length(Names) + 1);
          Names[High(Names)] := Dir + PathDelim + Search.Name;
        end;
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;

  Instantiated := 0;
  Resolved := 0;
  SetLength(FCorpusBytes, Length(Names));
  SetLength(FCorpusModules, Length(Names));
  SetLength(FCorpusIrs, Length(Names));

  for Index := 0 to High(Names) do
  begin
    Path := Names[Index];
    Slot := Index;
    FCorpusBytes[Slot] := LoadFileBytes(Path);
    FCorpusModules[Slot] := TWasmModule.Create;
    DecodeModule(FCorpusBytes[Slot], FCorpusModules[Slot]);
    FCorpusIrs[Slot] := ValidateModule(FCorpusModules[Slot],
      FCorpusBytes[Slot]);

    SatisfyImports(FStore, FCorpusIrs[Slot], Imports);
    Instance := InstantiateModule(FStore, FCorpusIrs[Slot],
      @FCorpusBytes[Slot][0], NativeUInt(Length(FCorpusBytes[Slot])),
      Imports);
    Inc(Instantiated);

    { Every index space is exactly as long as the IR's snapshot of it,
      imports first — the property a tier reads addresses out of. }
    ExpectCount(Path + ' funcs', Length(Instance.FuncAddrs),
      Length(FCorpusIrs[Slot].FuncCanonTypes));
    ExpectCount(Path + ' tables', Length(Instance.TableAddrs),
      Length(FCorpusIrs[Slot].Tables));
    ExpectCount(Path + ' memories', Length(Instance.MemAddrs),
      Length(FCorpusIrs[Slot].Memories));
    ExpectCount(Path + ' globals', Length(Instance.GlobalAddrs),
      Length(FCorpusIrs[Slot].Globals));
    ExpectCount(Path + ' tags', Length(Instance.TagAddrs),
      Length(FCorpusIrs[Slot].Tags));
    ExpectCount(Path + ' elems', Length(Instance.ElemAddrs),
      Length(FCorpusIrs[Slot].Elems));
    ExpectCount(Path + ' datas', Length(Instance.DataAddrs),
      Length(FCorpusIrs[Slot].Datas));
    ExpectCount(Path + ' exports', Length(Instance.ExportNames),
      Length(FCorpusIrs[Slot].ExportList));

    { And every export resolves to a real address in its own space. }
    for ExportIndex := 0 to High(Instance.ExportNames) do
      if Instance.FindExport(Instance.ExportNames[ExportIndex], Kind,
        Addr) and (Addr <> WASM_NO_ADDR) then
        Inc(Resolved);
  end;

  Expect<Boolean>(Instantiated >= MIN_INSTANTIATED_FIXTURES).ToBe(True);
  Expect<Boolean>(Resolved > 0).ToBe(True);
end;

procedure TRuntimeInstantiateTests.SetupTests;
begin
  Test('the fixture module instantiates into the expected store shape',
    TestInstantiatesTheFixtureModule);
  Test('global initialisers evaluate in order, including chains',
    TestGlobalInitialisersAndChains);
  Test('active data reaches memory through the chokepoint',
    TestDataReachesMemoryThroughTheChokepoint);
  Test('an active element segment populates the table with funcrefs',
    TestElementSegmentPopulatesTheTable);
  Test('applied segments are dropped and the buffer is released',
    TestAppliedSegmentsAreDroppedAndTheBufferIsReleased);
  Test('a passive data segment keeps borrowing the buffer',
    TestPassiveDataKeepsBorrowingTheBuffer);
  Test('a declarative element segment is dropped immediately',
    TestDeclarativeSegmentIsDroppedImmediately);

  Test('constant-expression arithmetic wraps at every boundary',
    TestWrappingArithmeticInConstantExpressions);
  Test('reference constant expressions evaluate without a heap',
    TestReferenceConstantExpressions);
  Test('struct.new in a constant expression initialises a global',
    TestStructNewInitialisesAGlobal);
  Test('array.new, array.new_fixed and array.new_default evaluate',
    TestArrayConstantExpressions);
  Test('an element segment and a struct global survive a collection',
    TestElementSegmentAndStructGlobalCoexist);

  Test('an out-of-bounds active data segment traps after mutation',
    TestActiveDataOutOfBoundsTraps);
  Test('an out-of-bounds active element segment traps',
    TestActiveElemOutOfBoundsTraps);
  Test('an active data segment on an imported memory persists after a trap',
    TestActiveDataOnImportedMemoryPersistsAfterTrap);
  Test('an active element segment on an imported table persists after a trap',
    TestActiveElemOnImportedTablePersistsAfterTrap);

  Test('a missing import is a link error before any mutation',
    TestMissingImportIsALinkErrorBeforeAnyMutation);
  Test('an incompatible import is a link error before any mutation',
    TestIncompatibleImportIsALinkErrorBeforeAnyMutation);
  Test('an unknown-import sentinel is reported as a link error',
    TestUnknownImportSentinelIsALinkError);
  Test('repeated instantiation does not leak host roots',
    TestRepeatedInstantiationDoesNotLeakRoots);
  Test('a start function is recorded and reported as needing a tier',
    TestStartIsRecordedAndNeedsATier);

  Test('every valid fixture module instantiates into a sound store',
    TestFixtureCorpusInstantiates);
end;

begin
  TestRunnerProgram.AddSuite(
    TRuntimeInstantiateTests.Create('Wasm.Runtime.Instantiate'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
