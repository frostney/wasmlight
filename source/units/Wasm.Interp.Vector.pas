{ Wasm.Interp.Vector — pure leaf procedures for every v128 (SIMD) operation
  the register IR emits (Track G). The exact analogue of Wasm.Interp.Numeric:
  no store, no IR, no frames — each routine maps one wasm vector operator to a
  bit-exact result on TWasmV128, so the whole unit is testable in isolation
  with literal 16-byte vectors.

  Operands and destinations are the 16-byte TWasmV128 views onto register
  pairs (Wasm.Core §1.3). Lane order is little-endian WITHIN the vector: lane i
  of a shape t x N occupies bytes [i*w, (i+1)*w), exactly the 16 literal bytes
  of a binary v128.const immediate. Every leaf reads its operands into locals
  before writing the destination, so a Dest that aliases a source is safe even
  though the IR always allocates a fresh temporary.

  Scalar-returning leaves (bitmask, all_true, any_true, extract_lane) return
  the raw i32/i64 bit pattern, matching Wasm.Interp.Numeric's raw-bits
  contract; splat/replace_lane take the scalar as raw bits.

  The load rules that are load-bearing here, each cited at its family:

  - Integer arithmetic wraps modulo the lane width (exec-vbinop maps each lane
    to the generic wrapping operator); Shared.inc turns overflow/range checks
    ON outside PRODUCTION, so the whole implementation pushes them OFF.
  - Saturating ops compute in a wider signed/unsigned type and clamp to the
    lane range (exec-vbinop, exec-vnarrow).
  - Shift counts are taken modulo the lane width (exec-vshiftop).
  - THE NaN DISCIPLINE (aux-nans, per lane). Every payload-affecting float lane
    op canonicalises a NaN result to the POSITIVE canonical pattern — done for
    free by delegating each lane to the scalar Wasm.Interp.Numeric helper,
    which already canonicalises. neg/abs are sign-bit ops and preserve payload.
    pmin/pmax are SELECTIONS (fpmin(z1,z2) = if z2 < z1 then z2 else z1) with
    NO nans(...) routing: they return one operand BIT FOR BIT, so they are
    implemented directly and NEVER call the canonicalising helpers. min/max
    carry the +/-0 tie by sign (min(+0,-0) = -0), which the scalar F32Min/Max
    already do.
  - Relaxed SIMD is the deterministic profile R = 0 (profile-deterministic):
    every relaxed op reduces to its non-relaxed twin, so each relaxed leaf is a
    one-line delegation. The two relaxed dot products have no non-relaxed twin
    and are implemented directly as the signed dot product (op-irelaxed_dot:
    "In the deterministic profile it behaves like signed dot product").

  Memory load/store leaves take/return RAW BYTES the caller has already
  bounds-checked through the one memory chokepoint (simd-spec §4.5). This unit
  never touches a store or a memory: it is purely the lane transform. Bytes are
  read/written little-endian, byte by byte, so an unaligned source never
  faults on a strict-alignment target.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Anchors: exec-vunop,
  exec-vbinop, exec-vrelop, exec-vshiftop, exec-vtestop, exec-vbitmask,
  exec-vnarrow, exec-vextunop, exec-vextbinop, exec-vcvtop, exec-vshuffle,
  exec-vswizzlop, exec-vsplat, exec-vextract_lane, exec-vreplace_lane,
  exec-vload, exec-vload-pack, exec-vload-splat, exec-vload-zero,
  exec-vload_lane, exec-vstore, exec-vstore_lane, op-irelaxed_*. Where the
  served exec prose was empty (SpecTec), the corpus simd_*.wast is cited. }
unit Wasm.Interp.Vector;

{$I Shared.inc}

interface

uses
  Wasm.Core;

{ --- const / bitwise (exec-vvunop, exec-vvbinop, exec-vvternop) -------- }

procedure V128Not(const A, D: PWasmV128);
procedure V128And(const A, B, D: PWasmV128);
procedure V128Andnot(const A, B, D: PWasmV128);
procedure V128Or(const A, B, D: PWasmV128);
procedure V128Xor(const A, B, D: PWasmV128);
{ bitselect(i1, i2, mask) = (i1 and mask) or (i2 and not mask). }
procedure V128Bitselect(const A, B, C, D: PWasmV128);
function V128AnyTrue(const A: PWasmV128): UInt32;

{ --- shuffle / swizzle (exec-vshuffle, exec-vswizzlop) ---------------- }

{ ALanes points to 16 lane bytes, each in 0..31 (guaranteed by validation);
  result byte i is concat(A, B)[ALanes[i]]. }
procedure I8x16Shuffle(const A, B: PWasmV128; const ALanes: PByte;
  const D: PWasmV128);
{ result byte i is A[B[i]] when B[i] < 16 (unsigned), else 0. }
procedure I8x16Swizzle(const A, B, D: PWasmV128);

{ --- splat (exec-vsplat) --------------------------------------------- }

procedure I8x16Splat(const AValue: UInt32; const D: PWasmV128);
procedure I16x8Splat(const AValue: UInt32; const D: PWasmV128);
procedure I32x4Splat(const AValue: UInt32; const D: PWasmV128);
procedure I64x2Splat(const AValue: UInt64; const D: PWasmV128);
procedure F32x4Splat(const AValue: UInt32; const D: PWasmV128);
procedure F64x2Splat(const AValue: UInt64; const D: PWasmV128);

{ --- extract / replace lane (exec-vextract_lane, exec-vreplace_lane) -- }

function I8x16ExtractLaneS(const A: PWasmV128; const ALane: UInt32): UInt32;
function I8x16ExtractLaneU(const A: PWasmV128; const ALane: UInt32): UInt32;
function I16x8ExtractLaneS(const A: PWasmV128; const ALane: UInt32): UInt32;
function I16x8ExtractLaneU(const A: PWasmV128; const ALane: UInt32): UInt32;
function I32x4ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt32;
function I64x2ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt64;
function F32x4ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt32;
function F64x2ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt64;

procedure I8x16ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
procedure I16x8ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
procedure I32x4ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
procedure I64x2ReplaceLane(const A: PWasmV128; const ALane: UInt32;
  const AValue: UInt64; const D: PWasmV128);
procedure F32x4ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
procedure F64x2ReplaceLane(const A: PWasmV128; const ALane: UInt32;
  const AValue: UInt64; const D: PWasmV128);

{ --- i8x16 integer (exec-vunop, exec-vbinop, exec-vrelop, ...) -------- }

procedure I8x16Add(const A, B, D: PWasmV128);
procedure I8x16Sub(const A, B, D: PWasmV128);
procedure I8x16Neg(const A, D: PWasmV128);
procedure I8x16Abs(const A, D: PWasmV128);
procedure I8x16AddSatS(const A, B, D: PWasmV128);
procedure I8x16AddSatU(const A, B, D: PWasmV128);
procedure I8x16SubSatS(const A, B, D: PWasmV128);
procedure I8x16SubSatU(const A, B, D: PWasmV128);
procedure I8x16MinS(const A, B, D: PWasmV128);
procedure I8x16MinU(const A, B, D: PWasmV128);
procedure I8x16MaxS(const A, B, D: PWasmV128);
procedure I8x16MaxU(const A, B, D: PWasmV128);
procedure I8x16AvgrU(const A, B, D: PWasmV128);
procedure I8x16Popcnt(const A, D: PWasmV128);
procedure I8x16Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I8x16ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I8x16ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
function I8x16AllTrue(const A: PWasmV128): UInt32;
function I8x16Bitmask(const A: PWasmV128): UInt32;

procedure I8x16Eq(const A, B, D: PWasmV128);
procedure I8x16Ne(const A, B, D: PWasmV128);
procedure I8x16LtS(const A, B, D: PWasmV128);
procedure I8x16LtU(const A, B, D: PWasmV128);
procedure I8x16GtS(const A, B, D: PWasmV128);
procedure I8x16GtU(const A, B, D: PWasmV128);
procedure I8x16LeS(const A, B, D: PWasmV128);
procedure I8x16LeU(const A, B, D: PWasmV128);
procedure I8x16GeS(const A, B, D: PWasmV128);
procedure I8x16GeU(const A, B, D: PWasmV128);

procedure I8x16NarrowI16x8S(const A, B, D: PWasmV128);
procedure I8x16NarrowI16x8U(const A, B, D: PWasmV128);

{ --- i16x8 integer --------------------------------------------------- }

procedure I16x8Add(const A, B, D: PWasmV128);
procedure I16x8Sub(const A, B, D: PWasmV128);
procedure I16x8Mul(const A, B, D: PWasmV128);
procedure I16x8Neg(const A, D: PWasmV128);
procedure I16x8Abs(const A, D: PWasmV128);
procedure I16x8AddSatS(const A, B, D: PWasmV128);
procedure I16x8AddSatU(const A, B, D: PWasmV128);
procedure I16x8SubSatS(const A, B, D: PWasmV128);
procedure I16x8SubSatU(const A, B, D: PWasmV128);
procedure I16x8MinS(const A, B, D: PWasmV128);
procedure I16x8MinU(const A, B, D: PWasmV128);
procedure I16x8MaxS(const A, B, D: PWasmV128);
procedure I16x8MaxU(const A, B, D: PWasmV128);
procedure I16x8AvgrU(const A, B, D: PWasmV128);
procedure I16x8Q15mulrSatS(const A, B, D: PWasmV128);
procedure I16x8Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I16x8ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I16x8ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
function I16x8AllTrue(const A: PWasmV128): UInt32;
function I16x8Bitmask(const A: PWasmV128): UInt32;

procedure I16x8Eq(const A, B, D: PWasmV128);
procedure I16x8Ne(const A, B, D: PWasmV128);
procedure I16x8LtS(const A, B, D: PWasmV128);
procedure I16x8LtU(const A, B, D: PWasmV128);
procedure I16x8GtS(const A, B, D: PWasmV128);
procedure I16x8GtU(const A, B, D: PWasmV128);
procedure I16x8LeS(const A, B, D: PWasmV128);
procedure I16x8LeU(const A, B, D: PWasmV128);
procedure I16x8GeS(const A, B, D: PWasmV128);
procedure I16x8GeU(const A, B, D: PWasmV128);

procedure I16x8NarrowI32x4S(const A, B, D: PWasmV128);
procedure I16x8NarrowI32x4U(const A, B, D: PWasmV128);
procedure I16x8ExtendLowI8x16S(const A, D: PWasmV128);
procedure I16x8ExtendHighI8x16S(const A, D: PWasmV128);
procedure I16x8ExtendLowI8x16U(const A, D: PWasmV128);
procedure I16x8ExtendHighI8x16U(const A, D: PWasmV128);
procedure I16x8ExtaddPairwiseI8x16S(const A, D: PWasmV128);
procedure I16x8ExtaddPairwiseI8x16U(const A, D: PWasmV128);
procedure I16x8ExtmulLowI8x16S(const A, B, D: PWasmV128);
procedure I16x8ExtmulHighI8x16S(const A, B, D: PWasmV128);
procedure I16x8ExtmulLowI8x16U(const A, B, D: PWasmV128);
procedure I16x8ExtmulHighI8x16U(const A, B, D: PWasmV128);

{ --- i32x4 integer --------------------------------------------------- }

procedure I32x4Add(const A, B, D: PWasmV128);
procedure I32x4Sub(const A, B, D: PWasmV128);
procedure I32x4Mul(const A, B, D: PWasmV128);
procedure I32x4Neg(const A, D: PWasmV128);
procedure I32x4Abs(const A, D: PWasmV128);
procedure I32x4MinS(const A, B, D: PWasmV128);
procedure I32x4MinU(const A, B, D: PWasmV128);
procedure I32x4MaxS(const A, B, D: PWasmV128);
procedure I32x4MaxU(const A, B, D: PWasmV128);
procedure I32x4Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I32x4ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I32x4ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
function I32x4AllTrue(const A: PWasmV128): UInt32;
function I32x4Bitmask(const A: PWasmV128): UInt32;

procedure I32x4Eq(const A, B, D: PWasmV128);
procedure I32x4Ne(const A, B, D: PWasmV128);
procedure I32x4LtS(const A, B, D: PWasmV128);
procedure I32x4LtU(const A, B, D: PWasmV128);
procedure I32x4GtS(const A, B, D: PWasmV128);
procedure I32x4GtU(const A, B, D: PWasmV128);
procedure I32x4LeS(const A, B, D: PWasmV128);
procedure I32x4LeU(const A, B, D: PWasmV128);
procedure I32x4GeS(const A, B, D: PWasmV128);
procedure I32x4GeU(const A, B, D: PWasmV128);

procedure I32x4ExtendLowI16x8S(const A, D: PWasmV128);
procedure I32x4ExtendHighI16x8S(const A, D: PWasmV128);
procedure I32x4ExtendLowI16x8U(const A, D: PWasmV128);
procedure I32x4ExtendHighI16x8U(const A, D: PWasmV128);
procedure I32x4ExtaddPairwiseI16x8S(const A, D: PWasmV128);
procedure I32x4ExtaddPairwiseI16x8U(const A, D: PWasmV128);
procedure I32x4ExtmulLowI16x8S(const A, B, D: PWasmV128);
procedure I32x4ExtmulHighI16x8S(const A, B, D: PWasmV128);
procedure I32x4ExtmulLowI16x8U(const A, B, D: PWasmV128);
procedure I32x4ExtmulHighI16x8U(const A, B, D: PWasmV128);
procedure I32x4DotI16x8S(const A, B, D: PWasmV128);

{ --- i64x2 integer --------------------------------------------------- }

procedure I64x2Add(const A, B, D: PWasmV128);
procedure I64x2Sub(const A, B, D: PWasmV128);
procedure I64x2Mul(const A, B, D: PWasmV128);
procedure I64x2Neg(const A, D: PWasmV128);
procedure I64x2Abs(const A, D: PWasmV128);
procedure I64x2Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I64x2ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
procedure I64x2ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
function I64x2AllTrue(const A: PWasmV128): UInt32;
function I64x2Bitmask(const A: PWasmV128): UInt32;

procedure I64x2Eq(const A, B, D: PWasmV128);
procedure I64x2Ne(const A, B, D: PWasmV128);
procedure I64x2LtS(const A, B, D: PWasmV128);
procedure I64x2GtS(const A, B, D: PWasmV128);
procedure I64x2LeS(const A, B, D: PWasmV128);
procedure I64x2GeS(const A, B, D: PWasmV128);

procedure I64x2ExtendLowI32x4S(const A, D: PWasmV128);
procedure I64x2ExtendHighI32x4S(const A, D: PWasmV128);
procedure I64x2ExtendLowI32x4U(const A, D: PWasmV128);
procedure I64x2ExtendHighI32x4U(const A, D: PWasmV128);
procedure I64x2ExtmulLowI32x4S(const A, B, D: PWasmV128);
procedure I64x2ExtmulHighI32x4S(const A, B, D: PWasmV128);
procedure I64x2ExtmulLowI32x4U(const A, B, D: PWasmV128);
procedure I64x2ExtmulHighI32x4U(const A, B, D: PWasmV128);

{ --- f32x4 float (exec-vunop, exec-vbinop, exec-vrelop) -------------- }

procedure F32x4Add(const A, B, D: PWasmV128);
procedure F32x4Sub(const A, B, D: PWasmV128);
procedure F32x4Mul(const A, B, D: PWasmV128);
procedure F32x4Div(const A, B, D: PWasmV128);
procedure F32x4Min(const A, B, D: PWasmV128);
procedure F32x4Max(const A, B, D: PWasmV128);
procedure F32x4Pmin(const A, B, D: PWasmV128);
procedure F32x4Pmax(const A, B, D: PWasmV128);
procedure F32x4Sqrt(const A, D: PWasmV128);
procedure F32x4Ceil(const A, D: PWasmV128);
procedure F32x4Floor(const A, D: PWasmV128);
procedure F32x4Trunc(const A, D: PWasmV128);
procedure F32x4Nearest(const A, D: PWasmV128);
procedure F32x4Neg(const A, D: PWasmV128);
procedure F32x4Abs(const A, D: PWasmV128);

procedure F32x4Eq(const A, B, D: PWasmV128);
procedure F32x4Ne(const A, B, D: PWasmV128);
procedure F32x4Lt(const A, B, D: PWasmV128);
procedure F32x4Gt(const A, B, D: PWasmV128);
procedure F32x4Le(const A, B, D: PWasmV128);
procedure F32x4Ge(const A, B, D: PWasmV128);

{ --- f64x2 float ----------------------------------------------------- }

procedure F64x2Add(const A, B, D: PWasmV128);
procedure F64x2Sub(const A, B, D: PWasmV128);
procedure F64x2Mul(const A, B, D: PWasmV128);
procedure F64x2Div(const A, B, D: PWasmV128);
procedure F64x2Min(const A, B, D: PWasmV128);
procedure F64x2Max(const A, B, D: PWasmV128);
procedure F64x2Pmin(const A, B, D: PWasmV128);
procedure F64x2Pmax(const A, B, D: PWasmV128);
procedure F64x2Sqrt(const A, D: PWasmV128);
procedure F64x2Ceil(const A, D: PWasmV128);
procedure F64x2Floor(const A, D: PWasmV128);
procedure F64x2Trunc(const A, D: PWasmV128);
procedure F64x2Nearest(const A, D: PWasmV128);
procedure F64x2Neg(const A, D: PWasmV128);
procedure F64x2Abs(const A, D: PWasmV128);

procedure F64x2Eq(const A, B, D: PWasmV128);
procedure F64x2Ne(const A, B, D: PWasmV128);
procedure F64x2Lt(const A, B, D: PWasmV128);
procedure F64x2Gt(const A, B, D: PWasmV128);
procedure F64x2Le(const A, B, D: PWasmV128);
procedure F64x2Ge(const A, B, D: PWasmV128);

{ --- conversions (exec-vcvtop) --------------------------------------- }

procedure F32x4ConvertI32x4S(const A, D: PWasmV128);
procedure F32x4ConvertI32x4U(const A, D: PWasmV128);
procedure F64x2ConvertLowI32x4S(const A, D: PWasmV128);
procedure F64x2ConvertLowI32x4U(const A, D: PWasmV128);
procedure I32x4TruncSatF32x4S(const A, D: PWasmV128);
procedure I32x4TruncSatF32x4U(const A, D: PWasmV128);
procedure I32x4TruncSatF64x2SZero(const A, D: PWasmV128);
procedure I32x4TruncSatF64x2UZero(const A, D: PWasmV128);
procedure F32x4DemoteF64x2Zero(const A, D: PWasmV128);
procedure F64x2PromoteLowF32x4(const A, D: PWasmV128);

{ --- relaxed SIMD (profile-deterministic, R = 0) --------------------- }

procedure I8x16RelaxedSwizzle(const A, B, D: PWasmV128);
procedure I32x4RelaxedTruncF32x4S(const A, D: PWasmV128);
procedure I32x4RelaxedTruncF32x4U(const A, D: PWasmV128);
procedure I32x4RelaxedTruncF64x2S(const A, D: PWasmV128);
procedure I32x4RelaxedTruncF64x2U(const A, D: PWasmV128);
procedure F32x4RelaxedMadd(const A, B, C, D: PWasmV128);
procedure F32x4RelaxedNmadd(const A, B, C, D: PWasmV128);
procedure F64x2RelaxedMadd(const A, B, C, D: PWasmV128);
procedure F64x2RelaxedNmadd(const A, B, C, D: PWasmV128);
procedure I8x16RelaxedLaneselect(const A, B, C, D: PWasmV128);
procedure I16x8RelaxedLaneselect(const A, B, C, D: PWasmV128);
procedure I32x4RelaxedLaneselect(const A, B, C, D: PWasmV128);
procedure I64x2RelaxedLaneselect(const A, B, C, D: PWasmV128);
procedure F32x4RelaxedMin(const A, B, D: PWasmV128);
procedure F32x4RelaxedMax(const A, B, D: PWasmV128);
procedure F64x2RelaxedMin(const A, B, D: PWasmV128);
procedure F64x2RelaxedMax(const A, B, D: PWasmV128);
procedure I16x8RelaxedQ15mulrS(const A, B, D: PWasmV128);
{ i16x8.relaxed_dot_i8x16_i7x16_s: signed dot of adjacent i8 pairs -> i16. }
procedure I16x8RelaxedDotI8x16I7x16S(const A, B, D: PWasmV128);
{ i32x4.relaxed_dot_i8x16_i7x16_add_s: the i16 relaxed dot, then adjacent
  i16 lanes summed pairwise into i32 and added to C. }
procedure I32x4RelaxedDotI8x16I7x16AddS(const A, B, C, D: PWasmV128);

{ --- memory lane transforms (exec-vload*, exec-vstore*) --------------
  Pure byte transforms; the caller has already bounds-checked the span. }

procedure V128Load(const ASrc: PByte; const D: PWasmV128);
procedure V128Store(const A: PWasmV128; const ADest: PByte);
procedure V128Load8x8S(const ASrc: PByte; const D: PWasmV128);
procedure V128Load8x8U(const ASrc: PByte; const D: PWasmV128);
procedure V128Load16x4S(const ASrc: PByte; const D: PWasmV128);
procedure V128Load16x4U(const ASrc: PByte; const D: PWasmV128);
procedure V128Load32x2S(const ASrc: PByte; const D: PWasmV128);
procedure V128Load32x2U(const ASrc: PByte; const D: PWasmV128);
procedure V128Load8Splat(const ASrc: PByte; const D: PWasmV128);
procedure V128Load16Splat(const ASrc: PByte; const D: PWasmV128);
procedure V128Load32Splat(const ASrc: PByte; const D: PWasmV128);
procedure V128Load64Splat(const ASrc: PByte; const D: PWasmV128);
procedure V128Load32Zero(const ASrc: PByte; const D: PWasmV128);
procedure V128Load64Zero(const ASrc: PByte; const D: PWasmV128);
procedure V128Load8Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
procedure V128Load16Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
procedure V128Load32Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
procedure V128Load64Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
procedure V128Store8Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);
procedure V128Store16Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);
procedure V128Store32Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);
procedure V128Store64Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);

implementation

uses
  Wasm.Interp.Numeric;

{ Every routine relies on modulo-2^N lane arithmetic; Shared.inc turns the
  checks ON outside PRODUCTION, so push them OFF for the whole unit
  (exec-vbinop maps each lane to the wrapping generic operator). }
{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

{ --- saturation, sign, and arithmetic-shift helpers ------------------ }

function SatS8(const X: Int32): Byte; inline;
begin
  if X > 127 then Result := 127
  else if X < -128 then Result := Byte(-128)   { $80 }
  else Result := Byte(X);
end;

function SatU8(const X: Int32): Byte; inline;
begin
  if X > 255 then Result := 255
  else if X < 0 then Result := 0
  else Result := Byte(X);
end;

function SatS16(const X: Int32): Word; inline;
begin
  if X > 32767 then Result := 32767
  else if X < -32768 then Result := Word(-32768)   { $8000 }
  else Result := Word(X);
end;

function SatU16(const X: Int32): Word; inline;
begin
  if X > 65535 then Result := 65535
  else if X < 0 then Result := 0
  else Result := Word(X);
end;

function SatS32(const X: Int64): UInt32; inline;
begin
  if X > High(Int32) then Result := UInt32(High(Int32))
  else if X < Low(Int32) then Result := UInt32(Low(Int32))   { $80000000 }
  else Result := UInt32(Int32(X));
end;

function SatU32(const X: Int64): UInt32; inline;
begin
  if X > High(UInt32) then Result := High(UInt32)
  else if X < 0 then Result := 0
  else Result := UInt32(X);
end;

function SExt8(const V: Byte): Int32; inline;
begin
  Result := Int32(ShortInt(V));
end;

function SExt16(const V: Word): Int32; inline;
begin
  Result := Int32(SmallInt(V));
end;

function SExt32(const V: UInt32): Int64; inline;
begin
  Result := Int64(Int32(V));
end;

{ Arithmetic right shift by hand: FPC 'shr' is logical, so fill the vacated
  high bits with the sign when the operand is negative (mirrors
  Wasm.Interp.Numeric.I32ShrS). The 'not (not V shr C)' identity produces the
  same fill without a per-width mask constant. }
function Sar8(const V: Byte; const C: Byte): Byte; inline;
begin
  if (V and $80) <> 0 then
    Result := Byte(not (Byte(not V) shr C))
  else
    Result := V shr C;
end;

function Sar16(const V: Word; const C: Byte): Word; inline;
begin
  if (V and $8000) <> 0 then
    Result := Word(not (Word(not V) shr C))
  else
    Result := V shr C;
end;

function Sar32(const V: UInt32; const C: Byte): UInt32; inline;
begin
  if (V and $80000000) <> 0 then
    Result := not ((not V) shr C)
  else
    Result := V shr C;
end;

function Sar64(const V: UInt64; const C: Byte): UInt64; inline;
begin
  if (V and UInt64($8000000000000000)) <> 0 then
    Result := not ((not V) shr C)
  else
    Result := V shr C;
end;

{ Byte popcount, small loop per the RTL policy. }
function Popcnt8(const V: Byte): Byte; inline;
var
  Bits: Byte;
begin
  Result := 0;
  Bits := V;
  while Bits <> 0 do
  begin
    Inc(Result, Bits and 1);
    Bits := Bits shr 1;
  end;
end;

{ --- const / bitwise ------------------------------------------------- }

procedure V128Not(const A, D: PWasmV128);
begin
  D^.U64[0] := not A^.U64[0];
  D^.U64[1] := not A^.U64[1];
end;

procedure V128And(const A, B, D: PWasmV128);
begin
  D^.U64[0] := A^.U64[0] and B^.U64[0];
  D^.U64[1] := A^.U64[1] and B^.U64[1];
end;

procedure V128Andnot(const A, B, D: PWasmV128);
begin
  D^.U64[0] := A^.U64[0] and not B^.U64[0];
  D^.U64[1] := A^.U64[1] and not B^.U64[1];
end;

procedure V128Or(const A, B, D: PWasmV128);
begin
  D^.U64[0] := A^.U64[0] or B^.U64[0];
  D^.U64[1] := A^.U64[1] or B^.U64[1];
end;

procedure V128Xor(const A, B, D: PWasmV128);
begin
  D^.U64[0] := A^.U64[0] xor B^.U64[0];
  D^.U64[1] := A^.U64[1] xor B^.U64[1];
end;

procedure V128Bitselect(const A, B, C, D: PWasmV128);
var
  M0, M1: UInt64;
begin
  M0 := C^.U64[0];
  M1 := C^.U64[1];
  D^.U64[0] := (A^.U64[0] and M0) or (B^.U64[0] and not M0);
  D^.U64[1] := (A^.U64[1] and M1) or (B^.U64[1] and not M1);
end;

function V128AnyTrue(const A: PWasmV128): UInt32;
begin
  Result := Ord((A^.U64[0] or A^.U64[1]) <> 0);
end;

{ --- shuffle / swizzle ----------------------------------------------- }

procedure I8x16Shuffle(const A, B: PWasmV128; const ALanes: PByte;
  const D: PWasmV128);
var
  Src: array[0..31] of Byte;
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
  begin
    Src[I] := A^.B[I];
    Src[I + 16] := B^.B[I];
  end;
  for I := 0 to 15 do
    Res.B[I] := Src[ALanes[I]];   { ALanes[I] < 32 by validation }
  D^ := Res;
end;

procedure I8x16Swizzle(const A, B, D: PWasmV128);
var
  Src, Idx, Res: TWasmV128;
  I: Integer;
  K: Byte;
begin
  Src := A^;
  Idx := B^;
  for I := 0 to 15 do
  begin
    K := Idx.B[I];   { unsigned: any value >= 16, incl. all negatives, -> 0 }
    if K < 16 then
      Res.B[I] := Src.B[K]
    else
      Res.B[I] := 0;
  end;
  D^ := Res;
end;

{ --- splat ----------------------------------------------------------- }

procedure I8x16Splat(const AValue: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(AValue);
  D^ := Res;
end;

procedure I16x8Splat(const AValue: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(AValue);
  D^ := Res;
end;

procedure I32x4Splat(const AValue: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    Res.U32[I] := AValue;
  D^ := Res;
end;

procedure I64x2Splat(const AValue: UInt64; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := AValue;
  Res.U64[1] := AValue;
  D^ := Res;
end;

procedure F32x4Splat(const AValue: UInt32; const D: PWasmV128);
begin
  I32x4Splat(AValue, D);   { splat is a bit copy; f32 lane = raw bits }
end;

procedure F64x2Splat(const AValue: UInt64; const D: PWasmV128);
begin
  I64x2Splat(AValue, D);
end;

{ --- extract / replace lane ------------------------------------------ }

function I8x16ExtractLaneS(const A: PWasmV128; const ALane: UInt32): UInt32;
begin
  Result := UInt32(SExt8(A^.B[ALane]));
end;

function I8x16ExtractLaneU(const A: PWasmV128; const ALane: UInt32): UInt32;
begin
  Result := A^.B[ALane];
end;

function I16x8ExtractLaneS(const A: PWasmV128; const ALane: UInt32): UInt32;
begin
  Result := UInt32(SExt16(A^.U16[ALane]));
end;

function I16x8ExtractLaneU(const A: PWasmV128; const ALane: UInt32): UInt32;
begin
  Result := A^.U16[ALane];
end;

function I32x4ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt32;
begin
  Result := A^.U32[ALane];
end;

function I64x2ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt64;
begin
  Result := A^.U64[ALane];
end;

function F32x4ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt32;
begin
  Result := A^.U32[ALane];
end;

function F64x2ExtractLane(const A: PWasmV128; const ALane: UInt32): UInt64;
begin
  Result := A^.U64[ALane];
end;

procedure I8x16ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := A^;
  Res.B[ALane] := Byte(AValue);
  D^ := Res;
end;

procedure I16x8ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := A^;
  Res.U16[ALane] := Word(AValue);
  D^ := Res;
end;

procedure I32x4ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := A^;
  Res.U32[ALane] := AValue;
  D^ := Res;
end;

procedure I64x2ReplaceLane(const A: PWasmV128; const ALane: UInt32;
  const AValue: UInt64; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := A^;
  Res.U64[ALane] := AValue;
  D^ := Res;
end;

procedure F32x4ReplaceLane(const A: PWasmV128; const ALane, AValue: UInt32;
  const D: PWasmV128);
begin
  I32x4ReplaceLane(A, ALane, AValue, D);
end;

procedure F64x2ReplaceLane(const A: PWasmV128; const ALane: UInt32;
  const AValue: UInt64; const D: PWasmV128);
begin
  I64x2ReplaceLane(A, ALane, AValue, D);
end;

{ --- i8x16 integer --------------------------------------------------- }

procedure I8x16Add(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(A^.B[I] + B^.B[I]);
  D^ := Res;
end;

procedure I8x16Sub(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(A^.B[I] - B^.B[I]);
  D^ := Res;
end;

procedure I8x16Neg(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(0 - A^.B[I]);
  D^ := Res;
end;

procedure I8x16Abs(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  { abs(INT_MIN) wraps to INT_MIN (two's complement, no trap). }
  for I := 0 to 15 do
    if (A^.B[I] and $80) <> 0 then
      Res.B[I] := Byte(0 - A^.B[I])
    else
      Res.B[I] := A^.B[I];
  D^ := Res;
end;

procedure I8x16AddSatS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := SatS8(SExt8(A^.B[I]) + SExt8(B^.B[I]));
  D^ := Res;
end;

procedure I8x16AddSatU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := SatU8(Int32(A^.B[I]) + Int32(B^.B[I]));
  D^ := Res;
end;

procedure I8x16SubSatS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := SatS8(SExt8(A^.B[I]) - SExt8(B^.B[I]));
  D^ := Res;
end;

procedure I8x16SubSatU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := SatU8(Int32(A^.B[I]) - Int32(B^.B[I]));
  D^ := Res;
end;

procedure I8x16MinS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    if ShortInt(A^.B[I]) < ShortInt(B^.B[I]) then
      Res.B[I] := A^.B[I]
    else
      Res.B[I] := B^.B[I];
  D^ := Res;
end;

procedure I8x16MinU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    if A^.B[I] < B^.B[I] then Res.B[I] := A^.B[I] else Res.B[I] := B^.B[I];
  D^ := Res;
end;

procedure I8x16MaxS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    if ShortInt(A^.B[I]) > ShortInt(B^.B[I]) then
      Res.B[I] := A^.B[I]
    else
      Res.B[I] := B^.B[I];
  D^ := Res;
end;

procedure I8x16MaxU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    if A^.B[I] > B^.B[I] then Res.B[I] := A^.B[I] else Res.B[I] := B^.B[I];
  D^ := Res;
end;

procedure I8x16AvgrU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  { (a + b + 1) >> 1, widened so the +1 cannot overflow. }
  for I := 0 to 15 do
    Res.B[I] := Byte((Int32(A^.B[I]) + Int32(B^.B[I]) + 1) shr 1);
  D^ := Res;
end;

procedure I8x16Popcnt(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Popcnt8(A^.B[I]);
  D^ := Res;
end;

procedure I8x16Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 7;
  for I := 0 to 15 do
    Res.B[I] := Byte(A^.B[I] shl C);
  D^ := Res;
end;

procedure I8x16ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 7;
  for I := 0 to 15 do
    Res.B[I] := Sar8(A^.B[I], C);
  D^ := Res;
end;

procedure I8x16ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 7;
  for I := 0 to 15 do
    Res.B[I] := A^.B[I] shr C;
  D^ := Res;
end;

function I8x16AllTrue(const A: PWasmV128): UInt32;
var
  I: Integer;
begin
  for I := 0 to 15 do
    if A^.B[I] = 0 then Exit(0);
  Result := 1;
end;

function I8x16Bitmask(const A: PWasmV128): UInt32;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 15 do
    if (A^.B[I] and $80) <> 0 then
      Result := Result or (UInt32(1) shl I);
end;

{ i8x16 comparisons: a true lane is all-ones ($FF), a false lane 0. }
procedure I8x16Eq(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Res.B[I] := Byte(-Ord(A^.B[I] = B^.B[I]));
  D^ := Res;
end;

procedure I8x16Ne(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Res.B[I] := Byte(-Ord(A^.B[I] <> B^.B[I]));
  D^ := Res;
end;

procedure I8x16LtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(-Ord(ShortInt(A^.B[I]) < ShortInt(B^.B[I])));
  D^ := Res;
end;

procedure I8x16LtU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Res.B[I] := Byte(-Ord(A^.B[I] < B^.B[I]));
  D^ := Res;
end;

procedure I8x16GtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(-Ord(ShortInt(A^.B[I]) > ShortInt(B^.B[I])));
  D^ := Res;
end;

procedure I8x16GtU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Res.B[I] := Byte(-Ord(A^.B[I] > B^.B[I]));
  D^ := Res;
end;

procedure I8x16LeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(-Ord(ShortInt(A^.B[I]) <= ShortInt(B^.B[I])));
  D^ := Res;
end;

procedure I8x16LeU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Res.B[I] := Byte(-Ord(A^.B[I] <= B^.B[I]));
  D^ := Res;
end;

procedure I8x16GeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do
    Res.B[I] := Byte(-Ord(ShortInt(A^.B[I]) >= ShortInt(B^.B[I])));
  D^ := Res;
end;

procedure I8x16GeU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Res.B[I] := Byte(-Ord(A^.B[I] >= B^.B[I]));
  D^ := Res;
end;

{ narrow (exec-vnarrow): concatenate both operands' lanes, saturating into the
  narrower lane. A gives result lanes 0..7, B gives 8..15. The source is read
  SIGNED for both _s and _u; _u clamps negatives to 0. }
procedure I8x16NarrowI16x8S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
  begin
    Res.B[I] := SatS8(SExt16(A^.U16[I]));
    Res.B[I + 8] := SatS8(SExt16(B^.U16[I]));
  end;
  D^ := Res;
end;

procedure I8x16NarrowI16x8U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
  begin
    Res.B[I] := SatU8(SExt16(A^.U16[I]));
    Res.B[I + 8] := SatU8(SExt16(B^.U16[I]));
  end;
  D^ := Res;
end;

{ --- i16x8 integer --------------------------------------------------- }

procedure I16x8Add(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(A^.U16[I] + B^.U16[I]);
  D^ := Res;
end;

procedure I16x8Sub(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(A^.U16[I] - B^.U16[I]);
  D^ := Res;
end;

procedure I16x8Mul(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(A^.U16[I] * B^.U16[I]);
  D^ := Res;
end;

procedure I16x8Neg(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(0 - A^.U16[I]);
  D^ := Res;
end;

procedure I16x8Abs(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    if (A^.U16[I] and $8000) <> 0 then
      Res.U16[I] := Word(0 - A^.U16[I])
    else
      Res.U16[I] := A^.U16[I];
  D^ := Res;
end;

procedure I16x8AddSatS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := SatS16(SExt16(A^.U16[I]) + SExt16(B^.U16[I]));
  D^ := Res;
end;

procedure I16x8AddSatU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := SatU16(Int32(A^.U16[I]) + Int32(B^.U16[I]));
  D^ := Res;
end;

procedure I16x8SubSatS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := SatS16(SExt16(A^.U16[I]) - SExt16(B^.U16[I]));
  D^ := Res;
end;

procedure I16x8SubSatU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := SatU16(Int32(A^.U16[I]) - Int32(B^.U16[I]));
  D^ := Res;
end;

procedure I16x8MinS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    if SmallInt(A^.U16[I]) < SmallInt(B^.U16[I]) then
      Res.U16[I] := A^.U16[I]
    else
      Res.U16[I] := B^.U16[I];
  D^ := Res;
end;

procedure I16x8MinU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    if A^.U16[I] < B^.U16[I] then Res.U16[I] := A^.U16[I]
    else Res.U16[I] := B^.U16[I];
  D^ := Res;
end;

procedure I16x8MaxS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    if SmallInt(A^.U16[I]) > SmallInt(B^.U16[I]) then
      Res.U16[I] := A^.U16[I]
    else
      Res.U16[I] := B^.U16[I];
  D^ := Res;
end;

procedure I16x8MaxU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    if A^.U16[I] > B^.U16[I] then Res.U16[I] := A^.U16[I]
    else Res.U16[I] := B^.U16[I];
  D^ := Res;
end;

procedure I16x8AvgrU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word((Int32(A^.U16[I]) + Int32(B^.U16[I]) + 1) shr 1);
  D^ := Res;
end;

procedure I16x8Q15mulrSatS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  T: Int32;
begin
  { sat_s16((a*b + 0x4000) >> 15); the >> is arithmetic. The only saturating
    case is a = b = -32768 -> 32767. }
  for I := 0 to 7 do
  begin
    T := SExt16(A^.U16[I]) * SExt16(B^.U16[I]) + $4000;
    Res.U16[I] := SatS16(Int32(Sar32(UInt32(T), 15)));
  end;
  D^ := Res;
end;

procedure I16x8Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 15;
  for I := 0 to 7 do Res.U16[I] := Word(A^.U16[I] shl C);
  D^ := Res;
end;

procedure I16x8ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 15;
  for I := 0 to 7 do Res.U16[I] := Sar16(A^.U16[I], C);
  D^ := Res;
end;

procedure I16x8ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 15;
  for I := 0 to 7 do Res.U16[I] := A^.U16[I] shr C;
  D^ := Res;
end;

function I16x8AllTrue(const A: PWasmV128): UInt32;
var
  I: Integer;
begin
  for I := 0 to 7 do if A^.U16[I] = 0 then Exit(0);
  Result := 1;
end;

function I16x8Bitmask(const A: PWasmV128): UInt32;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 7 do
    if (A^.U16[I] and $8000) <> 0 then Result := Result or (UInt32(1) shl I);
end;

procedure I16x8Eq(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(-Ord(A^.U16[I] = B^.U16[I]));
  D^ := Res;
end;

procedure I16x8Ne(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(-Ord(A^.U16[I] <> B^.U16[I]));
  D^ := Res;
end;

procedure I16x8LtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(-Ord(SmallInt(A^.U16[I]) < SmallInt(B^.U16[I])));
  D^ := Res;
end;

procedure I16x8LtU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(-Ord(A^.U16[I] < B^.U16[I]));
  D^ := Res;
end;

procedure I16x8GtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(-Ord(SmallInt(A^.U16[I]) > SmallInt(B^.U16[I])));
  D^ := Res;
end;

procedure I16x8GtU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(-Ord(A^.U16[I] > B^.U16[I]));
  D^ := Res;
end;

procedure I16x8LeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(-Ord(SmallInt(A^.U16[I]) <= SmallInt(B^.U16[I])));
  D^ := Res;
end;

procedure I16x8LeU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(-Ord(A^.U16[I] <= B^.U16[I]));
  D^ := Res;
end;

procedure I16x8GeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(-Ord(SmallInt(A^.U16[I]) >= SmallInt(B^.U16[I])));
  D^ := Res;
end;

procedure I16x8GeU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(-Ord(A^.U16[I] >= B^.U16[I]));
  D^ := Res;
end;

procedure I16x8NarrowI32x4S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
  begin
    Res.U16[I] := SatS16(Int32(A^.U32[I]));
    Res.U16[I + 4] := SatS16(Int32(B^.U32[I]));
  end;
  D^ := Res;
end;

procedure I16x8NarrowI32x4U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
  begin
    Res.U16[I] := SatU16(Int32(A^.U32[I]));
    Res.U16[I + 4] := SatU16(Int32(B^.U32[I]));
  end;
  D^ := Res;
end;

procedure I16x8ExtendLowI8x16S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(SExt8(A^.B[I]));
  D^ := Res;
end;

procedure I16x8ExtendHighI8x16S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(SExt8(A^.B[I + 8]));
  D^ := Res;
end;

procedure I16x8ExtendLowI8x16U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := A^.B[I];
  D^ := Res;
end;

procedure I16x8ExtendHighI8x16U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := A^.B[I + 8];
  D^ := Res;
end;

procedure I16x8ExtaddPairwiseI8x16S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(SExt8(A^.B[2 * I]) + SExt8(A^.B[2 * I + 1]));
  D^ := Res;
end;

procedure I16x8ExtaddPairwiseI8x16U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(Int32(A^.B[2 * I]) + Int32(A^.B[2 * I + 1]));
  D^ := Res;
end;

procedure I16x8ExtmulLowI8x16S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(SExt8(A^.B[I]) * SExt8(B^.B[I]));
  D^ := Res;
end;

procedure I16x8ExtmulHighI8x16S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(SExt8(A^.B[I + 8]) * SExt8(B^.B[I + 8]));
  D^ := Res;
end;

procedure I16x8ExtmulLowI8x16U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(Int32(A^.B[I]) * Int32(B^.B[I]));
  D^ := Res;
end;

procedure I16x8ExtmulHighI8x16U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := Word(Int32(A^.B[I + 8]) * Int32(B^.B[I + 8]));
  D^ := Res;
end;

{ --- i32x4 integer --------------------------------------------------- }

procedure I32x4Add(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := A^.U32[I] + B^.U32[I];
  D^ := Res;
end;

procedure I32x4Sub(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := A^.U32[I] - B^.U32[I];
  D^ := Res;
end;

procedure I32x4Mul(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := A^.U32[I] * B^.U32[I];
  D^ := Res;
end;

procedure I32x4Neg(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := 0 - A^.U32[I];
  D^ := Res;
end;

procedure I32x4Abs(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    if (A^.U32[I] and $80000000) <> 0 then
      Res.U32[I] := 0 - A^.U32[I]
    else
      Res.U32[I] := A^.U32[I];
  D^ := Res;
end;

procedure I32x4MinS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    if Int32(A^.U32[I]) < Int32(B^.U32[I]) then Res.U32[I] := A^.U32[I]
    else Res.U32[I] := B^.U32[I];
  D^ := Res;
end;

procedure I32x4MinU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    if A^.U32[I] < B^.U32[I] then Res.U32[I] := A^.U32[I]
    else Res.U32[I] := B^.U32[I];
  D^ := Res;
end;

procedure I32x4MaxS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    if Int32(A^.U32[I]) > Int32(B^.U32[I]) then Res.U32[I] := A^.U32[I]
    else Res.U32[I] := B^.U32[I];
  D^ := Res;
end;

procedure I32x4MaxU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    if A^.U32[I] > B^.U32[I] then Res.U32[I] := A^.U32[I]
    else Res.U32[I] := B^.U32[I];
  D^ := Res;
end;

procedure I32x4Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 31;
  for I := 0 to 3 do Res.U32[I] := A^.U32[I] shl C;
  D^ := Res;
end;

procedure I32x4ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 31;
  for I := 0 to 3 do Res.U32[I] := Sar32(A^.U32[I], C);
  D^ := Res;
end;

procedure I32x4ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 31;
  for I := 0 to 3 do Res.U32[I] := A^.U32[I] shr C;
  D^ := Res;
end;

function I32x4AllTrue(const A: PWasmV128): UInt32;
var
  I: Integer;
begin
  for I := 0 to 3 do if A^.U32[I] = 0 then Exit(0);
  Result := 1;
end;

function I32x4Bitmask(const A: PWasmV128): UInt32;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to 3 do
    if (A^.U32[I] and $80000000) <> 0 then Result := Result or (UInt32(1) shl I);
end;

procedure I32x4Eq(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(A^.U32[I] = B^.U32[I]));
  D^ := Res;
end;

procedure I32x4Ne(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(A^.U32[I] <> B^.U32[I]));
  D^ := Res;
end;

procedure I32x4LtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(Int32(A^.U32[I]) < Int32(B^.U32[I])));
  D^ := Res;
end;

procedure I32x4LtU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(A^.U32[I] < B^.U32[I]));
  D^ := Res;
end;

procedure I32x4GtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(Int32(A^.U32[I]) > Int32(B^.U32[I])));
  D^ := Res;
end;

procedure I32x4GtU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(A^.U32[I] > B^.U32[I]));
  D^ := Res;
end;

procedure I32x4LeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(Int32(A^.U32[I]) <= Int32(B^.U32[I])));
  D^ := Res;
end;

procedure I32x4LeU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(A^.U32[I] <= B^.U32[I]));
  D^ := Res;
end;

procedure I32x4GeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(Int32(A^.U32[I]) >= Int32(B^.U32[I])));
  D^ := Res;
end;

procedure I32x4GeU(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Ord(A^.U32[I] >= B^.U32[I]));
  D^ := Res;
end;

procedure I32x4ExtendLowI16x8S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(SExt16(A^.U16[I]));
  D^ := Res;
end;

procedure I32x4ExtendHighI16x8S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(SExt16(A^.U16[I + 4]));
  D^ := Res;
end;

procedure I32x4ExtendLowI16x8U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := A^.U16[I];
  D^ := Res;
end;

procedure I32x4ExtendHighI16x8U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := A^.U16[I + 4];
  D^ := Res;
end;

procedure I32x4ExtaddPairwiseI16x8S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    Res.U32[I] := UInt32(SExt16(A^.U16[2 * I]) + SExt16(A^.U16[2 * I + 1]));
  D^ := Res;
end;

procedure I32x4ExtaddPairwiseI16x8U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    Res.U32[I] := UInt32(Int32(A^.U16[2 * I]) + Int32(A^.U16[2 * I + 1]));
  D^ := Res;
end;

procedure I32x4ExtmulLowI16x8S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(SExt16(A^.U16[I]) * SExt16(B^.U16[I]));
  D^ := Res;
end;

procedure I32x4ExtmulHighI16x8S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    Res.U32[I] := UInt32(SExt16(A^.U16[I + 4]) * SExt16(B^.U16[I + 4]));
  D^ := Res;
end;

procedure I32x4ExtmulLowI16x8U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(A^.U16[I]) * UInt32(B^.U16[I]);
  D^ := Res;
end;

procedure I32x4ExtmulHighI16x8U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(A^.U16[I + 4]) * UInt32(B^.U16[I + 4]);
  D^ := Res;
end;

procedure I32x4DotI16x8S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  { pairwise a[2i]*b[2i] + a[2i+1]*b[2i+1] in i32; no saturation (the sum of
    two i16*i16 products always fits i32). }
  for I := 0 to 3 do
    Res.U32[I] := UInt32(
      SExt16(A^.U16[2 * I]) * SExt16(B^.U16[2 * I]) +
      SExt16(A^.U16[2 * I + 1]) * SExt16(B^.U16[2 * I + 1]));
  D^ := Res;
end;

{ --- i64x2 integer --------------------------------------------------- }

procedure I64x2Add(const A, B, D: PWasmV128);
begin
  D^.U64[0] := A^.U64[0] + B^.U64[0];
  D^.U64[1] := A^.U64[1] + B^.U64[1];
end;

procedure I64x2Sub(const A, B, D: PWasmV128);
begin
  D^.U64[0] := A^.U64[0] - B^.U64[0];
  D^.U64[1] := A^.U64[1] - B^.U64[1];
end;

procedure I64x2Mul(const A, B, D: PWasmV128);
begin
  D^.U64[0] := A^.U64[0] * B^.U64[0];
  D^.U64[1] := A^.U64[1] * B^.U64[1];
end;

procedure I64x2Neg(const A, D: PWasmV128);
begin
  D^.U64[0] := 0 - A^.U64[0];
  D^.U64[1] := 0 - A^.U64[1];
end;

procedure I64x2Abs(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    if (A^.U64[I] and UInt64($8000000000000000)) <> 0 then
      Res.U64[I] := 0 - A^.U64[I]
    else
      Res.U64[I] := A^.U64[I];
  D^ := Res;
end;

procedure I64x2Shl(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 63;
  for I := 0 to 1 do Res.U64[I] := A^.U64[I] shl C;
  D^ := Res;
end;

procedure I64x2ShrS(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 63;
  for I := 0 to 1 do Res.U64[I] := Sar64(A^.U64[I], C);
  D^ := Res;
end;

procedure I64x2ShrU(const A: PWasmV128; const ACount: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
  C: Byte;
begin
  C := ACount and 63;
  for I := 0 to 1 do Res.U64[I] := A^.U64[I] shr C;
  D^ := Res;
end;

function I64x2AllTrue(const A: PWasmV128): UInt32;
begin
  Result := Ord((A^.U64[0] <> 0) and (A^.U64[1] <> 0));
end;

function I64x2Bitmask(const A: PWasmV128): UInt32;
begin
  Result := 0;
  if (A^.U64[0] and UInt64($8000000000000000)) <> 0 then Result := Result or 1;
  if (A^.U64[1] and UInt64($8000000000000000)) <> 0 then Result := Result or 2;
end;

procedure I64x2Eq(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(A^.U64[I] = B^.U64[I])));
  D^ := Res;
end;

procedure I64x2Ne(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(A^.U64[I] <> B^.U64[I])));
  D^ := Res;
end;

procedure I64x2LtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    Res.U64[I] := UInt64(-Int64(Ord(Int64(A^.U64[I]) < Int64(B^.U64[I]))));
  D^ := Res;
end;

procedure I64x2GtS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    Res.U64[I] := UInt64(-Int64(Ord(Int64(A^.U64[I]) > Int64(B^.U64[I]))));
  D^ := Res;
end;

procedure I64x2LeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    Res.U64[I] := UInt64(-Int64(Ord(Int64(A^.U64[I]) <= Int64(B^.U64[I]))));
  D^ := Res;
end;

procedure I64x2GeS(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    Res.U64[I] := UInt64(-Int64(Ord(Int64(A^.U64[I]) >= Int64(B^.U64[I]))));
  D^ := Res;
end;

procedure I64x2ExtendLowI32x4S(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := UInt64(SExt32(A^.U32[0]));
  Res.U64[1] := UInt64(SExt32(A^.U32[1]));
  D^ := Res;
end;

procedure I64x2ExtendHighI32x4S(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := UInt64(SExt32(A^.U32[2]));
  Res.U64[1] := UInt64(SExt32(A^.U32[3]));
  D^ := Res;
end;

procedure I64x2ExtendLowI32x4U(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := A^.U32[0];
  Res.U64[1] := A^.U32[1];
  D^ := Res;
end;

procedure I64x2ExtendHighI32x4U(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := A^.U32[2];
  Res.U64[1] := A^.U32[3];
  D^ := Res;
end;

procedure I64x2ExtmulLowI32x4S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := UInt64(SExt32(A^.U32[0]) * SExt32(B^.U32[0]));
  Res.U64[1] := UInt64(SExt32(A^.U32[1]) * SExt32(B^.U32[1]));
  D^ := Res;
end;

procedure I64x2ExtmulHighI32x4S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := UInt64(SExt32(A^.U32[2]) * SExt32(B^.U32[2]));
  Res.U64[1] := UInt64(SExt32(A^.U32[3]) * SExt32(B^.U32[3]));
  D^ := Res;
end;

procedure I64x2ExtmulLowI32x4U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := UInt64(A^.U32[0]) * UInt64(B^.U32[0]);
  Res.U64[1] := UInt64(A^.U32[1]) * UInt64(B^.U32[1]);
  D^ := Res;
end;

procedure I64x2ExtmulHighI32x4U(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := UInt64(A^.U32[2]) * UInt64(B^.U32[2]);
  Res.U64[1] := UInt64(A^.U32[3]) * UInt64(B^.U32[3]);
  D^ := Res;
end;

{ --- f32x4 float -----------------------------------------------------
  Every arithmetic lane delegates to the scalar Wasm.Interp.Numeric helper,
  which applies IEEE round-to-nearest-ties-even and canonicalises a NaN result
  to the positive canonical pattern (aux-nans, per lane). }

procedure F32x4Add(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Add(A^.U32[I], B^.U32[I]);
  D^ := Res;
end;

procedure F32x4Sub(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Sub(A^.U32[I], B^.U32[I]);
  D^ := Res;
end;

procedure F32x4Mul(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Mul(A^.U32[I], B^.U32[I]);
  D^ := Res;
end;

procedure F32x4Div(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Div(A^.U32[I], B^.U32[I]);
  D^ := Res;
end;

procedure F32x4Min(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Min(A^.U32[I], B^.U32[I]);
  D^ := Res;
end;

procedure F32x4Max(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Max(A^.U32[I], B^.U32[I]);
  D^ := Res;
end;

{ pmin/pmax are SELECTIONS, not fmin/fmax: fpmin(z1,z2) = if z2 < z1 then z2
  else z1. No nans(...) routing, so the operand is returned BIT FOR BIT
  (payload and sign preserved) and a NaN operand makes the '<' false, yielding
  z1. Corpus: simd_f32x4_pmin_pmax.wast (528 nan:0x payloads, 0 nan:canonical). }
procedure F32x4Pmin(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    if BitsToF32(B^.U32[I]) < BitsToF32(A^.U32[I]) then
      Res.U32[I] := B^.U32[I]
    else
      Res.U32[I] := A^.U32[I];
  D^ := Res;
end;

procedure F32x4Pmax(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    if BitsToF32(A^.U32[I]) < BitsToF32(B^.U32[I]) then
      Res.U32[I] := B^.U32[I]
    else
      Res.U32[I] := A^.U32[I];
  D^ := Res;
end;

procedure F32x4Sqrt(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Sqrt(A^.U32[I]);
  D^ := Res;
end;

procedure F32x4Ceil(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Ceil(A^.U32[I]);
  D^ := Res;
end;

procedure F32x4Floor(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Floor(A^.U32[I]);
  D^ := Res;
end;

procedure F32x4Trunc(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Trunc(A^.U32[I]);
  D^ := Res;
end;

procedure F32x4Nearest(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Nearest(A^.U32[I]);
  D^ := Res;
end;

{ neg/abs are sign-bit ops: no canonicalisation. }
procedure F32x4Neg(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Neg(A^.U32[I]);
  D^ := Res;
end;

procedure F32x4Abs(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32Abs(A^.U32[I]);
  D^ := Res;
end;

procedure F32x4Eq(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Int32(F32Eq(A^.U32[I], B^.U32[I])));
  D^ := Res;
end;

procedure F32x4Ne(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Int32(F32Ne(A^.U32[I], B^.U32[I])));
  D^ := Res;
end;

procedure F32x4Lt(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Int32(F32Lt(A^.U32[I], B^.U32[I])));
  D^ := Res;
end;

procedure F32x4Gt(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Int32(F32Gt(A^.U32[I], B^.U32[I])));
  D^ := Res;
end;

procedure F32x4Le(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Int32(F32Le(A^.U32[I], B^.U32[I])));
  D^ := Res;
end;

procedure F32x4Ge(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(-Int32(F32Ge(A^.U32[I], B^.U32[I])));
  D^ := Res;
end;

{ --- f64x2 float ----------------------------------------------------- }

procedure F64x2Add(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Add(A^.U64[I], B^.U64[I]);
  D^ := Res;
end;

procedure F64x2Sub(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Sub(A^.U64[I], B^.U64[I]);
  D^ := Res;
end;

procedure F64x2Mul(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Mul(A^.U64[I], B^.U64[I]);
  D^ := Res;
end;

procedure F64x2Div(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Div(A^.U64[I], B^.U64[I]);
  D^ := Res;
end;

procedure F64x2Min(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Min(A^.U64[I], B^.U64[I]);
  D^ := Res;
end;

procedure F64x2Max(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Max(A^.U64[I], B^.U64[I]);
  D^ := Res;
end;

procedure F64x2Pmin(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    if BitsToF64(B^.U64[I]) < BitsToF64(A^.U64[I]) then
      Res.U64[I] := B^.U64[I]
    else
      Res.U64[I] := A^.U64[I];
  D^ := Res;
end;

procedure F64x2Pmax(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    if BitsToF64(A^.U64[I]) < BitsToF64(B^.U64[I]) then
      Res.U64[I] := B^.U64[I]
    else
      Res.U64[I] := A^.U64[I];
  D^ := Res;
end;

procedure F64x2Sqrt(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Sqrt(A^.U64[I]);
  D^ := Res;
end;

procedure F64x2Ceil(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Ceil(A^.U64[I]);
  D^ := Res;
end;

procedure F64x2Floor(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Floor(A^.U64[I]);
  D^ := Res;
end;

procedure F64x2Trunc(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Trunc(A^.U64[I]);
  D^ := Res;
end;

procedure F64x2Nearest(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Nearest(A^.U64[I]);
  D^ := Res;
end;

procedure F64x2Neg(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Neg(A^.U64[I]);
  D^ := Res;
end;

procedure F64x2Abs(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := F64Abs(A^.U64[I]);
  D^ := Res;
end;

procedure F64x2Eq(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(F64Eq(A^.U64[I], B^.U64[I]) <> 0)));
  D^ := Res;
end;

procedure F64x2Ne(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(F64Ne(A^.U64[I], B^.U64[I]) <> 0)));
  D^ := Res;
end;

procedure F64x2Lt(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(F64Lt(A^.U64[I], B^.U64[I]) <> 0)));
  D^ := Res;
end;

procedure F64x2Gt(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(F64Gt(A^.U64[I], B^.U64[I]) <> 0)));
  D^ := Res;
end;

procedure F64x2Le(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(F64Le(A^.U64[I], B^.U64[I]) <> 0)));
  D^ := Res;
end;

procedure F64x2Ge(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(-Int64(Ord(F64Ge(A^.U64[I], B^.U64[I]) <> 0)));
  D^ := Res;
end;

{ --- conversions ----------------------------------------------------- }

procedure F32x4ConvertI32x4S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32ConvertI32S(A^.U32[I]);
  D^ := Res;
end;

procedure F32x4ConvertI32x4U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := F32ConvertI32U(A^.U32[I]);
  D^ := Res;
end;

procedure F64x2ConvertLowI32x4S(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := F64ConvertI32S(A^.U32[0]);
  Res.U64[1] := F64ConvertI32S(A^.U32[1]);
  D^ := Res;
end;

procedure F64x2ConvertLowI32x4U(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := F64ConvertI32U(A^.U32[0]);
  Res.U64[1] := F64ConvertI32U(A^.U32[1]);
  D^ := Res;
end;

{ trunc_sat never traps: NaN -> 0, below-min -> min, above-max -> max. }
procedure I32x4TruncSatF32x4S(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := I32TruncSatF32S(A^.U32[I]);
  D^ := Res;
end;

procedure I32x4TruncSatF32x4U(const A, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := I32TruncSatF32U(A^.U32[I]);
  D^ := Res;
end;

{ _zero forms: lanes 0-1 from the two f64 lanes, lanes 2-3 zero. }
procedure I32x4TruncSatF64x2SZero(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U32[0] := I32TruncSatF64S(A^.U64[0]);
  Res.U32[1] := I32TruncSatF64S(A^.U64[1]);
  Res.U32[2] := 0;
  Res.U32[3] := 0;
  D^ := Res;
end;

procedure I32x4TruncSatF64x2UZero(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U32[0] := I32TruncSatF64U(A^.U64[0]);
  Res.U32[1] := I32TruncSatF64U(A^.U64[1]);
  Res.U32[2] := 0;
  Res.U32[3] := 0;
  D^ := Res;
end;

procedure F32x4DemoteF64x2Zero(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U32[0] := F32DemoteF64(A^.U64[0]);
  Res.U32[1] := F32DemoteF64(A^.U64[1]);
  Res.U32[2] := 0;
  Res.U32[3] := 0;
  D^ := Res;
end;

procedure F64x2PromoteLowF32x4(const A, D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := F64PromoteF32(A^.U32[0]);
  Res.U64[1] := F64PromoteF32(A^.U32[1]);
  D^ := Res;
end;

{ --- relaxed SIMD (deterministic profile, R = 0) --------------------
  Each relaxed op reduces to its non-relaxed twin (profile-deterministic);
  most are one-line delegations. }

procedure I8x16RelaxedSwizzle(const A, B, D: PWasmV128);
begin
  I8x16Swizzle(A, B, D);
end;

procedure I32x4RelaxedTruncF32x4S(const A, D: PWasmV128);
begin
  I32x4TruncSatF32x4S(A, D);
end;

procedure I32x4RelaxedTruncF32x4U(const A, D: PWasmV128);
begin
  I32x4TruncSatF32x4U(A, D);
end;

{ NOTE the G1 mnemonic: the relaxed f64x2 trunc ops carry no _zero suffix in
  the registry, though they zero lanes 2-3 like their sat twin. }
procedure I32x4RelaxedTruncF64x2S(const A, D: PWasmV128);
begin
  I32x4TruncSatF64x2SZero(A, D);
end;

procedure I32x4RelaxedTruncF64x2U(const A, D: PWasmV128);
begin
  I32x4TruncSatF64x2UZero(A, D);
end;

{ R_fmadd = 0: UNFUSED, fadd(fmul(a,b), c) — two roundings. The scalar helpers
  round (and canonicalise) at each step. }
procedure F32x4RelaxedMadd(const A, B, C, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    Res.U32[I] := F32Add(F32Mul(A^.U32[I], B^.U32[I]), C^.U32[I]);
  D^ := Res;
end;

procedure F32x4RelaxedNmadd(const A, B, C, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    Res.U32[I] := F32Add(F32Mul(F32Neg(A^.U32[I]), B^.U32[I]), C^.U32[I]);
  D^ := Res;
end;

procedure F64x2RelaxedMadd(const A, B, C, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    Res.U64[I] := F64Add(F64Mul(A^.U64[I], B^.U64[I]), C^.U64[I]);
  D^ := Res;
end;

procedure F64x2RelaxedNmadd(const A, B, C, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do
    Res.U64[I] := F64Add(F64Mul(F64Neg(A^.U64[I]), B^.U64[I]), C^.U64[I]);
  D^ := Res;
end;

{ R_laneselect = 0: regular ibitselect, the mask used bit-wise. }
procedure I8x16RelaxedLaneselect(const A, B, C, D: PWasmV128);
begin
  V128Bitselect(A, B, C, D);
end;

procedure I16x8RelaxedLaneselect(const A, B, C, D: PWasmV128);
begin
  V128Bitselect(A, B, C, D);
end;

procedure I32x4RelaxedLaneselect(const A, B, C, D: PWasmV128);
begin
  V128Bitselect(A, B, C, D);
end;

procedure I64x2RelaxedLaneselect(const A, B, C, D: PWasmV128);
begin
  V128Bitselect(A, B, C, D);
end;

procedure F32x4RelaxedMin(const A, B, D: PWasmV128);
begin
  F32x4Min(A, B, D);
end;

procedure F32x4RelaxedMax(const A, B, D: PWasmV128);
begin
  F32x4Max(A, B, D);
end;

procedure F64x2RelaxedMin(const A, B, D: PWasmV128);
begin
  F64x2Min(A, B, D);
end;

procedure F64x2RelaxedMax(const A, B, D: PWasmV128);
begin
  F64x2Max(A, B, D);
end;

procedure I16x8RelaxedQ15mulrS(const A, B, D: PWasmV128);
begin
  I16x8Q15mulrSatS(A, B, D);
end;

{ op-irelaxed_dot at R = 0: signed dot product. No non-relaxed twin exists for
  the i8 -> i16 shape, so it is implemented here. Output lane j (0..7) is the
  signed dot of the adjacent i8 pair a[2j]*b[2j] + a[2j+1]*b[2j+1], saturated
  into i16. For inputs honouring the i7x16 contract on B the sum never
  saturates; the out-of-i7 corpus cases are all (either ...) alternatives, so
  the sat is a documented deterministic choice where the exec prose was empty.
  Corpus: relaxed_dot_product.wast. }
function RelaxedDot8Pair(const A, B: PWasmV128; const AJ: Integer): Int32; inline;
begin
  Result := SExt8(A^.B[2 * AJ]) * SExt8(B^.B[2 * AJ]) +
    SExt8(A^.B[2 * AJ + 1]) * SExt8(B^.B[2 * AJ + 1]);
end;

procedure I16x8RelaxedDotI8x16I7x16S(const A, B, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do
    Res.U16[I] := SatS16(RelaxedDot8Pair(A, B, I));
  D^ := Res;
end;

{ i32x4.relaxed_dot_i8x16_i7x16_add_s: the i16 relaxed dot's eight lanes summed
  in adjacent pairs into four i32 lanes, plus C. The pair values are the full
  signed dots (accumulated in the wider i32 lane, so no intermediate i16
  clamp). Corpus intermediate example a=b=[0..15] -> [14,126,366,734]. }
procedure I32x4RelaxedDotI8x16I7x16AddS(const A, B, C, D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do
    Res.U32[I] := UInt32(
      RelaxedDot8Pair(A, B, 2 * I) + RelaxedDot8Pair(A, B, 2 * I + 1) +
      Int32(C^.U32[I]));
  D^ := Res;
end;

{ --- memory lane transforms ------------------------------------------ }

function RdU16(const P: PByte): Word; inline;
begin
  Result := Word(P[0]) or (Word(P[1]) shl 8);
end;

function RdU32(const P: PByte): UInt32; inline;
begin
  Result := UInt32(P[0]) or (UInt32(P[1]) shl 8) or
    (UInt32(P[2]) shl 16) or (UInt32(P[3]) shl 24);
end;

function RdU64(const P: PByte): UInt64; inline;
begin
  Result := UInt64(RdU32(P)) or (UInt64(RdU32(@P[4])) shl 32);
end;

procedure WrU16(const P: PByte; const V: Word); inline;
begin
  P[0] := Byte(V);
  P[1] := Byte(V shr 8);
end;

procedure WrU32(const P: PByte; const V: UInt32); inline;
begin
  P[0] := Byte(V);
  P[1] := Byte(V shr 8);
  P[2] := Byte(V shr 16);
  P[3] := Byte(V shr 24);
end;

procedure WrU64(const P: PByte; const V: UInt64); inline;
begin
  WrU32(P, UInt32(V));
  WrU32(@P[4], UInt32(V shr 32));
end;

procedure V128Load(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 15 do Res.B[I] := ASrc[I];
  D^ := Res;
end;

procedure V128Store(const A: PWasmV128; const ADest: PByte);
var
  I: Integer;
begin
  for I := 0 to 15 do ADest[I] := A^.B[I];
end;

procedure V128Load8x8S(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := Word(SExt8(ASrc[I]));
  D^ := Res;
end;

procedure V128Load8x8U(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 7 do Res.U16[I] := ASrc[I];
  D^ := Res;
end;

procedure V128Load16x4S(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := UInt32(SExt16(RdU16(@ASrc[2 * I])));
  D^ := Res;
end;

procedure V128Load16x4U(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 3 do Res.U32[I] := RdU16(@ASrc[2 * I]);
  D^ := Res;
end;

procedure V128Load32x2S(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := UInt64(SExt32(RdU32(@ASrc[4 * I])));
  D^ := Res;
end;

procedure V128Load32x2U(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
  I: Integer;
begin
  for I := 0 to 1 do Res.U64[I] := RdU32(@ASrc[4 * I]);
  D^ := Res;
end;

procedure V128Load8Splat(const ASrc: PByte; const D: PWasmV128);
begin
  I8x16Splat(ASrc[0], D);
end;

procedure V128Load16Splat(const ASrc: PByte; const D: PWasmV128);
begin
  I16x8Splat(RdU16(ASrc), D);
end;

procedure V128Load32Splat(const ASrc: PByte; const D: PWasmV128);
begin
  I32x4Splat(RdU32(ASrc), D);
end;

procedure V128Load64Splat(const ASrc: PByte; const D: PWasmV128);
begin
  I64x2Splat(RdU64(ASrc), D);
end;

procedure V128Load32Zero(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := 0;
  Res.U64[1] := 0;
  Res.U32[0] := RdU32(ASrc);
  D^ := Res;
end;

procedure V128Load64Zero(const ASrc: PByte; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res.U64[0] := RdU64(ASrc);
  Res.U64[1] := 0;
  D^ := Res;
end;

procedure V128Load8Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := AOld^;
  Res.B[ALane] := ASrc[0];
  D^ := Res;
end;

procedure V128Load16Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := AOld^;
  Res.U16[ALane] := RdU16(ASrc);
  D^ := Res;
end;

procedure V128Load32Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := AOld^;
  Res.U32[ALane] := RdU32(ASrc);
  D^ := Res;
end;

procedure V128Load64Lane(const ASrc: PByte; const AOld: PWasmV128;
  const ALane: UInt32; const D: PWasmV128);
var
  Res: TWasmV128;
begin
  Res := AOld^;
  Res.U64[ALane] := RdU64(ASrc);
  D^ := Res;
end;

procedure V128Store8Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);
begin
  ADest[0] := A^.B[ALane];
end;

procedure V128Store16Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);
begin
  WrU16(ADest, A^.U16[ALane]);
end;

procedure V128Store32Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);
begin
  WrU32(ADest, A^.U32[ALane]);
end;

procedure V128Store64Lane(const A: PWasmV128; const ALane: UInt32;
  const ADest: PByte);
begin
  WrU64(ADest, A^.U64[ALane]);
end;

{$POP}

end.
