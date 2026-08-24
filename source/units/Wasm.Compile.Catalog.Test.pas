{ Unit suite for Wasm.Compile.Catalog — released triples, catalog parse,
  checksums, and deterministic target selection including the negative
  catalog-corruption paths. }
program Wasm.Compile.Catalog.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Wasm.Compile.Catalog,
  Wasm.Core;

type
  TCatalogTests = class(TTestSuite)
  private
    FTempDir: string;
    function MakeTempDir: string;
    procedure RemoveTree(const APath: string);
    procedure WriteBytes(const APath: string; const ABytes: TWasmBytes);
    procedure WriteText(const APath, AText: string);
    function SampleShell(const ATag: string): TWasmBytes;
    function MakeEntry(const AId: TWasmTargetId; const AVersion: string;
      const AFileName: string; const ABytes: TWasmBytes): TWasmShellEntry;
    function WriteReleaseCatalog(const ARoot: string): TWasmShellCatalog;
  public
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure SetupTests; override;

    procedure TestReleasedTripleCountAndNames;
    procedure TestUnknownTripleRejected;
    procedure TestHostDefaultIsReleasedOrEmpty;
    procedure TestCompilerCatalogRootIsBesideCompiler;
    procedure TestChecksumEmptyIsOffsetBasis;
    procedure TestChecksumDeterministic;
    procedure TestCatalogRoundTrip;
    procedure TestCatalogCoversRelease;
    procedure TestSelectEveryReleasedTarget;
    procedure TestHostDefaultUsesSameSelectionPath;
    procedure TestEmptyTripleResolvesHost;
    procedure TestUnknownTargetFailsBeforeCatalog;
    procedure TestMissingCatalogIsMissingShell;
    procedure TestMissingTargetIsMissingShell;
    procedure TestDuplicateCatalogEntryRejected;
    procedure TestStaleVersionRejected;
    procedure TestMismatchedArchRejected;
    procedure TestCorruptMagicRejected;
    procedure TestCorruptChecksumRejected;
    procedure TestEscapingFileNameRejected;
    procedure TestLeftoverFilesAreIgnored;
    procedure TestIncompleteReleaseCatalog;
    procedure TestSelectErrorMessages;
  end;

function TCatalogTests.MakeTempDir: string;
var
  Base: string;
  Attempt: Integer;
begin
  Base := IncludeTrailingPathDelimiter(GetTempDir);
  for Attempt := 0 to 999 do
  begin
    Result := Base + 'wasmlight_catalog_' + IntToStr(GetTickCount64) + '_' +
      IntToStr(Attempt);
    if not DirectoryExists(Result) and not FileExists(Result) then
      if CreateDir(Result) then
        Exit;
  end;
  raise EWasmError.Create('could not create a unique temp dir for the test');
end;

procedure TCatalogTests.RemoveTree(const APath: string);
var
  Sr: TSearchRec;
  Full: string;
begin
  if not DirectoryExists(APath) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, Sr) = 0 then
  begin
    try
      repeat
        if (Sr.Name = '.') or (Sr.Name = '..') then
          Continue;
        Full := IncludeTrailingPathDelimiter(APath) + Sr.Name;
        if (Sr.Attr and faDirectory) <> 0 then
          RemoveTree(Full)
        else
          DeleteFile(Full);
      until FindNext(Sr) <> 0;
    finally
      FindClose(Sr);
    end;
  end;
  RemoveDir(APath);
end;

procedure TCatalogTests.WriteBytes(const APath: string; const ABytes: TWasmBytes);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
end;

procedure TCatalogTests.WriteText(const APath, AText: string);
var
  Bytes_: TWasmBytes;
  I: Integer;
begin
  SetLength(Bytes_, Length(AText));
  for I := 1 to Length(AText) do
    Bytes_[I - 1] := Byte(Ord(AText[I]));
  WriteBytes(APath, Bytes_);
end;

function TCatalogTests.SampleShell(const ATag: string): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(ATag));
  for I := 1 to Length(ATag) do
    Result[I - 1] := Byte(Ord(ATag[I]));
end;

function TCatalogTests.MakeEntry(const AId: TWasmTargetId;
  const AVersion: string; const AFileName: string;
  const ABytes: TWasmBytes): TWasmShellEntry;
begin
  Result.Target := AId;
  Result.Triple := TargetTriple(AId);
  Result.Version := AVersion;
  case AId of
    wtiAArch64Linux, wtiAArch64Darwin:
      Result.Arch := wtaAArch64;
    else
      Result.Arch := wtaX64;
  end;
  case AId of
    wtiAArch64Linux, wtiX64Linux:
      begin
        Result.Os := wtoLinux;
        Result.Format := wsfElf;
      end;
    else
      begin
        Result.Os := wtoDarwin;
        Result.Format := wsfMachO;
      end;
  end;
  Result.FileName := AFileName;
  Result.Checksum := ShellChecksumBytes(ABytes);
  Result.ShellPath := '';
end;

function TCatalogTests.WriteReleaseCatalog(const ARoot: string): TWasmShellCatalog;
var
  I: Integer;
  Id: TWasmTargetId;
  Bytes_: TWasmBytes;
  Entries: TWasmShellEntries;
  FileName: string;
begin
  if not DirectoryExists(ARoot) then
    CreateDir(ARoot);
  SetLength(Entries, RELEASED_TARGET_COUNT);
  for I := 0 to RELEASED_TARGET_COUNT - 1 do
  begin
    Id := ReleasedTargetId(I);
    FileName := TargetTriple(Id) + '.shell';
    Bytes_ := SampleShell('shell-' + TargetTriple(Id));
    WriteBytes(IncludeTrailingPathDelimiter(ARoot) + FileName, Bytes_);
    Entries[I] := MakeEntry(Id, PROGRAM_VERSION, FileName, Bytes_);
  end;
  WriteText(IncludeTrailingPathDelimiter(ARoot) + SHELL_CATALOG_FILENAME,
    WriteShellCatalogText(Entries));
  Expect<Integer>(Ord(LoadShellCatalog(ARoot, Result))).ToBe(Ord(slrOk));
end;

procedure TCatalogTests.BeforeEach;
begin
  FTempDir := MakeTempDir;
end;

procedure TCatalogTests.AfterEach;
begin
  RemoveTree(FTempDir);
  FTempDir := '';
end;

procedure TCatalogTests.TestReleasedTripleCountAndNames;
begin
  Expect<Integer>(RELEASED_TARGET_COUNT).ToBe(4);
  Expect<string>(TargetTriple(ReleasedTargetId(0))).ToBe('aarch64-linux');
  Expect<string>(TargetTriple(ReleasedTargetId(1))).ToBe('x86_64-linux');
  Expect<string>(TargetTriple(ReleasedTargetId(2))).ToBe('aarch64-darwin');
  Expect<string>(TargetTriple(ReleasedTargetId(3))).ToBe('x86_64-darwin');
  Expect<string>(TargetTriple(wtiNone)).ToBe('');
end;

procedure TCatalogTests.TestUnknownTripleRejected;
var
  Id: TWasmTargetId;
begin
  Expect<Boolean>(ParseTargetTriple('riscv64-linux', Id)).ToBe(False);
  Expect<Integer>(Ord(Id)).ToBe(Ord(wtiNone));
  Expect<Boolean>(ParseTargetTriple('aarch64-unknown-linux-gnu', Id)).ToBe(False);
  Expect<Boolean>(ParseTargetTriple('x86_64-win64', Id)).ToBe(False);
  Expect<Boolean>(ParseTargetTriple('', Id)).ToBe(False);
end;

procedure TCatalogTests.TestHostDefaultIsReleasedOrEmpty;
var
  Host: string;
  Id: TWasmTargetId;
begin
  Host := HostTargetTriple;
  if Host = '' then
    Expect<Integer>(Ord(HostTargetId)).ToBe(Ord(wtiNone))
  else
  begin
    Expect<Boolean>(ParseTargetTriple(Host, Id)).ToBe(True);
    Expect<string>(TargetTriple(Id)).ToBe(Host);
  end;
end;

procedure TCatalogTests.TestCompilerCatalogRootIsBesideCompiler;
var
  CompilerPath: string;
begin
  CompilerPath := IncludeTrailingPathDelimiter('bindir') + 'wasmlight';
  Expect<string>(CompilerCatalogRoot(CompilerPath)
    ).ToBe(IncludeTrailingPathDelimiter('bindir') + 'shells');
  Expect<string>(CompilerCatalogRoot('wasmlight')).ToBe('shells');
end;

procedure TCatalogTests.TestChecksumEmptyIsOffsetBasis;
begin
  Expect<string>(ChecksumToHex(ShellChecksumBytes(nil))
    ).ToBe('cbf29ce484222325');
end;

procedure TCatalogTests.TestChecksumDeterministic;
var
  A, B: TWasmBytes;
begin
  A := SampleShell('shell-bytes');
  B := SampleShell('shell-bytes');
  Expect<string>(ChecksumToHex(ShellChecksumBytes(A))
    ).ToBe(ChecksumToHex(ShellChecksumBytes(B)));
  B[0] := B[0] xor $FF;
  Expect<Boolean>(ShellChecksumBytes(A) <> ShellChecksumBytes(B)).ToBe(True);
end;

procedure TCatalogTests.TestCatalogRoundTrip;
var
  Entries: TWasmShellEntries;
  Catalog: TWasmShellCatalog;
  Text: string;
begin
  SetLength(Entries, 1);
  Entries[0] := MakeEntry(wtiAArch64Linux, PROGRAM_VERSION, 'aarch64-linux.shell',
    SampleShell('one'));
  Text := WriteShellCatalogText(Entries);
  Expect<Integer>(Ord(ParseShellCatalogText(Text, Catalog))).ToBe(Ord(slrOk));
  Expect<Integer>(Length(Catalog.Entries)).ToBe(1);
  Expect<string>(Catalog.Entries[0].Triple).ToBe('aarch64-linux');
  Expect<string>(Catalog.Entries[0].Version).ToBe(PROGRAM_VERSION);
  Expect<string>(Catalog.Entries[0].FileName).ToBe('aarch64-linux.shell');
  Expect<string>(ChecksumToHex(Catalog.Entries[0].Checksum)
    ).ToBe(ChecksumToHex(Entries[0].Checksum));
end;

procedure TCatalogTests.TestCatalogCoversRelease;
var
  Catalog: TWasmShellCatalog;
begin
  Catalog := WriteReleaseCatalog(FTempDir);
  Expect<Boolean>(CatalogCoversRelease(Catalog)).ToBe(True);
end;

procedure TCatalogTests.TestSelectEveryReleasedTarget;
var
  Catalog: TWasmShellCatalog;
  I: Integer;
  Triple: string;
  Entry: TWasmShellEntry;
  Res: TWasmShellSelectResult;
begin
  Catalog := WriteReleaseCatalog(FTempDir);
  for I := 0 to RELEASED_TARGET_COUNT - 1 do
  begin
    Triple := TargetTriple(ReleasedTargetId(I));
    Res := SelectShell(Catalog, Triple, Entry);
    Expect<Integer>(Ord(Res)).ToBe(Ord(ssrOk));
    Expect<string>(Entry.Triple).ToBe(Triple);
    Expect<string>(ExtractFileName(Entry.ShellPath)).ToBe(Triple + '.shell');
    Res := ResolveShell(FTempDir, Triple, Entry);
    Expect<Integer>(Ord(Res)).ToBe(Ord(ssrOk));
    Expect<string>(Entry.Triple).ToBe(Triple);
  end;
end;

procedure TCatalogTests.TestHostDefaultUsesSameSelectionPath;
var
  Catalog: TWasmShellCatalog;
  Host: string;
  ViaHost, ViaExplicit: TWasmShellEntry;
  HostRes, ExplicitRes: TWasmShellSelectResult;
begin
  Catalog := WriteReleaseCatalog(FTempDir);
  Host := HostTargetTriple;
  if Host = '' then
  begin
    HostRes := ResolveShell(FTempDir, '', ViaHost);
    Expect<Integer>(Ord(HostRes)).ToBe(Ord(ssrUnknownTarget));
    Exit;
  end;
  HostRes := ResolveShell(FTempDir, '', ViaHost);
  ExplicitRes := ResolveShell(FTempDir, Host, ViaExplicit);
  Expect<Integer>(Ord(HostRes)).ToBe(Ord(ssrOk));
  Expect<Integer>(Ord(ExplicitRes)).ToBe(Ord(ssrOk));
  Expect<string>(ViaHost.ShellPath).ToBe(ViaExplicit.ShellPath);
  Expect<string>(ViaHost.Triple).ToBe(Host);
  Expect<Integer>(Ord(SelectShell(Catalog, Host, ViaExplicit))).ToBe(Ord(ssrOk));
end;

procedure TCatalogTests.TestEmptyTripleResolvesHost;
var
  Entry: TWasmShellEntry;
  Res: TWasmShellSelectResult;
begin
  WriteReleaseCatalog(FTempDir);
  Res := ResolveShell(FTempDir, '', Entry);
  if HostTargetTriple = '' then
    Expect<Integer>(Ord(Res)).ToBe(Ord(ssrUnknownTarget))
  else
  begin
    Expect<Integer>(Ord(Res)).ToBe(Ord(ssrOk));
    Expect<string>(Entry.Triple).ToBe(HostTargetTriple);
  end;
end;

procedure TCatalogTests.TestUnknownTargetFailsBeforeCatalog;
var
  Entry: TWasmShellEntry;
  Res: TWasmShellSelectResult;
begin
  Res := ResolveShell('/definitely/missing/wasmlight-shells', 'riscv64-linux',
    Entry);
  Expect<Integer>(Ord(Res)).ToBe(Ord(ssrUnknownTarget));
  Expect<string>(FormatSelectError(Res, 'riscv64-linux')
    ).ToBe('target: unknown target "riscv64-linux"');
end;

procedure TCatalogTests.TestMissingCatalogIsMissingShell;
var
  Entry: TWasmShellEntry;
  Res: TWasmShellSelectResult;
begin
  Res := ResolveShell(FTempDir, 'aarch64-linux', Entry);
  Expect<Integer>(Ord(Res)).ToBe(Ord(ssrMissingShell));
end;

procedure TCatalogTests.TestMissingTargetIsMissingShell;
var
  Entries: TWasmShellEntries;
  Bytes_: TWasmBytes;
  Entry: TWasmShellEntry;
  Res: TWasmShellSelectResult;
begin
  Bytes_ := SampleShell('only-linux');
  WriteBytes(IncludeTrailingPathDelimiter(FTempDir) + 'aarch64-linux.shell',
    Bytes_);
  SetLength(Entries, 1);
  Entries[0] := MakeEntry(wtiAArch64Linux, PROGRAM_VERSION, 'aarch64-linux.shell',
    Bytes_);
  WriteText(IncludeTrailingPathDelimiter(FTempDir) + SHELL_CATALOG_FILENAME,
    WriteShellCatalogText(Entries));
  Res := ResolveShell(FTempDir, 'x86_64-linux', Entry);
  Expect<Integer>(Ord(Res)).ToBe(Ord(ssrMissingShell));
end;

procedure TCatalogTests.TestDuplicateCatalogEntryRejected;
var
  Entries: TWasmShellEntries;
  Bytes_: TWasmBytes;
  Catalog: TWasmShellCatalog;
  Entry: TWasmShellEntry;
begin
  Bytes_ := SampleShell('dup');
  WriteBytes(IncludeTrailingPathDelimiter(FTempDir) + 'a.shell', Bytes_);
  WriteBytes(IncludeTrailingPathDelimiter(FTempDir) + 'b.shell', Bytes_);
  SetLength(Entries, 2);
  Entries[0] := MakeEntry(wtiAArch64Linux, PROGRAM_VERSION, 'a.shell', Bytes_);
  Entries[1] := MakeEntry(wtiAArch64Linux, PROGRAM_VERSION, 'b.shell', Bytes_);
  WriteText(IncludeTrailingPathDelimiter(FTempDir) + SHELL_CATALOG_FILENAME,
    WriteShellCatalogText(Entries));
  Expect<Integer>(Ord(ParseShellCatalogText(WriteShellCatalogText(Entries),
    Catalog))).ToBe(Ord(slrDuplicateTarget));
  Expect<Integer>(Ord(ResolveShell(FTempDir, 'aarch64-linux', Entry))
    ).ToBe(Ord(ssrDuplicateShell));
end;

procedure TCatalogTests.TestStaleVersionRejected;
var
  Entries: TWasmShellEntries;
  Bytes_: TWasmBytes;
  Entry: TWasmShellEntry;
begin
  Bytes_ := SampleShell('stale');
  WriteBytes(IncludeTrailingPathDelimiter(FTempDir) + 'aarch64-linux.shell',
    Bytes_);
  SetLength(Entries, 1);
  Entries[0] := MakeEntry(wtiAArch64Linux, '0.0.0', 'aarch64-linux.shell', Bytes_);
  WriteText(IncludeTrailingPathDelimiter(FTempDir) + SHELL_CATALOG_FILENAME,
    WriteShellCatalogText(Entries));
  Expect<Integer>(Ord(ResolveShell(FTempDir, 'aarch64-linux', Entry))
    ).ToBe(Ord(ssrStaleShell));
end;

procedure TCatalogTests.TestMismatchedArchRejected;
var
  Text: string;
  Catalog: TWasmShellCatalog;
begin
  Text := SHELL_CATALOG_MAGIC + ' 1' + #10 +
    'target aarch64-linux' + #10 +
    'version ' + PROGRAM_VERSION + #10 +
    'arch x86_64' + #10 +
    'os linux' + #10 +
    'format elf' + #10 +
    'file aarch64-linux.shell' + #10 +
    'checksum cbf29ce484222325' + #10;
  Expect<Integer>(Ord(ParseShellCatalogText(Text, Catalog))
    ).ToBe(Ord(slrCorruptCatalog));
end;

procedure TCatalogTests.TestCorruptMagicRejected;
var
  Catalog: TWasmShellCatalog;
  Entry: TWasmShellEntry;
begin
  WriteText(IncludeTrailingPathDelimiter(FTempDir) + SHELL_CATALOG_FILENAME,
    'NOT-A-CATALOG 1' + #10);
  Expect<Integer>(Ord(ParseShellCatalogText('NOT-A-CATALOG 1' + #10, Catalog))
    ).ToBe(Ord(slrCorruptCatalog));
  Expect<Integer>(Ord(ResolveShell(FTempDir, 'aarch64-linux', Entry))
    ).ToBe(Ord(ssrCorruptCatalog));
end;

procedure TCatalogTests.TestCorruptChecksumRejected;
var
  Entries: TWasmShellEntries;
  Bytes_: TWasmBytes;
  Entry: TWasmShellEntry;
begin
  Bytes_ := SampleShell('payload');
  WriteBytes(IncludeTrailingPathDelimiter(FTempDir) + 'aarch64-linux.shell',
    Bytes_);
  SetLength(Entries, 1);
  Entries[0] := MakeEntry(wtiAArch64Linux, PROGRAM_VERSION, 'aarch64-linux.shell',
    Bytes_);
  Entries[0].Checksum := Entries[0].Checksum xor UInt64(1);
  WriteText(IncludeTrailingPathDelimiter(FTempDir) + SHELL_CATALOG_FILENAME,
    WriteShellCatalogText(Entries));
  Expect<Integer>(Ord(ResolveShell(FTempDir, 'aarch64-linux', Entry))
    ).ToBe(Ord(ssrCorruptShell));
end;

procedure TCatalogTests.TestEscapingFileNameRejected;
var
  Text: string;
  Catalog: TWasmShellCatalog;
begin
  Text := SHELL_CATALOG_MAGIC + ' 1' + #10 +
    'target aarch64-linux' + #10 +
    'version ' + PROGRAM_VERSION + #10 +
    'arch aarch64' + #10 +
    'os linux' + #10 +
    'format elf' + #10 +
    'file ../escape.shell' + #10 +
    'checksum cbf29ce484222325' + #10;
  Expect<Integer>(Ord(ParseShellCatalogText(Text, Catalog))
    ).ToBe(Ord(slrCorruptCatalog));
  Text := SHELL_CATALOG_MAGIC + ' 1' + #10 +
    'target aarch64-linux' + #10 +
    'version ' + PROGRAM_VERSION + #10 +
    'arch aarch64' + #10 +
    'os linux' + #10 +
    'format elf' + #10 +
    'file /absolute.shell' + #10 +
    'checksum cbf29ce484222325' + #10;
  Expect<Integer>(Ord(ParseShellCatalogText(Text, Catalog))
    ).ToBe(Ord(slrCorruptCatalog));
end;

procedure TCatalogTests.TestLeftoverFilesAreIgnored;
var
  Catalog: TWasmShellCatalog;
  Entry: TWasmShellEntry;
begin
  Catalog := WriteReleaseCatalog(FTempDir);
  WriteBytes(IncludeTrailingPathDelimiter(FTempDir) + 'stray.shell',
    SampleShell('stray'));
  Expect<Boolean>(CatalogCoversRelease(Catalog)).ToBe(True);
  Expect<Integer>(Ord(ResolveShell(FTempDir, 'aarch64-linux', Entry))
    ).ToBe(Ord(ssrOk));
end;

procedure TCatalogTests.TestIncompleteReleaseCatalog;
var
  Entries: TWasmShellEntries;
  Bytes_: TWasmBytes;
  Catalog: TWasmShellCatalog;
begin
  Bytes_ := SampleShell('partial');
  SetLength(Entries, 1);
  Entries[0] := MakeEntry(wtiAArch64Linux, PROGRAM_VERSION, 'aarch64-linux.shell',
    Bytes_);
  Expect<Integer>(Ord(ParseShellCatalogText(WriteShellCatalogText(Entries),
    Catalog))).ToBe(Ord(slrOk));
  Expect<Boolean>(CatalogCoversRelease(Catalog)).ToBe(False);
end;

procedure TCatalogTests.TestSelectErrorMessages;
begin
  Expect<string>(FormatSelectError(ssrMissingShell, 'x86_64-darwin')
    ).ToBe('target: no runtime shell for "x86_64-darwin"');
  Expect<string>(FormatSelectError(ssrStaleShell, 'aarch64-linux')
    ).ToBe('target: stale runtime shell for "aarch64-linux"');
  Expect<string>(FormatSelectError(ssrCorruptCatalog, 'aarch64-linux')
    ).ToBe('target: corrupt shell catalog');
end;

procedure TCatalogTests.SetupTests;
begin
  Test('released triples are the four 64-bit Unix targets',
    TestReleasedTripleCountAndNames);
  Test('an unknown triple is not a released target', TestUnknownTripleRejected);
  Test('the host default is a released triple or empty',
    TestHostDefaultIsReleasedOrEmpty);
  Test('the default catalog root sits beside the compiler',
    TestCompilerCatalogRootIsBesideCompiler);
  Test('FNV-1a-64 of empty input is the offset basis',
    TestChecksumEmptyIsOffsetBasis);
  Test('shell checksums are deterministic and avalanche',
    TestChecksumDeterministic);
  Test('a catalog entry round-trips through write/parse', TestCatalogRoundTrip);
  Test('a complete catalog covers the current release', TestCatalogCoversRelease);
  Test('every released target selects exactly one shell',
    TestSelectEveryReleasedTarget);
  Test('host-native selection uses the same path as an explicit triple',
    TestHostDefaultUsesSameSelectionPath);
  Test('an empty triple resolves through the host default',
    TestEmptyTripleResolvesHost);
  Test('an unknown target fails before catalog I/O',
    TestUnknownTargetFailsBeforeCatalog);
  Test('a missing catalog is a missing shell', TestMissingCatalogIsMissingShell);
  Test('a catalog without the requested target is missing',
    TestMissingTargetIsMissingShell);
  Test('duplicate catalog entries fail before selection',
    TestDuplicateCatalogEntryRejected);
  Test('a stale compiler version is rejected', TestStaleVersionRejected);
  Test('arch/os/format that disagree with the triple are corrupt',
    TestMismatchedArchRejected);
  Test('a bad catalog magic is corrupt', TestCorruptMagicRejected);
  Test('a checksum mismatch is a corrupt shell', TestCorruptChecksumRejected);
  Test('a catalog file that escapes the root is rejected',
    TestEscapingFileNameRejected);
  Test('stray files beside the catalog are not selected',
    TestLeftoverFilesAreIgnored);
  Test('an incomplete catalog does not cover the release',
    TestIncompleteReleaseCatalog);
  Test('selection errors use a target: prefix', TestSelectErrorMessages);
end;

begin
  TestRunnerProgram.AddSuite(TCatalogTests.Create('Wasm.Compile.Catalog'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
