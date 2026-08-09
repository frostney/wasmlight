{ Wasm.Wat.Assembler — the `wat` text-format assembler (Track C;
  .agent/design/wat-assembler.md §2, §3, §6).

  The assembler lowers module TEXT to the binary encoding and hands the bytes
  to the shipped DecodeModule -> ValidateModule pipeline (§1): it produces
  BYTES, never the model and never IR. Text-level malformedness surfaces here
  as a text error with upstream's canonical prefixes; binary-level
  malformedness cannot arise from a correct assembler (INV-1).

  MODULE FIELDS. Every field encodes: types (rec/sub/final/struct/array with
  field names), imports and exports including the inline abbreviations
  (§2(c.2)), memories, tables, globals, tags, elem and data with the sugar
  forms (§2(c.5)) — including the desugared inline elem/data segments —
  start, and funcs with param/result/local merging. Const expressions
  (global/elem/data init) run the same instruction path as function bodies.

  THE INSTRUCTION GRAMMAR is complete and data-driven: dispatch keys on the
  immediate SHAPE recorded in Wasm.Wat.Opcodes, never on a hard-coded opcode.
  EmitImmediatesBody handles every shape — the numeric no-immediate ops, the
  `*.const` family, `local.*`/`global.*`, `call`/`ref.func`, memarg
  loads/stores, `br_table`, `call_indirect`, `select` (bare and result-typed),
  `ref.test`/`ref.cast`/`br_on_cast`, the $FB GC families, and `try_table`
  with its catch vector. Block structures come in both the flat
  `block`/`loop`/`if … end` and the FOLDED `(block …)`/`(if …)` spellings
  (EmitFoldedBlock), each carrying labels + a blocktype that may be a
  multi-value typeuse. A mnemonic with no row is the reserved-token case: it
  raises `unknown operator <mnemonic>`, loud and never silently wrong.

  STAGED, and the ONE thing not encoded: the $FD SIMD vector space is Track G
  and has no rows in Wasm.Wat.Opcodes, so a v128 mnemonic takes the same
  unknown-operator path rather than mis-assembling.

  THE §7 RISK — implicit typeuse ordering — is resolved in two sub-passes:
  sub-pass 1a collects every EXPLICIT type (so they own indices 0..E-1 in
  textual order), then sub-pass 1b walks the fields in appearance order and
  interns each implicit typeuse AFTER the explicit block, reusing the smallest
  matching singular-final-func or appending a fresh type. That is exactly what
  func.wast:422-433 pins. See Wasm.Wat.Names.InternFuncType.

  Spec citations against wasm-mcp pinned core spec, commit
  d7b37e4170d8315f2f1283aed4e8076591a9a333. }
unit Wasm.Wat.Assembler;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Wat.Emit,
  Wasm.Wat.Lexer,
  Wasm.Wat.Names,
  Wasm.Wat.Numbers,
  Wasm.Wat.Opcodes;

const
  { MSG_UNEXPECTED_TOKEN and MSG_UNKNOWN_OPERATOR are the two prefixes this
    unit shares with Wasm.Wat.Numbers; they live in Wasm.Core (reached through
    this unit's uses) so the corpus-matched spelling has one home. The prefixes
    below are raised only here, so they stay local. }
  MSG_MULTIPLE_START    = 'multiple start sections';
  MSG_IMPORT_AFTER      = 'import after ';
  { The corpus asks for both `alignment` (92) and `alignment must be a power of
    two` (22); the match is a prefix match, so the long spelling satisfies both
    (§4). align=0/align=7 land here (align.wast:26-37). }
  MSG_ALIGNMENT         = 'alignment must be a power of two';

{ Primary entry point: ASource is the module's source BYTES (§2a — UTF-8
  validity is a rule the assembler enforces, so it must be handed bytes).
  Accepts a `(module …)` form or a bare field sequence (the shape a
  `(module quote …)` payload takes). }
function AssembleWat(const ASource: TWasmBytes): TWasmBytes;

{ Convenience for .wat text and unit tests. }
function AssembleWatText(const AText: string): TWasmBytes;

{ The `(module quote …)` payload — already the concatenated, escape-decoded
  string bytes — is itself module text, so this assembles it. Kept distinct so
  the runner's two module forms have two named doors even though they share a
  body (§2a, §5). }
function AssembleQuote(const APayload: TWasmBytes): TWasmBytes;

implementation

type
  { --- intermediate declarations, filled in pass 1, emitted in pass 2 ----- }

  TImpDecl = record
    ModuleName: string;
    Name: string;
    Kind: TWasmExternKind;
    Id: string;
    TypeIndex: UInt32;
    Table: TWasmTableType;
    Mem: TWasmMemType;
    Global: TWasmGlobalType;
    InlineExports: array of string;
    FinalIndex: Integer;
  end;

  TFuncDecl = record
    Id: string;
    TypeIndex: UInt32;
    ParamNames: array of string;
    ParamCount: Integer;
    BodyStart: Integer;   { first token after the typeuse }
    BodyEnd: Integer;     { the func field's closing ')' token index }
    InlineExports: array of string;
    FinalIndex: Integer;
  end;

  TTableDecl = record
    Id: string;
    TableType: TWasmTableType;
    InlineExports: array of string;
    FinalIndex: Integer;
  end;

  TMemDecl = record
    Id: string;
    MemType: TWasmMemType;
    InlineExports: array of string;
    FinalIndex: Integer;
  end;

  TGlobalDecl = record
    Id: string;
    GlobalType: TWasmGlobalType;
    InitStart: Integer;
    InitEnd: Integer;
    InlineExports: array of string;
    FinalIndex: Integer;
  end;

  TTagDecl = record
    Id: string;
    TypeIndex: UInt32;
    InlineExports: array of string;
    FinalIndex: Integer;
  end;

  TExpDecl = record
    Name: string;
    Kind: TWasmExternKind;
    { When Resolved, Index is final; otherwise RefTok points at the operand to
      resolve at emit time. }
    Resolved: Boolean;
    Index: UInt32;
    RefTok: Integer;
  end;

  { elem/data are captured as their whole field token range and re-parsed at
    emit, when every module index is bound (offsets and funcidx lists need
    that). }
  TSegDecl = record
    FieldStart: Integer;
  end;

  { An inline `(table T (elem …))` desugars to a standalone ACTIVE element
    segment at offset (i32.const 0) over this table (§2(c.5);
    call_indirect.wast:626, elem.wast:84). The element list is captured as a
    token range and re-parsed at emit, so its funcidx forward references
    resolve like any other. }
  TInlineElemDecl = record
    TableDeclIndex: Integer;   { index into FTables }
    ListStart, ListEnd: Integer;
    ElemCount: Integer;
    UsesExprs: Boolean;
    RefType: TWasmRefType;
  end;

  { An inline `(memory (data …))` desugars to a standalone ACTIVE data segment
    at offset (i32.const 0) over this memory (§2(c.5); bulk.wast:58). The
    payload is raw string bytes with no forward references, so it is captured
    at declare time. }
  TInlineDataDecl = record
    MemDeclIndex: Integer;     { index into FMems }
    Payload: TWasmBytes;
  end;

  TWatAssembler = class
  private
    FToks: array of TWatToken;
    FPos: Integer;
    FNames: TWatNames;

    FImports: array of TImpDecl;
    FFuncs: array of TFuncDecl;
    FTables: array of TTableDecl;
    FMems: array of TMemDecl;
    FGlobals: array of TGlobalDecl;
    FTags: array of TTagDecl;
    FExports: array of TExpDecl;
    FElems: array of TSegDecl;
    FDatas: array of TSegDecl;
    FInlineElems: array of TInlineElemDecl;
    FInlineDatas: array of TInlineDataDecl;

    FHasStart: Boolean;
    FStartTok: Integer;
    FFirstDefWord: string;   { for `import after <kind>` }
    FUsesDataIndex: Boolean; { a data index appears in code => data-count needed }

    FFieldsStart: Integer;

    { --- token access ------------------------------------------------- }
    function Cur: TWatToken;
    function At(const AOffset: Integer): TWatToken;
    function PeekKind: TWatTokenKind;
    procedure Advance;
    function IsListHead(const AKeyword: string): Boolean;
    function IsKeyword(const AKeyword: string): Boolean;
    procedure ExpectLParen;
    procedure ExpectRParen;
    procedure ExpectKeyword(const AKeyword: string);
    procedure SkipBalanced;
    function CaptureClauseContent(out AStart, AEnd: Integer): Boolean;

    procedure RaiseText(const AMessage: string);
    procedure RaiseUnexpected;
    procedure RaiseUnknownOperator(const AToken: string);

    { --- primitive parsers -------------------------------------------- }
    function TokenName(const AToken: TWatToken): string;
    function ParseValueType: TWasmValueType;
    function ParseHeapType: TWasmHeapType;
    function ParseRefTypeParen: TWasmRefType;
    function ParseRefType: TWasmRefType;
    function ParseStorageType: TWasmStorageType;
    function ParseFieldType: TWasmFieldType;
    function ParseLimitsInline: TWasmLimits;
    function ParseTableTypeInline: TWasmTableType;
    function ParseGlobalTypeInline: TWasmGlobalType;
    procedure ParseParams(var AParams: TArray<TWasmValueType>;
      var ANames: TArray<string>; const AAllowNames: Boolean = True);
    procedure ParseResults(var AResults: TArray<TWasmValueType>);
    function ReadIndex(const ASpace: TWatSpace): UInt32;
    function ReadLocalIndex: UInt32;
    function ReadLabelIndex: UInt32;
    function ReadTypeIndex: UInt32;
    function FindFieldClose(const AFrom: Integer): Integer;

    { --- types (pass 1a) ---------------------------------------------- }
    procedure ParseCompType(out AComp: TWasmCompType;
      out AFieldNames: TArray<string>);
    procedure ParseSubType(out ASub: TWasmSubType;
      out AFieldNames: TArray<string>);
    procedure PreBindTypeField;
    procedure ParseTypeField;

    { --- typeuse (pass 1b) -------------------------------------------- }
    function ParseTypeUse(out AParamNames: TArray<string>;
      out AParamCount: Integer): UInt32;
    procedure ParseTypeUseInstr(out AHasType: Boolean; out ATypeIdx: UInt32;
      out AParams, AResults: TArray<TWasmValueType>);

    { --- field declaration (pass 1b) ---------------------------------- }
    function ReadString(const ARequireUtf8: Boolean): string;
    procedure ParseInlineExports(var AExports: TArray<string>);
    function TryParseInlineImport(out AModule, AName: string): Boolean;
    procedure NoteDefinition(const AWord: string);
    procedure DeclareImportField;
    procedure DeclareFuncField;
    procedure DeclareTableField;
    procedure DeclareInlineTableElem(var ATable: TTableDecl);
    procedure DeclareMemField;
    procedure DeclareInlineMemData(var AMem: TMemDecl);
    procedure DeclareGlobalField;
    procedure DeclareTagField;
    procedure DeclareExportField;
    procedure DeclareStartField;
    procedure DeclareSegField(const AIsData: Boolean);
    procedure DeclareField;

    procedure AssignIndices;
    procedure AssignSpace(const ASpace: TWatSpace);

    { --- instruction / expr emission (pass 2) ------------------------- }
    procedure EmitOpcode(var AOut: TWasmWriter; const AInfo: TWasmOpcodeInfo);
    function TakeNumberText: string;
    function ReadOptionalIndex(const ASpace: TWatSpace;
      const ADefault: UInt32): UInt32;
    function CurIsIndexToken: Boolean;
    procedure EmitMemArg(var AOut: TWasmWriter; const AInfo: TWasmOpcodeInfo);
    procedure EmitBrTable(var AOut: TWasmWriter);
    procedure EmitCallIndirect(var AOut: TWasmWriter);
    procedure EmitCatchVector(var AOut: TWasmWriter);
    procedure EmitTypeField(var AOut: TWasmWriter);
    procedure EmitSelect(var AOut: TWasmWriter; const AInfo: TWasmOpcodeInfo);
    procedure EmitRefTestCast(var AOut: TWasmWriter;
      const AInfo: TWasmOpcodeInfo);
    procedure EmitBrOnCast(var AOut: TWasmWriter; const AInfo: TWasmOpcodeInfo);
    procedure EmitImmediatesBody(var AOut: TWasmWriter;
      const AInfo: TWasmOpcodeInfo; const AMnemonic: string);
    procedure EmitOpcodeAndImmediates(var AOut: TWasmWriter;
      const AInfo: TWasmOpcodeInfo; const AMnemonic: string);
    procedure EmitBlockType(var AOut: TWasmWriter);
    procedure CheckLabelMatch(const AToken: TWatToken; const ABlockName: string);
    procedure EmitBlock(var AOut: TWasmWriter; const AMnemonic: string);
    procedure EmitTryTableFlat(var AOut: TWasmWriter);
    procedure EmitFoldedBlock(var AOut: TWasmWriter; const AMnemonic: string);
    procedure EmitFlatInstr(var AOut: TWasmWriter);
    procedure EmitFoldedInstr(var AOut: TWasmWriter);
    procedure EmitInstrSeq(var AOut: TWasmWriter; const AStopAtEnd: Boolean;
      const AEnd: Integer);
    procedure EmitConstExpr(var AOut: TWasmWriter;
      const AStart, AEnd: Integer);

    { --- section builders (pass 2) ------------------------------------ }
    procedure WriteName(var AOut: TWasmWriter; const AName: string);
    procedure EmitFuncLocalsAndBody(const AFunc: TFuncDecl;
      var AEntry: TWasmWriter);
    procedure EmitElemSegment(const AStart: Integer; var AOut: TWasmWriter);
    procedure EmitDataSegment(const AStart: Integer; var AOut: TWasmWriter);
    procedure WriteZeroOffsetExpr(var AOut: TWasmWriter);
    procedure EmitInlineElemSegment(const ADecl: TInlineElemDecl;
      var AOut: TWasmWriter);
    procedure EmitInlineDataSegment(const ADecl: TInlineDataDecl;
      var AOut: TWasmWriter);
    procedure CollectExports(var AList: TArray<TExpDecl>);
    function BuildModule: TWasmBytes;
  public
    constructor Create;
    destructor Destroy; override;
    function Run(const ASource: TWasmBytes): TWasmBytes;
  end;

{ --- keyword classification (unit-level, stateless) --------------------- }

function TryNumOrVecKeyword(const AKw: string;
  out AType: TWasmValueType): Boolean;
begin
  Result := True;
  if AKw = 'i32' then AType := MakeNumValueType(wntI32)
  else if AKw = 'i64' then AType := MakeNumValueType(wntI64)
  else if AKw = 'f32' then AType := MakeNumValueType(wntF32)
  else if AKw = 'f64' then AType := MakeNumValueType(wntF64)
  else if AKw = 'v128' then AType := MakeVecValueType
  else
    Result := False;
end;

function TryAbsHeapKeyword(const AKw: string;
  out AAbs: TWasmAbsHeapType): Boolean;
begin
  Result := True;
  if AKw = 'func' then AAbs := wahFunc
  else if AKw = 'extern' then AAbs := wahExtern
  else if AKw = 'any' then AAbs := wahAny
  else if AKw = 'eq' then AAbs := wahEq
  else if AKw = 'i31' then AAbs := wahI31
  else if AKw = 'struct' then AAbs := wahStruct
  else if AKw = 'array' then AAbs := wahArray
  else if AKw = 'none' then AAbs := wahNone
  else if AKw = 'nofunc' then AAbs := wahNoFunc
  else if AKw = 'noextern' then AAbs := wahNoExtern
  else if AKw = 'exn' then AAbs := wahExn
  else if AKw = 'noexn' then AAbs := wahNoExn
  else
    Result := False;
end;

function TryShorthandRefKeyword(const AKw: string;
  out ARef: TWasmRefType): Boolean;

  function R(const AAbs: TWasmAbsHeapType): TWasmRefType;
  begin
    Result := MakeRefType(True, MakeAbsHeapType(AAbs));
  end;

begin
  Result := True;
  if AKw = 'funcref' then ARef := R(wahFunc)
  else if AKw = 'externref' then ARef := R(wahExtern)
  else if AKw = 'anyref' then ARef := R(wahAny)
  else if AKw = 'eqref' then ARef := R(wahEq)
  else if AKw = 'i31ref' then ARef := R(wahI31)
  else if AKw = 'structref' then ARef := R(wahStruct)
  else if AKw = 'arrayref' then ARef := R(wahArray)
  else if AKw = 'nullref' then ARef := R(wahNone)
  else if AKw = 'nullfuncref' then ARef := R(wahNoFunc)
  else if AKw = 'nullexternref' then ARef := R(wahNoExtern)
  else if AKw = 'exnref' then ARef := R(wahExn)
  else if AKw = 'nullexnref' then ARef := R(wahNoExn)
  else
    Result := False;
end;

function IsRefTypeShorthand(const AKw: string): Boolean;
var
  Ref: TWasmRefType;
begin
  Result := TryShorthandRefKeyword(AKw, Ref);
end;

{ The keywords that head a STRUCTURAL clause (a typeuse or a local
  declaration), never an instruction. Meeting one where an instruction is
  expected is a misplaced clause — `unexpected token`, not `unknown operator`
  (§4; func.wast:937-953). In a valid module these are all consumed by the
  typeuse / local parsers before any instruction is read. }
function IsStructuralKeyword(const AKw: string): Boolean;
begin
  Result := (AKw = 'param') or (AKw = 'result') or (AKw = 'type')
    or (AKw = 'local')
    { try_table catch-clause keywords, valid only inside a try_table's catch
      vector; and the legacy exception keywords (Track H, unimplemented). Both
      are reserved by the grammar, so meeting them where an instruction is
      expected is `unexpected token`, not `unknown operator`
      (try_table.wast:366-371, legacy/try_catch.wast, legacy/try_delegate.wast). }
    or (AKw = 'catch') or (AKw = 'catch_ref') or (AKw = 'catch_all')
    or (AKw = 'catch_all_ref')
    or (AKw = 'try') or (AKw = 'delegate') or (AKw = 'rethrow');
end;

function TextStartsWith(const AWhole, APrefix: string): Boolean;
begin
  Result := (Length(AWhole) >= Length(APrefix))
    and (Copy(AWhole, 1, Length(APrefix)) = APrefix);
end;

{ --- byte/string helpers ------------------------------------------------ }

function BytesToStr(const ABytes: TWasmBytes): string;
var
  I: Integer;
begin
  SetLength(Result, Length(ABytes));
  for I := 0 to High(ABytes) do
    Result[I + 1] := Chr(ABytes[I]);
end;

{ --- TWatAssembler ------------------------------------------------------ }

constructor TWatAssembler.Create;
begin
  inherited Create;
  FNames := TWatNames.Create;
end;

destructor TWatAssembler.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

function TWatAssembler.Cur: TWatToken;
begin
  Result := FToks[FPos];
end;

function TWatAssembler.At(const AOffset: Integer): TWatToken;
begin
  if FPos + AOffset < Length(FToks) then
    Result := FToks[FPos + AOffset]
  else
    Result := FToks[High(FToks)];   { the trailing eof }
end;

function TWatAssembler.PeekKind: TWatTokenKind;
begin
  Result := FToks[FPos].Kind;
end;

procedure TWatAssembler.Advance;
begin
  if FToks[FPos].Kind <> wttEof then
    Inc(FPos);
end;

function TWatAssembler.IsListHead(const AKeyword: string): Boolean;
begin
  Result := (Cur.Kind = wttLParen) and (At(1).Kind = wttKeyword)
    and (At(1).Text = AKeyword);
end;

function TWatAssembler.IsKeyword(const AKeyword: string): Boolean;
begin
  Result := (Cur.Kind = wttKeyword) and (Cur.Text = AKeyword);
end;

procedure TWatAssembler.RaiseText(const AMessage: string);
begin
  raise EWasmTextError.Create(AMessage);
end;

procedure TWatAssembler.RaiseUnexpected;
begin
  { A RESERVED token is a longest-match run that is nothing the grammar names
    (`0drop`, `0$l`, `$"l"0`, `data"a"`, `"a"x`): it is an unknown operator
    WHEREVER it appears, never a misplaced-but-valid token. So any parse
    position that rejects the current token reports `unknown operator <tok>`
    for a reserved run and `unexpected token` only for a valid token out of
    place (§4; token.wast:7-299). }
  if Cur.Kind = wttReserved then
    RaiseUnknownOperator(Cur.Text)
  else
    RaiseText(MSG_UNEXPECTED_TOKEN);
end;

procedure TWatAssembler.RaiseUnknownOperator(const AToken: string);
begin
  RaiseText(MSG_UNKNOWN_OPERATOR + ' ' + AToken);
end;

procedure TWatAssembler.ExpectLParen;
begin
  if Cur.Kind <> wttLParen then
    RaiseUnexpected;
  Advance;
end;

procedure TWatAssembler.ExpectRParen;
begin
  if Cur.Kind <> wttRParen then
    RaiseUnexpected;
  Advance;
end;

procedure TWatAssembler.ExpectKeyword(const AKeyword: string);
begin
  if not IsKeyword(AKeyword) then
    RaiseUnexpected;
  Advance;
end;

procedure TWatAssembler.SkipBalanced;
var
  Depth: Integer;
begin
  { Assumes Cur = '('. Consumes a balanced '(' … ')' group. }
  Depth := 0;
  repeat
    case PeekKind of
      wttEof: RaiseUnexpected;
      wttLParen: Inc(Depth);
      wttRParen: Dec(Depth);
    end;
    Advance;
  until Depth = 0;
end;

function TWatAssembler.CaptureClauseContent(out AStart, AEnd: Integer): Boolean;
var
  Depth: Integer;
begin
  { Assumes the clause's '(' and head keyword have been consumed; captures the
    remaining content token range [AStart, AEnd) and consumes the closing ')'. }
  AStart := FPos;
  Depth := 1;
  while Depth > 0 do
  begin
    case PeekKind of
      wttEof: RaiseUnexpected;
      wttLParen: Inc(Depth);
      wttRParen:
        begin
          Dec(Depth);
          if Depth = 0 then
            Break;
        end;
    end;
    Advance;
  end;
  AEnd := FPos;      { at the closing ')' }
  Advance;           { consume it }
  Result := True;
end;

function TWatAssembler.TokenName(const AToken: TWatToken): string;
begin
  Result := BytesToStr(AToken.Bytes);
end;

{ --- value / reference / storage types ---------------------------------- }

function TWatAssembler.ParseHeapType: TWasmHeapType;
var
  Abs: TWasmAbsHeapType;
  Idx: Integer;
  Name: string;
begin
  case Cur.Kind of
    wttKeyword:
      begin
        if not TryAbsHeapKeyword(Cur.Text, Abs) then
          RaiseUnexpected;
        Advance;
        Result := MakeAbsHeapType(Abs);
      end;
    wttInteger:
      begin
        Result := MakeConcreteHeapType(UInt32(ParseIntLiteral(Cur.Text, 32)));
        Advance;
      end;
    wttIdentifier:
      begin
        Name := TokenName(Cur);
        Idx := FNames.LookupType(Name);
        if Idx < 0 then
          RaiseText(MSG_UNKNOWN_TYPE);
        Advance;
        Result := MakeConcreteHeapType(UInt32(Idx));
      end;
  else
    RaiseUnexpected;
  end;
end;

function TWatAssembler.ParseRefTypeParen: TWasmRefType;
var
  Nullable: Boolean;
  Heap: TWasmHeapType;
begin
  { Assumes Cur = '(' with head 'ref'. }
  ExpectLParen;
  ExpectKeyword('ref');
  Nullable := False;
  if IsKeyword('null') then
  begin
    Advance;
    Nullable := True;
  end;
  Heap := ParseHeapType;
  ExpectRParen;
  Result := MakeRefType(Nullable, Heap);
end;

function TWatAssembler.ParseValueType: TWasmValueType;
var
  NumVec: TWasmValueType;
  Ref: TWasmRefType;
begin
  case Cur.Kind of
    wttKeyword:
      begin
        if TryNumOrVecKeyword(Cur.Text, NumVec) then
        begin
          Advance;
          Exit(NumVec);
        end;
        if TryShorthandRefKeyword(Cur.Text, Ref) then
        begin
          Advance;
          Exit(MakeRefValueType(Ref));
        end;
        RaiseUnexpected;
      end;
    wttLParen:
      if At(1).Text = 'ref' then
        Exit(MakeRefValueType(ParseRefTypeParen))
      else
        RaiseUnexpected;
  else
    RaiseUnexpected;
  end;
end;

function TWatAssembler.ParseStorageType: TWasmStorageType;
begin
  if IsKeyword('i8') then
  begin
    Advance;
    Exit(MakePackedStorageType(wpkI8));
  end;
  if IsKeyword('i16') then
  begin
    Advance;
    Exit(MakePackedStorageType(wpkI16));
  end;
  Result := MakeValueStorageType(ParseValueType);
end;

function TWatAssembler.ParseFieldType: TWasmFieldType;
var
  Storage: TWasmStorageType;
begin
  if IsListHead('mut') then
  begin
    ExpectLParen;
    ExpectKeyword('mut');
    Storage := ParseStorageType;
    ExpectRParen;
    Exit(MakeFieldType(True, Storage));
  end;
  Storage := ParseStorageType;
  Result := MakeFieldType(False, Storage);
end;

function TWatAssembler.ParseRefType: TWasmRefType;
begin
  if (Cur.Kind = wttKeyword) and TryShorthandRefKeyword(Cur.Text, Result) then
  begin
    Advance;
    Exit;
  end;
  if (Cur.Kind = wttLParen) and (At(1).Text = 'ref') then
    Exit(ParseRefTypeParen);
  RaiseUnexpected;
end;

function TWatAssembler.ParseLimitsInline: TWasmLimits;
var
  Addr: TWasmAddrType;
  Min, Max: UInt64;
  HasMax: Boolean;
begin
  { text limits: addrtype? min max? — addrtype defaults to i32, min/max are
    u64 in the encoding regardless of address type. }
  Addr := watI32;
  if IsKeyword('i32') then
    Advance
  else if IsKeyword('i64') then
  begin
    Addr := watI64;
    Advance;
  end;
  if Cur.Kind <> wttInteger then
    RaiseUnexpected;
  Min := ParseIntLiteral(Cur.Text, 64);
  Advance;
  HasMax := False;
  Max := 0;
  if Cur.Kind = wttInteger then
  begin
    Max := ParseIntLiteral(Cur.Text, 64);
    Advance;
    HasMax := True;
  end;
  if HasMax then
    Result := MakeLimitsWithMax(Addr, Min, Max)
  else
    Result := MakeLimits(Addr, Min);
end;

function TWatAssembler.ParseTableTypeInline: TWasmTableType;
var
  Limits: TWasmLimits;
  Ref: TWasmRefType;
begin
  { tabletype text order: limits then reftype. }
  Limits := ParseLimitsInline;
  Ref := ParseRefType;
  Result := MakeTableType(Ref, Limits);
end;

function TWatAssembler.ParseGlobalTypeInline: TWasmGlobalType;
var
  VT: TWasmValueType;
begin
  if IsListHead('mut') then
  begin
    ExpectLParen;
    ExpectKeyword('mut');
    VT := ParseValueType;
    ExpectRParen;
    Exit(MakeGlobalType(True, VT));
  end;
  VT := ParseValueType;
  Result := MakeGlobalType(False, VT);
end;

function TWatAssembler.FindFieldClose(const AFrom: Integer): Integer;
var
  Depth, P: Integer;
begin
  { AFrom sits INSIDE an open field (depth 1); return the index of the ')'
    that closes it. }
  Depth := 1;
  P := AFrom;
  while P < Length(FToks) do
  begin
    case FToks[P].Kind of
      wttLParen: Inc(Depth);
      wttRParen:
        begin
          Dec(Depth);
          if Depth = 0 then
            Exit(P);
        end;
      wttEof:
        Break;
    end;
    Inc(P);
  end;
  RaiseUnexpected;
  Result := AFrom;
end;

procedure TWatAssembler.ParseParams(var AParams: TArray<TWasmValueType>;
  var ANames: TArray<string>; const AAllowNames: Boolean = True);
var
  Name: string;
  VT: TWasmValueType;
begin
  while IsListHead('param') do
  begin
    ExpectLParen;
    ExpectKeyword('param');
    if Cur.Kind = wttIdentifier then
    begin
      { Only a single-type group may carry an id, and a param id only binds a
        LOCAL — an instruction typeuse (call_indirect, a blocktype) has no
        locals to name, so an id there is `unexpected token` (text-typeuse;
        block.wast:463, call_indirect.wast:738). }
      if not AAllowNames then
        RaiseUnexpected;
      Name := TokenName(Cur);
      Advance;
      VT := ParseValueType;
      SetLength(AParams, Length(AParams) + 1);
      AParams[High(AParams)] := VT;
      SetLength(ANames, Length(ANames) + 1);
      ANames[High(ANames)] := Name;
      ExpectRParen;
    end
    else
    begin
      while Cur.Kind <> wttRParen do
      begin
        VT := ParseValueType;
        SetLength(AParams, Length(AParams) + 1);
        AParams[High(AParams)] := VT;
        SetLength(ANames, Length(ANames) + 1);
        ANames[High(ANames)] := '';
      end;
      ExpectRParen;
    end;
  end;
end;

procedure TWatAssembler.ParseResults(var AResults: TArray<TWasmValueType>);
var
  VT: TWasmValueType;
begin
  while IsListHead('result') do
  begin
    ExpectLParen;
    ExpectKeyword('result');
    while Cur.Kind <> wttRParen do
    begin
      VT := ParseValueType;
      SetLength(AResults, Length(AResults) + 1);
      AResults[High(AResults)] := VT;
    end;
    ExpectRParen;
  end;
end;

function TWatAssembler.ReadIndex(const ASpace: TWatSpace): UInt32;
var
  Name: string;
  Idx: Integer;
begin
  case Cur.Kind of
    wttInteger:
      begin
        Result := UInt32(ParseIntLiteral(Cur.Text, 32));
        Advance;
      end;
    wttIdentifier:
      begin
        Name := TokenName(Cur);
        if ASpace = wnsType then
          Idx := FNames.LookupType(Name)
        else
          Idx := FNames.LookupName(ASpace, Name);
        if Idx < 0 then
        begin
          if ASpace = wnsType then
            RaiseText(MSG_UNKNOWN_TYPE)
          else
            RaiseText('unknown ' + TWatNames.SpaceWord(ASpace) + ' ' + Name);
        end;
        Advance;
        Result := UInt32(Idx);
      end;
  else
    RaiseUnexpected;
    Result := 0;
  end;
end;

function TWatAssembler.ReadLocalIndex: UInt32;
var
  Name: string;
  Idx: Integer;
begin
  case Cur.Kind of
    wttInteger:
      begin
        Result := UInt32(ParseIntLiteral(Cur.Text, 32));
        Advance;
      end;
    wttIdentifier:
      begin
        Name := TokenName(Cur);
        Idx := FNames.LookupLocal(Name);
        if Idx < 0 then
          RaiseText('unknown local ' + Name);
        Advance;
        Result := UInt32(Idx);
      end;
  else
    RaiseUnexpected;
    Result := 0;
  end;
end;

function TWatAssembler.ReadLabelIndex: UInt32;
var
  Name: string;
  Depth: Integer;
begin
  { A NUMERIC label is a de Bruijn depth passed through unchecked — an
    out-of-range one is the validator's `unknown label` (br.wast:647), never a
    text error. A SYMBOLIC label resolves innermost-first; an unresolved one is
    a text error `unknown label` (token.wast:103). }
  case Cur.Kind of
    wttInteger:
      begin
        Result := UInt32(ParseIntLiteral(Cur.Text, 32));
        Advance;
      end;
    wttIdentifier:
      begin
        Name := TokenName(Cur);
        Depth := FNames.LabelDepth(Name);
        if Depth < 0 then
          RaiseText(MSG_UNKNOWN_LABEL);
        Advance;
        Result := UInt32(Depth);
      end;
  else
    RaiseUnexpected;
    Result := 0;
  end;
end;

function TWatAssembler.ReadTypeIndex: UInt32;
begin
  Result := ReadIndex(wnsType);
end;

{ --- type definitions (pass 1a) ----------------------------------------- }

procedure TWatAssembler.ParseCompType(out AComp: TWasmCompType;
  out AFieldNames: TArray<string>);
var
  Params, Results: TArray<TWasmValueType>;
  ParamNames: TArray<string>;
  Func: TWasmFuncType;
  Struct: TWasmStructType;
  Arr: TWasmArrayType;
  FieldName: string;
  FieldTypes: TArray<TWasmFieldType>;
  I: Integer;
begin
  AFieldNames := nil;
  ExpectLParen;
  if IsKeyword('func') then
  begin
    Advance;
    Params := nil;
    Results := nil;
    ParamNames := nil;
    ParseParams(Params, ParamNames);
    ParseResults(Results);
    Func.Params := Params;
    Func.Results := Results;
    AComp := MakeFuncCompType(Func);
    ExpectRParen;
  end
  else if IsKeyword('struct') then
  begin
    Advance;
    Struct.Fields := nil;
    while IsListHead('field') do
    begin
      ExpectLParen;
      ExpectKeyword('field');
      FieldName := '';
      if Cur.Kind = wttIdentifier then
      begin
        FieldName := TokenName(Cur);
        Advance;
      end;
      FieldTypes := nil;
      while Cur.Kind <> wttRParen do
      begin
        SetLength(FieldTypes, Length(FieldTypes) + 1);
        FieldTypes[High(FieldTypes)] := ParseFieldType;
      end;
      ExpectRParen;
      for I := 0 to High(FieldTypes) do
      begin
        SetLength(Struct.Fields, Length(Struct.Fields) + 1);
        Struct.Fields[High(Struct.Fields)] := FieldTypes[I];
        SetLength(AFieldNames, Length(AFieldNames) + 1);
        { Only a single-type group's id names its field. }
        if (Length(FieldTypes) = 1) and (I = 0) then
          AFieldNames[High(AFieldNames)] := FieldName
        else
          AFieldNames[High(AFieldNames)] := '';
      end;
    end;
    AComp := MakeStructCompType(Struct);
    ExpectRParen;
  end
  else if IsKeyword('array') then
  begin
    Advance;
    Arr.Elem := ParseFieldType;
    AComp := MakeArrayCompType(Arr);
    ExpectRParen;
  end
  else
    RaiseUnexpected;
end;

procedure TWatAssembler.ParseSubType(out ASub: TWasmSubType;
  out AFieldNames: TArray<string>);
var
  Final: Boolean;
  Supers: array of UInt32;
begin
  if IsListHead('sub') then
  begin
    ExpectLParen;
    ExpectKeyword('sub');
    Final := False;
    if IsKeyword('final') then
    begin
      Advance;
      Final := True;
    end;
    Supers := nil;
    while (Cur.Kind = wttInteger) or (Cur.Kind = wttIdentifier) do
    begin
      SetLength(Supers, Length(Supers) + 1);
      Supers[High(Supers)] := ReadTypeIndex;
    end;
    ParseCompType(ASub.Comp, AFieldNames);
    ExpectRParen;
    ASub.IsFinal := Final;
    ASub.SuperTypes := Supers;
  end
  else
  begin
    { A bare comptype is a final subtype with no supertypes. }
    ParseCompType(ASub.Comp, AFieldNames);
    ASub.IsFinal := True;
    ASub.SuperTypes := nil;
  end;
end;

procedure TWatAssembler.PreBindTypeField;

  procedure PreBindOneType;
  begin
    { FPos at a member's '(' with head 'type'. Bind the id (if any) to its
      index, then skip the body without resolving anything. }
    ExpectLParen;
    ExpectKeyword('type');
    if Cur.Kind = wttIdentifier then
    begin
      FNames.PreBindType(TokenName(Cur));
      Advance;
    end
    else
      FNames.PreBindType('');
    while Cur.Kind <> wttRParen do
      if Cur.Kind = wttLParen then
        SkipBalanced
      else if Cur.Kind = wttEof then
        RaiseUnexpected
      else
        Advance;
    ExpectRParen;
  end;

begin
  { Pass 0 over the type fields: bind every type member's identifier to its
    module type index BEFORE any type body is parsed, so a body may
    forward-reference a type by name — its own (a self-reference inside a rec
    group) or one defined later (§2b; type-subtyping.wast:37-60, type-rec.wast).
    FPos at the field's '('. }
  ExpectLParen;
  if IsKeyword('rec') then
  begin
    ExpectKeyword('rec');
    while IsListHead('type') do
      PreBindOneType;
    ExpectRParen;
  end
  else
  begin
    { Rewind over the consumed '(' so PreBindOneType sees the whole member. }
    Dec(FPos);
    PreBindOneType;
  end;
end;

procedure TWatAssembler.ParseTypeField;
var
  Rec: TWasmRecType;
  MemberNames: array of string;
  FieldNamesPer: array of TArray<string>;
  Sub: TWasmSubType;
  FieldNames: TArray<string>;
  Name: string;
  IsRec: Boolean;
  Base, I, J: Integer;
begin
  { FPos at the field's '('. }
  ExpectLParen;
  IsRec := IsKeyword('rec');
  if IsRec then
    ExpectKeyword('rec')
  else
    ExpectKeyword('type');

  Rec.SubTypes := nil;
  MemberNames := nil;
  FieldNamesPer := nil;

  if IsRec then
  begin
    while IsListHead('type') do
    begin
      ExpectLParen;
      ExpectKeyword('type');
      Name := '';
      if Cur.Kind = wttIdentifier then
      begin
        Name := TokenName(Cur);
        Advance;
      end;
      ParseSubType(Sub, FieldNames);
      ExpectRParen;
      SetLength(Rec.SubTypes, Length(Rec.SubTypes) + 1);
      Rec.SubTypes[High(Rec.SubTypes)] := Sub;
      SetLength(MemberNames, Length(MemberNames) + 1);
      MemberNames[High(MemberNames)] := Name;
      SetLength(FieldNamesPer, Length(FieldNamesPer) + 1);
      FieldNamesPer[High(FieldNamesPer)] := FieldNames;
    end;
    ExpectRParen;   { close (rec …) }
  end
  else
  begin
    Name := '';
    if Cur.Kind = wttIdentifier then
    begin
      Name := TokenName(Cur);
      Advance;
    end;
    ParseSubType(Sub, FieldNames);
    ExpectRParen;   { close (type …) }
    SetLength(Rec.SubTypes, 1);
    Rec.SubTypes[0] := Sub;
    SetLength(MemberNames, 1);
    MemberNames[0] := Name;
    SetLength(FieldNamesPer, 1);
    FieldNamesPer[0] := FieldNames;
  end;

  Base := FNames.TypeMemberCount;
  { Names were bound in the pre-bind pass (PreBindTypeField); do not re-bind
    them here or the pre-binding would look like a duplicate. }
  FNames.AddTypeGroup(Rec, MemberNames, False);

  { Bind field names into each member's per-type namespace. }
  for I := 0 to High(FieldNamesPer) do
    for J := 0 to High(FieldNamesPer[I]) do
      FNames.BindField(Base + I, FieldNamesPer[I][J]);
end;

{ --- typeuse (pass 1b) -------------------------------------------------- }

function TWatAssembler.ParseTypeUse(out AParamNames: TArray<string>;
  out AParamCount: Integer): UInt32;
var
  HasType: Boolean;
  TypeIdx: UInt32;
  Params, Results: TArray<TWasmValueType>;
  ParamNames: TArray<string>;
begin
  { text-typeuse clause order is fixed: (type …)? (param …)* (result …)*. }
  HasType := False;
  TypeIdx := 0;
  if IsListHead('type') then
  begin
    ExpectLParen;
    ExpectKeyword('type');
    TypeIdx := ReadTypeIndex;
    ExpectRParen;
    HasType := True;
  end;

  Params := nil;
  Results := nil;
  ParamNames := nil;
  ParseParams(Params, ParamNames);
  ParseResults(Results);

  { Clause order is fixed: (type)? (param)* (result)*. A further type/param/
    result clause here is out of order and is `unexpected token` (text-typeuse;
    type.wast:43). }
  if IsListHead('type') or IsListHead('param') or IsListHead('result') then
    RaiseUnexpected;

  if HasType then
  begin
    { Inline declarations, when present, must be syntactically equal to the
      referenced type (text-typeuse). The assembler must READ the referenced
      type to compare, so an out-of-range or non-func `(type x)` carrying inline
      declarations is `unknown type`, and a func that disagrees is
      `inline function type` (§2b; func.wast:454, func.wast:601-606). }
    if (Length(Params) > 0) or (Length(Results) > 0) then
    begin
      if not FNames.MemberIsFunc(Integer(TypeIdx)) then
        RaiseText(MSG_UNKNOWN_TYPE)
      else if not WatFuncTypeEquals(FNames.MemberFunc(Integer(TypeIdx)),
        Params, Results) then
        RaiseText(MSG_INLINE_FUNC_TYPE);
    end;
    AParamNames := ParamNames;
    if Length(ParamNames) > 0 then
      AParamCount := Length(ParamNames)
    else
      AParamCount := FNames.MemberFuncParamCount(Integer(TypeIdx));
    Result := TypeIdx;
  end
  else
  begin
    { Implicit typeuse: intern (reuse-or-append) — THE §7 risk. }
    Result := UInt32(FNames.InternFuncType(Params, Results));
    AParamNames := ParamNames;
    AParamCount := Length(Params);
  end;
end;

procedure TWatAssembler.ParseTypeUseInstr(out AHasType: Boolean;
  out ATypeIdx: UInt32; out AParams, AResults: TArray<TWasmValueType>);
var
  Names: TArray<string>;
begin
  { The typeuse embedded in an INSTRUCTION (call_indirect's signature, a
    block/loop/if blocktype). Same fixed clause order — (type)? (param)*
    (result)* — but param ids are rejected (no locals to name) and any
    out-of-order clause is `unexpected token`. The caller decides how to encode
    the result (a fresh intern, an s33 index, or a blocktype short form). }
  AHasType := False;
  ATypeIdx := 0;
  AParams := nil;
  AResults := nil;
  Names := nil;
  if IsListHead('type') then
  begin
    ExpectLParen;
    ExpectKeyword('type');
    ATypeIdx := ReadTypeIndex;
    ExpectRParen;
    AHasType := True;
  end;
  ParseParams(AParams, Names, False);
  ParseResults(AResults);
  if IsListHead('type') or IsListHead('param') or IsListHead('result') then
    RaiseUnexpected;

  if AHasType and ((Length(AParams) > 0) or (Length(AResults) > 0)) then
  begin
    { Inline declarations must be syntactically equal to the referenced type;
      an out-of-range or non-func reference we cannot read is `unknown type`,
      a func that disagrees is `inline function type` (text-typeuse;
      call_indirect.wast:757, block.wast:467-494, if.wast:795-825). }
    if not FNames.MemberIsFunc(Integer(ATypeIdx)) then
      RaiseText(MSG_UNKNOWN_TYPE)
    else if not WatFuncTypeEquals(FNames.MemberFunc(Integer(ATypeIdx)),
      AParams, AResults) then
      RaiseText(MSG_INLINE_FUNC_TYPE);
  end;
end;

{ --- field declaration helpers (pass 1b) -------------------------------- }

function TWatAssembler.ReadString(const ARequireUtf8: Boolean): string;
begin
  if Cur.Kind <> wttString then
    RaiseUnexpected;
  if ARequireUtf8 and not IsValidUtf8(Cur.Bytes) then
    RaiseText(MSG_MALFORMED_UTF8);
  Result := BytesToStr(Cur.Bytes);
  Advance;
end;

procedure TWatAssembler.ParseInlineExports(var AExports: TArray<string>);
begin
  { Zero or more `(export "name")` abbreviations, possibly followed by an
    import — text-func-abbrev. }
  while IsListHead('export') do
  begin
    ExpectLParen;
    ExpectKeyword('export');
    SetLength(AExports, Length(AExports) + 1);
    AExports[High(AExports)] := ReadString(True);
    ExpectRParen;
  end;
end;

function TWatAssembler.TryParseInlineImport(out AModule, AName: string):
  Boolean;
begin
  Result := False;
  if IsListHead('import') then
  begin
    ExpectLParen;
    ExpectKeyword('import');
    AModule := ReadString(True);
    AName := ReadString(True);
    ExpectRParen;
    Result := True;
  end;
end;

procedure TWatAssembler.NoteDefinition(const AWord: string);
begin
  if FFirstDefWord = '' then
    FFirstDefWord := AWord;
end;

procedure TWatAssembler.DeclareImportField;
var
  Imp: TImpDecl;
  ParamNames: TArray<string>;
  ParamCount: Integer;
begin
  { An explicit `(import "m" "n" (desc))` after ANY non-imported definition is
    malformed, and names the earliest such definition's kind (imports.wast). }
  if FFirstDefWord <> '' then
    RaiseText(MSG_IMPORT_AFTER + FFirstDefWord);

  ExpectLParen;
  ExpectKeyword('import');
  Imp := Default(TImpDecl);
  Imp.ModuleName := ReadString(True);
  Imp.Name := ReadString(True);

  ExpectLParen;
  if IsKeyword('func') then
  begin
    Advance;
    Imp.Kind := wxkFunc;
    if Cur.Kind = wttIdentifier then
    begin
      Imp.Id := TokenName(Cur);
      Advance;
    end;
    Imp.TypeIndex := ParseTypeUse(ParamNames, ParamCount);
  end
  else if IsKeyword('table') then
  begin
    Advance;
    Imp.Kind := wxkTable;
    if Cur.Kind = wttIdentifier then
    begin
      Imp.Id := TokenName(Cur);
      Advance;
    end;
    Imp.Table := ParseTableTypeInline;
  end
  else if IsKeyword('memory') then
  begin
    Advance;
    Imp.Kind := wxkMem;
    if Cur.Kind = wttIdentifier then
    begin
      Imp.Id := TokenName(Cur);
      Advance;
    end;
    Imp.Mem := MakeMemType(ParseLimitsInline);
  end
  else if IsKeyword('global') then
  begin
    Advance;
    Imp.Kind := wxkGlobal;
    if Cur.Kind = wttIdentifier then
    begin
      Imp.Id := TokenName(Cur);
      Advance;
    end;
    Imp.Global := ParseGlobalTypeInline;
  end
  else if IsKeyword('tag') then
  begin
    Advance;
    Imp.Kind := wxkTag;
    if Cur.Kind = wttIdentifier then
    begin
      Imp.Id := TokenName(Cur);
      Advance;
    end;
    Imp.TypeIndex := ParseTypeUse(ParamNames, ParamCount);
  end
  else
    RaiseUnexpected;
  ExpectRParen;   { close (desc) }
  ExpectRParen;   { close (import) }

  SetLength(FImports, Length(FImports) + 1);
  FImports[High(FImports)] := Imp;
end;

procedure TWatAssembler.DeclareFuncField;
var
  F: TFuncDecl;
  Exports_: TArray<string>;
  ImpModule, ImpName: string;
  Imp: TImpDecl;
  ParamNames: TArray<string>;
  ParamCount, CloseIdx: Integer;
begin
  ExpectLParen;
  ExpectKeyword('func');
  F := Default(TFuncDecl);
  if Cur.Kind = wttIdentifier then
  begin
    F.Id := TokenName(Cur);
    Advance;
  end;
  Exports_ := nil;
  ParseInlineExports(Exports_);
  if TryParseInlineImport(ImpModule, ImpName) then
  begin
    { Inline import: this func belongs to the import index range. }
    F.TypeIndex := ParseTypeUse(ParamNames, ParamCount);
    { The func field closes right after the typeuse. }
    if Cur.Kind <> wttRParen then
      RaiseUnexpected;
    Advance;
    Imp := Default(TImpDecl);
    Imp.ModuleName := ImpModule;
    Imp.Name := ImpName;
    Imp.Kind := wxkFunc;
    Imp.Id := F.Id;
    Imp.TypeIndex := F.TypeIndex;
    Imp.InlineExports := Exports_;
    SetLength(FImports, Length(FImports) + 1);
    FImports[High(FImports)] := Imp;
    Exit;
  end;

  NoteDefinition('function');
  F.TypeIndex := ParseTypeUse(ParamNames, ParamCount);
  F.ParamNames := ParamNames;
  F.ParamCount := ParamCount;
  F.InlineExports := Exports_;
  F.BodyStart := FPos;
  CloseIdx := FindFieldClose(FPos);
  F.BodyEnd := CloseIdx;
  FPos := CloseIdx + 1;   { past the func field's ')' }

  SetLength(FFuncs, Length(FFuncs) + 1);
  FFuncs[High(FFuncs)] := F;
end;

procedure TWatAssembler.DeclareTableField;
var
  T: TTableDecl;
  Exports_: TArray<string>;
  ImpModule, ImpName: string;
  Imp: TImpDecl;
begin
  ExpectLParen;
  ExpectKeyword('table');
  T := Default(TTableDecl);
  if Cur.Kind = wttIdentifier then
  begin
    T.Id := TokenName(Cur);
    Advance;
  end;
  Exports_ := nil;
  ParseInlineExports(Exports_);
  if TryParseInlineImport(ImpModule, ImpName) then
  begin
    T.TableType := ParseTableTypeInline;
    ExpectRParen;
    Imp := Default(TImpDecl);
    Imp.ModuleName := ImpModule;
    Imp.Name := ImpName;
    Imp.Kind := wxkTable;
    Imp.Id := T.Id;
    Imp.Table := T.TableType;
    Imp.InlineExports := Exports_;
    SetLength(FImports, Length(FImports) + 1);
    FImports[High(FImports)] := Imp;
    Exit;
  end;

  NoteDefinition('table');
  T.InlineExports := Exports_;

  { Inline `(table id? reftype (elem …))`: a reftype where a limits/addrtype
    would start signals the sugar form. The table's min=max is the element
    count, plus a synthetic active elem segment (§2(c.5)). }
  if ((Cur.Kind = wttKeyword) and IsRefTypeShorthand(Cur.Text))
    or ((Cur.Kind = wttLParen) and (At(1).Kind = wttKeyword)
      and (At(1).Text = 'ref')) then
  begin
    DeclareInlineTableElem(T);
    Exit;
  end;

  T.TableType := ParseTableTypeInline;
  ExpectRParen;
  SetLength(FTables, Length(FTables) + 1);
  FTables[High(FTables)] := T;
end;

procedure TWatAssembler.DeclareMemField;
var
  M: TMemDecl;
  Exports_: TArray<string>;
  ImpModule, ImpName: string;
  Imp: TImpDecl;
begin
  ExpectLParen;
  ExpectKeyword('memory');
  M := Default(TMemDecl);
  if Cur.Kind = wttIdentifier then
  begin
    M.Id := TokenName(Cur);
    Advance;
  end;
  Exports_ := nil;
  ParseInlineExports(Exports_);
  if TryParseInlineImport(ImpModule, ImpName) then
  begin
    M.MemType := MakeMemType(ParseLimitsInline);
    ExpectRParen;
    Imp := Default(TImpDecl);
    Imp.ModuleName := ImpModule;
    Imp.Name := ImpName;
    Imp.Kind := wxkMem;
    Imp.Id := M.Id;
    Imp.Mem := M.MemType;
    Imp.InlineExports := Exports_;
    SetLength(FImports, Length(FImports) + 1);
    FImports[High(FImports)] := Imp;
    Exit;
  end;

  NoteDefinition('memory');
  M.InlineExports := Exports_;

  { Inline `(memory id? (data …))`: the memory min=max is ceil(len/64KiB) plus
    a synthetic active data segment (§2(c.5); bulk.wast:58). }
  if IsListHead('data') then
  begin
    DeclareInlineMemData(M);
    Exit;
  end;

  M.MemType := MakeMemType(ParseLimitsInline);
  ExpectRParen;
  SetLength(FMems, Length(FMems) + 1);
  FMems[High(FMems)] := M;
end;

procedure TWatAssembler.DeclareInlineTableElem(var ATable: TTableDecl);
var
  Rec: TInlineElemDecl;
  Count: Integer;
begin
  { Cur is the reftype; parse it, then the required `(elem <list>)`. The list
    is captured as a token range and re-parsed at emit (funcidx forward refs).
    The table's limits are min=max=element count. }
  Rec.RefType := ParseRefType;
  ExpectLParen;
  ExpectKeyword('elem');
  Rec.ListStart := FPos;
  Count := 0;
  if Cur.Kind = wttLParen then
  begin
    Rec.UsesExprs := True;
    while Cur.Kind = wttLParen do
    begin
      SkipBalanced;
      Inc(Count);
    end;
  end
  else
  begin
    Rec.UsesExprs := False;
    while CurIsIndexToken do
    begin
      Advance;
      Inc(Count);
    end;
  end;
  Rec.ListEnd := FPos;
  Rec.ElemCount := Count;
  ExpectRParen;   { close (elem …) }
  ExpectRParen;   { close (table …) }

  ATable.TableType := MakeTableType(Rec.RefType,
    MakeLimitsWithMax(watI32, UInt64(Count), UInt64(Count)));
  SetLength(FTables, Length(FTables) + 1);
  FTables[High(FTables)] := ATable;

  Rec.TableDeclIndex := High(FTables);
  SetLength(FInlineElems, Length(FInlineElems) + 1);
  FInlineElems[High(FInlineElems)] := Rec;
end;

procedure TWatAssembler.DeclareInlineMemData(var AMem: TMemDecl);
var
  Rec: TInlineDataDecl;
  I, J: Integer;
  Pages: UInt64;
begin
  ExpectLParen;
  ExpectKeyword('data');
  Rec.Payload := nil;
  while Cur.Kind = wttString do
  begin
    J := Length(Rec.Payload);
    SetLength(Rec.Payload, J + Length(Cur.Bytes));
    for I := 0 to High(Cur.Bytes) do
      Rec.Payload[J + I] := Cur.Bytes[I];
    Advance;
  end;
  ExpectRParen;   { close (data …) }
  ExpectRParen;   { close (memory …) }

  Pages := (UInt64(Length(Rec.Payload)) + 65535) div 65536;
  AMem.MemType := MakeMemType(MakeLimitsWithMax(watI32, Pages, Pages));
  SetLength(FMems, Length(FMems) + 1);
  FMems[High(FMems)] := AMem;

  Rec.MemDeclIndex := High(FMems);
  SetLength(FInlineDatas, Length(FInlineDatas) + 1);
  FInlineDatas[High(FInlineDatas)] := Rec;
end;

procedure TWatAssembler.DeclareGlobalField;
var
  G: TGlobalDecl;
  Exports_: TArray<string>;
  ImpModule, ImpName: string;
  Imp: TImpDecl;
  CloseIdx: Integer;
begin
  ExpectLParen;
  ExpectKeyword('global');
  G := Default(TGlobalDecl);
  if Cur.Kind = wttIdentifier then
  begin
    G.Id := TokenName(Cur);
    Advance;
  end;
  Exports_ := nil;
  ParseInlineExports(Exports_);
  if TryParseInlineImport(ImpModule, ImpName) then
  begin
    G.GlobalType := ParseGlobalTypeInline;
    ExpectRParen;
    Imp := Default(TImpDecl);
    Imp.ModuleName := ImpModule;
    Imp.Name := ImpName;
    Imp.Kind := wxkGlobal;
    Imp.Id := G.Id;
    Imp.Global := G.GlobalType;
    Imp.InlineExports := Exports_;
    SetLength(FImports, Length(FImports) + 1);
    FImports[High(FImports)] := Imp;
    Exit;
  end;

  NoteDefinition('global');
  G.GlobalType := ParseGlobalTypeInline;
  G.InlineExports := Exports_;
  G.InitStart := FPos;
  CloseIdx := FindFieldClose(FPos);
  G.InitEnd := CloseIdx;
  FPos := CloseIdx + 1;
  SetLength(FGlobals, Length(FGlobals) + 1);
  FGlobals[High(FGlobals)] := G;
end;

procedure TWatAssembler.DeclareTagField;
var
  T: TTagDecl;
  Exports_: TArray<string>;
  ImpModule, ImpName: string;
  Imp: TImpDecl;
  ParamNames: TArray<string>;
  ParamCount: Integer;
begin
  ExpectLParen;
  ExpectKeyword('tag');
  T := Default(TTagDecl);
  if Cur.Kind = wttIdentifier then
  begin
    T.Id := TokenName(Cur);
    Advance;
  end;
  Exports_ := nil;
  ParseInlineExports(Exports_);
  if TryParseInlineImport(ImpModule, ImpName) then
  begin
    T.TypeIndex := ParseTypeUse(ParamNames, ParamCount);
    ExpectRParen;
    Imp := Default(TImpDecl);
    Imp.ModuleName := ImpModule;
    Imp.Name := ImpName;
    Imp.Kind := wxkTag;
    Imp.Id := T.Id;
    Imp.TypeIndex := T.TypeIndex;
    Imp.InlineExports := Exports_;
    SetLength(FImports, Length(FImports) + 1);
    FImports[High(FImports)] := Imp;
    Exit;
  end;

  { A defined tag is not one of the four kinds the import-after rule names. }
  T.TypeIndex := ParseTypeUse(ParamNames, ParamCount);
  T.InlineExports := Exports_;
  ExpectRParen;
  SetLength(FTags, Length(FTags) + 1);
  FTags[High(FTags)] := T;
end;

procedure TWatAssembler.DeclareExportField;
var
  E: TExpDecl;
begin
  ExpectLParen;
  ExpectKeyword('export');
  E := Default(TExpDecl);
  E.Name := ReadString(True);
  ExpectLParen;
  if IsKeyword('func') then E.Kind := wxkFunc
  else if IsKeyword('table') then E.Kind := wxkTable
  else if IsKeyword('memory') then E.Kind := wxkMem
  else if IsKeyword('global') then E.Kind := wxkGlobal
  else if IsKeyword('tag') then E.Kind := wxkTag
  else RaiseUnexpected;
  Advance;   { the kind keyword }
  E.Resolved := False;
  E.RefTok := FPos;   { resolve the operand at emit, when all names are bound }
  { skip operand + close }
  if (Cur.Kind = wttInteger) or (Cur.Kind = wttIdentifier) then
    Advance
  else
    RaiseUnexpected;
  ExpectRParen;   { close (kind idx) }
  ExpectRParen;   { close (export) }
  SetLength(FExports, Length(FExports) + 1);
  FExports[High(FExports)] := E;
end;

procedure TWatAssembler.DeclareStartField;
begin
  ExpectLParen;
  ExpectKeyword('start');
  if FHasStart then
    RaiseText(MSG_MULTIPLE_START);
  FHasStart := True;
  FStartTok := FPos;
  if (Cur.Kind = wttInteger) or (Cur.Kind = wttIdentifier) then
    Advance
  else
    RaiseUnexpected;
  ExpectRParen;
end;

procedure TWatAssembler.DeclareSegField(const AIsData: Boolean);
var
  Seg: TSegDecl;
  Id: string;
begin
  Seg.FieldStart := FPos;
  { Bind the segment id (elem/data spaces) before skipping the field. }
  ExpectLParen;
  if AIsData then
    ExpectKeyword('data')
  else
    ExpectKeyword('elem');
  Id := '';
  if Cur.Kind = wttIdentifier then
  begin
    Id := TokenName(Cur);
    Advance;
  end;
  if AIsData then
    FNames.Bind(wnsData, Id)
  else
    FNames.Bind(wnsElem, Id);
  { Skip the rest of the field; it is re-parsed at emit. }
  FPos := Seg.FieldStart;
  SkipBalanced;
  if AIsData then
  begin
    SetLength(FDatas, Length(FDatas) + 1);
    FDatas[High(FDatas)] := Seg;
  end
  else
  begin
    SetLength(FElems, Length(FElems) + 1);
    FElems[High(FElems)] := Seg;
  end;
end;

procedure TWatAssembler.DeclareField;
var
  Head: string;
begin
  if Cur.Kind <> wttLParen then
    RaiseUnexpected;
  { A field head that is a RESERVED run — `data"a"`, or a stray `@a`/`@b` left
    when `( @a)` / `((@a)@b)` failed to form an annotation — is `unknown
    operator`, since RaiseUnexpected would otherwise look at the '(' and miss it
    (annotations.wast:70,94; token.wast:143). }
  if At(1).Kind = wttReserved then
    RaiseUnknownOperator(At(1).Text);
  if At(1).Kind <> wttKeyword then
    RaiseUnexpected;
  Head := At(1).Text;

  if (Head = 'type') or (Head = 'rec') then
    SkipBalanced           { collected in pass 1a }
  else if Head = 'import' then
    DeclareImportField
  else if Head = 'func' then
    DeclareFuncField
  else if Head = 'table' then
    DeclareTableField
  else if Head = 'memory' then
    DeclareMemField
  else if Head = 'global' then
    DeclareGlobalField
  else if Head = 'tag' then
    DeclareTagField
  else if Head = 'export' then
    DeclareExportField
  else if Head = 'start' then
    DeclareStartField
  else if Head = 'elem' then
    DeclareSegField(False)
  else if Head = 'data' then
    DeclareSegField(True)
  else
    RaiseUnexpected;
end;

{ --- index assignment --------------------------------------------------- }

procedure TWatAssembler.AssignSpace(const ASpace: TWatSpace);
var
  I: Integer;
  WantKind: TWasmExternKind;
begin
  case ASpace of
    wnsFunc:   WantKind := wxkFunc;
    wnsTable:  WantKind := wxkTable;
    wnsMem:    WantKind := wxkMem;
    wnsGlobal: WantKind := wxkGlobal;
    wnsTag:    WantKind := wxkTag;
  else
    Exit;
  end;

  { Imports occupy the low indices of their space, in textual order. }
  for I := 0 to High(FImports) do
    if FImports[I].Kind = WantKind then
      FImports[I].FinalIndex := FNames.Bind(ASpace, FImports[I].Id);

  case ASpace of
    wnsFunc:
      for I := 0 to High(FFuncs) do
        FFuncs[I].FinalIndex := FNames.Bind(wnsFunc, FFuncs[I].Id);
    wnsTable:
      for I := 0 to High(FTables) do
        FTables[I].FinalIndex := FNames.Bind(wnsTable, FTables[I].Id);
    wnsMem:
      for I := 0 to High(FMems) do
        FMems[I].FinalIndex := FNames.Bind(wnsMem, FMems[I].Id);
    wnsGlobal:
      for I := 0 to High(FGlobals) do
        FGlobals[I].FinalIndex := FNames.Bind(wnsGlobal, FGlobals[I].Id);
    wnsTag:
      for I := 0 to High(FTags) do
        FTags[I].FinalIndex := FNames.Bind(wnsTag, FTags[I].Id);
  end;
end;

procedure TWatAssembler.AssignIndices;
begin
  AssignSpace(wnsFunc);
  AssignSpace(wnsTable);
  AssignSpace(wnsMem);
  AssignSpace(wnsGlobal);
  AssignSpace(wnsTag);
end;

{ --- instruction emission ----------------------------------------------- }

procedure TWatAssembler.EmitOpcode(var AOut: TWasmWriter;
  const AInfo: TWasmOpcodeInfo);
begin
  if AInfo.HasPrefix then
  begin
    AOut.WriteByte(AInfo.Prefix);
    AOut.WriteU32(AInfo.Opcode);
  end
  else
    AOut.WriteByte(AInfo.Opcode);
end;

function TWatAssembler.TakeNumberText: string;
begin
  { A numeric literal is an integer- or float-shaped token; a RESERVED run
    (`0x`, `1x`, `0xg`) is a malformed number and is passed through so Numbers
    raises `unknown operator`. A KEYWORD here is never a literal — the result
    patterns `nan:canonical` / `nan:arithmetic` lex as keywords and belong to
    the runner's matcher, so in a const they are `unexpected token`, not a
    number (§d.2; i64.wast:487-491). }
  case Cur.Kind of
    wttInteger, wttFloat, wttReserved:
      begin
        Result := Cur.Text;
        Advance;
      end;
    wttKeyword:
      begin
        { nan:canonical / nan:arithmetic are the runner's result-match patterns,
          not literals: in a const they are `unexpected token` (i64.wast:487-491).
          Any OTHER keyword is a malformed number token (`nan:1`) passed through
          to Numbers, which raises `unknown operator` (const.wast:409-413). }
        if (Cur.Text = 'nan:canonical') or (Cur.Text = 'nan:arithmetic') then
          RaiseUnexpected;
        Result := Cur.Text;
        Advance;
      end;
  else
    RaiseUnexpected;
    Result := '';
  end;
end;

function TWatAssembler.CurIsIndexToken: Boolean;
begin
  Result := (Cur.Kind = wttInteger) or (Cur.Kind = wttIdentifier);
end;

function TWatAssembler.ReadOptionalIndex(const ASpace: TWatSpace;
  const ADefault: UInt32): UInt32;
begin
  { Many 3.0 immediates carry an optional table/memory index that defaults to
    0 when omitted (memory.size, table.fill, the second memarg operand, …). An
    index token is an integer or a $id; anything else means "omitted". }
  if CurIsIndexToken then
    Result := ReadIndex(ASpace)
  else
    Result := ADefault;
end;

{ Convert an explicit `align=` byte count to its log2 encoding, raising the
  power-of-two text error otherwise (§2(c.6); align.wast:26-37). Zero and any
  non-power-of-two land here; `align` LARGER than natural is the validator's
  job, not the assembler's, so it is passed through. }
function AlignFieldLog2(const AValue: UInt32): Byte;
var
  V: UInt32;
begin
  if (AValue = 0) or ((AValue and (AValue - 1)) <> 0) then
    raise EWasmTextError.Create(MSG_ALIGNMENT);
  Result := 0;
  V := AValue;
  while V > 1 do
  begin
    V := V shr 1;
    Inc(Result);
  end;
end;

procedure TWatAssembler.EmitMemArg(var AOut: TWasmWriter;
  const AInfo: TWasmOpcodeInfo);
var
  HasMem: Boolean;
  MemIdx: UInt32;
  Offset: UInt64;
  AlignLog2, Flags: Byte;
  Kw, ValText: string;
begin
  { memarg ::= memidx? offset=<u64>? align=<u32>? — memidx first (an index
    token), then the `offset=`/`align=` keyword tokens in any order. align is
    encoded as log2 in the flag field, with bit 6 signalling an explicit
    memidx that rides between the flags and the u64 offset (§2(c.6); mirrors
    Wasm.Decoder.Expr.SkipMemarg). }
  HasMem := False;
  MemIdx := 0;
  if CurIsIndexToken then
  begin
    HasMem := True;
    MemIdx := ReadIndex(wnsMem);
  end;

  Offset := 0;
  AlignLog2 := AInfo.NaturalAlignLog2;
  while (Cur.Kind = wttKeyword)
    and (TextStartsWith(Cur.Text, 'offset=') or TextStartsWith(Cur.Text, 'align=')) do
  begin
    Kw := Cur.Text;
    if TextStartsWith(Kw, 'offset=') then
    begin
      ValText := Copy(Kw, Length('offset=') + 1, Length(Kw));
      Offset := ParseIntLiteral(ValText, 64);
    end
    else
    begin
      ValText := Copy(Kw, Length('align=') + 1, Length(Kw));
      AlignLog2 := AlignFieldLog2(UInt32(ParseIntLiteral(ValText, 32)));
    end;
    Advance;
  end;

  Flags := AlignLog2;
  if HasMem then
    Flags := Flags or $40;
  AOut.WriteU32(Flags);
  if HasMem then
    AOut.WriteU32(MemIdx);
  AOut.WriteU64(Offset);
end;

procedure TWatAssembler.EmitBrTable(var AOut: TWasmWriter);
var
  Labels: array of UInt32;
  I: Integer;
begin
  { A vector of label indices plus a trailing default label. }
  Labels := nil;
  while CurIsIndexToken do
  begin
    SetLength(Labels, Length(Labels) + 1);
    Labels[High(Labels)] := ReadLabelIndex;
  end;
  if Length(Labels) < 1 then
    RaiseUnexpected;
  AOut.WriteU32(UInt32(Length(Labels) - 1));
  for I := 0 to High(Labels) - 1 do
    AOut.WriteU32(Labels[I]);
  AOut.WriteU32(Labels[High(Labels)]);   { the default }
end;

procedure TWatAssembler.EmitCallIndirect(var AOut: TWasmWriter);
var
  TableIdx, TypeIdx: UInt32;
  HasType: Boolean;
  Params, Results: TArray<TWasmValueType>;
begin
  { call_indirect x:tableidx? y:typeuse — the table defaults to 0; the typeuse
    may intern an implicit type (which is why the type section is built LAST,
    after every body has been walked). The typeuse is an INSTRUCTION typeuse:
    fixed clause order, no param ids, inline decls must match (§2c.1). }
  TableIdx := ReadOptionalIndex(wnsTable, 0);
  ParseTypeUseInstr(HasType, TypeIdx, Params, Results);
  if not HasType then
    TypeIdx := UInt32(FNames.InternFuncType(Params, Results));
  AOut.WriteU32(TypeIdx);
  AOut.WriteU32(TableIdx);
end;

procedure TWatAssembler.EmitCatchVector(var AOut: TWasmWriter);
var
  Clauses: TWasmWriter;
  Count: UInt32;
  Head: string;
begin
  { try_table's catch clause vector — each clause a kind byte then its
    immediates, mirroring Wasm.Decoder.Expr.SkipCatchVector. The clause LABELS
    resolve in the ENCLOSING scope: the try_table's own label is not pushed
    until after this vector (Wasm.Validator.Body: "the clause labels resolve
    before the try_table frame is pushed"). }
  Clauses.Init;
  Count := 0;
  while IsListHead('catch') or IsListHead('catch_ref')
    or IsListHead('catch_all') or IsListHead('catch_all_ref') do
  begin
    ExpectLParen;
    Head := Cur.Text;
    Advance;   { the catch* keyword }
    if Head = 'catch' then
    begin
      Clauses.WriteByte($00);
      Clauses.WriteU32(ReadIndex(wnsTag));
      Clauses.WriteU32(ReadLabelIndex);
    end
    else if Head = 'catch_ref' then
    begin
      Clauses.WriteByte($01);
      Clauses.WriteU32(ReadIndex(wnsTag));
      Clauses.WriteU32(ReadLabelIndex);
    end
    else if Head = 'catch_all' then
    begin
      Clauses.WriteByte($02);
      Clauses.WriteU32(ReadLabelIndex);
    end
    else
    begin
      Clauses.WriteByte($03);
      Clauses.WriteU32(ReadLabelIndex);
    end;
    ExpectRParen;
    Inc(Count);
  end;
  AOut.WriteU32(Count);
  AOut.AppendBytes(Clauses.ToBytes);
end;

procedure TWatAssembler.EmitTypeField(var AOut: TWasmWriter);
var
  TypeIdx, FieldIdx: UInt32;
  Name: string;
  F: Integer;
begin
  { struct.get/set etc.: typeidx then fieldidx, the field resolved against the
    per-type field namespace of the FIRST operand (§3; struct.wast:82-106). }
  TypeIdx := ReadTypeIndex;
  case Cur.Kind of
    wttInteger:
      begin
        FieldIdx := UInt32(ParseIntLiteral(Cur.Text, 32));
        Advance;
      end;
    wttIdentifier:
      begin
        Name := TokenName(Cur);
        F := FNames.LookupField(Integer(TypeIdx), Name);
        if F < 0 then
          RaiseText('unknown field ' + Name);
        Advance;
        FieldIdx := UInt32(F);
      end;
  else
    RaiseUnexpected;
    FieldIdx := 0;
  end;
  AOut.WriteU32(TypeIdx);
  AOut.WriteU32(FieldIdx);
end;

procedure TWatAssembler.EmitSelect(var AOut: TWasmWriter;
  const AInfo: TWasmOpcodeInfo);
var
  Results: TArray<TWasmValueType>;
  I: Integer;
begin
  { Bare select is AInfo.Opcode ($1B); the typed form is Opcode+1 ($1C) with a
    vec(valtype) of the result annotation (binary-select). }
  if IsListHead('result') then
  begin
    Results := nil;
    ParseResults(Results);
    AOut.WriteByte(AInfo.Opcode + 1);
    AOut.WriteU32(UInt32(Length(Results)));
    for I := 0 to High(Results) do
      AOut.WriteValueType(Results[I]);
  end
  else
    AOut.WriteByte(AInfo.Opcode);
end;

procedure TWatAssembler.EmitRefTestCast(var AOut: TWasmWriter;
  const AInfo: TWasmOpcodeInfo);
var
  Ref: TWasmRefType;
  Sub: UInt32;
begin
  { ref.test / ref.cast take a reftype `(ref null? ht)`; the null variant is
    the +1 subopcode and only a HEAP TYPE is emitted (binary-ref.test). }
  Ref := ParseRefType;
  Sub := AInfo.Opcode;
  if Ref.Nullable then
    Inc(Sub);
  AOut.WriteByte(AInfo.Prefix);
  AOut.WriteU32(Sub);
  AOut.WriteHeapType(Ref.Heap);
end;

procedure TWatAssembler.EmitBrOnCast(var AOut: TWasmWriter;
  const AInfo: TWasmOpcodeInfo);
var
  LabelIdx: UInt32;
  Ref1, Ref2: TWasmRefType;
  Flags: Byte;
begin
  { br_on_cast(_fail) label rt1 rt2 — the castop flags byte records which of
    the two reftypes are nullable (bit 0 = rt1, bit 1 = rt2), then labelidx and
    the two HEAP TYPES (binary-br_on_cast / binary-castop). The opcode
    (prefix + subopcode) is already written by EmitOpcode — this shape is a
    fixed-opcode one routed through EmitImmediatesBody, so writing it again here
    would double the $FB prefix and the decoder would read it as the flags
    byte. Emit only the immediates. }
  LabelIdx := ReadLabelIndex;
  Ref1 := ParseRefType;
  Ref2 := ParseRefType;
  Flags := 0;
  if Ref1.Nullable then
    Flags := Flags or $01;
  if Ref2.Nullable then
    Flags := Flags or $02;
  AOut.WriteByte(Flags);
  AOut.WriteU32(LabelIdx);
  AOut.WriteHeapType(Ref1.Heap);
  AOut.WriteHeapType(Ref2.Heap);
end;

procedure TWatAssembler.EmitImmediatesBody(var AOut: TWasmWriter;
  const AInfo: TWasmOpcodeInfo; const AMnemonic: string);
var
  Bits64: UInt64;
  DataIdx, MemIdx, ElemIdx, TableIdx, TypeIdx, TypeIdx2, Count: UInt32;
begin
  { The opcode byte(s) are already written; this handles every fixed-opcode
    immediate shape. The variable-opcode shapes (select, ref.test/cast) never
    reach here — EmitOpcodeAndImmediates handles them first. }
  case AInfo.Shape of
    wisNone:;
    wisConstI32:
      AOut.WriteS32(Int32(UInt32(ParseIntLiteral(TakeNumberText, 32))));
    wisConstI64:
      AOut.WriteS64(Int64(ParseIntLiteral(TakeNumberText, 64)));
    wisConstF32:
      AOut.WriteFixedU32(ParseF32(TakeNumberText));
    wisConstF64:
      begin
        Bits64 := ParseF64(TakeNumberText);
        AOut.WriteFixedU32(UInt32(Bits64 and UInt64($FFFFFFFF)));
        AOut.WriteFixedU32(UInt32(Bits64 shr 32));
      end;
    wisLocal:
      AOut.WriteU32(ReadLocalIndex);
    wisGlobal:
      AOut.WriteU32(ReadIndex(wnsGlobal));
    wisFunc:
      AOut.WriteU32(ReadIndex(wnsFunc));
    wisType:
      AOut.WriteU32(ReadTypeIndex);
    wisTag:
      AOut.WriteU32(ReadIndex(wnsTag));
    wisLabel:
      AOut.WriteU32(ReadLabelIndex);
    wisTable:
      AOut.WriteU32(ReadOptionalIndex(wnsTable, 0));
    wisMem:
      AOut.WriteU32(ReadOptionalIndex(wnsMem, 0));
    wisData:
      begin
        FUsesDataIndex := True;   { data.drop — data-count section is required }
        AOut.WriteU32(ReadIndex(wnsData));
      end;
    wisElem:
      AOut.WriteU32(ReadIndex(wnsElem));
    wisHeapType:
      AOut.WriteHeapType(ParseHeapType);
    wisMemArg:
      EmitMemArg(AOut, AInfo);
    wisBrTable:
      EmitBrTable(AOut);
    wisCallIndirect:
      EmitCallIndirect(AOut);
    wisTryTable:
      { try_table is a structured instruction, routed through EmitFoldedBlock /
        EmitTryTableFlat, never here. }
      RaiseUnknownOperator(AMnemonic);
    wisTypeField:
      EmitTypeField(AOut);
    wisTypeCount:
      begin
        TypeIdx := ReadTypeIndex;
        Count := UInt32(ParseIntLiteral(TakeNumberText, 32));
        AOut.WriteU32(TypeIdx);
        AOut.WriteU32(Count);
      end;
    wisTypeData:
      begin
        FUsesDataIndex := True;   { array.new_data / array.init_data }
        TypeIdx := ReadTypeIndex;
        DataIdx := ReadIndex(wnsData);
        AOut.WriteU32(TypeIdx);
        AOut.WriteU32(DataIdx);
      end;
    wisTypeElem:
      begin
        TypeIdx := ReadTypeIndex;
        ElemIdx := ReadIndex(wnsElem);
        AOut.WriteU32(TypeIdx);
        AOut.WriteU32(ElemIdx);
      end;
    wisTypeType:
      begin
        TypeIdx := ReadTypeIndex;
        TypeIdx2 := ReadTypeIndex;
        AOut.WriteU32(TypeIdx);
        AOut.WriteU32(TypeIdx2);
      end;
    wisDataMem:
      begin
        { memory.init x:memidx? y:dataidx (memory container first in text,
          data index first in the encoding — memory_init.wast). }
        FUsesDataIndex := True;   { data-count section is required }
        if CurIsIndexToken and ((At(1).Kind = wttInteger)
          or (At(1).Kind = wttIdentifier)) then
        begin
          MemIdx := ReadIndex(wnsMem);
          DataIdx := ReadIndex(wnsData);
        end
        else
        begin
          MemIdx := 0;
          DataIdx := ReadIndex(wnsData);
        end;
        AOut.WriteU32(DataIdx);
        AOut.WriteU32(MemIdx);
      end;
    wisMemMem:
      begin
        MemIdx := ReadOptionalIndex(wnsMem, 0);
        AOut.WriteU32(MemIdx);
        AOut.WriteU32(ReadOptionalIndex(wnsMem, 0));
      end;
    wisElemTable:
      begin
        { table.init x:tableidx? y:elemidx (table container first in text, elem
          index first in the encoding — table.init $t0 1 vs table.init 4). }
        if CurIsIndexToken and ((At(1).Kind = wttInteger)
          or (At(1).Kind = wttIdentifier)) then
        begin
          TableIdx := ReadIndex(wnsTable);
          ElemIdx := ReadIndex(wnsElem);
        end
        else
        begin
          TableIdx := 0;
          ElemIdx := ReadIndex(wnsElem);
        end;
        AOut.WriteU32(ElemIdx);
        AOut.WriteU32(TableIdx);
      end;
    wisTableTable:
      begin
        TableIdx := ReadOptionalIndex(wnsTable, 0);
        AOut.WriteU32(TableIdx);
        AOut.WriteU32(ReadOptionalIndex(wnsTable, 0));
      end;
    wisBrOnCast:
      EmitBrOnCast(AOut, AInfo);
  else
    RaiseUnknownOperator(AMnemonic);
  end;
end;

procedure TWatAssembler.EmitOpcodeAndImmediates(var AOut: TWasmWriter;
  const AInfo: TWasmOpcodeInfo; const AMnemonic: string);
begin
  { The shapes whose OPCODE depends on the immediate must decide the byte
    themselves; every other shape writes the fixed opcode then its immediates. }
  case AInfo.Shape of
    wisSelect:
      EmitSelect(AOut, AInfo);
    wisRefTest, wisRefCast:
      EmitRefTestCast(AOut, AInfo);
  else
    EmitOpcode(AOut, AInfo);
    EmitImmediatesBody(AOut, AInfo, AMnemonic);
  end;
end;

procedure TWatAssembler.EmitBlockType(var AOut: TWasmWriter);
var
  Params, Results: TArray<TWasmValueType>;
  HasType: Boolean;
  Idx: UInt32;
begin
  { A block type is an INSTRUCTION type use, but the syntactically-empty and
    single-result cases parse to the short forms rather than an inline function
    type (text-blocktype). Clause order, the ban on param ids, and the inline
    match are all enforced by ParseTypeUseInstr; an explicit (type x) is written
    as its s33 index (its inline decls, once checked, only name locals a block
    cannot bind, so they are discarded); a param-carrying or multi-result type
    is interned like any implicit typeuse (§2(c.4)) — the type section is built
    last so a fresh insertion is picked up. }
  ParseTypeUseInstr(HasType, Idx, Params, Results);
  if HasType then
  begin
    AOut.WriteS33(Int64(Idx));
    Exit;
  end;

  if (Length(Params) = 0) and (Length(Results) = 0) then
  begin
    AOut.WriteEmptyBlockType;
    Exit;
  end;
  if (Length(Params) = 0) and (Length(Results) = 1) then
  begin
    AOut.WriteValueType(Results[0]);
    Exit;
  end;
  AOut.WriteS33(Int64(FNames.InternFuncType(Params, Results)));
end;

procedure TWatAssembler.CheckLabelMatch(const AToken: TWatToken;
  const ABlockName: string);
begin
  if TokenName(AToken) <> ABlockName then
    RaiseText(MSG_MISMATCHING_LABEL);
end;

procedure TWatAssembler.EmitBlock(var AOut: TWasmWriter;
  const AMnemonic: string);
var
  Info: TWasmOpcodeInfo;
  Name: string;
begin
  { Flat block/loop/if: `op label? blocktype instr* (else instr*)? end`. The
    label push happens before the body so an inner br resolves it. }
  LookupOpcode(AMnemonic, Info);
  Name := '';
  if Cur.Kind = wttIdentifier then
  begin
    Name := TokenName(Cur);
    Advance;
  end;
  FNames.PushLabel(Name);
  AOut.WriteByte(Info.Opcode);
  EmitBlockType(AOut);

  EmitInstrSeq(AOut, True, MaxInt);

  if (AMnemonic = 'if') and IsKeyword('else') then
  begin
    Advance;   { 'else' }
    { A trailing id at `else` must equal the block's id (mismatching label). }
    if Cur.Kind = wttIdentifier then
    begin
      CheckLabelMatch(Cur, Name);
      Advance;
    end;
    AOut.WriteByte($05);   { else }
    EmitInstrSeq(AOut, True, MaxInt);
  end;

  ExpectKeyword('end');
  { A trailing id at `end` must equal the block's id. }
  if Cur.Kind = wttIdentifier then
  begin
    CheckLabelMatch(Cur, Name);
    Advance;
  end;
  AOut.WriteByte($0B);   { end }
  FNames.PopLabel;
end;

procedure TWatAssembler.EmitTryTableFlat(var AOut: TWasmWriter);
var
  Name: string;
begin
  { Flat try_table: `try_table label? blocktype catch* instr* end`. The block
    type and the catch vector are emitted BEFORE the label is pushed, so a
    catch clause's target resolves in the enclosing scope. }
  Name := '';
  if Cur.Kind = wttIdentifier then
  begin
    Name := TokenName(Cur);
    Advance;
  end;
  AOut.WriteByte($1F);
  EmitBlockType(AOut);
  EmitCatchVector(AOut);

  FNames.PushLabel(Name);
  EmitInstrSeq(AOut, True, MaxInt);
  ExpectKeyword('end');
  if Cur.Kind = wttIdentifier then
  begin
    CheckLabelMatch(Cur, Name);
    Advance;
  end;
  AOut.WriteByte($0B);
  FNames.PopLabel;
end;

procedure TWatAssembler.EmitFoldedBlock(var AOut: TWasmWriter;
  const AMnemonic: string);
var
  Info: TWasmOpcodeInfo;
  Name: string;
  BtBuf: TWasmWriter;
begin
  { Folded block/loop/if/try_table — the `end` delimiter is implied. FPos sits
    at the head keyword (the '(' is already consumed); this routine consumes
    through the closing ')'. }
  Advance;   { the head keyword }
  Name := '';
  if Cur.Kind = wttIdentifier then
  begin
    Name := TokenName(Cur);
    Advance;
  end;

  if AMnemonic = 'if' then
  begin
    { ( if label? blocktype folded* (then instr*) (else instr*)? ) — the
      folded CONDITION operands emit BEFORE the `if` opcode, then the then-arm,
      then else, then end (§2(c.3), §7; the silent-bug case). The blocktype is
      captured first but written only after the condition. }
    BtBuf.Init;
    EmitBlockType(BtBuf);
    while (Cur.Kind = wttLParen) and not IsListHead('then')
      and not IsListHead('else') do
      EmitFoldedInstr(AOut);

    FNames.PushLabel(Name);
    LookupOpcode('if', Info);   { $04 — same row the flat path uses. }
    AOut.WriteByte(Info.Opcode);
    AOut.AppendBytes(BtBuf.ToBytes);

    ExpectLParen;
    ExpectKeyword('then');
    EmitInstrSeq(AOut, False, MaxInt);
    ExpectRParen;

    if IsListHead('else') then
    begin
      ExpectLParen;
      ExpectKeyword('else');
      AOut.WriteByte($05);
      EmitInstrSeq(AOut, False, MaxInt);
      ExpectRParen;
    end;

    AOut.WriteByte($0B);
    FNames.PopLabel;
    ExpectRParen;   { close ( if … ) }
    Exit;
  end;

  if AMnemonic = 'try_table' then
  begin
    LookupOpcode('try_table', Info);   { $1F — same row the flat path uses. }
    AOut.WriteByte(Info.Opcode);
    EmitBlockType(AOut);
    EmitCatchVector(AOut);
    FNames.PushLabel(Name);
    EmitInstrSeq(AOut, False, MaxInt);
    AOut.WriteByte($0B);
    FNames.PopLabel;
    ExpectRParen;
    Exit;
  end;

  { block / loop. }
  LookupOpcode(AMnemonic, Info);
  FNames.PushLabel(Name);
  AOut.WriteByte(Info.Opcode);
  EmitBlockType(AOut);
  EmitInstrSeq(AOut, False, MaxInt);
  AOut.WriteByte($0B);
  FNames.PopLabel;
  ExpectRParen;
end;

procedure TWatAssembler.EmitFlatInstr(var AOut: TWasmWriter);
var
  Mnemonic: string;
  Info: TWasmOpcodeInfo;
begin
  Mnemonic := Cur.Text;
  Advance;   { the mnemonic keyword }
  if (Mnemonic = 'block') or (Mnemonic = 'loop') or (Mnemonic = 'if') then
  begin
    EmitBlock(AOut, Mnemonic);
    Exit;
  end;
  if Mnemonic = 'try_table' then
  begin
    EmitTryTableFlat(AOut);
    Exit;
  end;
  if IsStructuralKeyword(Mnemonic) then
    RaiseUnexpected;
  if not LookupOpcode(Mnemonic, Info) then
    RaiseUnknownOperator(Mnemonic);
  if (Info.Shape = wisBlockType) or (Info.Shape = wisTryTable) then
    RaiseUnknownOperator(Mnemonic);   { structured forms handled above }
  EmitOpcodeAndImmediates(AOut, Info, Mnemonic);
end;

procedure TWatAssembler.EmitFoldedInstr(var AOut: TWasmWriter);
var
  Mnemonic: string;
  Info: TWasmOpcodeInfo;
  Imm: TWasmWriter;
begin
  ExpectLParen;
  if Cur.Kind <> wttKeyword then
    RaiseUnexpected;
  Mnemonic := Cur.Text;
  if (Mnemonic = 'block') or (Mnemonic = 'loop') or (Mnemonic = 'if')
    or (Mnemonic = 'try_table') then
  begin
    EmitFoldedBlock(AOut, Mnemonic);
    Exit;
  end;
  if IsStructuralKeyword(Mnemonic) then
    RaiseUnexpected;
  Advance;   { the mnemonic keyword }
  if not LookupOpcode(Mnemonic, Info) then
    RaiseUnknownOperator(Mnemonic);
  if (Info.Shape = wisBlockType) or (Info.Shape = wisTryTable) then
    RaiseUnknownOperator(Mnemonic);

  { ( plaininstr folded* ) => unfold(folded*) then plaininstr: parse this
    instruction's opcode+immediates first (into a temp), then emit the operand
    instructions, then splice this instruction after them. }
  Imm.Init;
  EmitOpcodeAndImmediates(Imm, Info, Mnemonic);
  EmitInstrSeq(AOut, False, MaxInt);
  AOut.AppendBytes(Imm.ToBytes);
  ExpectRParen;
end;

procedure TWatAssembler.EmitInstrSeq(var AOut: TWasmWriter;
  const AStopAtEnd: Boolean; const AEnd: Integer);
begin
  while FPos < AEnd do
  begin
    case PeekKind of
      wttEof, wttRParen:
        Exit;
      wttKeyword:
        begin
          if AStopAtEnd and ((Cur.Text = 'end') or (Cur.Text = 'else')) then
            Exit;
          EmitFlatInstr(AOut);
        end;
      wttLParen:
        EmitFoldedInstr(AOut);
    else
      RaiseUnexpected;
    end;
  end;
end;

procedure TWatAssembler.EmitConstExpr(var AOut: TWasmWriter;
  const AStart, AEnd: Integer);
var
  Saved: Integer;
begin
  Saved := FPos;
  FPos := AStart;
  EmitInstrSeq(AOut, False, AEnd);
  FPos := Saved;
  AOut.WriteByte($0B);   { end }
end;

{ --- section builders --------------------------------------------------- }

procedure TWatAssembler.WriteName(var AOut: TWasmWriter; const AName: string);
var
  I: Integer;
begin
  AOut.WriteU32(UInt32(Length(AName)));
  for I := 1 to Length(AName) do
    AOut.WriteByte(Byte(Ord(AName[I]) and $FF));
end;

procedure TWatAssembler.EmitFuncLocalsAndBody(const AFunc: TFuncDecl;
  var AEntry: TWasmWriter);
var
  Locals: TArray<TWasmValueType>;
  VT: TWasmValueType;
  Name: string;
  I, GroupCount, RunLen: Integer;
begin
  FNames.ResetLocals;
  { Bind params: named ones (inline) or anonymous placeholders (type-only). }
  if Length(AFunc.ParamNames) > 0 then
    for I := 0 to High(AFunc.ParamNames) do
      FNames.BindLocal(AFunc.ParamNames[I])
  else
    for I := 0 to AFunc.ParamCount - 1 do
      FNames.BindLocal('');

  FPos := AFunc.BodyStart;
  Locals := nil;
  while IsListHead('local') do
  begin
    ExpectLParen;
    ExpectKeyword('local');
    if Cur.Kind = wttIdentifier then
    begin
      Name := TokenName(Cur);
      Advance;
      VT := ParseValueType;
      FNames.BindLocal(Name);
      SetLength(Locals, Length(Locals) + 1);
      Locals[High(Locals)] := VT;
      ExpectRParen;
    end
    else
    begin
      while Cur.Kind <> wttRParen do
      begin
        VT := ParseValueType;
        FNames.BindLocal('');
        SetLength(Locals, Length(Locals) + 1);
        Locals[High(Locals)] := VT;
      end;
      ExpectRParen;
    end;
  end;

  { Locals encoded as run-length groups, merging consecutive equal types. }
  GroupCount := 0;
  I := 0;
  while I < Length(Locals) do
  begin
    Inc(GroupCount);
    Inc(I);
    while (I < Length(Locals))
      and WatValueTypeEquals(Locals[I], Locals[I - 1]) do
      Inc(I);
  end;
  AEntry.WriteU32(UInt32(GroupCount));
  I := 0;
  while I < Length(Locals) do
  begin
    RunLen := 1;
    while (I + RunLen < Length(Locals))
      and WatValueTypeEquals(Locals[I + RunLen], Locals[I]) do
      Inc(RunLen);
    AEntry.WriteU32(UInt32(RunLen));
    AEntry.WriteValueType(Locals[I]);
    Inc(I, RunLen);
  end;

  { The body: FPos now sits at the first instruction (or the func ')'). }
  EmitInstrSeq(AEntry, False, AFunc.BodyEnd);
  AEntry.WriteByte($0B);   { terminating end }
end;

procedure TWatAssembler.EmitElemSegment(const AStart: Integer;
  var AOut: TWasmWriter);
var
  Declarative, HasTable, HasOffset, UsesExprs: Boolean;
  TableIdx: UInt32;
  OffStart, OffEnd: Integer;
  Funcs: array of UInt32;
  ItemS, ItemE: array of Integer;
  RefType: TWasmRefType;
  Flags, I: Integer;
  Off: TWasmWriter;

  procedure AddItem;
  begin
    SetLength(ItemS, Length(ItemS) + 1);
    SetLength(ItemE, Length(ItemE) + 1);
    if IsListHead('item') then
    begin
      ExpectLParen;
      ExpectKeyword('item');
      CaptureClauseContent(ItemS[High(ItemS)], ItemE[High(ItemE)]);
    end
    else
    begin
      ItemS[High(ItemS)] := FPos;
      SkipBalanced;
      ItemE[High(ItemE)] := FPos;
    end;
  end;

begin
  FPos := AStart;
  ExpectLParen;
  ExpectKeyword('elem');
  if Cur.Kind = wttIdentifier then
    Advance;   { id, already bound }

  Declarative := False;
  HasTable := False;
  HasOffset := False;
  UsesExprs := False;
  TableIdx := 0;
  OffStart := 0;
  OffEnd := 0;
  Funcs := nil;
  ItemS := nil;
  ItemE := nil;
  RefType := MakeRefType(True, MakeAbsHeapType(wahFunc));

  if IsKeyword('declare') then
  begin
    Advance;
    Declarative := True;
  end;

  if IsListHead('table') then
  begin
    ExpectLParen;
    ExpectKeyword('table');
    TableIdx := ReadIndex(wnsTable);
    ExpectRParen;
    HasTable := True;
  end;

  { Offset: `(offset expr)` or a folded-instruction abbreviation — a paren
    whose head is neither `item` nor a reftype clause. }
  if (not Declarative) and (Cur.Kind = wttLParen) and not IsListHead('item')
    and not ((At(1).Kind = wttKeyword) and (At(1).Text = 'ref')) then
  begin
    if IsListHead('offset') then
    begin
      ExpectLParen;
      ExpectKeyword('offset');
      CaptureClauseContent(OffStart, OffEnd);
    end
    else
    begin
      OffStart := FPos;
      SkipBalanced;
      OffEnd := FPos;
    end;
    HasOffset := True;
  end;

  { Element list. }
  if IsKeyword('func') then
  begin
    Advance;
    while (Cur.Kind = wttIdentifier) or (Cur.Kind = wttInteger) do
    begin
      SetLength(Funcs, Length(Funcs) + 1);
      Funcs[High(Funcs)] := ReadIndex(wnsFunc);
    end;
  end
  else if ((Cur.Kind = wttKeyword) and IsRefTypeShorthand(Cur.Text))
    or ((Cur.Kind = wttLParen) and (At(1).Text = 'ref')) then
  begin
    { A reftype then element EXPRESSIONS. }
    UsesExprs := True;
    RefType := ParseRefType;
    while Cur.Kind = wttLParen do
      AddItem;
  end
  else
  begin
    { Bare funcidx list (the `func` keyword elided). }
    while (Cur.Kind = wttIdentifier) or (Cur.Kind = wttInteger) do
    begin
      SetLength(Funcs, Length(Funcs) + 1);
      Funcs[High(Funcs)] := ReadIndex(wnsFunc);
    end;
  end;

  if UsesExprs then
  begin
    if Declarative then Flags := 7
    else if HasTable then Flags := 6
    else if HasOffset then Flags := 4
    else Flags := 5;
  end
  else
  begin
    if Declarative then Flags := 3
    else if HasTable then Flags := 2
    else if HasOffset then Flags := 0
    else Flags := 1;
  end;

  AOut.WriteU32(UInt32(Flags));
  case Flags of
    0:
      begin
        Off.Init; EmitConstExpr(Off, OffStart, OffEnd);
        AOut.AppendBytes(Off.ToBytes);
        AOut.WriteU32(UInt32(Length(Funcs)));
        for I := 0 to High(Funcs) do AOut.WriteU32(Funcs[I]);
      end;
    1:
      begin
        AOut.WriteByte($00);   { elemkind funcref }
        AOut.WriteU32(UInt32(Length(Funcs)));
        for I := 0 to High(Funcs) do AOut.WriteU32(Funcs[I]);
      end;
    2:
      begin
        AOut.WriteU32(TableIdx);
        Off.Init; EmitConstExpr(Off, OffStart, OffEnd);
        AOut.AppendBytes(Off.ToBytes);
        AOut.WriteByte($00);
        AOut.WriteU32(UInt32(Length(Funcs)));
        for I := 0 to High(Funcs) do AOut.WriteU32(Funcs[I]);
      end;
    3:
      begin
        AOut.WriteByte($00);
        AOut.WriteU32(UInt32(Length(Funcs)));
        for I := 0 to High(Funcs) do AOut.WriteU32(Funcs[I]);
      end;
    4:
      begin
        Off.Init; EmitConstExpr(Off, OffStart, OffEnd);
        AOut.AppendBytes(Off.ToBytes);
        AOut.WriteU32(UInt32(Length(ItemS)));
        for I := 0 to High(ItemS) do
        begin
          Off.Init; EmitConstExpr(Off, ItemS[I], ItemE[I]);
          AOut.AppendBytes(Off.ToBytes);
        end;
      end;
    5:
      begin
        AOut.WriteRefType(RefType);
        AOut.WriteU32(UInt32(Length(ItemS)));
        for I := 0 to High(ItemS) do
        begin
          Off.Init; EmitConstExpr(Off, ItemS[I], ItemE[I]);
          AOut.AppendBytes(Off.ToBytes);
        end;
      end;
    6:
      begin
        AOut.WriteU32(TableIdx);
        Off.Init; EmitConstExpr(Off, OffStart, OffEnd);
        AOut.AppendBytes(Off.ToBytes);
        AOut.WriteRefType(RefType);
        AOut.WriteU32(UInt32(Length(ItemS)));
        for I := 0 to High(ItemS) do
        begin
          Off.Init; EmitConstExpr(Off, ItemS[I], ItemE[I]);
          AOut.AppendBytes(Off.ToBytes);
        end;
      end;
    7:
      begin
        AOut.WriteRefType(RefType);
        AOut.WriteU32(UInt32(Length(ItemS)));
        for I := 0 to High(ItemS) do
        begin
          Off.Init; EmitConstExpr(Off, ItemS[I], ItemE[I]);
          AOut.AppendBytes(Off.ToBytes);
        end;
      end;
  end;
end;

procedure TWatAssembler.EmitDataSegment(const AStart: Integer;
  var AOut: TWasmWriter);
var
  HasMem, HasOffset: Boolean;
  MemIdx: UInt32;
  OffStart, OffEnd, I, J: Integer;
  Payload: TWasmBytes;
  Off: TWasmWriter;
begin
  FPos := AStart;
  ExpectLParen;
  ExpectKeyword('data');
  if Cur.Kind = wttIdentifier then
    Advance;

  HasMem := False;
  HasOffset := False;
  MemIdx := 0;
  OffStart := 0;
  OffEnd := 0;

  if IsListHead('memory') then
  begin
    ExpectLParen;
    ExpectKeyword('memory');
    MemIdx := ReadIndex(wnsMem);
    ExpectRParen;
    HasMem := True;
  end
  else if (Cur.Kind = wttInteger) or (Cur.Kind = wttIdentifier) then
  begin
    { The memuse may also be a BARE memidx (`(data 0 (offset) …)`), the
      abbreviation for `(memory 0)` — text-memuse. The segment id, if any, was
      already taken above, so a remaining index token here is the memory use. }
    MemIdx := ReadIndex(wnsMem);
    HasMem := True;
  end;

  if Cur.Kind = wttLParen then
  begin
    if IsListHead('offset') then
    begin
      ExpectLParen;
      ExpectKeyword('offset');
      CaptureClauseContent(OffStart, OffEnd);
    end
    else
    begin
      OffStart := FPos;
      SkipBalanced;
      OffEnd := FPos;
    end;
    HasOffset := True;
  end;

  { The payload: a possibly empty sequence of string literals (raw bytes). }
  Payload := nil;
  while Cur.Kind = wttString do
  begin
    J := Length(Payload);
    SetLength(Payload, J + Length(Cur.Bytes));
    for I := 0 to High(Cur.Bytes) do
      Payload[J + I] := Cur.Bytes[I];
    Advance;
  end;

  { The field must close now. A leftover token means a malformed segment: a
    RESERVED run from something like `$l"a"` (an id glued to a string with no
    separator) is `unknown operator`, any other stray token `unexpected token`
    — both via RaiseUnexpected (token.wast:153-273). }
  if Cur.Kind <> wttRParen then
    RaiseUnexpected;

  if not HasOffset then
  begin
    AOut.WriteU32(1);   { passive }
  end
  else if HasMem then
  begin
    AOut.WriteU32(2);
    AOut.WriteU32(MemIdx);
    Off.Init; EmitConstExpr(Off, OffStart, OffEnd); AOut.AppendBytes(Off.ToBytes);
  end
  else
  begin
    AOut.WriteU32(0);
    Off.Init; EmitConstExpr(Off, OffStart, OffEnd); AOut.AppendBytes(Off.ToBytes);
  end;
  AOut.WriteU32(UInt32(Length(Payload)));
  AOut.AppendBytes(Payload);
end;

procedure TWatAssembler.WriteZeroOffsetExpr(var AOut: TWasmWriter);
begin
  { The synthetic active-segment offset that desugared inline elem/data
    segments all sit at: the const expr `(i32.const 0)`, i.e. i32.const ($41),
    a zero sLEB, and the end delimiter ($0B). }
  AOut.WriteByte($41);
  AOut.WriteS32(0);
  AOut.WriteByte($0B);
end;

procedure TWatAssembler.EmitInlineElemSegment(const ADecl: TInlineElemDecl;
  var AOut: TWasmWriter);
var
  Saved, ItemStart, ItemEnd: Integer;
  TableIdx: UInt32;
  Off: TWasmWriter;
begin
  { A desugared inline table-elem: an ACTIVE segment at offset (i32.const 0)
    over this table. The explicit-table flags (2 for a funcidx list, 6 for an
    expression list) work for any table index, which the elided-table sugar
    could not name. }
  Saved := FPos;
  TableIdx := UInt32(FTables[ADecl.TableDeclIndex].FinalIndex);
  FPos := ADecl.ListStart;
  if ADecl.UsesExprs then
  begin
    AOut.WriteU32(6);
    AOut.WriteU32(TableIdx);
    WriteZeroOffsetExpr(AOut);
    AOut.WriteRefType(ADecl.RefType);
    AOut.WriteU32(UInt32(ADecl.ElemCount));
    while FPos < ADecl.ListEnd do
    begin
      if IsListHead('item') then
      begin
        ExpectLParen;
        ExpectKeyword('item');
        CaptureClauseContent(ItemStart, ItemEnd);
      end
      else
      begin
        ItemStart := FPos;
        SkipBalanced;
        ItemEnd := FPos;
      end;
      Off.Init; EmitConstExpr(Off, ItemStart, ItemEnd);
      AOut.AppendBytes(Off.ToBytes);
    end;
  end
  else
  begin
    AOut.WriteU32(2);
    AOut.WriteU32(TableIdx);
    WriteZeroOffsetExpr(AOut);
    AOut.WriteByte($00);   { elemkind funcref }
    AOut.WriteU32(UInt32(ADecl.ElemCount));
    while FPos < ADecl.ListEnd do
      AOut.WriteU32(ReadIndex(wnsFunc));
  end;
  FPos := Saved;
end;

procedure TWatAssembler.EmitInlineDataSegment(const ADecl: TInlineDataDecl;
  var AOut: TWasmWriter);
var
  MemIdx: UInt32;
begin
  { A desugared inline memory-data: an ACTIVE segment at offset (i32.const 0)
    over this memory, written with the explicit-memidx flag (2) so any memory
    index encodes. }
  MemIdx := UInt32(FMems[ADecl.MemDeclIndex].FinalIndex);
  AOut.WriteU32(2);
  AOut.WriteU32(MemIdx);
  WriteZeroOffsetExpr(AOut);
  AOut.WriteU32(UInt32(Length(ADecl.Payload)));
  AOut.AppendBytes(ADecl.Payload);
end;

procedure TWatAssembler.CollectExports(var AList: TArray<TExpDecl>);

  procedure AddInline(const ANames: TArray<string>; const AKind: TWasmExternKind;
    const AIndex: Integer);
  var
    K: Integer;
    E: TExpDecl;
  begin
    for K := 0 to High(ANames) do
    begin
      E := Default(TExpDecl);
      E.Name := ANames[K];
      E.Kind := AKind;
      E.Resolved := True;
      E.Index := UInt32(AIndex);
      SetLength(AList, Length(AList) + 1);
      AList[High(AList)] := E;
    end;
  end;

  function SpaceForKind(const AKind: TWasmExternKind): TWatSpace;
  begin
    case AKind of
      wxkFunc:   Result := wnsFunc;
      wxkTable:  Result := wnsTable;
      wxkMem:    Result := wnsMem;
      wxkGlobal: Result := wnsGlobal;
    else
      Result := wnsTag;
    end;
  end;

var
  I: Integer;
  E: TExpDecl;
begin
  AList := nil;
  { Inline exports, in entity order: imports, funcs, tables, mems, globals,
    tags. }
  for I := 0 to High(FImports) do
    AddInline(FImports[I].InlineExports, FImports[I].Kind,
      FImports[I].FinalIndex);
  for I := 0 to High(FFuncs) do
    AddInline(FFuncs[I].InlineExports, wxkFunc, FFuncs[I].FinalIndex);
  for I := 0 to High(FTables) do
    AddInline(FTables[I].InlineExports, wxkTable, FTables[I].FinalIndex);
  for I := 0 to High(FMems) do
    AddInline(FMems[I].InlineExports, wxkMem, FMems[I].FinalIndex);
  for I := 0 to High(FGlobals) do
    AddInline(FGlobals[I].InlineExports, wxkGlobal, FGlobals[I].FinalIndex);
  for I := 0 to High(FTags) do
    AddInline(FTags[I].InlineExports, wxkTag, FTags[I].FinalIndex);

  { Explicit exports: resolve the operand now that every name is bound. }
  for I := 0 to High(FExports) do
  begin
    E := FExports[I];
    FPos := E.RefTok;
    E.Index := ReadIndex(SpaceForKind(E.Kind));
    E.Resolved := True;
    SetLength(AList, Length(AList) + 1);
    AList[High(AList)] := E;
  end;
end;

function TWatAssembler.BuildModule: TWasmBytes;
var
  Emitter: TWasmModuleEmitter;
  Body, Entry: TWasmWriter;
  AllExports: TArray<TExpDecl>;
  I: Integer;
  StartIndex: UInt32;
  EntryBytes: TWasmBytes;
begin
  Emitter := TWasmModuleEmitter.Create;
  try
    { The type section is built LAST (below), after every function body and
      const expression has been walked, so any type interned by a body-level
      typeuse (call_indirect, a multi-value blocktype) is included. The
      emitter reorders sections into the prescribed encoding order regardless
      of the order they are added, so building types last is purely a
      completeness fix, not a section-order one. }

    { Import section. }
    if Length(FImports) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FImports)));
      for I := 0 to High(FImports) do
      begin
        WriteName(Body, FImports[I].ModuleName);
        WriteName(Body, FImports[I].Name);
        Body.WriteByte(Ord(FImports[I].Kind));
        case FImports[I].Kind of
          wxkFunc:   Body.WriteU32(FImports[I].TypeIndex);
          wxkTable:  Body.WriteTableType(FImports[I].Table);
          wxkMem:    Body.WriteMemType(FImports[I].Mem);
          wxkGlobal: Body.WriteGlobalType(FImports[I].Global);
          wxkTag:    Body.WriteTagType(MakeTagType(FImports[I].TypeIndex));
        end;
      end;
      Emitter.AddSection(wsImport, Body.ToBytes);
    end;

    { Function section. }
    if Length(FFuncs) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FFuncs)));
      for I := 0 to High(FFuncs) do
        Body.WriteU32(FFuncs[I].TypeIndex);
      Emitter.AddSection(wsFunction, Body.ToBytes);
    end;

    { Table section. }
    if Length(FTables) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FTables)));
      for I := 0 to High(FTables) do
        Body.WriteTableType(FTables[I].TableType);
      Emitter.AddSection(wsTable, Body.ToBytes);
    end;

    { Memory section. }
    if Length(FMems) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FMems)));
      for I := 0 to High(FMems) do
        Body.WriteMemType(FMems[I].MemType);
      Emitter.AddSection(wsMemory, Body.ToBytes);
    end;

    { Tag section. }
    if Length(FTags) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FTags)));
      for I := 0 to High(FTags) do
        Body.WriteTagType(MakeTagType(FTags[I].TypeIndex));
      Emitter.AddSection(wsTag, Body.ToBytes);
    end;

    { Global section. }
    if Length(FGlobals) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FGlobals)));
      for I := 0 to High(FGlobals) do
      begin
        Body.WriteGlobalType(FGlobals[I].GlobalType);
        EmitConstExpr(Body, FGlobals[I].InitStart, FGlobals[I].InitEnd);
      end;
      Emitter.AddSection(wsGlobal, Body.ToBytes);
    end;

    { Export section. }
    CollectExports(AllExports);
    if Length(AllExports) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(AllExports)));
      for I := 0 to High(AllExports) do
      begin
        WriteName(Body, AllExports[I].Name);
        Body.WriteByte(Ord(AllExports[I].Kind));
        Body.WriteU32(AllExports[I].Index);
      end;
      Emitter.AddSection(wsExport, Body.ToBytes);
    end;

    { Start section. }
    if FHasStart then
    begin
      FPos := FStartTok;
      StartIndex := ReadIndex(wnsFunc);
      Body.Init;
      Body.WriteU32(StartIndex);
      Emitter.AddSection(wsStart, Body.ToBytes);
    end;

    { Element section — explicit segments then the segments desugared from
      inline `(table … (elem …))` forms (§2(c.5)). }
    if Length(FElems) + Length(FInlineElems) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FElems) + Length(FInlineElems)));
      for I := 0 to High(FElems) do
        EmitElemSegment(FElems[I].FieldStart, Body);
      for I := 0 to High(FInlineElems) do
        EmitInlineElemSegment(FInlineElems[I], Body);
      Emitter.AddSection(wsElement, Body.ToBytes);
    end;

    { Code section. Built before the data-count section because walking the
      bodies is what discovers a data index in code (memory.init, data.drop,
      array.new_data/init_data), which is exactly what makes the data-count
      section mandatory (§2e; binary-module: a data count section is required
      if a data index occurs in code). The emitter reorders both into the
      prescribed encoding order regardless of the order they are added. }
    if Length(FFuncs) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FFuncs)));
      for I := 0 to High(FFuncs) do
      begin
        Entry.Init;
        EmitFuncLocalsAndBody(FFuncs[I], Entry);
        EntryBytes := Entry.ToBytes;
        Body.WriteU32(UInt32(Length(EntryBytes)));
        Body.AppendBytes(EntryBytes);
      end;
      Emitter.AddSection(wsCode, Body.ToBytes);
    end;

    { Data count section — emitted whenever there is a data section, OR a data
      index occurs in code even with no data segments (§2e). The count is the
      number of data segments (0 is legal: memory_init.wast:189's `data.drop 0`
      then decodes and the validator rejects the index as `unknown data
      segment`, rather than our own decoder rejecting our output). }
    if (Length(FDatas) + Length(FInlineDatas) > 0) or FUsesDataIndex then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FDatas) + Length(FInlineDatas)));
      Emitter.AddSection(wsDataCount, Body.ToBytes);
    end;

    { Data section — explicit segments then the segments desugared from inline
      `(memory (data …))` forms (§2(c.5)). }
    if Length(FDatas) + Length(FInlineDatas) > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(Length(FDatas) + Length(FInlineDatas)));
      for I := 0 to High(FDatas) do
        EmitDataSegment(FDatas[I].FieldStart, Body);
      for I := 0 to High(FInlineDatas) do
        EmitInlineDataSegment(FInlineDatas[I], Body);
      Emitter.AddSection(wsData, Body.ToBytes);
    end;

    { Type section — built last so body-interned types are captured (see the
      note at the top of this method). The emitter places it first. }
    if FNames.TypeGroupCount > 0 then
    begin
      Body.Init;
      Body.WriteU32(UInt32(FNames.TypeGroupCount));
      for I := 0 to FNames.TypeGroupCount - 1 do
        Body.WriteType(FNames.TypeGroup(I));
      Emitter.AddSection(wsType, Body.ToBytes);
    end;

    Result := Emitter.Finish;
  finally
    Emitter.Free;
  end;
end;

function TWatAssembler.Run(const ASource: TWasmBytes): TWasmBytes;
var
  Lexer: TWatLexer;
  Tok: TWatToken;
  Wrapped: Boolean;
begin
  { Tokenize the whole source once; malformed tokens surface here as text
    errors (correctly). }
  Lexer.Init(ASource);
  FToks := nil;
  repeat
    Tok := Lexer.Next;
    SetLength(FToks, Length(FToks) + 1);
    FToks[High(FToks)] := Tok;
  until Tok.Kind = wttEof;

  FPos := 0;
  Wrapped := False;
  if IsListHead('module') then
  begin
    Wrapped := True;
    ExpectLParen;
    ExpectKeyword('module');
    if Cur.Kind = wttIdentifier then
      Advance;   { the module id is the runner's registry, not ours (§2c.7) }
  end;

  FFieldsStart := FPos;

  { Pass 0: bind every type member's identifier to its index, so a type body
    may forward-reference any type by name (§2b). }
  while Cur.Kind = wttLParen do
  begin
    if IsListHead('type') or IsListHead('rec') then
      PreBindTypeField
    else
      SkipBalanced;
  end;

  { Sub-pass 1a: collect every EXPLICIT type (names already bound above). }
  FPos := FFieldsStart;
  while Cur.Kind = wttLParen do
  begin
    if IsListHead('type') or IsListHead('rec') then
      ParseTypeField
    else
      SkipBalanced;
  end;

  { Sub-pass 1b: declare everything, interning implicit typeuses in appearance
    order. }
  FPos := FFieldsStart;
  while Cur.Kind = wttLParen do
    DeclareField;

  AssignIndices;

  if Wrapped then
    ExpectRParen;
  if Cur.Kind <> wttEof then
    RaiseUnexpected;

  Result := BuildModule;
end;

{ --- entry points ------------------------------------------------------- }

function AssembleWat(const ASource: TWasmBytes): TWasmBytes;
var
  A: TWatAssembler;
begin
  A := TWatAssembler.Create;
  try
    Result := A.Run(ASource);
  finally
    A.Free;
  end;
end;

function AssembleWatText(const AText: string): TWasmBytes;
var
  Bytes: TWasmBytes;
  I: Integer;
begin
  SetLength(Bytes, Length(AText));
  for I := 1 to Length(AText) do
    Bytes[I - 1] := Byte(Ord(AText[I]) and $FF);
  Result := AssembleWat(Bytes);
end;

function AssembleQuote(const APayload: TWasmBytes): TWasmBytes;
begin
  Result := AssembleWat(APayload);
end;

end.
