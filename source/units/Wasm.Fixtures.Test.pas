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
end;

begin
  TestRunnerProgram.AddSuite(TFixtureTests.Create('Wasm.Fixtures'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
