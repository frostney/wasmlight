{ Wasm.Validator.Types — type-section well-formedness, recursive-group
  canonicalisation, and the closed subtyping (matching) relation.

  This is the lowest of the validator units and the one every later
  consumer leans on. It owns three things:

  1. **Phase 1 of module validation** (`valid-type`, `valid-rectype` /
     `valid-subtype`, `valid-comptype`, `valid-heaptype`): the type
     section is validated INCREMENTALLY, group by group — "The sequence
     of types defined in a module is validated incrementally, yielding a
     sequence of defined types representing them individually"
     (`valid-type`). A recursive group may reference itself and any
     PREVIOUSLY defined group; a reference into a later group is
     invalid, and a declared supertype must be defined strictly before
     THE DECLARING MEMBER — which admits an earlier member of the same
     recursion group, and rules out self- and forward references, which
     is what "preventing cyclic subtype hierarchies" (`valid-rectype`)
     buys. See CheckMemberWellFormed for the rule and for the
     prose-versus-formal-rule tension behind it.

  2. **Canonicalisation.** Type equality under the 3.0 draft is equality
     of CLOSED types, so comparing type indices is wrong across groups
     and across modules. Each group is rolled up — internal type indices
     become group-relative recursive type indices (`aux-roll-rectype`,
     `syntax-rectypeidx`) — serialised into an injective key, and
     interned. Structurally identical groups therefore receive the same
     canonical ids, which is what makes equality "a constant-time check"
     (`appendix/algorithm-types`).

     Canonical ids produced here are MODULE-LOCAL. Track D needs
     engine-global ids for `call_indirect`'s runtime type check and for
     import/export linking, so every group's serialised key is retained
     (`GroupKey`) for re-interning into an engine-wide table. Never
     assume a canonical id is portable across modules.

  3. **The matching relation** (`match-valtype`, `match-reftype`,
     `match-heaptype`, `match-comptype`, `match-fieldtype`), exposed so
     that the body walker, the constant-expression checker, the
     module-level validator, and Track D's `ref.test` / `ref.cast` all
     share one implementation. Concrete-vs-concrete subtyping is a
     constant-time lookup in a precomputed supertype DISPLAY (the
     ancestor chain root-first), never a walk.

  Spec pin: the 3.0 draft at `d7b37e4170d8315f2f1283aed4e8076591a9a333`
  (ADR-0004; `wasm-mcp` `spec_version`). Anchors are cited at each rule.

  Two boundaries worth stating. Everything raised here is
  `EWasmValidationError`: the binary grammar was already satisfied by
  `Wasm.Decoder.Types`, so a type section that reaches this unit decodes.
  And there are no TYPE imports in the pinned draft — `importdesc` covers
  functions, tables, memories, globals, and tags only — so the context is
  built from the module's own type section and nothing else. }
unit Wasm.Validator.Types;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Module;

const
  { --- canonical message prefixes -------------------------------------

    These are PREFIXES: the reference interpreter's checker prefix-matches
    the error string, so context is appended after them. They live here
    rather than in a unit of their own because this is the lowest of the
    validator units and every one of the others uses them.

    The MCP serves the specification, not the testsuite, so a prefix
    cannot be verified from the spec text. What verifies one is a
    `wasmspec` run over the upstream corpus, and every prefix below that
    a `(module binary ...)` case reaches has now been through one
    (WebAssembly/testsuite@de54fd27). The ones still marked UNCONFIRMED
    are the ones no BINARY case reaches — the corpus spells them only in
    text modules, which stay skipped until there is an assembler — so
    they remain asserted from knowledge of upstream. Never delete a
    marker without a corpus run that settles it.

    `memory is immutable` is deliberately absent: memories carry no
    mutability flag in the core spec (`valid-memtype`), so there is no
    such rule to report. }
  MSG_TYPE_MISMATCH = 'type mismatch';
  MSG_UNKNOWN_LABEL = 'unknown label';
  MSG_UNKNOWN_LOCAL = 'unknown local';
  MSG_UNKNOWN_GLOBAL = 'unknown global';
  MSG_UNKNOWN_FUNCTION = 'unknown function';
  MSG_UNKNOWN_TABLE = 'unknown table';
  { The offending memory INDEX is part of the prefix upstream matches
    (`unknown memory 1`), with no colon before it — see
    UnknownMemoryPrefix, which is the only way this constant should be
    spelled at a raise site that has an index in hand. A bare
    `unknown memory` still prefix-matches the result, so upstream's
    index-less cases are unaffected. }
  MSG_UNKNOWN_MEMORY = 'unknown memory';
  MSG_UNKNOWN_TYPE = 'unknown type';
  { Confirmed against the upstream testsuite by review 2026-08-08. }
  MSG_UNKNOWN_TAG = 'unknown tag';
  MSG_UNKNOWN_DATA_SEGMENT = 'unknown data segment';
  { Confirmed against the upstream testsuite by review 2026-08-08. }
  MSG_UNKNOWN_ELEM_SEGMENT = 'unknown elem segment';
  MSG_CONSTANT_EXPRESSION_REQUIRED = 'constant expression required';
  MSG_DUPLICATE_EXPORT_NAME = 'duplicate export name';
  MSG_INVALID_RESULT_ARITY = 'invalid result arity';
  MSG_ALIGNMENT_TOO_LARGE = 'alignment must not be larger than natural';
  MSG_UNDECLARED_FUNCTION_REFERENCE = 'undeclared function reference';
  { Writing through an immutable handle. Upstream spells the space in the
    noun, not "X is immutable": a mutable-global write is `immutable
    global` (global.wast), a struct.set to a const field is `immutable
    field` (struct.wast), and every array write to a const element —
    array.set/fill/copy/init — is `immutable array` (array*.wast).
    Confirmed against the upstream testsuite by corpus run 2026-08-09. }
  MSG_IMMUTABLE_GLOBAL = 'immutable global';
  MSG_IMMUTABLE_FIELD = 'immutable field';
  MSG_IMMUTABLE_ARRAY = 'immutable array';
  { array.copy whose source element storage does not match the
    destination's (array_copy.wast), and array.init_data/new_data on an
    array whose element is a reference rather than a number, vector, or
    packed field (array_init_data.wast / array_new_data.wast). Confirmed
    against the upstream testsuite by corpus run 2026-08-09. }
  MSG_ARRAY_TYPES_MISMATCH = 'array types do not match';
  MSG_ARRAY_NOT_NUMERIC = 'array type is not numeric or vector';
  MSG_SIZE_MINIMUM_GT_MAXIMUM =
    'size minimum must not be greater than maximum';
  MSG_MEMORY_SIZE_LIMIT = 'memory size must be at most 65536 pages (4GiB)';
  MSG_START_FUNCTION = 'start function';
  { The GC declared-subtyping failures. Confirmed against the upstream
    testsuite by review 2026-08-08 for the two reachable-from-text cases —
    a supertype that is final, and a composite type that does not match
    its declared supertype — both of which upstream asserts as `sub type`.
    UNCONFIRMED for the third use, more supertypes than the pinned draft
    admits: the text format cannot spell a second supertype, so upstream
    has no case for it and only a hand-written binary module reaches that
    raise. }
  MSG_SUB_TYPE = 'sub type';
  { Reading a local that is not known to be initialized
    (`appendix/algorithm-stacks`, get_local: "error_if(not
    locals_init[idx])"). A DELIBERATE DIVERGENCE FROM THE TRACK B DESIGN
    DOC, which pinned `type mismatch` here on the argument that the local
    exists and only its local TYPE (`set` vs `set?`) is wrong. Confirmed
    against the upstream testsuite by review 2026-08-08: upstream asserts
    `uninitialized local`. }
  MSG_UNINITIALIZED_LOCAL = 'uninitialized local';
  { Project-local, by the Track B contract: SIMD typing is Track G. }
  MSG_SIMD_NOT_IMPLEMENTED = 'SIMD validation is not implemented';

  { The bottom heap type. BOT "is a bottom type that matches all value
    types … Similarly, BOT is also used as a bottom type of all heap
    types" (`syntax-rectypeidx`), and it is deliberately NOT representable
    in the binary format — it exists only during validation, which is why
    Wasm.Core has no spelling for it.

    It is spelled here as a CONCRETE heap type carrying a reserved index
    no module can name: the type index space is bounded by the type
    section, which cannot have 2^32-1 entries in a module that fits in
    memory. Every matching entry point tests for it before resolving a
    concrete index, so the sentinel never reaches the canonical table. }
  WASM_BOT_TYPE_INDEX = High(UInt32);

type
  { One canonicalised defined type.

    Comp is in CANONICAL space: every concrete heap type inside it names a
    canonical id, not a module type index, so the record is self-contained
    and survives being handed to a consumer that has no module. Use
    TWasmTypeContext.Expand for the module-space spelling — the two must
    never be mixed on one operand stack.

    Display is the supertype display: the ancestor chain root-first with
    this type itself last, so `A <= B` is
    `Depth(B) <= Depth(A) and Display(A)[Depth(B)] = B` — constant time,
    which is what Track D's `ref.cast` wants on the hot path
    (`match-deftype`, rules Deftype_sub/refl and Deftype_sub/super). }
  TWasmCanonType = record
    Comp: TWasmCompType;
    IsFinal: Boolean;
    HasSuper: Boolean;
    SuperId: UInt32;
    Display: array of UInt32;
  end;

  { The validated view of a module's type section.

    A record, not a class: it is built once, copied by value cheaply (the
    payload is refcounted dynamic arrays), and has no lifetime question at
    a call site. It borrows nothing from the module buffer — unlike the
    decoded model, everything here is owned. }
  TWasmTypeContext = record
  private
    { Module-space view: one entry per module type index, flattened out of
      the rec groups in section order. This is the spelling the decoder
      produced and the one every index in the rest of the module means. }
    FTypes: array of TWasmSubType;
    FTypeIndexToCanon: array of UInt32;

    { Canonical space. }
    FCanonTypes: array of TWasmCanonType;

    { Per rec group, in section order. }
    FGroupFirst: array of UInt32;
    FGroupSize: array of UInt32;
    FGroupBase: array of UInt32;
    FGroupKeys: array of TWasmBytes;

    { The intern table. A private detail on purpose: Track D replaces it
      with an engine-wide table without touching a caller.

      It is a LINEAR SCAN over parallel arrays, not a hash table: there
      are no buckets and no probing. FInternHashes is a cheap reject —
      comparing a stored u32 before comparing key bytes — so the scan is
      O(groups) with a four-byte test per step. Deliberate, because a
      type section is small and this runs once per module; and it avoids
      the RTL's string containers, whose comparisons are not safe over
      keys with embedded NULs. If a module ever makes this the hot spot,
      the fix is real buckets, not a better probe. }
    FInternHashes: array of UInt32;
    FInternKeys: array of TWasmBytes;
    FInternBases: array of UInt32;
    FInternCount: Integer;

    procedure Clear;
    { Raises `unknown type` when ATypeIndex is outside the module type
      index space. The single chokepoint every later unit's type-index
      check goes through: CanonIdOf and SubTypeAt both start here, so a
      caller that only wants the check calls this rather than discarding
      a canonical id for its side effect. }
    procedure CheckTypeIndex(const ATypeIndex: UInt32);
    procedure CheckTypeUse(const AIndex, ALimit: UInt32;
      const AWhere: string);
    procedure CheckValTypeUses(const AType: TWasmValueType;
      const ALimit: UInt32; const AWhere: string);
    procedure CheckFieldTypeUses(const AField: TWasmFieldType;
      const ALimit: UInt32; const AWhere: string);
    procedure CheckMemberWellFormed(const ASub: TWasmSubType;
      const AFirst, ACount, ASelf: UInt32);
    procedure CheckDeclaredSubtype(const ASub: TWasmSubType;
      const ASelf: UInt32);
    function SerialiseGroup(const AGroup: TWasmRecType;
      const AFirst, ACount: UInt32): TWasmBytes;
    { AHash is an OUT parameter rather than an internal detail so that the
      miss path can hand it straight to InternAdd: the key has just been
      hashed, and hashing it a second time is the whole cost of the
      lookup paid twice. }
    function InternLookup(const AKey: TWasmBytes;
      out AHash: UInt32; out ABase: UInt32): Boolean;
    procedure InternAdd(const AKey: TWasmBytes;
      const AHash, ABase: UInt32);
    procedure MaterialiseGroup(const AGroup: TWasmRecType;
      const AFirst, ACount, ABase: UInt32);
    function RewriteValType(const AType: TWasmValueType): TWasmValueType;
    function RewriteFieldType(const AField: TWasmFieldType): TWasmFieldType;
    function RewriteCompType(const AComp: TWasmCompType): TWasmCompType;
    function ConcreteAbsKind(const ATypeIndex: UInt32): TWasmAbsHeapType;
  public
    { Validates and canonicalises AModule's type section. Raises
      EWasmValidationError on the first violation. }
    procedure Build(const AModule: TWasmModule);
    { The same, from a bare rec-group sequence — the shape a test or a
      future text-format front end has. }
    procedure BuildFromRecTypes(const ATypes: array of TWasmRecType);

    { Size of the module's type index space (rec groups flattened). }
    function TypeCount: Integer;
    function CanonTypeCount: Integer;
    function GroupCount: Integer;

    { Canonical id for a module type index. Raises `unknown type` when the
      index is out of range — this is the single chokepoint every later
      unit's type-index check goes through. }
    function CanonIdOf(const ATypeIndex: UInt32): UInt32;
    { The composite type a module type index expands to, in MODULE space
      (`aux-expand-deftype`). }
    function Expand(const ATypeIndex: UInt32): TWasmCompType;
    function CompKind(const ATypeIndex: UInt32): TWasmCompKind;
    function IsFinal(const ATypeIndex: UInt32): Boolean;
    function SubTypeAt(const ATypeIndex: UInt32): TWasmSubType;

    { Canonical space, for Track D. }
    function CanonType(const ACanonId: UInt32): TWasmCanonType;
    function CanonComp(const ACanonId: UInt32): TWasmCompType;
    function CanonDepth(const ACanonId: UInt32): UInt32;
    { The serialised, index-space-independent key of a rec group, for
      re-interning into an engine-wide table. }
    function GroupKey(const AGroupIndex: Integer): TWasmBytes;
    function GroupBase(const AGroupIndex: Integer): UInt32;
    function GroupSize(const AGroupIndex: Integer): UInt32;

    { --- the matching relation ---------------------------------------

      Concrete heap types in the arguments are MODULE type indices, which
      is what every caller inside this project holds. MatchesCanon is the
      canonical-id entry point for a consumer holding runtime types. }
    function MatchesCanon(const ASub, ASuper: UInt32): Boolean;
    function MatchesHeapType(const A, B: TWasmHeapType): Boolean;
    function MatchesRefType(const A, B: TWasmRefType): Boolean;
    function MatchesValType(const A, B: TWasmValueType): Boolean;
    function MatchesStorageType(const A, B: TWasmStorageType): Boolean;
    function MatchesFieldType(const A, B: TWasmFieldType): Boolean;
    function MatchesFuncType(const A, B: TWasmFuncType): Boolean;
    function MatchesCompType(const A, B: TWasmCompType): Boolean;

    { The least precise supertype of a heap type — its top type. }
    function TopHeapType(const A: TWasmHeapType): TWasmAbsHeapType;
  end;

function MakeBotHeapType: TWasmHeapType;
function MakeBotValType: TWasmValueType;
function IsBotHeapType(const A: TWasmHeapType): Boolean;
function IsBotValType(const A: TWasmValueType): Boolean;

{ Subtyping between two ABSTRACT heap types (`match-heaptype`). Exposed
  because Track D's casts need it without a module in hand. }
function AbsHeapSubtype(const A, B: TWasmAbsHeapType): Boolean;

{ `unknown <thing> <index>` — the prefix for an index that names nothing
  in its space. The index sits INSIDE the prefix, space-separated and
  with no colon, because that is what upstream's scripts assert (they
  prefix-match `unknown global 7`, `unknown table 0`, …); the raise site
  then appends its own context after the usual colon. Every index-space
  `unknown X` message routes through here so the "index in the prefix, no
  colon" shape is written once — see the twelve MSG_UNKNOWN_* constants. }
function UnknownIndex(const ANoun: string; const AIndex: Int64): string;

{ `unknown memory <index>` — the memory-specific spelling of the above,
  kept as a named entry point because the memory reconciliation predates
  the generic helper and several callers reference it. }
function UnknownMemoryPrefix(const AIndex: UInt32): string;

implementation

{ --- message prefixes ---------------------------------------------------- }

function UnknownIndex(const ANoun: string; const AIndex: Int64): string;
begin
  Result := ANoun + ' ' + IntToStr(AIndex);
end;

function UnknownMemoryPrefix(const AIndex: UInt32): string;
begin
  Result := UnknownIndex(MSG_UNKNOWN_MEMORY, Int64(AIndex));
end;

{ --- the bottom type ----------------------------------------------------- }

function MakeBotHeapType: TWasmHeapType;
begin
  Result := MakeConcreteHeapType(WASM_BOT_TYPE_INDEX);
end;

function MakeBotValType: TWasmValueType;
begin
  Result := MakeRefValueType(MakeRefType(True, MakeBotHeapType));
end;

function IsBotHeapType(const A: TWasmHeapType): Boolean;
begin
  Result := (not A.IsAbstract) and (A.TypeIndex = WASM_BOT_TYPE_INDEX);
end;

function IsBotValType(const A: TWasmValueType): Boolean;
begin
  { Nullable is DELIBERATELY not consulted: BOT is the bottom of the heap
    hierarchy and a bottom-typed value is bottom either way — there is no
    `(ref bot)` that is somehow less bottom than `(ref null bot)`.
    MatchesRefType carries the same rule for the same reason, and the two
    must not drift apart. }
  Result := (A.Kind = wvkRef) and IsBotHeapType(A.Ref.Heap);
end;

{ --- abstract heap type subtyping ---------------------------------------- }

const
  ABS_HEAP_LOW = Ord(Low(TWasmAbsHeapType));

  { The abstract hierarchy, written out rather than computed
    (`match-heaptype`: Heaptype_sub/refl, /trans, /eq-any, /i31-eq,
    /struct-eq, /array-eq, /none, /nofunc, /noexn, /noextern).

    Four DISJOINT hierarchies (`syntax-heaptype`): the aggregate one
    topped by ANY with EQ below it and I31/STRUCT/ARRAY below EQ, bottom
    NONE; the function one topped by FUNC, bottom NOFUNC; EXTERN, bottom
    NOEXTERN; and EXN, bottom NOEXN, which "has no concrete subtypes".

    Rows are the SUBTYPE, columns the supertype, both in TWasmAbsHeapType
    declaration order:

      0 exn  1 array  2 struct  3 i31  4 eq  5 any
      6 extern  7 func  8 none  9 noextern  10 nofunc  11 noexn }
  ABS_HEAP_SUB: array[0..11, 0..11] of Boolean = (
    { exn      } (True, False, False, False, False, False, False, False,
                  False, False, False, False),
    { array    } (False, True, False, False, True, True, False, False,
                  False, False, False, False),
    { struct   } (False, False, True, False, True, True, False, False,
                  False, False, False, False),
    { i31      } (False, False, False, True, True, True, False, False,
                  False, False, False, False),
    { eq       } (False, False, False, False, True, True, False, False,
                  False, False, False, False),
    { any      } (False, False, False, False, False, True, False, False,
                  False, False, False, False),
    { extern   } (False, False, False, False, False, False, True, False,
                  False, False, False, False),
    { func     } (False, False, False, False, False, False, False, True,
                  False, False, False, False),
    { none     } (False, True, True, True, True, True, False, False,
                  True, False, False, False),
    { noextern } (False, False, False, False, False, False, True, False,
                  False, True, False, False),
    { nofunc   } (False, False, False, False, False, False, False, True,
                  False, False, True, False),
    { noexn    } (True, False, False, False, False, False, False, False,
                  False, False, False, True)
  );

function AbsHeapSubtype(const A, B: TWasmAbsHeapType): Boolean;
begin
  Result := ABS_HEAP_SUB[Ord(A) - ABS_HEAP_LOW, Ord(B) - ABS_HEAP_LOW];
end;

{ --- key serialisation --------------------------------------------------- }

type
  { A growable byte buffer for one group key. Kept local: the key layout
    is nobody else's business, only its injectivity is. }
  TKeyWriter = record
    Bytes: TWasmBytes;
    Count: Integer;

    procedure EmitByte(const AValue: Byte);
    procedure EmitU32(const AValue: UInt32);
    function Finish: TWasmBytes;
  end;

procedure TKeyWriter.EmitByte(const AValue: Byte);
begin
  if Count >= Length(Bytes) then
    SetLength(Bytes, (Count + 1) * 2);
  Bytes[Count] := AValue;
  Inc(Count);
end;

procedure TKeyWriter.EmitU32(const AValue: UInt32);
begin
  EmitByte(Byte(AValue and $FF));
  EmitByte(Byte((AValue shr 8) and $FF));
  EmitByte(Byte((AValue shr 16) and $FF));
  EmitByte(Byte((AValue shr 24) and $FF));
end;

function TKeyWriter.Finish: TWasmBytes;
begin
  SetLength(Bytes, Count);
  Result := Bytes;
end;

const
  { Key grammar. Any layout works as long as it is injective and
    deterministic, so it is pinned here once and never derived:

      group     ::= u32 count member*
      member    ::= u8 final  u32 supercount  typeuse*  comp
      comp      ::= $00 u32 nparams valtype* u32 nresults valtype*
                  | $01 u32 nfields fieldtype*
                  | $02 fieldtype
      fieldtype ::= u8 mut  storage
      storage   ::= $00 u8 packed | $01 valtype
      valtype   ::= $00 u8 num | $01 | $02 u8 nullable heaptype
      heaptype  ::= $00 u8 abs | $01 u32 recrel | $02 u32 canonid
      u32       ::= four bytes, little-endian

    REC_REL is the group-relative recursive type index (`aux-roll-rectype`,
    `syntax-rectypeidx`): making an internal reference position-relative is
    what lets two structurally identical groups at different type indices
    serialise identically. CANON is a reference to an already-canonicalised
    type, by canonical id — a reference to a LATER group cannot occur,
    because it is rejected before this runs. }
  KEY_COMP_FUNC = $00;
  KEY_COMP_STRUCT = $01;
  KEY_COMP_ARRAY = $02;
  KEY_STORAGE_PACKED = $00;
  KEY_STORAGE_VALUE = $01;
  KEY_VAL_NUM = $00;
  KEY_VAL_VEC = $01;
  KEY_VAL_REF = $02;
  KEY_HEAP_ABS = $00;
  KEY_HEAP_REC_REL = $01;
  KEY_HEAP_CANON = $02;

{ FNV-1a, 32-bit. A hash, not a checksum: collisions are resolved by
  comparing the key bytes. Overflow AND range checking are switched off
  around the multiply — wrapping IS the algorithm, FPC evaluates the
  product in 64 bits before narrowing it back, and Shared.inc turns both
  checks on for non-production builds. }
{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}
function KeyHash(const AKey: TWasmBytes): UInt32;
var
  I: Integer;
begin
  Result := UInt32($811C9DC5);
  for I := 0 to High(AKey) do
  begin
    Result := Result xor AKey[I];
    Result := Result * UInt32($01000193);
  end;
end;
{$POP}

function KeysEqual(const A, B: TWasmBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

{ --- TWasmTypeContext: construction -------------------------------------- }

procedure TWasmTypeContext.Clear;
begin
  SetLength(FTypes, 0);
  SetLength(FTypeIndexToCanon, 0);
  SetLength(FCanonTypes, 0);
  SetLength(FGroupFirst, 0);
  SetLength(FGroupSize, 0);
  SetLength(FGroupBase, 0);
  SetLength(FGroupKeys, 0);
  SetLength(FInternHashes, 0);
  SetLength(FInternKeys, 0);
  SetLength(FInternBases, 0);
  FInternCount := 0;
end;

procedure TWasmTypeContext.CheckTypeUse(const AIndex, ALimit: UInt32;
  const AWhere: string);
begin
  { `valid-heaptype` / `valid-type`: a concrete heap type may name a type
    of an earlier group or of its own group, never a later one. }
  if AIndex >= ALimit then
    raise EWasmValidationError.CreateFmt(
      '%s: %s refers to type %d, but only %d type(s) are defined at that '
      + 'point', [MSG_UNKNOWN_TYPE, AWhere, Int64(AIndex), Int64(ALimit)]);
end;

procedure TWasmTypeContext.CheckValTypeUses(const AType: TWasmValueType;
  const ALimit: UInt32; const AWhere: string);
begin
  if (AType.Kind = wvkRef) and (not AType.Ref.Heap.IsAbstract) then
    CheckTypeUse(AType.Ref.Heap.TypeIndex, ALimit, AWhere);
end;

procedure TWasmTypeContext.CheckFieldTypeUses(const AField: TWasmFieldType;
  const ALimit: UInt32; const AWhere: string);
begin
  { `valid-fieldtype` / `valid-storagetype`: a packed storage type has no
    type use to check. }
  if not AField.Storage.IsPacked then
    CheckValTypeUses(AField.Storage.ValueType, ALimit, AWhere);
end;

procedure TWasmTypeContext.CheckMemberWellFormed(const ASub: TWasmSubType;
  const AFirst, ACount, ASelf: UInt32);
var
  I: Integer;
  Limit: UInt32;
  Where: string;
begin
  Where := 'type ' + IntToStr(Int64(ASelf));

  { `valid-rectype`: "Future versions of WebAssembly may allow more than
    one supertype" — so at the pinned commit the list holds at most one.
    The binary grammar encodes a vector, which is why this is a validation
    rule and not a decode one. }
  if Length(ASub.SuperTypes) > 1 then
    raise EWasmValidationError.CreateFmt(
      '%s: %s declares %d supertypes, but at most one is allowed',
      [MSG_SUB_TYPE, Where, Length(ASub.SuperTypes)]);

  { THE BOUND IS THE MEMBER'S OWN INDEX, not the group's first.
    `valid-rectype`'s PROSE says a declared supertype must be "a
    previously defined types", which reads as "before the group"; the
    FORMAL RULES it cites say something weaker and that is what governs.
    `Rectype_ok/cons` validates the head member at OK(x) and the tail at
    OK(x+1), so the index parameter advances member by member through the
    group, and `Subtype_ok` — whose side condition is `y < x_0` over the
    declared supertypes — therefore compares against the DECLARING
    MEMBER's index. The prose is describing the common case, not the
    rule.

    Two independent confirmations at the pinned commit
    (d7b37e4170d8315f2f1283aed4e8076591a9a333): the reference
    interpreter, and `test/core/gc/type-subtyping.wast`, which asserts as
    VALID a module containing

      (rec (type $t1 (sub          (func (param i32 (ref $t3)))))
           (type $t2 (sub $t1      (func (param i32 (ref $t2)))))
           (type $t3 (sub $t2      (func (param i32 (ref $t1))))))

    — every supertype an earlier member of the declaring member's own
    group. Bounding at AFirst rejected that module.

    Self- and forward references stay rejected, which is the part that
    actually prevents a cyclic hierarchy: >= ASelf covers both, because a
    supertype equal to the declaring index is the one-step cycle and
    anything larger is not yet defined. This ordering is also what lets
    MaterialiseGroup extend the supertype display by exactly one entry —
    an own-group supertype's display is complete by the time the
    declaring member is materialised, because members are materialised in
    index order. }
  for I := 0 to High(ASub.SuperTypes) do
    if ASub.SuperTypes[I] >= ASelf then
      raise EWasmValidationError.CreateFmt(
        '%s: %s declares supertype %d, which is not defined before it '
        + '(a supertype must be an earlier type, its own group included)',
        [MSG_UNKNOWN_TYPE, Where, Int64(ASub.SuperTypes[I])]);

  { Inside the group's own composite types, self- and sibling references
    are exactly what recursion groups exist for. }
  Limit := AFirst + ACount;
  case ASub.Comp.Kind of
    wckFunc:
      begin
        for I := 0 to High(ASub.Comp.Func.Params) do
          CheckValTypeUses(ASub.Comp.Func.Params[I], Limit, Where);
        for I := 0 to High(ASub.Comp.Func.Results) do
          CheckValTypeUses(ASub.Comp.Func.Results[I], Limit, Where);
      end;
    wckStruct:
      for I := 0 to High(ASub.Comp.Struct.Fields) do
        CheckFieldTypeUses(ASub.Comp.Struct.Fields[I], Limit, Where);
    wckArray:
      CheckFieldTypeUses(ASub.Comp.Arr.Elem, Limit, Where);
  end;
end;

procedure TWasmTypeContext.CheckDeclaredSubtype(const ASub: TWasmSubType;
  const ASelf: UInt32);
var
  Super: UInt32;
  Where: string;
begin
  if Length(ASub.SuperTypes) = 0 then
    Exit;

  Super := ASub.SuperTypes[0];
  Where := 'type ' + IntToStr(Int64(ASelf));

  { `valid-rectype` / `syntax-final`: a final type prevents further
    subtyping. }
  if FTypes[Super].IsFinal then
    raise EWasmValidationError.CreateFmt(
      '%s: %s declares supertype %d, which is final',
      [MSG_SUB_TYPE, Where, Int64(Super)]);

  { `match-comptype`: the declaring type's composite type must match the
    supertype's. Both sides are module-space here, and every index either
    of them can name is already canonicalised. }
  if not MatchesCompType(ASub.Comp, FTypes[Super].Comp) then
    raise EWasmValidationError.CreateFmt(
      '%s: %s does not match its declared supertype %d',
      [MSG_SUB_TYPE, Where, Int64(Super)]);
end;

function TWasmTypeContext.SerialiseGroup(const AGroup: TWasmRecType;
  const AFirst, ACount: UInt32): TWasmBytes;
var
  Writer: TKeyWriter;
  I, J: Integer;
  Sub: TWasmSubType;

  { The ONE place a type index becomes a key byte, used for concrete heap
    types inside composite types AND for the declared supertype list.
    That uniformity is load-bearing: an own-group supertype is as
    position-dependent as an own-group field reference, so it needs the
    same rec-relative encoding, or two alpha-equivalent groups declaring
    internal supertypes would serialise differently and fail to intern. }
  procedure EmitTypeUse(const AIndex: UInt32);
  begin
    if AIndex >= AFirst then
    begin
      Writer.EmitByte(KEY_HEAP_REC_REL);
      Writer.EmitU32(AIndex - AFirst);
    end
    else
    begin
      Writer.EmitByte(KEY_HEAP_CANON);
      Writer.EmitU32(FTypeIndexToCanon[AIndex]);
    end;
  end;

  procedure EmitValType(const AType: TWasmValueType);
  begin
    case AType.Kind of
      wvkNum:
        begin
          Writer.EmitByte(KEY_VAL_NUM);
          Writer.EmitByte(Byte(Ord(AType.Num) - Ord(Low(TWasmNumType))));
        end;
      wvkVec:
        Writer.EmitByte(KEY_VAL_VEC);
      wvkRef:
        begin
          Writer.EmitByte(KEY_VAL_REF);
          Writer.EmitByte(Ord(AType.Ref.Nullable));
          if AType.Ref.Heap.IsAbstract then
          begin
            Writer.EmitByte(KEY_HEAP_ABS);
            Writer.EmitByte(Byte(Ord(AType.Ref.Heap.Abs) - ABS_HEAP_LOW));
          end
          else
            EmitTypeUse(AType.Ref.Heap.TypeIndex);
        end;
    end;
  end;

  procedure EmitFieldType(const AField: TWasmFieldType);
  begin
    Writer.EmitByte(Ord(AField.Mut));
    if AField.Storage.IsPacked then
    begin
      Writer.EmitByte(KEY_STORAGE_PACKED);
      Writer.EmitByte(Ord(AField.Storage.PackedType));
    end
    else
    begin
      Writer.EmitByte(KEY_STORAGE_VALUE);
      EmitValType(AField.Storage.ValueType);
    end;
  end;

begin
  Writer.Bytes := nil;
  Writer.Count := 0;
  Writer.EmitU32(ACount);

  for I := 0 to High(AGroup.SubTypes) do
  begin
    Sub := AGroup.SubTypes[I];
    Writer.EmitByte(Ord(Sub.IsFinal));
    Writer.EmitU32(UInt32(Length(Sub.SuperTypes)));
    for J := 0 to High(Sub.SuperTypes) do
      EmitTypeUse(Sub.SuperTypes[J]);

    case Sub.Comp.Kind of
      wckFunc:
        begin
          Writer.EmitByte(KEY_COMP_FUNC);
          Writer.EmitU32(UInt32(Length(Sub.Comp.Func.Params)));
          for J := 0 to High(Sub.Comp.Func.Params) do
            EmitValType(Sub.Comp.Func.Params[J]);
          Writer.EmitU32(UInt32(Length(Sub.Comp.Func.Results)));
          for J := 0 to High(Sub.Comp.Func.Results) do
            EmitValType(Sub.Comp.Func.Results[J]);
        end;
      wckStruct:
        begin
          Writer.EmitByte(KEY_COMP_STRUCT);
          Writer.EmitU32(UInt32(Length(Sub.Comp.Struct.Fields)));
          for J := 0 to High(Sub.Comp.Struct.Fields) do
            EmitFieldType(Sub.Comp.Struct.Fields[J]);
        end;
      wckArray:
        begin
          Writer.EmitByte(KEY_COMP_ARRAY);
          EmitFieldType(Sub.Comp.Arr.Elem);
        end;
    end;
  end;

  Result := Writer.Finish;
end;

function TWasmTypeContext.InternLookup(const AKey: TWasmBytes;
  out AHash: UInt32; out ABase: UInt32): Boolean;
var
  I: Integer;
begin
  AHash := KeyHash(AKey);
  for I := 0 to FInternCount - 1 do
    if (FInternHashes[I] = AHash) and KeysEqual(FInternKeys[I], AKey) then
    begin
      ABase := FInternBases[I];
      Exit(True);
    end;
  ABase := 0;
  Result := False;
end;

procedure TWasmTypeContext.InternAdd(const AKey: TWasmBytes;
  const AHash, ABase: UInt32);
begin
  { AHash is the caller's, from the InternLookup that just missed —
    rehashing here would walk the whole key a second time for nothing. }
  if FInternCount >= Length(FInternKeys) then
  begin
    SetLength(FInternKeys, (FInternCount + 1) * 2);
    SetLength(FInternHashes, Length(FInternKeys));
    SetLength(FInternBases, Length(FInternKeys));
  end;
  FInternKeys[FInternCount] := AKey;
  FInternHashes[FInternCount] := AHash;
  FInternBases[FInternCount] := ABase;
  Inc(FInternCount);
end;

function TWasmTypeContext.RewriteValType(
  const AType: TWasmValueType): TWasmValueType;
begin
  Result := AType;
  if (AType.Kind = wvkRef) and (not AType.Ref.Heap.IsAbstract) then
    Result := MakeRefValueType(MakeRefType(AType.Ref.Nullable,
      MakeConcreteHeapType(FTypeIndexToCanon[AType.Ref.Heap.TypeIndex])));
end;

function TWasmTypeContext.RewriteFieldType(
  const AField: TWasmFieldType): TWasmFieldType;
begin
  if AField.Storage.IsPacked then
    Result := AField
  else
    Result := MakeFieldType(AField.Mut,
      MakeValueStorageType(RewriteValType(AField.Storage.ValueType)));
end;

function TWasmTypeContext.RewriteCompType(
  const AComp: TWasmCompType): TWasmCompType;
var
  I: Integer;
  Func: TWasmFuncType;
  Struct: TWasmStructType;
  Arr: TWasmArrayType;
begin
  { Fresh arrays throughout: the module's own arrays are shared by
    reference and must not be rewritten under the decoder's feet. }
  case AComp.Kind of
    wckFunc:
      begin
        SetLength(Func.Params, Length(AComp.Func.Params));
        for I := 0 to High(AComp.Func.Params) do
          Func.Params[I] := RewriteValType(AComp.Func.Params[I]);
        SetLength(Func.Results, Length(AComp.Func.Results));
        for I := 0 to High(AComp.Func.Results) do
          Func.Results[I] := RewriteValType(AComp.Func.Results[I]);
        Result := MakeFuncCompType(Func);
      end;
    wckStruct:
      begin
        SetLength(Struct.Fields, Length(AComp.Struct.Fields));
        for I := 0 to High(AComp.Struct.Fields) do
          Struct.Fields[I] := RewriteFieldType(AComp.Struct.Fields[I]);
        Result := MakeStructCompType(Struct);
      end;
  else
    Arr.Elem := RewriteFieldType(AComp.Arr.Elem);
    Result := MakeArrayCompType(Arr);
  end;
end;

procedure TWasmTypeContext.MaterialiseGroup(const AGroup: TWasmRecType;
  const AFirst, ACount, ABase: UInt32);
var
  I, D: Integer;
  Sub: TWasmSubType;
  Canon: TWasmCanonType;
  SuperId: UInt32;
begin
  SetLength(FCanonTypes, ABase + ACount);
  for I := 0 to High(AGroup.SubTypes) do
  begin
    Sub := AGroup.SubTypes[I];
    Canon.Comp := RewriteCompType(Sub.Comp);
    Canon.IsFinal := Sub.IsFinal;
    Canon.HasSuper := Length(Sub.SuperTypes) > 0;
    Canon.SuperId := 0;
    Canon.Display := nil;

    if Canon.HasSuper then
    begin
      { The supertype is defined before this MEMBER (CheckMemberWellFormed
        bounds it at ASelf), so its display is already complete and the
        chain extends by exactly one. That holds for an own-group
        supertype too, but only because this loop runs in index order and
        FTypeIndexToCanon was filled for the whole group before the call —
        materialising out of order would read an empty display and
        silently flatten the hierarchy. }
      SuperId := FTypeIndexToCanon[Sub.SuperTypes[0]];
      Canon.SuperId := SuperId;
      SetLength(Canon.Display, Length(FCanonTypes[SuperId].Display) + 1);
      for D := 0 to High(FCanonTypes[SuperId].Display) do
        Canon.Display[D] := FCanonTypes[SuperId].Display[D];
    end
    else
      SetLength(Canon.Display, 1);
    Canon.Display[High(Canon.Display)] := ABase + UInt32(I);

    FCanonTypes[ABase + UInt32(I)] := Canon;
  end;
end;

procedure TWasmTypeContext.BuildFromRecTypes(
  const ATypes: array of TWasmRecType);
var
  G, J, Total: Integer;
  First, Count, Base, Hash: UInt32;
  Key: TWasmBytes;
  IsNewGroup: Boolean;
begin
  Clear;

  Total := 0;
  for G := 0 to High(ATypes) do
    Inc(Total, Length(ATypes[G].SubTypes));
  SetLength(FTypes, Total);
  SetLength(FTypeIndexToCanon, Total);
  SetLength(FGroupFirst, Length(ATypes));
  SetLength(FGroupSize, Length(ATypes));
  SetLength(FGroupBase, Length(ATypes));
  SetLength(FGroupKeys, Length(ATypes));

  First := 0;
  for G := 0 to High(ATypes) do
  begin
    Count := UInt32(Length(ATypes[G].SubTypes));
    FGroupFirst[G] := First;
    FGroupSize[G] := Count;

    { Order matters and is the whole of `valid-type`'s incrementality:
      well-formedness first (nothing may name a later group), then the
      group joins the index space, then it is interned and materialised
      so that the declared-subtype check below can resolve every index it
      sees, including this group's own. }
    for J := 0 to High(ATypes[G].SubTypes) do
      CheckMemberWellFormed(ATypes[G].SubTypes[J], First, Count,
        First + UInt32(J));
    for J := 0 to High(ATypes[G].SubTypes) do
      FTypes[First + UInt32(J)] := ATypes[G].SubTypes[J];

    Key := SerialiseGroup(ATypes[G], First, Count);
    FGroupKeys[G] := Key;
    IsNewGroup := not InternLookup(Key, Hash, Base);
    if IsNewGroup then
    begin
      Base := UInt32(Length(FCanonTypes));
      InternAdd(Key, Hash, Base);
    end;
    FGroupBase[G] := Base;

    for J := 0 to High(ATypes[G].SubTypes) do
      FTypeIndexToCanon[First + UInt32(J)] := Base + UInt32(J);
    if IsNewGroup then
      MaterialiseGroup(ATypes[G], First, Count, Base);

    for J := 0 to High(ATypes[G].SubTypes) do
      CheckDeclaredSubtype(ATypes[G].SubTypes[J], First + UInt32(J));

    First := First + Count;
  end;
end;

procedure TWasmTypeContext.Build(const AModule: TWasmModule);
var
  I: Integer;
  Groups: array of TWasmRecType;
begin
  SetLength(Groups, AModule.TypeCount);
  for I := 0 to AModule.TypeCount - 1 do
    Groups[I] := AModule.Types[I];
  BuildFromRecTypes(Groups);
end;

{ --- TWasmTypeContext: accessors ----------------------------------------- }

function TWasmTypeContext.TypeCount: Integer;
begin
  Result := Length(FTypes);
end;

function TWasmTypeContext.CanonTypeCount: Integer;
begin
  Result := Length(FCanonTypes);
end;

function TWasmTypeContext.GroupCount: Integer;
begin
  Result := Length(FGroupFirst);
end;

procedure TWasmTypeContext.CheckTypeIndex(const ATypeIndex: UInt32);
begin
  if ATypeIndex >= UInt32(Length(FTypes)) then
    raise EWasmValidationError.CreateFmt(
      '%s: type index %d is out of range (%d type(s) defined)',
      [MSG_UNKNOWN_TYPE, Int64(ATypeIndex), Length(FTypes)]);
end;

function TWasmTypeContext.CanonIdOf(const ATypeIndex: UInt32): UInt32;
begin
  CheckTypeIndex(ATypeIndex);
  Result := FTypeIndexToCanon[ATypeIndex];
end;

function TWasmTypeContext.SubTypeAt(
  const ATypeIndex: UInt32): TWasmSubType;
begin
  CheckTypeIndex(ATypeIndex);
  Result := FTypes[ATypeIndex];
end;

function TWasmTypeContext.Expand(
  const ATypeIndex: UInt32): TWasmCompType;
begin
  Result := SubTypeAt(ATypeIndex).Comp;
end;

function TWasmTypeContext.CompKind(
  const ATypeIndex: UInt32): TWasmCompKind;
begin
  Result := SubTypeAt(ATypeIndex).Comp.Kind;
end;

function TWasmTypeContext.IsFinal(const ATypeIndex: UInt32): Boolean;
begin
  Result := SubTypeAt(ATypeIndex).IsFinal;
end;

function TWasmTypeContext.CanonType(
  const ACanonId: UInt32): TWasmCanonType;
begin
  if ACanonId >= UInt32(Length(FCanonTypes)) then
    raise EWasmValidationError.CreateFmt(
      '%s: canonical type id %d is out of range (%d defined)',
      [MSG_UNKNOWN_TYPE, Int64(ACanonId), Length(FCanonTypes)]);
  Result := FCanonTypes[ACanonId];
end;

function TWasmTypeContext.CanonComp(
  const ACanonId: UInt32): TWasmCompType;
begin
  Result := CanonType(ACanonId).Comp;
end;

function TWasmTypeContext.CanonDepth(const ACanonId: UInt32): UInt32;
begin
  Result := UInt32(Length(CanonType(ACanonId).Display) - 1);
end;

function TWasmTypeContext.GroupKey(
  const AGroupIndex: Integer): TWasmBytes;
begin
  Result := FGroupKeys[AGroupIndex];
end;

function TWasmTypeContext.GroupBase(const AGroupIndex: Integer): UInt32;
begin
  Result := FGroupBase[AGroupIndex];
end;

function TWasmTypeContext.GroupSize(const AGroupIndex: Integer): UInt32;
begin
  Result := FGroupSize[AGroupIndex];
end;

{ --- TWasmTypeContext: matching ------------------------------------------ }

function TWasmTypeContext.MatchesCanon(const ASub,
  ASuper: UInt32): Boolean;
var
  SuperDepth: Integer;
begin
  { `match-deftype`: Deftype_sub/refl and Deftype_sub/super. The display
    turns the chain walk into two array reads. }
  if ASub = ASuper then
    Exit(True);
  SuperDepth := Length(CanonType(ASuper).Display) - 1;
  Result := (SuperDepth < Length(CanonType(ASub).Display))
    and (FCanonTypes[ASub].Display[SuperDepth] = ASuper);
end;

function TWasmTypeContext.ConcreteAbsKind(
  const ATypeIndex: UInt32): TWasmAbsHeapType;
begin
  { Heaptype_sub/struct, /array, /func: a concrete type sits under the
    abstract type of its composite kind. }
  case CompKind(ATypeIndex) of
    wckStruct: Result := wahStruct;
    wckArray: Result := wahArray;
  else
    Result := wahFunc;
  end;
end;

function TWasmTypeContext.MatchesHeapType(const A,
  B: TWasmHeapType): Boolean;
begin
  { Heaptype_sub/bot: BOT is below everything, and nothing but BOT is
    below BOT. Tested before any index is resolved — the bottom sentinel
    is not in the canonical table. }
  if IsBotHeapType(A) then
    Exit(True);
  if IsBotHeapType(B) then
    Exit(False);

  if A.IsAbstract and B.IsAbstract then
    Exit(AbsHeapSubtype(A.Abs, B.Abs));

  if B.IsAbstract then
    Exit(AbsHeapSubtype(ConcreteAbsKind(A.TypeIndex), B.Abs));

  if A.IsAbstract then
  begin
    { Only the bottom of the matching hierarchy reaches a concrete type
      (Heaptype_sub/none, /nofunc). NOEXN and NOEXTERN have no concrete
      types to be below: EXN and EXTERN "have no concrete subtypes"
      (`syntax-heaptype`). }
    case A.Abs of
      wahNone:
        Result := ConcreteAbsKind(B.TypeIndex) <> wahFunc;
      wahNoFunc:
        Result := ConcreteAbsKind(B.TypeIndex) = wahFunc;
    else
      Result := False;
    end;
    Exit;
  end;

  Result := MatchesCanon(CanonIdOf(A.TypeIndex), CanonIdOf(B.TypeIndex));
end;

function TWasmTypeContext.MatchesRefType(const A,
  B: TWasmRefType): Boolean;
begin
  { A BOTTOM HEAP TYPE IS BOTTOM WHETHER OR NOT THE REFERENCE IS SPELLED
    NULLABLE, and that has to be decided before the nullability test.
    IsBotValType ignores Nullable, so MatchesValType routes
    `(ref null bot)` straight to True; without this line MatchesRefType
    would then answer False for the same pair, because a nullable A
    against a non-nullable B fails the test below. Two entry points
    disagreeing about the bottom type is the kind of divergence that
    surfaces as a tier-dependent accept/reject much later.

    Hardening rather than a bug fix: no current call site constructs a
    nullable bottom reference and asks MatchesRefType directly — the
    walker's polymorphic values go through MatchesValType. Aligning them
    is cheaper than proving it stays that way.

    Spec-wise this is Heaptype_sub/bot doing the work: BOT is below every
    heap type, and `syntax-rectypeidx` gives it no nullability of its own
    to disagree about. }
  if IsBotHeapType(A.Heap) then
    Exit(True);

  { `match-reftype`: a non-null reference matches a nullable one, never
    the other way round. }
  Result := ((not A.Nullable) or B.Nullable)
    and MatchesHeapType(A.Heap, B.Heap);
end;

function TWasmTypeContext.MatchesValType(const A,
  B: TWasmValueType): Boolean;
begin
  { `match-valtype`: Valtype_sub/bot, /num, /vec, /ref. Numbers and
    vectors match only themselves. }
  if IsBotValType(A) then
    Exit(True);
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    wvkNum: Result := A.Num = B.Num;
    wvkVec: Result := True;
  else
    Result := MatchesRefType(A.Ref, B.Ref);
  end;
end;

function TWasmTypeContext.MatchesStorageType(const A,
  B: TWasmStorageType): Boolean;
begin
  { `match-fieldtype` / Storagetype_sub, Packtype_sub: a packed type
    matches only the identical packed type, and never a value type. }
  if A.IsPacked <> B.IsPacked then
    Exit(False);
  if A.IsPacked then
    Result := A.PackedType = B.PackedType
  else
    Result := MatchesValType(A.ValueType, B.ValueType);
end;

function TWasmTypeContext.MatchesFieldType(const A,
  B: TWasmFieldType): Boolean;
begin
  { Fieldtype_sub/const is covariant in the storage type;
    Fieldtype_sub/var is INVARIANT — a mutable field must match in both
    directions, which is why the second call is not redundant. }
  if A.Mut <> B.Mut then
    Exit(False);
  Result := MatchesStorageType(A.Storage, B.Storage);
  if Result and A.Mut then
    Result := MatchesStorageType(B.Storage, A.Storage);
end;

function TWasmTypeContext.MatchesFuncType(const A,
  B: TWasmFuncType): Boolean;
var
  I: Integer;
begin
  { `match-functype`: same arities, parameters CONTRAVARIANT, results
    COVARIANT. Getting the variance backwards passes every same-type
    test, which is what makes it the classic error here. }
  if (Length(A.Params) <> Length(B.Params))
    or (Length(A.Results) <> Length(B.Results)) then
    Exit(False);
  for I := 0 to High(A.Params) do
    if not MatchesValType(B.Params[I], A.Params[I]) then
      Exit(False);
  for I := 0 to High(A.Results) do
    if not MatchesValType(A.Results[I], B.Results[I]) then
      Exit(False);
  Result := True;
end;

function TWasmTypeContext.MatchesCompType(const A,
  B: TWasmCompType): Boolean;
var
  I: Integer;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    wckFunc:
      Result := MatchesFuncType(A.Func, B.Func);
    wckStruct:
      begin
        { `match-structtype`: WIDTH subtyping — the supertype's fields are
          a prefix of the subtype's — plus per-field matching. }
        if Length(A.Struct.Fields) < Length(B.Struct.Fields) then
          Exit(False);
        for I := 0 to High(B.Struct.Fields) do
          if not MatchesFieldType(A.Struct.Fields[I],
            B.Struct.Fields[I]) then
            Exit(False);
        Result := True;
      end;
  else
    Result := MatchesFieldType(A.Arr.Elem, B.Arr.Elem);
  end;
end;

function TWasmTypeContext.TopHeapType(
  const A: TWasmHeapType): TWasmAbsHeapType;
begin
  { `appendix/algorithm-types`' top_heap_type, with one addition: it omits
    EXN and NOEXN entirely, because it is written for ref.test/ref.cast,
    which never reach the exception hierarchy. Returning EXN for both is
    the consistent completion: EXN tops its hierarchy by
    `match-heaptype`, so it is SPEC-DERIVABLE rather than guessed, and
    only the algorithm appendix's silence keeps it from being a citation.

    BOT has no top type — it is below all four hierarchies at once, so
    there is no answer to return. Reaching here with it is an internal
    error, not a module-level one, and it is reported with a message that
    deliberately does NOT carry a canonical prefix: a caller that passed
    BOT has a bug, and dressing it as `unknown type` would make it look
    like a rejected module and could be prefix-matched by a conformance
    runner. Without this guard the bottom sentinel falls through to
    ConcreteAbsKind and raises exactly that. }
  if IsBotHeapType(A) then
    raise EWasmValidationError.Create(
      'internal error: TopHeapType has no answer for the bottom heap '
      + 'type; the caller must test IsBotHeapType first');

  if not A.IsAbstract then
  begin
    if ConcreteAbsKind(A.TypeIndex) = wahFunc then
      Result := wahFunc
    else
      Result := wahAny;
    Exit;
  end;

  case A.Abs of
    wahAny, wahEq, wahI31, wahStruct, wahArray, wahNone:
      Result := wahAny;
    wahFunc, wahNoFunc:
      Result := wahFunc;
    wahExtern, wahNoExtern:
      Result := wahExtern;
  else
    Result := wahExn;
  end;
end;

end.
