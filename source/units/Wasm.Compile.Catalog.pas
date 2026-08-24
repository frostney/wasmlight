{ Wasm.Compile.Catalog — installed runtime-shell discovery and deterministic
  target selection.

  Cross-compilation locates a released runtime shell from an explicit catalog
  root. It never searches PATH, HOME, or the network, never invokes a compiler
  or linker, and never treats the host CPU/OS as a special emission path
  (ADR-0015). HostTargetTriple only names the default `--target` value; every
  request, including that default, goes through ResolveShell.

  The catalog is a text index (`catalog`) beside the shell files it names.
  Each entry binds a released triple, the compiler version, arch/os/format,
  a catalog-relative file, and an FNV-1a-64 checksum of those bytes. Missing,
  duplicate, stale, mismatched, or corrupt entries fail before any compile
  output. Packaged shells themselves are not required to be in-tree: tests
  and later packagers supply a catalog root.

  STRUCTURAL ONLY. This unit does not decode wasm, emit machine code, or
  attach a payload. ABI layout descriptors belong to the target-ABI work;
  ELF/Mach-O packaging and `wasmlight compile` consume this selection. }
unit Wasm.Compile.Catalog;

{$I Shared.inc}

interface

uses
  Wasm.Core;

const
  { File name of the catalog index inside a catalog root. }
  SHELL_CATALOG_FILENAME = 'catalog';

  { First token of a well-formed catalog. }
  SHELL_CATALOG_MAGIC = 'WASMLIGHT-SHELL-CATALOG';

  { Catalog text format. Bump only for a layout this reader must reject. }
  SHELL_CATALOG_FORMAT = 1;

  { Number of triples the current compiler release may emit. }
  RELEASED_TARGET_COUNT = 4;

type
  TWasmTargetArch = (
    wtaUnknown,
    wtaAArch64,
    wtaX64
  );

  TWasmTargetOs = (
    wtoUnknown,
    wtoLinux,
    wtoDarwin
  );

  TWasmShellFormat = (
    wsfUnknown,
    wsfElf,
    wsfMachO
  );

  { Released 0.2.0 compile targets. Later Windows triples are not in this
    set: an unknown triple fails closed rather than being inferred. }
  TWasmTargetId = (
    wtiNone,
    wtiAArch64Linux,
    wtiX64Linux,
    wtiAArch64Darwin,
    wtiX64Darwin
  );

  TWasmShellEntry = record
    Target: TWasmTargetId;
    Triple: string;
    Version: string;
    Arch: TWasmTargetArch;
    Os: TWasmTargetOs;
    Format: TWasmShellFormat;
    FileName: string;
    Checksum: UInt64;
    ShellPath: string;
  end;
  TWasmShellEntries = array of TWasmShellEntry;

  TWasmShellCatalog = record
    Root: string;
    FormatVersion: Integer;
    Entries: TWasmShellEntries;
  end;

  TWasmShellLoadResult = (
    slrOk,
    slrMissingCatalog,
    slrCorruptCatalog,
    slrDuplicateTarget
  );

  TWasmShellSelectResult = (
    ssrOk,
    ssrUnknownTarget,
    ssrMissingShell,
    ssrDuplicateShell,
    ssrStaleShell,
    ssrMismatchedShell,
    ssrCorruptCatalog,
    ssrCorruptShell
  );

{ Released triple at 0..RELEASED_TARGET_COUNT-1. }
function ReleasedTargetId(const AIndex: Integer): TWasmTargetId;
function TargetTriple(const AId: TWasmTargetId): string;
function ParseTargetTriple(const ATriple: string;
  out AId: TWasmTargetId): Boolean;

{ Host triple when the compiler host is itself a released target; otherwise
  empty. This is the default `--target` spelling, not a selection bypass. }
function HostTargetId: TWasmTargetId;
function HostTargetTriple: string;

function TargetArchName(const AArch: TWasmTargetArch): string;
function TargetOsName(const AOs: TWasmTargetOs): string;
function ShellFormatName(const AFormat: TWasmShellFormat): string;

{ `<compiler-dir>/shells`. The CLI supplies ParamStr(0); tests pass a fixture. }
function CompilerCatalogRoot(const ACompilerPath: string): string;

{ FNV-1a-64 of the shell bytes — a corruption guard, not authentication.
  Same algorithm and offset basis as the `.waot` self-checksum. }
function ShellChecksum(const AData: PByte; const ALen: NativeUInt): UInt64;
function ShellChecksumBytes(const ABytes: TWasmBytes): UInt64;
function ChecksumToHex(const AValue: UInt64): string;

function WriteShellCatalogText(const AEntries: TWasmShellEntries): string;
function ParseShellCatalogText(const AText: string;
  out ACatalog: TWasmShellCatalog): TWasmShellLoadResult;
function LoadShellCatalog(const ARoot: string;
  out ACatalog: TWasmShellCatalog): TWasmShellLoadResult;

{ True iff the catalog lists each released target exactly once at
  PROGRAM_VERSION. Extra or unknown entries make it fail. }
function CatalogCoversRelease(const ACatalog: TWasmShellCatalog): Boolean;

function SelectShell(const ACatalog: TWasmShellCatalog; const ATriple: string;
  out AEntry: TWasmShellEntry): TWasmShellSelectResult;

{ Load then select. An empty triple uses HostTargetTriple. }
function ResolveShell(const ACatalogRoot, ATriple: string;
  out AEntry: TWasmShellEntry): TWasmShellSelectResult;

function FormatSelectError(const AResult: TWasmShellSelectResult;
  const ATriple: string): string;

implementation

uses
  Classes,
  SysUtils;

const
  FNV64_OFFSET = UInt64($CBF29CE484222325);
  FNV64_PRIME = UInt64($00000100000001B3);

  RELEASED_TARGETS: array[0..RELEASED_TARGET_COUNT - 1] of TWasmTargetId = (
    wtiAArch64Linux,
    wtiX64Linux,
    wtiAArch64Darwin,
    wtiX64Darwin
  );

procedure ClearEntry(out AEntry: TWasmShellEntry);
begin
  AEntry.Target := wtiNone;
  AEntry.Triple := '';
  AEntry.Version := '';
  AEntry.Arch := wtaUnknown;
  AEntry.Os := wtoUnknown;
  AEntry.Format := wsfUnknown;
  AEntry.FileName := '';
  AEntry.Checksum := 0;
  AEntry.ShellPath := '';
end;

procedure ClearCatalog(out ACatalog: TWasmShellCatalog);
begin
  ACatalog.Root := '';
  ACatalog.FormatVersion := 0;
  ACatalog.Entries := nil;
end;

function ReleasedTargetId(const AIndex: Integer): TWasmTargetId;
begin
  if (AIndex < 0) or (AIndex >= RELEASED_TARGET_COUNT) then
    Result := wtiNone
  else
    Result := RELEASED_TARGETS[AIndex];
end;

function TargetTriple(const AId: TWasmTargetId): string;
begin
  case AId of
    wtiAArch64Linux: Result := 'aarch64-linux';
    wtiX64Linux: Result := 'x86_64-linux';
    wtiAArch64Darwin: Result := 'aarch64-darwin';
    wtiX64Darwin: Result := 'x86_64-darwin';
  else
    Result := '';
  end;
end;

function ParseTargetTriple(const ATriple: string;
  out AId: TWasmTargetId): Boolean;
var
  I: Integer;
  Candidate: TWasmTargetId;
begin
  AId := wtiNone;
  Result := False;
  if ATriple = '' then
    Exit;
  for I := 0 to RELEASED_TARGET_COUNT - 1 do
  begin
    Candidate := RELEASED_TARGETS[I];
    if ATriple = TargetTriple(Candidate) then
    begin
      AId := Candidate;
      Exit(True);
    end;
  end;
end;

function HostTargetId: TWasmTargetId;
begin
  Result := wtiNone;
{$IF DEFINED(CPUAARCH64) AND DEFINED(DARWIN)}
  Result := wtiAArch64Darwin;
{$ELSEIF DEFINED(CPUX86_64) AND DEFINED(DARWIN)}
  Result := wtiX64Darwin;
{$ELSEIF DEFINED(CPUAARCH64) AND DEFINED(LINUX)}
  Result := wtiAArch64Linux;
{$ELSEIF DEFINED(CPUX86_64) AND DEFINED(LINUX)}
  Result := wtiX64Linux;
{$ENDIF}
end;

function HostTargetTriple: string;
begin
  Result := TargetTriple(HostTargetId);
end;

function TargetArchName(const AArch: TWasmTargetArch): string;
begin
  case AArch of
    wtaAArch64: Result := 'aarch64';
    wtaX64: Result := 'x86_64';
  else
    Result := '';
  end;
end;

function TargetOsName(const AOs: TWasmTargetOs): string;
begin
  case AOs of
    wtoLinux: Result := 'linux';
    wtoDarwin: Result := 'darwin';
  else
    Result := '';
  end;
end;

function ShellFormatName(const AFormat: TWasmShellFormat): string;
begin
  case AFormat of
    wsfElf: Result := 'elf';
    wsfMachO: Result := 'macho';
  else
    Result := '';
  end;
end;

function ExpectedArch(const AId: TWasmTargetId): TWasmTargetArch;
begin
  case AId of
    wtiAArch64Linux, wtiAArch64Darwin: Result := wtaAArch64;
    wtiX64Linux, wtiX64Darwin: Result := wtaX64;
  else
    Result := wtaUnknown;
  end;
end;

function ExpectedOs(const AId: TWasmTargetId): TWasmTargetOs;
begin
  case AId of
    wtiAArch64Linux, wtiX64Linux: Result := wtoLinux;
    wtiAArch64Darwin, wtiX64Darwin: Result := wtoDarwin;
  else
    Result := wtoUnknown;
  end;
end;

function ExpectedFormat(const AId: TWasmTargetId): TWasmShellFormat;
begin
  case AId of
    wtiAArch64Linux, wtiX64Linux: Result := wsfElf;
    wtiAArch64Darwin, wtiX64Darwin: Result := wsfMachO;
  else
    Result := wsfUnknown;
  end;
end;

function ParseArchName(const AName: string; out AArch: TWasmTargetArch): Boolean;
begin
  if AName = 'aarch64' then
  begin
    AArch := wtaAArch64;
    Exit(True);
  end;
  if AName = 'x86_64' then
  begin
    AArch := wtaX64;
    Exit(True);
  end;
  AArch := wtaUnknown;
  Result := False;
end;

function ParseOsName(const AName: string; out AOs: TWasmTargetOs): Boolean;
begin
  if AName = 'linux' then
  begin
    AOs := wtoLinux;
    Exit(True);
  end;
  if AName = 'darwin' then
  begin
    AOs := wtoDarwin;
    Exit(True);
  end;
  AOs := wtoUnknown;
  Result := False;
end;

function ParseFormatName(const AName: string;
  out AFormat: TWasmShellFormat): Boolean;
begin
  if AName = 'elf' then
  begin
    AFormat := wsfElf;
    Exit(True);
  end;
  if AName = 'macho' then
  begin
    AFormat := wsfMachO;
    Exit(True);
  end;
  AFormat := wsfUnknown;
  Result := False;
end;

function CompilerCatalogRoot(const ACompilerPath: string): string;
var
  Dir: string;
begin
  Dir := ExtractFileDir(ACompilerPath);
  if Dir = '' then
    Result := 'shells'
  else
    Result := IncludeTrailingPathDelimiter(Dir) + 'shells';
end;

{$push}{$Q-}{$R-}
function ShellChecksum(const AData: PByte; const ALen: NativeUInt): UInt64;
var
  P: PByte;
  I: NativeUInt;
begin
  Result := FNV64_OFFSET;
  P := AData;
  I := 0;
  while I < ALen do
  begin
    Result := Result xor UInt64(P^);
    Result := Result * FNV64_PRIME;
    Inc(P);
    Inc(I);
  end;
end;
{$pop}

function ShellChecksumBytes(const ABytes: TWasmBytes): UInt64;
begin
  if Length(ABytes) = 0 then
    Result := ShellChecksum(nil, 0)
  else
    Result := ShellChecksum(@ABytes[0], NativeUInt(Length(ABytes)));
end;

function HexDigit(const AValue: Byte): Char;
begin
  if AValue < 10 then
    Result := Char(Ord('0') + AValue)
  else
    Result := Char(Ord('a') + AValue - 10);
end;

function ChecksumToHex(const AValue: UInt64): string;
var
  I: Integer;
  Nibble: Byte;
begin
  SetLength(Result, 16);
  for I := 0 to 15 do
  begin
    Nibble := Byte((AValue shr (60 - I * 4)) and $F);
    Result[I + 1] := HexDigit(Nibble);
  end;
end;

function ParseHex64(const AText: string; out AValue: UInt64): Boolean;
var
  I, Digit: Integer;
  Ch: Char;
begin
  AValue := 0;
  Result := False;
  if Length(AText) <> 16 then
    Exit;
  for I := 1 to 16 do
  begin
    Ch := AText[I];
    if (Ch >= '0') and (Ch <= '9') then
      Digit := Ord(Ch) - Ord('0')
    else if (Ch >= 'a') and (Ch <= 'f') then
      Digit := 10 + Ord(Ch) - Ord('a')
    else if (Ch >= 'A') and (Ch <= 'F') then
      Digit := 10 + Ord(Ch) - Ord('A')
    else
      Exit;
    AValue := (AValue shl 4) or UInt64(Digit);
  end;
  Result := True;
end;

function HasPrefix(const ALine, APrefix: string; out ARest: string): Boolean;
var
  PrefixLen: Integer;
begin
  PrefixLen := Length(APrefix);
  Result := (Length(ALine) > PrefixLen) and
    (Copy(ALine, 1, PrefixLen) = APrefix);
  if Result then
    ARest := Copy(ALine, PrefixLen + 1, MaxInt)
  else
    ARest := '';
end;

function FileNameIsContained(const AFileName: string): Boolean;
var
  I, Start: Integer;
  Segment: string;
begin
  Result := False;
  if AFileName = '' then
    Exit;
  if (AFileName[1] = '/') or (AFileName[1] = '\') then
    Exit;
  if (Length(AFileName) >= 2) and (AFileName[2] = ':') then
    Exit;
  Start := 1;
  for I := 1 to Length(AFileName) + 1 do
    if (I > Length(AFileName)) or (AFileName[I] = '/') or
      (AFileName[I] = '\') then
    begin
      if I = Start then
        Exit;
      Segment := Copy(AFileName, Start, I - Start);
      if (Segment = '.') or (Segment = '..') then
        Exit;
      Start := I + 1;
    end;
  Result := True;
end;

function ResolveContainedPath(const ARoot, AFileName: string): string;
var
  Normalized: string;
  I: Integer;
begin
  Normalized := AFileName;
  for I := 1 to Length(Normalized) do
    if Normalized[I] = '/' then
      Normalized[I] := PathDelim;
  Result := IncludeTrailingPathDelimiter(ARoot) + Normalized;
end;

function EntryMetadataMatches(const AEntry: TWasmShellEntry): Boolean;
begin
  Result := (AEntry.Target <> wtiNone) and
    (AEntry.Triple = TargetTriple(AEntry.Target)) and
    (AEntry.Arch = ExpectedArch(AEntry.Target)) and
    (AEntry.Os = ExpectedOs(AEntry.Target)) and
    (AEntry.Format = ExpectedFormat(AEntry.Target)) and
    FileNameIsContained(AEntry.FileName);
end;

function WriteShellCatalogText(const AEntries: TWasmShellEntries): string;
var
  I: Integer;
  Entry: TWasmShellEntry;
begin
  Result := SHELL_CATALOG_MAGIC + ' ' + IntToStr(SHELL_CATALOG_FORMAT) + #10;
  for I := 0 to High(AEntries) do
  begin
    Entry := AEntries[I];
    if I > 0 then
      Result := Result + #10;
    Result := Result + 'target ' + Entry.Triple + #10;
    Result := Result + 'version ' + Entry.Version + #10;
    Result := Result + 'arch ' + TargetArchName(Entry.Arch) + #10;
    Result := Result + 'os ' + TargetOsName(Entry.Os) + #10;
    Result := Result + 'format ' + ShellFormatName(Entry.Format) + #10;
    Result := Result + 'file ' + Entry.FileName + #10;
    Result := Result + 'checksum ' + ChecksumToHex(Entry.Checksum) + #10;
  end;
end;

function SplitLines(const AText: string): TStringList;
var
  I: Integer;
  Line: string;
  Ch: Char;
begin
  Result := TStringList.Create;
  Line := '';
  I := 1;
  while I <= Length(AText) do
  begin
    Ch := AText[I];
    if Ch = #10 then
    begin
      Result.Add(Line);
      Line := '';
    end
    else if Ch <> #13 then
      Line := Line + Ch;
    Inc(I);
  end;
  if Line <> '' then
    Result.Add(Line);
end;

function ParseFieldLine(const ALine, AKey: string; out AValue: string): Boolean;
begin
  Result := HasPrefix(ALine, AKey + ' ', AValue) and (AValue <> '');
end;

function ParseOneEntry(const ALines: TStringList; var AIndex: Integer;
  out AEntry: TWasmShellEntry): Boolean;
var
  Triple, Version, ArchName, OsName, FormatName, FileName, ChecksumHex: string;
  Target: TWasmTargetId;
  Arch: TWasmTargetArch;
  Os: TWasmTargetOs;
  Format: TWasmShellFormat;
  Checksum: UInt64;
begin
  ClearEntry(AEntry);
  Result := False;
  if AIndex + 6 > ALines.Count - 1 then
    Exit;
  if not ParseFieldLine(ALines[AIndex], 'target', Triple) then
    Exit;
  if not ParseFieldLine(ALines[AIndex + 1], 'version', Version) then
    Exit;
  if not ParseFieldLine(ALines[AIndex + 2], 'arch', ArchName) then
    Exit;
  if not ParseFieldLine(ALines[AIndex + 3], 'os', OsName) then
    Exit;
  if not ParseFieldLine(ALines[AIndex + 4], 'format', FormatName) then
    Exit;
  if not ParseFieldLine(ALines[AIndex + 5], 'file', FileName) then
    Exit;
  if not ParseFieldLine(ALines[AIndex + 6], 'checksum', ChecksumHex) then
    Exit;
  if not ParseTargetTriple(Triple, Target) then
    Exit;
  if not ParseArchName(ArchName, Arch) then
    Exit;
  if not ParseOsName(OsName, Os) then
    Exit;
  if not ParseFormatName(FormatName, Format) then
    Exit;
  if not ParseHex64(ChecksumHex, Checksum) then
    Exit;
  AEntry.Target := Target;
  AEntry.Triple := Triple;
  AEntry.Version := Version;
  AEntry.Arch := Arch;
  AEntry.Os := Os;
  AEntry.Format := Format;
  AEntry.FileName := FileName;
  AEntry.Checksum := Checksum;
  if not EntryMetadataMatches(AEntry) then
  begin
    ClearEntry(AEntry);
    Exit;
  end;
  AIndex := AIndex + 7;
  Result := True;
end;

function CatalogHasDuplicate(const AEntries: TWasmShellEntries): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  for I := 0 to High(AEntries) do
    for J := I + 1 to High(AEntries) do
      if AEntries[I].Target = AEntries[J].Target then
        Exit(True);
end;

function FinishParsedCatalog(var ACatalog: TWasmShellCatalog): TWasmShellLoadResult;
var
  I: Integer;
begin
  if CatalogHasDuplicate(ACatalog.Entries) then
  begin
    ClearCatalog(ACatalog);
    Exit(slrDuplicateTarget);
  end;
  if ACatalog.Root <> '' then
    for I := 0 to High(ACatalog.Entries) do
      ACatalog.Entries[I].ShellPath :=
        ResolveContainedPath(ACatalog.Root, ACatalog.Entries[I].FileName);
  Result := slrOk;
end;

function ParseShellCatalogText(const AText: string;
  out ACatalog: TWasmShellCatalog): TWasmShellLoadResult;
var
  Lines: TStringList;
  HeaderRest: string;
  Index, FormatVer, Count: Integer;
  Entry: TWasmShellEntry;
begin
  ClearCatalog(ACatalog);
  if AText = '' then
    Exit(slrCorruptCatalog);
  Lines := SplitLines(AText);
  try
    if Lines.Count = 0 then
      Exit(slrCorruptCatalog);
    if not HasPrefix(Lines[0], SHELL_CATALOG_MAGIC + ' ', HeaderRest) then
      Exit(slrCorruptCatalog);
    FormatVer := StrToIntDef(HeaderRest, -1);
    if FormatVer <> SHELL_CATALOG_FORMAT then
      Exit(slrCorruptCatalog);
    ACatalog.FormatVersion := FormatVer;
    Index := 1;
    Count := 0;
    while Index < Lines.Count do
    begin
      if Lines[Index] = '' then
      begin
        Inc(Index);
        Continue;
      end;
      if not ParseOneEntry(Lines, Index, Entry) then
      begin
        ClearCatalog(ACatalog);
        Exit(slrCorruptCatalog);
      end;
      SetLength(ACatalog.Entries, Count + 1);
      ACatalog.Entries[Count] := Entry;
      Inc(Count);
    end;
    Result := FinishParsedCatalog(ACatalog);
  finally
    Lines.Free;
  end;
end;

function TryReadAllBytes(const APath: string; out ABytes: TWasmBytes): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  ABytes := nil;
  if not FileExists(APath) then
    Exit;
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on EStreamError do
      Exit;
  end;
  try
    SetLength(ABytes, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(ABytes[0], Stream.Size);
    Result := True;
  finally
    Stream.Free;
  end;
end;

function BytesToText(const ABytes: TWasmBytes): string;
var
  I: Integer;
begin
  SetLength(Result, Length(ABytes));
  for I := 0 to High(ABytes) do
    Result[I + 1] := Char(ABytes[I]);
end;

function LoadShellCatalog(const ARoot: string;
  out ACatalog: TWasmShellCatalog): TWasmShellLoadResult;
var
  CatalogPath: string;
  Bytes_: TWasmBytes;
begin
  ClearCatalog(ACatalog);
  if ARoot = '' then
    Exit(slrMissingCatalog);
  CatalogPath := IncludeTrailingPathDelimiter(ARoot) + SHELL_CATALOG_FILENAME;
  if not FileExists(CatalogPath) then
    Exit(slrMissingCatalog);
  if not TryReadAllBytes(CatalogPath, Bytes_) then
    Exit(slrCorruptCatalog);
  Result := ParseShellCatalogText(BytesToText(Bytes_), ACatalog);
  if Result = slrOk then
    ACatalog.Root := ARoot;
  if Result = slrOk then
    Result := FinishParsedCatalog(ACatalog);
end;

function CatalogCoversRelease(const ACatalog: TWasmShellCatalog): Boolean;
var
  Seen: array[TWasmTargetId] of Boolean;
  I: Integer;
  Id: TWasmTargetId;
begin
  Result := False;
  if Length(ACatalog.Entries) <> RELEASED_TARGET_COUNT then
    Exit;
  for Id := Low(TWasmTargetId) to High(TWasmTargetId) do
    Seen[Id] := False;
  for I := 0 to High(ACatalog.Entries) do
  begin
    Id := ACatalog.Entries[I].Target;
    if (Id = wtiNone) or Seen[Id] then
      Exit;
    if ACatalog.Entries[I].Version <> PROGRAM_VERSION then
      Exit;
    if not EntryMetadataMatches(ACatalog.Entries[I]) then
      Exit;
    Seen[Id] := True;
  end;
  for I := 0 to RELEASED_TARGET_COUNT - 1 do
    if not Seen[RELEASED_TARGETS[I]] then
      Exit;
  Result := True;
end;

function FindTargetMatches(const ACatalog: TWasmShellCatalog;
  const AId: TWasmTargetId; out AFirst: TWasmShellEntry;
  out ACount: Integer): Boolean;
var
  I: Integer;
begin
  ClearEntry(AFirst);
  ACount := 0;
  Result := False;
  for I := 0 to High(ACatalog.Entries) do
    if ACatalog.Entries[I].Target = AId then
    begin
      if ACount = 0 then
        AFirst := ACatalog.Entries[I];
      Inc(ACount);
    end;
  Result := ACount > 0;
end;

function VerifyShellFile(const AEntry: TWasmShellEntry): TWasmShellSelectResult;
var
  Bytes_: TWasmBytes;
begin
  if AEntry.ShellPath = '' then
    Exit(ssrMissingShell);
  if not TryReadAllBytes(AEntry.ShellPath, Bytes_) then
    Exit(ssrMissingShell);
  if ShellChecksumBytes(Bytes_) <> AEntry.Checksum then
    Exit(ssrCorruptShell);
  Result := ssrOk;
end;

function SelectShell(const ACatalog: TWasmShellCatalog; const ATriple: string;
  out AEntry: TWasmShellEntry): TWasmShellSelectResult;
var
  Target: TWasmTargetId;
  Count: Integer;
begin
  ClearEntry(AEntry);
  if not ParseTargetTriple(ATriple, Target) then
    Exit(ssrUnknownTarget);
  if not FindTargetMatches(ACatalog, Target, AEntry, Count) then
    Exit(ssrMissingShell);
  if Count > 1 then
  begin
    ClearEntry(AEntry);
    Exit(ssrDuplicateShell);
  end;
  if not EntryMetadataMatches(AEntry) then
  begin
    ClearEntry(AEntry);
    Exit(ssrMismatchedShell);
  end;
  if AEntry.Version <> PROGRAM_VERSION then
    Exit(ssrStaleShell);
  Result := VerifyShellFile(AEntry);
  if Result <> ssrOk then
    ClearEntry(AEntry);
end;

function ResolveShell(const ACatalogRoot, ATriple: string;
  out AEntry: TWasmShellEntry): TWasmShellSelectResult;
var
  Triple: string;
  Catalog: TWasmShellCatalog;
  Load: TWasmShellLoadResult;
begin
  ClearEntry(AEntry);
  Triple := ATriple;
  if Triple = '' then
    Triple := HostTargetTriple;
  if not ParseTargetTriple(Triple, AEntry.Target) then
  begin
    ClearEntry(AEntry);
    Exit(ssrUnknownTarget);
  end;
  ClearEntry(AEntry);
  Load := LoadShellCatalog(ACatalogRoot, Catalog);
  case Load of
    slrMissingCatalog:
      Exit(ssrMissingShell);
    slrCorruptCatalog:
      Exit(ssrCorruptCatalog);
    slrDuplicateTarget:
      Exit(ssrDuplicateShell);
  else
    Result := SelectShell(Catalog, Triple, AEntry);
  end;
end;

function FormatSelectError(const AResult: TWasmShellSelectResult;
  const ATriple: string): string;
var
  Shown: string;
begin
  Shown := ATriple;
  if Shown = '' then
    Shown := HostTargetTriple;
  if Shown = '' then
    Shown := '(host)';
  case AResult of
    ssrOk:
      Result := '';
    ssrUnknownTarget:
      Result := 'target: unknown target "' + Shown + '"';
    ssrMissingShell:
      Result := 'target: no runtime shell for "' + Shown + '"';
    ssrDuplicateShell:
      Result := 'target: duplicate runtime shell for "' + Shown + '"';
    ssrStaleShell:
      Result := 'target: stale runtime shell for "' + Shown + '"';
    ssrMismatchedShell:
      Result := 'target: mismatched runtime shell for "' + Shown + '"';
    ssrCorruptCatalog:
      Result := 'target: corrupt shell catalog';
    ssrCorruptShell:
      Result := 'target: corrupt runtime shell for "' + Shown + '"';
  else
    Result := 'target: unknown selection failure';
  end;
end;

end.
