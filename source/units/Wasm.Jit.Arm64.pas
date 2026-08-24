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

  WAVE 2 CALLING CONVENTION (§5.3, O-J3). Because some numeric operations and
  every trap slow path still call helpers, the compiled body is not a leaf and
  cannot keep the register-file base in x0 (caller-saved,
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

  WAVE 3 — THE CALL FAMILY (§4.4, §4.5). A compiled call emits only
  marshal -> helper -> unmarshal; the tier decision, the call_indirect / ref
  resolution, and the tail-call frame replacement are Pascal, reusing the
  interpreter's own seam. See the block comment above TArm64CompiledEntry for
  the design, and Arm64InvokeCompiled for the tail-call trampoline loop that
  gives `return_call*` its O(1) native-stack property.

  UNCONFIRMED (epoch, §6): a compiled function calling an INTERPRETED one
  re-enters through Store.TierInvoke, which re-seeds Store.EpochSnapshot
  because its usual caller is an outermost guest entry. Arm64CallInterpreted
  restores the outer snapshot afterwards, so the compiled caller (which holds
  its own snapshot in x22) is unaffected; but WITHIN that nested interpreted
  callee the snapshot is the freshly read epoch, so an epoch bump that
  happened before the call is observed at the CALLER's next back-edge instead
  of inside the callee. The trap is delayed, never invented, and never lost
  while any back-edge remains. Closing it needs one interp-side change (seed
  the snapshot only when the GC frame chain is empty, or expose a nested
  interpreted-invoke entry point) and is out of this unit's ownership.

  Depends on Wasm.Jit.CodeBuffer and Wasm.Ir (§12.1) plus — new in Wave 2 —
  Wasm.Interp.Numeric and Wasm.Runtime.Traps, the leaves and trap helper the
  templates call (§1.4), and — new in Wave 3 — Wasm.Runtime.Store /
  Wasm.Runtime.Values / Wasm.Interp, the store and the shared frame helpers
  the call helpers reach. No cycle: none of those knows about the JIT.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
unit Wasm.Jit.Arm64;

{$I Shared.inc}
{ The Wave-3 call helpers copy flat slot blocks addressed as AArgs[i], which is
  pointer arithmetic on PWasmValue — the same convention Wasm.Interp uses for
  the register file it hands over. }
{$POINTERMATH ON}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Ir,
  Wasm.Jit.CodeBuffer,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

type
  { The borrowed IR-instruction pointer the helper-call templates bake (Fix C);
    the same shape Wasm.Interp exports, redeclared here so it is visible in this
    unit's interface without a circular use. }
  PWasmIrInstr = ^TWasmIrInstr;

  { A B/BL displacement that does not fit imm26 after any cond/CBZ veneer.
    B.cond/CBZ/CBNZ overflow is rewritten in place (invert + inserted B).
    Remaining imm26 overflow is an internal fault, not a silent decline. }
  EWasmJitBranchRange = class(EWasmError);

  { Per-instruction native-shape words handed over by the driver's
    AnalyzeGcFieldAccess; indexed by IR instruction index. }
  TArm64GcShapeArray = array[0..$FFFFFF] of UInt64;
  PArm64GcShapeArray = ^TArm64GcShapeArray;

  { One baked numeric field of a wave-11 inline struct.new: the source
    register slot, the cell byte offset, and the truncating store width —
    the same three numbers TWasmGcHeap's WriteField would have resolved at
    run time. }
  TWasmGcAllocField = record
    Slot: UInt32;
    Offset: UInt32;
    Width: Byte;
  end;

  { Per-instruction shape for the inline-allocation fast path. Word bit0
    enables; bits8-15 hold the field count, bits16-23 log2(CellSize) of the
    power-of-two size class. The engine type id is deliberately NOT here —
    it is per-store runtime state, loaded through the context chain so AOT
    artifacts stay instance/store-agnostic. }
  TWasmGcAllocShape = record
    Word: UInt64;
    Fields: array[0..15] of TWasmGcAllocField;
  end;

  PArm64GcAllocArray = ^TWasmGcAllocShape;

  { The store-relative offsets the fast path cannot probe itself (FHeap is
    private to Wasm.Runtime.Store); computed once per staged function from
    WasmJitOffsets and threaded beside the shape array. }
  TWasmGcAllocInfo = record
    FHeapOffset: NativeUInt;
    TierContextOffset: NativeUInt;
    EngineTypeIdsOffset: NativeUInt;
  end;

  PArm64RegCache = ^TArm64RegCache;

  TArm64RegCacheEntry = record
    Valid: Boolean;
    Dirty: Boolean;
    Slot: UInt32;
  end;

  { Compile-time state for value caches. The normal mode is the original
    clean, write-through block cache. Numeric loop functions may instead use a
    function-wide static allocation: a slot owns x12/x13/x26 on every control-flow
    edge, dirty values are written back only where the logical frame must be
    canonical, and a join needs no moves because all predecessors agree on the
    same slot-to-register map. }
  TArm64RegCache = record
    Entries: array[0..6] of TArm64RegCacheEntry;
    Next: Byte;
    StaticCount: Byte;
    StaticAllocation: Boolean;
    WriteBackDynamics: Boolean;
    UseCounts: PUInt32;
    VisibleSlots: PBoolean;
    SlotCount: UInt32;
    { Dynamic (round-robin victim) entries live at [DynBase .. DynBase+DynCount-1].
      Constant slots appended behind the leading statics raise StaticCount and
      shrink this range, so every dynamic-range loop derives from it rather
      than assuming the original four-register pool. }
    DynBase: Byte;
    DynCount: Byte;
    { First index owned by EnableConstSlots; below it sit the ordinary statics
      whose defining instructions must always emit. High value = none. }
    ConstFrom: Byte;
  end;

  TArm64WordBin = function(const ARd, ARn, ARm: Byte): UInt32;

const
  { --- register roles for the Wave-2 body (jit-spec §5.3) ----------------- }
  ARM64_REG_REGFILE = 19;  { x19 = @Values[Base], the register-file base }
  ARM64_REG_STORE = 20;    { x20 = the store pointer (for the epoch word) }
  ARM64_REG_EPOCHADDR = 21;{ x21 = &Store.Epoch }
  ARM64_REG_EPOCH = 22;    { x22 = the epoch captured at frame entry }
  { --- position-independent pins (aot-spec §1.2/§1.3/§4.3) --------------- }
  ARM64_REG_IRBASE = 23;   { x23 = @Fn^.Code[0], the IR-code base (entry arg x2) }
  ARM64_REG_HELPERTABLE = 24;  { x24 = the per-process helper-table base }
  ARM64_REG_MEMORY = 25;   { x25 = one memory instance, or proven-stable Base }
  ARM64_REG_ADDR = 8;      { x8: large-offset address / huge-imm scratch }
  ARM64_REG_T0 = 9;        { x9/w9 scratch }
  ARM64_REG_T1 = 10;       { x10/w10 scratch }
  ARM64_REG_T2 = 11;       { x11/w11 scratch }
  ARM64_REG_CACHE0 = 12;   { clean block-local value cache }
  ARM64_REG_CACHE1 = 13;   { clean block-local value cache }
  ARM64_REG_CACHE2 = 14;   { dynamic cache beside a static allocation }
  ARM64_REG_CACHE3 = 15;   { dynamic cache beside a static allocation }
  ARM64_REG_CACHE4 = 16;   { dynamic cache beside a static allocation }
  ARM64_REG_CACHE5 = 17;   { dynamic cache beside a static allocation }
  ARM64_REG_CACHE_STATIC2 = 26; { optional third function-wide allocation }
  { The proof-gated native self-recursion ABI reserves the same callee-saved
    register for its remaining logical-frame budget. Static allocation is
    explicitly denied this register whenever that ABI is selected. }
  ARM64_REG_NATIVE_BUDGET = 26;
  ARM64_REG_LR = 30;       { x30, the link register }
  ARM64_REG_ZR = 31;       { in data-processing, 31 encodes the zero register }
  { The SAME encoding 31 means SP in load/store (unsigned offset) and in the
    add/sub-immediate forms — which is exactly how the call templates reach
    their native-stack marshaling scratch (jit-spec §4.4). Named separately
    from ARM64_REG_ZR so a reader sees which meaning is intended. }
  ARM64_REG_SP = 31;

  { The interpreter frame slot is 8 bytes (Wasm.Runtime.Values.TWasmValue). The
    co-located test cross-checks this against
    Wasm.Interp.WasmJitFrameOffsets.ValueSlotSize so a slot-size change is
    caught rather than miscompiled. }
  ARM64_SLOT_SIZE = 8;

  { A scaled unsigned-offset LDR/STR imm12 field is 12 bits: the largest
    slot index the short form encodes is bounded by the tightest scale (a
    32-bit access scales the byte offset by 4, so imm12 = slot*8 div 4 =
    slot*2). Larger slots take the ADD-scratch path; this is an encoding
    threshold, not a compile decline. }
  ARM64_MAX_SLOT = 2047;

  { Historical single-`sub sp,#imm12` marshaling bound. Call sites above this
    use a multi-instruction SP adjust; the constant remains as the short-form
    threshold and for tests that name it. }
  ARM64_MAX_CALL_SLOTS = 256;

  { AArch64 condition codes (C1.2.4). Only the ones the relop templates use. }
  ARM64_COND_EQ = 0;
  ARM64_COND_NE = 1;
  ARM64_COND_HS = 2;   { unsigned >= (carry set) }
  ARM64_COND_LO = 3;   { unsigned <  (carry clear) }
  ARM64_COND_MI = 4;   { negative / ordered float < }
  ARM64_COND_VS = 6;   { overflow / unordered float }
  ARM64_COND_VC = 7;   { no overflow / ordered float }
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
{ Load/store register-offset form used by scalar linear-memory accesses.
  AUnsignedBase is the existing size/sign-specific unsigned-offset opcode
  prefix; i32 addresses use UXTW while memory64 uses an unextended X register. }
function Arm64MemRegOffset(const AUnsignedBase: UInt32;
  const ARt, ARn, ARm: Byte;
  const AAddr64: Boolean): UInt32;

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
function Arm64MaddX(const ARd, ARn, ARm, ARa: Byte): UInt32;
function Arm64SdivW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64SdivX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64UdivW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64UdivX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64MsubW(const ARd, ARn, ARm, ARa: Byte): UInt32;
function Arm64MsubX(const ARd, ARn, ARm, ARa: Byte): UInt32;
function Arm64AndW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64AndLowMaskImmW(const ARd, ARn, AOnes: Byte): UInt32;
function Arm64LslImmW(const ARd, ARn, AShift: Byte): UInt32;
function Arm64LsrImmW(const ARd, ARn, AShift: Byte): UInt32;
function Arm64AddImmW(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
function Arm64AndX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64OrrW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64OrrX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64EorW(const ARd, ARn, ARm: Byte): UInt32;
function Arm64EorX(const ARd, ARn, ARm: Byte): UInt32;

{ UBFIZ Wd,Wn,lsb,width: retain the low width bits and shift them left by
  lsb. The bounded (x & low_mask) << shift address idiom maps to this one
  instruction when width + shift <= 32. }
function Arm64UbfizW(const ARd, ARn, ALsb, AWidth: Byte): UInt32;

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

{ Scalar floating-point moves, arithmetic, comparisons and conversions. The
  integer register arguments carry exact wasm bit patterns; scalar FP register
  numbers use the same 0..31 encoding space. }
function Arm64FmovSFromW(const ASd, AWn: Byte): UInt32;
function Arm64FmovWFromS(const AWd, ASn: Byte): UInt32;
function Arm64FmovDFromX(const ADd, AXn: Byte): UInt32;
function Arm64FmovXFromD(const AXd, ADn: Byte): UInt32;
function Arm64FaddS(const ASd, ASn, ARm: Byte): UInt32;
function Arm64FsubS(const ASd, ASn, ARm: Byte): UInt32;
function Arm64FmulS(const ASd, ASn, ARm: Byte): UInt32;
function Arm64FdivS(const ASd, ASn, ARm: Byte): UInt32;
function Arm64FaddD(const ADd, ADn, ADm: Byte): UInt32;
function Arm64FsubD(const ADd, ADn, ADm: Byte): UInt32;
function Arm64FmulD(const ADd, ADn, ADm: Byte): UInt32;
function Arm64FdivD(const ADd, ADn, ADm: Byte): UInt32;
function Arm64FcmpS(const ASn, ARm: Byte): UInt32;
function Arm64FcmpD(const ADn, ADm: Byte): UInt32;
function Arm64ScvtfSW(const ASd, AWn: Byte): UInt32;
function Arm64ScvtfSX(const ASd, AXn: Byte): UInt32;
function Arm64ScvtfDW(const ADd, AWn: Byte): UInt32;
function Arm64ScvtfDX(const ADd, AXn: Byte): UInt32;
function Arm64UcvtfSW(const ASd, AWn: Byte): UInt32;
function Arm64UcvtfDW(const ADd, AWn: Byte): UInt32;
function Arm64FcvtSD(const ASd, ADn: Byte): UInt32;
function Arm64FcvtDS(const ADd, ASn: Byte): UInt32;
function Arm64SxtbW(const AWd, AWn: Byte): UInt32;
function Arm64SxthW(const AWd, AWn: Byte): UInt32;
function Arm64SxtbX(const AXd, AWn: Byte): UInt32;
function Arm64SxthX(const AXd, AWn: Byte): UInt32;
function Arm64SxtwX(const AXd, AWn: Byte): UInt32;

{ Universally available Advanced SIMD encodings used by the conservative
  native v128 subset. Register-file vectors occupy two adjacent slots and are
  loaded/stored as one Q register. ASize is 0/1/2/3 for 8/16/32/64-bit lanes. }
function Arm64LdrQ(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
function Arm64StrQ(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
function Arm64VecAnd(const AVd, AVn, AVm: Byte): UInt32;
function Arm64VecBic(const AVd, AVn, AVm: Byte): UInt32;
function Arm64VecOrr(const AVd, AVn, AVm: Byte): UInt32;
function Arm64VecEor(const AVd, AVn, AVm: Byte): UInt32;
function Arm64VecMvn(const AVd, AVn: Byte): UInt32;
function Arm64VecAdd(const AVd, AVn, AVm, ASize: Byte): UInt32;
function Arm64VecSub(const AVd, AVn, AVm, ASize: Byte): UInt32;
function Arm64VecDup(const AVd, ARn, ASize: Byte): UInt32;
function Arm64VecExtract(const ARd, AVn, ASize, ALane: Byte;
  const ASigned: Boolean): UInt32;

{ MOV Xd, Xn — register move, encoded as ORR Xd, XZR, Xn. }
function Arm64MovReg(const ARd, ARn: Byte): UInt32;

{ MOVZ/MOVK, both widths; the 32-bit MOVZ/MOVK zero-extend into Xd. }
function Arm64MovzW(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;
function Arm64MovkW(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;
function Arm64MovzX(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;
function Arm64MovkX(const ARd: Byte; const AImm16: UInt16; const AHw: Byte): UInt32;

{ ADD Xd,Xn,#imm12 (unsigned immediate, no shift): the epoch-word address
  computation x21 := x20 + StoreEpoch. With ARn = ARM64_REG_SP this is also
  `mov Xd, sp` (imm 0) and the scratch-slice address `add Xd, sp, #off`, and
  with ARd = ARn = ARM64_REG_SP it grows/shrinks the call scratch. }
function Arm64AddImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
{ ADD Xd,Xn,#imm12,LSL#12 — the high half of a two-instruction large add. }
function Arm64AddImmXShifted(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
{ SUB Xd,Xn,#imm12 (unsigned immediate, no shift). Used as
  `sub sp, sp, #frame` to reserve the call-marshaling scratch (§4.4). }
function Arm64SubImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
function Arm64SubImmXShifted(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
{ ADD/SUB (extended register), UXTX, so Rd/Rn may be SP. }
function Arm64AddExtX(const ARd, ARn, ARm: Byte): UInt32;
function Arm64SubExtX(const ARd, ARn, ARm: Byte): UInt32;
{ True when AByteOffset is a multiple of AScale and the scaled imm12 fits. }
function Arm64UnsignedOffsetFits(const AByteOffset, AScale: UInt32): Boolean;
{ SUBS Xd,Xn,#imm12, setting NZCV for a fused budget decrement/test. }
function Arm64SubsImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;

{ BLR Xn — branch with link to register (C6.2.35). Clobbers x30. }
function Arm64Blr(const ARn: Byte): UInt32;
{ RET (Xn) — return to Xn (default x30). ret = 0xD65F03C0. }
function Arm64Ret: UInt32;

{ The frame save/restore words. The position-independent prologue saves the SIX
  pinned callee-saved registers (x19..x24) plus x30 in a 64-byte frame; the
  epilogue restores them. Provided as builders so the encoder test can assert
  the bytes. }
function Arm64StpX19X20PreIndex64: UInt32;   { stp x19,x20,[sp,#-64]! }
function Arm64StpX21X22Off16: UInt32;        { stp x21,x22,[sp,#16] }
function Arm64StpX23X24Off32: UInt32;        { stp x23,x24,[sp,#32] }
function Arm64LdpX23X24Off32: UInt32;        { ldp x23,x24,[sp,#32] }
function Arm64LdpX21X22Off16: UInt32;        { ldp x21,x22,[sp,#16] }
function Arm64LdpX19X20PostIndex64: UInt32;  { ldp x19,x20,[sp],#64 }
function Arm64StpX19Lr(const AByteOffset: UInt32): UInt32;
function Arm64LdpX19Lr(const AByteOffset: UInt32): UInt32;
function Arm64StpX19LrPre(const AFrameBytes: UInt32): UInt32;
function Arm64LdpX19LrPost(const AFrameBytes: UInt32): UInt32;

{ True iff AValue fits a two's-complement signed field of ABits bits, i.e.
  -2^(ABits-1) <= AValue <= 2^(ABits-1)-1. The branch-displacement range guard
  (jit-spec §4.3): a B target must fit imm26 (ABits=26, +-128 MiB in
  instructions), a B.cond/CBZ/CBNZ target imm19 (ABits=19, +-1 MiB). The unit
  the caller passes is the already-scaled Imm = byteDelta div 4. }
function Arm64SignedImmFits(const AValue: Integer; const ABits: Byte): Boolean;

{ Branch instruction words with a ZERO displacement (the placeholder the patch
  list later fills). B is imm26<<2; B.cond / CBZ / CBNZ are imm19<<2. }
function Arm64BPlaceholder: UInt32;
function Arm64BlPlaceholder: UInt32;
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
procedure Arm64EmitLdrQ(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
procedure Arm64EmitStrQ(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
procedure Arm64EmitAddImmXAny(const ABuf: TWasmCodeBuffer;
  const ARd, ARn: Byte; const AImm: UInt32);
procedure Arm64EmitSubImmXAny(const ABuf: TWasmCodeBuffer;
  const ARd, ARn: Byte; const AImm: UInt32);
procedure Arm64EmitRet(const ABuf: TWasmCodeBuffer);
procedure Arm64EmitBlTo(const ABuf: TWasmCodeBuffer;
  const ATarget: TWasmJitLabel);
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
procedure Arm64EmitPrologueExtended(const ABuf: TWasmCodeBuffer);
{ Pin the per-process helper-table base in x24 (aot-spec §1.2/§4.3): loads it
  from the store field (x20 + AHelperTableOffset) ONCE, so every subsequent
  helper call is `ldr xT,[x24,#k*8]; blr xT`. Emitted by the driver right after
  the prologue, before the epoch capture; the exec-only encoder tests skip it
  (they emit no helper call), so the store is only dereferenced on the real
  compile path. AHelperTableOffset is WasmJitOffsets.StoreJitHelperTable. }
procedure Arm64EmitPinHelperTable(const ABuf: TWasmCodeBuffer;
  const AHelperTableOffset: NativeUInt);
procedure Arm64EmitPinMemory(const ABuf: TWasmCodeBuffer;
  const AMemoryIndex: UInt32; const ABaseOnly: Boolean);
procedure Arm64EmitEpochCapture(const ABuf: TWasmCodeBuffer;
  const AEpochOffset, ASnapshotOffset: NativeUInt);
procedure Arm64EmitNativeSelfBudget(const ABuf: TWasmCodeBuffer;
  const ARegisterCount: UInt32);
procedure Arm64EmitNativeCoreWrapperCall(const ABuf: TWasmCodeBuffer;
  const AParamCount, AParam0Reg, AParam1Reg, AResultReg: UInt32;
  const ACoreLabel: TWasmJitLabel);
procedure Arm64EmitNativeLeafEntry(const ABuf: TWasmCodeBuffer;
  const ARegisterCount: UInt32; const ACoreLabel,
  AExternalLabel: TWasmJitLabel);
procedure Arm64EmitEpilogue(const ABuf: TWasmCodeBuffer);
procedure Arm64EmitEpilogueExtended(const ABuf: TWasmCodeBuffer);

{ Emit an indirect call to helper slot AHelper through the pinned helper table:
  `ldr x9,[x24,#Ord(AHelper)*8]; blr x9` (aot-spec §1.2). Position-independent —
  the code names a stable slot index, never a baked address. }
procedure Arm64EmitCallHelper(const ABuf: TWasmCodeBuffer;
  const AHelper: TWasmAotHelper);

{ Compute @Fn^.Code[AInsIndex] into ADestReg from the pinned IR base x23
  (aot-spec §1.3): `add xDest,x23,#(i*stride)` when the offset fits ADD's imm12,
  else materialise the offset and add as a register. No baked IR pointer. }
procedure Arm64EmitIrInsPtr(const ABuf: TWasmCodeBuffer; const ADestReg: Byte;
  const AInsIndex: UInt32);

{ The per-process helper table for this backend: an array[TWasmAotHelper] of the
  live helper addresses, filled once (lazily) and returned by base pointer for
  RegisterJit to store in Store.JitHelperTable (aot-spec §4.3). }
function Arm64GetHelperTable: PPointer;

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
  AuxU32 block); pass the compiling function's AuxU32.

  Position-independent IR pointer (aot-spec §1.3). The helper-call templates
  (memory / table / ref / global / GC / v128 / ref-branch) hand the runtime
  dispatcher a pointer to the live IR instruction so it can read its fields.
  Rather than BAKE @Fn^.Code[i] as an absolute immediate (a heap address, wrong
  on any reload), the template computes it at run time from the pinned IR base
  x23 plus AInsIndex*SizeOf(TWasmIrInstr). The driver passes the instruction's
  IR index; @Fn^.Code[0] reaches the code through the entry's third argument,
  freshly per invocation — so nothing about the host process is ever baked, and
  this also subsumes the old Fix-C @AIns-by-reference concern. }
function Arm64CanEmitOp(const AOp: TWasmIrOp): Boolean;
function Arm64NativeVecOp(const AOp: TWasmIrOp): Boolean;
function Arm64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AUsePinnedMemory: Boolean = False;
  const ANativeScalarSelf: Boolean = False;
  const ANativeRegisterCount: UInt32 = 0;
  const ANativeParamReg: UInt32 = 0;
  const ANativeResultReg: UInt32 = 0;
  const ANativeCoreLabel: TWasmJitLabel = 0;
  const ANativeExhaustedLabel: TWasmJitLabel = 0): Boolean;
procedure Arm64InitRegCache(out ACache: TArm64RegCache);
procedure Arm64EnableStaticRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlots: array of UInt32);
procedure Arm64EnableConstSlots(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlots: array of UInt32;
  const ABits: array of UInt64);
function Arm64ConstSlotHost(const ACache: TArm64RegCache;
  const ASlot: UInt32; out AHost: Byte): Boolean;
procedure Arm64EnableDynamicWriteBack(var ACache: TArm64RegCache;
  const AUseCounts: PUInt32; const AVisibleSlots: PBoolean;
  const ASlotCount: UInt32);
procedure Arm64SeedNativeCoreCache(var ACache: TArm64RegCache;
  const AParamCount, AParam0Slot, AParam1Slot: UInt32;
  const AUseLeafCapacity: Boolean);
procedure Arm64FlushRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache);
procedure Arm64FlushDynamicRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache);
procedure Arm64InvalidateRegCache(var ACache: TArm64RegCache);
function Arm64EmitOpCached(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AAddr64, AUsePinnedMemory,
  AUsePinnedMemoryBase, AExtendedFrame: Boolean;
  var ACache: TArm64RegCache): Boolean; overload;
function Arm64EmitOpCached(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AAddr64, AUsePinnedMemory,
  AUsePinnedMemoryBase, AExtendedFrame, ANativeScalarSelf: Boolean;
  const ANativeRegisterCount, ANativeParamReg, ANativeResultReg: UInt32;
  const ANativeCoreLabel, ANativeExhaustedLabel: TWasmJitLabel;
  var ACache: TArm64RegCache;
  const AGcShapes: PArm64GcShapeArray;
  const AGcAlloc: PArm64GcAllocArray;
  const AGcAllocInfo: TWasmGcAllocInfo): Boolean; overload;
{ Numeric struct field access with a baked byte offset — the layout math is
  mirrored in the driver's AnalyzeGcFieldAccess, so no runtime resolution
  remains. Null refs trap the struct-specific kind before any load. }
procedure Arm64EmitGcFieldAccess(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AShape: UInt64;
  var ACache: TArm64RegCache);
{ Fixed-type scalar array access. A kind mismatch takes the unchanged helper
  route so the runtime's internal invariant remains authoritative; null and
  bounds traps are emitted in their original order on the native path. }
procedure Arm64EmitGcArrayAccess(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AInsIndex: UInt32; const AShape: UInt64;
  var ACache: TArm64RegCache);
{ Wave 11 — the inline struct.new fast path. Emits the free-list-hit
  allocation straight line (pop, bitmap, counters, header, baked numeric
  fields) and jumps to ADoneLabel; the caller binds its slow label at the
  unchanged generic (helper) emission so a miss or an exhausted class falls
  back to exactly the code that ran before. }
procedure Arm64EmitInlineStructNew(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AShape: TWasmGcAllocShape;
  const AInfo: TWasmGcAllocInfo; var ACache: TArm64RegCache;
  out ASlowLabel, ADoneLabel: TWasmJitLabel);
function Arm64CanUseI32Immediate(const AOp: TWasmIrOp;
  const AValue: UInt32): Boolean;
function Arm64EmitOpCachedImmediate(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AValue: UInt32;
  var ACache: TArm64RegCache): Boolean;
procedure Arm64EmitMaskedShiftCached(const ABuf: TWasmCodeBuffer;
  const ASource, ADest: UInt32; const AShift, AWidth: Byte;
  var ACache: TArm64RegCache);
procedure Arm64EmitCompareBranchCached(const ABuf: TWasmCodeBuffer;
  const ACompare, ABranch: TWasmIrInstr; var ACache: TArm64RegCache);

{ The INSTRUCTION-level half of the compile predicate. Arm64CanEmitOp answers
  "is there a template for this op"; this answers "can this particular
  instruction's template be emitted". Call-site arity is no longer a decline:
  large argument/result blocks take a multi-instruction SP adjust. Remaining
  False values are reserved for a future shape the template cannot emit. }
function Arm64CanEmitInstr(const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32): Boolean;

{ The compiled-entry invocation trampoline (jit-spec §4.5, §5.2) — what the
  driver's JitInvokeCompiled hook delegates to. Builds the callee's frame
  through the SHARED Wasm.Interp helpers, runs the machine code, marshals the
  results out; and, when the compiled body ended in a `return_call*`, LOOPS:
  it pops the frame and re-dispatches the replacement callee in this Pascal
  loop rather than by a native call, so a chain of N tail calls costs N
  iterations and ZERO native-stack growth — the O(1) property (§13 item 5).
  A tail callee that is interpreted or a host function is dispatched here too,
  so every tail target is reachable and the loop always terminates. }
procedure Arm64InvokeCompiled(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue);

{ The byte offset of register/slot k from the register-file base. }
function Arm64SlotByteOffset(const AReg: UInt32): UInt32;

implementation

uses
  Wasm.Interp,
  Wasm.Interp.Numeric,
  Wasm.Interp.Vector,
  Wasm.Jit.Vector,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Traps;

procedure Arm64CachedLoad(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ADest: Byte; const ASlot: UInt32); forward;
procedure Arm64CachedStore(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASrc: Byte; const ASlot: UInt32); forward;
procedure Arm64CachedAlu(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AWb: TArm64WordBin;
  var ACache: TArm64RegCache); forward;
procedure Arm64CachedRel(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ACond: Byte; const AWide: Boolean;
  var ACache: TArm64RegCache); forward;
function Arm64CachedHostForSlot(const ACache: TArm64RegCache;
  const ASlot: UInt32; out AHost: Byte): Boolean; forward;
function Arm64CachedSourceReg(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlot: UInt32;
  const ADefault: Byte): Byte; forward;
procedure Arm64CachedBinarySourceRegs(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ALeftSlot, ARightSlot: UInt32;
  out ALeft, ARight: Byte); forward;
function Arm64CachedDestReg(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlot: UInt32;
  const AExclude0, AExclude1, ADefault: Byte): Byte; forward;
procedure EmitCbnzTo(const ABuf: TWasmCodeBuffer; const ARt: Byte;
  const ATarget: UInt32); forward;
procedure EmitCbzTo(const ABuf: TWasmCodeBuffer; const ARt: Byte;
  const ATarget: UInt32); forward;
procedure EmitBranchTo(const ABuf: TWasmCodeBuffer;
  const ATarget: UInt32); forward;
procedure EmitNativeScalarSelfCallReg(const ABuf: TWasmCodeBuffer;
  const ARegisterCount: UInt32;
  const ACoreLabel, AExhaustedLabel: TWasmJitLabel); forward;

{ ===================================================================== }
{  cdecl helper thunks — the ABI boundary the emitted code calls (§1.4) }
{ ===================================================================== }

{ Delicate numeric ops (min/max/nearest, trapping and saturating float-to-int,
  unsigned i64-to-float, popcnt) route through these thunks, which call
  the EXACT Wasm.Interp.Numeric leaf the interpreter calls — so the remaining
  NaN/rounding behaviour and float-to-int trap kind + timing are identical by
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

function Arm64ScalarMemoryOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := AOp in [
    iroI32Load, iroI64Load, iroF32Load, iroF64Load,
    iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
    iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
    iroI64Load32S, iroI64Load32U,
    iroI32Store, iroI64Store, iroF32Store, iroF64Store,
    iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
    iroI64Store32];
end;

procedure LdW(const ABuf: TWasmCodeBuffer; const ARt: Byte;
  const AReg: UInt32); forward;
procedure LdX(const ABuf: TWasmCodeBuffer; const ARt: Byte;
  const AReg: UInt32); forward;
procedure StX(const ABuf: TWasmCodeBuffer; const ARt: Byte;
  const AReg: UInt32); forward;
procedure EmitBCondTo(const ABuf: TWasmCodeBuffer; const ACond: Byte;
  const ATarget: TWasmJitLabel); forward;

procedure Arm64EmitNativeCoreWrapperCall(const ABuf: TWasmCodeBuffer;
  const AParamCount, AParam0Reg, AParam1Reg, AResultReg: UInt32;
  const ACoreLabel: TWasmJitLabel);
begin
  { The external AAPCS wrapper bridges the canonical register file to the
    local scalar core ABI once. Recursive calls use x12; two-parameter leaves
    additionally receive their second scalar in x13. }
  LdX(ABuf, 12, AParam0Reg);
  if AParamCount = 2 then
    LdX(ABuf, 13, AParam1Reg);
  Arm64EmitBlTo(ABuf, ACoreLabel);
  StX(ABuf, 12, AResultReg);
end;

procedure Arm64EmitNativeLeafEntry(const ABuf: TWasmCodeBuffer;
  const ARegisterCount: UInt32; const ACoreLabel,
  AExternalLabel: TWasmJitLabel);
var
  FrameBytes: UInt32;
begin
  { Canonical entries pass their non-zero entry address in x4. A lightweight
    caller passes zero with the scalar arguments already in x12/x13. }
  EmitCbnzTo(ABuf, 4, UInt32(AExternalLabel));
  FrameBytes := ((ARegisterCount * ARM64_SLOT_SIZE + 15) and not UInt32(15))
    + 16;
  ABuf.EmitU32(Arm64StpX19LrPre(FrameBytes));
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_REGFILE, ARM64_REG_SP, 16));
  Arm64EmitBlTo(ABuf, ACoreLabel);
  ABuf.EmitU32(Arm64LdpX19LrPost(FrameBytes));
  Arm64EmitRet(ABuf);
end;

function Arm64MemoryAccessSize(const AOp: TWasmIrOp): UInt32;
begin
  case AOp of
    iroI32Load8S, iroI32Load8U, iroI64Load8S, iroI64Load8U,
    iroI32Store8, iroI64Store8: Result := 1;
    iroI32Load16S, iroI32Load16U, iroI64Load16S, iroI64Load16U,
    iroI32Store16, iroI64Store16: Result := 2;
    iroI32Load, iroF32Load, iroI64Load32S, iroI64Load32U,
    iroI32Store, iroF32Store, iroI64Store32: Result := 4;
  else
    Result := 8;
  end;
end;

function JitResolveMemory(const AStore: TWasmStore;
  const AMemoryIndex: PtrUInt): PWasmMemoryInst; cdecl;
var
  Ctx: PWasmInterpContext;
  Instance: TWasmModuleInstance;
begin
  Ctx := PWasmInterpContext(AStore.TierContext);
  Instance := Ctx^.Acts[Ctx^.Depth - 1].Instance;
  Result := AStore.JitMemoryAt(Instance.MemAddrs[AMemoryIndex]);
end;

procedure Arm64EmitTrapUnless(const ABuf: TWasmCodeBuffer;
  const AGoodCondition: Byte);
var
  Good: TWasmJitLabel;
begin
  Good := ABuf.NewLabel;
  EmitBCondTo(ABuf, AGoodCondition, Good);
  Arm64EmitLoadImm32(ABuf, 0, UInt32(Ord(wtkMemoryOutOfBounds)));
  Arm64EmitCallHelper(ABuf, aohTrapKind);
  ABuf.BindLabel(Good);
end;

procedure Arm64EmitScalarMemory(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAddr64, AUsePinnedMemory,
  AUsePinnedMemoryBase: Boolean; var ACache: TArm64RegCache);
var
  Layout: TWasmMemoryInst;
  AccessSize: UInt32;
  BaseReg: Byte;
  MemoryReg: Byte;
  Offset: UInt64;
  Folded: Boolean;
  LoadOp: UInt32;
  UseRegOffset: Boolean;
  AddrReg: Byte;
  ValueReg: Byte;

  procedure ResolveOperandReg(const ASlot: UInt32; const ADefault: Byte;
    out AReg: Byte);
  var
    Host: Byte;
  begin
    AReg := ADefault;
    if AUsePinnedMemoryBase and ACache.StaticAllocation and
      Arm64CachedHostForSlot(ACache, ASlot, Host) then
      AReg := Host
    else
      Arm64CachedLoad(ABuf, ACache, AReg, ASlot);
  end;

begin
  AccessSize := Arm64MemoryAccessSize(AIns.Op);
  { Imm stores the memarg's u64 bit pattern in the IR's signed immediate slot.
    Reinterpret it: a checked numeric conversion rejects offsets above
    High(Int64), even though memory64 admits the full u64 range. }
  Move(AIns.Imm, Offset, SizeOf(Offset));
  Folded := Offset <= WASM_STATIC_OFFSET_FOLD - UInt64(AccessSize);
  UseRegOffset := Offset = 0;

  { Resolve the module memory index through the current activation. The helper
    returns the live TWasmMemoryInst; generated code then applies that memory's
    statically selected strategy. The helper-table call keeps AOT bytes free of
    process addresses. }
  if AUsePinnedMemoryBase then
  begin
    { The driver permits a base-only pin only for zero-offset i32 guard-page
      accesses in a function that cannot call or grow memory. No operation in
      that frame can change Base, so x25 is the live base for its whole body. }
    BaseReg := ARM64_REG_MEMORY;
    MemoryReg := 0;
  end
  else if AUsePinnedMemory then
    MemoryReg := ARM64_REG_MEMORY
  else
  begin
    ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));
    Arm64EmitLoadImm32(ABuf, 1, AIns.B);
    Arm64EmitCallHelper(ABuf, aohResolveMemory);     { x0 := memory instance }
    MemoryReg := 0;
  end;
  { The memory instance may outlive a grow/remap, but Base remains live state:
    load it at every access even when the instance itself is pinned. The i32
    folded guard-page case does not inspect ByteSize at all, so avoid loading a
    field that the selected access strategy cannot consume. }
  if not AUsePinnedMemoryBase then
  begin
    BaseReg := 14;
    Arm64EmitLdrX(ABuf, BaseReg, MemoryReg,
      UInt32(PtrUInt(@Layout.Base) - PtrUInt(@Layout)));
    if AAddr64 or not Folded then
      Arm64EmitLdrX(ABuf, 15, MemoryReg,
        UInt32(PtrUInt(@Layout.ByteSize) - PtrUInt(@Layout)));
  end;
  { A helper-free base-pinned access may consume a statically allocated local
    directly as the register-offset index. Other shapes retain x10 because
    they reuse cache registers for the live memory instance fields. }
  ResolveOperandReg(AIns.A, 10, AddrReg);

  if AAddr64 and Folded then
  begin
    { Guard-assisted memory64: index > ByteSize can escape the reservation;
      index <= ByteSize is safe because the static offset plus access width is
      wholly absorbed by the reserved guard. }
    ABuf.EmitU32(Arm64CmpX(AddrReg, 15));
    Arm64EmitTrapUnless(ABuf, ARM64_COND_LS);
  end
  else if (not AAddr64) and Folded then
    { i32 guard-page strategy on a 64-bit POSIX backend: the 4 GiB reservation
      plus guard covers every widened index and this static offset. }
  else
  begin
    { Exact MemInBounds subtraction form: index <= size; offset <= size-index;
      access width <= size-index-offset. No addition can wrap. }
    ABuf.EmitU32(Arm64CmpX(AddrReg, 15));
    Arm64EmitTrapUnless(ABuf, ARM64_COND_LS);
    ABuf.EmitU32(Arm64SubX(15, 15, AddrReg));
    Arm64EmitLoadImm64(ABuf, 11, Offset);
    ABuf.EmitU32(Arm64CmpX(11, 15));
    Arm64EmitTrapUnless(ABuf, ARM64_COND_LS);
    ABuf.EmitU32(Arm64SubX(15, 15, 11));
    Arm64EmitLoadImm32(ABuf, 11, AccessSize);
    ABuf.EmitU32(Arm64CmpX(11, 15));
    Arm64EmitTrapUnless(ABuf, ARM64_COND_LS);
  end;

  if not UseRegOffset then
  begin
    if BaseReg <> 14 then
    begin
      ABuf.EmitU32(Arm64MovReg(14, BaseReg));
      BaseReg := 14;
    end;
    ABuf.EmitU32(Arm64AddX(BaseReg, BaseReg, AddrReg));
    Arm64EmitLoadImm64(ABuf, 11, Offset);
    ABuf.EmitU32(Arm64AddX(BaseReg, BaseReg, 11));
  end;

  case AIns.Op of
    iroI32Load8U, iroI64Load8U: LoadOp := $39400000;
    iroI32Load8S: LoadOp := $39C00000;
    iroI64Load8S: LoadOp := $39800000;
    iroI32Load16U, iroI64Load16U: LoadOp := $79400000;
    iroI32Load16S: LoadOp := $79C00000;
    iroI64Load16S: LoadOp := $79800000;
    iroI32Load, iroF32Load, iroI64Load32U: LoadOp := $B9400000;
    iroI64Load32S: LoadOp := $B9800000;
    iroI64Load, iroF64Load: LoadOp := $F9400000;
    iroI32Store8, iroI64Store8:
      begin
        ResolveOperandReg(AIns.Dest, 11, ValueReg);
        if UseRegOffset then
          ABuf.EmitU32(Arm64MemRegOffset($39000000, ValueReg, BaseReg,
            AddrReg, AAddr64))
        else
          ABuf.EmitU32($39000000 or (UInt32(BaseReg) shl 5) or ValueReg);
        Exit;
      end;
    iroI32Store16, iroI64Store16:
      begin
        ResolveOperandReg(AIns.Dest, 11, ValueReg);
        if UseRegOffset then
          ABuf.EmitU32(Arm64MemRegOffset($79000000, ValueReg, BaseReg,
            AddrReg, AAddr64))
        else
          ABuf.EmitU32($79000000 or (UInt32(BaseReg) shl 5) or ValueReg);
        Exit;
      end;
    iroI32Store, iroF32Store, iroI64Store32:
      begin
        ResolveOperandReg(AIns.Dest, 11, ValueReg);
        if UseRegOffset then
          ABuf.EmitU32(Arm64MemRegOffset($B9000000, ValueReg, BaseReg,
            AddrReg, AAddr64))
        else
          ABuf.EmitU32($B9000000 or (UInt32(BaseReg) shl 5) or ValueReg);
        Exit;
      end;
    iroI64Store, iroF64Store:
      begin
        ResolveOperandReg(AIns.Dest, 11, ValueReg);
        if UseRegOffset then
          ABuf.EmitU32(Arm64MemRegOffset($F9000000, ValueReg, BaseReg,
            AddrReg, AAddr64))
        else
          ABuf.EmitU32($F9000000 or (UInt32(BaseReg) shl 5) or ValueReg);
        Exit;
      end;
  else
    Exit;
  end;
  if UseRegOffset then
    ABuf.EmitU32(Arm64MemRegOffset(LoadOp, 11, BaseReg, AddrReg, AAddr64))
  else
    ABuf.EmitU32(LoadOp or (UInt32(BaseReg) shl 5) or 11);
  Arm64CachedStore(ABuf, ACache, 11, AIns.Dest);
end;

function Arm64EmitOpCached(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AAddr64, AUsePinnedMemory,
  AUsePinnedMemoryBase, AExtendedFrame: Boolean;
  var ACache: TArm64RegCache): Boolean; overload;
begin
  Result := Arm64EmitOpCached(ABuf, AIns, AAux, AInsIndex, AAddr64,
    AUsePinnedMemory, AUsePinnedMemoryBase, AExtendedFrame, False, 0, 0, 0,
    0, 0, ACache, nil, nil, Default(TWasmGcAllocInfo));
end;

procedure Arm64EmitGcFieldAccess(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AShape: UInt64;
  var ACache: TArm64RegCache);
var
  Offset: UInt32;
  Width, AccessSize: Byte;
  LdrOp, StrOp: UInt32;
  Signed: Boolean;
  Val: Byte;
  GoodLabel: TWasmJitLabel;

  function LoadWord(const APrefix: UInt32; const ARt, ARn: Byte;
    const AOffset: UInt32): UInt32;
  begin
    { Unsigned-offset form: imm12 is scaled by the access size. }
    Result := APrefix or ((AOffset div AccessSize) shl 10)
      or (UInt32(ARn) shl 5) or ARt;
  end;

begin
  Offset := UInt32(AShape shr 16);
  Width := Byte((AShape shr 8) and $FF);
  Signed := (AShape and 2) <> 0;
  AccessSize := Width;

  { The reference arrives in a value slot; T0 carries it for the null check
    and stays the base address. }
  Arm64CachedLoad(ABuf, ACache, ARM64_REG_T0, AIns.A);
  GoodLabel := ABuf.NewLabel;
  EmitCbnzTo(ABuf, ARM64_REG_T0, GoodLabel);
  Arm64EmitLoadImm32(ABuf, 0, Ord(wtkNullStructReference));
  Arm64EmitCallHelper(ABuf, aohTrapKind);
  ABuf.BindLabel(GoodLabel);

  case AIns.Op of
    iroStructGet, iroStructGetS, iroStructGetU:
      begin
        if Width = 1 then
          if Signed then
            LdrOp := $39C00000
          else
            LdrOp := $39400000
        else if Width = 2 then
          if Signed then
            LdrOp := $79C00000
          else
            LdrOp := $79400000
        else if Width = 4 then
          LdrOp := $B9400000
        else
          LdrOp := $F9400000;
        ABuf.EmitU32(LoadWord(LdrOp, ARM64_REG_T1, ARM64_REG_T0, Offset));
        { W-form loads zero the high half, which is exactly the canonical
          slot rule; the x load fills it verbatim. }
        StX(ABuf, ARM64_REG_T1, AIns.Dest);
      end;
    iroStructSet:
      begin
        Val := Arm64CachedSourceReg(ABuf, ACache, AIns.B,
          ARM64_REG_T1);
        if Width = 1 then
          StrOp := $39000000
        else if Width = 2 then
          StrOp := $79000000
        else if Width = 4 then
          StrOp := $B9000000
        else
          StrOp := $F9000000;
        ABuf.EmitU32(LoadWord(StrOp, Val, ARM64_REG_T0, Offset));
      end;
  end;
end;

procedure Arm64EmitGcArrayAccess(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AInsIndex: UInt32; const AShape: UInt64;
  var ACache: TArm64RegCache);
var
  ObjSlot, IndexSlot: UInt32;
  Width: Byte;
  LdrOp, StrOp: UInt32;
  Signed: Boolean;
  Val: Byte;
  NonNull, KindFallback, InBounds, Done: TWasmJitLabel;

  function ScaledRegOffset(const APrefix: UInt32; const ARt: Byte): UInt32;
  begin
    { S=1 scales Wm by the access width; the array index is i32, so UXTW
      keeps its full unsigned range. }
    Result := Arm64MemRegOffset(APrefix, ARt, ARM64_REG_T0,
      ARM64_REG_T1, False) or $1000;
  end;

begin
  Width := Byte((AShape shr 8) and $FF);
  Signed := (AShape and 2) <> 0;
  if AIns.Op = iroArraySet then
  begin
    ObjSlot := AIns.Dest;
    IndexSlot := AIns.A;
  end
  else
  begin
    ObjSlot := AIns.A;
    IndexSlot := AIns.B;
  end;

  Arm64CachedLoad(ABuf, ACache, ARM64_REG_T0, ObjSlot);
  Arm64CachedLoad(ABuf, ACache, ARM64_REG_T1, IndexSlot);
  NonNull := ABuf.NewLabel;
  KindFallback := ABuf.NewLabel;
  InBounds := ABuf.NewLabel;
  Done := ABuf.NewLabel;

  EmitCbnzTo(ABuf, ARM64_REG_T0, NonNull);
  Arm64EmitLoadImm32(ABuf, 0, Ord(wtkNullArrayReference));
  Arm64EmitCallHelper(ABuf, aohTrapKind);
  ABuf.BindLabel(NonNull);

  { Preserve ResolveElement's null -> layout/kind -> bounds order. The kind
    mismatch is validator-unreachable, so the cold helper call exists only to
    retain its exact EWasmInternal invariant rather than inventing a backend
    error path. }
  Arm64EmitLdrW(ABuf, ARM64_REG_T2, ARM64_REG_T0, 0);
  ABuf.EmitU32(Arm64LsrImmW(ARM64_REG_T2, ARM64_REG_T2,
    WASM_OBJ_KIND_SHIFT));
  ABuf.EmitU32(Arm64AndLowMaskImmW(ARM64_REG_T2, ARM64_REG_T2, 3));
  ABuf.EmitU32(Arm64SubImmX(ARM64_REG_T2, ARM64_REG_T2, Ord(wokArray)));
  ABuf.EmitU32(Arm64CmpX(ARM64_REG_T2, ARM64_REG_ZR));
  EmitBCondTo(ABuf, ARM64_COND_NE, KindFallback);

  Arm64EmitLdrW(ABuf, ARM64_REG_T2, ARM64_REG_T0,
    WASM_ARRAY_LENGTH_OFFSET);
  ABuf.EmitU32(Arm64CmpW(ARM64_REG_T1, ARM64_REG_T2));
  EmitBCondTo(ABuf, ARM64_COND_LO, InBounds);
  Arm64EmitLoadImm32(ABuf, 0, Ord(wtkArrayOutOfBounds));
  Arm64EmitCallHelper(ABuf, aohTrapKind);
  ABuf.BindLabel(InBounds);
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_T0, ARM64_REG_T0,
    WASM_ARRAY_ELEMS_OFFSET));

  if AIns.Op = iroArraySet then
  begin
    Val := Arm64CachedSourceReg(ABuf, ACache, AIns.B, ARM64_REG_T2);
    if Width = 1 then
      StrOp := $39000000
    else if Width = 2 then
      StrOp := $79000000
    else if Width = 4 then
      StrOp := $B9000000
    else
      StrOp := $F9000000;
    ABuf.EmitU32(ScaledRegOffset(StrOp, Val));
    { The v1 barrier is deliberately empty and a store cannot collect, so the
      direct reference write has the same visibility semantics as ArraySet.
      A non-empty future barrier must make reference shapes decline here or
      gain a dedicated PIC helper before it changes collector policy. }
  end
  else
  begin
    if Width = 1 then
      if Signed then
        LdrOp := $39C00000
      else
        LdrOp := $39400000
    else if Width = 2 then
      if Signed then
        LdrOp := $79C00000
      else
        LdrOp := $79400000
    else if Width = 4 then
      LdrOp := $B9400000
    else
      LdrOp := $F9400000;
    ABuf.EmitU32(ScaledRegOffset(LdrOp, ARM64_REG_T2));
    Arm64CachedStore(ABuf, ACache, ARM64_REG_T2, AIns.Dest);
  end;
  EmitBranchTo(ABuf, UInt32(Done));

  ABuf.BindLabel(KindFallback);
  { ResolveElement raises before consulting index/value on this path. Publish
    the already-loaded object so JitRtDispatch observes the exact ref even if
    its source slot currently lives only in the dynamic cache. }
  StX(ABuf, ARM64_REG_T0, ObjSlot);
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));
  ABuf.EmitU32(Arm64MovReg(1, ARM64_REG_REGFILE));
  Arm64EmitIrInsPtr(ABuf, 2, AInsIndex);
  Arm64EmitCallHelper(ABuf, aohRtDispatch);
  ABuf.BindLabel(Done);
end;

procedure Arm64EmitInlineStructNew(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AShape: TWasmGcAllocShape;
  const AInfo: TWasmGcAllocInfo; var ACache: TArm64RegCache;
  out ASlowLabel, ADoneLabel: TWasmJitLabel);
const
  { Two scratches beyond the named three. The caller has flushed and
    invalidated the value cache before this template runs, and a function
    containing an allocation is never static-cache eligible (iroStructNew
    fails StaticCacheOp), so the write-through hosts are dead metadata here. }
  R3 = ARM64_REG_CACHE0;   { x12 }
  R4 = ARM64_REG_CACHE1;   { x13 }
var
  GO: TWasmJitGcOffsets;
  FO: TWasmJitFrameOffsets;
  Count, Log2Cell, F: Integer;
  FreeOff: UInt32;
begin
  GO := WasmJitGcHeapOffsets;
  FO := WasmJitFrameOffsets;
  Count := Integer((AShape.Word shr 8) and $FF);
  Log2Cell := Integer((AShape.Word shr 16) and $FF);
  FreeOff := UInt32(GO.HeapFFree0) +
    UInt32((AShape.Word shr 24) and $FF) * 8;
  ASlowLabel := ABuf.NewLabel;
  ADoneLabel := ABuf.NewLabel;

  { The engine type id is per-store runtime state: walk the context chain to
    THIS activation's instance (the walk is call-safe — an activation's
    Instance field is fixed for its lifetime) and load EngineTypeIds[Imm].
    wokStruct is ordinal 0, so a struct header's kind bits are zero and the
    whole word is markState | typeId shl 32, written as two halves. }
  Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_STORE,
    UInt32(AInfo.TierContextOffset));
  Arm64EmitLdrX(ABuf, R3, ARM64_REG_T0, UInt32(FO.CtxDepth));
  ABuf.EmitU32(Arm64SubImmX(R3, R3, 1));
  Arm64EmitLdrX(ABuf, ARM64_REG_T1, ARM64_REG_T0, UInt32(FO.CtxActs));
  ABuf.EmitU32(Arm64MovzW(ARM64_REG_T0, UInt16(FO.ActStride), 0));
  ABuf.EmitU32(Arm64MaddX(R3, R3, ARM64_REG_T0, ARM64_REG_T1));
  Arm64EmitLdrX(ABuf, R3, R3, UInt32(FO.ActInstance));
  Arm64EmitLdrX(ABuf, R3, R3, UInt32(AInfo.EngineTypeIdsOffset));
  Arm64EmitLdrW(ABuf, ARM64_REG_T0, R3, UInt32(AIns.Imm) * 4);

  { Free-list head for this size class; a miss falls to the unchanged
    helper path, which stays THE collect safepoint (ADR-0011). }
  Arm64EmitLdrX(ABuf, ARM64_REG_T1, ARM64_REG_STORE,
    UInt32(AInfo.FHeapOffset));
  Arm64EmitLdrX(ABuf, ARM64_REG_T2, ARM64_REG_T1, FreeOff);
  EmitCbzTo(ABuf, ARM64_REG_T2, UInt32(ASlowLabel));

  { Pop FIRST: FFree[class] := [head + LINK]. The link word shares its qword
    with the header low half this very sequence is about to write, so the
    header stores MUST NOT precede it — and the pop parks the new head in R3,
    leaving T0's parked type id alone. }
  Arm64EmitLdrX(ABuf, R3, ARM64_REG_T2,
    WASM_GC_FREE_LINK_OFFSET);
  Arm64EmitStrX(ABuf, R3, ARM64_REG_T1, FreeOff);

  { Header high half — consumes the parked type id. }
  Arm64EmitStrW(ABuf, ARM64_REG_T0, ARM64_REG_T2, 4);

  { Header low half = mark state; the next cycle's polarity flip (H8)
    unmarks exactly like an Allocate-written header. }
  Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_T1,
    UInt32(GO.HeapMarkState));
  Arm64EmitStrW(ABuf, ARM64_REG_T0, ARM64_REG_T2, 0);

  { Bitmap: word = Allocated[(head-Base)/CellSize div 32] |=
    1 shl (... mod 32). CellSize is a power-of-two class size, so the
    division is one shift and the cell index needs no magic multiply. }
  Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_T2,
    WASM_GC_FREE_BLOCK_OFFSET);
  Arm64EmitLdrX(ABuf, ARM64_REG_T1, ARM64_REG_T0, UInt32(GO.BlockBase));
  ABuf.EmitU32(Arm64SubX(ARM64_REG_T1, ARM64_REG_T2, ARM64_REG_T1));
  ABuf.EmitU32(Arm64LsrImmW(ARM64_REG_T1, ARM64_REG_T1, Byte(Log2Cell)));
  Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_T0,
    UInt32(GO.BlockAllocated));
  ABuf.EmitU32(Arm64LsrImmW(R3, ARM64_REG_T1, 5));            { word idx }
  ABuf.EmitU32(Arm64AndLowMaskImmW(R4, ARM64_REG_T1, 31));    { bit no }
  ABuf.EmitU32(Arm64MovzW(ARM64_REG_T1, 1, 0));
  ABuf.EmitU32(Arm64LslvW(ARM64_REG_T1, ARM64_REG_T1, R4));   { mask }
  ABuf.EmitU32(Arm64MemRegOffset($B9400000, R4, ARM64_REG_T0, R3, True));
  ABuf.EmitU32(Arm64OrrW(R4, R4, ARM64_REG_T1));
  ABuf.EmitU32(Arm64MemRegOffset($B9000000, R4, ARM64_REG_T0, R3, True));

  { Host-visible counters. Each reloads the heap base — the pop above
    consumed the only copy — because three live base pointers do not fit
    the scratch set and one LDR is cheaper than a fourth register would be.
    CellSize == the class size == 2^Log2Cell exactly on this path. }
  Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_STORE,
    UInt32(AInfo.FHeapOffset));
  Arm64EmitLdrX(ABuf, ARM64_REG_T1, ARM64_REG_T0,
    UInt32(GO.HeapBytesLive));
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_T1, ARM64_REG_T1,
    UInt32(1) shl Log2Cell));
  Arm64EmitStrX(ABuf, ARM64_REG_T1, ARM64_REG_T0,
    UInt32(GO.HeapBytesLive));
  Arm64EmitLdrX(ABuf, ARM64_REG_T1, ARM64_REG_T0,
    UInt32(GO.HeapBytesAllocated));
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_T1, ARM64_REG_T1,
    UInt32(1) shl Log2Cell));
  Arm64EmitStrX(ABuf, ARM64_REG_T1, ARM64_REG_T0,
    UInt32(GO.HeapBytesAllocated));
  Arm64EmitLdrX(ABuf, ARM64_REG_T1, ARM64_REG_T0,
    UInt32(GO.HeapObjectCount));
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_T1, ARM64_REG_T1, 1));
  Arm64EmitStrX(ABuf, ARM64_REG_T1, ARM64_REG_T0,
    UInt32(GO.HeapObjectCount));

  { Numeric field fills at baked offsets, sources straight from the
    canonical register file (the cache was invalidated on entry). }
  for F := 0 to Count - 1 do
  begin
    Arm64EmitLdrX(ABuf, R3, ARM64_REG_REGFILE,
      Arm64SlotByteOffset(AShape.Fields[F].Slot));
    case AShape.Fields[F].Width of
      1: ABuf.EmitU32($39000000 or AShape.Fields[F].Offset or
           (UInt32(ARM64_REG_T2) shl 5) or R3);
      2: ABuf.EmitU32($79000000 or ((UInt32(AShape.Fields[F].Offset)
           div 2) shl 10) or (UInt32(ARM64_REG_T2) shl 5) or R3);
      4: ABuf.EmitU32($B9000000 or ((UInt32(AShape.Fields[F].Offset)
           div 4) shl 10) or (UInt32(ARM64_REG_T2) shl 5) or R3);
    else
      ABuf.EmitU32($F9000000 or ((UInt32(AShape.Fields[F].Offset)
        div 8) shl 10) or (UInt32(ARM64_REG_T2) shl 5) or R3);
    end;
  end;

  { Publish the reference last. Nothing between the header store and here
    can collect — the fast path contains no safepoint — so publish-first's
    ordering obligation is met trivially, and a source slot that equals
    Dest was read before this overwrite. }
  StX(ABuf, ARM64_REG_T2, AIns.Dest);
  EmitBranchTo(ABuf, UInt32(ADoneLabel));
end;

function Arm64EmitOpCached(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AAddr64, AUsePinnedMemory,
  AUsePinnedMemoryBase, AExtendedFrame, ANativeScalarSelf: Boolean;
  const ANativeRegisterCount, ANativeParamReg, ANativeResultReg: UInt32;
  const ANativeCoreLabel, ANativeExhaustedLabel: TWasmJitLabel;
  var ACache: TArm64RegCache;
  const AGcShapes: PArm64GcShapeArray;
  const AGcAlloc: PArm64GcAllocArray;
  const AGcAllocInfo: TWasmGcAllocInfo): Boolean; overload;
var
  Source, Dest: Byte;
  ArgSlot, ResultSlot: UInt32;
  ConstHost: Byte;
  SlowLabel, DoneLabel: TWasmJitLabel;
begin
  Result := True;
  if Arm64ScalarMemoryOp(AIns.Op) then
  begin
    { The base-pinned static-cache shape never consumes x14/x15 itself. Every
      other scalar-memory shape does, so discard dynamic-cache metadata before
      those scratch registers are reused for Base/ByteSize. }
    if not AUsePinnedMemoryBase then
      Arm64InvalidateRegCache(ACache);
    Arm64EmitScalarMemory(ABuf, AIns, AAddr64, AUsePinnedMemory,
      AUsePinnedMemoryBase, ACache);
    Exit;
  end;
  case AIns.Op of
    iroMove:
      begin
        Source := Arm64CachedSourceReg(ABuf, ACache, AIns.A,
          ARM64_REG_T0);
        Dest := Arm64CachedDestReg(ABuf, ACache, AIns.Dest, Source,
          ARM64_REG_ZR, ARM64_REG_T0);
        if Dest <> Source then
          ABuf.EmitU32(Arm64MovReg(Dest, Source));
        Arm64CachedStore(ABuf, ACache, Dest, AIns.Dest);
      end;
    iroI32Const, iroF32Const:
      begin
        { A loop-invariant constant with a dedicated static host was seeded at
          frame entry; re-emitting it inside the loop body would rebuild the
          same bits on every iteration. Otherwise materialize straight into
          the freshly reserved destination — the T0 hop costs an extra mov
          per constant in the native-core shapes. }
        if not Arm64ConstSlotHost(ACache, AIns.Dest, ConstHost) then
        begin
          Dest := Arm64CachedDestReg(ABuf, ACache, AIns.Dest,
            ARM64_REG_ZR, ARM64_REG_ZR, ARM64_REG_T0);
          Arm64EmitLoadImm32(ABuf, Dest,
            UInt32(AIns.Imm and $FFFFFFFF));
          Arm64CachedStore(ABuf, ACache, Dest, AIns.Dest);
        end;
      end;
    iroI64Const, iroF64Const:
      begin
        if not Arm64ConstSlotHost(ACache, AIns.Dest, ConstHost) then
        begin
          Dest := Arm64CachedDestReg(ABuf, ACache, AIns.Dest,
            ARM64_REG_ZR, ARM64_REG_ZR, ARM64_REG_T0);
          Arm64EmitLoadImm64(ABuf, Dest, UInt64(AIns.Imm));
          Arm64CachedStore(ABuf, ACache, Dest, AIns.Dest);
        end;
      end;
    iroBranchIf, iroBranchIfNot:
      begin
        Arm64CachedLoad(ABuf, ACache, ARM64_REG_T0, AIns.A);
        { Taken and fallthrough successors must see the same canonical frame.
          The condition itself is already safe in x9 while dirty expression
          values that remain live are reconciled before control splits. }
        Arm64FlushDynamicRegCache(ABuf, ACache);
        if AIns.Op = iroBranchIf then
          EmitCbnzTo(ABuf, ARM64_REG_T0, AIns.B)
        else
          EmitCbzTo(ABuf, ARM64_REG_T0, AIns.B);
        Arm64InvalidateRegCache(ACache);
      end;
    iroJump:
      begin
        { Static allocation is enabled only for helper-free numeric functions.
          Their flagged back-edge performs an epoch comparison and either
          falls through or invokes a non-returning trap helper. No GC can run
          on the one-thread-per-store fallthrough, and none of the allocated
          slots is a reference. Keep numeric values in registers here; exits
          still flush the canonical logical frame below. }
        Arm64FlushDynamicRegCache(ABuf, ACache);
        Result := Arm64EmitOp(ABuf, AIns, AAux, AInsIndex);
      end;
    iroCall:
      if ANativeScalarSelf then
      begin
        { x12 carries the local core's one numeric parameter and result.
          Consume the argument before flushing so a dead expression need not
          be canonicalized; every other live value survives the local BL. }
        ArgSlot := IrAuxBlockItem(AAux, AIns.A, 0);
        ResultSlot := IrAuxBlockItem(AAux, AIns.B, 0);
        Source := Arm64CachedSourceReg(ABuf, ACache, ArgSlot, 12);
        Arm64FlushDynamicRegCache(ABuf, ACache);
        if Source <> 12 then
          ABuf.EmitU32(Arm64MovReg(12, Source));
        Arm64InvalidateRegCache(ACache);
        EmitNativeScalarSelfCallReg(ABuf, ANativeRegisterCount,
          ANativeCoreLabel, ANativeExhaustedLabel);
        Arm64CachedStore(ABuf, ACache, 12, ResultSlot);
      end
      else
      begin
        Arm64FlushDynamicRegCache(ABuf, ACache);
        Arm64InvalidateRegCache(ACache);
        Result := Arm64EmitOp(ABuf, AIns, AAux, AInsIndex,
          AUsePinnedMemory);
      end;
    iroReturn:
      begin
        if ANativeScalarSelf then
        begin
          { The external wrapper publishes x12 once; recursive callers adopt
            it directly into their own lexical cache. }
          Arm64CachedLoad(ABuf, ACache, 12, ANativeResultReg);
          Arm64EmitRet(ABuf)
        end
        else
        begin
          { Results and every observable exit are read from the logical frame. }
          Arm64FlushRegCache(ABuf, ACache);
          if AExtendedFrame then
            Arm64EmitEpilogueExtended(ABuf)
          else
            Arm64EmitEpilogue(ABuf);
        end;
      end;
    iroUnreachable:
      begin
        Arm64FlushRegCache(ABuf, ACache);
        Result := Arm64EmitOp(ABuf, AIns, AAux, AInsIndex);
      end;
    iroI32Eqz, iroI64Eqz:
      begin
        Arm64CachedLoad(ABuf, ACache, ARM64_REG_T0, AIns.A);
        if AIns.Op = iroI64Eqz then
          ABuf.EmitU32(Arm64CmpX(ARM64_REG_T0, ARM64_REG_ZR))
        else
          ABuf.EmitU32(Arm64CmpW(ARM64_REG_T0, ARM64_REG_ZR));
        ABuf.EmitU32(Arm64CsetW(ARM64_REG_T0, ARM64_COND_EQ));
        Arm64CachedStore(ABuf, ACache, ARM64_REG_T0, AIns.Dest);
      end;
    iroI32Eq: Arm64CachedRel(ABuf, AIns, ARM64_COND_EQ, False, ACache);
    iroI32Ne: Arm64CachedRel(ABuf, AIns, ARM64_COND_NE, False, ACache);
    iroI32LtS: Arm64CachedRel(ABuf, AIns, ARM64_COND_LT, False, ACache);
    iroI32LtU: Arm64CachedRel(ABuf, AIns, ARM64_COND_LO, False, ACache);
    iroI32GtS: Arm64CachedRel(ABuf, AIns, ARM64_COND_GT, False, ACache);
    iroI32GtU: Arm64CachedRel(ABuf, AIns, ARM64_COND_HI, False, ACache);
    iroI32LeS: Arm64CachedRel(ABuf, AIns, ARM64_COND_LE, False, ACache);
    iroI32LeU: Arm64CachedRel(ABuf, AIns, ARM64_COND_LS, False, ACache);
    iroI32GeS: Arm64CachedRel(ABuf, AIns, ARM64_COND_GE, False, ACache);
    iroI32GeU: Arm64CachedRel(ABuf, AIns, ARM64_COND_HS, False, ACache);
    iroI64Eq: Arm64CachedRel(ABuf, AIns, ARM64_COND_EQ, True, ACache);
    iroI64Ne: Arm64CachedRel(ABuf, AIns, ARM64_COND_NE, True, ACache);
    iroI64LtS: Arm64CachedRel(ABuf, AIns, ARM64_COND_LT, True, ACache);
    iroI64LtU: Arm64CachedRel(ABuf, AIns, ARM64_COND_LO, True, ACache);
    iroI64GtS: Arm64CachedRel(ABuf, AIns, ARM64_COND_GT, True, ACache);
    iroI64GtU: Arm64CachedRel(ABuf, AIns, ARM64_COND_HI, True, ACache);
    iroI64LeS: Arm64CachedRel(ABuf, AIns, ARM64_COND_LE, True, ACache);
    iroI64LeU: Arm64CachedRel(ABuf, AIns, ARM64_COND_LS, True, ACache);
    iroI64GeS: Arm64CachedRel(ABuf, AIns, ARM64_COND_GE, True, ACache);
    iroI64GeU: Arm64CachedRel(ABuf, AIns, ARM64_COND_HS, True, ACache);
    iroI32Add: Arm64CachedAlu(ABuf, AIns, @Arm64AddW, ACache);
    iroI32Sub: Arm64CachedAlu(ABuf, AIns, @Arm64SubW, ACache);
    iroI32Mul: Arm64CachedAlu(ABuf, AIns, @Arm64MulW, ACache);
    iroI32And: Arm64CachedAlu(ABuf, AIns, @Arm64AndW, ACache);
    iroI32Or: Arm64CachedAlu(ABuf, AIns, @Arm64OrrW, ACache);
    iroI32Xor: Arm64CachedAlu(ABuf, AIns, @Arm64EorW, ACache);
    iroI32Shl: Arm64CachedAlu(ABuf, AIns, @Arm64LslvW, ACache);
    iroI32ShrS: Arm64CachedAlu(ABuf, AIns, @Arm64AsrvW, ACache);
    iroI32ShrU: Arm64CachedAlu(ABuf, AIns, @Arm64LsrvW, ACache);
    iroI32Rotr: Arm64CachedAlu(ABuf, AIns, @Arm64RorvW, ACache);
    iroI64Add: Arm64CachedAlu(ABuf, AIns, @Arm64AddX, ACache);
    iroI64Sub: Arm64CachedAlu(ABuf, AIns, @Arm64SubX, ACache);
    iroI64Mul: Arm64CachedAlu(ABuf, AIns, @Arm64MulX, ACache);
    iroI64And: Arm64CachedAlu(ABuf, AIns, @Arm64AndX, ACache);
    iroI64Or: Arm64CachedAlu(ABuf, AIns, @Arm64OrrX, ACache);
    iroI64Xor: Arm64CachedAlu(ABuf, AIns, @Arm64EorX, ACache);
    iroI64Shl: Arm64CachedAlu(ABuf, AIns, @Arm64LslvX, ACache);
    iroI64ShrS: Arm64CachedAlu(ABuf, AIns, @Arm64AsrvX, ACache);
    iroI64ShrU: Arm64CachedAlu(ABuf, AIns, @Arm64LsrvX, ACache);
    iroI64Rotr: Arm64CachedAlu(ABuf, AIns, @Arm64RorvX, ACache);
  else
  begin
    if (AGcShapes <> nil) and
      ((AGcShapes[AInsIndex] and 1) <> 0) then
    begin
      if (AGcShapes[AInsIndex] and 4) <> 0 then
        Arm64EmitGcArrayAccess(ABuf, AIns, AInsIndex,
          AGcShapes[AInsIndex], ACache)
      else
        Arm64EmitGcFieldAccess(ABuf, AIns, AGcShapes[AInsIndex], ACache);
      Exit;
    end;
    { Wave 11: an eligible struct.new takes the inline free-list fast path;
      its miss branch lands on the unchanged generic (helper) emission below,
      so the slow path is byte-for-byte what this op emitted before. }
    if (AGcAlloc <> nil) and (AIns.Op = iroStructNew) and
      ((AGcAlloc[AInsIndex].Word and 1) <> 0) then
    begin
      Arm64FlushDynamicRegCache(ABuf, ACache);
      Arm64InvalidateRegCache(ACache);
      DoneLabel := 0;
      Arm64EmitInlineStructNew(ABuf, AIns, AGcAlloc[AInsIndex],
        AGcAllocInfo, ACache, SlowLabel, DoneLabel);
      ABuf.BindLabel(SlowLabel);
      Arm64InvalidateRegCache(ACache);
      Result := Arm64EmitOp(ABuf, AIns, AAux, AInsIndex, AUsePinnedMemory,
        ANativeScalarSelf, ANativeRegisterCount, ANativeParamReg,
        ANativeResultReg, ANativeCoreLabel, ANativeExhaustedLabel);
      ABuf.BindLabel(DoneLabel);
      Exit;
    end;
    { Helpers, safepoints, complex control and currently uncached templates all
      observe/write the canonical memory register file. }
    Arm64FlushDynamicRegCache(ABuf, ACache);
    Arm64InvalidateRegCache(ACache);
    Result := Arm64EmitOp(ABuf, AIns, AAux, AInsIndex, AUsePinnedMemory,
      ANativeScalarSelf, ANativeRegisterCount, ANativeParamReg,
      ANativeResultReg, ANativeCoreLabel, ANativeExhaustedLabel);
  end;
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
{  Wave 3 — the CALL family (jit-spec §4.4, §4.5, §5)                    }
{ ===================================================================== }

{ THE DESIGN, in one paragraph. A compiled call does NOT re-implement frame
  layout. It copies the IR arguments into a flat native-stack buffer. A direct
  call asks the shared frame helper for a compiled entry and invokes that entry
  immediately; host/interpreted and dynamic calls use the generic dispatcher.
  Both paths copy the flat result buffer back into IR destinations. The buffer IS THE
  SEAM: the IR's argument/result aux blocks already list one register per
  SLOT (a v128 operand contributes its low and high halves as two separate
  entries), which is exactly the flat block the interpreter's CompiledCall /
  HostCall / JitEnterFrame speak — so the emitted marshaling is a plain
  slot-for-slot copy with no v128 special case, and it is bit-identical to the
  interpreter's. Everything subtle then lives in Pascal: the helper resolves
  the callee and dispatches host / compiled / interpreted in the interpreter's
  EnterCall order, so compiled<->interpreted<->host interop is automatic and
  observationally identical (§13). }

type
  { The AArch64 compiled-entry ABI (kept local so this unit stays below the
    driver): the register-file base (x0 -> pinned x19), the store (x1 -> pinned
    x20), the IR-code base @Fn^.Code[0] (x2 -> pinned x23), and the interpreter
    context (x3 -> x25 unless the function pins memory there), plus the live
    function entry in x4 retained by the generic direct-call ABI. IR, context,
    and entry are live per-invocation values, never baked. Proof-gated scalar
    recursion instead uses a local BL patch within the same PIC code blob. }
  TArm64CompiledEntry = procedure(const ARegBase: PWasmValue;
    const AStore: TWasmStore; const AIrBase: PWasmIrInstr;
    const ACtx: PWasmInterpContext; const ASelfEntry: Pointer); cdecl;

{ Fix A: the pending tail-call channel is now the SHARED Wasm.Interp.GTierTail
  (TierTailSlot), written by BOTH a compiled body's return_call* helper AND the
  interpreter's cross-tier tail bounce, and read by the loop below — so an
  alternating compiled<->interpreted tail chain re-dispatches through ONE loop
  with no native-stack growth (Finding 1). The old backend-local slot is gone. }

{ The instance whose index spaces a call immediate is resolved against: the
  CURRENT (top) activation's, which is the compiled frame JitEnterFrame pushed
  and which is still on top while a helper runs. The interpreter resolves
  against Act^.Instance in exactly the same way. }
function Arm64CallerInstance(const AStore: TWasmStore): TWasmModuleInstance;
var
  Ctx: PWasmInterpContext;
begin
  Ctx := InterpContextFor(AStore);
  Result := Ctx^.Acts[Ctx^.Depth - 1].Instance;
end;

{ Run an INTERPRETED callee as one nested invocation over the shared context.
  TierInvoke is the interpreter's entry: it carves the callee's frame through
  the same JitEnterFrame the compiled path uses, runs it, and delivers the
  flat results — so params/results marshal identically either way.

  THE EPOCH SNAPSHOT is saved and restored around it (ADR-0006, §6): the
  snapshot is a per-INVOCATION value seeded at the outermost guest entry, and
  TierInvoke re-seeds it because its normal caller IS an outermost entry. A
  nested wasm->wasm call must not disturb it, so the original is put back. See
  the UNCONFIRMED note in the unit header for the residue this cannot fix. }
procedure Arm64CallInterpreted(const AStore: TWasmStore;
  const AAddr: TWasmFuncAddr; const AArgs, AResults: PWasmValue);
var
  Saved: UInt64;
begin
  Saved := AStore.EpochSnapshot;
  AStore.TierInvoke(AStore, AAddr, AArgs, AResults);
  AStore.EpochSnapshot := Saved;
end;

{ The ONE tier decision for a wasm->wasm call from compiled code (§4.4), in
  the interpreter's EnterCall order: host first, then a compiled callee
  through the store's hook, else the interpreter. }
procedure Arm64DispatchCall(const AStore: TWasmStore;
  const AAddr: TWasmFuncAddr; const AArgs, AResults: PWasmValue);
begin
  if AStore.Funcs[AAddr].Kind = wfkHost then
    AStore.Funcs[AAddr].Callback(AStore, AStore.Funcs[AAddr].HostData,
      AArgs, AResults)
  else if Assigned(AStore.JitInvokeCompiled) and
    (AStore.Funcs[AAddr].CompiledEntry <> nil) then
  begin
    { Fix A: a compiled callee reached from compiled code is a nested tier seam
      — mark it so its frame is rtCompiledSeam (transparent to a throw). }
    MarkJitSeamReentry;
    AStore.JitInvokeCompiled(AStore, AAddr, AArgs, AResults);
  end
  else
  begin
    { An interpreted callee reached from compiled code (a NON-tail call) is a
      nested seam too; mark it so its frame is rtCompiledSeam. NOT a tail target,
      so it completes normally and its results flow back. TierInvoke bumps
      CallCount for the interpreted entry, as EnterCall does. }
    MarkJitSeamReentry;
    Arm64CallInterpreted(AStore, AAddr, AArgs, AResults);
  end;
end;

{ call_indirect resolution, mirroring Wasm.Interp.ResolveIndirect INSTRUCTION
  FOR INSTRUCTION — most of all its CHECK ORDER, which is observable through
  which message a bad table entry produces (§13 item 2, exec-call_indirect):

    1. index >= table length      -> 'undefined element'
    2. element is null            -> 'uninitialized element <index>'
    3. runtime type not a subtype -> 'indirect call type mismatch'

  The width of the index operand is the TABLE's address type, and the type
  check is engine-level subtyping (actual <: expected), not id equality — a
  proper subtype must dispatch. Every trap goes through the same TrapNow /
  TrapNowDetail the interpreter uses, so the messages are identical by
  construction rather than by being spelled twice. }
function Arm64ResolveIndirect(const AStore: TWasmStore; const APacked: UInt64;
  const AIndexBits: UInt64): TWasmFuncAddr;
var
  TypeIdx, TableIdx: UInt32;
  Inst: TWasmModuleInstance;
  TableAddr: TWasmTableAddr;
  Idx: UInt64;
  R: TWasmRef;
  FuncAddr: TWasmFuncAddr;
  Expected: TWasmEngineTypeId;
begin
  IrUnpack(Int64(APacked), TypeIdx, TableIdx);
  Inst := Arm64CallerInstance(AStore);
  TableAddr := Inst.TableAddrs[TableIdx];

  if AStore.Tables[TableAddr].TableType.Limits.AddrType = watI64 then
    Idx := AIndexBits
  else
    Idx := UInt32(AIndexBits);

  if Idx >= UInt64(Length(AStore.Tables[TableAddr].Elems)) then
    TrapNow(wtkUndefinedElement);

  R := AStore.Tables[TableAddr].Elems[Idx];
  if RefIsNull(R) then
    TrapNowDetail(wtkUninitializedElement, UInt32(Idx));

  FuncAddr := AStore.FuncRefAddr(R);
  Expected := Inst.EngineTypeIds[TypeIdx];
  if not AStore.Engine.Matches(AStore.Funcs[FuncAddr].TypeId, Expected) then
    TrapNow(wtkIndirectCallTypeMismatch);

  Result := FuncAddr;
end;

{ call_ref's null check, the interpreter's iroCallRef arm verbatim. }
function Arm64ResolveRef(const AStore: TWasmStore;
  const ARefBits: PtrUInt): TWasmFuncAddr;
var
  R: TWasmRef;
begin
  R := TWasmRef(ARefBits);
  if RefIsNull(R) then
    TrapNow(wtkNullFuncReference);
  Result := AStore.FuncRefAddr(R);
end;

{ Record a resolved tail target + its collected arguments for the trampoline
  loop, and return to the compiled body (which then runs its epilogue). No
  frame work happens here: the loop owns the pop/push so the replacement costs
  no native stack (§4.5). }
procedure Arm64SetPendingTail(const AAddr: TWasmFuncAddr;
  const AArgs: PWasmValue; const ACount: UInt32);
begin
  { Publish into the SHARED cross-tier channel (Fix A). }
  SetTierPendingTail(AAddr, AArgs, ACount);
end;

{ --- the six cdecl helpers the emitted call sequences call --------------- }

procedure JitCallHelper(const AStore: TWasmStore; const AFuncIdx: PtrUInt;
  const AArgs, AResults: PWasmValue); cdecl;
begin
  Arm64DispatchCall(AStore,
    Arm64CallerInstance(AStore).FuncAddrs[UInt32(AFuncIdx)], AArgs, AResults);
end;

procedure JitCallIndirectHelper(const AStore: TWasmStore;
  const APacked: PtrUInt; const AIndexBits: UInt64;
  const AArgs, AResults: PWasmValue); cdecl;
begin
  Arm64DispatchCall(AStore,
    Arm64ResolveIndirect(AStore, UInt64(APacked), AIndexBits), AArgs, AResults);
end;

procedure JitCallRefHelper(const AStore: TWasmStore; const ARefBits: PtrUInt;
  const AArgs, AResults: PWasmValue); cdecl;
begin
  Arm64DispatchCall(AStore, Arm64ResolveRef(AStore, ARefBits), AArgs, AResults);
end;

procedure JitReturnCallHelper(const AStore: TWasmStore;
  const AFuncIdx: PtrUInt; const AArgs: PWasmValue;
  const ACount: PtrUInt); cdecl;
begin
  Arm64SetPendingTail(Arm64CallerInstance(AStore).FuncAddrs[UInt32(AFuncIdx)],
    AArgs, UInt32(ACount));
end;

procedure JitReturnCallIndirectHelper(const AStore: TWasmStore;
  const APacked: PtrUInt; const AIndexBits: UInt64; const AArgs: PWasmValue;
  const ACount: PtrUInt); cdecl;
begin
  Arm64SetPendingTail(Arm64ResolveIndirect(AStore, UInt64(APacked), AIndexBits),
    AArgs, UInt32(ACount));
end;

procedure JitReturnCallRefHelper(const AStore: TWasmStore;
  const ARefBits: PtrUInt; const AArgs: PWasmValue;
  const ACount: PtrUInt); cdecl;
begin
  Arm64SetPendingTail(Arm64ResolveRef(AStore, ARefBits), AArgs,
    UInt32(ACount));
end;

{ --- the trampoline loop (§4.5, §5.2) ----------------------------------- }

procedure Arm64InvokeCompiled(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue);
var
  Ctx: PWasmInterpContext;
  Pend: PWasmTierTail;
  Base: PWasmValue;
  Entry: TArm64CompiledEntry;
  CurAddr: TWasmFuncAddr;
  CurArgs: PWasmValue;
  RetKind: TWasmRetKind;
  Seam: TWasmSeamCatch;
  IrFn: PWasmIrFunction;
  IrBase: PWasmIrInstr;
begin
  Ctx := InterpContextFor(AStore);
  { Fix A: this whole invocation's frames share ONE return/unwind kind — rtEntry
    at a genuine outermost compiled entry, rtCompiledSeam when a launcher marked
    a nested seam. A tail replacement preserves the original return target, so
    every iteration carves with the SAME RetKind. }
  RetKind := ConsumeJitSeamReentry;
  Pend := TierTailSlot;
  CurAddr := AFuncAddr;
  CurArgs := AParams;
  while True do
  begin
    { A tail target may be a host function: do the host call and let its results
      BE this invocation's results (§4.5). Unreachable on the first iteration. }
    if AStore.Funcs[CurAddr].Kind = wfkHost then
    begin
      AStore.Funcs[CurAddr].Callback(AStore, AStore.Funcs[CurAddr].HostData,
        CurArgs, AResults);
      Exit;
    end;
    { A tail target that is not compiled runs INTERPRETED. Fix A: drive it as a
      tail target (MarkTierTailTarget) and propagate this chain's kind, so its
      Run may BOUNCE a cross-tier tail back to THIS loop (O(1)) instead of
      nesting. If it bounces, GTierTail is pending and we loop; otherwise it ran
      to completion and delivered its results. }
    if AStore.Funcs[CurAddr].CompiledEntry = nil then
    begin
      if RetKind = rtCompiledSeam then
        MarkJitSeamReentry;
      MarkTierTailTarget;
      Arm64CallInterpreted(AStore, CurAddr, CurArgs, AResults);
      if not Pend^.Pending then
        Exit;
      Pend^.Pending := False;
      CurAddr := Pend^.Addr;
      CurArgs := @Pend^.Args[0];
      Continue;
    end;

    { Carve + zero + marshal params + push the GC frame through the SHARED
      helper (§5.1). CurArgs is consumed here, BEFORE the body can overwrite the
      pending buffer it may point into. }
    Base := JitEnterFrame(Ctx, AStore, CurAddr, CurArgs, AResults, RetKind);
    Pend^.Pending := False;
    Entry := TArm64CompiledEntry(AStore.Funcs[CurAddr].CompiledEntry);
    { The IR-code base @Fn^.Code[0] the compiled body pins in x23 to compute
      @Fn^.Code[i] (aot-spec §1.3). It is the FRESHLY-decoded IR of the current
      callee — a live per-invocation pointer, passed in, never baked. }
    IrFn := @AStore.Funcs[CurAddr].Instance.Ir.Functions[
      AStore.Funcs[CurAddr].FuncIrIndex];
    if Length(IrFn^.Code) > 0 then
      IrBase := @IrFn^.Code[0]
    else
      IrBase := nil;
    { Fix A (Finding 3): the compiled body is a native barrier. A wasm exception
      thrown beneath it LongJmps up to THIS seam catch (a Pascal raise cannot
      cross the native frame on this target). On the hop, re-enter the unwind: it
      pops this compiled frame (transparent, no handlers) and hops further out —
      or, at a genuine outermost rtEntry, RaiseUncaughts. It never resumes here
      (a compiled frame carries no handler), so control never returns to the
      normal path; the Exit is defensive. }
    Seam.Prev := CurrentSeamCatch;
    CurrentSeamCatch := @Seam;
    if SetJmp(Seam.JmpBuf) <> 0 then
    begin
      CurrentSeamCatch := Seam.Prev;
      UnwindException(Ctx, TWasmRef(Seam.ExnRef), False);
      Exit;
    end;
    Entry(Base, AStore, IrBase, Ctx,
      AStore.Funcs[CurAddr].CompiledEntry);
    CurrentSeamCatch := Seam.Prev;

    { Pop (reuses ONE frame-teardown path; on a tail the body wrote no results,
      and the NEXT iteration overwrites them). Popping resets ValueTop to this
      frame's Base, so the replacement is carved at the SAME base and Depth is
      unchanged across an iteration: the O(1) property. }
    JitLeaveFrame(Ctx);
    if not Pend^.Pending then
      Exit;
    Pend^.Pending := False;
    CurAddr := Pend^.Addr;
    CurArgs := @Pend^.Args[0];
  end;
end;

{ ===================================================================== }
{  Waves 4 & 5 — memory / table / reference / global / GC (jit-spec §7,  }
{  §8, §9, §12.3 Waves 4-5)                                              }
{ ===================================================================== }

{ THE PATTERN, and why it is the whole of these two waves. Every table,
  reference, global and GC op is a HELPER CALL, exactly as jit-spec
  §1.4 prescribes ("if the interpreter dispatches to a store/heap method for
  an op, the JIT emits a call to that same function"). The emitted template is
  UNIFORM and tiny — marshal the store, the register-file base and a pointer
  to the IR instruction into x0/x1/x2, then `blr` a single cdecl dispatcher
  (JitRtDispatch) — and every subtlety lives in Pascal:

    - SCALAR MEMORY uses the generated-code half of the ONE chokepoint: the
      address type selects the strategy statically, guard-page and
      guard-assisted folds use the reservation, and the fallback reproduces
      MemCheck's overflow-safe subtraction sequence. memory.grow and bulk/SIMD
      operations remain on Store.MemAddressAt / MemRangeAt helpers.
    - TABLE reference stores go through the barriered store methods
      (TableSet/Fill/Grow/Init/Copy); reads are the free functions. Traps are
      'out of bounds table access' / 'undefined element' — the store's, not
      re-spelled here.
    - GC struct/array/i31 go through Store.Heap (Wasm.Runtime.Gc), which owns
      layout, packing, the split null traps and the write barrier.
    - GLOBAL ref writes take the same empty-but-present write barrier the
      interpreter takes.

  Because the dispatcher reproduces the interpreter's Exec* bodies verbatim,
  calling the identical runtime primitives, the trap kind, message, order and
  the final memory/table/global/GC-heap state are the interpreter's BY
  CONSTRUCTION (§13) — the differential harness (§11) is what proves it.

  THE GC SAFEPOINT (§9). struct.new / array.new* ALLOCATE, and a collection
  may run inside the helper. The frame is walkable because JitEnterFrame
  pushed the compiled frame's TWasmGcFrame with Slots = @Values[Base] (the
  in-memory register file the templates read and write) and RefRegBits over
  the ref slots; the baseline stores every value to its slot before any op
  boundary, so at the helper call every live ref is in a slot the collector
  traces and NONE is only in a machine register. The dispatcher inherits the
  interpreter's publish-first discipline (write the fresh aggregate into its
  Dest slot before filling), so a mid-fill collection finds it rooted. No
  per-safepoint liveness map is needed — the memory-register-file choice pays
  this off for free (§9.3).

  TRAP-1 (interp-spec §1.4). Every helper below is a leaf whose locals are all
  plain pointers/scalars/records with no managed fields (no strings, dynamic
  arrays, interfaces), so a chokepoint/heap TrapNow's LongJmp to the
  per-invocation trampoline abandons nothing.

  THE INSTRUCTION POINTER. Arm64EmitOp receives the instruction as
  `const AIns: TWasmIrInstr`; a const record that size is passed BY REFERENCE
  (the assumption Wasm.Ir itself documents and relies on), so `@AIns` is the
  address of the live IR instruction (AFn^.Code[i]). The IR is borrowed and
  outlives the code block (jit-spec §3.4), so the compiled code may hold that
  raw pointer for its whole life and hand it to the dispatcher, which reads
  the op's Dest/A/B/Imm fields exactly as the interpreter does. }

{ The current (top) activation — the compiled frame JitEnterFrame pushed and
  which is still on top while a helper runs (the same invariant
  Arm64CallerInstance relies on). Gives the op its index spaces (Instance) and
  its aux blocks (Fn). }
function Arm64TopActivation(const AStore: TWasmStore): PWasmActivation;
var
  Ctx: PWasmInterpContext;
begin
  Ctx := InterpContextFor(AStore);
  Result := @Ctx^.Acts[Ctx^.Depth - 1];
end;

{ The interpreter's MemLoad / MemStore leaves, reproduced (they are
  implementation-only in Wasm.Interp). Both reach memory ONLY through
  Store.MemAddressAt — the chokepoint — which bounds-checks and traps
  'out of bounds memory access'. Little-endian, unaligned-safe. }
function JitMemLoadBytes(const AStore: TWasmStore; const AMemAddr: TWasmMemAddr;
  const AIndex, AOffset: UInt64; const ASize: NativeUInt): UInt64;
var
  P: PByte;
begin
  P := AStore.MemAddressAt(AMemAddr, AIndex, AOffset, ASize);
  Result := 0;
  Move(P^, Result, ASize);
end;

procedure JitMemStoreBytes(const AStore: TWasmStore;
  const AMemAddr: TWasmMemAddr; const AIndex, AOffset: UInt64;
  const ASize: NativeUInt; const AValue: UInt64);
var
  P: PByte;
  V: UInt64;
begin
  P := AStore.MemAddressAt(AMemAddr, AIndex, AOffset, ASize);
  V := AValue;
  Move(V, P^, ASize);
end;

{ --- memory (ExecLoad/ExecStore/size/grow/init/copy/fill/data.drop) ------ }
procedure JitDoMem(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  Inst: TWasmModuleInstance;
  MemAddr, DstMemAddr, SrcMemAddr: TWasmMemAddr;
  Raw: UInt64;
  MemIdx, DataIdx, DstMem, SrcMem: UInt32;
  DataAddr: TWasmDataAddr;
  DstIdx, SrcOff, SrcIdx, Count, DataSize: UInt64;
  DstPtr, SrcPtr: PByte;
begin
  Reg := AReg;
  Inst := AAct^.Instance;
  case AIns^.Op of
    { --- loads (B = mem index, A = index reg, Imm = static offset) ------- }
    iroI32Load:
      Reg[AIns^.Dest].Bits := UInt64(UInt32(JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4)));
    iroI64Load:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 8);
    iroF32Load:
      Reg[AIns^.Dest].Bits := UInt64(UInt32(JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4)));
    iroF64Load:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 8);
    iroI32Load8S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
        Reg[AIns^.Dest].Bits := UInt64(UInt32(Int32(ShortInt(Byte(Raw)))));
      end;
    iroI32Load8U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
    iroI32Load16S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
        Reg[AIns^.Dest].Bits := UInt64(UInt32(Int32(SmallInt(Word(Raw)))));
      end;
    iroI32Load16U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
    iroI64Load8S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
        Reg[AIns^.Dest].Bits := UInt64(Int64(ShortInt(Byte(Raw))));
      end;
    iroI64Load8U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
    iroI64Load16S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
        Reg[AIns^.Dest].Bits := UInt64(Int64(SmallInt(Word(Raw))));
      end;
    iroI64Load16U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
    iroI64Load32S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4);
        Reg[AIns^.Dest].Bits := UInt64(Int64(Int32(UInt32(Raw))));
      end;
    iroI64Load32U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4);

    { --- stores (Dest = value reg, A = index reg, B = mem index) --------- }
    iroI32Store, iroF32Store:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 4, Reg[AIns^.Dest].U64);
    iroI64Store, iroF64Store:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 8, Reg[AIns^.Dest].U64);
    iroI32Store8, iroI64Store8:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 1, Reg[AIns^.Dest].U64);
    iroI32Store16, iroI64Store16:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 2, Reg[AIns^.Dest].U64);
    iroI64Store32:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 4, Reg[AIns^.Dest].U64);

    { --- size / grow (grow never traps, never collects; -1 on failure) -- }
    iroMemorySize:
      Reg[AIns^.Dest].Bits := AStore.MemoryPages(Inst.MemAddrs[UInt32(AIns^.Imm)]);
    iroMemoryGrow:
      begin
        MemAddr := Inst.MemAddrs[UInt32(AIns^.Imm)];
        if AStore.MemoryAddrType(MemAddr) = watI64 then
          Reg[AIns^.Dest].Bits :=
            UInt64(AStore.MemoryGrow(MemAddr, Reg[AIns^.A].U64))
        else
          Reg[AIns^.Dest].Bits :=
            UInt64(UInt32(AStore.MemoryGrow(MemAddr, Reg[AIns^.A].U64)));
      end;

    { --- bulk (range-checked through the chokepoint; write nothing on trap) }
    iroMemoryInit:
      begin
        IrUnpack(AIns^.Imm, MemIdx, DataIdx);
        MemAddr := Inst.MemAddrs[MemIdx];
        DataAddr := Inst.DataAddrs[DataIdx];
        DstIdx := Reg[AIns^.Dest].U64;
        SrcOff := Reg[AIns^.A].U64;
        Count := Reg[AIns^.B].U64;
        DstPtr := AStore.MemRangeAt(MemAddr, DstIdx, Count);
        DataSize := UInt64(AStore.Datas[DataAddr].Size);
        if (SrcOff > DataSize) or (Count > DataSize - SrcOff) then
          TrapNow(wtkMemoryOutOfBounds);
        if Count > 0 then
        begin
          SrcPtr := AStore.Datas[DataAddr].Data;
          Inc(SrcPtr, SrcOff);
          Move(SrcPtr^, DstPtr^, NativeUInt(Count));
        end;
      end;
    iroMemoryCopy:
      begin
        IrUnpack(AIns^.Imm, DstMem, SrcMem);
        DstIdx := Reg[AIns^.Dest].U64;
        SrcIdx := Reg[AIns^.A].U64;
        Count := Reg[AIns^.B].U64;
        DstMemAddr := Inst.MemAddrs[DstMem];
        SrcMemAddr := Inst.MemAddrs[SrcMem];
        DstPtr := AStore.MemRangeAt(DstMemAddr, DstIdx, Count);
        SrcPtr := AStore.MemRangeAt(SrcMemAddr, SrcIdx, Count);
        if Count > 0 then
          Move(SrcPtr^, DstPtr^, NativeUInt(Count));
      end;
    iroMemoryFill:
      begin
        DstIdx := Reg[AIns^.Dest].U64;
        Count := Reg[AIns^.B].U64;
        DstPtr := AStore.MemRangeAt(Inst.MemAddrs[UInt32(AIns^.Imm)],
          DstIdx, Count);
        if Count > 0 then
          FillChar(DstPtr^, NativeUInt(Count), Byte(Reg[AIns^.A].U32 and $FF));
      end;
    iroDataDrop:
      begin
        DataAddr := Inst.DataAddrs[UInt32(AIns^.Imm)];
        AStore.Datas[DataAddr].Dropped := True;
        AStore.Datas[DataAddr].Size := 0;
        AStore.Datas[DataAddr].Data := nil;
      end;
  end;
end;

{ --- table (interp-spec §3.8): reference stores are barriered store methods,
  reads are free functions ------------------------------------------------- }
procedure JitDoTable(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  Inst: TWasmModuleInstance;
  Addr: TWasmTableAddr;
  U1, U2: UInt32;
begin
  Reg := AReg;
  Inst := AAct^.Instance;
  case AIns^.Op of
    iroTableGet:
      Reg[AIns^.Dest].Bits := UInt64(TableGet(
        AStore.Tables[Inst.TableAddrs[UInt32(AIns^.Imm)]], Reg[AIns^.A].U64));
    iroTableSet:
      AStore.TableSet(Inst.TableAddrs[UInt32(AIns^.Imm)],
        Reg[AIns^.A].U64, Reg[AIns^.B].Ref);
    iroTableSize:
      Reg[AIns^.Dest].Bits := TableSize(
        AStore.Tables[Inst.TableAddrs[UInt32(AIns^.Imm)]]);
    iroTableGrow:
      begin
        Addr := Inst.TableAddrs[UInt32(AIns^.Imm)];
        if AStore.Tables[Addr].TableType.Limits.AddrType = watI64 then
          Reg[AIns^.Dest].Bits :=
            UInt64(AStore.TableGrow(Addr, Reg[AIns^.B].U64, Reg[AIns^.A].Ref))
        else
          Reg[AIns^.Dest].Bits := UInt64(UInt32(
            AStore.TableGrow(Addr, Reg[AIns^.B].U64, Reg[AIns^.A].Ref)));
      end;
    iroTableFill:
      AStore.TableFill(Inst.TableAddrs[UInt32(AIns^.Imm)],
        Reg[AIns^.Dest].U64, Reg[AIns^.B].U64, Reg[AIns^.A].Ref);
    iroTableInit:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        AStore.TableInitFromElem(Inst.TableAddrs[U1], Reg[AIns^.Dest].U64,
          AStore.Elems[Inst.ElemAddrs[U2]].Refs, Reg[AIns^.A].U64,
          Reg[AIns^.B].U64);
      end;
    iroTableCopy:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        AStore.TableCopy(Inst.TableAddrs[U1], Reg[AIns^.Dest].U64,
          Inst.TableAddrs[U2], Reg[AIns^.A].U64, Reg[AIns^.B].U64);
      end;
    iroElemDrop:
      begin
        AStore.Elems[Inst.ElemAddrs[UInt32(AIns^.Imm)]].Refs := nil;
        AStore.Elems[Inst.ElemAddrs[UInt32(AIns^.Imm)]].Dropped := True;
      end;
  end;
end;

{ ref.test / ref.cast / br_on_cast* runtime match — the interpreter's
  MatchesAuxRefType leaf (reftype in Fn^.AuxRefTypes[Imm], module space,
  converted to engine space, then the store's O(1) subtype check). }
function JitMatchesAuxRefType(const AStore: TWasmStore;
  const AAct: PWasmActivation; const ARef: TWasmRef;
  const AAuxIdx: UInt32): Boolean;
var
  EngRt: TWasmRefType;
begin
  EngRt := EngineRefType(AAct^.Fn^.AuxRefTypes[AAuxIdx],
    AAct^.Instance.EngineTypeIds);
  Result := IsRefOfRefType(AStore.Engine, ARef, EngRt);
end;

{ --- reference (interp-spec §3.9), the non-branch forms ------------------ }
procedure JitDoRef(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  Inst: TWasmModuleInstance;
begin
  Reg := AReg;
  Inst := AAct^.Instance;
  case AIns^.Op of
    iroRefNull:
      Reg[AIns^.Dest].Bits := UInt64(WASM_REF_NULL);
    iroRefIsNull:
      ValueSetI32(Reg[AIns^.Dest], Ord(RefIsNull(Reg[AIns^.A].Ref)));
    iroRefFunc:
      Reg[AIns^.Dest].Bits := UInt64(
        AStore.Funcs[Inst.FuncAddrs[UInt32(AIns^.Imm)]].RefObject);
    iroRefEq:
      ValueSetI32(Reg[AIns^.Dest], Ord(Reg[AIns^.A].Ref = Reg[AIns^.B].Ref));
    iroRefAsNonNull:
      begin
        if RefIsNull(Reg[AIns^.A].Ref) then
          TrapNow(wtkNullReference);
        Reg[AIns^.Dest].Bits := Reg[AIns^.A].Bits;
      end;
    iroRefTest:
      ValueSetI32(Reg[AIns^.Dest], Ord(JitMatchesAuxRefType(AStore, AAct,
        Reg[AIns^.A].Ref, UInt32(AIns^.Imm))));
    iroRefCast:
      if JitMatchesAuxRefType(AStore, AAct, Reg[AIns^.A].Ref,
        UInt32(AIns^.Imm)) then
        Reg[AIns^.Dest].Bits := Reg[AIns^.A].Bits
      else
        TrapNow(wtkCastFailure);
  end;
end;

{ --- global (a v128 global is iroGlobalGetVec/SetVec — declined, Wave 6) -- }
procedure JitDoGlobal(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  Addr: TWasmGlobalAddr;
begin
  Reg := AReg;
  Addr := AAct^.Instance.GlobalAddrs[UInt32(AIns^.Imm)];
  case AIns^.Op of
    iroGlobalGet:
      Reg[AIns^.Dest].Bits := AStore.Globals[Addr].Value.Bits;
    iroGlobalSet:
      begin
        if AStore.Globals[Addr].GlobalType.ValueType.Kind = wvkRef then
          { The v1 write barrier is empty, so the old-value argument is null —
            the interpreter's exact call (a non-empty barrier would first read
            the cell's current ref, see the interp note). }
          AStore.Heap.WriteBarrier(WASM_REF_NULL, Reg[AIns^.A].Ref);
        AStore.Globals[Addr].Value.Bits := Reg[AIns^.A].Bits;
      end;
  end;
end;

{ --- GC: struct / array / i31 (interp-spec §3.10) ------------------------
  Publish-first is preserved verbatim: the fresh aggregate is written into its
  Dest ref slot (RefRegBits-covered) BEFORE any field/element write that could
  allocate, so a collection during the fill finds it rooted (§9.3). }
procedure JitDoGc(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  Inst: TWasmModuleInstance;
  Fn: PWasmIrFunction;
  Obj: TWasmRef;
  N, I, U1, U2, TypeIdx, DataIdx, ElemIdx, Aux: UInt32;
  TmpFields: array[0..7] of TWasmValue;
  ElemOffset, Count, SrcLen: UInt32;
  DataAddr: TWasmDataAddr;
  ElemAddr: TWasmElemAddr;
begin
  Reg := AReg;
  Inst := AAct^.Instance;
  Fn := AAct^.Fn;
  case AIns^.Op of
    iroStructNew:
      begin
        Obj := AStore.Heap.AllocStruct(Inst.EngineTypeIds[UInt32(AIns^.Imm)]);
        Reg[AIns^.Dest].Bits := UInt64(Obj);            { publish before fill }
        N := IrAuxBlockCount(Fn^.AuxU32, AIns^.A);
        if N <= UInt32(Length(TmpFields)) then
        begin
          for I := 0 to Integer(N) - 1 do
            TmpFields[I] := Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)];
          AStore.Heap.StructSetSeq(Obj, @TmpFields[0], N);
        end
        else
        begin
          I := 0;
          while I < N do
          begin
            AStore.Heap.StructSet(Obj, I,
              Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)]);
            Inc(I);
          end;
        end;
      end;
    iroStructNewDefault:
      begin
        Obj := AStore.Heap.AllocStruct(Inst.EngineTypeIds[UInt32(AIns^.Imm)]);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.StructSetDefaults(Obj);
      end;
    iroStructGet:
      begin
        IrUnpack(AIns^.Imm, U1, U2);   { U2 = field index }
        Reg[AIns^.Dest] := AStore.Heap.StructGet(Reg[AIns^.A].Ref, U2);
      end;
    iroStructGetS:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        ValueSetI32(Reg[AIns^.Dest],
          AStore.Heap.StructGetSigned(Reg[AIns^.A].Ref, U2));
      end;
    iroStructGetU:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        ValueSetU32(Reg[AIns^.Dest],
          AStore.Heap.StructGetUnsigned(Reg[AIns^.A].Ref, U2));
      end;
    iroStructSet:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        AStore.Heap.StructSet(Reg[AIns^.A].Ref, U2, Reg[AIns^.B]);
      end;

    iroArrayNew:
      begin
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[UInt32(AIns^.Imm)],
          Reg[AIns^.B].U32);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.ArrayFill(Obj, Reg[AIns^.A]);
      end;
    iroArrayNewDefault:
      begin
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[UInt32(AIns^.Imm)],
          Reg[AIns^.A].U32);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.ArraySetDefaults(Obj);
      end;
    iroArrayNewFixed:
      begin
        N := IrAuxBlockCount(Fn^.AuxU32, AIns^.A);
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[UInt32(AIns^.Imm)], N);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        I := 0;
        while I < N do
        begin
          AStore.Heap.ArraySet(Obj, I,
            Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)]);
          Inc(I);
        end;
      end;
    iroArrayNewData:
      begin
        IrUnpack(AIns^.Imm, TypeIdx, DataIdx);
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[TypeIdx],
          Reg[AIns^.B].U32);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        DataAddr := Inst.DataAddrs[DataIdx];
        AStore.Heap.ArrayInitFromData(Obj, 0, AStore.Datas[DataAddr].Data,
          AStore.Datas[DataAddr].Size, Reg[AIns^.A].U64, Reg[AIns^.B].U32);
      end;
    iroArrayNewElem:
      begin
        IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
        ElemAddr := Inst.ElemAddrs[ElemIdx];
        { The element-segment source range is checked BEFORE allocating, so an
          overflowing count traps 'out of bounds table access' rather than
          'out of memory' (interp-spec, corpus array.wast:283). }
        ElemOffset := Reg[AIns^.A].U32;
        Count := Reg[AIns^.B].U32;
        SrcLen := UInt32(Length(AStore.Elems[ElemAddr].Refs));
        if (ElemOffset > SrcLen) or (Count > SrcLen - ElemOffset) then
          TrapNow(wtkTableOutOfBounds);
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[TypeIdx], Count);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.ArrayInitFromElem(Obj, 0, AStore.Elems[ElemAddr].Refs,
          ElemOffset, Count);
      end;
    iroArrayGet:
      Reg[AIns^.Dest] :=
        AStore.Heap.ArrayGet(Reg[AIns^.A].Ref, Reg[AIns^.B].U32);
    iroArrayGetS:
      ValueSetI32(Reg[AIns^.Dest],
        AStore.Heap.ArrayGetSigned(Reg[AIns^.A].Ref, Reg[AIns^.B].U32));
    iroArrayGetU:
      ValueSetU32(Reg[AIns^.Dest],
        AStore.Heap.ArrayGetUnsigned(Reg[AIns^.A].Ref, Reg[AIns^.B].U32));
    iroArraySet:
      AStore.Heap.ArraySet(Reg[AIns^.Dest].Ref, Reg[AIns^.A].U32,
        Reg[AIns^.B]);
    iroArrayLen:
      ValueSetU32(Reg[AIns^.Dest], AStore.Heap.ArrayLength(Reg[AIns^.A].Ref));
    iroArrayFill:
      begin
        Aux := AIns^.A;   { aux [ref, index, value, count] }
        AStore.Heap.ArrayFill(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)]);
      end;
    iroArrayCopy:
      begin
        Aux := AIns^.A;   { aux [dstRef, dstIdx, srcRef, srcIdx, count] }
        AStore.Heap.ArrayCopy(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 4)].U32);
      end;
    iroArrayInitData:
      begin
        Aux := AIns^.A;   { aux [destRef, destIdx, srcByteOffset, count] }
        IrUnpack(AIns^.Imm, TypeIdx, DataIdx);
        DataAddr := Inst.DataAddrs[DataIdx];
        AStore.Heap.ArrayInitFromData(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          AStore.Datas[DataAddr].Data, AStore.Datas[DataAddr].Size,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].U64,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32);
      end;
    iroArrayInitElem:
      begin
        Aux := AIns^.A;   { aux [destRef, destIdx, srcElemOffset, count] }
        IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
        ElemAddr := Inst.ElemAddrs[ElemIdx];
        AStore.Heap.ArrayInitFromElem(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          AStore.Elems[ElemAddr].Refs,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32);
      end;

    { extern.convert_any / any.convert_extern: route through the same GC
      wrapper pair the interpreter uses so a subsequent ref.test/ref.cast
      classifies the value in the right hierarchy (M7). The JIT inherits the
      interpreter's semantics because it calls the identical helpers — the
      differential oracle requires it. }
    iroExternConvertAny:
      ValueSetRef(Reg[AIns^.Dest], AStore.Heap.ExternalizeAny(Reg[AIns^.A].Ref));
    iroAnyConvertExtern:
      ValueSetRef(Reg[AIns^.Dest], AStore.Heap.InternalizeExtern(Reg[AIns^.A].Ref));
    iroRefI31:
      Reg[AIns^.Dest].Bits := UInt64(MakeI31Ref(Reg[AIns^.A].I32));
    iroI31GetS:
      begin
        if RefIsNull(Reg[AIns^.A].Ref) then
          TrapNow(wtkNullI31Reference);
        ValueSetI32(Reg[AIns^.Dest], I31GetSigned(Reg[AIns^.A].Ref));
      end;
    iroI31GetU:
      begin
        if RefIsNull(Reg[AIns^.A].Ref) then
          TrapNow(wtkNullI31Reference);
        ValueSetU32(Reg[AIns^.Dest], I31GetUnsigned(Reg[AIns^.A].Ref));
      end;
  end;
end;

{ The single cdecl dispatcher every non-branch memory/table/ref/global/GC
  template calls: (store, register-file base, IR-instruction pointer). It
  derives the current activation for the op's index spaces and aux blocks, and
  runs the interpreter's exact logic. cdecl = AAPCS64, so the emitted call
  sequence (x0..x2, x19..x28 preserved) is fully specified. }
procedure JitRtDispatch(const AStore: TWasmStore; const ARegBase: PWasmValue;
  const AIns: PWasmIrInstr); cdecl;
var
  Act: PWasmActivation;
begin
  Act := Arm64TopActivation(AStore);
  case AIns^.Op of
    iroI32Load, iroI64Load, iroF32Load, iroF64Load,
    iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
    iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
    iroI64Load32S, iroI64Load32U,
    iroI32Store, iroI64Store, iroF32Store, iroF64Store,
    iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16, iroI64Store32,
    iroMemorySize, iroMemoryGrow, iroMemoryInit, iroMemoryCopy, iroMemoryFill,
    iroDataDrop:
      JitDoMem(AStore, ARegBase, Act, AIns);

    iroTableGet, iroTableSet, iroTableSize, iroTableGrow, iroTableFill,
    iroTableInit, iroTableCopy, iroElemDrop:
      JitDoTable(AStore, ARegBase, Act, AIns);

    iroRefNull, iroRefIsNull, iroRefFunc, iroRefEq, iroRefAsNonNull,
    iroRefTest, iroRefCast:
      JitDoRef(AStore, ARegBase, Act, AIns);

    iroGlobalGet, iroGlobalSet:
      JitDoGlobal(AStore, ARegBase, Act, AIns);
  else
    JitDoGc(AStore, ARegBase, Act, AIns);
  end;
end;

{ The ref-branch predicate helper (br_on_null/non_null/cast/cast_fail). Returns
  the PRIMITIVE predicate P — RefIsNull for the null forms, the runtime cast
  match for the cast forms — and the emitted code chooses the taken polarity
  (cbnz when the branch is taken on P, cbz when on not-P) and threads the
  fall-through refinement, mirroring the interpreter's arms exactly. }
function JitRefBranchPredicate(const AStore: TWasmStore;
  const ARegBase: PWasmValue; const AIns: PWasmIrInstr): PtrUInt; cdecl;
var
  Act: PWasmActivation;
  Reg: PWasmValue;
begin
  Act := Arm64TopActivation(AStore);
  Reg := ARegBase;
  case AIns^.Op of
    iroBrOnNull, iroBrOnNonNull:
      Result := PtrUInt(Ord(RefIsNull(Reg[AIns^.A].Ref)));
  else
    { iroBrOnCast / iroBrOnCastFail }
    Result := PtrUInt(Ord(JitMatchesAuxRefType(AStore, Act, Reg[AIns^.A].Ref,
      UInt32(AIns^.Imm))));
  end;
end;

{ ===================================================================== }
{  Wave 6 — v128 SIMD via the Wasm.Interp.Vector leaves (jit-spec §10.1) }
{ ===================================================================== }

{ THE PATTERN, and why it is the whole of this wave. Every v128 op is the SAME
  uniform three-argument helper call the Wave 4/5 runtime ops use (store,
  register-file base, IR-instruction pointer), dispatched by JitVecDispatch to
  JitDoVec — which reproduces the interpreter's v128 arms VERBATIM, calling the
  identical Wasm.Interp.Vector leaves. So the per-lane NaN discipline, the
  saturating/narrowing arithmetic, pmin/pmax's payload-preserving selection,
  and the relaxed-SIMD deterministic profile (R=0) are the interpreter's exact
  bits BY CONSTRUCTION (simd-spec §9, jit-spec §13) — the JIT computes no vector
  arithmetic of its own.

  THE 2-SLOT REGISTER FILE IS TRANSPARENT. A v128 register k occupies the two
  adjacent 8-byte slots k and k+1 (simd-spec §1.3); VecAt(Reg, k) aliases the
  pair as a TWasmV128. Because the dispatcher reads and writes the in-memory
  register file directly through x19 (never marshaling operands into machine
  registers), the two-slot layout needs NO special case — it is inherited from
  the interpreter's own VecAt addressing, exactly as jit-spec §10.1 states. The
  register file is 16-byte aligned at every even slot (Wasm.Interp's context
  over-aligns the reservation), and the IR guarantees a v128 register lands on
  an even slot, so VecAt's pointer is always 16-aligned.

  THE CHOKEPOINT (§7). The SIMD load/store family (plain, packed, splat, zero,
  and the lane forms) reaches memory ONLY through Store.MemAddressAt — the one
  bounds-checked chokepoint — so a v128 access traps 'out of bounds memory
  access' at the same index with the same message as the interpreter, and a
  trapping store writes nothing (the range is checked before any byte moves).

  GC SAFEPOINT / TRAP-1. The v128 GC ops (struct/array field get/set/fill) go
  through the same Store.Heap methods the interpreter uses; every helper here is
  a leaf whose locals are plain scalars/records with no managed fields, so a
  chokepoint/heap TrapNow's LongJmp to the trampoline abandons nothing. }


{ The cdecl dispatcher every v128 template calls (store, register-file base,
  IR-instruction pointer) — the same three-argument shape JitRtDispatch uses,
  routed to JitDoVec so no memory/table/GC op ever lands in the vector body.
  cdecl = AAPCS64. }
procedure JitVecDispatch(const AStore: TWasmStore; const ARegBase: PWasmValue;
  const AIns: PWasmIrInstr); cdecl;
begin
  JitDoVec(AStore, ARegBase, Arm64TopActivation(AStore), AIns);
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

function Arm64MemRegOffset(const AUnsignedBase: UInt32;
  const ARt, ARn, ARm: Byte; const AAddr64: Boolean): UInt32;
var
  ExtendBits: UInt32;
begin
  if AAddr64 then
    ExtendBits := $6800             { [Xn,Xm] }
  else
    ExtendBits := $4800;            { [Xn,Wm,UXTW] }
  { Every scalar load/store unsigned-offset prefix is exactly $00E00000 above
    its register-offset prefix across the byte/half/word/dword sign variants. }
  Result := (AUnsignedBase - $00E00000) or (UInt32(ARm) shl 16) or ExtendBits or
    (UInt32(ARn) shl 5) or ARt;
end;

function Arm64LdrQ(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
begin
  Result := $3DC00000 or ((AByteOffset div 16) shl 10)
    or (UInt32(ARn) shl 5) or ARt;
end;

function Arm64StrQ(const ARt, ARn: Byte; const AByteOffset: UInt32): UInt32;
begin
  Result := $3D800000 or ((AByteOffset div 16) shl 10)
    or (UInt32(ARn) shl 5) or ARt;
end;

function Arm64VecAnd(const AVd, AVn, AVm: Byte): UInt32;
begin
  Result := $4E201C00 or (UInt32(AVm) shl 16) or (UInt32(AVn) shl 5) or AVd;
end;

function Arm64VecBic(const AVd, AVn, AVm: Byte): UInt32;
begin
  Result := $4E601C00 or (UInt32(AVm) shl 16) or (UInt32(AVn) shl 5) or AVd;
end;

function Arm64VecOrr(const AVd, AVn, AVm: Byte): UInt32;
begin
  Result := $4EA01C00 or (UInt32(AVm) shl 16) or (UInt32(AVn) shl 5) or AVd;
end;

function Arm64VecEor(const AVd, AVn, AVm: Byte): UInt32;
begin
  Result := $6E201C00 or (UInt32(AVm) shl 16) or (UInt32(AVn) shl 5) or AVd;
end;

function Arm64VecMvn(const AVd, AVn: Byte): UInt32;
begin
  Result := $6E205800 or (UInt32(AVn) shl 5) or AVd;
end;

function Arm64VecAdd(const AVd, AVn, AVm, ASize: Byte): UInt32;
begin
  Result := $4E208400 or (UInt32(ASize and 3) shl 22)
    or (UInt32(AVm) shl 16) or (UInt32(AVn) shl 5) or AVd;
end;

function Arm64VecSub(const AVd, AVn, AVm, ASize: Byte): UInt32;
begin
  Result := $6E208400 or (UInt32(ASize and 3) shl 22)
    or (UInt32(AVm) shl 16) or (UInt32(AVn) shl 5) or AVd;
end;

function Arm64VecDup(const AVd, ARn, ASize: Byte): UInt32;
begin
  Result := $4E000C00 or (UInt32(1 shl ASize) shl 16)
    or (UInt32(ARn) shl 5) or AVd;
end;

function Arm64VecExtract(const ARd, AVn, ASize, ALane: Byte;
  const ASigned: Boolean): UInt32;
var
  Imm5: UInt32;
begin
  Imm5 := (UInt32(ALane) shl (ASize + 1)) or UInt32(1 shl ASize);
  if (ASize = 3) and (not ASigned) then
    Result := $4E003C00
  else if ASigned then
    Result := $0E002C00
  else
    Result := $0E003C00;
  Result := Result or (Imm5 shl 16) or (UInt32(AVn) shl 5) or ARd;
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

function Arm64MaddX(const ARd, ARn, ARm, ARa: Byte): UInt32;
begin
  { MADD Xd,Xn,Xm,Xa — the general three-operand form Arm64MulX specializes.
    The X-form base is $9B (bit31 sf=1 above the $1B W-form); $8B would be a
    plain shifted-register ADD. }
  Result := $9B000000 or (UInt32(ARm) shl 16) or (UInt32(ARa) shl 10) or
    (UInt32(ARn) shl 5) or ARd;
end;

function Arm64SdivW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $1AC00C00 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64SdivX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $9AC00C00 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64UdivW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $1AC00800 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64UdivX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $9AC00800 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64MsubW(const ARd, ARn, ARm, ARa: Byte): UInt32;
begin
  Result := $1B008000 or (UInt32(ARm) shl 16) or (UInt32(ARa) shl 10)
    or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64MsubX(const ARd, ARn, ARm, ARa: Byte): UInt32;
begin
  Result := $9B008000 or (UInt32(ARm) shl 16) or (UInt32(ARa) shl 10)
    or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AndW(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $0A000000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AndLowMaskImmW(const ARd, ARn, AOnes: Byte): UInt32;
begin
  Result := $12000000 or (UInt32(AOnes - 1) shl 10) or
    (UInt32(ARn) shl 5) or ARd;
end;

function Arm64LslImmW(const ARd, ARn, AShift: Byte): UInt32;
var
  Shift: Byte;
begin
  Shift := AShift and 31;
  Result := $53000000 or (UInt32((32 - Shift) and 31) shl 16) or
    (UInt32(31 - Shift) shl 10) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64LsrImmW(const ARd, ARn, AShift: Byte): UInt32;
begin
  { LSR Wd,Wn,#s = UBFM Wd,Wn,#s,#31. }
  Result := $53000000 or (UInt32(AShift and 31) shl 16) or
    (UInt32(31) shl 10) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64AddImmW(const ARd, ARn: Byte;
  const AImm12: UInt32): UInt32;
begin
  Result := $11000000 or ((AImm12 and $FFF) shl 10) or
    (UInt32(ARn) shl 5) or ARd;
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

function Arm64UbfizW(const ARd, ARn, ALsb, AWidth: Byte): UInt32;
begin
  Result := $53000000 or (UInt32((32 - ALsb) and 31) shl 16) or
    (UInt32(AWidth - 1) shl 10) or (UInt32(ARn) shl 5) or ARd;
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

function Arm64FmovSFromW(const ASd, AWn: Byte): UInt32;
begin
  Result := $1E270000 or (UInt32(AWn) shl 5) or ASd;
end;

function Arm64FmovWFromS(const AWd, ASn: Byte): UInt32;
begin
  Result := $1E260000 or (UInt32(ASn) shl 5) or AWd;
end;

function Arm64FmovDFromX(const ADd, AXn: Byte): UInt32;
begin
  Result := $9E670000 or (UInt32(AXn) shl 5) or ADd;
end;

function Arm64FmovXFromD(const AXd, ADn: Byte): UInt32;
begin
  Result := $9E660000 or (UInt32(ADn) shl 5) or AXd;
end;

function Arm64FpBinary(const ABase: UInt32; const ADd, ADn,
  ADm: Byte): UInt32;
begin
  Result := ABase or (UInt32(ADm) shl 16) or (UInt32(ADn) shl 5) or ADd;
end;

function Arm64FaddS(const ASd, ASn, ARm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E202800, ASd, ASn, ARm);
end;

function Arm64FsubS(const ASd, ASn, ARm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E203800, ASd, ASn, ARm);
end;

function Arm64FmulS(const ASd, ASn, ARm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E200800, ASd, ASn, ARm);
end;

function Arm64FdivS(const ASd, ASn, ARm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E201800, ASd, ASn, ARm);
end;

function Arm64FaddD(const ADd, ADn, ADm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E602800, ADd, ADn, ADm);
end;

function Arm64FsubD(const ADd, ADn, ADm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E603800, ADd, ADn, ADm);
end;

function Arm64FmulD(const ADd, ADn, ADm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E600800, ADd, ADn, ADm);
end;

function Arm64FdivD(const ADd, ADn, ADm: Byte): UInt32;
begin
  Result := Arm64FpBinary($1E601800, ADd, ADn, ADm);
end;

function Arm64FcmpS(const ASn, ARm: Byte): UInt32;
begin
  Result := $1E202000 or (UInt32(ARm) shl 16) or (UInt32(ASn) shl 5);
end;

function Arm64FcmpD(const ADn, ADm: Byte): UInt32;
begin
  Result := $1E602000 or (UInt32(ADm) shl 16) or (UInt32(ADn) shl 5);
end;

function Arm64ScvtfSW(const ASd, AWn: Byte): UInt32;
begin
  Result := $1E220000 or (UInt32(AWn) shl 5) or ASd;
end;

function Arm64ScvtfSX(const ASd, AXn: Byte): UInt32;
begin
  Result := $9E220000 or (UInt32(AXn) shl 5) or ASd;
end;

function Arm64ScvtfDW(const ADd, AWn: Byte): UInt32;
begin
  Result := $1E620000 or (UInt32(AWn) shl 5) or ADd;
end;

function Arm64ScvtfDX(const ADd, AXn: Byte): UInt32;
begin
  Result := $9E620000 or (UInt32(AXn) shl 5) or ADd;
end;

function Arm64UcvtfSW(const ASd, AWn: Byte): UInt32;
begin
  Result := $1E230000 or (UInt32(AWn) shl 5) or ASd;
end;

function Arm64UcvtfDW(const ADd, AWn: Byte): UInt32;
begin
  Result := $1E630000 or (UInt32(AWn) shl 5) or ADd;
end;

function Arm64FcvtSD(const ASd, ADn: Byte): UInt32;
begin
  Result := $1E624000 or (UInt32(ADn) shl 5) or ASd;
end;

function Arm64FcvtDS(const ADd, ASn: Byte): UInt32;
begin
  Result := $1E22C000 or (UInt32(ASn) shl 5) or ADd;
end;

function Arm64SxtbW(const AWd, AWn: Byte): UInt32;
begin
  Result := $13001C00 or (UInt32(AWn) shl 5) or AWd;
end;

function Arm64SxthW(const AWd, AWn: Byte): UInt32;
begin
  Result := $13003C00 or (UInt32(AWn) shl 5) or AWd;
end;

function Arm64SxtbX(const AXd, AWn: Byte): UInt32;
begin
  Result := $93401C00 or (UInt32(AWn) shl 5) or AXd;
end;

function Arm64SxthX(const AXd, AWn: Byte): UInt32;
begin
  Result := $93403C00 or (UInt32(AWn) shl 5) or AXd;
end;

function Arm64SxtwX(const AXd, AWn: Byte): UInt32;
begin
  Result := $93407C00 or (UInt32(AWn) shl 5) or AXd;
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

function Arm64AddImmXShifted(const ARd, ARn: Byte;
  const AImm12: UInt32): UInt32;
begin
  Result := $91400000 or ((AImm12 and $FFF) shl 10) or (UInt32(ARn) shl 5)
    or ARd;
end;

function Arm64SubImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
begin
  Result := $D1000000 or ((AImm12 and $FFF) shl 10) or (UInt32(ARn) shl 5)
    or ARd;
end;

function Arm64SubImmXShifted(const ARd, ARn: Byte;
  const AImm12: UInt32): UInt32;
begin
  Result := $D1400000 or ((AImm12 and $FFF) shl 10) or (UInt32(ARn) shl 5)
    or ARd;
end;

function Arm64AddExtX(const ARd, ARn, ARm: Byte): UInt32;
begin
  { ADD Xd|SP, Xn|SP, Xm, UXTX (C6.2.4). Bit 21 marks the extended form;
    option=011 (UXTX) at bits 15-13. Rd/Rn = 31 encode SP. }
  Result := $8B206000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64SubExtX(const ARd, ARn, ARm: Byte): UInt32;
begin
  Result := $CB206000 or (UInt32(ARm) shl 16) or (UInt32(ARn) shl 5) or ARd;
end;

function Arm64UnsignedOffsetFits(const AByteOffset, AScale: UInt32): Boolean;
begin
  Result := (AScale <> 0) and ((AByteOffset mod AScale) = 0)
    and ((AByteOffset div AScale) <= $FFF);
end;

function Arm64SubsImmX(const ARd, ARn: Byte;
  const AImm12: UInt32): UInt32;
begin
  Result := $F1000000 or ((AImm12 and $FFF) shl 10) or
    (UInt32(ARn) shl 5) or ARd;
end;

function Arm64Blr(const ARn: Byte): UInt32;
begin
  Result := $D63F0000 or (UInt32(ARn) shl 5);
end;

function Arm64Ret: UInt32;
begin
  Result := $D65F03C0;
end;

function Arm64StpX19X20PreIndex64: UInt32;
begin
  Result := $A9BC53F3;   { stp x19, x20, [sp, #-64]! }
end;

function Arm64StpX21X22Off16: UInt32;
begin
  Result := $A9015BF5;   { stp x21, x22, [sp, #16] }
end;

function Arm64StpX23X24Off32: UInt32;
begin
  Result := $A90263F7;   { stp x23, x24, [sp, #32] }
end;

function Arm64LdpX23X24Off32: UInt32;
begin
  Result := $A94263F7;   { ldp x23, x24, [sp, #32] }
end;

function Arm64LdpX21X22Off16: UInt32;
begin
  Result := $A9415BF5;   { ldp x21, x22, [sp, #16] }
end;

function Arm64LdpX19X20PostIndex64: UInt32;
begin
  Result := $A8C453F3;   { ldp x19, x20, [sp], #64 }
end;

function Arm64StpX19Lr(const AByteOffset: UInt32): UInt32;
begin
  Result := $A9000000 or (((AByteOffset shr 3) and $7F) shl 15)
    or (UInt32(ARM64_REG_LR) shl 10) or
    (UInt32(ARM64_REG_SP) shl 5) or ARM64_REG_REGFILE;
end;

function Arm64LdpX19Lr(const AByteOffset: UInt32): UInt32;
begin
  Result := $A9400000 or (((AByteOffset shr 3) and $7F) shl 15)
    or (UInt32(ARM64_REG_LR) shl 10) or
    (UInt32(ARM64_REG_SP) shl 5) or ARM64_REG_REGFILE;
end;

function Arm64StpX19LrPre(const AFrameBytes: UInt32): UInt32;
begin
  { STP x19,x30,[sp,#-frame]!: signed imm7 scaled by 8. The native-self proof
    caps register files at 32 slots, so its 32..272-byte frames fit exactly. }
  Result := $A9800000 or
    ((UInt32(-(Int64(AFrameBytes) div 8)) and $7F) shl 15) or
    (UInt32(ARM64_REG_LR) shl 10) or
    (UInt32(ARM64_REG_SP) shl 5) or ARM64_REG_REGFILE;
end;

function Arm64LdpX19LrPost(const AFrameBytes: UInt32): UInt32;
begin
  { LDP x19,x30,[sp],#frame: the matching signed imm7 post-index form. }
  Result := $A8C00000 or (((AFrameBytes div 8) and $7F) shl 15) or
    (UInt32(ARM64_REG_LR) shl 10) or
    (UInt32(ARM64_REG_SP) shl 5) or ARM64_REG_REGFILE;
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

function Arm64BlPlaceholder: UInt32;
begin
  Result := $94000000;   { bl #0 }
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

procedure Arm64EmitFormAddr(const ABuf: TWasmCodeBuffer; const ARd, ARn: Byte;
  const AOffset: UInt32);
var
  Hi, Lo: UInt32;
  Scratch: Byte;
begin
  if AOffset = 0 then
  begin
    { ADD Xd,Xn,#0 copies SP when Rn/Rd is 31; ORR-as-MOV would read XZR. }
    if ARd <> ARn then
      ABuf.EmitU32(Arm64AddImmX(ARd, ARn, 0));
    Exit;
  end;
  if AOffset <= $FFF then
  begin
    ABuf.EmitU32(Arm64AddImmX(ARd, ARn, AOffset));
    Exit;
  end;
  if ((AOffset and $FFF) = 0) and ((AOffset shr 12) <= $FFF) then
  begin
    ABuf.EmitU32(Arm64AddImmXShifted(ARd, ARn, AOffset shr 12));
    Exit;
  end;
  if AOffset <= $FFFFFF then
  begin
    Hi := AOffset shr 12;
    Lo := AOffset and $FFF;
    ABuf.EmitU32(Arm64AddImmXShifted(ARd, ARn, Hi));
    if Lo <> 0 then
      ABuf.EmitU32(Arm64AddImmX(ARd, ARd, Lo));
    Exit;
  end;
  Scratch := ARM64_REG_ADDR;
  if (ARd = Scratch) or (ARn = Scratch) then
    Scratch := ARM64_REG_T2;
  if (ARd = Scratch) or (ARn = Scratch) then
    Scratch := ARM64_REG_T1;
  Arm64EmitLoadImm32(ABuf, Scratch, AOffset);
  ABuf.EmitU32(Arm64AddExtX(ARd, ARn, Scratch));
end;

procedure Arm64EmitAddImmXAny(const ABuf: TWasmCodeBuffer;
  const ARd, ARn: Byte; const AImm: UInt32);
begin
  Arm64EmitFormAddr(ABuf, ARd, ARn, AImm);
end;

procedure Arm64EmitSubImmXAny(const ABuf: TWasmCodeBuffer;
  const ARd, ARn: Byte; const AImm: UInt32);
var
  Hi, Lo: UInt32;
  Scratch: Byte;
begin
  if AImm = 0 then
  begin
    if ARd <> ARn then
      ABuf.EmitU32(Arm64SubImmX(ARd, ARn, 0));
    Exit;
  end;
  if AImm <= $FFF then
  begin
    ABuf.EmitU32(Arm64SubImmX(ARd, ARn, AImm));
    Exit;
  end;
  if ((AImm and $FFF) = 0) and ((AImm shr 12) <= $FFF) then
  begin
    ABuf.EmitU32(Arm64SubImmXShifted(ARd, ARn, AImm shr 12));
    Exit;
  end;
  if AImm <= $FFFFFF then
  begin
    Hi := AImm shr 12;
    Lo := AImm and $FFF;
    ABuf.EmitU32(Arm64SubImmXShifted(ARd, ARn, Hi));
    if Lo <> 0 then
      ABuf.EmitU32(Arm64SubImmX(ARd, ARd, Lo));
    Exit;
  end;
  Scratch := ARM64_REG_ADDR;
  if (ARd = Scratch) or (ARn = Scratch) then
    Scratch := ARM64_REG_T2;
  if (ARd = Scratch) or (ARn = Scratch) then
    Scratch := ARM64_REG_T1;
  Arm64EmitLoadImm32(ABuf, Scratch, AImm);
  ABuf.EmitU32(Arm64SubExtX(ARd, ARn, Scratch));
end;

function Arm64StoreAddrScratch(const ARt: Byte): Byte;
begin
  if ARt <> ARM64_REG_ADDR then
    Result := ARM64_REG_ADDR
  else
    Result := ARM64_REG_T2;
end;

procedure Arm64EmitLdrW(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  if Arm64UnsignedOffsetFits(AByteOffset, 4) then
    ABuf.EmitU32(Arm64LdrW(ARt, ARn, AByteOffset))
  else
  begin
    Arm64EmitFormAddr(ABuf, ARt, ARn, AByteOffset);
    ABuf.EmitU32(Arm64LdrW(ARt, ARt, 0));
  end;
end;

procedure Arm64EmitLdrX(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  if Arm64UnsignedOffsetFits(AByteOffset, 8) then
    ABuf.EmitU32(Arm64LdrX(ARt, ARn, AByteOffset))
  else
  begin
    Arm64EmitFormAddr(ABuf, ARt, ARn, AByteOffset);
    ABuf.EmitU32(Arm64LdrX(ARt, ARt, 0));
  end;
end;

procedure Arm64EmitStrW(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
var
  Scratch: Byte;
begin
  if Arm64UnsignedOffsetFits(AByteOffset, 4) then
    ABuf.EmitU32(Arm64StrW(ARt, ARn, AByteOffset))
  else
  begin
    Scratch := Arm64StoreAddrScratch(ARt);
    Arm64EmitFormAddr(ABuf, Scratch, ARn, AByteOffset);
    ABuf.EmitU32(Arm64StrW(ARt, Scratch, 0));
  end;
end;

procedure Arm64EmitStrX(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
var
  Scratch: Byte;
begin
  if Arm64UnsignedOffsetFits(AByteOffset, 8) then
    ABuf.EmitU32(Arm64StrX(ARt, ARn, AByteOffset))
  else
  begin
    Scratch := Arm64StoreAddrScratch(ARt);
    Arm64EmitFormAddr(ABuf, Scratch, ARn, AByteOffset);
    ABuf.EmitU32(Arm64StrX(ARt, Scratch, 0));
  end;
end;

procedure Arm64EmitLdrQ(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  if Arm64UnsignedOffsetFits(AByteOffset, 16) then
    ABuf.EmitU32(Arm64LdrQ(ARt, ARn, AByteOffset))
  else
  begin
    Arm64EmitFormAddr(ABuf, ARM64_REG_ADDR, ARn, AByteOffset);
    ABuf.EmitU32(Arm64LdrQ(ARt, ARM64_REG_ADDR, 0));
  end;
end;

procedure Arm64EmitStrQ(const ABuf: TWasmCodeBuffer; const ARt, ARn: Byte;
  const AByteOffset: UInt32);
begin
  if Arm64UnsignedOffsetFits(AByteOffset, 16) then
    ABuf.EmitU32(Arm64StrQ(ARt, ARn, AByteOffset))
  else
  begin
    Arm64EmitFormAddr(ABuf, ARM64_REG_ADDR, ARn, AByteOffset);
    ABuf.EmitU32(Arm64StrQ(ARt, ARM64_REG_ADDR, 0));
  end;
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
  ABuf.EmitU32(Arm64StpX19X20PreIndex64);      { stp x19,x20,[sp,#-64]! }
  ABuf.EmitU32(Arm64StpX21X22Off16);           { stp x21,x22,[sp,#16] }
  ABuf.EmitU32(Arm64StpX23X24Off32);           { stp x23,x24,[sp,#32] }
  ABuf.EmitU32(Arm64StrX(ARM64_REG_LR, ARM64_REG_ZR, 48)); { str x30,[sp,#48] }
  ABuf.EmitU32(Arm64StrX(ARM64_REG_MEMORY, ARM64_REG_ZR, 56));
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_REGFILE, 0));  { mov x19,x0 (regbase) }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_STORE, 1));    { mov x20,x1 (store) }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_IRBASE, 2));   { mov x23,x2 (IR base) }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_MEMORY, 3));   { mov x25,x3 (context) }
end;

procedure Arm64EmitPrologueExtended(const ABuf: TWasmCodeBuffer);
begin
  { Reserve one aligned callee-saved slot above the established 64-byte frame.
    Functions with a measured-useful third static allocation or a pinned
    native-self entry pay this. }
  ABuf.EmitU32(Arm64SubImmX(ARM64_REG_SP, ARM64_REG_SP, 16));
  Arm64EmitPrologue(ABuf);
  ABuf.EmitU32(Arm64StrX(ARM64_REG_CACHE_STATIC2, ARM64_REG_ZR, 64));
end;

procedure Arm64EmitPinHelperTable(const ABuf: TWasmCodeBuffer;
  const AHelperTableOffset: NativeUInt);
begin
  { x24 := Store.JitHelperTable — the per-process helper-table base, loaded once
    and held callee-saved so every helper call is a single indexed load + blr.
    The field is pointer-aligned; load it directly when the scaled offset fits
    LDR's imm12, else form the address in a scratch first. }
  if ((AHelperTableOffset and 7) = 0) and ((AHelperTableOffset shr 3) < $1000) then
    Arm64EmitLdrX(ABuf, ARM64_REG_HELPERTABLE, ARM64_REG_STORE,
      UInt32(AHelperTableOffset))
  else
  begin
    Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, UInt64(AHelperTableOffset));
    ABuf.EmitU32(Arm64AddX(ARM64_REG_T0, ARM64_REG_STORE, ARM64_REG_T0));
    Arm64EmitLdrX(ABuf, ARM64_REG_HELPERTABLE, ARM64_REG_T0, 0);
  end;
end;

procedure Arm64EmitCallHelper(const ABuf: TWasmCodeBuffer;
  const AHelper: TWasmAotHelper);
begin
  { ldr x9,[x24,#k*8]; blr x9 — position-independent: the code holds only the
    stable slot index k, the table holds the live address. }
  Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_HELPERTABLE,
    UInt32(Ord(AHelper)) * 8);
  ABuf.EmitU32(Arm64Blr(ARM64_REG_T0));
end;

procedure Arm64EmitPinMemory(const ABuf: TWasmCodeBuffer;
  const AMemoryIndex: UInt32; const ABaseOnly: Boolean);
var
  Layout: TWasmMemoryInst;
begin
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));
  Arm64EmitLoadImm32(ABuf, 1, AMemoryIndex);
  Arm64EmitCallHelper(ABuf, aohResolveMemory);
  if ABaseOnly then
    Arm64EmitLdrX(ABuf, ARM64_REG_MEMORY, 0,
      UInt32(PtrUInt(@Layout.Base) - PtrUInt(@Layout)))
  else
    ABuf.EmitU32(Arm64MovReg(ARM64_REG_MEMORY, 0));
end;

procedure Arm64EmitIrInsPtr(const ABuf: TWasmCodeBuffer; const ADestReg: Byte;
  const AInsIndex: UInt32);
var
  Offset: UInt64;
begin
  Offset := UInt64(AInsIndex) * SizeOf(TWasmIrInstr);
  if Offset < $1000 then
    ABuf.EmitU32(Arm64AddImmX(ADestReg, ARM64_REG_IRBASE, UInt32(Offset)))
  else
  begin
    { i*stride exceeds ADD's 12-bit immediate: materialise it (movz/movk into the
      scratch x9) and add as a register. }
    Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, Offset);
    ABuf.EmitU32(Arm64AddX(ADestReg, ARM64_REG_IRBASE, ARM64_REG_T0));
  end;
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

procedure Arm64EmitNativeSelfBudget(const ABuf: TWasmCodeBuffer;
  const ARegisterCount: UInt32);
var
  FO: TWasmJitFrameOffsets;
begin
  FO := WasmJitFrameOffsets;
  { The external wrapper already owns one fully visible logical/value/GC
    activation. Pin the exact number of additional lightweight activations
    admitted by both interpreter limits:

      min(DepthCap - Depth, (ValueCap - ValueTop) div RegisterCount)

    The proof gate guarantees RegisterCount is in 1..32. The wrapper prologue
    preserves x26 for AAPCS callers; the local recursive core shares it. }
  Arm64EmitLdrX(ABuf, 9, ARM64_REG_MEMORY, UInt32(FO.CtxDepthCap));
  Arm64EmitLdrX(ABuf, 10, ARM64_REG_MEMORY, UInt32(FO.CtxDepth));
  ABuf.EmitU32(Arm64SubX(ARM64_REG_NATIVE_BUDGET, 9, 10));
  Arm64EmitLdrX(ABuf, 9, ARM64_REG_MEMORY, UInt32(FO.CtxValueCap));
  Arm64EmitLdrX(ABuf, 10, ARM64_REG_MEMORY, UInt32(FO.CtxValueTop));
  ABuf.EmitU32(Arm64SubX(9, 9, 10));
  Arm64EmitLoadImm64(ABuf, 10, ARegisterCount);
  ABuf.EmitU32(Arm64UdivX(9, 9, 10));
  ABuf.EmitU32(Arm64CmpX(9, ARM64_REG_NATIVE_BUDGET));
  ABuf.EmitU32(Arm64CselX(ARM64_REG_NATIVE_BUDGET, 9,
    ARM64_REG_NATIVE_BUDGET, ARM64_COND_LO));
end;

procedure Arm64EmitEpilogue(const ABuf: TWasmCodeBuffer);
begin
  ABuf.EmitU32(Arm64LdrX(ARM64_REG_MEMORY, ARM64_REG_ZR, 56));
  ABuf.EmitU32(Arm64LdrX(ARM64_REG_LR, ARM64_REG_ZR, 48));  { ldr x30,[sp,#48] }
  ABuf.EmitU32(Arm64LdpX23X24Off32);           { ldp x23,x24,[sp,#32] }
  ABuf.EmitU32(Arm64LdpX21X22Off16);           { ldp x21,x22,[sp,#16] }
  ABuf.EmitU32(Arm64LdpX19X20PostIndex64);     { ldp x19,x20,[sp],#64 }
  ABuf.EmitU32(Arm64Ret);
end;

procedure Arm64EmitEpilogueExtended(const ABuf: TWasmCodeBuffer);
begin
  ABuf.EmitU32(Arm64LdrX(ARM64_REG_CACHE_STATIC2, ARM64_REG_ZR, 64));
  ABuf.EmitU32(Arm64LdrX(ARM64_REG_MEMORY, ARM64_REG_ZR, 56));
  ABuf.EmitU32(Arm64LdrX(ARM64_REG_LR, ARM64_REG_ZR, 48));
  ABuf.EmitU32(Arm64LdpX23X24Off32);
  ABuf.EmitU32(Arm64LdpX21X22Off16);
  ABuf.EmitU32(Arm64LdpX19X20PostIndex64);
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_SP, ARM64_REG_SP, 16));
  ABuf.EmitU32(Arm64Ret);
end;

procedure Arm64ResolvePatches(const ABuf: TWasmCodeBuffer);
var
  I: Integer;
  P: TWasmJitPatch;
  Base, Instr, Inverted: UInt32;
  Delta, Imm: Integer;
begin
  { Kind 0 means a consumed overflow site that was rewritten in place. New B
    veneers are appended and resolved in the same walk. }
  I := 0;
  while I < ABuf.PatchCount do
  begin
    P := ABuf.GetPatch(I);
    if P.Kind = 0 then
    begin
      Inc(I);
      Continue;
    end;
    Base := UInt32(P.Kind);
    Delta := ABuf.PatchDelta(I);
    Imm := Delta div 4;
    if (Base and $7C000000) = $14000000 then
    begin
      if not Arm64SignedImmFits(Imm, 26) then
        raise EWasmJitBranchRange.CreateFmt(
          'JIT: B/BL displacement %d does not fit imm26', [Delta]);
      Instr := Base or (UInt32(Imm) and $03FFFFFF);
      ABuf.PatchU32(P.SiteOffset, Instr);
    end
    else if Arm64SignedImmFits(Imm, 19) then
    begin
      Instr := Base or ((UInt32(Imm) and $7FFFF) shl 5);
      ABuf.PatchU32(P.SiteOffset, Instr);
    end
    else
    begin
      { Invert the 4-byte conditional so it skips an inserted B, which then
        carries the original target with imm26 reach. }
      if (Base and $FF000010) = $54000000 then
        Inverted := (Base and $FFFFFFF0) or ((Base xor 1) and $F)
      else
        Inverted := Base xor $01000000;
      ABuf.InsertU32(P.SiteOffset + 4, Arm64BPlaceholder);
      ABuf.PatchU32(P.SiteOffset, Inverted or (UInt32(2) shl 5));
      ABuf.AddPatch(P.SiteOffset + 4, P.Target, Integer(Arm64BPlaceholder));
      ABuf.SetPatchKind(I, 0);
    end;
    Inc(I);
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

procedure LdQ(const ABuf: TWasmCodeBuffer; const AVt: Byte; const AReg: UInt32);
begin
  Arm64EmitLdrQ(ABuf, AVt, ARM64_REG_REGFILE, Arm64SlotByteOffset(AReg));
end;

procedure StQ(const ABuf: TWasmCodeBuffer; const AVt: Byte; const AReg: UInt32);
begin
  Arm64EmitStrQ(ABuf, AVt, ARM64_REG_REGFILE, Arm64SlotByteOffset(AReg));
end;

function Arm64CacheHostReg(const AIndex: Integer): Byte;
begin
  case AIndex of
    0: Result := ARM64_REG_CACHE0;
    1: Result := ARM64_REG_CACHE1;
    2: Result := ARM64_REG_CACHE_STATIC2;
    3: Result := ARM64_REG_CACHE2;
    4: Result := ARM64_REG_CACHE3;
    5: Result := ARM64_REG_CACHE4;
  else Result := ARM64_REG_CACHE5;
  end;
end;

procedure Arm64InitRegCache(out ACache: TArm64RegCache);
begin
  FillChar(ACache, SizeOf(ACache), 0);
  { The original dynamic pool is x14..x17 (entries 3..6). }
  ACache.DynBase := 3;
  ACache.DynCount := 4;
  ACache.ConstFrom := High(Byte);
end;

procedure Arm64EnableStaticRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlots: array of UInt32);
var
  I: Integer;
begin
  Arm64InitRegCache(ACache);
  ACache.StaticAllocation := True;
  for I := 0 to High(ASlots) do
    if ASlots[I] <> High(UInt32) then
    begin
      ACache.Entries[ACache.StaticCount].Valid := True;
      ACache.Entries[ACache.StaticCount].Slot := ASlots[I];
      LdX(ABuf, Arm64CacheHostReg(ACache.StaticCount), ASlots[I]);
      Inc(ACache.StaticCount);
  end;
end;

{ Append loop-invariant constant slots behind the leading statics. Each host
  register is seeded ONCE with its immediate at frame entry; the defining
  const instruction emits nothing, so a value that sat inside the loop body
  stops being rebuilt on every iteration. }
procedure Arm64EnableConstSlots(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlots: array of UInt32;
  const ABits: array of UInt64);
var
  I: Integer;
begin
  if not ACache.StaticAllocation then
    Exit;
  ACache.ConstFrom := ACache.StaticCount;
  for I := 0 to High(ASlots) do
  begin
    if (I > High(ABits)) or (ASlots[I] = High(UInt32)) or
      (ACache.StaticCount > High(ACache.Entries)) then
      Continue;
    Arm64EmitLoadImm64(ABuf, Arm64CacheHostReg(ACache.StaticCount), ABits[I]);
    ACache.Entries[ACache.StaticCount].Valid := True;
    ACache.Entries[ACache.StaticCount].Slot := ASlots[I];
    Inc(ACache.StaticCount);
  end;
  ACache.DynBase := ACache.StaticCount;
  ACache.DynCount := Byte(High(ACache.Entries) + 1 - ACache.DynBase);
  { The round-robin cursor ranged over the old four-register pool. }
  if ACache.Next >= ACache.DynCount then
    ACache.Next := 0;
end;

{ True when ASlot is served by one of the appended constant entries; the
  defining iro*Const may then emit nothing. Slot numbers are unique per SSA
  value, and the driver never hands an already-allocated slot here, so a hit
  is unambiguous. }
function Arm64ConstSlotHost(const ACache: TArm64RegCache;
  const ASlot: UInt32; out AHost: Byte): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := ACache.ConstFrom to ACache.StaticCount - 1 do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
    begin
      AHost := Arm64CacheHostReg(I);
      Result := True;
      Exit;
    end;
end;

procedure Arm64EnableDynamicWriteBack(var ACache: TArm64RegCache;
  const AUseCounts: PUInt32; const AVisibleSlots: PBoolean;
  const ASlotCount: UInt32);
begin
  ACache.WriteBackDynamics := True;
  ACache.UseCounts := AUseCounts;
  ACache.VisibleSlots := AVisibleSlots;
  ACache.SlotCount := ASlotCount;
end;

procedure Arm64SeedNativeCoreCache(var ACache: TArm64RegCache;
  const AParamCount, AParam0Slot, AParam1Slot: UInt32;
  const AUseLeafCapacity: Boolean);
begin
  { x12/x13 are populated by the external wrapper or lightweight caller. The
    callee slots stay absent until a flush proves they must be materialized.
    A non-recursive leaf may also use x14-x17: unlike the self-recursive ABI it
    does not reserve x26 for a frame budget, and it has no nested call whose
    register boundary would require the deliberately smaller two-entry cache. }
  if AUseLeafCapacity then
  begin
    ACache.StaticAllocation := True;
    { Keep the incoming slots fixed in x12/x13. A later local.set must update
      that exact mapping rather than create a duplicate dynamic entry whose
      older fixed mapping would win the next lookup. }
    ACache.StaticCount := Byte(AParamCount);
  end;
  { The victim pool stays x14..x17 in both modes: entry 2 (x26) is reserved by
    the self-recursion budget ABI, and the parameter entries are served by
    their fixed hosts, never round-robin. }
  ACache.Entries[0].Valid := True;
  ACache.Entries[0].Dirty := True;
  ACache.Entries[0].Slot := AParam0Slot;
  if AParamCount = 2 then
  begin
    ACache.Entries[1].Valid := True;
    ACache.Entries[1].Dirty := True;
    ACache.Entries[1].Slot := AParam1Slot;
    ACache.Next := 0;
  end
  else
    ACache.Next := 1;
end;

function Arm64EntryNeedsWriteBack(const ACache: TArm64RegCache;
  const AIndex: Integer): Boolean;
var
  Slot: UInt32;
begin
  Result := False;
  if not ACache.Entries[AIndex].Valid or
    not ACache.Entries[AIndex].Dirty then
    Exit;
  Slot := ACache.Entries[AIndex].Slot;
  if Slot >= ACache.SlotCount then
    Exit(True);
  Result := ACache.VisibleSlots[Slot] or (ACache.UseCounts[Slot] > 0);
end;

procedure Arm64SpillCacheEntry(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const AIndex: Integer);
begin
  if Arm64EntryNeedsWriteBack(ACache, AIndex) then
    StX(ABuf, Arm64CacheHostReg(AIndex), ACache.Entries[AIndex].Slot);
  ACache.Entries[AIndex].Dirty := False;
end;

procedure Arm64FlushDynamicRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache);
var
  I: Integer;
begin
  if not ACache.WriteBackDynamics then
    Exit;
  { Starts at StaticCount, not DynBase: in native-core modes the dirty
    parameter entries sit below any fixed boundary and depend on this spill
    for their canonical write-back; ordinary statics are flushed by
    FlushRegCache instead. }
  for I := ACache.StaticCount to High(ACache.Entries) do
    Arm64SpillCacheEntry(ABuf, ACache, I);
end;

procedure Arm64FlushRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache);
var
  I: Integer;
begin
  if not ACache.StaticAllocation then
  begin
    Arm64FlushDynamicRegCache(ABuf, ACache);
    Exit;
  end;
  { Emit the fixed allocation at every canonical point. This deliberately does
    not use compile-time dirty state: a forward branch may skip a writeback
    that the linear emitter visited, so path-independent stores are the safe
    reconciliation for all predecessors. }
  for I := 0 to ACache.StaticCount - 1 do
    if ACache.Entries[I].Valid then
      StX(ABuf, Arm64CacheHostReg(I), ACache.Entries[I].Slot);
  Arm64FlushDynamicRegCache(ABuf, ACache);
end;

procedure Arm64InvalidateRegCache(var ACache: TArm64RegCache);
var
  I: Integer;
begin
  if ACache.StaticAllocation then
  begin
    for I := ACache.DynBase to High(ACache.Entries) do
      ACache.Entries[I].Valid := False;
    ACache.Next := 0;
    Exit;
  end;
  ACache.Entries[0].Valid := False;
  ACache.Entries[1].Valid := False;
  ACache.Next := 0;
end;

procedure Arm64CachedLoad(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ADest: Byte; const ASlot: UInt32);
var
  I, Victim: Integer;
  Host: Byte;

  procedure ConsumeUse;
  begin
    if ACache.WriteBackDynamics and (ASlot < ACache.SlotCount) and
      (ACache.UseCounts[ASlot] > 0) then
      Dec(ACache.UseCounts[ASlot]);
  end;
begin
  for I := 0 to High(ACache.Entries) do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
    begin
      Host := Arm64CacheHostReg(I);
      if ADest <> Host then
        ABuf.EmitU32(Arm64MovReg(ADest, Host));
      ConsumeUse;
      Exit;
    end;
  if ACache.StaticAllocation then
  begin
    Victim := ACache.DynBase + ACache.Next;
    ACache.Next := Byte((ACache.Next + 1) mod ACache.DynCount);
  end
  else
  begin
    Victim := ACache.Next;
    ACache.Next := Byte(1 - ACache.Next);
  end;
  if ACache.WriteBackDynamics then
    Arm64SpillCacheEntry(ABuf, ACache, Victim);
  Host := Arm64CacheHostReg(Victim);
  LdX(ABuf, Host, ASlot);
  ACache.Entries[Victim].Valid := True;
  ACache.Entries[Victim].Dirty := False;
  ACache.Entries[Victim].Slot := ASlot;
  if ADest <> Host then
    ABuf.EmitU32(Arm64MovReg(ADest, Host));
  ConsumeUse;
end;

function Arm64CachedHostForSlot(const ACache: TArm64RegCache;
  const ASlot: UInt32; out AHost: Byte): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ACache.Entries) do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
    begin
      AHost := Arm64CacheHostReg(I);
      Exit(True);
    end;
  Result := False;
end;

function Arm64CachedSourceReg(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlot: UInt32;
  const ADefault: Byte): Byte;
var
  Victim: Integer;
begin
  if Arm64CachedHostForSlot(ACache, ASlot, Result) then
  begin
    { Keep the existing load path as the one place that consumes the planned
      use count. The established host emits no move. }
    Arm64CachedLoad(ABuf, ACache, Result, ASlot);
    Exit;
  end;
  if ACache.StaticAllocation then
  begin
    { A one-source cached operation can load a missing expression directly
      into its selected dynamic entry. This is the same round-robin victim and
      liveness spill used by CachedLoad, without an unnecessary scratch copy. }
    Victim := ACache.DynBase + ACache.Next;
    ACache.Next := Byte((ACache.Next + 1) mod ACache.DynCount);
    if ACache.WriteBackDynamics then
      Arm64SpillCacheEntry(ABuf, ACache, Victim);
    Result := Arm64CacheHostReg(Victim);
    LdX(ABuf, Result, ASlot);
    ACache.Entries[Victim].Valid := True;
    ACache.Entries[Victim].Dirty := False;
    ACache.Entries[Victim].Slot := ASlot;
    if ACache.WriteBackDynamics and (ASlot < ACache.SlotCount) and
      (ACache.UseCounts[ASlot] > 0) then
      Dec(ACache.UseCounts[ASlot]);
    Exit;
  end;
  Result := ADefault;
  { Keep the existing load path as the one place that consumes the planned use
    count in the original write-through cache. }
  Arm64CachedLoad(ABuf, ACache, Result, ASlot);
end;

function Arm64CachedStaticHostForSlot(const ACache: TArm64RegCache;
  const ASlot: UInt32; out AHost: Byte): Boolean;
var
  I: Integer;
begin
  for I := 0 to ACache.StaticCount - 1 do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
    begin
      AHost := Arm64CacheHostReg(I);
      Exit(True);
    end;
  Result := False;
end;

procedure Arm64CachedBinarySourceRegs(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ALeftSlot, ARightSlot: UInt32;
  out ALeft, ARight: Byte);
begin
  { A missing right operand can evict a dynamic entry holding the left one.
    Use host registers directly only when both lookups are already stable;
    otherwise preserve both values in the established scratch pair. }
  if Arm64CachedHostForSlot(ACache, ALeftSlot, ALeft) and
    Arm64CachedHostForSlot(ACache, ARightSlot, ARight) then
  begin
    Arm64CachedLoad(ABuf, ACache, ALeft, ALeftSlot);
    Arm64CachedLoad(ABuf, ACache, ARight, ARightSlot);
    Exit;
  end;
  { A static allocation cannot be evicted by resolving the other operand into
    x14..x17. Keep that side in its host register and load the missing side
    directly into a dynamic entry. }
  if Arm64CachedStaticHostForSlot(ACache, ALeftSlot, ALeft) then
  begin
    Arm64CachedLoad(ABuf, ACache, ALeft, ALeftSlot);
    ARight := Arm64CachedSourceReg(ABuf, ACache, ARightSlot,
      ARM64_REG_T1);
    Exit;
  end;
  if Arm64CachedStaticHostForSlot(ACache, ARightSlot, ARight) then
  begin
    ALeft := Arm64CachedSourceReg(ABuf, ACache, ALeftSlot,
      ARM64_REG_T0);
    Arm64CachedLoad(ABuf, ACache, ARight, ARightSlot);
    Exit;
  end;
  ALeft := ARM64_REG_T0;
  ARight := ARM64_REG_T1;
  Arm64CachedLoad(ABuf, ACache, ALeft, ALeftSlot);
  Arm64CachedLoad(ABuf, ACache, ARight, ARightSlot);
end;

function Arm64CachedDestReg(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASlot: UInt32;
  const AExclude0, AExclude1, ADefault: Byte): Byte;
var
  I, Offset, Attempt: Integer;
  Host: Byte;
begin
  Result := ADefault;
  for I := 0 to ACache.StaticCount - 1 do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
      Exit(Arm64CacheHostReg(I));
  if not ACache.StaticAllocation then
  begin
    if not ACache.WriteBackDynamics then
      Exit;
    for I := 0 to 1 do
      if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
      begin
        Host := Arm64CacheHostReg(I);
        if (Host = AExclude0) or (Host = AExclude1) then
          Exit;
        ACache.Entries[I].Dirty := False;
        Exit(Host);
      end;
    for Attempt := 0 to 1 do
    begin
      I := (Integer(ACache.Next) + Attempt) and 1;
      Host := Arm64CacheHostReg(I);
      if (Host = AExclude0) or (Host = AExclude1) then
        Continue;
      Arm64SpillCacheEntry(ABuf, ACache, I);
      ACache.Entries[I].Valid := True;
      ACache.Entries[I].Dirty := False;
      ACache.Entries[I].Slot := ASlot;
      ACache.Next := Byte(1 - I);
      Exit(Host);
    end;
    Exit;
  end;
  { Reuse an established dynamic destination only when it is not an operand.
    If it is an operand, retain the scratch path so the input survives until
    the instruction has read it and no duplicate slot mapping is created. }
  for I := ACache.DynBase to High(ACache.Entries) do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
    begin
      Host := Arm64CacheHostReg(I);
      if (Host = AExclude0) or (Host = AExclude1) then
        Exit;
      ACache.Entries[I].Dirty := False;
      Exit(Host);
    end;
  { Reserve a non-source entry before emission. Its previous value is spilled
    through the existing liveness predicate; CachedStore marks the new value
    dirty after the instruction writes it. }
  for Attempt := 0 to ACache.DynCount - 1 do
  begin
    Offset := (Integer(ACache.Next) + Attempt) mod ACache.DynCount;
    I := ACache.DynBase + Offset;
    Host := Arm64CacheHostReg(I);
    if (Host = AExclude0) or (Host = AExclude1) then
      Continue;
    if ACache.WriteBackDynamics then
      Arm64SpillCacheEntry(ABuf, ACache, I);
    ACache.Entries[I].Valid := True;
    ACache.Entries[I].Dirty := False;
    ACache.Entries[I].Slot := ASlot;
    ACache.Next := Byte((Offset + 1) mod ACache.DynCount);
    Exit(Host);
  end;
end;

procedure Arm64CachedStore(const ABuf: TWasmCodeBuffer;
  var ACache: TArm64RegCache; const ASrc: Byte; const ASlot: UInt32);
var
  I, Victim: Integer;
  Host: Byte;
begin
  Victim := -1;
  for I := 0 to High(ACache.Entries) do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
      Victim := I;
  if ACache.StaticAllocation then
  begin
    if (Victim >= 0) and (Victim < ACache.StaticCount) then
    begin
      Host := Arm64CacheHostReg(Victim);
      if ASrc <> Host then
        ABuf.EmitU32(Arm64MovReg(Host, ASrc));
      ACache.Entries[Victim].Dirty := True;
      Exit;
    end;
    { Unallocated expression values retain the write-through cache in
      x14..x17, so static locals do not evict producer/consumer temporaries. }
    if not ACache.WriteBackDynamics then
      StX(ABuf, ASrc, ASlot);
    if Victim < ACache.StaticCount then
    begin
      Victim := ACache.DynBase + ACache.Next;
      ACache.Next := Byte((ACache.Next + 1) mod ACache.DynCount);
    end;
    if ACache.WriteBackDynamics then
      Arm64SpillCacheEntry(ABuf, ACache, Victim);
    Host := Arm64CacheHostReg(Victim);
    if ASrc <> Host then
      ABuf.EmitU32(Arm64MovReg(Host, ASrc));
    ACache.Entries[Victim].Valid := True;
    ACache.Entries[Victim].Dirty := ACache.WriteBackDynamics;
    ACache.Entries[Victim].Slot := ASlot;
    Exit;
  end;
  if ACache.WriteBackDynamics then
  begin
    if Victim < 0 then
    begin
      Victim := ACache.Next;
      ACache.Next := Byte(1 - Victim);
      Arm64SpillCacheEntry(ABuf, ACache, Victim);
    end;
    Host := Arm64CacheHostReg(Victim);
    if ASrc <> Host then
      ABuf.EmitU32(Arm64MovReg(Host, ASrc));
    ACache.Entries[Victim].Valid := True;
    ACache.Entries[Victim].Dirty := True;
    ACache.Entries[Victim].Slot := ASlot;
    Exit;
  end;
  StX(ABuf, ASrc, ASlot);
  if Victim < 0 then
  begin
    Victim := ACache.Next;
    ACache.Next := Byte(1 - Victim);
  end;
  Host := Arm64CacheHostReg(Victim);
  if ASrc <> Host then
    ABuf.EmitU32(Arm64MovReg(Host, ASrc));
  ACache.Entries[Victim].Valid := True;
  ACache.Entries[Victim].Slot := ASlot;
end;

procedure Arm64CachedAlu(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AWb: TArm64WordBin;
  var ACache: TArm64RegCache);
var
  Left, Right, Dest: Byte;
begin
  Arm64CachedBinarySourceRegs(ABuf, ACache, AIns.A, AIns.B, Left, Right);
  Dest := Arm64CachedDestReg(ABuf, ACache, AIns.Dest, Left, Right,
    ARM64_REG_T0);
  ABuf.EmitU32(AWb(Dest, Left, Right));
  Arm64CachedStore(ABuf, ACache, Dest, AIns.Dest);
end;

function Arm64CanUseI32Immediate(const AOp: TWasmIrOp;
  const AValue: UInt32): Boolean;
begin
  case AOp of
    iroI32Add: Result := AValue <= $FFF;
    iroI32And:
      Result := (AValue <> 0) and (AValue <> High(UInt32)) and
        ((AValue and (AValue + 1)) = 0);
    iroI32Shl: Result := True;
  else
    Result := False;
  end;
end;

function Arm64EmitOpCachedImmediate(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AValue: UInt32;
  var ACache: TArm64RegCache): Boolean;
var
  Mask: UInt32;
  Ones: Byte;
  Source, Dest: Byte;
begin
  Result := Arm64CanUseI32Immediate(AIns.Op, AValue);
  if not Result then
    Exit;
  Source := Arm64CachedSourceReg(ABuf, ACache, AIns.A, ARM64_REG_T0);
  Dest := Arm64CachedDestReg(ABuf, ACache, AIns.Dest, Source, ARM64_REG_ZR,
    ARM64_REG_T0);
  case AIns.Op of
    iroI32Add:
      ABuf.EmitU32(Arm64AddImmW(Dest, Source, AValue));
    iroI32And:
      begin
        Mask := AValue;
        Ones := 0;
        while Mask <> 0 do
        begin
          Inc(Ones);
          Mask := Mask shr 1;
        end;
        ABuf.EmitU32(Arm64AndLowMaskImmW(Dest, Source, Ones));
      end;
    iroI32Shl:
      ABuf.EmitU32(Arm64LslImmW(Dest, Source,
        Byte(AValue and 31)));
  end;
  Arm64CachedStore(ABuf, ACache, Dest, AIns.Dest);
end;

procedure Arm64EmitMaskedShiftCached(const ABuf: TWasmCodeBuffer;
  const ASource, ADest: UInt32; const AShift, AWidth: Byte;
  var ACache: TArm64RegCache);
var
  Source, Dest: Byte;
begin
  Source := Arm64CachedSourceReg(ABuf, ACache, ASource, ARM64_REG_T0);
  Dest := Arm64CachedDestReg(ABuf, ACache, ADest, Source, ARM64_REG_ZR,
    ARM64_REG_T0);
  ABuf.EmitU32(Arm64UbfizW(Dest, Source, AShift, AWidth));
  Arm64CachedStore(ABuf, ACache, Dest, ADest);
end;

procedure Arm64EmitCompareBranchCached(const ABuf: TWasmCodeBuffer;
  const ACompare, ABranch: TWasmIrInstr; var ACache: TArm64RegCache);
var
  Cond: Byte;
  Wide: Boolean;
  Left, Right: Byte;
begin
  Wide := False;
  case ACompare.Op of
    iroI32Eq: Cond := ARM64_COND_EQ;
    iroI32Ne: Cond := ARM64_COND_NE;
    iroI32LtS: Cond := ARM64_COND_LT;
    iroI32LtU: Cond := ARM64_COND_LO;
    iroI32GtS: Cond := ARM64_COND_GT;
    iroI32GtU: Cond := ARM64_COND_HI;
    iroI32LeS: Cond := ARM64_COND_LE;
    iroI32LeU: Cond := ARM64_COND_LS;
    iroI32GeS: Cond := ARM64_COND_GE;
    iroI32GeU: Cond := ARM64_COND_HS;
    iroI64Eq: begin Cond := ARM64_COND_EQ; Wide := True; end;
    iroI64Ne: begin Cond := ARM64_COND_NE; Wide := True; end;
    iroI64LtS: begin Cond := ARM64_COND_LT; Wide := True; end;
    iroI64LtU: begin Cond := ARM64_COND_LO; Wide := True; end;
    iroI64GtS: begin Cond := ARM64_COND_GT; Wide := True; end;
    iroI64GtU: begin Cond := ARM64_COND_HI; Wide := True; end;
    iroI64LeS: begin Cond := ARM64_COND_LE; Wide := True; end;
    iroI64LeU: begin Cond := ARM64_COND_LS; Wide := True; end;
    iroI64GeS: begin Cond := ARM64_COND_GE; Wide := True; end;
  else
    begin Cond := ARM64_COND_HS; Wide := True; end;
  end;
  if ABranch.Op = iroBranchIfNot then
    Cond := Cond xor 1;
  Arm64CachedBinarySourceRegs(ABuf, ACache, ACompare.A, ACompare.B,
    Left, Right);
  if Wide then
    ABuf.EmitU32(Arm64CmpX(Left, Right))
  else
    ABuf.EmitU32(Arm64CmpW(Left, Right));
  { STR does not alter NZCV, so reconcile live dirty expressions after CMP and
    before the fused control split without losing the comparison flags. }
  Arm64FlushDynamicRegCache(ABuf, ACache);
  EmitBCondTo(ABuf, Cond, TWasmJitLabel(ABranch.B));
  Arm64InvalidateRegCache(ACache);
end;

procedure Arm64CachedRel(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ACond: Byte; const AWide: Boolean;
  var ACache: TArm64RegCache);
begin
  Arm64CachedLoad(ABuf, ACache, ARM64_REG_T0, AIns.A);
  Arm64CachedLoad(ABuf, ACache, ARM64_REG_T1, AIns.B);
  if AWide then
    ABuf.EmitU32(Arm64CmpX(ARM64_REG_T0, ARM64_REG_T1))
  else
    ABuf.EmitU32(Arm64CmpW(ARM64_REG_T0, ARM64_REG_T1));
  ABuf.EmitU32(Arm64CsetW(ARM64_REG_T0, ACond));
  Arm64CachedStore(ABuf, ACache, ARM64_REG_T0, AIns.Dest);
end;

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

procedure Arm64EmitBlTo(const ABuf: TWasmCodeBuffer;
  const ATarget: TWasmJitLabel);
var
  Site: Integer;
begin
  Site := ABuf.CurrentOffset;
  ABuf.AddPatch(Site, ATarget, Integer(Arm64BlPlaceholder));
  ABuf.EmitU32(Arm64BlPlaceholder);
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
  Arm64EmitCallHelper(ABuf, aohTrapKind);                    { blr -> no return }
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
  Arm64EmitCallHelper(ABuf, aohOpBinary);
  StX(ABuf, 0, AIns.Dest);
end;

procedure EmitLeafUnary(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  LdX(ABuf, 1, AIns.A);
  ABuf.EmitU32(Arm64MovzW(0, UInt16(Ord(AIns.Op)), 0));
  Arm64EmitCallHelper(ABuf, aohOpUnary);
  StX(ABuf, 0, AIns.Dest);
end;

procedure EmitTrap(const ABuf: TWasmCodeBuffer; const AKind: TWasmTrapKind);
begin
  ABuf.EmitU32(Arm64MovzW(0, UInt16(Ord(AKind)), 0));
  Arm64EmitCallHelper(ABuf, aohTrapKind);
end;

procedure EmitDivRem(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AWide, ASigned, ARem: Boolean);
var
  NonZero, Safe: TWasmJitLabel;
begin
  if AWide then
  begin
    LdX(ABuf, ARM64_REG_T0, AIns.A);
    LdX(ABuf, ARM64_REG_T1, AIns.B);
    ABuf.EmitU32(Arm64CmpX(ARM64_REG_T1, ARM64_REG_ZR));
  end
  else
  begin
    LdW(ABuf, ARM64_REG_T0, AIns.A);
    LdW(ABuf, ARM64_REG_T1, AIns.B);
    ABuf.EmitU32(Arm64CmpW(ARM64_REG_T1, ARM64_REG_ZR));
  end;
  NonZero := ABuf.NewLabel;
  EmitBCondTo(ABuf, ARM64_COND_NE, NonZero);
  EmitTrap(ABuf, wtkDivideByZero);
  ABuf.BindLabel(NonZero);

  { Signed division alone traps MIN_INT / -1. Signed remainder returns zero;
    A64 SDIV itself is non-trapping and produces MIN_INT, from which MSUB
    computes the required zero remainder. }
  if ASigned and not ARem then
  begin
    Safe := ABuf.NewLabel;
    if AWide then
    begin
      Arm64EmitLoadImm64(ABuf, ARM64_REG_T2, High(UInt64));
      ABuf.EmitU32(Arm64CmpX(ARM64_REG_T1, ARM64_REG_T2));
      EmitBCondTo(ABuf, ARM64_COND_NE, Safe);
      Arm64EmitLoadImm64(ABuf, ARM64_REG_T2, UInt64(1) shl 63);
      ABuf.EmitU32(Arm64CmpX(ARM64_REG_T0, ARM64_REG_T2));
    end
    else
    begin
      Arm64EmitLoadImm32(ABuf, ARM64_REG_T2, High(UInt32));
      ABuf.EmitU32(Arm64CmpW(ARM64_REG_T1, ARM64_REG_T2));
      EmitBCondTo(ABuf, ARM64_COND_NE, Safe);
      Arm64EmitLoadImm32(ABuf, ARM64_REG_T2, UInt32(1) shl 31);
      ABuf.EmitU32(Arm64CmpW(ARM64_REG_T0, ARM64_REG_T2));
    end;
    EmitBCondTo(ABuf, ARM64_COND_NE, Safe);
    EmitTrap(ABuf, wtkIntegerOverflow);
    ABuf.BindLabel(Safe);
  end;

  if AWide then
  begin
    if ASigned then
      ABuf.EmitU32(Arm64SdivX(ARM64_REG_T2, ARM64_REG_T0, ARM64_REG_T1))
    else
      ABuf.EmitU32(Arm64UdivX(ARM64_REG_T2, ARM64_REG_T0, ARM64_REG_T1));
    if ARem then
      ABuf.EmitU32(Arm64MsubX(ARM64_REG_T0, ARM64_REG_T2,
        ARM64_REG_T1, ARM64_REG_T0))
    else
      ABuf.EmitU32(Arm64MovReg(ARM64_REG_T0, ARM64_REG_T2));
  end
  else
  begin
    if ASigned then
      ABuf.EmitU32(Arm64SdivW(ARM64_REG_T2, ARM64_REG_T0, ARM64_REG_T1))
    else
      ABuf.EmitU32(Arm64UdivW(ARM64_REG_T2, ARM64_REG_T0, ARM64_REG_T1));
    if ARem then
      ABuf.EmitU32(Arm64MsubW(ARM64_REG_T0, ARM64_REG_T2,
        ARM64_REG_T1, ARM64_REG_T0))
    else
      ABuf.EmitU32(Arm64MovReg(ARM64_REG_T0, ARM64_REG_T2));
  end;
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitCanonicalFloatResult(const ABuf: TWasmCodeBuffer;
  const AWide: Boolean; const ADest: UInt32);
var
  NanValue, Done: TWasmJitLabel;
begin
  { Arithmetic and narrowing/widening conversions must return the project's
    canonical NaN, matching Wasm.Interp.Numeric exactly. FCMP value,value sets
    V for every NaN without disturbing the result register. }
  if AWide then
    ABuf.EmitU32(Arm64FcmpD(0, 0))
  else
    ABuf.EmitU32(Arm64FcmpS(0, 0));
  NanValue := ABuf.NewLabel;
  Done := ABuf.NewLabel;
  EmitBCondTo(ABuf, ARM64_COND_VS, NanValue);
  if AWide then
    ABuf.EmitU32(Arm64FmovXFromD(ARM64_REG_T0, 0))
  else
    ABuf.EmitU32(Arm64FmovWFromS(ARM64_REG_T0, 0));
  EmitBranchTo(ABuf, UInt32(Done));
  ABuf.BindLabel(NanValue);
  if AWide then
    Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, WASM_F64_CANONICAL_NAN)
  else
    Arm64EmitLoadImm32(ABuf, ARM64_REG_T0, WASM_F32_CANONICAL_NAN);
  ABuf.BindLabel(Done);
  StX(ABuf, ARM64_REG_T0, ADest);
end;

procedure EmitFloatBinary(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AWide: Boolean;
  const AWord: TArm64WordBin);
begin
  if AWide then
  begin
    LdX(ABuf, ARM64_REG_T0, AIns.A);
    LdX(ABuf, ARM64_REG_T1, AIns.B);
    ABuf.EmitU32(Arm64FmovDFromX(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FmovDFromX(1, ARM64_REG_T1));
  end
  else
  begin
    LdW(ABuf, ARM64_REG_T0, AIns.A);
    LdW(ABuf, ARM64_REG_T1, AIns.B);
    ABuf.EmitU32(Arm64FmovSFromW(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FmovSFromW(1, ARM64_REG_T1));
  end;
  ABuf.EmitU32(AWord(0, 0, 1));
  EmitCanonicalFloatResult(ABuf, AWide, AIns.Dest);
end;

procedure EmitFloatRel(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AWide: Boolean; const ACond: Byte);
begin
  if AWide then
  begin
    LdX(ABuf, ARM64_REG_T0, AIns.A);
    LdX(ABuf, ARM64_REG_T1, AIns.B);
    ABuf.EmitU32(Arm64FmovDFromX(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FmovDFromX(1, ARM64_REG_T1));
    ABuf.EmitU32(Arm64FcmpD(0, 1));
  end
  else
  begin
    LdW(ABuf, ARM64_REG_T0, AIns.A);
    LdW(ABuf, ARM64_REG_T1, AIns.B);
    ABuf.EmitU32(Arm64FmovSFromW(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FmovSFromW(1, ARM64_REG_T1));
    ABuf.EmitU32(Arm64FcmpS(0, 1));
  end;
  ABuf.EmitU32(Arm64CsetW(ARM64_REG_T0, ACond));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitIntegerConversion(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AWord: UInt32; const ALoadWide: Boolean);
begin
  if ALoadWide then
    LdX(ABuf, ARM64_REG_T0, AIns.A)
  else
    LdW(ABuf, ARM64_REG_T0, AIns.A);
  if AWord <> 0 then
    ABuf.EmitU32(AWord);
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitIntToFloat(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ASourceWide, AResultWide,
  AUnsigned: Boolean);
begin
  if ASourceWide then
    LdX(ABuf, ARM64_REG_T0, AIns.A)
  else
    LdW(ABuf, ARM64_REG_T0, AIns.A);
  if AResultWide then
  begin
    if AUnsigned then
      ABuf.EmitU32(Arm64UcvtfDW(0, ARM64_REG_T0))
    else if ASourceWide then
      ABuf.EmitU32(Arm64ScvtfDX(0, ARM64_REG_T0))
    else
      ABuf.EmitU32(Arm64ScvtfDW(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FmovXFromD(ARM64_REG_T0, 0));
  end
  else
  begin
    if AUnsigned then
      ABuf.EmitU32(Arm64UcvtfSW(0, ARM64_REG_T0))
    else if ASourceWide then
      ABuf.EmitU32(Arm64ScvtfSX(0, ARM64_REG_T0))
    else
      ABuf.EmitU32(Arm64ScvtfSW(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FmovWFromS(ARM64_REG_T0, 0));
  end;
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitFloatWidthConversion(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ADemote: Boolean);
begin
  if ADemote then
  begin
    LdX(ABuf, ARM64_REG_T0, AIns.A);
    ABuf.EmitU32(Arm64FmovDFromX(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FcvtSD(0, 0));
    EmitCanonicalFloatResult(ABuf, False, AIns.Dest);
  end
  else
  begin
    LdW(ABuf, ARM64_REG_T0, AIns.A);
    ABuf.EmitU32(Arm64FmovSFromW(0, ARM64_REG_T0));
    ABuf.EmitU32(Arm64FcvtDS(0, 0));
    EmitCanonicalFloatResult(ABuf, True, AIns.Dest);
  end;
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

{ --- the call templates (§4.4/§4.5): marshal -> helper -> unmarshal ------

  Layout of the native-stack scratch a call site reserves:

      sp + 0                 .. arg slot 0 .. arg slot (ArgN-1)
      sp + ArgN*8            .. result slot 0 .. result slot (ResN-1)
      total rounded up to 16 (AAPCS64 keeps sp 16-byte aligned at all times;
      SP is also the base register of the marshaling stores, which faults if
      misaligned)

  The scratch is released BEFORE the epilogue, because the epilogue addresses
  the prologue's saves off sp. A trap inside the helper never returns here;
  the trampoline's LongJmp restores sp from the invocation setjmp (ADR-0009),
  so the un-executed `add sp` is harmless. }

function Arm64Align16(const AValue: UInt32): UInt32;
begin
  Result := (AValue + 15) and not UInt32(15);
end;

{ The scratch frame a call site needs: args then results, never zero (so the
  two buffer pointers are always valid distinct addresses). }
function Arm64CallFrameBytes(const AArgSlots, AResultSlots: UInt32): UInt32;
begin
  Result := Arm64Align16((AArgSlots + AResultSlots) * ARM64_SLOT_SIZE);
  if Result = 0 then
    Result := 16;
end;

{ Copy the IR's argument registers into the flat scratch, one slot per aux
  entry — the block already spells a v128's two halves separately, so this is
  the interpreter's flat block with no vector special case. }
procedure EmitMarshalArgs(const ABuf: TWasmCodeBuffer;
  const AAux: TWasmIrAuxU32; const ABlock, ACount: UInt32);
var
  I: UInt32;
begin
  I := 0;
  while I < ACount do
  begin
    LdX(ABuf, ARM64_REG_T0, IrAuxBlockItem(AAux, ABlock, I));
    Arm64EmitStrX(ABuf, ARM64_REG_T0, ARM64_REG_SP, I * ARM64_SLOT_SIZE);
    Inc(I);
  end;
end;

{ The mirror image, after the helper returns: flat result slots back into the
  IR's destination registers. }
procedure EmitUnmarshalResults(const ABuf: TWasmCodeBuffer;
  const AAux: TWasmIrAuxU32; const ABlock, ACount, AOffset: UInt32);
var
  I: UInt32;
begin
  I := 0;
  while I < ACount do
  begin
    Arm64EmitLdrX(ABuf, ARM64_REG_T0, ARM64_REG_SP,
      AOffset + I * ARM64_SLOT_SIZE);
    StX(ABuf, ARM64_REG_T0, IrAuxBlockItem(AAux, ABlock, I));
    Inc(I);
  end;
end;

{ A one- or two-slot-parameter/one-result static call can publish and retire
  its logical frame entirely in generated code. Resolution stays
  instance-relative and position-independent: the caller activation supplies
  the live function
  address map, the context supplies an indirection to Store.Funcs, and each
  function instance supplies prelinked pointers into freshly validated IR.
  No helper is crossed on the compiled fast path. }
procedure EmitNativeScalarDirectCall(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AArgBytes, AStateOffset: UInt32;
  const AFallback, ADone: TWasmJitLabel);
var
  FO: TWasmJitFrameOffsets;
  FuncLayout: TWasmFuncInst;
  StateLayout: TWasmJitDirectCallState;
  FuncDirectEntry, FuncInstance: UInt32;
  MetaFn, MetaIrBase, MetaFuncAddrs, MetaEntryZeroRegs,
    MetaRefRegBits, MetaRegisterCount, MetaEntryZeroCount,
    MetaParam0Reg, MetaParam1Reg, MetaResult0Reg: UInt32;
  StateRegBase, StateIrBase, StateCtx, StateEntry, StateGcFrameSlot,
    StateResultReg: UInt32;
  ZeroLoop, ZeroDone, Exhausted: TWasmJitLabel;
begin
  FO := WasmJitFrameOffsets;
  FuncDirectEntry := UInt32(PtrUInt(@FuncLayout.CompiledDirectEntry) -
    PtrUInt(@FuncLayout));
  FuncInstance := UInt32(PtrUInt(@FuncLayout.Instance) -
    PtrUInt(@FuncLayout));
  MetaFn := UInt32(PtrUInt(@FuncLayout.DirectMeta.Fn) - PtrUInt(@FuncLayout));
  MetaIrBase := UInt32(PtrUInt(@FuncLayout.DirectMeta.IrBase) -
    PtrUInt(@FuncLayout));
  MetaFuncAddrs := UInt32(PtrUInt(@FuncLayout.DirectMeta.FuncAddrs) -
    PtrUInt(@FuncLayout));
  MetaEntryZeroRegs := UInt32(PtrUInt(@FuncLayout.DirectMeta.EntryZeroRegs) -
    PtrUInt(@FuncLayout));
  MetaRefRegBits := UInt32(PtrUInt(@FuncLayout.DirectMeta.RefRegBits) -
    PtrUInt(@FuncLayout));
  MetaRegisterCount := UInt32(PtrUInt(@FuncLayout.DirectMeta.RegisterCount) -
    PtrUInt(@FuncLayout));
  MetaEntryZeroCount := UInt32(PtrUInt(@FuncLayout.DirectMeta.EntryZeroCount) -
    PtrUInt(@FuncLayout));
  MetaParam0Reg := UInt32(PtrUInt(@FuncLayout.DirectMeta.Param0Reg) -
    PtrUInt(@FuncLayout));
  MetaParam1Reg := UInt32(PtrUInt(@FuncLayout.DirectMeta.Param1Reg) -
    PtrUInt(@FuncLayout));
  MetaResult0Reg := UInt32(PtrUInt(@FuncLayout.DirectMeta.Result0Reg) -
    PtrUInt(@FuncLayout));
  StateRegBase := UInt32(PtrUInt(@StateLayout.RegBase) - PtrUInt(@StateLayout));
  StateIrBase := UInt32(PtrUInt(@StateLayout.IrBase) - PtrUInt(@StateLayout));
  StateCtx := UInt32(PtrUInt(@StateLayout.Ctx) - PtrUInt(@StateLayout));
  StateEntry := UInt32(PtrUInt(@StateLayout.Entry) - PtrUInt(@StateLayout));
  StateGcFrameSlot := UInt32(PtrUInt(@StateLayout.GcFrameSlot) -
    PtrUInt(@StateLayout));
  StateResultReg := UInt32(PtrUInt(@StateLayout.ScalarResultReg) -
    PtrUInt(@StateLayout));

  ZeroLoop := ABuf.NewLabel;
  ZeroDone := ABuf.NewLabel;
  Exhausted := ABuf.NewLabel;

  { x25 is the current context for functions without pinned memory. Resolve
    caller funcidx -> store address -> live function instance. }
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxDepth));
  ABuf.EmitU32(Arm64SubImmX(2, 1, 1));
  Arm64EmitLoadImm64(ABuf, 3, FO.ActStride);
  ABuf.EmitU32(Arm64MulX(2, 2, 3));
  Arm64EmitLdrX(ABuf, 3, ARM64_REG_MEMORY, UInt32(FO.CtxActs));
  ABuf.EmitU32(Arm64AddX(2, 3, 2));
  Arm64EmitLdrX(ABuf, 1, 2, UInt32(FO.ActFuncAddrs));
  Arm64EmitLoadImm64(ABuf, 8, UInt64(UInt32(AIns.Imm)) * 4);
  ABuf.EmitU32(Arm64AddX(1, 1, 8));
  Arm64EmitLdrW(ABuf, 2, 1, 0);
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxFuncsSlot));
  Arm64EmitLdrX(ABuf, 1, 1, 0);
  Arm64EmitLoadImm64(ABuf, 8, SizeOf(TWasmFuncInst));
  ABuf.EmitU32(Arm64MulX(2, 2, 8));
  ABuf.EmitU32(Arm64AddX(3, 1, 2));
  Arm64EmitLdrX(ABuf, 9, 3, FuncDirectEntry);
  ABuf.EmitU32(Arm64CmpX(9, ARM64_REG_ZR));
  EmitBCondTo(ABuf, ARM64_COND_EQ, AFallback);

  { Exhaustion is checked before the first logical-frame mutation. }
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxDepth));
  Arm64EmitLdrX(ABuf, 8, ARM64_REG_MEMORY, UInt32(FO.CtxDepthCap));
  ABuf.EmitU32(Arm64CmpX(1, 8));
  EmitBCondTo(ABuf, ARM64_COND_HS, Exhausted);
  Arm64EmitLdrX(ABuf, 2, ARM64_REG_MEMORY, UInt32(FO.CtxValueTop));
  Arm64EmitLdrW(ABuf, 8, 3, MetaRegisterCount);
  ABuf.EmitU32(Arm64AddX(13, 2, 8));
  Arm64EmitLdrX(ABuf, 10, ARM64_REG_MEMORY, UInt32(FO.CtxValueCap));
  ABuf.EmitU32(Arm64CmpX(13, 10));
  EmitBCondTo(ABuf, ARM64_COND_HI, Exhausted);

  { x6 := activation[depth], x5 := Values[old ValueTop]. }
  Arm64EmitLoadImm64(ABuf, 8, FO.ActStride);
  ABuf.EmitU32(Arm64MulX(8, 1, 8));
  Arm64EmitLdrX(ABuf, 6, ARM64_REG_MEMORY, UInt32(FO.CtxActs));
  ABuf.EmitU32(Arm64AddX(6, 6, 8));
  Arm64EmitLdrX(ABuf, 5, ARM64_REG_MEMORY, UInt32(FO.CtxValues));
  Arm64EmitLoadImm64(ABuf, 12, 8);
  ABuf.EmitU32(Arm64MulX(8, 2, 12));
  ABuf.EmitU32(Arm64AddX(5, 5, 8));

  Arm64EmitLdrX(ABuf, 8, 3, MetaFn);
  Arm64EmitStrX(ABuf, 8, 6, UInt32(FO.ActFn));
  Arm64EmitLdrX(ABuf, 8, 3, FuncInstance);
  Arm64EmitStrX(ABuf, 8, 6, UInt32(FO.ActInstance));
  Arm64EmitLdrX(ABuf, 8, 3, MetaFuncAddrs);
  Arm64EmitStrX(ABuf, 8, 6, UInt32(FO.ActFuncAddrs));
  Arm64EmitStrW(ABuf, ARM64_REG_ZR, 6, UInt32(FO.ActIP));
  Arm64EmitStrX(ABuf, 2, 6, UInt32(FO.ActBase));
  Arm64EmitStrX(ABuf, 13, ARM64_REG_MEMORY, UInt32(FO.CtxValueTop));

  { Sparse entry zeroing precedes parameter publication and GC visibility. }
  Arm64EmitLdrX(ABuf, 10, 3, MetaEntryZeroRegs);
  Arm64EmitLdrW(ABuf, 11, 3, MetaEntryZeroCount);
  ABuf.BindLabel(ZeroLoop);
  EmitCbzTo(ABuf, 11, UInt32(ZeroDone));
  Arm64EmitLdrW(ABuf, 8, 10, 0);
  ABuf.EmitU32(Arm64MulX(8, 8, 12));
  ABuf.EmitU32(Arm64MemRegOffset($F9000000, ARM64_REG_ZR, 5, 8, True));
  ABuf.EmitU32(Arm64AddImmX(10, 10, 4));
  ABuf.EmitU32(Arm64SubImmX(11, 11, 1));
  EmitBranchTo(ABuf, UInt32(ZeroLoop));
  ABuf.BindLabel(ZeroDone);
  Arm64EmitLdrW(ABuf, 8, 3, MetaParam0Reg);
  ABuf.EmitU32(Arm64MulX(8, 8, 12));
  Arm64EmitLdrX(ABuf, 10, ARM64_REG_SP, 0);
  ABuf.EmitU32(Arm64MemRegOffset($F9000000, 10, 5, 8, True));
  if AArgBytes = 2 * ARM64_SLOT_SIZE then
  begin
    Arm64EmitLdrW(ABuf, 8, 3, MetaParam1Reg);
    ABuf.EmitU32(Arm64MulX(8, 8, 12));
    Arm64EmitLdrX(ABuf, 10, ARM64_REG_SP, ARM64_SLOT_SIZE);
    ABuf.EmitU32(Arm64MemRegOffset($F9000000, 10, 5, 8, True));
  end;

  Arm64EmitStrW(ABuf, ARM64_REG_ZR, 6, UInt32(FO.ActRetKind));
  Arm64EmitStrX(ABuf, ARM64_REG_ZR, 6, UInt32(FO.ActRetDest));
  Arm64EmitStrW(ABuf, ARM64_REG_ZR, 6, UInt32(FO.ActRetCount));
  Arm64EmitStrX(ABuf, ARM64_REG_ZR, 6, UInt32(FO.ActRetBase));
  ABuf.EmitU32(Arm64AddImmX(8, ARM64_REG_SP, AArgBytes));
  Arm64EmitStrX(ABuf, 8, 6, UInt32(FO.ActEntryResults));

  { Publish the precise frame only after every reference slot is initialized. }
  Arm64EmitLdrX(ABuf, 7, ARM64_REG_MEMORY, UInt32(FO.CtxGcFrameSlot));
  ABuf.EmitU32(Arm64AddImmX(8, 6, UInt32(FO.ActGcFrame)));
  Arm64EmitLdrX(ABuf, 10, 7, 0);
  Arm64EmitStrX(ABuf, 10, 8, UInt32(FO.GcFramePrev));
  Arm64EmitStrX(ABuf, 5, 8, UInt32(FO.GcFrameSlots));
  Arm64EmitLdrX(ABuf, 10, 3, MetaRefRegBits);
  Arm64EmitStrX(ABuf, 10, 8, UInt32(FO.GcFrameRefRegBits));
  Arm64EmitLdrW(ABuf, 10, 3, MetaRegisterCount);
  Arm64EmitStrW(ABuf, 10, 8, UInt32(FO.GcFrameRegisterCount));
  Arm64EmitLdrX(ABuf, 10, 3, FuncInstance);
  Arm64EmitStrX(ABuf, 10, 8, UInt32(FO.GcFrameInstance));
  Arm64EmitStrX(ABuf, 8, 7, 0);
  ABuf.EmitU32(Arm64AddImmX(1, 1, 1));
  Arm64EmitStrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxDepth));

  { Preserve the normal-return retirement state across the native callee. }
  Arm64EmitStrX(ABuf, 5, ARM64_REG_SP, AStateOffset + StateRegBase);
  Arm64EmitLdrX(ABuf, 2, 3, MetaIrBase);
  Arm64EmitStrX(ABuf, 2, ARM64_REG_SP, AStateOffset + StateIrBase);
  Arm64EmitStrX(ABuf, ARM64_REG_MEMORY, ARM64_REG_SP, AStateOffset + StateCtx);
  Arm64EmitStrX(ABuf, 6, ARM64_REG_SP, AStateOffset + StateEntry);
  Arm64EmitStrX(ABuf, 7, ARM64_REG_SP, AStateOffset + StateGcFrameSlot);
  Arm64EmitLdrW(ABuf, 8, 3, MetaResult0Reg);
  Arm64EmitStrW(ABuf, 8, ARM64_REG_SP, AStateOffset + StateResultReg);

  Arm64EmitLdrX(ABuf, 9, 3, FuncDirectEntry);
  ABuf.EmitU32(Arm64MovReg(0, 5));
  ABuf.EmitU32(Arm64MovReg(1, ARM64_REG_STORE));
  ABuf.EmitU32(Arm64MovReg(3, ARM64_REG_MEMORY));
  ABuf.EmitU32(Arm64MovReg(4, 9));
  ABuf.EmitU32(Arm64Blr(9));

  { Normal return: copy the scalar result, unlink the GC frame, and retire
    ValueTop/Depth. Abnormal exits longjmp and never execute this block. }
  Arm64EmitLdrX(ABuf, 0, ARM64_REG_SP, AStateOffset + StateCtx);
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_SP, AStateOffset + StateEntry);
  Arm64EmitLdrX(ABuf, 2, ARM64_REG_SP, AStateOffset + StateRegBase);
  Arm64EmitLdrW(ABuf, 3, ARM64_REG_SP, AStateOffset + StateResultReg);
  Arm64EmitLdrX(ABuf, 4, ARM64_REG_SP, AStateOffset + StateGcFrameSlot);
  Arm64EmitLdrX(ABuf, 5, 1, UInt32(FO.ActEntryResults));
  Arm64EmitLoadImm64(ABuf, 6, 8);
  ABuf.EmitU32(Arm64MulX(3, 3, 6));
  ABuf.EmitU32(Arm64MemRegOffset($F9400000, 6, 2, 3, True));
  Arm64EmitStrX(ABuf, 6, 5, 0);
  Arm64EmitLdrX(ABuf, 5, 1, UInt32(FO.ActGcFrame + FO.GcFramePrev));
  Arm64EmitStrX(ABuf, 5, 4, 0);
  Arm64EmitLdrX(ABuf, 5, 1, UInt32(FO.ActBase));
  Arm64EmitStrX(ABuf, 5, 0, UInt32(FO.CtxValueTop));
  Arm64EmitLdrX(ABuf, 5, 0, UInt32(FO.CtxDepth));
  ABuf.EmitU32(Arm64SubImmX(5, 5, 1));
  Arm64EmitStrX(ABuf, 5, 0, UInt32(FO.CtxDepth));
  EmitBranchTo(ABuf, UInt32(ADone));

  ABuf.BindLabel(Exhausted);
  Arm64EmitLoadImm32(ABuf, 0, UInt32(Ord(wtkStackExhausted)));
  Arm64EmitCallHelper(ABuf, aohTrapKind);
end;

{ Proof-gated self recursion for a closed helper-free numeric function. The
  callee's register file lives on the native stack. The external wrapper pins
  the exact remaining logical/value-frame budget in x26, so recursive frames
  need no observable Depth/ValueTop updates. There are no references,
  allocations, host calls, interpreted escapes, or throwing instructions in
  the eligible graph. Consequently each recursive stack map is empty: the
  wrapper's one fully published logical/GC frame remains the sole root, while
  lightweight frames contain numeric bits only and cannot reach a collector.
  Ordinary calls are not epoch safepoints; only IR-marked loop back-edges poll,
  exactly as in the interpreter. Traps longjmp to the invocation trampoline
  and discard x26; normal returns restore it after each local call. }
procedure EmitNativeScalarSelfCallReg(const ABuf: TWasmCodeBuffer;
  const ARegisterCount: UInt32;
  const ACoreLabel, AExhaustedLabel: TWasmJitLabel);
var
  FrameBytes: UInt32;
begin
  FrameBytes := Arm64Align16(ARegisterCount * ARM64_SLOT_SIZE) + 16;

  { Subtract-and-test the exact budget before native-stack mutation. An
    exhausted path discards the underflowed callee-saved register while
    unwinding to the invocation trampoline. A call is not an epoch safepoint;
    the local core retains ordinary IR back-edge checks emitted below. }
  ABuf.EmitU32(Arm64SubsImmX(ARM64_REG_NATIVE_BUDGET,
    ARM64_REG_NATIVE_BUDGET, 1));
  EmitBCondTo(ABuf, ARM64_COND_LO, AExhaustedLabel);
  { Allocate the frame and preserve x19/LR in one pre-index pair store. The
    numeric register file begins 16 bytes above SP and remains aligned. x12
    carries the parameter directly into the local core. }
  ABuf.EmitU32(Arm64StpX19LrPre(FrameBytes));

  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_REGFILE, ARM64_REG_SP, 16));
  Arm64EmitBlTo(ABuf, ACoreLabel);

  ABuf.EmitU32(Arm64LdpX19LrPost(FrameBytes));
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_NATIVE_BUDGET,
    ARM64_REG_NATIVE_BUDGET, 1));
end;

procedure EmitNativeScalarSelfCall(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const ARegisterCount, AParamReg, AResultReg: UInt32;
  const ACoreLabel, AExhaustedLabel: TWasmJitLabel);
begin
  { Canonical fallback retained for callers outside the cached local ABI. }
  LdX(ABuf, 12, IrAuxBlockItem(AAux, AIns.A, 0));
  EmitNativeScalarSelfCallReg(ABuf, ARegisterCount, ACoreLabel,
    AExhaustedLabel);
  StX(ABuf, 12, IrAuxBlockItem(AAux, AIns.B, 0));
end;

{ A compiled numeric leaf has no call, allocation, reference, handler,
  safepoint, or trapping operation that can observe a published activation.
  Check the exact logical/value caps, then enter its native-stack scalar ABI.
  A nil entry preserves the generic compiled/interpreted/host fallback. }
procedure EmitNativeScalarLeafDirectCall(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AArgN: UInt32; const AFallback, ADone: TWasmJitLabel);
var
  FO: TWasmJitFrameOffsets;
  FuncLayout: TWasmFuncInst;
  FuncNativeEntry, MetaRegisterCount: UInt32;
  Exhausted: TWasmJitLabel;
begin
  FO := WasmJitFrameOffsets;
  FuncNativeEntry := UInt32(
    PtrUInt(@FuncLayout.CompiledNativeScalarEntry) - PtrUInt(@FuncLayout));
  MetaRegisterCount := UInt32(
    PtrUInt(@FuncLayout.DirectMeta.RegisterCount) - PtrUInt(@FuncLayout));
  Exhausted := ABuf.NewLabel;

  { Resolve caller funcidx -> store address -> live function instance. }
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxDepth));
  ABuf.EmitU32(Arm64SubImmX(2, 1, 1));
  Arm64EmitLoadImm64(ABuf, 3, FO.ActStride);
  ABuf.EmitU32(Arm64MulX(2, 2, 3));
  Arm64EmitLdrX(ABuf, 3, ARM64_REG_MEMORY, UInt32(FO.CtxActs));
  ABuf.EmitU32(Arm64AddX(2, 3, 2));
  Arm64EmitLdrX(ABuf, 1, 2, UInt32(FO.ActFuncAddrs));
  Arm64EmitLoadImm64(ABuf, 8, UInt64(UInt32(AIns.Imm)) * 4);
  ABuf.EmitU32(Arm64AddX(1, 1, 8));
  Arm64EmitLdrW(ABuf, 2, 1, 0);
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxFuncsSlot));
  Arm64EmitLdrX(ABuf, 1, 1, 0);
  Arm64EmitLoadImm64(ABuf, 8, SizeOf(TWasmFuncInst));
  ABuf.EmitU32(Arm64MulX(2, 2, 8));
  ABuf.EmitU32(Arm64AddX(3, 1, 2));
  Arm64EmitLdrX(ABuf, 9, 3, FuncNativeEntry);
  ABuf.EmitU32(Arm64CmpX(9, ARM64_REG_ZR));
  EmitBCondTo(ABuf, ARM64_COND_EQ, AFallback);

  { Match JitEnterResolvedFrame's two exhaustion predicates without mutation. }
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxDepth));
  Arm64EmitLdrX(ABuf, 8, ARM64_REG_MEMORY, UInt32(FO.CtxDepthCap));
  ABuf.EmitU32(Arm64CmpX(1, 8));
  EmitBCondTo(ABuf, ARM64_COND_HS, Exhausted);
  Arm64EmitLdrX(ABuf, 1, ARM64_REG_MEMORY, UInt32(FO.CtxValueTop));
  Arm64EmitLdrW(ABuf, 8, 3, MetaRegisterCount);
  ABuf.EmitU32(Arm64AddX(1, 1, 8));
  Arm64EmitLdrX(ABuf, 8, ARM64_REG_MEMORY, UInt32(FO.CtxValueCap));
  ABuf.EmitU32(Arm64CmpX(1, 8));
  EmitBCondTo(ABuf, ARM64_COND_HI, Exhausted);

  LdX(ABuf, 12, IrAuxBlockItem(AAux, AIns.A, 0));
  if AArgN = 2 then
    LdX(ABuf, 13, IrAuxBlockItem(AAux, AIns.A, 1));
  ABuf.EmitU32(Arm64MovReg(4, ARM64_REG_ZR));
  ABuf.EmitU32(Arm64Blr(9));
  StX(ABuf, 12, IrAuxBlockItem(AAux, AIns.B, 0));
  EmitBranchTo(ABuf, UInt32(ADone));

  ABuf.BindLabel(Exhausted);
  Arm64EmitLoadImm32(ABuf, 0, UInt32(Ord(wtkStackExhausted)));
  Arm64EmitCallHelper(ABuf, aohTrapKind);
end;

{ iroCall / iroCallIndirect / iroCallRef. x0 is always the store (pinned in
  x20); the callee selector differs per form (funcidx immediate / packed
  type+table immediate plus the index operand / the funcref operand), and the
  last two arguments are always the arg and result scratch pointers. }
procedure EmitCall(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32; const AUsePinnedMemory,
  ANativeScalarSelf: Boolean; const ANativeRegisterCount,
  ANativeParamReg, ANativeResultReg: UInt32;
  const ANativeCoreLabel, ANativeExhaustedLabel: TWasmJitLabel);
var
  ArgN, ResN, ArgBytes, ResBytes, StateOffset, FrameBytes: UInt32;
  FallbackLabel, DoneLabel, NativeFallback, NativeDone: TWasmJitLabel;
  UseNativeLeaf: Boolean;
begin
  if ANativeScalarSelf and (AIns.Op = iroCall) then
  begin
    EmitNativeScalarSelfCall(ABuf, AIns, AAux, ANativeRegisterCount,
      ANativeParamReg, ANativeResultReg, ANativeCoreLabel,
      ANativeExhaustedLabel);
    Exit;
  end;
  ArgN := IrAuxBlockCount(AAux, AIns.A);
  ResN := IrAuxBlockCount(AAux, AIns.B);
  UseNativeLeaf := (AIns.Op = iroCall) and (ArgN in [1, 2]) and
    (ResN = 1) and not AUsePinnedMemory;
  NativeFallback := -1;
  NativeDone := -1;
  if UseNativeLeaf then
  begin
    NativeFallback := ABuf.NewLabel;
    NativeDone := ABuf.NewLabel;
    EmitNativeScalarLeafDirectCall(ABuf, AIns, AAux, ArgN,
      NativeFallback, NativeDone);
    ABuf.BindLabel(NativeFallback);
  end;
  ArgBytes := ArgN * ARM64_SLOT_SIZE;
  ResBytes := ResN * ARM64_SLOT_SIZE;
  StateOffset := ArgBytes + ResBytes;
  if AIns.Op = iroCall then
    FrameBytes := Arm64Align16(StateOffset +
      SizeOf(TWasmJitDirectCallState))
  else
    FrameBytes := Arm64CallFrameBytes(ArgN, ResN);

  Arm64EmitSubImmXAny(ABuf, ARM64_REG_SP, ARM64_REG_SP, FrameBytes);
  EmitMarshalArgs(ABuf, AAux, AIns.A, ArgN);
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));

  case AIns.Op of
    iroCall:
      begin
        { Static compiled callee: enter its shared logical/GC frame once, call
          its native entry directly, then use the shared result/pop path. The
          nil return falls back to the existing host/interpreter dispatcher. }
        FallbackLabel := ABuf.NewLabel;
        DoneLabel := ABuf.NewLabel;
        if (ArgN in [1, 2]) and (ResN = 1) and not AUsePinnedMemory then
          EmitNativeScalarDirectCall(ABuf, AIns, ArgBytes, StateOffset,
            FallbackLabel, DoneLabel)
        else
        begin
          Arm64EmitLoadImm32(ABuf, 1, UInt32(AIns.Imm));
          ABuf.EmitU32(Arm64AddImmX(2, ARM64_REG_SP, 0));
          Arm64EmitAddImmXAny(ABuf, 3, ARM64_REG_SP, ArgBytes);
          Arm64EmitAddImmXAny(ABuf, 4, ARM64_REG_SP, StateOffset);
          if (ArgN = 1) and (ResN = 1) then
            Arm64EmitCallHelper(ABuf, aohDirectCallPrepareScalar)
          else
            Arm64EmitCallHelper(ABuf, aohDirectCallPrepare);
          ABuf.EmitU32(Arm64CmpX(0, 31));
          EmitBCondTo(ABuf, ARM64_COND_EQ, FallbackLabel);
          ABuf.EmitU32(Arm64MovReg(ARM64_REG_T0, 0));
          Arm64EmitLdrX(ABuf, 0, ARM64_REG_SP, StateOffset);
          ABuf.EmitU32(Arm64MovReg(1, ARM64_REG_STORE));
          Arm64EmitLdrX(ABuf, 2, ARM64_REG_SP,
            StateOffset + ARM64_SLOT_SIZE);
          Arm64EmitLdrX(ABuf, 3, ARM64_REG_SP,
            StateOffset + 2 * ARM64_SLOT_SIZE);
          ABuf.EmitU32(Arm64MovReg(4, ARM64_REG_T0));
          ABuf.EmitU32(Arm64Blr(ARM64_REG_T0));
          if (ArgN = 1) and (ResN = 1) then
          begin
            Arm64EmitLdrX(ABuf, 0, ARM64_REG_SP,
              StateOffset + 2 * ARM64_SLOT_SIZE);
            Arm64EmitLdrX(ABuf, 1, ARM64_REG_SP,
              StateOffset + 3 * ARM64_SLOT_SIZE);
            Arm64EmitLdrX(ABuf, 2, ARM64_REG_SP, StateOffset);
            Arm64EmitLdrW(ABuf, 3, ARM64_REG_SP,
              StateOffset + 5 * ARM64_SLOT_SIZE);
            Arm64EmitLdrX(ABuf, 4, ARM64_REG_SP,
              StateOffset + 4 * ARM64_SLOT_SIZE);
            Arm64EmitCallHelper(ABuf, aohDirectCallFinishScalar)
          end
          else
          begin
            ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));
            Arm64EmitCallHelper(ABuf, aohDirectCallFinish);
          end;
          EmitBranchTo(ABuf, UInt32(DoneLabel));
        end;
        ABuf.BindLabel(FallbackLabel);
        ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));
        Arm64EmitLoadImm32(ABuf, 1, UInt32(AIns.Imm));
        ABuf.EmitU32(Arm64AddImmX(2, ARM64_REG_SP, 0));
        Arm64EmitAddImmXAny(ABuf, 3, ARM64_REG_SP, ArgBytes);
        Arm64EmitCallHelper(ABuf, aohCall);
        ABuf.BindLabel(DoneLabel);
      end;
    iroCallIndirect:
      begin
        Arm64EmitLoadImm64(ABuf, 1, UInt64(AIns.Imm));
        { The table-index operand rides in Dest (ifkSrcReg); pass the whole
          slot and let the helper narrow it by the table's address type. }
        LdX(ABuf, 2, AIns.Dest);
        ABuf.EmitU32(Arm64AddImmX(3, ARM64_REG_SP, 0));
        Arm64EmitAddImmXAny(ABuf, 4, ARM64_REG_SP, ArgBytes);
        Arm64EmitCallHelper(ABuf, aohCallIndirect);
      end;
  else
    { iroCallRef: the funcref operand rides in Dest. }
    LdX(ABuf, 1, AIns.Dest);
    ABuf.EmitU32(Arm64AddImmX(2, ARM64_REG_SP, 0));
    Arm64EmitAddImmXAny(ABuf, 3, ARM64_REG_SP, ArgBytes);
    Arm64EmitCallHelper(ABuf, aohCallRef);
  end;

  EmitUnmarshalResults(ABuf, AAux, AIns.B, ResN, ArgBytes);
  Arm64EmitAddImmXAny(ABuf, ARM64_REG_SP, ARM64_REG_SP, FrameBytes);
  if UseNativeLeaf then
    ABuf.BindLabel(NativeDone);
end;

{ iroReturnCall / iroReturnCallIndirect / iroReturnCallRef. Same marshal, but
  the helper only RECORDS the resolved target and its arguments; the body then
  releases its scratch and runs the epilogue, returning to the trampoline loop
  which does the frame replacement and re-dispatch. That is what makes the
  tail call cost no native stack (§4.5, §13 item 5). There is no result
  unmarshal: the callee's results become this frame's results. }
procedure EmitReturnCall(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32);
var
  ArgN, FrameBytes: UInt32;
begin
  ArgN := IrAuxBlockCount(AAux, AIns.A);
  FrameBytes := Arm64CallFrameBytes(ArgN, 0);

  Arm64EmitSubImmXAny(ABuf, ARM64_REG_SP, ARM64_REG_SP, FrameBytes);
  EmitMarshalArgs(ABuf, AAux, AIns.A, ArgN);
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));

  case AIns.Op of
    iroReturnCall:
      begin
        Arm64EmitLoadImm32(ABuf, 1, UInt32(AIns.Imm));
        ABuf.EmitU32(Arm64AddImmX(2, ARM64_REG_SP, 0));
        Arm64EmitLoadImm32(ABuf, 3, ArgN);
        Arm64EmitCallHelper(ABuf, aohReturnCall);
      end;
    iroReturnCallIndirect:
      begin
        Arm64EmitLoadImm64(ABuf, 1, UInt64(AIns.Imm));
        LdX(ABuf, 2, AIns.Dest);
        ABuf.EmitU32(Arm64AddImmX(3, ARM64_REG_SP, 0));
        Arm64EmitLoadImm32(ABuf, 4, ArgN);
        Arm64EmitCallHelper(ABuf, aohReturnCallIndirect);
      end;
  else
    { iroReturnCallRef }
    LdX(ABuf, 1, AIns.Dest);
    ABuf.EmitU32(Arm64AddImmX(2, ARM64_REG_SP, 0));
    Arm64EmitLoadImm32(ABuf, 3, ArgN);
    Arm64EmitCallHelper(ABuf, aohReturnCallRef);
  end;

  Arm64EmitAddImmXAny(ABuf, ARM64_REG_SP, ARM64_REG_SP, FrameBytes);
  Arm64EmitEpilogue(ABuf);
end;

{ --- Waves 4/5 templates: the uniform helper call (jit-spec §7/§8/§9) -----

  Every memory/table/ref/global/GC op is the SAME three-argument helper call:
  the store (pinned x20), the register-file base (pinned x19), and a pointer to
  the IR instruction. `@AIns` is the address of Arm64EmitOp's const-record
  parameter, which — a const record being passed BY REFERENCE — is the live IR
  instruction AFn^.Code[i] (borrowed and outliving the code block, jit-spec
  §3.4), so the dispatcher reads the op's fields exactly as the interpreter
  does. No operand marshaling and no result unmarshal is emitted: the helper
  reads and writes the in-memory register file directly through x19. }
procedure EmitRuntimeOp(const ABuf: TWasmCodeBuffer; const AInsIndex: UInt32);
begin
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));      { x0 := store }
  ABuf.EmitU32(Arm64MovReg(1, ARM64_REG_REGFILE));    { x1 := regbase }
  Arm64EmitIrInsPtr(ABuf, 2, AInsIndex);              { x2 := @Fn^.Code[i] }
  Arm64EmitCallHelper(ABuf, aohRtDispatch);
end;

{ Wave 6 — every v128 op is the SAME uniform three-argument helper call, but to
  JitVecDispatch (jit-spec §10.1): the store (pinned x20), the register-file
  base (pinned x19), and a pointer to the live IR instruction. The dispatcher
  reads and writes the in-memory register file directly through x19, so a v128's
  two adjacent slots need no operand marshaling — the 2-slot handling is
  inherited from the interpreter's own VecAt addressing. }
procedure EmitVecOp(const ABuf: TWasmCodeBuffer; const AInsIndex: UInt32);
begin
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));      { x0 := store }
  ABuf.EmitU32(Arm64MovReg(1, ARM64_REG_REGFILE));    { x1 := regbase }
  Arm64EmitIrInsPtr(ABuf, 2, AInsIndex);              { x2 := @Fn^.Code[i] }
  Arm64EmitCallHelper(ABuf, aohVecDispatch);
end;

{ iroMoveVec and iroV128Const join the native subset because they dominate
  vector-bearing loops' helper traffic: every v128 local.get/set/tee lowers to
  a move and every literal to a const, and each used to pay the full dispatch
  crossing for what is one Q-register copy or two immediate stores. The const
  bits are read from the aux block at COMPILE time and baked as movz/movk
  pairs, so no run-time aux reach is needed. }
function Arm64NativeVecOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroV128Not, iroV128And, iroV128Andnot, iroV128Or, iroV128Xor,
    iroI8x16Add, iroI8x16Sub, iroI16x8Add, iroI16x8Sub,
    iroI32x4Add, iroI32x4Sub, iroI64x2Add, iroI64x2Sub,
    iroI8x16Splat, iroI16x8Splat, iroI32x4Splat, iroI64x2Splat,
    iroI8x16ExtractLaneS, iroI8x16ExtractLaneU,
    iroI16x8ExtractLaneS, iroI16x8ExtractLaneU,
    iroI32x4ExtractLane, iroI64x2ExtractLane,
    iroMoveVec, iroV128Const:
      Result := True;
  else
    Result := False;
  end;
end;

procedure EmitNativeVecBinary(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ABase: UInt32);
begin
  LdQ(ABuf, 0, AIns.A);
  LdQ(ABuf, 1, AIns.B);
  ABuf.EmitU32(ABase or (UInt32(1) shl 16));
  StQ(ABuf, 0, AIns.Dest);
end;

procedure EmitNativeVecLaneBinary(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ASize: Byte; const ASub: Boolean);
begin
  LdQ(ABuf, 0, AIns.A);
  LdQ(ABuf, 1, AIns.B);
  if ASub then
    ABuf.EmitU32(Arm64VecSub(0, 0, 1, ASize))
  else
    ABuf.EmitU32(Arm64VecAdd(0, 0, 1, ASize));
  StQ(ABuf, 0, AIns.Dest);
end;

procedure EmitNativeVecSplat(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ASize: Byte);
begin
  if ASize = 3 then
    LdX(ABuf, ARM64_REG_T0, AIns.A)
  else
    LdW(ABuf, ARM64_REG_T0, AIns.A);
  ABuf.EmitU32(Arm64VecDup(0, ARM64_REG_T0, ASize));
  StQ(ABuf, 0, AIns.Dest);
end;

procedure EmitNativeVecExtract(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ASize: Byte; const ASigned: Boolean);
begin
  LdQ(ABuf, 0, AIns.A);
  ABuf.EmitU32(Arm64VecExtract(ARM64_REG_T0, 0, ASize,
    Byte(UInt32(AIns.Imm)), ASigned));
  StX(ABuf, ARM64_REG_T0, AIns.Dest);
end;

procedure EmitNativeVec(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32);
var
  VTmp: TWasmV128;
begin
  case AIns.Op of
    iroMoveVec:
      begin
        LdQ(ABuf, 0, AIns.A);
        StQ(ABuf, 0, AIns.Dest);
      end;
    iroV128Const:
      begin
        IrAuxReadV128(AAux, UInt32(AIns.Imm), VTmp);
        Arm64EmitLoadImm64(ABuf, ARM64_REG_T0, VTmp.U64[0]);
        StX(ABuf, ARM64_REG_T0, AIns.Dest);
        Arm64EmitLoadImm64(ABuf, ARM64_REG_T1, VTmp.U64[1]);
        StX(ABuf, ARM64_REG_T1, AIns.Dest + 1);
      end;
    iroV128Not:
      begin
        LdQ(ABuf, 0, AIns.A);
        ABuf.EmitU32(Arm64VecMvn(0, 0));
        StQ(ABuf, 0, AIns.Dest);
      end;
    iroV128And: EmitNativeVecBinary(ABuf, AIns, $4E201C00);
    iroV128Andnot: EmitNativeVecBinary(ABuf, AIns, $4E601C00);
    iroV128Or: EmitNativeVecBinary(ABuf, AIns, $4EA01C00);
    iroV128Xor: EmitNativeVecBinary(ABuf, AIns, $6E201C00);
    iroI8x16Add: EmitNativeVecLaneBinary(ABuf, AIns, 0, False);
    iroI8x16Sub: EmitNativeVecLaneBinary(ABuf, AIns, 0, True);
    iroI16x8Add: EmitNativeVecLaneBinary(ABuf, AIns, 1, False);
    iroI16x8Sub: EmitNativeVecLaneBinary(ABuf, AIns, 1, True);
    iroI32x4Add: EmitNativeVecLaneBinary(ABuf, AIns, 2, False);
    iroI32x4Sub: EmitNativeVecLaneBinary(ABuf, AIns, 2, True);
    iroI64x2Add: EmitNativeVecLaneBinary(ABuf, AIns, 3, False);
    iroI64x2Sub: EmitNativeVecLaneBinary(ABuf, AIns, 3, True);
    iroI8x16Splat: EmitNativeVecSplat(ABuf, AIns, 0);
    iroI16x8Splat: EmitNativeVecSplat(ABuf, AIns, 1);
    iroI32x4Splat: EmitNativeVecSplat(ABuf, AIns, 2);
    iroI64x2Splat: EmitNativeVecSplat(ABuf, AIns, 3);
    iroI8x16ExtractLaneS: EmitNativeVecExtract(ABuf, AIns, 0, True);
    iroI8x16ExtractLaneU: EmitNativeVecExtract(ABuf, AIns, 0, False);
    iroI16x8ExtractLaneS: EmitNativeVecExtract(ABuf, AIns, 1, True);
    iroI16x8ExtractLaneU: EmitNativeVecExtract(ABuf, AIns, 1, False);
    iroI32x4ExtractLane: EmitNativeVecExtract(ABuf, AIns, 2, False);
    iroI64x2ExtractLane: EmitNativeVecExtract(ABuf, AIns, 3, False);
  end;
end;

{ br_on_null / br_on_non_null / br_on_cast / br_on_cast_fail. Call the
  predicate helper (w0 = P: RefIsNull for the null forms, the cast match for
  the cast forms), branch to the target label on the op's taken polarity, then
  — on the fall-through (not-taken) edge — thread the refined value into Dest
  when present, exactly as the interpreter's arms do (interp-spec §3.9). }
procedure EmitBranchRef(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AInsIndex: UInt32);
begin
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));      { x0 := store }
  ABuf.EmitU32(Arm64MovReg(1, ARM64_REG_REGFILE));    { x1 := regbase }
  Arm64EmitIrInsPtr(ABuf, 2, AInsIndex);              { x2 := @Fn^.Code[i] }
  Arm64EmitCallHelper(ABuf, aohRefBranchPredicate);   { w0 := P (1/0) }
  case AIns.Op of
    iroBrOnNull, iroBrOnCast:
      { taken when P holds (null / cast succeeds) }
      EmitCbnzTo(ABuf, 0, AIns.B);
  else
    { iroBrOnNonNull / iroBrOnCastFail: taken when P does NOT hold }
    EmitCbzTo(ABuf, 0, AIns.B);
  end;
  { Fall-through = the not-taken edge: refine Dest := A when present. }
  if AIns.Dest <> IR_NO_REG then
  begin
    LdX(ABuf, ARM64_REG_T0, AIns.A);
    StX(ABuf, ARM64_REG_T0, AIns.Dest);
  end;
end;

{ True for a memory/table/reference/global/GC op that JitRtDispatch handles as
  a plain helper call (the non-branch forms). The v128-typed variants
  (iroGlobalGetVec/SetVec, iroStructGetVec/SetVec, iroArrayGetVec/SetVec,
  iroArrayFillVec) are DELIBERATELY absent here — they are Wave 6 and are
  matched by Arm64VecOp instead, dispatched to JitDoVec (which reads/writes the
  16-byte register slots), never to JitRtDispatch. }
function Arm64RuntimeOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    { memory }
    iroI32Load, iroI64Load, iroF32Load, iroF64Load,
    iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
    iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
    iroI64Load32S, iroI64Load32U,
    iroI32Store, iroI64Store, iroF32Store, iroF64Store,
    iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16, iroI64Store32,
    iroMemorySize, iroMemoryGrow, iroMemoryInit, iroMemoryCopy, iroMemoryFill,
    iroDataDrop,
    { table }
    iroTableGet, iroTableSet, iroTableSize, iroTableGrow, iroTableFill,
    iroTableInit, iroTableCopy, iroElemDrop,
    { reference (non-branch) }
    iroRefNull, iroRefIsNull, iroRefFunc, iroRefEq, iroRefAsNonNull,
    iroRefTest, iroRefCast,
    { global }
    iroGlobalGet, iroGlobalSet,
    { GC struct / array / i31 }
    iroStructNew, iroStructNewDefault, iroStructGet, iroStructGetS,
    iroStructGetU, iroStructSet,
    iroArrayNew, iroArrayNewDefault, iroArrayNewFixed, iroArrayNewData,
    iroArrayNewElem, iroArrayGet, iroArrayGetS, iroArrayGetU, iroArraySet,
    iroArrayLen, iroArrayFill, iroArrayCopy, iroArrayInitData, iroArrayInitElem,
    iroAnyConvertExtern, iroExternConvertAny,
    iroRefI31, iroI31GetS, iroI31GetU:
      Result := True;
  else
    Result := False;
  end;
end;

{ True for a v128 op EmitVecOp / JitDoVec handles (jit-spec §10.1). The vector
  ops form one contiguous enum run — every wasm $FD op (iroV128Load..
  iroI32x4RelaxedDotI8x16I7x16AddS) plus the nine IR-only vector ops
  (iroMoveVec..iroArrayFillVec) — so the predicate is a single range test.
  This is what stops declining v128 functions (Wave 6): with it, the ONLY ops
  the backend still declines are the EH ops, which the driver fences off. }
function Arm64VecOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := (Ord(AOp) >= Ord(iroV128Load))
    and (Ord(AOp) <= Ord(iroArrayFillVec));
end;

{ True for a reference-branch op EmitBranchRef handles. }
function Arm64BranchRefOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroBrOnNull, iroBrOnNonNull, iroBrOnCast, iroBrOnCastFail:
      Result := True;
  else
    Result := False;
  end;
end;

function Arm64CallOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroCall, iroCallIndirect, iroCallRef,
    iroReturnCall, iroReturnCallIndirect, iroReturnCallRef:
      Result := True;
  else
    Result := False;
  end;
end;

function Arm64LeafBinaryOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroF32Min, iroF32Max, iroF32Copysign,
    iroF64Min, iroF64Max, iroF64Copysign:
      Result := True;
  else
    Result := False;
  end;
end;

function Arm64LeafUnaryOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroI32Popcnt, iroI64Popcnt,
    iroF32Abs, iroF32Neg, iroF32Ceil, iroF32Floor, iroF32Trunc,
    iroF32Nearest, iroF32Sqrt,
    iroF64Abs, iroF64Neg, iroF64Ceil, iroF64Floor, iroF64Trunc,
    iroF64Nearest, iroF64Sqrt,
    iroI32TruncF32S, iroI32TruncF32U, iroI32TruncF64S, iroI32TruncF64U,
    iroI64TruncF32S, iroI64TruncF32U, iroI64TruncF64S, iroI64TruncF64U,
    iroF32ConvertI64U, iroF64ConvertI64U,
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
    iroI32DivS, iroI32DivU, iroI32RemS, iroI32RemU,
    iroI64DivS, iroI64DivU, iroI64RemS, iroI64RemU,
    iroI32Clz, iroI32Ctz, iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or,
    iroI32Xor, iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
    iroI64Clz, iroI64Ctz, iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or,
    iroI64Xor, iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr,
    iroF32Add, iroF32Sub, iroF32Mul, iroF32Div,
    iroF32Eq, iroF32Ne, iroF32Lt, iroF32Gt, iroF32Le, iroF32Ge,
    iroF64Add, iroF64Sub, iroF64Mul, iroF64Div,
    iroF64Eq, iroF64Ne, iroF64Lt, iroF64Gt, iroF64Le, iroF64Ge,
    iroI32WrapI64, iroI64ExtendI32S, iroI64ExtendI32U,
    iroI32Extend8S, iroI32Extend16S,
    iroI64Extend8S, iroI64Extend16S, iroI64Extend32S,
    iroF32DemoteF64, iroF64PromoteF32,
    iroF32ConvertI32S, iroF32ConvertI32U, iroF32ConvertI64S,
    iroF64ConvertI32S, iroF64ConvertI32U, iroF64ConvertI64S,
    iroI32ReinterpretF32, iroF32ReinterpretI32,
    iroI64ReinterpretF64, iroF64ReinterpretI64:
      Result := True;
  else
    Result := False;
  end;
end;

function Arm64CanEmitOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := Arm64InlineOp(AOp) or Arm64LeafBinaryOp(AOp)
    or Arm64LeafUnaryOp(AOp) or Arm64CallOp(AOp)
    or Arm64RuntimeOp(AOp) or Arm64BranchRefOp(AOp)
    or Arm64VecOp(AOp);
end;

function Arm64CanEmitInstr(const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32): Boolean;
begin
  { Call-site arity is encoded with a multi-instruction SP adjust; no
    instruction shape declines a valid IR function. }
  Result := True;
  if AIns.Op <> AIns.Op then
    Result := Length(AAux) < 0;
end;

function Arm64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AUsePinnedMemory,
  ANativeScalarSelf: Boolean; const ANativeRegisterCount,
  ANativeParamReg, ANativeResultReg: UInt32;
  const ANativeCoreLabel, ANativeExhaustedLabel: TWasmJitLabel): Boolean;
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
    iroReturn:
      if ANativeScalarSelf then
        Arm64EmitRet(ABuf)
      else
        Arm64EmitEpilogue(ABuf);
    iroUnreachable:
      begin
        ABuf.EmitU32(Arm64MovzW(0, UInt16(Ord(wtkUnreachable)), 0));
        Arm64EmitCallHelper(ABuf, aohTrapKind);
      end;

    { --- calls (Wave 3) ------------------------------------------------ }
    iroCall, iroCallIndirect, iroCallRef:
      EmitCall(ABuf, AIns, AAux, AUsePinnedMemory, ANativeScalarSelf,
        ANativeRegisterCount, ANativeParamReg, ANativeResultReg,
        ANativeCoreLabel, ANativeExhaustedLabel);
    iroReturnCall, iroReturnCallIndirect, iroReturnCallRef:
      EmitReturnCall(ABuf, AIns, AAux);

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

    { --- native integer division/remainder --------------------------- }
    iroI32DivS: EmitDivRem(ABuf, AIns, False, True, False);
    iroI32DivU: EmitDivRem(ABuf, AIns, False, False, False);
    iroI32RemS: EmitDivRem(ABuf, AIns, False, True, True);
    iroI32RemU: EmitDivRem(ABuf, AIns, False, False, True);
    iroI64DivS: EmitDivRem(ABuf, AIns, True, True, False);
    iroI64DivU: EmitDivRem(ABuf, AIns, True, False, False);
    iroI64RemS: EmitDivRem(ABuf, AIns, True, True, True);
    iroI64RemU: EmitDivRem(ABuf, AIns, True, False, True);

    { --- native scalar floating point -------------------------------- }
    iroF32Add: EmitFloatBinary(ABuf, AIns, False, @Arm64FaddS);
    iroF32Sub: EmitFloatBinary(ABuf, AIns, False, @Arm64FsubS);
    iroF32Mul: EmitFloatBinary(ABuf, AIns, False, @Arm64FmulS);
    iroF32Div: EmitFloatBinary(ABuf, AIns, False, @Arm64FdivS);
    iroF64Add: EmitFloatBinary(ABuf, AIns, True, @Arm64FaddD);
    iroF64Sub: EmitFloatBinary(ABuf, AIns, True, @Arm64FsubD);
    iroF64Mul: EmitFloatBinary(ABuf, AIns, True, @Arm64FmulD);
    iroF64Div: EmitFloatBinary(ABuf, AIns, True, @Arm64FdivD);
    iroF32Eq: EmitFloatRel(ABuf, AIns, False, ARM64_COND_EQ);
    iroF32Ne: EmitFloatRel(ABuf, AIns, False, ARM64_COND_NE);
    iroF32Lt: EmitFloatRel(ABuf, AIns, False, ARM64_COND_MI);
    iroF32Gt: EmitFloatRel(ABuf, AIns, False, ARM64_COND_GT);
    iroF32Le: EmitFloatRel(ABuf, AIns, False, ARM64_COND_LS);
    iroF32Ge: EmitFloatRel(ABuf, AIns, False, ARM64_COND_GE);
    iroF64Eq: EmitFloatRel(ABuf, AIns, True, ARM64_COND_EQ);
    iroF64Ne: EmitFloatRel(ABuf, AIns, True, ARM64_COND_NE);
    iroF64Lt: EmitFloatRel(ABuf, AIns, True, ARM64_COND_MI);
    iroF64Gt: EmitFloatRel(ABuf, AIns, True, ARM64_COND_GT);
    iroF64Le: EmitFloatRel(ABuf, AIns, True, ARM64_COND_LS);
    iroF64Ge: EmitFloatRel(ABuf, AIns, True, ARM64_COND_GE);

    { --- exact integer and scalar float conversions ------------------ }
    iroI32WrapI64:
      EmitIntegerConversion(ABuf, AIns, 0, False);
    iroI64ExtendI32U:
      EmitIntegerConversion(ABuf, AIns, 0, False);
    iroI64ExtendI32S:
      EmitIntegerConversion(ABuf, AIns,
        Arm64SxtwX(ARM64_REG_T0, ARM64_REG_T0), False);
    iroI32Extend8S:
      EmitIntegerConversion(ABuf, AIns,
        Arm64SxtbW(ARM64_REG_T0, ARM64_REG_T0), False);
    iroI32Extend16S:
      EmitIntegerConversion(ABuf, AIns,
        Arm64SxthW(ARM64_REG_T0, ARM64_REG_T0), False);
    iroI64Extend8S:
      EmitIntegerConversion(ABuf, AIns,
        Arm64SxtbX(ARM64_REG_T0, ARM64_REG_T0), True);
    iroI64Extend16S:
      EmitIntegerConversion(ABuf, AIns,
        Arm64SxthX(ARM64_REG_T0, ARM64_REG_T0), True);
    iroI64Extend32S:
      EmitIntegerConversion(ABuf, AIns,
        Arm64SxtwX(ARM64_REG_T0, ARM64_REG_T0), True);
    iroF32ConvertI32S: EmitIntToFloat(ABuf, AIns, False, False, False);
    iroF32ConvertI32U: EmitIntToFloat(ABuf, AIns, False, False, True);
    iroF32ConvertI64S: EmitIntToFloat(ABuf, AIns, True, False, False);
    iroF64ConvertI32S: EmitIntToFloat(ABuf, AIns, False, True, False);
    iroF64ConvertI32U: EmitIntToFloat(ABuf, AIns, False, True, True);
    iroF64ConvertI64S: EmitIntToFloat(ABuf, AIns, True, True, False);
    iroF32DemoteF64: EmitFloatWidthConversion(ABuf, AIns, True);
    iroF64PromoteF32: EmitFloatWidthConversion(ABuf, AIns, False);
    iroI32ReinterpretF32, iroF32ReinterpretI32:
      EmitIntegerConversion(ABuf, AIns, 0, False);
    iroI64ReinterpretF64, iroF64ReinterpretI64:
      EmitIntegerConversion(ABuf, AIns, 0, True);

  else
    if Arm64NativeVecOp(AIns.Op) then
      EmitNativeVec(ABuf, AIns, AAux)
    else if Arm64LeafBinaryOp(AIns.Op) then
      EmitLeafBinary(ABuf, AIns)
    else if Arm64LeafUnaryOp(AIns.Op) then
      EmitLeafUnary(ABuf, AIns)
    else if Arm64RuntimeOp(AIns.Op) then
      { memory / table / reference / global / GC — the uniform helper call
        (Waves 4-5), reached only after the inlined-op cases above so no op
        with a dedicated template lands here. }
      EmitRuntimeOp(ABuf, AInsIndex)
    else if Arm64BranchRefOp(AIns.Op) then
      EmitBranchRef(ABuf, AIns, AInsIndex)
    else if Arm64VecOp(AIns.Op) then
      { v128 via the Wasm.Interp.Vector leaves — the uniform helper call
        (Wave 6), reached only after every dedicated template above. }
      EmitVecOp(ABuf, AInsIndex)
    else
      Result := False;
  end;
end;

{ ===================================================================== }
{  the per-process helper table (aot-spec §1.2/§4.3)                     }
{ ===================================================================== }

var
  { Filled once, lazily, with THIS process's live helper addresses. Process-
    global because the addresses are the same for every store (the helpers are
    plain unit procedures); a store points its JitHelperTable field at &[0]. }
  GArm64HelperTable: array[TWasmAotHelper] of Pointer;
  GArm64HelperTableFilled: Boolean = False;

function Arm64GetHelperTable: PPointer;
begin
  if not GArm64HelperTableFilled then
  begin
    GArm64HelperTable[aohTrapKind] := @JitTrapKind;
    GArm64HelperTable[aohOpBinary] := @JitOpBinary;
    GArm64HelperTable[aohOpUnary] := @JitOpUnary;
    GArm64HelperTable[aohRtDispatch] := @JitRtDispatch;
    GArm64HelperTable[aohVecDispatch] := @JitVecDispatch;
    GArm64HelperTable[aohRefBranchPredicate] := @JitRefBranchPredicate;
    GArm64HelperTable[aohCall] := @JitCallHelper;
    GArm64HelperTable[aohCallIndirect] := @JitCallIndirectHelper;
    GArm64HelperTable[aohCallRef] := @JitCallRefHelper;
    GArm64HelperTable[aohReturnCall] := @JitReturnCallHelper;
    GArm64HelperTable[aohReturnCallIndirect] := @JitReturnCallIndirectHelper;
    GArm64HelperTable[aohReturnCallRef] := @JitReturnCallRefHelper;
    GArm64HelperTable[aohDirectCallPrepare] := @JitPrepareDirectCall;
    GArm64HelperTable[aohDirectCallFinish] := @JitFinishDirectCall;
    GArm64HelperTable[aohResolveMemory] := @JitResolveMemory;
    GArm64HelperTable[aohDirectCallFinishScalar] :=
      @JitFinishDirectCallScalar;
    GArm64HelperTable[aohDirectCallPrepareScalar] :=
      @JitPrepareDirectCallScalar;
    GArm64HelperTableFilled := True;
  end;
  Result := @GArm64HelperTable[aohTrapKind];
end;

end.
