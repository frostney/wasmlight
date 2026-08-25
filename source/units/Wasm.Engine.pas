{ Wasm.Engine — the host-facing embedding facade over the shipped runtime.

  This unit is a FACADE and nothing more (embedding-spec §1). Every method
  delegates to a shipped procedure: decode/validate (Wasm.Decoder /
  Wasm.Validator), the store and its type interner (Wasm.Runtime.Store),
  instantiation (Wasm.Runtime.Instantiate), the interpreter trampoline
  (Wasm.Interp), the memory chokepoint (via TWasmStore), and the collector's
  host-root API (Wasm.Runtime.Gc, re-exported over the store). It adds NO
  runtime logic — if a method would need new runtime, it belongs in the layer
  it delegates to. The value it adds is (a) an ergonomic object surface that
  hides the TWasmImports-by-kind vectors and the intern/instantiate/register
  dance, (b) the typed host-import builder (TWasmLinker), (c) the capability
  boundary made explicit — an import not defined on the linker is simply
  absent and instantiation fails with EWasmLinkError, there is no ambient
  fallback, and (d) the rooting-handle surface for contract HOST-1.

  INHERITED INVARIANTS this unit must not weaken:

    - Deny-by-default host capability (AGENTS.md, ADR-0002). A host function,
      global, memory, or table reaches the guest only through TWasmLinker,
      which the embedder fills explicitly.
    - The error hierarchy is load-bearing (AGENTS.md). LoadModule never
      collapses EWasmDecodeError (not a module) and EWasmValidationError (a
      module, ill-typed); Instantiate raises EWasmLinkError for a bad import;
      Call lets EWasmTrap, EWasmException, and EWasmExit propagate distinctly.
    - Memory only through the chokepoint (ADR-0005/0010/0013). MemRead /
      MemWrite route to TWasmStore.MemRangeAt with an overflow-safe pre-check;
      this unit never sees a memory's Base and never does pointer arithmetic
      on guest memory — the store keeps FMemories private for exactly that
      reason and the facade does not widen it.
    - Traps unwind to the trampoline (ADR-0009). Host->guest calls go through
      Wasm.Interp.InterpInvoke, so a trap becomes a catchable EWasmTrap on
      ordinary Pascal ground, never a longjmp into a missing trampoline.
    - Host roots need explicit registration (ADR-0011, contract HOST-1). A
      host holding a TWasmRef — or a caught exnref — across anything that can
      allocate MUST root it; the re-exported RootRegister/RootScopeEnter/... do
      that, and RootValueRef / RootExceptionRef are the ergonomic handles.
    - A store is confined to one thread (ADR-0008). This unit adds no locks
      and surfaces the store's own CheckThread as CheckStoreThread.
    - BorrowsBuffer is surfaced (contract HOST-2, ADR-0003). A loaded module
      OWNS its byte buffer and must outlive every instance; TWasmInstance
      forwards BorrowsBuffer as the honest lifetime query.

  Spec pin (for the embedding anchors this API mirrors): wasm-mcp 0.2.16,
  spec/main d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). The entry
  points mirror the core spec's Embedding appendix (anchor `embed`;
  module_instantiate, func_invoke, func_alloc, instance_export,
  mem_read / mem_write). }
unit Wasm.Engine;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator;

type
  { A clean, guest-requested exit (embedding-spec §6.1). NOT a trap (the guest
    did not fault) and NOT a wasm exception (no `throw`) — it is a request to
    stop, raised by a WASI proc_exit callback as an ORDINARY Pascal raise from
    a host callback, propagated unchanged by InterpInvoke's trampoline. It is
    an EWasmError subtype so the trampoline's `on E: EWasmError` re-raise path
    carries it out, but a distinct class so a host classifies it exactly.

    Declared here, in Wasm.Engine, because proc_exit is a host-surface concept
    and Wasm.Core's hierarchy is about guest faults. F1 only needs the class
    to exist for the layers above (F2's proc_exit raises it, F3's `run` maps
    ExitCode to a process code); Call lets it propagate like any EWasmError. }
  EWasmExit = class(EWasmError)
  public
    ExitCode: Int32;
    constructor CreateExit(const ACode: Int32);
  end;

  TWasmImportArray = array of TWasmImport;
  TWasmExportArray = array of TWasmExport;

  { An opaque handle onto an exported memory. It can only be USED through the
    chokepoint accessors (MemRead / MemWrite / MemSize / the scalar twins),
    never dereferenced: the store keeps memories private and hands out no
    Base, and this handle carries only the store and the memory address. }
  TWasmMemoryRef = record
    Store: TWasmStore;
    Addr: TWasmMemAddr;
  end;

  { An opaque handle onto an exported global. }
  TWasmGlobalRef = record
    Store: TWasmStore;
    Addr: TWasmGlobalAddr;
  end;

  { An exported-function handle. ParamTypes / ResultTypes are the callee's
    signature (engine space; for slot counting only the Kind matters — a v128
    spans two adjacent TWasmValue slots, embedding-spec §1.6). }
  TWasmFunc = record
    Store: TWasmStore;
    Addr: TWasmFuncAddr;
    ParamTypes: array of TWasmValueType;
    ResultTypes: array of TWasmValueType;
  end;

  { A loaded, validated module: the IR plus the OWNED byte buffer, ready to
    instantiate any number of times.

    LIFETIME (ADR-0003, contract HOST-2): it owns its byte buffer, its decoded
    model, and its IR. It MUST outlive every TWasmInstance created from it —
    an instance borrows the IR and the bytes, and freeing this while an
    instance is live is a use-after-free with no diagnostic. The bytes are
    COPIED at load (embedding-spec §1.2) so the loaded module's lifetime is
    self-contained even for an embedder that read from a transient stream. }
  TWasmLoadedModule = class
  private
    FBytes: TWasmBytes;    { OWNED — a private copy }
    FModule: TWasmModule;  { OWNED — the decoded model, for import/export names }
    FIr: TWasmIrModule;    { OWNED — borrowed by every instance }
  public
    { Decode + validate ABytes into a loaded module. Raises EWasmDecodeError
      (not a module) or EWasmValidationError (a module, not well-typed) —
      never collapses the two. ABytes is copied. }
    constructor Create(const ABytes: TWasmBytes);
    destructor Destroy; override;

    { The module's imports (module, name, kind, type), so the embedder/linker
      knows exactly what to provide. In import-section order. }
    function Imports: TWasmImportArray;
    { The module's exports (name, kind, index). `exports` is a reserved word,
      so the getter is escaped (spell it `Loaded.&Exports`), matching
      Wasm.Module's own convention. }
    function &Exports: TWasmExportArray;

    { The borrowed byte buffer (ADR-0003). Stable for the life of this object. }
    function BytesPtr: PByte;
    function BytesLength: NativeUInt;

    property Ir: TWasmIrModule read FIr;
    property Model: TWasmModule read FModule;
  end;

  { The import set under construction — the capability boundary as a Pascal
    object (embedding-spec §1.3). It maps (module, name) to a store entity the
    embedder is EXPLICITLY providing; nothing is provided implicitly. An
    import a module needs but the linker was not told to define is a link
    failure at ResolveImports/Instantiate, never a silent no-op. }
  TWasmLinker = class
  private
    type
      TDef = record
        ModuleName: string;
        Name: string;
        Kind: TWasmExternKind;
        { wxkFunc — resolved lazily at ResolveImports time (§1.4). }
        Params: array of TWasmValueType;
        Results: array of TWasmValueType;
        Callback: TWasmHostFunc;
        Data: Pointer;
        { wxkMem / wxkGlobal — minted eagerly, addr recorded. No wxkTable:
          the linker exposes no DefineTable in v1, so a table import has no
          def to match and falls through to the link error below. }
        Addr: UInt32;
      end;
  private
    FStore: TWasmStore;
    FDefs: array of TDef;
    FDefCount: Integer;

    function FindDef(const AModule, AName: string; out ADef: TDef): Boolean;
    procedure AddDef(const ADef: TDef);
  public
    constructor Create(const AStore: TWasmStore);

    { Register a host function for (module, name). AParams/AResults name the
      wasm signature the host func presents; the matching engine type id is
      minted at ResolveImports time from the importing module's own declared
      functype (§1.4), so MatchFuncImport reduces to id equality — while an
      explicit structural check rejects a host whose declared signature does
      not match what the guest imported. ACallback is the shipped
      TWasmHostFunc; AData is opaque host state (a WASI context, say). }
    procedure DefineFunc(const AModule, AName: string;
      const AParams, AResults: array of TWasmValueType;
      const ACallback: TWasmHostFunc; const AData: Pointer);

    { Host globals / memories the embedder chooses to export to the guest.
      Provided for general embedding — WASI preview1 needs NONE of these (it
      is all functions plus the guest's own exported memory). A memory takes a
      TWasmMemType directly. A global's value type must be numeric or vector
      in v1 (a concrete reference element would need engine-space interning
      the facade does not perform here); an abstract-heap reference passes
      through unchanged. }
    procedure DefineMemory(const AModule, AName: string;
      const AType: TWasmMemType; out AAddr: TWasmMemAddr);
    procedure DefineGlobal(const AModule, AName: string;
      const AType: TWasmGlobalType; const AInitial: TWasmValue);

    { Resolve one module's imports against what has been defined, producing
      the by-kind TWasmImports the shipped InstantiateModule wants, in module
      index order per kind. Raises EWasmLinkError naming the first
      (module, name) that is missing (MSG_LINK_UNKNOWN_IMPORT) or whose kind
      or host signature does not match (MSG_LINK_INCOMPATIBLE_IMPORT) —
      deny-by-default, before any store observation. }
    function ResolveImports(const AModule: TWasmLoadedModule): TWasmImports;
  end;

  { A live instance: a thin handle over a store-owned TWasmModuleInstance.
    Freeing a TWasmInstance frees only this handle — the underlying instance
    is owned by the store and released when the store is freed (§1.1). }
  TWasmInstance = class
  private
    FStore: TWasmStore;
    FInst: TWasmModuleInstance;
  public
    constructor Create(const AStore: TWasmStore;
      const AInst: TWasmModuleInstance);

    function FindExportFunc(const AName: string; out AFunc: TWasmFunc): Boolean;
    function FindExportMemory(const AName: string;
      out AMem: TWasmMemoryRef): Boolean;
    function FindExportGlobal(const AName: string;
      out AGlobal: TWasmGlobalRef): Boolean;

    { Contract HOST-2 (ADR-0003): true while at least one data segment is
      undropped, i.e. while the loaded module's bytes must stay alive. }
    function BorrowsBuffer: Boolean;

    property Raw: TWasmModuleInstance read FInst;
    property Store: TWasmStore read FStore;
  end;

{ --- loading ------------------------------------------------------------- }

{ Decode + validate bytes into a loaded module. The bytes are copied
  (embedding-spec §1.2), so the returned module's lifetime is self-contained.
  Raises EWasmDecodeError or EWasmValidationError — never both collapsed. }
function LoadModule(const ABytes: TWasmBytes): TWasmLoadedModule;
{ Read APath and load it. EWasmDecodeError when the file cannot be read. }
function LoadModuleFromFile(const APath: string): TWasmLoadedModule;

{ --- instantiating and calling ------------------------------------------- }

{ Ensure AStore runs guest code through the interpreter tier. Idempotent —
  wraps Wasm.Interp.RegisterInterpreter. Instantiate calls it, so an embedder
  rarely needs it directly. }
procedure EnsureInterpreter(const AStore: TWasmStore);

{ Link + instantiate. Delegates to ResolveImports then InstantiateModule.
  Raises EWasmLinkError on a bad import (from the linker or the runtime) and
  EWasmTrap on an out-of-bounds active elem/data segment. A module with a
  start function instantiates and records the start pending; RunStart runs it.
  The returned TWasmInstance is a handle the caller frees; the underlying
  instance is store-owned. }
function Instantiate(const AStore: TWasmStore; const ALinker: TWasmLinker;
  const AModule: TWasmLoadedModule): TWasmInstance;

{ Run the module's start function, if any, through the trampoline. A trap or
  uncaught exception in start propagates as EWasmTrap/EWasmException. }
procedure RunStart(const AStore: TWasmStore; const AInstance: TWasmInstance);

{ Call an exported function. AArgs must match the callee's parameter SLOTS in
  order/arity (a v128 argument is two adjacent slots, low half first —
  embedding-spec §1.6); AResults is filled in result-slot order and must be
  the callee's result-slot count long. Goes through InterpInvoke (installs the
  trampoline), so a guest trap is a catchable EWasmTrap, an uncaught guest
  throw an EWasmException, and a proc_exit an EWasmExit — the caller catches. }
procedure Call(const AFunc: TWasmFunc; const AArgs: array of TWasmValue;
  var AResults: array of TWasmValue);

{ Read an exported global's current value. }
function GlobalGet(const AGlobal: TWasmGlobalRef): TWasmValue;

{ --- exported-memory access (embedding-spec §1.6 / §5) -------------------

  All bounds-checked through the store chokepoint (MemRangeAt), NEVER raw Base
  arithmetic. An out-of-bounds access returns False (does not raise, does not
  crash) — the sandbox boundary the WASI layer builds on. The range check is
  an unsigned, overflow-safe pre-check against MemSize, so the copy never
  provokes a guard-page fault on any strategy and needs no trampoline. }

{ Size of the memory in BYTES. }
function MemSize(const AMem: TWasmMemoryRef): UInt64;

{ Copy ALength bytes from guest offset AOffset into ADest. False (no raise) if
  the range is out of bounds. }
function MemRead(const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
  ADest: PByte): Boolean;
{ Copy ALength bytes from ASrc into guest offset AOffset. False on OOB. }
function MemWrite(const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
  ASrc: PByte): Boolean;

{ Typed scalar accessors (little-endian, wasm's byte order). Each is a
  MemRead/MemWrite of the right width; False on OOB. }
function MemReadU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt32): Boolean;
function MemWriteU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt32): Boolean;
function MemReadU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt64): Boolean;
function MemWriteU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt64): Boolean;

{ --- host roots (contract HOST-1, embedding-spec §1.6) -------------------

  Re-exported so an embedder needs only `uses Wasm.Engine`. A host (or a WASI
  callback) that keeps a TWasmRef — a funcref, externref, anyref, or a caught
  exnref — in its own Pascal storage across ANYTHING that can allocate
  (another Call, a struct.new in a re-entrant guest call, a subsequent
  instantiation) MUST root it: the engine's param/result buffers are not on
  the GC frame chain and the collector cannot see a ref the host stashed. A
  host-held ref that is not rooted is collectable on the next allocation, with
  no diagnostic. The handle is an index into a store-owned array, so it
  survives the array growing; under the non-moving collector RootGet returns
  the pointer with no read barrier. }
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

{ Ergonomic HOST-1 handles. RootValueRef roots the reference carried in a
  TWasmValue result slot (the value a Call handed back). RootExceptionRef
  roots the exnref an uncaught EWasmException carries — the Track H F3/F4
  forward hazard made safe: a host that catches an EWasmException and wants to
  inspect its tag/payload, or re-throw it into a later guest call, across an
  intervening Call/allocation, MUST root it the instant it catches. }
function RootValueRef(const AStore: TWasmStore;
  const AValue: TWasmValue): TWasmRootHandle;
function RootExceptionRef(const AStore: TWasmStore;
  const AException: EWasmException): TWasmRootHandle;

{ --- single-thread confinement (ADR-0008) -------------------------------- }

{ Surface the store's own confinement check. Raises EWasmError in debug builds
  when called off the store's owning thread; a no-op in PRODUCTION. }
procedure CheckStoreThread(const AStore: TWasmStore);

implementation

{$IFNDEF WASM_RUNTIME_SHELL}
uses
  Wasm.Interp;
{$ENDIF}

const
  { A linear-memory page is 64 KiB (spec `page-size`). Named locally so the
    byte-size helper reads the store's page count without reaching into
    Wasm.Runtime.Memory — metadata only, still no Base. }
  WASM_PAGE_SIZE_BYTES = UInt64(65536);

{ --- EWasmExit ----------------------------------------------------------- }

constructor EWasmExit.CreateExit(const ACode: Int32);
begin
  inherited Create('guest requested exit');
  ExitCode := ACode;
end;

{ --- slot counting ------------------------------------------------------- }

{ Slots a value type occupies in the flat marshal array: a v128 spans two
  (embedding-spec §1.6), everything else one. }
function TypeSlots(const AType: TWasmValueType): Integer; inline;
begin
  if AType.Kind = wvkVec then
    Result := 2
  else
    Result := 1;
end;

function SumSlots(const ATypes: array of TWasmValueType): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ATypes) do
    Inc(Result, TypeSlots(ATypes[I]));
end;

{ --- TWasmLoadedModule --------------------------------------------------- }

constructor TWasmLoadedModule.Create(const ABytes: TWasmBytes);
var
  Index: Integer;
begin
  inherited Create;
  { Own a private copy so the lifetime is self-contained (ADR-0003, §1.2). }
  SetLength(FBytes, Length(ABytes));
  for Index := 0 to High(ABytes) do
    FBytes[Index] := ABytes[Index];

  FModule := TWasmModule.Create;
  { DecodeModule may raise EWasmDecodeError, ValidateModule
    EWasmValidationError (or EWasmDecodeError for a body-only grammar
    violation). Neither is collapsed — the caller discriminates. On a raise
    the half-built object is torn down by the caller's freeing convention;
    free the model here so a raise leaks nothing. }
  try
    DecodeModule(FBytes, FModule);
    FIr := ValidateModule(FModule, FBytes);
  except
    FreeAndNil(FModule);
    raise;
  end;
end;

destructor TWasmLoadedModule.Destroy;
begin
  { The IR borrows the bytes and the model; free it first, then the model,
    then let the managed byte array release. }
  FIr.Free;
  FModule.Free;
  inherited Destroy;
end;

function TWasmLoadedModule.Imports: TWasmImportArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, FModule.ImportCount);
  for Index := 0 to FModule.ImportCount - 1 do
    Result[Index] := FModule.Imports[Index];
end;

function TWasmLoadedModule.&Exports: TWasmExportArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, FModule.ExportCount);
  for Index := 0 to FModule.ExportCount - 1 do
    Result[Index] := FModule.&Exports[Index];
end;

function TWasmLoadedModule.BytesPtr: PByte;
begin
  if Length(FBytes) = 0 then
    Result := nil
  else
    Result := @FBytes[0];
end;

function TWasmLoadedModule.BytesLength: NativeUInt;
begin
  Result := NativeUInt(Length(FBytes));
end;

function LoadModule(const ABytes: TWasmBytes): TWasmLoadedModule;
begin
  Result := TWasmLoadedModule.Create(ABytes);
end;

function LoadModuleFromFile(const APath: string): TWasmLoadedModule;
begin
  { LoadFileBytes raises EWasmDecodeError with the path when the file cannot
    be read — the honest class for "there is no module here". }
  Result := TWasmLoadedModule.Create(LoadFileBytes(APath));
end;

{ --- TWasmLinker --------------------------------------------------------- }

constructor TWasmLinker.Create(const AStore: TWasmStore);
begin
  inherited Create;
  if AStore = nil then
    raise EWasmError.Create('a linker needs a store');
  FStore := AStore;
  FDefCount := 0;
end;

procedure TWasmLinker.AddDef(const ADef: TDef);
begin
  if FDefCount >= Length(FDefs) then
    SetLength(FDefs, (FDefCount + 1) * 2);
  FDefs[FDefCount] := ADef;
  Inc(FDefCount);
end;

function TWasmLinker.FindDef(const AModule, AName: string;
  out ADef: TDef): Boolean;
var
  Index: Integer;
begin
  { Last definition wins for a repeated (module, name) — walk from the end. }
  for Index := FDefCount - 1 downto 0 do
    if (FDefs[Index].ModuleName = AModule) and (FDefs[Index].Name = AName) then
    begin
      ADef := FDefs[Index];
      Exit(True);
    end;
  Result := False;
end;

procedure TWasmLinker.DefineFunc(const AModule, AName: string;
  const AParams, AResults: array of TWasmValueType;
  const ACallback: TWasmHostFunc; const AData: Pointer);
var
  Def: TDef;
  Index: Integer;
begin
  Def := Default(TDef);
  Def.ModuleName := AModule;
  Def.Name := AName;
  Def.Kind := wxkFunc;
  SetLength(Def.Params, Length(AParams));
  for Index := 0 to High(AParams) do
    Def.Params[Index] := AParams[Index];
  SetLength(Def.Results, Length(AResults));
  for Index := 0 to High(AResults) do
    Def.Results[Index] := AResults[Index];
  Def.Callback := ACallback;
  Def.Data := AData;
  AddDef(Def);
end;

procedure TWasmLinker.DefineMemory(const AModule, AName: string;
  const AType: TWasmMemType; out AAddr: TWasmMemAddr);
var
  Def: TDef;
begin
  AAddr := FStore.AddMemory(AType);
  Def := Default(TDef);
  Def.ModuleName := AModule;
  Def.Name := AName;
  Def.Kind := wxkMem;
  Def.Addr := AAddr;
  AddDef(Def);
end;

procedure TWasmLinker.DefineGlobal(const AModule, AName: string;
  const AType: TWasmGlobalType; const AInitial: TWasmValue);
var
  Def: TDef;
begin
  { EngineGlobalType leaves a numeric/vector value type and an abstract-heap
    reference unchanged (an empty map). A concrete reference element would
    index the empty map and raise — the documented v1 limitation. }
  Def := Default(TDef);
  Def.ModuleName := AModule;
  Def.Name := AName;
  Def.Kind := wxkGlobal;
  Def.Addr := FStore.AddGlobal(EngineGlobalType(AType, nil), AInitial);
  AddDef(Def);
end;

{ Structural equality of two value types, across module and engine space.
  Numeric and vector types compare exactly (they are identical in both
  spaces); a reference type compares nullability and its abstract-heap code or
  concrete index. This is what rejects a host whose declared signature does
  not match the functype the guest imported (§1.4). }
function ValueTypeEquals(const A, B: TWasmValueType): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    wvkNum:
      Result := A.Num = B.Num;
    wvkVec:
      Result := True;
    wvkRef:
      begin
        if A.Ref.Nullable <> B.Ref.Nullable then
          Exit(False);
        if A.Ref.Heap.IsAbstract <> B.Ref.Heap.IsAbstract then
          Exit(False);
        if A.Ref.Heap.IsAbstract then
          Result := A.Ref.Heap.Abs = B.Ref.Heap.Abs
        else
          Result := A.Ref.Heap.TypeIndex = B.Ref.Heap.TypeIndex;
      end;
  else
    Result := False;
  end;
end;

function FuncSignatureMatches(const AFunc: TWasmFuncType;
  const AParams, AResults: array of TWasmValueType): Boolean;
var
  Index: Integer;
begin
  if (Length(AFunc.Params) <> Length(AParams)) or
    (Length(AFunc.Results) <> Length(AResults)) then
    Exit(False);
  for Index := 0 to High(AParams) do
    if not ValueTypeEquals(AFunc.Params[Index], AParams[Index]) then
      Exit(False);
  for Index := 0 to High(AResults) do
    if not ValueTypeEquals(AFunc.Results[Index], AResults[Index]) then
      Exit(False);
  Result := True;
end;

procedure AppendAddr(var AVec: TWasmAddrs; const AAddr: UInt32);
begin
  SetLength(AVec, Length(AVec) + 1);
  AVec[High(AVec)] := AAddr;
end;

function TWasmLinker.ResolveImports(
  const AModule: TWasmLoadedModule): TWasmImports;
var
  CanonIds, TypeIds: TWasmEngineTypeIds;
  Index: Integer;
  Imp: TWasmImport;
  Def: TDef;
  ExpectedId: TWasmEngineTypeId;
  EngType: TWasmEngineType;
  Addr: TWasmFuncAddr;
begin
  Result.Funcs := nil;
  Result.Tables := nil;
  Result.Mems := nil;
  Result.Globals := nil;
  Result.Tags := nil;

  { Intern the module (idempotent — TWasmEngine.InternModule caches, so this
    second-or-later call over the same IR allocates nothing; InstantiateModule
    interns again and reads the same ids). TypeIds maps a module TYPE INDEX to
    its engine id, which is exactly the engine id of a func import's declared
    functype (§1.4). }
  FStore.Engine.InternModule(AModule.Ir, CanonIds, TypeIds);

  for Index := 0 to AModule.Model.ImportCount - 1 do
  begin
    Imp := AModule.Model.Imports[Index];
    if not FindDef(Imp.ModuleName, Imp.Name, Def) then
      raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
        [string(MSG_LINK_UNKNOWN_IMPORT), Imp.ModuleName, Imp.Name]);
    if Def.Kind <> Imp.Kind then
      raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
        [string(MSG_LINK_INCOMPATIBLE_IMPORT), Imp.ModuleName, Imp.Name]);

    case Imp.Kind of
      wxkFunc:
        begin
          if Imp.FuncTypeIndex >= UInt32(Length(TypeIds)) then
            raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
              [string(MSG_LINK_INCOMPATIBLE_IMPORT), Imp.ModuleName, Imp.Name]);
          ExpectedId := TypeIds[Imp.FuncTypeIndex];
          EngType := FStore.Engine.EngineType(ExpectedId);
          { Verify the host's DECLARED signature equals the functype the guest
            imported — a guest importing with the wrong arity/types must be
            rejected, not silently mis-marshaled. Creating the host func with
            the module's own ExpectedId then makes MatchFuncImport reduce to
            id equality (trivially true). }
          if (EngType.Comp.Kind <> wckFunc) or
            (not FuncSignatureMatches(EngType.Comp.Func, Def.Params,
              Def.Results)) then
            raise EWasmLinkError.CreateFmt('%s: "%s"."%s": host import '
              + 'signature mismatch', [string(MSG_LINK_INCOMPATIBLE_IMPORT),
              Imp.ModuleName, Imp.Name]);
          Addr := FStore.AddHostFunc(ExpectedId, Def.Callback, Def.Data);
          AppendAddr(Result.Funcs, Addr);
        end;
      wxkMem:
        AppendAddr(Result.Mems, Def.Addr);
      wxkGlobal:
        AppendAddr(Result.Globals, Def.Addr);
    else
      { A table or tag import is not part of the v1 linker surface — there is
        no DefineTable/DefineTag, so no def of that kind can exist, and the
        kind check above already rejected any such import. This else is the
        honest catch-all (WASI needs neither in v1). }
      raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
        [string(MSG_LINK_INCOMPATIBLE_IMPORT), Imp.ModuleName, Imp.Name]);
    end;
  end;
end;

{ --- TWasmInstance ------------------------------------------------------- }

constructor TWasmInstance.Create(const AStore: TWasmStore;
  const AInst: TWasmModuleInstance);
begin
  inherited Create;
  FStore := AStore;
  FInst := AInst;
end;

function TWasmInstance.FindExportFunc(const AName: string;
  out AFunc: TWasmFunc): Boolean;
var
  Kind: TWasmExternKind;
  Addr: UInt32;
  FuncType: TWasmFuncType;
begin
  AFunc.Store := FStore;
  AFunc.Addr := 0;
  AFunc.ParamTypes := nil;
  AFunc.ResultTypes := nil;
  Result := FInst.FindExport(AName, Kind, Addr) and (Kind = wxkFunc);
  if not Result then
    Exit;
  AFunc.Addr := Addr;
  FuncType := FStore.Engine.EngineType(FStore.Funcs[Addr].TypeId).Comp.Func;
  AFunc.ParamTypes := FuncType.Params;
  AFunc.ResultTypes := FuncType.Results;
end;

function TWasmInstance.FindExportMemory(const AName: string;
  out AMem: TWasmMemoryRef): Boolean;
var
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  AMem.Store := FStore;
  AMem.Addr := 0;
  Result := FInst.FindExport(AName, Kind, Addr) and (Kind = wxkMem);
  if Result then
    AMem.Addr := Addr;
end;

function TWasmInstance.FindExportGlobal(const AName: string;
  out AGlobal: TWasmGlobalRef): Boolean;
var
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  AGlobal.Store := FStore;
  AGlobal.Addr := 0;
  Result := FInst.FindExport(AName, Kind, Addr) and (Kind = wxkGlobal);
  if Result then
    AGlobal.Addr := Addr;
end;

function TWasmInstance.BorrowsBuffer: Boolean;
begin
  Result := FInst.BorrowsBuffer(FStore);
end;

{ --- instantiate / run / call -------------------------------------------- }

procedure EnsureInterpreter(const AStore: TWasmStore);
begin
  {$IFDEF WASM_RUNTIME_SHELL}
  raise EWasmInternal.Create(
    'internal: runtime shell has no interpreter');
  {$ELSE}
  RegisterInterpreter(AStore);
  {$ENDIF}
end;

function Instantiate(const AStore: TWasmStore; const ALinker: TWasmLinker;
  const AModule: TWasmLoadedModule): TWasmInstance;
var
  Imports: TWasmImports;
  Inst: TWasmModuleInstance;
begin
  if (AStore = nil) or (ALinker = nil) or (AModule = nil) then
    raise EWasmError.Create('instantiate needs a store, linker and module');
  { Wire the tier once so RunStart / Call have a trampoline. Idempotent.
    The runtime shell instantiates through InstantiateModule and installs
    NativeTierInvoke instead — it must not pull InterpTierInvoke. }
  {$IFNDEF WASM_RUNTIME_SHELL}
  RegisterInterpreter(AStore);
  {$ENDIF}
  Imports := ALinker.ResolveImports(AModule);
  Inst := InstantiateModule(AStore, AModule.Ir, AModule.BytesPtr,
    AModule.BytesLength, Imports);
  Result := TWasmInstance.Create(AStore, Inst);
end;

procedure RunStart(const AStore: TWasmStore; const AInstance: TWasmInstance);
begin
  AStore.RunPendingStart(AInstance.Raw);
end;

procedure Call(const AFunc: TWasmFunc; const AArgs: array of TWasmValue;
  var AResults: array of TWasmValue);
var
  ParamSlots, ResultSlots, Index: Integer;
  Params, Results: array of TWasmValue;
  ParamPtr, ResultPtr: PWasmValue;
begin
  if AFunc.Store = nil then
    raise EWasmError.Create('call on an unbound function handle');
  ParamSlots := SumSlots(AFunc.ParamTypes);
  ResultSlots := SumSlots(AFunc.ResultTypes);
  if Length(AArgs) <> ParamSlots then
    raise EWasmError.CreateFmt(
      'call: %d argument slots supplied, the function takes %d',
      [Length(AArgs), ParamSlots]);
  if Length(AResults) <> ResultSlots then
    raise EWasmError.CreateFmt(
      'call: %d result slots supplied, the function returns %d',
      [Length(AResults), ResultSlots]);

  SetLength(Params, ParamSlots);
  for Index := 0 to ParamSlots - 1 do
    Params[Index] := AArgs[Index];
  SetLength(Results, ResultSlots);

  if ParamSlots > 0 then
    ParamPtr := @Params[0]
  else
    ParamPtr := nil;
  if ResultSlots > 0 then
    ResultPtr := @Results[0]
  else
    ResultPtr := nil;

  { Through InterpInvoke (the WasmInvoke trampoline): a trap becomes a
    catchable EWasmTrap, an uncaught throw an EWasmException, proc_exit an
    EWasmExit — all EWasmError, propagated to the caller unchanged. }
  {$IFDEF WASM_RUNTIME_SHELL}
  raise EWasmInternal.Create(
    'internal: runtime shell has no interpreter');
  {$ELSE}
  InterpInvoke(AFunc.Store, AFunc.Addr, ParamPtr, ResultPtr);
  {$ENDIF}

  for Index := 0 to ResultSlots - 1 do
    AResults[Index] := Results[Index];
end;

function GlobalGet(const AGlobal: TWasmGlobalRef): TWasmValue;
begin
  Result := AGlobal.Store.Globals[AGlobal.Addr].Value;
end;

{ --- exported-memory access ---------------------------------------------- }

function MemSize(const AMem: TWasmMemoryRef): UInt64;
begin
  Result := AMem.Store.MemoryPages(AMem.Addr) * WASM_PAGE_SIZE_BYTES;
end;

function MemRead(const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
  ADest: PByte): Boolean;
var
  Size: UInt64;
  Src: PByte;
begin
  Size := MemSize(AMem);
  { Overflow-safe: never AOffset + ALength (which wraps). }
  if (AOffset > Size) or (ALength > Size - AOffset) then
    Exit(False);
  if ALength > 0 then
  begin
    { Pre-verified in bounds, so MemRangeAt returns a pointer without
      trapping, and the copy touches only in-range bytes. }
    Src := AMem.Store.MemRangeAt(AMem.Addr, AOffset, ALength);
    Move(Src^, ADest^, ALength);
  end;
  Result := True;
end;

function MemWrite(const AMem: TWasmMemoryRef; const AOffset, ALength: UInt64;
  ASrc: PByte): Boolean;
var
  Size: UInt64;
  Dest: PByte;
begin
  Size := MemSize(AMem);
  if (AOffset > Size) or (ALength > Size - AOffset) then
    Exit(False);
  if ALength > 0 then
  begin
    Dest := AMem.Store.MemRangeAt(AMem.Addr, AOffset, ALength);
    Move(ASrc^, Dest^, ALength);
  end;
  Result := True;
end;

function MemReadU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt32): Boolean;
var
  B: array[0..3] of Byte;
begin
  AValue := 0;
  Result := MemRead(AMem, AOffset, 4, @B[0]);
  if Result then
    AValue := UInt32(B[0]) or (UInt32(B[1]) shl 8) or
      (UInt32(B[2]) shl 16) or (UInt32(B[3]) shl 24);
end;

function MemWriteU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt32): Boolean;
var
  B: array[0..3] of Byte;
begin
  B[0] := Byte(AValue);
  B[1] := Byte(AValue shr 8);
  B[2] := Byte(AValue shr 16);
  B[3] := Byte(AValue shr 24);
  Result := MemWrite(AMem, AOffset, 4, @B[0]);
end;

function MemReadU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt64): Boolean;
var
  B: array[0..7] of Byte;
  Index: Integer;
begin
  AValue := 0;
  Result := MemRead(AMem, AOffset, 8, @B[0]);
  if Result then
    for Index := 0 to 7 do
      AValue := AValue or (UInt64(B[Index]) shl (Index * 8));
end;

function MemWriteU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt64): Boolean;
var
  B: array[0..7] of Byte;
  Index: Integer;
begin
  for Index := 0 to 7 do
    B[Index] := Byte(AValue shr (Index * 8));
  Result := MemWrite(AMem, AOffset, 8, @B[0]);
end;

{ --- host roots ---------------------------------------------------------- }

function RootRegister(const AStore: TWasmStore;
  const ARef: TWasmRef): TWasmRootHandle;
begin
  Result := Wasm.Runtime.Store.RootRegister(AStore, ARef);
end;

function RootGet(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle): TWasmRef;
begin
  Result := Wasm.Runtime.Store.RootGet(AStore, AHandle);
end;

procedure RootSet(const AStore: TWasmStore; const AHandle: TWasmRootHandle;
  const ARef: TWasmRef);
begin
  Wasm.Runtime.Store.RootSet(AStore, AHandle, ARef);
end;

procedure RootRelease(const AStore: TWasmStore;
  const AHandle: TWasmRootHandle);
begin
  Wasm.Runtime.Store.RootRelease(AStore, AHandle);
end;

function RootScopeEnter(const AStore: TWasmStore): UInt32;
begin
  Result := Wasm.Runtime.Store.RootScopeEnter(AStore);
end;

procedure RootScopeLeave(const AStore: TWasmStore; const AMark: UInt32);
begin
  Wasm.Runtime.Store.RootScopeLeave(AStore, AMark);
end;

function RootValueRef(const AStore: TWasmStore;
  const AValue: TWasmValue): TWasmRootHandle;
begin
  Result := Wasm.Runtime.Store.RootRegister(AStore, AValue.Ref);
end;

function RootExceptionRef(const AStore: TWasmStore;
  const AException: EWasmException): TWasmRootHandle;
begin
  { EWasmException.ExnRef is the raw wokExn handle as a NativeUInt, which is
    exactly a TWasmRef. Root it the instant the host catches, before any
    Call/allocation (embedding-spec §1.6). }
  Result := Wasm.Runtime.Store.RootRegister(AStore, TWasmRef(AException.ExnRef));
end;

{ --- single-thread confinement ------------------------------------------- }

procedure CheckStoreThread(const AStore: TWasmStore);
begin
  AStore.CheckThread;
end;

end.
