{ Wasm.Jit.X64 — the x86-64 (System V AMD64) instruction encoder and the
  per-IR-op code templates the baseline JIT emits (.agent/design/jit-spec.md
  §12.3 Wave 7). Second backend; mirrors Wasm.Jit.Arm64 op-for-op behind the
  same driver (Wasm.Jit). No new semantics — encoder work only.

  STRATEGY (§1.1, the memory-resident register file), identical to the aarch64
  backend: the IR's virtual registers stay in the interpreter's value stack,
  addressed Reg[k] = Values[Base + k] as 8-byte slots. Each template loads its
  operand slot(s) into scratch machine registers, computes, and stores the
  result to its destination slot. Machine registers are scratch WITHIN one
  template only, so the GC stack map is the frame itself (§9.1).

  SYSTEM V AMD64 ABI (the Linux VM target, §5.3). Integer args:
  rdi, rsi, rdx, rcx, r8, r9; result rax; callee-saved rbx, rbp, r12-r15;
  caller-saved rax, rcx, rdx, rsi, rdi, r8-r11. rsp must be 16-byte aligned at
  the point of a CALL (so rsp is 8 mod 16 on entry, after the return address is
  pushed). The compiled entry is cdecl: 1st arg (register-file base) in rdi,
  2nd arg (store) in rsi.

  PINS (§5.3), mirroring the aarch64 x19-x22 scheme, all callee-saved so they
  survive helper calls:
    rbx = register-file base (@Values[Base]; the entry's 1st arg, rdi)
    r12 = the store pointer   (the entry's 2nd arg, rsi)
    r13 = &Store.Epoch        (r12 + StoreEpoch offset)
    r14 = the epoch captured at entry (Store.EpochSnapshot, §6)
  Scratch is rax/rcx/rdx (caller-saved, dead at op boundaries); the SysV arg
  registers marshal helper arguments. The prologue pushes rbx/r12/r13/r14 and a
  single 8-byte pad (keeping rsp 16-aligned for calls); the epilogue reverses
  it. A trap unwinds through LongJmp to the per-invocation trampoline
  (ADR-0009), which restores the caller's callee-saved set from its setjmp, so a
  skipped epilogue on the trap path is correct.

  HELPER-CALL ABI. Every helper is a cdecl thunk defined in this unit —
  X64OpBinary / X64OpUnary (which switch on the IR op and call the EXACT
  Wasm.Interp.Numeric leaf the interpreter calls, so NaN bits, rounding and the
  div/rem and float->int trap kind + timing are the interpreter's by
  construction, §13) and X64TrapKind (TrapNow). The memory / table / ref /
  global / GC / v128 ops call X64RtDispatch / X64VecDispatch, and the calls go
  through X64DispatchCall / X64InvokeCompiled — all of which reproduce the
  interpreter's Exec* bodies verbatim, calling the identical runtime primitives,
  so identity is structural (the differential harness §11 proves it). These are
  the SAME arch-independent Pascal helpers the aarch64 backend uses; because
  they live in that unit's private implementation and cannot be shared without
  editing it, they are reproduced here (a source-maintenance follow-up would
  lift them to a shared Wasm.Jit.Runtime unit). Both backend units are never
  linked into one program, so the duplicate helper names never collide.

  ENCODINGS. Every x86-64 byte sequence below is asserted from the Intel SDM
  Vol. 2 (opcode maps, ModRM/SIB/REX). Where a byte-level detail is not certain
  it carries UNCONFIRMED per jit-spec §0; a wrong byte is caught mechanically by
  the differential harness (§11) — the compiled op diverges from the interpreter
  on the first input that exercises it, or the code faults — and by the
  co-located byte-level encoder tests (runnable on any host, since the emitters
  compute bytes and never execute).

  CLZ/CTZ ON X86-64. Unlike the aarch64 backend, which inlines clz/ctz via
  CLZ/RBIT, this backend routes i32/i64 clz and ctz through the X64OpUnary leaf
  (calling Wasm.Interp.Numeric's I32Clz/I32Ctz/I64Clz/I64Ctz), because inlining
  would need LZCNT/TZCNT (BMI1/ABM CPUID-gated) or BSR/BSF with special
  zero-input handling. The leaf path is identity-guaranteed and CPUID-free. This
  is a per-backend inline/leaf split only; the SET of compiled ops is identical
  to the aarch64 backend (the compile predicate covers all non-EH ops).

  Depends on Wasm.Jit.CodeBuffer and Wasm.Ir plus Wasm.Interp.Numeric /
  Wasm.Interp.Vector, Wasm.Runtime.Store / Values / Gc / Traps and Wasm.Interp
  (the shared frame helpers). No cycle: none of those knows about the JIT.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
unit Wasm.Jit.X64;

{$I Shared.inc}
{ The call helpers copy flat slot blocks addressed as AArgs[i] — pointer
  arithmetic on PWasmValue, the convention Wasm.Interp uses for the register
  file it hands over. }
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

  { A branch displacement that does not fit its rel32 field. Raised by
    X64ResolvePatches so the driver ABANDONS the compile and leaves the
    function interpreted (AAlways correct). A distinct class so the driver
    swallows ONLY this and lets every other internal error surface loudly
    (jit-spec §4.3). rel32 spans +-2 GiB so this is effectively unreachable for
    a real function, but the guard keeps the shape identical to the aarch64
    backend. }
  EWasmJitBranchRange = class(EWasmError);

  TX64RegCacheEntry = record
    Valid: Boolean;
    Slot: UInt32;
  end;

  TX64RegCache = record
    Entries: array[0..3] of TX64RegCacheEntry;
    Next: Byte;
    StaticAllocation: Boolean;
  end;

const
  { --- x86-64 register numbers (SDM Vol. 2 Table 2-2) --------------------- }
  X64_RAX = 0;
  X64_RCX = 1;
  X64_RDX = 2;
  X64_RBX = 3;
  X64_RSP = 4;
  X64_RBP = 5;
  X64_RSI = 6;
  X64_RDI = 7;
  X64_R8 = 8;
  X64_R9 = 9;
  X64_R10 = 10;
  X64_R11 = 11;
  X64_R12 = 12;
  X64_R13 = 13;
  X64_R14 = 14;
  X64_R15 = 15;

  { --- pins (jit-spec §5.3, aot-spec §1.2/§1.3/§4.3) --------------------- }
  { The x86-64 callee-saved set is rbx, rbp, r12-r15. All six are pinned: the
    four Wave-2 roles below plus the two position-independence pins (the
    helper-table base and the IR-code base). rbp is used as a general pinned
    register, NOT a frame pointer — this JIT addresses locals off rbx and native
    scratch off rsp, and a trap unwinds through setjmp/longjmp (which restores
    rbp), so no frame-pointer chain is needed. Scratch stays rax/rcx/rdx. }
  X64_REG_REGFILE = X64_RBX;    { rbx = @Values[Base] }
  X64_REG_STORE = X64_R12;      { r12 = the store pointer }
  X64_REG_EPOCHADDR = X64_R13;  { r13 = &Store.Epoch }
  X64_REG_EPOCH = X64_R14;      { r14 = the epoch captured at frame entry }
  X64_REG_HELPERTABLE = X64_R15;{ r15 = the per-process helper-table base }
  X64_REG_IRBASE = X64_RBP;     { rbp = @Fn^.Code[0], the IR-code base }
  X64_REG_T0 = X64_RAX;         { rax/eax scratch }
  X64_REG_T1 = X64_RCX;         { rcx/ecx scratch (also CL for variable shifts) }
  X64_REG_T2 = X64_RDX;         { rdx/edx scratch }

  { SysV integer argument registers, in order. }
  X64_ARG0 = X64_RDI;
  X64_ARG1 = X64_RSI;
  X64_ARG2 = X64_RDX;
  X64_ARG3 = X64_RCX;
  X64_ARG4 = X64_R8;
  X64_ARG5 = X64_R9;

  X64_SLOT_SIZE = 8;

  { Slots are addressed [rbx + slot*8] with a disp32, so the frame is bounded
    only by Int32; a comfortable cap keeps disp arithmetic obviously in range.
    Beyond it JitCanCompile declines the function and it runs interpreted. }
  X64_MAX_SLOT = 1 shl 20;

  { The per-call-site marshaling cap (jit-spec §4.4), mirroring the aarch64
    backend. Above it JitCanCompile DECLINES the whole function. }
  X64_MAX_CALL_SLOTS = 256;

  { Condition-code nibbles (SDM Vol. 2 Appendix B, Jcc/SETcc). opcode is
    0F 80+cc (Jcc rel32) / 0F 90+cc (SETcc r/m8). }
  X64_CC_E = $4;    { ZF=1        (== / signed & unsigned) }
  X64_CC_NE = $5;   { ZF=0 }
  X64_CC_B = $2;    { CF=1        (unsigned <) }
  X64_CC_AE = $3;   { CF=0        (unsigned >=) }
  X64_CC_BE = $6;   { unsigned <= }
  X64_CC_A = $7;    { unsigned >  }
  X64_CC_P = $A;    { parity / unordered scalar float }
  X64_CC_L = $C;    { SF<>OF      (signed <) }
  X64_CC_GE = $D;   { signed >= }
  X64_CC_LE = $E;   { signed <= }
  X64_CC_G = $F;    { signed >  }

  { Patch kinds double as the instruction length (jit-spec §4.3 analog): the
    rel32 field is always the last 4 bytes, so the field offset is (len-4) and
    the relative displacement is (target-site) - len. JMP rel32 is 5 bytes,
    Jcc rel32 is 6. }
  X64_PATCH_JMP32 = 5;
  X64_PATCH_JCC32 = 6;

{ --- low-level byte emitters (the encoder; the test asserts their bytes) --- }

{ REX prefix (0x40 | W<<3 | R<<2 | X<<1 | B); emitted only when a bit is set
  (SDM Vol. 2 §2.2.1). }
procedure X64EmitRex(const ABuf: TWasmCodeBuffer; const AW, AR, AX, AB: Byte);
procedure X64EmitRet(const ABuf: TWasmCodeBuffer);

{ mov ADst, ASrc — 64-bit register move (89 /r). }
procedure X64EmitMovRegReg(const ABuf: TWasmCodeBuffer; const ADst, ASrc: Byte);
{ mov reg32, imm32 (B8+rd id) — zero-extends into the 64-bit register. }
procedure X64EmitMovRegImm32(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const AImm: UInt32);
{ movabs reg64, imm64 (REX.W B8+rd io). }
procedure X64EmitMovRegImm64(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const AImm: UInt64);

{ mov reg, [ABase + ADisp] and mov [ABase + ADisp], reg, 64- and 32-bit. The
  32-bit load zero-extends into the 64-bit register (the i32 widening store,
  §13 item 7). }
procedure X64EmitLoadMem64(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);
procedure X64EmitLoadMem32(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);
procedure X64EmitStoreMem64(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);
{ lea AReg, [ABase + ADisp] (8D /r). }
procedure X64EmitLea(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);

{ Frame-relative slot access off the pinned rbx base. }
procedure X64EmitLoadSlot64(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const ASlot: UInt32);
procedure X64EmitLoadSlot32(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const ASlot: UInt32);
procedure X64EmitStoreSlot64(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const ASlot: UInt32);

{ ALU register-register: <op> ADst, ASrc. AOpcode is the r/m,r opcode byte
  (ADD=01, OR=09, AND=21, SUB=29, XOR=31, CMP=39, TEST=85). AWide selects the
  REX.W 64-bit form. }
procedure X64EmitAluRegReg(const ABuf: TWasmCodeBuffer; const AOpcode: Byte;
  const AWide: Boolean; const ADst, ASrc: Byte);
{ imul ADst, ASrc (0F AF /r); ADst is the destination (reg field). }
procedure X64EmitImul(const ABuf: TWasmCodeBuffer; const AWide: Boolean;
  const ADst, ASrc: Byte);
{ Variable shift/rotate by CL: <op> AReg, cl (D3 /subop). subop: ROL=0, ROR=1,
  SHL=4, SHR=5, SAR=7. The hardware masks CL modulo the width, exactly wasm's
  `count and (N-1)`. }
procedure X64EmitShiftCl(const ABuf: TWasmCodeBuffer; const ASubop: Byte;
  const AWide: Boolean; const AReg: Byte);
{ setcc al (0F 90+cc /0) then movzx eax, al (0F B6 /r): eax := (cc) ? 1 : 0,
  zero-extended into rax. }
procedure X64EmitSetccAl(const ABuf: TWasmCodeBuffer; const ACc: Byte);
procedure X64EmitMovzxEaxAl(const ABuf: TWasmCodeBuffer);
{ cmovcc ADst, ASrc (0F 40+cc /r). }
procedure X64EmitCmovcc(const ABuf: TWasmCodeBuffer; const ACc: Byte;
  const AWide: Boolean; const ADst, ASrc: Byte);

{ Native scalar numeric encodings. Integer operands use general registers;
  scalar FP operands use XMM register numbers in the same 0..15 range. }
procedure X64EmitSignDividend(const ABuf: TWasmCodeBuffer;
  const AWide: Boolean);
procedure X64EmitDivReg(const ABuf: TWasmCodeBuffer;
  const ASigned, AWide: Boolean; const AReg: Byte);
procedure X64EmitMovToXmm(const ABuf: TWasmCodeBuffer; const AXmm,
  AReg: Byte; const AWide: Boolean);
procedure X64EmitMovFromXmm(const ABuf: TWasmCodeBuffer; const AReg,
  AXmm: Byte; const AWide: Boolean);
procedure X64EmitScalarFloatBinary(const ABuf: TWasmCodeBuffer;
  const AOpcode: Byte; const AWide: Boolean; const ADestXmm, ASrcXmm: Byte);
procedure X64EmitScalarFloatCompare(const ABuf: TWasmCodeBuffer;
  const APredicate: Byte; const AWide: Boolean;
  const ADestXmm, ASrcXmm: Byte);
procedure X64EmitScalarFloatUcomi(const ABuf: TWasmCodeBuffer;
  const AWide: Boolean; const ALeftXmm, ARightXmm: Byte);
procedure X64EmitIntToFloat(const ABuf: TWasmCodeBuffer;
  const ASourceWide, AResultWide: Boolean; const ADestXmm, ASrcReg: Byte);
procedure X64EmitFloatWidthConvert(const ABuf: TWasmCodeBuffer;
  const ADemote: Boolean; const ADestXmm, ASrcXmm: Byte);
procedure X64EmitSignExtendRax(const ABuf: TWasmCodeBuffer;
  const ASourceBits: Byte; const ATargetWide: Boolean);

procedure X64EmitPushReg(const ABuf: TWasmCodeBuffer; const AReg: Byte);
procedure X64EmitPopReg(const ABuf: TWasmCodeBuffer; const AReg: Byte);
{ add/sub rsp, imm (48 83 /0|/5 ib, or 48 81 /0|/5 id). }
procedure X64EmitAddRsp(const ABuf: TWasmCodeBuffer; const AImm: Int32);
procedure X64EmitSubRsp(const ABuf: TWasmCodeBuffer; const AImm: Int32);
{ call reg (FF /2). }
procedure X64EmitCallReg(const ABuf: TWasmCodeBuffer; const AReg: Byte);

{ jmp rel32 / jcc rel32 placeholders (rel32 = 0), recording a patch against the
  target label (= the target IR-instruction index; the driver binds one label
  per instruction, in order). }
procedure X64EmitJmpTo(const ABuf: TWasmCodeBuffer; const ATarget: UInt32);
procedure X64EmitJccTo(const ABuf: TWasmCodeBuffer; const ACc: Byte;
  const ATarget: UInt32);

{ --- the Wave-2 frame (jit-spec §5.2/§5.3/§6) --------------------------- }
procedure X64EmitPrologue(const ABuf: TWasmCodeBuffer);
{ Pin the per-process helper-table base in r15 (aot-spec §1.2/§4.3): loads it
  from the store field (r12 + AHelperTableOffset) ONCE. Emitted by the driver
  right after the prologue; the exec-only encoder tests skip it. }
procedure X64EmitPinHelperTable(const ABuf: TWasmCodeBuffer;
  const AHelperTableOffset: NativeUInt);
procedure X64EmitEpochCapture(const ABuf: TWasmCodeBuffer;
  const AEpochOffset, ASnapshotOffset: NativeUInt);
procedure X64EmitEpilogue(const ABuf: TWasmCodeBuffer);

{ Emit an indirect call to helper slot AHelper through the pinned helper table:
  `call qword [r15 + Ord(AHelper)*8]` (aot-spec §1.2) — position-independent. }
procedure X64EmitCallHelper(const ABuf: TWasmCodeBuffer;
  const AHelper: TWasmAotHelper);

{ Compute @Fn^.Code[AInsIndex] into ADestReg from the pinned IR base rbp
  (aot-spec §1.3): `lea rDest, [rbp + i*stride]`. No baked IR pointer. }
procedure X64EmitIrInsPtr(const ABuf: TWasmCodeBuffer; const ADestReg: Byte;
  const AInsIndex: UInt32);

{ The per-process helper table for this backend (aot-spec §4.3): an
  array[TWasmAotHelper] of live helper addresses, returned by base pointer for
  RegisterJit to store in Store.JitHelperTable. }
function X64GetHelperTable: PPointer;

{ Resolve every branch placeholder on ABuf's patch list into its final rel32.
  Call once, after the whole function is emitted and every label bound, while
  the buffer is still writable (§4.3). }
procedure X64ResolvePatches(const ABuf: TWasmCodeBuffer);

{ --- the per-op template layer (the driver walks the IR and calls this) --- }
function X64CanEmitOp(const AOp: TWasmIrOp): Boolean;
{ AInsIndex is the instruction's IR index (aot-spec §1.3): the runtime-op
  templates compute @Fn^.Code[i] from the pinned IR base rbp plus
  AInsIndex*SizeOf(TWasmIrInstr), so nothing is baked. }
function X64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32): Boolean;
procedure X64InitRegCache(out ACache: TX64RegCache);
procedure X64EnableStaticRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TX64RegCache; const ASlots: array of UInt32);
procedure X64FlushRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TX64RegCache);
procedure X64InvalidateRegCache(var ACache: TX64RegCache);
function X64EmitOpCached(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AAddr64: Boolean;
  var ACache: TX64RegCache): Boolean;
procedure X64EmitCompareBranchCached(const ABuf: TWasmCodeBuffer;
  const ACompare, ABranch: TWasmIrInstr; var ACache: TX64RegCache);
function X64CanEmitInstr(const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32): Boolean;

{ The compiled-entry invocation trampoline (jit-spec §4.5, §5.2), identical in
  logic to the aarch64 backend's: builds the callee's frame through the SHARED
  Wasm.Interp helpers, runs the machine code, marshals results out; on a pending
  `return_call*` it LOOPS, popping the frame and re-dispatching in this Pascal
  loop rather than by a native call, so a chain of N tail calls costs N
  iterations and ZERO native-stack growth (§13 item 5). }
procedure X64InvokeCompiled(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue);

{ The byte offset of register/slot k from the register-file base. }
function X64SlotByteOffset(const AReg: UInt32): UInt32;

implementation

uses
  Wasm.Interp,
  Wasm.Interp.Numeric,
  Wasm.Interp.Vector,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Traps;

procedure X64EmitScalarMemory(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAddr64: Boolean); forward;

procedure X64CachedLoad(const ABuf: TWasmCodeBuffer; var ACache: TX64RegCache;
  const ADest: Byte; const ASlot: UInt32); forward;
procedure X64CachedStore(const ABuf: TWasmCodeBuffer; var ACache: TX64RegCache;
  const ASrc: Byte; const ASlot: UInt32); forward;
procedure X64CachedAlu(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AOpcode: Byte; const AWide, AMul: Boolean;
  var ACache: TX64RegCache); forward;
procedure X64CachedRel(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ACc: Byte; const AWide: Boolean;
  var ACache: TX64RegCache); forward;

{ ===================================================================== }
{  cdecl helper thunks — the ABI boundary the emitted code calls (§1.4)  }
{ ===================================================================== }

{ Delicate numeric ops (min/max/nearest, trapping and saturating float-to-int,
  unsigned i64-to-float, clz/ctz/popcnt) route through these thunks,
  and call the EXACT Wasm.Interp.Numeric leaf the interpreter calls — so the
  remaining NaN/rounding behaviour and float-to-int trap kind + timing are
  identical by construction (§13). A 32-bit result is returned zero-extended, a
  64-bit result verbatim, exactly as the interpreter stores it. }
function X64OpBinary(const AOp: PtrUInt; const A, B: UInt64): UInt64; cdecl;
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

function X64ScalarMemoryOp(const AOp: TWasmIrOp): Boolean;
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

function X64MemoryAccessSize(const AOp: TWasmIrOp): UInt32;
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

function X64EmitOpCached(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32; const AAddr64: Boolean;
  var ACache: TX64RegCache): Boolean;
begin
  Result := True;
  if X64ScalarMemoryOp(AIns.Op) then
  begin
    X64InvalidateRegCache(ACache);
    X64EmitScalarMemory(ABuf, AIns, AAddr64);
    Exit;
  end;
  case AIns.Op of
    iroMove:
      begin
        X64CachedLoad(ABuf, ACache, X64_RAX, AIns.A);
        X64CachedStore(ABuf, ACache, X64_RAX, AIns.Dest);
      end;
    iroI32Const, iroF32Const:
      begin
        X64EmitMovRegImm32(ABuf, X64_RAX, UInt32(AIns.Imm and $FFFFFFFF));
        X64CachedStore(ABuf, ACache, X64_RAX, AIns.Dest);
      end;
    iroI64Const, iroF64Const:
      begin
        X64EmitMovRegImm64(ABuf, X64_RAX, UInt64(AIns.Imm));
        X64CachedStore(ABuf, ACache, X64_RAX, AIns.Dest);
      end;
    iroBranchIf, iroBranchIfNot:
      begin
        X64CachedLoad(ABuf, ACache, X64_RAX, AIns.A);
        X64EmitAluRegReg(ABuf, $85, False, X64_RAX, X64_RAX);
        if AIns.Op = iroBranchIf then
          X64EmitJccTo(ABuf, X64_CC_NE, AIns.B)
        else
          X64EmitJccTo(ABuf, X64_CC_E, AIns.B);
        X64InvalidateRegCache(ACache);
      end;
    iroJump:
      begin
        { Safepoint back-edges expose the logical frame to the runtime. Flush
          dirty allocated values but retain their fixed register mapping. }
        if (AIns.Imm and IR_JUMP_SAFEPOINT) <> 0 then
          X64FlushRegCache(ABuf, ACache);
        Result := X64EmitOp(ABuf, AIns, AAux, AInsIndex);
      end;
    iroReturn, iroUnreachable:
      begin
        X64FlushRegCache(ABuf, ACache);
        Result := X64EmitOp(ABuf, AIns, AAux, AInsIndex);
      end;
    iroI32Eqz, iroI64Eqz:
      begin
        X64CachedLoad(ABuf, ACache, X64_RAX, AIns.A);
        X64EmitAluRegReg(ABuf, $85, AIns.Op = iroI64Eqz, X64_RAX, X64_RAX);
        X64EmitSetccAl(ABuf, X64_CC_E);
        X64EmitMovzxEaxAl(ABuf);
        X64CachedStore(ABuf, ACache, X64_RAX, AIns.Dest);
      end;
    iroI32Eq: X64CachedRel(ABuf, AIns, X64_CC_E, False, ACache);
    iroI32Ne: X64CachedRel(ABuf, AIns, X64_CC_NE, False, ACache);
    iroI32LtS: X64CachedRel(ABuf, AIns, X64_CC_L, False, ACache);
    iroI32LtU: X64CachedRel(ABuf, AIns, X64_CC_B, False, ACache);
    iroI32GtS: X64CachedRel(ABuf, AIns, X64_CC_G, False, ACache);
    iroI32GtU: X64CachedRel(ABuf, AIns, X64_CC_A, False, ACache);
    iroI32LeS: X64CachedRel(ABuf, AIns, X64_CC_LE, False, ACache);
    iroI32LeU: X64CachedRel(ABuf, AIns, X64_CC_BE, False, ACache);
    iroI32GeS: X64CachedRel(ABuf, AIns, X64_CC_GE, False, ACache);
    iroI32GeU: X64CachedRel(ABuf, AIns, X64_CC_AE, False, ACache);
    iroI64Eq: X64CachedRel(ABuf, AIns, X64_CC_E, True, ACache);
    iroI64Ne: X64CachedRel(ABuf, AIns, X64_CC_NE, True, ACache);
    iroI64LtS: X64CachedRel(ABuf, AIns, X64_CC_L, True, ACache);
    iroI64LtU: X64CachedRel(ABuf, AIns, X64_CC_B, True, ACache);
    iroI64GtS: X64CachedRel(ABuf, AIns, X64_CC_G, True, ACache);
    iroI64GtU: X64CachedRel(ABuf, AIns, X64_CC_A, True, ACache);
    iroI64LeS: X64CachedRel(ABuf, AIns, X64_CC_LE, True, ACache);
    iroI64LeU: X64CachedRel(ABuf, AIns, X64_CC_BE, True, ACache);
    iroI64GeS: X64CachedRel(ABuf, AIns, X64_CC_GE, True, ACache);
    iroI64GeU: X64CachedRel(ABuf, AIns, X64_CC_AE, True, ACache);
    iroI32Add: X64CachedAlu(ABuf, AIns, $01, False, False, ACache);
    iroI32Sub: X64CachedAlu(ABuf, AIns, $29, False, False, ACache);
    iroI32Mul: X64CachedAlu(ABuf, AIns, 0, False, True, ACache);
    iroI32And: X64CachedAlu(ABuf, AIns, $21, False, False, ACache);
    iroI32Or: X64CachedAlu(ABuf, AIns, $09, False, False, ACache);
    iroI32Xor: X64CachedAlu(ABuf, AIns, $31, False, False, ACache);
    iroI64Add: X64CachedAlu(ABuf, AIns, $01, True, False, ACache);
    iroI64Sub: X64CachedAlu(ABuf, AIns, $29, True, False, ACache);
    iroI64Mul: X64CachedAlu(ABuf, AIns, 0, True, True, ACache);
    iroI64And: X64CachedAlu(ABuf, AIns, $21, True, False, ACache);
    iroI64Or: X64CachedAlu(ABuf, AIns, $09, True, False, ACache);
    iroI64Xor: X64CachedAlu(ABuf, AIns, $31, True, False, ACache);
  else
    X64InvalidateRegCache(ACache);
    Result := X64EmitOp(ABuf, AIns, AAux, AInsIndex);
  end;
end;

function X64CacheHostReg(const AIndex: Integer): Byte;
begin
  case AIndex of
    0: Result := X64_R8;
    1: Result := X64_R9;
    2: Result := X64_R10;
  else
    Result := X64_R11;
  end;
end;

procedure X64InitRegCache(out ACache: TX64RegCache);
begin
  FillChar(ACache, SizeOf(ACache), 0);
end;

procedure X64EnableStaticRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TX64RegCache; const ASlots: array of UInt32);
var
  I: Integer;
begin
  X64InitRegCache(ACache);
  ACache.StaticAllocation := True;
  for I := 0 to 1 do
    if I <= High(ASlots) then
    begin
      ACache.Entries[I].Valid := True;
      ACache.Entries[I].Slot := ASlots[I];
      X64EmitLoadSlot64(ABuf, X64CacheHostReg(I), ASlots[I]);
    end;
end;

procedure X64FlushRegCache(const ABuf: TWasmCodeBuffer;
  var ACache: TX64RegCache);
var
  I: Integer;
begin
  if not ACache.StaticAllocation then
    Exit;
  for I := 0 to 1 do
    if ACache.Entries[I].Valid then
      X64EmitStoreSlot64(ABuf, X64CacheHostReg(I), ACache.Entries[I].Slot);
end;

procedure X64InvalidateRegCache(var ACache: TX64RegCache);
begin
  if ACache.StaticAllocation then
  begin
    ACache.Entries[2].Valid := False;
    ACache.Entries[3].Valid := False;
    ACache.Next := 0;
    Exit;
  end;
  ACache.Entries[0].Valid := False;
  ACache.Entries[1].Valid := False;
  ACache.Next := 0;
end;

procedure X64CachedLoad(const ABuf: TWasmCodeBuffer; var ACache: TX64RegCache;
  const ADest: Byte; const ASlot: UInt32);
var
  I, Victim: Integer;
  Host: Byte;
begin
  for I := 0 to High(ACache.Entries) do
    if ACache.Entries[I].Valid and (ACache.Entries[I].Slot = ASlot) then
    begin
      Host := X64CacheHostReg(I);
      if ADest <> Host then
        X64EmitMovRegReg(ABuf, ADest, Host);
      Exit;
    end;
  if ACache.StaticAllocation then
  begin
    Victim := 2 + ACache.Next;
    ACache.Next := Byte(1 - ACache.Next);
  end
  else
  begin
    Victim := ACache.Next;
    ACache.Next := Byte(1 - ACache.Next);
  end;
  Host := X64CacheHostReg(Victim);
  X64EmitLoadSlot64(ABuf, Host, ASlot);
  ACache.Entries[Victim].Valid := True;
  ACache.Entries[Victim].Slot := ASlot;
  if ADest <> Host then
    X64EmitMovRegReg(ABuf, ADest, Host);
end;

procedure X64CachedStore(const ABuf: TWasmCodeBuffer; var ACache: TX64RegCache;
  const ASrc: Byte; const ASlot: UInt32);
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
    if (Victim >= 0) and (Victim <= 1) then
    begin
      Host := X64CacheHostReg(Victim);
      if ASrc <> Host then
        X64EmitMovRegReg(ABuf, Host, ASrc);
      Exit;
    end;
    X64EmitStoreSlot64(ABuf, ASrc, ASlot);
    if Victim < 2 then
    begin
      Victim := 2 + ACache.Next;
      ACache.Next := Byte(1 - ACache.Next);
    end;
    Host := X64CacheHostReg(Victim);
    if ASrc <> Host then
      X64EmitMovRegReg(ABuf, Host, ASrc);
    ACache.Entries[Victim].Valid := True;
    ACache.Entries[Victim].Slot := ASlot;
    Exit;
  end;
  X64EmitStoreSlot64(ABuf, ASrc, ASlot);
  if Victim < 0 then
  begin
    Victim := ACache.Next;
    ACache.Next := Byte(1 - Victim);
  end;
  Host := X64CacheHostReg(Victim);
  if ASrc <> Host then
    X64EmitMovRegReg(ABuf, Host, ASrc);
  ACache.Entries[Victim].Valid := True;
  ACache.Entries[Victim].Slot := ASlot;
end;

procedure X64CachedAlu(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AOpcode: Byte; const AWide, AMul: Boolean;
  var ACache: TX64RegCache);
begin
  X64CachedLoad(ABuf, ACache, X64_RAX, AIns.A);
  X64CachedLoad(ABuf, ACache, X64_RCX, AIns.B);
  if AMul then
    X64EmitImul(ABuf, AWide, X64_RAX, X64_RCX)
  else
    X64EmitAluRegReg(ABuf, AOpcode, AWide, X64_RAX, X64_RCX);
  X64CachedStore(ABuf, ACache, X64_RAX, AIns.Dest);
end;

procedure X64EmitCompareBranchCached(const ABuf: TWasmCodeBuffer;
  const ACompare, ABranch: TWasmIrInstr; var ACache: TX64RegCache);
var
  Cond: Byte;
  Wide: Boolean;
begin
  Wide := False;
  case ACompare.Op of
    iroI32Eq: Cond := X64_CC_E;
    iroI32Ne: Cond := X64_CC_NE;
    iroI32LtS: Cond := X64_CC_L;
    iroI32LtU: Cond := X64_CC_B;
    iroI32GtS: Cond := X64_CC_G;
    iroI32GtU: Cond := X64_CC_A;
    iroI32LeS: Cond := X64_CC_LE;
    iroI32LeU: Cond := X64_CC_BE;
    iroI32GeS: Cond := X64_CC_GE;
    iroI32GeU: Cond := X64_CC_AE;
    iroI64Eq: begin Cond := X64_CC_E; Wide := True; end;
    iroI64Ne: begin Cond := X64_CC_NE; Wide := True; end;
    iroI64LtS: begin Cond := X64_CC_L; Wide := True; end;
    iroI64LtU: begin Cond := X64_CC_B; Wide := True; end;
    iroI64GtS: begin Cond := X64_CC_G; Wide := True; end;
    iroI64GtU: begin Cond := X64_CC_A; Wide := True; end;
    iroI64LeS: begin Cond := X64_CC_LE; Wide := True; end;
    iroI64LeU: begin Cond := X64_CC_BE; Wide := True; end;
    iroI64GeS: begin Cond := X64_CC_GE; Wide := True; end;
  else
    begin Cond := X64_CC_AE; Wide := True; end;
  end;
  if ABranch.Op = iroBranchIfNot then
    Cond := Cond xor 1;
  X64CachedLoad(ABuf, ACache, X64_RAX, ACompare.A);
  X64CachedLoad(ABuf, ACache, X64_RCX, ACompare.B);
  X64EmitAluRegReg(ABuf, $39, Wide, X64_RAX, X64_RCX);
  X64EmitJccTo(ABuf, Cond, ABranch.B);
  X64InvalidateRegCache(ACache);
end;

procedure X64CachedRel(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ACc: Byte; const AWide: Boolean;
  var ACache: TX64RegCache);
begin
  X64CachedLoad(ABuf, ACache, X64_RAX, AIns.A);
  X64CachedLoad(ABuf, ACache, X64_RCX, AIns.B);
  X64EmitAluRegReg(ABuf, $39, AWide, X64_RAX, X64_RCX);
  X64EmitSetccAl(ABuf, ACc);
  X64EmitMovzxEaxAl(ABuf);
  X64CachedStore(ABuf, ACache, X64_RAX, AIns.Dest);
end;

function X64OpUnary(const AOp: PtrUInt; const A: UInt64): UInt64; cdecl;
begin
  case TWasmIrOp(AOp) of
    { clz/ctz go leaf on x86-64 (see the unit header) — the interpreter's exact
      count leaves, so a zero input yields 32/64 identically. }
    iroI32Clz: Result := UInt64(I32Clz(UInt32(A)));
    iroI32Ctz: Result := UInt64(I32Ctz(UInt32(A)));
    iroI64Clz: Result := I64Clz(A);
    iroI64Ctz: Result := I64Ctz(A);

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
procedure X64TrapKind(const AKind: PtrUInt); cdecl;
begin
  TrapNow(TWasmTrapKind(AKind));
end;

{ ===================================================================== }
{  Wave 3 — the CALL family (jit-spec §4.4, §4.5, §5)                    }
{ ===================================================================== }

type
  { The compiled entry's ABI (aot-spec §1.3/§4.3): regbase in rdi, store in rsi,
    IR-code base @Fn^.Code[0] in rdx; cdecl = SysV. The prologue pins them in
    rbx / r12 / rbp, and pins the helper-table base (r15) off the store. }
  TX64CompiledEntry = procedure(const ARegBase: PWasmValue;
    const AStore: TWasmStore; const AIrBase: PWasmIrInstr); cdecl;

{ Fix A: the pending tail channel is the SHARED Wasm.Interp.GTierTail
  (TierTailSlot), written by both a compiled body's return_call* helper and the
  interpreter's cross-tier tail bounce, read by the loop below — so alternating
  compiled<->interpreted tails re-dispatch through ONE loop with no native-stack
  growth (Finding 1). The old backend-local slot is gone. }

function X64CallerInstance(const AStore: TWasmStore): TWasmModuleInstance;
var
  Ctx: PWasmInterpContext;
begin
  Ctx := InterpContextFor(AStore);
  Result := Ctx^.Acts[Ctx^.Depth - 1].Instance;
end;

function X64ResolveMemory(const AStore: TWasmStore;
  const AMemoryIndex: PtrUInt): PWasmMemoryInst; cdecl;
var
  Instance: TWasmModuleInstance;
begin
  Instance := X64CallerInstance(AStore);
  Result := AStore.JitMemoryAt(Instance.MemAddrs[AMemoryIndex]);
end;

{ Run an INTERPRETED callee as one nested invocation over the shared context.
  TierInvoke carves the callee's frame through the same JitEnterFrame the
  compiled path uses. The epoch snapshot is saved/restored around it (§6): the
  snapshot is per-INVOCATION, and TierInvoke re-seeds it because its normal
  caller is an outermost entry, so a nested wasm->wasm call must put the
  original back. }
procedure X64CallInterpreted(const AStore: TWasmStore;
  const AAddr: TWasmFuncAddr; const AArgs, AResults: PWasmValue);
var
  Saved: UInt64;
begin
  Saved := AStore.EpochSnapshot;
  AStore.TierInvoke(AStore, AAddr, AArgs, AResults);
  AStore.EpochSnapshot := Saved;
end;

{ The ONE tier decision for a wasm->wasm call from compiled code (§4.4), in the
  interpreter's EnterCall order: host first, then a compiled callee through the
  store's hook, else the interpreter. }
procedure X64DispatchCall(const AStore: TWasmStore;
  const AAddr: TWasmFuncAddr; const AArgs, AResults: PWasmValue);
begin
  if AStore.Funcs[AAddr].Kind = wfkHost then
    AStore.Funcs[AAddr].Callback(AStore, AStore.Funcs[AAddr].HostData,
      AArgs, AResults)
  else if Assigned(AStore.JitInvokeCompiled) and
    (AStore.Funcs[AAddr].CompiledEntry <> nil) then
  begin
    { Fix A: a nested compiled seam — its frame is rtCompiledSeam. }
    MarkJitSeamReentry;
    AStore.JitInvokeCompiled(AStore, AAddr, AArgs, AResults);
  end
  else
  begin
    { A NON-tail interpreted callee reached from compiled code is a nested seam;
      its frame is rtCompiledSeam (but not a tail target — it completes). }
    MarkJitSeamReentry;
    X64CallInterpreted(AStore, AAddr, AArgs, AResults);
  end;
end;

{ call_indirect resolution, mirroring Wasm.Interp.ResolveIndirect check order
  (bounds -> null -> type), observable through which message a bad entry
  produces (§13 item 2). Every trap goes through the same TrapNow/TrapNowDetail
  the interpreter uses. }
function X64ResolveIndirect(const AStore: TWasmStore; const APacked: UInt64;
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
  Inst := X64CallerInstance(AStore);
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

function X64ResolveRef(const AStore: TWasmStore;
  const ARefBits: PtrUInt): TWasmFuncAddr;
var
  R: TWasmRef;
begin
  R := TWasmRef(ARefBits);
  if RefIsNull(R) then
    TrapNow(wtkNullFuncReference);
  Result := AStore.FuncRefAddr(R);
end;

procedure X64SetPendingTail(const AAddr: TWasmFuncAddr;
  const AArgs: PWasmValue; const ACount: UInt32);
begin
  { Publish into the SHARED cross-tier channel (Fix A). }
  SetTierPendingTail(AAddr, AArgs, ACount);
end;

{ --- the six cdecl helpers the emitted call sequences call --------------- }

procedure X64CallHelper(const AStore: TWasmStore; const AFuncIdx: PtrUInt;
  const AArgs, AResults: PWasmValue); cdecl;
begin
  X64DispatchCall(AStore,
    X64CallerInstance(AStore).FuncAddrs[UInt32(AFuncIdx)], AArgs, AResults);
end;

procedure X64CallIndirectHelper(const AStore: TWasmStore;
  const APacked: PtrUInt; const AIndexBits: UInt64;
  const AArgs, AResults: PWasmValue); cdecl;
begin
  X64DispatchCall(AStore,
    X64ResolveIndirect(AStore, UInt64(APacked), AIndexBits), AArgs, AResults);
end;

procedure X64CallRefHelper(const AStore: TWasmStore; const ARefBits: PtrUInt;
  const AArgs, AResults: PWasmValue); cdecl;
begin
  X64DispatchCall(AStore, X64ResolveRef(AStore, ARefBits), AArgs, AResults);
end;

procedure X64ReturnCallHelper(const AStore: TWasmStore;
  const AFuncIdx: PtrUInt; const AArgs: PWasmValue;
  const ACount: PtrUInt); cdecl;
begin
  X64SetPendingTail(X64CallerInstance(AStore).FuncAddrs[UInt32(AFuncIdx)],
    AArgs, UInt32(ACount));
end;

procedure X64ReturnCallIndirectHelper(const AStore: TWasmStore;
  const APacked: PtrUInt; const AIndexBits: UInt64; const AArgs: PWasmValue;
  const ACount: PtrUInt); cdecl;
begin
  X64SetPendingTail(X64ResolveIndirect(AStore, UInt64(APacked), AIndexBits),
    AArgs, UInt32(ACount));
end;

procedure X64ReturnCallRefHelper(const AStore: TWasmStore;
  const ARefBits: PtrUInt; const AArgs: PWasmValue;
  const ACount: PtrUInt); cdecl;
begin
  X64SetPendingTail(X64ResolveRef(AStore, ARefBits), AArgs, UInt32(ACount));
end;

procedure X64InvokeCompiled(const AStore: TWasmStore;
  const AFuncAddr: TWasmFuncAddr; const AParams, AResults: PWasmValue);
var
  Ctx: PWasmInterpContext;
  Pend: PWasmTierTail;
  Base: PWasmValue;
  Entry: TX64CompiledEntry;
  CurAddr: TWasmFuncAddr;
  CurArgs: PWasmValue;
  RetKind: TWasmRetKind;
  Seam: TWasmSeamCatch;
  IrFn: PWasmIrFunction;
  IrBase: PWasmIrInstr;
begin
  Ctx := InterpContextFor(AStore);
  { Fix A: one return/unwind kind for the whole chain (see the aarch64 twin). }
  RetKind := ConsumeJitSeamReentry;
  Pend := TierTailSlot;
  CurAddr := AFuncAddr;
  CurArgs := AParams;
  while True do
  begin
    if AStore.Funcs[CurAddr].Kind = wfkHost then
    begin
      AStore.Funcs[CurAddr].Callback(AStore, AStore.Funcs[CurAddr].HostData,
        CurArgs, AResults);
      Exit;
    end;
    { Interpreted tail target: drive it as a bounceable tail target (Fix A). }
    if AStore.Funcs[CurAddr].CompiledEntry = nil then
    begin
      if RetKind = rtCompiledSeam then
        MarkJitSeamReentry;
      MarkTierTailTarget;
      X64CallInterpreted(AStore, CurAddr, CurArgs, AResults);
      if not Pend^.Pending then
        Exit;
      Pend^.Pending := False;
      CurAddr := Pend^.Addr;
      CurArgs := @Pend^.Args[0];
      Continue;
    end;

    Base := JitEnterFrame(Ctx, AStore, CurAddr, CurArgs, AResults, RetKind);
    Pend^.Pending := False;
    Entry := TX64CompiledEntry(AStore.Funcs[CurAddr].CompiledEntry);
    { The freshly-decoded IR base @Fn^.Code[0] the body pins in rbp to compute
      @Fn^.Code[i] (aot-spec §1.3) — a live per-invocation pointer, never baked. }
    IrFn := @AStore.Funcs[CurAddr].Instance.Ir.Functions[
      AStore.Funcs[CurAddr].FuncIrIndex];
    if Length(IrFn^.Code) > 0 then
      IrBase := @IrFn^.Code[0]
    else
      IrBase := nil;
    { Fix A (Finding 3): the compiled body is a native barrier; a wasm exception
      thrown beneath it LongJmps up to this seam catch (a Pascal raise cannot
      cross the native frame). Continue the unwind (pops this frame, hops further
      out, or RaiseUncaughts at a genuine outermost rtEntry). }
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
{  §8, §9). Non-scalar-memory ops use the uniform helper call (store,          }
{  register-file base, IR-instruction pointer); the Pascal below reproduces    }
{  the interpreter's Exec* bodies verbatim, so trap kind/message/order and the }
{  final memory/table/global/GC-heap state are the interpreter's by            }
{  construction (§13). Memory goes through the ONE chokepoint                  }
{  Store.MemAddressAt / MemRangeAt. The GC frame is walkable at every          }
{  allocation because JitEnterFrame pushed Slots = @Values[Base] with          }
{  publish-first preserved (§9.3). }
{ Scalar loads/stores now use the generated-code half of the memory
  chokepoint; grow, bulk and SIMD memory remain in this dispatcher. }
{ ===================================================================== }

function X64TopActivation(const AStore: TWasmStore): PWasmActivation;
var
  Ctx: PWasmInterpContext;
begin
  Ctx := InterpContextFor(AStore);
  Result := @Ctx^.Acts[Ctx^.Depth - 1];
end;

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
          AStore.Heap.WriteBarrier(WASM_REF_NULL, Reg[AIns^.A].Ref);
        AStore.Globals[Addr].Value.Bits := Reg[AIns^.A].Bits;
      end;
  end;
end;

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
        Reg[AIns^.Dest].Bits := UInt64(Obj);
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
        IrUnpack(AIns^.Imm, U1, U2);
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
        Aux := AIns^.A;
        AStore.Heap.ArrayFill(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)]);
      end;
    iroArrayCopy:
      begin
        Aux := AIns^.A;
        AStore.Heap.ArrayCopy(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 4)].U32);
      end;
    iroArrayInitData:
      begin
        Aux := AIns^.A;
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
        Aux := AIns^.A;
        IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
        ElemAddr := Inst.ElemAddrs[ElemIdx];
        AStore.Heap.ArrayInitFromElem(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          AStore.Elems[ElemAddr].Refs,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32);
      end;

    { extern.convert_any / any.convert_extern via the same GC wrapper pair the
      interpreter uses, so ref.test/ref.cast classify correctly (M7); the
      differential oracle requires the JIT match the interpreter. }
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
  template calls: (store, register-file base, IR-instruction pointer). }
procedure X64RtDispatch(const AStore: TWasmStore; const ARegBase: PWasmValue;
  const AIns: PWasmIrInstr); cdecl;
var
  Act: PWasmActivation;
begin
  Act := X64TopActivation(AStore);
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

{ The ref-branch predicate helper (br_on_null/non_null/cast/cast_fail): returns
  the PRIMITIVE predicate P; the emitted code chooses the taken polarity. }
function X64RefBranchPredicate(const AStore: TWasmStore;
  const ARegBase: PWasmValue; const AIns: PWasmIrInstr): PtrUInt; cdecl;
var
  Act: PWasmActivation;
  Reg: PWasmValue;
begin
  Act := X64TopActivation(AStore);
  Reg := ARegBase;
  case AIns^.Op of
    iroBrOnNull, iroBrOnNonNull:
      Result := PtrUInt(Ord(RefIsNull(Reg[AIns^.A].Ref)));
  else
    Result := PtrUInt(Ord(JitMatchesAuxRefType(AStore, Act, Reg[AIns^.A].Ref,
      UInt32(AIns^.Imm))));
  end;
end;

{ ===================================================================== }
{  Wave 6 — v128 SIMD via the Wasm.Interp.Vector leaves (jit-spec §10.1)  }
{  Every v128 op is the SAME uniform three-argument helper call to          }
{  X64VecDispatch -> JitDoVec, which reproduces the interpreter's v128 arms  }
{  VERBATIM, so per-lane NaN discipline, saturating/narrowing arithmetic and }
{  the relaxed R=0 profile are the interpreter's exact bits. A v128 register }
{  occupies two adjacent 8-byte slots; VecAt over the in-memory register file }
{  makes the two-slot layout transparent (no operand marshaling). }
{ ===================================================================== }

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
  Src := VecAt(Reg, AIns^.Dest);
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
    iroV128Load, iroV128Load8x8S, iroV128Load8x8U, iroV128Load16x4S,
    iroV128Load16x4U, iroV128Load32x2S, iroV128Load32x2U, iroV128Load8Splat,
    iroV128Load16Splat, iroV128Load32Splat, iroV128Load64Splat,
    iroV128Load32Zero, iroV128Load64Zero, iroV128Load8Lane, iroV128Load16Lane,
    iroV128Load32Lane, iroV128Load64Lane:
      JitMemLoadV128(AStore, Reg, AAct, AIns);
    iroV128Store, iroV128Store8Lane, iroV128Store16Lane, iroV128Store32Lane,
    iroV128Store64Lane:
      JitMemStoreV128(AStore, Reg, AAct, AIns);

    iroV128Const:
      IrAuxReadV128(Fn^.AuxU32, UInt32(AIns^.Imm), VecAt(Reg, AIns^.Dest)^);
    iroI8x16Shuffle:
      begin
        IrAuxReadV128(Fn^.AuxU32, UInt32(AIns^.Imm), VTmp);
        I8x16Shuffle(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), @VTmp.B[0],
          VecAt(Reg, AIns^.Dest));
      end;
    iroI8x16Swizzle: I8x16Swizzle(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));

    iroI8x16Splat: I8x16Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroI16x8Splat: I16x8Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroI32x4Splat: I32x4Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroI64x2Splat: I64x2Splat(Reg[AIns^.A].U64, VecAt(Reg, AIns^.Dest));
    iroF32x4Splat: F32x4Splat(Reg[AIns^.A].U32, VecAt(Reg, AIns^.Dest));
    iroF64x2Splat: F64x2Splat(Reg[AIns^.A].U64, VecAt(Reg, AIns^.Dest));

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

    iroV128Not: V128Not(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroV128And: V128And(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Andnot: V128Andnot(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Or: V128Or(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Xor: V128Xor(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, AIns^.Dest));
    iroV128Bitselect: V128Bitselect(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.B), VecAt(Reg, UInt32(AIns^.Imm)), VecAt(Reg, AIns^.Dest));
    iroV128AnyTrue: ValueSetU32(Reg[AIns^.Dest], V128AnyTrue(VecAt(Reg, AIns^.A)));

    iroF32x4DemoteF64x2Zero: F32x4DemoteF64x2Zero(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2PromoteLowF32x4: F64x2PromoteLowF32x4(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));

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

    iroI32x4TruncSatF32x4S: I32x4TruncSatF32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4TruncSatF32x4U: I32x4TruncSatF32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4ConvertI32x4S: F32x4ConvertI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF32x4ConvertI32x4U: F32x4ConvertI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4TruncSatF64x2SZero: I32x4TruncSatF64x2SZero(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroI32x4TruncSatF64x2UZero: I32x4TruncSatF64x2UZero(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2ConvertLowI32x4S: F64x2ConvertLowI32x4S(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));
    iroF64x2ConvertLowI32x4U: F64x2ConvertLowI32x4U(VecAt(Reg, AIns^.A), VecAt(Reg, AIns^.Dest));

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

    iroMoveVec:
      VecAt(Reg, AIns^.Dest)^ := VecAt(Reg, AIns^.A)^;
    iroSelectVec:
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

procedure X64VecDispatch(const AStore: TWasmStore; const ARegBase: PWasmValue;
  const AIns: PWasmIrInstr); cdecl;
begin
  JitDoVec(AStore, ARegBase, X64TopActivation(AStore), AIns);
end;

{ ===================================================================== }
{  the x86-64 encoder (SDM Vol. 2)                                       }
{ ===================================================================== }

function X64SlotByteOffset(const AReg: UInt32): UInt32;
begin
  Result := AReg * X64_SLOT_SIZE;
end;

procedure X64EmitRex(const ABuf: TWasmCodeBuffer; const AW, AR, AX, AB: Byte);
var
  V: Byte;
begin
  V := $40 or (AW shl 3) or (AR shl 2) or (AX shl 1) or AB;
  if V <> $40 then
    ABuf.EmitByte(V);
end;

{ ModRM for a register-direct operand (mod=11). }
procedure EmitModRMReg(const ABuf: TWasmCodeBuffer; const ARegField,
  ARmReg: Byte);
begin
  ABuf.EmitByte($C0 or ((ARegField and 7) shl 3) or (ARmReg and 7));
end;

{ ModRM (+SIB, +disp) for a memory operand [ABase + ADisp]. Handles the SIB
  requirement when ABase's low 3 bits are 100 (rsp/r12) and the disp-forcing
  when they are 101 (rbp/r13, which cannot encode a zero disp in mod=00). The
  REX.B that extends the base is emitted by the caller (base shr 3). }
procedure EmitMemOperand(const ABuf: TWasmCodeBuffer; const ARegField,
  ABase: Byte; const ADisp: Int32);
var
  BaseLow, ModB, RmF: Byte;
  NeedSib: Boolean;
begin
  BaseLow := ABase and 7;
  NeedSib := BaseLow = 4;
  if (ADisp = 0) and (BaseLow <> 5) then
    ModB := 0
  else if (ADisp >= -128) and (ADisp <= 127) then
    ModB := 1
  else
    ModB := 2;
  if NeedSib then
    RmF := 4
  else
    RmF := BaseLow;
  ABuf.EmitByte((ModB shl 6) or ((ARegField and 7) shl 3) or RmF);
  if NeedSib then
    { scale=0, index=100 (none), base=BaseLow. }
    ABuf.EmitByte((4 shl 3) or BaseLow);
  if ModB = 1 then
    ABuf.EmitByte(Byte(ADisp))
  else if ModB = 2 then
    ABuf.EmitU32(UInt32(ADisp));
end;

procedure X64EmitRet(const ABuf: TWasmCodeBuffer);
begin
  ABuf.EmitByte($C3);   { RET (SDM: C3). }
end;

procedure X64EmitMovRegReg(const ABuf: TWasmCodeBuffer; const ADst, ASrc: Byte);
begin
  { MOV r/m64, r64 = 89 /r; rm=ADst, reg=ASrc. }
  X64EmitRex(ABuf, 1, ASrc shr 3, 0, ADst shr 3);
  ABuf.EmitByte($89);
  EmitModRMReg(ABuf, ASrc, ADst);
end;

procedure X64EmitMovRegImm32(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const AImm: UInt32);
begin
  { MOV r32, imm32 = B8+rd id; zero-extends into the 64-bit register. }
  X64EmitRex(ABuf, 0, 0, 0, AReg shr 3);
  ABuf.EmitByte($B8 or (AReg and 7));
  ABuf.EmitU32(AImm);
end;

procedure X64EmitMovRegImm64(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const AImm: UInt64);
begin
  { MOV r64, imm64 = REX.W B8+rd io (movabs). }
  X64EmitRex(ABuf, 1, 0, 0, AReg shr 3);
  ABuf.EmitByte($B8 or (AReg and 7));
  ABuf.EmitU64(AImm);
end;

procedure X64EmitLoadMem64(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);
begin
  { MOV r64, r/m64 = 8B /r. }
  X64EmitRex(ABuf, 1, AReg shr 3, 0, ABase shr 3);
  ABuf.EmitByte($8B);
  EmitMemOperand(ABuf, AReg, ABase, ADisp);
end;

procedure X64EmitLoadMem32(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);
begin
  { MOV r32, r/m32 = 8B /r (no REX.W); zero-extends into the 64-bit register. }
  X64EmitRex(ABuf, 0, AReg shr 3, 0, ABase shr 3);
  ABuf.EmitByte($8B);
  EmitMemOperand(ABuf, AReg, ABase, ADisp);
end;

procedure X64EmitStoreMem64(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);
begin
  { MOV r/m64, r64 = 89 /r; reg=AReg (the source), rm=[ABase+ADisp]. }
  X64EmitRex(ABuf, 1, AReg shr 3, 0, ABase shr 3);
  ABuf.EmitByte($89);
  EmitMemOperand(ABuf, AReg, ABase, ADisp);
end;

procedure X64EmitLea(const ABuf: TWasmCodeBuffer; const AReg, ABase: Byte;
  const ADisp: Int32);
begin
  { LEA r64, m = 8D /r. }
  X64EmitRex(ABuf, 1, AReg shr 3, 0, ABase shr 3);
  ABuf.EmitByte($8D);
  EmitMemOperand(ABuf, AReg, ABase, ADisp);
end;

procedure X64EmitLoadScalar(const ABuf: TWasmCodeBuffer;
  const ADest, ABase: Byte; const ASize: UInt32; const ASigned,
  AResult64: Boolean);
begin
  case ASize of
    1, 2:
      begin
        X64EmitRex(ABuf, Ord(ASigned and AResult64), ADest shr 3, 0,
          ABase shr 3);
        ABuf.EmitByte($0F);
        if ASigned then
          ABuf.EmitByte($BE + Ord(ASize = 2))
        else
          ABuf.EmitByte($B6 + Ord(ASize = 2));
        EmitMemOperand(ABuf, ADest, ABase, 0);
      end;
    4:
      if ASigned and AResult64 then
      begin
        X64EmitRex(ABuf, 1, ADest shr 3, 0, ABase shr 3);
        ABuf.EmitByte($63);                    { movsxd r64, r/m32 }
        EmitMemOperand(ABuf, ADest, ABase, 0);
      end
      else
        X64EmitLoadMem32(ABuf, ADest, ABase, 0);
  else
    X64EmitLoadMem64(ABuf, ADest, ABase, 0);
  end;
end;

procedure X64EmitStoreScalar(const ABuf: TWasmCodeBuffer;
  const ASource, ABase: Byte; const ASize: UInt32);
begin
  case ASize of
    1:
      begin
        X64EmitRex(ABuf, 0, ASource shr 3, 0, ABase shr 3);
        ABuf.EmitByte($88);
        EmitMemOperand(ABuf, ASource, ABase, 0);
      end;
    2:
      begin
        ABuf.EmitByte($66);
        X64EmitRex(ABuf, 0, ASource shr 3, 0, ABase shr 3);
        ABuf.EmitByte($89);
        EmitMemOperand(ABuf, ASource, ABase, 0);
      end;
    4:
      begin
        X64EmitRex(ABuf, 0, ASource shr 3, 0, ABase shr 3);
        ABuf.EmitByte($89);
        EmitMemOperand(ABuf, ASource, ABase, 0);
      end;
  else
    X64EmitStoreMem64(ABuf, ASource, ABase, 0);
  end;
end;

procedure X64EmitTrapUnless(const ABuf: TWasmCodeBuffer;
  const AGoodCondition: Byte);
var
  Good: TWasmJitLabel;
begin
  Good := ABuf.NewLabel;
  X64EmitJccTo(ABuf, AGoodCondition, Good);
  X64EmitMovRegImm32(ABuf, X64_ARG0, UInt32(Ord(wtkMemoryOutOfBounds)));
  X64EmitCallHelper(ABuf, aohTrapKind);
  ABuf.BindLabel(Good);
end;

procedure X64EmitScalarMemory(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAddr64: Boolean);
var
  Layout: TWasmMemoryInst;
  AccessSize: UInt32;
  Offset: UInt64;
  Folded: Boolean;
  SignedLoad: Boolean;
begin
  AccessSize := X64MemoryAccessSize(AIns.Op);
  Offset := UInt64(AIns.Imm);
  Folded := Offset <= WASM_STATIC_OFFSET_FOLD - AccessSize;

  X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);
  X64EmitMovRegImm32(ABuf, X64_ARG1, AIns.B);
  X64EmitCallHelper(ABuf, aohResolveMemory);           { rax := memory instance }
  X64EmitLoadMem64(ABuf, X64_R8, X64_RAX,
    Int32(PtrUInt(@Layout.Base) - PtrUInt(@Layout)));
  X64EmitLoadMem64(ABuf, X64_RDX, X64_RAX,
    Int32(PtrUInt(@Layout.ByteSize) - PtrUInt(@Layout)));
  if AAddr64 then
    X64EmitLoadSlot64(ABuf, X64_RCX, AIns.A)
  else
    X64EmitLoadSlot32(ABuf, X64_RCX, AIns.A);

  if AAddr64 and Folded then
  begin
    X64EmitAluRegReg(ABuf, $39, True, X64_RCX, X64_RDX);
    X64EmitTrapUnless(ABuf, X64_CC_BE);
  end
  else if (not AAddr64) and Folded then
    { i32 guard pages need no explicit check for a folded static offset. }
  else
  begin
    X64EmitAluRegReg(ABuf, $39, True, X64_RCX, X64_RDX);
    X64EmitTrapUnless(ABuf, X64_CC_BE);
    X64EmitAluRegReg(ABuf, $29, True, X64_RDX, X64_RCX);
    X64EmitMovRegImm64(ABuf, X64_RAX, Offset);
    X64EmitAluRegReg(ABuf, $39, True, X64_RAX, X64_RDX);
    X64EmitTrapUnless(ABuf, X64_CC_BE);
    X64EmitAluRegReg(ABuf, $29, True, X64_RDX, X64_RAX);
    X64EmitMovRegImm32(ABuf, X64_RAX, AccessSize);
    X64EmitAluRegReg(ABuf, $39, True, X64_RAX, X64_RDX);
    X64EmitTrapUnless(ABuf, X64_CC_BE);
  end;

  X64EmitAluRegReg(ABuf, $01, True, X64_R8, X64_RCX);
  if Offset <= UInt64(High(Int32)) then
    X64EmitLea(ABuf, X64_R8, X64_R8, Int32(Offset))
  else
  begin
    X64EmitMovRegImm64(ABuf, X64_RAX, Offset);
    X64EmitAluRegReg(ABuf, $01, True, X64_R8, X64_RAX);
  end;

  if AIns.Op in [iroI32Store, iroI64Store, iroF32Store, iroF64Store,
    iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
    iroI64Store32] then
  begin
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.Dest);
    X64EmitStoreScalar(ABuf, X64_RAX, X64_R8, AccessSize);
    Exit;
  end;

  SignedLoad := AIns.Op in [iroI32Load8S, iroI32Load16S,
    iroI64Load8S, iroI64Load16S, iroI64Load32S];
  X64EmitLoadScalar(ABuf, X64_RAX, X64_R8, AccessSize, SignedLoad,
    AIns.Op in [iroI64Load8S, iroI64Load16S, iroI64Load32S]);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure X64EmitLoadSlot64(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const ASlot: UInt32);
begin
  X64EmitLoadMem64(ABuf, AReg, X64_REG_REGFILE, Int32(X64SlotByteOffset(ASlot)));
end;

procedure X64EmitLoadSlot32(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const ASlot: UInt32);
begin
  X64EmitLoadMem32(ABuf, AReg, X64_REG_REGFILE, Int32(X64SlotByteOffset(ASlot)));
end;

procedure X64EmitStoreSlot64(const ABuf: TWasmCodeBuffer; const AReg: Byte;
  const ASlot: UInt32);
begin
  X64EmitStoreMem64(ABuf, AReg, X64_REG_REGFILE,
    Int32(X64SlotByteOffset(ASlot)));
end;

procedure X64EmitAluRegReg(const ABuf: TWasmCodeBuffer; const AOpcode: Byte;
  const AWide: Boolean; const ADst, ASrc: Byte);
begin
  { <op> r/m, r = AOpcode /r; rm=ADst, reg=ASrc. }
  X64EmitRex(ABuf, Ord(AWide), ASrc shr 3, 0, ADst shr 3);
  ABuf.EmitByte(AOpcode);
  EmitModRMReg(ABuf, ASrc, ADst);
end;

procedure X64EmitImul(const ABuf: TWasmCodeBuffer; const AWide: Boolean;
  const ADst, ASrc: Byte);
begin
  { IMUL r, r/m = 0F AF /r; reg=ADst, rm=ASrc (commutative, so low bits match). }
  X64EmitRex(ABuf, Ord(AWide), ADst shr 3, 0, ASrc shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte($AF);
  EmitModRMReg(ABuf, ADst, ASrc);
end;

procedure X64EmitSignDividend(const ABuf: TWasmCodeBuffer;
  const AWide: Boolean);
begin
  if AWide then
    ABuf.EmitByte($48);   { CQO = REX.W 99 }
  ABuf.EmitByte($99);     { CDQ / CQO: sign-extend eax/rax into edx/rdx }
end;

procedure X64EmitDivReg(const ABuf: TWasmCodeBuffer;
  const ASigned, AWide: Boolean; const AReg: Byte);
var
  Subop: Byte;
begin
  if ASigned then
    Subop := 7
  else
    Subop := 6;
  X64EmitRex(ABuf, Ord(AWide), 0, 0, AReg shr 3);
  ABuf.EmitByte($F7);
  EmitModRMReg(ABuf, Subop, AReg);   { DIV/IDIV r/m32|64 = F7 /6|/7 }
end;

procedure X64EmitMovToXmm(const ABuf: TWasmCodeBuffer; const AXmm,
  AReg: Byte; const AWide: Boolean);
begin
  ABuf.EmitByte($66);
  X64EmitRex(ABuf, Ord(AWide), AXmm shr 3, 0, AReg shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte($6E);   { MOVD/MOVQ xmm, r32|64 }
  EmitModRMReg(ABuf, AXmm, AReg);
end;

procedure X64EmitMovFromXmm(const ABuf: TWasmCodeBuffer; const AReg,
  AXmm: Byte; const AWide: Boolean);
begin
  ABuf.EmitByte($66);
  X64EmitRex(ABuf, Ord(AWide), AXmm shr 3, 0, AReg shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte($7E);   { MOVD/MOVQ r32|64, xmm }
  EmitModRMReg(ABuf, AXmm, AReg);
end;

procedure X64EmitScalarFloatBinary(const ABuf: TWasmCodeBuffer;
  const AOpcode: Byte; const AWide: Boolean; const ADestXmm, ASrcXmm: Byte);
begin
  if AWide then
    ABuf.EmitByte($F2)
  else
    ABuf.EmitByte($F3);
  X64EmitRex(ABuf, 0, ADestXmm shr 3, 0, ASrcXmm shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte(AOpcode);
  EmitModRMReg(ABuf, ADestXmm, ASrcXmm);
end;

procedure X64EmitScalarFloatCompare(const ABuf: TWasmCodeBuffer;
  const APredicate: Byte; const AWide: Boolean;
  const ADestXmm, ASrcXmm: Byte);
begin
  X64EmitScalarFloatBinary(ABuf, $C2, AWide, ADestXmm, ASrcXmm);
  ABuf.EmitByte(APredicate);
end;

procedure X64EmitScalarFloatUcomi(const ABuf: TWasmCodeBuffer;
  const AWide: Boolean; const ALeftXmm, ARightXmm: Byte);
begin
  if AWide then
    ABuf.EmitByte($66);
  X64EmitRex(ABuf, 0, ALeftXmm shr 3, 0, ARightXmm shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte($2E);   { UCOMISS/UCOMISD xmm, xmm }
  EmitModRMReg(ABuf, ALeftXmm, ARightXmm);
end;

procedure X64EmitIntToFloat(const ABuf: TWasmCodeBuffer;
  const ASourceWide, AResultWide: Boolean; const ADestXmm, ASrcReg: Byte);
begin
  if AResultWide then
    ABuf.EmitByte($F2)
  else
    ABuf.EmitByte($F3);
  X64EmitRex(ABuf, Ord(ASourceWide), ADestXmm shr 3, 0, ASrcReg shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte($2A);   { CVTSI2SS/CVTSI2SD xmm, r32|64 }
  EmitModRMReg(ABuf, ADestXmm, ASrcReg);
end;

procedure X64EmitFloatWidthConvert(const ABuf: TWasmCodeBuffer;
  const ADemote: Boolean; const ADestXmm, ASrcXmm: Byte);
begin
  if ADemote then
    ABuf.EmitByte($F2)   { CVTSD2SS }
  else
    ABuf.EmitByte($F3);  { CVTSS2SD }
  X64EmitRex(ABuf, 0, ADestXmm shr 3, 0, ASrcXmm shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte($5A);
  EmitModRMReg(ABuf, ADestXmm, ASrcXmm);
end;

procedure X64EmitSignExtendRax(const ABuf: TWasmCodeBuffer;
  const ASourceBits: Byte; const ATargetWide: Boolean);
begin
  if ATargetWide then
    ABuf.EmitByte($48);
  if ASourceBits = 32 then
  begin
    { MOVSXD rax,eax = 48 63 C0. A 32-bit target needs no operation. }
    if ATargetWide then
    begin
      ABuf.EmitByte($63);
      ABuf.EmitByte($C0);
    end;
  end
  else
  begin
    ABuf.EmitByte($0F);
    if ASourceBits = 8 then
      ABuf.EmitByte($BE)
    else
      ABuf.EmitByte($BF);
    ABuf.EmitByte($C0);   { MOVSX eax|rax, al|ax }
  end;
end;

procedure X64EmitShiftCl(const ABuf: TWasmCodeBuffer; const ASubop: Byte;
  const AWide: Boolean; const AReg: Byte);
begin
  { <shift> r/m, CL = D3 /subop. CL is masked modulo the width by the hardware
    (SDM: SHL/SHR/SAR/ROL/ROR), exactly wasm's `count and (N-1)`. }
  X64EmitRex(ABuf, Ord(AWide), 0, 0, AReg shr 3);
  ABuf.EmitByte($D3);
  ABuf.EmitByte($C0 or (ASubop shl 3) or (AReg and 7));
end;

procedure X64EmitSetccAl(const ABuf: TWasmCodeBuffer; const ACc: Byte);
begin
  { SETcc r/m8 = 0F (90+cc) /0; rm = al. }
  ABuf.EmitByte($0F);
  ABuf.EmitByte($90 or ACc);
  ABuf.EmitByte($C0);
end;

procedure X64EmitMovzxEaxAl(const ABuf: TWasmCodeBuffer);
begin
  { MOVZX r32, r/m8 = 0F B6 /r; reg=eax, rm=al -> eax := zero_extend(al). }
  ABuf.EmitByte($0F);
  ABuf.EmitByte($B6);
  ABuf.EmitByte($C0);
end;

procedure X64EmitCmovcc(const ABuf: TWasmCodeBuffer; const ACc: Byte;
  const AWide: Boolean; const ADst, ASrc: Byte);
begin
  { CMOVcc r, r/m = 0F (40+cc) /r; reg=ADst, rm=ASrc. }
  X64EmitRex(ABuf, Ord(AWide), ADst shr 3, 0, ASrc shr 3);
  ABuf.EmitByte($0F);
  ABuf.EmitByte($40 or ACc);
  EmitModRMReg(ABuf, ADst, ASrc);
end;

procedure X64EmitPushReg(const ABuf: TWasmCodeBuffer; const AReg: Byte);
begin
  if AReg >= 8 then
    ABuf.EmitByte($41);
  ABuf.EmitByte($50 or (AReg and 7));   { PUSH r64 = 50+rd. }
end;

procedure X64EmitPopReg(const ABuf: TWasmCodeBuffer; const AReg: Byte);
begin
  if AReg >= 8 then
    ABuf.EmitByte($41);
  ABuf.EmitByte($58 or (AReg and 7));   { POP r64 = 58+rd. }
end;

{ ADD/SUB rsp, imm. AIsSub selects /5 (SUB) vs /0 (ADD); imm8 form 83, else 81. }
procedure X64EmitRspAdjust(const ABuf: TWasmCodeBuffer; const AIsSub: Boolean;
  const AImm: Int32);
var
  RmByte: Byte;
begin
  if AIsSub then
    RmByte := $EC          { mod=11, /5, rm=rsp }
  else
    RmByte := $C4;         { mod=11, /0, rm=rsp }
  X64EmitRex(ABuf, 1, 0, 0, 0);   { REX.W = 48 }
  if (AImm >= -128) and (AImm <= 127) then
  begin
    ABuf.EmitByte($83);
    ABuf.EmitByte(RmByte);
    ABuf.EmitByte(Byte(AImm));
  end
  else
  begin
    ABuf.EmitByte($81);
    ABuf.EmitByte(RmByte);
    ABuf.EmitU32(UInt32(AImm));
  end;
end;

procedure X64EmitAddRsp(const ABuf: TWasmCodeBuffer; const AImm: Int32);
begin
  X64EmitRspAdjust(ABuf, False, AImm);
end;

procedure X64EmitSubRsp(const ABuf: TWasmCodeBuffer; const AImm: Int32);
begin
  X64EmitRspAdjust(ABuf, True, AImm);
end;

procedure X64EmitCallReg(const ABuf: TWasmCodeBuffer; const AReg: Byte);
begin
  { CALL r/m64 = FF /2. }
  if AReg >= 8 then
    ABuf.EmitByte($41);
  ABuf.EmitByte($FF);
  ABuf.EmitByte($D0 or (AReg and 7));
end;

procedure X64EmitCallHelper(const ABuf: TWasmCodeBuffer;
  const AHelper: TWasmAotHelper);
begin
  { CALL r/m64 = FF /2, memory form: call qword [r15 + k*8]. r15 needs REX.B; the
    reg field is /2. Position-independent — the code holds only the slot index. }
  X64EmitRex(ABuf, 0, 0, 0, X64_REG_HELPERTABLE shr 3);
  ABuf.EmitByte($FF);
  EmitMemOperand(ABuf, 2, X64_REG_HELPERTABLE, Int32(Ord(AHelper)) * 8);
end;

procedure X64EmitIrInsPtr(const ABuf: TWasmCodeBuffer; const ADestReg: Byte;
  const AInsIndex: UInt32);
begin
  { lea rDest, [rbp + i*stride] — rbp base always encodes an explicit disp
    (EmitMemOperand forces it), so disp 0 (i=0) is not misread as RIP-relative. }
  X64EmitLea(ABuf, ADestReg, X64_REG_IRBASE,
    Int32(AInsIndex * UInt32(SizeOf(TWasmIrInstr))));
end;

procedure X64EmitJmpTo(const ABuf: TWasmCodeBuffer; const ATarget: UInt32);
var
  Site: Integer;
begin
  { JMP rel32 = E9 cd; rel32 back-patched by X64ResolvePatches. }
  Site := ABuf.CurrentOffset;
  ABuf.EmitByte($E9);
  ABuf.EmitU32(0);
  ABuf.AddPatch(Site, TWasmJitLabel(ATarget), X64_PATCH_JMP32);
end;

procedure X64EmitJccTo(const ABuf: TWasmCodeBuffer; const ACc: Byte;
  const ATarget: UInt32);
var
  Site: Integer;
begin
  { Jcc rel32 = 0F (80+cc) cd. }
  Site := ABuf.CurrentOffset;
  ABuf.EmitByte($0F);
  ABuf.EmitByte($80 or ACc);
  ABuf.EmitU32(0);
  ABuf.AddPatch(Site, TWasmJitLabel(ATarget), X64_PATCH_JCC32);
end;

{ ===================================================================== }
{  the Wave-2 frame + branch patching                                    }
{ ===================================================================== }

procedure X64EmitPrologue(const ABuf: TWasmCodeBuffer);
begin
  X64EmitPushReg(ABuf, X64_RBX);
  X64EmitPushReg(ABuf, X64_R12);
  X64EmitPushReg(ABuf, X64_R13);
  X64EmitPushReg(ABuf, X64_R14);
  X64EmitPushReg(ABuf, X64_R15);
  X64EmitPushReg(ABuf, X64_RBP);
  { Six 8-byte pushes leave rsp 8 mod 16 (entry is 8 mod 16); the pad restores
    16-alignment so every CALL below sees an aligned stack (SysV §3.2.2). }
  X64EmitSubRsp(ABuf, 8);
  X64EmitMovRegReg(ABuf, X64_REG_REGFILE, X64_RDI);   { rbx := regbase (arg0) }
  X64EmitMovRegReg(ABuf, X64_REG_STORE, X64_RSI);     { r12 := store (arg1) }
  X64EmitMovRegReg(ABuf, X64_REG_IRBASE, X64_RDX);    { rbp := IR base (arg2) }
end;

procedure X64EmitPinHelperTable(const ABuf: TWasmCodeBuffer;
  const AHelperTableOffset: NativeUInt);
begin
  { r15 := Store.JitHelperTable — the per-process helper-table base, loaded once
    and held callee-saved so every helper call is `call [r15 + k*8]`. }
  X64EmitLoadMem64(ABuf, X64_REG_HELPERTABLE, X64_REG_STORE,
    Int32(AHelperTableOffset));
end;

procedure X64EmitEpochCapture(const ABuf: TWasmCodeBuffer;
  const AEpochOffset, ASnapshotOffset: NativeUInt);
begin
  { r13 := &Store.Epoch (the LIVE epoch word, reloaded at every back-edge). }
  X64EmitLea(ABuf, X64_REG_EPOCHADDR, X64_REG_STORE, Int32(AEpochOffset));
  { r14 := Store.EpochSnapshot — the SHARED per-invocation snapshot the
    outermost guest-entry seeded (§6), held callee-saved for the whole
    function so a nested call re-seeding the shared slot cannot disturb it. }
  X64EmitLoadMem64(ABuf, X64_REG_EPOCH, X64_REG_STORE, Int32(ASnapshotOffset));
end;

procedure X64EmitEpilogue(const ABuf: TWasmCodeBuffer);
begin
  X64EmitAddRsp(ABuf, 8);            { undo the alignment pad }
  X64EmitPopReg(ABuf, X64_RBP);
  X64EmitPopReg(ABuf, X64_R15);
  X64EmitPopReg(ABuf, X64_R14);
  X64EmitPopReg(ABuf, X64_R13);
  X64EmitPopReg(ABuf, X64_R12);
  X64EmitPopReg(ABuf, X64_RBX);
  X64EmitRet(ABuf);
end;

procedure X64ResolvePatches(const ABuf: TWasmCodeBuffer);
var
  I: Integer;
  P: TWasmJitPatch;
  Delta, Rel, InstrLen: Integer;
begin
  for I := 0 to ABuf.PatchCount - 1 do
  begin
    P := ABuf.GetPatch(I);
    InstrLen := P.Kind;               { 5 = JMP rel32, 6 = Jcc rel32 }
    if InstrLen < 5 then
      raise EWasmJitBranchRange.CreateFmt(
        'JIT: unexpected branch patch kind %d', [InstrLen]);
    Delta := ABuf.PatchDelta(I);      { target - site (Integer) }
    { rel32 is measured from the END of the branch instruction; the field is
      its last 4 bytes. Delta already fits Int32, so rel32 never overflows for
      a real function — the guard is kept only for shape parity (§4.3). }
    Rel := Delta - InstrLen;
    ABuf.PatchU32(P.SiteOffset + (InstrLen - 4), UInt32(Rel));
  end;
end;

{ ===================================================================== }
{  op templates                                                          }
{ ===================================================================== }

procedure EmitTrapCall(const ABuf: TWasmCodeBuffer; const AKind: TWasmTrapKind);
begin
  X64EmitMovRegImm32(ABuf, X64_ARG0, UInt32(Ord(AKind)));
  X64EmitCallHelper(ABuf, aohTrapKind);   { does not return }
end;

{ The back-edge epoch check (§6): if [r13] (live Store.Epoch) <> r14 (snapshot),
  call X64TrapKind(wtkEpochInterrupt); otherwise fall through. }
procedure EmitEpochCheck(const ABuf: TWasmCodeBuffer);
var
  Cont: TWasmJitLabel;
begin
  X64EmitLoadMem64(ABuf, X64_RAX, X64_REG_EPOCHADDR, 0);       { rax := *r13 }
  X64EmitAluRegReg(ABuf, $39, True, X64_RAX, X64_REG_EPOCH);   { cmp rax, r14 }
  Cont := ABuf.NewLabel;
  X64EmitJccTo(ABuf, X64_CC_E, UInt32(Cont));                  { je Cont }
  EmitTrapCall(ABuf, wtkEpochInterrupt);
  ABuf.BindLabel(Cont);
end;

{ 32-bit two-operand ALU: eax := op(w[A], w[B]); store the widened slot (the
  32-bit op zero-extends into rax). }
procedure EmitAluW(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AOpcode: Byte);
begin
  X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot32(ABuf, X64_RCX, AIns.B);
  X64EmitAluRegReg(ABuf, AOpcode, False, X64_RAX, X64_RCX);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitAluX(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AOpcode: Byte);
begin
  X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  X64EmitAluRegReg(ABuf, AOpcode, True, X64_RAX, X64_RCX);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitMulW(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot32(ABuf, X64_RCX, AIns.B);
  X64EmitImul(ABuf, False, X64_RAX, X64_RCX);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitMulX(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  X64EmitImul(ABuf, True, X64_RAX, X64_RCX);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

{ Variable shift/rotate: value in eax/rax, count in ecx/rcx (CL is the count
  the hardware masks). }
procedure EmitShiftW(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const ASubop: Byte);
begin
  X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot32(ABuf, X64_RCX, AIns.B);
  X64EmitShiftCl(ABuf, ASubop, False, X64_RAX);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitShiftX(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const ASubop: Byte);
begin
  X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  X64EmitShiftCl(ABuf, ASubop, True, X64_RAX);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitRelW(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const ACc: Byte);
begin
  X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot32(ABuf, X64_RCX, AIns.B);
  X64EmitAluRegReg(ABuf, $39, False, X64_RAX, X64_RCX);   { cmp eax, ecx }
  X64EmitSetccAl(ABuf, ACc);
  X64EmitMovzxEaxAl(ABuf);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitRelX(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const ACc: Byte);
begin
  X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  X64EmitAluRegReg(ABuf, $39, True, X64_RAX, X64_RCX);    { cmp rax, rcx }
  X64EmitSetccAl(ABuf, ACc);
  X64EmitMovzxEaxAl(ABuf);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitEqzW(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  X64EmitAluRegReg(ABuf, $85, False, X64_RAX, X64_RAX);   { test eax, eax }
  X64EmitSetccAl(ABuf, X64_CC_E);
  X64EmitMovzxEaxAl(ABuf);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitEqzX(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
  X64EmitAluRegReg(ABuf, $85, True, X64_RAX, X64_RAX);    { test rax, rax }
  X64EmitSetccAl(ABuf, X64_CC_E);
  X64EmitMovzxEaxAl(ABuf);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitSelect(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  { Condition register rides in Imm (ifkSrcReg). cond<>0 -> A else B, a full
    8-byte conditional copy. cmove moves when ZF=1 (cond=0), so it selects B. }
  X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
  X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  X64EmitLoadSlot32(ABuf, X64_RDX, UInt32(AIns.Imm));      { edx := cond (i32) }
  X64EmitAluRegReg(ABuf, $85, False, X64_RDX, X64_RDX);    { test edx, edx }
  X64EmitCmovcc(ABuf, X64_CC_E, True, X64_RAX, X64_RCX);   { cmove rax, rcx }
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitConst32(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  { i32/f32 const: low 32 bits of Imm, high half cleared (the 32-bit mov
    zero-extends into rax). }
  X64EmitMovRegImm32(ABuf, X64_RAX, UInt32(AIns.Imm and $FFFFFFFF));
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitConst64(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  X64EmitMovRegImm64(ABuf, X64_RAX, UInt64(AIns.Imm));
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitBrTable(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32);
var
  N: UInt32;
  I: Integer;
  Target: UInt32;
begin
  { Aux block [s0 .. s(N-1)]; the last entry is the default. A compare chain is
    the simplest correct baseline. }
  N := IrAuxBlockCount(AAux, AIns.B);
  X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);   { selector }
  for I := 0 to Integer(N) - 2 do
  begin
    Target := IrAuxBlockItem(AAux, AIns.B, UInt32(I));
    X64EmitMovRegImm32(ABuf, X64_RCX, UInt32(I));
    X64EmitAluRegReg(ABuf, $39, False, X64_RAX, X64_RCX);   { cmp eax, ecx }
    X64EmitJccTo(ABuf, X64_CC_E, Target);
  end;
  if N >= 1 then
  begin
    Target := IrAuxBlockItem(AAux, AIns.B, N - 1);
    X64EmitJmpTo(ABuf, Target);
  end;
end;

{ Helper-call templates (§1.4): op ordinal in rdi (arg0), operand(s) in
  rsi/rdx, call the thunk, store rax to the destination slot. }
procedure EmitLeafBinary(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  X64EmitLoadSlot64(ABuf, X64_ARG1, AIns.A);
  X64EmitLoadSlot64(ABuf, X64_ARG2, AIns.B);
  X64EmitMovRegImm32(ABuf, X64_ARG0, UInt32(Ord(AIns.Op)));
  X64EmitCallHelper(ABuf, aohOpBinary);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitLeafUnary(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr);
begin
  X64EmitLoadSlot64(ABuf, X64_ARG1, AIns.A);
  X64EmitMovRegImm32(ABuf, X64_ARG0, UInt32(Ord(AIns.Op)));
  X64EmitCallHelper(ABuf, aohOpUnary);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitDivRem(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AWide, ASigned, ARem: Boolean);
var
  NonZero, Safe, Done: TWasmJitLabel;
begin
  if AWide then
  begin
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
    X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  end
  else
  begin
    X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
    X64EmitLoadSlot32(ABuf, X64_RCX, AIns.B);
  end;
  X64EmitAluRegReg(ABuf, $85, AWide, X64_RCX, X64_RCX);
  NonZero := ABuf.NewLabel;
  X64EmitJccTo(ABuf, X64_CC_NE, UInt32(NonZero));
  EmitTrapCall(ABuf, wtkDivideByZero);
  ABuf.BindLabel(NonZero);

  if ASigned then
  begin
    Safe := ABuf.NewLabel;
    if AWide then
    begin
      X64EmitMovRegImm64(ABuf, X64_RDX, High(UInt64));
      X64EmitAluRegReg(ABuf, $39, True, X64_RCX, X64_RDX);
      X64EmitJccTo(ABuf, X64_CC_NE, UInt32(Safe));
      X64EmitMovRegImm64(ABuf, X64_RDX, UInt64(1) shl 63);
      X64EmitAluRegReg(ABuf, $39, True, X64_RAX, X64_RDX);
    end
    else
    begin
      X64EmitMovRegImm32(ABuf, X64_RDX, High(UInt32));
      X64EmitAluRegReg(ABuf, $39, False, X64_RCX, X64_RDX);
      X64EmitJccTo(ABuf, X64_CC_NE, UInt32(Safe));
      X64EmitMovRegImm32(ABuf, X64_RDX, UInt32(1) shl 31);
      X64EmitAluRegReg(ABuf, $39, False, X64_RAX, X64_RDX);
    end;
    X64EmitJccTo(ABuf, X64_CC_NE, UInt32(Safe));
    if not ARem then
      EmitTrapCall(ABuf, wtkIntegerOverflow)
    else
    begin
      { Unlike A64 SDIV, x86 IDIV faults on MIN_INT/-1. Remainder is defined as
        zero, so bypass IDIV for precisely this pair. }
      X64EmitMovRegImm32(ABuf, X64_RAX, 0);
      Done := ABuf.NewLabel;
      X64EmitJmpTo(ABuf, UInt32(Done));
    end;
    ABuf.BindLabel(Safe);
  end;

  if ASigned then
    X64EmitSignDividend(ABuf, AWide)
  else
    X64EmitAluRegReg(ABuf, $31, False, X64_RDX, X64_RDX);
  X64EmitDivReg(ABuf, ASigned, AWide, X64_RCX);
  if ARem then
    X64EmitMovRegReg(ABuf, X64_RAX, X64_RDX);
  if ASigned and ARem then
    ABuf.BindLabel(Done);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitCanonicalFloatResult(const ABuf: TWasmCodeBuffer;
  const AWide: Boolean; const ADest: UInt32);
var
  NanValue, Done: TWasmJitLabel;
begin
  X64EmitScalarFloatUcomi(ABuf, AWide, 0, 0);
  NanValue := ABuf.NewLabel;
  Done := ABuf.NewLabel;
  X64EmitJccTo(ABuf, X64_CC_P, UInt32(NanValue));
  X64EmitMovFromXmm(ABuf, X64_RAX, 0, AWide);
  X64EmitJmpTo(ABuf, UInt32(Done));
  ABuf.BindLabel(NanValue);
  if AWide then
    X64EmitMovRegImm64(ABuf, X64_RAX, WASM_F64_CANONICAL_NAN)
  else
    X64EmitMovRegImm32(ABuf, X64_RAX, WASM_F32_CANONICAL_NAN);
  ABuf.BindLabel(Done);
  X64EmitStoreSlot64(ABuf, X64_RAX, ADest);
end;

procedure EmitFloatBinary(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AWide: Boolean; const AOpcode: Byte);
begin
  if AWide then
  begin
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
    X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  end
  else
  begin
    X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
    X64EmitLoadSlot32(ABuf, X64_RCX, AIns.B);
  end;
  X64EmitMovToXmm(ABuf, 0, X64_RAX, AWide);
  X64EmitMovToXmm(ABuf, 1, X64_RCX, AWide);
  X64EmitScalarFloatBinary(ABuf, AOpcode, AWide, 0, 1);
  EmitCanonicalFloatResult(ABuf, AWide, AIns.Dest);
end;

procedure EmitFloatRel(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AWide: Boolean;
  const APredicate: Byte; const ASwap: Boolean);
var
  ResultXmm: Byte;
begin
  if AWide then
  begin
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
    X64EmitLoadSlot64(ABuf, X64_RCX, AIns.B);
  end
  else
  begin
    X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
    X64EmitLoadSlot32(ABuf, X64_RCX, AIns.B);
  end;
  X64EmitMovToXmm(ABuf, 0, X64_RAX, AWide);
  X64EmitMovToXmm(ABuf, 1, X64_RCX, AWide);
  if ASwap then
  begin
    X64EmitScalarFloatCompare(ABuf, APredicate, AWide, 1, 0);
    ResultXmm := 1;
  end
  else
  begin
    X64EmitScalarFloatCompare(ABuf, APredicate, AWide, 0, 1);
    ResultXmm := 0;
  end;
  X64EmitMovFromXmm(ABuf, X64_RAX, ResultXmm, AWide);
  { CMPSS/CMPSD produces all-ones or zero; narrow to wasm's i32 1/0. }
  ABuf.EmitByte($83);
  ABuf.EmitByte($E0);   { and eax, 1 }
  ABuf.EmitByte($01);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitIntegerConversion(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ALoadWide: Boolean;
  const ASourceBits: Byte; const ATargetWide: Boolean);
begin
  if ALoadWide then
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A)
  else
    X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  if ASourceBits <> 0 then
    X64EmitSignExtendRax(ABuf, ASourceBits, ATargetWide);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitIntToFloatConversion(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ASourceWide, AResultWide,
  AUnsigned: Boolean);
begin
  if ASourceWide then
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A)
  else
    X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  { x86 has no u32 scalar conversion before AVX-512. A zero-extended u32 is a
    positive i64, so the r64 signed conversion is exactly equivalent. }
  X64EmitIntToFloat(ABuf, ASourceWide or AUnsigned, AResultWide, 0, X64_RAX);
  X64EmitMovFromXmm(ABuf, X64_RAX, 0, AResultWide);
  X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
end;

procedure EmitFloatWidthConversion(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const ADemote: Boolean);
begin
  if ADemote then
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A)
  else
    X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
  X64EmitMovToXmm(ABuf, 0, X64_RAX, ADemote);
  X64EmitFloatWidthConvert(ABuf, ADemote, 0, 0);
  EmitCanonicalFloatResult(ABuf, not ADemote, AIns.Dest);
end;

{ The uniform three-argument runtime/vector helper call: store (r12), regbase
  (rbx), and a pointer to the live IR instruction. Fix C: the baked pointer is
  AInsPtr = @Fn^.Code[i], the driver's guaranteed-stable location in the
  borrowed IR (outliving the code block, §3.4) — NOT @AIns, which would rely on
  FPC passing the const record by reference through every forwarding hop. No
  operand marshaling: the dispatcher reads and writes the in-memory register
  file directly through rbx. AInsPtr is nil only for the exec-only unit tests,
  which never drive a runtime template. }
procedure EmitRuntimeOp(const ABuf: TWasmCodeBuffer; const AInsIndex: UInt32);
begin
  X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);
  X64EmitMovRegReg(ABuf, X64_ARG1, X64_REG_REGFILE);
  X64EmitIrInsPtr(ABuf, X64_ARG2, AInsIndex);          { rdx := @Fn^.Code[i] }
  X64EmitCallHelper(ABuf, aohRtDispatch);
end;

procedure EmitVecOp(const ABuf: TWasmCodeBuffer; const AInsIndex: UInt32);
begin
  X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);
  X64EmitMovRegReg(ABuf, X64_ARG1, X64_REG_REGFILE);
  X64EmitIrInsPtr(ABuf, X64_ARG2, AInsIndex);          { rdx := @Fn^.Code[i] }
  X64EmitCallHelper(ABuf, aohVecDispatch);
end;

procedure EmitBranchRef(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AInsIndex: UInt32);
begin
  X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);
  X64EmitMovRegReg(ABuf, X64_ARG1, X64_REG_REGFILE);
  X64EmitIrInsPtr(ABuf, X64_ARG2, AInsIndex);          { rdx := @Fn^.Code[i] }
  X64EmitCallHelper(ABuf, aohRefBranchPredicate);      { eax := P (1/0) }
  X64EmitAluRegReg(ABuf, $85, False, X64_RAX, X64_RAX);   { test eax, eax }
  case AIns.Op of
    iroBrOnNull, iroBrOnCast:
      X64EmitJccTo(ABuf, X64_CC_NE, AIns.B);           { taken when P holds }
  else
    X64EmitJccTo(ABuf, X64_CC_E, AIns.B);              { taken when not P }
  end;
  if AIns.Dest <> IR_NO_REG then
  begin
    X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
    X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
  end;
end;

{ --- the call templates (§4.4/§4.5): marshal -> helper -> unmarshal ------
  Native-stack scratch layout (rsp-relative): [args][results], rounded up to
  16 (SysV keeps rsp 16-aligned at a CALL). Released before returning. }
function X64Align16(const AValue: UInt32): UInt32;
begin
  Result := (AValue + 15) and not UInt32(15);
end;

function X64CallFrameBytes(const AArgSlots, AResultSlots: UInt32): UInt32;
begin
  Result := X64Align16((AArgSlots + AResultSlots) * X64_SLOT_SIZE);
  if Result = 0 then
    Result := 16;
end;

procedure EmitMarshalArgs(const ABuf: TWasmCodeBuffer;
  const AAux: TWasmIrAuxU32; const ABlock, ACount: UInt32);
var
  I: UInt32;
begin
  I := 0;
  while I < ACount do
  begin
    X64EmitLoadSlot64(ABuf, X64_RAX, IrAuxBlockItem(AAux, ABlock, I));
    X64EmitStoreMem64(ABuf, X64_RAX, X64_RSP, Int32(I * X64_SLOT_SIZE));
    Inc(I);
  end;
end;

procedure EmitUnmarshalResults(const ABuf: TWasmCodeBuffer;
  const AAux: TWasmIrAuxU32; const ABlock, ACount, AOffset: UInt32);
var
  I: UInt32;
begin
  I := 0;
  while I < ACount do
  begin
    X64EmitLoadMem64(ABuf, X64_RAX, X64_RSP,
      Int32(AOffset + I * X64_SLOT_SIZE));
    X64EmitStoreSlot64(ABuf, X64_RAX, IrAuxBlockItem(AAux, ABlock, I));
    Inc(I);
  end;
end;

procedure EmitCall(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32);
var
  ArgN, ResN, ArgBytes, ResBytes, StateOffset, FrameBytes: UInt32;
  FallbackLabel, DoneLabel: TWasmJitLabel;
begin
  ArgN := IrAuxBlockCount(AAux, AIns.A);
  ResN := IrAuxBlockCount(AAux, AIns.B);
  ArgBytes := ArgN * X64_SLOT_SIZE;
  ResBytes := ResN * X64_SLOT_SIZE;
  StateOffset := ArgBytes + ResBytes;
  if AIns.Op = iroCall then
    FrameBytes := X64Align16(StateOffset + SizeOf(TWasmJitDirectCallState))
  else
    FrameBytes := X64CallFrameBytes(ArgN, ResN);

  X64EmitSubRsp(ABuf, Int32(FrameBytes));
  EmitMarshalArgs(ABuf, AAux, AIns.A, ArgN);
  X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);   { store }

  case AIns.Op of
    iroCall:
      begin
        FallbackLabel := ABuf.NewLabel;
        DoneLabel := ABuf.NewLabel;
        X64EmitMovRegImm32(ABuf, X64_ARG1, UInt32(AIns.Imm));    { funcidx }
        X64EmitLea(ABuf, X64_ARG2, X64_RSP, 0);                  { args }
        X64EmitLea(ABuf, X64_ARG3, X64_RSP, Int32(ArgBytes));    { results }
        X64EmitLea(ABuf, X64_ARG4, X64_RSP, Int32(StateOffset)); { state }
        X64EmitCallHelper(ABuf, aohDirectCallPrepare);
        X64EmitAluRegReg(ABuf, $85, True, X64_RAX, X64_RAX);     { test rax,rax }
        X64EmitJccTo(ABuf, X64_CC_E, UInt32(FallbackLabel));
        X64EmitMovRegReg(ABuf, X64_R11, X64_RAX);                { entry }
        X64EmitLoadMem64(ABuf, X64_ARG0, X64_RSP, Int32(StateOffset));
        X64EmitMovRegReg(ABuf, X64_ARG1, X64_REG_STORE);
        X64EmitLoadMem64(ABuf, X64_ARG2, X64_RSP,
          Int32(StateOffset + X64_SLOT_SIZE));
        X64EmitCallReg(ABuf, X64_R11);
        X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);
        X64EmitCallHelper(ABuf, aohDirectCallFinish);
        X64EmitJmpTo(ABuf, UInt32(DoneLabel));
        ABuf.BindLabel(FallbackLabel);
        X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);
        X64EmitMovRegImm32(ABuf, X64_ARG1, UInt32(AIns.Imm));
        X64EmitLea(ABuf, X64_ARG2, X64_RSP, 0);
        X64EmitLea(ABuf, X64_ARG3, X64_RSP, Int32(ArgBytes));
        X64EmitCallHelper(ABuf, aohCall);
        ABuf.BindLabel(DoneLabel);
      end;
    iroCallIndirect:
      begin
        X64EmitMovRegImm64(ABuf, X64_ARG1, UInt64(AIns.Imm));    { packed }
        X64EmitLoadSlot64(ABuf, X64_ARG2, AIns.Dest);            { index }
        X64EmitLea(ABuf, X64_ARG3, X64_RSP, 0);                  { args }
        X64EmitLea(ABuf, X64_ARG4, X64_RSP, Int32(ArgBytes));    { results }
        X64EmitCallHelper(ABuf, aohCallIndirect);
      end;
  else
    { iroCallRef }
    X64EmitLoadSlot64(ABuf, X64_ARG1, AIns.Dest);               { funcref }
    X64EmitLea(ABuf, X64_ARG2, X64_RSP, 0);
    X64EmitLea(ABuf, X64_ARG3, X64_RSP, Int32(ArgBytes));
    X64EmitCallHelper(ABuf, aohCallRef);
  end;

  EmitUnmarshalResults(ABuf, AAux, AIns.B, ResN, ArgBytes);
  X64EmitAddRsp(ABuf, Int32(FrameBytes));
end;

procedure EmitReturnCall(const ABuf: TWasmCodeBuffer; const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32);
var
  ArgN, FrameBytes: UInt32;
begin
  ArgN := IrAuxBlockCount(AAux, AIns.A);
  FrameBytes := X64CallFrameBytes(ArgN, 0);

  X64EmitSubRsp(ABuf, Int32(FrameBytes));
  EmitMarshalArgs(ABuf, AAux, AIns.A, ArgN);
  X64EmitMovRegReg(ABuf, X64_ARG0, X64_REG_STORE);

  case AIns.Op of
    iroReturnCall:
      begin
        X64EmitMovRegImm32(ABuf, X64_ARG1, UInt32(AIns.Imm));
        X64EmitLea(ABuf, X64_ARG2, X64_RSP, 0);
        X64EmitMovRegImm32(ABuf, X64_ARG3, ArgN);
        X64EmitCallHelper(ABuf, aohReturnCall);
      end;
    iroReturnCallIndirect:
      begin
        X64EmitMovRegImm64(ABuf, X64_ARG1, UInt64(AIns.Imm));
        X64EmitLoadSlot64(ABuf, X64_ARG2, AIns.Dest);
        X64EmitLea(ABuf, X64_ARG3, X64_RSP, 0);
        X64EmitMovRegImm32(ABuf, X64_ARG4, ArgN);
        X64EmitCallHelper(ABuf, aohReturnCallIndirect);
      end;
  else
    { iroReturnCallRef }
    X64EmitLoadSlot64(ABuf, X64_ARG1, AIns.Dest);
    X64EmitLea(ABuf, X64_ARG2, X64_RSP, 0);
    X64EmitMovRegImm32(ABuf, X64_ARG3, ArgN);
    X64EmitCallHelper(ABuf, aohReturnCallRef);
  end;

  X64EmitAddRsp(ABuf, Int32(FrameBytes));
  X64EmitEpilogue(ABuf);
end;

{ ===================================================================== }
{  the per-op predicates + dispatch                                      }
{ ===================================================================== }

function X64RuntimeOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroI32Load, iroI64Load, iroF32Load, iroF64Load,
    iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
    iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
    iroI64Load32S, iroI64Load32U,
    iroI32Store, iroI64Store, iroF32Store, iroF64Store,
    iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16, iroI64Store32,
    iroMemorySize, iroMemoryGrow, iroMemoryInit, iroMemoryCopy, iroMemoryFill,
    iroDataDrop,
    iroTableGet, iroTableSet, iroTableSize, iroTableGrow, iroTableFill,
    iroTableInit, iroTableCopy, iroElemDrop,
    iroRefNull, iroRefIsNull, iroRefFunc, iroRefEq, iroRefAsNonNull,
    iroRefTest, iroRefCast,
    iroGlobalGet, iroGlobalSet,
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

function X64VecOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := (Ord(AOp) >= Ord(iroV128Load))
    and (Ord(AOp) <= Ord(iroArrayFillVec));
end;

function X64BranchRefOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroBrOnNull, iroBrOnNonNull, iroBrOnCast, iroBrOnCastFail:
      Result := True;
  else
    Result := False;
  end;
end;

function X64CallOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroCall, iroCallIndirect, iroCallRef,
    iroReturnCall, iroReturnCallIndirect, iroReturnCallRef:
      Result := True;
  else
    Result := False;
  end;
end;

function X64LeafBinaryOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroF32Min, iroF32Max, iroF32Copysign,
    iroF64Min, iroF64Max, iroF64Copysign:
      Result := True;
  else
    Result := False;
  end;
end;

{ Leaf unaries — the aarch64 set PLUS clz/ctz (routed leaf on x86-64; see the
  unit header). }
function X64LeafUnaryOp(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroI32Clz, iroI32Ctz, iroI64Clz, iroI64Ctz,
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

{ Inlined ops — the aarch64 set MINUS clz/ctz (which are leaf here). }
function X64InlineOp(const AOp: TWasmIrOp): Boolean;
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
    iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or,
    iroI32Xor, iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
    iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or,
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

function X64CanEmitOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := X64InlineOp(AOp) or X64LeafBinaryOp(AOp)
    or X64LeafUnaryOp(AOp) or X64CallOp(AOp)
    or X64RuntimeOp(AOp) or X64BranchRefOp(AOp)
    or X64VecOp(AOp);
end;

function X64CanEmitInstr(const AIns: TWasmIrInstr;
  const AAux: TWasmIrAuxU32): Boolean;
begin
  Result := True;
  case AIns.Op of
    iroCall, iroCallIndirect, iroCallRef:
      Result := (IrAuxBlockCount(AAux, AIns.A)
        + IrAuxBlockCount(AAux, AIns.B)) <= X64_MAX_CALL_SLOTS;
    iroReturnCall, iroReturnCallIndirect, iroReturnCallRef:
      Result := IrAuxBlockCount(AAux, AIns.A) <= X64_MAX_CALL_SLOTS;
  end;
end;

function X64EmitOp(const ABuf: TWasmCodeBuffer;
  const AIns: TWasmIrInstr; const AAux: TWasmIrAuxU32;
  const AInsIndex: UInt32): Boolean;
begin
  Result := True;
  case AIns.Op of
    iroMove:
      begin
        X64EmitLoadSlot64(ABuf, X64_RAX, AIns.A);
        X64EmitStoreSlot64(ABuf, X64_RAX, AIns.Dest);
      end;

    iroI32Const, iroF32Const: EmitConst32(ABuf, AIns);
    iroI64Const, iroF64Const: EmitConst64(ABuf, AIns);

    iroJump:
      begin
        if (AIns.Imm and IR_JUMP_SAFEPOINT) <> 0 then
          EmitEpochCheck(ABuf);
        X64EmitJmpTo(ABuf, AIns.A);
      end;
    iroBranchIf:
      begin
        X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
        X64EmitAluRegReg(ABuf, $85, False, X64_RAX, X64_RAX);   { test eax,eax }
        X64EmitJccTo(ABuf, X64_CC_NE, AIns.B);
      end;
    iroBranchIfNot:
      begin
        X64EmitLoadSlot32(ABuf, X64_RAX, AIns.A);
        X64EmitAluRegReg(ABuf, $85, False, X64_RAX, X64_RAX);
        X64EmitJccTo(ABuf, X64_CC_E, AIns.B);
      end;
    iroBrTable: EmitBrTable(ABuf, AIns, AAux);
    iroReturn: X64EmitEpilogue(ABuf);
    iroUnreachable: EmitTrapCall(ABuf, wtkUnreachable);

    iroCall, iroCallIndirect, iroCallRef: EmitCall(ABuf, AIns, AAux);
    iroReturnCall, iroReturnCallIndirect, iroReturnCallRef:
      EmitReturnCall(ABuf, AIns, AAux);

    iroSelect: EmitSelect(ABuf, AIns);

    iroI32Eqz: EmitEqzW(ABuf, AIns);
    iroI32Eq: EmitRelW(ABuf, AIns, X64_CC_E);
    iroI32Ne: EmitRelW(ABuf, AIns, X64_CC_NE);
    iroI32LtS: EmitRelW(ABuf, AIns, X64_CC_L);
    iroI32LtU: EmitRelW(ABuf, AIns, X64_CC_B);
    iroI32GtS: EmitRelW(ABuf, AIns, X64_CC_G);
    iroI32GtU: EmitRelW(ABuf, AIns, X64_CC_A);
    iroI32LeS: EmitRelW(ABuf, AIns, X64_CC_LE);
    iroI32LeU: EmitRelW(ABuf, AIns, X64_CC_BE);
    iroI32GeS: EmitRelW(ABuf, AIns, X64_CC_GE);
    iroI32GeU: EmitRelW(ABuf, AIns, X64_CC_AE);

    iroI64Eqz: EmitEqzX(ABuf, AIns);
    iroI64Eq: EmitRelX(ABuf, AIns, X64_CC_E);
    iroI64Ne: EmitRelX(ABuf, AIns, X64_CC_NE);
    iroI64LtS: EmitRelX(ABuf, AIns, X64_CC_L);
    iroI64LtU: EmitRelX(ABuf, AIns, X64_CC_B);
    iroI64GtS: EmitRelX(ABuf, AIns, X64_CC_G);
    iroI64GtU: EmitRelX(ABuf, AIns, X64_CC_A);
    iroI64LeS: EmitRelX(ABuf, AIns, X64_CC_LE);
    iroI64LeU: EmitRelX(ABuf, AIns, X64_CC_BE);
    iroI64GeS: EmitRelX(ABuf, AIns, X64_CC_GE);
    iroI64GeU: EmitRelX(ABuf, AIns, X64_CC_AE);

    iroI32Add: EmitAluW(ABuf, AIns, $01);
    iroI32Sub: EmitAluW(ABuf, AIns, $29);
    iroI32Mul: EmitMulW(ABuf, AIns);
    iroI32And: EmitAluW(ABuf, AIns, $21);
    iroI32Or: EmitAluW(ABuf, AIns, $09);
    iroI32Xor: EmitAluW(ABuf, AIns, $31);
    iroI32Shl: EmitShiftW(ABuf, AIns, 4);
    iroI32ShrU: EmitShiftW(ABuf, AIns, 5);
    iroI32ShrS: EmitShiftW(ABuf, AIns, 7);
    iroI32Rotl: EmitShiftW(ABuf, AIns, 0);
    iroI32Rotr: EmitShiftW(ABuf, AIns, 1);

    iroI64Add: EmitAluX(ABuf, AIns, $01);
    iroI64Sub: EmitAluX(ABuf, AIns, $29);
    iroI64Mul: EmitMulX(ABuf, AIns);
    iroI64And: EmitAluX(ABuf, AIns, $21);
    iroI64Or: EmitAluX(ABuf, AIns, $09);
    iroI64Xor: EmitAluX(ABuf, AIns, $31);
    iroI64Shl: EmitShiftX(ABuf, AIns, 4);
    iroI64ShrU: EmitShiftX(ABuf, AIns, 5);
    iroI64ShrS: EmitShiftX(ABuf, AIns, 7);
    iroI64Rotl: EmitShiftX(ABuf, AIns, 0);
    iroI64Rotr: EmitShiftX(ABuf, AIns, 1);

    iroI32DivS: EmitDivRem(ABuf, AIns, False, True, False);
    iroI32DivU: EmitDivRem(ABuf, AIns, False, False, False);
    iroI32RemS: EmitDivRem(ABuf, AIns, False, True, True);
    iroI32RemU: EmitDivRem(ABuf, AIns, False, False, True);
    iroI64DivS: EmitDivRem(ABuf, AIns, True, True, False);
    iroI64DivU: EmitDivRem(ABuf, AIns, True, False, False);
    iroI64RemS: EmitDivRem(ABuf, AIns, True, True, True);
    iroI64RemU: EmitDivRem(ABuf, AIns, True, False, True);

    iroF32Add: EmitFloatBinary(ABuf, AIns, False, $58);
    iroF32Sub: EmitFloatBinary(ABuf, AIns, False, $5C);
    iroF32Mul: EmitFloatBinary(ABuf, AIns, False, $59);
    iroF32Div: EmitFloatBinary(ABuf, AIns, False, $5E);
    iroF64Add: EmitFloatBinary(ABuf, AIns, True, $58);
    iroF64Sub: EmitFloatBinary(ABuf, AIns, True, $5C);
    iroF64Mul: EmitFloatBinary(ABuf, AIns, True, $59);
    iroF64Div: EmitFloatBinary(ABuf, AIns, True, $5E);
    { CMPSS/CMPDS predicates: 0=eq, 1=lt, 2=le, 4=ne. gt/ge swap inputs. }
    iroF32Eq: EmitFloatRel(ABuf, AIns, False, 0, False);
    iroF32Ne: EmitFloatRel(ABuf, AIns, False, 4, False);
    iroF32Lt: EmitFloatRel(ABuf, AIns, False, 1, False);
    iroF32Gt: EmitFloatRel(ABuf, AIns, False, 1, True);
    iroF32Le: EmitFloatRel(ABuf, AIns, False, 2, False);
    iroF32Ge: EmitFloatRel(ABuf, AIns, False, 2, True);
    iroF64Eq: EmitFloatRel(ABuf, AIns, True, 0, False);
    iroF64Ne: EmitFloatRel(ABuf, AIns, True, 4, False);
    iroF64Lt: EmitFloatRel(ABuf, AIns, True, 1, False);
    iroF64Gt: EmitFloatRel(ABuf, AIns, True, 1, True);
    iroF64Le: EmitFloatRel(ABuf, AIns, True, 2, False);
    iroF64Ge: EmitFloatRel(ABuf, AIns, True, 2, True);

    iroI32WrapI64:
      EmitIntegerConversion(ABuf, AIns, False, 0, False);
    iroI64ExtendI32U:
      EmitIntegerConversion(ABuf, AIns, False, 0, True);
    iroI64ExtendI32S:
      EmitIntegerConversion(ABuf, AIns, False, 32, True);
    iroI32Extend8S:
      EmitIntegerConversion(ABuf, AIns, False, 8, False);
    iroI32Extend16S:
      EmitIntegerConversion(ABuf, AIns, False, 16, False);
    iroI64Extend8S:
      EmitIntegerConversion(ABuf, AIns, True, 8, True);
    iroI64Extend16S:
      EmitIntegerConversion(ABuf, AIns, True, 16, True);
    iroI64Extend32S:
      EmitIntegerConversion(ABuf, AIns, True, 32, True);
    iroF32ConvertI32S:
      EmitIntToFloatConversion(ABuf, AIns, False, False, False);
    iroF32ConvertI32U:
      EmitIntToFloatConversion(ABuf, AIns, False, False, True);
    iroF32ConvertI64S:
      EmitIntToFloatConversion(ABuf, AIns, True, False, False);
    iroF64ConvertI32S:
      EmitIntToFloatConversion(ABuf, AIns, False, True, False);
    iroF64ConvertI32U:
      EmitIntToFloatConversion(ABuf, AIns, False, True, True);
    iroF64ConvertI64S:
      EmitIntToFloatConversion(ABuf, AIns, True, True, False);
    iroF32DemoteF64: EmitFloatWidthConversion(ABuf, AIns, True);
    iroF64PromoteF32: EmitFloatWidthConversion(ABuf, AIns, False);
    iroI32ReinterpretF32, iroF32ReinterpretI32:
      EmitIntegerConversion(ABuf, AIns, False, 0, False);
    iroI64ReinterpretF64, iroF64ReinterpretI64:
      EmitIntegerConversion(ABuf, AIns, True, 0, True);

  else
    if X64LeafBinaryOp(AIns.Op) then
      EmitLeafBinary(ABuf, AIns)
    else if X64LeafUnaryOp(AIns.Op) then
      EmitLeafUnary(ABuf, AIns)
    else if X64RuntimeOp(AIns.Op) then
      EmitRuntimeOp(ABuf, AInsIndex)
    else if X64BranchRefOp(AIns.Op) then
      EmitBranchRef(ABuf, AIns, AInsIndex)
    else if X64VecOp(AIns.Op) then
      EmitVecOp(ABuf, AInsIndex)
    else
      Result := False;
  end;
end;

{ ===================================================================== }
{  the per-process helper table (aot-spec §1.2/§4.3)                     }
{ ===================================================================== }

var
  GX64HelperTable: array[TWasmAotHelper] of Pointer;
  GX64HelperTableFilled: Boolean = False;

function X64GetHelperTable: PPointer;
begin
  if not GX64HelperTableFilled then
  begin
    GX64HelperTable[aohTrapKind] := @X64TrapKind;
    GX64HelperTable[aohOpBinary] := @X64OpBinary;
    GX64HelperTable[aohOpUnary] := @X64OpUnary;
    GX64HelperTable[aohRtDispatch] := @X64RtDispatch;
    GX64HelperTable[aohVecDispatch] := @X64VecDispatch;
    GX64HelperTable[aohRefBranchPredicate] := @X64RefBranchPredicate;
    GX64HelperTable[aohCall] := @X64CallHelper;
    GX64HelperTable[aohCallIndirect] := @X64CallIndirectHelper;
    GX64HelperTable[aohCallRef] := @X64CallRefHelper;
    GX64HelperTable[aohReturnCall] := @X64ReturnCallHelper;
    GX64HelperTable[aohReturnCallIndirect] := @X64ReturnCallIndirectHelper;
    GX64HelperTable[aohReturnCallRef] := @X64ReturnCallRefHelper;
    GX64HelperTable[aohDirectCallPrepare] := @JitPrepareDirectCall;
    GX64HelperTable[aohDirectCallFinish] := @JitFinishDirectCall;
    GX64HelperTable[aohResolveMemory] := @X64ResolveMemory;
    GX64HelperTableFilled := True;
  end;
  Result := @GX64HelperTable[aohTrapKind];
end;

end.
