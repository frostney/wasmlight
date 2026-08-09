{ Unit suite for Wasm.Validator — module-level validation and the public
  ValidateModule entry point.

  Every case is a real module assembled byte by byte and pushed through
  the real decoder, so whatever ValidateModule rejects below is a module
  the BINARY grammar accepted: the malformed/invalid boundary is the
  premise of the suite, not an incidental detail, and each negative
  asserts the exception CLASS as well as the canonical message prefix. A
  case that failed to decode would be vacuous rather than passing, so the
  helper reports a decode error as a distinct outcome.

  The positives assert the returned TWasmIrModule's SURFACE — the counts,
  the index-space snapshots, the export list, the canonical type ids, and
  the format stamp — because that surface is what Track D and Track E
  consume, and because ValidateModule's real job is assembling it. Per-
  instruction IR text belongs to Wasm.Validator.Body.Test and
  Wasm.Validator.Const.Test and is not restated here.

  Spec anchors are cited per group, read from wasm-mcp 0.2.16 at the
  pinned commit d7b37e4170d8315f2f1283aed4e8076591a9a333.

  `Wasm.Validator.&Const` is spelled with FPC's identifier escape because
  `const` is a reserved word; see that unit's header. }
program Wasm.Validator.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator,
  Wasm.Validator.Types;

type
  { A growable byte buffer, so a section's size prefix is computed rather
    than hand-counted — a miscounted length would surface as a decode
    error and disguise whatever the case was actually about. }
  TByteBuf = record
    Data: TWasmBytes;
    Count: Integer;

    procedure Reset;
    procedure Add(const AValue: Byte);
    procedure AddMany(const AValues: array of Byte);
    procedure AddU32(const AValue: UInt32);
    procedure Section(const AId: TWasmSectionId;
      const ABody: array of Byte);
    function Finish: TWasmBytes;
  end;

  TValidatorTests = class(TTestSuite)
  private
    { The decoded module and the IR both borrow this buffer (ADR-0003),
      so it must outlive them. }
    FBytes: TWasmBytes;
    FBuf: TByteBuf;
    FModule: TWasmModule;
    FIr: TWasmIrModule;

    procedure StartModule;
    procedure Sect(const AId: TWasmSectionId; const ABody: array of Byte);
    { Decodes what has been built so far and validates it into FIr. }
    procedure FinishAndValidate;

    function PrefixOutcome(const AMessage, APrefix: string): string;
    { Validates whatever has been built and reports the outcome as one
      string: 'rejected: <prefix>' when the prefix matched, and anything
      else — 'ACCEPTED', a different message, a decode error — verbatim,
      so a case that fails for the wrong reason says which. }
    function RejectionOf(const APrefix: string): string;
    { Builds the fixed multi-section module every positive leans on. }
    procedure BuildKitchenSink;
    procedure ExpectCount(const AWhat: string;
      const AActual, AExpected: Integer);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestKitchenSinkValidates;
    procedure TestKitchenSinkIndexSpaces;
    procedure TestKitchenSinkTypesAndFunctions;
    procedure TestKitchenSinkSegmentsAndStart;
    procedure TestConstExprRefFuncDeclaresTheFunction;
    procedure TestUndeclaredWithoutThatConstExpr;
    procedure TestTableWithInitExpression;
    procedure TestDeclarativeElemEnablesRefFunc;
    procedure TestI64MemoryAndItsDataOffset;
    procedure TestDuplicateImportNamesAreAccepted;
    procedure TestNonNullElemSegmentIntoAFuncrefTable;
    procedure TestFuncidxShorthandIntoANonNullableTable;
    procedure TestImpliedFuncrefExprFormIntoANonNullableTable;

    procedure TestRejectsDuplicateExportName;
    procedure TestRejectsMemory64OverThePageLimit;
    procedure TestRejectsDefinedMemoryWithMinAboveMax;
    procedure TestRejectsDefinedTableWithMinAboveMax;
    procedure TestRejectsTableOverTheSizeLimit;
    procedure TestRejectsStartIndexOutOfRange;
    procedure TestRejectsStartWithResults;
    procedure TestRejectsExportsInEveryOtherSpace;
    procedure TestElemItemsAreCheckedBeforeTheTable;
    procedure TestRejectsStartWithParameters;
    procedure TestRejectsNonDefaultableTableWithoutInit;
    procedure TestRejectsElementReferenceTypeMismatch;
    procedure TestRejectsI32OffsetOnI64Table;
    procedure TestRejectsGlobalReadingALaterGlobal;
    procedure TestRejectsTableInitReadingADefinedGlobal;
    procedure TestRejectsTagWithResults;
    procedure TestRejectsMemoryOverThePageLimit;
    procedure TestRejectsImportedLimitsWithMinAboveMax;
    procedure TestRejectsExportOfAMissingFunction;
  end;

{ --- TByteBuf ------------------------------------------------------------ }

procedure TByteBuf.Reset;
begin
  Data := nil;
  Count := 0;
end;

procedure TByteBuf.Add(const AValue: Byte);
begin
  if Count >= Length(Data) then
    SetLength(Data, (Count + 1) * 2);
  Data[Count] := AValue;
  Inc(Count);
end;

procedure TByteBuf.AddMany(const AValues: array of Byte);
var
  I: Integer;
begin
  for I := 0 to High(AValues) do
    Add(AValues[I]);
end;

procedure TByteBuf.AddU32(const AValue: UInt32);
var
  Rest: UInt32;
begin
  Rest := AValue;
  repeat
    if Rest < $80 then
      Add(Byte(Rest))
    else
      Add(Byte((Rest and $7F) or $80));
    Rest := Rest shr 7;
  until Rest = 0;
end;

procedure TByteBuf.Section(const AId: TWasmSectionId;
  const ABody: array of Byte);
begin
  Add(Ord(AId));
  AddU32(UInt32(Length(ABody)));
  AddMany(ABody);
end;

function TByteBuf.Finish: TWasmBytes;
begin
  SetLength(Data, Count);
  Result := Data;
end;

{ --- fixture ------------------------------------------------------------- }

procedure TValidatorTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FIr := nil;
end;

procedure TValidatorTests.AfterEach;
begin
  FreeAndNil(FIr);
  FreeAndNil(FModule);
end;

procedure TValidatorTests.StartModule;
begin
  FBuf.Reset;
  FBuf.AddMany([$00, $61, $73, $6D, $01, $00, $00, $00]);
end;

procedure TValidatorTests.Sect(const AId: TWasmSectionId;
  const ABody: array of Byte);
begin
  FBuf.Section(AId, ABody);
end;

procedure TValidatorTests.FinishAndValidate;
begin
  FBytes := FBuf.Finish;
  DecodeModule(FBytes, FModule);
  FreeAndNil(FIr);
  FIr := ValidateModule(FModule, FBytes);
end;

function TValidatorTests.PrefixOutcome(const AMessage,
  APrefix: string): string;
begin
  if Copy(AMessage, 1, Length(APrefix)) = APrefix then
    Result := 'rejected: ' + APrefix
  else
    Result := 'rejected with message: ' + AMessage;
end;

function TValidatorTests.RejectionOf(const APrefix: string): string;
begin
  Result := 'ACCEPTED';
  try
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Result := PrefixOutcome(E.Message, APrefix);
    on E: EWasmDecodeError do
      Result := 'decode error: ' + E.Message;
  end;
end;

procedure TValidatorTests.ExpectCount(const AWhat: string;
  const AActual, AExpected: Integer);
begin
  { Phrased as a labelled comparison so a failure names the field rather
    than reporting two bare numbers. }
  Expect<string>(Format('%s=%d', [AWhat, AActual]))
    .ToBe(Format('%s=%d', [AWhat, AExpected]));
end;

{ --- the multi-section module -------------------------------------------- }

{ One module touching every index space, in the binary format's PRESCRIBED
  section order (which is not id order: tag sits between memory and global,
  and data count before code — Wasm.Core.SectionOrderPosition).

    type 0    (func)
    type 1    (func (param i32) (result i32))
    type 2    (func (param i32))            -- the tag's type
    type 3    (struct (field i32))          -- unused, exercises the space

    import 0  "env"."f" (func (type 1))     -> func   0
    import 1  "env"."t" (table 1 funcref)   -> table  0
    import 2  "env"."m" (memory 1)          -> memory 0
    import 3  "env"."g" (global i32)        -> global 0
    import 4  "env"."e" (tag (type 2))      -> tag    0

    func   1  (type 1)   body: local.get 0
    func   2  (type 0)   body: ref.func 1; drop
    table  1  funcref 2
    table  2  externref 1, initialised with (ref.null extern)
    memory 1  1
    tag    1  (type 2)
    global 1  i32       = global.get 0      -- an IMPORTED global
    global 2  funcref   = ref.func 1        -- puts func 1 into C.REFS
    exports   "a" func 1, "b" table 1, "c" memory 0, "d" global 1,
              "h" tag 0
    start     func 2
    elem 0    active table 1, offset (i32.const 0), funcidx [1, 2]
    elem 1    declarative, funcref, [(ref.func 2)]
    data 0    passive "hi"
    data 1    active memory 0, offset (i32.const 0), "hi" }
procedure TValidatorTests.BuildKitchenSink;
begin
  StartModule;

  Sect(wsType, [$04,
    $60, $00, $00,
    $60, $01, $7F, $01, $7F,
    $60, $01, $7F, $00,
    $5F, $01, $7F, $00]);

  Sect(wsImport, [$05,
    $03, $65, $6E, $76, $01, $66, $00, $01,
    $03, $65, $6E, $76, $01, $74, $01, $70, $00, $01,
    $03, $65, $6E, $76, $01, $6D, $02, $00, $01,
    $03, $65, $6E, $76, $01, $67, $03, $7F, $00,
    $03, $65, $6E, $76, $01, $65, $04, $00, $02]);

  Sect(wsFunction, [$02, $01, $00]);

  { The second table uses the 3.0 with-initialiser form: the $40 marker,
    a reserved zero byte, the table type, then a constant expression. }
  Sect(wsTable, [$02,
    $70, $00, $02,
    $40, $00, $6F, $00, $01, $D0, $6F, $0B]);

  Sect(wsMemory, [$01, $00, $01]);
  Sect(wsTag, [$01, $00, $02]);

  Sect(wsGlobal, [$02,
    $7F, $00, $23, $00, $0B,
    $70, $00, $D2, $01, $0B]);

  Sect(wsExport, [$05,
    $01, $61, $00, $01,
    $01, $62, $01, $01,
    $01, $63, $02, $00,
    $01, $64, $03, $01,
    $01, $68, $04, $00]);

  Sect(wsStart, [$02]);

  Sect(wsElement, [$02,
    $02, $01, $41, $00, $0B, $00, $02, $01, $02,
    $07, $70, $01, $D2, $02, $0B]);

  Sect(wsDataCount, [$02]);

  Sect(wsCode, [$02,
    $04, $00, $20, $00, $0B,
    $05, $00, $D2, $01, $1A, $0B]);

  Sect(wsData, [$02,
    $01, $02, $68, $69,
    $00, $41, $00, $0B, $02, $68, $69]);

  FinishAndValidate;
end;

{ --- positives ----------------------------------------------------------- }

procedure TValidatorTests.TestKitchenSinkValidates;
begin
  { `valid-module`: the phases of §6.1 run in order and every one of them
    has something to do in this module. }
  BuildKitchenSink;
  Expect<Boolean>(FIr <> nil).ToBe(True);
  { ADR-0007: the stamp an ahead-of-time artifact is rejected against. }
  ExpectCount('FormatVersion', Integer(FIr.FormatVersion),
    IR_FORMAT_VERSION);
end;

procedure TValidatorTests.TestKitchenSinkIndexSpaces;
begin
  { Every index space counts imports FIRST, and the import counts are what
    tells a consumer where the module's own definitions begin. }
  BuildKitchenSink;

  ExpectCount('funcs', Length(FIr.FuncCanonTypes), 3);
  ExpectCount('funcImports', Integer(FIr.FuncImportCount), 1);
  Expect<Boolean>(FIr.FuncIsImported[0]).ToBe(True);
  Expect<Boolean>(FIr.FuncIsImported[1]).ToBe(False);
  Expect<Boolean>(FIr.FuncIsImported[2]).ToBe(False);

  ExpectCount('tables', Length(FIr.Tables), 3);
  ExpectCount('tableImports', Integer(FIr.TableImportCount), 1);
  ExpectCount('memories', Length(FIr.Memories), 2);
  ExpectCount('memoryImports', Integer(FIr.MemoryImportCount), 1);
  ExpectCount('globals', Length(FIr.Globals), 3);
  ExpectCount('globalImports', Integer(FIr.GlobalImportCount), 1);
  ExpectCount('tags', Length(FIr.Tags), 2);
  ExpectCount('tagImports', Integer(FIr.TagImportCount), 1);

  { The snapshots carry the TYPES, not just the counts. }
  Expect<string>(FIr.Tables[1].RefType.Describe).ToBe('funcref');
  Expect<string>(FIr.Tables[2].RefType.Describe).ToBe('externref');
  Expect<Boolean>(FIr.Globals[1].Mut).ToBe(False);

  ExpectCount('exports', Length(FIr.ExportList), 5);
  Expect<string>(FIr.ExportList[0].Name).ToBe('a');
  ExpectCount('export0.kind', Ord(FIr.ExportList[0].Kind), Ord(wxkFunc));
  ExpectCount('export0.index', Integer(FIr.ExportList[0].Index), 1);
  Expect<string>(FIr.ExportList[4].Name).ToBe('h');
  ExpectCount('export4.kind', Ord(FIr.ExportList[4].Kind), Ord(wxkTag));
end;

procedure TValidatorTests.TestKitchenSinkTypesAndFunctions;
var
  I: Integer;
  DistinctCanonIds: Boolean;
begin
  BuildKitchenSink;

  { Four structurally distinct types, so canonicalisation interns four
    (`appendix/algorithm-types`) and every module type index maps to one
    of them. }
  ExpectCount('canonTypes', Length(FIr.CanonTypes), 4);
  ExpectCount('typeIndexToCanon', Length(FIr.TypeIndexToCanon), 4);
  ExpectCount('groupKeys', Length(FIr.GroupKeys), 4);

  DistinctCanonIds := True;
  for I := 0 to High(FIr.TypeIndexToCanon) do
    if FIr.TypeIndexToCanon[I] >= UInt32(Length(FIr.CanonTypes)) then
      DistinctCanonIds := False;
  Expect<Boolean>(DistinctCanonIds).ToBe(True);

  { The imported function's canonical id is type 1's, and the tag's is
    type 2's — the two spaces are described in the same canonical
    space. }
  ExpectCount('func0.canon', Integer(FIr.FuncCanonTypes[0]),
    Integer(FIr.TypeIndexToCanon[1]));
  ExpectCount('tag0.canon', Integer(FIr.Tags[0]),
    Integer(FIr.TypeIndexToCanon[2]));

  { Two code entries, in code order, each with real IR behind it. }
  ExpectCount('functions', Length(FIr.Functions), 2);
  ExpectCount('fn0.typeIndex', Integer(FIr.Functions[0].TypeIndex), 1);
  ExpectCount('fn0.params', Integer(FIr.Functions[0].ParamCount), 1);
  ExpectCount('fn0.results', Integer(FIr.Functions[0].ResultCount), 1);
  Expect<Boolean>(Length(FIr.Functions[0].Code) > 0).ToBe(True);
  Expect<Boolean>(Length(FIr.Functions[1].Code) > 0).ToBe(True);
  Expect<Boolean>(FIr.Functions[0].RegisterCount > 0).ToBe(True);
  { The register-type table is the ADR-0011 projection's source and must
    be sized to the frame. }
  ExpectCount('fn0.regTypes', Length(FIr.Functions[0].RegTypes),
    Integer(FIr.Functions[0].RegisterCount));
end;

procedure TValidatorTests.TestKitchenSinkSegmentsAndStart;
begin
  BuildKitchenSink;

  { Initialiser IR is per DEFINED entity, not per index space. }
  ExpectCount('globalInits', Length(FIr.GlobalInits), 2);
  ExpectCount('tableInits', Length(FIr.TableInits), 2);
  { Table 1 has no initialiser, table 2 does. }
  ExpectCount('tableInit0.code', Length(FIr.TableInits[0].Code), 0);
  Expect<Boolean>(Length(FIr.TableInits[1].Code) > 0).ToBe(True);

  ExpectCount('elems', Length(FIr.Elems), 2);
  ExpectCount('elem0.mode', Ord(FIr.Elems[0].Mode), Ord(iremActive));
  ExpectCount('elem0.table', Integer(FIr.Elems[0].TableIndex), 1);
  { The funcidx-vector form is normalised into init expressions, so both
    segments are read through one code path. }
  ExpectCount('elem0.items', Length(FIr.Elems[0].Items), 2);
  Expect<Boolean>(Length(FIr.Elems[0].Offset.Code) > 0).ToBe(True);
  ExpectCount('elem1.mode', Ord(FIr.Elems[1].Mode), Ord(iremDeclarative));
  ExpectCount('elem1.items', Length(FIr.Elems[1].Items), 1);

  ExpectCount('datas', Length(FIr.Datas), 2);
  ExpectCount('data0.mode', Ord(FIr.Datas[0].Mode), Ord(irdmPassive));
  ExpectCount('data1.mode', Ord(FIr.Datas[1].Mode), Ord(irdmActive));
  { Payload bytes stay a borrowed span into the module buffer
    (ADR-0003) — "hi" is two bytes, located, not copied. }
  ExpectCount('data0.bytes', Integer(FIr.Datas[0].Bytes.Size), 2);

  Expect<Boolean>(FIr.HasStart).ToBe(True);
  ExpectCount('start', Integer(FIr.StartFuncIndex), 2);

  { C.REFS (`context`). Func 1 is named by the export list, the element
    segment and global 2's initialiser; func 2 by the start section and
    the declarative segment. The imported func 0 is named nowhere. }
  ExpectCount('declaredFuncRefs', Length(FIr.DeclaredFuncRefs), 3);
  Expect<Boolean>(FIr.DeclaredFuncRefs[0]).ToBe(False);
  Expect<Boolean>(FIr.DeclaredFuncRefs[1]).ToBe(True);
  Expect<Boolean>(FIr.DeclaredFuncRefs[2]).ToBe(True);
end;

{ The union that Wasm.Validator owns. BuildDeclaredFuncSet deliberately
  cannot see `ref.func` inside a constant expression, so a module whose
  ONLY declaration of a body-referenced function is a global initialiser
  is exactly the case a missing union rejects. }
procedure TValidatorTests.TestConstExprRefFuncDeclaresTheFunction;
begin
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  { (global funcref (ref.func 0)) — the sole declaration of func 0. }
  Sect(wsGlobal, [$01, $70, $00, $D2, $00, $0B]);
  { (func (ref.func 0) (drop)) }
  Sect(wsCode, [$01, $05, $00, $D2, $00, $1A, $0B]);
  FinishAndValidate;

  ExpectCount('declaredFuncRefs', Length(FIr.DeclaredFuncRefs), 1);
  Expect<Boolean>(FIr.DeclaredFuncRefs[0]).ToBe(True);
  ExpectCount('globalInits', Length(FIr.GlobalInits), 1);
  Expect<Boolean>(Length(FIr.Functions[0].Code) > 0).ToBe(True);
end;

{ The twin of the case above, with the global removed. Without it nothing
  declares func 0, so `ref.func 0` in the body must fail — which is what
  makes the positive non-vacuous. }
procedure TValidatorTests.TestUndeclaredWithoutThatConstExpr;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsType, [$01, $60, $00, $00]);
    Sect(wsFunction, [$01, $00]);
    Sect(wsCode, [$01, $05, $00, $D2, $00, $1A, $0B]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message,
        MSG_UNDECLARED_FUNCTION_REFERENCE);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome)
    .ToBe('rejected: ' + MSG_UNDECLARED_FUNCTION_REFERENCE);
end;

procedure TValidatorTests.TestTableWithInitExpression;
begin
  { `valid-table`, the with-initialiser form: the expression is constant
    and matches the element type, so a NON-defaultable element type is
    fine here — which is the whole reason the form exists. }
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  { (table 1 (ref func) (ref.func 0)) — element type $64 $70 is the long,
    non-nullable form. }
  Sect(wsTable, [$01, $40, $00, $64, $70, $00, $01, $D2, $00, $0B]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;

  ExpectCount('tableInits', Length(FIr.TableInits), 1);
  Expect<Boolean>(Length(FIr.TableInits[0].Code) > 0).ToBe(True);
  Expect<string>(FIr.Tables[0].RefType.Describe).ToBe('(ref func)');
  { The table initialiser's ref.func also lands in C.REFS. }
  Expect<Boolean>(FIr.DeclaredFuncRefs[0]).ToBe(True);
end;

procedure TValidatorTests.TestDeclarativeElemEnablesRefFunc;
begin
  { A declarative segment declares functions and initialises nothing —
    its whole purpose is to put an index into C.REFS
    (`Elemmode_ok/declare`). }
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsElement, [$01, $03, $00, $01, $00]);
  Sect(wsCode, [$01, $05, $00, $D2, $00, $1A, $0B]);
  FinishAndValidate;

  ExpectCount('elems', Length(FIr.Elems), 1);
  ExpectCount('elem0.mode', Ord(FIr.Elems[0].Mode), Ord(iremDeclarative));
  Expect<Boolean>(FIr.DeclaredFuncRefs[0]).ToBe(True);
end;

{ memory64 is in the pinned draft, so an i64 memory is a POSITIVE case
  and not an oddity: limits flag $04 is the i64 form (Track A reads bit 2
  as the address type). Its active data segment's offset is then typed at
  the MEMORY's address type — i64 here, not i32 (`Datamode_ok`) — which
  is the half of the rule an i32-only validator gets wrong silently. }
procedure TValidatorTests.TestI64MemoryAndItsDataOffset;
begin
  StartModule;
  Sect(wsMemory, [$01, $04, $01]);
  { (data (i64.const 0) "a") — the offset expression is i64.const. }
  Sect(wsData, [$01, $00, $42, $00, $0B, $01, $61]);
  FinishAndValidate;

  ExpectCount('memories', Length(FIr.Memories), 1);
  ExpectCount('memory0.addrType',
    Ord(FIr.Memories[0].Limits.AddrType), Ord(watI64));
  ExpectCount('datas', Length(FIr.Datas), 1);
  ExpectCount('data0.mode', Ord(FIr.Datas[0].Mode), Ord(irdmActive));
  Expect<Boolean>(Length(FIr.Datas[0].Offset.Code) > 0).ToBe(True);
end;

{ `syntax-importdesc`: "Unlike export names, import names are not
  necessarily unique. It is possible to import the same module/item name
  pair multiple times." The twin of the duplicate-EXPORT negative below,
  and the reason the uniqueness check lives only on the export side. }
procedure TValidatorTests.TestDuplicateImportNamesAreAccepted;
begin
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsImport, [$02,
    $01, $6D, $01, $66, $00, $00,
    $01, $6D, $01, $66, $00, $00]);
  FinishAndValidate;

  ExpectCount('funcs', Length(FIr.FuncCanonTypes), 2);
  ExpectCount('funcImports', Integer(FIr.FuncImportCount), 2);
end;

{ `valid-elem` in active mode checks `match-reftype` in ONE direction:
  the segment's element type must be a SUBTYPE of the table's, not the
  other way round. A `(ref func)` segment into a `funcref` table is
  therefore valid — and it is the case that discriminates the direction,
  because the mismatch negative below uses two unrelated types and would
  pass either way. }
procedure TValidatorTests.TestNonNullElemSegmentIntoAFuncrefTable;
begin
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsTable, [$01, $70, $00, $01]);
  { flags 6: active, explicit table index, offset expr, reftype,
    vec(expr) — element type $64 $70 is the non-nullable long form. }
  Sect(wsElement, [$01, $06, $00, $41, $00, $0B, $64, $70,
    $01, $D2, $00, $0B]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;

  ExpectCount('elems', Length(FIr.Elems), 1);
  Expect<string>(FIr.Elems[0].RefType.Describe).ToBe('(ref func)');
  ExpectCount('elem0.items', Length(FIr.Elems[0].Items), 1);
  Expect<Boolean>(FIr.DeclaredFuncRefs[0]).ToBe(True);
end;

{ --- negatives ----------------------------------------------------------- }

{ `syntax-exportdesc`: "Each export is labeled by a unique name." }
procedure TValidatorTests.TestRejectsDuplicateExportName;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsType, [$01, $60, $00, $00]);
    Sect(wsFunction, [$01, $00]);
    Sect(wsExport, [$02, $01, $61, $00, $00, $01, $61, $00, $00]);
    Sect(wsCode, [$01, $02, $00, $0B]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_DUPLICATE_EXPORT_NAME);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_DUPLICATE_EXPORT_NAME);
end;

{ `valid-start` (`Start_ok`): the start function's type must be [] -> []. }
procedure TValidatorTests.TestRejectsStartWithParameters;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsType, [$01, $60, $01, $7F, $00]);
    Sect(wsFunction, [$01, $00]);
    Sect(wsStart, [$00]);
    Sect(wsCode, [$01, $02, $00, $0B]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_START_FUNCTION);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_START_FUNCTION);
end;

{ `valid-table` without an initialiser: the element type must be
  defaultable (`aux-default` — "For other references, no default value is
  defined"), and `(ref func)` is not. }
procedure TValidatorTests.TestRejectsNonDefaultableTableWithoutInit;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsTable, [$01, $64, $70, $00, $01]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_TYPE_MISMATCH);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_TYPE_MISMATCH);
end;

{ `valid-elem` in active mode: the table's element type must subsume the
  segment's (`match-reftype`). funcref does not match externref. }
procedure TValidatorTests.TestRejectsElementReferenceTypeMismatch;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsTable, [$01, $6F, $00, $01]);
    { flags 6: active, explicit table index, offset expr, reftype,
      vec(expr) — here funcref against an externref table. }
    Sect(wsElement, [$01, $06, $00, $41, $00, $0B, $70, $00]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_TYPE_MISMATCH);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_TYPE_MISMATCH);
end;

{ An active segment's offset is typed at the TABLE's address type, not at
  i32 (`Elemmode_ok/active`). Limits flag $04 is the i64 form (Track A:
  four assigned flag values, bit 2 selecting the address type). }
procedure TValidatorTests.TestRejectsI32OffsetOnI64Table;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsTable, [$01, $70, $04, $01]);
    Sect(wsElement, [$01, $02, $00, $41, $00, $0B, $00, $00]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_TYPE_MISMATCH);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_TYPE_MISMATCH);
end;

{ `valid-globalseq` / `valid-constant`: global i sees the imports plus
  globals 0..i-1. Global 0 reading global 1 is outside the constrained
  context, so the global does not exist as far as the rule is concerned. }
procedure TValidatorTests.TestRejectsGlobalReadingALaterGlobal;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsGlobal, [$02,
      $7F, $00, $23, $01, $0B,
      $7F, $00, $41, $00, $0B]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_UNKNOWN_GLOBAL);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_UNKNOWN_GLOBAL);
end;

{ `valid-constant`: "Constant expressions occurring in tables may only
  have GLOBAL.GET instructions that refer to IMPORTED globals." This
  module has no global imports, so global 0 — which exists, and has the
  right type — is still out of scope for a table initialiser. }
procedure TValidatorTests.TestRejectsTableInitReadingADefinedGlobal;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsTable, [$01, $40, $00, $70, $00, $01, $23, $00, $0B]);
    Sect(wsGlobal, [$01, $70, $00, $D0, $70, $0B]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_UNKNOWN_GLOBAL);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_UNKNOWN_GLOBAL);
end;

{ `syntax-tagtype`: "The result type is empty for exception tags." }
procedure TValidatorTests.TestRejectsTagWithResults;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsType, [$01, $60, $00, $01, $7F]);
    Sect(wsTag, [$01, $00, $00]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_TAG_RESULT_TYPE);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_TAG_RESULT_TYPE);
end;

{ `valid-memtype` (`Memtype_ok`): an i32 memory's limits are bounded by
  2^32 / 64 Ki = 65536 pages. 65537 is one past it. }
procedure TValidatorTests.TestRejectsMemoryOverThePageLimit;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    { 65537 as an unsigned LEB128 is $81 $80 $04. }
    Sect(wsMemory, [$01, $00, $81, $80, $04]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_MEMORY_SIZE_LIMIT);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_MEMORY_SIZE_LIMIT);
end;

{ `valid-limits` (`Limits_ok`): n <= m. Checked on IMPORT descriptions
  too — `valid-importdesc` validates the external type, and an import is
  the one place a limits pair reaches the validator without a definition
  behind it. }
procedure TValidatorTests.TestRejectsImportedLimitsWithMinAboveMax;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    { "m"."t" (memory 2 1) — flags $01 means a maximum follows. }
    Sect(wsImport, [$01,
      $01, $6D, $01, $74, $02, $01, $02, $01]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_SIZE_MINIMUM_GT_MAXIMUM);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome)
    .ToBe('rejected: ' + MSG_SIZE_MINIMUM_GT_MAXIMUM);
end;

{ `valid-exportdesc`: the index must exist in the space the kind names. }
procedure TValidatorTests.TestRejectsExportOfAMissingFunction;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsExport, [$01, $01, $61, $00, $00]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_UNKNOWN_FUNCTION);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_UNKNOWN_FUNCTION);
end;

{ The i64 half of `Memtype_ok`, which the i32 case above cannot reach:
  the bound is 2^64 / 64 Ki = 2^48 pages, and 2^48+1 is one past it. The
  PREFIX is the point as much as the rejection — an i64 memory must not
  be reported with the i32 message, which spells "65536 pages (4GiB)"
  and would be simply false here. }
procedure TValidatorTests.TestRejectsMemory64OverThePageLimit;
begin
  StartModule;
  { 281474976710657 (= 2^48 + 1) as an unsigned LEB128. }
  Sect(wsMemory, [$01, $04, $81, $80, $80, $80, $80, $80, $40]);
  Expect<string>(RejectionOf(MSG_MEMORY64_SIZE_LIMIT))
    .ToBe('rejected: ' + MSG_MEMORY64_SIZE_LIMIT);
end;

{ `Limits_ok`'s n <= m on a DEFINED memory. The existing case checks it
  on an import; this one checks that phase 5 applies the same rule to the
  module's own definitions, which is a separate call site. }
procedure TValidatorTests.TestRejectsDefinedMemoryWithMinAboveMax;
begin
  StartModule;
  { (memory 2 1) — flags $01 means a maximum follows. }
  Sect(wsMemory, [$01, $01, $02, $01]);
  Expect<string>(RejectionOf(MSG_SIZE_MINIMUM_GT_MAXIMUM))
    .ToBe('rejected: ' + MSG_SIZE_MINIMUM_GT_MAXIMUM);
end;

{ …and the same rule under `Tabletype_ok`, which is a third call site. }
procedure TValidatorTests.TestRejectsDefinedTableWithMinAboveMax;
begin
  StartModule;
  { (table 2 1 funcref) }
  Sect(wsTable, [$01, $70, $01, $02, $01]);
  Expect<string>(RejectionOf(MSG_SIZE_MINIMUM_GT_MAXIMUM))
    .ToBe('rejected: ' + MSG_SIZE_MINIMUM_GT_MAXIMUM);
end;

{ `Tabletype_ok`'s range bound: an i32 table holds at most 2^32-1
  entries, because a table of exactly 2^32 has no representable last
  index. The reference interpreter cannot construct this case — its
  minimum is u32-encoded — but this project's decoder reads every limits
  field as u64 (Track A), so the bound is reachable and therefore
  testable. }
procedure TValidatorTests.TestRejectsTableOverTheSizeLimit;
begin
  StartModule;
  { (table 4294967296 funcref) — 2^32 as an unsigned LEB128. }
  Sect(wsTable, [$01, $70, $00, $80, $80, $80, $80, $10]);
  Expect<string>(RejectionOf(MSG_TABLE_SIZE_LIMIT))
    .ToBe('rejected: ' + MSG_TABLE_SIZE_LIMIT);
end;

{ `valid-start` (`Start_ok`), the first of its two failures: the index
  must NAME a function at all. A missing function is `unknown function`,
  not `start function` — different questions, different prefixes. }
procedure TValidatorTests.TestRejectsStartIndexOutOfRange;
begin
  StartModule;
  Sect(wsStart, [$05]);
  Expect<string>(RejectionOf(MSG_UNKNOWN_FUNCTION))
    .ToBe('rejected: ' + MSG_UNKNOWN_FUNCTION);
end;

{ The other half of `Start_ok`: [] -> [], so RESULTS disqualify a start
  function exactly as parameters do. The existing case covers parameters
  only, and a validator checking just `Length(Params) <> 0` would pass
  it. }
procedure TValidatorTests.TestRejectsStartWithResults;
begin
  StartModule;
  Sect(wsType, [$01, $60, $00, $01, $7F]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsStart, [$00]);
  Sect(wsCode, [$01, $04, $00, $41, $00, $0B]);
  Expect<string>(RejectionOf(MSG_START_FUNCTION))
    .ToBe('rejected: ' + MSG_START_FUNCTION);
end;

{ `valid-exportdesc` in the four spaces the existing function case does
  not cover. One test rather than four because the interesting property
  is that each KIND reports its own prefix — a shared "unknown export"
  would pass four separate tests written carelessly and fails this one. }
procedure TValidatorTests.TestRejectsExportsInEveryOtherSpace;
var
  Report: string;

  procedure Check(const AKind: Byte; const APrefix: string);
  begin
    StartModule;
    { export "a" <kind> 0, into a module that defines nothing. }
    Sect(wsExport, [$01, $01, $61, AKind, $00]);
    if Report <> '' then
      Report := Report + #10;
    Report := Report + RejectionOf(APrefix);
  end;

begin
  Report := '';
  Check($01, MSG_UNKNOWN_TABLE);
  Check($02, MSG_UNKNOWN_MEMORY);
  Check($03, MSG_UNKNOWN_GLOBAL);
  Check($04, MSG_UNKNOWN_TAG);

  Expect<string>(Report).ToBe(
    'rejected: ' + MSG_UNKNOWN_TABLE + #10
    + 'rejected: ' + MSG_UNKNOWN_MEMORY + #10
    + 'rejected: ' + MSG_UNKNOWN_GLOBAL + #10
    + 'rejected: ' + MSG_UNKNOWN_TAG);
end;

{ ERROR PRECEDENCE, which is conformance surface: `Elem_ok` validates the
  segment's ITEMS against its reference type and only then hands the mode
  to `Elemmode_ok`, so a segment that is BOTH ill-typed in its items and
  aimed at a table that does not exist must report the item failure. This
  module is exactly that: an externref segment whose single item is a
  `ref.func`, targeting table 0 of a module with no tables. Reporting
  `unknown table` here — which is what checking the active mode first
  does — is the wrong answer to a .wast assert_invalid. }
procedure TValidatorTests.TestElemItemsAreCheckedBeforeTheTable;
begin
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  { flags 6: active with an explicit table index. externref element type,
    one item: (ref.func 0), which is a function reference. }
  Sect(wsElement, [$01, $06, $00, $41, $00, $0B, $6F,
    $01, $D2, $00, $0B]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  Expect<string>(RejectionOf(MSG_TYPE_MISMATCH))
    .ToBe('rejected: ' + MSG_TYPE_MISMATCH);
end;

{ `binary-elem` / `binary-elemkind`: the funcidx shorthand's element type
  is the NON-NULLABLE `(ref func)`, because the production builds its
  elements as `(ref.func y) end`, and `elemkind ::= 0x00 => ref func`.
  Reading it as `funcref` makes this module fail to validate against a
  `(ref func)` table — upstream ships exactly this module as valid
  (elem.wast, flags 0 and 2). The two flag values are the implicit- and
  explicit-table arms of the same shorthand, so both are covered.

  The table is the 3.0 explicit-init form ($40 $00), which is the only
  way to spell a non-defaultable table type. }
procedure TValidatorTests.TestFuncidxShorthandIntoANonNullableTable;
begin
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  { $40 $00, then (ref func) [1..], initialised with (ref.func 0). }
  Sect(wsTable, [$01, $40, $00, $64, $70, $00, $01, $D2, $00, $0B]);
  { flags 0: active, implicit table 0, offset expr, vec(funcidx). }
  Sect(wsElement, [$01, $00, $41, $00, $0B, $01, $00]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;

  ExpectCount('elems', Length(FIr.Elems), 1);
  Expect<string>(FIr.Elems[0].RefType.Describe).ToBe('(ref func)');

  { flags 2: the same shorthand with an explicit table index. }
  StartModule;
  Sect(wsType, [$01, $60, $00, $00]);
  Sect(wsFunction, [$01, $00]);
  Sect(wsTable, [$01, $40, $00, $64, $70, $00, $01, $D2, $00, $0B]);
  Sect(wsElement, [$01, $02, $00, $41, $00, $0B, $00, $01, $00]);
  Sect(wsCode, [$01, $02, $00, $0B]);
  FinishAndValidate;

  ExpectCount('elems', Length(FIr.Elems), 1);
  Expect<string>(FIr.Elems[0].RefType.Describe).ToBe('(ref func)');
end;

{ The discriminating counterpart, and the reason the shorthand's type
  cannot simply be widened for everything: flag 4 is the element-
  EXPRESSION form with an implied type, and its production yields
  `ref null func` — an element expression may be `ref.null func`. Against
  the same `(ref func)` table that is a type mismatch, and upstream
  asserts it as one. }
procedure TValidatorTests.TestImpliedFuncrefExprFormIntoANonNullableTable;
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';
  try
    StartModule;
    Sect(wsType, [$01, $60, $00, $00]);
    Sect(wsFunction, [$01, $00]);
    Sect(wsTable, [$01, $40, $00, $64, $70, $00, $01, $D2, $00, $0B]);
    { flags 4: active, implicit table 0, offset expr, vec(expr). }
    Sect(wsElement, [$01, $04, $41, $00, $0B, $01, $D2, $00, $0B]);
    Sect(wsCode, [$01, $02, $00, $0B]);
    FinishAndValidate;
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, MSG_TYPE_MISMATCH);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;
  Expect<string>(Outcome).ToBe('rejected: ' + MSG_TYPE_MISMATCH);
end;

procedure TValidatorTests.SetupTests;
begin
  Test('a module exercising every index space validates',
    TestKitchenSinkValidates);
  Test('the IR carries every index space, imports first',
    TestKitchenSinkIndexSpaces);
  Test('the IR carries canonical types and per-function code',
    TestKitchenSinkTypesAndFunctions);
  Test('the IR carries initialisers, segments, start and C.REFS',
    TestKitchenSinkSegmentsAndStart);
  Test('ref.func in a global initialiser declares the function',
    TestConstExprRefFuncDeclaresTheFunction);
  Test('without that initialiser the same body is undeclared',
    TestUndeclaredWithoutThatConstExpr);
  Test('a table with an initialiser may have a non-defaultable type',
    TestTableWithInitExpression);
  Test('a declarative element segment enables ref.func in a body',
    TestDeclarativeElemEnablesRefFunc);
  Test('an i64 memory takes an i64 data offset',
    TestI64MemoryAndItsDataOffset);
  Test('duplicate import names are accepted',
    TestDuplicateImportNamesAreAccepted);
  Test('a (ref func) segment fits a funcref table',
    TestNonNullElemSegmentIntoAFuncrefTable);
  Test('the funcidx shorthand fits a (ref func) table',
    TestFuncidxShorthandIntoANonNullableTable);
  Test('the implied-funcref expr form does not fit a (ref func) table',
    TestImpliedFuncrefExprFormIntoANonNullableTable);

  Test('rejects a duplicate export name',
    TestRejectsDuplicateExportName);
  Test('rejects an i64 memory above the page limit',
    TestRejectsMemory64OverThePageLimit);
  Test('rejects a defined memory whose minimum exceeds its maximum',
    TestRejectsDefinedMemoryWithMinAboveMax);
  Test('rejects a defined table whose minimum exceeds its maximum',
    TestRejectsDefinedTableWithMinAboveMax);
  Test('rejects a table above the address type''s size limit',
    TestRejectsTableOverTheSizeLimit);
  Test('rejects a start index past the function space',
    TestRejectsStartIndexOutOfRange);
  Test('rejects a start function with results',
    TestRejectsStartWithResults);
  Test('rejects exports naming missing tables, memories, globals and tags',
    TestRejectsExportsInEveryOtherSpace);
  Test('reports an element item failure before a missing table',
    TestElemItemsAreCheckedBeforeTheTable);
  Test('rejects a start function with parameters',
    TestRejectsStartWithParameters);
  Test('rejects a non-defaultable table without an initialiser',
    TestRejectsNonDefaultableTableWithoutInit);
  Test('rejects an element segment whose type the table does not subsume',
    TestRejectsElementReferenceTypeMismatch);
  Test('rejects an i32 element offset on an i64 table',
    TestRejectsI32OffsetOnI64Table);
  Test('rejects a global initialiser reading a later global',
    TestRejectsGlobalReadingALaterGlobal);
  Test('rejects a table initialiser reading a defined global',
    TestRejectsTableInitReadingADefinedGlobal);
  Test('rejects a tag whose function type has results',
    TestRejectsTagWithResults);
  Test('rejects a memory above the page limit',
    TestRejectsMemoryOverThePageLimit);
  Test('rejects imported limits whose minimum exceeds its maximum',
    TestRejectsImportedLimitsWithMinAboveMax);
  Test('rejects an export naming a function that does not exist',
    TestRejectsExportOfAMissingFunction);
end;

begin
  TestRunnerProgram.AddSuite(TValidatorTests.Create('Wasm.Validator'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
