{ wasmlight — the runtime's command-line front end.

  The subcommand registry is the single source of truth for the command
  surface: `--help` renders from it, and docs/tooling.md documents it.
  Flags go through the lwpt `cli` package — no hand-rolled ParamStr loops
  except the documented `run` pre-scan (see AGENTS.md).

  `compile` is registered here so the verb, `--target`, and `--connector`
  exist and fail with structured diagnostics. Native executable emission
  is not shipped until the remaining ADR-0015 stages land. }
program wasmlight;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Subcommands,

  Wasm.Aot,
  Wasm.Aot.Artifact,
  Wasm.Compile,
  Wasm.Compile.Capabilities,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Engine,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Run,
  Wasm.Runtime.Store,
  Wasm.Validator,
  Wasm.Wasi;

function ErrPrefix(const ASubcommand: string): string; inline;
begin
  Result := PROGRAM_NAME + ' ' + ASubcommand + ': ';
end;

{ --- byte file IO (aot artifacts) --------------------------------------- }

{ Write ABytes verbatim to APath (the `.waot` writer's output; the artifact is
  a fixed-width binary blob, so it goes out byte-for-byte). Raises on an IO
  error, which the `aot` command reports as a failure. }
procedure WriteBytesToFile(const APath: string; const ABytes: TWasmBytes);
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

{ Read APath into ABytes. Returns False (never raises) when the file is absent
  or unreadable — the `run` path treats that as "no artifact" and falls back to
  the interpreter transparently, so a missing sibling `.waot` is never an error. }
function TryReadBytesFromFile(const APath: string;
  out ABytes: TWasmBytes): Boolean;
var
  Stream: TFileStream;
begin
  ABytes := nil;
  Result := False;
  if not FileExists(APath) then
    Exit;
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(ABytes, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(ABytes[0], Stream.Size);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    on E: EStreamError do
    begin
      ABytes := nil;
      Result := False;
    end;
  end;
end;

{ The human-readable name of an AOT target-arch id (Wasm.Aot.Artifact). }
function AotArchName(const AArch: Byte): string;
begin
  case AArch of
    WAOT_ARCH_AARCH64: Result := 'aarch64';
    WAOT_ARCH_X64: Result := 'x86-64';
  else
    Result := 'unknown';
  end;
end;

{ --- inspect ------------------------------------------------------------- }

{ Right-pad to at least AWidth. Format's `%-20s` is a MINIMUM width, so a
  long name (a custom section renders as `custom "<name>"`, and names are
  arbitrary) pushes the following columns right on that row alone. The
  name column is therefore measured before anything is printed. }
function PadRight(const AText: string; const AWidth: Integer): string;
begin
  Result := AText;
  while Length(Result) < AWidth do
    Result := Result + ' ';
end;

procedure PrintSections(const AModule: TWasmModule; const APath: string);
const
  MIN_NAME_WIDTH = 20;
var
  I, NameWidth: Integer;
  Section: TWasmSectionInfo;
begin
  WriteLn(APath, ': WebAssembly module, binary version ', AModule.Version,
    ', ', AModule.Size, ' bytes, ', AModule.SectionCount, ' section(s)');

  if AModule.SectionCount = 0 then
    Exit;

  NameWidth := MIN_NAME_WIDTH;
  for I := 0 to AModule.SectionCount - 1 do
    if Length(AModule[I].DisplayName) > NameWidth then
      NameWidth := Length(AModule[I].DisplayName);

  WriteLn;
  WriteLn(PadRight('SECTION', NameWidth),
    Format(' %10s %10s', ['OFFSET', 'SIZE']));
  for I := 0 to AModule.SectionCount - 1 do
  begin
    Section := AModule[I];
    WriteLn(PadRight(Section.DisplayName, NameWidth),
      Format(' %10u %10u', [Section.BodyOffset, Section.BodySize]));
  end;
end;

{ The decoded model in one glance: entity counts per index space, plus
  the two optional scalars (start function, data count) when present.
  Imports break down by kind because the kind decides which index space
  each one occupies — the counts here and the sections table above are
  the same module seen at two altitudes. }
procedure PrintEntitySummary(const AModule: TWasmModule);
const
  LABEL_WIDTH = 20;

  procedure CountLine(const ALabel: string; const ACount: Integer);
  begin
    WriteLn(PadRight(ALabel, LABEL_WIDTH), Format(' %10d', [ACount]));
  end;

begin
  WriteLn;
  CountLine('types (rec groups)', AModule.TypeCount);
  WriteLn(PadRight('imports', LABEL_WIDTH),
    Format(' %10d', [AModule.ImportCount]),
    Format('  (func %d, table %d, memory %d, global %d, tag %d)',
      [AModule.ImportCountOfKind(wxkFunc),
       AModule.ImportCountOfKind(wxkTable),
       AModule.ImportCountOfKind(wxkMem),
       AModule.ImportCountOfKind(wxkGlobal),
       AModule.ImportCountOfKind(wxkTag)]));
  CountLine('functions', AModule.FunctionTypeIndexCount);
  CountLine('tables', AModule.TableCount);
  CountLine('memories', AModule.MemoryCount);
  CountLine('globals', AModule.GlobalCount);
  CountLine('exports', AModule.ExportCount);
  CountLine('elements', AModule.ElementCount);
  CountLine('code entries', AModule.CodeEntryCount);
  CountLine('data segments', AModule.DataSegmentCount);
  CountLine('tags', AModule.TagCount);
  if AModule.HasStart then
    WriteLn(PadRight('start function', LABEL_WIDTH),
      Format(' %10u', [AModule.StartFuncIndex]));
  if AModule.HasDataCount then
    WriteLn(PadRight('data count', LABEL_WIDTH),
      Format(' %10u', [AModule.DataCount]));
end;

function HandleInspect(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Module: TWasmModule;
  Bytes: TWasmBytes;
  I: Integer;
begin
  if APositionals.Count < 1 then
  begin
    WriteLn(ErrOutput, ErrPrefix('inspect'), 'expected at least one <module.wasm>');
    Exit(1);
  end;

  Result := 0;
  Module := TWasmModule.Create;
  try
    for I := 0 to APositionals.Count - 1 do
    begin
      if I > 0 then
        WriteLn;
      try
        DecodeModuleFile(APositionals[I], Module, Bytes);
        PrintSections(Module, APositionals[I]);
        PrintEntitySummary(Module);
      except
        on E: EWasmError do
        begin
          WriteLn(ErrOutput, ErrPrefix('inspect'), E.Message);
          Result := 1;
        end;
      end;
    end;
  finally
    Module.Free;
  end;
end;

{ --- validate ------------------------------------------------------------ }

{ Decode, then validate. The two are separate commands because they answer
  separate questions and fail with separate error classes: `inspect`
  reports what the bytes ARE, `validate` reports whether they are a
  well-typed module (AGENTS.md's error hierarchy — a decode error means
  the bytes are not a module, a validation error means they are a module
  that is not well-typed). The class name is printed alongside the message
  so the distinction survives the trip to a shell.

  Success prints one line. The IR format version is on it because ADR-0007
  makes it the thing an ahead-of-time artifact is rejected against, so it
  is worth being able to read off a build without a debugger. The line is
  pure ASCII deliberately: it goes to a terminal whose encoding the
  program does not control, and a mojibake em-dash in the one line most
  users ever see is not worth the typography.

  TWO handlers, and the outer one is the point. EWasmError is the expected
  failure and gets the module-qualified report. Anything else — an
  EAccessViolation, an ERangeError, an EOutOfMemory from a hostile module
  — is a wasmlight BUG, but an unhandled exception leaves the RTL to abort
  with exit code 217 and a raw runtime-error dump, which is unreadable and
  indistinguishable from a crash. The outer handler turns that into a
  named error on stderr and exit 1. It fixes nothing: it makes the failure
  reportable. }
function HandleValidate(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Module: TWasmModule;
  Bytes: TWasmBytes;
  Ir: TWasmIrModule;
  I: Integer;
begin
  if APositionals.Count < 1 then
  begin
    WriteLn(ErrOutput, ErrPrefix('validate'),
      'expected at least one <module.wasm>');
    Exit(1);
  end;

  Result := 0;
  Module := TWasmModule.Create;
  try
    for I := 0 to APositionals.Count - 1 do
    begin
      Ir := nil;
      try
        try
          DecodeModuleFile(APositionals[I], Module, Bytes);
          Ir := ValidateModule(Module, Bytes);
          WriteLn(APositionals[I], ': valid - ', Length(Ir.Functions),
            ' function(s) lowered, ', Module.TotalFunctionCount,
            ' in the function index space, IR format version ',
            Ir.FormatVersion);
        except
          on E: EWasmError do
          begin
            WriteLn(ErrOutput, ErrPrefix('validate'), APositionals[I],
              ': ', E.ClassName, ': ', E.Message);
            Result := 1;
          end;
          on E: Exception do
          begin
            WriteLn(ErrOutput, ErrPrefix('validate'), APositionals[I],
              ': internal error: ', E.ClassName, ': ', E.Message);
            Result := 1;
          end;
        end;
      finally
        { In the finally, not after the except: an outer handler that
          re-raised, or a future `Exit` inside the loop, would otherwise
          leak the IR module. }
        FreeAndNil(Ir);
      end;
    end;
  finally
    Module.Free;
  end;
end;

{ --- aot ----------------------------------------------------------------- }

{ `wasmlight aot <module.wasm> [-o <artifact.waot>]` — compile every compilable
  function of a module AHEAD OF TIME into a `.waot` artifact for instant startup
  (aot-spec §3, §7 Wave 5). It decode+validates the module (the same error
  classes as `validate` — a module that does not decode or validate is not
  compilable and the command exits non-zero, never a stale artifact), then drives
  the HOST backend over every function (JitCanCompile decides; declined functions
  are recorded and run interpreted at load), and writes the fixed-width artifact.

  The artifact is ARCH-SPECIFIC: it carries the host CPU's machine code and is
  rejected by `run` on a different CPU (a transparent fall-back, never a wrong
  run). -o names the output; omitted, it defaults to a sibling `<module>.waot`. }
function HandleAot(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  OutputOpt: TStringOption;
  ModulePath, OutPath: string;
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Artifact: TWasmBytes;
  Parsed: TWasmAotArtifact;
  Compiled, Declined, I: Integer;
begin
  if APositionals.Count < 1 then
  begin
    WriteLn(ErrOutput, ErrPrefix('aot'), 'expected <module.wasm>');
    Exit(1);
  end;
  ModulePath := APositionals[0];

  OutputOpt := TStringOption(AOptions[0]);
  if OutputOpt.Present and (OutputOpt.Value <> '') then
    OutPath := OutputOpt.Value
  else
    OutPath := ChangeFileExt(ModulePath, '.waot');

  Loaded := nil;
  Engine := nil;
  Store := nil;
  try
    try
      { Decode + validate on the source bytes — the same trust boundary a load
        re-runs. EWasmDecodeError vs EWasmValidationError stay distinct, exactly
        as `validate` reports them. }
      Loaded := LoadModuleFromFile(ModulePath);
    except
      on E: EWasmError do
      begin
        WriteLn(ErrOutput, ErrPrefix('aot'), ModulePath, ': ', E.ClassName,
          ': ', E.Message);
        Exit(1);
      end;
      on E: Exception do
      begin
        WriteLn(ErrOutput, ErrPrefix('aot'), ModulePath, ': internal error: ',
          E.ClassName, ': ', E.Message);
        Exit(1);
      end;
    end;

    { A store supplies the record-layout offsets the code bakes; it need not be
      instantiated, and no interpreter/JIT need be registered just to stage. }
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Artifact := AotCompileModule(Store, Loaded);

    try
      WriteBytesToFile(OutPath, Artifact);
    except
      on E: EStreamError do
      begin
        WriteLn(ErrOutput, ErrPrefix('aot'), 'cannot write "', OutPath, '": ',
          E.Message);
        Exit(1);
      end;
    end;

    { Re-parse the written bytes to report the truth of what was compiled
      (a function can be declined LATE by the backend, invisible to a pre-count).
      A well-formed artifact we just wrote always parses. }
    Compiled := 0;
    Declined := 0;
    if ParseAotArtifact(Artifact, Parsed) = aprOk then
      for I := 0 to High(Parsed.Funcs) do
        if Parsed.Funcs[I].Compiled then
          Inc(Compiled)
        else
          Inc(Declined);

    WriteLn(OutPath, ': aot artifact for ', AotArchName(AotHostArch), ', ',
      Compiled, '/', Compiled + Declined, ' function(s) compiled (', Declined,
      ' declined), IR format version ', Loaded.Ir.FormatVersion, ', ',
      Length(Artifact), ' bytes');
    Result := 0;
  finally
    FreeAndNil(Store);
    Engine.Free;
    Loaded.Free;
  end;
end;

{ --- compile ------------------------------------------------------------- }

{ `wasmlight compile <module.wasm> -o <executable> [--target T]
  [--connector F.wlc]...` — the native-application command (ADR-0015).
  Parsing is entirely the lwpt cli package: `-o`, `--target`, and
  repeatable `--connector` are registry options, and `compile --help`
  renders from them. The heavy lifting lives in Wasm.Compile so it is
  hermetically unit-testable; this handler only maps the parsed options
  onto that core and prints the diagnostic. There is no ParamStr
  pre-scan and no silent fallback to `.waot`, the JIT, or the
  interpreter. }
function HandleCompile(const APositionals: TStringList;
  const AOptions: TOptionArray): Integer;
var
  Res: TWasmCompileResult;
begin
  Res := CompileFromOptions(APositionals, AOptions);
  if Res.Diagnostic <> '' then
    WriteLn(ErrOutput, ErrPrefix('compile'), Res.Diagnostic);
  Result := Res.ExitCode;
end;

{ --- run ----------------------------------------------------------------- }

{ `wasmlight run [--dir GUEST=HOST]... [--env KEY=VALUE]... <module.wasm>
  [args...]` — decode + validate a WASI preview1 command, wire it to the
  wasi_snapshot_preview1 host module under a deny-by-default capability set, run
  `_start`, and map the guest's exit to a process code. The heavy lifting lives
  in Wasm.Run so it is hermetically unit-testable (Wasm.Run.Test injects
  capturing streams); this file only parses the flags, wires the REAL process
  stdio, and forwards.

  The flag parse is a hand-rolled ParamStr scan rather than the cli parser, and
  that is a DELIBERATE extension of the one documented CLI exception already in
  this file (the top-level help/unknown-command handling). embedding-spec.md §4.2
  records why: lwpt's CLI.Parser has no `--` terminator and rejects any unknown
  long flag, so a flag-shaped GUEST argument (`app.wasm --verbose`) would choke
  wasmlight's own parser before the module ran. The scan below consumes
  wasmlight's own --dir/--env (into their real cli TRepeatableOption objects, so
  the registry still owns them and `run --help` renders from them), takes the
  first positional as the module path, and captures everything after it — and
  everything after a bare `--` — as opaque guest argv that never reaches the cli
  parser. }

{ Split one --dir GUEST=HOST spec and add it as a preopen. Deny-by-default: the
  only filesystem the guest reaches is a directory the user named here. }
function AddDirPreopen(const AConfig: TWasmWasiConfig; const ASpec: string;
  out AError: string): Boolean;
var
  GuestPath, HostPath: string;
begin
  if not TryParseCompiledDirSpec(ASpec, GuestPath, HostPath, AError) then
    Exit(False);
  AConfig.AddPreopenDir(GuestPath, HostPath, WASM_RUN_DIR_RIGHTS);
  Result := True;
end;

{ The ParamStr pre-scan (embedding-spec.md §4.2). Applies --dir/--env to their
  option objects, sets AModulePath to the first positional, and fills AGuestArgs
  with every token after the module (and after a bare `--`) verbatim. Returns
  False with AError on a bad/unknown wasmlight option; sets AWantsHelp when a
  leading --help/-h is seen (before the module — a --help AFTER the module is a
  guest argument). }
function ParseRunArgs(const ADirOpt, AEnvOpt: TRepeatableOption;
  out AModulePath: string; const AGuestArgs: TStringList;
  out AAotPath: string; out ANoAot: Boolean;
  out AWantsHelp: Boolean; out AError: string): Boolean;
var
  I, EqPos: Integer;
  Arg, Body, Name, Value: string;
  HasEquals, SepSeen, ModuleFound: Boolean;
begin
  AModulePath := '';
  AAotPath := '';
  ANoAot := False;
  AError := '';
  AWantsHelp := False;
  SepSeen := False;
  ModuleFound := False;

  I := 2;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);

    { The first bare `--` is the option/guest-argv separator: drop it and stop
      wasmlight option parsing. Any later `--` is a real guest argument. }
    if (Arg = '--') and (not SepSeen) then
    begin
      SepSeen := True;
      Inc(I);
      Continue;
    end;

    { Once the module is found, everything is guest argv — including flag-shaped
      tokens, which is the whole point of not routing this through the parser. }
    if ModuleFound then
    begin
      AGuestArgs.Add(Arg);
      Inc(I);
      Continue;
    end;

    if not SepSeen then
    begin
      if (Arg = '--help') or (Arg = '-h') then
      begin
        AWantsHelp := True;
        Exit(True);
      end;
      if Copy(Arg, 1, 2) = '--' then
      begin
        Body := Copy(Arg, 3, MaxInt);
        EqPos := Pos('=', Body);
        if EqPos > 0 then
        begin
          Name := Copy(Body, 1, EqPos - 1);
          Value := Copy(Body, EqPos + 1, MaxInt);
          HasEquals := True;
        end
        else
        begin
          Name := Body;
          Value := '';
          HasEquals := False;
        end;
        { --no-aot is a flag: never load an artifact for this run. }
        if Name = 'no-aot' then
        begin
          ANoAot := True;
          Inc(I);
          Continue;
        end;
        if (Name = 'dir') or (Name = 'env') or (Name = 'aot') then
        begin
          if not HasEquals then
          begin
            if I >= ParamCount then
            begin
              AError := '--' + Name + ' requires a value';
              Exit(False);
            end;
            Inc(I);
            Value := ParamStr(I);
          end;
          if Name = 'dir' then
            ADirOpt.Apply(Value)
          else if Name = 'env' then
            AEnvOpt.Apply(Value)
          else
            { --aot <path>: load THIS artifact (last one wins). The path is
              captured directly here, like the module path — the pre-scan owns
              the wasmlight/guest split (embedding-spec.md §4.2). }
            AAotPath := Value;
          Inc(I);
          Continue;
        end;
        AError := 'unknown option: ' + Arg;
        Exit(False);
      end;
    end;

    { A positional (or the first token after `--`): the module path. }
    AModulePath := Arg;
    ModuleFound := True;
    Inc(I);
  end;

  Result := True;
end;

{ The `run` command. Not dispatched through TSubcommandRegistry.Run (whose
  ParseCommandLine cannot see a `--` terminator or a flag-shaped guest arg);
  invoked directly from the top-level dispatch, reading its --dir/--env option
  objects back out of the registry so they stay the single, registry-owned
  definition that `run --help` renders. }
function RunCommand(const ARegistry: TSubcommandRegistry): Integer;
var
  Sub: TSubcommand;
  DirOpt, EnvOpt: TRepeatableOption;
  GuestArgs: TStringList;
  ModulePath, ErrMsg: string;
  WantsHelp: Boolean;
  Config: TWasmWasiConfig;
  OsIn: TWasmWasiOsInStream;
  OsOut, OsErr: TWasmWasiOsOutStream;
  Argv: array of string;
  RunRes: TWasmRunResult;
  I: Integer;
  AotPath, SiblingPath, AotNote: string;
  NoAot, AotExplicit: Boolean;
  ArtifactBytes: TWasmBytes;
begin
  Sub := ARegistry.Find('run');
  DirOpt := TRepeatableOption(Sub.Options[0]);
  EnvOpt := TRepeatableOption(Sub.Options[1]);

  GuestArgs := TStringList.Create;
  try
    if not ParseRunArgs(DirOpt, EnvOpt, ModulePath, GuestArgs, AotPath, NoAot,
      WantsHelp, ErrMsg) then
    begin
      WriteLn(ErrOutput, ErrPrefix('run'), ErrMsg);
      Exit(1);
    end;

    if WantsHelp then
    begin
      ARegistry.PrintSubcommandHelp(PROGRAM_NAME, Sub);
      Exit(0);
    end;

    if ModulePath = '' then
    begin
      WriteLn(ErrOutput, ErrPrefix('run'), 'expected <module.wasm>');
      Exit(1);
    end;

    { Deny-by-default (embedding-spec.md §2.2, §4.3): the config grants stdio +
      clock + random and nothing else; --dir adds exactly the named preopens and
      --env exactly the named vars. The real process fds replace the config's
      default capture buffers (embedding-spec.md §4.5) — these three streams are
      ours to free, since the config frees only what it created. }
    Config := TWasmWasiConfig.Create;
    OsIn := TWasmWasiOsInStream.Create(StdInputHandle);
    OsOut := TWasmWasiOsOutStream.Create(StdOutputHandle);
    OsErr := TWasmWasiOsOutStream.Create(StdErrorHandle);
    try
      Config.Stdin := OsIn;
      Config.Stdout := OsOut;
      Config.Stderr := OsErr;

      { argv[0] = the module basename with extension (embedding-spec.md §4.4),
        then the forwarded guest args. }
      SetLength(Argv, 1 + GuestArgs.Count);
      Argv[0] := ExtractFileName(ModulePath);
      for I := 0 to GuestArgs.Count - 1 do
        Argv[I + 1] := GuestArgs[I];
      Config.SetArgv(Argv);

      for I := 0 to DirOpt.Values.Count - 1 do
        if not AddDirPreopen(Config, DirOpt.Values[I], ErrMsg) then
        begin
          WriteLn(ErrOutput, ErrPrefix('run'), ErrMsg);
          Exit(1);
        end;
      for I := 0 to EnvOpt.Values.Count - 1 do
        Config.AddEnv(EnvOpt.Values[I]);

      { Resolve the optional AOT artifact (aot-spec §4, §8). --no-aot suppresses
        it entirely. An explicit --aot names the artifact; otherwise a sibling
        `<module>.waot` is auto-detected if present. A missing/unreadable
        artifact is NEVER fatal — the module always decode+validates and runs,
        AOT only saves the compile. The module is re-validated by Wasm.Run
        regardless of the artifact (the security oracle); the artifact only
        supplies pre-compiled code that is re-checked against that validation. }
      ArtifactBytes := nil;
      AotNote := '';
      AotExplicit := AotPath <> '';
      if not NoAot then
      begin
        if AotExplicit then
        begin
          if not TryReadBytesFromFile(AotPath, ArtifactBytes) then
            AotNote := 'aot: cannot read artifact "' + AotPath
              + '", running interpreted';
        end
        else
        begin
          SiblingPath := ChangeFileExt(ModulePath, '.waot');
          if FileExists(SiblingPath) then
            TryReadBytesFromFile(SiblingPath, ArtifactBytes);
        end;
      end;

      RunRes := RunConfiguredModuleAot(ModulePath, Config, ArtifactBytes);
      { Diagnostics go to stderr, never stdout — stdout is the guest's
        (embedding-spec.md §6). }
      if RunRes.Diagnostic <> '' then
        WriteLn(ErrOutput, ErrPrefix('run'), RunRes.Diagnostic);
      { The AOT note is verbose feedback: printed only when the user OPTED IN
        with an explicit --aot (so they asked to know whether the cache loaded),
        never for a silent sibling auto-detect, keeping ordinary `run` output
        clean. It never affects the exit code. }
      if AotExplicit then
      begin
        if AotNote <> '' then
          WriteLn(ErrOutput, ErrPrefix('run'), AotNote)
        else if RunRes.AotStatus <> '' then
          WriteLn(ErrOutput, ErrPrefix('run'), RunRes.AotStatus);
      end;
      Result := RunRes.ExitCode;
    finally
      Config.Free;
      OsIn.Free;
      OsOut.Free;
      OsErr.Free;
    end;
  finally
    GuestArgs.Free;
  end;
end;

{ --- top-level flags ----------------------------------------------------- }

{ The cli package's PrintTopLevelHelp hardcodes lwpt's own tagline
  ("lightweight Pascal toolkit") and gives a consumer no way to override
  it, so top-level help is rendered here instead. The command list is
  still read from the live registry — the registry stays the single source
  of truth for the command surface, only the banner is ours. }
procedure PrintTopLevelHelp(const ARegistry: TSubcommandRegistry);
var
  I: Integer;
  Sub: TSubcommand;
begin
  WriteLn(PROGRAM_NAME, ' — WebAssembly runtime for Object Pascal');
  WriteLn;
  WriteLn('usage: ', PROGRAM_NAME, ' <command> [options]');
  WriteLn;
  WriteLn('commands:');
  for I := 0 to ARegistry.Count - 1 do
  begin
    Sub := ARegistry.Item(I);
    WriteLn('  ', Sub.Name:10, '  ', Sub.Summary);
  end;
  WriteLn;
  WriteLn('run "', PROGRAM_NAME, ' <command> --help" for command options');
end;

function WantsVersion: Boolean;
var
  A: string;
begin
  { Only the first token. Scanning the whole argv would steal a
    flag-shaped compile/aot value such as `-o -v`. `run` already
    excludes itself; compile has no guest argv and uses the registry. }
  Result := False;
  if ParamCount < 1 then
    Exit;
  A := LowerCase(ParamStr(1));
  Result := (A = '--version') or (A = '-v') or (A = 'version');
end;

{ True when argv asks for top-level help: no arguments at all, or the
  first argument is a help request. A `--help` AFTER a subcommand name is
  that subcommand's help, which the registry handles. }
function WantsTopLevelHelp: Boolean;
var
  A: string;
begin
  if ParamCount < 1 then
    Exit(True);
  A := LowerCase(ParamStr(1));
  Result := (A = 'help') or (A = '--help') or (A = '-h');
end;

{ True when the first argument is the `run` command word — used to keep the
  version scan from swallowing a guest `-v`, since after the module every token
  is the guest's (embedding-spec.md §4.2). }
function IsRunCommand: Boolean;
begin
  Result := (ParamCount >= 1) and (LowerCase(ParamStr(1)) = 'run');
end;

{ --- registration -------------------------------------------------------- }
var
  Registry: TSubcommandRegistry;
  InspectOpts, ValidateOpts, RunOpts, AotOpts, CompileOpts: TOptionArray;
  AotOutputOpt: TStringOption;
  CompileOutputOpt, CompileTargetOpt: TStringOption;
  CompileConnectorOpt: TRepeatableOption;
begin
  { A `run` invocation forwards its own argv tail to the guest, where `-v` is a
    guest flag, not a request for wasmlight's version. }
  if WantsVersion and not IsRunCommand then
  begin
    WriteLn(PROGRAM_NAME, ' ', PROGRAM_VERSION);
    ExitCode := 0;
    Exit;
  end;

  Registry := TSubcommandRegistry.Create;
  try
    SetLength(InspectOpts, 0);
    Registry.Add(TSubcommand.Create('inspect',
      'Decode a module and report its sections and entity counts',
      '<module.wasm> [<module.wasm>...]',
      @HandleInspect, InspectOpts));

    SetLength(ValidateOpts, 0);
    Registry.Add(TSubcommand.Create('validate',
      'Decode and validate a module, reporting the lowered IR',
      '<module.wasm> [<module.wasm>...]',
      @HandleValidate, ValidateOpts));

    { `aot` compiles the module ahead of time into a `.waot` artifact for instant
      startup (aot-spec §3). -o/--output names the artifact; omitted, a sibling
      `<module>.waot`. A normal subcommand — dispatched through Registry.Run. }
    SetLength(AotOpts, 1);
    AotOutputOpt := TStringOption.Create('output',
      'write the artifact to this path (default: <module>.waot)');
    AotOutputOpt.ShortName := 'o';
    AotOpts[0] := AotOutputOpt;
    Registry.Add(TSubcommand.Create('aot',
      'Ahead-of-time compile a module to a .waot artifact for instant startup',
      '<module.wasm> [-o <artifact.waot>]',
      @HandleAot, AotOpts));

    { `compile` is the native-executable command (ADR-0015). Options are
      created by Wasm.Compile so `compile --help` and the unit suite share
      one definition. Backend stages still fail with structured errors
      until sibling work lands; the command never falls back to `.waot`. }
    CompileOpts := CreateCompileOptions(CompileOutputOpt, CompileTargetOpt,
      CompileConnectorOpt);
    Registry.Add(TSubcommand.Create('compile',
      'Compile a module to a native executable (strict; no interpreter fallback)',
      '<module.wasm> -o <executable> [--target <triple>] [--connector <file.wlc>]...',
      @HandleCompile, CompileOpts));

    { --dir and --env are repeatable and are the ONLY host capabilities `run`
      grants beyond stdio (deny-by-default). --aot/--no-aot select the optional
      AOT artifact (parsed by RunCommand's own pre-scan, but declared here so
      `run --help` documents them and the registry stays the source of truth).
      The registry owns these option objects; RunCommand reads --dir/--env back
      out of it. RunCommand is dispatched directly (below), not via Registry.Run,
      so its guest-argv pre-scan can see the whole tail. }
    SetLength(RunOpts, 4);
    RunOpts[0] := TRepeatableOption.Create('dir',
      'grant a preopened directory as GUEST=HOST (repeatable)');
    RunOpts[1] := TRepeatableOption.Create('env',
      'set an environment variable KEY=VALUE (repeatable)');
    RunOpts[2] := TStringOption.Create('aot',
      'load a precompiled .waot artifact for instant startup (falls back if stale)');
    RunOpts[3] := TFlagOption.Create('no-aot',
      'never load a .waot artifact; always interpret (disables sibling auto-detect)');
    Registry.Add(TSubcommand.Create('run',
      'Run a WASI preview1 command module (_start) to a process exit code',
      '[--dir GUEST=HOST]... [--env KEY=VALUE]... [--aot <artifact.waot>] '
      + '[--no-aot] <module.wasm> [args...]',
      nil, RunOpts));

    if WantsTopLevelHelp then
    begin
      PrintTopLevelHelp(Registry);
      ExitCode := 0;
    end
    else if IsRunCommand then
      { Dispatched directly, not through Registry.Run: the run handler needs to
        pre-scan the whole argv tail for guest argv (embedding-spec.md §4.2),
        which the registry's ParseCommandLine — no `--` terminator, rejects
        unknown long flags — cannot do. }
      ExitCode := RunCommand(Registry)
    else if Registry.Find(LowerCase(ParamStr(1))) = nil then
    begin
      { Handled here rather than in the registry for the same reason as
        the help banner: the registry's own miss path prints lwpt's
        tagline. }
      WriteLn(ErrOutput, PROGRAM_NAME, ': unknown command: ', ParamStr(1));
      PrintTopLevelHelp(Registry);
      ExitCode := 1;
    end
    else
      ExitCode := Registry.Run(PROGRAM_NAME);
  finally
    Registry.Free;
  end;
end.
