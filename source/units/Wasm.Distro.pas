{ Wasm.Distro — release-archive contract for the compiler and its
  runtime-shell catalog.

  Owns host/target names, the unpacked tree layout, the line-based MANIFEST,
  GNU SHA-256 checksum-file syntax, and ELF/Mach-O structural recognition.
  Packing and checksum *computation* stay in scripts/ (they shell out to
  tar and sha256sum/shasum). This unit is not on the decode, validation,
  or execution path. }
unit Wasm.Distro;

{$I Shared.inc}

interface

uses
  SysUtils;

const
  DISTRO_PACKAGE = 'wasmlight';
  DISTRO_MANIFEST_NAME = 'MANIFEST';
  DISTRO_COMPILER_NAME = 'wasmlight';
  DISTRO_SHELL_NAME = 'shell';
  DISTRO_META_NAME = 'META';
  DISTRO_SHELL_ROOT = 'share/wasmlight/shells';
  DISTRO_CHECKSUMS_SUFFIX = '-checksums.txt';
  DISTRO_ARCHIVE_EXT = '.tar.gz';
  DISTRO_HOST_COUNT = 4;
  DISTRO_SHELL_COUNT = 4;

type
  TWasmDistroImage = (wdiUnknown, wdiElf64, wdiMachO64);
  TWasmDistroCatalog = (wdcLive, wdcFixture);

  TWasmDistroHost = record
    Triple: string;
    Display: string;
  end;

  TWasmDistroShell = record
    Triple: string;
    Image: TWasmDistroImage;
    Machine: LongWord;
  end;

  TWasmDistroStatus = (
    ddsOk,
    ddsMissingManifest,
    ddsMalformedManifest,
    ddsUnknownHost,
    ddsDisplayMismatch,
    ddsUnknownShell,
    ddsDuplicateShell,
    ddsIncompleteCatalog,
    ddsMissingFile,
    ddsBadShellImage,
    ddsBadMeta,
    ddsChecksumMalformed,
    ddsChecksumMismatch,
    ddsForbiddenName,
    ddsVersionMismatch
  );

  TWasmDistroResult = record
    Status: TWasmDistroStatus;
    Detail: string;
    class function Ok: TWasmDistroResult; static;
    class function Fail(AStatus: TWasmDistroStatus;
      const ADetail: string): TWasmDistroResult; static;
    function IsOk: Boolean;
  end;

  TWasmDistroManifest = record
    Version: string;
    HostTriple: string;
    Display: string;
    Catalog: TWasmDistroCatalog;
    Shells: array of string;
    Files: array of string;
    Hashes: array of record
      RelPath: string;
      Digest: string;
    end;
  end;

  TWasmDistroChecksum = record
    Digest: string;
    FileName: string;
  end;

  TWasmDistroChecksums = array of TWasmDistroChecksum;

function DistroHost(const AIndex: Integer): TWasmDistroHost;
function DistroShell(const AIndex: Integer): TWasmDistroShell;
function DistroFindHost(const AName: string; out AHost: TWasmDistroHost): Boolean;
function DistroFindShell(const ATriple: string; out AShell: TWasmDistroShell): Boolean;
function DistroCurrentHost(out AHost: TWasmDistroHost): Boolean;

function DistroArchiveBase(const AVersion, ADisplay: string): string;
function DistroArchiveFileName(const AVersion, ADisplay: string): string;
function DistroChecksumsFileName(const AVersion: string): string;
function DistroShellRelPath(const ATriple: string): string;
function DistroMetaRelPath(const ATriple: string): string;
function DistroJoin(const ARoot, ARel: string): string;

function DistroFormatManifest(const AManifest: TWasmDistroManifest): string;
function DistroParseManifest(const AText: string;
  out AManifest: TWasmDistroManifest): TWasmDistroResult;
function DistroValidateManifest(const AManifest: TWasmDistroManifest): TWasmDistroResult;

function DistroClassifyImage(const ABytes: TBytes; out AMachine: LongWord): TWasmDistroImage;
function DistroImageMatchesShell(const ABytes: TBytes; const ATriple: string): Boolean;
procedure DistroWriteStructuralShell(const APath, ATriple: string);
procedure DistroWriteShellMeta(const APath, ATriple: string);
function DistroParseMeta(const AText: string; out ATriple: string): TWasmDistroResult;

function DistroFormatChecksums(const ARows: TWasmDistroChecksums): string;
function DistroParseChecksums(const AText: string;
  out ARows: TWasmDistroChecksums): TWasmDistroResult;
function DistroExpectedArchiveNames(const AVersion: string): TStringArray;
function DistroChecksumsCoverArchives(const AVersion: string;
  const ARows: TWasmDistroChecksums): TWasmDistroResult;
function DistroIsForbiddenName(const AName: string): Boolean;

function DistroValidateTree(const ARoot: string;
  const AExpectedVersion: string = ''): TWasmDistroResult;
function DistroSynthesizeCatalog(const ARoot: string): TWasmDistroResult;

function DistroHelpListsCompile(const AHelpText: string): Boolean;
function DistroUnknownCompileCommand(const AText: string): Boolean;

implementation

uses
  Classes;

const
  ELF_MAGIC: array[0..3] of Byte = ($7F, $45, $4C, $46);
  ELF_CLASS64 = 2;
  ELF_DATA2LSB = 1;
  ELF_ET_EXEC = 2;
  ELF_EM_X86_64 = 62;
  ELF_EM_AARCH64 = 183;
  MACHO_MAGIC_64_0 = $CF;
  MACHO_MAGIC_64_1 = $FA;
  MACHO_MAGIC_64_2 = $ED;
  MACHO_MAGIC_64_3 = $FE;
  MACHO_CPU_X86_64 = $01000007;
  MACHO_CPU_ARM64 = $0100000C;
  MACHO_MH_EXECUTE = 2;

  HOSTS: array[0..DISTRO_HOST_COUNT - 1] of TWasmDistroHost = (
    (Triple: 'aarch64-linux'; Display: 'linux-arm64'),
    (Triple: 'x86_64-linux'; Display: 'linux-x64'),
    (Triple: 'aarch64-darwin'; Display: 'macos-arm64'),
    (Triple: 'x86_64-darwin'; Display: 'macos-x64')
  );

  SHELLS: array[0..DISTRO_SHELL_COUNT - 1] of TWasmDistroShell = (
    (Triple: 'aarch64-linux'; Image: wdiElf64; Machine: ELF_EM_AARCH64),
    (Triple: 'x86_64-linux'; Image: wdiElf64; Machine: ELF_EM_X86_64),
    (Triple: 'aarch64-darwin'; Image: wdiMachO64; Machine: MACHO_CPU_ARM64),
    (Triple: 'x86_64-darwin'; Image: wdiMachO64; Machine: MACHO_CPU_X86_64)
  );

class function TWasmDistroResult.Ok: TWasmDistroResult;
begin
  Result.Status := ddsOk;
  Result.Detail := '';
end;

class function TWasmDistroResult.Fail(AStatus: TWasmDistroStatus;
  const ADetail: string): TWasmDistroResult;
begin
  Result.Status := AStatus;
  Result.Detail := ADetail;
end;

function TWasmDistroResult.IsOk: Boolean;
begin
  Result := Status = ddsOk;
end;

function DistroHost(const AIndex: Integer): TWasmDistroHost;
begin
  Result := HOSTS[AIndex];
end;

function DistroShell(const AIndex: Integer): TWasmDistroShell;
begin
  Result := SHELLS[AIndex];
end;

function DistroFindHost(const AName: string; out AHost: TWasmDistroHost): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(HOSTS) do
    if SameText(AName, HOSTS[I].Triple) or SameText(AName, HOSTS[I].Display) then
    begin
      AHost := HOSTS[I];
      Exit(True);
    end;
  Result := False;
end;

function DistroFindShell(const ATriple: string; out AShell: TWasmDistroShell): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(SHELLS) do
    if SameText(ATriple, SHELLS[I].Triple) then
    begin
      AShell := SHELLS[I];
      Exit(True);
    end;
  Result := False;
end;

function DistroCurrentHost(out AHost: TWasmDistroHost): Boolean;
var
  Triple: string;
begin
  Triple := '';
{$IF DEFINED(CPUAARCH64) AND DEFINED(LINUX)}
  Triple := 'aarch64-linux';
{$ELSEIF DEFINED(CPUX86_64) AND DEFINED(LINUX)}
  Triple := 'x86_64-linux';
{$ELSEIF DEFINED(CPUAARCH64) AND DEFINED(DARWIN)}
  Triple := 'aarch64-darwin';
{$ELSEIF DEFINED(CPUX86_64) AND DEFINED(DARWIN)}
  Triple := 'x86_64-darwin';
{$ENDIF}
  Result := (Triple <> '') and DistroFindHost(Triple, AHost);
end;

function DistroArchiveBase(const AVersion, ADisplay: string): string;
begin
  Result := DISTRO_PACKAGE + '-' + AVersion + '-' + ADisplay;
end;

function DistroArchiveFileName(const AVersion, ADisplay: string): string;
begin
  Result := DistroArchiveBase(AVersion, ADisplay) + DISTRO_ARCHIVE_EXT;
end;

function DistroChecksumsFileName(const AVersion: string): string;
begin
  Result := DISTRO_PACKAGE + '-' + AVersion + DISTRO_CHECKSUMS_SUFFIX;
end;

function DistroShellRelPath(const ATriple: string): string;
begin
  Result := DISTRO_SHELL_ROOT + '/' + ATriple + '/' + DISTRO_SHELL_NAME;
end;

function DistroMetaRelPath(const ATriple: string): string;
begin
  Result := DISTRO_SHELL_ROOT + '/' + ATriple + '/' + DISTRO_META_NAME;
end;

function DistroJoin(const ARoot, ARel: string): string;
var
  Normalized: string;
begin
  Normalized := StringReplace(ARel, '/', PathDelim, [rfReplaceAll]);
  Result := IncludeTrailingPathDelimiter(ARoot) + Normalized;
end;

procedure AppendLine(var AText: string; const ALine: string);
begin
  if AText = '' then
    AText := ALine
  else
    AText := AText + sLineBreak + ALine;
end;

function DistroFormatManifest(const AManifest: TWasmDistroManifest): string;
var
  I: Integer;
  Catalog: string;
begin
  if AManifest.Catalog = wdcLive then
    Catalog := 'live'
  else
    Catalog := 'fixture';
  Result := '';
  AppendLine(Result, 'version ' + AManifest.Version);
  AppendLine(Result, 'host ' + AManifest.HostTriple);
  AppendLine(Result, 'display ' + AManifest.Display);
  AppendLine(Result, 'catalog ' + Catalog);
  for I := 0 to High(AManifest.Shells) do
    AppendLine(Result, 'shell ' + AManifest.Shells[I]);
  for I := 0 to High(AManifest.Files) do
    AppendLine(Result, 'file ' + AManifest.Files[I]);
  for I := 0 to High(AManifest.Hashes) do
    AppendLine(Result, 'hash ' + AManifest.Hashes[I].RelPath + ' ' +
      AManifest.Hashes[I].Digest);
end;

function SplitKeyValue(const ALine: string; out AKey, AValue: string): Boolean;
var
  Space: Integer;
  Trimmed: string;
begin
  Trimmed := Trim(ALine);
  if (Trimmed = '') or (Trimmed[1] = '#') then
    Exit(False);
  Space := Pos(' ', Trimmed);
  if Space = 0 then
  begin
    AKey := LowerCase(Trimmed);
    AValue := '';
  end
  else
  begin
    AKey := LowerCase(Copy(Trimmed, 1, Space - 1));
    AValue := Trim(Copy(Trimmed, Space + 1, MaxInt));
  end;
  Result := True;
end;

procedure AddString(var AItems: TStringArray; const AValue: string);
begin
  SetLength(AItems, Length(AItems) + 1);
  AItems[High(AItems)] := AValue;
end;

function DistroParseManifest(const AText: string;
  out AManifest: TWasmDistroManifest): TWasmDistroResult;
var
  Lines: TStringList;
  I, Space: Integer;
  Key, Value, Rel, Digest: string;
begin
  AManifest.Version := '';
  AManifest.HostTriple := '';
  AManifest.Display := '';
  AManifest.Catalog := wdcLive;
  SetLength(AManifest.Shells, 0);
  SetLength(AManifest.Files, 0);
  SetLength(AManifest.Hashes, 0);
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      if not SplitKeyValue(Lines[I], Key, Value) then
        Continue;
      if Key = 'version' then
        AManifest.Version := Value
      else if Key = 'host' then
        AManifest.HostTriple := Value
      else if Key = 'display' then
        AManifest.Display := Value
      else if Key = 'catalog' then
      begin
        if SameText(Value, 'live') then
          AManifest.Catalog := wdcLive
        else if SameText(Value, 'fixture') then
          AManifest.Catalog := wdcFixture
        else
          Exit(TWasmDistroResult.Fail(ddsMalformedManifest,
            'catalog must be live or fixture'));
      end
      else if Key = 'shell' then
        AddString(AManifest.Shells, Value)
      else if Key = 'file' then
        AddString(AManifest.Files, Value)
      else if Key = 'hash' then
      begin
        Space := Pos(' ', Value);
        if Space = 0 then
          Exit(TWasmDistroResult.Fail(ddsMalformedManifest,
            'hash line needs a path and a digest'));
        Rel := Trim(Copy(Value, 1, Space - 1));
        Digest := LowerCase(Trim(Copy(Value, Space + 1, MaxInt)));
        SetLength(AManifest.Hashes, Length(AManifest.Hashes) + 1);
        AManifest.Hashes[High(AManifest.Hashes)].RelPath := Rel;
        AManifest.Hashes[High(AManifest.Hashes)].Digest := Digest;
      end
      else
        Exit(TWasmDistroResult.Fail(ddsMalformedManifest,
          'unknown manifest key: ' + Key));
    end;
  finally
    Lines.Free;
  end;
  Result := DistroValidateManifest(AManifest);
end;

function DistroValidateManifest(const AManifest: TWasmDistroManifest): TWasmDistroResult;
var
  Host: TWasmDistroHost;
  Shell: TWasmDistroShell;
  Seen: array[0..DISTRO_SHELL_COUNT - 1] of Boolean;
  I, J: Integer;
begin
  if Trim(AManifest.Version) = '' then
    Exit(TWasmDistroResult.Fail(ddsMalformedManifest, 'missing version'));
  if not DistroFindHost(AManifest.HostTriple, Host) then
    Exit(TWasmDistroResult.Fail(ddsUnknownHost, AManifest.HostTriple));
  if AManifest.Display <> Host.Display then
    Exit(TWasmDistroResult.Fail(ddsDisplayMismatch,
      AManifest.Display + ' is not ' + Host.Display));
  if AManifest.HostTriple <> Host.Triple then
    Exit(TWasmDistroResult.Fail(ddsUnknownHost, AManifest.HostTriple));
  if Length(AManifest.Shells) = 0 then
    Exit(TWasmDistroResult.Fail(ddsIncompleteCatalog, 'no shells listed'));
  FillChar(Seen, SizeOf(Seen), 0);
  for I := 0 to High(AManifest.Shells) do
  begin
    if not DistroFindShell(AManifest.Shells[I], Shell) then
      Exit(TWasmDistroResult.Fail(ddsUnknownShell, AManifest.Shells[I]));
    for J := 0 to High(SHELLS) do
      if SHELLS[J].Triple = Shell.Triple then
      begin
        if Seen[J] then
          Exit(TWasmDistroResult.Fail(ddsDuplicateShell, Shell.Triple));
        Seen[J] := True;
      end;
  end;
  for J := 0 to High(Seen) do
    if not Seen[J] then
      Exit(TWasmDistroResult.Fail(ddsIncompleteCatalog,
        'missing shell ' + SHELLS[J].Triple));
  Result := TWasmDistroResult.Ok;
end;

function ReadU16LE(const ABytes: TBytes; const AOffset: Integer): Word;
begin
  Result := ABytes[AOffset] or (Word(ABytes[AOffset + 1]) shl 8);
end;

function ReadU32LE(const ABytes: TBytes; const AOffset: Integer): LongWord;
begin
  Result := ABytes[AOffset] or
    (LongWord(ABytes[AOffset + 1]) shl 8) or
    (LongWord(ABytes[AOffset + 2]) shl 16) or
    (LongWord(ABytes[AOffset + 3]) shl 24);
end;

function DistroClassifyImage(const ABytes: TBytes; out AMachine: LongWord): TWasmDistroImage;
begin
  AMachine := 0;
  Result := wdiUnknown;
  if Length(ABytes) >= 20 then
    if (ABytes[0] = ELF_MAGIC[0]) and (ABytes[1] = ELF_MAGIC[1]) and
      (ABytes[2] = ELF_MAGIC[2]) and (ABytes[3] = ELF_MAGIC[3]) and
      (ABytes[4] = ELF_CLASS64) and (ABytes[5] = ELF_DATA2LSB) then
    begin
      AMachine := ReadU16LE(ABytes, 18);
      Exit(wdiElf64);
    end;
  if Length(ABytes) >= 8 then
    if (ABytes[0] = MACHO_MAGIC_64_0) and (ABytes[1] = MACHO_MAGIC_64_1) and
      (ABytes[2] = MACHO_MAGIC_64_2) and (ABytes[3] = MACHO_MAGIC_64_3) then
    begin
      AMachine := ReadU32LE(ABytes, 4);
      Exit(wdiMachO64);
    end;
end;

function DistroImageMatchesShell(const ABytes: TBytes; const ATriple: string): Boolean;
var
  Shell: TWasmDistroShell;
  Image: TWasmDistroImage;
  Machine: LongWord;
begin
  Result := DistroFindShell(ATriple, Shell);
  if not Result then
    Exit;
  Image := DistroClassifyImage(ABytes, Machine);
  Result := (Image = Shell.Image) and (Machine = Shell.Machine);
end;

procedure WriteBytes(const APath: string; const ABytes: TBytes);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFilePath(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
end;

procedure DistroWriteStructuralShell(const APath, ATriple: string);
var
  Shell: TWasmDistroShell;
  Bytes: TBytes;
begin
  if not DistroFindShell(ATriple, Shell) then
    raise EArgumentException.Create('unknown shell target: ' + ATriple);
  if Shell.Image = wdiElf64 then
  begin
    SetLength(Bytes, 64);
    FillChar(Bytes[0], Length(Bytes), 0);
    Bytes[0] := ELF_MAGIC[0];
    Bytes[1] := ELF_MAGIC[1];
    Bytes[2] := ELF_MAGIC[2];
    Bytes[3] := ELF_MAGIC[3];
    Bytes[4] := ELF_CLASS64;
    Bytes[5] := ELF_DATA2LSB;
    Bytes[6] := 1;
    Bytes[16] := ELF_ET_EXEC;
    Bytes[18] := Byte(Shell.Machine);
    Bytes[19] := Byte(Shell.Machine shr 8);
  end
  else
  begin
    SetLength(Bytes, 32);
    FillChar(Bytes[0], Length(Bytes), 0);
    Bytes[0] := MACHO_MAGIC_64_0;
    Bytes[1] := MACHO_MAGIC_64_1;
    Bytes[2] := MACHO_MAGIC_64_2;
    Bytes[3] := MACHO_MAGIC_64_3;
    Bytes[4] := Byte(Shell.Machine);
    Bytes[5] := Byte(Shell.Machine shr 8);
    Bytes[6] := Byte(Shell.Machine shr 16);
    Bytes[7] := Byte(Shell.Machine shr 24);
    Bytes[12] := MACHO_MH_EXECUTE;
  end;
  WriteBytes(APath, Bytes);
end;

procedure DistroWriteShellMeta(const APath, ATriple: string);
var
  Lines: TStringList;
begin
  ForceDirectories(ExtractFilePath(APath));
  Lines := TStringList.Create;
  try
    Lines.Add('target ' + ATriple);
    Lines.Add('kind runtime-shell');
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

function DistroParseMeta(const AText: string; out ATriple: string): TWasmDistroResult;
var
  Lines: TStringList;
  I: Integer;
  Key, Value: string;
  Kind: string;
  Shell: TWasmDistroShell;
begin
  ATriple := '';
  Kind := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      if not SplitKeyValue(Lines[I], Key, Value) then
        Continue;
      if Key = 'target' then
        ATriple := Value
      else if Key = 'kind' then
        Kind := Value;
    end;
  finally
    Lines.Free;
  end;
  if not DistroFindShell(ATriple, Shell) then
    Exit(TWasmDistroResult.Fail(ddsBadMeta, 'META target ' + ATriple));
  if Kind <> 'runtime-shell' then
    Exit(TWasmDistroResult.Fail(ddsBadMeta, 'META kind must be runtime-shell'));
  Result := TWasmDistroResult.Ok;
end;

function DistroFormatChecksums(const ARows: TWasmDistroChecksums): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ARows) do
    AppendLine(Result, LowerCase(ARows[I].Digest) + '  ' + ARows[I].FileName);
end;

function IsHexDigest(const ADigest: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := Length(ADigest) = 64;
  if not Result then
    Exit;
  for I := 1 to Length(ADigest) do
  begin
    C := ADigest[I];
    if not (C in ['0'..'9', 'a'..'f']) then
      Exit(False);
  end;
end;

function DistroParseChecksums(const AText: string;
  out ARows: TWasmDistroChecksums): TWasmDistroResult;
var
  Lines: TStringList;
  I, Sep: Integer;
  Line, Digest, Name: string;
begin
  SetLength(ARows, 0);
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Line = '' then
        Continue;
      Sep := Pos('  ', Line);
      if Sep = 0 then
        Sep := Pos(' *', Line);
      if Sep = 0 then
        Exit(TWasmDistroResult.Fail(ddsChecksumMalformed, Line));
      Digest := LowerCase(Trim(Copy(Line, 1, Sep - 1)));
      Name := Trim(Copy(Line, Sep + 2, MaxInt));
      if (Name <> '') and (Name[1] = '*') then
        Delete(Name, 1, 1);
      Name := Trim(Name);
      if not IsHexDigest(Digest) then
        Exit(TWasmDistroResult.Fail(ddsChecksumMalformed,
          'digest is not 64 hex chars'));
      if (Name = '') or (Pos('/', Name) > 0) or (Pos('\', Name) > 0) then
        Exit(TWasmDistroResult.Fail(ddsChecksumMalformed,
          'checksum name must be a basename'));
      SetLength(ARows, Length(ARows) + 1);
      ARows[High(ARows)].Digest := Digest;
      ARows[High(ARows)].FileName := Name;
    end;
  finally
    Lines.Free;
  end;
  if Length(ARows) = 0 then
    Exit(TWasmDistroResult.Fail(ddsChecksumMalformed, 'empty checksums'));
  Result := TWasmDistroResult.Ok;
end;

function DistroExpectedArchiveNames(const AVersion: string): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, DISTRO_HOST_COUNT);
  for I := 0 to High(HOSTS) do
    Result[I] := DistroArchiveFileName(AVersion, HOSTS[I].Display);
end;

function DistroChecksumsCoverArchives(const AVersion: string;
  const ARows: TWasmDistroChecksums): TWasmDistroResult;
var
  Expected: TStringArray;
  I, J: Integer;
  Found: Boolean;
begin
  Expected := DistroExpectedArchiveNames(AVersion);
  if Length(ARows) <> Length(Expected) then
    Exit(TWasmDistroResult.Fail(ddsChecksumMismatch,
      'expected ' + IntToStr(Length(Expected)) + ' archives'));
  for I := 0 to High(Expected) do
  begin
    Found := False;
    for J := 0 to High(ARows) do
      if ARows[J].FileName = Expected[I] then
      begin
        Found := True;
        Break;
      end;
    if not Found then
      Exit(TWasmDistroResult.Fail(ddsChecksumMismatch,
        'missing ' + Expected[I]));
  end;
  Result := TWasmDistroResult.Ok;
end;

function DistroIsForbiddenName(const AName: string): Boolean;
var
  Base: string;
begin
  Base := ExtractFileName(AName);
  Result := (Base = '.DS_Store') or
    (Copy(Base, 1, 2) = '._') or
    (Base = '.AppleDouble');
end;

function LoadBytes(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function WalkForbidden(const ARoot: string): TWasmDistroResult;
var
  Search: TSearchRec;
  Child: string;
  Nested: TWasmDistroResult;
begin
  Result := TWasmDistroResult.Ok;
  if FindFirst(IncludeTrailingPathDelimiter(ARoot) + '*', faAnyFile, Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      if DistroIsForbiddenName(Search.Name) then
        Exit(TWasmDistroResult.Fail(ddsForbiddenName, Search.Name));
      Child := IncludeTrailingPathDelimiter(ARoot) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        Nested := WalkForbidden(Child);
        if not Nested.IsOk then
          Exit(Nested);
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function DistroValidateTree(const ARoot: string;
  const AExpectedVersion: string): TWasmDistroResult;
var
  ManifestPath, MetaPath, ShellPath, CompilerPath: string;
  Text: TStringList;
  Manifest: TWasmDistroManifest;
  I: Integer;
  Bytes: TBytes;
  MetaTriple: string;
begin
  ManifestPath := DistroJoin(ARoot, DISTRO_MANIFEST_NAME);
  if not FileExists(ManifestPath) then
    Exit(TWasmDistroResult.Fail(ddsMissingManifest, ManifestPath));
  Text := TStringList.Create;
  try
    Text.LoadFromFile(ManifestPath);
    Result := DistroParseManifest(Text.Text, Manifest);
    if not Result.IsOk then
      Exit;
  finally
    Text.Free;
  end;
  if (AExpectedVersion <> '') and (Manifest.Version <> AExpectedVersion) then
    Exit(TWasmDistroResult.Fail(ddsVersionMismatch,
      Manifest.Version + ' != ' + AExpectedVersion));
  Result := WalkForbidden(ARoot);
  if not Result.IsOk then
    Exit;
  CompilerPath := DistroJoin(ARoot, DISTRO_COMPILER_NAME);
  if not FileExists(CompilerPath) then
    Exit(TWasmDistroResult.Fail(ddsMissingFile, DISTRO_COMPILER_NAME));
  for I := 0 to High(SHELLS) do
  begin
    ShellPath := DistroJoin(ARoot, DistroShellRelPath(SHELLS[I].Triple));
    MetaPath := DistroJoin(ARoot, DistroMetaRelPath(SHELLS[I].Triple));
    if not FileExists(ShellPath) then
      Exit(TWasmDistroResult.Fail(ddsMissingFile, DistroShellRelPath(SHELLS[I].Triple)));
    if not FileExists(MetaPath) then
      Exit(TWasmDistroResult.Fail(ddsMissingFile, DistroMetaRelPath(SHELLS[I].Triple)));
    Bytes := LoadBytes(ShellPath);
    if not DistroImageMatchesShell(Bytes, SHELLS[I].Triple) then
      Exit(TWasmDistroResult.Fail(ddsBadShellImage, SHELLS[I].Triple));
    Text := TStringList.Create;
    try
      Text.LoadFromFile(MetaPath);
      Result := DistroParseMeta(Text.Text, MetaTriple);
      if not Result.IsOk then
        Exit;
      if MetaTriple <> SHELLS[I].Triple then
        Exit(TWasmDistroResult.Fail(ddsBadMeta,
          MetaTriple + ' in ' + SHELLS[I].Triple));
    finally
      Text.Free;
    end;
  end;
  for I := 0 to High(Manifest.Files) do
    if not FileExists(DistroJoin(ARoot, Manifest.Files[I])) then
      Exit(TWasmDistroResult.Fail(ddsMissingFile, Manifest.Files[I]));
  Result := TWasmDistroResult.Ok;
end;

function DistroSynthesizeCatalog(const ARoot: string): TWasmDistroResult;
var
  I: Integer;
begin
  for I := 0 to High(SHELLS) do
  begin
    DistroWriteStructuralShell(DistroJoin(ARoot, DistroShellRelPath(SHELLS[I].Triple)),
      SHELLS[I].Triple);
    DistroWriteShellMeta(DistroJoin(ARoot, DistroMetaRelPath(SHELLS[I].Triple)),
      SHELLS[I].Triple);
  end;
  Result := TWasmDistroResult.Ok;
end;

function DistroHelpListsCompile(const AHelpText: string): Boolean;
var
  Lines: TStringList;
  I: Integer;
  Line: string;
begin
  Result := False;
  Lines := TStringList.Create;
  try
    Lines.Text := AHelpText;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Copy(Line, 1, 8) = 'compile ') or (Line = 'compile') or
        (Copy(Line, 1, 8) = 'compile'#9) then
        Exit(True);
    end;
  finally
    Lines.Free;
  end;
end;

function DistroUnknownCompileCommand(const AText: string): Boolean;
begin
  Result := Pos('unknown command: compile', LowerCase(AText)) > 0;
end;

end.
