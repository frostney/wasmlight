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
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit.CodeBuffer,
  Wasm.Jit.X64,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps;

type
  TX64Tests = class(TTestSuite)
  private
    { Assert the whole emitted byte sequence of ABuf against AExpected. }
    procedure CheckSeq(const ABuf: TWasmCodeBuffer;
      const AExpected: array of Byte);
    { The first offset >= AFrom where AExpected occurs in ABuf, or -1. }
    function FindSeq(const ABuf: TWasmCodeBuffer;
      const AExpected: array of Byte; const AFrom: Integer = 0): Integer;
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
    procedure TestNopForms;
    procedure TestAlignCode;
    procedure TestEpochBackEdgeBytes;
    procedure TestPrologueBytes;
    procedure TestEpilogueBytes;
    procedure TestEpochCaptureBytes;
    procedure TestEpochCheckCoreBytes;
    procedure TestNativeSelfCallBytes;
    procedure TestNativeCoreWriteBack;
    procedure TestNativeLeafCallStaticMoves;
    procedure TestNativeLeafCallPlans;
    procedure TestNativeLeafMemoryCore;
    procedure TestRuntimeCallMarshalBytes;
    procedure TestPositionIndependentSequences;
    procedure TestSlotOffset;
    procedure TestPredicateCoversWaves;
    procedure TestPredicateEmitsEh;
    procedure TestEveryIrOpHasTemplate;
    procedure TestStaticCacheKeepsShiftResult;
    procedure TestStaticCacheDefersDynamicStores;
    procedure TestStaticCachePinnedMemoryBytes;
    procedure TestStaticCacheFourFixedHosts;
    procedure TestStaticCacheAddressZeroExtension;
    procedure TestStaticCacheLoadAluFusion;
    procedure TestScaledIndexEncodings;
    procedure TestScaledIndexPinnedAccess;
    procedure TestDirectOperandEncodings;
    procedure TestDirectOperandCachedOps;
    procedure TestDirectOperandBookkeeping;
    procedure TestImmediateEncodings;
    procedure TestImmediateCachedOps;
    procedure TestGcFieldAccessBytes;
    procedure TestGcArrayAccessBytes;
    procedure TestVecCacheEncodings;
    procedure TestVecCacheLoopBody;
    procedure TestVecCacheOperandHazards;
    procedure TestVecCacheExtractAndSplat;

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

function TX64Tests.FindSeq(const ABuf: TWasmCodeBuffer;
  const AExpected: array of Byte; const AFrom: Integer): Integer;
var
  I, J: Integer;
  Hit: Boolean;
begin
  for I := AFrom to ABuf.Size - Length(AExpected) do
  begin
    Hit := True;
    for J := 0 to High(AExpected) do
      if ABuf.ByteAt(I + J) <> AExpected[J] then
      begin
        Hit := False;
        Break;
      end;
    if Hit then
      Exit(I);
  end;
  Result := -1;
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

procedure TX64Tests.TestNopForms;
const
  { SDM Vol. 2 "NOP": the recommended multi-byte sequences. }
  Forms: array[1..9] of array[0..8] of Byte = (
    ($90, 0, 0, 0, 0, 0, 0, 0, 0),
    ($66, $90, 0, 0, 0, 0, 0, 0, 0),
    ($0F, $1F, $00, 0, 0, 0, 0, 0, 0),
    ($0F, $1F, $40, $00, 0, 0, 0, 0, 0),
    ($0F, $1F, $44, $00, $00, 0, 0, 0, 0),
    ($66, $0F, $1F, $44, $00, $00, 0, 0, 0),
    ($0F, $1F, $80, $00, $00, $00, $00, 0, 0),
    ($0F, $1F, $84, $00, $00, $00, $00, $00, 0),
    ($66, $0F, $1F, $84, $00, $00, $00, $00, $00));
var
  Buf: TWasmCodeBuffer;
  N, I: Integer;
begin
  for N := 1 to 9 do
  begin
    Buf := TWasmCodeBuffer.Create;
    try
      X64EmitNops(Buf, N);
      Expect<Integer>(Buf.Size).ToBe(N);
      for I := 0 to N - 1 do
        Expect<Byte>(Buf.ByteAt(I)).ToBe(Forms[N][I]);
    finally
      Buf.Free;
    end;
  end;
  { Longer runs are whole 9-byte forms, then one form for the remainder. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitNops(Buf, 20);
    CheckSeq(Buf, [$66, $0F, $1F, $84, $00, $00, $00, $00, $00,
      $66, $0F, $1F, $84, $00, $00, $00, $00, $00,
      $66, $90]);
    X64EmitNops(Buf, 0);
    Expect<Integer>(Buf.Size).ToBe(20);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestAlignCode;
var
  Buf: TWasmCodeBuffer;
  Start, Before, I: Integer;
begin
  { From every start offset in a 64-byte block the loop-head pad lands on
    offset 32 of the next block position, emitting fewer than 64 bytes of
    decodable NOPs (each form starts with 90, 66, or 0F). }
  for Start := 0 to 64 do
  begin
    Buf := TWasmCodeBuffer.Create;
    try
      for I := 1 to Start do
        Buf.EmitByte($CC);
      X64EmitLoopHeadAlign(Buf);
      Expect<Integer>(Buf.CurrentOffset mod X64_LOOP_HEAD_ALIGN)
        .ToBe(X64_LOOP_HEAD_OFFSET);
      Expect<Boolean>(Buf.CurrentOffset - Start < X64_LOOP_HEAD_ALIGN)
        .ToBe(True);
      Expect<Boolean>(Buf.CurrentOffset >= Start).ToBe(True);
      if Buf.CurrentOffset > Start then
        Expect<Boolean>(Buf.ByteAt(Start) in [$90, $66, $0F]).ToBe(True);
      { Already placed: no further padding. }
      Before := Buf.CurrentOffset;
      X64EmitLoopHeadAlign(Buf);
      Expect<Integer>(Buf.CurrentOffset).ToBe(Before);
    finally
      Buf.Free;
    end;
  end;
  { The generic form honours any power-of-two boundary and offset. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitByte($CC);
    X64AlignCode(Buf, 16, 0);
    Expect<Integer>(Buf.CurrentOffset).ToBe(16);
    X64AlignCode(Buf, 32, 8);
    Expect<Integer>(Buf.CurrentOffset).ToBe(40);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestEpochBackEdgeBytes;
var
  Buf: TWasmCodeBuffer;
begin
  { A loop head bound at 0, one body byte, then the back-edge: cmp r14,
    [r13 + 0] (4D 3B 75 00, CMP r64, r/m64; GNU as agrees); je head (0F 84
    rel32, rel32 = 0 - (5 + 6) = -11); mov edi,wtkEpochInterrupt (BF
    imm32); call [r15] (41 FF 17). The only taken branch is the je; the
    trap falls through. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;
    Buf.BindLabel(0);
    Buf.EmitByte($90);
    X64EmitEpochBackEdge(Buf, 0);
    X64ResolvePatches(Buf);
    CheckSeq(Buf, [$90,
      $4D, $3B, $75, $00,
      $0F, $84, $F5, $FF, $FF, $FF,
      $BF, Byte(Ord(wtkEpochInterrupt)), $00, $00, $00,
      $41, $FF, $17]);
  finally
    Buf.Free;
  end;
  { The load form v128-cache loops keep: mov rax,[r13] (49 8B 45 00); cmp
    rax,r14 (4C 39 F0); je head (rel32 = 0 - (8 + 6) = -14). }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;
    Buf.BindLabel(0);
    Buf.EmitByte($90);
    X64EmitEpochBackEdge(Buf, 0, True);
    X64ResolvePatches(Buf);
    CheckSeq(Buf, [$90,
      $49, $8B, $45, $00,
      $4C, $39, $F0,
      $0F, $84, $F2, $FF, $FF, $FF,
      $BF, Byte(Ord(wtkEpochInterrupt)), $00, $00, $00,
      $41, $FF, $17]);
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
  { sub r12, 1; jb exhausted (the borrow is exactly the old zero test);
    a 16-byte regfile + 8 frame; rbx:=rsp; call core (the r8 parameter
    stays unstored); release; lea rbx, [rsp+8] (no push/pop); add r12, 1.
    Both branches are rel32 placeholders resolved after the complete
    function is emitted. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.NewLabel;
    Buf.NewLabel;
    X64EmitNativeSelfCall(Buf, 2, 0, 0, 1);
    CheckSeq(Buf, [$49, $83, $EC, $01, $0F, $82, $00, $00, $00, $00,
      $48, $83, $EC, $18, $48, $89, $E3,
      $E8, $00, $00, $00, $00, $48, $83, $C4, $18,
      $48, $8D, $5C, $24, $08, $49, $83, $C4, $01]);
    Expect<Integer>(Buf.PatchCount).ToBe(2);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestNativeCoreWriteBack;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0 .. 7] of UInt32;
  Visible: array[0 .. 7] of Boolean;
  Start: Integer;

  procedure Emit(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32;
    const AImm: Int64 = 0);
  begin
    { A native self core over an 8-slot frame: parameter slot 0, core label
      0, exhaustion label 1, result source slot 5. }
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(AOp, ADest, AA, AB, AImm), Aux, 0, False, False, True,
      True, 8, 0, 5, 0, 1, False, False, Cache, nil, nil, nil)).ToBe(True);
  end;

  procedure Setup;
  begin
    FillChar(UseCounts, SizeOf(UseCounts), 0);
    FillChar(Visible, SizeOf(Visible), 0);
    Visible[0] := True;
    Buf := TWasmCodeBuffer.Create;
    Buf.NewLabel;
    Buf.NewLabel;
    Buf.NewLabel;
    X64SeedNativeCoreCache(Cache, 1, 0, 0, True);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
  end;

  procedure CheckFrom(const AExpected: array of Byte);
  var
    I: Integer;
  begin
    Expect<Integer>(Buf.Size - Start).ToBe(Length(AExpected));
    for I := 0 to High(AExpected) do
      if Start + I < Buf.Size then
        Expect<Byte>(Buf.ByteAt(Start + I)).ToBe(AExpected[I]);
  end;

begin
  { Aux block 0 = the call's argument (slot 2), block 2 = its result
    (slot 3). }
  SetLength(Aux, 4);
  Aux[0] := 1;
  Aux[1] := 2;
  Aux[2] := 1;
  Aux[3] := 3;

  { The parameter arrives unstored in r8. Writing it stays in r8 (dirty); a
    dead temporary is never stored; the self call stores exactly the
    parameter (a local its frame reads after the call), passes the argument
    in r8, and adopts the r8 result into a dynamic host:
      add r8d, r8d ; mov r10d, 1 ;
      mov r11, r8 ; sub r11d, r10d ;               (argument, slot 2)
      mov [rbx], r8 ; mov r8, r11 ;                (write-back, argument)
      sub r12, 1 ; jb exh ; sub rsp, 72 ; mov rbx, rsp ;
      call core ; add rsp, 72 ; lea rbx, [rsp+8] ; add r12, 1 ;
      mov r10, r8                                  (result, slot 3) }
  Setup;
  try
    UseCounts[0] := 2;
    UseCounts[1] := 1;
    UseCounts[2] := 1;
    UseCounts[3] := 1;
    Start := Buf.Size;
    Emit(iroI32Add, 0, 0, 0);
    Emit(iroI32Const, 1, 0, 0, 1);
    Emit(iroI32Sub, 2, 0, 1);
    Emit(iroCall, 0, 0, 2);
    CheckFrom([$45, $01, $C0, $41, $BA, $01, $00, $00, $00,
      $4D, $89, $C3, $45, $29, $D3,
      $4C, $89, $03, $4D, $89, $D8,
      $49, $83, $EC, $01, $0F, $82, $00, $00, $00, $00,
      $48, $83, $EC, $48, $48, $89, $E3,
      $E8, $00, $00, $00, $00, $48, $83, $C4, $48,
      $48, $8D, $5C, $24, $08, $49, $83, $C4, $01, $4D, $89, $C2]);
    { r8 now holds the callee's result: the parameter host is
      non-resident until a read or a canonical point reloads it. }
    Expect<Boolean>(Cache.Entries[0].Valid).ToBe(False);
    Expect<Boolean>(Cache.Entries[2].Valid and (Cache.Entries[2].Slot = 3) and
      Cache.Entries[2].Dirty).ToBe(True);

    { A later read reloads the parameter into its own host from the slot
      the call left canonical: mov r8, [rbx] ; add r10d, r8d. }
    Start := Buf.Size;
    Emit(iroI32Add, 3, 3, 0);
    CheckFrom([$4C, $8B, $03, $45, $01, $C2]);
    Expect<Boolean>(Cache.Entries[0].Valid and not Cache.Entries[0].Dirty)
      .ToBe(True);
  finally
    Buf.Free;
  end;

  { A branch right after the call is a canonical point: the dirty live
    result is stored and the parameter host reloaded before the jump, so
    every join sees it resident:
      test r10d, r10d ; mov [rbx+24], r10 ; mov r8, [rbx] ; jne rel32. }
  Setup;
  try
    UseCounts[0] := 1;
    UseCounts[2] := 1;
    UseCounts[3] := 2;
    Emit(iroMove, 2, 0, 0);
    Emit(iroCall, 0, 0, 2);
    Start := Buf.Size;
    Emit(iroBranchIf, 0, 3, 2);
    CheckFrom([$45, $85, $D2, $4C, $89, $53, $18, $4C, $8B, $03,
      $0F, $85, $00, $00, $00, $00]);
    Expect<Boolean>(Cache.Entries[0].Valid and Cache.Entries[0].Dirty)
      .ToBe(True);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestNativeLeafCallStaticMoves;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0 .. 7] of UInt32;
  Visible: array[0 .. 7] of Boolean;

  { Emit a static-allocation direct call to a native leaf with arguments
    AArg0/AArg1 and result ARes (statics: slot 0 in r8, slot 1 in r9) and
    return the bytes around the call: APre before `xor ecx, ecx ; call rdx`,
    APost after it up to the cold-path jump. }
  procedure EmitCall(const AArg0, AArg1, ARes: UInt32;
    out APre, APost: TWasmBytes);
  var
    I, Site, Jmp: Integer;
  begin
    SetLength(Aux, 5);
    Aux[0] := 2;
    Aux[1] := AArg0;
    Aux[2] := AArg1;
    Aux[3] := 1;
    Aux[4] := ARes;
    FillChar(UseCounts, SizeOf(UseCounts), 0);
    FillChar(Visible, SizeOf(Visible), 0);
    Visible[0] := True;
    Visible[1] := True;
    Buf := TWasmCodeBuffer.Create;
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroCall, 0, 0, 3, 1),
      Aux, 0, False, False, False, False, 0, 0, 0, 0, 0, True, True,
      Cache, nil, nil, nil)).ToBe(True);
    Site := -1;
    for I := 0 to Buf.Size - 4 do
      if (Buf.ByteAt(I) = $31) and (Buf.ByteAt(I + 1) = $C9) and
        (Buf.ByteAt(I + 2) = $FF) and (Buf.ByteAt(I + 3) = $D2) then
        Site := I;
    Expect<Boolean>(Site > 12).ToBe(True);
    Jmp := Site + 4;
    while (Jmp < Buf.Size) and (Buf.ByteAt(Jmp) <> $E9) do
      Inc(Jmp);
    SetLength(APre, 9);
    for I := 0 to 8 do
      APre[I] := Buf.ByteAt(Site - 9 + I);
    SetLength(APost, Jmp - Site - 4);
    for I := 0 to High(APost) do
      APost[I] := Buf.ByteAt(Site + 4 + I);
    Buf.Free;
  end;

  procedure CheckBytes(const AActual: TWasmBytes;
    const AExpected: array of Byte; const AFrom: Integer);
  var
    I: Integer;
  begin
    Expect<Integer>(Length(AActual) - AFrom).ToBe(Length(AExpected));
    for I := 0 to High(AExpected) do
      if AFrom + I < Length(AActual) then
        Expect<Byte>(AActual[AFrom + I]).ToBe(AExpected[I]);
  end;

var
  Pre, Post: TWasmBytes;
begin
  { Swapped statics: the parallel move parks r8 in rcx (rax is free for the
    entry): mov rcx, r8 ; mov r8, r9 ; mov r9, rcx. The result (slot 2) is
    adopted from r8 into r10 before both statics reload: mov r10, r8 ;
    mov r8, [rbx] ; mov r9, [rbx+8]. }
  EmitCall(1, 0, 2, Pre, Post);
  CheckBytes(Pre, [$4C, $89, $C1, $4D, $89, $C8, $49, $89, $C9], 0);
  CheckBytes(Post, [$4D, $89, $C2, $4C, $8B, $03, $4C, $8B, $4B, $08], 0);

  { r8 is the second argument's source: r9 is filled first (mov r9, r8)
    and then r8 from the first argument's slot 3 (not resident):
    mov r8, [rbx+24]. A result into static slot 1 moves into r9 and only
    r8 reloads: mov r9, r8 ; mov r8, [rbx]. }
  EmitCall(3, 0, 1, Pre, Post);
  CheckBytes(Pre, [$4D, $89, $C1, $4C, $8B, $43, $18], 2);
  CheckBytes(Post, [$4D, $89, $C1, $4C, $8B, $03], 0);

  { The same static twice: r8 already holds argument 0 (no move), then
    mov r9, r8. A result into static slot 0 stays in r8 and only r9
    reloads: mov r9, [rbx+8]. }
  EmitCall(0, 0, 0, Pre, Post);
  CheckBytes(Pre, [$4D, $89, $C1], 6);
  CheckBytes(Post, [$4C, $8B, $4B, $08], 0);
end;

procedure TX64Tests.TestNativeLeafCallPlans;
const
  { mov [rbx + 8k], host for the statics r8, r9, rdi, rdx. }
  STORE_REX: array[0 .. 3] of Byte = ($4C, $4C, $48, $48);
  STORE_MODRM: array[0 .. 3] of Byte = ($03, $4B, $7B, $53);
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  Plan: TX64LeafCall;
  UseCounts: array[0 .. 15] of UInt32;
  Visible: array[0 .. 15] of Boolean;
  Layout: TWasmMemoryInst;
  BaseOff: Byte;
  I, Site: Integer;

  procedure Setup(const AArgs: array of UInt32; const AResult: UInt32);
  var
    N: Integer;
  begin
    SetLength(Aux, Length(AArgs) + 3);
    Aux[0] := Length(AArgs);
    for N := 0 to High(AArgs) do
      Aux[N + 1] := AArgs[N];
    Aux[Length(AArgs) + 1] := 1;
    Aux[Length(AArgs) + 2] := AResult;
    FillChar(UseCounts, SizeOf(UseCounts), 0);
    FillChar(Visible, SizeOf(Visible), 0);
    for N := 0 to 3 do
      Visible[N] := True;
    FillChar(Plan, SizeOf(Plan), 0);
    Plan.Enabled := True;
    Plan.ParamCount := Length(AArgs);
    for N := 0 to 3 do
      Plan.ArgSlots[N] := High(UInt32);
    Plan.ResultSlot := High(UInt32);
    Buf := TWasmCodeBuffer.Create;
    { Statics: slot 0 in r8, 1 in r9, 2 in rdi, 3 in rdx. The activation
      caches the leaf's entry, so the call site loads it into rax and the
      hot path clobbers only what the leaf itself does. }
    X64EnableStaticRegCache(Buf, Cache, [0, 1, 2, 3]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 16);
    X64EnableLeafEntryCache(Cache, 0);
  end;

  procedure Emit;
  begin
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroCall, 0, 0, UInt32(Aux[0]) + 1, 0), Aux, 0, False,
      False, False, False, 0, 0, 0, 0, 0, True, True, Cache, nil, nil, nil,
      @Plan)).ToBe(True);
    { The fast path's call: xor ecx, ecx ; call rax. }
    Site := FindSeq(Buf, [$31, $C9, $FF, $D0]);
    Expect<Boolean>(Site > 0).ToBe(True);
  end;

  procedure CheckBefore(const AExpected: array of Byte);
  var
    N: Integer;
  begin
    for N := 0 to High(AExpected) do
      if Site - Length(AExpected) + N >= 0 then
        Expect<Byte>(Buf.ByteAt(Site - Length(AExpected) + N))
          .ToBe(AExpected[N]);
  end;

  procedure CheckAfter(const AExpected: array of Byte);
  var
    N: Integer;
  begin
    for N := 0 to High(AExpected) do
      Expect<Byte>(Buf.ByteAt(Site + 4 + N)).ToBe(AExpected[N]);
  end;

begin
  { A four-argument rotation of the statics, (r9, rdi, rdx, r8) -> (r8, r9,
    rdi, rdx), is one cycle: rcx parks r8 (rax holds the entry):
      mov rcx, r8 ; mov r8, r9 ; mov r9, rdi ; mov rdi, rdx ; mov rdx, rcx.
    A four-parameter leaf writes all four hosts. Each static (a visible
    local) was just written, so it is stored before the call, and reloads
    after it; the result (slot 4) is adopted from r8 into r10 first:
      mov r10, r8 ; mov r8, [rbx] ; mov r9, [rbx+8] ; mov rdi, [rbx+16] ;
      mov rdx, [rbx+24]. }
  Setup([1, 2, 3, 0], 4);
  Plan.ClobbersRdi := True;
  Plan.ClobbersRdx := True;
  for I := 0 to 3 do
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Const, UInt32(I), 0, 0, I + 40), Aux, 0, False,
      False, Cache)).ToBe(True);
  Emit;
  CheckBefore([$4C, $89, $C1, $4D, $89, $C8, $49, $89, $F9, $48, $89, $D7,
    $48, $89, $CA]);
  CheckAfter([$4D, $89, $C2, $4C, $8B, $03, $4C, $8B, $4B, $08, $48, $8B,
    $7B, $10, $48, $8B, $53, $18]);
  for I := 0 to 3 do
    Expect<Boolean>(FindSeq(Buf, [STORE_REX[I], $89, STORE_MODRM[I]]) >= 0)
      .ToBe(True);
  Buf.Free;

  { A two-parameter leaf leaves rdi and rdx alone: they are neither stored
    nor reloaded on the hot path, the arguments read them directly
    (mov r8, rdx ; mov r9, rdi), and the result forwarded into static slot 1
    replaces its reload (mov r9, r8 ; mov r8, [rbx]). r8's slot is current
    (the statics were only loaded), so it is reloaded but never stored. }
  Setup([3, 2], 5);
  Plan.ResultSlot := 1;
  Emit;
  CheckBefore([$49, $89, $D0, $49, $89, $F9]);
  CheckAfter([$4D, $89, $C1, $4C, $8B, $03, $E9]);
  Expect<Integer>(FindSeq(Buf, [$48, $89, $7B, $10])).ToBe(
    FindSeq(Buf, [$48, $89, $7B, $10], Site));
  Expect<Integer>(FindSeq(Buf, [$4C, $89, $03])).ToBe(-1);
  Buf.Free;

  { Constant arguments go straight into their registers, each in its
    shortest exact form, and a memory leaf called from a frame that does
    not hold Base gets it from the pinned instance:
      mov r8d, 1 ; xor r9d, r9d ; movabs rdi, 0x100000000 ;
      mov rsi, [rsp] ; mov rsi, [rsi + Base]. }
  Setup([8, 9, 10], 6);
  Plan.UsesMemory := True;
  Plan.ClobbersRdi := True;
  Plan.ArgConst[0] := True;
  Plan.ArgValues[0] := 1;
  Plan.ArgConst[1] := True;
  Plan.ArgValues[1] := 0;
  Plan.ArgConst[2] := True;
  Plan.ArgValues[2] := UInt64($100000000);
  Emit;
  BaseOff := Byte(PtrUInt(@Layout.Base) - PtrUInt(@Layout));
  if BaseOff = 0 then
    CheckBefore([$41, $B8, $01, 0, 0, 0, $45, $31, $C9, $48, $BF, 0, 0, 0,
      0, 1, 0, 0, 0, $48, $8B, $34, $24, $48, $8B, $36])
  else
    CheckBefore([$41, $B8, $01, 0, 0, 0, $45, $31, $C9, $48, $BF, 0, 0, 0,
      0, 1, 0, 0, 0, $48, $8B, $34, $24, $48, $8B, $76, BaseOff]);
  Buf.Free;
end;

procedure TX64Tests.TestNativeLeafMemoryCore;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0 .. 15] of UInt32;
  Visible: array[0 .. 15] of Boolean;

  procedure Emit(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32);
  begin
    Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(AOp, ADest, AA, AB, 0),
      Aux, 0, False, True, True, False, 16, 0, 9, 0, 1, False, False, Cache,
      nil, nil, nil)).ToBe(True);
  end;

begin
  SetLength(Aux, 0);
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  UseCounts[5] := 1;
  UseCounts[6] := 1;
  UseCounts[7] := 1;
  Buf := TWasmCodeBuffer.Create;
  try
    { A four-parameter leaf: slots 0-3 arrive in r8, r9, rdi, rdx; memory
      accesses read Base from rsi. }
    X64SeedNativeCoreCache(Cache, 4, 0, 1, False, 2, 3);
    X64EnablePinnedMemoryBase(Cache);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 16);
    { i64.load r5 <- [r2]: the parameter's upper half is not known zero, so
      the index is copied by a 32-bit move: mov ecx, edi ;
      mov r10, [rsi + rcx]. }
    Emit(iroI64Load, 5, 2, 0);
    { i64.extend_i32_s r6 <- r0: movsxd r11, r8d. }
    Emit(iroI64ExtendI32S, 6, 0, 0);
    { i32.wrap_i64 r7 <- r3 into the dead load's host: mov r10d, edx. }
    UseCounts[5] := 0;
    Emit(iroI32WrapI64, 7, 3, 0);
    { i64.extend_i32_u r8 <- r1: mov r11d, r9d. }
    UseCounts[6] := 0;
    Emit(iroI64ExtendI32U, 8, 1, 0);
    { i32.store [r7] <- r3: r7's host was written by a 32-bit move, so it
      indexes directly: mov [rsi + r10], edx. }
    Emit(iroI32Store, 3, 7, 0);
    CheckSeq(Buf, [$89, $F9, $4C, $8B, $14, $0E, $4D, $63, $D8, $41, $89,
      $D2, $45, $89, $CB, $42, $89, $14, $16]);
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

  { PinMemory: resolve Store.FMemories[Acts[Depth-1].Instance.MemAddrs[7]]
    inline and retain it in the first frame slot. Offsets are the published
    LP64 layout (Wasm.Target): TierContext 168, Depth 56, ActStride 128, Acts
    40, ActInstance 8, MemAddrs 48, MemInstStride 80, FMemories 64. The
    emitter reads the host's live record offsets, which equal that layout on
    every 64-bit host the x64 backend runs on; a 32-bit host's records are
    smaller (the encoder tests still run there), so the literal bytes are
    asserted on 64-bit hosts only. }
  {$IFDEF CPU64}
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPinMemory(Buf, 7);
    CheckSeq(Buf, [
      $49, $8B, $84, $24, $A8, $00, $00, $00,   { mov rax,[r12+168] }
      $48, $8B, $48, $38,                       { mov rcx,[rax+56] }
      $48, $69, $C9, $80, $00, $00, $00,        { imul rcx,rcx,128 }
      $48, $03, $48, $28,                       { add rcx,[rax+40] }
      $48, $8B, $41, $88,                       { mov rax,[rcx-120] }
      $48, $8B, $40, $30,                       { mov rax,[rax+48] }
      $8B, $40, $1C,                            { mov eax,[rax+28] }
      $48, $69, $C0, $50, $00, $00, $00,        { imul rax,rax,80 }
      $49, $03, $44, $24, $40,                  { add rax,[r12+64] }
      $48, $89, $04, $24]);                     { mov [rsp],rax }
  finally
    Buf.Free;
  end;
  {$ENDIF}

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

procedure TX64Tests.TestStaticCacheDefersDynamicStores;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..5] of UInt32;
  Visible: array[0..5] of Boolean;
  BodyEnd: Integer;

  function HasSeq(const AExpected: array of Byte;
    const AFrom: Integer = 0): Boolean;
  var
    I, J: Integer;
  begin
    for I := AFrom to Buf.Size - Length(AExpected) do
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
  { Slots 0/1 are static locals, 5 is the result. Slot 2 has one read, slot 3
    none. Expected stores are MOV [rbx+disp8], r10/r11 (REX 4C, 89 /r,
    ModRM 53/5B) per SDM Vol. 2 MOV and Table 2-2. }
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Visible[0] := True;
  Visible[1] := True;
  Visible[5] := True;
  UseCounts[2] := 1;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 6);
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Const, 2, 0, 0, 7), Aux,
      0, False, False, Cache)).ToBe(True);
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Add, 5, 2, 0, 0), Aux,
      1, False, False, Cache)).ToBe(True);
    { Evicts slot 2 after its only read: a dead temporary is never stored. }
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Const, 3, 0, 0, 9), Aux,
      2, False, False, Cache)).ToBe(True);
    Expect<UInt32>(UseCounts[2]).ToBe(0);
    Expect<Boolean>(HasSeq([$4C, $89, $53, $10])).ToBe(False);
    Expect<Boolean>(HasSeq([$4C, $89, $5B, $28])).ToBe(False);
    BodyEnd := Buf.Size;
    { The flush stores the visible result and skips the unread slot 3. }
    X64FlushDynamicRegCache(Buf, Cache);
    Expect<Integer>(Buf.Size - BodyEnd).ToBe(4);
    Expect<Boolean>(HasSeq([$4C, $89, $5B, $28], BodyEnd)).ToBe(True);
    Expect<Boolean>(HasSeq([$4C, $89, $53, $18])).ToBe(False);
  finally
    Buf.Free;
  end;

  { A temporary evicted before its read is written back first. }
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  UseCounts[2] := 1;
  UseCounts[3] := 1;
  UseCounts[4] := 1;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 6);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 2, 0, 0, 1), Aux,
      0, False, False, Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 3, 0, 0, 2), Aux,
      1, False, False, Cache);
    Expect<Boolean>(HasSeq([$4C, $89, $53, $10])).ToBe(False);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 4, 0, 0, 3), Aux,
      2, False, False, Cache);
    Expect<Boolean>(HasSeq([$4C, $89, $53, $10])).ToBe(True);
  finally
    Buf.Free;
  end;

  { Eviction prefers the host whose value is already dead: slot 3's only read
    frees r11, so the new result does not displace live slot 2 from r10
    (round-robin order alone would store and later reload it). }
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  UseCounts[2] := 1;
  UseCounts[3] := 1;
  UseCounts[4] := 1;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 6);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 2, 0, 0, 1), Aux,
      0, False, False, Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 3, 0, 0, 2), Aux,
      1, False, False, Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Add, 4, 3, 0, 0), Aux,
      2, False, False, Cache);
    Expect<Boolean>(HasSeq([$4C, $89, $53, $10])).ToBe(False);
    Expect<Boolean>(HasSeq([$4C, $89, $5B, $18])).ToBe(False);
    Expect<Boolean>(Cache.Entries[2].Valid and
      (Cache.Entries[2].Slot = 2)).ToBe(True);
    Expect<Boolean>(Cache.Entries[3].Valid and
      (Cache.Entries[3].Slot = 4)).ToBe(True);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestStaticCachePinnedMemoryBytes;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..5] of UInt32;
  Visible: array[0..5] of Boolean;
  Start: Integer;

  function HasSeq(const AExpected: array of Byte;
    const AFrom: Integer = 0): Boolean;
  var
    I, J: Integer;
  begin
    for I := AFrom to Buf.Size - Length(AExpected) do
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

  procedure CheckFrom(const AFrom: Integer; const AExpected: array of Byte);
  var
    J: Integer;
  begin
    Expect<Integer>(Buf.Size - AFrom).ToBe(Length(AExpected));
    for J := 0 to High(AExpected) do
      Expect<Byte>(Buf.ByteAt(AFrom + J)).ToBe(AExpected[J]);
  end;

begin
  { The pin loads Base (TWasmMemoryInst's first field) into rsi only on
    request: mov [rsp],rax (48 89 04 24); mov rsi,[rax] (48 8B 30). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPinMemory(Buf, 0);
    Expect<Boolean>(HasSeq([$48, $89, $04, $24, $48, $8B, $30])).ToBe(False);
  finally
    Buf.Free;
  end;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitPinMemory(Buf, 0, True);
    Expect<Boolean>(HasSeq([$48, $89, $04, $24, $48, $8B, $30])).ToBe(True);
  finally
    Buf.Free;
  end;

  { Slots 0/1 are the static r8/r9 hosts. Each access zero-extends its i32
    address into ecx (mov r32,r32 = 89 /r) and addresses [rsi + rcx*1]
    (ModRM rm=100, SIB 0E) per SDM Vol. 2 Tables 2-2/2-3. }
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Visible[0] := True;
  Visible[1] := True;
  UseCounts[2] := 1;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 6);
    X64EnablePinnedMemoryBase(Cache);
    Expect<Boolean>(Cache.PinnedMemoryBase).ToBe(True);

    { i32.store8 [r8] := r9b: mov ecx,r8d; mov [rsi+rcx],r9b. }
    Start := Buf.Size;
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Store8, 1, 0, 0, 0), Aux, 0, False, True,
      Cache)).ToBe(True);
    CheckFrom(Start, [$44, $89, $C1, $44, $88, $0C, $0E]);

    { i64.load8_s from [r9] straight into the dirty dynamic host r10 for
      slot 2 (REX.WR 0F BE /r, ModRM 14 = r10 + SIB). No rax bounce and no
      register-file store. r9 was loaded from its slot, so its high half is
      unknown and the address still goes through ecx. }
    Start := Buf.Size;
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI64Load8S, 2, 1, 0, 0), Aux, 1, False, True,
      Cache)).ToBe(True);
    CheckFrom(Start, [$44, $89, $C9, $4C, $0F, $BE, $14, $0E]);
    Expect<Boolean>(Cache.Entries[2].Valid and Cache.Entries[2].Dirty and
      (Cache.Entries[2].Slot = 2)).ToBe(True);

    { i32.store16 [r8] := r10w consumes the dirty value in place; the
      guard-page access cannot observe slots, so nothing is flushed. }
    Start := Buf.Size;
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI32Store16, 2, 0, 0, 0), Aux, 2, False, True,
      Cache)).ToBe(True);
    CheckFrom(Start, [$44, $89, $C1, $66, $44, $89, $14, $0E]);
    Expect<UInt32>(UseCounts[2]).ToBe(0);
    Expect<Boolean>(HasSeq([$4C, $89, $53, $10])).ToBe(False);

    { Uncached operands come from their canonical slots: mov ecx,[rbx+0x28];
      mov rax,[rbx+0x20]; mov [rsi+rcx],rax. }
    Start := Buf.Size;
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(iroI64Store, 4, 5, 0, 0), Aux, 3, False, True,
      Cache)).ToBe(True);
    CheckFrom(Start, [$8B, $4B, $28, $48, $8B, $43, $20,
      $48, $89, $04, $0E]);
  finally
    Buf.Free;
  end;
end;

{ Static slots 2 and 3 take rdi and rdx (X64CacheHostReg 4/5) with the
  same fixed-host discipline as r8/r9: loaded once at entry, written back
  only by an exit (X64FlushRegCache), kept valid across a join, and computed
  into directly. Encodings: MOV r64, r/m64 8B /r and MOV r/m64, r64 89 /r
  with REX.W (+R for r8/r9), ModRM mod=00 rm=011 (rbx) or mod=01 + disp8,
  SDM Vol. 2 Tables 2-2 and 2-3. }
procedure TX64Tests.TestStaticCacheFourFixedHosts;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..7] of UInt32;
  Visible: array[0..7] of Boolean;
  Start: Integer;
  Raised: Boolean;
begin
  Aux := nil;
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1, 2, 3]);
    CheckSeq(Buf, [
      $4C, $8B, $03,          { mov r8, [rbx] }
      $4C, $8B, $4B, $08,     { mov r9, [rbx+8] }
      $48, $8B, $7B, $10,     { mov rdi, [rbx+0x10] }
      $48, $8B, $53, $18]);   { mov rdx, [rbx+0x18] }
    Expect<Boolean>(Cache.Entries[4].Valid and
      (Cache.Entries[4].Slot = 2)).ToBe(True);
    Expect<Boolean>(Cache.Entries[5].Valid and
      (Cache.Entries[5].Slot = 3)).ToBe(True);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);

    { i32.add into slot 3 computes in rdx (mov rdx, rdi; add edx, r8d) and
      emits no register-file store: the host is the slot's only copy. }
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Add, 3, 2, 0, 0), Aux, 0,
      False, False, Cache);
    Expect<Integer>(Buf.Size - Start).ToBe(6);
    Expect<Integer>(FindSeq(Buf, [$48, $89, $FA, $44, $01, $C2], Start))
      .ToBe(Start);

    { A join keeps every fixed host and drops only r10/r11. }
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 5, 0, 0, 9), Aux, 1,
      False, False, Cache);
    X64FlushDynamicRegCache(Buf, Cache);
    X64InvalidateRegCache(Cache);
    Expect<Boolean>(Cache.Entries[0].Valid and Cache.Entries[1].Valid and
      Cache.Entries[4].Valid and Cache.Entries[5].Valid).ToBe(True);
    Expect<Boolean>(Cache.Entries[2].Valid or Cache.Entries[3].Valid)
      .ToBe(False);

    { An exit writes all four fixed hosts back, in entry order. }
    Start := Buf.Size;
    X64FlushRegCache(Buf, Cache);
    Expect<Integer>(Buf.Size - Start).ToBe(15);
    Expect<Integer>(FindSeq(Buf, [
      $4C, $89, $03,          { mov [rbx], r8 }
      $4C, $89, $4B, $08,     { mov [rbx+8], r9 }
      $48, $89, $7B, $10,     { mov [rbx+0x10], rdi }
      $48, $89, $53, $18],    { mov [rbx+0x18], rdx }
      Start)).ToBe(Start);

    { rdx is select's condition scratch, so select must never run while it
      hosts a slot (StaticCacheOp does not admit it). }
    Raised := False;
    try
      X64EmitOpCached(Buf, MakeIrInstr(iroSelect, 6, 0, 1, 2), Aux, 2,
        False, False, Cache);
    except
      on E: EWasmInternal do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Buf.Free;
  end;

  { An unused driver slot (High(UInt32)) leaves its host free and unloaded. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1, High(UInt32), 3]);
    CheckSeq(Buf, [$4C, $8B, $03, $4C, $8B, $4B, $08,
      $48, $8B, $53, $18]);
    Expect<Boolean>(Cache.Entries[4].Valid).ToBe(False);
    Expect<Boolean>(Cache.Entries[5].Valid).ToBe(True);
  finally
    Buf.Free;
  end;
end;

{ An i32 address indexes [rsi + index] only as its zero-extended value. A
  host last written by a 32-bit operation (which zero-extends, SDM Vol. 1
  §3.4.1.1) already is one and indexes directly; a 64-bit write, a slot
  reload, or a join forces the 32-bit copy into ecx (MOV r/m32, r32 89 /r).
  Loads land directly in their destination host. SIB bytes: scale 1, index
  rdi (111) or rdx (010) or rcx (001), base rsi (110). }
procedure TX64Tests.TestStaticCacheAddressZeroExtension;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..7] of UInt32;
  Visible: array[0..7] of Boolean;
  Start: Integer;

  procedure Op(const AIns: TWasmIrInstr);
  begin
    Expect<Boolean>(X64EmitOpCached(Buf, AIns, Aux, 0, False, True,
      Cache)).ToBe(True);
  end;

  procedure CheckFrom(const AFrom: Integer; const AExpected: array of Byte);
  var
    J: Integer;
  begin
    Expect<Integer>(Buf.Size - AFrom).ToBe(Length(AExpected));
    for J := 0 to High(AExpected) do
      Expect<Byte>(Buf.ByteAt(AFrom + J)).ToBe(AExpected[J]);
  end;

begin
  Aux := nil;
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1, 2, 3]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    X64EnablePinnedMemoryBase(Cache);
    { Entry loads are 64-bit copies of the slots: nothing known. }
    Expect<Boolean>(Cache.Entries[4].Zx32 or Cache.Entries[5].Zx32)
      .ToBe(False);

    { i32.add into rdi, then i32.load through it: no copy, and the value
      goes straight into r10 (44 8B 14 3E = mov r10d, [rsi+rdi]). }
    Start := Buf.Size;
    Op(MakeIrInstr(iroI32Add, 2, 0, 1, 0));
    Op(MakeIrInstr(iroI32Load, 6, 2, 0, 0));
    CheckFrom(Start, [$4C, $89, $C7, $44, $01, $CF, $44, $8B, $14, $3E]);
    Expect<Boolean>(Cache.Entries[2].Valid and (Cache.Entries[2].Slot = 6) and
      Cache.Entries[2].Dirty and Cache.Entries[2].Zx32).ToBe(True);

    { i64.add into the same host: its high half is live, so the store
      copies the address to ecx first (89 F9 = mov ecx, edi). }
    Start := Buf.Size;
    Op(MakeIrInstr(iroI64Add, 2, 0, 1, 0));
    Op(MakeIrInstr(iroI32Store, 0, 2, 0, 0));
    CheckFrom(Start, [$4C, $89, $C7, $4C, $01, $CF, $89, $F9,
      $44, $89, $04, $0E]);

    { A 32-bit shift of that non-zero-extended source is conservatively not
      credited (mov rcx, r9; mov rdx, rdi; shl edx, cl): the load copies
      edx (89 D1) and lands in r11 (44 8B 1C 0E). }
    Start := Buf.Size;
    Op(MakeIrInstr(iroI32Shl, 3, 2, 1, 0));
    Op(MakeIrInstr(iroI32Load, 7, 3, 0, 0));
    CheckFrom(Start, [$4C, $89, $C9, $48, $89, $FA, $D3, $E2,
      $89, $D1, $44, $8B, $1C, $0E]);

    { After an i32.and the shift inherits the zero extension; the
      load16_s indexes [rsi+rdx] directly (44 0F BF 14 16). }
    Start := Buf.Size;
    Op(MakeIrInstr(iroI32And, 2, 0, 1, 0));
    Op(MakeIrInstr(iroI32Shl, 3, 2, 1, 0));
    Op(MakeIrInstr(iroI32Load16S, 6, 3, 0, 0));
    CheckFrom(Start, [$4C, $89, $C7, $44, $21, $CF,
      $4C, $89, $C9, $48, $89, $FA, $D3, $E2,
      $44, $0F, $BF, $14, $16]);

    { A join forgets it: another predecessor may have written rdx with a
      64-bit value. }
    X64FlushDynamicRegCache(Buf, Cache);
    X64InvalidateRegCache(Cache);
    Expect<Boolean>(Cache.Entries[5].Zx32).ToBe(False);
    Start := Buf.Size;
    Op(MakeIrInstr(iroI32Load, 6, 3, 0, 0));
    CheckFrom(Start, [$89, $D1, $44, $8B, $14, $0E]);

    { A move (mov rax, rdi; mov r10, rax) carries the source's fact: rdi is
      unknown after the join, so the store copies r10d; after an i32.or
      into rdi, the next copy indexes [rsi + r10] directly. }
    X64FlushDynamicRegCache(Buf, Cache);
    X64InvalidateRegCache(Cache);
    Start := Buf.Size;
    Op(MakeIrInstr(iroMove, 6, 2, 0, 0));
    Op(MakeIrInstr(iroI32Store, 1, 6, 0, 0));
    CheckFrom(Start, [$48, $89, $F8, $49, $89, $C2, $44, $89, $D1,
      $44, $89, $0C, $0E]);
    Op(MakeIrInstr(iroI32Or, 2, 0, 1, 0));
    Start := Buf.Size;
    Op(MakeIrInstr(iroMove, 6, 2, 0, 0));
    Op(MakeIrInstr(iroI32Store, 1, 6, 0, 0));
    CheckFrom(Start, [$48, $89, $F8, $49, $89, $C2,
      $46, $89, $0C, $16]);

    { A compare result is 0/1 in a zeroed host (xor edi, edi; cmp r8d, r9d;
      setb dil), so a byte store through it indexes [rsi+rdi] (44 88 0C 3E
      = mov [rsi+rdi], r9b). }
    Start := Buf.Size;
    Op(MakeIrInstr(iroI32LtU, 2, 0, 1, 0));
    Op(MakeIrInstr(iroI32Store8, 1, 2, 0, 0));
    CheckFrom(Start, [$31, $FF, $45, $39, $C8, $40, $0F, $92, $C7,
      $44, $88, $0C, $3E]);

    { A zero-extending load result feeds the next access directly; a
      sign extension to 64 bits does not. i32.load8_u into r10 (44 0F B6
      14 3E), then i64.load through it into r11 (4E 8B 1C 16 = mov r11,
      [rsi+r10]); i64.load8_s into r11 (4C 0F BE 1C 3E), then a store
      through it copies r11d first (44 89 D9). }
    X64FlushDynamicRegCache(Buf, Cache);
    X64InvalidateRegCache(Cache);
    Op(MakeIrInstr(iroI32And, 2, 0, 1, 0));
    Start := Buf.Size;
    Op(MakeIrInstr(iroI32Load8U, 7, 2, 0, 0));
    Op(MakeIrInstr(iroI64Load, 6, 7, 0, 0));
    CheckFrom(Start, [$44, $0F, $B6, $14, $3E, $4E, $8B, $1C, $16]);
    Start := Buf.Size;
    Op(MakeIrInstr(iroI64Load8S, 6, 2, 0, 0));
    Op(MakeIrInstr(iroI32Store, 1, 6, 0, 0));
    CheckFrom(Start, [$4C, $0F, $BE, $1C, $3E, $44, $89, $D9,
      $44, $89, $0C, $0E]);

    { A dynamic host reloaded from a slot (64-bit mov) inherits nothing
      from the 32-bit value it held before: both r10 and r11 end i32 adds,
      then slot 5 is loaded into one of them for an i32.eqz, and a store
      through slot 5 must copy that host's low half to ecx first. }
    X64FlushDynamicRegCache(Buf, Cache);
    X64InvalidateRegCache(Cache);
    Op(MakeIrInstr(iroI32Add, 6, 0, 1, 0));
    Op(MakeIrInstr(iroI32Add, 7, 0, 1, 0));
    Expect<Boolean>(Cache.Entries[2].Zx32 and Cache.Entries[3].Zx32)
      .ToBe(True);
    Op(MakeIrInstr(iroI32Eqz, 2, 5, 0, 0));
    Start := Buf.Size;
    Op(MakeIrInstr(iroI32Store, 1, 5, 0, 0));
    Expect<Integer>(Buf.Size - Start).ToBe(7);
    Expect<Boolean>((FindSeq(Buf, [$44, $89, $D1], Start) = Start) or
      (FindSeq(Buf, [$44, $89, $D9], Start) = Start)).ToBe(True);
  finally
    Buf.Free;
  end;
end;

{ `op r32, [rsi + index]` (ADD 03, SUB 2B, IMUL 0F AF /r; ModRM mod=00
  rm=100 + SIB, SDM Vol. 2 Tables 2-2/2-3). }
procedure TX64Tests.TestStaticCacheLoadAluFusion;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..7] of UInt32;
  Visible: array[0..7] of Boolean;
  Start: Integer;

  procedure CheckFrom(const AFrom: Integer; const AExpected: array of Byte);
  var
    J: Integer;
  begin
    Expect<Integer>(Buf.Size - AFrom).ToBe(Length(AExpected));
    for J := 0 to High(AExpected) do
      Expect<Byte>(Buf.ByteAt(AFrom + J)).ToBe(AExpected[J]);
  end;

begin
  { The predicate: a zero-offset i32.load read once by i32 add/sub/and/or/
    xor/mul, and only as sub's right operand. }
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI32Load, 6, 2, 0, 0),
    MakeIrInstr(iroI32Add, 3, 6, 3, 0))).ToBe(True);
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI32Load, 6, 2, 0, 0),
    MakeIrInstr(iroI32Sub, 3, 3, 6, 0))).ToBe(True);
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI32Load, 6, 2, 0, 0),
    MakeIrInstr(iroI32Sub, 3, 6, 3, 0))).ToBe(False);
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI32Load, 6, 2, 0, 0),
    MakeIrInstr(iroI32Mul, 3, 6, 6, 0))).ToBe(False);
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI32Load8U, 6, 2, 0, 0),
    MakeIrInstr(iroI32Add, 3, 3, 6, 0))).ToBe(False);
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI32Load, 6, 2, 0, 4),
    MakeIrInstr(iroI32Add, 3, 3, 6, 0))).ToBe(False);
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI64Load, 6, 2, 0, 0),
    MakeIrInstr(iroI64Add, 3, 3, 6, 0))).ToBe(False);
  Expect<Boolean>(X64CanFuseLoadAlu(MakeIrInstr(iroI32Load, 6, 2, 0, 0),
    MakeIrInstr(iroI32Shl, 3, 3, 6, 0))).ToBe(False);

  Aux := nil;
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1, 2, 3]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    X64EnablePinnedMemoryBase(Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32And, 2, 0, 1, 0), Aux, 0,
      False, True, Cache);

    { acc (rdx) += [rsi + rdi]: 03 14 3E. }
    Start := Buf.Size;
    X64EmitLoadAluCached(Buf, MakeIrInstr(iroI32Load, 6, 2, 0, 0),
      MakeIrInstr(iroI32Add, 3, 3, 6, 0), Cache);
    CheckFrom(Start, [$03, $14, $3E]);
    Expect<Boolean>(Cache.Entries[5].Zx32).ToBe(True);

    { A dynamic result: mov r10, r8; sub r10d, [rsi + rdi] (44 2B 14 3E). }
    Start := Buf.Size;
    X64EmitLoadAluCached(Buf, MakeIrInstr(iroI32Load, 6, 2, 0, 0),
      MakeIrInstr(iroI32Sub, 7, 0, 6, 0), Cache);
    CheckFrom(Start, [$4D, $89, $C2, $44, $2B, $14, $3E]);
    Expect<Boolean>(Cache.Entries[2].Valid and (Cache.Entries[2].Slot = 7) and
      Cache.Entries[2].Zx32).ToBe(True);

    { The result takes the dead address's host r10 (r11 is live), so the
      index moves to ecx before r8 is copied over it: mov ecx, r10d;
      mov r10, r8; imul r10d, [rsi + rcx] (44 0F AF 14 0E). }
    X64FlushDynamicRegCache(Buf, Cache);
    X64InvalidateRegCache(Cache);
    UseCounts[5] := 1;
    UseCounts[4] := 1;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Add, 5, 0, 1, 0), Aux, 0,
      False, True, Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Add, 4, 0, 1, 0), Aux, 0,
      False, True, Cache);
    Expect<Boolean>(Cache.Entries[2].Slot = 5).ToBe(True);
    Start := Buf.Size;
    X64EmitLoadAluCached(Buf, MakeIrInstr(iroI32Load, 6, 5, 0, 0),
      MakeIrInstr(iroI32Mul, 7, 6, 0, 0), Cache);
    CheckFrom(Start, [$44, $89, $D1, $4D, $89, $C2,
      $44, $0F, $AF, $14, $0E]);
    Expect<Boolean>(Cache.Entries[3].Valid and
      (Cache.Entries[3].Slot = 4)).ToBe(True);
  finally
    Buf.Free;
  end;
end;

{ --- scaled pinned index (SDM Vol. 2 Table 2-3: SIB = ss index base; a
  base with low bits 101 takes mod=01 disp8 0; index 100 needs REX.X, so
  r12 indexes and rsp cannot). Each expected sequence was assembled with
  GNU as and disassembled with objdump -Mintel. -------------------------- }

procedure TX64Tests.TestScaledIndexEncodings;
var
  Buf: TWasmCodeBuffer;

  procedure Load(const ADest, ABase, AIndex: Byte; const ASize: UInt32;
    const ASigned, AResult64: Boolean; const AScale: Byte;
    const AExpected: array of Byte);
  begin
    Buf.Free;
    Buf := TWasmCodeBuffer.Create;
    X64EmitLoadScalarIndexed(Buf, ADest, ABase, AIndex, ASize, ASigned,
      AResult64, AScale);
    CheckSeq(Buf, AExpected);
  end;

  procedure Store(const ASource, ABase, AIndex: Byte; const ASize: UInt32;
    const AScale: Byte; const AExpected: array of Byte);
  begin
    Buf.Free;
    Buf := TWasmCodeBuffer.Create;
    X64EmitStoreScalarIndexed(Buf, ASource, ABase, AIndex, ASize, AScale);
    CheckSeq(Buf, AExpected);
  end;

var
  Raised: Boolean;
begin
  Buf := nil;
  try
    { mov r8d, [rsi + r10*4] }
    Load(X64_R8, X64_RSI, X64_R10, 4, False, False, 2, [$46, $8B, $04, $96]);
    { mov eax, [rbp + rcx*2 + 0] }
    Load(X64_RAX, X64_RBP, X64_RCX, 4, False, False, 1,
      [$8B, $44, $4D, $00]);
    { mov r15d, [r12 + r12*8] }
    Load(X64_R15, X64_R12, X64_R12, 4, False, False, 3, [$47, $8B, $3C, $E4]);
    { movzx r9d, byte [r13 + r15*2 + 0] }
    Load(X64_R9, X64_R13, X64_R15, 1, False, False, 1,
      [$47, $0F, $B6, $4C, $7D, $00]);
    { movsx eax, word [rsi + rbx*8] }
    Load(X64_RAX, X64_RSI, X64_RBX, 2, True, False, 3,
      [$0F, $BF, $04, $DE]);
    { movsxd r10, dword [rbx + r12*4] }
    Load(X64_R10, X64_RBX, X64_R12, 4, True, True, 2, [$4E, $63, $14, $A3]);
    { mov rax, [r12 + r8*8] }
    Load(X64_RAX, X64_R12, X64_R8, 8, False, False, 3, [$4B, $8B, $04, $C4]);
    { movzx edx, word [rsi + r11*2] }
    Load(X64_RDX, X64_RSI, X64_R11, 2, False, False, 1,
      [$42, $0F, $B7, $14, $5E]);
    { mov [rsi + r10*4], r8d }
    Store(X64_R8, X64_RSI, X64_R10, 4, 2, [$46, $89, $04, $96]);
    { mov [rbp + r9*8 + 0], rax }
    Store(X64_RAX, X64_RBP, X64_R9, 8, 3, [$4A, $89, $44, $CD, $00]);
    { mov byte [r12 + rdi*2], sil: the REX that makes sil addressable }
    Store(X64_RSI, X64_R12, X64_RDI, 1, 1, [$41, $88, $34, $7C]);
    { mov word [r13 + r11*4 + 0], dx }
    Store(X64_RDX, X64_R13, X64_R11, 2, 2, [$66, $43, $89, $54, $9D, $00]);
    { mov byte [rsi + r14*8], r9b }
    Store(X64_R9, X64_RSI, X64_R14, 1, 3, [$46, $88, $0C, $F6]);
    { Scale 0 is the unscaled form: mov r8d, [rsi + r10] }
    Store(X64_R8, X64_RSI, X64_R10, 4, 0, [$46, $89, $04, $16]);

    { rsp is not an index, and there is no scale above 8. }
    Raised := False;
    try
      Load(X64_RAX, X64_RSI, X64_RSP, 4, False, False, 1, []);
    except
      on EWasmInternal do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Raised := False;
    try
      Store(X64_RAX, X64_RSI, X64_RCX, 4, 4, []);
    except
      on EWasmInternal do
        Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestScaledIndexPinnedAccess;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..7] of UInt32;
  Visible: array[0..7] of Boolean;
  Start: Integer;

  procedure CheckFrom(const AFrom: Integer; const AExpected: array of Byte);
  var
    J: Integer;
  begin
    Expect<Integer>(Buf.Size - AFrom).ToBe(Length(AExpected));
    for J := 0 to High(AExpected) do
      Expect<Byte>(Buf.ByteAt(AFrom + J)).ToBe(AExpected[J]);
  end;

begin
  Aux := nil;
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1, 2, 3]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    X64EnablePinnedMemoryBase(Cache);

    { An i32.and leaves rdi zero-extended (mov rdi, r8; and edi, r9d), so
      the scaled load indexes it directly: mov r10d, [rsi + rdi*4]. }
    Start := Buf.Size;
    Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroI32And, 2, 0, 1, 0),
      Aux, 0, False, True, Cache)).ToBe(True);
    X64EmitScalarMemoryPinned(Buf, MakeIrInstr(iroI32Load, 6, 2, 0, 0),
      False, Cache, 2);
    CheckFrom(Start, [$4C, $89, $C7, $44, $21, $CF, $44, $8B, $14, $BE]);

    { After an i64.add rdi's high half is live: mov ecx, edi, then
      mov [rsi + rcx*8], r8d. A scaled 64-bit index would be wrong. }
    Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroI64Add, 2, 0, 1, 0),
      Aux, 0, False, True, Cache)).ToBe(True);
    Start := Buf.Size;
    X64EmitScalarMemoryPinned(Buf, MakeIrInstr(iroI32Store, 0, 2, 0, 0),
      False, Cache, 3);
    CheckFrom(Start, [$89, $F9, $44, $89, $04, $CE]);

    { An uncached index loads its slot with a 32-bit load (mov ecx,
      [rbx + 0x38]): mov word [rsi + rcx*2], r9w. }
    Start := Buf.Size;
    X64EmitScalarMemoryPinned(Buf, MakeIrInstr(iroI32Store16, 1, 7, 0, 0),
      False, Cache, 1);
    CheckFrom(Start, [$8B, $4B, $38, $66, $44, $89, $0C, $4E]);

    { The load/ALU pair takes the same scale: add edx, [rsi + rdi*4] after
      a fresh i32.and into rdi. }
    Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroI32And, 2, 0, 1, 0),
      Aux, 0, False, True, Cache)).ToBe(True);
    Start := Buf.Size;
    X64EmitLoadAluCached(Buf, MakeIrInstr(iroI32Load, 6, 2, 0, 0),
      MakeIrInstr(iroI32Add, 3, 3, 6, 0), Cache, 2);
    CheckFrom(Start, [$03, $14, $BE]);
  finally
    Buf.Free;
  end;
end;

{ --- direct register operands (SDM Vol. 2: ADD 01, SUB 29, AND 21, OR 09,
  XOR 31, CMP 39, TEST 85 /r; IMUL 0F AF /r; SETcc 0F 90+cc /0; MOVZX
  0F B6 /r; REX W/R/B per §2.2.1 and Table 2-2) ----------------------------- }

procedure TX64Tests.TestDirectOperandEncodings;
const
  Hosts: array[0 .. 5] of Byte = (X64_RAX, X64_RCX, X64_R8, X64_R9, X64_R10,
    X64_R11);
  Ops: array[0 .. 6] of Byte = ($01, $29, $21, $09, $31, $39, $85);
var
  Buf: TWasmCodeBuffer;
  D, S, O, W: Integer;
  Rex: Byte;
begin
  { Spot checks, each disassembled with objdump -mi386:x86-64. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitAluRegReg(Buf, $01, False, X64_R10, X64_R11);
    X64EmitAluRegReg(Buf, $29, True, X64_R9, X64_R10);
    X64EmitAluRegReg(Buf, $29, False, X64_RAX, X64_R9);
    X64EmitAluRegReg(Buf, $21, True, X64_R8, X64_RAX);
    X64EmitAluRegReg(Buf, $39, False, X64_R10, X64_R11);
    X64EmitAluRegReg(Buf, $39, True, X64_R11, X64_R8);
    X64EmitAluRegReg(Buf, $85, False, X64_R11, X64_R11);
    X64EmitAluRegReg(Buf, $31, False, X64_R8, X64_R8);
    X64EmitImul(Buf, False, X64_R10, X64_R11);
    X64EmitImul(Buf, True, X64_R9, X64_R8);
    X64EmitImul(Buf, True, X64_RAX, X64_R11);
    X64EmitShiftCl(Buf, 4, False, X64_R11);
    X64EmitShiftCl(Buf, 1, True, X64_R9);
    X64EmitSetccReg(Buf, X64_CC_B, X64_R8);
    X64EmitSetccReg(Buf, X64_CC_L, X64_R10);
    X64EmitSetccReg(Buf, X64_CC_E, X64_RAX);
    X64EmitSetccReg(Buf, X64_CC_NE, X64_RSI);
    X64EmitMovzxReg8(Buf, X64_R10, X64_R10);
    X64EmitMovzxReg8(Buf, X64_RAX, X64_RAX);
    X64EmitMovzxReg8(Buf, X64_RAX, X64_RSI);
    X64EmitMovzxReg8(Buf, X64_R9, X64_RAX);
    X64EmitMovRegReg(Buf, X64_R10, X64_R9);
    X64EmitMovRegImm32(Buf, X64_R11, $19660D);
    CheckSeq(Buf, [
      $45, $01, $DA,             { add r10d, r11d }
      $4D, $29, $D1,             { sub r9, r10 }
      $44, $29, $C8,             { sub eax, r9d }
      $49, $21, $C0,             { and r8, rax }
      $45, $39, $DA,             { cmp r10d, r11d }
      $4D, $39, $C3,             { cmp r11, r8 }
      $45, $85, $DB,             { test r11d, r11d }
      $45, $31, $C0,             { xor r8d, r8d }
      $45, $0F, $AF, $D3,        { imul r10d, r11d }
      $4D, $0F, $AF, $C8,        { imul r9, r8 }
      $49, $0F, $AF, $C3,        { imul rax, r11 }
      $41, $D3, $E3,             { shl r11d, cl }
      $49, $D3, $C9,             { ror r9, cl }
      $41, $0F, $92, $C0,        { setb r8b }
      $41, $0F, $9C, $C2,        { setl r10b }
      $0F, $94, $C0,             { sete al }
      $40, $0F, $95, $C6,        { setne sil (REX selects sil, not dh) }
      $45, $0F, $B6, $D2,        { movzx r10d, r10b }
      $0F, $B6, $C0,             { movzx eax, al }
      $40, $0F, $B6, $C6,        { movzx eax, sil }
      $44, $0F, $B6, $C8,        { movzx r9d, al }
      $4D, $89, $CA,             { mov r10, r9 }
      $41, $BB, $0D, $66, $19, $00]); { mov r11d, 0x19660d }
  finally
    Buf.Free;
  end;

  { Every scratch/cache register pair, both widths: <op> r/m=D, reg=S takes
    REX.W for 64-bit, REX.R for S >= 8, REX.B for D >= 8, and ModRM
    11 S D; imul swaps the fields (reg=D, rm=S). A 32-bit form with neither
    extended register carries no REX. }
  for D := 0 to High(Hosts) do
    for S := 0 to High(Hosts) do
      for W := 0 to 1 do
      begin
        for O := 0 to High(Ops) do
        begin
          Buf := TWasmCodeBuffer.Create;
          try
            X64EmitAluRegReg(Buf, Ops[O], W = 1, Hosts[D], Hosts[S]);
            Rex := $40 or (W shl 3) or ((Hosts[S] shr 3) shl 2) or
              (Hosts[D] shr 3);
            if Rex = $40 then
              CheckSeq(Buf, [Ops[O], $C0 or ((Hosts[S] and 7) shl 3) or
                (Hosts[D] and 7)])
            else
              CheckSeq(Buf, [Rex, Ops[O], $C0 or ((Hosts[S] and 7) shl 3) or
                (Hosts[D] and 7)]);
          finally
            Buf.Free;
          end;
        end;
        Buf := TWasmCodeBuffer.Create;
        try
          X64EmitImul(Buf, W = 1, Hosts[D], Hosts[S]);
          Rex := $40 or (W shl 3) or ((Hosts[D] shr 3) shl 2) or
            (Hosts[S] shr 3);
          if Rex = $40 then
            CheckSeq(Buf, [$0F, $AF, $C0 or ((Hosts[D] and 7) shl 3) or
              (Hosts[S] and 7)])
          else
            CheckSeq(Buf, [Rex, $0F, $AF, $C0 or ((Hosts[D] and 7) shl 3) or
              (Hosts[S] and 7)]);
        finally
          Buf.Free;
        end;
      end;

  { SETcc / MOVZX on each cache host: r8b..r11b need REX.B (and REX.R for
    the movzx destination). }
  for D := 2 to High(Hosts) do
  begin
    Buf := TWasmCodeBuffer.Create;
    try
      X64EmitSetccReg(Buf, X64_CC_A, Hosts[D]);
      X64EmitMovzxReg8(Buf, Hosts[D], Hosts[D]);
      CheckSeq(Buf, [$41, $0F, $97, $C0 or (Hosts[D] and 7),
        $45, $0F, $B6, $C0 or ((Hosts[D] and 7) shl 3) or (Hosts[D] and 7)]);
    finally
      Buf.Free;
    end;
  end;
end;

{ Slots 0/1 are static (r8/r9); constants put slot 2 in r10 and slot 3 in
  r11 with deferred stores. Each case then emits one cached op and asserts
  the bytes it added. }
procedure TX64Tests.TestDirectOperandCachedOps;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0 .. 7] of UInt32;
  Visible: array[0 .. 7] of Boolean;
  Start: Integer;

  procedure Setup(const AUses2, AUses3: UInt32);
  begin
    FillChar(UseCounts, SizeOf(UseCounts), 0);
    FillChar(Visible, SizeOf(Visible), 0);
    UseCounts[2] := AUses2;
    UseCounts[3] := AUses3;
    Buf := TWasmCodeBuffer.Create;
    Buf.NewLabel;
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 2, 0, 0, 7), Aux, 0,
      False, False, Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 3, 0, 0, 9), Aux, 1,
      False, False, Cache);
    Start := Buf.Size;
  end;

  procedure Emit(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32);
  begin
    Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(AOp, ADest, AA, AB, 0),
      Aux, 2, False, False, Cache)).ToBe(True);
  end;

  procedure CheckAdded(const AExpected: array of Byte);
  var
    I: Integer;
  begin
    Expect<Integer>(Buf.Size - Start).ToBe(Length(AExpected));
    for I := 0 to High(AExpected) do
      if Start + I < Buf.Size then
        Expect<Byte>(Buf.ByteAt(Start + I)).ToBe(AExpected[I]);
    Buf.Free;
  end;

begin
  { After the two static loads (7 bytes) the constants go straight to r10
    and r11: mov r10d, 7 ; mov r11d, 9. }
  Setup(1, 1);
  Start := 7;
  CheckAdded([$41, $BA, $07, $00, $00, $00, $41, $BB, $09, $00, $00, $00]);

  { Result slot is the left operand's: one in-place add r10d, r11d. }
  Setup(1, 1);
  Emit(iroI32Add, 2, 2, 3);
  CheckAdded([$45, $01, $DA]);

  { Static result host: mov r8, r10 ; sub r8d, r11d. }
  Setup(1, 1);
  Emit(iroI32Sub, 0, 2, 3);
  CheckAdded([$4D, $89, $D0, $45, $29, $D8]);

  { A subtraction whose result host holds its right operand goes through
    rax: mov rax, r10 ; sub eax, r11d ; mov r11, rax. }
  Setup(1, 1);
  Emit(iroI32Sub, 3, 2, 3);
  CheckAdded([$4C, $89, $D0, $44, $29, $D8, $49, $89, $C3]);

  { A commutative op swaps instead: add r11, r10. }
  Setup(1, 1);
  Emit(iroI64Add, 3, 2, 3);
  CheckAdded([$4D, $01, $D3]);

  { Two-operand imul in place: imul r10, r11. }
  Setup(1, 1);
  Emit(iroI64Mul, 2, 2, 3);
  CheckAdded([$4D, $0F, $AF, $D3]);

  { x op x: mov r8, r10 ; xor r8d, r10d. }
  Setup(2, 0);
  Emit(iroI32Xor, 0, 2, 2);
  CheckAdded([$4D, $89, $D0, $45, $31, $D0]);

  { The count reaches CL before the result host (the count's own host) is
    overwritten: mov rcx, r11 ; mov r11, r10 ; shl r11d, cl. }
  Setup(1, 1);
  Emit(iroI32Shl, 3, 2, 3);
  CheckAdded([$4C, $89, $D9, $4D, $89, $D3, $41, $D3, $E3]);

  { In place: mov rcx, r11 ; ror r10, cl. }
  Setup(1, 1);
  Emit(iroI64Rotr, 2, 2, 3);
  CheckAdded([$4C, $89, $D9, $49, $D3, $CA]);

  { A distinct result host is zeroed before the compare:
    xor r8d, r8d ; cmp r10d, r11d ; setb r8b. }
  Setup(1, 1);
  Emit(iroI32LtU, 0, 2, 3);
  CheckAdded([$45, $31, $C0, $45, $39, $DA, $41, $0F, $92, $C0]);

  { An operand's host is widened after SETcc:
    cmp r10, r11 ; setl r10b ; movzx r10d, r10b. }
  Setup(1, 1);
  Emit(iroI64LtS, 2, 2, 3);
  CheckAdded([$4D, $39, $DA, $41, $0F, $9C, $C2, $45, $0F, $B6, $D2]);

  { test r11d, r11d ; sete r11b ; movzx r11d, r11b. }
  Setup(1, 1);
  Emit(iroI32Eqz, 3, 3, 0);
  CheckAdded([$45, $85, $DB, $41, $0F, $94, $C3, $45, $0F, $B6, $DB]);

  { xor r9d, r9d ; test r10, r10 ; sete r9b. }
  Setup(1, 1);
  Emit(iroI64Eqz, 1, 2, 0);
  CheckAdded([$45, $31, $C9, $4D, $85, $D2, $41, $0F, $94, $C1]);

  { Fused compare-branch: cmp r10d, r11d ; (no live dirty value) ;
    jge rel32. }
  Setup(1, 1);
  X64EmitCompareBranchCached(Buf, MakeIrInstr(iroI32GeS, 4, 2, 3, 0),
    MakeIrInstr(iroBranchIf, 0, 4, 0, 0), Cache);
  CheckAdded([$45, $39, $DA, $0F, $8D, $00, $00, $00, $00]);

  { Branch on a resident condition: test r10d, r10d ; jne rel32. }
  Setup(1, 0);
  Emit(iroBranchIf, 0, 2, 0);
  CheckAdded([$45, $85, $D2, $0F, $85, $00, $00, $00, $00]);
end;

procedure TX64Tests.TestDirectOperandBookkeeping;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0 .. 7] of UInt32;
  Visible: array[0 .. 7] of Boolean;
  Start: Integer;

  procedure Emit(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32;
    const AImm: Int64 = 0);
  begin
    Expect<Boolean>(X64EmitOpCached(Buf,
      MakeIrInstr(AOp, ADest, AA, AB, AImm), Aux, 0, False, False,
      Cache)).ToBe(True);
  end;

  procedure CheckFrom(const AExpected: array of Byte);
  var
    I: Integer;
  begin
    Expect<Integer>(Buf.Size - Start).ToBe(Length(AExpected));
    for I := 0 to High(AExpected) do
      if Start + I < Buf.Size then
        Expect<Byte>(Buf.ByteAt(Start + I)).ToBe(AExpected[I]);
  end;

begin
  FillChar(Visible, SizeOf(Visible), 0);

  { A dead left operand's host is the cheapest victim, so the result takes
    it in place and the dead value is never stored: add r10d, r11d. }
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  UseCounts[2] := 1;
  UseCounts[3] := 2;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    Emit(iroI32Const, 2, 0, 0, 7);
    Emit(iroI32Const, 3, 0, 0, 9);
    Start := Buf.Size;
    Emit(iroI32Add, 5, 2, 3);
    CheckFrom([$45, $01, $DA]);
    Expect<Boolean>(Cache.Entries[2].Valid and (Cache.Entries[2].Slot = 5) and
      Cache.Entries[2].Dirty).ToBe(True);
    Expect<Boolean>(Cache.Entries[3].Valid and
      (Cache.Entries[3].Slot = 3)).ToBe(True);
    Expect<UInt32>(UseCounts[2]).ToBe(0);
    Expect<UInt32>(UseCounts[3]).ToBe(1);
  finally
    Buf.Free;
  end;

  { A still-live left operand displaced by the result is spilled before its
    host is overwritten: mov [rbx+16], r10 ; add r10d, r11d. Its next read
    reloads from the slot. }
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  UseCounts[2] := 2;
  UseCounts[3] := 2;
  UseCounts[5] := 1;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    Emit(iroI32Const, 2, 0, 0, 7);
    Emit(iroI32Const, 3, 0, 0, 9);
    Start := Buf.Size;
    Emit(iroI32Add, 5, 2, 3);
    CheckFrom([$4C, $89, $53, $10, $45, $01, $DA]);
    Expect<Boolean>(Cache.Entries[2].Valid and (Cache.Entries[2].Slot = 5) and
      Cache.Entries[2].Dirty).ToBe(True);
    Expect<UInt32>(UseCounts[2]).ToBe(1);
    { Both dynamic entries are live and dirty; round-robin picks r11, which
      is spilled, then reloaded with slot 2: mov [rbx+24], r11 ;
      mov r11, [rbx+16] ; mov r8, r11 ; add r8d, r10d. }
    Start := Buf.Size;
    Emit(iroI32Add, 0, 2, 5);
    CheckFrom([$4C, $89, $5B, $18, $4C, $8B, $5B, $10, $4D, $89, $D8,
      $45, $01, $D0]);
  finally
    Buf.Free;
  end;

  { Write-through pair: the right operand's miss takes the left operand's
    host (r8), so the left value is copied to rax first; the result then
    takes r9 and is stored: mov rax, r8 ; mov r8, [rbx+16] ; mov r9, rax ;
    sub r9d, r8d ; mov [rbx+40], r9. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64InitRegCache(Cache);
    Emit(iroI32Const, 1, 0, 0, 5);
    Emit(iroI32Const, 3, 0, 0, 6);
    Start := Buf.Size;
    Emit(iroI32Sub, 5, 1, 2);
    CheckFrom([$4C, $89, $C0, $4C, $8B, $43, $10, $49, $89, $C1,
      $45, $29, $C1, $4C, $89, $4B, $28]);
    Expect<Boolean>(Cache.Entries[0].Valid and
      (Cache.Entries[0].Slot = 2)).ToBe(True);
    Expect<Boolean>(Cache.Entries[1].Valid and
      (Cache.Entries[1].Slot = 5)).ToBe(True);
    Expect<Byte>(Cache.Next).ToBe(0);
  finally
    Buf.Free;
  end;

  { Static allocation without deferred stores writes a dynamic result through
    from its host. Round robin gives slot 4 the left operand's r10:
    add r10d, r11d ; mov [rbx+32], r10. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    Emit(iroI32Const, 2, 0, 0, 7);
    Emit(iroI32Const, 3, 0, 0, 9);
    Start := Buf.Size;
    Emit(iroI32Add, 4, 2, 3);
    CheckFrom([$45, $01, $DA, $4C, $89, $53, $20]);
    Expect<Boolean>(Cache.Entries[2].Valid and (Cache.Entries[2].Slot = 4) and
      not Cache.Entries[2].Dirty).ToBe(True);
  finally
    Buf.Free;
  end;

  { A native-core parameter host defers its store like a dynamic entry: an
    in-place op leaves it dirty with no store: add r8d, r8d. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64SeedNativeCoreCache(Cache, 1, 0, 0, True);
    Start := Buf.Size;
    Emit(iroI32Add, 0, 0, 0);
    CheckFrom([$45, $01, $C0]);
    Expect<Boolean>(Cache.Entries[0].Valid and Cache.Entries[0].Dirty)
      .ToBe(True);
  finally
    Buf.Free;
  end;
end;

{ --- immediate operands (SDM Vol. 2: 83/81 group 1, 6B/69 IMUL, C1 group 2,
  8D LEA, 89 MOV, C7 /0 MOV imm32, B8+rd) ---------------------------------- }

procedure TX64Tests.TestImmediateEncodings;
var
  Buf: TWasmCodeBuffer;
begin
  { imm8 vs imm32 at both sign boundaries, REX.B for r8-r15, and REX.W:
    add r10d,127 ; add r10d,128 ; add r10d,-128 ; add r10d,-129 ;
    sub eax,1 ; and ecx,0x3fff ; or r15,-1 ; xor r11,0x7fffffff ;
    cmp r8d,1000000000 ; cmp r9,-2^31 ; xor r11d,0x9e3779b9. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitAluRegImm(Buf, 0, False, X64_R10, 127);
    X64EmitAluRegImm(Buf, 0, False, X64_R10, 128);
    X64EmitAluRegImm(Buf, 0, False, X64_R10, -128);
    X64EmitAluRegImm(Buf, 0, False, X64_R10, -129);
    X64EmitAluRegImm(Buf, 5, False, X64_RAX, 1);
    X64EmitAluRegImm(Buf, 4, False, X64_RCX, $3FFF);
    X64EmitAluRegImm(Buf, 1, True, X64_R15, -1);
    X64EmitAluRegImm(Buf, 6, True, X64_R11, $7FFFFFFF);
    X64EmitAluRegImm(Buf, 7, False, X64_R8, 1000000000);
    X64EmitAluRegImm(Buf, 7, True, X64_R9, Low(Int32));
    X64EmitAluRegImm(Buf, 6, False, X64_R11, Int32($9E3779B9));
    CheckSeq(Buf, [$41, $83, $C2, $7F, $41, $81, $C2, $80, $00, $00, $00,
      $41, $83, $C2, $80, $41, $81, $C2, $7F, $FF, $FF, $FF,
      $83, $E8, $01, $81, $E1, $FF, $3F, $00, $00,
      $49, $83, $CF, $FF, $49, $81, $F3, $FF, $FF, $FF, $7F,
      $41, $81, $F8, $00, $CA, $9A, $3B, $49, $81, $F9, $00, $00, $00, $80,
      $41, $81, $F3, $B9, $79, $37, $9E]);
  finally
    Buf.Free;
  end;

  { imul r11d,r8d,17 ; imul r10,r9,-129 ; imul eax,ecx,127 ;
    imul r12,r15,128 ; shl r9d,2 ; shr r10,63 ; sar eax,31 ; rol r11d,5 ;
    ror r8,1 (the C1 form). }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitImulRegImm(Buf, False, X64_R11, X64_R8, 17);
    X64EmitImulRegImm(Buf, True, X64_R10, X64_R9, -129);
    X64EmitImulRegImm(Buf, False, X64_RAX, X64_RCX, 127);
    X64EmitImulRegImm(Buf, True, X64_R12, X64_R15, 128);
    X64EmitShiftImm(Buf, 4, False, X64_R9, 2);
    X64EmitShiftImm(Buf, 5, True, X64_R10, 63);
    X64EmitShiftImm(Buf, 7, False, X64_RAX, 31);
    X64EmitShiftImm(Buf, 0, False, X64_R11, 5);
    X64EmitShiftImm(Buf, 1, True, X64_R8, 1);
    CheckSeq(Buf, [$45, $6B, $D8, $11, $4D, $69, $D1, $7F, $FF, $FF, $FF,
      $6B, $C1, $7F, $4D, $69, $E7, $80, $00, $00, $00,
      $41, $C1, $E1, $02, $49, $C1, $EA, $3F, $C1, $F8, $1F,
      $41, $C1, $C3, $05, $49, $C1, $C8, $01]);
  finally
    Buf.Free;
  end;

  { lea r10d,[r8+1] ; lea r11,[r9-129] ; lea eax,[rcx+0x7fffffff] ;
    lea r9d,[r13+0] (rbp/r13 force a disp8) ; lea r9d,[r12+4] (SIB) ;
    mov r10d,r8d ; mov eax,r11d ; mov r8d,eax. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitLeaRegDisp(Buf, False, X64_R10, X64_R8, 1);
    X64EmitLeaRegDisp(Buf, True, X64_R11, X64_R9, -129);
    X64EmitLeaRegDisp(Buf, False, X64_RAX, X64_RCX, $7FFFFFFF);
    X64EmitLeaRegDisp(Buf, False, X64_R9, X64_R13, 0);
    X64EmitLeaRegDisp(Buf, False, X64_R9, X64_R12, 4);
    X64EmitMovRegReg32(Buf, X64_R10, X64_R8);
    X64EmitMovRegReg32(Buf, X64_RAX, X64_R11);
    X64EmitMovRegReg32(Buf, X64_R8, X64_RAX);
    CheckSeq(Buf, [$45, $8D, $50, $01, $4D, $8D, $99, $7F, $FF, $FF, $FF,
      $8D, $81, $FF, $FF, $FF, $7F, $45, $8D, $4D, $00,
      $45, $8D, $4C, $24, $04,
      $45, $89, $C2, $44, $89, $D8, $41, $89, $C0]);
  finally
    Buf.Free;
  end;

  { Constants in their shortest exact form: xor r10d,r10d ;
    mov r10d,1 ; mov r11d,0xffffffff (zero-extends) ; mov rax,-1 ;
    mov r9,-2^31 (C7 /0 sign-extends) ; movabs r8,2^32 ;
    movabs r11,-2^31-1 ; movabs rax,0x7fffffffffffffff. }
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitMovRegConst(Buf, X64_R10, 0);
    X64EmitMovRegConst(Buf, X64_R10, 1);
    X64EmitMovRegConst(Buf, X64_R11, $FFFFFFFF);
    X64EmitMovRegConst(Buf, X64_RAX, UInt64(-1));
    X64EmitMovRegConst(Buf, X64_R9, UInt64(Int64(Low(Int32))));
    X64EmitMovRegConst(Buf, X64_R8, UInt64($100000000));
    X64EmitMovRegConst(Buf, X64_R11, UInt64(Int64(Low(Int32)) - 1));
    X64EmitMovRegConst(Buf, X64_RAX, UInt64(High(Int64)));
    CheckSeq(Buf, [$45, $31, $D2, $41, $BA, $01, $00, $00, $00,
      $41, $BB, $FF, $FF, $FF, $FF, $48, $C7, $C0, $FF, $FF, $FF, $FF,
      $49, $C7, $C1, $00, $00, $00, $80,
      $49, $B8, $00, $00, $00, $00, $01, $00, $00, $00,
      $49, $BB, $FF, $FF, $FF, $7F, $FF, $FF, $FF, $FF,
      $48, $B8, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $7F]);
  finally
    Buf.Free;
  end;

  { Which (op, constant) pairs have an immediate form: every i32 value;
    an i64 value only as a sign-extended imm32, except shift counts. }
  Expect<Boolean>(X64CanUseImmediate(iroI32Add, Int32($9E3779B9)))
    .ToBe(True);
  Expect<Boolean>(X64CanUseImmediate(iroI64Add, $7FFFFFFF)).ToBe(True);
  Expect<Boolean>(X64CanUseImmediate(iroI64And, $80000000)).ToBe(False);
  Expect<Boolean>(X64CanUseImmediate(iroI64Or, $FFFFFFFF)).ToBe(False);
  Expect<Boolean>(X64CanUseImmediate(iroI64Xor, Low(Int32))).ToBe(True);
  Expect<Boolean>(X64CanUseImmediate(iroI64Mul, Int64(Low(Int32)) - 1))
    .ToBe(False);
  Expect<Boolean>(X64CanUseImmediate(iroI64LtU, $100000000)).ToBe(False);
  Expect<Boolean>(X64CanUseImmediate(iroI64GeS, -129)).ToBe(True);
  Expect<Boolean>(X64CanUseImmediate(iroI64Shl, High(Int64))).ToBe(True);
  Expect<Boolean>(X64CanUseImmediate(iroI32Rotl, -1)).ToBe(True);
  Expect<Boolean>(X64CanUseImmediate(iroI32DivS, 3)).ToBe(False);
  Expect<Boolean>(X64CanUseImmediate(iroI32Eqz, 0)).ToBe(False);
end;

procedure TX64Tests.TestImmediateCachedOps;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0 .. 7] of UInt32;
  Visible: array[0 .. 7] of Boolean;
  Start: Integer;

  { Static hosts r8/r9 hold slots 0/1; slot 2 is a constant in r10 with
    AUses planned reads left. }
  procedure Setup(const AUses: UInt32);
  begin
    FillChar(UseCounts, SizeOf(UseCounts), 0);
    FillChar(Visible, SizeOf(Visible), 0);
    UseCounts[2] := AUses;
    Buf := TWasmCodeBuffer.Create;
    Buf.NewLabel;
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 8);
    Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroI32Const, 2, 0, 0,
      7), Aux, 0, False, False, Cache)).ToBe(True);
    Start := Buf.Size;
  end;

  procedure Emit(const AOp: TWasmIrOp; const ADest, AA: UInt32;
    const AValue: Int64);
  begin
    Expect<Boolean>(X64EmitOpCachedImmediate(Buf,
      MakeIrInstr(AOp, ADest, AA, 6, 0), AValue, Cache)).ToBe(True);
  end;

  procedure CheckAdded(const AExpected: array of Byte);
  var
    I: Integer;
  begin
    Expect<Integer>(Buf.Size - Start).ToBe(Length(AExpected));
    for I := 0 to High(AExpected) do
      if Start + I < Buf.Size then
        Expect<Byte>(Buf.ByteAt(Start + I)).ToBe(AExpected[I]);
    Buf.Free;
  end;

begin
  { The constant goes straight to its host: mov r10d, 7 (the two static
    loads before it are 7 bytes). }
  Setup(1);
  Start := 7;
  CheckAdded([$41, $BA, $07, $00, $00, $00]);

  { i64 constants beside the live r10, each previous one dead so r11 is
    reused: xor r11d,r11d ; mov r11,-1 (sign-extended imm32) ;
    movabs r11,2^32. }
  Setup(1);
  Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroI64Const, 3, 0, 0, 0),
    Aux, 0, False, False, Cache)).ToBe(True);
  Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroI64Const, 4, 0, 0,
    -1), Aux, 0, False, False, Cache)).ToBe(True);
  Expect<Boolean>(X64EmitOpCached(Buf, MakeIrInstr(iroI64Const, 5, 0, 0,
    $100000000), Aux, 0, False, False, Cache)).ToBe(True);
  CheckAdded([$45, $31, $DB, $49, $C7, $C3, $FF, $FF, $FF, $FF,
    $49, $BB, $00, $00, $00, $00, $01, $00, $00, $00]);

  { A static destination computes in place: add r8d, 1. }
  Setup(1);
  Emit(iroI32Add, 0, 0, 1);
  CheckAdded([$41, $83, $C0, $01]);

  { A dead dynamic operand's host takes the result in place:
    and r10d, 0x3fff. }
  Setup(1);
  Emit(iroI32And, 4, 2, $3FFF);
  CheckAdded([$41, $81, $E2, $FF, $3F, $00, $00]);
  Expect<Boolean>(Cache.Entries[2].Valid and (Cache.Entries[2].Slot = 4) and
    Cache.Entries[2].Dirty).ToBe(True);

  { A live operand keeps its host; add and sub become one lea into the
    other: lea r11d,[r10-129] ; lea r11d,[r10-5]. }
  Setup(3);
  Emit(iroI32Add, 4, 2, -129);
  Emit(iroI32Sub, 4, 2, 5);
  CheckAdded([$45, $8D, $9A, $7F, $FF, $FF, $FF, $45, $8D, $5A, $FB]);

  { An i64 sub of -2^31 has no imm32 negation: mov r11, r10 ;
    sub r11, -2^31. An i32 sub of INT32_MIN wraps: lea r11d,[r10-2^31]. }
  Setup(3);
  Emit(iroI64Sub, 4, 2, Low(Int32));
  Emit(iroI32Sub, 4, 2, Low(Int32));
  CheckAdded([$4D, $89, $D3, $49, $81, $EB, $00, $00, $00, $80,
    $45, $8D, $9A, $00, $00, $00, $80]);

  { Other ops copy first: mov r11, r10 ; xor r11d, 0x9e3779b9 ;
    imul is three-operand: imul r11d, r10d, 17. }
  Setup(3);
  Emit(iroI32Xor, 4, 2, Int32($9E3779B9));
  Emit(iroI32Mul, 4, 2, 17);
  CheckAdded([$4D, $89, $D3, $41, $81, $F3, $B9, $79, $37, $9E,
    $45, $6B, $DA, $11]);

  { Counts are masked as wasm masks them: i32 shl by 33 is shl r10d,1 ;
    i64 shr_u by -1 is shr r10,63. }
  Setup(2);
  Emit(iroI32Shl, 2, 2, 33);
  Emit(iroI64ShrU, 2, 2, -1);
  CheckAdded([$41, $C1, $E2, $01, $49, $C1, $EA, $3F]);

  { A zero masked count: an i32 rotr by 32 re-zero-extends
    (mov r10d, r10d); an i64 shl by 64 in place is nothing. }
  Setup(2);
  Emit(iroI32Rotr, 2, 2, 32);
  Emit(iroI64Shl, 2, 2, 64);
  CheckAdded([$45, $89, $D2]);

  { ... and into a distinct host (the operand stays live) it is a copy:
    mov r11, r10. }
  Setup(2);
  Emit(iroI64Shl, 4, 2, 64);
  CheckAdded([$4D, $89, $D3]);

  { cmp against the constant: xor r8d,r8d ; cmp r10d,1000000000 ;
    setb r8b. }
  Setup(1);
  Emit(iroI32LtU, 0, 2, 1000000000);
  CheckAdded([$45, $31, $C0, $41, $81, $FA, $00, $CA, $9A, $3B,
    $41, $0F, $92, $C0]);

  { Fused compare-branch against a constant: cmp r8, -1 ; (the dead
    constant is not stored) ; jl rel32. }
  Setup(0);
  X64EmitCompareBranchCached(Buf, MakeIrInstr(iroI64LtS, 5, 0, 6, 0),
    MakeIrInstr(iroBranchIf, 0, 5, 0, 0), Cache, True, -1);
  CheckAdded([$49, $83, $F8, $FF, $0F, $8C, $00, $00, $00, $00]);

  { An i64 value outside imm32 is declined and nothing is emitted. }
  Setup(1);
  Expect<Boolean>(X64EmitOpCachedImmediate(Buf,
    MakeIrInstr(iroI64And, 4, 2, 6, 0), $FFFFFFFF, Cache)).ToBe(False);
  CheckAdded([]);

  { Write-through pair: the operand misses into r8, lea into r9, and the
    result is stored: mov r8,[rbx+16] ; lea r9d,[r8+1] ; mov [rbx+24],r9. }
  Buf := TWasmCodeBuffer.Create;
  X64InitRegCache(Cache);
  Start := 0;
  Emit(iroI32Add, 3, 2, 1);
  CheckAdded([$4C, $8B, $43, $10, $45, $8D, $48, $01, $4C, $89, $4B, $18]);
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
  { Representative ops from every wave must be compilable. }
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

procedure TX64Tests.TestPredicateEmitsEh;
begin
  { throw / throw_ref compile; matching stays in UnwindException. }
  Expect<Boolean>(X64CanEmitOp(iroThrow)).ToBe(True);
  Expect<Boolean>(X64CanEmitOp(iroThrowRef)).ToBe(True);
end;

{ With call and return_call* arity encoded, the op template is the only
  compile fence (JitCompileDecline), so an IR op without one would make
  strict compilation decline a valid module (ADR-0015, issue #33). The
  failure lists the ordinals of the ops missing a template. }
procedure TX64Tests.TestEveryIrOpHasTemplate;
var
  Op: TWasmIrOp;
  Missing: string;
begin
  Missing := '';
  for Op := Low(TWasmIrOp) to High(TWasmIrOp) do
    if not X64CanEmitOp(Op) then
      Missing := Missing + ' ' + IntToStr(Ord(Op));
  Expect<string>(Missing).ToBe('');
end;

{ v128 xmm cache encodings, SDM Vol. 2: MOVDQA xmm1, xmm2/m128 = 66 0F 6F /r;
  PXOR = 66 0F EF /r; PCMPEQD = 66 0F 76 /r; MOVQ xmm, r/m64 = 66 REX.W 0F
  6E /r; PUNPCKLQDQ = 66 0F 6C /r; REX.R extends ModRM.reg, REX.B ModRM.rm. }
procedure TX64Tests.TestVecCacheEncodings;
var
  Buf: TWasmCodeBuffer;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    X64EmitVecMove(Buf, 2, 15);
    X64EmitVecMove(Buf, 15, 3);
    X64EmitVecMove(Buf, 0, 2);
    X64EmitVecConst(Buf, 3, 0, 0);
    X64EmitVecConst(Buf, 9, High(UInt64), High(UInt64));
    X64EmitVecConst(Buf, 14, UInt64($0000000200000001),
      UInt64($0000000400000003));
    CheckSeq(Buf, [$66, $41, $0F, $6F, $D7,        { movdqa xmm2, xmm15 }
      $66, $44, $0F, $6F, $FB,                     { movdqa xmm15, xmm3 }
      $66, $0F, $6F, $C2,                          { movdqa xmm0, xmm2 }
      $66, $0F, $EF, $DB,                          { pxor xmm3, xmm3 }
      $66, $45, $0F, $76, $C9,                     { pcmpeqd xmm9, xmm9 }
      $48, $B8, $01, $00, $00, $00, $02, $00, $00, $00,
      $66, $4C, $0F, $6E, $F0,                     { movq xmm14, rax }
      $48, $B8, $03, $00, $00, $00, $04, $00, $00, $00,
      $66, $48, $0F, $6E, $C0,                     { movq xmm0, rax }
      $66, $44, $0F, $6C, $F0]);                   { punpcklqdq xmm14, xmm0 }
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestVecCacheLoopBody;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..31] of UInt32;
  Visible: array[0..31] of Boolean;
  Start, Mark: Integer;
begin
  { The simd loop's shape: v128 local 4 in a fixed host, the loop-invariant
    constant 6 seeded once, temporaries 8 and 10 dying inside the body, and
    a visible result 14. }
  Aux := nil;
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Visible[0] := True;
  Visible[1] := True;
  Visible[4] := True;
  Visible[14] := True;
  UseCounts[4] := 2;
  UseCounts[6] := 2;
  UseCounts[8] := 1;
  UseCounts[10] := 1;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 32);
    Start := Buf.Size;
    X64EnableVecCache(Buf, Cache, [4], [6], [UInt64($0000000200000001)],
      [UInt64($0000000400000003)]);
    Expect<Integer>(Buf.Size - Start).ToBe(41);
    Expect<Integer>(FindSeq(Buf, [$F3, $44, $0F, $6F, $7B, $20,
      $48, $B8, $01, $00, $00, $00, $02, $00, $00, $00,
      $66, $4C, $0F, $6E, $F0,
      $48, $B8, $03, $00, $00, $00, $04, $00, $00, $00,
      $66, $48, $0F, $6E, $C0,
      $66, $44, $0F, $6C, $F0], Start)).ToBe(Start);
    Expect<Boolean>(Cache.VecEntries[13].Fixed and
      not Cache.VecEntries[13].Constant and
      (Cache.VecEntries[13].Slot = 4)).ToBe(True);
    Expect<Boolean>(Cache.VecEntries[12].Fixed and
      Cache.VecEntries[12].Constant and
      (Cache.VecEntries[12].Slot = 6)).ToBe(True);

    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroMoveVec, 8, 4, 0, 0), Aux, 0,
      False, False, Cache);
    { The hoisted constant's defining instruction emits nothing. }
    X64EmitOpCached(Buf, MakeIrInstr(iroV128Const, 6, 0, 0, 0), Aux, 1,
      False, False, Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4Add, 10, 8, 6, 0), Aux, 2,
      False, False, Cache);
    X64EmitOpCached(Buf, MakeIrInstr(iroMoveVec, 4, 10, 0, 0), Aux, 3,
      False, False, Cache);
    Expect<Integer>(Buf.Size - Start).ToBe(19);
    Expect<Integer>(FindSeq(Buf, [$66, $41, $0F, $6F, $D7, { movdqa xmm2,xmm15 }
      $66, $0F, $6F, $DA,                          { movdqa xmm3, xmm2 }
      $66, $41, $0F, $FE, $DE,                     { paddd xmm3, xmm14 }
      $66, $44, $0F, $6F, $FB], Start)).ToBe(Start); { movdqa xmm15, xmm3 }
    Expect<UInt32>(UseCounts[8]).ToBe(0);
    Expect<UInt32>(UseCounts[10]).ToBe(0);
    { Dead temporaries and the fixed local need no write-back. }
    Mark := Buf.Size;
    X64FlushDynamicRegCache(Buf, Cache);
    Expect<Integer>(Buf.Size).ToBe(Mark);

    { A visible result is written back at the next canonical point. }
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4Sub, 14, 4, 6, 0), Aux, 4,
      False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$66, $41, $0F, $6F, $E7, { movdqa xmm4,xmm15 }
      $66, $41, $0F, $FA, $E6], Start)).ToBe(Start); { psubd xmm4, xmm14 }
    Mark := Buf.Size;
    X64FlushDynamicRegCache(Buf, Cache);
    Expect<Integer>(Buf.Size - Mark).ToBe(5);
    Expect<Integer>(FindSeq(Buf, [$F3, $0F, $7F, $63, $70], Mark))
      .ToBe(Mark);                                 { movdqu [rbx+0x70], xmm4 }
    { A join drops the dynamic entries and keeps the fixed hosts. }
    X64InvalidateRegCache(Cache);
    Expect<Boolean>(Cache.VecEntries[0].Valid or Cache.VecEntries[1].Valid or
      Cache.VecEntries[2].Valid).ToBe(False);
    Expect<Boolean>(Cache.VecEntries[12].Valid and
      Cache.VecEntries[13].Valid).ToBe(True);
    { An exit stores the scalar statics only: a fixed v128 host holds a local
      or a constant temporary, neither of which an exit reads. }
    Mark := Buf.Size;
    X64FlushRegCache(Buf, Cache);
    Expect<Integer>(FindSeq(Buf, [$0F, $7F], Mark)).ToBe(-1);
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestVecCacheOperandHazards;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..255] of UInt32;
  Visible: array[0..255] of Boolean;
  Start: Integer;

  { Every dynamic host but xmm2 (slot 20) and xmm3 (slot 22) holds a live
    value, so victim choice is forced. ADirty makes every value dirty. }
  procedure Reset(const ANext: Byte; const ADirty: Boolean);
  var
    K: Integer;
  begin
    FillChar(UseCounts, SizeOf(UseCounts), 0);
    FillChar(Visible, SizeOf(Visible), 0);
    Buf.Free;
    Buf := TWasmCodeBuffer.Create;
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 256);
    X64EnableVecCache(Buf, Cache, [], [], [], []);
    for K := 0 to High(Cache.VecEntries) do
    begin
      Cache.VecEntries[K].Valid := True;
      Cache.VecEntries[K].Dirty := ADirty;
      Cache.VecEntries[K].Slot := UInt32(100 + 2 * K);
      UseCounts[100 + 2 * K] := 1;
    end;
    Cache.VecEntries[0].Slot := 20;
    Cache.VecEntries[1].Slot := 22;
    UseCounts[20] := 1;
    UseCounts[22] := 1;
    Cache.VecNext := ANext;
  end;

begin
  Aux := nil;
  Buf := nil;
  try
    { Result host = right operand host of a non-commutative op: compute in
      xmm0 so the right operand is not overwritten first. }
    Reset(1, False);
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4Sub, 24, 20, 22, 0), Aux, 0,
      False, False, Cache);
    Expect<Integer>(Buf.Size - Start).ToBe(12);
    Expect<Integer>(FindSeq(Buf, [$66, $0F, $6F, $C2, { movdqa xmm0, xmm2 }
      $66, $0F, $FA, $C3,                          { psubd xmm0, xmm3 }
      $66, $0F, $6F, $D8], Start)).ToBe(Start);    { movdqa xmm3, xmm0 }
    Expect<Boolean>(Cache.VecEntries[1].Dirty and
      (Cache.VecEntries[1].Slot = 24)).ToBe(True);

    { andnot(a, b) = PANDN with b in the destination. Result host = a's. }
    Reset(0, False);
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroV128Andnot, 24, 20, 22, 0), Aux, 0,
      False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$66, $0F, $6F, $C3, { movdqa xmm0, xmm3 }
      $66, $0F, $DF, $C2,                          { pandn xmm0, xmm2 }
      $66, $0F, $6F, $D0], Start)).ToBe(Start);    { movdqa xmm2, xmm0 }
    { Result host = b's: PANDN in place. }
    Reset(1, False);
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroV128Andnot, 24, 20, 22, 0), Aux, 0,
      False, False, Cache);
    Expect<Integer>(Buf.Size - Start).ToBe(4);
    Expect<Integer>(FindSeq(Buf, [$66, $0F, $DF, $DA], Start))
      .ToBe(Start);                                { pandn xmm3, xmm2 }

    { A missed right operand never evicts the left operand's host, even
      once the left operand's last planned read makes it the cheapest. }
    Reset(0, False);
    Cache.VecEntries[1].Slot := 98;
    UseCounts[98] := 1;
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4Add, 24, 20, 22, 0), Aux, 0,
      False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$F3, $0F, $6F, $9B, $B0, $00, $00, $00,
      $66, $0F, $FE, $D3], Start)).ToBe(Start);    { movdqu xmm3,[rbx+0xB0] }
                                                   { paddd xmm2, xmm3 }

    { Evicting a dirty value that is still read later writes it back first:
      slot 110 from xmm7 (movdqu [rbx+0x370], xmm7). }
    Reset(5, True);
    UseCounts[20] := 2;
    UseCounts[22] := 2;
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4Add, 24, 20, 22, 0), Aux, 0,
      False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$F3, $0F, $7F, $BB, $70, $03, $00, $00,
      $66, $0F, $6F, $FA,                          { movdqa xmm7, xmm2 }
      $66, $0F, $FE, $FB], Start)).ToBe(Start);    { paddd xmm7, xmm3 }
  finally
    Buf.Free;
  end;
end;

procedure TX64Tests.TestVecCacheExtractAndSplat;
var
  Aux: TWasmIrAuxU32;
  Buf: TWasmCodeBuffer;
  Cache: TX64RegCache;
  UseCounts: array[0..63] of UInt32;
  Visible: array[0..63] of Boolean;
  Start: Integer;
begin
  Aux := nil;
  FillChar(UseCounts, SizeOf(UseCounts), 0);
  FillChar(Visible, SizeOf(Visible), 0);
  Visible[0] := True;
  Visible[1] := True;
  UseCounts[20] := 4;
  Buf := TWasmCodeBuffer.Create;
  try
    X64EnableStaticRegCache(Buf, Cache, [0, 1]);
    X64EnableDynamicWriteBack(Cache, @UseCounts[0], @Visible[0], 64);
    X64EnableVecCache(Buf, Cache, [], [], [], []);
    Cache.VecEntries[0].Valid := True;
    Cache.VecEntries[0].Slot := 20;
    Cache.VecNext := 1;
    { A non-zero lane shifts a copy in xmm0; the source host is intact. }
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4ExtractLane, 3, 20, 0, 2), Aux,
      0, False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$66, $0F, $6F, $C2, { movdqa xmm0, xmm2 }
      $66, $0F, $73, $D8, $08,                     { psrldq xmm0, 8 }
      $66, $0F, $7E, $C0], Start)).ToBe(Start);    { movd eax, xmm0 }
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI8x16ExtractLaneS, 5, 20, 0, 5), Aux,
      1, False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$66, $0F, $6F, $C2,
      $66, $0F, $73, $D8, $05,                     { psrldq xmm0, 5 }
      $66, $0F, $7E, $C0,
      $0F, $BE, $C0], Start)).ToBe(Start);         { movsx eax, al }
    { Lane 0 reads the host directly. }
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4ExtractLane, 7, 20, 0, 0), Aux,
      2, False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$66, $0F, $7E, $D0], Start))
      .ToBe(Start);                                { movd eax, xmm2 }
    Expect<Integer>(FindSeq(Buf, [$66, $0F, $73, $DA])).ToBe(-1);
    Expect<UInt32>(UseCounts[20]).ToBe(1);
    { Splats read the scalar cache hosts: r8 (static slot 0), r9 (slot 1). }
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI32x4Splat, 26, 0, 0, 0), Aux, 3,
      False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$66, $41, $0F, $6E, $D8, { movd xmm3, r8d }
      $66, $0F, $70, $DB, $00], Start)).ToBe(Start); { pshufd xmm3,xmm3,0 }
    Start := Buf.Size;
    X64EmitOpCached(Buf, MakeIrInstr(iroI64x2Splat, 28, 1, 0, 0), Aux, 4,
      False, False, Cache);
    Expect<Integer>(FindSeq(Buf, [$66, $49, $0F, $6E, $E1, { movq xmm4, r9 }
      $66, $0F, $6C, $E4], Start)).ToBe(Start);    { punpcklqdq xmm4, xmm4 }
  finally
    Buf.Free;
  end;
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
  Test('multi-byte NOP padding uses the SDM forms', TestNopForms);
  Test('loop-head alignment lands on the configured block offset',
    TestAlignCode);
  Test('the epoch back-edge branches to the head and traps on fall-through',
    TestEpochBackEdgeBytes);
  Test('the prologue emits the asserted byte sequence', TestPrologueBytes);
  Test('the epilogue emits the asserted byte sequence', TestEpilogueBytes);
  Test('the epoch capture emits the asserted bytes', TestEpochCaptureBytes);
  Test('the epoch-check load+compare core emits the asserted bytes',
    TestEpochCheckCoreBytes);
  Test('the native self-call frame emits the asserted bytes',
    TestNativeSelfCallBytes);
  Test('the native core defers parameter and temporary stores',
    TestNativeCoreWriteBack);
  Test('a static caller moves four leaf arguments, constants, and the Base',
    TestNativeLeafCallPlans);
  Test('a memory leaf core addresses rsi and converts widths in its hosts',
    TestNativeLeafMemoryCore);
  Test('a static caller moves leaf arguments and adopts the result',
    TestNativeLeafCallStaticMoves);
  Test('the runtime/vec helper-call marshaling emits the asserted bytes',
    TestRuntimeCallMarshalBytes);
  Test('helper calls and the IR pointer are position-independent',
    TestPositionIndependentSequences);
  Test('slot byte offset is register*8', TestSlotOffset);
  Test('predicate covers waves 2-6 including throw and throw_ref',
    TestPredicateCoversWaves);
  Test('predicate emits exception-handling ops', TestPredicateEmitsEh);
  Test('every IR op has an x86-64 template', TestEveryIrOpHasTemplate);
  Test('static allocation keeps a shifted expression result',
    TestStaticCacheKeepsShiftResult);
  Test('static allocation defers dynamic stores and evicts dead values first',
    TestStaticCacheDefersDynamicStores);
  Test('base-pinned scalar memory uses rsi plus cached operands',
    TestStaticCachePinnedMemoryBytes);
  Test('static allocation fixes four hosts: r8, r9, rdi, and rdx',
    TestStaticCacheFourFixedHosts);
  Test('a pinned access skips the address copy only for a 32-bit-written host',
    TestStaticCacheAddressZeroExtension);
  Test('an i32.load feeding an ALU op becomes its memory operand',
    TestStaticCacheLoadAluFusion);
  Test('scaled-index loads and stores emit the asserted SIB bytes',
    TestScaledIndexEncodings);
  Test('a scaled pinned access zero-extends a non-Zx32 index first',
    TestScaledIndexPinnedAccess);
  Test('direct-operand ALU, compare, setcc, and movzx encodings',
    TestDirectOperandEncodings);
  Test('cached ALU and compares compute on the cache hosts',
    TestDirectOperandCachedOps);
  Test('direct operands keep victims, spills, and write-through stores',
    TestDirectOperandBookkeeping);
  Test('immediate ALU, imul, shift, lea, and constant encodings',
    TestImmediateEncodings);
  Test('fused constants use immediate forms under every cache mode',
    TestImmediateCachedOps);
  Test('numeric GC fields use baked native x64 loads and stores',
    TestGcFieldAccessBytes);
  Test('fixed scalar arrays use native x64 loads and stores',
    TestGcArrayAccessBytes);
  Test('v128 cache register moves and constants emit the asserted bytes',
    TestVecCacheEncodings);
  Test('a cached v128 loop body keeps values in xmm hosts',
    TestVecCacheLoopBody);
  Test('cached v128 ops keep operands live through victim choice',
    TestVecCacheOperandHazards);
  Test('cached lane extracts and splats keep their sources intact',
    TestVecCacheExtractAndSplat);
  Test('executable proof is gated to a real x86-64 host', TestExecPlaceholder);
end;

begin
  TestRunnerProgram.AddSuite(TX64Tests.Create('Wasm.Jit.X64'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
