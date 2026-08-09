{ Unit suite for Wasm.Ir — the IR's shape, not its production.

  Three things here are load-bearing rather than incidental:

  1. TWasmIrOp is DENSE and its ordinals are a wire format for AOT
     artifacts, so the member count and several pinned ordinals are
     asserted directly. Inserting a member in the middle renumbers every
     later op and must fail here rather than in a cached artifact.
  2. IR_OP_INFO is an enum-indexed constant array, and FPC does not warn
     about a short initialiser for one. Totality is asserted.
  3. The Describe format is a TEST SURFACE: the validator suites assert
     emitted IR as disassembled text, so the rendering of every operand
     family is pinned here with literal expected strings. }
program Wasm.Ir.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Ir;

type
  TIrTests = class(TTestSuite)
  private
    { Builds a function whose Code is AInstrs; every other field stays at
      its zero value unless the test sets it. }
    procedure SetCode(var AFn: TWasmIrFunction;
      const AInstrs: array of TWasmIrInstr);
    { Asserts the whole-function listing, one line per instruction. }
    procedure ExpectListing(const AFn: TWasmIrFunction;
      const ALines: array of string);
  public
    procedure SetupTests; override;

    procedure TestEnumIsDenseAndComplete;
    procedure TestEnumOrdinalsArePinned;
    procedure TestOpInfoIsTotal;
    procedure TestOpInfoFieldKindsPerFamily;
    procedure TestInstructionRecordLayout;
    procedure TestPackedIndexRoundTrip;
    procedure TestFloatImmediatesAreBitPatterns;
    procedure TestAuxBlocksRoundTrip;
    procedure TestBuildPrimitivesGrowAndTrim;
    procedure TestBuildPrimitivesTolerateSelfAliasing;
    procedure TestSafepointClassification;
    procedure TestReferenceRegisterBitset;
    procedure TestFormatVersionIsStamped;

    procedure TestDescribeArithmeticAndConstants;
    procedure TestDescribeBranchesAndSafepoint;
    procedure TestDescribeBrTableAuxBlock;
    procedure TestDescribeCallArgumentAndResultLists;
    procedure TestDescribeMemoryAndPackedImmediates;
    procedure TestDescribeIndexSpacesAndAuxLists;
    procedure TestDescribeReferenceTypes;
    procedure TestDescribeSentinelsAndSingleInstruction;
    procedure TestDescribeEmptyAuxBlocks;
    procedure TestDescribeInitExpression;
  end;

procedure TIrTests.SetCode(var AFn: TWasmIrFunction;
  const AInstrs: array of TWasmIrInstr);
var
  I: Integer;
begin
  SetLength(AFn.Code, Length(AInstrs));
  for I := 0 to High(AInstrs) do
    AFn.Code[I] := AInstrs[I];
end;

procedure TIrTests.ExpectListing(const AFn: TWasmIrFunction;
  const ALines: array of string);
var
  Expected: string;
  I: Integer;
begin
  { LF-separated, no trailing LF — DescribeIrFunction's contract. }
  Expected := '';
  for I := 0 to High(ALines) do
  begin
    if I > 0 then
      Expected := Expected + #10;
    Expected := Expected + ALines[I];
  end;
  Expect<string>(DescribeIrFunction(AFn)).ToBe(Expected);
end;

{ --- enum and table integrity -------------------------------------------- }

procedure TIrTests.TestEnumIsDenseAndComplete;
begin
  { 241 non-vector instructions in the pinned 3.0 draft, minus 11 that
    vanish at lowering and 3 that collapse into an existing member, plus 4
    IR-only ops. }
  Expect<Integer>(Ord(Low(TWasmIrOp))).ToBe(0);
  Expect<Integer>(Ord(High(TWasmIrOp)) + 1).ToBe(231);
  { Two bytes by the PACKENUM 2 directive, which is what keeps
    TWasmIrInstr at 24. }
  Expect<Integer>(SizeOf(TWasmIrOp)).ToBe(2);
end;

procedure TIrTests.TestEnumOrdinalsArePinned;
begin
  { The four IR-only ops lead, so an interpreter's hottest cases sit at
    the bottom of the jump table. }
  Expect<Integer>(Ord(iroMove)).ToBe(0);
  Expect<Integer>(Ord(iroJump)).ToBe(1);
  Expect<Integer>(Ord(iroBranchIf)).ToBe(2);
  Expect<Integer>(Ord(iroBranchIfNot)).ToBe(3);
  Expect<Integer>(Ord(iroUnreachable)).ToBe(4);
  Expect<Integer>(Ord(iroI31GetU)).ToBe(230);

  { Group boundaries. The load and store families are contiguous because
    the disassembler dispatches them as ranges. }
  Expect<Integer>(Ord(iroI64Load32U) - Ord(iroI32Load)).ToBe(13);
  Expect<Integer>(Ord(iroI64Store32) - Ord(iroI32Store)).ToBe(8);
  Expect<Integer>(Ord(iroI32Store) - Ord(iroI64Load32U)).ToBe(1);
  Expect<Integer>(Ord(iroI32Load)).ToBe(30);
  Expect<Integer>(Ord(iroI32Const)).ToBe(59);
  Expect<Integer>(Ord(iroRefNull)).ToBe(199);
  Expect<Integer>(Ord(iroStructNew)).ToBe(206);
  Expect<Integer>(Ord(iroArrayNew)).ToBe(212);

  { select has one member for its two binary encodings; ref.test and
    ref.cast likewise, since the encodings differ only in a reference type
    carried in AuxRefTypes. }
  Expect<Integer>(Ord(iroGlobalGet) - Ord(iroSelect)).ToBe(1);
  Expect<Integer>(Ord(iroRefCast) - Ord(iroRefTest)).ToBe(1);
end;

procedure TIrTests.TestOpInfoIsTotal;
var
  Op: TWasmIrOp;
  I, J: Integer;
  Duplicates: Integer;
begin
  Expect<Integer>(Length(IR_OP_INFO)).ToBe(Ord(High(TWasmIrOp)) + 1);

  for Op := Low(TWasmIrOp) to High(TWasmIrOp) do
    Expect<Boolean>(IR_OP_INFO[Op].Mnemonic <> '').ToBe(True);

  { A copy-pasted row is the realistic way this table goes wrong, and a
    duplicated mnemonic is what it looks like. The loop counts in Integer
    rather than TWasmIrOp because Succ(High(enum)) is a range error. }
  Duplicates := 0;
  for I := 0 to Ord(High(TWasmIrOp)) do
    for J := I + 1 to Ord(High(TWasmIrOp)) do
      if IR_OP_INFO[TWasmIrOp(I)].Mnemonic
        = IR_OP_INFO[TWasmIrOp(J)].Mnemonic then
        Inc(Duplicates);
  Expect<Integer>(Duplicates).ToBe(0);

  Expect<string>(IrOpMnemonic(iroI32Add)).ToBe('i32.add');
  Expect<string>(IrOpMnemonic(iroBranchIfNot)).ToBe('branch_if_not');
end;

procedure TIrTests.TestOpInfoFieldKindsPerFamily;
begin
  { One op per family, chosen where the field meaning is NOT what the
    field name suggests — those are the entries a reader would guess
    wrong. }

  { iroJump's A is a code index and its Imm is a bit field. }
  Expect<Boolean>(IR_OP_INFO[iroJump].AKind = ifkInstrIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroJump].ImmKind = ifkFlags).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroJump].DestKind = ifkUnused).ToBe(True);

  { A store's Dest holds the value being stored — a SOURCE register. }
  Expect<Boolean>(IR_OP_INFO[iroI32Store].DestKind = ifkSrcReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI32Store].BKind = ifkMemIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI32Load].DestKind = ifkDestReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI32Load].ImmKind = ifkImmValue).ToBe(True);

  { select is the only op with a register in Imm. }
  Expect<Boolean>(IR_OP_INFO[iroSelect].ImmKind = ifkSrcReg).ToBe(True);

  { A call's Dest names the callee, not a result; results are an aux
    block, uniformly, even for one result. }
  Expect<Boolean>(IR_OP_INFO[iroCall].DestKind = ifkUnused).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroCall].AKind = ifkAuxIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroCall].BKind = ifkAuxIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroCallIndirect].DestKind = ifkSrcReg)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroCallIndirect].ImmKind = ifkPacked)
    .ToBe(True);

  { Three sources and no destination occupy Dest, A, B in wasm operand
    order — the deepest stack operand lands in Dest. }
  Expect<Boolean>(IR_OP_INFO[iroTableFill].DestKind = ifkSrcReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroMemoryFill].DestKind = ifkSrcReg)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroArraySet].DestKind = ifkSrcReg).ToBe(True);

  { Four and five operands do not fit three fields, so they use aux. }
  Expect<Boolean>(IR_OP_INFO[iroArrayCopy].AKind = ifkAuxIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroArrayFill].AKind = ifkAuxIndex).ToBe(True);

  { Numeric unary/binary are the uniform shapes. }
  Expect<Boolean>(IR_OP_INFO[iroI32Eqz].BKind = ifkUnused).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI32Add].BKind = ifkSrcReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI32Add].ImmKind = ifkUnused).ToBe(True);

  { Casts carry rt2 in AuxRefTypes, never in the instruction. }
  Expect<Boolean>(IR_OP_INFO[iroRefTest].ImmKind = ifkRefTypeIndex)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroBrOnCast].ImmKind = ifkRefTypeIndex)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroBrOnCast].BKind = ifkInstrIndex).ToBe(True);

  { br_on_non_null delivers the reference to the label, so it has no
    fall-through refinement; br_on_null does. }
  Expect<Boolean>(IR_OP_INFO[iroBrOnNonNull].DestKind = ifkUnused)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroBrOnNull].DestKind = ifkDestReg).ToBe(True);

  { ref.null carries no heap type — the static type is in RegTypes. }
  Expect<Boolean>(IR_OP_INFO[iroRefNull].ImmKind = ifkUnused).ToBe(True);

  { Index-space immediates. }
  Expect<Boolean>(IR_OP_INFO[iroGlobalSet].ImmKind = ifkGlobalIndex)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroElemDrop].ImmKind = ifkElemIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroDataDrop].ImmKind = ifkDataIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroThrow].ImmKind = ifkTagIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroRefFunc].ImmKind = ifkFuncIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroStructGet].ImmKind = ifkPacked).ToBe(True);
end;

procedure TIrTests.TestInstructionRecordLayout;
var
  Instr: TWasmIrInstr;
begin
  { 2 bytes Op + 2 padding + 3x4 + 8. A new field that changes this
    changes every AOT artifact's layout. }
  Expect<Integer>(SizeOf(TWasmIrInstr)).ToBe(24);

  Instr := MakeIrInstr(iroI32Add, 4, 2, 3, 0);
  Expect<Boolean>(Instr.Op = iroI32Add).ToBe(True);
  Expect<Int64>(Int64(Instr.Dest)).ToBe(4);
  Expect<Int64>(Int64(Instr.A)).ToBe(2);
  Expect<Int64>(Int64(Instr.B)).ToBe(3);
  Expect<Int64>(Instr.Imm).ToBe(0);

  { The two sentinels are distinct names for the same all-ones word; a
    reader must not treat one as a valid register or block index. }
  Expect<Int64>(Int64(IR_NO_REG)).ToBe($FFFFFFFF);
  Expect<Int64>(Int64(IR_NO_AUX)).ToBe($FFFFFFFF);
  Expect<Int64>(IR_JUMP_SAFEPOINT).ToBe(1);
end;

procedure TIrTests.TestPackedIndexRoundTrip;
var
  LowIdx, HighIdx: UInt32;
begin
  { The boundaries are where a signed/unsigned slip shows: $FFFFFFFF in
    the high half makes Imm negative as an Int64, and the low half must
    still come back unchanged. }
  IrUnpack(IrPack(0, 0), LowIdx, HighIdx);
  Expect<Int64>(Int64(LowIdx)).ToBe(0);
  Expect<Int64>(Int64(HighIdx)).ToBe(0);

  IrUnpack(IrPack(4, 0), LowIdx, HighIdx);
  Expect<Int64>(Int64(LowIdx)).ToBe(4);
  Expect<Int64>(Int64(HighIdx)).ToBe(0);

  IrUnpack(IrPack($FFFFFFFF, 0), LowIdx, HighIdx);
  Expect<Int64>(Int64(LowIdx)).ToBe($FFFFFFFF);
  Expect<Int64>(Int64(HighIdx)).ToBe(0);

  IrUnpack(IrPack(0, $FFFFFFFF), LowIdx, HighIdx);
  Expect<Int64>(Int64(LowIdx)).ToBe(0);
  Expect<Int64>(Int64(HighIdx)).ToBe($FFFFFFFF);

  IrUnpack(IrPack($FFFFFFFF, $FFFFFFFF), LowIdx, HighIdx);
  Expect<Int64>(Int64(LowIdx)).ToBe($FFFFFFFF);
  Expect<Int64>(Int64(HighIdx)).ToBe($FFFFFFFF);

  IrUnpack(IrPack($80000000, $7FFFFFFF), LowIdx, HighIdx);
  Expect<Int64>(Int64(LowIdx)).ToBe($80000000);
  Expect<Int64>(Int64(HighIdx)).ToBe($7FFFFFFF);

  { Low really is low: the doc pins which index goes where per op, so the
    halves must not be swapped by the primitive. }
  Expect<Int64>(IrPack(1, 0)).ToBe(1);
  Expect<Int64>(IrPack(0, 1)).ToBe(Int64(1) shl 32);
end;

procedure TIrTests.TestFloatImmediatesAreBitPatterns;
var
  Bits: Int64;
begin
  { 1.0 is 0x3FF0000000000000 as an f64 — a value round-trip, not a
    numeric conversion. }
  Expect<Int64>(IrF64Bits(1.0)).ToBe(Int64($3FF0000000000000));
  Expect<Boolean>(IrBitsAsF64(Int64($3FF0000000000000)) = 1.0).ToBe(True);

  { An f32 pattern is ZERO-extended, so the high half stays clear and two
    identical patterns compare equal as Imm. }
  Bits := IrF32Bits(1.0);
  Expect<Int64>(Bits).ToBe($3F800000);
  Expect<Boolean>(IrBitsAsF32(Bits) = 1.0).ToBe(True);

  { A signalling-NaN payload survives, which is the whole reason floats
    are stored as bits: assert_return distinguishes canonical from
    arithmetic NaNs. }
  Bits := IrF64Bits(IrBitsAsF64(Int64($7FF0000000000001)));
  Expect<Int64>(Bits).ToBe(Int64($7FF0000000000001));
end;

procedure TIrTests.TestAuxBlocksRoundTrip;
var
  Aux: TWasmIrAuxU32;
  First, Second, Empty: UInt32;
begin
  Aux := nil;
  First := IrAppendAuxBlock(Aux, [1, 2]);
  Second := IrAppendAuxBlock(Aux, [7]);
  Empty := IrAppendAuxBlock(Aux, []);

  { A block at k is [count, items...] at k .. k+count, so the next block
    starts at k + 1 + count. No reader ever needs a count from elsewhere. }
  Expect<Int64>(Int64(First)).ToBe(0);
  Expect<Int64>(Int64(Second)).ToBe(3);
  Expect<Int64>(Int64(Empty)).ToBe(5);
  Expect<Integer>(Length(Aux)).ToBe(6);

  Expect<Int64>(Int64(IrAuxBlockCount(Aux, First))).ToBe(2);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, First, 0))).ToBe(1);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, First, 1))).ToBe(2);
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, Second))).ToBe(1);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, Second, 0))).ToBe(7);
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, Empty))).ToBe(0);

  { Reading past a block, or through the "no block" sentinel, yields the
    empty answer rather than raising: the disassembler runs on
    half-constructed IR in diagnostics. }
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, First, 2))).ToBe(Int64(IR_NO_REG));
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, IR_NO_AUX))).ToBe(0);
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, 99))).ToBe(0);
end;

procedure TIrTests.TestBuildPrimitivesGrowAndTrim;
var
  Code: TWasmIrCode;
  RegTypes: TWasmIrRegTypes;
  Aux: TWasmIrAuxU32;
  CodeCount, RegCount, AuxCount, I: Integer;
  Block: UInt32;
begin
  { The (array, live-count) contract: Length is the CAPACITY while
    building and runs ahead of the count, so nothing may read the array by
    Length until IrTrim* has been called. }
  Code := nil;
  CodeCount := 0;
  for I := 0 to 39 do
    Expect<Int64>(Int64(IrEmitInstr(Code, CodeCount,
      MakeIrInstr(iroI32Const, UInt32(I), IR_NO_REG, IR_NO_REG,
        Int64(I))))).ToBe(Int64(I));

  Expect<Integer>(CodeCount).ToBe(40);
  { Geometric, so 40 appends cost a handful of reallocations rather than
    40 — the whole reason the primitive exists. }
  Expect<Boolean>(Length(Code) > CodeCount).ToBe(True);
  IrTrimCode(Code, CodeCount);
  Expect<Integer>(Length(Code)).ToBe(40);
  Expect<Int64>(Code[39].Imm).ToBe(39);
  { Trimming twice is a no-op, not a truncation. }
  IrTrimCode(Code, CodeCount);
  Expect<Integer>(Length(Code)).ToBe(40);

  RegTypes := nil;
  RegCount := 0;
  for I := 0 to 39 do
    Expect<Int64>(Int64(IrAllocReg(RegTypes, RegCount,
      MakeNumValueType(wntI32)))).ToBe(Int64(I));
  Expect<Integer>(RegCount).ToBe(40);
  Expect<Boolean>(Length(RegTypes) > RegCount).ToBe(True);
  IrTrimRegTypes(RegTypes, RegCount);
  Expect<Integer>(Length(RegTypes)).ToBe(40);

  { The aux form advances the count PAST the block it wrote, so the next
    block starts where the reader's `k + 1 + count` walk expects it. }
  Aux := nil;
  AuxCount := 0;
  Block := IrAppendAuxBlockGrowing(Aux, AuxCount, [1, 2]);
  Expect<Int64>(Int64(Block)).ToBe(0);
  Expect<Integer>(AuxCount).ToBe(3);
  Block := IrAppendAuxBlockGrowing(Aux, AuxCount, [7]);
  Expect<Int64>(Int64(Block)).ToBe(3);
  Expect<Integer>(AuxCount).ToBe(5);
  Block := IrAppendAuxBlockGrowing(Aux, AuxCount, []);
  Expect<Int64>(Int64(Block)).ToBe(5);
  Expect<Integer>(AuxCount).ToBe(6);
  Expect<Boolean>(Length(Aux) > AuxCount).ToBe(True);

  IrTrimAux(Aux, AuxCount);
  Expect<Integer>(Length(Aux)).ToBe(6);
  { Identical layout to the exact-growth IrAppendAuxBlock: the two forms
    differ in allocation policy only, never in what a reader sees. }
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, 0))).ToBe(2);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, 0, 1))).ToBe(2);
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, 3))).ToBe(1);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, 3, 0))).ToBe(7);
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, 5))).ToBe(0);
end;

procedure TIrTests.TestBuildPrimitivesTolerateSelfAliasing;
var
  Code: TWasmIrCode;
  RegTypes: TWasmIrRegTypes;
  Aux: TWasmIrAuxU32;
  CodeCount, RegCount, AuxCount, I: Integer;
  Block: UInt32;
begin
  { A `const` record parameter wider than a machine word is passed BY
    REFERENCE, so `IrEmitInstr(Code, N, Code[K])` hands the primitive a
    pointer into the array it is about to reallocate. The append is driven
    to exactly the capacity boundary first, so the reallocation happens on
    the aliased call and not before it. }
  Code := nil;
  CodeCount := 0;
  for I := 0 to 15 do
    IrEmitInstr(Code, CodeCount,
      MakeIrInstr(iroI32Const, UInt32(I), IR_NO_REG, IR_NO_REG, Int64(I)));
  Expect<Integer>(CodeCount).ToBe(16);
  Expect<Integer>(Length(Code)).ToBe(16);

  Expect<Int64>(Int64(IrEmitInstr(Code, CodeCount, Code[3]))).ToBe(16);
  Expect<Int64>(Code[16].Imm).ToBe(3);
  Expect<Int64>(Int64(Code[16].Dest)).ToBe(3);
  Expect<Boolean>(Code[16].Op = iroI32Const).ToBe(True);

  { The same shape for registers: allocating a temporary of an existing
    register's type is the natural spelling and must not read freed
    memory. }
  RegTypes := nil;
  RegCount := 0;
  for I := 0 to 15 do
    IrAllocReg(RegTypes, RegCount, MakeNumValueType(wntI32));
  RegTypes[3] := MakeRefValueType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)));
  Expect<Integer>(Length(RegTypes)).ToBe(16);

  Expect<Int64>(Int64(IrAllocReg(RegTypes, RegCount, RegTypes[3])))
    .ToBe(16);
  Expect<Boolean>(RegTypes[16].Kind = wvkRef).ToBe(True);
  Expect<Boolean>(RegTypes[16].Ref.Heap.Abs = wahFunc).ToBe(True);

  { And for an aux append whose items are a slice of the aux array
    itself — the shape a merge-register append takes. }
  Aux := nil;
  AuxCount := 0;
  IrAppendAuxBlockGrowing(Aux, AuxCount, [1, 2, 3]);
  IrTrimAux(Aux, AuxCount);
  Expect<Integer>(Length(Aux)).ToBe(4);

  Block := IrAppendAuxBlockGrowing(Aux, AuxCount, Aux);
  Expect<Int64>(Int64(Block)).ToBe(4);
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, Block))).ToBe(4);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, Block, 0))).ToBe(3);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, Block, 1))).ToBe(1);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, Block, 2))).ToBe(2);
  Expect<Int64>(Int64(IrAuxBlockItem(Aux, Block, 3))).ToBe(3);
end;

procedure TIrTests.TestSafepointClassification;
begin
  { Calls and allocations are safepoints by op-kind and carry no marker. }
  Expect<Boolean>(IrOpIsSafepoint(iroCall)).ToBe(True);
  Expect<Boolean>(IrOpIsSafepoint(iroCallIndirect)).ToBe(True);
  Expect<Boolean>(IrOpIsSafepoint(iroReturnCallRef)).ToBe(True);
  Expect<Boolean>(IrOpIsSafepoint(iroStructNew)).ToBe(True);
  Expect<Boolean>(IrOpIsSafepoint(iroArrayNewFixed)).ToBe(True);
  Expect<Boolean>(IrOpIsSafepoint(iroRefI31)).ToBe(True);

  Expect<Boolean>(IrOpIsSafepoint(iroI32Add)).ToBe(False);
  Expect<Boolean>(IrOpIsSafepoint(iroStructGet)).ToBe(False);
  Expect<Boolean>(IrOpIsSafepoint(iroArrayLen)).ToBe(False);

  { A jump is a safepoint only with the flag set, and the flag lives on
    the instruction — which is why the op-only query says False and the
    instruction query decides. }
  Expect<Boolean>(IrOpIsSafepoint(iroJump)).ToBe(False);
  Expect<Boolean>(IrInstrIsSafepoint(
    MakeIrInstr(iroJump, IR_NO_REG, 0, IR_NO_REG, IR_JUMP_SAFEPOINT)))
    .ToBe(True);
  Expect<Boolean>(IrInstrIsSafepoint(
    MakeIrInstr(iroJump, IR_NO_REG, 0, IR_NO_REG, 0))).ToBe(False);
  Expect<Boolean>(IrInstrIsSafepoint(
    MakeIrInstr(iroCall, IR_NO_REG, 0, 0, 0))).ToBe(True);

  { No other branch op carries the flag, so a stray bit in a conditional
    branch's Imm must not read as a safepoint. }
  Expect<Boolean>(IrInstrIsSafepoint(
    MakeIrInstr(iroBranchIf, IR_NO_REG, 1, 2, 1))).ToBe(False);
end;

procedure TIrTests.TestReferenceRegisterBitset;
var
  Fn: TWasmIrFunction;
begin
  { RegTypes is authoritative; RefRegBits is the ADR-0011 projection a
    collector scans, computed once at the end of the function walk. }
  SetLength(Fn.RegTypes, 34);
  Fn.RegTypes[0] := MakeNumValueType(wntI32);
  Fn.RegTypes[1] := MakeRefValueType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)));
  Fn.RegTypes[2] := MakeNumValueType(wntF64);
  Fn.RegTypes[3] := MakeVecValueType;
  { Across the word boundary, where an `and 31` bug hides. }
  Fn.RegTypes[33] := MakeRefValueType(
    MakeRefType(False, MakeConcreteHeapType(2)));
  Fn.RegisterCount := 34;
  IrComputeRefRegBits(Fn);

  Expect<Integer>(Length(Fn.RefRegBits)).ToBe(2);
  Expect<Boolean>(IrRegIsRef(Fn, 0)).ToBe(False);
  Expect<Boolean>(IrRegIsRef(Fn, 1)).ToBe(True);
  Expect<Boolean>(IrRegIsRef(Fn, 2)).ToBe(False);
  { A v128 is not a reference — the collector must not scan it. }
  Expect<Boolean>(IrRegIsRef(Fn, 3)).ToBe(False);
  Expect<Boolean>(IrRegIsRef(Fn, 32)).ToBe(False);
  Expect<Boolean>(IrRegIsRef(Fn, 33)).ToBe(True);
  Expect<Boolean>(IrRegIsRef(Fn, IR_NO_REG)).ToBe(False);
end;

procedure TIrTests.TestFormatVersionIsStamped;
var
  IrModule: TWasmIrModule;
begin
  Expect<Integer>(IR_FORMAT_VERSION).ToBe(1);
  IrModule := TWasmIrModule.Create;
  try
    { ADR-0007's artifact-rejection rule reads this field, so it must be
      set by construction and never left at zero. }
    Expect<Int64>(Int64(IrModule.FormatVersion)).ToBe(IR_FORMAT_VERSION);
    Expect<Boolean>(IrModule.HasStart).ToBe(False);
  finally
    IrModule.Free;
  end;
end;

{ --- the disassembler, one test per operand family ----------------------- }

procedure TIrTests.TestDescribeArithmeticAndConstants;
var
  Fn: TWasmIrFunction;
begin
  SetCode(Fn, [
    MakeIrInstr(iroI32Const, 2, IR_NO_REG, IR_NO_REG, 7),
    MakeIrInstr(iroF64Const, 3, IR_NO_REG, IR_NO_REG,
      Int64($3FF0000000000000)),
    MakeIrInstr(iroI32Add, 4, 2, 2, 0),
    MakeIrInstr(iroMove, 1, 4, IR_NO_REG, 0),
    MakeIrInstr(iroI32Eqz, 5, 4, IR_NO_REG, 0),
    MakeIrInstr(iroReturn, IR_NO_REG, IR_NO_REG, IR_NO_REG, 0)
  ]);

  { Integer constants render as decimal, float constants as the raw bit
    pattern — never as a formatted float, which would lose NaN payloads
    and vary by locale. }
  ExpectListing(Fn, [
    '0000  i32.const              r2 <- 7',
    '0001  f64.const              r3 <- 0x3FF0000000000000',
    '0002  i32.add                r4 <- r2, r2',
    '0003  move                   r1 <- r4',
    '0004  i32.eqz                r5 <- r4',
    '0005  return'
  ]);
end;

procedure TIrTests.TestDescribeBranchesAndSafepoint;
var
  Fn: TWasmIrFunction;
begin
  SetCode(Fn, [
    MakeIrInstr(iroBranchIf, IR_NO_REG, 5, 4, 0),
    MakeIrInstr(iroBranchIfNot, IR_NO_REG, 5, 4, 0),
    MakeIrInstr(iroJump, IR_NO_REG, 0, IR_NO_REG, IR_JUMP_SAFEPOINT),
    MakeIrInstr(iroJump, IR_NO_REG, 4, IR_NO_REG, 0),
    MakeIrInstr(iroReturn, IR_NO_REG, IR_NO_REG, IR_NO_REG, 0)
  ]);

  { Branch targets are RESOLVED instruction indices, never label depths —
    that is the point of lowering structured control (ADR-0007). The
    safepoint is a flag on iroJump and renders only there. }
  ExpectListing(Fn, [
    '0000  branch_if              r5 -> @0004',
    '0001  branch_if_not          r5 -> @0004',
    '0002  jump                   @0000 safepoint',
    '0003  jump                   @0004',
    '0004  return'
  ]);
end;

procedure TIrTests.TestDescribeBrTableAuxBlock;
var
  Fn: TWasmIrFunction;
  Block: UInt32;
begin
  { [3, 3, 5, 7]: count 3 (two entries plus the default), then the three
    edge stubs. The default is the LAST entry, not the first. }
  Block := IrAppendAuxBlock(Fn.AuxU32, [3, 5, 7]);
  SetCode(Fn, [
    MakeIrInstr(iroBrTable, IR_NO_REG, 5, Block, 0)
  ]);

  Expect<Int64>(Int64(Fn.AuxU32[0])).ToBe(3);
  ExpectListing(Fn, [
    '0000  br_table               r5 -> [@0003, @0005, @0007]'
  ]);
end;

procedure TIrTests.TestDescribeCallArgumentAndResultLists;
var
  Fn: TWasmIrFunction;
  TwoArgs, OneResult, OneArg: UInt32;
begin
  TwoArgs := IrAppendAuxBlock(Fn.AuxU32, [1, 2]);
  OneResult := IrAppendAuxBlock(Fn.AuxU32, [7]);
  OneArg := IrAppendAuxBlock(Fn.AuxU32, [1]);

  SetCode(Fn, [
    MakeIrInstr(iroCall, IR_NO_REG, TwoArgs, OneResult, 3),
    MakeIrInstr(iroCallIndirect, 5, OneArg, OneResult, IrPack(4, 0)),
    MakeIrInstr(iroReturnCall, IR_NO_REG, OneArg, IR_NO_REG, 1),
    MakeIrInstr(iroCallRef, 6, OneArg, OneResult, 4),
    MakeIrInstr(iroThrow, IR_NO_REG, TwoArgs, IR_NO_REG, 2)
  ]);

  { Results are an aux list even for the single-result case, so a consumer
    writes one result-copy loop rather than two. A tail call has no result
    list at all: the callee's results become this function's. }
  ExpectListing(Fn, [
    '0000  call                   f3 (r1, r2) -> (r7)',
    '0001  call_indirect          type=4 table=0 [r5] (r1) -> (r7)',
    '0002  return_call            f1 (r1)',
    '0003  call_ref               type=4 [r6] (r1) -> (r7)',
    '0004  throw                  tag=2 (r1, r2)'
  ]);
end;

procedure TIrTests.TestDescribeMemoryAndPackedImmediates;
var
  Fn: TWasmIrFunction;
begin
  SetCode(Fn, [
    MakeIrInstr(iroI32Load, 5, 4, 0, 8),
    MakeIrInstr(iroI32Store, 6, 4, 0, 8),
    MakeIrInstr(iroMemoryCopy, 1, 2, 3, IrPack(0, 1)),
    MakeIrInstr(iroStructGet, 8, 1, IR_NO_REG, IrPack(2, 1)),
    MakeIrInstr(iroTableCopy, 1, 2, 3, IrPack(0, 1))
  ]);

  { A store's value register lives in Dest so that A is always the address
    and B always the memory index across loads and stores. Packed halves
    get distinct names, because rendering both as `mem=` would be
    ambiguous exactly where it matters. }
  ExpectListing(Fn, [
    '0000  i32.load               r5 <- [r4 + 8] mem=0',
    '0001  i32.store              [r4 + 8] <- r6 mem=0',
    '0002  memory.copy            dst_mem=0 src_mem=1 r1, r2, r3',
    '0003  struct.get             r8 <- type=2 field=1 r1',
    '0004  table.copy             dst_table=0 src_table=1 r1, r2, r3'
  ]);
end;

procedure TIrTests.TestDescribeIndexSpacesAndAuxLists;
var
  Fn: TWasmIrFunction;
  Fields, FillArgs: UInt32;
begin
  Fields := IrAppendAuxBlock(Fn.AuxU32, [1, 2]);
  FillArgs := IrAppendAuxBlock(Fn.AuxU32, [1, 2, 3, 4]);

  SetCode(Fn, [
    MakeIrInstr(iroGlobalGet, 7, IR_NO_REG, IR_NO_REG, 2),
    MakeIrInstr(iroGlobalSet, IR_NO_REG, 7, IR_NO_REG, 2),
    MakeIrInstr(iroTableGet, 8, 5, IR_NO_REG, 1),
    MakeIrInstr(iroSelect, 9, 2, 3, 5),
    MakeIrInstr(iroStructNew, 8, Fields, IR_NO_REG, 2),
    MakeIrInstr(iroArrayFill, IR_NO_REG, FillArgs, IR_NO_REG, 5),
    MakeIrInstr(iroElemDrop, IR_NO_REG, IR_NO_REG, IR_NO_REG, 1),
    MakeIrInstr(iroTableSize, 3, IR_NO_REG, IR_NO_REG, 1)
  ]);

  { The compact index spaces get a one-letter prefix (g, t, f); every
    other space is spelled out. select's condition rides in Imm and is the
    only register that does, which is why it renders after `?`. }
  ExpectListing(Fn, [
    '0000  global.get             r7 <- g2',
    '0001  global.set             g2 <- r7',
    '0002  table.get              r8 <- t1[r5]',
    '0003  select                 r9 <- r2, r3 ? r5',
    '0004  struct.new             r8 <- type=2 (r1, r2)',
    '0005  array.fill             type=5 (r1, r2, r3, r4)',
    '0006  elem.drop              elem=1',
    '0007  table.size             r3 <- t1'
  ]);
end;

procedure TIrTests.TestDescribeReferenceTypes;
var
  Fn: TWasmIrFunction;
begin
  SetLength(Fn.RegTypes, 10);
  { ref.null and ref.cast print their type from the REGISTER table: the
    instruction carries no heap type, because a null has no runtime type
    and the static one is what the stack map reads. }
  Fn.RegTypes[9] := MakeRefValueType(
    MakeRefType(True, MakeAbsHeapType(wahNoFunc)));
  Fn.RegTypes[7] := MakeRefValueType(
    MakeRefType(True, MakeConcreteHeapType(3)));

  { ref.test's destination is an i32, so its tested type has to come from
    AuxRefTypes instead. }
  SetLength(Fn.AuxRefTypes, 1);
  Fn.AuxRefTypes[0] := MakeRefType(True, MakeConcreteHeapType(3));

  SetCode(Fn, [
    MakeIrInstr(iroRefNull, 9, IR_NO_REG, IR_NO_REG, 0),
    MakeIrInstr(iroRefFunc, 8, IR_NO_REG, IR_NO_REG, 3),
    MakeIrInstr(iroRefTest, 5, 6, IR_NO_REG, 0),
    MakeIrInstr(iroBrOnCast, 7, 6, 21, 0),
    MakeIrInstr(iroBrOnNonNull, IR_NO_REG, 6, 21, 0),
    MakeIrInstr(iroUnreachable, IR_NO_REG, IR_NO_REG, IR_NO_REG, 0)
  ]);

  { br_on_cast's branch is the TAKEN edge; Dest is the refinement written
    on the fall-through, which is why it renders after `else`. }
  ExpectListing(Fn, [
    '0000  ref.null               r9 <- nullfuncref',
    '0001  ref.func               r8 <- f3',
    '0002  ref.test               r5 <- (ref null 3) r6',
    '0003  br_on_cast             r6 -> @0021 else r7 <- (ref null 3)',
    '0004  br_on_non_null         r6 -> @0021',
    '0005  unreachable'
  ]);
end;

procedure TIrTests.TestDescribeSentinelsAndSingleInstruction;
var
  Fn: TWasmIrFunction;
begin
  SetCode(Fn, [
    MakeIrInstr(iroMove, 1, IR_NO_REG, IR_NO_REG, 0),
    MakeIrInstr(iroBrOnNull, IR_NO_REG, 6, 9, 0),
    MakeIrInstr(iroF32Const, 4, IR_NO_REG, IR_NO_REG, $7FC00000)
  ]);

  { IR_NO_REG renders `-`, never `r4294967295`. In unreachable code a
    polymorphic pop yields no register at all, and that must be legible
    rather than look like a wild register number. }
  ExpectListing(Fn, [
    '0000  move                   r1 <- -',
    '0001  br_on_null             r6 -> @0009',
    '0002  f32.const              r4 <- 0x7FC00000'
  ]);

  Expect<string>(DescribeIrInstr(Fn, 1))
    .ToBe('0001  br_on_null             r6 -> @0009');
  { Out of range is reported, not raised: Describe is a diagnostic and
    must survive being pointed at half-constructed IR. }
  Expect<string>(DescribeIrInstr(Fn, 9)).ToBe('0009  <out of range>');
end;

procedure TIrTests.TestDescribeEmptyAuxBlocks;
var
  Fn: TWasmIrFunction;
  NoArgs, NoResults: UInt32;
begin
  { An empty aux block is the COMMON case, not an exotic one: a call to a
    no-argument function, a call with no results, and a struct.new of a
    zero-field struct all render one. The loop that walks a block counts
    in UInt32, so `0 to Count - 1` at Count = 0 is `0 to $FFFFFFFF` —
    either a hang or a range error, depending on the build. }
  NoArgs := IrAppendAuxBlock(Fn.AuxU32, []);
  NoResults := IrAppendAuxBlock(Fn.AuxU32, []);
  Expect<Int64>(Int64(NoArgs)).ToBe(0);
  Expect<Int64>(Int64(NoResults)).ToBe(1);

  SetCode(Fn, [
    MakeIrInstr(iroCall, IR_NO_REG, NoArgs, NoResults, 3),
    MakeIrInstr(iroStructNew, 8, NoArgs, IR_NO_REG, 2),
    MakeIrInstr(iroThrow, IR_NO_REG, NoArgs, IR_NO_REG, 2),
    MakeIrInstr(iroReturnCall, IR_NO_REG, NoArgs, IR_NO_REG, 1),
    { The "no block at all" sentinel reads as empty rather than raising,
      which is the disassembler's contract on half-constructed IR. }
    MakeIrInstr(iroBrTable, IR_NO_REG, 5, IR_NO_AUX, 0)
  ]);

  ExpectListing(Fn, [
    '0000  call                   f3 () -> ()',
    '0001  struct.new             r8 <- type=2 ()',
    '0002  throw                  tag=2 ()',
    '0003  return_call            f1 ()',
    '0004  br_table               r5 -> []'
  ]);
end;

procedure TIrTests.TestDescribeInitExpression;
var
  Expr: TWasmIrInitExpr;
begin
  { An init expression is not a function: no return block and no trailing
    iroReturn. Run Code[0..High] and read ResultReg. }
  SetLength(Expr.Code, 2);
  Expr.Code[0] := MakeIrInstr(iroI32Const, 0, IR_NO_REG, IR_NO_REG, 42);
  Expr.Code[1] := MakeIrInstr(iroGlobalGet, 1, IR_NO_REG, IR_NO_REG, 0);
  Expr.RegisterCount := 2;
  Expr.ResultReg := 1;

  Expect<string>(DescribeIrInitExpr(Expr)).ToBe(
    '0000  i32.const              r0 <- 42' + #10 +
    '0001  global.get             r1 <- g0');
  Expect<string>(DescribeIrInitExprInstr(Expr, 0))
    .ToBe('0000  i32.const              r0 <- 42');
end;

procedure TIrTests.SetupTests;
begin
  Test('IR op enum is dense and complete', TestEnumIsDenseAndComplete);
  Test('IR op ordinals are pinned', TestEnumOrdinalsArePinned);
  Test('IR_OP_INFO is total over TWasmIrOp', TestOpInfoIsTotal);
  Test('IR_OP_INFO field kinds per family',
    TestOpInfoFieldKindsPerFamily);
  Test('instruction record layout is fixed',
    TestInstructionRecordLayout);
  Test('packed index pairs round-trip', TestPackedIndexRoundTrip);
  Test('float immediates are bit patterns',
    TestFloatImmediatesAreBitPatterns);
  Test('aux blocks are length-prefixed and round-trip',
    TestAuxBlocksRoundTrip);
  Test('build primitives grow geometrically and trim exactly',
    TestBuildPrimitivesGrowAndTrim);
  Test('build primitives tolerate a self-aliased payload',
    TestBuildPrimitivesTolerateSelfAliasing);
  Test('safepoints are op-kind plus the jump flag',
    TestSafepointClassification);
  Test('reference registers project to a bitset',
    TestReferenceRegisterBitset);
  Test('IR_FORMAT_VERSION is stamped on the module',
    TestFormatVersionIsStamped);

  Test('describe: arithmetic and constants',
    TestDescribeArithmeticAndConstants);
  Test('describe: branches and the safepoint flag',
    TestDescribeBranchesAndSafepoint);
  Test('describe: br_table aux block', TestDescribeBrTableAuxBlock);
  Test('describe: call argument and result lists',
    TestDescribeCallArgumentAndResultLists);
  Test('describe: memory access and packed immediates',
    TestDescribeMemoryAndPackedImmediates);
  Test('describe: index spaces and aux lists',
    TestDescribeIndexSpacesAndAuxLists);
  Test('describe: reference types', TestDescribeReferenceTypes);
  Test('describe: sentinels and a single instruction',
    TestDescribeSentinelsAndSingleInstruction);
  Test('describe: empty aux blocks', TestDescribeEmptyAuxBlocks);
  Test('describe: init expression', TestDescribeInitExpression);
end;

begin
  TestRunnerProgram.AddSuite(TIrTests.Create('Wasm.Ir'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
