{ Unit suite for Wasm.Decoder.Entities' entity-section decoders.

  Happy paths hand-assemble each section body as literal bytes and
  assert the decoded model fields — all five import/export kinds, both
  table forms (default-init and the 3.0 $40 $00 explicit-init form), a
  global with a nontrivial init expression whose span is pinned exactly,
  duplicate export names decoding fine (name disjointness is module
  VALIDITY, not grammar), start, and tags.

  Malformed inputs are spelled as literal bytes next to the assertion:
  unassigned discriminator bytes, truncated and non-UTF-8 names,
  truncated vectors, leftover bytes after the declared content (the
  "section size mismatch" family), a trailing byte after the start
  funcidx, and the table-init form with a nonzero reserved byte. }
program Wasm.Decoder.Entities.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Entities,
  Wasm.Module;

type
  TDecoderEntitiesTests = class(TTestSuite)
  private
    { The reader borrows its buffer, so the buffer must outlive every
      reader built over it — hence a suite field. }
    FBuffer: TWasmBytes;
    FModule: TWasmModule;

    function ReaderOver(const AValues: array of Byte): TWasmReader;
    { Runs the decoder named by ASection over AValues (ABase = 0) into a
      fresh module and asserts it raises EWasmDecodeError. }
    procedure ExpectRejected(const ASection, ADescription: string;
      const AValues: array of Byte);
    procedure AssertRejected(const ADescription: string;
      const ARejected: Boolean);
    procedure DecodeSection(const ASection: string;
      var AReader: TWasmReader; const ABase: NativeUInt);
  public
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure SetupTests; override;

    procedure TestImportsOfAllFiveKinds;
    procedure TestImportRejectsMalformed;
    procedure TestFunctionSection;
    procedure TestFunctionRejectsMalformed;
    procedure TestTablePlainForm;
    procedure TestTableExplicitInitForm;
    procedure TestTableRejectsMalformed;
    procedure TestMemorySection;
    procedure TestMemoryRejectsMalformed;
    procedure TestGlobalSection;
    procedure TestGlobalInitSpanUsesBase;
    procedure TestGlobalRejectsMalformed;
    procedure TestExportsIncludingDuplicateName;
    procedure TestExportRejectsMalformed;
    procedure TestStartSection;
    procedure TestStartRejectsMalformed;
    procedure TestTagSection;
    procedure TestTagRejectsMalformed;
  end;

procedure TDecoderEntitiesTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TDecoderEntitiesTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

function TDecoderEntitiesTests.ReaderOver(
  const AValues: array of Byte): TWasmReader;
var
  I: Integer;
begin
  SetLength(FBuffer, Length(AValues));
  for I := 0 to High(AValues) do
    FBuffer[I] := AValues[I];
  Result.InitFromBytes(FBuffer);
end;

procedure TDecoderEntitiesTests.DecodeSection(const ASection: string;
  var AReader: TWasmReader; const ABase: NativeUInt);
begin
  if ASection = 'import' then
    DecodeImportSection(AReader, ABase, FModule)
  else if ASection = 'function' then
    DecodeFunctionSection(AReader, ABase, FModule)
  else if ASection = 'table' then
    DecodeTableSection(AReader, ABase, FModule)
  else if ASection = 'memory' then
    DecodeMemorySection(AReader, ABase, FModule)
  else if ASection = 'global' then
    DecodeGlobalSection(AReader, ABase, FModule)
  else if ASection = 'export' then
    DecodeExportSection(AReader, ABase, FModule)
  else if ASection = 'start' then
    DecodeStartSection(AReader, ABase, FModule)
  else if ASection = 'tag' then
    DecodeTagSection(AReader, ABase, FModule)
  else
    Fail('unknown section kind ' + ASection);
end;

procedure TDecoderEntitiesTests.ExpectRejected(
  const ASection, ADescription: string; const AValues: array of Byte);
var
  Reader: TWasmReader;
  Rejected: Boolean;
begin
  Reader := ReaderOver(AValues);
  Rejected := False;

  { The assertion is made after the try, not inside the handler: a Fail()
    in the try block would be swallowed, and FPC will not parse a generic
    call as the lone statement of an `on ... do`. }
  try
    DecodeSection(ASection, Reader, 0);
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;

  AssertRejected(ADescription, Rejected);
end;

procedure TDecoderEntitiesTests.AssertRejected(const ADescription: string;
  const ARejected: Boolean);
var
  Outcome: string;
begin
  if ARejected then
    Outcome := 'rejected'
  else
    Outcome := 'ACCEPTED';
  Expect<string>(ADescription + ': ' + Outcome)
    .ToBe(ADescription + ': rejected');
end;

procedure TDecoderEntitiesTests.TestImportsOfAllFiveKinds;
var
  R: TWasmReader;
begin
  { Five imports, one per discriminator byte $00..$04, all from module
    "env" (name lengths first — names are length-prefixed byte vecs). }
  R := ReaderOver([
    $05,                                       { vec count }
    $03, $65, $6E, $76, $01, $66, $00, $2A,    { "env" "f" func typeidx 42 }
    $03, $65, $6E, $76, $01, $74, $01,         { "env" "t" table }
      $70, $00, $0A,                           {   funcref, min 10 }
    $03, $65, $6E, $76, $01, $6D, $02,         { "env" "m" mem }
      $01, $01, $02,                           {   min 1 max 2 }
    $03, $65, $6E, $76, $01, $67, $03,         { "env" "g" global }
      $7F, $01,                                {   (mut i32) }
    $03, $65, $6E, $76, $01, $65, $04,         { "env" "e" tag }
      $00, $03]);                              {   attribute 0, typeidx 3 }
  DecodeImportSection(R, 0, FModule);

  Expect<Integer>(FModule.ImportCount).ToBe(5);
  Expect<string>(FModule.Imports[0].ModuleName).ToBe('env');
  Expect<string>(FModule.Imports[0].Name).ToBe('f');
  Expect<Boolean>(FModule.Imports[0].Kind = wxkFunc).ToBe(True);
  Expect<Int64>(Int64(FModule.Imports[0].FuncTypeIndex)).ToBe(42);
  Expect<Boolean>(FModule.Imports[1].Kind = wxkTable).ToBe(True);
  Expect<string>(FModule.Imports[1].Table.Describe).ToBe('10 funcref');
  Expect<Boolean>(FModule.Imports[2].Kind = wxkMem).ToBe(True);
  Expect<string>(FModule.Imports[2].Mem.Describe).ToBe('1 2');
  Expect<Boolean>(FModule.Imports[3].Kind = wxkGlobal).ToBe(True);
  Expect<string>(FModule.Imports[3].Global.Describe).ToBe('(mut i32)');
  Expect<Boolean>(FModule.Imports[4].Kind = wxkTag).ToBe(True);
  Expect<Int64>(Int64(FModule.Imports[4].Tag.TypeIndex)).ToBe(3);
end;

procedure TDecoderEntitiesTests.TestImportRejectsMalformed;
begin
  { $05 is the first unassigned discriminator. }
  ExpectRejected('import', 'unassigned extern kind $05',
    [$01, $01, $61, $01, $66, $05, $00]);
  { Name declares 5 bytes but only 1 follows. }
  ExpectRejected('import', 'truncated module name',
    [$01, $05, $61]);
  { $80 is a lone UTF-8 continuation byte — names are UTF-8 as a DECODE
    rule, so this is malformed, not invalid. }
  ExpectRejected('import', 'non-UTF-8 item name',
    [$01, $01, $61, $01, $80, $00, $00]);
  { $C0 $AF is the classic overlong spelling of '/' — overlong forms
    are excluded by the utf8 grammar, so the name is malformed. }
  ExpectRejected('import', 'overlong UTF-8 in module name',
    [$01, $02, $C0, $AF, $01, $66, $00, $00]);
  { $ED $A0 $80 encodes the surrogate U+D800, which the utf8 grammar
    excludes. }
  ExpectRejected('import', 'surrogate in module name',
    [$01, $03, $ED, $A0, $80, $01, $66, $00, $00]);
  { Vec declares two imports; only one is present. }
  ExpectRejected('import', 'truncated import vec',
    [$02, $01, $61, $01, $66, $00, $00]);
  { Empty vec followed by a stray byte: section size mismatch. }
  ExpectRejected('import', 'leftover byte after content',
    [$00, $00]);
  ExpectRejected('import', 'empty body', []);
end;

procedure TDecoderEntitiesTests.TestFunctionSection;
var
  R: TWasmReader;
begin
  R := ReaderOver([$03, $00, $01, $2A]);
  DecodeFunctionSection(R, 0, FModule);

  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(3);
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[0])).ToBe(0);
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[1])).ToBe(1);
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[2])).ToBe(42);
end;

procedure TDecoderEntitiesTests.TestFunctionRejectsMalformed;
begin
  ExpectRejected('function', 'truncated typeidx vec', [$02, $00]);
  ExpectRejected('function', 'leftover byte after content',
    [$01, $00, $00]);
  ExpectRejected('function', 'empty body', []);
end;

procedure TDecoderEntitiesTests.TestTablePlainForm;
var
  R: TWasmReader;
begin
  R := ReaderOver([$01, $70, $00, $0A]);
  DecodeTableSection(R, 0, FModule);

  Expect<Integer>(FModule.TableCount).ToBe(1);
  Expect<string>(FModule.Tables[0].TableType.Describe).ToBe('10 funcref');
  Expect<Boolean>(FModule.Tables[0].HasInit).ToBe(False);
end;

procedure TDecoderEntitiesTests.TestTableExplicitInitForm;
var
  R: TWasmReader;
begin
  { Two tables: the $40 $00 explicit-init form (tabletype, then the init
    expr `ref.null func; end` = $D0 $70 $0B), then a plain one — both
    forms must coexist in one vec. }
  R := ReaderOver([
    $02,
    $40, $00, $6F, $01, $01, $05, $D0, $70, $0B,
    $70, $00, $00]);
  DecodeTableSection(R, 7, FModule);

  Expect<Integer>(FModule.TableCount).ToBe(2);
  Expect<Boolean>(FModule.Tables[0].HasInit).ToBe(True);
  Expect<string>(FModule.Tables[0].TableType.Describe)
    .ToBe('1 5 externref');
  { The expr starts at body offset 7 (count, marker, reserved byte, then
    the 4-byte tabletype) and is 3 bytes including its `end`; ABase = 7
    shifts the span to absolute offset 14. }
  Expect<Int64>(Int64(FModule.Tables[0].Init.Offset)).ToBe(14);
  Expect<Int64>(Int64(FModule.Tables[0].Init.Size)).ToBe(3);
  Expect<Boolean>(FModule.Tables[1].HasInit).ToBe(False);
  Expect<string>(FModule.Tables[1].TableType.Describe).ToBe('0 funcref');
end;

procedure TDecoderEntitiesTests.TestTableRejectsMalformed;
begin
  { The byte after the $40 marker is reserved and must be zero. }
  ExpectRejected('table', 'nonzero reserved byte in init form',
    [$01, $40, $01, $70, $00, $0A, $D0, $70, $0B]);
  { Init form whose expr never reaches its `end`. }
  ExpectRejected('table', 'unterminated init expr',
    [$01, $40, $00, $70, $00, $0A, $D0, $70]);
  ExpectRejected('table', 'truncated table vec', [$02, $70, $00, $00]);
  ExpectRejected('table', 'leftover byte after content',
    [$01, $70, $00, $00, $00]);
  ExpectRejected('table', 'empty body', []);
end;

procedure TDecoderEntitiesTests.TestMemorySection;
var
  R: TWasmReader;
begin
  R := ReaderOver([$02, $00, $01, $05, $01, $02]);
  DecodeMemorySection(R, 0, FModule);

  Expect<Integer>(FModule.MemoryCount).ToBe(2);
  Expect<string>(FModule.Memories[0].Describe).ToBe('1');
  Expect<string>(FModule.Memories[1].Describe).ToBe('i64 1 2');
end;

procedure TDecoderEntitiesTests.TestMemoryRejectsMalformed;
begin
  ExpectRejected('memory', 'undefined limits flags', [$01, $02, $00]);
  ExpectRejected('memory', 'truncated memtype vec', [$02, $00, $01]);
  ExpectRejected('memory', 'leftover byte after content',
    [$01, $00, $01, $00]);
end;

procedure TDecoderEntitiesTests.TestGlobalSection;
var
  R: TWasmReader;
begin
  { One (mut i32) global with the nontrivial init
    `i32.const 1; i32.const 2; i32.add; end` — the span must cover the
    whole expr including its `end`, and nothing before it. }
  R := ReaderOver([$01, $7F, $01, $41, $01, $41, $02, $6A, $0B]);
  DecodeGlobalSection(R, 0, FModule);

  Expect<Integer>(FModule.GlobalCount).ToBe(1);
  Expect<string>(FModule.Globals[0].GlobalType.Describe).ToBe('(mut i32)');
  Expect<Int64>(Int64(FModule.Globals[0].Init.Offset)).ToBe(3);
  Expect<Int64>(Int64(FModule.Globals[0].Init.Size)).ToBe(6);
end;

procedure TDecoderEntitiesTests.TestGlobalInitSpanUsesBase;
var
  R: TWasmReader;
begin
  { Same body under ABase = 100: spans are ABSOLUTE buffer offsets
    (ADR-0003), so the init shifts to 103. }
  R := ReaderOver([$01, $7F, $01, $41, $01, $41, $02, $6A, $0B]);
  DecodeGlobalSection(R, 100, FModule);

  Expect<Int64>(Int64(FModule.Globals[0].Init.Offset)).ToBe(103);
  Expect<Int64>(Int64(FModule.Globals[0].Init.Size)).ToBe(6);
end;

procedure TDecoderEntitiesTests.TestGlobalRejectsMalformed;
begin
  { i32.const with its immediate cut off. }
  ExpectRejected('global', 'truncated init expr', [$01, $7F, $00, $41]);
  ExpectRejected('global', 'unterminated init expr',
    [$01, $7F, $00, $41, $01]);
  ExpectRejected('global', 'bad mutability byte',
    [$01, $7F, $02, $41, $01, $0B]);
  ExpectRejected('global', 'leftover byte after content',
    [$01, $7F, $00, $41, $01, $0B, $00]);
end;

procedure TDecoderEntitiesTests.TestExportsIncludingDuplicateName;
var
  R: TWasmReader;
begin
  { Four exports, one per kind bar mem — including a DUPLICATE name "x":
    name disjointness is module validity (valid-module), not the binary
    grammar, so the decoder must accept it and leave the rejection to
    the validator. }
  R := ReaderOver([
    $04,
    $01, $78, $00, $01,    { "x" func 1 }
    $01, $79, $01, $00,    { "y" table 0 }
    $01, $78, $03, $02,    { "x" global 2 — duplicate name }
    $01, $7A, $04, $00]);  { "z" tag 0 }
  DecodeExportSection(R, 0, FModule);

  Expect<Integer>(FModule.ExportCount).ToBe(4);
  Expect<string>(FModule.&Exports[0].Name).ToBe('x');
  Expect<Boolean>(FModule.&Exports[0].Kind = wxkFunc).ToBe(True);
  Expect<Int64>(Int64(FModule.&Exports[0].Index)).ToBe(1);
  Expect<Boolean>(FModule.&Exports[1].Kind = wxkTable).ToBe(True);
  Expect<string>(FModule.&Exports[2].Name).ToBe('x');
  Expect<Boolean>(FModule.&Exports[2].Kind = wxkGlobal).ToBe(True);
  Expect<Int64>(Int64(FModule.&Exports[2].Index)).ToBe(2);
  Expect<Boolean>(FModule.&Exports[3].Kind = wxkTag).ToBe(True);
end;

procedure TDecoderEntitiesTests.TestExportRejectsMalformed;
begin
  ExpectRejected('export', 'unassigned extern kind $05',
    [$01, $01, $78, $05, $00]);
  ExpectRejected('export', 'truncated name', [$01, $05, $78]);
  ExpectRejected('export', 'non-UTF-8 name',
    [$01, $01, $80, $00, $00]);
  { Overlong form and surrogate — see the import suite for the byte
    spellings; the same DECODE rule applies to export names. }
  ExpectRejected('export', 'overlong UTF-8 name',
    [$01, $02, $C0, $AF, $00, $00]);
  ExpectRejected('export', 'surrogate in name',
    [$01, $03, $ED, $A0, $80, $00, $00]);
  ExpectRejected('export', 'truncated export vec',
    [$02, $01, $78, $00, $00]);
  ExpectRejected('export', 'leftover byte after content', [$00, $00]);
end;

procedure TDecoderEntitiesTests.TestStartSection;
var
  R: TWasmReader;
begin
  Expect<Boolean>(FModule.HasStart).ToBe(False);

  R := ReaderOver([$2A]);
  DecodeStartSection(R, 0, FModule);

  Expect<Boolean>(FModule.HasStart).ToBe(True);
  Expect<Int64>(Int64(FModule.StartFuncIndex)).ToBe(42);
end;

procedure TDecoderEntitiesTests.TestStartRejectsMalformed;
begin
  { The start section is a single funcidx, not a vec — anything after it
    is a size mismatch. }
  ExpectRejected('start', 'trailing byte after funcidx', [$2A, $00]);
  ExpectRejected('start', 'empty body', []);
  ExpectRejected('start', 'funcidx cut mid-LEB', [$80]);
end;

procedure TDecoderEntitiesTests.TestTagSection;
var
  R: TWasmReader;
begin
  R := ReaderOver([$02, $00, $01, $00, $05]);
  DecodeTagSection(R, 0, FModule);

  Expect<Integer>(FModule.TagCount).ToBe(2);
  Expect<Int64>(Int64(FModule.Tags[0].TypeIndex)).ToBe(1);
  Expect<Int64>(Int64(FModule.Tags[1].TypeIndex)).ToBe(5);
end;

procedure TDecoderEntitiesTests.TestTagRejectsMalformed;
begin
  { $00 is the only assigned tag attribute byte. }
  ExpectRejected('tag', 'bad attribute byte', [$01, $01, $00]);
  ExpectRejected('tag', 'truncated tag vec', [$02, $00, $01]);
  ExpectRejected('tag', 'leftover byte after content',
    [$01, $00, $01, $00]);
end;

procedure TDecoderEntitiesTests.SetupTests;
begin
  Test('imports of all five kinds', TestImportsOfAllFiveKinds);
  Test('imports reject malformed forms', TestImportRejectsMalformed);
  Test('function section', TestFunctionSection);
  Test('function section rejects malformed forms',
    TestFunctionRejectsMalformed);
  Test('tables: plain form', TestTablePlainForm);
  Test('tables: explicit-init form', TestTableExplicitInitForm);
  Test('tables reject malformed forms', TestTableRejectsMalformed);
  Test('memory section', TestMemorySection);
  Test('memory section rejects malformed forms',
    TestMemoryRejectsMalformed);
  Test('globals with init expressions', TestGlobalSection);
  Test('global init spans use the section base', TestGlobalInitSpanUsesBase);
  Test('globals reject malformed forms', TestGlobalRejectsMalformed);
  Test('exports including a duplicate name',
    TestExportsIncludingDuplicateName);
  Test('exports reject malformed forms', TestExportRejectsMalformed);
  Test('start section', TestStartSection);
  Test('start section rejects malformed forms', TestStartRejectsMalformed);
  Test('tag section', TestTagSection);
  Test('tag section rejects malformed forms', TestTagRejectsMalformed);
end;

begin
  TestRunnerProgram.AddSuite(
    TDecoderEntitiesTests.Create('Wasm.Decoder.Entities'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
