{ Unit suite for Wasm.Distro — the release-archive contract.

  These cases pin the names, MANIFEST rules, GNU checksum syntax, and
  ELF/Mach-O structural recognition the packer and CI verifier share.
  Archive *bytes* are assembled next to the assertion so a bad catalog
  or a swapped shell image is readable in the test. }
program Wasm.Distro.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Wasm.Distro;

type
  TDistroTests = class(TTestSuite)
  private
    function TempRoot: string;
    procedure WriteText(const APath, AText: string);
    function BuildValidTree(const ARoot, AVersion, AHost: string;
      ACatalog: TWasmDistroCatalog): TWasmDistroManifest;
  public
    procedure SetupTests; override;

    procedure TestHostLookup;
    procedure TestArchiveNames;
    procedure TestManifestRoundTrip;
    procedure TestRejectUnknownHost;
    procedure TestRejectIncompleteCatalog;
    procedure TestRejectUnknownShell;
    procedure TestRejectDuplicateShell;
    procedure TestElfAndMachOMagic;
    procedure TestSwappedShellImage;
    procedure TestValidateTree;
    procedure TestForbiddenAppleDouble;
    procedure TestChecksumsCoverFourArchives;
    procedure TestChecksumsRejectPath;
    procedure TestCompileHelpDetection;
  end;

function TDistroTests.TempRoot: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight-distro-' + IntToHex(Random(MaxInt), 8);
  ForceDirectories(Result);
end;

procedure TDistroTests.WriteText(const APath, AText: string);
var
  Lines: TStringList;
begin
  ForceDirectories(ExtractFilePath(APath));
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

function TDistroTests.BuildValidTree(const ARoot, AVersion, AHost: string;
  ACatalog: TWasmDistroCatalog): TWasmDistroManifest;
var
  Host: TWasmDistroHost;
  I: Integer;
begin
  Expect<Boolean>(DistroFindHost(AHost, Host)).ToBe(True);
  DistroSynthesizeCatalog(ARoot);
  WriteText(DistroJoin(ARoot, DISTRO_COMPILER_NAME), 'compiler-placeholder');
  Result.Version := AVersion;
  Result.HostTriple := Host.Triple;
  Result.Display := Host.Display;
  Result.Catalog := ACatalog;
  SetLength(Result.Shells, DISTRO_SHELL_COUNT);
  SetLength(Result.Files, 1 + (DISTRO_SHELL_COUNT * 2));
  Result.Files[0] := DISTRO_COMPILER_NAME;
  for I := 0 to DISTRO_SHELL_COUNT - 1 do
  begin
    Result.Shells[I] := DistroShell(I).Triple;
    Result.Files[1 + (I * 2)] := DistroShellRelPath(DistroShell(I).Triple);
    Result.Files[2 + (I * 2)] := DistroMetaRelPath(DistroShell(I).Triple);
  end;
  SetLength(Result.Hashes, 0);
  WriteText(DistroJoin(ARoot, DISTRO_MANIFEST_NAME), DistroFormatManifest(Result));
end;

procedure TDistroTests.TestHostLookup;
var
  Host: TWasmDistroHost;
  I: Integer;
begin
  for I := 0 to DISTRO_HOST_COUNT - 1 do
  begin
    Expect<Boolean>(DistroFindHost(DistroHost(I).Triple, Host)).ToBe(True);
    Expect<string>(Host.Display).ToBe(DistroHost(I).Display);
    Expect<Boolean>(DistroFindHost(DistroHost(I).Display, Host)).ToBe(True);
    Expect<string>(Host.Triple).ToBe(DistroHost(I).Triple);
  end;
  Expect<Boolean>(DistroFindHost('x86_64-win64', Host)).ToBe(False);
end;

procedure TDistroTests.TestArchiveNames;
var
  Names: TStringArray;
begin
  Expect<string>(DistroArchiveFileName('0.2.0', 'macos-arm64')).ToBe(
    'wasmlight-0.2.0-macos-arm64.tar.gz');
  Expect<string>(DistroChecksumsFileName('0.2.0')).ToBe(
    'wasmlight-0.2.0-checksums.txt');
  Names := DistroExpectedArchiveNames('0.2.0');
  Expect<Integer>(Length(Names)).ToBe(4);
  Expect<string>(Names[0]).ToBe('wasmlight-0.2.0-linux-arm64.tar.gz');
  Expect<string>(Names[1]).ToBe('wasmlight-0.2.0-linux-x64.tar.gz');
  Expect<string>(Names[2]).ToBe('wasmlight-0.2.0-macos-arm64.tar.gz');
  Expect<string>(Names[3]).ToBe('wasmlight-0.2.0-macos-x64.tar.gz');
end;

procedure TDistroTests.TestManifestRoundTrip;
var
  Manifest, Parsed: TWasmDistroManifest;
  Status: TWasmDistroResult;
  I: Integer;
begin
  Manifest.Version := '0.2.0';
  Manifest.HostTriple := 'aarch64-darwin';
  Manifest.Display := 'macos-arm64';
  Manifest.Catalog := wdcFixture;
  SetLength(Manifest.Shells, DISTRO_SHELL_COUNT);
  for I := 0 to DISTRO_SHELL_COUNT - 1 do
    Manifest.Shells[I] := DistroShell(I).Triple;
  SetLength(Manifest.Files, 1);
  Manifest.Files[0] := DISTRO_COMPILER_NAME;
  SetLength(Manifest.Hashes, 1);
  Manifest.Hashes[0].RelPath := DISTRO_COMPILER_NAME;
  Manifest.Hashes[0].Digest := StringOfChar('a', 64);
  Status := DistroParseManifest(DistroFormatManifest(Manifest), Parsed);
  Expect<Boolean>(Status.IsOk).ToBe(True);
  Expect<string>(Parsed.Version).ToBe('0.2.0');
  Expect<string>(Parsed.HostTriple).ToBe('aarch64-darwin');
  Expect<string>(Parsed.Display).ToBe('macos-arm64');
  Expect<Integer>(Ord(Parsed.Catalog)).ToBe(Ord(wdcFixture));
  Expect<Integer>(Length(Parsed.Shells)).ToBe(4);
  Expect<string>(Parsed.Hashes[0].Digest).ToBe(StringOfChar('a', 64));
end;

procedure TDistroTests.TestRejectUnknownHost;
var
  Manifest: TWasmDistroManifest;
  Status: TWasmDistroResult;
begin
  Status := DistroParseManifest(
    'version 0.2.0' + sLineBreak +
    'host x86_64-win64' + sLineBreak +
    'display windows-x64' + sLineBreak +
    'catalog live', Manifest);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsUnknownHost));
end;

procedure TDistroTests.TestRejectIncompleteCatalog;
var
  Manifest: TWasmDistroManifest;
  Status: TWasmDistroResult;
begin
  Status := DistroParseManifest(
    'version 0.2.0' + sLineBreak +
    'host x86_64-linux' + sLineBreak +
    'display linux-x64' + sLineBreak +
    'catalog live' + sLineBreak +
    'shell x86_64-linux', Manifest);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsIncompleteCatalog));
end;

procedure TDistroTests.TestRejectUnknownShell;
var
  Manifest: TWasmDistroManifest;
  Status: TWasmDistroResult;
  Text: string;
  I: Integer;
begin
  Text := 'version 0.2.0' + sLineBreak +
    'host x86_64-linux' + sLineBreak +
    'display linux-x64' + sLineBreak +
    'catalog live';
  for I := 0 to DISTRO_SHELL_COUNT - 1 do
    Text := Text + sLineBreak + 'shell ' + DistroShell(I).Triple;
  Text := Text + sLineBreak + 'shell i386-win32';
  Status := DistroParseManifest(Text, Manifest);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsUnknownShell));
end;

procedure TDistroTests.TestRejectDuplicateShell;
var
  Manifest: TWasmDistroManifest;
  Status: TWasmDistroResult;
begin
  Status := DistroParseManifest(
    'version 0.2.0' + sLineBreak +
    'host aarch64-linux' + sLineBreak +
    'display linux-arm64' + sLineBreak +
    'catalog live' + sLineBreak +
    'shell aarch64-linux' + sLineBreak +
    'shell x86_64-linux' + sLineBreak +
    'shell aarch64-darwin' + sLineBreak +
    'shell x86_64-darwin' + sLineBreak +
    'shell aarch64-linux', Manifest);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsDuplicateShell));
end;

procedure TDistroTests.TestElfAndMachOMagic;
var
  Root: string;
  Bytes: TBytes;
  Stream: TFileStream;
  Machine: LongWord;
begin
  Root := TempRoot;
  DistroSynthesizeCatalog(Root);
  Stream := TFileStream.Create(DistroJoin(Root, DistroShellRelPath('x86_64-linux')),
    fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Expect<Integer>(Ord(DistroClassifyImage(Bytes, Machine))).ToBe(Ord(wdiElf64));
  Expect<Boolean>(DistroImageMatchesShell(Bytes, 'x86_64-linux')).ToBe(True);
  Expect<Boolean>(DistroImageMatchesShell(Bytes, 'aarch64-linux')).ToBe(False);

  Stream := TFileStream.Create(DistroJoin(Root, DistroShellRelPath('aarch64-darwin')),
    fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Expect<Integer>(Ord(DistroClassifyImage(Bytes, Machine))).ToBe(Ord(wdiMachO64));
  Expect<Boolean>(DistroImageMatchesShell(Bytes, 'aarch64-darwin')).ToBe(True);
  Expect<Boolean>(DistroImageMatchesShell(Bytes, 'x86_64-darwin')).ToBe(False);
end;

procedure TDistroTests.TestSwappedShellImage;
var
  Root: string;
  Status: TWasmDistroResult;
begin
  Root := TempRoot;
  BuildValidTree(Root, '0.2.0', 'linux-x64', wdcFixture);
  { Put the AArch64 ELF image where the x86-64 Linux shell belongs. }
  DistroWriteStructuralShell(DistroJoin(Root, DistroShellRelPath('x86_64-linux')),
    'aarch64-linux');
  Status := DistroValidateTree(Root, '0.2.0');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadShellImage));
end;

procedure TDistroTests.TestValidateTree;
var
  Root: string;
  Status: TWasmDistroResult;
begin
  Root := TempRoot;
  BuildValidTree(Root, '0.2.0', 'macos-arm64', wdcFixture);
  Status := DistroValidateTree(Root, '0.2.0');
  Expect<Boolean>(Status.IsOk).ToBe(True);
  Status := DistroValidateTree(Root, '0.1.0');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsVersionMismatch));
end;

procedure TDistroTests.TestForbiddenAppleDouble;
var
  Root: string;
  Status: TWasmDistroResult;
begin
  Root := TempRoot;
  BuildValidTree(Root, '0.2.0', 'linux-arm64', wdcFixture);
  WriteText(DistroJoin(Root, '._wasmlight'), 'appledouble');
  Status := DistroValidateTree(Root);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsForbiddenName));
end;

procedure TDistroTests.TestChecksumsCoverFourArchives;
var
  Rows, Parsed: TWasmDistroChecksums;
  Status: TWasmDistroResult;
  Names: TStringArray;
  I: Integer;
begin
  Names := DistroExpectedArchiveNames('0.2.0');
  SetLength(Rows, Length(Names));
  for I := 0 to High(Names) do
  begin
    Rows[I].Digest := StringOfChar(Chr(Ord('0') + (I mod 10)), 64);
    Rows[I].FileName := Names[I];
  end;
  Status := DistroParseChecksums(DistroFormatChecksums(Rows), Parsed);
  Expect<Boolean>(Status.IsOk).ToBe(True);
  Status := DistroChecksumsCoverArchives('0.2.0', Parsed);
  Expect<Boolean>(Status.IsOk).ToBe(True);
end;

procedure TDistroTests.TestChecksumsRejectPath;
var
  Rows: TWasmDistroChecksums;
  Status: TWasmDistroResult;
begin
  Status := DistroParseChecksums(
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  dist/wasmlight-0.2.0-linux-x64.tar.gz',
    Rows);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsChecksumMalformed));
end;

procedure TDistroTests.TestCompileHelpDetection;
begin
  Expect<Boolean>(DistroHelpListsCompile(
    'Commands:' + sLineBreak +
    '  inspect   Decode a module' + sLineBreak +
    '  compile   Emit a native executable' + sLineBreak)).ToBe(True);
  Expect<Boolean>(DistroHelpListsCompile(
    '  aot        Ahead-of-time compile a module' + sLineBreak)).ToBe(False);
  Expect<Boolean>(DistroUnknownCompileCommand(
    'wasmlight: unknown command: compile')).ToBe(True);
end;

procedure TDistroTests.SetupTests;
begin
  Test('four Unix hosts resolve by triple and display name', TestHostLookup);
  Test('archive and checksum names follow the lwpt pattern', TestArchiveNames);
  Test('a valid MANIFEST round-trips', TestManifestRoundTrip);
  Test('a Win64 host is rejected in the 0.2.0 catalog', TestRejectUnknownHost);
  Test('a partial shell list is incomplete', TestRejectIncompleteCatalog);
  Test('an unknown shell triple is rejected', TestRejectUnknownShell);
  Test('a duplicated shell triple is rejected', TestRejectDuplicateShell);
  Test('synthesized shells carry the target ELF or Mach-O magic', TestElfAndMachOMagic);
  Test('a swapped shell image fails structural validation', TestSwappedShellImage);
  Test('a complete tree validates and a version mismatch does not', TestValidateTree);
  Test('AppleDouble names are forbidden in an archive tree', TestForbiddenAppleDouble);
  Test('checksums.txt must list every host archive basename', TestChecksumsCoverFourArchives);
  Test('checksum names may not contain a path', TestChecksumsRejectPath);
  Test('compile is detected from the command list, not the aot blurb',
    TestCompileHelpDetection);
end;

begin
  Randomize;
  TestRunnerProgram.AddSuite(TDistroTests.Create('Wasm.Distro'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
