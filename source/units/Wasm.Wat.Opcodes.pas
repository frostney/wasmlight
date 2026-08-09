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
  hard-codes an opcode; Track G appends ~256 vector rows to it without
  touching the grammar, which is why the table is data-driven and lives in
  its own unit (.agent/design/wat-assembler.md §6).

  SIMD is out of scope here. The whole $FD vector space — including the
  v128 loads/stores that the spec files under the "memory" category — is
  Track G and is deliberately absent, marked by the GAP note in
  the builder. An assembler that finds no row for a mnemonic reports it as
  the reserved-token / unknown-operator case; that is the lexer's and the
  assembler's job, so a missing row here is exactly the right signal, and
  obsolete spellings the format dropped (`get_local`, `i32.wrap/i64`, …)
  are simply never added.

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
    wisTableTable     { tableidx then tableidx }
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
    Opcode: Byte;
    Shape: TWasmImmShape;
    NaturalAlignLog2: Byte;
  end;

{ The $FB and $FC prefix bytes, exposed for the encoder that writes a
  prefixed instruction as [Prefix][u32 subopcode]. }
const
  OPCODE_PREFIX_FB = $FB;  { aggregate / GC space }
  OPCODE_PREFIX_FC = $FC;  { saturating truncation + bulk memory/table }

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

  { GAP — the $FD vector space (v128 loads/stores, lane ops, splats,
    shuffles) is Track G and is intentionally not added here. }
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
