{ Wasm.Runtime.Gc — the precise, non-moving, stop-the-world collector and
  everything that knows the shape of a GC heap object.

  ADR-0011, in one paragraph. The collector is PRECISE: it knows exactly
  which slots hold references, because validation already recorded the
  static type of every register and TWasmIrFunction.RefRegBits is the
  projection of that table. It is NON-MOVING mark-sweep with segregated
  size classes, which is what lets a host hold a raw TWasmRef across a
  call with only a registration — no handle indirection, no read barrier,
  and a missed root is a use-after-free rather than a silently relocated
  object. It is STOP-THE-WORLD and single-threaded, because ADR-0008
  confines a store to one thread and there is no external agent that needs
  the mutator to stop. And collection is triggered AT ALLOCATION SITES
  ONLY: back-edges and function entries stay safepoints and must still be
  able to produce a stack map (contract GC-2), but they do not poll —
  there is nothing for them to poll for.

  THIS UNIT DOES NOT DEPEND ON Wasm.Runtime.Store. The collector is driven
  BY the store rather than reaching into it: the store installs one root
  callback (SetRootSource) and hands the heap a layout table the engine
  owns. That inversion is what makes the whole of this wave testable with
  a synthetic root set and no store at all, and it is deliberate.

  THE ONE ALIGNMENT INVARIANT. Every object is 8-byte aligned on both
  bitnesses. That is what reserves bit 0 of an object pointer for
  Wasm.Runtime.Values' unboxed-i31 tag, so it is an allocator invariant
  rather than a preference: an object at an odd address would be read back
  as an i31 and never traced.

  WHAT IS NOT HERE. No finalizers, no weak references, no post-mortem
  callbacks, no resurrection — the pinned 3.0 draft has none of them, and
  the store clause's only word on reclamation is that "implementations may
  apply techniques like garbage collection or reference counting to remove
  objects from the store that are no longer referenced. However, such
  techniques are not semantically observable" (`syntax-store`).
  TWasmHostRelease is the one adjacent hook and it is NOT a wasm-visible
  finalizer: it is the embedder's chance to drop its own refcount when a
  host box is swept.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004).
  Anchors: syntax-store, syntax-fieldval (struct/array instances),
  syntax-exninst, syntax-structinst, syntax-arrayinst, aux-packfield /
  aux-unpackfield, aux-default, syntax-reftype ("values of reference type
  can be stored in tables but not in memories" — linear memory is not a
  root), struct.get and array.get (trap messages), impl-exec (allocation
  failure is an embedder-specific error). }
unit Wasm.Runtime.Gc;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values;

type
  { An engine-global canonical type id, spelled without naming
    Wasm.Runtime.Store's TWasmEngineTypeId — that unit sits ABOVE this one
    and typing the field from there would invert the dependency. The two
    are the same u32 and the store hands its ids straight in. }
  TWasmGcTypeId = UInt32;

  PWasmRef = ^TWasmRef;

  { The five heap object kinds. wokExn's layout is fixed HERE, in Track D,
    with throw/catch left to Track H: "an exception instance … holds the
    address of the respective tag and the argument values"
    (`syntax-exninst`) is a fixed shape, and discovering in Track H that
    exnref needs a sixth kind would mean changing the header enum, the
    trace loop and the abstract-kind map at a point where the collector is
    already under test. }
  TWasmObjKind = (
    wokStruct,
    wokArray,
    wokFuncRef,
    wokHostBox,
    wokExn
  );

  { The embedder's hook for a swept host box. NOT a finalization API — see
    the unit header. Track F decides whether to expose it. }
  TWasmHostRelease = procedure(const APayload: NativeUInt);

const
  { The 64-bit header word, on both bitnesses:

      bit   0      MARK
      bit   1      FORWARDED (a copying collector's; unused in v1, and
                   reserved so the escape hatch in the design contract
                   does not need a header change)
      bits  2..4   TWasmObjKind
      bits  5..31  reserved
      bits 32..63  engine canonical type id

    The type id sits in the HIGH half so the O(1) subtype check is one
    shift and one array index with no masking.

    THE HEADER DOES NOT STORE SIZE. Size is derived from Kind plus the
    engine type — a struct's field count and packing, an array's length
    word times its element width. That is one indirection on the trace
    path in exchange for 4-8 bytes on every object, and object counts in a
    GC workload are large. Bits 5..31 are where a size cache goes if
    measurement ever says otherwise. }
  WASM_OBJ_MARK_BIT = UInt64(1);
  WASM_OBJ_FORWARDED_BIT = UInt64(2);
  WASM_OBJ_KIND_SHIFT = 2;
  WASM_OBJ_KIND_MASK = UInt64(7);
  WASM_OBJ_TYPE_SHIFT = 32;

  { The type id a wokHostBox carries in its header. A host box has no
    engine type — GcAbsKindOf derives its abstract kind (wahExtern) from
    the KIND, never the id — so the id field must not be a real engine id
    like 0 (B14): a cast surface that reached for GcRefTypeId on a host box
    would otherwise collide with the module's engine type 0. This sentinel
    is above every engine id; reading it back is a loud "not a typed
    object" rather than a plausible wrong answer. }
  WASM_GC_NO_TYPE_ID = High(UInt32);

  { The two aux-default invariant messages the runtime raises when a module
    the validator should have rejected reaches struct.new_default /
    array.new_default. Promoted to named constants (B16) so the co-located
    test asserts against the same text rather than a duplicated literal. }
  MSG_GC_STRUCT_FIELD_NO_DEFAULT =
    'internal: struct field %d has no default value';
  MSG_GC_ARRAY_ELEM_NO_DEFAULT =
    'internal: the array element type has no default value';

  { A v128 struct field or array element is a valid TYPE (the validator
    admits vector storage types; only the $FD instruction space is staged),
    so a valid module can reach a v128 field at run time through
    struct.new_default / array.new_default (the zero vector default) or a
    struct.get / array.get whose v128 result is dropped. That is a staged-
    SIMD gap (Track G), NOT a bare 'internal:' engine bug (B15). This string
    mirrors Wasm.Validator.Types.MSG_SIMD_NOT_IMPLEMENTED verbatim — that
    unit sits above this one, so the constant is duplicated deliberately —
    so the message a module sees for staged SIMD is the same wherever it is
    hit. }
  MSG_GC_VEC_STORAGE_STAGED = 'SIMD validation is not implemented';

  { Object layouts, by kind. Every one starts with the header word and
    every total is rounded up to 8.

      wokStruct   [header:8][field 0][field 1]...
      wokArray    [header:8][length:8][elem 0]...
      wokFuncRef  [header:8][funcaddr:4][pad:4]
      wokHostBox  [header:8][payload:NativeUInt][release:Pointer]
      wokExn      [header:8][tagaddr:4][argc:4][arg 0 : TWasmValue]...

    An array's length is a SEPARATE WORD rather than header bits: a length
    is u32 and the header has 27 spare bits, which is not enough. }
  WASM_OBJ_HEADER_SIZE = 8;
  WASM_ARRAY_LENGTH_OFFSET = 8;
  WASM_ARRAY_ELEMS_OFFSET = 16;
  WASM_FUNCREF_ADDR_OFFSET = 8;
  WASM_FUNCREF_SIZE = 16;
  WASM_HOSTBOX_PAYLOAD_OFFSET = 8;
  WASM_HOSTBOX_RELEASE_OFFSET = 8 + SizeOf(NativeUInt);
  WASM_HOSTBOX_SIZE = 8 + 2 * SizeOf(NativeUInt);
  WASM_EXN_TAG_OFFSET = 8;
  WASM_EXN_ARGC_OFFSET = 12;
  WASM_EXN_ARGS_OFFSET = 16;

type
  { One field's storage, resolved to bytes.

    Width is the storage width: 1 for i8, 2 for i16, 4 for i32/f32, 8 for
    i64/f64, SizeOf(TWasmRef) for a reference, 16 for v128 (Track G). }
  TWasmGcField = record
    Offset: UInt32;
    Width: UInt32;
    IsPacked: Boolean;
    PackedKind: TWasmPackedType;
    IsRef: Boolean;
    IsVec: Boolean;
    { Whether aux-default gives this storage a value: always for a packed
      or numeric field, only for a NULLABLE reference otherwise. "For
      other references, no default value is defined", which is what makes
      struct.new_default's validation rule load-bearing rather than
      cosmetic — recorded per field so the runtime checks it without
      keeping the value type around. }
    HasDefault: Boolean;
  end;

  TWasmGcFields = array of TWasmGcField;
  TWasmGcOffsets = array of UInt32;

  PWasmGcLayout = ^TWasmGcLayout;

  { The byte layout of one engine type, computed ONCE when the type is
    interned and never again.

    FIELDS ARE LAID OUT IN DECLARATION ORDER, each at the next offset that
    is a multiple of its own width. Declaration order rather than
    size-sorted is REQUIRED and it is the single most important
    consequence of GC subtyping on layout: a struct subtype extends its
    supertype by APPENDING fields (`Structtype_sub`), so the subtype's
    prefix must have byte-identical layout to the supertype, or a
    struct.get through a supertype-typed reference reads the wrong bytes.
    Size-sorting silently breaks that, which is why there is a test for it
    rather than only a comment.

    RefFieldOffsets is the offsets of exactly the reference-typed fields,
    so tracing a struct is a loop over a small array and needs no
    per-object map. RefArgSlots is the same idea for an exception's
    arguments, which are TWasmValue slots whose reference-ness is NOT
    derivable from the object — it comes from the tag's functype params. }
  TWasmGcLayout = record
    Defined: Boolean;
    Kind: TWasmCompKind;
    { wckStruct }
    Fields: TWasmGcFields;
    RefFieldOffsets: TWasmGcOffsets;
    Size: UInt32;
    { wckArray }
    Elem: TWasmGcField;
    { wckFunc — the tag functype behind a wokExn }
    RefArgSlots: TWasmGcOffsets;
  end;

  { The layout table. OWNED BY THE ENGINE, not by a heap: a layout is a
    property of an engine type, engine types are shared by every store
    built on that engine, and computing them per store would be the same
    answer three times. The heap borrows it. }
  TWasmGcTypes = class
  private
    FLayouts: array of TWasmGcLayout;
    FCount: Integer;

    procedure Grow(const ACount: Integer);
  public
    { Compute and record the layout of engine type AId from its ENGINE-space
      composite. Idempotent: defining the same id twice recomputes the same
      answer, because a layout is a pure function of the composite. }
    procedure Define(const AId: TWasmGcTypeId; const AComp: TWasmCompType);

    function IsDefined(const AId: TWasmGcTypeId): Boolean;
    { Raises EWasmError for an id with no layout — an internal invariant
      violation, since every engine type gets one at intern time. }
    function Layout(const AId: TWasmGcTypeId): PWasmGcLayout;
    function Count: Integer;
  end;

const
  { Segregated size classes. A block is bump-allocated within its class
    until exhausted, then the next block comes off the class's list, which
    is what recovers most of bump allocation's speed without paying
    copying's permanent 2x memory overhead. Anything larger than the top
    class is allocated on its own and freed outright when swept. }
  WASM_GC_CLASS_COUNT = 9;
  WASM_GC_SIZE_CLASSES: array[0..WASM_GC_CLASS_COUNT - 1] of UInt32 =
    (16, 24, 32, 48, 64, 96, 128, 192, 256);

  { 64 KiB of cells per block. Small enough that a mostly-empty heap does
    not round up to something embarrassing on a 32-bit target (ADR-0010),
    large enough that block bookkeeping is noise. }
  WASM_GC_BLOCK_BYTES = 64 * 1024;

  { The collection trigger. Live bytes past the threshold at an allocation
    site means collect, then re-target the threshold at a multiple of what
    survived, never below the floor. Both are settable so a test can make
    collection deterministic by setting the floor to zero. }
  WASM_GC_DEFAULT_THRESHOLD = UInt64(1024 * 1024);
  WASM_GC_GROWTH_FACTOR = 2;

  { Freed cells are poisoned outside PRODUCTION builds. Under mark-sweep a
    missed root frees a live object, and the object is at least still
    THERE until it is reused — poison is what turns "still there" into a
    loud failure rather than a plausible read. }
  WASM_GC_POISON = Byte($DE);

  { A free cell carries two u64 words: the next cell on its class's list,
    and the block it belongs to (so an allocation off the list can find
    the bitmap that says the cell is now live). Fixed 8-byte slots rather
    than SizeOf(Pointer) ones, because on a 32-bit host a u64 link at 0
    and a pointer at 4 would overlap. The smallest class is 16 bytes,
    which is exactly these two words. }
  WASM_GC_FREE_LINK_OFFSET = 0;
  WASM_GC_FREE_BLOCK_OFFSET = 8;

type
  TWasmRootHandle = UInt32;

const
  WASM_NO_ROOT = High(UInt32);

type
  PWasmGcRefBits = ^UInt32;

  PWasmGcFrame = ^TWasmGcFrame;

  { CONTRACT GC-1, as implemented — the frame chain the collector walks.

    Track E maintains a per-store chain of active guest frames; the
    collector walks Prev from the innermost and, for each frame, iterates
    the set bits of RefRegBits over [0, RegisterCount), treating
    Slots[i].Ref as a root.

    Three obligations on every tier:

      1. EVERY REGISTER IN [0, RegisterCount) WHOSE TYPE IS A REFERENCE
         MUST HOLD A VALID TWasmRef (possibly null) AT EVERY SAFEPOINT. A
         register that has not been written yet must read as null, so the
         frame is ZEROED AT ENTRY (ValueZeroSlots). This is the single
         most important line in the contract: an unzeroed slot is
         indistinguishable from a live reference.
      2. The frame record is pushed before the first safepoint in the
         function and popped after the last. A frame that is live but not
         on the chain is a lost root.
      3. Tail calls replace the frame IN PLACE and the replacement must
         not span a safepoint. Zero the new frame before publishing it.

    DEVIATION FROM THE DESIGN CONTRACT, recorded deliberately. The
    contract spelled this record with `Fn: PWasmIrFunction`, from which
    the walk reads exactly two things: RefRegBits and RegisterCount. Those
    two are carried directly instead, for two reasons. It keeps this unit
    off Wasm.Ir, which is what the layering asks for. And Tracks I and J
    get their maps "from a side table keyed by return address rather than
    from the frame" — a JIT frame has no TWasmIrFunction to point at, and
    would otherwise have to fabricate one. The walk is unchanged either
    way. Track E passes @Fn^.RefRegBits[0] and Fn^.RegisterCount.

    Init-expression frames join the same chain, with the bits derived from
    TWasmIrInitExpr.RegTypes exactly as IrComputeRefRegBits derives them
    for a function. Track D builds and walks those itself; they exist
    before Track E does. }
  TWasmGcFrame = record
    Prev: PWasmGcFrame;
    { The register file, RegisterCount slots long. }
    Slots: PWasmValue;
    { Bitset, 32 registers per word; bit i set iff register i is a ref. }
    RefRegBits: PWasmGcRefBits;
    RegisterCount: UInt32;
    { The frame's module instance. Opaque here — the collector does not
      read it, and typing it would pull in Wasm.Runtime.Store. }
    Instance: Pointer;
  end;

  TWasmGcHeap = class;

  { How the store hands over its roots. One callback rather than a
    structural dependency: the store calls AHeap.MarkRoot for each of its
    reference-typed globals, every table element, every element instance's
    references, and every function instance's handle. }
  TWasmGcRootProc = procedure(const AHeap: TWasmGcHeap;
    const AContext: Pointer);

  PWasmGcBlock = ^TWasmGcBlock;

  { One block of cells of a single size class, or one large object. Blocks
    are never returned to the host: a freed cell goes on its class's free
    list, and the address stability that buys is the same property that
    lets a host root be a raw pointer. }
  TWasmGcBlock = record
    Raw: Pointer;
    Base: PByte;
    CellSize: UInt32;
    CellCount: UInt32;
    { Cells handed out by the bump pointer. Cells at or above this index
      have never been allocated and are not on any free list. }
    Carved: UInt32;
    { One bit per cell: set while the cell holds a live object. This is
      what lets the sweep distinguish a free cell from an object without
      reading the object, and what lets the free lists be rebuilt from
      scratch each cycle rather than maintained across one. }
    Allocated: array of UInt32;
    ClassIndex: Integer;
    IsLarge: Boolean;
  end;

  { The v1 heap. One per store, owned by it. }
  TWasmGcHeap = class
  private
    FTypes: TWasmGcTypes;              { BORROWED — engine-owned }

    FBlocks: array of PWasmGcBlock;
    FBlockCount: Integer;
    FLarge: array of PWasmGcBlock;
    FLargeCount: Integer;
    FFree: array[0..WASM_GC_CLASS_COUNT - 1] of PByte;
    FBump: array[0..WASM_GC_CLASS_COUNT - 1] of PWasmGcBlock;

    FRoots: array of TWasmRef;
    FRootCount: Integer;
    FRootFree: array of TWasmRootHandle;
    FRootFreeCount: Integer;

    FFrames: PWasmGcFrame;
    FRootProc: TWasmGcRootProc;
    FRootContext: Pointer;

    FMarkStack: array of TWasmRef;
    FMarkCount: Integer;
    FCollecting: Boolean;
    { The mark-bit VALUE (0 or WASM_OBJ_MARK_BIT) that means "reached, live"
      for the current epoch. Flipped once per cycle (design §7.1: "bit 0 =
      MARK, flipped per cycle") so a completed sweep leaves survivors marked
      without a clear pass, and — combined with the abort recovery in
      Collect — a cycle that raises part-way leaves no lasting mark (H8). }
    FMarkState: UInt64;
{$IFNDEF PRODUCTION}
    { Test-only fault injection: the next N NewBlock calls report host
      allocator failure, making the collect-then-retry path (§7.3, M8)
      reachable from a unit test. Never compiled into a PRODUCTION build. }
    FInjectBlockFailures: Integer;
{$ENDIF}

    FBytesLive: UInt64;
    FBytesAllocated: UInt64;
    FBytesReclaimed: UInt64;
    FHeapBytes: UInt64;
    FObjectCount: UInt64;
    FCollectionCount: UInt64;
    FThreshold: UInt64;
    FThresholdFloor: UInt64;

    function ClassOf(const ASize: UInt32): Integer;
    function NewBlock(const AClassIndex: Integer; const ACellSize: UInt32;
      const ACellCount: UInt32; const AIsLarge: Boolean): PWasmGcBlock;
    procedure FreeBlock(const ABlock: PWasmGcBlock);
    function TakeCell(const ASize: UInt32): PByte;
    function Allocate(const ASize: UInt32; const AKind: TWasmObjKind;
      const ATypeId: TWasmGcTypeId): PByte;

    procedure Push(const ARef: TWasmRef);
    procedure MarkRoots;
    procedure MarkFrames;
    procedure Drain;
    procedure Trace(const ARef: TWasmRef);
    procedure Sweep;
    procedure ClearAllMarks;
    procedure FillRange(const ARef: TWasmRef; const AOffset, ACount: UInt32;
      const AValue: TWasmValue);
    procedure ReleaseObject(const ACell: PByte);

    function LayoutOf(const ARef: TWasmRef): PWasmGcLayout;
    function StructField(const ARef: TWasmRef;
      const AField: UInt32): TWasmGcField;
    function ArrayElement(const ARef: TWasmRef;
      const AIndex: UInt32): TWasmGcField;

    procedure SetThreshold(const AValue: UInt64);
  public
    { ATypes is BORROWED and must outlive the heap. It is the engine's
      layout table; every id the heap is handed must already be defined
      there. }
    constructor Create(const ATypes: TWasmGcTypes);
    destructor Destroy; override;

    { --- allocation --------------------------------------------------
      Every one of these is a safepoint: it may collect, and a reference
      the caller holds only in a Pascal local is NOT a root. Register it,
      or keep it in a frame slot the stack map covers.

      All allocation zeroes the object, which is not merely tidy: a
      collection triggered by the NEXT allocation would otherwise trace
      whatever the recycled cell used to hold. }
    function AllocStruct(const ATypeId: TWasmGcTypeId): TWasmRef;
    function AllocArray(const ATypeId: TWasmGcTypeId;
      const ALength: UInt32): TWasmRef;
    function AllocFuncRef(const AFuncAddr: UInt32;
      const ATypeId: TWasmGcTypeId): TWasmRef;
    function AllocHostBox(const APayload: NativeUInt;
      const ARelease: TWasmHostRelease): TWasmRef;
    function AllocExn(const ATagAddr: UInt32;
      const ATypeId: TWasmGcTypeId; const AArgCount: UInt32): TWasmRef;

    { aux-default over every field / element. A zeroed object already
      holds those values; these check that each one HAS a default and
      raise EWasmError if not, which is the invariant the validator
      guarantees for struct.new_default and array.new_default
      ("null for nullable reference types … For other references, no
      default value is defined"). }
    procedure StructSetDefaults(const ARef: TWasmRef);
    procedure ArraySetDefaults(const ARef: TWasmRef);

    { --- field and element access ------------------------------------
      Get on a null reference traps `null reference` (confirmed for
      struct.get); an array index out of bounds traps `out of bounds
      array access` (UNCONFIRMED — array.get reports can_trap:false at the
      pin, which is a gap in the served data rather than the truth; Track
      C's assert_trap corpus settles it).

      Get / GetSigned / GetUnsigned mirror the three instructions:
      struct.get is for unpacked fields only, struct.get_s and
      struct.get_u for packed ones, sign- or zero-extending from the
      packed width (`aux-unpackfield`). Set truncates (`aux-packfield`). }
    function StructFieldCount(const ARef: TWasmRef): UInt32;
    function StructGet(const ARef: TWasmRef;
      const AField: UInt32): TWasmValue;
    function StructGetSigned(const ARef: TWasmRef;
      const AField: UInt32): Int32;
    function StructGetUnsigned(const ARef: TWasmRef;
      const AField: UInt32): UInt32;
    procedure StructSet(const ARef: TWasmRef; const AField: UInt32;
      const AValue: TWasmValue);

    function ArrayLength(const ARef: TWasmRef): UInt32;
    function ArrayGet(const ARef: TWasmRef;
      const AIndex: UInt32): TWasmValue;
    function ArrayGetSigned(const ARef: TWasmRef;
      const AIndex: UInt32): Int32;
    function ArrayGetUnsigned(const ARef: TWasmRef;
      const AIndex: UInt32): UInt32;
    procedure ArraySet(const ARef: TWasmRef; const AIndex: UInt32;
      const AValue: TWasmValue);
    { Whole-array fill (array.new's initialiser). Kept as the two-argument
      form so existing callers are undisturbed; both overloads read layout,
      element field and length ONCE and store in place, rather than routing
      each element back through ArraySet (B12: that re-fetched
      layout+length+field per element — quadratic on the fill path). }
    procedure ArrayFill(const ARef: TWasmRef;
      const AValue: TWasmValue); overload;
    { array.fill's RANGE form (L20): [AOffset, AOffset+ACount) with AValue,
      trapping `out of bounds array access` if the range escapes the array. }
    procedure ArrayFill(const ARef: TWasmRef;
      const AOffset, ACount: UInt32; const AValue: TWasmValue); overload;

    { --- bulk array ops the interpreter's array.copy/init_* need (O-6/O-8) --
      Each reads the layout(s) ONCE, honours packed element widths, and calls
      WriteBarrier at every reference-element store. Trap kinds/messages are
      corpus-CONFIRMED (the pinned server reports the whole 3.0 array family
      can_trap:false, a gap in the served data) — see the anchor and corpus
      line at each implementation. }

    { array.copy (exec-array.copy). Copy ACount elements from ASrc[ASrcIdx..]
      into ADest[ADestIdx..]. Element-type-compatible by validation, so the
      widths match. Overlap-safe (memmove semantics) when source and
      destination are the SAME array. A null on EITHER side traps
      'null array reference'; either range out of bounds traps
      'out of bounds array access' (corpus array_copy.wast:97-98, 101-106).
      Barriered per reference element. }
    procedure ArrayCopy(const ADest: TWasmRef; const ADestIdx: UInt32;
      const ASrc: TWasmRef; const ASrcIdx: UInt32; const ACount: UInt32);

    { array.init_data (exec-array.init_data). Copy ACount elements from a
      passive/active data segment's bytes (ADataBytes, ADataSize, borrowed —
      Gc sits below Wasm.Runtime.Store so the caller passes the raw span, not
      a TWasmDataInst) starting at BYTE offset ADataByteOffset into a
      numeric/packed-element array. ADataByteOffset is a byte offset; each
      element is the array element's storage width. A null dest traps
      'null array reference'; the DEST range out of bounds traps
      'out of bounds array access'; the DATA source byte range out of bounds
      traps 'out of bounds memory access' (corpus array_init_data.wast:68,
      71-72). No barrier — array.init_data's element type is never a
      reference (the validator guarantees it). }
    procedure ArrayInitFromData(const ADest: TWasmRef; const ADestIdx: UInt32;
      const ADataBytes: PByte; const ADataSize: NativeUInt;
      const ADataByteOffset: UInt64; const ACount: UInt32);

    { array.init_elem (exec-array.init_elem). Copy ACount references from an
      element segment's Refs (ASrc, borrowed) starting at element index
      ASrcOffset into a reference-element array. A null dest traps
      'null array reference'; the DEST range out of bounds traps
      'out of bounds array access'; the ELEM source range out of bounds traps
      'out of bounds table access' (corpus array_init_elem.wast:85, 88-89).
      Barriered per element. }
    procedure ArrayInitFromElem(const ADest: TWasmRef; const ADestIdx: UInt32;
      const ASrc: array of TWasmRef; const ASrcOffset: UInt32;
      const ACount: UInt32);

    function ExnTagAddr(const ARef: TWasmRef): UInt32;
    function ExnArgCount(const ARef: TWasmRef): UInt32;
    function ExnArg(const ARef: TWasmRef; const AIndex: UInt32): TWasmValue;
    procedure ExnSetArg(const ARef: TWasmRef; const AIndex: UInt32;
      const AValue: TWasmValue);

    { --- collection --------------------------------------------------- }

    { Stop-the-world, full, non-moving. Safe to call with nothing live. }
    procedure Collect;

    { Report a root. Only meaningful from inside a root callback or the
      frame walk; null and unboxed i31 references are skipped by encoding
      and cost one test. }
    procedure MarkRoot(const ARef: TWasmRef);

    { THE WRITE BARRIER. Empty in v1 and shipped anyway — its existence is
      the whole point. Every reference-field store calls it: struct.set,
      array.set, array.fill, array.copy, array.init_*, and table.set /
      table.fill / table.copy / table.init, because tables are root arrays
      and a generational collector needs them in its remembered set too.
      Retrofitting a barrier means touching every one of those sites in
      three tiers, which is exactly the "expensive later" shape ADR-0006
      warns about. Marked `inline` (B11): it is called on every reference
      store, and an empty out-of-line call is pure overhead on that hot
      path until a generational upgrade gives it a body. }
    procedure WriteBarrier(const AObj, AValue: TWasmRef); inline;

    { --- roots -------------------------------------------------------- }

    { The store's producers. Called once per collection, before the frame
      walk; nil means "no store", which is what the direct-API tests use. }
    procedure SetRootSource(const AProc: TWasmGcRootProc;
      const AContext: Pointer);

    { Host roots. A handle is an INDEX into a heap-owned array, so the
      array may grow without invalidating anything a host holds, and under
      a non-moving collector RootGet returns the pointer with no read
      barrier — the payoff for not copying.

      CONTRACT HOST-1: a host that stores a TWasmRef in its own structure
      without registering it has a use-after-free, and there is no
      diagnostic. }
    function RootRegister(const ARef: TWasmRef): TWasmRootHandle;
    function RootGet(const AHandle: TWasmRootHandle): TWasmRef;
    procedure RootSet(const AHandle: TWasmRootHandle; const ARef: TWasmRef);
    procedure RootRelease(const AHandle: TWasmRootHandle);
    { Scoped form for the common case — a host function holding references
      across an allocation. A stack discipline, so the common case costs
      one increment. }
    function RootScopeEnter: UInt32;
    procedure RootScopeLeave(const AMark: UInt32);
    function RootCount: Integer;

    { The frame chain (contract GC-1). PushFrame sets Prev itself, so a
      caller only fills Slots, RefRegBits and RegisterCount. }
    procedure PushFrame(const AFrame: PWasmGcFrame);
    procedure PopFrame;
    { Drop the whole chain. The trampoline's obligation after a trap: a
      siglongjmp skips every PopFrame between the fault and the landing
      pad, so the chain must be re-established rather than trusted.

      CONTRACT (H6/B21): the guest-entry wrapper in Wasm.Runtime.Store must
      call Heap.ResetFrames after ANY trap unwind (the trampoline's
      siglongjmp landing), before the next collection. This unit sits below
      the trampoline and cannot wire that call itself; ResetFrames is kept
      correct and tested here so the Store agent can rely on it. After it
      returns, CurrentFrame is nil and a subsequent Collect walks no stale
      frame — the frames skipped by the jump held no managed Pascal state
      (TRAP-1), so dropping the chain leaks nothing. }
    procedure ResetFrames;
    function CurrentFrame: PWasmGcFrame;

    { --- statistics --------------------------------------------------- }
    property BytesLive: UInt64 read FBytesLive;
    property BytesAllocated: UInt64 read FBytesAllocated;
    property BytesReclaimed: UInt64 read FBytesReclaimed;
    property HeapBytes: UInt64 read FHeapBytes;
    property ObjectCount: UInt64 read FObjectCount;
    property CollectionCount: UInt64 read FCollectionCount;
    { The floor the trigger never goes below. Setting it also re-arms the
      current trigger, which is what makes collection deterministic in a
      test: a floor of zero collects at every allocation. }
    property Threshold: UInt64 read FThresholdFloor write SetThreshold;

{$IFNDEF PRODUCTION}
    { Force the next ACount block allocations to report host-allocator
      failure. Test-only (M8): lets a unit test drive the collect-then-retry
      path deterministically without exhausting real memory. }
    procedure InjectBlockFailures(const ACount: Integer);
{$ENDIF}
  end;

{ --- header accessors ----------------------------------------------------

  Free functions rather than heap methods: reading an object's kind or
  type id needs no heap, and Wasm.Runtime.Store's runtime cast surface
  reads them with the engine in hand rather than the heap. Every one
  raises EWasmError for a reference that is not an object — null and
  unboxed i31 have no header, and reaching one here is a caller bug the
  validator was supposed to have made unreachable. }
function GcRefKind(const ARef: TWasmRef): TWasmObjKind;
function GcRefTypeId(const ARef: TWasmRef): TWasmGcTypeId;
function GcRefIsMarked(const ARef: TWasmRef): Boolean;

{ The funcaddr a wokFuncRef handle names. }
function GcFuncRefAddr(const ARef: TWasmRef): UInt32;
function GcHostBoxPayload(const ARef: TWasmRef): NativeUInt;

{ The abstract heap type an object sits under. THREE DISJOINT HIERARCHIES
  fall out of this map — func, aggregate, extern, plus exn — which is the
  property that makes a wokFuncRef answer false for `anyref`.

  KNOWN LIMITATION (M7), tracked for Track E. This map derives the abstract
  hierarchy from the object KIND alone, so a value's hierarchy is fixed at
  allocation. That is wrong for `extern.convert_any` / `any.convert_extern`
  (opcodes 0xFB 0x1B / 0xFB 0x1A, both 3.0). The spec places struct/array/
  i31 in the aggregate (`any`) hierarchy and host values in the `extern`
  hierarchy, but says the two "are interconvertible … both type hierarchies
  are inhabited by an isomorphic set of values, but may have different,
  incompatible representations in practice" (`syntax-heaptype`, a.k.a.
  `type-abstract`; also: `any` "denotes the common supertype of all
  aggregate types, as well as possibly abstract values produced by
  internalizing an external reference of type extern"). Both convert ops
  report `can_trap:false` and are identity on the operand.

  So after `struct.new → extern.convert_any`, `ref.test (ref extern)` MUST
  answer true and `ref.test (ref any)` false — the opposite of what this
  map gives for a `wokStruct`. Expressing that needs the value to record
  which hierarchy it currently inhabits, which the spec's "incompatible
  representations" clause licenses an engine to do with either a wrapper
  object created at the convert site or a toggled header flag. Neither can
  be driven from this unit alone: the convert ops and the ref.test/ref.cast
  surface both live in Wasm.Runtime.Store / the interpreter (Track E), and
  a pure header flag cannot cover an externalized unboxed i31 or null,
  which carry no header. This unit therefore ships the KIND-only map and a
  MARKED, staged test that pins the gap rather than a silently-wrong
  answer; the convert ops are unimplemented, so nothing observes the wrong
  answer yet. Design §1.3's "no-op on representation" note is the claim
  that must be revisited when Track E lands these ops. }
function GcAbsKindOf(const AKind: TWasmObjKind): TWasmAbsHeapType;

implementation

type
  PWasmU8 = ^Byte;
  PWasmU16 = ^Word;
  PWasmU32 = ^UInt32;
  PWasmU64 = ^UInt64;
  PWasmHostRelease = ^TWasmHostRelease;

{ A store is confined to one thread (ADR-0008), so a threadvar bridges the
  heap's collection state to TWasmGcTypes.Define without coupling the two
  classes. Define must never run mid-collection: Layout returns @FLayouts[i]
  and callers hold it across Allocate, which can Collect (B21/L21); a Define
  that reallocated FLayouts during that window would dangle the pointer. }
threadvar
  GWasmGcCollecting: Boolean;

{ --- allocation bitmap --------------------------------------------------- }

{ One bit per cell, set while the cell holds a live object. Spelled once
  here (B13) rather than open-coded at five sites in TakeCell/Sweep/Destroy,
  where a mis-typed shift would be a silent corruption. }
function CellIsAllocated(const ABlock: PWasmGcBlock;
  const ACell: UInt32): Boolean; inline;
begin
  Result := (ABlock^.Allocated[ACell div 32] and
    (UInt32(1) shl (ACell and 31))) <> 0;
end;

procedure SetCellAllocated(const ABlock: PWasmGcBlock;
  const ACell: UInt32); inline;
begin
  ABlock^.Allocated[ACell div 32] := ABlock^.Allocated[ACell div 32] or
    (UInt32(1) shl (ACell and 31));
end;

procedure ClearCellAllocated(const ABlock: PWasmGcBlock;
  const ACell: UInt32); inline;
begin
  ABlock^.Allocated[ACell div 32] := ABlock^.Allocated[ACell div 32] and
    not (UInt32(1) shl (ACell and 31));
end;

{ --- header -------------------------------------------------------------- }

function HeaderOf(const ARef: TWasmRef): PWasmU64; inline;
begin
  if not RefIsObject(ARef) then
    raise EWasmError.Create(
      'internal: a null or i31 reference has no heap object header');
  Result := PWasmU64(RefToPointer(ARef));
end;

function MakeHeader(const AKind: TWasmObjKind;
  const ATypeId: TWasmGcTypeId): UInt64; inline;
begin
  Result := (UInt64(Ord(AKind)) shl WASM_OBJ_KIND_SHIFT) or
    (UInt64(ATypeId) shl WASM_OBJ_TYPE_SHIFT);
end;

function KindOfHeader(const AHeader: UInt64): TWasmObjKind; inline;
begin
  Result := TWasmObjKind((AHeader shr WASM_OBJ_KIND_SHIFT) and
    WASM_OBJ_KIND_MASK);
end;

function TypeIdOfHeader(const AHeader: UInt64): TWasmGcTypeId; inline;
begin
  { One shift, no masking: the id owns the whole high half, which is why
    it was put there. }
  Result := TWasmGcTypeId(AHeader shr WASM_OBJ_TYPE_SHIFT);
end;

function GcRefKind(const ARef: TWasmRef): TWasmObjKind;
begin
  Result := KindOfHeader(HeaderOf(ARef)^);
end;

function GcRefTypeId(const ARef: TWasmRef): TWasmGcTypeId;
begin
  Result := TypeIdOfHeader(HeaderOf(ARef)^);
end;

function GcRefIsMarked(const ARef: TWasmRef): Boolean;
begin
  Result := (HeaderOf(ARef)^ and WASM_OBJ_MARK_BIT) <> 0;
end;

function GcFuncRefAddr(const ARef: TWasmRef): UInt32;
var
  Header: PWasmU64;
begin
  Header := HeaderOf(ARef);
  if KindOfHeader(Header^) <> wokFuncRef then
    raise EWasmError.Create('internal: not a function reference');
  Result := PWasmU32(PByte(Header) + WASM_FUNCREF_ADDR_OFFSET)^;
end;

function GcHostBoxPayload(const ARef: TWasmRef): NativeUInt;
var
  Header: PWasmU64;
begin
  Header := HeaderOf(ARef);
  if KindOfHeader(Header^) <> wokHostBox then
    raise EWasmError.Create('internal: not a host box');
  Result := PNativeUInt(PByte(Header) + WASM_HOSTBOX_PAYLOAD_OFFSET)^;
end;

function GcAbsKindOf(const AKind: TWasmObjKind): TWasmAbsHeapType;
begin
  case AKind of
    wokStruct: Result := wahStruct;
    wokArray: Result := wahArray;
    wokFuncRef: Result := wahFunc;
    wokHostBox: Result := wahExtern;
  else
    Result := wahExn;
  end;
end;

{ --- layout -------------------------------------------------------------- }

function StorageWidth(const AStorage: TWasmStorageType): UInt32;
begin
  if AStorage.IsPacked then
  begin
    if AStorage.PackedType = wpkI8 then
      Result := 1
    else
      Result := 2;
    Exit;
  end;

  case AStorage.ValueType.Kind of
    wvkNum:
      if (AStorage.ValueType.Num = wntI32) or
        (AStorage.ValueType.Num = wntF32) then
        Result := 4
      else
        Result := 8;
    wvkVec:
      Result := 16;
  else
    Result := SizeOf(TWasmRef);
  end;
end;

function DescribeField(const AStorage: TWasmStorageType;
  const AOffset: UInt32): TWasmGcField;
var
  Default: TWasmValue;
begin
  Result.Offset := AOffset;
  Result.Width := StorageWidth(AStorage);
  Result.IsPacked := AStorage.IsPacked;
  Result.PackedKind := AStorage.PackedType;
  Result.IsRef := (not AStorage.IsPacked) and
    (AStorage.ValueType.Kind = wvkRef);
  Result.IsVec := (not AStorage.IsPacked) and
    (AStorage.ValueType.Kind = wvkVec);
  { A packed field's ValueType is not populated — packed types "are NOT
    value types and never appear on the operand stack" — so the default
    question is answered here rather than passed on. }
  Result.HasDefault := AStorage.IsPacked or
    TryDefaultValue(AStorage.ValueType, Default);
end;

function AlignUp(const AOffset, AAlign: UInt32): UInt32; inline;
begin
  Result := (AOffset + (AAlign - 1)) and not (AAlign - 1);
end;

procedure TWasmGcTypes.Grow(const ACount: Integer);
var
  Index: Integer;
begin
  if ACount <= Length(FLayouts) then
    Exit;
  Index := Length(FLayouts);
  SetLength(FLayouts, ACount * 2);
  while Index < Length(FLayouts) do
  begin
    FLayouts[Index].Defined := False;
    Inc(Index);
  end;
end;

procedure TWasmGcTypes.Define(const AId: TWasmGcTypeId;
  const AComp: TWasmCompType);
var
  Layout: PWasmGcLayout;
  Index: Integer;
  Offset: UInt32;
  RefCount: Integer;
begin
  Grow(Integer(AId) + 1);
  if Integer(AId) >= FCount then
    FCount := Integer(AId) + 1;

{$IFNDEF PRODUCTION}
  { A layout pointer from Layout() is held across allocation, which can
    collect; growing FLayouts here mid-collection would dangle it. Define
    runs at intern time, never during a cycle — assert it (B21/L21). }
  if GWasmGcCollecting then
    raise EWasmError.Create(
      'internal: a GC type layout was defined during collection');
{$ENDIF}

  Layout := @FLayouts[AId];
  Layout^.Kind := AComp.Kind;
  Layout^.Fields := nil;
  Layout^.RefFieldOffsets := nil;
  Layout^.RefArgSlots := nil;
  Layout^.Size := WASM_OBJ_HEADER_SIZE;
  { Reset Elem for every kind so a non-array layout does not inherit a
    previous definition's element field — the idempotence Define claims
    (L5/B19). Only wckArray writes it below. }
  FillChar(Layout^.Elem, SizeOf(Layout^.Elem), 0);

  case AComp.Kind of
    wckStruct:
      begin
        SetLength(Layout^.Fields, Length(AComp.Struct.Fields));
        Offset := WASM_OBJ_HEADER_SIZE;
        RefCount := 0;
        for Index := 0 to High(AComp.Struct.Fields) do
        begin
          Offset := AlignUp(Offset,
            StorageWidth(AComp.Struct.Fields[Index].Storage));
          Layout^.Fields[Index] :=
            DescribeField(AComp.Struct.Fields[Index].Storage, Offset);
          Offset := Offset + Layout^.Fields[Index].Width;
          if Layout^.Fields[Index].IsRef then
            Inc(RefCount);
        end;
        { Rounded to 8 so the NEXT object is aligned, which is what
          reserves bit 0 of its pointer for the i31 tag. }
        Layout^.Size := AlignUp(Offset, WASM_GC_ALIGNMENT);

        SetLength(Layout^.RefFieldOffsets, RefCount);
        RefCount := 0;
        for Index := 0 to High(Layout^.Fields) do
          if Layout^.Fields[Index].IsRef then
          begin
            Layout^.RefFieldOffsets[RefCount] := Layout^.Fields[Index].Offset;
            Inc(RefCount);
          end;
      end;

    wckArray:
      { Elements start after the header and the length word; the offset
        recorded here is element ZERO's, and element i is at
        Offset + i * Width. }
      Layout^.Elem := DescribeField(AComp.Arr.Elem.Storage,
        WASM_ARRAY_ELEMS_OFFSET);

    wckFunc:
      begin
        { An exception object's arguments are TWasmValue slots and WHICH
          of them are references is not derivable from the object — it
          comes from the tag's functype params. Cached here for the same
          reason struct field offsets are. }
        RefCount := 0;
        for Index := 0 to High(AComp.Func.Params) do
          if AComp.Func.Params[Index].Kind = wvkRef then
            Inc(RefCount);
        SetLength(Layout^.RefArgSlots, RefCount);
        RefCount := 0;
        for Index := 0 to High(AComp.Func.Params) do
          if AComp.Func.Params[Index].Kind = wvkRef then
          begin
            Layout^.RefArgSlots[RefCount] := UInt32(Index);
            Inc(RefCount);
          end;
      end;
  end;

  Layout^.Defined := True;
end;

function TWasmGcTypes.IsDefined(const AId: TWasmGcTypeId): Boolean;
begin
  Result := (AId < UInt32(Length(FLayouts))) and FLayouts[AId].Defined;
end;

function TWasmGcTypes.Layout(const AId: TWasmGcTypeId): PWasmGcLayout;
begin
  if not IsDefined(AId) then
    raise EWasmError.CreateFmt('internal: engine type %u has no layout',
      [AId]);
  Result := @FLayouts[AId];
end;

function TWasmGcTypes.Count: Integer;
begin
  Result := FCount;
end;

{ --- the heap ------------------------------------------------------------ }

constructor TWasmGcHeap.Create(const ATypes: TWasmGcTypes);
var
  Index: Integer;
begin
  inherited Create;
  if ATypes = nil then
    raise EWasmError.Create('a GC heap needs a layout table');
  FTypes := ATypes;
  for Index := 0 to WASM_GC_CLASS_COUNT - 1 do
  begin
    FFree[Index] := nil;
    FBump[Index] := nil;
  end;
  FThreshold := WASM_GC_DEFAULT_THRESHOLD;
  FThresholdFloor := WASM_GC_DEFAULT_THRESHOLD;
end;

destructor TWasmGcHeap.Destroy;
var
  Index: Integer;
  Block: PWasmGcBlock;
  Cell: UInt32;
begin
  { Every host box still alive at teardown gets its release callback, for
    the same reason a swept one does: it is the embedder's hook to drop
    its own refcount, and a store going away must not leak the host's
    side. }
  for Index := 0 to FBlockCount - 1 do
  begin
    Block := FBlocks[Index];
    Cell := 0;
    while Cell < Block^.Carved do
    begin
      if CellIsAllocated(Block, Cell) then
        ReleaseObject(Block^.Base + Cell * Block^.CellSize);
      Inc(Cell);
    end;
    FreeBlock(Block);
  end;
  FBlocks := nil;
  FBlockCount := 0;

  for Index := 0 to FLargeCount - 1 do
  begin
    ReleaseObject(FLarge[Index]^.Base);
    FreeBlock(FLarge[Index]);
  end;
  FLarge := nil;
  FLargeCount := 0;

  inherited Destroy;
end;

procedure TWasmGcHeap.SetThreshold(const AValue: UInt64);
begin
  FThresholdFloor := AValue;
  FThreshold := AValue;
end;

function TWasmGcHeap.ClassOf(const ASize: UInt32): Integer;
var
  Index: Integer;
begin
  for Index := 0 to WASM_GC_CLASS_COUNT - 1 do
    if ASize <= WASM_GC_SIZE_CLASSES[Index] then
      Exit(Index);
  { Larger than every class: its own block. }
  Result := -1;
end;

function TWasmGcHeap.NewBlock(const AClassIndex: Integer;
  const ACellSize: UInt32; const ACellCount: UInt32;
  const AIsLarge: Boolean): PWasmGcBlock;
var
  Raw: Pointer;
  Bytes: NativeUInt;
  Failed: Boolean;
  Block: PWasmGcBlock;
begin
{$IFNDEF PRODUCTION}
  { Test-only: pretend the host allocator failed, to reach the collect-then-
    retry path (M8) without exhausting real memory. }
  if FInjectBlockFailures > 0 then
  begin
    Dec(FInjectBlockFailures);
    Exit(nil);
  end;
{$ENDIF}

  Bytes := NativeUInt(ACellSize) * NativeUInt(ACellCount) +
    WASM_GC_ALIGNMENT;
  Raw := nil;
  Failed := False;
  try
    Raw := GetMem(Bytes);
  except
    { The RTL heap manager RAISES rather than returning nil, so the nil
      test alone would never fire. }
    on EOutOfMemory do
      Failed := True;
  end;
  { Report failure as nil, NEVER a trap from here (M8): Allocate owns the
    §7.3 policy — collect, retry, then trap — and TrapNow may siglongjmp
    once a tier installs a trampoline, which must not happen mid-allocation
    before the retry. }
  if Failed or (Raw = nil) then
    Exit(nil);

  New(Block);
  Block^.Raw := Raw;
  Block^.Base := PByte((NativeUInt(Raw) + (WASM_GC_ALIGNMENT - 1)) and
    not NativeUInt(WASM_GC_ALIGNMENT - 1));
  Block^.CellSize := ACellSize;
  Block^.CellCount := ACellCount;
  Block^.Carved := 0;
  Block^.Allocated := nil;
  SetLength(Block^.Allocated, (Integer(ACellCount) + 31) div 32);
  Block^.ClassIndex := AClassIndex;
  Block^.IsLarge := AIsLarge;
  FHeapBytes := FHeapBytes + UInt64(Bytes);
  Result := Block;
end;

procedure TWasmGcHeap.FreeBlock(const ABlock: PWasmGcBlock);
begin
  FHeapBytes := FHeapBytes - (UInt64(ABlock^.CellSize) *
    UInt64(ABlock^.CellCount) + WASM_GC_ALIGNMENT);
  FreeMem(ABlock^.Raw);
  ABlock^.Allocated := nil;
  Dispose(ABlock);
end;

function TWasmGcHeap.TakeCell(const ASize: UInt32): PByte;
var
  ClassIndex: Integer;
  CellSize: UInt32;
  Block: PWasmGcBlock;
  Cell: UInt32;
begin
{$IFNDEF PRODUCTION}
  { A host release hook must not allocate: it runs inside Sweep, mid free-
    list rebuild, and re-entering here would corrupt it (B10). Allocate
    skips its collect while FCollecting, so a re-entrant alloc reaches
    TakeCell directly — make that loud rather than silent. }
  if FCollecting then
    raise EWasmError.Create(
      'internal: allocation during collection ' +
      '(a host release hook must not allocate)');
{$ENDIF}

  ClassIndex := ClassOf(ASize);

  if ClassIndex < 0 then
  begin
    { A large object owns its block. Freeing it outright at sweep is what
      keeps a heap that allocated one huge array from holding the memory
      forever. }
    Block := NewBlock(-1, ASize, 1, True);
    if Block = nil then
      Exit(nil);
    if FLargeCount >= Length(FLarge) then
      SetLength(FLarge, (FLargeCount + 1) * 2);
    FLarge[FLargeCount] := Block;
    Inc(FLargeCount);
    Block^.Carved := 1;
    SetCellAllocated(Block, 0);
    Exit(Block^.Base);
  end;

  CellSize := WASM_GC_SIZE_CLASSES[ClassIndex];

  Result := FFree[ClassIndex];
  if Result <> nil then
  begin
    { The free list threads through the first two words of a free cell;
      the per-block bitmap, not the link, is what says a cell is free, so
      overwriting them on allocation loses nothing. }
    FFree[ClassIndex] := PByte(NativeUInt(
      PWasmU64(Result + WASM_GC_FREE_LINK_OFFSET)^));
    Block := PWasmGcBlock(NativeUInt(
      PWasmU64(Result + WASM_GC_FREE_BLOCK_OFFSET)^));
    Cell := UInt32(Result - Block^.Base) div CellSize;
    SetCellAllocated(Block, Cell);
    Exit;
  end;

  Block := FBump[ClassIndex];
  if (Block = nil) or (Block^.Carved >= Block^.CellCount) then
  begin
    Block := NewBlock(ClassIndex, CellSize,
      UInt32(WASM_GC_BLOCK_BYTES) div CellSize, False);
    if Block = nil then
      Exit(nil);
    if FBlockCount >= Length(FBlocks) then
      SetLength(FBlocks, (FBlockCount + 1) * 2);
    FBlocks[FBlockCount] := Block;
    Inc(FBlockCount);
    FBump[ClassIndex] := Block;
  end;

  Cell := Block^.Carved;
  Inc(Block^.Carved);
  SetCellAllocated(Block, Cell);
  Result := Block^.Base + Cell * CellSize;
end;

function TWasmGcHeap.Allocate(const ASize: UInt32;
  const AKind: TWasmObjKind; const ATypeId: TWasmGcTypeId): PByte;
var
  Size: UInt32;
  ClassIndex: Integer;
  CellSize: UInt32;
begin
{$IFNDEF PRODUCTION}
  { Collection never allocates; a re-entrant call here is a host release
    hook breaking its no-alloc contract (B10). }
  if FCollecting then
    raise EWasmError.Create(
      'internal: allocation during collection ' +
      '(a host release hook must not allocate)');
{$ENDIF}

  Size := AlignUp(ASize, WASM_GC_ALIGNMENT);
  if Size < WASM_GC_SIZE_CLASSES[0] then
    Size := WASM_GC_SIZE_CLASSES[0];
  ClassIndex := ClassOf(Size);
  if ClassIndex >= 0 then
    CellSize := WASM_GC_SIZE_CLASSES[ClassIndex]
  else
    CellSize := Size;

  { THE ONLY COLLECTION TRIGGER IN v1. Back-edges and function entries
    remain safepoints and must still produce a stack map (contract GC-2),
    but they do not poll: the collector is stop-the-world and
    single-threaded, so the only reason to collect is that an allocation
    needs memory, and polling anywhere else would be pure cost. }
  if (not FCollecting) and (FBytesLive + UInt64(CellSize) > FThreshold) then
    Collect;

  Result := TakeCell(Size);
  if (Result = nil) and (not FCollecting) then
  begin
    { The host allocator failed. Design §7.3 / M8: collect once and retry
      before trapping — a module that would fit after reclaiming dies
      otherwise (NewBlock used to trap on the spot). The retry reuses
      reclaimed cells first, then grows; only a still-nil result traps. }
    Collect;
    Result := TakeCell(Size);
  end;
  if Result = nil then
    TrapNow(wtkAllocationFailure);

  { A recycled cell holds whatever the last object left; zeroing before
    the header goes down is what stops the next collection tracing it. }
  FillChar(Result^, CellSize, 0);
  { The mark bit is set to the current epoch's live value, so the next
    cycle's polarity flip unmarks this object cleanly along with every
    survivor (H8, design §7.1). }
  PWasmU64(Result)^ := MakeHeader(AKind, ATypeId) or FMarkState;

  FBytesLive := FBytesLive + UInt64(CellSize);
  FBytesAllocated := FBytesAllocated + UInt64(CellSize);
  Inc(FObjectCount);
end;

{ --- allocation ---------------------------------------------------------- }

function TWasmGcHeap.AllocStruct(const ATypeId: TWasmGcTypeId): TWasmRef;
var
  Layout: PWasmGcLayout;
begin
  Layout := FTypes.Layout(ATypeId);
  if Layout^.Kind <> wckStruct then
    raise EWasmError.CreateFmt(
      'internal: engine type %u is not a struct type', [ATypeId]);
  Result := MakeObjectRef(Allocate(Layout^.Size, wokStruct, ATypeId));
end;

function TWasmGcHeap.AllocArray(const ATypeId: TWasmGcTypeId;
  const ALength: UInt32): TWasmRef;
var
  Layout: PWasmGcLayout;
  Bytes: UInt64;
  Cell: PByte;
begin
  Layout := FTypes.Layout(ATypeId);
  if Layout^.Kind <> wckArray then
    raise EWasmError.CreateFmt(
      'internal: engine type %u is not an array type', [ATypeId]);

  { Computed in u64 and compared before narrowing: a length near 2^32 with
    an 8-byte element overflows a 32-bit size and would allocate a small
    object that every later access walks off the end of. }
  Bytes := UInt64(WASM_ARRAY_ELEMS_OFFSET) +
    UInt64(ALength) * UInt64(Layout^.Elem.Width);
  if Bytes > UInt64(High(UInt32) - WASM_GC_ALIGNMENT) then
    TrapNow(wtkAllocationFailure);

  Cell := Allocate(UInt32(Bytes), wokArray, ATypeId);
  PWasmU64(Cell + WASM_ARRAY_LENGTH_OFFSET)^ := UInt64(ALength);
  Result := MakeObjectRef(Cell);
end;

function TWasmGcHeap.AllocFuncRef(const AFuncAddr: UInt32;
  const ATypeId: TWasmGcTypeId): TWasmRef;
var
  Cell: PByte;
begin
  { A funcref value is a POINTER, not a funcaddr, so that reference
    identity and tracing both work uniformly: store.Funcs[a] holds the
    authoritative record and this object is its handle. One per function
    instance, created at instantiation and kept alive by the store's root
    set, which is what makes ref.func return the same pointer every time. }
  Cell := Allocate(WASM_FUNCREF_SIZE, wokFuncRef, ATypeId);
  PWasmU32(Cell + WASM_FUNCREF_ADDR_OFFSET)^ := AFuncAddr;
  Result := MakeObjectRef(Cell);
end;

function TWasmGcHeap.AllocHostBox(const APayload: NativeUInt;
  const ARelease: TWasmHostRelease): TWasmRef;
var
  Cell: PByte;
begin
  { A raw host pointer is not a valid TWasmRef: its low bit may be set and
    the collector can neither trace nor identify it. An externref of a
    host value is a pointer to one of these instead. The header carries the
    NO-TYPE sentinel, not 0 (B14): a host box has no engine type, and a real
    id 0 in the header would collide with the module's engine type 0 if a
    cast surface ever read GcRefTypeId here instead of switching on kind. }
  Cell := Allocate(WASM_HOSTBOX_SIZE, wokHostBox, WASM_GC_NO_TYPE_ID);
  PNativeUInt(Cell + WASM_HOSTBOX_PAYLOAD_OFFSET)^ := APayload;
  PWasmHostRelease(Cell + WASM_HOSTBOX_RELEASE_OFFSET)^ := ARelease;
  Result := MakeObjectRef(Cell);
end;

function TWasmGcHeap.AllocExn(const ATagAddr: UInt32;
  const ATypeId: TWasmGcTypeId; const AArgCount: UInt32): TWasmRef;
var
  Cell: PByte;
  Bytes: UInt64;
  Layout: PWasmGcLayout;
begin
  { The header's type id holds the TAG's functype id, so GcAbsKindOf
    yields wahExn and casts behave. Track H adds the throw path; the
    object is allocatable, traceable and collectable today.

    Validate the id up front (L6), exactly as AllocStruct/AllocArray do. An
    unvalidated bad id would otherwise surface only when Trace reaches
    FTypes.Layout during a collection, turning a caller bug into an
    EWasmError raised INSIDE Collect — which is precisely the mid-cycle
    failure H8 has to unwind. Catch it here, before the object exists. }
  Layout := FTypes.Layout(ATypeId);
  if Layout^.Kind <> wckFunc then
    raise EWasmError.CreateFmt(
      'internal: engine type %u is not a tag (func) type', [ATypeId]);

  Bytes := UInt64(WASM_EXN_ARGS_OFFSET) +
    UInt64(AArgCount) * UInt64(SizeOf(TWasmValue));
  if Bytes > UInt64(High(UInt32) - WASM_GC_ALIGNMENT) then
    TrapNow(wtkAllocationFailure);
  Cell := Allocate(UInt32(Bytes), wokExn, ATypeId);
  PWasmU32(Cell + WASM_EXN_TAG_OFFSET)^ := ATagAddr;
  PWasmU32(Cell + WASM_EXN_ARGC_OFFSET)^ := AArgCount;
  Result := MakeObjectRef(Cell);
end;

{ --- field access -------------------------------------------------------- }

function TWasmGcHeap.LayoutOf(const ARef: TWasmRef): PWasmGcLayout;
begin
  Result := FTypes.Layout(GcRefTypeId(ARef));
end;

function ReadField(const ABase: PByte;
  const AField: TWasmGcField): TWasmValue;
begin
  { Bits is the canonical raw view and every read fills the whole slot,
    which is the same rule Wasm.Runtime.Values imposes on a register: a
    stale high half would be traced as a pointer. }
  Result.Bits := 0;
  if AField.IsRef then
  begin
    Result.Bits := UInt64(PWasmRef(ABase + AField.Offset)^);
    Exit;
  end;
  case AField.Width of
    1: Result.Bits := UInt64(PWasmU8(ABase + AField.Offset)^);
    2: Result.Bits := UInt64(PWasmU16(ABase + AField.Offset)^);
    4: Result.Bits := UInt64(PWasmU32(ABase + AField.Offset)^);
    8: Result.Bits := PWasmU64(ABase + AField.Offset)^;
  else
    raise EWasmError.Create(MSG_GC_VEC_STORAGE_STAGED);
  end;
end;

procedure WriteField(const ABase: PByte; const AField: TWasmGcField;
  const AValue: TWasmValue);
begin
  if AField.IsRef then
  begin
    PWasmRef(ABase + AField.Offset)^ := TWasmRef(AValue.Bits);
    Exit;
  end;
  { A packed store TRUNCATES (`aux-packfield`), which the narrow store
    does by itself. }
  case AField.Width of
    1: PWasmU8(ABase + AField.Offset)^ := Byte(AValue.Bits);
    2: PWasmU16(ABase + AField.Offset)^ := Word(AValue.Bits);
    4: PWasmU32(ABase + AField.Offset)^ := UInt32(AValue.Bits);
    8: PWasmU64(ABase + AField.Offset)^ := AValue.Bits;
  else
    raise EWasmError.Create(MSG_GC_VEC_STORAGE_STAGED);
  end;
end;

function ExtendSigned(const AValue: TWasmValue;
  const AField: TWasmGcField): Int32;
begin
  { `aux-unpackfield` sign-extends from the packed width. Written out
    rather than left to a cast so the i8 and i16 cases are visibly the
    same rule at two widths. }
  if not AField.IsPacked then
    raise EWasmError.Create(
      'internal: get_s on a field that is not packed');
  if AField.PackedKind = wpkI8 then
    Result := Int32(Int8(Byte(AValue.Bits)))
  else
    Result := Int32(Int16(Word(AValue.Bits)));
end;

function TWasmGcHeap.StructField(const ARef: TWasmRef;
  const AField: UInt32): TWasmGcField;
var
  Layout: PWasmGcLayout;
begin
  { O-5: struct.get/get_s/get_u/set on a null ref trap the TYPE-SPECIFIC
    kind (corpus struct.wast:155-156, 'null structure reference'), not the
    bare wtkNullReference the ref.as_non_null path uses. }
  if RefIsNull(ARef) then
    TrapNow(wtkNullStructReference);
  Layout := LayoutOf(ARef);
  if Layout^.Kind <> wckStruct then
    raise EWasmError.Create('internal: not a struct instance');
  if AField >= UInt32(Length(Layout^.Fields)) then
    raise EWasmError.CreateFmt(
      'internal: struct field %u of %u', [AField,
      UInt32(Length(Layout^.Fields))]);
  Result := Layout^.Fields[AField];
end;

function TWasmGcHeap.StructFieldCount(const ARef: TWasmRef): UInt32;
begin
  if RefIsNull(ARef) then
    TrapNow(wtkNullStructReference);
  Result := UInt32(Length(LayoutOf(ARef)^.Fields));
end;

function TWasmGcHeap.StructGet(const ARef: TWasmRef;
  const AField: UInt32): TWasmValue;
var
  Field: TWasmGcField;
begin
  Field := StructField(ARef, AField);
  if Field.IsPacked then
    raise EWasmError.Create(
      'internal: struct.get on a packed field needs get_s or get_u');
  Result := ReadField(PByte(RefToPointer(ARef)), Field);
end;

function TWasmGcHeap.StructGetSigned(const ARef: TWasmRef;
  const AField: UInt32): Int32;
var
  Field: TWasmGcField;
begin
  Field := StructField(ARef, AField);
  Result := ExtendSigned(ReadField(PByte(RefToPointer(ARef)), Field),
    Field);
end;

function TWasmGcHeap.StructGetUnsigned(const ARef: TWasmRef;
  const AField: UInt32): UInt32;
var
  Field: TWasmGcField;
begin
  Field := StructField(ARef, AField);
  if not Field.IsPacked then
    raise EWasmError.Create('internal: get_u on a field that is not packed');
  { Zero extension is what the narrow read already did. }
  Result := UInt32(ReadField(PByte(RefToPointer(ARef)), Field).Bits);
end;

procedure TWasmGcHeap.StructSet(const ARef: TWasmRef; const AField: UInt32;
  const AValue: TWasmValue);
var
  Field: TWasmGcField;
begin
  Field := StructField(ARef, AField);
  WriteField(PByte(RefToPointer(ARef)), Field, AValue);
  if Field.IsRef then
    WriteBarrier(ARef, TWasmRef(AValue.Bits));
end;

procedure TWasmGcHeap.StructSetDefaults(const ARef: TWasmRef);
var
  Layout: PWasmGcLayout;
  Index: Integer;
  Value: TWasmValue;
begin
  if RefIsNull(ARef) then
    TrapNow(wtkNullStructReference);
  Layout := LayoutOf(ARef);
  if Layout^.Kind <> wckStruct then
    raise EWasmError.Create('internal: not a struct instance');
  Value.Bits := 0;
  for Index := 0 to High(Layout^.Fields) do
  begin
    { aux-default is ZERO for every defaultable storage type, so a zeroed
      object already holds it. What this loop adds is the CHECK that a
      default exists at all — the invariant struct.new_default relies on,
      and an internal error rather than a link error if it is missing,
      because the validator should have rejected the module. }
    if not Layout^.Fields[Index].HasDefault then
      raise EWasmError.CreateFmt(MSG_GC_STRUCT_FIELD_NO_DEFAULT, [Index]);
    WriteField(PByte(RefToPointer(ARef)), Layout^.Fields[Index], Value);
  end;
end;

function TWasmGcHeap.ArrayLength(const ARef: TWasmRef): UInt32;
begin
  { O-5: array.get/get_s/get_u/set/len/fill/copy/init_* on a null ref trap
    'null array reference' (corpus array.wast:342-343, array_len.* etc.),
    not the bare wtkNullReference. }
  if RefIsNull(ARef) then
    TrapNow(wtkNullArrayReference);
  Result := UInt32(PWasmU64(PByte(RefToPointer(ARef)) +
    WASM_ARRAY_LENGTH_OFFSET)^);
end;

function TWasmGcHeap.ArrayElement(const ARef: TWasmRef;
  const AIndex: UInt32): TWasmGcField;
var
  Layout: PWasmGcLayout;
begin
  if RefIsNull(ARef) then
    TrapNow(wtkNullArrayReference);
  Layout := LayoutOf(ARef);
  if Layout^.Kind <> wckArray then
    raise EWasmError.Create('internal: not an array instance');
  if AIndex >= ArrayLength(ARef) then
    TrapNow(wtkArrayOutOfBounds);
  Result := Layout^.Elem;
  Result.Offset := Result.Offset + AIndex * Result.Width;
end;

function TWasmGcHeap.ArrayGet(const ARef: TWasmRef;
  const AIndex: UInt32): TWasmValue;
var
  Field: TWasmGcField;
begin
  Field := ArrayElement(ARef, AIndex);
  if Field.IsPacked then
    raise EWasmError.Create(
      'internal: array.get on a packed element needs get_s or get_u');
  Result := ReadField(PByte(RefToPointer(ARef)), Field);
end;

function TWasmGcHeap.ArrayGetSigned(const ARef: TWasmRef;
  const AIndex: UInt32): Int32;
var
  Field: TWasmGcField;
begin
  Field := ArrayElement(ARef, AIndex);
  Result := ExtendSigned(ReadField(PByte(RefToPointer(ARef)), Field),
    Field);
end;

function TWasmGcHeap.ArrayGetUnsigned(const ARef: TWasmRef;
  const AIndex: UInt32): UInt32;
var
  Field: TWasmGcField;
begin
  Field := ArrayElement(ARef, AIndex);
  if not Field.IsPacked then
    raise EWasmError.Create('internal: get_u on an element that is not packed');
  Result := UInt32(ReadField(PByte(RefToPointer(ARef)), Field).Bits);
end;

procedure TWasmGcHeap.ArraySet(const ARef: TWasmRef; const AIndex: UInt32;
  const AValue: TWasmValue);
var
  Field: TWasmGcField;
begin
  Field := ArrayElement(ARef, AIndex);
  WriteField(PByte(RefToPointer(ARef)), Field, AValue);
  if Field.IsRef then
    WriteBarrier(ARef, TWasmRef(AValue.Bits));
end;

procedure TWasmGcHeap.FillRange(const ARef: TWasmRef;
  const AOffset, ACount: UInt32; const AValue: TWasmValue);
var
  Layout: PWasmGcLayout;
  Base: PByte;
  Field: TWasmGcField;
  ElemOffset: UInt32;
  ElemWidth: UInt32;
  Len: UInt32;
  Cursor: UInt32;
begin
  { Layout, element field, length and base are read ONCE and the loop
    stores in place — the fix for B12's Message Chains / quadratic re-fetch
    when array.fill and array.new_default routed each element through
    ArraySet (null check + kind check + bounds + layout, per element). }
  if RefIsNull(ARef) then
    TrapNow(wtkNullArrayReference);
  Layout := LayoutOf(ARef);
  if Layout^.Kind <> wckArray then
    raise EWasmError.Create('internal: not an array instance');
  Base := PByte(RefToPointer(ARef));
  Len := UInt32(PWasmU64(Base + WASM_ARRAY_LENGTH_OFFSET)^);
  { Overflow-safe range test (array.fill traps out of bounds): guard the
    subtraction with AOffset > Len so AOffset + ACount cannot wrap. }
  if (AOffset > Len) or (ACount > Len - AOffset) then
    TrapNow(wtkArrayOutOfBounds);

  Field := Layout^.Elem;
  ElemOffset := Layout^.Elem.Offset;
  ElemWidth := Layout^.Elem.Width;
  Cursor := 0;
  while Cursor < ACount do
  begin
    Field.Offset := ElemOffset + (AOffset + Cursor) * ElemWidth;
    WriteField(Base, Field, AValue);
    Inc(Cursor);
  end;
  { One barrier for the whole fill rather than one per element — the value
    stored is the same, so it names the same referent (L9-style guard). }
  if Field.IsRef then
    WriteBarrier(ARef, TWasmRef(AValue.Bits));
end;

procedure TWasmGcHeap.ArrayFill(const ARef: TWasmRef;
  const AValue: TWasmValue);
begin
  { ArrayLength traps on a null reference, matching the ranged form. }
  FillRange(ARef, 0, ArrayLength(ARef), AValue);
end;

procedure TWasmGcHeap.ArrayFill(const ARef: TWasmRef;
  const AOffset, ACount: UInt32; const AValue: TWasmValue);
begin
  FillRange(ARef, AOffset, ACount, AValue);
end;

procedure TWasmGcHeap.ArraySetDefaults(const ARef: TWasmRef);
var
  Layout: PWasmGcLayout;
  Value: TWasmValue;
begin
  if RefIsNull(ARef) then
    TrapNow(wtkNullArrayReference);
  Layout := LayoutOf(ARef);
  if Layout^.Kind <> wckArray then
    raise EWasmError.Create('internal: not an array instance');
  { A zeroed object already holds aux-default's value for every
    defaultable storage type; what this adds is the CHECK that one exists,
    which is the invariant array.new_default relies on. }
  if not Layout^.Elem.HasDefault then
    raise EWasmError.Create(MSG_GC_ARRAY_ELEM_NO_DEFAULT);
  Value.Bits := 0;
  FillRange(ARef, 0, ArrayLength(ARef), Value);
end;

procedure TWasmGcHeap.ArrayCopy(const ADest: TWasmRef;
  const ADestIdx: UInt32; const ASrc: TWasmRef; const ASrcIdx: UInt32;
  const ACount: UInt32);
var
  DestLayout: PWasmGcLayout;
  SrcLayout: PWasmGcLayout;
  DestBase: PByte;
  SrcBase: PByte;
  DestLen: UInt32;
  SrcLen: UInt32;
  DestField: TWasmGcField;
  SrcField: TWasmGcField;
  Value: TWasmValue;
  Cursor: UInt32;
  Slot: UInt32;
  Backward: Boolean;
begin
  { exec-array.copy. Null on EITHER side traps 'null array reference' (both
    corpus lines spell the same message), checked before the ranges. }
  if RefIsNull(ADest) then
    TrapNow(wtkNullArrayReference);
  if RefIsNull(ASrc) then
    TrapNow(wtkNullArrayReference);
  DestLayout := LayoutOf(ADest);
  if DestLayout^.Kind <> wckArray then
    raise EWasmError.Create(
      'internal: array.copy destination is not an array');
  SrcLayout := LayoutOf(ASrc);
  if SrcLayout^.Kind <> wckArray then
    raise EWasmError.Create('internal: array.copy source is not an array');

  DestBase := PByte(RefToPointer(ADest));
  SrcBase := PByte(RefToPointer(ASrc));
  DestLen := UInt32(PWasmU64(DestBase + WASM_ARRAY_LENGTH_OFFSET)^);
  SrcLen := UInt32(PWasmU64(SrcBase + WASM_ARRAY_LENGTH_OFFSET)^);

  { Both ranges 'out of bounds array access'; overflow-safe subtracting
    form so a large index cannot wrap into range. Dest range then source
    range — either spells the same message. }
  if (ADestIdx > DestLen) or (ACount > DestLen - ADestIdx) then
    TrapNow(wtkArrayOutOfBounds);
  if (ASrcIdx > SrcLen) or (ACount > SrcLen - ASrcIdx) then
    TrapNow(wtkArrayOutOfBounds);

  { Layout read ONCE for each side; the element field widths match by
    validation (element-type compatibility). }
  DestField := DestLayout^.Elem;
  SrcField := SrcLayout^.Elem;

  { memmove semantics: only the SAME array can overlap, and a forward copy
    then clobbers not-yet-read source elements when the destination is
    higher, so copy backward in exactly that case. }
  Backward := (DestBase = SrcBase) and (ADestIdx > ASrcIdx);

  Cursor := 0;
  while Cursor < ACount do
  begin
    if Backward then
      Slot := ACount - 1 - Cursor
    else
      Slot := Cursor;
    SrcField.Offset := SrcLayout^.Elem.Offset +
      (ASrcIdx + Slot) * SrcLayout^.Elem.Width;
    DestField.Offset := DestLayout^.Elem.Offset +
      (ADestIdx + Slot) * DestLayout^.Elem.Width;
    Value := ReadField(SrcBase, SrcField);
    WriteField(DestBase, DestField, Value);
    { Barriered per reference element (empty in v1; the site is the point). }
    if DestField.IsRef then
      WriteBarrier(ADest, TWasmRef(Value.Bits));
    Inc(Cursor);
  end;
end;

procedure TWasmGcHeap.ArrayInitFromData(const ADest: TWasmRef;
  const ADestIdx: UInt32; const ADataBytes: PByte; const ADataSize: NativeUInt;
  const ADataByteOffset: UInt64; const ACount: UInt32);
var
  Layout: PWasmGcLayout;
  Base: PByte;
  DestLen: UInt32;
  ElemOffset: UInt32;
  ElemWidth: UInt32;
  SrcEnd: UInt64;
  Cursor: UInt32;
  Src: PByte;
  Dst: PByte;
begin
  { exec-array.init_data. Null, then the DEST (array) range, then the DATA
    (memory) range — the spec checks the array bound before the data bound. }
  if RefIsNull(ADest) then
    TrapNow(wtkNullArrayReference);
  Layout := LayoutOf(ADest);
  if Layout^.Kind <> wckArray then
    raise EWasmError.Create(
      'internal: array.init_data target is not an array');
  { array.init_data's element type is numeric or packed, never a reference
    (the validator guarantees it), so no write barrier is owed. }
  if Layout^.Elem.IsRef then
    raise EWasmError.Create(
      'internal: array.init_data on a reference-element array');

  Base := PByte(RefToPointer(ADest));
  DestLen := UInt32(PWasmU64(Base + WASM_ARRAY_LENGTH_OFFSET)^);
  if (ADestIdx > DestLen) or (ACount > DestLen - ADestIdx) then
    TrapNow(wtkArrayOutOfBounds);

  ElemOffset := Layout^.Elem.Offset;
  ElemWidth := Layout^.Elem.Width;
  { A v128 element is a valid TYPE whose storage is staged (Track G),
    exactly as ReadField/WriteField treat width 16. }
  if (ElemWidth <> 1) and (ElemWidth <> 2) and (ElemWidth <> 4) and
    (ElemWidth <> 8) then
    raise EWasmError.Create(MSG_GC_VEC_STORAGE_STAGED);

  { Byte bound on the data side, in u64 so offset+count cannot wrap. The
    DATA side is a memory-style bound: 'out of bounds memory access'
    (corpus array_init_data.wast:72). }
  SrcEnd := ADataByteOffset + UInt64(ACount) * UInt64(ElemWidth);
  if SrcEnd > UInt64(ADataSize) then
    TrapNow(wtkMemoryOutOfBounds);

  { A width-sized little-endian byte copy per element: the data segment
    image and packed/numeric element storage are both LE byte arrays, so
    Move reproduces the typed load+store WriteField would perform, and
    honours the packed element width. }
  Cursor := 0;
  while Cursor < ACount do
  begin
    Src := ADataBytes + NativeUInt(ADataByteOffset) +
      NativeUInt(Cursor) * NativeUInt(ElemWidth);
    Dst := Base + ElemOffset + (ADestIdx + Cursor) * ElemWidth;
    Move(Src^, Dst^, ElemWidth);
    Inc(Cursor);
  end;
end;

procedure TWasmGcHeap.ArrayInitFromElem(const ADest: TWasmRef;
  const ADestIdx: UInt32; const ASrc: array of TWasmRef;
  const ASrcOffset: UInt32; const ACount: UInt32);
var
  Layout: PWasmGcLayout;
  Base: PByte;
  DestLen: UInt32;
  SrcLen: UInt32;
  ElemOffset: UInt32;
  ElemWidth: UInt32;
  Cursor: UInt32;
  Ref: TWasmRef;
begin
  { exec-array.init_elem. Null, then the DEST (array) range, then the ELEM
    (table-shaped) source range. }
  if RefIsNull(ADest) then
    TrapNow(wtkNullArrayReference);
  Layout := LayoutOf(ADest);
  if Layout^.Kind <> wckArray then
    raise EWasmError.Create(
      'internal: array.init_elem target is not an array');
  if not Layout^.Elem.IsRef then
    raise EWasmError.Create(
      'internal: array.init_elem on a non-reference-element array');

  Base := PByte(RefToPointer(ADest));
  DestLen := UInt32(PWasmU64(Base + WASM_ARRAY_LENGTH_OFFSET)^);
  if (ADestIdx > DestLen) or (ACount > DestLen - ADestIdx) then
    TrapNow(wtkArrayOutOfBounds);

  { The source is the element segment's references; a range past its length
    traps 'out of bounds table access' (corpus array_init_elem.wast:89). A
    dropped segment reads as empty (Length 0). }
  SrcLen := UInt32(Length(ASrc));
  if (ASrcOffset > SrcLen) or (ACount > SrcLen - ASrcOffset) then
    TrapNow(wtkTableOutOfBounds);

  ElemOffset := Layout^.Elem.Offset;
  ElemWidth := Layout^.Elem.Width;
  Cursor := 0;
  while Cursor < ACount do
  begin
    Ref := ASrc[ASrcOffset + Cursor];
    PWasmRef(Base + ElemOffset + (ADestIdx + Cursor) * ElemWidth)^ := Ref;
    { Barriered per reference element. }
    WriteBarrier(ADest, Ref);
    Inc(Cursor);
  end;
end;

function TWasmGcHeap.ExnTagAddr(const ARef: TWasmRef): UInt32;
begin
  if RefIsNull(ARef) then
    TrapNow(wtkNullReference);
  Result := PWasmU32(PByte(RefToPointer(ARef)) + WASM_EXN_TAG_OFFSET)^;
end;

function TWasmGcHeap.ExnArgCount(const ARef: TWasmRef): UInt32;
begin
  if RefIsNull(ARef) then
    TrapNow(wtkNullReference);
  Result := PWasmU32(PByte(RefToPointer(ARef)) + WASM_EXN_ARGC_OFFSET)^;
end;

function TWasmGcHeap.ExnArg(const ARef: TWasmRef;
  const AIndex: UInt32): TWasmValue;
begin
  if AIndex >= ExnArgCount(ARef) then
    raise EWasmError.CreateFmt('internal: exception argument %u of %u',
      [AIndex, ExnArgCount(ARef)]);
  Result := PWasmValue(PByte(RefToPointer(ARef)) + WASM_EXN_ARGS_OFFSET +
    AIndex * SizeOf(TWasmValue))^;
end;

procedure TWasmGcHeap.ExnSetArg(const ARef: TWasmRef; const AIndex: UInt32;
  const AValue: TWasmValue);
var
  Layout: PWasmGcLayout;
  Index: Integer;
  IsRefArg: Boolean;
begin
  if AIndex >= ExnArgCount(ARef) then
    raise EWasmError.CreateFmt('internal: exception argument %u of %u',
      [AIndex, ExnArgCount(ARef)]);
  PWasmValue(PByte(RefToPointer(ARef)) + WASM_EXN_ARGS_OFFSET +
    AIndex * SizeOf(TWasmValue))^ := AValue;
  { Guard the barrier on whether this argument slot is a reference (L9),
    for consistency with StructSet/ArraySet — which of an exn's args are
    references comes from the tag functype's params (RefArgSlots), not from
    the value. }
  Layout := LayoutOf(ARef);
  IsRefArg := False;
  for Index := 0 to High(Layout^.RefArgSlots) do
    if Layout^.RefArgSlots[Index] = AIndex then
    begin
      IsRefArg := True;
      Break;
    end;
  if IsRefArg then
    WriteBarrier(ARef, TWasmRef(AValue.Bits));
end;

{ --- roots --------------------------------------------------------------- }

procedure TWasmGcHeap.SetRootSource(const AProc: TWasmGcRootProc;
  const AContext: Pointer);
begin
  FRootProc := AProc;
  FRootContext := AContext;
end;

function TWasmGcHeap.RootRegister(const ARef: TWasmRef): TWasmRootHandle;
begin
  if FRootFreeCount > 0 then
  begin
    Dec(FRootFreeCount);
    Result := FRootFree[FRootFreeCount];
    FRoots[Result] := ARef;
    Exit;
  end;
  if FRootCount >= Length(FRoots) then
    SetLength(FRoots, (FRootCount + 1) * 2);
  Result := TWasmRootHandle(FRootCount);
  FRoots[FRootCount] := ARef;
  Inc(FRootCount);
end;

function TWasmGcHeap.RootGet(const AHandle: TWasmRootHandle): TWasmRef;
begin
  if AHandle >= UInt32(FRootCount) then
    raise EWasmError.CreateFmt('internal: no root handle %u', [AHandle]);
  { No read barrier and no indirection: the collector never moves an
    object, which is the whole reason it is mark-sweep. }
  Result := FRoots[AHandle];
end;

procedure TWasmGcHeap.RootSet(const AHandle: TWasmRootHandle;
  const ARef: TWasmRef);
begin
  if AHandle >= UInt32(FRootCount) then
    raise EWasmError.CreateFmt('internal: no root handle %u', [AHandle]);
  FRoots[AHandle] := ARef;
end;

procedure TWasmGcHeap.RootRelease(const AHandle: TWasmRootHandle);
begin
  if AHandle >= UInt32(FRootCount) then
    raise EWasmError.CreateFmt('internal: no root handle %u', [AHandle]);
  FRoots[AHandle] := WASM_REF_NULL;
  if AHandle = UInt32(FRootCount - 1) then
  begin
    { Releasing the top is a pop, which is what keeps the common
      register/release pair from growing the array. }
    Dec(FRootCount);
    Exit;
  end;
  if FRootFreeCount >= Length(FRootFree) then
    SetLength(FRootFree, (FRootFreeCount + 1) * 2);
  FRootFree[FRootFreeCount] := AHandle;
  Inc(FRootFreeCount);
end;

function TWasmGcHeap.RootScopeEnter: UInt32;
begin
  Result := UInt32(FRootCount);
end;

procedure TWasmGcHeap.RootScopeLeave(const AMark: UInt32);
var
  Read: Integer;
  Write: Integer;
begin
  if AMark > UInt32(FRootCount) then
    raise EWasmError.Create('internal: root scope mark is above the stack');
  FRootCount := Integer(AMark);
  { Free-list entries above the mark name slots that no longer exist;
    dropping them is what keeps the stack discipline and the free list
    from disagreeing. }
  Write := 0;
  for Read := 0 to FRootFreeCount - 1 do
    if FRootFree[Read] < AMark then
    begin
      FRootFree[Write] := FRootFree[Read];
      Inc(Write);
    end;
  FRootFreeCount := Write;
end;

function TWasmGcHeap.RootCount: Integer;
begin
  Result := FRootCount;
end;

procedure TWasmGcHeap.PushFrame(const AFrame: PWasmGcFrame);
begin
  AFrame^.Prev := FFrames;
  FFrames := AFrame;
end;

procedure TWasmGcHeap.PopFrame;
begin
  if FFrames = nil then
    raise EWasmError.Create('internal: popping an empty frame chain');
  FFrames := FFrames^.Prev;
end;

procedure TWasmGcHeap.ResetFrames;
begin
  FFrames := nil;
end;

function TWasmGcHeap.CurrentFrame: PWasmGcFrame;
begin
  Result := FFrames;
end;

{ --- marking ------------------------------------------------------------- }

procedure TWasmGcHeap.WriteBarrier(const AObj, AValue: TWasmRef); inline;
begin
  { EMPTY IN v1, ON PURPOSE. See the declaration. }
end;

procedure TWasmGcHeap.Push(const ARef: TWasmRef);
begin
  if FMarkCount >= Length(FMarkStack) then
    SetLength(FMarkStack, (FMarkCount + 1) * 2);
  FMarkStack[FMarkCount] := ARef;
  Inc(FMarkCount);
end;

procedure TWasmGcHeap.MarkRoot(const ARef: TWasmRef);
var
  Header: PWasmU64;
begin
  { Null and unboxed i31 are skipped BY ENCODING — one test, no header
    read, no allocation to trace. That is what the tag bit buys. }
  if not RefIsObject(ARef) then
    Exit;
  Header := PWasmU64(RefToPointer(ARef));
  { "Reached this cycle" is mark bit == FMarkState, not == 1 (H8): the
    epoch's live value flips each cycle. Already at FMarkState → seen. }
  if (Header^ and WASM_OBJ_MARK_BIT) = FMarkState then
    Exit;
  Header^ := (Header^ and not WASM_OBJ_MARK_BIT) or FMarkState;
  Push(ARef);
end;

procedure TWasmGcHeap.MarkRoots;
var
  Index: Integer;
begin
  for Index := 0 to FRootCount - 1 do
    MarkRoot(FRoots[Index]);
  if Assigned(FRootProc) then
    FRootProc(Self, FRootContext);
end;

procedure TWasmGcHeap.MarkFrames;
var
  Frame: PWasmGcFrame;
  WordIndex: UInt32;
  WordCount: UInt32;
  Word_: UInt32;
  Reg: UInt32;
begin
  { Contract GC-1's walk, and the whole of it: follow Prev, and for each
    frame iterate the set bits of RefRegBits over [0, RegisterCount)
    treating Slots[i].Ref as a root. An unzeroed slot is indistinguishable
    from a live reference, which is why zeroing at entry is obligation 1
    on every tier rather than a suggestion.

    The ref-bit word is loaded ONCE per 32 registers and its set bits are
    consumed lowest-first with W and (W - 1) (B17), so a numeric function's
    all-zero words cost one load and no per-register work. }
  Frame := FFrames;
  while Frame <> nil do
  begin
    if (Frame^.Slots <> nil) and (Frame^.RefRegBits <> nil) and
      (Frame^.RegisterCount > 0) then
    begin
      WordCount := (Frame^.RegisterCount + 31) div 32;
      WordIndex := 0;
      while WordIndex < WordCount do
      begin
        Word_ := PWasmGcRefBits(PByte(Frame^.RefRegBits) +
          WordIndex * SizeOf(UInt32))^;
        while Word_ <> 0 do
        begin
          Reg := WordIndex * 32 + UInt32(BsfDWord(Word_));
          { Bits beyond RegisterCount in the final word must read zero (the
            tier zeroes the frame), but guard anyway — a spurious high bit
            would otherwise index past the register file. }
          if Reg < Frame^.RegisterCount then
            MarkRoot(PWasmValue(PByte(Frame^.Slots) +
              NativeUInt(Reg) * SizeOf(TWasmValue))^.Ref);
          Word_ := Word_ and (Word_ - 1);
        end;
        Inc(WordIndex);
      end;
    end;
    Frame := Frame^.Prev;
  end;
end;

procedure TWasmGcHeap.Trace(const ARef: TWasmRef);
var
  Base: PByte;
  Layout: PWasmGcLayout;
  Index: Integer;
  Count: UInt32;
  Cursor: UInt32;
  Offset: UInt32;
begin
  Base := PByte(RefToPointer(ARef));
  case KindOfHeader(PWasmU64(Base)^) of
    wokStruct:
      begin
        { A loop over the small cached array of reference field offsets —
          no per-object map, and nothing read from the object except the
          references themselves. }
        Layout := FTypes.Layout(TypeIdOfHeader(PWasmU64(Base)^));
        for Index := 0 to High(Layout^.RefFieldOffsets) do
          MarkRoot(PWasmRef(Base + Layout^.RefFieldOffsets[Index])^);
      end;

    wokArray:
      begin
        Layout := FTypes.Layout(TypeIdOfHeader(PWasmU64(Base)^));
        if not Layout^.Elem.IsRef then
          Exit;
        Count := UInt32(PWasmU64(Base + WASM_ARRAY_LENGTH_OFFSET)^);
        Cursor := 0;
        while Cursor < Count do
        begin
          Offset := Layout^.Elem.Offset + Cursor * Layout^.Elem.Width;
          MarkRoot(PWasmRef(Base + Offset)^);
          Inc(Cursor);
        end;
      end;

    wokExn:
      begin
        { Which arguments are references comes from the TAG'S functype,
          not from the object. }
        Layout := FTypes.Layout(TypeIdOfHeader(PWasmU64(Base)^));
        Count := PWasmU32(Base + WASM_EXN_ARGC_OFFSET)^;
        for Index := 0 to High(Layout^.RefArgSlots) do
          if Layout^.RefArgSlots[Index] < Count then
            MarkRoot(PWasmValue(Base + WASM_EXN_ARGS_OFFSET +
              Layout^.RefArgSlots[Index] * SizeOf(TWasmValue))^.Ref);
      end;
  end;
  { wokFuncRef holds a funcaddr and wokHostBox an opaque payload; neither
    contains a reference, so neither is traced. }
end;

procedure TWasmGcHeap.Drain;
var
  Ref: TWasmRef;
begin
  { AN EXPLICIT MARK STACK, NEVER RECURSION. A guest object graph is
    attacker-shaped: a linked list of a million nodes is one struct.new in
    a loop, and a recursive trace would overflow the Pascal stack long
    before the heap filled. The design contract is silent on this and the
    choice is recorded here. }
  while FMarkCount > 0 do
  begin
    Dec(FMarkCount);
    Ref := FMarkStack[FMarkCount];
    Trace(Ref);
  end;
end;

{ --- sweeping ------------------------------------------------------------ }

procedure TWasmGcHeap.ReleaseObject(const ACell: PByte);
var
  Release: TWasmHostRelease;
begin
  { The one call OUT of the collector, and it is not a finalizer: 3.0 has
    neither finalization nor weak references (verified against the pin),
    and this is the embedder's hook to drop its own refcount for a host
    value whose box is gone. A release callback must not allocate. }
  if KindOfHeader(PWasmU64(ACell)^) <> wokHostBox then
    Exit;
  Release := PWasmHostRelease(ACell + WASM_HOSTBOX_RELEASE_OFFSET)^;
  if Assigned(Release) then
    Release(PNativeUInt(ACell + WASM_HOSTBOX_PAYLOAD_OFFSET)^);
end;

procedure TWasmGcHeap.Sweep;
var
  Index: Integer;
  Live: Integer;
  Block: PWasmGcBlock;
  Cell: UInt32;
  Base: PByte;
  Header: PWasmU64;
begin
  { The free lists are REBUILT from the allocation bitmaps rather than
    maintained across a cycle: a cell that is free is exactly a carved
    cell whose bit is clear, and deriving the lists from that one fact
    removes any chance of a cell appearing on a list twice.

    A cell is LIVE iff its mark bit equals FMarkState (this cycle's live
    value). Survivors are left untouched — no clear pass — because the
    next cycle flips FMarkState, which unmarks every survivor at once
    (H8, design §7.1). }
  for Index := 0 to WASM_GC_CLASS_COUNT - 1 do
    FFree[Index] := nil;

  for Index := 0 to FBlockCount - 1 do
  begin
    Block := FBlocks[Index];
    Cell := Block^.Carved;
    { Backwards, so the rebuilt free list hands out low addresses first —
      which makes the reuse test deterministic and keeps a mostly-empty
      heap clustered at the front of each block. }
    while Cell > 0 do
    begin
      Dec(Cell);
      Base := Block^.Base + Cell * Block^.CellSize;
      if CellIsAllocated(Block, Cell) then
      begin
        Header := PWasmU64(Base);
        if (Header^ and WASM_OBJ_MARK_BIT) = FMarkState then
          { Survived: leave the mark as-is; the next flip unmarks it. }
          Continue;
        ReleaseObject(Base);
        ClearCellAllocated(Block, Cell);
        FBytesLive := FBytesLive - UInt64(Block^.CellSize);
        FBytesReclaimed := FBytesReclaimed + UInt64(Block^.CellSize);
        Dec(FObjectCount);
        {$IFNDEF PRODUCTION}
        { Poisoned whole, THEN relinked, so every byte a live object could
          have held is overwritten. Under mark-sweep a missed root frees
          an object that is still THERE; poison is what turns a plausible
          read into a loud one. }
        FillChar(Base^, Block^.CellSize, WASM_GC_POISON);
        {$ENDIF}
      end;
      { Free, whether just now or from an earlier cycle: onto the list. }
      PWasmU64(Base + WASM_GC_FREE_LINK_OFFSET)^ :=
        UInt64(NativeUInt(FFree[Block^.ClassIndex]));
      PWasmU64(Base + WASM_GC_FREE_BLOCK_OFFSET)^ := UInt64(NativeUInt(Block));
      FFree[Block^.ClassIndex] := Base;
    end;
  end;

  { Large objects are freed outright — a heap that allocated one huge
    array must not hold its pages until teardown. }
  Live := 0;
  for Index := 0 to FLargeCount - 1 do
  begin
    Block := FLarge[Index];
    Header := PWasmU64(Block^.Base);
    if (Header^ and WASM_OBJ_MARK_BIT) = FMarkState then
    begin
      { Survived: compacted forward in FLarge, mark left for the flip. }
      FLarge[Live] := Block;
      Inc(Live);
      Continue;
    end;
    ReleaseObject(Block^.Base);
    FBytesLive := FBytesLive - UInt64(Block^.CellSize);
    FBytesReclaimed := FBytesReclaimed + UInt64(Block^.CellSize);
    Dec(FObjectCount);
    {$IFNDEF PRODUCTION}
    { Poison the object before returning its pages (L7): a large object is
      FreeMem'd outright, so a stale TWasmRef into it must read loud, the
      same use-after-free property the cell poison gives small objects. }
    FillChar(Block^.Base^, Block^.CellSize, WASM_GC_POISON);
    {$ENDIF}
    FreeBlock(Block);
  end;
  FLargeCount := Live;
end;

procedure TWasmGcHeap.ClearAllMarks;
var
  Index: Integer;
  Block: PWasmGcBlock;
  Cell: UInt32;
  Base: PByte;
begin
  { Reset every live object's mark bit to 0 and the epoch to 0, so the
    population is uniform again after an aborted cycle (H8). Walks the
    allocation bitmaps, never the free lists: a freed cell's header words
    are poison / free-list links and must not be disturbed. }
  for Index := 0 to FBlockCount - 1 do
  begin
    Block := FBlocks[Index];
    Cell := 0;
    while Cell < Block^.Carved do
    begin
      if CellIsAllocated(Block, Cell) then
      begin
        Base := Block^.Base + Cell * Block^.CellSize;
        PWasmU64(Base)^ := PWasmU64(Base)^ and not WASM_OBJ_MARK_BIT;
      end;
      Inc(Cell);
    end;
  end;
  for Index := 0 to FLargeCount - 1 do
    PWasmU64(FLarge[Index]^.Base)^ :=
      PWasmU64(FLarge[Index]^.Base)^ and not WASM_OBJ_MARK_BIT;
  FMarkState := 0;
end;

procedure TWasmGcHeap.Collect;
var
  Completed: Boolean;
begin
  { Stop-the-world and single-threaded: ADR-0008 removes concurrent
    marking, cross-thread write barriers and safepoint coordination, so
    the whole cycle is three straight-line phases. }
  if FCollecting then
    Exit;
  FCollecting := True;
  GWasmGcCollecting := True;
  Completed := False;
  try
    FMarkCount := 0;
    { Flip the epoch's live value BEFORE marking (design §7.1): every
      existing object carries the OLD FMarkState, so the flip makes them
      all read as unmarked at once, and a completed sweep needs no clear
      pass — survivors keep the new value, garbage keeps the old. }
    FMarkState := FMarkState xor WASM_OBJ_MARK_BIT;
    MarkRoots;
    MarkFrames;
    Drain;
    Sweep;
    Inc(FCollectionCount);
    { Re-arm at a multiple of what survived, never below the floor. A floor
      of zero forces a collection at EVERY allocation, even once objects
      survive (L8): the retarget holds the threshold at zero rather than
      letting FBytesLive * GROWTH raise it, so FBytesLive + CellSize > 0
      stays true. That is how a test makes the trigger deterministic. }
    if FThresholdFloor = 0 then
      FThreshold := 0
    else
    begin
      FThreshold := FBytesLive * WASM_GC_GROWTH_FACTOR;
      if FThreshold < FThresholdFloor then
        FThreshold := FThresholdFloor;
    end;
    Completed := True;
  finally
    { Abort safety (H8). MarkRoots (the embedder root proc), MarkFrames, or
      Drain (FTypes.Layout on an unvalidated id) can raise past the flip and
      past marking some objects — a mixed, half-marked population. Left
      alone, the next cycle would early-out on those stale marks and sweep
      still-reachable objects. Normalise the whole heap back to a uniform
      unmarked state before releasing the collecting flag. }
    if not Completed then
      ClearAllMarks;
    GWasmGcCollecting := False;
    FCollecting := False;
  end;
end;

{$IFNDEF PRODUCTION}
procedure TWasmGcHeap.InjectBlockFailures(const ACount: Integer);
begin
  FInjectBlockFailures := ACount;
end;
{$ENDIF}

end.
