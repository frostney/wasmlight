{ Unit suite for Wasm.Wast.Values — the .wast argument/expected-result
  value parser and result comparator (Track E, Wave 5; interp-spec §6).

  The float parser is a known bug farm (subnormals, INT64_MIN, the
  smallest-subnormal rounding boundary, the NaN payload forms), so it is
  tested against exact bit patterns rather than arithmetic values — the
  corpus compares bits, and so does this suite. The comparator is tested on
  each NaN class (canonical / arithmetic), exact int/float, and reference
  identity, both the match and the mismatch. }
program Wasm.Wast.Values.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Runtime.Values,
  Wasm.Wast,
  Wasm.Wast.Values;

type
  TWastValuesTests = class(TTestSuite)
  private
    { Parse ANode-text into a single value/matcher via the real s-expr
      parser, so WastParseVal is exercised end to end. }
    function ParseVal(const AText: string): TWastVal;
    function I32(const AText: string): UInt32;
    function I64(const AText: string): UInt64;
    function F32(const AText: string): UInt32;
    function F64(const AText: string): UInt64;
  public
    procedure SetupTests; override;

    { integer literals }
    procedure TestInt32Decimal;
    procedure TestInt32Hex;
    procedure TestInt32NegativeWraps;
    procedure TestInt32Underscores;
    procedure TestInt64FullRange;
    procedure TestInt64Min;
    procedure TestInt64HexMax;

    { float literals — exact bits }
    procedure TestF32One;
    procedure TestF32NegZero;
    procedure TestF32Inf;
    procedure TestF32NanCanonical;
    procedure TestF32NanPayload;
    procedure TestF32HexBasic;
    procedure TestF32SmallestSubnormal;
    procedure TestF32SubnormalRoundToEven;
    procedure TestF32Max;
    procedure TestF32OverflowToInf;
    procedure TestF32DecimalHalf;
    procedure TestF64One;
    procedure TestF64Half;
    procedure TestF64SmallestSubnormal;
    procedure TestF64HexFraction;
    procedure TestF64NegInf;

    { WastParseVal categories }
    procedure TestParseValI32;
    procedure TestParseValNanCanonicalMatcher;
    procedure TestParseValRefExternId;
    procedure TestParseValRefNull;

    { v128.const parsing → exact 16 bytes }
    procedure TestParseV128I8x16Bytes;
    procedure TestParseV128I32x4Lanes;
    procedure TestParseV128F64x2Lanes;
    procedure TestParseV128F32x4NanLaneKinds;
    procedure TestParseV128WrongLaneCountRaises;

    { comparator }
    procedure TestCompareExactI32;
    procedure TestCompareExactF32NegZero;
    procedure TestCompareNanCanonicalMatch;
    procedure TestCompareNanCanonicalRejectsPayload;
    procedure TestCompareNanArithmeticMatch;
    procedure TestCompareNanArithmeticRejectsInf;
    procedure TestCompareRefNull;
    procedure TestCompareRefExternIdentity;
    procedure TestCompareRefExternMismatch;
    procedure TestCompareRefExternBareAnyNonNull;

    { v128 per-lane comparator + (either) }
    procedure TestVecExactMatch;
    procedure TestVecOneNanCanonicalLaneMatches;
    procedure TestVecWrongLaneFails;
    procedure TestVecNanArithmeticLaneClass;
    procedure TestEitherMatchesAnyAlternative;
    procedure TestEitherFailsWhenNoneMatch;
  end;

function TWastValuesTests.ParseVal(const AText: string): TWastVal;
var
  Script: TWastScript;
begin
  Script := ParseWastScript(AText);
  try
    Result := WastParseVal(Script[0].Node);
  finally
    Script.Free;
  end;
end;

function TWastValuesTests.I32(const AText: string): UInt32;
begin
  if not WastParseInt32(AText, Result) then
    raise EWasmError.CreateFmt('i32 parse failed: %s', [AText]);
end;

function TWastValuesTests.I64(const AText: string): UInt64;
begin
  if not WastParseInt64(AText, Result) then
    raise EWasmError.CreateFmt('i64 parse failed: %s', [AText]);
end;

function TWastValuesTests.F32(const AText: string): UInt32;
begin
  if not WastParseF32Bits(AText, Result) then
    raise EWasmError.CreateFmt('f32 parse failed: %s', [AText]);
end;

function TWastValuesTests.F64(const AText: string): UInt64;
begin
  if not WastParseF64Bits(AText, Result) then
    raise EWasmError.CreateFmt('f64 parse failed: %s', [AText]);
end;

{ --- integers ------------------------------------------------------------ }

procedure TWastValuesTests.TestInt32Decimal;
begin
  Expect<UInt32>(I32('305419896')).ToBe(UInt32($12345678));
end;

procedure TWastValuesTests.TestInt32Hex;
begin
  Expect<UInt32>(I32('0x12345678')).ToBe(UInt32($12345678));
end;

procedure TWastValuesTests.TestInt32NegativeWraps;
begin
  { -1 and 4294967295 both spell the all-ones i32 pattern. }
  Expect<UInt32>(I32('-1')).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(I32('4294967295')).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(I32('-2147483648')).ToBe(UInt32($80000000));
end;

procedure TWastValuesTests.TestInt32Underscores;
begin
  Expect<UInt32>(I32('1_000_000')).ToBe(UInt32(1000000));
end;

procedure TWastValuesTests.TestInt64FullRange;
begin
  Expect<UInt64>(I64('-1')).ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(I64('18446744073709551615'))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF));
end;

procedure TWastValuesTests.TestInt64Min;
begin
  { INT64_MIN — the classic off-by-one bug farm. }
  Expect<UInt64>(I64('-9223372036854775808'))
    .ToBe(UInt64($8000000000000000));
end;

procedure TWastValuesTests.TestInt64HexMax;
begin
  Expect<UInt64>(I64('0xffffffffffffffff'))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(I64('0x8000000000000000'))
    .ToBe(UInt64($8000000000000000));
end;

{ --- floats: exact bits -------------------------------------------------- }

procedure TWastValuesTests.TestF32One;
begin
  Expect<UInt32>(F32('1.0')).ToBe(UInt32($3F800000));
  Expect<UInt32>(F32('-1.0')).ToBe(UInt32($BF800000));
end;

procedure TWastValuesTests.TestF32NegZero;
begin
  Expect<UInt32>(F32('-0.0')).ToBe(UInt32($80000000));
  Expect<UInt32>(F32('0.0')).ToBe(UInt32($00000000));
end;

procedure TWastValuesTests.TestF32Inf;
begin
  Expect<UInt32>(F32('inf')).ToBe(UInt32($7F800000));
  Expect<UInt32>(F32('-inf')).ToBe(UInt32($FF800000));
end;

procedure TWastValuesTests.TestF32NanCanonical;
begin
  Expect<UInt32>(F32('nan')).ToBe(UInt32($7FC00000));
  Expect<UInt32>(F32('-nan')).ToBe(UInt32($FFC00000));
end;

procedure TWastValuesTests.TestF32NanPayload;
begin
  { nan:0x200000 is the "plain snan" payload float_literals uses. }
  Expect<UInt32>(F32('nan:0x200000')).ToBe(UInt32($7FA00000));
  Expect<UInt32>(F32('nan:0x400000')).ToBe(UInt32($7FC00000));
end;

procedure TWastValuesTests.TestF32HexBasic;
begin
  Expect<UInt32>(F32('0x1p0')).ToBe(UInt32($3F800000));
  { 0x1.8 = 1.5, ·2^1 = 3.0 }
  Expect<UInt32>(F32('0x1.8p1')).ToBe(UInt32($40400000));
end;

procedure TWastValuesTests.TestF32SmallestSubnormal;
begin
  Expect<UInt32>(F32('0x1p-149')).ToBe(UInt32($00000001));
end;

procedure TWastValuesTests.TestF32SubnormalRoundToEven;
begin
  { 0x1p-150 is exactly half the smallest subnormal — ties to even → +0. }
  Expect<UInt32>(F32('0x1p-150')).ToBe(UInt32($00000000));
  { 0x1.8p-150 = 0.75·2^-149 > half → rounds up to the smallest subnormal. }
  Expect<UInt32>(F32('0x1.8p-150')).ToBe(UInt32($00000001));
end;

procedure TWastValuesTests.TestF32Max;
begin
  Expect<UInt32>(F32('0x1.fffffep127')).ToBe(UInt32($7F7FFFFF));
end;

procedure TWastValuesTests.TestF32OverflowToInf;
begin
  Expect<UInt32>(F32('0x1p128')).ToBe(UInt32($7F800000));
end;

procedure TWastValuesTests.TestF32DecimalHalf;
begin
  Expect<UInt32>(F32('0.5')).ToBe(UInt32($3F000000));
end;

procedure TWastValuesTests.TestF64One;
begin
  Expect<UInt64>(F64('1.0')).ToBe(UInt64($3FF0000000000000));
end;

procedure TWastValuesTests.TestF64Half;
begin
  Expect<UInt64>(F64('0.5')).ToBe(UInt64($3FE0000000000000));
  Expect<UInt64>(F64('2.0')).ToBe(UInt64($4000000000000000));
end;

procedure TWastValuesTests.TestF64SmallestSubnormal;
begin
  Expect<UInt64>(F64('0x1p-1074')).ToBe(UInt64($0000000000000001));
end;

procedure TWastValuesTests.TestF64HexFraction;
begin
  { 0x1.5p3 = (1 + 5/16)·8 = 10.5 }
  Expect<UInt64>(F64('0x1.5p3')).ToBe(UInt64($4025000000000000));
end;

procedure TWastValuesTests.TestF64NegInf;
begin
  Expect<UInt64>(F64('-inf')).ToBe(UInt64($FFF0000000000000));
end;

{ --- WastParseVal categories --------------------------------------------- }

procedure TWastValuesTests.TestParseValI32;
var
  V: TWastVal;
begin
  V := ParseVal('(i32.const 42)');
  Expect<Integer>(Ord(V.Kind)).ToBe(Ord(wvcI32));
  Expect<UInt64>(V.Bits).ToBe(UInt64(42));
end;

procedure TWastValuesTests.TestParseValNanCanonicalMatcher;
var
  V: TWastVal;
begin
  V := ParseVal('(f32.const nan:canonical)');
  Expect<Integer>(Ord(V.Kind)).ToBe(Ord(wvcNanCanonical));
  Expect<Integer>(Ord(V.Width)).ToBe(Ord(wvw32));
end;

procedure TWastValuesTests.TestParseValRefExternId;
var
  V: TWastVal;
begin
  V := ParseVal('(ref.extern 3)');
  Expect<Integer>(Ord(V.Kind)).ToBe(Ord(wvcRefExtern));
  Expect<Boolean>(V.HasId).ToBe(True);
  Expect<UInt32>(V.Id).ToBe(UInt32(3));
end;

procedure TWastValuesTests.TestParseValRefNull;
var
  V: TWastVal;
begin
  V := ParseVal('(ref.null extern)');
  Expect<Integer>(Ord(V.Kind)).ToBe(Ord(wvcRefNull));
end;

{ --- v128.const parsing -------------------------------------------------- }

procedure TWastValuesTests.TestParseV128I8x16Bytes;
var
  V: TWastVal;
  Vec: TWasmV128;
  I: Integer;
  AllExact: Boolean;
begin
  V := ParseVal('(v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)');
  Expect<Integer>(Ord(V.Kind)).ToBe(Ord(wvcV128));
  Expect<Integer>(Ord(V.VecShape)).ToBe(Ord(wvsI8x16));
  Vec := WastValToVec(V);
  AllExact := True;
  for I := 0 to 15 do
    if (Vec.B[I] <> I) or (V.VecLaneKinds[I] <> wlkExact) then
      AllExact := False;
  Expect<Boolean>(AllExact).ToBe(True);
  { -0x80 and 0xFF both fit the i8 union range. }
  V := ParseVal('(v128.const i8x16 -0x80 0xFF 0 0 0 0 0 0 0 0 0 0 0 0 0 0)');
  Vec := WastValToVec(V);
  Expect<UInt32>(UInt32(Vec.B[0])).ToBe(UInt32($80));
  Expect<UInt32>(UInt32(Vec.B[1])).ToBe(UInt32($FF));
end;

procedure TWastValuesTests.TestParseV128I32x4Lanes;
var
  Vec: TWasmV128;
begin
  Vec := WastValToVec(ParseVal('(v128.const i32x4 1 2 0xdeadbeef -1)'));
  Expect<UInt32>(Vec.U32[0]).ToBe(UInt32(1));
  Expect<UInt32>(Vec.U32[1]).ToBe(UInt32(2));
  Expect<UInt32>(Vec.U32[2]).ToBe(UInt32($DEADBEEF));
  Expect<UInt32>(Vec.U32[3]).ToBe(UInt32($FFFFFFFF));
end;

procedure TWastValuesTests.TestParseV128F64x2Lanes;
var
  Vec: TWasmV128;
begin
  Vec := WastValToVec(ParseVal('(v128.const f64x2 1.0 2.0)'));
  Expect<UInt64>(Vec.U64[0]).ToBe(UInt64($3FF0000000000000));
  Expect<UInt64>(Vec.U64[1]).ToBe(UInt64($4000000000000000));
end;

procedure TWastValuesTests.TestParseV128F32x4NanLaneKinds;
var
  V: TWastVal;
begin
  { A single constant mixing two NaN classes with two exact lanes — the
    corpus's simd_f32x4_arith.wast:5292 shape. Each lane's kind is recorded
    independently. }
  V := ParseVal('(v128.const f32x4 nan:canonical nan:arithmetic 6.0 7.0)');
  Expect<Integer>(Ord(V.VecShape)).ToBe(Ord(wvsF32x4));
  Expect<Integer>(Ord(V.VecLaneKinds[0])).ToBe(Ord(wlkNanCanonical));
  Expect<Integer>(Ord(V.VecLaneKinds[1])).ToBe(Ord(wlkNanArithmetic));
  Expect<Integer>(Ord(V.VecLaneKinds[2])).ToBe(Ord(wlkExact));
  Expect<Integer>(Ord(V.VecLaneKinds[3])).ToBe(Ord(wlkExact));
  Expect<UInt64>(V.VecLanes[2]).ToBe(UInt64($40C00000));   { 6.0f }
end;

procedure TWastValuesTests.TestParseV128WrongLaneCountRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ParseVal('(v128.const i32x4 1 2 3)');   { needs 4 lanes }
  except
    on E: EWastValueError do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

{ --- comparator ---------------------------------------------------------- }

function MakeI32Expect(const ABits: UInt32): TWastVal;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := wvcI32;
  Result.Width := wvw32;
  Result.Bits := UInt64(ABits);
end;

function MakeF32Expect(const ABits: UInt32): TWastVal;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := wvcF32;
  Result.Width := wvw32;
  Result.Bits := UInt64(ABits);
end;

function MakeNanExpect(const AKind: TWastValKind;
  const AWidth: TWastValWidth): TWastVal;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := AKind;
  Result.Width := AWidth;
end;

function MakeRefExpect(const AKind: TWastValKind): TWastVal;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := AKind;
end;

function ActualBits(const ABits: UInt64): TWasmValue;
begin
  Result.Bits := ABits;
end;

procedure TWastValuesTests.TestCompareExactI32;
begin
  Expect<Boolean>(WastValMatches(MakeI32Expect($DEADBEEF),
    ActualBits($DEADBEEF), WASM_REF_NULL)).ToBe(True);
  Expect<Boolean>(WastValMatches(MakeI32Expect($DEADBEEF),
    ActualBits($DEADBEEE), WASM_REF_NULL)).ToBe(False);
  { High 32 bits of the slot are ignored for an i32 compare. }
  Expect<Boolean>(WastValMatches(MakeI32Expect($00000007),
    ActualBits((UInt64($FFFFFFFF) shl 32) or UInt64($00000007)),
    WASM_REF_NULL)).ToBe(True);
end;

procedure TWastValuesTests.TestCompareExactF32NegZero;
begin
  { Bitwise: -0.0 is not +0.0. }
  Expect<Boolean>(WastValMatches(MakeF32Expect($00000000),
    ActualBits($80000000), WASM_REF_NULL)).ToBe(False);
  Expect<Boolean>(WastValMatches(MakeF32Expect($80000000),
    ActualBits($80000000), WASM_REF_NULL)).ToBe(True);
end;

procedure TWastValuesTests.TestCompareNanCanonicalMatch;
begin
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanCanonical, wvw32),
    ActualBits($7FC00000), WASM_REF_NULL)).ToBe(True);
  { Negative canonical is still canonical (sign ignored). }
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanCanonical, wvw32),
    ActualBits($FFC00000), WASM_REF_NULL)).ToBe(True);
end;

procedure TWastValuesTests.TestCompareNanCanonicalRejectsPayload;
begin
  { An arithmetic NaN with extra payload bits is NOT canonical. }
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanCanonical, wvw32),
    ActualBits($7FC00001), WASM_REF_NULL)).ToBe(False);
  { A finite value is not canonical either. }
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanCanonical, wvw32),
    ActualBits($3F800000), WASM_REF_NULL)).ToBe(False);
end;

procedure TWastValuesTests.TestCompareNanArithmeticMatch;
begin
  { Canonical satisfies the arithmetic class (payload MSB set). }
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanArithmetic, wvw32),
    ActualBits($7FC00000), WASM_REF_NULL)).ToBe(True);
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanArithmetic, wvw64),
    ActualBits($7FF8000000000000), WASM_REF_NULL)).ToBe(True);
end;

procedure TWastValuesTests.TestCompareNanArithmeticRejectsInf;
begin
  { Infinity has a zero significand — not a NaN at all. }
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanArithmetic, wvw32),
    ActualBits($7F800000), WASM_REF_NULL)).ToBe(False);
  { A signalling NaN with payload MSB clear fails the arithmetic class. }
  Expect<Boolean>(WastValMatches(MakeNanExpect(wvcNanArithmetic, wvw32),
    ActualBits($7FA00000), WASM_REF_NULL)).ToBe(False);
end;

procedure TWastValuesTests.TestCompareRefNull;
begin
  Expect<Boolean>(WastValMatches(MakeRefExpect(wvcRefNull),
    ActualBits(UInt64(WASM_REF_NULL)), WASM_REF_NULL)).ToBe(True);
  { A non-null reference does not match ref.null. }
  Expect<Boolean>(WastValMatches(MakeRefExpect(wvcRefNull),
    ActualBits(UInt64(8)), WASM_REF_NULL)).ToBe(False);
end;

procedure TWastValuesTests.TestCompareRefExternIdentity;
var
  Expected: TWastVal;
begin
  Expected := MakeRefExpect(wvcRefExtern);
  { The resolved reference the runner would mint for this identity. }
  Expect<Boolean>(WastValMatches(Expected, ActualBits(UInt64(16)),
    TWasmRef(16))).ToBe(True);
end;

procedure TWastValuesTests.TestCompareRefExternMismatch;
var
  Expected: TWastVal;
begin
  Expected := MakeRefExpect(wvcRefExtern);
  { Different reference identity — no match. }
  Expect<Boolean>(WastValMatches(Expected, ActualBits(UInt64(24)),
    TWasmRef(16))).ToBe(False);
  { A null result never matches a positive-identity extern. }
  Expect<Boolean>(WastValMatches(Expected,
    ActualBits(UInt64(WASM_REF_NULL)), TWasmRef(16))).ToBe(False);
end;

procedure TWastValuesTests.TestCompareRefExternBareAnyNonNull;
var
  Expected: TWastVal;
begin
  { A BARE `(ref.extern)` matcher (no N) carries no identity, so the runner
    hands the comparator a null AExpectedRef. Any non-null externref must
    then match — the same any-non-null rule bare `(ref.func)` already uses.
    Mirrors extern.wast, whose `(ref.extern)` results have no index. }
  Expected := MakeRefExpect(wvcRefExtern);
  Expect<Boolean>(WastValMatches(Expected, ActualBits(UInt64(40)),
    WASM_REF_NULL)).ToBe(True);
  { A null result is still not a non-null externref. }
  Expect<Boolean>(WastValMatches(Expected,
    ActualBits(UInt64(WASM_REF_NULL)), WASM_REF_NULL)).ToBe(False);
end;

{ --- v128 per-lane comparator + (either) --------------------------------- }

function VecI32(const A, B, C, D: UInt32): TWasmV128;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.U32[0] := A;
  Result.U32[1] := B;
  Result.U32[2] := C;
  Result.U32[3] := D;
end;

function VecF32Bits(const A, B, C, D: UInt32): TWasmV128;
begin
  Result := VecI32(A, B, C, D);   { lanes are raw f32 bit patterns }
end;

{ Parse AExpectedText into a result matcher and compare AActual (a v128)
  against it through the real slot-aware entry point. }
function VecMatches(const AExpectedText: string;
  const AActual: TWasmV128): Boolean;
var
  Script: TWastScript;
  Exp: TWastExpected;
  Slots: array[0..1] of TWasmValue;
begin
  Script := ParseWastScript(AExpectedText);
  try
    Exp := WastParseExpected(Script[0].Node);
  finally
    Script.Free;
  end;
  Slots[0].Bits := AActual.U64[0];
  Slots[1].Bits := AActual.U64[1];
  Result := WastExpectedMatches(Exp, @Slots[0], True, WASM_REF_NULL);
end;

procedure TWastValuesTests.TestVecExactMatch;
begin
  Expect<Boolean>(VecMatches('(v128.const i32x4 1 2 3 4)',
    VecI32(1, 2, 3, 4))).ToBe(True);
  Expect<Boolean>(VecMatches('(v128.const i32x4 1 2 3 4)',
    VecI32(1, 2, 3, 5))).ToBe(False);
end;

procedure TWastValuesTests.TestVecOneNanCanonicalLaneMatches;
begin
  { Lane 0 canonical NaN, lanes 1-3 exact — all four must hold. }
  Expect<Boolean>(VecMatches(
    '(v128.const f32x4 nan:canonical 1.0 2.0 3.0)',
    VecF32Bits($7FC00000, $3F800000, $40000000, $40400000))).ToBe(True);
end;

procedure TWastValuesTests.TestVecWrongLaneFails;
begin
  { Lane 0 matches the canonical class, but lane 1 is 1.5 not 1.0 — a single
    wrong lane fails the whole result. }
  Expect<Boolean>(VecMatches(
    '(v128.const f32x4 nan:canonical 1.0 2.0 3.0)',
    VecF32Bits($7FC00000, $3FC00000, $40000000, $40400000))).ToBe(False);
end;

procedure TWastValuesTests.TestVecNanArithmeticLaneClass;
begin
  { A non-canonical arithmetic NaN (payload MSB set, extra payload bits)
    satisfies nan:arithmetic on that lane. }
  Expect<Boolean>(VecMatches(
    '(v128.const f32x4 nan:arithmetic 0 0 0)',
    VecF32Bits($7FE00000, 0, 0, 0))).ToBe(True);
  { Infinity is not a NaN — the arithmetic class rejects it. }
  Expect<Boolean>(VecMatches(
    '(v128.const f32x4 nan:arithmetic 0 0 0)',
    VecF32Bits($7F800000, 0, 0, 0))).ToBe(False);
end;

procedure TWastValuesTests.TestEitherMatchesAnyAlternative;
begin
  { The relaxed-SIMD form: passes if the actual matches ANY alternative. }
  Expect<Boolean>(VecMatches(
    '(either (v128.const i32x4 1 2 3 4) (v128.const i32x4 5 6 7 8))',
    VecI32(5, 6, 7, 8))).ToBe(True);
end;

procedure TWastValuesTests.TestEitherFailsWhenNoneMatch;
begin
  Expect<Boolean>(VecMatches(
    '(either (v128.const i32x4 1 2 3 4) (v128.const i32x4 5 6 7 8))',
    VecI32(9, 9, 9, 9))).ToBe(False);
end;

procedure TWastValuesTests.SetupTests;
begin
  Test('i32 decimal', TestInt32Decimal);
  Test('i32 hex', TestInt32Hex);
  Test('i32 negative wraps', TestInt32NegativeWraps);
  Test('i32 underscores', TestInt32Underscores);
  Test('i64 full range', TestInt64FullRange);
  Test('i64 min', TestInt64Min);
  Test('i64 hex max', TestInt64HexMax);

  Test('f32 one', TestF32One);
  Test('f32 negative zero', TestF32NegZero);
  Test('f32 inf', TestF32Inf);
  Test('f32 nan canonical', TestF32NanCanonical);
  Test('f32 nan payload', TestF32NanPayload);
  Test('f32 hex basic', TestF32HexBasic);
  Test('f32 smallest subnormal', TestF32SmallestSubnormal);
  Test('f32 subnormal round to even', TestF32SubnormalRoundToEven);
  Test('f32 max', TestF32Max);
  Test('f32 overflow to inf', TestF32OverflowToInf);
  Test('f32 decimal half', TestF32DecimalHalf);
  Test('f64 one', TestF64One);
  Test('f64 half', TestF64Half);
  Test('f64 smallest subnormal', TestF64SmallestSubnormal);
  Test('f64 hex fraction', TestF64HexFraction);
  Test('f64 negative inf', TestF64NegInf);

  Test('parse value i32', TestParseValI32);
  Test('parse value nan:canonical matcher', TestParseValNanCanonicalMatcher);
  Test('parse value ref.extern id', TestParseValRefExternId);
  Test('parse value ref.null', TestParseValRefNull);

  Test('parse v128 i8x16 exact bytes', TestParseV128I8x16Bytes);
  Test('parse v128 i32x4 lanes', TestParseV128I32x4Lanes);
  Test('parse v128 f64x2 lanes', TestParseV128F64x2Lanes);
  Test('parse v128 f32x4 mixed NaN lane kinds',
    TestParseV128F32x4NanLaneKinds);
  Test('parse v128 wrong lane count raises',
    TestParseV128WrongLaneCountRaises);

  Test('compare exact i32', TestCompareExactI32);
  Test('compare exact f32 negative zero', TestCompareExactF32NegZero);
  Test('compare nan canonical match', TestCompareNanCanonicalMatch);
  Test('compare nan canonical rejects payload',
    TestCompareNanCanonicalRejectsPayload);
  Test('compare nan arithmetic match', TestCompareNanArithmeticMatch);
  Test('compare nan arithmetic rejects inf',
    TestCompareNanArithmeticRejectsInf);
  Test('compare ref null', TestCompareRefNull);
  Test('compare ref extern identity', TestCompareRefExternIdentity);
  Test('compare ref extern mismatch', TestCompareRefExternMismatch);
  Test('compare bare ref extern matches any non-null externref',
    TestCompareRefExternBareAnyNonNull);

  Test('vec exact match', TestVecExactMatch);
  Test('vec one nan:canonical lane matches',
    TestVecOneNanCanonicalLaneMatches);
  Test('vec wrong lane fails', TestVecWrongLaneFails);
  Test('vec nan:arithmetic lane class', TestVecNanArithmeticLaneClass);
  Test('either matches any alternative', TestEitherMatchesAnyAlternative);
  Test('either fails when none match', TestEitherFailsWhenNoneMatch);
end;

begin
  TestRunnerProgram.AddSuite(TWastValuesTests.Create('Wasm.Wast.Values'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
