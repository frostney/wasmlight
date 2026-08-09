{ Wasm.Ir — the register-based intermediate representation every execution
  tier consumes, and nothing else.

  Validation runs once and emits this (ADR-0007); the interpreter, the
  baseline JIT, and the AOT backend all read it and none of them reads the
  raw binary or re-derives a spec rule. The IR is register-based rather
  than stack-based (ADR-0012): virtual registers are assigned during
  validation's symbolic stack walk, and merges at control-flow joins are
  materialised as explicit moves rather than phi nodes.

  This unit holds DATA STRUCTURES ONLY, plus a disassembler. There is no
  validation logic here and there must never be: it depends on Wasm.Core
  and nothing else, which is also why it cannot see TWasmModule and why
  TWasmIrModule carries its own index-space snapshots instead of pointing
  back at the decoded model.

  LIFETIME: TWasmIrDataSegment.Bytes is a span into the module buffer, not
  a copy (ADR-0003). The IR module borrows the same buffer the decoded
  module borrowed, and that buffer must outlive BOTH. A caller that frees
  the bytes and keeps the IR has a dangling data segment.

  The IR is internal. There is no compatibility promise; IR_FORMAT_VERSION
  exists so an AOT artifact compiled against an older shape is rejected
  rather than misread.

  Spec anchors cited in comments were read from wasm-mcp 0.2.16, upstream
  spec/main d7b37e4170d8315f2f1283aed4e8076591a9a333. }
unit Wasm.Ir;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  { Bumped whenever the instruction encoding, the enum's ordinals, or the
    aux-array conventions change. ADR-0007's artifact-rejection rule reads
    this and refuses anything that does not match. Track G's SIMD ops are
    APPENDED to TWasmIrOp and will bump this to 2. }
  IR_FORMAT_VERSION = 1;

  { "This field names no register" / "no aux block". Distinct constants
    with the same value because they are read in different contexts and a
    future encoding may separate them. }
  IR_NO_REG = UInt32($FFFFFFFF);
  IR_NO_AUX = UInt32($FFFFFFFF);

  { iroJump.Imm bit 0. The epoch check (ADR-0006) and the stack map
    (ADR-0011) are emitted at exactly the instructions carrying this flag,
    plus function entry and the by-op-kind safepoints — see
    IrOpIsSafepoint. }
  IR_JUMP_SAFEPOINT = Int64($1);

{ TWasmIrOp is pinned to two bytes so TWasmIrInstr stays 24 bytes with the
  natural field alignment. This is local to this one declaration — it must
  NOT move into Shared.inc, where it would silently resize every enum in
  the project. PUSH/POP rather than `PACKENUM DEFAULT`, so the setting the
  unit was compiled with is restored rather than replaced by whatever the
  compiler's default happens to be. }
{$PUSH}
{$PACKENUM 2}
type
  { One member per IR operation, wasm-mnemonic naming, DENSE: no explicit
    ordinals and no gaps, so an interpreter's dispatch is a jump table.
    Members are grouped by family in wasm opcode order and every member
    that corresponds to a wasm instruction carries its opcode.

    Eleven wasm instructions have no member because they vanish at
    lowering (nop, block, loop, if, else, end, br, br_if, drop, the
    local.* family, try_table) and three collapse into an existing member
    (select's two encodings; ref.test's and ref.cast's nullable and
    non-nullable encodings, which differ only in a reference type carried
    in AuxRefTypes). Four members have no wasm opcode at all. }
  TWasmIrOp = (
    { --- IR-only (no wasm opcode) ------------------------------------ }
    iroMove,                    { Dest <- A }
    iroJump,                    { the only op that can carry a safepoint }
    iroBranchIf,
    iroBranchIfNot,

    { --- control (binary-instr-control) ------------------------------ }
    iroUnreachable,             { 0x00 - the "trap" op }
    iroThrow,                   { 0x08 }
    iroThrowRef,                { 0x0A }
    iroBrTable,                 { 0x0E }
    iroReturn,                  { 0x0F }
    iroCall,                    { 0x10 }
    iroCallIndirect,            { 0x11 }
    iroReturnCall,              { 0x12 }
    iroReturnCallIndirect,      { 0x13 }
    iroCallRef,                 { 0x14 }
    iroReturnCallRef,           { 0x15 }
    iroBrOnNull,                { 0xD5 }
    iroBrOnNonNull,             { 0xD6 }
    iroBrOnCast,                { 0xFB 24 }
    iroBrOnCastFail,            { 0xFB 25 }

    { --- parametric -------------------------------------------------- }
    iroSelect,                  { 0x1B and 0x1C }

    { --- variable ---------------------------------------------------- }
    iroGlobalGet,               { 0x23 }
    iroGlobalSet,               { 0x24 }

    { --- table ------------------------------------------------------- }
    iroTableGet,                { 0x25 }
    iroTableSet,                { 0x26 }
    iroTableInit,               { 0xFC 12 }
    iroElemDrop,                { 0xFC 13 }
    iroTableCopy,               { 0xFC 14 }
    iroTableGrow,               { 0xFC 15 }
    iroTableSize,               { 0xFC 16 }
    iroTableFill,               { 0xFC 17 }

    { --- memory: loads ----------------------------------------------- }
    iroI32Load,                 { 0x28 }
    iroI64Load,                 { 0x29 }
    iroF32Load,                 { 0x2A }
    iroF64Load,                 { 0x2B }
    iroI32Load8S,               { 0x2C }
    iroI32Load8U,               { 0x2D }
    iroI32Load16S,              { 0x2E }
    iroI32Load16U,              { 0x2F }
    iroI64Load8S,               { 0x30 }
    iroI64Load8U,               { 0x31 }
    iroI64Load16S,              { 0x32 }
    iroI64Load16U,              { 0x33 }
    iroI64Load32S,              { 0x34 }
    iroI64Load32U,              { 0x35 }

    { --- memory: stores ---------------------------------------------- }
    iroI32Store,                { 0x36 }
    iroI64Store,                { 0x37 }
    iroF32Store,                { 0x38 }
    iroF64Store,                { 0x39 }
    iroI32Store8,               { 0x3A }
    iroI32Store16,              { 0x3B }
    iroI64Store8,               { 0x3C }
    iroI64Store16,              { 0x3D }
    iroI64Store32,              { 0x3E }

    { --- memory: management ------------------------------------------ }
    iroMemorySize,              { 0x3F }
    iroMemoryGrow,              { 0x40 }
    iroMemoryInit,              { 0xFC 8 }
    iroDataDrop,                { 0xFC 9 }
    iroMemoryCopy,              { 0xFC 10 }
    iroMemoryFill,              { 0xFC 11 }

    { --- numeric: constants ------------------------------------------ }
    iroI32Const,                { 0x41 }
    iroI64Const,                { 0x42 }
    iroF32Const,                { 0x43 }
    iroF64Const,                { 0x44 }

    { --- numeric: i32 test/compare ----------------------------------- }
    iroI32Eqz,                  { 0x45 }
    iroI32Eq,                   { 0x46 }
    iroI32Ne,                   { 0x47 }
    iroI32LtS,                  { 0x48 }
    iroI32LtU,                  { 0x49 }
    iroI32GtS,                  { 0x4A }
    iroI32GtU,                  { 0x4B }
    iroI32LeS,                  { 0x4C }
    iroI32LeU,                  { 0x4D }
    iroI32GeS,                  { 0x4E }
    iroI32GeU,                  { 0x4F }

    { --- numeric: i64 test/compare ----------------------------------- }
    iroI64Eqz,                  { 0x50 }
    iroI64Eq,                   { 0x51 }
    iroI64Ne,                   { 0x52 }
    iroI64LtS,                  { 0x53 }
    iroI64LtU,                  { 0x54 }
    iroI64GtS,                  { 0x55 }
    iroI64GtU,                  { 0x56 }
    iroI64LeS,                  { 0x57 }
    iroI64LeU,                  { 0x58 }
    iroI64GeS,                  { 0x59 }
    iroI64GeU,                  { 0x5A }

    { --- numeric: f32 compare ---------------------------------------- }
    iroF32Eq,                   { 0x5B }
    iroF32Ne,                   { 0x5C }
    iroF32Lt,                   { 0x5D }
    iroF32Gt,                   { 0x5E }
    iroF32Le,                   { 0x5F }
    iroF32Ge,                   { 0x60 }

    { --- numeric: f64 compare ---------------------------------------- }
    iroF64Eq,                   { 0x61 }
    iroF64Ne,                   { 0x62 }
    iroF64Lt,                   { 0x63 }
    iroF64Gt,                   { 0x64 }
    iroF64Le,                   { 0x65 }
    iroF64Ge,                   { 0x66 }

    { --- numeric: i32 unary/binary ----------------------------------- }
    iroI32Clz,                  { 0x67 }
    iroI32Ctz,                  { 0x68 }
    iroI32Popcnt,               { 0x69 }
    iroI32Add,                  { 0x6A }
    iroI32Sub,                  { 0x6B }
    iroI32Mul,                  { 0x6C }
    iroI32DivS,                 { 0x6D }
    iroI32DivU,                 { 0x6E }
    iroI32RemS,                 { 0x6F }
    iroI32RemU,                 { 0x70 }
    iroI32And,                  { 0x71 }
    iroI32Or,                   { 0x72 }
    iroI32Xor,                  { 0x73 }
    iroI32Shl,                  { 0x74 }
    iroI32ShrS,                 { 0x75 }
    iroI32ShrU,                 { 0x76 }
    iroI32Rotl,                 { 0x77 }
    iroI32Rotr,                 { 0x78 }

    { --- numeric: i64 unary/binary ----------------------------------- }
    iroI64Clz,                  { 0x79 }
    iroI64Ctz,                  { 0x7A }
    iroI64Popcnt,               { 0x7B }
    iroI64Add,                  { 0x7C }
    iroI64Sub,                  { 0x7D }
    iroI64Mul,                  { 0x7E }
    iroI64DivS,                 { 0x7F }
    iroI64DivU,                 { 0x80 }
    iroI64RemS,                 { 0x81 }
    iroI64RemU,                 { 0x82 }
    iroI64And,                  { 0x83 }
    iroI64Or,                   { 0x84 }
    iroI64Xor,                  { 0x85 }
    iroI64Shl,                  { 0x86 }
    iroI64ShrS,                 { 0x87 }
    iroI64ShrU,                 { 0x88 }
    iroI64Rotl,                 { 0x89 }
    iroI64Rotr,                 { 0x8A }

    { --- numeric: f32 unary/binary ----------------------------------- }
    iroF32Abs,                  { 0x8B }
    iroF32Neg,                  { 0x8C }
    iroF32Ceil,                 { 0x8D }
    iroF32Floor,                { 0x8E }
    iroF32Trunc,                { 0x8F }
    iroF32Nearest,              { 0x90 }
    iroF32Sqrt,                 { 0x91 }
    iroF32Add,                  { 0x92 }
    iroF32Sub,                  { 0x93 }
    iroF32Mul,                  { 0x94 }
    iroF32Div,                  { 0x95 }
    iroF32Min,                  { 0x96 }
    iroF32Max,                  { 0x97 }
    iroF32Copysign,             { 0x98 }

    { --- numeric: f64 unary/binary ----------------------------------- }
    iroF64Abs,                  { 0x99 }
    iroF64Neg,                  { 0x9A }
    iroF64Ceil,                 { 0x9B }
    iroF64Floor,                { 0x9C }
    iroF64Trunc,                { 0x9D }
    iroF64Nearest,              { 0x9E }
    iroF64Sqrt,                 { 0x9F }
    iroF64Add,                  { 0xA0 }
    iroF64Sub,                  { 0xA1 }
    iroF64Mul,                  { 0xA2 }
    iroF64Div,                  { 0xA3 }
    iroF64Min,                  { 0xA4 }
    iroF64Max,                  { 0xA5 }
    iroF64Copysign,             { 0xA6 }

    { --- numeric: conversions ---------------------------------------- }
    iroI32WrapI64,              { 0xA7 }
    iroI32TruncF32S,            { 0xA8 }
    iroI32TruncF32U,            { 0xA9 }
    iroI32TruncF64S,            { 0xAA }
    iroI32TruncF64U,            { 0xAB }
    iroI64ExtendI32S,           { 0xAC }
    iroI64ExtendI32U,           { 0xAD }
    iroI64TruncF32S,            { 0xAE }
    iroI64TruncF32U,            { 0xAF }
    iroI64TruncF64S,            { 0xB0 }
    iroI64TruncF64U,            { 0xB1 }
    iroF32ConvertI32S,          { 0xB2 }
    iroF32ConvertI32U,          { 0xB3 }
    iroF32ConvertI64S,          { 0xB4 }
    iroF32ConvertI64U,          { 0xB5 }
    iroF32DemoteF64,            { 0xB6 }
    iroF64ConvertI32S,          { 0xB7 }
    iroF64ConvertI32U,          { 0xB8 }
    iroF64ConvertI64S,          { 0xB9 }
    iroF64ConvertI64U,          { 0xBA }
    iroF64PromoteF32,           { 0xBB }
    iroI32ReinterpretF32,       { 0xBC }
    iroI64ReinterpretF64,       { 0xBD }
    iroF32ReinterpretI32,       { 0xBE }
    iroF64ReinterpretI64,       { 0xBF }

    { --- numeric: sign extension (2.0) ------------------------------- }
    iroI32Extend8S,             { 0xC0 }
    iroI32Extend16S,            { 0xC1 }
    iroI64Extend8S,             { 0xC2 }
    iroI64Extend16S,            { 0xC3 }
    iroI64Extend32S,            { 0xC4 }

    { --- numeric: saturating truncation ------------------------------ }
    iroI32TruncSatF32S,         { 0xFC 0 }
    iroI32TruncSatF32U,         { 0xFC 1 }
    iroI32TruncSatF64S,         { 0xFC 2 }
    iroI32TruncSatF64U,         { 0xFC 3 }
    iroI64TruncSatF32S,         { 0xFC 4 }
    iroI64TruncSatF32U,         { 0xFC 5 }
    iroI64TruncSatF64S,         { 0xFC 6 }
    iroI64TruncSatF64U,         { 0xFC 7 }

    { --- reference --------------------------------------------------- }
    iroRefNull,                 { 0xD0 }
    iroRefIsNull,               { 0xD1 }
    iroRefFunc,                 { 0xD2 }
    iroRefEq,                   { 0xD3 }
    iroRefAsNonNull,            { 0xD4 }
    iroRefTest,                 { 0xFB 20 and 0xFB 21 }
    iroRefCast,                 { 0xFB 22 and 0xFB 23 }

    { --- struct ------------------------------------------------------ }
    iroStructNew,               { 0xFB 0  - allocation safepoint }
    iroStructNewDefault,        { 0xFB 1  - allocation safepoint }
    iroStructGet,               { 0xFB 2 }
    iroStructGetS,              { 0xFB 3 }
    iroStructGetU,              { 0xFB 4 }
    iroStructSet,               { 0xFB 5 }

    { --- array ------------------------------------------------------- }
    iroArrayNew,                { 0xFB 6  - allocation safepoint }
    iroArrayNewDefault,         { 0xFB 7  - allocation safepoint }
    iroArrayNewFixed,           { 0xFB 8  - allocation safepoint }
    iroArrayNewData,            { 0xFB 9  - allocation safepoint }
    iroArrayNewElem,            { 0xFB 10 - allocation safepoint }
    iroArrayGet,                { 0xFB 11 }
    iroArrayGetS,               { 0xFB 12 }
    iroArrayGetU,               { 0xFB 13 }
    iroArraySet,                { 0xFB 14 }
    iroArrayLen,                { 0xFB 15 }
    iroArrayFill,               { 0xFB 16 }
    iroArrayCopy,               { 0xFB 17 }
    iroArrayInitData,           { 0xFB 18 }
    iroArrayInitElem,           { 0xFB 19 }

    { --- extern conversions ------------------------------------------ }
    iroAnyConvertExtern,        { 0xFB 26 }
    iroExternConvertAny,        { 0xFB 27 }

    { --- i31 --------------------------------------------------------- }
    iroRefI31,                  { 0xFB 28 - allocation safepoint }
    iroI31GetS,                 { 0xFB 29 }
    iroI31GetU                  { 0xFB 30 }
  );
{$POP}

type
  { The fixed instruction record. 2 bytes Op + 2 padding + 3x4 + 8 = 24,
    asserted below so a new field cannot change the size unnoticed.

    Dest, A and B do NOT always name registers, and Imm does not always
    hold a value — IR_OP_INFO records what each field means per op, and
    every reader (the disassembler, the stack-map projection, any future
    renumbering pass) consults it rather than guessing. }
  TWasmIrInstr = record
    Op: TWasmIrOp;
    Dest: UInt32;
    A: UInt32;
    B: UInt32;
    Imm: Int64;
  end;

{$IF SizeOf(TWasmIrInstr) <> 24}
  {$MESSAGE ERROR 'TWasmIrInstr must stay 24 bytes; see Wasm.Ir header'}
{$IFEND}

type
  { What a field of TWasmIrInstr means for a given op. }
  TWasmIrFieldKind = (
    ifkUnused,        { field is 0 / IR_NO_REG and must be ignored }
    ifkDestReg,       { a register this op WRITES }
    ifkSrcReg,        { a register this op READS }
    ifkInstrIndex,    { an index into the function's Code array }
    ifkAuxIndex,      { an index into AuxU32 (length-prefixed block) }
    ifkRefTypeIndex,  { an index into AuxRefTypes }
    ifkTypeIndex,
    ifkFuncIndex,
    ifkTableIndex,
    ifkMemIndex,
    ifkGlobalIndex,
    ifkTagIndex,
    ifkDataIndex,
    ifkElemIndex,
    { No ifkFieldIndex: a struct field index never travels alone. Every
      struct op that names one packs it with the type index, so the field
      is reached through ifkPacked and IrPackedNames. }
    ifkFlags,         { bit field (iroJump only) }
    ifkImmValue,      { a literal value / bit pattern }
    ifkPacked         { two u32 indices packed into Imm — see IrPack }
  );

  TWasmIrOpInfo = record
    Mnemonic: string;
    DestKind: TWasmIrFieldKind;
    AKind: TWasmIrFieldKind;
    BKind: TWasmIrFieldKind;
    ImmKind: TWasmIrFieldKind;
  end;

const
  { Exhaustive over TWasmIrOp. FPC does not warn about a short initialiser
    for an enum-indexed array, so Wasm.Ir.Test asserts totality and that
    every entry has a mnemonic. }
  IR_OP_INFO: array[TWasmIrOp] of TWasmIrOpInfo = (
    { --- IR-only (no wasm opcode) ------------------------------------ }
    (Mnemonic: 'move'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'jump'; DestKind: ifkUnused; AKind: ifkInstrIndex;
      BKind: ifkUnused; ImmKind: ifkFlags),
    (Mnemonic: 'branch_if'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkInstrIndex; ImmKind: ifkUnused),
    (Mnemonic: 'branch_if_not'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkInstrIndex; ImmKind: ifkUnused),

    { --- control (binary-instr-control) ------------------------------ }
    (Mnemonic: 'unreachable'; DestKind: ifkUnused; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'throw'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkTagIndex),
    (Mnemonic: 'throw_ref'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'br_table'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkAuxIndex; ImmKind: ifkUnused),
    (Mnemonic: 'return'; DestKind: ifkUnused; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'call'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkAuxIndex; ImmKind: ifkFuncIndex),
    (Mnemonic: 'call_indirect'; DestKind: ifkSrcReg; AKind: ifkAuxIndex;
      BKind: ifkAuxIndex; ImmKind: ifkPacked),
    (Mnemonic: 'return_call'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkFuncIndex),
    (Mnemonic: 'return_call_indirect'; DestKind: ifkSrcReg; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkPacked),
    (Mnemonic: 'call_ref'; DestKind: ifkSrcReg; AKind: ifkAuxIndex;
      BKind: ifkAuxIndex; ImmKind: ifkTypeIndex),
    (Mnemonic: 'return_call_ref'; DestKind: ifkSrcReg; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkTypeIndex),
    (Mnemonic: 'br_on_null'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkInstrIndex; ImmKind: ifkUnused),
    (Mnemonic: 'br_on_non_null'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkInstrIndex; ImmKind: ifkUnused),
    (Mnemonic: 'br_on_cast'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkInstrIndex; ImmKind: ifkRefTypeIndex),
    (Mnemonic: 'br_on_cast_fail'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkInstrIndex; ImmKind: ifkRefTypeIndex),

    { --- parametric -------------------------------------------------- }
    (Mnemonic: 'select'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcReg),

    { --- variable ---------------------------------------------------- }
    (Mnemonic: 'global.get'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkGlobalIndex),
    (Mnemonic: 'global.set'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkGlobalIndex),

    { --- table ------------------------------------------------------- }
    (Mnemonic: 'table.get'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkTableIndex),
    (Mnemonic: 'table.set'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTableIndex),
    (Mnemonic: 'table.init'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),
    (Mnemonic: 'elem.drop'; DestKind: ifkUnused; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkElemIndex),
    (Mnemonic: 'table.copy'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),
    (Mnemonic: 'table.grow'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTableIndex),
    (Mnemonic: 'table.size'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkTableIndex),
    (Mnemonic: 'table.fill'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTableIndex),

    { --- memory: loads ----------------------------------------------- }
    (Mnemonic: 'i32.load'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.load'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'f32.load'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'f64.load'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i32.load8_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i32.load8_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i32.load16_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i32.load16_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.load8_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.load8_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.load16_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.load16_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.load32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.load32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),

    { --- memory: stores ---------------------------------------------- }
    (Mnemonic: 'i32.store'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.store'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'f32.store'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'f64.store'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i32.store8'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i32.store16'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.store8'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.store16'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.store32'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),

    { --- memory: management ------------------------------------------ }
    (Mnemonic: 'memory.size'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkMemIndex),
    (Mnemonic: 'memory.grow'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkMemIndex),
    (Mnemonic: 'memory.init'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),
    (Mnemonic: 'data.drop'; DestKind: ifkUnused; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkDataIndex),
    (Mnemonic: 'memory.copy'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),
    (Mnemonic: 'memory.fill'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkMemIndex),

    { --- numeric: constants ------------------------------------------ }
    (Mnemonic: 'i32.const'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i64.const'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'f32.const'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'f64.const'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkImmValue),

    { --- numeric: i32 test/compare ----------------------------------- }
    (Mnemonic: 'i32.eqz'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.lt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.lt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.gt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.gt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.le_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.le_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.ge_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.ge_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: i64 test/compare ----------------------------------- }
    (Mnemonic: 'i64.eqz'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.lt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.lt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.gt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.gt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.le_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.le_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.ge_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.ge_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: f32 compare ---------------------------------------- }
    (Mnemonic: 'f32.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.lt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.gt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.le'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.ge'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: f64 compare ---------------------------------------- }
    (Mnemonic: 'f64.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.lt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.gt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.le'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.ge'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: i32 unary/binary ----------------------------------- }
    (Mnemonic: 'i32.clz'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.ctz'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.popcnt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.div_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.div_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.rem_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.rem_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.and'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.or'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.xor'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.shl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.shr_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.shr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.rotl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32.rotr'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: i64 unary/binary ----------------------------------- }
    (Mnemonic: 'i64.clz'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.ctz'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.popcnt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.div_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.div_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.rem_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.rem_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.and'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.or'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.xor'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.shl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.shr_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.shr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.rotl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64.rotr'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: f32 unary/binary ----------------------------------- }
    (Mnemonic: 'f32.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.ceil'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.floor'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.trunc'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.nearest'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.sqrt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.div'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.min'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.max'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32.copysign'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: f64 unary/binary ----------------------------------- }
    (Mnemonic: 'f64.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.ceil'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.floor'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.trunc'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.nearest'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.sqrt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.div'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.min'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.max'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64.copysign'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- numeric: conversions ---------------------------------------- }
    (Mnemonic: 'i32.wrap_i64'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.trunc_f32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.trunc_f32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.trunc_f64_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.trunc_f64_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.extend_i32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.extend_i32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_f32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_f32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_f64_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_f64_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.convert_i32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.convert_i32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.convert_i64_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.convert_i64_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.demote_f64'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.convert_i32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.convert_i32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.convert_i64_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.convert_i64_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.promote_f32'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.reinterpret_f32'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.reinterpret_f64'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32.reinterpret_i32'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64.reinterpret_i64'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),

    { --- numeric: sign extension (2.0) ------------------------------- }
    (Mnemonic: 'i32.extend8_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.extend16_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.extend8_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.extend16_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.extend32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),

    { --- numeric: saturating truncation ------------------------------ }
    (Mnemonic: 'i32.trunc_sat_f32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.trunc_sat_f32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.trunc_sat_f64_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32.trunc_sat_f64_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_sat_f32_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_sat_f32_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_sat_f64_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64.trunc_sat_f64_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),

    { --- reference --------------------------------------------------- }
    (Mnemonic: 'ref.null'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'ref.is_null'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'ref.func'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkFuncIndex),
    (Mnemonic: 'ref.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'ref.as_non_null'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'ref.test'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkRefTypeIndex),
    (Mnemonic: 'ref.cast'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkRefTypeIndex),

    { --- struct ------------------------------------------------------ }
    (Mnemonic: 'struct.new'; DestKind: ifkDestReg; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkTypeIndex),
    (Mnemonic: 'struct.new_default'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkTypeIndex),
    (Mnemonic: 'struct.get'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkPacked),
    (Mnemonic: 'struct.get_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkPacked),
    (Mnemonic: 'struct.get_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkPacked),
    (Mnemonic: 'struct.set'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),

    { --- array ------------------------------------------------------- }
    (Mnemonic: 'array.new'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.new_default'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.new_fixed'; DestKind: ifkDestReg; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.new_data'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),
    (Mnemonic: 'array.new_elem'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),
    (Mnemonic: 'array.get'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.get_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.get_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.set'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.len'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'array.fill'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.copy'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkPacked),
    (Mnemonic: 'array.init_data'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkPacked),
    (Mnemonic: 'array.init_elem'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkPacked),

    { --- extern conversions ------------------------------------------ }
    (Mnemonic: 'any.convert_extern'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'extern.convert_any'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),

    { --- i31 --------------------------------------------------------- }
    (Mnemonic: 'ref.i31'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i31.get_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i31.get_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused)
  );

type
  { --- variable-length parts ---------------------------------------------

    Named types, not inline `array of X`, because the records below are
    passed by var and open arrays of an anonymous type are not assignable.
    Dynamic arrays throughout: no TList, no generics, no interfaces —
    ADR-0009 forbids managed state on frames a trap unwind can skip, and
    the IR is read from exactly those frames. }

  TWasmIrCode = array of TWasmIrInstr;
  TWasmIrRegTypes = array of TWasmValueType;
  TWasmIrRefTypes = array of TWasmRefType;

  { Length-prefixed blocks, one rule with no exceptions: a block at index
    k is AuxU32[k] = the count N, followed by N entries at k+1 .. k+N. A
    reader never needs a count from anywhere else. Blocks are never shared
    or deduplicated — deterministic emission is what makes the
    Describe-based validator tests stable. }
  TWasmIrAuxU32 = array of UInt32;

  { Bitset over register numbers, 32 registers per word. }
  TWasmIrBitset = array of UInt32;

  { --- exception handling (populated from day one, consumed by Track H) - }

  { DECLARATION ORDER IS COUPLED to `binary-instr-control`'s catch byte
    assignment: CATCH = 0x00, CATCH_REF = 0x01, CATCH_ALL = 0x02,
    CATCH_ALL_REF = 0x03, and the decoder converts the byte to a member by
    ordinal. Reordering or inserting a member silently remaps every
    handler clause — add at the END and bump IR_FORMAT_VERSION. }
  TWasmIrCatchKind = (wickCatch, wickCatchRef, wickCatchAll,
    wickCatchAllRef);

  TWasmIrCatchClause = record
    Kind: TWasmIrCatchKind;
    TagIndex: UInt32;      { wickCatch / wickCatchRef only }
    TargetInstr: UInt32;   { resolved label target }
    { AuxU32 block holding the target label's merge registers, in order.
      The unwinder writes the payload there and resumes at TargetInstr;
      no stub and no moves are needed. }
    PayloadAux: UInt32;
  end;

  TWasmIrCatchClauses = array of TWasmIrCatchClause;

  TWasmIrHandler = record
    StartInstr: UInt32;    { inclusive }
    EndInstr: UInt32;      { exclusive }
    ClauseStart: UInt32;   { index into TWasmIrFunction.HandlerClauses }
    ClauseCount: UInt32;
  end;

  { Appended at each try_table's `end`, so an inner handler is appended
    before its enclosing one. A linear scan from 0 for the first entry
    covering the faulting instruction therefore finds the INNERMOST
    handler. Do not sort this table.

    EPOCH OBLIGATION (design doc §4.12, ADR-0006). Resuming at a clause's
    TargetInstr is a control transfer that did NOT go through the
    safepoint-flagged iroJump: when the target is a LOOP HEADER, the
    back-edge check that every other path to it runs is bypassed, so a
    loop whose only back edge is a throw would never observe an epoch
    change and could not be interrupted. The unwinder must therefore run
    the epoch check itself before resuming at TargetInstr. This is a
    property of the unwinder in every tier, not of the emitted code, and
    it is recorded here because this table is where a tier author looks. }
  TWasmIrHandlers = array of TWasmIrHandler;

  { --- borrowed buffer ranges --------------------------------------------

    Deliberately NOT Wasm.Module's TWasmSpan: this unit depends on
    Wasm.Core alone. The layout is identical so a caller converts field by
    field. }
  TWasmIrSpan = record
    Offset: NativeUInt;
    Size: NativeUInt;
  end;

  { Mirrors of Wasm.Module's segment modes, for the same reason. }
  TWasmIrElemMode = (iremActive, iremPassive, iremDeclarative);
  TWasmIrDataMode = (irdmActive, irdmPassive);

  { --- code --------------------------------------------------------------

    An init expression is NOT a function: it has no return register block,
    no trailing iroReturn, and no handlers. Run Code[0..High] and read
    ResultReg.

    THE ABSENT-INITIALISER SENTINEL. Some init-expression arrays are
    positional and have a hole: TWasmIrModule.TableInits carries one entry
    per table, and a table without an initialiser still occupies its slot.
    Such an entry is spelled EMPTY: Length(Code) = 0 and ResultReg =
    IR_NO_REG. `Length(Code) = 0` is the discriminator a consumer tests —
    it is the one field that cannot be confused with a legitimate value,
    because a present initialiser always emits at least one instruction.
    ResultReg is set to IR_NO_REG on the same entries so that a consumer
    that reaches for it anyway reads the sentinel rather than register 0. }
  TWasmIrInitExpr = record
    Code: TWasmIrCode;
    RegTypes: TWasmIrRegTypes;
    RegisterCount: UInt32;
    ResultReg: UInt32;
    AuxU32: TWasmIrAuxU32;
    AuxRefTypes: TWasmIrRefTypes;
  end;

  TWasmIrInitExprs = array of TWasmIrInitExpr;

  { Register numbering, per function, in this order:

      [0 .. P-1]                 parameters, in declaration order
      [P .. P+L-1]               declared locals, run-length expanded
      [P+L .. P+L+R-1]           the return register block
      [P+L+R .. RegisterCount-1] merge registers and temporaries

    ReturnRegBase = P + L, so a caller reads a callee's results from a
    constant offset without consulting the type. Temporaries are allocated
    monotonically and never reused, which is what lets RegTypes be a plain
    array — every register has exactly one type for the whole function, so
    ADR-0011's stack map is a projection of it rather than a second
    analysis. RegisterCount is the interpreter frame size; there is no
    separate operand-stack depth. }
  TWasmIrFunction = record
    TypeIndex: UInt32;         { module type space }
    CanonTypeId: UInt32;       { canonical type id, module-local }
    ParamCount: UInt32;
    LocalCount: UInt32;        { declared locals, excluding params }
    ResultCount: UInt32;
    ReturnRegBase: UInt32;     { = ParamCount + LocalCount }
    RegisterCount: UInt32;
    SourceOffset: NativeUInt;  { absolute, for diagnostics }
    Code: TWasmIrCode;
    RegTypes: TWasmIrRegTypes;
    { Bit i set iff RegTypes[i].Kind = wvkRef. Computed once, at the end
      of the function walk, by IrComputeRefRegBits. }
    RefRegBits: TWasmIrBitset;
    AuxU32: TWasmIrAuxU32;
    AuxRefTypes: TWasmIrRefTypes;
    Handlers: TWasmIrHandlers;
    HandlerClauses: TWasmIrCatchClauses;
  end;

  TWasmIrFunctions = array of TWasmIrFunction;

  { --- module-level snapshots --------------------------------------------

    Canonical type ids are MODULE-LOCAL. Cross-module equality (linking,
    call_indirect's runtime check) needs an engine-wide table, which is
    why each rec group's serialised key travels with the module: a later
    layer re-interns the keys and remaps. Never assume the ids are
    portable.

    NAMED TWasmIrCanonType, not TWasmCanonType: Wasm.Validator.Types
    declares its own canonical-type record under the latter name with a
    DIFFERENT shape (it carries HasSuper/SuperId and no precomputed
    Depth). The two used to collide, and a unit seeing both resolved the
    bare name by uses-order rather than by intent. }
  TWasmIrCanonType = record
    Comp: TWasmCompType;
    IsFinal: Boolean;
    { Supertype display, root first, last entry being this type itself, so
      A <= B iff Depth(B) <= Depth(A) and Display(A)[Depth(B)] = B. }
    Display: TWasmIrAuxU32;
    Depth: UInt32;
  end;

  TWasmIrCanonTypes = array of TWasmIrCanonType;

  TWasmIrExport = record
    Name: string;
    Kind: TWasmExternKind;
    { Index into the Kind's index space, imports first. }
    Index: UInt32;
  end;

  TWasmIrExports = array of TWasmIrExport;

  { Element items are normalised to init expressions — the funcidx vector
    form lowers to a one-instruction iroRefFunc expression — so
    instantiation has exactly one code path. }
  TWasmIrElemSegment = record
    Mode: TWasmIrElemMode;
    TableIndex: UInt32;
    RefType: TWasmRefType;
    Offset: TWasmIrInitExpr;   { active only }
    Items: TWasmIrInitExprs;
  end;

  TWasmIrElemSegments = array of TWasmIrElemSegment;

  TWasmIrDataSegment = record
    Mode: TWasmIrDataMode;
    MemIndex: UInt32;
    Offset: TWasmIrInitExpr;   { active only }
    Bytes: TWasmIrSpan;        { BORROWED — see the unit header }
  end;

  TWasmIrDataSegments = array of TWasmIrDataSegment;

  TWasmIrTableTypes = array of TWasmTableType;
  TWasmIrMemTypes = array of TWasmMemType;
  TWasmIrGlobalTypes = array of TWasmGlobalType;
  TWasmIrFlags = array of Boolean;
  TWasmIrGroupKeys = array of TWasmBytes;

  { The validated module: per-function IR plus the index-space snapshots
    the tiers and the store builder need. Nothing here points back at the
    decoded model. }
  TWasmIrModule = class
  public
    { Stamped at construction; an artifact recording a different value is
      rejected rather than read (ADR-0007). }
    FormatVersion: UInt32;

    { types }
    CanonTypes: TWasmIrCanonTypes;
    TypeIndexToCanon: TWasmIrAuxU32;
    GroupKeys: TWasmIrGroupKeys;

    { index spaces — imports occupy the low indices of each }
    FuncCanonTypes: TWasmIrAuxU32;
    FuncIsImported: TWasmIrFlags;
    Tables: TWasmIrTableTypes;
    Memories: TWasmIrMemTypes;
    Globals: TWasmIrGlobalTypes;
    Tags: TWasmIrAuxU32;            { canonical type ids }

    FuncImportCount: UInt32;
    TableImportCount: UInt32;
    MemoryImportCount: UInt32;
    GlobalImportCount: UInt32;
    TagImportCount: UInt32;

    ExportList: TWasmIrExports;

    { definitions }
    Functions: TWasmIrFunctions;    { defined functions, code order }
    GlobalInits: TWasmIrInitExprs;
    TableInits: TWasmIrInitExprs;   { empty entry when the table has none }
    Elems: TWasmIrElemSegments;
    Datas: TWasmIrDataSegments;
    HasStart: Boolean;
    StartFuncIndex: UInt32;
    { C.REFS: functions reachable by ref.func outside a function body. }
    DeclaredFuncRefs: TWasmIrFlags;

    constructor Create;
  end;

{ --- construction and field packing -------------------------------------- }

function MakeIrInstr(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32;
  const AImm: Int64): TWasmIrInstr;

function MakeIrSpan(const AOffset, ASize: NativeUInt): TWasmIrSpan;

{ Two u32 index immediates in one Imm. Which index is low and which is
  high is fixed per op by IR_OP_INFO's documented meaning and must never be
  inferred from the order the binary format encodes them in. }
function IrPack(const ALow, AHigh: UInt32): Int64;
procedure IrUnpack(const AImm: Int64; out ALow, AHigh: UInt32);

{ Float immediates are stored as BIT PATTERNS, never as Single/Double: NaN
  payloads are observable and a round-trip through an FPC float type is not
  required to preserve them. These convert through a variant record, never
  by assignment between a float and an integer. }
function IrF32Bits(const AValue: Single): Int64;
function IrF64Bits(const AValue: Double): Int64;
function IrBitsAsF32(const ABits: Int64): Single;
function IrBitsAsF64(const ABits: Int64): Double;

{ --- building: the amortised append primitives ---------------------------

  Every producer of IR — the fused body walk and the constant-expression
  checker today, a text-format front end later — appends to the same three
  arrays, and they all want the same thing: geometric growth while
  building, an exact trim at the end. The primitives live HERE rather than
  in a producer so there is one growth policy and one aliasing rule
  instead of one per caller.

  The convention is an (ARRAY, LIVE-COUNT) pair: Length(array) is the
  CAPACITY and is meaningless to a reader, ACount is the number of live
  elements. Nothing may read the array by Length until it has been
  trimmed, which is what the IrTrim* procedures are for. Calling one twice
  is harmless; forgetting it leaves garbage entries visible to every
  consumer, so trim in the same procedure that finished building.

  ALIASING. Each of these can REALLOCATE the array it appends to, and a
  `const` record parameter larger than a machine word is passed by
  reference on the ABIs this project targets. A caller writing
  `IrEmitInstr(Code, Count, Code[K])` would therefore hand over a pointer
  into the very buffer about to move. Each primitive copies its payload to
  a local before it can grow, so that call is safe rather than a
  use-after-free that reproduces only once the capacity runs out. }

function IrEmitInstr(var ACode: TWasmIrCode; var ACodeCount: Integer;
  const AInstr: TWasmIrInstr): UInt32;

function IrAllocReg(var ARegTypes: TWasmIrRegTypes;
  var ARegCount: Integer; const AType: TWasmValueType): UInt32;

procedure IrTrimCode(var ACode: TWasmIrCode; const ACodeCount: Integer);
procedure IrTrimRegTypes(var ARegTypes: TWasmIrRegTypes;
  const ARegCount: Integer);
procedure IrTrimAux(var AAux: TWasmIrAuxU32; const AAuxCount: Integer);

{ --- aux blocks ---------------------------------------------------------- }

{ Appends [N, items...] and returns the block's index (the index of N).
  Grows EXACTLY, so it is O(total) per call: correct for the handful of
  blocks a caller appends outside a walk, wrong inside one. Use
  IrAppendAuxBlockGrowing there. }
function IrAppendAuxBlock(var AAux: TWasmIrAuxU32;
  const AItems: array of UInt32): UInt32;

{ The amortised form, over an (array, live-count) pair — see the building
  section above. AAuxCount is the live length and is advanced past the
  appended block; trim with IrTrimAux. }
function IrAppendAuxBlockGrowing(var AAux: TWasmIrAuxU32;
  var AAuxCount: Integer; const AItems: array of UInt32): UInt32;

{ 0 for IR_NO_AUX or an index past the end — a missing block reads as
  empty rather than raising, because the disassembler runs on
  half-constructed IR in tests and in diagnostics. }
function IrAuxBlockCount(const AAux: TWasmIrAuxU32;
  const AIndex: UInt32): UInt32;

{ IR_NO_REG when AItem is outside the block. }
function IrAuxBlockItem(const AAux: TWasmIrAuxU32;
  const AIndex, AItem: UInt32): UInt32;

{ --- safepoints and the reference-register projection -------------------- }

{ True for the ops that are safepoints by KIND: calls, tail calls, and the
  allocating GC ops. iroJump is a safepoint only when its flag is set, and
  the flag lives on the instruction, so ask IrInstrIsSafepoint when you
  have one. Function entry (instruction index 0) is an implicit safepoint
  and is not represented by any op. }
function IrOpIsSafepoint(const AOp: TWasmIrOp): Boolean;
function IrInstrIsSafepoint(const AInstr: TWasmIrInstr): Boolean;

function IrOpMnemonic(const AOp: TWasmIrOp): string;

procedure IrComputeRefRegBits(var AFn: TWasmIrFunction);
function IrRegIsRef(const AFn: TWasmIrFunction;
  const AReg: UInt32): Boolean;

{ --- disassembler --------------------------------------------------------

  This format is a TEST SURFACE: the validator suites assert IR emission as
  disassembled text rather than record internals, so that they survive an
  encoding tweak. Line format is
  Format('%.4d  %-22s %s', [Index, Mnemonic, Operands]), right-trimmed.
  Registers render r<N>, IR_NO_REG renders `-`, instruction indices render
  @<4 digits>, aux register lists render parenthesised, index immediates
  render g<n>/t<n>/f<n> for the compact spaces and <name>=<n> otherwise. }
function DescribeIrInstr(const AFn: TWasmIrFunction;
  const AIndex: UInt32): string;
function DescribeIrFunction(const AFn: TWasmIrFunction): string;
function DescribeIrInitExprInstr(const AExpr: TWasmIrInitExpr;
  const AIndex: UInt32): string;
function DescribeIrInitExpr(const AExpr: TWasmIrInitExpr): string;

implementation

constructor TWasmIrModule.Create;
begin
  inherited Create;
  FormatVersion := IR_FORMAT_VERSION;
end;

function MakeIrInstr(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32;
  const AImm: Int64): TWasmIrInstr;
begin
  Result.Op := AOp;
  Result.Dest := ADest;
  Result.A := AA;
  Result.B := AB;
  Result.Imm := AImm;
end;

function MakeIrSpan(const AOffset, ASize: NativeUInt): TWasmIrSpan;
begin
  Result.Offset := AOffset;
  Result.Size := ASize;
end;

function IrPack(const ALow, AHigh: UInt32): Int64;
begin
  Result := Int64(ALow) or (Int64(AHigh) shl 32);
end;

procedure IrUnpack(const AImm: Int64; out ALow, AHigh: UInt32);
begin
  ALow := UInt32(UInt64(AImm) and $FFFFFFFF);
  AHigh := UInt32((UInt64(AImm) shr 32) and $FFFFFFFF);
end;

type
  { Reinterpretation without an arithmetic conversion. An assignment
    between a float and an integer would convert the VALUE; a NaN payload
    does not survive that. }
  TF32Bits = record
    case Boolean of
      False: (F: Single);
      True: (U: UInt32);
  end;

  TF64Bits = record
    case Boolean of
      False: (F: Double);
      True: (U: UInt64);
  end;

function IrF32Bits(const AValue: Single): Int64;
var
  Conv: TF32Bits;
begin
  Conv.F := AValue;
  { Zero-extended: an f32 pattern occupies the low 32 bits and the high
    half stays clear, so two identical patterns compare equal as Imm. }
  Result := Int64(Conv.U);
end;

function IrF64Bits(const AValue: Double): Int64;
var
  Conv: TF64Bits;
begin
  Conv.F := AValue;
  Result := Int64(Conv.U);
end;

function IrBitsAsF32(const ABits: Int64): Single;
var
  Conv: TF32Bits;
begin
  Conv.U := UInt32(UInt64(ABits) and $FFFFFFFF);
  Result := Conv.F;
end;

function IrBitsAsF64(const ABits: Int64): Double;
var
  Conv: TF64Bits;
begin
  Conv.U := UInt64(ABits);
  Result := Conv.F;
end;

{ --- building: the amortised append primitives ---------------------------- }

function IrEmitInstr(var ACode: TWasmIrCode; var ACodeCount: Integer;
  const AInstr: TWasmIrInstr): UInt32;
var
  { COPIED BEFORE THE GROWTH, deliberately: AInstr is 24 bytes and a
    `const` record that size is passed by reference, so a caller passing
    ACode[K] would be pointing into the buffer SetLength is about to
    move. See the interface's aliasing note. }
  Instr: TWasmIrInstr;
begin
  Instr := AInstr;
  if ACodeCount >= Length(ACode) then
    SetLength(ACode, (ACodeCount * 2) + 16);
  ACode[ACodeCount] := Instr;
  Result := UInt32(ACodeCount);
  Inc(ACodeCount);
end;

function IrAllocReg(var ARegTypes: TWasmIrRegTypes;
  var ARegCount: Integer; const AType: TWasmValueType): UInt32;
var
  { Same hazard, same fix: `IrAllocReg(RegTypes, N, RegTypes[K])` is the
    natural way to allocate a register of an existing register's type. }
  Ty: TWasmValueType;
begin
  Ty := AType;
  if ARegCount >= Length(ARegTypes) then
    SetLength(ARegTypes, (ARegCount * 2) + 16);
  ARegTypes[ARegCount] := Ty;
  Result := UInt32(ARegCount);
  Inc(ARegCount);
end;

procedure IrTrimCode(var ACode: TWasmIrCode; const ACodeCount: Integer);
begin
  SetLength(ACode, ACodeCount);
end;

procedure IrTrimRegTypes(var ARegTypes: TWasmIrRegTypes;
  const ARegCount: Integer);
begin
  SetLength(ARegTypes, ARegCount);
end;

procedure IrTrimAux(var AAux: TWasmIrAuxU32; const AAuxCount: Integer);
begin
  SetLength(AAux, AAuxCount);
end;

function IrAppendAuxBlock(var AAux: TWasmIrAuxU32;
  const AItems: array of UInt32): UInt32;
var
  Base: Integer;
  I: Integer;
begin
  Base := Length(AAux);
  SetLength(AAux, Base + 1 + Length(AItems));
  AAux[Base] := UInt32(Length(AItems));
  for I := 0 to High(AItems) do
    AAux[Base + 1 + I] := AItems[I];
  Result := UInt32(Base);
end;

function IrAppendAuxBlockGrowing(var AAux: TWasmIrAuxU32;
  var AAuxCount: Integer; const AItems: array of UInt32): UInt32;
var
  Base, Need, I: Integer;
  Saved: TWasmIrAuxU32;
begin
  Base := AAuxCount;
  Need := Base + 1 + Length(AItems);

  if Need > Length(AAux) then
  begin
    { An open-array parameter is a pointer, so AItems may be a slice of
      AAux itself — `IrAppendAuxBlockGrowing(Aux, N, MergeRegsReadFromAux)`
      is exactly the shape a merge-register append takes. Copy the items
      out BEFORE the reallocation, and only on the growth path, so the
      common case still costs nothing. }
    SetLength(Saved, Length(AItems));
    for I := 0 to High(AItems) do
      Saved[I] := AItems[I];

    SetLength(AAux, (Need * 2) + 16);

    AAux[Base] := UInt32(Length(Saved));
    for I := 0 to High(Saved) do
      AAux[Base + 1 + I] := Saved[I];
  end
  else
  begin
    AAux[Base] := UInt32(Length(AItems));
    for I := 0 to High(AItems) do
      AAux[Base + 1 + I] := AItems[I];
  end;

  AAuxCount := Need;
  Result := UInt32(Base);
end;

function IrAuxBlockCount(const AAux: TWasmIrAuxU32;
  const AIndex: UInt32): UInt32;
begin
  if (AIndex = IR_NO_AUX) or (AIndex >= UInt32(Length(AAux))) then
    Exit(0);
  Result := AAux[AIndex];
end;

function IrAuxBlockItem(const AAux: TWasmIrAuxU32;
  const AIndex, AItem: UInt32): UInt32;
begin
  if AItem >= IrAuxBlockCount(AAux, AIndex) then
    Exit(IR_NO_REG);
  Result := AAux[AIndex + 1 + AItem];
end;

function IrOpIsSafepoint(const AOp: TWasmIrOp): Boolean;
begin
  case AOp of
    iroCall, iroCallIndirect, iroCallRef,
    iroReturnCall, iroReturnCallIndirect, iroReturnCallRef,
    iroStructNew, iroStructNewDefault,
    iroArrayNew, iroArrayNewDefault, iroArrayNewFixed,
    iroArrayNewData, iroArrayNewElem,
    iroRefI31:
      Result := True;
  else
    Result := False;
  end;
end;

function IrInstrIsSafepoint(const AInstr: TWasmIrInstr): Boolean;
begin
  if AInstr.Op = iroJump then
    Result := (AInstr.Imm and IR_JUMP_SAFEPOINT) <> 0
  else
    Result := IrOpIsSafepoint(AInstr.Op);
end;

function IrOpMnemonic(const AOp: TWasmIrOp): string;
begin
  Result := IR_OP_INFO[AOp].Mnemonic;
end;

procedure IrComputeRefRegBits(var AFn: TWasmIrFunction);
var
  I: Integer;
  Words: Integer;
begin
  Words := (Length(AFn.RegTypes) + 31) div 32;
  SetLength(AFn.RefRegBits, Words);
  for I := 0 to Words - 1 do
    AFn.RefRegBits[I] := 0;
  for I := 0 to High(AFn.RegTypes) do
    if AFn.RegTypes[I].Kind = wvkRef then
      AFn.RefRegBits[I div 32] := AFn.RefRegBits[I div 32]
        or (UInt32(1) shl (I mod 32));
end;

function IrRegIsRef(const AFn: TWasmIrFunction;
  const AReg: UInt32): Boolean;
begin
  if (AReg = IR_NO_REG) or (AReg div 32 >= UInt32(Length(AFn.RefRegBits)))
  then
    Exit(False);
  Result := (AFn.RefRegBits[AReg div 32]
    and (UInt32(1) shl (AReg mod 32))) <> 0;
end;

{ --- disassembler -------------------------------------------------------- }

function IrRegName(const AReg: UInt32): string;
begin
  if AReg = IR_NO_REG then
    Result := '-'
  else
    Result := 'r' + IntToStr(AReg);
end;

function IrInstrRef(const AIndex: UInt32): string;
begin
  Result := '@' + Format('%.4d', [Integer(AIndex)]);
end;

function IrAuxRegList(const AAux: TWasmIrAuxU32;
  const AIndex: UInt32): string;
var
  I, Count: UInt32;
begin
  Count := IrAuxBlockCount(AAux, AIndex);
  { The empty block is COMMON, not exotic: a call to a no-argument
    function, a call with no results, a struct.new of a zero-field struct,
    and every IR_NO_AUX field all land here. It also has to be an early
    return rather than a `to Count - 1` loop, because I and Count are
    UInt32: `0 to 0 - 1` is `0 to $FFFFFFFF`, which either hangs or trips
    range checking depending on the build. }
  if Count = 0 then
    Exit('()');

  Result := '(';
  for I := 0 to Count - 1 do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + IrRegName(IrAuxBlockItem(AAux, AIndex, I));
  end;
  Result := Result + ')';
end;

function IrAuxTargetList(const AAux: TWasmIrAuxU32;
  const AIndex: UInt32): string;
var
  I, Count: UInt32;
begin
  { Same UInt32 underflow as IrAuxRegList — see the note there. A br_table
    always has at least the default target, so this one is reachable only
    through IR_NO_AUX or half-constructed IR, which is exactly what the
    disassembler promises to survive. }
  Count := IrAuxBlockCount(AAux, AIndex);
  if Count = 0 then
    Exit('[]');

  Result := '[';
  for I := 0 to Count - 1 do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + IrInstrRef(IrAuxBlockItem(AAux, AIndex, I));
  end;
  Result := Result + ']';
end;

function IrRegTypeName(const ARegTypes: TWasmIrRegTypes;
  const AReg: UInt32): string;
begin
  if (AReg = IR_NO_REG) or (AReg >= UInt32(Length(ARegTypes))) then
    Result := '?'
  else
    Result := ARegTypes[AReg].Describe;
end;

function IrRefTypeName(const ARefTypes: TWasmIrRefTypes;
  const AIndex: Int64): string;
begin
  if (AIndex < 0) or (AIndex >= Length(ARefTypes)) then
    Result := '?'
  else
    Result := ARefTypes[AIndex].Describe;
end;

{ The two halves of a packed Imm, named per op. Rendering both as `type=`
  or both as `table=` would be ambiguous exactly where it matters
  (table.copy, array.copy, memory.copy), so each op names its own. }
procedure IrPackedNames(const AOp: TWasmIrOp; out ALow, AHigh: string);
begin
  case AOp of
    iroCallIndirect, iroReturnCallIndirect:
      begin
        ALow := 'type';
        AHigh := 'table';
      end;
    iroTableCopy:
      begin
        ALow := 'dst_table';
        AHigh := 'src_table';
      end;
    iroTableInit:
      begin
        ALow := 'table';
        AHigh := 'elem';
      end;
    iroMemoryCopy:
      begin
        ALow := 'dst_mem';
        AHigh := 'src_mem';
      end;
    iroMemoryInit:
      begin
        ALow := 'mem';
        AHigh := 'data';
      end;
    iroStructGet, iroStructGetS, iroStructGetU, iroStructSet:
      begin
        ALow := 'type';
        AHigh := 'field';
      end;
    iroArrayNewData, iroArrayInitData:
      begin
        ALow := 'type';
        AHigh := 'data';
      end;
    iroArrayNewElem, iroArrayInitElem:
      begin
        ALow := 'type';
        AHigh := 'elem';
      end;
    iroArrayCopy:
      begin
        ALow := 'dst_type';
        AHigh := 'src_type';
      end;
  else
    ALow := 'a';
    AHigh := 'b';
  end;
end;

{ The immediate, for the ops the generic renderer handles. The compact
  spaces get a one-letter prefix; everything else is spelled <name>=<n>. }
function IrImmText(const AOp: TWasmIrOp; const AKind: TWasmIrFieldKind;
  const AImm: Int64): string;
var
  LowIdx, HighIdx: UInt32;
  LowName, HighName: string;
begin
  case AKind of
    ifkGlobalIndex: Result := 'g' + IntToStr(AImm);
    ifkTableIndex: Result := 't' + IntToStr(AImm);
    ifkFuncIndex: Result := 'f' + IntToStr(AImm);
    ifkTypeIndex: Result := 'type=' + IntToStr(AImm);
    ifkMemIndex: Result := 'mem=' + IntToStr(AImm);
    ifkTagIndex: Result := 'tag=' + IntToStr(AImm);
    ifkDataIndex: Result := 'data=' + IntToStr(AImm);
    ifkElemIndex: Result := 'elem=' + IntToStr(AImm);
    ifkImmValue: Result := IntToStr(AImm);
    ifkPacked:
      begin
        IrUnpack(AImm, LowIdx, HighIdx);
        IrPackedNames(AOp, LowName, HighName);
        Result := LowName + '=' + IntToStr(LowIdx) + ' '
          + HighName + '=' + IntToStr(HighIdx);
      end;
  else
    Result := '';
  end;
end;

function IrJoin(const ALeft, ARight: string): string;
begin
  if ALeft = '' then
    Result := ARight
  else if ARight = '' then
    Result := ALeft
  else
    Result := ALeft + ' ' + ARight;
end;

{ Everything the special forms below do not claim. Shape:
  `<dest> <- ` then the immediate then the operands, where operands are
  either an aux register list or the comma-separated source registers in
  field order. }
function IrGenericOperands(const AInstr: TWasmIrInstr;
  const AAux: TWasmIrAuxU32): string;
var
  Info: TWasmIrOpInfo;
  Ops: string;

  procedure AddSrc(const AKind: TWasmIrFieldKind; const AReg: UInt32);
  begin
    if AKind <> ifkSrcReg then
      Exit;
    if Ops <> '' then
      Ops := Ops + ', ';
    Ops := Ops + IrRegName(AReg);
  end;

begin
  Info := IR_OP_INFO[AInstr.Op];
  Ops := '';
  if Info.AKind = ifkAuxIndex then
    Ops := IrAuxRegList(AAux, AInstr.A)
  else
  begin
    AddSrc(Info.DestKind, AInstr.Dest);
    AddSrc(Info.AKind, AInstr.A);
    AddSrc(Info.BKind, AInstr.B);
  end;

  Result := IrJoin(IrImmText(AInstr.Op, Info.ImmKind, AInstr.Imm), Ops);
  if Info.DestKind = ifkDestReg then
    Result := IrRegName(AInstr.Dest) + ' <- ' + Result;
end;

function IrOperands(const ACode: TWasmIrCode;
  const ARegTypes: TWasmIrRegTypes; const AAux: TWasmIrAuxU32;
  const ARefTypes: TWasmIrRefTypes; const AIndex: UInt32): string;
var
  Ins: TWasmIrInstr;
  LowIdx, HighIdx: UInt32;
begin
  Ins := ACode[AIndex];
  case Ins.Op of
    iroUnreachable, iroReturn:
      Result := '';

    iroMove:
      Result := IrRegName(Ins.Dest) + ' <- ' + IrRegName(Ins.A);

    iroJump:
      begin
        Result := IrInstrRef(Ins.A);
        if (Ins.Imm and IR_JUMP_SAFEPOINT) <> 0 then
          Result := Result + ' safepoint';
      end;

    iroBranchIf, iroBranchIfNot, iroBrOnNonNull:
      Result := IrRegName(Ins.A) + ' -> ' + IrInstrRef(Ins.B);

    { The branch is the taken edge; Dest is the refinement written on the
      FALL-THROUGH, which is why it renders after `else`. }
    iroBrOnNull, iroBrOnCast, iroBrOnCastFail:
      begin
        Result := IrRegName(Ins.A) + ' -> ' + IrInstrRef(Ins.B);
        if Ins.Dest <> IR_NO_REG then
          Result := Result + ' else ' + IrRegName(Ins.Dest) + ' <- '
            + IrRegTypeName(ARegTypes, Ins.Dest);
      end;

    iroBrTable:
      Result := IrRegName(Ins.A) + ' -> '
        + IrAuxTargetList(AAux, Ins.B);

    { Calls always use the aux result list, even for one result, so a
      consumer writes one result-copy loop instead of two. }
    iroCall:
      Result := 'f' + IntToStr(Ins.Imm) + ' ' + IrAuxRegList(AAux, Ins.A)
        + ' -> ' + IrAuxRegList(AAux, Ins.B);

    iroReturnCall:
      Result := 'f' + IntToStr(Ins.Imm) + ' ' + IrAuxRegList(AAux, Ins.A);

    iroCallIndirect, iroReturnCallIndirect:
      begin
        IrUnpack(Ins.Imm, LowIdx, HighIdx);
        Result := 'type=' + IntToStr(LowIdx) + ' table='
          + IntToStr(HighIdx)
          + ' [' + IrRegName(Ins.Dest) + '] '
          + IrAuxRegList(AAux, Ins.A);
        if Ins.Op = iroCallIndirect then
          Result := Result + ' -> ' + IrAuxRegList(AAux, Ins.B);
      end;

    iroCallRef, iroReturnCallRef:
      begin
        Result := 'type=' + IntToStr(Ins.Imm)
          + ' [' + IrRegName(Ins.Dest) + '] '
          + IrAuxRegList(AAux, Ins.A);
        if Ins.Op = iroCallRef then
          Result := Result + ' -> ' + IrAuxRegList(AAux, Ins.B);
      end;

    iroThrow:
      Result := 'tag=' + IntToStr(Ins.Imm) + ' '
        + IrAuxRegList(AAux, Ins.A);

    iroThrowRef:
      Result := IrRegName(Ins.A);

    { The one op where a register rides in Imm — the condition. }
    iroSelect:
      Result := IrRegName(Ins.Dest) + ' <- ' + IrRegName(Ins.A) + ', '
        + IrRegName(Ins.B) + ' ? ' + IrRegName(UInt32(Ins.Imm));

    iroGlobalGet:
      Result := IrRegName(Ins.Dest) + ' <- g' + IntToStr(Ins.Imm);
    iroGlobalSet:
      Result := 'g' + IntToStr(Ins.Imm) + ' <- ' + IrRegName(Ins.A);

    iroTableGet:
      Result := IrRegName(Ins.Dest) + ' <- t' + IntToStr(Ins.Imm)
        + '[' + IrRegName(Ins.A) + ']';
    iroTableSet:
      Result := 't' + IntToStr(Ins.Imm) + '[' + IrRegName(Ins.A)
        + '] <- ' + IrRegName(Ins.B);

    iroI32Load .. iroI64Load32U:
      Result := IrRegName(Ins.Dest) + ' <- [' + IrRegName(Ins.A) + ' + '
        + IntToStr(Ins.Imm) + '] mem=' + IntToStr(Ins.B);

    { The store family is the one place a SOURCE register lives in Dest,
      so that A is always the address and B always the memory index across
      loads and stores. }
    iroI32Store .. iroI64Store32:
      Result := '[' + IrRegName(Ins.A) + ' + ' + IntToStr(Ins.Imm)
        + '] <- ' + IrRegName(Ins.Dest) + ' mem=' + IntToStr(Ins.B);

    iroI32Const, iroI64Const:
      Result := IrRegName(Ins.Dest) + ' <- ' + IntToStr(Ins.Imm);
    iroF32Const:
      Result := IrRegName(Ins.Dest) + ' <- 0x' + IntToHex(Ins.Imm, 8);
    iroF64Const:
      Result := IrRegName(Ins.Dest) + ' <- 0x' + IntToHex(Ins.Imm, 16);

    { ref.null carries no heap type in the instruction — a null value has
      no runtime type, and the static one is already in RegTypes[Dest],
      which is where the stack map reads it from. }
    iroRefNull:
      Result := IrRegName(Ins.Dest) + ' <- '
        + IrRegTypeName(ARegTypes, Ins.Dest);
    iroRefCast:
      Result := IrRegName(Ins.Dest) + ' <- '
        + IrRegTypeName(ARegTypes, Ins.Dest) + ' ' + IrRegName(Ins.A);
    { ref.test's destination is an i32, so the tested type has to come
      from AuxRefTypes rather than the register table. }
    iroRefTest:
      Result := IrRegName(Ins.Dest) + ' <- '
        + IrRefTypeName(ARefTypes, Ins.Imm) + ' ' + IrRegName(Ins.A);

  else
    Result := IrGenericOperands(Ins, AAux);
  end;
end;

function IrDescribeAt(const ACode: TWasmIrCode;
  const ARegTypes: TWasmIrRegTypes; const AAux: TWasmIrAuxU32;
  const ARefTypes: TWasmIrRefTypes; const AIndex: UInt32): string;
begin
  if AIndex >= UInt32(Length(ACode)) then
    Exit(Format('%.4d  <out of range>', [Integer(AIndex)]));
  Result := TrimRight(Format('%.4d  %-22s %s',
    [Integer(AIndex), IR_OP_INFO[ACode[AIndex].Op].Mnemonic,
     IrOperands(ACode, ARegTypes, AAux, ARefTypes, AIndex)]));
end;

function IrDescribeAll(const ACode: TWasmIrCode;
  const ARegTypes: TWasmIrRegTypes; const AAux: TWasmIrAuxU32;
  const ARefTypes: TWasmIrRefTypes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ACode) do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result
      + IrDescribeAt(ACode, ARegTypes, AAux, ARefTypes, UInt32(I));
  end;
end;

function DescribeIrInstr(const AFn: TWasmIrFunction;
  const AIndex: UInt32): string;
begin
  Result := IrDescribeAt(AFn.Code, AFn.RegTypes, AFn.AuxU32,
    AFn.AuxRefTypes, AIndex);
end;

function DescribeIrFunction(const AFn: TWasmIrFunction): string;
begin
  Result := IrDescribeAll(AFn.Code, AFn.RegTypes, AFn.AuxU32,
    AFn.AuxRefTypes);
end;

function DescribeIrInitExprInstr(const AExpr: TWasmIrInitExpr;
  const AIndex: UInt32): string;
begin
  Result := IrDescribeAt(AExpr.Code, AExpr.RegTypes, AExpr.AuxU32,
    AExpr.AuxRefTypes, AIndex);
end;

function DescribeIrInitExpr(const AExpr: TWasmIrInitExpr): string;
begin
  Result := IrDescribeAll(AExpr.Code, AExpr.RegTypes, AExpr.AuxU32,
    AExpr.AuxRefTypes);
end;

end.
