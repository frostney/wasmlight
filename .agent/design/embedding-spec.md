# Track F — the embedding API and WASI preview1

Design spec. **The deliverable is this document; Track F ships no source
until this is accepted.** It builds on the current source of
`Wasm.Runtime.Store`, `Wasm.Runtime.Instantiate`, `Wasm.Interp`,
`Wasm.Runtime.Memory`, `Wasm.Runtime.Gc`, `Wasm.Runtime.Values`,
`Wasm.Module`, `Wasm.Wast.Runner` (as a reference for the host-side flow),
and `source/apps/wasmlight.pas`. It must not contradict the shipped
runtime; where it constrains a not-yet-written unit the constraint is a
contract, not a re-implementation. Never commit generated state. Gates:
`lwpt format --check`, `lwpt build`, `lwpt test`.

**Core-spec pin** (for the embedding anchors only): `wasm-mcp` 0.2.16,
`spec/main` `d7b37e4170d8315f2f1283aed4e8076591a9a333` (ADR-0004), verified
via `spec_version` at authoring time. The embedding entry points this API
mirrors live in the core spec's *Embedding* appendix (anchor `embed`;
`module_instantiate`, `func_invoke`, `func_alloc`, `instance_export`,
`mem_read`/`mem_write`). Everything in the appendix is "a suitable
interface … in the form of entry points through which an embedder can
access" the semantics — this doc is that interface, in Pascal, over the
shipped store.

**WASI pin.** WASI preview1 (`wasi_snapshot_preview1`) is **not** in the
WebAssembly core spec, so `wasm-mcp` cannot serve it. Every WASI claim
below is from the frozen `wasi_snapshot_preview1.witx` ABI as recalled,
and anything not verifiable from the core spec carries an explicit
`UNCONFIRMED` marker. **The witx signatures and errno/struct layouts MUST
be re-checked against a pinned copy of `WebAssembly/WASI`'s
`snapshot/witx/typenames.witx` + `wasi_snapshot_preview1.witx` before the
implementing wave writes the numeric constants** — the two shipped-bug
lessons in AGENTS.md ("check the spec; do not recall it") apply to the
WASI ABI exactly as they apply to the core encoding. Vendor that witx pin
under `tests/spec/wasi/` alongside the wasi-testsuite corpus (§7).

---

## 0. What Track F is, and the invariants it inherits

Track F turns a runtime that *executes* modules into one that *runs
programs*. Three deliverables, bottom-up:

1. **`Wasm.Engine`** — a thin, honest host-facing wrapper over the shipped
   store / instantiate / interp seam, so a program or a test can load,
   link, instantiate, and call a module without reaching into
   `Wasm.Wast.Runner`'s internals. This is API ergonomics plus the
   capability boundary, **not new runtime**.
2. **`Wasm.Wasi.*`** — the `wasi_snapshot_preview1` host module,
   implemented as ordinary host functions over `Wasm.Engine`, configured
   by an explicit capability set (deny-by-default).
3. **`wasmlight run`** — a new CLI subcommand that wires flags → capability
   set → WASI host imports → the `_start` entry, and maps the guest's exit
   to a process exit code.

Hard obligations, inherited and non-negotiable:

- **Deny-by-default host capability** (AGENTS.md; ADR-0002 as carried
  forward by ADR-0014). Nothing reaches the host filesystem, clock,
  environment, or network except through an import the embedder explicitly
  granted. A capability is a **value the host hands over**, never a
  permission the guest requests. Preopened directories are the model for
  everything (§2). This is the security-critical surface, so the
  constraint is a hard rule, not a guideline.
- **The Component Model is OUT** (ADR-0014). v1's host surface is WASI
  preview1 only. No component decoding, no canonical ABI. "Module" and
  "component" stay distinct terms; Track F only ever says "module".
- **A store is confined to one thread** (ADR-0008). `Wasm.Engine`
  enforces it in debug builds (`Store.CheckThread`) and documents it; it
  adds no locks. A host wanting parallelism runs several engines/stores.
- **The error hierarchy is load-bearing** (AGENTS.md). `EWasmDecodeError`,
  `EWasmValidationError`, `EWasmLinkError`, `EWasmTrap`, and
  `EWasmException` (the sibling of `EWasmTrap`) mean different things to a
  host. `Wasm.Engine` never collapses them and never raises a bare
  `EWasmError` where a specific one applies. A new one is added: a clean
  guest-requested exit (§6).
- **Validation happens once, before any tier** (ADR-0007/0012). Loading a
  module in the engine is exactly `DecodeModule → ValidateModule`; the
  engine never re-derives a spec rule and never reads raw bytes for
  execution (data-segment payloads excepted, which the runtime already
  owns via ADR-0003 spans).
- **Memory only through the chokepoint** (ADR-0005/0010/0013). Every WASI
  byte access to guest memory goes through `Store.MemAddressAt` /
  `Store.MemRangeAt`; the WASI code never sees `Base` and never does its
  own pointer arithmetic on a memory. A new caller that bypasses the
  chokepoint is the failure mode the whole memory design most guards
  against — and the WASI layer, which dereferences guest-controlled
  pointers constantly, is the single most exposed new caller. §5 is
  written to make that impossible by construction.
- **Traps unwind to the trampoline** (ADR-0009). Host→guest calls in
  `Wasm.Engine` go through `Wasm.Interp.InterpInvoke` (which wraps
  `WasmInvoke`), so a trap becomes a catchable `EWasmTrap` on ordinary
  ground, never a longjmp into a missing trampoline. A WASI callback that
  needs to fail the guest raises `EWasmTrap` (the host-trap thunk in the
  interpreter handles it, §4/interp-spec §5.6).
- **Host roots need explicit registration** (ADR-0011; contract HOST-1). A
  host (including a WASI callback) that holds a `TWasmRef` — or a caught
  `exnref` — across anything that can allocate must register it with
  `Store.Heap.RootRegister` / `RootScopeEnter`. Track H's F3/F4 forward
  hazards land here (§1.6). Undiagnosed otherwise.
- **`BorrowsBuffer` must be surfaced** (contract HOST-2, ADR-0003). The
  engine owns the module bytes for the instance's lifetime and exposes the
  query.

### 0.1 Layering (bottom-up, AGENTS.md fixed layout)

```
source/units/
  Wasm.Engine              depends on Store, Instantiate, Interp, Decoder,
                           Validator, Module, Values, Memory(via Store), Gc
  Wasm.Wasi.Types          errno enum, struct sizes, rights/oflags/fdflags,
                           clockid, filetype — constants only, no deps
                           beyond Wasm.Core
  Wasm.Wasi.Memory         guest-memory read/write helpers over the engine
                           instance + Store chokepoint (depends Engine,
                           Wasm.Wasi.Types)
  Wasm.Wasi                the wasi_snapshot_preview1 host module + the
                           capability set (depends Engine, Wasm.Wasi.Memory,
                           Wasm.Wasi.Types)
source/apps/
  wasmlight.pas            + the `run` subcommand (depends Engine, Wasi,
                           Decoder, Validator, cli package)
```

`Wasm.Engine` sits **above** the runtime and **below** the apps.
`Wasm.Wasi` sits above `Wasm.Engine`. Tests are co-located
(`Wasm.Engine.Test.pas`, `Wasm.Wasi.Test.pas`, `Wasm.Wasi.Memory.Test.pas`).
No new third-party dependency — only lwpt's `testing` and `cli`, already
present.

---

## 1. The embedding API — `Wasm.Engine`

The design principle for the whole unit: **it is a facade.** Every method
delegates to a shipped procedure. If a method would need new runtime
logic, it does not belong here — it belongs in the layer it delegates to.
The value the unit adds is (a) an ergonomic object surface that hides the
`TWasmImports`-by-kind vectors and the intern/instantiate/register dance,
(b) the typed host-import builder, (c) the capability boundary being
*explicit and visible* at the API, and (d) the rooting handle surface for
HOST-1.

### 1.1 Objects and lifetimes

```pascal
{ Wasm.Engine }

type
  { The engine owns the canonical type table (TWasmEngine) that outlives
    every store built on it, and is the factory for stores. One engine per
    "world" of modules that should share type identity for cross-module
    ref.cast / call_indirect. A CLI run uses exactly one. }
  TWasmEngine2 = class            { NAME: see §1.7 — reuses TWasmEngine or wraps it }
  ...

  { A loaded, validated module: the IR plus the borrowed bytes, ready to
    instantiate any number of times. Owns nothing the runtime owns; it
    owns the IR and the byte buffer it was validated against (ADR-0003:
    the bytes must outlive every instance — the engine module holds them
    so the embedder cannot drop them early). }
  TWasmLoadedModule = class
  public
    function Imports: TArray<TWasmImportDesc>;   { module, name, kind, type }
    function Exports: TArray<TWasmExportDesc>;
    property Ir: TWasmIrModule read FIr;         { borrowed by instances }
  end;

  { The import set under construction: a builder the embedder fills before
    instantiating. This is where the capability boundary is made visible —
    an import that is not defined here is simply absent, and instantiation
    fails with EWasmLinkError. There is NO ambient fallback. }
  TWasmLinker = class ... end;

  { A live instance: a handle over TWasmModuleInstance in a store. Calling,
    export lookup, and memory access go through it. }
  TWasmInstance = class
  public
    function FindExportFunc(const AName: string; out AFunc: TWasmFunc): Boolean;
    function FindExportMemory(const AName: string; out AMem: TWasmMemoryRef): Boolean;
    function FindExportGlobal(const AName: string; out AGlobal: TWasmGlobalRef): Boolean;
    function BorrowsBuffer: Boolean;             { HOST-2 }
    property Raw: TWasmModuleInstance read FInst;
  end;
```

`TWasmStore` already is the store; the engine's store facade is a thin
`TWasmStoreHandle` that (a) constructs `TWasmStore.Create(engine)`, (b)
calls `RegisterInterpreter(store)` once so the tier seam is wired (the
interpreter hook is per-store — see interp-spec §1.5), and (c) forwards
`CheckThread`. Rather than introduce a parallel class, **the engine facade
reuses the shipped `TWasmStore` directly** and adds free functions /
a light wrapper for the ergonomic calls. The doc uses "the store" and
"the engine" for the shipped `TWasmStore` + `TWasmEngine`; the only *new*
classes are `TWasmLoadedModule`, `TWasmLinker`, and `TWasmInstance`, plus
value/handle records. (Final naming in §1.7.)

**Lifetime contract, stated on every entry point** (ADR-0003, HOST-2):

1. A `TWasmLoadedModule` owns its byte buffer and its `TWasmIrModule`. It
   must outlive every `TWasmInstance` created from it.
2. A `TWasmInstance` borrows the loaded module's IR and bytes. Freeing the
   loaded module while an instance is live is a use-after-free with no
   diagnostic; `BorrowsBuffer` (true until every data segment is dropped)
   is the honest query, surfaced from `TWasmModuleInstance.BorrowsBuffer`.
3. The store owns every instance (via `AddInstance`); the embedder never
   frees an instance directly. Freeing the store frees them.
4. The engine (`TWasmEngine`) outlives every store built on it.

### 1.2 Loading a module

```pascal
{ Decode + validate bytes into a loaded module. Raises EWasmDecodeError
  (not a module) or EWasmValidationError (a module, not well-typed) —
  never collapses the two, so a host can tell "garbage" from "ill-typed".
  The bytes are COPIED into the loaded module so its lifetime is
  self-contained (ADR-0003 wants the buffer stable; owning a copy is the
  simplest way to guarantee it for an embedder that reads from a stream). }
function LoadModule(const ABytes: TWasmBytes): TWasmLoadedModule;
function LoadModuleFromFile(const APath: string): TWasmLoadedModule;
```

Implementation is exactly `wasmlight validate`'s body: `DecodeModule` then
`ValidateModule(Module, Bytes)` → the `TWasmIrModule`. The loaded module
keeps the `TWasmBytes` copy and the IR; `ValidateModule` is the only pass
that reads the raw binary (ADR-0007).

Decisions:

- **Copy the bytes.** `validate` today keeps `Bytes: TWasmBytes` on the
  stack; an embedder that hands us a transient buffer would violate
  ADR-0003 if we borrowed. One owned copy per loaded module removes a
  whole class of lifetime bug at the cost of one buffer. (An advanced
  zero-copy `LoadModuleBorrowed(ABytes)` MAY be added later for embedders
  that guarantee the lifetime; not v1.)
- **No lazy/streaming decode.** The core-spec streaming entry points are
  js-api/web-api concerns; v1 decodes eagerly.

### 1.3 Defining host imports — `TWasmLinker`

The linker is the capability boundary made a Pascal object. It maps
`(module, name)` → a store entity the embedder is *explicitly* providing.
Nothing is provided implicitly.

```pascal
type
  TWasmLinker = class
  public
    constructor Create(const AStore: TWasmStore);

    { Register a host function for (module, name). AParams/AResults name the
      wasm signature the host func presents; the linker mints the matching
      engine type id (§1.4) and calls Store.AddHostFunc. ACallback is the
      shipped TWasmHostFunc; AData is opaque host state (the WASI context,
      for instance). }
    procedure DefineFunc(const AModule, AName: string;
      const AParams, AResults: array of TWasmValueType;
      const ACallback: TWasmHostFunc; const AData: Pointer);

    { Host globals / memories / tables the embedder chooses to export to
      the guest. WASI preview1 needs NONE of these (it is all functions +
      the guest's own exported memory), so these are provided for
      completeness and general embedding, not for WASI. }
    procedure DefineGlobal(const AModule, AName: string;
      const AType: TWasmGlobalType; const AInitial: TWasmValue);
    procedure DefineMemory(const AModule, AName: string;
      const AType: TWasmMemType; out AAddr: TWasmMemAddr);
    procedure DefineTable(const AModule, AName: string;
      const AType: TWasmTableType);

    { Resolve one module's imports against what has been defined, producing
      the by-kind TWasmImports the shipped InstantiateModule wants. Raises
      EWasmLinkError naming the first (module, name) that is missing or
      whose kind/type does not match — deny-by-default: an undefined import
      is a link failure, never a silent no-op. }
    function ResolveImports(const AModule: TWasmLoadedModule): TWasmImports;
  end;
```

`DefineFunc` stores `(module, name) → TWasmFuncAddr` in an internal map.
`ResolveImports` walks `AModule.Imports` (from `Wasm.Module`'s
`TWasmImport` list: `ModuleName`, `Name`, `Kind`, `FuncTypeIndex`/…), and
for each import looks up the definition, checks the kind, and appends the
addr to the right `TWasmImports` vector **in module index order** (the
shipped instantiate expects the vectors ordered as the index spaces
expect — see `Wasm.Runtime.Instantiate`'s header). A missing or
kind-mismatched import raises `EWasmLinkError` here, before instantiation,
with the same `MSG_LINK_*` vocabulary the runtime uses.

The linker owns the *policy* of what is granted; the store owns the
*entities*. The two together are the sandbox's outer wall.

### 1.4 Minting the engine type id for a host function — the load-bearing detail

`Store.AddHostFunc(ATypeId: TWasmEngineTypeId; ACallback; AData)` needs an
**engine type id**, and instantiation's `CheckImportTypes` matches a func
import by `MatchFuncImport(Engine, StoreFunc, CanonIds[Ir.FuncCanonTypes[i]])`
— i.e. the host func's `TypeId` must match (engine subtyping) the module's
declared import functype (`Wasm.Runtime.Instantiate`).

The mechanism, using only shipped APIs:

- `TWasmEngine.InternModule(Ir, CanonIds, TypeIds)` is public and
  **idempotent/cached** — instantiation calls it, and a second call is
  free. `CanonIds[Ir.FuncCanonTypes[i]]` is the engine type id the module
  assigned its func import `i`.
- Therefore `DefineFunc` cannot mint from thin air *before* it knows the
  module, but `ResolveImports(module)` can: it interns the module (or
  reads the cached ids), and for each func import it looks up the
  definition and **creates the host func lazily at resolve time with the
  module's own import type id**:

  ```
  Engine.InternModule(module.Ir, CanonIds, TypeIds)   { cached after 1st }
  for each func import i in module:
      def := lookup(module_name[i], name[i])           { EWasmLinkError if absent }
      expectedId := CanonIds[module.Ir.FuncCanonTypes[i]]
      { robustness: verify the DECLARED functype equals the signature the
        host func actually implements — a guest that imports fd_write with
        the wrong arity must be rejected, not silently mis-marshaled }
      if not FuncTypeEquals(Engine.EngineType(expectedId).Comp.Func,
                            def.Params, def.Results) then
        raise EWasmLinkError('<module>.<name>: host import signature mismatch')
      addr := Store.AddHostFunc(expectedId, def.Callback, def.Data)
      Imports.Funcs[i] := addr
  ```

  Using the module's own `expectedId` makes `MatchFuncImport` reduce to id
  equality — trivially true — while the explicit `FuncTypeEquals` check is
  what actually enforces that the guest asked for the signature the host
  implements. This needs **no new engine API**. It is the same
  intern-then-read-ids flow `InstantiateModule` performs internally.

  > **UNCONFIRMED (mechanism, not spec):** that `InternModule` is safe to
  > call twice on the same IR with identical outputs. The runtime-spec
  > §2.5 states the result is cached on the IR so a second instantiation
  > is free; the implementing wave must confirm `InternModule` is
  > genuinely idempotent (returns the cached `CanonIds`/`TypeIds` on the
  > second call) rather than re-appending engine types. If it is not, add
  > a one-line `Engine.EnsureInterned(Ir): (CanonIds, TypeIds)` accessor
  > that returns the cache; do not duplicate the interning.

`DefineGlobal`/`DefineMemory`/`DefineTable` mint their entities eagerly via
`Store.AddGlobal`/`AddMemory`/`AddTable` (those take a type, not an engine
id, so no interning dance) and record the addr under `(module, name)`.

### 1.5 Instantiating and calling

```pascal
{ Link + instantiate. Delegates to InstantiateModule(store, ir, bytes,
  len, imports). Raises EWasmLinkError on a bad import (from the linker or
  the runtime), EWasmTrap on an out-of-bounds active elem/data segment.
  A module with a start function instantiates and records the start
  PENDING; RunStart runs it. }
function Instantiate(const AStore: TWasmStore; const ALinker: TWasmLinker;
  const AModule: TWasmLoadedModule): TWasmInstance;

{ Run the module's start function (if any) through the trampoline. A trap
  or an uncaught exception in start propagates as EWasmTrap/EWasmException.
  Delegates to Store.RunPendingStart, which goes through WasmInvoke. }
procedure RunStart(const AStore: TWasmStore; const AInstance: TWasmInstance);
```

`Instantiate` is `ALinker.ResolveImports(AModule)` then
`InstantiateModule(AStore, AModule.Ir, AModule.BytesPtr,
AModule.BytesLen, imports)` wrapped in `TWasmInstance`. `RunStart` is
`Store.RunPendingStart(inst.Raw)`.

**Calling an export.** The engine call API marshals `TWasmValue` in and
out and goes through `InterpInvoke` (which installs the trampoline), so a
trap is a catchable `EWasmTrap`:

```pascal
type
  TWasmFunc = record                { an export handle }
    Store: TWasmStore;
    Addr:  TWasmFuncAddr;
    ParamTypes: TArray<TWasmValueType>;
    ResultTypes: TArray<TWasmValueType>;
  end;

{ Call an exported function. AArgs must match ParamTypes in order/arity;
  AResults is filled in result order. Values are the shipped 8-byte
  TWasmValue slots (v128 occupies two adjacent slots, low half first —
  simd-spec §1.7; the marshaling helper accounts for that from the type
  vector). Raises EWasmTrap on a guest trap, EWasmException on an uncaught
  guest throw, EWasmExit on proc_exit (§6). }
procedure Call(const AFunc: TWasmFunc;
  const AArgs: array of TWasmValue; var AResults: array of TWasmValue);
```

Implementation mirrors `Wasm.Wast.Runner`'s invoke (its lines 914–943 are
the working reference): find the export addr via
`TWasmModuleInstance.FindExport` (kind `wxkFunc`), read the arity from
`Engine.EngineType(Store.Funcs[Addr].TypeId).Comp.Func`, copy args into a
contiguous param buffer, `InterpInvoke(Store, Addr, @Params[0],
@Results[0])`, copy results out. **The runner calls `InterpInvoke`, not
`InterpTierInvoke`** — that is the rule (interp-spec §1.5): the trampoline
must be installed so a trap becomes an exception rather than a longjmp
into nothing. The engine follows it.

`FindExportMemory` returns a `TWasmMemoryRef = record Store; Addr:
TWasmMemAddr end` — an opaque handle that can only be *used* through the
chokepoint accessors (§1.6, §5), never dereferenced. The store keeps
memories private for exactly this reason (`Wasm.Runtime.Store` FMemories
is private); the engine does not widen that hole.

### 1.6 Reading/writing exported memory, and host roots (HOST-1)

The engine exposes guest memory only through the chokepoint. These are the
*embedder-facing* twins of §5's WASI-internal helpers — same rule, same
enforcement:

```pascal
{ Read ALength bytes at guest offset AOffset of an exported memory into
  ADest. Returns False (does NOT raise) if the range is out of bounds — an
  embedder reading guest memory should get a boolean, not a guest trap.
  Internally: Store.MemRangeAt(mem.Addr, AOffset, ALength) inside a
  WasmInvoke-guarded region so an out-of-bounds access traps to a boolean
  rather than a process crash under a guard-page memory. }
function MemRead(const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
  ADest: PByte): Boolean;
function MemWrite(const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
  ASrc: PByte): Boolean;
function MemSize(const AMem: TWasmMemoryRef): UInt64;   { bytes }
```

> **Chokepoint note.** `MemRangeAt` under a guard-page memory can fault
> (the guard page), and a fault outside `WasmInvoke` has no trampoline to
> unwind to — `Wasm.Runtime.Traps` raises a diagnostic ("memory
> chokepoint used outside WasmInvoke"). So `MemRead`/`MemWrite` for the
> *guard-page* strategy must run their access inside a `WasmInvoke` thunk
> that converts a fault into the boolean. For explicit-bounds strategies
> the range check is a plain comparison and no trampoline is needed; the
> helper can pre-check with a size comparison against `MemSize` and only
> touch bytes when in range, avoiding the trampoline on the common path.
> **Decision:** pre-check the range against `MemSize` (an unsigned,
> overflow-safe compare identical to §5's), and only then copy — so
> `MemRead`/`MemWrite` never provoke a guard fault at all, on any
> strategy, and need no trampoline. This is the same discipline §5
> mandates for WASI.

**Host roots — the registration API (HOST-1).** An embedder (or a WASI
callback) that keeps a `TWasmRef` — a `funcref`, `externref`, `anyref`, or
a caught `exnref` — in its own Pascal storage across anything that can
allocate (another `Call`, a `struct.new` inside a re-entrant guest call, a
subsequent instantiation) must root it, because the engine's param/result
buffers are **not** on the GC frame chain and the collector cannot see a
ref the host stashed. The engine re-exports the shipped
`Wasm.Runtime.Gc` API on the store:

```pascal
function  RootRegister(const AStore: TWasmStore; const ARef: TWasmRef): TWasmRootHandle;
function  RootGet(const AStore: TWasmStore; const AHandle: TWasmRootHandle): TWasmRef;
procedure RootSet(const AStore: TWasmStore; const AHandle: TWasmRootHandle; const ARef: TWasmRef);
procedure RootRelease(const AStore: TWasmStore; const AHandle: TWasmRootHandle);
function  RootScopeEnter(const AStore: TWasmStore): UInt32;
procedure RootScopeLeave(const AStore: TWasmStore; const AMark: UInt32);
```

These forward to `Store.Heap.RootRegister` / `RootScopeEnter` / etc. The
handle is an index into a store-owned array, so it survives the array
growing; under the non-moving collector `RootGet` returns the pointer with
no read barrier.

**Track H's forward hazards F3/F4 (eh-spec §2.5) resolve exactly here.**
An uncaught `EWasmException` carries `ExnRef: NativeUInt` (the `wokExn`
handle) and `TagAddr: UInt32`. Once `Run` has exited, the frame chain is
empty, so the `ExnRef` is an **unrooted raw handle** — safe only until the
next allocation. A host that catches an `EWasmException` and wants to
inspect the exception's tag/payload, *or* to re-throw it into a later
guest call, across an intervening `Call`/allocation, MUST root it the
instant it catches:

```pascal
{ The pattern Track F documents as mandatory for a host that survives an
  uncaught guest exception past its first allocation: }
except
  on E: EWasmException do
  begin
    h := RootRegister(Store, TWasmRef(E.ExnRef));   { before any Call/alloc }
    try
      ... inspect tag E.TagAddr, read payload via a to-be-added ExnPayload
          accessor, or hand it back into a later invoke ...
    finally
      RootRelease(Store, h);
    end;
  end;
```

WASI itself never holds an `exnref` (preview1 has no exceptions), so this
is an embedding-API obligation, documented and test-covered (§7), not a
WASI-internal one. The doc's job per eh-spec §2.5 is to *specify* it here;
it is now specified.

### 1.7 Naming and the reuse-vs-wrap decision

`TWasmEngine` and `TWasmStore` already exist and are the real engine and
store. Track F does **not** rename or subclass them. The new public names:

- `TWasmLoadedModule`, `TWasmLinker`, `TWasmInstance` — the three genuinely
  new facade classes.
- `TWasmFunc`, `TWasmMemoryRef`, `TWasmGlobalRef` — value/handle records.
- Free functions `LoadModule`, `Instantiate`, `Call`, `MemRead`, … in
  `Wasm.Engine`.

The `TWasmEngine2` sketch in §1.1 is discarded: there is one engine type,
the shipped `TWasmEngine`. `Wasm.Engine` the *unit* provides the facade;
`TWasmEngine` the *class* stays where it is (`Wasm.Runtime.Store`). The
unit name and the class name differing is intentional and documented.

---

## 2. The capability model (deny-by-default, ADR-0002 via ADR-0014)

A capability is a **value the host hands over**. The guest has no ambient
authority: no path it can name reaches a file the host did not preopen, no
clock it can read unless granted, no environment variable it did not
receive. This is the security core of Track F and the reason WASI code is
concentrated in one reviewable unit.

### 2.1 The config the embedder passes

```pascal
{ Wasm.Wasi }

type
  { A byte sink/source the host controls — the seam that makes fd_write to
    "stdout" testable without a real stdout (§7). Implementations: a real
    OS handle, an in-memory buffer, /dev/null. }
  TWasmWasiStream = class
  public
    function WriteBytes(const ABuf: PByte; const ALen: NativeUInt): NativeUInt; virtual; abstract;
    function ReadBytes(const ABuf: PByte; const AMax: NativeUInt): NativeUInt; virtual; abstract;
    function IsTerminal: Boolean; virtual;
  end;

  { A preopened directory: the ONLY way the guest reaches the filesystem.
    HostPath is a real OS directory the embedder chose; GuestPath is the
    name the guest sees (e.g. "/" or "."); Rights bound what may be done
    through it and any fd derived from it. The guest gets a preopen fd
    (3,4,…) and a fd_prestat_dir_name of GuestPath — it never learns
    HostPath. }
  TWasmWasiPreopen = record
    GuestPath: string;
    HostPath:  string;
    Rights:    UInt64;        { base rights bitmask (§3, rights_* ) }
    InheritRights: UInt64;    { rights new fds under this preopen may have }
  end;

  { The whole capability set. Everything the guest can reach, and nothing
    it cannot. Default-constructed = deny-all except the three std streams
    (see §2.2). }
  TWasmWasiConfig = class
  public
    Argv: TArray<string>;                 { args_get / args_sizes_get }
    Env:  TArray<string>;                 { "KEY=VALUE"; environ_* }
    Preopens: TArray<TWasmWasiPreopen>;   { path_open reachability }
    Stdin, Stdout, Stderr: TWasmWasiStream;
    Clock:  TWasmWasiClock;               { injectable — §2.3 }
    Random: TWasmWasiRandom;              { injectable — §2.3 }
    { Construction helpers used by `wasmlight run`: }
    procedure GrantStdio;                 { wire real OS stdin/out/err }
    procedure AddPreopenDir(const AGuest, AHost: string; const ARights: UInt64);
    procedure AddEnv(const AKV: string);
    procedure SetArgv(const AArgv: array of string);
  end;
```

### 2.2 The default is (almost) nothing — and which "almost"

Deny-by-default means the *default* `TWasmWasiConfig` grants **no
filesystem, no env, no argv beyond argv[0], and no network** (there is no
network in preview1 anyway). The one deliberate grant: **the three
standard streams (fd 0/1/2)**, following wasmtime's default (stdio on, fs
and env off). Justification, cited to the ADR: ADR-0002/0014's
deny-by-default is about *ambient authority to the host's resources* —
files, env, clock, network. Stdout/stderr are the process's own already-
open descriptors, and a `run` command that could not print is not a
runtime, it is a null device. wasmtime grants stdio by default and nothing
else; peer runtimes (wazero, WAMR) do the same. We follow that model and
cite the deny-by-default ADR for everything else.

- **stdin default = empty (EOF immediately).** Granting a read of the
  real terminal is a capability; the default gives an empty stream, so a
  guest reading stdin sees clean EOF, not the host's keyboard, unless the
  embedder wired it. `wasmlight run` wires real stdin (see §4 — a command
  the user typed is a user handing over their terminal; still, this is a
  decision to state, and `--no-stdin` can revoke it later).
- **clock and random default = present but explicit.** A default `run`
  grants `clock_time_get`/`random_get` from the real OS clock and CSPRNG,
  because a program that cannot get the time or a random seed is broken
  for no security benefit, and neither leaks host *state* the way the
  filesystem does. Tests inject deterministic clock/random (§7). If a
  future embedder wants a hermetic guest, it passes a fixed
  `TWasmWasiClock`/`TWasmWasiRandom` — the seam is already there.

  > **UNCONFIRMED (policy, not ABI):** whether clock/random should be
  > *denied* by default and opted into with a flag. wasmtime grants them.
  > v1 follows wasmtime: granted for `wasmlight run`, injectable/denyable
  > at the API. Recorded as a decision so it is visible for review.

- **argv default.** `args_get` returns at least `argv[0]` (the program
  name — the module path or its basename; §4 decides). The guest's own
  args come only from what `wasmlight run` forwards after the module (or
  what the embedder sets). No ambient argv.

### 2.3 Injectable clock and random (determinism + the test seam)

```pascal
  TWasmWasiClock = class
  public
    { nanoseconds since epoch for CLOCK_REALTIME; monotonic ns for others.
      AClockId is the wasi clockid (§3). AProvidedResolution ns. }
    function TimeGet(const AClockId: UInt32; out ANanos: UInt64): TWasmWasiErrno; virtual; abstract;
    function ResGet(const AClockId: UInt32; out ANanos: UInt64): TWasmWasiErrno; virtual; abstract;
  end;

  TWasmWasiRandom = class
  public
    function Fill(ABuf: PByte; ALen: NativeUInt): TWasmWasiErrno; virtual; abstract;
  end;
```

Real implementations wrap the OS (POSIX `clock_gettime`, `getrandom`/
`arc4random_buf`; Windows `QueryPerformanceCounter`/`BCryptGenRandom`).
Test implementations return fixed values. The WASI functions never touch
the OS directly — they call through these objects, so a hermetic test is
the default posture and the real clock/CSPRNG is just one implementation.
This keeps AGENTS.md's "nothing in the test stack touches the external
network" true and extends it to "nothing in a WASI unit test touches the
real clock, fs, or entropy unless it opts in".

### 2.4 The capability is checked at the WASI boundary, not the guest's request

The guest never *asks* for a capability. It calls `path_open` with a
dirfd; the WASI layer resolves that dirfd in the fd table (§3), and the fd
table only contains entries the embedder put there (preopens) or entries
derived from them under their rights. A dirfd the guest fabricates is
`EBADF`; a path that escapes the preopen (via `..`) is `ENOTCAPABLE` or
`EACCES` (§5.3). There is no code path from a guest call to a host
resource that does not pass through an embedder-granted fd-table entry.
That absence is the sandbox.

---

## 3. WASI preview1 (`wasi_snapshot_preview1`) — the host module

Every function is registered by `TWasmLinker.DefineFunc('wasi_snapshot_preview1',
'<name>', params, results, @Wasi_<name>, ctx)`, where `ctx: PWasmWasiContext`
is the per-instance WASI state:

```pascal
type
  PWasmWasiContext = ^TWasmWasiContext;
  TWasmWasiContext = record
    Config:   TWasmWasiConfig;             { the granted capabilities }
    Fds:      TWasmWasiFdTable;            { fd -> entry; §3.1 }
    Memory:   TWasmMemoryRef;             { the guest's exported "memory";
                                            resolved AFTER instantiation }
    ExitCode: Int32;                       { set by proc_exit; §6 }
  end;
```

**The memory-resolution ordering.** WASI functions read/write the guest's
*own* exported linear memory (preview1 modules export `memory`). The
context's `Memory` handle is not known until the instance exists, but the
host funcs are registered *before* instantiation. Resolution: register the
callbacks with a `ctx` whose `Memory` is unset; after `Instantiate`, call
`FindExportMemory(inst, 'memory', ctx.Memory)` and store it into the
context before the first `Call`/`RunStart`. A WASI call that runs before
`Memory` is resolved (impossible in practice — `_start` runs after
resolution) returns `EFAULT`. This is the one piece of state that flows
instance→context; it is a single handle, set once.

### 3.1 The fd table

```pascal
type
  TWasmWasiFdKind = (wfkStream, wfkDir, wfkFile);
  TWasmWasiFdEntry = record
    Kind: TWasmWasiFdKind;
    Stream: TWasmWasiStream;    { wfkStream: 0/1/2 and pipes }
    { wfkDir/wfkFile: a real OS handle plus the preopen it descends from,
      so every access re-checks rights and containment (§5.3). }
    OsHandle: THandle;          { or a Pascal file handle abstraction }
    Preopen:  Integer;          { index into Config.Preopens, or -1 }
    Rights, InheritRights: UInt64;
    IsPreopen: Boolean;         { fd_prestat_* only answers for these }
    Offset:   UInt64;           { fd_seek cursor for regular files }
  end;
  TWasmWasiFdTable = ... { fd (UInt32) -> entry; 0/1/2 = stdio, 3.. = preopens then opened }
```

fd 0/1/2 are the std streams; preopens are assigned 3,4,… at context
construction (that is what `fd_prestat_get`/`fd_prestat_dir_name` report,
and how libc-side preopen discovery finds them); opened files/dirs get the
next free fd. Closing frees the slot.

### 3.2 The pointer-argument discipline (the sandbox boundary)

Every preview1 function takes **guest linear-memory offsets** (i32, or i64
under memory64) as pointer/length arguments. The rule, absolute:

> **A WASI function NEVER dereferences a raw host pointer derived from
> guest data. Every access to guest memory goes through `Wasm.Wasi.Memory`
> (§5), which routes to `Store.MemRangeAt`/`MemAddressAt` (the chokepoint)
> and bounds-checks. A bad guest pointer is a WASI `EFAULT` return value,
> never a crash and never an out-of-bounds host read.**

This is the WASI-shaped restatement of ADR-0005's chokepoint rule, and the
reason the entire WASI layer is written against `Wasm.Wasi.Memory` and
never sees `Base`.

### 3.3 The function set, tiered

Each entry gives the witx signature (all params/results are `i32` unless
noted; pointers are guest offsets), the capability check, and the errno on
failure. **Signatures marked UNCONFIRMED must be checked against the
pinned witx before coding.** Return value is a wasi `errno` (i32) unless
the function is `noreturn`.

**Wave 1 — MUST (hello-world + args/env/clock/random/exit/stdio):**

| function | witx signature (guest offsets) | capability / behaviour | errno on fail |
| --- | --- | --- | --- |
| `proc_exit` | `(rval: i32) -> ()` noreturn | sets `ctx.ExitCode := rval`; raises `EWasmExit` (§6) — clean, not a trap | — |
| `fd_write` | `(fd, iovs, iovs_len, nwritten_ptr) -> errno` | fd must be a writable stream/file with `rights_fd_write`; reads the iovec array + each buffer through §5; writes to `entry.Stream`/OS handle; stores bytes-written at `nwritten_ptr` | `EBADF`, `ENOTCAPABLE`, `EFAULT` |
| `fd_read` | `(fd, iovs, iovs_len, nread_ptr) -> errno` | fd readable with `rights_fd_read`; fills iovec buffers from the stream/file; stores count | `EBADF`, `ENOTCAPABLE`, `EFAULT` |
| `fd_close` | `(fd) -> errno` | frees the fd-table slot; closing a preopen is allowed but removes it | `EBADF` |
| `fd_seek` | `(fd, offset: i64, whence: i32, newoffset_ptr) -> errno` | regular files with `rights_fd_seek`; updates `entry.Offset` | `EBADF`, `ENOTCAPABLE`, `ESPIPE`(stream), `EFAULT` |
| `fd_fdstat_get` | `(fd, buf_ptr) -> errno` | writes a `fdstat` struct (filetype, flags, rights_base, rights_inheriting) via §5 | `EBADF`, `EFAULT` |
| `fd_prestat_get` | `(fd, buf_ptr) -> errno` | preopen fds only: writes `prestat { tag=dir; u.dir.pr_name_len }`; non-preopen fd → `EBADF` (this is how libc terminates preopen discovery) | `EBADF`, `EFAULT` |
| `fd_prestat_dir_name` | `(fd, path_ptr, path_len) -> errno` | writes `GuestPath` of the preopen (truncated to path_len) | `EBADF`, `ENAMETOOLONG`, `EFAULT` |
| `environ_sizes_get` | `(count_ptr, bufsize_ptr) -> errno` | writes number of env entries and total bytes | `EFAULT` |
| `environ_get` | `(environ_ptr, buf_ptr) -> errno` | writes the pointer array + NUL-terminated `KEY=VALUE` strings into guest memory via §5 | `EFAULT` |
| `args_sizes_get` | `(argc_ptr, bufsize_ptr) -> errno` | argv count + total bytes | `EFAULT` |
| `args_get` | `(argv_ptr, buf_ptr) -> errno` | argv pointer array + NUL-terminated strings | `EFAULT` |
| `clock_time_get` | `(id: i32, precision: i64, time_ptr) -> errno` | `Config.Clock.TimeGet`; writes i64 ns | `EINVAL`(bad id), `ENOTCAPABLE`(denied), `EFAULT` |
| `clock_res_get` | `(id: i32, res_ptr) -> errno` | `Config.Clock.ResGet`; writes i64 ns | `EINVAL`, `EFAULT` |
| `random_get` | `(buf_ptr, buf_len) -> errno` | `Config.Random.Fill` into the checked guest range | `EFAULT` |
| `sched_yield` | `() -> errno` | no-op, returns `ESUCCESS` (single-threaded store) | — |
| `proc_raise` | `(sig: i32) -> errno` | UNCONFIRMED whether preview1 keeps it; if present, `ENOTSUP` unless a signal model is granted | `ENOTSUP` |

**Wave 2 — SHOULD (real filesystem via preopens):**

| function | witx signature | capability / behaviour | errno |
| --- | --- | --- | --- |
| `path_open` | `(dirfd, dirflags: i32, path_ptr, path_len, oflags: i32, rights_base: i64, rights_inheriting: i64, fdflags: i32, opened_fd_ptr) -> errno` | dirfd must be a dir fd with `rights_path_open`; resolve `path` **within** the preopen with no `..` escape (§5.3); requested rights masked by the dirfd's inheriting rights; opens a real OS handle; installs a new fd; writes it | `EBADF`, `ENOTCAPABLE`, `EACCES`, `ENOENT`, `EEXIST`, `ENOTDIR`, `EFAULT` |
| `fd_filestat_get` | `(fd, buf_ptr) -> errno` | writes a `filestat` struct (dev, ino, filetype, nlink, size, atim, mtim, ctim) | `EBADF`, `EFAULT` |
| `path_filestat_get` | `(dirfd, flags, path_ptr, path_len, buf_ptr) -> errno` | resolve within preopen; stat | `EBADF`, `ENOTCAPABLE`, `ENOENT`, `EFAULT` |
| `fd_readdir` | `(fd, buf_ptr, buf_len, cookie: i64, bufused_ptr) -> errno` | dir with `rights_fd_readdir`; writes `dirent` records + names; cookie-paged | `EBADF`, `ENOTCAPABLE`, `EFAULT` |
| `path_create_directory` | `(dirfd, path_ptr, path_len) -> errno` | dir with `rights_path_create_directory` | `EBADF`, `ENOTCAPABLE`, `EEXIST`, `EFAULT` |
| `path_unlink_file` | `(dirfd, path_ptr, path_len) -> errno` | `rights_path_unlink_file`; **note: unlink is a prohibited-adjacent op — it deletes guest-reachable data, but ONLY within a granted preopen, so it is permitted when the capability is present.** Not a host-data delete outside the sandbox. | `EBADF`, `ENOTCAPABLE`, `ENOENT`, `EFAULT` |
| `path_remove_directory` | `(dirfd, path_ptr, path_len) -> errno` | `rights_path_remove_directory` | as above |
| `fd_fdstat_set_flags` | `(fd, flags: i32) -> errno` | append/nonblock toggles within rights | `EBADF`, `ENOTCAPABLE` |
| `fd_filestat_set_size` | `(fd, size: i64) -> errno` | truncate/extend within `rights_fd_filestat_set_size` | `EBADF`, `ENOTCAPABLE`, `EFAULT` |
| `path_rename`, `path_link`, `path_symlink`, `path_readlink` | (per witx) | each behind its right, each within preopens on both ends | `ENOTCAPABLE`, `EFAULT`, … |
| `fd_pread`, `fd_pwrite` | `(fd, iovs, iovs_len, offset: i64, n_ptr) -> errno` | positional variants of read/write | as read/write |
| `fd_tell` | `(fd, offset_ptr) -> errno` | `entry.Offset` | `EBADF`, `EFAULT` |
| `fd_sync`, `fd_datasync` | `(fd) -> errno` | flush within rights | `EBADF`, `ENOTCAPABLE` |
| `fd_advise`, `fd_allocate` | (per witx) | advisory; MAY no-op with `ESUCCESS` if the OS lacks it | — |

**Wave 3 — MAY / stub (the long tail):** any preview1 function not above
is registered but returns `ENOSYS` (or `ENOTSUP`) rather than being
absent, so a module importing it *links* and only fails at the call. Rationale:
absence is an `EWasmLinkError` at instantiation, which stops a program
that imports a rarely-called function it never actually invokes; a stub
returning `ENOSYS` lets it run until it truly needs the function.
Candidates: `fd_renumber`, `sock_*` (there is no network — always
`ENOTSUP`/`ENOTCAPABLE`), `poll_oneoff` (stub `ENOSYS` in v1; a real
implementation is a wave past 2). **`sock_*` returning `ENOTCAPABLE` is
the deny-by-default network posture made concrete: the functions exist so
a module links, but no socket capability is ever grantable in v1.**

> **UNCONFIRMED (ABI specifics, must verify against witx before coding):**
> the exact struct layouts and offsets of `fdstat` (24 bytes?),
> `prestat` (tag + union), `filestat` (64 bytes?), `dirent` (24-byte
> header + name), `iovec`/`ciovec` (8 bytes: ptr+len on wasm32; 16 on
> wasm64), the `whence` enum values (SET/CUR/END ordering), the `oflags`
> bits (CREAT/DIRECTORY/EXCL/TRUNC), the `fdflags` bits (APPEND/DSYNC/
> NONBLOCK/RSYNC/SYNC), the full `rights_*` bit assignments, the
> `clockid` values (REALTIME=0, MONOTONIC=1, PROCESS_CPUTIME=2,
> THREAD_CPUTIME=3), and the complete `errno` enum numbering. All of
> these are numeric constants in the witx; §5 accesses them abstractly,
> but the numbers themselves are load-bearing and are the classic place a
> recalled ABI is wrong. Put them in `Wasm.Wasi.Types` with a comment
> citing the witx line, and cross-check each against a runnable
> hello-world from wasi-sdk before trusting them.

### 3.4 The errno type

```pascal
{ Wasm.Wasi.Types — the wasi errno as a Pascal enum whose ORDINALS are the
  ABI numbers. Verify every value against typenames.witx. }
type
  TWasmWasiErrno = (
    weSuccess = 0, we2Big = 1, weAcces = 2, weAddrInUse = 3, ...
    weBadf = 8, ... weFault = 21, ... weInval = 28, ... weNoEnt = 44,
    weNoSys = 52, ... weNotCapable = 76, ... );  { NUMBERS UNCONFIRMED }
```

A WASI callback computes a `TWasmWasiErrno` and writes `Ord(errno)` as the
i32 result via `AResults[0]`. `weSuccess = 0` is the success return.

---

## 4. `wasmlight run` — the CLI

A new subcommand, registered in `wasmlight.pas` alongside `inspect` and
`validate`, through the lwpt `cli` package (AGENTS.md: no hand-rolled
`ParamStr` loops in `source/apps/`).

```
wasmlight run [--dir GUEST=HOST]... [--env KEY=VALUE]... [--] <module.wasm> [args...]
```

### 4.1 Flag parsing (lwpt cli)

`--dir` and `--env` are **repeatable** — the cli package has
`TRepeatableOption` (`AddRepeatable`), whose `.Values: TStringList`
accumulates every occurrence. The run subcommand's option array:

```pascal
RunOpts := TOptionList.Create;
DirOpt := RunOpts.AddRepeatable('dir',
  'grant a preopened directory as GUEST=HOST (repeatable)');
EnvOpt := RunOpts.AddRepeatable('env',
  'set an environment variable KEY=VALUE (repeatable)');
{ future: --no-stdin, --clock=fixed:<ns>, --seed=<n> for hermetic runs }
```

The handler receives `APositionals: TStringList` (the module path first,
then guest args) and the parsed options. `--dir guest=host` splits on the
first `=`; `--env KEY=VALUE` is passed through verbatim (splitting on the
first `=` is WASI's own convention and libc handles it, so we forward the
whole string).

### 4.2 The guest-argv passthrough problem, and its resolution

**Constraint discovered in the cli package:** `CLI.Parser.ParseCommandLine`
raises `TParseError` on any unknown `--long` token and has **no `--`
terminator** (a bare `--` is parsed as an empty-named long option and
rejected). So a guest arg that looks like a flag
(`wasmlight run app.wasm --verbose`) would make wasmlight's own parser
choke on `--verbose` before the module ever runs. Plain (non-flag-shaped)
guest args already survive — they accumulate as positionals.

**Also discovered:** the cli package's registry special-cases the literal
command name `run` for *subcommand aliasing* (`lwpt run <subcmd>`): if
argv[2] is itself a registered subcommand, it dispatches there. For
wasmlight this means `wasmlight run inspect …` would be hijacked into the
`inspect` command, and a module literally named `inspect`/`validate`/`run`
collides. This is an lwpt behaviour, not ours.

**Resolution (v1), consistent with the one documented CLI exception
already in `wasmlight.pas`:** wasmlight already renders its own top-level
help and unknown-command path by pre-scanning `ParamStr` (the documented
exception because lwpt's `PrintTopLevelHelp` hardcodes its tagline). Track
F extends that same pre-scan by one job: **locate `--` in argv; everything
after it is guest argv, captured verbatim and NOT handed to the cli
parser.** Concretely, `wasmlight.pas`'s top-level code:

1. Pre-scans `ParamStr(1..ParamCount)` for the first bare `--` **after**
   the `run` command word.
2. If found, the tokens before `--` (the module path + wasmlight's own
   `--dir`/`--env`) go through the registry/cli parser as usual; the
   tokens after `--` become `GuestArgvTail` and are appended to the
   positional module args by the run handler as opaque guest data.
3. If not found, guest args are just the positionals after the module
   (works for non-flag args; a flag-shaped guest arg without `--` is a
   usage error the parser reports — documented).

This keeps **wasmlight's own flags on the cli package** (satisfying
AGENTS.md — `--dir`/`--env` are real cli options), while treating post-`--`
tokens as what they are: not wasmlight flags, but data forwarded to the
guest. The pre-scan is the same mechanism, and the same documented
exception, as the existing top-level help handling.

> **RECOMMENDED upstream fix (not required for v1):** add a `--`
> terminator to `CLI.Parser.ParseCommandLine` (on a bare `--`, push every
> remaining `ParamStr` as a positional and stop). It is a one-branch
> change, generally useful, and would let the run handler read guest argv
> straight from its positionals with no wasmlight-side pre-scan. File it
> against lwpt (the roadmap already notes one lwpt cli gap — the
> hardcoded tagline — so this joins it). Until then, the pre-scan above
> is the v1 path.

The `run`-aliasing collision is handled by documenting that a module named
exactly `inspect`/`validate`/`run` must be given as a path with a
directory component (`./run.wasm`), which the aliasing check
(`Find(LowerCase(ParamStr(2)))`) does not match.

### 4.3 The run sequence

```
1. Decode + validate:  LoadModuleFromFile(path)          { EWasmDecodeError / EWasmValidationError -> stderr, exit 1 }
2. Build the capability set from flags:
     cfg := TWasmWasiConfig.Create
     cfg.GrantStdio                                        { deny-by-default + stdio }
     cfg.SetArgv([Basename(path)] + GuestArgs)             { argv[0] convention: §4.4 }
     for each --dir g=h:  cfg.AddPreopenDir(g, h, DEFAULT_DIR_RIGHTS)
     for each --env kv:   cfg.AddEnv(kv)
     { clock/random default to real OS (§2.2) }
3. store := TWasmStore.Create(engine);  RegisterInterpreter(store)
4. ctx := WasiContextCreate(cfg)                           { fd table: 0/1/2 + preopens 3.. }
5. linker := TWasmLinker.Create(store)
   WasiDefineAll(linker, ctx)                              { every preview1 func -> DefineFunc }
6. inst := Instantiate(store, linker, module)              { EWasmLinkError if the module imports
                                                             something outside wasi_snapshot_preview1 }
7. FindExportMemory(inst, 'memory', ctx.Memory)            { resolve the guest memory into the ctx }
   if not found and the module uses memory -> EWasmLinkError-ish: a preview1 command
   MUST export "memory"; report and exit
8. entry := FindExportFunc(inst, '_start')                 { command convention; §4.4 }
9. RunStart(store, inst)                                    { module start fn, if any, first }
10. Call(entry, [], [])  guarded:
      try Call(...) except map to exit code (§6) end
11. ExitCode := mapped code; free store; free module
```

### 4.4 Entry-point convention: `_start` (command) vs `_initialize` (reactor)

A preview1 **command** exports `_start: () -> ()` and `memory`. A
preview1 **reactor** exports `_initialize: () -> ()` and its own
functions, and does not run to completion. `wasmlight run` targets
**commands**: it calls `_start`. Decision:

- If the module exports `_start`, call it. `_start` returning normally is
  exit code 0 (unless `proc_exit` set another).
- If the module exports `_initialize` but **not** `_start`, it is a
  reactor; `wasmlight run` reports "not a command module (no `_start`)"
  and exits non-zero. Running reactor exports is an embedding-API use case
  (call `_initialize`, then call named exports via `Call`), not a `run`
  use case; v1's `run` is command-only. (A future `wasmlight run
  --invoke=<name>` could target reactors; out of v1 scope.)
- `argv[0]` = the module's basename (e.g. `app.wasm` → `app`), matching
  what a native program sees. UNCONFIRMED whether to strip the `.wasm`
  extension; wasi-libc programs generally do not care. Decision: pass the
  basename **with** extension; revisit if a real program complains.

### 4.5 stdout/stderr wiring

`cfg.GrantStdio` wires `Stdout`/`Stderr` to `TWasmWasiStream` instances
backed by the process's real fd 1/2 (via `Write`/`FileWrite` on the
handles — but per AGENTS.md's RTL policy, direct `FpWrite`/`FileWrite` on
the OS handle, not buffered `system.Write`, so a guest's `fd_write`
ordering is not scrambled by Pascal's own buffering). `fd_write(1, …)`
routes to `ctx.Fds[1].Stream.WriteBytes`. The hello-world path is exactly:
guest calls `fd_write(1, iovs, n, nwritten)` → §5 reads the iovec array and
each buffer through the chokepoint → the bytes go to `Stdout.WriteBytes` →
the host's fd 1. No fs, no env needed; stdio is the default grant.

---

## 5. Memory & marshaling for WASI — `Wasm.Wasi.Memory`

The sandbox boundary in one small unit. Every guest-memory access in the
WASI layer goes through it; the WASI functions never call `MemRangeAt`
directly and never see `Base`.

```pascal
{ Wasm.Wasi.Memory — all reads/writes bounds-checked via the chokepoint.
  Each returns a TWasmWasiErrno: weSuccess or weFault. AMem is the guest's
  exported memory handle from the context. }

{ Copy ALen bytes from guest offset AOffset into AHost. weFault if the
  range is out of bounds. Internally an unsigned, overflow-safe pre-check
  against MemSize(AMem) followed by MemRangeAt copy — never a raw deref. }
function GuestRead(const AMem: TWasmMemoryRef; const AOffset, ALen: UInt64;
  AHost: PByte): TWasmWasiErrno;

{ Copy ALen bytes from AHost into guest offset AOffset. weFault on OOB. }
function GuestWrite(const AMem: TWasmMemoryRef; const AOffset, ALen: UInt64;
  AHost: PByte): TWasmWasiErrno;

{ Typed scalar accessors at a guest offset (little-endian, wasm's byte
  order). Each is GuestRead/GuestWrite of the right width. }
function GuestReadU32(const AMem; const AOffset: UInt64; out AValue: UInt32): TWasmWasiErrno;
function GuestWriteU32(const AMem; const AOffset: UInt64; const AValue: UInt32): TWasmWasiErrno;
function GuestReadU64(const AMem; const AOffset: UInt64; out AValue: UInt64): TWasmWasiErrno;
function GuestWriteU64(const AMem; const AOffset: UInt64; const AValue: UInt64): TWasmWasiErrno;

{ Read an iovec/ciovec array: N records of (buf_ptr: ptr, buf_len: len) at
  AIovsPtr. Returns each record as a (offset, len) pair, EACH bounds-
  checked when its buffer is later touched — the array read itself is one
  bounds check, and each buffer is a further check at read/write time.
  weFault if the array or any buffer is out of bounds. Pointer width is
  the memory's address type (4 bytes on wasm32, 8 on wasm64). }
function GuestReadIoVec(const AMem: TWasmMemoryRef; const AIovsPtr: UInt64;
  const AIovsLen: UInt32; out AVecs: TArray<TWasmIoVec>): TWasmWasiErrno;
```

Rules that make this the boundary, not merely a helper:

- **Overflow-safe pre-check.** `GuestRead`/`Write` compute
  `if (AOffset > Size) or (ALen > Size - AOffset) then Exit(weFault)`
  (unsigned, never `AOffset + ALen > Size`, which wraps) against
  `MemSize(AMem)`, then copy the in-range bytes via `MemRangeAt`. Because
  the range is pre-verified in bounds, the copy never provokes a guard-page
  fault, so no `WasmInvoke` trampoline is needed inside a WASI call (WASI
  calls run *inside* the guest's `Call` trampoline anyway — the host thunk
  is on the guest side of a live trampoline — but the pre-check keeps the
  helper honest and strategy-independent).
- **A WASI function that has no granted capability for its operation
  returns the WASI errno, never performs the op.** `fd_write` to an fd
  that is not in the table → `EBADF`. `path_open` outside a preopen →
  `ENOTCAPABLE`. `clock_time_get` when the clock is denied → `ENOTCAPABLE`.
  The deny path is an ordinary i32 return value; it never raises and never
  touches the resource.
- **Every guest pointer is untrusted.** iovec offsets, path strings,
  result-struct pointers — all arrive as guest offsets and all go through
  the checked accessors. A path string is read with a bounded `GuestRead`
  of `path_len` bytes (never scanned for a NUL past the length the guest
  gave) into a host buffer, then used only for containment resolution
  (§5.3).

### 5.1 Result-struct writes

Functions that return a struct (`fd_fdstat_get`, `fd_prestat_get`,
`fd_filestat_get`, `args_sizes_get`, …) build the struct in a host-side
fixed record, then `GuestWrite` its bytes at the guest result pointer. The
struct field offsets are the UNCONFIRMED witx layouts (§3.3); the write is
one bounds-checked copy. A guest result pointer that is out of bounds is
`EFAULT` — the function computed its answer but could not deliver it, and
says so, rather than writing past the memory.

### 5.2 String/array writes (`environ_get`, `args_get`)

Two-call ABI: the guest first calls `*_sizes_get` to learn the count and
total byte size, allocates guest memory, then calls `*_get` with two
pointers (a pointer array and a byte buffer). The `_get` implementation
writes the pointer array (each entry a guest offset into the byte buffer)
and the NUL-terminated strings, all through `GuestWrite`, all bounds-
checked against the sizes the guest was told. A guest that lies about the
buffer size gets `EFAULT` on the first out-of-range write, not a host
overflow.

### 5.3 Path containment — the fs capability check

`path_open` (and every `path_*`) resolves the guest path **relative to the
dirfd's preopen host directory**, and must reject any escape:

1. The dirfd must be an open dir fd (`EBADF` otherwise) descending from a
   preopen (`Preopen >= 0`).
2. The guest path is read (bounded, §5) and normalized. Any component that
   would escape the preopen root — a leading `/` (absolute), or `..`
   ascending above the preopen — is rejected with `ENOTCAPABLE` (WASI's
   "the requested rights/scope exceed the fd's capability") or `EACCES`.
   **Symlinks are re-checked after resolution** so a symlink inside the
   preopen pointing outside it does not escape (resolve the real path and
   verify it is still under the preopen host path). UNCONFIRMED which
   errno preview1 libc expects for the escape (`ENOTCAPABLE` vs `EACCES`
   vs `EPERM`); verify against wasi-testsuite. Decision: `ENOTCAPABLE`
   for a `..`/absolute escape, `EACCES` for an OS permission denial.
3. Requested `rights_base`/`rights_inheriting` are masked by the dirfd's
   inheriting rights; a request for a right the dirfd cannot grant is
   `ENOTCAPABLE`.
4. Only then is a real OS `open` performed, under the host directory, and
   a new fd installed carrying the masked rights and its originating
   preopen index (so its own later accesses re-check containment).

This is the crux of the filesystem sandbox: **the guest names paths, but
the host resolves them under a directory it chose, and no name reaches
outside it.** The preopen is the capability; the path is data.

### 5.4 memory64

WASI preview1 predates memory64 and assumes wasm32 pointers (4-byte
offsets, 4-byte `size`/`ptr` in structs). A module with an i64-addressed
memory using preview1 is unusual; v1's stance: pointer/length arguments
arrive as the memory's address-type width, and the chokepoint takes u64
throughout, so 64-bit offsets are handled by `GuestRead`/`Write` uniformly.
Struct layouts stay 32-bit (that is the preview1 ABI). UNCONFIRMED whether
any real preview1 toolchain emits a 64-bit memory; if not, `run` MAY reject
an i64 memory with preview1 imports. Decision: accept it, treat offsets as
u64; do not special-case struct widths (preview1 structs are wasm32).

---

## 6. Error / exit model

Five ways a `wasmlight run` (or an embedding `Call`) can end. Each maps to
a distinct outcome; the error hierarchy stays intact.

### 6.1 `proc_exit(code)` — a clean, guest-requested exit (the new signal)

`proc_exit` is **not a trap** (the guest did not fault) and **not an
exception** (no wasm `throw`). It is a clean request to stop. It needs its
own signal to unwind guest execution back to the invocation boundary
without being mistaken for either. Design:

```pascal
{ Wasm.Core (beside EWasmTrap/EWasmException) — or Wasm.Engine if Core must
  stay WASI-agnostic. Decision: Wasm.Engine, because proc_exit is a host-
  surface concept and Wasm.Core's hierarchy is about guest faults. It is
  still an EWasmError subtype so the trampoline's `on E: EWasmError`
  re-raise path (InterpInvoke) carries it out cleanly. }
type
  EWasmExit = class(EWasmError)
  public
    ExitCode: Int32;
    constructor CreateExit(const ACode: Int32);
  end;
```

**How it unwinds (respecting ADR-0009).** `proc_exit`'s host callback sets
`ctx.ExitCode := code` and `raise EWasmExit.CreateExit(code)`. This is an
*ordinary Pascal raise from a host callback* — the same mechanism as a
host callback raising `EWasmError` (interp-spec §4.1). It is NOT a trap
(no `siglongjmp`, no `TrapNow`) and NOT a wasm exception. It propagates
out of the interpreter dispatch as a normal Pascal exception; `InterpInvoke`'s
`try/except on E: EWasmError` catches it, resets the frame chain and
context cursors at the top level (exactly as it does for a trap or a
staged-op error), and re-raises. It reaches `WasmInvoke`'s ground and then
the engine's `Call` guard, which recognizes `EWasmExit` and returns its
`ExitCode`.

Why a Pascal raise is correct here and not the trap longjmp: a host
callback runs on **ordinary Pascal ground above a trampoline** (interp-spec
§5.6 — the frames between the host thunk and the guest are guest frames,
but the callback itself is host code that may hold managed state and may
raise). `EWasmExit` is a host-originated raise, like `EWasmError` from a
misbehaving host func, and the interpreter's existing host-call error
path handles it. The one obligation: the raise must unwind cleanly through
the guest frames, and it does, because the trap path's TRAP-1 (no managed
state on guest frames) means an unwinding Pascal exception does not skip
managed finalizers on guest frames (there are none to skip). The GC frame
chain is reset at the `InterpInvoke` boundary. **This reuses the exception
route, not the trap route** — the right sibling, since like a wasm
exception it is a clean, non-fault unwind, but distinct from both trap and
wasm-exception in class so a host classifies it exactly.

> Alternative considered and rejected: a store flag (`ctx.ExitRequested`)
> checked at each safepoint, no exception. Rejected because it makes
> `proc_exit` non-local to check, requires every tier to poll a WASI flag
> (a host concern leaking into the tier), and does not stop execution
> promptly (the guest keeps running to the next safepoint). A raise stops
> now and needs no tier cooperation.

### 6.2 The exit-code mapping

`wasmlight run` maps the five outcomes to a process exit code:

| outcome | how it surfaces | process exit code |
| --- | --- | --- |
| `_start` returns normally, no `proc_exit` | `Call` returns | `0` |
| `proc_exit(code)` | `EWasmExit` caught by `Call` guard | `code` (the guest's value, 0–255; masked to a byte) |
| guest trap (`unreachable`, OOB, div0, …) | `EWasmTrap` | `128 + SIGABRT`? — decision below |
| uncaught guest exception (`throw` unhandled) | `EWasmException` | non-zero, distinct from trap — decision below |
| decode/validate/link failure (before run) | `EWasmDecodeError`/`EWasmValidationError`/`EWasmLinkError` | `1`, message to stderr |
| wasmlight internal bug | any other `Exception` | `70` (EX_SOFTWARE) or `1`, "internal error" to stderr |

**Trap and uncaught-exception codes — decision.** wasmtime maps a wasm
trap to exit code **128 + SIGABRT = 134** (it aborts) for a CLI run, and
`proc_exit(n)` to `n`. Following that convention keeps `wasmlight run`
composable with shells that already understand `128+signal`:

- **Trap → 134** (`128 + 6`), with the trap message (`EWasmTrap.Message`,
  e.g. `'unreachable'`, `'out of bounds memory access'`) on stderr. This
  is distinguishable from any `proc_exit(n)` for n in 0–127, and from a
  clean 0.

  > UNCONFIRMED that 134 is the exact wasmtime value across versions;
  > the load-bearing property is only that a trap yields a non-zero code
  > distinct from common `proc_exit` values and prints the trap message.
  > If matching wasmtime bit-for-bit matters, verify; otherwise 134 is a
  > defensible, documented choice.

- **Uncaught wasm exception → 1** (with the message `'uncaught
  exception'` from `EWasmException`, UNCONFIRMED per eh-spec, on stderr),
  OR a distinct code if a host wants to tell it from a trap. Decision:
  **exit 1** for an uncaught exception — it is a program-level error, not
  a hardware-style fault, and preview1 has no exceptions of its own so
  this only arises with a module using core-wasm EH and no host handler.
  Keep it distinct from a trap (134) so scripts can discriminate.

- **`proc_exit(n)` for n > 125** is a wasi-defined edge: wasi reserves
  126/127-ish for shell conventions, but preview1 passes `n` through. We
  mask to a byte (`n and $FF`) because a Unix process exit status is 8
  bits; a guest passing 256 gets 0, matching native behaviour. Document
  it.

### 6.3 A WASI errno is a normal return value, never a Pascal exception

Emphasized because it is the most common WASI outcome: `fd_write`
returning `EBADF`, `path_open` returning `ENOTCAPABLE`, `clock_time_get`
returning `EINVAL` — these are i32 values written to `AResults[0]`, and
guest execution continues. They are **not** `EWasmError`, not traps, not
exits. Only `proc_exit` (clean exit) and a host callback deciding to trap
the guest (`raise EWasmTrap`, rare in WASI — e.g. a genuinely impossible
internal state) leave the callback abnormally. The errno path is the
overwhelmingly common one and stays inside the i32 ABI.

---

## 7. Testing strategy

Track F is designed to be testable **without the network or a real
filesystem**, honoring AGENTS.md ("nothing in the test stack touches the
external network") and extending it to the clock, entropy, and fs via the
injectable seams (§2.3) and temp-dir preopens.

### 7.1 `Wasm.Engine.Test.pas` — the embedding API is unit-testable

- **Host-func round trip.** Define a Pascal host func (a `TWasmHostFunc`
  that records it was called and adds its two i32 args), hand-build a tiny
  module (via the shipped wat assembler `Wasm.Wat.Assembler`, the same
  path the `.wast` runner uses) that imports it and exports a function
  calling it, `Instantiate` with a linker that `DefineFunc`s it, `Call`
  the export, assert the host func ran and the result marshaled back.
- **Link failure.** Instantiate a module importing an undefined
  `(module,name)`; assert `EWasmLinkError` with the right message.
- **Signature mismatch.** Import `fd_write` with the wrong arity via a raw
  module; assert the linker's `FuncTypeEquals` check raises
  `EWasmLinkError`, not a silent mis-marshal.
- **Trap classification.** `Call` a function that executes `unreachable`;
  assert `EWasmTrap` (not `EWasmError`, not `EWasmException`).
- **Exported-memory read/write.** Build a module exporting a memory and a
  function that writes a byte; `Call` it, then `MemRead` and assert;
  `MemWrite` a byte and `Call` a reader. Assert an out-of-range `MemRead`
  returns `False`, never crashes.
- **HOST-1 rooting.** Build a module returning a `ref` (a `struct.new`
  result or a `funcref`), `Call` to get it, `RootRegister` it, force a
  collection (a second `Call` that allocates), assert the rooted ref is
  still valid via `RootGet`; then the negative: an *unrooted* ref is
  documented-UB and not asserted (we assert the rooted one survives, which
  is the contract).
- **EWasmException across a host frame (Track H F3/F4).** A module with an
  exported function that throws uncaught; `Call` it inside a host frame,
  catch `EWasmException`, `RootRegister(E.ExnRef)` immediately, run a
  second allocating `Call`, then read the tag/payload and assert it
  survived. This is the test the eh-spec review flagged as missing; Track
  F adds it.

### 7.2 `Wasm.Wasi.Memory.Test.pas` — the boundary in isolation

Directly exercise `GuestRead`/`GuestWrite`/`GuestReadIoVec` against a
hand-built memory: in-range copies succeed; a range straddling the end
returns `weFault`; an offset near `2^64` with a small length does not wrap
(the overflow-safe check); an iovec array partly out of bounds is
`weFault`. No engine needed beyond a store with one memory.

### 7.3 `Wasm.Wasi.Test.pas` — WASI with an injected capability set

The capability seams make every WASI function hermetically testable:

- **`fd_write` to a captured buffer.** `Stdout` is a `TWasmWasiStream`
  subclass that appends to a `TBytesStream`. Build a module that calls
  `fd_write(1, iovs, n, nwritten)` (assembled from wat), run it, assert
  the captured buffer holds the expected bytes and `nwritten` was written
  back. This is the hello-world path with no real stdout.
- **args/env.** Inject `Argv := ['prog','a','b']`, `Env := ['X=1']`; a
  module calling `args_sizes_get`/`args_get` and `environ_*` writes the
  results into its memory; assert via `MemRead`.
- **clock/random determinism.** Inject a `TWasmWasiClock` returning a
  fixed ns and a `TWasmWasiRandom` filling a constant pattern; assert the
  guest received exactly those. Determinism proves nothing touched the
  real OS.
- **`proc_exit`.** A module calling `proc_exit(42)`; assert the engine's
  `Call` raises/returns `EWasmExit` with `ExitCode = 42` and that the
  run-level mapping yields 42.
- **path_open in a temp preopen.** Create a temp directory (the test
  framework's temp-dir; deleted in teardown), preopen it, run a module
  that `path_open`s a file within it and `fd_write`s; assert the file
  contents on the host side. Then the negative: `path_open("../escape")`
  returns `ENOTCAPABLE`, and an unopened dirfd returns `EBADF`. These two
  negatives are the sandbox's proof.
- **deny-by-default.** A module that calls `path_open` with **no** preopen
  configured gets `EBADF` (no dir fd exists); `sock_*` gets `ENOTCAPABLE`.

None of these touch the network; the fs ones touch only a self-created
temp dir under the preopen, which is the sandbox working as designed.

### 7.4 The external conformance net: wasi-testsuite

`WebAssembly/wasi-testsuite` is the analogue of the core-spec `testsuite`
corpus (`tests/spec/`) for WASI: a set of precompiled `.wasm` programs
plus JSON manifests describing argv/env/preopens and expected
stdout/exit-code. It is the honest external judge for preview1, exactly as
`wasmspec` is for core. **Scope for the first slice:** the unit tests
above **plus one real hello-world `.wasm`** (a wasi-sdk-compiled program
printing to stdout and exiting) run end-to-end through `wasmlight run`,
with its output captured and asserted. Wiring the full wasi-testsuite as a
harness (a `wasmwasi` runner analogous to `wasmspec`, reading the JSON
manifests) is a follow-on wave, tracked but not v1's first slice. Vendor
the wasi-testsuite corpus (and the witx pin) under `tests/spec/wasi/` with
a `regenerate.sh`, mirroring `tests/fixtures/`.

> The first slice deliberately does **not** depend on wasi-testsuite
> passing — it depends on the injectable-seam unit tests plus one
> committed hello-world module. That keeps CI hermetic and offline while
> proving the whole path.

---

## 8. Unit layout + wave plan

### 8.1 Units and ownership (disjoint for parallelism)

| Unit | Owns | Depends on |
| --- | --- | --- |
| `Wasm.Wasi.Types` | errno enum, struct sizes/offsets, rights/oflags/fdflags/clockid/filetype constants | `Wasm.Core` only |
| `Wasm.Engine` | `TWasmLoadedModule`, `TWasmLinker`, `TWasmInstance`, `Load`/`Instantiate`/`Call`/`Mem*`, root re-exports | Store, Instantiate, Interp, Decoder, Validator, Module, Values |
| `Wasm.Wasi.Memory` | `GuestRead`/`Write`/scalar/iovec helpers | `Wasm.Engine`, `Wasm.Wasi.Types` |
| `Wasm.Wasi` | `TWasmWasiConfig`, capability set, fd table, context, every preview1 host func, `WasiDefineAll` | `Wasm.Engine`, `Wasm.Wasi.Memory`, `Wasm.Wasi.Types` |
| `source/apps/wasmlight.pas` | the `run` subcommand + the `--` pre-scan | `Wasm.Engine`, `Wasm.Wasi`, Decoder, Validator, cli |

Disjoint enough that `Wasm.Engine` (wave F1) and `Wasm.Wasi.Types` (wave
F0, trivial) can proceed in parallel; `Wasm.Wasi.Memory` and the WASI
wave-1 functions can be split by function group once `Wasm.Engine` lands.

### 8.2 Waves

- **F0 — `Wasm.Wasi.Types`.** The constant tables, transcribed from the
  pinned witx with per-constant citations. Testable in isolation (a test
  asserting a few known values against the witx). Unblocks everything.
- **F1 — `Wasm.Engine`.** The facade: load, linker, instantiate, call,
  memory accessors, root re-exports. Delivered when `Wasm.Engine.Test`
  (§7.1) is green — including the HOST-1 and F3/F4 rooting tests. This is
  the load-bearing wave; §1.4's intern-idempotency UNCONFIRMED is settled
  here (confirm or add `EnsureInterned`).
- **F2 — `Wasm.Wasi.Memory` + WASI wave-1 (MUST) functions + the WASI
  context/config/fd-table + `Wasm.Wasi`'s `WasiDefineAll` for wave-1.**
  Delivered when `Wasm.Wasi.Memory.Test` and the wave-1 half of
  `Wasm.Wasi.Test` (fd_write to a buffer, args/env, clock/random,
  proc_exit) are green. This is the hello-world-capable slice.
- **F3 — `wasmlight run`.** The subcommand, the `--dir`/`--env` flags, the
  `--` pre-scan, the capability-set assembly, the exit-code mapping, the
  one committed hello-world `.wasm` end-to-end test. Delivered when
  `wasmlight run hello.wasm` prints and exits 0, and a trapping module
  exits 134.
- **F4 — WASI wave-2 (SHOULD) fs functions via preopens.** `path_open`
  containment, the file ops, `fd_readdir`, `filestat`. Delivered when the
  temp-preopen tests (§7.3) and the containment negatives are green.
- **F5 — wasi-testsuite harness (`wasmwasi`) + wave-3 stubs.** Wire the
  JSON-manifest corpus as the external net; register the long-tail
  functions as `ENOSYS`/`ENOTCAPABLE` stubs. Honestly staged: the tally of
  passing wasi-testsuite programs is reported, not asserted-at-100%.

### 8.3 What is honestly staged/stubbed

- The **long tail of fs ops** (`path_link`/`symlink`/`readlink`/`rename`,
  `fd_advise`/`allocate`/`sync` variants, `poll_oneoff`) — wave 2 or
  stubbed `ENOSYS` until a program needs them.
- **All `sock_*`** — permanently `ENOTCAPABLE`/`ENOTSUP` in v1 (no network
  by design; there is no capability to grant one).
- **Reactors** (`_initialize`-only modules) — the engine API can drive
  them; `wasmlight run` is command-only in v1.
- **memory64 + preview1** — accepted, offsets treated as u64, struct
  widths stay wasm32; UNCONFIRMED whether any toolchain emits it.
- **Component Model** — OUT entirely (ADR-0014).

---

## 9. Scope fence + security

### 9.1 The hard invariant, restated

**Deny-by-default.** Every capability the guest has is a value the
embedder explicitly handed over. There is no code path from a guest call
to the host filesystem, clock, environment, or network that does not pass
through (a) an import the linker was explicitly told to define, and (b),
for the filesystem, a preopen the embedder chose. The default posture is:
stdio granted (the process's own descriptors), clock/random granted from
the OS for `wasmlight run` (injectable/denyable at the API), and
**nothing else** — no fs, no env, no argv beyond argv[0], no network ever.

### 9.2 The sandbox boundary is two things, and only two

1. **The memory chokepoint.** Every guest pointer the WASI layer touches
   goes through `Wasm.Wasi.Memory` → `Store.MemRangeAt`/`MemAddressAt`,
   bounds-checked, overflow-safe. A malicious guest cannot escape via a
   bad pointer: it gets `EFAULT`. The WASI layer never holds `Base` and
   never does raw pointer arithmetic on a memory.
2. **The capability checks.** Every fd is either a std stream, a preopen,
   or derived from a preopen under masked rights. A fabricated fd →
   `EBADF`. A path escaping a preopen → `ENOTCAPABLE`/`EACCES`. An
   operation without its right → `ENOTCAPABLE`. An ungranted clock/socket
   → `ENOTCAPABLE`. A malicious guest cannot reach a resource it was not
   given.

Everything else — traps, exceptions, the tier seam — is the shipped
runtime's, unchanged.

### 9.3 What a security review of this surface must check

- **No `Base` leak.** Grep the WASI units for any use of a memory's `Base`
  or any pointer arithmetic on guest memory outside `Wasm.Wasi.Memory`.
  There must be none. The store keeps `FMemories` private for this reason;
  confirm `Wasm.Engine` does not widen it.
- **Every guest offset is checked before use.** No `GuestRead`/`Write`
  bypass; no reading a path string past its declared length; no scanning
  for a NUL in guest memory.
- **Overflow-safe bounds arithmetic everywhere.** `offset > size` and
  `len > size - offset`, never `offset + len > size`. One wrong comparison
  is an OOB read.
- **Path containment cannot be escaped** by `..`, absolute paths, or a
  symlink resolving outside the preopen. The post-resolution real-path
  re-check is present.
- **Rights masking is monotonic.** A derived fd never gains a right its
  parent dirfd's inheriting rights did not include.
- **The default is deny.** A `TWasmWasiConfig` with no preopens exposes no
  filesystem; assert that `path_open` with no preopen is `EBADF`, not a
  host open of the process CWD.
- **`proc_exit` cannot be turned into an escape.** It only sets an exit
  code and unwinds; it touches no host resource.
- **The prohibited actions stay prohibited.** WASI grants file operations
  *within a preopen* — including `path_unlink_file` inside a granted
  directory, which is the guest deleting its own sandboxed data, not host
  data. There is no WASI path to entering credentials, executing a
  financial action, or deleting host data outside a preopen; the capability
  model makes those unreachable by construction.
- **ADR-0008 single-thread.** `Wasm.Engine` adds no locks; a store is one
  thread's. Confirm no WASI state is shared across stores.

### 9.4 Out of scope (fenced)

- The **Component Model** and the canonical ABI (ADR-0014) — post-v1.
- **Threads / shared memory** (ADR-0008) — a store is one thread's;
  WASI's threads proposal is not preview1 and is out.
- **Networking** — no `sock_*` capability is grantable in v1.
- **The full wasi-testsuite pass rate** — the first slice proves the path
  with unit tests + one hello-world; the corpus tally is reported, not a
  gate.
