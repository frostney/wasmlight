{ Shared v128 op body for the two JIT backends (Wasm.Jit.Arm64, Wasm.Jit.X64).

  Both backends carried BYTE-IDENTICAL copies of JitMemLoadV128,
  JitMemStoreV128, and JitDoVec — the whole case dispatch is
  ISA-INDEPENDENT: it reads and writes the in-memory register file through
  VecAt and calls either the Wasm.Interp.Vector leaves (the interpreter's
  exact bits) or Store/GC methods through the same chokepoints. Only the
  native-code emission around them differs, which stays in the backends.
  One home means a vector-arm fix lands once and cannot drift between the
  tiers' compiling backends; the observational-identity invariant
  (ADR-0001, jit-spec §10.1, §13) is what the duplication used to put at
  risk. The per-op leaf inventory lives in Wasm.Interp.Vector; memory
  access stays behind Store.MemAddressAt (ADR-0005). }
unit Wasm.Jit.Vector;

{$I Shared.inc}

{$POINTERMATH ON}

interface

uses
  Wasm.Core,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

{ SIMD load/store family: every access is the chokepoint
  Store.MemAddressAt; see the implementation notes. }
procedure JitMemLoadV128(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
procedure JitMemStoreV128(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);

{ The v128 op body — the interpreter's SIMD arms reproduced VERBATIM, calling
  the identical Wasm.Interp.Vector leaves (jit-spec §10.1, §13). Reads and
  writes go through VecAt(Reg, k) / Reg[k] over the in-memory register file, so
  the 2-slot v128 layout is transparent and the result is bit-identical to the
  interpreter, per lane, including canonical NaNs and the relaxed R=0 profile. }
procedure JitDoVec(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);

implementation

uses
  Wasm.Interp.Vector,
  Wasm.Runtime.Gc;

{ The interpreter's MemLoadV128 / MemStoreV128 leaves, reproduced (they are
  implementation-only in Wasm.Interp). Reg is the register-file base the
  dispatcher already holds; AAct gives the aux block (lane forms) and the
  memory index space. Every access is the chokepoint Store.MemAddressAt. }
procedure JitMemLoadV128(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  MemAddr: TWasmMemAddr;
  Index, Offset: UInt64;
  MemIdx, Lane: UInt32;
  Dst: PWasmV128;
  P: PByte;
begin
  Reg := AReg;
  Index := Reg[AIns^.A].U64;
  Dst := VecAt(Reg, AIns^.Dest);
  case AIns^.Op of
    iroV128Load8Lane, iroV128Load16Lane, iroV128Load32Lane, iroV128Load64Lane:
      IrAuxReadLaneMemArg(AAct^.Fn^.AuxU32, UInt32(AIns^.Imm),
        MemIdx, Offset, Lane);
  else
    MemIdx := AIns^.B;
    Offset := UInt64(AIns^.Imm);
    Lane := 0;
  end;
  MemAddr := AAct^.Instance.MemAddrs[MemIdx];
  case AIns^.Op of
    iroV128Load:
      V128Load(AStore.MemAddressAt(MemAddr, Index, Offset, 16), Dst);
    iroV128Load8x8S:
      V128Load8x8S(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load8x8U:
      V128Load8x8U(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load16x4S:
      V128Load16x4S(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load16x4U:
      V128Load16x4U(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load32x2S:
      V128Load32x2S(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load32x2U:
      V128Load32x2U(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load8Splat:
      V128Load8Splat(AStore.MemAddressAt(MemAddr, Index, Offset, 1), Dst);
    iroV128Load16Splat:
      V128Load16Splat(AStore.MemAddressAt(MemAddr, Index, Offset, 2), Dst);
    iroV128Load32Splat:
      V128Load32Splat(AStore.MemAddressAt(MemAddr, Index, Offset, 4), Dst);
    iroV128Load64Splat:
      V128Load64Splat(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load32Zero:
      V128Load32Zero(AStore.MemAddressAt(MemAddr, Index, Offset, 4), Dst);
    iroV128Load64Zero:
      V128Load64Zero(AStore.MemAddressAt(MemAddr, Index, Offset, 8), Dst);
    iroV128Load8Lane:
      begin
        P := AStore.MemAddressAt(MemAddr, Index, Offset, 1);
        V128Load8Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
    iroV128Load16Lane:
      begin
        P := AStore.MemAddressAt(MemAddr, Index, Offset, 2);
        V128Load16Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
    iroV128Load32Lane:
      begin
        P := AStore.MemAddressAt(MemAddr, Index, Offset, 4);
        V128Load32Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
    iroV128Load64Lane:
      begin
        P := AStore.MemAddressAt(MemAddr, Index, Offset, 8);
        V128Load64Lane(P, VecAt(Reg, AIns^.B), Lane, Dst);
      end;
  end;
end;

procedure JitMemStoreV128(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  MemAddr: TWasmMemAddr;
  Index, Offset: UInt64;
  MemIdx, Lane: UInt32;
  Src: PWasmV128;
begin
  Reg := AReg;
  Index := Reg[AIns^.A].U64;
  Src := VecAt(Reg, AIns^.Dest);   { the value register (ifkSrcReg in Dest) }
  case AIns^.Op of
    iroV128Store8Lane, iroV128Store16Lane, iroV128Store32Lane,
    iroV128Store64Lane:
      IrAuxReadLaneMemArg(AAct^.Fn^.AuxU32, UInt32(AIns^.Imm),
        MemIdx, Offset, Lane);
  else
    MemIdx := AIns^.B;
    Offset := UInt64(AIns^.Imm);
    Lane := 0;
  end;
  MemAddr := AAct^.Instance.MemAddrs[MemIdx];
  case AIns^.Op of
    iroV128Store:
      V128Store(Src, AStore.MemAddressAt(MemAddr, Index, Offset, 16));
    iroV128Store8Lane:
      V128Store8Lane(Src, Lane, AStore.MemAddressAt(MemAddr, Index, Offset, 1));
    iroV128Store16Lane:
      V128Store16Lane(Src, Lane, AStore.MemAddressAt(MemAddr, Index, Offset, 2));
    iroV128Store32Lane:
      V128Store32Lane(Src, Lane, AStore.MemAddressAt(MemAddr, Index, Offset, 4));
    iroV128Store64Lane:
      V128Store64Lane(Src, Lane, AStore.MemAddressAt(MemAddr, Index, Offset, 8));
  end;
end;

{ The v128 op body — the interpreter's SIMD arms reproduced VERBATIM, calling
  the identical Wasm.Interp.Vector leaves (jit-spec §10.1, §13). Reads and
  writes go through VecAt(Reg, k) / Reg[k] over the in-memory register file, so
  the 2-slot v128 layout is transparent and the result is bit-identical to the
  interpreter, per lane, including canonical NaNs and the relaxed R=0 profile. }
procedure JitDoVec(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  Fn: PWasmIrFunction;
  Inst: TWasmModuleInstance;
  VTmp: TWasmV128;
  U1, U2: UInt32;
begin
  Reg := AReg;
  Fn := AAct^.Fn;
  Inst := AAct^.Instance;
  case AIns^.Op of
    { --- SIMD memory loads / stores: one chokepoint, explicit bounds check }
    iroV128Load, iroV128Load8x8S, iroV128Load8x8U, iroV128Load16x4S,
    iroV128Load16x4U, iroV128Load32x2S, iroV128Load32x2U, iroV128Load8Splat,
    iroV128Load16Splat, iroV128Load32Splat, iroV128Load64Splat,
    iroV128Load32Zero, iroV128Load64Zero, iroV128Load8Lane, iroV128Load16Lane,
    iroV128Load32Lane, iroV128Load64Lane:
      JitMemLoadV128(AStore, Reg, AAct, AIns);
    iroV128Store, iroV128Store8Lane, iroV128Store16Lane, iroV128Store32Lane,
    iroV128Store64Lane:
      JitMemStoreV128(AStore, Reg, AAct, AIns);

    { --- const / shuffle (16-byte immediate) ------------------------- }
    iroV128Const:
      IrAuxReadV128(Fn^.AuxU32, UInt32(AIns^.Imm), VecAt(Reg, AIns^.Dest)^);
    iroI8x16Shuffle:
      begin
        IrAuxReadV128(Fn^.AuxU32, UInt32(AIns^.Imm), VTmp);
        I8x16Shuffle(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), @VTmp.B[0],
          VecAt(Reg, AIns^.Dest));
      end;
    iroI8x16Swizzle: I8x16Swizzle(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));

    { --- splat ------------------------------------------------------- }
    iroI8x16Splat: I8x16Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroI16x8Splat: I16x8Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroI32x4Splat: I32x4Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroI64x2Splat: I64x2Splat(Reg[AIns^.A].U64, VecAt(Reg, AIns^.Dest));
    iroF32x4Splat: F32x4Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroF64x2Splat: F64x2Splat(Reg[AIns^.A].U64, VecAt(Reg, AIns^.Dest));

    { --- extract / replace lane -------------------------------------- }
    iroI8x16ExtractLaneS: ValueSetU32(Reg[AIns^.Dest], I8x16ExtractLaneS(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm)));
    iroI8x16ExtractLaneU: ValueSetU32(Reg[AIns^.Dest], I8x16ExtractLaneU(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm)));
    iroI8x16ReplaceLane: I8x16ReplaceLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI16x8ExtractLaneS: ValueSetU32(Reg[AIns^.Dest], I16x8ExtractLaneS(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm)));
    iroI16x8ExtractLaneU: ValueSetU32(Reg[AIns^.Dest], I16x8ExtractLaneU(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm)));
    iroI16x8ReplaceLane: I16x8ReplaceLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI32x4ExtractLane: ValueSetU32(Reg[AIns^.Dest], I32x4ExtractLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm)));
    iroI32x4ReplaceLane: I32x4ReplaceLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI64x2ExtractLane: Reg[AIns^.Dest].Bits := I64x2ExtractLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm));
    iroI64x2ReplaceLane: I64x2ReplaceLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm), Reg[AIns^.B].U64, VecAt(Reg, AIns^.Dest));
    iroF32x4ExtractLane: ValueSetU32(Reg[AIns^.Dest], F32x4ExtractLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm)));
    iroF32x4ReplaceLane: F32x4ReplaceLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroF64x2ExtractLane: Reg[AIns^.Dest].Bits := F64x2ExtractLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm));
    iroF64x2ReplaceLane: F64x2ReplaceLane(VecAt(Reg, AIns^.A), UInt32(AIns^.Imm), Reg[AIns^.B].U64, VecAt(Reg, AIns^.Dest));

    { --- comparisons ------------------------------------------------- }
    iroI8x16Eq: I8x16Eq(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16Ne: I8x16Ne(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16LtS: I8x16LtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16LtU: I8x16LtU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16GtS: I8x16GtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16GtU: I8x16GtU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16LeS: I8x16LeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16LeU: I8x16LeU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16GeS: I8x16GeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16GeU: I8x16GeU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8Eq: I16x8Eq(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8Ne: I16x8Ne(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8LtS: I16x8LtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8LtU: I16x8LtU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8GtS: I16x8GtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8GtU: I16x8GtU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8LeS: I16x8LeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8LeU: I16x8LeU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8GeS: I16x8GeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8GeU: I16x8GeU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4Eq: I32x4Eq(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4Ne: I32x4Ne(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4LtS: I32x4LtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4LtU: I32x4LtU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4GtS: I32x4GtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4GtU: I32x4GtU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4LeS: I32x4LeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4LeU: I32x4LeU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4GeS: I32x4GeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4GeU: I32x4GeU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Eq: F32x4Eq(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Ne: F32x4Ne(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Lt: F32x4Lt(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Gt: F32x4Gt(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Le: F32x4Le(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Ge: F32x4Ge(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Eq: F64x2Eq(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Ne: F64x2Ne(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Lt: F64x2Lt(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Gt: F64x2Gt(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Le: F64x2Le(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Ge: F64x2Ge(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));

    { --- bitwise and the whole-vector test --------------------------- }
    iroV128Not: V128Not(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroV128And: V128And(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Andnot: V128Andnot(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Or: V128Or(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Xor: V128Xor(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Bitselect: V128Bitselect(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroV128AnyTrue: ValueSetU32(Reg[AIns^.Dest], V128AnyTrue(VecAt(Reg, AIns^.A)));

    { --- float conversions ------------------------------------------- }
    iroF32x4DemoteF64x2Zero: F32x4DemoteF64x2Zero(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2PromoteLowF32x4: F64x2PromoteLowF32x4(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));

    { --- i8x16 unary / narrow / rounding / arith --------------------- }
    iroI8x16Abs: I8x16Abs(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI8x16Neg: I8x16Neg(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI8x16Popcnt: I8x16Popcnt(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI8x16AllTrue: ValueSetU32(Reg[AIns^.Dest], I8x16AllTrue(VecAt(Reg, AIns^.A)));
    iroI8x16Bitmask: ValueSetU32(Reg[AIns^.Dest], I8x16Bitmask(VecAt(Reg, AIns^.A)));
    iroI8x16NarrowI16x8S: I8x16NarrowI16x8S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16NarrowI16x8U: I8x16NarrowI16x8U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Ceil: F32x4Ceil(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4Floor: F32x4Floor(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4Trunc: F32x4Trunc(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4Nearest: F32x4Nearest(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI8x16Shl: I8x16Shl(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI8x16ShrS: I8x16ShrS(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI8x16ShrU: I8x16ShrU(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI8x16Add: I8x16Add(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16AddSatS: I8x16AddSatS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16AddSatU: I8x16AddSatU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16Sub: I8x16Sub(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16SubSatS: I8x16SubSatS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16SubSatU: I8x16SubSatU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Ceil: F64x2Ceil(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2Floor: F64x2Floor(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI8x16MinS: I8x16MinS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16MinU: I8x16MinU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16MaxS: I8x16MaxS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI8x16MaxU: I8x16MaxU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Trunc: F64x2Trunc(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI8x16AvgrU: I8x16AvgrU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtaddPairwiseI8x16S: I16x8ExtaddPairwiseI8x16S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtaddPairwiseI8x16U: I16x8ExtaddPairwiseI8x16U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtaddPairwiseI16x8S: I32x4ExtaddPairwiseI16x8S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtaddPairwiseI16x8U: I32x4ExtaddPairwiseI16x8U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));

    { --- i16x8 ------------------------------------------------------- }
    iroI16x8Abs: I16x8Abs(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8Neg: I16x8Neg(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8Q15mulrSatS: I16x8Q15mulrSatS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8AllTrue: ValueSetU32(Reg[AIns^.Dest], I16x8AllTrue(VecAt(Reg, AIns^.A)));
    iroI16x8Bitmask: ValueSetU32(Reg[AIns^.Dest], I16x8Bitmask(VecAt(Reg, AIns^.A)));
    iroI16x8NarrowI32x4S: I16x8NarrowI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8NarrowI32x4U: I16x8NarrowI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtendLowI8x16S: I16x8ExtendLowI8x16S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtendHighI8x16S: I16x8ExtendHighI8x16S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtendLowI8x16U: I16x8ExtendLowI8x16U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtendHighI8x16U: I16x8ExtendHighI8x16U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8Shl: I16x8Shl(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI16x8ShrS: I16x8ShrS(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI16x8ShrU: I16x8ShrU(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI16x8Add: I16x8Add(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8AddSatS: I16x8AddSatS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8AddSatU: I16x8AddSatU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8Sub: I16x8Sub(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8SubSatS: I16x8SubSatS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8SubSatU: I16x8SubSatU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Nearest: F64x2Nearest(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI16x8Mul: I16x8Mul(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8MinS: I16x8MinS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8MinU: I16x8MinU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8MaxS: I16x8MaxS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8MaxU: I16x8MaxU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8AvgrU: I16x8AvgrU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtmulLowI8x16S: I16x8ExtmulLowI8x16S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtmulHighI8x16S: I16x8ExtmulHighI8x16S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtmulLowI8x16U: I16x8ExtmulLowI8x16U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8ExtmulHighI8x16U: I16x8ExtmulHighI8x16U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));

    { --- i32x4 ------------------------------------------------------- }
    iroI32x4Abs: I32x4Abs(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4Neg: I32x4Neg(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4AllTrue: ValueSetU32(Reg[AIns^.Dest], I32x4AllTrue(VecAt(Reg, AIns^.A)));
    iroI32x4Bitmask: ValueSetU32(Reg[AIns^.Dest], I32x4Bitmask(VecAt(Reg, AIns^.A)));
    iroI32x4ExtendLowI16x8S: I32x4ExtendLowI16x8S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtendHighI16x8S: I32x4ExtendHighI16x8S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtendLowI16x8U: I32x4ExtendLowI16x8U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtendHighI16x8U: I32x4ExtendHighI16x8U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4Shl: I32x4Shl(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI32x4ShrS: I32x4ShrS(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI32x4ShrU: I32x4ShrU(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI32x4Add: I32x4Add(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4Sub: I32x4Sub(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4Mul: I32x4Mul(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4MinS: I32x4MinS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4MinU: I32x4MinU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4MaxS: I32x4MaxS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4MaxU: I32x4MaxU(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4DotI16x8S: I32x4DotI16x8S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtmulLowI16x8S: I32x4ExtmulLowI16x8S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtmulHighI16x8S: I32x4ExtmulHighI16x8S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtmulLowI16x8U: I32x4ExtmulLowI16x8U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4ExtmulHighI16x8U: I32x4ExtmulHighI16x8U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));

    { --- i64x2 ------------------------------------------------------- }
    iroI64x2Abs: I64x2Abs(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI64x2Neg: I64x2Neg(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI64x2AllTrue: ValueSetU32(Reg[AIns^.Dest], I64x2AllTrue(VecAt(Reg, AIns^.A)));
    iroI64x2Bitmask: ValueSetU32(Reg[AIns^.Dest], I64x2Bitmask(VecAt(Reg, AIns^.A)));
    iroI64x2ExtendLowI32x4S: I64x2ExtendLowI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI64x2ExtendHighI32x4S: I64x2ExtendHighI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI64x2ExtendLowI32x4U: I64x2ExtendLowI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI64x2ExtendHighI32x4U: I64x2ExtendHighI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI64x2Shl: I64x2Shl(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI64x2ShrS: I64x2ShrS(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI64x2ShrU: I64x2ShrU(VecAt(Reg, AIns^.A), Reg[AIns^.B].U32, VecAt(Reg, AIns^.Dest));
    iroI64x2Add: I64x2Add(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2Sub: I64x2Sub(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2Mul: I64x2Mul(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2Eq: I64x2Eq(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2Ne: I64x2Ne(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2LtS: I64x2LtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2GtS: I64x2GtS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2LeS: I64x2LeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2GeS: I64x2GeS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2ExtmulLowI32x4S: I64x2ExtmulLowI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2ExtmulHighI32x4S: I64x2ExtmulHighI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2ExtmulLowI32x4U: I64x2ExtmulLowI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI64x2ExtmulHighI32x4U: I64x2ExtmulHighI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));

    { --- f32x4 / f64x2 arithmetic ------------------------------------ }
    iroF32x4Abs: F32x4Abs(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4Neg: F32x4Neg(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4Sqrt: F32x4Sqrt(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4Add: F32x4Add(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Sub: F32x4Sub(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Mul: F32x4Mul(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Div: F32x4Div(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Min: F32x4Min(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Max: F32x4Max(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Pmin: F32x4Pmin(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4Pmax: F32x4Pmax(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Abs: F64x2Abs(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2Neg: F64x2Neg(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2Sqrt: F64x2Sqrt(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2Add: F64x2Add(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Sub: F64x2Sub(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Mul: F64x2Mul(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Div: F64x2Div(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Min: F64x2Min(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Max: F64x2Max(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Pmin: F64x2Pmin(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2Pmax: F64x2Pmax(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));

    { --- conversions ------------------------------------------------- }
    iroI32x4TruncSatF32x4S: I32x4TruncSatF32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4TruncSatF32x4U: I32x4TruncSatF32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4ConvertI32x4S: F32x4ConvertI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4ConvertI32x4U: F32x4ConvertI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4TruncSatF64x2SZero: I32x4TruncSatF64x2SZero(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4TruncSatF64x2UZero: I32x4TruncSatF64x2UZero(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2ConvertLowI32x4S: F64x2ConvertLowI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2ConvertLowI32x4U: F64x2ConvertLowI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));

    { --- relaxed SIMD (deterministic R=0 profile, the interpreter's) - }
    iroI8x16RelaxedSwizzle: I8x16RelaxedSwizzle(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4RelaxedTruncF32x4S: I32x4RelaxedTruncF32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4RelaxedTruncF32x4U: I32x4RelaxedTruncF32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4RelaxedTruncF64x2S: I32x4RelaxedTruncF64x2S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4RelaxedTruncF64x2U: I32x4RelaxedTruncF64x2U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4RelaxedMadd: F32x4RelaxedMadd(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroF32x4RelaxedNmadd: F32x4RelaxedNmadd(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroF64x2RelaxedMadd: F64x2RelaxedMadd(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroF64x2RelaxedNmadd: F64x2RelaxedNmadd(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroI8x16RelaxedLaneselect: I8x16RelaxedLaneselect(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroI16x8RelaxedLaneselect: I16x8RelaxedLaneselect(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroI32x4RelaxedLaneselect: I32x4RelaxedLaneselect(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroI64x2RelaxedLaneselect: I64x2RelaxedLaneselect(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroF32x4RelaxedMin: F32x4RelaxedMin(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF32x4RelaxedMax: F32x4RelaxedMax(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2RelaxedMin: F64x2RelaxedMin(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroF64x2RelaxedMax: F64x2RelaxedMax(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8RelaxedQ15mulrS: I16x8RelaxedQ15mulrS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI16x8RelaxedDotI8x16I7x16S: I16x8RelaxedDotI8x16I7x16S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroI32x4RelaxedDotI8x16I7x16AddS: I32x4RelaxedDotI8x16I7x16AddS(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));

    { --- IR-only vector ops (simd-spec §2.4) ------------------------- }
    iroMoveVec:
      VecAt(Reg, AIns^.Dest)^ := VecAt(Reg, AIns^.A)^;
    iroSelectVec:
      { Condition register rides in Imm (ifkSrcRegImm); 16-byte copy. }
      if Reg[UInt32(AIns^.Imm)].I32 <> 0 then
        VecAt(Reg, AIns^.Dest)^ := VecAt(Reg, AIns^.A)^
      else
        VecAt(Reg, AIns^.Dest)^ := VecAt(Reg, AIns^.B)^;
    iroGlobalGetVec:
      VecAt(Reg, AIns^.Dest)^ :=
        AStore.Globals[Inst.GlobalAddrs[UInt32(AIns^.Imm)]].Vec;
    iroGlobalSetVec:
      AStore.Globals[Inst.GlobalAddrs[UInt32(AIns^.Imm)]].Vec :=
        VecAt(Reg, AIns^.A)^;
    iroStructGetVec:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        AStore.Heap.StructGetVec(Reg[AIns^.A].Ref, U2, VecAt(Reg, AIns^.Dest));
      end;
    iroStructSetVec:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        AStore.Heap.StructSetVec(Reg[AIns^.A].Ref, U2, VecAt(Reg, AIns^.B));
      end;
    iroArrayGetVec:
      AStore.Heap.ArrayGetVec(Reg[AIns^.A].Ref, Reg[AIns^.B].U32,
        VecAt(Reg, AIns^.Dest));
    iroArraySetVec:
      AStore.Heap.ArraySetVec(Reg[AIns^.Dest].Ref, Reg[AIns^.A].U32,
        VecAt(Reg, AIns^.B));
    iroArrayFillVec:
      AStore.Heap.ArrayFillVec(
        Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, 0)].Ref,
        Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, 1)].U32,
        Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, 3)].U32,
        VecAt(Reg, IrAuxBlockItem(Fn^.AuxU32, AIns^.A, 2)));
  end;
end;

end.
