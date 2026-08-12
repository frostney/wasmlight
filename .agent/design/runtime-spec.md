# Track D — Runtime state and the precise collector

Design contract. **Not source.** Scratchpad only — never commit.

Spec pin: `wasm-mcp` 0.2.16, upstream `spec/main`
`d7b37e4170d8315f2f1283aed4e8076591a9a333` (ADR-0004). Every spec claim
below cites the anchor it was read from. Claims that could **not** be
confirmed from served text carry an explicit `UNCONFIRMED` marker — the
repo's existing convention (`Wasm.Validator.Types` message prefixes) and
Track C's runner is what settles them.

Scope: the store, instances, linear memory, tables, globals, tags, the
trap path, instantiation, and the collector. **Track E (the interpreter)
is out of scope**; where Track D must constrain it, the constraint is
written as a contract Track E has to satisfy, not as interpreter design.

---

## 0. Standing constraints this document is written under

| Source | Constraint |
| --- | --- |
| ADR-0003 | The decoded module and `TWasmIrModule` **borrow** the caller's bytes. Data-segment payloads are spans. |
| ADR-0005 | One memory-access chokepoint. Strategy varies by **platform**, never by tier. |
| ADR-0006 | Epoch check at loop back-edges and function entries. |
| ADR-0007 / ADR-0012 | Validation already ran. No runtime unit re-derives a spec rule or reads the raw binary (data-segment *bytes* excepted — those are the module's payload, not its code). |
| ADR-0008 | A store is confined to one thread. **Zero locks, zero atomics** on any structure reachable from a store. |
| ADR-0009 | Traps unwind to a per-invocation trampoline. Frames a `siglongjmp` can skip hold **no managed Pascal state**. |
| ADR-0010 | 32-bit targets are conformant, on explicit bounds checks. |
| ADR-0011 (amended) | Precise GC from IR-derived stack maps. Safepoints = epoch locations **plus every allocation site**. Host roots need explicit registration. |
| ADR-0013 | Strategy matrix is decidable from (platform, memory address type) alone. |

**The one global invariant.** Every claim in this document reduces to:
*the runtime holds no type information a value does not need, because
`TWasmIrFunction.RegTypes` and `RefRegBits` already hold it.* Where a bit
of runtime tagging is proposed (§1.3), it is justified against exactly
that sentence.

---

## 1. Value representation

### 1.1 `TWasmValue` — the interpreter frame slot

```pascal
{ Wasm.Runtime.Values }

TWasmRef = NativeUInt;      { see §1.3 }

TWasmValue = record
  case Integer of
    0: (I32:  Int32);
    1: (U32:  UInt32);
    2: (I64:  Int64);
    3: (U64:  UInt64);
    4: (F32:  Single);
    5: (F64:  Double);
    6: (Ref:  TWasmRef);
    7: (Bits: UInt64);      { the canonical raw view }
end;
```

**Size: 8 bytes.** A frame is `array of TWasmValue` of length
`TWasmIrFunction.RegisterCount` — the IR already states that
"`RegisterCount` is the interpreter frame size; there is no separate
operand-stack depth" (`Wasm.Ir.pas` header, register-numbering comment).

Rules:

- **`Bits` is the canonical raw view.** Narrow writes (`I32`, `F32`,
  `Ref` on a 32-bit host) MUST zero the whole 8-byte slot first —
  `Bits := 0` then the narrow store, or a combined widening store. This
  is not cosmetic: §7.5's root scan reads `Ref` from a slot, and a stale
  high half left by an earlier `I64` in the same register would be read
  as a pointer. Registers are never reused across types (the IR
  allocates temporaries monotonically and never reuses them, so
  `RegTypes[i]` is the register's type for the whole function) — but
  *parameters and locals* are reused across a call, and locals of ref
  type are reset to null at entry anyway. Keep the zeroing rule
  unconditional; it is one store and it removes a whole class of
  root-scan bug.
- **No tag field.** `TWasmValue` carries no discriminator. The type of
  register *i* is `RegTypes[i]`, statically. This is ADR-0011's
  load-bearing premise.
- **32-bit hosts.** `TWasmRef` is 4 bytes there; the slot stays 8 bytes
  so the frame layout, and therefore the stack-map projection, is
  bitness-independent.

### 1.2 v128 (Track G) — deliberately NOT in the slot

`v128` needs 16 bytes. Two options:

1. Widen every slot to 16 bytes.
2. Keep 8-byte slots and give each function a **side vector** for its
   `wvkVec` registers, with a dense remap computed once at IR build.

**Recommendation: (2).** Option (1) doubles frame memory traffic and
halves frame cache density for the ~99% of functions with no vector
register, on the tier that has to run everywhere. Option (2) costs one
indirection on vector register access only, and the remap is free
because `RegTypes[i].Kind = wvkVec` is already known statically — the
same projection that produces `RefRegBits` produces `VecRegSlot`.

Track G owns the decision; this document only fixes that `TWasmValue`
stays 8 bytes in Track D and that widening it later is a change to one
record plus the frame allocator, not to the store.

### 1.3 References — pointer-or-i31, low-bit tagged

```text
TWasmRef (NativeUInt), interpreted as:

  value = 0                → null
  value and 1 = 1          → unboxed i31; payload in bits 1..31
  otherwise                → pointer to a GC heap object header (§7.1)
```

**Null is nil (`0`).** Justification, and why it is safe despite the
spec's `REF.NULL ht` carrying a heap type: the only instruction whose
result depends on a null's hierarchy is `ref.cast` / `ref.test`, and
`valid-ref.cast` types the operand at a supertype `rt'` of the target
`rt` — "the liberty to pick a supertype rt' allows typing the
instruction with the least precise super type of rt as input, that is,
the top type in the corresponding heap subtyping hierarchy"
(`valid-ref.cast`). Validation therefore already pins the operand's
hierarchy, so at run time the cast of a null reduces to *"does the
target reftype admit null"* — a static property of the target, needing
no information from the value. `ref.eq` is restricted to `eqref`, so two
nulls from different hierarchies are never comparable. Reference types
are in any case "opaque, meaning that neither their size nor their bit
pattern can be observed" (`syntax-reftype`).

> `UNCONFIRMED` — that no 3.0 instruction distinguishes nulls of
> different hierarchies at run time. The argument above is complete over
> the instructions Track B emits, but the check is `assert_return` on
> the `ref_null`, `ref_cast`, `ref_test`, and `type-equivalence` corpus
> files under Track C. If it falls, the fix is local: widen null into
> four reserved non-pointer constants (`2`, `4`, `6`, `8` — all with the
> i31 bit clear and below any heap address), which the mark loop already
> rejects by the null test being a range test rather than an equality.

**Unboxed i31.** `syntax-num` describes non-null references as
"scalar references, containing a 31-bit integer" among the forms. The
encoding:

```text
ref.i31   x:i32     →  Ref := NativeUInt(UInt32((UInt32(x) shl 1) or 1))
i31.get_s r         →  SarInt32(Int32(UInt32(r)), 1)      { arithmetic }
i31.get_u r         →  UInt32(r) shr 1                    { 31 bits }
ref.eq    a, b      →  a = b                              { plain compare }
```

31 payload bits + 1 tag bit = exactly 32, so this fits a 32-bit
`NativeUInt` with nothing to spare and is byte-identical on both
bitnesses (the 64-bit form zero-extends the 32-bit word — do **not**
sign-extend, or `ref.eq` breaks across the two paths). `ref.i31`'s
required wrap to 31 bits falls out of the `shl 1` discarding bit 31.

**Justification, unboxed vs boxed.** Boxing costs a heap allocation on
every `ref.i31` — and `ref.i31` is exactly what a language backend
(Kotlin/Wasm, Dart, OCaml) emits for every small integer in a generic
container. It also makes `ref.eq` on i31 a heap comparison, which the
spec's by-value equality then has to emulate. Unboxing costs one bit of
address space that object alignment already reserves (§7.1 aligns every
heap object to 8 bytes, so bit 0 of a real pointer is always 0) and one
`and 1` test on the deref and trace paths. Every surveyed engine unboxes
(V8 Smi, SpiderMonkey, Wasmtime `VMGcRef`). The IR already flags
`iroRefI31` as a safepoint (`IrOpIsSafepoint`, `Wasm.Ir.pas`) — that
flag becomes conservative rather than wrong under unboxing, and the
runtime treats it as a no-op safepoint. **Do not un-flag it in the IR**;
that would be an IR format change for a runtime detail.

**Why this is not the universal tagging ADR-0011 forbids.** ADR-0011's
"precision costs no runtime tagging" is about *type* tags: the collector
must not need a value to say "I am a ref". It still does not — the
collector learns "slot *i* is a ref" from `RefRegBits`, a projection of
`RegTypes`. The i31 bit lives *inside a single static type*
(`anyref`/`eqref`/`i31ref`) and answers a different question: "is this
particular ref traceable". Exactly one bit, exactly one hierarchy, and
nothing else in the runtime is tagged. Any proposal to add a second tag
bit reopens ADR-0011.

**Host references (`externref` of an embedder value).** A raw host
pointer is **not** a valid `TWasmRef`: its low bit may be set, and the
collector cannot trace or move it. An `externref` wrapping a host value
is a pointer to a GC-heap `THostBox` (§7.1, kind `wokHostBox`) holding
one opaque `NativeUInt` payload plus an embedder-supplied release
callback slot. This is also what makes `extern.convert_any` /
`any.convert_extern` a no-op on representation (they are identity on the
pointer; only the static type changes), which matches Track B's flat
reading of those instructions.

---

## 2. Store and instances

### 2.1 `TWasmStore`

One thread, no locks, no atomics (ADR-0008). "The store represents all
global state that can be manipulated by WebAssembly programs …
functions, tables, memories, globals, tags, element segments, data
segments, and structures, arrays or exceptions" (`syntax-store`).

```pascal
{ Wasm.Runtime.Store }

TWasmStore = class
public
  { --- spec store categories (syntax-store) --------------------------
    Grow-only arrays. An address is an INDEX, never a pointer: the array
    may reallocate, and a raw pointer into it would dangle. Nothing is
    ever removed — reclamation of these categories is out of scope
    ("implementations may apply techniques like garbage collection … such
    techniques are not semantically observable", syntax-store). Only the
    GC heap (§7) reclaims, and it holds no funcaddr/tableaddr/... }
  Funcs:    array of TWasmFuncInst;
  Tables:   array of TWasmTableInst;
  Memories: array of TWasmMemoryInst;
  Globals:  array of TWasmGlobalInst;
  Tags:     array of TWasmTagInst;
  Elems:    array of TWasmElemInst;
  Datas:    array of TWasmDataInst;

  Instances: array of TWasmModuleInstance;

  { --- engine-scoped state ----------------------------------------- }
  Engine: TWasmEngine;          { canonical types — §2.5, NOT owned }
  Heap:   TWasmGcHeap;          { §7 — owned }
  Traps:  TWasmTrapContext;     { §5 — owned }

  Epoch: UInt64;                { ADR-0006; plain load/store, no atomic }
  OwnerThreadId: TThreadID;     { debug builds only — §2.6 }

  HostRoots: TWasmHostRootSet;  { §7.5 — owned }
end;
```

**Addresses are indices.** `TWasmFuncAddr = UInt32` and friends. The
spec's addresses are abstract (`syntax-funcaddr`); an index into a
grow-only array is the cheapest faithful model and survives the array
reallocating. `WASM_NO_ADDR = High(UInt32)` is the absent marker.

**A `funcref` value is not a `funcaddr`.** A `funcref` is a `TWasmRef`
(§1.3) and must be a *pointer* so `ref.eq`-adjacent identity and the
GC's tracing both work uniformly. Resolution: function instances are
allocated **in the GC heap** as `wokFuncRef` objects (§7.1) holding the
funcaddr; `store.Funcs[a]` holds the authoritative record and the heap
object is its handle. One heap object per function instance, created at
instantiation, permanently reachable from the owning module instance's
root set — so it is never collected while its instance lives, and
`ref.func` returns the same pointer every time (function instance
identity "is not observable by WebAssembly code", `syntax-hostfunc`, but
making it stable is free and removes a class of surprise).

### 2.2 `TWasmModuleInstance`

"A module instance … collects runtime representations of all entities
that are imported, defined, or exported by the module. Each component
references runtime instances … in the order of their static indices"
(`syntax-moduleinst`).

```pascal
TWasmModuleInstance = class
public
  { --- borrowed, ADR-0003 ------------------------------------------- }
  Ir:    TWasmIrModule;         { NOT owned }
  Bytes: PByte;                 { NOT owned — base of the module buffer }
  BytesLength: NativeUInt;

  { --- index spaces, imports first, exactly the IR's ordering ------- }
  FuncAddrs:   array of TWasmFuncAddr;
  TableAddrs:  array of TWasmTableAddr;
  MemAddrs:    array of TWasmMemAddr;
  GlobalAddrs: array of TWasmGlobalAddr;
  TagAddrs:    array of TWasmTagAddr;
  ElemAddrs:   array of TWasmElemAddr;
  DataAddrs:   array of TWasmDataAddr;

  { --- engine-global canonical ids, one per MODULE type index -------
    The runtime never uses TWasmIrModule.TypeIndexToCanon directly:
    those ids are module-local (Wasm.Ir.pas, "Canonical type ids are
    MODULE-LOCAL"). This is the remap produced by §2.5. }
  EngineTypeIds: array of TWasmEngineTypeId;

  { --- exports ------------------------------------------------------
    "It is an invariant of the semantics that all export instances in a
    given module instance have different names" (syntax-moduleinst);
    the validator already enforced MSG_DUPLICATE_EXPORT_NAME. }
  ExportNames: array of string;
  ExportKinds: array of TWasmExternKind;
  ExportAddrs: array of UInt32;

  { --- pending start (§6.6) ----------------------------------------- }
  HasPendingStart: Boolean;
  PendingStartFuncIndex: UInt32;

  { --- GC roots owned by this instance (§7.5) ----------------------- }
  FuncRefObjects: array of TWasmRef;   { the wokFuncRef handles }
end;
```

### 2.3 Lifetime rules (ADR-0003, spelled out)

These are the rules the Pascal compiler cannot check. They go in the doc
comment of **every** entry point that produces a store, an instance, or
an IR module.

1. **The module buffer outlives the IR module, which outlives every
   module instance, which outlives the store's use of it.** Concretely:
   `Bytes` must remain valid and unmoved for as long as the instance is
   in `Store.Instances`.
2. **`TWasmIrModule` is borrowed by the instance, not owned.** One IR
   module may back many instances (in one store or several). Freeing it
   while an instance references it is a use-after-free with no
   diagnostic.
3. **The only consumer of `Bytes` at run time is data-segment
   initialisation** (`TWasmIrDataSegment.Bytes` is a `TWasmIrSpan`,
   offset+size into the buffer) and `array.new_data` /
   `memory.init`. After instantiation completes, if every data segment
   has been dropped (`data.drop`, or an active segment which is dropped
   by the instantiation sequence — §6.5), the buffer is no longer read.
4. **`TWasmDataInst` therefore stores a span, not a copy**, plus a
   `Dropped: Boolean`. Dropping sets `Dropped` and zeroes the span; it
   does not free anything.
5. **Provide the query, do not rely on the comment.** ADR-0003 names
   WAMR's "is the underlying binary freeable" query as the honest way to
   make the contract checkable. Track D ships
   `TWasmModuleInstance.BorrowsBuffer: Boolean` — true until every data
   segment is dropped. Track F's embedding API surfaces it.

### 2.4 Function instances

"A function instance … effectively is a closure of the original function
over the runtime module instance of its originating module"
(`syntax-hostfunc`).

```pascal
TWasmFuncKind = (wfkWasm, wfkHost);

TWasmFuncInst = record
  Kind: TWasmFuncKind;
  { Engine-global canonical type id — the thing call_indirect compares.
    "It is an invariant of the semantics that all types occurring during
    execution are closed" (exec-type). }
  TypeId: TWasmEngineTypeId;
  { The heap handle returned by ref.func (§2.1). }
  RefObject: TWasmRef;
  case TWasmFuncKind of
    wfkWasm: (
      Instance: TWasmModuleInstance;   { borrowed }
      FuncIrIndex: UInt32;             { index into Ir.Functions }
    );
    wfkHost: (
      Callback: TWasmHostFunc;
      HostData: Pointer;               { opaque to the runtime }
    );
end;

{ Params and Results are frame slices the trampoline owns; the callee
  writes results in place. Raising EWasmTrap from a host function is
  legal and is the host's way to trap — §5.6. }
TWasmHostFunc = procedure(const AStore: TWasmStore;
  const AData: Pointer; const AParams: PWasmValue;
  const AResults: PWasmValue);
```

`FuncIrIndex` indexes `Ir.Functions` (defined functions, code order);
`Instance.FuncAddrs` is indexed by the *module* function index (imports
first). Conversion: `IrIndex = ModuleIndex - Ir.FuncImportCount`, and
`Ir.FuncIsImported[ModuleIndex]` is the check. **Store the IR index, not
the module index** — the runtime should never re-derive that offset on
the call path.

### 2.5 Engine-wide canonical type re-interning

This is the piece the whole GC track leans on, and the interfaces for it
already exist.

**Why.** `Wasm.Validator.Types` produces module-local canonical ids and
says so ("Canonical ids produced here are MODULE-LOCAL. Track D needs
engine-global ids for `call_indirect`'s runtime type check and for
import/export linking, so every group's serialised key is retained"). The
spec agrees: "Runtime type checks generally involve types from multiple
modules or types not defined by a module at all, such that any
module-local type indices occurring inside them would not generally be
meaningful" (`exec-type`), and module allocation for types "is defined in
terms of rolling and substitution of all preceding types to produce a
list of closed defined types" (`alloc-module`).

**The engine table.**

```pascal
{ Wasm.Runtime.Store — TWasmEngine outlives every store built on it }

TWasmEngineTypeId = UInt32;

TWasmEngineType = record
  Comp: TWasmCompType;        { concrete heap types name ENGINE ids }
  IsFinal: Boolean;
  Display: array of TWasmEngineTypeId;   { root first, self last }
  Depth: UInt32;
  Kind: TWasmCompKind;        { hoisted out of Comp for the hot path }
end;

TWasmEngine = class
  Types: array of TWasmEngineType;
  { intern table over rolled GROUP keys → base id, same shape as
    TWasmTypeContext's private one: parallel arrays, u32 hash pre-reject,
    linear scan. Promote to real buckets only on measurement. }
  GroupHashes: array of UInt32;
  GroupKeys:   array of TWasmBytes;   { OWNED copies — see below }
  GroupBases:  array of TWasmEngineTypeId;
  GroupSizes:  array of UInt32;
  GroupCount:  Integer;
end;
```

**Algorithm — `EngineInternModule(E, Ir) → EngineTypeIds`.** Runs once
per (engine, IR module) pair, at first instantiation, and the result is
cached on the IR module so a second instantiation is free.

```text
for each group g in 0 .. High(Ir.GroupKeys):
    key := Ir.GroupKeys[g]                  { already rolled: internal
                                              type indices are group-
                                              relative rec indices,
                                              per aux-roll-rectype }
    h   := Hash32(key)
    if LookupGroup(E, h, key) → base:
        BaseOf[g] := base                   { hit: nothing allocated }
    else:
        base := Length(E.Types)
        SetLength(E.Types, base + GroupSizeOf(g))
        E.Types[base .. base+n-1] := <materialised, see below>
        AddGroup(E, h, CopyOf(key), base, n)
        BaseOf[g] := base

{ then the per-type-index remap the instance carries }
for each module type index x:
    localCanon := Ir.TypeIndexToCanon[x]
    (g, k)     := GroupAndMemberOf(localCanon)
    EngineTypeIds[x] := BaseOf[g] + k
```

Three details that are load-bearing:

- **The key must be the rolled form**, and it already is: the group key
  is `TWasmTypeContext.SerialiseGroup`'s output, where "internal type
  indices become group-relative recursive type indices
  (`aux-roll-rectype`, `syntax-rectypeidx`)". That is exactly what makes
  two structurally identical groups from two different modules hash and
  compare equal. **Do not re-serialise from the IR's `CanonTypes`** —
  those carry module-local ids and would defeat the whole mechanism.
- **Materialising a group needs the rec-index → engine-id substitution.**
  A group member's `Comp` in `Ir.CanonTypes` names module-local canonical
  ids. Rewriting to engine ids is a walk over every value type in the
  composite, mapping each concrete heap type `c` through
  `BaseOf[GroupOf(c)] + MemberOf(c)`. Members of the group *currently
  being interned* map through the `base` just assigned — which is why
  `base` is computed and `SetLength` done **before** materialisation.
  Groups referenced by an earlier index are already in `BaseOf`
  (canonicalisation is incremental and forward references are invalid —
  `valid-type`, and `Wasm.Validator.Types`' `CheckMemberWellFormed`).
- **`GroupKeys` must be copied into the engine.** `TWasmIrModule` may be
  freed while the engine lives. The key is a small `TWasmBytes`; copy it.
  This is the one place in Track D that deliberately owns rather than
  borrows.

**Displays live in the engine, not in the instance.** `E.Types[i].Display`
is the ancestor chain in **engine** ids, rebuilt at intern time from
`Ir.CanonTypes[..].Display` under the same substitution. The runtime
subtyping check (§7.7) reads only `E.Types`, never a module. This is what
makes `ref.cast` work across modules — the point of the whole exercise.

**Growth is monotone.** Engine types are never removed. A long-lived
engine instantiating many distinct modules grows its type table; that is
the price of O(1) cross-module casts, and it is bounded by the number of
*distinct* rec groups ever seen, not by module count.

### 2.6 Thread confinement (ADR-0008)

`OwnerThreadId` is recorded at store creation and checked at each public
entry point **in non-`PRODUCTION` builds only** (`Shared.inc` already
splits on `PRODUCTION`). ADR-0008 says violation "is undefined behaviour
rather than a detected error unless a debug-build check makes it
detectable" and that detecting it is "a deliberate feature with a cost".
A debug-only check is that feature at zero production cost. It raises
`EWasmError` (not a trap — it is a host misuse, not a guest fault).

---

## 3. Linear memory — the chokepoint

### 3.1 The strategy matrix (ADR-0013)

| | 64-bit host | 32-bit host |
| --- | --- | --- |
| i32 memory | guard pages, no check | explicit checks |
| i64 memory | guard-assisted explicit checks | explicit checks + index-width reduction |

**Plus one staging decision, made here:**

> **STAGING DECISION — Windows takes explicit bounds checks in this
> wave, on every memory, regardless of bitness.**
>
> ADR-0005 permits strategy selection by platform and names explicit
> checks as "the fallback path, not a discarded option: targets that
> cannot reserve the address space use it." Windows *can* reserve the
> address space; what it cannot do without an SEH filter is convert the
> resulting access violation into a trap, and ADR-0009's Windows leg
> ("structured unwind") is unbuilt. Shipping guard pages on Windows
> before the SEH filter exists means an access violation crashes the
> process instead of trapping — a correctness regression that CI would
> catch as a hard failure on the `i386-win32` and x86-64 Windows legs.
>
> This is **deliberate, temporary, and observationally invisible**: both
> strategies must trap identically (ADR-0005, ADR-0010), so a Windows
> build differs from a Linux build only in speed. Revisit when the trap
> path grows its SEH filter; the strategy selector (§3.2) is one
> function and the change is one line in it.
>
> Recorded so it is a decision in writing rather than an omission
> discovered later.

Selection is **static, per memory, at instantiation**, from
`(platform, memtype.Limits.AddrType)` and nothing else — never from
runtime state, never per tier (ADR-0013: "the strategy matrix is
decidable from (platform, memory's address type) alone, so every tier —
and an AOT artifact — can emit the access sequence with no runtime
knowledge").

### 3.2 The memory instance

```pascal
{ Wasm.Runtime.Memory }

TWasmMemStrategy = (
  wmsGuardPages,      { i32 memory, 64-bit POSIX: reservation covers all }
  wmsGuardAssisted,   { i64 memory, 64-bit POSIX: check, offsets fold }
  wmsBoundsChecked    { everything else: 32-bit hosts, Windows (staged) }
);

WASM_PAGE_SIZE = 65536;                 { page-size }
WASM_MAX_I32_PAGES = 65536;             { 4 GiB — MSG_MEMORY_SIZE_LIMIT }

{ Named tunables. ADR-0013: "Guard size, reservation policy (including
  whether growth remaps), and the offset threshold above which an access
  gets a full-precision check are implementation constants tuned by
  wasmbench measurements, deliberately not pinned here." }
WASM_GUARD_BYTES        = 2 * 1024 * 1024 * 1024;  { 2 GiB, 64-bit }
WASM_I32_RESERVE_BYTES  = 4 * 1024 * 1024 * 1024;  { 4 GiB }
WASM_STATIC_OFFSET_FOLD = WASM_GUARD_BYTES;        { offsets <= this fold }

TWasmMemoryInst = record
  { --- the hot fields, first, in one cache line ---------------------- }
  Base:      PByte;        { byte 0 of the accessible region }
  ByteSize:  UInt64;       { current size in BYTES = Pages*WASM_PAGE_SIZE }
  { --- cold ---------------------------------------------------------- }
  Strategy:  TWasmMemStrategy;
  AddrType:  TWasmAddrType;
  Pages:     UInt64;
  MaxPages:  UInt64;       { effective max; see §3.6 }
  HasMax:    Boolean;
  ReserveBase: Pointer;    { mmap base — may differ from Base? NO: equal.
                             kept separately so munmap gets the right ptr }
  ReserveBytes: NativeUInt;{ what to munmap / VirtualFree }
  Committed: NativeUInt;   { bytes currently RW (guard strategies) }
end;
```

`Base` and `ByteSize` are adjacent and first because every access reads
both, and ADR-0013 requires "the bound is loaded from the instance, so a
moved memory is transparent to the check."

### 3.3 The one access API

**Every** consumer — the interpreter, the JIT's runtime helpers, host
memory reads, `memory.init`, `memory.copy`, `memory.fill`,
`array.new_data`, the embedding API's byte accessors, and the `.wast`
runner — goes through these and nothing else. ADR-0005: "a new caller
that bypasses the chokepoint is the failure mode this design is most
exposed to."

```pascal
{ Address resolution. Returns a pointer into the memory, or traps.
  ASize is the access width in bytes (1/2/4/8/16). AOffset is the static
  offset immediate. AIndex is the dynamic index, already widened to u64
  by the caller (the caller knows the address type statically). }
function MemAddress(var AMem: TWasmMemoryInst;
  const AIndex: UInt64; const AOffset: UInt64;
  const ASize: NativeUInt): PByte; inline;

{ Range form, for the bulk ops. Traps if the whole range is out. }
function MemRange(var AMem: TWasmMemoryInst;
  const AIndex: UInt64; const ALength: UInt64): PByte; inline;

{ Explicit check with no pointer, for a caller that will do its own
  pointer arithmetic (the JIT's fold path). }
procedure MemCheck(var AMem: TWasmMemoryInst;
  const AIndex, AOffset, ASize: UInt64); inline;
```

Semantics of `MemAddress`, by strategy:

```text
wmsGuardPages:      { i32 memory, 64-bit POSIX }
    { AIndex is u32-widened, AOffset <= 2^32-1 from the encoding, so
      AIndex+AOffset+ASize < 2^33 < reserve+guard. No check, no branch.
      The MMU faults into §5. }
    Result := AMem.Base + AIndex + AOffset

wmsGuardAssisted:   { i64 memory, 64-bit POSIX }
    if AOffset <= WASM_STATIC_OFFSET_FOLD then
        { offset absorbed by the guard: one offset-INDEPENDENT compare,
          deduplicable across many accesses through the same base }
        if AIndex >= AMem.ByteSize then Trap(...)
    else
        { full precision, unsigned, overflow-safe }
        if (AIndex > AMem.ByteSize) or
           (AOffset + ASize > AMem.ByteSize - AIndex) then Trap(...)
    Result := AMem.Base + AIndex + AOffset

wmsBoundsChecked:   { 32-bit hosts, and Windows this wave }
    { on 32-bit with an i64 memory: index-width reduction FIRST }
    if (32-bit host) and (AddrType = watI64) and (AIndex shr 32 <> 0) then
        Trap(...)
    if (AIndex > AMem.ByteSize) or
       (AOffset + ASize > AMem.ByteSize - AIndex) then Trap(...)
    Result := AMem.Base + AIndex + AOffset
```

**The overflow-safe comparison form is mandatory.** Write
`AOffset + ASize > AMem.ByteSize - AIndex` guarded by
`AIndex > AMem.ByteSize`, never `AIndex + AOffset + ASize > ByteSize` —
the latter wraps for large `AIndex` on i64 memories and admits an
out-of-bounds access. `AOffset + ASize` cannot overflow u64 (offset is
u64-encoded but bounded by the encoding, size ≤ 16); assert it in a
debug build.

**`MemAddress` is `inline` and holds no managed state** — it sits between
the trampoline and the fault (ADR-0009's skipped-frame rule).

### 3.4 Reservation plan — macOS and Linux, 64-bit

`wmsGuardPages` (i32 memory):

```text
reserve = WASM_I32_RESERVE_BYTES + WASM_GUARD_BYTES        { 6 GiB }
p = mmap(nil, reserve, PROT_NONE,
         MAP_PRIVATE or MAP_ANONYMOUS or MAP_NORESERVE, -1, 0)
    { macOS has no MAP_NORESERVE; it is a no-op flag there and the
      mapping is lazily backed anyway. Do not pass MAP_JIT. }
mprotect(p, initial_pages * WASM_PAGE_SIZE, PROT_READ or PROT_WRITE)
Base = p;  ReserveBase = p;  ReserveBytes = reserve;  Committed = initial
```

A 4 GiB reservation covers every address an i32 memory can name; the
2 GiB guard on top covers the static offset immediate (u32-encoded, so
at most 4 GiB−1 — see §3.4.1). Everything past `Committed` is `PROT_NONE`
and faults.

**§3.4.1 — the offset-immediate hole, and its fix.** A `memarg` offset
is `u64` in 3.0's encoding, and even restricted to u32 an offset near
2³²−1 added to an index near 2³²−1 reaches ~8 GiB — past a 4 + 2 GiB
reservation. Two mitigations, both required:

1. The validator has already rejected nothing here — the offset is not a
   validation error. So the **runtime** must handle it: at instantiation,
   memories are fine; the obligation is on the *access*. Under
   `wmsGuardPages`, `MemAddress` takes the fold path only when
   `AOffset <= WASM_STATIC_OFFSET_FOLD`; a larger offset falls through to
   the full-precision check, exactly as `wmsGuardAssisted` does. This is
   one predictable branch on a static immediate, and a JIT resolves it at
   compile time to a check or no check.
2. Size the guard from the fold threshold, not the other way round:
   `WASM_STATIC_OFFSET_FOLD = WASM_GUARD_BYTES` keeps the two in sync by
   construction. Changing the guard changes the threshold; there is no
   second place to update.

`wmsGuardAssisted` (i64 memory, current-size + guard remap):

```text
reserve = current_bytes + WASM_GUARD_BYTES
p = mmap(nil, reserve, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0)
mprotect(p, current_bytes, PROT_READ|PROT_WRITE)
```

The guard exists solely so static offsets fold; the index is always
checked. On growth the reservation is remapped (§3.5).

`wmsBoundsChecked`: plain allocation.

- POSIX: `mmap(nil, bytes, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`.
- Windows: `VirtualAlloc(nil, bytes, MEM_RESERVE or MEM_COMMIT, PAGE_READWRITE)`.
No guard region — nothing reads past the bound because the check is
unconditional.

**A zero-page memory has `Base <> nil`.** `mmap` of 0 bytes fails; a
0-page memory reserves one system page and sets `ByteSize := 0`. Every
access then traps on the check (or on the `PROT_NONE` page under a guard
strategy) and `Base + 0` is a valid, dereferenceable-nowhere pointer.
This removes a nil-check from `MemAddress`.

**Reservation registry.** Every mapping's `[ReserveBase, ReserveBase +
ReserveBytes)` is inserted into the process-wide registry of §5.3 at
creation and removed at destruction. **This is not optional**: it is the
only way the signal handler can decide a fault is ours.

### 3.5 Growth

`memory.grow n` (`exec-memory.grow`, `can_trap: false` — it returns −1 on
failure, it does not trap):

```text
old := Pages
if HasMax and (old + n > MaxPages)          → return -1
if old + n > address-type ceiling           → return -1   { §3.6 }
case Strategy of
  wmsGuardPages:
      { in place, always — the 4 GiB reservation already covers it }
      mprotect(Base + old*PAGE, n*PAGE, PROT_READ|PROT_WRITE)
      on failure → return -1
  wmsGuardAssisted:
      { REMAP. ADR-0013: "Growth of an i64 memory may remap. The bound
        is loaded from the instance, so a moved memory is transparent
        to the check." }
      if (old + n)*PAGE + GUARD <= ReserveBytes then
          mprotect in place                        { fits the guard }
      else
          Linux:  mremap(ReserveBase, ReserveBytes, newReserve, MREMAP_MAYMOVE)
          macOS:  new mmap + memcpy(old bytes) + munmap(old)
                  { no mremap on macOS; the copy is the cost of the
                    strategy and wasmbench must measure it }
          update Base, ReserveBase, ReserveBytes, deregister+register
  wmsBoundsChecked:
      new allocation + copy + free, or ReAllocMem
end
Pages := old + n;  ByteSize := Pages * WASM_PAGE_SIZE
return old
```

**Bound reload is mandatory.** Any code holding a cached `Base` or
`ByteSize` across a `memory.grow`, a host call, or **any safepoint**
(§7.6) must reload both from the instance afterwards. This is the single
most likely miscompile in Tracks E/I; write it into the tier contract:

> **Tier contract MEM-1.** `Base` and `ByteSize` may be cached only
> within a straight-line region containing no call, no `memory.grow`,
> and no safepoint. Every such region reloads on entry.

**Growth must not run the collector.** Linear memory is not GC heap. If
growth is ever made to trigger a collection, MEM-1's safepoint clause
already covers it — but the recommendation is: do not.

### 3.6 memory64 clamping

An i32 memory's size is capped at `WASM_MAX_I32_PAGES` (65536 pages =
4 GiB) — the validator already enforces the *declared* limit with
`MSG_MEMORY_SIZE_LIMIT` (`'memory size must be at most 65536 pages
(4GiB)'`). The runtime re-derives the ceiling for `memory.grow`:

```text
ceiling(watI32) = 65536
ceiling(watI64) = 2^48 / WASM_PAGE_SIZE = 2^32      { see below }
```

> `UNCONFIRMED` — the numeric page ceiling for an i64-addressed memory.
> `syntax-memtype` says only "The limits are given in units of page
> size" and `syntax-limits` says "If no maximum is present, then the
> respective storage can grow to any valid size"; the served text gives
> no i64 bound. The existing `Wasm.Validator.Types` already carries
> "memory/table limit numeric bounds" as an unconfirmed item (HANDOFF).
> **Track D must not invent a second answer** — it reads whatever
> ceiling the validator enforced. Until Track C settles it, the runtime
> ceiling is: whatever `memtype.Limits.Max` says when present, else the
> allocator's own failure (`return -1`). ADR-0013 explicitly *rejected*
> an implementation-defined cap ("an embedder-visible size cap is a
> public-contract decision that must not ride in on a bounds-check
> optimisation"), so **no constant cap is introduced here.**

`MaxPages` is computed once at instantiation as
`min(declared max if present, ceiling)` and never recomputed.

### 3.7 Trap reporting from the chokepoint

Every trap the chokepoint raises carries the same message,
`'out of bounds memory access'` — confirmed from `i32.load` and
`memory.init` (`instruction_get`, both name that trap). It reaches the
host by exactly one of two routes, and they must be indistinguishable
above the chokepoint:

- **Explicit check** (`wmsGuardAssisted`, `wmsBoundsChecked`): the check
  calls `TrapNow(wtkMemoryOutOfBounds)`, which records the kind in the
  trampoline record and `siglongjmp`s (§5.4). It does **not** raise a
  Pascal exception at the fault site — that would put managed state on a
  skippable frame.
- **Guard fault** (`wmsGuardPages`): SIGSEGV/SIGBUS → handler → attribute
  → record `wtkMemoryOutOfBounds` → `siglongjmp` (§5.2–5.4).

Both land in the trampoline, which raises one `EWasmTrap` with one
message. ADR-0005: "a module must trap identically under either."

---

## 4. Tables, globals, tags

### 4.1 Tables

"A table instance … records its type and holds a sequence of reference
values … It is an invariant of the semantics that all table elements
have a type matching the element type of tabletype" (`syntax-tableinst`).

```pascal
TWasmTableInst = record
  Elems:    array of TWasmRef;   { GC-visible root array — §7.5 }
  TableType: TWasmTableType;     { RefType + Limits (incl. AddrType) }
  MaxSize:  UInt64;              { effective, min(declared, ceiling) }
end;
```

- **Elements are `TWasmRef`, uniformly** — funcref, externref, anyref,
  exnref, all the same 8/4-byte slot with the §1.3 encoding. The element
  type is static (`TableType.RefType`) and the validator already checked
  every write against it; the runtime performs **no** element type check
  on `table.set`. The one exception is `table.init` from an element
  segment, where the segment's type was likewise validated.
- **Bounds.** `table.get` / `table.set` trap `'out of bounds table
  access'` (confirmed: `table.get` `instruction_get`); `table.init` /
  `table.copy` / `table.fill` the same (confirmed: `table.init`).
  `call_indirect` traps `'undefined element'` on an out-of-range index —
  a *different* message from `table.get`'s, confirmed from
  `call_indirect`'s trap table. Do not unify them.
- **Address type.** 3.0 parameterises tables over `addrtype` too
  (`syntax-addrtype`: "offsets into memories **and tables**"). The index
  arrives as u64; on a 32-bit host with an i64-addressed table apply the
  same index-width reduction as §3.3 before the bounds compare. Tables
  are always explicitly checked — there is no guard-page strategy for a
  table, because elements are references and cannot be faulted on.
- **Growth** (`table.grow`, returns −1 on failure, no trap):
  `SetLength` + fill the new tail with the supplied init value. A table
  grow **may move the array**, so tier contract MEM-1 applies verbatim to
  any cached `Elems` pointer. `table.grow`'s init value is a reference
  the collector must see across the reallocation — grow is a safepoint
  only if it can allocate; `SetLength` on a `TWasmRef` array cannot, so
  it is not. But the *value being installed* is a live root during the
  call; it lives in a frame register the stack map already covers.
- **Null semantics.** A defaultable table with no initialiser is filled
  with null (`aux-default`: "null for nullable reference types … For
  other references, no default value is defined"). A **non-nullable**
  element type therefore *requires* an initialiser — Track B already
  enforced that, and `TWasmIrModule.TableInits` carries the empty-entry
  sentinel (`Length(Code) = 0`) for tables without one. The runtime
  asserts: an empty init entry on a non-nullable table is an internal
  invariant violation (`EWasmError`), not a link error — the validator
  should have caught it.

### 4.2 Globals

"A global instance … records its type and holds an individual value"
(`syntax-globalinst`).

```pascal
TWasmGlobalInst = record
  Value:      TWasmValue;
  GlobalType: TWasmGlobalType;   { Mut + ValueType }
end;
```

- One flat array in the store. `global.get` / `global.set` are a slot
  read/write with no check — mutability and type were settled by
  validation (`MSG_GLOBAL_IS_IMMUTABLE`).
- **A global of reference type is a GC root** (§7.5), unconditionally,
  mutable or not.
- Imported globals are *shared*, not copied: `Instance.GlobalAddrs[i]`
  points at the exporting instance's global. A `global.set` through an
  imported mutable global is visible to the exporter. This falls out of
  addresses-are-indices and is the spec's model.

### 4.3 Tags

"A tag instance … records the defined type of the tag" (`syntax-taginst`).

```pascal
TWasmTagInst = record
  TypeId: TWasmEngineTypeId;     { engine-global — cross-module matching }
end;
```

That is the whole instance. Tag **identity is the address**: two tags
with identical types are different tags, and a `catch` matches on
`tagaddr` equality, not on type equality. `TypeId` exists for import
matching (§6.3) and for the payload arity/shape Track H needs.

Track D allocates tag instances and links them; **throwing is Track H**
(roadmap: "What is absent is the dynamic half"). §7.8 decides the
exception-object layout now.

---

## 5. The trap path (ADR-0009)

### 5.1 Shape

```text
  host
   └─ WasmInvoke(...)                 ← installs the trampoline (§5.4)
        sigsetjmp ────────────────────────────────┐
        └─ guest frames (NO managed Pascal state) │
             └─ MemAddress → fault                │
                  └─ SIGSEGV handler (§5.2)       │
                       attribute (§5.3)           │
                       record kind                │
                       siglongjmp ────────────────┘
        raise EWasmTrap(message)      ← ordinary ground
```

### 5.2 Handler installation

Per **process**, once, guarded by a module-level flag. Installed lazily at the
first guard-strategy memory creation — a store with no guard-page memory
(32-bit, Windows this wave) installs nothing.

```text
{ per process, once }
install with sigaction, SA_SIGINFO | SA_NODEFER
  for SIGSEGV and SIGBUS.
  - SIGBUS matters on macOS (and for truncated file-backed mappings);
    Linux delivers SIGSEGV for our case, macOS can deliver either.
  - The handler claims only registered linear-memory reservations, not host
    stack faults, so it deliberately does not request SA_ONSTACK. FPC 3.2.2's
    Linux fpSigAction also fails to install its required sa_restorer when that
    flag is supplied.
  - Chain to the previously installed handler when the fault is NOT
    ours (§5.3). Save the old sigaction and re-raise through it —
    never swallow a fault we did not cause.

```

**Handler body — the complete list of what it may do.** Async-signal
safety is the constraint; ADR-0009 rejected "raising a Pascal exception
directly from the handler" for exactly this.

1. Read `si_addr` from `siginfo_t`.
2. Look it up in the reservation registry (§5.3) — a read-only-during-
   execution array walk, no allocation, no lock.
3. If not ours: restore and chain to the saved handler; return.
4. If ours: write `wtkMemoryOutOfBounds` into the **current thread's**
   trampoline record, and `siglongjmp(record.JmpBuf, 1)`.

Nothing else. No formatting, no `Format`, no `IntToStr`, no `WriteLn`,
no allocation, no `SysUtils` call of any kind.

### 5.3 Fault attribution — the reservation registry

The handler must decide whether the faulting address is ours. Guessing
is not acceptable: swallowing an unrelated SIGSEGV turns a host bug into
a spurious wasm trap.

```pascal
{ Wasm.Runtime.Traps — process-global, ONE writer at a time }

TWasmReservation = record
  Base:  NativeUInt;
  Limit: NativeUInt;      { Base + ReserveBytes, exclusive }
end;

{ A fixed-capacity, append-and-tombstone array. NOT a dynamic array:
  the handler walks it, and a SetLength racing the walk is exactly the
  kind of hazard a signal handler cannot tolerate. Capacity grows by
  allocating a NEW array, copying, and publishing the pointer with a
  single aligned store; the old array is never freed (it is small and
  leaking it once per growth is cheaper than the alternative). }
```

Registration happens in §3.4 at map time and deregistration at unmap
time. Deregistration **must** precede `munmap` — otherwise a fault at a
freshly-unmapped-and-reused address is misattributed.

Lookup: linear scan over `Count` entries with two `NativeUInt`
comparisons each. Typical `Count` is the number of live guard-strategy
memories — small. If it ever is not, the fix is a sorted array plus
binary search, still allocation-free.

**Address masking is not a substitute.** Some engines reserve
alignment-constrained regions and test the fault address by mask. That
trick assumes a fixed reservation size, which `wmsGuardAssisted` (which
remaps to current size + guard) does not have. The registry works for
both.

### 5.4 The trampoline

```pascal
{ ONE per host→guest invocation. Lives on the Pascal stack of
  WasmInvoke, which is the frame siglongjmp returns to. }
TWasmTrapKind = (
  wtkNone,
  wtkUnreachable, wtkMemoryOutOfBounds, wtkTableOutOfBounds,
  wtkUndefinedElement, wtkUninitializedElement,
  wtkIndirectCallTypeMismatch, wtkNullReference,
  wtkDivideByZero, wtkIntegerOverflow, wtkInvalidConversion,
  wtkCastFailure, wtkArrayOutOfBounds, wtkAllocationFailure,
  wtkEpochInterrupt, wtkStackExhausted, wtkHostTrap
);

TWasmTrampoline = record
  JmpBuf:   jmp_buf;                 { sigjmp_buf }
  Prev:     PWasmTrampoline;         { nesting: host→guest→host→guest }
  Store:    TWasmStore;
  Kind:     TWasmTrapKind;
  Detail:   UInt32;                  { e.g. the mem/table index }
  HostMsg:  PAnsiChar;               { wtkHostTrap only; borrowed }
end;

{ Per-thread current trampoline. threadvar, NOT a store field: the
  handler has a thread but not a store. }
threadvar CurrentTrampoline: PWasmTrampoline;
```

`WasmInvoke`:

```text
tr.Prev := CurrentTrampoline;  tr.Kind := wtkNone;  CurrentTrampoline := @tr
if sigsetjmp(tr.JmpBuf, 1) = 0 then
    <enter guest>                          { the whole tier call }
    CurrentTrampoline := tr.Prev
    result := ok
else
    CurrentTrampoline := tr.Prev
    raise EWasmTrap.Create(TrapMessage(tr.Kind))   { ordinary ground }
```

`sigsetjmp(buf, 1)` — save the signal mask. Without it, returning from
the handler via `siglongjmp` leaves SIGSEGV blocked and the *next* fault
kills the process. This is the classic bug in this design; it costs a
`sigprocmask` per invocation and is not negotiable.

`TrapNow(kind)` — used by every explicit check — is:
`CurrentTrampoline^.Kind := kind; siglongjmp(CurrentTrampoline^.JmpBuf, 1)`.
It never returns. Mark it `noreturn` in spirit (FPC has no attribute;
the convention is that it is the last statement).

**Nesting.** A host function called from guest code may itself call
guest code. `Prev` chains them; each `WasmInvoke` unwinds only to its
own trampoline. A trap in the inner invocation raises `EWasmTrap` at the
inner trampoline, which is an ordinary Pascal exception propagating
through the host function's frame — and *that* frame is host code, which
may hold managed state, because it is above a trampoline.

### 5.5 The managed-state constraint (ADR-0009 amendment)

> **Tier contract TRAP-1.** Every Pascal frame between a trampoline and
> any point that can `siglongjmp` — i.e. every frame in guest execution
> — must hold **no** managed state: no `string`/`AnsiString`, no
> dynamic array local, no `interface`, no `try..finally` whose cleanup
> matters, no class instance whose destructor must run. A skipped frame
> never runs its implicit finalisation; FPC gives no diagnostic.

Practical rules that make this checkable rather than aspirational:

1. **No `string` locals or parameters in `Wasm.Runtime.Memory`,
   `Wasm.Runtime.Traps`' fault path, or any tier's execution loop.**
   Messages are `PAnsiChar` constants selected by `TWasmTrapKind` at the
   trampoline, after the jump. `TrapMessage` is a `case` returning a
   compile-time constant.
2. **No dynamic-array locals** in those units. Where a temporary buffer
   is needed, it is a fixed-size stack array or a field of a
   pre-allocated per-store scratch record.
3. **No `try..finally` in guest frames.** Resources acquired during
   guest execution must be owned by a structure the trampoline can clean
   up, or not acquired at all.
4. The frame arrays Track E allocates for guest calls are **not**
   per-call dynamic arrays: they are slices of one per-store stack
   buffer, so a skipped frame leaks nothing. Write this into the Track E
   contract now — it is the rule most likely to be violated by an
   obvious-looking implementation.
5. **Debug aid.** A non-`PRODUCTION` build can bracket the guest region
   with a counter of live managed allocations and assert it is unchanged
   after a trap. Cheap, and it turns a silent refcount corruption into a
   loud test failure.

### 5.6 Host functions and traps

A host callback raises `EWasmTrap` normally (it is ordinary Pascal
ground). The runtime's host-call thunk catches it, records
`wtkHostTrap` with the message pointer, and `siglongjmp`s to the current
trampoline — because the frames *between* the thunk and the trampoline
are guest frames and cannot be unwound by Pascal exception machinery
under TRAP-1. `exec-invoke-host` permits the host to fail; the mapping to
a trap is the embedder's, and this is ours.

### 5.7 Epoch interruption through the same path

ADR-0006's check is `if Store.Epoch <> LocalEpoch then TrapNow(wtkEpochInterrupt)`.
It surfaces at the trampoline like any other trap (ADR-0009: "the
trampoline is the single guest-entry chokepoint, so it is also where
epoch interruption surfaces"). `Store.Epoch` is a plain `UInt64` — no
atomic, because ADR-0008 confines the store; a host interrupting from
another thread is a *deliberate* cross-thread write of a single aligned
word, which is the one exception, and it is a write to a scalar the
guest only reads. Document it as such; do not generalise it.

> `UNCONFIRMED` — the canonical message for an epoch interrupt. It is
> not a spec trap (`impl-exec` makes runtime-limit exceedance
> "an embedder-specific error"). Proposed: `'interrupt'`. The corpus
> does not test it; the embedding API documents it.

---

## 6. Instantiation

### 6.1 The order, and where it comes from

"Instantiation checks that the module is valid and the provided imports
match the declared types, and may fail with an error otherwise.
Instantiation can also result in an exception or trap when initializing a
table or memory from an active segment or when executing the start
function" (`exec-module`).

The staging is spelled out in `aux-rundata`, and it is exactly the shape
Track D implements:

> "In practice, the initialization values can be determined beforehand by
> staging module allocation such that first, the module's own function
> instances are pre-allocated in the store, then the initializer
> expressions are evaluated in order, allocating globals on the way, then
> the rest of the module instance is allocated, and finally the new
> function instances' MODULE fields are set to that module instance."

and:

> "All failure conditions are checked before any observable mutation of
> the store takes place."

Therefore:

| # | Step | Failure mode |
| --- | --- | --- |
| 0 | Re-intern the module's rec groups into the engine (§2.5); build `EngineTypeIds` | internal (`EWasmError`) |
| 1 | Check import **count** matches the module's import count | `EWasmLinkError` |
| 2 | Check each import's **kind and type** (§6.3) | `EWasmLinkError` |
| 3 | Pre-allocate own function instances (addresses only; `Instance` field unset) | — |
| 4 | Evaluate global initialisers in order, allocating globals as it goes (§6.4) | trap (§6.4) |
| 5 | Evaluate table initialisers (`Ir.TableInits`) | trap |
| 6 | Evaluate element-segment item expressions (`Elem.Items`) | trap |
| 7 | Allocate memories, tables, elem instances, data instances | — |
| 8 | Build the module instance; back-patch step 3's `Instance` field | — |
| 9 | Apply **element** segments, in module order (§6.5) | trap |
| 10 | Apply **data** segments, in module order (§6.5) | trap |
| 11 | Record the pending start function (§6.6) | — |

Steps 1–2 precede any store mutation, satisfying `aux-rundata`'s
"all failure conditions are checked before any observable mutation."
Steps 9–10 *can* trap after mutation — the spec permits it explicitly
("Instantiation can also result in … a trap when initializing a table or
memory from an active segment"), and the resulting partially-initialised
store is observable. That is the spec's behaviour, not a defect.

**`.wast` note for Track C.** `assert_unlinkable` expects the link error;
`assert_trap` on a `(module ...)` command expects the segment/start trap.
The split above puts each in the right class.

### 6.2 Why step 0 comes first

Import type checking compares an import's declared type against the
supplied instance's actual type, and both must be in **engine** space.
`aux-rundata`: "Checking import types assumes that the module instance
has already been allocated to compute the respective closed defined
types. However, this forward reference merely is a way to simplify the
specification. In practice, implementations will likely allocate or
canonicalize types beforehand, when compiling a module, in a stage before
instantiation and before imports are checked." Step 0 *is* that stage.

### 6.3 Import matching — the external-typing rules

The relation is `externtype_1 <: externtype_2` (`match-externtype`,
formal rules `Externtype_sub/{func,table,mem,global,tag}`), applied as:
*the supplied instance's type must be a subtype of the declared import
type.*

**Honest note on sourcing.** The pinned `wasm-mcp` build serves the
`valid/matching` clauses with **empty prose** — they are SpecTec-
generated and the tool returns only the rule names. `match-externtype`,
`match-limits`, `match-tabletype`, `match-memtype`, `match-globaltype`
all came back with `"prose": ""`. What *is* served and citable:

- the rule names above, plus `Limits_sub` / `Limits_sub/*`,
  `Tabletype_sub`, `Memtype_sub`, `Globaltype_sub` / `Globaltype_sub/*`,
  `Tagtype_sub`, `Deftype_sub` / `Deftype_sub/refl` /
  `Deftype_sub/super`;
- that the relation is the one used "during module instantiation when
  checking the types of imports" (`subtyping`);
- `match-tagtype`'s prose, which says tag-type matching "invokes
  subtyping on defined types" in its premise;
- `match-deftype`'s prose: "there is no explicit definition of type
  equivalence, since it coincides with syntactic equality" — i.e. under
  canonicalisation, equality is engine-id equality;
- that `Globaltype_sub` and `Limits_sub` are **case-split** (the `/*`
  suffix), which is the structural signature of mutable-vs-immutable and
  max-present-vs-absent.

The variance directions below are therefore stated as **the
implementation contract**, each marked with its confidence.

```text
{ Wasm.Runtime.Store — MatchExternType }

func:    CONFIRMED-shape (Externtype_sub/func → Deftype_sub)
    supplied.TypeId = declared.TypeId
      OR EngineMatches(supplied.TypeId, declared.TypeId)   { §7.7 }
    { Deftype_sub/refl + Deftype_sub/super: a subtype is acceptable. }

limits:  UNCONFIRMED direction (Limits_sub, prose not served)
    supplied.Min >= declared.Min
    AND ( not declared.HasMax
          OR ( supplied.HasMax AND supplied.Max <= declared.Max ) )
    { The importer asks for AT LEAST Min and AT MOST Max. A supplier
      with no max cannot satisfy an importer that declares one — this
      is the INVERTED-VARIANCE trap: the max direction is the opposite
      of the min direction, and "no max" is INFINITY, so it fails a
      declared max rather than satisfying it. }
    { Address types must be EQUAL — an i32 memory does not satisfy an
      i64 import or vice versa (3.0 addrtype is part of limits). }

mem:     UNCONFIRMED (Memtype_sub)
    limits match, per above.

table:   UNCONFIRMED (Tabletype_sub)
    limits match AND EngineMatchesRefType(supplied.RefType,
                                          declared.RefType)
    { Table element type is COVARIANT in 3.0 (a table of (ref $sub)
      satisfies an import of (ref $super)) because table types were
      given a subtyping rule at all — a purely invariant rule would
      not need Tabletype_sub separate from equality. MARKED: this is
      an inference from the rule's existence, not from served text. }

global:  UNCONFIRMED direction (Globaltype_sub, CASE-SPLIT)
    if declared.Mut then
        supplied.Mut AND supplied.Type = declared.Type   { INVARIANT }
    else
        (not supplied.Mut) AND
        EngineMatchesValType(supplied.Type, declared.Type)  { covariant }
    { The second INVERTED-VARIANCE trap: a MUTABLE global is invariant
      in its value type — it is both read and written, so neither
      direction alone is sound — while an IMMUTABLE global is
      covariant. The Globaltype_sub/* case split is the evidence. A
      mutable global also cannot satisfy an immutable import in the
      other direction: mutability must match exactly, because a const
      import of a var global would let the exporter change it under
      the importer's feet. }

tag:     CONFIRMED-shape (Tagtype_sub, prose served)
    EngineMatches(supplied.TypeId, declared.TypeId)
    { match-tagtype: the premise "invokes subtyping on defined types". }
```

> These `UNCONFIRMED` markers stay in the source at the site, exactly as
> `Wasm.Validator.Types` does it. **Track C's `assert_unlinkable`
> corpus — 262 assertions — settles every one of them**, and it is the
> single highest-value external check Track D has. `linking.wast`,
> `imports.wast`, and `type-subtyping.wast` are the files.

**Error.** Every failure raises `EWasmLinkError`. Message family: §9.

### 6.4 The init-expression evaluator

`TWasmIrInitExpr` (`Wasm.Ir.pas`) is "NOT a function: it has no return
register block, no trailing `iroReturn`, and no handlers. Run
`Code[0..High]` and read `ResultReg`." That is the whole contract, and it
makes a ~60-line evaluator sufficient.

```pascal
{ Wasm.Runtime.Instantiate }

function EvalInitExpr(const AStore: TWasmStore;
  const AInst: TWasmModuleInstance;
  const AExpr: TWasmIrInitExpr): TWasmValue;
```

Frame: `array of TWasmValue` of length `AExpr.RegisterCount`, taken from
a per-store scratch buffer (TRAP-1 rule 4 — no per-call dynamic array).

The opcode set is **closed and small** — exactly what
`Wasm.Validator.Const` emits:

```text
iroI32Const iroI64Const iroF32Const iroF64Const
iroI32Add iroI32Sub iroI32Mul  iroI64Add iroI64Sub iroI64Mul
iroRefNull iroRefFunc iroRefI31
iroGlobalGet
iroStructNew iroStructNewDefault
iroArrayNew iroArrayNewDefault iroArrayNewFixed
iroAnyConvertExtern iroExternConvertAny
```

(Track G appends `v128.const`; the roadmap already notes it "*is* a
constant instruction in the spec". The evaluator's `else` branch must
therefore raise `EWasmError` with a clear "unsupported constant
instruction" rather than silently producing zero.)

Notes:

- **`iroGlobalGet` reads through `AInst.GlobalAddrs`**, and the
  validator's `GlobalLimit` windows already guaranteed the index refers
  only to an import (for table inits and element offsets) or to an
  earlier global. The evaluator does not re-check.
- **`iroRefFunc` returns the function instance's `RefObject`** (§2.1),
  which requires step 3 of §6.1 to have run — hence its position. This is
  the concrete reason the spec's staging note matters: "This is possible
  because validation ensures that initialization expressions cannot
  actually call a function, only take their reference" (`aux-rundata`).
- **The aggregate ops allocate**, so `EvalInitExpr` is a **safepoint
  region** (§7.6). Roots during it: the frame slots whose `RegTypes` say
  `wvkRef`, plus everything the partially-built instance already holds.
  §7.5's frame-walk contract covers init-expr frames identically to
  function frames — `TWasmIrInitExpr` carries `RegTypes`, and Track D
  computes the ref bits for it the same way `IrComputeRefRegBits` does
  for a function.
- **No trap can arise from the arithmetic ops** (add/sub/mul do not
  trap). The only trap sources are allocation failure and — for
  `iroArrayNew` with a huge length — an allocation the heap refuses.
- **`EvalInitExpr` must be callable with no tier present.** It is the
  reason §8's Wave 3 is testable without Track E.

### 6.5 Segment application — order and error class

**3.0 executes active segments as bulk-copy instructions.**
`aux-rundata`'s formal references are `rundata_` and `runelem_`, and the
clause sits directly under instantiation; `exec-module` states plainly
that instantiation "can also result in an exception or **trap** when
initializing a table or memory from an active segment."

**Therefore: an out-of-bounds active segment is a TRAP, not a link
error.** This is the point where earlier spec versions differed (MVP-era
implementations reported it at link time, and some engines still fold it
into instantiation failure). Under the pinned 3.0 draft it is a trap,
and it happens *after* store mutation — earlier segments in the same
module have already been written.

- The trap message is `'out of bounds memory access'` for data
  (confirmed: `memory.init` `instruction_get`) and `'out of bounds table
  access'` for elements (confirmed: `table.init`).
- **Order is module order**, segment by segment, elements before data.
  Within a segment, the copy is atomic in the sense that a trapping
  segment writes nothing (the range check precedes the copy) — which
  matches `memory.init`'s semantics, where the bounds check is on the
  whole range.

> `UNCONFIRMED` — that elements are applied strictly before data. The
> served text does not order the two relative to each other; the
> reference interpreter's `instantiate` does elements then data. The
> observable difference is only *which* trap fires when both would.
> Track C's `elem.wast` / `data.wast` settle it.

After application, an active segment is **dropped**: the elem instance's
list is emptied and the data instance's span is zeroed with
`Dropped := True`. This is what lets `BorrowsBuffer` (§2.3) go false.

### 6.6 The start function — deferral

`Ir.HasStart` / `Ir.StartFuncIndex`. Track D has no tier and cannot run
it (roadmap: Track E "needs D"). Therefore:

- Instantiation records `HasPendingStart := Ir.HasStart` and
  `PendingStartFuncIndex`.
- Instantiation **succeeds**. It does not raise. A module with a start
  function instantiates to a complete, inspectable store.
- `TWasmStore.RunPendingStart(Instance)` is the entry point. With no tier
  registered it raises `EWasmError` with a message naming the missing
  capability — explicitly **not** `EWasmTrap` and **not**
  `EWasmLinkError`, because neither is true: the module linked, and no
  guest code faulted. Proposed message:
  `'start function requires an execution tier (Track E)'`.
- When Track E lands, `RunPendingStart` invokes through `WasmInvoke`
  (§5.4) and a trap in the start function propagates as `EWasmTrap`,
  matching `exec-module`.
- `Wasm.Runtime.Store` exposes `TierInvoke: TWasmTierInvokeProc` — a
  single procedure variable, nil until Track E sets it. This is the
  entire tier seam as far as Track D is concerned, and keeping it to one
  field is deliberate.

---

## 7. The collector (ADR-0011)

### 7.1 Heap object layout

Every GC-heap object begins with one header word.

```pascal
{ Wasm.Runtime.Gc }

TWasmObjKind = (
  wokStruct,     { struct instance — syntax-structinst }
  wokArray,      { array instance — syntax-arrayinst }
  wokFuncRef,    { funcref handle — §2.1 }
  wokHostBox,    { externref of a host value — §1.3 }
  wokExn         { exception instance — syntax-exninst, §7.8 }
);

{ 64-bit header, both bitnesses (on 32-bit it is two words):

    bits  0..1   Kind-class / mark state:
                   bit 0 = MARK      (flipped per cycle, or forwarding)
                   bit 1 = FORWARDED (copying collector only)
    bits  2..4   TWasmObjKind (3 bits, 5 values)
    bits  5..31  reserved / array length low bits — see below
    bits 32..63  engine canonical type id (TWasmEngineTypeId, u32)

  The engine type id is in the HIGH half so that the O(1) subtype check
  (§7.7) is one shift and one array index, with no masking. }

TWasmObjHeader = record
  Bits: UInt64;
end;
```

Layout by kind:

```text
wokStruct:   [header:8][field 0][field 1]...      { §7.2 packing }
wokArray:    [header:8][length:8][elem 0]...      { length is a
                                                    SEPARATE word: an
                                                    array length is u32
                                                    but the header's
                                                    spare bits are 27,
                                                    which is not enough }
wokFuncRef:  [header:8][funcaddr:4][pad:4]
wokHostBox:  [header:8][payload:NativeUInt][release:Pointer]
wokExn:      [header:8][tagaddr:4][argc:4][arg 0]...   { §7.8 }
```

**Alignment: 8 bytes on both bitnesses.** This is what reserves bit 0 of
every object pointer for §1.3's i31 tag. It is a hard invariant of the
allocator, not a preference.

**The header does not store object size.** Size is derived from
`Kind` + the engine type (struct: field count and packing from
`E.Types[id].Comp.Struct`; array: `length` word × element size). This is
one indirection on the sweep/scan path in exchange for 4–8 bytes per
object, and object counts in a GC workload are large. If measurement
says otherwise, the spare header bits 5..31 are where a size cache goes.

### 7.2 Field packing (i8/i16)

`aux-packfield` / `aux-unpackfield` define the conversion both ways; a
field's storage is `TWasmStorageType` (`IsPacked` + `PackedType`), and
packed types "are NOT value types and never appear on the operand stack"
(`Wasm.Core.pas`).

Layout rule, chosen for simplicity over density:

```text
storage width:  wpkI8 → 1 byte, wpkI16 → 2 bytes,
                i32/f32 → 4, i64/f64 → 8, ref → SizeOf(TWasmRef),
                v128 → 16 (Track G)

Fields are laid out in DECLARATION ORDER, each at the next offset that
is a multiple of its own width, with the object's total size rounded up
to 8. Offsets are computed ONCE per engine type at intern time and
cached in TWasmEngineType.FieldOffsets: array of UInt32.
```

Declaration order (rather than size-sorted) is required: struct subtyping
extends a struct by **appending** fields (`Structtype_sub`), so a
subtype's prefix must have the identical layout to its supertype, or
`struct.get` through a supertype-typed reference reads the wrong bytes.
This is the single most important consequence of GC subtyping on layout,
and size-sorting silently breaks it.

`struct.get_s` / `struct.get_u` sign- or zero-extend from the packed
width (`aux-unpackfield`); `struct.set` truncates (`aux-packfield`).

**Reference fields must be identifiable without a per-object map.** Cache
a per-engine-type `RefFieldOffsets: array of UInt32` at intern time —
the offsets of exactly the fields whose storage is a `wvkRef` value
type. Tracing a struct is then a loop over that small array. Same for
arrays: one boolean `ElemIsRef` plus the element width.

### 7.3 Allocator — the recommendation

> **Recommendation: mark-sweep with segregated size classes and a free
> list, for v1. Not semispace copying.**

The trade, argued rather than asserted:

| Factor | Copying (semispace) | Mark-sweep |
| --- | --- | --- |
| Allocation cost | bump pointer — the fastest possible | free-list pop; segregated classes make it 3–4 instructions |
| Memory overhead | **2×**, permanently | ~1× plus fragmentation |
| Fragmentation | none | real, mitigated by size classes |
| Host refs | must be **pinned or indirected** — objects move | **no pinning needed** — objects never move |
| Root precision | must be exact *and* updatable (every root is written back) | must be exact, read-only |
| Interior pointers | forbidden (we have none) | forbidden (we have none) |
| Failure mode of a missed root | **silent memory corruption** (a stale pointer to a moved object) | a use-after-free, still bad, but the object is at least still there until swept |

The deciding factors, in order:

1. **Host roots.** ADR-0011 requires a root-registration mechanism, and
   ADR-0008 says "the embedding API can hand out raw pointers into linear
   memory for the duration of a host call without a borrow-tracking
   scheme." Linear memory is not GC heap, so that sentence does not
   cover GC objects — but the *expectation it sets* does. A non-moving
   collector lets a host hold a `TWasmRef` across a call with only a
   registration, no handle indirection, no read barrier. A copying
   collector forces every host reference through an indirection table
   (a handle), which is a permanent API tax on Track F.
2. **The cost of a missed root.** Track D is the first runtime code in
   this project; the root set has three producers (frames, globals/
   tables, host) and the frame walk depends on a contract Track E has
   not yet implemented. Under mark-sweep a missed root frees a live
   object — bad, and detectable by poisoning freed memory in a debug
   build. Under copying it *moves* the object and leaves a stale pointer
   that reads plausible garbage. The debuggability difference is large
   and it matters most exactly when the collector is new.
3. **2× overhead is a poor trade for a runtime whose pitch includes
   small targets** (ADR-0010's whole argument for keeping 32-bit).

Against: allocation is slower, and bump allocation is genuinely the
faster path for the allocation-heavy workloads GC languages produce.
The mitigation is that segregated free lists with a per-size-class
bump-within-block scheme recover most of it: a block is bump-allocated
until exhausted, then the next block comes off the class's list.

**Recorded escape hatch.** If `wasmbench` shows allocation dominating,
the upgrade is a *generational* collector with a bump-allocated copying
nursery and a mark-sweep mature space. That keeps mark-sweep's
non-moving property for anything that survives one collection — which is
everything a host can hold a reference to, if host registration promotes
— and gets bump allocation back. Designing for that now costs one thing:
**keep the write barrier hook in the API from day one** (§7.4), even
though v1's implementation is empty. Retrofitting a barrier means
touching every `struct.set` / `array.set` / `array.fill` / `array.copy`
site in three tiers, which is exactly the "expensive later" shape
ADR-0006 warns about.

```pascal
{ Wasm.Runtime.Gc — the v1 heap }

TWasmGcHeap = class
public
  function AllocStruct(const ATypeId: TWasmEngineTypeId): TWasmRef;
  function AllocArray(const ATypeId: TWasmEngineTypeId;
    const ALength: UInt32): TWasmRef;
  function AllocFuncRef(const AFuncAddr: TWasmFuncAddr;
    const ATypeId: TWasmEngineTypeId): TWasmRef;
  function AllocHostBox(const APayload: NativeUInt;
    const ARelease: TWasmHostRelease): TWasmRef;
  function AllocExn(const ATagAddr: TWasmTagAddr;
    const AArgCount: UInt32): TWasmRef;

  procedure Collect;                      { stop-the-world, full }
  { The barrier. EMPTY in v1. Present so the call sites exist. }
  procedure WriteBarrier(const AObj, AValue: TWasmRef); inline;

  { Direct API for Wave 5 testing — see §8. }
  property BytesAllocated: UInt64;
  property CollectionCount: UInt64;
end;
```

**Allocation failure.** `AllocX` triggers a collection first (§7.6), then
retries, then grows the heap, then `TrapNow(wtkAllocationFailure)`.
`impl-exec` makes exceeding "the number of allocated structure
instances" / "the size of an array instance" an embedder-specific error,
so the message is ours.

> `UNCONFIRMED` — the canonical message for allocation failure. The
> upstream corpus uses `assert_exhaustion` (15 assertions repo-wide) for
> stack exhaustion; whether a GC OOM appears there at all is unknown.
> Proposed: `'allocation too large'` for a single oversized request and
> `'out of memory'` for heap exhaustion.

### 7.4 The write barrier (empty in v1)

`WriteBarrier(obj, value)` is called by every reference-field store:
`struct.set`, `array.set`, `array.fill`, `array.copy`, `array.init_*`,
and `table.set` / `table.fill` / `table.copy` / `table.init` (tables are
root arrays, and a generational collector needs them in its remembered
set too). In v1 it compiles to nothing. Its existence is the whole point.

### 7.5 Root set enumeration

Four producers. All must be exact.

**(a) Interpreter frames — the contract Track E must satisfy.**

ADR-0011: "the stack map is a projection of information validation
computed anyway". The projection already exists:
`TWasmIrFunction.RefRegBits` is "Bit *i* set iff `RegTypes[i].Kind =
wvkRef`", computed by `IrComputeRefRegBits`.

> **Tier contract GC-1 (frame walk).** Track E maintains a per-store
> chain of active guest frames. Each entry provides exactly:
>
> ```pascal
> TWasmFrameRecord = record
>   Prev:  PWasmFrameRecord;
>   Slots: PWasmValue;              { the register file, RegisterCount long }
>   Fn:    PWasmIrFunction;         { for RefRegBits and RegisterCount }
>   Inst:  TWasmModuleInstance;     { the frame's instance }
> end;
> ```
>
> The collector walks `Prev` from the store's current frame and, for each
> frame, iterates the set bits of `Fn^.RefRegBits` over
> `[0, Fn^.RegisterCount)`, treating `Slots[i].Ref` as a root.
>
> Three obligations on Track E:
>
> 1. **Every register in `[0, RegisterCount)` whose `RegTypes` entry is a
>    ref must hold a valid `TWasmRef` (possibly null) at every
>    safepoint.** A register that has not been written yet must read as
>    null, so the frame is **zeroed at entry**. This is the single most
>    important line in this contract: an unzeroed frame slot is
>    indistinguishable from a live reference.
> 2. **The frame record is pushed before the first safepoint in the
>    function and popped after the last.** A frame that is live but not
>    on the chain is a lost root.
> 3. **Tail calls replace the frame in place** (roadmap: `return_call`
>    "require frame *replacement* with guaranteed O(1) stack growth").
>    Replacement must update `Fn` and `Slots` **atomically with respect
>    to safepoints** — i.e. not across one. Zero the new frame before
>    publishing it.
>
> Init-expression frames (§6.4) join the same chain, with a synthesised
> `TWasmIrFunction`-shaped view over `TWasmIrInitExpr`'s `RegTypes` and
> `RegisterCount`. Track D builds and walks those itself; they exist
> before Track E does.
>
> The same contract is what Tracks I and J must satisfy for JIT/AOT
> frames (ADR-0011: "Every tier must be able to produce a stack map at a
> safepoint. That is an obligation on the baseline JIT and the AOT
> compiler, not only on the interpreter"). Their `Slots`/`RefRegBits`
> come from a side table keyed by return address rather than from the
> frame, but the collector's walk is unchanged.

**(b) Globals of reference type.** Every `TWasmGlobalInst` where
`GlobalType.ValueType.Kind = wvkRef`. Precompute, per store, a dense
`RefGlobalAddrs: array of TWasmGlobalAddr` at instantiation so the scan
does not filter on every cycle.

**(c) Tables.** Every element of every `TWasmTableInst` — a table's
element type is always a reference type, so no filtering is needed. This
is the largest root source for a func-table-heavy module; a card-marked
or generationally-remembered table is the upgrade path, and §7.4's
barrier already covers the write sites.

**(d) Host roots — the registration API.** ADR-0011: "Host code holding a
reference across a call that can allocate needs a root registration
mechanism; raw Pascal pointers into the GC heap are not roots the
collector can see."

```pascal
{ Wasm.Runtime.Gc }

TWasmRootHandle = UInt32;
WASM_NO_ROOT = High(UInt32);

{ A slot in a store-owned array. The handle is an INDEX, so the array
  may grow without invalidating anything the host holds. }
function  RootRegister(const AStore: TWasmStore;
  const ARef: TWasmRef): TWasmRootHandle;
function  RootGet(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle): TWasmRef;
procedure RootSet(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle; const ARef: TWasmRef);
procedure RootRelease(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle);

{ Scoped convenience for the common case — a host function holding a
  reference across an allocation. Uses a stack discipline (a mark/
  release pair) so the common case costs one increment. }
function  RootScopeEnter(const AStore: TWasmStore): UInt32;
procedure RootScopeLeave(const AStore: TWasmStore; const AMark: UInt32);
```

The root array itself is a plain `array of TWasmRef` with a free list of
released indices. The collector scans `[0, RootCount)` and skips
tombstones (a released slot is set to null, which the scan ignores
anyway). Under a non-moving collector `RootGet` returns the pointer
directly with no read barrier — the payoff from §7.3.

**Track F must document this as mandatory**: a host that stores a
`TWasmRef` in its own structure without registering it has a
use-after-free, and there is no diagnostic.

**(e) Not roots.** Linear memory (references cannot be stored in
memories — `syntax-reftype`: "Values of reference type can be stored in
tables but not in memories"). Element instances **are** roots (they hold
references, `syntax-eleminst`) until dropped. Data instances are not.

### 7.6 Safepoint policy

ADR-0011 (amended): "Safepoints are the epoch-check locations from
ADR-0006 — loop back-edges and function entries — plus every allocation
site and every runtime call that can trigger collection. A `struct.new`
that finds the heap exhausted must be able to collect immediately, not
fail until the next back-edge."

> **Decision: in v1, collection is triggered at allocation sites only.
> Back-edges and function entries remain safepoints — they emit the
> epoch check and must be able to produce a stack map — but they do not
> poll for collection.**

Why:

- The collector is stop-the-world and single-threaded (ADR-0008 removes
  "concurrent marking, no write barrier for cross-thread visibility, and
  no cross-thread safepoint coordination"). There is no external agent
  that needs the mutator to stop; the *only* reason to collect is that
  an allocation needs memory. Polling at back-edges would be pure cost.
- ADR-0011's amendment exists to make allocation sites sufficient, not
  to make back-edges also collect.
- The obligation ADR-0011 does place on back-edges — *being able to
  produce a stack map* — is preserved exactly. Contract GC-1 holds at
  every safepoint, whether or not that safepoint collects. This keeps
  the door open: if a future generational collector wants a nursery-full
  poll at back-edges, the maps are already there and only the trigger
  changes.
- The one thing this decision forfeits is bounded pause-to-collect
  latency for a long allocation-free loop. Nothing in v1 needs it.

Recorded so Track I does not conclude the back-edge stack map is
optional. **It is not.** ADR-0006 and ADR-0011 share those locations
deliberately.

### 7.7 Runtime subtyping — `ref.test` / `ref.cast` / `br_on_cast*`

O(1), from the object header and the engine displays.

```text
RuntimeMatches(objTypeId, targetTypeId):
    dt := E.Types[targetTypeId].Depth
    do := E.Types[objTypeId].Depth
    Result := (dt <= do) and (E.Types[objTypeId].Display[dt] = targetTypeId)
```

This is the display test `Wasm.Validator.Types` already documents
("`A <= B` is `Depth(B) <= Depth(A) and Display(A)[Depth(B)] = B` —
constant time, which is what Track D's `ref.cast` wants on the hot
path", citing `match-deftype` rules `Deftype_sub/refl` and
`Deftype_sub/super`). The only difference is that the ids are engine
ids and the table is `TWasmEngine.Types`.

Full `ref.cast rt` on value `v`:

```text
if v = null then
    Result := rt.Nullable            { §1.3's argument }
else if v and 1 = 1 then             { unboxed i31 }
    Result := AbsHeapSubtype(wahI31, rt.Heap.Abs) when rt.Heap.IsAbstract
              else False             { i31 is never a concrete type }
else
    h := Header(v)
    if rt.Heap.IsAbstract then
        Result := AbsHeapSubtype(AbsKindOf(h.Kind, h.TypeId), rt.Heap.Abs)
    else
        Result := RuntimeMatches(h.TypeId, EngineIdOf(rt.Heap.TypeIndex))
```

`AbsHeapSubtype` is already exported from `Wasm.Validator.Types`
"because Track D's casts need it without a module in hand". `AbsKindOf`
maps a heap object to its abstract kind: `wokStruct → wahStruct`,
`wokArray → wahArray`, `wokFuncRef → wahFunc`, `wokHostBox → wahExtern`,
`wokExn → wahExn`. **Three disjoint hierarchies** (func / aggregate /
extern, plus exn) fall out of this map — a `wokFuncRef` never answers
true for `wahAny`, which is the property the roadmap flags as having to
be "modelled exactly".

`ref.cast` failing traps.

> `UNCONFIRMED` — the `ref.cast` failure message, and indeed **that
> `ref.cast` traps at all according to the served data**. `wasm-mcp`
> `instruction_get ref.cast` returns `can_trap: false, traps: []`, and
> `exec-ref.cast` returns empty prose (SpecTec: `Step_read/ref.cast`,
> `Step_read/ref.cast-*` — the `-*` variant being the failure case). The
> same gap appears across the whole GC family: `array.get`, `array.set`,
> `array.new_data`, `i31.get_s` all report `can_trap: false` while
> `call_ref`, `ref.as_non_null`, and `struct.get` correctly report
> `'null reference'`. **The served trap table is reliable for 1.0/2.0
> instructions and systematically incomplete for 3.0 GC instructions.**
> Treat every GC trap message as UNCONFIRMED and let Track C's
> `assert_trap` corpus settle them. Proposed: `'cast failure'` for
> `ref.cast`, `'out of bounds array access'` for array indexing,
> `'null reference'` for null aggregate access (that one is confirmed
> for `struct.get` and extends by symmetry).

### 7.8 Exception objects — layout now, behaviour in Track H

**Decision: define the layout in Track D; leave throw/catch to Track H.**

"An exception instance … holds the address of the respective tag and the
argument values" (`syntax-exninst`). That is a fixed shape and it costs
nothing to fix now, whereas discovering in Track H that `exnref` needs a
different heap-object kind means changing the header enum, the trace
loop, and the `AbsKindOf` map at a point where the collector is already
under test.

```text
wokExn:  [header:8][tagaddr:4][argc:4][arg 0 : TWasmValue]...
```

- The header's engine type id holds the **tag's** type id (the tag's
  functype), so `AbsKindOf` yields `wahExn` and casts behave.
- Arguments are `TWasmValue` slots. **Which of them are references is
  not derivable from the object** — it comes from the tag's functype
  params in `E.Types[TypeId].Comp.Func.Params`. Cache a
  `RefParamOffsets` array on the engine type at intern time, exactly as
  §7.2 does for struct fields, and the trace loop is uniform.
- `AllocExn` exists and is testable in Track D (allocate, trace,
  collect) without anything throwing. Track H adds the throw path,
  handler matching against `TWasmIrHandler`/`TWasmIrCatchClause`
  (already emitted by Track B), and the unwinder's epoch obligation
  recorded in `Wasm.Ir.pas`' `TWasmIrHandlers` comment.

### 7.9 Finalization and weak references — out of scope, verified

The pinned 3.0 draft has **neither**. Verified three ways against the
pin: `spec_search "finalization"` → 0 hits; `spec_search "weak"` → 2
hits, both about *weakening a type by subsumption* (`valid-instrs`,
`appendix/properties-compositionality`), neither about references;
`proposal_list contains:"weak"` → 0 proposals. The store clause's only
word on reclamation is that "implementations may apply techniques like
garbage collection or reference counting to remove objects from the
store that are no longer referenced. However, such techniques are not
semantically observable" (`syntax-store`).

So: no finalizers, no weak maps, no post-mortem callbacks, no
resurrection. The one adjacent obligation is `wokHostBox`'s `release`
callback, which is **not** a wasm-visible finalizer — it is the
embedder's hook to drop its own refcount when the box is swept, and
Track F decides whether to expose it. It must not be documented as a
finalization API.

---

## 8. Unit layout and wave plan

### 8.1 Units

Strictly bottom-up (`docs/architecture.md`: "each layer may use only the
layers below it"). New units, in dependency order:

| Unit | Depends on | Holds |
| --- | --- | --- |
| `Wasm.Runtime.Values` | `Wasm.Core` | `TWasmValue`, `TWasmRef`, the i31 encoding, null, `MakeRef*`/`RefIsNull`/`RefIsI31` |
| `Wasm.Runtime.Traps` | `Wasm.Core`, `.Values` | `TWasmTrapKind`, canonical messages, the reservation registry, signal handler, `sigsetjmp` trampoline, `TrapNow`, `WasmInvoke` |
| `Wasm.Runtime.Memory` | `Wasm.Core`, `.Values`, `.Traps` | `TWasmMemoryInst`, the strategy selector, `MemAddress`/`MemRange`/`MemCheck`, mmap/mprotect/VirtualAlloc, grow |
| `Wasm.Runtime.Gc` | `Wasm.Core`, `.Values`, `.Traps` | header, layout computation, allocator, mark-sweep, root registry, frame-walk driver, `RuntimeMatches` |
| `Wasm.Runtime.Store` | all above + `Wasm.Ir`, `Wasm.Validator.Types` | `TWasmEngine` + re-interning, `TWasmStore`, all instance records, tables/globals/tags, export lookup |
| `Wasm.Runtime.Instantiate` | `Wasm.Runtime.Store` | `EvalInitExpr`, import matching, the 11-step sequence, segment application, pending start |

Notes on the split:

- **`.Traps` sits below `.Memory`**, not beside it, because the memory
  chokepoint calls `TrapNow` and the reservation registry is the
  handler's, not the memory's. Inverting this creates a cycle.
- **`.Gc` does not depend on `.Store`.** The collector is driven *by*
  the store (the store hands it the root producers through a small
  callback record) rather than reaching into it. This is what makes
  Wave 5 testable with a synthetic root set and no store at all.
- **`Wasm.Validator.Types` is a dependency of `.Store` only**, for
  `TWasmTypeContext`'s canonical accessors and `AbsHeapSubtype`. Note
  that `Wasm.Ir` "depends on `Wasm.Core` alone"; the runtime is the first
  layer that legitimately sees both.
- Co-located suites throughout: `Wasm.Runtime.<X>.Test.pas`.

### 8.2 Waves

Each wave is independently mergeable, gate-green, and — the constraint
that shaped the ordering — **testable without Track E**.

**Wave 1 — values and traps.** `Wasm.Runtime.Values` +
`Wasm.Runtime.Traps`.
Delivers: `TWasmValue`, the i31/null encoding, the trap kind enum and
message table, the reservation registry, the trampoline, signal handler
installation.
Testable without an interpreter: the i31 round-trip over the full 31-bit
range including the boundaries (`-2^30`, `2^30-1`, `-1`, `0`, and the
wrap of `2^31`); null identity; that a pointer with bit 0 set is never
produced; registry insert/lookup/remove; and — the important one — a
**deliberate SIGSEGV inside a `WasmInvoke`** at an address inside a
registered reservation lands as `EWasmTrap` with the right message,
while one *outside* every reservation chains to the previous handler.
That last test is the whole trap path proven before any memory exists.

**Wave 2 — linear memory.** `Wasm.Runtime.Memory`.
Delivers: the strategy selector, all three strategies, `MemAddress` /
`MemRange` / `MemCheck`, growth including the i64 remap, the reservation
registry wiring.
Testable directly: create a memory instance by hand (no module, no
store), read and write through the chokepoint, walk the bound with the
classic off-by-one triple (`size-1` ok, `size` traps, `size-size` with a
large offset traps), verify the overflow-safe comparison with an index
near `2^64-1`, verify growth preserves contents and that `Base`/
`ByteSize` both updated, verify `memory.grow` past max returns −1 and
does not trap. **And the strategy-equivalence test**: the same access
sequence under `wmsGuardPages`, `wmsGuardAssisted`, and
`wmsBoundsChecked` on the same host must produce the same trap at the
same access — ADR-0005's identity requirement, made executable. Force
the strategy through a test-only override.

**Wave 3 — the engine type table and the init-expr evaluator.**
The re-interning half of `Wasm.Runtime.Store` + `EvalInitExpr`.
Delivers: `TWasmEngine`, `EngineInternModule`, `EngineTypeIds`,
`RuntimeMatches`, the evaluator.
Testable without an interpreter: validate two *different* modules that
declare structurally identical rec groups, intern both, assert the
engine ids are **equal** — the cross-module property nothing else can
check; assert distinct groups get distinct ids; assert the display test
agrees with `TWasmTypeContext.MatchesCanon` on every pair in a
module (a differential test against the already-tested validator
implementation, which is the cheapest high-coverage check available);
run every `Ir.GlobalInits` from the fixture corpus through the evaluator
and compare against expected values.

**Wave 4 — store, instances, tables, globals, tags, instantiation.**
The rest of `Wasm.Runtime.Store` + `Wasm.Runtime.Instantiate`.
Delivers: the full 11-step sequence, import matching, segment
application, pending start.
Testable without an interpreter: instantiate all 22 fixture modules and
assert the resulting store shape (counts per category, export names,
global values, table contents, memory contents at known offsets after
data application); import-matching negatives spelled as literal type
records next to the assertion, one per inverted-variance case (limits min
too small, limits max too large, supplier without a max against a
declared max, mutable-vs-immutable global both directions, mutable global
with a subtype value type, wrong address type); active-segment OOB
produces `EWasmTrap` with the right message and leaves earlier segments
applied; a module with a start function instantiates successfully and
`RunPendingStart` raises the tier-missing `EWasmError`.

**Wave 5 — the collector.** `Wasm.Runtime.Gc`, and the store wiring that
feeds it roots.
Delivers: layout computation, allocator, mark-sweep, root registry,
frame walk, `ref.cast` support.
Testable without an interpreter, via the direct allocation API: allocate
a known object graph through `AllocStruct`/`AllocArray`, register some
roots and not others, `Collect`, and assert exactly the unreachable set
was reclaimed (`BytesAllocated` delta, plus poison-on-free readback in a
debug build); cycles are collected (the correctness property ADR-0011
cites against refcounting); a host root survives; a released host root
does not; field packing round-trips for `i8`/`i16` signed and unsigned;
a subtype's field offsets match its supertype's prefix (§7.2's
load-bearing invariant); `RuntimeMatches` over a hand-built display
matches `AbsHeapSubtype` and `MatchesCanon`; a synthetic frame chain
(hand-built `TWasmFrameRecord`s over a hand-built `RefRegBits`) keeps
exactly the referenced objects alive — which proves contract GC-1
against a stub before Track E exists.

**Explicitly out of scope for every wave:** running any wasm function.
The first thing that executes guest code is Track E.

### 8.3 What `wasmbench` must gain

ADR-0009 requires it ("`wasmbench` must measure host-to-guest call
overhead so the cost is a number, not a guess") and ADR-0013 requires it
("the bounds-check path … is hot-path code on 64-bit hosts too, and
`wasmbench` must measure it"). Add, in Wave 2 and Wave 5:

- `WasmInvoke` round-trip on an empty guest region — the `sigsetjmp`
  cost ADR-0009 estimates at ~7%.
- `MemAddress` throughput under each of the three strategies.
- Allocation throughput and full-collection pause against a synthetic
  graph.

Measurement only — never a CI assertion (AGENTS.md).

---

## 9. Error classes and messages

### 9.1 The usage map

The hierarchy is load-bearing (AGENTS.md; `Wasm.Core.pas`: "never
collapse them").

| Condition | Class |
| --- | --- |
| Import count/kind/type mismatch at instantiation | `EWasmLinkError` |
| Missing import | `EWasmLinkError` |
| Active elem/data segment out of bounds | **`EWasmTrap`** (§6.5) |
| Start function traps | `EWasmTrap` |
| Any guest fault (memory, table, div, cast, null, unreachable) | `EWasmTrap` |
| Host function raising a trap | `EWasmTrap` |
| Epoch interrupt | `EWasmTrap` |
| GC allocation failure / heap exhaustion | `EWasmTrap` |
| Stack exhaustion | `EWasmTrap` |
| Start requested with no tier registered | `EWasmError` |
| Store touched from the wrong thread (debug builds) | `EWasmError` |
| IR internal invariant violated (e.g. missing table init for a non-nullable table) | `EWasmError` |
| Unsupported constant instruction in an init expr (SIMD, pre-Track-G) | `EWasmError` |

`EWasmDecodeError` and `EWasmValidationError` **never** originate in
Track D. A runtime unit raising either is a bug: it means the runtime
re-derived a rule the validator owns (ADR-0007).

### 9.2 Canonical message table

Confidence markers, using this repo's existing convention:

- **C** — served by `wasm-mcp` `instruction_get` at the pin.
- **U** — `UNCONFIRMED`; the marker stays in the source at the site and
  Track C's runner is what corrects it, in one place.

| Trap kind | Message | Conf. | Source |
| --- | --- | --- | --- |
| `wtkUnreachable` | `unreachable` | **C** | `unreachable` |
| `wtkMemoryOutOfBounds` | `out of bounds memory access` | **C** | `i32.load`, `memory.init` |
| `wtkTableOutOfBounds` | `out of bounds table access` | **C** | `table.get`, `table.init` |
| `wtkUndefinedElement` | `undefined element` | **C** | `call_indirect` |
| `wtkUninitializedElement` | `uninitialized element` | **C** | `call_indirect` |
| `wtkIndirectCallTypeMismatch` | `indirect call type mismatch` | **C** | `call_indirect` |
| `wtkNullReference` | `null reference` | **C** | `call_ref`, `ref.as_non_null`, `struct.get` |
| `wtkDivideByZero` | `integer divide by zero` | **C** | `i32.div_s` |
| `wtkIntegerOverflow` | `integer overflow` | **C** | `i32.div_s`, `i32.trunc_f32_s` |
| `wtkInvalidConversion` | `invalid conversion to integer` | **C** | `i32.trunc_f32_s` |
| `wtkCastFailure` | `cast failure` | **U** | ref.cast reports `can_trap:false` — §7.7 |
| `wtkArrayOutOfBounds` | `out of bounds array access` | **U** | array.get reports `can_trap:false` — §7.7 |
| `wtkAllocationFailure` | `allocation too large` / `out of memory` | **U** | not a spec trap; `impl-exec` |
| `wtkStackExhausted` | `call stack exhausted` | **U** | not a spec trap; `impl-exec` names "the number of frames on the stack" as an implementation limit |
| `wtkEpochInterrupt` | `interrupt` | **U** | not a spec trap; ADR-0006 |
| `wtkHostTrap` | *(host-supplied)* | — | `exec-invoke-host` |

**Link-error family** — all **U**. `exec-module` says only that
instantiation "may fail with an error"; `exec-invocation` likewise leaves
reporting to the embedder, and `assert_unlinkable` is what prefix-matches
them.

| Condition | Message | Conf. |
| --- | --- | --- |
| Import kind/type mismatch | `incompatible import type` | **U** |
| Import not supplied | `unknown import` | **U** |
| Import count mismatch | `unknown import` | **U** |

Both families live in **one** constants block in `Wasm.Runtime.Traps`,
next to `TWasmTrapKind`, so the `U` markers sit where a corrector will
find them — exactly as `Wasm.Validator.Types` did it. `TrapMessage` is a
`case` over the enum returning compile-time constants (TRAP-1 rule 1).

### 9.3 The systematic gap, recorded once

The pinned `wasm-mcp` build's `traps` field is **complete for 1.0/2.0
instructions and systematically incomplete for the 3.0 GC family**:
`ref.cast`, `array.get`, `array.set`, `array.new_data`, and `i31.get_s`
all report `can_trap: false, traps: []`, while `call_ref`,
`ref.as_non_null`, and `struct.get` correctly report `'null reference'`.
The corresponding `exec-*` clauses are SpecTec-generated with empty
prose, so the trap conditions cannot be recovered from the server at all.

This is worth an upstream issue against `wasm-mcp` and it is why every
GC trap message above is marked **U**. It is also the strongest argument
in this document for Track C preceding heavy Track D testing: 5,252
`assert_trap` assertions settle in one run what the MCP cannot answer.

---

## Appendix A — spec anchors cited

Pin `d7b37e4170d8315f2f1283aed4e8076591a9a333`, `wasm-mcp` 0.2.16.

`syntax-store`, `syntax-moduleinst`, `syntax-hostfunc` (funcinst),
`syntax-tableinst`, `page-size` (meminst), `syntax-globalinst`,
`syntax-taginst`, `syntax-eleminst`, `syntax-datainst`,
`syntax-fieldval` (struct/array inst), `syntax-exninst`, `syntax-num`
(values, "scalar references, containing a 31-bit integer"),
`syntax-frame`, `aux-default`, `aux-packfield` / `aux-unpackfield`,
`syntax-reftype` ("opaque … neither their size nor their bit pattern can
be observed"; "can be stored in tables but not in memories"),
`syntax-limits`, `syntax-memtype`, `syntax-addrtype`,
`exec-module` / `exec-instantiation`, `aux-rundata` / `aux-runelem`,
`alloc-module`, `alloc-mem`, `exec-invocation`, `exec-type`,
`type-inst`, `subtyping`, `match-externtype` (`Externtype_sub/*`),
`match-limits` (`Limits_sub/*`), `match-tabletype` (`Tabletype_sub`),
`match-memtype` (`Memtype_sub`), `match-globaltype`
(`Globaltype_sub/*`), `match-tagtype` (`Tagtype_sub`), `match-deftype`
(`Deftype_sub/refl`, `Deftype_sub/super`), `match-heaptype`,
`valid-ref.cast`, `exec-ref.cast` (`Step_read/ref.cast-*`),
`impl-exec`, `valid-type`, `aux-roll-rectype`.

Instruction trap tables read via `instruction_get`: `unreachable`,
`i32.load`, `i32.div_s`, `i32.trunc_f32_s`, `memory.init`,
`memory.grow`, `call_indirect`, `call_ref`, `table.get`, `table.init`,
`ref.as_non_null`, `struct.get`, `ref.cast`, `array.get`, `array.set`,
`array.new`, `array.new_data`, `ref.i31`, `i31.get_s`.

## Appendix B — contracts this document imposes on later tracks

| Id | On | Contract |
| --- | --- | --- |
| MEM-1 | E, I, J | `Base`/`ByteSize` cached only within a region containing no call, no `memory.grow`, no safepoint. |
| TRAP-1 | E, I, J | No managed Pascal state in any frame between a trampoline and a possible `siglongjmp`. Frames come from a per-store buffer, not per-call dynamic arrays. |
| GC-1 | E, I, J | The frame chain, zeroed ref slots at entry, push-before-first-safepoint, in-place tail-call replacement not spanning a safepoint. |
| GC-2 | I, J | Back-edge and function-entry safepoints must still produce a stack map even though v1 does not collect there. |
| EH-1 | H | The unwinder runs the epoch check before resuming at a catch clause's `TargetInstr` (already recorded in `Wasm.Ir.pas`' `TWasmIrHandlers`). |
| HOST-1 | F | A host holding a `TWasmRef` across anything that can allocate must register it. Undiagnosed otherwise. |
| HOST-2 | F | `BorrowsBuffer` must be surfaced; ADR-0003's lifetime rule is otherwise uncheckable. |
