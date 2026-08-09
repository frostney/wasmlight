{ wasmlight — the runtime's command-line front end.

  The subcommand registry is the single source of truth for the command
  surface: `--help` renders from it, and docs/tooling.md documents it.
  Flags go through the lwpt `cli` package — no hand-rolled ParamStr loops
  (see AGENTS.md).

  Shipped surface today is `inspect` and `validate`. `run` arrives with
  the interpreter tier; until then the command does not exist rather than
  existing and failing, so `--help` never advertises something the binary
  cannot do. }
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

  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator;

function ErrPrefix(const ASubcommand: string): string; inline;
begin
  Result := PROGRAM_NAME + ' ' + ASubcommand + ': ';
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
  I: Integer;
  A: string;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if (A = '--version') or (A = '-v') or (LowerCase(A) = 'version') then
      Exit(True);
  end;
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

{ --- registration -------------------------------------------------------- }
var
  Registry: TSubcommandRegistry;
  InspectOpts, ValidateOpts: TOptionArray;
begin
  if WantsVersion then
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

    if WantsTopLevelHelp then
    begin
      PrintTopLevelHelp(Registry);
      ExitCode := 0;
    end
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
