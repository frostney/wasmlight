{ Wasm.Validator — module-level validation and the public entry point.

  This is the top of the validator stack and the only thing outside it a
  caller needs: `ValidateModule` takes a decoded model plus the buffer it
  borrows (ADR-0003) and returns the lowered register IR every execution
  tier consumes (ADR-0007). Validation happens exactly once, before any
  tier, and no tier re-derives a rule or reads the raw binary again.

  WHAT THIS UNIT OWNS is the module-shape rules and the ORDER the phases
  run in — imports, the function section's type uses, tables, memories,
  tags, globals, element and data segments, the start function, and the
  export list — plus the assembly of TWasmIrModule. Everything else is
  delegated and never re-implemented here:

    - Wasm.Validator.Types  — the type section, canonicalisation, and the
                              matching relation (`valid-type`)
    - Wasm.Validator.&Const — constant expressions and their IR
                              (`valid-constant`)
    - Wasm.Validator.Body   — the fused per-function walk (`valid-func`)

  THE PHASE ORDER IS NOT ARBITRARY (`valid-module`, and the Track B design
  document's §6.1). Types must exist before anything names them; imports
  must be placed before an index space is indexed; globals are sequential
  among themselves, because "Globals … are not recursive but evaluated
  sequentially, such that each constant expressions only has access to
  imported or previously defined globals" (`valid-module`); and C.REFS
  must be complete before the first function body is walked, or a valid
  module gets rejected for an `undeclared function reference` that was
  declared by an initialiser the walk had not reached yet.

  C.REFS IS THE ONE PLACE TWO UNITS HAVE TO BE UNIONED.
  Wasm.Validator.Body.BuildDeclaredFuncSet deliberately covers only what a
  caller holding the decoded model alone can see (element segments in the
  funcidx-vector form and the export list — NOT the start function, which
  the spec excludes from C.REFS); `ref.func`
  inside a CONSTANT EXPRESSION also declares a function, and only
  Wasm.Validator.&Const can read those. Every ValidateConstExpr call below
  appends to one accumulator, and the union of the two is what goes into
  the TWasmIndexSpaces record every body walk reads.

  Spec pin: the 3.0 draft at `d7b37e4170d8315f2f1283aed4e8076591a9a333`
  (ADR-0004; `wasm-mcp` 0.2.16 `spec_version`). Anchors are cited per
  rule. Canonical message prefixes come from Wasm.Validator.Types and are
  never re-spelled; the three declared below are the ones that unit does
  not carry, each with one raise site.

  NOTE ON THE MCP AND NUMERIC BOUNDS. The validation clauses for limits
  are SpecTec-generated: `valid-limits`, `valid-memtype`, and
  `valid-tabletype` serve prose and a formal-rule reference
  (`Limits_ok`, `Memtype_ok`, `Tabletype_ok`) but no numbers, so the
  bounds below are transcriptions of those formal rules and are marked
  UNCONFIRMED where the MCP could not confirm them. What the MCP DOES
  confirm and what the bounds are built from: the page size is 64 Ki
  (`page-size`, `valid-meminst`: "The length of b* must equal m
  multiplied by the page size 64 Ki"), and an address type is i32 or i64
  (`syntax-addrtype`). }
unit Wasm.Validator;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator.&Const,
  Wasm.Validator.Body,
  Wasm.Validator.Types;

const
  { The i64 counterpart of MSG_MEMORY_SIZE_LIMIT (Wasm.Validator.Types),
    which spells the i32 bound in full and would therefore be the WRONG
    prefix for an i64 memory. UNCONFIRMED: the shared part
    ("memory size must be at most") is HIGH, the parenthesised size is a
    transcription of 2^48 pages. The byte figure is the page count times
    the page size — 2^48 * 64 Ki = 2^64 bytes = 16 EiB, which is the
    whole i64 address space and exactly what MEM_PAGE_LIMIT's derivation
    says it should be; it read `4EiB` until Track B's second review.
    One raise site. }
  MSG_MEMORY64_SIZE_LIMIT =
    'memory size must be at most 281474976710656 pages (16EiB)';

  { Tables have the same shape of rule as memories (`Tabletype_ok`), but
    no canonical phrase is known for it: with a u32-encoded minimum the
    reference interpreter cannot construct the case, whereas this
    project's decoder reads every limits form as u64 (Track A) and so
    can. UNCONFIRMED, one raise site. }
  MSG_TABLE_SIZE_LIMIT = 'table size must be at most';

  { `valid-tag` / `syntax-tagtype`: "The result type is empty for
    exception tags". UNCONFIRMED as a prefix, one raise site. }
  MSG_TAG_RESULT_TYPE = 'non-empty tag result type';

{ --- public façade over the type-section key format (A7 / M3) -------------

  docs/architecture makes Wasm.Validator the only public face of the
  validator stack; the rec-group key grammar is Wasm.Validator.Types'
  private business, so the runtime and the .wast harness read it THROUGH
  these rather than reaching into that unit.

  The KEY_* grammar below is DUPLICATED from Wasm.Validator.Types'
  SerialiseGroup and MUST stay in lock-step with it. It is duplicated here,
  not shared, because those constants live in that unit's implementation
  section and the layering forbids exporting them; a mismatch is caught the
  moment interning rejects a module the validator accepted. }

{ The member count of a rolled rec-group key — its leading little-endian
  u32. Re-exported here so Wasm.Runtime.Store need not depend on
  Wasm.Validator.Types for it. }
function GroupMemberCount(const AKey: TWasmBytes): UInt32;

{ M3: rewrite a rec-group key's OUT-OF-GROUP references from module-local
  canonical ids to engine ids, using ACanonToEngine (indexed by module-local
  canonical id). In-group references are recursive-relative and already
  structural, so they are left untouched. The result is a STRUCTURAL key:
  two modules that define the same closed type after a different number of
  preceding rec groups produce byte-identical rewritten keys and therefore
  intern to the same engine id. Lengths are unchanged (a u32 stays a u32),
  so the rewrite is an in-place edit of a copy. }
function RewriteGroupKeyRefs(const AKey: TWasmBytes;
  const ACanonToEngine: array of UInt32): TWasmBytes;

{ Validates AModule — which ABytes must be the buffer it was decoded from
  — and returns the lowered IR. The caller owns the result.

  Raises EWasmValidationError for a module that is not well-typed and
  EWasmDecodeError for the binary-grammar violations only a function-body
  walk can see (Wasm.Validator.Body's header lists them). The distinction
  is load-bearing: malformed and invalid are different answers to a host. }
function ValidateModule(const AModule: TWasmModule;
  const ABytes: TWasmBytes): TWasmIrModule;

implementation

const
  { `Memtype_ok`: the limits of an `at limits PAGE` memory are checked
    against 2^|at| / 64 Ki — the number of pages that fits the address
    space. 2^32 / 2^16 = 2^16 for i32, 2^64 / 2^16 = 2^48 for i64.
    UNCONFIRMED (formal rule, see the unit header). }
  MEM_PAGE_LIMIT: array[TWasmAddrType] of UInt64 = (
    UInt64(65536),
    UInt64(281474976710656)
  );

  { `Tabletype_ok`: a table's limits are checked against 2^|at| - 1 — one
    fewer than the address space, because a table of exactly 2^32 entries
    has no representable last index. UNCONFIRMED (formal rule).
    The i64 bound is High(UInt64), so it can never fire for an i64 table;
    it is spelled out rather than special-cased so the rule reads the same
    for both address types. }
  TABLE_SIZE_LIMIT: array[TWasmAddrType] of UInt64 = (
    UInt64($FFFFFFFF),
    UInt64($FFFFFFFFFFFFFFFF)
  );

  { The rec-group key grammar, DUPLICATED from Wasm.Validator.Types'
    SerialiseGroup (see the interface note). Keep in lock-step. }
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

{ --- rec-group key façade (M3) ------------------------------------------ }

function GroupMemberCount(const AKey: TWasmBytes): UInt32;
begin
  if Length(AKey) < 4 then
    raise EWasmError.Create('internal: malformed rec-group key');
  Result := UInt32(AKey[0]) or (UInt32(AKey[1]) shl 8) or
    (UInt32(AKey[2]) shl 16) or (UInt32(AKey[3]) shl 24);
end;

function RewriteGroupKeyRefs(const AKey: TWasmBytes;
  const ACanonToEngine: array of UInt32): TWasmBytes;
var
  Buf: TWasmBytes;
  P: Integer;

  procedure Need(const ACount: Integer);
  begin
    if P + ACount > Length(Buf) then
      raise EWasmError.Create('internal: rec-group key truncated');
  end;

  function ReadU32: UInt32;
  begin
    Need(4);
    Result := UInt32(Buf[P]) or (UInt32(Buf[P + 1]) shl 8) or
      (UInt32(Buf[P + 2]) shl 16) or (UInt32(Buf[P + 3]) shl 24);
    Inc(P, 4);
  end;

  { Rewrite the u32 at position APos (already read) in place. }
  procedure MapCanonAt(const APos: Integer; const ALocal: UInt32);
  var
    Engine: UInt32;
  begin
    if ALocal >= UInt32(Length(ACanonToEngine)) then
      raise EWasmError.Create(
        'internal: rec-group key names an out-of-range out-of-group type');
    Engine := ACanonToEngine[ALocal];
    { High(UInt32) is the "not interned yet" marker the caller seeds the
      map with; an out-of-group reference must point at an EARLIER group,
      which is always already interned, so hitting it is an invariant
      violation, not a legal state. }
    if Engine = High(UInt32) then
      raise EWasmError.Create(
        'internal: rec-group key names an un-interned out-of-group type');
    Buf[APos] := Byte(Engine and $FF);
    Buf[APos + 1] := Byte((Engine shr 8) and $FF);
    Buf[APos + 2] := Byte((Engine shr 16) and $FF);
    Buf[APos + 3] := Byte((Engine shr 24) and $FF);
  end;

  procedure ReadByte;
  begin
    Need(1);
    Inc(P);
  end;

  { A concrete type use (supertype list, or a concrete ref's heap type):
    tag byte + u32. Only KEY_HEAP_CANON is out-of-group and rewritten. }
  procedure RewriteTypeUse;
  var
    Tag: Byte;
    Pos: Integer;
    Local: UInt32;
  begin
    Need(1);
    Tag := Buf[P];
    Inc(P);
    Pos := P;
    Local := ReadU32;
    if Tag = KEY_HEAP_CANON then
      MapCanonAt(Pos, Local);
  end;

  procedure RewriteValType;
  var
    Kind: Byte;
    HeapKind: Byte;
    Pos: Integer;
    Local: UInt32;
  begin
    Need(1);
    Kind := Buf[P];
    Inc(P);
    case Kind of
      KEY_VAL_NUM:
        ReadByte;
      KEY_VAL_VEC:
        ;
      KEY_VAL_REF:
        begin
          ReadByte;               { nullability }
          Need(1);
          HeapKind := Buf[P];
          Inc(P);
          case HeapKind of
            KEY_HEAP_ABS:
              ReadByte;
            KEY_HEAP_REC_REL:
              ReadU32;
            KEY_HEAP_CANON:
              begin
                Pos := P;
                Local := ReadU32;
                MapCanonAt(Pos, Local);
              end;
          else
            raise EWasmError.Create('internal: bad heap tag in rec-group key');
          end;
        end;
    else
      raise EWasmError.Create('internal: bad value tag in rec-group key');
    end;
  end;

  procedure RewriteFieldType;
  var
    Storage: Byte;
  begin
    ReadByte;                     { mutability }
    Need(1);
    Storage := Buf[P];
    Inc(P);
    if Storage = KEY_STORAGE_PACKED then
      ReadByte
    else
      RewriteValType;
  end;

var
  Count: UInt32;
  NSuper: UInt32;
  NParams: UInt32;
  NResults: UInt32;
  NFields: UInt32;
  CompKind: Byte;
  I: UInt32;
  J: UInt32;
begin
  SetLength(Buf, Length(AKey));
  if Length(AKey) > 0 then
    Move(AKey[0], Buf[0], Length(AKey));

  P := 0;
  Count := ReadU32;
  I := 0;
  while I < Count do
  begin
    ReadByte;                     { IsFinal }
    NSuper := ReadU32;
    J := 0;
    while J < NSuper do
    begin
      RewriteTypeUse;
      Inc(J);
    end;

    Need(1);
    CompKind := Buf[P];
    Inc(P);
    case CompKind of
      KEY_COMP_FUNC:
        begin
          NParams := ReadU32;
          J := 0;
          while J < NParams do
          begin
            RewriteValType;
            Inc(J);
          end;
          NResults := ReadU32;
          J := 0;
          while J < NResults do
          begin
            RewriteValType;
            Inc(J);
          end;
        end;
      KEY_COMP_STRUCT:
        begin
          NFields := ReadU32;
          J := 0;
          while J < NFields do
          begin
            RewriteFieldType;
            Inc(J);
          end;
        end;
      KEY_COMP_ARRAY:
        RewriteFieldType;
    else
      raise EWasmError.Create('internal: bad comp tag in rec-group key');
    end;
    Inc(I);
  end;

  Result := Buf;
end;

type
  { A record rather than a class, matching TBodyWalker: it is created on
    the stack of the one function that uses it, and it owns nothing a
    destructor would have to release. }
  TModuleValidator = record
  private
    FModule: TWasmModule;
    FBytes: TWasmBytes;
    FTypes: TWasmTypeContext;
    FConst: TWasmConstContext;
    FFuncRefs: TWasmConstFuncRefs;

    { Index spaces, IMPORTS FIRST — the numbering every index in exports,
      segments, and instructions refers to. Built in one pre-pass, which
      is what `valid-module` says a validator may do: "All types needed to
      construct C can easily be determined from a simple pre-pass over the
      module that does not perform any actual validation."

      ONE record, and the SAME record every function body reads
      (Wasm.Validator.Body's TWasmIndexSpaces): the module-shape rules
      here and the body walk want the identical spaces, and building
      them twice — once here, once per body — was both wasted work and
      two places for the numbering to drift. }
    FSpaces: TWasmIndexSpaces;
    FFuncImports: UInt32;
    FTableImports: UInt32;
    FMemImports: UInt32;
    FGlobalImports: UInt32;
    FTagImports: UInt32;

    { Seen export names, for the uniqueness rule. A stored hash in front
      of the string comparison, then a linear scan — the same shape as
      Wasm.Validator.Types' intern table, and for the same reason: an
      export list is small, this runs once, and it keeps the RTL's string
      containers out of the validator. }
    FExportHashes: array of UInt32;
    FExportNames: array of string;
    FExportCount: Integer;

    procedure ValErr(const APrefix, AContext: string);

    procedure BuildSpaces;

    procedure CheckRefType(const A: TWasmRefType);
    procedure CheckValType(const A: TWasmValueType);
    procedure CheckLimits(const A: TWasmLimits; const ABound: UInt64;
      const ABoundPrefix, AWhat: string);
    procedure CheckTableType(const A: TWasmTableType; const AWhat: string);
    procedure CheckMemType(const A: TWasmMemType; const AWhat: string);
    procedure CheckGlobalType(const A: TWasmGlobalType);
    function CheckFuncTypeUse(const ATypeIndex: UInt32;
      const AWhat: string): TWasmFuncType;
    procedure CheckTagType(const A: TWasmTagType; const AWhat: string);

    function AddrValType(const A: TWasmAddrType): TWasmValueType;
    function ConstExpr(const ASpan: TWasmSpan;
      const AExpected: TWasmValueType;
      const AGlobalLimit: UInt32): TWasmIrInitExpr;

    function AddExportName(const AName: string): Boolean;

    procedure ValidateImports;
    procedure ValidateFunctions;
    procedure ValidateTables(const AIr: TWasmIrModule);
    procedure ValidateMemories;
    procedure ValidateTags;
    procedure ValidateGlobals(const AIr: TWasmIrModule);
    procedure ValidateElements(const AIr: TWasmIrModule);
    procedure ValidateDatas(const AIr: TWasmIrModule);
    procedure ValidateStart;
    procedure ValidateExports(const AIr: TWasmIrModule);
    function BuildDeclaredFuncs: TWasmDeclaredFuncs;
    procedure ValidateBodies(const AIr: TWasmIrModule;
      const ADeclared: TWasmDeclaredFuncs);
    procedure FillTypeSnapshots(const AIr: TWasmIrModule);
    procedure FillIndexSpaceSnapshots(const AIr: TWasmIrModule);
  public
    function Run(const AModule: TWasmModule;
      const ABytes: TWasmBytes): TWasmIrModule;
  end;

{ --- diagnostics --------------------------------------------------------- }

procedure TModuleValidator.ValErr(const APrefix, AContext: string);
begin
  if AContext = '' then
    raise EWasmValidationError.Create(APrefix);
  raise EWasmValidationError.Create(APrefix + ': ' + AContext);
end;

{ --- index spaces -------------------------------------------------------- }

procedure TModuleValidator.BuildSpaces;
begin
  { The pre-pass, delegated in full: Wasm.Validator.Body owns the index
    spaces because the body walk is what indexes them, and building them
    there rather than duplicating the import walk here is what keeps the
    numbering single-sourced. DeclaredFuncs comes back as
    BuildDeclaredFuncSet's partial answer and is REPLACED below, once the
    constant expressions have contributed theirs (see BuildDeclaredFuncs
    and this unit's header on C.REFS). }
  BuildIndexSpaces(FModule, FSpaces);

  FFuncImports := UInt32(FModule.ImportCountOfKind(wxkFunc));
  FTableImports := UInt32(FModule.ImportCountOfKind(wxkTable));
  FMemImports := UInt32(FModule.ImportCountOfKind(wxkMem));
  FGlobalImports := UInt32(FModule.ImportCountOfKind(wxkGlobal));
  FTagImports := UInt32(FModule.ImportCountOfKind(wxkTag));
end;

{ --- type forms ---------------------------------------------------------- }

{ `valid-heaptype`: an abstract heap type is always well formed; a
  concrete one must name a defined type. CanonIdOf is the project's single
  chokepoint for that bound and raises `unknown type`. }
procedure TModuleValidator.CheckRefType(const A: TWasmRefType);
begin
  if not A.Heap.IsAbstract then
    FTypes.CanonIdOf(A.Heap.TypeIndex);
end;

{ `valid-valtype`: number and vector types are universally valid
  ("Simple types, such as number types are universally valid",
  `valid/types-types`), so only the reference case has anything to
  check. }
procedure TModuleValidator.CheckValType(const A: TWasmValueType);
begin
  if A.Kind = wvkRef then
    CheckRefType(A.Ref);
end;

{ `valid-limits`: "Limits must have meaningful bounds that are within a
  given range" — `Limits_ok` is n <= m <= k, so the minimum must not
  exceed the maximum and neither may exceed the range bound the enclosing
  table or memory rule supplies. }
procedure TModuleValidator.CheckLimits(const A: TWasmLimits;
  const ABound: UInt64; const ABoundPrefix, AWhat: string);
begin
  { Every bound is a u64 in the ENCODING for both address types (Track A),
    so they are rendered with IntToStr's QWord overload rather than through
    Format's %u, which would narrow them. }
  if A.HasMax and (A.Min > A.Max) then
    ValErr(MSG_SIZE_MINIMUM_GT_MAXIMUM,
      Format('%s has minimum %s and maximum %s',
        [AWhat, IntToStr(A.Min), IntToStr(A.Max)]));
  if A.Min > ABound then
    ValErr(ABoundPrefix,
      Format('%s has minimum %s, above the limit %s for its address type',
        [AWhat, IntToStr(A.Min), IntToStr(ABound)]));
  if A.HasMax and (A.Max > ABound) then
    ValErr(ABoundPrefix,
      Format('%s has maximum %s, above the limit %s for its address type',
        [AWhat, IntToStr(A.Max), IntToStr(ABound)]));
end;

{ `valid-tabletype` (`Tabletype_ok`): the element type must be a
  well-formed reference type and the limits must be within the address
  type's range. }
procedure TModuleValidator.CheckTableType(const A: TWasmTableType;
  const AWhat: string);
begin
  CheckRefType(A.RefType);
  CheckLimits(A.Limits, TABLE_SIZE_LIMIT[A.Limits.AddrType],
    MSG_TABLE_SIZE_LIMIT, AWhat);
end;

{ `valid-memtype` (`Memtype_ok`). }
procedure TModuleValidator.CheckMemType(const A: TWasmMemType;
  const AWhat: string);
var
  Prefix: string;
begin
  if A.Limits.AddrType = watI64 then
    Prefix := MSG_MEMORY64_SIZE_LIMIT
  else
    Prefix := MSG_MEMORY_SIZE_LIMIT;
  CheckLimits(A.Limits, MEM_PAGE_LIMIT[A.Limits.AddrType], Prefix, AWhat);
end;

{ `valid-globaltype`: the value type must be well formed; mutability is
  unconstrained. No context string, unlike the other checkers — the only
  thing that can fail is a concrete heap type, and CanonIdOf's own message
  already names the offending type index. }
procedure TModuleValidator.CheckGlobalType(const A: TWasmGlobalType);
begin
  CheckValType(A.ValueType);
end;

{ `valid-typeuse` + `valid-func`: the index must name a defined type
  ("unknown type") and that type must expand to a FUNCTION type
  ("Functions func are classified by defined types that expand to function
  types", `valid-func`), which is a typing failure rather than a missing
  definition. }
function TModuleValidator.CheckFuncTypeUse(const ATypeIndex: UInt32;
  const AWhat: string): TWasmFuncType;
var
  Comp: TWasmCompType;
begin
  Comp := FTypes.Expand(ATypeIndex);
  if Comp.Kind <> wckFunc then
    ValErr(MSG_TYPE_MISMATCH,
      Format('%s names type %u, which does not expand to a function type',
        [AWhat, ATypeIndex]));
  Result := Comp.Func;
end;

{ `valid-tag` / `valid-tagtype`: "Tags are classified by their tag types,
  which are defined types expanding to function types" and
  "The result type is empty for exception tags" (`syntax-tagtype`). }
procedure TModuleValidator.CheckTagType(const A: TWasmTagType;
  const AWhat: string);
var
  Ft: TWasmFuncType;
begin
  Ft := CheckFuncTypeUse(A.TypeIndex, AWhat);
  if Length(Ft.Results) <> 0 then
    ValErr(MSG_TAG_RESULT_TYPE,
      Format('%s names type %u, whose function type has %d result(s)',
        [AWhat, A.TypeIndex, Length(Ft.Results)]));
end;

{ --- constant expressions ------------------------------------------------ }

{ An active segment's offset is typed at the ADDRESS TYPE of the table or
  memory it targets, not at i32: memory64 and table64 make that
  pervasive (`Elemmode_ok/active`, `Datamode_ok`). }
function TModuleValidator.AddrValType(
  const A: TWasmAddrType): TWasmValueType;
begin
  if A = watI64 then
    Result := MakeNumValueType(wntI64)
  else
    Result := MakeNumValueType(wntI32);
end;

{ The one call site for Wasm.Validator.&Const. AGlobalLimit is the caller's
  to choose because `valid-constant` constrains the CONTEXT, not the
  instruction: "Constant expressions occurring in globals are further
  constrained in that contained GLOBAL.GET instructions are only allowed
  to refer to imported or previously defined globals. Constant expressions
  occurring in tables may only have GLOBAL.GET instructions that refer to
  imported globals." }
function TModuleValidator.ConstExpr(const ASpan: TWasmSpan;
  const AExpected: TWasmValueType;
  const AGlobalLimit: UInt32): TWasmIrInitExpr;
begin
  FConst.GlobalLimit := AGlobalLimit;
  Result := ValidateConstExpr(FTypes, FConst, FBytes, ASpan,
    AExpected, FFuncRefs);
end;

{ --- export names -------------------------------------------------------- }

{ FNV-1a, 32-bit — a hash, not a checksum, so a hit is confirmed by
  comparing the name. Wrapping IS the algorithm and Shared.inc turns
  overflow and range checking on for non-production builds, hence the
  local suppression (the same shape as Wasm.Validator.Types' KeyHash). }
{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}
function ExportNameHash(const AName: string): UInt32;
var
  I: Integer;
begin
  Result := UInt32($811C9DC5);
  for I := 1 to Length(AName) do
  begin
    Result := Result xor UInt32(Byte(AName[I]));
    Result := Result * UInt32($01000193);
  end;
end;
{$POP}

{ False when AName was already registered. }
function TModuleValidator.AddExportName(const AName: string): Boolean;
var
  I: Integer;
  Hash: UInt32;
begin
  Hash := ExportNameHash(AName);
  for I := 0 to FExportCount - 1 do
    if (FExportHashes[I] = Hash) and (FExportNames[I] = AName) then
      Exit(False);

  if FExportCount >= Length(FExportHashes) then
  begin
    SetLength(FExportHashes, (FExportCount + 1) * 2);
    SetLength(FExportNames, Length(FExportHashes));
  end;
  FExportHashes[FExportCount] := Hash;
  FExportNames[FExportCount] := AName;
  Inc(FExportCount);
  Result := True;
end;

{ --- phase 2: imports ---------------------------------------------------- }

{ `valid-importdesc`: each descriptor must be a valid external type. Import
  NAMES are deliberately not checked for uniqueness — "Unlike export names,
  import names are not necessarily unique. It is possible to import the
  same module/item name pair multiple times" (`syntax-importdesc`). }
procedure TModuleValidator.ValidateImports;
var
  I: Integer;
  Imp: TWasmImport;
  What: string;
begin
  for I := 0 to FModule.ImportCount - 1 do
  begin
    Imp := FModule.Imports[I];
    What := Format('import %d ("%s"."%s")',
      [I, Imp.ModuleName, Imp.Name]);
    case Imp.Kind of
      wxkFunc: CheckFuncTypeUse(Imp.FuncTypeIndex, What);
      wxkTable: CheckTableType(Imp.Table, What);
      wxkMem: CheckMemType(Imp.Mem, What);
      wxkGlobal: CheckGlobalType(Imp.Global);
      wxkTag: CheckTagType(Imp.Tag, What);
    end;
  end;
end;

{ --- phase 3: the function section --------------------------------------- }

procedure TModuleValidator.ValidateFunctions;
var
  I: Integer;
begin
  for I := 0 to FModule.FunctionTypeIndexCount - 1 do
    CheckFuncTypeUse(FModule.FunctionTypeIndices[I],
      Format('function %d', [Integer(FFuncImports) + I]));
end;

{ --- phase 4: tables ----------------------------------------------------- }

{ `valid-table`. Two forms, and the difference is the whole point of the
  3.0 table-with-initialiser addition: WITHOUT an init expression the
  element type must have a default value (`aux-default` — nullable
  references and number types do, non-nullable references do not), and
  WITH one the expression must be constant and yield the element type.
  A table initialiser sees only IMPORTED globals (`valid-constant`). }
procedure TModuleValidator.ValidateTables(const AIr: TWasmIrModule);
var
  I: Integer;
  Table: TWasmTable;
  What: string;
begin
  SetLength(AIr.TableInits, FModule.TableCount);
  for I := 0 to FModule.TableCount - 1 do
  begin
    Table := FModule.Tables[I];
    What := Format('table %d', [Integer(FTableImports) + I]);
    CheckTableType(Table.TableType, What);

    { TableInits is POSITIONAL — one entry per defined table — so a table
      without an initialiser still occupies its slot, and Wasm.Ir's
      absent-initialiser convention says such an entry is spelled empty:
      Length(Code) = 0 AND ResultReg = IR_NO_REG. SetLength zeroes the
      record, which would leave ResultReg reading as register 0, so the
      sentinel is written explicitly. A consumer discriminates on the
      code length; the sentinel is what it finds if it reaches for the
      register anyway. }
    AIr.TableInits[I].ResultReg := IR_NO_REG;

    if Table.HasInit then
      AIr.TableInits[I] := ConstExpr(Table.Init,
        MakeRefValueType(Table.TableType.RefType), FGlobalImports)
    else if not IsDefaultableValType(
      MakeRefValueType(Table.TableType.RefType)) then
      ValErr(MSG_TYPE_MISMATCH,
        Format('%s has non-defaultable element type %s and no initialiser',
          [What, Table.TableType.RefType.Describe]));
  end;
end;

{ --- phase 5: memories --------------------------------------------------- }

procedure TModuleValidator.ValidateMemories;
var
  I: Integer;
begin
  for I := 0 to FModule.MemoryCount - 1 do
    CheckMemType(FModule.Memories[I],
      Format('memory %d', [Integer(FMemImports) + I]));
end;

{ --- phase 6: tags ------------------------------------------------------- }

procedure TModuleValidator.ValidateTags;
var
  I: Integer;
begin
  for I := 0 to FModule.TagCount - 1 do
    CheckTagType(FModule.Tags[I],
      Format('tag %d', [Integer(FTagImports) + I]));
end;

{ --- phase 7: globals ---------------------------------------------------- }

{ `valid-global` / `valid-globalseq`: "Sequences of globals are handled
  incrementally, such that each definition has access to previous
  definitions." So defined global i sees the imported globals plus the
  globals defined before it, and nothing else — a self-reference or a
  forward reference is out of the constrained context and reads as
  `unknown global`. }
procedure TModuleValidator.ValidateGlobals(const AIr: TWasmIrModule);
var
  I: Integer;
  Global: TWasmGlobal;
begin
  SetLength(AIr.GlobalInits, FModule.GlobalCount);
  for I := 0 to FModule.GlobalCount - 1 do
  begin
    Global := FModule.Globals[I];
    CheckGlobalType(Global.GlobalType);
    AIr.GlobalInits[I] := ConstExpr(Global.Init,
      Global.GlobalType.ValueType, FGlobalImports + UInt32(I));
  end;
end;

{ --- phase 8: element segments ------------------------------------------- }

{ `valid-elem` / `valid-elemmode`. The segment's reference type must be
  well formed and every item must be a constant expression of that type;
  in ACTIVE mode the table index must exist, the table's element type must
  subsume the segment's (`match-reftype`), and the offset must be a
  constant expression of the TABLE's address type.

  The funcidx-vector form is normalised through MakeRefFuncInitExpr into
  the same one-instruction `ref.func` expression the expression form
  produces, so instantiation has exactly one code path and the ref.func
  typing rule lives in one place. }
procedure TModuleValidator.ValidateElements(const AIr: TWasmIrModule);
var
  I, J: Integer;
  Seg: TWasmElemSegment;
  Elem: TWasmIrElemSegment;
  ItemType: TWasmValueType;
  Table: TWasmTableType;
  Full: UInt32;
  What: string;
begin
  Full := UInt32(Length(FSpaces.Globals));
  SetLength(AIr.Elems, FModule.ElementCount);
  for I := 0 to FModule.ElementCount - 1 do
  begin
    Seg := FModule.Elements[I];
    What := Format('element segment %d', [I]);
    CheckRefType(Seg.RefType);
    ItemType := MakeRefValueType(Seg.RefType);

    Elem := Default(TWasmIrElemSegment);
    Elem.RefType := Seg.RefType;
    Elem.TableIndex := Seg.TableIndex;
    case Seg.Mode of
      wemActive: Elem.Mode := iremActive;
      wemPassive: Elem.Mode := iremPassive;
      wemDeclarative: Elem.Mode := iremDeclarative;
    end;

    { RULE ORDER, and it is the reason the items come first. `Elem_ok`
      reads the segment's ITEMS against its reference type and only then
      hands the mode to `Elemmode_ok`, so a segment that is both
      ill-typed in its items and pointed at a table that does not exist
      must report the ITEM failure. Checking the active-mode table bound
      first — which is what this did — reported `unknown table` for it,
      and error precedence is conformance surface the .wast harness
      asserts on. }
    if Seg.UsesExprs then
    begin
      SetLength(Elem.Items, Length(Seg.InitExprs));
      for J := 0 to High(Seg.InitExprs) do
        Elem.Items[J] := ConstExpr(Seg.InitExprs[J], ItemType, Full);
    end
    else
    begin
      { GlobalLimit is not consulted by MakeRefFuncInitExpr — the funcidx
        form has no `global.get` to constrain — so nothing is set here.
        Assigning it would imply a scoping rule that is not in force. }
      SetLength(Elem.Items, Length(Seg.FuncIndices));
      for J := 0 to High(Seg.FuncIndices) do
        Elem.Items[J] := MakeRefFuncInitExpr(FTypes, FConst,
          Seg.FuncIndices[J], ItemType, FFuncRefs);
    end;

    if Seg.Mode = wemActive then
    begin
      if Seg.TableIndex >= UInt32(Length(FSpaces.Tables)) then
        ValErr(UnknownIndex(MSG_UNKNOWN_TABLE, Seg.TableIndex),
          Format('%s targets table %u, but only %d table(s) exist',
            [What, Seg.TableIndex, Length(FSpaces.Tables)]));
      Table := FSpaces.Tables[Seg.TableIndex];
      if not FTypes.MatchesRefType(Seg.RefType, Table.RefType) then
        ValErr(MSG_TYPE_MISMATCH,
          Format('%s has element type %s, which does not match table %u''s '
            + 'element type %s',
            [What, Seg.RefType.Describe, Seg.TableIndex,
             Table.RefType.Describe]));
      Elem.Offset := ConstExpr(Seg.Offset,
        AddrValType(Table.Limits.AddrType), Full);
    end;

    AIr.Elems[I] := Elem;
  end;
end;

{ --- phase 9: data segments ---------------------------------------------- }

{ `valid-data` / `valid-datamode`: in active mode the memory index must
  exist and the offset must be a constant expression of the MEMORY's
  address type. The payload bytes stay a borrowed span (ADR-0003). }
procedure TModuleValidator.ValidateDatas(const AIr: TWasmIrModule);
var
  I: Integer;
  Seg: TWasmDataSegment;
  Data: TWasmIrDataSegment;
  Full: UInt32;
begin
  Full := UInt32(Length(FSpaces.Globals));
  SetLength(AIr.Datas, FModule.DataSegmentCount);
  for I := 0 to FModule.DataSegmentCount - 1 do
  begin
    Seg := FModule.DataSegments[I];

    Data := Default(TWasmIrDataSegment);
    Data.MemIndex := Seg.MemIndex;
    Data.Bytes := MakeIrSpan(Seg.Bytes.Offset, Seg.Bytes.Size);
    if Seg.Mode = wdmActive then
      Data.Mode := irdmActive
    else
      Data.Mode := irdmPassive;

    if Seg.Mode = wdmActive then
    begin
      if Seg.MemIndex >= UInt32(Length(FSpaces.Memories)) then
        ValErr(UnknownMemoryPrefix(Seg.MemIndex),
          Format('data segment %d targets it, but only %d memory '
            + '(memories) exist', [I, Length(FSpaces.Memories)]));
      Data.Offset := ConstExpr(Seg.Offset,
        AddrValType(FSpaces.Memories[Seg.MemIndex].Limits.AddrType), Full);
    end;

    AIr.Datas[I] := Data;
  end;
end;

{ --- phase 10: the start function ---------------------------------------- }

{ `valid-start` (`Start_ok`): the index must name a function and that
  function's type must be [] -> []. The two failures get different
  prefixes because they are different questions — a missing function is
  `unknown function`, a function of the wrong shape is `start function`. }
procedure TModuleValidator.ValidateStart;
var
  Ft: TWasmFuncType;
begin
  if not FModule.HasStart then
    Exit;

  if FModule.StartFuncIndex >= UInt32(Length(FSpaces.FuncTypes)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_FUNCTION, FModule.StartFuncIndex),
      Format('start function %u, but only %d function(s) exist',
        [FModule.StartFuncIndex, Length(FSpaces.FuncTypes)]));

  Ft := CheckFuncTypeUse(FSpaces.FuncTypes[FModule.StartFuncIndex],
    Format('start function %u', [FModule.StartFuncIndex]));
  if (Length(Ft.Params) <> 0) or (Length(Ft.Results) <> 0) then
    ValErr(MSG_START_FUNCTION,
      Format('%u has %d parameter(s) and %d result(s), but must have none '
        + 'of either', [FModule.StartFuncIndex, Length(Ft.Params),
        Length(Ft.Results)]));
end;

{ --- phase 11: exports --------------------------------------------------- }

{ `valid-exportdesc`: the index must exist in the named space. Plus the
  rule that lives in the module rule rather than the descriptor's:
  "Each export is labeled by a unique name" (`syntax-exportdesc`). }
procedure TModuleValidator.ValidateExports(const AIr: TWasmIrModule);
var
  I: Integer;
  Exp: TWasmExport;
  Limit: Integer;
  Prefix, Space: string;
begin
  SetLength(AIr.ExportList, FModule.ExportCount);
  for I := 0 to FModule.ExportCount - 1 do
  begin
    Exp := FModule.&Exports[I];

    case Exp.Kind of
      wxkFunc:
        begin
          Limit := Length(FSpaces.FuncTypes);
          Prefix := UnknownIndex(MSG_UNKNOWN_FUNCTION, Exp.Index);
          Space := 'function';
        end;
      wxkTable:
        begin
          Limit := Length(FSpaces.Tables);
          Prefix := UnknownIndex(MSG_UNKNOWN_TABLE, Exp.Index);
          Space := 'table';
        end;
      wxkMem:
        begin
          Limit := Length(FSpaces.Memories);
          Prefix := UnknownMemoryPrefix(Exp.Index);
          Space := 'memory';
        end;
      wxkGlobal:
        begin
          Limit := Length(FSpaces.Globals);
          Prefix := UnknownIndex(MSG_UNKNOWN_GLOBAL, Exp.Index);
          Space := 'global';
        end;
    else
      Limit := Length(FSpaces.Tags);
      Prefix := UnknownIndex(MSG_UNKNOWN_TAG, Exp.Index);
      Space := 'tag';
    end;

    if Exp.Index >= UInt32(Limit) then
      ValErr(Prefix,
        Format('export "%s" names %s %u, but only %d exist',
          [Exp.Name, Space, Exp.Index, Limit]));

    if not AddExportName(Exp.Name) then
      ValErr(MSG_DUPLICATE_EXPORT_NAME,
        Format('"%s" is exported more than once', [Exp.Name]));

    AIr.ExportList[I].Name := Exp.Name;
    AIr.ExportList[I].Kind := Exp.Kind;
    AIr.ExportList[I].Index := Exp.Index;
  end;
end;

{ --- C.REFS -------------------------------------------------------------- }

{ `context`: C.REFS is "the list of function indices that occur in the
  module outside functions and can hence be used to form references inside
  them". BuildDeclaredFuncSet covers what the decoded model alone shows;
  the `ref.func` indices every constant expression named were accumulated
  into FFuncRefs by the phases above, and the union is the set the body
  walk checks `undeclared function reference` against. Missing the union
  rejects valid modules — that is the failure mode this function exists
  to prevent. }
function TModuleValidator.BuildDeclaredFuncs: TWasmDeclaredFuncs;
var
  I: Integer;
begin
  Result := BuildDeclaredFuncSet(FModule);
  if Length(Result) <> Length(FSpaces.FuncTypes) then
    SetLength(Result, Length(FSpaces.FuncTypes));
  for I := 0 to High(FFuncRefs) do
    if FFuncRefs[I] < UInt32(Length(Result)) then
      Result[FFuncRefs[I]] := True;
end;

{ --- phase 12: function bodies ------------------------------------------- }

procedure TModuleValidator.ValidateBodies(const AIr: TWasmIrModule;
  const ADeclared: TWasmDeclaredFuncs);
var
  I: Integer;
begin
  { The completed C.REFS replaces the partial set BuildSpaces left in the
    record, and from here the SAME index spaces reach every body — no
    rebuilding per function. }
  FSpaces.DeclaredFuncs := ADeclared;
  SetLength(AIr.Functions, FModule.CodeEntryCount);
  for I := 0 to FModule.CodeEntryCount - 1 do
    AIr.Functions[I] := ValidateFunctionBody(FModule, FTypes, FBytes,
      FModule.FunctionTypeIndices[I], FModule.CodeEntries[I], FSpaces);
end;

{ --- IR assembly --------------------------------------------------------- }

{ Wasm.Ir declares its OWN canonical-type record, TWasmIrCanonType — it
  depends on Wasm.Core alone and cannot see Wasm.Validator.Types — so the
  two records are converted field by field rather than assigned. The
  names differ as well as the layouts, deliberately: both used to be
  spelled TWasmCanonType and a unit seeing both resolved the bare name by
  uses-order rather than by intent. The layouts differ because
  the validator's carries HasSuper/SuperId, which the tiers never consult
  because the supertype DISPLAY already answers every subtyping question
  in constant time, and the IR's carries the display's Depth explicitly
  so a consumer does not have to derive it. }
procedure TModuleValidator.FillTypeSnapshots(const AIr: TWasmIrModule);
var
  I, J: Integer;
  Canon: TWasmCanonType;
begin
  SetLength(AIr.CanonTypes, FTypes.CanonTypeCount);
  for I := 0 to FTypes.CanonTypeCount - 1 do
  begin
    Canon := FTypes.CanonType(UInt32(I));
    AIr.CanonTypes[I].Comp := Canon.Comp;
    AIr.CanonTypes[I].IsFinal := Canon.IsFinal;
    AIr.CanonTypes[I].Depth := FTypes.CanonDepth(UInt32(I));
    SetLength(AIr.CanonTypes[I].Display, Length(Canon.Display));
    for J := 0 to High(Canon.Display) do
      AIr.CanonTypes[I].Display[J] := Canon.Display[J];
  end;

  SetLength(AIr.TypeIndexToCanon, FTypes.TypeCount);
  for I := 0 to FTypes.TypeCount - 1 do
    AIr.TypeIndexToCanon[I] := FTypes.CanonIdOf(UInt32(I));

  SetLength(AIr.GroupKeys, FTypes.GroupCount);
  for I := 0 to FTypes.GroupCount - 1 do
    AIr.GroupKeys[I] := FTypes.GroupKey(I);
end;

procedure TModuleValidator.FillIndexSpaceSnapshots(
  const AIr: TWasmIrModule);
var
  I: Integer;
begin
  SetLength(AIr.FuncCanonTypes, Length(FSpaces.FuncTypes));
  SetLength(AIr.FuncIsImported, Length(FSpaces.FuncTypes));
  for I := 0 to High(FSpaces.FuncTypes) do
  begin
    AIr.FuncCanonTypes[I] := FTypes.CanonIdOf(FSpaces.FuncTypes[I]);
    AIr.FuncIsImported[I] := UInt32(I) < FFuncImports;
  end;

  SetLength(AIr.Tables, Length(FSpaces.Tables));
  for I := 0 to High(FSpaces.Tables) do
    AIr.Tables[I] := FSpaces.Tables[I];
  SetLength(AIr.Memories, Length(FSpaces.Memories));
  for I := 0 to High(FSpaces.Memories) do
    AIr.Memories[I] := FSpaces.Memories[I];
  SetLength(AIr.Globals, Length(FSpaces.Globals));
  for I := 0 to High(FSpaces.Globals) do
    AIr.Globals[I] := FSpaces.Globals[I];
  SetLength(AIr.Tags, Length(FSpaces.Tags));
  for I := 0 to High(FSpaces.Tags) do
    AIr.Tags[I] := FTypes.CanonIdOf(FSpaces.Tags[I]);

  AIr.FuncImportCount := FFuncImports;
  AIr.TableImportCount := FTableImports;
  AIr.MemoryImportCount := FMemImports;
  AIr.GlobalImportCount := FGlobalImports;
  AIr.TagImportCount := FTagImports;
end;

{ --- the phase order ----------------------------------------------------- }

function TModuleValidator.Run(const AModule: TWasmModule;
  const ABytes: TWasmBytes): TWasmIrModule;
var
  Declared: TWasmDeclaredFuncs;
  I: Integer;
begin
  FModule := AModule;
  FBytes := ABytes;
  FFuncRefs := nil;
  FExportHashes := nil;
  FExportNames := nil;
  FExportCount := 0;

  { Phase 1 — types. Incremental, group by group, and the source of every
    canonical id the rest of the module is described in. }
  FTypes.Build(AModule);

  BuildSpaces;
  BuildConstContext(AModule, FConst);

  Result := TWasmIrModule.Create;
  try
    ValidateImports;        { phase 2  — valid-importdesc }
    ValidateFunctions;      { phase 3  — valid-func's type use }
    ValidateTables(Result); { phase 4  — valid-table }
    ValidateMemories;       { phase 5  — valid-mem }
    ValidateTags;           { phase 6  — valid-tag }
    ValidateGlobals(Result);{ phase 7  — valid-global / valid-globalseq }
    ValidateElements(Result);   { phase 8  — valid-elem }
    ValidateDatas(Result);      { phase 9  — valid-data }
    ValidateStart;              { phase 10 — valid-start }
    ValidateExports(Result);    { phase 11 — valid-exportdesc }

    { C.REFS is complete only now, which is why it is built here and not
      earlier: phases 4, 7 and 8 are what contribute the constant-
      expression `ref.func` occurrences. }
    Declared := BuildDeclaredFuncs;
    SetLength(Result.DeclaredFuncRefs, Length(Declared));
    for I := 0 to High(Declared) do
      Result.DeclaredFuncRefs[I] := Declared[I];

    ValidateBodies(Result, Declared);   { phase 12 — the fused walk }

    FillTypeSnapshots(Result);
    FillIndexSpaceSnapshots(Result);

    Result.HasStart := AModule.HasStart;
    Result.StartFuncIndex := AModule.StartFuncIndex;
  except
    Result.Free;
    raise;
  end;
end;

function ValidateModule(const AModule: TWasmModule;
  const ABytes: TWasmBytes): TWasmIrModule;
var
  Validator: TModuleValidator;
begin
  Validator := Default(TModuleValidator);
  Result := Validator.Run(AModule, ABytes);
end;

end.
