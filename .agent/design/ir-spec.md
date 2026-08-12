# Track B design — validation, the register IR, and `TWasmIrModule`

Status: design, normative for the four Track B implementation agents.
This document **elaborates** `track-b-contract.md` and may not contradict
it. Where the contract pinned something, this document says so; where it
left a choice open, this document makes it, and the implementer does not.

Spec pin: `wasm-mcp` 0.2.16, upstream `spec/main`
`d7b37e4170d8315f2f1283aed4e8076591a9a333` (`spec_version`). Every
WebAssembly claim below carries the anchor it was read from. Anchors are
spelled as they appear in `section_get` / `instruction_get`; the rendered
URL is `https://webassembly.github.io/spec/core/<path>.html#<anchor>`.

**Confidence markers.** Facts read from the MCP at the pin are unmarked.
Anything asserted from knowledge of the upstream *testsuite* (which is
not served by the MCP and is not vendored — `tests/spec/testsuite/` is
gitignored and absent) is marked **HIGH** or **UNCONFIRMED**. Never
delete a marker; Track C's runner is what promotes an UNCONFIRMED to a
fact.

---

## 0. Scope, units, and the one thing not built

Scope is the contract's: everything the decoder accepts **except** the
`$FD` vector space. The body walker fails on a `$FD` prefix with
`EWasmValidationError` whose message begins
`SIMD validation is not implemented` — read the `u32` subopcode first so
the message can name it, then raise. Never silently accept.

Units and ownership are the contract's five (`Wasm.Ir`,
`Wasm.Validator.Types`, `Wasm.Validator.Const`, `Wasm.Validator.Body`,
`Wasm.Validator`) plus their co-located `.Test.pas`. Two placement
decisions this document adds:

- **Canonical error-message constants live in `Wasm.Validator.Types.pas`'s
  interface** (`MSG_TYPE_MISMATCH = 'type mismatch'`, …). That unit is
  the lowest of the four and the contract already calls it "exposed for
  every later consumer"; Body, Const, and Validator all use it. Do not
  create a sixth unit for messages, and do not scatter string literals.
- **`Wasm.Ir` depends only on `Wasm.Core`** (contract). It therefore
  cannot see `TWasmModule`; `TWasmIrModule` carries its own index-space
  snapshots rather than pointing back at the decoded model.

### 0.1 FPC shape constraints

- `TWasmIrInstr` is a plain `record`, never a class, never generic.
- The `Op` field is the enum itself, sized to 2 bytes by wrapping the
  enum declaration in `{$PACKENUM 2}` … `{$PACKENUM DEFAULT}` in
  `Wasm.Ir.pas` (do **not** put this in `Shared.inc`; it is local to this
  one declaration and the comment explaining why belongs next to it).
- Assert the layout at compile time so a future field never silently
  changes the record size:
  `{$IF SizeOf(TWasmIrInstr) <> 24} {$MESSAGE ERROR '...'} {$IFEND}`
  (2 bytes `Op` + 2 padding + 3×4 bytes + 8 bytes `Imm` = 24).
- Dynamic arrays everywhere for the variable-length parts. No `TList`,
  no generics, no interfaces in the IR structures — ADR-0009 forbids
  managed state on frames a `siglongjmp` can skip, and the IR is read
  from exactly those frames.

---

## 1. `TWasmIrOp` — the complete enum

### 1.1 Naming, ordering, density

One flat enum, wasm-mnemonic naming with an `iro` prefix
(`iroI32Add`), **dense** (no explicit ordinals, no gaps) so the
interpreter's dispatch is a jump table. Members are grouped by family in
wasm opcode order, with the opcode in a trailing comment on every member.

Read the two counts before you start, so you know when you are done.
`instruction_list` at the pin gives **497** instructions total; **234**
are `vec` and a further **22** are the `v128.load*` / `v128.store*`
family filed under `memory`, leaving **241 non-vector instructions** in
scope. Of those, **11 vanish** at lowering, **3** collapse into an
existing member (two binary encodings, one IR op), and the remaining
**227** get one IR op each. Add **4 IR-only** ops: the enum has exactly
**231 members**.

### 1.2 What vanishes, and why

| wasm | opcode | disposition |
| --- | --- | --- |
| `nop` | `0x01` | emits nothing |
| `block` | `0x02` | emits nothing; pushes a control frame (§4) |
| `loop` | `0x03` | emits nothing; records a back-edge target |
| `if` | `0x04` | emits `iroBranchIfNot` (§4.4) |
| `else` | `0x05` | delimiter; emits merge moves + `iroJump` |
| `end` | `0x0B` | delimiter; emits merge moves (and `iroReturn` at function level) |
| `br` | `0x0C` | merge moves + `iroJump` |
| `br_if` | `0x0D` | `iroBranchIf`, or the inverted form (§4.5) |
| `drop` | `0x1A` | emits nothing — see below |
| `local.get` / `local.set` / `local.tee` | `0x20`–`0x22` | `iroMove` (§3.4) |
| `try_table` | `0x1F` | emits nothing; contributes a handler-table entry (§4.9) |

**`drop` emits nothing — decision and justification.** Under register
addressing a value's storage is a register that was already written by
the producing instruction; discarding it is a change to the *validator's*
symbolic stack, not to machine state. The register keeps its dead value,
costing nothing at run time and one entry in the register table (which
would exist anyway, since the producer needed a destination). The
alternative — emitting a no-op so the IR keeps a one-to-one shape with
the source — buys nothing but dispatch cost. In unreachable code `drop`
pops `Bot` and there is no register at all.

**Merged encodings.** `select` has two binary encodings (`0x1B` untyped,
`0x1C` typed) and one IR op. `ref.test` has two (`0xFB 20`, `0xFB 21`)
and `ref.cast` has two (`0xFB 22`, `0xFB 23`); the pair differs only in
the nullability of the tested reference type, which is carried in
`AuxRefTypes` (§2.6), so one IR op each. `br_on_cast` / `br_on_cast_fail`
already have one encoding each; their `castop` flags byte
(`binary-castop`) sets the nullability of `rt1` and `rt2`.

### 1.3 The enum, exhaustively

```pascal
{$PACKENUM 2}
type
  TWasmIrOp = (
    { --- IR-only (no wasm opcode) ------------------------------------ }
    iroMove,                    { Dest <- A }
    iroJump,                    { the only op that can carry a safepoint }
    iroBranchIf,
    iroBranchIfNot,

    { --- control (binary-instr-control) ------------------------------ }
    iroUnreachable,             { 0x00 — the "trap" op }
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
    iroStructNew,               { 0xFB 0  — allocation safepoint }
    iroStructNewDefault,        { 0xFB 1  — allocation safepoint }
    iroStructGet,               { 0xFB 2 }
    iroStructGetS,              { 0xFB 3 }
    iroStructGetU,              { 0xFB 4 }
    iroStructSet,               { 0xFB 5 }

    { --- array ------------------------------------------------------- }
    iroArrayNew,                { 0xFB 6  — allocation safepoint }
    iroArrayNewDefault,         { 0xFB 7  — allocation safepoint }
    iroArrayNewFixed,           { 0xFB 8  — allocation safepoint }
    iroArrayNewData,            { 0xFB 9  — allocation safepoint }
    iroArrayNewElem,            { 0xFB 10 — allocation safepoint }
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
    iroRefI31,                  { 0xFB 28 — allocation safepoint }
    iroI31GetS,                 { 0xFB 29 }
    iroI31GetU                  { 0xFB 30 }
  );
{$PACKENUM DEFAULT}
```

### 1.4 Safepoints — a flag on `iroJump`, and only there

The contract pinned "loop back-edge branches carry a safepoint marker".
This document **confirms the flag** (not a separate op) and **narrows
where it can appear**:

- `iroJump` carries `IR_JUMP_SAFEPOINT = $00000001` in its `Imm` field.
  No other op carries a branch flag.
- **Every back-edge is an `iroJump`.** A conditional branch whose target
  is a `loop` label is *always* lowered through an edge stub (§4.5) whose
  terminating `iroJump` carries the flag. A `br_table` entry targeting a
  loop label likewise goes through a stub — and since §4.6 makes *all*
  `br_table` entries stubs, that falls out for free.
- Function entry is an implicit safepoint (ADR-0011); nothing is emitted
  for it. Instruction index 0 is the entry safepoint by convention.
- Allocation and call sites are safepoints **by op-kind**: `iroCall*`,
  `iroReturnCall*`, `iroStructNew*`, `iroArrayNew*`, `iroRefI31`. No
  marker. `Wasm.Ir` exposes `function IrOpIsSafepoint(const AOp:
  TWasmIrOp): Boolean;` returning True for those and for `iroJump` with
  the flag set (the flag is checked by the caller, which has the
  instruction).

Rejected: **a separate `iroSafepoint` op**. It costs a dispatch on every
loop iteration in the tier that runs everywhere, and — worse — it
separates the epoch check from the branch it must be paired with, so a
backend could reorder or drop one without the other. ADR-0006 makes the
check cheap precisely by keeping it a load-and-compare fused to the
back-edge; a standalone op re-introduces the cost the ADR removes.

Rejected: **the flag on every branch op**. It forces a flags field into
ops that also need `Dest` (`iroBrOnNull`, `iroBrOnCast`) and `Imm`
(`iroBrOnCast`'s reference type), and it multiplies the places Tracks E
and I must remember to emit the epoch check from one to six.

### 1.5 SIMD: appended in Track G, not reserved here

**Decision: do not reserve a range.** Track G appends its ~256 members
after `iroI31GetU`, and bumps `IR_FORMAT_VERSION` to 2.

Reserving a contiguous gap would require explicit ordinals (killing the
"dense, no ordinals" rule), and would put ~250 dead entries into every
`case` jump table the interpreter and disassembler build. Appending
changes no existing member's ordinal, so no existing IR consumer's
dispatch shifts. The `IR_FORMAT_VERSION` bump is the honest signal under
ADR-0007's artifact-rejection rule, and its churn cost is exactly zero
today: there is no AOT artifact cache until Track J, and Track G lands
long before it. Appending will break the "grouped in wasm opcode order"
convention (SIMD will sit after i31); accept that, and say so in the
enum's comment when Track G lands.

---

## 2. Instruction encoding

### 2.1 The record and its sentinels

```pascal
const
  IR_FORMAT_VERSION = 1;
  IR_NO_REG  = UInt32($FFFFFFFF);   { "this field names no register" }
  IR_NO_AUX  = UInt32($FFFFFFFF);   { "this field names no aux block" }
  IR_JUMP_SAFEPOINT = Int64($1);    { iroJump.Imm bit 0 }

type
  TWasmIrInstr = record
    Op: TWasmIrOp;          { 2 bytes, see §0.1 }
    Dest: UInt32;
    A: UInt32;
    B: UInt32;
    Imm: Int64;
  end;
```

### 2.2 The field-kind table (normative, and machine-readable)

`Dest`, `A`, and `B` do **not** always name registers. `Wasm.Ir` declares
a per-op descriptor so the disassembler, the stack-map projection, and
any future register-renumbering pass never guess:

```pascal
type
  TWasmIrFieldKind = (
    ifkUnused,      { field is 0 / IR_NO_REG and must be ignored }
    ifkDestReg,     { a register this op WRITES }
    ifkSrcReg,      { a register this op READS }
    ifkInstrIndex,  { an index into the function's Code array }
    ifkAuxIndex,    { an index into AuxU32 (length-prefixed block) }
    ifkRefTypeIndex,{ an index into AuxRefTypes }
    ifkTypeIndex, ifkFuncIndex, ifkTableIndex, ifkMemIndex,
    ifkGlobalIndex, ifkTagIndex, ifkDataIndex, ifkElemIndex,
    ifkFieldIndex,
    ifkFlags,       { bit field (iroJump only) }
    ifkImmValue,    { a literal value / bit pattern }
    ifkPacked       { two u32 indices packed into Imm, see §2.3 }
  );

  TWasmIrOpInfo = record
    Mnemonic: string;      { rendered by Describe }
    DestKind, AKind, BKind, ImmKind: TWasmIrFieldKind;
  end;

const
  IR_OP_INFO: array[TWasmIrOp] of TWasmIrOpInfo = ( ... );
```

The table is exhaustive over `TWasmIrOp`; FPC will not warn about a
missing entry, so `Wasm.Ir.Test` **must** assert
`Length(IR_OP_INFO) = Ord(High(TWasmIrOp)) + 1` and that every entry has
a non-empty `Mnemonic`.

### 2.3 Packing convention for two indices in `Imm`

Several ops carry two `u32` index immediates. They pack into `Imm` as:

```text
Imm = Int64(Low32) or (Int64(High32) shl 32)
```

`Wasm.Ir` exposes `function IrPack(const ALow, AHigh: UInt32): Int64;`
and `procedure IrUnpack(const AImm: Int64; out ALow, AHigh: UInt32);`.
Which index is low and which is high is fixed per op in §2.5 and must not
be inferred from the binary immediate order.

### 2.4 Aux arrays

Per function, three aux arrays. **Every `AuxU32` block is
length-prefixed**: a block at index `k` is `AuxU32[k]` = the count `N`,
followed by `N` entries at `k+1 .. k+N`. One rule, no exceptions — a
reader never needs a count from elsewhere.

| array | element | used by |
| --- | --- | --- |
| `AuxU32` | `UInt32` | call arg lists, call result lists, `br_table` stub tables, `array.fill/copy/init_*` operand lists, `struct.new` / `array.new_fixed` field lists, `throw` argument lists, catch-clause payload register lists |
| `AuxRefTypes` | `TWasmRefType` | `iroRefTest`, `iroRefCast`, `iroBrOnCast`, `iroBrOnCastFail` |
| `RegTypes` | `TWasmValueType` | the register-type table (§3.3) — not an aux array, but sized the same way |

`AuxU32` blocks are **never shared or deduplicated** in the first
implementation. Determinism of emission is what makes the
`Describe`-based tests stable; a dedup pass is a later, measurable
optimisation.

### 2.5 Field meanings, per family

Registers are `UInt32`. "src" means the field holds a register the op
reads even when the field is named `Dest` — the field-kind table records
this and `Describe` renders it correctly.

#### 2.5.1 IR-only

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroMove` | dest reg | src reg | — | 0 |
| `iroJump` | — | instr index (target) | — | flags (`IR_JUMP_SAFEPOINT`) |
| `iroBranchIf` | — | src reg (i32 condition) | instr index (taken) | 0 |
| `iroBranchIfNot` | — | src reg (i32 condition) | instr index (taken) | 0 |

Fall-through for both conditional forms is `index + 1`.

#### 2.5.2 Control

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroUnreachable` | — | — | — | 0 |
| `iroReturn` | — | — | — | 0 |
| `iroBrTable` | — | src reg (i32 selector) | aux index of the stub table | 0 |
| `iroCall` | — | aux index: arg regs | aux index: result regs | funcidx |
| `iroCallIndirect` | src reg (callee index) | aux: args | aux: results | pack(typeidx, tableidx) |
| `iroCallRef` | src reg (callee funcref) | aux: args | aux: results | typeidx |
| `iroReturnCall` | — | aux: args | — | funcidx |
| `iroReturnCallIndirect` | src reg (callee index) | aux: args | — | pack(typeidx, tableidx) |
| `iroReturnCallRef` | src reg (callee funcref) | aux: args | — | typeidx |
| `iroThrow` | — | aux index: payload regs | — | tagidx |
| `iroThrowRef` | — | src reg (exnref) | — | 0 |
| `iroBrOnNull` | dest reg (non-null refinement, written on **fall-through**) | src reg (the reference) | instr index (taken when null) | 0 |
| `iroBrOnNonNull` | `IR_NO_REG` | src reg | instr index (taken when non-null) | 0 |
| `iroBrOnCast` | dest reg (typed `rt1 \ rt2`, written on **fall-through**) | src reg | instr index (taken when the cast succeeds) | `AuxRefTypes` index of `rt2` |
| `iroBrOnCastFail` | dest reg (typed `rt2`, written on **fall-through**) | src reg | instr index (taken when the cast fails) | `AuxRefTypes` index of `rt2` |

`br_table`'s aux block is `[N, s0, s1, ..., s(N-1)]` where `N` is the
number of entries **including the default**, entry `N-1` is the default,
and every `si` is the instruction index of that edge's stub (§4.6).

Calls always use the aux result list, even for the common
single-result case, and `Dest` is never a call's result. Uniformity wins
here: a call already pays frame setup, so one aux indirection is noise,
and one shape means Track E writes one result-copy loop instead of two.

`iroReturn` takes no operands because the function's results live in a
fixed register block (§3.2); `return` is just a branch to the outermost
label (§4.8).

**Multi-result calls** are exactly the general case: `B` names an aux
block whose count equals the callee's result arity, in order.

#### 2.5.3 Parametric

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroSelect` | dest reg | src reg (value chosen when the condition ≠ 0) | src reg (value chosen when 0) | **condition register**, zero-extended |

The contract listed select's sources as an aux candidate. It does not
need one: three sources plus a destination fit if the condition rides in
`Imm`, and `Imm` is otherwise dead for this op. `ImmKind` is `ifkSrcReg`
for `iroSelect` — the only op where a register lives in `Imm`, and the
field-kind table is what makes that safe.

#### 2.5.4 Variable and global

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroGlobalGet` | dest reg | — | — | globalidx |
| `iroGlobalSet` | — | src reg (value) | — | globalidx |

#### 2.5.5 Table

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroTableGet` | dest reg | src reg (index, table's address type) | — | tableidx |
| `iroTableSet` | — | src reg (index) | src reg (value) | tableidx |
| `iroTableSize` | dest reg | — | — | tableidx |
| `iroTableGrow` | dest reg (old size) | src reg (init value) | src reg (delta) | tableidx |
| `iroTableFill` | src reg (start index) | src reg (value) | src reg (count) | tableidx |
| `iroTableCopy` | src reg (dst index) | src reg (src index) | src reg (count) | pack(dstTableIdx, srcTableIdx) |
| `iroTableInit` | src reg (dst index) | src reg (src offset) | src reg (count) | pack(tableidx, elemidx) |
| `iroElemDrop` | — | — | — | elemidx |

**Three-source rule.** When an op has three source registers and no
destination, they occupy `Dest`, `A`, `B` in **wasm operand order**
(deepest stack operand in `Dest`). This is the same rule for
`table.fill/copy/init`, `memory.fill/copy/init`, and `array.set`.

Note the operand types: `table.get`/`table.set`/`table.fill`/`table.grow`
take the table's **address type** (`valid-table.get`,
`valid-table.grow` — signature `[t at] -> [at]`), not always `i32`, and
`table.copy`/`table.init` mix address types
(`valid-table.copy` signature `[at1 at2 at]`). memory64/table64 makes
this pervasive; see §5.4.

#### 2.5.6 Memory loads and stores

| family | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| all 14 loads | dest reg | src reg (address, memory's address type) | memidx | static offset (u64 stored as Int64) |
| all 9 stores | **src reg (the value)** | src reg (address) | memidx | static offset |

The store family is the one place a source register lives in `Dest`. The
alternative — memidx in `Dest` — puts a non-register in a register-named
field for a whole family and gains nothing; this way `A` is always the
address and `B` is always the memory index across loads and stores.

The **alignment** hint is consumed by validation (§5.4) and **discarded**:
it has no runtime meaning. The offset is a full `u64` (memory64), so
nothing can be packed alongside it in `Imm`; that is why memidx needs a
field of its own.

#### 2.5.7 Memory management

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroMemorySize` | dest reg | — | — | memidx |
| `iroMemoryGrow` | dest reg (old size) | src reg (delta) | — | memidx |
| `iroMemoryFill` | src reg (dst address) | src reg (byte value, i32) | src reg (count) | memidx |
| `iroMemoryCopy` | src reg (dst address) | src reg (src address) | src reg (count) | pack(dstMemIdx, srcMemIdx) |
| `iroMemoryInit` | src reg (dst address) | src reg (src offset, i32) | src reg (count, i32) | pack(memidx, dataidx) |
| `iroDataDrop` | — | — | — | dataidx |

#### 2.5.8 Constants

| op | Dest | Imm |
| --- | --- | --- |
| `iroI32Const` | dest reg | the value, **sign-extended** to Int64 |
| `iroI64Const` | dest reg | the value |
| `iroF32Const` | dest reg | the 32 raw bits, **zero-extended** into Int64 |
| `iroF64Const` | dest reg | the 64 raw bits, reinterpreted as Int64 |

Floats are stored as **bit patterns, never as `Single`/`Double`**. NaN
payloads are observable (`assert_return` with `nan:canonical` /
`nan:arithmetic` — roadmap, Track C) and a round-trip through an FPC
float type is not required to preserve them. Convert with a variant
record or `Move`, never with an assignment between float and integer.

#### 2.5.9 Numeric operations

Unary (`clz`, `eqz`, all conversions, all `reinterpret`, all `extend*_s`,
all `trunc_sat`): `Dest` = dest reg, `A` = src reg, `B` = `IR_NO_REG`,
`Imm` = 0.

Binary (`add` … `copysign`, all compares): `Dest` = dest reg, `A` = left
operand (deeper on the stack), `B` = right operand, `Imm` = 0.

#### 2.5.10 Reference

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroRefNull` | dest reg | — | — | 0 |
| `iroRefIsNull` | dest reg (i32) | src reg | — | 0 |
| `iroRefFunc` | dest reg | — | — | funcidx |
| `iroRefEq` | dest reg (i32) | src reg | src reg | 0 |
| `iroRefAsNonNull` | dest reg | src reg | — | 0 |
| `iroRefTest` | dest reg (i32) | src reg | — | `AuxRefTypes` index |
| `iroRefCast` | dest reg | src reg | — | `AuxRefTypes` index |

`iroRefNull` carries no heap type in the instruction: a null value has no
runtime type, and the static type is already in `RegTypes[Dest]`, which
is where the stack map reads it from (ADR-0011). `Describe` prints the
type by reading the register table.

#### 2.5.11 Struct

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroStructNew` | dest reg | aux index: field value regs (in field order) | — | typeidx |
| `iroStructNewDefault` | dest reg | — | — | typeidx |
| `iroStructGet` / `S` / `U` | dest reg | src reg (the struct ref) | — | pack(typeidx, fieldidx) |
| `iroStructSet` | — | src reg (the struct ref) | src reg (value) | pack(typeidx, fieldidx) |

#### 2.5.12 Array

| op | Dest | A | B | Imm |
| --- | --- | --- | --- | --- |
| `iroArrayNew` | dest reg | src reg (init value) | src reg (length, i32) | typeidx |
| `iroArrayNewDefault` | dest reg | src reg (length, i32) | — | typeidx |
| `iroArrayNewFixed` | dest reg | aux index: element regs | — | typeidx |
| `iroArrayNewData` | dest reg | src reg (offset, i32) | src reg (size, i32) | pack(typeidx, dataidx) |
| `iroArrayNewElem` | dest reg | src reg (offset, i32) | src reg (size, i32) | pack(typeidx, elemidx) |
| `iroArrayGet` / `S` / `U` | dest reg | src reg (array ref) | src reg (index, i32) | typeidx |
| `iroArraySet` | src reg (array ref) | src reg (index, i32) | src reg (value) | typeidx |
| `iroArrayLen` | dest reg (i32) | src reg (array ref) | — | 0 |
| `iroArrayFill` | — | aux index: 4 regs `[ref, index, value, count]` | — | typeidx |
| `iroArrayCopy` | — | aux index: 5 regs `[dstRef, dstIdx, srcRef, srcIdx, count]` | — | pack(dstTypeIdx, srcTypeIdx) |
| `iroArrayInitData` | — | aux index: 4 regs `[ref, index, offset, count]` | — | pack(typeidx, dataidx) |
| `iroArrayInitElem` | — | aux index: 4 regs `[ref, index, offset, count]` | — | pack(typeidx, elemidx) |

Four and five operands do not fit three fields; those four ops use an aux
block. Operand order in the block is the wasm stack order, deepest first
— confirmed against `valid-array.fill`
(`[(ref null x) i32 t i32]`), `valid-array.copy`
(`[(ref null x) i32 (ref null y) i32 i32]`), and `valid-array.init_data`
(`[(ref null x) i32 i32 i32]`).

#### 2.5.13 i31 and extern

All five (`iroRefI31`, `iroI31GetS`, `iroI31GetU`,
`iroAnyConvertExtern`, `iroExternConvertAny`) are unary: `Dest` = dest
reg, `A` = src reg, `Imm` = 0.

### 2.6 `AuxRefTypes` and the two cast encodings

`ref.test`/`ref.cast` come in a nullable and a non-nullable encoding
(`0xFB 20`/`21` and `22`/`23`); `br_on_cast`/`br_on_cast_fail` carry a
`castop` flags byte (`binary-castop`, values `$00..$03`) giving the
nullability of `rt1` and `rt2` independently, followed by two heap types.
In all four cases the IR stores **only `rt2`** (the type being tested
against) in `AuxRefTypes`, because `rt1` is a validation-time constraint
on the operand and has no runtime meaning. The refined result types are
recorded in `RegTypes` for `Dest`.

### 2.7 The `Describe` disassembler (test surface — pin exactly)

Tests assert disassembled text, not record internals, so the format is
part of the contract between Track B's four agents.

```pascal
function DescribeIrInstr(const AFn: TWasmIrFunction;
  const AIndex: UInt32): string;
function DescribeIrFunction(const AFn: TWasmIrFunction): string;  { one line per instr, LF-separated, no trailing LF }
```

Line format: `Format('%.4d  %-22s %s', [Index, Mnemonic, Operands])`,
with trailing whitespace trimmed. Registers render `r<N>`; instruction
indices render `@<4-digit>`; `IR_NO_REG` renders `-`. Operand forms:

```text
0000  i32.const              r2 <- 7
0001  f64.const              r3 <- 0x3FF0000000000000
0002  i32.add                r4 <- r2, r2
0003  move                   r1 <- r4
0004  i32.load               r5 <- [r4 + 8] mem=0
0005  i32.store              [r4 + 8] <- r6 mem=0
0006  global.get             r7 <- g2
0007  global.set             g2 <- r7
0008  table.get              r8 <- t1[r5]
0009  select                 r9 <- r2, r3 ? r5
0010  branch_if              r5 -> @0014
0011  branch_if_not          r5 -> @0014
0012  jump                   @0003 safepoint
0013  br_table               r5 -> [@0016, @0018, @0020]
0014  call                   f3 (r1, r2) -> (r7)
0015  call_indirect          type=4 table=0 [r5] (r1) -> (r7)
0016  br_on_cast             r6 -> @0021 else r7 <- (ref null 3)
0017  struct.new             r8 <- type=2 (r1, r2)
0018  array.fill             type=5 (r1, r2, r3, r4)
0019  ref.null               r9 <- nullfuncref
0020  return
0021  unreachable
```

Rules the forms follow, so a new op needs no new decision: a destination
is `<dest> <-` followed by a space; source registers are comma-separated;
index immediates
render as `<letter><n>` for the compact spaces (`g`=global, `t`=table,
`f`=function) and `<name>=<n>` otherwise; aux register lists render
parenthesised; branch targets render `-> @nnnn`; the safepoint flag
renders as a trailing space followed by `safepoint`. `ref.null` and `ref.cast`
print the
reference type from `RegTypes[Dest].Describe` (`Wasm.Core` already has
it).

---

## 3. The register model

### 3.1 Registers are not SSA

Virtual registers are `UInt32`, per function, and the IR is **not** SSA.
Two reasons, both structural:

1. **Locals are mutable homes.** `local.set x` writes local `x`'s
   register; the local's register is assigned many times and is the
   *same* storage each time. Renaming it per assignment would require
   phi nodes at every join, which is exactly the machinery ADR-0012's
   "phi-like moves at merge points" avoids.
2. **Merge registers are multiply assigned by construction.** Every
   branch edge into a label writes the label's merge registers (§4.2), so
   a merge register has many definitions and one storage slot.

Temporaries, by contrast, are single-assignment — see §3.2.

### 3.2 Numbering and the monotonic-temporaries decision

Per function, in this order:

```text
[0 .. P-1]                 parameters, in declaration order
[P .. P+L-1]               declared locals, run-length expanded, in order
[P+L .. P+L+R-1]           the return register block (R = result arity)
[P+L+R .. RegisterCount-1] merge registers and temporaries, allocated
                           monotonically as the body walk proceeds
```

`ReturnRegBase = P + L` is recorded in the function's metadata, so a
caller reads a callee's results from a constant offset without consulting
the type.

**Temporaries are allocated monotonically and never reused within a
function.** This is a decision, and it has a price and a payoff:

- *Payoff 1 — the register-type table is a plain array.* Every register
  has exactly one `TWasmValueType` for the whole function. ADR-0011's
  stack map is then literally a projection of that array — one bitset,
  computed once. With reuse, a register's type would vary by program
  point and the stack map would need a per-safepoint type map, which is
  the second analysis ADR-0011 exists to avoid.
- *Payoff 2 — refinement and re-entry are correct without analysis.* The
  `if`-without-`else` path (§4.4) and `br_on_cast`'s fall-through
  refinement (§2.5.2) both depend on a register still holding its value
  at a program point the producing instruction did not dominate in a
  stack-discipline allocator. Monotonic allocation makes that free.
- *Price — the interpreter frame is `RegisterCount` slots.* Register
  count grows with the number of value-producing *instructions*, i.e.
  with code size, not with execution. It is bounded and comparable to the
  translated-bytecode footprint ADR-0007 already committed to measuring
  ("IR bytes per bytecode byte"). `wasmbench` must additionally report
  **frame slots per function** so this stops being a guess.
- *Escape hatch, deliberately not taken now:* a liveness-based
  renumbering pass over the **finished** IR can compact registers without
  changing the IR's shape, provided it also emits per-safepoint type
  maps. That is a Track E/I optimisation with its own measurement, not a
  Track B design element.

`RegisterCount` is the frame size. There is no separate operand-stack
depth to record.

### 3.3 The register-type table

```pascal
  RegTypes: array of TWasmValueType;   { length = RegisterCount }
  RefRegBits: array of UInt32;         { bitset, bit i set iff RegTypes[i].Kind = wvkRef }
```

`RegTypes` is authoritative. `RefRegBits` is computed once at the end of
the function walk and is the ADR-0011 projection the collector scans;
`Wasm.Ir` exposes `function IrRegIsRef(const AFn: TWasmIrFunction;
const AReg: UInt32): Boolean;`. Parameters and locals get their declared
types; the return block gets the function's result types; every allocated
temporary gets the type of the value it holds at the moment of
allocation.

### 3.4 `local.get` / `local.set` / `local.tee`

**`local.get x` emits `iroMove t <- LocalReg[x]`** into a fresh
temporary. Always. It does not alias.

The tempting alternative is to push `LocalReg[x]` onto the symbolic stack
directly and emit nothing. That is wrong without an invalidation
analysis: in `local.get 0; ...; local.set 0; ...` the value pushed by the
`get` must be the *old* contents of local 0, and an alias would observe
the new one. Production engines solve it with copy-on-write spilling of
aliased stack entries at every `local.set`/`local.tee`, which is a
well-known bug class and — per ADR-0012 — a bug here is a
*miscompilation*, not a rejected module.

The move is still strictly cheaper than what ADR-0012 set out to remove:
an operand-stack interpreter pays a push **and** a pop for the same
value, plus the stack-pointer traffic. And the optimisation remains
available as a pure IR-level peephole in Track E — `iroMove t <- L`
followed by uses of `t` with no intervening write to `L` folds to direct
uses of `L` — which changes no IR structure and needs no format bump.

- `local.set x`: pop `r`; emit `iroMove LocalReg[x] <- r`.
- `local.tee x`: pop `r`; emit `iroMove LocalReg[x] <- r`; push **`r`**
  again. No second move: `r` is a temporary and temporaries are
  single-assignment, so `r` still holds the value. (`r` can also be a
  merge register — see §4.2 — which is likewise not written again on this
  path before its next use.)

---

## 4. Control-flow lowering

This is the correctness-critical section. ADR-0012 names three risk
spots; all three are specified here with worked examples.

### 4.1 The control frame

```pascal
type
  TWasmCtrlKind = (wckBlock, wckLoop, wckIf, wckElse, wckTryTable,
                   wckFuncBody);

  TWasmCtrlFrame = record
    Kind: TWasmCtrlKind;
    StartTypes: array of TWasmValueType;   { block params }
    EndTypes: array of TWasmValueType;     { block results }
    ParamRegs: array of UInt32;            { registers holding StartTypes at entry }
    MergeRegs: array of UInt32;            { see §4.2 }
    ValHeight: NativeUInt;                 { value-stack height at entry }
    InitHeight: NativeUInt;                { init-stack height at entry }
    Unreachable: Boolean;
    LoopHeader: UInt32;                    { loop only: the back-edge target }
    JumpPatches: array of UInt32;          { instruction indices to patch at end }
    ClausePatches: array of UInt32;        { handler-clause indices to patch at end }
    HandlerIndex: UInt32;                  { try_table only }
  end;
```

This is the spec's `ctrl_frame`
(`appendix/algorithm-stacks`) plus four register-lowering fields.

### 4.2 Merge registers

`MergeRegs` is the vector of registers every edge into the frame's label
must write, and it is what the label's arriving values live in.

- **Allocation happens at block entry**, one register per label type,
  typed from the label type.
- **Which types**: `label_types(frame)` is `StartTypes` for a `loop` and
  `EndTypes` for everything else (`appendix/algorithm-stacks`,
  `label_types`). So:
  - `wckLoop`: `MergeRegs` has one register per **param**, allocated at
    the `loop` opcode. The `loop`'s params are popped and **moved** into
    them, then the merge registers are pushed back. This is the one entry
    that costs moves, and it must: back-edges write these registers.
  - `wckBlock`, `wckIf`, `wckElse`, `wckTryTable`, `wckFuncBody`:
    `MergeRegs` has one register per **result**, allocated at entry. No
    entry moves — nothing branches to a block's *start*, so the params
    can stay where they are. `ParamRegs` records them for the
    `if`-without-`else` and `else` re-entry paths.
  - A `loop` allocates **no** result merge registers: a loop's `end` is
    reached only by fall-through, so there is nothing to merge.
- `wckFuncBody`'s `MergeRegs` **is the return register block**
  (§3.2). That is what makes `return` an ordinary branch.
- `wckElse` **shares** the `if` frame's `MergeRegs` and `ParamRegs`
  objects (same register numbers) — both arms must land in the same
  place.

### 4.3 The merge-move algorithm (normative)

At every branch site, immediately **before** the jump, emit the parallel
move `MergeRegs[i] <- StackReg[i]` for `i` in `0 .. N-1`, where
`StackReg` is the top `N` value-stack entries in stack order (deepest
first) and `N = Length(label_types(target))`. The values are *not* popped
by `br`-family instructions that continue (`br_if`, `br_on_*`) — those
push the same registers back, per the spec algorithm.

Emit it as a **correct parallel move**, not a naive left-to-right loop:

```text
procedure EmitParallelMove(Dests, Sources: array of UInt32)
  1. Drop every pair where Dests[i] = Sources[i].          { self-moves }
  2. While a pair (d, s) exists whose d is not the Source of any
     remaining pair:
         emit iroMove d <- s ; remove the pair.
  3. If pairs remain, they form one or more cycles. Pick any remaining
     pair (d, s). Allocate a fresh temporary `tmp` with RegTypes[tmp] =
     RegTypes[d]. Emit iroMove tmp <- d. Rewrite every remaining pair
     whose Source = d to have Source = tmp. Go to 2.
  4. Terminates: each iteration of 3 strictly reduces the number of
     cycles.
```

Destinations are distinct by construction (a label's merge registers are
allocated once each). Sources may repeat (the same register can appear
twice on the value stack) — step 2 handles that without special-casing.
Cycles are believed unreachable for well-formed wasm, but the algorithm
is cheap, `N` is tiny, and "believed unreachable" is not a proof; the
cycle path must exist and must have a unit test that drives it through
`EmitParallelMove` directly.

### 4.4 Branch-target resolution

Forward targets are unknown when the branch is emitted, so each frame
carries `JumpPatches` (instruction indices) and `ClausePatches` (handler
clause indices). At the frame's resolution point, every recorded
instruction's target field is set to the resolved index; the field is
derived from the op (`iroJump` → `A`; every other branch op → `B`), so
the patch record is just an index.

**Loops resolve at push time** (`LoopHeader` = the current emission
index, i.e. the index of the first instruction of the loop body); they
never use `JumpPatches`.

**The `else` transfer is the classic bug.** At `else`, the `if` frame is
popped and an `else` frame pushed. The `else` frame **inherits the `if`
frame's `JumpPatches` and `ClausePatches` unresolved** — branches out of
the then-arm target the *same* end. Resolving them at `else` is wrong and
will pass most tests. Write a test with `block ... if ... br 1 ... else
... end ... end`.

### 4.5 Worked example — block with a result

```wat
(func (result i32) (block (result i32) i32.const 7))
```

Body bytes (after the locals vector):
`02 7F 41 07 0B 0B`

Registers: `r0` = return block (i32); temporaries from `r1`.

| step | action |
| --- | --- |
| `wckFuncBody` push | `MergeRegs = [r0]` |
| `02 7F` block | allocate `MergeRegs = [r1]` (i32); no entry moves |
| `41 07` | allocate `r2`; emit |
| `0B` end (block) | reachable → merge move `r1 <- r2`; push `r1` |
| `0B` end (func) | merge move `r0 <- r1`; emit `iroReturn` |

```text
0000  i32.const              r2 <- 7
0001  move                   r1 <- r2
0002  move                   r0 <- r1
0003  return
```

Two chained moves is the honest output of straightforward emission: the
block's `end` merges `r2` into the block's merge register `r1`, and the
function's `end` merges `r1` into the return register `r0`. Copy
coalescing is a later pass; do not hand-optimise it in Track B, because
the tests assert this text and a partial optimisation is worse than
none.

### 4.6 Worked example — loop with a back-edge (safepoint shown)

```wat
(func (param i32) (result i32)
  (local i32)
  block $exit
    loop $l
      local.get 0
      i32.eqz
      br_if $exit          ;; depth 1
      local.get 0
      i32.const 1
      i32.sub
      local.set 0
      br $l                ;; depth 0
    end
  end
  local.get 0)
```

Bytes: locals `01 01 7F`, then
`02 40 03 40 20 00 45 0D 01 20 00 41 01 6B 21 00 0C 00 0B 0B 20 00 0B`

Registers: `r0` param, `r1` local, `r2` return block, temporaries from
`r3`. `$exit` and `$l` are both empty-typed, so all merge vectors are
empty and no merge moves appear — which is exactly why this example
isolates the safepoint.

```text
0000  move                   r3 <- r0
0001  i32.eqz                r4 <- r3
0002  branch_if              r4 -> @0008
0003  move                   r5 <- r0
0004  i32.const              r6 <- 1
0005  i32.sub                r7 <- r5, r6
0006  move                   r0 <- r7
0007  jump                   @0000 safepoint
0008  move                   r8 <- r0
0009  move                   r2 <- r8
0010  return
```

`LoopHeader` for `$l` is `0000`. Instruction `0002` is patched to `0008`
when `$exit` resolves. Instruction `0007` is the back-edge and is the
only safepoint-flagged instruction; the function-entry safepoint is
implicit at index `0000`.

### 4.7 Worked example — `if`/`else` with merge moves

```wat
(func (param i32) (result i32)
  local.get 0
  if (result i32) i32.const 1 else i32.const 2 end)
```

Bytes: `20 00 04 7F 41 01 05 41 02 0B 0B`

Registers: `r0` param, `r1` return block, temporaries from `r2`.

```text
0000  move                   r2 <- r0
0001  branch_if_not          r2 -> @0005
0002  i32.const              r4 <- 1
0003  move                   r3 <- r4
0004  jump                   @0007
0005  i32.const              r5 <- 2
0006  move                   r3 <- r5
0007  move                   r1 <- r3
0008  return
```

- The `if` allocates `MergeRegs = [r3]`, pops the condition `r2`, and
  emits `branch_if_not` with `B` unpatched.
- At `else`: pop the `if` frame → then-arm merge move `r3 <- r4`, then
  `iroJump` (recorded in the **else** frame's `JumpPatches`). `0001`'s
  `B` is patched to the next index, `0005`. Push the `else` frame with
  the same `MergeRegs` and the same `ParamRegs`.
- At `end`: else-arm merge move `r3 <- r5`; resolve `JumpPatches` to
  `0007`; push `r3`.

**`if` without `else`.** The spec requires `t1* = t2*` in that case. The
missing arm is synthesised at `end`: emit the then-arm merge moves and
the jump exactly as above, patch the `branch_if_not` to the next index,
then emit the parallel move `MergeRegs[i] <- ParamRegs[i]` for every `i`,
then resolve. `ParamRegs` is why the frame records them (§4.1), and
monotonic temporaries (§3.2) is why they are still live.

**Unreachable arms.** If an arm is unreachable at its terminator, emit
neither its merge moves nor its jump — there is no fall-through to merge.

### 4.8 Worked example — `br` from nested depth with a multi-value merge

```wat
(type $tt (func (result i32 i64)))
(func (result i32 i64)
  (block $b (type $tt)
    (block
      i32.const 1
      i64.const 2
      br 1)
    i32.const 3
    i64.const 4))
```

Body bytes (with `$tt` at type index 1, so the block type is the s33
`01`):
`02 01 02 40 41 01 42 02 0C 01 0B 41 03 42 04 0B 0B`

Registers: `r0` (i32) and `r1` (i64) are the return block; temporaries
from `r2`.

```text
0000  i32.const              r4 <- 1
0001  i64.const              r5 <- 2
0002  move                   r2 <- r4
0003  move                   r3 <- r5
0004  jump                   @0009
0005  i32.const              r6 <- 3
0006  i64.const              r7 <- 4
0007  move                   r2 <- r6
0008  move                   r3 <- r7
0009  move                   r0 <- r2
0010  move                   r1 <- r3
0011  return
```

`$b` allocates `MergeRegs = [r2 (i32), r3 (i64)]` at entry; the inner
block allocates an empty one. `br 1` pops the top two values (`r4`,
`r5`), runs `EmitParallelMove([r2,r3], [r4,r5])` — no conflicts, no
self-moves — then jumps. The frame is then marked unreachable.

**Unreachable code after `br`.** The inner block's `end` runs with
`Unreachable = True`. It pops its (empty) end types polymorphically,
emits **nothing**, and pops the frame. Nothing between the `br` and the
enclosing `end`/`else` may emit IR — but the walk must still *type-check*
it (`appendix/algorithm-stacks`: "Even with the unreachable flag set,
consecutive operands are still pushed to and popped from the operand
stack. That is necessary to detect invalid examples like
`(unreachable (i32.const) i64.add)`"). Polymorphic pops return `Bot` and
allocate **no register**; a value-stack entry may therefore carry
`(Bot, IR_NO_REG)`. Every emission site must check
`Frame.Unreachable` first and return before touching a register number —
a `Bot` entry's register is `IR_NO_REG` and using it is the archetypal
version of this bug.

### 4.9 Worked example — `br_table` with per-target merge moves

```wat
(func (param i32) (result i32)
  (block $a (result i32)
    (block $b (result i32)
      i32.const 7
      local.get 0
      br_table $b $a $a)))
```

Bytes: `02 7F 02 7F 41 07 20 00 0E 02 00 01 01 0B 0B`
(`0E`, count `02`, entries `00` `01`, default `01`.)

Registers: `r0` param; `r1` return block; `$a` merge `r2`; `$b` merge
`r3`; temporaries from `r4`.

**Every `br_table` entry gets its own stub**, emitted contiguously
immediately after the `iroBrTable`, in entry order, default last. Stubs
are **not** deduplicated even when two entries target the same label —
determinism of emission is what makes the `Describe` tests stable, and
`br_table` is not a hot enough op to trade that away. Placing stubs
immediately after the instruction is safe because `br_table` is
unconditional: the frame is unreachable afterwards, so nothing else is
emitted there anyway.

```text
0000  i32.const              r4 <- 7
0001  move                   r5 <- r0
0002  br_table               r5 -> [@0003, @0005, @0007]
0003  move                   r3 <- r4
0004  jump                   @0009
0005  move                   r2 <- r4
0006  jump                   @0010
0007  move                   r2 <- r4
0008  jump                   @0010
0009  move                   r2 <- r3
0010  move                   r1 <- r2
0011  return
```

`AuxU32` block for `0002` is `[3, 3, 5, 7]` — count 3 (two entries plus
the default), then the three stub indices. `0009` is `$b`'s end (its
merge move into `$a`), `0010` is `$a`'s end.

Arity checking is per the spec algorithm
(`appendix/algorithm-validation-of-opcode-sequences`, `br_table`): every
target's label arity must equal the default's, and each target's label
types are checked by `push_vals(pop_vals(label_types(ctrls[n])))` before
the default's are popped. Mismatched arity is `invalid result arity`
(§6.3), mismatched types are `type mismatch`.

### 4.10 `br_if`, `br_on_*`, and the inverted form

A conditional branch is emitted **directly** when it needs no merge moves
*and* its target is not a `loop` label:

```text
branch_if  cond -> target
```

Otherwise it is emitted in the inverted form, with the taken edge laid
out inline:

```text
0000  branch_if_not          cond -> @0004     ; skip the taken edge
0001  move                   m0 <- s0
0002  move                   m1 <- s1
0003  jump                   @target [safepoint]
0004  ...fall-through continues here
```

This is why both `iroBranchIf` and `iroBranchIfNot` exist: one
conditional branch, no jump on the (common) not-taken path, and the
safepoint lands on a real `iroJump` so §1.4's invariant holds. The
`iroBranchIfNot`'s `B` is patched to the index after the `iroJump`, which
is known immediately — no patch list needed for this one.

`br_on_null` and `br_on_non_null` use the same two shapes, with their own
op in place of `branch_if`. Note their asymmetry: `br_on_null` branches
when the reference **is** null and its refinement (`Dest`, non-nullable)
is written on the **fall-through**; `br_on_non_null` branches when it is
**not** null and the reference value is delivered to the label as the
last merge register, so it has no `Dest`
(`appendix/algorithm-validation-of-opcode-sequences`, `br_on_null`;
`valid-br_on_non_null`).

`br_on_cast` / `br_on_cast_fail` follow the algorithm exactly
(`appendix/algorithm-validation-of-opcode-sequences`, `br_on_cast`): pop
`rt1`, push `rt2`, check the label types with `rt2` on top, pop `rt2`,
push `rt1 \ rt2`. In register terms the taken edge moves the **source**
register into the label's last merge register (typed by the label), and
the fall-through writes `Dest`, typed `rt1 \ rt2`.

**`\` (`\reftypediff`) — HIGH, verify with a testsuite case.** The
difference removes nullability from `rt1` when `rt2` is nullable, and
leaves the heap type alone:
`(ref null₁ ht₁) \ (ref null₂ ht₂) = (ref ht₁)` if `null₂`, else
`(ref null₁ ht₁)`. **Trap for implementers:** the appendix pseudocode
writes `diff_ref_type(rt2, rt1)` — its argument order is the reverse of
the spec's infix `t_1 \reftypediff t_2` in `instruction_get br_on_cast`'s
signature. Name the Pascal helper
`function RefTypeDiff(const ARt1, ARt2: TWasmRefType): TWasmRefType;`
computing `ARt1 \ ARt2`, and comment the discrepancy at the definition.

### 4.11 `return`, including multi-value

`return` is a branch to the outermost (`wckFuncBody`) label:
`EmitParallelMove(ReturnRegs, top-N stack registers)` then `iroReturn`,
then mark the frame unreachable.

```wat
(func (result i32 i32) i32.const 1 i32.const 2 return)
```

`41 01 41 02 0F 0B`

```text
0000  i32.const              r2 <- 1
0001  i32.const              r3 <- 2
0002  move                   r0 <- r2
0003  move                   r1 <- r3
0004  return
0005  return
```

**Invariant: every function's `Code` array ends with exactly one
`iroReturn`, emitted at the function-body `end` whether or not the frame
is reachable.** Instruction `0005` above is dead. It is emitted anyway so
the interpreter's fetch loop needs no end-of-array check — a real cost
saved on the hot path for one dead instruction per function. Assert this
invariant in `Wasm.Ir.Test`.

### 4.12 `try_table` and the handler table

`try_table` emits no instruction. It contributes one entry to the
function's handler table, covering the instruction range of its body.

```pascal
type
  TWasmIrCatchKind = (wickCatch, wickCatchRef, wickCatchAll,
                      wickCatchAllRef);

  TWasmIrCatchClause = record
    Kind: TWasmIrCatchKind;
    TagIndex: UInt32;        { wickCatch / wickCatchRef only }
    TargetInstr: UInt32;     { resolved label target }
    PayloadAux: UInt32;      { AuxU32 block: destination registers }
  end;

  TWasmIrHandler = record
    StartInstr: UInt32;      { inclusive }
    EndInstr: UInt32;        { exclusive }
    ClauseStart: UInt32;     { index into HandlerClauses }
    ClauseCount: UInt32;
  end;
```

`PayloadAux` is **exactly the target label's `MergeRegs` vector**. That
falls out of the validation rule
(`appendix/algorithm-validation-of-opcode-sequences`, `try_table`): each
clause is checked by pushing a `catch` control frame with the label's
types and then pushing the tag's params (plus `exnref` for the `_ref`
forms) and popping the frame, which is precisely the assertion "what the
handler delivers equals what the label expects". So Track H's unwinder
writes the payload values into the label's merge registers in order and
transfers to `TargetInstr`; no stub and no moves are needed. `catch_all`
has an empty payload block; `catch_all_ref` has a one-entry block holding
the label's single `exnref` merge register.

**Clause label resolution.** The clause label indices are resolved
against the control stack **before** the `try_table` frame is pushed —
the appendix evaluates `ctrls[handler.label]` in the pre-push context.
Getting this wrong shifts every label by one and is silent on
`(try_table (catch $t 0) ...)` at the outermost level.

**Nesting order.** Handler entries are appended at each `try_table`'s
`end`, so an inner handler is appended before its enclosing one. A linear
scan from index 0 for the first entry whose `[StartInstr, EndInstr)`
contains the faulting instruction therefore finds the **innermost**
handler. Pin that scan order; do not sort the table.

Worked example:

```wat
(type $t (func (param i32)))
(tag $tag (type $t))
(func (result i32)
  (block $h (result i32)
    (try_table (result i32) (catch $tag $h)
      i32.const 1)))
```

Body bytes: `02 7F 1F 7F 01 00 00 00 41 01 0B 0B 0B`

Registers: `r0` return block; `$h` merge `r1`; try_table merge `r2`;
temporaries from `r3`.

```text
0000  i32.const              r3 <- 1
0001  move                   r2 <- r3
0002  move                   r1 <- r2
0003  move                   r0 <- r1
0004  return
```

Handler table: one entry `{StartInstr: 0, EndInstr: 2, ClauseStart: 0,
ClauseCount: 1}`. Clause 0: `{Kind: wickCatch, TagIndex: 0,
TargetInstr: 2, PayloadAux: block [1, r1]}`. When Track H unwinds an
exception raised inside `[0,2)` with tag 0, it writes the payload i32
into `r1` and resumes at `0002`.

**Obligation for Track H:** transferring into a handler whose target is a
`loop` header bypasses the `iroJump` that would have carried the epoch
check. The unwinder must perform the epoch check itself before resuming.
Record this in Track H's contract; Track B only pins the shape.

### 4.13 Tail calls

`return_call*` are distinct ops so the interpreter can implement O(1)
frame replacement (roadmap: "Tail calls forbid a host-stack-recursive
interpreter"). Lowering: pop the callee's params into the aux argument
list, check that the callee's results match the *current function's*
results (`appendix/algorithm-validation-of-opcode-sequences`,
`return_call_ref`: `error_if(t.results.len() =/= return_types.len())`,
then `pop_vals(return_types)`), emit the op, mark unreachable. No merge
moves into the return block — the callee's results become this function's
results directly.

```wat
(func (param i32) (result i32) local.get 0 (return_call 1))
```

`20 00 12 01 0B`

```text
0000  move                   r2 <- r0
0001  return_call            f1 (r2)
0002  return
```

`0002` is the mandatory trailing `iroReturn` from §4.11.

---

## 5. The validation algorithm

### 5.1 State

The spec's three stacks (`appendix/algorithm-stacks`), with one addition:

```pascal
type
  TWasmValEntry = record
    ValType: TWasmValueType;
    IsBot: Boolean;        { the spec's Bot; TWasmValueType cannot express it }
    Reg: UInt32;           { IR_NO_REG when IsBot }
  end;
```

`TWasmValueType` (`Wasm.Core`) has no `Bot` case and must not grow one —
it is the *binary format's* vocabulary and `Bot` is not representable in
the binary or text format (`syntax-rectypeidx`: these forms "cannot be
used in a program; they only occur during validation or execution"). Keep
`Bot` as the `IsBot` flag on the validator's own entry record, and keep a
parallel `TWasmValHeapBot` notion inside `Wasm.Validator.Types` for
`pop_ref` returning `Ref(Bot, false)`.

The three stacks: `Vals: array of TWasmValEntry`, `Inits: array of
UInt32`, `Ctrls: array of TWasmCtrlFrame`, plus `LocalsInit: array of
Boolean`.

### 5.2 The auxiliary functions

Implement `appendix/algorithm-stacks` verbatim, extended with register
assignment. The two that carry the extension:

```text
PopVal() : TWasmValEntry
  if (Length(Vals) = Ctrls[top].ValHeight) and Ctrls[top].Unreachable then
    Result := (IsBot: True; Reg: IR_NO_REG)
  ErrorIf(Length(Vals) = Ctrls[top].ValHeight, MSG_TYPE_MISMATCH)
  Result := Vals.Pop

PopVal(Expect) : TWasmValEntry
  Result := PopVal
  ErrorIf(not MatchesVal(Result, Expect), MSG_TYPE_MISMATCH)

PushVal(T) : allocates NOTHING — the caller supplies the register
AllocTemp(T) : UInt32 — appends to RegTypes, returns the new number
```

`PushVal` never allocates: a value's register is decided by the
instruction that produced it. Ops allocate their destination with
`AllocTemp` **only when the frame is reachable**; in unreachable code
they emit nothing and push `Bot` entries for their results.

`PushCtrl`, `PopCtrl`, `LabelTypes`, `Unreachable`, `GetLocal`,
`SetLocal`, `ResetLocals` are the spec's, unmodified in behaviour.
`PopCtrl` additionally runs the merge moves (§4.3) when the frame is
reachable, before it checks `Length(Vals) = Frame.ValHeight`.

`Ctrls[0]` in the spec's notation indexes from the **top**; FPC arrays
index from the bottom. Write a `TopCtrl(N)` helper and never index the
raw array in a rule — this transposition is a guaranteed bug otherwise.

### 5.3 Unreachable semantics, exactly

`Unreachable()` (`appendix/algorithm-stacks`) resizes the value stack to
`Ctrls[top].ValHeight` and sets `Ctrls[top].Unreachable := True`. It is
invoked after `unreachable`, `br`, `br_table`, `return`, `throw`, and the
three `return_call*` ops. (`throw_ref` also ends the frame —
`valid-throw_ref` gives it a stack-polymorphic result type `[t_1* exnref]
-> [t_2*]`; treat it as unreachable-inducing.)

The emission rule, stated as an invariant the implementation must
enforce: **while `Ctrls[top].Unreachable` is True, `Wasm.Validator.Body`
emits no instruction, allocates no register, and emits no merge move —
but performs every type check exactly as it would otherwise.** The frame
leaves unreachable mode only when it is popped (`end`) or replaced
(`else`). This is ADR-0012's named risk spot; make it one guard function
(`function Emitting: Boolean`) that every emission site calls, not an
`if` copied 200 times.

`Bot` matches everything (`matches_val`), so pops succeed; `Bot` values
carry `IR_NO_REG`.

### 5.4 Locals: initialization tracking

Non-defaultable locals (non-nullable reference types) start
uninitialized. The 3.0 rule is the `init_stack` in
`appendix/algorithm-stacks`, and the two-rule classification in
`valid-local` ("For cases where both rules are applicable, the former
yields the more permissable type").

- `LocalsInit[i]` starts `True` for parameters and for locals whose type
  is defaultable, `False` otherwise.
- `local.get x` → `GetLocal(x)`: `ErrorIf(not LocalsInit[x],
  MSG_TYPE_MISMATCH)`. **The message here is `type mismatch`, not
  `unknown local`** — the local exists; it is its *type* (`set` vs `set?`)
  that does not match. Marked **HIGH**.
- `local.set x` / `local.tee x` → `SetLocal(x)`: if not already
  initialized, push `x` on `Inits` and set the flag.
- `PopCtrl` calls `ResetLocals(Frame.InitHeight)`, undoing every
  initialization performed inside the block. This is what makes
  `(block (local.set $r ...)) (local.get $r)` invalid.
- `Inits` is bounded by the number of non-defaultable locals; preallocate
  it (`appendix/algorithm-stacks` says so explicitly).

A local's *register* exists regardless of init status; only reads are
gated.

### 5.5 Address types are not always `i32`

memory64 and table64 make the index/address operand type the
memory's or table's **address type** (`TWasmAddrType`), not `i32`. The
signatures confirm it: `i32.load` is `[at] -> [i32]`
(`instruction_get i32.load`), `memory.size` is `[] -> [at]`,
`memory.grow` is `[at] -> [at]`, `memory.copy` is `[at1 at2 at]`,
`memory.init` is `[at i32 i32]`, `table.get` is `[at] -> [t]`,
`table.grow` is `[t at] -> [at]`, `table.copy` is `[at1 at2 at]`,
`table.init` is `[at i32 i32]`. Note the mixed cases: `memory.init`'s
source offset and length are always `i32`; `memory.copy`'s count `at` is
the **minimum** of the two memories' address types per `valid-memory.copy`
— read the formal rule (`Instr_ok/memory.copy`) before implementing that
one rather than guessing which of `at1`/`at2` wins. Marked
**UNCONFIRMED** for the `min` detail specifically.

`array.new_data`/`array.new_elem`/`array.init_*`/`array.fill`/`array.copy`
offsets and counts are always `i32` (`valid-array.new_data`,
`valid-array.fill`, `valid-array.copy`) — arrays are not address-typed.

### 5.6 Alignment lives on the validation side

`valid-memarg`: "Memory instructions use memory arguments, which are
classified by the address type and the bit width of the access they are
suitable for." The side condition `2^align ≤ N/8` is a **validation**
rule, so an over-large alignment is `EWasmValidationError` with the
prefix `alignment must not be larger than natural` (**HIGH**).

The *encoding* of the flags field is a decode rule and is already
implemented in Track A: a flags value `≥ 0x80` matches no production and
is `EWasmDecodeError` (`Wasm.Decoder.Expr.SkipMemarg`; handoff note:
"memarg: bit 6 of align flags signals a trailing memidx; offset is u64;
flags >= 0x80 malformed"). Because the decoder caps flags at `0x7F` and
bit 6 is the memidx flag, `align` reaching the validator is in `0..63` —
there is no alignment-field *overflow* case left to handle on the
validation side. Say that in the code comment; a reviewer will ask.

### 5.7 The decode/validation split inside the fused walk

The class distinction is load-bearing (AGENTS.md) and both classes arise
from the same walk. `EWasmDecodeError` is for **binary-grammar**
violations; `EWasmValidationError` is for **typing** violations.

`EWasmDecodeError` cases in the body walk:

| case | canonical prefix | confidence |
| --- | --- | --- |
| unknown opcode / unknown `$FB` / `$FC` / `$FD` subopcode | `illegal opcode` | UNCONFIRMED — Track A already emits `unknown opcode $xx at offset n`; keep Track A's wording for consistency and let Track C correct it |
| truncated immediate (reader underflow) | `unexpected end` | HIGH |
| LEB128 longer than its width / overlong | `integer representation too long` | HIGH |
| LEB128 value out of range for its width | `integer too large` | HIGH |
| the body's `end` is not the span's last byte | `section size mismatch` | UNCONFIRMED — the reference interpreter may use `unexpected end of section or function`; pick one, put it in a named constant, and let Track C settle it |
| malformed block type | (Track A's wording) | reuse `Wasm.Decoder.Expr` |
| malformed memarg flags (`≥ 0x80`) | (Track A's wording) | reuse |
| malformed catch-clause kind, malformed cast flags | (Track A's wording) | reuse |
| misplaced `else` | (Track A's wording) | reuse |
| `memory.init` / `data.drop` present with no data count section | `data count section required` | HIGH; the contract already fixed the **class** as decode |

The data-count rule's scope: `binary-datacntsec` names only
`MEMORY.INIT` and `DATA.DROP` in its prose. `array.new_data` and
`array.init_data` also carry a `dataidx`, and the same single-pass
argument applies. **Decision: require the data count section for all
four**, and mark the two GC ones **UNCONFIRMED** in the code comment so
Track C's `assert_malformed` cases can correct it cheaply.

Everything else is `EWasmValidationError`.

**`select t*` with a type vector whose length ≠ 1** — the binary grammar
(`0x1C t*:vec(valtype)`) admits any count, and `valid-select` requires
exactly one type, so this is a **validation** error with the prefix
`invalid result arity`. Marked **UNCONFIRMED** (the reference
interpreter may reject it in its decoder); if Track C shows otherwise,
moving it is a one-line change because the check sits at a single site.

### 5.8 Per-family push/pop rules

Every rule cites `valid-<mnemonic>` from `valid/instructions` (the
`instruction_get` `anchors.validation` field). The grouped anchors worth
knowing: all 14 loads share `valid-load-val`, all 9 stores share
`valid-store-val`, both `select` encodings share `valid-select`, and
`valid-memarg` covers the alignment side condition for both.

- **Numeric** (`valid-<mnemonic>`): pop the operand types, allocate the
  destination, push it. Mechanical for all 140.
- **Parametric**: `drop` → `PopVal()`. `select` (untyped, `0x1B`) →
  `pop_val(I32)`, `t1 := pop_val()`, `t2 := pop_val()`, error unless both
  are num or both are vec, error unless `t1 = t2` or either is `Bot`,
  push `if t1 = Bot then t2 else t1`
  (`appendix/algorithm-validation-of-opcode-sequences`). `select t`
  (`0x1C`) → `pop_val(I32)`, `pop_val(t)`, `pop_val(t)`, `push_val(t)` —
  and note the untyped form **rejects reference operands** while the
  typed form accepts them.
- **Variable**: §3.4 and §5.4. `global.get x` → `unknown global` if out of
  range; `global.set x` → additionally `global is immutable` when
  `not Mut` (**HIGH**).
- **Table** (`valid-table.get` …): `unknown table` on index; operand
  types per §5.5; element type from the table's `RefType`.
- **Memory** (`valid-load-val`, `valid-store-val`, `valid-memory.*`):
  `unknown memory` on index; alignment per §5.6; `unknown data segment`
  for `memory.init`/`data.drop` (**HIGH**).
- **Reference**: `ref.null ht` → validate the heap type
  (`valid-heaptype`), push `(ref null ht)`. `ref.func x` →
  `unknown function` if out of range, and **`undeclared function
  reference`** (**HIGH**) if `x ∉ C.REFS` (§6.2); push
  `(ref <concrete func type of x>)` — non-nullable, and the *concrete*
  type, not `funcref`. `ref.test`/`ref.cast` per
  `appendix/algorithm-validation-of-opcode-sequences` (`ref.test`):
  validate the reference type, `pop_val(Ref(top_heap_type(rt), true))`,
  then push (`i32` for test, `rt` for cast).
- **Struct/array/i31/extern**: `expand_def(types[x])` then a kind check
  (`is_struct` / `is_array`), field index bounds, `unpack_field` for
  packed storage (`appendix/algorithm-types`). `struct.get` on a packed
  field without `_s`/`_u` is a type mismatch, and `struct.get_s`/`_u` on
  an unpacked field likewise.
- **Control**: `unknown label` when `Length(Ctrls) ≤ n` (**HIGH**);
  `unknown type` for a bad type index; `unknown tag` for a bad tag index
  (**UNCONFIRMED**); `invalid result arity` for `br_table` arity
  mismatch (**HIGH**). Block types: `valid-blocktype` — the empty form,
  a single value type, or a type index that must expand to a functype.

---

## 6. Module-level validation order

`ValidateModule` runs the phases below in this order. The ordering is not
arbitrary: types must exist before anything names them, imports must be
placed before index spaces are indexed, globals are sequential among
themselves (`valid-constant`: "constant expressions occurring in globals
are further constrained in that contained GLOBAL.GET instructions are
only allowed to refer to imported or previously defined globals"), and
`C.REFS` must be complete before any function body is walked.

### 6.1 The phases

| # | phase | anchor | checks |
| --- | --- | --- | --- |
| 1 | Types | `valid-type`, `valid-rectype`, `valid-subtype`, `valid-comptype`, `valid-heaptype` | incremental, group by group (§7); each declared supertype must be a *previously defined* type and non-`final`; canonicalise as you go |
| 2 | Imports | `valid-importdesc`, `valid-typeuse`, `valid-tabletype`, `valid-memtype`, `valid-globaltype`, `valid-tagtype`, `valid-limits` | each descriptor is valid; index spaces are built imports-first. Import names are **not** required unique |
| 3 | Functions | `valid-func` | each function's type index exists and expands to a functype |
| 4 | Tables | `valid-table`, `valid-tabletype`, `valid-limits` | limits well-formed; with an init expression, it is constant and matches the element type; **without** one, the element type must be defaultable (i.e. nullable) |
| 5 | Memories | `valid-mem`, `valid-memtype`, `valid-limits` | limits well-formed; i32 memories bounded at 65536 pages |
| 6 | Tags | `valid-tag`, `valid-tagtype` | type index exists, expands to a functype with **empty results** |
| 7 | Globals | `valid-global`, `valid-globalseq`, `valid-constant` | sequential: global *i*'s init may reference only imported globals and globals `0 .. i-1`; expression constant and matching |
| 8 | Element segments | `valid-elem`, `valid-elemmode` | reference type valid; every item constant and matching; active mode: table index exists, the table's element type is a supertype of the segment's, offset expression constant of the table's address type |
| 9 | Data segments | `valid-data`, `valid-datamode` | active mode: memory index exists, offset expression constant of the memory's address type |
| 10 | Start | `valid-start` | function index exists and its type is `[] -> []` |
| 11 | Exports | `valid-exportdesc` | index exists in the named space; **names unique across all exports** |
| 12 | Function bodies | `valid-func` + §5 | the fused walk, per code entry, in order |

Phases 1–11 are all module-shape checks and are cheap; phase 12 is
everything else. Emitting IR for init expressions (phases 4, 7, 8, 9)
belongs to `Wasm.Validator.Const`; phase 12 belongs to
`Wasm.Validator.Body`; phase 1 and the matching relation belong to
`Wasm.Validator.Types`; the ordering itself and phases 2–3, 5–6, 10–11
belong to `Wasm.Validator`.

### 6.2 `C.REFS`

`context` defines it as "the list of function indices that occur in the
module outside functions and can hence be used to form references inside
them". Collect, before phase 12, every `funcidx` appearing in:

- global initialiser expressions (`ref.func`)
- table initialiser expressions (`ref.func`)
- element segments — both the `funcidx` vector form and `ref.func` inside
  the expression form
- data segment offset expressions (scan for completeness)
- the export list (`wxkFunc` entries)
- the start section

This set is what `undeclared function reference` is checked against, and
getting it under-populated makes valid modules fail while
over-populating makes `elem.wast`'s negative cases pass wrongly. Build it
as an explicit `array of Boolean` sized to the function index space.

### 6.3 Canonical message prefixes

These are **prefixes**; the reference interpreter's checker does a prefix
match, so the project appends context after them (Track A already
established that convention, and the handoff records "section size
mismatch" being unified for exactly this reason). Declare each as a named
constant in `Wasm.Validator.Types.pas`.

The MCP serves the *specification*, not the testsuite; `spec_search` for
these strings returns nothing, and `tests/spec/testsuite/` is gitignored
and absent from this checkout. The confidence column below is therefore
knowledge of upstream, not a verified read. **Every UNCONFIRMED row is a
guess that Track C's runner will correct in one place.**

| constant | prefix | confidence |
| --- | --- | --- |
| `MSG_TYPE_MISMATCH` | `type mismatch` | HIGH |
| `MSG_UNKNOWN_LABEL` | `unknown label` | HIGH |
| `MSG_UNKNOWN_LOCAL` | `unknown local` | HIGH |
| `MSG_UNKNOWN_GLOBAL` | `unknown global` | HIGH |
| `MSG_UNKNOWN_FUNCTION` | `unknown function` | HIGH |
| `MSG_UNKNOWN_TABLE` | `unknown table` | HIGH |
| `MSG_UNKNOWN_MEMORY` | `unknown memory` | HIGH |
| `MSG_UNKNOWN_TYPE` | `unknown type` | HIGH |
| `MSG_UNKNOWN_TAG` | `unknown tag` | UNCONFIRMED |
| `MSG_UNKNOWN_DATA_SEGMENT` | `unknown data segment` | HIGH |
| `MSG_UNKNOWN_ELEM_SEGMENT` | `unknown elem segment` | UNCONFIRMED |
| `MSG_CONSTANT_EXPRESSION_REQUIRED` | `constant expression required` | HIGH |
| `MSG_DUPLICATE_EXPORT_NAME` | `duplicate export name` | HIGH |
| `MSG_INVALID_RESULT_ARITY` | `invalid result arity` | HIGH |
| `MSG_ALIGNMENT_TOO_LARGE` | `alignment must not be larger than natural` | HIGH |
| `MSG_UNDECLARED_FUNCTION_REFERENCE` | `undeclared function reference` | HIGH |
| `MSG_GLOBAL_IS_IMMUTABLE` | `global is immutable` | HIGH |
| `MSG_SIZE_MINIMUM_GT_MAXIMUM` | `size minimum must not be greater than maximum` | HIGH |
| `MSG_MEMORY_SIZE_LIMIT` | `memory size must be at most 65536 pages (4GiB)` | HIGH |
| `MSG_START_FUNCTION` | `start function` | HIGH |
| `MSG_SUB_TYPE` | `sub type` | UNCONFIRMED (GC declared-subtyping failures) |
| `MSG_SIMD_NOT_IMPLEMENTED` | `SIMD validation is not implemented` | project-local, by contract |

**`memory is immutable` is not on this list.** The contract listed it
with a question mark; there is no such validation rule in the core spec
(memories have no mutability flag — `valid-memtype`). Do not introduce
the constant.

---

## 7. Subtyping and rec-type canonicalisation

`Wasm.Validator.Types` owns this and exposes it to every later consumer.
Two facts settle the design:

1. **Full canonical rec-type equivalence is required.** Type *equality*
   under 3.0 is equality of closed types, and
   `appendix/algorithm-types` states the assumption directly: "We assume
   that all types have been canonicalized, such that equality on two type
   representations holds if and only if their closures are syntactically
   equivalent, making it a constant-time check." A "compare type indices"
   shortcut is wrong across rec groups and across modules.
2. **The type section is validated incrementally**, so a single pass
   works. `valid-type`: "The sequence of types defined in a module is
   validated incrementally, yielding a sequence of defined types
   representing them individually." A rec group may reference itself and
   any *previously defined* group; it may not forward-reference a later
   group. (That is the whole reason rec groups exist: mutually recursive
   types must be in the same group.)

### 7.1 Rolling and canonicalising

Per `aux-roll-rectype`: "Rolling up a recursive type substitutes its
internal type indices with corresponding recursive type indices … this
representation ensures that types with equivalent recursive structure are
also syntactically equal, hence allowing a simple equality check on
(closed) types."

Algorithm, one pass over the type section:

```text
CanonNextId := 0
for each rec group g, with first type index f and member count n:
    key := SerialiseGroup(g, f, n)
    if Interned.TryGet(key, id) then
        GroupCanonBase[g] := id
    else
        id := CanonNextId; CanonNextId += n
        Interned.Add(key, id)
        GroupCanonBase[g] := id
        materialise CanonTypes[id .. id+n-1] from g
    for j in 0..n-1: TypeIndexToCanon[f + j] := GroupCanonBase[g] + j
```

`SerialiseGroup` emits a deterministic byte string for the whole group in
which every **type use** is replaced by one of two tokens:

- `REC_REL(x - f)` when `f ≤ x < f + n` — a reference *inside* this
  group, made position-relative so two structurally identical groups
  serialise identically regardless of where they sit in the index space
  (this is `syntax-rectypeidx`'s recursive type index);
- `CANON(TypeIndexToCanon[x])` when `x < f` — a reference to an
  already-canonicalised type, by its canonical id.
- `x ≥ f + n` is **invalid**: raise `MSG_UNKNOWN_TYPE`.

Everything else in the group serialises structurally: for each member,
the `final` flag, the supertype list (as tokens), the composite kind, and
the field/param/result types with their mutability, packing, and
nullability. Fix the byte layout once in a comment; any layout works as
long as it is injective and deterministic. Tie-break by nothing — the
serialisation is total, so identical keys mean identical types by
construction and there is no tie to break.

`Interned` is a plain hash map from the key bytes to the base canonical
id. FPC's `TFPHashList`/`TStringList` are cold-path acceptable here (type
sections are small and this runs once per module), but the map must be a
private detail so Track D can replace it with an engine-wide table
without touching callers.

**Cross-module equality.** Canonical ids produced here are **module-local**.
Track D needs engine-global ids for `call_indirect`'s runtime type check
and for import/export linking, so `TWasmIrModule` retains each group's
serialised key alongside its canonical id; Track D re-interns the keys
into an engine table and remaps. State this in the unit header so nobody
assumes the ids are portable.

### 7.2 The matching relation

Exposed from `Wasm.Validator.Types`:

```pascal
function MatchesHeapType(const A, B: TWasmHeapType): Boolean;
function MatchesRefType(const A, B: TWasmRefType): Boolean;
function MatchesValType(const A, B: TWasmValueType): Boolean;
function MatchesFieldType(const A, B: TWasmFieldType): Boolean;
function MatchesCompType(const A, B: TWasmCompType): Boolean;
function MatchesFuncType(const A, B: TWasmFuncType): Boolean;
function MatchesExternType(const A, B: <extern type>): Boolean;
```

All take the canonical type table implicitly (pass it, or make these
methods on a `TWasmTypeContext` record — either, but pick one and use it
everywhere).

- `MatchesValType` (`match-valtype`, formal rules `Valtype_sub/bot`,
  `/num`, `/vec`, `/ref`): `Bot` matches everything; numbers and vectors
  match only themselves; references delegate.
- `MatchesRefType` (`match-reftype`):
  `(not A.Nullable or B.Nullable) and MatchesHeapType(A.Heap, B.Heap)`.
- `MatchesHeapType` (`match-heaptype`, rules `Heaptype_sub/refl`,
  `/trans`, `/eq-any`, `/i31-eq`, `/struct-eq`, `/array-eq`, `/struct`,
  `/array`, `/func`, `/typeidx-l`, `/typeidx-r`, `/none`, `/nofunc`,
  `/noexn`, `/noextern`, `/bot`, `/def`):
  - **Four disjoint hierarchies**: `any` (with `eq`, `i31`, `struct`,
    `array`, and every concrete struct/array type; bottom `none`),
    `func` (concrete func types; bottom `nofunc`), `extern` (bottom
    `noextern`), and `exn` (bottom `noexn`). Note that
    `appendix/algorithm-types`' `top_heap_type` omits `exn` entirely —
    it is written for `ref.test`/`ref.cast`, which do not reach the exn
    hierarchy. Return `Exn` for `Exn`/`NoExn` in your own
    `TopHeapType`, and mark that choice **UNCONFIRMED** in the comment;
    Track C will judge it.
  - abstract vs abstract: a fixed 12×12 constant table over
    `TWasmAbsHeapType`. Write it out; do not compute it.
  - concrete vs abstract: map the concrete type's composite kind to
    `struct`/`array`/`func`, then use the table.
  - abstract vs concrete: only the bottom of the matching hierarchy
    (`none` ≤ any concrete aggregate, `nofunc` ≤ any concrete func) and
    `Bot`.
  - **concrete vs concrete**: `A ≤ B` iff `A = B` or `B` is on `A`'s
    declared supertype chain. A type has at most one supertype
    (`valid-rectype`: "Future versions of WebAssembly may allow more than
    one supertype"), so the chain is a list. Precompute, per canonical
    type, a **supertype display**: the ancestor chain root-first plus the
    depth. Then `A ≤ B` iff `Depth(B) ≤ Depth(A)` and
    `Display(A)[Depth(B)] = B` — constant time, no walking, and exactly
    what Track D's `ref.cast` wants on the hot path.
- `MatchesCompType` (`match-comptype`, `match-structtype`,
  `match-arraytype`, `match-functype`):
  - struct ≤ struct: **width** subtyping (`B`'s fields are a prefix of
    `A`'s) plus per-field `MatchesFieldType`.
  - array ≤ array: `MatchesFieldType` on the element.
  - func ≤ func: same arities, params **contravariant**, results
    **covariant**. Getting the variance backwards is the classic error
    and passes every same-type test.
- `MatchesFieldType`: **mutable → invariant** (match in both directions);
  **immutable → covariant** in the storage type. Packed storage matches
  only the identical packed type.

`valid-subtype` (an anchor on `valid-rectype`) is the well-formedness
check on the *declaration*: each declared supertype must be previously
defined, must not be `final`, and the declaring type's composite type
must match the supertype's under `MatchesCompType`.

### 7.3 Where Track D reuses this

- `ref.test` / `ref.cast` / `br_on_cast*` at run time: the same
  `MatchesHeapType` over the display arrays, with the object's runtime
  canonical type on the left.
- `call_indirect`'s "indirect call type mismatch" trap
  (`instruction_get call_indirect`): canonical id equality, not
  subtyping.
- Import/export linking (`EWasmLinkError`): `MatchesExternType`.

None of that needs a second implementation, which is the point of putting
the relation in `Wasm.Validator.Types` rather than inside the body
walker.

---

## 8. `TWasmIrModule`

### 8.1 Shape

```pascal
type
  TWasmIrInitExpr = record
    Code: array of TWasmIrInstr;
    RegTypes: array of TWasmValueType;
    RegisterCount: UInt32;
    ResultReg: UInt32;
    AuxU32: array of UInt32;
    AuxRefTypes: array of TWasmRefType;
  end;

  TWasmIrFunction = record
    TypeIndex: UInt32;            { module type space }
    CanonTypeId: UInt32;          { §7 }
    ParamCount: UInt32;
    LocalCount: UInt32;           { declared locals, excluding params }
    ResultCount: UInt32;
    ReturnRegBase: UInt32;        { = ParamCount + LocalCount }
    RegisterCount: UInt32;        { = the interpreter frame size }
    SourceOffset: NativeUInt;     { absolute, for diagnostics }
    Code: array of TWasmIrInstr;
    RegTypes: array of TWasmValueType;
    RefRegBits: array of UInt32;
    AuxU32: array of UInt32;
    AuxRefTypes: array of TWasmRefType;
    Handlers: array of TWasmIrHandler;
    HandlerClauses: array of TWasmIrCatchClause;
  end;

  TWasmIrElemSegment = record
    Mode: TWasmElemMode;
    TableIndex: UInt32;
    RefType: TWasmRefType;
    Offset: TWasmIrInitExpr;              { active only }
    Items: array of TWasmIrInitExpr;
  end;

  TWasmIrDataSegment = record
    Mode: TWasmDataMode;
    MemIndex: UInt32;
    Offset: TWasmIrInitExpr;              { active only }
    Bytes: TWasmSpan;                     { borrowed, ADR-0003 }
  end;

  TWasmIrModule = class
    { versioning }
    FormatVersion: UInt32;                { = IR_FORMAT_VERSION }
    { types }
    CanonTypes: array of TWasmCanonType;  { comp type + supertype display }
    TypeIndexToCanon: array of UInt32;
    GroupKeys: array of TWasmBytes;       { for Track D's engine-wide interning }
    { index spaces, imports first }
    FuncCanonTypes: array of UInt32;
    FuncIsImported: array of Boolean;
    Tables: array of TWasmTableType;
    Memories: array of TWasmMemType;
    Globals: array of TWasmGlobalType;
    Tags: array of UInt32;                { canonical type ids }
    ImportCount per kind, ExportList ...
    { definitions }
    Functions: array of TWasmIrFunction;  { defined functions, code order }
    GlobalInits: array of TWasmIrInitExpr;
    TableInits: array of TWasmIrInitExpr; { empty entry when HasInit is False }
    Elems: array of TWasmIrElemSegment;
    Datas: array of TWasmIrDataSegment;
    HasStart: Boolean;
    StartFuncIndex: UInt32;
    DeclaredFuncRefs: array of Boolean;   { C.REFS, §6.2 }
  end;
```

Public API, per the contract:

```pascal
function ValidateModule(const AModule: TWasmModule;
  const ABytes: TWasmBytes): TWasmIrModule;
```

### 8.2 Decisions embedded in the shape

- **Element items are normalised to init expressions.** The `funcidx`
  vector form lowers to a one-instruction `iroRefFunc` expression, so
  Track D instantiates elements through exactly one code path.
- **Init expressions have no terminator.** Run `Code[0..High]`, read
  `ResultReg`. Do not emit `iroReturn`; an init expression is not a
  function and giving it a return block would imply a frame it does not
  have.
- **Data bytes stay a `TWasmSpan`.** ADR-0003 stands: the IR module
  borrows the same buffer the decoded module borrowed, and the buffer
  must outlive both. State this in `Wasm.Ir.pas`'s unit header — it is
  the lifetime rule a caller will otherwise get wrong.
- **`FormatVersion` is stamped at construction** and is what an AOT
  artifact records and is rejected against (ADR-0007).

### 8.3 What Track D and Track E consume first

- **Track D (runtime + collector)**: `CanonTypes` with the supertype
  displays, `TypeIndexToCanon`, the four index-space snapshots, `Tags`,
  `GlobalInits`, `TableInits`, `Elems`, `Datas`, `HasStart` /
  `StartFuncIndex`. It does not need `Code` at all to build a store.
- **Track E (interpreter)**: `Functions[i].Code`, `RegTypes`,
  `RefRegBits`, `RegisterCount`, `ReturnRegBase`, `AuxU32`,
  `AuxRefTypes`, and `IrOpIsSafepoint`. `Handlers` /
  `HandlerClauses` are present and populated from day one but unused
  until Track H — that is the contract's point: the IR carries the shape
  now so the tier seam does not move later.

---

## 9. Testing obligations specific to this design

House idiom applies (literal bytes next to the assertion; assert both the
exception class and the message prefix; the two FPC framework gotchas).
Beyond that, these are the tests that exist because of decisions made
here, and none of them is optional:

1. `Wasm.Ir.Test`: `IR_OP_INFO` is total over `TWasmIrOp`; every entry
   has a mnemonic; `SizeOf(TWasmIrInstr) = 24`; `IrPack`/`IrUnpack`
   round-trip across the full `UInt32` range at the boundaries.
2. `Wasm.Ir.Test`: `DescribeIrFunction` output for one instruction of
   every field-kind shape — the format is a test surface (§2.7).
3. `Wasm.Validator.Body.Test`: each of §4's seven worked examples,
   asserted as `Describe` text. They are the regression net for the three
   ADR-0012 risk spots.
4. `Wasm.Validator.Body.Test`: the `else`-patch-transfer case (§4.4) —
   `block (if ... br 1 ... else ... end) end`.
5. `Wasm.Validator.Body.Test`: `EmitParallelMove` driven directly with a
   two-cycle and a duplicate-source input (§4.3).
6. `Wasm.Validator.Body.Test`: `(unreachable (i32.const 0) i64.add)` is
   **invalid** — the appendix names it as the reason unreachable mode
   still type-checks (§5.3).
7. `Wasm.Validator.Body.Test`: every function's `Code` ends with exactly
   one `iroReturn` (§4.11), including a function ending in `br`.
8. `Wasm.Validator.Types.Test`: two structurally identical rec groups at
   different type indices canonicalise to the same key; a forward
   reference across groups raises `unknown type`; func-type variance in
   both directions; mutable-field invariance.
9. `Wasm.Fixtures.Test`: every valid non-SIMD fixture validates;
   `simd.wasm` raises `EWasmValidationError` with the staged SIMD prefix.
10. Every negative case asserts the **class** as well as the prefix. The
    decode/validation boundary (§5.7) is the point of the test, not a
    detail of it.
