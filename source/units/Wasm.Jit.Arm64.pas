{ Wasm.Jit.Arm64 — the aarch64 (A64) instruction encoder and the per-IR-op
  code templates the baseline JIT emits (.agent/design/jit-spec.md §1, §5, §6,
  §8, §12.3 Wave 1 + Wave 2).

  This is the FIRST backend (§2.1: the dev host is aarch64-darwin, so the whole
  emit -> run -> diff loop is local). It owns ONLY the A64 bit-encoding and the
  op templates; the executable-memory machinery is Wasm.Jit.CodeBuffer's and the
  driver/dispatch is Wasm.Jit's.

  THE STRATEGY (§1.1, the memory-resident register file). The IR's virtual
  registers are NOT allocated to machine registers; they stay in the
  interpreter's value stack, addressed Reg[k] = Values[Base + k], a slice of
  8-byte TWasmValue slots. Each template (1) loads its operand slot(s) from
  memory into scratch machine registers, (2) computes, (3) stores the result to
  its destination slot. Machine registers are scratch WITHIN one template only —
  dead at every IR-op boundary — so the GC stack map is the frame itself and
  nothing extra is produced (§9.1).

  WAVE 2 CALLING CONVENTION (§5.3, O-J3). Because Wave 2 needs helper calls (all
  float ops and div/rem call Wasm.Interp.Numeric leaves; unreachable and the
  epoch interrupt call TrapNow) and forward branches, the compiled body is no
  longer a leaf and cannot keep the register-file base in x0 (caller-saved,
  clobbered by every call). The prologue therefore pins:

    x19  = register-file base  (@Values[Base]; the compiled entry's 1st arg, x0)
    x20  = the store pointer    (the compiled entry's 2nd arg, x1)
    x21  = &Store.Epoch         (x20 + StoreEpoch offset)
    x22  = the epoch captured at entry (the interpreter's EpochCache, §6)

  all callee-saved (AAPCS64 x19..x28), so they survive any helper call. The
  scratch registers are x9..x11 (caller-saved, dead at op boundaries) and x0..x2
  marshal helper arguments. The prologue saves x19..x22 and x30 and the epilogue
  restores them; a trap unwinds through LongJmp to the per-invocation trampoline
  (ADR-0009), which restores the caller's callee-saved set from its setjmp, so a
  skipped epilogue on the trap path is correct.

  HELPER-CALL ABI. Every helper the JIT calls is a cdecl thunk defined in this
  unit — JitOpBinary / JitOpUnary (which switch on the IR op and call the exact
  Wasm.Interp.Numeric leaf, so NaN bits, rounding, and div/rem trap kind+timing
  are the interpreter's by construction, §13) and JitTrapKind (TrapNow). cdecl on
  aarch64 IS AAPCS64, so the emitted call sequence (args in x0..x2, result in x0,
  16-byte SP alignment) is fully specified rather than betting on FPC's default
  convention.

  ENCODINGS. Every A64 word below is asserted from the ARM Architecture
  Reference Manual (ARMv8-A, section C6). Where a byte-level detail is not
  certain it carries UNCONFIRMED per jit-spec §0; a wrong bit is caught
  mechanically by the differential harness (§11): the compiled op diverges from
  the interpreter on the first input that exercises it, or the code faults.

  Depends on Wasm.Jit.CodeBuffer and Wasm.Ir (§12.1) plus — new in Wave 2 —
  Wasm.Interp.Numeric and Wasm.Runtime.Traps, the leaves and trap helper the
  templates call (§1.4). No cycle: Numeric uses only Traps.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
unit Wasm.Jit.Arm64;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Ir,
  Wasm.Jit.CodeBuffer;

type
  { A branch displacement that does not fit its A64 immediate field (imm26 for
    B, imm19 for B.cond/CBZ/CBNZ). Raised by Arm64ResolvePatches so the driver
    ABANDONS the compile and leaves the function interpreted (always correct)
    rather than silently truncating the offset into a wrong jump. A distinct
    class so the driver swallows ONLY this — a genuinely over-large function —
    and lets every other internal error surface loudly (jit-spec §4.3). }
  EWasmJitBranchRange = class(EWasmError);

const
  { --- register roles for the Wave-2 body (jit-spec §5.3) ----------------- }
  ARM64_REG_REGFILE = 19;  { x19 = @Values[Base], the register-file base }
  ARM64_REG_STORE = 20;    { x20 = the store pointer (for the epoch word) }
  ARM64_REG_EPOCHADDR = 21;{ x21 = &Store.Epoch }
  ARM64_REG_EPOCH = 22;    { x22 = the epoch captured at frame entry }
  ARM64_REG_T0 = 9;        { x9/w9 scratch }
  ARM64_REG_T1 = 10;       { x10/w10 scratch }
  ARM64_REG_T2 = 11;       { x11/w11 scratch }
  ARM64_REG_LR = 30;       { x30, the link register }
  ARM64_REG_ZR = 31;       { in data-processing, 31 encodes the zero register }

  { The interpreter frame slot is 8 bytes (Wasm.Runtime.Values.TWasmValue). The
    co-located test cross-checks this against
    Wasm.Interp.WasmJitFrameOffsets.ValueSlotSize so a slot-size change is
    caught rather than miscompiled. }
  ARM64_SLOT_SIZE = 8;

  { A scaled unsigned-offset LDR/STR imm12 field is 12 bits: the largest
    encodable slot index is bounded by the tightest scale (a 32-bit access
    scales the byte offset by 4, so imm12 = slot*8 div 4 = slot*2). Beyond this
    the driver declines the function (JitCanCompile) and it runs interpreted —
    always correct. }
  ARM64_MAX_SLOT = 2047;

  { AArch64 condition codes (C1.2.4). Only the ones the relop templates use. }
  ARM64_COND_EQ = 0;
  ARM64_COND_NE = 1;
  ARM64_COND_HS = 2;   { unsigned >= (carry set) }
  ARM64_COND_LO = 3;   { unsigned <  (carry clear) }
  ARM64_COND_HI = 8;   { unsigned >  }
  ARM64_COND_LS = 9;   { unsigned <= }
  ARM64_COND_GE = 10;  { signed   >= }
  ARM64_COND_LT = 11;  { signed   <  }
  ARM64_COND_GT = 12;  { signed   >  }
  ARM64_COND_LE = 13;  { signed   <= }

{ --- pure A64 word builders (no buffer; the test asserts their bits) ------ }

{ LDR/STR frame-relative, unsigned scaled offset (C6.2). imm12 = byteoffset /
  accesssize; the byteoffset is always a slot multiple, so exactly divisible. }
function Arm64LdrW(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
function Arm64LdrX(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
function Arm64StrW(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
function Arm64StrX(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;

{ Data-processing (shifted register), 32-bit (W) and 64-bit (X). The W form
  zero-extends its result into the whole X register, so a following STR Xt
  writes an i32 with its high 32 bits clear — the observational-identity
  widening store (§13 item 7). }
function Arm64AddW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64AddX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64SubW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64SubX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64MulW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64MulX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64AndW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64AndX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64OrrW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64OrrX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64EorW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64EorX(const ARd, ARn, ARm: Byte): UInt32;

{ Variable shifts/rotates (LSLV/LSRV/ASRV/RORV); the shift amount is taken
  modulo the register width by the hardware, exactly wasm's `count and (N-1)`. }
function Arm64LslvW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64LslvX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64LsrvW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64LsrvX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64AsrvW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64AsrvX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64RorvW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64RorvX(const ARd, ARn, ARm: Byte): UInt32;

{ NEG Wd,Wm = SUB Wd,WZR,Wm — used to turn ROR into a rotate-left (rotl(a,b) =
  ror(a, -b), since ROR masks the amount modulo the width). }
function Arm64NegW(const ARd, ARm: Byte): UInt32;
function Arm64NegX(const ARd, ARm: Byte): UInt32;

{ CLZ / RBIT; ctz(a) = clz(rbit(a)), matching the leaf. }
function Arm64ClzW(const ARd, ARn: Byte): UInt32;
function Arm64ClzX(const ARd, ARn: Byte): UInt32;
function Arm64RbitW(const ARd, ARn: Byte): UInt32;
function Arm64RbitX(const ARd, ARn: Byte): UInt32;

{ CMP (shifted register) = SUBS ZR,Rn,Rm (C6.2.62): sets the flags a following
  CSET/CSEL/B.cond reads. Pass ARM64_REG_ZR as ARm to compare against zero. }
function Arm64CmpW(const ARn, ARm: Byte): UInt32;
function Arm64CmpX(const ARn, ARm: Byte): UInt32;
{ CSET Wd,cond = CSINC Wd,WZR,WZR,invert(cond) (C6.2.71): 1 when cond holds,
  else 0, zero-extended into Xd. The 32-bit form is correct for every wasm
  relop (result is i32). }
function Arm64CsetW(const ARd, ACond: Byte): UInt32;
{ CSEL Xd,Xn,Xm,cond (C6.2.69): Xd := if cond then Xn else Xm — the select
  template's full 8-byte conditional copy. }
function Arm64CselX(const ARd, ARn, ARm, ACond: Byte): UInt32;

{ MOV Xd, Xn — register move, encoded as ORR Xd, XZR, Xn. }
function Arm64MovReg(const ARd, ARn: Byte): UInt32;

{ MOVZ/MOVK, both widths; the 32-bit MOVZ/MOVK zero-extend into Xd. }
function Arm64MovzW(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;
function Arm64MovkW(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;
function Arm64MovzX(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;
function Arm64MovkX(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;

{ ADD Xd,Xn,#imm12 (unsigned immediate, no shift): the epoch-word address
  computation x21 := x20 + StoreEpoch. }
function Arm64AddImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;

{ BLR Xn — branch with link to register (C6.2.35). Clobbers x30. }
function Arm64Blr(const ARn: Byte): UInt32;
{ RET (Xn) — return to Xn (default x30). ret = 0xD65F03C0. }
function Arm64Ret: UInt32;

{ The Wave-2 frame save/restore words (jit-spec §5.3). The prologue saves the
  four pinned callee-saved registers plus x30 in a 48-byte frame; the epilogue
  restores them. Provided as builders so the encoder test can assert the bytes. }
function Arm64StpX19X20PreIndex48: UInt32;   { stp x19,x20,[sp,#-48]! }
function Arm64StpX21X22Off16: UInt32;        { stp x21,x22,[sp,#16] }
function Arm64LdpX21X22Off16: UInt32;        { ldp x21,x22,[sp,#16] }
function Arm64LdpX19X20PostIndex48: UInt32;  { ldp x19,x20,[sp],#48 }

{ True iff AValue fits a two's-complement signed field of ABits bits, i.e.
  -2^(ABits-1) <= AValue <= 2^(ABits-1)-1. The branch-displacement range guard
  (jit-spec §4.3): a B target must fit imm26 (ABits=26, +-128 MiB in
  instructions), a B.cond/CBZ/CBNZ target imm19 (ABits=19, +-1 MiB). The unit
  the caller passes is the already-scaled Imm = byteDelta div 4. }
function Arm64SignedImmFits(const AValue: Integer; const ABits: Byte): Boolean;

{ Branch instruction words with a ZERO displacement (the placeholder the patch
  list later fills). B is imm26<<2; B.cond / CBZ / CBNZ are imm19<<2. }
function Arm64BPlaceholder: UInt32;
function Arm64BCondPlaceholder(const ACond: Byte): UInt32;
function Arm64CbzWPlaceholder(const ARt: Byte): UInt32;
function Arm64CbnzWPlaceholder(const ARt: Byte): UInt32;

{ --- emit primitives into a code buffer ---------------------------------- }
procedure Arm64EmitLdrW(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
procedure Arm64EmitLdrX(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
procedure Arm64EmitStrW(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
procedure Arm64EmitStrX(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
procedure Arm64EmitRet(const ABuf: TWasmCodeBuffer);
procedure Arm64EmitMovzX(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AImm16: UInt16; const AHw: Byte);
procedure Arm64EmitMovkX(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AImm16: UInt16; const AHw: Byte);
{ Load an arbitrary 32-/64-bit constant into Rd (movz + movk as needed). }
procedure Arm64EmitLoadImm32(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AValue: UInt32);
procedure Arm64EmitLoadImm64(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AValue: UInt64);

{ --- the Wave-2 frame (jit-spec §5.2/§5.3/§6) ----------------------------

  Arm64EmitPrologue saves the callee-saved set and moves the two entry
  arguments into their pinned registers (x0 -> x19 regbase, x1 -> x20 store).
  It does NOT dereference the store, so it is safe to emit even where the
  epoch is never checked. Arm64EmitEpochCapture then computes x21 := &Epoch
  (the LIVE epoch word, reloaded at every back-edge) and captures
  x22 := Store.EpochSnapshot (the SHARED per-invocation snapshot the outermost
  guest-entry seeded, jit-spec §6) — NOT a fresh Store.Epoch read, so a
  compiled leaf called mid-invocation inherits the invocation's original
  snapshot and observes an interrupt at the same back-edge the interpreter
  would. The driver emits it once, right after the prologue, because the store
  is a real pointer on the JitDispatch path. AEpochOffset is Store.Epoch's byte
  offset; ASnapshotOffset is Store.EpochSnapshot's. Arm64EmitEpilogue restores
  the set and returns (iroReturn emits it). }
procedure Arm64EmitPrologue(const ABuf: TWasmCodeBuffer);
procedure Arm64EmitEpochCapture(const ABuf: TWasmCodeBuffer;
  const AEpochOffset, ASnapshotOffset: NativeUInt);
procedure Arm64EmitEpilogue(const ABuf: TWasmCodeBuffer);

{ Resolve every forward/backward branch placeholder recorded on ABuf's patch
  list into its final A64 branch word. Call once, after the whole function is
  emitted and every label bound, while the buffer is still writable (§4.3). }
procedure Arm64ResolvePatches(const ABuf: TWasmCodeBuffer);

{ --- the per-op template layer (the driver walks the IR and calls this) ---

  Arm64CanEmitOp is the per-op half of the compile predicate (§10.3): true only
  for an op this backend has a template for. Arm64EmitOp emits that template for
  one instruction, reading operand slots relative to the pinned register-file
  base and writing the destination slot; it returns False (emitting nothing) for
  an op it cannot handle. Control-flow ops record branch patches against the
  target IR-instruction's label — the driver binds one label per instruction, in
  order, so the label id equals the IR index (AIns's target fields are used as
  label ids directly). br_table reads its target list from AAux (the function's
  AuxU32 block); pass the compiling function's AuxU32. }
function Arm64CanEmitOp(const AOp: TWasmIrOp): Boolean;
function Arm64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32): Boolean;

{ The byte offset of register/slot k from the register-file base. }
function Arm64SlotByteOffset(const AReg: UInt32): UInt32;

implementation

uses
  Wasm.Interp.Numeric,
  Wasm.Runtime.Traps;

{ ===================================================================== }
{  cdecl helper thunks — the ABI boundary the emitted code calls (§1.4) }
{ ===================================================================== }

{ Every subtle op (all float arithmetic, div/rem, conversions, truncations)
  routes through these two thunks, which switch on the IR op ordinal and call
  the EXACT Wasm.Interp.Numeric leaf the interpreter calls — so NaN bits,
  rounding, and the div/rem and float->int trap kind + timing are identical by
  construction (§13). Results are widened to a full slot exactly as the
  interpreter's `Reg[Dest].Bits := UInt64(...)` stores them: a 32-bit result is
  returned zero-extended, a 64-bit result verbatim. cdecl = AAPCS64, so the
  emitter's call sequence is fully specified. }
function JitOpBinary(const AOp: PtrUInt; const A, B: UInt64): UInt64; cdecl;
begin
  case TWasmIrOp(AOp) of
    iroI32DivS: Result := UInt64(I32DivS(UInt32(A), UInt32(B)));
    iroI32DivU: Result := UInt64(I32DivU(UInt32(A), UInt32(B)));
    iroI32RemS: Result := UInt64(I32RemS(UInt32(A), UInt32(B)));
    iroI32RemU: Result := UInt64(I32RemU(UInt32(A), UInt32(B)));
    iroI64DivS: Result := I64DivS(A, B);
    iroI64DivU: Result := I64DivU(A, B);
    iroI64RemS: Result := I64RemS(A, B);
    iroI64RemU: Result := I64RemU(A, B);

    iroF32Add: Result := UInt64(F32Add(UInt32(A), UInt32(B)));
    iroF32Sub: Result := UInt64(F32Sub(UInt32(A), UInt32(B)));
    iroF32Mul: Result := UInt64(F32Mul(UInt32(A), UInt32(B)));
    iroF32Div: Result := UInt64(F32Div(UInt32(A), UInt32(B)));
    iroF32Min: Result := UInt64(F32Min(UInt32(A), UInt32(B)));
    iroF32Max: Result := UInt64(F32Max(UInt32(A), UInt32(B)));
    iroF32Copysign: Result := UInt64(F32Copysign(UInt32(A), UInt32(B)));
    iroF32Eq: Result := UInt64(F32Eq(UInt32(A), UInt32(B)));
    iroF32Ne: Result := UInt64(F32Ne(UInt32(A), UInt32(B)));
    iroF32Lt: Result := UInt64(F32Lt(UInt32(A), UInt32(B)));
    iroF32Gt: Result := UInt64(F32Gt(UInt32(A), UInt32(B)));
    iroF32Le: Result := UInt64(F32Le(UInt32(A), UInt32(B)));
    iroF32Ge: Result := UInt64(F32Ge(UInt32(A), UInt32(B)));

    iroF64Add: Result := F64Add(A, B);
    iroF64Sub: Result := F64Sub(A, B);
    iroF64Mul: Result := F64Mul(A, B);
    iroF64Div: Result := F64Div(A, B);
    iroF64Min: Result := F64Min(A, B);
    iroF64Max: Result := F64Max(A, B);
    iroF64Copysign: Result := F64Copysign(A, B);
    iroF64Eq: Result := UInt64(F64Eq(A, B));
    iroF64Ne: Result := UInt64(F64Ne(A, B));
    iroF64Lt: Result := UInt64(F64Lt(A, B));
    iroF64Gt: Result := UInt64(F64Gt(A, B));
    iroF64Le: Result := UInt64(F64Le(A, B));
    iroF64Ge: Result := UInt64(F64Ge(A, B));
  else
    Result := 0;
  end;
end;

function JitOpUnary(const AOp: PtrUInt; const A: UInt64): UInt64; cdecl;
begin
  case TWasmIrOp(AOp) of
    iroI32Popcnt: Result := UInt64(I32Popcnt(UInt32(A)));
    iroI64Popcnt: Result := I64Popcnt(A);

    iroI32WrapI64: Result := UInt64(I32WrapI64(A));
    iroI64ExtendI32S: Result := I64ExtendI32S(UInt32(A));
    iroI64ExtendI32U: Result := I64ExtendI32U(UInt32(A));
    iroI32Extend8S: Result := UInt64(I32Extend8S(UInt32(A)));
    iroI32Extend16S: Result := UInt64(I32Extend16S(UInt32(A)));
    iroI64Extend8S: Result := I64Extend8S(A);
    iroI64Extend16S: Result := I64Extend16S(A);
    iroI64Extend32S: Result := I64Extend32S(A);

    iroF32Abs: Result := UInt64(F32Abs(UInt32(A)));
    iroF32Neg: Result := UInt64(F32Neg(UInt32(A)));
    iroF32Ceil: Result := UInt64(F32Ceil(UInt32(A)));
    iroF32Floor: Result := UInt64(F32Floor(UInt32(A)));
    iroF32Trunc: Result := UInt64(F32Trunc(UInt32(A)));
    iroF32Nearest: Result := UInt64(F32Nearest(UInt32(A)));
    iroF32Sqrt: Result := UInt64(F32Sqrt(UInt32(A)));
    iroF64Abs: Result := F64Abs(A);
    iroF64Neg: Result := F64Neg(A);
    iroF64Ceil: Result := F64Ceil(A);
    iroF64Floor: Result := F64Floor(A);
    iroF64Trunc: Result := F64Trunc(A);
    iroF64Nearest: Result := F64Nearest(A);
    iroF64Sqrt: Result := F64Sqrt(A);

    iroF32DemoteF64: Result := UInt64(F32DemoteF64(A));
    iroF64PromoteF32: Result := F64PromoteF32(UInt32(A));

    iroI32TruncF32S: Result := UInt64(I32TruncF32S(UInt32(A)));
    iroI32TruncF32U: Result := UInt64(I32TruncF32U(UInt32(A)));
    iroI32TruncF64S: Result := UInt64(I32TruncF64S(A));
    iroI32TruncF64U: Result := UInt64(I32TruncF64U(A));
    iroI64TruncF32S: Result := I64TruncF32S(UInt32(A));
    iroI64TruncF32U: Result := I64TruncF32U(UInt32(A));
    iroI64TruncF64S: Result := I64TruncF64S(A);
    iroI64TruncF64U: Result := I64TruncF64U(A);

    iroF32ConvertI32S: Result := UInt64(F32ConvertI32S(UInt32(A)));
    iroF32ConvertI32U: Result := UInt64(F32ConvertI32U(UInt32(A)));
    iroF32ConvertI64S: Result := UInt64(F32ConvertI64S(A));
    iroF32ConvertI64U: Result := UInt64(F32ConvertI64U(A));
    iroF64ConvertI32S: Result := F64ConvertI32S(UInt32(A));
    iroF64ConvertI32U: Result := F64ConvertI32U(UInt32(A));
    iroF64ConvertI64S: Result := F64ConvertI64S(A);
    iroF64ConvertI64U: Result := F64ConvertI64U(A);

    iroI32ReinterpretF32: Result := UInt64(I32ReinterpretF32(UInt32(A)));
    iroF32ReinterpretI32: Result := UInt64(F32ReinterpretI32(UInt32(A)));
    iroI64ReinterpretF64: Result := I64ReinterpretF64(A);
    iroF64ReinterpretI64: Result := F64ReinterpretI64(A);

    iroI32TruncSatF32S: Result := UInt64(I32TruncSatF32S(UInt32(A)));
    iroI32TruncSatF32U: Result := UInt64(I32TruncSatF32U(UInt32(A)));
    iroI32TruncSatF64S: Result := UInt64(I32TruncSatF64S(A));
    iroI32TruncSatF64U: Result := UInt64(I32TruncSatF64U(A));
    iroI64TruncSatF32S: Result := I64TruncSatF32S(UInt32(A));
    iroI64TruncSatF32U: Result := I64TruncSatF32U(UInt32(A));
    iroI64TruncSatF64S: Result := I64TruncSatF64S(A);
    iroI64TruncSatF64U: Result := I64TruncSatF64U(A);
  else
    Result := 0;
  end;
end;

{ The trap thunk (§8.1): a call that never returns. Reuses the interpreter's
  exact TrapNow, so the message + kind + trampoline unwind match for free. }
procedure JitTrapKind(const AKind: PtrUInt); cdecl;
begin
  TrapNow(TWasmTrapKind(AKind));
end;

{ ===================================================================== }
{  pure word builders                                                    }
{ ===================================================================== }

function Arm64SlotByteOffset(const AReg: UInt32): UInt32;
begin
  Result := AReg * ARM64_SLOT_SIZE;
end;

function Arm64LdrW(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
begin
  Result := $B9400000 or ((AByteOffset div 4) shl 10) or (UInt32(ARn) shl 5)
    or ARt;
end;

function Arm64LdrX(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
begin
  Result := $F9400000 or ((AByteOffset div 8) shl 10) or (UInt32(ARn) shl 5)
    or ARt;
end;

function Arm64StrW(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
begin
  Result := $B9000000 or ((AByteOffset div 4) shl 10) or (UInt32(ARn) shl 5)
    or ARt;
end;

function Arm64StrX(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
begin
  Result := $F9000000 or ((AByteOffset div 8) shl 10) or (UInt32(ARn) shl 5)
    or ARt;
end;

function Arm64AddW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $0B000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AddX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $8B000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64SubW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $4B000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64SubX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $CB000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64MulW(const ARd, ARn, ARm: Byte): UInt32;
begin
  { MADD Wd,Wn,Wm,WZR (Ra = 31). }
  Result := $1B007C00 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64MulX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $9B007C00 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AndW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $0A000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AndX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $8A000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64OrrW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $2A000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64OrrX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $AA000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64EorW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $4A000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64EorX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $CA000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64LslvW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $1AC02000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64LslvX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $9AC02000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64LsrvW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $1AC02400 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64LsrvX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $9AC02400 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AsrvW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $1AC02800 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AsrvX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $9AC02800 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64RorvW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $1AC02C00 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64RorvX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $9AC02C00 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64NegW(const ARd, ARm: Byte): UInt32;
begin
  { SUB Wd, WZR, Wm. }
  Result := $4B0003E0 or (UInt32(ARm) shl 16) or ARd;
end;

function Arm64NegX(const ARd, ARm: Byte): UInt32;
begin
  Result := $CB0003E0 or (UInt32(ARm) shl 16) or ARd;
end;

function Arm64ClzW(const ARd, ARn: Byte): UInt32;
begin
  Result := $5AC01000 or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64ClzX(const ARd, ARn: Byte): UInt32;
begin
  Result := $DAC01000 or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64RbitW(const ARd, ARn: Byte): UInt32;
begin
  Result := $5AC00000 or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64RbitX(const ARd, ARn: Byte): UInt32;
begin
  Result := $DAC00000 or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64CmpW(const ARn, ARm: Byte): UInt32;
begin
  { SUBS WZR, Wn, Wm (Rd = 31). }
  Result := $6B00001F or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5);
end;

function Arm64CmpX(const ARn, ARm: Byte): UInt32;
begin
  Result := $EB00001F or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5);
end;

function Arm64CsetW(const ARd, ACond: Byte): UInt32;
begin
  { CSINC Wd, WZR, WZR, invert(cond). invert = cond xor 1. }
  Result := $1A9F07E0 or ((UInt32(ACond) xor 1) shl 12) or ARd;
end;

function Arm64CselX(const ARd, ARn, ARm, ACond: Byte): UInt32;
begin
  Result := $9A800000 or (UInt32(ARm) shl 16) or (UInt32(ACond) shl 12)
    or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64MovReg(const ARd, ARn: Byte): UInt32;
begin
  { ORR Xd, XZR, Xn : base has Rn-field = 31 (XZR). }
  Result := $AA0003E0 or (UInt32(ARn) shl 16) or ARd;
end;

function Arm64MovzW(const ARd: Byte; const AImm16: UInt16;
  const AHw: Byte): UInt32;
begin
  Result := $52800000 or (UInt32(AHw) shl 21) or (UInt32(AImm16) shl 5) or ARd;
end;

function Arm64MovkW(const ARd: Byte; const AImm16: UInt16;
  const AHw: Byte): UInt32;
begin
  Result := $72800000 or (UInt32(AHw) shl 21) or (UInt32(AImm16) shl 5) or ARd;
end;

function Arm64MovzX(const ARd: Byte; const AImm16: UInt16;
  const AHw: Byte): UInt32;
begin
  Result := $D2800000 or (UInt32(AHw) shl 21) or (UInt32(AImm16) shl 5) or ARd;
end;

function Arm64MovkX(const ARd: Byte; const AImm16: UInt16;
  const AHw: Byte): UInt32;
begin
  Result := $F2800000 or (UInt32(AHw) shl 21) or (UInt32(AImm16) shl 5) or ARd;
end;

function Arm64AddImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
begin
  Result := $91000000 or ((AImm12 and $FFF) shl 10) or (UInt32(ARn) shl 5)
    or ARd;
end;

function Arm64Blr(const ARn: Byte): UInt32;
begin
  Result := $D63F0000 or (UInt32(ARn) shl 5);
end;

function Arm64Ret: UInt32;
begin
  Result := $D65F03C0;
end;

function Arm64StpX19X20PreIndex48: UInt32;
begin
  Result := $A9BD53F3;   { stp x19, x20, [sp, #-48]! }
end;

function Arm64StpX21X22Off16: UInt32;
begin
  Result := $A9015BF5;   { stp x21, x22, [sp, #16] }
end;

function Arm64LdpX21X22Off16: UInt32;
begin
  Result := $A9415BF5;   { ldp x21, x22, [sp, #16] }
end;

function Arm64LdpX19X20PostIndex48: UInt32;
begin
  Result := $A8C353F3;   { ldp x19, x20, [sp], #48 }
end;

function Arm64SignedImmFits(const AValue: Integer; const ABits: Byte): Boolean;
var
  Limit: Integer;
begin
  { 2^(ABits-1); ABits is 19 or 26 here, so this never overflows Int32. }
  Limit := 1 shl (ABits - 1);
  Result := (AValue >= -Limit) and (AValue <= Limit - 1);
end;

function Arm64BPlaceholder: UInt32;
begin
  Result := $14000000;   { b #0 }
end;

function Arm64BCondPlaceholder(const ACond: Byte): UInt32;
begin
  Result := $54000000 or (UInt32(ACond) and $F);   { b.cond #0 }
end;

function Arm64CbzWPlaceholder(const ARt: Byte): UInt32;
begin
  Result := $34000000 or ARt;   { cbz Wt, #0 }
end;

function Arm64CbnzWPlaceholder(const ARt: Byte): UInt32;
begin
  Result := $35000000 or ARt;   { cbnz Wt, #0 }
end;

{ ===================================================================== }
{  emit primitives                                                       }
{ ===================================================================== }

procedure Arm64EmitLdrW(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  ABuf.EmitU32(Arm64LdrW(ARt, ARn, AByteOffset));
end;

procedure Arm64EmitLdrX(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  ABuf.EmitU32(Arm64LdrX(ARt, ARn, AByteOffset));
end;

procedure Arm64EmitStrW(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  ABuf.EmitU32(Arm64StrW(ARt, ARn, AByteOffset));
end;

procedure Arm64EmitStrX(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  ABuf.EmitU32(Arm64StrX(ARt, ARn, AByteOffset));
end;

procedure Arm64EmitRet(const ABuf: TWasmCodeBuffer);
begin
  ABuf.EmitU32(Arm64Ret);
end;

procedure Arm64EmitMovzX(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AImm16: UInt16; const AHw: Byte);
begin
  ABuf.EmitU32(Arm64MovzX(ARd, AImm16, AHw));
end;

procedure Arm64EmitMovkX(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AImm16: UInt16; const AHw: Byte);
begin
  ABuf.EmitU32(Arm64MovkX(ARd, AImm16, AHw));
end;

procedure Arm64EmitLoadImm32(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AValue: UInt32);
begin
  { Always emit the movz so the register is fully written (clears the high
    half) even when the low 16 bits are zero. }
  ABuf.EmitU32(Arm64MovzW(ARd, UInt16(AValue and $FFFF), 0));
  if (AValue shr 16) <> 0 then
    ABuf.EmitU32(Arm64MovkW(ARd, UInt16((AValue shr 16) and $FFFF), 1));
end;

procedure Arm64EmitLoadImm64(const ABuf: TWasmCodeBuffer; const ARd: Byte;
  const AValue: UInt64);
begin
  Arm64EmitMovzX(ABuf, ARd, UInt16(AValue and $FFFF), 0);
  Arm64EmitMovkX(ABuf, ARd, UInt16((AValue shr 16) and $FFFF), 1);
  Arm64EmitMovkX(ABuf, ARd, UInt16((AValue shr 32) and $FFFF), 2);
  Arm64EmitMovkX(ABuf, ARd, UInt16((AValue shr 48) and $FFFF), 3);
end;

{ ===================================================================== }
{  the Wave-2 frame + branch patching                                    }
{ ===================================================================== }

procedure Arm64EmitPrologue(const ABuf: TWasmCodeBuffer);
begin
  ABuf.EmitU32(Arm64StpX19X20PreIndex48);      { stp x19,x20,[sp,#-48]! }
  ABuf.EmitU32(Arm64StpX21X22Off16);           { stp x21,x22,[sp,#16] }
  ABuf.EmitU32(Arm64StrX(ARM64_REG_LR, ARM64_REG_ZR, 32)); { str x30,[sp,#32] }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_REGFILE, 0));  { mov x19,x0 (regbase) }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_STORE, 1));    { mov x20,x1 (store) }
end;

procedure Arm64EmitEpochCapture(const ABuf: TWasmCodeBuffer;
  const AEpochOffset, ASnapshotOffset: NativeUInt);
begin
  { x21 := &Store.Epoch = x20 + offset. The offset is a small class-field
    offset; the common case fits ADD's 12-bit immediate, otherwise materialise
    it and add as a register. This is the LIVE epoch word x21 points at,
    reloaded at every back-edge. }
  if AEpochOffset < $1000 then
    ABuf.EmitU32(Arm64AddImmX(ARM64_REG_EPOCHADDR, ARM64_REG_STORE,
      UInt32(AEpochOffset)))
  else
  begin
    Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, UInt64(AEpochOffset));
    ABuf.EmitU32(Arm64AddX(ARM64_REG_EPOCHADDR, ARM64_REG_STORE, ARM64_REG_T0));
  end;
  { x22 := Store.EpochSnapshot — the SHARED per-invocation snapshot the
    outermost guest-entry seeded (jit-spec §6), NOT a fresh Store.Epoch read.
    Held callee-saved for the whole function, so a nested call that re-seeds
    the shared slot cannot disturb it. The snapshot field is 8-byte aligned;
    load it directly when the scaled offset fits LDR's imm12, else form the
    address in a scratch first. }
  if ((ASnapshotOffset and 7) = 0) and ((ASnapshotOffset shr 3) < $1000) then
    Arm64EmitLdrX(ABuf, ARM64_REG_EPOCH, ARM64_REG_STORE, UInt32(ASnapshotOffset))
  else
  begin
    Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, UInt64(ASnapshotOffset));
    ABuf.EmitU32(Arm64AddX(ARM64_REG_T0, ARM64_REG_STORE, ARM64_REG_T0));
    Arm64EmitLdrX(ABuf, ARM64_REG_EPOCH, ARM64_REG_T0, 0);
  end;
end;

procedure Arm64EmitEpilogue(const ABuf: TWasmCodeBuffer);
begin
  ABuf.EmitU32(Arm64LdrX(ARM64_REG_LR, ARM64_REG_ZR, 32));  { ldr x30,[sp,#32] }
  ABuf.EmitU32(Arm64LdpX21X22Off16);           { ldp x21,x22,[sp,#16] }
  ABuf.EmitU32(Arm64LdpX19X20PostIndex48);     { ldp x19,x20,[sp],#48 }
  ABuf.EmitU32(Arm64Ret);
end;

procedure Arm64ResolvePatches(const ABuf: TWasmCodeBuffer);
var
  I: Integer;
  P: TWasmJitPatch;
  Base, Instr: UInt32;
  Delta, Imm: Integer;
begin
  for I := 0 to ABuf.PatchCount - 1 do
  begin
    P := ABuf.GetPatch(I);
    Base := UInt32(P.Kind);
    Delta := ABuf.PatchDelta(I);   { signed byte displacement, multiple of 4 }
    Imm := Delta div 4;
    if (Base and $FC000000) = $14000000 then
    begin
      { B: imm26 in bits [25:0]. A displacement that overflows the field would
        silently wrap into a wrong jump; refuse it so the driver abandons the
        compile and the function stays interpreted (jit-spec §4.3). }
      if not Arm64SignedImmFits(Imm, 26) then
        raise EWasmJitBranchRange.CreateFmt(
          'JIT: B displacement %d does not fit imm26', [Delta]);
      Instr := Base or (UInt32(Imm) and $03FFFFFF);
    end
    else
    begin
      { B.cond / CBZ / CBNZ: imm19 in bits [23:5]. Same range guard, tighter
        field (imm19 = +-1 MiB of code). }
      if not Arm64SignedImmFits(Imm, 19) then
        raise EWasmJitBranchRange.CreateFmt(
          'JIT: conditional-branch displacement %d does not fit imm19', [Delta]);
      Instr := Base or ((UInt32(Imm) and $7FFFF) shl 5);
    end;
    ABuf.PatchU32(P.SiteOffset, Instr);
  end;
end;

{ ===================================================================== }
{  op templates                                                          }
{ ===================================================================== }

{ Local slot-addressing shorthands (Reg[k] = [x19 + k*8]). }
procedure LdW(const ABuf: TWasmCodeBuffer; const ARt: Byte; const AReg: UInt32);
begin
  Arm64EmitLdrW(ABuf, ARt, ARM64_REG_REGFILE, Arm64SlotByteOffset(AReg));
end;

procedure LdX(const ABuf: TWasmCodeBuffer; const ARt: Byte; const AReg: UInt32);
begin
  Arm64EmitLdrX(ABuf, ARt, ARM64_REG_REGFILE, Arm64SlotByteOffset(AReg));
end;

procedure StX(const ABuf: TWasmCodeBuffer; const ARt: Byte; const AReg: UInt32);
begin
  Arm64EmitStrX(ABuf, ARt, ARM64_REG_REGFILE, Arm64SlotByteOffset(AReg));
end;

type
  TArm64WordBin = function(const ARd, ARn, ARm: Byte): UInt32;

{ 32-bit two-operand ALU: w9 := op(w[A], w[B]); store the widened slot. }
procedure EmitAluW(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AWb: TArm64WordBin);
begin
  LdW(ABuf, ARM64_REG_T0, AIns.A);
  LdW(ABuf, ARM64_REG_T1, AIns.B);
  ABuf.EmitU32(AWb(ARM64_REG_T0, ARM64_REG_T0, ARM64_REG_T1));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitAluX(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AWb: TArm64WordBin);
begin
  LdX(ABuf, ARM64_REG_T0, AIns.A);
  LdX(ABuf, ARM64_REG_T1, AIns.B);
  ABuf.EmitU32(AWb(ARM64_REG_T0, ARM64_REG_T0, ARM64_REG_T1));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

{ 32-bit compare: cset from cmp(w[A], w[B]). }
procedure EmitRelW(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const ACond: Byte);
begin
  LdW(ABuf, ARM64_REG_T0, AIns.A);
  LdW(ABuf, ARM64_REG_T1, AIns.B);
  ABuf.EmitU32(Arm64CmpW(ARM64_REG_T0, ARM64_REG_T1));
  ABuf.EmitU32(Arm64CsetW(ARM64_REG_T0, ACond));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitRelX(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const ACond: Byte);
begin
  LdX(ABuf, ARM64_REG_T0, AIns.A);
  LdX(ABuf, ARM64_REG_T1, AIns.B);
  ABuf.EmitU32(Arm64CmpX(ARM64_REG_T0, ARM64_REG_T1));
  ABuf.EmitU32(Arm64CsetW(ARM64_REG_T0, ACond));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

{ Emit a placeholder branch and record its patch against the target label
  (= the target IR instruction index; the driver binds label i at instr i). }
procedure EmitBranchTo(const ABuf: TWasmCodeBuffer; const ATarget: UInt32);
var
  Site: Integer;
begin
  Site := ABuf.CurrentOffset;
  ABuf.AddPatch(Site, TWasmJitLabel(ATarget), Integer(Arm64BPlaceholder));
  ABuf.EmitU32(Arm64BPlaceholder);
end;

procedure EmitBCondTo(const ABuf: TWasmCodeBuffer; const ACond: Byte;
  const ATarget: TWasmJitLabel);
var
  Site: Integer;
  Base: UInt32;
begin
  Base := Arm64BCondPlaceholder(ACond);
  Site := ABuf.CurrentOffset;
  ABuf.AddPatch(Site, ATarget, Integer(Base));
  ABuf.EmitU32(Base);
end;

procedure EmitCbnzTo(const ABuf: TWasmCodeBuffer; const ARt: Byte;
  const ATarget: UInt32);
var
  Site: Integer;
  Base: UInt32;
begin
  Base := Arm64CbnzWPlaceholder(ARt);
  Site := ABuf.CurrentOffset;
  ABuf.AddPatch(Site, TWasmJitLabel(ATarget), Integer(Base));
  ABuf.EmitU32(Base);
end;

procedure EmitCbzTo(const ABuf: TWasmCodeBuffer; const ARt: Byte;
  const ATarget: UInt32);
var
  Site: Integer;
  Base: UInt32;
begin
  Base := Arm64CbzWPlaceholder(ARt);
  Site := ABuf.CurrentOffset;
  ABuf.AddPatch(Site, TWasmJitLabel(ATarget), Integer(Base));
  ABuf.EmitU32(Base);
end;

{ The back-edge epoch check (§6): if Store.Epoch <> the captured snapshot,
  call TrapNow(wtkEpochInterrupt) (which never returns); otherwise fall through.
  Requires x21 (&Epoch) and x22 (snapshot) set by the prologue's EpochCapture. }
procedure EmitEpochCheck(const ABuf: TWasmCodeBuffer);
var
  Cont: TWasmJitLabel;
begin
  Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_EPOCHADDR, 0); { x9 := *x21 }
  ABuf.EmitU32(Arm64CmpX(ARM64_REG_T0, ARM64_REG_EPOCH));    { cmp x9,x22 }
  Cont := ABuf.NewLabel;
  EmitBCondTo(ABuf, ARM64_COND_EQ, Cont);                    { b.eq Cont }
  ABuf.EmitU32(Arm64MovzW(0, UInt16(Ord(wtkEpochInterrupt)), 0)); { w0 := kind }
  Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, PtrUInt(@JitTrapKind));
  ABuf.EmitU32(Arm64Blr(ARM64_REG_T0));                      { blr -> no return }
  ABuf.BindLabel(Cont);
end;

{ A helper-call template: op ordinal in x0, operand(s) in x1(/x2), call the
  thunk in x9, store x0 to the destination slot (§1.4). Operands are always
  loaded as full 8-byte slots; the thunk narrows per op. }
procedure EmitLeafBinary(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  LdX(ABuf, 1, AIns.A);
  LdX(ABuf, 2, AIns.B);
  ABuf.EmitU32(Arm64MovzW(0, UInt16(Ord(AIns.Op)), 0));
  Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, PtrUInt(@JitOpBinary));
  ABuf.EmitU32(Arm64Blr(ARM64_REG_T0));
  StX(ABuf, 0, AIns.Dest);
end;

procedure EmitLeafUnary(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  LdX(ABuf, 1, AIns.A);
  ABuf.EmitU32(Arm64MovzW(0, UInt16(Ord(AIns.Op)), 0));
  Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, PtrUInt(@JitOpUnary));
  ABuf.EmitU32(Arm64Blr(ARM64_REG_T0));
  StX(ABuf, 0, AIns.Dest);
end;

procedure EmitBrTable(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32);
var
  N: UInt32;
  I: Integer;
  Target: UInt32;
begin
  { Aux block [N, s0 .. s(N-1)]; the last entry is the default (interp-spec
    matches Reg[A].U32 >= N-1). A compare chain is the simplest correct
    baseline (§12.3 Wave 2): for each non-default case, cmp the index and
    branch on equality; then an unconditional branch to the default. }
  N := IrAuxBlockCount(AAux, AIns.B);
  LdW(ABuf, ARM64_REG_T0, AIns.A);   { w9 := selector }
  for I := 0 to Integer(N) - 2 do
  begin
    Target := IrAuxBlockItem(AAux, AIns.B, UInt32(I));
    Arm64EmitLoadImm32(ABuf, ARM64_REG_T1, UInt32(I));
    ABuf.EmitU32(Arm64CmpW(ARM64_REG_T0, ARM64_REG_T1));
    EmitBCondTo(ABuf, ARM64_COND_EQ, TWasmJitLabel(Target));
  end;
  if N >= 1 then
  begin
    Target := IrAuxBlockItem(AAux, AIns.B, N - 1);
    EmitBranchTo(ABuf, Target);
  end;
end;

procedure EmitSelect(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  { Condition register rides in Imm (ifkSrcReg). If cond <> 0 -> A else B, a
    full 8-byte conditional copy, exactly the interpreter's iroSelect. }
  LdW(ABuf, ARM64_REG_T0, UInt32(AIns.Imm));   { w9 := cond (i32) }
  LdX(ABuf, ARM64_REG_T1, AIns.A);             { x10 := A }
  LdX(ABuf, ARM64_REG_T2, AIns.B);             { x11 := B }
  ABuf.EmitU32(Arm64CmpW(ARM64_REG_T0, ARM64_REG_ZR));  { cmp w9,#0 }
  ABuf.EmitU32(Arm64CselX(ARM64_REG_T1, ARM64_REG_T1, ARM64_REG_T2,
    ARM64_COND_NE));                           { csel x10, A, B, NE }
  StX(ABuf, ARM64_REG_T1, AIns.Dest);
end;

procedure EmitConst32(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  { i32/f32 const: low 32 bits of Imm, high half cleared (interp stores
    UInt64(UInt32(...))). }
  Arm64EmitLoadImm32(ABuf, ARM64_REG_T0, UInt32(AIns.Imm and $FFFFFFFF));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitConst64(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, UInt64(AIns.Imm));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

function Arm64LeafBinaryOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroI32DivS, iroI32DivU, iroI32RemS, iroI32RemU,
    iroI64DivS, iroI64DivU, iroI64RemS, iroI64RemU,
    iroF32Add, iroF32Sub, iroF32Mul, iroF32Div, iroF32Min, iroF32Max,
    iroF32Copysign,
    iroF32Eq, iroF32Ne, iroF32Lt, iroF32Gt, iroF32Le, iroF32Ge,
    iroF64Add, iroF64Sub, iroF64Mul, iroF64Div, iroF64Min, iroF64Max,
    iroF64Copysign,
    iroF64Eq, iroF64Ne, iroF64Lt, iroF64Gt, iroF64Le, iroF64Ge:
      Result := True;
  else
    Result := False;
  end;
end;

function Arm64LeafUnaryOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroI32Popcnt, iroI64Popcnt,
    iroI32WrapI64, iroI64ExtendI32S, iroI64ExtendI32U,
    iroI32Extend8S, iroI32Extend16S,
    iroI64Extend8S, iroI64Extend16S, iroI64Extend32S,
    iroF32Abs, iroF32Neg, iroF32Ceil, iroF32Floor, iroF32Trunc,
    iroF32Nearest, iroF32Sqrt,
    iroF64Abs, iroF64Neg, iroF64Ceil, iroF64Floor, iroF64Trunc,
    iroF64Nearest, iroF64Sqrt,
    iroF32DemoteF64, iroF64PromoteF32,
    iroI32TruncF32S, iroI32TruncF32U, iroI32TruncF64S, iroI32TruncF64U,
    iroI64TruncF32S, iroI64TruncF32U, iroI64TruncF64S, iroI64TruncF64U,
    iroF32ConvertI32S, iroF32ConvertI32U, iroF32ConvertI64S, iroF32ConvertI64U,
    iroF64ConvertI32S, iroF64ConvertI32U, iroF64ConvertI64S, iroF64ConvertI64U,
    iroI32ReinterpretF32, iroF32ReinterpretI32,
    iroI64ReinterpretF64, iroF64ReinterpretI64,
    iroI32TruncSatF32S, iroI32TruncSatF32U, iroI32TruncSatF64S,
    iroI32TruncSatF64U,
    iroI64TruncSatF32S, iroI64TruncSatF32U, iroI64TruncSatF64S,
    iroI64TruncSatF64U:
      Result := True;
  else
    Result := False;
  end;
end;

function Arm64InlineOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroMove,
    iroI32Const, iroI64Const, iroF32Const, iroF64Const,
    iroJump, iroBranchIf, iroBranchIfNot, iroBrTable, iroReturn, iroUnreachable,
    iroSelect,
    iroI32Eqz, iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
    iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
    iroI64Eqz, iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
    iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
    iroI32Clz, iroI32Ctz, iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or,
    iroI32Xor, iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
    iroI64Clz, iroI64Ctz, iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or,
    iroI64Xor, iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr:
      Result := True;
  else
    Result := False;
  end;
end;

function Arm64CanEmitOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := Arm64InlineOp(AOp) or Arm64LeafBinaryOp(AOp)
    or Arm64LeafUnaryOp(AOp);
end;

function Arm64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32): Boolean;
begin
  Result := True;
  case AIns.Op of
    iroMove:
      begin
        LdX(ABuf, ARM64_REG_T0, AIns.A);
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;

    { --- constants ---------------------------------------------------- }
    iroI32Const, iroF32Const: EmitConst32(ABuf, AIns);
    iroI64Const, iroF64Const: EmitConst64(ABuf, AIns);

    { --- control ------------------------------------------------------ }
    iroJump:
      begin
        if (AIns.Imm and IR_JUMP_SAFEPOINT) <> 0 then
          EmitEpochCheck(ABuf);
        EmitBranchTo(ABuf, AIns.A);
      end;
    iroBranchIf:
      begin
        LdW(ABuf, ARM64_REG_T0, AIns.A);
        EmitCbnzTo(ABuf, ARM64_REG_T0, AIns.B);
      end;
    iroBranchIfNot:
      begin
        LdW(ABuf, ARM64_REG_T0, AIns.A);
        EmitCbzTo(ABuf, ARM64_REG_T0, AIns.B);
      end;
    iroBrTable: EmitBrTable(ABuf, AIns, AAux);
    iroReturn: Arm64EmitEpilogue(ABuf);
    iroUnreachable:
      begin
        ABuf.EmitU32(Arm64MovzW(0, UInt16(Ord(wtkUnreachable)), 0));
        Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, PtrUInt(@JitTrapKind));
        ABuf.EmitU32(Arm64Blr(ARM64_REG_T0));
      end;

    { --- parametric --------------------------------------------------- }
    iroSelect: EmitSelect(ABuf, AIns);

    { --- i32 test/compare --------------------------------------------- }
    iroI32Eqz:
      begin
        LdW(ABuf, ARM64_REG_T0, AIns.A);
        ABuf.EmitU32(Arm64CmpW(ARM64_REG_T0, ARM64_REG_ZR));
        ABuf.EmitU32(Arm64CsetW(ARM64_REG_T0, ARM64_COND_EQ));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;
    iroI32Eq: EmitRelW(ABuf, AIns, ARM64_COND_EQ);
    iroI32Ne: EmitRelW(ABuf, AIns, ARM64_COND_NE);
    iroI32LtS: EmitRelW(ABuf, AIns, ARM64_COND_LT);
    iroI32LtU: EmitRelW(ABuf, AIns, ARM64_COND_LO);
    iroI32GtS: EmitRelW(ABuf, AIns, ARM64_COND_GT);
    iroI32GtU: EmitRelW(ABuf, AIns, ARM64_COND_HI);
    iroI32LeS: EmitRelW(ABuf, AIns, ARM64_COND_LE);
    iroI32LeU: EmitRelW(ABuf, AIns, ARM64_COND_LS);
    iroI32GeS: EmitRelW(ABuf, AIns, ARM64_COND_GE);
    iroI32GeU: EmitRelW(ABuf, AIns, ARM64_COND_HS);

    { --- i64 test/compare (result is i32) ----------------------------- }
    iroI64Eqz:
      begin
        LdX(ABuf, ARM64_REG_T0, AIns.A);
        ABuf.EmitU32(Arm64CmpX(ARM64_REG_T0, ARM64_REG_ZR));
        ABuf.EmitU32(Arm64CsetW(ARM64_REG_T0, ARM64_COND_EQ));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;
    iroI64Eq: EmitRelX(ABuf, AIns, ARM64_COND_EQ);
    iroI64Ne: EmitRelX(ABuf, AIns, ARM64_COND_NE);
    iroI64LtS: EmitRelX(ABuf, AIns, ARM64_COND_LT);
    iroI64LtU: EmitRelX(ABuf, AIns, ARM64_COND_LO);
    iroI64GtS: EmitRelX(ABuf, AIns, ARM64_COND_GT);
    iroI64GtU: EmitRelX(ABuf, AIns, ARM64_COND_HI);
    iroI64LeS: EmitRelX(ABuf, AIns, ARM64_COND_LE);
    iroI64LeU: EmitRelX(ABuf, AIns, ARM64_COND_LS);
    iroI64GeS: EmitRelX(ABuf, AIns, ARM64_COND_GE);
    iroI64GeU: EmitRelX(ABuf, AIns, ARM64_COND_HS);

    { --- i32 arithmetic/logical/shift ---------------------------------- }
    iroI32Add: EmitAluW(ABuf, AIns, @Arm64AddW);
    iroI32Sub: EmitAluW(ABuf, AIns, @Arm64SubW);
    iroI32Mul: EmitAluW(ABuf, AIns, @Arm64MulW);
    iroI32And: EmitAluW(ABuf, AIns, @Arm64AndW);
    iroI32Or: EmitAluW(ABuf, AIns, @Arm64OrrW);
    iroI32Xor: EmitAluW(ABuf, AIns, @Arm64EorW);
    iroI32Shl: EmitAluW(ABuf, AIns, @Arm64LslvW);
    iroI32ShrU: EmitAluW(ABuf, AIns, @Arm64LsrvW);
    iroI32ShrS: EmitAluW(ABuf, AIns, @Arm64AsrvW);
    iroI32Rotr: EmitAluW(ABuf, AIns, @Arm64RorvW);
    iroI32Rotl:
      begin
        LdW(ABuf, ARM64_REG_T0, AIns.A);
        LdW(ABuf, ARM64_REG_T1, AIns.B);
        ABuf.EmitU32(Arm64NegW(ARM64_REG_T1, ARM64_REG_T1));
        ABuf.EmitU32(Arm64RorvW(ARM64_REG_T0, ARM64_REG_T0, ARM64_REG_T1));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;
    iroI32Clz:
      begin
        LdW(ABuf, ARM64_REG_T0, AIns.A);
        ABuf.EmitU32(Arm64ClzW(ARM64_REG_T0, ARM64_REG_T0));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;
    iroI32Ctz:
      begin
        LdW(ABuf, ARM64_REG_T0, AIns.A);
        ABuf.EmitU32(Arm64RbitW(ARM64_REG_T0, ARM64_REG_T0));
        ABuf.EmitU32(Arm64ClzW(ARM64_REG_T0, ARM64_REG_T0));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;

    { --- i64 arithmetic/logical/shift ---------------------------------- }
    iroI64Add: EmitAluX(ABuf, AIns, @Arm64AddX);
    iroI64Sub: EmitAluX(ABuf, AIns, @Arm64SubX);
    iroI64Mul: EmitAluX(ABuf, AIns, @Arm64MulX);
    iroI64And: EmitAluX(ABuf, AIns, @Arm64AndX);
    iroI64Or: EmitAluX(ABuf, AIns, @Arm64OrrX);
    iroI64Xor: EmitAluX(ABuf, AIns, @Arm64EorX);
    iroI64Shl: EmitAluX(ABuf, AIns, @Arm64LslvX);
    iroI64ShrU: EmitAluX(ABuf, AIns, @Arm64LsrvX);
    iroI64ShrS: EmitAluX(ABuf, AIns, @Arm64AsrvX);
    iroI64Rotr: EmitAluX(ABuf, AIns, @Arm64RorvX);
    iroI64Rotl:
      begin
        LdX(ABuf, ARM64_REG_T0, AIns.A);
        LdX(ABuf, ARM64_REG_T1, AIns.B);
        ABuf.EmitU32(Arm64NegX(ARM64_REG_T1, ARM64_REG_T1));
        ABuf.EmitU32(Arm64RorvX(ARM64_REG_T0, ARM64_REG_T0, ARM64_REG_T1));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;
    iroI64Clz:
      begin
        LdX(ABuf, ARM64_REG_T0, AIns.A);
        ABuf.EmitU32(Arm64ClzX(ARM64_REG_T0, ARM64_REG_T0));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;
    iroI64Ctz:
      begin
        LdX(ABuf, ARM64_REG_T0, AIns.A);
        ABuf.EmitU32(Arm64RbitX(ARM64_REG_T0, ARM64_REG_T0));
        ABuf.EmitU32(Arm64ClzX(ARM64_REG_T0, ARM64_REG_T0));
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
      end;

  else
    if Arm64LeafBinaryOp(AIns.Op) then
      EmitLeafBinary(ABuf, AIns)
    else if Arm64LeafUnaryOp(AIns.Op) then
      EmitLeafUnary(ABuf, AIns)
    else
      Result := False;
  end;
end;

end.
