{ Cross-check against REAL toolchain output.

  The other suites assert against byte arrays written by hand, which
  proves the decoder matches our reading of the spec. This one runs it
  over modules produced by wabt and independently validated by
  wasm-tools, which proves it matches what the ecosystem actually emits.
  Those are different claims and both are worth having: the section-order
  bug this project already fixed was invisible to hand-written tests
  precisely because the same misreading produced both the code and the
  fixture.

  Every file under tests/fixtures/valid/ must decode; every file under
  tests/fixtures/malformed/ must be rejected. See tests/fixtures/README.md
  for what each one covers and how to regenerate the corpus.

  Test programs run with the repository root as the working directory
  (verified), so the relative paths below resolve. }
program Wasm.Fixtures.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Module;

const
  VALID_DIR = 'tests/fixtures/valid';
  MALFORMED_DIR = 'tests/fixtures/malformed';

  { A corpus that shrinks silently is a suite that passes vacuously, so
    the counts are asserted against a floor. Raise these when fixtures
    are added; never lower them to make a run go green. }
  MIN_VALID_FIXTURES = 11;
  MIN_MALFORMED_FIXTURES = 11;

type
  TFixtureTests = class(TTestSuite)
  private
    FBytes: TWasmBytes;
    FModule: TWasmModule;

    function ListFixtures(const ADir: string): TStringList;
    { Decodes APath into FModule. Returns '' on success, or the decode
      error's message. }
    function TryDecode(const APath: string): string;
    { Index of the first section with AId, or -1. }
    function IndexOf(const AId: TWasmSectionId): Integer;
    { Decodes valid/<AName> into FModule, asserting the decode succeeds
      so the model assertions that follow never run on a stale module. }
    procedure DecodeValid(const AName: string);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestCorpusIsPresent;
    procedure TestEveryValidFixtureDecodes;
    procedure TestEveryMalformedFixtureIsRejected;
    procedure TestDataCountPrecedesCode;
    procedure TestTagPrecedesGlobal;
    procedure TestSectionExtentsStayInsideTheModule;
    procedure TestExportsModel;
    procedure TestImportsModel;
    procedure TestStartModel;
    procedure TestDataCountModel;
    procedure TestMultiMemoryModel;
    procedure TestRefTypesModel;
    procedure TestSimdModel;
    procedure TestTagsModel;
    procedure TestCustomSectionsModel;
    procedure TestPaddedLebModel;
    procedure TestMinimalModel;
  end;

{ The directory constants are written with '/' because that is how the
  paths appear in docs and in the fixture README; SetDirSeparators makes
  them native so the Windows CI legs are not relying on the Win32 API's
  tolerance of forward slashes. }
function NativePath(const APath: string): string;
begin
  Result := SetDirSeparators(APath);
end;

function TFixtureTests.ListFixtures(const ADir: string): TStringList;
var
  Search: TSearchRec;
  Dir: string;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Dir := NativePath(ADir);
  if FindFirst(Dir + PathDelim + '*.wasm', faAnyFile, Search) = 0 then
    try
      repeat
        if (Search.Attr and faDirectory) = 0 then
          Result.Add(Dir + PathDelim + Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
end;

function TFixtureTests.TryDecode(const APath: string): string;
begin
  Result := '';
  try
    DecodeModuleFile(APath, FModule, FBytes);
  except
    on E: EWasmError do
      Result := E.Message;
  end;
end;

function TFixtureTests.IndexOf(const AId: TWasmSectionId): Integer;
begin
  Result := FModule.IndexOfSection(AId);
end;

procedure TFixtureTests.DecodeValid(const AName: string);
begin
  Expect<string>(TryDecode(NativePath(VALID_DIR + '/' + AName))).ToBe('');
end;

procedure TFixtureTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TFixtureTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

procedure TFixtureTests.TestCorpusIsPresent;
var
  Valid, Malformed: TStringList;
begin
  Valid := ListFixtures(VALID_DIR);
  Malformed := ListFixtures(MALFORMED_DIR);
  try
    { Phrased as a comparison rather than a bare count so a failure says
      what was found, not just that a number was wrong. }
    Expect<Boolean>(Valid.Count >= MIN_VALID_FIXTURES).ToBe(True);
    Expect<Boolean>(Malformed.Count >= MIN_MALFORMED_FIXTURES).ToBe(True);
    if Valid.Count < MIN_VALID_FIXTURES then
      Fail(Format('found %d valid fixtures in %s, expected at least %d ' +
        '(corpus missing? run tests/fixtures/regenerate.sh)',
        [Valid.Count, VALID_DIR, MIN_VALID_FIXTURES]));
    if Malformed.Count < MIN_MALFORMED_FIXTURES then
      Fail(Format('found %d malformed fixtures in %s, expected at least %d',
        [Malformed.Count, MALFORMED_DIR, MIN_MALFORMED_FIXTURES]));
  finally
    Valid.Free;
    Malformed.Free;
  end;
end;

procedure TFixtureTests.TestEveryValidFixtureDecodes;
var
  Files: TStringList;
  I: Integer;
  Error, Failures: string;
begin
  Failures := '';
  Files := ListFixtures(VALID_DIR);
  try
    for I := 0 to Files.Count - 1 do
    begin
      Error := TryDecode(Files[I]);
      if Error <> '' then
        Failures := Failures + #10 + '  ' + Files[I] + ': ' + Error;
    end;
  finally
    Files.Free;
  end;

  { Every failure is reported, not just the first — one broken decode
    rule usually breaks several fixtures, and the set names the rule. }
  Expect<string>(Failures).ToBe('');
end;

procedure TFixtureTests.TestEveryMalformedFixtureIsRejected;
var
  Files: TStringList;
  I: Integer;
  Accepted: string;
begin
  Accepted := '';
  Files := ListFixtures(MALFORMED_DIR);
  try
    for I := 0 to Files.Count - 1 do
      if TryDecode(Files[I]) = '' then
        Accepted := Accepted + #10 + '  ' + Files[I];
  finally
    Files.Free;
  end;

  Expect<string>(Accepted).ToBe('');
end;

procedure TFixtureTests.TestDataCountPrecedesCode;
var
  Error: string;
  DataCountAt, CodeAt: Integer;
begin
  { Real wabt output. The data count section is id 12 and the code
    section id 10, and this module has the former BEFORE the latter —
    the case that a decoder written on "ids must increase" rejects. }
  Error := TryDecode(NativePath(VALID_DIR + '/datacount.wasm'));
  Expect<string>(Error).ToBe('');

  DataCountAt := IndexOf(wsDataCount);
  CodeAt := IndexOf(wsCode);
  Expect<Boolean>(DataCountAt >= 0).ToBe(True);
  Expect<Boolean>(CodeAt >= 0).ToBe(True);
  Expect<Boolean>(DataCountAt < CodeAt).ToBe(True);
end;

procedure TFixtureTests.TestTagPrecedesGlobal;
var
  Error: string;
  TagAt, GlobalAt, MemoryAt: Integer;
begin
  { The second divergence: tag is id 13 but sits between memory (id 5)
    and global (id 6). }
  Error := TryDecode(NativePath(VALID_DIR + '/tags.wasm'));
  Expect<string>(Error).ToBe('');

  MemoryAt := IndexOf(wsMemory);
  TagAt := IndexOf(wsTag);
  GlobalAt := IndexOf(wsGlobal);
  Expect<Boolean>(TagAt >= 0).ToBe(True);
  Expect<Boolean>(MemoryAt < TagAt).ToBe(True);
  Expect<Boolean>(TagAt < GlobalAt).ToBe(True);
end;

procedure TFixtureTests.TestSectionExtentsStayInsideTheModule;
var
  Files: TStringList;
  I, J: Integer;
  Section: TWasmSectionInfo;
  Overruns: string;
begin
  { Offsets and sizes are handed to execution tiers as a window into the
    caller's buffer (ADR-0003), so an extent past the end of the module
    would be a memory-safety bug, not a reporting one. }
  Overruns := '';
  Files := ListFixtures(VALID_DIR);
  try
    for I := 0 to Files.Count - 1 do
    begin
      if TryDecode(Files[I]) <> '' then
        Continue;
      for J := 0 to FModule.SectionCount - 1 do
      begin
        Section := FModule[J];
        if Section.BodyOffset + Section.BodySize > FModule.Size then
          Overruns := Overruns + #10 + '  ' + Files[I] + ' ' +
            Section.DisplayName;
      end;
    end;
  finally
    Files.Free;
  end;

  Expect<string>(Overruns).ToBe('');
end;

{ --- per-fixture model expectations --------------------------------------

  Ground truth for every assertion below is the co-located .wat source
  (tests/fixtures/valid/*.wat) — entity counts, declaration order, and
  names all come from there, not from what the decoder happened to
  produce. padded-leb-size.wasm has no .wat; regenerate.sh derives it
  from exports.wasm by padding one size LEB, so it shares exports'
  model. }

procedure TFixtureTests.TestExportsModel;
var
  First: TWasmExport;
begin
  DecodeValid('exports.wasm');
  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(2);
  Expect<Integer>(FModule.TableCount).ToBe(1);
  Expect<Integer>(FModule.MemoryCount).ToBe(1);
  Expect<Integer>(FModule.GlobalCount).ToBe(2);
  Expect<Integer>(FModule.ExportCount).ToBe(6);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(2);

  { (export "add" (func $add)) is declared first; $add is func 0. }
  First := FModule.&Exports[0];
  Expect<string>(First.Name).ToBe('add');
  Expect<Integer>(Ord(First.Kind)).ToBe(Ord(wxkFunc));
  Expect<Integer>(Integer(First.Index)).ToBe(0);

  { (global $counter (mut i32) ...) then (global $limit i32 ...). }
  Expect<Boolean>(FModule.Globals[0].GlobalType.Mut).ToBe(True);
  Expect<Boolean>(FModule.Globals[1].GlobalType.Mut).ToBe(False);

  { (memory $mem 1 2) — both bounds present. }
  Expect<Boolean>(FModule.Memories[0].Limits.HasMax).ToBe(True);
  Expect<Integer>(Integer(FModule.Memories[0].Limits.Min)).ToBe(1);
  Expect<Integer>(Integer(FModule.Memories[0].Limits.Max)).ToBe(2);
end;

procedure TFixtureTests.TestImportsModel;
begin
  DecodeValid('imports.wasm');
  Expect<Integer>(FModule.ImportCount).ToBe(4);

  { Declaration order: func, table, memory, global — all from "env". }
  Expect<Integer>(Ord(FModule.Imports[0].Kind)).ToBe(Ord(wxkFunc));
  Expect<Integer>(Ord(FModule.Imports[1].Kind)).ToBe(Ord(wxkTable));
  Expect<Integer>(Ord(FModule.Imports[2].Kind)).ToBe(Ord(wxkMem));
  Expect<Integer>(Ord(FModule.Imports[3].Kind)).ToBe(Ord(wxkGlobal));
  Expect<string>(FModule.Imports[0].ModuleName).ToBe('env');
  Expect<string>(FModule.Imports[0].Name).ToBe('log');
  Expect<string>(FModule.Imports[3].Name).ToBe('base');

  { The function index space counts the import first: 1 import + 1
    defined function. }
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(1);
  Expect<Integer>(FModule.TotalFunctionCount).ToBe(2);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(1);
  Expect<Integer>(FModule.ExportCount).ToBe(1);
  Expect<string>(FModule.&Exports[0].Name).ToBe('use');
end;

procedure TFixtureTests.TestStartModel;
begin
  DecodeValid('start.wasm');
  Expect<Boolean>(FModule.HasStart).ToBe(True);
  { (start $init) — $init is the first defined function, no imports. }
  Expect<Integer>(Integer(FModule.StartFuncIndex)).ToBe(0);

  Expect<Integer>(FModule.GlobalCount).ToBe(1);
  Expect<Integer>(FModule.ElementCount).ToBe(1);
  Expect<Integer>(Ord(FModule.Elements[0].Mode)).ToBe(Ord(wemActive));
  { (elem (i32.const 0) $init $noop) — the funcidx-list form. }
  Expect<Boolean>(FModule.Elements[0].UsesExprs).ToBe(False);
  Expect<Integer>(Length(FModule.Elements[0].FuncIndices)).ToBe(2);
  Expect<Integer>(FModule.DataSegmentCount).ToBe(1);
  Expect<Integer>(Ord(FModule.DataSegments[0].Mode)).ToBe(Ord(wdmActive));
  { "hello fixture" is 13 bytes, located in the buffer, not copied. }
  Expect<Integer>(Integer(FModule.DataSegments[0].Bytes.Size)).ToBe(13);
  Expect<string>(FModule.&Exports[0].Name).ToBe('g');
end;

procedure TFixtureTests.TestDataCountModel;
begin
  DecodeValid('datacount.wasm');
  Expect<Boolean>(FModule.HasDataCount).ToBe(True);
  { Two data segments — (data $passive ...) then (data $active ...) —
    and the declared count must agree (the walk enforces it, so a decode
    that got here is already consistent; asserting both pins the model). }
  Expect<Integer>(Integer(FModule.DataCount)).ToBe(2);
  Expect<Integer>(FModule.DataSegmentCount).ToBe(2);
  Expect<Integer>(Ord(FModule.DataSegments[0].Mode)).ToBe(Ord(wdmPassive));
  Expect<Integer>(Ord(FModule.DataSegments[1].Mode)).ToBe(Ord(wdmActive));
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(2);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(2);
end;

procedure TFixtureTests.TestMultiMemoryModel;
begin
  DecodeValid('multimemory.wasm');
  Expect<Integer>(FModule.MemoryCount).ToBe(2);
  { (data (memory $b) ...) — bound to memory 1, which forces the
    explicit-memidx encoding (flags = 2). }
  Expect<Integer>(FModule.DataSegmentCount).ToBe(1);
  Expect<Integer>(Ord(FModule.DataSegments[0].Mode)).ToBe(Ord(wdmActive));
  Expect<Integer>(Integer(FModule.DataSegments[0].MemIndex)).ToBe(1);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(2);
  Expect<Integer>(FModule.ExportCount).ToBe(4);
end;

procedure TFixtureTests.TestRefTypesModel;
begin
  DecodeValid('reftypes.wasm');
  { (table $funcs 4 funcref) then (table $exts 2 externref). }
  Expect<Integer>(FModule.TableCount).ToBe(2);
  Expect<string>(FModule.Tables[0].TableType.RefType.Describe)
    .ToBe('funcref');
  Expect<string>(FModule.Tables[1].TableType.RefType.Describe)
    .ToBe('externref');
  Expect<Integer>(FModule.ElementCount).ToBe(1);
  Expect<Integer>(Ord(FModule.Elements[0].Mode))
    .ToBe(Ord(wemDeclarative));
  Expect<Integer>(FModule.CodeEntryCount).ToBe(5);
  Expect<Integer>(FModule.ExportCount).ToBe(4);
end;

procedure TFixtureTests.TestSimdModel;
begin
  DecodeValid('simd.wasm');
  Expect<Boolean>(FModule.TypeCount > 0).ToBe(True);
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(5);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(5);
  Expect<Integer>(FModule.MemoryCount).ToBe(1);
  Expect<Integer>(FModule.ExportCount).ToBe(4);
end;

procedure TFixtureTests.TestTagsModel;
var
  TagExport: TWasmExport;
begin
  DecodeValid('tags.wasm');
  Expect<Integer>(FModule.TagCount).ToBe(1);
  Expect<Integer>(FModule.GlobalCount).ToBe(1);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(2);
  { (export "catcher" ...) then (export "oops" (tag $oops)). }
  Expect<Integer>(FModule.ExportCount).ToBe(2);
  TagExport := FModule.&Exports[1];
  Expect<string>(TagExport.Name).ToBe('oops');
  Expect<Integer>(Ord(TagExport.Kind)).ToBe(Ord(wxkTag));
end;

procedure TFixtureTests.TestCustomSectionsModel;
begin
  DecodeValid('customsections.wasm');
  Expect<Integer>(FModule.CustomSectionCount).ToBe(4);
  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Expect<Integer>(FModule.MemoryCount).ToBe(1);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(1);
  Expect<Integer>(FModule.ExportCount).ToBe(1);
  Expect<string>(FModule.&Exports[0].Name).ToBe('double');
end;

procedure TFixtureTests.TestPaddedLebModel;
begin
  { Same module as exports.wasm apart from the padded size LEB, so the
    MODEL must be identical even though every section body sits one byte
    further into the buffer. }
  DecodeValid('padded-leb-size.wasm');
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(2);
  Expect<Integer>(FModule.GlobalCount).ToBe(2);
  Expect<Integer>(FModule.ExportCount).ToBe(6);
  Expect<string>(FModule.&Exports[0].Name).ToBe('add');
  Expect<Integer>(FModule.CodeEntryCount).ToBe(2);
end;

procedure TFixtureTests.TestMinimalModel;
begin
  DecodeValid('minimal.wasm');
  Expect<Integer>(FModule.SectionCount).ToBe(0);
  Expect<Integer>(FModule.TypeCount).ToBe(0);
  Expect<Integer>(FModule.TotalFunctionCount).ToBe(0);
  Expect<Boolean>(FModule.HasStart).ToBe(False);
  Expect<Boolean>(FModule.HasDataCount).ToBe(False);
end;

procedure TFixtureTests.SetupTests;
begin
  Test('the fixture corpus is present', TestCorpusIsPresent);
  Test('every valid fixture decodes', TestEveryValidFixtureDecodes);
  Test('every malformed fixture is rejected',
    TestEveryMalformedFixtureIsRejected);
  Test('real output puts data count before code', TestDataCountPrecedesCode);
  Test('real output puts tag before global', TestTagPrecedesGlobal);
  Test('section extents stay inside the module',
    TestSectionExtentsStayInsideTheModule);
  Test('exports.wasm model matches its source', TestExportsModel);
  Test('imports.wasm model matches its source', TestImportsModel);
  Test('start.wasm model matches its source', TestStartModel);
  Test('datacount.wasm model matches its source', TestDataCountModel);
  Test('multimemory.wasm model matches its source', TestMultiMemoryModel);
  Test('reftypes.wasm model matches its source', TestRefTypesModel);
  Test('simd.wasm model matches its source', TestSimdModel);
  Test('tags.wasm model matches its source', TestTagsModel);
  Test('customsections.wasm model matches its source',
    TestCustomSectionsModel);
  Test('padded-leb-size.wasm model matches exports.wasm',
    TestPaddedLebModel);
  Test('minimal.wasm model is empty', TestMinimalModel);
end;

begin
  TestRunnerProgram.AddSuite(TFixtureTests.Create('Wasm.Fixtures'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
