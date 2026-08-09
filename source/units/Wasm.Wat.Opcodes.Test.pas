{ Unit suite for Wasm.Wat.Opcodes, the mnemonic table.

  The table is the mirror of Wasm.Decoder.Expr's immediate dispatch, so
  the checks below are spot-checks of representative mnemonics per family
  against the pinned spec's opcode bytes and the immediate shape the
  decoder reads — one core single-byte, one memarg (with its natural
  alignment), one $FC-prefixed, one $FB-prefixed per interesting shape.
  Two structural properties matter as much as the individual rows: no
  mnemonic is added twice (a copy-paste duplicate would silently shadow an
  earlier opcode), and a spelling the format does not have — the obsolete
  `get_local`, or any not-yet-added vector mnemonic — resolves to nothing,
  which is what routes it to the assembler's unknown-operator path. }
program Wasm.Wat.Opcodes.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Wat.Opcodes;

type
  TWatOpcodesTests = class(TTestSuite)
  private
    { Fetches AMnemonic, asserting it is present so the row assertions
      that follow never read a stale record. }
    function Info(const AMnemonic: string): TWasmOpcodeInfo;
    { Asserts a single-byte-opcode row: no prefix, the opcode, the shape. }
    procedure ExpectCore(const AMnemonic: string; const AOpcode: Byte;
      const AShape: TWasmImmShape);
    { Asserts a prefixed row: the prefix, the subopcode, the shape. }
    procedure ExpectPrefixed(const AMnemonic: string;
      const APrefix, ASub: Byte; const AShape: TWasmImmShape);
    { Asserts a $FD vector row: subopcode (u32, reaches 275), shape, and the
      natural alignment (meaningful only for the memarg families). }
    procedure ExpectVector(const AMnemonic: string; const ASub: UInt32;
      const AShape: TWasmImmShape; const AAlignLog2: Byte);
  public
    procedure SetupTests; override;

    procedure TestControlFamily;
    procedure TestVariableAndParametric;
    procedure TestMemoryFamilyAndNaturalAlignment;
    procedure TestConstFamily;
    procedure TestNumericFamily;
    procedure TestRefFamily;
    procedure TestMiscPrefixedFamily;
    procedure TestAggregatePrefixedFamily;
    procedure TestNoDuplicateMnemonics;
    procedure TestUnknownAndObsoleteAbsent;
    procedure TestVectorFamilyOpcodesAndShapes;
    procedure TestVectorMemoryFamilyNaturalAlignment;
    procedure TestVectorRelaxedTruncSpelling;
    procedure TestTableSizeFloor;
  end;

function TWatOpcodesTests.Info(const AMnemonic: string): TWasmOpcodeInfo;
var
  Found: TWasmOpcodeInfo;
  Present: Boolean;
begin
  Present := LookupOpcode(AMnemonic, Found);
  Expect<string>(AMnemonic + ': ' + BoolToStr(Present, 'present', 'ABSENT'))
    .ToBe(AMnemonic + ': present');
  Result := Found;
end;

procedure TWatOpcodesTests.ExpectCore(const AMnemonic: string;
  const AOpcode: Byte; const AShape: TWasmImmShape);
var
  I: TWasmOpcodeInfo;
begin
  I := Info(AMnemonic);
  Expect<Boolean>(I.HasPrefix).ToBe(False);
  Expect<Integer>(Integer(I.Opcode)).ToBe(Integer(AOpcode));
  Expect<Integer>(Ord(I.Shape)).ToBe(Ord(AShape));
end;

procedure TWatOpcodesTests.ExpectPrefixed(const AMnemonic: string;
  const APrefix, ASub: Byte; const AShape: TWasmImmShape);
var
  I: TWasmOpcodeInfo;
begin
  I := Info(AMnemonic);
  Expect<Boolean>(I.HasPrefix).ToBe(True);
  Expect<Integer>(Integer(I.Prefix)).ToBe(Integer(APrefix));
  Expect<Integer>(Integer(I.Opcode)).ToBe(Integer(ASub));
  Expect<Integer>(Ord(I.Shape)).ToBe(Ord(AShape));
end;

procedure TWatOpcodesTests.ExpectVector(const AMnemonic: string;
  const ASub: UInt32; const AShape: TWasmImmShape; const AAlignLog2: Byte);
var
  I: TWasmOpcodeInfo;
begin
  I := Info(AMnemonic);
  Expect<Boolean>(I.HasPrefix).ToBe(True);
  Expect<Integer>(Integer(I.Prefix)).ToBe(Integer(OPCODE_PREFIX_FD));
  Expect<Int64>(Int64(I.Opcode)).ToBe(Int64(ASub));
  Expect<Integer>(Ord(I.Shape)).ToBe(Ord(AShape));
  Expect<Integer>(Integer(I.NaturalAlignLog2)).ToBe(Integer(AAlignLog2));
end;

procedure TWatOpcodesTests.TestControlFamily;
begin
  ExpectCore('unreachable', $00, wisNone);
  ExpectCore('block', $02, wisBlockType);
  ExpectCore('loop', $03, wisBlockType);
  ExpectCore('if', $04, wisBlockType);
  ExpectCore('throw', $08, wisTag);
  ExpectCore('br', $0C, wisLabel);
  ExpectCore('br_if', $0D, wisLabel);
  ExpectCore('br_table', $0E, wisBrTable);
  ExpectCore('return', $0F, wisNone);
  ExpectCore('call', $10, wisFunc);
  ExpectCore('call_indirect', $11, wisCallIndirect);
  ExpectCore('call_ref', $14, wisType);
  ExpectCore('try_table', $1F, wisTryTable);
end;

procedure TWatOpcodesTests.TestVariableAndParametric;
begin
  ExpectCore('drop', $1A, wisNone);
  { select stores the bare-form opcode; the type-annotated form is +1. }
  ExpectCore('select', $1B, wisSelect);
  ExpectCore('local.get', $20, wisLocal);
  ExpectCore('local.set', $21, wisLocal);
  ExpectCore('local.tee', $22, wisLocal);
  ExpectCore('global.get', $23, wisGlobal);
  ExpectCore('global.set', $24, wisGlobal);
  ExpectCore('table.get', $25, wisTable);
  ExpectCore('table.set', $26, wisTable);
end;

procedure TWatOpcodesTests.TestMemoryFamilyAndNaturalAlignment;
var
  I: TWasmOpcodeInfo;
begin
  ExpectCore('i32.load', $28, wisMemArg);
  ExpectCore('i64.load', $29, wisMemArg);
  ExpectCore('i32.store', $36, wisMemArg);
  ExpectCore('i64.store32', $3E, wisMemArg);
  ExpectCore('memory.size', $3F, wisMem);
  ExpectCore('memory.grow', $40, wisMem);

  { Natural alignment is log2 of the access size, the default `align=`:
    8 for i32.load8, 16 for i32.load16, 32/64 for the word loads. }
  I := Info('i32.load8_u');
  Expect<Integer>(Integer(I.NaturalAlignLog2)).ToBe(0);
  I := Info('i32.load16_u');
  Expect<Integer>(Integer(I.NaturalAlignLog2)).ToBe(1);
  I := Info('i32.load');
  Expect<Integer>(Integer(I.NaturalAlignLog2)).ToBe(2);
  I := Info('i64.load');
  Expect<Integer>(Integer(I.NaturalAlignLog2)).ToBe(3);
  I := Info('f64.store');
  Expect<Integer>(Integer(I.NaturalAlignLog2)).ToBe(3);
  I := Info('i64.load32_u');
  Expect<Integer>(Integer(I.NaturalAlignLog2)).ToBe(2);
end;

procedure TWatOpcodesTests.TestConstFamily;
begin
  ExpectCore('i32.const', $41, wisConstI32);
  ExpectCore('i64.const', $42, wisConstI64);
  ExpectCore('f32.const', $43, wisConstF32);
  ExpectCore('f64.const', $44, wisConstF64);
end;

procedure TWatOpcodesTests.TestNumericFamily;
begin
  { Boundaries of the contiguous $45..$C4 numeric block plus a few
    interior rows, all no-immediate. }
  ExpectCore('i32.eqz', $45, wisNone);
  ExpectCore('i32.add', $6A, wisNone);
  ExpectCore('i64.add', $7C, wisNone);
  ExpectCore('f32.add', $92, wisNone);
  ExpectCore('f64.add', $A0, wisNone);
  ExpectCore('i32.wrap_i64', $A7, wisNone);
  ExpectCore('i64.extend_i32_s', $AC, wisNone);
  ExpectCore('f64.promote_f32', $BB, wisNone);
  ExpectCore('i32.extend8_s', $C0, wisNone);
  ExpectCore('i64.extend32_s', $C4, wisNone);
end;

procedure TWatOpcodesTests.TestRefFamily;
begin
  ExpectCore('ref.null', $D0, wisHeapType);
  ExpectCore('ref.is_null', $D1, wisNone);
  ExpectCore('ref.func', $D2, wisFunc);
  ExpectCore('ref.eq', $D3, wisNone);
  ExpectCore('ref.as_non_null', $D4, wisNone);
  ExpectCore('br_on_null', $D5, wisLabel);
  ExpectCore('br_on_non_null', $D6, wisLabel);
end;

procedure TWatOpcodesTests.TestMiscPrefixedFamily;
begin
  ExpectPrefixed('i32.trunc_sat_f32_s', OPCODE_PREFIX_FC, 0, wisNone);
  ExpectPrefixed('i64.trunc_sat_f64_u', OPCODE_PREFIX_FC, 7, wisNone);
  ExpectPrefixed('memory.init', OPCODE_PREFIX_FC, 8, wisDataMem);
  ExpectPrefixed('data.drop', OPCODE_PREFIX_FC, 9, wisData);
  ExpectPrefixed('memory.copy', OPCODE_PREFIX_FC, 10, wisMemMem);
  ExpectPrefixed('memory.fill', OPCODE_PREFIX_FC, 11, wisMem);
  ExpectPrefixed('table.init', OPCODE_PREFIX_FC, 12, wisElemTable);
  ExpectPrefixed('elem.drop', OPCODE_PREFIX_FC, 13, wisElem);
  ExpectPrefixed('table.copy', OPCODE_PREFIX_FC, 14, wisTableTable);
  ExpectPrefixed('table.grow', OPCODE_PREFIX_FC, 15, wisTable);
  ExpectPrefixed('table.size', OPCODE_PREFIX_FC, 16, wisTable);
  ExpectPrefixed('table.fill', OPCODE_PREFIX_FC, 17, wisTable);
end;

procedure TWatOpcodesTests.TestAggregatePrefixedFamily;
begin
  ExpectPrefixed('struct.new', OPCODE_PREFIX_FB, 0, wisType);
  ExpectPrefixed('struct.get', OPCODE_PREFIX_FB, 2, wisTypeField);
  ExpectPrefixed('struct.set', OPCODE_PREFIX_FB, 5, wisTypeField);
  ExpectPrefixed('array.new', OPCODE_PREFIX_FB, 6, wisType);
  ExpectPrefixed('array.new_fixed', OPCODE_PREFIX_FB, 8, wisTypeCount);
  ExpectPrefixed('array.new_data', OPCODE_PREFIX_FB, 9, wisTypeData);
  ExpectPrefixed('array.new_elem', OPCODE_PREFIX_FB, 10, wisTypeElem);
  ExpectPrefixed('array.len', OPCODE_PREFIX_FB, 15, wisNone);
  ExpectPrefixed('array.copy', OPCODE_PREFIX_FB, 17, wisTypeType);
  ExpectPrefixed('array.init_elem', OPCODE_PREFIX_FB, 19, wisTypeElem);
  { ref.test/ref.cast carry the non-null subopcode; +1 is the null one. }
  ExpectPrefixed('ref.test', OPCODE_PREFIX_FB, 20, wisRefTest);
  ExpectPrefixed('ref.cast', OPCODE_PREFIX_FB, 22, wisRefCast);
  ExpectPrefixed('br_on_cast', OPCODE_PREFIX_FB, 24, wisBrOnCast);
  ExpectPrefixed('br_on_cast_fail', OPCODE_PREFIX_FB, 25, wisBrOnCast);
  ExpectPrefixed('ref.i31', OPCODE_PREFIX_FB, 28, wisNone);
  ExpectPrefixed('i31.get_s', OPCODE_PREFIX_FB, 29, wisNone);
  ExpectPrefixed('any.convert_extern', OPCODE_PREFIX_FB, 26, wisNone);
  ExpectPrefixed('extern.convert_any', OPCODE_PREFIX_FB, 27, wisNone);
end;

procedure TWatOpcodesTests.TestNoDuplicateMnemonics;
begin
  { A duplicate Add would collapse in the dictionary and shadow the
    earlier row silently; the builder counts them so the suite can gate
    on zero. }
  Expect<Integer>(DuplicateMnemonicCount).ToBe(0);
end;

procedure TWatOpcodesTests.TestUnknownAndObsoleteAbsent;
begin
  { The obsolete spellings the text format dropped must not resolve — the
    assembler needs them to fall to the unknown-operator path. }
  Expect<Boolean>(HasOpcode('get_local')).ToBe(False);
  Expect<Boolean>(HasOpcode('set_local')).ToBe(False);
  Expect<Boolean>(HasOpcode('current_memory')).ToBe(False);
  Expect<Boolean>(HasOpcode('i32.wrap/i64')).ToBe(False);
  { Not an instruction at all. }
  Expect<Boolean>(HasOpcode('totally.not.an.op')).ToBe(False);
end;

procedure TWatOpcodesTests.TestVectorFamilyOpcodesAndShapes;
begin
  { $FD vector rows, one representative per immediate shape. Subopcodes are
    the pinned spec's (wasm-mcp category=vec / category=memory prefix=v128.). }
  { plain memarg load/store (wisMemArg). }
  ExpectVector('v128.load', 0, wisMemArg, 4);
  ExpectVector('v128.store', 11, wisMemArg, 4);
  ExpectVector('v128.load32_zero', 92, wisMemArg, 2);
  { 16-byte immediates. }
  ExpectVector('v128.const', 12, wisV128Const, 0);
  ExpectVector('i8x16.shuffle', 13, wisShuffle, 0);
  { one laneidx byte. }
  ExpectVector('i8x16.extract_lane_s', 21, wisLane, 0);
  ExpectVector('f64x2.replace_lane', 34, wisLane, 0);
  { memarg then laneidx. }
  ExpectVector('v128.load8_lane', 84, wisMemArgLane, 0);
  ExpectVector('v128.store64_lane', 91, wisMemArgLane, 3);
  { plain no-immediate ops, including a multi-byte-LEB subopcode and the two
    top relaxed ops (275 exercises the widened UInt32 field). }
  ExpectVector('i8x16.swizzle', 14, wisNone, 0);
  ExpectVector('i32x4.splat', 17, wisNone, 0);
  ExpectVector('v128.bitselect', 82, wisNone, 0);
  ExpectVector('i16x8.abs', 128, wisNone, 0);
  ExpectVector('f64x2.convert_low_i32x4_u', 255, wisNone, 0);
  ExpectVector('i8x16.relaxed_swizzle', 256, wisNone, 0);
  ExpectVector('i32x4.relaxed_dot_i8x16_i7x16_add_s', 275, wisNone, 0);
  { the unassigned subopcodes stay absent (154 / 162 / 226 / 238). }
  Expect<Boolean>(HasOpcode('i16x8.opcode154')).ToBe(False);
end;

procedure TWatOpcodesTests.TestVectorMemoryFamilyNaturalAlignment;
begin
  { Natural alignments from simd_align.wast (the align= upstream marks
    assert_invalid is one power of two above these). }
  ExpectVector('v128.load8x8_s', 1, wisMemArg, 3);
  ExpectVector('v128.load16x4_u', 4, wisMemArg, 3);
  ExpectVector('v128.load8_splat', 7, wisMemArg, 0);
  ExpectVector('v128.load16_splat', 8, wisMemArg, 1);
  ExpectVector('v128.load32_splat', 9, wisMemArg, 2);
  ExpectVector('v128.load64_splat', 10, wisMemArg, 3);
  ExpectVector('v128.load64_zero', 93, wisMemArg, 3);
  ExpectVector('v128.load16_lane', 85, wisMemArgLane, 1);
  ExpectVector('v128.load32_lane', 86, wisMemArgLane, 2);
  ExpectVector('v128.store8_lane', 88, wisMemArgLane, 0);
end;

procedure TWatOpcodesTests.TestVectorRelaxedTruncSpelling;
var
  Found: TWasmOpcodeInfo;
begin
  { The f64x2 relaxed-trunc ops are spelled WITHOUT _zero to match the IR
    registry (design deviation note in Wasm.Ir); subopcodes 259/260. The
    _zero spellings (which the corpus uses) must NOT resolve here. }
  ExpectVector('i32x4.relaxed_trunc_f64x2_s', 259, wisNone, 0);
  ExpectVector('i32x4.relaxed_trunc_f64x2_u', 260, wisNone, 0);
  { The corpus (testsuite@de54fd27) writes the older _zero spelling, so those
    are accepted as text aliases onto the same subopcodes 259/260. }
  ExpectVector('i32x4.relaxed_trunc_f64x2_s_zero', 259, wisNone, 0);
  ExpectVector('i32x4.relaxed_trunc_f64x2_u_zero', 260, wisNone, 0);
  { The f32x4 relaxed-trunc ops keep their spelling (no _zero either). }
  ExpectVector('i32x4.relaxed_trunc_f32x4_s', 257, wisNone, 0);
  Expect<Boolean>(LookupOpcode('i32x4.relaxed_trunc_f32x4_s', Found)).ToBe(True);
end;

procedure TWatOpcodesTests.TestTableSizeFloor;
begin
  { The full 3.0 set: 238 non-vector mnemonics plus the 256 assigned $FD
    vector subopcodes = 494, plus 2 text aliases for the f64x2 relaxed-trunc
    ops (the corpus's _s_zero / _u_zero spelling onto subopcodes 259/260) =
    496. Asserted exactly so an accidental add or drop shows up rather than
    passing vacuously. }
  Expect<Integer>(OpcodeCount).ToBe(496);
end;

procedure TWatOpcodesTests.SetupTests;
begin
  Test('control family opcodes and shapes', TestControlFamily);
  Test('variable and parametric opcodes', TestVariableAndParametric);
  Test('memory family opcodes and natural alignment',
    TestMemoryFamilyAndNaturalAlignment);
  Test('const family opcodes and shapes', TestConstFamily);
  Test('numeric family boundaries', TestNumericFamily);
  Test('reference family opcodes', TestRefFamily);
  Test('$FC-prefixed family opcodes and shapes', TestMiscPrefixedFamily);
  Test('$FB-prefixed aggregate family opcodes and shapes',
    TestAggregatePrefixedFamily);
  Test('no mnemonic is added twice', TestNoDuplicateMnemonics);
  Test('unknown and obsolete mnemonics are absent',
    TestUnknownAndObsoleteAbsent);
  Test('$FD vector family opcodes and immediate shapes',
    TestVectorFamilyOpcodesAndShapes);
  Test('$FD vector memory family natural alignment',
    TestVectorMemoryFamilyNaturalAlignment);
  Test('relaxed_trunc f64x2 spelling matches the IR registry (no _zero)',
    TestVectorRelaxedTruncSpelling);
  Test('the table has the full 3.0 set (non-vector + vector)',
    TestTableSizeFloor);
end;

begin
  TestRunnerProgram.AddSuite(
    TWatOpcodesTests.Create('Wasm.Wat.Opcodes'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
