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
  { --- position-independent pins (aot-spec §1.2/§1.3/§4.3) --------------- }
  ARM64_REG_IRBASE = 23;   { x23 = @Fn^.Code[0], the IR-code base (entry arg x2) }
  ARM64_REG_HELPERTABLE = 24;  { x24 = the per-process helper-table base }
  ARM64_REG_T0 = 9;        { x9/w9 scratch }
  ARM64_REG_T1 = 10;       { x10/w10 scratch }
  ARM64_REG_T2 = 11;       { x11/w11 scratch }
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
    encodable slot index is bounded by the tightest scale (a 32-bit access
    scales the byte offset by 4, so imm12 = slot*8 div 4 = slot*2). Beyond this
    the driver declines the function (JitCanCompile) and it runs interpreted —
    always correct. }
  ARM64_MAX_SLOT = 2047;

  { The per-call-site marshaling cap (jit-spec §4.4). A compiled call reserves
    (args + results) slots of native-stack scratch with a single
    `sub sp,sp,#imm12`, and a pending tail call copies its argument slots into
    a fixed thread-local buffer — so both are bounded. A call site above the
    cap makes JitCanCompile DECLINE the whole function, which then runs
    interpreted (always correct). Comfortably above real function arities. }
  ARM64_MAX_CALL_SLOTS = 256;

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
  computation x21 := x20 + StoreEpoch. With ARn = ARM64_REG_SP this is also
  `mov Xd, sp` (imm 0) and the scratch-slice address `add Xd, sp, #off`, and
  with ARd = ARn = ARM64_REG_SP it grows/shrinks the call scratch. }
function Arm64AddImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
{ SUB Xd,Xn,#imm12 (unsigned immediate, no shift). Used as
  `sub sp, sp, #frame` to reserve the call-marshaling scratch (§4.4). }
function Arm64SubImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;

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
{ Pin the per-process helper-table base in x24 (aot-spec §1.2/§4.3): loads it
  from the store field (x20 + AHelperTableOffset) ONCE, so every subsequent
  helper call is `ldr xT,[x24,#k*8]; blr xT`. Emitted by the driver right after
  the prologue, before the epoch capture; the exec-only encoder tests skip it
  (they emit no helper call), so the store is only dereferenced on the real
  compile path. AHelperTableOffset is WasmJitOffsets.StoreJitHelperTable. }
procedure Arm64EmitPinHelperTable(const ABuf: TWasmCodeBuffer;
  const AHelperTableOffset: NativeUInt);
procedure Arm64EmitEpochCapture(const ABuf: TWasmCodeBuffer;
  const AEpochOffset, ASnapshotOffset: NativeUInt);
procedure Arm64EmitEpilogue(const ABuf: TWasmCodeBuffer);

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
function Arm64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32): Boolean;

{ The INSTRUCTION-level half of the compile predicate (§4.4). Arm64CanEmitOp
  answers "is there a template for this op"; this answers "can this particular
  instruction's template be emitted", which for the call family means "does the
  call site's argument + result marshaling fit ARM64_MAX_CALL_SLOTS". True for
  every non-call op. The driver calls BOTH per instruction; either False
  declines the whole function, which then runs interpreted. }
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
  Wasm.Runtime.Gc,
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
{  Wave 3 — the CALL family (jit-spec §4.4, §4.5, §5)                    }
{ ===================================================================== }

{ THE DESIGN, in one paragraph. A compiled call does NOT re-implement calling.
  The emitted sequence is only marshal -> call helper -> unmarshal: it copies
  the IR's argument registers into a flat slot buffer on the native stack,
  calls one of the cdecl helpers below, and copies the helper's flat result
  buffer back into the IR's destination registers. The FLAT SLOT BUFFER IS THE
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
  { The compiled entry's ABI, mirroring Wasm.Jit.TWasmJitCompiledEntry (kept
    local so this unit stays below the driver). THREE arguments now
    (aot-spec §1.3/§4.3): the register-file base (x0 -> pinned x19), the store
    (x1 -> pinned x20, from which the prologue pins &Epoch, the snapshot, and
    the helper-table base), and the IR-code base @Fn^.Code[0] (x2 -> pinned x23),
    from which every runtime-op template computes @Fn^.Code[i]. The IR base is a
    live per-invocation value, never baked, which is what makes the code
    position-independent. }
  TArm64CompiledEntry = procedure(const ARegBase: PWasmValue;
    const AStore: TWasmStore; const AIrBase: PWasmIrInstr); cdecl;

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
    Entry(Base, AStore, IrBase);
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

{ THE PATTERN, and why it is the whole of these two waves. Every memory,
  table, reference, global and GC op is a HELPER CALL, exactly as jit-spec
  §1.4 prescribes ("if the interpreter dispatches to a store/heap method for
  an op, the JIT emits a call to that same function"). The emitted template is
  UNIFORM and tiny — marshal the store, the register-file base and a pointer
  to the IR instruction into x0/x1/x2, then `blr` a single cdecl dispatcher
  (JitRtDispatch) — and every subtlety lives in Pascal:

    - MEMORY goes through the ONE chokepoint Store.MemAddressAt / MemRangeAt
      (AGENTS.md's named top failure mode). The baseline emits NO raw
      memory-base arithmetic and does NOT rely on guard-page faults; the
      chokepoint runs the explicit full-precision bounds check and traps
      'out of bounds memory access' via the same TrapNow the interpreter uses
      (jit-spec §7.1 form 1).
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
        I := 0;
        while I < N do
        begin
          AStore.Heap.StructSet(Obj, I,
            Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)]);
          Inc(I);
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

    { extern.convert_any / any.convert_extern: identity on the representation
      (KNOWN LIMITATION M7 — matches the interpreter exactly, which is what the
      differential oracle requires). }
    iroAnyConvertExtern, iroExternConvertAny:
      Reg[AIns^.Dest].Bits := Reg[AIns^.A].Bits;
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

function Arm64SubImmX(const ARd, ARn: Byte; const AImm12: UInt32): UInt32;
begin
  Result := $D1000000 or ((AImm12 and $FFF) shl 10) or (UInt32(ARn) shl 5)
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
  ABuf.EmitU32(Arm64StpX19X20PreIndex64);      { stp x19,x20,[sp,#-64]! }
  ABuf.EmitU32(Arm64StpX21X22Off16);           { stp x21,x22,[sp,#16] }
  ABuf.EmitU32(Arm64StpX23X24Off32);           { stp x23,x24,[sp,#32] }
  ABuf.EmitU32(Arm64StrX(ARM64_REG_LR, ARM64_REG_ZR, 48)); { str x30,[sp,#48] }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_REGFILE, 0));  { mov x19,x0 (regbase) }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_STORE, 1));    { mov x20,x1 (store) }
  ABuf.EmitU32(Arm64MovReg(ARM64_REG_IRBASE, 2));   { mov x23,x2 (IR base) }
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

procedure Arm64EmitEpilogue(const ABuf: TWasmCodeBuffer);
begin
  ABuf.EmitU32(Arm64LdrX(ARM64_REG_LR, ARM64_REG_ZR, 48));  { ldr x30,[sp,#48] }
  ABuf.EmitU32(Arm64LdpX23X24Off32);           { ldp x23,x24,[sp,#32] }
  ABuf.EmitU32(Arm64LdpX21X22Off16);           { ldp x21,x22,[sp,#16] }
  ABuf.EmitU32(Arm64LdpX19X20PostIndex64);     { ldp x19,x20,[sp],#64 }
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

{ iroCall / iroCallIndirect / iroCallRef. x0 is always the store (pinned in
  x20); the callee selector differs per form (funcidx immediate / packed
  type+table immediate plus the index operand / the funcref operand), and the
  last two arguments are always the arg and result scratch pointers. }
procedure EmitCall(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32);
var
  ArgN, ResN, ArgBytes, FrameBytes: UInt32;
begin
  ArgN := IrAuxBlockCount(AAux, AIns.A);
  ResN := IrAuxBlockCount(AAux, AIns.B);
  ArgBytes := ArgN * ARM64_SLOT_SIZE;
  FrameBytes := Arm64CallFrameBytes(ArgN, ResN);

  ABuf.EmitU32(Arm64SubImmX(ARM64_REG_SP, ARM64_REG_SP, FrameBytes));
  EmitMarshalArgs(ABuf, AAux, AIns.A, ArgN);
  ABuf.EmitU32(Arm64MovReg(0, ARM64_REG_STORE));

  case AIns.Op of
    iroCall:
      begin
        Arm64EmitLoadImm32(ABuf, 1, UInt32(AIns.Imm));
        ABuf.EmitU32(Arm64AddImmX(2, ARM64_REG_SP, 0));
        ABuf.EmitU32(Arm64AddImmX(3, ARM64_REG_SP, ArgBytes));
        Arm64EmitCallHelper(ABuf, aohCall);
      end;
    iroCallIndirect:
      begin
        Arm64EmitLoadImm64(ABuf, 1, UInt64(AIns.Imm));
        { The table-index operand rides in Dest (ifkSrcReg); pass the whole
          slot and let the helper narrow it by the table's address type. }
        LdX(ABuf, 2, AIns.Dest);
        ABuf.EmitU32(Arm64AddImmX(3, ARM64_REG_SP, 0));
        ABuf.EmitU32(Arm64AddImmX(4, ARM64_REG_SP, ArgBytes));
        Arm64EmitCallHelper(ABuf, aohCallIndirect);
      end;
  else
    { iroCallRef: the funcref operand rides in Dest. }
    LdX(ABuf, 1, AIns.Dest);
    ABuf.EmitU32(Arm64AddImmX(2, ARM64_REG_SP, 0));
    ABuf.EmitU32(Arm64AddImmX(3, ARM64_REG_SP, ArgBytes));
    Arm64EmitCallHelper(ABuf, aohCallRef);
  end;

  EmitUnmarshalResults(ABuf, AAux, AIns.B, ResN, ArgBytes);
  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_SP, ARM64_REG_SP, FrameBytes));
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

  ABuf.EmitU32(Arm64SubImmX(ARM64_REG_SP, ARM64_REG_SP, FrameBytes));
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

  ABuf.EmitU32(Arm64AddImmX(ARM64_REG_SP, ARM64_REG_SP, FrameBytes));
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
    or Arm64LeafUnaryOp(AOp) or Arm64CallOp(AOp)
    or Arm64RuntimeOp(AOp) or Arm64BranchRefOp(AOp)
    or Arm64VecOp(AOp);
end;

function Arm64CanEmitInstr(const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32): Boolean;
begin
  Result := True;
  case AIns.Op of
    iroCall, iroCallIndirect, iroCallRef:
      Result := (IrAuxBlockCount(AAux, AIns.A)
        + IrAuxBlockCount(AAux, AIns.B)) <= ARM64_MAX_CALL_SLOTS;
    { A tail call marshals arguments only — the callee's results are this
      frame's, so there is no result block to size. }
    iroReturnCall, iroReturnCallIndirect, iroReturnCallRef:
      Result := IrAuxBlockCount(AAux, AIns.A) <= ARM64_MAX_CALL_SLOTS;
  end;
end;

function Arm64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32): Boolean;
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
        Arm64EmitCallHelper(ABuf, aohTrapKind);
      end;

    { --- calls (Wave 3) ------------------------------------------------ }
    iroCall, iroCallIndirect, iroCallRef: EmitCall(ABuf, AIns, AAux);
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

  else
    if Arm64LeafBinaryOp(AIns.Op) then
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
    GArm64HelperTableFilled := True;
  end;
  Result := @GArm64HelperTable[aohTrapKind];
end;

end.
