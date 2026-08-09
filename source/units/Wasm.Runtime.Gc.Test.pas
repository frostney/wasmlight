{ Unit suite for Wasm.Runtime.Gc — layout, the allocator, mark-sweep, the
  root registry and the frame walk.

  EVERYTHING HERE RUNS WITHOUT AN INTERPRETER AND WITHOUT A STORE. That is
  the property the wave plan was shaped around and the reason the
  collector takes its roots through a callback rather than reaching into a
  store: the layout table is built by hand from Wasm.Core composites, the
  object graph is built through the direct allocation API, and the frame
  chain is a hand-built TWasmGcFrame over a hand-built RefRegBits — which
  is what proves contract GC-1 against a stub before Track E exists.

  Reclamation is asserted through ObjectCount and BytesLive rather than by
  reading freed memory: a freed cell is poisoned outside PRODUCTION
  builds, and a test that read it back would be asserting the poison
  rather than the collection. The one place addresses are compared is the
  reuse case, where the point IS the address.

  Spec anchors are cited per group, read from wasm-mcp 0.2.16 at the
  pinned commit d7b37e4170d8315f2f1283aed4e8076591a9a333. }
program Wasm.Runtime.Gc.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values;

const
  { The hand-built type table every test shares. Ids are arbitrary and
    dense; nothing here needs an engine, because a layout is a pure
    function of the composite. }
  TY_PACKED = 0;      { (struct i8 i16 i32 i64 (ref null any)) }
  TY_BASE = 1;        { (struct i32) }
  TY_DERIVED = 2;     { (struct i32 i64) — the appending subtype }
  TY_NODE = 3;        { (struct (ref null any) (ref null any)) }
  TY_REF_ARRAY = 4;   { (array (mut (ref null any))) }
  TY_I8_ARRAY = 5;    { (array (mut i8)) }
  TY_I32_ARRAY = 6;   { (array (mut i32)) }
  TY_TAG = 7;         { (func (param i32 (ref null any))) — an exn's tag }
  TY_NO_DEFAULT = 8;  { (struct (ref any)) — non-nullable, no default }
  TY_VEC_STRUCT = 9;  { (struct (mut v128)) — a valid TYPE, staged storage }

var
  { The host-box release hook's evidence. A file-level variable because
    TWasmHostRelease is a plain procedure — a closure would be managed
    state on a path the collector calls. }
  GReleaseCount: Integer;
  GReleasedPayload: NativeUInt;

procedure CountRelease(const APayload: NativeUInt);
begin
  Inc(GReleaseCount);
  GReleasedPayload := APayload;
end;

type
  TRuntimeGcTests = class(TTestSuite)
  private
    FTypes: TWasmGcTypes;
    FHeap: TWasmGcHeap;

    procedure DefineTypes;
    function AnyRef: TWasmValueType;
    function NonNullAnyRef: TWasmValueType;
    function StructOf(const AStorages: array of TWasmStorageType;
      const AMutable: Boolean): TWasmCompType;
    function ArrayOf(const AStorage: TWasmStorageType): TWasmCompType;

    function Node(const AFirst, ASecond: TWasmRef): TWasmRef;
    procedure ExpectCount(const AWhat: string;
      const AActual, AExpected: Integer);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestFieldOffsetsFollowDeclarationOrderAndPacking;
    procedure TestASubtypePrefixMatchesItsSupertypeExactly;
    procedure TestEveryObjectIsEightByteAligned;
    procedure TestHeaderCarriesKindAndEngineTypeId;
    procedure TestAbstractKindsAreThreeDisjointHierarchies;

    procedure TestStructFieldsRoundTrip;
    procedure TestPackedFieldsExtendAndTruncate;
    procedure TestArrayElementsRoundTrip;
    procedure TestPackedArrayElementsExtend;
    procedure TestNullAccessTraps;
    procedure TestArrayIndexOutOfBoundsTraps;
    procedure TestDefaultsAreCheckedNotInvented;

    procedure TestArrayCopyMovesForwardAndBackwardWithoutClobbering;
    procedure TestArrayCopyBoundsTrapOnEitherSide;
    procedure TestArrayCopyReferenceElementsSurviveThroughTheDestination;
    procedure TestArrayInitFromDataCopiesBytesAndTrapsBothBounds;
    procedure TestArrayInitFromElemCopiesRefsAndTrapsBothBounds;

    procedure TestCollectingWithNothingLiveReclaimsEverything;
    procedure TestReclaimedBytesAreReused;
    procedure TestAHostRootKeepsAnObjectAliveAndReleasingItDoesNot;
    procedure TestARootScopeReleasesInOneStep;
    procedure TestTransitiveGraphSurvivesThroughOneRoot;
    procedure TestUnreachableCyclesAreCollected;
    procedure TestFrameWalkKeepsExactlyTheReferencedRegisters;
    procedure TestStoreRootCallbackIsConsulted;
    procedure TestI31AndNullAreNeverAllocatedOrTraced;

    procedure TestExceptionArgumentsAreTracedThroughTheTagType;
    procedure TestHostBoxReleaseRunsOnSweep;

    procedure TestAllocationAtTheThresholdCollects;
    procedure TestNoCollectionBelowTheThreshold;
    procedure TestStatisticsAccountForEveryByte;

    procedure TestAnAbortedCollectionLeavesNoStaleMarks;
    procedure TestResetFramesDropsStaleFramesAfterUnwind;
    procedure TestAReleaseHookThatAllocatesIsCaught;
    procedure TestAllocationFailureCollectsThenRetries;
    procedure TestVectorStorageIsStagedNotAnInternalBug;
    procedure TestExternalizeIsInvisibleToAbstractKindStaged;
  end;

{ --- fixture ------------------------------------------------------------- }

function TRuntimeGcTests.AnyRef: TWasmValueType;
begin
  Result := MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahAny)));
end;

function TRuntimeGcTests.NonNullAnyRef: TWasmValueType;
begin
  Result := MakeRefValueType(MakeRefType(False, MakeAbsHeapType(wahAny)));
end;

function TRuntimeGcTests.StructOf(
  const AStorages: array of TWasmStorageType;
  const AMutable: Boolean): TWasmCompType;
var
  Struct: TWasmStructType;
  Index: Integer;
begin
  SetLength(Struct.Fields, Length(AStorages));
  for Index := 0 to High(AStorages) do
    Struct.Fields[Index] := MakeFieldType(AMutable, AStorages[Index]);
  Result := MakeStructCompType(Struct);
end;

function TRuntimeGcTests.ArrayOf(
  const AStorage: TWasmStorageType): TWasmCompType;
var
  Arr: TWasmArrayType;
begin
  Arr.Elem := MakeFieldType(True, AStorage);
  Result := MakeArrayCompType(Arr);
end;

procedure TRuntimeGcTests.DefineTypes;
var
  Func: TWasmFuncType;
begin
  FTypes.Define(TY_PACKED, StructOf([
    MakePackedStorageType(wpkI8),
    MakePackedStorageType(wpkI16),
    MakeValueStorageType(MakeNumValueType(wntI32)),
    MakeValueStorageType(MakeNumValueType(wntI64)),
    MakeValueStorageType(AnyRef)], True));

  { The load-bearing pair: a struct subtype extends its supertype by
    APPENDING fields (`Structtype_sub`). }
  FTypes.Define(TY_BASE, StructOf([
    MakeValueStorageType(MakeNumValueType(wntI32))], False));
  FTypes.Define(TY_DERIVED, StructOf([
    MakeValueStorageType(MakeNumValueType(wntI32)),
    MakeValueStorageType(MakeNumValueType(wntI64))], False));

  FTypes.Define(TY_NODE, StructOf([
    MakeValueStorageType(AnyRef),
    MakeValueStorageType(AnyRef)], True));

  FTypes.Define(TY_REF_ARRAY, ArrayOf(MakeValueStorageType(AnyRef)));
  FTypes.Define(TY_I8_ARRAY, ArrayOf(MakePackedStorageType(wpkI8)));
  FTypes.Define(TY_I32_ARRAY,
    ArrayOf(MakeValueStorageType(MakeNumValueType(wntI32))));

  SetLength(Func.Params, 2);
  Func.Params[0] := MakeNumValueType(wntI32);
  Func.Params[1] := AnyRef;
  Func.Results := nil;
  FTypes.Define(TY_TAG, MakeFuncCompType(Func));

  { "For other references, no default value is defined" (`aux-default`) —
    which is exactly what makes struct.new_default's validation rule
    load-bearing. }
  FTypes.Define(TY_NO_DEFAULT, StructOf([
    MakeValueStorageType(NonNullAnyRef)], False));

  { A v128 field is a valid storage type — the validator admits vector
    value types; only the $FD instruction space is staged (B15). The layout
    computes (width 16), but reading or writing the field is Track G. }
  FTypes.Define(TY_VEC_STRUCT, StructOf([
    MakeValueStorageType(MakeVecValueType)], True));
end;

procedure TRuntimeGcTests.BeforeEach;
begin
  FTypes := TWasmGcTypes.Create;
  DefineTypes;
  FHeap := TWasmGcHeap.Create(FTypes);
  GReleaseCount := 0;
  GReleasedPayload := 0;
end;

procedure TRuntimeGcTests.AfterEach;
begin
  { The heap first: its teardown reads object headers and their layouts. }
  FreeAndNil(FHeap);
  FreeAndNil(FTypes);
end;

{ A two-field node, built and linked in one step so no partially-linked
  object is ever exposed to an allocation. }
function TRuntimeGcTests.Node(const AFirst, ASecond: TWasmRef): TWasmRef;
begin
  Result := FHeap.AllocStruct(TY_NODE);
  FHeap.StructSet(Result, 0, MakeValueRef(AFirst));
  FHeap.StructSet(Result, 1, MakeValueRef(ASecond));
end;

procedure TRuntimeGcTests.ExpectCount(const AWhat: string;
  const AActual, AExpected: Integer);
begin
  Expect<string>(Format('%s=%d', [AWhat, AActual]))
    .ToBe(Format('%s=%d', [AWhat, AExpected]));
end;


{ --- layout -------------------------------------------------------------- }

procedure TRuntimeGcTests.TestFieldOffsetsFollowDeclarationOrderAndPacking;
var
  Layout: PWasmGcLayout;
begin
  { Declaration order, each field at the next offset that is a multiple of
    its own width, starting after the 8-byte header:

      i8   at  8   (width 1)
      i16  at 10   (width 2, aligned up from 9)
      i32  at 12   (width 4)
      i64  at 16   (width 8)
      ref  at 24

    Size-sorting would pack this tighter and would silently break struct
    subtyping, which is why the order is asserted and not just the size. }
  Layout := FTypes.Layout(TY_PACKED);
  ExpectCount('i8 offset', Integer(Layout^.Fields[0].Offset), 8);
  ExpectCount('i16 offset', Integer(Layout^.Fields[1].Offset), 10);
  ExpectCount('i32 offset', Integer(Layout^.Fields[2].Offset), 12);
  ExpectCount('i64 offset', Integer(Layout^.Fields[3].Offset), 16);
  ExpectCount('ref offset', Integer(Layout^.Fields[4].Offset), 24);

  ExpectCount('i8 width', Integer(Layout^.Fields[0].Width), 1);
  ExpectCount('i16 width', Integer(Layout^.Fields[1].Width), 2);

  { Exactly one reference field, and the trace loop reads its offset from
    here rather than from any per-object map. }
  ExpectCount('ref fields', Length(Layout^.RefFieldOffsets), 1);
  ExpectCount('traced offset', Integer(Layout^.RefFieldOffsets[0]), 24);

  { Rounded to 8 so the next object keeps bit 0 of its pointer clear. }
  Expect<Boolean>((Layout^.Size mod WASM_GC_ALIGNMENT) = 0).ToBe(True);
end;

procedure TRuntimeGcTests.TestASubtypePrefixMatchesItsSupertypeExactly;
var
  Base: PWasmGcLayout;
  Derived: PWasmGcLayout;
begin
  { THE invariant declaration-order layout exists to preserve: a struct
    subtype extends its supertype by appending, so struct.get of field 0
    through a supertype-typed reference must read the same bytes in both.
    A size-sorted layout passes every other test in this file and fails
    this one. }
  Base := FTypes.Layout(TY_BASE);
  Derived := FTypes.Layout(TY_DERIVED);
  ExpectCount('base fields', Length(Base^.Fields), 1);
  ExpectCount('derived fields', Length(Derived^.Fields), 2);
  ExpectCount('shared offset', Integer(Derived^.Fields[0].Offset),
    Integer(Base^.Fields[0].Offset));
  ExpectCount('shared width', Integer(Derived^.Fields[0].Width),
    Integer(Base^.Fields[0].Width));
end;

procedure TRuntimeGcTests.TestEveryObjectIsEightByteAligned;
var
  Index: Integer;
  Ref: TWasmRef;
  Misaligned: Integer;
begin
  { 8-byte alignment is what reserves bit 0 of an object pointer for the
    unboxed-i31 tag. An object at an odd address would read back as an
    i31 and never be traced — so this is an allocator invariant, checked
    across every size class rather than on one object. }
  Misaligned := 0;
  for Index := 0 to 63 do
  begin
    Ref := FHeap.AllocArray(TY_I32_ARRAY, UInt32(Index) * 7);
    if (NativeUInt(RefToPointer(Ref)) and (WASM_GC_ALIGNMENT - 1)) <> 0 then
      Inc(Misaligned);
    if not RefIsObject(Ref) then
      Inc(Misaligned);
  end;
  ExpectCount('misaligned', Misaligned, 0);
end;

procedure TRuntimeGcTests.TestHeaderCarriesKindAndEngineTypeId;
var
  Struct: TWasmRef;
  Arr: TWasmRef;
  Handle: TWasmRef;
begin
  Struct := FHeap.AllocStruct(TY_NODE);
  Arr := FHeap.AllocArray(TY_I32_ARRAY, 3);
  Handle := FHeap.AllocFuncRef(11, TY_TAG);

  Expect<Boolean>(GcRefKind(Struct) = wokStruct).ToBe(True);
  Expect<Boolean>(GcRefKind(Arr) = wokArray).ToBe(True);
  Expect<Boolean>(GcRefKind(Handle) = wokFuncRef).ToBe(True);

  { The id lives in the header's HIGH half, which is what makes the
    runtime cast one shift and one array index. }
  ExpectCount('struct type', Integer(GcRefTypeId(Struct)), TY_NODE);
  ExpectCount('array type', Integer(GcRefTypeId(Arr)), TY_I32_ARRAY);
  ExpectCount('funcaddr', Integer(GcFuncRefAddr(Handle)), 11);

  { Nothing is marked outside a collection. }
  Expect<Boolean>(GcRefIsMarked(Struct)).ToBe(False);
end;

procedure TRuntimeGcTests.TestAbstractKindsAreThreeDisjointHierarchies;
begin
  { The map that keeps func, aggregate and extern apart — plus exn. A
    funcref must never answer true for anyref, and this is where that
    falls out. }
  Expect<Boolean>(GcAbsKindOf(wokStruct) = wahStruct).ToBe(True);
  Expect<Boolean>(GcAbsKindOf(wokArray) = wahArray).ToBe(True);
  Expect<Boolean>(GcAbsKindOf(wokFuncRef) = wahFunc).ToBe(True);
  Expect<Boolean>(GcAbsKindOf(wokHostBox) = wahExtern).ToBe(True);
  Expect<Boolean>(GcAbsKindOf(wokExn) = wahExn).ToBe(True);
end;

{ --- field access -------------------------------------------------------- }

procedure TRuntimeGcTests.TestStructFieldsRoundTrip;
var
  Obj: TWasmRef;
  Target: TWasmRef;
begin
  Target := FHeap.AllocStruct(TY_BASE);
  Obj := FHeap.AllocStruct(TY_PACKED);

  FHeap.StructSet(Obj, 2, MakeValueI32(-7));
  FHeap.StructSet(Obj, 3, MakeValueI64(Int64($1122334455667788)));
  FHeap.StructSet(Obj, 4, MakeValueRef(Target));

  Expect<Int32>(FHeap.StructGet(Obj, 2).I32).ToBe(-7);
  Expect<Int64>(FHeap.StructGet(Obj, 3).I64)
    .ToBe(Int64($1122334455667788));
  Expect<Boolean>(FHeap.StructGet(Obj, 4).Ref = Target).ToBe(True);
  ExpectCount('fields', Integer(FHeap.StructFieldCount(Obj)), 5);

  { A fresh object reads as aux-default everywhere it was not written:
    zero for a number, null for a nullable reference. }
  Expect<Int32>(FHeap.StructGet(FHeap.AllocStruct(TY_PACKED), 2).I32)
    .ToBe(0);
end;

procedure TRuntimeGcTests.TestPackedFieldsExtendAndTruncate;
var
  Obj: TWasmRef;
  Caught: string;
begin
  { `aux-unpackfield` sign- or zero-extends from the packed width and
    `aux-packfield` truncates to it. Both directions at both widths, with
    the bit patterns spelled here rather than derived. }
  Obj := FHeap.AllocStruct(TY_PACKED);

  FHeap.StructSet(Obj, 0, MakeValueI32(Int32($FF)));
  Expect<Int32>(FHeap.StructGetSigned(Obj, 0)).ToBe(-1);
  Expect<UInt32>(FHeap.StructGetUnsigned(Obj, 0)).ToBe(UInt32(255));

  FHeap.StructSet(Obj, 1, MakeValueI32(Int32($FFFF)));
  Expect<Int32>(FHeap.StructGetSigned(Obj, 1)).ToBe(-1);
  Expect<UInt32>(FHeap.StructGetUnsigned(Obj, 1)).ToBe(UInt32(65535));

  { The high bits of a wider value are DISCARDED, not rejected: a store
    into an i8 field keeps eight bits. }
  FHeap.StructSet(Obj, 0, MakeValueI32(Int32($01FE)));
  Expect<UInt32>(FHeap.StructGetUnsigned(Obj, 0)).ToBe(UInt32($FE));
  Expect<Int32>(FHeap.StructGetSigned(Obj, 0)).ToBe(-2);

  { 0x7F is the largest i8 that is not negative — the boundary either
    side of which sign extension changes the answer. }
  FHeap.StructSet(Obj, 0, MakeValueI32(127));
  Expect<Int32>(FHeap.StructGetSigned(Obj, 0)).ToBe(127);
  FHeap.StructSet(Obj, 0, MakeValueI32(128));
  Expect<Int32>(FHeap.StructGetSigned(Obj, 0)).ToBe(-128);

  { And a packed field is NOT readable with the unpacked accessor — the
    spec has no struct.get for one, and the validator has already made
    this unreachable, so it is an internal invariant violation rather than
    a trap. }
  Caught := 'accepted';
  try
    FHeap.StructGet(Obj, 0);
  except
    on E: EWasmTrap do
    begin
      Caught := 'trap: ' + E.Message;
    end;
    on E: EWasmError do
    begin
      Caught := 'error';
    end;
  end;
  Expect<string>(Caught).ToBe('error');
end;

procedure TRuntimeGcTests.TestArrayElementsRoundTrip;
var
  Arr: TWasmRef;
  Refs: TWasmRef;
  Target: TWasmRef;
begin
  Arr := FHeap.AllocArray(TY_I32_ARRAY, 4);
  ExpectCount('length', Integer(FHeap.ArrayLength(Arr)), 4);
  FHeap.ArraySet(Arr, 0, MakeValueI32(10));
  FHeap.ArraySet(Arr, 3, MakeValueI32(-10));
  Expect<Int32>(FHeap.ArrayGet(Arr, 0).I32).ToBe(10);
  Expect<Int32>(FHeap.ArrayGet(Arr, 1).I32).ToBe(0);
  Expect<Int32>(FHeap.ArrayGet(Arr, 3).I32).ToBe(-10);

  FHeap.ArrayFill(Arr, 0, FHeap.ArrayLength(Arr), MakeValueI32(5));
  Expect<Int32>(FHeap.ArrayGet(Arr, 1).I32).ToBe(5);

  { array.fill takes an offset and a count, not the whole array (L20): a
    range fill touches exactly [offset, offset+count) and leaves the rest. }
  FHeap.ArrayFill(Arr, 1, 2, MakeValueI32(8));
  Expect<Int32>(FHeap.ArrayGet(Arr, 0).I32).ToBe(5);
  Expect<Int32>(FHeap.ArrayGet(Arr, 1).I32).ToBe(8);
  Expect<Int32>(FHeap.ArrayGet(Arr, 2).I32).ToBe(8);
  Expect<Int32>(FHeap.ArrayGet(Arr, 3).I32).ToBe(5);

  Target := FHeap.AllocStruct(TY_BASE);
  Refs := FHeap.AllocArray(TY_REF_ARRAY, 2);
  FHeap.ArraySet(Refs, 1, MakeValueRef(Target));
  Expect<Boolean>(FHeap.ArrayGet(Refs, 1).Ref = Target).ToBe(True);
  Expect<Boolean>(RefIsNull(FHeap.ArrayGet(Refs, 0).Ref)).ToBe(True);

  { A zero-length array is legal and has no elements to read. }
  ExpectCount('empty',
    Integer(FHeap.ArrayLength(FHeap.AllocArray(TY_I32_ARRAY, 0))), 0);
end;

procedure TRuntimeGcTests.TestPackedArrayElementsExtend;
var
  Arr: TWasmRef;
begin
  { An array element packs exactly as a struct field does, and the
    elements really are one byte apart — writing one must not disturb its
    neighbour. }
  Arr := FHeap.AllocArray(TY_I8_ARRAY, 4);
  FHeap.ArraySet(Arr, 0, MakeValueI32(Int32($FF)));
  FHeap.ArraySet(Arr, 1, MakeValueI32(1));
  Expect<Int32>(FHeap.ArrayGetSigned(Arr, 0)).ToBe(-1);
  Expect<UInt32>(FHeap.ArrayGetUnsigned(Arr, 0)).ToBe(UInt32(255));
  Expect<Int32>(FHeap.ArrayGetSigned(Arr, 1)).ToBe(1);
  Expect<Int32>(FHeap.ArrayGetSigned(Arr, 2)).ToBe(0);
end;

procedure TRuntimeGcTests.TestNullAccessTraps;
var
  Arr: TWasmRef;
  Caught: string;
begin
  { O-5: the null message is TYPE-SPECIFIC now, not the bare
    'null reference'. struct.get/get_s/get_u/set/fieldcount/setdefaults on a
    null all spell 'null structure reference' (corpus struct.wast:155-156);
    the bare message is reserved for ref.as_non_null / ref.cast-to-non-null,
    which the interpreter/Store raise, not these accessors. }
  Caught := 'no trap';
  try
    FHeap.StructGet(WASM_REF_NULL, 0);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_STRUCT_REFERENCE);

  Caught := 'no trap';
  try
    FHeap.StructSet(WASM_REF_NULL, 0, MakeValueI32(1));
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_STRUCT_REFERENCE);

  Caught := 'no trap';
  try
    FHeap.StructFieldCount(WASM_REF_NULL);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_STRUCT_REFERENCE);

  Caught := 'no trap';
  try
    FHeap.StructSetDefaults(WASM_REF_NULL);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_STRUCT_REFERENCE);

  { array.get/get_s/get_u/set/len/fill/copy/init_* on a null all spell
    'null array reference' (corpus array.wast:342-343 et al.). }
  Caught := 'no trap';
  try
    FHeap.ArrayLength(WASM_REF_NULL);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);

  Caught := 'no trap';
  try
    FHeap.ArrayGet(WASM_REF_NULL, 0);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);

  Caught := 'no trap';
  try
    FHeap.ArraySet(WASM_REF_NULL, 0, MakeValueI32(1));
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);

  Caught := 'no trap';
  try
    FHeap.ArrayFill(WASM_REF_NULL, 0, 0, MakeValueI32(1));
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);

  { And a live array is unaffected by any of that. }
  Arr := FHeap.AllocArray(TY_I32_ARRAY, 1);
  ExpectCount('length', Integer(FHeap.ArrayLength(Arr)), 1);
end;

procedure TRuntimeGcTests.TestArrayIndexOutOfBoundsTraps;
var
  Arr: TWasmRef;
  Caught: string;
begin
  { The classic off-by-one triple. UNCONFIRMED message: array.get reports
    can_trap:false at the pin, which is a gap in the served data for the
    whole 3.0 GC family rather than the truth — Track C's assert_trap
    corpus settles it, in one place. }
  Arr := FHeap.AllocArray(TY_I32_ARRAY, 2);
  FHeap.ArraySet(Arr, 1, MakeValueI32(9));
  Expect<Int32>(FHeap.ArrayGet(Arr, 1).I32).ToBe(9);

  Caught := 'no trap';
  try
    FHeap.ArrayGet(Arr, 2);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_ARRAY_OUT_OF_BOUNDS);

  { A huge index must trap rather than wrap into range. }
  Caught := 'no trap';
  try
    FHeap.ArraySet(Arr, High(UInt32), MakeValueI32(0));
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_ARRAY_OUT_OF_BOUNDS);
end;

procedure TRuntimeGcTests.TestDefaultsAreCheckedNotInvented;
var
  Obj: TWasmRef;
  Caught: string;
begin
  { aux-default gives zero to a number and null to a NULLABLE reference,
    and nothing at all to a non-nullable one. The validator has already
    rejected struct.new_default on the latter, so reaching it here is an
    internal invariant violation rather than a link error. }
  Obj := FHeap.AllocStruct(TY_NODE);
  FHeap.StructSetDefaults(Obj);
  Expect<Boolean>(RefIsNull(FHeap.StructGet(Obj, 0).Ref)).ToBe(True);

  Obj := FHeap.AllocStruct(TY_NO_DEFAULT);
  Caught := 'accepted';
  try
    FHeap.StructSetDefaults(Obj);
  except
    on E: EWasmTrap do
    begin
      Caught := 'trap';
    end;
    on E: EWasmError do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught)
    .ToBe(Format(MSG_GC_STRUCT_FIELD_NO_DEFAULT, [0]));
end;

{ --- bulk array ops (O-6/O-8) -------------------------------------------- }

procedure TRuntimeGcTests.
  TestArrayCopyMovesForwardAndBackwardWithoutClobbering;
var
  Arr: TWasmRef;
  Other: TWasmRef;
  Index: Integer;
begin
  { exec-array.copy, memmove semantics. Overlap within one array is the
    case a plain forward loop gets wrong; the two directions below fail
    differently if the direction choice is dropped. }

  { Backward case: destIdx > srcIdx. arr = [0..5]; copy 3 from 0 to 2.
    Correct memmove => [0,1,0,1,2,5]; a forward loop clobbers => the 5th
    element reads a value already overwritten. }
  Arr := FHeap.AllocArray(TY_I32_ARRAY, 6);
  for Index := 0 to 5 do
    FHeap.ArraySet(Arr, UInt32(Index), MakeValueI32(Index));
  FHeap.ArrayCopy(Arr, 2, Arr, 0, 3);
  Expect<Int32>(FHeap.ArrayGet(Arr, 0).I32).ToBe(0);
  Expect<Int32>(FHeap.ArrayGet(Arr, 1).I32).ToBe(1);
  Expect<Int32>(FHeap.ArrayGet(Arr, 2).I32).ToBe(0);
  Expect<Int32>(FHeap.ArrayGet(Arr, 3).I32).ToBe(1);
  Expect<Int32>(FHeap.ArrayGet(Arr, 4).I32).ToBe(2);
  Expect<Int32>(FHeap.ArrayGet(Arr, 5).I32).ToBe(5);

  { Forward case: destIdx < srcIdx. arr = [0..5]; copy 3 from 2 to 0.
    Correct memmove => [2,3,4,3,4,5]. }
  Arr := FHeap.AllocArray(TY_I32_ARRAY, 6);
  for Index := 0 to 5 do
    FHeap.ArraySet(Arr, UInt32(Index), MakeValueI32(Index));
  FHeap.ArrayCopy(Arr, 0, Arr, 2, 3);
  Expect<Int32>(FHeap.ArrayGet(Arr, 0).I32).ToBe(2);
  Expect<Int32>(FHeap.ArrayGet(Arr, 1).I32).ToBe(3);
  Expect<Int32>(FHeap.ArrayGet(Arr, 2).I32).ToBe(4);
  Expect<Int32>(FHeap.ArrayGet(Arr, 3).I32).ToBe(3);
  Expect<Int32>(FHeap.ArrayGet(Arr, 4).I32).ToBe(4);
  Expect<Int32>(FHeap.ArrayGet(Arr, 5).I32).ToBe(5);

  { Between two distinct arrays: no overlap, a straight copy. }
  Arr := FHeap.AllocArray(TY_I32_ARRAY, 3);
  Other := FHeap.AllocArray(TY_I32_ARRAY, 3);
  FHeap.ArraySet(Other, 0, MakeValueI32(7));
  FHeap.ArraySet(Other, 1, MakeValueI32(8));
  FHeap.ArraySet(Other, 2, MakeValueI32(9));
  FHeap.ArrayCopy(Arr, 0, Other, 0, 3);
  Expect<Int32>(FHeap.ArrayGet(Arr, 0).I32).ToBe(7);
  Expect<Int32>(FHeap.ArrayGet(Arr, 2).I32).ToBe(9);

  { A zero count at exactly the length is in bounds and copies nothing. }
  FHeap.ArrayCopy(Arr, 3, Other, 3, 0);
  Expect<Int32>(FHeap.ArrayGet(Arr, 0).I32).ToBe(7);
end;

procedure TRuntimeGcTests.TestArrayCopyBoundsTrapOnEitherSide;
var
  Dest: TWasmRef;
  Src: TWasmRef;
  Caught: string;
begin
  { Both sides trap 'out of bounds array access' (corpus
    array_copy.wast:101-106). A count of zero with an index past the end
    still traps, and a null on either side traps 'null array reference'. }
  Dest := FHeap.AllocArray(TY_I32_ARRAY, 4);
  Src := FHeap.AllocArray(TY_I32_ARRAY, 4);

  Caught := 'no trap';
  try
    FHeap.ArrayCopy(Dest, 3, Src, 0, 2);   { dest 3+2 > 4 }
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_ARRAY_OUT_OF_BOUNDS);

  Caught := 'no trap';
  try
    FHeap.ArrayCopy(Dest, 0, Src, 3, 2);   { src 3+2 > 4 }
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_ARRAY_OUT_OF_BOUNDS);

  Caught := 'no trap';
  try
    FHeap.ArrayCopy(WASM_REF_NULL, 0, Src, 0, 1);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);

  Caught := 'no trap';
  try
    FHeap.ArrayCopy(Dest, 0, WASM_REF_NULL, 0, 1);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);
end;

procedure TRuntimeGcTests.
  TestArrayCopyReferenceElementsSurviveThroughTheDestination;
var
  Dest: TWasmRef;
  Src: TWasmRef;
  Target: TWasmRef;
  DestRoot: TWasmRootHandle;
begin
  { The reference-element path: array.copy stores refs through the
    barriered WriteField, so a copied reference is a real edge — the
    referent must survive a collection when only the DESTINATION array is
    rooted and the source is dropped. (The v1 barrier is an empty inline
    no-op; tracing is driven by the layout regardless, so this proves the
    ref STORE is correct, which is what the barrier site guards.) }
  Target := FHeap.AllocStruct(TY_BASE);
  FHeap.StructSet(Target, 0, MakeValueI32(1234));

  Src := FHeap.AllocArray(TY_REF_ARRAY, 2);
  FHeap.ArraySet(Src, 1, MakeValueRef(Target));

  Dest := FHeap.AllocArray(TY_REF_ARRAY, 2);
  FHeap.ArrayCopy(Dest, 0, Src, 0, 2);
  Expect<Boolean>(FHeap.ArrayGet(Dest, 1).Ref = Target).ToBe(True);
  Expect<Boolean>(RefIsNull(FHeap.ArrayGet(Dest, 0).Ref)).ToBe(True);

  { Root only the destination; Src and Target are otherwise unreachable. }
  DestRoot := FHeap.RootRegister(Dest);
  FHeap.Collect;

  { Dest survived (it is a root); Target survived THROUGH the copied
    reference; Src was collected. }
  Expect<Boolean>(FHeap.ArrayGet(FHeap.RootGet(DestRoot), 1).Ref = Target)
    .ToBe(True);
  Expect<Int32>(FHeap.StructGet(Target, 0).I32).ToBe(1234);
  FHeap.RootRelease(DestRoot);
end;

procedure TRuntimeGcTests.
  TestArrayInitFromDataCopiesBytesAndTrapsBothBounds;
var
  Arr: TWasmRef;
  PackedArr: TWasmRef;
  Bytes: array[0..11] of Byte;
  Index: Integer;
  Caught: string;
begin
  { exec-array.init_data. A width-sized little-endian copy from a data
    span into a numeric/packed-element array. Three i32s little-endian:
    1, 2, 0x04030201. }
  for Index := 0 to 11 do
    Bytes[Index] := 0;
  Bytes[0] := 1;
  Bytes[4] := 2;
  Bytes[8] := 1; Bytes[9] := 2; Bytes[10] := 3; Bytes[11] := 4;

  Arr := FHeap.AllocArray(TY_I32_ARRAY, 4);
  FHeap.ArrayInitFromData(Arr, 1, @Bytes[0], Length(Bytes), 0, 3);
  Expect<Int32>(FHeap.ArrayGet(Arr, 0).I32).ToBe(0);      { untouched }
  Expect<Int32>(FHeap.ArrayGet(Arr, 1).I32).ToBe(1);
  Expect<Int32>(FHeap.ArrayGet(Arr, 2).I32).ToBe(2);
  Expect<Int32>(FHeap.ArrayGet(Arr, 3).I32)
    .ToBe(Int32($04030201));

  { Packed element width honoured: an i8 array reads one byte per element,
    starting at a non-zero byte offset. }
  PackedArr := FHeap.AllocArray(TY_I8_ARRAY, 4);
  FHeap.ArrayInitFromData(PackedArr, 0, @Bytes[8], 4, 1, 3);
  Expect<UInt32>(FHeap.ArrayGetUnsigned(PackedArr, 0)).ToBe(UInt32(2));
  Expect<UInt32>(FHeap.ArrayGetUnsigned(PackedArr, 1)).ToBe(UInt32(3));
  Expect<UInt32>(FHeap.ArrayGetUnsigned(PackedArr, 2)).ToBe(UInt32(4));

  { Dest bound trap: array side is 'out of bounds array access'. }
  Caught := 'no trap';
  try
    FHeap.ArrayInitFromData(Arr, 3, @Bytes[0], Length(Bytes), 0, 2);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_ARRAY_OUT_OF_BOUNDS);

  { Source byte bound trap: the data side is 'out of bounds memory access'
    (corpus array_init_data.wast:72). 3 i32s = 12 bytes; offset 4 leaves
    only 8. }
  Caught := 'no trap';
  try
    FHeap.ArrayInitFromData(Arr, 0, @Bytes[0], Length(Bytes), 4, 3);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);

  { A null destination is an array null. }
  Caught := 'no trap';
  try
    FHeap.ArrayInitFromData(WASM_REF_NULL, 0, @Bytes[0], Length(Bytes), 0, 1);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);
end;

procedure TRuntimeGcTests.
  TestArrayInitFromElemCopiesRefsAndTrapsBothBounds;
var
  Dest: TWasmRef;
  A0: TWasmRef;
  A1: TWasmRef;
  Src: array[0..2] of TWasmRef;
  Caught: string;
  Root: TWasmRootHandle;
begin
  { exec-array.init_elem. Copy references from an element segment's Refs
    into a reference-element array, barriered. }
  A0 := FHeap.AllocStruct(TY_BASE);
  A1 := FHeap.AllocStruct(TY_BASE);
  FHeap.StructSet(A0, 0, MakeValueI32(100));
  FHeap.StructSet(A1, 0, MakeValueI32(200));
  Src[0] := A0;
  Src[1] := A1;
  Src[2] := WASM_REF_NULL;

  Dest := FHeap.AllocArray(TY_REF_ARRAY, 4);
  { Copy 2 refs from source element 1 into dest element 2. }
  FHeap.ArrayInitFromElem(Dest, 2, Src, 1, 2);
  Expect<Boolean>(FHeap.ArrayGet(Dest, 2).Ref = A1).ToBe(True);
  Expect<Boolean>(RefIsNull(FHeap.ArrayGet(Dest, 3).Ref)).ToBe(True);
  Expect<Boolean>(RefIsNull(FHeap.ArrayGet(Dest, 0).Ref)).ToBe(True);

  { The stored reference is a real edge: root the dest, drop the source,
    collect — A1 survives through the array. }
  Root := FHeap.RootRegister(Dest);
  Src[0] := WASM_REF_NULL;
  Src[1] := WASM_REF_NULL;
  FHeap.Collect;
  Expect<Int32>(FHeap.StructGet(FHeap.ArrayGet(Dest, 2).Ref, 0).I32)
    .ToBe(200);
  FHeap.RootRelease(Root);

  { Dest bound trap: 'out of bounds array access'. }
  Caught := 'no trap';
  try
    FHeap.ArrayInitFromElem(Dest, 3, Src, 0, 2);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_ARRAY_OUT_OF_BOUNDS);

  { Source bound trap: the element side is 'out of bounds table access'
    (corpus array_init_elem.wast:89). Source has 3 entries. }
  Caught := 'no trap';
  try
    FHeap.ArrayInitFromElem(Dest, 0, Src, 2, 2);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_TABLE_OUT_OF_BOUNDS);

  { A null destination is an array null. }
  Caught := 'no trap';
  try
    FHeap.ArrayInitFromElem(WASM_REF_NULL, 0, Src, 0, 1);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_NULL_ARRAY_REFERENCE);
end;

{ --- collection ---------------------------------------------------------- }

procedure TRuntimeGcTests.TestCollectingWithNothingLiveReclaimsEverything;
var
  Index: Integer;
begin
  for Index := 0 to 9 do
    FHeap.AllocStruct(TY_NODE);
  ExpectCount('objects before', Integer(FHeap.ObjectCount), 10);
  Expect<Boolean>(FHeap.BytesLive > 0).ToBe(True);

  FHeap.Collect;

  ExpectCount('objects after', Integer(FHeap.ObjectCount), 0);
  ExpectCount('live bytes after', Integer(FHeap.BytesLive), 0);
  ExpectCount('collections', Integer(FHeap.CollectionCount), 1);
  Expect<Boolean>(FHeap.BytesReclaimed > 0).ToBe(True);

  { Collecting an empty heap is a no-op, not an error. }
  FHeap.Collect;
  ExpectCount('objects still', Integer(FHeap.ObjectCount), 0);
end;

procedure TRuntimeGcTests.TestReclaimedBytesAreReused;
var
  First: TWasmRef;
  Second: TWasmRef;
  Reserved: UInt64;
begin
  { Reclaimed memory has to come BACK, or a mark-sweep collector is just a
    slow leak. The address is the assertion here because it is the thing
    that would differ if the sweep dropped the cell instead of relisting
    it. }
  First := FHeap.AllocStruct(TY_NODE);
  Reserved := FHeap.HeapBytes;
  FHeap.Collect;
  ExpectCount('objects', Integer(FHeap.ObjectCount), 0);

  Second := FHeap.AllocStruct(TY_NODE);
  Expect<Boolean>(Second = First).ToBe(True);
  { And no new block was taken to satisfy it. }
  Expect<Boolean>(FHeap.HeapBytes = Reserved).ToBe(True);
  { The recycled cell is ZEROED, not left holding the last object's
    fields — otherwise the next collection would trace them. }
  Expect<Boolean>(RefIsNull(FHeap.StructGet(Second, 0).Ref)).ToBe(True);
end;

procedure TRuntimeGcTests
  .TestAHostRootKeepsAnObjectAliveAndReleasingItDoesNot;
var
  Kept: TWasmRef;
  Handle: TWasmRootHandle;
  Index: Integer;
begin
  Kept := FHeap.AllocStruct(TY_BASE);
  Handle := FHeap.RootRegister(Kept);
  for Index := 0 to 4 do
    FHeap.AllocStruct(TY_NODE);

  FHeap.Collect;
  ExpectCount('survivors', Integer(FHeap.ObjectCount), 1);
  { Non-moving, so the handle still names the same address and the host's
    own copy of the pointer is still valid — the payoff for not copying. }
  Expect<Boolean>(FHeap.RootGet(Handle) = Kept).ToBe(True);

  { Releasing it is what makes it garbage, and nothing else. }
  FHeap.RootRelease(Handle);
  FHeap.Collect;
  ExpectCount('after release', Integer(FHeap.ObjectCount), 0);
  ExpectCount('collections', Integer(FHeap.CollectionCount), 2);
end;

procedure TRuntimeGcTests.TestARootScopeReleasesInOneStep;
var
  Mark: UInt32;
  Index: Integer;
begin
  { The scoped form is the common case — a host function holding several
    references across an allocation — and leaving the scope must release
    all of them, not merely the last. }
  Mark := FHeap.RootScopeEnter;
  for Index := 0 to 3 do
    FHeap.RootRegister(FHeap.AllocStruct(TY_BASE));
  ExpectCount('roots', FHeap.RootCount, 4);

  FHeap.Collect;
  ExpectCount('held', Integer(FHeap.ObjectCount), 4);

  FHeap.RootScopeLeave(Mark);
  ExpectCount('roots after', FHeap.RootCount, 0);
  FHeap.Collect;
  ExpectCount('after scope', Integer(FHeap.ObjectCount), 0);
end;

procedure TRuntimeGcTests.TestTransitiveGraphSurvivesThroughOneRoot;
var
  Leaf: TWasmRef;
  Middle: TWasmRef;
  Root: TWasmRef;
  Handle: TWasmRootHandle;
begin
  { struct -> array -> struct, kept alive by ONE root. Reachability is
    transitive or it is nothing, and the array leg is what exercises the
    element-wise trace rather than the field-offset one. }
  Leaf := FHeap.AllocStruct(TY_BASE);
  Middle := FHeap.AllocArray(TY_REF_ARRAY, 3);
  FHeap.ArraySet(Middle, 2, MakeValueRef(Leaf));
  Root := Node(Middle, WASM_REF_NULL);
  Handle := FHeap.RootRegister(Root);

  { Garbage alongside it, so the test would fail if collection were a
    no-op rather than a correct traversal. }
  FHeap.AllocStruct(TY_NODE);
  FHeap.AllocArray(TY_I32_ARRAY, 8);

  FHeap.Collect;
  ExpectCount('reachable', Integer(FHeap.ObjectCount), 3);
  Expect<Boolean>(FHeap.StructGet(Root, 0).Ref = Middle).ToBe(True);
  Expect<Boolean>(FHeap.ArrayGet(Middle, 2).Ref = Leaf).ToBe(True);

  FHeap.RootRelease(Handle);
  FHeap.Collect;
  ExpectCount('unreachable', Integer(FHeap.ObjectCount), 0);
end;

procedure TRuntimeGcTests.TestUnreachableCyclesAreCollected;
var
  First: TWasmRef;
  Second: TWasmRef;
  Handle: TWasmRootHandle;
begin
  { ADR-0011 rejects reference counting because it "cannot collect cycles;
    WebAssembly GC object graphs form them freely, so this is a
    correctness failure, not a performance one". This is that argument
    made executable: two structs pointing at each other, reachable from
    nothing. }
  First := FHeap.AllocStruct(TY_NODE);
  Second := FHeap.AllocStruct(TY_NODE);
  FHeap.StructSet(First, 0, MakeValueRef(Second));
  FHeap.StructSet(Second, 0, MakeValueRef(First));
  { A self-loop too — the degenerate cycle a naive mark loop turns into
    an infinite one. }
  FHeap.StructSet(Second, 1, MakeValueRef(Second));

  Handle := FHeap.RootRegister(First);
  FHeap.Collect;
  ExpectCount('rooted cycle', Integer(FHeap.ObjectCount), 2);

  FHeap.RootRelease(Handle);
  FHeap.Collect;
  ExpectCount('unrooted cycle', Integer(FHeap.ObjectCount), 0);
end;

procedure TRuntimeGcTests.TestFrameWalkKeepsExactlyTheReferencedRegisters;
var
  Frame: TWasmGcFrame;
  Slots: array[0..3] of TWasmValue;
  Bits: array[0..0] of UInt32;
  Live: TWasmRef;
  AlsoLive: TWasmRef;
  Hidden: TWasmRef;
begin
  { CONTRACT GC-1, proven against a stub before Track E exists. Registers
    1 and 3 are references; register 2 holds a reference VALUE but is not
    flagged, which is exactly what a tier that forgot to zero a slot, or
    that reused a numeric register, would look like — and the collector
    must believe RefRegBits rather than the bit pattern. }
  Live := FHeap.AllocStruct(TY_BASE);
  Hidden := FHeap.AllocStruct(TY_BASE);
  AlsoLive := FHeap.AllocArray(TY_I32_ARRAY, 2);

  ValueZeroSlots(@Slots[0], 4);
  Slots[1].Bits := UInt64(Live);
  Slots[2].Bits := UInt64(Hidden);
  Slots[3].Bits := UInt64(AlsoLive);
  Bits[0] := (UInt32(1) shl 1) or (UInt32(1) shl 3);

  Frame.Prev := nil;
  Frame.Slots := @Slots[0];
  Frame.RefRegBits := PWasmGcRefBits(@Bits[0]);
  Frame.RegisterCount := 4;
  Frame.Instance := nil;
  FHeap.PushFrame(@Frame);
  try
    FHeap.Collect;
  finally
    FHeap.PopFrame;
  end;

  ExpectCount('kept by the frame', Integer(FHeap.ObjectCount), 2);
  Expect<Int32>(FHeap.StructGet(Live, 0).I32).ToBe(0);
  ExpectCount('array still', Integer(FHeap.ArrayLength(AlsoLive)), 2);

  { Popped, so nothing holds them now. }
  FHeap.Collect;
  ExpectCount('after the frame', Integer(FHeap.ObjectCount), 0);
end;

type
  { A stand-in for the store's root callback: the collector takes its
    roots through one procedure variable and never reaches into whatever
    is on the other side of it, which is what makes this whole suite
    store-free. }
  TFakeRootSet = record
    Ref: TWasmRef;
    Calls: Integer;
  end;

  PFakeRootSet = ^TFakeRootSet;

procedure FakeRoots(const AHeap: TWasmGcHeap; const AContext: Pointer);
begin
  Inc(PFakeRootSet(AContext)^.Calls);
  AHeap.MarkRoot(PFakeRootSet(AContext)^.Ref);
end;

type
  { A root callback that marks its object and then raises on a chosen call,
    to force an exception mid-mark (H8). File-level because the collector
    calls it and a closure would be managed state on that path. }
  TAbortRootSet = record
    Ref: TWasmRef;
    Calls: Integer;
    RaiseOnCall: Integer;
  end;

  PAbortRootSet = ^TAbortRootSet;

procedure AbortingRoots(const AHeap: TWasmGcHeap; const AContext: Pointer);
begin
  Inc(PAbortRootSet(AContext)^.Calls);
  { Mark the graph's entry, then abort BEFORE Drain traces its children —
    exactly the partial mark that leaves stale bits under fixed polarity. }
  AHeap.MarkRoot(PAbortRootSet(AContext)^.Ref);
  if PAbortRootSet(AContext)^.Calls = PAbortRootSet(AContext)^.RaiseOnCall then
    raise EWasmError.Create('injected mid-mark failure');
end;

var
  { The heap a re-entrant release hook allocates from (B10). File-level for
    the same reason: TWasmHostRelease is a plain procedure with no heap
    argument, so the hook reaches the heap through here. }
  GReleaseHeap: TWasmGcHeap;

procedure AllocatingRelease(const APayload: NativeUInt);
begin
  { A host release hook must NOT allocate — it runs inside the sweep. Doing
    so must be caught loudly by the re-entrancy assert, not corrupt the
    free-list rebuild silently. }
  if GReleaseHeap <> nil then
    GReleaseHeap.AllocStruct(TY_BASE);
end;

procedure TRuntimeGcTests.TestStoreRootCallbackIsConsulted;
var
  Fake: TFakeRootSet;
begin
  Fake.Calls := 0;
  Fake.Ref := FHeap.AllocStruct(TY_BASE);
  FHeap.AllocStruct(TY_NODE);
  FHeap.SetRootSource(FakeRoots, @Fake);

  FHeap.Collect;
  ExpectCount('callbacks', Fake.Calls, 1);
  ExpectCount('kept', Integer(FHeap.ObjectCount), 1);

  Fake.Ref := WASM_REF_NULL;
  FHeap.Collect;
  ExpectCount('callbacks again', Fake.Calls, 2);
  ExpectCount('kept after', Integer(FHeap.ObjectCount), 0);
end;

procedure TRuntimeGcTests.TestI31AndNullAreNeverAllocatedOrTraced;
var
  Obj: TWasmRef;
  Handle: TWasmRootHandle;
begin
  { An i31 is unboxed: 31 payload bits plus one tag bit is exactly 32, so
    ref.i31 allocates NOTHING and the mark loop rejects it with the same
    single test that rejects null. }
  ExpectCount('objects', Integer(FHeap.ObjectCount), 0);
  Handle := FHeap.RootRegister(MakeI31Ref(-5));
  FHeap.RootRegister(WASM_REF_NULL);
  ExpectCount('still nothing', Integer(FHeap.ObjectCount), 0);

  Obj := FHeap.AllocStruct(TY_NODE);
  { A reference field holding an i31 is traced past, not followed. }
  FHeap.StructSet(Obj, 0, MakeValueRef(MakeI31Ref(7)));
  FHeap.RootRegister(Obj);

  FHeap.Collect;
  ExpectCount('after collect', Integer(FHeap.ObjectCount), 1);
  Expect<Int32>(I31GetSigned(FHeap.RootGet(Handle))).ToBe(-5);
  Expect<Int32>(I31GetSigned(FHeap.StructGet(Obj, 0).Ref)).ToBe(7);
end;

{ --- exceptions and host boxes ------------------------------------------- }

procedure TRuntimeGcTests.TestExceptionArgumentsAreTracedThroughTheTagType;
var
  Exn: TWasmRef;
  Payload: TWasmRef;
  Handle: TWasmRootHandle;
begin
  { "An exception instance … holds the address of the respective tag and
    the argument values" (`syntax-exninst`). WHICH arguments are
    references is not derivable from the object — it comes from the tag's
    functype params, cached on the engine type exactly as struct field
    offsets are. Track H adds throw and catch; the object is allocatable,
    traceable and collectable today. }
  Payload := FHeap.AllocStruct(TY_BASE);
  Exn := FHeap.AllocExn(4, TY_TAG, 2);
  FHeap.ExnSetArg(Exn, 0, MakeValueI32(99));
  FHeap.ExnSetArg(Exn, 1, MakeValueRef(Payload));
  Handle := FHeap.RootRegister(Exn);

  FHeap.Collect;
  ExpectCount('exn and payload', Integer(FHeap.ObjectCount), 2);
  ExpectCount('tag', Integer(FHeap.ExnTagAddr(Exn)), 4);
  ExpectCount('argc', Integer(FHeap.ExnArgCount(Exn)), 2);
  Expect<Int32>(FHeap.ExnArg(Exn, 0).I32).ToBe(99);
  Expect<Boolean>(FHeap.ExnArg(Exn, 1).Ref = Payload).ToBe(True);
  { An exception is in its own hierarchy — not an aggregate. }
  Expect<Boolean>(GcAbsKindOf(GcRefKind(Exn)) = wahExn).ToBe(True);

  FHeap.RootRelease(Handle);
  FHeap.Collect;
  ExpectCount('both gone', Integer(FHeap.ObjectCount), 0);
end;

procedure TRuntimeGcTests.TestHostBoxReleaseRunsOnSweep;
var
  Box: TWasmRef;
  Handle: TWasmRootHandle;
begin
  { A raw host pointer is not a valid reference — its low bit may be set
    and the collector cannot trace it — so an externref of a host value is
    a pointer to one of these. The release callback is NOT a wasm-visible
    finalizer: 3.0 has neither finalization nor weak references, and this
    is the embedder's hook to drop its own refcount. }
  Box := FHeap.AllocHostBox(NativeUInt($ABCD), CountRelease);
  Handle := FHeap.RootRegister(Box);
  Expect<Boolean>(GcRefKind(Box) = wokHostBox).ToBe(True);
  Expect<Boolean>(GcHostBoxPayload(Box) = NativeUInt($ABCD)).ToBe(True);

  FHeap.Collect;
  ExpectCount('not yet released', GReleaseCount, 0);

  FHeap.RootRelease(Handle);
  FHeap.Collect;
  ExpectCount('released', GReleaseCount, 1);
  Expect<Boolean>(GReleasedPayload = NativeUInt($ABCD)).ToBe(True);
end;

{ --- the trigger and the statistics -------------------------------------- }

procedure TRuntimeGcTests.TestAllocationAtTheThresholdCollects;
var
  Index: Integer;
begin
  { ALLOCATION SITES ARE THE ONLY TRIGGER in v1. A floor of zero makes
    that deterministic: every allocation finds itself over the threshold
    and collects first, so three allocations of unrooted objects leave
    exactly one alive and three collections behind. }
  FHeap.Threshold := 0;
  ExpectCount('collections before', Integer(FHeap.CollectionCount), 0);
  for Index := 0 to 2 do
    FHeap.AllocStruct(TY_NODE);
  ExpectCount('collections', Integer(FHeap.CollectionCount), 3);
  ExpectCount('survivors', Integer(FHeap.ObjectCount), 1);
end;

procedure TRuntimeGcTests.TestNoCollectionBelowTheThreshold;
var
  Index: Integer;
begin
  { The other half of the same claim: under the default threshold a
    handful of small objects collects nothing at all, so the trigger is
    the threshold rather than the allocation itself. }
  for Index := 0 to 63 do
    FHeap.AllocStruct(TY_NODE);
  ExpectCount('collections', Integer(FHeap.CollectionCount), 0);
  ExpectCount('objects', Integer(FHeap.ObjectCount), 64);
end;

procedure TRuntimeGcTests.TestStatisticsAccountForEveryByte;
var
  Handle: TWasmRootHandle;
  Index: Integer;
begin
  Handle := FHeap.RootRegister(FHeap.AllocStruct(TY_BASE));
  for Index := 0 to 9 do
    FHeap.AllocArray(TY_I32_ARRAY, 16);

  Expect<Boolean>(FHeap.BytesAllocated = FHeap.BytesLive).ToBe(True);
  Expect<Boolean>(FHeap.HeapBytes >= FHeap.BytesLive).ToBe(True);

  FHeap.Collect;

  { Every allocated byte is either live or reclaimed, always. }
  Expect<Boolean>(
    FHeap.BytesAllocated = FHeap.BytesLive + FHeap.BytesReclaimed)
    .ToBe(True);
  ExpectCount('objects', Integer(FHeap.ObjectCount), 1);
  Expect<Boolean>(FHeap.BytesLive > 0).ToBe(True);
  Expect<Boolean>(FHeap.RootGet(Handle) <> WASM_REF_NULL).ToBe(True);
end;

{ --- abort safety, frames, and the staged gaps --------------------------- }

procedure TRuntimeGcTests.TestAnAbortedCollectionLeavesNoStaleMarks;
var
  EntryNode: TWasmRef;
  Child: TWasmRef;
  Roots: TAbortRootSet;
  Caught: string;
begin
  { A collection that raises mid-mark must leave no lasting mark, or the
    next cycle early-outs on the stale bit and sweeps a reachable object
    (H8). Two live structs, entry -> child, kept alive only by a root
    callback that marks the entry and then raises before Drain reaches the
    child. }
  Child := FHeap.AllocStruct(TY_NODE);
  EntryNode := FHeap.AllocStruct(TY_NODE);
  FHeap.StructSet(EntryNode, 0, MakeValueRef(Child));

  Roots.Ref := EntryNode;
  Roots.Calls := 0;
  Roots.RaiseOnCall := 1;   { raise on the first collection only }
  FHeap.SetRootSource(AbortingRoots, @Roots);

  Caught := 'no error';
  try
    FHeap.Collect;
  except
    on E: EWasmError do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe('injected mid-mark failure');

  { The aborted cycle never reached Sweep, so both objects are still here. }
  ExpectCount('after abort', Integer(FHeap.ObjectCount), 2);

  { The SECOND collection completes: it marks the entry (no raise now) and
    Drain traces the child, so BOTH survive. Under the old fixed-polarity
    sweep the entry's stale mark made MarkRoot early-out, the child was
    never traced, and this counted 1 — the bug H8 describes. }
  FHeap.Collect;
  ExpectCount('reachable after recovery', Integer(FHeap.ObjectCount), 2);
  Expect<Boolean>(FHeap.StructGet(EntryNode, 0).Ref = Child).ToBe(True);
end;

procedure TRuntimeGcTests.TestResetFramesDropsStaleFramesAfterUnwind;
var
  Frame: TWasmGcFrame;
  Slots: array[0..0] of TWasmValue;
  Bits: array[0..0] of UInt32;
  Live: TWasmRef;
begin
  { ResetFrames is the trampoline's post-trap obligation: a siglongjmp skips
    every PopFrame, so the chain is dropped, not trusted (H6/B21). Push a
    frame that roots an object, simulate an abrupt unwind by calling
    ResetFrames instead of PopFrame, and assert the next collection walks no
    stale frame — the object is collected and CurrentFrame is nil. }
  Live := FHeap.AllocStruct(TY_BASE);
  ValueZeroSlots(@Slots[0], 1);
  Slots[0].Bits := UInt64(Live);
  Bits[0] := UInt32(1) shl 0;

  Frame.Slots := @Slots[0];
  Frame.RefRegBits := PWasmGcRefBits(@Bits[0]);
  Frame.RegisterCount := 1;
  Frame.Instance := nil;
  FHeap.PushFrame(@Frame);
  Expect<Boolean>(FHeap.CurrentFrame = @Frame).ToBe(True);

  { The abrupt unwind: the frame is gone from the Pascal stack, and the
    trampoline drops the chain rather than popping it. }
  FHeap.ResetFrames;
  Expect<Boolean>(FHeap.CurrentFrame = nil).ToBe(True);

  { With no frame rooting it, the object is unreachable and collected. A
    stale frame left on the chain would have kept it alive and, worse, read
    a dangling Slots pointer. }
  FHeap.Collect;
  ExpectCount('collected after reset', Integer(FHeap.ObjectCount), 0);
end;

procedure TRuntimeGcTests.TestAReleaseHookThatAllocatesIsCaught;
var
  Box: TWasmRef;
  Handle: TWasmRootHandle;
  Caught: string;
begin
  { A host release hook runs inside the sweep; if it allocates, the free
    list is mid-rebuild and TakeCell would corrupt it. The re-entrancy
    assert (B10) makes that loud instead of silent. Register a box whose
    release hook allocates, drop the root, and collect: the assert fires. }
  GReleaseHeap := FHeap;
  try
    Box := FHeap.AllocHostBox(NativeUInt($1234), AllocatingRelease);
    Handle := FHeap.RootRegister(Box);
    FHeap.RootRelease(Handle);

    Caught := 'no error';
    try
      FHeap.Collect;
    except
      on E: EWasmError do
        Caught := E.Message;
    end;
    Expect<Boolean>(Pos('must not allocate', Caught) > 0).ToBe(True);
  finally
    GReleaseHeap := nil;
  end;
end;

procedure TRuntimeGcTests.TestAllocationFailureCollectsThenRetries;
var
  Before: Integer;
  Obj: TWasmRef;
begin
  { NewBlock used to trap the moment the host allocator failed; design §7.3
    says collect, retry, THEN trap (M8). Force the first block allocation to
    fail: Allocate must collect once and retry, and the object still
    allocates. }
  Before := Integer(FHeap.CollectionCount);
  FHeap.InjectBlockFailures(1);
  Obj := FHeap.AllocStruct(TY_BASE);

  Expect<Boolean>(RefIsObject(Obj)).ToBe(True);
  ExpectCount('collect-then-retry ran',
    Integer(FHeap.CollectionCount), Before + 1);
end;

procedure TRuntimeGcTests.TestVectorStorageIsStagedNotAnInternalBug;
var
  Obj: TWasmRef;
  Caught: string;
begin
  { A (struct (field v128)) is a valid TYPE — the validator admits vector
    storage; only $FD instructions are staged. A valid module can still
    reach the field through struct.new_default, so the runtime fails with
    the SAME staged-SIMD message the validator uses, not a bare 'internal:'
    engine bug (B15). }
  Obj := FHeap.AllocStruct(TY_VEC_STRUCT);
  Caught := 'accepted';
  try
    FHeap.StructSetDefaults(Obj);
  except
    on E: EWasmTrap do
      Caught := 'trap: ' + E.Message;
    on E: EWasmError do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_GC_VEC_STORAGE_STAGED);
end;

procedure TRuntimeGcTests.TestExternalizeIsInvisibleToAbstractKindStaged;
var
  StructRef: TWasmRef;
  Box: TWasmRef;
begin
  { STAGED / KNOWN LIMITATION (M7), pinned so it is loud rather than silent.
    extern.convert_any / any.convert_extern move a value between the `any`
    and `extern` hierarchies (`syntax-heaptype`, a.k.a. `type-abstract`,
    read from wasm-mcp 0.2.16 at commit d7b37e41…: the two "are
    interconvertible … an isomorphic set of values, but may have different,
    incompatible representations in practice"). Both report can_trap:false
    and are identity on the operand.

    GcAbsKindOf derives the abstract hierarchy from the object KIND alone,
    so it CANNOT record an externalization: a struct is always wahStruct
    (under `any`), a host box always wahExtern. After
    struct.new -> extern.convert_any, ref.test (ref extern) ought to answer
    true and ref.test (ref any) false — the opposite of what a kind-only map
    yields. This test pins the current, deliberately-limited answer; the
    convert ops live in Track E and are unimplemented, so nothing observes
    the wrong answer yet. When Track E lands them, the fix (a wrapper object
    or a header flag set at the convert site) must flip these. }
  StructRef := FHeap.AllocStruct(TY_BASE);
  Box := FHeap.AllocHostBox(NativeUInt($7), nil);

  Expect<Boolean>(GcAbsKindOf(GcRefKind(StructRef)) = wahStruct).ToBe(True);
  Expect<Boolean>(GcAbsKindOf(GcRefKind(Box)) = wahExtern).ToBe(True);
end;

procedure TRuntimeGcTests.SetupTests;
begin
  Test('field offsets follow declaration order and packed widths',
    TestFieldOffsetsFollowDeclarationOrderAndPacking);
  Test('a subtype''s field prefix matches its supertype exactly',
    TestASubtypePrefixMatchesItsSupertypeExactly);
  Test('every object is eight-byte aligned in every size class',
    TestEveryObjectIsEightByteAligned);
  Test('the header carries the kind and the engine type id',
    TestHeaderCarriesKindAndEngineTypeId);
  Test('abstract kinds keep the hierarchies disjoint',
    TestAbstractKindsAreThreeDisjointHierarchies);

  Test('struct fields round-trip through the heap API',
    TestStructFieldsRoundTrip);
  Test('packed fields sign- and zero-extend, and stores truncate',
    TestPackedFieldsExtendAndTruncate);
  Test('array elements round-trip, including references',
    TestArrayElementsRoundTrip);
  Test('packed array elements extend the same way fields do',
    TestPackedArrayElementsExtend);
  Test('access through a null reference traps', TestNullAccessTraps);
  Test('an array index out of bounds traps',
    TestArrayIndexOutOfBoundsTraps);
  Test('defaults are checked against aux-default, not invented',
    TestDefaultsAreCheckedNotInvented);

  Test('array.copy is overlap-safe forward and backward',
    TestArrayCopyMovesForwardAndBackwardWithoutClobbering);
  Test('array.copy traps out of bounds on either side',
    TestArrayCopyBoundsTrapOnEitherSide);
  Test('array.copy preserves reference elements through the destination',
    TestArrayCopyReferenceElementsSurviveThroughTheDestination);
  Test('array.init_data copies packed bytes and traps both bounds',
    TestArrayInitFromDataCopiesBytesAndTrapsBothBounds);
  Test('array.init_elem copies references and traps both bounds',
    TestArrayInitFromElemCopiesRefsAndTrapsBothBounds);

  Test('collecting with nothing live reclaims everything',
    TestCollectingWithNothingLiveReclaimsEverything);
  Test('reclaimed cells are handed back to the next allocation',
    TestReclaimedBytesAreReused);
  Test('a host root keeps an object alive and releasing it does not',
    TestAHostRootKeepsAnObjectAliveAndReleasingItDoesNot);
  Test('a root scope releases every root it covers',
    TestARootScopeReleasesInOneStep);
  Test('a transitive graph survives through one root',
    TestTransitiveGraphSurvivesThroughOneRoot);
  Test('unreachable cycles are collected',
    TestUnreachableCyclesAreCollected);
  Test('the frame walk keeps exactly the flagged registers',
    TestFrameWalkKeepsExactlyTheReferencedRegisters);
  Test('the root callback is consulted on every collection',
    TestStoreRootCallbackIsConsulted);
  Test('i31 and null are never allocated and never traced',
    TestI31AndNullAreNeverAllocatedOrTraced);

  Test('exception arguments are traced through the tag type',
    TestExceptionArgumentsAreTracedThroughTheTagType);
  Test('a host box release callback runs when the box is swept',
    TestHostBoxReleaseRunsOnSweep);

  Test('an allocation at the threshold collects first',
    TestAllocationAtTheThresholdCollects);
  Test('no collection happens below the threshold',
    TestNoCollectionBelowTheThreshold);
  Test('statistics account for every allocated byte',
    TestStatisticsAccountForEveryByte);

  Test('an aborted collection leaves no stale mark for the next cycle',
    TestAnAbortedCollectionLeavesNoStaleMarks);
  Test('ResetFrames drops a stale frame chain after an unwind',
    TestResetFramesDropsStaleFramesAfterUnwind);
  Test('a release hook that allocates is caught, not silently corrupting',
    TestAReleaseHookThatAllocatesIsCaught);
  Test('allocation failure collects and retries before trapping',
    TestAllocationFailureCollectsThenRetries);
  Test('a v128 field is staged SIMD, not an internal bug',
    TestVectorStorageIsStagedNotAnInternalBug);
  Test('externalization is invisible to the kind-only abstract map (staged)',
    TestExternalizeIsInvisibleToAbstractKindStaged);
end;

begin
  TestRunnerProgram.AddSuite(TRuntimeGcTests.Create('Wasm.Runtime.Gc'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
