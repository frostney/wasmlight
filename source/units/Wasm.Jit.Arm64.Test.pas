{ Unit suite for Wasm.Jit.Arm64 — the aarch64 encoder and op templates
  (.agent/design/jit-spec.md §12.3 Wave 1 + Wave 2).

  TWO layers of proof:
    - PORTABLE bit assertions on the pure word builders, so a wrong constant is
      caught on every CI leg (the builders compute bytes and never execute).
      Load-bearing encodings are cross-checked against the byte patterns already
      proven executable in Wasm.Jit.CodeBuffer.Test (add w0,w0,w1 = 0x0B010000;
      ret = 0xD65F03C0; movz w0,#42 = 0x52800540) and against the ARMv8-A A64
      base-instruction encodings.
    - EXECUTABLE proof (aarch64 only): emit the Wave-2 prologue, an op template,
      and the epilogue into a real code buffer, make it executable, and call it
      against an in-memory register file — proving the frame-relative addressing,
      the pinned register-file base in x19, the callee-saved save/restore, and
      each inlined template, at the encoder level and below the whole runtime.
      The heavy differential coverage (float via leaves, div/rem traps, loops,
      NaN bits, br_table, unreachable) lives in Wasm.Jit.Test, which runs the
      real decode -> validate -> instantiate -> two-tier pipeline (§11).

  FPC gotchas (AGENTS.md): every test records at least one assertion; a generic
  Expect<T>(...) is never the lone statement of an `on..do`. }
program Wasm.Jit.Arm64.Test;

{$I Shared.inc}

{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Ir,
  Wasm.Jit.Arm64,
  Wasm.Jit.CodeBuffer,
  Wasm.Runtime.Store;

type
  { The register-file base is the FIRST pointer argument (x0 on AAPCS64); the
    Wave-2 prologue moves it into x19. The store is the second argument (x1) and
    is unused by these tests (they emit no epoch capture), so a one-argument
    cdecl call is fine — x1 is simply never dereferenced. }
  TWasmSlotFn = procedure(const ASlots: Pointer); cdecl;

  TArm64Tests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestWordBuilderBits;
    procedure TestFrameWordBits;
    procedure TestBranchPlaceholderBits;
    procedure TestSlotOffset;
    procedure TestPredicateCoversWave2;
    procedure TestCallArityFence;
    procedure TestBranchOffsetRangeGuard;
    procedure TestPositionIndependentSequences;
    procedure TestStaticCacheKeepsFourTemporaries;
    procedure TestStaticCacheKeepsShiftResult;

    procedure TestExecAddTemplate;
    procedure TestExecAddWraps;
    procedure TestExecMoveTemplate;
    procedure TestExecSubTemplate;
    procedure TestExecShlMasksCount;
    procedure TestExecRelopSigned;
    procedure TestExecConst;
    procedure TestExecI64Add;
  end;

function Ins(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32): TWasmIrInstr;
begin
  Result.Op := AOp;
  Result.Dest := ADest;
  Result.A := AA;
  Result.B := AB;
  Result.Imm := 0;
end;

{ --- portable bit assertions -------------------------------------------- }

procedure TArm64Tests.TestWordBuilderBits;
begin
  { The two proven executable in the CodeBuffer suite; asserting them here pins
    the builders to those exact bytes. }
  Expect<UInt32>(Arm64Ret).ToBe($D65F03C0);
  Expect<UInt32>(Arm64AddW(0, 0, 1)).ToBe($0B010000);
  Expect<UInt32>(Arm64MovzW(0, 42, 0)).ToBe($52800540);

  { Frame-relative loads/stores. }
  Expect<UInt32>(Arm64LdrW(1, 0, 8)).ToBe($B9400801);
  Expect<UInt32>(Arm64LdrX(1, 0, 8)).ToBe($F9400401);
  Expect<UInt32>(Arm64StrX(2, 0, 16)).ToBe($F9000802);
  { Scalar-memory zero-offset forms, independently assembled with clang. }
  Expect<UInt32>(Arm64MemRegOffset($B9400000, 11, 14, 10, False))
    .ToBe($B86A49CB);                    { ldr w11,[x14,w10,uxtw] }
  Expect<UInt32>(Arm64MemRegOffset($B9000000, 11, 14, 10, False))
    .ToBe($B82A49CB);                    { str w11,[x14,w10,uxtw] }
  Expect<UInt32>(Arm64MemRegOffset($F9400000, 11, 14, 10, True))
    .ToBe($F86A69CB);                    { ldr x11,[x14,x10] }

  { Wave-2 integer spine (ARMv8-A C6.2). }
  Expect<UInt32>(Arm64SubW(0, 1, 2)).ToBe($4B020020);
  Expect<UInt32>(Arm64MulW(0, 1, 2)).ToBe($1B027C20);
  Expect<UInt32>(Arm64SdivW(9, 9, 10)).ToBe($1ACA0D29);
  Expect<UInt32>(Arm64UdivX(9, 9, 10)).ToBe($9ACA0929);
  Expect<UInt32>(Arm64MsubW(9, 11, 10, 9)).ToBe($1B0AA569);
  Expect<UInt32>(Arm64AndW(0, 1, 2)).ToBe($0A020020);
  Expect<UInt32>(Arm64OrrW(0, 1, 2)).ToBe($2A020020);
  Expect<UInt32>(Arm64EorW(0, 1, 2)).ToBe($4A020020);
  Expect<UInt32>(Arm64LslvW(0, 1, 2)).ToBe($1AC22020);
  Expect<UInt32>(Arm64LsrvW(0, 1, 2)).ToBe($1AC22420);
  Expect<UInt32>(Arm64AsrvW(0, 1, 2)).ToBe($1AC22820);
  Expect<UInt32>(Arm64RorvW(0, 1, 2)).ToBe($1AC22C20);
  Expect<UInt32>(Arm64ClzW(0, 1)).ToBe($5AC01020);

  { cmp / cset / csel. cset w0,eq = 0x1A9F17E0 (a known value). }
  Expect<UInt32>(Arm64CmpW(1, 2)).ToBe($6B02003F);
  Expect<UInt32>(Arm64CsetW(0, ARM64_COND_EQ)).ToBe($1A9F17E0);
  Expect<UInt32>(Arm64CsetW(0, ARM64_COND_NE)).ToBe($1A9F07E0);
  Expect<UInt32>(Arm64CselX(10, 10, 11, ARM64_COND_NE)).ToBe($9A8B114A);

  { Native scalar floating point and exact conversions, assembled independently
    with clang's aarch64 assembler. }
  Expect<UInt32>(Arm64FmovSFromW(0, 9)).ToBe($1E270120);
  Expect<UInt32>(Arm64FmovXFromD(9, 0)).ToBe($9E660009);
  Expect<UInt32>(Arm64FaddS(0, 0, 1)).ToBe($1E212800);
  Expect<UInt32>(Arm64FdivD(0, 0, 1)).ToBe($1E611800);
  Expect<UInt32>(Arm64FcmpS(0, 1)).ToBe($1E212000);
  Expect<UInt32>(Arm64ScvtfSX(0, 9)).ToBe($9E220120);
  Expect<UInt32>(Arm64UcvtfDW(0, 9)).ToBe($1E630120);
  Expect<UInt32>(Arm64FcvtSD(0, 0)).ToBe($1E624000);
  Expect<UInt32>(Arm64SxtwX(9, 9)).ToBe($93407D29);

  { Native Advanced SIMD subset, independently assembled with clang. }
  Expect<UInt32>(Arm64LdrQ(0, 19, 16)).ToBe($3DC00660);
  Expect<UInt32>(Arm64StrQ(1, 19, 32)).ToBe($3D800A61);
  Expect<UInt32>(Arm64VecAnd(0, 1, 2)).ToBe($4E221C20);
  Expect<UInt32>(Arm64VecBic(0, 1, 2)).ToBe($4E621C20);
  Expect<UInt32>(Arm64VecOrr(0, 1, 2)).ToBe($4EA21C20);
  Expect<UInt32>(Arm64VecEor(0, 1, 2)).ToBe($6E221C20);
  Expect<UInt32>(Arm64VecMvn(0, 1)).ToBe($6E205820);
  Expect<UInt32>(Arm64VecAdd(0, 1, 2, 3)).ToBe($4EE28420);
  Expect<UInt32>(Arm64VecSub(0, 1, 2, 2)).ToBe($6EA28420);
  Expect<UInt32>(Arm64VecDup(0, 9, 1)).ToBe($4E020D20);
  Expect<UInt32>(Arm64VecExtract(9, 0, 0, 15, True)).ToBe($0E1F2C09);
  Expect<UInt32>(Arm64VecExtract(9, 0, 3, 1, False)).ToBe($4E183C09);

  { movk, add-immediate, blr, mov reg. }
  Expect<UInt32>(Arm64MovkW(0, 1, 1)).ToBe($72A00020);
  Expect<UInt32>(Arm64AddImmX(21, 20, 8)).ToBe($91002295);
  Expect<UInt32>(Arm64Blr(9)).ToBe($D63F0120);
  Expect<UInt32>(Arm64MovReg(19, 0)).ToBe($AA0003F3);

  { Wave-3 call scratch (jit-spec §4.4). Register field 31 means SP — not the
    zero register — in the add/sub-immediate and the scaled load/store forms,
    which is the whole mechanism by which a call site reserves and addresses
    its marshaling buffer. These four are the load-bearing words. }
  Expect<UInt32>(Arm64SubImmX(ARM64_REG_SP, ARM64_REG_SP, 32))
    .ToBe($D10083FF);                                    { sub sp,sp,#32 }
  Expect<UInt32>(Arm64AddImmX(ARM64_REG_SP, ARM64_REG_SP, 32))
    .ToBe($910083FF);                                    { add sp,sp,#32 }
  Expect<UInt32>(Arm64AddImmX(2, ARM64_REG_SP, 0)).ToBe($910003E2); { mov x2,sp }
  Expect<UInt32>(Arm64StrX(9, ARM64_REG_SP, 8)).ToBe($F90007E9); { str x9,[sp,#8] }
  Expect<UInt32>(Arm64LdrX(9, ARM64_REG_SP, 8)).ToBe($F94007E9); { ldr x9,[sp,#8] }
end;

procedure TArm64Tests.TestFrameWordBits;
begin
  { The position-independent frame save/restore words: SIX callee-saved pins
    (x19..x24) + x30 in a 64-byte frame (aot-spec §1.2/§1.3/§4.3). }
  Expect<UInt32>(Arm64StpX19X20PreIndex64).ToBe($A9BC53F3);
  Expect<UInt32>(Arm64StpX21X22Off16).ToBe($A9015BF5);
  Expect<UInt32>(Arm64StpX23X24Off32).ToBe($A90263F7);
  Expect<UInt32>(Arm64LdpX23X24Off32).ToBe($A94263F7);
  Expect<UInt32>(Arm64LdpX21X22Off16).ToBe($A9415BF5);
  Expect<UInt32>(Arm64LdpX19X20PostIndex64).ToBe($A8C453F3);
  { str/ldr x30 at [sp,#48] reuse the scaled LDR/STR builders. }
  Expect<UInt32>(Arm64StrX(30, 31, 48)).ToBe($F9001BFE);
  Expect<UInt32>(Arm64LdrX(30, 31, 48)).ToBe($F9401BFE);
end;

procedure TArm64Tests.TestStaticCacheKeepsFourTemporaries;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TArm64RegCache;
  I: Integer;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Arm64EnableStaticRegCache(Buf, Cache, [0, 1]);
    for I := 0 to 3 do
      Expect<Boolean>(Arm64EmitOpCached(Buf,
        MakeIrInstr(iroI32Const, UInt32(I + 2), 0, 0, I), Aux,
        UInt32(I), False, False, False, Cache)).ToBe(True);
    for I := 0 to 3 do
    begin
      Expect<Boolean>(Cache.Entries[I + 2].Valid).ToBe(True);
      Expect<UInt32>(Cache.Entries[I + 2].Slot).ToBe(UInt32(I + 2));
    end;
  finally
    Buf.Free;
  end;
end;

procedure TArm64Tests.TestStaticCacheKeepsShiftResult;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TArm64RegCache;
  I: Integer;
  Found: Boolean;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Arm64EnableStaticRegCache(Buf, Cache, [0, 1]);
    Expect<Boolean>(Arm64EmitOpCached(Buf,
      MakeIrInstr(iroI32Const, 2, 0, 0, 7), Aux,
      0, False, False, False, Cache)).ToBe(True);
    Expect<Boolean>(Arm64EmitOpCached(Buf,
      MakeIrInstr(iroI32Const, 3, 0, 0, 2), Aux,
      1, False, False, False, Cache)).ToBe(True);
    Expect<Boolean>(Arm64EmitOpCached(Buf,
      MakeIrInstr(iroI32Shl, 4, 2, 3, 0), Aux,
      2, False, False, False, Cache)).ToBe(True);
    Found := False;
    for I := 0 to High(Cache.Entries) do
      Found := Found or (Cache.Entries[I].Valid and
        (Cache.Entries[I].Slot = 4));
    Expect<Boolean>(Found).ToBe(True);
  finally
    Buf.Free;
  end;
end;

procedure TArm64Tests.TestBranchPlaceholderBits;
begin
  Expect<UInt32>(Arm64BPlaceholder).ToBe($14000000);
  Expect<UInt32>(Arm64BCondPlaceholder(ARM64_COND_EQ)).ToBe($54000000);
  Expect<UInt32>(Arm64CbzWPlaceholder(9)).ToBe($34000009);
  Expect<UInt32>(Arm64CbnzWPlaceholder(9)).ToBe($35000009);
end;

procedure TArm64Tests.TestSlotOffset;
begin
  Expect<UInt32>(Arm64SlotByteOffset(0)).ToBe(0);
  Expect<UInt32>(Arm64SlotByteOffset(3)).ToBe(24);
end;

procedure TArm64Tests.TestPredicateCoversWave2;
begin
  { The Wave-2 spine: numeric, control, parametric, variable-move. }
  Expect<Boolean>(Arm64CanEmitOp(iroMove)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32Add)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32Sub)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI64Mul)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32DivS)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroF64Add)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroF32Sqrt)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32LtS)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroSelect)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroBrTable)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroReturn)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroUnreachable)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32TruncSatF32S)).ToBe(True);

  { Wave 3: the whole call family now has templates. }
  Expect<Boolean>(Arm64CanEmitOp(iroCall)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroCallIndirect)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroCallRef)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroReturnCall)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroReturnCallIndirect)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroReturnCallRef)).ToBe(True);

  { Waves 4 & 5 add the memory / table / reference / global / GC op families as
    uniform helper-call templates (§7-§9), so they now compile. }
  Expect<Boolean>(Arm64CanEmitOp(iroI32Load)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32Store8)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroMemoryGrow)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroTableGet)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroGlobalGet)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroGlobalSet)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroRefFunc)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroRefCast)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroBrOnCast)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroStructNew)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroArrayGet)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroRefI31)).ToBe(True);

  { Wave 6 accepts the whole v128 op set — the $FD ops and the IR-only v128
    variants — so the predicate now covers them too (dispatched via JitDoVec). }
  Expect<Boolean>(Arm64CanEmitOp(iroV128Load)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroV128Const)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32x4Add)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroF32x4Pmin)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI8x16Shuffle)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroI32x4RelaxedDotI8x16I7x16AddS)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroMoveVec)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroSelectVec)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroGlobalGetVec)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroStructGetVec)).ToBe(True);
  Expect<Boolean>(Arm64CanEmitOp(iroArrayFillVec)).ToBe(True);

  { The ONLY ops still declined are the EH ops — after Wave 6 a function is
    compilable iff it contains no exception-handling op (§10.2). }
  Expect<Boolean>(Arm64CanEmitOp(iroThrow)).ToBe(False);
  Expect<Boolean>(Arm64CanEmitOp(iroThrowRef)).ToBe(False);
end;

{ The instruction-level half of the predicate (jit-spec §4.4): a call site's
  argument + result marshaling must fit the backend's native-stack scratch, so
  an over-wide call declines the whole function rather than reserving a frame
  its `sub sp,#imm12` cannot encode. Non-call instructions always pass. }
procedure TArm64Tests.TestCallArityFence;
var
  Aux: TWasmIrAuxU32;
  Instr: TWasmIrInstr;
  I: Integer;
begin
  { Two aux blocks, each [count, items...]: block 0 holds 2 argument
    registers, block 3 holds 1 destination register. }
  SetLength(Aux, 5);
  Aux[0] := 2;
  Aux[1] := 0;
  Aux[2] := 1;
  Aux[3] := 1;
  Aux[4] := 2;

  FillChar(Instr, SizeOf(Instr), 0);
  Instr.Op := iroCall;
  Instr.A := 0;
  Instr.B := 3;
  Expect<Boolean>(Arm64CanEmitInstr(Instr, Aux)).ToBe(True);

  Instr.Op := iroI32Add;
  Expect<Boolean>(Arm64CanEmitInstr(Instr, Aux)).ToBe(True);

  { An argument block one past the cap declines. }
  SetLength(Aux, ARM64_MAX_CALL_SLOTS + 2);
  Aux[0] := ARM64_MAX_CALL_SLOTS + 1;
  for I := 1 to ARM64_MAX_CALL_SLOTS + 1 do
    Aux[I] := 0;
  Instr.Op := iroReturnCall;
  Instr.A := 0;
  Expect<Boolean>(Arm64CanEmitInstr(Instr, Aux)).ToBe(False);
end;

{ The branch-displacement range guard (jit-spec §4.3). Arm64ResolvePatches masks
  the scaled offset Imm = byteDelta div 4 into imm26 (B) or imm19 (B.cond / CBZ /
  CBNZ) and raises EWasmJitBranchRange when it does not fit, so an over-large
  function is transparently interpreted rather than silently mis-encoded.
  Building a >1 MiB function to exercise the raise is impractical in a unit test
  (jit-spec §11.4), so the range predicate itself is asserted at its exact
  two's-complement boundaries — the load-bearing logic the resolver keys on. }
procedure TArm64Tests.TestBranchOffsetRangeGuard;
begin
  { imm19 (conditional branches): signed 19-bit, [-262144, 262143]. }
  Expect<Boolean>(Arm64SignedImmFits(262143, 19)).ToBe(True);
  Expect<Boolean>(Arm64SignedImmFits(262144, 19)).ToBe(False);
  Expect<Boolean>(Arm64SignedImmFits(-262144, 19)).ToBe(True);
  Expect<Boolean>(Arm64SignedImmFits(-262145, 19)).ToBe(False);

  { imm26 (B): signed 26-bit, [-33554432, 33554431]. }
  Expect<Boolean>(Arm64SignedImmFits(33554431, 26)).ToBe(True);
  Expect<Boolean>(Arm64SignedImmFits(33554432, 26)).ToBe(False);
  Expect<Boolean>(Arm64SignedImmFits(-33554432, 26)).ToBe(True);
  Expect<Boolean>(Arm64SignedImmFits(-33554433, 26)).ToBe(False);

  { Zero (a same-site displacement) fits every field; the common in-range case. }
  Expect<Boolean>(Arm64SignedImmFits(0, 19)).ToBe(True);
  Expect<Boolean>(Arm64SignedImmFits(0, 26)).ToBe(True);
end;

{ --- position-independent emission (aot-spec §1.2/§1.3) ------------------

  The helper calls and the IR-instruction pointer must be table-indexed /
  register-relative, NOT baked absolutes — that is what makes the code
  relocatable for the AOT tier. Assert the exact words each emits against the
  pure builders, so a regression to a baked movz/movk quad is caught here. }
function EmittedWord(const ABuf: TWasmCodeBuffer; const AIndex: Integer): UInt32;
begin
  Result := UInt32(ABuf.ByteAt(AIndex * 4))
    or (UInt32(ABuf.ByteAt(AIndex * 4 + 1)) shl 8)
    or (UInt32(ABuf.ByteAt(AIndex * 4 + 2)) shl 16)
    or (UInt32(ABuf.ByteAt(AIndex * 4 + 3)) shl 24);
end;

procedure TArm64Tests.TestPositionIndependentSequences;
var
  Buf: TWasmCodeBuffer;
begin
  { PinHelperTable: ldr x24,[x20,#off] — a single indexed load off the pinned
    store, no baked address. }
  Buf := TWasmCodeBuffer.Create;
  try
    Arm64EmitPinHelperTable(Buf, 16);
    Expect<UInt32>(EmittedWord(Buf, 0))
      .ToBe(Arm64LdrX(ARM64_REG_HELPERTABLE, ARM64_REG_STORE, 16));
  finally
    Buf.Free;
  end;

  { CallHelper: ldr x9,[x24,#k*8]; blr x9 — the code holds only the slot index. }
  Buf := TWasmCodeBuffer.Create;
  try
    Arm64EmitCallHelper(Buf, aohRtDispatch);
    Expect<UInt32>(EmittedWord(Buf, 0)).ToBe(
      Arm64LdrX(ARM64_REG_T0, ARM64_REG_HELPERTABLE,
        UInt32(Ord(aohRtDispatch)) * 8));
    Expect<UInt32>(EmittedWord(Buf, 1)).ToBe(Arm64Blr(ARM64_REG_T0));
  finally
    Buf.Free;
  end;

  { IrInsPtr: add x2,x23,#(i*stride) — computed from the pinned IR base, no baked
    heap pointer. Index 3 stays within ADD's imm12 range. }
  Buf := TWasmCodeBuffer.Create;
  try
    Arm64EmitIrInsPtr(Buf, 2, 3);
    Expect<UInt32>(EmittedWord(Buf, 0)).ToBe(
      Arm64AddImmX(2, ARM64_REG_IRBASE, 3 * UInt32(SizeOf(TWasmIrInstr))));
  finally
    Buf.Free;
  end;
end;

{ --- executable proof (aarch64) -----------------------------------------

  Each exec test emits: prologue (saves callee-saved, x19 := x0 = base),
  the op template(s), then the epilogue (restores, ret). No epoch capture is
  emitted, so x20/x21/x22 are unused and the store argument is irrelevant. }

{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
procedure RunOne(const AIns: TWasmIrInstr; var ASlots: array of UInt64);
var
  Buf: TWasmCodeBuffer;
  Fn: TWasmSlotFn;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Arm64EmitPrologue(Buf);
    { Inline templates use neither the helper table nor the IR base, so the exec
      harness skips PinHelperTable and passes index 0 — the prologue's x23/x24
      saves and `mov x23,x2` are harmless with a one-argument call. }
    Arm64EmitOp(Buf, AIns, nil, 0);
    Arm64EmitEpilogue(Buf);
    Buf.MakeExecutable;
    Fn := TWasmSlotFn(Buf.EntryPoint);
    Fn(@ASlots[0]);
  finally
    Buf.Free;
  end;
end;
{$ENDIF}

procedure TArm64Tests.TestExecAddTemplate;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Slots: array[0 .. 5] of UInt64;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  Slots[0] := 17;
  Slots[1] := 25;
  Slots[2] := $DEADBEEF;
  RunOne(Ins(iroI32Add, 2, 0, 1), Slots);
  Expect<UInt64>(Slots[2]).ToBe(42);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.TestExecAddWraps;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Slots: array[0 .. 5] of UInt64;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  { 0xFFFFFFFF + 1 wraps to 0 in 32 bits and the 64-bit store leaves the high
    half clear (the widening-store identity, §13 item 7). High garbage in the
    operands proves the W-form ignores it. }
  Slots[0] := (UInt64($AAAAAAAA) shl 32) or UInt64($FFFFFFFF);
  Slots[1] := (UInt64($BBBBBBBB) shl 32) or UInt64($00000001);
  Slots[2] := High(UInt64);
  RunOne(Ins(iroI32Add, 2, 0, 1), Slots);
  Expect<UInt64>(Slots[2]).ToBe(0);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.TestExecMoveTemplate;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Slots: array[0 .. 5] of UInt64;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  Slots[0] := $1122334455667788;
  Slots[3] := 0;
  RunOne(Ins(iroMove, 3, 0, 0), Slots);
  Expect<UInt64>(Slots[3]).ToBe($1122334455667788);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.TestExecSubTemplate;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Slots: array[0 .. 5] of UInt64;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  Slots[0] := 5;
  Slots[1] := 8;
  Slots[2] := 0;
  RunOne(Ins(iroI32Sub, 2, 0, 1), Slots);
  { 5 - 8 = -3 as i32, high half clear -> 0x00000000FFFFFFFD. }
  Expect<UInt64>(Slots[2]).ToBe(UInt64($FFFFFFFD));
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.TestExecShlMasksCount;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Slots: array[0 .. 5] of UInt64;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  { i32.shl takes the count modulo 32: 1 << 33 == 1 << 1 == 2. }
  Slots[0] := 1;
  Slots[1] := 33;
  Slots[2] := 0;
  RunOne(Ins(iroI32Shl, 2, 0, 1), Slots);
  Expect<UInt64>(Slots[2]).ToBe(2);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.TestExecRelopSigned;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Slots: array[0 .. 5] of UInt64;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  { i32.lt_s(-1, 0) = 1 (signed); the high garbage must be ignored. }
  Slots[0] := UInt64($FFFFFFFF);
  Slots[1] := 0;
  Slots[2] := High(UInt64);
  RunOne(Ins(iroI32LtS, 2, 0, 1), Slots);
  Expect<UInt64>(Slots[2]).ToBe(1);

  { And the false case: lt_s(10, 5) = 0. }
  Slots[0] := 10;
  Slots[1] := 5;
  Slots[2] := High(UInt64);
  RunOne(Ins(iroI32LtS, 2, 0, 1), Slots);
  Expect<UInt64>(Slots[2]).ToBe(0);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.TestExecConst;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Buf: TWasmCodeBuffer;
  Fn: TWasmSlotFn;
  Slots: array[0 .. 5] of UInt64;
  Ci: TWasmIrInstr;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  { i32.const 0xABCD1234 into slot 1: low 32 set, high half clear. }
  Buf := TWasmCodeBuffer.Create;
  try
    Ci.Op := iroI32Const;
    Ci.Dest := 1;
    Ci.A := 0;
    Ci.B := 0;
    Ci.Imm := Int64(Integer($ABCD1234));
    Arm64EmitPrologue(Buf);
    Arm64EmitOp(Buf, Ci, nil, 0);
    Arm64EmitEpilogue(Buf);
    Buf.MakeExecutable;
    Slots[1] := High(UInt64);
    Fn := TWasmSlotFn(Buf.EntryPoint);
    Fn(@Slots[0]);
    Expect<UInt64>(Slots[1]).ToBe(UInt64($ABCD1234));
  finally
    Buf.Free;
  end;
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.TestExecI64Add;
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
var
  Slots: array[0 .. 5] of UInt64;
{$ENDIF}
begin
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  { Full 64-bit add, no truncation. }
  Slots[0] := $00000000FFFFFFFF;
  Slots[1] := $0000000100000001;
  Slots[2] := 0;
  RunOne(Ins(iroI64Add, 2, 0, 1), Slots);
  Expect<UInt64>(Slots[2]).ToBe($0000000200000000);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TArm64Tests.SetupTests;
begin
  Test('word builders emit the asserted A64 bits', TestWordBuilderBits);
  Test('frame save/restore words emit the asserted bits', TestFrameWordBits);
  Test('branch placeholders emit the asserted bits', TestBranchPlaceholderBits);
  Test('slot byte offset is register*8', TestSlotOffset);
  Test('predicate covers waves 2-6 (only EH is declined)',
    TestPredicateCoversWave2);
  Test('the call-site arity fence declines an over-wide call',
    TestCallArityFence);
  Test('branch-offset range guard fits imm19/imm26 at the boundaries',
    TestBranchOffsetRangeGuard);
  Test('helper calls and the IR pointer are position-independent',
    TestPositionIndependentSequences);
  Test('static allocation keeps four expression temporaries',
    TestStaticCacheKeepsFourTemporaries);
  Test('static allocation keeps a shifted expression result',
    TestStaticCacheKeepsShiftResult);
  Test('executes the i32.add template over a register file', TestExecAddTemplate);
  Test('i32.add template wraps at 2^32 and clears the high half',
    TestExecAddWraps);
  Test('executes the move template as a full slot copy', TestExecMoveTemplate);
  Test('executes the i32.sub template', TestExecSubTemplate);
  Test('i32.shl masks the shift count modulo 32', TestExecShlMasksCount);
  Test('executes a signed i32 relop via cmp+cset', TestExecRelopSigned);
  Test('executes an i32.const template', TestExecConst);
  Test('executes a full-width i64.add template', TestExecI64Add);
end;

begin
  TestRunnerProgram.AddSuite(TArm64Tests.Create('Wasm.Jit.Arm64'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
