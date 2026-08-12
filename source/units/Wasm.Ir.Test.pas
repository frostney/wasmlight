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
    procedure TestVectorRegisterAllocation;
    procedure TestVectorAuxRoundTrips;
    procedure TestV128LaneAccess;
    procedure TestDescribeVectorForms;

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
  { 231 non-vector members (the pre-SIMD count), plus Track G's 256 wasm
    vector ops (234 vec + 22 memory-category v128.* = 256, verified against
    the pinned registry) and 9 IR-only vector ops. 231 + 256 + 9 = 496. }
  Expect<Integer>(Ord(Low(TWasmIrOp))).ToBe(0);
  Expect<Integer>(Ord(High(TWasmIrOp)) + 1).ToBe(496);
  { Still two bytes by the PACKENUM 2 directive (495 < 65536), which is what
    keeps TWasmIrInstr at 24. }
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

  { --- vector block: appended after i31, in subopcode order (Track G) --- }

  { The block leads at 231 (right after iroI31GetU = 230) with $FD 0, and
    the first IR-only vector op follows the last wasm one. }
  Expect<Integer>(Ord(iroV128Load)).ToBe(231);
  Expect<Integer>(Ord(iroV128Const)).ToBe(243);      { $FD 12 }
  Expect<Integer>(Ord(iroI8x16Shuffle)).ToBe(244);   { $FD 13 }
  Expect<Integer>(Ord(iroV128Bitselect)).ToBe(313);  { $FD 82 }
  Expect<Integer>(Ord(iroV128Load8Lane)).ToBe(315);  { $FD 84 }
  { The last wasm vector op is $FD 275, and the 9 IR-only ops follow it. }
  Expect<Integer>(Ord(iroI32x4RelaxedDotI8x16I7x16AddS)).ToBe(486);
  Expect<Integer>(Ord(iroMoveVec)).ToBe(487);
  Expect<Integer>(Ord(iroArrayFillVec)).ToBe(495);

  { Contiguity across the gap-skips: subopcodes < 154 are dense, so the
    ordinal delta equals the subopcode delta up to there. }
  Expect<Integer>(Ord(iroV128Store) - Ord(iroV128Load)).ToBe(11);
  Expect<Integer>(Ord(iroV128AnyTrue) - Ord(iroV128Load)).ToBe(83);
  { i16x8.avgr_u is $FD 155 (154 is unassigned), one past i16x8.max_u
    ($FD 153) — a one-step ordinal move across a skipped subopcode. }
  Expect<Integer>(Ord(iroI16x8AvgrU) - Ord(iroI16x8MaxU)).ToBe(1);
  { i32x4.all_true is $FD 163 (162 unassigned), one past i32x4.neg
    ($FD 161). }
  Expect<Integer>(Ord(iroI32x4AllTrue) - Ord(iroI32x4Neg)).ToBe(1);
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

  { --- vector families (Track G) -------------------------------------- }

  { The 16-byte immediates ride in an aux block. }
  Expect<Boolean>(IR_OP_INFO[iroV128Const].ImmKind = ifkAuxIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroV128Const].AKind = ifkUnused).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI8x16Shuffle].ImmKind = ifkAuxIndex)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI8x16Shuffle].BKind = ifkSrcReg).ToBe(True);

  { The lane index is a plain immediate; extract has no B, replace does. }
  Expect<Boolean>(IR_OP_INFO[iroI8x16ExtractLaneS].ImmKind = ifkImmValue)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI8x16ExtractLaneS].BKind = ifkUnused)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI8x16ReplaceLane].BKind = ifkSrcReg)
    .ToBe(True);

  { A whole-vector load mirrors a scalar load; the store keeps its value in
    Dest so A stays the address and B the memory index. }
  Expect<Boolean>(IR_OP_INFO[iroV128Load].DestKind = ifkDestReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroV128Load].BKind = ifkMemIndex).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroV128Store].DestKind = ifkSrcReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroV128Store].BKind = ifkMemIndex).ToBe(True);

  { A lane load/store carries its memarg+lane in an aux block; the load's B
    is the source vector, the store's B is unused. }
  Expect<Boolean>(IR_OP_INFO[iroV128Load8Lane].ImmKind = ifkAuxIndex)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroV128Load8Lane].BKind = ifkSrcReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroV128Store8Lane].DestKind = ifkSrcReg)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroV128Store8Lane].BKind = ifkUnused).ToBe(True);

  { ifkSrcRegImm — the third source register of a ternary vector op. All
    ten wasm ternaries carry it, plus the IR-only iroSelectVec. A plain
    binary vector op does NOT. }
  Expect<Boolean>(IR_OP_INFO[iroV128Bitselect].ImmKind = ifkSrcRegImm)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI8x16RelaxedLaneselect].ImmKind
    = ifkSrcRegImm).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroF32x4RelaxedMadd].ImmKind = ifkSrcRegImm)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI32x4RelaxedDotI8x16I7x16AddS].ImmKind
    = ifkSrcRegImm).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroSelectVec].ImmKind = ifkSrcRegImm)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI8x16Add].ImmKind = ifkUnused).ToBe(True);

  { A relaxed op with a lane-select-free signature (min/max, swizzle,
    q15mulr, the two-operand dot) is a plain binary, not a ternary. }
  Expect<Boolean>(IR_OP_INFO[iroF32x4RelaxedMin].ImmKind = ifkUnused)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI8x16RelaxedSwizzle].BKind = ifkSrcReg)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroI16x8RelaxedDotI8x16I7x16S].ImmKind
    = ifkUnused).ToBe(True);

  { The IR-only *Vec ops mirror their scalar twins' field kinds. }
  Expect<Boolean>(IR_OP_INFO[iroMoveVec].DestKind = ifkDestReg).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroGlobalGetVec].ImmKind = ifkGlobalIndex)
    .ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroStructGetVec].ImmKind = ifkPacked).ToBe(True);
  Expect<Boolean>(IR_OP_INFO[iroArrayFillVec].AKind = ifkAuxIndex).ToBe(True);
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

  { A quiet-NaN payload survives, which is the whole reason floats are stored
    as bits: assert_return distinguishes canonical from arithmetic NaNs. A
    signalling NaN cannot be loaded through an x87 register on 32-bit Windows
    without raising an invalid-operation exception before this helper runs. }
  Bits := IrF64Bits(IrBitsAsF64(Int64($7FF8000000000001)));
  Expect<Int64>(Bits).ToBe(Int64($7FF8000000000001));
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
  Expect<Integer>(IR_FORMAT_VERSION).ToBe(2);
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

{ --- vector foundation (Track G) ----------------------------------------- }

procedure TIrTests.TestVectorRegisterAllocation;
var
  RegTypes: TWasmIrRegTypes;
  RegCount: Integer;
  R0, RVec, RRef, RVec2: UInt32;
  Fn: TWasmIrFunction;
begin
  { The two-slot rule (SIMD design §1.3-§1.5): a v128 occupies two adjacent
    slots and its low slot is always EVEN, so IrAllocReg pads when the next
    free slot is odd. }
  RegTypes := nil;
  RegCount := 0;

  R0 := IrAllocReg(RegTypes, RegCount, MakeNumValueType(wntI32));
  Expect<Int64>(Int64(R0)).ToBe(0);

  { Slot 1 is odd, so the v128 pads it and lands the pair at 2 and 3. }
  RVec := IrAllocReg(RegTypes, RegCount, MakeVecValueType);
  Expect<Int64>(Int64(RVec)).ToBe(2);
  Expect<Boolean>((RVec and 1) = 0).ToBe(True);
  Expect<Integer>(RegCount).ToBe(4);
  Expect<Boolean>(RegTypes[2].Kind = wvkVec).ToBe(True);
  Expect<Boolean>(RegTypes[3].Kind = wvkVec).ToBe(True);
  { The pad slot is a non-reference filler, never a v128 or a ref. }
  Expect<Boolean>(RegTypes[1].Kind = wvkVec).ToBe(False);
  Expect<Boolean>(RegTypes[1].Kind = wvkRef).ToBe(False);

  { A reference after the v128 takes the very next slot (4). }
  RRef := IrAllocReg(RegTypes, RegCount,
    MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahFunc))));
  Expect<Int64>(Int64(RRef)).ToBe(4);
  Expect<Integer>(RegCount).ToBe(5);

  { Slot 5 is odd, so a second v128 pads it and lands at 6 and 7. }
  RVec2 := IrAllocReg(RegTypes, RegCount, MakeVecValueType);
  Expect<Int64>(Int64(RVec2)).ToBe(6);
  Expect<Integer>(RegCount).ToBe(8);

  { THE GC FRAME-WALK INVARIANT (ADR-0011), the reason the alignment exists:
    RefRegBits is indexed by SLOT, both slots of every v128 are clear, and
    the ref register's own bit is set — so G5's collector scans the ref and
    skips the vector halves. }
  IrTrimRegTypes(RegTypes, RegCount);
  Fn.RegTypes := RegTypes;
  Fn.RegisterCount := UInt32(RegCount);
  IrComputeRefRegBits(Fn);

  Expect<Boolean>(IrRegIsRef(Fn, 0)).ToBe(False);   { i32 }
  Expect<Boolean>(IrRegIsRef(Fn, 1)).ToBe(False);   { pad }
  Expect<Boolean>(IrRegIsRef(Fn, 2)).ToBe(False);   { v128 low }
  Expect<Boolean>(IrRegIsRef(Fn, 3)).ToBe(False);   { v128 high }
  Expect<Boolean>(IrRegIsRef(Fn, 4)).ToBe(True);    { the reference }
  Expect<Boolean>(IrRegIsRef(Fn, 6)).ToBe(False);   { v128 low }
  Expect<Boolean>(IrRegIsRef(Fn, 7)).ToBe(False);   { v128 high }
end;

procedure TIrTests.TestVectorAuxRoundTrips;
var
  Aux: TWasmIrAuxU32;
  AuxCount: Integer;
  V, VBack: TWasmV128;
  Block: UInt32;
  MemIdx, Lane: UInt32;
  Offset: UInt64;
  I: Integer;
begin
  { A v128 immediate is a length-4 aux block holding the 16 bytes verbatim
    (SIMD design §2.2) — read back with a single Move, byte for byte. }
  for I := 0 to 15 do
    V.B[I] := Byte(I);                    { 00 01 ... 0f }
  Aux := nil;
  Block := IrAppendAuxV128(Aux, V);
  Expect<Int64>(Int64(Block)).ToBe(0);
  Expect<Integer>(Length(Aux)).ToBe(5);   { count word + 4 data words }
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, Block))).ToBe(4);

  IrAuxReadV128(Aux, Block, VBack);
  for I := 0 to 15 do
    Expect<Int64>(Int64(VBack.B[I])).ToBe(Int64(I));

  { The growing form produces the same layout, appended after the first. }
  AuxCount := Length(Aux);
  V.U64[0] := UInt64($1122334455667788);
  V.U64[1] := UInt64($99AABBCCDDEEFF00);
  Block := IrAppendAuxV128Growing(Aux, AuxCount, V);
  Expect<Int64>(Int64(Block)).ToBe(5);
  IrTrimAux(Aux, AuxCount);
  IrAuxReadV128(Aux, Block, VBack);
  Expect<Int64>(Int64(VBack.U64[0])).ToBe(Int64($1122334455667788));
  Expect<Int64>(Int64(VBack.U64[1])).ToBe(Int64(UInt64($99AABBCCDDEEFF00)));

  { A missing block reads as the zero vector rather than raising. }
  IrAuxReadV128(Aux, IR_NO_AUX, VBack);
  Expect<Int64>(Int64(VBack.U64[0])).ToBe(0);
  Expect<Int64>(Int64(VBack.U64[1])).ToBe(0);

  { The lane memarg block: [mem, offsetLo, offsetHi, lane], offset a full
    u64 (SIMD design §2.3) so an i64 memory's offset survives. }
  Aux := nil;
  Block := IrAppendAuxLaneMemArg(Aux, 1, UInt64($100000002), 5);
  Expect<Int64>(Int64(IrAuxBlockCount(Aux, Block))).ToBe(4);
  IrAuxReadLaneMemArg(Aux, Block, MemIdx, Offset, Lane);
  Expect<Int64>(Int64(MemIdx)).ToBe(1);
  Expect<Int64>(Int64(Offset)).ToBe(Int64($100000002));
  Expect<Int64>(Int64(Lane)).ToBe(5);
end;

procedure TIrTests.TestV128LaneAccess;
var
  V: TWasmV128;
  I: Integer;
begin
  { The record is exactly 16 bytes — the whole two-slot design rests on it. }
  Expect<Integer>(SizeOf(TWasmV128)).ToBe(16);

  { Write bytes, read the wider lane views. The union is HOST-order, so a
    byte-to-word reinterpretation is endianness-sensitive; assert for the
    build's actual endianness. }
  for I := 0 to 15 do
    V.B[I] := Byte(I);
{$IFDEF ENDIAN_LITTLE}
  Expect<Int64>(Int64(V.U32[0])).ToBe(Int64($03020100));
  Expect<Int64>(Int64(V.U32[3])).ToBe(Int64($0F0E0D0C));
  Expect<Int64>(Int64(V.U64[1])).ToBe(Int64($0F0E0D0C0B0A0908));
{$ELSE}
  Expect<Int64>(Int64(V.U32[0])).ToBe(Int64($00010203));
  Expect<Int64>(Int64(V.U32[3])).ToBe(Int64($0C0D0E0F));
  Expect<Int64>(Int64(V.U64[1])).ToBe(Int64($08090A0B0C0D0E0F));
{$ENDIF}

  { Write the wider lanes, read the bytes back — same host-order rule, in
    reverse. }
  V.U64[0] := UInt64($1122334455667788);
  V.U64[1] := UInt64($99AABBCCDDEEFF00);
{$IFDEF ENDIAN_LITTLE}
  Expect<Int64>(Int64(V.B[0])).ToBe(Int64($88));
  Expect<Int64>(Int64(V.B[7])).ToBe(Int64($11));
  Expect<Int64>(Int64(V.B[8])).ToBe(Int64($00));
  Expect<Int64>(Int64(V.B[15])).ToBe(Int64($99));
{$ELSE}
  Expect<Int64>(Int64(V.B[0])).ToBe(Int64($11));
  Expect<Int64>(Int64(V.B[7])).ToBe(Int64($88));
  Expect<Int64>(Int64(V.B[8])).ToBe(Int64($99));
  Expect<Int64>(Int64(V.B[15])).ToBe(Int64($00));
{$ENDIF}

  { The float lane views alias the same storage and round-trip a value
    regardless of endianness. }
  V.F64[0] := 1.0;
  Expect<Boolean>(V.F64[0] = 1.0).ToBe(True);
  V.F32[2] := 2.0;
  Expect<Boolean>(V.F32[2] = 2.0).ToBe(True);
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

procedure TIrTests.TestDescribeVectorForms;
var
  Fn: TWasmIrFunction;
  V: TWasmV128;
  ConstBlk, ShufBlk, LaneBlk: UInt32;
  I: Integer;

  function VLine(const AIdx: Integer; const AOp: TWasmIrOp;
    const AOperands: string): string;
  begin
    { Rebuild the index/mnemonic/padding the way IrDescribeAt does, so only
      the OPERAND rendering — the thing under test — is a literal. }
    Result := TrimRight(Format('%.4d  %-22s %s',
      [AIdx, IrOpMnemonic(AOp), AOperands]));
  end;

begin
  { const and shuffle both take a 16-byte aux immediate; use 00..0f for
    both, so the const hex and the shuffle mask read the same source. }
  for I := 0 to 15 do
    V.B[I] := Byte(I);
  ConstBlk := IrAppendAuxV128(Fn.AuxU32, V);
  ShufBlk := IrAppendAuxV128(Fn.AuxU32, V);
  { A lane memarg: mem 0, static offset 8, lane 5. }
  LaneBlk := IrAppendAuxLaneMemArg(Fn.AuxU32, 0, 8, 5);

  SetCode(Fn, [
    MakeIrInstr(iroV128Const, 4, IR_NO_REG, IR_NO_REG, Int64(ConstBlk)),
    MakeIrInstr(iroI8x16Shuffle, 6, 2, 4, Int64(ShufBlk)),
    MakeIrInstr(iroI8x16ExtractLaneS, 7, 6, IR_NO_REG, 3),
    MakeIrInstr(iroI8x16ReplaceLane, 8, 6, 7, 3),
    MakeIrInstr(iroV128Bitselect, 9, 2, 4, 6),
    MakeIrInstr(iroV128Load, 10, 3, 0, 8),
    MakeIrInstr(iroV128Store, 10, 3, 0, 8),
    MakeIrInstr(iroV128Load8Lane, 11, 3, 10, Int64(LaneBlk)),
    MakeIrInstr(iroV128Store8Lane, 10, 3, IR_NO_REG, Int64(LaneBlk)),
    MakeIrInstr(iroMoveVec, 12, 9, IR_NO_REG, 0)
  ]);

  { The five special shapes, the whole-vector load/store, and the IR-only
    move.v128 — exactly the SIMD design §2.6 listing. `v128:` renders the 16
    bytes in memory order, `lanes[…]` the decimal shuffle mask, a ternary's
    third source after `?`, and a lane op's [addr + offset] mem/lane. }
  ExpectListing(Fn, [
    VLine(0, iroV128Const,
      'r4 <- v128:000102030405060708090a0b0c0d0e0f'),
    VLine(1, iroI8x16Shuffle,
      'r6 <- r2, r4 lanes[0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15]'),
    VLine(2, iroI8x16ExtractLaneS, 'r7 <- r6 lane=3'),
    VLine(3, iroI8x16ReplaceLane, 'r8 <- r6, r7 lane=3'),
    VLine(4, iroV128Bitselect, 'r9 <- r2, r4 ? r6'),
    VLine(5, iroV128Load, 'r10 <- [r3 + 8] mem=0'),
    VLine(6, iroV128Store, '[r3 + 8] <- r10 mem=0'),
    VLine(7, iroV128Load8Lane, 'r11 <- [r3 + 8] mem=0 lane=5, r10'),
    VLine(8, iroV128Store8Lane, '[r3 + 8] <- r10 mem=0 lane=5'),
    VLine(9, iroMoveVec, 'r12 <- r9')
  ]);
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
  Test('vector registers take two even-aligned non-ref slots',
    TestVectorRegisterAllocation);
  Test('vector aux blocks round-trip (v128 immediate and lane memarg)',
    TestVectorAuxRoundTrips);
  Test('v128 lane views alias one 16-byte record',
    TestV128LaneAccess);

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
  Test('describe: vector operand forms', TestDescribeVectorForms);
end;

begin
  TestRunnerProgram.AddSuite(TIrTests.Create('Wasm.Ir'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
