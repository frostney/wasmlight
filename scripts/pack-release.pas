#!/usr/bin/env instantfpc
program PackRelease;

{ Assemble one host's wasmlight release archive and refresh the sibling
  SHA-256 checksums file. InstantFPC entry: run from the repo root with
  `-Fusource/units -Fisource/units` so Wasm.Distro is visible.

  This writes archives; it does not publish a GitHub release. /create-release
  remains the single publication path. }

{$mode delphi}{$H+}

uses
  Classes,
  Process,
  SysUtils,

  Wasm.Distro;

const
  USAGE =
    'usage: pack-release --compiler PATH --out DIR [--version VER] ' +
    '[--host TRIPLE|DISPLAY] [--catalog DIR] [--synthesize-catalog]';

function ArgValue(const AName: string; out AValue: string): Boolean;
var
  I: Integer;
  Flag: string;
begin
  Result := False;
  AValue := '';
  Flag := '--' + AName;
  for I := 1 to ParamCount do
  begin
    if ParamStr(I) <> Flag then
      Continue;
    if I = ParamCount then
    begin
      WriteLn(ErrOutput, 'pack-release: ', Flag, ' needs a value');
      Halt(2);
    end;
    AValue := ParamStr(I + 1);
    Exit(True);
  end;
end;

function HasFlag(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if ParamStr(I) = '--' + AName then
      Exit(True);
  Result := False;
end;

function RunTool(const AExe: string; const AArgs: array of string;
  out AOutput: string): Boolean;
begin
  Result := RunCommand(AExe, AArgs, AOutput);
end;

function Sha256Of(const APath: string): string;
var
  Output, Line: string;
  Sep: Integer;
begin
  if RunTool('sha256sum', [APath], Output) then
  else if RunTool('shasum', ['-a', '256', APath], Output) then
  else
  begin
    WriteLn(ErrOutput, 'pack-release: neither sha256sum nor shasum is on PATH');
    Halt(1);
  end;
  Line := Trim(Output);
  Sep := Pos(' ', Line);
  if Sep = 0 then
  begin
    WriteLn(ErrOutput, 'pack-release: could not parse digest of ', APath);
    Halt(1);
  end;
  Result := LowerCase(Trim(Copy(Line, 1, Sep - 1)));
end;

function CompilerVersion(const ACompiler: string): string;
var
  Output: string;
  Space: Integer;
begin
  if not RunTool(ACompiler, ['--version'], Output) then
  begin
    WriteLn(ErrOutput, 'pack-release: ', ACompiler, ' --version failed');
    Halt(1);
  end;
  Output := Trim(Output);
  Space := Pos(' ', Output);
  if Space = 0 then
    Result := Output
  else
    Result := Trim(Copy(Output, Space + 1, MaxInt));
end;

procedure CopyFileTo(const ASrc, ADst: string);
var
  Src, Dst: TFileStream;
begin
  ForceDirectories(ExtractFilePath(ADst));
  Src := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(ADst, fmCreate);
    try
      Dst.CopyFrom(Src, 0);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

procedure CopyTree(const ASrc, ADst: string);
var
  Search: TSearchRec;
  ChildSrc, ChildDst: string;
begin
  ForceDirectories(ADst);
  if FindFirst(IncludeTrailingPathDelimiter(ASrc) + '*', faAnyFile, Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      ChildSrc := IncludeTrailingPathDelimiter(ASrc) + Search.Name;
      ChildDst := IncludeTrailingPathDelimiter(ADst) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
        CopyTree(ChildSrc, ChildDst)
      else
        CopyFileTo(ChildSrc, ChildDst);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure AddFile(var AFiles: TStringArray; const ARel: string);
begin
  SetLength(AFiles, Length(AFiles) + 1);
  AFiles[High(AFiles)] := ARel;
end;

procedure MergeChecksums(const APath, AFileName, ADigest: string);
var
  Existing: TStringList;
  Rows: TWasmDistroChecksums;
  Parsed: TWasmDistroResult;
  I: Integer;
  Replaced: Boolean;
begin
  SetLength(Rows, 0);
  if FileExists(APath) then
  begin
    Existing := TStringList.Create;
    try
      Existing.LoadFromFile(APath);
      Parsed := DistroParseChecksums(Existing.Text, Rows);
      if not Parsed.IsOk then
      begin
        WriteLn(ErrOutput, 'pack-release: existing checksums: ', Parsed.Detail);
        Halt(1);
      end;
    finally
      Existing.Free;
    end;
  end;
  Replaced := False;
  for I := 0 to High(Rows) do
    if Rows[I].FileName = AFileName then
    begin
      Rows[I].Digest := ADigest;
      Replaced := True;
    end;
  if not Replaced then
  begin
    SetLength(Rows, Length(Rows) + 1);
    Rows[High(Rows)].FileName := AFileName;
    Rows[High(Rows)].Digest := ADigest;
  end;
  Existing := TStringList.Create;
  try
    Existing.Text := DistroFormatChecksums(Rows);
    Existing.SaveToFile(APath);
  finally
    Existing.Free;
  end;
end;

var
  Compiler, OutDir, Version, HostArg, CatalogDir, Stage, ArchiveBase,
    ArchiveName, ArchivePath, ChecksumsPath, Output, Rel: string;
  Host: TWasmDistroHost;
  Manifest: TWasmDistroManifest;
  I: Integer;
  CatalogKind: TWasmDistroCatalog;
  Status: TWasmDistroResult;
  Lines: TStringList;
begin
  try
    if HasFlag('help') or HasFlag('h') then
    begin
      WriteLn(USAGE);
      Halt(0);
    end;
    if not ArgValue('compiler', Compiler) then
    begin
      WriteLn(ErrOutput, USAGE);
      Halt(2);
    end;
    if not ArgValue('out', OutDir) then
    begin
      WriteLn(ErrOutput, USAGE);
      Halt(2);
    end;
    Randomize;
    if not FileExists(Compiler) then
    begin
      WriteLn(ErrOutput, 'pack-release: compiler not found: ', Compiler);
      Halt(1);
    end;
    if not ArgValue('version', Version) then
      Version := CompilerVersion(Compiler);
    if ArgValue('host', HostArg) then
    begin
      if not DistroFindHost(HostArg, Host) then
      begin
        WriteLn(ErrOutput, 'pack-release: unknown host: ', HostArg);
        Halt(1);
      end;
    end
    else if not DistroCurrentHost(Host) then
    begin
      WriteLn(ErrOutput, 'pack-release: not a 0.2.0 Unix compiler host');
      Halt(1);
    end;

    CatalogKind := wdcLive;
    if ArgValue('catalog', CatalogDir) then
      CatalogKind := wdcLive
    else if HasFlag('synthesize-catalog') then
    begin
      CatalogDir := IncludeTrailingPathDelimiter(GetTempDir) +
        'wasmlight-catalog-' + IntToHex(Random(MaxInt), 8);
      Status := DistroSynthesizeCatalog(CatalogDir);
      if not Status.IsOk then
      begin
        WriteLn(ErrOutput, 'pack-release: ', Status.Detail);
        Halt(1);
      end;
      CatalogKind := wdcFixture;
    end
    else
    begin
      WriteLn(ErrOutput,
        'pack-release: pass --catalog DIR or --synthesize-catalog');
      Halt(2);
    end;

    ForceDirectories(OutDir);
    ArchiveBase := DistroArchiveBase(Version, Host.Display);
    Stage := IncludeTrailingPathDelimiter(OutDir) + ArchiveBase;
    if DirectoryExists(Stage) then
    begin
      { Staging is rebuilt every run so a leftover file cannot leak in. }
      if not RunTool('rm', ['-rf', Stage], Output) then
      begin
        WriteLn(ErrOutput, 'pack-release: could not replace ', Stage);
        Halt(1);
      end;
    end;
    ForceDirectories(Stage);
    CopyFileTo(Compiler, DistroJoin(Stage, DISTRO_COMPILER_NAME));
    RunTool('chmod', ['0755', DistroJoin(Stage, DISTRO_COMPILER_NAME)], Output);
    if DirectoryExists(DistroJoin(CatalogDir, DISTRO_SHELL_ROOT)) then
      CopyTree(DistroJoin(CatalogDir, DISTRO_SHELL_ROOT),
        DistroJoin(Stage, DISTRO_SHELL_ROOT))
    else
      CopyTree(CatalogDir, DistroJoin(Stage, DISTRO_SHELL_ROOT));
    if FileExists('README.md') then
    begin
      CopyFileTo('README.md', DistroJoin(Stage, 'README.md'));
    end;

    Manifest.Version := Version;
    Manifest.HostTriple := Host.Triple;
    Manifest.Display := Host.Display;
    Manifest.Catalog := CatalogKind;
    SetLength(Manifest.Shells, DISTRO_SHELL_COUNT);
    SetLength(Manifest.Files, 0);
    SetLength(Manifest.Hashes, 0);
    AddFile(Manifest.Files, DISTRO_COMPILER_NAME);
    if FileExists(DistroJoin(Stage, 'README.md')) then
      AddFile(Manifest.Files, 'README.md');
    for I := 0 to DISTRO_SHELL_COUNT - 1 do
    begin
      Manifest.Shells[I] := DistroShell(I).Triple;
      AddFile(Manifest.Files, DistroShellRelPath(DistroShell(I).Triple));
      AddFile(Manifest.Files, DistroMetaRelPath(DistroShell(I).Triple));
    end;
    SetLength(Manifest.Hashes, Length(Manifest.Files));
    for I := 0 to High(Manifest.Files) do
    begin
      Rel := Manifest.Files[I];
      Manifest.Hashes[I].RelPath := Rel;
      Manifest.Hashes[I].Digest := Sha256Of(DistroJoin(Stage, Rel));
    end;
    Lines := TStringList.Create;
    try
      Lines.Text := DistroFormatManifest(Manifest);
      Lines.SaveToFile(DistroJoin(Stage, DISTRO_MANIFEST_NAME));
    finally
      Lines.Free;
    end;

    Status := DistroValidateTree(Stage, Version);
    if not Status.IsOk then
    begin
      WriteLn(ErrOutput, 'pack-release: staged tree: ', Status.Detail);
      Halt(1);
    end;

    ArchiveName := DistroArchiveFileName(Version, Host.Display);
    ArchivePath := IncludeTrailingPathDelimiter(OutDir) + ArchiveName;
    if not RunTool('/usr/bin/env', ['COPYFILE_DISABLE=1', 'tar',
      '-C', OutDir, '-czf', ArchivePath, ArchiveBase], Output) then
    begin
      WriteLn(ErrOutput, 'pack-release: tar failed: ', Output);
      Halt(1);
    end;

    ChecksumsPath := IncludeTrailingPathDelimiter(OutDir) +
      DistroChecksumsFileName(Version);
    MergeChecksums(ChecksumsPath, ArchiveName, Sha256Of(ArchivePath));
    WriteLn('pack-release: wrote ', ArchivePath);
    WriteLn('pack-release: updated ', ChecksumsPath);
    if CatalogKind = wdcFixture then
      WriteLn('pack-release: catalog=fixture (structural placeholders, not live shells)');
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'pack-release: ', E.Message);
      Halt(1);
    end;
  end;
end.
