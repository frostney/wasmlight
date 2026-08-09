# Track G — SIMD (the `v128` vector instruction set)

Status: design contract, not yet implemented. Written against the tree at
`.agent/HANDOFF.md` (Tracks A/B/C/D/E delivered, `$FD` staged everywhere).

Spec authority: `wasm-mcp` 0.2.16, pinned `spec/main`
`d7b37e4170d8315f2f1283aed4e8076591a9a333` (ADR-0004's 3.0 draft).
Every behavioural claim below cites a clause anchor; Appendix B is the
list. Corpus authority: `WebAssembly/testsuite@de54fd27` under
`tests/spec/testsuite/` — 59 `simd_*.wast` files (81,772 lines) plus 7
relaxed-SIMD files (691 lines) that live in the ROOT directory, not under
`proposals/`. **There is no `proposals/relaxed-simd/` directory**; the
relaxed suite is merged into the root corpus.

---

## 0. Scope, and what is already built

### 0.1 The counted surface

| Bucket | Count | Source |
| --- | ---: | --- |
| `instruction_list category=vec` | 234 | 2.0: 214, 3.0 (relaxed): 20 |
| `instruction_list category=memory prefix=v128.` | 22 | the load/store family the spec files under *memory* |
| **Total `$FD` instructions** | **256** | subopcodes 0..275 minus 20 unassigned |

The 20 unassigned subopcodes are `154, 162, 165, 166, 175, 176,
178..180, 187, 194, 197, 198, 207, 208, 210..212, 226, 238`. That list is
already spelled, from the pinned grammar, in
`source/units/Wasm.Decoder.Expr.pas:1173-1180`, and copy-identically in
`Wasm.Validator.Body.Prefixed`. **Those two range lists are the single
best source of truth for the table this track writes** — keep all three in
lock-step, and add a build-time check that they agree.

### 0.2 What already exists (do not rebuild it)

| Already shipped | Where |
| --- | --- |
| `wvkVec` value kind, `TYPE_CODE_V128 = -5`, `MakeVecValueType`, `Describe → 'v128'` | `Wasm.Core.pas:94,350,552,611,646` |
| Full `$FD` immediate-shape decode (`SkipVecInstr`) | `Wasm.Decoder.Expr.pas:268-320` — **the decode side is DONE** |
| `v128` as a param/result/local/global/field valtype in the assembler, emitter, name comparer | `Wasm.Wat.Assembler.pas:340`, `Wasm.Wat.Emit.pas:324`, `Wasm.Wat.Names.pas:191` |
| `ParseI8` / `ParseI16` — added for lane literals, currently unused | `Wasm.Wat.Numbers.pas:80-83,957-982` |
| `WASM_MAX_ACCESS_WIDTH = 16`, chokepoint `ASize is 1/2/4/8/16` | `Wasm.Runtime.Memory.pas:115-119`, `Wasm.Runtime.Store.pas:516` |
| `StorageWidth(wvkVec) = 16`, `TWasmGcField.IsVec` | `Wasm.Runtime.Gc.pas:849,179` |
| `wvcV128` / `wvcEither` parse stubs | `Wasm.Wast.Values.pas:69-70,707-717` |

What is **staged and must be removed** is inventoried in Appendix C.

### 0.3 The one thing this track does not do

Track G does not touch the tier seam, the trap path, the collector's
algorithm, or the epoch check. `v128` is never a reference, so
`RefRegBits`, the stack-map projection, and the root scan are unaffected
by every decision below. That is what makes this track "large but
shallow".

---

## 1. The `v128` value representation — the structural decision

### 1.1 What was pinned, and why it is being revisited

`runtime-spec.md §1.2` recommended, and `Wasm.Runtime.Values.pas:55-60`
records:

> Exactly 8 bytes. v128 needs 16 and deliberately does NOT live here […]
> Track G owns that decision; what is fixed here is that the record stays
> 8 bytes and that widening it later touches this record plus the frame
> allocator, never the store.

That recommendation was made before the interpreter existed. Three facts
the shipped interpreter now supplies change the calculus:

1. The register file is **one flat, non-reallocating reservation** —
   `TWasmInterpContext.Values: PWasmValue`, `GetMem(ValueCap * 8)`,
   default `WasmInterpValueSlots = 1 shl 20` = 8 MiB
   (`Wasm.Interp.pas:61-68,795-803`). A frame is the slice
   `Values[Base .. Base + RegisterCount)`.
2. Argument marshaling, tail-call frame replacement, and host calls are
   all **positional loops over 8-byte slots**
   (`PushWasmFrame` 249-258, `ReplaceWasmFrame`'s
   `Tmp: array[0..1023] of TWasmValue` = 8 KiB, `HostCall`'s two
   `array[0..1023] of TWasmValue` buffers = 16 KiB of Pascal stack).
3. Register access in `Run` is `Reg[Ins^.A].U32` — one indexed load, no
   helper, no indirection. ADR-0012's register design exists to keep it
   that way.

### 1.2 The three candidates, priced

**(a) The pinned side vector.** A second reservation
`Vecs: PWasmV128`, a second per-activation `VecBase`, and a per-function
remap `VecRegSlot: array of UInt32` computed by the same projection that
produces `RefRegBits`.

- Vector operand access becomes two dependent loads:
  `Vecs[Act^.VecBase + Fn^.VecRegSlot[Ins^.A]]`. That is the SIMD hot
  path — the exact path this track exists to make fast.
- `PushWasmFrame`, `ReplaceWasmFrame`, and `HostCall` all need a
  vec-aware second copy path, plus a second `Tmp` buffer for tail calls.
- Static cost is `4 × RegisterCount` per function *whether or not* it
  uses vectors.

**(b) Widen `TWasmValue` to 16 bytes.** Simplest dispatch, and the IR
instruction record is unaffected (IR instructions never hold values, so
the 24-byte `TWasmIrInstr` guard is not in play).

- The reservation doubles to 16 MiB; `ValueZeroSlots` at every
  `PushWasmFrame` copies twice as much; the two host-call buffers become
  32 KiB of Pascal stack and the tail-call `Tmp` becomes 16 KiB.
- Frame cache density halves for the ~99% of functions with no vector
  register. This is precisely the cost ADR-0012's register model exists
  to avoid, paid unconditionally and forever.

**(c) Boxing.** An allocation per `v128` value on the tier of record.
Rejected without further argument: it puts an allocator on the hot path
of a value type that is not a reference, and it would drag `v128` into
the collector for no reason.

### 1.3 Decision — a `v128` register is a **pair of adjacent 8-byte slots**

**`TWasmValue` stays exactly 8 bytes. A `v128` register `k` occupies
slots `k` and `k+1` of the existing register file, low half first, and
`k` is always even.**

```pascal
{ Wasm.Core — vocabulary, so Wasm.Ir, Wasm.Wat.*, Wasm.Interp.Vector and
  Wasm.Runtime.* can all see it without a layering inversion. }
type
  PWasmV128 = ^TWasmV128;
  TWasmV128 = packed record
    case Integer of
      0: (B:   array[0..15] of Byte);
      1: (U16: array[0..7] of Word);
      2: (U32: array[0..3] of UInt32);
      3: (U64: array[0..1] of UInt64);
      4: (F32: array[0..3] of Single);
      5: (F64: array[0..1] of Double);
  end;
```

Lane `i` of shape `t x N` occupies bytes `[i*w, (i+1)*w)` — **little-endian
within the vector**, which is what `syntax-laneidx` means by "packed into
an i128" and what the binary `v128.const` immediate's 16 literal bytes
already are.

```pascal
{ Wasm.Runtime.Values }
function VecAt(const AReg: PWasmValue; const AIndex: UInt32): PWasmV128; inline;
begin
  Result := PWasmV128(@AReg[AIndex]);
end;
```

Dispatch is then exactly as cheap as the scalar case:

```pascal
iroI8x16Add:
  begin V8x16Add(VecAt(Reg, Ins^.A), VecAt(Reg, Ins^.B), VecAt(Reg, Ins^.Dest)); Inc(IP); end;
```

**Why this dominates both (a) and (b).**

| Property | (a) side vector | (b) widen | **pair (chosen)** |
| --- | --- | --- | --- |
| Vector operand access | 2 dependent loads | 1 load | **1 load** |
| Cost to non-SIMD functions | 4 B/register static | 2× everything | **zero** |
| `PushWasmFrame` arg copy | needs a vec path | unchanged | **unchanged** |
| `ReplaceWasmFrame` (tail calls) | second `Tmp` buffer | 16 KiB `Tmp` | **unchanged** |
| `HostCall` ABI | second buffer + a vec map | 32 KiB buffers | **unchanged** |
| `RefRegBits` / stack maps | unchanged | unchanged | **unchanged** |
| Frame memory for a SIMD function | 16 B/vec register | 16 B/register | **16 B/vec register** |
| Local ⇄ register identity | preserved | preserved | **lost — needs a map** |
| `RegisterCount` semantics | wasm registers | wasm registers | **slots, not values** |

The pair design wins the hot path and leaves four boundary mechanisms —
call marshaling, tail-call replacement, the host ABI, and the GC bit
computation — structurally untouched. It pays for that with two
bookkeeping changes (§1.4, §1.5), both local to the validator.

It also honours the letter of the pinned constraint: `TWasmValue` stays
8 bytes and the store is not restructured. The only store change is
§1.7's global cell.

### 1.4 Consequence 1 — the local-to-register map

`Wasm.Validator.Body.pas:3966-3981` allocates one register per local in
order, so today `register i = local i` by identity, and
`ReturnRegBase = ParamCount + LocalCount`. With pairs that identity
breaks.

The body walker gains

```pascal
FLocalReg: array of UInt32;    { wasm local index -> low register }
```

built in the same loop that fills `FLocalTypes`, and `local.get` /
`local.set` / `local.tee` (lines 1828-1896) read `FLocalReg[Idx]` instead
of `Idx`. `TWasmIrFunction` gains the same array so a tier can map back:

```pascal
LocalRegs: TWasmIrAuxU32;   { reuse the u32 array type; length = ParamCount + LocalCount }
```

`ParamCount` / `LocalCount` keep their wasm meaning (value counts).
`ReturnRegBase` becomes "the first register after the last local's
slots"; `RegisterCount` is redefined from "register count" to **"frame
slot count"** and its comment in `Wasm.Ir.pas` must say so. Nothing in
`Wasm.Interp` reads `RegisterCount` as anything but a slot count today,
so this is a comment change plus the arithmetic in the walker.

### 1.5 Consequence 2 — even alignment, and the low/high discriminator

`IrAllocReg` gains a rule: **when `AType.Kind = wvkVec`, round the next
free ordinal up to even, allocate two entries, and set
`RegTypes[k] := RegTypes[k+1] := v128`.** `RegisterCount` is likewise
rounded up to even, so every frame `Base` is even by induction from
`Base = 0`, and `Values` is allocated with an explicit 16-byte alignment
guarantee (over-allocate 16 bytes, round the base pointer up, keep the
raw pointer for `FreeMem`) rather than trusting `GetMem`.

Two things fall out for free:

- Every `v128` register is **16-byte aligned**, so Track I may use
  aligned SSE/NEON loads without a fixup. (The interpreter itself must
  still use plain Pascal record assignment or `Move`, never a
  hand-written aligned instruction — AGENTS.md's FreePascal rule and
  portability both say so.)
- The low/high discriminator is derivable with no new field: **register
  `k` is the low half of a `v128` iff `RegTypes[k].Kind = wvkVec` and
  `k` is even.** No `VecHighRegBits`, no new value kind.

Waste is bounded at one slot per vector register plus one per frame.

### 1.6 Consequence 3 — the two-slot ABI at every boundary

This is now part of the engine's calling convention and must be
documented as such (§9 item 8):

- **Wasm→wasm calls.** `AuxU32` argument and result blocks name *slots*,
  so a `v128` argument contributes **two consecutive entries** (`k`,
  `k+1`). `PushWasmFrame`'s existing per-slot copy loop is then correct
  unmodified, because the callee's `v128` parameter also occupies two
  consecutive slots in the same order.
- **Host calls.** `TWasmHostCallback`'s `AParams` / `AResults` are
  positional `TWasmValue` arrays; a `v128` param or result occupies two
  consecutive entries, low half first. `HostCall`'s buffers and loops are
  unchanged. Track F documents this in the embedding API.
- **`TWasmTierInvokeProc`** (`Wasm.Runtime.Store.pas:405`) keeps its
  `PWasmValue` params; the same two-slot rule applies. The differential
  harness for Track I therefore needs no signature change.
- **`WASM_INTERP_MAX_MARSHAL`** counts slots, so a function with 1024
  `v128` params would now exceed it. Leave the cap; the existing
  `'internal: host-call arity exceeds the marshal cap'` guard already
  covers it.

### 1.7 The one store change — `v128` globals

`simd_linking.wast` exports and imports `v128` globals, mutable and
immutable, and `simd_lane.wast:1033-1057` uses `(global $g0 (mut v128) …)`
with `global.get` / `global.set`. `TWasmGlobalInst`
(`Wasm.Runtime.Store.pas:303-306`) holds a single `Value: TWasmValue`.

```pascal
  TWasmGlobalInst = record
    Value: TWasmValue;
    Vec: TWasmV128;        { used iff GlobalType's value type is wvkVec }
    GlobalType: TWasmGlobalType;
  end;
```

16 extra bytes per global instance, and globals are few. The alternative
— making the global cell a two-slot pair — would force every global
accessor to branch on width. A dedicated field, plus dedicated IR ops
(`iroGlobalGetVec` / `iroGlobalSetVec`, §2.4), keeps both paths
branch-free.

### 1.8 `TWasmValue` interop, restated

- `Bits` stays the canonical raw view for every non-vector type, and the
  zero-the-whole-slot rule on narrow writes is unchanged.
- A `v128` is *never* read or written through `TWasmValue` fields. It is
  read and written only through `PWasmV128`, which aliases the two slots.
  `ValueZeroSlots` already zeroes both, which is exactly the `v128`
  default value (`TryDefaultValue`'s "zero for numbers and vectors").
- No `MakeValueV128` is added, because there is no single-slot value to
  make. `Wasm.Runtime.Values` gains `VecAt`, `VecZero`, `VecEquals`,
  and `VecFromBytes` / `VecToBytes` only.

### 1.9 What `Wasm.Wast.Values` holds for a `v128` expected value

A `v128` expectation is **not** a bit pattern: `simd_f32x4_arith.wast:5292`
asserts `(v128.const f32x4 nan:canonical nan:arithmetic 6.0 7.0)` — a
single constant mixing two NaN classes with two exact lanes. So the
comparator must hold **per-lane kinds**. See §6.1 for the record; the
short version is `shape + 16 lane bit patterns + 16 lane kinds`, and the
`(either …)` form is lifted *out* of `TWastVal` into a list wrapper so
the record stays non-recursive.

---

## 2. IR extension

### 2.1 Enum, version, and the naming rule

Append after `iroI31GetU` (`Wasm.Ir.pas:358`). No reserved range —
`ir-spec.md §1.5` already decided this, and the reasons hold: reserving
would require explicit ordinals (killing the DENSE rule that makes the
interpreter's `case` a jump table) and would put dead entries in every
dispatch table.

- **`IR_FORMAT_VERSION` 1 → 2.** Free today: there is no AOT artifact
  cache until Track J, so ADR-0007's artifact-rejection rule has nothing
  to reject.
- The enum comment must record that SIMD sits **after** i31, breaking the
  "grouped in wasm opcode order" convention — `ir-spec.md §1.5` said to
  say so when the track lands.
- Naming: `iro` + the mnemonic with `.`/`_` removed and each segment
  capitalised. `v128.load` → `iroV128Load`; `i8x16.extract_lane_s` →
  `iroI8x16ExtractLaneS`; `i16x8.extadd_pairwise_i8x16_s` →
  `iroI16x8ExtaddPairwiseI8x16S`; `i32x4.relaxed_dot_i8x16_i7x16_add_s` →
  `iroI32x4RelaxedDotI8x16I7x16AddS`.
- Member ordering: **by subopcode**, 0..275, skipping the 20 unassigned.
  Group headers mirror the existing style; the groups are the ones in
  Appendix A.
- After the 256 wasm ops, append the **9 IR-only vector ops** of §2.4.

**Totals: 231 + 256 + 9 = 496.** `Wasm.Ir.Test.pas:99`'s
`Expect<Integer>(Ord(High(TWasmIrOp)) + 1).ToBe(231)` becomes `496`, and
line 140's `Length(IR_OP_INFO) = Ord(High(TWasmIrOp)) + 1` keeps holding.
`{$PACKENUM 2}` still fits.

### 2.2 Where a 16-byte immediate lives

`TWasmIrInstr.Imm` is `Int64` and the record is size-asserted at 24
bytes. Two immediates are 16 bytes wide: `v128.const`'s literal and
`i8x16.shuffle`'s 16 lane indices.

**Decision: reuse `AuxU32`. No new side table.** A 16-byte immediate is
one length-prefixed block of four `UInt32` words holding the vector's
bytes in little-endian order:

```
AuxU32[k]     = 4
AuxU32[k+1..k+4] = the 16 bytes, as four little-endian u32 words
```

`Imm` holds `k`, with `ImmKind: ifkAuxIndex`.

Rejected: a new `AuxV128: array of TWasmV128` table. It would add a
field to **both** `TWasmIrFunction` and `TWasmIrInitExpr`, a fourth
`IrTrim*` call in `TBodyWalker.Run`'s tail (lines 4188-4196), a fourth
`IrAppendAux*` builder, and a new field kind — all to save 4 bytes per
constant. The aux words are contiguous, so reading is a single
`Move(AAux[k+1], V, 16)`, and `v128.const` is not a hot instruction (the
interpreter can hoist nothing either way).

### 2.3 The other immediate shapes

| Shape | Ops | Encoding |
| --- | --- | --- |
| lane index | `extract_lane` ×6, `replace_lane` ×6 | `Imm` = the lane index, `ImmKind: ifkImmValue` |
| 16-byte literal | `v128.const`, `i8x16.shuffle` | `Imm` = aux block index (§2.2) |
| memarg | the 12 whole-vector / packed / splat / zero loads and `v128.store` | mirrors `iroI32Load` exactly: `B` = mem index (`ifkMemIndex`), `Imm` = static offset (`ifkImmValue`) |
| memarg **+** lane | `v128.load8/16/32/64_lane`, `v128.store8/16/32/64_lane` | `Imm` = aux block index to a **4-word vector-memarg block**: `[MemIdx, OffsetLo, OffsetHi, LaneIdx]` |
| third source register | the 10 ternary ops | `Imm` = the register number, new kind `ifkSrcRegImm` |

The vector-memarg block exists because a lane load needs six values
(dest, addr reg, source vector reg, mem index, u64 static offset, lane)
and the record has four fields. `IrPack` cannot help: a static offset on
an i64 memory does not fit `UInt32`.

`ifkSrcRegImm` is the one new `TWasmIrFieldKind` member: *"a register
number carried in `Imm`"*. It makes all ten ternary vector ops
(`v128.bitselect`, four `*.relaxed_laneselect`, four
`f*.relaxed_madd/nmadd`, `i32x4.relaxed_dot_i8x16_i7x16_add_s`) single
instructions instead of aux-block indirections. `Describe` renders it
`r<n>`; any future renumbering pass must handle it, which is exactly why
the kind is declared rather than implied.

### 2.4 The nine IR-only vector ops

Emitted by the validator, corresponding to no wasm opcode. They exist so
the interpreter never has to ask "is this register 8 or 16 bytes wide?"
at run time.

| Op | Replaces | Fields |
| --- | --- | --- |
| `iroMoveVec` | `iroMove` for a `v128` | `Dest` ← `A`, 16 bytes |
| `iroSelectVec` | `iroSelect` for `v128` arms | `Dest`, `A`, `B`, `Imm` = condition reg (`ifkSrcRegImm`) |
| `iroGlobalGetVec` / `iroGlobalSetVec` | the scalar pair for a `v128` global | `A`/`Dest` = global index |
| `iroStructGetVec` / `iroStructSetVec` | for a `v128` field | as the scalar forms, `Imm` = `IrPack(TypeIdx, FieldIdx)` |
| `iroArrayGetVec` / `iroArraySetVec` | for a `v128` element | as the scalar forms |
| `iroArrayFillVec` | `iroArrayFill` with a `v128` value | as the scalar form |

The general rule, so a tenth case needs no new decision:

> Where the interpreter would otherwise have to consult `RegTypes` or a
> runtime layout to learn a value's width, the validator — which knows it
> statically — emits a `*Vec` variant. Where the runtime layout record is
> already in hand (`TWasmGcField.IsVec` during `struct.new`,
> `array.new_fixed`, `array.copy`), the existing op branches on it and no
> new op is added.

`iroMoveVec` is chosen over "emit two `iroMove`s" so that the merge-move
algorithm (`ir-spec.md §4.3`) keeps its one-instruction-per-stack-value
shape and `Describe` stays readable; its cycle-breaking temporary is
allocated with `AllocTemp(MakeVecValueType)`, which allocates a pair.

### 2.5 `IR_OP_INFO` rows

Representative rows, in the existing formatting:

```pascal
    (Mnemonic: 'v128.const'; DestKind: ifkDestReg; AKind: ifkUnused;
      BKind: ifkUnused; ImmKind: ifkAuxIndex),
    (Mnemonic: 'i8x16.shuffle'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkAuxIndex),
    (Mnemonic: 'i8x16.splat'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkUnused),
    (Mnemonic: 'i8x16.extract_lane_s'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkImmValue),
    (Mnemonic: 'i8x16.replace_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkImmValue),
    (Mnemonic: 'i8x16.add'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkUnused),
    (Mnemonic: 'v128.bitselect'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkSrcRegImm),
    (Mnemonic: 'v128.load'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.store'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkMemIndex; ImmKind: ifkImmValue),
    (Mnemonic: 'v128.load8_lane'; DestKind: ifkDestReg; AKind: ifkSrcReg;
      BKind: ifkSrcReg; ImmKind: ifkAuxIndex),
    (Mnemonic: 'v128.store8_lane'; DestKind: ifkSrcReg; AKind: ifkSrcReg;
      BKind: ifkUnused; ImmKind: ifkAuxIndex),
```

Every op's `Mnemonic` is the wasm mnemonic verbatim, so the corpus, the
assembler table, and the disassembler all agree on one spelling.

### 2.6 `Describe` forms

The generic renderer covers most rows automatically. Five special arms
are added to `IrOperands` (`Wasm.Ir.pas:1765-1893`):

```
0000  v128.const             r4 <- v128:000102030405060708090a0b0c0d0e0f
0001  i8x16.shuffle          r6 <- r2, r4 lanes[0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15]
0002  i8x16.extract_lane_s   r7 <- r6 lane=3
0003  i8x16.replace_lane     r8 <- r6, r7 lane=3
0004  v128.bitselect         r9 <- r2, r4 ? r6
0005  v128.load              r10 <- [r3 + 8] mem=0
0006  v128.store             [r3 + 8] <- r10 mem=0
0007  v128.load8_lane        r11 <- [r3 + 8] mem=0 lane=5, r10
0008  v128.store8_lane       [r3 + 8] <- r10 mem=0 lane=5
0009  move.v128              r12 <- r9
```

`v128:` renders the 16 immediate bytes in memory order as lowercase hex,
which is directly comparable to a `(v128.const i8x16 …)` in a test.
`lanes[…]` renders the shuffle mask decimal, matching the text form.
Register names still render `r<N>` naming the **low** slot; a `v128`
register `r6` implicitly owns `r7`, which no instruction ever names. The
`DescribeIrFunction` register-type header shows both as `v128`.

---

## 3. Validation — replacing the staged `$FD` arm

### 3.1 The shape of the replacement

`Wasm.Validator.Body.Prefixed`'s `else` branch (lines 3369-3383 of the
arm quoted at 3820-3893) is deleted and replaced by
`HandleVector(Sub, AOffset)`, table-driven exactly as `HandleNumeric` is:

```pascal
type
  TVecFamily = (
    vfNullary,      { v128.const              — no operands }
    vfShuffle,      { i8x16.shuffle           — 2 x v128 + 16 lane bytes }
    vfUnary,        { v128 -> v128 }
    vfBinary,       { v128, v128 -> v128 }
    vfTernary,      { v128, v128, v128 -> v128 }
    vfTest,         { v128 -> i32 }
    vfShift,        { v128, i32 -> v128 }
    vfSplat,        { <num> -> v128 }
    vfExtract,      { v128 + lane -> <num> }
    vfReplace,      { v128, <num> + lane -> v128 }
    vfLoad,         { addr -> v128, memarg }
    vfStore,        { addr, v128 -> (), memarg }
    vfLoadLane,     { addr, v128 + memarg + lane -> v128 }
    vfStoreLane     { addr, v128 + memarg + lane -> () }
  );

  TVecSig = record
    Family: TVecFamily;
    Scalar: TWasmNumType;   { vfSplat/vfExtract/vfReplace/vfTest operand or result }
    Dim: Byte;              { lane count for lane-index bounds; 0 = n/a }
    MaxAlign: Byte;         { log2(access bytes); meaningful for the memory families }
  end;

const
  VEC_SIG: array[0..275] of TVecSig = ( ... );   { unassigned rows carry vfNullary + a sentinel }
```

The main-loop entry (`Wasm.Validator.Body.pas:4172`) is unchanged;
`Prefixed`'s `$FD` case becomes:

```pascal
    case Sub of
      0..153, 155..161, 163, 164, 167..174, 177, 181..186, 188..193,
      195, 196, 199..206, 209, 213..225, 227..237, 239..275:
        HandleVector(Sub, AOffset);
    else
      DecErr(Format('unknown $FD subopcode %u at offset %u', [Sub, AOffset]));
    end;
```

**The malformed/invalid boundary does not move.** An unassigned
subopcode stays a *decode* error, exactly as it is today — that split is
what the conformance suite asserts, and Track G must not disturb it.

### 3.2 Typing rules, per family

All `v128` operands and results use `MakeVecValueType`, popped with the
existing `PopValExpect` so a mismatch produces the corpus's
`type mismatch` (600 occurrences across 53 `simd_*.wast` files) with no
new message.

| Family | Rule | Anchor |
| --- | --- | --- |
| `v128.const` | `[] → [v128]` | `valid-vconst` |
| `i8x16.shuffle` | `[v128 v128] → [v128]`, plus the lane bound in §3.3 | `valid-vshuffle` |
| `i8x16.swizzle`, relaxed swizzle | `[v128 v128] → [v128]` | `valid-vswizzlop` |
| splat | `[t] → [v128]`, `t = i32` for i8x16/i16x8/i32x4, `i64`/`f32`/`f64` otherwise | `valid-vsplat` |
| `extract_lane` | `[v128] → [t]` | `valid-vextract_lane` |
| `replace_lane` | `[v128 t] → [v128]` | `valid-vreplace_lane` |
| unary (`abs`,`neg`,`popcnt`,`sqrt`,`ceil`…, extend, convert, trunc_sat, demote/promote) | `[v128] → [v128]` | `valid-vunop`, `valid-vcvtop`, `valid-vextunop` |
| binary (arith, cmp, min/max, narrow, extmul, dot) | `[v128 v128] → [v128]` | `valid-vbinop`, `valid-vrelop`, `valid-vextbinop` |
| ternary (`bitselect`, laneselect, madd/nmadd, relaxed dot-add) | `[v128 v128 v128] → [v128]` | `valid-vvternop`, `valid-vternop`, `valid-vextternop` |
| bitwise (`not`,`and`,`andnot`,`or`,`xor`) | `[v128 (v128)] → [v128]` | `valid-vvunop`, `valid-vvbinop` |
| `v128.any_true` | `[v128] → [i32]` | `valid-vvtestop` |
| `*.all_true` | `[v128] → [i32]` | `valid-vtestop` |
| `*.bitmask` | `[v128] → [i32]` | `valid-vbitmask` |
| shifts | `[v128 i32] → [v128]` | `valid-vshiftop` |
| whole/packed/splat/zero loads | `[at] → [v128]` | `valid-vload`, `valid-vload-pack`, `valid-vload-splat`, `valid-vload-zero` |
| `v128.store` | `[at v128] → []` | `valid-vstore` |
| `load*_lane` | `[at v128] → [v128]` | `valid-vload_lane` |
| `store*_lane` | `[at v128] → []` | `valid-vstore_lane` |

`at` is the memory's address type (`i32` or `i64`) — reuse
`AddrValType(Mem.Limits.AddrType)` exactly as `HandleLoadStore` does, so
memory64 works from day one.

**Relaxed ops type identically to their non-relaxed counterparts.** They
are ordinary `vbinop`/`vternop`/`vcvtop`/`vswizzlop` forms with
implementation-defined *results*, never implementation-defined *types*.

### 3.3 Lane-index bounds — a validation rule

New constant, next to `MSG_ALIGNMENT_TOO_LARGE` in
`Wasm.Validator.Types.pas`:

```pascal
  MSG_INVALID_LANE_INDEX = 'invalid lane index';
```

**Corpus-confirmed, 48 occurrences across 9 files, always under
`assert_invalid`** — never `assert_malformed`. That distinction is
load-bearing: a lane index of `255` parses fine (it is one byte) and is
rejected by *validation*; a lane index of `256` fails in the *assembler*
(§5.4).

| Instruction | Bound | Corpus |
| --- | --- | --- |
| `i8x16.extract_lane_*` / `replace_lane` | `< 16` | `simd_lane.wast` |
| `i16x8.*_lane` | `< 8` | `simd_lane.wast` |
| `i32x4.*_lane`, `f32x4.*_lane` | `< 4` | `(i32x4.extract_lane 4 …)` → invalid |
| `i64x2.*_lane`, `f64x2.*_lane` | `< 2` | `(i64x2.extract_lane 2 …)` → invalid |
| `i8x16.shuffle`, all 16 indices | `< 32` | `simd_lane.wast:514-607`; index 255 → invalid |
| `v128.load8_lane` / `store8_lane` | `< 16` | `simd_load8_lane.wast` |
| `load16_lane` / `store16_lane` | `< 8` | `(v128.store16_lane 8 …)` → invalid |
| `load32_lane` / `store32_lane` | `< 4` | |
| `load64_lane` / `store64_lane` | `< 2` | |

`ValErr(MSG_INVALID_LANE_INDEX, Format('lane %u is not below %u at offset %u', …))`
— the harness prefix-matches, so the detail is free.

### 3.4 Alignment for the memory family

`ReadMemarg` takes a single-byte opcode and indexes `MEM_SIG[AOp]` for
`MaxAlign`; a `$FD` load has no row there. **Add an overload taking the
maximum explicitly** and have the existing one delegate:

```pascal
procedure ReadMemargMax(const AMaxAlign: Byte; const AOpName: string;
  out AMemIdx: UInt32; out AOffset: UInt64; const AOpOffset: NativeUInt);
```

The natural alignments, each confirmed against `simd_align.wast` (the
`align=` value that upstream marks `assert_invalid` is one power of two
*above* natural):

| Instruction | Access bytes | `MaxAlign` (log2) | Confirming corpus case |
| --- | ---: | ---: | --- |
| `v128.load`, `v128.store` | 16 | 4 | `align=32` → invalid |
| `v128.load8x8_s/u`, `load16x4_s/u`, `load32x2_s/u` | 8 | 3 | `align=16` → invalid |
| `v128.load8_splat` | 1 | 0 | `align=2` → invalid |
| `v128.load16_splat` | 2 | 1 | `align=4` → invalid |
| `v128.load32_splat` | 4 | 2 | `align=8` → invalid |
| `v128.load64_splat` | 8 | 3 | `align=16` → invalid |
| `v128.load32_zero` | 4 | 2 | |
| `v128.load64_zero` | 8 | 3 | |
| `v128.load8_lane` / `store8_lane` | 1 | 0 | `align=2` → `alignment must not be larger than natural` |
| `load16_lane` / `store16_lane` | 2 | 1 | |
| `load32_lane` / `store32_lane` | 4 | 2 | |
| `load64_lane` / `store64_lane` | 8 | 3 | |

Both alignment messages are already shipped and unchanged:
`MSG_ALIGNMENT_TOO_LARGE = 'alignment must not be larger than natural'`
(20 corpus occurrences in the SIMD files) and the assembler's
`'alignment must be a power of two'` (22). The `align=0` / `align=7`
cases are *malformed* (assembler) while `align=32` is *invalid*
(validator) — the corpus enforces that split and the existing code
already implements it.

The `offset out of range` check (`MSG_OFFSET_OUT_OF_RANGE`, static offset
> `$FFFFFFFF` on an i32 memory) applies unchanged; `simd_address.wast`
has two such cases.

### 3.5 Constant expressions

`v128.const` **is** a constant instruction (`valid-vconst`;
`Instr_const/vconst`). `Wasm.Validator.Const.pas:951-964`'s
`OP_PREFIX_VEC` arm is rewritten:

- `$FD 12` → decode the 16 immediate bytes, append the aux block, emit
  `iroV128Const` into the `TWasmIrInitExpr`, push `v128`.
- any other **assigned** `$FD` subopcode → the walker's existing
  non-constant message (the same one `i32.add` in a const expression
  gets). Not a SIMD-specific message.
- unassigned → the decode error, as everywhere.

`Wasm.Runtime.Instantiate`'s evaluator (`:103-106`, the `else` branch
whose comment already says "Track G appends v128.const") gains the
`iroV128Const` arm, and `TWasmIrInitExpr.ResultReg` may now name a
register pair; the global-initialisation path writes
`Globals[a].Vec` when the global's type is `wvkVec`.

### 3.6 The staged-message plumbing, removed

- `Wasm.Validator.Types.MSG_SIMD_NOT_IMPLEMENTED` — **deleted**.
- `Wasm.Runtime.Gc.MSG_GC_VEC_STORAGE_STAGED` (its deliberate duplicate)
  — **deleted** with §7.
- `Wasm.Validator.IsStagedFeatureMessage` (declared `:109-113`,
  implemented `:180-187`) — **deleted entirely**. With SIMD unstaged its
  only producer is gone; the sole remaining staged message
  (`'exception handling is not implemented'`) is raised in
  `Wasm.Interp.StageException`, not in the validator, and
  `Wasm.Wast.Runner.IsStagedMessage` (`:308-317`) already matches it with
  an inline literal. That function keeps only its EH clause until Track H
  deletes it too, and every `IsStagedFeatureMessage` call site in the
  runner (`:953, 1179, 1250, 1318, 1388, 1425`) collapses to
  `IsStagedMessage`.
- Test updates: `Wasm.Validator.Body.Test.pas:1098`,
  `Wasm.Validator.Const.Test.pas:673-682,739`,
  `Wasm.Fixtures.Test.pas:309-310` (the `simd.wasm` fixture that "is the
  first thing that fails when the work starts" — it now asserts a
  successful validation and an IR shape),
  `Wasm.Runtime.Gc.Test.pas:1470` (`TestVectorStorageIsStagedNotAnInternalBug`
  becomes `TestVectorStorageRoundTrips`).

---

## 4. Interpreter execution

### 4.1 Unit split

**New unit `Wasm.Interp.Vector`**, the exact analogue of
`Wasm.Interp.Numeric`: pure leaf procedures, no store, no IR, no frames.
It owns all 256 semantics.

```pascal
{ operands and destination are the 16-byte views onto register pairs;
  Dest never aliases a source (the IR allocates a fresh temporary), but
  leaves read operands into locals before writing D where it is free. }
procedure V8x16Add(const A, B, D: PWasmV128);
procedure V4x32Splat(const AValue: UInt32; const D: PWasmV128);
function  V16x8AllTrue(const A: PWasmV128): UInt32;
procedure V4x32FMin(const A, B, D: PWasmV128);
```

Naming: `V` + dimension `x` lane-width + operation, so `V8x16` is
`i8x16`/8-bit-lane-16-lanes, `V4x32F` the f32x4 family. Leaves that
return a scalar return `UInt32` (the i32 result of a test or bitmask),
matching `Wasm.Interp.Numeric`'s raw-bits contract.

**Dispatch stays in `Wasm.Interp.Run`'s flat `case`**, one arm per op,
exactly as the numeric family does. Rationale: a single jump table over
the dense enum, no call-per-instruction on top of the leaf call, and no
new parameter-passing convention. `Wasm.Interp.pas` grows by roughly 600
lines to ~2,600 — smaller than `Wasm.Validator.Body.pas` today.

`Run`'s no-managed-locals rule (TRAP-1) is preserved: `TWasmV128` has no
managed fields, so a `TWasmV128` local in `Run` is fine, and every string
still lives in a leaf.

**No `StageSimd`.** Once the validator emits vector ops, a missing
dispatch arm reaches `UnhandledOp` and reports
`internal: unhandled IR op v128.add` — an engine bug, which is exactly
what it would be. Wave G5 lands all 256 arms together; there is no
half-landed state to stage.

### 4.2 Integer lane families

Anchors: `exec-vunop`, `exec-vbinop`, `exec-vrelop`, `exec-vshiftop`,
`exec-vtestop`, `exec-vbitmask`, `exec-vnarrow`, `exec-vextunop`,
`exec-vextbinop`.

- **Wrapping arithmetic** (`add`, `sub`, `mul`, `neg`): modular in the
  lane width. Compute in the unsigned lane type and let FPC wrap; do not
  promote.
- **Saturating** (`add_sat_s/u`, `sub_sat_s/u`): compute in the next
  wider signed/unsigned type and clamp to the lane range.
- **`abs`**: `abs(INT_MIN)` wraps to `INT_MIN` (two's complement, no
  trap).
- **`min_s/u`, `max_s/u`**: plain comparisons in the right signedness.
- **`avgr_u`**: `(a + b + 1) >> 1` computed in a wider unsigned type — the
  `+1` rounds up and the widening prevents overflow.
- **Shifts** (`shl`, `shr_s`, `shr_u`): the i32 shift operand is taken
  **modulo the lane width** (`k mod 8/16/32/64`), per `exec-vshiftop`.
  `simd_bit_shift.wast` (211 assertions) tests shift counts well beyond
  the lane width.
- **`i16x8.q15mulr_sat_s`**: `sat_s16((a*b + 0x4000) >> 15)`; the only
  saturating case is `a = b = -32768`, which yields `32767`.
- **`i32x4.dot_i16x8_s`** (`exec-vextbinop`): pairwise
  `a[2i]*b[2i] + a[2i+1]*b[2i+1]` in 32-bit. No saturation — the products
  cannot overflow i32.
- **`extadd_pairwise_*`** (`exec-vextunop`): adjacent lanes widened and
  summed.
- **`extmul_low/high_*`**: the low or high half of the source lanes,
  widened, multiplied into the wider lane.
- **`extend_low/high_*`**: sign- or zero-extend half the lanes.
- **`narrow_*_s/u`** (`exec-vnarrow`): concatenate both operands' lanes,
  **saturating** into the narrower lane; `_u` saturates to the *unsigned*
  range but the source is read as signed, so negatives clamp to 0.
- **`popcnt`**: per byte lane.
- **`bitmask`** (`exec-vbitmask`): the sign bit of each lane, lane 0 in
  bit 0, zero-extended into an i32.
- **`all_true`** (`exec-vtestop`): 1 iff every lane is non-zero.
- **`any_true`** (`exec-vvtestop`): 1 iff *any bit* of the whole vector is
  set — note it is a `vvtestop` over the 128 bits, not a lane test.

### 4.3 Float lane families — the NaN discipline

`exec-vunop` / `exec-vbinop` apply the scalar operator lane by lane, so
`aux-nans` applies **per lane**, and `interp-spec.md §3.2`'s
reference-fixing decision carries over verbatim:

> **After each payload-affecting float lane operation, if the lane's
> result is NaN, store the positive canonical pattern** — `$7FC00000`
> (f32) or `$7FF8000000000000` (f64).

That satisfies both corpus classes: `nan:canonical` requires exactly this
pattern, and `nan:arithmetic` requires only payload-MSB set. The corpus
uses **both, per lane, mixed within one constant** — `simd_f32x4_arith.wast:5292`
is `(v128.const f32x4 nan:canonical nan:arithmetic 6.0 7.0)`, and
`simd_f64x2_arith.wast:5298` puts the NaN in lane 1 with a number in lane
0. There are 2,378 `nan:canonical` and 2,426 `nan:arithmetic` tokens
across eight files.

**Exempt from canonicalisation** (bit-preserving, must not be touched):

- `f32x4.abs` / `f64x2.abs` — clear each lane's sign bit.
- `f32x4.neg` / `f64x2.neg` — flip each lane's sign bit.
- every `v128.*` bitwise op, `bitselect`, `laneselect`, `splat`,
  `extract_lane`, `replace_lane`, `shuffle`, `swizzle`, and every load
  and store.
- **`pmin` / `pmax`** — see below. This is the subtle one.

#### `min`/`max` versus `pmin`/`pmax`

`f32x4.min` is wasm `fmin`, which routes a NaN result through `nans{…}`
and therefore canonicalises. `f32x4.pmin` is defined as the *selection*
`fpmin(z1,z2) = if z2 < z1 then z2 else z1` — no `nans{…}` — so it
returns one operand **bit for bit**, including its payload and sign, and
when either operand is NaN the comparison is false so the result is `z1`.

The corpus states this unambiguously:

```
simd_f32x4.wast:940      (invoke "f32x4.min"  (f32x4 nan …) (f32x4 0 …))
                         → (v128.const f32x4 nan:canonical …)      ; CLASS match

simd_f32x4_pmin_pmax.wast:4935
                         (invoke "f32x4.pmin" (f32x4 nan …) (f32x4 nan:0x200000 …))
                         → (v128.const f32x4 nan …)                ; EXACT bits — z1

simd_f32x4_pmin_pmax.wast:5067
                         (invoke "f32x4.pmin" (f32x4 -nan …) (f32x4 -nan …))
                         → (v128.const f32x4 -nan …)               ; sign preserved
```

`simd_f32x4_pmin_pmax.wast` contains **528 `nan:0x…` payload literals and
zero `nan:canonical` tokens** across 3,872 assertions. Canonicalising
`pmin` would fail thousands of them. Implement `pmin`/`pmax` as a raw
`if B < A then D := B else D := A` per lane, on the bit patterns, with
the comparison done in the float domain.

`min`/`max` also carry the ±0 rule: `min(+0,-0) = -0`, `max(+0,-0) = +0`.
Compare bit patterns for the zero tie, never `<`.

#### The rest

- `add`, `sub`, `mul`, `div`, `sqrt`: IEEE, round-to-nearest-ties-even,
  then the canonicalisation rule. Float `div` never traps.
- `ceil`, `floor`, `trunc`, `nearest`: `nearest` is `roundTiesToEven`,
  not FPC `Round` and not C `round`. Preserve the sign of zero.
  `simd_f32x4_rounding.wast` / `simd_f64x2_rounding.wast` are the oracle.
- `f32x4.demote_f64x2_zero`: lanes 0-1 from the f64x2 rounded to f32,
  lanes 2-3 zero. `f64x2.promote_low_f32x4`: lanes 0-1 widened exactly.
- `f32x4.convert_i32x4_s/u`, `f64x2.convert_low_i32x4_s/u`: exact where
  representable, ties-to-even otherwise. Never trap.
- `i32x4.trunc_sat_f32x4_s/u`, `i32x4.trunc_sat_f64x2_s/u_zero`
  (`exec-vcvtop`): **never trap**. NaN → 0; below-min → min; above-max →
  max. The `_zero` forms fill lanes 2-3 with zero.

Call `MaskFpuExceptions` once per thread as the scalar path already does
(`Wasm.Interp.pas:1822`); nothing new is needed.

### 4.4 Shuffle, swizzle, splat, lanes

- **`i8x16.shuffle`** (`exec-vshuffle`): result byte `i` is
  `concat(a,b)[mask[i]]`, `mask[i] < 32` guaranteed by validation.
- **`i8x16.swizzle`** (`exec-vswizzlop`): result byte `i` is `a[b[i]]`
  when `b[i] < 16`, **`0` otherwise**. `b` is read as unsigned bytes;
  any value ≥ 16 (which includes every byte whose signed value is
  negative) yields zero.
- **splat**: replicate the scalar across all lanes; the i32 operand is
  truncated to the lane width for i8x16/i16x8.
- **`extract_lane_s/u`**: read the lane, sign- or zero-extend to i32 (the
  i32x4/i64x2/f32x4/f64x2 forms have no `_s`/`_u` suffix and are exact).
- **`replace_lane`**: copy the vector, overwrite one lane; the i32 value
  is truncated for the narrow shapes.

### 4.5 The load/store family — the same chokepoint

All 22 go through `TWasmStore.MemAddressAt`, which already documents
`ASize is 1/2/4/8/16` and whose `WASM_MAX_ACCESS_WIDTH = 16` was sized for
exactly this. **No new memory path, no bypass** — this is AGENTS.md's
named top failure mode.

`Wasm.Interp`'s `MemLoad` returns `UInt64` and cannot carry 16 bytes. Add
two leaves beside it, in the same file, with the same
no-managed-locals discipline:

```pascal
procedure MemLoadV128(const AStore: TWasmStore; const AMemAddr: TWasmMemAddr;
  const AIndex, AOffset: UInt64; const ASize: NativeUInt; const ADest: PWasmV128);
procedure MemStoreV128(const AStore: TWasmStore; const AMemAddr: TWasmMemAddr;
  const AIndex, AOffset: UInt64; const ASize: NativeUInt; const ASrc: PWasmV128);
```

`ASize` is the *access* size, which is 16 only for `v128.load`/`store`;
it is 8 for the packed and 64-bit splat/zero forms, 1/2/4/8 for the lane
forms. The bounds check is one range check for the whole access, so the
trap (`out of bounds memory access`) fires before any byte moves.

Semantics after the load:

- `v128.load` (`exec-vload`): 16 bytes verbatim.
- `v128.load8x8_s/u`, `load16x4_s/u`, `load32x2_s/u`
  (`exec-vload-pack`): load 8 bytes, extend each of the 8/4/2 packed
  lanes into the wider lane.
- `v128.loadN_splat` (`exec-vload-splat`): load N/8 bytes, replicate.
- `v128.loadN_zero` (`exec-vload-zero`): load N/8 bytes into lane 0, zero
  the rest of the vector.
- `v128.loadN_lane` (`exec-vload_lane`): copy the source vector, then
  overwrite one lane from memory.
- `v128.storeN_lane` (`exec-vstore_lane`): write one lane to memory.

`simd_load_splat.wast` (32 traps) and `simd_load_extend.wast` /
`simd_load_zero.wast` (12 + 4) are the out-of-bounds oracle; the 54
`assert_trap` cases in the SIMD files are all `out of bounds memory
access`.

### 4.6 Relaxed SIMD — our fixed, deterministic behaviour

`relaxed-ops` says the result of a relaxed operator is
implementation-dependent, controlled by a **global parameter `R` that is
constant for the whole execution of a program**, and that

> In the deterministic profile, every parameter is prescribed to be 0.

and `profile-deterministic` confirms

> All relaxed vector instructions have a fixed behaviour that does not
> depend on the implementation.

**Decision: wasmlight instantiates every relaxed parameter to `R = 0`,
i.e. it implements the deterministic profile, permanently and for every
tier.** The spec explicitly sanctions this ("Implementations are expected
to either choose the behaviour that is the most efficient on the
underlying hardware, or the behaviour of the deterministic profile"), and
for a runtime whose central constraint is that tiers be observationally
identical, the choice makes itself: a hardware-shaped choice would have
to be re-implemented identically in the JIT and the AOT compiler on two
architectures.

At `R = 0` every relaxed operator reduces to its non-relaxed counterpart.
The complete table, one row per parameter, each quoting the pinned clause:

| Parameter | Ops | `R = 0` behaviour | Anchor |
| --- | --- | --- | --- |
| `R_swizzle` | `i8x16.relaxed_swizzle` | regular `ivswizzle` — index ≥ 16 (signed) yields **0** | `op-ivrelaxed_swizzle` |
| `R_trunc_s` | `i32x4.relaxed_trunc_f32x4_s`, `…_f64x2_s_zero` | regular `trunc_sat_s` | `op-relaxed_trunc_s` |
| `R_trunc_u` | `i32x4.relaxed_trunc_f32x4_u`, `…_f64x2_u_zero` | regular `trunc_sat_u` | `op-relaxed_trunc` |
| `R_fmadd` | `f32x4/f64x2.relaxed_madd` | **unfused**: `fadd(fmul(a,b), c)` — two roundings | `op-frelaxed_madd` |
| `R_fmadd` | `f32x4/f64x2.relaxed_nmadd` | unfused `fadd(fmul(-a,b), c)` | `op-frelaxed_nmadd` |
| `R_laneselect` | `i8x16/i16x8/i32x4/i64x2.relaxed_laneselect` | regular `ibitselect` — the mask is used bit-wise, **not** high-bit-expanded | `op-irelaxed_laneselect` |
| `R_fmin` | `f32x4/f64x2.relaxed_min` | regular `fmin` (NaN → canonical NaN, `min(+0,-0) = -0`) | `op-frelaxed_min` |
| `R_fmax` | `f32x4/f64x2.relaxed_max` | regular `fmax` | `op-frelaxed_max` |
| `R_iq15mulr` | `i16x8.relaxed_q15mulr_s` | regular `q15mulr_sat_s` — `-32768 × -32768 → 32767` | `op-irelaxed_q15mulr_s` |
| `R_idot` | `i16x8.relaxed_dot_i8x16_i7x16_s`, `i32x4.relaxed_dot_i8x16_i7x16_add_s` | regular **signed** dot product | `op-irelaxed_dot`, `op-vextbinop` |

The implementation consequence is that each relaxed op's leaf is a
one-line delegation to the non-relaxed leaf — 20 ops, near-zero cost.
The corpus's 32 `(either …)` results always list the deterministic
alternative, so all 69 relaxed `assert_return`s pass; the 16
`*_cmp` exports (which apply the same relaxed op twice and compare) pass
because our behaviour is a pure function, which the "fixed parameter"
rule requires of any conformant implementation anyway.

Note `i32x4_relaxed_trunc.wast` is a bare module with **zero
assertions** — the four `relaxed_trunc` ops have no corpus oracle. They
get unit tests in `Wasm.Interp.Vector.Test`.

---

## 5. Assembler — Wave 7

### 5.1 `Wasm.Wat.Opcodes` structural changes

Two are mandatory before a single row can be added:

```pascal
  TWasmOpcodeInfo = record
    Mnemonic: string;
    HasPrefix: Boolean;
    Prefix: Byte;
    Opcode: UInt32;          { was Byte — $FD subopcodes reach 275 }
    Shape: TWasmImmShape;
    NaturalAlignLog2: Byte;
  end;

const
  OPCODE_PREFIX_FD = $FD;    { the vector space }
```

`Opcode` is already written as a u32 LEB after the prefix byte for
`$FB`/`$FC`, so the encoder needs no change once the field is wide
enough.

Four new `TWasmImmShape` members:

```pascal
    wisV128Const,     { a shape keyword then N lane literals }
    wisShuffle,       { 16 lane indices }
    wisLane,          { one laneidx byte }
    wisMemArgLane     { a memarg then one laneidx byte }
```

A new `BuildVector` procedure adds ~256 rows and is appended to
`BuildTable`'s call list, replacing the GAP comment at `:475-477`. The
existing `AddMem` helper covers the 12 plain memarg loads/stores with the
§3.4 alignments; `wisMemArgLane` rows carry the same
`NaturalAlignLog2`, so `EmitMemArg` is reusable **verbatim**.

`Wasm.Wat.Opcodes.Test`'s no-duplicate and count assertions grow by 256.

### 5.2 `v128.const`

Grammar: `v128.const <shape> <lane>…` where shape ∈ `i8x16 i16x8 i32x4
i64x2 f32x4 f64x2` with 16/8/4/2/4/2 literals. All six shapes appear in
the corpus (f64x2 25,833 times, f32x4 25,702, i32x4 6,670, i16x8 4,252,
i64x2 4,099, i8x16 3,731).

- Integer lanes: `ParseIntLiteral(tok, 8/16/32/64)`. Hex, decimal,
  negative, and `_` digit separators are all in the corpus
  (`-0x8000_0000`, `-2_147_483_648`).
- Float lanes: `ParseF32` / `ParseF64`. Decimal, hex-float `0x1.…p±N`,
  `inf`, `-inf`, bare `nan`, `-nan`, `nan:0x…` payloads, `+0.0`/`-0.0`.
  `nan:canonical` / `nan:arithmetic` in a *const* must raise
  `unexpected token`, which `ParseF32` already does — this is exactly
  the confusion `wat-assembler.md §7` warns about, and the corpus has 78
  `unexpected token` cases in `simd_const.wast` and `simd_lane.wast`.
- Emission: 16 raw bytes, little-endian per lane, after the `$FD 12`
  opcode.

Errors, all corpus-exact:

| Condition | Message | Count | New home |
| --- | --- | ---: | --- |
| too few or too many lane literals | `wrong number of lane literals` | 8 | `Wasm.Wat.Assembler` |
| a lane literal outside its width | `constant out of range` | 25 | `Wasm.Wat.Numbers` (existing) |
| a malformed literal (`0x`, `0xg`) | `unknown operator` | — | existing |
| `nan:canonical` in a const | `unexpected token` | — | existing |

Note the pairing carefully: **`v128.const` lane literals raise the bare
`constant out of range`** for every shape, including `i8x16 256`
(`simd_const.wast` is the only file with that expectation, 25 times, and
its cases span i8x16 / i16x8 / i32x4 / f32x4 / f64x2). The width-prefixed
spelling belongs to lane *indices*, not lane *literals* — see §5.4.

### 5.3 `i8x16.shuffle`

Sixteen bare lane indices immediately after the mnemonic, before the two
operands:

```
(i8x16.shuffle  0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 (local.get 0) (local.get 1))
(i8x16.shuffle 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 (local.get 0) (local.get 1))
```

- Each index parses with `ParseI8`.
- Fewer or more than 16 → `wrong number of lane indices` (5 corpus
  cases, both 15 and 17 indices).
- An index that does not fit i8 (`256`) → `i8 constant out of range`
  (§5.4).
- An index that fits i8 but is ≥ 32 (`255`) → **assembles**, and
  validation rejects it with `invalid lane index`.
- `-1`, `15.0`, `inf` → `unexpected token` (the lexer's classification,
  unchanged).

`i8x16.swizzle` takes no immediates.

### 5.4 Lane indices and the width-prefixed message

`Wasm.Wat.Numbers` gains one constant and wires it into the two
already-present, currently-unused wrappers:

```pascal
  MSG_I8_CONSTANT_OUT_OF_RANGE = 'i8 constant out of range';
```

**`ParseI8` raises the width-prefixed spelling; `ParseIntLiteral(tok, 8)`
keeps the bare one.** That reads inconsistent, and it is — but it is what
the corpus demands, and the corpus is the authority. The evidence is
clean: `i8 constant out of range` occurs 15 times and **only in
`simd_lane.wast`**, always on a lane-index position:

```
(i8x16.extract_lane_s 256 …)
(i8x16.extract_lane_u 256 …)
(i8x16.replace_lane 256 …)
(i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 256 …)
```

while `constant out of range` occurs 25 times and **only in
`simd_const.wast`**, always on a `v128.const` lane literal. Because the
harness matches by prefix and `i8 constant out of range` does **not**
have `constant out of range` as a prefix, the two spellings cannot be
merged. So: lane indices (`wisLane`, `wisShuffle`, `wisMemArgLane`) go
through `ParseI8`; `v128.const` lanes go through `ParseIntLiteral`.

`ParseI16` gets the analogous `MSG_I16_CONSTANT_OUT_OF_RANGE` for
symmetry, marked `UNCONFIRMED` — no corpus case reaches it.

### 5.5 `wisMemArgLane` and the memidx/lane ambiguity

Grammar, from `simd_memory-multi.wast` (a file that exists precisely to
"test syntax for load/store_lane immediates"):

```
(v128.load8_lane 1 (i32.const 0) (local.get $v))                  ; lane 1, no memidx
(v128.load8_lane 1 1 (i32.const 0) (local.get $v))                ; memidx 1, lane 1
(v128.load8_lane 1 offset=0 align=1 1 (i32.const 0) (local.get $v))
(v128.load8_lane $m offset=0 align=1 1 (i32.const 0) (local.get $v))
(v128.store8_lane offset=0 align=1 1 (i32.const 0) (local.get $v))
```

so the immediate order is `memidx? offset=? align=? laneidx`, with the
lane index **last**, after the memarg. `EmitMemArg` currently consumes a
leading index token as the memidx unconditionally
(`if CurIsIndexToken then …`), which would swallow the lane index in the
first form.

**Resolution rule:** a leading `$id` is always the memidx; a leading
*numeric* token is the memidx **iff** the next token is another numeric
token or an `offset=` / `align=` keyword. This needs **one token of
lookahead**, which the assembler does not have today — it carries `Cur`
and `Advance` only. Add either a `Peek` on `Wasm.Wat.Lexer` or a
save/restore of the token cursor in the assembler; the peek is cleaner
and is the only new capability Wave 7 needs.

Emission is then `EmitMemArg(AOut, AInfo)` followed by one raw lane byte.
`AlignFieldLog2` is unchanged and keeps raising
`alignment must be a power of two` for `align=0` / `align=7` (22 corpus
cases in `simd_align.wast`); `align` larger than natural is passed
through to the validator, as it already is for scalar memory ops.

### 5.6 What un-stages in the assembler

`Wasm.Wat.Assembler.pas:29-31`'s "the ONE thing not encoded" header note
is deleted. `EmitImmediatesBody`'s `else RaiseUnknownOperator` no longer
catches vector mnemonics, because they now have rows.

---

## 6. Runner and comparator

### 6.1 The expected-value record

`TWastVal` gains a vector payload and per-lane kinds. `Bits: UInt64`
cannot hold 128 bits, and a single `Kind` cannot express
`(v128.const f32x4 nan:canonical nan:arithmetic 6.0 7.0)`.

```pascal
type
  TWastVecShape = (wvsI8x16, wvsI16x8, wvsI32x4, wvsI64x2, wvsF32x4, wvsF64x2);

  { Per-lane matcher class. Only the float shapes ever use the NaN kinds. }
  TWastLaneKind = (wlkExact, wlkNanCanonical, wlkNanArithmetic);

  TWastVal = record
    Kind: TWastValKind;
    Width: TWastValWidth;
    Bits: UInt64;
    Id: UInt32;
    HasId: Boolean;
    { wvcV128 only }
    VecShape: TWastVecShape;
    VecLanes: array[0..15] of UInt64;        { each lane's bits, low-aligned }
    VecLaneKinds: array[0..15] of TWastLaneKind;
  end;
```

`wvcEither` is lifted **out** of `TWastVal` — a record cannot contain a
dynamic array of itself. Every expected result becomes a list:

```pascal
  TWastExpected = record
    Alts: array of TWastVal;   { length 1 for a normal result }
  end;

function WastParseExpected(const ANode: TWastNode): TWastExpected;
```

`(either A B …)` parses into `Alts` of length 2..4; everything else
parses into `Alts` of length 1. `TWastValWidth` gains no `wvw128`
member — `VecShape` carries that information.

### 6.2 Matching

```pascal
function WastExpectedMatches(const AExpected: TWastExpected;
  const AActual: PWasmValue; const AActualIsVec: Boolean;
  const AExpectedRef: TWasmRef): Boolean;
```

- **Any-alternative rule:** true iff **any** element of `Alts` matches.
  That is the entire `(either …)` implementation — 32 corpus occurrences
  across the six relaxed files, always in `assert_return` result
  position, never nested, never in argument position.
- **`wvcV128`:** assemble the actual from its two slots into a
  `TWasmV128`, then compare lane by lane at the shape's width:
  - `wlkExact` → bit equality at the lane width.
  - `wlkNanCanonical` → `IsF32Canonical` / `IsF64Canonical` on the lane
    bits (the existing predicates, sign-insensitive).
  - `wlkNanArithmetic` → `IsF32Arithmetic` / `IsF64Arithmetic`.
- `WastValMatches`'s `else Result := False` arm is no longer reachable
  for `wvcV128`; keep it as the defensive default.

### 6.3 Slot-aware marshaling

Because a `v128` occupies two `TWasmValue` slots (§1.6), both
`MarshalArgs` and `RunAssertReturn` must walk **by declared type**, not
by index:

- `MarshalArgs` sizes `AParams` by the callee's total *slot* count and
  advances the slot cursor by 1 or 2 per parsed argument, choosing on the
  parsed value's kind (`wvcV128` → 2). `v128.const` appears in argument
  position 23,220 times, so this is the common path, not an edge.
- `RunAssertReturn` walks the invoked function's result types alongside
  `Expecteds`; a `v128` result consumes two slots of
  `TWastActionResult.Values`. The arity check becomes "expected count vs
  *declared result count*", not vs slot count.
- `RenderActual` renders a vector actual as
  `(v128.const <expected shape> <lane> …)` so a failure diff is
  readable in the same notation as the script.

### 6.4 What un-stages in the runner

Deleted outright:

- `Wasm.Wast.Values.WastValIsStaged` (`:715-718`) and every caller.
- `Wasm.Wast.Runner.IsStagedSimdText` (`:420-443`) with its `VEC` prefix
  array — dead the moment `Wasm.Wat.Opcodes` has vector rows.
- `TWatAssembleStatus.wasStaged` and the whole `ABlocked` propagation
  (`:620, 640-650, 1101, 1120, 1309-1310`).
- The `'SIMD argument'` (`:848, 876`) and `'SIMD result'`
  (`:1524-1525, 1541`) staging paths.
- `IsStagedMessage` keeps only its exception-handling clause; the
  `IsStagedFeatureMessage` call is removed with §3.6.

`TWastStatus.wrsStaged` survives — Track H still needs it — but its SIMD
population drops to zero.

`Wasm.Wast.Runner.Test.pas` has 30 SIMD-related staging assertions that
become correctness assertions.

---

## 7. GC — `v128` struct and array storage

The layout side is already correct: `StorageWidth` returns 16 for
`wvkVec` (`Wasm.Runtime.Gc.pas:849`) and `TWasmGcField.IsVec` exists
(`:179`). Only the accessors stage out, and only because they are typed
in terms of the 8-byte `TWasmValue`.

Add, beside `ReadField` / `WriteField` (`:1381-1421`):

```pascal
procedure ReadFieldV128(const ABase: PByte; const AField: TWasmGcField;
  const ADest: PWasmV128);
procedure WriteFieldV128(const ABase: PByte; const AField: TWasmGcField;
  const ASrc: PWasmV128);
```

each a plain 16-byte `Move` at `ABase + AField.Offset`. Callers
(`:1474, 1483, 1496, 1505, 1531` for structs; `:1571, 1580, 1592, 1601,
1640` for arrays) reach them through the `*Vec` IR ops of §2.4, so no
caller branches at run time.

- **Packed rules do not apply.** `IsPacked` is never true for a vector
  storage type, so the truncate-on-store rule and `get_s`/`get_u` are
  irrelevant. `array.get_s` / `array.get_u` on a `v128` element are not
  even representable — the validator rejects them.
- **No ref-bits impact.** A `v128` field is not a reference; the
  collector's field walk skips it exactly as it skips an `i64`.
- **Deletions:** `MSG_GC_VEC_STORAGE_STAGED` (`:133-143`), the two
  `else raise` arms in `ReadField`/`WriteField`, and the element-width
  guard in `array.init_data` (`:1788-1794`) — the `Move`-based copy
  underneath it (`:1807-1814`) already works for width 16 unmodified.
- `array.fill` with a `v128` value uses `iroArrayFillVec`; `array.copy`
  is width-driven from the layout and needs no change.
- `struct.new` / `array.new_fixed` read an `AuxU32` register list; a
  `v128` field contributes **two** entries, and the helper's field walk
  consumes 1 or 2 based on `IsVec`.

**There is no corpus oracle here.** A grep for `v128` co-occurring with
`field` / `struct` / `array` across the whole testsuite returns zero
hits. Cover it with unit tests in `Wasm.Runtime.Gc.Test`, which already
declares `TY_VEC_STRUCT = 9; { (struct (mut v128)) }` at `:46` for
exactly this purpose: round-trip a vector field, a vector array element,
`array.new_default`'s zero vector, `array.fill`, and `array.copy`.

---

## 8. Unit layout and wave plan

### 8.1 Units touched

| Unit | Change | Wave |
| --- | --- | --- |
| `Wasm.Core` | `TWasmV128` + lane helpers | G1 |
| `Wasm.Ir` | 265 enum members, `IR_OP_INFO` rows, `IR_FORMAT_VERSION` = 2, `ifkSrcRegImm`, even-alignment in `IrAllocReg`, `LocalRegs`, 5 `Describe` arms | G1 |
| **`Wasm.Interp.Vector`** *(new)* | all 256 lane semantics as pure leaves | G4 |
| `Wasm.Wat.Numbers` | `MSG_I8_CONSTANT_OUT_OF_RANGE`, wire `ParseI8`/`ParseI16` | G2 |
| `Wasm.Wat.Opcodes` | `Opcode: UInt32`, `OPCODE_PREFIX_FD`, 4 shapes, `BuildVector` | G2 |
| `Wasm.Wat.Lexer` | one-token `Peek` (§5.5) | G2 |
| `Wasm.Wat.Assembler` | 4 immediate emitters, memidx/lane lookahead, delete the staging note | G2 |
| `Wasm.Validator.Types` | `-MSG_SIMD_NOT_IMPLEMENTED`, `+MSG_INVALID_LANE_INDEX` | G3 |
| `Wasm.Validator` | delete `IsStagedFeatureMessage` | G3 |
| `Wasm.Validator.Body` | `HandleVector` + `VEC_SIG`, `ReadMemargMax`, `FLocalReg` | G3 |
| `Wasm.Validator.Const` | accept `v128.const` | G3 |
| `Wasm.Runtime.Values` | `VecAt`/`VecZero`/`VecEquals`, aligned `Values` allocation | G5 |
| `Wasm.Runtime.Store` | `TWasmGlobalInst.Vec` | G5 |
| `Wasm.Runtime.Instantiate` | `iroV128Const` in the evaluator, vector global init | G5 |
| `Wasm.Runtime.Gc` | `ReadFieldV128`/`WriteFieldV128`, delete 3 staged sites | G5 |
| `Wasm.Interp` | 265 dispatch arms, `MemLoadV128`/`MemStoreV128`, even `Base` | G5 |
| `Wasm.Wast.Values` | vector payload, `TWastExpected`, per-lane matcher, `either` | G6 |
| `Wasm.Wast.Runner` | slot-aware marshaling, delete all SIMD staging | G6 |

Plus the co-located test suites, and `docs/roadmap.md`,
`docs/testing.md`, `tests/spec/README.md`, `AGENTS.md`'s
code-organisation table and its two "deliberately staged" paragraphs.

### 8.2 Waves, with file ownership

The waves are cut so that **concurrently-running waves own disjoint
files**. No two parallel waves edit the same unit.

```
        ┌──────────────── G2 (Wat.Numbers, Wat.Opcodes, Wat.Lexer, Wat.Assembler)
        │
  G1 ───┼──────────────── G3 (Validator*, Validator.Body, Validator.Const)  ──┐
(Core,  │                                                                     ├── G7
 Ir)    └──────────────── G5 (Interp, Runtime.*)  ←── needs G4                │
                                                                              │
  G4 (Interp.Vector) ─────────────────────────────────────────────────────────┤
                                                                              │
  G6 (Wast.Values, Wast.Runner) ──────────────────────────────────────────────┘
```

**G1 — foundation.** `Wasm.Core` + `Wasm.Ir` + `Wasm.Ir.Test`. The enum,
the info table, the version bump, `ifkSrcRegImm`, the alignment rule, the
`Describe` arms. Mechanical and small; it blocks G3 and G5. *Corpus
unlock: 0.*

**G2 — assembler text forms.** Depends on `Wasm.Core` only, so it can
start **before or alongside G1**. Owns the four SIMD-specific message
prefixes. *Corpus unlock on its own: 50 `assert_malformed` commands
(`i8 constant out of range` 15, `wrong number of lane literals` 8,
`wrong number of lane indices` 5, `alignment must be a power of two` 22).
It also stops ~1,620 commands from being STAGED — but those then land on
the validator, so the honest reporting point is G3.*

**G3 — validation.** Needs G1. Owns `invalid lane index` (48) and the
`alignment must not be larger than natural` SIMD cases (20). Together
with G2, `staged` goes to zero and the 671 `assert_invalid` + 509
`assert_malformed` SIMD commands become judged. *Corpus unlock with G2:
≈1,230 commands, plus the ~1,620 currently-staged flip to pass.*

**G4 — vector semantics.** `Wasm.Interp.Vector` + its test, pure and
dependency-free below `Wasm.Core`. **This is the single largest chunk
(~256 leaves) and it can run fully in parallel with G1/G2/G3** — the same
isolation argument as Track E's Wave 1. Unit tests assert bit-exact lane
results, the wrap/saturate boundaries, per-lane NaN classes, the
`pmin`/`pmax`-vs-`min`/`max` split, swizzle's out-of-range zero, and each
relaxed op against its non-relaxed twin. *Corpus unlock: 0. Highest
defect density; find it in isolation.*

**G5 — dispatch and runtime.** Needs G1 and G4. All 265 arms, the two
16-byte memory leaves, the vector global cell, the GC accessors, the
const-expression evaluator. *Corpus unlock: nothing until G6 wires the
comparator.*

**G6 — harness.** `Wasm.Wast.Values` + `Wasm.Wast.Runner`: the vector
payload, the per-lane comparator, `(either …)`, slot-aware marshaling,
and the staging deletions. The **code** is independent of G3/G5 and can
be written in parallel; the **results** need everything. *Corpus unlock:
the 24,281 SIMD `assert_return`s, 54 `assert_trap`s, and the 69 relaxed
`assert_return`s.*

**G7 — corpus run and message settling.** Budget two passes, exactly as
`wat-assembler.md §6`'s Wave 6 did: expect prefix divergences and few
wrong-class verdicts. Publish the new tallies and enumerate every new
FAIL with both strings.

### 8.3 Corpus arithmetic

Baseline (`WebAssembly/testsuite@de54fd27`, 288 files):
`pass=38900 fail=444 skip=26161 staged=1620`, judged ≈40,900 of ≈67,000.

Newly judged by Track G:

| Source | Commands |
| --- | ---: |
| `simd_*.wast` `assert_return` | 24,281 |
| `simd_*.wast` `assert_trap` | 54 |
| `simd_*.wast` `assert_invalid` | 671 |
| `simd_*.wast` `assert_malformed` | 509 |
| relaxed files `assert_return` | 69 |
| **Total** | **25,584** |

plus the top-level module commands in those 66 files. The currently
`staged=1620` bucket goes to ~0 (its residue is Track H's). Expect
`skip` to fall from ~26,161 to ~1,900 — what remains is
`assert_unlinkable` (262), host imports the harness does not provide, the
EH suite, and the `_custom` directives. Judged should reach ≈66,400 of
≈67,000.

Two operational notes: `simd_f32x4_pmin_pmax.wast` and
`simd_f64x2_pmin_pmax.wast` are 11,676 lines each — watch runner
timeouts, as the roadmap already warns. And `Wasm.Wast.Runner.pas:249`'s
growth-by-doubling comment already names these files.

---

## 9. Observational identity — what Track I and Track J must match

Added to `interp-spec.md §8`'s list. Items 1 and 2 are the ones a JIT
gets wrong by *default*, because the natural hardware instruction is the
non-conformant one.

1. **Relaxed operations are `R = 0`, the deterministic profile, always
   (§4.6).** This is the expensive one, and it must be budgeted now:
   - `relaxed_madd` / `relaxed_nmadd` must be **unfused** — a JIT must
     *not* emit `vfmadd*` / `FMLA`, which is precisely the instruction
     the op exists to expose.
   - `relaxed_swizzle` must zero out-of-range indices — x86 `pshufb`
     zeroes only when the index's high bit is set, so indices 16..127
     need a fixup (`pcmpgtb` against 15, or an `and` with 0x8F).
   - `relaxed_laneselect` must be a bitwise `bitselect`, not a
     high-bit-broadcast blend (`vpblendvb` broadcasts; it does not).
   - `relaxed_min` / `relaxed_max` must be wasm `fmin`/`fmax` with NaN
     canonicalisation and the ±0 rule — not bare `minps`/`maxps`.
   - `relaxed_trunc*` must saturate like `trunc_sat`, not produce
     x86's `0x80000000` indefinite value.
   - `relaxed_q15mulr_s` must saturate the `-32768 × -32768` case to
     `32767`, and `relaxed_dot_*` must be the signed dot product.
2. **Per-lane NaN.** Every payload-affecting float lane op that produces
   NaN yields the **positive canonical** pattern, per lane. Exempt and
   bit-preserving: `abs`, `neg`, all `v128.*` bitwise ops, `bitselect`,
   `laneselect`, splat/extract/replace/shuffle/swizzle, every load and
   store, and **`pmin`/`pmax`**.
3. **`pmin`/`pmax` are selections, not min/max.** `pmin(a,b)` is
   `b < a ? b : a`, returning an operand bit-for-bit including its NaN
   payload and sign; `min(a,b)` canonicalises NaN and applies the ±0
   rule. A JIT that lowers both to `minps` diverges on thousands of
   `simd_f32x4_pmin_pmax.wast` assertions.
4. **Lane order is little-endian within the vector.** Lane `i` of shape
   `t x N` is bytes `[i*w, (i+1)*w)`. `bitmask` puts lane 0 in bit 0.
5. **`i8x16.swizzle` yields 0 for any index ≥ 16** (unsigned reading), and
   `shuffle`'s mask is validated `< 32` so no run-time check is needed.
6. **Shift counts are taken modulo the lane width.**
7. **Traps.** Only the 22 memory-family ops can trap, only with
   `out of bounds memory access`, and only through the one chokepoint —
   identical across guard-page, guard-assisted, and bounds-checked
   strategies. The whole access is range-checked before any byte moves,
   so a trapping `v128.store` writes nothing.
8. **The two-slot `v128` ABI is part of the engine calling convention**
   (§1.6): 16 bytes = two consecutive 8-byte slots, low half first, low
   slot at an even, 16-byte-aligned index. `TWasmTierInvokeProc` and the
   host callback contract both depend on it, so the differential harness
   drives both tiers through the same buffers unchanged.
9. **`v128` is never a reference.** `RefRegBits`, the stack maps, and the
   root scan are unaffected; a JIT's register allocator may keep a `v128`
   in a vector register across a safepoint with no GC bookkeeping.

---

## Appendix A — the complete `$FD` space

Subopcodes are the `u32` LEB after the `$FD` prefix. `M` marks the 22
instructions the spec files under *memory*; everything else is *vec*.
IR member names follow §2.1's rule.

**Memory: whole, packed, splat, store — memarg (0..11)**

| 0 `v128.load` M · 1 `v128.load8x8_s` M · 2 `v128.load8x8_u` M · 3 `v128.load16x4_s` M · 4 `v128.load16x4_u` M · 5 `v128.load32x2_s` M · 6 `v128.load32x2_u` M · 7 `v128.load8_splat` M · 8 `v128.load16_splat` M · 9 `v128.load32_splat` M · 10 `v128.load64_splat` M · 11 `v128.store` M |
| --- |

**Const and shuffle — 16-byte immediate (12..13)**

| 12 `v128.const` · 13 `i8x16.shuffle` |
| --- |

**Swizzle and splat (14..20)**

| 14 `i8x16.swizzle` · 15 `i8x16.splat` · 16 `i16x8.splat` · 17 `i32x4.splat` · 18 `i64x2.splat` · 19 `f32x4.splat` · 20 `f64x2.splat` |
| --- |

**Lane access — one laneidx byte (21..34)**

| 21 `i8x16.extract_lane_s` · 22 `i8x16.extract_lane_u` · 23 `i8x16.replace_lane` · 24 `i16x8.extract_lane_s` · 25 `i16x8.extract_lane_u` · 26 `i16x8.replace_lane` · 27 `i32x4.extract_lane` · 28 `i32x4.replace_lane` · 29 `i64x2.extract_lane` · 30 `i64x2.replace_lane` · 31 `f32x4.extract_lane` · 32 `f32x4.replace_lane` · 33 `f64x2.extract_lane` · 34 `f64x2.replace_lane` |
| --- |

**Comparisons (35..76)**

| 35..44 `i8x16.` `eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u` |
| --- |
| 45..54 `i16x8.` `eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u` |
| 55..64 `i32x4.` `eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u` |
| 65..70 `f32x4.` `eq ne lt gt le ge` |
| 71..76 `f64x2.` `eq ne lt gt le ge` |

**Bitwise and the whole-vector test (77..83)**

| 77 `v128.not` · 78 `v128.and` · 79 `v128.andnot` · 80 `v128.or` · 81 `v128.xor` · 82 `v128.bitselect` · 83 `v128.any_true` |
| --- |

**Memory: lane and zero — memarg + laneidx / memarg (84..93)**

| 84 `v128.load8_lane` M · 85 `v128.load16_lane` M · 86 `v128.load32_lane` M · 87 `v128.load64_lane` M · 88 `v128.store8_lane` M · 89 `v128.store16_lane` M · 90 `v128.store32_lane` M · 91 `v128.store64_lane` M · 92 `v128.load32_zero` M · 93 `v128.load64_zero` M |
| --- |

**Float conversions (94..95)**

| 94 `f32x4.demote_f64x2_zero` · 95 `f64x2.promote_low_f32x4` |
| --- |

**i8x16 unary, narrow, f32x4 rounding, i8x16 arithmetic (96..127)**

| 96 `i8x16.abs` · 97 `i8x16.neg` · 98 `i8x16.popcnt` · 99 `i8x16.all_true` · 100 `i8x16.bitmask` · 101 `i8x16.narrow_i16x8_s` · 102 `i8x16.narrow_i16x8_u` |
| --- |
| 103 `f32x4.ceil` · 104 `f32x4.floor` · 105 `f32x4.trunc` · 106 `f32x4.nearest` |
| 107 `i8x16.shl` · 108 `i8x16.shr_s` · 109 `i8x16.shr_u` · 110 `i8x16.add` · 111 `i8x16.add_sat_s` · 112 `i8x16.add_sat_u` · 113 `i8x16.sub` · 114 `i8x16.sub_sat_s` · 115 `i8x16.sub_sat_u` |
| 116 `f64x2.ceil` · 117 `f64x2.floor` |
| 118 `i8x16.min_s` · 119 `i8x16.min_u` · 120 `i8x16.max_s` · 121 `i8x16.max_u` |
| 122 `f64x2.trunc` · 123 `i8x16.avgr_u` |
| 124 `i16x8.extadd_pairwise_i8x16_s` · 125 `i16x8.extadd_pairwise_i8x16_u` · 126 `i32x4.extadd_pairwise_i16x8_s` · 127 `i32x4.extadd_pairwise_i16x8_u` |

**i16x8 (128..159; 154 unassigned)**

| 128 `i16x8.abs` · 129 `i16x8.neg` · 130 `i16x8.q15mulr_sat_s` · 131 `i16x8.all_true` · 132 `i16x8.bitmask` · 133 `i16x8.narrow_i32x4_s` · 134 `i16x8.narrow_i32x4_u` |
| --- |
| 135 `i16x8.extend_low_i8x16_s` · 136 `i16x8.extend_high_i8x16_s` · 137 `i16x8.extend_low_i8x16_u` · 138 `i16x8.extend_high_i8x16_u` |
| 139 `i16x8.shl` · 140 `i16x8.shr_s` · 141 `i16x8.shr_u` · 142 `i16x8.add` · 143 `i16x8.add_sat_s` · 144 `i16x8.add_sat_u` · 145 `i16x8.sub` · 146 `i16x8.sub_sat_s` · 147 `i16x8.sub_sat_u` |
| 148 `f64x2.nearest` · 149 `i16x8.mul` · 150 `i16x8.min_s` · 151 `i16x8.min_u` · 152 `i16x8.max_s` · 153 `i16x8.max_u` · **154 —** · 155 `i16x8.avgr_u` |
| 156 `i16x8.extmul_low_i8x16_s` · 157 `i16x8.extmul_high_i8x16_s` · 158 `i16x8.extmul_low_i8x16_u` · 159 `i16x8.extmul_high_i8x16_u` |

**i32x4 (160..191; 162, 165, 166, 175, 176, 178..180, 187 unassigned)**

| 160 `i32x4.abs` · 161 `i32x4.neg` · **162 —** · 163 `i32x4.all_true` · 164 `i32x4.bitmask` · **165 —** · **166 —** |
| --- |
| 167 `i32x4.extend_low_i16x8_s` · 168 `i32x4.extend_high_i16x8_s` · 169 `i32x4.extend_low_i16x8_u` · 170 `i32x4.extend_high_i16x8_u` |
| 171 `i32x4.shl` · 172 `i32x4.shr_s` · 173 `i32x4.shr_u` · 174 `i32x4.add` · **175..176 —** · 177 `i32x4.sub` · **178..180 —** · 181 `i32x4.mul` |
| 182 `i32x4.min_s` · 183 `i32x4.min_u` · 184 `i32x4.max_s` · 185 `i32x4.max_u` · 186 `i32x4.dot_i16x8_s` · **187 —** |
| 188 `i32x4.extmul_low_i16x8_s` · 189 `i32x4.extmul_high_i16x8_s` · 190 `i32x4.extmul_low_i16x8_u` · 191 `i32x4.extmul_high_i16x8_u` |

**i64x2 (192..223; 194, 197, 198, 207, 208, 210..212 unassigned)**

| 192 `i64x2.abs` · 193 `i64x2.neg` · **194 —** · 195 `i64x2.all_true` · 196 `i64x2.bitmask` · **197..198 —** |
| --- |
| 199 `i64x2.extend_low_i32x4_s` · 200 `i64x2.extend_high_i32x4_s` · 201 `i64x2.extend_low_i32x4_u` · 202 `i64x2.extend_high_i32x4_u` |
| 203 `i64x2.shl` · 204 `i64x2.shr_s` · 205 `i64x2.shr_u` · 206 `i64x2.add` · **207..208 —** · 209 `i64x2.sub` · **210..212 —** · 213 `i64x2.mul` |
| 214 `i64x2.eq` · 215 `i64x2.ne` · 216 `i64x2.lt_s` · 217 `i64x2.gt_s` · 218 `i64x2.le_s` · 219 `i64x2.ge_s` *(no unsigned i64x2 comparisons exist)* |
| 220 `i64x2.extmul_low_i32x4_s` · 221 `i64x2.extmul_high_i32x4_s` · 222 `i64x2.extmul_low_i32x4_u` · 223 `i64x2.extmul_high_i32x4_u` |

**f32x4 / f64x2 arithmetic (224..247; 226, 238 unassigned)**

| 224 `f32x4.abs` · 225 `f32x4.neg` · **226 —** · 227 `f32x4.sqrt` · 228 `f32x4.add` · 229 `f32x4.sub` · 230 `f32x4.mul` · 231 `f32x4.div` · 232 `f32x4.min` · 233 `f32x4.max` · 234 `f32x4.pmin` · 235 `f32x4.pmax` |
| --- |
| 236 `f64x2.abs` · 237 `f64x2.neg` · **238 —** · 239 `f64x2.sqrt` · 240 `f64x2.add` · 241 `f64x2.sub` · 242 `f64x2.mul` · 243 `f64x2.div` · 244 `f64x2.min` · 245 `f64x2.max` · 246 `f64x2.pmin` · 247 `f64x2.pmax` |

**Conversions (248..255)**

| 248 `i32x4.trunc_sat_f32x4_s` · 249 `i32x4.trunc_sat_f32x4_u` · 250 `f32x4.convert_i32x4_s` · 251 `f32x4.convert_i32x4_u` · 252 `i32x4.trunc_sat_f64x2_s_zero` · 253 `i32x4.trunc_sat_f64x2_u_zero` · 254 `f64x2.convert_low_i32x4_s` · 255 `f64x2.convert_low_i32x4_u` |
| --- |

**Relaxed SIMD — the 20 3.0 additions (256..275)**

| 256 `i8x16.relaxed_swizzle` · 257 `i32x4.relaxed_trunc_f32x4_s` · 258 `i32x4.relaxed_trunc_f32x4_u` · 259 `i32x4.relaxed_trunc_f64x2_s_zero` · 260 `i32x4.relaxed_trunc_f64x2_u_zero` |
| --- |
| 261 `f32x4.relaxed_madd` · 262 `f32x4.relaxed_nmadd` · 263 `f64x2.relaxed_madd` · 264 `f64x2.relaxed_nmadd` |
| 265 `i8x16.relaxed_laneselect` · 266 `i16x8.relaxed_laneselect` · 267 `i32x4.relaxed_laneselect` · 268 `i64x2.relaxed_laneselect` |
| 269 `f32x4.relaxed_min` · 270 `f32x4.relaxed_max` · 271 `f64x2.relaxed_min` · 272 `f64x2.relaxed_max` |
| 273 `i16x8.relaxed_q15mulr_s` · 274 `i16x8.relaxed_dot_i8x16_i7x16_s` · 275 `i32x4.relaxed_dot_i8x16_i7x16_add_s` |

Count check: 276 slots − 20 unassigned = **256** = 234 `vec` + 22
`memory`.

---

## Appendix B — spec anchors cited

Pinned `spec/main` `d7b37e4170d8315f2f1283aed4e8076591a9a333`.

*Syntax and types:* `syntax-laneidx` (shape vocabulary, lane naming,
the subcategory list), `syntax-instr-vec`, `syntax-instr-vec-relaxed`,
`syntax-vectype`.

*Validation:* `valid-vconst`, `valid-vshuffle`, `valid-vswizzlop`,
`valid-vsplat`, `valid-vextract_lane`, `valid-vreplace_lane`,
`valid-vunop`, `valid-vbinop`, `valid-vternop`, `valid-vrelop`,
`valid-vtestop`, `valid-vshiftop`, `valid-vbitmask`, `valid-vcvtop`,
`valid-vextunop`, `valid-vextbinop`, `valid-vextternop`,
`valid-vvunop`, `valid-vvbinop`, `valid-vvternop`, `valid-vvtestop`,
`valid-vload`, `valid-vload-pack`, `valid-vload-splat`,
`valid-vload-zero`, `valid-vload_lane`, `valid-vstore`,
`valid-vstore_lane`.

*Execution:* the `exec-` twin of each of the above, plus `exec-vnarrow`
(reached from `i8x16.narrow_i16x8_s`, whose validation anchor is
`valid-vbinop`).

*Numerics:* `aux-nans` (the NaN rule the per-lane discipline inherits),
`relaxed-ops` / `aux-relaxed` (implementation-dependent results as fixed
global parameters), `profile-deterministic` (every parameter prescribed
to 0; canonical positive NaN), `op-ivrelaxed_swizzle`,
`op-relaxed_trunc_s`, `op-relaxed_trunc`, `op-frelaxed_madd`,
`op-frelaxed_nmadd`, `op-irelaxed_laneselect`, `op-frelaxed_min`,
`op-frelaxed_max`, `op-irelaxed_q15mulr_s`, `op-irelaxed_dot`,
`op-vextbinop`.

---

## Appendix C — the staged-marker removal checklist

Every site AGENTS.md, the roadmap, or the source currently marks as
staged SIMD. Track G is not done until all of them are gone.

| File:line | What | Action |
| --- | --- | --- |
| `Wasm.Validator.Types.pas:148` | `MSG_SIMD_NOT_IMPLEMENTED` | delete |
| `Wasm.Validator.pas:109-113, 180-187` | `IsStagedFeatureMessage` | delete (§3.6) |
| `Wasm.Validator.Body.pas:29-31, 3820-3893` | header note + the `$FD` arm | replace with `HandleVector` |
| `Wasm.Validator.Const.pas:38-39, 184, 212, 313, 951-964` | staged prose + the `OP_PREFIX_VEC` arm | accept `v128.const` |
| `Wasm.Runtime.Gc.pas:133-143, 1399, 1419, 1788-1794` | `MSG_GC_VEC_STORAGE_STAGED` + 3 raise sites | delete (§7) |
| `Wasm.Runtime.Instantiate.pas:103-106` | "Track G appends v128.const" | implement |
| `Wasm.Interp.pas:16, 28` | "the full non-SIMD … dispatch" header | rewrite |
| `Wasm.Interp.Numeric.pas:1` | "every non-vector numeric op" | rewrite (point at `Wasm.Interp.Vector`) |
| `Wasm.Runtime.Values.pas:55-60` | the 8-byte / v128 staging paragraph | rewrite as the §1.3 pair rule |
| `Wasm.Wat.Opcodes.pas:1, 15, 19-21, 475-477` | header + the GAP comment | replace with `BuildVector` |
| `Wasm.Wat.Assembler.pas:29-31` | "the ONE thing not encoded" | delete |
| `Wasm.Wast.Values.pas:117-129, 707-718` | staged docs, parse stubs, `WastValIsStaged` | implement / delete |
| `Wasm.Wast.Runner.pas:43, 56-61, 308-317, 420-443, 574, 620, 640-650, 848, 876, 1101, 1120, 1309-1310, 1524-1525, 1541` | the whole SIMD staging apparatus | delete (§6.4) |
| `Wasm.Ir.Test.pas:99` | `ToBe(231)` | `ToBe(496)` |
| `Wasm.Validator.Body.Test.pas:1098` | `ExpectInvalid('a $FD vector instruction', MSG_SIMD_NOT_IMPLEMENTED)` | rewrite as an IR-emission assertion |
| `Wasm.Validator.Const.Test.pas:673-682, 739` | staged-SIMD negatives | rewrite |
| `Wasm.Fixtures.Test.pas:291-310, 569, 632-649` | `simd.wasm` asserts the staged message | rewrite; the roadmap names this as the first thing to fail |
| `Wasm.Runtime.Gc.Test.pas:46, 202, 1470-1478, 1599-1600` | `TestVectorStorageIsStagedNotAnInternalBug` | rewrite as a round-trip |
| `Wasm.Wast.Runner.Test.pas` (30 hits) | staged-classification tests | rewrite |
| `AGENTS.md` (the two "deliberately staged" paragraphs), `docs/roadmap.md` Tracks B/C/E/G, `docs/testing.md`, `tests/spec/README.md` | prose | update with the measured G7 tallies |
