{ Wasm.Wat.Numbers — the wat text-format numeric literal parser: integer and
  floating-point literal TEXT to their exact bit patterns.

  This is the highest single fidelity risk in the text-format assembler and is
  deliberately a leaf unit (design .agent/design/wat-assembler.md §2(d), §6):
  it depends only on Wasm.Core, so every boundary case is testable in
  isolation with a literal spelled next to its expected bits. It emits BITS,
  not sLEB128 — the emitter (Wasm.Wat.Emit) encodes them — and it enforces the
  text-format's own range rules, raising EWasmTextError with upstream's
  canonical prefixes.

  Two spec areas drive the whole unit, both cited at their sites and checked
  against wasm-mcp 0.2.16, spec/main d7b37e4170d8315f2f1283aed4e8076591a9a333
  (ADR-0004):

  - Integers (text-sign / text-int, text/values.html#text-sign). An iN literal
    fits if its magnitude lies in the UNION [-2^(N-1), 2^N-1] — the testsuite
    writes both -1 and 4294967295 for i32. The magnitude is accumulated as an
    unbounded unsigned value and the sign applied by two's-complement negation
    on the bits, so -0x8000000000000000, 0x8000000000000000 and
    -9223372036854775808 all produce 0x8000000000000000 without an Int64
    ever overflowing (design §2(d.1)).

  - Floats (text-frac / text-hexfloat, text/values.html#text-frac). The RTL is
    unusable (no hex floats, no nan payloads, no `inf`, locale-dependent
    separator, unspecified rounding), so both decimal and hexadecimal are
    parsed to bits here. Every literal reduces to an exact rational Num/Den of
    arbitrary-precision integers, which is then rounded to the target IEEE754
    type with round-half-to-even and a correct sticky bit. The range rule is
    "round FIRST, then check": the value is out of range only if the
    correctly-rounded result is infinite (text-frac). const.wast:316 vs :327
    (0x1.fffffefffffffffffp127 rounds down to max-finite and is accepted;
    0x1.ffffffp127 rounds up past it and is `constant out of range`) is the
    case that distinguishes a correct rounder from an almost-correct one.

  NaN literals: bare `nan` is the positive canonical NaN — payload 2^(m-1),
  the shared Wasm.Core.WASM_F32_CANONICAL_NAN / WASM_F64_CANONICAL_NAN
  (0x7FC00000 / 0x7FF8000000000000). `nan:0x<payload>` supplies an explicit
  payload that must be nonzero and fit the mantissa width. `nan:canonical` and
  `nan:arithmetic` are the RUNNER's result-class spellings (a different track)
  and are NOT valid in a const literal position — they raise `unexpected token`
  (design §2(d.2), §7; i64.wast:488).

  Strings are NOT handled here: string->bytes decoding belongs to the lexer
  (design §2(d.3)); this unit is purely numeric. }
unit Wasm.Wat.Numbers;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

{ EWasmTextError now lives in Wasm.Core (design §1): promoted from the
  per-unit local copies so every Wasm.Wat.* unit and the runner share one
  type. It is reachable here through the Wasm.Core in this unit's uses. }

const
  { Canonical upstream prefixes. The harness matches an assertion's expected
    string as a PREFIX of ours, so `unknown operator` carries the offending
    token appended after a space (design §4, obsolete-keywords.wast).
    MSG_CONSTANT_OUT_OF_RANGE lives here because this is the unit that raises
    it (design §4, "Constants live as MSG_* in the unit that raises them");
    MSG_UNKNOWN_OPERATOR and MSG_UNEXPECTED_TOKEN are raised here AND by the
    assembler, so they live in Wasm.Core (reached through this unit's uses)
    to keep one corpus-matched spelling. }
  MSG_CONSTANT_OUT_OF_RANGE = 'constant out of range';

  { The width-PREFIXED spelling belongs to lane INDICES, not lane literals.
    ParseI8 raises it (the assembler routes shuffle / extract_lane /
    replace_lane / load-store_lane indices through ParseI8), while
    ParseIntLiteral(tok, 8) — the path a `v128.const i8x16` lane literal
    takes — keeps the bare `constant out of range`. That reads inconsistent,
    but it is exactly the corpus split: `i8 constant out of range` occurs
    only in simd_lane.wast (lane-index positions) and `constant out of range`
    only in simd_const.wast (v128.const lane literals). The harness matches by
    prefix, and `i8 constant out of range` is NOT prefixed by `constant out of
    range`, so the two cannot be merged (design §5.4). MSG_I16 is the
    symmetric spelling; UNCONFIRMED — no corpus case reaches it. }
  MSG_I8_CONSTANT_OUT_OF_RANGE  = 'i8 constant out of range';
  MSG_I16_CONSTANT_OUT_OF_RANGE = 'i16 constant out of range';

{ Parse an integer literal token to its ABitWidth-bit two's-complement pattern,
  returned in the low bits of the result. The value must fit ABitWidth as
  EITHER a signed or an unsigned integer (the union [-2^(N-1), 2^N-1]); a value
  outside it raises `constant out of range`. A token that is not a well-formed
  integer (empty, `0x`, `1x`, `0xg`, a misplaced underscore) raises
  `unknown operator`. ABitWidth is one of 8/16/32/64. }
function ParseIntLiteral(const AToken: string; const ABitWidth: Integer): UInt64;

{ Width-typed integer wrappers. ParseI8 / ParseI16 exist for SIMD lane
  INDICES and raise the width-prefixed `i8/i16 constant out of range` on
  overflow (design §5.4); ParseI32 / ParseI64 and ParseIntLiteral raise the
  bare `constant out of range`. Choose ParseIntLiteral(tok, 8/16/…) — not
  ParseI8 / ParseI16 — for a v128.const lane LITERAL, which wants the bare
  spelling. }
function ParseI8(const AToken: string): Byte;
function ParseI16(const AToken: string): Word;
function ParseI32(const AToken: string): UInt32;
function ParseI64(const AToken: string): UInt64;

{ Parse a floating-point literal token to its IEEE754 bit pattern. Handles
  decimal and hexadecimal floats, `inf`, bare `nan`, and `nan:0x<payload>`,
  each with an optional leading sign. Overflow-after-rounding and an
  out-of-range NaN payload raise `constant out of range`; `nan:canonical` /
  `nan:arithmetic` raise `unexpected token`; a malformed float token raises
  `unknown operator`. }
function ParseF32(const AToken: string): UInt32;
function ParseF64(const AToken: string): UInt64;

implementation

{ Every arithmetic path below relies on intentional modulo-2^N wraparound (the
  two's-complement negation of a magnitude, and the limb accumulations of the
  bignum). Shared.inc turns overflow/range checks ON outside PRODUCTION, so
  push them OFF for the whole implementation exactly as Wasm.Interp.Numeric
  does. }
{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

type
  { A non-negative arbitrary-precision integer: little-endian base-2^32 limbs,
    always trimmed so that a zero value has length 0 and the top limb is never
    zero. Deliberately minimal — this is a cold path (design §2(d.2), "the
    driver here is correctness, not speed"), so clarity beats a limb-optimised
    Knuth division. }
  TBig = array of UInt32;

{ --- diagnostics ----------------------------------------------------- }

procedure RaiseRange;
begin
  raise EWasmTextError.Create(MSG_CONSTANT_OUT_OF_RANGE);
end;

procedure RaiseUnknown(const AToken: string);
begin
  { Append the offending token after a space; the bare-prefix assertions still
    match because the prefix is intact (design §4). }
  raise EWasmTextError.Create(MSG_UNKNOWN_OPERATOR + ' ' + AToken);
end;

procedure RaiseUnexpected;
begin
  raise EWasmTextError.Create(MSG_UNEXPECTED_TOKEN);
end;

{ --- bignum ---------------------------------------------------------- }

procedure BigTrim(var A: TBig);
var
  N: Integer;
begin
  N := Length(A);
  while (N > 0) and (A[N - 1] = 0) do
    Dec(N);
  if N <> Length(A) then
    SetLength(A, N);
end;

function BigIsZero(const A: TBig): Boolean;
begin
  Result := Length(A) = 0;
end;

function BigFromU64(const V: UInt64): TBig;
begin
  if V = 0 then
    Result := nil
  else if V <= UInt64($FFFFFFFF) then
  begin
    SetLength(Result, 1);
    Result[0] := UInt32(V);
  end
  else
  begin
    SetLength(Result, 2);
    Result[0] := UInt32(V and UInt64($FFFFFFFF));
    Result[1] := UInt32(V shr 32);
  end;
end;

{ Low 64 bits of A. The callers only invoke this once A is known to fit 64 bits
  (after a range check), so limbs above the second are not consulted. }
function BigToU64(const A: TBig): UInt64;
begin
  Result := 0;
  if Length(A) >= 1 then
    Result := A[0];
  if Length(A) >= 2 then
    Result := Result or (UInt64(A[1]) shl 32);
end;

{ Both operands assumed trimmed: compare by length, then by limb from the top. }
function BigCompare(const A, B: TBig): Integer;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
  begin
    if Length(A) < Length(B) then
      Exit(-1)
    else
      Exit(1);
  end;
  for I := High(A) downto 0 do
    if A[I] <> B[I] then
    begin
      if A[I] < B[I] then
        Exit(-1)
      else
        Exit(1);
    end;
  Result := 0;
end;

function BigBitLength(const A: TBig): Integer;
var
  Top: UInt32;
  Bits: Integer;
begin
  if Length(A) = 0 then
    Exit(0);
  Top := A[High(A)];
  Bits := 0;
  while Top <> 0 do
  begin
    Inc(Bits);
    Top := Top shr 1;
  end;
  Result := High(A) * 32 + Bits;
end;

function BigShlBits(const A: TBig; const N: Integer): TBig;
var
  LimbShift, BitShift, I: Integer;
  Carry, V: UInt64;
begin
  if Length(A) = 0 then
    Exit(nil);
  if N = 0 then
    Exit(Copy(A));
  LimbShift := N div 32;
  BitShift := N mod 32;
  SetLength(Result, Length(A) + LimbShift + 1);
  for I := 0 to LimbShift - 1 do
    Result[I] := 0;
  Carry := 0;
  for I := 0 to High(A) do
  begin
    V := (UInt64(A[I]) shl BitShift) or Carry;
    Result[I + LimbShift] := UInt32(V and UInt64($FFFFFFFF));
    Carry := V shr 32;
  end;
  Result[Length(A) + LimbShift] := UInt32(Carry);
  BigTrim(Result);
end;

{ A - B, assuming A >= B. }
function BigSub(const A, B: TBig): TBig;
var
  I: Integer;
  Av, Bv, D, Borrow: Int64;
begin
  SetLength(Result, Length(A));
  Borrow := 0;
  for I := 0 to High(A) do
  begin
    Av := A[I];
    if I <= High(B) then
      Bv := B[I]
    else
      Bv := 0;
    D := Av - Bv - Borrow;
    if D < 0 then
    begin
      D := D + Int64($100000000);
      Borrow := 1;
    end
    else
      Borrow := 0;
    Result[I] := UInt32(D);
  end;
  BigTrim(Result);
end;

function BigAdd(const A, B: TBig): TBig;
var
  I, N: Integer;
  Av, Bv, S, Carry: UInt64;
begin
  N := Length(A);
  if Length(B) > N then
    N := Length(B);
  SetLength(Result, N + 1);
  Carry := 0;
  for I := 0 to N - 1 do
  begin
    if I <= High(A) then
      Av := A[I]
    else
      Av := 0;
    if I <= High(B) then
      Bv := B[I]
    else
      Bv := 0;
    S := Av + Bv + Carry;
    Result[I] := UInt32(S and UInt64($FFFFFFFF));
    Carry := S shr 32;
  end;
  Result[N] := UInt32(Carry);
  BigTrim(Result);
end;

function BigMulSmall(const A: TBig; const M: UInt32): TBig;
var
  I: Integer;
  Carry, V: UInt64;
begin
  if (Length(A) = 0) or (M = 0) then
    Exit(nil);
  SetLength(Result, Length(A) + 1);
  Carry := 0;
  for I := 0 to High(A) do
  begin
    V := UInt64(A[I]) * M + Carry;
    Result[I] := UInt32(V and UInt64($FFFFFFFF));
    Carry := V shr 32;
  end;
  Result[Length(A)] := UInt32(Carry);
  BigTrim(Result);
end;

function BigAddSmall(const A: TBig; const M: UInt32): TBig;
var
  I: Integer;
  Carry, V: UInt64;
begin
  Result := Copy(A);
  Carry := M;
  I := 0;
  while Carry <> 0 do
  begin
    if I > High(Result) then
      SetLength(Result, I + 1);
    V := UInt64(Result[I]) + Carry;
    Result[I] := UInt32(V and UInt64($FFFFFFFF));
    Carry := V shr 32;
    Inc(I);
  end;
  BigTrim(Result);
end;

function BigPow10(const K: Integer): TBig;
var
  I: Integer;
begin
  Result := BigFromU64(1);
  for I := 1 to K do
    Result := BigMulSmall(Result, 10);
end;

{ --- digit scanning -------------------------------------------------- }

function DigitValue(const C: Char; const ABase: Integer; out V: Integer): Boolean;
begin
  V := 0;
  Result := False;
  if (C >= '0') and (C <= '9') then
  begin
    V := Ord(C) - Ord('0');
    Result := V < ABase;
  end
  else if ABase = 16 then
  begin
    if (C >= 'a') and (C <= 'f') then
    begin
      V := Ord(C) - Ord('a') + 10;
      Result := True;
    end
    else if (C >= 'A') and (C <= 'F') then
    begin
      V := Ord(C) - Ord('A') + 10;
      Result := True;
    end;
  end;
end;

function IsDigitChar(const C: Char; const ABase: Integer): Boolean;
var
  Dummy: Integer;
begin
  Result := DigitValue(C, ABase, Dummy);
end;

{ Consume a run of Base digits with `_` separators into Acc, advancing Idx past
  it and returning the digit Count. Enforces the text-format underscore rule
  (text-num / text-hexnum): at least one digit, and a `_` only ever BETWEEN two
  digits — a leading, trailing, or doubled underscore is not a number token, so
  it raises `unknown operator` (int_literals.wast:99-140). Stops at the first
  character that is neither a digit nor a valid separator. }
procedure ScanDigits(const S: string; var AIdx: Integer; const ABase: Integer;
  out AAcc: TBig; out ACount: Integer; const AToken: string);
var
  C: Char;
  V: Integer;
  Started: Boolean;
begin
  AAcc := nil;
  ACount := 0;
  Started := False;
  while AIdx <= Length(S) do
  begin
    C := S[AIdx];
    if DigitValue(C, ABase, V) then
    begin
      if ABase = 16 then
        AAcc := BigAddSmall(BigShlBits(AAcc, 4), UInt32(V))
      else
        AAcc := BigAddSmall(BigMulSmall(AAcc, 10), UInt32(V));
      Inc(ACount);
      Inc(AIdx);
      Started := True;
    end
    else if C = '_' then
    begin
      if not Started then
        RaiseUnknown(AToken);
      if (AIdx = Length(S)) or (not IsDigitChar(S[AIdx + 1], ABase)) then
        RaiseUnknown(AToken);
      Inc(AIdx);
    end
    else
      Break;
  end;
  if not Started then
    RaiseUnknown(AToken);
end;

{ A signed decimal exponent (the `p`/`e` tail). Saturates the magnitude far
  above any representable exponent so an absurd literal cannot build an
  astronomically large power; the callers short-circuit true over/underflow
  before that ever matters. }
function ScanExpInt(const S: string; var AIdx: Integer;
  const AToken: string): Int64;
var
  C: Char;
  V: Integer;
  Started, Neg: Boolean;
begin
  Neg := False;
  if AIdx <= Length(S) then
  begin
    if S[AIdx] = '+' then
      Inc(AIdx)
    else if S[AIdx] = '-' then
    begin
      Neg := True;
      Inc(AIdx);
    end;
  end;
  Result := 0;
  Started := False;
  while AIdx <= Length(S) do
  begin
    C := S[AIdx];
    if DigitValue(C, 10, V) then
    begin
      if Result < Int64(100000000) then
        Result := Result * 10 + V;
      Inc(AIdx);
      Started := True;
    end
    else if C = '_' then
    begin
      if not Started then
        RaiseUnknown(AToken);
      if (AIdx = Length(S)) or (not IsDigitChar(S[AIdx + 1], 10)) then
        RaiseUnknown(AToken);
      Inc(AIdx);
    end
    else
      Break;
  end;
  if not Started then
    RaiseUnknown(AToken);
  if Neg then
    Result := -Result;
end;

{ --- float assembly -------------------------------------------------- }

function SignedZero(const ANeg, AIsF32: Boolean): UInt64;
begin
  if not ANeg then
    Result := 0
  else if AIsF32 then
    Result := UInt64($80000000)
  else
    Result := UInt64($8000000000000000);
end;

function BitLenU64(V: UInt64): Integer;
begin
  Result := 0;
  while V <> 0 do
  begin
    Inc(Result);
    V := V shr 1;
  end;
end;

{ Encode a rounded significand M (0 <= M <= 2^p) at ULP-exponent AUlpExp into
  the IEEE754 bit pattern. M and AUlpExp together already name the exact value
  M * 2^AUlpExp, so the normal/subnormal split and the round-up-to-the-next-
  binade case (M = 2^p) all fall out of M's own bit length; overflow past the
  largest finite value raises `constant out of range` (text-frac: round first,
  then check). }
function EncodeFloatBits(const M: UInt64; const AUlpExp: Integer;
  const ANeg, AIsF32: Boolean): UInt64;
var
  Emin, Emax, Bias, MantBits, Msb, Ev, Biased: Integer;
  Frac: UInt64;
begin
  if AIsF32 then
  begin
    Emin := -126;
    Emax := 127;
    Bias := 127;
    MantBits := 23;
  end
  else
  begin
    Emin := -1022;
    Emax := 1023;
    Bias := 1023;
    MantBits := 52;
  end;

  if M = 0 then
    Exit(SignedZero(ANeg, AIsF32));

  Msb := BitLenU64(M) - 1;
  Ev := AUlpExp + Msb;
  if Ev > Emax then
    RaiseRange;

  if Ev < Emin then
  begin
    { Subnormal: exponent field 0, M is the whole mantissa (M < 2^MantBits by
      construction, because AUlpExp was clamped to the subnormal ULP). }
    Biased := 0;
    Frac := M;
  end
  else
  begin
    { Normal. Dropping the implicit leading bit as M - 2^Msb also yields
      mantissa 0 when M rounded up to exactly 2^p (Msb = p), which is the
      carry into the next binade. }
    Biased := Ev + Bias;
    Frac := M - (UInt64(1) shl Msb);
  end;

  if AIsF32 then
    Result := (UInt64(Ord(ANeg)) shl 31) or (UInt64(Biased) shl 23)
      or (Frac and UInt64($7FFFFF))
  else
    Result := (UInt64(Ord(ANeg)) shl 63) or (UInt64(Biased) shl 52)
      or (Frac and UInt64($FFFFFFFFFFFFF));
end;

{ Round the exact rational ANum/ADen (ANum >= 0, ADen > 0) to the nearest
  value of the target IEEE754 type, ties to even, and return its bits.

  The value's binary exponent E = floor(log2(ANum/ADen)) fixes the ULP
  exponent (E-(p-1) for a normal, clamped up to the subnormal ULP), and a
  single arbitrary-precision division at that ULP produces the significand
  plus an exact remainder for the half-to-even decision. Doing the division
  once, directly at the final ULP, is what avoids the double-rounding that a
  normalise-then-shift-for-subnormal scheme would introduce. }
function RoundRational(const ANum, ADen: TBig;
  const ANeg, AIsF32: Boolean): UInt64;
var
  P, Emax, MinUlp: Integer;
  E, UlpExp, K, I, C: Integer;
  SNum, SDen, Rem, T, TwoRem: TBig;
  M: UInt64;
begin
  if AIsF32 then
  begin
    P := 24;
    Emax := 127;
    MinUlp := -149;
  end
  else
  begin
    P := 53;
    Emax := 1023;
    MinUlp := -1074;
  end;

  if BigIsZero(ANum) then
    Exit(SignedZero(ANeg, AIsF32));

  { E = floor(log2(ANum/ADen)), exactly. The bit-length difference is within 1
    of the answer; one comparison (avoiding a negative shift) picks between the
    two candidates. }
  E := BigBitLength(ANum) - BigBitLength(ADen);
  if E >= 0 then
    C := BigCompare(BigShlBits(ADen, E), ANum)
  else
    C := BigCompare(ADen, BigShlBits(ANum, -E));
  if C > 0 then
    Dec(E);

  { E > Emax means the value already exceeds the largest binade of a finite
    number, so it overflows regardless of rounding. E = Emax still has to run
    the rounder (0x1.ffffffp127 rounds up to infinity from there). }
  if E > Emax then
    RaiseRange;

  UlpExp := E - (P - 1);
  if UlpExp < MinUlp then
    UlpExp := MinUlp;

  if UlpExp <= 0 then
  begin
    SNum := BigShlBits(ANum, -UlpExp);
    SDen := ADen;
  end
  else
  begin
    SNum := ANum;
    SDen := BigShlBits(ADen, UlpExp);
  end;

  { M = floor(SNum / SDen), Rem = SNum mod SDen. M is bounded by 2^(p+1), so it
    fits a UInt64 and the quotient's top bit is at index K = bitlen(SNum) -
    bitlen(SDen). }
  K := BigBitLength(SNum) - BigBitLength(SDen);
  if K > 62 then
    K := 62;
  M := 0;
  Rem := Copy(SNum);
  if K >= 0 then
    for I := K downto 0 do
    begin
      T := BigShlBits(SDen, I);
      if BigCompare(T, Rem) <= 0 then
      begin
        Rem := BigSub(Rem, T);
        M := M or (UInt64(1) shl I);
      end;
    end;

  { Round half-to-even: compare 2*Rem against SDen. }
  TwoRem := BigShlBits(Rem, 1);
  C := BigCompare(TwoRem, SDen);
  if C > 0 then
    Inc(M)
  else if C = 0 then
  begin
    if (M and 1) = 1 then
      Inc(M);
  end;

  Result := EncodeFloatBits(M, UlpExp, ANeg, AIsF32);
end;

{ ABody starts with '0x'. hexfloat ::= '0x' hexnum ('.' hexfrac?)? (('p'|'P')
  sign? num)? — value = mantissa * 2^(binExp - 4*fracDigits) (text-hexfloat). }
function ParseHexFloatBody(const ABody: string; const ANeg, AIsF32: Boolean;
  const AToken: string): UInt64;
var
  Idx, IntCount, FracCount: Integer;
  Emax, MinUlp: Integer;
  IntAcc, FracAcc, Num, Den: TBig;
  PExp, Exp2, ApproxLog2: Int64;
begin
  if AIsF32 then
  begin
    Emax := 127;
    MinUlp := -149;
  end
  else
  begin
    Emax := 1023;
    MinUlp := -1074;
  end;

  Idx := 3; { past '0x' }
  ScanDigits(ABody, Idx, 16, IntAcc, IntCount, AToken);

  FracCount := 0;
  if (Idx <= Length(ABody)) and (ABody[Idx] = '.') then
  begin
    Inc(Idx);
    { The fraction is optional and may be empty (a trailing dot: 0x1.p10). }
    if (Idx <= Length(ABody)) and IsDigitChar(ABody[Idx], 16) then
    begin
      ScanDigits(ABody, Idx, 16, FracAcc, FracCount, AToken);
      IntAcc := BigAdd(BigShlBits(IntAcc, 4 * FracCount), FracAcc);
    end;
  end;

  PExp := 0;
  if (Idx <= Length(ABody)) and ((ABody[Idx] = 'p') or (ABody[Idx] = 'P')) then
  begin
    Inc(Idx);
    PExp := ScanExpInt(ABody, Idx, AToken);
  end;

  if Idx <= Length(ABody) then
    RaiseUnknown(AToken);

  Exp2 := PExp - Int64(4) * FracCount;

  { Short-circuit exponents so far outside the representable range that a
    correctly-rounded result is unambiguous, keeping the shifts below bounded.
    Margins of 2 keep every representable value on the exact path. }
  if not BigIsZero(IntAcc) then
  begin
    ApproxLog2 := Int64(BigBitLength(IntAcc)) + Exp2;
    if ApproxLog2 > Emax + 2 then
      RaiseRange;
    if ApproxLog2 < MinUlp - 2 then
      Exit(SignedZero(ANeg, AIsF32));
  end;

  if Exp2 >= 0 then
  begin
    Num := BigShlBits(IntAcc, Integer(Exp2));
    Den := BigFromU64(1);
  end
  else
  begin
    Num := IntAcc;
    Den := BigShlBits(BigFromU64(1), Integer(-Exp2));
  end;

  Result := RoundRational(Num, Den, ANeg, AIsF32);
end;

{ float ::= num ('.' frac?)? (('e'|'E') sign? num)? — value = digits *
  10^(decExp - fracDigits) (text-float). }
function ParseDecFloatBody(const ABody: string; const ANeg, AIsF32: Boolean;
  const AToken: string): UInt64;
var
  Idx, IntCount, FracCount, I: Integer;
  IntAcc, FracAcc, Num, Den: TBig;
  EExp, DecExp: Int64;
  ApproxLog10: Double;
begin
  Idx := 1;
  ScanDigits(ABody, Idx, 10, IntAcc, IntCount, AToken);

  FracCount := 0;
  if (Idx <= Length(ABody)) and (ABody[Idx] = '.') then
  begin
    Inc(Idx);
    if (Idx <= Length(ABody)) and IsDigitChar(ABody[Idx], 10) then
    begin
      ScanDigits(ABody, Idx, 10, FracAcc, FracCount, AToken);
      for I := 1 to FracCount do
        IntAcc := BigMulSmall(IntAcc, 10);
      IntAcc := BigAdd(IntAcc, FracAcc);
    end;
  end;

  EExp := 0;
  if (Idx <= Length(ABody)) and ((ABody[Idx] = 'e') or (ABody[Idx] = 'E')) then
  begin
    Inc(Idx);
    EExp := ScanExpInt(ABody, Idx, AToken);
  end;

  if Idx <= Length(ABody) then
    RaiseUnknown(AToken);

  DecExp := EExp - FracCount;

  { log10 estimate from the significand's bit length (log10 2 ~ 0.30103); a
    generous +-400 window keeps every representable magnitude (f64 tops out
    near 1e308, bottoms near 1e-324) on the exact bignum path. }
  if not BigIsZero(IntAcc) then
  begin
    ApproxLog10 := BigBitLength(IntAcc) * 0.30103 + DecExp;
    if ApproxLog10 > 400 then
      RaiseRange;
    if ApproxLog10 < -400 then
      Exit(SignedZero(ANeg, AIsF32));
  end
  else
    { A zero mantissa is signed zero regardless of the decimal exponent. The
      log10 short-circuit above only runs for nonzero significands, so exit
      here before the DecExp scaling loop — otherwise `0e1000000000` would
      spin ~1e9 no-op BigMulSmall(0, 10) iterations. }
    Exit(SignedZero(ANeg, AIsF32));

  if DecExp >= 0 then
  begin
    Num := Copy(IntAcc);
    for I := 1 to Integer(DecExp) do
      Num := BigMulSmall(Num, 10);
    Den := BigFromU64(1);
  end
  else
  begin
    Num := IntAcc;
    Den := BigPow10(Integer(-DecExp));
  end;

  Result := RoundRational(Num, Den, ANeg, AIsF32);
end;

function ParseFloat(const AToken: string; const AIsF32: Boolean): UInt64;
var
  I, MantBits, PIdx, PCount: Integer;
  Neg: Boolean;
  Rest, Payload: string;
  Pv: TBig;
  PvU, MaxPayload: UInt64;
begin
  if AIsF32 then
    MantBits := 23
  else
    MantBits := 52;

  I := 1;
  Neg := False;
  if Length(AToken) >= 1 then
  begin
    if AToken[1] = '+' then
      I := 2
    else if AToken[1] = '-' then
    begin
      Neg := True;
      I := 2;
    end;
  end;
  Rest := Copy(AToken, I, MaxInt);

  if Rest = 'inf' then
  begin
    if AIsF32 then
      Result := (UInt64(Ord(Neg)) shl 31) or UInt64($7F800000)
    else
      Result := (UInt64(Ord(Neg)) shl 63) or UInt64($7FF0000000000000);
    Exit;
  end;

  if Rest = 'nan' then
  begin
    { Bare nan is the positive canonical NaN — payload 2^(m-1). }
    if AIsF32 then
      Result := (UInt64(Ord(Neg)) shl 31) or UInt64(WASM_F32_CANONICAL_NAN)
    else
      Result := (UInt64(Ord(Neg)) shl 63) or WASM_F64_CANONICAL_NAN;
    Exit;
  end;

  if (Length(Rest) >= 4) and (Copy(Rest, 1, 4) = 'nan:') then
  begin
    Payload := Copy(Rest, 5, MaxInt);
    { Result-class spellings are not literals — `unexpected token` in a const
      position (design §2(d.2); i64.wast:488). }
    if (Payload = 'canonical') or (Payload = 'arithmetic') then
      RaiseUnexpected;
    { The payload must be hexadecimal; `nan:1` is not a float token at all
      (const.wast:410). }
    if (Length(Payload) < 3) or (Payload[1] <> '0') or (Payload[2] <> 'x') then
      RaiseUnknown(AToken);
    PIdx := 3;
    ScanDigits(Payload, PIdx, 16, Pv, PCount, AToken);
    if PIdx <= Length(Payload) then
      RaiseUnknown(AToken);
    { Payload must be nonzero and fit the mantissa (const.wast:419-432). }
    if BigIsZero(Pv) then
      RaiseRange;
    MaxPayload := (UInt64(1) shl MantBits) - 1;
    if BigCompare(Pv, BigFromU64(MaxPayload)) > 0 then
      RaiseRange;
    PvU := BigToU64(Pv);
    if AIsF32 then
      Result := (UInt64(Ord(Neg)) shl 31) or UInt64($7F800000) or PvU
    else
      Result := (UInt64(Ord(Neg)) shl 63) or UInt64($7FF0000000000000) or PvU;
    Exit;
  end;

  if (Length(Rest) >= 2) and (Rest[1] = '0') and (Rest[2] = 'x') then
    Result := ParseHexFloatBody(Rest, Neg, AIsF32, AToken)
  else
    Result := ParseDecFloatBody(Rest, Neg, AIsF32, AToken);
end;

{ --- integers -------------------------------------------------------- }

{ The shared integer-literal core. ARangeMsg lets a width-typed wrapper pick
  the diagnostic spelling: the bare `constant out of range` for a literal, or
  the width-prefixed `i8/i16 constant out of range` for a lane index. Every
  other diagnostic (`unknown operator`) is width-agnostic and unchanged. }
function IntLiteralBits(const AToken: string; const ABitWidth: Integer;
  const ARangeMsg: string): UInt64;
var
  I, Count: Integer;
  Neg: Boolean;
  Mag, Limit: TBig;
  MagU, Mask: UInt64;
begin
  I := 1;
  Neg := False;
  if Length(AToken) >= 1 then
  begin
    if AToken[1] = '+' then
      I := 2
    else if AToken[1] = '-' then
    begin
      Neg := True;
      I := 2;
    end;
  end;

  { A `0x` prefix selects hexadecimal; otherwise decimal (010 is ten, not
    octal — int_literals.wast:10). ScanDigits requires at least one digit, so
    `0x` alone and an empty token both raise `unknown operator`. }
  if (I + 1 <= Length(AToken)) and (AToken[I] = '0') and (AToken[I + 1] = 'x') then
  begin
    Inc(I, 2);
    ScanDigits(AToken, I, 16, Mag, Count, AToken);
  end
  else
    ScanDigits(AToken, I, 10, Mag, Count, AToken);

  { Trailing junk (`1x`, `0xg`) means the whole thing is not an integer token. }
  if I <= Length(AToken) then
    RaiseUnknown(AToken);

  if Neg then
  begin
    { Negative: magnitude must fit signed N, i.e. <= 2^(N-1). Bits are the
      two's complement, computed on the unsigned value so -2^63 never forms an
      overflowing Int64. }
    Limit := BigShlBits(BigFromU64(1), ABitWidth - 1);
    if BigCompare(Mag, Limit) > 0 then
      raise EWasmTextError.Create(ARangeMsg);
    MagU := BigToU64(Mag);
    if ABitWidth >= 64 then
      Result := UInt64(0) - MagU
    else
    begin
      Mask := (UInt64(1) shl ABitWidth) - 1;
      Result := ((UInt64(1) shl ABitWidth) - MagU) and Mask;
    end;
  end
  else
  begin
    { Positive: magnitude must fit unsigned N, i.e. <= 2^N - 1. }
    Limit := BigSub(BigShlBits(BigFromU64(1), ABitWidth), BigFromU64(1));
    if BigCompare(Mag, Limit) > 0 then
      raise EWasmTextError.Create(ARangeMsg);
    MagU := BigToU64(Mag);
    if ABitWidth >= 64 then
      Result := MagU
    else
    begin
      Mask := (UInt64(1) shl ABitWidth) - 1;
      Result := MagU and Mask;
    end;
  end;
end;

function ParseIntLiteral(const AToken: string;
  const ABitWidth: Integer): UInt64;
begin
  { Lane LITERAL path (v128.const): the bare `constant out of range`. }
  Result := IntLiteralBits(AToken, ABitWidth, MSG_CONSTANT_OUT_OF_RANGE);
end;

function ParseI8(const AToken: string): Byte;
begin
  { Lane INDEX path (shuffle / extract_lane / …): the width-prefixed
    `i8 constant out of range` (design §5.4; simd_lane.wast). }
  Result := Byte(IntLiteralBits(AToken, 8, MSG_I8_CONSTANT_OUT_OF_RANGE));
end;

function ParseI16(const AToken: string): Word;
begin
  Result := Word(IntLiteralBits(AToken, 16, MSG_I16_CONSTANT_OUT_OF_RANGE));
end;

function ParseI32(const AToken: string): UInt32;
begin
  Result := UInt32(ParseIntLiteral(AToken, 32));
end;

function ParseI64(const AToken: string): UInt64;
begin
  Result := ParseIntLiteral(AToken, 64);
end;

function ParseF32(const AToken: string): UInt32;
begin
  Result := UInt32(ParseFloat(AToken, True));
end;

function ParseF64(const AToken: string): UInt64;
begin
  Result := ParseFloat(AToken, False);
end;

{$POP}

end.
