{ Wasm.Wast.Values — the argument / expected-result value parser and the
  result comparator for the `.wast` conformance runner (Track E, Wave 5;
  interp-spec §6.2/§6.3).

  An assert_return argument or expected result is an s-expression:
  `(i32.const 5)`, `(i64.const -1)`, `(f32.const nan:canonical)`,
  `(f64.const 0x1.5p3)`, `(ref.null func)`, `(ref.extern 1)`,
  `(ref.func)`, `(v128.const ...)`. Wasm.Wast already lexes these into
  TWastNode trees; this unit turns one node into a TWastVal — either a
  CONCRETE value (an argument, or an exact expected pattern) or a MATCHER
  (a NaN class, a reference-identity, a non-null predicate).

  WHY A DEDICATED FLOAT PARSER. The RTL's Val cannot read hex floats, NaN
  payloads, or the `nan:canonical`/`nan:arithmetic` classes, and the
  corpus hammers exactly those (subnormals, ±0, the smallest-subnormal
  rounding boundary, specific NaN payloads). So hex floats are parsed
  EXACTLY — a hex float is a rational of the form M·2^e, with no decimal
  rounding ambiguity — and packed into the target width with a single
  round-to-nearest-ties-to-even (PackFloat, a soft-float normalise/round).
  Decimal floats defer to the RTL's correctly-rounded Val for the f64
  case and narrow to f32 by hardware rounding.

  WHY BITWISE COMPARISON. assert_return compares bit patterns, not
  arithmetic values: `-0.0` is not `+0.0`, and an exact NaN payload is
  checked exactly. The two NaN CLASSES (canonical / arithmetic) are the
  only inexact matchers, and the interpreter's canonical-always NaN
  discipline (interp-spec §3.2) passes both.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Anchors:
  text-hexfloat, aux-nans (canonical / arithmetic NaN classes),
  appendix on the wast script value grammar. }
unit Wasm.Wast.Values;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Values,
  Wasm.Wast,
  Wasm.Wat.Numbers;

type
  { Parse-time problem in a value/matcher s-expr — an unrecognised form or
    a malformed literal. A harness-input error, distinct from a module
    error, so it gets its own class rather than being confused with a
    conformance result. }
  EWastValueError = class(EWasmError);

  { The categories a wast argument / expected-result s-expr parses into.
    The numeric and reference-null forms serve as both an ARGUMENT (a
    concrete value) and an EXACT expected matcher; the NaN-class, non-null
    reference, and multi-value forms are matchers only. }
  TWastValKind = (
    wvcI32,            { exact i32 bits (low 32 of Bits) }
    wvcI64,            { exact i64 bits }
    wvcF32,            { exact f32 bit pattern (low 32 of Bits) }
    wvcF64,            { exact f64 bit pattern }
    wvcNanCanonical,   { f32/f64 canonical-NaN class (Width says which) }
    wvcNanArithmetic,  { f32/f64 arithmetic-NaN class }
    wvcRefNull,        { a null of any hierarchy }
    wvcRefExtern,      { host box with identity Id (ref.extern N) }
    wvcRefHost,        { host box with identity Id (ref.host N) }
    wvcRefFunc,        { funcref: any non-null, or function Id when HasId }
    wvcRefAny,         { a non-null reference (ref.any/eq/i31/struct/...) }
    wvcV128            { SIMD constant — shape + per-lane bits + per-lane kind }
  );

  TWastValWidth = (wvwNone, wvw32, wvw64);

  { The declared shape of a `(v128.const <shape> ...)` — it fixes the lane
    width and count, and whether the lanes are integer or floating-point.
    A wvcV128 matcher compares lane by lane at this shape's width. }
  TWastVecShape = (wvsI8x16, wvsI16x8, wvsI32x4, wvsI64x2, wvsF32x4, wvsF64x2);

  { Per-lane matcher class. Only the float shapes ever use the NaN kinds; an
    integer lane is always wlkExact. A single float lane may be
    nan:canonical or nan:arithmetic while its neighbours are exact — the
    corpus mixes classes within one constant (simd_f32x4_arith.wast:5292),
    so the class lives per lane, not per value (design §6.1). }
  TWastLaneKind = (wlkExact, wlkNanCanonical, wlkNanArithmetic);

  { A parsed value or matcher. For the numeric kinds Bits holds the exact
    pattern (i32/f32 in the low 32 bits). For the reference-identity kinds
    Id is the host identity or function index. For wvcV128 the vector fields
    carry the shape and each lane's bits + kind (a 16-byte value cannot fit
    Bits). The record is copied by value. }
  TWastVal = record
    Kind: TWastValKind;
    Width: TWastValWidth;
    Bits: UInt64;
    Id: UInt32;
    HasId: Boolean;
    { wvcV128 only. VecLanes[i] holds lane i's bits low-aligned (an i8 lane
      in 0..255, an f32 lane in the low 32 bits); only the first
      lane-count entries are meaningful. }
    VecShape: TWastVecShape;
    VecLanes: array[0..15] of UInt64;
    VecLaneKinds: array[0..15] of TWastLaneKind;
  end;

  { An expected RESULT matcher: either a single value/matcher (Alts length
    1) or the relaxed-SIMD `(either A B ...)` form (Alts length 2..4), which
    passes if the actual matches ANY alternative. Lifted out of TWastVal
    because a record cannot hold a dynamic array of itself (design §6.1). }
  TWastExpected = record
    Alts: array of TWastVal;
  end;

const
  { The canonical NaN bit patterns (interp-spec §3.2). Positive; the class
    matchers ignore the sign. }
  WASM_F32_CANONICAL_NAN = UInt32($7FC00000);
  WASM_F64_CANONICAL_NAN = UInt64($7FF8000000000000);

{ --- scalar literal parsers (exposed for unit testing) ------------------- }

{ Parse a wast integer literal: optional sign, decimal or `0x` hex,
  underscores between digits, wrapping to the width's two's complement.
  The testsuite writes i32/i64 constants across the full unsigned OR
  signed range, so `-1` and `4294967295` both yield $FFFFFFFF for i32. }
function WastParseInt32(const AText: string; out AValue: UInt32): Boolean;
function WastParseInt64(const AText: string; out AValue: UInt64): Boolean;

{ Parse a wast float literal into its target-width bit pattern. Handles
  decimal floats, hex floats (`0x1.5p3`), `inf`/`-inf`, bare `nan`
  (canonical), and `nan:0x<payload>`. The class tokens `nan:canonical`
  and `nan:arithmetic` are recognised too — as concrete values they
  produce the canonical pattern, but WastParseVal intercepts them into
  class matchers before reaching here. }
function WastParseF32Bits(const AText: string; out ABits: UInt32): Boolean;
function WastParseF64Bits(const AText: string; out ABits: UInt64): Boolean;

{ --- value / matcher parser ---------------------------------------------- }

{ Parse one value/matcher s-expr node. Raises EWastValueError when the
  node is not a recognised value form or a literal does not parse. A
  `(v128.const <shape> lane...)` node parses into a wvcV128 with its shape,
  per-lane bits, and per-lane kinds. }
function WastParseVal(const ANode: TWastNode): TWastVal;

{ Parse an expected RESULT node into a matcher. `(either A B ...)` yields a
  multi-alternative matcher; every other form yields a single-alternative
  one wrapping WastParseVal. Raises EWastValueError on a bad form. }
function WastParseExpected(const ANode: TWastNode): TWastExpected;

{ Number of lanes in a v128 shape (16/8/4/2 by lane width). }
function VecLaneCount(const AShape: TWastVecShape): Integer;

{ True when the value form is a host/func reference IDENTITY the runner
  must resolve against its own registry before comparison. }
function WastValIsRefIdentity(const AVal: TWastVal): Boolean;

{ Materialise a concrete SCALAR TWastVal (numeric, NaN, or ref.null) into a
  runtime slot. The reference-identity kinds cannot be built without the
  store's heap and are the runner's job; a v128 spans two slots and is built
  with WastValToVec instead. This raises EWastValueError for both. }
function WastValToRuntime(const AVal: TWastVal): TWasmValue;

{ Build the 16-byte vector of a wvcV128 value from its shape and per-lane
  bits, little-endian within the vector. The runner writes its two 8-byte
  halves into two consecutive TWasmValue slots, low half first (design
  §1.6). A NaN-class lane materialises as the canonical pattern. }
function WastValToVec(const AVal: TWastVal): TWasmV128;

{ --- comparator ---------------------------------------------------------- }

{ Does the produced SCALAR runtime value AActual match the expected matcher
  AExpected? For the reference-identity kinds the caller resolves the
  expected reference (its minted host box or the function's handle) and
  passes it as AExpectedRef; the other kinds ignore it. Numeric and exact
  float matches are BITWISE; the NaN classes are per-width bit-class
  tests. wvcV128 is never matched here — it goes through WastExpectedMatches
  — so its arm falls to the defensive default. }
function WastValMatches(const AExpected: TWastVal; const AActual: TWasmValue;
  const AExpectedRef: TWasmRef): Boolean;

{ Does the produced result match the expected matcher? True iff ANY of
  AExpected.Alts matches (the `(either ...)` rule). AActual points at the
  result slot(s): a v128 alternative reads AActual[0] and AActual[1] as one
  TWasmV128 (AActualIsVec must be True), comparing lane by lane at the
  shape's width — bitwise for exact lanes, the canonical/arithmetic bit
  class for a nan:canonical/nan:arithmetic lane. Scalar alternatives read
  AActual^ and use AExpectedRef exactly as WastValMatches does. }
function WastExpectedMatches(const AExpected: TWastExpected;
  const AActual: PWasmValue; const AActualIsVec: Boolean;
  const AExpectedRef: TWasmRef): Boolean;

implementation

{ --- small lexical helpers ----------------------------------------------- }

function IsHexDigit(const AChar: Char): Boolean; inline;
begin
  Result := ((AChar >= '0') and (AChar <= '9'))
    or ((AChar >= 'a') and (AChar <= 'f'))
    or ((AChar >= 'A') and (AChar <= 'F'));
end;

function HexDigitValue(const AChar: Char): Byte; inline;
begin
  if (AChar >= '0') and (AChar <= '9') then
    Result := Ord(AChar) - Ord('0')
  else if (AChar >= 'a') and (AChar <= 'f') then
    Result := Ord(AChar) - Ord('a') + 10
  else
    Result := Ord(AChar) - Ord('A') + 10;
end;

{ --- bit casts ----------------------------------------------------------- }

function DoubleBits(const AValue: Double): UInt64; inline;
var
  U: record case Integer of 0: (D: Double); 1: (B: UInt64); end;
begin
  U.D := AValue;
  Result := U.B;
end;

function SingleBits(const AValue: Single): UInt32; inline;
var
  U: record case Integer of 0: (S: Single); 1: (B: UInt32); end;
begin
  U.S := AValue;
  Result := U.B;
end;

{ --- integer parsing ----------------------------------------------------- }

{ Wraparound arithmetic is the point here — the testsuite writes the full
  unsigned range of a width — so overflow/range checks are off locally
  (Shared.inc turns them ON outside PRODUCTION). }
{$PUSH}
{$Q-}
{$R-}
function ParseIntCore(const AText: string; out AValue: UInt64): Boolean;
var
  S: string;
  I: Integer;
  Neg, Hex, Any: Boolean;
  Acc: UInt64;
  C: Char;
begin
  Result := False;
  AValue := 0;
  S := AText;
  I := 1;
  if I > Length(S) then
    Exit;
  Neg := False;
  if S[I] = '+' then
    Inc(I)
  else if S[I] = '-' then
  begin
    Neg := True;
    Inc(I);
  end;
  Hex := False;
  if (I + 1 <= Length(S)) and (S[I] = '0')
    and ((S[I + 1] = 'x') or (S[I + 1] = 'X')) then
  begin
    Hex := True;
    Inc(I, 2);
  end;
  Acc := 0;
  Any := False;
  while I <= Length(S) do
  begin
    C := S[I];
    if C = '_' then
    begin
      Inc(I);
      Continue;
    end;
    if Hex then
    begin
      if not IsHexDigit(C) then
        Exit;
      Acc := (Acc shl 4) or HexDigitValue(C);
    end
    else
    begin
      if (C < '0') or (C > '9') then
        Exit;
      Acc := Acc * 10 + UInt64(Ord(C) - Ord('0'));
    end;
    Any := True;
    Inc(I);
  end;
  if not Any then
    Exit;
  if Neg then
    Acc := UInt64(0) - Acc;
  AValue := Acc;
  Result := True;
end;
{$POP}

function WastParseInt32(const AText: string; out AValue: UInt32): Boolean;
var
  Wide: UInt64;
begin
  Result := ParseIntCore(AText, Wide);
  AValue := UInt32(Wide and $FFFFFFFF);
end;

function WastParseInt64(const AText: string; out AValue: UInt64): Boolean;
begin
  Result := ParseIntCore(AText, AValue);
end;

{ --- float packing (soft-float normalise + round) ------------------------ }

function HighBit(const AValue: UInt64): Integer; inline;
var
  I: Integer;
begin
  Result := 63;
  for I := 63 downto 0 do
    if (AValue and (UInt64(1) shl I)) <> 0 then
      Exit(I);
  Result := 0;
end;

{ Pack the binary value (-1)^ANeg · AMantissa · 2^AExp2 into an IEEE float
  of AMantBits fraction bits and AExpBits exponent bits, rounding to
  nearest, ties to even. ASticky records that nonzero bits were dropped
  below AMantissa's least significant bit during accumulation, which the
  round must treat as an inexact remainder. Handles subnormals, overflow
  to infinity, and signed zero. }
{$PUSH}
{$Q-}
{$R-}
function PackFloat(const ANeg: Boolean; const AMantissa: UInt64;
  const AExp2: Integer; const ASticky: Boolean;
  const AMantBits, AExpBits: Integer): UInt64;
var
  P, Bias, MaxExp, HighestBit, Biased, DropBits: Integer;
  Sig, Half, LowMask, Rem, SigTop, Frac, SignBit: UInt64;
begin
  P := AMantBits + 1;                          { significand precision }
  Bias := (1 shl (AExpBits - 1)) - 1;
  MaxExp := (1 shl AExpBits) - 1;
  if ANeg then
    SignBit := UInt64(1) shl (AMantBits + AExpBits)
  else
    SignBit := 0;

  if AMantissa = 0 then
  begin
    Result := SignBit;                         { signed zero }
    Exit;
  end;

  HighestBit := HighBit(AMantissa);
  { Left-justify so the leading 1 sits at bit 63; fold the carried sticky
    into the low bit, which is always part of the round/sticky region. }
  Sig := AMantissa shl (63 - HighestBit);
  if ASticky then
    Sig := Sig or 1;
  Biased := AExp2 + HighestBit + Bias;         { biased exp of a normal }

  if Biased >= MaxExp then
  begin
    Result := SignBit or (UInt64(MaxExp) shl AMantBits);   { infinity }
    Exit;
  end;

  if Biased <= 0 then
  begin
    { Subnormal: the exponent floors at 1-Bias, so drop extra bits. }
    DropBits := (64 - P) + (1 - Biased);
    if DropBits >= 64 then
    begin
      if DropBits = 64 then
      begin
        { Half sits at bit 63. SigTop is 0; a tie rounds to even (0). }
        Rem := Sig;
        Half := UInt64(1) shl 63;
        SigTop := 0;
        if Rem > Half then
          Inc(SigTop);
        Result := SignBit or SigTop;
        Exit;
      end;
      Result := SignBit;                       { underflow to zero }
      Exit;
    end;
    SigTop := Sig shr DropBits;
    LowMask := (UInt64(1) shl DropBits) - 1;
    Rem := Sig and LowMask;
    Half := UInt64(1) shl (DropBits - 1);
    if (Rem > Half) or ((Rem = Half) and ((SigTop and 1) <> 0)) then
      Inc(SigTop);
    { A carry into bit AMantBits promotes to the smallest normal, which the
      bit layout represents as exp field 1, frac 0 — SigTop already spells
      it. }
    Result := SignBit or SigTop;
    Exit;
  end;

  { Normal. }
  DropBits := 64 - P;
  SigTop := Sig shr DropBits;
  LowMask := (UInt64(1) shl DropBits) - 1;
  Rem := Sig and LowMask;
  Half := UInt64(1) shl (DropBits - 1);
  if (Rem > Half) or ((Rem = Half) and ((SigTop and 1) <> 0)) then
    Inc(SigTop);
  if (SigTop shr P) <> 0 then                  { rounded up to 2.0 }
  begin
    SigTop := SigTop shr 1;
    Inc(Biased);
  end;
  if Biased >= MaxExp then
  begin
    Result := SignBit or (UInt64(MaxExp) shl AMantBits);   { overflow → inf }
    Exit;
  end;
  Frac := SigTop and ((UInt64(1) shl AMantBits) - 1);
  Result := SignBit or (UInt64(Biased) shl AMantBits) or Frac;
end;
{$POP}

{ --- float parsing ------------------------------------------------------- }

function StripUnderscores(const AText: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AText) do
    if AText[I] <> '_' then
      Result := Result + AText[I];
end;

{ Parse the hex-float body (AText[AStart..], right after "0x") into bits.
  Mantissa hex digits accumulate into a 64-bit significand with a sticky
  flag for anything below it; each dropped digit folds 4 into the binary
  exponent, which is correct for BOTH an over-long integer part (digits
  scale the kept significand up) and an over-long fraction (net zero, just
  sticky). }
{$PUSH}
{$Q-}
{$R-}
function ParseHexFloatBody(const AText: string; const AStart: Integer;
  const ANeg: Boolean; const AMantBits, AExpBits: Integer;
  out ABits: UInt64): Boolean;
var
  I, FracDigits, PExp, ExtraShift, Exp2: Integer;
  Mant: UInt64;
  Sticky, SawDot, SawDigit, PNeg, AnyExp: Boolean;
  C: Char;
  Nib: Byte;
begin
  Result := False;
  I := AStart;
  Mant := 0;
  ExtraShift := 0;
  FracDigits := 0;
  Sticky := False;
  SawDot := False;
  SawDigit := False;
  while I <= Length(AText) do
  begin
    C := AText[I];
    if C = '_' then
    begin
      Inc(I);
      Continue;
    end;
    if C = '.' then
    begin
      if SawDot then
        Exit;
      SawDot := True;
      Inc(I);
      Continue;
    end;
    if (C = 'p') or (C = 'P') then
      Break;
    if not IsHexDigit(C) then
      Exit;
    Nib := HexDigitValue(C);
    SawDigit := True;
    if Mant <= (High(UInt64) shr 4) then
      Mant := (Mant shl 4) or Nib
    else
    begin
      ExtraShift := ExtraShift + 4;
      if Nib <> 0 then
        Sticky := True;
    end;
    if SawDot then
      Inc(FracDigits);
    Inc(I);
  end;
  if not SawDigit then
    Exit;

  PExp := 0;
  PNeg := False;
  AnyExp := False;
  if (I <= Length(AText)) and ((AText[I] = 'p') or (AText[I] = 'P')) then
  begin
    Inc(I);
    if (I <= Length(AText)) and (AText[I] = '+') then
      Inc(I)
    else if (I <= Length(AText)) and (AText[I] = '-') then
    begin
      PNeg := True;
      Inc(I);
    end;
    while I <= Length(AText) do
    begin
      C := AText[I];
      if C = '_' then
      begin
        Inc(I);
        Continue;
      end;
      if (C < '0') or (C > '9') then
        Exit;
      PExp := PExp * 10 + (Ord(C) - Ord('0'));
      AnyExp := True;
      Inc(I);
    end;
    if not AnyExp then
      Exit;
    if PNeg then
      PExp := -PExp;
  end;

  Exp2 := PExp - 4 * FracDigits + ExtraShift;
  ABits := PackFloat(ANeg, Mant, Exp2, Sticky, AMantBits, AExpBits);
  Result := True;
end;
{$POP}

function ParseDecimalFloat(const ANeg: Boolean; const AMagText: string;
  const AMantBits, AExpBits: Integer; out ABits: UInt64): Boolean;
var
  Bits, SignBit: UInt64;
begin
  { Correctly-rounded decimal-to-float is delegated to the assembler's
    ParseFloat (Wasm.Wat.Numbers) — the SAME parser the v128.const lane
    literals use (ParseF32/ParseF64) — so an expected `f64.const` and a
    `v128.const` lane round an identical literal to identical bits. The RTL's
    Val mis-rounds SUBNORMALS (e.g. 1.7976931348623157e-308), which showed
    up as a false assert_return mismatch on simd_lane.wast where the
    interpreter had in fact computed the exact IEEE result. }
  Result := False;
  try
    if AMantBits = 23 then
      Bits := UInt64(ParseF32(AMagText))
    else
      Bits := ParseF64(AMagText);
  except
    on EWasmTextError do
      Exit;
  end;
  SignBit := UInt64(1) shl (AMantBits + AExpBits);
  if ANeg then
    Bits := Bits or SignBit
  else
    Bits := Bits and not SignBit;
  ABits := Bits;
  Result := True;
end;

function CanonicalNanBits(const AMantBits, AExpBits: Integer;
  const ANeg: Boolean): UInt64;
var
  SignBit: UInt64;
begin
  if ANeg then
    SignBit := UInt64(1) shl (AMantBits + AExpBits)
  else
    SignBit := 0;
  Result := SignBit or (UInt64((1 shl AExpBits) - 1) shl AMantBits)
    or (UInt64(1) shl (AMantBits - 1));
end;

{$PUSH}
{$Q-}
{$R-}
function ParseFloatBits(const AText: string; const AMantBits, AExpBits: Integer;
  out ABits: UInt64): Boolean;
var
  S, Payload: string;
  Neg: Boolean;
  MaxExp: Integer;
  SignBit, PayloadBits: UInt64;
begin
  Result := False;
  S := AText;
  Neg := False;
  if Length(S) >= 1 then
  begin
    if S[1] = '+' then
      S := Copy(S, 2, MaxInt)
    else if S[1] = '-' then
    begin
      Neg := True;
      S := Copy(S, 2, MaxInt);
    end;
  end;
  MaxExp := (1 shl AExpBits) - 1;
  if Neg then
    SignBit := UInt64(1) shl (AMantBits + AExpBits)
  else
    SignBit := 0;

  if S = 'inf' then
  begin
    ABits := SignBit or (UInt64(MaxExp) shl AMantBits);
    Exit(True);
  end;
  if (S = 'nan') or (S = 'nan:canonical') or (S = 'nan:arithmetic') then
  begin
    ABits := CanonicalNanBits(AMantBits, AExpBits, Neg);
    Exit(True);
  end;
  if (Length(S) > 6) and (Copy(S, 1, 6) = 'nan:0x') then
  begin
    Payload := StripUnderscores(Copy(S, 5, MaxInt));   { keep the 0x }
    if not WastParseInt64(Payload, PayloadBits) then
      Exit;
    if (PayloadBits = 0)
      or (PayloadBits >= (UInt64(1) shl AMantBits)) then
      Exit;                                            { must be a real NaN }
    ABits := SignBit or (UInt64(MaxExp) shl AMantBits) or PayloadBits;
    Exit(True);
  end;

  if (Length(S) >= 2) and (S[1] = '0') and ((S[2] = 'x') or (S[2] = 'X')) then
    Result := ParseHexFloatBody(S, 3, Neg, AMantBits, AExpBits, ABits)
  else
    Result := ParseDecimalFloat(Neg, StripUnderscores(S),
      AMantBits, AExpBits, ABits);
end;
{$POP}

function WastParseF32Bits(const AText: string; out ABits: UInt32): Boolean;
var
  Wide: UInt64;
begin
  Result := ParseFloatBits(AText, 23, 8, Wide);
  ABits := UInt32(Wide and $FFFFFFFF);
end;

function WastParseF64Bits(const AText: string; out ABits: UInt64): Boolean;
begin
  Result := ParseFloatBits(AText, 52, 11, ABits);
end;

{ --- value / matcher parser ---------------------------------------------- }

{ The value literal of a `(op literal)` node — its first atom child, or ''
  when the node has no atom operand (e.g. bare `(ref.func)`). }
function ValueAtom(const ANode: TWastNode): string;
begin
  if (ANode.Count >= 2) and (ANode[1].Kind = wnkAtom) then
    Result := ANode[1].Atom
  else
    Result := '';
end;

{ Lanes in a v128 shape: 16/8/4/2 by lane width. }
function VecLaneCount(const AShape: TWastVecShape): Integer;
begin
  case AShape of
    wvsI8x16: Result := 16;
    wvsI16x8: Result := 8;
    wvsI32x4, wvsF32x4: Result := 4;
  else
    Result := 2;   { wvsI64x2, wvsF64x2 }
  end;
end;

{ Parse `(v128.const <shape> lane0 lane1 ...)` into AVal (already zeroed by
  the caller). The shape keyword fixes the lane count and width; each lane
  literal is parsed via Wasm.Wat.Numbers at the lane width. A float lane may
  be nan:canonical / nan:arithmetic, recorded as a per-lane CLASS with the
  canonical pattern as its placeholder bits (design §6.1). }
procedure ParseV128Const(const ANode: TWastNode; var AVal: TWastVal);
var
  Shape, Tok: string;
  Count, I: Integer;
begin
  AVal.Kind := wvcV128;
  AVal.Width := wvwNone;   { VecShape carries the width }
  if (ANode.Count < 2) or (ANode[1].Kind <> wnkAtom) then
    raise EWastValueError.Create('v128.const needs a shape');
  Shape := ANode[1].Atom;
  if Shape = 'i8x16' then
    AVal.VecShape := wvsI8x16
  else if Shape = 'i16x8' then
    AVal.VecShape := wvsI16x8
  else if Shape = 'i32x4' then
    AVal.VecShape := wvsI32x4
  else if Shape = 'i64x2' then
    AVal.VecShape := wvsI64x2
  else if Shape = 'f32x4' then
    AVal.VecShape := wvsF32x4
  else if Shape = 'f64x2' then
    AVal.VecShape := wvsF64x2
  else
    raise EWastValueError.CreateFmt('unknown v128 shape "%s"', [Shape]);

  Count := VecLaneCount(AVal.VecShape);
  if ANode.Count - 2 <> Count then
    raise EWastValueError.CreateFmt(
      'v128.const %s needs %d lanes, got %d', [Shape, Count, ANode.Count - 2]);

  for I := 0 to Count - 1 do
  begin
    if ANode[2 + I].Kind <> wnkAtom then
      raise EWastValueError.Create('v128.const lane must be a literal');
    Tok := ANode[2 + I].Atom;
    AVal.VecLaneKinds[I] := wlkExact;
    try
      case AVal.VecShape of
        wvsI8x16: AVal.VecLanes[I] := UInt64(ParseI8(Tok));
        wvsI16x8: AVal.VecLanes[I] := UInt64(ParseI16(Tok));
        wvsI32x4: AVal.VecLanes[I] := UInt64(ParseI32(Tok));
        wvsI64x2: AVal.VecLanes[I] := ParseI64(Tok);
        wvsF32x4:
          if Tok = 'nan:canonical' then
          begin
            AVal.VecLaneKinds[I] := wlkNanCanonical;
            AVal.VecLanes[I] := UInt64(WASM_F32_CANONICAL_NAN);
          end
          else if Tok = 'nan:arithmetic' then
          begin
            AVal.VecLaneKinds[I] := wlkNanArithmetic;
            AVal.VecLanes[I] := UInt64(WASM_F32_CANONICAL_NAN);
          end
          else
            AVal.VecLanes[I] := UInt64(ParseF32(Tok));
        wvsF64x2:
          if Tok = 'nan:canonical' then
          begin
            AVal.VecLaneKinds[I] := wlkNanCanonical;
            AVal.VecLanes[I] := WASM_F64_CANONICAL_NAN;
          end
          else if Tok = 'nan:arithmetic' then
          begin
            AVal.VecLaneKinds[I] := wlkNanArithmetic;
            AVal.VecLanes[I] := WASM_F64_CANONICAL_NAN;
          end
          else
            AVal.VecLanes[I] := ParseF64(Tok);
      end;
    except
      on E: EWasmTextError do
        raise EWastValueError.CreateFmt('bad v128 lane "%s": %s',
          [Tok, E.Message]);
    end;
  end;
end;

function WastParseVal(const ANode: TWastNode): TWastVal;
var
  Head, Lit: string;
  I32: UInt32;
  I64, F64: UInt64;
  F32: UInt32;
begin
  FillChar(Result, SizeOf(Result), 0);
  if ANode.Kind <> wnkList then
    raise EWastValueError.Create('value must be an s-expression');
  Head := ANode.HeadAtom;
  Lit := ValueAtom(ANode);

  if Head = 'i32.const' then
  begin
    if not WastParseInt32(Lit, I32) then
      raise EWastValueError.CreateFmt('bad i32 literal "%s"', [Lit]);
    Result.Kind := wvcI32;
    Result.Width := wvw32;
    Result.Bits := UInt64(I32);
  end
  else if Head = 'i64.const' then
  begin
    if not WastParseInt64(Lit, I64) then
      raise EWastValueError.CreateFmt('bad i64 literal "%s"', [Lit]);
    Result.Kind := wvcI64;
    Result.Width := wvw64;
    Result.Bits := I64;
  end
  else if Head = 'f32.const' then
  begin
    Result.Width := wvw32;
    if Lit = 'nan:canonical' then
      Result.Kind := wvcNanCanonical
    else if Lit = 'nan:arithmetic' then
      Result.Kind := wvcNanArithmetic
    else
    begin
      if not WastParseF32Bits(Lit, F32) then
        raise EWastValueError.CreateFmt('bad f32 literal "%s"', [Lit]);
      Result.Kind := wvcF32;
      Result.Bits := UInt64(F32);
    end;
  end
  else if Head = 'f64.const' then
  begin
    Result.Width := wvw64;
    if Lit = 'nan:canonical' then
      Result.Kind := wvcNanCanonical
    else if Lit = 'nan:arithmetic' then
      Result.Kind := wvcNanArithmetic
    else
    begin
      if not WastParseF64Bits(Lit, F64) then
        raise EWastValueError.CreateFmt('bad f64 literal "%s"', [Lit]);
      Result.Kind := wvcF64;
      Result.Bits := F64;
    end;
  end
  else if Head = 'ref.null' then
    Result.Kind := wvcRefNull
  else if (Head = 'ref.extern') or (Head = 'ref.host') then
  begin
    if Head = 'ref.host' then
      Result.Kind := wvcRefHost
    else
      Result.Kind := wvcRefExtern;
    if Lit <> '' then
    begin
      if not WastParseInt32(Lit, Result.Id) then
        raise EWastValueError.CreateFmt('bad ref id "%s"', [Lit]);
      Result.HasId := True;
    end;
  end
  else if Head = 'ref.func' then
  begin
    Result.Kind := wvcRefFunc;
    if Lit <> '' then
    begin
      if WastParseInt32(Lit, Result.Id) then
        Result.HasId := True;
    end;
  end
  else if (Head = 'ref.any') or (Head = 'ref.eq') or (Head = 'ref.i31')
    or (Head = 'ref.struct') or (Head = 'ref.array') then
    Result.Kind := wvcRefAny
  else if Head = 'v128.const' then
    ParseV128Const(ANode, Result)
  else
    raise EWastValueError.CreateFmt('unrecognised value form "%s"', [Head]);
end;

function WastParseExpected(const ANode: TWastNode): TWastExpected;
var
  I: Integer;
begin
  if (ANode.Kind = wnkList) and (ANode.HeadAtom = 'either') then
  begin
    { `(either A B ...)` — the relaxed-SIMD alternatives, each a value node.
      Never nested, never in argument position (design §6.2). }
    if ANode.Count < 2 then
      raise EWastValueError.Create('(either ...) needs at least one alternative');
    SetLength(Result.Alts, ANode.Count - 1);
    for I := 1 to ANode.Count - 1 do
      Result.Alts[I - 1] := WastParseVal(ANode[I]);
  end
  else
  begin
    SetLength(Result.Alts, 1);
    Result.Alts[0] := WastParseVal(ANode);
  end;
end;

function WastValIsRefIdentity(const AVal: TWastVal): Boolean;
begin
  Result := AVal.Kind in [wvcRefExtern, wvcRefHost, wvcRefFunc];
end;

function WastValToRuntime(const AVal: TWastVal): TWasmValue;
begin
  Result.Bits := 0;
  case AVal.Kind of
    wvcI32, wvcI64, wvcF32, wvcF64:
      Result.Bits := AVal.Bits;
    wvcNanCanonical:
      if AVal.Width = wvw32 then
        Result.Bits := UInt64(WASM_F32_CANONICAL_NAN)
      else
        Result.Bits := WASM_F64_CANONICAL_NAN;
    wvcNanArithmetic:
      if AVal.Width = wvw32 then
        Result.Bits := UInt64(WASM_F32_CANONICAL_NAN)
      else
        Result.Bits := WASM_F64_CANONICAL_NAN;
    wvcRefNull:
      Result.Bits := 0;
  else
    raise EWastValueError.Create(
      'value cannot be built without the store (ref identity or v128)');
  end;
end;

function WastValToVec(const AVal: TWastVal): TWasmV128;
var
  I, Count: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Count := VecLaneCount(AVal.VecShape);
  for I := 0 to Count - 1 do
    case AVal.VecShape of
      wvsI8x16: Result.B[I] := Byte(AVal.VecLanes[I]);
      wvsI16x8: Result.U16[I] := Word(AVal.VecLanes[I]);
      wvsI32x4, wvsF32x4: Result.U32[I] := UInt32(AVal.VecLanes[I]);
      wvsI64x2, wvsF64x2: Result.U64[I] := AVal.VecLanes[I];
    end;
end;

{ --- comparator ---------------------------------------------------------- }

function IsF32Canonical(const ABits: UInt64): Boolean; inline;
begin
  Result := (ABits and $7FFFFFFF) = UInt64(WASM_F32_CANONICAL_NAN);
end;

function IsF64Canonical(const ABits: UInt64): Boolean; inline;
begin
  Result := (ABits and $7FFFFFFFFFFFFFFF) = WASM_F64_CANONICAL_NAN;
end;

function IsF32Arithmetic(const ABits: UInt64): Boolean; inline;
begin
  { Exponent all ones, significand nonzero, payload MSB set. }
  Result := ((ABits and $7F800000) = $7F800000)
    and ((ABits and $007FFFFF) <> 0)
    and ((ABits and $00400000) <> 0);
end;

function IsF64Arithmetic(const ABits: UInt64): Boolean; inline;
begin
  Result := ((ABits and $7FF0000000000000) = $7FF0000000000000)
    and ((ABits and $000FFFFFFFFFFFFF) <> 0)
    and ((ABits and $0008000000000000) <> 0);
end;

{ Peel any M7 conversion wrapper (wokExternalized / wokInternalized) off a
  produced reference so a `(ref.host N)` / `(ref.extern N)` matcher compares
  the underlying host IDENTITY rather than the wrapper pointer. The runner
  mints a single host box per id N and `ExpectedRefFor` hands that box to both
  the extern and host matcher; a value that has crossed the any<->extern
  boundary via extern.convert_any / any.convert_extern is that same host box
  inside a wrapper (ADR-0001: the spec's two hierarchies "are inhabited by an
  isomorphic set of values"), so unwrapping recovers the id. A plain host box
  (never converted) resolves to itself, so this is a no-op for every prior
  case and stays correct even when a tier still realises the convert ops as
  representation identity. }
function ResolveHostIdentity(const ARef: TWasmRef): TWasmRef;
var
  Cur: TWasmRef;
  Kind: TWasmObjKind;
begin
  Cur := ARef;
  while RefIsObject(Cur) do
  begin
    Kind := GcRefKind(Cur);
    if (Kind <> wokExternalized) and (Kind <> wokInternalized) then
      Break;
    Cur := GcConvertInner(Cur);
  end;
  Result := Cur;
end;

function WastValMatches(const AExpected: TWastVal; const AActual: TWasmValue;
  const AExpectedRef: TWasmRef): Boolean;
begin
  case AExpected.Kind of
    wvcI32, wvcF32:
      Result := (AActual.Bits and $FFFFFFFF)
        = (AExpected.Bits and $FFFFFFFF);
    wvcI64, wvcF64:
      Result := AActual.Bits = AExpected.Bits;
    wvcNanCanonical:
      if AExpected.Width = wvw32 then
        Result := IsF32Canonical(AActual.Bits)
      else
        Result := IsF64Canonical(AActual.Bits);
    wvcNanArithmetic:
      if AExpected.Width = wvw32 then
        Result := IsF32Arithmetic(AActual.Bits)
      else
        Result := IsF64Arithmetic(AActual.Bits);
    wvcRefNull:
      Result := RefIsNull(AActual.Ref);
    wvcRefExtern, wvcRefHost:
      { A specific host box when N is given (ref.extern N / ref.host N),
        otherwise any non-null externref (the corpus's bare `(ref.extern)`).
        Mirrors the bare-`(ref.func)` any-non-null fallback below and keys on
        the same signal: the runner mints a non-null identity only for the
        N form (a boxed host value is never WASM_REF_NULL) and leaves a bare
        matcher's AExpectedRef null. Without the fallback a correct non-null
        externref is judged a mismatch against `AActual.Ref = WASM_REF_NULL`. }
      if AExpectedRef <> WASM_REF_NULL then
        Result := ResolveHostIdentity(AActual.Ref) = AExpectedRef
      else
        Result := not RefIsNull(AActual.Ref);
    wvcRefFunc:
      { A specific function's handle when known, otherwise any non-null
        funcref (the corpus's bare `(ref.func)`). }
      if AExpectedRef <> WASM_REF_NULL then
        Result := AActual.Ref = AExpectedRef
      else
        Result := not RefIsNull(AActual.Ref);
    wvcRefAny:
      Result := not RefIsNull(AActual.Ref);
  else
    Result := False;
  end;
end;

{ Compare a produced vector against a wvcV128 matcher, lane by lane at the
  matcher's shape width. A single diverging lane fails the whole vector. }
function WastVecMatches(const AExpected: TWastVal;
  const AActual: PWasmV128): Boolean;
var
  I, Count: Integer;
  ActLane: UInt64;
begin
  Result := False;
  Count := VecLaneCount(AExpected.VecShape);
  for I := 0 to Count - 1 do
  begin
    case AExpected.VecShape of
      wvsI8x16: ActLane := UInt64(AActual^.B[I]);
      wvsI16x8: ActLane := UInt64(AActual^.U16[I]);
      wvsI32x4, wvsF32x4: ActLane := UInt64(AActual^.U32[I]);
    else
      ActLane := AActual^.U64[I];   { wvsI64x2, wvsF64x2 }
    end;
    case AExpected.VecLaneKinds[I] of
      wlkExact:
        { VecLanes[i] is already masked to the lane width by the parser. }
        if ActLane <> AExpected.VecLanes[I] then
          Exit;
      wlkNanCanonical:
        if AExpected.VecShape = wvsF32x4 then
        begin
          if not IsF32Canonical(ActLane) then
            Exit;
        end
        else if not IsF64Canonical(ActLane) then
          Exit;
      wlkNanArithmetic:
        if AExpected.VecShape = wvsF32x4 then
        begin
          if not IsF32Arithmetic(ActLane) then
            Exit;
        end
        else if not IsF64Arithmetic(ActLane) then
          Exit;
    end;
  end;
  Result := True;
end;

function WastExpectedMatches(const AExpected: TWastExpected;
  const AActual: PWasmValue; const AActualIsVec: Boolean;
  const AExpectedRef: TWasmRef): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(AExpected.Alts) do
  begin
    if AExpected.Alts[I].Kind = wvcV128 then
    begin
      if AActualIsVec
        and WastVecMatches(AExpected.Alts[I], PWasmV128(AActual)) then
        Exit(True);
    end
    else if WastValMatches(AExpected.Alts[I], AActual^, AExpectedRef) then
      Exit(True);
  end;
end;

end.
