{ wasmspec — runs `.wast` conformance scripts and reports the verdicts.

  The external judge (docs/testing.md): the upstream WebAssembly testsuite
  is fetched, never vendored, and this program is what points it at the
  layers this project has shipped. Wasm.Wast parses the scripts,
  Wasm.Wast.Runner judges the commands it can judge, and everything here
  is argument handling and reporting.

  WHAT A RUN MEANS TODAY. The interpreter tier is wired in (Track E), so
  `(module binary ...)` cases now decode, validate, INSTANTIATE, and run:
  top-level modules, `assert_malformed`/`assert_invalid`, and the action
  and result assertions (`assert_return`, `assert_trap`,
  `assert_exhaustion`, `invoke`, `register`, `get`). There is still no
  text-format assembler, so the overwhelming majority of the corpus — which
  spells its modules in the text format — is SKIPPED with a reason until
  that lands (Track C). The skip column is never folded into the totals: a
  report from this program must not read as more conformance than was
  actually measured.

  OUTPUT IS ONE LINE PER FACT, on stdout, in a fixed leading-token shape
  (`FAIL`, `STAGED`, `SKIP`, `PASS`, `FILE`, `TOTAL`, `ERROR`) so a run
  over hundreds of files can be sorted, counted, and diffed with the
  shell. The failure line carries both strings: running the corpus is
  what settled the validator's message prefixes against upstream, and the
  expected/actual pair IS that evidence — and the guard against drift.

  EXIT CODE is 0 only when nothing failed and every file could be read
  and parsed. Staged cases and skips do not fail a run; a script that
  cannot be parsed does, because it means the harness could not do its
  job.

  Flags go through the lwpt `cli` package — no hand-rolled ParamStr loops
  (AGENTS.md). }
program wasmspec;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Parser,
  CLI.Help,

  Wasm.Core,
  Wasm.Wast,
  Wasm.Wast.Runner;

const
  TOOL_NAME = 'wasmspec';
  WAST_EXTENSION = '.wast';

  { The class field of an ERROR line when a positional argument named
    nothing on disk. There is no exception to name, but the ERROR shape
    keeps the class in a fixed position (see PrintError). }
  ERR_UNRESOLVED_ARGUMENT = 'unresolved-argument';

{ --- reporting ----------------------------------------------------------- }

{ A message rendered inside double quotes on a single line. Our own
  messages are plain one-line ASCII, but the corpus feeds arbitrary bytes
  in and a message could quote them back, so the two characters that
  would break the line format are escaped rather than assumed absent. }
function Quoted(const AText: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '"';
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
    else
      Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

{ An operational failure — a file that could not be read or parsed, or an
  argument that named nothing — never a conformance result. One field
  shape, so a run's ERROR lines are as greppable as its FAIL lines:

    ERROR <path> <class> <quoted-detail>

  <class> is the class of the exception that stopped the file, or the
  sentinel ERR_UNRESOLVED_ARGUMENT when a positional resolved to nothing;
  <detail> is the exception message or the reason, always quoted. }
procedure PrintError(const APath, AClass, ADetail: string);
begin
  WriteLn('ERROR ', APath, ' ', AClass, ' ', Quoted(ADetail));
end;

function ResultLocation(const APath: string;
  const AResult: TWastCommandResult): string;
begin
  Result := APath + ':' + IntToStr(AResult.Line) + ' '
    + WastCommandKindName(AResult.Kind);
end;

procedure PrintResult(const APath: string;
  const AResult: TWastCommandResult);
begin
  case AResult.Status of
    wrsPass:
      WriteLn('PASS ', ResultLocation(APath, AResult));
    wrsSkip:
      WriteLn('SKIP ', ResultLocation(APath, AResult),
        ' reason=', Quoted(AResult.Actual));
    wrsStaged:
      WriteLn('STAGED ', ResultLocation(APath, AResult),
        ' got=', WastErrorKindName(AResult.ActualKind),
        ' expected=', Quoted(AResult.Expected),
        ' actual=', Quoted(AResult.Actual));
  else
    WriteLn('FAIL ', ResultLocation(APath, AResult),
      ' got=', WastErrorKindName(AResult.ActualKind),
      ' expected=', Quoted(AResult.Expected),
      ' actual=', Quoted(AResult.Actual));
  end;
end;

function TallyText(const ATally: TWastTally): string;
begin
  Result := Format('pass=%d fail=%d skip=%d staged=%d total=%d',
    [ATally.Pass, ATally.Fail, ATally.Skip, ATally.Staged, ATally.Total]);
end;

{ --- input collection ---------------------------------------------------- }

function HasWastExtension(const APath: string): Boolean;
begin
  Result := SameText(ExtractFileExt(APath), WAST_EXTENSION);
end;

{ Every `.wast` under ADirectory, recursively. The corpus keeps its
  proposal corpora in subdirectories, so a caller pointing at the checkout
  root means all of them. }
procedure CollectDirectory(const ADirectory: string;
  const AInto: TStringList);
var
  Search: TSearchRec;
  Path: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*', faAnyFile,
    Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      Path := IncludeTrailingPathDelimiter(ADirectory) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
        CollectDirectory(Path, AInto)
      else if HasWastExtension(Path) then
        AInto.Add(Path);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

{ Expand one argument into scripts. A directory contributes its whole
  tree; a file is taken as given, extension or not, because naming a file
  explicitly is an instruction, not a guess. Returns False when the
  argument names nothing. }
function CollectArgument(const APath: string;
  const AInto: TStringList): Boolean;
begin
  Result := True;
  if DirectoryExists(APath) then
    CollectDirectory(APath, AInto)
  else if FileExists(APath) then
    AInto.Add(APath)
  else
    Result := False;
end;

{ --- one script ---------------------------------------------------------- }

{ Run one script and report it. Returns its tally; AErrors is incremented
  when the file could not be read or parsed, which is an operational
  failure rather than a conformance result and so is never folded into the
  pass/fail columns. }
function RunOne(const APath: string; const AMode: TWastTierMode;
  const AShowPass, AShowSkip, AShowStaged, AShowFileLine: Boolean;
  var AErrors, ACompiled: Integer): TWastTally;
var
  Run: TWastRunResult;
  Item: TWastCommandResult;
  I: Integer;
begin
  Result.Clear;
  Run := nil;
  try
    try
      Run := RunWastFile(APath, AMode);
    except
      { EWastParseError for script text, EWasmDecodeError for an
        unreadable file, and a bare Exception guard so one bad file cannot
        abandon a run over hundreds of them. }
      on E: Exception do
      begin
        PrintError(APath, E.ClassName, E.Message);
        Inc(AErrors);
        Exit;
      end;
    end;

    for I := 0 to Run.Count - 1 do
    begin
      Item := Run[I];
      case Item.Status of
        wrsFail: PrintResult(APath, Item);
        wrsStaged: if AShowStaged then PrintResult(APath, Item);
        wrsSkip: if AShowSkip then PrintResult(APath, Item);
        wrsPass: if AShowPass then PrintResult(APath, Item);
      end;
    end;

    Result := Run.Tally;
    Inc(ACompiled, Run.CompiledFuncCount);
    if AShowFileLine then
      WriteLn('FILE ', APath, ' ', TallyText(Result));
  finally
    Run.Free;
  end;
end;

{ --- entry point --------------------------------------------------------- }

{ Options and their descriptions come from the registered option array
  through lwpt's GenerateHelpText, so the help can never disagree with the
  flags the parser accepts. (The AGENTS.md carve-out is about
  PrintTopLevelHelp's hardcoded tagline, which GenerateHelpText does not
  impose.) The banner and the closing note are ours, ASCII-only to match
  the one-line output format. }
procedure PrintUsage(const AOptions: TOptionArray);
begin
  WriteLn(TOOL_NAME, ' ', PROGRAM_VERSION,
    ' - run .wast conformance scripts');
  WriteLn;
  Write(GenerateHelpText(TOOL_NAME, '[options] <script.wast|directory>...',
    AOptions));
  WriteLn;
  WriteLn('Only (module binary ...) cases are judged: modules decode, validate,');
  WriteLn('and run (assert_return/assert_trap/assert_exhaustion/invoke). Text-format');
  WriteLn('modules still need the assembler and are reported as SKIP. Exit code is 0');
  WriteLn('only when nothing failed and every script could be read and parsed.');
end;

{ The corpus keeps its proposal corpora under a `proposals/` directory; the
  3.0-draft root (ADR-0004's conformance target) is everything else. Splitting
  the tally on that path segment keeps post-3.0 proposal noise from being read
  as core-conformance movement. }
function IsProposalScript(const APath: string): Boolean;
begin
  Result := Pos(PathDelim + 'proposals' + PathDelim, APath) > 0;
end;

var
  Options: TOptionList;
  VerboseOpt, FailuresOnlyOpt, HelpOpt: TFlagOption;
  TierOpt: TStringOption;
  Positionals, Scripts: TStringList;
  Verbose, FailuresOnly: Boolean;
  ShowPass, ShowSkip, ShowStaged, ShowFileLine: Boolean;
  Mode: TWastTierMode;
  Total, Root, Proposals, FileTally: TWastTally;
  Errors, Compiled, I: Integer;
begin
  Options := TOptionList.Create;
  Positionals := nil;
  Scripts := nil;
  try
    VerboseOpt := Options.AddFlag('verbose',
      'One line per command, including passes and skips');
    FailuresOnlyOpt := Options.AddFlag('failures-only',
      'Only failure lines and the totals');
    { The tier the corpus runs under (jit-spec §11, §12.3). interp is the tier
      of record and the default — omitting the flag leaves every number exactly
      as before. jit registers the baseline JIT and force-compiles every
      compilable function, turning the corpus into the JIT's conformance net:
      the tally MUST match an interp run, or a compiled function diverged. }
    TierOpt := Options.AddString('tier',
      'Execution tier: interp (default) or jit');
    HelpOpt := Options.AddFlag('help', 'Show usage');

    try
      Positionals := ParseCommandLine(Options.Options);
    except
      on E: TParseError do
      begin
        WriteLn(ErrOutput, TOOL_NAME, ': ', E.Message);
        ExitCode := 1;
        Exit;
      end;
    end;

    if HelpOpt.Present then
    begin
      PrintUsage(Options.Options);
      ExitCode := 0;
      Exit;
    end;

    if Positionals.Count = 0 then
    begin
      WriteLn(ErrOutput, TOOL_NAME,
        ': expected at least one <script.wast|directory>');
      ExitCode := 1;
      Exit;
    end;

    { Resolve the tier. Absent or 'interp' is the interpreter (the default and
      the tier of record); 'jit' opts into the baseline JIT. An unrecognised
      value is an operational error, not a silent fall-through to interpreter —
      a run must never claim a tier it did not use. }
    Mode := wtmInterp;
    if TierOpt.Present then
    begin
      if TierOpt.Value = 'jit' then
        Mode := wtmJit
      else if TierOpt.Value = 'interp' then
        Mode := wtmInterp
      else
      begin
        WriteLn(ErrOutput, TOOL_NAME, ': unknown --tier "', TierOpt.Value,
          '" (expected interp or jit)');
        ExitCode := 1;
        Exit;
      end;
    end;

    Verbose := VerboseOpt.Present;
    FailuresOnly := FailuresOnlyOpt.Present;
    { --failures-only wins over --verbose where they disagree: it is the
      narrower request, and a caller passing both is asking for the
      failures. }
    ShowPass := Verbose and not FailuresOnly;
    ShowSkip := Verbose and not FailuresOnly;
    ShowStaged := not FailuresOnly;
    ShowFileLine := not FailuresOnly;

    Scripts := TStringList.Create;
    Errors := 0;
    for I := 0 to Positionals.Count - 1 do
      if not CollectArgument(Positionals[I], Scripts) then
      begin
        PrintError(Positionals[I], ERR_UNRESOLVED_ARGUMENT,
          'no such file or directory');
        Inc(Errors);
      end;
    { Sorted so two runs over the same tree produce comparable output;
      FindFirst order is the filesystem's, not anyone's. }
    Scripts.Sort;

    Total.Clear;
    Root.Clear;
    Proposals.Clear;
    Compiled := 0;
    for I := 0 to Scripts.Count - 1 do
    begin
      FileTally := RunOne(Scripts[I], Mode, ShowPass, ShowSkip, ShowStaged,
        ShowFileLine, Errors, Compiled);
      Total.Add(FileTally);
      if IsProposalScript(Scripts[I]) then
        Proposals.Add(FileTally)
      else
        Root.Add(FileTally);
    end;

    { The 3.0-draft root and the proposal corpora split out, so a run reports
      core-conformance movement apart from post-3.0 proposal coverage. The TOTAL
      line names the tier and, under --tier=jit, how many functions were
      actually compiled — so a run's tier is unambiguous and the JIT is provably
      exercised rather than silently all-interpreted (jit-spec §11.3, §12.3). }
    WriteLn('ROOT ', TallyText(Root));
    WriteLn('PROPOSALS ', TallyText(Proposals));
    WriteLn('TOTAL files=', Scripts.Count, ' errors=', Errors,
      ' tier=', WastTierModeName(Mode), ' compiled=', Compiled, ' ',
      TallyText(Total));

    if (Total.Fail > 0) or (Errors > 0) then
      ExitCode := 1
    else
      ExitCode := 0;
  finally
    Scripts.Free;
    Positionals.Free;
    Options.Free;
  end;
end.
