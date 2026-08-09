{ Unit suite for Wasm.Interp.Vector — the SIMD lane-semantics micro-net.

  Every leaf is checked at representative and boundary inputs with bit-exact
  expected TWasmV128 results. The cases the spec corpus (tests/spec/testsuite/
  simd_*.wast) hammers and that have been real defects in shipped engines are
  spelled out next to the assertion: the wrap/saturate boundaries (add_sat,
  narrow), shift-count masking, avgr rounding, q15mulr's single saturating
  case, the per-lane NaN discipline (arithmetic op on a NaN lane -> canonical;
  pmin/pmax preserve the operand's exact bits and payload), min/max -0/+0,
  trunc_sat NaN->0 and range clamps, the _zero conversions zeroing high lanes,
  swizzle out-of-range->0, shuffle lane selection, bitmask/all_true/any_true,
  the byte-level load/store transforms, and each relaxed op equalling its twin.

  Vectors are built from typed lane literals (VI8/VU8/VI16/... and VF32/VF64
  for raw float bits) and compared as their two u64 halves, so a failure diff
  is a readable hex pair.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
program Wasm.Interp.Vector.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Interp.Vector;

{ Lane literals wrap/reinterpret exactly as the interpreter does; turn the
  checks off so a signed lane literal like -128 stores as $80. }
{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

function VI8(const B: array of ShortInt): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(B) do Result.B[I] := Byte(B[I]);
end;

function VU8(const B: array of Byte): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(B) do Result.B[I] := B[I];
end;

function VI16(const W: array of SmallInt): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U16[I] := Word(W[I]);
end;

function VU16(const W: array of Word): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U16[I] := W[I];
end;

function VI32(const W: array of Int32): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U32[I] := UInt32(W[I]);
end;

function VU32(const W: array of UInt32): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U32[I] := W[I];
end;

function VI64(const W: array of Int64): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U64[I] := UInt64(W[I]);
end;

function VU64(const W: array of UInt64): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U64[I] := W[I];
end;

{ FPC forbids @FunctionResult, so leaf calls that build an operand inline route
  it through P, which copies the value into a small ring of scratch buffers and
  returns a pointer. A single leaf call takes at most three vector operands, so
  an eight-slot ring guarantees the operands of one statement never collide;
  CheckV compares expected vectors by value, so it never aliases the ring. }
var
  GScratch: array[0..7] of TWasmV128;
  GScratchIx: Integer;

function P(const V: TWasmV128): PWasmV128;
begin
  GScratch[GScratchIx] := V;
  Result := @GScratch[GScratchIx];
  GScratchIx := (GScratchIx + 1) and 7;
end;

{ Raw f32/f64 lane BITS (so a NaN payload is written exactly). }
function VF32(const W: array of UInt32): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U32[I] := W[I];
end;

function VF64(const W: array of UInt64): TWasmV128;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 0 to High(W) do Result.U64[I] := W[I];
end;

const
  { f32 bit patterns. }
  F32_0    = UInt32($00000000);
  F32_NEG0 = UInt32($80000000);
  F32_1    = UInt32($3F800000);
  F32_2    = UInt32($40000000);
  F32_NEG1 = UInt32($BF800000);
  F32_INF  = UInt32($7F800000);
  F32_NINF = UInt32($FF800000);
  F32_CANON = UInt32($7FC00000);           { canonical NaN }
  F32_PL   = UInt32($7FA00000);            { nan:0x200000 payload }
  F32_NPL  = UInt32($FFA00000);            { -nan:0x200000 }
  F32_1P5  = UInt32($3FC00000);            { 1.5 }
  F32_N1P5 = UInt32($BFC00000);            { -1.5 }

  { f64 bit patterns. }
  F64_0    = UInt64($0000000000000000);
  F64_NEG0 = UInt64($8000000000000000);
  F64_1    = UInt64($3FF0000000000000);
  F64_2    = UInt64($4000000000000000);
  F64_NEG1 = UInt64($BFF0000000000000);
  F64_INF  = UInt64($7FF0000000000000);
  F64_CANON = UInt64($7FF8000000000000);
  F64_PL   = UInt64($7FF4000000000000);    { a NaN payload }
  F64_1P5  = UInt64($3FF8000000000000);

type
  TInterpVectorTests = class(TTestSuite)
  private
    procedure CheckV(const AGot, AWant: TWasmV128);
  public
    procedure SetupTests; override;

    procedure TestBitwise;
    procedure TestBitselectAnyTrue;
    procedure TestShuffle;
    procedure TestSwizzle;
    procedure TestSplat;
    procedure TestExtractLane;
    procedure TestReplaceLane;

    procedure TestI8x16AddSubNegAbs;
    procedure TestI8x16SatArith;
    procedure TestI8x16MinMaxAvgr;
    procedure TestI8x16Popcnt;
    procedure TestI8x16Shifts;
    procedure TestI8x16Compares;
    procedure TestI8x16BitmaskAllTrue;
    procedure TestNarrow;

    procedure TestI16x8Arith;
    procedure TestI16x8Q15mulr;
    procedure TestI16x8ExtendExtaddExtmul;
    procedure TestI16x8Shifts;

    procedure TestI32x4Arith;
    procedure TestI32x4Dot;
    procedure TestI32x4ExtendExtaddExtmul;
    procedure TestI32x4Compares;
    procedure TestI32x4BitmaskAllTrue;

    procedure TestI64x2Arith;
    procedure TestI64x2Shifts;
    procedure TestI64x2Compares;
    procedure TestI64x2ExtendExtmul;
    procedure TestI64x2BitmaskAllTrue;

    procedure TestF32x4Arith;
    procedure TestF32x4MinMax;
    procedure TestF32x4PminPmax;
    procedure TestF32x4RoundAndNegAbs;
    procedure TestF32x4Compares;

    procedure TestF64x2Arith;
    procedure TestF64x2MinMaxPmin;

    procedure TestConversions;

    procedure TestRelaxedEqualsTwin;
    procedure TestRelaxedMadd;
    procedure TestRelaxedDot;

    procedure TestMemoryLoadStore;
    procedure TestMemoryLoadExtendSplatZero;
    procedure TestMemoryLaneOps;
  end;

procedure TInterpVectorTests.CheckV(const AGot, AWant: TWasmV128);
begin
  Expect<UInt64>(AGot.U64[0]).ToBe(AWant.U64[0]);
  Expect<UInt64>(AGot.U64[1]).ToBe(AWant.U64[1]);
end;

{ --- bitwise --------------------------------------------------------- }

procedure TInterpVectorTests.TestBitwise;
var
  A, B, D: TWasmV128;
begin
  A := VU64([UInt64($F0F0F0F0F0F0F0F0), UInt64($FF00FF00FF00FF00)]);
  B := VU64([UInt64($FFFF0000FFFF0000), UInt64($0F0F0F0F0F0F0F0F)]);

  V128Not(@A, @D);
  CheckV(D, VU64([UInt64($0F0F0F0F0F0F0F0F), UInt64($00FF00FF00FF00FF)]));

  V128And(@A, @B, @D);
  CheckV(D, VU64([UInt64($F0F00000F0F00000), UInt64($0F000F000F000F00)]));

  V128Or(@A, @B, @D);
  CheckV(D, VU64([UInt64($FFFFF0F0FFFFF0F0), UInt64($FF0FFF0FFF0FFF0F)]));

  V128Xor(@A, @B, @D);
  CheckV(D, VU64([UInt64($0F0FF0F00F0FF0F0), UInt64($F00FF00FF00FF00F)]));

  { andnot(a,b) = a and not b. }
  V128Andnot(@A, @B, @D);
  CheckV(D, VU64([UInt64($0000F0F00000F0F0), UInt64($F000F000F000F000)]));
end;

procedure TInterpVectorTests.TestBitselectAnyTrue;
var
  A, B, C, D: TWasmV128;
begin
  { bitselect(i1, i2, mask) = (i1 and mask) or (i2 and not mask). }
  A := VU64([UInt64($AAAAAAAAAAAAAAAA), UInt64($FFFFFFFFFFFFFFFF)]);
  B := VU64([UInt64($5555555555555555), UInt64($0000000000000000)]);
  C := VU64([UInt64($FF00FF00FF00FF00), UInt64($00000000FFFFFFFF)]);
  V128Bitselect(@A, @B, @C, @D);
  CheckV(D, VU64([UInt64($AA55AA55AA55AA55), UInt64($00000000FFFFFFFF)]));

  { any_true is over all 128 bits. }
  Expect<UInt32>(V128AnyTrue(P(VU64([UInt64(0), UInt64(0)])))).ToBe(UInt32(0));
  Expect<UInt32>(V128AnyTrue(P(VU64([UInt64(0), UInt64(1)])))).ToBe(UInt32(1));
  Expect<UInt32>(V128AnyTrue(P(VU8([1])))).ToBe(UInt32(1));
end;

procedure TInterpVectorTests.TestShuffle;
var
  A, B, D: TWasmV128;
  Lanes: array[0..15] of Byte;
  I: Integer;
begin
  A := VU8([10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25]);
  B := VU8([30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45]);
  { Identity of A. }
  for I := 0 to 15 do Lanes[I] := I;
  I8x16Shuffle(@A, @B, @Lanes[0], @D);
  CheckV(D, A);
  { Reversed concat: pick from B (16..31), descending. }
  for I := 0 to 15 do Lanes[I] := 31 - I;
  I8x16Shuffle(@A, @B, @Lanes[0], @D);
  CheckV(D, VU8([45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30]));
  { Mixed: lane 0 from A[0], lane 1 from B[0] (=index 16), etc. }
  for I := 0 to 15 do
    if I mod 2 = 0 then Lanes[I] := I else Lanes[I] := 16 + I;
  I8x16Shuffle(@A, @B, @Lanes[0], @D);
  Expect<Byte>(D.B[0]).ToBe(Byte(10));   { A[0] }
  Expect<Byte>(D.B[1]).ToBe(Byte(31));   { B[1] via index 17 }
end;

procedure TInterpVectorTests.TestSwizzle;
var
  A, B, D: TWasmV128;
begin
  A := VU8([100, 101, 102, 103, 104, 105, 106, 107,
            108, 109, 110, 111, 112, 113, 114, 115]);
  { indices: 0,15 in range; 16 and 200 and -1(=255) out of range -> 0. }
  B := VU8([0, 15, 16, 200, 255, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  I8x16Swizzle(@A, @B, @D);
  CheckV(D, VU8([100, 115, 0, 0, 0, 101, 102, 103,
                 104, 105, 106, 107, 108, 109, 110, 111]));
end;

procedure TInterpVectorTests.TestSplat;
var
  D: TWasmV128;
begin
  I8x16Splat(UInt32($1234AB), @D);   { truncates to low byte $AB }
  CheckV(D, VU8([$AB, $AB, $AB, $AB, $AB, $AB, $AB, $AB,
                 $AB, $AB, $AB, $AB, $AB, $AB, $AB, $AB]));
  I16x8Splat(UInt32($1234ABCD), @D); { -> $ABCD }
  CheckV(D, VU16([$ABCD, $ABCD, $ABCD, $ABCD, $ABCD, $ABCD, $ABCD, $ABCD]));
  I32x4Splat(UInt32($DEADBEEF), @D);
  CheckV(D, VU32([$DEADBEEF, $DEADBEEF, $DEADBEEF, $DEADBEEF]));
  I64x2Splat(UInt64($0123456789ABCDEF), @D);
  CheckV(D, VU64([UInt64($0123456789ABCDEF), UInt64($0123456789ABCDEF)]));
  F32x4Splat(F32_1, @D);
  CheckV(D, VF32([F32_1, F32_1, F32_1, F32_1]));
  F64x2Splat(F64_1, @D);
  CheckV(D, VF64([F64_1, F64_1]));
end;

procedure TInterpVectorTests.TestExtractLane;
var
  A: TWasmV128;
begin
  A := VI8([-1, 2, -128, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  { _s sign-extends to i32; _u zero-extends. }
  Expect<UInt32>(I8x16ExtractLaneS(@A, 0)).ToBe(UInt32($FFFFFFFF));  { -1 }
  Expect<UInt32>(I8x16ExtractLaneU(@A, 0)).ToBe(UInt32($000000FF));  { 255 }
  Expect<UInt32>(I8x16ExtractLaneS(@A, 2)).ToBe(UInt32($FFFFFF80));  { -128 }
  Expect<UInt32>(I8x16ExtractLaneU(@A, 2)).ToBe(UInt32($00000080));

  A := VI16([-1, 32767, 0, 0, 0, 0, 0, 0]);
  Expect<UInt32>(I16x8ExtractLaneS(@A, 0)).ToBe(UInt32($FFFFFFFF));
  Expect<UInt32>(I16x8ExtractLaneU(@A, 0)).ToBe(UInt32($0000FFFF));
  Expect<UInt32>(I16x8ExtractLaneS(@A, 1)).ToBe(UInt32($00007FFF));

  A := VU32([$11111111, $22222222, $33333333, $44444444]);
  Expect<UInt32>(I32x4ExtractLane(@A, 2)).ToBe(UInt32($33333333));
  A := VU64([UInt64($AAAAAAAABBBBBBBB), UInt64($CCCCCCCCDDDDDDDD)]);
  Expect<UInt64>(I64x2ExtractLane(@A, 1)).ToBe(UInt64($CCCCCCCCDDDDDDDD));

  A := VF32([F32_1, F32_2, F32_INF, F32_CANON]);
  Expect<UInt32>(F32x4ExtractLane(@A, 3)).ToBe(F32_CANON);
  A := VF64([F64_1, F64_CANON]);
  Expect<UInt64>(F64x2ExtractLane(@A, 1)).ToBe(F64_CANON);
end;

procedure TInterpVectorTests.TestReplaceLane;
var
  A, D: TWasmV128;
begin
  A := VU8([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16ReplaceLane(@A, 3, UInt32($AABBCCFF), @D);   { low byte $FF }
  Expect<Byte>(D.B[3]).ToBe(Byte($FF));
  Expect<Byte>(D.B[0]).ToBe(Byte(0));
  I16x8ReplaceLane(@A, 2, UInt32($AABBCCDD), @D);    { -> $CCDD }
  Expect<Word>(D.U16[2]).ToBe(Word($CCDD));
  I32x4ReplaceLane(@A, 1, UInt32($DEADBEEF), @D);
  Expect<UInt32>(D.U32[1]).ToBe(UInt32($DEADBEEF));
  I64x2ReplaceLane(@A, 0, UInt64($0123456789ABCDEF), @D);
  Expect<UInt64>(D.U64[0]).ToBe(UInt64($0123456789ABCDEF));
  F32x4ReplaceLane(@A, 3, F32_2, @D);
  Expect<UInt32>(D.U32[3]).ToBe(F32_2);
  F64x2ReplaceLane(@A, 1, F64_CANON, @D);
  Expect<UInt64>(D.U64[1]).ToBe(F64_CANON);
end;

{ --- i8x16 ----------------------------------------------------------- }

procedure TInterpVectorTests.TestI8x16AddSubNegAbs;
var
  A, B, D: TWasmV128;
begin
  A := VU8([200, 1, 255, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VU8([100, 2, 1, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16Add(@A, @B, @D);   { wrap mod 256: 200+100=300->44, 255+1=0 }
  CheckV(D, VU8([44, 3, 0, 0, 200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  I8x16Sub(@A, @B, @D);   { 0-1=255 for lane 3? lane2: 255-1=254; lane3:0-0=0 }
  CheckV(D, VU8([100, 255, 254, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));

  A := VI8([-128, 127, -1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16Neg(@A, @D);       { -(-128)=-128 wrap ($80) }
  CheckV(D, VI8([-128, -127, 1, 0, -5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  I8x16Abs(@A, @D);       { abs(-128) wraps to -128 ($80) }
  CheckV(D, VU8([128, 127, 1, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI8x16SatArith;
var
  A, B, D: TWasmV128;
begin
  { add_sat_s: 127+1 -> 127; -128+-1 -> -128. }
  A := VI8([127, -128, 100, -100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VI8([1, -1, 100, -100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16AddSatS(@A, @B, @D);
  CheckV(D, VI8([127, -128, 127, -128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  { sub_sat_s: -128 - 1 -> -128; 127 - -1 -> 127. }
  A := VI8([-128, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VI8([1, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16SubSatS(@A, @B, @D);
  CheckV(D, VI8([-128, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  { add_sat_u: 200+100 -> 255. sub_sat_u: 10-20 -> 0. }
  A := VU8([200, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VU8([100, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16AddSatU(@A, @B, @D);
  CheckV(D, VU8([255, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  I8x16SubSatU(@A, @B, @D);
  CheckV(D, VU8([100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI8x16MinMaxAvgr;
var
  A, B, D: TWasmV128;
begin
  A := VI8([-1, 5, -128, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VI8([1, 3, 127, -128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16MinS(@A, @B, @D);
  CheckV(D, VI8([-1, 3, -128, -128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  I8x16MaxS(@A, @B, @D);
  CheckV(D, VI8([1, 5, 127, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  { unsigned: -1 reads as 255. }
  { unsigned: A reads [255,5,128,127], B reads [1,3,127,128]. }
  I8x16MinU(@A, @B, @D);
  CheckV(D, VU8([1, 3, 127, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  I8x16MaxU(@A, @B, @D);
  CheckV(D, VU8([255, 5, 128, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  { avgr_u rounds up: (255+0+1)>>1 = 128; (1+2+1)>>1 = 2. }
  A := VU8([255, 1, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VU8([0, 2, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16AvgrU(@A, @B, @D);
  CheckV(D, VU8([128, 2, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI8x16Popcnt;
var
  A, D: TWasmV128;
begin
  A := VU8([$FF, $00, $01, $80, $0F, $AA, $7F, $55,
            0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16Popcnt(@A, @D);
  CheckV(D, VU8([8, 0, 1, 1, 4, 4, 7, 4, 0, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI8x16Shifts;
var
  A, D: TWasmV128;
begin
  A := VU8([$81, $01, $FF, $40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  { count masked mod 8: 9 -> 1. }
  I8x16Shl(@A, 9, @D);
  CheckV(D, VU8([$02, $02, $FE, $80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  { shr_u: logical. }
  I8x16ShrU(@A, 1, @D);
  CheckV(D, VU8([$40, $00, $7F, $20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  { shr_s: arithmetic; $81 (-127) >> 1 = -64 ($C0); $FF (-1) >> 1 = -1 ($FF). }
  I8x16ShrS(@A, 1, @D);
  CheckV(D, VU8([$C0, $00, $FF, $20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI8x16Compares;
var
  A, B, D: TWasmV128;
begin
  A := VI8([1, 2, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VI8([1, 3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I8x16Eq(@A, @B, @D);   { lane0 equal -> $FF, rest 0 }
  CheckV(D, VU8([$FF, 0, 0, $FF, $FF, $FF, $FF, $FF,
                 $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF]));
  I8x16LtS(@A, @B, @D);  { 1<1 no; 2<3 yes; -1<1 yes(signed) }
  CheckV(D, VU8([0, $FF, $FF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  I8x16LtU(@A, @B, @D);  { -1 reads 255, 255<1 no }
  CheckV(D, VU8([0, $FF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  I8x16GtS(@A, @B, @D);
  CheckV(D, VU8([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI8x16BitmaskAllTrue;
var
  A: TWasmV128;
begin
  { bitmask: sign bit of each lane, lane 0 in bit 0. }
  A := VU8([$80, $00, $FF, $7F, $80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $80]);
  Expect<UInt32>(I8x16Bitmask(@A)).ToBe(UInt32($8000 or $0001 or $0004 or $0010));
  { all_true: every lane non-zero. }
  Expect<UInt32>(I8x16AllTrue(P(VU8([1, 1, 1, 1, 1, 1, 1, 1,
                                    1, 1, 1, 1, 1, 1, 1, 1])))).ToBe(UInt32(1));
  Expect<UInt32>(I8x16AllTrue(P(VU8([1, 1, 1, 1, 1, 1, 1, 0,
                                    1, 1, 1, 1, 1, 1, 1, 1])))).ToBe(UInt32(0));
end;

procedure TInterpVectorTests.TestNarrow;
var
  A, B, D: TWasmV128;
begin
  { i8x16.narrow_i16x8_s: A -> lanes 0..7, B -> 8..15; sat to [-128,127]. }
  A := VI16([200, -200, 127, -128, 0, 0, 0, 0]);
  B := VI16([300, -300, 100, -100, 0, 0, 0, 0]);
  I8x16NarrowI16x8S(@A, @B, @D);
  CheckV(D, VI8([127, -128, 127, -128, 0, 0, 0, 0,
                 127, -128, 100, -100, 0, 0, 0, 0]));
  { _u: source read signed, sat to [0,255]; negatives -> 0. }
  I8x16NarrowI16x8U(@A, @B, @D);
  CheckV(D, VU8([200, 0, 127, 0, 0, 0, 0, 0,
                 255, 0, 100, 0, 0, 0, 0, 0]));
  { i16x8.narrow_i32x4_s/u. }
  A := VI32([70000, -70000, 32767, -32768]);
  B := VI32([100000, -100000, 5, -5]);
  I16x8NarrowI32x4S(@A, @B, @D);
  CheckV(D, VI16([32767, -32768, 32767, -32768, 32767, -32768, 5, -5]));
  I16x8NarrowI32x4U(@A, @B, @D);
  CheckV(D, VU16([65535, 0, 32767, 0, 65535, 0, 5, 0]));
end;

{ --- i16x8 ----------------------------------------------------------- }

procedure TInterpVectorTests.TestI16x8Arith;
var
  A, B, D: TWasmV128;
begin
  A := VU16([$FFFF, 2, 100, 0, 0, 0, 0, 0]);
  B := VU16([1, 3, 100, 0, 0, 0, 0, 0]);
  I16x8Add(@A, @B, @D);   { $FFFF+1 wraps to 0 }
  CheckV(D, VU16([0, 5, 200, 0, 0, 0, 0, 0]));
  I16x8Mul(@A, @B, @D);   { $FFFF*1=$FFFF; 2*3=6; 100*100=10000 }
  CheckV(D, VU16([$FFFF, 6, 10000, 0, 0, 0, 0, 0]));
  { sat arith. }
  A := VI16([32767, -32768, 0, 0, 0, 0, 0, 0]);
  B := VI16([1, -1, 0, 0, 0, 0, 0, 0]);
  I16x8AddSatS(@A, @B, @D);
  CheckV(D, VI16([32767, -32768, 0, 0, 0, 0, 0, 0]));
  { avgr_u rounding. }
  A := VU16([65535, 100, 0, 0, 0, 0, 0, 0]);
  B := VU16([0, 101, 0, 0, 0, 0, 0, 0]);
  I16x8AvgrU(@A, @B, @D);
  CheckV(D, VU16([32768, 101, 0, 0, 0, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI16x8Q15mulr;
var
  A, B, D: TWasmV128;
begin
  { q15mulr_sat_s: sat_s16((a*b + 0x4000) >> 15). The only saturating case is
    -32768 * -32768 -> 32767. And 32767*32767 -> 32766. }
  A := VI16([-32768, 32767, 16384, 0, -32768, 1, 0, 0]);
  B := VI16([-32768, 32767, 16384, 100, 32767, 1, 0, 0]);
  I16x8Q15mulrSatS(@A, @B, @D);
  { lane0: (-32768*-32768 + 0x4000)>>15 = 32768 -> sat 32767
    lane1: (32767*32767 + 0x4000)>>15 = 32766
    lane2: (16384*16384 + 0x4000)>>15 = 8192
    lane3: (0*100 + 0x4000)>>15 = 0
    lane4: (-32768*32767 + 0x4000)>>15 = -32767
    lane5: (1*1 + 16384)>>15 = 0 }
  CheckV(D, VI16([32767, 32766, 8192, 0, -32767, 0, 0, 0]));
end;

procedure TInterpVectorTests.TestI16x8ExtendExtaddExtmul;
var
  A, B, D: TWasmV128;
begin
  A := VI8([-1, 2, -128, 127, 1, 2, 3, 4, 10, 20, 30, 40, -50, -60, -70, -80]);
  I16x8ExtendLowI8x16S(@A, @D);
  CheckV(D, VI16([-1, 2, -128, 127, 1, 2, 3, 4]));
  I16x8ExtendHighI8x16S(@A, @D);
  CheckV(D, VI16([10, 20, 30, 40, -50, -60, -70, -80]));
  I16x8ExtendLowI8x16U(@A, @D);
  CheckV(D, VU16([255, 2, 128, 127, 1, 2, 3, 4]));
  { extadd_pairwise_s: adjacent bytes summed. }
  I16x8ExtaddPairwiseI8x16S(@A, @D);
  CheckV(D, VI16([1, -1, 3, 7, 30, 70, -110, -150]));
  { extmul_low_s: sext8(a)*sext8(b). }
  B := VI8([2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0]);
  I16x8ExtmulLowI8x16S(@A, @B, @D);
  CheckV(D, VI16([-2, 4, -256, 254, 2, 4, 6, 8]));
end;

procedure TInterpVectorTests.TestI16x8Shifts;
var
  A, D: TWasmV128;
begin
  A := VU16([$8001, $0001, $FFFF, $4000, 0, 0, 0, 0]);
  I16x8Shl(@A, 17, @D);   { mask mod 16 -> 1 }
  CheckV(D, VU16([$0002, $0002, $FFFE, $8000, 0, 0, 0, 0]));
  I16x8ShrU(@A, 1, @D);
  CheckV(D, VU16([$4000, $0000, $7FFF, $2000, 0, 0, 0, 0]));
  I16x8ShrS(@A, 1, @D);   { $8001 = -32767 -> $C000; $FFFF -> $FFFF }
  CheckV(D, VU16([$C000, $0000, $FFFF, $2000, 0, 0, 0, 0]));
end;

{ --- i32x4 ----------------------------------------------------------- }

procedure TInterpVectorTests.TestI32x4Arith;
var
  A, B, D: TWasmV128;
begin
  A := VU32([$FFFFFFFF, 2, 100, $80000000]);
  B := VU32([1, 3, 100, 1]);
  I32x4Add(@A, @B, @D);
  CheckV(D, VU32([0, 5, 200, $80000001]));
  I32x4Mul(@A, @B, @D);   { $FFFFFFFF*1; 100*100=10000 }
  CheckV(D, VU32([$FFFFFFFF, 6, 10000, $80000000]));
  A := VI32([-1, 5, -2147483648, 100]);
  B := VI32([1, 3, 0, -100]);
  I32x4MinS(@A, @B, @D);
  CheckV(D, VI32([-1, 3, -2147483648, -100]));
  I32x4MaxU(@A, @B, @D);  { -1 reads as 4294967295 }
  CheckV(D, VU32([$FFFFFFFF, 5, $80000000, $FFFFFF9C]));
  I32x4Neg(P(VI32([-2147483648, 1, 0, 0])), @D);  { -(-2^31)=-2^31 }
  CheckV(D, VU32([$80000000, $FFFFFFFF, 0, 0]));
end;

procedure TInterpVectorTests.TestI32x4Dot;
var
  A, B, D: TWasmV128;
begin
  { dot_i16x8_s: a[2i]*b[2i] + a[2i+1]*b[2i+1] in i32. }
  A := VI16([1, 2, 3, 4, -1, -2, 32767, 32767]);
  B := VI16([5, 6, 7, 8, 1, 1, 32767, 32767]);
  I32x4DotI16x8S(@A, @B, @D);
  { lane0: 1*5+2*6=17; lane1: 3*7+4*8=53; lane2: -1*1+-2*1=-3;
    lane3: 32767*32767*2 = 2147352578 }
  CheckV(D, VI32([17, 53, -3, 2147352578]));
end;

procedure TInterpVectorTests.TestI32x4ExtendExtaddExtmul;
var
  A, B, D: TWasmV128;
begin
  A := VI16([-1, 2, -32768, 32767, 10, 20, -30, -40]);
  I32x4ExtendLowI16x8S(@A, @D);
  CheckV(D, VI32([-1, 2, -32768, 32767]));
  I32x4ExtendHighI16x8U(@A, @D);
  CheckV(D, VU32([10, 20, 65506, 65496]));   { -30 -> 65506, -40 -> 65496 }
  I32x4ExtaddPairwiseI16x8S(@A, @D);
  CheckV(D, VI32([1, -1, 30, -70]));
  B := VI16([2, 2, 2, 2, 0, 0, 0, 0]);
  I32x4ExtmulLowI16x8S(@A, @B, @D);
  CheckV(D, VI32([-2, 4, -65536, 65534]));
end;

procedure TInterpVectorTests.TestI32x4Compares;
var
  A, B, D: TWasmV128;
begin
  A := VI32([-1, 2, 3, 100]);
  B := VI32([1, 2, 1, -100]);
  I32x4LtS(@A, @B, @D);
  CheckV(D, VU32([$FFFFFFFF, 0, 0, 0]));
  { LtU: lane0 -1 reads $FFFFFFFF (not < 1); lane3 100 < 4294967196 (-100). }
  I32x4LtU(@A, @B, @D);
  CheckV(D, VU32([0, 0, 0, $FFFFFFFF]));
  I32x4GeS(@A, @B, @D);
  CheckV(D, VU32([0, $FFFFFFFF, $FFFFFFFF, $FFFFFFFF]));
end;

procedure TInterpVectorTests.TestI32x4BitmaskAllTrue;
var
  A: TWasmV128;
begin
  A := VU32([$80000000, $7FFFFFFF, $FFFFFFFF, $00000000]);
  Expect<UInt32>(I32x4Bitmask(@A)).ToBe(UInt32($01 or $04));
  Expect<UInt32>(I32x4AllTrue(P(VU32([1, 2, 3, 4])))).ToBe(UInt32(1));
  Expect<UInt32>(I32x4AllTrue(P(VU32([1, 0, 3, 4])))).ToBe(UInt32(0));
end;

{ --- i64x2 ----------------------------------------------------------- }

procedure TInterpVectorTests.TestI64x2Arith;
var
  A, B, D: TWasmV128;
begin
  A := VU64([UInt64($FFFFFFFFFFFFFFFF), 5]);
  B := VU64([1, 3]);
  I64x2Add(@A, @B, @D);
  CheckV(D, VU64([0, 8]));
  I64x2Mul(@A, @B, @D);
  CheckV(D, VU64([UInt64($FFFFFFFFFFFFFFFF), 15]));
  I64x2Sub(P(VU64([0, 10])), P(VU64([1, 3])), @D);
  CheckV(D, VU64([UInt64($FFFFFFFFFFFFFFFF), 7]));
  I64x2Neg(P(VI64([Low(Int64), 1])), @D);   { -(INT64_MIN)=INT64_MIN }
  CheckV(D, VU64([UInt64($8000000000000000), UInt64($FFFFFFFFFFFFFFFF)]));
  I64x2Abs(P(VI64([-5, Low(Int64)])), @D);
  CheckV(D, VU64([5, UInt64($8000000000000000)]));
end;

procedure TInterpVectorTests.TestI64x2Shifts;
var
  A, D: TWasmV128;
begin
  A := VU64([UInt64($8000000000000001), UInt64($4000000000000000)]);
  I64x2Shl(@A, 65, @D);   { mask mod 64 -> 1 }
  CheckV(D, VU64([UInt64($0000000000000002), UInt64($8000000000000000)]));
  I64x2ShrU(@A, 1, @D);
  CheckV(D, VU64([UInt64($4000000000000000), UInt64($2000000000000000)]));
  I64x2ShrS(@A, 1, @D);   { top lane bit set -> arithmetic fill }
  CheckV(D, VU64([UInt64($C000000000000000), UInt64($2000000000000000)]));
end;

procedure TInterpVectorTests.TestI64x2Compares;
var
  A, B, D: TWasmV128;
begin
  A := VI64([-1, 5]);
  B := VI64([1, 5]);
  I64x2Eq(@A, @B, @D);
  CheckV(D, VU64([0, UInt64($FFFFFFFFFFFFFFFF)]));
  I64x2LtS(@A, @B, @D);   { -1 < 1 signed -> true }
  CheckV(D, VU64([UInt64($FFFFFFFFFFFFFFFF), 0]));
  I64x2GeS(@A, @B, @D);
  CheckV(D, VU64([0, UInt64($FFFFFFFFFFFFFFFF)]));
end;

procedure TInterpVectorTests.TestI64x2ExtendExtmul;
var
  A, B, D: TWasmV128;
begin
  A := VI32([-1, 2, -2147483648, 2147483647]);
  I64x2ExtendLowI32x4S(@A, @D);
  CheckV(D, VI64([-1, 2]));
  I64x2ExtendHighI32x4U(@A, @D);
  CheckV(D, VU64([UInt64($80000000), UInt64($7FFFFFFF)]));
  B := VI32([3, 3, 0, 0]);
  I64x2ExtmulLowI32x4S(@A, @B, @D);
  CheckV(D, VI64([-3, 6]));
  I64x2ExtmulHighI32x4U(@A, @B, @D);
  CheckV(D, VU64([0, 0]));
end;

procedure TInterpVectorTests.TestI64x2BitmaskAllTrue;
var
  A: TWasmV128;
begin
  A := VU64([UInt64($8000000000000000), UInt64($0000000000000001)]);
  Expect<UInt32>(I64x2Bitmask(@A)).ToBe(UInt32(1));
  A := VU64([UInt64($0000000000000001), UInt64($8000000000000000)]);
  Expect<UInt32>(I64x2Bitmask(@A)).ToBe(UInt32(2));
  Expect<UInt32>(I64x2AllTrue(P(VU64([1, 1])))).ToBe(UInt32(1));
  Expect<UInt32>(I64x2AllTrue(P(VU64([1, 0])))).ToBe(UInt32(0));
end;

{ --- f32x4 ----------------------------------------------------------- }

procedure TInterpVectorTests.TestF32x4Arith;
var
  A, B, D: TWasmV128;
begin
  A := VF32([F32_1, F32_2, F32_1, F32_INF]);
  B := VF32([F32_1, F32_2, F32_CANON, F32_INF]);
  F32x4Add(@A, @B, @D);   { 1+1=2; 2+2=4; 1+NaN->canonical; inf+inf=inf }
  CheckV(D, VF32([F32_2, UInt32($40800000), F32_CANON, F32_INF]));
  { inf - inf -> canonical NaN. }
  F32x4Sub(P(VF32([F32_INF, F32_2, 0, 0])), P(VF32([F32_INF, F32_1, 0, 0])), @D);
  CheckV(D, VF32([F32_CANON, F32_1, F32_0, F32_0]));
  { div by zero -> inf (no trap). }
  F32x4Div(P(VF32([F32_1, 0, 0, 0])), P(VF32([F32_0, F32_0, F32_1, F32_1])), @D);
  Expect<UInt32>(D.U32[0]).ToBe(F32_INF);
end;

procedure TInterpVectorTests.TestF32x4MinMax;
var
  D: TWasmV128;
begin
  { min(+0,-0) = -0; max(+0,-0) = +0. }
  F32x4Min(P(VF32([F32_0, F32_NEG0, F32_1, F32_2])),
           P(VF32([F32_NEG0, F32_0, F32_2, F32_1])), @D);
  CheckV(D, VF32([F32_NEG0, F32_NEG0, F32_1, F32_1]));
  F32x4Max(P(VF32([F32_0, F32_NEG0, F32_1, F32_2])),
           P(VF32([F32_NEG0, F32_0, F32_2, F32_1])), @D);
  CheckV(D, VF32([F32_0, F32_0, F32_2, F32_2]));
  { any NaN operand -> canonical NaN. }
  F32x4Min(P(VF32([F32_PL, F32_1, F32_1, F32_1])),
           P(VF32([F32_1, F32_1, F32_1, F32_1])), @D);
  Expect<UInt32>(D.U32[0]).ToBe(F32_CANON);
end;

procedure TInterpVectorTests.TestF32x4PminPmax;
var
  D: TWasmV128;
begin
  { pmin(z1,z2) = if z2<z1 then z2 else z1 — a selection, exact bits. }
  F32x4Pmin(P(VF32([F32_1, F32_2, F32_NEG0, F32_0])),
            P(VF32([F32_2, F32_1, F32_0, F32_NEG0])), @D);
  { lane0: 2<1? no -> z1=1; lane1: 1<2? yes -> z2=1;
    lane2: +0 < -0? no -> z1=-0; lane3: -0 < +0? no -> z1=+0 }
  CheckV(D, VF32([F32_1, F32_1, F32_NEG0, F32_0]));
  { pmin with NaN: comparison false -> returns z1 EXACT bits (payload kept). }
  F32x4Pmin(P(VF32([F32_CANON, F32_PL, F32_NPL, F32_1])),
            P(VF32([F32_PL, F32_1, F32_1, F32_NPL])), @D);
  { lane0: z2<z1 false -> z1=canonical; lane1: 1<pl? NaN cmp false -> z1=pl;
    lane2: 1 < -nan:pl? false -> z1=-nan:pl (sign+payload preserved);
    lane3: -nan:pl < 1? false -> z1=1 }
  CheckV(D, VF32([F32_CANON, F32_PL, F32_NPL, F32_1]));
  { pmax(z1,z2) = if z1<z2 then z2 else z1. }
  F32x4Pmax(P(VF32([F32_1, F32_2, F32_CANON, F32_1])),
            P(VF32([F32_2, F32_1, F32_1, F32_CANON])), @D);
  { lane0: 1<2 -> z2=2; lane1: 2<1? no -> z1=2; lane2: NaN cmp false -> z1;
    lane3: 1<NaN false -> z1=1 }
  CheckV(D, VF32([F32_2, F32_2, F32_CANON, F32_1]));
end;

procedure TInterpVectorTests.TestF32x4RoundAndNegAbs;
var
  D: TWasmV128;
begin
  { ceil/floor/trunc/nearest, and nearest ties-to-even. }
  F32x4Ceil(P(VF32([F32_1P5, F32_N1P5, F32_0, F32_INF])), @D);
  CheckV(D, VF32([F32_2, F32_NEG1, F32_0, F32_INF]));
  F32x4Floor(P(VF32([F32_1P5, F32_N1P5, 0, 0])), @D);
  CheckV(D, VF32([F32_1, UInt32($C0000000), F32_0, F32_0]));  { -2.0 }
  F32x4Trunc(P(VF32([F32_1P5, F32_N1P5, 0, 0])), @D);
  CheckV(D, VF32([F32_1, F32_NEG1, F32_0, F32_0]));
  { nearest 1.5 -> 2 (even), 0.5 -> 0 (even), 2.5 -> 2 (even). }
  F32x4Nearest(P(VF32([F32_1P5, UInt32($3F000000), UInt32($40200000), 0])), @D);
  CheckV(D, VF32([F32_2, F32_0, F32_2, F32_0]));
  { neg/abs are sign-bit ops preserving NaN payload. }
  F32x4Neg(P(VF32([F32_1, F32_PL, F32_NEG0, F32_INF])), @D);
  CheckV(D, VF32([F32_NEG1, F32_NPL, F32_0, F32_NINF]));
  F32x4Abs(P(VF32([F32_NEG1, F32_NPL, F32_NEG0, F32_NINF])), @D);
  CheckV(D, VF32([F32_1, F32_PL, F32_0, F32_INF]));
end;

procedure TInterpVectorTests.TestF32x4Compares;
var
  D: TWasmV128;
begin
  { NaN compares unordered: eq/lt/... false, ne true. }
  F32x4Eq(P(VF32([F32_1, F32_CANON, F32_0, F32_NEG0])),
          P(VF32([F32_1, F32_1, F32_NEG0, F32_0])), @D);
  CheckV(D, VU32([$FFFFFFFF, 0, $FFFFFFFF, $FFFFFFFF]));  { +0 == -0 }
  F32x4Ne(P(VF32([F32_1, F32_CANON, 0, 0])),
          P(VF32([F32_1, F32_1, 0, 0])), @D);
  CheckV(D, VU32([0, $FFFFFFFF, 0, 0]));
  F32x4Lt(P(VF32([F32_1, F32_2, F32_CANON, 0])),
          P(VF32([F32_2, F32_1, F32_1, 0])), @D);
  CheckV(D, VU32([$FFFFFFFF, 0, 0, 0]));
end;

{ --- f64x2 ----------------------------------------------------------- }

procedure TInterpVectorTests.TestF64x2Arith;
var
  D: TWasmV128;
begin
  F64x2Add(P(VF64([F64_1, F64_1])), P(VF64([F64_1, F64_CANON])), @D);
  CheckV(D, VF64([F64_2, F64_CANON]));   { 1+1=2; 1+NaN->canonical }
  F64x2Mul(P(VF64([F64_2, F64_INF])), P(VF64([F64_2, F64_0])), @D);
  { inf*0 -> canonical NaN. }
  CheckV(D, VF64([UInt64($4010000000000000), F64_CANON]));  { 4.0 }
  F64x2Sqrt(P(VF64([UInt64($4010000000000000), F64_NEG1])), @D);
  { sqrt(4)=2; sqrt(-1)->canonical NaN. }
  CheckV(D, VF64([F64_2, F64_CANON]));
end;

procedure TInterpVectorTests.TestF64x2MinMaxPmin;
var
  D: TWasmV128;
begin
  F64x2Min(P(VF64([F64_0, F64_1])), P(VF64([F64_NEG0, F64_2])), @D);
  CheckV(D, VF64([F64_NEG0, F64_1]));
  F64x2Max(P(VF64([F64_0, F64_1])), P(VF64([F64_NEG0, F64_2])), @D);
  CheckV(D, VF64([F64_0, F64_2]));
  { pmin exact bits + NaN payload from z1. }
  F64x2Pmin(P(VF64([F64_1, F64_PL])), P(VF64([F64_2, F64_1])), @D);
  CheckV(D, VF64([F64_1, F64_PL]));
  F64x2Pmax(P(VF64([F64_1, F64_2])), P(VF64([F64_2, F64_1])), @D);
  CheckV(D, VF64([F64_2, F64_2]));
end;

{ --- conversions ----------------------------------------------------- }

procedure TInterpVectorTests.TestConversions;
var
  D: TWasmV128;
begin
  { f32x4.convert_i32x4_s/u. }
  F32x4ConvertI32x4S(P(VI32([-1, 0, 1, 2147483647])), @D);
  Expect<UInt32>(D.U32[0]).ToBe(F32_NEG1);
  Expect<UInt32>(D.U32[2]).ToBe(F32_1);
  F32x4ConvertI32x4U(P(VU32([$FFFFFFFF, 0, 1, 0])), @D);
  Expect<UInt32>(D.U32[2]).ToBe(F32_1);
  { f64x2.convert_low_i32x4_s: only lanes 0,1. }
  F64x2ConvertLowI32x4S(P(VI32([-1, 2, 999, 999])), @D);
  CheckV(D, VF64([F64_NEG1, F64_2]));
  { trunc_sat_f32x4_s: NaN->0, 1.5->1, -1.5->-1, +inf-> INT32_MAX. }
  I32x4TruncSatF32x4S(P(VF32([F32_CANON, F32_1P5, F32_N1P5, F32_INF])), @D);
  CheckV(D, VU32([0, 1, UInt32($FFFFFFFF), UInt32($7FFFFFFF)]));
  { trunc_sat_f32x4_u: -1.5 -> 0, +inf -> UINT32_MAX. }
  I32x4TruncSatF32x4U(P(VF32([F32_N1P5, F32_1P5, F32_INF, F32_CANON])), @D);
  CheckV(D, VU32([0, 1, UInt32($FFFFFFFF), 0]));
  { _zero forms: lanes 2,3 zeroed. }
  I32x4TruncSatF64x2SZero(P(VF64([F64_1P5, F64_NEG1])), @D);
  CheckV(D, VU32([1, UInt32($FFFFFFFF), 0, 0]));
  { demote_zero: lanes 2,3 zeroed. }
  F32x4DemoteF64x2Zero(P(VF64([F64_1, F64_2])), @D);
  CheckV(D, VF32([F32_1, F32_2, F32_0, F32_0]));
  { promote_low: lanes 0,1 widened. }
  F64x2PromoteLowF32x4(P(VF32([F32_1, F32_2, F32_INF, F32_INF])), @D);
  CheckV(D, VF64([F64_1, F64_2]));
end;

{ --- relaxed SIMD ---------------------------------------------------- }

procedure TInterpVectorTests.TestRelaxedEqualsTwin;
var
  A, B, C, D, T: TWasmV128;
begin
  { Each relaxed op equals its non-relaxed twin at R = 0. }
  A := VU8([100, 101, 102, 103, 104, 105, 106, 107,
            108, 109, 110, 111, 112, 113, 114, 115]);
  B := VU8([0, 15, 16, 200, 255, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  I8x16RelaxedSwizzle(@A, @B, @D);
  I8x16Swizzle(@A, @B, @T);
  CheckV(D, T);

  A := VF32([F32_1P5, F32_N1P5, F32_INF, F32_CANON]);
  I32x4RelaxedTruncF32x4S(@A, @D);
  I32x4TruncSatF32x4S(@A, @T);
  CheckV(D, T);
  I32x4RelaxedTruncF32x4U(@A, @D);
  I32x4TruncSatF32x4U(@A, @T);
  CheckV(D, T);

  { relaxed f64x2 trunc has no _zero suffix but zeroes lanes 2,3. }
  I32x4RelaxedTruncF64x2S(P(VF64([F64_1P5, F64_NEG1])), @D);
  I32x4TruncSatF64x2SZero(P(VF64([F64_1P5, F64_NEG1])), @T);
  CheckV(D, T);
  Expect<UInt32>(D.U32[2]).ToBe(UInt32(0));
  Expect<UInt32>(D.U32[3]).ToBe(UInt32(0));

  { relaxed_min/max == fmin/fmax (NaN -> canonical). }
  A := VF32([F32_PL, F32_1, F32_0, F32_NEG0]);
  B := VF32([F32_1, F32_2, F32_NEG0, F32_0]);
  F32x4RelaxedMin(@A, @B, @D);
  F32x4Min(@A, @B, @T);
  CheckV(D, T);

  { relaxed_laneselect == bitselect (mask bit-wise). }
  A := VU64([UInt64($AAAAAAAAAAAAAAAA), UInt64($FFFFFFFFFFFFFFFF)]);
  B := VU64([UInt64($5555555555555555), UInt64(0)]);
  C := VU64([UInt64($FF00FF00FF00FF00), UInt64($00000000FFFFFFFF)]);
  I8x16RelaxedLaneselect(@A, @B, @C, @D);
  V128Bitselect(@A, @B, @C, @T);
  CheckV(D, T);

  { relaxed_q15mulr == q15mulr_sat_s. }
  A := VI16([-32768, 32767, 0, 0, 0, 0, 0, 0]);
  B := VI16([-32768, 32767, 0, 0, 0, 0, 0, 0]);
  I16x8RelaxedQ15mulrS(@A, @B, @D);
  I16x8Q15mulrSatS(@A, @B, @T);
  CheckV(D, T);
end;

procedure TInterpVectorTests.TestRelaxedMadd;
var
  D: TWasmV128;
begin
  { R = 0: unfused fadd(fmul(a,b), c). 2*3+1 = 7. }
  F32x4RelaxedMadd(P(VF32([F32_2, F32_1, 0, 0])),
                   P(VF32([UInt32($40400000), F32_1, 0, 0])),  { 3.0, 1.0 }
                   P(VF32([F32_1, F32_1, 0, 0])), @D);
  CheckV(D, VF32([UInt32($40E00000), F32_2, F32_0, F32_0]));  { 7.0, 2.0 }
  { nmadd: fadd(fmul(-a,b), c). -(2*3)+1 = -5. }
  F32x4RelaxedNmadd(P(VF32([F32_2, 0, 0, 0])),
                    P(VF32([UInt32($40400000), 0, 0, 0])),
                    P(VF32([F32_1, 0, 0, 0])), @D);
  Expect<UInt32>(D.U32[0]).ToBe(UInt32($C0A00000));  { -5.0 }
  { f64x2 madd. }
  F64x2RelaxedMadd(P(VF64([F64_2, 0])), P(VF64([F64_2, 0])), P(VF64([F64_1, 0])), @D);
  Expect<UInt64>(D.U64[0]).ToBe(UInt64($4014000000000000));  { 5.0 }
end;

procedure TInterpVectorTests.TestRelaxedDot;
var
  A, B, C, D: TWasmV128;
begin
  { relaxed_dot_product.wast: a=b=[0..15] -> [1,13,41,85,145,221,313,421]. }
  A := VI8([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
  B := VI8([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
  I16x8RelaxedDotI8x16I7x16S(@A, @B, @D);
  CheckV(D, VI16([1, 13, 41, 85, 145, 221, 313, 421]));

  { max/min i8 case (exact, not `either`): [-128,-128,127,127,0..]·[127,127,127,127,0..]
    -> [-32512, 32258, 0, 0, 0, 0, 0, 0]. }
  A := VI8([-128, -128, 127, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VI8([127, 127, 127, 127, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  I16x8RelaxedDotI8x16I7x16S(@A, @B, @D);
  CheckV(D, VI16([-32512, 32258, 0, 0, 0, 0, 0, 0]));

  { add variant: a=b=[0..15], c=[0,1,2,3] -> intermediate [14,126,366,734]
    then + c -> [14,127,368,737]. }
  A := VI8([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
  B := VI8([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
  C := VI32([0, 1, 2, 3]);
  I32x4RelaxedDotI8x16I7x16AddS(@A, @B, @C, @D);
  CheckV(D, VI32([14, 127, 368, 737]));

  { add variant max/min: intermediate [-65024, 64516, 0, 0], + c[1,2,3,4]. }
  A := VI8([-128, -128, -128, -128, 127, 127, 127, 127, 0, 0, 0, 0, 0, 0, 0, 0]);
  B := VI8([127, 127, 127, 127, 127, 127, 127, 127, 0, 0, 0, 0, 0, 0, 0, 0]);
  C := VI32([1, 2, 3, 4]);
  I32x4RelaxedDotI8x16I7x16AddS(@A, @B, @C, @D);
  CheckV(D, VI32([-65023, 64518, 3, 4]));
end;

{ --- memory lane transforms ------------------------------------------ }

procedure TInterpVectorTests.TestMemoryLoadStore;
var
  Src: array[0..15] of Byte;
  Dst: array[0..15] of Byte;
  D: TWasmV128;
  A: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Src[I] := I + 1;
  V128Load(@Src[0], @D);
  CheckV(D, VU8([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]));
  A := VU8([$10, $20, $30, $40, $50, $60, $70, $80,
            $90, $A0, $B0, $C0, $D0, $E0, $F0, $FF]);
  FillChar(Dst, SizeOf(Dst), 0);
  V128Store(@A, @Dst[0]);
  for I := 0 to 15 do Expect<Byte>(Dst[I]).ToBe(A.B[I]);
end;

procedure TInterpVectorTests.TestMemoryLoadExtendSplatZero;
var
  Src: array[0..15] of Byte;
  D: TWasmV128;
begin
  { load8x8_s: 8 signed bytes -> 8 i16 lanes. }
  Src[0] := $FF; Src[1] := $01; Src[2] := $80; Src[3] := $7F;
  Src[4] := 0; Src[5] := 0; Src[6] := 0; Src[7] := 0;
  V128Load8x8S(@Src[0], @D);
  CheckV(D, VI16([-1, 1, -128, 127, 0, 0, 0, 0]));
  V128Load8x8U(@Src[0], @D);
  CheckV(D, VU16([255, 1, 128, 127, 0, 0, 0, 0]));

  { load16x4_s: little-endian words. $FFFF -> -1, $0001 -> 1. }
  Src[0] := $FF; Src[1] := $FF; Src[2] := $01; Src[3] := $00;
  Src[4] := $00; Src[5] := $80; Src[6] := $FF; Src[7] := $7F;
  V128Load16x4S(@Src[0], @D);
  CheckV(D, VI32([-1, 1, -32768, 32767]));

  { load32x2_s. }
  Src[0] := $FF; Src[1] := $FF; Src[2] := $FF; Src[3] := $FF;
  Src[4] := $01; Src[5] := $00; Src[6] := $00; Src[7] := $00;
  V128Load32x2S(@Src[0], @D);
  CheckV(D, VI64([-1, 1]));

  { load8_splat. }
  Src[0] := $AB;
  V128Load8Splat(@Src[0], @D);
  CheckV(D, VU8([$AB, $AB, $AB, $AB, $AB, $AB, $AB, $AB,
                 $AB, $AB, $AB, $AB, $AB, $AB, $AB, $AB]));
  { load32_splat little-endian. }
  Src[0] := $EF; Src[1] := $BE; Src[2] := $AD; Src[3] := $DE;
  V128Load32Splat(@Src[0], @D);
  CheckV(D, VU32([$DEADBEEF, $DEADBEEF, $DEADBEEF, $DEADBEEF]));
  { load32_zero: lane 0 set, rest zero. }
  V128Load32Zero(@Src[0], @D);
  CheckV(D, VU32([$DEADBEEF, 0, 0, 0]));
  { load64_zero. }
  Src[4] := $01; Src[5] := $02; Src[6] := $03; Src[7] := $04;
  V128Load64Zero(@Src[0], @D);
  CheckV(D, VU64([UInt64($04030201DEADBEEF), 0]));
end;

procedure TInterpVectorTests.TestMemoryLaneOps;
var
  Src: array[0..7] of Byte;
  Dst: array[0..7] of Byte;
  Old, D, A: TWasmV128;
begin
  Old := VU32([$11111111, $22222222, $33333333, $44444444]);
  Src[0] := $AA; Src[1] := $BB; Src[2] := $CC; Src[3] := $DD;
  { load32_lane into lane 2 overwrites, keeps the rest. }
  V128Load32Lane(@Src[0], @Old, 2, @D);
  CheckV(D, VU32([$11111111, $22222222, $DDCCBBAA, $44444444]));
  { load8_lane into lane 5. }
  V128Load8Lane(@Src[0], @Old, 5, @D);
  Expect<Byte>(D.B[5]).ToBe(Byte($AA));
  Expect<UInt32>(D.U32[0]).ToBe(UInt32($11111111));
  { load64_lane into lane 1. }
  Src[4] := $01; Src[5] := $02; Src[6] := $03; Src[7] := $04;
  V128Load64Lane(@Src[0], @Old, 1, @D);
  Expect<UInt64>(D.U64[1]).ToBe(UInt64($04030201DDCCBBAA));
  Expect<UInt64>(D.U64[0]).ToBe(UInt64($2222222211111111));

  { store lane: little-endian bytes. }
  A := VU32([$DEADBEEF, $CAFEBABE, $12345678, $9ABCDEF0]);
  FillChar(Dst, SizeOf(Dst), 0);
  V128Store32Lane(@A, 1, @Dst[0]);   { lane 1 = $CAFEBABE }
  Expect<Byte>(Dst[0]).ToBe(Byte($BE));
  Expect<Byte>(Dst[1]).ToBe(Byte($BA));
  Expect<Byte>(Dst[2]).ToBe(Byte($FE));
  Expect<Byte>(Dst[3]).ToBe(Byte($CA));
  FillChar(Dst, SizeOf(Dst), 0);
  V128Store16Lane(@A, 0, @Dst[0]);   { low word of lane 0 = $BEEF }
  Expect<Byte>(Dst[0]).ToBe(Byte($EF));
  Expect<Byte>(Dst[1]).ToBe(Byte($BE));
  FillChar(Dst, SizeOf(Dst), 0);
  { byte lane 4 = first byte of U32[1]=$CAFEBABE little-endian = $BE. }
  V128Store8Lane(@A, 4, @Dst[0]);
  Expect<Byte>(Dst[0]).ToBe(Byte($BE));
end;

procedure TInterpVectorTests.SetupTests;
begin
  Test('v128 not/and/or/xor/andnot', TestBitwise);
  Test('v128 bitselect and any_true over all bits', TestBitselectAnyTrue);
  Test('i8x16 shuffle lane selection from 32-byte concat', TestShuffle);
  Test('i8x16 swizzle with out-of-range index -> 0', TestSwizzle);
  Test('splat replicates and truncates the scalar', TestSplat);
  Test('extract_lane signed/unsigned extension', TestExtractLane);
  Test('replace_lane overwrites one lane', TestReplaceLane);

  Test('i8x16 add/sub wrap, neg/abs INT_MIN', TestI8x16AddSubNegAbs);
  Test('i8x16 saturating add/sub boundaries', TestI8x16SatArith);
  Test('i8x16 min/max signed+unsigned and avgr rounding', TestI8x16MinMaxAvgr);
  Test('i8x16 popcnt per byte', TestI8x16Popcnt);
  Test('i8x16 shifts with masked counts and arithmetic shr', TestI8x16Shifts);
  Test('i8x16 comparisons yield all-ones/all-zero lanes', TestI8x16Compares);
  Test('i8x16 bitmask and all_true', TestI8x16BitmaskAllTrue);
  Test('narrow saturates signed and unsigned', TestNarrow);

  Test('i16x8 add/mul/sat/avgr', TestI16x8Arith);
  Test('i16x8 q15mulr_sat_s including the -32768^2 case', TestI16x8Q15mulr);
  Test('i16x8 extend/extadd_pairwise/extmul', TestI16x8ExtendExtaddExtmul);
  Test('i16x8 shifts with masked counts', TestI16x8Shifts);

  Test('i32x4 add/mul/min/max/neg', TestI32x4Arith);
  Test('i32x4 dot_i16x8_s pairwise', TestI32x4Dot);
  Test('i32x4 extend/extadd/extmul', TestI32x4ExtendExtaddExtmul);
  Test('i32x4 comparisons', TestI32x4Compares);
  Test('i32x4 bitmask and all_true', TestI32x4BitmaskAllTrue);

  Test('i64x2 add/sub/mul/neg/abs', TestI64x2Arith);
  Test('i64x2 shifts with masked counts', TestI64x2Shifts);
  Test('i64x2 signed comparisons', TestI64x2Compares);
  Test('i64x2 extend/extmul', TestI64x2ExtendExtmul);
  Test('i64x2 bitmask and all_true', TestI64x2BitmaskAllTrue);

  Test('f32x4 arith with per-lane NaN canonicalization', TestF32x4Arith);
  Test('f32x4 min/max sign-of-zero and NaN', TestF32x4MinMax);
  Test('f32x4 pmin/pmax select exact operand bits', TestF32x4PminPmax);
  Test('f32x4 rounding and neg/abs payload preservation', TestF32x4RoundAndNegAbs);
  Test('f32x4 comparisons with unordered NaN', TestF32x4Compares);

  Test('f64x2 arith with NaN canonicalization', TestF64x2Arith);
  Test('f64x2 min/max and pmin/pmax', TestF64x2MinMaxPmin);

  Test('conversions: convert/trunc_sat/_zero/demote/promote', TestConversions);

  Test('every relaxed op equals its non-relaxed twin', TestRelaxedEqualsTwin);
  Test('relaxed madd/nmadd are unfused', TestRelaxedMadd);
  Test('relaxed dot products against the corpus values', TestRelaxedDot);

  Test('memory v128.load/store byte transforms', TestMemoryLoadStore);
  Test('memory load extend/splat/zero transforms', TestMemoryLoadExtendSplatZero);
  Test('memory load_lane/store_lane transforms', TestMemoryLaneOps);
end;

{$POP}

begin
  TestRunnerProgram.AddSuite(TInterpVectorTests.Create('Wasm.Interp.Vector'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
