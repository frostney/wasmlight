{ Unit suite for Wasm.Jit.X64 — the x86-64 (System V AMD64) encoder and op
  templates (.agent/design/jit-spec.md §12.3 Wave 7).

  PRIMARY PROOF ON THIS HOST: PORTABLE byte assertions on the encoder. The
  emitters compute bytes and never execute, so every assertion runs on the
  aarch64 dev host (and every CI leg). Each expected sequence is cited to the
  Intel SDM Vol. 2 (opcode maps, ModRM/SIB/REX, §2.1-2.2). A wrong byte is
  caught here before the x86-64 differential run in the amd64 VM ever runs.

  The EXECUTABLE differential proof (compiled == interpreter across the corpus)
  runs only on a real x86-64 host; those tests are gated on CPUX86_64 and are
  inert here (the co-located Wasm.Jit.Test differential suite drives the real
  decode -> validate -> instantiate -> two-tier pipeline in the VM).

  FPC gotchas (AGENTS.md): every test records at least one assertion; a generic
  Expect<T>(...) is never the lone statement of an `on..do`. }
program Wasm.Jit.X64.Test;

{$I Shared.inc}

{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Ir,
  Wasm.Jit.CodeBuffer,
  Wasm.Jit.X64,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps;

type
  TX64Tests = class(TTestSuite)
  private
    { Assert the whole emitted byte sequence of ABuf against AExpected. }
    procedure CheckSeq(const ABuf: TWasmCodeBuffer;
      const AExpected: array of Byte);
  public
    procedure SetupTests; override;

    procedure TestMovRegReg;
    procedure TestMovImm;
    procedure TestLoadStoreSlots;
    procedure TestAluAddSubImul;
    procedure TestCmpTestShift;
    procedure TestSetccMovzxCmov;
    procedure TestNativeNumericEncodings;
    procedure TestPushPopRsp;
    procedure TestCallRet;
    procedure TestLea;
    procedure TestBranchPlaceholders;
    procedure TestResolvePatchRel32;
    procedure TestPrologueBytes;
    procedure TestEpilogueBytes;
    procedure TestEpochCaptureBytes;
    procedure TestEpochCheckCoreBytes;
    procedure TestNativeSelfCallBytes;
    procedure TestRuntimeCallMarshalBytes;
    procedure TestPositionIndependentSequences;
    procedure TestSlotOffset;
    procedure TestPredicateCoversWaves;
    procedure TestPredicateDeclinesEh;
    procedure TestCallArityFence;
    procedure TestStaticCacheKeepsShiftResult;
    procedure TestGcFieldAccessBytes;
    procedure TestGcArrayAccessBytes;

    procedure TestExecPlaceholder;
  end;

procedure TX64Tests.CheckSeq(const ABuf: TWasmCodeBuffer;
  const AExpected: array of Byte);
var
  I: Integer;
begin
  Expect<Integer>(ABuf.Size).ToBe(Length(AExpected));
  for I := 0 to High(AExpected) do
    if I < ABuf.Size then
      Expect<Byte>(ABuf.ByteAt(I)).ToBe(AExpected[I]);
end;

procedure TX64Tests.TestNativeNumericEncodings;
var
  Buf: TWasmCodeBuffer;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitSignDividend(Buf, True);
    X64EmitDivReg(Buf, True, True, X64_RCX);
    X64EmitMovToXmm(Buf, 0, X64_RAX, False);
    X64EmitScalarFloatBinary(Buf, $58, False, 0, 1);
    X64EmitScalarFloatCompare(Buf, 1, True, 0, 1);
    X64EmitIntToFloat(Buf, True, True, 0, X64_RAX);
    X64EmitFloatWidthConvert(Buf, True, 0, 0);
    X64EmitSignExtendRax(Buf, 8, True);
    X64EmitLoadVec(Buf, 0, 2);
    X64EmitVecBinary(Buf, $DB, 0, 1);
    X64EmitVecDup(Buf, 0, X64_RAX, 1);
    X64EmitVecExtract(Buf, X64_RAX, 0, 0, 15, True);
    X64EmitVecExtract(Buf, X64_RAX, 0, 1, 7, False);
    X64EmitStoreVec(Buf, 0, 4);
    CheckSeq(Buf, [$48, $99, $48, $F7, $F9,
      $66, $0F, $6E, $C0,
      $F3, $0F, $58, $C1,
      $F2, $0F, $C2, $C1, $01,
      $F2, $48, $0F, $2A, $C0,
      $F2, $0F, $5A, $C0,
      $48, $0F, $BE, $C0,
      $F3, $0F, $6F, $43, $10,
      $66, $0F, $DB, $C1,
      $66, $0F, $6E, $C0, $66, $0F, $61, $C0,
      $66, $0F, $70, $C0, $00,
      $66, $0F, $73, $D8, $0F, $66, $0F, $7E, $C0,
      $0F, $BE, $C0,
      $66, $0F, $73, $D8, $0E, $66, $0F, $7E, $C0,
      $0F, $B7, $C0,
      $F3, $0F, $7F, $43, $20]);
  finally
    Buf.Free;
  end;
end;

{ --- register-register / immediate moves (SDM: MOV 89 /r, B8+rd) --------- }

procedure TX64Tests.TestMovRegReg;
var
  Buf: TWasmCodeBuffer;
begin
  { mov rbx, rdi = 48 89 FB ; mov r12, rsi = 49 89 F4 (the prologue's two pins). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitMovRegReg(Buf, X64_RBX, X64_RDI);
    X64EmitMovRegReg(Buf, X64_R12, X64_RSI);
    CheckSeq(Buf, [$48, $89, $FB, $49, $89, $F4]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestMovImm;
var
  Buf: TWasmCodeBuffer;
begin
  { movabs rax, 0x1122334455667788 = 48 B8 88 77 66 55 44 33 22 11. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitMovRegImm64(Buf, X64_RAX, UInt64($1122334455667788));
    CheckSeq(Buf, [$48, $B8, $88, $77, $66, $55, $44, $33, $22, $11]);
  finally
    Buf.Free;
  end;

  { mov edi, 42 = BF 2A 00 00 00 (no REX; zero-extends). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitMovRegImm32(Buf, X64_RDI, 42);
    CheckSeq(Buf, [$BF, $2A, $00, $00, $00]);
  finally
    Buf.Free;
  end;

  { mov r8d, 1 = 41 B8 01 00 00 00 (REX.B for the extended register). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitMovRegImm32(Buf, X64_R8, 1);
    CheckSeq(Buf, [$41, $B8, $01, $00, $00, $00]);
  finally
    Buf.Free;
  end;
end;

{ --- frame-relative slot access (SDM: MOV 8B/89 /r, ModRM disp) ---------- }

procedure TX64Tests.TestLoadStoreSlots;
var
  Buf: TWasmCodeBuffer;
begin
  { mov rax, [rbx+8] = 48 8B 43 08 (slot 1). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitLoadSlot64(Buf, X64_RAX, 1);
    CheckSeq(Buf, [$48, $8B, $43, $08]);
  finally
    Buf.Free;
  end;

  { mov rcx, [rbx] = 48 8B 0B (slot 0, disp0 -> mod00). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitLoadSlot64(Buf, X64_RCX, 0);
    CheckSeq(Buf, [$48, $8B, $0B]);
  finally
    Buf.Free;
  end;

  { mov eax, [rbx+16] = 8B 43 10 (32-bit load, zero-extends; slot 2). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitLoadSlot32(Buf, X64_RAX, 2);
    CheckSeq(Buf, [$8B, $43, $10]);
  finally
    Buf.Free;
  end;

  { mov [rbx+24], rdx = 48 89 53 18 (widened store; slot 3). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitStoreSlot64(Buf, X64_RDX, 3);
    CheckSeq(Buf, [$48, $89, $53, $18]);
  finally
    Buf.Free;
  end;
end;

{ --- ALU (SDM: ADD 01, SUB 29, IMUL 0F AF) ------------------------------ }

procedure TX64Tests.TestAluAddSubImul;
var
  Buf: TWasmCodeBuffer;
begin
  { add eax, ecx = 01 C8 ; add rax, rcx = 48 01 C8. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitAluRegReg(Buf, $01, False, X64_RAX, X64_RCX);
    X64EmitAluRegReg(Buf, $01, True, X64_RAX, X64_RCX);
    CheckSeq(Buf, [$01, $C8, $48, $01, $C8]);
  finally
    Buf.Free;
  end;

  { sub eax, ecx = 29 C8 ; imul eax, ecx = 0F AF C1 ; imul rax,rcx = 48 0F AF C1. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitAluRegReg(Buf, $29, False, X64_RAX, X64_RCX);
    X64EmitImul(Buf, False, X64_RAX, X64_RCX);
    X64EmitImul(Buf, True, X64_RAX, X64_RCX);
    CheckSeq(Buf, [$29, $C8, $0F, $AF, $C1, $48, $0F, $AF, $C1]);
  finally
    Buf.Free;
  end;
end;

{ --- cmp / test / shift-by-CL (SDM: CMP 39, TEST 85, D3 /subop) --------- }

procedure TX64Tests.TestCmpTestShift;
var
  Buf: TWasmCodeBuffer;
begin
  { cmp eax, ecx = 39 C8 ; cmp rax, r14 = 4C 39 F0 ; test eax, eax = 85 C0. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitAluRegReg(Buf, $39, False, X64_RAX, X64_RCX);
    X64EmitAluRegReg(Buf, $39, True, X64_RAX, X64_R14);
    X64EmitAluRegReg(Buf, $85, False, X64_RAX, X64_RAX);
    CheckSeq(Buf, [$39, $C8, $4C, $39, $F0, $85, $C0]);
  finally
    Buf.Free;
  end;

  { shl eax,cl = D3 E0 ; shr eax,cl = D3 E8 ; sar rax,cl = 48 D3 F8 ;
    rol eax,cl = D3 C0 ; ror eax,cl = D3 C8. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitShiftCl(Buf, 4, False, X64_RAX);
    X64EmitShiftCl(Buf, 5, False, X64_RAX);
    X64EmitShiftCl(Buf, 7, True, X64_RAX);
    X64EmitShiftCl(Buf, 0, False, X64_RAX);
    X64EmitShiftCl(Buf, 1, False, X64_RAX);
    CheckSeq(Buf, [$D3, $E0, $D3, $E8, $48, $D3, $F8, $D3, $C0, $D3, $C8]);
  finally
    Buf.Free;
  end;
end;

{ --- setcc / movzx / cmov (SDM: 0F 90+cc, 0F B6, 0F 40+cc) -------------- }

procedure TX64Tests.TestSetccMovzxCmov;
var
  Buf: TWasmCodeBuffer;
begin
  { sete al = 0F 94 C0 ; movzx eax,al = 0F B6 C0 ; cmove rax,rcx = 48 0F 44 C1. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitSetccAl(Buf, X64_CC_E);
    X64EmitMovzxEaxAl(Buf);
    X64EmitCmovcc(Buf, X64_CC_E, True, X64_RAX, X64_RCX);
    CheckSeq(Buf, [$0F, $94, $C0, $0F, $B6, $C0, $48, $0F, $44, $C1]);
  finally
    Buf.Free;
  end;
end;

{ --- push / pop / rsp adjust (SDM: 50+rd, 58+rd, 83 /0|/5) -------------- }

procedure TX64Tests.TestPushPopRsp;
var
  Buf: TWasmCodeBuffer;
begin
  { push rbx = 53 ; push r12 = 41 54 ; pop r14 = 41 5E ; pop rbx = 5B. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPushReg(Buf, X64_RBX);
    X64EmitPushReg(Buf, X64_R12);
    X64EmitPopReg(Buf, X64_R14);
    X64EmitPopReg(Buf, X64_RBX);
    CheckSeq(Buf, [$53, $41, $54, $41, $5E, $5B]);
  finally
    Buf.Free;
  end;

  { sub rsp, 8 = 48 83 EC 08 ; add rsp, 8 = 48 83 C4 08. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitSubRsp(Buf, 8);
    X64EmitAddRsp(Buf, 8);
    CheckSeq(Buf, [$48, $83, $EC, $08, $48, $83, $C4, $08]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestCallRet;
var
  Buf: TWasmCodeBuffer;
begin
  { call rax = FF D0 ; ret = C3. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitCallReg(Buf, X64_RAX);
    X64EmitRet(Buf);
    CheckSeq(Buf, [$FF, $D0, $C3]);
  finally
    Buf.Free;
  end;
end;

{ --- lea (SDM: 8D /r), including the r12/rsp SIB base ------------------- }

procedure TX64Tests.TestLea;
var
  Buf: TWasmCodeBuffer;
begin
  { lea r13, [r12] = 4D 8D 2C 24 (r12 base forces SIB; r13 dest). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitLea(Buf, X64_R13, X64_R12, 0);
    CheckSeq(Buf, [$4D, $8D, $2C, $24]);
  finally
    Buf.Free;
  end;

  { lea rdx, [rsp+16] = 48 8D 54 24 10 (rsp base forces SIB; disp8). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitLea(Buf, X64_RDX, X64_RSP, 16);
    CheckSeq(Buf, [$48, $8D, $54, $24, $10]);
  finally
    Buf.Free;
  end;
end;

{ --- branch placeholders + rel32 patching (SDM: E9 cd, 0F 80+cc cd) ----- }

procedure TX64Tests.TestBranchPlaceholders;
var
  Buf: TWasmCodeBuffer;
begin
  { call rel32 placeholder = E8 00 00 00 00. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;
    X64EmitCallTo(Buf, 0);
    CheckSeq(Buf, [$E8, $00, $00, $00, $00]);
    Expect<Integer>(Buf.PatchCount).ToBe(1);
  finally
    Buf.Free;
  end;

  { jmp rel32 placeholder = E9 00 00 00 00. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;
    X64EmitJmpTo(Buf, 0);
    CheckSeq(Buf, [$E9, $00, $00, $00, $00]);
    Expect<Integer>(Buf.PatchCount).ToBe(1);
  finally
    Buf.Free;
  end;

  { je rel32 placeholder = 0F 84 00 00 00 00. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;
    X64EmitJccTo(Buf, X64_CC_E, 0);
    CheckSeq(Buf, [$0F, $84, $00, $00, $00, $00]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestResolvePatchRel32;
var
  Buf: TWasmCodeBuffer;
  Rel: Integer;
begin
  { A forward jmp whose target label binds 5 bytes past the jmp end must patch
    rel32 = 0. A jmp to a target 3 bytes after the end must patch rel32 = 3.
    Build: label0 at 0; emit a 3-byte filler (ret + 2 nops via bytes), then a
    jmp to a label bound right after it. Simpler: emit jmp to label, bind label
    immediately after -> rel32 = 0 (target - (site+5) = 0). }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;                 { label 0 }
    X64EmitJmpTo(Buf, 0);         { site 0, 5 bytes }
    Buf.BindLabel(0);             { target offset = 5 }
    X64ResolvePatches(Buf);
    { rel32 field is the last 4 bytes; target(5) - site(0) - len(5) = 0. }
    Rel := Integer(Buf.ByteAt(1)) or (Integer(Buf.ByteAt(2)) shl 8)
      or (Integer(Buf.ByteAt(3)) shl 16) or (Integer(Buf.ByteAt(4)) shl 24);
    Expect<Integer>(Rel).ToBe(0);
  finally
    Buf.Free;
  end;
end;

{ --- the Wave-2 frame (jit-spec §5.2/§5.3/§6) --------------------------- }

procedure TX64Tests.TestPrologueBytes;
var
  Buf: TWasmCodeBuffer;
begin
  { The ordinary frame retains its original single alignment/memory slot. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPrologue(Buf);
    CheckSeq(Buf, [$53, $41, $54, $41, $55, $41, $56, $41, $57, $55,
      $48, $83, $EC, $08, $48, $89, $FB, $49, $89, $F4, $48, $89, $D5]);
  finally
    Buf.Free;
  end;

  { Position-independent scalar-call prologue: SIX callee-saved pins pushed
    (rbx, r12-r15, rbp) + context/memory/alignment slots + arg moves and
    context retention.
    push rbx = 53 ; push r12 = 41 54 ; push r13 = 41 55 ; push r14 = 41 56 ;
    push r15 = 41 57 ; push rbp = 55 ; sub rsp,24 = 48 83 EC 18 ;
    mov rbx,rdi = 48 89 FB ; mov r12,rsi = 49 89 F4 ; mov rbp,rdx = 48 89 D5 ;
    mov [rsp+8],rcx = 48 89 4C 24 08. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPrologue(Buf, True);
    CheckSeq(Buf, [$53, $41, $54, $41, $55, $41, $56, $41, $57, $55,
      $48, $83, $EC, $18, $48, $89, $FB, $49, $89, $F4, $48, $89, $D5,
      $48, $89, $4C, $24, $08]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestEpilogueBytes;
var
  Buf: TWasmCodeBuffer;
begin
  { The ordinary frame restores its single alignment/memory slot. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitEpilogue(Buf);
    CheckSeq(Buf, [$48, $83, $C4, $08, $5D, $41, $5F, $41, $5E, $41, $5D,
      $41, $5C, $5B, $C3]);
  finally
    Buf.Free;
  end;

  { add rsp,24; pop rbp; pop r15; pop r14; pop r13; pop r12; pop rbx; ret. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitEpilogue(Buf, True);
    CheckSeq(Buf, [$48, $83, $C4, $18, $5D, $41, $5F, $41, $5E, $41, $5D,
      $41, $5C, $5B, $C3]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestEpochCaptureBytes;
var
  Buf: TWasmCodeBuffer;
begin
  { lea r13, [r12+8]  = 4D 8D 6C 24 08 ; mov r14, [r12+16] = 4D 8B 74 24 10.
    (StoreEpoch=8, StoreEpochSnapshot=16 chosen for the byte assertion.) }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitEpochCapture(Buf, 8, 16);
    CheckSeq(Buf, [$4D, $8D, $6C, $24, $08, $4D, $8B, $74, $24, $10]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestEpochCheckCoreBytes;
var
  Buf: TWasmCodeBuffer;
begin
  { The epoch check's load+compare core (the branch/trap tail patches at
    resolve time): mov rax,[r13] = 49 8B 45 00 ; cmp rax,r14 = 4C 39 F0. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitLoadMem64(Buf, X64_RAX, X64_R13, 0);
    X64EmitAluRegReg(Buf, $39, True, X64_RAX, X64_R14);
    CheckSeq(Buf, [$49, $8B, $45, $00, $4C, $39, $F0]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestNativeSelfCallBytes;
var
  Buf: TWasmCodeBuffer;
begin
  { test r12; je exhausted; r12--; push rbx; 16-byte regfile; rbx:=rsp;
    store r8 parameter; call core; restore; r12++. Both branches are rel32
    placeholders resolved after the complete function is emitted. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;
    Buf.NewLabel;
    X64EmitNativeSelfCall(Buf, 2, 0, 0, 1);
    CheckSeq(Buf, [$4D, $85, $E4, $0F, $84, $00, $00, $00, $00,
      $B8, $01, $00, $00, $00, $49, $29, $C4, $53,
      $48, $83, $EC, $10, $48, $89, $E3, $4C, $89, $03,
      $E8, $00, $00, $00, $00, $48, $83, $C4, $10, $5B,
      $B8, $01, $00, $00, $00, $49, $01, $C4]);
    Expect<Integer>(Buf.PatchCount).ToBe(2);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestRuntimeCallMarshalBytes;
var
  Buf: TWasmCodeBuffer;
begin
  { The store+regbase marshaling every memory/table/ref/global/GC and v128
    helper call emits: mov rdi,r12 = 4C 89 E7 ; mov rsi,rbx = 48 89 DE. (The
    following movabs @instruction / movabs @dispatcher carry runtime addresses,
    not portably byte-assertable; the VM differential run covers them.) }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitMovRegReg(Buf, X64_RDI, X64_R12);
    X64EmitMovRegReg(Buf, X64_RSI, X64_RBX);
    CheckSeq(Buf, [$4C, $89, $E7, $48, $89, $DE]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestPositionIndependentSequences;
var
  Buf: TWasmCodeBuffer;
begin
  { PinHelperTable: mov r15,[r12+off] — one indexed load off the pinned store,
    no baked address (aot-spec §1.2/§4.3). off=16: 4D 8B 7C 24 10. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPinHelperTable(Buf, 16);
    CheckSeq(Buf, [$4D, $8B, $7C, $24, $10]);
  finally
    Buf.Free;
  end;

  { PinMemory: retain the stable instance pointer in the first frame slot. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPinMemory(Buf, 7);
    CheckSeq(Buf, [$4C, $89, $E7, $BE, $07, $00, $00, $00,
      $41, $FF, $57, Byte(Ord(aohResolveMemory) * 8),
      $48, $89, $04, $24]);
  finally
    Buf.Free;
  end;

  { CallHelper: call qword [r15 + k*8] — the code holds only the slot index k.
    k = Ord(aohRtDispatch) = 3, disp = 24: 41 FF 57 18. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitCallHelper(Buf, aohRtDispatch);
    CheckSeq(Buf, [$41, $FF, $57, Byte(Ord(aohRtDispatch) * 8)]);
  finally
    Buf.Free;
  end;

  { IrInsPtr: lea rdx,[rbp + i*stride] — computed from the pinned IR base, no
    baked heap pointer. i=1, stride=SizeOf(TWasmIrInstr): 48 8D 55 <stride>. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitIrInsPtr(Buf, X64_ARG2, 1);
    CheckSeq(Buf, [$48, $8D, $55, Byte(SizeOf(TWasmIrInstr))]);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestStaticCacheKeepsShiftResult;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  I: Integer;
  Found: Boolean;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Const, 2, 0, 0, 7), Aux,
      0, False, False, Cache)).ToBe(True);
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Const, 3, 0, 0, 2), Aux,
      1, False, False, Cache)).ToBe(True);
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Shl, 4, 2, 3, 0), Aux,
      2, False, False, Cache)).ToBe(True);
    Found := False;
    for I := 0 to High(Cache.Entries) do
      Found := Found or (Cache.Entries[I].Valid and
        (Cache.Entries[I].Slot = 4));
    Expect<Boolean>(Found).ToBe(True);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestGcFieldAccessBytes;
var
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;

  function HasSeq(const AExpected: array of Byte): Boolean;
  var
    I, J: Integer;
  begin
    for I := 0 to Buf.Size - Length(AExpected) do
    begin
      Result := True;
      for J := 0 to High(AExpected) do
        if Buf.ByteAt(I + J) <> AExpected[J] then
        begin
          Result := False;
          Break;
        end;
      if Result then
        Exit;
    end;
    Result := False;
  end;

begin
  { get_s i8 at offset 24: direct MOVSX from the baked address, with the null
    trap retained and no generic runtime dispatch call. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64InitRegCache(Cache);
    X64EmitGcFieldAccess(Buf,
      MakeIrInstr(iroStructGetS, 2, 1, 0, 0),
      1 or 2 or (UInt64(1) shl 8) or (UInt64(24) shl 16), Cache);
    X64ResolvePatches(Buf);
    Expect<Boolean>(HasSeq([$48, $8D, $40, $18, $0F, $BE, $00]))
      .ToBe(True);
    Expect<Boolean>(HasSeq([$41, $FF, $57,
      Byte(Ord(aohRtDispatch) * 8)])).ToBe(False);
  finally
    Buf.Free;
  end;

  { struct.set i32 at offset 8 stores the low 32 bits directly. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64InitRegCache(Cache);
    X64EmitGcFieldAccess(Buf,
      MakeIrInstr(iroStructSet, 0, 1, 2, 0),
      1 or (UInt64(4) shl 8) or (UInt64(8) shl 16), Cache);
    X64ResolvePatches(Buf);
    Expect<Boolean>(HasSeq([$48, $8D, $40, $08])).ToBe(True);
    Expect<Boolean>(HasSeq([$89, $08])).ToBe(True);
    Expect<Boolean>(HasSeq([$41, $FF, $57,
      Byte(Ord(aohRtDispatch) * 8)])).ToBe(False);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestGcArrayAccessBytes;
var
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  CanonPos, NullPos, KindPos, BoundsPos: Integer;

  function FindSeq(const AExpected: array of Byte): Integer;
  var
    I, J: Integer;
    Match: Boolean;
  begin
    Result := -1;
    if Buf.Size < Length(AExpected) then
      Exit;
    for I := 0 to Buf.Size - Length(AExpected) do
    begin
      Match := True;
      for J := 0 to High(AExpected) do
        if Buf.ByteAt(I + J) <> AExpected[J] then
        begin
          Match := False;
          Break;
        end;
      if Match then
        Exit(I);
    end;
  end;

  function HasSeq(const AExpected: array of Byte): Boolean;
  begin
    Result := FindSeq(AExpected) >= 0;
  end;

begin
  { array.get_s i8: kind is checked before an unsigned bounds comparison;
    the final address uses the canonicalized i32 index and MOVSX. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64InitRegCache(Cache);
    X64EmitGcArrayAccess(Buf,
      MakeIrInstr(iroArrayGetS, 2, 0, 1, 0), 7,
      1 or 2 or 4 or (UInt64(1) shl 8) or
        (UInt64(WASM_ARRAY_ELEMS_OFFSET) shl 16), Cache);
    X64ResolvePatches(Buf);
    CanonPos := FindSeq([$89, $C9]);
    NullPos := FindSeq([$BF, Byte(Ord(wtkNullArrayReference)), $00, $00, $00,
      $41, $FF, $17]);
    KindPos := FindSeq([$8B, $10, $83, $E2, $1C, $83, $FA, $04]);
    BoundsPos := FindSeq([$8B, $50, $08, $39, $D1, $0F, $82]);
    Expect<Boolean>((CanonPos >= 0) and (CanonPos < NullPos) and
      (NullPos < KindPos) and (KindPos < BoundsPos)).ToBe(True);
    Expect<Boolean>(HasSeq([$48, $8D, $44, $08, $10,
      $0F, $BE, $10])).ToBe(True);
    Expect<Boolean>(HasSeq([$41, $FF, $57,
      Byte(Ord(aohRtDispatch) * 8)])).ToBe(True);
  finally
    Buf.Free;
  end;

  { array.get_u i16 zero-extends from a scale-two element address. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64InitRegCache(Cache);
    X64EmitGcArrayAccess(Buf,
      MakeIrInstr(iroArrayGetU, 2, 0, 1, 0), 8,
      1 or 4 or (UInt64(2) shl 8) or
        (UInt64(WASM_ARRAY_ELEMS_OFFSET) shl 16), Cache);
    X64ResolvePatches(Buf);
    Expect<Boolean>(HasSeq([$48, $8D, $44, $48, $10,
      $0F, $B7, $10])).ToBe(True);
  finally
    Buf.Free;
  end;

  { array.set i8 stores only the source's low byte. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64InitRegCache(Cache);
    X64EmitGcArrayAccess(Buf,
      MakeIrInstr(iroArraySet, 0, 1, 2, 0), 9,
      1 or 4 or (UInt64(1) shl 8) or
        (UInt64(WASM_ARRAY_ELEMS_OFFSET) shl 16), Cache);
    X64ResolvePatches(Buf);
    Expect<Boolean>(HasSeq([$48, $8D, $44, $08, $10])).ToBe(True);
    Expect<Boolean>(HasSeq([$88, $10])).ToBe(True);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestSlotOffset;
begin
  Expect<UInt32>(X64SlotByteOffset(0)).ToBe(0);
  Expect<UInt32>(X64SlotByteOffset(5)).ToBe(40);
end;

{ --- compile predicate (the scope fence, §10.3) ------------------------- }

procedure TX64Tests.TestPredicateCoversWaves;
begin
  { Representative ops from every wave must be compilable (only EH is declined,
    like the aarch64 backend). }
  Expect<Boolean>(X64CanEmitOp(iroI32Add)).ToBe(True);       { Wave 2 inline }
  Expect<Boolean>(X64CanEmitOp(iroI32Clz)).ToBe(True);       { leaf on x86-64 }
  Expect<Boolean>(X64CanEmitOp(iroF64Add)).ToBe(True);       { Wave 2 leaf }
  Expect<Boolean>(X64CanEmitOp(iroCall)).ToBe(True);         { Wave 3 }
  Expect<Boolean>(X64CanEmitOp(iroReturnCall)).ToBe(True);
  Expect<Boolean>(X64CanEmitOp(iroI32Load)).ToBe(True);      { Wave 4 }
  Expect<Boolean>(X64CanEmitOp(iroStructNew)).ToBe(True);    { Wave 5 }
  Expect<Boolean>(X64CanEmitOp(iroV128Load)).ToBe(True);     { Wave 6 }
  Expect<Boolean>(X64CanEmitOp(iroI32x4Add)).ToBe(True);
  Expect<Boolean>(X64CanEmitOp(iroArrayFillVec)).ToBe(True); { last vec op }
end;

procedure TX64Tests.TestPredicateDeclinesEh;
begin
  { Exception-handling ops are never compiled (§8.3, §10.2). }
  Expect<Boolean>(X64CanEmitOp(iroThrow)).ToBe(False);
  Expect<Boolean>(X64CanEmitOp(iroThrowRef)).ToBe(False);
end;

procedure TX64Tests.TestCallArityFence;
var
  Ins: TWasmIrInstr;
  Aux: TWasmIrAuxU32;
  I: Integer;
begin
  { Call-site arity is not a decline. An empty aux and an argument block one
    past the historical short-form cap both compile. }
  Ins.Op := iroCall;
  Ins.Dest := 0;
  Ins.A := 0;
  Ins.B := 0;
  Ins.Imm := 0;
  Aux := nil;
  Expect<Boolean>(X64CanEmitInstr(Ins, Aux)).ToBe(True);

  SetLength(Aux, X64_MAX_CALL_SLOTS + 2);
  Aux[0] := X64_MAX_CALL_SLOTS + 1;
  for I := 1 to X64_MAX_CALL_SLOTS + 1 do
    Aux[I] := 0;
  Ins.Op := iroReturnCall;
  Expect<Boolean>(X64CanEmitInstr(Ins, Aux)).ToBe(True);
end;

procedure TX64Tests.TestExecPlaceholder;
begin
  { Executable proof runs only on a real x86-64 host (the amd64 VM differential
    run via Wasm.Jit.Test + wasmspec --tier=jit). Inert here on aarch64. }
  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUX86_64)}
  Expect<Boolean>(JitExecMemSupported).ToBe(True);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TX64Tests.SetupTests;
begin
  Test('mov reg,reg emits the asserted bytes', TestMovRegReg);
  Test('mov reg,imm (movabs / imm32) emits the asserted bytes', TestMovImm);
  Test('frame-relative slot load/store emit the asserted bytes',
    TestLoadStoreSlots);
  Test('add/sub/imul emit the asserted bytes', TestAluAddSubImul);
  Test('cmp/test/shift-by-cl emit the asserted bytes', TestCmpTestShift);
  Test('setcc/movzx/cmov emit the asserted bytes', TestSetccMovzxCmov);
  Test('native numeric instructions emit the asserted bytes',
    TestNativeNumericEncodings);
  Test('push/pop/rsp-adjust emit the asserted bytes', TestPushPopRsp);
  Test('call reg / ret emit the asserted bytes', TestCallRet);
  Test('lea with SIB base emits the asserted bytes', TestLea);
  Test('jmp/jcc rel32 placeholders emit the asserted bytes',
    TestBranchPlaceholders);
  Test('rel32 patch resolves to target - site - instrlen',
    TestResolvePatchRel32);
  Test('the prologue emits the asserted byte sequence', TestPrologueBytes);
  Test('the epilogue emits the asserted byte sequence', TestEpilogueBytes);
  Test('the epoch capture emits the asserted bytes', TestEpochCaptureBytes);
  Test('the epoch-check load+compare core emits the asserted bytes',
    TestEpochCheckCoreBytes);
  Test('the native self-call frame emits the asserted bytes',
    TestNativeSelfCallBytes);
  Test('the runtime/vec helper-call marshaling emits the asserted bytes',
    TestRuntimeCallMarshalBytes);
  Test('helper calls and the IR pointer are position-independent',
    TestPositionIndependentSequences);
  Test('slot byte offset is register*8', TestSlotOffset);
  Test('predicate covers waves 2-6 (only EH is declined)',
    TestPredicateCoversWaves);
  Test('predicate declines exception-handling ops', TestPredicateDeclinesEh);
  Test('the call-site arity predicate admits an over-wide call',
    TestCallArityFence);
  Test('static allocation keeps a shifted expression result',
    TestStaticCacheKeepsShiftResult);
  Test('numeric GC fields use baked native x64 loads and stores',
    TestGcFieldAccessBytes);
  Test('fixed scalar arrays use native x64 loads and stores',
    TestGcArrayAccessBytes);
  Test('executable proof is gated to a real x86-64 host', TestExecPlaceholder);
end;

begin
  TestRunnerProgram.AddSuite(TX64Tests.Create('Wasm.Jit.X64'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
