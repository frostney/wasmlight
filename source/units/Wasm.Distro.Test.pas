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
  Wasm.Compile.Catalog,
  Wasm.Core,
  Wasm.Distro,
  Wasm.MachO,
  Wasm.Native.Payload,
  Wasm.Package.Elf;

type
  TDistroTests = class(TTestSuite)
  private
    function TempRoot: string;
    procedure WriteText(const APath, AText: string);
    function BuildValidTree(const ARoot, AVersion, AHost: string;
      ACatalog: TWasmDistroCatalog): TWasmDistroManifest;
    function ProbePayload(const ATriple: string;
      const AShell: TBytes): TBytes;
    function UnsignedMachOTemplate(const ATarget: TWasmMachOTarget): TBytes;
  public
    procedure SetupTests; override;

    procedure TestHostLookup;
    procedure TestHostShellsShareTheHostArchitecture;
    procedure TestArchiveNames;
    procedure TestManifestRoundTrip;
    procedure TestRejectUnknownHost;
    procedure TestRejectIncompleteCatalog;
    procedure TestRejectUnknownShell;
    procedure TestRejectDuplicateShell;
    procedure TestRejectForeignArchitectureShell;
    procedure TestRejectAllToAllCatalogTree;
    procedure TestElfAndMachOMagic;
    procedure TestSwappedShellImage;
    procedure TestValidateTree;
    procedure TestCompilerCatalogIsLoadable;
    procedure TestArchivePathsStayContained;
    procedure TestForbiddenAppleDouble;
    procedure TestChecksumsCoverFourArchives;
    procedure TestChecksumsRejectPath;
    procedure TestCompileHelpDetection;
    procedure TestCompileEmissionNotShipped;
    procedure TestElfEmissionBindsItsShell;
    procedure TestMachOEmissionBindsItsShell;
    procedure TestUnsignedMachOEmission;
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
  Triples: TStringArray;
  I: Integer;
begin
  Expect<Boolean>(DistroFindHost(AHost, Host)).ToBe(True);
  Expect<Boolean>(DistroSynthesizeCatalog(ARoot, Host).IsOk).ToBe(True);
  Triples := DistroHostShells(Host);
  DistroWriteCatalog(ARoot, AVersion, Triples);
  WriteText(DistroJoin(ARoot, DISTRO_COMPILER_NAME), 'compiler-placeholder');
  Result.Version := AVersion;
  Result.HostTriple := Host.Triple;
  Result.Display := Host.Display;
  Result.Catalog := ACatalog;
  SetLength(Result.Shells, Length(Triples));
  SetLength(Result.Files, 1 + (Length(Triples) * 2));
  Result.Files[0] := DISTRO_COMPILER_NAME;
  for I := 0 to High(Triples) do
  begin
    Result.Shells[I] := Triples[I];
    Result.Files[1 + (I * 2)] := DistroShellRelPath(Triples[I]);
    Result.Files[2 + (I * 2)] := DistroMetaRelPath(Triples[I]);
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

procedure TDistroTests.TestHostShellsShareTheHostArchitecture;
var
  Host: TWasmDistroHost;
  Shells: TStringArray;
begin
  Expect<Boolean>(DistroFindHost('x86_64-linux', Host)).ToBe(True);
  Shells := DistroHostShells(Host);
  Expect<Integer>(Length(Shells)).ToBe(DISTRO_HOST_SHELL_COUNT);
  Expect<string>(Shells[0]).ToBe('x86_64-linux');
  Expect<string>(Shells[1]).ToBe('x86_64-darwin');
  Expect<Boolean>(DistroFindHost('macos-arm64', Host)).ToBe(True);
  Shells := DistroHostShells(Host);
  Expect<Integer>(Length(Shells)).ToBe(DISTRO_HOST_SHELL_COUNT);
  Expect<string>(Shells[0]).ToBe('aarch64-linux');
  Expect<string>(Shells[1]).ToBe('aarch64-darwin');
  { Cross-architecture emission is not in the 0.2.0 archive contract. }
  Expect<Boolean>(DistroHostCarriesShell(Host, 'x86_64-darwin')).ToBe(False);
  Expect<Boolean>(DistroHostCarriesShell(Host, 'i386-win32')).ToBe(False);
end;

function TDistroTests.ProbePayload(const ATriple: string;
  const AShell: TBytes): TBytes;
var
  Params: TWasmNativePayloadWriteParams;
  Funcs: TWasmNativeCodeRecords;
begin
  Params.IrFormatVer := 1;
  if Copy(ATriple, 1, 7) = 'aarch64' then
    Params.TargetArch := WNEP_ARCH_AARCH64
  else
    Params.TargetArch := WNEP_ARCH_X64;
  if Pos('linux', ATriple) > 0 then
    Params.TargetOs := WNEP_OS_LINUX
  else
    Params.TargetOs := WNEP_OS_DARWIN;
  Params.Flags := 0;
  Params.AbiFingerprint := 1;
  Params.ModuleBytes := TWasmBytes.Create($00, $61, $73, $6D, $01, $00, $00, $00);
  Params.ModuleHash := WnepHash128Bytes(Params.ModuleBytes);
  Params.ShellHash := WnepHash128Bytes(AShell);
  SetLength(Funcs, 1);
  Funcs[0].FuncIrIndex := 0;
  Funcs[0].RegisterCount := 1;
  Funcs[0].EntryOffset := 0;
  Funcs[0].Code := TWasmBytes.Create($C3);
  Params.Funcs := Funcs;
  Params.ConnectorPlan := nil;
  Params.CapabilitySet := nil;
  Result := WriteNativePayload(Params);
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
begin
  Manifest.Version := '0.2.0';
  Manifest.HostTriple := 'aarch64-darwin';
  Manifest.Display := 'macos-arm64';
  Manifest.Catalog := wdcFixture;
  SetLength(Manifest.Shells, 2);
  Manifest.Shells[0] := 'aarch64-linux';
  Manifest.Shells[1] := 'aarch64-darwin';
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
  Expect<Integer>(Length(Parsed.Shells)).ToBe(2);
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
begin
  Status := DistroParseManifest(
    'version 0.2.0' + sLineBreak +
    'host x86_64-linux' + sLineBreak +
    'display linux-x64' + sLineBreak +
    'catalog live' + sLineBreak +
    'shell x86_64-linux' + sLineBreak +
    'shell x86_64-darwin' + sLineBreak +
    'shell i386-win32', Manifest);
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
    'shell aarch64-darwin' + sLineBreak +
    'shell aarch64-linux', Manifest);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsDuplicateShell));
end;

procedure TDistroTests.TestRejectForeignArchitectureShell;
var
  Manifest: TWasmDistroManifest;
  Status: TWasmDistroResult;
begin
  { An x86-64 compiler cannot emit AArch64 in 0.2.0, so an archive that
    lists an AArch64 shell would promise a target its compiler rejects. }
  Status := DistroParseManifest(
    'version 0.2.0' + sLineBreak +
    'host x86_64-linux' + sLineBreak +
    'display linux-x64' + sLineBreak +
    'catalog live' + sLineBreak +
    'shell x86_64-linux' + sLineBreak +
    'shell x86_64-darwin' + sLineBreak +
    'shell aarch64-linux', Manifest);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsForeignShell));
end;

procedure TDistroTests.TestRejectAllToAllCatalogTree;
var
  Root: string;
  I: Integer;
  Triples: TStringArray;
  Status: TWasmDistroResult;
begin
  Root := TempRoot;
  BuildValidTree(Root, '0.2.0', 'linux-x64', wdcFixture);
  { Stage every released shell and index all four: the MANIFEST still names
    only the host pair, but the catalog now offers foreign targets. }
  SetLength(Triples, DISTRO_SHELL_COUNT);
  for I := 0 to DISTRO_SHELL_COUNT - 1 do
  begin
    Triples[I] := DistroShell(I).Triple;
    DistroWriteStructuralShell(DistroJoin(Root, DistroShellRelPath(Triples[I])),
      Triples[I]);
  end;
  DistroWriteCatalog(Root, '0.2.0', Triples);
  Status := DistroValidateTree(Root, '0.2.0');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsForeignShell));
end;

procedure TDistroTests.TestElfAndMachOMagic;
var
  Root: string;
  Bytes: TBytes;
  Stream: TFileStream;
  Machine: LongWord;
  I: Integer;
  Shell: TWasmDistroShell;
  Wrong: string;
begin
  Root := TempRoot;
  for I := 0 to DISTRO_SHELL_COUNT - 1 do
  begin
    Shell := DistroShell(I);
    DistroWriteStructuralShell(DistroJoin(Root, DistroShellRelPath(Shell.Triple)),
      Shell.Triple);
    Stream := TFileStream.Create(DistroJoin(Root, DistroShellRelPath(Shell.Triple)),
      fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Bytes, Stream.Size);
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
    Expect<Integer>(Ord(DistroClassifyImage(Bytes, Machine))).ToBe(Ord(Shell.Image));
    Expect<Boolean>(DistroImageMatchesShell(Bytes, Shell.Triple)).ToBe(True);
    if I = DISTRO_SHELL_COUNT - 1 then
      Wrong := DistroShell(0).Triple
    else
      Wrong := DistroShell(I + 1).Triple;
    Expect<Boolean>(DistroImageMatchesShell(Bytes, Wrong)).ToBe(False);
  end;
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
  SetLength(Parsed, Length(Parsed) - 1);
  Status := DistroChecksumsCoverArchives('0.2.0', Parsed);
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsChecksumMismatch));
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

procedure TDistroTests.TestCompileEmissionNotShipped;
begin
  Expect<Boolean>(DistroCompileEmissionNotShipped(
    'wasmlight compile: EWasmCompileError: strict compile is not available')).ToBe(True);
  Expect<Boolean>(DistroCompileEmissionNotShipped(
    'runtime shell packaging is not available for target "x86_64-linux"')).ToBe(True);
  Expect<Boolean>(DistroCompileEmissionNotShipped(
    'EWasmLinkError: unknown import')).ToBe(False);
end;

procedure TDistroTests.TestElfEmissionBindsItsShell;
var
  Shell, Image, Payload, Other: TBytes;
  Info: TWasmElfPackageInfo;
  Status: TWasmDistroResult;
begin
  Shell := PlaceholderElfTemplate(weptX86_64Linux);
  Payload := ProbePayload('x86_64-linux', Shell);
  Expect<Integer>(Ord(PackageElfShell(Shell, Payload, weptX86_64Linux, Image)))
    .ToBe(Ord(eprOk));
  Expect<Integer>(Ord(ParseElfPackage(Image, Info))).ToBe(Ord(eprOk));
  Status := DistroCheckEmission(Image, Info.Payload, Shell, 'x86_64-linux');
  Expect<Boolean>(Status.IsOk).ToBe(True);
  { Right image, wrong requested target. }
  Status := DistroCheckEmission(Image, Info.Payload, Shell, 'x86_64-darwin');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadEmission));
  { A payload stamped for macOS inside a Linux image. }
  Status := DistroCheckEmission(Image, ProbePayload('x86_64-darwin', Shell),
    Shell, 'x86_64-linux');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadEmission));
  { Packaged onto some other shell than the archive's. }
  Other := Copy(Shell);
  Other[High(Other)] := Other[High(Other)] xor $FF;
  Status := DistroCheckEmission(Image, Info.Payload, Other, 'x86_64-linux');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadEmission));
  { A payload that is not a native-executable payload at all. }
  Status := DistroCheckEmission(Image, TBytes.Create($57, $53, $48, $4C), Shell,
    'x86_64-linux');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadEmission));
end;

procedure TDistroTests.TestMachOEmissionBindsItsShell;
var
  Shell, Image, Payload, Extracted: TBytes;
  Status: TWasmDistroResult;
  Info: TWasmMachOInfo;
begin
  Shell := WriteMachOShellTemplate(wmtX86_64Darwin);
  Payload := ProbePayload('x86_64-darwin', Shell);
  Expect<Integer>(Ord(PackageMachORuntimeShell(Shell, Payload, 'probe', Image)))
    .ToBe(Ord(mmrOk));
  Expect<Integer>(Ord(ExtractMachOPayload(Image, Extracted))).ToBe(Ord(mmrOk));
  Status := DistroCheckEmission(Image, Extracted, Shell, 'x86_64-darwin');
  Expect<Boolean>(Status.IsOk).ToBe(True);
  Status := DistroCheckEmission(Image, Extracted, Shell, 'aarch64-darwin');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadEmission));
  { Flip a byte of the signed payload: the ad-hoc signature must fail. }
  Expect<Integer>(Ord(InspectMachO(Image, Info))).ToBe(Ord(mmrOk));
  Image[Info.PayloadOff] := Image[Info.PayloadOff] xor $FF;
  Status := DistroCheckEmission(Image, Extracted, Shell, 'x86_64-darwin');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadEmission));
end;

function TDistroTests.UnsignedMachOTemplate(const ATarget: TWasmMachOTarget): TBytes;
const
  LC_CODE_SIGNATURE = $1D;
  LC_DYLIB_CODE_SIGN_DRS = $2B;
var
  Info: TWasmMachOInfo;
  Off, Cmds, I: Integer;
begin
  { Intel `ld` links without a signature. Retag the template's
    LC_CODE_SIGNATURE as an inert linkedit command to model that shell. }
  Result := WriteMachOShellTemplate(ATarget);
  Cmds := Result[16] or (Result[17] shl 8);
  Off := 32;
  for I := 1 to Cmds do
  begin
    if Result[Off] = LC_CODE_SIGNATURE then
      Result[Off] := LC_DYLIB_CODE_SIGN_DRS;
    Off := Off + (Result[Off + 4] or (Result[Off + 5] shl 8));
  end;
  Expect<Integer>(Ord(InspectMachO(Result, Info))).ToBe(Ord(mmrOk));
  Expect<Boolean>(Info.HasSignature).ToBe(False);
end;

procedure TDistroTests.TestUnsignedMachOEmission;
var
  Shell, Image, Extracted: TBytes;
  Status: TWasmDistroResult;
begin
  { x86-64 macOS runs unsigned code: the appended-trailer image passes. }
  Shell := UnsignedMachOTemplate(wmtX86_64Darwin);
  Expect<Integer>(Ord(PackageAppendedPayload(Shell,
    ProbePayload('x86_64-darwin', Shell), Image))).ToBe(Ord(eprOk));
  Expect<Integer>(Ord(ParseAppendedPayload(Image, Extracted))).ToBe(Ord(eprOk));
  Status := DistroCheckEmission(Image, Extracted, Shell, 'x86_64-darwin');
  Expect<Boolean>(Status.IsOk).ToBe(True);
  { arm64 macOS does not: the same form for AArch64 is rejected. }
  Shell := UnsignedMachOTemplate(wmtAarch64Darwin);
  Expect<Integer>(Ord(PackageAppendedPayload(Shell,
    ProbePayload('aarch64-darwin', Shell), Image))).ToBe(Ord(eprOk));
  Expect<Integer>(Ord(ParseAppendedPayload(Image, Extracted))).ToBe(Ord(eprOk));
  Status := DistroCheckEmission(Image, Extracted, Shell, 'aarch64-darwin');
  Expect<Integer>(Ord(Status.Status)).ToBe(Ord(ddsBadEmission));
end;

procedure TDistroTests.TestCompileHelpDetection;
begin
  Expect<Boolean>(DistroHelpListsCompile(
    'Commands:' + sLineBreak +
    '  inspect   Decode a module' + sLineBreak +
    '  compile   Emit a native executable' + sLineBreak)).ToBe(True);
  Expect<Boolean>(DistroHelpListsCompile(
    '  aot        Ahead-of-time compile a module' + sLineBreak)).ToBe(False);
  Expect<Boolean>(DistroHelpListsCompile('compile'#9'Emit a native executable')).ToBe(True);
  Expect<Boolean>(DistroUnknownCompileCommand(
    'wasmlight: unknown command: compile')).ToBe(True);
end;

procedure TDistroTests.TestCompilerCatalogIsLoadable;
var
  Root: string;
  Entry: TWasmShellEntry;
  Host: TWasmDistroHost;
  Triples: TStringArray;
  I: Integer;
begin
  Root := TempRoot;
  BuildValidTree(Root, PROGRAM_VERSION, 'aarch64-darwin', wdcFixture);
  Expect<Boolean>(DistroFindHost('aarch64-darwin', Host)).ToBe(True);
  Triples := DistroHostShells(Host);
  for I := 0 to High(Triples) do
    Expect<Integer>(Ord(ResolveShell(DistroJoin(Root, DISTRO_SHELL_ROOT),
      Triples[I], Entry))).ToBe(Ord(ssrOk));
  { The compiler's own selector finds no foreign-architecture shell. }
  Expect<Integer>(Ord(ResolveShell(DistroJoin(Root, DISTRO_SHELL_ROOT),
    'x86_64-linux', Entry))).ToBe(Ord(ssrMissingShell));
  DeleteFile(DistroJoin(Root, DISTRO_SHELL_ROOT + '/' + SHELL_CATALOG_FILENAME));
  Expect<Integer>(Ord(DistroValidateTree(Root).Status)).ToBe(Ord(ddsIncompleteCatalog));
end;

procedure TDistroTests.TestArchivePathsStayContained;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    DistroJoin(TempRoot, '../outside');
  except
    on E: EArgumentException do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    DistroArchiveBase('../../outside', 'macos-arm64');
  except
    on E: EArgumentException do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TDistroTests.SetupTests;
begin
  Test('archive catalogs load through the compiler selector', TestCompilerCatalogIsLoadable);
  Test('archive paths and staging versions stay contained', TestArchivePathsStayContained);
  Test('four Unix hosts resolve by triple and display name', TestHostLookup);
  Test('a host archive carries its own architecture for Linux and macOS',
    TestHostShellsShareTheHostArchitecture);
  Test('archive and checksum names follow the lwpt pattern', TestArchiveNames);
  Test('a valid MANIFEST round-trips', TestManifestRoundTrip);
  Test('a Win64 host is rejected in the 0.2.0 catalog', TestRejectUnknownHost);
  Test('a partial shell list is incomplete', TestRejectIncompleteCatalog);
  Test('an unknown shell triple is rejected', TestRejectUnknownShell);
  Test('a duplicated shell triple is rejected', TestRejectDuplicateShell);
  Test('a foreign-architecture shell is rejected', TestRejectForeignArchitectureShell);
  Test('an all-to-all catalog is not a 0.2.0 host archive', TestRejectAllToAllCatalogTree);
  Test('every synthesized shell carries its ELF or Mach-O magic', TestElfAndMachOMagic);
  Test('a swapped shell image fails structural validation', TestSwappedShellImage);
  Test('a complete tree validates and a version mismatch does not', TestValidateTree);
  Test('AppleDouble names are forbidden in an archive tree', TestForbiddenAppleDouble);
  Test('checksums.txt must list every host archive basename', TestChecksumsCoverFourArchives);
  Test('checksum names may not contain a path', TestChecksumsRejectPath);
  Test('compile is detected from the command list, not the aot blurb',
    TestCompileHelpDetection);
  Test('stub compile/packaging errors are emission-not-shipped, not archive faults',
    TestCompileEmissionNotShipped);
  Test('an ELF emission binds its target and the archive shell', TestElfEmissionBindsItsShell);
  Test('a Mach-O emission binds its target, shell, and signature',
    TestMachOEmissionBindsItsShell);
  Test('an unsigned Mach-O emission is x86-64 only', TestUnsignedMachOEmission);
end;

begin
  Randomize;
  TestRunnerProgram.AddSuite(TDistroTests.Create('Wasm.Distro'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
