{ Unit suite for Wasm.Interp.Numeric — the numeric conformance micro-net.

  Every function is checked at representative and boundary inputs with
  bit-exact expected results, and every trapping op is asserted by class
  (EWasmTrap) and canonical message. The cases that the spec corpus hammers
  and that have been real bugs in shipped engines are spelled out next to the
  assertion: integer wrap and the div_s/rem_s INT_MIN/-1 pair, the shift-count
  masking, the wasm (not C) min/max sign-of-zero and NaN rules, nearest's
  ties-to-even, NaN canonicalization of every payload-affecting op versus the
  payload-preserving neg/abs/copysign, and the trunc range boundaries against
  the split of 'invalid conversion to integer' (NaN) versus 'integer overflow'
  (out of range, +/-inf included).

  Ordinary float magnitudes are written as Pascal literals and reinterpreted
  through F32ToBits/F64ToBits (themselves pinned to literal hex here); the
  load-bearing patterns — zeros, infinities, the canonical NaN, and the
  conversion boundaries — are written as literal hex Bits values.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
program Wasm.Interp.Numeric.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Interp.Numeric,
  Wasm.Runtime.Traps;

type
  { A call target for the shared integer-trap helper. }
  TFunc32 = function(const A, B: UInt32): UInt32;

  TInterpNumericTests = class(TTestSuite)
  private
    function TrapMsgI32(const AOp: TFunc32; const A, B: UInt32): string;
  public
    procedure SetupTests; override;

    procedure TestReinterpretAndBits;
    procedure TestNaNHelpers;

    procedure TestI32AddSubMul;
    procedure TestI32Bitwise;
    procedure TestI32DivRem;
    procedure TestI32DivRemTraps;
    procedure TestI32ShiftRotate;
    procedure TestI32ClzCtzPopcnt;
    procedure TestI32Relops;

    procedure TestI64AddSubMul;
    procedure TestI64DivRem;
    procedure TestI64DivRemTraps;
    procedure TestI64ShiftRotate;
    procedure TestI64ClzCtzPopcnt;
    procedure TestI64Relops;

    procedure TestF32Arithmetic;
    procedure TestF32MinMax;
    procedure TestF32RoundOps;
    procedure TestF32Sqrt;
    procedure TestF32NegAbsCopysign;
    procedure TestF32Relops;

    procedure TestF64Arithmetic;
    procedure TestF64MinMax;
    procedure TestF64RoundOps;
    procedure TestF64Sqrt;
    procedure TestF64NegAbsCopysign;
    procedure TestF64Relops;

    procedure TestWrapExtend;
    procedure TestConvertIntToFloat;
    procedure TestDemotePromote;

    procedure TestTruncTrapping;
    procedure TestTruncTrapMessages;
    procedure TestTruncSat;
  end;

{ These suites deliberately exercise modulo-2^N wrap arithmetic exactly as
  the interpreter does — with the inlined wrap helpers pasted into this unit,
  a legal wrap would otherwise raise EIntOverflow under Shared.inc's checks.
  Turn them off for the assertions, matching the tier's runtime environment. }
{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

function TInterpNumericTests.TrapMsgI32(const AOp: TFunc32;
  const A, B: UInt32): string;
var
  Dummy: UInt32;
begin
  Result := '';
  try
    Dummy := AOp(A, B);
    if Dummy = 0 then
      Result := '';
  except
    on E: EWasmTrap do
      Result := E.Message;
  end;
end;

{ --- reinterpret + NaN helpers --------------------------------------- }

procedure TInterpNumericTests.TestReinterpretAndBits;
begin
  { The reinterpret casts are the anchor every other float test leans on:
    pin them to literal hex. 1.0f = 0x3F800000, 1.0d = 0x3FF0.. }
  Expect<UInt32>(F32ToBits(1.0)).ToBe(UInt32($3F800000));
  Expect<UInt32>(F32ToBits(-2.0)).ToBe(UInt32($C0000000));
  Expect<Boolean>(BitsToF32(UInt32($3F800000)) = 1.0).ToBe(True);
  Expect<UInt64>(F64ToBits(1.0)).ToBe(UInt64($3FF0000000000000));
  Expect<Boolean>(BitsToF64(UInt64($3FF0000000000000)) = 1.0).ToBe(True);

  { reinterpret ops are pure bit copies (payload survives). }
  Expect<UInt32>(I32ReinterpretF32(UInt32($7FC00001))).ToBe(UInt32($7FC00001));
  Expect<UInt32>(F32ReinterpretI32(UInt32($DEADBEEF))).ToBe(UInt32($DEADBEEF));
  Expect<UInt64>(I64ReinterpretF64(UInt64($7FF8000000000001)))
    .ToBe(UInt64($7FF8000000000001));
  Expect<UInt64>(F64ReinterpretI64(UInt64($0123456789ABCDEF)))
    .ToBe(UInt64($0123456789ABCDEF));
end;

procedure TInterpNumericTests.TestNaNHelpers;
begin
  { Detect by bit test: exponent all-ones AND non-zero significand. }
  Expect<Boolean>(F32IsNan(UInt32($7FC00000))).ToBe(True);   { canonical }
  Expect<Boolean>(F32IsNan(UInt32($7F800001))).ToBe(True);   { signaling }
  Expect<Boolean>(F32IsNan(UInt32($FFC00000))).ToBe(True);   { negative }
  Expect<Boolean>(F32IsNan(UInt32($7F800000))).ToBe(False);  { +inf }
  Expect<Boolean>(F32IsNan(UInt32($00000000))).ToBe(False);  { +0 }
  Expect<Boolean>(F64IsNan(UInt64($7FF8000000000000))).ToBe(True);
  Expect<Boolean>(F64IsNan(UInt64($7FF0000000000000))).ToBe(False); { +inf }

  { Canonicalize collapses any NaN to positive canonical, passes others. }
  Expect<UInt32>(CanonicalizeF32(UInt32($FF800001))).ToBe(UInt32($7FC00000));
  Expect<UInt32>(CanonicalizeF32(UInt32($3F800000))).ToBe(UInt32($3F800000));
  Expect<UInt64>(CanonicalizeF64(UInt64($FFF0000000000001)))
    .ToBe(UInt64($7FF8000000000000));
end;

{ --- i32 integer ----------------------------------------------------- }

procedure TInterpNumericTests.TestI32AddSubMul;
var
  Max, Zero, Bit16: UInt32;
begin
  Max := UInt32($FFFFFFFF);
  Zero := 0;
  Bit16 := UInt32($10000);
  Expect<UInt32>(I32Add(2, 3)).ToBe(5);
  { modulo 2^32 wrap. }
  Expect<UInt32>(I32Add(Max, 1)).ToBe(0);
  Expect<UInt32>(I32Sub(Zero, 1)).ToBe(Max);
  Expect<UInt32>(I32Mul(Max, Max)).ToBe(1);
  Expect<UInt32>(I32Mul(Bit16, Bit16)).ToBe(0); { 2^32 wraps }
end;

procedure TInterpNumericTests.TestI32Bitwise;
begin
  Expect<UInt32>(I32And(UInt32($FF00FF00), UInt32($0FF00FF0)))
    .ToBe(UInt32($0F000F00));
  Expect<UInt32>(I32Or(UInt32($FF00FF00), UInt32($00FF00FF)))
    .ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(I32Xor(UInt32($FFFFFFFF), UInt32($0F0F0F0F)))
    .ToBe(UInt32($F0F0F0F0));
end;

procedure TInterpNumericTests.TestI32DivRem;
begin
  Expect<UInt32>(I32DivS(UInt32(-7), 3)).ToBe(UInt32(-2)); { toward zero }
  Expect<UInt32>(I32DivS(7, UInt32(-3))).ToBe(UInt32(-2));
  Expect<UInt32>(I32DivU(UInt32($FFFFFFFF), 2)).ToBe(UInt32($7FFFFFFF));
  Expect<UInt32>(I32RemS(UInt32(-7), 3)).ToBe(UInt32(-1)); { sign of dividend }
  Expect<UInt32>(I32RemS(7, UInt32(-3))).ToBe(1);
  Expect<UInt32>(I32RemU(UInt32($FFFFFFFF), 2)).ToBe(1);
  { INT_MIN/-1: div_s traps (checked elsewhere), rem_s is 0 and does NOT. }
  Expect<UInt32>(I32RemS(UInt32($80000000), UInt32(-1))).ToBe(0);
end;

procedure TInterpNumericTests.TestI32DivRemTraps;
begin
  Expect<string>(TrapMsgI32(@I32DivS, 1, 0)).ToBe(MSG_TRAP_DIVIDE_BY_ZERO);
  Expect<string>(TrapMsgI32(@I32DivU, 1, 0)).ToBe(MSG_TRAP_DIVIDE_BY_ZERO);
  Expect<string>(TrapMsgI32(@I32RemS, 1, 0)).ToBe(MSG_TRAP_DIVIDE_BY_ZERO);
  Expect<string>(TrapMsgI32(@I32RemU, 1, 0)).ToBe(MSG_TRAP_DIVIDE_BY_ZERO);
  { div_s INT_MIN/-1 is the unrepresentable-quotient overflow. }
  Expect<string>(TrapMsgI32(@I32DivS, UInt32($80000000), UInt32(-1)))
    .ToBe(MSG_TRAP_INTEGER_OVERFLOW);
end;

procedure TInterpNumericTests.TestI32ShiftRotate;
begin
  Expect<UInt32>(I32Shl(1, 4)).ToBe(16);
  { shift count is masked to width-1: 33 mod 32 = 1. }
  Expect<UInt32>(I32Shl(1, 33)).ToBe(2);
  Expect<UInt32>(I32ShrU(UInt32($80000000), 31)).ToBe(1);
  Expect<UInt32>(I32ShrS(UInt32($80000000), 31)).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(I32ShrS(UInt32($80000000), 0)).ToBe(UInt32($80000000));
  Expect<UInt32>(I32ShrS(UInt32($40000000), 30)).ToBe(1); { positive: logical }
  Expect<UInt32>(I32Rotl(UInt32($80000000), 1)).ToBe(1);
  Expect<UInt32>(I32Rotl(UInt32($00000001), 0)).ToBe(1);
  Expect<UInt32>(I32Rotr(UInt32($00000001), 1)).ToBe(UInt32($80000000));
  Expect<UInt32>(I32Rotr(UInt32($00000001), 32)).ToBe(1); { count mod 32 = 0 }
end;

procedure TInterpNumericTests.TestI32ClzCtzPopcnt;
begin
  Expect<UInt32>(I32Clz(0)).ToBe(32);
  Expect<UInt32>(I32Clz(1)).ToBe(31);
  Expect<UInt32>(I32Clz(UInt32($80000000))).ToBe(0);
  Expect<UInt32>(I32Ctz(0)).ToBe(32);
  Expect<UInt32>(I32Ctz(UInt32($80000000))).ToBe(31);
  Expect<UInt32>(I32Ctz(1)).ToBe(0);
  Expect<UInt32>(I32Popcnt(0)).ToBe(0);
  Expect<UInt32>(I32Popcnt(UInt32($FFFFFFFF))).ToBe(32);
  Expect<UInt32>(I32Popcnt(UInt32($AAAAAAAA))).ToBe(16);
  Expect<UInt32>(I32Eqz(0)).ToBe(1);
  Expect<UInt32>(I32Eqz(1)).ToBe(0);
end;

procedure TInterpNumericTests.TestI32Relops;
begin
  Expect<UInt32>(I32Eq(5, 5)).ToBe(1);
  Expect<UInt32>(I32Ne(5, 6)).ToBe(1);
  Expect<UInt32>(I32LtS(UInt32(-1), 0)).ToBe(1);
  Expect<UInt32>(I32LtU(UInt32(-1), 0)).ToBe(0); { -1 is 0xFFFFFFFF unsigned }
  Expect<UInt32>(I32GtS(0, UInt32(-1))).ToBe(1);
  Expect<UInt32>(I32GtU(UInt32(-1), 0)).ToBe(1);
  Expect<UInt32>(I32LeS(5, 5)).ToBe(1);
  Expect<UInt32>(I32LeU(5, 4)).ToBe(0);
  Expect<UInt32>(I32GeS(UInt32(-1), UInt32(-1))).ToBe(1);
  Expect<UInt32>(I32GeU(4, 5)).ToBe(0);
end;

{ --- i64 integer ----------------------------------------------------- }

procedure TInterpNumericTests.TestI64AddSubMul;
var
  Max, Zero: UInt64;
begin
  { Runtime operands: 2^64 cannot be constant-folded at all, so the inlined
    wrap arithmetic must see non-constant inputs. }
  Max := UInt64($FFFFFFFFFFFFFFFF);
  Zero := 0;
  Expect<UInt64>(I64Add(2, 3)).ToBe(5);
  Expect<UInt64>(I64Add(Max, 1)).ToBe(0);
  Expect<UInt64>(I64Sub(Zero, 1)).ToBe(Max);
  Expect<UInt64>(I64Mul(Max, Max)).ToBe(1);
end;

procedure TInterpNumericTests.TestI64DivRem;
begin
  Expect<UInt64>(I64DivS(UInt64(Int64(-7)), 3)).ToBe(UInt64(Int64(-2)));
  Expect<UInt64>(I64DivU(UInt64($FFFFFFFFFFFFFFFF), 2))
    .ToBe(UInt64($7FFFFFFFFFFFFFFF));
  Expect<UInt64>(I64RemS(UInt64(Int64(-7)), 3)).ToBe(UInt64(Int64(-1)));
  Expect<UInt64>(I64RemU(UInt64($FFFFFFFFFFFFFFFF), 2)).ToBe(1);
  { INT64_MIN/-1: rem_s is 0, no trap. }
  Expect<UInt64>(I64RemS(UInt64($8000000000000000), UInt64(Int64(-1)))).ToBe(0);
end;

procedure TInterpNumericTests.TestI64DivRemTraps;
var
  Msg: string;
  Dummy: UInt64;
begin
  Msg := '';
  try Dummy := I64DivU(1, 0); if Dummy = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_DIVIDE_BY_ZERO);

  Msg := '';
  try Dummy := I64DivS(UInt64($8000000000000000), UInt64(Int64(-1)));
    if Dummy = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_INTEGER_OVERFLOW);

  Msg := '';
  try Dummy := I64RemS(1, 0); if Dummy = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_DIVIDE_BY_ZERO);
end;

procedure TInterpNumericTests.TestI64ShiftRotate;
begin
  Expect<UInt64>(I64Shl(1, 4)).ToBe(16);
  Expect<UInt64>(I64Shl(1, 65)).ToBe(2); { 65 mod 64 = 1 }
  Expect<UInt64>(I64ShrU(UInt64($8000000000000000), 63)).ToBe(1);
  Expect<UInt64>(I64ShrS(UInt64($8000000000000000), 63))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(I64ShrS(UInt64($4000000000000000), 62)).ToBe(1);
  Expect<UInt64>(I64Rotl(UInt64($8000000000000000), 1)).ToBe(1);
  Expect<UInt64>(I64Rotr(1, 1)).ToBe(UInt64($8000000000000000));
  Expect<UInt64>(I64Rotr(1, 64)).ToBe(1); { count mod 64 = 0 }
end;

procedure TInterpNumericTests.TestI64ClzCtzPopcnt;
begin
  Expect<UInt64>(I64Clz(0)).ToBe(64);
  Expect<UInt64>(I64Clz(1)).ToBe(63);
  Expect<UInt64>(I64Clz(UInt64($8000000000000000))).ToBe(0);
  Expect<UInt64>(I64Ctz(0)).ToBe(64);
  Expect<UInt64>(I64Ctz(UInt64($8000000000000000))).ToBe(63);
  Expect<UInt64>(I64Popcnt(UInt64($FFFFFFFFFFFFFFFF))).ToBe(64);
  Expect<UInt64>(I64Popcnt(0)).ToBe(0);
  Expect<UInt32>(I64Eqz(0)).ToBe(1);
  Expect<UInt32>(I64Eqz(UInt64($8000000000000000))).ToBe(0);
end;

procedure TInterpNumericTests.TestI64Relops;
begin
  Expect<UInt32>(I64Eq(5, 5)).ToBe(1);
  Expect<UInt32>(I64Ne(5, 6)).ToBe(1);
  Expect<UInt32>(I64LtS(UInt64(Int64(-1)), 0)).ToBe(1);
  Expect<UInt32>(I64LtU(UInt64(Int64(-1)), 0)).ToBe(0);
  Expect<UInt32>(I64GtU(UInt64(Int64(-1)), 0)).ToBe(1);
  Expect<UInt32>(I64GeS(UInt64(Int64(-1)), UInt64(Int64(-1)))).ToBe(1);
end;

{ --- f32 float ------------------------------------------------------- }

procedure TInterpNumericTests.TestF32Arithmetic;
begin
  Expect<UInt32>(F32Add(F32ToBits(1.0), F32ToBits(2.0)))
    .ToBe(F32ToBits(3.0));
  Expect<UInt32>(F32Sub(F32ToBits(1.0), F32ToBits(2.0)))
    .ToBe(F32ToBits(-1.0));
  Expect<UInt32>(F32Mul(F32ToBits(3.0), F32ToBits(2.0)))
    .ToBe(F32ToBits(6.0));
  { div by zero is NOT a trap for floats. }
  Expect<UInt32>(F32Div(F32ToBits(1.0), UInt32($00000000)))
    .ToBe(UInt32($7F800000)); { +inf }
  Expect<UInt32>(F32Div(F32ToBits(-1.0), UInt32($00000000)))
    .ToBe(UInt32($FF800000)); { -inf }
  { 0/0 is NaN -> positive canonical (aux-nans deterministic profile). }
  Expect<UInt32>(F32Div(UInt32($00000000), UInt32($00000000)))
    .ToBe(UInt32($7FC00000));
  { any NaN input -> canonical output, even with a preserved-looking payload. }
  Expect<UInt32>(F32Add(UInt32($FF800001), F32ToBits(1.0)))
    .ToBe(UInt32($7FC00000));
  { inf - inf is NaN -> canonical. }
  Expect<UInt32>(F32Sub(UInt32($7F800000), UInt32($7F800000)))
    .ToBe(UInt32($7FC00000));
end;

procedure TInterpNumericTests.TestF32MinMax;
begin
  Expect<UInt32>(F32Min(F32ToBits(1.0), F32ToBits(2.0))).ToBe(F32ToBits(1.0));
  Expect<UInt32>(F32Max(F32ToBits(1.0), F32ToBits(2.0))).ToBe(F32ToBits(2.0));
  { the sign-of-zero tie: min(+0,-0) = -0, max(+0,-0) = +0. }
  Expect<UInt32>(F32Min(UInt32($00000000), UInt32($80000000)))
    .ToBe(UInt32($80000000));
  Expect<UInt32>(F32Min(UInt32($80000000), UInt32($00000000)))
    .ToBe(UInt32($80000000));
  Expect<UInt32>(F32Max(UInt32($00000000), UInt32($80000000)))
    .ToBe(UInt32($00000000));
  Expect<UInt32>(F32Max(UInt32($80000000), UInt32($00000000)))
    .ToBe(UInt32($00000000));
  { any NaN operand -> canonical NaN (NOT the other operand). }
  Expect<UInt32>(F32Min(F32ToBits(1.0), UInt32($7FC00000)))
    .ToBe(UInt32($7FC00000));
  Expect<UInt32>(F32Max(UInt32($7F800001), F32ToBits(1.0)))
    .ToBe(UInt32($7FC00000));
  { infinities. }
  Expect<UInt32>(F32Min(UInt32($FF800000), F32ToBits(1.0)))
    .ToBe(UInt32($FF800000));
  Expect<UInt32>(F32Max(UInt32($7F800000), F32ToBits(1.0)))
    .ToBe(UInt32($7F800000));
end;

procedure TInterpNumericTests.TestF32RoundOps;
begin
  { ceil / floor / trunc / nearest at the tie and sign-of-zero edges. }
  Expect<UInt32>(F32Ceil(F32ToBits(1.5))).ToBe(F32ToBits(2.0));
  Expect<UInt32>(F32Floor(F32ToBits(1.5))).ToBe(F32ToBits(1.0));
  Expect<UInt32>(F32Trunc(F32ToBits(1.5))).ToBe(F32ToBits(1.0));
  Expect<UInt32>(F32Ceil(F32ToBits(-1.5))).ToBe(F32ToBits(-1.0));
  Expect<UInt32>(F32Floor(F32ToBits(-1.5))).ToBe(F32ToBits(-2.0));
  Expect<UInt32>(F32Trunc(F32ToBits(-1.5))).ToBe(F32ToBits(-1.0));
  { nearest is ties-to-EVEN, not half-away-from-zero. }
  Expect<UInt32>(F32Nearest(F32ToBits(0.5))).ToBe(UInt32($00000000)); { -> 0 }
  Expect<UInt32>(F32Nearest(F32ToBits(1.5))).ToBe(F32ToBits(2.0));    { -> 2 }
  Expect<UInt32>(F32Nearest(F32ToBits(2.5))).ToBe(F32ToBits(2.0));    { -> 2 }
  Expect<UInt32>(F32Nearest(F32ToBits(3.5))).ToBe(F32ToBits(4.0));    { -> 4 }
  { sign of zero preserved through all four. }
  Expect<UInt32>(F32Trunc(UInt32($80000000))).ToBe(UInt32($80000000)); { -0 }
  Expect<UInt32>(F32Ceil(UInt32($80000000))).ToBe(UInt32($80000000));
  Expect<UInt32>(F32Floor(UInt32($80000000))).ToBe(UInt32($80000000));
  Expect<UInt32>(F32Nearest(UInt32($80000000))).ToBe(UInt32($80000000));
  { -0.5 rounds to -0.0 (nearest) and ceil(-0.5) = -0.0. }
  Expect<UInt32>(F32Nearest(F32ToBits(-0.5))).ToBe(UInt32($80000000));
  Expect<UInt32>(F32Ceil(F32ToBits(-0.5))).ToBe(UInt32($80000000));
  Expect<UInt32>(F32Floor(F32ToBits(-0.5))).ToBe(F32ToBits(-1.0));
  { infinities pass through; NaN -> canonical. }
  Expect<UInt32>(F32Ceil(UInt32($7F800000))).ToBe(UInt32($7F800000));
  Expect<UInt32>(F32Trunc(UInt32($FF800001))).ToBe(UInt32($7FC00000));
end;

procedure TInterpNumericTests.TestF32Sqrt;
begin
  Expect<UInt32>(F32Sqrt(F32ToBits(4.0))).ToBe(F32ToBits(2.0));
  Expect<UInt32>(F32Sqrt(F32ToBits(0.0))).ToBe(UInt32($00000000));
  { sqrt(-0) = -0. }
  Expect<UInt32>(F32Sqrt(UInt32($80000000))).ToBe(UInt32($80000000));
  { sqrt(negative) = canonical NaN; sqrt(NaN) = canonical. }
  Expect<UInt32>(F32Sqrt(F32ToBits(-1.0))).ToBe(UInt32($7FC00000));
  Expect<UInt32>(F32Sqrt(UInt32($FF800001))).ToBe(UInt32($7FC00000));
  { sqrt(+inf) = +inf. }
  Expect<UInt32>(F32Sqrt(UInt32($7F800000))).ToBe(UInt32($7F800000));
end;

procedure TInterpNumericTests.TestF32NegAbsCopysign;
begin
  Expect<UInt32>(F32Neg(F32ToBits(1.0))).ToBe(F32ToBits(-1.0));
  Expect<UInt32>(F32Abs(F32ToBits(-1.0))).ToBe(F32ToBits(1.0));
  { these are BIT ops: a NaN payload must be preserved, only the sign moves. }
  Expect<UInt32>(F32Neg(UInt32($7FC00001))).ToBe(UInt32($FFC00001));
  Expect<UInt32>(F32Abs(UInt32($FFC00005))).ToBe(UInt32($7FC00005));
  Expect<UInt32>(F32Copysign(F32ToBits(1.0), F32ToBits(-2.0)))
    .ToBe(F32ToBits(-1.0));
  Expect<UInt32>(F32Copysign(F32ToBits(-1.0), F32ToBits(2.0)))
    .ToBe(F32ToBits(1.0));
  { copysign preserves the magnitude's NaN payload, takes only the sign. }
  Expect<UInt32>(F32Copysign(UInt32($7FC00005), UInt32($80000000)))
    .ToBe(UInt32($FFC00005));
end;

procedure TInterpNumericTests.TestF32Relops;
begin
  Expect<UInt32>(F32Eq(F32ToBits(1.0), F32ToBits(1.0))).ToBe(1);
  Expect<UInt32>(F32Eq(UInt32($00000000), UInt32($80000000))).ToBe(1); { +0=-0 }
  Expect<UInt32>(F32Lt(F32ToBits(1.0), F32ToBits(2.0))).ToBe(1);
  Expect<UInt32>(F32Ge(F32ToBits(2.0), F32ToBits(2.0))).ToBe(1);
  { NaN is unordered: eq/lt/gt/le/ge false, ne true. }
  Expect<UInt32>(F32Eq(UInt32($7FC00000), UInt32($7FC00000))).ToBe(0);
  Expect<UInt32>(F32Ne(UInt32($7FC00000), UInt32($7FC00000))).ToBe(1);
  Expect<UInt32>(F32Lt(UInt32($7FC00000), F32ToBits(1.0))).ToBe(0);
end;

{ --- f64 float ------------------------------------------------------- }

procedure TInterpNumericTests.TestF64Arithmetic;
begin
  Expect<UInt64>(F64Add(F64ToBits(1.0), F64ToBits(2.0))).ToBe(F64ToBits(3.0));
  Expect<UInt64>(F64Mul(F64ToBits(3.0), F64ToBits(2.0))).ToBe(F64ToBits(6.0));
  Expect<UInt64>(F64Div(F64ToBits(1.0), UInt64($0000000000000000)))
    .ToBe(UInt64($7FF0000000000000)); { +inf }
  Expect<UInt64>(F64Div(UInt64(0), UInt64(0)))
    .ToBe(UInt64($7FF8000000000000)); { 0/0 canonical }
  Expect<UInt64>(F64Add(UInt64($FFF0000000000001), F64ToBits(1.0)))
    .ToBe(UInt64($7FF8000000000000)); { NaN input -> canonical }
end;

procedure TInterpNumericTests.TestF64MinMax;
begin
  Expect<UInt64>(F64Min(F64ToBits(1.0), F64ToBits(2.0))).ToBe(F64ToBits(1.0));
  Expect<UInt64>(F64Max(F64ToBits(1.0), F64ToBits(2.0))).ToBe(F64ToBits(2.0));
  Expect<UInt64>(F64Min(UInt64(0), UInt64($8000000000000000)))
    .ToBe(UInt64($8000000000000000)); { -0 }
  Expect<UInt64>(F64Max(UInt64(0), UInt64($8000000000000000)))
    .ToBe(UInt64($0000000000000000)); { +0 }
  Expect<UInt64>(F64Min(F64ToBits(1.0), UInt64($7FF8000000000000)))
    .ToBe(UInt64($7FF8000000000000)); { NaN -> canonical }
end;

procedure TInterpNumericTests.TestF64RoundOps;
begin
  Expect<UInt64>(F64Ceil(F64ToBits(1.5))).ToBe(F64ToBits(2.0));
  Expect<UInt64>(F64Floor(F64ToBits(-1.5))).ToBe(F64ToBits(-2.0));
  Expect<UInt64>(F64Trunc(F64ToBits(-1.5))).ToBe(F64ToBits(-1.0));
  Expect<UInt64>(F64Nearest(F64ToBits(0.5))).ToBe(UInt64(0));       { -> 0 }
  Expect<UInt64>(F64Nearest(F64ToBits(2.5))).ToBe(F64ToBits(2.0));  { -> 2 }
  Expect<UInt64>(F64Nearest(F64ToBits(-0.5)))
    .ToBe(UInt64($8000000000000000)); { -> -0 }
  Expect<UInt64>(F64Trunc(UInt64($8000000000000000)))
    .ToBe(UInt64($8000000000000000)); { -0 preserved }
  Expect<UInt64>(F64Trunc(UInt64($FFF0000000000001)))
    .ToBe(UInt64($7FF8000000000000)); { NaN -> canonical }
end;

procedure TInterpNumericTests.TestF64Sqrt;
begin
  Expect<UInt64>(F64Sqrt(F64ToBits(4.0))).ToBe(F64ToBits(2.0));
  Expect<UInt64>(F64Sqrt(UInt64($8000000000000000)))
    .ToBe(UInt64($8000000000000000)); { sqrt(-0) = -0 }
  Expect<UInt64>(F64Sqrt(F64ToBits(-1.0)))
    .ToBe(UInt64($7FF8000000000000)); { canonical }
end;

procedure TInterpNumericTests.TestF64NegAbsCopysign;
begin
  Expect<UInt64>(F64Neg(F64ToBits(1.0))).ToBe(F64ToBits(-1.0));
  Expect<UInt64>(F64Abs(F64ToBits(-1.0))).ToBe(F64ToBits(1.0));
  Expect<UInt64>(F64Neg(UInt64($7FF8000000000001)))
    .ToBe(UInt64($FFF8000000000001)); { payload preserved }
  Expect<UInt64>(F64Copysign(F64ToBits(1.0), F64ToBits(-2.0)))
    .ToBe(F64ToBits(-1.0));
end;

procedure TInterpNumericTests.TestF64Relops;
begin
  Expect<UInt32>(F64Eq(F64ToBits(1.0), F64ToBits(1.0))).ToBe(1);
  Expect<UInt32>(F64Lt(F64ToBits(1.0), F64ToBits(2.0))).ToBe(1);
  Expect<UInt32>(F64Ne(UInt64($7FF8000000000000), UInt64($7FF8000000000000)))
    .ToBe(1); { NaN unordered }
  Expect<UInt32>(F64Eq(UInt64($7FF8000000000000), UInt64($7FF8000000000000)))
    .ToBe(0);
end;

{ --- conversions ----------------------------------------------------- }

procedure TInterpNumericTests.TestWrapExtend;
var
  Wide: UInt64;
begin
  Wide := UInt64($00000001FFFFFFFF);
  Expect<UInt32>(I32WrapI64(Wide)).ToBe(UInt32($FFFFFFFF)); { low 32 bits }
  Expect<UInt64>(I64ExtendI32S(UInt32($FFFFFFFF)))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF)); { -1 sign-extended }
  Expect<UInt64>(I64ExtendI32U(UInt32($FFFFFFFF)))
    .ToBe(UInt64($00000000FFFFFFFF)); { zero-extended }
  Expect<UInt32>(I32Extend8S(UInt32($000000FF))).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(I32Extend8S(UInt32($0000007F))).ToBe(UInt32($0000007F));
  Expect<UInt32>(I32Extend16S(UInt32($0000FFFF))).ToBe(UInt32($FFFFFFFF));
  Expect<UInt64>(I64Extend8S(UInt64($00000000000000FF)))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(I64Extend16S(UInt64($000000000000FFFF)))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(I64Extend32S(UInt64($00000000FFFFFFFF)))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF));
end;

procedure TInterpNumericTests.TestConvertIntToFloat;
begin
  Expect<UInt32>(F32ConvertI32S(UInt32(-1))).ToBe(F32ToBits(-1.0));
  { 4294967295 rounds to 2^32 = 0x4F800000. }
  Expect<UInt32>(F32ConvertI32U(UInt32($FFFFFFFF))).ToBe(UInt32($4F800000));
  Expect<UInt64>(F64ConvertI32S(UInt32(-1))).ToBe(F64ToBits(-1.0));
  Expect<UInt32>(F32ConvertI64S(UInt64(Int64(-1)))).ToBe(F32ToBits(-1.0));
  { unsigned 0xFFFF..FF = 2^64-1 rounds to 2^64: f32 0x5F800000, f64 0x43F0.. }
  Expect<UInt32>(F32ConvertI64U(UInt64($FFFFFFFFFFFFFFFF)))
    .ToBe(UInt32($5F800000));
  Expect<UInt64>(F64ConvertI64U(UInt64($FFFFFFFFFFFFFFFF)))
    .ToBe(UInt64($43F0000000000000));
  Expect<UInt64>(F64ConvertI64S(UInt64(Int64(-1)))).ToBe(F64ToBits(-1.0));
  Expect<UInt64>(F64ConvertI32U(UInt32($FFFFFFFF)))
    .ToBe(F64ToBits(4294967295.0)); { exact in f64 }
  { Round-to-nearest-even at the top of the u64 range — the sticky-bit
    cases FPC's x86-64 UInt64->float got wrong (it truncated). All are
    just past the halfway point, so they must round UP. conversions.wast
    522/523 (f32), 537/538 (f64). Host-arch-independent after the fix. }
  Expect<UInt32>(F32ConvertI64U(UInt64($8000008000000001)))
    .ToBe(UInt32($5F000001)); { 2^63 + 2^39 + 1 -> 0x1.000002p+63 }
  Expect<UInt32>(F32ConvertI64U(UInt64($FFFFFE8000000001)))
    .ToBe(UInt32($5F7FFFFF)); { -> 0x1.fffffep+63 }
  Expect<UInt64>(F64ConvertI64U(UInt64($8000000000000401)))
    .ToBe(UInt64($43E0000000000001)); { 2^63 + 1025 -> 0x1.0..1p+63 }
  Expect<UInt64>(F64ConvertI64U(UInt64($8000000000000402)))
    .ToBe(UInt64($43E0000000000001));
end;

procedure TInterpNumericTests.TestDemotePromote;
begin
  Expect<UInt32>(F32DemoteF64(F64ToBits(1.0))).ToBe(F32ToBits(1.0));
  { max f64 overflows f32 -> +inf. }
  Expect<UInt32>(F32DemoteF64(UInt64($7FEFFFFFFFFFFFFF))).ToBe(UInt32($7F800000));
  { NaN -> canonical of the target width. }
  Expect<UInt32>(F32DemoteF64(UInt64($7FF8000000000000))).ToBe(UInt32($7FC00000));
  Expect<UInt64>(F64PromoteF32(F32ToBits(1.0))).ToBe(F64ToBits(1.0));
  Expect<UInt64>(F64PromoteF32(UInt32($7FC00000)))
    .ToBe(UInt64($7FF8000000000000));
end;

{ --- truncations ----------------------------------------------------- }

procedure TInterpNumericTests.TestTruncTrapping;
begin
  { representative + boundary in-range values. }
  Expect<UInt32>(I32TruncF32S(F32ToBits(1.9))).ToBe(UInt32(1));
  Expect<UInt32>(I32TruncF32S(F32ToBits(-1.9))).ToBe(UInt32($FFFFFFFF));
  { -2^31 is exactly representable and in range -> 0x80000000, no trap. }
  Expect<UInt32>(I32TruncF32S(UInt32($CF000000))).ToBe(UInt32($80000000));
  { a boundary fraction must NOT falsely trap: trunc(-2147483648.9) = -2^31. }
  Expect<UInt32>(I32TruncF64S(F64ToBits(-2147483648.9))).ToBe(UInt32($80000000));
  Expect<UInt32>(I32TruncF64S(F64ToBits(2147483647.9))).ToBe(UInt32($7FFFFFFF));
  { unsigned: a negative fraction truncates to 0, not a trap. }
  Expect<UInt32>(I32TruncF32U(F32ToBits(-0.9))).ToBe(UInt32(0));
  Expect<UInt32>(I32TruncF64U(F64ToBits(4294967295.0))).ToBe(UInt32($FFFFFFFF));
  { i64: the u64 high half via the split path. }
  Expect<UInt64>(I64TruncF64S(F64ToBits(-1.5))).ToBe(UInt64($FFFFFFFFFFFFFFFF));
  Expect<UInt64>(I64TruncF64U(F64ToBits(9223372036854775808.0)))
    .ToBe(UInt64($8000000000000000)); { 2^63 in [2^63, 2^64) }
end;

procedure TInterpNumericTests.TestTruncTrapMessages;
var
  Msg: string;
  D32: UInt32;
  D64: UInt64;
begin
  { NaN -> 'invalid conversion to integer'. }
  Msg := '';
  try D32 := I32TruncF32S(UInt32($7FC00000)); if D32 = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_INVALID_CONVERSION);

  { +inf -> 'integer overflow' (NOT invalid conversion — corpus split). }
  Msg := '';
  try D32 := I32TruncF32S(UInt32($7F800000)); if D32 = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_INTEGER_OVERFLOW);

  { 2^31 is the first out-of-range value for i32.trunc_f32_s. }
  Msg := '';
  try D32 := I32TruncF32S(UInt32($4F000000)); if D32 = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_INTEGER_OVERFLOW);

  { -inf on the i64 path. }
  Msg := '';
  try D64 := I64TruncF64S(UInt64($FFF0000000000000));
    if D64 = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_INTEGER_OVERFLOW);

  { negative into unsigned traps overflow, not invalid conversion. }
  Msg := '';
  try D32 := I32TruncF32U(F32ToBits(-1.0)); if D32 = 0 then Msg := ''; except
    on E: EWasmTrap do Msg := E.Message; end;
  Expect<string>(Msg).ToBe(MSG_TRAP_INTEGER_OVERFLOW);
end;

procedure TInterpNumericTests.TestTruncSat;
begin
  { in-range behaves like trunc. }
  Expect<UInt32>(I32TruncSatF32S(F32ToBits(1.9))).ToBe(UInt32(1));
  { NaN -> 0. }
  Expect<UInt32>(I32TruncSatF32S(UInt32($7FC00000))).ToBe(UInt32(0));
  Expect<UInt32>(I32TruncSatF32U(UInt32($7FC00000))).ToBe(UInt32(0));
  { +inf / above-max -> max; -inf / below-min -> min. }
  Expect<UInt32>(I32TruncSatF32S(UInt32($7F800000))).ToBe(UInt32($7FFFFFFF));
  Expect<UInt32>(I32TruncSatF32S(UInt32($FF800000))).ToBe(UInt32($80000000));
  Expect<UInt32>(I32TruncSatF32U(UInt32($FF800000))).ToBe(UInt32(0));
  Expect<UInt32>(I32TruncSatF32U(UInt32($7F800000))).ToBe(UInt32($FFFFFFFF));
  { the first out-of-range finite value saturates (2^31 -> INT32_MAX). }
  Expect<UInt32>(I32TruncSatF32S(UInt32($4F000000))).ToBe(UInt32($7FFFFFFF));
  { i64 saturating incl the +inf -> UINT64_MAX high-half case. }
  Expect<UInt64>(I64TruncSatF64S(UInt64($FFF0000000000000)))
    .ToBe(UInt64($8000000000000000)); { -inf -> INT64_MIN }
  Expect<UInt64>(I64TruncSatF64U(UInt64($7FF0000000000000)))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF)); { +inf -> UINT64_MAX }
  Expect<UInt64>(I64TruncSatF64U(F64ToBits(-1.0))).ToBe(UInt64(0));
  Expect<UInt64>(I64TruncSatF64S(F64ToBits(-1.5))).ToBe(UInt64($FFFFFFFFFFFFFFFF));
end;

procedure TInterpNumericTests.SetupTests;
begin
  Test('reinterpret casts and bit round-trips', TestReinterpretAndBits);
  Test('NaN detection and canonicalization', TestNaNHelpers);

  Test('i32 add/sub/mul wrap modulo 2^32', TestI32AddSubMul);
  Test('i32 and/or/xor', TestI32Bitwise);
  Test('i32 div/rem including INT_MIN/-1', TestI32DivRem);
  Test('i32 div/rem traps by class and message', TestI32DivRemTraps);
  Test('i32 shift/rotate with masked counts', TestI32ShiftRotate);
  Test('i32 clz/ctz/popcnt/eqz including zero', TestI32ClzCtzPopcnt);
  Test('i32 relops signed and unsigned', TestI32Relops);

  Test('i64 add/sub/mul wrap modulo 2^64', TestI64AddSubMul);
  Test('i64 div/rem including INT_MIN/-1', TestI64DivRem);
  Test('i64 div/rem traps by class and message', TestI64DivRemTraps);
  Test('i64 shift/rotate with masked counts', TestI64ShiftRotate);
  Test('i64 clz/ctz/popcnt/eqz including zero', TestI64ClzCtzPopcnt);
  Test('i64 relops signed and unsigned', TestI64Relops);

  Test('f32 add/sub/mul/div and NaN canonicalization', TestF32Arithmetic);
  Test('f32 min/max sign-of-zero and NaN rules', TestF32MinMax);
  Test('f32 ceil/floor/trunc/nearest ties-to-even', TestF32RoundOps);
  Test('f32 sqrt edges', TestF32Sqrt);
  Test('f32 neg/abs/copysign preserve payload', TestF32NegAbsCopysign);
  Test('f32 relops with unordered NaN', TestF32Relops);

  Test('f64 add/mul/div and NaN canonicalization', TestF64Arithmetic);
  Test('f64 min/max sign-of-zero and NaN rules', TestF64MinMax);
  Test('f64 ceil/floor/trunc/nearest ties-to-even', TestF64RoundOps);
  Test('f64 sqrt edges', TestF64Sqrt);
  Test('f64 neg/abs/copysign preserve payload', TestF64NegAbsCopysign);
  Test('f64 relops with unordered NaN', TestF64Relops);

  Test('wrap and the sign/zero extensions', TestWrapExtend);
  Test('int-to-float conversions with rounding', TestConvertIntToFloat);
  Test('demote/promote including NaN and overflow', TestDemotePromote);

  Test('trapping truncations at the range boundaries', TestTruncTrapping);
  Test('trunc trap messages split NaN from overflow', TestTruncTrapMessages);
  Test('saturating truncations clamp instead of trap', TestTruncSat);
end;

{$POP}

begin
  TestRunnerProgram.AddSuite(TInterpNumericTests.Create('Wasm.Interp.Numeric'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
