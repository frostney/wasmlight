{ Unit suite for Wasm.Runtime.Store — engine-wide type interning, the
  matching relation, tables, and import matching.

  The interning cases go through the REAL decoder and validator on modules
  assembled byte by byte, because the property under test is
  cross-module: two independently validated modules that declare
  structurally identical recursion groups must come out of the engine with
  the SAME ids. Nothing below Track D can check that — a module-local
  canonicalisation is correct by construction within one module — so it is
  the reason this unit exists.

  The display test is checked DIFFERENTIALLY against
  TWasmTypeContext.MatchesCanon over every pair of types in a module. The
  validator's relation is already under test in its own suite, so agreeing
  with it is the cheapest high-coverage check available for the engine's
  copy.

  The import-matching cases hand-build the instance records rather than
  instantiating anything: the point of each is one variance direction, and
  spelling the two types next to the assertion is what makes a swapped
  direction visible. There is ONE TEST PER DIRECTION on purpose — a rule
  that accepted both ways round would pass a single-direction test.

  Spec anchors are cited per group, read from wasm-mcp 0.2.16 at the
  pinned commit d7b37e4170d8315f2f1283aed4e8076591a9a333. }
program Wasm.Runtime.Store.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator,
  Wasm.Validator.Types;

type
  { A growable byte buffer, so a section's size prefix is computed rather
    than hand-counted. }
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

  { One decoded + validated module, with its buffer, kept alive together:
    the IR borrows the bytes (ADR-0003). }
  TFixtureModule = class
  public
    Bytes: TWasmBytes;
    Module: TWasmModule;
    Ir: TWasmIrModule;
    Types: TWasmTypeContext;
    destructor Destroy; override;
  end;

  TRuntimeStoreTests = class(TTestSuite)
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FModules: array of TFixtureModule;

    function BuildModule(const ATypeSection: array of Byte): TFixtureModule;
    { The self-referential rec group both alpha-equivalence fixtures
      share. }
    function SelfRefGroupModule: TFixtureModule;
    function SelfRefGroupAfterAFuncModule: TFixtureModule;
    function SubtypeChainModule: TFixtureModule;
    function BaseOnlyModule: TFixtureModule;
    function OutOfGroupRefModule: TFixtureModule;
    function OutOfGroupRefAfterFillerModule: TFixtureModule;

    function InternOf(const AModule: TFixtureModule): TWasmEngineTypeIds;
    procedure ExpectCount(const AWhat: string;
      const AActual, AExpected: Integer);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestInterningAllocatesOneGroup;
    procedure TestAlphaEquivalentGroupsShareEngineIds;
    procedure TestDistinctGroupsGetDistinctIds;
    procedure TestReinterningIsIdempotent;
    procedure TestEmptyRecGroupInternsToNothing;
    procedure TestCrossModuleOutOfGroupRefsInternStructurally;
    procedure TestDisplayTestAgreesWithTheValidator;
    procedure TestEngineMatchingIsCrossModule;

    procedure TestLimitsMinIsALowerBound;
    procedure TestLimitsMaxIsAnUpperBoundTheOtherWayRound;
    procedure TestASupplierWithoutAMaximumFailsADeclaredOne;
    procedure TestLimitsAddressTypesMustBeEqual;
    procedure TestMemImportUsesTheCurrentSize;

    procedure TestImmutableGlobalIsCovariant;
    procedure TestMutableGlobalIsInvariant;
    procedure TestGlobalMutabilityMustMatchBothWays;

    procedure TestFuncImportAcceptsASubtype;
    procedure TestFuncImportRejectsASupertype;
    procedure TestTableElementTypeIsInvariant;
    procedure TestTagImportMatchesOnTheDefinedType;

    procedure TestTableBoundsAreExact;
    procedure TestTableRangeChecksDoNotWrap;
    procedure TestTableGrowRespectsTheMaximum;
    procedure TestTableCopyIsOverlapSafeAndTrapsBothSides;
    procedure TestTableInitFromElemSliceTrapsBothSides;
    procedure TestTierContextIsFreedOnStoreTeardown;
    procedure TestFuncRefHandlesAreAlignedAndStable;
    procedure TestFuncRefHandlesComeFromTheCollector;
    procedure TestRuntimeCastIsCrossModule;
    procedure TestRuntimeCastKeepsTheHierarchiesApart;
    procedure TestRuntimeCastSeesM7ConversionWrappers;
    procedure TestHostRootsGoThroughTheStore;
    procedure TestTrampolineContextCarriesTheStore;
    procedure TestFrameChainResetsAfterATrap;
    procedure TestThreadConfinementCheckAcceptsTheOwner;
    { Baseline-JIT tier seam (O-J1, O-J5). }
    procedure TestFuncInstTierFieldsDefaultToNotCompiled;
    procedure TestJitOffsetsMatchTheRecordLayout;
  end;

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

{ --- TFixtureModule ------------------------------------------------------ }

destructor TFixtureModule.Destroy;
begin
  Ir.Free;
  Module.Free;
  inherited Destroy;
end;

{ --- O-10 teardown sentinel ---------------------------------------------
  Evidence that TWasmStore.Destroy invokes TierContextFree with the exact
  TierContext pointer. A file-level procedure and file-level variables
  because TierContextFree is a plain procedure var — a method or closure is
  managed state the store's teardown path must not carry. }
var
  GTierFreeCount: Integer;
  GTierFreedContext: Pointer;

procedure RecordTierContextFree(AContext: Pointer);
begin
  Inc(GTierFreeCount);
  GTierFreedContext := AContext;
end;

{ --- fixture ------------------------------------------------------------- }

procedure TRuntimeStoreTests.BeforeEach;
begin
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  FModules := nil;
end;

procedure TRuntimeStoreTests.AfterEach;
var
  Index: Integer;
begin
  FreeAndNil(FStore);
  for Index := 0 to High(FModules) do
    FModules[Index].Free;
  FModules := nil;
  FreeAndNil(FEngine);
end;

function TRuntimeStoreTests.BuildModule(
  const ATypeSection: array of Byte): TFixtureModule;
var
  Buf: TByteBuf;
begin
  Buf.Reset;
  Buf.AddMany([$00, $61, $73, $6D, $01, $00, $00, $00]);
  Buf.Section(wsType, ATypeSection);

  Result := TFixtureModule.Create;
  { The suite owns every fixture for the life of the test: the IR and the
    type context both borrow, and freeing the buffer under them is the
    lifetime bug ADR-0003 names. }
  SetLength(FModules, Length(FModules) + 1);
  FModules[High(FModules)] := Result;

  Result.Bytes := Buf.Finish;
  Result.Module := TWasmModule.Create;
  DecodeModule(Result.Bytes, Result.Module);
  Result.Ir := ValidateModule(Result.Module, Result.Bytes);
  Result.Types.Build(Result.Module);
end;

{ (rec (struct (field (ref null 0)))) — ONE rec group whose member refers
  to itself, so its serialised key can only compare equal to another
  module's if the self-reference was rolled to a group-relative recursive
  index (`aux-roll-rectype`). A group with no internal reference would
  intern equal by accident. }
function TRuntimeStoreTests.SelfRefGroupModule: TFixtureModule;
begin
  Result := BuildModule([$01,
    $4E, $01, $5F, $01, $63, $00, $00]);
end;

{ The same group, but at type index 1 behind an unrelated (func) type. The
  self-reference is spelled `1` here and `0` there; equal keys are the
  whole point. }
function TRuntimeStoreTests.SelfRefGroupAfterAFuncModule: TFixtureModule;
begin
  Result := BuildModule([$02,
    $60, $00, $00,
    $4E, $01, $5F, $01, $63, $01, $00]);
end;

{ type 0  (sub (struct (field i32)))                  non-final
  type 1  (sub final 0 (struct (field i32) (field i64)))
  A struct subtype EXTENDS its supertype by appending fields
  (Structtype_sub), which is also why field layout is declaration-ordered
  in the collector's design. }
function TRuntimeStoreTests.SubtypeChainModule: TFixtureModule;
begin
  Result := BuildModule([$02,
    $50, $00, $5F, $01, $7F, $00,
    $4F, $01, $00, $5F, $02, $7F, $00, $7E, $00]);
end;

{ ONLY the non-final base group of the chain above, in a module of its
  own. Its serialised key is byte-identical to the chain module's first
  group, so the engine must hand back the same id — which is what makes
  the cast test below genuinely cross-module rather than two names for one
  module's type. }
function TRuntimeStoreTests.BaseOnlyModule: TFixtureModule;
begin
  Result := BuildModule([$01,
    $50, $00, $5F, $01, $7F, $00]);
end;

{ M3 fixtures. Both define the SAME closed array type whose element is a
  reference to an empty struct — an OUT-OF-GROUP reference — but the struct
  sits at a different canonical index in each because a different number of
  rec groups precedes it. If the engine keyed the array's out-of-group
  reference by module-local canonical id, the two arrays would get distinct
  engine ids; keyed structurally (by the struct's engine id) they must
  intern to one.

  type 0  (struct)                     empty struct, singleton group
  type 1  (array (ref null 0))         references type 0 }
function TRuntimeStoreTests.OutOfGroupRefModule: TFixtureModule;
begin
  Result := BuildModule([$02,
    $5F, $00,
    $5E, $63, $00, $00]);
end;

{ type 0  (func)                       an unrelated leading group
  type 1  (struct)                     same empty struct, now canon 1
  type 2  (array (ref null 1))         references type 1 }
function TRuntimeStoreTests.OutOfGroupRefAfterFillerModule: TFixtureModule;
begin
  Result := BuildModule([$03,
    $60, $00, $00,
    $5F, $00,
    $5E, $63, $01, $00]);
end;

function TRuntimeStoreTests.InternOf(
  const AModule: TFixtureModule): TWasmEngineTypeIds;
var
  Canon: TWasmEngineTypeIds;
begin
  FEngine.InternModule(AModule.Ir, Canon, Result);
end;

procedure TRuntimeStoreTests.ExpectCount(const AWhat: string;
  const AActual, AExpected: Integer);
begin
  Expect<string>(Format('%s=%d', [AWhat, AActual]))
    .ToBe(Format('%s=%d', [AWhat, AExpected]));
end;

{ --- interning ----------------------------------------------------------- }

procedure TRuntimeStoreTests.TestInterningAllocatesOneGroup;
var
  Ids: TWasmEngineTypeIds;
begin
  Ids := InternOf(SelfRefGroupModule);
  ExpectCount('types', FEngine.TypeCount, 1);
  ExpectCount('groups', FEngine.GroupCount, 1);
  ExpectCount('ids', Length(Ids), 1);
  { The member's own field names the ENGINE id, not the module-local
    canonical id it carried in — the substitution is what makes an engine
    type self-contained ("all types occurring during execution are
    closed", exec-type). }
  Expect<Boolean>(FEngine.EngineType(Ids[0]).Comp.Struct.Fields[0]
    .Storage.ValueType.Ref.Heap.TypeIndex = Ids[0]).ToBe(True);
end;

procedure TRuntimeStoreTests.TestAlphaEquivalentGroupsShareEngineIds;
var
  First: TWasmEngineTypeIds;
  Second: TWasmEngineTypeIds;
begin
  { THE cross-module property, and the only thing that can check it: two
    separately validated modules whose rec groups are structurally
    identical must come out with the same engine id, even though the
    group sits at a different type index in each. }
  First := InternOf(SelfRefGroupModule);
  Second := InternOf(SelfRefGroupAfterAFuncModule);

  Expect<Boolean>(First[0] = Second[1]).ToBe(True);
  { The second module contributed exactly its (func) type. }
  ExpectCount('types', FEngine.TypeCount, 2);
  ExpectCount('groups', FEngine.GroupCount, 2);
end;

procedure TRuntimeStoreTests.TestDistinctGroupsGetDistinctIds;
var
  Ids: TWasmEngineTypeIds;
begin
  Ids := InternOf(SelfRefGroupAfterAFuncModule);
  Expect<Boolean>(Ids[0] = Ids[1]).ToBe(False);
  Expect<Boolean>(FEngine.EngineType(Ids[0]).Kind = wckFunc).ToBe(True);
  Expect<Boolean>(FEngine.EngineType(Ids[1]).Kind = wckStruct).ToBe(True);
end;

procedure TRuntimeStoreTests.TestReinterningIsIdempotent;
var
  Module: TFixtureModule;
  First: TWasmEngineTypeIds;
  Second: TWasmEngineTypeIds;
  Canon: TWasmEngineTypeIds;
begin
  { A second instantiation of the same module re-interns and must allocate
    nothing: every group hits. }
  Module := SelfRefGroupAfterAFuncModule;
  FEngine.InternModule(Module.Ir, Canon, First);
  ExpectCount('types after one', FEngine.TypeCount, 2);
  FEngine.InternModule(Module.Ir, Canon, Second);
  ExpectCount('types after two', FEngine.TypeCount, 2);
  ExpectCount('groups after two', FEngine.GroupCount, 2);
  Expect<Boolean>((First[0] = Second[0]) and (First[1] = Second[1]))
    .ToBe(True);
end;

procedure TRuntimeStoreTests.TestEmptyRecGroupInternsToNothing;
var
  Ids: TWasmEngineTypeIds;
begin
  { An empty `(rec)` is a valid rec group of zero types: `binary-rectype`
    encodes the members as a list, and a list count of 0 is well-formed
    (type-rec.wast opens with one). It must intern to nothing — no engine
    type, no group, no type-index slot — rather than being rejected as an
    internal "sizes do not cover the type index space" error. The module is
    `(rec)` followed by a lone (func), so exactly one engine type results.

      type section: 2 rectype entries
        [0] 0x4E 0x00        (rec) with zero members
        [1] 0x60 0x00 0x00   (func) -> singleton rec group }
  Ids := InternOf(BuildModule([$02, $4E, $00, $60, $00, $00]));

  { Only the func's type index survives; the empty group added nothing. }
  ExpectCount('type-index space', Length(Ids), 1);
  ExpectCount('types', FEngine.TypeCount, 1);
  ExpectCount('groups', FEngine.GroupCount, 1);
  Expect<Boolean>(FEngine.EngineType(Ids[0]).Kind = wckFunc).ToBe(True);
end;

procedure TRuntimeStoreTests.TestCrossModuleOutOfGroupRefsInternStructurally;
var
  IdsA: TWasmEngineTypeIds;
  IdsB: TWasmEngineTypeIds;
begin
  { M3: the shared struct interns equal (it always did — it has no
    out-of-group reference), but the ARRAY that references it must intern
    equal too, even though its element's out-of-group reference is spelled
    with a different module-local canonical id in each module. A key that
    carried the module-local id would give the two arrays distinct engine
    ids; the structural (engine-id) rewrite makes them one. }
  IdsA := InternOf(OutOfGroupRefModule);
  IdsB := InternOf(OutOfGroupRefAfterFillerModule);

  { struct: A's type 0, B's type 1. }
  Expect<Boolean>(IdsA[0] = IdsB[1]).ToBe(True);
  { array — THE M3 assertion: same engine id across the two modules. }
  Expect<Boolean>(IdsA[1] = IdsB[2]).ToBe(True);
  { and the matching relation agrees, cross-module. }
  Expect<Boolean>(FEngine.Matches(IdsA[1], IdsB[2])).ToBe(True);
  { the filler (func) is distinct and did not collide with either. }
  Expect<Boolean>(IdsB[0] = IdsA[1]).ToBe(False);
end;

procedure TRuntimeStoreTests.TestDisplayTestAgreesWithTheValidator;
var
  Module: TFixtureModule;
  Ids: TWasmEngineTypeIds;
  Sub, Super: Integer;
  Mine, Theirs: Boolean;
  Disagreements: Integer;
begin
  { Differential against the already-tested validator implementation, over
    every ordered pair. The two relations are the same relation
    (`match-deftype`, Deftype_sub/refl and Deftype_sub/super) computed
    over two different id spaces, so any disagreement is a bug in the
    remap or in the display rebuild. }
  Module := SubtypeChainModule;
  Ids := InternOf(Module);
  Disagreements := 0;
  for Sub := 0 to Module.Types.TypeCount - 1 do
    for Super := 0 to Module.Types.TypeCount - 1 do
    begin
      Mine := FEngine.Matches(Ids[Sub], Ids[Super]);
      Theirs := Module.Types.MatchesCanon(
        Module.Types.CanonIdOf(UInt32(Sub)),
        Module.Types.CanonIdOf(UInt32(Super)));
      if Mine <> Theirs then
        Inc(Disagreements);
    end;
  ExpectCount('disagreements', Disagreements, 0);
  { And the relation is not vacuous: the pair that matters really does
    hold in one direction only. }
  Expect<Boolean>(FEngine.Matches(Ids[1], Ids[0])).ToBe(True);
  Expect<Boolean>(FEngine.Matches(Ids[0], Ids[1])).ToBe(False);
end;

procedure TRuntimeStoreTests.TestEngineMatchingIsCrossModule;
var
  FromChain: TWasmEngineTypeIds;
  Other: TWasmEngineTypeIds;
begin
  { The subtype relation must hold between ids that reached the engine
    through DIFFERENT modules — which is the whole reason displays live in
    the engine rather than in an instance. }
  FromChain := InternOf(SubtypeChainModule);
  Other := InternOf(SubtypeChainModule);
  Expect<Boolean>(FEngine.Matches(Other[1], FromChain[0])).ToBe(True);
  Expect<Boolean>(FEngine.Matches(FromChain[1], Other[0])).ToBe(True);
  Expect<Boolean>(FEngine.Matches(Other[0], FromChain[1])).ToBe(False);
end;

{ --- limits -------------------------------------------------------------- }

procedure TRuntimeStoreTests.TestLimitsMinIsALowerBound;
begin
  { The importer asks for AT LEAST Min. A supplier offering more is fine;
    one offering less is not. }
  Expect<Boolean>(MatchLimits(MakeLimits(watI32, 2),
    MakeLimits(watI32, 1))).ToBe(True);
  Expect<Boolean>(MatchLimits(MakeLimits(watI32, 1),
    MakeLimits(watI32, 2))).ToBe(False);
end;

procedure TRuntimeStoreTests.TestLimitsMaxIsAnUpperBoundTheOtherWayRound;
begin
  { INVERTED VARIANCE, direction one. The importer asks for AT MOST Max,
    so a supplier whose maximum is SMALLER satisfies it and one whose
    maximum is larger does not — the opposite of the minimum's direction.
    Swapping the two comparisons passes the min test above and fails
    here, which is why they are separate tests. }
  Expect<Boolean>(MatchLimits(MakeLimitsWithMax(watI32, 1, 2),
    MakeLimitsWithMax(watI32, 1, 4))).ToBe(True);
  Expect<Boolean>(MatchLimits(MakeLimitsWithMax(watI32, 1, 8),
    MakeLimitsWithMax(watI32, 1, 4))).ToBe(False);
end;

procedure TRuntimeStoreTests.TestASupplierWithoutAMaximumFailsADeclaredOne;
begin
  { An absent maximum is INFINITY, so it fails a declared maximum rather
    than satisfying it. A declaration with no maximum accepts anything. }
  Expect<Boolean>(MatchLimits(MakeLimits(watI32, 1),
    MakeLimitsWithMax(watI32, 1, 4))).ToBe(False);
  Expect<Boolean>(MatchLimits(MakeLimitsWithMax(watI32, 1, 4),
    MakeLimits(watI32, 1))).ToBe(True);
end;

procedure TRuntimeStoreTests.TestLimitsAddressTypesMustBeEqual;
begin
  { 3.0 carries the addrtype inside limits (`syntax-addrtype`), and an
    i32 memory does not satisfy an i64 import however generous its
    bounds. }
  Expect<Boolean>(MatchLimits(MakeLimits(watI64, 8),
    MakeLimits(watI32, 1))).ToBe(False);
  Expect<Boolean>(MatchLimits(MakeLimits(watI32, 8),
    MakeLimits(watI64, 1))).ToBe(False);
end;

procedure TRuntimeStoreTests.TestMemImportUsesTheCurrentSize;
var
  Mem: TWasmMemoryInst;
begin
  { A memory instance's type reports its CURRENT size as the minimum
    (`valid-meminst` ties the byte length to the limits), so a memory
    grown past its declared minimum satisfies an import asking for more.
    Hand-built: none of this needs a mapping, and reserving one would
    make the assertion about the allocator instead. }
  FillChar(Mem, SizeOf(Mem), 0);
  Mem.AddrType := watI32;
  Mem.Pages := 4;
  Mem.HasMax := False;
  Mem.MaxPages := 65536;

  Expect<Boolean>(MatchMemImport(Mem, MakeMemType(MakeLimits(watI32, 4))))
    .ToBe(True);
  Expect<Boolean>(MatchMemImport(Mem, MakeMemType(MakeLimits(watI32, 5))))
    .ToBe(False);
  Expect<Boolean>(MatchMemImport(Mem,
    MakeMemType(MakeLimitsWithMax(watI32, 1, 8)))).ToBe(False);
end;

{ --- globals ------------------------------------------------------------- }

procedure TRuntimeStoreTests.TestImmutableGlobalIsCovariant;
var
  Ids: TWasmEngineTypeIds;
  Supplied: TWasmGlobalInst;
  SubType: TWasmValueType;
  SuperType: TWasmValueType;
begin
  { An IMMUTABLE global is read-only, so a subtype value satisfies a
    supertype declaration. }
  Ids := InternOf(SubtypeChainModule);
  SubType := MakeRefValueType(MakeRefType(True,
    MakeConcreteHeapType(Ids[1])));
  SuperType := MakeRefValueType(MakeRefType(True,
    MakeConcreteHeapType(Ids[0])));

  Supplied.Value := MakeValueNullRef;
  Supplied.GlobalType := MakeGlobalType(False, SubType);
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(False, SuperType))).ToBe(True);

  Supplied.GlobalType := MakeGlobalType(False, SuperType);
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(False, SubType))).ToBe(False);
end;

procedure TRuntimeStoreTests.TestMutableGlobalIsInvariant;
var
  Ids: TWasmEngineTypeIds;
  Supplied: TWasmGlobalInst;
  SubType: TWasmValueType;
  SuperType: TWasmValueType;
begin
  { INVERTED VARIANCE, direction two. A MUTABLE global is both read and
    written, so neither direction alone is sound and the value type is
    INVARIANT — the covariant reading that works for an immutable global
    must be rejected here, in both directions. }
  Ids := InternOf(SubtypeChainModule);
  SubType := MakeRefValueType(MakeRefType(True,
    MakeConcreteHeapType(Ids[1])));
  SuperType := MakeRefValueType(MakeRefType(True,
    MakeConcreteHeapType(Ids[0])));

  Supplied.Value := MakeValueNullRef;
  Supplied.GlobalType := MakeGlobalType(True, SubType);
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(True, SuperType))).ToBe(False);

  Supplied.GlobalType := MakeGlobalType(True, SuperType);
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(True, SubType))).ToBe(False);

  { Equal types still match — invariance is not rejection of everything. }
  Supplied.GlobalType := MakeGlobalType(True, SubType);
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(True, SubType))).ToBe(True);
end;

procedure TRuntimeStoreTests.TestGlobalMutabilityMustMatchBothWays;
var
  Supplied: TWasmGlobalInst;
  I32: TWasmValueType;
begin
  { A const import bound to a var global would let the exporter change it
    under the importer's feet; a var import bound to a const global cannot
    be written. Both directions fail. }
  I32 := MakeNumValueType(wntI32);
  Supplied.Value := MakeValueI32(0);

  Supplied.GlobalType := MakeGlobalType(True, I32);
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(False, I32))).ToBe(False);

  Supplied.GlobalType := MakeGlobalType(False, I32);
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(True, I32))).ToBe(False);

  { And a plain numeric mismatch is still a mismatch. }
  Supplied.GlobalType := MakeGlobalType(False, MakeNumValueType(wntI64));
  Expect<Boolean>(MatchGlobalImport(FEngine, Supplied,
    MakeGlobalType(False, I32))).ToBe(False);
end;

{ --- functions, tables, tags --------------------------------------------- }

procedure TRuntimeStoreTests.TestFuncImportAcceptsASubtype;
var
  Ids: TWasmEngineTypeIds;
  Supplied: TWasmFuncInst;
begin
  { Externtype_sub/func reduces to Deftype_sub, whose rules are
    reflexivity and the supertype step. }
  Ids := InternOf(SubtypeChainModule);
  FillChar(Supplied, SizeOf(Supplied), 0);
  Supplied.TypeId := Ids[1];
  Expect<Boolean>(MatchFuncImport(FEngine, Supplied, Ids[0])).ToBe(True);
  Expect<Boolean>(MatchFuncImport(FEngine, Supplied, Ids[1])).ToBe(True);
end;

procedure TRuntimeStoreTests.TestFuncImportRejectsASupertype;
var
  Ids: TWasmEngineTypeIds;
  Supplied: TWasmFuncInst;
begin
  Ids := InternOf(SubtypeChainModule);
  FillChar(Supplied, SizeOf(Supplied), 0);
  Supplied.TypeId := Ids[0];
  Expect<Boolean>(MatchFuncImport(FEngine, Supplied, Ids[1])).ToBe(False);
end;

procedure TRuntimeStoreTests.TestTableElementTypeIsInvariant;
var
  Ids: TWasmEngineTypeIds;
  Supplied: TWasmTableInst;
  Declared: TWasmTableType;
begin
  { H7, CONFIRMED-invariant (Tabletype_sub) against linking.wast:441: a
    table is both read and written, so its element type is INVARIANT — a
    (ref null $sub) table does NOT satisfy an import of (ref null $super),
    the exact case the corpus asserts unlinkable. Element types must be
    EQUAL. A covariant match here is a memory-safety hole, because call_ref
    / call_indirect do no runtime element-type check. }
  Ids := InternOf(SubtypeChainModule);

  { supplied = subtype, declared = supertype: covariance would accept this,
    invariance rejects it (this is the corpus's unlinkable case). }
  Supplied.TableType := MakeTableType(
    MakeRefType(True, MakeConcreteHeapType(Ids[1])),
    MakeLimits(watI32, 1));
  Supplied.HasMax := False;
  Supplied.MaxSize := UInt64($FFFFFFFF);
  SetLength(Supplied.Elems, 1);

  Declared := MakeTableType(
    MakeRefType(True, MakeConcreteHeapType(Ids[0])),
    MakeLimits(watI32, 1));
  Expect<Boolean>(MatchTableImport(FEngine, Supplied, Declared)).ToBe(False);

  { supplied = supertype, declared = subtype: rejected in the other
    direction too. }
  Declared := MakeTableType(
    MakeRefType(True, MakeConcreteHeapType(Ids[1])),
    MakeLimits(watI32, 1));
  Supplied.TableType.RefType := MakeRefType(True,
    MakeConcreteHeapType(Ids[0]));
  Expect<Boolean>(MatchTableImport(FEngine, Supplied, Declared)).ToBe(False);

  { Equal element types still match — invariance is not blanket rejection. }
  Supplied.TableType.RefType := MakeRefType(True,
    MakeConcreteHeapType(Ids[1]));
  Expect<Boolean>(MatchTableImport(FEngine, Supplied, Declared)).ToBe(True);
end;

procedure TRuntimeStoreTests.TestTagImportMatchesOnTheDefinedType;
var
  Ids: TWasmEngineTypeIds;
  Supplied: TWasmTagInst;
begin
  { match-tagtype's premise "invokes subtyping on defined types". Tag
    IDENTITY is still the address — this is only the type check. }
  Ids := InternOf(SubtypeChainModule);
  Supplied.TypeId := Ids[1];
  Expect<Boolean>(MatchTagImport(FEngine, Supplied, Ids[0])).ToBe(True);
  Supplied.TypeId := Ids[0];
  Expect<Boolean>(MatchTagImport(FEngine, Supplied, Ids[1])).ToBe(False);
end;

{ --- tables -------------------------------------------------------------- }

procedure TRuntimeStoreTests.TestTableBoundsAreExact;
var
  Addr: TWasmTableAddr;
  Caught: string;
begin
  Addr := FStore.AddTable(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)),
    MakeLimits(watI32, 2)), WASM_REF_NULL);
  Expect<Boolean>(TableSize(FStore.Tables[Addr]) = 2).ToBe(True);

  { A defaultable table with no initialiser is filled with null
    (`aux-default`). }
  Expect<Boolean>(RefIsNull(TableGet(FStore.Tables[Addr], 0))).ToBe(True);

  FStore.TableSet(Addr, 1, MakeI31Ref(5));
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 1))).ToBe(5);

  Caught := 'no trap';
  try
    TableGet(FStore.Tables[Addr], 2);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  { table.get's message, NOT call_indirect's `undefined element` — the two
    are separately confirmed and are never unified. }
  Expect<string>(Caught).ToBe(MSG_TRAP_TABLE_OUT_OF_BOUNDS);
end;

procedure TRuntimeStoreTests.TestTableRangeChecksDoNotWrap;
var
  Addr: TWasmTableAddr;
  Caught: string;
begin
  { The subtracting form is mandatory: `index + count > size` wraps for a
    large index on an i64-addressed table and would admit an out-of-bounds
    write. }
  Addr := FStore.AddTable(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)),
    MakeLimits(watI64, 2)), WASM_REF_NULL);

  Caught := 'no trap';
  try
    TableCheckRange(FStore.Tables[Addr], UInt64($FFFFFFFFFFFFFFFF), 2);
  except
    on E: EWasmTrap do
    begin
      Caught := E.Message;
    end;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_TABLE_OUT_OF_BOUNDS);

  { A zero-length range at exactly the size is IN bounds, which is what
    table.fill and table.init require. }
  TableCheckRange(FStore.Tables[Addr], 2, 0);
  Expect<Boolean>(True).ToBe(True);
end;

procedure TRuntimeStoreTests.TestTableGrowRespectsTheMaximum;
var
  Addr: TWasmTableAddr;
begin
  Addr := FStore.AddTable(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)),
    MakeLimitsWithMax(watI32, 1, 2)), WASM_REF_NULL);

  { table.grow returns the PREVIOUS size, or -1, and never traps. }
  Expect<Int64>(FStore.TableGrow(Addr, 1, MakeI31Ref(3))).ToBe(1);
  Expect<Boolean>(TableSize(FStore.Tables[Addr]) = 2).ToBe(True);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 1))).ToBe(3);

  Expect<Int64>(FStore.TableGrow(Addr, 1, WASM_REF_NULL)).ToBe(-1);
  Expect<Boolean>(TableSize(FStore.Tables[Addr]) = 2).ToBe(True);
end;

{ --- barriered table bulk ops (O-2) -------------------------------------- }

procedure TRuntimeStoreTests.TestTableCopyIsOverlapSafeAndTrapsBothSides;
var
  Addr: TWasmTableAddr;
  Other: TWasmTableAddr;
  Index: Integer;
  Caught: string;
begin
  { exec-table.copy through the store's barriered method. Overlap within one
    table is memmove; between two tables it is a straight copy. Both ranges
    trap 'out of bounds table access' (corpus table_copy.wast). }
  Addr := FStore.AddTable(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahAny)),
    MakeLimits(watI32, 6)), WASM_REF_NULL);
  for Index := 0 to 5 do
    FStore.TableSet(Addr, UInt64(Index), MakeI31Ref(Index));

  { Backward overlap: dstIdx > srcIdx. Copy 3 from 0 into 2 => slots 2,3,4
    become 0,1,2. A forward loop would clobber slot 4 by reading an
    already-written slot. }
  FStore.TableCopy(Addr, 2, Addr, 0, 3);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 0))).ToBe(0);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 1))).ToBe(1);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 2))).ToBe(0);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 3))).ToBe(1);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 4))).ToBe(2);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 5))).ToBe(5);

  { Distinct tables: no overlap. Copies the current [0,1,0] prefix. }
  Other := FStore.AddTable(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahAny)),
    MakeLimits(watI32, 3)), WASM_REF_NULL);
  FStore.TableCopy(Other, 0, Addr, 0, 3);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Other], 0))).ToBe(0);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Other], 1))).ToBe(1);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Other], 2))).ToBe(0);

  { A zero count at exactly the size is in bounds and copies nothing. }
  FStore.TableCopy(Addr, 6, Addr, 6, 0);

  { Dest range out of bounds. }
  Caught := 'no trap';
  try
    FStore.TableCopy(Addr, 4, Addr, 0, 3);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_TABLE_OUT_OF_BOUNDS);

  { Source range out of bounds. }
  Caught := 'no trap';
  try
    FStore.TableCopy(Addr, 0, Addr, 4, 3);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_TABLE_OUT_OF_BOUNDS);
end;

procedure TRuntimeStoreTests.TestTableInitFromElemSliceTrapsBothSides;
var
  Addr: TWasmTableAddr;
  Src: array[0..3] of TWasmRef;
  Index: Integer;
  Caught: string;
begin
  { O-2 sliced form. Both sides checked before any write; a trapping
    table.init writes nothing. }
  Addr := FStore.AddTable(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahAny)),
    MakeLimits(watI32, 5)), WASM_REF_NULL);
  for Index := 0 to 3 do
    Src[Index] := MakeI31Ref(10 + Index);

  { Copy 2 refs from source element 1 into table offset 2. }
  FStore.TableInitFromElem(Addr, 2, Src, 1, 2);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 2))).ToBe(11);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 3))).ToBe(12);
  Expect<Boolean>(RefIsNull(TableGet(FStore.Tables[Addr], 0))).ToBe(True);

  { Destination range out of bounds. }
  Caught := 'no trap';
  try
    FStore.TableInitFromElem(Addr, 4, Src, 0, 2);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_TABLE_OUT_OF_BOUNDS);

  { Source range out of bounds: 4 entries, offset 3 + count 2 > 4. }
  Caught := 'no trap';
  try
    FStore.TableInitFromElem(Addr, 0, Src, 3, 2);
  except
    on E: EWasmTrap do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe(MSG_TRAP_TABLE_OUT_OF_BOUNDS);

  { The whole-array overload the instantiator uses is undisturbed. }
  FStore.TableInitFromElem(Addr, 0, Src);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 0))).ToBe(10);
  Expect<Int32>(I31GetSigned(TableGet(FStore.Tables[Addr], 3))).ToBe(13);
end;

procedure TRuntimeStoreTests.TestTierContextIsFreedOnStoreTeardown;
var
  S: TWasmStore;
  Ctx: Pointer;
begin
  { O-10: the store owns the tier context's lifetime. RegisterInterpreter
    sets TierInvoke/TierContext/TierContextFree together, and Destroy frees
    the context via TierContextFree(TierContext) with no external map. }
  GTierFreeCount := 0;
  GTierFreedContext := nil;

  { A sentinel pointer standing in for TWasmInterpContext; the hook records
    it rather than freeing, so the test owns the allocation. }
  Ctx := GetMem(16);
  S := TWasmStore.Create(FEngine);
  S.TierContext := Ctx;
  S.TierContextFree := @RecordTierContextFree;
  S.Free;

  Expect<Integer>(GTierFreeCount).ToBe(1);
  Expect<Boolean>(GTierFreedContext = Ctx).ToBe(True);
  FreeMem(Ctx);

  { The guard is on BOTH fields: a store with the hook but a nil context
    must not call through (nor the reverse). }
  GTierFreeCount := 0;
  S := TWasmStore.Create(FEngine);
  S.TierContextFree := @RecordTierContextFree;   { TierContext stays nil }
  S.Free;
  Expect<Integer>(GTierFreeCount).ToBe(0);
end;

{ --- handles, trampoline, thread ----------------------------------------- }

procedure TRuntimeStoreTests.TestFuncRefHandlesAreAlignedAndStable;
var
  First: TWasmFuncAddr;
  Second: TWasmFuncAddr;
  Ref: TWasmRef;
begin
  First := FStore.AddHostFunc(0, nil, nil);
  Second := FStore.AddHostFunc(0, nil, nil);
  Ref := FStore.Funcs[First].RefObject;

  { 8-byte alignment is what reserves bit 0 of an object pointer for the
    unboxed-i31 tag. A violated invariant here would read back as an i31
    rather than as a pointer. }
  Expect<Boolean>((NativeUInt(RefToPointer(Ref)) and 7) = 0).ToBe(True);
  Expect<Boolean>(RefIsObject(Ref)).ToBe(True);
  Expect<Boolean>(RefIsI31(Ref)).ToBe(False);

  { ref.func returns the same pointer every time, and two functions never
    share one. }
  Expect<Boolean>(FStore.Funcs[First].RefObject = Ref).ToBe(True);
  Expect<Boolean>(FStore.Funcs[Second].RefObject = Ref).ToBe(False);
  Expect<Boolean>(FStore.FuncRefAddr(Ref) = First).ToBe(True);
  Expect<Boolean>(FStore.FuncRefAddr(FStore.Funcs[Second].RefObject) =
    Second).ToBe(True);
end;

procedure TRuntimeStoreTests.TestFuncRefHandlesComeFromTheCollector;
var
  Addr: TWasmFuncAddr;
  Ref: TWasmRef;
begin
  { Wave 5's handover: a funcref handle is a wokFuncRef object on the GC
    heap, not a store-private block. It is therefore collectable in
    principle, and the store's root callback is what makes it not be — a
    function instance is never removed from a store, so its handle lives
    exactly as long as the store does. }
  Addr := FStore.AddHostFunc(0, nil, nil);
  Ref := FStore.Funcs[Addr].RefObject;
  Expect<Boolean>(GcRefKind(Ref) = wokFuncRef).ToBe(True);
  ExpectCount('objects', Integer(FStore.Heap.ObjectCount), 1);

  FStore.Heap.Collect;

  ExpectCount('objects after', Integer(FStore.Heap.ObjectCount), 1);
  Expect<Boolean>(FStore.Funcs[Addr].RefObject = Ref).ToBe(True);
  Expect<Boolean>(FStore.FuncRefAddr(Ref) = Addr).ToBe(True);
end;

procedure TRuntimeStoreTests.TestRuntimeCastIsCrossModule;
var
  ChainIds: TWasmEngineTypeIds;
  BaseIds: TWasmEngineTypeIds;
  Derived: TWasmRef;
  Base: TWasmRef;
begin
  { THE property the whole interning exercise exists for: an object
    allocated with one module's type id answers a cast against ANOTHER
    module's id for the same structural type. The displays live in the
    engine precisely so this works with no module in hand. }
  ChainIds := InternOf(SubtypeChainModule);
  BaseIds := InternOf(BaseOnlyModule);
  Expect<Boolean>(BaseIds[0] = ChainIds[0]).ToBe(True);

  Derived := FStore.Heap.AllocStruct(ChainIds[1]);
  Base := FStore.Heap.AllocStruct(BaseIds[0]);

  { One shift and one array index: the header's id against the target's
    depth in the display. }
  Expect<Boolean>(IsRefOfType(FEngine, Derived, ChainIds[1])).ToBe(True);
  Expect<Boolean>(IsRefOfType(FEngine, Derived, BaseIds[0])).ToBe(True);
  { And not the other way round — a supertype instance is not a subtype. }
  Expect<Boolean>(IsRefOfType(FEngine, Base, ChainIds[1])).ToBe(False);

  { The subtype's field prefix is the supertype's, which is what makes
    reading field 0 through either type legitimate. }
  FStore.Heap.StructSet(Derived, 0, MakeValueI32(5));
  Expect<Int32>(FStore.Heap.StructGet(Derived, 0).I32).ToBe(5);
  Expect<Boolean>(
    FEngine.GcTypes.Layout(ChainIds[1])^.Fields[0].Offset =
    FEngine.GcTypes.Layout(ChainIds[0])^.Fields[0].Offset).ToBe(True);
end;

procedure TRuntimeStoreTests.TestRuntimeCastKeepsTheHierarchiesApart;
var
  Ids: TWasmEngineTypeIds;
  Struct: TWasmRef;
  Handle: TWasmRef;
  Scalar: TWasmRef;
  Addr: TWasmFuncAddr;
begin
  { Three disjoint hierarchies — func, aggregate, extern — plus exn. A
    funcref answering true for anyref is the failure the roadmap flags as
    having to be modelled exactly. }
  Ids := InternOf(SubtypeChainModule);
  Struct := FStore.Heap.AllocStruct(Ids[0]);
  { Two statements, not one: AddHostFunc grows Funcs, and an expression
    that indexed the array in the same statement could hold the pointer
    from before the reallocation. }
  Addr := FStore.AddHostFunc(Ids[0], nil, nil);
  Handle := FStore.Funcs[Addr].RefObject;
  Scalar := MakeI31Ref(3);

  Expect<Boolean>(IsRefOfRefType(FEngine, Struct,
    MakeRefType(True, MakeAbsHeapType(wahAny)))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, Struct,
    MakeRefType(True, MakeAbsHeapType(wahStruct)))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, Struct,
    MakeRefType(True, MakeAbsHeapType(wahArray)))).ToBe(False);
  Expect<Boolean>(IsRefOfRefType(FEngine, Struct,
    MakeRefType(True, MakeAbsHeapType(wahFunc)))).ToBe(False);

  Expect<Boolean>(IsRefOfRefType(FEngine, Handle,
    MakeRefType(True, MakeAbsHeapType(wahFunc)))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, Handle,
    MakeRefType(True, MakeAbsHeapType(wahAny)))).ToBe(False);

  { An unboxed i31 is in the aggregate hierarchy and is never a concrete
    type. }
  Expect<Boolean>(IsRefOfRefType(FEngine, Scalar,
    MakeRefType(True, MakeAbsHeapType(wahI31)))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, Scalar,
    MakeRefType(True, MakeAbsHeapType(wahEq)))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, Scalar,
    MakeRefType(True, MakeConcreteHeapType(Ids[0])))).ToBe(False);

  { Casting a null reduces to "does the target admit null" — a static
    property of the target, needing nothing from the value. }
  Expect<Boolean>(IsRefOfRefType(FEngine, WASM_REF_NULL,
    MakeRefType(True, MakeConcreteHeapType(Ids[0])))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, WASM_REF_NULL,
    MakeRefType(False, MakeConcreteHeapType(Ids[0])))).ToBe(False);
end;

procedure TRuntimeStoreTests.TestRuntimeCastSeesM7ConversionWrappers;
var
  Ids: TWasmEngineTypeIds;
  Struct, Ext, Box, Intl: TWasmRef;
begin
  { M7 — the runtime cast surface must classify a value by the hierarchy it
    CURRENTLY inhabits after extern.convert_any / any.convert_extern, not the
    one its inner value was allocated in. The wrappers ride the same
    IsRefOfRefType path as everything else (GcAbsKindOf on the wrapper kind),
    so this is the store-level proof behind the ref_test/ref_cast corpus. }
  Ids := InternOf(SubtypeChainModule);
  Struct := FStore.Heap.AllocStruct(Ids[0]);

  { externalize(struct): now `extern`, no longer `any` / `struct`. }
  Ext := FStore.Heap.ExternalizeAny(Struct);
  Expect<Boolean>(IsRefOfRefType(FEngine, Ext,
    MakeRefType(True, MakeAbsHeapType(wahExtern)))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, Ext,
    MakeRefType(True, MakeAbsHeapType(wahAny)))).ToBe(False);
  Expect<Boolean>(IsRefOfRefType(FEngine, Ext,
    MakeRefType(True, MakeAbsHeapType(wahStruct)))).ToBe(False);
  { The inverse recovers the exact struct, which still answers `struct`. }
  Expect<Boolean>(FStore.Heap.InternalizeExtern(Ext) = Struct).ToBe(True);

  { internalize(host box): now `any` — but deliberately NOT `eq` (an
    internalized external is `any` and nothing more specific), and never a
    concrete struct/array. }
  Box := FStore.Heap.AllocHostBox(NativeUInt($42), nil);
  Intl := FStore.Heap.InternalizeExtern(Box);
  Expect<Boolean>(IsRefOfRefType(FEngine, Intl,
    MakeRefType(True, MakeAbsHeapType(wahAny)))).ToBe(True);
  Expect<Boolean>(IsRefOfRefType(FEngine, Intl,
    MakeRefType(True, MakeAbsHeapType(wahEq)))).ToBe(False);
  Expect<Boolean>(IsRefOfRefType(FEngine, Intl,
    MakeRefType(True, MakeAbsHeapType(wahStruct)))).ToBe(False);
  Expect<Boolean>(IsRefOfRefType(FEngine, Intl,
    MakeRefType(True, MakeAbsHeapType(wahExtern)))).ToBe(False);
  { And the raw host box, unconverted, is still `extern`. }
  Expect<Boolean>(IsRefOfRefType(FEngine, Box,
    MakeRefType(True, MakeAbsHeapType(wahExtern)))).ToBe(True);
  { The inverse recovers the exact host box. }
  Expect<Boolean>(FStore.Heap.ExternalizeAny(Intl) = Box).ToBe(True);
end;

procedure TRuntimeStoreTests.TestHostRootsGoThroughTheStore;
var
  Ids: TWasmEngineTypeIds;
  Kept: TWasmRef;
  Handle: TWasmRootHandle;
begin
  { Contract HOST-1's surface, in the spelling Track F documents: a host
    holding a TWasmRef across anything that can allocate must register it,
    and there is no diagnostic if it does not. }
  Ids := InternOf(SubtypeChainModule);
  Kept := FStore.Heap.AllocStruct(Ids[0]);
  Handle := RootRegister(FStore, Kept);
  FStore.Heap.AllocStruct(Ids[1]);

  FStore.Heap.Collect;
  ExpectCount('objects', Integer(FStore.Heap.ObjectCount), 1);
  { Non-moving, so the host's own copy of the pointer is still the object
    and RootGet needs no read barrier. }
  Expect<Boolean>(RootGet(FStore, Handle) = Kept).ToBe(True);

  RootRelease(FStore, Handle);
  FStore.Heap.Collect;
  ExpectCount('objects after', Integer(FStore.Heap.ObjectCount), 0);
end;

procedure TRuntimeStoreTests.TestTrampolineContextCarriesTheStore;
var
  Trampoline: TWasmTrampoline;
begin
  { The design contract gave the trampoline a typed Store field; it cannot
    have one without inverting the dependency between this unit and
    Wasm.Runtime.Traps. The field is an untyped Pointer there and this is
    the convention that gives it meaning. }
  FillChar(Trampoline, SizeOf(Trampoline), 0);
  Trampoline.Context := Pointer(FStore);
  Expect<Boolean>(TrampolineStore(@Trampoline) = FStore).ToBe(True);
  Expect<Boolean>(TrampolineStore(nil) = nil).ToBe(True);
end;

{ H6: a fake tier that pushes a GC frame (as guest execution would) and
  then traps, so the frame's PopFrame is skipped exactly as a real
  siglongjmp would skip it. RunPendingStart must re-establish the chain. }
var
  GTrapFrame: TWasmGcFrame;

procedure TrapPushingTier(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams: PWasmValue;
  const AResults: PWasmValue);
begin
  FillChar(GTrapFrame, SizeOf(GTrapFrame), 0);
  AStore.Heap.PushFrame(@GTrapFrame);
  raise EWasmTrap.Create('boom');
end;

procedure TRuntimeStoreTests.TestFrameChainResetsAfterATrap;
var
  Ids: TWasmEngineTypeIds;
  Addr: TWasmFuncAddr;
  Instance: TWasmModuleInstance;
  Caught: Boolean;
begin
  Ids := InternOf(SelfRefGroupAfterAFuncModule);
  Addr := FStore.AddWasmFunc(Ids[0], 0);

  Instance := TWasmModuleInstance.Create;
  SetLength(Instance.FuncAddrs, 1);
  Instance.FuncAddrs[0] := Addr;
  Instance.HasPendingStart := True;
  Instance.PendingStartFuncIndex := 0;
  FStore.AddInstance(Instance);

  FStore.TierInvoke := @TrapPushingTier;
  Expect<Boolean>(FStore.Heap.CurrentFrame = nil).ToBe(True);

  Caught := False;
  try
    FStore.RunPendingStart(Instance);
  except
    on E: EWasmTrap do
      Caught := True;
  end;

  { The trap propagated, AND the dangling guest frame the longjmp would
    have skipped is gone — contract GC-1 / ADR-0009. }
  Expect<Boolean>(Caught).ToBe(True);
  Expect<Boolean>(FStore.Heap.CurrentFrame = nil).ToBe(True);
end;

procedure TRuntimeStoreTests.TestThreadConfinementCheckAcceptsTheOwner;
begin
  { ADR-0008's check is debug-only by design. All that can be asserted on
    the owning thread is that it does not fire — the violating case needs
    a second thread, and spawning one to prove a debug assertion would
    make the suite's own confinement the thing under test. }
  FStore.CheckThread;
  Expect<Boolean>(FStore.OwnerThread = GetCurrentThreadId).ToBe(True);
end;

procedure TRuntimeStoreTests.TestFuncInstTierFieldsDefaultToNotCompiled;
var
  W, H: TWasmFuncAddr;
begin
  { O-J1: a freshly added function is NOT compiled — CompiledEntry nil and the
    compile-on-hot counter zero — for both a wasm and a host function, so a
    store with no JIT registered dispatches everything to the interpreter and
    nothing observable changes. The JIT's own dispatch hook is likewise nil
    until a JIT registers it. }
  W := FStore.AddWasmFunc(0, 0);
  H := FStore.AddHostFunc(0, nil, nil);

  Expect<Boolean>(FStore.Funcs[W].CompiledEntry = nil).ToBe(True);
  Expect<Boolean>(FStore.Funcs[W].CompiledDirectEntry = nil).ToBe(True);
  ExpectCount('wasm CallCount', Integer(FStore.Funcs[W].CallCount), 0);
  Expect<Boolean>(FStore.Funcs[H].CompiledEntry = nil).ToBe(True);
  Expect<Boolean>(FStore.Funcs[H].CompiledDirectEntry = nil).ToBe(True);
  ExpectCount('host CallCount', Integer(FStore.Funcs[H].CallCount), 0);
  Expect<Boolean>(Assigned(FStore.JitInvokeCompiled)).ToBe(False);
end;

procedure TRuntimeStoreTests.TestJitOffsetsMatchTheRecordLayout;
var
  Off: TWasmJitOffsets;
begin
  { O-J5: the offsets the JIT hard-codes come from the live Pascal layout, and
    this asserts the concrete values the generated code assumes. A field
    reorder moves one of these and the test goes red before any miscompile. }
  Off := WasmJitOffsets(FStore);

  { A memory instance keeps Base first and ByteSize immediately after it — the
    hot pair the inline bounds check loads (jit-spec §7.1). The JIT-supported
    64-bit layouts keep them adjacent; FPC may align UInt64 to eight bytes on a
    32-bit target, where the JIT is unavailable. }
  ExpectCount('MemBase', Integer(Off.MemBase), 0);
  {$IFDEF CPU64}
  ExpectCount('MemByteSize', Integer(Off.MemByteSize), SizeOf(Pointer));
  {$ELSE}
  Expect<Boolean>(Off.MemByteSize >= SizeOf(Pointer)).ToBe(True);
  Expect<Boolean>(Off.MemByteSize < SizeOf(Pointer) + SizeOf(UInt64)).ToBe(True);
  {$ENDIF}

  { A func inst keeps Kind first (the wasm/host discriminator), and its tier
    fields are adjacent (generic entry, direct-safe entry, then CallCount). }
  ExpectCount('FuncKind', Integer(Off.FuncKind), 0);
  ExpectCount('FuncCompiledDirectEntry - FuncCompiledEntry',
    Integer(Off.FuncCompiledDirectEntry - Off.FuncCompiledEntry),
    SizeOf(Pointer));
  ExpectCount('FuncCallCount - FuncCompiledDirectEntry',
    Integer(Off.FuncCallCount - Off.FuncCompiledDirectEntry), SizeOf(Pointer));
  Expect<Boolean>(Off.FuncCompiledDirectEntry + SizeOf(Pointer) +
    SizeOf(UInt32) <= Off.FuncInstStride).ToBe(True);
  Expect<Boolean>((Off.FuncCompiledEntry and (SizeOf(Pointer) - 1)) = 0)
    .ToBe(True);

  { Store.Epoch is read from the object reference at every back-edge safepoint
    (jit-spec §6): it sits past the object header and is pointer-aligned. }
  Expect<Boolean>(Off.StoreEpoch > 0).ToBe(True);
  Expect<Boolean>((Off.StoreEpoch and (SizeOf(UInt64) - 1)) = 0).ToBe(True);

  { The accessor must agree with a direct probe on the live store — the guard
    that the reported StoreEpoch is the real one the JIT would load. }
  ExpectCount('StoreEpoch probe',
    Integer(PtrUInt(@FStore.Epoch) - PtrUInt(Pointer(FStore))),
    Integer(Off.StoreEpoch));

  { The per-process helper-table base (aot-spec §1.2/§4.3): pointer-aligned, past
    the header, and the accessor agrees with a live probe — the position-
    independent prologue loads it at this exact offset. }
  Expect<Boolean>(Off.StoreJitHelperTable > 0).ToBe(True);
  Expect<Boolean>((Off.StoreJitHelperTable and (SizeOf(Pointer) - 1)) = 0)
    .ToBe(True);
  ExpectCount('StoreJitHelperTable probe',
    Integer(PtrUInt(@FStore.JitHelperTable) - PtrUInt(Pointer(FStore))),
    Integer(Off.StoreJitHelperTable));
end;

procedure TRuntimeStoreTests.SetupTests;
begin
  Test('interning a module allocates one group per distinct rec group',
    TestInterningAllocatesOneGroup);
  Test('alpha-equivalent groups from two modules share engine ids',
    TestAlphaEquivalentGroupsShareEngineIds);
  Test('structurally distinct groups get distinct engine ids',
    TestDistinctGroupsGetDistinctIds);
  Test('re-interning the same module allocates nothing',
    TestReinterningIsIdempotent);
  Test('an empty rec group interns to nothing',
    TestEmptyRecGroupInternsToNothing);
  Test('cross-module out-of-group references intern structurally',
    TestCrossModuleOutOfGroupRefsInternStructurally);
  Test('the display test agrees with the validator on every pair',
    TestDisplayTestAgreesWithTheValidator);
  Test('subtyping holds between ids from different modules',
    TestEngineMatchingIsCrossModule);

  Test('a declared minimum is a lower bound on the supplier',
    TestLimitsMinIsALowerBound);
  Test('a declared maximum bounds the supplier the other way round',
    TestLimitsMaxIsAnUpperBoundTheOtherWayRound);
  Test('a supplier without a maximum fails a declared maximum',
    TestASupplierWithoutAMaximumFailsADeclaredOne);
  Test('limits address types must be equal',
    TestLimitsAddressTypesMustBeEqual);
  Test('a memory import is matched against the current size',
    TestMemImportUsesTheCurrentSize);

  Test('an immutable global import is covariant',
    TestImmutableGlobalIsCovariant);
  Test('a mutable global import is invariant',
    TestMutableGlobalIsInvariant);
  Test('global mutability must match in both directions',
    TestGlobalMutabilityMustMatchBothWays);

  Test('a function import accepts a subtype', TestFuncImportAcceptsASubtype);
  Test('a function import rejects a supertype',
    TestFuncImportRejectsASupertype);
  Test('a table import is invariant in its element type',
    TestTableElementTypeIsInvariant);
  Test('a tag import matches on the defined type',
    TestTagImportMatchesOnTheDefinedType);

  Test('table bounds are exact and trap with table.get''s message',
    TestTableBoundsAreExact);
  Test('a table range check does not wrap at a huge index',
    TestTableRangeChecksDoNotWrap);
  Test('table.grow respects the maximum and returns -1',
    TestTableGrowRespectsTheMaximum);
  Test('table.copy is overlap-safe and traps out of bounds both sides',
    TestTableCopyIsOverlapSafeAndTrapsBothSides);
  Test('table.init from an element slice traps out of bounds both sides',
    TestTableInitFromElemSliceTrapsBothSides);
  Test('the tier context is freed on store teardown',
    TestTierContextIsFreedOnStoreTeardown);
  Test('funcref handles are aligned, stable and distinct',
    TestFuncRefHandlesAreAlignedAndStable);
  Test('funcref handles are collector objects the store keeps rooted',
    TestFuncRefHandlesComeFromTheCollector);
  Test('a runtime cast holds between ids from different modules',
    TestRuntimeCastIsCrossModule);
  Test('a runtime cast keeps the reference hierarchies apart',
    TestRuntimeCastKeepsTheHierarchiesApart);
  Test('a runtime cast classifies M7 extern/any conversion wrappers',
    TestRuntimeCastSeesM7ConversionWrappers);
  Test('host roots register and release through the store',
    TestHostRootsGoThroughTheStore);
  Test('the trampoline context carries the store',
    TestTrampolineContextCarriesTheStore);
  Test('the frame chain is reset after a trap unwinds guest entry',
    TestFrameChainResetsAfterATrap);
  Test('the confinement check accepts the owning thread',
    TestThreadConfinementCheckAcceptsTheOwner);

  Test('a fresh function instance is not compiled and its counter is zero',
    TestFuncInstTierFieldsDefaultToNotCompiled);
  Test('the JIT field offsets match the record layout',
    TestJitOffsetsMatchTheRecordLayout);
end;

begin
  TestRunnerProgram.AddSuite(
    TRuntimeStoreTests.Create('Wasm.Runtime.Store'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
