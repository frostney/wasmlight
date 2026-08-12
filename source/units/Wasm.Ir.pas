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
    this and refuses anything that does not match. Track G (SIMD) APPENDED
    256 wasm vector ops plus 9 IR-only vector ops to TWasmIrOp and added the
    ifkSrcRegImm field kind, so this went 1 -> 2. The bump is free today:
    there is no AOT artifact cache until Track J, so nothing is rejected. }
  IR_FORMAT_VERSION = 2;

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
    iroI31GetU,                 { 0xFB 30 }

    { === vector / SIMD ($FD prefix) ===================================

      Track G. These break the "grouped in wasm opcode order" convention
      that holds above: SIMD sits AFTER i31 rather than interleaved by
      opcode, because it was appended whole (ir-spec.md §1.5 pre-authorised
      this, and DENSE ordinals matter more than opcode grouping). Within
      the block, members are in SUBOPCODE order 0..275, skipping the 20
      unassigned subopcodes, exactly as Appendix A of the SIMD design doc
      lists them. Comments give the $FD subopcode. None of these can be a
      reference, so none is a safepoint and none affects RefRegBits.

      Verified against wasm-mcp 0.2.16, spec/main
      d7b37e4170d8315f2f1283aed4e8076591a9a333: instruction_list
      category=vec (234) + category=memory prefix=v128. (22) = 256. }

    { --- memory: whole / packed / splat loads, store — memarg (0..11) - }
    iroV128Load,                { $FD 0 }
    iroV128Load8x8S,            { $FD 1 }
    iroV128Load8x8U,            { $FD 2 }
    iroV128Load16x4S,           { $FD 3 }
    iroV128Load16x4U,           { $FD 4 }
    iroV128Load32x2S,           { $FD 5 }
    iroV128Load32x2U,           { $FD 6 }
    iroV128Load8Splat,          { $FD 7 }
    iroV128Load16Splat,         { $FD 8 }
    iroV128Load32Splat,         { $FD 9 }
    iroV128Load64Splat,         { $FD 10 }
    iroV128Store,               { $FD 11 }

    { --- const and shuffle — 16-byte immediate (12..13) --------------- }
    iroV128Const,               { $FD 12 }
    iroI8x16Shuffle,            { $FD 13 }

    { --- swizzle and splat (14..20) ---------------------------------- }
    iroI8x16Swizzle,            { $FD 14 }
    iroI8x16Splat,              { $FD 15 }
    iroI16x8Splat,              { $FD 16 }
    iroI32x4Splat,              { $FD 17 }
    iroI64x2Splat,              { $FD 18 }
    iroF32x4Splat,              { $FD 19 }
    iroF64x2Splat,              { $FD 20 }

    { --- lane access — one laneidx byte (21..34) --------------------- }
    iroI8x16ExtractLaneS,       { $FD 21 }
    iroI8x16ExtractLaneU,       { $FD 22 }
    iroI8x16ReplaceLane,        { $FD 23 }
    iroI16x8ExtractLaneS,       { $FD 24 }
    iroI16x8ExtractLaneU,       { $FD 25 }
    iroI16x8ReplaceLane,        { $FD 26 }
    iroI32x4ExtractLane,        { $FD 27 }
    iroI32x4ReplaceLane,        { $FD 28 }
    iroI64x2ExtractLane,        { $FD 29 }
    iroI64x2ReplaceLane,        { $FD 30 }
    iroF32x4ExtractLane,        { $FD 31 }
    iroF32x4ReplaceLane,        { $FD 32 }
    iroF64x2ExtractLane,        { $FD 33 }
    iroF64x2ReplaceLane,        { $FD 34 }

    { --- comparisons (35..76) ---------------------------------------- }
    iroI8x16Eq,                 { $FD 35 }
    iroI8x16Ne,                 { $FD 36 }
    iroI8x16LtS,                { $FD 37 }
    iroI8x16LtU,                { $FD 38 }
    iroI8x16GtS,                { $FD 39 }
    iroI8x16GtU,                { $FD 40 }
    iroI8x16LeS,                { $FD 41 }
    iroI8x16LeU,                { $FD 42 }
    iroI8x16GeS,                { $FD 43 }
    iroI8x16GeU,                { $FD 44 }
    iroI16x8Eq,                 { $FD 45 }
    iroI16x8Ne,                 { $FD 46 }
    iroI16x8LtS,                { $FD 47 }
    iroI16x8LtU,                { $FD 48 }
    iroI16x8GtS,                { $FD 49 }
    iroI16x8GtU,                { $FD 50 }
    iroI16x8LeS,                { $FD 51 }
    iroI16x8LeU,                { $FD 52 }
    iroI16x8GeS,                { $FD 53 }
    iroI16x8GeU,                { $FD 54 }
    iroI32x4Eq,                 { $FD 55 }
    iroI32x4Ne,                 { $FD 56 }
    iroI32x4LtS,                { $FD 57 }
    iroI32x4LtU,                { $FD 58 }
    iroI32x4GtS,                { $FD 59 }
    iroI32x4GtU,                { $FD 60 }
    iroI32x4LeS,                { $FD 61 }
    iroI32x4LeU,                { $FD 62 }
    iroI32x4GeS,                { $FD 63 }
    iroI32x4GeU,                { $FD 64 }
    iroF32x4Eq,                 { $FD 65 }
    iroF32x4Ne,                 { $FD 66 }
    iroF32x4Lt,                 { $FD 67 }
    iroF32x4Gt,                 { $FD 68 }
    iroF32x4Le,                 { $FD 69 }
    iroF32x4Ge,                 { $FD 70 }
    iroF64x2Eq,                 { $FD 71 }
    iroF64x2Ne,                 { $FD 72 }
    iroF64x2Lt,                 { $FD 73 }
    iroF64x2Gt,                 { $FD 74 }
    iroF64x2Le,                 { $FD 75 }
    iroF64x2Ge,                 { $FD 76 }

    { --- bitwise and the whole-vector test (77..83) ------------------ }
    iroV128Not,                 { $FD 77 }
    iroV128And,                 { $FD 78 }
    iroV128Andnot,              { $FD 79 }
    iroV128Or,                  { $FD 80 }
    iroV128Xor,                 { $FD 81 }
    iroV128Bitselect,           { $FD 82 - ternary, ifkSrcRegImm }
    iroV128AnyTrue,             { $FD 83 }

    { --- memory: lane and zero — memarg + laneidx / memarg (84..93) -- }
    iroV128Load8Lane,           { $FD 84 }
    iroV128Load16Lane,          { $FD 85 }
    iroV128Load32Lane,          { $FD 86 }
    iroV128Load64Lane,          { $FD 87 }
    iroV128Store8Lane,          { $FD 88 }
    iroV128Store16Lane,         { $FD 89 }
    iroV128Store32Lane,         { $FD 90 }
    iroV128Store64Lane,         { $FD 91 }
    iroV128Load32Zero,          { $FD 92 }
    iroV128Load64Zero,          { $FD 93 }

    { --- float conversions (94..95) ---------------------------------- }
    iroF32x4DemoteF64x2Zero,    { $FD 94 }
    iroF64x2PromoteLowF32x4,    { $FD 95 }

    { --- i8x16 unary, narrow, f32x4 rounding, i8x16 arith (96..127) -- }
    iroI8x16Abs,                { $FD 96 }
    iroI8x16Neg,                { $FD 97 }
    iroI8x16Popcnt,             { $FD 98 }
    iroI8x16AllTrue,            { $FD 99 }
    iroI8x16Bitmask,            { $FD 100 }
    iroI8x16NarrowI16x8S,       { $FD 101 }
    iroI8x16NarrowI16x8U,       { $FD 102 }
    iroF32x4Ceil,               { $FD 103 }
    iroF32x4Floor,              { $FD 104 }
    iroF32x4Trunc,              { $FD 105 }
    iroF32x4Nearest,            { $FD 106 }
    iroI8x16Shl,                { $FD 107 }
    iroI8x16ShrS,               { $FD 108 }
    iroI8x16ShrU,               { $FD 109 }
    iroI8x16Add,                { $FD 110 }
    iroI8x16AddSatS,            { $FD 111 }
    iroI8x16AddSatU,            { $FD 112 }
    iroI8x16Sub,                { $FD 113 }
    iroI8x16SubSatS,            { $FD 114 }
    iroI8x16SubSatU,            { $FD 115 }
    iroF64x2Ceil,               { $FD 116 }
    iroF64x2Floor,              { $FD 117 }
    iroI8x16MinS,               { $FD 118 }
    iroI8x16MinU,               { $FD 119 }
    iroI8x16MaxS,               { $FD 120 }
    iroI8x16MaxU,               { $FD 121 }
    iroF64x2Trunc,              { $FD 122 }
    iroI8x16AvgrU,              { $FD 123 }
    iroI16x8ExtaddPairwiseI8x16S, { $FD 124 }
    iroI16x8ExtaddPairwiseI8x16U, { $FD 125 }
    iroI32x4ExtaddPairwiseI16x8S, { $FD 126 }
    iroI32x4ExtaddPairwiseI16x8U, { $FD 127 }

    { --- i16x8 (128..159; 154 unassigned) ---------------------------- }
    iroI16x8Abs,                { $FD 128 }
    iroI16x8Neg,                { $FD 129 }
    iroI16x8Q15mulrSatS,        { $FD 130 }
    iroI16x8AllTrue,            { $FD 131 }
    iroI16x8Bitmask,            { $FD 132 }
    iroI16x8NarrowI32x4S,       { $FD 133 }
    iroI16x8NarrowI32x4U,       { $FD 134 }
    iroI16x8ExtendLowI8x16S,    { $FD 135 }
    iroI16x8ExtendHighI8x16S,   { $FD 136 }
    iroI16x8ExtendLowI8x16U,    { $FD 137 }
    iroI16x8ExtendHighI8x16U,   { $FD 138 }
    iroI16x8Shl,                { $FD 139 }
    iroI16x8ShrS,               { $FD 140 }
    iroI16x8ShrU,               { $FD 141 }
    iroI16x8Add,                { $FD 142 }
    iroI16x8AddSatS,            { $FD 143 }
    iroI16x8AddSatU,            { $FD 144 }
    iroI16x8Sub,                { $FD 145 }
    iroI16x8SubSatS,            { $FD 146 }
    iroI16x8SubSatU,            { $FD 147 }
    iroF64x2Nearest,            { $FD 148 }
    iroI16x8Mul,                { $FD 149 }
    iroI16x8MinS,               { $FD 150 }
    iroI16x8MinU,               { $FD 151 }
    iroI16x8MaxS,               { $FD 152 }
    iroI16x8MaxU,               { $FD 153 }
    iroI16x8AvgrU,              { $FD 155 (154 unassigned) }
    iroI16x8ExtmulLowI8x16S,    { $FD 156 }
    iroI16x8ExtmulHighI8x16S,   { $FD 157 }
    iroI16x8ExtmulLowI8x16U,    { $FD 158 }
    iroI16x8ExtmulHighI8x16U,   { $FD 159 }

    { --- i32x4 (160..191; 162,165,166,175,176,178..180,187 unassigned) }
    iroI32x4Abs,                { $FD 160 }
    iroI32x4Neg,                { $FD 161 }
    iroI32x4AllTrue,            { $FD 163 (162 unassigned) }
    iroI32x4Bitmask,            { $FD 164 }
    iroI32x4ExtendLowI16x8S,    { $FD 167 (165,166 unassigned) }
    iroI32x4ExtendHighI16x8S,   { $FD 168 }
    iroI32x4ExtendLowI16x8U,    { $FD 169 }
    iroI32x4ExtendHighI16x8U,   { $FD 170 }
    iroI32x4Shl,                { $FD 171 }
    iroI32x4ShrS,               { $FD 172 }
    iroI32x4ShrU,               { $FD 173 }
    iroI32x4Add,                { $FD 174 }
    iroI32x4Sub,                { $FD 177 (175,176 unassigned) }
    iroI32x4Mul,                { $FD 181 (178..180 unassigned) }
    iroI32x4MinS,               { $FD 182 }
    iroI32x4MinU,               { $FD 183 }
    iroI32x4MaxS,               { $FD 184 }
    iroI32x4MaxU,               { $FD 185 }
    iroI32x4DotI16x8S,          { $FD 186 }
    iroI32x4ExtmulLowI16x8S,    { $FD 188 (187 unassigned) }
    iroI32x4ExtmulHighI16x8S,   { $FD 189 }
    iroI32x4ExtmulLowI16x8U,    { $FD 190 }
    iroI32x4ExtmulHighI16x8U,   { $FD 191 }

    { --- i64x2 (192..223; 194,197,198,207,208,210..212 unassigned) --- }
    iroI64x2Abs,                { $FD 192 }
    iroI64x2Neg,                { $FD 193 }
    iroI64x2AllTrue,            { $FD 195 (194 unassigned) }
    iroI64x2Bitmask,            { $FD 196 }
    iroI64x2ExtendLowI32x4S,    { $FD 199 (197,198 unassigned) }
    iroI64x2ExtendHighI32x4S,   { $FD 200 }
    iroI64x2ExtendLowI32x4U,    { $FD 201 }
    iroI64x2ExtendHighI32x4U,   { $FD 202 }
    iroI64x2Shl,                { $FD 203 }
    iroI64x2ShrS,               { $FD 204 }
    iroI64x2ShrU,               { $FD 205 }
    iroI64x2Add,                { $FD 206 }
    iroI64x2Sub,                { $FD 209 (207,208 unassigned) }
    iroI64x2Mul,                { $FD 213 (210..212 unassigned) }
    iroI64x2Eq,                 { $FD 214 }
    iroI64x2Ne,                 { $FD 215 }
    iroI64x2LtS,                { $FD 216 }
    iroI64x2GtS,                { $FD 217 }
    iroI64x2LeS,                { $FD 218 }
    iroI64x2GeS,                { $FD 219 (no unsigned i64x2 compares) }
    iroI64x2ExtmulLowI32x4S,    { $FD 220 }
    iroI64x2ExtmulHighI32x4S,   { $FD 221 }
    iroI64x2ExtmulLowI32x4U,    { $FD 222 }
    iroI64x2ExtmulHighI32x4U,   { $FD 223 }

    { --- f32x4 / f64x2 arithmetic (224..247; 226,238 unassigned) ----- }
    iroF32x4Abs,                { $FD 224 }
    iroF32x4Neg,                { $FD 225 }
    iroF32x4Sqrt,               { $FD 227 (226 unassigned) }
    iroF32x4Add,                { $FD 228 }
    iroF32x4Sub,                { $FD 229 }
    iroF32x4Mul,                { $FD 230 }
    iroF32x4Div,                { $FD 231 }
    iroF32x4Min,                { $FD 232 }
    iroF32x4Max,                { $FD 233 }
    iroF32x4Pmin,               { $FD 234 }
    iroF32x4Pmax,               { $FD 235 }
    iroF64x2Abs,                { $FD 236 }
    iroF64x2Neg,                { $FD 237 }
    iroF64x2Sqrt,               { $FD 239 (238 unassigned) }
    iroF64x2Add,                { $FD 240 }
    iroF64x2Sub,                { $FD 241 }
    iroF64x2Mul,                { $FD 242 }
    iroF64x2Div,                { $FD 243 }
    iroF64x2Min,                { $FD 244 }
    iroF64x2Max,                { $FD 245 }
    iroF64x2Pmin,               { $FD 246 }
    iroF64x2Pmax,               { $FD 247 }

    { --- conversions (248..255) -------------------------------------- }
    iroI32x4TruncSatF32x4S,     { $FD 248 }
    iroI32x4TruncSatF32x4U,     { $FD 249 }
    iroF32x4ConvertI32x4S,      { $FD 250 }
    iroF32x4ConvertI32x4U,      { $FD 251 }
    iroI32x4TruncSatF64x2SZero, { $FD 252 }
    iroI32x4TruncSatF64x2UZero, { $FD 253 }
    iroF64x2ConvertLowI32x4S,   { $FD 254 }
    iroF64x2ConvertLowI32x4U,   { $FD 255 }

    { --- relaxed SIMD — the 20 3.0 additions (256..275) --------------

      NOTE: the pinned registry names the f64x2 relaxed-trunc ops
      i32x4.relaxed_trunc_f64x2_s / _u — WITHOUT the _zero suffix the
      non-relaxed trunc_sat forms carry. The SIMD design doc's Appendix A
      wrote them with _zero; the registry is the tiebreaker for the verbatim
      mnemonic (they still fill lanes 2..3 with zero at run time). }
    iroI8x16RelaxedSwizzle,     { $FD 256 }
    iroI32x4RelaxedTruncF32x4S, { $FD 257 }
    iroI32x4RelaxedTruncF32x4U, { $FD 258 }
    iroI32x4RelaxedTruncF64x2S, { $FD 259 }
    iroI32x4RelaxedTruncF64x2U, { $FD 260 }
    iroF32x4RelaxedMadd,        { $FD 261 - ternary, ifkSrcRegImm }
    iroF32x4RelaxedNmadd,       { $FD 262 - ternary, ifkSrcRegImm }
    iroF64x2RelaxedMadd,        { $FD 263 - ternary, ifkSrcRegImm }
    iroF64x2RelaxedNmadd,       { $FD 264 - ternary, ifkSrcRegImm }
    iroI8x16RelaxedLaneselect,  { $FD 265 - ternary, ifkSrcRegImm }
    iroI16x8RelaxedLaneselect,  { $FD 266 - ternary, ifkSrcRegImm }
    iroI32x4RelaxedLaneselect,  { $FD 267 - ternary, ifkSrcRegImm }
    iroI64x2RelaxedLaneselect,  { $FD 268 - ternary, ifkSrcRegImm }
    iroF32x4RelaxedMin,         { $FD 269 }
    iroF32x4RelaxedMax,         { $FD 270 }
    iroF64x2RelaxedMin,         { $FD 271 }
    iroF64x2RelaxedMax,         { $FD 272 }
    iroI16x8RelaxedQ15mulrS,    { $FD 273 }
    iroI16x8RelaxedDotI8x16I7x16S,      { $FD 274 }
    iroI32x4RelaxedDotI8x16I7x16AddS,   { $FD 275 - ternary, ifkSrcRegImm }

    { === IR-only vector ops (no wasm opcode) ==========================

      Emitted by the validator so the interpreter never asks "is this
      register 8 or 16 bytes wide?" at run time (SIMD design §2.4): where a
      width is knowable statically, a *Vec variant is emitted; where the GC
      layout record is in hand (struct.new, array.new_fixed, array.copy) the
      existing op branches on TWasmGcField.IsVec and no new op is added. }
    iroMoveVec,                 { Dest <- A, 16 bytes }
    iroSelectVec,               { Dest <- A, B ? cond(Imm), 16 bytes }
    iroGlobalGetVec,            { a v128 global }
    iroGlobalSetVec,            { a v128 global }
    iroStructGetVec,            { a v128 field }
    iroStructSetVec,            { a v128 field }
    iroArrayGetVec,             { a v128 element }
    iroArraySetVec,             { a v128 element }
    iroArrayFillVec             { array.fill with a v128 value }
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
    ifkPacked,        { two u32 indices packed into Imm — see IrPack }
    { A source REGISTER number carried in Imm. Distinct from ifkSrcReg
      (which names a register in a Dest/A/B field) so a register-renumbering
      pass rewrites Imm too. Introduced by Track G for the ten ternary
      vector ops — v128.bitselect, the four *.relaxed_laneselect, the four
      f*.relaxed_madd/nmadd, and i32x4.relaxed_dot_i8x16_i7x16_add_s — plus
      the IR-only iroSelectVec, all of which need a third source register
      that will not fit Dest/A/B. Appended LAST so no existing kind's
      ordinal moves. Describe renders it r<n>. }
    ifkSrcRegImm
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
      BKind: ifkUnused; ImmKind: ifkUnused),

    { === vector / SIMD ($FD prefix) — see the enum for ordering ======= }

    { --- memory: whole / packed / splat loads, store (0..11) ---------- }
    (Mnemonic: 'v128.load'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load8x8_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load8x8_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load16x4_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load16x4_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load32x2_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load32x2_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load8_splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load16_splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load32_splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load64_splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.store'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),

    { --- const and shuffle — 16-byte immediate in an aux block (12..13) }
    (Mnemonic: 'v128.const'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkAuxIndex),
    (Mnemonic: 'i8x16.shuffle'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkAuxIndex),

    { --- swizzle and splat (14..20) ---------------------------------- }
    (Mnemonic: 'i8x16.swizzle'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),

    { --- lane access — the lane index in Imm (21..34) ---------------- }
    (Mnemonic: 'i8x16.extract_lane_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i8x16.extract_lane_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i8x16.replace_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkImmValue),
    (Mnemonic: 'i16x8.extract_lane_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i16x8.extract_lane_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i16x8.replace_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkImmValue),
    (Mnemonic: 'i32x4.extract_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i32x4.replace_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkImmValue),
    (Mnemonic: 'i64x2.extract_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i64x2.replace_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkImmValue),
    (Mnemonic: 'f32x4.extract_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'f32x4.replace_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkImmValue),
    (Mnemonic: 'f64x2.extract_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'f64x2.replace_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkImmValue),

    { --- comparisons (35..76) — binary v128,v128 -> v128 ------------- }
    (Mnemonic: 'i8x16.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.lt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.lt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.gt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.gt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.le_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.le_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.ge_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.ge_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.lt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.lt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.gt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.gt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.le_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.le_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.ge_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.ge_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.lt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.lt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.gt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.gt_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.le_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.le_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.ge_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.ge_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.lt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.gt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.le'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.ge'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.lt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.gt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.le'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.ge'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- bitwise and the whole-vector test (77..83) ------------------ }
    (Mnemonic: 'v128.not'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'v128.and'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'v128.andnot'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'v128.or'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'v128.xor'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'v128.bitselect'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'v128.any_true'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),

    { --- memory: lane and zero (84..93) ------------------------------

      A *_lane needs six values (dest, addr, source vector, mem index, u64
      offset, lane) and the record has four fields, so a load*_lane / a
      store*_lane carries a 4-word aux block [MemIdx, OffsetLo, OffsetHi,
      LaneIdx] in Imm — see IrAppendAuxLaneMemArg. B holds the source
      vector for a load (whose Dest is the result), and is unused for a
      store (whose Dest holds the value being stored). }
    (Mnemonic: 'v128.load8_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.load16_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.load32_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.load64_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.store8_lane'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.store16_lane'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.store32_lane'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.store64_lane'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.load32_zero'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load64_zero'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),

    { --- float conversions (94..95) — unary -------------------------- }
    (Mnemonic: 'f32x4.demote_f64x2_zero'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.promote_low_f32x4'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),

    { --- i8x16 unary/narrow, f32x4 rounding, i8x16 arith (96..127) --- }
    (Mnemonic: 'i8x16.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.popcnt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.all_true'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.bitmask'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.narrow_i16x8_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.narrow_i16x8_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.ceil'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.floor'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.trunc'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.nearest'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.shl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.shr_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.shr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.add_sat_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.add_sat_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.sub_sat_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.sub_sat_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.ceil'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.floor'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.min_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.min_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.max_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.max_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.trunc'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.avgr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extadd_pairwise_i8x16_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extadd_pairwise_i8x16_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extadd_pairwise_i16x8_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extadd_pairwise_i16x8_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),

    { --- i16x8 (128..159) -------------------------------------------- }
    (Mnemonic: 'i16x8.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.q15mulr_sat_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.all_true'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.bitmask'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.narrow_i32x4_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.narrow_i32x4_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extend_low_i8x16_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extend_high_i8x16_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extend_low_i8x16_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extend_high_i8x16_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.shl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.shr_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.shr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.add_sat_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.add_sat_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.sub_sat_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.sub_sat_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.nearest'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.min_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.min_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.max_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.max_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.avgr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extmul_low_i8x16_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extmul_high_i8x16_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extmul_low_i8x16_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.extmul_high_i8x16_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- i32x4 (160..191) -------------------------------------------- }
    (Mnemonic: 'i32x4.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.all_true'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.bitmask'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extend_low_i16x8_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extend_high_i16x8_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extend_low_i16x8_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extend_high_i16x8_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.shl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.shr_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.shr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.min_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.min_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.max_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.max_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.dot_i16x8_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extmul_low_i16x8_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extmul_high_i16x8_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extmul_low_i16x8_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.extmul_high_i16x8_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- i64x2 (192..223) -------------------------------------------- }
    (Mnemonic: 'i64x2.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.all_true'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.bitmask'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extend_low_i32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extend_high_i32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extend_low_i32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extend_high_i32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.shl'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.shr_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.shr_u'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.eq'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.ne'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.lt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.gt_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.le_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.ge_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extmul_low_i32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extmul_high_i32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extmul_low_i32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i64x2.extmul_high_i32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- f32x4 / f64x2 arithmetic (224..247) ------------------------- }
    (Mnemonic: 'f32x4.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.sqrt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.div'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.min'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.max'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.pmin'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.pmax'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.abs'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.neg'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.sqrt'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.sub'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.mul'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.div'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.min'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.max'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.pmin'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.pmax'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),

    { --- conversions (248..255) — unary ------------------------------ }
    (Mnemonic: 'i32x4.trunc_sat_f32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.trunc_sat_f32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.convert_i32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.convert_i32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.trunc_sat_f64x2_s_zero'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.trunc_sat_f64x2_u_zero'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.convert_low_i32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.convert_low_i32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),

    { --- relaxed SIMD (256..275) ------------------------------------- }
    (Mnemonic: 'i8x16.relaxed_swizzle'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.relaxed_trunc_f32x4_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.relaxed_trunc_f32x4_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.relaxed_trunc_f64x2_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.relaxed_trunc_f64x2_u'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.relaxed_madd'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'f32x4.relaxed_nmadd'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'f64x2.relaxed_madd'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'f64x2.relaxed_nmadd'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'i8x16.relaxed_laneselect'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'i16x8.relaxed_laneselect'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'i32x4.relaxed_laneselect'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'i64x2.relaxed_laneselect'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'f32x4.relaxed_min'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f32x4.relaxed_max'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.relaxed_min'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'f64x2.relaxed_max'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.relaxed_q15mulr_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i16x8.relaxed_dot_i8x16_i7x16_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'i32x4.relaxed_dot_i8x16_i7x16_add_s'; DestKind: ifkDestReg;
      AKind: ifkSrcReg; BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),

    { === IR-only vector ops ($2.4) ===================================

      Field kinds mirror the scalar op each replaces; the width is 16 bytes
      by construction, so a tier reads/writes through PWasmV128 without a
      RegTypes lookup. Mnemonics carry a `.v128` suffix so they stay unique
      from their scalar twins (the duplicate-mnemonic test asserts this). }
    (Mnemonic: 'move.v128'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'select.v128'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'global.get.v128'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkGlobalIndex),
    (Mnemonic: 'global.set.v128'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkGlobalIndex),
    (Mnemonic: 'struct.get.v128'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkPacked),
    (Mnemonic: 'struct.set.v128'; DestKind: ifkUnused; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkPacked),
    (Mnemonic: 'array.get.v128'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.set.v128'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkTypeIndex),
    (Mnemonic: 'array.fill.v128'; DestKind: ifkUnused; AKind: ifkAuxIndex;
      BKind: ifkUnused; ImmKind: ifkTypeIndex)
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

  { Register numbering, per function. Every register names a SLOT of the
    interpreter's flat 8-byte register file, and the numbering is in slot
    order:

      [0 .. base of locals)      parameters, in declaration order
      [.. base of returns)       declared locals, run-length expanded
      [.. base of temporaries)   the return register block
      [.. RegisterCount)         merge registers and temporaries

    THE SLOT RULE (SIMD design §1.3-§1.5). A v128 register occupies TWO
    adjacent slots, low half first, and its low slot is always EVEN;
    IrAllocReg enforces both by padding to even and reserving a pair. So a
    register number is a slot index, RegisterCount is a SLOT COUNT (and the
    interpreter frame size in slots), and Track G broke the old
    register==local identity: use LocalRegs to map a wasm local index to its
    low slot. ReturnRegBase = "the first slot after the last local's slots".

    Temporaries are allocated monotonically and never reused, which is what
    lets RegTypes be a plain array — every slot has exactly one type for the
    whole function, so ADR-0011's stack map is a projection of it rather
    than a second analysis.

    THE GC FRAME-WALK INVARIANT (ADR-0011), which G5's interp frame walk and
    G3's register allocation both depend on: RefRegBits is indexed BY SLOT.
    A v128 spans two slots and NEITHER is ever a reference, so BOTH bits are
    clear — RegTypes[k] = RegTypes[k+1] = v128 (Kind = wvkVec), and
    IrComputeRefRegBits sets a bit only for wvkRef. A reference register
    allocated after a v128 therefore lands at the next free slot with ITS
    bit set and the two vector slots left clear. Any padding slot inserted
    for even alignment is a non-reference type for the same reason. }
  TWasmIrFunction = record
    TypeIndex: UInt32;         { module type space }
    CanonTypeId: UInt32;       { canonical type id, module-local }
    ParamCount: UInt32;        { wasm value count, not a slot count }
    LocalCount: UInt32;        { declared locals, excluding params (values) }
    ResultCount: UInt32;
    ReturnRegBase: UInt32;     { first slot after the last local's slots }
    RegisterCount: UInt32;     { frame size in SLOTS (a v128 costs two) }
    SourceOffset: NativeUInt;  { absolute, for diagnostics }
    Code: TWasmIrCode;
    RegTypes: TWasmIrRegTypes;
    { wasm local index -> its low register/slot. Length =
      ParamCount + LocalCount. Needed because a v128 local breaks the
      1:1 local-index = register identity the pre-SIMD IR relied on;
      local.get/set/tee read this rather than assuming register i = local i.
      Populated by the body walker (Track G3); reuses the u32 array type. }
    LocalRegs: TWasmIrAuxU32;
    { wasm result index -> its low register/slot. Length = ResultCount. The
      return block is allocated with the same even-alignment rule as locals
      (IrAllocReg), so a scalar result BEFORE a v128 result inserts a pad and
      the results are NOT a contiguous run from ReturnRegBase. Marshaling the
      results (DoReturn, ResultSlotCount, the host return path) walks this map
      pad-aware instead of assuming contiguity, exactly as the param seam walks
      LocalRegs. Populated by the body walker; reuses the u32 array type. }
    ResultRegs: TWasmIrAuxU32;
    { Bit i set iff RegTypes[i].Kind = wvkRef, indexed by SLOT. Computed
      once, at the end of the function walk, by IrComputeRefRegBits. Both
      slots of a v128 are clear — see the frame-walk invariant above. }
    RefRegBits: TWasmIrBitset;
    { Slot indices whose entry value must be zero: every declared
      non-parameter local slot and every reference-typed register. Validation
      precomputes this sparse list so recursive compiled entry does not scan or
      clear definition-dominated numeric temporaries. }
    EntryZeroRegs: TWasmIrAuxU32;
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

{ --- vector aux blocks (Track G) -----------------------------------------

  A 16-byte v128 immediate and the lane-load/store memarg both need more
  than the record's four fields hold, so both ride in AuxU32 as ordinary
  length-prefixed blocks — no AuxV128 side table (SIMD design §2.2-§2.3).
  The instruction's Imm holds the block index, with ImmKind ifkAuxIndex.

  v128 immediate (v128.const, i8x16.shuffle mask): a length-4 block whose
  four words hold the 16 bytes verbatim, little-endian within the vector.
  The bytes are copied with a raw Move, so the words are never interpreted
  numerically and the round-trip is endian-safe.

  lane memarg (v128.loadN_lane / storeN_lane): a length-4 block
  [MemIdx, OffsetLo, OffsetHi, LaneIdx] — the static offset is u64 (an i64
  memory does not fit UInt32) so it is split across two words. }

{ Appends a v128's 16 bytes as a length-4 block and returns the block
  index. Exact growth — see IrAppendAuxBlock. }
function IrAppendAuxV128(var AAux: TWasmIrAuxU32;
  const AVec: TWasmV128): UInt32;

{ The amortised form over an (array, live-count) pair. }
function IrAppendAuxV128Growing(var AAux: TWasmIrAuxU32;
  var AAuxCount: Integer; const AVec: TWasmV128): UInt32;

{ Reads the 16 bytes back with a single Move; a missing or truncated block
  yields a zero vector rather than raising (the disassembler runs on
  half-constructed IR). }
procedure IrAuxReadV128(const AAux: TWasmIrAuxU32; const AIndex: UInt32;
  out AVec: TWasmV128);

{ Appends [MemIdx, OffsetLo, OffsetHi, LaneIdx] and returns the block
  index. Exact growth. }
function IrAppendAuxLaneMemArg(var AAux: TWasmIrAuxU32;
  const AMemIdx: UInt32; const AOffset: UInt64; const ALane: UInt32): UInt32;

{ The amortised form. }
function IrAppendAuxLaneMemArgGrowing(var AAux: TWasmIrAuxU32;
  var AAuxCount: Integer; const AMemIdx: UInt32; const AOffset: UInt64;
  const ALane: UInt32): UInt32;

{ Reads the four words back; a missing block yields zeros / IR_NO_REG per
  IrAuxBlockItem's tolerant contract. }
procedure IrAuxReadLaneMemArg(const AAux: TWasmIrAuxU32; const AIndex: UInt32;
  out AMemIdx: UInt32; out AOffset: UInt64; out ALane: UInt32);

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
procedure IrComputeEntryZeroRegs(var AFn: TWasmIrFunction);
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
    natural way to allocate a register of an existing register's type. Copy
    the type out BEFORE any SetLength so a self-aliased AType survives the
    reallocation. }
  Ty: TWasmValueType;

  procedure EnsureCapacity(const ANeed: Integer);
  begin
    if ANeed > Length(ARegTypes) then
      SetLength(ARegTypes, (ANeed * 2) + 16);
  end;

begin
  Ty := AType;

  { A v128 occupies TWO adjacent slots and its low slot must be EVEN (SIMD
    design §1.5), which — since a scalar allocation advances by one — means
    padding when the next free slot is odd. The pad is a dead, non-reference
    filler (i32), so RefRegBits stays clear over it and the GC never scans
    it. Both halves of the pair get the v128 type, so the stack-map
    projection and any width query see a consistent RegTypes; neither half
    is a reference, so both RefRegBits are clear. Returns the low slot. }
  if Ty.Kind = wvkVec then
  begin
    if Odd(ARegCount) then
    begin
      EnsureCapacity(ARegCount + 1);
      ARegTypes[ARegCount] := MakeNumValueType(wntI32);
      Inc(ARegCount);
    end;
    EnsureCapacity(ARegCount + 2);
    ARegTypes[ARegCount] := Ty;
    ARegTypes[ARegCount + 1] := Ty;
    Result := UInt32(ARegCount);
    Inc(ARegCount, 2);
    Exit;
  end;

  { The scalar path keeps the original growth policy verbatim — a caller
    pins Length after a run of allocations. }
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

function IrAppendAuxV128(var AAux: TWasmIrAuxU32;
  const AVec: TWasmV128): UInt32;
var
  Words: array[0..3] of UInt32;
begin
  { Raw byte copy, so the four words carry the 16 bytes verbatim regardless
    of host endianness — they are never read as numbers. }
  Move(AVec, Words[0], 16);
  Result := IrAppendAuxBlock(AAux, Words);
end;

function IrAppendAuxV128Growing(var AAux: TWasmIrAuxU32;
  var AAuxCount: Integer; const AVec: TWasmV128): UInt32;
var
  Words: array[0..3] of UInt32;
begin
  Move(AVec, Words[0], 16);
  Result := IrAppendAuxBlockGrowing(AAux, AAuxCount, Words);
end;

procedure IrAuxReadV128(const AAux: TWasmIrAuxU32; const AIndex: UInt32;
  out AVec: TWasmV128);
begin
  FillChar(AVec, SizeOf(AVec), 0);
  { Need the four data words at AIndex+1..AIndex+4 in range. A missing
    block (IR_NO_AUX) or a truncated one reads as the zero vector. }
  if (AIndex = IR_NO_AUX) or (Int64(AIndex) + 5 > Int64(Length(AAux))) then
    Exit;
  Move(AAux[AIndex + 1], AVec, 16);
end;

function IrAppendAuxLaneMemArg(var AAux: TWasmIrAuxU32;
  const AMemIdx: UInt32; const AOffset: UInt64; const ALane: UInt32): UInt32;
begin
  Result := IrAppendAuxBlock(AAux, [AMemIdx,
    UInt32(AOffset and $FFFFFFFF), UInt32((AOffset shr 32) and $FFFFFFFF),
    ALane]);
end;

function IrAppendAuxLaneMemArgGrowing(var AAux: TWasmIrAuxU32;
  var AAuxCount: Integer; const AMemIdx: UInt32; const AOffset: UInt64;
  const ALane: UInt32): UInt32;
begin
  Result := IrAppendAuxBlockGrowing(AAux, AAuxCount, [AMemIdx,
    UInt32(AOffset and $FFFFFFFF), UInt32((AOffset shr 32) and $FFFFFFFF),
    ALane]);
end;

procedure IrAuxReadLaneMemArg(const AAux: TWasmIrAuxU32; const AIndex: UInt32;
  out AMemIdx: UInt32; out AOffset: UInt64; out ALane: UInt32);
begin
  AMemIdx := IrAuxBlockItem(AAux, AIndex, 0);
  AOffset := UInt64(IrAuxBlockItem(AAux, AIndex, 1))
    or (UInt64(IrAuxBlockItem(AAux, AIndex, 2)) shl 32);
  ALane := IrAuxBlockItem(AAux, AIndex, 3);
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

procedure IrComputeEntryZeroRegs(var AFn: TWasmIrFunction);
var
  Count, I, Reg: Integer;

  procedure Add(const AReg: UInt32);
  begin
    SetLength(AFn.EntryZeroRegs, Count + 1);
    AFn.EntryZeroRegs[Count] := AReg;
    Inc(Count);
  end;

begin
  AFn.EntryZeroRegs := nil;
  Count := 0;
  I := Integer(AFn.ParamCount);
  while I < Integer(AFn.ParamCount + AFn.LocalCount) do
  begin
    Reg := Integer(AFn.LocalRegs[I]);
    case AFn.RegTypes[Reg].Kind of
      wvkNum:
        Add(UInt32(Reg));
      wvkVec:
        begin
          Add(UInt32(Reg));
          Add(UInt32(Reg + 1));
        end;
    end;
    Inc(I);
  end;
  for I := 0 to High(AFn.RegTypes) do
    if AFn.RegTypes[I].Kind = wvkRef then
      Add(UInt32(I));
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
    iroStructGet, iroStructGetS, iroStructGetU, iroStructSet,
    iroStructGetVec, iroStructSetVec:
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

{ The 16 immediate bytes of a v128 constant, in memory order, as lowercase
  hex — directly comparable to a `(v128.const i8x16 …)` byte sequence. }
function IrV128Hex(const AAux: TWasmIrAuxU32; const AAuxIndex: UInt32): string;
var
  V: TWasmV128;
  I: Integer;
begin
  IrAuxReadV128(AAux, AAuxIndex, V);
  Result := '';
  for I := 0 to 15 do
    Result := Result + LowerCase(IntToHex(V.B[I], 2));
end;

{ The 16 shuffle lane indices, decimal, space-separated, from the mask
  block — matching the text form `i8x16.shuffle 0 1 … 15`. }
function IrShuffleLanes(const AAux: TWasmIrAuxU32;
  const AAuxIndex: UInt32): string;
var
  V: TWasmV128;
  I: Integer;
begin
  IrAuxReadV128(AAux, AAuxIndex, V);
  Result := 'lanes[';
  for I := 0 to 15 do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + IntToStr(V.B[I]);
  end;
  Result := Result + ']';
end;

{ `[<addr> + <offset>]` from a lane memarg block. Kept separate from the
  mem/lane tail because a load renders them adjacent (`[..] mem=.. lane=..,
  src`) while a store puts the stored value between them (`[..] <- val
  mem=.. lane=..`), matching the SIMD design §2.6 listing. }
function IrLaneAddr(const AAux: TWasmIrAuxU32; const AAddr: UInt32;
  const AAuxIndex: UInt32): string;
var
  MemIdx, Lane: UInt32;
  Offset: UInt64;
begin
  IrAuxReadLaneMemArg(AAux, AAuxIndex, MemIdx, Offset, Lane);
  Result := '[' + IrRegName(AAddr) + ' + ' + IntToStr(Offset) + ']';
end;

{ `mem=<m> lane=<l>` from a lane memarg block. }
function IrLaneMemLane(const AAux: TWasmIrAuxU32;
  const AAuxIndex: UInt32): string;
var
  MemIdx, Lane: UInt32;
  Offset: UInt64;
begin
  IrAuxReadLaneMemArg(AAux, AAuxIndex, MemIdx, Offset, Lane);
  Result := 'mem=' + IntToStr(MemIdx) + ' lane=' + IntToStr(Lane);
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

    iroMove, iroMoveVec:
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

    { A register rides in Imm — the condition (select) or the third source
      operand of a ternary vector op (ifkSrcRegImm). Same shape either way:
      `Dest <- A, B ? Imm`. }
    iroSelect, iroSelectVec, iroV128Bitselect,
    iroF32x4RelaxedMadd, iroF32x4RelaxedNmadd,
    iroF64x2RelaxedMadd, iroF64x2RelaxedNmadd,
    iroI8x16RelaxedLaneselect, iroI16x8RelaxedLaneselect,
    iroI32x4RelaxedLaneselect, iroI64x2RelaxedLaneselect,
    iroI32x4RelaxedDotI8x16I7x16AddS:
      Result := IrRegName(Ins.Dest) + ' <- ' + IrRegName(Ins.A) + ', '
        + IrRegName(Ins.B) + ' ? ' + IrRegName(UInt32(Ins.Imm));

    iroGlobalGet, iroGlobalGetVec:
      Result := IrRegName(Ins.Dest) + ' <- g' + IntToStr(Ins.Imm);
    iroGlobalSet, iroGlobalSetVec:
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

    { --- vector special forms (SIMD design §2.6) --------------------- }

    { The 16 immediate bytes render as `v128:<hex>` in memory order. }
    iroV128Const:
      Result := IrRegName(Ins.Dest) + ' <- v128:'
        + IrV128Hex(AAux, UInt32(Ins.Imm));

    { Two vector operands plus the decimal 16-lane mask. }
    iroI8x16Shuffle:
      Result := IrRegName(Ins.Dest) + ' <- ' + IrRegName(Ins.A) + ', '
        + IrRegName(Ins.B) + ' ' + IrShuffleLanes(AAux, UInt32(Ins.Imm));

    { Lane access. Extract has no B (BKind ifkUnused); replace does. }
    iroI8x16ExtractLaneS .. iroF64x2ReplaceLane:
      if IR_OP_INFO[Ins.Op].BKind = ifkSrcReg then
        Result := IrRegName(Ins.Dest) + ' <- ' + IrRegName(Ins.A) + ', '
          + IrRegName(Ins.B) + ' lane=' + IntToStr(Ins.Imm)
      else
        Result := IrRegName(Ins.Dest) + ' <- ' + IrRegName(Ins.A)
          + ' lane=' + IntToStr(Ins.Imm);

    { Whole-vector / packed / splat / zero loads: same shape as a scalar
      load — B is the memory index, Imm the static offset. }
    iroV128Load .. iroV128Load64Splat, iroV128Load32Zero, iroV128Load64Zero:
      Result := IrRegName(Ins.Dest) + ' <- [' + IrRegName(Ins.A) + ' + '
        + IntToStr(Ins.Imm) + '] mem=' + IntToStr(Ins.B);

    { The whole-vector store keeps the value register in Dest, like a scalar
      store, so A stays the address and B the memory index. }
    iroV128Store:
      Result := '[' + IrRegName(Ins.A) + ' + ' + IntToStr(Ins.Imm)
        + '] <- ' + IrRegName(Ins.Dest) + ' mem=' + IntToStr(Ins.B);

    { Lane loads: Dest is the result, A the address, B the source vector,
      Imm the [mem, offset, lane] block. }
    iroV128Load8Lane .. iroV128Load64Lane:
      Result := IrRegName(Ins.Dest) + ' <- '
        + IrLaneAddr(AAux, Ins.A, UInt32(Ins.Imm)) + ' '
        + IrLaneMemLane(AAux, UInt32(Ins.Imm)) + ', ' + IrRegName(Ins.B);

    { Lane stores: Dest holds the stored vector, A the address — the value
      renders between the address and the mem/lane tail. }
    iroV128Store8Lane .. iroV128Store64Lane:
      Result := IrLaneAddr(AAux, Ins.A, UInt32(Ins.Imm)) + ' <- '
        + IrRegName(Ins.Dest) + ' '
        + IrLaneMemLane(AAux, UInt32(Ins.Imm));

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
