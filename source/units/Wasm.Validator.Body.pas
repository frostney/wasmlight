{ Wasm.Validator.Body — the fused body walk: decode, type-check, and emit
  the register IR for one function body, in a single pass over its bytes.

  ADR-0007 makes validation the only pass that reads the binary, and
  ADR-0012 makes what it emits register-based. Those two together are why
  this unit exists and why it is shaped the way it is: the spec's
  validation algorithm (`appendix/algorithm-stacks`,
  `appendix/algorithm-validation-of-opcode-sequences`) is implemented
  verbatim, extended so that every value-stack entry carries the virtual
  register holding it and every control frame carries the registers a
  branch to its label must write.

  TWO ERROR CLASSES COME OUT OF ONE WALK, and the distinction is
  load-bearing (AGENTS.md). Binary-grammar violations found inside a body
  are EWasmDecodeError: an unassigned opcode or prefixed subopcode, a
  truncated immediate, a misplaced `else`, a malformed block type, and —
  the one only this unit can see — a body whose terminating `end` is not
  the last byte of its code-entry span. The code section decoder
  deliberately does not walk bodies (Wasm.Decoder.Segments hands that
  obligation here in writing), so this walk is the FIRST structural pass
  over a function body. Everything about typing is EWasmValidationError.

  Spec anchors cited below were read from wasm-mcp 0.2.16, upstream
  spec/main d7b37e4170d8315f2f1283aed4e8076591a9a333.

  SCOPE. Every instruction the 3.0 draft defines is walked here: control
  flow, locals, the parametric and call families, the whole numeric
  family, globals, tables, memory, references, the $FB aggregate (GC)
  space, exception handling, and the $FD vector ($v128$) space. The
  vector arm is table-driven exactly as the numeric and load/store arms
  are (HandleVector over VEC_SIG); a $v128$ register is a PAIR of adjacent
  even-aligned 8-byte slots (SIMD design §1.3-§1.5), so IrAllocReg
  even-aligns a wvkVec allocation, FLocalReg maps a wasm local index to
  its low register, and a $v128$ move emits iroMoveVec. }
unit Wasm.Validator.Body;

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

const
  { `binary-datacntsec`: "The data count section is used to simplify
    single-pass validation. Since the data section occurs after the code
    section, the MEMORY.INIT and DATA.DROP instructions would not be able
    to check whether the data segment index is valid until the data
    section is read. The data count section occurs before the code
    section, so a single-pass validator can use this count instead of
    deferring validation."

    The rule is therefore a side condition of the BINARY grammar and a
    body naming a data segment without one is MALFORMED, not invalid.
    Track A pinned that class in writing at the code section's
    CodeEntry.Body site and deferred the check here, because only a body
    walk can see it. HIGH as a prefix.

    UNCONFIRMED in ONE respect: `binary-datacntsec` names only
    MEMORY.INIT and DATA.DROP, but `array.new_data` and
    `array.init_data` carry a dataidx too and the same single-pass
    argument applies word for word. The Track B design document decided
    to require the section for all four; Track C's assert_malformed
    cases settle it, and the decision lives at one call site
    (RequireDataCount). }
  MSG_DATA_COUNT_REQUIRED = 'data count section required';

  { An engine capacity refusal, and DELIBERATELY NOT A GRAMMAR RULE.
    `syntax-list` bounds a list at 2^32-1 elements and `binary-code`
    makes an expanded locals sequence above that MALFORMED — Track A's
    code section decoder enforces exactly that bound. What is left is
    the gap between that bound and what a register file can actually
    address: every local becomes a register, RegTypes is indexed by an
    Integer, and a module asking for two billion of them is well formed
    and well typed and still cannot be compiled here. That is neither
    `malformed` nor a typing failure, so it is reported as an
    EWasmValidationError naming itself an implementation limit rather
    than borrowing a conformance prefix it would misrepresent. No
    upstream testsuite case reaches it. One raise site. }
  MSG_LOCALS_IMPLEMENTATION_LIMIT =
    'implementation limit: too many locals';

  { `valid-memarg` classifies a memory argument "by the address type" of
    the memory: the static offset must fit that address type, so for a
    32-bit (i32) memory the offset must be < 2^32, while a memory64 admits
    the full u64. `syntax-loadn` spells out why — an i32 memory yields a
    33-bit effective address, which the 32-bit static offset cannot
    overflow. The offset is decoded as a u64 (Wasm.Decoder.Expr's
    SkipMemarg reads it as such), so the bound is a VALIDATION rule against
    the memory's address type, not a decode side condition. address.wast
    asserts the prefix "offset out of range" for offset=2^32 on `(memory 1)`. }
  MSG_OFFSET_OUT_OF_RANGE = 'offset out of range';

type
  TWasmValTypeList = array of TWasmValueType;
  TWasmRegList = array of UInt32;

  { Function index space -> module type index, imports first. Built once
    per module rather than once per function: the single-argument
    ValidateFunctionBody overload builds it itself and is O(functions)
    per call, so the module-level validator should build it once and use
    the overload that takes it. }
  TWasmFuncTypeIndices = array of UInt32;

  { C.REFS (`context`): "the list of function indices that occur in the
    module outside functions and can hence be used to form references
    inside them". `ref.func x` is valid only for an x in this set, so the
    walker needs it as an INPUT — the set is a whole-module property and
    a single function body cannot derive it.

    One flag per function index (imports first). An index at or past the
    array's end reads as False, so an empty array means "nothing is
    declared" and every `ref.func` fails with
    MSG_UNDECLARED_FUNCTION_REFERENCE. }
  TWasmDeclaredFuncs = array of Boolean;

  TWasmTableTypeList = array of TWasmTableType;
  TWasmMemTypeList = array of TWasmMemType;
  TWasmGlobalTypeList = array of TWasmGlobalType;
  TWasmRefTypeList = array of TWasmRefType;

  { EVERY index space a function body can name (`context`), imports
    first, in one record built ONCE PER MODULE.

    It lives here rather than in Wasm.Validator because the body walk is
    the only consumer that needs all of it and because Wasm.Validator
    already depends on this unit — the reverse would be a cycle. The
    module-level validator builds one of these, uses it for its own
    module-shape rules, and hands the same record to every body; the
    self-building overloads below exist for standalone use (tests, and
    a caller validating one body in isolation) and simply call
    BuildIndexSpaces themselves.

    DeclaredFuncs (C.REFS) rides along because it is per-module too, but
    it is the ONE field a module-level caller must overwrite after
    building: BuildDeclaredFuncSet cannot see `ref.func` inside a
    constant expression, and the union is Wasm.Validator's to compute
    (its header explains why). }
  TWasmIndexSpaces = record
    FuncTypes: TWasmFuncTypeIndices;
    Tables: TWasmTableTypeList;
    Memories: TWasmMemTypeList;
    Globals: TWasmGlobalTypeList;
    { Tag index space, as MODULE TYPE INDICES (`syntax-tagtype`: a tag
      type is a type use referring to a function type). }
    Tags: TWasmFuncTypeIndices;
    { Element segment index space, by the segment's reference type
      (`context`: element segments are "represented by the elements'
      reference type"). Element segments cannot be imported. }
    ElemTypes: TWasmRefTypeList;
    { Data segments are "each represented by an OK entry" (`context`), so
      only the COUNT matters — and the count comes from the data count
      section, not the data section, which is why its absence is a
      grammar violation rather than a bounds failure. }
    HasDataCount: Boolean;
    DataCount: UInt32;
    DeclaredFuncs: TWasmDeclaredFuncs;
  end;

{ The function index space (imports first), as the `call` family reads
  it. }
function BuildFunctionTypeIndexSpace(
  const AModule: TWasmModule): TWasmFuncTypeIndices;

{ The part of C.REFS a caller holding only the decoded model can compute:
  element segments in the funcidx-VECTOR form (every mode, declarative
  included), the export list's function entries, and the start function.

  DELIBERATELY INCOMPLETE, and this is the contract the module-level
  integrator must honour: `ref.func` occurrences inside CONSTANT
  EXPRESSIONS — global initialisers, table initialisers, and element
  items in the expression form — also declare a function, and reading
  those needs Wasm.Validator.Const, which the fused body walk has no
  business invoking. `ValidateConstExpr` already appends every index it
  sees to a caller-supplied array; the module-level validator unions that
  with this set and puts the result into the TWasmIndexSpaces record it
  hands to the body walk. Using this helper alone rejects `ref.func`
  on a function declared only by a constant expression, which is a wrong
  REJECTION, never a wrong acceptance. }
function BuildDeclaredFuncSet(
  const AModule: TWasmModule): TWasmDeclaredFuncs;

{ Every index space at once, which is what a module-level walk wants:
  one pass over the import list instead of one per function body.
  DeclaredFuncs is filled with BuildDeclaredFuncSet's partial answer and
  is the field a module-level caller replaces (see the record). }
procedure BuildIndexSpaces(const AModule: TWasmModule;
  out ASpaces: TWasmIndexSpaces);

{ Validates one function body and returns its IR. ABytes is the whole
  module buffer; AEntry.Body is an ABSOLUTE span into it (ADR-0003).
  ATypeIndex is the function's type index in the module type space.

  Raises EWasmDecodeError for binary-grammar violations and
  EWasmValidationError for typing violations — see the unit header. }
function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32;
  const AEntry: TWasmCodeEntry): TWasmIrFunction; overload;

function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
  const AFuncTypes: TWasmFuncTypeIndices): TWasmIrFunction; overload;

{ The full form. ADeclaredFuncs is C.REFS; the two overloads above derive
  what they can with BuildDeclaredFuncSet and are therefore stricter about
  `ref.func` than a module-level walk should be. }
function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
  const AFuncTypes: TWasmFuncTypeIndices;
  const ADeclaredFuncs: TWasmDeclaredFuncs): TWasmIrFunction; overload;

{ The form a module-level walk uses: the index spaces are built once for
  the whole module and every body reads the same record. The overloads
  above are the standalone forms and rebuild them per call. }
function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
  const ASpaces: TWasmIndexSpaces): TWasmIrFunction; overload;

{ --- emission primitives, exposed for tests ------------------------------

  The append primitives themselves live in Wasm.Ir — one growth policy
  and one aliasing rule for every IR producer — and this unit imports
  them. What is exposed HERE is the parallel move, because its cycle
  path is believed unreachable for well-formed wasm and "believed" is
  not a proof, so it gets a direct test rather than only an indirect
  one. ACode / ARegTypes are grown geometrically and ACodeCount /
  ARegCount are the live element counts; the caller trims with
  Wasm.Ir's IrTrim* when it is done. }

{ The parallel move at a branch edge: MergeRegs[i] <- Sources[i], all
  conceptually simultaneous. Self-moves are dropped, a source that is
  also a destination is ordered after its reader, and a cycle is broken
  by copying one destination into a fresh temporary. }
procedure EmitParallelMove(var ACode: TWasmIrCode; var ACodeCount: Integer;
  var ARegTypes: TWasmIrRegTypes; var ARegCount: Integer;
  const ADests, ASources: array of UInt32);

implementation

{ --- small helpers -------------------------------------------------------- }

function CopyValTypes(
  const A: array of TWasmValueType): TWasmValTypeList;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function MakeI32: TWasmValueType;
begin
  Result := MakeNumValueType(wntI32);
end;

{ Defaultable value types (`valid-local`): numbers, vectors, and NULLABLE
  references have a default value; a non-nullable reference does not, so
  such a local starts uninitialized. }
function IsDefaultable(const A: TWasmValueType): Boolean;
begin
  Result := (A.Kind <> wvkRef) or A.Ref.Nullable;
end;

function MakeAbsRef(const ANullable: Boolean;
  const AAbs: TWasmAbsHeapType): TWasmValueType;
begin
  Result := MakeRefValueType(
    MakeRefType(ANullable, MakeAbsHeapType(AAbs)));
end;

function MakeConcreteRef(const ANullable: Boolean;
  const ATypeIndex: UInt32): TWasmValueType;
begin
  Result := MakeRefValueType(
    MakeRefType(ANullable, MakeConcreteHeapType(ATypeIndex)));
end;

{ The value type an operand of a memory or table whose address type is A
  must have (`valid-memarg`, and every `at` in the table and memory
  signatures — `instruction_get memory.size` renders `[] -> [at]`, not
  `[] -> [i32]`). memory64 and table64 are in the pinned draft, so this
  is never unconditionally i32. }
function AddrValType(const A: TWasmAddrType): TWasmValueType;
begin
  if A = watI64 then
    Result := MakeNumValueType(wntI64)
  else
    Result := MakeI32;
end;

{ `aux-reftypediff`: the difference "computes an approximation of the
  reference type that is inhabited by all values from rt_1 except those
  from rt_2 … the definition only affects the presence of null and cannot
  express the absence of other values". So it clears rt1's nullability
  exactly when rt2 is nullable and leaves the heap type alone.

  TRAP, and the reason this helper is named after the INFIX form: the
  appendix pseudocode writes `diff_ref_type(rt2, rt1)`, whose argument
  order is the reverse of the spec's `t_1 \reftypediff t_2` in
  `instruction_get br_on_cast`'s signature. This computes ARt1 \ ARt2. }
function RefTypeDiff(const ARt1, ARt2: TWasmRefType): TWasmRefType;
begin
  Result := ARt1;
  if ARt2.Nullable then
    Result.Nullable := False;
end;

{ `aux-default` via `appendix/algorithm-types`' unpack_field: a PACKED
  field always has a default (the zero of its width), so defaultability
  is a question about value storage only. }
function IsDefaultableStorage(const A: TWasmStorageType): Boolean;
begin
  Result := A.IsPacked or IsDefaultable(A.ValueType);
end;

{ `appendix/algorithm-types`: "func unpack_field(t : field_type) :
  val_type = if (it = I8 || t = I16) return I32; return t". Packed
  storage is not a value type and never reaches the operand stack. }
function UnpackField(const A: TWasmFieldType): TWasmValueType;
begin
  if A.Storage.IsPacked then
    Result := MakeI32
  else
    Result := A.Storage.ValueType;
end;

{ A move of register AReg is iroMoveVec when AReg is a v128 (a pair of
  slots, 16 bytes) and iroMove otherwise. The validator knows the width
  statically, so the interpreter never has to (SIMD design §2.4). }
function MoveOpFor(const ARegTypes: TWasmIrRegTypes;
  const AReg: UInt32): TWasmIrOp;
begin
  if (AReg < UInt32(Length(ARegTypes)))
    and (ARegTypes[AReg].Kind = wvkVec) then
    Result := iroMoveVec
  else
    Result := iroMove;
end;

{ The call ABI names SLOTS, not values: a v128 argument/result contributes
  TWO consecutive entries (its low register and low+1), so PushWasmFrame and
  DoReturn's positional per-slot copy carry all 16 bytes and land later
  operands at the callee's even-aligned slots (SIMD design §1.6). A value
  list would copy only the low half and misplace every operand after the
  first vector. ARegs holds one low register per value; ATypes runs
  in step. }
function SlotList(const ARegs: TWasmRegList;
  const ATypes: TWasmValTypeList): TWasmRegList;
var
  I, N: Integer;
begin
  SetLength(Result, 0);
  N := 0;
  for I := 0 to High(ARegs) do
    if (I <= High(ATypes)) and (ATypes[I].Kind = wvkVec) then
    begin
      SetLength(Result, N + 2);
      Result[N] := ARegs[I];
      Result[N + 1] := ARegs[I] + 1;
      Inc(N, 2);
    end
    else
    begin
      SetLength(Result, N + 1);
      Result[N] := ARegs[I];
      Inc(N);
    end;
end;

procedure EmitParallelMove(var ACode: TWasmIrCode; var ACodeCount: Integer;
  var ARegTypes: TWasmIrRegTypes; var ARegCount: Integer;
  const ADests, ASources: array of UInt32);
var
  Dests, Srcs: TWasmRegList;
  Live: array of Boolean;
  Count, Remaining, I, J: Integer;
  Progress, IsSource: Boolean;
  Tmp: UInt32;
begin
  Count := Length(ADests);
  if Count = 0 then
    Exit;

  SetLength(Dests, Count);
  SetLength(Srcs, Count);
  SetLength(Live, Count);
  Remaining := 0;
  for I := 0 to Count - 1 do
  begin
    Dests[I] := ADests[I];
    Srcs[I] := ASources[I];
    { Step 1: drop self-moves. }
    Live[I] := Dests[I] <> Srcs[I];
    if Live[I] then
      Inc(Remaining);
  end;

  while Remaining > 0 do
  begin
    { Step 2: emit every pair whose destination is nobody's source. }
    repeat
      Progress := False;
      for I := 0 to Count - 1 do
      begin
        if not Live[I] then
          Continue;
        IsSource := False;
        for J := 0 to Count - 1 do
          if Live[J] and (Srcs[J] = Dests[I]) then
          begin
            IsSource := True;
            Break;
          end;
        if IsSource then
          Continue;
        IrEmitInstr(ACode, ACodeCount,
          MakeIrInstr(MoveOpFor(ARegTypes, Dests[I]), Dests[I], Srcs[I],
            IR_NO_REG, 0));
        Live[I] := False;
        Dec(Remaining);
        Progress := True;
      end;
    until (not Progress) or (Remaining = 0);

    if Remaining = 0 then
      Break;

    { Step 3: what is left is one or more cycles. Break one by copying a
      destination aside and rewriting every reader of it. Each iteration
      removes exactly one cycle, so this terminates. }
    for I := 0 to Count - 1 do
      if Live[I] then
      begin
        Tmp := IrAllocReg(ARegTypes, ARegCount, ARegTypes[Dests[I]]);
        IrEmitInstr(ACode, ACodeCount,
          MakeIrInstr(MoveOpFor(ARegTypes, Dests[I]), Tmp, Dests[I],
            IR_NO_REG, 0));
        for J := 0 to Count - 1 do
          if Live[J] and (Srcs[J] = Dests[I]) then
            Srcs[J] := Tmp;
        Break;
      end;
  end;
end;

function BuildFunctionTypeIndexSpace(
  const AModule: TWasmModule): TWasmFuncTypeIndices;
var
  I, N: Integer;
  Imp: TWasmImport;
begin
  SetLength(Result, AModule.TotalFunctionCount);
  N := 0;
  for I := 0 to AModule.ImportCount - 1 do
  begin
    Imp := AModule.Imports[I];
    if Imp.Kind = wxkFunc then
    begin
      Result[N] := Imp.FuncTypeIndex;
      Inc(N);
    end;
  end;
  for I := 0 to AModule.FunctionTypeIndexCount - 1 do
  begin
    Result[N] := AModule.FunctionTypeIndices[I];
    Inc(N);
  end;
end;

function BuildDeclaredFuncSet(
  const AModule: TWasmModule): TWasmDeclaredFuncs;
var
  I, J, Total: Integer;
  Seg: TWasmElemSegment;
  Exp: TWasmExport;

  procedure Declare(const AIndex: UInt32);
  begin
    { Out-of-range indices are somebody else's error to report — the
      export/element/start rules own them — so they are dropped rather
      than raised on here. }
    if AIndex < UInt32(Total) then
      Result[AIndex] := True;
  end;

begin
  Total := AModule.TotalFunctionCount;
  SetLength(Result, Total);
  for I := 0 to Total - 1 do
    Result[I] := False;

  { Element segments in the funcidx-VECTOR form. Every mode counts, not
    just the declarative one: `context`'s C.REFS is "the list of function
    indices that occur in the module outside functions", and an active or
    passive segment's items occur there just as much. }
  for I := 0 to AModule.ElementCount - 1 do
  begin
    Seg := AModule.Elements[I];
    if not Seg.UsesExprs then
      for J := 0 to High(Seg.FuncIndices) do
        Declare(Seg.FuncIndices[J]);
  end;

  for I := 0 to AModule.ExportCount - 1 do
  begin
    Exp := AModule.&Exports[I];
    if Exp.Kind = wxkFunc then
      Declare(Exp.Index);
  end;

  { The start function is NOT in C.REFS. The reference set is only the
    function indices that occur OUTSIDE functions — in globals, element
    segments, and exports (`context`: "the list of function indices that
    occur in the module outside functions"). Naming a function as start does
    not declare it, so `(module (start $f) (func $f (drop (ref.func $f))))`
    is INVALID with `undeclared function reference` (ref_func.wast:112-115). }
end;

{ Every index space in ONE pass over the import list, IMPORTS FIRST —
  that is the numbering every index immediate in a body means
  (`context`). Element and data segments have no import form, so they
  are the module's own only. }
procedure BuildIndexSpaces(const AModule: TWasmModule;
  out ASpaces: TWasmIndexSpaces);
var
  I, N, M, Gl, Tg: Integer;
  Imp: TWasmImport;
begin
  ASpaces.FuncTypes := BuildFunctionTypeIndexSpace(AModule);
  ASpaces.DeclaredFuncs := BuildDeclaredFuncSet(AModule);

  SetLength(ASpaces.Tables, AModule.TotalTableCount);
  SetLength(ASpaces.Memories, AModule.TotalMemoryCount);
  SetLength(ASpaces.Globals, AModule.TotalGlobalCount);
  SetLength(ASpaces.Tags, AModule.TotalTagCount);
  N := 0;
  M := 0;
  Gl := 0;
  Tg := 0;
  for I := 0 to AModule.ImportCount - 1 do
  begin
    Imp := AModule.Imports[I];
    case Imp.Kind of
      wxkTable:
        begin
          ASpaces.Tables[N] := Imp.Table;
          Inc(N);
        end;
      wxkMem:
        begin
          ASpaces.Memories[M] := Imp.Mem;
          Inc(M);
        end;
      wxkGlobal:
        begin
          ASpaces.Globals[Gl] := Imp.Global;
          Inc(Gl);
        end;
      wxkTag:
        begin
          ASpaces.Tags[Tg] := Imp.Tag.TypeIndex;
          Inc(Tg);
        end;
    end;
  end;
  for I := 0 to AModule.TableCount - 1 do
  begin
    ASpaces.Tables[N] := AModule.Tables[I].TableType;
    Inc(N);
  end;
  for I := 0 to AModule.MemoryCount - 1 do
  begin
    ASpaces.Memories[M] := AModule.Memories[I];
    Inc(M);
  end;
  for I := 0 to AModule.GlobalCount - 1 do
  begin
    ASpaces.Globals[Gl] := AModule.Globals[I].GlobalType;
    Inc(Gl);
  end;
  for I := 0 to AModule.TagCount - 1 do
  begin
    ASpaces.Tags[Tg] := AModule.Tags[I].TypeIndex;
    Inc(Tg);
  end;

  SetLength(ASpaces.ElemTypes, AModule.ElementCount);
  for I := 0 to AModule.ElementCount - 1 do
    ASpaces.ElemTypes[I] := AModule.Elements[I].RefType;

  { The data segment COUNT comes from the data count section, never from
    the data section: the data section sits after the code section, which
    is the whole reason `binary-datacntsec` exists. Its absence is what
    CheckData reports as malformed. }
  ASpaces.HasDataCount := AModule.HasDataCount;
  ASpaces.DataCount := AModule.DataCount;
end;

{ --- the numeric signature table -----------------------------------------

  Driving the 140 numeric instructions from a table rather than 140 hand
  written arms is not only shorter, it is the only way the mapping stays
  checkable: TWasmIrOp's numeric members are dense and in wasm opcode
  order, so the IR op is
  TWasmIrOp(Ord(iroI32Eqz) + Op - $45) for the whole $45..$C4 run and
  TWasmIrOp(Ord(iroI32TruncSatF32S) + Sub) for $FC 0..7.

  Signatures read from `instruction_list category=numeric` and spot
  checked with `instruction_get` (i32.eqz `valid-testop` [i32]->[i32],
  f32.eq `valid-relop` [f32 f32]->[i32], i32.wrap_i64 `valid-cvtop`
  [i64]->[i32], f32.convert_i64_u `valid-cvtop` [i64]->[f32]). The
  grouped validation anchors are `valid-unop`, `valid-binop`,
  `valid-testop`, `valid-relop`, and `valid-cvtop`. }

type
  TNumSig = record
    Arity: Byte;             { 1 or 2; both operands share Operand }
    Operand: TWasmNumType;
    ResultType: TWasmNumType;
  end;

const
  NUM_SIG: array[$45..$C4] of TNumSig = (
    { $45 i32.eqz }
    (Arity: 1; Operand: wntI32; ResultType: wntI32),
    { $46..$4F i32.eq .. i32.ge_u }
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    { $50 i64.eqz }
    (Arity: 1; Operand: wntI64; ResultType: wntI32),
    { $51..$5A i64.eq .. i64.ge_u }
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    (Arity: 2; Operand: wntI64; ResultType: wntI32),
    { $5B..$60 f32.eq .. f32.ge }
    (Arity: 2; Operand: wntF32; ResultType: wntI32),
    (Arity: 2; Operand: wntF32; ResultType: wntI32),
    (Arity: 2; Operand: wntF32; ResultType: wntI32),
    (Arity: 2; Operand: wntF32; ResultType: wntI32),
    (Arity: 2; Operand: wntF32; ResultType: wntI32),
    (Arity: 2; Operand: wntF32; ResultType: wntI32),
    { $61..$66 f64.eq .. f64.ge }
    (Arity: 2; Operand: wntF64; ResultType: wntI32),
    (Arity: 2; Operand: wntF64; ResultType: wntI32),
    (Arity: 2; Operand: wntF64; ResultType: wntI32),
    (Arity: 2; Operand: wntF64; ResultType: wntI32),
    (Arity: 2; Operand: wntF64; ResultType: wntI32),
    (Arity: 2; Operand: wntF64; ResultType: wntI32),
    { $67..$69 i32.clz, i32.ctz, i32.popcnt }
    (Arity: 1; Operand: wntI32; ResultType: wntI32),
    (Arity: 1; Operand: wntI32; ResultType: wntI32),
    (Arity: 1; Operand: wntI32; ResultType: wntI32),
    { $6A..$78 i32.add .. i32.rotr }
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    (Arity: 2; Operand: wntI32; ResultType: wntI32),
    { $79..$7B i64.clz, i64.ctz, i64.popcnt }
    (Arity: 1; Operand: wntI64; ResultType: wntI64),
    (Arity: 1; Operand: wntI64; ResultType: wntI64),
    (Arity: 1; Operand: wntI64; ResultType: wntI64),
    { $7C..$8A i64.add .. i64.rotr }
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    (Arity: 2; Operand: wntI64; ResultType: wntI64),
    { $8B..$91 f32.abs .. f32.sqrt }
    (Arity: 1; Operand: wntF32; ResultType: wntF32),
    (Arity: 1; Operand: wntF32; ResultType: wntF32),
    (Arity: 1; Operand: wntF32; ResultType: wntF32),
    (Arity: 1; Operand: wntF32; ResultType: wntF32),
    (Arity: 1; Operand: wntF32; ResultType: wntF32),
    (Arity: 1; Operand: wntF32; ResultType: wntF32),
    (Arity: 1; Operand: wntF32; ResultType: wntF32),
    { $92..$98 f32.add .. f32.copysign }
    (Arity: 2; Operand: wntF32; ResultType: wntF32),
    (Arity: 2; Operand: wntF32; ResultType: wntF32),
    (Arity: 2; Operand: wntF32; ResultType: wntF32),
    (Arity: 2; Operand: wntF32; ResultType: wntF32),
    (Arity: 2; Operand: wntF32; ResultType: wntF32),
    (Arity: 2; Operand: wntF32; ResultType: wntF32),
    (Arity: 2; Operand: wntF32; ResultType: wntF32),
    { $99..$9F f64.abs .. f64.sqrt }
    (Arity: 1; Operand: wntF64; ResultType: wntF64),
    (Arity: 1; Operand: wntF64; ResultType: wntF64),
    (Arity: 1; Operand: wntF64; ResultType: wntF64),
    (Arity: 1; Operand: wntF64; ResultType: wntF64),
    (Arity: 1; Operand: wntF64; ResultType: wntF64),
    (Arity: 1; Operand: wntF64; ResultType: wntF64),
    (Arity: 1; Operand: wntF64; ResultType: wntF64),
    { $A0..$A6 f64.add .. f64.copysign }
    (Arity: 2; Operand: wntF64; ResultType: wntF64),
    (Arity: 2; Operand: wntF64; ResultType: wntF64),
    (Arity: 2; Operand: wntF64; ResultType: wntF64),
    (Arity: 2; Operand: wntF64; ResultType: wntF64),
    (Arity: 2; Operand: wntF64; ResultType: wntF64),
    (Arity: 2; Operand: wntF64; ResultType: wntF64),
    (Arity: 2; Operand: wntF64; ResultType: wntF64),
    { $A7 i32.wrap_i64 }
    (Arity: 1; Operand: wntI64; ResultType: wntI32),
    { $A8..$AB i32.trunc_f32_s .. i32.trunc_f64_u }
    (Arity: 1; Operand: wntF32; ResultType: wntI32),
    (Arity: 1; Operand: wntF32; ResultType: wntI32),
    (Arity: 1; Operand: wntF64; ResultType: wntI32),
    (Arity: 1; Operand: wntF64; ResultType: wntI32),
    { $AC..$AD i64.extend_i32_s / _u }
    (Arity: 1; Operand: wntI32; ResultType: wntI64),
    (Arity: 1; Operand: wntI32; ResultType: wntI64),
    { $AE..$B1 i64.trunc_f32_s .. i64.trunc_f64_u }
    (Arity: 1; Operand: wntF32; ResultType: wntI64),
    (Arity: 1; Operand: wntF32; ResultType: wntI64),
    (Arity: 1; Operand: wntF64; ResultType: wntI64),
    (Arity: 1; Operand: wntF64; ResultType: wntI64),
    { $B2..$B5 f32.convert_i32_s .. f32.convert_i64_u }
    (Arity: 1; Operand: wntI32; ResultType: wntF32),
    (Arity: 1; Operand: wntI32; ResultType: wntF32),
    (Arity: 1; Operand: wntI64; ResultType: wntF32),
    (Arity: 1; Operand: wntI64; ResultType: wntF32),
    { $B6 f32.demote_f64 }
    (Arity: 1; Operand: wntF64; ResultType: wntF32),
    { $B7..$BA f64.convert_i32_s .. f64.convert_i64_u }
    (Arity: 1; Operand: wntI32; ResultType: wntF64),
    (Arity: 1; Operand: wntI32; ResultType: wntF64),
    (Arity: 1; Operand: wntI64; ResultType: wntF64),
    (Arity: 1; Operand: wntI64; ResultType: wntF64),
    { $BB f64.promote_f32 }
    (Arity: 1; Operand: wntF32; ResultType: wntF64),
    { $BC..$BF the four reinterprets }
    (Arity: 1; Operand: wntF32; ResultType: wntI32),
    (Arity: 1; Operand: wntF64; ResultType: wntI64),
    (Arity: 1; Operand: wntI32; ResultType: wntF32),
    (Arity: 1; Operand: wntI64; ResultType: wntF64),
    { $C0..$C1 i32.extend8_s, i32.extend16_s }
    (Arity: 1; Operand: wntI32; ResultType: wntI32),
    (Arity: 1; Operand: wntI32; ResultType: wntI32),
    { $C2..$C4 i64.extend8_s, i64.extend16_s, i64.extend32_s }
    (Arity: 1; Operand: wntI64; ResultType: wntI64),
    (Arity: 1; Operand: wntI64; ResultType: wntI64),
    (Arity: 1; Operand: wntI64; ResultType: wntI64)
  );

  { $FC 0..7, the saturating truncations. }
  TRUNC_SAT_SIG: array[0..7] of TNumSig = (
    (Arity: 1; Operand: wntF32; ResultType: wntI32),
    (Arity: 1; Operand: wntF32; ResultType: wntI32),
    (Arity: 1; Operand: wntF64; ResultType: wntI32),
    (Arity: 1; Operand: wntF64; ResultType: wntI32),
    (Arity: 1; Operand: wntF32; ResultType: wntI64),
    (Arity: 1; Operand: wntF32; ResultType: wntI64),
    (Arity: 1; Operand: wntF64; ResultType: wntI64),
    (Arity: 1; Operand: wntF64; ResultType: wntI64)
  );

{ --- the memory access table ----------------------------------------------

  $28..$3E is 23 CONSECUTIVE opcodes — 14 loads then 9 stores — and
  TWasmIrOp's iroI32Load .. iroI64Store32 run is the same 23 members in
  the same order, so the IR op is
  TWasmIrOp(Ord(iroI32Load) + Op - $28) and needs no table column.

  What the table does carry is the value type moved and the access WIDTH
  in bits, because the alignment side condition is stated on the width:
  `valid-memarg` classifies memory arguments "by the address type and the
  bit width of the access they are suitable for", and the rule is
  2^align <= N/8. MaxAlign below is log2(N/8), so the check is a plain
  comparison and nothing is ever shifted.

  Signatures spot-checked with `instruction_get`: i32.load is [at]->[i32]
  (`valid-load-val`), i32.load8_s is [at]->[i32] (`valid-load-pack`), and
  the store family is `valid-store-val` / `valid-store-pack`. The address
  operand is the MEMORY'S ADDRESS TYPE, never unconditionally i32. }

type
  TMemSig = record
    Value: TWasmNumType;   { the type loaded or stored }
    MaxAlign: Byte;        { log2(N/8) }
    IsStore: Boolean;
  end;

const
  MEM_SIG: array[$28..$3E] of TMemSig = (
    { $28..$2B i32.load, i64.load, f32.load, f64.load }
    (Value: wntI32; MaxAlign: 2; IsStore: False),
    (Value: wntI64; MaxAlign: 3; IsStore: False),
    (Value: wntF32; MaxAlign: 2; IsStore: False),
    (Value: wntF64; MaxAlign: 3; IsStore: False),
    { $2C..$2F i32.load8_s/_u, i32.load16_s/_u }
    (Value: wntI32; MaxAlign: 0; IsStore: False),
    (Value: wntI32; MaxAlign: 0; IsStore: False),
    (Value: wntI32; MaxAlign: 1; IsStore: False),
    (Value: wntI32; MaxAlign: 1; IsStore: False),
    { $30..$35 i64.load8_s/_u, load16_s/_u, load32_s/_u }
    (Value: wntI64; MaxAlign: 0; IsStore: False),
    (Value: wntI64; MaxAlign: 0; IsStore: False),
    (Value: wntI64; MaxAlign: 1; IsStore: False),
    (Value: wntI64; MaxAlign: 1; IsStore: False),
    (Value: wntI64; MaxAlign: 2; IsStore: False),
    (Value: wntI64; MaxAlign: 2; IsStore: False),
    { $36..$39 i32.store, i64.store, f32.store, f64.store }
    (Value: wntI32; MaxAlign: 2; IsStore: True),
    (Value: wntI64; MaxAlign: 3; IsStore: True),
    (Value: wntF32; MaxAlign: 2; IsStore: True),
    (Value: wntF64; MaxAlign: 3; IsStore: True),
    { $3A..$3B i32.store8, i32.store16 }
    (Value: wntI32; MaxAlign: 0; IsStore: True),
    (Value: wntI32; MaxAlign: 1; IsStore: True),
    { $3C..$3E i64.store8, i64.store16, i64.store32 }
    (Value: wntI64; MaxAlign: 0; IsStore: True),
    (Value: wntI64; MaxAlign: 1; IsStore: True),
    (Value: wntI64; MaxAlign: 2; IsStore: True)
  );

{ --- the vector ($FD) signature table -------------------------------------

  Driving the 256 vector instructions from a table, exactly as the numeric
  and load/store arms are driven, is what keeps the typing checkable: each
  op's family fixes its stack signature (SIMD design §3.2, anchors
  valid-vunop / valid-vbinop / valid-vternop / valid-vrelop /
  valid-vtestop / valid-vshiftop / valid-vbitmask / valid-vcvtop /
  valid-vsplat / valid-vextract_lane / valid-vreplace_lane /
  valid-vshuffle / valid-vswizzlop / valid-vload* / valid-vstore*), and
  Scalar/Dim/MaxAlign carry the family-specific detail.

  The table is indexed by the raw $FD subopcode 0..275; the 20 unassigned
  slots carry a filler row that HandleVector never reads because the
  Prefixed dispatch routes an unassigned subopcode to a decode error
  first. The IR op to emit is NOT a table column: TWasmIrOp's vector
  members are dense and in subopcode order, so VecOpBySub (built once at
  unit initialisation by walking the assigned subopcodes) maps a subopcode
  to its op with no second hand-maintained list.

  Relaxed ops type identically to their non-relaxed twins — the result is
  implementation-defined, never the type (SIMD design §3.2). }

type
  TVecFamily = (
    vfNullary,      { v128.const                 [] -> [v128] + 16-byte imm }
    vfShuffle,      { i8x16.shuffle    [v128 v128] -> [v128] + 16 lane bytes }
    vfUnary,        { [v128] -> [v128] }
    vfBinary,       { [v128 v128] -> [v128] }
    vfTernary,      { [v128 v128 v128] -> [v128], third source in Imm }
    vfTest,         { [v128] -> [i32]  (any_true / all_true / bitmask) }
    vfShift,        { [v128 i32] -> [v128] }
    vfSplat,        { [Scalar] -> [v128] }
    vfExtract,      { [v128] -> [Scalar] + lane imm }
    vfReplace,      { [v128 Scalar] -> [v128] + lane imm }
    vfLoad,         { [at] -> [v128], memarg }
    vfStore,        { [at v128] -> [], memarg }
    vfLoadLane,     { [at v128] -> [v128], memarg + lane }
    vfStoreLane);   { [at v128] -> [], memarg + lane }

  TVecSig = record
    Family: TVecFamily;
    Scalar: TWasmNumType;   { splat / extract / replace scalar; else filler }
    Dim: Byte;              { lane count for the lane-index bound; 0 = n/a }
    MaxAlign: Byte;         { log2(access bytes) for the memory families }
  end;

const
  { The 20 unassigned subopcodes carry a filler row — (vfUnary, i32, 0, 0)
    — that HandleVector never reads, because Prefixed routes an unassigned
    subopcode to a decode error before HandleVector runs. }
  VEC_SIG: array[0..275] of TVecSig = (
    { 0..10 whole / packed / splat loads — memarg }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 4),   { 0 v128.load }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),   { 1 load8x8_s }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),   { 2 load8x8_u }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),   { 3 load16x4_s }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),   { 4 load16x4_u }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),   { 5 load32x2_s }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),   { 6 load32x2_u }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 7 load8_splat }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 1),   { 8 load16_splat }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 2),   { 9 load32_splat }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),   { 10 load64_splat }
    (Family: vfStore; Scalar: wntI32; Dim: 0; MaxAlign: 4),  { 11 v128.store }
    { 12..13 const / shuffle — 16-byte immediate }
    (Family: vfNullary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 12 v128.const }
    (Family: vfShuffle; Scalar: wntI32; Dim: 32; MaxAlign: 0), { 13 shuffle }
    { 14..20 swizzle and splat }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 14 swizzle }
    (Family: vfSplat; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 15 i8x16.splat }
    (Family: vfSplat; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 16 i16x8.splat }
    (Family: vfSplat; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 17 i32x4.splat }
    (Family: vfSplat; Scalar: wntI64; Dim: 0; MaxAlign: 0),   { 18 i64x2.splat }
    (Family: vfSplat; Scalar: wntF32; Dim: 0; MaxAlign: 0),   { 19 f32x4.splat }
    (Family: vfSplat; Scalar: wntF64; Dim: 0; MaxAlign: 0),   { 20 f64x2.splat }
    { 21..34 lane access — one lane byte, bound = Dim }
    (Family: vfExtract; Scalar: wntI32; Dim: 16; MaxAlign: 0), { 21 i8x16 s }
    (Family: vfExtract; Scalar: wntI32; Dim: 16; MaxAlign: 0), { 22 i8x16 u }
    (Family: vfReplace; Scalar: wntI32; Dim: 16; MaxAlign: 0), { 23 i8x16 }
    (Family: vfExtract; Scalar: wntI32; Dim: 8; MaxAlign: 0),  { 24 i16x8 s }
    (Family: vfExtract; Scalar: wntI32; Dim: 8; MaxAlign: 0),  { 25 i16x8 u }
    (Family: vfReplace; Scalar: wntI32; Dim: 8; MaxAlign: 0),  { 26 i16x8 }
    (Family: vfExtract; Scalar: wntI32; Dim: 4; MaxAlign: 0),  { 27 i32x4 }
    (Family: vfReplace; Scalar: wntI32; Dim: 4; MaxAlign: 0),  { 28 i32x4 }
    (Family: vfExtract; Scalar: wntI64; Dim: 2; MaxAlign: 0),  { 29 i64x2 }
    (Family: vfReplace; Scalar: wntI64; Dim: 2; MaxAlign: 0),  { 30 i64x2 }
    (Family: vfExtract; Scalar: wntF32; Dim: 4; MaxAlign: 0),  { 31 f32x4 }
    (Family: vfReplace; Scalar: wntF32; Dim: 4; MaxAlign: 0),  { 32 f32x4 }
    (Family: vfExtract; Scalar: wntF64; Dim: 2; MaxAlign: 0),  { 33 f64x2 }
    (Family: vfReplace; Scalar: wntF64; Dim: 2; MaxAlign: 0),  { 34 f64x2 }
    { 35..76 comparisons — all [v128 v128] -> [v128] }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 35 i8x16.eq }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 36 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 37 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 38 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 39 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 40 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 41 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 42 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 43 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 44 i8x16.ge_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 45 i16x8.eq }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 46 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 47 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 48 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 49 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 50 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 51 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 52 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 53 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 54 i16x8.ge_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 55 i32x4.eq }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 56 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 57 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 58 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 59 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 60 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 61 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 62 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 63 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 64 i32x4.ge_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 65 f32x4.eq }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 66 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 67 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 68 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 69 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 70 f32x4.ge }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 71 f64x2.eq }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 72 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 73 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 74 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 75 }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 76 f64x2.ge }
    { 77..83 bitwise and the whole-vector test }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 77 v128.not }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 78 v128.and }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 79 v128.andnot }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 80 v128.or }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 81 v128.xor }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 82 bitselect }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 83 any_true }
    { 84..93 lane and zero loads/stores — memarg (+ lane) }
    (Family: vfLoadLane; Scalar: wntI32; Dim: 16; MaxAlign: 0),  { 84 load8_lane }
    (Family: vfLoadLane; Scalar: wntI32; Dim: 8; MaxAlign: 1),   { 85 load16_lane }
    (Family: vfLoadLane; Scalar: wntI32; Dim: 4; MaxAlign: 2),   { 86 load32_lane }
    (Family: vfLoadLane; Scalar: wntI32; Dim: 2; MaxAlign: 3),   { 87 load64_lane }
    (Family: vfStoreLane; Scalar: wntI32; Dim: 16; MaxAlign: 0), { 88 store8_lane }
    (Family: vfStoreLane; Scalar: wntI32; Dim: 8; MaxAlign: 1),  { 89 store16_lane }
    (Family: vfStoreLane; Scalar: wntI32; Dim: 4; MaxAlign: 2),  { 90 store32_lane }
    (Family: vfStoreLane; Scalar: wntI32; Dim: 2; MaxAlign: 3),  { 91 store64_lane }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 2),    { 92 load32_zero }
    (Family: vfLoad; Scalar: wntI32; Dim: 0; MaxAlign: 3),    { 93 load64_zero }
    { 94..95 float conversions — unary }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 94 demote_zero }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 95 promote_low }
    { 96..127 i8x16 unary/narrow, f32x4 rounding, i8x16 arith }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 96 i8x16.abs }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 97 i8x16.neg }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 98 popcnt }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 99 all_true }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 100 bitmask }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 101 narrow_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 102 narrow_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 103 f32x4.ceil }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 104 f32x4.floor }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 105 f32x4.trunc }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 106 f32x4.nearest }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 107 i8x16.shl }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 108 i8x16.shr_s }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 109 i8x16.shr_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 110 i8x16.add }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 111 add_sat_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 112 add_sat_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 113 i8x16.sub }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 114 sub_sat_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 115 sub_sat_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 116 f64x2.ceil }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 117 f64x2.floor }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 118 i8x16.min_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 119 i8x16.min_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 120 i8x16.max_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 121 i8x16.max_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 122 f64x2.trunc }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 123 avgr_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 124 extadd_pw }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 125 extadd_pw }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 126 extadd_pw }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 127 extadd_pw }
    { 128..159 i16x8 (154 unassigned) }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 128 i16x8.abs }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 129 i16x8.neg }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 130 q15mulr_sat_s }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 131 all_true }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 132 bitmask }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 133 narrow_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 134 narrow_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 135 extend_low_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 136 extend_high_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 137 extend_low_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 138 extend_high_u }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 139 i16x8.shl }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 140 i16x8.shr_s }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 141 i16x8.shr_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 142 i16x8.add }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 143 add_sat_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 144 add_sat_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 145 i16x8.sub }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 146 sub_sat_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 147 sub_sat_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 148 f64x2.nearest }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 149 i16x8.mul }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 150 i16x8.min_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 151 i16x8.min_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 152 i16x8.max_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 153 i16x8.max_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 154 unassigned }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 155 avgr_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 156 extmul_low_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 157 extmul_high_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 158 extmul_low_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 159 extmul_high_u }
    { 160..191 i32x4 (162,165,166,175,176,178..180,187 unassigned) }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 160 i32x4.abs }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 161 i32x4.neg }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 162 unassigned }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 163 all_true }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 164 bitmask }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 165 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 166 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 167 extend_low_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 168 extend_high_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 169 extend_low_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 170 extend_high_u }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 171 i32x4.shl }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 172 i32x4.shr_s }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 173 i32x4.shr_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 174 i32x4.add }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 175 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 176 unassigned }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 177 i32x4.sub }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 178 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 179 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 180 unassigned }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 181 i32x4.mul }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 182 i32x4.min_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 183 i32x4.min_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 184 i32x4.max_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 185 i32x4.max_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 186 dot_i16x8_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 187 unassigned }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 188 extmul_low_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 189 extmul_high_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 190 extmul_low_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 191 extmul_high_u }
    { 192..223 i64x2 (194,197,198,207,208,210..212 unassigned) }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 192 i64x2.abs }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 193 i64x2.neg }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 194 unassigned }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 195 all_true }
    (Family: vfTest; Scalar: wntI32; Dim: 0; MaxAlign: 0),    { 196 bitmask }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 197 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 198 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 199 extend_low_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 200 extend_high_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 201 extend_low_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 202 extend_high_u }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 203 i64x2.shl }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 204 i64x2.shr_s }
    (Family: vfShift; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 205 i64x2.shr_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 206 i64x2.add }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 207 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 208 unassigned }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 209 i64x2.sub }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 210 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 211 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 212 unassigned }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 213 i64x2.mul }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 214 i64x2.eq }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 215 i64x2.ne }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 216 i64x2.lt_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 217 i64x2.gt_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 218 i64x2.le_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 219 i64x2.ge_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 220 extmul_low_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 221 extmul_high_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 222 extmul_low_u }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 223 extmul_high_u }
    { 224..247 f32x4 / f64x2 arithmetic (226,238 unassigned) }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 224 f32x4.abs }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 225 f32x4.neg }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 226 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 227 f32x4.sqrt }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 228 f32x4.add }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 229 f32x4.sub }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 230 f32x4.mul }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 231 f32x4.div }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 232 f32x4.min }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 233 f32x4.max }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 234 f32x4.pmin }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 235 f32x4.pmax }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 236 f64x2.abs }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 237 f64x2.neg }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),                                                { 238 unassigned }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 239 f64x2.sqrt }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 240 f64x2.add }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 241 f64x2.sub }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 242 f64x2.mul }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 243 f64x2.div }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 244 f64x2.min }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 245 f64x2.max }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 246 f64x2.pmin }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 247 f64x2.pmax }
    { 248..255 conversions — unary }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 248 trunc_sat_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 249 trunc_sat_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 250 convert_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 251 convert_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 252 trunc_sat_zero_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 253 trunc_sat_zero_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 254 convert_low_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 255 convert_low_u }
    { 256..275 relaxed SIMD — type as the non-relaxed twin }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 256 rel_swizzle }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 257 rel_trunc_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 258 rel_trunc_u }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 259 rel_trunc_zero_s }
    (Family: vfUnary; Scalar: wntI32; Dim: 0; MaxAlign: 0),   { 260 rel_trunc_zero_u }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 261 rel_madd }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 262 rel_nmadd }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 263 rel_madd }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 264 rel_nmadd }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 265 rel_lanesel }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 266 rel_lanesel }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 267 rel_lanesel }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0), { 268 rel_lanesel }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 269 rel_min }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 270 rel_max }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 271 rel_min }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 272 rel_max }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 273 rel_q15mulr_s }
    (Family: vfBinary; Scalar: wntI32; Dim: 0; MaxAlign: 0),  { 274 rel_dot }
    (Family: vfTernary; Scalar: wntI32; Dim: 0; MaxAlign: 0)  { 275 rel_dot_add }
  );

{ Whether a $FD subopcode is assigned in the pinned 3.0 grammar. The 20
  gaps are the same list Wasm.Decoder.Expr and Prefixed spell; keeping the
  three in lock-step is why the list is written once per unit. }
function IsAssignedVecSub(const ASub: UInt32): Boolean;
begin
  case ASub of
    0..153, 155..161, 163, 164, 167..174, 177, 181..186, 188..193,
    195, 196, 199..206, 209, 213..225, 227..237, 239..275:
      Result := True;
  else
    Result := False;
  end;
end;

{ Subopcode -> IR op. TWasmIrOp's 256 vector members are dense and in
  subopcode order (SIMD design §2.1), so walking the assigned subopcodes
  in order pairs each with the next op. Built once (initialisation). }
var
  VecOpBySub: array[0..275] of TWasmIrOp;

procedure BuildVecOpTable;
var
  Sub: Integer;
  Op: TWasmIrOp;
begin
  Op := iroV128Load;
  for Sub := 0 to 275 do
    if IsAssignedVecSub(UInt32(Sub)) then
    begin
      VecOpBySub[Sub] := Op;
      if Op < iroI32x4RelaxedDotI8x16I7x16AddS then
        Inc(Op);
    end
    else
      VecOpBySub[Sub] := iroV128Load;   { sentinel; never read }
end;

{ --- the walker's state ---------------------------------------------------

  The spec's three stacks (`appendix/algorithm-stacks`) plus the locals'
  initialization flags, extended with register lowering. }

type
  { `wct` and not `wck`: Wasm.Core's TWasmCompKind already owns the
    `wck` prefix (wckFunc/wckStruct/wckArray) and this unit reads both
    enums in the same procedures, so sharing a prefix would let a typo
    resolve to the wrong enum instead of failing to compile
    (docs/code-style.md's one-prefix-per-enum rule). }
  TWasmCtrlKind = (wctBlock, wctLoop, wctIf, wctElse, wctTryTable,
    wctFuncBody);

  { Bot is the spec's bottom type. TWasmValueType deliberately cannot
    express it — it is the binary format's vocabulary and Bot occurs only
    during validation (`syntax-rectypeidx`) — so it rides here as a flag,
    and a Bot entry never carries a register. }
  TWasmValEntry = record
    ValType: TWasmValueType;
    IsBot: Boolean;
    Reg: UInt32;
  end;

  TWasmValEntries = array of TWasmValEntry;

  TWasmCtrlFrame = record
    Kind: TWasmCtrlKind;
    StartTypes: TWasmValTypeList;
    EndTypes: TWasmValTypeList;
    { Registers holding StartTypes at entry. Kept because the
      if-without-else path synthesises its missing arm out of them, and
      monotonic temporaries are what keep them live to that point. }
    ParamRegs: TWasmRegList;
    { The registers every edge into this frame's LABEL must write, one
      per label type. label_types(frame) is StartTypes for a loop and
      EndTypes for everything else, so MergeRegs lines up with it in all
      cases. wctFuncBody's MergeRegs IS the return register block, which
      is what makes `return` an ordinary branch. }
    MergeRegs: TWasmRegList;
    ValHeight: Integer;
    InitHeight: Integer;
    Unreachable: Boolean;
    { loop only: the resolved back-edge target. }
    LoopHeader: UInt32;
    { if only: the iroBranchIfNot whose taken edge is the else arm. }
    HasElseBranch: Boolean;
    ElseBranch: UInt32;
    { Instruction indices whose branch target is this frame's label, to
      be resolved when the frame's `end` is reached. }
    JumpPatches: TWasmRegList;
    PatchCount: Integer;
    { Handler-clause indices whose TargetInstr is this frame's label. A
      try_table's catch clause transfers to an ENCLOSING label, so its
      target is forward-resolved exactly like a branch — and, like
      JumpPatches, it must survive the if/else frame swap unresolved. }
    ClausePatches: TWasmRegList;
    ClausePatchCount: Integer;
    { try_table only: where the protected instruction range begins, and
      the clause range this frame contributed. The TWasmIrHandler record
      itself is appended at the frame's `end`, so an inner handler lands
      in the table BEFORE its enclosing one and a linear scan from 0
      finds the innermost (Wasm.Ir's TWasmIrHandlers comment). }
    HandlerStart: UInt32;
    ClauseStart: UInt32;
    ClauseCount: UInt32;
    HasHandler: Boolean;
  end;

  TWasmCtrlFrames = array of TWasmCtrlFrame;

  TBodyWalker = record
  private
    FModule: TWasmModule;
    FTypes: TWasmTypeContext;
    { The index spaces, imports first — the numbering every index
      immediate in a function body means (`context`). Built ONCE PER
      MODULE by the caller and read, never rebuilt, here. }
    FSpaces: TWasmIndexSpaces;

    FReader: TWasmReader;
    FBase: NativeUInt;
    FBodySize: NativeUInt;
    { Absolute code-section end, plus the physical byte just after this body.
      The fused walk needs both encoded boundaries to classify a missing END
      without widening the reader past its declared body span. }
    FCodeSectionEnd: NativeUInt;
    FHasByteAfterBody: Boolean;
    FByteAfterBody: Byte;

    FFn: TWasmIrFunction;
    FCodeCount: Integer;
    FRegCount: Integer;
    { Live length of FFn.AuxU32, which is grown geometrically by
      Wasm.Ir's IrAppendAuxBlockGrowing and trimmed once in Run.
      Length(FFn.AuxU32) is the CAPACITY until then and must not be read
      as a length. }
    FAuxCount: Integer;

    FVals: TWasmValEntries;
    FValCount: Integer;
    FInits: TWasmRegList;
    FInitCount: Integer;
    FCtrls: TWasmCtrlFrames;
    FCtrlCount: Integer;
    { Number of frames on the control stack marked unreachable. Emission
      is suppressed while ANY enclosing frame is dead, not merely the
      innermost one: a block opened inside dead code is `reachable` to
      the spec algorithm (push_ctrl clears the flag) but its operands can
      still be Bot entries inherited from the dead frame, and emitting
      against IR_NO_REG is the archetypal ADR-0012 bug. }
    FDeadCount: Integer;

    FLocalTypes: TWasmValTypeList;
    FLocalsInit: array of Boolean;
    { Wasm local index -> its LOW register (SIMD design §1.4). A v128 local
      takes two even-aligned slots, so `register i = local i` no longer
      holds and local.get/set/tee read this map instead of the raw index.
      Filled in the same loop that fills FLocalTypes. }
    FLocalReg: array of UInt32;
    FReturnTypes: TWasmValTypeList;

    procedure DecErr(const AMessage: string);
    procedure ValErr(const APrefix, AContext: string);

    function Emitting: Boolean;
    function Emit(const AOp: TWasmIrOp; const ADest, AA, AB: UInt32;
      const AImm: Int64): UInt32;
    function AllocTemp(const AType: TWasmValueType): UInt32;
    function AllocTemps(const ATypes: TWasmValTypeList): TWasmRegList;

    procedure PushEntry(const AEntry: TWasmValEntry);
    procedure PushVal(const AType: TWasmValueType; const AReg: UInt32);
    procedure PushVals(const ATypes: TWasmValTypeList;
      const ARegs: TWasmRegList);
    function PopVal: TWasmValEntry;
    function PopValExpect(const AType: TWasmValueType): TWasmValEntry;
    function PopVals(const ATypes: TWasmValTypeList): TWasmRegList;
    function PopRef: TWasmValEntry;

    function CtrlIndex(const ADepth: UInt32): Integer;
    function LabelTypes(const AIndex: Integer): TWasmValTypeList;
    procedure PushCtrl(const AKind: TWasmCtrlKind;
      const AIn, AOut: TWasmValTypeList;
      const AMergeRegs, AParamRegs: TWasmRegList);
    function PopCtrlCore: TWasmCtrlFrame;
    procedure ResolvePatches(const AFrame: TWasmCtrlFrame;
      const ATarget: UInt32);
    procedure AppendHandler(const AFrame: TWasmCtrlFrame;
      const AEndInstr: UInt32);
    procedure AddPatch(const AIndex: Integer; const AInstr: UInt32);
    procedure AddClausePatch(const AIndex: Integer; const AClause: UInt32);
    procedure MarkUnreachable;
    procedure ResetLocals(const AHeight: Integer);

    procedure EmitEdge(const AIndex: Integer; const ASrcRegs: TWasmRegList);
    procedure EmitConditionalEdge(const AIndex: Integer;
      const ACondReg: UInt32; const ASrcRegs: TWasmRegList);
    procedure EmitRefEdge(const AIndex: Integer;
      const AOp, AInverseOp: TWasmIrOp; const ASrcReg, ARefineReg: UInt32;
      const ASrcRegs: TWasmRegList; const AImm: Int64);

    procedure ReadBlockType(out AIn, AOut: TWasmValTypeList);
    function FuncTypeAt(const ATypeIndex: UInt32): TWasmFuncType;

    { --- index spaces and type forms --------------------------------- }
    function AddRefTypeAux(const A: TWasmRefType): UInt32;
    procedure CheckHeapType(const A: TWasmHeapType);
    procedure CheckRefType(const A: TWasmRefType);
    procedure CheckValType(const A: TWasmValueType);
    function CheckTable(const AIndex: UInt32;
      const AOffset: NativeUInt): TWasmTableType;
    function CheckMemory(const AIndex: UInt32;
      const AOffset: NativeUInt): TWasmMemType;
    function CheckGlobal(const AIndex: UInt32;
      const AOffset: NativeUInt): TWasmGlobalType;
    function CheckTag(const AIndex: UInt32;
      const AOffset: NativeUInt): TWasmFuncType;
    function CheckElem(const AIndex: UInt32;
      const AOffset: NativeUInt): TWasmRefType;
    procedure CheckData(const AIndex: UInt32; const AOffset: NativeUInt);
    function StructTypeAt(const ATypeIndex: UInt32): TWasmStructType;
    function ArrayTypeAt(const ATypeIndex: UInt32): TWasmFieldType;
    function StructFieldAt(const ATypeIndex, AFieldIndex: UInt32;
      const AOffset: NativeUInt): TWasmFieldType;
    procedure CheckFieldAccess(const AField: TWasmFieldType;
      const APacked: Boolean; const AWhat: string);
    procedure CheckFieldMutable(const AField: TWasmFieldType;
      const APrefix, AWhat: string);
    procedure ReadMemarg(const AOp: Byte; out AMemIdx: UInt32;
      out AOffset: UInt64; const AOpOffset: NativeUInt);
    procedure ReadMemargMax(const AMaxAlign: Byte; const AWhat: string;
      out AMemIdx: UInt32; out AOffset: UInt64; const AOpOffset: NativeUInt);

    procedure HandleNumeric(const AOp: Byte; const ASig: TNumSig;
      const AIrOp: TWasmIrOp);
    procedure HandleLocalGet;
    procedure HandleLocalSet(const ATee: Boolean);
    procedure HandleSelect(const ATyped: Boolean);
    procedure HandleBlock(const AKind: TWasmCtrlKind);
    procedure HandleElse(const ASynthetic: Boolean;
      const AOffset: NativeUInt);
    function HandleEnd: Boolean;
    procedure HandleBr;
    procedure HandleBrIf;
    procedure HandleBrTable;
    procedure HandleReturn;
    procedure HandleCall(const ATail: Boolean);
    procedure HandleCallIndirect(const ATail: Boolean);
    procedure HandleCallRef(const ATail: Boolean);
    procedure CheckTailResults(const AResults: TWasmValTypeList);

    { --- the remaining instruction families -------------------------- }
    procedure HandleGlobal(const ASet: Boolean;
      const AOffset: NativeUInt);
    procedure HandleTableGet(const AOffset: NativeUInt);
    procedure HandleTableSet(const AOffset: NativeUInt);
    procedure HandleLoadStore(const AOp: Byte; const AOffset: NativeUInt);
    procedure HandleMemorySizeGrow(const AGrow: Boolean;
      const AOffset: NativeUInt);
    procedure HandleRefNull;
    procedure HandleRefIsNull;
    procedure HandleRefFunc(const AOffset: NativeUInt);
    procedure HandleRefEq;
    procedure HandleRefAsNonNull;
    procedure HandleBrOnNull(const ANonNull: Boolean);
    procedure HandleThrow(const AOffset: NativeUInt);
    procedure HandleThrowRef;
    procedure HandleTryTable(const AOffset: NativeUInt);
    procedure HandleBulkMemory(const ASub: UInt32;
      const AOffset: NativeUInt);
    procedure HandleBulkTable(const ASub: UInt32;
      const AOffset: NativeUInt);
    procedure HandleStructOp(const ASub: UInt32;
      const AOffset: NativeUInt);
    procedure HandleArrayOp(const ASub: UInt32; const AOffset: NativeUInt);
    procedure HandleCast(const ASub: UInt32);
    procedure HandleBrOnCast(const AFail: Boolean;
      const AOffset: NativeUInt);
    procedure HandleI31Extern(const ASub: UInt32);
    procedure HandleVector(const ASub: UInt32; const AOffset: NativeUInt);

    procedure Prefixed(const APrefix: Byte; const AOffset: NativeUInt);
  public
    procedure Setup(const AModule: TWasmModule;
      const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
      const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
      const ASpaces: TWasmIndexSpaces);
    function Run: TWasmIrFunction;
  end;

{ --- errors --------------------------------------------------------------- }

procedure TBodyWalker.DecErr(const AMessage: string);
begin
  raise EWasmDecodeError.Create(AMessage);
end;

procedure TBodyWalker.ValErr(const APrefix, AContext: string);
begin
  if AContext = '' then
    raise EWasmValidationError.Create(APrefix);
  raise EWasmValidationError.Create(APrefix + ': ' + AContext);
end;

{ --- emission ------------------------------------------------------------- }

function TBodyWalker.Emitting: Boolean;
begin
  Result := FDeadCount = 0;
end;

function TBodyWalker.Emit(const AOp: TWasmIrOp; const ADest, AA,
  AB: UInt32; const AImm: Int64): UInt32;
begin
  Result := IrEmitInstr(FFn.Code, FCodeCount,
    MakeIrInstr(AOp, ADest, AA, AB, AImm));
end;

function TBodyWalker.AllocTemp(const AType: TWasmValueType): UInt32;
begin
  Result := IrAllocReg(FFn.RegTypes, FRegCount, AType);
end;

{ Destination registers for an instruction's results. Allocated only when
  the walk is emitting: in dead code nothing reads them, and not
  allocating keeps register numbering in live code independent of what
  dead code happens to contain. }
function TBodyWalker.AllocTemps(
  const ATypes: TWasmValTypeList): TWasmRegList;
var
  I: Integer;
begin
  SetLength(Result, Length(ATypes));
  for I := 0 to High(ATypes) do
    if Emitting then
      Result[I] := AllocTemp(ATypes[I])
    else
      Result[I] := IR_NO_REG;
end;

{ --- the value stack ------------------------------------------------------ }

procedure TBodyWalker.PushEntry(const AEntry: TWasmValEntry);
begin
  if FValCount >= Length(FVals) then
    SetLength(FVals, (FValCount * 2) + 16);
  FVals[FValCount] := AEntry;
  Inc(FValCount);
end;

procedure TBodyWalker.PushVal(const AType: TWasmValueType;
  const AReg: UInt32);
var
  E: TWasmValEntry;
begin
  E.ValType := AType;
  E.IsBot := False;
  E.Reg := AReg;
  PushEntry(E);
end;

procedure TBodyWalker.PushVals(const ATypes: TWasmValTypeList;
  const ARegs: TWasmRegList);
var
  I: Integer;
begin
  for I := 0 to High(ATypes) do
    if I <= High(ARegs) then
      PushVal(ATypes[I], ARegs[I])
    else
      PushVal(ATypes[I], IR_NO_REG);
end;

{ `appendix/algorithm-stacks`, pop_val: at the current frame's floor a
  polymorphic frame yields Bot rather than underflowing, and Bot carries
  no register. }
function TBodyWalker.PopVal: TWasmValEntry;
begin
  if FValCount = FCtrls[FCtrlCount - 1].ValHeight then
  begin
    if FCtrls[FCtrlCount - 1].Unreachable then
    begin
      Result.ValType := MakeBotValType;
      Result.IsBot := True;
      Result.Reg := IR_NO_REG;
      Exit;
    end;
    ValErr(MSG_TYPE_MISMATCH, 'operand stack underflows the current block');
  end;
  Dec(FValCount);
  Result := FVals[FValCount];
end;

function TBodyWalker.PopValExpect(
  const AType: TWasmValueType): TWasmValEntry;
begin
  Result := PopVal;
  if Result.IsBot then
    Exit;
  if not FTypes.MatchesValType(Result.ValType, AType) then
    ValErr(MSG_TYPE_MISMATCH,
      'expected ' + AType.Describe + ', found ' + Result.ValType.Describe);
end;

function TBodyWalker.PopVals(
  const ATypes: TWasmValTypeList): TWasmRegList;
var
  I: Integer;
begin
  SetLength(Result, Length(ATypes));
  for I := High(ATypes) downto 0 do
    Result[I] := PopValExpect(ATypes[I]).Reg;
end;

{ `appendix/algorithm-stacks`' pop_ref: any reference type is accepted and
  a polymorphic pop yields Ref(Bot, false). The Bot case keeps its
  IR_NO_REG and is spelled as a reference whose HEAP type is the bottom
  sentinel, so every later MatchesRefType against it succeeds — which is
  what makes `unreachable; ref.is_null` type-check. }
function TBodyWalker.PopRef: TWasmValEntry;
begin
  Result := PopVal;
  if Result.IsBot then
  begin
    Result.ValType := MakeRefValueType(MakeRefType(False, MakeBotHeapType));
    Exit;
  end;
  if Result.ValType.Kind <> wvkRef then
    ValErr(MSG_TYPE_MISMATCH,
      'expected a reference type, found ' + Result.ValType.Describe);
end;

{ --- the control stack ---------------------------------------------------- }

{ The spec indexes ctrls from the TOP (ctrls[0] is the innermost); FPC
  arrays index from the bottom. Every rule goes through here so the
  transposition is written once. }
function TBodyWalker.CtrlIndex(const ADepth: UInt32): Integer;
begin
  if ADepth >= UInt32(FCtrlCount) then
    ValErr(UnknownIndex(MSG_UNKNOWN_LABEL, ADepth),
      Format('out of range (%d label(s) in scope)',
        [FCtrlCount]));
  Result := FCtrlCount - 1 - Integer(ADepth);
end;

function TBodyWalker.LabelTypes(
  const AIndex: Integer): TWasmValTypeList;
begin
  if FCtrls[AIndex].Kind = wctLoop then
    Result := FCtrls[AIndex].StartTypes
  else
    Result := FCtrls[AIndex].EndTypes;
end;

procedure TBodyWalker.PushCtrl(const AKind: TWasmCtrlKind;
  const AIn, AOut: TWasmValTypeList;
  const AMergeRegs, AParamRegs: TWasmRegList);
var
  Frame: TWasmCtrlFrame;
begin
  Frame.Kind := AKind;
  Frame.StartTypes := AIn;
  Frame.EndTypes := AOut;
  Frame.ParamRegs := AParamRegs;
  Frame.MergeRegs := AMergeRegs;
  Frame.ValHeight := FValCount;
  Frame.InitHeight := FInitCount;
  Frame.Unreachable := False;
  Frame.LoopHeader := 0;
  Frame.HasElseBranch := False;
  Frame.ElseBranch := 0;
  Frame.JumpPatches := nil;
  Frame.PatchCount := 0;
  Frame.ClausePatches := nil;
  Frame.ClausePatchCount := 0;
  Frame.HandlerStart := 0;
  Frame.ClauseStart := 0;
  Frame.ClauseCount := 0;
  Frame.HasHandler := False;

  if FCtrlCount >= Length(FCtrls) then
    SetLength(FCtrls, (FCtrlCount * 2) + 8);
  FCtrls[FCtrlCount] := Frame;
  Inc(FCtrlCount);

  PushVals(AIn, AParamRegs);
end;

{ pop_ctrl, with the merge moves. The frame's own end merges run FIRST
  and the label's resolved target is the index AFTER them, which is what
  makes a branch to the label land where the fall-through does. }
function TBodyWalker.PopCtrlCore: TWasmCtrlFrame;
var
  Frame: TWasmCtrlFrame;
  Regs, ResultRegs: TWasmRegList;
  I: Integer;
begin
  Frame := FCtrls[FCtrlCount - 1];
  Regs := PopVals(Frame.EndTypes);
  if FValCount <> Frame.ValHeight then
    ValErr(MSG_TYPE_MISMATCH,
      Format('block leaves %d extra operand(s) on the stack',
        [FValCount - Frame.ValHeight]));

  if (Frame.Kind <> wctLoop) and Emitting then
    EmitParallelMove(FFn.Code, FCodeCount, FFn.RegTypes, FRegCount,
      Frame.MergeRegs, Regs);

  ResetLocals(Frame.InitHeight);
  if Frame.Unreachable then
    Dec(FDeadCount);
  Dec(FCtrlCount);

  { From here on Emitting reflects the ENCLOSING frame, which is what
    decides whether the values this block yields need real registers. }
  if Frame.Kind = wctLoop then
  begin
    { A loop's `end` is reached only by fall-through, so there is nothing
      to merge and the values keep the registers they already have. Dead
      code gave them none, so materialise fresh ones — the enclosing
      frame may well be live, and handing it IR_NO_REG is the ADR-0012
      bug this whole guard exists to prevent. }
    ResultRegs := Regs;
    for I := 0 to High(ResultRegs) do
      if (ResultRegs[I] = IR_NO_REG) and Emitting then
        ResultRegs[I] := AllocTemp(Frame.EndTypes[I]);
  end
  else
    ResultRegs := Frame.MergeRegs;

  Frame.MergeRegs := ResultRegs;
  Result := Frame;
end;

procedure TBodyWalker.ResolvePatches(const AFrame: TWasmCtrlFrame;
  const ATarget: UInt32);
var
  I: Integer;
  Idx: UInt32;
begin
  for I := 0 to AFrame.PatchCount - 1 do
  begin
    Idx := AFrame.JumpPatches[I];
    { The target field is derived from the op: iroJump carries it in A,
      every other branch op in B. }
    if FFn.Code[Idx].Op = iroJump then
      FFn.Code[Idx].A := ATarget
    else
      FFn.Code[Idx].B := ATarget;
  end;

  { Catch clauses resolve against the same label and at the same moment:
    a handler transfers into the target label exactly where a `br` to it
    would land, after the label's merge moves. }
  for I := 0 to AFrame.ClausePatchCount - 1 do
    FFn.HandlerClauses[AFrame.ClausePatches[I]].TargetInstr := ATarget;
end;

procedure TBodyWalker.AddPatch(const AIndex: Integer;
  const AInstr: UInt32);
begin
  if FCtrls[AIndex].PatchCount >= Length(FCtrls[AIndex].JumpPatches) then
    SetLength(FCtrls[AIndex].JumpPatches,
      (FCtrls[AIndex].PatchCount * 2) + 4);
  FCtrls[AIndex].JumpPatches[FCtrls[AIndex].PatchCount] := AInstr;
  Inc(FCtrls[AIndex].PatchCount);
end;

procedure TBodyWalker.AddClausePatch(const AIndex: Integer;
  const AClause: UInt32);
begin
  if FCtrls[AIndex].ClausePatchCount
    >= Length(FCtrls[AIndex].ClausePatches) then
    SetLength(FCtrls[AIndex].ClausePatches,
      (FCtrls[AIndex].ClausePatchCount * 2) + 4);
  FCtrls[AIndex].ClausePatches[FCtrls[AIndex].ClausePatchCount] := AClause;
  Inc(FCtrls[AIndex].ClausePatchCount);
end;

procedure TBodyWalker.MarkUnreachable;
begin
  FValCount := FCtrls[FCtrlCount - 1].ValHeight;
  if not FCtrls[FCtrlCount - 1].Unreachable then
  begin
    FCtrls[FCtrlCount - 1].Unreachable := True;
    Inc(FDeadCount);
  end;
end;

procedure TBodyWalker.ResetLocals(const AHeight: Integer);
begin
  while FInitCount > AHeight do
  begin
    Dec(FInitCount);
    FLocalsInit[FInits[FInitCount]] := False;
  end;
end;

{ --- branch edges --------------------------------------------------------- }

{ The unconditional edge into a label: the parallel move into the label's
  merge registers, then the transfer. The outermost label is the function
  body's, and reaching it IS returning, which is why `return` needs no
  special case beyond calling this with frame 0. }
procedure TBodyWalker.EmitEdge(const AIndex: Integer;
  const ASrcRegs: TWasmRegList);
var
  Idx: UInt32;
begin
  if not Emitting then
    Exit;

  EmitParallelMove(FFn.Code, FCodeCount, FFn.RegTypes, FRegCount,
    FCtrls[AIndex].MergeRegs, ASrcRegs);

  case FCtrls[AIndex].Kind of
    wctFuncBody:
      Emit(iroReturn, IR_NO_REG, IR_NO_REG, IR_NO_REG, 0);
    wctLoop:
      { Every back-edge is an iroJump carrying the safepoint flag: the
        epoch check (ADR-0006) and the stack map (ADR-0011) are emitted
        at exactly these instructions, and keeping the check fused to the
        branch is what makes it cheap. }
      Emit(iroJump, IR_NO_REG, FCtrls[AIndex].LoopHeader, IR_NO_REG,
        IR_JUMP_SAFEPOINT);
  else
    Idx := Emit(iroJump, IR_NO_REG, 0, IR_NO_REG, 0);
    AddPatch(AIndex, Idx);
  end;
end;

{ A conditional branch is emitted DIRECTLY when it needs no merge moves
  and its target is a forward label; otherwise the taken edge is laid out
  inline behind an inverted test, so the not-taken (common) path costs no
  jump and the safepoint still lands on a real iroJump. }
procedure TBodyWalker.EmitConditionalEdge(const AIndex: Integer;
  const ACondReg: UInt32; const ASrcRegs: TWasmRegList);
var
  Idx, NotIdx: UInt32;
  Direct: Boolean;
begin
  if not Emitting then
    Exit;

  Direct := (Length(FCtrls[AIndex].MergeRegs) = 0)
    and (FCtrls[AIndex].Kind <> wctLoop)
    and (FCtrls[AIndex].Kind <> wctFuncBody);

  if Direct then
  begin
    Idx := Emit(iroBranchIf, IR_NO_REG, ACondReg, 0, 0);
    AddPatch(AIndex, Idx);
    Exit;
  end;

  NotIdx := Emit(iroBranchIfNot, IR_NO_REG, ACondReg, 0, 0);
  EmitEdge(AIndex, ASrcRegs);
  FFn.Code[NotIdx].B := UInt32(FCodeCount);
end;

{ The same two shapes for the four conditional branches that test a
  REFERENCE rather than an i32: br_on_null, br_on_non_null, br_on_cast,
  br_on_cast_fail. AOp is the op whose TAKEN edge is the wasm
  instruction's; AInverseOp is the op that branches on the complementary
  condition, used for the inline-edge shape.

  The direct shape carries the fall-through refinement in the op's Dest,
  which is what IR_OP_INFO says that field means. The inline shape cannot:
  its conditional test is the INVERSE op, whose fall-through is the wasm
  instruction's TAKEN path, so the refinement is written by an explicit
  iroMove placed after the edge. That move is not overhead the direct
  shape avoids — the refinement register has to be written either way; it
  is just free when the branch itself can do it.

  In practice only br_on_null ever takes the direct shape: the other three
  deliver a value to the label, so their label types are never empty. }
procedure TBodyWalker.EmitRefEdge(const AIndex: Integer;
  const AOp, AInverseOp: TWasmIrOp; const ASrcReg, ARefineReg: UInt32;
  const ASrcRegs: TWasmRegList; const AImm: Int64);
var
  Idx, NotIdx: UInt32;
  Direct: Boolean;
begin
  if not Emitting then
    Exit;

  Direct := (Length(FCtrls[AIndex].MergeRegs) = 0)
    and (FCtrls[AIndex].Kind <> wctLoop)
    and (FCtrls[AIndex].Kind <> wctFuncBody);

  if Direct then
  begin
    Idx := Emit(AOp, ARefineReg, ASrcReg, 0, AImm);
    AddPatch(AIndex, Idx);
    Exit;
  end;

  NotIdx := Emit(AInverseOp, IR_NO_REG, ASrcReg, 0, AImm);
  EmitEdge(AIndex, ASrcRegs);
  FFn.Code[NotIdx].B := UInt32(FCodeCount);
  if ARefineReg <> IR_NO_REG then
    Emit(iroMove, ARefineReg, ASrcReg, IR_NO_REG, 0);
end;

{ --- immediates ----------------------------------------------------------- }

{ Block type: the byte $40 (empty), a single value type, or a
  non-negative s33 type index (`valid-blocktype`, `binary-blocktype`).
  The reading mirrors Wasm.Decoder.Expr.SkipBlockType byte for byte —
  including that the empty and value-type arms are literal single-byte
  productions, so a padded sLEB spelling of their codes matches nothing. }
procedure TBodyWalker.ReadBlockType(out AIn, AOut: TWasmValTypeList);
const
  BLOCKTYPE_EMPTY = -64;
var
  Marker: Byte;
  Start: NativeUInt;
  Code: Int64;
  Value: TWasmValueType;
  Comp: TWasmCompType;
begin
  AIn := nil;
  AOut := nil;

  Marker := FReader.PeekByte;
  if (Marker = BYTE_REF_NULL) or (Marker = BYTE_REF) then
  begin
    SetLength(AOut, 1);
    AOut[0] := MakeRefValueType(ReadRefType(FReader));
    { The long form is the arm that can name a CONCRETE type, and
      `valid-blocktype` reduces to `valid-valtype` for a value-type block
      type — so `(block (result (ref null 5)))` in a one-type module is
      invalid, not accepted. Nothing before this point bounded the index. }
    CheckValType(AOut[0]);
    Exit;
  end;

  Start := FReader.Position;
  Code := FReader.ReadS33;
  if Code >= 0 then
  begin
    if Code > High(UInt32) then
      ValErr(UnknownIndex(MSG_UNKNOWN_TYPE, Code),
        'block type index is out of range');
    Comp := FTypes.Expand(UInt32(Code));
    if Comp.Kind <> wckFunc then
      ValErr(MSG_TYPE_MISMATCH,
        Format('block type %d does not expand to a function type',
          [Code]));
    AIn := CopyValTypes(Comp.Func.Params);
    AOut := CopyValTypes(Comp.Func.Results);
    Exit;
  end;

  if (FReader.Position - Start = 1) and (Code = BLOCKTYPE_EMPTY) then
    Exit;

  if (FReader.Position - Start = 1) and TryDecodeValueType(Code, Value) then
  begin
    SetLength(AOut, 1);
    AOut[0] := Value;
    { Single-byte productions only, so this arm cannot currently yield a
      concrete heap type — the check is here because `valid-blocktype`
      states the rule on the value type, not on the encoding, and the two
      value-type arms must not drift apart. }
    CheckValType(AOut[0]);
    Exit;
  end;

  DecErr(Format('malformed block type (code %d) at offset %u',
    [Code, FBase + Start]));
end;

function TBodyWalker.FuncTypeAt(
  const ATypeIndex: UInt32): TWasmFuncType;
var
  Comp: TWasmCompType;
begin
  Comp := FTypes.Expand(ATypeIndex);
  if Comp.Kind <> wckFunc then
    ValErr(MSG_TYPE_MISMATCH,
      Format('type %u does not expand to a function type', [ATypeIndex]));
  Result := Comp.Func;
end;

{ --- index spaces and type forms ----------------------------------------- }

{ AuxRefTypes holds ONLY rt2 — the type being tested against — for
  ref.test, ref.cast, br_on_cast and br_on_cast_fail. rt1 is a
  validation-time constraint on the operand and has no runtime meaning;
  the refined RESULT type is recorded in RegTypes for the destination. }
function TBodyWalker.AddRefTypeAux(const A: TWasmRefType): UInt32;
begin
  Result := UInt32(Length(FFn.AuxRefTypes));
  SetLength(FFn.AuxRefTypes, Result + 1);
  FFn.AuxRefTypes[Result] := A;
end;

{ `valid-heaptype`: an abstract heap type is always well formed, and a
  concrete one must name a defined type. CanonIdOf is the project's single
  chokepoint for that bound and raises `unknown type`. }
procedure TBodyWalker.CheckHeapType(const A: TWasmHeapType);
begin
  if not A.IsAbstract then
    FTypes.CanonIdOf(A.TypeIndex);
end;

procedure TBodyWalker.CheckRefType(const A: TWasmRefType);
begin
  CheckHeapType(A.Heap);
end;

{ `valid-valtype`: number and vector types are universally valid, so only
  the reference case has anything to check.

  This is not decoration. A value type read from a function body carries
  a CONCRETE heap type whenever it uses the $63/$64 long form, and
  nothing before this point had a type space to bound it against —
  Wasm.Decoder.Common reads the index and stops there. Every site that
  takes a value type from the bytes (block types, `select`'s type
  immediate, the locals vector) must come through here or it wrongly
  ACCEPTS a reference to a type that does not exist. }
procedure TBodyWalker.CheckValType(const A: TWasmValueType);
begin
  if A.Kind = wvkRef then
    CheckRefType(A.Ref);
end;

function TBodyWalker.CheckTable(const AIndex: UInt32;
  const AOffset: NativeUInt): TWasmTableType;
begin
  if AIndex >= UInt32(Length(FSpaces.Tables)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_TABLE, AIndex),
      Format('out of range (%d table(s)) at offset %u',
        [Length(FSpaces.Tables), AOffset]));
  Result := FSpaces.Tables[AIndex];
end;

function TBodyWalker.CheckMemory(const AIndex: UInt32;
  const AOffset: NativeUInt): TWasmMemType;
begin
  if AIndex >= UInt32(Length(FSpaces.Memories)) then
    ValErr(UnknownMemoryPrefix(AIndex),
      Format('out of range (%d memory/memories) at offset %u',
        [Length(FSpaces.Memories), AOffset]));
  Result := FSpaces.Memories[AIndex];
end;

{ `context`: unlike a constant expression — where `valid-constant`
  restricts GLOBAL.GET to imported or previously defined globals — a
  function body sees the WHOLE global index space. There is no sequential
  bound to apply here, and adding one would reject valid modules. }
function TBodyWalker.CheckGlobal(const AIndex: UInt32;
  const AOffset: NativeUInt): TWasmGlobalType;
begin
  if AIndex >= UInt32(Length(FSpaces.Globals)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_GLOBAL, AIndex),
      Format('out of range (%d global(s)) at offset %u',
        [Length(FSpaces.Globals), AOffset]));
  Result := FSpaces.Globals[AIndex];
end;

{ The tag's function type. `syntax-tagtype`: a tag type is "a type use
  referring to the definition of a function type … The result type is
  empty for exception tags", so the empty-results side condition is
  checked here as well as at `valid-tag`. Module-level validation owns
  the tag SECTION; this walk can be driven on its own, and a tag with
  results would otherwise reach `throw` and push a result nothing pops. }
function TBodyWalker.CheckTag(const AIndex: UInt32;
  const AOffset: NativeUInt): TWasmFuncType;
begin
  if AIndex >= UInt32(Length(FSpaces.Tags)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_TAG, AIndex),
      Format('out of range (%d tag(s)) at offset %u',
        [Length(FSpaces.Tags), AOffset]));
  Result := FuncTypeAt(FSpaces.Tags[AIndex]);
  if Length(Result.Results) <> 0 then
    ValErr(MSG_TYPE_MISMATCH,
      Format('tag %u has %d result(s); an exception tag has none, at '
        + 'offset %u', [AIndex, Length(Result.Results), AOffset]));
end;

function TBodyWalker.CheckElem(const AIndex: UInt32;
  const AOffset: NativeUInt): TWasmRefType;
begin
  if AIndex >= UInt32(Length(FSpaces.ElemTypes)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_ELEM_SEGMENT, AIndex),
      Format('out of range (%d segment(s)) at offset %u',
        [Length(FSpaces.ElemTypes), AOffset]));
  Result := FSpaces.ElemTypes[AIndex];
end;

{ Two rules in one place, and they are of DIFFERENT CLASSES.

  The data count section being present at all is `binary-datacntsec`'s
  side condition — binary grammar, hence EWasmDecodeError with
  MSG_DATA_COUNT_REQUIRED. Only once it is present is there a bound to
  check, and exceeding that bound is a typing failure. Getting the order
  the other way round would report `unknown data segment` for a module
  the grammar already rejects. }
procedure TBodyWalker.CheckData(const AIndex: UInt32;
  const AOffset: NativeUInt);
begin
  if not FSpaces.HasDataCount then
    DecErr(Format('%s: a data segment index is used at offset %u but the '
      + 'module has no data count section',
      [MSG_DATA_COUNT_REQUIRED, AOffset]));
  if AIndex >= FSpaces.DataCount then
    ValErr(UnknownIndex(MSG_UNKNOWN_DATA_SEGMENT, AIndex),
      Format('out of range (%u segment(s)) at offset %u',
        [FSpaces.DataCount, AOffset]));
end;

{ `appendix/algorithm-validation-of-opcode-sequences`: every struct
  instruction begins `let t = expand_def(types[x]); error_if(not
  is_struct(t))`. Expand raises `unknown type` for an index out of range,
  so only the kind is left to report. }
function TBodyWalker.StructTypeAt(
  const ATypeIndex: UInt32): TWasmStructType;
var
  Comp: TWasmCompType;
begin
  Comp := FTypes.Expand(ATypeIndex);
  if Comp.Kind <> wckStruct then
    ValErr(MSG_TYPE_MISMATCH,
      Format('type %u does not expand to a struct type', [ATypeIndex]));
  Result := Comp.Struct;
end;

function TBodyWalker.ArrayTypeAt(
  const ATypeIndex: UInt32): TWasmFieldType;
var
  Comp: TWasmCompType;
begin
  Comp := FTypes.Expand(ATypeIndex);
  if Comp.Kind <> wckArray then
    ValErr(MSG_TYPE_MISMATCH,
      Format('type %u does not expand to an array type', [ATypeIndex]));
  Result := Comp.Arr.Elem;
end;

function TBodyWalker.StructFieldAt(const ATypeIndex,
  AFieldIndex: UInt32; const AOffset: NativeUInt): TWasmFieldType;
var
  St: TWasmStructType;
begin
  St := StructTypeAt(ATypeIndex);
  { The appendix folds the field bound into the same error_if as the kind
    check (struct.set: `error_if(not is_struct(t) || n >= t.fields.len())`),
    so it is the same failure. }
  if AFieldIndex >= UInt32(Length(St.Fields)) then
    ValErr(MSG_TYPE_MISMATCH,
      Format('field %u is out of range for type %u (%d field(s)) at '
        + 'offset %u',
        [AFieldIndex, ATypeIndex, Length(St.Fields), AOffset]));
  Result := St.Fields[AFieldIndex];
end;

{ The packed/unpacked pairing, in both directions. `struct.get` and
  `array.get` read a field's storage type directly and so may not be used
  on PACKED storage — there is no i8 on the operand stack — while the
  `_s`/`_u` forms exist only to widen packed storage and are meaningless
  on a value field. }
procedure TBodyWalker.CheckFieldAccess(const AField: TWasmFieldType;
  const APacked: Boolean; const AWhat: string);
begin
  if APacked and (not AField.Storage.IsPacked) then
    ValErr(MSG_TYPE_MISMATCH,
      AWhat + ' reads a sign extension from the unpacked field type '
      + AField.Storage.Describe);
  if (not APacked) and AField.Storage.IsPacked then
    ValErr(MSG_TYPE_MISMATCH,
      AWhat + ' reads the packed field type ' + AField.Storage.Describe
      + ' without a sign extension');
end;

{ The prefix names the aggregate whose member is immutable — `immutable
  field` for a struct, `immutable array` for every array write — because
  that is what upstream's scripts prefix-match (struct.wast, array*.wast).
  Confirmed by corpus run 2026-08-09; the instruction that tripped it is
  appended as context. }
procedure TBodyWalker.CheckFieldMutable(const AField: TWasmFieldType;
  const APrefix, AWhat: string);
begin
  if not AField.Mut then
    ValErr(APrefix, AWhat + ' writes an immutable member');
end;

{ memarg. The ENCODING is Track A's, reproduced byte for byte from
  `binary-memarg`: a u32 flags field, malformed at $80 and above, whose
  bit 6 signals a trailing memidx, then a u64 offset (memory64 is in the
  pinned draft, so the offset does not fit a u32).

  The ALIGNMENT is validation's (`valid-memarg`: memory arguments are
  "classified by the address type and the bit width of the access they
  are suitable for"), and the side condition is 2^align <= N/8. Because
  the flags cap at $7F and bit 6 is taken, the align field that reaches
  here is 0..63 — there is no alignment OVERFLOW case left to handle on
  this side, and nothing needs shifting: MEM_SIG stores log2(N/8) and the
  check is a comparison. }
procedure TBodyWalker.ReadMemargMax(const AMaxAlign: Byte;
  const AWhat: string; out AMemIdx: UInt32; out AOffset: UInt64;
  const AOpOffset: NativeUInt);
const
  MEMARG_FLAG_MEMIDX = $40;
var
  Start: NativeUInt;
  Flags, Align: UInt32;
begin
  Start := FReader.Position;
  Flags := FReader.ReadU32;
  if Flags >= $80 then
    DecErr(Format('%s: %u at offset %u',
      [MSG_MALFORMED_MEMOP_FLAGS, Flags, FBase + Start]));

  AMemIdx := 0;
  if (Flags and MEMARG_FLAG_MEMIDX) <> 0 then
    AMemIdx := FReader.ReadU32;
  AOffset := FReader.ReadU64;

  Align := Flags and (MEMARG_FLAG_MEMIDX - 1);
  if Align > AMaxAlign then
    ValErr(MSG_ALIGNMENT_TOO_LARGE,
      Format('alignment 2^%u exceeds the natural 2^%u of %s at offset %u',
        [Align, AMaxAlign, AWhat, AOpOffset]));
end;

procedure TBodyWalker.ReadMemarg(const AOp: Byte; out AMemIdx: UInt32;
  out AOffset: UInt64; const AOpOffset: NativeUInt);
begin
  { The natural alignment for a scalar memory op is MEM_SIG's; the vector
    load/store family passes its own maximum through ReadMemargMax. The
    message names the opcode in the same $xx form as before. }
  ReadMemargMax(MEM_SIG[AOp].MaxAlign, Format('opcode $%.2x', [AOp]),
    AMemIdx, AOffset, AOpOffset);
end;

{ --- instruction families ------------------------------------------------- }

{ `valid-unop` / `valid-binop` / `valid-testop` / `valid-relop` /
  `valid-cvtop`: pop the operands, allocate the destination, push it.
  Binary operands land in A (deeper on the stack) and B (shallower). }
procedure TBodyWalker.HandleNumeric(const AOp: Byte; const ASig: TNumSig;
  const AIrOp: TWasmIrOp);
var
  Operand, ResultType: TWasmValueType;
  RegA, RegB, Dest: UInt32;
begin
  Operand := MakeNumValueType(ASig.Operand);
  ResultType := MakeNumValueType(ASig.ResultType);

  RegB := IR_NO_REG;
  if ASig.Arity = 2 then
    RegB := PopValExpect(Operand).Reg;
  RegA := PopValExpect(Operand).Reg;

  if Emitting then
  begin
    Dest := AllocTemp(ResultType);
    Emit(AIrOp, Dest, RegA, RegB, 0);
  end
  else
    Dest := IR_NO_REG;
  PushVal(ResultType, Dest);
end;

{ local.get x emits a MOVE into a fresh temporary. Always, and it does
  not alias the local's register: in `local.get 0 ... local.set 0 ...`
  the value pushed by the get must be the OLD contents, and an alias
  would observe the new one. The fold back to a direct use is a pure
  peephole for a later track and needs no IR change. }
procedure TBodyWalker.HandleLocalGet;
var
  Start: NativeUInt;
  Idx: UInt32;
  Dest: UInt32;
begin
  Start := FReader.Position;
  Idx := FReader.ReadU32;
  if Idx >= UInt32(Length(FLocalTypes)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_LOCAL, Idx),
      Format('out of range (%d local(s)) at offset %u',
        [Length(FLocalTypes), FBase + Start]));

  { get_local (`appendix/algorithm-stacks`): a local whose type is not
    defaultable starts uninitialized and may not be read until set. }
  if not FLocalsInit[Idx] then
    ValErr(MSG_UNINITIALIZED_LOCAL,
      Format('local %u is read before it is set at offset %u',
        [Idx, FBase + Start]));

  if Emitting then
  begin
    Dest := AllocTemp(FLocalTypes[Idx]);
    { The value's register is FLocalReg[Idx], not Idx: a v128 local owns
      a slot pair and the low slot is what a get reads (SIMD design §1.4),
      and a v128 move is 16 bytes wide (iroMoveVec). }
    Emit(MoveOpFor(FFn.RegTypes, FLocalReg[Idx]), Dest, FLocalReg[Idx],
      IR_NO_REG, 0);
  end
  else
    Dest := IR_NO_REG;
  PushVal(FLocalTypes[Idx], Dest);
end;

{ local.set / local.tee. tee pushes the SAME register back: it is a
  temporary (or a merge register), and neither is written again on this
  path before its next use, so a second move would be dead. }
procedure TBodyWalker.HandleLocalSet(const ATee: Boolean);
var
  Start: NativeUInt;
  Idx: UInt32;
  E: TWasmValEntry;
begin
  Start := FReader.Position;
  Idx := FReader.ReadU32;
  if Idx >= UInt32(Length(FLocalTypes)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_LOCAL, Idx),
      Format('out of range (%d local(s)) at offset %u',
        [Length(FLocalTypes), FBase + Start]));

  E := PopValExpect(FLocalTypes[Idx]);
  if Emitting then
    Emit(MoveOpFor(FFn.RegTypes, FLocalReg[Idx]), FLocalReg[Idx], E.Reg,
      IR_NO_REG, 0);

  { set_local: record the change so the enclosing block's `end` can undo
    it. This is what makes `(block (local.set $r ...)) (local.get $r)`
    invalid. }
  if not FLocalsInit[Idx] then
  begin
    if FInitCount >= Length(FInits) then
      SetLength(FInits, (FInitCount * 2) + 8);
    FInits[FInitCount] := Idx;
    Inc(FInitCount);
    FLocalsInit[Idx] := True;
  end;

  if ATee then
    PushVal(FLocalTypes[Idx], E.Reg);
end;

{ select (`valid-select`, and the two cases in
  `appendix/algorithm-validation-of-opcode-sequences`). The UNTYPED form
  rejects reference operands — it is num-or-vec only — while the typed
  form accepts any single value type. The condition rides in Imm, the
  only op where a register lives there; A is the value chosen when the
  condition is non-zero, which is the DEEPER stack operand. }
procedure TBodyWalker.HandleSelect(const ATyped: Boolean);
var
  Start: NativeUInt;
  Count: UInt32;
  Cond, V1, V2: TWasmValEntry;
  Chosen: TWasmValueType;
  IsBot: Boolean;
  Dest: UInt32;
  Ty: TWasmValueType;

  function NumOrBot(const E: TWasmValEntry): Boolean;
  begin
    Result := E.IsBot or (E.ValType.Kind = wvkNum);
  end;

  function VecOrBot(const E: TWasmValEntry): Boolean;
  begin
    Result := E.IsBot or (E.ValType.Kind = wvkVec);
  end;

begin
  if ATyped then
  begin
    Start := FReader.Position;
    Count := FReader.ReadU32;
    { The binary grammar admits any count; `valid-select` requires
      exactly one ("In future versions of WebAssembly, SELECT may allow
      more than one value per choice"), so this is a typing error, not a
      malformation. UNCONFIRMED: upstream may reject it in its decoder. }
    if Count <> 1 then
      ValErr(MSG_INVALID_RESULT_ARITY,
        Format('select expects exactly one result type, found %u at '
          + 'offset %u', [Count, FBase + Start]));
    Ty := ReadValueType(FReader);
    { `valid-select`'s typed form requires the immediate to BE a valid
      value type, and the $63/$64 long form can name a concrete type the
      module does not define. }
    CheckValType(Ty);

    Cond := PopValExpect(MakeI32);
    V2 := PopValExpect(Ty);
    V1 := PopValExpect(Ty);
    Chosen := Ty;
    IsBot := False;
  end
  else
  begin
    Cond := PopValExpect(MakeI32);
    V2 := PopVal;
    V1 := PopVal;
    if not ((NumOrBot(V2) and NumOrBot(V1))
      or (VecOrBot(V2) and VecOrBot(V1))) then
      ValErr(MSG_TYPE_MISMATCH,
        'select without a type immediate takes numeric or vector '
        + 'operands only');
    if (not V2.IsBot) and (not V1.IsBot)
      and (not FTypes.MatchesValType(V2.ValType, V1.ValType)) then
      ValErr(MSG_TYPE_MISMATCH,
        'select operands differ: ' + V1.ValType.Describe + ' and '
        + V2.ValType.Describe);
    if V2.IsBot then
    begin
      Chosen := V1.ValType;
      IsBot := V1.IsBot;
    end
    else
    begin
      Chosen := V2.ValType;
      IsBot := False;
    end;
  end;

  if IsBot then
  begin
    PushEntry(V1);
    Exit;
  end;

  if Emitting then
  begin
    Dest := AllocTemp(Chosen);
    { A v128 select copies 16 bytes; the condition register rides in Imm
      (ifkSrcRegImm) for the *Vec arm (SIMD design §2.4). }
    if Chosen.Kind = wvkVec then
      Emit(iroSelectVec, Dest, V1.Reg, V2.Reg, Int64(Cond.Reg))
    else
      Emit(iroSelect, Dest, V1.Reg, V2.Reg, Int64(Cond.Reg));
  end
  else
    Dest := IR_NO_REG;
  PushVal(Chosen, Dest);
end;

{ block / loop / if. block, loop and if emit nothing themselves except
  `if`'s inverted test; what they do is push a control frame and allocate
  the registers a branch to its label must write.

  Merge registers are allocated at ENTRY, one per label type, even in
  dead code: they are the one register class whose numbers a later branch
  depends on, and an unallocated merge register is the same IR_NO_REG bug
  in a different coat. }
procedure TBodyWalker.HandleBlock(const AKind: TWasmCtrlKind);
var
  InTypes, OutTypes: TWasmValTypeList;
  ParamRegs, MergeRegs: TWasmRegList;
  Cond: TWasmValEntry;
  I: Integer;
  Idx: UInt32;
begin
  ReadBlockType(InTypes, OutTypes);

  Cond.IsBot := False;
  Cond.Reg := IR_NO_REG;
  if AKind = wctIf then
    Cond := PopValExpect(MakeI32);
  ParamRegs := PopVals(InTypes);

  if AKind = wctLoop then
  begin
    { label_types(loop) is the START types, so the loop's merge registers
      are its PARAMETERS and the entry costs one move each — back-edges
      write exactly these. A loop allocates no result merge registers:
      its `end` is reached only by fall-through. }
    SetLength(MergeRegs, Length(InTypes));
    for I := 0 to High(InTypes) do
      MergeRegs[I] := AllocTemp(InTypes[I]);
    if Emitting then
      EmitParallelMove(FFn.Code, FCodeCount, FFn.RegTypes, FRegCount,
        MergeRegs, ParamRegs);
    PushCtrl(wctLoop, InTypes, OutTypes, MergeRegs, MergeRegs);
    FCtrls[FCtrlCount - 1].LoopHeader := UInt32(FCodeCount);
    Exit;
  end;

  SetLength(MergeRegs, Length(OutTypes));
  for I := 0 to High(OutTypes) do
    MergeRegs[I] := AllocTemp(OutTypes[I]);

  if AKind = wctIf then
  begin
    Idx := 0;
    if Emitting then
      Idx := Emit(iroBranchIfNot, IR_NO_REG, Cond.Reg, 0, 0);
    PushCtrl(wctIf, InTypes, OutTypes, MergeRegs, ParamRegs);
    FCtrls[FCtrlCount - 1].HasElseBranch := Emitting;
    FCtrls[FCtrlCount - 1].ElseBranch := Idx;
    Exit;
  end;

  PushCtrl(wctBlock, InTypes, OutTypes, MergeRegs, ParamRegs);
end;

{ else, real or synthesised. THE CLASSIC BUG IS HERE: the else frame
  inherits the if frame's JumpPatches UNRESOLVED, because a branch out of
  the then-arm targets the same `end`. Resolving them at `else` passes
  most tests and fails `block (if ... br 1 ... else ... end) end`. }
procedure TBodyWalker.HandleElse(const ASynthetic: Boolean;
  const AOffset: NativeUInt);
var
  Frame: TWasmCtrlFrame;
  Idx: UInt32;
  Emitted: Boolean;
begin
  if (not ASynthetic) and (FCtrls[FCtrlCount - 1].Kind <> wctIf) then
    { `binary-if` admits $05 in exactly one place and at most once, so an
      else anywhere else matches no production. Track A raises the same
      message from the expression skipper. }
    DecErr(Format('misplaced else opcode at offset %u', [AOffset]));

  Emitted := Emitting;
  Frame := PopCtrlCore;

  Idx := 0;
  if Emitted and (not Frame.Unreachable) then
    Idx := Emit(iroJump, IR_NO_REG, 0, IR_NO_REG, 0);

  if Frame.HasElseBranch then
    FFn.Code[Frame.ElseBranch].B := UInt32(FCodeCount);

  { ParamRegs are re-pushed, which is exactly what the synthesised arm of
    an `if` without `else` needs: its result is its input, and monotonic
    temporaries are why those registers are still live here. }
  PushCtrl(wctElse, Frame.StartTypes, Frame.EndTypes,
    { MergeRegs of the popped frame were rewritten to the pushed result
      registers by PopCtrlCore; for a non-loop frame those ARE the merge
      registers, so both arms land in the same place. }
    Frame.MergeRegs, Frame.ParamRegs);

  FCtrls[FCtrlCount - 1].JumpPatches := Frame.JumpPatches;
  FCtrls[FCtrlCount - 1].PatchCount := Frame.PatchCount;
  { Catch clauses whose target is this label inherit the same way, and for
    the same reason: a try_table inside the then-arm names the `end` the
    else-arm shares. }
  FCtrls[FCtrlCount - 1].ClausePatches := Frame.ClausePatches;
  FCtrls[FCtrlCount - 1].ClausePatchCount := Frame.ClausePatchCount;
  if Emitted and (not Frame.Unreachable) then
    AddPatch(FCtrlCount - 1, Idx);
end;

procedure TBodyWalker.AppendHandler(const AFrame: TWasmCtrlFrame;
  const AEndInstr: UInt32);
var
  N: Integer;
begin
  if not AFrame.HasHandler then
    Exit;
  N := Length(FFn.Handlers);
  SetLength(FFn.Handlers, N + 1);
  FFn.Handlers[N].StartInstr := AFrame.HandlerStart;
  FFn.Handlers[N].EndInstr := AEndInstr;
  FFn.Handlers[N].ClauseStart := AFrame.ClauseStart;
  FFn.Handlers[N].ClauseCount := AFrame.ClauseCount;
end;

{ end. Returns True when the function body's own `end` was consumed. }
function TBodyWalker.HandleEnd: Boolean;
var
  Frame: TWasmCtrlFrame;
  Target: UInt32;
begin
  Result := False;

  { `if` without `else`: the spec requires t1* = t2*, and the missing arm
    is synthesised rather than special-cased so the typing falls out of
    the same pop. }
  if FCtrls[FCtrlCount - 1].Kind = wctIf then
    HandleElse(True, 0);

  Frame := PopCtrlCore;
  Target := UInt32(FCodeCount);

  { A try_table's handler entry is appended HERE, at its `end`, so an
    inner handler lands in the table before its enclosing one and a linear
    scan from index 0 finds the innermost (Wasm.Ir's TWasmIrHandlers
    comment — do not sort that table). The protected range ends after the
    frame's own merge moves, which PopCtrlCore has just emitted. }
  if Frame.Kind = wctTryTable then
    AppendHandler(Frame, Target);

  if Frame.Kind = wctFuncBody then
  begin
    { Every function's Code ends with exactly one iroReturn, emitted
      whether or not the frame is reachable, so an interpreter's fetch
      loop needs no end-of-array check. }
    Emit(iroReturn, IR_NO_REG, IR_NO_REG, IR_NO_REG, 0);
    ResolvePatches(Frame, Target);
    Exit(True);
  end;

  ResolvePatches(Frame, Target);
  PushVals(Frame.EndTypes, Frame.MergeRegs);
end;

procedure TBodyWalker.HandleBr;
var
  Depth: UInt32;
  Idx: Integer;
  Regs: TWasmRegList;
begin
  Depth := FReader.ReadU32;
  Idx := CtrlIndex(Depth);
  Regs := PopVals(LabelTypes(Idx));
  EmitEdge(Idx, Regs);
  MarkUnreachable;
end;

procedure TBodyWalker.HandleBrIf;
var
  Depth: UInt32;
  Idx: Integer;
  Cond: TWasmValEntry;
  Types: TWasmValTypeList;
  Regs: TWasmRegList;
begin
  Depth := FReader.ReadU32;
  Idx := CtrlIndex(Depth);
  Cond := PopValExpect(MakeI32);
  Types := LabelTypes(Idx);
  Regs := PopVals(Types);
  PushVals(Types, Regs);
  EmitConditionalEdge(Idx, Cond.Reg, Regs);
end;

{ br_table. Every entry gets its own stub, emitted contiguously right
  after the iroBrTable in entry order with the default last, and stubs
  are NOT deduplicated even when two entries share a label: deterministic
  emission is what makes the disassembly-based tests stable, and
  br_table is not hot enough to trade that away. Placing the stubs there
  is safe because br_table is unconditional — the frame is dead
  afterwards, so nothing else would be emitted at that point anyway. }
procedure TBodyWalker.HandleBrTable;
var
  Count, I: Integer;
  Start: NativeUInt;
  Entries: TWasmRegList;
  DefaultDepth: UInt32;
  DefaultIdx, EntryIdx: Integer;
  Cond: TWasmValEntry;
  Arity: Integer;
  Types: TWasmValTypeList;
  Regs, Placeholder: TWasmRegList;
  Popped: array of TWasmValEntry;
  J: Integer;
  AuxIdx: UInt32;
begin
  Start := FReader.Position;
  { The label vector is a `vec(labelidx)` like any other, so the count is
    bounded by the bytes left BEFORE anything is sized: every entry is at
    least one byte, so a larger count belongs to a truncated body and is
    MALFORMED. Reading it any other way lets a five-byte body ask for a
    four-billion-element array. ReadVecCount is the project's one home
    for that rule and its message is the shared truncated-vector one. }
  Count := Integer(ReadVecCount(FReader, 'br_table target'));
  SetLength(Entries, Count);
  for I := 0 to Count - 1 do
    Entries[I] := FReader.ReadU32;
  DefaultDepth := FReader.ReadU32;

  Cond := PopValExpect(MakeI32);
  DefaultIdx := CtrlIndex(DefaultDepth);
  Arity := Length(LabelTypes(DefaultIdx));

  { Arity checking is the spec algorithm's: every target's label arity
    must equal the default's, and each target's label types are checked
    non-destructively by push_vals(pop_vals(...)) before the default's
    are popped. }
  for I := 0 to Count - 1 do
  begin
    EntryIdx := CtrlIndex(Entries[I]);
    Types := LabelTypes(EntryIdx);
    if Length(Types) <> Arity then
      { Upstream folds a br_table label-arity divergence into `type
        mismatch` (br_table.wast, unreached-invalid.wast), not a distinct
        arity prefix — confirmed by corpus run 2026-08-09. }
      ValErr(MSG_TYPE_MISMATCH,
        Format('br_table target %d has arity %d, default has %d, at '
          + 'offset %u', [I, Length(Types), Arity, FBase + Start]));
    { push_vals(pop_vals(...)): re-push the ACTUAL popped operands, NOT the
      label types. In polymorphic (post-unreachable) code a popped operand
      is Bot; pushing the label type back instead would leave a CONCRETE
      type on the stack, so a later target with a DIFFERENT label type sees
      a spurious mismatch (`expected f64, found f32`) — exactly the
      meet-bottom case the spec algorithm avoids (appendix
      `algorithm-validation-of-opcode-sequences`, br_table;
      unreached-valid.wast). In reachable code the popped entry equals the
      label type, so this is identical to the old behaviour. }
    SetLength(Popped, Length(Types));
    for J := High(Types) downto 0 do
      Popped[J] := PopValExpect(Types[J]);
    for J := 0 to High(Popped) do
      PushEntry(Popped[J]);
  end;

  Regs := PopVals(LabelTypes(DefaultIdx));

  if Emitting then
  begin
    SetLength(Placeholder, Count + 1);
    for I := 0 to Count do
      Placeholder[I] := 0;
    { The block is [N, s0 .. s(N-1)] where N counts the default, which is
      the last entry. }
    AuxIdx := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, Placeholder);
    Emit(iroBrTable, IR_NO_REG, Cond.Reg, AuxIdx, 0);

    for I := 0 to Count - 1 do
    begin
      FFn.AuxU32[AuxIdx + 1 + UInt32(I)] := UInt32(FCodeCount);
      EmitEdge(CtrlIndex(Entries[I]), Regs);
    end;
    FFn.AuxU32[AuxIdx + 1 + UInt32(Count)] := UInt32(FCodeCount);
    EmitEdge(DefaultIdx, Regs);
  end;

  MarkUnreachable;
end;

{ return is a branch to the outermost label; the results live in a fixed
  register block, which is why iroReturn is operandless. }
procedure TBodyWalker.HandleReturn;
var
  Regs: TWasmRegList;
begin
  Regs := PopVals(FReturnTypes);
  EmitEdge(0, Regs);
  MarkUnreachable;
end;

{ The tail-call result rule, verbatim from
  `appendix/algorithm-validation-of-opcode-sequences` (return_call_ref):
  the callee's result ARITY must equal this function's, and the results
  are then popped against this function's return types. }
procedure TBodyWalker.CheckTailResults(const AResults: TWasmValTypeList);
var
  Regs: TWasmRegList;
begin
  if Length(AResults) <> Length(FReturnTypes) then
    ValErr(MSG_TYPE_MISMATCH,
      Format('tail call returns %d value(s), the caller returns %d',
        [Length(AResults), Length(FReturnTypes)]));
  SetLength(Regs, 0);
  PushVals(AResults, Regs);
  PopVals(FReturnTypes);
end;

procedure TBodyWalker.HandleCall(const ATail: Boolean);
var
  Start: NativeUInt;
  FuncIdx: UInt32;
  Ft: TWasmFuncType;
  Params, Results: TWasmValTypeList;
  ArgRegs, ResRegs: TWasmRegList;
  ArgAux, ResAux: UInt32;
begin
  Start := FReader.Position;
  FuncIdx := FReader.ReadU32;
  if FuncIdx >= UInt32(Length(FSpaces.FuncTypes)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_FUNCTION, FuncIdx),
      Format('out of range (%d function(s)) at offset %u',
        [Length(FSpaces.FuncTypes), FBase + Start]));

  Ft := FuncTypeAt(FSpaces.FuncTypes[FuncIdx]);
  Params := CopyValTypes(Ft.Params);
  Results := CopyValTypes(Ft.Results);
  ArgRegs := PopVals(Params);

  if ATail then
  begin
    CheckTailResults(Results);
    if Emitting then
    begin
      ArgAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ArgRegs, Params));
      Emit(iroReturnCall, IR_NO_REG, ArgAux, IR_NO_REG, Int64(FuncIdx));
    end;
    MarkUnreachable;
    Exit;
  end;

  ResRegs := AllocTemps(Results);
  if Emitting then
  begin
    ArgAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ArgRegs, Params));
    ResAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ResRegs, Results));
    Emit(iroCall, IR_NO_REG, ArgAux, ResAux, Int64(FuncIdx));
  end;
  PushVals(Results, ResRegs);
end;

procedure TBodyWalker.HandleCallIndirect(const ATail: Boolean);
var
  Start: NativeUInt;
  TypeIdx, TableIdx: UInt32;
  Ft: TWasmFuncType;
  Params, Results: TWasmValTypeList;
  ArgRegs, ResRegs: TWasmRegList;
  ArgAux, ResAux: UInt32;
  IdxReg: UInt32;
  AddrType: TWasmValueType;
begin
  Start := FReader.Position;
  TypeIdx := FReader.ReadU32;
  TableIdx := FReader.ReadU32;

  if TableIdx >= UInt32(Length(FSpaces.Tables)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_TABLE, TableIdx),
      Format('out of range (%d table(s)) at offset %u',
        [Length(FSpaces.Tables), FBase + Start]));

  { The table must hold function references. }
  if not FTypes.MatchesRefType(FSpaces.Tables[TableIdx].RefType,
    MakeRefType(True, MakeAbsHeapType(wahFunc))) then
    ValErr(MSG_TYPE_MISMATCH,
      'call_indirect requires a table of function references, found '
      + FSpaces.Tables[TableIdx].RefType.Describe);

  Ft := FuncTypeAt(TypeIdx);
  Params := CopyValTypes(Ft.Params);
  Results := CopyValTypes(Ft.Results);

  { UNCONFIRMED. `instruction_get call_indirect` renders the index
    operand as I32 at the pin, but `table.get` on the very same table
    renders the table's ADDRESS TYPE (`at`), and table64 is in the 3.0
    draft — an i32-only index would make call_indirect unusable on a
    64-bit table. The address type is taken here as the coherent reading;
    the two readings agree exactly for every i32 table, which is every
    case that exists today. Track C's runner settles it, and it is one
    line. }
  if FSpaces.Tables[TableIdx].Limits.AddrType = watI64 then
    AddrType := MakeNumValueType(wntI64)
  else
    AddrType := MakeI32;

  IdxReg := PopValExpect(AddrType).Reg;
  ArgRegs := PopVals(Params);

  if ATail then
  begin
    CheckTailResults(Results);
    if Emitting then
    begin
      ArgAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ArgRegs, Params));
      Emit(iroReturnCallIndirect, IdxReg, ArgAux, IR_NO_REG,
        IrPack(TypeIdx, TableIdx));
    end;
    MarkUnreachable;
    Exit;
  end;

  ResRegs := AllocTemps(Results);
  if Emitting then
  begin
    ArgAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ArgRegs, Params));
    ResAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ResRegs, Results));
    Emit(iroCallIndirect, IdxReg, ArgAux, ResAux,
      IrPack(TypeIdx, TableIdx));
  end;
  PushVals(Results, ResRegs);
end;

procedure TBodyWalker.HandleCallRef(const ATail: Boolean);
var
  TypeIdx: UInt32;
  Ft: TWasmFuncType;
  Params, Results: TWasmValTypeList;
  ArgRegs, ResRegs: TWasmRegList;
  ArgAux, ResAux: UInt32;
  RefReg: UInt32;
begin
  TypeIdx := FReader.ReadU32;
  Ft := FuncTypeAt(TypeIdx);
  Params := CopyValTypes(Ft.Params);
  Results := CopyValTypes(Ft.Results);

  { `instruction_get call_ref`: the callee operand is (ref null x). }
  RefReg := PopValExpect(MakeRefValueType(
    MakeRefType(True, MakeConcreteHeapType(TypeIdx)))).Reg;
  ArgRegs := PopVals(Params);

  if ATail then
  begin
    CheckTailResults(Results);
    if Emitting then
    begin
      ArgAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ArgRegs, Params));
      Emit(iroReturnCallRef, RefReg, ArgAux, IR_NO_REG, Int64(TypeIdx));
    end;
    MarkUnreachable;
    Exit;
  end;

  ResRegs := AllocTemps(Results);
  if Emitting then
  begin
    ArgAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ArgRegs, Params));
    ResAux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, SlotList(ResRegs, Results));
    Emit(iroCallRef, RefReg, ArgAux, ResAux, Int64(TypeIdx));
  end;
  PushVals(Results, ResRegs);
end;

{ --- variable: globals ---------------------------------------------------- }

{ `valid-global.get` ([] -> [t]) and `valid-global.set` ([t] -> []). The
  ONLY extra rule is mutability, and only on the set side: "globals are
  classified by … a mutability flag" and an immutable one may not be
  written. }
procedure TBodyWalker.HandleGlobal(const ASet: Boolean;
  const AOffset: NativeUInt);
var
  Idx: UInt32;
  G: TWasmGlobalType;
  Dest, Reg: UInt32;
begin
  Idx := FReader.ReadU32;
  G := CheckGlobal(Idx, AOffset);

  if ASet then
  begin
    if not G.Mut then
      ValErr(MSG_IMMUTABLE_GLOBAL,
        Format('global %u is not mutable at offset %u', [Idx, AOffset]));
    Reg := PopValExpect(G.ValueType).Reg;
    if Emitting then
      { A v128 global's cell is the 16-byte Vec side (SIMD design §1.7); the
        validator emits the width-specific op so the interpreter's *Vec arm
        is the single runtime path and never asks a register's width. }
      if G.ValueType.Kind = wvkVec then
        Emit(iroGlobalSetVec, IR_NO_REG, Reg, IR_NO_REG, Int64(Idx))
      else
        Emit(iroGlobalSet, IR_NO_REG, Reg, IR_NO_REG, Int64(Idx));
    Exit;
  end;

  if Emitting then
  begin
    Dest := AllocTemp(G.ValueType);
    if G.ValueType.Kind = wvkVec then
      Emit(iroGlobalGetVec, Dest, IR_NO_REG, IR_NO_REG, Int64(Idx))
    else
      Emit(iroGlobalGet, Dest, IR_NO_REG, IR_NO_REG, Int64(Idx));
  end
  else
    Dest := IR_NO_REG;
  PushVal(G.ValueType, Dest);
end;

{ --- table ---------------------------------------------------------------- }

{ `valid-table.get`: [at] -> [t]. The index operand is the TABLE'S ADDRESS
  TYPE, not i32 — table64 is in the pinned draft. }
procedure TBodyWalker.HandleTableGet(const AOffset: NativeUInt);
var
  Idx: UInt32;
  Tt: TWasmTableType;
  IdxReg, Dest: UInt32;
  Elem: TWasmValueType;
begin
  Idx := FReader.ReadU32;
  Tt := CheckTable(Idx, AOffset);
  Elem := MakeRefValueType(Tt.RefType);

  IdxReg := PopValExpect(AddrValType(Tt.Limits.AddrType)).Reg;
  if Emitting then
  begin
    Dest := AllocTemp(Elem);
    Emit(iroTableGet, Dest, IdxReg, IR_NO_REG, Int64(Idx));
  end
  else
    Dest := IR_NO_REG;
  PushVal(Elem, Dest);
end;

{ `valid-table.set`: [at t] -> []. The value is the SHALLOWER operand. }
procedure TBodyWalker.HandleTableSet(const AOffset: NativeUInt);
var
  Idx: UInt32;
  Tt: TWasmTableType;
  IdxReg, ValReg: UInt32;
begin
  Idx := FReader.ReadU32;
  Tt := CheckTable(Idx, AOffset);

  ValReg := PopValExpect(MakeRefValueType(Tt.RefType)).Reg;
  IdxReg := PopValExpect(AddrValType(Tt.Limits.AddrType)).Reg;
  if Emitting then
    Emit(iroTableSet, IR_NO_REG, IdxReg, ValReg, Int64(Idx));
end;

{ --- memory: loads and stores --------------------------------------------- }

{ `valid-load-val` / `valid-load-pack` ([at] -> [t]) and
  `valid-store-val` / `valid-store-pack` ([at t] -> []), plus
  `valid-memarg`'s alignment condition, which ReadMemarg owns.

  The store family is the one place a SOURCE register lives in Dest: that
  keeps A the address and B the memory index across all 23 opcodes, which
  is what lets a tier write one address-computation path. }
procedure TBodyWalker.HandleLoadStore(const AOp: Byte;
  const AOffset: NativeUInt);
var
  MemIdx: UInt32;
  StaticOffset: UInt64;
  Mem: TWasmMemType;
  Value: TWasmValueType;
  AddrReg, ValReg, Dest: UInt32;
  IrOp: TWasmIrOp;
begin
  ReadMemarg(AOp, MemIdx, StaticOffset, AOffset);
  Mem := CheckMemory(MemIdx, AOffset);
  { `valid-memarg`: the static offset must fit the memory's address type.
    A memory64 admits the full u64 offset; an i32 memory caps it at 2^32-1
    ($FFFFFFFF). Only the i32 case can overflow, since the offset is a u64. }
  if (Mem.Limits.AddrType <> watI64) and (StaticOffset > $FFFFFFFF) then
    ValErr(MSG_OFFSET_OUT_OF_RANGE,
      Format('static offset %u does not fit the i32 memory %u at offset %u',
        [StaticOffset, MemIdx, AOffset]));
  Value := MakeNumValueType(MEM_SIG[AOp].Value);
  IrOp := TWasmIrOp(Ord(iroI32Load) + Integer(AOp) - $28);

  if MEM_SIG[AOp].IsStore then
  begin
    ValReg := PopValExpect(Value).Reg;
    AddrReg := PopValExpect(AddrValType(Mem.Limits.AddrType)).Reg;
    if Emitting then
      Emit(IrOp, ValReg, AddrReg, MemIdx, Int64(StaticOffset));
    Exit;
  end;

  AddrReg := PopValExpect(AddrValType(Mem.Limits.AddrType)).Reg;
  if Emitting then
  begin
    Dest := AllocTemp(Value);
    Emit(IrOp, Dest, AddrReg, MemIdx, Int64(StaticOffset));
  end
  else
    Dest := IR_NO_REG;
  PushVal(Value, Dest);
end;

{ `valid-memory.size` ([] -> [at]) and `valid-memory.grow`
  ([at] -> [at]). Both take a memidx immediate in the 3.0 grammar —
  multi-memory made the old fixed $00 byte an index. }
procedure TBodyWalker.HandleMemorySizeGrow(const AGrow: Boolean;
  const AOffset: NativeUInt);
var
  Idx: UInt32;
  Mem: TWasmMemType;
  Addr: TWasmValueType;
  Reg, Dest: UInt32;
begin
  Idx := FReader.ReadU32;
  Mem := CheckMemory(Idx, AOffset);
  Addr := AddrValType(Mem.Limits.AddrType);

  Reg := IR_NO_REG;
  if AGrow then
    Reg := PopValExpect(Addr).Reg;

  if Emitting then
  begin
    Dest := AllocTemp(Addr);
    if AGrow then
      Emit(iroMemoryGrow, Dest, Reg, IR_NO_REG, Int64(Idx))
    else
      Emit(iroMemorySize, Dest, IR_NO_REG, IR_NO_REG, Int64(Idx));
  end
  else
    Dest := IR_NO_REG;
  PushVal(Addr, Dest);
end;

{ --- reference ------------------------------------------------------------ }

{ `valid-ref.null`: [] -> [(ref null ht)], with the heap type validated
  (`valid-heaptype`). The instruction carries no type: a null value has no
  runtime type and the static one is in RegTypes[Dest], which is where the
  stack map reads it. }
procedure TBodyWalker.HandleRefNull;
var
  Heap: TWasmHeapType;
  Ty: TWasmValueType;
  Dest: UInt32;
begin
  Heap := ReadHeapType(FReader);
  CheckHeapType(Heap);
  Ty := MakeRefValueType(MakeRefType(True, Heap));

  if Emitting then
  begin
    Dest := AllocTemp(Ty);
    Emit(iroRefNull, Dest, IR_NO_REG, IR_NO_REG, 0);
  end
  else
    Dest := IR_NO_REG;
  PushVal(Ty, Dest);
end;

{ `appendix/algorithm-validation-of-opcode-sequences`, ref.is_null:
  `pop_ref(); push_val(I32)` — ANY reference, nullable or not. }
procedure TBodyWalker.HandleRefIsNull;
var
  E: TWasmValEntry;
  Dest: UInt32;
begin
  E := PopRef;
  if Emitting then
  begin
    Dest := AllocTemp(MakeI32);
    Emit(iroRefIsNull, Dest, E.Reg, IR_NO_REG, 0);
  end
  else
    Dest := IR_NO_REG;
  PushVal(MakeI32, Dest);
end;

{ `valid-ref.func`: [] -> [(ref ht)] — NON-nullable, and the CONCRETE
  function type, not funcref.

  The second condition is the one that needs the module: x must be in
  C.REFS, "the list of function indices that occur in the module outside
  functions and can hence be used to form references inside them"
  (`context`). The walker takes that set as an input (TWasmDeclaredFuncs)
  because no single body can derive it. }
procedure TBodyWalker.HandleRefFunc(const AOffset: NativeUInt);
var
  Idx: UInt32;
  Ty: TWasmValueType;
  Dest: UInt32;
begin
  Idx := FReader.ReadU32;
  if Idx >= UInt32(Length(FSpaces.FuncTypes)) then
    ValErr(UnknownIndex(MSG_UNKNOWN_FUNCTION, Idx),
      Format('out of range (%d function(s)) at offset %u',
        [Length(FSpaces.FuncTypes), AOffset]));

  if (Idx >= UInt32(Length(FSpaces.DeclaredFuncs))) or (not FSpaces.DeclaredFuncs[Idx]) then
    ValErr(MSG_UNDECLARED_FUNCTION_REFERENCE,
      Format('function %u is not declared outside a function body, at '
        + 'offset %u', [Idx, AOffset]));

  Ty := MakeConcreteRef(False, FSpaces.FuncTypes[Idx]);
  if Emitting then
  begin
    Dest := AllocTemp(Ty);
    Emit(iroRefFunc, Dest, IR_NO_REG, IR_NO_REG, Int64(Idx));
  end
  else
    Dest := IR_NO_REG;
  PushVal(Ty, Dest);
end;

{ `valid-ref.eq`: [eqref eqref] -> [i32]. }
procedure TBodyWalker.HandleRefEq;
var
  RegA, RegB, Dest: UInt32;
  Eq: TWasmValueType;
begin
  Eq := MakeAbsRef(True, wahEq);
  RegB := PopValExpect(Eq).Reg;
  RegA := PopValExpect(Eq).Reg;
  if Emitting then
  begin
    Dest := AllocTemp(MakeI32);
    Emit(iroRefEq, Dest, RegA, RegB, 0);
  end
  else
    Dest := IR_NO_REG;
  PushVal(MakeI32, Dest);
end;

{ `appendix/algorithm-validation-of-opcode-sequences`, ref.as_non_null:
  `let rt = pop_ref(); push_val(Ref(rt.heap, false))`. The heap type is
  carried through unchanged; only nullability is dropped. }
procedure TBodyWalker.HandleRefAsNonNull;
var
  E: TWasmValEntry;
  Ty: TWasmValueType;
  Dest: UInt32;
begin
  E := PopRef;
  Ty := MakeRefValueType(MakeRefType(False, E.ValType.Ref.Heap));
  if Emitting then
  begin
    Dest := AllocTemp(Ty);
    Emit(iroRefAsNonNull, Dest, E.Reg, IR_NO_REG, 0);
  end
  else
    Dest := IR_NO_REG;
  PushVal(Ty, Dest);
end;

{ br_on_null / br_on_non_null. Their asymmetry is the whole difficulty
  (`appendix/algorithm-validation-of-opcode-sequences`, br_on_null;
  `valid-br_on_non_null`):

    br_on_null n     : [t* (ref null ht)] -> [t* (ref ht)]
                       label = [t*]     — the reference is NOT delivered
    br_on_non_null n : [t* (ref null ht)] -> [t*]
                       label = [t* (ref ht)] — it IS, as the last value

  So br_on_null refines on the FALL-THROUGH and br_on_non_null refines
  into the label's last merge register, which is why only the former has
  a Dest. }
procedure TBodyWalker.HandleBrOnNull(const ANonNull: Boolean);
var
  Depth: UInt32;
  Idx: Integer;
  E: TWasmValEntry;
  Types: TWasmValTypeList;
  Regs: TWasmRegList;
  NonNullTy: TWasmValueType;
  Refine: UInt32;
begin
  Depth := FReader.ReadU32;
  Idx := CtrlIndex(Depth);

  E := PopRef;
  NonNullTy := MakeRefValueType(MakeRefType(False, E.ValType.Ref.Heap));
  Types := LabelTypes(Idx);

  if ANonNull then
  begin
    { `valid-br_on_non_null` gives the label the type [t* (ref ht)], so an
      empty label cannot satisfy the rule at all. Without this guard the
      push/pop pair below would silently accept one — pop_vals of nothing
      checks nothing. }
    if Length(Types) = 0 then
      ValErr(MSG_TYPE_MISMATCH,
        Format('br_on_non_null delivers a reference to label %u, which '
          + 'takes no values', [Depth]));

    { The label's last type receives the reference, so it is checked by
      pushing the refined value and popping the label types over it. }
    PushVal(NonNullTy, E.Reg);
    Regs := PopVals(Types);
    PushVals(Types, Regs);
    { …and popped straight back off: the fall-through does not keep it. }
    PopVal;
    EmitRefEdge(Idx, iroBrOnNonNull, iroBrOnNull, E.Reg, IR_NO_REG,
      Regs, 0);
    Exit;
  end;

  Regs := PopVals(Types);
  PushVals(Types, Regs);

  if Emitting then
    Refine := AllocTemp(NonNullTy)
  else
    Refine := IR_NO_REG;

  EmitRefEdge(Idx, iroBrOnNull, iroBrOnNonNull, E.Reg, Refine, Regs, 0);
  PushVal(NonNullTy, Refine);
end;

{ --- exception handling --------------------------------------------------- }

{ `appendix/algorithm-validation-of-opcode-sequences`, throw:
  `pop_vals(tags[x].type.params); unreachable()`. `valid-throw` adds that
  "The THROW instruction is stack-polymorphic", which is what the
  unreachable() call encodes. }
{ `[t1 t2 …]` — the reference's stack-type spelling, used only by throw's
  whole-signature diagnostic below. }
function FormatStackTypes(const ATypes: array of TWasmValueType): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to High(ATypes) do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + ATypes[I].Describe;
  end;
  Result := Result + ']';
end;

procedure TBodyWalker.HandleThrow(const AOffset: NativeUInt);
var
  Idx: UInt32;
  Ft: TWasmFuncType;
  ArgRegs: TWasmRegList;
  Aux: UInt32;
  Floor, Avail, I: Integer;
  Ok: Boolean;
  Have: TArray<TWasmValueType>;
begin
  Idx := FReader.ReadU32;
  Ft := CheckTag(Idx, AOffset);

  { valid-throw pops the tag's params. While the current frame is still
    reachable, a shortfall or a param type mismatch is reported against the
    WHOLE instruction signature and the whole in-frame operand stack —
    `type mismatch: instruction requires [t*] but stack has [t*]`
    (throw.wast:52,54; appendix/algorithm-validation-of-opcode-sequences,
    throw). A polymorphic (unreachable) frame fills any shortfall with Bot,
    so the generic pop below handles it. }
  if not FCtrls[FCtrlCount - 1].Unreachable then
  begin
    Floor := FCtrls[FCtrlCount - 1].ValHeight;
    Avail := FValCount - Floor;
    Ok := Avail >= Length(Ft.Params);
    if Ok then
      for I := 0 to High(Ft.Params) do
        if not FTypes.MatchesValType(
          FVals[FValCount - Length(Ft.Params) + I].ValType, Ft.Params[I]) then
        begin
          Ok := False;
          Break;
        end;
    if not Ok then
    begin
      SetLength(Have, Avail);
      for I := 0 to Avail - 1 do
        Have[I] := FVals[Floor + I].ValType;
      ValErr(MSG_TYPE_MISMATCH,
        'instruction requires ' + FormatStackTypes(Ft.Params)
        + ' but stack has ' + FormatStackTypes(Have));
    end;
  end;

  ArgRegs := PopVals(CopyValTypes(Ft.Params));

  if Emitting then
  begin
    Aux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, ArgRegs);
    Emit(iroThrow, IR_NO_REG, Aux, IR_NO_REG, Int64(Idx));
  end;
  MarkUnreachable;
end;

{ `valid-throw_ref`: [t_1* exnref] -> [t_2*] — stack-polymorphic in the
  same way `throw` is, so the frame ends here too. }
procedure TBodyWalker.HandleThrowRef;
var
  Reg: UInt32;
begin
  Reg := PopValExpect(MakeAbsRef(True, wahExn)).Reg;
  if Emitting then
    Emit(iroThrowRef, IR_NO_REG, Reg, IR_NO_REG, 0);
  MarkUnreachable;
end;

{ try_table. It emits NO instruction: what it contributes is one entry in
  the function's handler table covering its body's instruction range, plus
  one clause per catch.

  `appendix/algorithm-validation-of-opcode-sequences`, try_table:

    pop_vals([t1])
    foreach (handler in handler)
      error_if(ctrls.size() < handler.label)
      push_ctrl(catch, [], label_types(ctrls[handler.label]))
      switch (handler.clause)
        case (catch x)         push_vals(tags[x].type.params)
        case (catch_ref x)     push_vals(tags[x].type.params); push_val(Exnref)
        case (catch_all)       skip
        case (catch_all_ref)   push_val(Exnref)
      pop_ctrl()
    push_ctrl(try_table, [t1], [t2])

  Two things fall out of that shape and both are load-bearing:

  1. THE CLAUSE LABELS RESOLVE BEFORE THE try_table FRAME IS PUSHED. The
     appendix evaluates ctrls[handler.label] in the pre-push context.
     Getting this wrong shifts every label by one and is silent on
     `(try_table (catch $t 0) ...)` at the outermost level.
  2. The catch frame's push/pop pair asserts exactly "what the handler
     delivers equals what the label expects", so the payload destination
     IS the target label's merge-register vector. Track H writes the
     payload there and transfers; no stub and no moves are needed. The
     arity-and-matching check below is that push_ctrl/pop_ctrl pair
     written out, without the emission a real frame would trigger. }
procedure TBodyWalker.HandleTryTable(const AOffset: NativeUInt);
var
  InTypes, OutTypes, Payload: TWasmValTypeList;
  ParamRegs, MergeRegs: TWasmRegList;
  Count, I: UInt32;
  J, N: Integer;
  Start: NativeUInt;
  Kind: Byte;
  TagIdx, Label_: UInt32;
  Target: Integer;
  Ft: TWasmFuncType;
  Types: TWasmValTypeList;
  Clause: TWasmIrCatchClause;
  ClauseIdx, FirstClause, Recorded: UInt32;
  Record_: Boolean;
begin
  ReadBlockType(InTypes, OutTypes);
  Count := FReader.ReadU32;

  ParamRegs := PopVals(InTypes);

  Record_ := Emitting;
  FirstClause := UInt32(Length(FFn.HandlerClauses));
  Recorded := 0;

  I := 0;
  while I < Count do
  begin
    Start := FReader.Position;
    Kind := FReader.ReadByte;
    TagIdx := 0;
    case Kind of
      $00, $01:
        begin
          TagIdx := FReader.ReadU32;
          Label_ := FReader.ReadU32;
        end;
      $02, $03:
        Label_ := FReader.ReadU32;
    else
      { `binary-catch` assigns exactly four kind bytes; Track A's
        expression skipper raises the same message from the same
        grammar. }
      DecErr(Format('malformed catch clause kind $%.2x at offset %u',
        [Kind, FBase + Start]));
      Label_ := 0;
    end;

    Target := CtrlIndex(Label_);

    { The payload the handler delivers, per clause kind. }
    Payload := nil;
    if Kind <= $01 then
    begin
      Ft := CheckTag(TagIdx, FBase + Start);
      Payload := CopyValTypes(Ft.Params);
    end;
    if (Kind = $01) or (Kind = $03) then
    begin
      { catch_ref / catch_all_ref deliver a NON-NULL `(ref exn)`, not a
        nullable `exnref`: a caught exception object always exists, so the
        appendix's `push_val(Exnref)` (algorithm-validation, try_table) is the
        non-null reference (valid-try_table -> Instr_ok/try_table -> Catch_ok;
        exec-handler binds the live exnaddr). try_table.wast's catch_ref1 /
        catch_all_ref1 prove it: their labels expect `(ref exn)` and MUST
        validate, while catch_ref2 / catch_all_ref2 (label `(ref null exn)`)
        still validate because a non-null ref is a subtype of the nullable one.
        Building this nullable rejected catch_ref1 (a non-null ref is not
        delivered by a nullable payload). throw_ref's OPERAND stays nullable
        (HandleThrowRef) — that is a different position, and a null there
        traps. }
      N := Length(Payload);
      SetLength(Payload, N + 1);
      Payload[N] := MakeAbsRef(False, wahExn);
    end;

    Types := LabelTypes(Target);
    if Length(Payload) <> Length(Types) then
      ValErr(MSG_TYPE_MISMATCH,
        Format('catch clause delivers %d value(s), label %u expects %d, '
          + 'at offset %u',
          [Length(Payload), Label_, Length(Types), FBase + Start]));
    for J := 0 to High(Types) do
      if not FTypes.MatchesValType(Payload[J], Types[J]) then
        ValErr(MSG_TYPE_MISMATCH,
          Format('catch clause value %d is %s, label %u expects %s, at '
            + 'offset %u',
            [J, Payload[J].Describe, Label_, Types[J].Describe,
             FBase + Start]));

    if Record_ then
    begin
      Clause.Kind := TWasmIrCatchKind(Kind);
      Clause.TagIndex := TagIdx;
      { A loop label resolved at PUSH time and never uses a patch list. }
      if FCtrls[Target].Kind = wctLoop then
        Clause.TargetInstr := FCtrls[Target].LoopHeader
      else
        Clause.TargetInstr := 0;
      Clause.PayloadAux :=
        IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, FCtrls[Target].MergeRegs);

      ClauseIdx := UInt32(Length(FFn.HandlerClauses));
      SetLength(FFn.HandlerClauses, ClauseIdx + 1);
      FFn.HandlerClauses[ClauseIdx] := Clause;
      Inc(Recorded);
      if FCtrls[Target].Kind <> wctLoop then
        AddClausePatch(Target, ClauseIdx);
    end;

    Inc(I);
  end;

  SetLength(MergeRegs, Length(OutTypes));
  for J := 0 to High(OutTypes) do
    MergeRegs[J] := AllocTemp(OutTypes[J]);

  PushCtrl(wctTryTable, InTypes, OutTypes, MergeRegs, ParamRegs);
  FCtrls[FCtrlCount - 1].HasHandler := Record_;
  FCtrls[FCtrlCount - 1].HandlerStart := UInt32(FCodeCount);
  FCtrls[FCtrlCount - 1].ClauseStart := FirstClause;
  FCtrls[FCtrlCount - 1].ClauseCount := Recorded;
end;

{ --- $FC 8..11: bulk memory ----------------------------------------------- }

{ Immediate ORDER is Track A's, from `binary-memory.init` /
  `binary-memory.copy`: memory.init takes (dataidx, memidx) and
  memory.copy (dst memidx, src memidx). The IR packs them the other way
  round for memory.init — pack(memidx, dataidx) — which is exactly why
  Wasm.Ir says the packing "must never be inferred from the order the
  binary format encodes them in". }
procedure TBodyWalker.HandleBulkMemory(const ASub: UInt32;
  const AOffset: NativeUInt);
var
  DataIdx, MemIdx, SrcMemIdx: UInt32;
  Dst, Src, Cnt: UInt32;
  DstMem, SrcMem: TWasmMemType;
  CountType: TWasmValueType;
begin
  case ASub of
    { memory.init x y : [at i32 i32] -> [] — the source offset and the
      length are ALWAYS i32; only the destination address is address
      typed (`instruction_get memory.init`). }
    8:
      begin
        DataIdx := FReader.ReadU32;
        MemIdx := FReader.ReadU32;
        { The IMMEDIATES decode (dataidx, memidx), but the typing rule
          `Instr_ok/memory.init` premises the MEMORY (x) before the data
          segment (y), so an out-of-range memory is reported first —
          upstream asserts `unknown memory` even when the data index is
          also out of range (memory_init.wast, corpus run 2026-08-09). }
        DstMem := CheckMemory(MemIdx, AOffset);
        CheckData(DataIdx, AOffset);

        Cnt := PopValExpect(MakeI32).Reg;
        Src := PopValExpect(MakeI32).Reg;
        Dst := PopValExpect(AddrValType(DstMem.Limits.AddrType)).Reg;
        if Emitting then
          Emit(iroMemoryInit, Dst, Src, Cnt, IrPack(MemIdx, DataIdx));
      end;

    { data.drop x : [] -> [] }
    9:
      begin
        DataIdx := FReader.ReadU32;
        CheckData(DataIdx, AOffset);
        if Emitting then
          Emit(iroDataDrop, IR_NO_REG, IR_NO_REG, IR_NO_REG,
            Int64(DataIdx));
      end;

    { memory.copy x y : [at1 at2 at] -> []. UNCONFIRMED, and pinned by
      the Track B design document rather than read from prose: the count
      operand's address type is the MINIMUM of the two memories'.
      TWasmAddrType is ordered watI32 < watI64, so the minimum is the
      smaller ordinal. The two readings coincide whenever both memories
      share an address type, which is every module that exists today. }
    10:
      begin
        MemIdx := FReader.ReadU32;
        SrcMemIdx := FReader.ReadU32;
        DstMem := CheckMemory(MemIdx, AOffset);
        SrcMem := CheckMemory(SrcMemIdx, AOffset);

        if SrcMem.Limits.AddrType < DstMem.Limits.AddrType then
          CountType := AddrValType(SrcMem.Limits.AddrType)
        else
          CountType := AddrValType(DstMem.Limits.AddrType);

        Cnt := PopValExpect(CountType).Reg;
        Src := PopValExpect(AddrValType(SrcMem.Limits.AddrType)).Reg;
        Dst := PopValExpect(AddrValType(DstMem.Limits.AddrType)).Reg;
        if Emitting then
          Emit(iroMemoryCopy, Dst, Src, Cnt, IrPack(MemIdx, SrcMemIdx));
      end;

    { memory.fill x : [at i32 at] -> [] — the byte value is i32. }
  else
    begin
      MemIdx := FReader.ReadU32;
      DstMem := CheckMemory(MemIdx, AOffset);

      Cnt := PopValExpect(AddrValType(DstMem.Limits.AddrType)).Reg;
      Src := PopValExpect(MakeI32).Reg;
      Dst := PopValExpect(AddrValType(DstMem.Limits.AddrType)).Reg;
      if Emitting then
        Emit(iroMemoryFill, Dst, Src, Cnt, Int64(MemIdx));
    end;
  end;
end;

{ --- $FC 12..17: table ---------------------------------------------------- }

{ Immediate ORDER is Track A's, from `binary-instr-table`: table.init
  encodes (elemidx, tableidx) — the ELEMENT index first, unlike every
  other two-index instruction — and table.copy (dst tableidx, src
  tableidx). }
procedure TBodyWalker.HandleBulkTable(const ASub: UInt32;
  const AOffset: NativeUInt);
var
  ElemIdx, TableIdx, SrcTableIdx: UInt32;
  Dst, Src, Cnt, Val, Dest: UInt32;
  Tt, SrcTt: TWasmTableType;
  ElemRef: TWasmRefType;
  CountType, Addr: TWasmValueType;
begin
  case ASub of
    { table.init x y : [at i32 i32] -> [], and the segment's reference
      type must fit the table's element type. }
    12:
      begin
        ElemIdx := FReader.ReadU32;
        TableIdx := FReader.ReadU32;
        { The IMMEDIATES decode (elemidx, tableidx), but the typing rule
          `Instr_ok/table.init` premises the TABLE (x) before the element
          segment (y), so an out-of-range table is reported first —
          upstream asserts `unknown table` even when the elem index is
          also out of range (table_init.wast, corpus run 2026-08-09). }
        Tt := CheckTable(TableIdx, AOffset);
        ElemRef := CheckElem(ElemIdx, AOffset);
        if not FTypes.MatchesRefType(ElemRef, Tt.RefType) then
          ValErr(MSG_TYPE_MISMATCH,
            Format('elem segment %u holds %s, table %u holds %s',
              [ElemIdx, ElemRef.Describe, TableIdx,
               Tt.RefType.Describe]));

        Cnt := PopValExpect(MakeI32).Reg;
        Src := PopValExpect(MakeI32).Reg;
        Dst := PopValExpect(AddrValType(Tt.Limits.AddrType)).Reg;
        if Emitting then
          Emit(iroTableInit, Dst, Src, Cnt, IrPack(TableIdx, ElemIdx));
      end;

    { elem.drop x : [] -> [] }
    13:
      begin
        ElemIdx := FReader.ReadU32;
        CheckElem(ElemIdx, AOffset);
        if Emitting then
          Emit(iroElemDrop, IR_NO_REG, IR_NO_REG, IR_NO_REG,
            Int64(ElemIdx));
      end;

    { table.copy x y : [at1 at2 at] -> []. The count's address type
      carries the same UNCONFIRMED minimum rule as memory.copy. }
    14:
      begin
        TableIdx := FReader.ReadU32;
        SrcTableIdx := FReader.ReadU32;
        Tt := CheckTable(TableIdx, AOffset);
        SrcTt := CheckTable(SrcTableIdx, AOffset);
        if not FTypes.MatchesRefType(SrcTt.RefType, Tt.RefType) then
          ValErr(MSG_TYPE_MISMATCH,
            Format('table %u holds %s, table %u holds %s',
              [SrcTableIdx, SrcTt.RefType.Describe, TableIdx,
               Tt.RefType.Describe]));

        if SrcTt.Limits.AddrType < Tt.Limits.AddrType then
          CountType := AddrValType(SrcTt.Limits.AddrType)
        else
          CountType := AddrValType(Tt.Limits.AddrType);

        Cnt := PopValExpect(CountType).Reg;
        Src := PopValExpect(AddrValType(SrcTt.Limits.AddrType)).Reg;
        Dst := PopValExpect(AddrValType(Tt.Limits.AddrType)).Reg;
        if Emitting then
          Emit(iroTableCopy, Dst, Src, Cnt,
            IrPack(TableIdx, SrcTableIdx));
      end;

    { table.grow x : [t at] -> [at] }
    15:
      begin
        TableIdx := FReader.ReadU32;
        Tt := CheckTable(TableIdx, AOffset);
        Addr := AddrValType(Tt.Limits.AddrType);

        Cnt := PopValExpect(Addr).Reg;
        Val := PopValExpect(MakeRefValueType(Tt.RefType)).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(Addr);
          Emit(iroTableGrow, Dest, Val, Cnt, Int64(TableIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(Addr, Dest);
      end;

    { table.size x : [] -> [at] }
    16:
      begin
        TableIdx := FReader.ReadU32;
        Tt := CheckTable(TableIdx, AOffset);
        Addr := AddrValType(Tt.Limits.AddrType);
        if Emitting then
        begin
          Dest := AllocTemp(Addr);
          Emit(iroTableSize, Dest, IR_NO_REG, IR_NO_REG,
            Int64(TableIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(Addr, Dest);
      end;

    { table.fill x : [at t at] -> [] }
  else
    begin
      TableIdx := FReader.ReadU32;
      Tt := CheckTable(TableIdx, AOffset);
      Addr := AddrValType(Tt.Limits.AddrType);

      Cnt := PopValExpect(Addr).Reg;
      Val := PopValExpect(MakeRefValueType(Tt.RefType)).Reg;
      Dst := PopValExpect(Addr).Reg;
      if Emitting then
        Emit(iroTableFill, Dst, Val, Cnt, Int64(TableIdx));
    end;
  end;
end;

{ --- $FB 0..5: struct ----------------------------------------------------- }

{ `appendix/algorithm-validation-of-opcode-sequences`, struct.new and
  struct.set, generalised to the six: expand the type, require a struct,
  bound the field index, and read the field through unpack_field. The
  result reference is NON-nullable and CONCRETE — an allocation cannot
  return null. }
procedure TBodyWalker.HandleStructOp(const ASub: UInt32;
  const AOffset: NativeUInt);
var
  TypeIdx, FieldIdx: UInt32;
  St: TWasmStructType;
  Field: TWasmFieldType;
  Types: TWasmValTypeList;
  ArgRegs: TWasmRegList;
  I: Integer;
  ResTy, FieldTy: TWasmValueType;
  Dest, RefReg, ValReg, Aux: UInt32;
begin
  TypeIdx := FReader.ReadU32;
  ResTy := MakeConcreteRef(False, TypeIdx);

  case ASub of
    { struct.new x : [t*] -> [(ref x)] — an allocation safepoint by op
      kind (Wasm.Ir.IrOpIsSafepoint), so no marker is emitted. }
    0:
      begin
        St := StructTypeAt(TypeIdx);
        SetLength(Types, Length(St.Fields));
        for I := 0 to High(St.Fields) do
          Types[I] := UnpackField(St.Fields[I]);
        ArgRegs := PopVals(Types);
        if Emitting then
        begin
          Dest := AllocTemp(ResTy);
          Aux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, ArgRegs);
          Emit(iroStructNew, Dest, Aux, IR_NO_REG, Int64(TypeIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ResTy, Dest);
      end;

    { struct.new_default x : [] -> [(ref x)], and every field must have a
      default (`aux-default`) — a non-nullable reference field has none. }
    1:
      begin
        St := StructTypeAt(TypeIdx);
        for I := 0 to High(St.Fields) do
          if not IsDefaultableStorage(St.Fields[I].Storage) then
            ValErr(MSG_TYPE_MISMATCH,
              Format('field %d of type %u has type %s, which has no '
                + 'default value, at offset %u',
                [I, TypeIdx, St.Fields[I].Storage.Describe, AOffset]));
        if Emitting then
        begin
          Dest := AllocTemp(ResTy);
          Emit(iroStructNewDefault, Dest, IR_NO_REG, IR_NO_REG,
            Int64(TypeIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ResTy, Dest);
      end;

    { struct.set x n : [(ref null x) t] -> [] — the VALUE is shallower,
      so it pops first, whichever order the appendix pseudocode lists. }
    5:
      begin
        FieldIdx := FReader.ReadU32;
        Field := StructFieldAt(TypeIdx, FieldIdx, AOffset);
        CheckFieldMutable(Field, MSG_IMMUTABLE_FIELD, 'struct.set');
        ValReg := PopValExpect(UnpackField(Field)).Reg;
        RefReg := PopValExpect(MakeConcreteRef(True, TypeIdx)).Reg;
        if Emitting then
          { A v128 field is 16 bytes; the *Vec store carries both slots
            (SIMD design §2.4/§7). Packed storage is never v128, so get_s/
            get_u never reach a vector field. }
          if UnpackField(Field).Kind = wvkVec then
            Emit(iroStructSetVec, IR_NO_REG, RefReg, ValReg,
              IrPack(TypeIdx, FieldIdx))
          else
            Emit(iroStructSet, IR_NO_REG, RefReg, ValReg,
              IrPack(TypeIdx, FieldIdx));
      end;

    { struct.get / get_s / get_u x n : [(ref null x)] -> [t] }
  else
    begin
      FieldIdx := FReader.ReadU32;
      Field := StructFieldAt(TypeIdx, FieldIdx, AOffset);
      CheckFieldAccess(Field, ASub <> 2, 'struct.get');
      FieldTy := UnpackField(Field);
      RefReg := PopValExpect(MakeConcreteRef(True, TypeIdx)).Reg;
      if Emitting then
      begin
        Dest := AllocTemp(FieldTy);
        if FieldTy.Kind = wvkVec then
          { ASub is necessarily 2 (plain get): get_s/get_u require packed
            storage, which v128 is not. }
          Emit(iroStructGetVec, Dest, RefReg, IR_NO_REG,
            IrPack(TypeIdx, FieldIdx))
        else
          Emit(TWasmIrOp(Ord(iroStructGet) + Integer(ASub) - 2), Dest,
            RefReg, IR_NO_REG, IrPack(TypeIdx, FieldIdx));
      end
      else
        Dest := IR_NO_REG;
      PushVal(FieldTy, Dest);
    end;
  end;
end;

{ --- $FB 6..19: array ----------------------------------------------------- }

{ Arrays are NOT address typed: every index, offset, and count below is
  i32 (`instruction_get array.fill` [(ref null x) i32 t i32],
  `array.copy` [(ref null x) i32 (ref null y) i32 i32],
  `array.init_data` [(ref null x) i32 i32 i32]).

  Four of them take more operands than an instruction has fields and use
  an aux block, in wasm stack order, deepest first. }
procedure TBodyWalker.HandleArrayOp(const ASub: UInt32;
  const AOffset: NativeUInt);
var
  TypeIdx, SrcTypeIdx, SegIdx, Count, Take: UInt32;
  Elem, SrcElem: TWasmFieldType;
  ElemTy, ResTy: TWasmValueType;
  SegRef: TWasmRefType;
  Types: TWasmValTypeList;
  ArgRegs, Ops: TWasmRegList;
  I, Avail: Integer;
  Dest, RefReg, IdxReg, ValReg, LenReg, OffReg, CntReg, Aux: UInt32;
  SrcRefReg, SrcIdxReg: UInt32;

  { `valid-array.new_data` / `valid-array.init_data`: the element's
    storage must be packed or a number or a vector — bytes cannot
    initialise a reference. }
  procedure RequireNumericElem(const AWhat: string);
  begin
    if (not Elem.Storage.IsPacked)
      and (Elem.Storage.ValueType.Kind = wvkRef) then
      ValErr(MSG_ARRAY_NOT_NUMERIC,
        AWhat + ' needs a numeric or packed element type, found '
        + Elem.Storage.Describe);
  end;

  { `valid-array.new_elem` / `valid-array.init_elem`: the segment's
    reference type must fit the element type. }
  procedure RequireElemMatches(const AWhat: string);
  begin
    if Elem.Storage.IsPacked
      or (Elem.Storage.ValueType.Kind <> wvkRef)
      or (not FTypes.MatchesRefType(SegRef,
        Elem.Storage.ValueType.Ref)) then
      ValErr(MSG_TYPE_MISMATCH,
        AWhat + ' fills ' + Elem.Storage.Describe + ' from an elem '
        + 'segment of ' + SegRef.Describe);
  end;

begin
  { array.len is the one arm with no type immediate
    (`instruction_get array.len`: [(ref null array)] -> [i32]). }
  if ASub = 15 then
  begin
    RefReg := PopValExpect(MakeAbsRef(True, wahArray)).Reg;
    if Emitting then
    begin
      Dest := AllocTemp(MakeI32);
      Emit(iroArrayLen, Dest, RefReg, IR_NO_REG, 0);
    end
    else
      Dest := IR_NO_REG;
    PushVal(MakeI32, Dest);
    Exit;
  end;

  TypeIdx := FReader.ReadU32;
  Elem := ArrayTypeAt(TypeIdx);
  ElemTy := UnpackField(Elem);
  ResTy := MakeConcreteRef(False, TypeIdx);

  case ASub of
    { array.new x : [t i32] -> [(ref x)] }
    6:
      begin
        LenReg := PopValExpect(MakeI32).Reg;
        ValReg := PopValExpect(ElemTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(ResTy);
          Emit(iroArrayNew, Dest, ValReg, LenReg, Int64(TypeIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ResTy, Dest);
      end;

    { array.new_default x : [i32] -> [(ref x)] }
    7:
      begin
        if not IsDefaultableStorage(Elem.Storage) then
          ValErr(MSG_TYPE_MISMATCH,
            Format('element type %s of type %u has no default value, at '
              + 'offset %u', [Elem.Storage.Describe, TypeIdx, AOffset]));
        LenReg := PopValExpect(MakeI32).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(ResTy);
          Emit(iroArrayNewDefault, Dest, LenReg, IR_NO_REG,
            Int64(TypeIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ResTy, Dest);
      end;

    { array.new_fixed x n : [t^n] -> [(ref x)] }
    8:
      begin
        Count := FReader.ReadU32;

        { n is an OPERAND COUNT, not a byte count, so no vector bound
          applies to it — and `SetLength(Types, n)` on a u32 straight
          out of the bytes is an unbounded allocation. The real bound is
          the same one Wasm.Validator.&Const's StepArrayNewFixed uses:
          every element must ALREADY be on the value stack, so n cannot
          exceed the operands the current frame holds, and exceeding it
          is the `type mismatch` an underflowing pop would have raised
          anyway.

          The clause Const does not need: a constant expression has no
          stack-polymorphic position, a function body does. Under an
          unreachable frame the floor yields Bot for every further pop
          (`appendix/algorithm-stacks`), so `unreachable; array.new_fixed
          $t 1000000` IS well typed — and popping those Bot values
          changes nothing observable, which is why the surplus is
          skipped rather than looped over. Emission is off in that state
          (the frame is dead), so no aux block wants the full width. }
        Avail := FValCount - FCtrls[FCtrlCount - 1].ValHeight;
        Take := Count;
        if Count > UInt32(Avail) then
        begin
          if not FCtrls[FCtrlCount - 1].Unreachable then
            ValErr(MSG_TYPE_MISMATCH,
              Format('array.new_fixed needs %u operand(s) but only %d '
                + 'are on the stack, at offset %u',
                [Count, Avail, AOffset]));
          Take := UInt32(Avail);
        end;

        SetLength(Types, Take);
        for I := 0 to Integer(Take) - 1 do
          Types[I] := ElemTy;
        ArgRegs := PopVals(Types);
        if Emitting then
        begin
          Dest := AllocTemp(ResTy);
          Aux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, ArgRegs);
          Emit(iroArrayNewFixed, Dest, Aux, IR_NO_REG, Int64(TypeIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ResTy, Dest);
      end;

    { array.new_data x y : [i32 i32] -> [(ref x)] }
    9:
      begin
        SegIdx := FReader.ReadU32;
        CheckData(SegIdx, AOffset);
        RequireNumericElem('array.new_data');
        LenReg := PopValExpect(MakeI32).Reg;
        OffReg := PopValExpect(MakeI32).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(ResTy);
          Emit(iroArrayNewData, Dest, OffReg, LenReg,
            IrPack(TypeIdx, SegIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ResTy, Dest);
      end;

    { array.new_elem x y : [i32 i32] -> [(ref x)] }
    10:
      begin
        SegIdx := FReader.ReadU32;
        SegRef := CheckElem(SegIdx, AOffset);
        RequireElemMatches('array.new_elem');
        LenReg := PopValExpect(MakeI32).Reg;
        OffReg := PopValExpect(MakeI32).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(ResTy);
          Emit(iroArrayNewElem, Dest, OffReg, LenReg,
            IrPack(TypeIdx, SegIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ResTy, Dest);
      end;

    { array.get / get_s / get_u x : [(ref null x) i32] -> [t] }
    11, 12, 13:
      begin
        CheckFieldAccess(Elem, ASub <> 11, 'array.get');
        IdxReg := PopValExpect(MakeI32).Reg;
        RefReg := PopValExpect(MakeConcreteRef(True, TypeIdx)).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(ElemTy);
          if ElemTy.Kind = wvkVec then
            { ASub is necessarily 11 (plain get) for a v128 element. }
            Emit(iroArrayGetVec, Dest, RefReg, IdxReg, Int64(TypeIdx))
          else
            Emit(TWasmIrOp(Ord(iroArrayGet) + Integer(ASub) - 11), Dest,
              RefReg, IdxReg, Int64(TypeIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ElemTy, Dest);
      end;

    { array.set x : [(ref null x) i32 t] -> [] }
    14:
      begin
        CheckFieldMutable(Elem, MSG_IMMUTABLE_ARRAY, 'array.set');
        ValReg := PopValExpect(ElemTy).Reg;
        IdxReg := PopValExpect(MakeI32).Reg;
        RefReg := PopValExpect(MakeConcreteRef(True, TypeIdx)).Reg;
        if Emitting then
          if ElemTy.Kind = wvkVec then
            Emit(iroArraySetVec, RefReg, IdxReg, ValReg, Int64(TypeIdx))
          else
            Emit(iroArraySet, RefReg, IdxReg, ValReg, Int64(TypeIdx));
      end;

    { array.fill x : [(ref null x) i32 t i32] -> [] }
    16:
      begin
        CheckFieldMutable(Elem, MSG_IMMUTABLE_ARRAY, 'array.fill');
        CntReg := PopValExpect(MakeI32).Reg;
        ValReg := PopValExpect(ElemTy).Reg;
        IdxReg := PopValExpect(MakeI32).Reg;
        RefReg := PopValExpect(MakeConcreteRef(True, TypeIdx)).Reg;
        if Emitting then
        begin
          SetLength(Ops, 4);
          Ops[0] := RefReg;
          Ops[1] := IdxReg;
          Ops[2] := ValReg;
          Ops[3] := CntReg;
          Aux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, Ops);
          if ElemTy.Kind = wvkVec then
            Emit(iroArrayFillVec, IR_NO_REG, Aux, IR_NO_REG, Int64(TypeIdx))
          else
            Emit(iroArrayFill, IR_NO_REG, Aux, IR_NO_REG, Int64(TypeIdx));
        end;
      end;

    { array.copy x y : [(ref null x) i32 (ref null y) i32 i32] -> [] }
    17:
      begin
        SrcTypeIdx := FReader.ReadU32;
        SrcElem := ArrayTypeAt(SrcTypeIdx);
        CheckFieldMutable(Elem, MSG_IMMUTABLE_ARRAY, 'array.copy');
        if not FTypes.MatchesStorageType(SrcElem.Storage,
          Elem.Storage) then
          ValErr(MSG_ARRAY_TYPES_MISMATCH,
            'array.copy reads ' + SrcElem.Storage.Describe
            + ' into ' + Elem.Storage.Describe);

        CntReg := PopValExpect(MakeI32).Reg;
        SrcIdxReg := PopValExpect(MakeI32).Reg;
        SrcRefReg := PopValExpect(MakeConcreteRef(True, SrcTypeIdx)).Reg;
        IdxReg := PopValExpect(MakeI32).Reg;
        RefReg := PopValExpect(MakeConcreteRef(True, TypeIdx)).Reg;
        if Emitting then
        begin
          SetLength(Ops, 5);
          Ops[0] := RefReg;
          Ops[1] := IdxReg;
          Ops[2] := SrcRefReg;
          Ops[3] := SrcIdxReg;
          Ops[4] := CntReg;
          Aux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, Ops);
          Emit(iroArrayCopy, IR_NO_REG, Aux, IR_NO_REG,
            IrPack(TypeIdx, SrcTypeIdx));
        end;
      end;

    { array.init_data / array.init_elem x y :
      [(ref null x) i32 i32 i32] -> [] }
  else
    begin
      SegIdx := FReader.ReadU32;
      CheckFieldMutable(Elem, MSG_IMMUTABLE_ARRAY, 'array.init');
      if ASub = 18 then
      begin
        CheckData(SegIdx, AOffset);
        RequireNumericElem('array.init_data');
      end
      else
      begin
        SegRef := CheckElem(SegIdx, AOffset);
        RequireElemMatches('array.init_elem');
      end;

      CntReg := PopValExpect(MakeI32).Reg;
      OffReg := PopValExpect(MakeI32).Reg;
      IdxReg := PopValExpect(MakeI32).Reg;
      RefReg := PopValExpect(MakeConcreteRef(True, TypeIdx)).Reg;
      if Emitting then
      begin
        SetLength(Ops, 4);
        Ops[0] := RefReg;
        Ops[1] := IdxReg;
        Ops[2] := OffReg;
        Ops[3] := CntReg;
        Aux := IrAppendAuxBlockGrowing(FFn.AuxU32, FAuxCount, Ops);
        if ASub = 18 then
          Emit(iroArrayInitData, IR_NO_REG, Aux, IR_NO_REG,
            IrPack(TypeIdx, SegIdx))
        else
          Emit(iroArrayInitElem, IR_NO_REG, Aux, IR_NO_REG,
            IrPack(TypeIdx, SegIdx));
      end;
    end;
  end;
end;

{ --- $FB 20..23: ref.test / ref.cast -------------------------------------- }

{ `appendix/algorithm-validation-of-opcode-sequences`, ref.test:

    validate_ref_type(rt)
    pop_val(Ref(top_heap_type(rt), true))
    push_val(I32)        — ref.cast pushes rt instead

  The four encodings are two instructions: $FB 20/22 spell a NON-nullable
  rt and $FB 21/23 a nullable one, which is the only difference between
  them, and it rides in AuxRefTypes rather than in a second IR op. }
procedure TBodyWalker.HandleCast(const ASub: UInt32);
var
  Heap: TWasmHeapType;
  Rt: TWasmRefType;
  Ty: TWasmValueType;
  SrcReg, Dest, Aux: UInt32;
begin
  Heap := ReadHeapType(FReader);
  Rt := MakeRefType((ASub = 21) or (ASub = 23), Heap);
  CheckRefType(Rt);

  SrcReg := PopValExpect(
    MakeAbsRef(True, FTypes.TopHeapType(Heap))).Reg;

  if ASub <= 21 then
    Ty := MakeI32
  else
    Ty := MakeRefValueType(Rt);

  if Emitting then
  begin
    Aux := AddRefTypeAux(Rt);
    Dest := AllocTemp(Ty);
    if ASub <= 21 then
      Emit(iroRefTest, Dest, SrcReg, IR_NO_REG, Int64(Aux))
    else
      Emit(iroRefCast, Dest, SrcReg, IR_NO_REG, Int64(Aux));
  end
  else
    Dest := IR_NO_REG;
  PushVal(Ty, Dest);
end;

{ --- $FB 24/25: br_on_cast, br_on_cast_fail ------------------------------- }

{ `appendix/algorithm-validation-of-opcode-sequences`, br_on_cast:

    validate_ref_type(rt1); validate_ref_type(rt2)
    pop_val(rt1)
    push_val(rt2)
    pop_vals(label_types(ctrls[n])); push_vals(label_types(ctrls[n]))
    pop_val(rt2)
    push_val(diff_ref_type(rt2, rt1))      — i.e. rt1 \ rt2

  br_on_cast_fail is the same shape with the two result types swapped:
  the label receives rt1 \ rt2 and the fall-through keeps rt2.

  In register terms the SOURCE register is what the taken edge moves into
  the label's last merge register, and the fall-through writes a fresh
  register typed by the refinement — so the value is never copied twice.

  UNCONFIRMED: the `rt2 <= rt1` side condition below is read from
  `Instr_ok/br_on_cast`, whose prose the pinned MCP does not serve (the
  clause is SpecTec-generated and empty). It is not in the appendix
  pseudocode either. Without it the difference `rt1 \ rt2` is meaningless
  for unrelated types, which is why it is enforced; Track C's runner
  settles it, and it is one `if`. }
procedure TBodyWalker.HandleBrOnCast(const AFail: Boolean;
  const AOffset: NativeUInt);
var
  Start: NativeUInt;
  Flags: Byte;
  Depth: UInt32;
  Rt1, Rt2, Diff, Pushed, Refined: TWasmRefType;
  Idx: Integer;
  E: TWasmValEntry;
  Types: TWasmValTypeList;
  Regs: TWasmRegList;
  Refine, Aux: UInt32;
  Op, InverseOp: TWasmIrOp;
begin
  Start := FReader.Position;
  Flags := FReader.ReadByte;
  { `binary-castop` assigns exactly $00..$03; Track A's expression
    skipper raises the same message from the same production.
    UNCONFIRMED, in the same way the clause's prose is unavailable: bit 0
    is taken as rt1's nullability and bit 1 as rt2's, in that order. }
  if Flags > $03 then
    DecErr(Format('malformed cast flags $%.2x at offset %u',
      [Flags, FBase + Start]));

  Depth := FReader.ReadU32;
  Rt1 := MakeRefType((Flags and $01) <> 0, ReadHeapType(FReader));
  Rt2 := MakeRefType((Flags and $02) <> 0, ReadHeapType(FReader));
  CheckRefType(Rt1);
  CheckRefType(Rt2);

  if not FTypes.MatchesRefType(Rt2, Rt1) then
    ValErr(MSG_TYPE_MISMATCH,
      Format('%s is not a subtype of %s at offset %u',
        [Rt2.Describe, Rt1.Describe, AOffset]));

  Idx := CtrlIndex(Depth);
  Diff := RefTypeDiff(Rt1, Rt2);

  if AFail then
  begin
    Pushed := Diff;
    Refined := Rt2;
    Op := iroBrOnCastFail;
    InverseOp := iroBrOnCast;
  end
  else
  begin
    Pushed := Rt2;
    Refined := Diff;
    Op := iroBrOnCast;
    InverseOp := iroBrOnCastFail;
  end;

  Types := LabelTypes(Idx);
  { Both forms hand the label a reference as its LAST value, so an empty
    label satisfies neither rule — and the push/pop pair below would not
    notice, because popping nothing checks nothing. }
  if Length(Types) = 0 then
    ValErr(MSG_TYPE_MISMATCH,
      Format('br_on_cast delivers a reference to label %u, which takes '
        + 'no values', [Depth]));

  E := PopValExpect(MakeRefValueType(Rt1));
  PushVal(MakeRefValueType(Pushed), E.Reg);
  Regs := PopVals(Types);
  PushVals(Types, Regs);
  PopVal;

  if Emitting then
  begin
    Refine := AllocTemp(MakeRefValueType(Refined));
    Aux := AddRefTypeAux(Rt2);
  end
  else
  begin
    Refine := IR_NO_REG;
    Aux := 0;
  end;

  EmitRefEdge(Idx, Op, InverseOp, E.Reg, Refine, Regs, Int64(Aux));
  PushVal(MakeRefValueType(Refined), Refine);
end;

{ --- $FB 26..30: extern conversions and i31 ------------------------------- }

{ All five are unary.

  UNCONFIRMED for the two conversions, AND THE SAME POLICY AS
  Wasm.Validator.&Const's StepConvert — the two must not disagree, since
  the same instruction is being typed and a divergence would make a
  module's validity depend on whether it appeared in a body or an
  initialiser. `instruction_get any.convert_extern` renders
  [(ref null extern)] -> [(ref null any)] and `extern.convert_any` the
  mirror, with NULL spelled literally on both sides; that FLAT rendering
  is what both sites implement. The formal rule may instead thread
  nullability through, in which case a non-null operand would yield a
  non-null result and `(global (ref extern) (extern.convert_any
  (ref.i31 ...)))` would become valid. Following the served signature is
  conservative in the ACCEPTANCE direction — it can only ever reject a
  module the propagating reading admits, never wrongly admit one — which
  is why it is the reading taken until Track C's runner settles it. }
procedure TBodyWalker.HandleI31Extern(const ASub: UInt32);
var
  SrcReg, Dest: UInt32;
  Operand, ResultTy: TWasmValueType;
  IrOp: TWasmIrOp;
begin
  case ASub of
    26:
      begin
        Operand := MakeAbsRef(True, wahExtern);
        ResultTy := MakeAbsRef(True, wahAny);
        IrOp := iroAnyConvertExtern;
      end;
    27:
      begin
        Operand := MakeAbsRef(True, wahAny);
        ResultTy := MakeAbsRef(True, wahExtern);
        IrOp := iroExternConvertAny;
      end;
    28:
      begin
        { `valid-ref.i31`: [i32] -> [(ref i31)] — NON-nullable, and an
          allocation safepoint by op kind. }
        Operand := MakeI32;
        ResultTy := MakeAbsRef(False, wahI31);
        IrOp := iroRefI31;
      end;
  else
    begin
      { `valid-i31.get`: [i31ref] -> [i32], and i31ref is NULLABLE. }
      Operand := MakeAbsRef(True, wahI31);
      ResultTy := MakeI32;
      if ASub = 29 then
        IrOp := iroI31GetS
      else
        IrOp := iroI31GetU;
    end;
  end;

  SrcReg := PopValExpect(Operand).Reg;
  if Emitting then
  begin
    Dest := AllocTemp(ResultTy);
    Emit(IrOp, Dest, SrcReg, IR_NO_REG, 0);
  end
  else
    Dest := IR_NO_REG;
  PushVal(ResultTy, Dest);
end;

{ The three prefixed spaces. Unassigned subopcodes stay MALFORMED (Track
  A's wording, reused verbatim); the one ASSIGNED space this unit does not
  type is $FD, which raises the staged SIMD message. That split is
  deliberate: moving an unassigned encoding from decode to validation
  would move the malformed/invalid boundary the conformance suite
  asserts. }
{ The $FD vector space, table-driven over VEC_SIG (SIMD design §3). Every
  v128 operand and result is MakeVecValueType, popped with PopValExpect so
  a mismatch is the ordinary `type mismatch`; a v128 result is allocated
  as wvkVec, which IrAllocReg even-aligns into a slot pair. Two rules are
  vector-specific: the lane immediate is checked against the shape's lane
  count (MSG_INVALID_LANE_INDEX), and the memory family's memarg alignment
  is checked against the access's natural alignment (ReadMemargMax). The
  IR op is VecOpBySub[ASub]; the immediate encodings mirror IR_OP_INFO. }
procedure TBodyWalker.HandleVector(const ASub: UInt32;
  const AOffset: NativeUInt);
var
  Sig: TVecSig;
  Op: TWasmIrOp;
  ScalarTy, VecTy: TWasmValueType;
  RegA, RegB, RegC, Dest, ValReg, AddrReg, MemIdx, Lane, AuxIdx: UInt32;
  StaticOffset: UInt64;
  Mem: TWasmMemType;
  Vec: TWasmV128;
  I: Integer;

  { A lane immediate names a lane the shape has: 0 <= lane < ADim
    (`valid-vextract_lane` / `valid-vreplace_lane` / the *_lane memory
    forms). The byte 255 parses fine and is rejected HERE, as validation. }
  procedure ReadLane(const ADim: Byte);
  begin
    Lane := FReader.ReadByte;
    if Lane >= ADim then
      ValErr(MSG_INVALID_LANE_INDEX,
        Format('lane %u is not below %u at offset %u',
          [Lane, ADim, AOffset]));
  end;

  { memarg for a vector load/store: the same flags/memidx/u64-offset shape
    as a scalar op, the alignment checked against this access's natural
    alignment, then the memory-existence and offset-fits checks that
    HandleLoadStore also runs. }
  procedure ReadVecMemory;
  begin
    ReadMemargMax(Sig.MaxAlign, IR_OP_INFO[Op].Mnemonic, MemIdx,
      StaticOffset, AOffset);
    Mem := CheckMemory(MemIdx, AOffset);
    if (Mem.Limits.AddrType <> watI64) and (StaticOffset > $FFFFFFFF) then
      ValErr(MSG_OFFSET_OUT_OF_RANGE,
        Format('static offset %u does not fit the i32 memory %u at '
          + 'offset %u', [StaticOffset, MemIdx, AOffset]));
  end;

begin
  Sig := VEC_SIG[ASub];
  Op := VecOpBySub[ASub];
  VecTy := MakeVecValueType;

  case Sig.Family of
    vfNullary:  { v128.const: [] -> [v128], 16 literal bytes }
      begin
        for I := 0 to 15 do
          Vec.B[I] := FReader.ReadByte;
        if Emitting then
        begin
          AuxIdx := IrAppendAuxV128Growing(FFn.AuxU32, FAuxCount, Vec);
          Dest := AllocTemp(VecTy);
          Emit(iroV128Const, Dest, IR_NO_REG, IR_NO_REG, Int64(AuxIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfShuffle:  { i8x16.shuffle: [v128 v128] -> [v128], 16 lane bytes < 32 }
      begin
        for I := 0 to 15 do
        begin
          Vec.B[I] := FReader.ReadByte;
          if Vec.B[I] >= Sig.Dim then
            ValErr(MSG_INVALID_LANE_INDEX,
              Format('shuffle lane %u is not below %u at offset %u',
                [Vec.B[I], Sig.Dim, AOffset]));
        end;
        RegB := PopValExpect(VecTy).Reg;
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          AuxIdx := IrAppendAuxV128Growing(FFn.AuxU32, FAuxCount, Vec);
          Dest := AllocTemp(VecTy);
          Emit(iroI8x16Shuffle, Dest, RegA, RegB, Int64(AuxIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfUnary:  { [v128] -> [v128] }
      begin
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, RegA, IR_NO_REG, 0);
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfBinary:  { [v128 v128] -> [v128] }
      begin
        RegB := PopValExpect(VecTy).Reg;
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, RegA, RegB, 0);
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfTernary:  { [v128 v128 v128] -> [v128], third source in Imm }
      begin
        RegC := PopValExpect(VecTy).Reg;
        RegB := PopValExpect(VecTy).Reg;
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, RegA, RegB, Int64(RegC));
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfTest:  { [v128] -> [i32] }
      begin
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(MakeI32);
          Emit(Op, Dest, RegA, IR_NO_REG, 0);
        end
        else
          Dest := IR_NO_REG;
        PushVal(MakeI32, Dest);
      end;

    vfShift:  { [v128 i32] -> [v128] }
      begin
        RegB := PopValExpect(MakeI32).Reg;
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, RegA, RegB, 0);
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfSplat:  { [Scalar] -> [v128] }
      begin
        ScalarTy := MakeNumValueType(Sig.Scalar);
        RegA := PopValExpect(ScalarTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, RegA, IR_NO_REG, 0);
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfExtract:  { [v128] -> [Scalar], lane in Imm }
      begin
        ReadLane(Sig.Dim);
        ScalarTy := MakeNumValueType(Sig.Scalar);
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(ScalarTy);
          Emit(Op, Dest, RegA, IR_NO_REG, Int64(Lane));
        end
        else
          Dest := IR_NO_REG;
        PushVal(ScalarTy, Dest);
      end;

    vfReplace:  { [v128 Scalar] -> [v128], lane in Imm }
      begin
        ReadLane(Sig.Dim);
        ScalarTy := MakeNumValueType(Sig.Scalar);
        RegB := PopValExpect(ScalarTy).Reg;
        RegA := PopValExpect(VecTy).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, RegA, RegB, Int64(Lane));
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfLoad:  { [at] -> [v128], memarg }
      begin
        ReadVecMemory;
        AddrReg := PopValExpect(AddrValType(Mem.Limits.AddrType)).Reg;
        if Emitting then
        begin
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, AddrReg, MemIdx, Int64(StaticOffset));
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfStore:  { [at v128] -> [], memarg }
      begin
        ReadVecMemory;
        ValReg := PopValExpect(VecTy).Reg;
        AddrReg := PopValExpect(AddrValType(Mem.Limits.AddrType)).Reg;
        if Emitting then
          Emit(Op, ValReg, AddrReg, MemIdx, Int64(StaticOffset));
      end;

    vfLoadLane:  { [at v128] -> [v128], memarg + lane }
      begin
        ReadVecMemory;
        ReadLane(Sig.Dim);
        RegB := PopValExpect(VecTy).Reg;   { the source vector, on top }
        AddrReg := PopValExpect(AddrValType(Mem.Limits.AddrType)).Reg;
        if Emitting then
        begin
          AuxIdx := IrAppendAuxLaneMemArgGrowing(FFn.AuxU32, FAuxCount,
            MemIdx, StaticOffset, Lane);
          Dest := AllocTemp(VecTy);
          Emit(Op, Dest, AddrReg, RegB, Int64(AuxIdx));
        end
        else
          Dest := IR_NO_REG;
        PushVal(VecTy, Dest);
      end;

    vfStoreLane:  { [at v128] -> [], memarg + lane }
      begin
        ReadVecMemory;
        ReadLane(Sig.Dim);
        ValReg := PopValExpect(VecTy).Reg;
        AddrReg := PopValExpect(AddrValType(Mem.Limits.AddrType)).Reg;
        if Emitting then
        begin
          AuxIdx := IrAppendAuxLaneMemArgGrowing(FFn.AuxU32, FAuxCount,
            MemIdx, StaticOffset, Lane);
          Emit(Op, ValReg, AddrReg, IR_NO_REG, Int64(AuxIdx));
        end;
      end;
  end;
end;

procedure TBodyWalker.Prefixed(const APrefix: Byte;
  const AOffset: NativeUInt);
var
  Sub: UInt32;
  Operand, ResultType: TWasmValueType;
  Sig: TNumSig;
  RegA, Dest: UInt32;
begin
  Sub := FReader.ReadU32;

  case APrefix of
    $FB:
      case Sub of
        0..5: HandleStructOp(Sub, AOffset);
        6..19: HandleArrayOp(Sub, AOffset);
        20..23: HandleCast(Sub);
        24: HandleBrOnCast(False, AOffset);
        25: HandleBrOnCast(True, AOffset);
        26..30: HandleI31Extern(Sub);
      else
        DecErr(Format('unknown $FB subopcode %u at offset %u',
          [Sub, AOffset]));
      end;

    $FC:
      begin
        if Sub <= 7 then
        begin
          Sig := TRUNC_SAT_SIG[Sub];
          Operand := MakeNumValueType(Sig.Operand);
          ResultType := MakeNumValueType(Sig.ResultType);
          RegA := PopValExpect(Operand).Reg;
          if Emitting then
          begin
            Dest := AllocTemp(ResultType);
            Emit(TWasmIrOp(Ord(iroI32TruncSatF32S) + Integer(Sub)), Dest,
              RegA, IR_NO_REG, 0);
          end
          else
            Dest := IR_NO_REG;
          PushVal(ResultType, Dest);
          Exit;
        end;
        if Sub > 17 then
          DecErr(Format('unknown $FC subopcode %u at offset %u',
            [Sub, AOffset]));
        if Sub <= 11 then
          HandleBulkMemory(Sub, AOffset)
        else
          HandleBulkTable(Sub, AOffset);
      end;
  else
    { $FD. The assigned set is the same non-contiguous one
      Wasm.Decoder.Expr spells out from the pinned grammar; an UNASSIGNED
      subopcode stays a DECODE error, exactly as before — that
      malformed/invalid split is what the conformance suite asserts and
      Track G does not disturb it. }
    case Sub of
      0..153, 155..161, 163, 164, 167..174, 177, 181..186, 188..193,
      195, 196, 199..206, 209, 213..225, 227..237, 239..275:
        HandleVector(Sub, AOffset);
    else
      DecErr(Format('unknown $FD subopcode %u at offset %u',
        [Sub, AOffset]));
    end;
  end;
end;

{ --- setup and the main loop ---------------------------------------------- }

procedure TBodyWalker.Setup(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
  const ASpaces: TWasmIndexSpaces);
var
  Ft: TWasmFuncType;
  I, G, N: Integer;
  C: UInt32;
  Total: UInt64;
  MergeRegs: TWasmRegList;
  CodeSectionIndex: Integer;
  BodyEnd: NativeUInt;
begin
  FModule := AModule;
  FTypes := AContext;
  { Read, never rebuilt: BuildIndexSpaces ran once for the whole module
    (see TWasmIndexSpaces). }
  FSpaces := ASpaces;

  Ft := FuncTypeAt(ATypeIndex);
  FReturnTypes := CopyValTypes(Ft.Results);

  { Locals: parameters, then the declared locals run-length expanded.

    SUMMED WIDE, and the width is the point: the code section decoder
    already rejected an expanded sequence above `syntax-list`'s 2^32-1
    (that bound is grammar, hence malformed), but 2^32-1 registers is
    not a number this engine can allocate — SetLength takes an Integer
    and every local becomes a register. So the sum is accumulated in a
    UInt64, which cannot wrap where a 32-bit accumulator would, and
    compared against what an Integer-indexed register file can hold. The
    refusal is neither malformed nor ill-typed; see
    MSG_LOCALS_IMPLEMENTATION_LIMIT. }
  Total := UInt64(Length(Ft.Params));
  for G := 0 to High(AEntry.Locals) do
    Inc(Total, UInt64(AEntry.Locals[G].Count));
  { The return register block is allocated on top of the locals, so the
    bound leaves room for it rather than being High(Integer) exactly. }
  if Total > UInt64(High(Integer) - Length(FReturnTypes)) then
    ValErr(MSG_LOCALS_IMPLEMENTATION_LIMIT,
      Format('function body at offset %u declares %s local(s)',
        [AEntry.Body.Offset, IntToStr(Total)]));

  SetLength(FLocalTypes, Integer(Total));
  SetLength(FLocalsInit, Integer(Total));
  for I := 0 to High(Ft.Params) do
  begin
    FLocalTypes[I] := Ft.Params[I];
    FLocalsInit[I] := True;
  end;
  N := Length(Ft.Params);
  for G := 0 to High(AEntry.Locals) do
  begin
    { `valid-local`: a local is classified by its value type, and a
      value type is only valid when a concrete heap type it names is
      defined. The code section decoder READ this type but had no type
      space to check it against, so `(local (ref null 5))` in a module
      with one type reaches here unvalidated — a wrong ACCEPTANCE if it
      is not checked. Checked once per GROUP rather than per expanded
      local: the type is the same for the whole run. }
    CheckValType(AEntry.Locals[G].ValueType);
    C := 0;
    while C < AEntry.Locals[G].Count do
    begin
      FLocalTypes[N] := AEntry.Locals[G].ValueType;
      { A non-defaultable local — a non-nullable reference — starts
        uninitialized (`valid-local`). Its REGISTER exists regardless;
        only reads are gated. }
      FLocalsInit[N] := IsDefaultable(AEntry.Locals[G].ValueType);
      Inc(N);
      Inc(C);
    end;
  end;

  { Registers: params, locals, the return block, then temporaries.
    FRegCount is a SLOT count, not a value count (SIMD design §1.4): a
    v128 local takes two even-aligned slots, so `register i = local i` no
    longer holds and FLocalReg records each local's low register. }
  FRegCount := 0;
  FFn.RegTypes := nil;
  SetLength(FLocalReg, Integer(Total));
  for I := 0 to Integer(Total) - 1 do
    FLocalReg[I] := IrAllocReg(FFn.RegTypes, FRegCount, FLocalTypes[I]);
  { The return block is the first free slot after the locals, UNLESS the
    first result is a v128 whose even-alignment inserts a pad — the
    interpreter reads results from [ReturnRegBase .. +ResultCount)
    (Wasm.Interp), so ReturnRegBase must be the first result's register,
    i.e. MergeRegs[0], not the pre-pad slot. Void keeps the first free
    slot (no result is read there). }
  FFn.ReturnRegBase := UInt32(FRegCount);
  SetLength(MergeRegs, Length(FReturnTypes));
  for I := 0 to High(FReturnTypes) do
    MergeRegs[I] := IrAllocReg(FFn.RegTypes, FRegCount, FReturnTypes[I]);
  if Length(MergeRegs) > 0 then
    FFn.ReturnRegBase := MergeRegs[0];

  FFn.TypeIndex := ATypeIndex;
  FFn.CanonTypeId := FTypes.CanonIdOf(ATypeIndex);
  FFn.ParamCount := UInt32(Length(Ft.Params));
  FFn.LocalCount := UInt32(Total - UInt64(Length(Ft.Params)));
  FFn.ResultCount := UInt32(Length(FReturnTypes));
  { A tier maps a wasm local index back to its register through this copy
    (Wasm.Ir's TWasmIrFunction.LocalRegs); length = ParamCount +
    LocalCount, one entry per wasm local. }
  SetLength(FFn.LocalRegs, Integer(Total));
  for I := 0 to Integer(Total) - 1 do
    FFn.LocalRegs[I] := FLocalReg[I];
  { A tier maps a wasm result index back to its register through this copy
    (Wasm.Ir's TWasmIrFunction.ResultRegs). The return block is MergeRegs,
    allocated pad-aware, so ResultRegs[i] is result i's low slot and lets the
    result marshaling skip any even-alignment pad rather than assuming the
    results form a contiguous run from ReturnRegBase. }
  SetLength(FFn.ResultRegs, Length(FReturnTypes));
  for I := 0 to High(FReturnTypes) do
    FFn.ResultRegs[I] := MergeRegs[I];
  FFn.SourceOffset := AEntry.Body.Offset;
  FFn.Code := nil;
  FFn.AuxU32 := nil;
  FFn.EntryZeroRegs := nil;
  FFn.AuxRefTypes := nil;
  FFn.Handlers := nil;
  FFn.HandlerClauses := nil;
  FCodeCount := 0;
  FAuxCount := 0;

  FVals := nil;
  FValCount := 0;
  FInits := nil;
  FInitCount := 0;
  FCtrls := nil;
  FCtrlCount := 0;
  FDeadCount := 0;

  { ValidateFunctionBody is PUBLIC API and AEntry may come from anywhere,
    so the span is checked against the buffer before it is pointed at.
    The zero-size case is separate and comes first: an expr is at least
    its terminating `end` byte (`binary-code`, and Track A's decoder
    rejects an empty body for the same reason), and @ABytes[Offset] with
    Offset = Length(ABytes) would index one past the end of the array
    before the reader ever bounded anything. Wasm.Validator.&Const's
    Init guards its span the same way. }
  if AEntry.Body.Size = 0 then
    DecErr(Format('function body at offset %u has no bytes; an expr is '
      + 'at least its terminating `end`', [AEntry.Body.Offset]));
  if (AEntry.Body.Offset > NativeUInt(Length(ABytes)))
    or (AEntry.Body.Size
      > NativeUInt(Length(ABytes)) - AEntry.Body.Offset) then
    DecErr(Format('function body span [%u, %u) runs past the module '
      + 'buffer (%d byte(s))',
      [AEntry.Body.Offset, AEntry.Body.Offset + AEntry.Body.Size,
       Length(ABytes)]));

  FBase := AEntry.Body.Offset;
  FBodySize := AEntry.Body.Size;
  BodyEnd := FBase + FBodySize;
  FCodeSectionEnd := BodyEnd;
  CodeSectionIndex := AModule.IndexOfSection(wsCode);
  if CodeSectionIndex >= 0 then
    FCodeSectionEnd := AModule[CodeSectionIndex].BodyOffset
      + AModule[CodeSectionIndex].BodySize;
  FHasByteAfterBody := BodyEnd < NativeUInt(Length(ABytes));
  if FHasByteAfterBody then
    FByteAfterBody := ABytes[BodyEnd]
  else
    FByteAfterBody := 0;
  FReader.InitSpanFromBytes(ABytes, AEntry.Body.Offset, AEntry.Body.Size);
  { A function body is one of the two things upstream means by "section
    or function": running off its end reports as such, not as running off
    the end of the module. }
  FReader.Context := wrcSection;

  { The function body is the outermost block: its label is the function's
    result types and its merge registers ARE the return register block,
    so `return` and a branch to the outermost depth are the same thing. }
  PushCtrl(wctFuncBody, nil, FReturnTypes, MergeRegs, nil);
end;

function TBodyWalker.Run: TWasmIrFunction;
var
  OpOffset: NativeUInt;
  Op: Byte;
  Done: Boolean;
  Dest: UInt32;
  Bits: Int64;
  I: Integer;
begin
  Done := False;
  while not Done do
  begin
    { The reference decoder reads the expression before checking code and
      section sizes (`binary-code`, `binary-section`). This fused walk stays
      bounded, so reproduce that structural classification from the encoded
      extents before the reader reports generic truncation. A true physical
      EOF deliberately falls through and remains `unexpected end of section
      or function`. }
    if FReader.Eof then
    begin
      if FBase + FBodySize < FCodeSectionEnd then
        DecErr(Format('%s: function body at offset %u',
          [MSG_END_OPCODE_EXPECTED, FBase]));
      if (FBase + FBodySize = FCodeSectionEnd) and FHasByteAfterBody
        and (FByteAfterBody = $0B) then
        DecErr(Format('%s: function body at offset %u terminates outside '
          + 'the declared code section', [MSG_SECTION_SIZE_MISMATCH, FBase]));
    end;
    OpOffset := FBase + FReader.Position;
    Op := FReader.ReadByte;

    case Op of
      { --- control ---------------------------------------------------- }
      $00:
        begin
          if Emitting then
            Emit(iroUnreachable, IR_NO_REG, IR_NO_REG, IR_NO_REG, 0);
          MarkUnreachable;
        end;
      $01:; { nop emits nothing }
      $02: HandleBlock(wctBlock);
      $03: HandleBlock(wctLoop);
      $04: HandleBlock(wctIf);
      $05: HandleElse(False, OpOffset);
      $0B: Done := HandleEnd;
      $0C: HandleBr;
      $0D: HandleBrIf;
      $0E: HandleBrTable;
      $0F: HandleReturn;
      $10: HandleCall(False);
      $11: HandleCallIndirect(False);
      $12: HandleCall(True);
      $13: HandleCallIndirect(True);
      $14: HandleCallRef(False);
      $15: HandleCallRef(True);

      { --- parametric ------------------------------------------------- }
      $1A: PopVal;
      $1B: HandleSelect(False);
      $1C: HandleSelect(True);

      { --- variable --------------------------------------------------- }
      $20: HandleLocalGet;
      $21: HandleLocalSet(False);
      $22: HandleLocalSet(True);

      { --- numeric constants ------------------------------------------ }
      $41:
        begin
          Bits := Int64(FReader.ReadI32);
          if Emitting then
          begin
            Dest := AllocTemp(MakeNumValueType(wntI32));
            Emit(iroI32Const, Dest, IR_NO_REG, IR_NO_REG, Bits);
          end
          else
            Dest := IR_NO_REG;
          PushVal(MakeNumValueType(wntI32), Dest);
        end;
      $42:
        begin
          Bits := FReader.ReadI64;
          if Emitting then
          begin
            Dest := AllocTemp(MakeNumValueType(wntI64));
            Emit(iroI64Const, Dest, IR_NO_REG, IR_NO_REG, Bits);
          end
          else
            Dest := IR_NO_REG;
          PushVal(MakeNumValueType(wntI64), Dest);
        end;
      { Floats are stored as BIT PATTERNS: NaN payloads are observable
        and a round-trip through an FPC float type is not required to
        preserve them, so the four/eight little-endian bytes are read as
        an integer and never converted. }
      $43:
        begin
          Bits := Int64(FReader.ReadFixedU32);
          if Emitting then
          begin
            Dest := AllocTemp(MakeNumValueType(wntF32));
            Emit(iroF32Const, Dest, IR_NO_REG, IR_NO_REG, Bits);
          end
          else
            Dest := IR_NO_REG;
          PushVal(MakeNumValueType(wntF32), Dest);
        end;
      $44:
        begin
          Bits := Int64(FReader.ReadFixedU32);
          Bits := Bits or (Int64(FReader.ReadFixedU32) shl 32);
          if Emitting then
          begin
            Dest := AllocTemp(MakeNumValueType(wntF64));
            Emit(iroF64Const, Dest, IR_NO_REG, IR_NO_REG, Bits);
          end
          else
            Dest := IR_NO_REG;
          PushVal(MakeNumValueType(wntF64), Dest);
        end;

      { --- the whole numeric family, table-driven --------------------- }
      $45..$C4:
        HandleNumeric(Op, NUM_SIG[Op],
          TWasmIrOp(Ord(iroI32Eqz) + Integer(Op) - $45));

      { --- variable: globals ------------------------------------------ }
      $23: HandleGlobal(False, OpOffset);
      $24: HandleGlobal(True, OpOffset);

      { --- table ------------------------------------------------------ }
      $25: HandleTableGet(OpOffset);
      $26: HandleTableSet(OpOffset);

      { --- memory loads, stores, size and grow ------------------------ }
      $28..$3E: HandleLoadStore(Op, OpOffset);
      $3F: HandleMemorySizeGrow(False, OpOffset);
      $40: HandleMemorySizeGrow(True, OpOffset);

      { --- reference -------------------------------------------------- }
      $D0: HandleRefNull;
      $D1: HandleRefIsNull;
      $D2: HandleRefFunc(OpOffset);
      $D3: HandleRefEq;
      $D4: HandleRefAsNonNull;
      $D5: HandleBrOnNull(False);
      $D6: HandleBrOnNull(True);

      { --- exception handling ----------------------------------------- }
      $08: HandleThrow(OpOffset);
      $0A: HandleThrowRef;
      $1F: HandleTryTable(OpOffset);

      { --- prefixed spaces -------------------------------------------- }
      $FB, $FC, $FD:
        Prefixed(Op, OpOffset);
    else
      DecErr(IllegalOpcodeMessage(Op, OpOffset));
    end;
  end;

  { The body's `end` must be the span's last byte. `binary-code` bounds a
    code entry by a size prefix, and the code section decoder deliberately
    leaves this to the fused walk — this is the FIRST structural pass over
    a function body, so if the check is not made here it is made nowhere. }
  if FReader.Position <> FBodySize then
    DecErr(Format('%s: function body at offset %u ends %u byte(s) before '
      + 'its declared extent', [MSG_SECTION_SIZE_MISMATCH, FBase,
      FBodySize - FReader.Position]));

  { The three geometrically grown arrays are trimmed HERE, in the same
    procedure that finished building them (AWasm.Ir's building section).
    Until this point Length() on any of them is the capacity, not the
    length, and no consumer may read them. }
  { RegisterCount is rounded up to EVEN (SIMD design §1.5): a frame's Base
    is the running sum of the callers' RegisterCounts, so keeping every
    count even keeps every Base even by induction from Base = 0, which is
    what lets a v128's even low slot land 16-byte aligned in the frame.
    The pad is a dead, non-reference i32 filler — allocated through
    IrAllocReg so RegTypes stays in step with the count and RefRegBits
    (computed from RegTypes below) stays clear over it. }
  if Odd(FRegCount) then
    IrAllocReg(FFn.RegTypes, FRegCount, MakeI32);
  IrTrimCode(FFn.Code, FCodeCount);
  IrTrimRegTypes(FFn.RegTypes, FRegCount);
  IrTrimAux(FFn.AuxU32, FAuxCount);
  FFn.RegisterCount := UInt32(FRegCount);
  IrComputeRefRegBits(FFn);
  IrComputeEntryZeroRegs(FFn);

  { Nothing below relies on it, but a broken walk is much easier to find
    from here than from a tier: the invariant is one trailing iroReturn. }
  I := Length(FFn.Code);
  if (I = 0) or (FFn.Code[I - 1].Op <> iroReturn) then
    raise EWasmValidationError.Create(
      'internal: function IR does not end with a return');

  Result := FFn;
end;

{ --- public entry points -------------------------------------------------- }

function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
  const ASpaces: TWasmIndexSpaces): TWasmIrFunction;
var
  Walker: TBodyWalker;
begin
  Walker.Setup(AModule, AContext, ABytes, ATypeIndex, AEntry, ASpaces);
  Result := Walker.Run;
end;

{ The three standalone forms, each building what the caller did not
  supply. They are O(module) per BODY, which is exactly why the overload
  above exists — a module-level walk must not use these. }
function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
  const AFuncTypes: TWasmFuncTypeIndices;
  const ADeclaredFuncs: TWasmDeclaredFuncs): TWasmIrFunction;
var
  Spaces: TWasmIndexSpaces;
begin
  BuildIndexSpaces(AModule, Spaces);
  Spaces.FuncTypes := AFuncTypes;
  Spaces.DeclaredFuncs := ADeclaredFuncs;
  Result := ValidateFunctionBody(AModule, AContext, ABytes, ATypeIndex,
    AEntry, Spaces);
end;

function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32; const AEntry: TWasmCodeEntry;
  const AFuncTypes: TWasmFuncTypeIndices): TWasmIrFunction;
var
  Spaces: TWasmIndexSpaces;
begin
  BuildIndexSpaces(AModule, Spaces);
  Spaces.FuncTypes := AFuncTypes;
  Result := ValidateFunctionBody(AModule, AContext, ABytes, ATypeIndex,
    AEntry, Spaces);
end;

function ValidateFunctionBody(const AModule: TWasmModule;
  const AContext: TWasmTypeContext; const ABytes: TWasmBytes;
  const ATypeIndex: UInt32;
  const AEntry: TWasmCodeEntry): TWasmIrFunction;
var
  Spaces: TWasmIndexSpaces;
begin
  BuildIndexSpaces(AModule, Spaces);
  Result := ValidateFunctionBody(AModule, AContext, ABytes, ATypeIndex,
    AEntry, Spaces);
end;

initialization
  BuildVecOpTable;

end.
