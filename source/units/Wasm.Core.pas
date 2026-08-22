{ Wasm.Core — project identity, the WebAssembly value/section vocabulary,
  and the error hierarchy every other unit raises through.

  This is the bottom of the layering (docs/architecture.md): it depends on
  nothing in the project and names the concepts the decoder, the validator,
  the execution tiers, and the embedding API all share. Anything that needs
  a module, a store, or an execution tier belongs above it. }
unit Wasm.Core;

{$I Shared.inc}

interface

uses
  SysUtils;

const
  PROGRAM_NAME = 'wasmlight';

  { PROGRAM_VERSION — stamped from [package].version in lwpt.toml by the
    `stamp-version` prebuild hook. Never hand-edit Version.inc. }
  {$I Version.inc}

  { The four bytes every WebAssembly module starts with: '\0asm'. }
  WASM_MAGIC: array[0..3] of Byte = ($00, $61, $73, $6D);

  { The only binary-format version wasmlight decodes. The component
    binary format reuses the preamble with a different version/layer
    pair — see Wasm.Component once that lands (ADR-0002). }
  WASM_BINARY_VERSION = 1;

type
  { Numeric, vector, and reference types as they appear in the binary
    format.

    Two things about the encoding drive this shape, and both are easy to
    get wrong:

    1. Type codes are SIGNED LEB128 small negatives, not raw bytes. The
       spec chose that deliberately so type codes can share an encoding
       space with (positive) type indices — which they do, in block types
       and in heap types. Reading a type code as a byte works right up
       until a long-form reference type or a block type appears, so the
       decoding surface here takes an Int64 that the caller read as an
       sLEB128.
    2. A reference type is not a code at all. It is `REF NULL? ht` — a
       nullability flag plus a heap type, where the heap type is itself
       either an abstract code or a type index. The single-byte forms are
       a SHORT FORM for the nullable case, not the whole story.

    https://webassembly.github.io/spec/core/binary/types.html }

  { Abstract heap types, by their (negative) type code. Concrete heap
    types are type indices and are not in this enum. }
  TWasmAbsHeapType = (
    wahExn      = -23,   { $69 }
    wahArray    = -22,   { $6A }
    wahStruct   = -21,   { $6B }
    wahI31      = -20,   { $6C }
    wahEq       = -19,   { $6D }
    wahAny      = -18,   { $6E }
    wahExtern   = -17,   { $6F }
    wahFunc     = -16,   { $70 }
    wahNone     = -15,   { $71 }
    wahNoExtern = -14,   { $72 }
    wahNoFunc   = -13,   { $73 }
    wahNoExn    = -12    { $74 }
  );

  TWasmNumType = (
    wntF64 = -4,   { $7C }
    wntF32 = -3,   { $7D }
    wntI64 = -2,   { $7E }
    wntI32 = -1    { $7F }
  );

  { A heap type is either one of the abstract codes above or a concrete
    type index into the type section. }
  TWasmHeapType = record
    IsAbstract: Boolean;
    Abs: TWasmAbsHeapType;
    TypeIndex: UInt32;

    function Describe: string;
  end;

  TWasmRefType = record
    Nullable: Boolean;
    Heap: TWasmHeapType;

    function Describe: string;
  end;

  TWasmValueKind = (wvkNum, wvkVec, wvkRef);

  { The one vector type, v128 ($7B / -5), needs no enum of its own — a
    kind of wvkVec says everything there is to say. }
  TWasmValueType = record
    Kind: TWasmValueKind;
    Num: TWasmNumType;
    Ref: TWasmRefType;

    function Describe: string;
  end;

  { The runtime representation of a v128 value — the SHARED shape both the
    interpreter's register file and the GC's struct/array storage read and
    write through (.agent/design/simd-spec.md §1.3). It is deliberately a
    plain 16-byte value record with NO managed fields, so it may live on a
    frame a trap unwind can skip (ADR-0009) and be copied with a raw Move.

    A v128 register occupies TWO adjacent 8-byte slots of the register file
    (§1.3): TWasmValue stays exactly 8 bytes, and a v128 is never read or
    written through TWasmValue's fields — only through a PWasmV128 aliasing
    the two slots. The two slots are the low half first.

    LANE ORDER is little-endian WITHIN the vector: lane i of a shape t x N
    occupies bytes [i*w, (i+1)*w), which is exactly the 16 literal bytes of
    a binary v128.const immediate (§1.3, spec syntax-laneidx). The variant
    arms below ARE the lane accessors; index them directly (V.U32[2],
    V.F64[1], V.B[15]). No arm interprets a word numerically for storage —
    aux round-trips copy raw bytes — so this record is endian-safe as a
    byte container. }
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

{$IF SizeOf(TWasmV128) <> 16}
  {$MESSAGE ERROR 'TWasmV128 must be exactly 16 bytes; see the header in Wasm.Core'}
{$IFEND}

  { Address types index a linear memory or a table; Wasm 3.0 makes both
    64-bit addressable. The address type is carried INSIDE the limits
    encoding (a flag bit), not next to it, which is why decoding limits
    yields one of these rather than taking one.
    https://webassembly.github.io/spec/core/binary/types.html#binary-limits }
  TWasmAddrType = (watI32, watI64);

  { Limits as decoded from the flags byte. Min and Max are u64 in the
    ENCODING for BOTH address types — every alternative of the binary
    grammar reads u64, including the i32 ones. Whether the values fit the
    address type is a validation question, so the decoder must not narrow
    them and this record must not either.
    https://webassembly.github.io/spec/core/binary/types.html#binary-limits }
  TWasmLimits = record
    AddrType: TWasmAddrType;
    HasMax: Boolean;
    Min: UInt64;
    Max: UInt64;

    function Describe: string;
  end;

  { https://webassembly.github.io/spec/core/binary/types.html#binary-tabletype }
  TWasmTableType = record
    RefType: TWasmRefType;
    Limits: TWasmLimits;

    function Describe: string;
  end;

  { https://webassembly.github.io/spec/core/binary/types.html#binary-memtype }
  TWasmMemType = record
    Limits: TWasmLimits;

    function Describe: string;
  end;

  { https://webassembly.github.io/spec/core/binary/types.html#binary-globaltype }
  TWasmGlobalType = record
    Mut: Boolean;
    ValueType: TWasmValueType;

    function Describe: string;
  end;

  { A tag type is a function type reference; the binary form is an
    attribute byte (0x00 is the only assigned value) and a type index.
    https://webassembly.github.io/spec/core/binary/types.html#binary-tagtype }
  TWasmTagType = record
    TypeIndex: UInt32;
  end;

  { Packed storage types, usable only as struct/array field storage —
    they are NOT value types and never appear on the operand stack.
    https://webassembly.github.io/spec/core/binary/types.html#binary-packtype }
  TWasmPackedType = (wpkI8, wpkI16);

  { A field's storage: either a full value type or a packed type. }
  TWasmStorageType = record
    IsPacked: Boolean;
    PackedType: TWasmPackedType;
    ValueType: TWasmValueType;

    function Describe: string;
  end;

  { https://webassembly.github.io/spec/core/binary/types.html#binary-fieldtype }
  TWasmFieldType = record
    Mut: Boolean;
    Storage: TWasmStorageType;

    function Describe: string;
  end;

  { Composite types — what a type-section entry defines once the rec/sub
    wrapping is unwrapped: a function, struct, or array shape.
    https://webassembly.github.io/spec/core/binary/types.html#binary-comptype }
  TWasmCompKind = (wckFunc, wckStruct, wckArray);

  TWasmFuncType = record
    Params: array of TWasmValueType;
    Results: array of TWasmValueType;
  end;

  TWasmStructType = record
    Fields: array of TWasmFieldType;
  end;

  TWasmArrayType = record
    Elem: TWasmFieldType;
  end;

  TWasmCompType = record
    Kind: TWasmCompKind;
    Func: TWasmFuncType;
    Struct: TWasmStructType;
    Arr: TWasmArrayType;
  end;

  { One member of a recursion group: optionally non-final, with declared
    supertype indices, around a composite type. A bare comptype in the
    binary is shorthand for a final subtype with no supertypes.
    https://webassembly.github.io/spec/core/binary/types.html#binary-subtype }
  TWasmSubType = record
    IsFinal: Boolean;
    SuperTypes: array of UInt32;
    Comp: TWasmCompType;
  end;

  { A type-section entry. Every entry is a recursion group — a bare
    subtype is shorthand for a group of one — and each member gets its
    own type index.
    https://webassembly.github.io/spec/core/binary/types.html#binary-rectype }
  TWasmRecType = record
    SubTypes: array of TWasmSubType;
  end;

  { External kinds, with ordinals matching the import/export description
    discriminator bytes (0x00..0x04).
    https://webassembly.github.io/spec/core/binary/types.html#binary-externtype }
  TWasmExternKind = (
    wxkFunc   = 0,
    wxkTable  = 1,
    wxkMem    = 2,
    wxkGlobal = 3,
    wxkTag    = 4
  );

  { Section ids. NOTE that these are ids, not positions — the encoding
    order is the grammar's prescribed order, which differs (see
    SectionOrderPosition). Custom sections may appear anywhere. }
  TWasmSectionId = (
    wsCustom    = 0,
    wsType      = 1,
    wsImport    = 2,
    wsFunction  = 3,
    wsTable     = 4,
    wsMemory    = 5,
    wsGlobal    = 6,
    wsExport    = 7,
    wsStart     = 8,
    wsElement   = 9,
    wsCode      = 10,
    wsData      = 11,
    wsDataCount = 12,
    wsTag       = 13
  );

  { The execution tier that ran (or will run) a function. The tier seam is
    the project's central architectural boundary (ADR-0001): every tier
    implements the same contract and is selected per function, never per
    module. }
  TWasmExecutionTier = (
    wetInterpreter,
    wetBaselineJit,
    wetAheadOfTime
  );

  TWasmBytes = array of Byte;

  { Error hierarchy. The distinction is the spec's, and it is load-bearing:
    a decode error means the bytes are not a module, a validation error
    means they are a module that is not well-typed, a link error means the
    imports could not be satisfied, a trap means well-typed code failed at
    run time, and an uncaught WebAssembly exception means well-typed code
    threw and no handler caught it before the invocation boundary. Hosts
    discriminate on these, so never collapse them. EWasmException and
    EWasmTrap are SIBLINGS under EWasmError, never one under the other: an
    uncaught guest exception is a distinct outcome from a trap, and the host
    (and the .wast runner's assert_exception judge) tells them apart. }
  EWasmError = class(Exception);
  EWasmDecodeError = class(EWasmError);
  EWasmValidationError = class(EWasmError);
  EWasmLinkError = class(EWasmError);
  EWasmTrap = class(EWasmError);

  { An internal invariant failure: a "internal: ..." defect on a code path
    the validator's type check proves unreachable for a validated module.
    NOT part of the host-facing vocabulary above — those five classes mean
    something about the MODULE or the invocation, this one means the
    runtime contradicted its own proof. It stays under EWasmError so a
    host's broadest handler still catches it, but it is never raised where
    a module-facing class applies, and no module-facing path may raise it. }
  EWasmInternal = class(EWasmError);

  { An uncaught WebAssembly exception (`throw` / `throw_ref`) that reached the
    invocation boundary with no `try_table` clause catching it. A SIBLING of
    EWasmTrap, not a subclass (see the hierarchy note above): the unwind that
    delivers it is explicit interpreter control flow over the activation
    stack, and only THIS terminal case leaves the interpreter as a real Pascal
    exception — the trampoline propagates it unchanged, exactly as it does an
    EWasmTrap, but the two never merge. Carries the raw wokExn handle (as a
    NativeUInt, so Wasm.Core keeps its no-runtime-dependency rule — a runtime
    TWasmRef is NativeUInt) and the thrown tag's store address, so an embedder
    (Track F) can recover the tag and payload; the conformance corpus only
    needs the class. .agent/design/eh-spec.md §2.4. }
  EWasmException = class(EWasmError)
  public
    ExnRef: NativeUInt;
    TagAddr: UInt32;
    constructor CreateExn(const AExn: NativeUInt; const ATag: UInt32);
  end;

  { A text-format syntax error, raised by the `wat` assembler and its
    sub-units (Wasm.Wat.*). A SIBLING of EWasmDecodeError, never a subclass:
    text malformedness is a claim about SOURCE TEXT, a decode error a claim
    about BINARY bytes (the hierarchy is load-bearing). Keeping it apart is
    what lets the conformance runner discriminate a real text error (which
    `assert_malformed` over a text/quote module expects) from a decode error
    on the assembler's OWN output (which is an internal defect — INV-1 in
    .agent/design/wat-assembler.md, never a malformed pass).

    Line and Column locate the fault, 1-based, for diagnostics; the corpus
    match on `assert_malformed` is a PREFIX match, so the canonical string
    must lead Message and any positional suffix is harmless. Promoted here
    (design §1) from the per-unit local copies each Wasm.Wat.* unit
    used to carry, so they are all the one type. }
  EWasmTextError = class(EWasmError)
  public
    Line: Integer;
    Column: Integer;
  end;

const
  { The canonical NaN bit patterns: the positive quiet NaN with the mantissa
    MSB set and every other payload bit clear (2^(m-1)). Load-bearing and
    shared — the text-format numeric parser (Wasm.Wat.Numbers) produces bare
    `nan` as this pattern, and the execution/result-class helpers
    (Wasm.Interp.Numeric, Wasm.Wast.Values) recognise and produce it. Kept
    here so there is ONE spelling of a value all of them must agree on. }
  WASM_F32_CANONICAL_NAN = UInt32($7FC00000);
  WASM_F64_CANONICAL_NAN = UInt64($7FF8000000000000);

  { Shared text-error message prefixes. These are UPSTREAM'S canonical strings
    and the conformance corpus matches them as a PREFIX of ours, so the two
    that more than one Wasm.Wat.* unit raises live here to keep the corpus-
    matched spelling from drifting between units (design §4). `unknown
    operator` and `unexpected token` are raised by both the numeric parser
    (Wasm.Wat.Numbers) and the assembler (Wasm.Wat.Assembler); the prefixes
    only one unit raises stay as MSG_* in that unit. }
  MSG_UNKNOWN_OPERATOR = 'unknown operator';
  MSG_UNEXPECTED_TOKEN = 'unexpected token';

{ Human-readable section name for diagnostics and `wasmlight inspect`.
  Ids outside the known set render as `unknown(<id>)` rather than raising —
  an unknown section id is a decode error the caller reports with its own
  offset context, not something a formatting helper should decide. }
function SectionIdName(const AId: Byte): string;

{ True when AId is one of the section ids this build knows. }
function IsKnownSectionId(const AId: Byte): Boolean;

{ Position of a known section in the binary format's PRESCRIBED ORDER,
  1-based, or 0 for the custom section (which may appear anywhere).

  Section ids are NOT the order. The spec says so explicitly — "Section
  ids do not always correspond to the order of sections in the encoding of
  a module" — and there are two deviations:

    - the data count section is id 12 but occurs BEFORE the code section
      (id 10), so a single-pass validator can check memory.init and
      data.drop segment indices without deferring;
    - the tag section is id 13 but occurs between the memory section
      (id 5) and the global section (id 6).

  Encoding the rule as "ids must increase" therefore rejects valid
  modules. The order below is the module grammar's, in grammar order.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-module }
function SectionOrderPosition(const AId: Byte): Integer;

{ --- type codes ---------------------------------------------------------

  All of these are the values of the SIGNED LEB128 the decoder reads, not
  byte values. The hex in the comment is the single-byte encoding of that
  same number, which is what a hex dump shows. }
const
  TYPE_CODE_V128     = -5;    { $7B }
  TYPE_CODE_REF_NULL = -29;   { $63 — long form: nullable ref to a heap type }
  TYPE_CODE_REF      = -28;   { $64 — long form: non-null ref to a heap type }

  { Recursive/composite type form codes, the type section's grammar. Note
    that $4F is the FINAL form and $50 the non-final one — final is the
    lower byte, which is the easy pair to transpose.
    https://webassembly.github.io/spec/core/binary/types.html#binary-rectype
    https://webassembly.github.io/spec/core/binary/types.html#binary-comptype }
  TYPE_CODE_REC       = -50;  { $4E — rec subtype* }
  TYPE_CODE_SUB_FINAL = -49;  { $4F — sub final typeidx* comptype }
  TYPE_CODE_SUB       = -48;  { $50 — sub typeidx* comptype }
  TYPE_CODE_ARRAY     = -34;  { $5E — array fieldtype }
  TYPE_CODE_STRUCT    = -33;  { $5F — struct fieldtype* }
  TYPE_CODE_FUNC      = -32;  { $60 — func params results }

  { Packed storage types. I16 is the LOWER byte of the two.
    https://webassembly.github.io/spec/core/binary/types.html#binary-packtype }
  TYPE_CODE_I16 = -9;   { $77 }
  TYPE_CODE_I8  = -8;   { $78 }

{ True when ACode is a number type. }
function TryDecodeNumType(const ACode: Int64;
  out AType: TWasmNumType): Boolean;

{ True when ACode is an abstract heap type code. A heap type that is not
  one of these is a concrete type index, which is a NON-NEGATIVE value —
  the two never collide, which is the whole point of the signed encoding. }
function TryDecodeAbsHeapType(const ACode: Int64;
  out AType: TWasmAbsHeapType): Boolean;

{ True when ACode is the SHORT form of a reference type: a bare abstract
  heap type code standing for a nullable reference to it. The long forms
  ($63 / $64) carry a following heap type and so cannot be decoded from a
  code alone — that belongs to the type-section decoder, which has a
  reader to read the heap type with. }
function TryDecodeShortRefType(const ACode: Int64;
  out AType: TWasmRefType): Boolean;

{ True when ACode is a value type in one of its self-contained forms:
  a number type, the vector type, or the short form of a reference type.
  Long-form reference types return False here for the reason above. }
function TryDecodeValueType(const ACode: Int64;
  out AType: TWasmValueType): Boolean;

function MakeAbsHeapType(const AAbs: TWasmAbsHeapType): TWasmHeapType;
function MakeConcreteHeapType(const ATypeIndex: UInt32): TWasmHeapType;
function MakeRefType(const ANullable: Boolean;
  const AHeap: TWasmHeapType): TWasmRefType;
function MakeNumValueType(const ANum: TWasmNumType): TWasmValueType;
function MakeVecValueType: TWasmValueType;
function MakeRefValueType(const ARef: TWasmRefType): TWasmValueType;

function MakeLimits(const AAddrType: TWasmAddrType;
  const AMin: UInt64): TWasmLimits;
function MakeLimitsWithMax(const AAddrType: TWasmAddrType;
  const AMin, AMax: UInt64): TWasmLimits;
function MakeTableType(const ARefType: TWasmRefType;
  const ALimits: TWasmLimits): TWasmTableType;
function MakeMemType(const ALimits: TWasmLimits): TWasmMemType;
function MakeGlobalType(const AMut: Boolean;
  const AValueType: TWasmValueType): TWasmGlobalType;
function MakeTagType(const ATypeIndex: UInt32): TWasmTagType;
function MakeValueStorageType(
  const AValueType: TWasmValueType): TWasmStorageType;
function MakePackedStorageType(
  const APacked: TWasmPackedType): TWasmStorageType;
function MakeFieldType(const AMut: Boolean;
  const AStorage: TWasmStorageType): TWasmFieldType;
function MakeFuncCompType(const AFunc: TWasmFuncType): TWasmCompType;
function MakeStructCompType(const AStruct: TWasmStructType): TWasmCompType;
function MakeArrayCompType(const AArr: TWasmArrayType): TWasmCompType;

function ExecutionTierName(const ATier: TWasmExecutionTier): string;

implementation

const
  SECTION_NAMES: array[TWasmSectionId] of string = (
    'custom', 'type', 'import', 'function', 'table', 'memory', 'global',
    'export', 'start', 'element', 'code', 'data', 'data count', 'tag'
  );

const
  { Indexed by section id; 0 means "not ordered" (custom sections). }
  SECTION_ORDER: array[TWasmSectionId] of Integer = (
    0,   { custom     — may appear anywhere }
    1,   { type       (id 1)  }
    2,   { import     (id 2)  }
    3,   { function   (id 3)  }
    4,   { table      (id 4)  }
    5,   { memory     (id 5)  }
    7,   { global     (id 6)  — after tag }
    8,   { export     (id 7)  }
    9,   { start      (id 8)  }
    10,  { element    (id 9)  }
    12,  { code       (id 10) — after data count }
    13,  { data       (id 11) }
    11,  { data count (id 12) — BEFORE code }
    6    { tag        (id 13) — between memory and global }
  );

function IsKnownSectionId(const AId: Byte): Boolean;
begin
  Result := AId <= Ord(High(TWasmSectionId));
end;

function SectionOrderPosition(const AId: Byte): Integer;
begin
  if IsKnownSectionId(AId) then
    Result := SECTION_ORDER[TWasmSectionId(AId)]
  else
    Result := 0;
end;

function SectionIdName(const AId: Byte): string;
begin
  if IsKnownSectionId(AId) then
    Result := SECTION_NAMES[TWasmSectionId(AId)]
  else
    Result := 'unknown(' + IntToStr(AId) + ')';
end;

{ --- types -------------------------------------------------------------- }

function AbsHeapTypeName(const AAbs: TWasmAbsHeapType): string;
begin
  case AAbs of
    wahExn: Result := 'exn';
    wahArray: Result := 'array';
    wahStruct: Result := 'struct';
    wahI31: Result := 'i31';
    wahEq: Result := 'eq';
    wahAny: Result := 'any';
    wahExtern: Result := 'extern';
    wahFunc: Result := 'func';
    wahNone: Result := 'none';
    wahNoExtern: Result := 'noextern';
    wahNoFunc: Result := 'nofunc';
    wahNoExn: Result := 'noexn';
  else
    Result := '?';
  end;
end;

function TWasmHeapType.Describe: string;
begin
  if IsAbstract then
    Result := AbsHeapTypeName(Abs)
  else
    Result := IntToStr(TypeIndex);
end;

{ Conventional spelling of a nullable reference to an abstract heap type.
  This is a TABLE, not `AbsHeapTypeName + 'ref'`: the four bottom types
  spell as `null*ref`, not `no*ref` — `none` is `nullref`, `nofunc` is
  `nullfuncref`. Deriving these by concatenation gets all four wrong.
  https://webassembly.github.io/spec/core/syntax/types.html#syntax-reftype }
function AbsHeapTypeShortRefName(const AAbs: TWasmAbsHeapType): string;
begin
  case AAbs of
    wahExn: Result := 'exnref';
    wahArray: Result := 'arrayref';
    wahStruct: Result := 'structref';
    wahI31: Result := 'i31ref';
    wahEq: Result := 'eqref';
    wahAny: Result := 'anyref';
    wahExtern: Result := 'externref';
    wahFunc: Result := 'funcref';
    wahNone: Result := 'nullref';
    wahNoExtern: Result := 'nullexternref';
    wahNoFunc: Result := 'nullfuncref';
    wahNoExn: Result := 'nullexnref';
  else
    Result := '?';
  end;
end;

function TWasmRefType.Describe: string;
begin
  { The short forms have conventional spellings — `funcref` rather than
    `(ref null func)` — and those are what a reader expects to see. }
  if Nullable and Heap.IsAbstract then
    Result := AbsHeapTypeShortRefName(Heap.Abs)
  else if Nullable then
    Result := '(ref null ' + Heap.Describe + ')'
  else
    Result := '(ref ' + Heap.Describe + ')';
end;

function TWasmValueType.Describe: string;
begin
  case Kind of
    wvkNum:
      case Num of
        wntI32: Result := 'i32';
        wntI64: Result := 'i64';
        wntF32: Result := 'f32';
        wntF64: Result := 'f64';
      else
        Result := '?';
      end;
    wvkVec: Result := 'v128';
    wvkRef: Result := Ref.Describe;
  else
    Result := '?';
  end;
end;

function TryDecodeNumType(const ACode: Int64;
  out AType: TWasmNumType): Boolean;
begin
  Result := (ACode >= Ord(Low(TWasmNumType)))
    and (ACode <= Ord(High(TWasmNumType)));
  if Result then
    AType := TWasmNumType(ACode)
  else
    AType := wntI32;
end;

function TryDecodeAbsHeapType(const ACode: Int64;
  out AType: TWasmAbsHeapType): Boolean;
begin
  Result := (ACode >= Ord(Low(TWasmAbsHeapType)))
    and (ACode <= Ord(High(TWasmAbsHeapType)));
  if Result then
    AType := TWasmAbsHeapType(ACode)
  else
    AType := wahFunc;
end;

function MakeAbsHeapType(const AAbs: TWasmAbsHeapType): TWasmHeapType;
begin
  Result.IsAbstract := True;
  Result.Abs := AAbs;
  Result.TypeIndex := 0;
end;

function MakeConcreteHeapType(const ATypeIndex: UInt32): TWasmHeapType;
begin
  Result.IsAbstract := False;
  Result.Abs := wahFunc;
  Result.TypeIndex := ATypeIndex;
end;

function MakeRefType(const ANullable: Boolean;
  const AHeap: TWasmHeapType): TWasmRefType;
begin
  Result.Nullable := ANullable;
  Result.Heap := AHeap;
end;

function MakeNumValueType(const ANum: TWasmNumType): TWasmValueType;
begin
  Result.Kind := wvkNum;
  Result.Num := ANum;
  Result.Ref := MakeRefType(True, MakeAbsHeapType(wahFunc));
end;

function MakeVecValueType: TWasmValueType;
begin
  Result.Kind := wvkVec;
  Result.Num := wntI32;
  Result.Ref := MakeRefType(True, MakeAbsHeapType(wahFunc));
end;

function MakeRefValueType(const ARef: TWasmRefType): TWasmValueType;
begin
  Result.Kind := wvkRef;
  Result.Num := wntI32;
  Result.Ref := ARef;
end;

function TryDecodeShortRefType(const ACode: Int64;
  out AType: TWasmRefType): Boolean;
var
  Abs: TWasmAbsHeapType;
begin
  Result := TryDecodeAbsHeapType(ACode, Abs);
  { The short form is always the nullable one; `(ref ht)` has no short
    spelling. }
  AType := MakeRefType(True, MakeAbsHeapType(Abs));
end;

function TryDecodeValueType(const ACode: Int64;
  out AType: TWasmValueType): Boolean;
var
  Num: TWasmNumType;
  Ref: TWasmRefType;
begin
  if TryDecodeNumType(ACode, Num) then
  begin
    AType := MakeNumValueType(Num);
    Exit(True);
  end;

  if ACode = TYPE_CODE_V128 then
  begin
    AType := MakeVecValueType;
    Exit(True);
  end;

  if TryDecodeShortRefType(ACode, Ref) then
  begin
    AType := MakeRefValueType(Ref);
    Exit(True);
  end;

  AType := MakeNumValueType(wntI32);
  Result := False;
end;

{ --- external and composite types ---------------------------------------- }

function TWasmLimits.Describe: string;
begin
  { The text format spells limits as `addrtype? min max?`, and i32 is the
    default address type, abbreviated to nothing — so only i64 is marked.
    https://webassembly.github.io/spec/core/text/types.html#text-limits }
  if AddrType = watI64 then
    Result := 'i64 ' + IntToStr(Min)
  else
    Result := IntToStr(Min);
  if HasMax then
    Result := Result + ' ' + IntToStr(Max);
end;

function TWasmTableType.Describe: string;
begin
  { `tabletype ::= addrtype? limits reftype` — element type last.
    https://webassembly.github.io/spec/core/text/types.html#text-tabletype }
  Result := Limits.Describe + ' ' + RefType.Describe;
end;

function TWasmMemType.Describe: string;
begin
  Result := Limits.Describe;
end;

function TWasmGlobalType.Describe: string;
begin
  { Immutable is the unmarked case; only `mut` gets the parenthesised form.
    https://webassembly.github.io/spec/core/text/types.html#text-globaltype }
  if Mut then
    Result := '(mut ' + ValueType.Describe + ')'
  else
    Result := ValueType.Describe;
end;

function TWasmStorageType.Describe: string;
begin
  if not IsPacked then
    Exit(ValueType.Describe);
  if PackedType = wpkI8 then
    Result := 'i8'
  else
    Result := 'i16';
end;

function TWasmFieldType.Describe: string;
begin
  if Mut then
    Result := '(mut ' + Storage.Describe + ')'
  else
    Result := Storage.Describe;
end;

function MakeLimits(const AAddrType: TWasmAddrType;
  const AMin: UInt64): TWasmLimits;
begin
  Result.AddrType := AAddrType;
  Result.HasMax := False;
  Result.Min := AMin;
  Result.Max := 0;
end;

function MakeLimitsWithMax(const AAddrType: TWasmAddrType;
  const AMin, AMax: UInt64): TWasmLimits;
begin
  Result.AddrType := AAddrType;
  Result.HasMax := True;
  Result.Min := AMin;
  Result.Max := AMax;
end;

function MakeTableType(const ARefType: TWasmRefType;
  const ALimits: TWasmLimits): TWasmTableType;
begin
  Result.RefType := ARefType;
  Result.Limits := ALimits;
end;

function MakeMemType(const ALimits: TWasmLimits): TWasmMemType;
begin
  Result.Limits := ALimits;
end;

function MakeGlobalType(const AMut: Boolean;
  const AValueType: TWasmValueType): TWasmGlobalType;
begin
  Result.Mut := AMut;
  Result.ValueType := AValueType;
end;

function MakeTagType(const ATypeIndex: UInt32): TWasmTagType;
begin
  Result.TypeIndex := ATypeIndex;
end;

function MakeValueStorageType(
  const AValueType: TWasmValueType): TWasmStorageType;
begin
  Result.IsPacked := False;
  Result.PackedType := wpkI8;
  Result.ValueType := AValueType;
end;

function MakePackedStorageType(
  const APacked: TWasmPackedType): TWasmStorageType;
begin
  Result.IsPacked := True;
  Result.PackedType := APacked;
  Result.ValueType := MakeNumValueType(wntI32);
end;

function MakeFieldType(const AMut: Boolean;
  const AStorage: TWasmStorageType): TWasmFieldType;
begin
  Result.Mut := AMut;
  Result.Storage := AStorage;
end;

{ The inactive arms are reset to fixed defaults rather than left as the
  caller's stack garbage, so two comp types built the same way always
  compare and hash the same. }

function DefaultFieldType: TWasmFieldType;
begin
  Result := MakeFieldType(False,
    MakeValueStorageType(MakeNumValueType(wntI32)));
end;

function MakeFuncCompType(const AFunc: TWasmFuncType): TWasmCompType;
begin
  Result.Kind := wckFunc;
  Result.Func := AFunc;
  Result.Struct.Fields := nil;
  Result.Arr.Elem := DefaultFieldType;
end;

function MakeStructCompType(const AStruct: TWasmStructType): TWasmCompType;
begin
  Result.Kind := wckStruct;
  Result.Func.Params := nil;
  Result.Func.Results := nil;
  Result.Struct := AStruct;
  Result.Arr.Elem := DefaultFieldType;
end;

function MakeArrayCompType(const AArr: TWasmArrayType): TWasmCompType;
begin
  Result.Kind := wckArray;
  Result.Func.Params := nil;
  Result.Func.Results := nil;
  Result.Struct.Fields := nil;
  Result.Arr := AArr;
end;

function ExecutionTierName(const ATier: TWasmExecutionTier): string;
begin
  case ATier of
    wetInterpreter: Result := 'interpreter';
    wetBaselineJit: Result := 'baseline-jit';
    wetAheadOfTime: Result := 'aot';
  else
    Result := '?';
  end;
end;

{ The message is fixed — the corpus's assert_exception checks only THAT an
  exception escaped, never a message (eh-spec §2.4). ExnRef/TagAddr carry the
  observable payload for a host that wants it. }
constructor EWasmException.CreateExn(const AExn: NativeUInt; const ATag: UInt32);
begin
  inherited Create('uncaught exception');
  ExnRef := AExn;
  TagAddr := ATag;
end;

end.
