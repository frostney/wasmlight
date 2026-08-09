{ Unit suite for Wasm.Wat.Numbers — the wat numeric-literal fidelity net.

  Every literal is spelled next to its expected bit pattern, drawn from the
  conformance corpus (const.wast, float_literals.wast, int_literals.wast) so
  the corpus is the oracle, exactly as AGENTS.md requires for malformed byte
  cases. The load-bearing risks each get a suite: the INT64_MIN edge across all
  four spellings plus the just-out-of-range neighbours; the i32 signed/unsigned
  union (-1 vs 4294967295); hex-float round-half-to-even at the exact tie,
  subnormal shift-with-sticky, and overflow that appears only AFTER rounding
  (const.wast:316 vs :327); the 309-digit decimal at const.wast:2; and NaN
  payloads side by side with the assertion that nan:canonical in a const raises
  `unexpected token`.

  A round-trip property test formats known f32/f64 bit patterns as hex floats
  and re-parses them: hex round-trips EXACTLY, so any mismatch is a parser bug.

  Two FPC framework gotchas are honoured (AGENTS.md): a generic Expect<T> call
  is never the lone statement of an `on ... do` (the message is captured into a
  variable first), and every test records at least one assertion.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
program Wasm.Wat.Numbers.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Wat.Numbers;

type
  TWatNumbersTests = class(TTestSuite)
  private
    { Capture the EWasmTextError message (or '' on success) for each parse
      entry point. }
    function I8Err(const AToken: string): string;
    function I16Err(const AToken: string): string;
    function I32Err(const AToken: string): string;
    function I64Err(const AToken: string): string;
    function F32Err(const AToken: string): string;
    function F64Err(const AToken: string): string;
    { Exact hex-float rendering of a bit pattern for the round-trip oracle. }
    function HexOfF32(const ABits: UInt32): string;
    function HexOfF64(const ABits: UInt64): string;
  public
    procedure SetupTests; override;

    procedure TestIntBasic;
    procedure TestIntSeparators;
    procedure TestI32Union;
    procedure TestI64MinEdge;
    procedure TestIntOutOfRange;
    procedure TestIntMalformed;
    procedure TestLaneWidthWrappersAndMessages;

    procedure TestFloatSpecials;
    procedure TestNaNPayloads;
    procedure TestNaNResultClasses;
    procedure TestHexFloatExact;
    procedure TestHexFloatSubnormal;
    procedure TestHexFloatRoundTiesToEven;
    procedure TestHexFloatOverflowAfterRounding;
    procedure TestDecimalFloat;
    procedure TestDecimalHardCases;
    procedure TestFloatOutOfRange;
    procedure TestFloatRoundTrip;
  end;

{ --- private helpers -------------------------------------------------- }

function TWatNumbersTests.I8Err(const AToken: string): string;
var
  D: Byte;
begin
  Result := '';
  try
    D := ParseI8(AToken);
    if D = 0 then
      Result := '';
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatNumbersTests.I16Err(const AToken: string): string;
var
  D: Word;
begin
  Result := '';
  try
    D := ParseI16(AToken);
    if D = 0 then
      Result := '';
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatNumbersTests.I32Err(const AToken: string): string;
var
  D: UInt32;
begin
  Result := '';
  try
    D := ParseI32(AToken);
    if D = 0 then
      Result := '';
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatNumbersTests.I64Err(const AToken: string): string;
var
  D: UInt64;
begin
  Result := '';
  try
    D := ParseI64(AToken);
    if D = 0 then
      Result := '';
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatNumbersTests.F32Err(const AToken: string): string;
var
  D: UInt32;
begin
  Result := '';
  try
    D := ParseF32(AToken);
    if D = 0 then
      Result := '';
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatNumbersTests.F64Err(const AToken: string): string;
var
  D: UInt64;
begin
  Result := '';
  try
    D := ParseF64(AToken);
    if D = 0 then
      Result := '';
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

{ value = sig * 2^exp2, with sig the full significand (implicit bit included
  for normals) — an integer hex float that re-parses to exactly ABits. }
function TWatNumbersTests.HexOfF32(const ABits: UInt32): string;
var
  Sign: Boolean;
  ExpF: Integer;
  Mant, Sig: UInt32;
  Exp2: Integer;
begin
  Sign := (ABits and UInt32($80000000)) <> 0;
  ExpF := (ABits shr 23) and $FF;
  Mant := ABits and UInt32($7FFFFF);
  if ExpF = 0 then
  begin
    Sig := Mant;
    Exp2 := -149;
  end
  else
  begin
    Sig := Mant or UInt32($800000);
    Exp2 := ExpF - 127 - 23;
  end;
  Result := '';
  if Sign then
    Result := '-';
  Result := Result + '0x' + LowerCase(IntToHex(Sig, 1)) + 'p' + IntToStr(Exp2);
end;

function TWatNumbersTests.HexOfF64(const ABits: UInt64): string;
var
  Sign: Boolean;
  ExpF: Integer;
  Mant, Sig: UInt64;
  Exp2: Integer;
begin
  Sign := (ABits and UInt64($8000000000000000)) <> 0;
  ExpF := (ABits shr 52) and $7FF;
  Mant := ABits and UInt64($FFFFFFFFFFFFF);
  if ExpF = 0 then
  begin
    Sig := Mant;
    Exp2 := -1074;
  end
  else
  begin
    Sig := Mant or UInt64($10000000000000);
    Exp2 := ExpF - 1023 - 52;
  end;
  Result := '';
  if Sign then
    Result := '-';
  Result := Result + '0x' + LowerCase(IntToHex(Sig, 1)) + 'p' + IntToStr(Exp2);
end;

{ --- integers -------------------------------------------------------- }

procedure TWatNumbersTests.TestIntBasic;
begin
  { int_literals.wast: decimal, hex, +sign, and 010 as ten not octal. }
  Expect<UInt32>(ParseI32('0x0bAdD00D')).ToBe(UInt32($0BADD00D));
  Expect<UInt32>(ParseI32('195940365')).ToBe(UInt32(195940365));
  Expect<UInt32>(ParseI32('010')).ToBe(UInt32(10));
  Expect<UInt32>(ParseI32('+42')).ToBe(UInt32(42));
  Expect<UInt32>(ParseI32('-0x0')).ToBe(UInt32(0));
  Expect<UInt64>(ParseI64('0x0CABBA6E0ba66a6e')).ToBe(UInt64($0CABBA6E0BA66A6E));
  Expect<UInt64>(ParseI64('913028331277281902')).ToBe(UInt64(913028331277281902));
  { small widths for lane literals. }
  Expect<Byte>(ParseI8('255')).ToBe(Byte($FF));
  Expect<Byte>(ParseI8('-128')).ToBe(Byte($80));
  Expect<Word>(ParseI16('-1')).ToBe(Word($FFFF));
end;

procedure TWatNumbersTests.TestIntSeparators;
begin
  { Underscores between digits, decimal and hex (int_literals.wast). }
  Expect<UInt32>(ParseI32('1_000_000')).ToBe(UInt32(1000000));
  Expect<UInt32>(ParseI32('1_0_0_0')).ToBe(UInt32(1000));
  Expect<UInt32>(ParseI32('0xa_0f_00_99')).ToBe(UInt32($A0F0099));
  Expect<UInt64>(ParseI64('0xa_f00f_0000_9999')).ToBe(UInt64($AF00F00009999));
end;

procedure TWatNumbersTests.TestI32Union;
begin
  { The i32 union range: -1 and 4294967295 both denote 0xFFFFFFFF, and
    0x80000000 and -0x80000000 both denote the sign bit (int_literals.wast). }
  Expect<UInt32>(ParseI32('-1')).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(ParseI32('4294967295')).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(ParseI32('0xffffffff')).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(ParseI32('2147483647')).ToBe(UInt32($7FFFFFFF));
  Expect<UInt32>(ParseI32('-2147483648')).ToBe(UInt32($80000000));
  Expect<UInt32>(ParseI32('0x80000000')).ToBe(UInt32($80000000));
  Expect<UInt32>(ParseI32('-0x80000000')).ToBe(UInt32($80000000));
end;

procedure TWatNumbersTests.TestI64MinEdge;
begin
  { INT64_MIN across all four spellings, plus the unsigned max — all computed
    without an Int64 negation that would overflow (const.wast:287-298,
    int_literals.wast:19). }
  Expect<UInt64>(ParseI64('-0x8000000000000000')).ToBe(UInt64($8000000000000000));
  Expect<UInt64>(ParseI64('0x8000000000000000')).ToBe(UInt64($8000000000000000));
  Expect<UInt64>(ParseI64('-9223372036854775808')).ToBe(UInt64($8000000000000000));
  Expect<UInt64>(ParseI64('0xffffffffffffffff')).ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(ParseI64('18446744073709551615')).ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(ParseI64('-1')).ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(ParseI64('9223372036854775807')).ToBe(UInt64($7FFFFFFFFFFFFFFF));
end;

procedure TWatNumbersTests.TestIntOutOfRange;
begin
  { The just-out-of-range neighbours of every boundary (const.wast:286-304). }
  Expect<string>(I64Err('0x10000000000000000')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I64Err('-0x8000000000000001')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I64Err('18446744073709551616')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I64Err('-9223372036854775809')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I32Err('4294967296')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I32Err('-2147483649')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I32Err('0x100000000')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
end;

procedure TWatNumbersTests.TestIntMalformed;
begin
  { Malformed integer TOKENS are `unknown operator`, not range errors
    (const.wast:12-20, int_literals.wast:99-140). The message carries the
    appended token, so assert on the prefix. }
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I32Err('0x')) = 1).ToBe(True);
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I32Err('1x')) = 1).ToBe(True);
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I32Err('0xg')) = 1).ToBe(True);
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I32Err('_100')) = 1).ToBe(True);
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I32Err('99_')) = 1).ToBe(True);
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I32Err('1__000')) = 1).ToBe(True);
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I32Err('0x_100')) = 1).ToBe(True);
  { And the appended-token shape itself is exact. }
  Expect<string>(I32Err('1x')).ToBe(MSG_UNKNOWN_OPERATOR + ' 1x');
end;

procedure TWatNumbersTests.TestLaneWidthWrappersAndMessages;
begin
  { The lane-INDEX wrappers ParseI8 / ParseI16 accept the union [-2^(N-1),
    2^N-1] like every width, but raise the WIDTH-PREFIXED spelling on
    overflow, because a lane index is spelled through them. This is the split
    the corpus forces (design §5.4): `i8 constant out of range` in
    simd_lane.wast (lane indices) vs the bare `constant out of range` in
    simd_const.wast (v128.const lane literals). Prefix matching makes the two
    unmergeable, so the exact string matters. }
  Expect<Byte>(ParseI8('0')).ToBe(Byte(0));
  Expect<Byte>(ParseI8('255')).ToBe(Byte(255));
  Expect<Byte>(ParseI8('0x1f')).ToBe(Byte($1F));
  { -1 is IN range for ParseI8 (the signed/unsigned union) and wraps to 255;
    the assembler, not Numbers, rejects a signed lane index. }
  Expect<Byte>(ParseI8('-1')).ToBe(Byte(255));
  Expect<Word>(ParseI16('65535')).ToBe(Word(65535));

  { 256 overflows i8 -> the width-prefixed message (simd_lane.wast:415). }
  Expect<string>(I8Err('256')).ToBe(MSG_I8_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I8Err('0x100')).ToBe(MSG_I8_CONSTANT_OUT_OF_RANGE);
  Expect<string>(I16Err('65536')).ToBe(MSG_I16_CONSTANT_OUT_OF_RANGE);

  { The bare `constant out of range` stays the spelling for ParseIntLiteral at
    width 8/16 — the v128.const lane-literal path (simd_const.wast). The two
    must be DISTINCT: `i8 constant out of range` is NOT prefixed by the bare
    form, so a harness prefix-match keeps them apart. }
  Expect<Boolean>(Pos(MSG_CONSTANT_OUT_OF_RANGE, MSG_I8_CONSTANT_OUT_OF_RANGE) = 1)
    .ToBe(False);
  Expect<string>(I8Err('256')).ToBe(MSG_I8_CONSTANT_OUT_OF_RANGE);

  { A malformed lane-index token is still `unknown operator`, width-agnostic. }
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, I8Err('0xg')) = 1).ToBe(True);
end;

{ --- floats ---------------------------------------------------------- }

procedure TWatNumbersTests.TestFloatSpecials;
begin
  { inf / nan / signs (float_literals.wast). }
  Expect<UInt32>(ParseF32('inf')).ToBe(UInt32($7F800000));
  Expect<UInt32>(ParseF32('+inf')).ToBe(UInt32($7F800000));
  Expect<UInt32>(ParseF32('-inf')).ToBe(UInt32($FF800000));
  Expect<UInt32>(ParseF32('nan')).ToBe(UInt32($7FC00000));
  Expect<UInt32>(ParseF32('+nan')).ToBe(UInt32($7FC00000));
  Expect<UInt32>(ParseF32('-nan')).ToBe(UInt32($FFC00000));
  Expect<UInt64>(ParseF64('inf')).ToBe(UInt64($7FF0000000000000));
  Expect<UInt64>(ParseF64('-inf')).ToBe(UInt64($FFF0000000000000));
  Expect<UInt64>(ParseF64('nan')).ToBe(UInt64($7FF8000000000000));
  Expect<UInt64>(ParseF64('-nan')).ToBe(UInt64($FFF8000000000000));
  { plain zeros with sign. }
  Expect<UInt32>(ParseF32('0x0.0p0')).ToBe(UInt32(0));
  Expect<UInt32>(ParseF32('-0x0.0p0')).ToBe(UInt32($80000000));
  Expect<UInt32>(ParseF32('0.0e0')).ToBe(UInt32(0));
  Expect<UInt32>(ParseF32('-0.0e0')).ToBe(UInt32($80000000));
end;

procedure TWatNumbersTests.TestNaNPayloads;
begin
  { Explicit payloads: canonical bit, all-ones, misc, signs, underscores
    (float_literals.wast, const.wast:406). Bits are sign | all-ones exp |
    payload. }
  Expect<UInt32>(ParseF32('nan:0x400000')).ToBe(UInt32($7FC00000));
  Expect<UInt32>(ParseF32('nan:0x200000')).ToBe(UInt32($7FA00000));
  Expect<UInt32>(ParseF32('-nan:0x7fffff')).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(ParseF32('nan:0x7f_ffff')).ToBe(UInt32($7FFFFFFF));
  Expect<UInt32>(ParseF32('+nan:0x304050')).ToBe(UInt32($7FB04050));
  Expect<UInt64>(ParseF64('nan:0x8000000000000')).ToBe(UInt64($7FF8000000000000));
  Expect<UInt64>(ParseF64('-nan:0xfffffffffffff')).ToBe(UInt64($FFFFFFFFFFFFFFFF));

  { Payload 0 and payload = 2^m (one past the mantissa) are out of range
    (const.wast:419-432). }
  Expect<string>(F32Err('nan:0x0')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(F64Err('nan:0x0')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(F32Err('nan:0x800000')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(F64Err('nan:0x10000000000000')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);

  { A non-hex payload is not a float token at all (const.wast:410). }
  Expect<Boolean>(Pos(MSG_UNKNOWN_OPERATOR, F32Err('nan:1')) = 1).ToBe(True);
end;

procedure TWatNumbersTests.TestNaNResultClasses;
begin
  { nan:canonical / nan:arithmetic are the runner's result classes, invalid in
    a const literal position -> `unexpected token` (design §7; i64.wast:488).
    A parser that accepted them here would silently turn a malformed case into
    a pass. }
  Expect<string>(F32Err('nan:canonical')).ToBe(MSG_UNEXPECTED_TOKEN);
  Expect<string>(F32Err('nan:arithmetic')).ToBe(MSG_UNEXPECTED_TOKEN);
  Expect<string>(F64Err('nan:canonical')).ToBe(MSG_UNEXPECTED_TOKEN);
  Expect<string>(F64Err('-nan:arithmetic')).ToBe(MSG_UNEXPECTED_TOKEN);
end;

procedure TWatNumbersTests.TestHexFloatExact;
begin
  { Exactly-representable hex floats, no rounding (float_literals.wast). }
  Expect<UInt32>(ParseF32('0x1.921fb6p+2')).ToBe(UInt32($40C90FDB));
  Expect<UInt32>(ParseF32('0x1.p10')).ToBe(UInt32($44800000));
  Expect<UInt32>(ParseF32('0x12345')).ToBe(UInt32($4791A280));
  Expect<UInt32>(ParseF32('0x1_0000_0000_0000_0000_0000')).ToBe(UInt32($67800000));
  Expect<UInt32>(ParseF32('-0x8000_0000')).ToBe(UInt32($CF000000));
  Expect<UInt32>(ParseF32('-0x8000_0000_0000_0000')).ToBe(UInt32($DF000000));
  Expect<UInt64>(ParseF64('0x1.921fb54442d18p+2')).ToBe(UInt64($401921FB54442D18));
  Expect<UInt64>(ParseF64('0x1p+0')).ToBe(UInt64($3FF0000000000000));
end;

procedure TWatNumbersTests.TestHexFloatSubnormal;
begin
  { Subnormal shift-with-sticky at the very bottom of the range
    (float_literals.wast). }
  Expect<UInt32>(ParseF32('0x1p-149')).ToBe(UInt32(1));           { min subnormal }
  Expect<UInt32>(ParseF32('0x1p-126')).ToBe(UInt32($800000));     { min normal }
  Expect<UInt32>(ParseF32('0x1.fffffcp-127')).ToBe(UInt32($7FFFFF)); { max subnormal }
  Expect<UInt32>(ParseF32('0x1.fffffep+127')).ToBe(UInt32($7F7FFFFF)); { max finite }
  { 0x1p-150 is exactly half the smallest subnormal -> ties to even -> 0. }
  Expect<UInt32>(ParseF32('0x1p-150')).ToBe(UInt32(0));
  Expect<UInt64>(ParseF64('0x1p-1074')).ToBe(UInt64(1));          { min subnormal }
  Expect<UInt64>(ParseF64('0x1p-1022')).ToBe(UInt64($10000000000000)); { min normal }
  Expect<UInt64>(ParseF64('0x0.fffffffffffffp-1022')).ToBe(UInt64($FFFFFFFFFFFFF));
  Expect<UInt64>(ParseF64('0x1.fffffffffffffp+1023')).ToBe(UInt64($7FEFFFFFFFFFFFFF));
end;

procedure TWatNumbersTests.TestHexFloatRoundTiesToEven;
begin
  { const.wast:288-296: 0x1.000000p-50 has bits 0x26800000, and one ulp up
    (0x1.000002p-50) is 0x26800001. The guard-bit tie at 0x1.000001000...0
    rounds to the even neighbour (down, 0x26800000), while an extra low 1 tips
    it up to 0x26800001. }
  Expect<UInt32>(ParseF32('+0x1.00000100000000000p-50')).ToBe(UInt32($26800000));
  Expect<UInt32>(ParseF32('+0x1.00000100000000001p-50')).ToBe(UInt32($26800001));
  Expect<UInt32>(ParseF32('+0x1.000001fffffffffffp-50')).ToBe(UInt32($26800001));
  { The next tie (0x1.000003 halfway) rounds UP to the even neighbour
    0x1.000004p-50 = 0x26800002. }
  Expect<UInt32>(ParseF32('+0x1.00000300000000000p-50')).ToBe(UInt32($26800002));
  Expect<UInt32>(ParseF32('-0x1.00000300000000000p-50')).ToBe(UInt32($A6800002));
end;

procedure TWatNumbersTests.TestHexFloatOverflowAfterRounding;
begin
  { const.wast:316 vs :327 — the two literals differ ONLY in the rounding
    decision. Rounding down to max-finite is accepted; rounding up past it is
    `constant out of range`. }
  Expect<UInt32>(ParseF32('0x1.fffffefffffffffffp127')).ToBe(UInt32($7F7FFFFF));
  Expect<string>(F32Err('0x1.ffffffp127')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<UInt64>(ParseF64('0x1.fffffffffffff7ffffffp1023'))
    .ToBe(UInt64($7FEFFFFFFFFFFFFF));
  Expect<string>(F64Err('0x1.fffffffffffff8p1023')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
end;

procedure TWatNumbersTests.TestDecimalFloat;
begin
  { Decimal floats, correctly rounded (float_literals.wast). }
  Expect<UInt32>(ParseF32('1.0')).ToBe(UInt32($3F800000));
  Expect<UInt32>(ParseF32('12345')).ToBe(UInt32($4640E400));
  Expect<UInt32>(ParseF32('1.e10')).ToBe(UInt32($501502F9));
  Expect<UInt32>(ParseF32('1.4013e-45')).ToBe(UInt32(1));         { min subnormal }
  Expect<UInt32>(ParseF32('3.4028234e+38')).ToBe(UInt32($7F7FFFFF)); { max finite }
  Expect<UInt64>(ParseF64('1.0')).ToBe(UInt64($3FF0000000000000));
  Expect<UInt64>(ParseF64('-0.0')).ToBe(UInt64($8000000000000000));
end;

procedure TWatNumbersTests.TestDecimalHardCases;
begin
  { const.wast:2 — the 309-digit decimal that names the max finite double
    exactly; the corresponding larger literal is out of range. This is the
    bignum long-division stress case. }
  Expect<UInt64>(ParseF64('179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368'))
    .ToBe(UInt64($7FEFFFFFFFFFFFFF));
  Expect<string>(F64Err('269653970229347356221791135597556535197105851288767494898376215204735891170042808140884337949150317257310688430271573696351481990334196274152701320055306275479074865864826923114368235135583993416113802762682700913456874855354834422248712838998185022412196739306217084753107265771378949821875606039276187287552'))
    .ToBe(MSG_CONSTANT_OUT_OF_RANGE);
end;

procedure TWatNumbersTests.TestFloatOutOfRange;
begin
  { Decimal and hex overflow to infinity is out of range (const.wast). }
  Expect<string>(F32Err('1e39')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<UInt32>(ParseF32('1e38')).ToBe(UInt32($7E967699)); { still finite }
  Expect<string>(F32Err('0x1p128')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(F64Err('1e309')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
  Expect<string>(F64Err('0x1p1024')).ToBe(MSG_CONSTANT_OUT_OF_RANGE);
end;

procedure TWatNumbersTests.TestFloatRoundTrip;
const
  F32Cases: array[0..9] of UInt32 = (
    UInt32($00000000),   { +0 }
    UInt32($80000000),   { -0 }
    UInt32($00000001),   { min subnormal }
    UInt32($007FFFFF),   { max subnormal }
    UInt32($00800000),   { min normal }
    UInt32($3F800000),   { 1.0 }
    UInt32($40490FDB),   { pi }
    UInt32($41200000),   { 10.0 }
    UInt32($C0000000),   { -2.0 }
    UInt32($7F7FFFFF)    { max finite }
  );
  F64Cases: array[0..6] of UInt64 = (
    UInt64($0000000000000001),   { min subnormal }
    UInt64($000FFFFFFFFFFFFF),   { max subnormal }
    UInt64($0010000000000000),   { min normal }
    UInt64($3FF0000000000000),   { 1.0 }
    UInt64($400921FB54442D18),   { pi }
    UInt64($C000000000000000),   { -2.0 }
    UInt64($7FEFFFFFFFFFFFFF)    { max finite }
  );
var
  I: Integer;
begin
  { Hex floats round-trip EXACTLY: format the bits, re-parse, expect the same
    bits. Any mismatch is a parser bug (design §7). }
  for I := Low(F32Cases) to High(F32Cases) do
    Expect<UInt32>(ParseF32(HexOfF32(F32Cases[I]))).ToBe(F32Cases[I]);
  for I := Low(F64Cases) to High(F64Cases) do
    Expect<UInt64>(ParseF64(HexOfF64(F64Cases[I]))).ToBe(F64Cases[I]);
end;

{ --- registration ---------------------------------------------------- }

procedure TWatNumbersTests.SetupTests;
begin
  Test('integer decimal/hex/sign basics', TestIntBasic);
  Test('integer underscore separators', TestIntSeparators);
  Test('i32 signed/unsigned union range', TestI32Union);
  Test('i64 INT64_MIN across four spellings', TestI64MinEdge);
  Test('integer just-out-of-range boundaries', TestIntOutOfRange);
  Test('malformed integer tokens are unknown operator', TestIntMalformed);
  Test('lane-width wrappers and the width-prefixed range message',
    TestLaneWidthWrappersAndMessages);

  Test('float inf/nan/zero specials and signs', TestFloatSpecials);
  Test('nan explicit payloads and range rules', TestNaNPayloads);
  Test('nan:canonical/arithmetic are unexpected token', TestNaNResultClasses);
  Test('hex float exact (no rounding)', TestHexFloatExact);
  Test('hex float subnormal shift-with-sticky', TestHexFloatSubnormal);
  Test('hex float round-half-to-even at the tie', TestHexFloatRoundTiesToEven);
  Test('hex float overflow only after rounding', TestHexFloatOverflowAfterRounding);
  Test('decimal float correct rounding', TestDecimalFloat);
  Test('decimal 309-digit and out-of-range twin', TestDecimalHardCases);
  Test('float overflow to infinity is out of range', TestFloatOutOfRange);
  Test('hex-float format/re-parse round-trip', TestFloatRoundTrip);
end;

begin
  TestRunnerProgram.AddSuite(TWatNumbersTests.Create('Wasm.Wat.Numbers'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
