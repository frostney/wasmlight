{ Wasm.Validator.Const — constant-expression validation and the IR the
  tiers evaluate an initialiser with.

  Globals, table initialisers, element-segment offsets and items, and
  data-segment offsets all carry a `constant expression`: a short
  instruction sequence drawn from a restricted set, terminated by `end`,
  yielding exactly one value of a required type. This unit validates one
  such expression and emits its TWasmIrInitExpr in a SINGLE fused walk —
  the bytes are re-decoded from the span (ADR-0003), type-checked, and
  lowered in one pass, because ADR-0007 says validation is the only thing
  that ever reads the raw binary and every tier reads the IR instead.

  Track A's `Wasm.Decoder.Expr.SkipExpr` already walked these bytes and
  proved them structurally well-formed, so the span's grammar is not in
  question here: the immediates still have to be READ (that is what makes
  the walk fused rather than a second pass over a decoded form), but a
  truncated immediate or an unassigned opcode cannot occur. The few
  EWasmDecodeError raises below are therefore defensive; they are marked
  as such at each site, and they exist because collapsing them into a
  validation error would move the malformed/invalid boundary the error
  hierarchy exists to preserve (AGENTS.md).

  THE CONSTANT INSTRUCTION SET, read from `valid-constant` at the pinned
  commit. Its `formal_refs` enumerate the rule exactly — Instr_const/const,
  /vconst, /binop, /ref.null, /ref.i31, /ref.func, /struct.new,
  /struct.new_default, /array.new, /array.new_default, /array.new_fixed,
  /any.convert_extern, /extern.convert_any, /global.get — which is:

    - `t.const` for all four numeric types
    - the extended-const arithmetic: `inn.add`, `inn.sub`, `inn.mul`, so
      i32 and i64 only, six instructions
      (`appendix/changes-extended-constant-expressions`)
    - `ref.null`, `ref.func`
    - `global.get` of a previously declared IMMUTABLE global (see below)
    - the GC allocation set: `struct.new`, `struct.new_default`,
      `array.new`, `array.new_default`, `array.new_fixed`, `ref.i31`,
      `any.convert_extern`, `extern.convert_any` (`extension-gc`)
    - `v128.const` (`valid-vconst`, `Instr_const/vconst`): a constant
      instruction, accepted here — it reads its 16 literal bytes, emits
      iroV128Const, and pushes v128. Every OTHER assigned $FD subopcode is
      non-constant and gets the same message any non-constant instruction
      does, not a SIMD-specific one

  Note what is NOT in that list even though it looks like it belongs:
  `array.new_data` and `array.new_elem` are allocation instructions but
  are not constant instructions at the pin.

  THE global.get RULE has two independent halves and both are enforced,
  but in different places:

    1. MUTABILITY is a property of the instruction, so it is checked here:
       `appendix/changes-extended-constant-expressions` admits
       "GLOBALGET for any previously declared immutable global". A
       `global.get` of a mutable global is not a constant instruction, so
       the failure is MSG_CONSTANT_EXPRESSION_REQUIRED rather than a type
       error.
    2. WHICH globals are in scope is a property of the surrounding module
       rule, not of the instruction: `valid-constant` says "constant
       expressions occurring in globals are further constrained in that
       contained GLOBAL.GET instructions are only allowed to refer to
       imported or previously defined globals. Constant expressions
       occurring in tables may only have GLOBAL.GET instructions that
       refer to imported globals. This is enforced in the validation rule
       for modules by constraining the context C accordingly." That is
       why TWasmConstContext carries a GlobalLimit the CALLER sets per
       call site: imported-only for a table initialiser, imports plus the
       globals already defined for global i, and the whole space
       elsewhere. Out of scope reads as MSG_UNKNOWN_GLOBAL, because from
       the constrained context's point of view the global does not exist.

  `ref.func x` inside a constant expression is one of the things that puts
  x into C.REFS ("the list of function indices that occur in the module
  outside functions", `context`), which is what
  MSG_UNDECLARED_FUNCTION_REFERENCE is later checked against inside
  function bodies. TWasmIrInitExpr has no field for that and this unit
  must not widen Wasm.Ir, so the indices come back through the
  accumulating AFuncRefs parameter — one array threaded through every
  call, which is exactly the shape C.REFS wants.

  Spec pin: the 3.0 draft at `d7b37e4170d8315f2f1283aed4e8076591a9a333`
  (ADR-0004; `wasm-mcp` 0.2.16 `spec_version`). Anchors are cited per
  rule. Canonical message prefixes and the matching relation come from
  Wasm.Validator.Types and are never re-spelled here.

  ONE SPELLING QUIRK, and every consumer hits it: `const` is a reserved
  word, so the last component of this unit's dotted name must be escaped
  with FPC's `&` — the declaration below reads `Wasm.Validator.&Const`,
  and a `uses` clause must spell it `Wasm.Validator.&Const` too. The FILE
  is still `Wasm.Validator.Const.pas`, which is what the unit name has to
  match and what the layout rule (AGENTS.md) fixes; the escape is purely
  a lexical device and changes nothing else. }
unit Wasm.Validator.&Const;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Common,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator.Types;

type
  { The function indices a constant expression named with `ref.func`.
    Accumulated across every initialiser in the module to form C.REFS
    (`context`); duplicates are kept, because the consumer builds a
    membership flag array from it and deduplicating here would cost a
    pass for nothing. }
  TWasmConstFuncRefs = array of UInt32;

  { Function index space -> module type index, imports first. }
  TWasmConstFuncTypes = array of UInt32;

  { What a constant expression is allowed to see. Everything in here is
    module-level knowledge the caller already has; this unit does not
    reconstruct it, because the caller is what knows WHICH call site is
    being validated and therefore how far GlobalLimit reaches. }
  TWasmConstContext = record
    { The global index space, IMPORTS FIRST — the numbering `global.get`
      means. }
    Globals: array of TWasmGlobalType;
    { Exclusive bound on the global indices `global.get` may name. See
      the unit header: the spec constrains the CONTEXT, not the
      instruction, so the bound is the caller's to choose. }
    GlobalLimit: UInt32;
    { The function index space `ref.func` names, imports first, carried
      PREBUILT. It used to be re-derived per call by walking the import
      list looking for the index'th function, which is O(imports) on
      every single `ref.func` — and an element segment is a vector of
      them. FuncCount is Length(FuncTypes), kept as its own field
      because the bound is what `ref.func` reports on. }
    FuncTypes: TWasmConstFuncTypes;
    FuncCount: UInt32;
  end;

{ Snapshots AModule's global and function index spaces into AContext with
  GlobalLimit spanning every global. Callers that need a narrower scope —
  a table initialiser, or global i's own initialiser — assign GlobalLimit
  afterwards; that is the one field this helper cannot decide.

  Called ONCE per module: everything it builds is whole-module knowledge
  and none of it changes between call sites. }
procedure BuildConstContext(const AModule: TWasmModule;
  out AContext: TWasmConstContext);

{ The module type index of function AIndex in the function index space
  (imports first). AIndex must already be in range. }
function ConstFuncTypeIndex(const AContext: TWasmConstContext;
  const AIndex: UInt32): UInt32;

{ Validates one constant expression and returns its IR.

  ASpan is a range of ABytes (ADR-0003) covering the expression INCLUDING
  its terminating `end` byte — exactly what Wasm.Decoder.Expr.SkipExpr
  produced. AExpected is the type the expression must yield; the check is
  MATCHING, not equality (`match-valtype`), so a `(ref $f)` initialiser
  satisfies a `funcref` global.

  Every `ref.func` index the expression names is APPENDED to AFuncRefs,
  which is never cleared — thread one array through the whole module.

  Raises EWasmValidationError for typing and constness violations, with
  the canonical prefixes from Wasm.Validator.Types. }
function ValidateConstExpr(const ATypes: TWasmTypeContext;
  const AConst: TWasmConstContext;
  const ABytes: TWasmBytes; const ASpan: TWasmSpan;
  const AExpected: TWasmValueType;
  var AFuncRefs: TWasmConstFuncRefs): TWasmIrInitExpr;

{ The `elem` funcidx-vector form, which the binary format spells as a
  bare index rather than an expression, lowered to the one-instruction
  `ref.func` expression every other item already is. Instantiation then
  has exactly one code path (Wasm.Ir's TWasmIrElemSegment comment), and
  the ref.func typing rule lives in one place rather than two. }
function MakeRefFuncInitExpr(const ATypes: TWasmTypeContext;
  const AConst: TWasmConstContext;
  const AFuncIndex: UInt32; const AExpected: TWasmValueType;
  var AFuncRefs: TWasmConstFuncRefs): TWasmIrInitExpr;

{ `aux-default`: "Value types can have an associated default value; it is
  the respective value for number types, for vector types, and null for
  nullable reference types. For other references, no default value is
  defined". Exposed because the table rule (`valid-table` without an init
  expression) needs the same predicate. }
function IsDefaultableValType(const AType: TWasmValueType): Boolean;

implementation

const
  { Single-byte opcodes this unit acts on. Everything else in the
    single-byte space is not a constant instruction. }
  OP_END         = $0B;
  OP_GLOBAL_GET  = $23;
  OP_I32_CONST   = $41;
  OP_I64_CONST   = $42;
  OP_F32_CONST   = $43;
  OP_F64_CONST   = $44;
  OP_I32_ADD     = $6A;
  OP_I32_SUB     = $6B;
  OP_I32_MUL     = $6C;
  OP_I64_ADD     = $7C;
  OP_I64_SUB     = $7D;
  OP_I64_MUL     = $7E;
  OP_REF_NULL    = $D0;
  OP_REF_FUNC    = $D2;

  { The three prefixed spaces. $FB carries the GC instructions, of which
    eight are constant; $FC carries saturating truncation and bulk
    memory/table, none of which are; $FD is the vector space, staged to
    Track G. }
  OP_PREFIX_GC   = $FB;
  OP_PREFIX_MISC = $FC;
  OP_PREFIX_VEC  = $FD;

  { $FB subopcodes (`binary-instr-aggr`). }
  GC_STRUCT_NEW          = 0;
  GC_STRUCT_NEW_DEFAULT  = 1;
  GC_ARRAY_NEW           = 6;
  GC_ARRAY_NEW_DEFAULT   = 7;
  GC_ARRAY_NEW_FIXED     = 8;
  GC_ANY_CONVERT_EXTERN  = 26;
  GC_EXTERN_CONVERT_ANY  = 27;
  GC_REF_I31             = 28;
  { The skipper accepts 0..30 and rejects everything above as malformed. }
  GC_MAX_SUBOPCODE       = 30;

type
  { One entry of the symbolic value stack. There is no Bot case and there
    must not be one: `unreachable` is not a constant instruction, so a
    constant expression has no stack-polymorphic position and every value
    on this stack has a concrete type and a register. }
  TConstValue = record
    ValType: TWasmValueType;
    Reg: UInt32;
  end;

  { The fused walker. A record rather than a class so nothing managed
    sits on a frame an unwind could skip, matching the rest of the
    validator. }
  TConstWalker = record
  private
    FTypes: TWasmTypeContext;
    FConst: TWasmConstContext;
    FReader: TWasmReader;
    FBase: NativeUInt;

    FExpr: TWasmIrInitExpr;
    { Live lengths of FExpr.Code / RegTypes / AuxU32, which Wasm.Ir's
      append primitives grow geometrically. Length() on any of the three
      is the CAPACITY until Run trims them. }
    FCodeCount: Integer;
    FRegCount: Integer;
    FAuxCount: Integer;
    FStack: array of TConstValue;
    FDepth: Integer;
    FFuncRefs: TWasmConstFuncRefs;
    FFuncRefCount: Integer;

    function Offset: NativeUInt;
    procedure NotConstant(const AWhat: string; const AOffset: NativeUInt);

    function AllocReg(const AType: TWasmValueType): UInt32;
    procedure Emit(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32;
      const AImm: Int64);
    procedure Push(const AType: TWasmValueType; const AReg: UInt32);
    function PopAny(const AWhat: string): TConstValue;
    function Pop(const AExpected: TWasmValueType;
      const AWhat: string): UInt32;
    function PopI32(const AWhat: string): UInt32;
    procedure RecordFuncRef(const AIndex: UInt32);

    function Aggregate(const ATypeIndex: UInt32;
      const AKind: TWasmCompKind; const AWhat: string): TWasmCompType;
    procedure RequireDefaultable(const AField: TWasmFieldType;
      const AWhat: string; const AWhich: Integer);
    function AllocRef(const ATypeIndex: UInt32): UInt32;

    procedure StepConstI32;
    procedure StepConstI64;
    procedure StepConstF32;
    procedure StepConstF64;
    procedure StepV128Const;
    procedure StepBinop(const AOp: TWasmIrOp;
      const AType: TWasmValueType; const AWhat: string);
    procedure StepRefNull;
    procedure StepRefFunc;
    procedure StepGlobalGet;
    procedure StepStructNew;
    procedure StepStructNewDefault;
    procedure StepArrayNew;
    procedure StepArrayNewDefault;
    procedure StepArrayNewFixed;
    procedure StepRefI31;
    procedure StepConvert(const AOp: TWasmIrOp;
      const AFrom, ATo: TWasmAbsHeapType; const AWhat: string);
    procedure StepGc(const AOpOffset: NativeUInt);
    procedure Step(const AOpcode: Byte; const AOpOffset: NativeUInt);
  public
    procedure Init(const ATypes: TWasmTypeContext;
      const AConst: TWasmConstContext;
      const ABytes: TWasmBytes; const ASpan: TWasmSpan);
    procedure Run(const AExpected: TWasmValueType);

    property Expr: TWasmIrInitExpr read FExpr;
  end;

{ --- small type helpers -------------------------------------------------- }

function IsDefaultableValType(const AType: TWasmValueType): Boolean;
begin
  { `aux-default`. Numbers and vectors always have a default; a reference
    has one exactly when it is nullable. }
  Result := (AType.Kind <> wvkRef) or AType.Ref.Nullable;
end;

function IsDefaultableFieldType(const AField: TWasmFieldType): Boolean;
begin
  { A packed field's storage is an integer, so it always defaults to
    zero; only a value-typed field can be non-defaultable. }
  if AField.Storage.IsPacked then
    Exit(True);
  Result := IsDefaultableValType(AField.Storage.ValueType);
end;

{ The type of the OPERAND that initialises a field: a packed storage type
  is written and read as an i32, so `struct.new` on a struct with an i8
  field takes an i32 (`valid-struct.new`, whose parameter list is the
  unpacked storage types). }
function UnpackStorageType(
  const AStorage: TWasmStorageType): TWasmValueType;
begin
  if AStorage.IsPacked then
    Result := MakeNumValueType(wntI32)
  else
    Result := AStorage.ValueType;
end;

function CompKindName(const AKind: TWasmCompKind): string;
begin
  case AKind of
    wckFunc: Result := 'function';
    wckStruct: Result := 'struct';
  else
    Result := 'array';
  end;
end;

function NumValType(const ANum: TWasmNumType): TWasmValueType;
begin
  Result := MakeNumValueType(ANum);
end;

function AbsRefValType(const AAbs: TWasmAbsHeapType;
  const ANullable: Boolean): TWasmValueType;
begin
  Result := MakeRefValueType(MakeRefType(ANullable,
    MakeAbsHeapType(AAbs)));
end;

{ --- module index-space helpers ------------------------------------------ }

procedure BuildConstContext(const AModule: TWasmModule;
  out AContext: TWasmConstContext);
var
  I, Next: Integer;
begin
  SetLength(AContext.Globals, AModule.TotalGlobalCount);
  Next := 0;
  { Imports occupy the low indices of every index space. }
  for I := 0 to AModule.ImportCount - 1 do
    if AModule.Imports[I].Kind = wxkGlobal then
    begin
      AContext.Globals[Next] := AModule.Imports[I].Global;
      Inc(Next);
    end;
  for I := 0 to AModule.GlobalCount - 1 do
  begin
    AContext.Globals[Next] := AModule.Globals[I].GlobalType;
    Inc(Next);
  end;

  AContext.GlobalLimit := UInt32(Length(AContext.Globals));

  { The function index space, built once here for the same reason the
    global one is: imports first, then the function section's entries in
    order. }
  SetLength(AContext.FuncTypes, AModule.TotalFunctionCount);
  Next := 0;
  for I := 0 to AModule.ImportCount - 1 do
    if AModule.Imports[I].Kind = wxkFunc then
    begin
      AContext.FuncTypes[Next] := AModule.Imports[I].FuncTypeIndex;
      Inc(Next);
    end;
  for I := 0 to AModule.FunctionTypeIndexCount - 1 do
  begin
    AContext.FuncTypes[Next] := AModule.FunctionTypeIndices[I];
    Inc(Next);
  end;

  AContext.FuncCount := UInt32(Length(AContext.FuncTypes));
end;

function ConstFuncTypeIndex(const AContext: TWasmConstContext;
  const AIndex: UInt32): UInt32;
begin
  Result := AContext.FuncTypes[AIndex];
end;

{ --- TConstWalker: plumbing ---------------------------------------------- }

procedure TConstWalker.Init(const ATypes: TWasmTypeContext;
  const AConst: TWasmConstContext;
  const ABytes: TWasmBytes; const ASpan: TWasmSpan);
begin
  FTypes := ATypes;
  FConst := AConst;
  FBase := ASpan.Offset;

  { The reader is confined to the span, so overrunning it is impossible
    rather than merely checked. ADR-0003: the span is absolute into the
    module buffer, which the caller must keep alive. }
  if ASpan.Size = 0 then
    raise EWasmDecodeError.CreateFmt(
      'empty constant expression at offset %u', [ASpan.Offset]);
  if ASpan.Offset + ASpan.Size > NativeUInt(Length(ABytes)) then
    raise EWasmDecodeError.CreateFmt(
      'constant expression at offset %u runs past the module buffer '
      + '(%u byte(s))', [ASpan.Offset, NativeUInt(Length(ABytes))]);
  FReader.Init(@ABytes[ASpan.Offset], ASpan.Size);
  { The span was cut out of a section body, so truncation inside it reads
    as running off the end of that section — see TWasmReaderContext. }
  FReader.Context := wrcSection;

  FExpr.Code := nil;
  FExpr.RegTypes := nil;
  FExpr.RegisterCount := 0;
  FExpr.ResultReg := IR_NO_REG;
  FExpr.AuxU32 := nil;
  FExpr.AuxRefTypes := nil;
  FCodeCount := 0;
  FRegCount := 0;
  FAuxCount := 0;

  FStack := nil;
  FDepth := 0;
  FFuncRefs := nil;
  FFuncRefCount := 0;
end;

function TConstWalker.Offset: NativeUInt;
begin
  { Absolute, so a diagnostic points at the module buffer and not at a
    position inside a span nobody can see. }
  Result := FBase + FReader.Position;
end;

procedure TConstWalker.NotConstant(const AWhat: string;
  const AOffset: NativeUInt);
begin
  raise EWasmValidationError.CreateFmt(
    '%s: %s at offset %u is not a constant instruction',
    [MSG_CONSTANT_EXPRESSION_REQUIRED, AWhat, AOffset]);
end;

{ Both of these are Wasm.Ir's primitives, unwrapped: the growth policy
  and the aliasing rule live there so that every IR producer shares one
  of each (Wasm.Ir's building section). What is left here is the naming
  and the ADR-0011 invariant that motivates it — registers are monotonic
  and never reused, so RegTypes stays a plain array with one type per
  register for the whole expression. }
function TConstWalker.AllocReg(const AType: TWasmValueType): UInt32;
begin
  Result := IrAllocReg(FExpr.RegTypes, FRegCount, AType);
end;

procedure TConstWalker.Emit(const AOp: TWasmIrOp;
  const ADest, AA, AB: UInt32; const AImm: Int64);
begin
  IrEmitInstr(FExpr.Code, FCodeCount, MakeIrInstr(AOp, ADest, AA, AB,
    AImm));
end;

procedure TConstWalker.Push(const AType: TWasmValueType;
  const AReg: UInt32);
begin
  if FDepth >= Length(FStack) then
    SetLength(FStack, (FDepth + 1) * 2);
  FStack[FDepth].ValType := AType;
  FStack[FDepth].Reg := AReg;
  Inc(FDepth);
end;

function TConstWalker.PopAny(const AWhat: string): TConstValue;
begin
  if FDepth = 0 then
    raise EWasmValidationError.CreateFmt(
      '%s: %s needs an operand, but the constant expression stack is '
      + 'empty', [MSG_TYPE_MISMATCH, AWhat]);
  Dec(FDepth);
  Result := FStack[FDepth];
end;

function TConstWalker.Pop(const AExpected: TWasmValueType;
  const AWhat: string): UInt32;
var
  Value: TConstValue;
begin
  Value := PopAny(AWhat);
  { `match-valtype`, not equality: an operand of a more precise type is
    admissible wherever the less precise one is. }
  if not FTypes.MatchesValType(Value.ValType, AExpected) then
    raise EWasmValidationError.CreateFmt(
      '%s: %s expects %s but found %s',
      [MSG_TYPE_MISMATCH, AWhat, AExpected.Describe,
       Value.ValType.Describe]);
  Result := Value.Reg;
end;

function TConstWalker.PopI32(const AWhat: string): UInt32;
begin
  Result := Pop(NumValType(wntI32), AWhat);
end;

procedure TConstWalker.RecordFuncRef(const AIndex: UInt32);
begin
  if FFuncRefCount >= Length(FFuncRefs) then
    SetLength(FFuncRefs, (FFuncRefCount + 1) * 2);
  FFuncRefs[FFuncRefCount] := AIndex;
  Inc(FFuncRefCount);
end;

function TConstWalker.Aggregate(const ATypeIndex: UInt32;
  const AKind: TWasmCompKind; const AWhat: string): TWasmCompType;
begin
  { Expand raises MSG_UNKNOWN_TYPE for an index outside the type space —
    that check has exactly one home (Wasm.Validator.Types) and this is a
    caller of it, not a second copy. }
  Result := FTypes.Expand(ATypeIndex);
  if Result.Kind <> AKind then
    raise EWasmValidationError.CreateFmt(
      '%s: %s needs type %d to be a %s type, but it is a %s type',
      [MSG_TYPE_MISMATCH, AWhat, Int64(ATypeIndex), CompKindName(AKind),
       CompKindName(Result.Kind)]);
end;

procedure TConstWalker.RequireDefaultable(const AField: TWasmFieldType;
  const AWhat: string; const AWhich: Integer);
begin
  { `valid-struct.new_default` / `valid-array.new_default` require every
    field's storage type to have a default value. UNCONFIRMED: the
    reference interpreter's phrasing for this failure is not served by
    the MCP; `type mismatch` is the prefix used here and Track C's runner
    is what settles it. }
  if IsDefaultableFieldType(AField) then
    Exit;
  if AWhich < 0 then
    raise EWasmValidationError.CreateFmt(
      '%s: %s needs a defaultable element type, but %s has no default '
      + 'value', [MSG_TYPE_MISMATCH, AWhat, AField.Describe])
  else
    raise EWasmValidationError.CreateFmt(
      '%s: %s needs defaultable fields, but field %d (%s) has no default '
      + 'value',
      [MSG_TYPE_MISMATCH, AWhat, AWhich, AField.Describe]);
end;

function TConstWalker.AllocRef(const ATypeIndex: UInt32): UInt32;
begin
  { Every allocation instruction yields a NON-NULL reference to the
    concrete type it allocated. }
  Result := AllocReg(MakeRefValueType(MakeRefType(False,
    MakeConcreteHeapType(ATypeIndex))));
end;

{ --- TConstWalker: the constant instructions ----------------------------- }

procedure TConstWalker.StepConstI32;
var
  Value: Int32;
  Reg: UInt32;
begin
  { `Instr_const/const`. }
  Value := FReader.ReadI32;
  Reg := AllocReg(NumValType(wntI32));
  Emit(iroI32Const, Reg, IR_NO_REG, IR_NO_REG, Int64(Value));
  Push(NumValType(wntI32), Reg);
end;

procedure TConstWalker.StepConstI64;
var
  Value: Int64;
  Reg: UInt32;
begin
  Value := FReader.ReadI64;
  Reg := AllocReg(NumValType(wntI64));
  Emit(iroI64Const, Reg, IR_NO_REG, IR_NO_REG, Value);
  Push(NumValType(wntI64), Reg);
end;

procedure TConstWalker.StepConstF32;
var
  Bits: UInt32;
  Reg: UInt32;
begin
  { Floats travel as BIT PATTERNS — NaN payloads are observable and a
    round trip through an FPC float type is not required to preserve
    them (Wasm.Ir's IrF32Bits comment). The 32 bits are zero-extended. }
  Bits := FReader.ReadFixedU32;
  Reg := AllocReg(NumValType(wntF32));
  Emit(iroF32Const, Reg, IR_NO_REG, IR_NO_REG, Int64(Bits));
  Push(NumValType(wntF32), Reg);
end;

procedure TConstWalker.StepConstF64;
var
  Lo, Hi: UInt32;
  Reg: UInt32;
begin
  { Two little-endian halves rather than one 64-bit read: TWasmReader
    exposes ReadFixedU32 only, and `shl` wraps rather than raising, so
    this composes without tripping the overflow checks Shared.inc turns
    on for non-production builds. }
  Lo := FReader.ReadFixedU32;
  Hi := FReader.ReadFixedU32;
  Reg := AllocReg(NumValType(wntF64));
  Emit(iroF64Const, Reg, IR_NO_REG, IR_NO_REG,
    Int64(Lo) or (Int64(Hi) shl 32));
  Push(NumValType(wntF64), Reg);
end;

{ v128.const ($FD 12): [] -> [v128] with 16 literal bytes. A constant
  instruction (`valid-vconst`); the 16 bytes ride in an AuxU32 block and
  the register is a v128 (a slot PAIR — IrAllocReg even-aligns it). }
procedure TConstWalker.StepV128Const;
var
  Vec: TWasmV128;
  I: Integer;
  Reg, Aux: UInt32;
begin
  for I := 0 to 15 do
    Vec.B[I] := FReader.ReadByte;
  Reg := AllocReg(MakeVecValueType);
  Aux := IrAppendAuxV128Growing(FExpr.AuxU32, FAuxCount, Vec);
  Emit(iroV128Const, Reg, IR_NO_REG, IR_NO_REG, Int64(Aux));
  Push(MakeVecValueType, Reg);
end;

procedure TConstWalker.StepBinop(const AOp: TWasmIrOp;
  const AType: TWasmValueType; const AWhat: string);
var
  Left, Right, Reg: UInt32;
begin
  { `Instr_const/binop`, restricted to add/sub/mul over the integer types
    (`appendix/changes-extended-constant-expressions`). The RIGHT operand
    is on top of the stack, so it pops first. }
  Right := Pop(AType, AWhat);
  Left := Pop(AType, AWhat);
  Reg := AllocReg(AType);
  Emit(AOp, Reg, Left, Right, 0);
  Push(AType, Reg);
end;

procedure TConstWalker.StepRefNull;
var
  Heap: TWasmHeapType;
  Ty: TWasmValueType;
  Reg: UInt32;
begin
  { `Instr_const/ref.null`, typed by `valid-ref.null`: the heap type must
    be valid, and the result is a NULLABLE reference to it. }
  Heap := ReadHeapType(FReader);
  if not Heap.IsAbstract then
    FTypes.CanonIdOf(Heap.TypeIndex);
  Ty := MakeRefValueType(MakeRefType(True, Heap));
  Reg := AllocReg(Ty);
  { ref.null carries no heap type in the instruction: a null value has no
    runtime type and the static one is in RegTypes[Dest]. }
  Emit(iroRefNull, Reg, IR_NO_REG, IR_NO_REG, 0);
  Push(Ty, Reg);
end;

procedure TConstWalker.StepRefFunc;
var
  Index, TypeIndex, Reg: UInt32;
  Ty: TWasmValueType;
begin
  { `Instr_const/ref.func` / `valid-ref.func`: the result is a NON-NULL
    reference to the function's CONCRETE type, not `funcref`. }
  Index := FReader.ReadU32;
  if Index >= FConst.FuncCount then
    raise EWasmValidationError.CreateFmt(
      '%s: ref.func names function %d, but the function index space '
      + 'holds %d', [UnknownIndex(MSG_UNKNOWN_FUNCTION, Int64(Index)),
      Int64(Index), Int64(FConst.FuncCount)]);

  TypeIndex := ConstFuncTypeIndex(FConst, Index);
  { Defensive: the module-level walk validates every function's type
    index before any initialiser is checked, so this cannot fire; it is
    here so a caller that reorders the phases fails loudly. }
  FTypes.CanonIdOf(TypeIndex);

  Ty := MakeRefValueType(MakeRefType(False,
    MakeConcreteHeapType(TypeIndex)));
  Reg := AllocReg(Ty);
  Emit(iroRefFunc, Reg, IR_NO_REG, IR_NO_REG, Int64(Index));
  Push(Ty, Reg);
  RecordFuncRef(Index);
end;

procedure TConstWalker.StepGlobalGet;
var
  Index, Reg: UInt32;
  Global: TWasmGlobalType;
  Offs: NativeUInt;
begin
  Offs := Offset;
  Index := FReader.ReadU32;

  { Out of the CONSTRAINED context's range — see the unit header. From
    the constrained context's point of view the global does not exist,
    which is why this is `unknown global` and not a constness failure. }
  if (Index >= FConst.GlobalLimit)
    or (Index >= UInt32(Length(FConst.Globals))) then
    raise EWasmValidationError.CreateFmt(
      '%s: global.get names global %d, but only %d global(s) are in '
      + 'scope here', [UnknownIndex(MSG_UNKNOWN_GLOBAL, Int64(Index)),
      Int64(Index), Int64(FConst.GlobalLimit)]);

  Global := FConst.Globals[Index];
  { `appendix/changes-extended-constant-expressions`: GLOBAL.GET is a
    constant instruction only "for any previously declared immutable
    global", so a mutable one makes the INSTRUCTION non-constant. }
  if Global.Mut then
    NotConstant('global.get of mutable global ' + IntToStr(Int64(Index)),
      Offs);

  Reg := AllocReg(Global.ValueType);
  Emit(iroGlobalGet, Reg, IR_NO_REG, IR_NO_REG, Int64(Index));
  Push(Global.ValueType, Reg);
end;

procedure TConstWalker.StepStructNew;
var
  TypeIndex, Reg, Aux: UInt32;
  Comp: TWasmCompType;
  Regs: array of UInt32;
  I, Count: Integer;
begin
  { `Instr_const/struct.new` / `valid-struct.new`: the operands are the
    field storage types UNPACKED, deepest first. }
  TypeIndex := FReader.ReadU32;
  Comp := Aggregate(TypeIndex, wckStruct, 'struct.new');
  Count := Length(Comp.Struct.Fields);

  SetLength(Regs, Count);
  for I := Count - 1 downto 0 do
    Regs[I] := Pop(UnpackStorageType(Comp.Struct.Fields[I].Storage),
      'struct.new field ' + IntToStr(I));

  Reg := AllocRef(TypeIndex);
  Aux := IrAppendAuxBlockGrowing(FExpr.AuxU32, FAuxCount, Regs);
  Emit(iroStructNew, Reg, Aux, IR_NO_REG, Int64(TypeIndex));
  Push(FExpr.RegTypes[Reg], Reg);
end;

procedure TConstWalker.StepStructNewDefault;
var
  TypeIndex, Reg: UInt32;
  Comp: TWasmCompType;
  I: Integer;
begin
  TypeIndex := FReader.ReadU32;
  Comp := Aggregate(TypeIndex, wckStruct, 'struct.new_default');
  for I := 0 to High(Comp.Struct.Fields) do
    RequireDefaultable(Comp.Struct.Fields[I], 'struct.new_default', I);

  Reg := AllocRef(TypeIndex);
  Emit(iroStructNewDefault, Reg, IR_NO_REG, IR_NO_REG, Int64(TypeIndex));
  Push(FExpr.RegTypes[Reg], Reg);
end;

procedure TConstWalker.StepArrayNew;
var
  TypeIndex, Reg, ValueReg, LenReg: UInt32;
  Comp: TWasmCompType;
begin
  { `valid-array.new`: [t i32] -> [(ref x)], with the length on top. }
  TypeIndex := FReader.ReadU32;
  Comp := Aggregate(TypeIndex, wckArray, 'array.new');
  LenReg := PopI32('array.new length');
  ValueReg := Pop(UnpackStorageType(Comp.Arr.Elem.Storage),
    'array.new element');

  Reg := AllocRef(TypeIndex);
  Emit(iroArrayNew, Reg, ValueReg, LenReg, Int64(TypeIndex));
  Push(FExpr.RegTypes[Reg], Reg);
end;

procedure TConstWalker.StepArrayNewDefault;
var
  TypeIndex, Reg, LenReg: UInt32;
  Comp: TWasmCompType;
begin
  TypeIndex := FReader.ReadU32;
  Comp := Aggregate(TypeIndex, wckArray, 'array.new_default');
  RequireDefaultable(Comp.Arr.Elem, 'array.new_default', -1);
  LenReg := PopI32('array.new_default length');

  Reg := AllocRef(TypeIndex);
  Emit(iroArrayNewDefault, Reg, LenReg, IR_NO_REG, Int64(TypeIndex));
  Push(FExpr.RegTypes[Reg], Reg);
end;

procedure TConstWalker.StepArrayNewFixed;
var
  TypeIndex, Count, Reg, Aux: UInt32;
  Comp: TWasmCompType;
  Elem: TWasmValueType;
  Regs: array of UInt32;
  I: Integer;
begin
  { `valid-array.new_fixed`: [t^n] -> [(ref x)]. The immediates are the
    type index then the element COUNT (`binary-instr-aggr`). }
  TypeIndex := FReader.ReadU32;
  Count := FReader.ReadU32;
  Comp := Aggregate(TypeIndex, wckArray, 'array.new_fixed');
  Elem := UnpackStorageType(Comp.Arr.Elem.Storage);

  { Checked BEFORE the allocation: every element must already be on the
    stack, so a hostile count cannot size an array here. }
  if Count > UInt32(FDepth) then
    raise EWasmValidationError.CreateFmt(
      '%s: array.new_fixed needs %d operand(s) but only %d are on the '
      + 'constant expression stack',
      [MSG_TYPE_MISMATCH, Int64(Count), FDepth]);

  SetLength(Regs, Integer(Count));
  for I := Integer(Count) - 1 downto 0 do
    Regs[I] := Pop(Elem, 'array.new_fixed element ' + IntToStr(I));

  Reg := AllocRef(TypeIndex);
  Aux := IrAppendAuxBlockGrowing(FExpr.AuxU32, FAuxCount, Regs);
  Emit(iroArrayNewFixed, Reg, Aux, IR_NO_REG, Int64(TypeIndex));
  Push(FExpr.RegTypes[Reg], Reg);
end;

procedure TConstWalker.StepRefI31;
var
  Src, Reg: UInt32;
  Ty: TWasmValueType;
begin
  { `valid-ref.i31`: [i32] -> [(ref i31)] — non-nullable. }
  Src := PopI32('ref.i31');
  Ty := AbsRefValType(wahI31, False);
  Reg := AllocReg(Ty);
  Emit(iroRefI31, Reg, Src, IR_NO_REG, 0);
  Push(Ty, Reg);
end;

procedure TConstWalker.StepConvert(const AOp: TWasmIrOp;
  const AFrom, ATo: TWasmAbsHeapType; const AWhat: string);
var
  Value: TConstValue;
  Ty: TWasmValueType;
  Reg: UInt32;
begin
  { `valid-any.convert_extern` / `valid-extern.convert_any`.

    UNCONFIRMED, and the one real ambiguity in this unit: the rendered
    signature the MCP serves at the pin is
    `[(REF NULL EXTERN)] -> [(REF NULL ANY)]` with no nullability
    variable, but the rule these instructions came from
    (`extension-gc`) may instead make the nullability POLYMORPHIC — a
    non-null operand yielding a non-null result.

    THE FLAT SIGNATURE IS WHAT IS IMPLEMENTED, at this site and at
    Wasm.Validator.Body's HandleI31Extern, and the two agreeing is the
    point: the same instruction must type the same way whether it
    appears in an initialiser or a body, or a module's validity would
    depend on where it was written. The flat reading is the
    conservative one in the ACCEPTANCE direction — it can only reject a
    module the propagating reading admits, never wrongly admit one. The
    discriminating case is `(global (ref extern) (extern.convert_any
    (ref.i31 (i32.const 1))))`: rejected here, accepted under the
    propagating reading. Track C's runner settles it; flipping it is
    two lines, one per site. }
  Value := PopAny(AWhat);
  if not FTypes.MatchesValType(Value.ValType,
    AbsRefValType(AFrom, True)) then
    raise EWasmValidationError.CreateFmt(
      '%s: %s expects %s but found %s',
      [MSG_TYPE_MISMATCH, AWhat, AbsRefValType(AFrom, True).Describe,
       Value.ValType.Describe]);

  Ty := AbsRefValType(ATo, True);
  Reg := AllocReg(Ty);
  Emit(AOp, Reg, Value.Reg, IR_NO_REG, 0);
  Push(Ty, Reg);
end;

procedure TConstWalker.StepGc(const AOpOffset: NativeUInt);
var
  Sub: UInt32;
begin
  Sub := FReader.ReadU32;
  case Sub of
    GC_STRUCT_NEW: StepStructNew;
    GC_STRUCT_NEW_DEFAULT: StepStructNewDefault;
    GC_ARRAY_NEW: StepArrayNew;
    GC_ARRAY_NEW_DEFAULT: StepArrayNewDefault;
    GC_ARRAY_NEW_FIXED: StepArrayNewFixed;
    GC_ANY_CONVERT_EXTERN:
      StepConvert(iroAnyConvertExtern, wahExtern, wahAny,
        'any.convert_extern');
    GC_EXTERN_CONVERT_ANY:
      StepConvert(iroExternConvertAny, wahAny, wahExtern,
        'extern.convert_any');
    GC_REF_I31: StepRefI31;
  else
    { An assigned but non-constant GC instruction — array.new_data and
      array.new_elem live here, and they ARE allocations but are NOT in
      `valid-constant`'s list. }
    if Sub <= GC_MAX_SUBOPCODE then
      NotConstant('$FB subopcode ' + IntToStr(Int64(Sub)), AOpOffset)
    else
      { Defensive: Wasm.Decoder.Expr already rejected any $FB subopcode
        above 30 as malformed, so this span cannot contain one. }
      raise EWasmDecodeError.CreateFmt(
        'unknown $FB subopcode %u at offset %u', [Sub, AOpOffset]);
  end;
end;

procedure TConstWalker.Step(const AOpcode: Byte;
  const AOpOffset: NativeUInt);
var
  Sub: UInt32;
begin
  case AOpcode of
    OP_I32_CONST: StepConstI32;
    OP_I64_CONST: StepConstI64;
    OP_F32_CONST: StepConstF32;
    OP_F64_CONST: StepConstF64;

    OP_I32_ADD: StepBinop(iroI32Add, NumValType(wntI32), 'i32.add');
    OP_I32_SUB: StepBinop(iroI32Sub, NumValType(wntI32), 'i32.sub');
    OP_I32_MUL: StepBinop(iroI32Mul, NumValType(wntI32), 'i32.mul');
    OP_I64_ADD: StepBinop(iroI64Add, NumValType(wntI64), 'i64.add');
    OP_I64_SUB: StepBinop(iroI64Sub, NumValType(wntI64), 'i64.sub');
    OP_I64_MUL: StepBinop(iroI64Mul, NumValType(wntI64), 'i64.mul');

    OP_REF_NULL: StepRefNull;
    OP_REF_FUNC: StepRefFunc;
    OP_GLOBAL_GET: StepGlobalGet;

    OP_PREFIX_GC: StepGc(AOpOffset);

    OP_PREFIX_MISC:
      begin
        { Nothing in the $FC space is constant; read the subopcode so the
          message can name it. }
        Sub := FReader.ReadU32;
        NotConstant('$FC subopcode ' + IntToStr(Int64(Sub)), AOpOffset);
      end;

    OP_PREFIX_VEC:
      begin
        { `v128.const` ($FD 12) IS a constant instruction
          (`Instr_const/vconst`) and is accepted; every other assigned
          $FD subopcode is non-constant and gets the ordinary message.
          An UNASSIGNED subopcode cannot reach here — SkipExpr walked
          these same bytes during decoding and raised EWasmDecodeError for
          it — so, like the $FB else branch, that case is defensive. }
        Sub := FReader.ReadU32;
        if Sub = 12 then
          StepV128Const
        else
          NotConstant('$FD subopcode ' + IntToStr(Int64(Sub)), AOpOffset);
      end;
  else
    { Everything else in the single-byte space. An UNASSIGNED opcode
      would land here too and be reported as non-constant rather than as
      malformed — which cannot happen in practice, because
      Wasm.Decoder.Expr walked these same bytes during decoding and
      raised EWasmDecodeError for an unassigned opcode long before this
      unit ran. Duplicating its opcode table here to preserve the
      ordering in an unreachable case would be a second source of truth
      for no gain. }
    NotConstant(Format('opcode $%.2x', [AOpcode]), AOpOffset);
  end;
end;

procedure TConstWalker.Run(const AExpected: TWasmValueType);
var
  Opcode: Byte;
  OpOffset: NativeUInt;
begin
  repeat
    OpOffset := Offset;
    Opcode := FReader.ReadByte;
    if Opcode = OP_END then
      Break;
    Step(Opcode, OpOffset);
  until False;

  { Defensive: SkipExpr produced this span and its last byte is the
    terminating `end`, so nothing can follow. }
  if not FReader.Eof then
    raise EWasmDecodeError.CreateFmt(
      'constant expression continues past its terminating `end` at '
      + 'offset %u', [Offset]);

  { `Expr_const` / `valid-expr`: an initialiser yields exactly one
    value. }
  if FDepth <> 1 then
    raise EWasmValidationError.CreateFmt(
      '%s: constant expression yields %d value(s), but exactly one of '
      + 'type %s is required',
      [MSG_TYPE_MISMATCH, FDepth, AExpected.Describe]);

  if not FTypes.MatchesValType(FStack[0].ValType, AExpected) then
    raise EWasmValidationError.CreateFmt(
      '%s: constant expression yields %s, which does not match the '
      + 'required %s', [MSG_TYPE_MISMATCH, FStack[0].ValType.Describe,
      AExpected.Describe]);

  { Trimmed in the same procedure that finished building them (Wasm.Ir's
    building section): until here Length() on the three arrays is the
    capacity, and RegisterCount is the live register count. }
  IrTrimCode(FExpr.Code, FCodeCount);
  IrTrimRegTypes(FExpr.RegTypes, FRegCount);
  IrTrimAux(FExpr.AuxU32, FAuxCount);
  FExpr.RegisterCount := UInt32(FRegCount);

  FExpr.ResultReg := FStack[0].Reg;
end;

{ --- entry points -------------------------------------------------------- }

procedure AppendFuncRefs(var ATarget: TWasmConstFuncRefs;
  const ASource: TWasmConstFuncRefs; const ACount: Integer);
var
  I, Base: Integer;
begin
  if ACount = 0 then
    Exit;
  Base := Length(ATarget);
  SetLength(ATarget, Base + ACount);
  for I := 0 to ACount - 1 do
    ATarget[Base + I] := ASource[I];
end;

function ValidateConstExpr(const ATypes: TWasmTypeContext;
  const AConst: TWasmConstContext;
  const ABytes: TWasmBytes; const ASpan: TWasmSpan;
  const AExpected: TWasmValueType;
  var AFuncRefs: TWasmConstFuncRefs): TWasmIrInitExpr;
var
  Walker: TConstWalker;
begin
  Walker.Init(ATypes, AConst, ABytes, ASpan);
  Walker.Run(AExpected);
  { Appended only on success: a rejected module contributes nothing to
    C.REFS, and leaving half a segment's references behind would make the
    set depend on which error fired first. }
  AppendFuncRefs(AFuncRefs, Walker.FFuncRefs, Walker.FFuncRefCount);
  Result := Walker.Expr;
end;

function MakeRefFuncInitExpr(const ATypes: TWasmTypeContext;
  const AConst: TWasmConstContext;
  const AFuncIndex: UInt32; const AExpected: TWasmValueType;
  var AFuncRefs: TWasmConstFuncRefs): TWasmIrInitExpr;
var
  TypeIndex: UInt32;
  Ty: TWasmValueType;
  Base: Integer;
begin
  if AFuncIndex >= AConst.FuncCount then
    raise EWasmValidationError.CreateFmt(
      '%s: element segment names function %d, but the function index '
      + 'space holds %d', [UnknownIndex(MSG_UNKNOWN_FUNCTION,
      Int64(AFuncIndex)), Int64(AFuncIndex), Int64(AConst.FuncCount)]);

  TypeIndex := ConstFuncTypeIndex(AConst, AFuncIndex);
  ATypes.CanonIdOf(TypeIndex);
  Ty := MakeRefValueType(MakeRefType(False,
    MakeConcreteHeapType(TypeIndex)));

  if not ATypes.MatchesValType(Ty, AExpected) then
    raise EWasmValidationError.CreateFmt(
      '%s: element segment item is %s, which does not match the '
      + 'required %s', [MSG_TYPE_MISMATCH, Ty.Describe,
      AExpected.Describe]);

  Result.Code := nil;
  SetLength(Result.Code, 1);
  Result.Code[0] := MakeIrInstr(iroRefFunc, 0, IR_NO_REG, IR_NO_REG,
    Int64(AFuncIndex));
  Result.RegTypes := nil;
  SetLength(Result.RegTypes, 1);
  Result.RegTypes[0] := Ty;
  Result.RegisterCount := 1;
  Result.ResultReg := 0;
  Result.AuxU32 := nil;
  Result.AuxRefTypes := nil;

  Base := Length(AFuncRefs);
  SetLength(AFuncRefs, Base + 1);
  AFuncRefs[Base] := AFuncIndex;
end;

end.
