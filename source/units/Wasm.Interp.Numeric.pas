{ Wasm.Interp.Numeric — pure leaf functions for every non-vector numeric op
  the register IR emits (Track E). No store, no IR, no frames: each
  function maps one wasm numeric operator to a bit-exact result, so the whole
  unit is testable in isolation with literal bit patterns.

  Values are the RAW bit patterns the interpreter keeps in TWasmValue.Bits:
  integer ops take/return UInt32 (i32) or UInt64 (i64); float ops take/return
  the IEEE bit pattern (UInt32 for f32, UInt64 for f64), never a Single/Double
  across a call boundary, so a NaN payload is never mangled in transit and the
  result is stored exactly as computed. The dispatch loop reads A.Bits, calls
  one of these, and writes D.Bits.

  Three spec rules are load-bearing here and each is cited at its site:

  - Integer arithmetic is modulo 2^N (exec-instr-numeric maps each op to the
    generic wrapping operator). Shared.inc turns overflow/range checks ON
    outside PRODUCTION, so a legal wasm wrap would otherwise raise
    EIntOverflow; the implementation section pushes them OFF.
  - div_s/rem_s/div_u/rem_u are PARTIAL (exec-instr-numeric): divide by zero
    traps 'integer divide by zero', and div_s INT_MIN/-1 traps 'integer
    overflow'. rem_s INT_MIN/-1 is 0 and does NOT trap. INT_MIN/-1 must be
    guarded BEFORE the machine idiv, which raises SIGFPE the check-flags
    cannot catch.
  - NaN propagation (aux-nans): "When the result of a floating-point operator
    other than fneg, fabs, or fcopysign is a NaN ... In the deterministic
    profile ... a positive canonical NaN is reliably produced." Every
    payload-affecting op therefore emits the POSITIVE CANONICAL NaN
    ($7FC00000 / $7FF8000000000000), which satisfies BOTH corpus classes
    (nan:canonical exactly, nan:arithmetic because its payload MSB is set).
    neg/abs/copysign/reinterpret are bit ops and preserve the payload. NaN is
    detected by bit test (exponent all-ones AND non-zero significand), never
    x <> x (foldable) and never a Math helper.

  The Math unit is deliberately NOT used: its Min/Max/Floor/Ceil carry their
  own NaN/zero-sign behaviour. wasm min/max/nearest/trunc/ceil/floor are
  implemented explicitly so the semantics are ours and pinned by the tests.

  Float exceptions must be masked (wasm float ops never trap: f32.div by zero
  yields +/-inf or a NaN, instruction_get f32.div can_trap:false). NO arch is
  trusted to mask by default — FPC's darwin/aarch64 startup in fact leaves the
  invalid/overflow trap-enables SET — so every arch is masked explicitly by the
  one exported MaskFpuExceptions, which the initialization below and the
  interpreter's per-thread invoke both call.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Anchors:
  exec-instr-numeric, exec-numeric, aux-nans, exec-cvtop, and the per-op
  instruction_get trap tables cited below. }
unit Wasm.Interp.Numeric;

{$I Shared.inc}

interface

const
  { aux-nans: the canonical NaN of each width — sign 0, exponent all-ones,
    significand MSB the only payload bit set. }
  WASM_F32_CANONICAL_NAN = UInt32($7FC00000);
  WASM_F64_CANONICAL_NAN = UInt64($7FF8000000000000);

{ Mask every FPU arithmetic exception on the CURRENT thread and pin the
  rounding/precision state wasm requires. Per-thread machine state, so the
  interpreter re-applies it on whatever thread runs guest code, not only on
  this unit's initialisation thread. Covers all supported arches:
  - x86_64: MXCSR = $1F80 (all six SSE exceptions masked, round-nearest,
    FTZ off). f32/f64 already round at their native width, no PC field.
  - i386: x87 control word = $027F — all six exceptions masked, round-nearest,
    and PC = 10b (bits 8-9) selecting DOUBLE (53-bit) precision. $037F's PC =
    11b would keep the 80-bit extended precision that double-rounds f32/f64 and
    breaks observational identity (ADR-0010 keeps 32-bit support). SSE math on
    x86_64 is unaffected by this field.
  - aarch64: FPCR cleared (every trap-enable off, round-to-nearest, FTZ off);
    FPC's darwin startup leaves invalid/overflow enabled, so this is required. }
procedure MaskFpuExceptions;

{ --- reinterpret / NaN helpers --------------------------------------- }

{ The reinterpret casts (f32.reinterpret_i32 and friends are pure bit
  copies). Pointer reinterpretation, so a NaN payload survives untouched. }
function BitsToF32(const ABits: UInt32): Single; inline;
function F32ToBits(const AValue: Single): UInt32; inline;
function BitsToF64(const ABits: UInt64): Double; inline;
function F64ToBits(const AValue: Double): UInt64; inline;

{ NaN by bit test (syntax-nan): exponent field all-ones and significand
  non-zero. Not x <> x. }
function F32IsNan(const ABits: UInt32): Boolean; inline;
function F64IsNan(const ABits: UInt64): Boolean; inline;

{ aux-nans deterministic profile: any NaN result collapses to the positive
  canonical pattern; a non-NaN passes through unchanged. }
function CanonicalizeF32(const ABits: UInt32): UInt32; inline;
function CanonicalizeF64(const ABits: UInt64): UInt64; inline;

{ Same-width reinterpret ops (bit identity, exposed for completeness). }
function F32ReinterpretI32(const A: UInt32): UInt32; inline;
function I32ReinterpretF32(const A: UInt32): UInt32; inline;
function F64ReinterpretI64(const A: UInt64): UInt64; inline;
function I64ReinterpretF64(const A: UInt64): UInt64; inline;

{ --- i32 integer ----------------------------------------------------- }

function I32Add(const A, B: UInt32): UInt32; inline;
function I32Sub(const A, B: UInt32): UInt32; inline;
function I32Mul(const A, B: UInt32): UInt32; inline;
function I32DivS(const A, B: UInt32): UInt32;
function I32DivU(const A, B: UInt32): UInt32;
function I32RemS(const A, B: UInt32): UInt32;
function I32RemU(const A, B: UInt32): UInt32;
function I32And(const A, B: UInt32): UInt32; inline;
function I32Or(const A, B: UInt32): UInt32; inline;
function I32Xor(const A, B: UInt32): UInt32; inline;
function I32Shl(const A, B: UInt32): UInt32; inline;
function I32ShrS(const A, B: UInt32): UInt32;
function I32ShrU(const A, B: UInt32): UInt32; inline;
function I32Rotl(const A, B: UInt32): UInt32;
function I32Rotr(const A, B: UInt32): UInt32;
function I32Clz(const A: UInt32): UInt32;
function I32Ctz(const A: UInt32): UInt32;
function I32Popcnt(const A: UInt32): UInt32;
function I32Eqz(const A: UInt32): UInt32; inline;

function I32Eq(const A, B: UInt32): UInt32; inline;
function I32Ne(const A, B: UInt32): UInt32; inline;
function I32LtS(const A, B: UInt32): UInt32; inline;
function I32LtU(const A, B: UInt32): UInt32; inline;
function I32GtS(const A, B: UInt32): UInt32; inline;
function I32GtU(const A, B: UInt32): UInt32; inline;
function I32LeS(const A, B: UInt32): UInt32; inline;
function I32LeU(const A, B: UInt32): UInt32; inline;
function I32GeS(const A, B: UInt32): UInt32; inline;
function I32GeU(const A, B: UInt32): UInt32; inline;

{ --- i64 integer ----------------------------------------------------- }

function I64Add(const A, B: UInt64): UInt64; inline;
function I64Sub(const A, B: UInt64): UInt64; inline;
function I64Mul(const A, B: UInt64): UInt64; inline;
function I64DivS(const A, B: UInt64): UInt64;
function I64DivU(const A, B: UInt64): UInt64;
function I64RemS(const A, B: UInt64): UInt64;
function I64RemU(const A, B: UInt64): UInt64;
function I64And(const A, B: UInt64): UInt64; inline;
function I64Or(const A, B: UInt64): UInt64; inline;
function I64Xor(const A, B: UInt64): UInt64; inline;
function I64Shl(const A, B: UInt64): UInt64; inline;
function I64ShrS(const A, B: UInt64): UInt64;
function I64ShrU(const A, B: UInt64): UInt64; inline;
function I64Rotl(const A, B: UInt64): UInt64;
function I64Rotr(const A, B: UInt64): UInt64;
function I64Clz(const A: UInt64): UInt64;
function I64Ctz(const A: UInt64): UInt64;
function I64Popcnt(const A: UInt64): UInt64;
function I64Eqz(const A: UInt64): UInt32; inline;

function I64Eq(const A, B: UInt64): UInt32; inline;
function I64Ne(const A, B: UInt64): UInt32; inline;
function I64LtS(const A, B: UInt64): UInt32; inline;
function I64LtU(const A, B: UInt64): UInt32; inline;
function I64GtS(const A, B: UInt64): UInt32; inline;
function I64GtU(const A, B: UInt64): UInt32; inline;
function I64LeS(const A, B: UInt64): UInt32; inline;
function I64LeU(const A, B: UInt64): UInt32; inline;
function I64GeS(const A, B: UInt64): UInt32; inline;
function I64GeU(const A, B: UInt64): UInt32; inline;

{ --- f32 float ------------------------------------------------------- }

function F32Add(const A, B: UInt32): UInt32;
function F32Sub(const A, B: UInt32): UInt32;
function F32Mul(const A, B: UInt32): UInt32;
function F32Div(const A, B: UInt32): UInt32;
function F32Min(const A, B: UInt32): UInt32;
function F32Max(const A, B: UInt32): UInt32;
function F32Sqrt(const A: UInt32): UInt32;
function F32Ceil(const A: UInt32): UInt32;
function F32Floor(const A: UInt32): UInt32;
function F32Trunc(const A: UInt32): UInt32;
function F32Nearest(const A: UInt32): UInt32;
function F32Neg(const A: UInt32): UInt32; inline;
function F32Abs(const A: UInt32): UInt32; inline;
function F32Copysign(const A, B: UInt32): UInt32; inline;

function F32Eq(const A, B: UInt32): UInt32; inline;
function F32Ne(const A, B: UInt32): UInt32; inline;
function F32Lt(const A, B: UInt32): UInt32; inline;
function F32Gt(const A, B: UInt32): UInt32; inline;
function F32Le(const A, B: UInt32): UInt32; inline;
function F32Ge(const A, B: UInt32): UInt32; inline;

{ --- f64 float ------------------------------------------------------- }

function F64Add(const A, B: UInt64): UInt64;
function F64Sub(const A, B: UInt64): UInt64;
function F64Mul(const A, B: UInt64): UInt64;
function F64Div(const A, B: UInt64): UInt64;
function F64Min(const A, B: UInt64): UInt64;
function F64Max(const A, B: UInt64): UInt64;
function F64Sqrt(const A: UInt64): UInt64;
function F64Ceil(const A: UInt64): UInt64;
function F64Floor(const A: UInt64): UInt64;
function F64Trunc(const A: UInt64): UInt64;
function F64Nearest(const A: UInt64): UInt64;
function F64Neg(const A: UInt64): UInt64; inline;
function F64Abs(const A: UInt64): UInt64; inline;
function F64Copysign(const A, B: UInt64): UInt64; inline;

function F64Eq(const A, B: UInt64): UInt32; inline;
function F64Ne(const A, B: UInt64): UInt32; inline;
function F64Lt(const A, B: UInt64): UInt32; inline;
function F64Gt(const A, B: UInt64): UInt32; inline;
function F64Le(const A, B: UInt64): UInt32; inline;
function F64Ge(const A, B: UInt64): UInt32; inline;

{ --- conversions ----------------------------------------------------- }

function I32WrapI64(const A: UInt64): UInt32; inline;
function I64ExtendI32S(const A: UInt32): UInt64; inline;
function I64ExtendI32U(const A: UInt32): UInt64; inline;
function I32Extend8S(const A: UInt32): UInt32; inline;
function I32Extend16S(const A: UInt32): UInt32; inline;
function I64Extend8S(const A: UInt64): UInt64; inline;
function I64Extend16S(const A: UInt64): UInt64; inline;
function I64Extend32S(const A: UInt64): UInt64; inline;

function F32DemoteF64(const A: UInt64): UInt32;
function F64PromoteF32(const A: UInt32): UInt64;

function F32ConvertI32S(const A: UInt32): UInt32;
function F32ConvertI32U(const A: UInt32): UInt32;
function F32ConvertI64S(const A: UInt64): UInt32;
function F32ConvertI64U(const A: UInt64): UInt32;
function F64ConvertI32S(const A: UInt32): UInt64;
function F64ConvertI32U(const A: UInt32): UInt64;
function F64ConvertI64S(const A: UInt64): UInt64;
function F64ConvertI64U(const A: UInt64): UInt64;

{ Trapping truncations (exec-cvtop): NaN -> 'invalid conversion to integer',
  out-of-range (incl +/-inf) -> 'integer overflow'. }
function I32TruncF32S(const A: UInt32): UInt32;
function I32TruncF32U(const A: UInt32): UInt32;
function I32TruncF64S(const A: UInt64): UInt32;
function I32TruncF64U(const A: UInt64): UInt32;
function I64TruncF32S(const A: UInt32): UInt64;
function I64TruncF32U(const A: UInt32): UInt64;
function I64TruncF64S(const A: UInt64): UInt64;
function I64TruncF64U(const A: UInt64): UInt64;

{ Saturating truncations (never trap): NaN -> 0, below-min/-inf -> min,
  above-max/+inf -> max, else truncated. }
function I32TruncSatF32S(const A: UInt32): UInt32;
function I32TruncSatF32U(const A: UInt32): UInt32;
function I32TruncSatF64S(const A: UInt64): UInt32;
function I32TruncSatF64U(const A: UInt64): UInt32;
function I64TruncSatF32S(const A: UInt32): UInt64;
function I64TruncSatF32U(const A: UInt32): UInt64;
function I64TruncSatF64S(const A: UInt64): UInt64;
function I64TruncSatF64U(const A: UInt64): UInt64;

implementation

uses
  Wasm.Runtime.Traps;

{ Every function below relies on modulo-2^N integer arithmetic; Shared.inc
  turns the checks ON outside PRODUCTION, so push them OFF for the whole
  unit (exec-instr-numeric maps each op to the wrapping generic operator). }
{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

const
  { Exact float boundaries for the truncations (all powers of two, so exactly
    representable in Double after an f32 source is widened losslessly). The
    valid post-trunc range for target T is [lo, hiExcl); +/-inf and NaN fall
    outside by construction. Values verified against conversions.wast. }
  F_2P31 = 2147483648.0;               { 2^31 }
  F_NEG_2P31 = -2147483648.0;          { -2^31 }
  F_2P32 = 4294967296.0;               { 2^32 }
  F_2P63 = 9223372036854775808.0;      { 2^63 }
  F_NEG_2P63 = -9223372036854775808.0; { -2^63 }
  F_2P64 = 18446744073709551616.0;     { 2^64 }
  TWO52 = 4503599627370496.0;          { 2^52: at/above this a Double is integral }

  MASK_F32_SIGN = UInt32($80000000);
  MASK_F32_MAG = UInt32($7FFFFFFF);
  MASK_F32_EXP = UInt32($7F800000);
  MASK_F32_FRAC = UInt32($007FFFFF);
  MASK_F64_SIGN = UInt64($8000000000000000);
  MASK_F64_MAG = UInt64($7FFFFFFFFFFFFFFF);
  MASK_F64_EXP = UInt64($7FF0000000000000);
  MASK_F64_FRAC = UInt64($000FFFFFFFFFFFFF);

{ --- reinterpret / NaN helpers --------------------------------------- }

function BitsToF32(const ABits: UInt32): Single;
begin
  Result := PSingle(@ABits)^;
end;

function F32ToBits(const AValue: Single): UInt32;
begin
  Result := PUInt32(@AValue)^;
end;

function BitsToF64(const ABits: UInt64): Double;
begin
  Result := PDouble(@ABits)^;
end;

function F64ToBits(const AValue: Double): UInt64;
begin
  Result := PUInt64(@AValue)^;
end;

function F32IsNan(const ABits: UInt32): Boolean;
begin
  Result := ((ABits and MASK_F32_EXP) = MASK_F32_EXP) and
    ((ABits and MASK_F32_FRAC) <> 0);
end;

function F64IsNan(const ABits: UInt64): Boolean;
begin
  Result := ((ABits and MASK_F64_EXP) = MASK_F64_EXP) and
    ((ABits and MASK_F64_FRAC) <> 0);
end;

function CanonicalizeF32(const ABits: UInt32): UInt32;
begin
  if F32IsNan(ABits) then
    Result := WASM_F32_CANONICAL_NAN
  else
    Result := ABits;
end;

function CanonicalizeF64(const ABits: UInt64): UInt64;
begin
  if F64IsNan(ABits) then
    Result := WASM_F64_CANONICAL_NAN
  else
    Result := ABits;
end;

function F32ReinterpretI32(const A: UInt32): UInt32;
begin
  Result := A;
end;

function I32ReinterpretF32(const A: UInt32): UInt32;
begin
  Result := A;
end;

function F64ReinterpretI64(const A: UInt64): UInt64;
begin
  Result := A;
end;

function I64ReinterpretF64(const A: UInt64): UInt64;
begin
  Result := A;
end;

{ --- i32 integer ----------------------------------------------------- }

function I32Add(const A, B: UInt32): UInt32;
begin
  Result := A + B;
end;

function I32Sub(const A, B: UInt32): UInt32;
begin
  Result := A - B;
end;

function I32Mul(const A, B: UInt32): UInt32;
begin
  Result := A * B;
end;

{ i32.div_s: instruction_get reports traps 'integer divide by zero' and
  'integer overflow'. INT_MIN/-1 must be caught before idiv (SIGFPE). }
function I32DivS(const A, B: UInt32): UInt32;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  if (Int32(A) = Low(Int32)) and (Int32(B) = -1) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt32(Int32(A) div Int32(B));
end;

function I32DivU(const A, B: UInt32): UInt32;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  Result := A div B;
end;

{ i32.rem_s: divide by zero traps; INT_MIN/-1 is 0 and does NOT trap (only
  div_s overflows there). FPC 'mod' takes the sign of the dividend, matching
  wasm's truncated remainder. }
function I32RemS(const A, B: UInt32): UInt32;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  if (Int32(A) = Low(Int32)) and (Int32(B) = -1) then
    Exit(0);
  Result := UInt32(Int32(A) mod Int32(B));
end;

function I32RemU(const A, B: UInt32): UInt32;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  Result := A mod B;
end;

function I32And(const A, B: UInt32): UInt32;
begin
  Result := A and B;
end;

function I32Or(const A, B: UInt32): UInt32;
begin
  Result := A or B;
end;

function I32Xor(const A, B: UInt32): UInt32;
begin
  Result := A xor B;
end;

{ Shift/rotate counts are taken modulo the width (exec-numeric ishl/ishr). }
function I32Shl(const A, B: UInt32): UInt32;
begin
  Result := A shl (B and 31);
end;

{ Arithmetic right shift by hand: FPC 'shr' is always logical, so fill the
  vacated high bits with the sign when the operand is negative. }
function I32ShrS(const A, B: UInt32): UInt32;
var
  Count: UInt32;
begin
  Count := B and 31;
  if (A and MASK_F32_SIGN) <> 0 then
    Result := (A shr Count) or not (UInt32($FFFFFFFF) shr Count)
  else
    Result := A shr Count;
end;

function I32ShrU(const A, B: UInt32): UInt32;
begin
  Result := A shr (B and 31);
end;

function I32Rotl(const A, B: UInt32): UInt32;
var
  Count: UInt32;
begin
  Count := B and 31;
  if Count = 0 then
    Result := A
  else
    Result := (A shl Count) or (A shr (32 - Count));
end;

function I32Rotr(const A, B: UInt32): UInt32;
var
  Count: UInt32;
begin
  Count := B and 31;
  if Count = 0 then
    Result := A
  else
    Result := (A shr Count) or (A shl (32 - Count));
end;

{ clz/ctz are the full width for a zero operand (exec-numeric iclz/ictz).
  Plain loops per the RTL policy; intrinsics only behind a wasmbench number. }
function I32Clz(const A: UInt32): UInt32;
var
  Mask: UInt32;
begin
  if A = 0 then
    Exit(32);
  Result := 0;
  Mask := MASK_F32_SIGN;
  while (A and Mask) = 0 do
  begin
    Inc(Result);
    Mask := Mask shr 1;
  end;
end;

function I32Ctz(const A: UInt32): UInt32;
var
  Mask: UInt32;
begin
  if A = 0 then
    Exit(32);
  Result := 0;
  Mask := 1;
  while (A and Mask) = 0 do
  begin
    Inc(Result);
    Mask := Mask shl 1;
  end;
end;

function I32Popcnt(const A: UInt32): UInt32;
var
  Bits: UInt32;
begin
  Result := 0;
  Bits := A;
  while Bits <> 0 do
  begin
    Inc(Result, Bits and 1);
    Bits := Bits shr 1;
  end;
end;

function I32Eqz(const A: UInt32): UInt32;
begin
  Result := Ord(A = 0);
end;

function I32Eq(const A, B: UInt32): UInt32;
begin
  Result := Ord(A = B);
end;

function I32Ne(const A, B: UInt32): UInt32;
begin
  Result := Ord(A <> B);
end;

function I32LtS(const A, B: UInt32): UInt32;
begin
  Result := Ord(Int32(A) < Int32(B));
end;

function I32LtU(const A, B: UInt32): UInt32;
begin
  Result := Ord(A < B);
end;

function I32GtS(const A, B: UInt32): UInt32;
begin
  Result := Ord(Int32(A) > Int32(B));
end;

function I32GtU(const A, B: UInt32): UInt32;
begin
  Result := Ord(A > B);
end;

function I32LeS(const A, B: UInt32): UInt32;
begin
  Result := Ord(Int32(A) <= Int32(B));
end;

function I32LeU(const A, B: UInt32): UInt32;
begin
  Result := Ord(A <= B);
end;

function I32GeS(const A, B: UInt32): UInt32;
begin
  Result := Ord(Int32(A) >= Int32(B));
end;

function I32GeU(const A, B: UInt32): UInt32;
begin
  Result := Ord(A >= B);
end;

{ --- i64 integer ----------------------------------------------------- }

function I64Add(const A, B: UInt64): UInt64;
begin
  Result := A + B;
end;

function I64Sub(const A, B: UInt64): UInt64;
begin
  Result := A - B;
end;

function I64Mul(const A, B: UInt64): UInt64;
begin
  Result := A * B;
end;

function I64DivS(const A, B: UInt64): UInt64;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  if (Int64(A) = Low(Int64)) and (Int64(B) = -1) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt64(Int64(A) div Int64(B));
end;

function I64DivU(const A, B: UInt64): UInt64;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  Result := A div B;
end;

function I64RemS(const A, B: UInt64): UInt64;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  if (Int64(A) = Low(Int64)) and (Int64(B) = -1) then
    Exit(0);
  Result := UInt64(Int64(A) mod Int64(B));
end;

function I64RemU(const A, B: UInt64): UInt64;
begin
  if B = 0 then
    TrapNow(wtkDivideByZero);
  Result := A mod B;
end;

function I64And(const A, B: UInt64): UInt64;
begin
  Result := A and B;
end;

function I64Or(const A, B: UInt64): UInt64;
begin
  Result := A or B;
end;

function I64Xor(const A, B: UInt64): UInt64;
begin
  Result := A xor B;
end;

function I64Shl(const A, B: UInt64): UInt64;
begin
  Result := A shl (B and 63);
end;

function I64ShrS(const A, B: UInt64): UInt64;
var
  Count: UInt64;
begin
  Count := B and 63;
  if (A and MASK_F64_SIGN) <> 0 then
    Result := (A shr Count) or not (UInt64($FFFFFFFFFFFFFFFF) shr Count)
  else
    Result := A shr Count;
end;

function I64ShrU(const A, B: UInt64): UInt64;
begin
  Result := A shr (B and 63);
end;

function I64Rotl(const A, B: UInt64): UInt64;
var
  Count: UInt64;
begin
  Count := B and 63;
  if Count = 0 then
    Result := A
  else
    Result := (A shl Count) or (A shr (64 - Count));
end;

function I64Rotr(const A, B: UInt64): UInt64;
var
  Count: UInt64;
begin
  Count := B and 63;
  if Count = 0 then
    Result := A
  else
    Result := (A shr Count) or (A shl (64 - Count));
end;

function I64Clz(const A: UInt64): UInt64;
var
  Mask: UInt64;
begin
  if A = 0 then
    Exit(64);
  Result := 0;
  Mask := MASK_F64_SIGN;
  while (A and Mask) = 0 do
  begin
    Inc(Result);
    Mask := Mask shr 1;
  end;
end;

function I64Ctz(const A: UInt64): UInt64;
var
  Mask: UInt64;
begin
  if A = 0 then
    Exit(64);
  Result := 0;
  Mask := 1;
  while (A and Mask) = 0 do
  begin
    Inc(Result);
    Mask := Mask shl 1;
  end;
end;

function I64Popcnt(const A: UInt64): UInt64;
var
  Bits: UInt64;
begin
  Result := 0;
  Bits := A;
  while Bits <> 0 do
  begin
    Inc(Result, Bits and 1);
    Bits := Bits shr 1;
  end;
end;

function I64Eqz(const A: UInt64): UInt32;
begin
  Result := Ord(A = 0);
end;

function I64Eq(const A, B: UInt64): UInt32;
begin
  Result := Ord(A = B);
end;

function I64Ne(const A, B: UInt64): UInt32;
begin
  Result := Ord(A <> B);
end;

function I64LtS(const A, B: UInt64): UInt32;
begin
  Result := Ord(Int64(A) < Int64(B));
end;

function I64LtU(const A, B: UInt64): UInt32;
begin
  Result := Ord(A < B);
end;

function I64GtS(const A, B: UInt64): UInt32;
begin
  Result := Ord(Int64(A) > Int64(B));
end;

function I64GtU(const A, B: UInt64): UInt32;
begin
  Result := Ord(A > B);
end;

function I64LeS(const A, B: UInt64): UInt32;
begin
  Result := Ord(Int64(A) <= Int64(B));
end;

function I64LeU(const A, B: UInt64): UInt32;
begin
  Result := Ord(A <= B);
end;

function I64GeS(const A, B: UInt64): UInt32;
begin
  Result := Ord(Int64(A) >= Int64(B));
end;

function I64GeU(const A, B: UInt64): UInt32;
begin
  Result := Ord(A >= B);
end;

{ --- shared float rounding on Double (exec-numeric ftrunc/ffloor/fceil/
  fnearest) — explicit so the sign of zero and ties-to-even are ours ---- }

{ Truncate toward zero, preserving the sign of zero and passing +/-inf
  through. Operand must not be NaN. }
function DTrunc(const X: Double): Double;
var
  Bits: UInt64;
  Magnitude, Rounded: Double;
begin
  Bits := F64ToBits(X);
  Magnitude := BitsToF64(Bits and MASK_F64_MAG);
  if Magnitude >= TWO52 then
    Exit(X); { already integral, or +/-inf }
  Rounded := Int64(Trunc(Magnitude)); { 0 <= Magnitude < 2^52, exact }
  if (Bits and MASK_F64_SIGN) <> 0 then
    Result := -Rounded { -0.0 when Rounded is zero }
  else
    Result := Rounded;
end;

function DFloor(const X: Double): Double;
var
  Truncated: Double;
begin
  Truncated := DTrunc(X);
  if Truncated > X then
    Result := Truncated - 1.0 { negative, non-integral }
  else
    Result := Truncated;
end;

function DCeil(const X: Double): Double;
var
  Truncated: Double;
begin
  Truncated := DTrunc(X);
  if Truncated < X then
    Result := Truncated + 1.0 { positive, non-integral }
  else
    Result := Truncated;
end;

{ Round to nearest, ties to even (roundTiesToEven), preserving the sign of
  zero. Operand must not be NaN. }
function DNearest(const X: Double): Double;
var
  Bits: UInt64;
  Truncated, Frac: Double;
begin
  Bits := F64ToBits(X);
  if BitsToF64(Bits and MASK_F64_MAG) >= TWO52 then
    Exit(X); { already integral, or +/-inf }
  Truncated := DTrunc(X);
  Frac := X - Truncated; { in (-1, 1) }
  if Frac > 0.5 then
    Result := Truncated + 1.0
  else if Frac < -0.5 then
    Result := Truncated - 1.0
  else if Frac = 0.5 then
  begin
    if (Int64(Trunc(Truncated)) and 1) = 0 then
      Result := Truncated { even neighbour }
    else
      Result := Truncated + 1.0;
  end
  else if Frac = -0.5 then
  begin
    if (Int64(Trunc(Truncated)) and 1) = 0 then
      Result := Truncated
    else
      Result := Truncated - 1.0;
  end
  else
    Result := Truncated; { |Frac| < 0.5 }
  { A zero result carries the sign of the operand (fnearest(-0.5) = -0.0). }
  if Result = 0.0 then
    if (Bits and MASK_F64_SIGN) <> 0 then
      Result := BitsToF64(MASK_F64_SIGN)
    else
      Result := 0.0;
end;

{ --- f32 float ------------------------------------------------------- }

function F32Add(const A, B: UInt32): UInt32;
var
  R: Single;
begin
  R := BitsToF32(A) + BitsToF32(B);
  Result := CanonicalizeF32(F32ToBits(R));
end;

function F32Sub(const A, B: UInt32): UInt32;
var
  R: Single;
begin
  R := BitsToF32(A) - BitsToF32(B);
  Result := CanonicalizeF32(F32ToBits(R));
end;

function F32Mul(const A, B: UInt32): UInt32;
var
  R: Single;
begin
  R := BitsToF32(A) * BitsToF32(B);
  Result := CanonicalizeF32(F32ToBits(R));
end;

function F32Div(const A, B: UInt32): UInt32;
var
  R: Single;
begin
  { f32.div can_trap:false — divide by zero yields +/-inf or a NaN. }
  R := BitsToF32(A) / BitsToF32(B);
  Result := CanonicalizeF32(F32ToBits(R));
end;

{ wasm fmin/fmax are NOT IEEE minNum/maxNum: any NaN operand yields a NaN,
  and the +/-0 tie is decided by sign, not by '<'. For the tie the two bit
  patterns differ only in the sign bit, so OR selects -0 (min) and AND
  selects +0 (max). }
function F32Min(const A, B: UInt32): UInt32;
var
  Fa, Fb: Single;
begin
  if F32IsNan(A) or F32IsNan(B) then
    Exit(WASM_F32_CANONICAL_NAN);
  Fa := BitsToF32(A);
  Fb := BitsToF32(B);
  if Fa < Fb then
    Result := A
  else if Fb < Fa then
    Result := B
  else
    Result := A or B; { equal, incl +/-0: -0 wins }
end;

function F32Max(const A, B: UInt32): UInt32;
var
  Fa, Fb: Single;
begin
  if F32IsNan(A) or F32IsNan(B) then
    Exit(WASM_F32_CANONICAL_NAN);
  Fa := BitsToF32(A);
  Fb := BitsToF32(B);
  if Fa > Fb then
    Result := A
  else if Fb > Fa then
    Result := B
  else
    Result := A and B; { equal, incl +/-0: +0 wins }
end;

function F32Sqrt(const A: UInt32): UInt32;
var
  R: Single;
begin
  { fsqrt(-0) = -0, fsqrt(negative) = NaN (canonicalized). }
  R := Sqrt(BitsToF32(A));
  Result := CanonicalizeF32(F32ToBits(R));
end;

function F32Ceil(const A: UInt32): UInt32;
var
  R: Single;
begin
  if F32IsNan(A) then
    Exit(WASM_F32_CANONICAL_NAN);
  R := DCeil(BitsToF32(A));
  Result := F32ToBits(R);
end;

function F32Floor(const A: UInt32): UInt32;
var
  R: Single;
begin
  if F32IsNan(A) then
    Exit(WASM_F32_CANONICAL_NAN);
  R := DFloor(BitsToF32(A));
  Result := F32ToBits(R);
end;

function F32Trunc(const A: UInt32): UInt32;
var
  R: Single;
begin
  if F32IsNan(A) then
    Exit(WASM_F32_CANONICAL_NAN);
  R := DTrunc(BitsToF32(A));
  Result := F32ToBits(R);
end;

function F32Nearest(const A: UInt32): UInt32;
var
  R: Single;
begin
  if F32IsNan(A) then
    Exit(WASM_F32_CANONICAL_NAN);
  R := DNearest(BitsToF32(A));
  Result := F32ToBits(R);
end;

{ Exempt bit ops — payload preserved, own sign rules (aux-nans). }
function F32Neg(const A: UInt32): UInt32;
begin
  Result := A xor MASK_F32_SIGN;
end;

function F32Abs(const A: UInt32): UInt32;
begin
  Result := A and MASK_F32_MAG;
end;

function F32Copysign(const A, B: UInt32): UInt32;
begin
  Result := (A and MASK_F32_MAG) or (B and MASK_F32_SIGN);
end;

function F32Eq(const A, B: UInt32): UInt32;
begin
  Result := Ord(BitsToF32(A) = BitsToF32(B));
end;

function F32Ne(const A, B: UInt32): UInt32;
begin
  Result := Ord(BitsToF32(A) <> BitsToF32(B));
end;

function F32Lt(const A, B: UInt32): UInt32;
begin
  Result := Ord(BitsToF32(A) < BitsToF32(B));
end;

function F32Gt(const A, B: UInt32): UInt32;
begin
  Result := Ord(BitsToF32(A) > BitsToF32(B));
end;

function F32Le(const A, B: UInt32): UInt32;
begin
  Result := Ord(BitsToF32(A) <= BitsToF32(B));
end;

function F32Ge(const A, B: UInt32): UInt32;
begin
  Result := Ord(BitsToF32(A) >= BitsToF32(B));
end;

{ --- f64 float ------------------------------------------------------- }

function F64Add(const A, B: UInt64): UInt64;
var
  R: Double;
begin
  R := BitsToF64(A) + BitsToF64(B);
  Result := CanonicalizeF64(F64ToBits(R));
end;

function F64Sub(const A, B: UInt64): UInt64;
var
  R: Double;
begin
  R := BitsToF64(A) - BitsToF64(B);
  Result := CanonicalizeF64(F64ToBits(R));
end;

function F64Mul(const A, B: UInt64): UInt64;
var
  R: Double;
begin
  R := BitsToF64(A) * BitsToF64(B);
  Result := CanonicalizeF64(F64ToBits(R));
end;

function F64Div(const A, B: UInt64): UInt64;
var
  R: Double;
begin
  R := BitsToF64(A) / BitsToF64(B);
  Result := CanonicalizeF64(F64ToBits(R));
end;

function F64Min(const A, B: UInt64): UInt64;
var
  Fa, Fb: Double;
begin
  if F64IsNan(A) or F64IsNan(B) then
    Exit(WASM_F64_CANONICAL_NAN);
  Fa := BitsToF64(A);
  Fb := BitsToF64(B);
  if Fa < Fb then
    Result := A
  else if Fb < Fa then
    Result := B
  else
    Result := A or B;
end;

function F64Max(const A, B: UInt64): UInt64;
var
  Fa, Fb: Double;
begin
  if F64IsNan(A) or F64IsNan(B) then
    Exit(WASM_F64_CANONICAL_NAN);
  Fa := BitsToF64(A);
  Fb := BitsToF64(B);
  if Fa > Fb then
    Result := A
  else if Fb > Fa then
    Result := B
  else
    Result := A and B;
end;

function F64Sqrt(const A: UInt64): UInt64;
var
  R: Double;
begin
  R := Sqrt(BitsToF64(A));
  Result := CanonicalizeF64(F64ToBits(R));
end;

function F64Ceil(const A: UInt64): UInt64;
begin
  if F64IsNan(A) then
    Exit(WASM_F64_CANONICAL_NAN);
  Result := F64ToBits(DCeil(BitsToF64(A)));
end;

function F64Floor(const A: UInt64): UInt64;
begin
  if F64IsNan(A) then
    Exit(WASM_F64_CANONICAL_NAN);
  Result := F64ToBits(DFloor(BitsToF64(A)));
end;

function F64Trunc(const A: UInt64): UInt64;
begin
  if F64IsNan(A) then
    Exit(WASM_F64_CANONICAL_NAN);
  Result := F64ToBits(DTrunc(BitsToF64(A)));
end;

function F64Nearest(const A: UInt64): UInt64;
begin
  if F64IsNan(A) then
    Exit(WASM_F64_CANONICAL_NAN);
  Result := F64ToBits(DNearest(BitsToF64(A)));
end;

function F64Neg(const A: UInt64): UInt64;
begin
  Result := A xor MASK_F64_SIGN;
end;

function F64Abs(const A: UInt64): UInt64;
begin
  Result := A and MASK_F64_MAG;
end;

function F64Copysign(const A, B: UInt64): UInt64;
begin
  Result := (A and MASK_F64_MAG) or (B and MASK_F64_SIGN);
end;

function F64Eq(const A, B: UInt64): UInt32;
begin
  Result := Ord(BitsToF64(A) = BitsToF64(B));
end;

function F64Ne(const A, B: UInt64): UInt32;
begin
  Result := Ord(BitsToF64(A) <> BitsToF64(B));
end;

function F64Lt(const A, B: UInt64): UInt32;
begin
  Result := Ord(BitsToF64(A) < BitsToF64(B));
end;

function F64Gt(const A, B: UInt64): UInt32;
begin
  Result := Ord(BitsToF64(A) > BitsToF64(B));
end;

function F64Le(const A, B: UInt64): UInt32;
begin
  Result := Ord(BitsToF64(A) <= BitsToF64(B));
end;

function F64Ge(const A, B: UInt64): UInt32;
begin
  Result := Ord(BitsToF64(A) >= BitsToF64(B));
end;

{ --- conversions ----------------------------------------------------- }

function I32WrapI64(const A: UInt64): UInt32;
begin
  Result := UInt32(A);
end;

function I64ExtendI32S(const A: UInt32): UInt64;
begin
  Result := UInt64(Int64(Int32(A)));
end;

function I64ExtendI32U(const A: UInt32): UInt64;
begin
  Result := UInt64(A);
end;

function I32Extend8S(const A: UInt32): UInt32;
begin
  Result := UInt32(Int32(ShortInt(Byte(A))));
end;

function I32Extend16S(const A: UInt32): UInt32;
begin
  Result := UInt32(Int32(SmallInt(Word(A))));
end;

function I64Extend8S(const A: UInt64): UInt64;
begin
  Result := UInt64(Int64(ShortInt(Byte(A))));
end;

function I64Extend16S(const A: UInt64): UInt64;
begin
  Result := UInt64(Int64(SmallInt(Word(A))));
end;

function I64Extend32S(const A: UInt64): UInt64;
begin
  Result := UInt64(Int64(Int32(UInt32(A))));
end;

function F32DemoteF64(const A: UInt64): UInt32;
var
  R: Single;
begin
  R := BitsToF64(A); { narrow, round-nearest-even; overflow -> +/-inf }
  Result := CanonicalizeF32(F32ToBits(R));
end;

function F64PromoteF32(const A: UInt32): UInt64;
var
  R: Double;
begin
  R := BitsToF32(A); { exact widen }
  Result := CanonicalizeF64(F64ToBits(R));
end;

function F32ConvertI32S(const A: UInt32): UInt32;
var
  R: Single;
begin
  R := Int32(A);
  Result := F32ToBits(R);
end;

function F32ConvertI32U(const A: UInt32): UInt32;
var
  R: Single;
begin
  R := A;
  Result := F32ToBits(R);
end;

function F32ConvertI64S(const A: UInt64): UInt32;
var
  R: Single;
begin
  R := Int64(A);
  Result := F32ToBits(R);
end;

function F32ConvertI64U(const A: UInt64): UInt32;
var
  R: Single;
begin
  R := A;
  Result := F32ToBits(R);
end;

function F64ConvertI32S(const A: UInt32): UInt64;
var
  R: Double;
begin
  R := Int32(A);
  Result := F64ToBits(R);
end;

function F64ConvertI32U(const A: UInt32): UInt64;
var
  R: Double;
begin
  R := A;
  Result := F64ToBits(R);
end;

function F64ConvertI64S(const A: UInt64): UInt64;
var
  R: Double;
begin
  R := Int64(A);
  Result := F64ToBits(R);
end;

function F64ConvertI64U(const A: UInt64): UInt64;
var
  R: Double;
begin
  R := A;
  Result := F64ToBits(R);
end;

{ --- trapping truncations (exec-cvtop) -------------------------------

  Order matters and follows conversions.wast, NOT the wasm-mcp trap prose
  which lumps 'NaN or infinity' into one condition: NaN traps 'invalid
  conversion to integer'; every other out-of-range value, +/-inf included,
  traps 'integer overflow'. The range test is on trunc(x) so a boundary
  fraction such as -2147483648.9 -> -2147483648 does not falsely trap. }

function I32TruncF32S(const A: UInt32): UInt32;
var
  T: Double;
begin
  if F32IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF32(A));
  if (T < F_NEG_2P31) or (T >= F_2P31) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt32(Int32(Trunc(T)));
end;

function I32TruncF32U(const A: UInt32): UInt32;
var
  T: Double;
begin
  if F32IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF32(A));
  if (T <= -1.0) or (T >= F_2P32) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt32(Trunc(T));
end;

function I32TruncF64S(const A: UInt64): UInt32;
var
  T: Double;
begin
  if F64IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF64(A));
  if (T < F_NEG_2P31) or (T >= F_2P31) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt32(Int32(Trunc(T)));
end;

function I32TruncF64U(const A: UInt64): UInt32;
var
  T: Double;
begin
  if F64IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF64(A));
  if (T <= -1.0) or (T >= F_2P32) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt32(Trunc(T));
end;

function I64TruncF32S(const A: UInt32): UInt64;
var
  T: Double;
begin
  if F32IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF32(A));
  if (T < F_NEG_2P63) or (T >= F_2P63) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt64(Trunc(T));
end;

function I64TruncF32U(const A: UInt32): UInt64;
var
  T: Double;
begin
  if F32IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF32(A));
  if (T <= -1.0) or (T >= F_2P64) then
    TrapNow(wtkIntegerOverflow);
  { Values in [2^63, 2^64) exceed Int64; split off the top bit. }
  if T < F_2P63 then
    Result := UInt64(Trunc(T))
  else
    Result := UInt64(Trunc(T - F_2P63)) or (UInt64(1) shl 63);
end;

function I64TruncF64S(const A: UInt64): UInt64;
var
  T: Double;
begin
  if F64IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF64(A));
  if (T < F_NEG_2P63) or (T >= F_2P63) then
    TrapNow(wtkIntegerOverflow);
  Result := UInt64(Trunc(T));
end;

function I64TruncF64U(const A: UInt64): UInt64;
var
  T: Double;
begin
  if F64IsNan(A) then
    TrapNow(wtkInvalidConversion);
  T := DTrunc(BitsToF64(A));
  if (T <= -1.0) or (T >= F_2P64) then
    TrapNow(wtkIntegerOverflow);
  if T < F_2P63 then
    Result := UInt64(Trunc(T))
  else
    Result := UInt64(Trunc(T - F_2P63)) or (UInt64(1) shl 63);
end;

{ --- saturating truncations (never trap) ----------------------------- }

function I32TruncSatF32S(const A: UInt32): UInt32;
var
  T: Double;
begin
  if F32IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF32(A));
  if T < F_NEG_2P31 then
    Result := UInt32(Low(Int32))
  else if T >= F_2P31 then
    Result := UInt32(High(Int32))
  else
    Result := UInt32(Int32(Trunc(T)));
end;

function I32TruncSatF32U(const A: UInt32): UInt32;
var
  T: Double;
begin
  if F32IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF32(A));
  if T < 0.0 then
    Result := 0
  else if T >= F_2P32 then
    Result := High(UInt32)
  else
    Result := UInt32(Trunc(T));
end;

function I32TruncSatF64S(const A: UInt64): UInt32;
var
  T: Double;
begin
  if F64IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF64(A));
  if T < F_NEG_2P31 then
    Result := UInt32(Low(Int32))
  else if T >= F_2P31 then
    Result := UInt32(High(Int32))
  else
    Result := UInt32(Int32(Trunc(T)));
end;

function I32TruncSatF64U(const A: UInt64): UInt32;
var
  T: Double;
begin
  if F64IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF64(A));
  if T < 0.0 then
    Result := 0
  else if T >= F_2P32 then
    Result := High(UInt32)
  else
    Result := UInt32(Trunc(T));
end;

function I64TruncSatF32S(const A: UInt32): UInt64;
var
  T: Double;
begin
  if F32IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF32(A));
  if T < F_NEG_2P63 then
    Result := UInt64(Low(Int64))
  else if T >= F_2P63 then
    Result := UInt64(High(Int64))
  else
    Result := UInt64(Trunc(T));
end;

function I64TruncSatF32U(const A: UInt32): UInt64;
var
  T: Double;
begin
  if F32IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF32(A));
  if T < 0.0 then
    Result := 0
  else if T >= F_2P64 then
    Result := High(UInt64)
  else if T < F_2P63 then
    Result := UInt64(Trunc(T))
  else
    Result := UInt64(Trunc(T - F_2P63)) or (UInt64(1) shl 63);
end;

function I64TruncSatF64S(const A: UInt64): UInt64;
var
  T: Double;
begin
  if F64IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF64(A));
  if T < F_NEG_2P63 then
    Result := UInt64(Low(Int64))
  else if T >= F_2P63 then
    Result := UInt64(High(Int64))
  else
    Result := UInt64(Trunc(T));
end;

function I64TruncSatF64U(const A: UInt64): UInt64;
var
  T: Double;
begin
  if F64IsNan(A) then
    Exit(0);
  T := DTrunc(BitsToF64(A));
  if T < 0.0 then
    Result := 0
  else if T >= F_2P64 then
    Result := High(UInt64)
  else if T < F_2P63 then
    Result := UInt64(Trunc(T))
  else
    Result := UInt64(Trunc(T - F_2P63)) or (UInt64(1) shl 63);
end;

{$IFDEF CPUAARCH64}
{ Clear FPCR so every floating-point trap-enable bit is off (and rounding is
  round-to-nearest, flush-to-zero off) — the state wasm requires. FPC's
  darwin/aarch64 startup leaves the invalid/overflow trap-enables set, so
  without this 0.0/0.0, inf-inf, sqrt(-1), an overflowing demote, and even an
  ordered compare against a NaN raise instead of yielding a NaN/inf. }
procedure MaskFpuExceptions; assembler; nostackframe;
asm
  msr fpcr, xzr
end;
{$ELSE}
procedure MaskFpuExceptions;
begin
{$IF DEFINED(CPUX86_64)}
  SetSSECSR($1F80); { IM DM ZM OM UM PM set, round-nearest, FTZ off }
{$ELSEIF DEFINED(CPUI386)}
  { $027F: all six x87 exceptions masked, round-nearest, and PC = 10b (bits
    8-9) = DOUBLE (53-bit) precision. $037F's PC = 11b keeps 80-bit extended
    precision, which double-rounds f32/f64 and breaks observational identity
    (ADR-0010). x86_64 uses SSE and is unaffected by the x87 PC field. }
  Set8087CW($027F);
{$ENDIF}
end;
{$ENDIF}

{$POP}

initialization
  { wasm float ops never trap: f32.div by zero yields +/-inf or a NaN
    (instruction_get f32.div can_trap:false), and NaN propagation is a value
    rule (aux-nans), never a fault. The FPU must therefore mask every
    arithmetic exception. This is per-thread state; the interpreter re-applies
    it (MaskFpuExceptions) on each thread's first invoke. }
  MaskFpuExceptions;

end.
