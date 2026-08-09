{ Wasm.Wast.Runner — executes a parsed `.wast` script against the layers
  this project has actually shipped, and reports what it could not judge.

  Track C's runner (docs/roadmap.md). Wasm.Wast is the front end — lexer,
  s-expression parser, command classifier — and deliberately stops there,
  keeping module payloads as raw trees. This unit is what turns those
  trees into verdicts.

  WHAT IS JUDGED TODAY, and why that is the whole list. Decode
  (Wasm.Decoder) and validation (Wasm.Validator) are shipped; there is no
  execution tier and no text-format assembler. So exactly three command
  shapes produce a real verdict, and all three need the module in the
  `(module binary "...")` form:

    - `(module binary ...)` at top level — must decode AND validate
    - `(assert_malformed (module binary ...) "...")` — must raise
      EWasmDecodeError
    - `(assert_invalid (module binary ...) "...")` — must raise
      EWasmValidationError

  Everything else is SKIPPED with a reason, never silently counted as a
  pass and never treated as an error: text and quoted modules (no
  assembler), the action and result assertions (no tier), and the
  testsuite-local directives outside the reference grammar
  (`assert_malformed_custom` and friends, which Wasm.Wast classifies as
  wcUnknown). A skip is an honest "not judged", and the tallies keep it
  apart from a pass so a report cannot read as more coverage than it is.

  LAZY DECODING IS THE POINT. Bytes are assembled and handed to
  DecodeModule inside the command's own execution, not when the script was
  parsed — otherwise `assert_malformed` could not observe the failure it
  exists to observe (docs/roadmap.md, Track C).

  THE MATCH IS A PREFIX MATCH. The reference interpreter checks that the
  script's expected string is a PREFIX of the implementation's message, so
  our error messages are part of conformance rather than diagnostics.
  Wasm.Validator's canonical prefixes carry UNCONFIRMED markers precisely
  because running this corpus is what settles them; a fail here therefore
  records BOTH strings, since the report is the evidence.

  THE STAGED STATUS EXISTS FOR ONE REASON. `$FD` vector validation is
  staged to Track G; the validator flags its "not implemented" message
  through `Wasm.Validator.IsStagedFeatureMessage`, so the harness classifies
  a staged failure with that predicate rather than string-matching a
  validator-internal constant. Vector cases are a large, concentrated slice
  of the corpus, so counting them as failures would bury every real
  divergence under known-absent work. When a case trips that specific
  message and would otherwise fail, it is recorded as STAGED and tallied
  separately — visible, never a pass, and never noise. STAGED is confined
  to results whose error CLASS is the one the assertion wanted, so a
  wrong-class SIMD result is still reported as a failure, never hidden. }
unit Wasm.Wast.Runner;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator,
  Wasm.Wast;

const
  { Skip reasons. Public because they are the honest boundary of what the
    harness can judge, and the tests assert on them rather than on prose
    spelled twice. }
  WAST_REASON_TEXT_FORMAT = 'text format not yet assembled';
  WAST_REASON_NEEDS_TIER = 'needs an execution tier';
  WAST_REASON_UNKNOWN_DIRECTIVE = 'directive not in the reference grammar';
  WAST_REASON_NO_MODULE_OPERAND = 'no module operand';

  { Recorded as the actual outcome when an assertion expected a failure
    and the module went through cleanly. Not a message from any layer —
    the absence of one is the finding. }
  WAST_NO_ERROR = '(no error raised)';

type
  TWastStatus = (
    wrsPass,    { judged, and the outcome matched }
    wrsFail,    { judged, and it did not — Expected and Actual both kept }
    wrsSkip,    { not judged; Actual carries the reason }
    wrsStaged   { would fail, but only on deliberately staged work }
  );

  { Which error class a module attempt produced. The hierarchy is
    load-bearing (AGENTS.md): malformed and invalid are different answers,
    and a harness that collapsed them would pass an implementation that
    rejects the right modules for the wrong reason. wekOther is anything
    that is not one of the two — a bug in this project, reported as a
    failure rather than allowed to abort the run. }
  TWastErrorKind = (
    wekNone,
    wekDecode,
    wekValidation,
    wekOther
  );

  TWastCommandResult = record
    Kind: TWastCommandKind;
    { 1-based line of the command's opening parenthesis. }
    Line: Integer;
    Status: TWastStatus;
    { The script's expected failure string; '' when the command is not an
      assertion. }
    Expected: string;
    { What happened: our message on a fail or a staged case, WAST_NO_ERROR
      when a required failure did not arrive, and the skip reason on a
      skip. }
    Actual: string;
    ActualKind: TWastErrorKind;
  end;

  TWastTally = record
    Pass: Integer;
    Fail: Integer;
    Skip: Integer;
    Staged: Integer;

    procedure Clear;
    procedure Count(const AStatus: TWastStatus);
    procedure Add(const AOther: TWastTally);
    function Total: Integer;
  end;

  { The per-command results of one script, plus their tally. The caller
    owns it. }
  TWastRunResult = class
  private
    FResults: array of TWastCommandResult;
    FCount: Integer;
    FTally: TWastTally;

    function GetResult(const AIndex: Integer): TWastCommandResult;
  public
    constructor Create;

    procedure AddResult(const AResult: TWastCommandResult);
    function Count: Integer;

    property Results[const AIndex: Integer]: TWastCommandResult
      read GetResult; default;
    property Tally: TWastTally read FTally;
  end;

{ Run every command of AScript in order. Never raises for a command
  outcome — a command that cannot be judged is a skip and a command that
  fails is a failure, both recorded. }
function RunWastScript(const AScript: TWastScript): TWastRunResult;

{ Parse ASource and run it. Raises EWastParseError when the SCRIPT itself
  is malformed; that is a harness-input error, not a conformance result,
  so it is not squeezed into a TWastCommandResult. }
function RunWastSource(const ASource: string): TWastRunResult;

{ Read APath and run it. Raises EWasmDecodeError when the file cannot be
  read (LoadFileBytes' contract) and EWastParseError as above. }
function RunWastFile(const APath: string): TWastRunResult;

function WastStatusName(const AStatus: TWastStatus): string;
function WastErrorKindName(const AKind: TWastErrorKind): string;

{ True when AExpected is a prefix of AActual — the reference
  interpreter's rule for failure strings, exposed because it IS the
  conformance criterion and belongs in a test. }
function WastMessageMatches(const AExpected, AActual: string): Boolean;

implementation

{ --- tally --------------------------------------------------------------- }

procedure TWastTally.Clear;
begin
  Pass := 0;
  Fail := 0;
  Skip := 0;
  Staged := 0;
end;

procedure TWastTally.Count(const AStatus: TWastStatus);
begin
  case AStatus of
    wrsPass: Inc(Pass);
    wrsFail: Inc(Fail);
    wrsSkip: Inc(Skip);
    wrsStaged: Inc(Staged);
  end;
end;

procedure TWastTally.Add(const AOther: TWastTally);
begin
  Inc(Pass, AOther.Pass);
  Inc(Fail, AOther.Fail);
  Inc(Skip, AOther.Skip);
  Inc(Staged, AOther.Staged);
end;

function TWastTally.Total: Integer;
begin
  Result := Pass + Fail + Skip + Staged;
end;

{ --- run result ---------------------------------------------------------- }

constructor TWastRunResult.Create;
begin
  inherited Create;
  FCount := 0;
  FTally.Clear;
end;

procedure TWastRunResult.AddResult(const AResult: TWastCommandResult);
begin
  { Growth by doubling. The corpus outliers are two 11,676-line SIMD
    files, so a fresh SetLength per command would copy the whole array
    tens of thousands of times for no reason. }
  if FCount = Length(FResults) then
  begin
    if FCount = 0 then
      SetLength(FResults, 64)
    else
      SetLength(FResults, FCount * 2);
  end;
  FResults[FCount] := AResult;
  Inc(FCount);
  FTally.Count(AResult.Status);
end;

function TWastRunResult.Count: Integer;
begin
  Result := FCount;
end;

function TWastRunResult.GetResult(const AIndex: Integer): TWastCommandResult;
begin
  if (AIndex < 0) or (AIndex >= FCount) then
    raise ERangeError.CreateFmt('result index %d out of range 0..%d',
      [AIndex, FCount - 1]);
  Result := FResults[AIndex];
end;

{ --- naming -------------------------------------------------------------- }

function WastStatusName(const AStatus: TWastStatus): string;
begin
  case AStatus of
    wrsPass: Result := 'pass';
    wrsFail: Result := 'fail';
    wrsSkip: Result := 'skip';
    wrsStaged: Result := 'staged';
  else
    Result := '?';
  end;
end;

function WastErrorKindName(const AKind: TWastErrorKind): string;
begin
  case AKind of
    wekNone: Result := 'none';
    wekDecode: Result := 'malformed';
    wekValidation: Result := 'invalid';
    wekOther: Result := 'internal';
  else
    Result := '?';
  end;
end;

function WastMessageMatches(const AExpected, AActual: string): Boolean;
begin
  Result := (Length(AExpected) <= Length(AActual))
    and (Copy(AActual, 1, Length(AExpected)) = AExpected);
end;

{ --- payload extraction -------------------------------------------------- }

{ The bytes of a string node as text. Expected-failure strings are ASCII
  in the corpus; a byte-per-char copy keeps whatever is there visible in a
  report instead of failing on it, because the harness is not the place to
  re-litigate the script's encoding. }
function BytesToText(const ABytes: TWasmBytes): string;
var
  I: Integer;
begin
  SetLength(Result, Length(ABytes));
  for I := 0 to High(ABytes) do
    Result[I + 1] := Chr(ABytes[I]);
end;

{ The concatenation of every string literal in a `(module binary ...)`
  form — the module's bytes. The literals are the payload wherever they
  sit, so they are gathered by node kind rather than by position. }
function ModuleBinaryBytes(const ANode: TWastNode): TWasmBytes;
var
  I, Total, Offset, Size: Integer;
  Part: TWasmBytes;
begin
  Total := 0;
  for I := 0 to ANode.Count - 1 do
    if ANode[I].Kind = wnkString then
      Inc(Total, Length(ANode[I].Bytes));

  SetLength(Result, Total);
  Offset := 0;
  for I := 0 to ANode.Count - 1 do
    if ANode[I].Kind = wnkString then
    begin
      Part := ANode[I].Bytes;
      Size := Length(Part);
      if Size > 0 then
      begin
        Move(Part[0], Result[Offset], Size);
        Inc(Offset, Size);
      end;
    end;
end;

{ The `(module ...)` operand of an assertion, nil when there is none.
  `assert_malformed` and `assert_invalid` always carry one in the
  reference grammar, but a harness that assumed it would crash on a
  malformed script instead of reporting it. }
function FindModuleOperand(const ANode: TWastNode): TWastNode;
var
  I: Integer;
begin
  Result := nil;
  for I := 1 to ANode.Count - 1 do
    if (ANode[I].Kind = wnkList) and (ANode[I].HeadAtom = 'module') then
      Exit(ANode[I]);
end;

{ The expected-failure string of an assertion: its LAST direct string
  literal. Taken from the end because the module operand's own literals
  are nested one level down and never direct children, while the failure
  string always trails the operand. }
function ExpectedFailure(const ANode: TWastNode): string;
var
  I: Integer;
begin
  Result := '';
  for I := ANode.Count - 1 downto 1 do
    if ANode[I].Kind = wnkString then
      Exit(BytesToText(ANode[I].Bytes));
end;

{ --- module attempts ----------------------------------------------------- }

{ Decode then validate ABytes, reporting which class of error came out.

  BOTH phases run for every case, and the verdict keys on the error CLASS
  rather than on which phase raised. That is not a shortcut: the binary
  grammar's side conditions inside function bodies are checked during the
  fused validation walk, and they raise EWasmDecodeError from there
  (Wasm.Validator.Body). A harness that decided "malformed" meant "failed
  in DecodeModule" would mark every one of those as a wrong-class failure.

  The bare Exception handler catches what should never happen — an
  ERangeError or an EOutOfMemory from a hostile module is a bug in this
  project, and the corpus is full of adversarial bytes. It is reported as
  wekOther, which always fails, rather than being allowed to abort a run
  of thousands of commands. }
function AttemptModule(const ABytes: TWasmBytes; const AModule: TWasmModule;
  out AMessage: string): TWastErrorKind;
var
  Ir: TWasmIrModule;
begin
  Result := wekNone;
  AMessage := '';
  Ir := nil;
  try
    try
      DecodeModule(ABytes, AModule);
      Ir := ValidateModule(AModule, ABytes);
    except
      on E: EWasmDecodeError do
      begin
        Result := wekDecode;
        AMessage := E.Message;
      end;
      on E: EWasmValidationError do
      begin
        Result := wekValidation;
        AMessage := E.Message;
      end;
      on E: Exception do
      begin
        Result := wekOther;
        AMessage := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    Ir.Free;
  end;
end;

procedure Skipped(var AResult: TWastCommandResult; const AReason: string);
begin
  AResult.Status := wrsSkip;
  AResult.Actual := AReason;
end;

{ A top-level module: it must decode AND validate. }
procedure RunModuleCommand(const ACommand: TWastCommand;
  const AModule: TWasmModule; var AResult: TWastCommandResult);
var
  Kind: TWastErrorKind;
  Msg: string;
begin
  if ACommand.ModuleForm <> wmfBinary then
  begin
    Skipped(AResult, WAST_REASON_TEXT_FORMAT);
    Exit;
  end;

  Kind := AttemptModule(ModuleBinaryBytes(ACommand.Node), AModule, Msg);
  AResult.ActualKind := Kind;
  AResult.Actual := Msg;
  if Kind = wekNone then
    AResult.Status := wrsPass
  else if IsStagedFeatureMessage(Msg) then
    AResult.Status := wrsStaged
  else
    AResult.Status := wrsFail;
end;

{ `assert_malformed` / `assert_invalid`: the module must fail, with the
  error class AWant and a message the script's expected string is a
  prefix of. Both halves matter — the right rejection for the wrong reason
  is still a divergence, and the message is what the report exists to
  surface. }
procedure RunAssertFailure(const ACommand: TWastCommand;
  const AWant: TWastErrorKind; const AModule: TWasmModule;
  var AResult: TWastCommandResult);
var
  Operand: TWastNode;
  Kind: TWastErrorKind;
  Msg: string;
begin
  Operand := FindModuleOperand(ACommand.Node);
  if Operand = nil then
  begin
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;

  AResult.Expected := ExpectedFailure(ACommand.Node);

  if DetectWastModuleForm(Operand) <> wmfBinary then
  begin
    Skipped(AResult, WAST_REASON_TEXT_FORMAT);
    Exit;
  end;

  Kind := AttemptModule(ModuleBinaryBytes(Operand), AModule, Msg);
  AResult.ActualKind := Kind;
  if Kind = wekNone then
    AResult.Actual := WAST_NO_ERROR
  else
    AResult.Actual := Msg;

  { An empty Expected degrades this to a class-only match: the empty
    string is a prefix of every message, per the reference interpreter's
    rule (WastMessageMatches). That is correct — assert_malformed /
    assert_invalid without a spelled failure string still assert the
    error CLASS — and the class check below is never relaxed by it.

    The staged carve-out is gated on `Kind = AWant`, not on the message
    alone: the staged-SIMD message is raised as a VALIDATION error, so a
    SIMD body under assert_malformed (which wants a decode error) is a
    wrong-class result and must fail, never be buried as STAGED. }
  if (Kind = AWant) and WastMessageMatches(AResult.Expected, Msg) then
    AResult.Status := wrsPass
  else if (Kind = AWant) and IsStagedFeatureMessage(Msg) then
    AResult.Status := wrsStaged
  else
    AResult.Status := wrsFail;
end;

function ExecuteCommand(const ACommand: TWastCommand;
  const AModule: TWasmModule): TWastCommandResult;
begin
  Result.Kind := ACommand.Kind;
  Result.Line := ACommand.Node.Line;
  Result.Status := wrsSkip;
  Result.Expected := '';
  Result.Actual := '';
  Result.ActualKind := wekNone;

  case ACommand.Kind of
    wcModule:
      RunModuleCommand(ACommand, AModule, Result);
    wcAssertMalformed:
      RunAssertFailure(ACommand, wekDecode, AModule, Result);
    wcAssertInvalid:
      RunAssertFailure(ACommand, wekValidation, AModule, Result);
    wcUnknown:
      Skipped(Result, WAST_REASON_UNKNOWN_DIRECTIVE);
  else
    { Registration, actions, and every result assertion. All of them need
      instantiation and execution, which is Track D onward. }
    Skipped(Result, WAST_REASON_NEEDS_TIER);
  end;
end;

{ --- entry points -------------------------------------------------------- }

function RunWastScript(const AScript: TWastScript): TWastRunResult;
var
  I: Integer;
  Module: TWasmModule;
begin
  Result := TWastRunResult.Create;
  try
    { One model reused across the script. DecodeModule clears it first, so
      no command can see the previous one's state, and a script with
      thousands of module commands does not allocate thousands of
      models. }
    Module := TWasmModule.Create;
    try
      for I := 0 to AScript.Count - 1 do
        Result.AddResult(ExecuteCommand(AScript[I], Module));
    finally
      Module.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function RunWastSource(const ASource: string): TWastRunResult;
var
  Script: TWastScript;
begin
  Script := ParseWastScript(ASource);
  try
    Result := RunWastScript(Script);
  finally
    Script.Free;
  end;
end;

function RunWastFile(const APath: string): TWastRunResult;
begin
  { LoadFileBytes rather than a TStringList: a .wast is read verbatim,
    with no line-ending normalisation and no encoding guess. The lexer
    tracks \n, \r\n, and lone \r itself, and string literals carry bytes. }
  Result := RunWastSource(BytesToText(LoadFileBytes(APath)));
end;

end.
