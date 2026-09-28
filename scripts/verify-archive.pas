#!/usr/bin/env instantfpc
program VerifyArchive;

{ Verify a packed wasmlight host archive: checksums, MANIFEST, catalog
  layout, ELF/Mach-O structure, and — on the archive's own host — the
  packed compiler's version and compile gates.

  The compile gates run the compiler inside the archive against its own
  catalog. For each shell it carries (the host architecture for Linux and
  macOS) it compiles a probe that exits 37, checks the image and its
  native payload are that target's and bound to the archive shell, and
  executes only the host-native output. The other-OS output is checked
  structurally, never executed: four host legs, not a 16-cell execution
  matrix. A foreign-architecture target must be refused (#148 owns
  cross-architecture emission).

  On a foreign host the packed compiler cannot run, so only the archive
  structure is verified; `--require-compile` then fails rather than pass
  unverified. `--complete-set` also requires the checksums file to list
  exactly the four host archives of the manifest version. }

{$mode delphi}{$H+}

uses
  Classes,
  Process,
  SysUtils,

  Wasm.Compile.Catalog,
  Wasm.Core,
  Wasm.Distro,
  Wasm.Shell;

const
  USAGE =
    'usage: verify-archive --archive FILE --checksums FILE [--version VER] ' +
    '[--require-compile] [--complete-set] [--work DIR]';

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
    { ExitStatus is the raw wait status on Unix: the exit code lives in bits
      8..15 only when the low 7 bits (the terminating signal) are zero. A
      signal death is reported as 128 + signal, never as a clean exit. }
    if (Proc.ExitStatus and $7F) = 0 then
      ACode := (Proc.ExitStatus shr 8) and $FF
    else
      ACode := 128 + (Proc.ExitStatus and $7F);
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

function LoadChecksums(const AChecksums: string): TWasmDistroChecksums;
var
  Status: TWasmDistroResult;
begin
  Status := DistroParseChecksums(LoadText(AChecksums), Result);
  if not Status.IsOk then
    Fail('checksums: ' + Status.Detail);
end;

procedure VerifyChecksum(const AArchive, AChecksums: string);
var
  Rows: TWasmDistroChecksums;
  I: Integer;
  Base, Digest: string;
  Found: Boolean;
begin
  Rows := LoadChecksums(AChecksums);
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
  I, J, Count: Integer;
  Digest: string;

  procedure RequireFile(const APath: string);
  var
    Index: Integer;
  begin
    for Index := 0 to High(AManifest.Files) do
      if AManifest.Files[Index] = APath then
        Exit;
    Fail('MANIFEST does not cover required file ' + APath);
  end;

begin
  RequireFile(DISTRO_COMPILER_NAME);
  RequireFile(DISTRO_SHELL_ROOT + '/' + SHELL_CATALOG_FILENAME);
  for I := 0 to High(AManifest.Shells) do
  begin
    RequireFile(DistroShellRelPath(AManifest.Shells[I]));
    RequireFile(DistroMetaRelPath(AManifest.Shells[I]));
  end;
  for I := 0 to High(AManifest.Files) do
  begin
    Count := 0;
    for J := 0 to High(AManifest.Hashes) do
      if AManifest.Hashes[J].RelPath = AManifest.Files[I] then
        Inc(Count);
    if Count <> 1 then
      Fail('MANIFEST needs exactly one hash for ' + AManifest.Files[I]);
  end;
  if Length(AManifest.Hashes) <> Length(AManifest.Files) then
    Fail('MANIFEST hash coverage differs from its file list');
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
  if Output <> 'wasmlight ' + AVersion then
    Fail('compiler version "' + Output + '" does not match wasmlight ' + AVersion);
end;

procedure WriteProbeModule(const APath: string);
const
  { proc_exit(37) proves the packaged shell ran the embedded command;
    an exit-zero placeholder cannot satisfy this execution check. }
  WASM: array[0..95] of Byte = (
    $00, $61, $73, $6D, $01, $00, $00, $00, $01, $08, $02, $60,
    $01, $7F, $00, $60, $00, $00, $02, $24, $01, $16, $77, $61,
    $73, $69, $5F, $73, $6E, $61, $70, $73, $68, $6F, $74, $5F,
    $70, $72, $65, $76, $69, $65, $77, $31, $09, $70, $72, $6F,
    $63, $5F, $65, $78, $69, $74, $00, $00, $03, $02, $01, $01,
    $05, $03, $01, $00, $01, $07, $13, $02, $06, $6D, $65, $6D,
    $6F, $72, $79, $02, $00, $06, $5F, $73, $74, $61, $72, $74,
    $00, $01, $0A, $08, $01, $06, $00, $41, $25, $10, $00, $0B
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

function ReadFileBytes(const APath: string): TWasmBytes;
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

{ A released target of another architecture must be refused: the archive
  carries no shell for it and this compiler cannot emit it (#148). }
procedure VerifyForeignArchRefused(const ACompiler, AWork, AModule: string;
  const AHost: TWasmDistroHost);
var
  I: Integer;
  Target, OutFile, Text: string;
  Code: Integer;
begin
  for I := 0 to DISTRO_SHELL_COUNT - 1 do
  begin
    Target := DistroShell(I).Triple;
    if DistroHostCarriesShell(AHost, Target) then
      Continue;
    OutFile := IncludeTrailingPathDelimiter(AWork) + 'refused-' + Target;
    if not CombinedOutput(ACompiler,
      ['compile', '--target', Target, '-o', OutFile, AModule], Text, Code) then
      Fail('could not invoke compile for ' + Target);
    if (Code = 0) or FileExists(OutFile) then
      Fail('compile --target ' + Target + ' is outside this archive and must fail');
  end;
  WriteLn('verify-archive: foreign-architecture targets refused');
end;

procedure VerifyCompileGates(const ACompiler, AWork, ARoot: string;
  const AManifest: TWasmDistroManifest);
var
  Host: TWasmDistroHost;
  I: Integer;
  Target, OutFile, Text: string;
  Code: Integer;
  Image, Payload: TWasmBytes;
  Status: TWasmDistroResult;
  Module: string;
begin
  DistroFindHost(AManifest.HostTriple, Host);
  Module := IncludeTrailingPathDelimiter(AWork) + 'native-probe.wasm';
  WriteProbeModule(Module);
  for I := 0 to High(AManifest.Shells) do
  begin
    Target := AManifest.Shells[I];
    OutFile := IncludeTrailingPathDelimiter(AWork) + 'emit-' + Target;
    if not CombinedOutput(ACompiler,
      ['compile', '--target', Target, '-o', OutFile, Module], Text, Code) then
      Fail('could not invoke compile for ' + Target);
    if Code <> 0 then
      Fail('compile --target ' + Target + ' failed: ' + Trim(Text));
    if not FileExists(OutFile) then
      Fail('compile --target ' + Target + ' wrote no output');
    Image := ReadFileBytes(OutFile);
    if not ExtractPackagedPayload(Image, Payload) then
      Fail('compile --target ' + Target + ' output carries no native payload');
    Status := DistroCheckEmission(Image, Payload,
      ReadFileBytes(DistroJoin(ARoot, DistroShellRelPath(Target))), Target);
    if not Status.IsOk then
      Fail('compile --target ' + Target + ': ' + Status.Detail);
    if Target = Host.Triple then
    begin
      if not CombinedOutput(OutFile, [], Text, Code) then
        Fail('native compiled program did not start');
      if Code <> 37 then
        Fail('native compiled program expected exit 37, got ' + IntToStr(Code) + ': ' +
          Trim(Text));
      WriteLn('verify-archive: native compile and execution ok for ', Target);
    end
    else
      WriteLn('verify-archive: cross-OS emission structure ok for ', Target);
  end;
  VerifyForeignArchRefused(ACompiler, AWork, Module, Host);
end;

var
  Archive, Checksums, Version, Compiler, Work, Output, UnpackRoot,
    CatalogLabel: string;
  RequireCompile, CompleteSet: Boolean;
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
    RequireCompile := HasFlag('require-compile');
    CompleteSet := HasFlag('complete-set');
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

    if CompleteSet then
    begin
      Status := DistroChecksumsCoverArchives(Manifest.Version,
        LoadChecksums(Checksums));
      if not Status.IsOk then
        Fail('checksums do not cover the release set: ' + Status.Detail);
      WriteLn('verify-archive: checksums cover all ', DISTRO_HOST_COUNT,
        ' host archives');
    end;

    if RequireCompile and (Manifest.Catalog = wdcFixture) then
      Fail('compile verification requires a live runtime-shell catalog');
    { The packed binary is what a download installs, so the gates always run
      the compiler inside the archive against the catalog beside it. }
    Compiler := DistroJoin(UnpackRoot, DISTRO_COMPILER_NAME);
    if not DistroCurrentHost(NativeHost) or
      (NativeHost.Triple <> Manifest.HostTriple) then
    begin
      if RequireCompile then
        Fail('compile gates must run on the archive''s own host (' +
          Manifest.HostTriple + ')');
      WriteLn('verify-archive: foreign host archive: structure verified; ',
        'compile gates not run here (they need ', Manifest.HostTriple, ')');
    end
    else
    begin
      VerifyNativeCompiler(Compiler, Manifest.Version);
      if Manifest.Catalog = wdcFixture then
        WriteLn('verify-archive: fixture structure verified; native compile is unverified')
      else if CompilerHasCompile(Compiler) then
        VerifyCompileGates(Compiler, Work, UnpackRoot, Manifest)
      else
        Fail('compile subcommand is required for a live archive');
    end;

    WriteLn('verify-archive: ok');
  except
    on E: Exception do
      Fail(E.Message);
  end;
end.
