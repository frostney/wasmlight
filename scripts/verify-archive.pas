#!/usr/bin/env instantfpc
program VerifyArchive;

{ Verify a packed wasmlight host archive: checksums, MANIFEST, catalog
  layout, ELF/Mach-O structure, and — when `wasmlight compile` can emit —
  native execution plus cross-target structural emission. The compile CLI
  is wired before native emission; that stub is deferred, not a pack fault.

  Same-host verification always runs the compiler inside the archive.
  `--compiler` is only a foreign-host fallback (the packed binary cannot
  execute). Cross-emission never executes a foreign binary. That is the
  4-host structural check, not a 16-cell execution matrix. }

{$mode delphi}{$H+}

uses
  Classes,
  Process,
  SysUtils,

  Wasm.Distro;

const
  USAGE =
    'usage: verify-archive --archive FILE --checksums FILE [--version VER] ' +
    '[--compiler PATH] [--require-compile] [--work DIR]';

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
      WriteLn(ErrOutput, 'verify-archive: ', Flag, ' needs a value');
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

function CombinedOutput(const AExe: string; const AArgs: array of string;
  out AText: string; out ACode: Integer): Boolean;
var
  Proc: TProcess;
  Buffer: array[0..4095] of Byte;
  ReadCount: LongInt;
  Chunk: AnsiString;
  I: Integer;
begin
  AText := '';
  ACode := 1;
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for I := 0 to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Options := [poUsePipes, poStderrToOutPut];
    try
      Proc.Execute;
    except
      on E: Exception do
      begin
        AText := E.Message;
        Exit(False);
      end;
    end;
    while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
    begin
      if Proc.Output.NumBytesAvailable > 0 then
      begin
        ReadCount := Proc.Output.Read(Buffer, SizeOf(Buffer));
        SetString(Chunk, PAnsiChar(@Buffer[0]), ReadCount);
        AText := AText + Chunk;
      end
      else
        Sleep(10);
    end;
    ACode := Proc.ExitStatus;
    Result := True;
  finally
    Proc.Free;
  end;
end;

procedure Fail(const AMsg: string);
begin
  WriteLn(ErrOutput, 'verify-archive: ', AMsg);
  Halt(1);
end;

function LoadText(const APath: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function Sha256Of(const APath: string): string;
var
  Output: string;
  Sep: Integer;
begin
  if RunTool('sha256sum', [APath], Output) then
  else if RunTool('shasum', ['-a', '256', APath], Output) then
  else
    Fail('neither sha256sum nor shasum is on PATH');
  Output := Trim(Output);
  Sep := Pos(' ', Output);
  if Sep = 0 then
    Fail('could not parse digest of ' + APath);
  Result := LowerCase(Trim(Copy(Output, 1, Sep - 1)));
end;

function CompilerHasCompile(const ACompiler: string): Boolean;
var
  Text: string;
  Code: Integer;
begin
  if not CombinedOutput(ACompiler, ['--help'], Text, Code) then
    Exit(False);
  if DistroHelpListsCompile(Text) then
    Exit(True);
  CombinedOutput(ACompiler, ['compile', '--help'], Text, Code);
  Result := (Code = 0) and not DistroUnknownCompileCommand(Text);
end;

procedure VerifyChecksum(const AArchive, AChecksums: string);
var
  Rows: TWasmDistroChecksums;
  Status: TWasmDistroResult;
  I: Integer;
  Base, Digest: string;
  Found: Boolean;
begin
  Status := DistroParseChecksums(LoadText(AChecksums), Rows);
  if not Status.IsOk then
    Fail('checksums: ' + Status.Detail);
  Base := ExtractFileName(AArchive);
  Found := False;
  Digest := Sha256Of(AArchive);
  for I := 0 to High(Rows) do
    if Rows[I].FileName = Base then
    begin
      Found := True;
      if Rows[I].Digest <> Digest then
        Fail('digest mismatch for ' + Base);
    end;
  if not Found then
    Fail(Base + ' is not listed in ' + AChecksums);
end;

procedure VerifyManifestHashes(const ARoot: string;
  const AManifest: TWasmDistroManifest);
var
  I: Integer;
  Digest: string;
begin
  if Length(AManifest.Hashes) = 0 then
    Fail('MANIFEST has no per-file hashes');
  for I := 0 to High(AManifest.Hashes) do
  begin
    Digest := Sha256Of(DistroJoin(ARoot, AManifest.Hashes[I].RelPath));
    if Digest <> AManifest.Hashes[I].Digest then
      Fail('MANIFEST hash mismatch for ' + AManifest.Hashes[I].RelPath);
  end;
  WriteLn('verify-archive: ', Length(AManifest.Hashes), ' MANIFEST file hashes ok');
end;

procedure VerifyNativeCompiler(const ACompiler, AVersion: string);
var
  Output: string;
begin
  if not RunTool(ACompiler, ['--version'], Output) then
    Fail(ACompiler + ' --version failed');
  Output := Trim(Output);
  if Pos(AVersion, Output) = 0 then
    Fail('compiler version "' + Output + '" does not contain ' + AVersion);
end;

procedure WriteEmptyStartModule(const APath: string);
const
  { (module (func (export "_start"))) — no imports, so deny-by-default
    compile linking does not raise EWasmLinkError before the emission stub. }
  WASM: array[0..35] of Byte = (
    $00, $61, $73, $6D, $01, $00, $00, $00,
    $01, $04, $01, $60, $00, $00,
    $03, $02, $01, $00,
    $07, $0A, $01, $06, $5F, $73, $74, $61, $72, $74, $00, $00,
    $0A, $04, $01, $02, $00, $0B
  );
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    Stream.WriteBuffer(WASM[0], Length(WASM));
  finally
    Stream.Free;
  end;
end;

procedure VerifyCompileGates(const ACompiler, AWork: string);
var
  Host: TWasmDistroHost;
  I: Integer;
  Target, OutFile, Text: string;
  Code: Integer;
  Bytes: TBytes;
  Stream: TFileStream;
  Module: string;
begin
  if not DistroCurrentHost(Host) then
    Fail('compile gates need a 0.2.0 Unix host');
  Module := IncludeTrailingPathDelimiter(AWork) + 'empty-start.wasm';
  WriteEmptyStartModule(Module);
  for I := 0 to DISTRO_SHELL_COUNT - 1 do
  begin
    Target := DistroShell(I).Triple;
    OutFile := IncludeTrailingPathDelimiter(AWork) + 'emit-' + Target;
    if not CombinedOutput(ACompiler,
      ['compile', '--target', Target, '-o', OutFile, Module], Text, Code) then
      Fail('could not invoke compile for ' + Target);
    if Code <> 0 then
    begin
      if DistroCompileEmissionNotShipped(Text) then
      begin
        WriteLn('verify-archive: compile gates deferred (native emission not shipped)');
        Exit;
      end;
      Fail('compile --target ' + Target + ' failed: ' + Trim(Text));
    end;
    if not FileExists(OutFile) then
      Fail('compile --target ' + Target + ' wrote no output');
    Stream := TFileStream.Create(OutFile, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Bytes, Stream.Size);
      if Length(Bytes) > 0 then
        Stream.ReadBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
    if not DistroImageMatchesShell(Bytes, Target) then
      Fail('cross-emission for ' + Target + ' is not the expected image');
    WriteLn('verify-archive: cross-emission structure ok for ', Target);
    if Target = Host.Triple then
    begin
      if not CombinedOutput(OutFile, [], Text, Code) then
        Fail('native compiled program did not start');
      if Code <> 0 then
        Fail('native compiled program exited ' + IntToStr(Code) + ': ' +
          Trim(Text));
      WriteLn('verify-archive: native compile execution ok for ', Target);
    end;
  end;
end;

var
  Archive, Checksums, Version, Compiler, HostCompiler, Work, Output,
    UnpackRoot, CatalogLabel: string;
  RequireCompile: Boolean;
  Status: TWasmDistroResult;
  Manifest: TWasmDistroManifest;
  NativeHost: TWasmDistroHost;
  Lines: TStringList;
begin
  try
    if HasFlag('help') or HasFlag('h') then
    begin
      WriteLn(USAGE);
      Halt(0);
    end;
    if not ArgValue('archive', Archive) then
    begin
      WriteLn(ErrOutput, USAGE);
      Halt(2);
    end;
    if not ArgValue('checksums', Checksums) then
    begin
      WriteLn(ErrOutput, USAGE);
      Halt(2);
    end;
    if not FileExists(Archive) then
      Fail('archive not found: ' + Archive);
    if not FileExists(Checksums) then
      Fail('checksums not found: ' + Checksums);
    Archive := ExpandFileName(Archive);
    Checksums := ExpandFileName(Checksums);
    ArgValue('version', Version);
    ArgValue('compiler', HostCompiler);
    if HostCompiler <> '' then
      HostCompiler := ExpandFileName(HostCompiler);
    RequireCompile := HasFlag('require-compile');
    Randomize;
    if not ArgValue('work', Work) then
      Work := IncludeTrailingPathDelimiter(GetTempDir) +
        'wasmlight-verify-' + IntToHex(Random(MaxInt), 8)
    else
      Work := ExpandFileName(Work);
    ForceDirectories(Work);

    VerifyChecksum(Archive, Checksums);
    WriteLn('verify-archive: checksum ok for ', ExtractFileName(Archive));

    UnpackRoot := IncludeTrailingPathDelimiter(Work) + 'unpacked';
    ForceDirectories(UnpackRoot);
    if not RunTool('tar', ['-C', UnpackRoot, '-xzf', Archive], Output) then
      Fail('tar extract failed: ' + Output);
    UnpackRoot := IncludeTrailingPathDelimiter(UnpackRoot) +
      ChangeFileExt(ExtractFileName(Archive), '');
    if ExtractFileExt(UnpackRoot) = '.tar' then
      UnpackRoot := ChangeFileExt(UnpackRoot, '');
    if not DirectoryExists(UnpackRoot) then
      Fail('archive did not contain ' + ExtractFileName(UnpackRoot));

    Status := DistroValidateTree(UnpackRoot, Version);
    if not Status.IsOk then
      Fail('tree: ' + Status.Detail + ' (' + IntToStr(Ord(Status.Status)) + ')');
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(DistroJoin(UnpackRoot, DISTRO_MANIFEST_NAME));
      Status := DistroParseManifest(Lines.Text, Manifest);
      if not Status.IsOk then
        Fail('manifest: ' + Status.Detail);
    finally
      Lines.Free;
    end;
    if Manifest.Catalog = wdcLive then
      CatalogLabel := 'live'
    else
      CatalogLabel := 'fixture';
    WriteLn('verify-archive: manifest version=', Manifest.Version,
      ' host=', Manifest.HostTriple, ' catalog=', CatalogLabel);
    VerifyManifestHashes(UnpackRoot, Manifest);

    { The packed binary is what a download installs. A `--compiler`
      override would let a broken archive pass against the workspace
      build, so same-host checks always use the unpacked compiler. }
    Compiler := DistroJoin(UnpackRoot, DISTRO_COMPILER_NAME);
    if DistroCurrentHost(NativeHost) and (NativeHost.Triple = Manifest.HostTriple) then
      VerifyNativeCompiler(Compiler, Manifest.Version)
    else if HostCompiler <> '' then
    begin
      Compiler := HostCompiler;
      VerifyNativeCompiler(Compiler, Manifest.Version);
    end
    else
      WriteLn('verify-archive: skipped native --version (foreign host archive)');

    if CompilerHasCompile(Compiler) then
      VerifyCompileGates(Compiler, Work)
    else if RequireCompile then
      Fail('compile subcommand is required but not present')
    else
      WriteLn('verify-archive: compile gates deferred (compile not shipped)');

    WriteLn('verify-archive: ok');
  except
    on E: Exception do
      Fail(E.Message);
  end;
end.
