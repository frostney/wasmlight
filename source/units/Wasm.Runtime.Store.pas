{ Wasm.Runtime.Store — the engine-wide canonical type table, the store,
  and the instance records everything above the chokepoints reads.

  Two things live here that look unrelated and are not.

  (1) THE ENGINE TYPE TABLE. Validation produces canonical type ids that
  are MODULE-LOCAL and says so (Wasm.Ir: "Canonical type ids are
  MODULE-LOCAL … a later layer re-interns the keys and remaps"). The spec
  agrees: "Runtime type checks generally involve types from multiple
  modules or types not defined by a module at all, such that any
  module-local type indices occurring inside them would not generally be
  meaningful" (`exec-type`), and module allocation "is defined in terms of
  rolling and substitution of all preceding types to produce a list of
  closed defined types" (`alloc-module`). TWasmEngine is that stage: every
  rec group's serialised key — already ROLLED, so two structurally
  identical groups from two different modules compare equal — is looked up
  in one engine-wide intern table, and the module gets a remap from its
  own ids into engine ids. `call_indirect`'s runtime check, `ref.cast`,
  and import matching all compare engine ids and nothing else.

  (2) THE STORE. "The store represents all global state that can be
  manipulated by WebAssembly programs … functions, tables, memories,
  globals, tags, element segments, data segments, and structures, arrays
  or exceptions" (`syntax-store`). One thread, no locks, no atomics
  (ADR-0008): the cost of synchronisation is paid on every access forever,
  and that is the thing the ADR exists to avoid.

  ADDRESSES ARE INDICES. `TWasmFuncAddr` and friends are u32 indices into
  grow-only arrays, never pointers: the array may reallocate and a raw
  pointer into it would dangle. Nothing is ever removed — "implementations
  may apply techniques like garbage collection … such techniques are not
  semantically observable" (`syntax-store`), and only the GC heap
  reclaims, which holds no addresses.

  LIFETIME (ADR-0003), the rules the Pascal compiler cannot check:

    1. The module buffer outlives the IR module, which outlives every
       module instance, which outlives the store's use of it. Concretely,
       TWasmModuleInstance.Bytes must stay valid and unmoved for as long
       as the instance is in Store.Instances.
    2. TWasmIrModule is BORROWED by an instance, never owned. One IR
       module may back many instances, in one store or several. Freeing it
       under a live instance is a use-after-free with no diagnostic.
    3. The only run-time consumer of the buffer is data-segment
       initialisation and the bulk ops that read a data segment. Once
       every data segment is dropped the buffer is no longer read, which
       is what BorrowsBuffer reports — ADR-0003 names WAMR's "is the
       underlying binary freeable" query as the honest way to make the
       contract checkable rather than documented.

  TYPES STORED HERE ARE IN ENGINE SPACE. A TWasmTableType or
  TWasmGlobalType held by a table or global instance has every concrete
  heap type naming an ENGINE id in its TypeIndex field, not a module type
  index. This is deliberate and it is what makes cross-module import
  matching possible with no module in hand ("It is an invariant of the
  semantics that all types occurring during execution are closed" —
  `exec-type`). EngineValueType / EngineRefType are the one conversion.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004).
  Anchors: syntax-store, syntax-moduleinst, syntax-hostfunc,
  syntax-tableinst, syntax-globalinst, syntax-taginst, syntax-eleminst,
  syntax-datainst, exec-type, alloc-module, subtyping, match-deftype
  (Deftype_sub/refl, Deftype_sub/super), match-heaptype, match-externtype
  (Externtype_sub/*), match-limits (Limits_sub/*), match-tabletype,
  match-memtype, match-globaltype (Globaltype_sub/*), match-tagtype,
  valid-tableinst, valid-meminst, table.get / table.init (trap messages). }
unit Wasm.Runtime.Store;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Ir,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator,
  Wasm.Validator.Types;

type
  { An engine-global canonical type id. Never a module type index and
    never a module-local canonical id; mixing the three is the failure
    this whole unit exists to prevent. }
  TWasmEngineTypeId = UInt32;
  TWasmEngineTypeIds = array of TWasmEngineTypeId;

  TWasmFuncAddr = UInt32;
  TWasmTableAddr = UInt32;
  TWasmMemAddr = UInt32;
  TWasmGlobalAddr = UInt32;
  TWasmTagAddr = UInt32;
  TWasmElemAddr = UInt32;
  TWasmDataAddr = UInt32;

  TWasmAddrs = array of UInt32;

const
  { The absent address. Also the "this canonical id has no engine id yet"
    marker inside the interner, where it is a genuine invariant check
    rather than a value anything stores. }
  WASM_NO_ADDR = High(UInt32);

type
  { One engine-wide canonical type.

    Comp is in ENGINE space: every concrete heap type inside it names an
    engine id. Display is the ancestor chain root-first with this type
    last, also in engine ids, so `A <: B` is
    `Depth(B) <= Depth(A) and Display(A)[Depth(B)] = B` — two array reads,
    which is what ref.cast wants on the hot path (`match-deftype`, rules
    Deftype_sub/refl and Deftype_sub/super). Kind is hoisted out of Comp
    because the abstract-hierarchy test reads it and nothing else. }
  TWasmEngineType = record
    Comp: TWasmCompType;
    IsFinal: Boolean;
    Display: TWasmEngineTypeIds;
    Depth: UInt32;
    Kind: TWasmCompKind;
  end;

  { The engine outlives every store built on it. It is not owned by a
    store and several stores may share one; that is the point, since two
    stores holding the same module's types must agree about them.

    Growth is MONOTONE. Engine types are never removed, so a long-lived
    engine instantiating many distinct modules grows its table — bounded
    by the number of DISTINCT rec groups ever seen, not by module count.
    That is the price of O(1) cross-module casts. }
  TWasmEngine = class
  private
    FTypes: array of TWasmEngineType;
    FTypeCount: Integer;

    { The collector's byte layouts, one per engine type, computed when the
      type is materialised and never again. OWNED BY THE ENGINE rather
      than by a heap for the same reason displays are: a layout is a pure
      function of the engine type, engine types outlive any one store, and
      recomputing them per store would be the same answer twice. The heap
      borrows this. }
    FGcTypes: TWasmGcTypes;

    { The intern table over ROLLED group keys. Same shape as
      TWasmTypeContext's private one and for the same reasons: parallel
      arrays, a u32 hash as a cheap reject, a linear scan. Promote to real
      buckets only on measurement — a type section is small and this runs
      once per (engine, module) pair. }
    FGroupHashes: array of UInt32;
    FGroupKeys: array of TWasmBytes;
    FGroupBases: array of TWasmEngineTypeId;
    FGroupSizes: array of UInt32;
    FGroupCount: Integer;

    function LookupGroup(const AKey: TWasmBytes; const AHash: UInt32;
      out ABase: TWasmEngineTypeId): Boolean;
    procedure AddGroup(const AKey: TWasmBytes; const AHash: UInt32;
      const ABase: TWasmEngineTypeId; const ASize: UInt32);
    function AllocateTypes(const ACount: UInt32): TWasmEngineTypeId;
    procedure MaterialiseGroup(const AIr: TWasmIrModule;
      const ALocalBase: UInt32; const ABase: TWasmEngineTypeId;
      const ASize: UInt32; const AMap: TWasmEngineTypeIds);
    function RewriteValType(const AType: TWasmValueType;
      const AMap: TWasmEngineTypeIds): TWasmValueType;
    function RewriteFieldType(const AField: TWasmFieldType;
      const AMap: TWasmEngineTypeIds): TWasmFieldType;
    function RewriteCompType(const AComp: TWasmCompType;
      const AMap: TWasmEngineTypeIds): TWasmCompType;
  public
    constructor Create;
    destructor Destroy; override;

    { Re-intern AIr's rec groups and produce the two remaps the runtime
      needs:

        ACanonToEngine   one entry per MODULE-LOCAL canonical id
        ATypeIndexToEngine one entry per MODULE TYPE INDEX

      Both are needed because the IR spells some things in canonical ids
      (FuncCanonTypes, Tags) and others in type indices (Tables, Globals,
      and every value type inside them).

      Idempotent: interning the same module twice produces the same ids
      and allocates nothing the second time. The design contract proposed
      caching the remap ON the IR module; that record belongs to Track B
      and Track D does not extend it, and an engine-side cache keyed by
      the module POINTER would alias a freed module reallocated at the
      same address. Re-interning hits every group on the second call and
      is O(groups x key length), which is not on any hot path.

      Raises EWasmError if the IR's group keys and canonical table
      disagree — an internal invariant violation, never a module defect
      (ADR-0007: the runtime does not re-derive a validator rule). }
    procedure InternModule(const AIr: TWasmIrModule;
      out ACanonToEngine: TWasmEngineTypeIds;
      out ATypeIndexToEngine: TWasmEngineTypeIds);

    function TypeCount: Integer;
    function GroupCount: Integer;
    function EngineType(const AId: TWasmEngineTypeId): TWasmEngineType;

    { The collector's layout table for these types. Every store built on
      this engine hands it to its heap. }
    property GcTypes: TWasmGcTypes read FGcTypes;

    { The O(1) display test. `match-deftype`. }
    function Matches(const ASub, ASuper: TWasmEngineTypeId): Boolean;
    { The abstract heap type a concrete engine type sits under
      (Heaptype_sub/struct, /array, /func). }
    function AbsKindOf(const AId: TWasmEngineTypeId): TWasmAbsHeapType;

    { The structural matching relation over ENGINE-space types. Mirrors
      TWasmTypeContext's, with two differences: concrete heap types name
      engine ids, and the bottom type cannot occur — BOT "is deliberately
      NOT representable in the binary format … it exists only during
      validation" (Wasm.Validator.Types), so nothing that reaches a store
      can carry one. }
    function MatchesHeapType(const A, B: TWasmHeapType): Boolean;
    function MatchesRefType(const A, B: TWasmRefType): Boolean;
    function MatchesValType(const A, B: TWasmValueType): Boolean;
  end;

  TWasmFuncKind = (wfkWasm, wfkHost);

  TWasmStore = class;

  { A host function. Params and Results are frame slices the caller owns;
    the callee writes its results in place. Raising EWasmTrap from a host
    function is legal and is the host's way to trap. }
  TWasmHostFunc = procedure(const AStore: TWasmStore; const AData: Pointer;
    const AParams: PWasmValue; const AResults: PWasmValue);

  TWasmModuleInstance = class;

  { "A function instance … effectively is a closure of the original
    function over the runtime module instance of its originating module"
    (`syntax-hostfunc`).

    FLAT rather than a variant record. The design contract spelled the
    wasm and host halves as a `case`; the saving is one machine word on a
    record allocated once per function per instantiation, and a variant
    part holding a class reference is the kind of thing that compiles
    differently across FPC targets. Kind is the discriminator and the
    unused half is zero.

    FuncIrIndex indexes Ir.Functions (DEFINED functions, code order),
    never the module function index space. The conversion is
    `IrIndex = ModuleIndex - Ir.FuncImportCount`, and it is done ONCE at
    instantiation so no call path re-derives it. }
  TWasmFuncInst = record
    Kind: TWasmFuncKind;
    { Engine-global canonical type id — what call_indirect compares. }
    TypeId: TWasmEngineTypeId;
    { The heap handle ref.func returns. Stable for the life of the
      instance. }
    RefObject: TWasmRef;
    { wfkWasm }
    Instance: TWasmModuleInstance;   { BORROWED }
    FuncIrIndex: UInt32;
    { --- baseline-JIT tier seam (O-J1, jit-spec §4.1/§4.2) -------------
      The JIT annotates a wfkWasm function here; both are zero for a host
      function and zero-initialised for a wasm one.

      CompiledEntry is nil until the JIT compiles this function. nil means
      "not compiled -> interpret"; once the JIT sets it, it is the entry
      point of the compiled machine code and every call site dispatches to
      it (through TWasmStore.JitInvokeCompiled) instead of the interpreter.
      The call-site check is a single predicted-not-taken branch, so a store
      with no JIT registered — where this stays nil forever — runs exactly
      as before.

      CallCount is the compile-on-hot counter (jit-spec §4.2). The
      interpreter Inc's it on each INTERPRETED call into the function; the
      JIT reads it and compiles once it crosses the driver's threshold. The
      interpreter only maintains the counter — the compile decision and the
      threshold belong to Wasm.Jit. }
    CompiledEntry: Pointer;
    { Same machine-code address only when the body cannot publish a pending
      return_call*. Direct native callers use this stricter pointer so a
      tail-calling body always stays on the invocation trampoline that consumes
      and re-dispatches its pending target. }
    CompiledDirectEntry: Pointer;
    CallCount: UInt32;
    { wfkHost }
    Callback: TWasmHostFunc;
    HostData: Pointer;               { opaque to the runtime }
  end;

  TWasmFuncInsts = array of TWasmFuncInst;

  { "A table instance … records its type and holds a sequence of reference
    values … It is an invariant of the semantics that all table elements
    have a type matching the element type of tabletype"
    (`syntax-tableinst`).

    Elements are TWasmRef uniformly — funcref, externref, anyref, exnref,
    all the same slot with the same encoding. The element type is static
    and the validator already checked every write against it, so the
    runtime performs NO element type check on table.set.

    TableType is in ENGINE space. Its Limits.Min is the DECLARED minimum
    and is not maintained as the table grows; the current size is
    Length(Elems), which is what the instance's type reports
    (`valid-tableinst`: "The length of ref* must equal n"). }
  TWasmTableInst = record
    Elems: array of TWasmRef;
    TableType: TWasmTableType;
    { Effective maximum: min(declared max when present, the ceiling for
      the address type). Computed once. }
    MaxSize: UInt64;
    HasMax: Boolean;
  end;

  TWasmTableInsts = array of TWasmTableInst;

  { "A global instance … records its type and holds an individual value"
    (`syntax-globalinst`). GlobalType is in ENGINE space.

    Imported globals are SHARED, not copied: an instance's GlobalAddrs
    entry points at the exporting instance's global, so a global.set
    through an imported mutable global is visible to the exporter. That
    falls out of addresses-being-indices and is the spec's model. }
  TWasmGlobalInst = record
    Value: TWasmValue;
    { Used iff GlobalType's value type is wvkVec (simd-spec §1.7). A
      dedicated 16-byte cell rather than a two-slot pair keeps every scalar
      global accessor branch-free; the vector path has its own IR ops
      (iroGlobalGetVec / iroGlobalSetVec). A v128 is never a reference, so
      this never participates in the root scan. }
    Vec: TWasmV128;
    GlobalType: TWasmGlobalType;
  end;

  TWasmGlobalInsts = array of TWasmGlobalInst;

  { "A tag instance … records the defined type of the tag"
    (`syntax-taginst`). That is the whole instance.

    Tag IDENTITY IS THE ADDRESS: two tags with identical types are
    different tags and a catch matches on tagaddr equality, never on type
    equality. TypeId exists for import matching and for the payload shape
    Track H needs. }
  TWasmTagInst = record
    TypeId: TWasmEngineTypeId;
  end;

  TWasmTagInsts = array of TWasmTagInst;

  { "An element instance … is the runtime representation of an element
    segment. It holds a vector of references" (`syntax-eleminst`).
    Dropping empties it; the instance stays, because elem addresses are
    never removed from the store. }
  TWasmElemInst = record
    RefType: TWasmRefType;      { ENGINE space }
    Refs: array of TWasmRef;
    Dropped: Boolean;
  end;

  TWasmElemInsts = array of TWasmElemInst;

  { A data instance holds a SPAN into the module buffer, not a copy
    (ADR-0003). Dropping sets Dropped and zeroes the span; it frees
    nothing, because the buffer belongs to the embedder. }
  TWasmDataInst = record
    Data: PByte;                { BORROWED — into the module buffer }
    Size: NativeUInt;
    Dropped: Boolean;
  end;

  TWasmDataInsts = array of TWasmDataInst;

  { "A module instance … collects runtime representations of all entities
    that are imported, defined, or exported by the module. Each component
    references runtime instances … in the order of their static indices"
    (`syntax-moduleinst`). Imports occupy the low indices of every space,
    exactly as the IR's snapshots do. }
  TWasmModuleInstance = class
  public
    { --- borrowed, ADR-0003 (see the unit header) --------------------- }
    Ir: TWasmIrModule;
    Bytes: PByte;
    BytesLength: NativeUInt;

    { --- index spaces ------------------------------------------------- }
    FuncAddrs: TWasmAddrs;
    TableAddrs: TWasmAddrs;
    MemAddrs: TWasmAddrs;
    GlobalAddrs: TWasmAddrs;
    TagAddrs: TWasmAddrs;
    ElemAddrs: TWasmAddrs;
    DataAddrs: TWasmAddrs;

    { --- engine ids, one per MODULE TYPE INDEX ------------------------
      The runtime never uses Ir.TypeIndexToCanon directly: those ids are
      module-local. EngineCanonIds is the companion map, one entry per
      module-local CANONICAL id, for the IR fields spelled that way. }
    EngineTypeIds: TWasmEngineTypeIds;
    EngineCanonIds: TWasmEngineTypeIds;

    { --- exports ------------------------------------------------------
      "It is an invariant of the semantics that all export instances in a
      given module instance have different names" (`syntax-moduleinst`);
      the validator already enforced MSG_DUPLICATE_EXPORT_NAME. }
    ExportNames: array of string;
    ExportKinds: array of TWasmExternKind;
    ExportAddrs: TWasmAddrs;

    { --- pending start ------------------------------------------------ }
    HasPendingStart: Boolean;
    PendingStartFuncIndex: UInt32;

    { The wokFuncRef handles this instance's DEFINED functions own. Roots
      for the collector once Wave 5 lands, and the reason ref.func returns
      the same pointer every time. }
    FuncRefObjects: array of TWasmRef;

    { True while at least one data segment is undropped — i.e. while
      Bytes must stay alive and unmoved. ADR-0003's lifetime rule is
      otherwise uncheckable; Track F surfaces this (contract HOST-2). }
    function BorrowsBuffer(const AStore: TWasmStore): Boolean;

    function FindExport(const AName: string; out AKind: TWasmExternKind;
      out AAddr: UInt32): Boolean;
  end;

  TWasmModuleInstances = array of TWasmModuleInstance;

  { The tier seam, in full. One procedure variable, nil until Track E sets
    it. Keeping it to a single field is deliberate: Track D has no opinion
    about how a tier runs a function, only about who asks it to. }
  TWasmTierInvokeProc = procedure(const AStore: TWasmStore;
    const AFuncAddr: TWasmFuncAddr; const AParams: PWasmValue;
    const AResults: PWasmValue);

  { The baseline JIT's compiled-invocation hook (O-J1, jit-spec §4.1/§4.4).
    nil until Wasm.Jit registers it; the interpreter calls it INSTEAD of its
    own dispatch loop whenever a wasm callee's CompiledEntry <> nil. The
    contract is the SAME flat seam a wasm entry and a host call already use:
    AParams / AResults are flat slot arrays (a v128 occupies two consecutive
    slots, low half first, in wasm operand order), so params and results
    marshal identically whether the callee is compiled or interpreted — the
    observational-identity property the tier seam turns on. The hook resolves
    AStore.Funcs[AFuncAddr].CompiledEntry itself, sets up the callee's frame
    through the shared JitEnterFrame / JitLeaveFrame helpers (so a compiled
    frame is bit-identical to an interpreted one), runs the compiled code to
    completion, and writes the flat results into AResults. There is no OSR:
    it runs the whole callee and returns. Shape matches TWasmTierInvokeProc
    deliberately. }
  TWasmJitInvokeProc = procedure(const AStore: TWasmStore;
    const AFuncAddr: TWasmFuncAddr; const AParams: PWasmValue;
    const AResults: PWasmValue);

  TWasmStore = class
  private
    FEngine: TWasmEngine;
    FOwnerThread: TThreadID;
    { The GC heap, OWNED. Its layout table comes from the engine, so two
      stores on one engine agree about every object's shape. }
    FHeap: TWasmGcHeap;
    { The reference-typed globals, densely. Every global of reference type
      is a root unconditionally, mutable or not; filtering the whole
      global array on every cycle would be the wrong shape for a store
      with thousands of numeric globals, so the filter runs once, at
      allocation. }
    FRefGlobals: array of TWasmGlobalAddr;
    FRefGlobalCount: Integer;
    { EvalInitExpr's frame, per TRAP-1 rule 4: init-expression frames come
      from one per-store buffer rather than a per-call dynamic array, so a
      frame a longjmp skips leaks nothing. Init expressions do not nest. }
    FScratch: array of TWasmValue;
    { The companion stack map for that frame — contract GC-1 applies to an
      init-expression frame exactly as it does to a function's, and
      TWasmIrInitExpr carries RegTypes but no precomputed ref bits, so the
      projection is computed here the same way IrComputeRefRegBits
      computes it for a function. }
    FScratchBits: array of UInt32;
    { Linear memories are PRIVATE, deliberately: exposing the array let any
      caller compute `Memories[i].Base + n` and dereference it, bypassing
      the one memory-access chokepoint (ADR-0005: "a new caller that
      bypasses the chokepoint is the failure mode this design is most
      exposed to"). Byte access is only through MemRangeAt / MemAddressAt,
      which route to Wasm.Runtime.Memory's MemRange / MemAddress and trap
      identically; metadata reads go through MemoryAddrType / MemoryCount /
      MemMatchesImport, none of which hand out Base. }
    FMemories: array of TWasmMemoryInst;
  public
    { --- spec store categories (`syntax-store`) ----------------------- }
    Funcs: TWasmFuncInsts;
    Tables: TWasmTableInsts;
    Globals: TWasmGlobalInsts;
    Tags: TWasmTagInsts;
    Elems: TWasmElemInsts;
    Datas: TWasmDataInsts;

    Instances: TWasmModuleInstances;   { OWNED }

    { ADR-0006. A plain UInt64, no atomic: ADR-0008 confines the store, and
      a host interrupting from another thread is a deliberate cross-thread
      write of one aligned word that the guest only reads. Documented as
      the single exception; do not generalise it. }
    Epoch: UInt64;

    { The per-invocation epoch SNAPSHOT (ADR-0006, jit-spec §6). Captured ONCE
      at the outermost guest-entry (Wasm.Interp.InterpTierInvoke, when a fresh
      invocation begins) as EpochSnapshot := Epoch, and read — never written —
      by BOTH tiers at their back-edge safepoints: the interpreter seeds its
      Run-local EpochCache from it, and every compiled function's prologue
      loads it into its snapshot register. A nested wasm->wasm call (compiled
      or interpreted) does NOT overwrite it, so a compiled leaf called mid-
      invocation inherits the invocation's ORIGINAL snapshot and traps
      'interrupt' at the same point the interpreter would — closing the
      epoch-interrupt observational-identity gap between tiers. A host->guest
      re-entry is a new outermost invocation and re-snapshots; because both
      tiers capture the value into stack-local / callee-saved state at entry,
      that re-snapshot never disturbs an outer activation already running.
      Kept beside Epoch (a store field, not the interp context) because the
      compiled entry receives the store pointer but not the context, so this
      is the one location both tiers can reach. Confined to the store's thread
      (ADR-0008); no atomic. }
    EpochSnapshot: UInt64;

    TierInvoke: TWasmTierInvokeProc;

    { The baseline JIT's compiled-invocation hook (O-J1, jit-spec §4.1). nil
      until Wasm.Jit's RegisterJit sets it; when a wasm callee carries a
      non-nil CompiledEntry the interpreter dispatches through this instead
      of running its own loop for that callee. Set beside the per-function
      CompiledEntry pointers, so leaving it nil (no JIT) means every function
      runs interpreted and nothing observable changes. A plain procedure var,
      not a method or closure — the TRAP-1 discipline the tier fields already
      follow (Wasm.Runtime.Traps). }
    JitInvokeCompiled: TWasmJitInvokeProc;

    { The per-process AOT/JIT helper table base (aot-spec §1.2/§4.3): a raw
      pointer to a contiguous array[TWasmAotHelper] of Pointer holding the LIVE
      addresses of the active backend's runtime helpers (JitTrapKind, JitOpBinary,
      the call/tail/dispatch thunks). nil until RegisterJit fills it. Every
      position-independent compiled function pins this base in a callee-saved
      register and reaches a helper by INDEX (`ldr xT,[base,#k*8]; blr xT` /
      `call [base+k*8]`), so generated code holds only the stable slot index —
      never a baked absolute helper address. That is what makes the code
      relocatable across processes, the prerequisite the AOT tier depends on.
      Set beside JitInvokeCompiled; a plain pointer, TRAP-1 clean (the addresses
      are process-global constants). }
    JitHelperTable: PPointer;

    { The tier's per-store execution context (O-10). Opaque here, exactly
      like TierInvoke: nil until Track E's RegisterInterpreter sets it, and
      never interpreted by Track D. The interpreter's TWasmInterpContext —
      the two fixed value-stack / activation reservations (interp-spec §1.1,
      §7.3) — lives behind this pointer, so the store owns the context's
      lifetime with NO external map keyed by store.

      RegisterInterpreter(Store) sets all THREE together —
      TierInvoke (the dispatch entry), TierContext (this pointer), and
      TierContextFree (the teardown hook below) — and TWasmStore.Destroy
      frees the context by calling TierContextFree(TierContext). }
    TierContext: Pointer;
    { The teardown hook for TierContext (O-10). A plain procedure var, not a
      method or closure (managed state a trap unwind cannot tolerate — the
      TRAP-1 discipline in Wasm.Runtime.Traps). nil-safe: Destroy calls it
      only when BOTH TierContext and TierContextFree are set. Set by
      RegisterInterpreter alongside TierInvoke/TierContext; it frees the two
      GetMem reservations the context owns and then the context record. }
    TierContextFree: procedure(AContext: Pointer);

    constructor Create(const AEngine: TWasmEngine);
    destructor Destroy; override;

    property Engine: TWasmEngine read FEngine;
    property OwnerThread: TThreadID read FOwnerThread;
    { The collector. OWNED by the store and confined to its thread with
      everything else (ADR-0008). }
    property Heap: TWasmGcHeap read FHeap;

    { ADR-0008's confinement check, in non-PRODUCTION builds only. The ADR
      says violation "is undefined behaviour rather than a detected error
      unless a debug-build check makes it detectable" and that detecting
      it "is a deliberate feature with a cost" — a debug-only check is
      that feature at zero production cost. Raises EWasmError, not a trap:
      it is host misuse, not a guest fault. }
    procedure CheckThread;

    { --- allocation into the store ------------------------------------
      Every one of these appends and returns the new address. Nothing is
      ever removed. }
    function AddWasmFunc(const ATypeId: TWasmEngineTypeId;
      const AFuncIrIndex: UInt32): TWasmFuncAddr;
    function AddHostFunc(const ATypeId: TWasmEngineTypeId;
      const ACallback: TWasmHostFunc;
      const AData: Pointer): TWasmFuncAddr;
    { ATableType must already be in ENGINE space. }
    function AddTable(const ATableType: TWasmTableType;
      const AInit: TWasmRef): TWasmTableAddr;
    function AddMemory(const AMemType: TWasmMemType): TWasmMemAddr;
    { --- linear memory, read-only surface (B23) -----------------------
      The only way to reach a memory's bytes or metadata from outside the
      store. Nothing here returns Base; byte access traps through the
      chokepoint exactly as a tier's would. }
    function MemoryCount: Integer;
    function MemoryAddrType(const AAddr: TWasmMemAddr): TWasmAddrType;
    { The two chokepoint forms, per memory address. ASize is 1/2/4/8/16. }
    function MemAddressAt(const AAddr: TWasmMemAddr;
      const AIndex, AOffset: UInt64; const ASize: NativeUInt): PByte;
    function MemRangeAt(const AAddr: TWasmMemAddr;
      const AIndex, ALength: UInt64): PByte;
    { Import matching without exposing the instance — MatchMemImport reads
      only size/limit metadata, never Base. }
    function MemMatchesImport(const AAddr: TWasmMemAddr;
      const ADeclared: TWasmMemType): Boolean;
    { memory.size / memory.grow surface for a tier (interp-spec §3.7). Neither
      exposes Base. MemoryPages reports the current size in pages; MemoryGrow
      wraps Wasm.Runtime.Memory.MemoryGrow and returns the previous size in
      pages or -1 (`exec-memory.grow` can_trap:false — growth fails, it does
      not trap, and it never runs the collector). }
    function MemoryPages(const AAddr: TWasmMemAddr): UInt64;
    function MemoryGrow(const AAddr: TWasmMemAddr; const ADelta: UInt64): Int64;
    { --- table mutation, barriered (A6) -------------------------------
      A table is a ROOT ARRAY, so every reference store into one is a
      write-barrier site the GC contract names (Wasm.Runtime.Gc's
      WriteBarrier doc: table.set / table.fill / table.copy / table.init and
      table.grow's tail fill). These are METHODS rather than free functions
      precisely so the barrier — which needs the heap — cannot be skipped by
      a caller holding only a `var TWasmTableInst`. Reads (TableGet,
      TableCheckRange, TableSize) stay free: a load is not a barrier site.
      The barrier is empty in v1; wiring the sites now is what makes the
      generational retrofit free (ADR-0006). }
    procedure TableSet(const AAddr: TWasmTableAddr; const AIndex: UInt64;
      const ARef: TWasmRef);
    procedure TableFill(const AAddr: TWasmTableAddr;
      const AIndex, ACount: UInt64; const ARef: TWasmRef);
    function TableGrow(const AAddr: TWasmTableAddr; const ADelta: UInt64;
      const AInit: TWasmRef): Int64;
    { table.init / active-elem application: copy refs from an element
      instance's Refs (ASrc) into table AAddr at ADstOffset, barriered.
      Traps `out of bounds table access` unless the whole destination range
      is in bounds — the range check precedes any write.

      The WHOLE-array form (instantiation's active-segment application) and
      the SLICED form (O-2, the interpreter's table.init needs a src slice)
      overload one name. The sliced form range-checks BOTH sides: the
      destination against the table, and [ASrcOffset, ASrcOffset+ACount)
      against the element instance's length — a dropped segment reads as
      empty, so any non-empty slice of it traps `out of bounds table
      access` (exec-table.init; corpus table_init.wast). }
    procedure TableInitFromElem(const AAddr: TWasmTableAddr;
      const ADstOffset: UInt64; const ASrc: array of TWasmRef); overload;
    procedure TableInitFromElem(const AAddr: TWasmTableAddr;
      const ADstOffset: UInt64; const ASrc: array of TWasmRef;
      const ASrcOffset, ACount: UInt64); overload;
    { table.copy: copy ACount refs from table ASrcAddr at ASrcIdx into table
      ADestAddr at ADstIdx, barriered and overlap-safe (memmove semantics
      when the two addresses name the same table). Range-checks BOTH tables
      before any write, trapping `out of bounds table access`
      (exec-table.copy; corpus table_copy.wast). The store owns the barrier
      site (O-2). }
    procedure TableCopy(const ADestAddr: TWasmTableAddr; const ADstIdx: UInt64;
      const ASrcAddr: TWasmTableAddr; const ASrcIdx: UInt64;
      const ACount: UInt64);
    { AGlobalType must already be in ENGINE space. }
    function AddGlobal(const AGlobalType: TWasmGlobalType;
      const AValue: TWasmValue): TWasmGlobalAddr;
    { A v128 global: the 16-byte initial value goes to the Vec cell. A
      vector is never a reference, so this never joins the root list. }
    function AddGlobalVec(const AGlobalType: TWasmGlobalType;
      const AVec: TWasmV128): TWasmGlobalAddr;
    function AddTag(const ATypeId: TWasmEngineTypeId): TWasmTagAddr;
    function AddElem(const ARefType: TWasmRefType): TWasmElemAddr;
    function AddData(const AData: PByte;
      const ASize: NativeUInt): TWasmDataAddr;

    { The funcaddr a wokFuncRef handle names. The handle itself now comes
      from the collector (TWasmGcHeap.AllocFuncRef) rather than from a
      store-private block list: the layout was always the collector's, and
      a funcref handle IS a heap object — which is why every
      Funcs[i].RefObject is enumerated as a root below. }
    function FuncRefAddr(const ARef: TWasmRef): TWasmFuncAddr;

    { The init-expression frame buffer (TRAP-1 rule 4). }
    function ScratchFrame(const ACount: UInt32): PWasmValue;
    { Its stack map: bit i set iff ARegTypes[i] is a reference type. The
      buffer is per-store for the same reason the frame is. }
    function ScratchRefBits(const ARegTypes: TWasmIrRegTypes;
      const ACount: UInt32): PWasmGcRefBits;

    { Run the start function recorded at instantiation.

      With no tier registered this raises EWasmError — deliberately NOT
      EWasmTrap and NOT EWasmLinkError, because neither is true: the
      module linked, and no guest code faulted. When Track E lands this
      goes through WasmInvoke and a trap in the start function propagates
      as EWasmTrap, matching `exec-module`. }
    procedure RunPendingStart(const AInstance: TWasmModuleInstance);

    { Takes ownership of AInstance. }
    function AddInstance(
      const AInstance: TWasmModuleInstance): TWasmModuleInstance;
  end;

const
  { Wave 4's staged errors, spelled once each. }
  MSG_START_NEEDS_TIER = 'start function requires an execution tier';
  MSG_WRONG_THREAD = 'store touched from a thread other than its owner';

{ --- runtime subtyping: ref.test / ref.cast / br_on_cast* ----------------

  O(1), from the object header and the engine displays, and it is the
  reason the header keeps the type id in its high half: one shift, one
  array index, no masking.

  The abstract half goes through AbsHeapSubtype over the object's KIND,
  which is what keeps the three hierarchies disjoint — a funcref never
  answers true for `anyref`, an externref never answers true for
  `structref`, and an exception is in neither.

  ref.cast failing traps `cast failure`. UNCONFIRMED, and worse: the
  pinned server reports ref.cast as `can_trap:false, traps:[]`, as it does
  for the whole 3.0 GC family, while correctly reporting `null reference`
  for struct.get. The served trap table is reliable for 1.0/2.0 and
  systematically incomplete for GC; Track C's assert_trap corpus is what
  settles the message. }

{ ARef against a CONCRETE engine type. False for null (a null has no
  runtime type — nullability is the reftype's question, below), false for
  an unboxed i31 (i31 is never a concrete type), and false for a host box
  or an exception, whose header ids are not concrete types at all. }
function IsRefOfType(const AEngine: TWasmEngine; const ARef: TWasmRef;
  const ATypeId: TWasmEngineTypeId): Boolean;

{ The full ref.test rt. ATarget must already be in ENGINE space — its
  concrete heap type names an engine id, not a module type index. }
function IsRefOfRefType(const AEngine: TWasmEngine; const ARef: TWasmRef;
  const ATarget: TWasmRefType): Boolean;

{ --- host roots (contract HOST-1) ----------------------------------------

  The design contract spells these as free functions over a store, and
  Track F documents them as MANDATORY: a host that stores a TWasmRef in
  its own structure without registering it has a use-after-free, and there
  is no diagnostic. A handle is an index into a store-owned array, so the
  array may grow without invalidating anything the host holds, and RootGet
  returns the pointer with no read barrier — the payoff for a non-moving
  collector. }
function RootRegister(const AStore: TWasmStore;
  const ARef: TWasmRef): TWasmRootHandle;
function RootGet(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle): TWasmRef;
procedure RootSet(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle; const ARef: TWasmRef);
procedure RootRelease(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle);
function RootScopeEnter(const AStore: TWasmStore): UInt32;
procedure RootScopeLeave(const AStore: TWasmStore; const AMark: UInt32);

{ --- module space to engine space ---------------------------------------

  AMap is TWasmModuleInstance.EngineTypeIds: indexed by MODULE TYPE INDEX.
  An abstract heap type is unchanged; a concrete one is remapped. }
function EngineHeapType(const AHeap: TWasmHeapType;
  const AMap: TWasmEngineTypeIds): TWasmHeapType;
function EngineRefType(const ARef: TWasmRefType;
  const AMap: TWasmEngineTypeIds): TWasmRefType;
function EngineValueType(const AType: TWasmValueType;
  const AMap: TWasmEngineTypeIds): TWasmValueType;
function EngineTableType(const AType: TWasmTableType;
  const AMap: TWasmEngineTypeIds): TWasmTableType;
function EngineGlobalType(const AType: TWasmGlobalType;
  const AMap: TWasmEngineTypeIds): TWasmGlobalType;

{ --- tables -------------------------------------------------------------

  There is no guard-page strategy for a table: elements are references and
  cannot be faulted on, so every table access is explicitly checked. On a
  32-bit host with an i64-addressed table the index-width reduction of the
  memory chokepoint applies verbatim — 3.0 parameterises tables over
  addrtype too ("offsets into memories AND tables", `syntax-addrtype`).

  table.get / table.set / table.init / table.copy / table.fill trap with
  `out of bounds table access` (confirmed: table.get, table.init).
  call_indirect's `undefined element` is a DIFFERENT message for a
  different instruction and the two are never unified.

  The reference-STORING ops (table.set / table.fill / table.grow /
  table.init) are methods on TWasmStore (see its declaration) so the write
  barrier they owe the collector cannot be bypassed. The reads and the
  range check below are free functions — a load is not a barrier site. }
function TableSize(const ATable: TWasmTableInst): UInt64;
function TableSizeCeiling(const AAddrType: TWasmAddrType): UInt64;
function TableGet(var ATable: TWasmTableInst;
  const AIndex: UInt64): TWasmRef;
{ Traps unless [AIndex, AIndex + ACount) is wholly in bounds. A zero count
  at exactly the size is in bounds, which is what table.fill and
  table.init require. }
procedure TableCheckRange(var ATable: TWasmTableInst;
  const AIndex, ACount: UInt64);

{ --- import matching (§ match-externtype) -------------------------------

  The relation is `externtype_1 <: externtype_2`, applied as: THE SUPPLIED
  INSTANCE'S TYPE MUST BE A SUBTYPE OF THE DECLARED IMPORT TYPE. It is the
  relation used "during module instantiation when checking the types of
  imports" (`subtyping`).

  HONEST SOURCING. The pinned server serves the valid/matching clauses
  with EMPTY prose — they are SpecTec-generated and only the rule names
  come back. `match-externtype`, `match-limits`, `match-tabletype`,
  `match-memtype` and `match-globaltype` all return "". What IS citable:
  the rule names (Externtype_sub/func, /table, /mem, /global and /tag,
  Limits_sub, Tabletype_sub, Memtype_sub, Globaltype_sub, Tagtype_sub,
  Deftype_sub/refl, Deftype_sub/super); that Globaltype_sub and Limits_sub are
  CASE-SPLIT (the `/*` suffix), which is the structural signature of
  mutable-vs-immutable and max-present-vs-absent; match-tagtype's prose,
  which says tag matching "invokes subtyping on defined types"; and
  match-deftype's "there is no explicit definition of type equivalence,
  since it coincides with syntactic equality" — under canonicalisation,
  equality IS engine-id equality.

  The variance directions below have been SETTLED against Track C's
  assert_unlinkable corpus (linking.wast, imports.wast,
  type-subtyping.wast): `incompatible import type` appears 237 times and
  `unknown import` 25 times across the testsuite, and the limits, mutable-
  global-invariance, and table-element-invariance directions all reproduce
  the corpus's answers. The former UNCONFIRMED markers are dropped. }

{ CONFIRMED direction (Limits_sub), settled against imports.wast's
  `test-table-10-inf` / `test-memory-2-inf` assert_unlinkable cases.

  The importer asks for AT LEAST Min and AT MOST Max. The max direction is
  the OPPOSITE of the min direction, and an absent maximum is INFINITY —
  so a supplier with no maximum FAILS a declared maximum rather than
  satisfying it. That inversion is the trap this function exists to get
  right; there is one test per direction so that swapping them fails.

  Address types must be EQUAL: 3.0 carries the addrtype inside limits and
  an i32 memory does not satisfy an i64 import or the reverse. }
function MatchLimits(const ASupplied, ADeclared: TWasmLimits): Boolean;

{ Each of these compares an instance already in the store against a
  DECLARED type already converted to engine space. }
function MatchFuncImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmFuncInst;
  const ADeclaredTypeId: TWasmEngineTypeId): Boolean;
function MatchTableImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmTableInst;
  const ADeclared: TWasmTableType): Boolean;
function MatchMemImport(const ASupplied: TWasmMemoryInst;
  const ADeclared: TWasmMemType): Boolean;
function MatchGlobalImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmGlobalInst;
  const ADeclared: TWasmGlobalType): Boolean;
function MatchTagImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmTagInst;
  const ADeclaredTypeId: TWasmEngineTypeId): Boolean;

{ The store an invocation belongs to.

  The design contract gave TWasmTrampoline a typed `Store` field. It
  cannot have one: Wasm.Runtime.Traps sits BELOW this unit (the memory
  chokepoint calls TrapNow and the reservation registry is the handler's),
  and typing the field would invert that and create a cycle. The field is
  an untyped Pointer there and THIS is the convention that gives it
  meaning: whatever a tier publishes in Trampoline^.Context is the
  TWasmStore the invocation is running in. Nothing in Wave 4 executes
  guest code, so nothing writes it yet; the accessor is here so the
  convention has one spelling rather than a cast at each future site. }
function TrampolineStore(const ATrampoline: PWasmTrampoline): TWasmStore;

{ --- O-J5: field offsets the baseline JIT hard-codes ---------------------

  The JIT's generated code reads a handful of fields at FIXED byte offsets:
  Store.Epoch at every back-edge safepoint (jit-spec §6), a memory
  instance's Base / ByteSize on the inline bounds-check path (§7.1 form 2),
  and the func-inst tier fields. A silent record-layout change would
  miscompile rather than fail to build, so these offsets come from the live
  Pascal layout — PtrUInt(@rec.field) - PtrUInt(@rec) — and the co-located
  test asserts the values the JIT hard-codes against them. Reorder a field
  and the test goes red; the generated code never sees a stale offset.

  StoreEpoch is measured from the object reference (the JIT holds the store
  as a class pointer), which is why the accessor needs a live store. The
  record offsets are layout-only and independent of AStore. }
type
  { The FIXED set of Pascal runtime helpers the position-independent JIT/AOT
    backends call INDIRECTLY through the per-process helper table
    (Store.JitHelperTable, aot-spec §1.2). The ORDINAL is the stable slot index
    baked into generated code (`[base + Ord(h)*8]`); the table maps that index
    to the helper's live address, filled once at RegisterJit. Both backends
    share this ordering, and the ABI fingerprint (Wasm.Interp) folds the count
    in, so a reorder is caught. NEVER reorder without bumping AOT_ABI_REVISION.
    Existing ordinals never move: AOT artifacts bake them into machine code.
    New helpers are appended and the ABI revision is bumped with the emitter. }
  TWasmAotHelper = (
    aohTrapKind,               { 0  TrapNow(kind) — every trap stub }
    aohOpBinary,               { 1  binary numeric leaf }
    aohOpUnary,                { 2  unary numeric leaf }
    aohRtDispatch,             { 3  mem/table/ref/global/GC uniform dispatch }
    aohVecDispatch,            { 4  v128 leaf dispatch }
    aohRefBranchPredicate,     { 5  br_on_null/cast predicate }
    aohCall,                   { 6  direct call }
    aohCallIndirect,           { 7  call_indirect }
    aohCallRef,                { 8  call_ref }
    aohReturnCall,             { 9  return_call }
    aohReturnCallIndirect,     { 10 return_call_indirect }
    aohReturnCallRef,          { 11 return_call_ref }
    aohDirectCallPrepare,      { 12 compiled direct-call frame entry }
    aohDirectCallFinish        { 13 compiled direct-call frame exit }
  );

const
  { Number of helper-table slots; the array Store.JitHelperTable points at has
    exactly this many Pointer entries. }
  AOT_HELPER_COUNT = Ord(High(TWasmAotHelper)) + 1;

type
  TWasmJitOffsets = record
    StoreEpoch: NativeUInt;          { TWasmStore.Epoch, from the object ref }
    StoreEpochSnapshot: NativeUInt;  { TWasmStore.EpochSnapshot, from the object ref }
    StoreJitHelperTable: NativeUInt; { TWasmStore.JitHelperTable, from the object ref }
    FuncInstStride: NativeUInt;      { SizeOf(TWasmFuncInst) }
    FuncKind: NativeUInt;            { TWasmFuncInst.Kind }
    FuncCompiledEntry: NativeUInt;   { TWasmFuncInst.CompiledEntry }
    FuncCompiledDirectEntry: NativeUInt; { TWasmFuncInst.CompiledDirectEntry }
    FuncCallCount: NativeUInt;       { TWasmFuncInst.CallCount }
    MemInstStride: NativeUInt;       { SizeOf(TWasmMemoryInst) }
    MemBase: NativeUInt;             { TWasmMemoryInst.Base }
    MemByteSize: NativeUInt;         { TWasmMemoryInst.ByteSize }
  end;

function WasmJitOffsets(const AStore: TWasmStore): TWasmJitOffsets;

implementation

{ --- module space to engine space ---------------------------------------- }

function EngineHeapType(const AHeap: TWasmHeapType;
  const AMap: TWasmEngineTypeIds): TWasmHeapType;
begin
  Result := AHeap;
  if AHeap.IsAbstract then
    Exit;
  if AHeap.TypeIndex >= UInt32(Length(AMap)) then
    raise EWasmError.CreateFmt(
      'internal: type index %u has no engine id', [AHeap.TypeIndex]);
  Result.TypeIndex := AMap[AHeap.TypeIndex];
end;

function EngineRefType(const ARef: TWasmRefType;
  const AMap: TWasmEngineTypeIds): TWasmRefType;
begin
  Result.Nullable := ARef.Nullable;
  Result.Heap := EngineHeapType(ARef.Heap, AMap);
end;

function EngineValueType(const AType: TWasmValueType;
  const AMap: TWasmEngineTypeIds): TWasmValueType;
begin
  Result := AType;
  if AType.Kind = wvkRef then
    Result.Ref := EngineRefType(AType.Ref, AMap);
end;

function EngineTableType(const AType: TWasmTableType;
  const AMap: TWasmEngineTypeIds): TWasmTableType;
begin
  Result.RefType := EngineRefType(AType.RefType, AMap);
  Result.Limits := AType.Limits;
end;

function EngineGlobalType(const AType: TWasmGlobalType;
  const AMap: TWasmEngineTypeIds): TWasmGlobalType;
begin
  Result.Mut := AType.Mut;
  Result.ValueType := EngineValueType(AType.ValueType, AMap);
end;

{ --- the intern table ---------------------------------------------------- }

{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}
{ FNV-1a. Only a reject filter — a collision costs one byte comparison,
  never a wrong answer. BOTH checks are off for the width of this one
  function, and both are needed: the multiply is DEFINED to wrap, FPC
  widens it before narrowing back to u32, and Shared.inc turns overflow
  AND range checks on outside PRODUCTION builds — where the widened
  product fails the range check on the way back into the u32. }
function HashKey(const AKey: TWasmBytes): UInt32;
var
  Index: Integer;
begin
  Result := UInt32($811C9DC5);
  for Index := 0 to High(AKey) do
  begin
    Result := Result xor UInt32(AKey[Index]);
    Result := Result * UInt32($01000193);
  end;
end;
{$POP}

function KeysEqual(const A, B: TWasmBytes): Boolean;
var
  Index: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for Index := 0 to High(A) do
    if A[Index] <> B[Index] then
      Exit(False);
  Result := True;
end;

function CopyKey(const AKey: TWasmBytes): TWasmBytes;
var
  Index: Integer;
begin
  { OWNED, not borrowed. This is the one place in Track D that copies
    rather than borrows, and deliberately: the IR module may be freed
    while the engine lives, and the key is small. }
  Result := nil;
  SetLength(Result, Length(AKey));
  for Index := 0 to High(AKey) do
    Result[Index] := AKey[Index];
end;

{ GroupMemberCount now comes from Wasm.Validator (A7): the key grammar is
  Wasm.Validator.Types' and the runtime reads it through the validator's
  public façade rather than reaching past it. }

constructor TWasmEngine.Create;
begin
  inherited Create;
  FGcTypes := TWasmGcTypes.Create;
end;

destructor TWasmEngine.Destroy;
begin
  FGcTypes.Free;
  inherited Destroy;
end;

function TWasmEngine.LookupGroup(const AKey: TWasmBytes;
  const AHash: UInt32; out ABase: TWasmEngineTypeId): Boolean;
var
  Index: Integer;
begin
  ABase := 0;
  for Index := 0 to FGroupCount - 1 do
    if (FGroupHashes[Index] = AHash) and KeysEqual(FGroupKeys[Index], AKey) then
    begin
      ABase := FGroupBases[Index];
      Exit(True);
    end;
  Result := False;
end;

procedure TWasmEngine.AddGroup(const AKey: TWasmBytes; const AHash: UInt32;
  const ABase: TWasmEngineTypeId; const ASize: UInt32);
begin
  if FGroupCount >= Length(FGroupKeys) then
  begin
    SetLength(FGroupKeys, (FGroupCount + 1) * 2);
    SetLength(FGroupHashes, Length(FGroupKeys));
    SetLength(FGroupBases, Length(FGroupKeys));
    SetLength(FGroupSizes, Length(FGroupKeys));
  end;
  FGroupKeys[FGroupCount] := CopyKey(AKey);
  FGroupHashes[FGroupCount] := AHash;
  FGroupBases[FGroupCount] := ABase;
  FGroupSizes[FGroupCount] := ASize;
  Inc(FGroupCount);
end;

function TWasmEngine.AllocateTypes(
  const ACount: UInt32): TWasmEngineTypeId;
begin
  Result := TWasmEngineTypeId(FTypeCount);
  if FTypeCount + Integer(ACount) > Length(FTypes) then
    SetLength(FTypes, (FTypeCount + Integer(ACount)) * 2);
  Inc(FTypeCount, Integer(ACount));
end;

function TWasmEngine.RewriteValType(const AType: TWasmValueType;
  const AMap: TWasmEngineTypeIds): TWasmValueType;
begin
  Result := AType;
  if AType.Kind <> wvkRef then
    Exit;
  if AType.Ref.Heap.IsAbstract then
    Exit;
  if (AType.Ref.Heap.TypeIndex >= UInt32(Length(AMap))) or
    (AMap[AType.Ref.Heap.TypeIndex] = WASM_NO_ADDR) then
    raise EWasmError.CreateFmt(
      'internal: canonical type %u is not interned yet',
      [AType.Ref.Heap.TypeIndex]);
  Result.Ref.Heap.TypeIndex := AMap[AType.Ref.Heap.TypeIndex];
end;

function TWasmEngine.RewriteFieldType(const AField: TWasmFieldType;
  const AMap: TWasmEngineTypeIds): TWasmFieldType;
begin
  Result := AField;
  if not AField.Storage.IsPacked then
    Result.Storage.ValueType := RewriteValType(AField.Storage.ValueType, AMap);
end;

function TWasmEngine.RewriteCompType(const AComp: TWasmCompType;
  const AMap: TWasmEngineTypeIds): TWasmCompType;
var
  Index: Integer;
begin
  Result := AComp;
  case AComp.Kind of
    wckFunc:
      begin
        SetLength(Result.Func.Params, Length(AComp.Func.Params));
        for Index := 0 to High(AComp.Func.Params) do
          Result.Func.Params[Index] :=
            RewriteValType(AComp.Func.Params[Index], AMap);
        SetLength(Result.Func.Results, Length(AComp.Func.Results));
        for Index := 0 to High(AComp.Func.Results) do
          Result.Func.Results[Index] :=
            RewriteValType(AComp.Func.Results[Index], AMap);
      end;
    wckStruct:
      begin
        SetLength(Result.Struct.Fields, Length(AComp.Struct.Fields));
        for Index := 0 to High(AComp.Struct.Fields) do
          Result.Struct.Fields[Index] :=
            RewriteFieldType(AComp.Struct.Fields[Index], AMap);
      end;
    wckArray:
      Result.Arr.Elem := RewriteFieldType(AComp.Arr.Elem, AMap);
  end;
end;

procedure TWasmEngine.MaterialiseGroup(const AIr: TWasmIrModule;
  const ALocalBase: UInt32; const ABase: TWasmEngineTypeId;
  const ASize: UInt32; const AMap: TWasmEngineTypeIds);
var
  Member: UInt32;
  Local: UInt32;
  Entry: Integer;
  Source: UInt32;
begin
  { Members of the group BEING interned resolve through the base just
    assigned, which is why the caller publishes AMap for them before
    calling this. Groups referenced by an earlier index are already
    mapped: canonicalisation is incremental and forward references are
    invalid (`valid-type`). }
  Member := 0;
  while Member < ASize do
  begin
    Local := ALocalBase + Member;
    if Local >= UInt32(Length(AIr.CanonTypes)) then
      raise EWasmError.Create(
        'internal: rec group runs past the canonical type table');

    FTypes[ABase + Member].Comp :=
      RewriteCompType(AIr.CanonTypes[Local].Comp, AMap);
    FTypes[ABase + Member].Kind := AIr.CanonTypes[Local].Comp.Kind;
    FTypes[ABase + Member].IsFinal := AIr.CanonTypes[Local].IsFinal;
    FTypes[ABase + Member].Depth := AIr.CanonTypes[Local].Depth;

    SetLength(FTypes[ABase + Member].Display,
      Length(AIr.CanonTypes[Local].Display));
    for Entry := 0 to High(AIr.CanonTypes[Local].Display) do
    begin
      Source := AIr.CanonTypes[Local].Display[Entry];
      if (Source >= UInt32(Length(AMap))) or (AMap[Source] = WASM_NO_ADDR) then
        raise EWasmError.CreateFmt(
          'internal: display entry %u is not interned yet', [Source]);
      FTypes[ABase + Member].Display[Entry] := AMap[Source];
    end;

    { The collector's byte layout, computed here and only here: a type is
      materialised once per engine, and field offsets are a pure function
      of the ENGINE-space composite that just landed. Doing it at intern
      time is what keeps struct.get off any per-object map. }
    FGcTypes.Define(ABase + Member, FTypes[ABase + Member].Comp);

    Inc(Member);
  end;
end;

procedure TWasmEngine.InternModule(const AIr: TWasmIrModule;
  out ACanonToEngine: TWasmEngineTypeIds;
  out ATypeIndexToEngine: TWasmEngineTypeIds);
var
  Group: Integer;
  First: UInt32;
  Size: UInt32;
  LocalBase: UInt32;
  Base: TWasmEngineTypeId;
  Hash: UInt32;
  IsNew: Boolean;
  Member: UInt32;
  Index: Integer;
  Key: TWasmBytes;
begin
  SetLength(ACanonToEngine, Length(AIr.CanonTypes));
  for Index := 0 to High(ACanonToEngine) do
    ACanonToEngine[Index] := WASM_NO_ADDR;

  First := 0;
  for Group := 0 to High(AIr.GroupKeys) do
  begin
    { The key is the ROLLED form — internal type indices are group-
      relative recursive indices (`aux-roll-rectype`) — which is exactly
      what makes two structurally identical groups from two different
      modules hash and compare equal. Never re-serialise from CanonTypes:
      those carry module-local ids and would defeat the mechanism. }
    Size := GroupMemberCount(AIr.GroupKeys[Group]);
    if Size = 0 then
    begin
      { An empty `(rec)` is a valid rec group of zero types: `binary-rectype`
        encodes the members as a list, and a list count of 0 is well-formed.
        It defines no types, so it interns to nothing and advances no type
        indices — skip it without allocating or registering a group. }
      Continue;
    end;
    if UInt64(First) + UInt64(Size) >
      UInt64(Length(AIr.TypeIndexToCanon)) then
      raise EWasmError.Create(
        'internal: rec group sizes do not cover the type index space');

    LocalBase := AIr.TypeIndexToCanon[First];

    { M3: the validator's key spells OUT-OF-GROUP references by module-local
      canonical id, which two modules assign differently when a different
      number of rec groups precedes the shared type — so the raw key is NOT
      structural across modules. Rewrite those references to ENGINE ids
      (earlier groups are already interned, so ACanonToEngine holds them)
      before hashing, looking up, and storing. In-group references are
      recursive-relative and untouched. Now two modules defining the same
      closed type after a DIFFERENT number of preceding groups produce the
      same engine key and intern to the same id. }
    Key := RewriteGroupKeyRefs(AIr.GroupKeys[Group], ACanonToEngine);

    Hash := HashKey(Key);
    IsNew := not LookupGroup(Key, Hash, Base);
    if IsNew then
    begin
      { Base is computed and the space reserved BEFORE materialisation, so
        the group's own members can resolve through it. }
      Base := AllocateTypes(Size);
      AddGroup(Key, Hash, Base, Size);
    end;

    Member := 0;
    while Member < Size do
    begin
      if LocalBase + Member >= UInt32(Length(ACanonToEngine)) then
        raise EWasmError.Create(
          'internal: rec group runs past the canonical type table');
      ACanonToEngine[LocalBase + Member] := Base + Member;
      Inc(Member);
    end;

    if IsNew then
      MaterialiseGroup(AIr, LocalBase, Base, Size, ACanonToEngine);

    First := First + Size;
  end;

  if First <> UInt32(Length(AIr.TypeIndexToCanon)) then
    raise EWasmError.Create(
      'internal: rec group sizes do not cover the type index space');

  { B22: the collector's layout table is Define'd once per engine type, in
    MaterialiseGroup, alongside the allocation that grew FTypes. If the two
    ever diverge a struct.get would read a layout that does not exist, so
    the invariant is asserted rather than assumed: every allocated engine
    type has a materialised GC layout. }
  if FGcTypes.Count <> FTypeCount then
    raise EWasmError.CreateFmt(
      'internal: %d engine types but %d GC layouts', [FTypeCount,
      FGcTypes.Count]);

  SetLength(ATypeIndexToEngine, Length(AIr.TypeIndexToCanon));
  for Index := 0 to High(ATypeIndexToEngine) do
    ATypeIndexToEngine[Index] := ACanonToEngine[AIr.TypeIndexToCanon[Index]];
end;

function TWasmEngine.TypeCount: Integer;
begin
  Result := FTypeCount;
end;

function TWasmEngine.GroupCount: Integer;
begin
  Result := FGroupCount;
end;

function TWasmEngine.EngineType(
  const AId: TWasmEngineTypeId): TWasmEngineType;
begin
  if AId >= UInt32(FTypeCount) then
    raise EWasmError.CreateFmt('internal: no engine type %u', [AId]);
  Result := FTypes[AId];
end;

function TWasmEngine.Matches(const ASub,
  ASuper: TWasmEngineTypeId): Boolean;
var
  SuperDepth: UInt32;
begin
  { Deftype_sub/refl and Deftype_sub/super. The display turns the chain
    walk into two array reads — constant time, across modules, which is
    the entire point of interning.

    L10: the range guard comes BEFORE the reflexivity shortcut. Two absent
    ids (both WASM_NO_ADDR) are equal and would otherwise report a spurious
    match; a valid id is never WASM_NO_ADDR, so the guard rejects the
    absent case rather than letting equality answer for it. }
  if (ASub >= UInt32(FTypeCount)) or (ASuper >= UInt32(FTypeCount)) then
    raise EWasmError.Create('internal: engine type id out of range');
  if ASub = ASuper then
    Exit(True);
  SuperDepth := FTypes[ASuper].Depth;
  Result := (SuperDepth < UInt32(Length(FTypes[ASub].Display))) and
    (FTypes[ASub].Display[SuperDepth] = ASuper);
end;

function TWasmEngine.AbsKindOf(
  const AId: TWasmEngineTypeId): TWasmAbsHeapType;
begin
  if AId >= UInt32(FTypeCount) then
    raise EWasmError.CreateFmt('internal: no engine type %u', [AId]);
  case FTypes[AId].Kind of
    wckStruct: Result := wahStruct;
    wckArray: Result := wahArray;
  else
    Result := wahFunc;
  end;
end;

function TWasmEngine.MatchesHeapType(const A, B: TWasmHeapType): Boolean;
begin
  if A.IsAbstract and B.IsAbstract then
    Exit(AbsHeapSubtype(A.Abs, B.Abs));

  if B.IsAbstract then
    Exit(AbsHeapSubtype(AbsKindOf(A.TypeIndex), B.Abs));

  if A.IsAbstract then
  begin
    { Only the bottom of each hierarchy reaches a concrete type
      (Heaptype_sub/none, /nofunc). NOEXN and NOEXTERN have no concrete
      types to be below: EXN and EXTERN "have no concrete subtypes"
      (`syntax-heaptype`). }
    case A.Abs of
      wahNone:
        Result := AbsKindOf(B.TypeIndex) <> wahFunc;
      wahNoFunc:
        Result := AbsKindOf(B.TypeIndex) = wahFunc;
    else
      Result := False;
    end;
    Exit;
  end;

  Result := Matches(A.TypeIndex, B.TypeIndex);
end;

function TWasmEngine.MatchesRefType(const A, B: TWasmRefType): Boolean;
begin
  { `match-reftype`: a non-null reference matches a nullable one, never
    the other way round. }
  Result := ((not A.Nullable) or B.Nullable) and
    MatchesHeapType(A.Heap, B.Heap);
end;

function TWasmEngine.MatchesValType(const A, B: TWasmValueType): Boolean;
begin
  { `match-valtype`: numbers and vectors match only themselves. }
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    wvkNum: Result := A.Num = B.Num;
    wvkVec: Result := True;
  else
    Result := MatchesRefType(A.Ref, B.Ref);
  end;
end;

{ --- tables -------------------------------------------------------------- }

function TableSize(const ATable: TWasmTableInst): UInt64;
begin
  Result := UInt64(Length(ATable.Elems));
end;

function TableSizeCeiling(const AAddrType: TWasmAddrType): UInt64;
begin
  { The validator checks a declared table's limits against 2^|at| - 1 —
    one fewer than the address space, because a table of exactly 2^32
    entries has no representable last index. The runtime re-derives the
    same ceiling for table.grow rather than inventing a second answer. }
  if AAddrType = watI32 then
    Result := UInt64($FFFFFFFF)
  else
    Result := UInt64($FFFFFFFFFFFFFFFF);
end;

function TableIndexTooWide(const ATable: TWasmTableInst;
  const AIndex: UInt64): Boolean; inline;
begin
  {$IFDEF CPU32}
  { 32-bit host, i64-addressed table: reduce the index width before the
    bounds compare, so an index above 2^32-1 traps rather than being
    truncated into range (ADR-0010, ADR-0013). }
  Result := (ATable.TableType.Limits.AddrType = watI64) and
    ((AIndex shr 32) <> 0);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

{ B24: the single-index out-of-bounds predicate, spelled once. Both the
  too-wide (32-bit i64-table) reduction and the length compare, so
  table.get and table.set share one definition. }
function TableIndexOutOfBounds(const ATable: TWasmTableInst;
  const AIndex: UInt64): Boolean; inline;
begin
  Result := TableIndexTooWide(ATable, AIndex) or
    (AIndex >= UInt64(Length(ATable.Elems)));
end;

function TableGet(var ATable: TWasmTableInst;
  const AIndex: UInt64): TWasmRef;
begin
  if TableIndexOutOfBounds(ATable, AIndex) then
    TrapNow(wtkTableOutOfBounds);
  Result := ATable.Elems[AIndex];
end;

procedure TableCheckRange(var ATable: TWasmTableInst;
  const AIndex, ACount: UInt64);
var
  Size: UInt64;
begin
  { Subtracting form, never `AIndex + ACount > Size`: the sum wraps for a
    large index on an i64-addressed table and would admit an
    out-of-bounds write. }
  Size := UInt64(Length(ATable.Elems));
  if TableIndexTooWide(ATable, AIndex) or (AIndex > Size) or
    (ACount > Size - AIndex) then
    TrapNow(wtkTableOutOfBounds);
end;

{ --- import matching ----------------------------------------------------- }

function MatchLimits(const ASupplied, ADeclared: TWasmLimits): Boolean;
begin
  if ASupplied.AddrType <> ADeclared.AddrType then
    Exit(False);
  if ASupplied.Min < ADeclared.Min then
    Exit(False);
  if not ADeclared.HasMax then
    Exit(True);
  { INVERTED VARIANCE. An absent supplied maximum is infinity and cannot
    satisfy a declared one. }
  Result := ASupplied.HasMax and (ASupplied.Max <= ADeclared.Max);
end;

function MatchFuncImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmFuncInst;
  const ADeclaredTypeId: TWasmEngineTypeId): Boolean;
begin
  { CONFIRMED-shape: Externtype_sub/func reduces to Deftype_sub, whose
    two rules are reflexivity and the supertype step — so a SUBTYPE of
    the declared type is acceptable. }
  Result := AEngine.Matches(ASupplied.TypeId, ADeclaredTypeId);
end;

function MatchTableImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmTableInst;
  const ADeclared: TWasmTableType): Boolean;
var
  Limits: TWasmLimits;
begin
  { The instance's type reports its CURRENT size as the minimum — "the
    length of ref* must equal n" (`valid-tableinst`) — so a table grown
    past its declared minimum satisfies an import that asks for more. }
  Limits := ASupplied.TableType.Limits;
  Limits.Min := UInt64(Length(ASupplied.Elems));
  Limits.HasMax := ASupplied.HasMax;
  Limits.Max := ASupplied.MaxSize;
  if not MatchLimits(Limits, ADeclared.Limits) then
    Exit(False);
  { CONFIRMED-invariant (Tabletype_sub), settled against the corpus. A
    table is BOTH read (table.get / call_indirect) and written (table.set /
    table.init / table.grow), so its element type is INVARIANT exactly as a
    mutable global's value type is — Tabletype_sub is separate from equality
    only because of the limits premise, not because the element type varies.
    linking.wast:441 imports the exporter's `(table 1 (ref null $t))` as
    `(table (import ...) 1 (ref null func))` — a SUPERtype of the supplied
    element type — and asserts `incompatible import type`; a covariant match
    would have linked it, and call_ref/call_indirect then do NO runtime
    element-type check, so covariance is a memory-safety hole. Require
    element-type EQUALITY: match in both directions. }
  Result := AEngine.MatchesRefType(ASupplied.TableType.RefType,
    ADeclared.RefType) and
    AEngine.MatchesRefType(ADeclared.RefType,
    ASupplied.TableType.RefType);
end;

function MatchMemImport(const ASupplied: TWasmMemoryInst;
  const ADeclared: TWasmMemType): Boolean;
var
  Limits: TWasmLimits;
begin
  { Same reading as tables: the instance's minimum is its current size
    (`valid-meminst` ties the byte length to the limits). }
  Limits.AddrType := ASupplied.AddrType;
  Limits.Min := ASupplied.Pages;
  Limits.HasMax := ASupplied.HasMax;
  Limits.Max := ASupplied.MaxPages;
  Result := MatchLimits(Limits, ADeclared.Limits);
end;

function MatchGlobalImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmGlobalInst;
  const ADeclared: TWasmGlobalType): Boolean;
begin
  { CONFIRMED direction (Globaltype_sub, CASE-SPLIT — the `/*` suffix is
    the structural evidence), settled against imports.wast's mutable-global
    assert_unlinkable cases.

    THE SECOND INVERTED-VARIANCE TRAP. A MUTABLE global is INVARIANT in
    its value type: it is both read and written, so neither direction
    alone is sound. An IMMUTABLE global is covariant. Mutability itself
    must match exactly in both directions — a const import bound to a var
    global would let the exporter change it under the importer's feet. }
  if ASupplied.GlobalType.Mut <> ADeclared.Mut then
    Exit(False);
  if ADeclared.Mut then
    Result := AEngine.MatchesValType(ASupplied.GlobalType.ValueType,
      ADeclared.ValueType) and
      AEngine.MatchesValType(ADeclared.ValueType,
      ASupplied.GlobalType.ValueType)
  else
    Result := AEngine.MatchesValType(ASupplied.GlobalType.ValueType,
      ADeclared.ValueType);
end;

function MatchTagImport(const AEngine: TWasmEngine;
  const ASupplied: TWasmTagInst;
  const ADeclaredTypeId: TWasmEngineTypeId): Boolean;
begin
  { CONFIRMED-shape: match-tagtype's prose says the premise "invokes
    subtyping on defined types". }
  Result := AEngine.Matches(ASupplied.TypeId, ADeclaredTypeId);
end;

{ --- module instance ----------------------------------------------------- }

function TWasmModuleInstance.BorrowsBuffer(
  const AStore: TWasmStore): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(DataAddrs) do
    if not AStore.Datas[DataAddrs[Index]].Dropped then
      Exit(True);
  Result := False;
end;

function TWasmModuleInstance.FindExport(const AName: string;
  out AKind: TWasmExternKind; out AAddr: UInt32): Boolean;
var
  Index: Integer;
begin
  AKind := wxkFunc;
  AAddr := WASM_NO_ADDR;
  for Index := 0 to High(ExportNames) do
    if ExportNames[Index] = AName then
    begin
      AKind := ExportKinds[Index];
      AAddr := ExportAddrs[Index];
      Exit(True);
    end;
  Result := False;
end;

{ --- store --------------------------------------------------------------- }

{ The store's half of the root set, handed to the heap as one callback so
  that Wasm.Runtime.Gc never has to know a store exists.

  FOUR PRODUCERS, all exact:

    (a) FUNCTION HANDLES. A funcref value is a heap object now, so every
        Funcs[i].RefObject is a root. The store never removes a function
        instance, so a handle lives exactly as long as the store — which
        is what makes ref.func's pointer stable.
    (b) TABLES. Every element of every table, with no filtering: a table's
        element type is always a reference type. This is the largest root
        source for a func-table-heavy module, and card marking or a
        remembered set is the upgrade path — the write barrier already
        covers the write sites.
    (c) GLOBALS of reference type, from the dense list built at
        allocation.
    (d) ELEMENT INSTANCES, which hold references (`syntax-eleminst`)
        until they are dropped.

  NOT roots: linear memory, because "values of reference type can be
  stored in tables but not in memories" (`syntax-reftype`); and data
  instances, which are bytes. Host roots and the frame chain are the
  heap's own and are walked before this runs. }
procedure StoreMarkRoots(const AHeap: TWasmGcHeap; const AContext: Pointer);
var
  Store: TWasmStore;
  Index: Integer;
  Slot: Integer;
begin
  Store := TWasmStore(AContext);

  for Index := 0 to High(Store.Funcs) do
    AHeap.MarkRoot(Store.Funcs[Index].RefObject);

  for Index := 0 to High(Store.Tables) do
    for Slot := 0 to High(Store.Tables[Index].Elems) do
      AHeap.MarkRoot(Store.Tables[Index].Elems[Slot]);

  for Index := 0 to Store.FRefGlobalCount - 1 do
    AHeap.MarkRoot(Store.Globals[Store.FRefGlobals[Index]].Value.Ref);

  for Index := 0 to High(Store.Elems) do
    for Slot := 0 to High(Store.Elems[Index].Refs) do
      AHeap.MarkRoot(Store.Elems[Index].Refs[Slot]);
end;

constructor TWasmStore.Create(const AEngine: TWasmEngine);
begin
  inherited Create;
  if AEngine = nil then
    raise EWasmError.Create('a store needs an engine');
  FEngine := AEngine;
  FOwnerThread := GetCurrentThreadId;
  FHeap := TWasmGcHeap.Create(AEngine.GcTypes);
  FHeap.SetRootSource(StoreMarkRoots, Pointer(Self));
end;

destructor TWasmStore.Destroy;
var
  Index: Integer;
begin
  { O-10: free the tier's execution context before anything else. The store
    owns its lifetime — RegisterInterpreter set TierContext/TierContextFree
    together, and this hook releases the context's GetMem reservations. Guard
    on BOTH being set so a store with no tier (or only TierInvoke) frees
    nothing. Done first, while the store is still whole, so the hook may read
    it if it ever needs to. }
  if Assigned(TierContextFree) and (TierContext <> nil) then
  begin
    TierContextFree(TierContext);
    TierContext := nil;
  end;

  for Index := 0 to High(Instances) do
    Instances[Index].Free;
  Instances := nil;

  for Index := 0 to High(FMemories) do
    MemoryFree(FMemories[Index]);
  FMemories := nil;

  { The heap goes LAST. Its teardown releases every host box, which may
    call back into the embedder, and doing that while the store still
    looked half-alive would be the one ordering a host cannot reason
    about. }
  FreeAndNil(FHeap);

  inherited Destroy;
end;

procedure TWasmStore.CheckThread;
begin
  {$IFNDEF PRODUCTION}
  if GetCurrentThreadId <> FOwnerThread then
    raise EWasmError.Create(MSG_WRONG_THREAD);
  {$ENDIF}
end;

function TWasmStore.AddWasmFunc(const ATypeId: TWasmEngineTypeId;
  const AFuncIrIndex: UInt32): TWasmFuncAddr;
begin
  Result := TWasmFuncAddr(Length(Funcs));
  SetLength(Funcs, Length(Funcs) + 1);
  Funcs[Result].Kind := wfkWasm;
  Funcs[Result].TypeId := ATypeId;
  Funcs[Result].Instance := nil;
  Funcs[Result].FuncIrIndex := AFuncIrIndex;
  { O-J1: nil CompiledEntry = not compiled -> interpret; the JIT sets it and
    bumps CallCount off the interpreter's increments. }
  Funcs[Result].CompiledEntry := nil;
  Funcs[Result].CallCount := 0;
  Funcs[Result].Callback := nil;
  Funcs[Result].HostData := nil;
  { The handle is created once, with the instance, so ref.func returns the
    same pointer every time. Function instance identity "is not observable
    by WebAssembly code" (`syntax-hostfunc`), but making it stable is free
    and removes a class of surprise.

    ALLOCATED AFTER the record is filled in, deliberately: AllocFuncRef is
    a safepoint, the collection it may trigger enumerates every
    Funcs[i].RefObject as a root, and a half-written entry read by that
    walk would be a garbage reference. The entry's RefObject is still
    null at that point, which the scan skips. }
  Funcs[Result].RefObject := FHeap.AllocFuncRef(Result, ATypeId);
end;

function TWasmStore.AddHostFunc(const ATypeId: TWasmEngineTypeId;
  const ACallback: TWasmHostFunc; const AData: Pointer): TWasmFuncAddr;
begin
  Result := TWasmFuncAddr(Length(Funcs));
  SetLength(Funcs, Length(Funcs) + 1);
  Funcs[Result].Kind := wfkHost;
  Funcs[Result].TypeId := ATypeId;
  Funcs[Result].Instance := nil;
  Funcs[Result].FuncIrIndex := 0;
  { A host function is never compiled; keep the tier fields zero. }
  Funcs[Result].CompiledEntry := nil;
  Funcs[Result].CallCount := 0;
  Funcs[Result].Callback := ACallback;
  Funcs[Result].HostData := AData;
  Funcs[Result].RefObject := FHeap.AllocFuncRef(Result, ATypeId);
end;

function TWasmStore.AddTable(const ATableType: TWasmTableType;
  const AInit: TWasmRef): TWasmTableAddr;
var
  Ceiling: UInt64;
  Index: Integer;
begin
  Result := TWasmTableAddr(Length(Tables));
  SetLength(Tables, Length(Tables) + 1);
  Tables[Result].TableType := ATableType;
  Tables[Result].HasMax := ATableType.Limits.HasMax;

  Ceiling := TableSizeCeiling(ATableType.Limits.AddrType);
  if ATableType.Limits.HasMax and (ATableType.Limits.Max < Ceiling) then
    Tables[Result].MaxSize := ATableType.Limits.Max
  else
    Tables[Result].MaxSize := Ceiling;

  if ATableType.Limits.Min >
    UInt64(High(NativeInt)) div UInt64(SizeOf(TWasmRef)) then
    raise EWasmError.Create('cannot allocate a table of that size');
  SetLength(Tables[Result].Elems, NativeInt(ATableType.Limits.Min));
  for Index := 0 to High(Tables[Result].Elems) do
    Tables[Result].Elems[Index] := AInit;
end;

function TWasmStore.AddMemory(const AMemType: TWasmMemType): TWasmMemAddr;
begin
  Result := TWasmMemAddr(Length(FMemories));
  SetLength(FMemories, Length(FMemories) + 1);
  { A HOST ALLOCATION FAILURE IS EWasmError AT THIS BOUNDARY, and that is
    a decision rather than an accident.

    MemoryInit documents "raises EWasmError if the host cannot provide the
    storage", and its guard paths do exactly that. Its bounds-checked path
    allocates through the RTL, whose heap manager RAISES EOutOfMemory
    rather than returning nil — so without this conversion a failure on a
    32-bit host or on Windows would reach an embedder as an exception from
    outside the wasm error hierarchy, which the error-class map has no
    entry for and a host cannot discriminate on. A resource failure is
    neither a decode, a validation, a link, nor a trap condition, so
    EWasmError is the honest class.

    Wasm.Runtime.Memory's memory.grow has the SAME exposure in the other
    direction: `exec-memory.grow` reports can_trap:false and the unit's own
    contract is that growth returns -1 on failure, but the RTL's
    ReAllocMem raises before the `nil` test can fire. That path belongs to
    a caller Track D does not have yet (memory.grow is executed by a tier),
    and fixing it means an except frame inside guest execution, which is a
    TRAP-1 question. Recorded here, unfixed, deliberately. }
  try
    MemoryInit(FMemories[Result], AMemType);
  except
    on E: EOutOfMemory do
      raise EWasmError.Create('cannot allocate linear memory');
  end;
end;

function TWasmStore.MemoryCount: Integer;
begin
  Result := Length(FMemories);
end;

procedure CheckMemAddr(const AAddr: TWasmMemAddr; const ACount: Integer);
begin
  if AAddr >= UInt32(ACount) then
    raise EWasmError.CreateFmt('internal: no memory %u', [AAddr]);
end;

function TWasmStore.MemoryAddrType(
  const AAddr: TWasmMemAddr): TWasmAddrType;
begin
  CheckMemAddr(AAddr, Length(FMemories));
  Result := FMemories[AAddr].AddrType;
end;

function TWasmStore.MemAddressAt(const AAddr: TWasmMemAddr;
  const AIndex, AOffset: UInt64; const ASize: NativeUInt): PByte;
begin
  CheckMemAddr(AAddr, Length(FMemories));
  Result := MemAddress(FMemories[AAddr], AIndex, AOffset, ASize);
end;

function TWasmStore.MemRangeAt(const AAddr: TWasmMemAddr;
  const AIndex, ALength: UInt64): PByte;
begin
  CheckMemAddr(AAddr, Length(FMemories));
  Result := MemRange(FMemories[AAddr], AIndex, ALength);
end;

function TWasmStore.MemMatchesImport(const AAddr: TWasmMemAddr;
  const ADeclared: TWasmMemType): Boolean;
begin
  CheckMemAddr(AAddr, Length(FMemories));
  Result := MatchMemImport(FMemories[AAddr], ADeclared);
end;

function TWasmStore.MemoryPages(const AAddr: TWasmMemAddr): UInt64;
begin
  CheckMemAddr(AAddr, Length(FMemories));
  Result := FMemories[AAddr].Pages;
end;

function TWasmStore.MemoryGrow(const AAddr: TWasmMemAddr;
  const ADelta: UInt64): Int64;
begin
  CheckMemAddr(AAddr, Length(FMemories));
  { Qualified so the call reaches Wasm.Runtime.Memory's free function rather
    than recursing into this method. Growth never runs the collector. }
  Result := Wasm.Runtime.Memory.MemoryGrow(FMemories[AAddr], ADelta);
end;

{ --- table mutation, barriered (A6) -------------------------------------- }

procedure TWasmStore.TableSet(const AAddr: TWasmTableAddr;
  const AIndex: UInt64; const ARef: TWasmRef);
begin
  if AAddr >= UInt32(Length(Tables)) then
    raise EWasmError.CreateFmt('internal: no table %u', [AAddr]);
  if TableIndexOutOfBounds(Tables[AAddr], AIndex) then
    TrapNow(wtkTableOutOfBounds);
  { Root-array store: barrier BEFORE the write so a future generational
    collector records the edge (empty in v1; the site is what matters). }
  FHeap.WriteBarrier(WASM_REF_NULL, ARef);
  Tables[AAddr].Elems[AIndex] := ARef;
end;

procedure TWasmStore.TableFill(const AAddr: TWasmTableAddr;
  const AIndex, ACount: UInt64; const ARef: TWasmRef);
var
  Cursor: UInt64;
begin
  if AAddr >= UInt32(Length(Tables)) then
    raise EWasmError.CreateFmt('internal: no table %u', [AAddr]);
  TableCheckRange(Tables[AAddr], AIndex, ACount);
  { One barrier for the whole fill: every stored slot takes the same
    reference, so recording that edge once is sufficient for any
    remembered-set design. }
  if ACount > 0 then
    FHeap.WriteBarrier(WASM_REF_NULL, ARef);
  Cursor := 0;
  while Cursor < ACount do
  begin
    Tables[AAddr].Elems[AIndex + Cursor] := ARef;
    Inc(Cursor);
  end;
end;

function TWasmStore.TableGrow(const AAddr: TWasmTableAddr;
  const ADelta: UInt64; const AInit: TWasmRef): Int64;
var
  OldSize: UInt64;
  NewSize: UInt64;
  Cursor: UInt64;
begin
  if AAddr >= UInt32(Length(Tables)) then
    raise EWasmError.CreateFmt('internal: no table %u', [AAddr]);
  { table.grow returns -1 on failure and does not trap. }
  OldSize := UInt64(Length(Tables[AAddr].Elems));
  if ADelta > Tables[AAddr].MaxSize - OldSize then
    Exit(-1);
  NewSize := OldSize + ADelta;
  { A dynamic array is indexed by a signed native integer, so a length
    past that is not representable however much memory exists. }
  if NewSize > UInt64(High(NativeInt)) div UInt64(SizeOf(TWasmRef)) then
    Exit(-1);

  try
    SetLength(Tables[AAddr].Elems, NativeInt(NewSize));
  except
    { A host allocation failure is not a trap and not an error class of
      the wasm hierarchy: table.grow's whole contract is that it FAILS
      rather than raising. The except frame is safe under TRAP-1 because
      nothing inside it can longjmp. }
    on EOutOfMemory do
      Exit(-1);
  end;

  if NewSize > OldSize then
    FHeap.WriteBarrier(WASM_REF_NULL, AInit);
  Cursor := OldSize;
  while Cursor < NewSize do
  begin
    Tables[AAddr].Elems[Cursor] := AInit;
    Inc(Cursor);
  end;
  Result := Int64(OldSize);
end;

procedure TWasmStore.TableInitFromElem(const AAddr: TWasmTableAddr;
  const ADstOffset: UInt64; const ASrc: array of TWasmRef);
var
  Cursor: UInt64;
  Count: UInt64;
begin
  if AAddr >= UInt32(Length(Tables)) then
    raise EWasmError.CreateFmt('internal: no table %u', [AAddr]);
  Count := UInt64(Length(ASrc));
  { Range check precedes any write, so a trapping table.init writes
    nothing — table.init's own semantics. }
  TableCheckRange(Tables[AAddr], ADstOffset, Count);
  Cursor := 0;
  while Cursor < Count do
  begin
    FHeap.WriteBarrier(WASM_REF_NULL, ASrc[Cursor]);
    Tables[AAddr].Elems[ADstOffset + Cursor] := ASrc[Cursor];
    Inc(Cursor);
  end;
end;

procedure TWasmStore.TableInitFromElem(const AAddr: TWasmTableAddr;
  const ADstOffset: UInt64; const ASrc: array of TWasmRef;
  const ASrcOffset, ACount: UInt64);
var
  Cursor: UInt64;
  SrcLen: UInt64;
begin
  { O-2 sliced form (the interpreter's table.init). BOTH sides are checked
    before any write, so a trapping table.init writes nothing. }
  if AAddr >= UInt32(Length(Tables)) then
    raise EWasmError.CreateFmt('internal: no table %u', [AAddr]);
  { Source range against the element instance's length; subtracting form so
    a large offset on a long slice cannot wrap. A dropped segment has
    Length 0, so any non-empty slice traps. Same message as the dest side. }
  SrcLen := UInt64(Length(ASrc));
  if (ASrcOffset > SrcLen) or (ACount > SrcLen - ASrcOffset) then
    TrapNow(wtkTableOutOfBounds);
  TableCheckRange(Tables[AAddr], ADstOffset, ACount);
  Cursor := 0;
  while Cursor < ACount do
  begin
    FHeap.WriteBarrier(WASM_REF_NULL, ASrc[ASrcOffset + Cursor]);
    Tables[AAddr].Elems[ADstOffset + Cursor] := ASrc[ASrcOffset + Cursor];
    Inc(Cursor);
  end;
end;

procedure TWasmStore.TableCopy(const ADestAddr: TWasmTableAddr;
  const ADstIdx: UInt64; const ASrcAddr: TWasmTableAddr;
  const ASrcIdx: UInt64; const ACount: UInt64);
var
  Cursor: UInt64;
  Slot: UInt64;
  Backward: Boolean;
  Ref: TWasmRef;
begin
  if ADestAddr >= UInt32(Length(Tables)) then
    raise EWasmError.CreateFmt('internal: no table %u', [ADestAddr]);
  if ASrcAddr >= UInt32(Length(Tables)) then
    raise EWasmError.CreateFmt('internal: no table %u', [ASrcAddr]);
  { BOTH ranges checked before any write, trapping 'out of bounds table
    access' (exec-table.copy). The range check precedes the copy so a
    trapping table.copy leaves the destination untouched. }
  TableCheckRange(Tables[ADestAddr], ADstIdx, ACount);
  TableCheckRange(Tables[ASrcAddr], ASrcIdx, ACount);

  { memmove semantics: only the SAME table can overlap, and then a forward
    copy clobbers not-yet-read source slots when the destination is higher,
    so copy backward in exactly that case. }
  Backward := (ADestAddr = ASrcAddr) and (ADstIdx > ASrcIdx);
  Cursor := 0;
  while Cursor < ACount do
  begin
    if Backward then
      Slot := ACount - 1 - Cursor
    else
      Slot := Cursor;
    Ref := Tables[ASrcAddr].Elems[ASrcIdx + Slot];
    { Root-array store: barrier at every reference store (empty in v1). }
    FHeap.WriteBarrier(WASM_REF_NULL, Ref);
    Tables[ADestAddr].Elems[ADstIdx + Slot] := Ref;
    Inc(Cursor);
  end;
end;

function TWasmStore.AddGlobal(const AGlobalType: TWasmGlobalType;
  const AValue: TWasmValue): TWasmGlobalAddr;
begin
  Result := TWasmGlobalAddr(Length(Globals));
  SetLength(Globals, Length(Globals) + 1);
  Globals[Result].GlobalType := AGlobalType;
  Globals[Result].Value := AValue;
  { A global of reference type is a root UNCONDITIONALLY, mutable or not.
    The filter runs here, once, so the collector scans a dense list rather
    than testing every global's kind on every cycle. }
  if AGlobalType.ValueType.Kind = wvkRef then
  begin
    if FRefGlobalCount >= Length(FRefGlobals) then
      SetLength(FRefGlobals, (FRefGlobalCount + 1) * 2);
    FRefGlobals[FRefGlobalCount] := Result;
    Inc(FRefGlobalCount);
  end;
end;

function TWasmStore.AddGlobalVec(const AGlobalType: TWasmGlobalType;
  const AVec: TWasmV128): TWasmGlobalAddr;
begin
  Result := TWasmGlobalAddr(Length(Globals));
  SetLength(Globals, Length(Globals) + 1);
  Globals[Result].GlobalType := AGlobalType;
  Globals[Result].Value.Bits := 0;
  Globals[Result].Vec := AVec;
  { A v128 is never a reference: nothing to register as a root. }
end;

function TWasmStore.AddTag(
  const ATypeId: TWasmEngineTypeId): TWasmTagAddr;
begin
  Result := TWasmTagAddr(Length(Tags));
  SetLength(Tags, Length(Tags) + 1);
  Tags[Result].TypeId := ATypeId;
end;

function TWasmStore.AddElem(
  const ARefType: TWasmRefType): TWasmElemAddr;
begin
  Result := TWasmElemAddr(Length(Elems));
  SetLength(Elems, Length(Elems) + 1);
  Elems[Result].RefType := ARefType;
  Elems[Result].Dropped := False;
end;

function TWasmStore.AddData(const AData: PByte;
  const ASize: NativeUInt): TWasmDataAddr;
begin
  Result := TWasmDataAddr(Length(Datas));
  SetLength(Datas, Length(Datas) + 1);
  Datas[Result].Data := AData;
  Datas[Result].Size := ASize;
  Datas[Result].Dropped := False;
end;

function TWasmStore.FuncRefAddr(const ARef: TWasmRef): TWasmFuncAddr;
begin
  Result := TWasmFuncAddr(GcFuncRefAddr(ARef));
end;

function TWasmStore.ScratchFrame(const ACount: UInt32): PWasmValue;
begin
  if ACount = 0 then
    Exit(nil);
  if ACount > UInt32(Length(FScratch)) then
    SetLength(FScratch, ACount);
  { Contract GC-1: a frame is zeroed at entry, so an unwritten reference
    slot reads as null. An unzeroed slot is indistinguishable from a live
    reference. }
  ValueZeroSlots(@FScratch[0], ACount);
  Result := @FScratch[0];
end;

function TWasmStore.ScratchRefBits(const ARegTypes: TWasmIrRegTypes;
  const ACount: UInt32): PWasmGcRefBits;
var
  Words: Integer;
  Index: Integer;
  Reg: UInt32;
begin
  if ACount = 0 then
    Exit(nil);
  Words := (Integer(ACount) + 31) div 32;
  if Words > Length(FScratchBits) then
    SetLength(FScratchBits, Words);
  for Index := 0 to Words - 1 do
    FScratchBits[Index] := 0;
  Reg := 0;
  while (Reg < ACount) and (Reg < UInt32(Length(ARegTypes))) do
  begin
    if ARegTypes[Reg].Kind = wvkRef then
      FScratchBits[Reg div 32] := FScratchBits[Reg div 32] or
        (UInt32(1) shl (Reg and 31));
    Inc(Reg);
  end;
  Result := PWasmGcRefBits(@FScratchBits[0]);
end;

function TWasmStore.AddInstance(
  const AInstance: TWasmModuleInstance): TWasmModuleInstance;
begin
  SetLength(Instances, Length(Instances) + 1);
  Instances[High(Instances)] := AInstance;
  Result := AInstance;
end;

procedure TWasmStore.RunPendingStart(
  const AInstance: TWasmModuleInstance);
var
  Addr: TWasmFuncAddr;
begin
  CheckThread;
  if (AInstance = nil) or (not AInstance.HasPendingStart) then
    Exit;
  if not Assigned(TierInvoke) then
    raise EWasmError.Create(MSG_START_NEEDS_TIER);
  Addr := AInstance.FuncAddrs[AInstance.PendingStartFuncIndex];
  AInstance.HasPendingStart := False;
  { GUEST ENTRY (ADR-0009 / contract GC-1). A trap unwinds by siglongjmp
    to the tier's trampoline, which raises EWasmTrap — and every guest
    frame between the fault and the landing pad had its PopFrame SKIPPED,
    so the heap's frame chain is left dangling. This is the top-level
    host->guest entry, so re-establishing the chain here (rather than
    trusting it) is the trampoline's documented obligation. On a clean
    return the chain is already balanced and this is a no-op; it runs in
    finally so a trap gets the same treatment. Coordinates with the Gc
    agent's Heap.ResetFrames and the Traps agent's trampoline. }
  try
    TierInvoke(Self, Addr, nil, nil);
  finally
    FHeap.ResetFrames;
  end;
end;

{ --- runtime subtyping --------------------------------------------------- }

function IsRefOfType(const AEngine: TWasmEngine; const ARef: TWasmRef;
  const ATypeId: TWasmEngineTypeId): Boolean;
var
  Kind: TWasmObjKind;
begin
  { Null and unboxed i31 are settled by encoding, with no header read:
    neither has a concrete runtime type. }
  if not RefIsObject(ARef) then
    Exit(False);
  Kind := GcRefKind(ARef);
  { A host box's header id is a placeholder and an exception's is its
    TAG's functype, so neither answers a concrete cast — extern and exn
    "have no concrete subtypes". }
  if (Kind <> wokStruct) and (Kind <> wokArray) and (Kind <> wokFuncRef) then
    Exit(False);
  Result := AEngine.Matches(GcRefTypeId(ARef), ATypeId);
end;

function IsRefOfRefType(const AEngine: TWasmEngine; const ARef: TWasmRef;
  const ATarget: TWasmRefType): Boolean;
begin
  if RefIsNull(ARef) then
  begin
    { The cast of a null reduces to "does the target admit null" — a
      static property of the target needing nothing from the value,
      because valid-ref.cast already typed the operand at a supertype in
      the same hierarchy. }
    Result := ATarget.Nullable;
    Exit;
  end;

  if RefIsI31(ARef) then
  begin
    { i31 is never a concrete type. }
    if not ATarget.Heap.IsAbstract then
      Exit(False);
    Result := AbsHeapSubtype(wahI31, ATarget.Heap.Abs);
    Exit;
  end;

  if ATarget.Heap.IsAbstract then
  begin
    Result := AbsHeapSubtype(GcAbsKindOf(GcRefKind(ARef)),
      ATarget.Heap.Abs);
    Exit;
  end;

  Result := IsRefOfType(AEngine, ARef, ATarget.Heap.TypeIndex);
end;

{ --- host roots ---------------------------------------------------------- }

function RootRegister(const AStore: TWasmStore;
  const ARef: TWasmRef): TWasmRootHandle;
begin
  Result := AStore.Heap.RootRegister(ARef);
end;

function RootGet(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle): TWasmRef;
begin
  Result := AStore.Heap.RootGet(AHandle);
end;

procedure RootSet(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle; const ARef: TWasmRef);
begin
  AStore.Heap.RootSet(AHandle, ARef);
end;

procedure RootRelease(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle);
begin
  AStore.Heap.RootRelease(AHandle);
end;

function RootScopeEnter(const AStore: TWasmStore): UInt32;
begin
  Result := AStore.Heap.RootScopeEnter;
end;

procedure RootScopeLeave(const AStore: TWasmStore; const AMark: UInt32);
begin
  AStore.Heap.RootScopeLeave(AMark);
end;

function TrampolineStore(const ATrampoline: PWasmTrampoline): TWasmStore;
begin
  if ATrampoline = nil then
    Exit(nil);
  Result := TWasmStore(ATrampoline^.Context);
end;

function WasmJitOffsets(const AStore: TWasmStore): TWasmJitOffsets;
var
  F: TWasmFuncInst;
  M: TWasmMemoryInst;
begin
  { Only the ADDRESSES of fields are taken, never their values, so the
    uninitialised locals F and M are not read. }
  Result.StoreEpoch := PtrUInt(@AStore.Epoch) - PtrUInt(Pointer(AStore));
  Result.StoreEpochSnapshot :=
    PtrUInt(@AStore.EpochSnapshot) - PtrUInt(Pointer(AStore));
  Result.StoreJitHelperTable :=
    PtrUInt(@AStore.JitHelperTable) - PtrUInt(Pointer(AStore));
  Result.FuncInstStride := SizeOf(TWasmFuncInst);
  Result.FuncKind := PtrUInt(@F.Kind) - PtrUInt(@F);
  Result.FuncCompiledEntry := PtrUInt(@F.CompiledEntry) - PtrUInt(@F);
  Result.FuncCompiledDirectEntry :=
    PtrUInt(@F.CompiledDirectEntry) - PtrUInt(@F);
  Result.FuncCallCount := PtrUInt(@F.CallCount) - PtrUInt(@F);
  Result.MemInstStride := SizeOf(TWasmMemoryInst);
  Result.MemBase := PtrUInt(@M.Base) - PtrUInt(@M);
  Result.MemByteSize := PtrUInt(@M.ByteSize) - PtrUInt(@M);
end;

end.
