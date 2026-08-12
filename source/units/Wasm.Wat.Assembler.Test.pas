{ Unit suite for Wasm.Wat.Assembler — the shipped text-format assembler.

  The oracle is the shipped pipeline: assemble text -> DecodeModule -> assert
  the decoded model, and for well-formed modules assemble -> DecodeModule ->
  ValidateModule. A text error must never reach the decoder (INV-1), so a
  well-formed case that decodes proves the assembler produced honest bytes.

  The suite lifts the §7 oracle cases verbatim from the corpus:
    - func.wast:422-433  — an implicit typeuse appends AFTER the explicit
      types, and `(type $t)` declared third is still index 0;
    - func_ptrs.wast:2-4 — explicit types are never deduped;
    - type-rec.wast:45-61 — an implicit typeuse must NOT reuse a multi-member
      rec-group member, so the module fails VALIDATION rather than reusing it.
  Plus the inline import/export abbreviations, elem/data sugar, named+indexed
  locals, label shadowing (asserted at the emitted `br` depth bytes), a
  duplicate-identifier text error, a forward reference, and a cross-check that
  the committed fixtures assemble to the same section shape. }
program Wasm.Wat.Assembler.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator,
  Wasm.Wat.Assembler;

type
  TWatAsmTests = class(TTestSuite)
  private
    FBytes: TWasmBytes;
    FModule: TWasmModule;
    FIr: TWasmIrModule;

    procedure AssembleAndDecode(const AText: string);
    function ValidateOutcome(const AText: string): string;
    function AssembleError(const AText: string): string;
    function FuncSig(const AGroup: TWasmRecType; out AParams,
      AResults: Integer): Boolean;
    function BodyHex: string;
    function BytesToHex(const ABytes: TWasmBytes): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestEmptyModule;
    procedure TestImplicitTypeuseOracle;
    procedure TestExplicitTypesNeverDeduped;
    procedure TestRecGroupMemberNotReused;
    procedure TestInlineImportExport;
    procedure TestElemAndDataSugar;
    procedure TestNamedAndIndexedLocals;
    procedure TestLabelShadowingDepths;
    procedure TestDuplicateIdentifier;
    procedure TestForwardReference;
    procedure TestUnknownOperatorPlaceholder;
    procedure TestFixturesSectionShape;
    procedure TestFoldedIfArmOrder;
    procedure TestMemArgDefaults;
    procedure TestBroadInstructionRoundTrip;
    procedure TestGcStructAndArray;
    procedure TestMismatchingLabel;
    procedure TestTryTable;
    procedure TestCallIndirectSelectBrTable;
    procedure TestInlineSegments;
    procedure TestRefTestCast;
    procedure TestForwardTypeReference;
    procedure TestTypeuseClauseOrder;
    procedure TestBlockTypeInlineFuncType;
    procedure TestDataCountFromCode;
    procedure TestReservedTokenIsUnknownOperator;
    procedure TestNanPatternsInConst;
    procedure TestBrOnCastRoundTrip;
    procedure TestVectorConstAllShapes;
    procedure TestVectorShuffleAndLanes;
    procedure TestVectorMemoryAndLaneLookahead;
    procedure TestVectorImmediateErrors;
    procedure TestTableInitExpr;
    procedure TestInlineMemDataAddrType;
    procedure TestTableAddrType;
    procedure TestObsoleteKeywordIsUnknownOperator;
    procedure TestMemArgSignedIsUnknownOperator;
    procedure TestVectorConstCountBeforeValue;
  end;

function StartsWith(const AWhole, APrefix: string): Boolean;
begin
  Result := Copy(AWhole, 1, Length(APrefix)) = APrefix;
end;

procedure TWatAsmTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FIr := nil;
end;

procedure TWatAsmTests.AfterEach;
begin
  FreeAndNil(FIr);
  FreeAndNil(FModule);
end;

procedure TWatAsmTests.AssembleAndDecode(const AText: string);
begin
  FBytes := AssembleWatText(AText);
  FModule.Clear;
  DecodeModule(FBytes, FModule);
end;

function TWatAsmTests.ValidateOutcome(const AText: string): string;
begin
  { 'valid' on success; otherwise the failing stage. A decode error on our own
    output is INV-1 violated and is reported as such rather than swallowed. }
  Result := 'valid';
  try
    FBytes := AssembleWatText(AText);
  except
    on E: Exception do
      Exit('assemble error: ' + E.Message);
  end;
  try
    FModule.Clear;
    DecodeModule(FBytes, FModule);
  except
    on E: EWasmDecodeError do
      Exit('INV-1 decode error: ' + E.Message);
  end;
  try
    FreeAndNil(FIr);
    FIr := ValidateModule(FModule, FBytes);
  except
    on E: EWasmValidationError do
      Exit('validation error');
  end;
end;

function TWatAsmTests.AssembleError(const AText: string): string;
begin
  { A text-format failure is a single unified EWasmTextError (Wasm.Core), so
    catch exactly that — a decode error from the assembler's own output would
    be an INV-1 defect and should fail loudly, not be reported as a message.
    The corpus match is a prefix match anyway. }
  Result := '';
  try
    FBytes := AssembleWatText(AText);
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatAsmTests.FuncSig(const AGroup: TWasmRecType; out AParams,
  AResults: Integer): Boolean;
begin
  Result := (Length(AGroup.SubTypes) = 1)
    and (AGroup.SubTypes[0].Comp.Kind = wckFunc);
  if Result then
  begin
    AParams := Length(AGroup.SubTypes[0].Comp.Func.Params);
    AResults := Length(AGroup.SubTypes[0].Comp.Func.Results);
  end
  else
  begin
    AParams := -1;
    AResults := -1;
  end;
end;

function TWatAsmTests.BytesToHex(const ABytes: TWasmBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
    Result := Result + IntToHex(ABytes[I], 2);
end;

function TWatAsmTests.BodyHex: string;
var
  Entry: TWasmCodeEntry;
  Slice: TWasmBytes;
  I: Integer;
begin
  Entry := FModule.CodeEntries[0];
  SetLength(Slice, Entry.Body.Size);
  for I := 0 to Integer(Entry.Body.Size) - 1 do
    Slice[I] := FBytes[Integer(Entry.Body.Offset) + I];
  Result := BytesToHex(Slice);
end;

{ --- oracle: implicit typeuse ordering (func.wast:422-433) --------------- }

procedure TWatAsmTests.TestEmptyModule;
begin
  AssembleAndDecode('(module)');
  Expect<Integer>(FModule.SectionCount).ToBe(0);
  { Bare fields (the quote-payload shape) assemble the same. }
  FBytes := AssembleWatText('');
  FModule.Clear;
  DecodeModule(FBytes, FModule);
  Expect<Integer>(FModule.SectionCount).ToBe(0);
end;

procedure TWatAsmTests.TestImplicitTypeuseOracle;
var
  P, R: Integer;
begin
  { func.wast:422-433. $f's implicit (result f64) must land at index 1, AFTER
    the explicit $t at index 0 — even though $t is declared third. }
  AssembleAndDecode(
    '(module' +
    '  (func $f (result f64) (f64.const 0))' +
    '  (func $g (param i32))' +
    '  (type $t (func (param i32)))' +
    '  (func $i32_void (type 0))' +
    '  (func $void_f64 (type 1) (f64.const 0)))');

  Expect<Integer>(FModule.TypeCount).ToBe(2);
  { index 0 = (i32)->() — the explicit $t. }
  Expect<Boolean>(FuncSig(FModule.Types[0], P, R)).ToBe(True);
  Expect<Integer>(P).ToBe(1);
  Expect<Integer>(R).ToBe(0);
  { index 1 = ()->(f64) — the implicit type from $f, appended after $t. }
  Expect<Boolean>(FuncSig(FModule.Types[1], P, R)).ToBe(True);
  Expect<Integer>(P).ToBe(0);
  Expect<Integer>(R).ToBe(1);

  Expect<string>(ValidateOutcome(
    '(module' +
    '  (func $f (result f64) (f64.const 0))' +
    '  (func $g (param i32))' +
    '  (type $t (func (param i32)))' +
    '  (func $i32_void (type 0))' +
    '  (func $void_f64 (type 1) (f64.const 0)))')).ToBe('valid');
end;

procedure TWatAsmTests.TestExplicitTypesNeverDeduped;
begin
  { func_ptrs.wast:2-4 — three identical explicit void->void types stay
    distinct at indices 0/1/2. }
  AssembleAndDecode(
    '(module (type (func)) (type (func)) (type (func)))');
  Expect<Integer>(FModule.TypeCount).ToBe(3);
end;

procedure TWatAsmTests.TestRecGroupMemberNotReused;
begin
  { type-rec.wast:45-61 — the implicit type of $f must NOT reuse a member of
    the two-member rec group, so a THIRD type is appended. The module then
    fails validation (the `(ref $ft)` global holds a ref of the wrong type),
    which is exactly the corpus's assert_invalid verdict. }
  AssembleAndDecode(
    '(module' +
    '  (rec (type $ft (func)) (type (func)))' +
    '  (func $f)' +
    '  (global (ref $ft) (ref.func $f)))');
  { Two type-section GROUPS: the 2-member rec group (indices 0,1) plus a fresh
    single-member group appended for $f's implicit type (index 2). Had the
    implicit typeuse wrongly reused a rec member, no group would be appended. }
  Expect<Integer>(FModule.TypeCount).ToBe(2);
  Expect<Integer>(Length(FModule.Types[0].SubTypes)).ToBe(2);
  Expect<Integer>(Length(FModule.Types[1].SubTypes)).ToBe(1);
  { $f's function type is the appended index 2, not the rec member 0/1. }
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[0])).ToBe(2);

  Expect<string>(ValidateOutcome(
    '(module' +
    '  (rec (type $ft (func)) (type (func)))' +
    '  (func $f)' +
    '  (global (ref $ft) (ref.func $f)))')).ToBe('validation error');
end;

{ --- inline import / export abbreviations (§2c.2) ------------------------ }

procedure TWatAsmTests.TestInlineImportExport;
begin
  AssembleAndDecode(
    '(module' +
    '  (func (export "e") (result i32) (i32.const 7))' +
    '  (memory (export "m") 1)' +
    '  (global (import "env" "g") i32))');

  { The inline import lands in the import section. }
  Expect<Integer>(FModule.ImportCount).ToBe(1);
  Expect<Integer>(Ord(FModule.Imports[0].Kind)).ToBe(Ord(wxkGlobal));
  Expect<string>(FModule.Imports[0].ModuleName).ToBe('env');
  Expect<string>(FModule.Imports[0].Name).ToBe('g');

  { Two inline exports, in entity order: the func then the memory. }
  Expect<Integer>(FModule.ExportCount).ToBe(2);
  Expect<string>(FModule.&Exports[0].Name).ToBe('e');
  Expect<Integer>(Ord(FModule.&Exports[0].Kind)).ToBe(Ord(wxkFunc));
  Expect<Int64>(Int64(FModule.&Exports[0].Index)).ToBe(0);
  Expect<string>(FModule.&Exports[1].Name).ToBe('m');
  Expect<Integer>(Ord(FModule.&Exports[1].Kind)).ToBe(Ord(wxkMem));
  Expect<Int64>(Int64(FModule.&Exports[1].Index)).ToBe(0);

  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(1);
  Expect<Integer>(FModule.MemoryCount).ToBe(1);
end;

{ --- elem / data sugar (§2c.5) ------------------------------------------- }

procedure TWatAsmTests.TestElemAndDataSugar;
begin
  AssembleAndDecode(
    '(module' +
    '  (table 2 funcref)' +
    '  (func $f)' +
    '  (elem (i32.const 0) $f $f)' +
    '  (memory 1)' +
    '  (data (i32.const 0) "hi")' +
    '  (data "passive"))');

  Expect<Integer>(FModule.ElementCount).ToBe(1);
  Expect<Integer>(Ord(FModule.Elements[0].Mode)).ToBe(Ord(wemActive));
  Expect<Int64>(Int64(FModule.Elements[0].TableIndex)).ToBe(0);
  Expect<Boolean>(FModule.Elements[0].UsesExprs).ToBe(False);
  Expect<Integer>(Length(FModule.Elements[0].FuncIndices)).ToBe(2);

  Expect<Integer>(FModule.DataSegmentCount).ToBe(2);
  Expect<Integer>(Ord(FModule.DataSegments[0].Mode)).ToBe(Ord(wdmActive));
  Expect<Int64>(Int64(FModule.DataSegments[0].Bytes.Size)).ToBe(2);
  Expect<Integer>(Ord(FModule.DataSegments[1].Mode)).ToBe(Ord(wdmPassive));
  Expect<Int64>(Int64(FModule.DataSegments[1].Bytes.Size)).ToBe(7);

  { A data section forces the data count section (§2e). }
  Expect<Boolean>(FModule.HasDataCount).ToBe(True);
  Expect<Int64>(Int64(FModule.DataCount)).ToBe(2);

  Expect<string>(ValidateOutcome(
    '(module' +
    '  (table 2 funcref)' +
    '  (func $f)' +
    '  (elem (i32.const 0) $f $f)' +
    '  (memory 1)' +
    '  (data (i32.const 0) "hi")' +
    '  (data "passive"))')).ToBe('valid');
end;

{ --- funcs with named and indexed locals -------------------------------- }

procedure TWatAsmTests.TestNamedAndIndexedLocals;
begin
  { A named param and a named local, addressed by both name and number in the
    body. local 0 = $p (param), local 1 = $q (local). }
  AssembleAndDecode(
    '(module (func $f (param $p i32) (result i32)' +
    '  (local $q i32)' +
    '  local.get $p' +
    '  local.set $q' +
    '  local.get 1' +
    '  local.get 0' +
    '  i32.add))');

  Expect<Integer>(FModule.CodeEntryCount).ToBe(1);
  { One local group of one i32 (the param is not a code-section local). }
  Expect<Integer>(Length(FModule.CodeEntries[0].Locals)).ToBe(1);
  Expect<Int64>(Int64(FModule.CodeEntries[0].Locals[0].Count)).ToBe(1);
  Expect<string>(FModule.CodeEntries[0].Locals[0].ValueType.Describe)
    .ToBe('i32');

  Expect<string>(ValidateOutcome(
    '(module (func $f (param $p i32) (result i32)' +
    '  (local $q i32)' +
    '  local.get $p' +
    '  local.set $q' +
    '  local.get 1' +
    '  local.get 0' +
    '  i32.add))')).ToBe('valid');
end;

{ --- label shadowing at the emitted br bytes (§7, labels.wast) ----------- }

procedure TWatAsmTests.TestLabelShadowingDepths;
begin
  { Nested blocks re-binding $a. The inner `br $a` must reach the innermost
    $a (depth 0); after that block pops, `br $a` reaches the outer $a, which
    now sits below $b (depth 1). An outer-first resolver would emit 2 and 1. }
  AssembleAndDecode(
    '(module (func' +
    '  block $a' +
    '    block $b' +
    '      block $a' +
    '        br $a' +
    '      end' +
    '      br $a' +
    '    end' +
    '  end))');

  { 02 40 (block $a) 02 40 (block $b) 02 40 (block $a) 0C 00 (br depth 0)' +
    ' 0B (end) 0C 01 (br depth 1) 0B 0B (ends) 0B (func end). }
  Expect<string>(BodyHex).ToBe('024002400240' + '0C00' + '0B' + '0C01' +
    '0B' + '0B' + '0B');
end;

{ --- duplicate identifier text error ------------------------------------ }

procedure TWatAsmTests.TestDuplicateIdentifier;
begin
  Expect<Boolean>(StartsWith(
    AssembleError('(module (func $f) (func $f))'), 'duplicate func'))
    .ToBe(True);
  { A struct field clash is `duplicate field`. }
  Expect<Boolean>(StartsWith(
    AssembleError('(module (type (struct (field $x i32) (field $x i32))))'),
    'duplicate field')).ToBe(True);
end;

{ --- forward reference: call a function declared later ------------------- }

procedure TWatAsmTests.TestForwardReference;
begin
  AssembleAndDecode('(module (func $a call $b) (func $b))');
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(2);
  Expect<string>(ValidateOutcome('(module (func $a call $b) (func $b))'))
    .ToBe('valid');
end;

{ --- the unknown-operator path is loud, not silent --------------------- }

procedure TWatAsmTests.TestUnknownOperatorPlaceholder;
begin
  { The $FD vector space is now encoded (Track G): a real v128 mnemonic
    assembles rather than raising `unknown operator`. But an invented
    v128-shaped spelling with no row still takes the unknown-operator path —
    a missing row is the right signal, exactly as for the obsolete keywords. }
  Expect<string>(AssembleError('(module (func v128.const i32x4 0 0 0 0 drop))'))
    .ToBe('');
  Expect<Boolean>(StartsWith(
    AssembleError('(module (func v128.notareal.op))'),
    'unknown operator v128.notareal.op')).ToBe(True);
  Expect<Boolean>(StartsWith(
    AssembleError('(module (func i8x16.notreal))'),
    'unknown operator i8x16.notreal')).ToBe(True);
end;

{ --- committed fixtures assemble to the same section shape -------------- }

procedure TWatAsmTests.TestFixturesSectionShape;

  procedure CompareShape(const AName: string);
  var
    AsmBytes, RefBytes: TWasmBytes;
    AsmMod, RefMod: TWasmModule;
    Base: string;
  begin
    Base := 'tests' + PathDelim + 'fixtures' + PathDelim + 'valid'
      + PathDelim + AName;
    AsmBytes := AssembleWat(LoadFileBytes(Base + '.wat'));
    RefBytes := LoadFileBytes(Base + '.wasm');
    AsmMod := TWasmModule.Create;
    RefMod := TWasmModule.Create;
    try
      DecodeModule(AsmBytes, AsmMod);
      DecodeModule(RefBytes, RefMod);
      Expect<Integer>(AsmMod.TypeCount).ToBe(RefMod.TypeCount);
      Expect<Integer>(AsmMod.ImportCount).ToBe(RefMod.ImportCount);
      Expect<Integer>(AsmMod.FunctionTypeIndexCount)
        .ToBe(RefMod.FunctionTypeIndexCount);
      Expect<Integer>(AsmMod.TableCount).ToBe(RefMod.TableCount);
      Expect<Integer>(AsmMod.MemoryCount).ToBe(RefMod.MemoryCount);
      Expect<Integer>(AsmMod.GlobalCount).ToBe(RefMod.GlobalCount);
      Expect<Integer>(AsmMod.ExportCount).ToBe(RefMod.ExportCount);
      Expect<Integer>(AsmMod.ElementCount).ToBe(RefMod.ElementCount);
      Expect<Integer>(AsmMod.DataSegmentCount).ToBe(RefMod.DataSegmentCount);
    finally
      AsmMod.Free;
      RefMod.Free;
    end;
  end;

begin
  CompareShape('minimal');
  CompareShape('exports');
  CompareShape('imports');
end;

{ --- folded-if arm ordering at the byte level (§7, if.wast:19) ----------- }

procedure TWatAsmTests.TestFoldedIfArmOrder;
begin
  { if.wast:19 — `(if (result i32) (local.get 0) (then (i32.const 7))
    (else (i32.const 8)))`. The CONDITION operand must emit BEFORE the `if`
    opcode, then the then-arm, else, else-arm, end. A resolver that emits the
    condition after the opcode produces a valid-looking WRONG module that only
    assert_return would catch — so this is asserted at the exact bytes. }
  AssembleAndDecode(
    '(module (func (param i32) (result i32)' +
    '  (if (result i32) (local.get 0) (then (i32.const 7)) (else (i32.const 8)))))');
  { 2000 (local.get 0) 04 (if) 7F (result i32) 4107 (then) 05 (else) 4108
    0B (end-of-if) 0B (func end). BodyHex covers the instruction bytes only,
    not the leading locals-count byte. }
  Expect<string>(BodyHex).ToBe('2000' + '04' + '7F' + '4107' + '05' +
    '4108' + '0B' + '0B');
end;

{ --- memarg defaults and explicit align/offset (§2c.6) ------------------- }

procedure TWatAsmTests.TestMemArgDefaults;

  function Body(const ALoad: string): string;
  begin
    AssembleAndDecode(
      '(module (memory 1) (func (result i32) i32.const 0 ' + ALoad + '))');
    Result := BodyHex;
  end;

begin
  { i32.load's natural alignment is 4 bytes = log2 2. With neither operand the
    flags field is that natural log2 and the offset is 0: 28 02 00. (BodyHex is
    the instruction bytes only, no leading locals-count byte.) }
  Expect<string>(Body('i32.load')).ToBe('4100' + '28' + '02' + '00' + '0B');
  { align=1 (log2 0) overrides the natural alignment. }
  Expect<string>(Body('i32.load align=1'))
    .ToBe('4100' + '28' + '00' + '00' + '0B');
  { offset=4 keeps the natural align and sets the u64 offset. }
  Expect<string>(Body('i32.load offset=4'))
    .ToBe('4100' + '28' + '02' + '04' + '0B');
  { both, in either order. }
  Expect<string>(Body('i32.load offset=8 align=1'))
    .ToBe('4100' + '28' + '00' + '08' + '0B');
  Expect<string>(Body('i32.load align=1 offset=8'))
    .ToBe('4100' + '28' + '00' + '08' + '0B');
  { align=0 and a non-power-of-two are text errors. }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (memory 1) (func i32.const 0 i32.load align=0 drop))'),
    'alignment must be a power of two')).ToBe(True);
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (memory 1) (func i32.const 0 i32.load align=3 drop))'),
    'alignment must be a power of two')).ToBe(True);
end;

{ --- a broad instruction round-trip that assembles, decodes and validates - }

procedure TWatAsmTests.TestBroadInstructionRoundTrip;
const
  Src =
    '(module' +
    '  (memory 1)' +
    '  (func $add (param i32 i32) (result i32)' +
    '    (i32.add (local.get 0) (local.get 1)))' +
    '  (func (param i32) (result i32)' +
    '    (local $acc i32)' +
    '    (block $a (result i32)' +           { folded block }
    '      (loop $l (result i32)' +          { folded loop }
    '        (if (result i32) (local.get 0)' + { folded if }
    '          (then (i32.const 1))' +
    '          (else (i32.const 2)))))' +
    '    (local.set $acc)' +
    '    block $flat' +                      { flat block }
    '      local.get 0' +
    '      br_if $flat' +
    '    end' +
    '    i32.const 0' +
    '    i32.load offset=0' +                { memarg }
    '    local.get $acc' +
    '    i32.add))';
begin
  AssembleAndDecode(Src);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(2);
  Expect<string>(ValidateOutcome(Src)).ToBe('valid');
end;

{ --- GC struct/array with field-by-name resolution (§3) ------------------ }

procedure TWatAsmTests.TestGcStructAndArray;
begin
  { struct.get resolves `$y` against the per-type field namespace of the FIRST
    operand ($pt, index 0), yielding field ordinal 1. array.new_default/get
    exercise the $FB type immediates. }
  AssembleAndDecode(
    '(module' +
    '  (type $pt (struct (field $x i32) (field $y i32)))' +
    '  (type $ai (array (mut i32)))' +
    '  (func (result i32)' +
    '    (struct.get $pt $y (struct.new_default $pt)))' +
    '  (func (result i32)' +
    '    (array.get $ai (array.new_default $ai (i32.const 3)) (i32.const 0))))');
  { The first body unfolds to FB 01 00 (struct.new_default $pt) then
    FB 02 00 01 (struct.get type 0, field ordinal 1 = $y) then 0B. BodyHex is
    the instruction bytes only. This pins field-by-NAME resolution. }
  Expect<string>(BodyHex).ToBe('FB0100' + 'FB020001' + '0B');

  Expect<string>(ValidateOutcome(
    '(module' +
    '  (type $pt (struct (field $x i32) (field $y i32)))' +
    '  (type $ai (array (mut i32)))' +
    '  (func (result i32)' +
    '    (struct.get $pt $y (struct.new_default $pt)))' +
    '  (func (result i32)' +
    '    (array.get $ai (array.new_default $ai (i32.const 3)) (i32.const 0))))'))
    .ToBe('valid');
end;

{ --- mismatching label: trailing id must equal the block's id (§7) ------- }

procedure TWatAsmTests.TestMismatchingLabel;

  function Bad(const AFunc: string): Boolean;
  begin
    Result := StartsWith(AssembleError(AFunc), 'mismatching label');
  end;

begin
  { The 14 corpus one-liners are all of this shape (block.wast:1486-1490,
    if.wast:1520-1551): a trailing id at `end`/`else` that does not equal the
    block's id — including an id on an UNLABELLED block. }
  Expect<Boolean>(Bad('(func block end $l)')).ToBe(True);
  Expect<Boolean>(Bad('(func block $a end $l)')).ToBe(True);
  Expect<Boolean>(Bad('(func i32.const 0 if end $l)')).ToBe(True);
  Expect<Boolean>(Bad('(func i32.const 0 if $a end $l)')).ToBe(True);
  Expect<Boolean>(Bad('(func i32.const 0 if else $l end)')).ToBe(True);
  Expect<Boolean>(Bad('(func i32.const 0 if $a else $l end)')).ToBe(True);
  Expect<Boolean>(Bad('(func i32.const 0 if else end $l)')).ToBe(True);
  Expect<Boolean>(Bad('(func i32.const 0 if $a else $a end $l)')).ToBe(True);
  { A matching trailing id is fine. }
  Expect<string>(ValidateOutcome('(module (func block $a end $a))'))
    .ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (func i32.const 0 if $a else $a end $a))')).ToBe('valid');
end;

{ --- try_table with a catch clause resolved in the enclosing scope ------- }

procedure TWatAsmTests.TestTryTable;
const
  Src =
    '(module' +
    '  (tag $e (param i32))' +
    '  (func (result i32)' +
    '    (block $h (result i32)' +
    '      (try_table (result i32) (catch $e $h)' +
    '        (i32.const 7)))))';
begin
  { The catch clause targets label $h — the enclosing block — which is at
    depth 0 BEFORE the try_table pushes its own (anonymous) label. }
  AssembleAndDecode(Src);
  Expect<Integer>(FModule.TagCount).ToBe(1);
  Expect<string>(ValidateOutcome(Src)).ToBe('valid');
end;

{ --- call_indirect typeuse, typed select, br_table --------------------- }

procedure TWatAsmTests.TestCallIndirectSelectBrTable;
const
  Src =
    '(module' +
    '  (type $ft (func (param i32) (result i32)))' +
    '  (table 1 funcref)' +
    '  (func (param i32) (result i32)' +
    '    (local.get 0) (i32.const 0)' +
    '    (call_indirect (type $ft)))' +      { typeuse, default table 0 }
    '  (func (param i32) (result i32)' +
    '    (select (result i32) (i32.const 1) (i32.const 2) (local.get 0)))' +
    '  (func (param i32)' +
    '    (block $a' +
    '      (block $b' +
    '        (local.get 0)' +
    '        (br_table $a $b $a)))))';
begin
  AssembleAndDecode(Src);
  { Two types: $ft (index 0, reused by the two (i32)->(i32) funcs and by the
    explicit call_indirect (type $ft)), plus the (i32)->() implicit type of the
    third func's br_table body appended at index 1. }
  Expect<Integer>(FModule.TypeCount).ToBe(2);
  Expect<string>(ValidateOutcome(Src)).ToBe('valid');
  { An inline typeuse structurally equal to $ft interns to the same index 0. }
  Expect<string>(ValidateOutcome(
    '(module' +
    '  (type $ft (func (param i32) (result i32)))' +
    '  (table 1 funcref)' +
    '  (func (param i32) (result i32)' +
    '    (local.get 0) (i32.const 0)' +
    '    (call_indirect (param i32) (result i32))))')).ToBe('valid');
end;

{ --- inline in-declaration segments (§2c.5) ----------------------------- }

procedure TWatAsmTests.TestInlineSegments;
const
  Src =
    '(module' +
    '  (func $f) (func $g)' +
    '  (table funcref (elem $f $g))' +      { inline table-elem (funcidx list) }
    '  (memory (data "\aa\bb\cc\dd")))';    { inline memory-data }
begin
  AssembleAndDecode(Src);
  { The table gains min=max=2 and a synthetic active elem segment; the memory
    min=max=1 (ceil(4/65536)) and a synthetic active data segment. }
  Expect<Integer>(FModule.TableCount).ToBe(1);
  Expect<Int64>(Int64(FModule.Tables[0].TableType.Limits.Min)).ToBe(2);
  Expect<Int64>(Int64(FModule.Tables[0].TableType.Limits.Max)).ToBe(2);
  Expect<Integer>(FModule.ElementCount).ToBe(1);
  Expect<Integer>(Ord(FModule.Elements[0].Mode)).ToBe(Ord(wemActive));
  Expect<Integer>(Length(FModule.Elements[0].FuncIndices)).ToBe(2);

  Expect<Integer>(FModule.MemoryCount).ToBe(1);
  Expect<Int64>(Int64(FModule.Memories[0].Limits.Min)).ToBe(1);
  Expect<Integer>(FModule.DataSegmentCount).ToBe(1);
  Expect<Integer>(Ord(FModule.DataSegments[0].Mode)).ToBe(Ord(wdmActive));
  Expect<Int64>(Int64(FModule.DataSegments[0].Bytes.Size)).ToBe(4);

  Expect<string>(ValidateOutcome(Src)).ToBe('valid');
  { The expression-list variant of the inline table-elem also validates. }
  Expect<string>(ValidateOutcome(
    '(module (func $f)' +
    '  (table funcref (elem (ref.func $f) (ref.null func))))')).ToBe('valid');

  { The inline table-elem abbreviation carries the TABLE's reftype, not a
    hardcoded funcref (text-table-abbrev / Telemtable_). A funcidx shorthand
    under a NON-funcref reftype must therefore lower to ref.func exprs under
    the table's reftype (flag 6), else the segment's element type mismatches
    the table (type-subtyping.wast:381, br_table.wast:3). The reftype must be
    nullable for the sugar to be valid: the desugared table carries no
    initialiser, so a non-defaultable (non-nullable) element type is rejected
    for want of one, independent of the segment — hence `(ref null $t)`. }
  Expect<string>(ValidateOutcome(
    '(module (type $t (sub (func))) (func $f (type $t))' +
    '  (table (ref null $t) (elem $f)))')).ToBe('valid');
  { And the decoded segment reports both entries for the concrete-ref case.
    The non-funcref reftype takes the flag-6 expr-list encoding, so the
    funcidxs land in InitExprs (as ref.func exprs), not FuncIndices. }
  AssembleAndDecode(
    '(module (type $t (sub (func)))' +
    '  (func $f (type $t)) (func $g (type $t))' +
    '  (table (ref null $t) (elem $f $g)))');
  Expect<Integer>(FModule.ElementCount).ToBe(1);
  Expect<Integer>(Ord(FModule.Elements[0].Mode)).ToBe(Ord(wemActive));
  Expect<Integer>(Length(FModule.Elements[0].InitExprs)).ToBe(2);
  { The lowered ref.func exprs still type-check each funcidx against rt: a
    function of an unrelated type is rejected by the validator, not masked. }
  Expect<string>(ValidateOutcome(
    '(module (type $t (sub (func)))' +
    '  (type $u (sub (func (param i32))))' +
    '  (func $f (type $u))' +
    '  (table (ref null $t) (elem $f)))')).ToBe('validation error');
end;

{ --- ref.test / ref.cast: the null variant is the +1 subopcode ---------- }

procedure TWatAsmTests.TestRefTestCast;
begin
  { ref.test (ref $s) is subopcode 20 (non-null) with a heap-type immediate;
    ref.test (ref null $s) is 21. ref.cast is 22/23. The +1 is easy to drop,
    so both spellings are round-tripped and validated. }
  AssembleAndDecode(
    '(module' +
    '  (type $s (struct))' +
    '  (func (param anyref) (result i32)' +
    '    (ref.test (ref $s) (local.get 0))))');
  { FB 14 (20) 00 (heaptype $s) — the non-null variant. }
  Expect<string>(BodyHex).ToBe('2000' + 'FB14' + '00' + '0B');

  AssembleAndDecode(
    '(module' +
    '  (type $s (struct))' +
    '  (func (param anyref) (result i32)' +
    '    (ref.test (ref null $s) (local.get 0))))');
  { FB 15 (21) 00 — the null variant, subopcode + 1. }
  Expect<string>(BodyHex).ToBe('2000' + 'FB15' + '00' + '0B');

  Expect<string>(ValidateOutcome(
    '(module' +
    '  (type $s (struct))' +
    '  (func (param anyref) (result (ref $s))' +
    '    (ref.cast (ref $s) (local.get 0))))')).ToBe('valid');
end;

{ --- forward type references inside type bodies (bug 1) ----------------- }

procedure TWatAsmTests.TestForwardTypeReference;
begin
  { A type body may reference a type by name that is defined later, or itself
    inside its own rec group — the pre-bind pass binds every type id before any
    body is parsed (type-subtyping.wast:37, type-rec.wast). Before the fix these
    raised a text `unknown type`; now they assemble and validate. }
  Expect<string>(ValidateOutcome(
    '(module (rec (type $r (sub (struct (field (ref $r)))))))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module' +
    '  (rec (type $a1 (sub (struct (field i32 (ref $a2)))))' +
    '       (type $a2 (sub (struct (field i64 (ref $a1)))))))')).ToBe('valid');
  { A numeric typeidx is NEVER range-checked at assembly — a bare out-of-range
    (type N) defers to the validator (func_ptrs.wast:48), so the module is
    'validation error', not an assemble error. }
  Expect<string>(ValidateOutcome('(module (func (type 42)))'))
    .ToBe('validation error');
end;

{ --- typeuse clause order + no param ids in instruction typeuses (bug 2) - }

procedure TWatAsmTests.TestTypeuseClauseOrder;

  function Bad(const AMod: string): Boolean;
  begin
    Result := StartsWith(AssembleError(AMod), 'unexpected token');
  end;

begin
  { Clause order in a typeuse is fixed (type)? (param)* (result)*; any other
    order is `unexpected token`, and so is a param id in an instruction typeuse
    which has no locals to name (call_indirect.wast:668-738, block.wast:421-463,
    func.wast:937-953). }
  Expect<Boolean>(Bad(
    '(module (type $s (func (param i32) (result i32))) (table 0 funcref)' +
    ' (func (result i32) (call_indirect (result i32) (type $s) (param i32)' +
    ' (i32.const 0) (i32.const 0))))')).ToBe(True);
  Expect<Boolean>(Bad(
    '(module (table 0 funcref)' +
    ' (func (call_indirect (param $x i32) (i32.const 0) (i32.const 0))))'))
    .ToBe(True);
  Expect<Boolean>(Bad(
    '(module (func (i32.const 0) (block (result i32) (param i32))))'))
    .ToBe(True);
  Expect<Boolean>(Bad('(module (func (nop) (local i32)))')).ToBe(True);
  Expect<Boolean>(Bad('(module (func (local i32) (param i32)))')).ToBe(True);
end;

{ --- inline function type in a blocktype (bug 4) ------------------------- }

procedure TWatAsmTests.TestBlockTypeInlineFuncType;

  function Bad(const AMod: string): Boolean;
  begin
    Result := StartsWith(AssembleError(AMod), 'inline function type');
  end;

begin
  { A blocktype (type $x) with inline (param)/(result) that disagree with $x is
    `inline function type`, not a downstream validation `type mismatch`
    (block.wast:467-494, if.wast:795, loop.wast:584). }
  Expect<Boolean>(Bad(
    '(module (type $sig (func))' +
    ' (func (block (type $sig) (result i32) (i32.const 0)) (unreachable)))'))
    .ToBe(True);
  Expect<Boolean>(Bad(
    '(module (type $sig (func (param i32 i32) (result i32)))' +
    ' (func (i32.const 0)' +
    '   (block (type $sig) (param i32) (result i32)) (unreachable)))'))
    .ToBe(True);
  { A matching inline declaration is legal (names locals only). }
  Expect<string>(ValidateOutcome(
    '(module (type $sig (func (param i32) (result i32)))' +
    ' (func (result i32) (i32.const 0)' +
    '   (block (type $sig) (param i32) (result i32))))')).ToBe('valid');
end;

{ --- data-count section is emitted when a data index occurs in code (bug 3) }

procedure TWatAsmTests.TestDataCountFromCode;
begin
  { data.drop / memory.init with NO data segments must still emit the data-count
    section, or DecodeModule rejects our own output (INV-1; memory_init.wast:189).
    The count is 0, so the module decodes and the VALIDATOR rejects the index. }
  Expect<string>(ValidateOutcome(
    '(module (func (export "t") (data.drop 0)))')).ToBe('validation error');
  Expect<string>(ValidateOutcome(
    '(module (memory 1) (func (memory.init 0 (i32.const 0) (i32.const 0)' +
    ' (i32.const 0))))')).ToBe('validation error');
  { With a matching data segment it is well-formed. }
  Expect<string>(ValidateOutcome(
    '(module (memory 1) (data "x")' +
    ' (func (memory.init 0 (i32.const 0) (i32.const 0) (i32.const 0))))'))
    .ToBe('valid');
end;

{ --- reserved token boundary vs unexpected token (bug 5) ---------------- }

procedure TWatAsmTests.TestReservedTokenIsUnknownOperator;

  function IsUnknownOp(const AMod: string): Boolean;
  begin
    Result := StartsWith(AssembleError(AMod), 'unknown operator');
  end;

begin
  { A reserved run (a longest-match token that is nothing the grammar names) is
    `unknown operator` wherever it appears — an operator, a br index, a field
    head, or a data-segment tail (token.wast:7-299). }
  Expect<Boolean>(IsUnknownOp('(func br 0drop)')).ToBe(True);
  Expect<Boolean>(IsUnknownOp(
    '(func (block $l (i32.const 0) (br_table 0$l)))')).ToBe(True);
  Expect<Boolean>(IsUnknownOp('(data $l"a")')).ToBe(True);
  Expect<Boolean>(IsUnknownOp('(data"a")')).ToBe(True);
  Expect<Boolean>(IsUnknownOp('(func "a"x)')).ToBe(True);
  { A misplaced but VALID token is `unexpected token`, not `unknown operator`. }
  Expect<Boolean>(StartsWith(
    AssembleError('(func (i32.const 0) (block (result i32) (param i32)))'),
    'unexpected token')).ToBe(True);
  { A bare-memidx active data segment (the `(memory 0)` abbreviation) is valid
    and must not be rejected by the tail check. }
  Expect<string>(ValidateOutcome(
    '(module (memory 1) (data 0 (i32.const 0) "\10"))')).ToBe('valid');
end;

{ --- nan:canonical / nan:arithmetic are patterns, not const literals ----- }

procedure TWatAsmTests.TestNanPatternsInConst;
begin
  { In a const, the result-match keywords are `unexpected token`, while a
    malformed nan payload like `nan:1` is `unknown operator`
    (i64.wast:487-491, const.wast:409-413). }
  Expect<Boolean>(StartsWith(
    AssembleError('(module (func (result i64) (i64.const nan:arithmetic)))'),
    'unexpected token')).ToBe(True);
  Expect<Boolean>(StartsWith(
    AssembleError('(module (func (result i64) (i64.const nan:canonical)))'),
    'unexpected token')).ToBe(True);
  Expect<Boolean>(StartsWith(
    AssembleError('(module (func (f32.const nan:1) drop))'),
    'unknown operator')).ToBe(True);
end;

{ --- br_on_cast emits the opcode exactly once (INV-1) -------------------- }

procedure TWatAsmTests.TestBrOnCastRoundTrip;
const
  Src =
    '(module' +
    '  (type $t (struct))' +
    '  (func (param anyref) (result anyref)' +
    '    (block $l (result (ref $t))' +
    '      (br_on_cast $l anyref (ref $t) (local.get 0))' +
    '      (unreachable))))';
begin
  { br_on_cast is a fixed-opcode shape routed through EmitImmediatesBody, so it
    must NOT re-emit the $FB prefix — doing so made the decoder read the second
    $FB as the cast-flags byte (`malformed cast flags $FB`, INV-1). }
  Expect<string>(ValidateOutcome(Src)).ToBe('valid');
end;

{ --- SIMD immediate shapes (Track G, Wave G2) --------------------------- }

procedure TWatAsmTests.TestVectorConstAllShapes;

  function ConstBody(const AShapeAndLanes: string): string;
  begin
    AssembleAndDecode(
      '(module (func (result v128) (v128.const ' + AShapeAndLanes + ')))');
    Result := BodyHex;
  end;

begin
  { v128.const <shape> <lane>… -> FD 0C then 16 raw bytes little-endian, low
    lane first, then the end byte 0B. All six shapes, with the exact emitted
    bytes computed by hand (integer lanes LE; float lanes their IEEE754 bits
    LE). This pins both the count-per-shape and the little-endian lane layout. }
  Expect<string>(ConstBody('i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15'))
    .ToBe('FD0C' + '000102030405060708090A0B0C0D0E0F' + '0B');
  Expect<string>(ConstBody('i16x8 0 1 2 3 4 5 6 7'))
    .ToBe('FD0C' + '00000100020003000400050006000700' + '0B');
  Expect<string>(ConstBody('i32x4 0 1 2 3'))
    .ToBe('FD0C' + '00000000010000000200000003000000' + '0B');
  Expect<string>(ConstBody('i64x2 0 1'))
    .ToBe('FD0C' + '00000000000000000100000000000000' + '0B');
  { f32(0,1,2,3) = 00000000 3F800000 40000000 40400000, each little-endian. }
  Expect<string>(ConstBody('f32x4 0 1 2 3'))
    .ToBe('FD0C' + '000000000000803F0000004000004040' + '0B');
  { f64(0,1) = 0000000000000000 3FF0000000000000, each little-endian. }
  Expect<string>(ConstBody('f64x2 0 1'))
    .ToBe('FD0C' + '0000000000000000000000000000F03F' + '0B');
  { A flat (non-folded) const followed by drop encodes identically. }
  AssembleAndDecode('(module (func v128.const i32x4 1 2 3 4 drop))');
  Expect<string>(BodyHex)
    .ToBe('FD0C' + '01000000020000000300000004000000' + '1A' + '0B');
end;

procedure TWatAsmTests.TestVectorShuffleAndLanes;
begin
  { i8x16.shuffle: 16 lane indices as 16 raw bytes AFTER the two folded
    operands (2000 2001), opcode FD 0D. Indices 0..15 then 16..31. }
  AssembleAndDecode(
    '(module (func (param v128 v128) (result v128)' +
    '  (i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15' +
    '    (local.get 0) (local.get 1))))');
  Expect<string>(BodyHex)
    .ToBe('20002001' + 'FD0D' + '000102030405060708090A0B0C0D0E0F' + '0B');
  AssembleAndDecode(
    '(module (func (param v128 v128) (result v128)' +
    '  (i8x16.shuffle 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31' +
    '    (local.get 0) (local.get 1))))');
  Expect<string>(BodyHex)
    .ToBe('20002001' + 'FD0D' + '101112131415161718191A1B1C1D1E1F' + '0B');

  { extract_lane_s: operand then FD 15 (sub 21) then one laneidx byte. }
  AssembleAndDecode(
    '(module (func (param v128) (result i32)' +
    '  (i8x16.extract_lane_s 3 (local.get 0))))');
  Expect<string>(BodyHex).ToBe('2000' + 'FD15' + '03' + '0B');
  { replace_lane: two operands (vector, scalar) then FD 17 (sub 23) + lane. }
  AssembleAndDecode(
    '(module (func (param v128) (result v128)' +
    '  (i8x16.replace_lane 3 (local.get 0) (i32.const 7))))');
  Expect<string>(BodyHex).ToBe('2000' + '4107' + 'FD17' + '03' + '0B');
  { swizzle takes no immediate: FD 0E after the two operands. }
  AssembleAndDecode(
    '(module (func (param v128 v128) (result v128)' +
    '  (i8x16.swizzle (local.get 0) (local.get 1))))');
  Expect<string>(BodyHex).ToBe('20002001' + 'FD0E' + '0B');
  { a multi-byte-LEB subopcode proves the widened UInt32 field: i16x8.abs is
    subopcode 128 = FD 80 01. }
  AssembleAndDecode(
    '(module (func (param v128) (result v128) (i16x8.abs (local.get 0))))');
  Expect<string>(BodyHex).ToBe('2000' + 'FD8001' + '0B');
end;

procedure TWatAsmTests.TestVectorMemoryAndLaneLookahead;
begin
  { v128.load, default alignment: natural align log2 4 -> flags 04, offset 0,
    so FD 00 04 00 after the address operand (i32.const 0 = 4100). }
  AssembleAndDecode(
    '(module (memory 1) (func (result v128) (v128.load (i32.const 0))))');
  Expect<string>(BodyHex).ToBe('4100' + 'FD00' + '04' + '00' + '0B');
  { explicit align=8 (log2 3) and offset=16 (0x10). }
  AssembleAndDecode(
    '(module (memory 1) (func (result v128)' +
    '  (v128.load offset=16 align=8 (i32.const 0))))');
  Expect<string>(BodyHex).ToBe('4100' + 'FD00' + '03' + '10' + '0B');

  { load8_lane, lane only (no memidx): the leading `3` is the LANE because the
    token after it is `(`. FD 54 (sub 84) then memarg (flags 00, offset 00)
    then the lane byte 03. Operands: address (4100) then source vector (2000). }
  AssembleAndDecode(
    '(module (memory 1) (func (param v128) (result v128)' +
    '  (v128.load8_lane 3 (i32.const 0) (local.get 0))))');
  Expect<string>(BodyHex)
    .ToBe('4100' + '2000' + 'FD54' + '00' + '00' + '03' + '0B');
  { load8_lane, memidx THEN lane: `1 3` — the leading `1` is the MEMIDX because
    a numeric follows it (the §5.5 lookahead). flags 40 (memidx bit), memidx
    01, offset 00, lane 03. }
  AssembleAndDecode(
    '(module (memory 1) (func (param v128) (result v128)' +
    '  (v128.load8_lane 1 3 (i32.const 0) (local.get 0))))');
  Expect<string>(BodyHex)
    .ToBe('4100' + '2000' + 'FD54' + '40' + '01' + '00' + '03' + '0B');
  { store8_lane with an explicit memarg then lane: `offset=0 align=1 2`. No
    memidx (leads with a keyword), align=1 -> log2 0, lane 2. FD 58 (sub 88). }
  AssembleAndDecode(
    '(module (memory 1) (func (param v128)' +
    '  (v128.store8_lane offset=0 align=1 2 (i32.const 0) (local.get 0))))');
  Expect<string>(BodyHex)
    .ToBe('4100' + '2000' + 'FD58' + '00' + '00' + '02' + '0B');
end;

procedure TWatAsmTests.TestVectorImmediateErrors;
begin
  { Wrong lane-literal count (too few) -> `wrong number of lane literals`
    (simd_const.wast:241-309). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const i8x16 0 0 0 0) drop))'),
    MSG_WRONG_LANE_LITERALS)).ToBe(True);
  { A no-lane const is also the wrong count. }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const f64x2) drop))'),
    MSG_WRONG_LANE_LITERALS)).ToBe(True);

  { Wrong shuffle-index count, both 15 and 17 -> `wrong number of lane
    indices` (simd_lane.wast:514-520). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (param v128 v128) (result v128)' +
    '  (i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14' +
    '    (local.get 0) (local.get 1))))'),
    MSG_WRONG_LANE_INDICES)).ToBe(True);
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (param v128 v128) (result v128)' +
    '  (i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16' +
    '    (local.get 0) (local.get 1))))'),
    MSG_WRONG_LANE_INDICES)).ToBe(True);

  { A v128.const lane literal out of its width raises the BARE `constant out
    of range` (simd_const.wast:238), even for i8x16 256. }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const i8x16 256 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0) drop))'),
    'constant out of range')).ToBe(True);
  { And a zero NaN payload lane is `constant out of range` too. }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const f32x4 nan:0x0 nan:0x0 nan:0x0 nan:0x0) drop))'),
    'constant out of range')).ToBe(True);

  { A lane INDEX out of the i8 byte range raises the WIDTH-PREFIXED `i8
    constant out of range` (simd_lane.wast:415), the split that must stay
    distinct from the bare literal message. }
  Expect<string>(AssembleError(
    '(module (func (param v128) (result i32)' +
    '  (i8x16.extract_lane_s 256 (local.get 0))))'))
    .ToBe('i8 constant out of range');
  { A shuffle index of 256 is the same width-prefixed message. }
  Expect<string>(AssembleError(
    '(module (func (param v128 v128) (result v128)' +
    '  (i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 256' +
    '    (local.get 0) (local.get 1))))'))
    .ToBe('i8 constant out of range');
  { A signed lane index (-1) is `unexpected token`, not a range error
    (simd_lane.wast:398, 522). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (param v128) (result i32)' +
    '  (i8x16.extract_lane_s -1 (local.get 0))))'),
    MSG_UNEXPECTED_TOKEN)).ToBe(True);
  { nan:canonical / a missing shape in a const is `unexpected token`. }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const f32x4 nan:canonical 0 0 0) drop))'),
    MSG_UNEXPECTED_TOKEN)).ToBe(True);
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const) drop))'),
    MSG_UNEXPECTED_TOKEN)).ToBe(True);

  { align not a power of two, on a vector load -> `alignment must be a power
    of two` (simd_align.wast). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (memory 1) (func (result v128)' +
    '  (v128.load align=3 (i32.const 0))))'),
    'alignment must be a power of two')).ToBe(True);
end;

procedure TWatAsmTests.TestTableInitExpr;
begin
  { The 3.0 explicit-init table form `(table limits reftype constexpr)`:
    a folded constant initialises every slot, encoded as $40 $00 tt e
    (table.wast:19-21, elem.wast:91). Assemble -> decode -> validate. }
  Expect<string>(ValidateOutcome(
    '(module (table 1 funcref (ref.null func)))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (func $f) (func $g)' +
    '  (table $t 10 (ref func) (ref.func $f))' +
    '  (elem (i32.const 3) $g))')).ToBe('valid');
  { And the decoded model carries exactly one table. }
  AssembleAndDecode('(module (table 1 funcref (ref.null func)))');
  Expect<Integer>(FModule.TableCount).ToBe(1);

  { An active element segment whose element type is NON-funcref (externref)
    must use flag 6 (explicit reftype), not the funcref-implied flag 4
    (elem.wast:1027) — else validation reports a funcref/externref mismatch. }
  Expect<string>(ValidateOutcome(
    '(module (table 2 externref)' +
    '  (elem (i32.const 0) externref (ref.null extern)))')).ToBe('valid');
  { The mismatched form (funcref value into an externref elem) still fails
    validation, so flag 6 is doing real type checking, not masking it. }
  Expect<string>(ValidateOutcome(
    '(module (table 1 (ref null func) (i32.const 0)))'))
    .ToBe('validation error');
end;

procedure TWatAsmTests.TestInlineMemDataAddrType;
begin
  { `(memory addrtype? (data …))` — an i64 memory keeps its address type and
    the synthetic active data segment takes an i64.const 0 offset
    (memory64.wast:11-15). Both i32 and i64 forms must validate. }
  Expect<string>(ValidateOutcome(
    '(module (memory (data "abc")))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (memory i64 (data "abc")))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (memory i64 (data)))')).ToBe('valid');
  { The address type reaches the decoded model. }
  AssembleAndDecode('(module (memory i64 (data "x")))');
  Expect<Boolean>(FModule.Memories[0].Limits.AddrType = watI64)
    .ToBe(True);
end;

procedure TWatAsmTests.TestTableAddrType;
begin
  { The 3.0 address-type keyword before a table's limits (table64.wast:1-12,
    text-tabletype/text-addrtype). The explicit i32 form, the i64 form, and
    the inline-elem sugar `(table addrtype? reftype (elem …))` (whose synthetic
    active elem segment takes an offset const of the table's address type —
    call_indirect64.wast:11) must all assemble, decode, and validate. }
  Expect<string>(ValidateOutcome(
    '(module (table i32 1 funcref))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (table i64 1 funcref))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (table i64 1 2 funcref))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (func $f) (table i64 funcref (elem $f)))')).ToBe('valid');
  Expect<string>(ValidateOutcome(
    '(module (func $f) (table i32 funcref (elem $f)))')).ToBe('valid');
  { call_indirect on an i64-addressed table validates: the index operand is
    an i64 for an i64 table (call_indirect64.wast). }
  Expect<string>(ValidateOutcome(
    '(module (type $t (func)) (table $t64 i64 1 funcref)'
    + ' (func (i64.const 0) (call_indirect $t64 (type $t))))')).ToBe('valid');
  { The same call_indirect with an i32 index on an i64 table is a type
    mismatch — proof the address type reaches the operand check. }
  Expect<string>(ValidateOutcome(
    '(module (type $t (func)) (table $t64 i64 1 funcref)'
    + ' (func (i32.const 0) (call_indirect $t64 (type $t))))'))
    .ToBe('validation error');
  { The address type and the synthetic elem offset type reach the model:
    an i64 table's inline-elem segment must NOT be an i32.const 0 offset. }
  AssembleAndDecode('(module (func $f) (table i64 funcref (elem $f)))');
  Expect<Boolean>(FModule.Tables[0].TableType.Limits.AddrType = watI64)
    .ToBe(True);
end;

procedure TWatAsmTests.TestObsoleteKeywordIsUnknownOperator;
begin
  { `anyfunc` is the removed pre-1.0 alias for funcref. Upstream lexes it as a
    reserved atom, so meeting it where a type is expected is `unknown operator
    anyfunc`, not `unexpected token` (obsolete-keywords.wast:40; §4). }
  Expect<string>(AssembleError('(module (global $g anyfunc (ref.null func)))'))
    .ToBe('unknown operator anyfunc');
  { A VALID but misplaced keyword stays `unexpected token`. }
  Expect<Boolean>(StartsWith(
    AssembleError('(func (i32.const 0) (block (result i32) (param i32)))'),
    'unexpected token')).ToBe(True);
end;

procedure TWatAsmTests.TestMemArgSignedIsUnknownOperator;
begin
  { A memarg align/offset value is a uN — no sign. A leading `-`/`+` makes the
    whole `align=…`/`offset=…` a reserved token: `unknown operator <token>`,
    NOT a range or power-of-two error (simd_align.wast:104 align=-1,
    simd_address.wast:112 offset=-1; design §c.6/§d.1). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (memory 1) (func (result v128)' +
    '  (v128.load align=-1 (i32.const 0))))'),
    'unknown operator')).ToBe(True);
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (memory 1) (func (result v128)' +
    '  (v128.load offset=-1 (i32.const 0))))'),
    'unknown operator')).ToBe(True);
  { The offending token is appended after the prefix. }
  Expect<string>(AssembleError(
    '(module (memory 1) (func i32.const 0 i32.load align=-1 drop))'))
    .ToBe('unknown operator align=-1');
  { A well-formed but oversized power-of-two align is NOT a text error — it
    reaches the validator's natural-alignment check (align.wast:1016). }
  Expect<string>(ValidateOutcome(
    '(module (memory 1) (func i32.const 0' +
    '  i32.load offset=0xFFFFFFFFFFFFFFFF align=0x8000000000000000 drop))'))
    .ToBe('validation error');
end;

procedure TWatAsmTests.TestVectorConstCountBeforeValue;
begin
  { A short lane list is `wrong number of lane literals` even when the tokens
    present are themselves out of range — the COUNT is checked before any value
    is parsed (simd_const.wast:480). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const i32x4' +
    '  0x10000000000000000 0x10000000000000000) drop))'),
    MSG_WRONG_LANE_LITERALS)).ToBe(True);
  { A `nan:1` lane (non-hex payload) is CONSUMED as the lane and rejected as
    `unknown operator`, not cut short as a count error (simd_const.wast:384). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const f32x4 nan:1 nan:1 nan:1 nan:1) drop))'),
    'unknown operator')).ToBe(True);
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (v128.const f64x2 nan:1 nan:1) drop))'),
    'unknown operator')).ToBe(True);
  { A signed lane INDEX with `+` is unexpected token (simd_lane.wast:877). }
  Expect<Boolean>(StartsWith(AssembleError(
    '(module (func (param v128) (result i32)' +
    '  (i8x16.extract_lane_u +0x0f (local.get 0))))'),
    MSG_UNEXPECTED_TOKEN)).ToBe(True);
end;

procedure TWatAsmTests.SetupTests;
begin
  Test('an empty module (and bare fields) decode to zero sections',
    TestEmptyModule);
  Test('implicit typeuse appends after explicit types (func.wast:422)',
    TestImplicitTypeuseOracle);
  Test('explicit types are never deduped (func_ptrs.wast:2)',
    TestExplicitTypesNeverDeduped);
  Test('implicit typeuse does not reuse a rec-group member (type-rec.wast:45)',
    TestRecGroupMemberNotReused);
  Test('inline import/export abbreviations decode to the right entries',
    TestInlineImportExport);
  Test('elem and data sugar forms decode correctly',
    TestElemAndDataSugar);
  Test('a func with named and indexed locals assembles and validates',
    TestNamedAndIndexedLocals);
  Test('label shadowing resolves innermost-first at the br bytes',
    TestLabelShadowingDepths);
  Test('a duplicate identifier is a text error',
    TestDuplicateIdentifier);
  Test('a forward reference (call a later func) resolves',
    TestForwardReference);
  Test('a still-staged vector mnemonic raises unknown operator',
    TestUnknownOperatorPlaceholder);
  Test('committed fixtures assemble to the same section shape',
    TestFixturesSectionShape);
  Test('folded-if emits the condition before the opcode (if.wast:19)',
    TestFoldedIfArmOrder);
  Test('memarg defaults and explicit align/offset encode correctly',
    TestMemArgDefaults);
  Test('a broad instruction mix assembles, decodes and validates',
    TestBroadInstructionRoundTrip);
  Test('GC struct/array with field-by-name resolution',
    TestGcStructAndArray);
  Test('a mismatching trailing block label is a text error',
    TestMismatchingLabel);
  Test('try_table with a catch clause resolved in the enclosing scope',
    TestTryTable);
  Test('call_indirect typeuse, typed select and br_table',
    TestCallIndirectSelectBrTable);
  Test('inline (table (elem …)) and (memory (data …)) desugar to segments',
    TestInlineSegments);
  Test('ref.test/ref.cast encode the null variant as the +1 subopcode',
    TestRefTestCast);
  Test('a forward/self type reference in a type body resolves (bug 1)',
    TestForwardTypeReference);
  Test('typeuse clause order and param-id bans are text errors (bug 2)',
    TestTypeuseClauseOrder);
  Test('a blocktype inline decl mismatch is inline function type (bug 4)',
    TestBlockTypeInlineFuncType);
  Test('a data index in code emits the data-count section (bug 3)',
    TestDataCountFromCode);
  Test('a reserved token is unknown operator, not unexpected token (bug 5)',
    TestReservedTokenIsUnknownOperator);
  Test('nan:canonical/nan:arithmetic in a const are unexpected token',
    TestNanPatternsInConst);
  Test('br_on_cast emits its opcode once and round-trips (INV-1)',
    TestBrOnCastRoundTrip);
  Test('v128.const all six shapes emit 16 little-endian bytes',
    TestVectorConstAllShapes);
  Test('i8x16.shuffle, extract/replace_lane, swizzle and a LEB subopcode',
    TestVectorShuffleAndLanes);
  Test('vector load/store memarg and the memidx-vs-lane lookahead',
    TestVectorMemoryAndLaneLookahead);
  Test('vector immediate error cases (counts, ranges, alignment)',
    TestVectorImmediateErrors);
  Test('table explicit-init expr and non-funcref active elem (table.wast:19)',
    TestTableInitExpr);
  Test('inline (memory i64 (data …)) keeps the i64 address type',
    TestInlineMemDataAddrType);
  Test('table addrtype text: (table i64 …) and inline-elem i64 (table64.wast)',
    TestTableAddrType);
  Test('an obsolete keyword (anyfunc) is unknown operator (obsolete-keywords)',
    TestObsoleteKeywordIsUnknownOperator);
  Test('a signed align=/offset= is unknown operator (simd_align.wast:104)',
    TestMemArgSignedIsUnknownOperator);
  Test('v128.const checks lane COUNT before value (simd_const.wast:480)',
    TestVectorConstCountBeforeValue);
end;

begin
  TestRunnerProgram.AddSuite(TWatAsmTests.Create('Wasm.Wat.Assembler'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
