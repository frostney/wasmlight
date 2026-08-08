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
    imports could not be satisfied, and a trap means well-typed code failed
    at run time. Hosts discriminate on these, so never collapse them. }
  EWasmError = class(Exception);
  EWasmDecodeError = class(EWasmError);
  EWasmValidationError = class(EWasmError);
  EWasmLinkError = class(EWasmError);
  EWasmTrap = class(EWasmError);

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

end.
