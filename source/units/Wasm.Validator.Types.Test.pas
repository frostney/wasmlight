{ Unit suite for Wasm.Validator.Types.

  Type sections are assembled byte-by-byte and pushed through the real
  decoder before validation, so every case here is a module the binary
  grammar accepts — which is the point: this unit's job starts exactly
  where Wasm.Decoder.Types' ends, and every rejection below must be an
  EWasmValidationError, never a decode error. The negative cases assert
  the class AND the canonical message prefix, because that boundary and
  those prefixes are conformance surface.

  Spec anchors are cited per assertion group, read from wasm-mcp at the
  pinned commit d7b37e4170d8315f2f1283aed4e8076591a9a333. }
program Wasm.Validator.Types.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Module,
  Wasm.Validator.Types;

type
  TValidatorTypesTests = class(TTestSuite)
  private
    { The decoded module borrows this buffer (ADR-0003), so it lives as
      long as the suite does. }
    FBytes: TWasmBytes;
    FModule: TWasmModule;
    FContext: TWasmTypeContext;

    { Wraps ABody as a complete module with one type section, decodes it,
      and validates the type section into FContext. }
    procedure BuildTypes(const ABody: array of Byte);
    procedure ExpectInvalid(const ADescription, APrefix: string;
      const ABody: array of Byte);
    function PrefixOutcome(const AMessage, APrefix: string): string;
    { Phrased as a value comparison rather than a bare Fail() so the test
      records an assertion on the happy path too. }
    procedure ExpectMatch(const ADescription: string;
      const AActual, AExpected: Boolean);
    procedure ExpectHeapMatch(const ASub, ASuper: TWasmHeapType;
      const AExpected: Boolean);
    procedure ExpectAbsMatch(const ASub, ASuper: TWasmAbsHeapType;
      const AExpected: Boolean);
    procedure ExpectCompMatch(const ASub, ASuper: UInt32;
      const AExpected: Boolean);
    function CanonId(const ATypeIndex: UInt32): Int64;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestAlphaRenamedGroupsShareCanonicalIds;
    procedure TestDistinctGroupsGetDistinctCanonicalIds;
    procedure TestIdenticalSingletonGroupsAreInterned;
    procedure TestAbstractHierarchyOrdering;
    procedure TestAbstractHierarchiesAreDisjoint;
    procedure TestBottomHeapTypes;
    procedure TestBottomValueTypeMatchesEverything;
    procedure TestConcreteVersusAbstract;
    procedure TestDeclaredSubtypeChain;
    procedure TestReferenceNullability;
    procedure TestFuncTypeVariance;
    procedure TestDeclaredFuncSubtypeIsAccepted;
    procedure TestFieldMutabilityInvariance;
    procedure TestStructWidthAndDepthSubtyping;
    procedure TestArraySubtyping;
    procedure TestTopHeapTypes;
    procedure TestAcceptsSupertypeInsideOwnGroup;
    procedure TestOwnGroupSupertypesAreAlphaEquivalent;
    procedure TestRejectsForwardSupertypeAcrossGroups;
    procedure TestRejectsSupertypeIndexOutOfRange;
    procedure TestRejectsSelfAndForwardSupertypeInOwnGroup;
    procedure TestRejectsForwardSupertypeInOwnGroup;
    procedure TestRejectsFinalSupertype;
    procedure TestRejectsCompTypeMismatchAgainstSupertype;
    procedure TestRejectsTooManySupertypes;
    procedure TestRejectsForwardTypeReferenceAcrossGroups;
    procedure TestRejectsOutOfRangeTypeReference;
    procedure TestUnknownTypeIndexLookup;
  end;

procedure TValidatorTypesTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TValidatorTypesTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

procedure TValidatorTypesTests.BuildTypes(const ABody: array of Byte);
var
  I, Size, SizeBytes: Integer;
  Value: UInt32;
begin
  { Section size is a u32 LEB128; the bodies below are small, but the
    emitter is general so a longer case does not silently corrupt. }
  Size := Length(ABody);
  SizeBytes := 1;
  Value := UInt32(Size) shr 7;
  while Value <> 0 do
  begin
    Inc(SizeBytes);
    Value := Value shr 7;
  end;

  SetLength(FBytes, 8 + 1 + SizeBytes + Size);
  for I := 0 to 3 do
    FBytes[I] := WASM_MAGIC[I];
  FBytes[4] := WASM_BINARY_VERSION;
  FBytes[5] := 0;
  FBytes[6] := 0;
  FBytes[7] := 0;
  FBytes[8] := Ord(wsType);

  Value := UInt32(Size);
  for I := 0 to SizeBytes - 1 do
  begin
    if I = SizeBytes - 1 then
      FBytes[9 + I] := Byte(Value and $7F)
    else
      FBytes[9 + I] := Byte((Value and $7F) or $80);
    Value := Value shr 7;
  end;

  for I := 0 to Size - 1 do
    FBytes[9 + SizeBytes + I] := ABody[I];

  DecodeModule(FBytes, FModule);
  FContext.Build(FModule);
end;

function TValidatorTypesTests.PrefixOutcome(const AMessage,
  APrefix: string): string;
begin
  if Copy(AMessage, 1, Length(APrefix)) = APrefix then
    Result := 'rejected: ' + APrefix
  else
    Result := 'rejected with message: ' + AMessage;
end;

procedure TValidatorTypesTests.ExpectInvalid(const ADescription,
  APrefix: string; const ABody: array of Byte);
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';

  { The class is asserted as well as the prefix: a decode error here would
    mean the malformed/invalid boundary has moved, which is the thing this
    suite exists to pin. }
  try
    BuildTypes(ABody);
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, APrefix);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;

  Expect<string>(ADescription + ' -> ' + Outcome)
    .ToBe(ADescription + ' -> rejected: ' + APrefix);
end;

procedure TValidatorTypesTests.ExpectMatch(const ADescription: string;
  const AActual, AExpected: Boolean);

  function Rendered(const AValue: Boolean): string;
  begin
    if AValue then
      Result := 'matches'
    else
      Result := 'does not match';
  end;

begin
  Expect<string>(ADescription + ': ' + Rendered(AActual))
    .ToBe(ADescription + ': ' + Rendered(AExpected));
end;

procedure TValidatorTypesTests.ExpectHeapMatch(const ASub,
  ASuper: TWasmHeapType; const AExpected: Boolean);
begin
  ExpectMatch('heap ' + ASub.Describe + ' <= ' + ASuper.Describe,
    FContext.MatchesHeapType(ASub, ASuper), AExpected);
end;

procedure TValidatorTypesTests.ExpectAbsMatch(const ASub,
  ASuper: TWasmAbsHeapType; const AExpected: Boolean);
begin
  ExpectHeapMatch(MakeAbsHeapType(ASub), MakeAbsHeapType(ASuper),
    AExpected);
end;

procedure TValidatorTypesTests.ExpectCompMatch(const ASub, ASuper: UInt32;
  const AExpected: Boolean);
begin
  ExpectMatch('comp type ' + IntToStr(Int64(ASub)) + ' <= '
    + IntToStr(Int64(ASuper)),
    FContext.MatchesCompType(FContext.Expand(ASub),
      FContext.Expand(ASuper)), AExpected);
end;

function TValidatorTypesTests.CanonId(const ATypeIndex: UInt32): Int64;
begin
  Result := Int64(FContext.CanonIdOf(ATypeIndex));
end;

{ --- canonicalisation ---------------------------------------------------- }

procedure TValidatorTypesTests.TestAlphaRenamedGroupsShareCanonicalIds;
var
  I: Integer;
  SameKey: Boolean;
  KeyA, KeyB: TWasmBytes;
  Field: TWasmValueType;
begin
  { Two spellings of the same pair of mutually recursive structs:

      (rec (type (struct (field (ref null 1))))
           (type (struct (field (ref null 0)))))
      (rec (type (struct (field (ref null 3))))
           (type (struct (field (ref null 2)))))

    The second group's internal references are alpha-renamed by its
    position in the index space. Rolling them up to group-relative
    recursive type indices is what makes the two serialise identically
    (`aux-roll-rectype`, `syntax-rectypeidx`), so they must intern to the
    same canonical ids. }
  BuildTypes([$02,
    $4E, $02, $5F, $01, $63, $01, $00, $5F, $01, $63, $00, $00,
    $4E, $02, $5F, $01, $63, $03, $00, $5F, $01, $63, $02, $00]);

  Expect<Integer>(FContext.TypeCount).ToBe(4);
  Expect<Integer>(FContext.GroupCount).ToBe(2);
  { Four module type indices, but only two distinct defined types. }
  Expect<Integer>(FContext.CanonTypeCount).ToBe(2);

  Expect<Int64>(CanonId(2)).ToBe(CanonId(0));
  Expect<Int64>(CanonId(3)).ToBe(CanonId(1));
  Expect<Boolean>(CanonId(0) = CanonId(1)).ToBe(False);

  { The retained group key is what Track D re-interns into an engine-wide
    table, so two spellings of one type must produce one key. }
  KeyA := FContext.GroupKey(0);
  KeyB := FContext.GroupKey(1);
  SameKey := Length(KeyA) = Length(KeyB);
  if SameKey then
    for I := 0 to High(KeyA) do
      if KeyA[I] <> KeyB[I] then
        SameKey := False;
  Expect<Boolean>(SameKey).ToBe(True);

  { The canonical composite type is in canonical space: its field must
    name a canonical id, not the module index it was spelled with. }
  Field := FContext.CanonComp(FContext.CanonIdOf(2))
    .Struct.Fields[0].Storage.ValueType;
  Expect<Int64>(Int64(Field.Ref.Heap.TypeIndex)).ToBe(CanonId(3));

  { Structural equality is what subtyping sees, too. }
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeConcreteHeapType(2), True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeConcreteHeapType(3), False);
end;

procedure TValidatorTypesTests.TestDistinctGroupsGetDistinctCanonicalIds;
begin
  { (struct (field i32)) and (struct (field i64)) differ only in the
    field's storage type, which the key must therefore carry. }
  BuildTypes([$02,
    $5F, $01, $7F, $00,
    $5F, $01, $7E, $00]);

  Expect<Integer>(FContext.CanonTypeCount).ToBe(2);
  Expect<Boolean>(CanonId(0) = CanonId(1)).ToBe(False);
  Expect<Boolean>(Length(FContext.GroupKey(0))
    = Length(FContext.GroupKey(1))).ToBe(True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeConcreteHeapType(1), False);
end;

procedure TValidatorTypesTests.TestIdenticalSingletonGroupsAreInterned;
begin
  BuildTypes([$02,
    $5F, $01, $7F, $00,
    $5F, $01, $7F, $00]);

  Expect<Integer>(FContext.TypeCount).ToBe(2);
  Expect<Integer>(FContext.CanonTypeCount).ToBe(1);
  Expect<Int64>(CanonId(1)).ToBe(CanonId(0));
end;

{ --- the abstract hierarchy ---------------------------------------------- }

procedure TValidatorTypesTests.TestAbstractHierarchyOrdering;
begin
  { `match-heaptype`: Heaptype_sub/refl, /trans, /eq-any, /i31-eq,
    /struct-eq, /array-eq. The aggregate hierarchy is ANY over EQ over
    I31 / STRUCT / ARRAY (`syntax-heaptype`: "EQ is a subtype of ANY that
    includes all types for which references can be compared"). }
  BuildTypes([$00]);

  ExpectAbsMatch(wahEq, wahAny, True);
  ExpectAbsMatch(wahI31, wahEq, True);
  ExpectAbsMatch(wahStruct, wahEq, True);
  ExpectAbsMatch(wahArray, wahEq, True);
  ExpectAbsMatch(wahI31, wahAny, True);
  ExpectAbsMatch(wahStruct, wahAny, True);
  ExpectAbsMatch(wahArray, wahAny, True);
  ExpectAbsMatch(wahAny, wahAny, True);

  ExpectAbsMatch(wahAny, wahEq, False);
  ExpectAbsMatch(wahEq, wahI31, False);
  ExpectAbsMatch(wahStruct, wahArray, False);
  ExpectAbsMatch(wahArray, wahStruct, False);
  ExpectAbsMatch(wahI31, wahStruct, False);
end;

procedure TValidatorTypesTests.TestAbstractHierarchiesAreDisjoint;
begin
  { `syntax-heaptype`: the function, aggregate, and external hierarchies
    are disjoint, and EXN "has no concrete subtypes" — nothing crosses. }
  BuildTypes([$00]);

  ExpectAbsMatch(wahFunc, wahAny, False);
  ExpectAbsMatch(wahAny, wahFunc, False);
  ExpectAbsMatch(wahExtern, wahAny, False);
  ExpectAbsMatch(wahAny, wahExtern, False);
  ExpectAbsMatch(wahExn, wahAny, False);
  ExpectAbsMatch(wahExn, wahExtern, False);
  ExpectAbsMatch(wahFunc, wahExtern, False);
  ExpectAbsMatch(wahExtern, wahExn, False);
  ExpectAbsMatch(wahExn, wahExn, True);
  ExpectAbsMatch(wahFunc, wahFunc, True);
  ExpectAbsMatch(wahExtern, wahExtern, True);
end;

procedure TValidatorTypesTests.TestBottomHeapTypes;
begin
  { Heaptype_sub/none, /nofunc, /noexn, /noextern: each hierarchy's bottom
    is below everything in that hierarchy and nothing outside it. }
  BuildTypes([$00]);

  ExpectAbsMatch(wahNone, wahAny, True);
  ExpectAbsMatch(wahNone, wahEq, True);
  ExpectAbsMatch(wahNone, wahI31, True);
  ExpectAbsMatch(wahNone, wahStruct, True);
  ExpectAbsMatch(wahNone, wahArray, True);
  ExpectAbsMatch(wahNone, wahNone, True);
  ExpectAbsMatch(wahNone, wahFunc, False);
  ExpectAbsMatch(wahNone, wahExtern, False);
  ExpectAbsMatch(wahAny, wahNone, False);

  ExpectAbsMatch(wahNoFunc, wahFunc, True);
  ExpectAbsMatch(wahNoFunc, wahAny, False);
  ExpectAbsMatch(wahNoExtern, wahExtern, True);
  ExpectAbsMatch(wahNoExtern, wahAny, False);
  ExpectAbsMatch(wahNoExn, wahExn, True);
  ExpectAbsMatch(wahNoExn, wahAny, False);
  ExpectAbsMatch(wahNoExn, wahNoFunc, False);
end;

procedure TValidatorTypesTests.TestBottomValueTypeMatchesEverything;
begin
  { `syntax-rectypeidx`: "The unique value type BOT is a bottom type that
    matches all value types. Similarly, BOT is also used as a bottom type
    of all heap types." It is not representable in the binary format, so
    it is spelled with the reserved sentinel index. }
  BuildTypes([$01, $60, $00, $00]);

  ExpectMatch('bot <= i32',
    FContext.MatchesValType(MakeBotValType,
      MakeNumValueType(wntI32)), True);
  ExpectMatch('bot <= v128',
    FContext.MatchesValType(MakeBotValType, MakeVecValueType), True);
  ExpectMatch('bot <= funcref',
    FContext.MatchesValType(MakeBotValType,
      MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahFunc)))),
    True);
  ExpectMatch('i32 <= bot',
    FContext.MatchesValType(MakeNumValueType(wntI32), MakeBotValType),
    False);
  ExpectMatch('anyref <= bot',
    FContext.MatchesValType(
      MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahAny))),
      MakeBotValType), False);
  ExpectHeapMatch(MakeBotHeapType, MakeAbsHeapType(wahExtern), True);
  ExpectHeapMatch(MakeBotHeapType, MakeConcreteHeapType(0), True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeBotHeapType, False);

  { NULLABILITY DOES NOT MAKE A BOTTOM REFERENCE LESS BOTTOM, and the two
    entry points must agree about that. IsBotValType ignores Nullable, so
    MatchesValType answers True for the nullable spelling; MatchesRefType
    would answer False on the same pair if it reached its nullability
    test, because a nullable subtype against a non-nullable supertype
    fails there. MakeBotValType is the nullable spelling, so these two
    assertions are the same question asked at both entry points. }
  ExpectMatch('(ref null bot) <= (ref 0)',
    FContext.MatchesRefType(MakeRefType(True, MakeBotHeapType),
      MakeRefType(False, MakeConcreteHeapType(0))), True);
  ExpectMatch('(ref bot) <= (ref 0)',
    FContext.MatchesRefType(MakeRefType(False, MakeBotHeapType),
      MakeRefType(False, MakeConcreteHeapType(0))), True);
  ExpectMatch('bot <= (ref 0)',
    FContext.MatchesValType(MakeBotValType,
      MakeRefValueType(MakeRefType(False, MakeConcreteHeapType(0)))),
    True);

  { Numbers and vectors match only themselves (Valtype_sub/num, /vec). }
  ExpectMatch('i32 <= i64',
    FContext.MatchesValType(MakeNumValueType(wntI32),
      MakeNumValueType(wntI64)), False);
  ExpectMatch('f32 <= f32',
    FContext.MatchesValType(MakeNumValueType(wntF32),
      MakeNumValueType(wntF32)), True);
  ExpectMatch('v128 <= v128',
    FContext.MatchesValType(MakeVecValueType, MakeVecValueType), True);
  ExpectMatch('i32 <= anyref',
    FContext.MatchesValType(MakeNumValueType(wntI32),
      MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahAny)))),
    False);
end;

procedure TValidatorTypesTests.TestConcreteVersusAbstract;
begin
  { Heaptype_sub/struct, /array, /func map a concrete type to the abstract
    type of its composite kind; only the hierarchy's bottom goes the other
    way. Types: 0 = (struct), 1 = (array i32), 2 = (func). }
  BuildTypes([$03,
    $5F, $00,
    $5E, $7F, $00,
    $60, $00, $00]);

  ExpectHeapMatch(MakeConcreteHeapType(0), MakeAbsHeapType(wahStruct),
    True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeAbsHeapType(wahEq), True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeAbsHeapType(wahAny), True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeAbsHeapType(wahArray),
    False);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeAbsHeapType(wahFunc),
    False);
  ExpectHeapMatch(MakeConcreteHeapType(1), MakeAbsHeapType(wahArray),
    True);
  ExpectHeapMatch(MakeConcreteHeapType(1), MakeAbsHeapType(wahAny), True);
  ExpectHeapMatch(MakeConcreteHeapType(2), MakeAbsHeapType(wahFunc), True);
  ExpectHeapMatch(MakeConcreteHeapType(2), MakeAbsHeapType(wahAny), False);
  ExpectHeapMatch(MakeConcreteHeapType(2), MakeAbsHeapType(wahEq), False);

  ExpectHeapMatch(MakeAbsHeapType(wahNone), MakeConcreteHeapType(0), True);
  ExpectHeapMatch(MakeAbsHeapType(wahNone), MakeConcreteHeapType(1), True);
  ExpectHeapMatch(MakeAbsHeapType(wahNone), MakeConcreteHeapType(2),
    False);
  ExpectHeapMatch(MakeAbsHeapType(wahNoFunc), MakeConcreteHeapType(2),
    True);
  ExpectHeapMatch(MakeAbsHeapType(wahNoFunc), MakeConcreteHeapType(0),
    False);
  ExpectHeapMatch(MakeAbsHeapType(wahAny), MakeConcreteHeapType(0), False);
  ExpectHeapMatch(MakeAbsHeapType(wahStruct), MakeConcreteHeapType(0),
    False);
end;

{ --- declared subtyping -------------------------------------------------- }

procedure TValidatorTypesTests.TestDeclaredSubtypeChain;
begin
  { (type 0 (sub (struct i32)))
    (type 1 (sub 0 (struct i32 i64)))
    (type 2 (sub final 1 (struct i32 i64 f32)))
    — `match-deftype` Deftype_sub/super, checked here against the
    precomputed supertype display. }
  BuildTypes([$03,
    $50, $00, $5F, $01, $7F, $00,
    $50, $01, $00, $5F, $02, $7F, $00, $7E, $00,
    $4F, $01, $01, $5F, $03, $7F, $00, $7E, $00, $7D, $00]);

  Expect<Int64>(Int64(FContext.CanonDepth(FContext.CanonIdOf(0))))
    .ToBe(0);
  Expect<Int64>(Int64(FContext.CanonDepth(FContext.CanonIdOf(1))))
    .ToBe(1);
  Expect<Int64>(Int64(FContext.CanonDepth(FContext.CanonIdOf(2))))
    .ToBe(2);

  ExpectHeapMatch(MakeConcreteHeapType(1), MakeConcreteHeapType(0), True);
  ExpectHeapMatch(MakeConcreteHeapType(2), MakeConcreteHeapType(1), True);
  ExpectHeapMatch(MakeConcreteHeapType(2), MakeConcreteHeapType(0), True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeConcreteHeapType(2), False);
  ExpectHeapMatch(MakeConcreteHeapType(1), MakeConcreteHeapType(2), False);
  ExpectHeapMatch(MakeConcreteHeapType(2), MakeConcreteHeapType(2), True);

  Expect<Boolean>(FContext.IsFinal(0)).ToBe(False);
  Expect<Boolean>(FContext.IsFinal(2)).ToBe(True);
end;

procedure TValidatorTypesTests.TestReferenceNullability;
var
  Concrete: TWasmHeapType;
begin
  { `match-reftype`: a non-null reference matches a nullable one of a
    matching heap type, never the reverse. }
  BuildTypes([$02,
    $50, $00, $5F, $01, $7F, $00,
    $4F, $01, $00, $5F, $02, $7F, $00, $7E, $00]);

  Concrete := MakeConcreteHeapType(0);
  ExpectMatch('(ref 1) <= (ref null 0)',
    FContext.MatchesRefType(MakeRefType(False, MakeConcreteHeapType(1)),
      MakeRefType(True, Concrete)), True);
  ExpectMatch('(ref null 1) <= (ref 0)',
    FContext.MatchesRefType(MakeRefType(True, MakeConcreteHeapType(1)),
      MakeRefType(False, Concrete)), False);
  ExpectMatch('(ref 1) <= (ref 0)',
    FContext.MatchesRefType(MakeRefType(False, MakeConcreteHeapType(1)),
      MakeRefType(False, Concrete)), True);
  ExpectMatch('(ref null 1) <= (ref null 0)',
    FContext.MatchesRefType(MakeRefType(True, MakeConcreteHeapType(1)),
      MakeRefType(True, Concrete)), True);
end;

procedure TValidatorTypesTests.TestFuncTypeVariance;
begin
  { `match-functype`: parameters CONTRAVARIANT, results COVARIANT, same
    arities. Types: 0 = (func (param anyref) (result eqref)),
    1 = (func (param eqref) (result anyref)), 2 = (func (param anyref)). }
  BuildTypes([$03,
    $60, $01, $6E, $01, $6D,
    $60, $01, $6D, $01, $6E,
    $60, $01, $6E, $00]);

  { 0 <= 1: its parameter is the WEAKER requirement (eqref <= anyref) and
    its result the STRONGER guarantee (eqref <= anyref). }
  ExpectCompMatch(0, 1, True);
  ExpectCompMatch(1, 0, False);
  ExpectCompMatch(0, 0, True);
  { Arity is invariant. }
  ExpectCompMatch(0, 2, False);
  ExpectCompMatch(2, 0, False);
end;

procedure TValidatorTypesTests.TestDeclaredFuncSubtypeIsAccepted;
begin
  { The same variance, declared rather than asked about:
    (type 0 (sub (func (param eqref) (result anyref))))
    (type 1 (sub final 0 (func (param anyref) (result eqref)))). }
  BuildTypes([$02,
    $50, $00, $60, $01, $6D, $01, $6E,
    $4F, $01, $00, $60, $01, $6E, $01, $6D]);

  Expect<Integer>(FContext.TypeCount).ToBe(2);
  ExpectHeapMatch(MakeConcreteHeapType(1), MakeConcreteHeapType(0), True);
  ExpectCompMatch(1, 0, True);
end;

procedure TValidatorTypesTests.TestFieldMutabilityInvariance;
begin
  { `match-fieldtype`: Fieldtype_sub/const is covariant in the storage
    type, Fieldtype_sub/var is invariant. Types:
    0 = (struct anyref), 1 = (struct eqref),
    2 = (struct (mut anyref)), 3 = (struct (mut eqref)). }
  BuildTypes([$04,
    $5F, $01, $6E, $00,
    $5F, $01, $6D, $00,
    $5F, $01, $6E, $01,
    $5F, $01, $6D, $01]);

  ExpectCompMatch(1, 0, True);
  ExpectCompMatch(0, 1, False);

  ExpectCompMatch(3, 2, False);
  ExpectCompMatch(2, 3, False);
  ExpectCompMatch(2, 2, True);
  ExpectCompMatch(3, 3, True);

  { Mutability itself never varies. }
  ExpectCompMatch(3, 1, False);
  ExpectCompMatch(1, 3, False);
end;

procedure TValidatorTypesTests.TestStructWidthAndDepthSubtyping;
begin
  { `match-structtype`: the supertype's fields are a PREFIX of the
    subtype's (width), each matching pairwise (depth). Types:
    0 = (struct i32), 1 = (struct i32 i64), 2 = (struct anyref),
    3 = (struct eqref), 4 = (struct i64), 5 = (array i32). }
  BuildTypes([$06,
    $5F, $01, $7F, $00,
    $5F, $02, $7F, $00, $7E, $00,
    $5F, $01, $6E, $00,
    $5F, $01, $6D, $00,
    $5F, $01, $7E, $00,
    $5E, $7F, $00]);

  ExpectCompMatch(1, 0, True);
  ExpectCompMatch(0, 1, False);
  ExpectCompMatch(3, 2, True);
  ExpectCompMatch(2, 3, False);
  { A prefix of the right length but the wrong type is still no match. }
  ExpectCompMatch(4, 0, False);
  ExpectCompMatch(0, 4, False);
  { Composite kinds never match across (`match-comptype`). }
  ExpectCompMatch(0, 5, False);
  ExpectCompMatch(5, 0, False);
end;

procedure TValidatorTypesTests.TestArraySubtyping;
begin
  { `match-arraytype` is field matching on the element. Types:
    0 = (array eqref), 1 = (array anyref), 2 = (array (mut eqref)),
    3 = (array (mut anyref)), 4 = (array i8), 5 = (array i16),
    6 = (array i32). }
  BuildTypes([$07,
    $5E, $6D, $00,
    $5E, $6E, $00,
    $5E, $6D, $01,
    $5E, $6E, $01,
    $5E, $78, $00,
    $5E, $77, $00,
    $5E, $7F, $00]);

  ExpectCompMatch(0, 1, True);
  ExpectCompMatch(1, 0, False);
  ExpectCompMatch(2, 3, False);
  ExpectCompMatch(3, 2, False);
  ExpectCompMatch(2, 2, True);

  { Packed storage matches only the identical packed type
    (`match-fieldtype`, Packtype_sub). }
  ExpectCompMatch(4, 4, True);
  ExpectCompMatch(4, 5, False);
  ExpectCompMatch(5, 4, False);
  ExpectCompMatch(4, 6, False);
  ExpectCompMatch(6, 4, False);
end;

procedure TValidatorTypesTests.TestTopHeapTypes;
var
  Outcome: string;
begin
  { `appendix/algorithm-types`' top_heap_type. It omits EXN entirely,
    being written for ref.test/ref.cast; wasmlight returns EXN for
    EXN/NOEXN, which `match-heaptype` makes spec-derivable even though
    the algorithm appendix does not spell it. Types:
    0 = (struct), 1 = (func). }
  BuildTypes([$02,
    $5F, $00,
    $60, $00, $00]);

  Expect<Boolean>(FContext.TopHeapType(MakeAbsHeapType(wahI31))
    = wahAny).ToBe(True);
  Expect<Boolean>(FContext.TopHeapType(MakeAbsHeapType(wahNone))
    = wahAny).ToBe(True);
  Expect<Boolean>(FContext.TopHeapType(MakeAbsHeapType(wahNoFunc))
    = wahFunc).ToBe(True);
  Expect<Boolean>(FContext.TopHeapType(MakeAbsHeapType(wahNoExtern))
    = wahExtern).ToBe(True);
  Expect<Boolean>(FContext.TopHeapType(MakeAbsHeapType(wahNoExn))
    = wahExn).ToBe(True);
  Expect<Boolean>(FContext.TopHeapType(MakeConcreteHeapType(0))
    = wahAny).ToBe(True);
  Expect<Boolean>(FContext.TopHeapType(MakeConcreteHeapType(1))
    = wahFunc).ToBe(True);

  { BOT sits below all four hierarchies at once, so it has no top type to
    return. That is an internal error, and it must NOT be reported with a
    canonical prefix — a conformance runner prefix-matches those, and an
    impossible internal state dressed as `unknown type` would read as a
    rejected module. It surfaces as EWasmInternal, never as a validation
    claim about a module. }
  Outcome := 'no error';
  try
    FContext.TopHeapType(MakeBotHeapType);
  except
    on E: EWasmInternal do
      if Copy(E.Message, 1, Length(MSG_UNKNOWN_TYPE)) = MSG_UNKNOWN_TYPE
      then
        Outcome := 'canonical prefix'
      else
        Outcome := 'non-canonical';
  end;
  Expect<string>(Outcome).ToBe('non-canonical');
end;

{ --- negative cases ------------------------------------------------------ }

procedure TValidatorTypesTests.TestRejectsForwardSupertypeAcrossGroups;
begin
  { `valid-rectype` / `Subtype_ok`: a declared supertype must be defined
    before the declaring member. Type 0 names type 1, which is not only
    later but in a LATER GROUP — the case the prose is describing. }
  ExpectInvalid('supertype in a later group', MSG_UNKNOWN_TYPE,
    [$02,
     $50, $01, $01, $60, $00, $00,
     $4F, $00, $60, $00, $00]);
end;

procedure TValidatorTypesTests.TestRejectsSupertypeIndexOutOfRange;
begin
  ExpectInvalid('supertype index past the type space', MSG_UNKNOWN_TYPE,
    [$01, $50, $01, $05, $60, $00, $00]);
end;

procedure TValidatorTypesTests.TestAcceptsSupertypeInsideOwnGroup;
begin
  { A supertype may be an EARLIER MEMBER OF THE DECLARING MEMBER'S OWN
    recursion group. `valid-rectype`'s prose ("a previously defined
    types") reads as "before the group", but the formal rules it cites
    say otherwise: `Rectype_ok/cons` validates the head at OK(x) and the
    tail at OK(x+1), so the index advances per member, and `Subtype_ok`'s
    side condition `y < x_0` therefore bounds at the DECLARING member.
    `test/core/gc/type-subtyping.wast` asserts as valid a three-member
    group whose second and third members subtype the ones before them.

      (rec (type 0 (sub    (func)))
           (type 1 (sub 0  (func))))

    Encoded: one rec group ($4E) of two members, each $50 (sub,
    non-final) with a supertype vector, then an empty functype. }
  BuildTypes([$01, $4E, $02,
    $50, $00, $60, $00, $00,
    $50, $01, $00, $60, $00, $00]);

  Expect<Integer>(FContext.TypeCount).ToBe(2);
  Expect<Integer>(FContext.GroupCount).ToBe(1);
  Expect<Integer>(FContext.CanonTypeCount).ToBe(2);

  { The display is what makes this more than "it did not raise": an
    own-group supertype must extend the chain by one exactly as a
    cross-group one does. }
  Expect<Int64>(Int64(FContext.CanonDepth(FContext.CanonIdOf(0)))).ToBe(0);
  Expect<Int64>(Int64(FContext.CanonDepth(FContext.CanonIdOf(1)))).ToBe(1);
  ExpectHeapMatch(MakeConcreteHeapType(1), MakeConcreteHeapType(0), True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeConcreteHeapType(1), False);
end;

procedure TValidatorTypesTests.TestRejectsSelfAndForwardSupertypeInOwnGroup;
begin
  { The bound moved from the group's first index to the DECLARING
    member's, which keeps out exactly the two cases that would make the
    hierarchy cyclic. Type 0 naming ITSELF as its supertype. }
  ExpectInvalid('supertype naming the declaring type itself',
    MSG_UNKNOWN_TYPE,
    [$01, $4E, $02,
     $50, $01, $00, $60, $00, $00,
     $50, $00, $60, $00, $00]);
end;

procedure TValidatorTypesTests.TestRejectsForwardSupertypeInOwnGroup;
begin
  { Type 0 naming type 1, a LATER member of its own group. }
  ExpectInvalid('supertype later in the declaring group', MSG_UNKNOWN_TYPE,
    [$01, $4E, $02,
     $50, $01, $01, $60, $00, $00,
     $50, $00, $60, $00, $00]);
end;

procedure TValidatorTypesTests.TestOwnGroupSupertypesAreAlphaEquivalent;
begin
  { An own-group supertype is as POSITION-DEPENDENT as an own-group field
    reference, so the key must roll it up rec-relatively
    (`aux-roll-rectype`, `syntax-rectypeidx`) like any other type use. Two
    spellings of the same pair at different type indices:

      (rec (type 0 (sub (func))) (type 1 (sub 0 (func))))
      (rec (type 2 (sub (func))) (type 3 (sub 2 (func))))

    If the supertype list were serialised by raw index — or by canonical
    id, which is not even available for an own-group member at
    serialisation time — the second group would key differently and
    intern as a fresh pair. }
  BuildTypes([$02,
    $4E, $02, $50, $00, $60, $00, $00, $50, $01, $00, $60, $00, $00,
    $4E, $02, $50, $00, $60, $00, $00, $50, $01, $02, $60, $00, $00]);

  Expect<Integer>(FContext.TypeCount).ToBe(4);
  Expect<Integer>(FContext.GroupCount).ToBe(2);
  Expect<Integer>(FContext.CanonTypeCount).ToBe(2);
  Expect<Int64>(CanonId(2)).ToBe(CanonId(0));
  Expect<Int64>(CanonId(3)).ToBe(CanonId(1));
  Expect<Boolean>(CanonId(0) = CanonId(1)).ToBe(False);

  { Subtyping crosses the two spellings, which is the observable
    consequence of interning them together. }
  ExpectHeapMatch(MakeConcreteHeapType(3), MakeConcreteHeapType(0), True);
  ExpectHeapMatch(MakeConcreteHeapType(1), MakeConcreteHeapType(2), True);
  ExpectHeapMatch(MakeConcreteHeapType(0), MakeConcreteHeapType(3), False);

  { The two groups share a canonical base, which is the interning itself
    rather than a consequence of it — Track D re-interns these keys into
    an engine-wide table and must reach the same answer. }
  Expect<Boolean>(FContext.GroupBase(0) = FContext.GroupBase(1)).ToBe(True);
end;

procedure TValidatorTypesTests.TestRejectsFinalSupertype;
begin
  { `syntax-final`: a final type prevents further subtyping. }
  ExpectInvalid('supertype declared final', MSG_SUB_TYPE,
    [$02,
     $4F, $00, $60, $00, $00,
     $50, $01, $00, $60, $00, $00]);
end;

procedure TValidatorTypesTests.TestRejectsCompTypeMismatchAgainstSupertype;
begin
  { A struct never matches a func (`match-comptype`). }
  ExpectInvalid('struct declaring a func supertype', MSG_SUB_TYPE,
    [$02,
     $50, $00, $60, $00, $00,
     $4F, $01, $00, $5F, $00]);

  { Same kind, wrong field: (struct i64) does not match (struct i32). }
  ExpectInvalid('field type differs from the supertype''s', MSG_SUB_TYPE,
    [$02,
     $50, $00, $5F, $01, $7F, $00,
     $4F, $01, $00, $5F, $01, $7E, $00]);

  { Width subtyping runs one way only: a subtype may not drop a field. }
  ExpectInvalid('subtype narrower than its supertype', MSG_SUB_TYPE,
    [$02,
     $50, $00, $5F, $02, $7F, $00, $7E, $00,
     $4F, $01, $00, $5F, $01, $7F, $00]);

  { Reversed func variance: (param eqref)(result anyref) is NOT below
    (param anyref)(result eqref). }
  ExpectInvalid('func variance reversed', MSG_SUB_TYPE,
    [$02,
     $50, $00, $60, $01, $6E, $01, $6D,
     $4F, $01, $00, $60, $01, $6D, $01, $6E]);

  { A mutable field is invariant, so widening it is not subtyping. }
  ExpectInvalid('mutable field widened', MSG_SUB_TYPE,
    [$02,
     $50, $00, $5F, $01, $6E, $01,
     $4F, $01, $00, $5F, $01, $6D, $01]);
end;

procedure TValidatorTypesTests.TestRejectsTooManySupertypes;
begin
  { `valid-rectype`: "Future versions of WebAssembly may allow more than
    one supertype" — at the pinned commit, one is the maximum. The binary
    grammar encodes a vector, so this can only be a validation rule. }
  ExpectInvalid('two declared supertypes', MSG_SUB_TYPE,
    [$02,
     $50, $00, $60, $00, $00,
     $50, $02, $00, $00, $60, $00, $00]);
end;

procedure TValidatorTypesTests.TestRejectsForwardTypeReferenceAcrossGroups;
begin
  { A concrete heap type may name its own group or an earlier one, never a
    later one — that is what recursion groups are for. }
  ExpectInvalid('struct field naming a later group', MSG_UNKNOWN_TYPE,
    [$02,
     $5F, $01, $63, $01, $00,
     $60, $00, $00]);

  ExpectInvalid('func parameter naming a later group', MSG_UNKNOWN_TYPE,
    [$02,
     $60, $01, $63, $01, $00,
     $60, $00, $00]);

  ExpectInvalid('array element naming a later group', MSG_UNKNOWN_TYPE,
    [$02,
     $5E, $63, $01, $00,
     $60, $00, $00]);
end;

procedure TValidatorTypesTests.TestRejectsOutOfRangeTypeReference;
begin
  ExpectInvalid('field naming a type past the type space',
    MSG_UNKNOWN_TYPE, [$01, $5F, $01, $63, $09, $00]);
  ExpectInvalid('func result naming a type past the type space',
    MSG_UNKNOWN_TYPE, [$01, $60, $00, $01, $64, $09]);
end;

procedure TValidatorTypesTests.TestUnknownTypeIndexLookup;
var
  Outcome: string;
begin
  { The lookup itself is the chokepoint every later unit's type-index
    check goes through, so it raises the same prefix. }
  BuildTypes([$01, $60, $00, $00]);

  Outcome := 'ACCEPTED';
  try
    Outcome := 'ACCEPTED: ' + IntToStr(Int64(FContext.CanonIdOf(5)));
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_UNKNOWN_TYPE);
  end;

  Expect<string>('CanonIdOf(5) -> ' + Outcome)
    .ToBe('CanonIdOf(5) -> rejected: ' + MSG_UNKNOWN_TYPE);
end;

procedure TValidatorTypesTests.SetupTests;
begin
  Test('alpha-renamed rec groups share canonical ids',
    TestAlphaRenamedGroupsShareCanonicalIds);
  Test('structurally different groups stay distinct',
    TestDistinctGroupsGetDistinctCanonicalIds);
  Test('identical singleton groups are interned',
    TestIdenticalSingletonGroupsAreInterned);
  Test('abstract aggregate hierarchy is ordered',
    TestAbstractHierarchyOrdering);
  Test('the four abstract hierarchies are disjoint',
    TestAbstractHierarchiesAreDisjoint);
  Test('each hierarchy has its own bottom', TestBottomHeapTypes);
  Test('bot matches every value type',
    TestBottomValueTypeMatchesEverything);
  Test('concrete types sit under their composite kind',
    TestConcreteVersusAbstract);
  Test('declared supertype chains give a display',
    TestDeclaredSubtypeChain);
  Test('reference nullability is one-way', TestReferenceNullability);
  Test('func params are contravariant and results covariant',
    TestFuncTypeVariance);
  Test('a correctly varying declared func subtype is accepted',
    TestDeclaredFuncSubtypeIsAccepted);
  Test('mutable fields are invariant', TestFieldMutabilityInvariance);
  Test('struct width and depth subtyping',
    TestStructWidthAndDepthSubtyping);
  Test('array element subtyping and packed storage',
    TestArraySubtyping);
  Test('top heap types', TestTopHeapTypes);
  Test('rejects a supertype in a later group',
    TestRejectsForwardSupertypeAcrossGroups);
  Test('rejects a supertype index out of range',
    TestRejectsSupertypeIndexOutOfRange);
  Test('accepts an earlier member of the declaring group as supertype',
    TestAcceptsSupertypeInsideOwnGroup);
  Test('own-group supertypes serialise alpha-equivalently',
    TestOwnGroupSupertypesAreAlphaEquivalent);
  Test('rejects a type declaring itself as its supertype',
    TestRejectsSelfAndForwardSupertypeInOwnGroup);
  Test('rejects a supertype later in the declaring group',
    TestRejectsForwardSupertypeInOwnGroup);
  Test('rejects subtyping a final type', TestRejectsFinalSupertype);
  Test('rejects a composite type that does not match its supertype',
    TestRejectsCompTypeMismatchAgainstSupertype);
  Test('rejects more than one supertype', TestRejectsTooManySupertypes);
  Test('rejects a type reference into a later group',
    TestRejectsForwardTypeReferenceAcrossGroups);
  Test('rejects a type reference past the type space',
    TestRejectsOutOfRangeTypeReference);
  Test('unknown type index lookup raises the canonical prefix',
    TestUnknownTypeIndexLookup);
end;

begin
  TestRunnerProgram.AddSuite(
    TValidatorTypesTests.Create('Wasm.Validator.Types'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
