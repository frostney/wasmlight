{ Wasm.Wat.Opcodes — the mnemonic table: every non-vector instruction
  spelling mapped to its opcode byte(s), its immediate shape, and (for
  memory instructions) its natural alignment.

  This is the MIRROR of Wasm.Decoder.Expr's opcode-to-immediate dispatch.
  Where the skipper reads "op $28..$3E → one memarg", this table records
  "i32.load → opcode $28, shape one memarg, natural align 4"; where the
  skipper reads "$FB sub 2 → typeidx + fieldidx", this records
  "struct.get → prefix $FB sub 2, shape typeidx+fieldidx". The opcode
  bytes and subopcodes were taken from the pinned spec's instruction
  tables (wasm-mcp, spec/main @ d7b37e4), not recalled, and cross-checked
  against the ranges Wasm.Decoder.Expr already enforces.

  The grammar (the Track C assembler) consumes this table and never
  hard-codes an opcode; the table is data-driven and lives in its own unit
  (.agent/design/wat-assembler.md §6) so that families can be appended
  without touching the grammar.

  The $FD vector space is present: BuildVector adds the 256 assigned
  subopcodes (0..275 minus the 20 unassigned), including the v128
  loads/stores the spec files under the "memory" category. Four immediate
  shapes are unique to it — wisV128Const, wisShuffle, wisLane,
  wisMemArgLane — the rest reuse wisNone (plain-$FD ops with only stack
  operands) and wisMemArg (the plain load/store family, with a natural
  alignment). An assembler that finds no row for a mnemonic reports it as
  the reserved-token / unknown-operator case; a missing row is the right
  signal, and obsolete spellings the format dropped (`get_local`,
  `i32.wrap/i64`, …) are simply never added.

  https://webassembly.github.io/spec/core/binary/instructions.html }
unit Wasm.Wat.Opcodes;

{$I Shared.inc}

interface

uses
  Generics.Collections,
  SysUtils;

type
  { The immediate shape that follows an opcode, at the granularity the
    decoder distinguishes AND the assembler must resolve. Encoding-
    identical immediates that resolve against different index spaces are
    kept apart (a labelidx needs the label stack, a funcidx the function
    space), because the assembler needs to know which. }
  TWasmImmShape = (
    wisNone,          { no immediates }
    wisBlockType,     { block / loop / if }
    wisTryTable,      { block type then a catch-clause vector }
    wisLabel,         { one labelidx }
    wisBrTable,       { vec(labelidx) then a default labelidx }
    wisFunc,          { one funcidx }
    wisType,          { one typeidx }
    wisTag,           { one tagidx }
    wisLocal,         { one localidx }
    wisGlobal,        { one globalidx }
    wisTable,         { one tableidx }
    wisMem,           { one memidx }
    wisCallIndirect,  { typeidx then tableidx }
    wisMemArg,        { a memarg (align/offset, optional memidx) }
    wisHeapType,      { one heap type (ref.null) }
    wisSelect,        { optional result-type vector (see note below) }
    wisConstI32,      { an i32 literal }
    wisConstI64,      { an i64 literal }
    wisConstF32,      { an f32 literal }
    wisConstF64,      { an f64 literal }
    wisRefTest,       { one heap type; null variant is the +1 subopcode }
    wisRefCast,       { one heap type; null variant is the +1 subopcode }
    wisBrOnCast,      { castflags, labelidx, then TWO heap types }
    wisTypeField,     { typeidx then fieldidx }
    wisTypeCount,     { typeidx then a u32 count }
    wisTypeData,      { typeidx then dataidx }
    wisTypeElem,      { typeidx then elemidx }
    wisTypeType,      { typeidx then typeidx }
    wisData,          { one dataidx }
    wisElem,          { one elemidx }
    wisDataMem,       { dataidx then memidx }
    wisMemMem,        { memidx then memidx }
    wisElemTable,     { elemidx then tableidx }
    wisTableTable,    { tableidx then tableidx }

    { $FD vector immediate shapes (Track G). }
    wisV128Const,     { v128.const: a shape keyword then N lane literals }
    wisShuffle,       { i8x16.shuffle: 16 bare lane indices }
    wisLane,          { extract/replace_lane: one laneidx byte }
    wisMemArgLane     { load/store lane: a memarg then one laneidx byte }
  );

  { One instruction row. For a single-byte opcode HasPrefix is False and
    Opcode is the byte; for a $FB/$FC-prefixed instruction HasPrefix is
    True, Prefix is $FB or $FC, and Opcode is the subopcode (which the
    encoder writes as a u32 LEB after the prefix byte). NaturalAlignLog2
    is the log2 of the access size, the default `align` for a memarg, and
    is meaningful only when Shape = wisMemArg.

    Two mnemonics map to a family of opcodes rather than one, and the
    Opcode field holds the BASE:
      - `select`: bare form is this Opcode ($1B); the type-annotated form
        the assembler emits when result types are present is Opcode+1
        ($1C, a vec(valtype) immediate).
      - `ref.test` / `ref.cast`: this Opcode is the non-null variant; the
        null variant (a `(ref null ht)` operand) is Opcode+1. }
  TWasmOpcodeInfo = record
    Mnemonic: string;
    HasPrefix: Boolean;
    Prefix: Byte;
    Opcode: UInt32;   { was Byte — $FD vector subopcodes reach 275 }
    Shape: TWasmImmShape;
    NaturalAlignLog2: Byte;
  end;

{ The $FB and $FC prefix bytes, exposed for the encoder that writes a
  prefixed instruction as [Prefix][u32 subopcode]. }
const
  OPCODE_PREFIX_FB = $FB;  { aggregate / GC space }
  OPCODE_PREFIX_FC = $FC;  { saturating truncation + bulk memory/table }
  OPCODE_PREFIX_FD = $FD;  { vector (v128 / SIMD) space }

{ Looks up a text mnemonic. Returns False for any spelling not in the
  table — an unknown mnemonic, an obsolete keyword, or a vector
  instruction that is not yet added. }
function LookupOpcode(const AMnemonic: string;
  out AInfo: TWasmOpcodeInfo): Boolean;

{ True when the mnemonic has a row. }
function HasOpcode(const AMnemonic: string): Boolean;

{ The number of distinct mnemonics in the table. }
function OpcodeCount: Integer;

{ The number of mnemonics that were added more than once — a build-time
  self-check the test asserts is zero, so a copy-paste duplicate in the
  builder cannot silently shadow an earlier row. }
function DuplicateMnemonicCount: Integer;

implementation

var
  FTable: TDictionary<string, TWasmOpcodeInfo>;
  FDuplicates: Integer;

{ Adds a single-byte-opcode row. }
procedure Add1(const AMnemonic: string; const AOpcode: Byte;
  const AShape: TWasmImmShape);
var
  Info: TWasmOpcodeInfo;
begin
  Info.Mnemonic := AMnemonic;
  Info.HasPrefix := False;
  Info.Prefix := 0;
  Info.Opcode := AOpcode;
  Info.Shape := AShape;
  Info.NaturalAlignLog2 := 0;
  if FTable.ContainsKey(AMnemonic) then
    Inc(FDuplicates);
  FTable.AddOrSetValue(AMnemonic, Info);
end;

{ Adds a memory-instruction row: single-byte opcode plus a natural
  alignment. }
procedure AddMem(const AMnemonic: string; const AOpcode: Byte;
  const AAlignLog2: Byte);
var
  Info: TWasmOpcodeInfo;
begin
  Info.Mnemonic := AMnemonic;
  Info.HasPrefix := False;
  Info.Prefix := 0;
  Info.Opcode := AOpcode;
  Info.Shape := wisMemArg;
  Info.NaturalAlignLog2 := AAlignLog2;
  if FTable.ContainsKey(AMnemonic) then
    Inc(FDuplicates);
  FTable.AddOrSetValue(AMnemonic, Info);
end;

{ Adds a prefixed-opcode row ($FB or $FC). }
procedure AddP(const AMnemonic: string; const APrefix, ASub: Byte;
  const AShape: TWasmImmShape);
var
  Info: TWasmOpcodeInfo;
begin
  Info.Mnemonic := AMnemonic;
  Info.HasPrefix := True;
  Info.Prefix := APrefix;
  Info.Opcode := ASub;
  Info.Shape := AShape;
  Info.NaturalAlignLog2 := 0;
  if FTable.ContainsKey(AMnemonic) then
    Inc(FDuplicates);
  FTable.AddOrSetValue(AMnemonic, Info);
end;

{ Adds a $FD vector row: the prefix is fixed, the subopcode is a u32 (the
  encoder writes it as a u32 LEB after the prefix byte), the shape is one of
  the vector shapes (or wisNone / wisMemArg for the plain families), and
  AAlignLog2 is the natural alignment (meaningful only for wisMemArg /
  wisMemArgLane). }
procedure AddVec(const AMnemonic: string; const ASub: UInt32;
  const AShape: TWasmImmShape; const AAlignLog2: Byte);
var
  Info: TWasmOpcodeInfo;
begin
  Info.Mnemonic := AMnemonic;
  Info.HasPrefix := True;
  Info.Prefix := OPCODE_PREFIX_FD;
  Info.Opcode := ASub;
  Info.Shape := AShape;
  Info.NaturalAlignLog2 := AAlignLog2;
  if FTable.ContainsKey(AMnemonic) then
    Inc(FDuplicates);
  FTable.AddOrSetValue(AMnemonic, Info);
end;

procedure BuildControl;
begin
  Add1('unreachable', $00, wisNone);
  Add1('nop', $01, wisNone);
  Add1('block', $02, wisBlockType);
  Add1('loop', $03, wisBlockType);
  Add1('if', $04, wisBlockType);
  Add1('throw', $08, wisTag);
  Add1('throw_ref', $0A, wisNone);
  Add1('br', $0C, wisLabel);
  Add1('br_if', $0D, wisLabel);
  Add1('br_table', $0E, wisBrTable);
  Add1('return', $0F, wisNone);
  Add1('call', $10, wisFunc);
  Add1('call_indirect', $11, wisCallIndirect);
  Add1('return_call', $12, wisFunc);
  Add1('return_call_indirect', $13, wisCallIndirect);
  Add1('call_ref', $14, wisType);
  Add1('return_call_ref', $15, wisType);
  Add1('try_table', $1F, wisTryTable);
end;

procedure BuildParametricAndVariable;
begin
  Add1('drop', $1A, wisNone);
  { select: bare form here; type-annotated form is $1C (Opcode+1). }
  Add1('select', $1B, wisSelect);

  Add1('local.get', $20, wisLocal);
  Add1('local.set', $21, wisLocal);
  Add1('local.tee', $22, wisLocal);
  Add1('global.get', $23, wisGlobal);
  Add1('global.set', $24, wisGlobal);
end;

procedure BuildTableAndMemoryOps;
begin
  Add1('table.get', $25, wisTable);
  Add1('table.set', $26, wisTable);

  { Loads and stores: one memarg each, with the natural alignment (log2
    of the access size in bytes) that is the default when `align=` is
    omitted. }
  AddMem('i32.load', $28, 2);
  AddMem('i64.load', $29, 3);
  AddMem('f32.load', $2A, 2);
  AddMem('f64.load', $2B, 3);
  AddMem('i32.load8_s', $2C, 0);
  AddMem('i32.load8_u', $2D, 0);
  AddMem('i32.load16_s', $2E, 1);
  AddMem('i32.load16_u', $2F, 1);
  AddMem('i64.load8_s', $30, 0);
  AddMem('i64.load8_u', $31, 0);
  AddMem('i64.load16_s', $32, 1);
  AddMem('i64.load16_u', $33, 1);
  AddMem('i64.load32_s', $34, 2);
  AddMem('i64.load32_u', $35, 2);
  AddMem('i32.store', $36, 2);
  AddMem('i64.store', $37, 3);
  AddMem('f32.store', $38, 2);
  AddMem('f64.store', $39, 3);
  AddMem('i32.store8', $3A, 0);
  AddMem('i32.store16', $3B, 1);
  AddMem('i64.store8', $3C, 0);
  AddMem('i64.store16', $3D, 1);
  AddMem('i64.store32', $3E, 2);

  Add1('memory.size', $3F, wisMem);
  Add1('memory.grow', $40, wisMem);
end;

procedure BuildConst;
begin
  Add1('i32.const', $41, wisConstI32);
  Add1('i64.const', $42, wisConstI64);
  Add1('f32.const', $43, wisConstF32);
  Add1('f64.const', $44, wisConstF64);
end;

{ Numeric $45..$C4: comparisons, unary/binary arithmetic, conversions,
  reinterpretations, sign extensions — all with no immediate. Opcodes are
  contiguous and in the spec's table order. }
procedure BuildNumeric;
begin
  Add1('i32.eqz', $45, wisNone);
  Add1('i32.eq', $46, wisNone);
  Add1('i32.ne', $47, wisNone);
  Add1('i32.lt_s', $48, wisNone);
  Add1('i32.lt_u', $49, wisNone);
  Add1('i32.gt_s', $4A, wisNone);
  Add1('i32.gt_u', $4B, wisNone);
  Add1('i32.le_s', $4C, wisNone);
  Add1('i32.le_u', $4D, wisNone);
  Add1('i32.ge_s', $4E, wisNone);
  Add1('i32.ge_u', $4F, wisNone);
  Add1('i64.eqz', $50, wisNone);
  Add1('i64.eq', $51, wisNone);
  Add1('i64.ne', $52, wisNone);
  Add1('i64.lt_s', $53, wisNone);
  Add1('i64.lt_u', $54, wisNone);
  Add1('i64.gt_s', $55, wisNone);
  Add1('i64.gt_u', $56, wisNone);
  Add1('i64.le_s', $57, wisNone);
  Add1('i64.le_u', $58, wisNone);
  Add1('i64.ge_s', $59, wisNone);
  Add1('i64.ge_u', $5A, wisNone);
  Add1('f32.eq', $5B, wisNone);
  Add1('f32.ne', $5C, wisNone);
  Add1('f32.lt', $5D, wisNone);
  Add1('f32.gt', $5E, wisNone);
  Add1('f32.le', $5F, wisNone);
  Add1('f32.ge', $60, wisNone);
  Add1('f64.eq', $61, wisNone);
  Add1('f64.ne', $62, wisNone);
  Add1('f64.lt', $63, wisNone);
  Add1('f64.gt', $64, wisNone);
  Add1('f64.le', $65, wisNone);
  Add1('f64.ge', $66, wisNone);
  Add1('i32.clz', $67, wisNone);
  Add1('i32.ctz', $68, wisNone);
  Add1('i32.popcnt', $69, wisNone);
  Add1('i32.add', $6A, wisNone);
  Add1('i32.sub', $6B, wisNone);
  Add1('i32.mul', $6C, wisNone);
  Add1('i32.div_s', $6D, wisNone);
  Add1('i32.div_u', $6E, wisNone);
  Add1('i32.rem_s', $6F, wisNone);
  Add1('i32.rem_u', $70, wisNone);
  Add1('i32.and', $71, wisNone);
  Add1('i32.or', $72, wisNone);
  Add1('i32.xor', $73, wisNone);
  Add1('i32.shl', $74, wisNone);
  Add1('i32.shr_s', $75, wisNone);
  Add1('i32.shr_u', $76, wisNone);
  Add1('i32.rotl', $77, wisNone);
  Add1('i32.rotr', $78, wisNone);
  Add1('i64.clz', $79, wisNone);
  Add1('i64.ctz', $7A, wisNone);
  Add1('i64.popcnt', $7B, wisNone);
  Add1('i64.add', $7C, wisNone);
  Add1('i64.sub', $7D, wisNone);
  Add1('i64.mul', $7E, wisNone);
  Add1('i64.div_s', $7F, wisNone);
  Add1('i64.div_u', $80, wisNone);
  Add1('i64.rem_s', $81, wisNone);
  Add1('i64.rem_u', $82, wisNone);
  Add1('i64.and', $83, wisNone);
  Add1('i64.or', $84, wisNone);
  Add1('i64.xor', $85, wisNone);
  Add1('i64.shl', $86, wisNone);
  Add1('i64.shr_s', $87, wisNone);
  Add1('i64.shr_u', $88, wisNone);
  Add1('i64.rotl', $89, wisNone);
  Add1('i64.rotr', $8A, wisNone);
  Add1('f32.abs', $8B, wisNone);
  Add1('f32.neg', $8C, wisNone);
  Add1('f32.ceil', $8D, wisNone);
  Add1('f32.floor', $8E, wisNone);
  Add1('f32.trunc', $8F, wisNone);
  Add1('f32.nearest', $90, wisNone);
  Add1('f32.sqrt', $91, wisNone);
  Add1('f32.add', $92, wisNone);
  Add1('f32.sub', $93, wisNone);
  Add1('f32.mul', $94, wisNone);
  Add1('f32.div', $95, wisNone);
  Add1('f32.min', $96, wisNone);
  Add1('f32.max', $97, wisNone);
  Add1('f32.copysign', $98, wisNone);
  Add1('f64.abs', $99, wisNone);
  Add1('f64.neg', $9A, wisNone);
  Add1('f64.ceil', $9B, wisNone);
  Add1('f64.floor', $9C, wisNone);
  Add1('f64.trunc', $9D, wisNone);
  Add1('f64.nearest', $9E, wisNone);
  Add1('f64.sqrt', $9F, wisNone);
  Add1('f64.add', $A0, wisNone);
  Add1('f64.sub', $A1, wisNone);
  Add1('f64.mul', $A2, wisNone);
  Add1('f64.div', $A3, wisNone);
  Add1('f64.min', $A4, wisNone);
  Add1('f64.max', $A5, wisNone);
  Add1('f64.copysign', $A6, wisNone);
  Add1('i32.wrap_i64', $A7, wisNone);
  Add1('i32.trunc_f32_s', $A8, wisNone);
  Add1('i32.trunc_f32_u', $A9, wisNone);
  Add1('i32.trunc_f64_s', $AA, wisNone);
  Add1('i32.trunc_f64_u', $AB, wisNone);
  Add1('i64.extend_i32_s', $AC, wisNone);
  Add1('i64.extend_i32_u', $AD, wisNone);
  Add1('i64.trunc_f32_s', $AE, wisNone);
  Add1('i64.trunc_f32_u', $AF, wisNone);
  Add1('i64.trunc_f64_s', $B0, wisNone);
  Add1('i64.trunc_f64_u', $B1, wisNone);
  Add1('f32.convert_i32_s', $B2, wisNone);
  Add1('f32.convert_i32_u', $B3, wisNone);
  Add1('f32.convert_i64_s', $B4, wisNone);
  Add1('f32.convert_i64_u', $B5, wisNone);
  Add1('f32.demote_f64', $B6, wisNone);
  Add1('f64.convert_i32_s', $B7, wisNone);
  Add1('f64.convert_i32_u', $B8, wisNone);
  Add1('f64.convert_i64_s', $B9, wisNone);
  Add1('f64.convert_i64_u', $BA, wisNone);
  Add1('f64.promote_f32', $BB, wisNone);
  Add1('i32.reinterpret_f32', $BC, wisNone);
  Add1('i64.reinterpret_f64', $BD, wisNone);
  Add1('f32.reinterpret_i32', $BE, wisNone);
  Add1('f64.reinterpret_i64', $BF, wisNone);
  Add1('i32.extend8_s', $C0, wisNone);
  Add1('i32.extend16_s', $C1, wisNone);
  Add1('i64.extend8_s', $C2, wisNone);
  Add1('i64.extend16_s', $C3, wisNone);
  Add1('i64.extend32_s', $C4, wisNone);
end;

procedure BuildRef;
begin
  Add1('ref.null', $D0, wisHeapType);
  Add1('ref.is_null', $D1, wisNone);
  Add1('ref.func', $D2, wisFunc);
  Add1('ref.eq', $D3, wisNone);
  Add1('ref.as_non_null', $D4, wisNone);
  Add1('br_on_null', $D5, wisLabel);
  Add1('br_on_non_null', $D6, wisLabel);
end;

{ The $FC space: saturating truncations (no immediates) and the bulk
  memory/table instructions. }
procedure BuildMisc;
begin
  AddP('i32.trunc_sat_f32_s', OPCODE_PREFIX_FC, 0, wisNone);
  AddP('i32.trunc_sat_f32_u', OPCODE_PREFIX_FC, 1, wisNone);
  AddP('i32.trunc_sat_f64_s', OPCODE_PREFIX_FC, 2, wisNone);
  AddP('i32.trunc_sat_f64_u', OPCODE_PREFIX_FC, 3, wisNone);
  AddP('i64.trunc_sat_f32_s', OPCODE_PREFIX_FC, 4, wisNone);
  AddP('i64.trunc_sat_f32_u', OPCODE_PREFIX_FC, 5, wisNone);
  AddP('i64.trunc_sat_f64_s', OPCODE_PREFIX_FC, 6, wisNone);
  AddP('i64.trunc_sat_f64_u', OPCODE_PREFIX_FC, 7, wisNone);

  AddP('memory.init', OPCODE_PREFIX_FC, 8, wisDataMem);
  AddP('data.drop', OPCODE_PREFIX_FC, 9, wisData);
  AddP('memory.copy', OPCODE_PREFIX_FC, 10, wisMemMem);
  AddP('memory.fill', OPCODE_PREFIX_FC, 11, wisMem);
  AddP('table.init', OPCODE_PREFIX_FC, 12, wisElemTable);
  AddP('elem.drop', OPCODE_PREFIX_FC, 13, wisElem);
  AddP('table.copy', OPCODE_PREFIX_FC, 14, wisTableTable);
  AddP('table.grow', OPCODE_PREFIX_FC, 15, wisTable);
  AddP('table.size', OPCODE_PREFIX_FC, 16, wisTable);
  AddP('table.fill', OPCODE_PREFIX_FC, 17, wisTable);
end;

{ The $FB aggregate / GC space: structs, arrays, i31, and the ref
  test/cast and cast-branch instructions. }
procedure BuildAggregate;
begin
  AddP('struct.new', OPCODE_PREFIX_FB, 0, wisType);
  AddP('struct.new_default', OPCODE_PREFIX_FB, 1, wisType);
  AddP('struct.get', OPCODE_PREFIX_FB, 2, wisTypeField);
  AddP('struct.get_s', OPCODE_PREFIX_FB, 3, wisTypeField);
  AddP('struct.get_u', OPCODE_PREFIX_FB, 4, wisTypeField);
  AddP('struct.set', OPCODE_PREFIX_FB, 5, wisTypeField);

  AddP('array.new', OPCODE_PREFIX_FB, 6, wisType);
  AddP('array.new_default', OPCODE_PREFIX_FB, 7, wisType);
  AddP('array.new_fixed', OPCODE_PREFIX_FB, 8, wisTypeCount);
  AddP('array.new_data', OPCODE_PREFIX_FB, 9, wisTypeData);
  AddP('array.new_elem', OPCODE_PREFIX_FB, 10, wisTypeElem);
  AddP('array.get', OPCODE_PREFIX_FB, 11, wisType);
  AddP('array.get_s', OPCODE_PREFIX_FB, 12, wisType);
  AddP('array.get_u', OPCODE_PREFIX_FB, 13, wisType);
  AddP('array.set', OPCODE_PREFIX_FB, 14, wisType);
  AddP('array.len', OPCODE_PREFIX_FB, 15, wisNone);
  AddP('array.fill', OPCODE_PREFIX_FB, 16, wisType);
  AddP('array.copy', OPCODE_PREFIX_FB, 17, wisTypeType);
  AddP('array.init_data', OPCODE_PREFIX_FB, 18, wisTypeData);
  AddP('array.init_elem', OPCODE_PREFIX_FB, 19, wisTypeElem);

  { ref.test / ref.cast store the non-null subopcode; the null-operand
    variant is that subopcode + 1 (20/21 and 22/23). }
  AddP('ref.test', OPCODE_PREFIX_FB, 20, wisRefTest);
  AddP('ref.cast', OPCODE_PREFIX_FB, 22, wisRefCast);
  AddP('br_on_cast', OPCODE_PREFIX_FB, 24, wisBrOnCast);
  AddP('br_on_cast_fail', OPCODE_PREFIX_FB, 25, wisBrOnCast);

  AddP('any.convert_extern', OPCODE_PREFIX_FB, 26, wisNone);
  AddP('extern.convert_any', OPCODE_PREFIX_FB, 27, wisNone);
  AddP('ref.i31', OPCODE_PREFIX_FB, 28, wisNone);
  AddP('i31.get_s', OPCODE_PREFIX_FB, 29, wisNone);
  AddP('i31.get_u', OPCODE_PREFIX_FB, 30, wisNone);
end;

{ The $FD vector space — 256 assigned subopcodes (0..275 minus the 20
  unassigned). Subopcodes and mnemonics are the pinned spec's (wasm-mcp
  spec/main @ d7b37e4, instruction_list category=vec and the 22 v128.* the
  spec files under category=memory), NOT recalled. Natural alignments for
  the memory families are from simd_align.wast (the align= upstream marks
  assert_invalid is one power of two above natural).

  ONE deliberate deviation from the spec's text: the f64x2 relaxed-trunc
  ops (subopcodes 259/260) are spelled i32x4.relaxed_trunc_f64x2_s / _u
  WITHOUT the _zero suffix, matching the IR registry (Wasm.Ir) so the
  assembler, disassembler, and corpus comparator share one spelling. }
procedure BuildVector;
begin
  { --- memory: whole/packed/splat/store — memarg (0..11) ------------- }
  AddVec('v128.load', 0, wisMemArg, 4);
  AddVec('v128.load8x8_s', 1, wisMemArg, 3);
  AddVec('v128.load8x8_u', 2, wisMemArg, 3);
  AddVec('v128.load16x4_s', 3, wisMemArg, 3);
  AddVec('v128.load16x4_u', 4, wisMemArg, 3);
  AddVec('v128.load32x2_s', 5, wisMemArg, 3);
  AddVec('v128.load32x2_u', 6, wisMemArg, 3);
  AddVec('v128.load8_splat', 7, wisMemArg, 0);
  AddVec('v128.load16_splat', 8, wisMemArg, 1);
  AddVec('v128.load32_splat', 9, wisMemArg, 2);
  AddVec('v128.load64_splat', 10, wisMemArg, 3);
  AddVec('v128.store', 11, wisMemArg, 4);

  { --- const and shuffle — 16-byte immediate (12..13) --------------- }
  AddVec('v128.const', 12, wisV128Const, 0);
  AddVec('i8x16.shuffle', 13, wisShuffle, 0);

  { --- swizzle and splat (14..20) ----------------------------------- }
  AddVec('i8x16.swizzle', 14, wisNone, 0);
  AddVec('i8x16.splat', 15, wisNone, 0);
  AddVec('i16x8.splat', 16, wisNone, 0);
  AddVec('i32x4.splat', 17, wisNone, 0);
  AddVec('i64x2.splat', 18, wisNone, 0);
  AddVec('f32x4.splat', 19, wisNone, 0);
  AddVec('f64x2.splat', 20, wisNone, 0);

  { --- lane access — one laneidx byte (21..34) ---------------------- }
  AddVec('i8x16.extract_lane_s', 21, wisLane, 0);
  AddVec('i8x16.extract_lane_u', 22, wisLane, 0);
  AddVec('i8x16.replace_lane', 23, wisLane, 0);
  AddVec('i16x8.extract_lane_s', 24, wisLane, 0);
  AddVec('i16x8.extract_lane_u', 25, wisLane, 0);
  AddVec('i16x8.replace_lane', 26, wisLane, 0);
  AddVec('i32x4.extract_lane', 27, wisLane, 0);
  AddVec('i32x4.replace_lane', 28, wisLane, 0);
  AddVec('i64x2.extract_lane', 29, wisLane, 0);
  AddVec('i64x2.replace_lane', 30, wisLane, 0);
  AddVec('f32x4.extract_lane', 31, wisLane, 0);
  AddVec('f32x4.replace_lane', 32, wisLane, 0);
  AddVec('f64x2.extract_lane', 33, wisLane, 0);
  AddVec('f64x2.replace_lane', 34, wisLane, 0);

  { --- comparisons (35..76) ----------------------------------------- }
  AddVec('i8x16.eq', 35, wisNone, 0);
  AddVec('i8x16.ne', 36, wisNone, 0);
  AddVec('i8x16.lt_s', 37, wisNone, 0);
  AddVec('i8x16.lt_u', 38, wisNone, 0);
  AddVec('i8x16.gt_s', 39, wisNone, 0);
  AddVec('i8x16.gt_u', 40, wisNone, 0);
  AddVec('i8x16.le_s', 41, wisNone, 0);
  AddVec('i8x16.le_u', 42, wisNone, 0);
  AddVec('i8x16.ge_s', 43, wisNone, 0);
  AddVec('i8x16.ge_u', 44, wisNone, 0);
  AddVec('i16x8.eq', 45, wisNone, 0);
  AddVec('i16x8.ne', 46, wisNone, 0);
  AddVec('i16x8.lt_s', 47, wisNone, 0);
  AddVec('i16x8.lt_u', 48, wisNone, 0);
  AddVec('i16x8.gt_s', 49, wisNone, 0);
  AddVec('i16x8.gt_u', 50, wisNone, 0);
  AddVec('i16x8.le_s', 51, wisNone, 0);
  AddVec('i16x8.le_u', 52, wisNone, 0);
  AddVec('i16x8.ge_s', 53, wisNone, 0);
  AddVec('i16x8.ge_u', 54, wisNone, 0);
  AddVec('i32x4.eq', 55, wisNone, 0);
  AddVec('i32x4.ne', 56, wisNone, 0);
  AddVec('i32x4.lt_s', 57, wisNone, 0);
  AddVec('i32x4.lt_u', 58, wisNone, 0);
  AddVec('i32x4.gt_s', 59, wisNone, 0);
  AddVec('i32x4.gt_u', 60, wisNone, 0);
  AddVec('i32x4.le_s', 61, wisNone, 0);
  AddVec('i32x4.le_u', 62, wisNone, 0);
  AddVec('i32x4.ge_s', 63, wisNone, 0);
  AddVec('i32x4.ge_u', 64, wisNone, 0);
  AddVec('f32x4.eq', 65, wisNone, 0);
  AddVec('f32x4.ne', 66, wisNone, 0);
  AddVec('f32x4.lt', 67, wisNone, 0);
  AddVec('f32x4.gt', 68, wisNone, 0);
  AddVec('f32x4.le', 69, wisNone, 0);
  AddVec('f32x4.ge', 70, wisNone, 0);
  AddVec('f64x2.eq', 71, wisNone, 0);
  AddVec('f64x2.ne', 72, wisNone, 0);
  AddVec('f64x2.lt', 73, wisNone, 0);
  AddVec('f64x2.gt', 74, wisNone, 0);
  AddVec('f64x2.le', 75, wisNone, 0);
  AddVec('f64x2.ge', 76, wisNone, 0);

  { --- bitwise and the whole-vector test (77..83) ------------------- }
  AddVec('v128.not', 77, wisNone, 0);
  AddVec('v128.and', 78, wisNone, 0);
  AddVec('v128.andnot', 79, wisNone, 0);
  AddVec('v128.or', 80, wisNone, 0);
  AddVec('v128.xor', 81, wisNone, 0);
  AddVec('v128.bitselect', 82, wisNone, 0);
  AddVec('v128.any_true', 83, wisNone, 0);

  { --- memory: lane and zero — memarg+laneidx / memarg (84..93) ----- }
  AddVec('v128.load8_lane', 84, wisMemArgLane, 0);
  AddVec('v128.load16_lane', 85, wisMemArgLane, 1);
  AddVec('v128.load32_lane', 86, wisMemArgLane, 2);
  AddVec('v128.load64_lane', 87, wisMemArgLane, 3);
  AddVec('v128.store8_lane', 88, wisMemArgLane, 0);
  AddVec('v128.store16_lane', 89, wisMemArgLane, 1);
  AddVec('v128.store32_lane', 90, wisMemArgLane, 2);
  AddVec('v128.store64_lane', 91, wisMemArgLane, 3);
  AddVec('v128.load32_zero', 92, wisMemArg, 2);
  AddVec('v128.load64_zero', 93, wisMemArg, 3);

  { --- float conversions (94..95) ----------------------------------- }
  AddVec('f32x4.demote_f64x2_zero', 94, wisNone, 0);
  AddVec('f64x2.promote_low_f32x4', 95, wisNone, 0);

  { --- i8x16 unary/narrow, f32x4 rounding, i8x16 arith (96..127) ---- }
  AddVec('i8x16.abs', 96, wisNone, 0);
  AddVec('i8x16.neg', 97, wisNone, 0);
  AddVec('i8x16.popcnt', 98, wisNone, 0);
  AddVec('i8x16.all_true', 99, wisNone, 0);
  AddVec('i8x16.bitmask', 100, wisNone, 0);
  AddVec('i8x16.narrow_i16x8_s', 101, wisNone, 0);
  AddVec('i8x16.narrow_i16x8_u', 102, wisNone, 0);
  AddVec('f32x4.ceil', 103, wisNone, 0);
  AddVec('f32x4.floor', 104, wisNone, 0);
  AddVec('f32x4.trunc', 105, wisNone, 0);
  AddVec('f32x4.nearest', 106, wisNone, 0);
  AddVec('i8x16.shl', 107, wisNone, 0);
  AddVec('i8x16.shr_s', 108, wisNone, 0);
  AddVec('i8x16.shr_u', 109, wisNone, 0);
  AddVec('i8x16.add', 110, wisNone, 0);
  AddVec('i8x16.add_sat_s', 111, wisNone, 0);
  AddVec('i8x16.add_sat_u', 112, wisNone, 0);
  AddVec('i8x16.sub', 113, wisNone, 0);
  AddVec('i8x16.sub_sat_s', 114, wisNone, 0);
  AddVec('i8x16.sub_sat_u', 115, wisNone, 0);
  AddVec('f64x2.ceil', 116, wisNone, 0);
  AddVec('f64x2.floor', 117, wisNone, 0);
  AddVec('i8x16.min_s', 118, wisNone, 0);
  AddVec('i8x16.min_u', 119, wisNone, 0);
  AddVec('i8x16.max_s', 120, wisNone, 0);
  AddVec('i8x16.max_u', 121, wisNone, 0);
  AddVec('f64x2.trunc', 122, wisNone, 0);
  AddVec('i8x16.avgr_u', 123, wisNone, 0);
  AddVec('i16x8.extadd_pairwise_i8x16_s', 124, wisNone, 0);
  AddVec('i16x8.extadd_pairwise_i8x16_u', 125, wisNone, 0);
  AddVec('i32x4.extadd_pairwise_i16x8_s', 126, wisNone, 0);
  AddVec('i32x4.extadd_pairwise_i16x8_u', 127, wisNone, 0);

  { --- i16x8 (128..159; 154 unassigned) ----------------------------- }
  AddVec('i16x8.abs', 128, wisNone, 0);
  AddVec('i16x8.neg', 129, wisNone, 0);
  AddVec('i16x8.q15mulr_sat_s', 130, wisNone, 0);
  AddVec('i16x8.all_true', 131, wisNone, 0);
  AddVec('i16x8.bitmask', 132, wisNone, 0);
  AddVec('i16x8.narrow_i32x4_s', 133, wisNone, 0);
  AddVec('i16x8.narrow_i32x4_u', 134, wisNone, 0);
  AddVec('i16x8.extend_low_i8x16_s', 135, wisNone, 0);
  AddVec('i16x8.extend_high_i8x16_s', 136, wisNone, 0);
  AddVec('i16x8.extend_low_i8x16_u', 137, wisNone, 0);
  AddVec('i16x8.extend_high_i8x16_u', 138, wisNone, 0);
  AddVec('i16x8.shl', 139, wisNone, 0);
  AddVec('i16x8.shr_s', 140, wisNone, 0);
  AddVec('i16x8.shr_u', 141, wisNone, 0);
  AddVec('i16x8.add', 142, wisNone, 0);
  AddVec('i16x8.add_sat_s', 143, wisNone, 0);
  AddVec('i16x8.add_sat_u', 144, wisNone, 0);
  AddVec('i16x8.sub', 145, wisNone, 0);
  AddVec('i16x8.sub_sat_s', 146, wisNone, 0);
  AddVec('i16x8.sub_sat_u', 147, wisNone, 0);
  AddVec('f64x2.nearest', 148, wisNone, 0);
  AddVec('i16x8.mul', 149, wisNone, 0);
  AddVec('i16x8.min_s', 150, wisNone, 0);
  AddVec('i16x8.min_u', 151, wisNone, 0);
  AddVec('i16x8.max_s', 152, wisNone, 0);
  AddVec('i16x8.max_u', 153, wisNone, 0);
  AddVec('i16x8.avgr_u', 155, wisNone, 0);
  AddVec('i16x8.extmul_low_i8x16_s', 156, wisNone, 0);
  AddVec('i16x8.extmul_high_i8x16_s', 157, wisNone, 0);
  AddVec('i16x8.extmul_low_i8x16_u', 158, wisNone, 0);
  AddVec('i16x8.extmul_high_i8x16_u', 159, wisNone, 0);

  { --- i32x4 (160..191; 162,165,166,175,176,178..180,187 unassigned) - }
  AddVec('i32x4.abs', 160, wisNone, 0);
  AddVec('i32x4.neg', 161, wisNone, 0);
  AddVec('i32x4.all_true', 163, wisNone, 0);
  AddVec('i32x4.bitmask', 164, wisNone, 0);
  AddVec('i32x4.extend_low_i16x8_s', 167, wisNone, 0);
  AddVec('i32x4.extend_high_i16x8_s', 168, wisNone, 0);
  AddVec('i32x4.extend_low_i16x8_u', 169, wisNone, 0);
  AddVec('i32x4.extend_high_i16x8_u', 170, wisNone, 0);
  AddVec('i32x4.shl', 171, wisNone, 0);
  AddVec('i32x4.shr_s', 172, wisNone, 0);
  AddVec('i32x4.shr_u', 173, wisNone, 0);
  AddVec('i32x4.add', 174, wisNone, 0);
  AddVec('i32x4.sub', 177, wisNone, 0);
  AddVec('i32x4.mul', 181, wisNone, 0);
  AddVec('i32x4.min_s', 182, wisNone, 0);
  AddVec('i32x4.min_u', 183, wisNone, 0);
  AddVec('i32x4.max_s', 184, wisNone, 0);
  AddVec('i32x4.max_u', 185, wisNone, 0);
  AddVec('i32x4.dot_i16x8_s', 186, wisNone, 0);
  AddVec('i32x4.extmul_low_i16x8_s', 188, wisNone, 0);
  AddVec('i32x4.extmul_high_i16x8_s', 189, wisNone, 0);
  AddVec('i32x4.extmul_low_i16x8_u', 190, wisNone, 0);
  AddVec('i32x4.extmul_high_i16x8_u', 191, wisNone, 0);

  { --- i64x2 (192..223; 194,197,198,207,208,210..212 unassigned) ---- }
  AddVec('i64x2.abs', 192, wisNone, 0);
  AddVec('i64x2.neg', 193, wisNone, 0);
  AddVec('i64x2.all_true', 195, wisNone, 0);
  AddVec('i64x2.bitmask', 196, wisNone, 0);
  AddVec('i64x2.extend_low_i32x4_s', 199, wisNone, 0);
  AddVec('i64x2.extend_high_i32x4_s', 200, wisNone, 0);
  AddVec('i64x2.extend_low_i32x4_u', 201, wisNone, 0);
  AddVec('i64x2.extend_high_i32x4_u', 202, wisNone, 0);
  AddVec('i64x2.shl', 203, wisNone, 0);
  AddVec('i64x2.shr_s', 204, wisNone, 0);
  AddVec('i64x2.shr_u', 205, wisNone, 0);
  AddVec('i64x2.add', 206, wisNone, 0);
  AddVec('i64x2.sub', 209, wisNone, 0);
  AddVec('i64x2.mul', 213, wisNone, 0);
  AddVec('i64x2.eq', 214, wisNone, 0);
  AddVec('i64x2.ne', 215, wisNone, 0);
  AddVec('i64x2.lt_s', 216, wisNone, 0);
  AddVec('i64x2.gt_s', 217, wisNone, 0);
  AddVec('i64x2.le_s', 218, wisNone, 0);
  AddVec('i64x2.ge_s', 219, wisNone, 0);
  AddVec('i64x2.extmul_low_i32x4_s', 220, wisNone, 0);
  AddVec('i64x2.extmul_high_i32x4_s', 221, wisNone, 0);
  AddVec('i64x2.extmul_low_i32x4_u', 222, wisNone, 0);
  AddVec('i64x2.extmul_high_i32x4_u', 223, wisNone, 0);

  { --- f32x4 / f64x2 arithmetic (224..247; 226,238 unassigned) ------ }
  AddVec('f32x4.abs', 224, wisNone, 0);
  AddVec('f32x4.neg', 225, wisNone, 0);
  AddVec('f32x4.sqrt', 227, wisNone, 0);
  AddVec('f32x4.add', 228, wisNone, 0);
  AddVec('f32x4.sub', 229, wisNone, 0);
  AddVec('f32x4.mul', 230, wisNone, 0);
  AddVec('f32x4.div', 231, wisNone, 0);
  AddVec('f32x4.min', 232, wisNone, 0);
  AddVec('f32x4.max', 233, wisNone, 0);
  AddVec('f32x4.pmin', 234, wisNone, 0);
  AddVec('f32x4.pmax', 235, wisNone, 0);
  AddVec('f64x2.abs', 236, wisNone, 0);
  AddVec('f64x2.neg', 237, wisNone, 0);
  AddVec('f64x2.sqrt', 239, wisNone, 0);
  AddVec('f64x2.add', 240, wisNone, 0);
  AddVec('f64x2.sub', 241, wisNone, 0);
  AddVec('f64x2.mul', 242, wisNone, 0);
  AddVec('f64x2.div', 243, wisNone, 0);
  AddVec('f64x2.min', 244, wisNone, 0);
  AddVec('f64x2.max', 245, wisNone, 0);
  AddVec('f64x2.pmin', 246, wisNone, 0);
  AddVec('f64x2.pmax', 247, wisNone, 0);

  { --- conversions (248..255) --------------------------------------- }
  AddVec('i32x4.trunc_sat_f32x4_s', 248, wisNone, 0);
  AddVec('i32x4.trunc_sat_f32x4_u', 249, wisNone, 0);
  AddVec('f32x4.convert_i32x4_s', 250, wisNone, 0);
  AddVec('f32x4.convert_i32x4_u', 251, wisNone, 0);
  AddVec('i32x4.trunc_sat_f64x2_s_zero', 252, wisNone, 0);
  AddVec('i32x4.trunc_sat_f64x2_u_zero', 253, wisNone, 0);
  AddVec('f64x2.convert_low_i32x4_s', 254, wisNone, 0);
  AddVec('f64x2.convert_low_i32x4_u', 255, wisNone, 0);

  { --- relaxed SIMD — the 20 3.0 additions (256..275) --------------- }
  AddVec('i8x16.relaxed_swizzle', 256, wisNone, 0);
  AddVec('i32x4.relaxed_trunc_f32x4_s', 257, wisNone, 0);
  AddVec('i32x4.relaxed_trunc_f32x4_u', 258, wisNone, 0);
  { 259/260 are spelled WITHOUT _zero to match the IR registry (see note), but
    the pinned corpus (testsuite@de54fd27, i32x4_relaxed_trunc.wast) writes the
    older _zero spelling — so the assembler ALSO accepts _s_zero / _u_zero as
    text aliases onto the same subopcodes. Only the text→opcode direction gains
    the alias; the IR/disassembler keep the single _s / _u spelling. }
  AddVec('i32x4.relaxed_trunc_f64x2_s', 259, wisNone, 0);
  AddVec('i32x4.relaxed_trunc_f64x2_u', 260, wisNone, 0);
  AddVec('i32x4.relaxed_trunc_f64x2_s_zero', 259, wisNone, 0);
  AddVec('i32x4.relaxed_trunc_f64x2_u_zero', 260, wisNone, 0);
  AddVec('f32x4.relaxed_madd', 261, wisNone, 0);
  AddVec('f32x4.relaxed_nmadd', 262, wisNone, 0);
  AddVec('f64x2.relaxed_madd', 263, wisNone, 0);
  AddVec('f64x2.relaxed_nmadd', 264, wisNone, 0);
  AddVec('i8x16.relaxed_laneselect', 265, wisNone, 0);
  AddVec('i16x8.relaxed_laneselect', 266, wisNone, 0);
  AddVec('i32x4.relaxed_laneselect', 267, wisNone, 0);
  AddVec('i64x2.relaxed_laneselect', 268, wisNone, 0);
  AddVec('f32x4.relaxed_min', 269, wisNone, 0);
  AddVec('f32x4.relaxed_max', 270, wisNone, 0);
  AddVec('f64x2.relaxed_min', 271, wisNone, 0);
  AddVec('f64x2.relaxed_max', 272, wisNone, 0);
  AddVec('i16x8.relaxed_q15mulr_s', 273, wisNone, 0);
  AddVec('i16x8.relaxed_dot_i8x16_i7x16_s', 274, wisNone, 0);
  AddVec('i32x4.relaxed_dot_i8x16_i7x16_add_s', 275, wisNone, 0);
end;

procedure BuildTable;
begin
  FDuplicates := 0;
  BuildControl;
  BuildParametricAndVariable;
  BuildTableAndMemoryOps;
  BuildConst;
  BuildNumeric;
  BuildRef;
  BuildMisc;
  BuildAggregate;
  BuildVector;
end;

function LookupOpcode(const AMnemonic: string;
  out AInfo: TWasmOpcodeInfo): Boolean;
begin
  Result := FTable.TryGetValue(AMnemonic, AInfo);
end;

function HasOpcode(const AMnemonic: string): Boolean;
begin
  Result := FTable.ContainsKey(AMnemonic);
end;

function OpcodeCount: Integer;
begin
  Result := FTable.Count;
end;

function DuplicateMnemonicCount: Integer;
begin
  Result := FDuplicates;
end;

initialization
  FTable := TDictionary<string, TWasmOpcodeInfo>.Create;
  BuildTable;

finalization
  FTable.Free;

end.
