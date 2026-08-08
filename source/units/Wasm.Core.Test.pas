{ Unit suite for Wasm.Core's type vocabulary and section-order table.

  The cases that matter here are the two the model got wrong before:
  type codes are signed LEB128 small negatives sharing an encoding space
  with positive type indices, and section ids are not the encoding order. }
program Wasm.Core.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core;

type
  TCoreTests = class(TTestSuite)
  private
    { Describe() for the value type at ACode, or 'invalid' when the code
      is not a self-contained value type. }
    function DescribeCode(const ACode: Int64): string;
  public
    procedure SetupTests; override;

    procedure TestNumTypeCodes;
    procedure TestVectorTypeCode;
    procedure TestShortFormRefTypeCodes;
    procedure TestLongFormCodesAreNotSelfContained;
    procedure TestTypeIndicesNeverCollideWithTypeCodes;
    procedure TestRefTypeDescribe;
    procedure TestHeapTypeDescribe;
    procedure TestSectionOrderIsNotIdOrder;
    procedure TestSectionOrderIsATotalOrder;
    procedure TestCustomSectionIsUnordered;
    procedure TestSectionIdNaming;
    procedure TestLimitsDescribe;
    procedure TestGlobalTypeDescribe;
    procedure TestTableAndMemTypeDescribe;
    procedure TestStorageAndFieldTypeDescribe;
    procedure TestCompositeTypeCodes;
    procedure TestExternKindOrdinals;
    procedure TestExternalTypeConstructors;
    procedure TestCompTypeConstructors;
  end;

function TCoreTests.DescribeCode(const ACode: Int64): string;
var
  ValueType: TWasmValueType;
begin
  if TryDecodeValueType(ACode, ValueType) then
    Result := ValueType.Describe
  else
    Result := 'invalid';
end;

procedure TCoreTests.TestNumTypeCodes;
begin
  { -1..-4, which a hex dump shows as $7F..$7C. }
  Expect<string>(DescribeCode(-1)).ToBe('i32');
  Expect<string>(DescribeCode(-2)).ToBe('i64');
  Expect<string>(DescribeCode(-3)).ToBe('f32');
  Expect<string>(DescribeCode(-4)).ToBe('f64');
end;

procedure TCoreTests.TestVectorTypeCode;
begin
  Expect<string>(DescribeCode(TYPE_CODE_V128)).ToBe('v128');
  Expect<Int64>(TYPE_CODE_V128).ToBe(-5);
end;

procedure TCoreTests.TestShortFormRefTypeCodes;
begin
  { The short form is a bare abstract heap type standing for a NULLABLE
    reference to it, which is why these spell as `<ht>ref`. }
  Expect<string>(DescribeCode(-16)).ToBe('funcref');
  Expect<string>(DescribeCode(-17)).ToBe('externref');
  Expect<string>(DescribeCode(-18)).ToBe('anyref');
  Expect<string>(DescribeCode(-19)).ToBe('eqref');
  Expect<string>(DescribeCode(-20)).ToBe('i31ref');
  Expect<string>(DescribeCode(-21)).ToBe('structref');
  Expect<string>(DescribeCode(-22)).ToBe('arrayref');
  Expect<string>(DescribeCode(-23)).ToBe('exnref');

  { The four bottom types do NOT spell as `no*ref`. Deriving a short-form
    name by appending 'ref' to the heap type's name gets exactly these
    four wrong, which is why the spelling is a table. }
  Expect<string>(DescribeCode(-15)).ToBe('nullref');         { none }
  Expect<string>(DescribeCode(-14)).ToBe('nullexternref');   { noextern }
  Expect<string>(DescribeCode(-13)).ToBe('nullfuncref');     { nofunc }
  Expect<string>(DescribeCode(-12)).ToBe('nullexnref');      { noexn }
end;

procedure TCoreTests.TestLongFormCodesAreNotSelfContained;
begin
  { $63 / $64 introduce a reference type whose heap type follows, so they
    cannot be resolved from a code alone — the type-section decoder reads
    the heap type. Reporting them as valid value types here would be the
    bug this test exists to prevent. }
  Expect<string>(DescribeCode(TYPE_CODE_REF_NULL)).ToBe('invalid');
  Expect<string>(DescribeCode(TYPE_CODE_REF)).ToBe('invalid');
  Expect<Int64>(TYPE_CODE_REF_NULL).ToBe(-29);
  Expect<Int64>(TYPE_CODE_REF).ToBe(-28);
end;

procedure TCoreTests.TestTypeIndicesNeverCollideWithTypeCodes;
var
  I: Integer;
  Num: TWasmNumType;
  Abs: TWasmAbsHeapType;
begin
  { The reason the encoding is signed at all: type codes are negative and
    type indices are not, so a heap type position can hold either without
    ambiguity. No non-negative value may decode as a type. }
  for I := 0 to 64 do
  begin
    Expect<string>(DescribeCode(I)).ToBe('invalid');
    Expect<Boolean>(TryDecodeNumType(I, Num)).ToBe(False);
    Expect<Boolean>(TryDecodeAbsHeapType(I, Abs)).ToBe(False);
  end;

  { And nothing below the abstract heap type range decodes either. }
  Expect<string>(DescribeCode(-24)).ToBe('invalid');
  Expect<string>(DescribeCode(-100)).ToBe('invalid');
end;

procedure TCoreTests.TestRefTypeDescribe;
begin
  Expect<string>(MakeRefType(True, MakeAbsHeapType(wahFunc)).Describe)
    .ToBe('funcref');
  { Non-null references have no short spelling. }
  Expect<string>(MakeRefType(False, MakeAbsHeapType(wahFunc)).Describe)
    .ToBe('(ref func)');
  { Concrete heap types are type indices, in either nullability. }
  Expect<string>(MakeRefType(True, MakeConcreteHeapType(7)).Describe)
    .ToBe('(ref null 7)');
  Expect<string>(MakeRefType(False, MakeConcreteHeapType(7)).Describe)
    .ToBe('(ref 7)');
end;

procedure TCoreTests.TestHeapTypeDescribe;
begin
  Expect<Boolean>(MakeAbsHeapType(wahExtern).IsAbstract).ToBe(True);
  Expect<string>(MakeAbsHeapType(wahExtern).Describe).ToBe('extern');
  Expect<Boolean>(MakeConcreteHeapType(3).IsAbstract).ToBe(False);
  Expect<string>(MakeConcreteHeapType(3).Describe).ToBe('3');
end;

procedure TCoreTests.TestSectionOrderIsNotIdOrder;
begin
  { The two deviations, asserted directly so a future edit to the table
    that "tidies" it back into id order fails here. }
  Expect<Boolean>(SectionOrderPosition(Ord(wsDataCount))
    < SectionOrderPosition(Ord(wsCode))).ToBe(True);
  Expect<Boolean>(SectionOrderPosition(Ord(wsTag))
    < SectionOrderPosition(Ord(wsGlobal))).ToBe(True);
  Expect<Boolean>(SectionOrderPosition(Ord(wsMemory))
    < SectionOrderPosition(Ord(wsTag))).ToBe(True);
end;

procedure TCoreTests.TestSectionOrderIsATotalOrder;
var
  Id, Other: Integer;
  Position: Integer;
  Seen: array[1..13] of Boolean;
begin
  { Every known non-custom section occupies exactly one position in 1..13.
    A duplicated position would silently make two sections mutually
    exclusive in the decoder. }
  for Id := 1 to 13 do
    Seen[Id] := False;

  for Id := 1 to 13 do
  begin
    Position := SectionOrderPosition(Id);
    Expect<Boolean>((Position >= 1) and (Position <= 13)).ToBe(True);
    Expect<Boolean>(Seen[Position]).ToBe(False);
    Seen[Position] := True;
  end;

  for Other := 1 to 13 do
    Expect<Boolean>(Seen[Other]).ToBe(True);
end;

procedure TCoreTests.TestCustomSectionIsUnordered;
begin
  Expect<Integer>(SectionOrderPosition(Ord(wsCustom))).ToBe(0);
  { Unknown ids are not ordered either; the decoder rejects them before
    ordering is ever consulted. }
  Expect<Integer>(SectionOrderPosition(200)).ToBe(0);
end;

procedure TCoreTests.TestSectionIdNaming;
begin
  Expect<string>(SectionIdName(Ord(wsType))).ToBe('type');
  Expect<string>(SectionIdName(Ord(wsDataCount))).ToBe('data count');
  Expect<string>(SectionIdName(Ord(wsTag))).ToBe('tag');
  Expect<Boolean>(IsKnownSectionId(13)).ToBe(True);
  Expect<Boolean>(IsKnownSectionId(14)).ToBe(False);
  Expect<string>(SectionIdName(14)).ToBe('unknown(14)');
end;

procedure TCoreTests.TestLimitsDescribe;
begin
  { Text format: `addrtype? min max?` — i32 is the default address type
    and is left unmarked; only i64 is spelled out. }
  Expect<string>(MakeLimits(watI32, 1).Describe).ToBe('1');
  Expect<string>(MakeLimitsWithMax(watI32, 1, 2).Describe).ToBe('1 2');
  Expect<string>(MakeLimits(watI64, 0).Describe).ToBe('i64 0');
  Expect<string>(MakeLimitsWithMax(watI64, 1, 2).Describe).ToBe('i64 1 2');
  { The bounds are u64-valued for both address types; a value above the
    u32 range must render, not wrap. }
  Expect<string>(MakeLimits(watI32, UInt64(1) shl 32).Describe)
    .ToBe('4294967296');
end;

procedure TCoreTests.TestGlobalTypeDescribe;
begin
  { Immutable is the unmarked case; only `mut` gets parentheses. }
  Expect<string>(MakeGlobalType(False, MakeNumValueType(wntI32)).Describe)
    .ToBe('i32');
  Expect<string>(MakeGlobalType(True, MakeNumValueType(wntI32)).Describe)
    .ToBe('(mut i32)');
  Expect<string>(MakeGlobalType(True,
    MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahFunc)))).Describe)
    .ToBe('(mut funcref)');
end;

procedure TCoreTests.TestTableAndMemTypeDescribe;
begin
  { `tabletype ::= addrtype? limits reftype` — element type last. }
  Expect<string>(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)),
    MakeLimitsWithMax(watI32, 0, 10)).Describe).ToBe('0 10 funcref');
  Expect<string>(MakeTableType(
    MakeRefType(True, MakeConcreteHeapType(5)),
    MakeLimits(watI64, 1)).Describe).ToBe('i64 1 (ref null 5)');
  Expect<string>(MakeMemType(MakeLimitsWithMax(watI32, 1, 2)).Describe)
    .ToBe('1 2');
  Expect<string>(MakeMemType(MakeLimits(watI64, 0)).Describe)
    .ToBe('i64 0');
end;

procedure TCoreTests.TestStorageAndFieldTypeDescribe;
begin
  Expect<string>(MakePackedStorageType(wpkI8).Describe).ToBe('i8');
  Expect<string>(MakePackedStorageType(wpkI16).Describe).ToBe('i16');
  Expect<string>(MakeValueStorageType(MakeNumValueType(wntF64)).Describe)
    .ToBe('f64');
  Expect<string>(
    MakeFieldType(True, MakePackedStorageType(wpkI8)).Describe)
    .ToBe('(mut i8)');
  Expect<string>(
    MakeFieldType(False, MakeValueStorageType(MakeNumValueType(wntI32)))
    .Describe).ToBe('i32');
end;

procedure TCoreTests.TestCompositeTypeCodes;
begin
  { The rec/sub/comptype/packed codes as SIGNED values ($4E.. $78 in a
    hex dump). $4F is FINAL and $50 non-final — the transposable pair. }
  Expect<Int64>(TYPE_CODE_REC).ToBe(-50);        { $4E }
  Expect<Int64>(TYPE_CODE_SUB_FINAL).ToBe(-49);  { $4F }
  Expect<Int64>(TYPE_CODE_SUB).ToBe(-48);        { $50 }
  Expect<Int64>(TYPE_CODE_ARRAY).ToBe(-34);      { $5E }
  Expect<Int64>(TYPE_CODE_STRUCT).ToBe(-33);     { $5F }
  Expect<Int64>(TYPE_CODE_FUNC).ToBe(-32);       { $60 }
  Expect<Int64>(TYPE_CODE_I16).ToBe(-9);         { $77 }
  Expect<Int64>(TYPE_CODE_I8).ToBe(-8);          { $78 }
end;

procedure TCoreTests.TestExternKindOrdinals;
begin
  { The ordinals ARE the import/export description discriminator bytes. }
  Expect<Integer>(Ord(wxkFunc)).ToBe(0);
  Expect<Integer>(Ord(wxkTable)).ToBe(1);
  Expect<Integer>(Ord(wxkMem)).ToBe(2);
  Expect<Integer>(Ord(wxkGlobal)).ToBe(3);
  Expect<Integer>(Ord(wxkTag)).ToBe(4);
end;

procedure TCoreTests.TestExternalTypeConstructors;
var
  Limits: TWasmLimits;
begin
  Limits := MakeLimitsWithMax(watI64, 3, 7);
  Expect<Boolean>(Limits.AddrType = watI64).ToBe(True);
  Expect<Boolean>(Limits.HasMax).ToBe(True);
  Expect<Int64>(Int64(Limits.Min)).ToBe(3);
  Expect<Int64>(Int64(Limits.Max)).ToBe(7);

  Limits := MakeLimits(watI32, 1);
  Expect<Boolean>(Limits.HasMax).ToBe(False);
  Expect<Int64>(Int64(Limits.Max)).ToBe(0);

  Expect<Int64>(Int64(MakeTagType(9).TypeIndex)).ToBe(9);
  Expect<Boolean>(MakeGlobalType(True, MakeVecValueType).Mut).ToBe(True);
  Expect<Boolean>(MakePackedStorageType(wpkI16).IsPacked).ToBe(True);
  Expect<Boolean>(
    MakeValueStorageType(MakeVecValueType).IsPacked).ToBe(False);
end;

procedure TCoreTests.TestCompTypeConstructors;
var
  Func: TWasmFuncType;
  Struct: TWasmStructType;
  Arr: TWasmArrayType;
  Comp: TWasmCompType;
begin
  SetLength(Func.Params, 2);
  Func.Params[0] := MakeNumValueType(wntI32);
  Func.Params[1] := MakeNumValueType(wntI64);
  SetLength(Func.Results, 1);
  Func.Results[0] := MakeNumValueType(wntF64);
  Comp := MakeFuncCompType(Func);
  Expect<Boolean>(Comp.Kind = wckFunc).ToBe(True);
  Expect<Integer>(Length(Comp.Func.Params)).ToBe(2);
  Expect<string>(Comp.Func.Results[0].Describe).ToBe('f64');
  Expect<Integer>(Length(Comp.Struct.Fields)).ToBe(0);

  SetLength(Struct.Fields, 1);
  Struct.Fields[0] := MakeFieldType(True, MakePackedStorageType(wpkI8));
  Comp := MakeStructCompType(Struct);
  Expect<Boolean>(Comp.Kind = wckStruct).ToBe(True);
  Expect<string>(Comp.Struct.Fields[0].Describe).ToBe('(mut i8)');
  Expect<Integer>(Length(Comp.Func.Params)).ToBe(0);

  Arr.Elem := MakeFieldType(False, MakePackedStorageType(wpkI16));
  Comp := MakeArrayCompType(Arr);
  Expect<Boolean>(Comp.Kind = wckArray).ToBe(True);
  Expect<string>(Comp.Arr.Elem.Describe).ToBe('i16');
end;

procedure TCoreTests.SetupTests;
begin
  Test('number type codes', TestNumTypeCodes);
  Test('vector type code', TestVectorTypeCode);
  Test('short-form reference type codes', TestShortFormRefTypeCodes);
  Test('long-form reference codes are not self-contained',
    TestLongFormCodesAreNotSelfContained);
  Test('type indices never collide with type codes',
    TestTypeIndicesNeverCollideWithTypeCodes);
  Test('reference type spelling', TestRefTypeDescribe);
  Test('heap type spelling', TestHeapTypeDescribe);
  Test('section order is not id order', TestSectionOrderIsNotIdOrder);
  Test('section order is a total order', TestSectionOrderIsATotalOrder);
  Test('custom sections are unordered', TestCustomSectionIsUnordered);
  Test('section id naming', TestSectionIdNaming);
  Test('limits spelling', TestLimitsDescribe);
  Test('global type spelling', TestGlobalTypeDescribe);
  Test('table and memory type spelling', TestTableAndMemTypeDescribe);
  Test('storage and field type spelling', TestStorageAndFieldTypeDescribe);
  Test('composite type codes', TestCompositeTypeCodes);
  Test('extern kind ordinals', TestExternKindOrdinals);
  Test('external type constructors', TestExternalTypeConstructors);
  Test('composite type constructors', TestCompTypeConstructors);
end;

begin
  TestRunnerProgram.AddSuite(TCoreTests.Create('Wasm.Core'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
