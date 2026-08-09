{ Unit suite for Wasm.Wast.Runner — the .wast command runner (Track C,
  docs/roadmap.md).

  The scripts here are INLINE, and the modules inside them are spelled as
  literal bytes in `\hh` escapes, for the same reason the decoder's
  malformed cases are (AGENTS.md, docs/testing.md): each case IS a
  specific module, and putting it next to the assertion means the reader
  can see what is being judged without opening a fixture. A fixture file
  would also defeat the point of a runner test — the runner's contract is
  about SCRIPT text, not about file loading.

  What is asserted here is OUR behaviour, deliberately, and the expected
  strings are upstream's real ones (`magic header not detected`,
  `unknown memory 1`). Both used to be divergences that these tests
  pinned as failures; the corpus run settled the prefixes and they now
  match, so the cases assert a pass and the wrong-prefix case uses a
  string that genuinely does not apply. What must not change is the
  shape: a divergence is REPORTED as a fail carrying both strings, never
  raised and never quietly passed because the module was rejected for
  some other reason. }
program Wasm.Wast.Runner.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Wast,
  Wasm.Wast.Runner;

const
  { A well-formed empty module: the 8-byte preamble and nothing else. }
  MODULE_EMPTY = '"\00asm\01\00\00\00"';

  { The same preamble with the magic's last byte changed from 'm' (6d) to
    'n' (6e). Malformed, and it fails in the very first bytes the decoder
    reads. }
  MODULE_BAD_MAGIC = '"\00asn\01\00\00\00"';

  { Preamble, then a memory section (id 5, 5 bytes): one memory, flags 00
    (no maximum, i32), minimum 65537 pages as LEB128 (81 80 04). The
    module DECODES — the limit is a validity rule, not a grammar rule —
    and then fails validation on the 65536-page bound. It is the case that
    keeps the malformed/invalid split honest in this suite. }
  MODULE_MEMORY_TOO_LARGE = '"\00asm\01\00\00\00\05\05\01\00\81\80\04"';

  { Preamble; type section (id 1) with one `(func)`; function section
    (id 3) declaring one function of that type; code section (id 10) whose
    single body is `v128.load align=0 offset=0` (FD 00 00 00) then `end`.
    It decodes — Wasm.Decoder.Expr knows the $FD immediate shapes — and
    reaches the vector family in the body walk, which is staged to
    Track G. }
  MODULE_SIMD_BODY = '"\00asm\01\00\00\00\01\04\01\60\00\00\03\02\01\00'
    + '\0a\08\01\06\00\fd\00\00\00\0b"';

  { A hand-assembled binary module that actually runs, for the execution
    tests. Three func types (()->i32, ()->f32, ()->f64) and exports:
      "seven"   () -> i32   = i32.const 7
      "qnan"    () -> f32   = f32.sqrt (f32.const -1)  → an arithmetic NaN
      "divz"    () -> i32   = 1 / 0                     → traps
      "onehalf" () -> f64   = f64.const 0.5
      "g"       global i32  = 42
    Spelled as literal bytes for the same reason the malformed cases are:
    the module under test is readable next to the assertion. }
  MODULE_NUMERIC =
    '(module binary '
    + '"\00\61\73\6d\01\00\00\00"'
    + '"\01\0d\03\60\00\01\7f\60\00\01\7d\60\00\01\7c"'
    + '"\03\05\04\00\01\00\02"'
    + '"\06\06\01\7f\00\41\2a\0b"'
    + '"\07\25\05\05\73\65\76\65\6e\00\00\04\71\6e\61\6e\00\01\04'
    + '\64\69\76\7a\00\02\07\6f\6e\65\68\61\6c\66\00\03\01\67\03\00"'
    + '"\0a\23\04\04\00\41\07\0b\08\00\43\00\00\80\bf\91\0b\07\00'
    + '\41\01\41\00\6d\0b\0b\00\44\00\00\00\00\00\00\e0\3f\0b"'
    + ')';

  { An identity function over externref: "id" (externref) -> externref =
    local.get 0. Exercises reference-identity marshaling both ways. }
  MODULE_EXTERN_ID =
    '(module binary '
    + '"\00\61\73\6d\01\00\00\00"'
    + '"\01\06\01\60\01\6f\01\6f"'
    + '"\03\02\01\00"'
    + '"\07\06\01\02\69\64\00\00"'
    + '"\0a\06\01\04\00\20\00\0b"'
    + ')';

  { Non-tail self-recursion: "rec" () -> i32 = rec() + 0. Runs the depth
    cap into `call stack exhausted`. }
  MODULE_RECURSE =
    '(module binary '
    + '"\00\61\73\6d\01\00\00\00"'
    + '"\01\05\01\60\00\01\7f"'
    + '"\03\02\01\00"'
    + '"\07\07\01\03\72\65\63\00\00"'
    + '"\0a\09\01\07\00\10\00\41\00\6a\0b"'
    + ')';

  { An exporter (func "get5" () -> i32 = 5) and, after `(register "M")`, an
    importer that imports M."get5" and re-exports it as "f". }
  MODULE_EXPORTER =
    '(module binary '
    + '"\00\61\73\6d\01\00\00\00"'
    + '"\01\05\01\60\00\01\7f"'
    + '"\03\02\01\00"'
    + '"\07\08\01\04\67\65\74\35\00\00"'
    + '"\0a\06\01\04\00\41\05\0b"'
    + ')';
  MODULE_IMPORTER =
    '(module binary '
    + '"\00\61\73\6d\01\00\00\00"'
    + '"\01\05\01\60\00\01\7f"'
    + '"\02\0a\01\01\4d\04\67\65\74\35\00\00"'
    + '"\07\05\01\01\66\00\00"'
    + ')';

type
  TWastRunnerTests = class(TTestSuite)
  private
    { '<kind>:<status>' per command, space separated — the whole script's
      verdict in one comparable string. }
    function StatusSignature(const ASource: string): string;
    { The AIndex-th command's result, the run itself already released. }
    function ResultAt(const ASource: string;
      const AIndex: Integer): TWastCommandResult;
    function FirstResult(const ASource: string): TWastCommandResult;
    { Assert AActual starts with AExpected, keeping the full actual text
      in the failure output. Spelled as a value comparison so the test
      records an assertion either way (docs/testing.md, gotcha 2). }
    procedure ExpectStartsWith(const AActual, AExpected: string);
  public
    procedure SetupTests; override;

    procedure TestAssertMalformedPasses;
    procedure TestAssertMalformedWrongPrefixReportsFail;
    procedure TestAssertMalformedNotRejectedReportsFail;
    procedure TestAssertInvalidPasses;
    procedure TestAssertInvalidWrongClassReportsFail;
    procedure TestAssertInvalidUnknownMemoryIndexInPrefix;
    procedure TestAssertInvalidEmptyExpectedMatchesOnClass;
    procedure TestAssertMalformedEmptyExpectedStillChecksClass;
    procedure TestStagedSimdWrongClassReportsFail;
    procedure TestTopLevelBinaryModulePasses;
    procedure TestTopLevelBinaryModuleFailureReported;
    procedure TestTextModuleSkipped;
    procedure TestQuotedModuleSkipped;
    procedure TestTextModuleInsideAssertSkipped;
    procedure TestUnknownDirectiveSkipped;
    procedure TestExecutionCommandsSkipped;
    procedure TestAssertWithoutModuleOperandSkipped;
    procedure TestStagedSimdInAssert;
    procedure TestStagedSimdAtTopLevel;
    procedure TestFailureDoesNotStopTheScript;
    procedure TestTallyCountsEveryStatus;
    procedure TestPrefixMatchRule;
    procedure TestScriptParseErrorRaises;

    { execution (Track E) }
    procedure TestAssertReturnPasses;
    procedure TestAssertReturnMismatchFails;
    procedure TestAssertReturnFloatAndNanClasses;
    procedure TestAssertTrapPasses;
    procedure TestAssertTrapWrongMessageFails;
    procedure TestInvokeActionPasses;
    procedure TestGetExportedGlobal;
    procedure TestAssertExhaustion;
    procedure TestExternRefIdentityMatches;
    procedure TestExternRefIdentityMismatchFails;
    procedure TestCrossModuleRegisterImport;
  end;

function TWastRunnerTests.StatusSignature(const ASource: string): string;
var
  Run: TWastRunResult;
  I: Integer;
begin
  Result := '';
  Run := RunWastSource(ASource);
  try
    for I := 0 to Run.Count - 1 do
    begin
      if Result <> '' then
        Result := Result + ' ';
      Result := Result + WastCommandKindName(Run[I].Kind) + ':'
        + WastStatusName(Run[I].Status);
    end;
  finally
    Run.Free;
  end;
end;

function TWastRunnerTests.ResultAt(const ASource: string;
  const AIndex: Integer): TWastCommandResult;
var
  Run: TWastRunResult;
begin
  Run := RunWastSource(ASource);
  try
    Result := Run[AIndex];
  finally
    Run.Free;
  end;
end;

function TWastRunnerTests.FirstResult(
  const ASource: string): TWastCommandResult;
begin
  Result := ResultAt(ASource, 0);
end;

procedure TWastRunnerTests.ExpectStartsWith(const AActual,
  AExpected: string);
var
  Outcome: string;
begin
  if WastMessageMatches(AExpected, AActual) then
    Outcome := 'starts with "' + AExpected + '"'
  else
    Outcome := 'MISSING prefix "' + AExpected + '" in "' + AActual + '"';
  Expect<string>(Outcome).ToBe('starts with "' + AExpected + '"');
end;

{ --- assert_malformed ---------------------------------------------------- }

procedure TWastRunnerTests.TestAssertMalformedPasses;
var
  Item: TWastCommandResult;
begin
  { The expected string is a PREFIX of our message, which is the reference
    interpreter's rule — not equality. This is upstream's own string for
    the case. }
  Item := FirstResult('(assert_malformed (module binary ' + MODULE_BAD_MAGIC
    + ') "magic header not detected")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('malformed');
  ExpectStartsWith(Item.Actual, 'magic header not detected: magic is');
  Expect<Integer>(Item.Line).ToBe(1);
end;

procedure TWastRunnerTests.TestAssertMalformedWrongPrefixReportsFail;
var
  Item: TWastCommandResult;
begin
  { `unknown binary version` is a real canonical prefix, but not this
    module's — the magic fails before the version is ever read. The
    runner must REPORT that mismatch as a fail carrying both strings,
    rather than raising, and rather than passing because the module was
    rejected for SOME reason. This is the shape of every prefix
    divergence the corpus surfaces. }
  Item := FirstResult('(assert_malformed (module binary ' + MODULE_BAD_MAGIC
    + ') "unknown binary version")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(Item.Expected).ToBe('unknown binary version');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('malformed');
  ExpectStartsWith(Item.Actual, 'magic header not detected');
end;

procedure TWastRunnerTests.TestAssertMalformedNotRejectedReportsFail;
var
  Item: TWastCommandResult;
begin
  { A module that goes through cleanly when the script says it must not.
    The absence of a message is the finding, so the runner spells it. }
  Item := FirstResult('(assert_malformed (module binary ' + MODULE_EMPTY
    + ') "unexpected end")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('none');
  Expect<string>(Item.Actual).ToBe(WAST_NO_ERROR);
end;

{ --- assert_invalid ------------------------------------------------------ }

procedure TWastRunnerTests.TestAssertInvalidPasses;
var
  Item: TWastCommandResult;
begin
  Item := FirstResult('(assert_invalid (module binary '
    + MODULE_MEMORY_TOO_LARGE + ') "memory size must be at most")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('invalid');
  ExpectStartsWith(Item.Actual, 'memory size must be at most');
end;

procedure TWastRunnerTests.TestAssertInvalidWrongClassReportsFail;
var
  Item: TWastCommandResult;
begin
  { Rejected, but as MALFORMED where the script demanded INVALID. The
    error hierarchy is load-bearing (AGENTS.md): a harness that accepted
    any rejection would pass an implementation that rejects the right
    modules for the wrong reason. The reported kind names what we did. }
  Item := FirstResult('(assert_invalid (module binary ' + MODULE_BAD_MAGIC
    + ') "magic header not detected")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('malformed');
end;

procedure TWastRunnerTests.TestAssertInvalidUnknownMemoryIndexInPrefix;
var
  Item: TWastCommandResult;
begin
  { A data segment naming memory 1 in a module with no memory section.
    Preamble; data count section (id 12) = 1; data section (id 11) with
    one active segment whose memory index is 1 (flags 02), offset
    `i32.const 0` (41 00 0B), and no bytes.

    Upstream spells the expected failure `unknown memory 1` — the INDEX is
    part of the prefix, with no colon before it. This case is the
    regression guard for that: a message of the shape
    `unknown memory: ... memory 1 ...` puts the index after the colon and
    would NOT match, even though it names the same memory. }
  Item := FirstResult('(assert_invalid (module binary '
    + '"\00asm\01\00\00\00\0c\01\01\0b\07\01\02\01\41\00\0b\00")'
    + ' "unknown memory 1")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('invalid');
  ExpectStartsWith(Item.Actual, 'unknown memory 1');
end;

procedure TWastRunnerTests.TestAssertInvalidEmptyExpectedMatchesOnClass;
var
  Item: TWastCommandResult;
begin
  { An empty expected string degrades to a class-only match, per the
    reference interpreter's prefix rule — the empty string is a prefix of
    every message. The module is rejected as invalid, so the class matches
    and the case passes. Pinned so the empty-prefix behaviour cannot drift
    into a spurious fail or a silent skip. }
  Item := FirstResult('(assert_invalid (module binary '
    + MODULE_MEMORY_TOO_LARGE + ') "")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(Item.Expected).ToBe('');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('invalid');
end;

procedure TWastRunnerTests.TestAssertMalformedEmptyExpectedStillChecksClass;
var
  Item: TWastCommandResult;
begin
  { An empty expected string does NOT loosen the class check. This module
    decodes and is rejected as INVALID, but the script asked for
    MALFORMED; the empty failure string cannot turn a wrong-class
    rejection into a pass. }
  Item := FirstResult('(assert_malformed (module binary '
    + MODULE_MEMORY_TOO_LARGE + ') "")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('invalid');
end;

procedure TWastRunnerTests.TestStagedSimdWrongClassReportsFail;
var
  Item: TWastCommandResult;
begin
  { A SIMD body under assert_malformed: the staged message is raised as a
    VALIDATION error, but the script demanded MALFORMED. The staged
    carve-out is gated on the wanted class, so this is a fail — a
    wrong-class result cannot hide behind STAGED. }
  Item := FirstResult('(assert_malformed (module binary ' + MODULE_SIMD_BODY
    + ') "type mismatch")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('invalid');
end;

{ --- top-level modules --------------------------------------------------- }

procedure TWastRunnerTests.TestTopLevelBinaryModulePasses;
var
  Item: TWastCommandResult;
begin
  Item := FirstResult('(module binary ' + MODULE_EMPTY + ')');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastCommandKindName(Item.Kind)).ToBe('module');
  Expect<string>(Item.Actual).ToBe('');
end;

procedure TWastRunnerTests.TestTopLevelBinaryModuleFailureReported;
var
  Item: TWastCommandResult;
begin
  { A module the script presents as good and we reject. There is no
    expected string on a bare module command, so the failure carries only
    our message — which is exactly the evidence needed. }
  Item := FirstResult('(module binary ' + MODULE_BAD_MAGIC + ')');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(Item.Expected).ToBe('');
  ExpectStartsWith(Item.Actual, 'magic header not detected');
end;

{ --- skips: the honest boundary ------------------------------------------ }

procedure TWastRunnerTests.TestTextModuleSkipped;
var
  Item: TWastCommandResult;
begin
  Item := FirstResult('(module (func $f (result i32) (i32.const 1)))');
  Expect<string>(WastStatusName(Item.Status)).ToBe('skip');
  Expect<string>(Item.Actual).ToBe(WAST_REASON_TEXT_FORMAT);
end;

procedure TWastRunnerTests.TestQuotedModuleSkipped;
begin
  { `(module quote ...)` is text too — the payload is source to be parsed,
    not bytes to be decoded. }
  Expect<string>(StatusSignature('(module quote "(module)")'))
    .ToBe('module:skip');
end;

procedure TWastRunnerTests.TestTextModuleInsideAssertSkipped;
var
  Item: TWastCommandResult;
begin
  { The assertion is real, the operand is not assemblable. Skipping is the
    only honest outcome: counting it as a pass would claim coverage of a
    case never run, and counting it as a fail would blame the corpus for
    an absent assembler. }
  Item := FirstResult(
    '(assert_malformed (module quote "(func)") "unexpected token")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('skip');
  Expect<string>(Item.Actual).ToBe(WAST_REASON_TEXT_FORMAT);
  { The expected string is still recorded — the case is skipped, not
    forgotten. }
  Expect<string>(Item.Expected).ToBe('unexpected token');
end;

procedure TWastRunnerTests.TestUnknownDirectiveSkipped;
var
  Item: TWastCommandResult;
begin
  { `assert_malformed_custom` is testsuite-local and outside the reference
    grammar. Wasm.Wast classifies it as unknown; the runner must skip it,
    never error on it. }
  Item := FirstResult('(assert_malformed_custom (module binary '
    + MODULE_BAD_MAGIC + ') "invalid custom section")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('skip');
  Expect<string>(Item.Actual).ToBe(WAST_REASON_UNKNOWN_DIRECTIVE);
end;

procedure TWastRunnerTests.TestExecutionCommandsSkipped;
begin
  { With a tier landed but NO module instantiated in the script, every
    action/assertion still skips — there is nothing to run it against. The
    reasons now name the real gap (no instance, text-only, exceptions)
    rather than a blanket "needs a tier". }
  Expect<string>(StatusSignature(
    '(register "m")' + sLineBreak +
    '(invoke "f" (i32.const 1))' + sLineBreak +
    '(assert_return (invoke "f") (i32.const 1))' + sLineBreak +
    '(assert_trap (invoke "f") "integer divide by zero")' + sLineBreak +
    '(assert_unlinkable (module quote "(module)") "unknown import")' +
      sLineBreak +
    '(assert_exhaustion (invoke "f") "call stack exhausted")' + sLineBreak +
    '(assert_exception (invoke "f"))'))
    .ToBe('register:skip invoke:skip assert_return:skip assert_trap:skip '
      + 'assert_unlinkable:skip assert_exhaustion:skip assert_exception:skip');

  { No module precedes it, so there is no current instance to register. }
  Expect<string>(FirstResult('(register "m")').Actual)
    .ToBe(WAST_REASON_NO_INSTANCE);
end;

procedure TWastRunnerTests.TestAssertWithoutModuleOperandSkipped;
var
  Item: TWastCommandResult;
begin
  { Not in the reference grammar, so nothing in the corpus should look
    like this — but a harness that assumed the operand was there would
    crash on a hand-written script instead of reporting it. }
  Item := FirstResult('(assert_malformed "unexpected end")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('skip');
  Expect<string>(Item.Actual).ToBe(WAST_REASON_NO_MODULE_OPERAND);
end;

{ --- staged work --------------------------------------------------------- }

procedure TWastRunnerTests.TestStagedSimdInAssert;
var
  Item: TWastCommandResult;
begin
  { The module is rejected, but on work this project has deliberately
    staged to Track G rather than on the rule the script is about. Neither
    a pass (nothing was judged) nor a fail (nothing diverged) — its own
    status, counted separately, so the vector files cannot bury the real
    divergences. }
  Item := FirstResult('(assert_invalid (module binary ' + MODULE_SIMD_BODY
    + ') "type mismatch")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('staged');
  Expect<string>(Item.Expected).ToBe('type mismatch');
  ExpectStartsWith(Item.Actual, 'SIMD validation is not implemented');
end;

procedure TWastRunnerTests.TestStagedSimdAtTopLevel;
var
  Item: TWastCommandResult;
begin
  Item := FirstResult('(module binary ' + MODULE_SIMD_BODY + ')');
  Expect<string>(WastStatusName(Item.Status)).ToBe('staged');
  ExpectStartsWith(Item.Actual, 'SIMD validation is not implemented');
end;

{ --- script-level behaviour ---------------------------------------------- }

procedure TWastRunnerTests.TestFailureDoesNotStopTheScript;
begin
  { A failing command is a result, not an exception. The corpus has files
    with hundreds of assertions and one harness run has to judge all of
    them, so the command after a failure — and after a rejected module
    that left the shared model half-built — must still be judged. }
  Expect<string>(StatusSignature(
    '(assert_malformed (module binary ' + MODULE_BAD_MAGIC
      + ') "wrong prefix entirely")' + sLineBreak +
    '(module binary ' + MODULE_BAD_MAGIC + ')' + sLineBreak +
    '(assert_malformed (module binary ' + MODULE_BAD_MAGIC
      + ') "magic header not detected")' + sLineBreak +
    '(module binary ' + MODULE_EMPTY + ')'))
    .ToBe('assert_malformed:fail module:fail assert_malformed:pass '
      + 'module:pass');
end;

procedure TWastRunnerTests.TestTallyCountsEveryStatus;
var
  Run: TWastRunResult;
  Tally: TWastTally;
begin
  Run := RunWastSource(
    '(assert_malformed (module binary ' + MODULE_BAD_MAGIC
      + ') "magic header not detected")' + sLineBreak +
    '(assert_malformed (module binary ' + MODULE_BAD_MAGIC
      + ') "unknown binary version")' + sLineBreak +
    '(module (func))' + sLineBreak +
    '(assert_invalid (module binary ' + MODULE_SIMD_BODY
      + ') "type mismatch")');
  try
    Tally := Run.Tally;
    Expect<Integer>(Run.Count).ToBe(4);
    Expect<Integer>(Tally.Pass).ToBe(1);
    Expect<Integer>(Tally.Fail).ToBe(1);
    Expect<Integer>(Tally.Skip).ToBe(1);
    Expect<Integer>(Tally.Staged).ToBe(1);
    { Skips are counted in the total and never folded into passes — a
      report must not read as more coverage than was measured. }
    Expect<Integer>(Tally.Total).ToBe(4);
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestPrefixMatchRule;
begin
  { The criterion itself: expected is a PREFIX of actual, not equal to it,
    not contained in it. }
  Expect<Boolean>(WastMessageMatches('type mismatch',
    'type mismatch: expected i32')).ToBe(True);
  Expect<Boolean>(WastMessageMatches('type mismatch', 'type mismatch'))
    .ToBe(True);
  Expect<Boolean>(WastMessageMatches('', 'anything at all')).ToBe(True);
  Expect<Boolean>(WastMessageMatches('mismatch',
    'type mismatch: expected i32')).ToBe(False);
  Expect<Boolean>(WastMessageMatches('type mismatch!', 'type mismatch'))
    .ToBe(False);
  { Case-sensitive, like the reference interpreter's comparison. }
  Expect<Boolean>(WastMessageMatches('Type', 'type mismatch')).ToBe(False);
end;

procedure TWastRunnerTests.TestScriptParseErrorRaises;
var
  Raised: Boolean;
begin
  { A script that is not a script is harness input, not a conformance
    result: it raises rather than being recorded as a failed command. The
    flag-then-assert shape is the framework gotcha in docs/testing.md —
    FPC will not parse a generic call as the lone statement of an
    `on ... do`. }
  Raised := False;
  try
    RunWastSource('(module binary "\00asm"').Free;
  except
    on E: EWastParseError do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

{ --- execution ----------------------------------------------------------- }

procedure TWastRunnerTests.TestAssertReturnPasses;
var
  Item: TWastCommandResult;
begin
  Item := ResultAt(MODULE_NUMERIC + sLineBreak
    + '(assert_return (invoke "seven") (i32.const 7))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestAssertReturnMismatchFails;
var
  Item: TWastCommandResult;
begin
  { The wrong expected value: the runner records the produced hex so the
    divergence is legible. }
  Item := ResultAt(MODULE_NUMERIC + sLineBreak
    + '(assert_return (invoke "seven") (i32.const 8))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  ExpectStartsWith(Item.Actual, '0x00000007');
end;

procedure TWastRunnerTests.TestAssertReturnFloatAndNanClasses;
begin
  { An exact f64, plus the same arithmetic NaN accepted by BOTH NaN
    classes (the interpreter emits canonical, §3.2). }
  Expect<string>(StatusSignature(MODULE_NUMERIC + sLineBreak
    + '(assert_return (invoke "onehalf") (f64.const 0.5))' + sLineBreak
    + '(assert_return (invoke "qnan") (f32.const nan:arithmetic))' + sLineBreak
    + '(assert_return (invoke "qnan") (f32.const nan:canonical))'))
    .ToBe('module:pass assert_return:pass assert_return:pass '
      + 'assert_return:pass');
end;

procedure TWastRunnerTests.TestAssertTrapPasses;
var
  Item: TWastCommandResult;
begin
  Item := ResultAt(MODULE_NUMERIC + sLineBreak
    + '(assert_trap (invoke "divz") "integer divide by zero")', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestAssertTrapWrongMessageFails;
var
  Item: TWastCommandResult;
begin
  { A real trap, but not the message the script demanded — a fail that
    keeps both strings, exactly as the malformed/invalid prefix fails do. }
  Item := ResultAt(MODULE_NUMERIC + sLineBreak
    + '(assert_trap (invoke "divz") "unreachable")', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(Item.Expected).ToBe('unreachable');
  ExpectStartsWith(Item.Actual, 'integer divide by zero');
end;

procedure TWastRunnerTests.TestInvokeActionPasses;
var
  Item: TWastCommandResult;
begin
  { A bare invoke runs for effect and is expected to succeed. }
  Item := ResultAt(MODULE_NUMERIC + sLineBreak + '(invoke "seven")', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestGetExportedGlobal;
var
  Item: TWastCommandResult;
begin
  Item := ResultAt(MODULE_NUMERIC + sLineBreak
    + '(assert_return (get "g") (i32.const 42))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestAssertExhaustion;
var
  Item: TWastCommandResult;
begin
  { Non-tail self-recursion trips the depth cap; the non-recursive
    interpreter reports it as `call stack exhausted`. }
  Item := ResultAt(MODULE_RECURSE + sLineBreak
    + '(assert_exhaustion (invoke "rec") "call stack exhausted")', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestExternRefIdentityMatches;
begin
  { The same identity in and out, and null-in null-out. }
  Expect<string>(StatusSignature(MODULE_EXTERN_ID + sLineBreak
    + '(assert_return (invoke "id" (ref.extern 1)) (ref.extern 1))' + sLineBreak
    + '(assert_return (invoke "id" (ref.null extern)) (ref.null extern))'))
    .ToBe('module:pass assert_return:pass assert_return:pass');
end;

procedure TWastRunnerTests.TestExternRefIdentityMismatchFails;
var
  Item: TWastCommandResult;
begin
  { Passing identity 2 but expecting identity 1 — reference comparison is
    by identity, so this diverges. }
  Item := ResultAt(MODULE_EXTERN_ID + sLineBreak
    + '(assert_return (invoke "id" (ref.extern 2)) (ref.extern 1))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
end;

procedure TWastRunnerTests.TestCrossModuleRegisterImport;
begin
  { An exporter registered under "M", then an importer that imports
    M."get5" and re-exports it — the whole point of the per-script
    registry. }
  Expect<string>(StatusSignature(MODULE_EXPORTER + sLineBreak
    + '(register "M")' + sLineBreak
    + MODULE_IMPORTER + sLineBreak
    + '(assert_return (invoke "f") (i32.const 5))'))
    .ToBe('module:pass register:pass module:pass assert_return:pass');
end;

procedure TWastRunnerTests.SetupTests;
begin
  Test('assert_malformed passes on a prefix match',
    TestAssertMalformedPasses);
  Test('assert_malformed reports a fail on a wrong prefix',
    TestAssertMalformedWrongPrefixReportsFail);
  Test('assert_malformed reports a fail when nothing was rejected',
    TestAssertMalformedNotRejectedReportsFail);
  Test('assert_invalid passes on a prefix match', TestAssertInvalidPasses);
  Test('assert_invalid reports a fail on the wrong error class',
    TestAssertInvalidWrongClassReportsFail);
  Test('assert_invalid matches the unknown-memory index in the prefix',
    TestAssertInvalidUnknownMemoryIndexInPrefix);
  Test('assert_invalid with an empty expected string matches on class',
    TestAssertInvalidEmptyExpectedMatchesOnClass);
  Test('assert_malformed with an empty expected string still checks class',
    TestAssertMalformedEmptyExpectedStillChecksClass);
  Test('staged SIMD under the wrong class reports a fail',
    TestStagedSimdWrongClassReportsFail);
  Test('top-level binary module passes', TestTopLevelBinaryModulePasses);
  Test('top-level binary module failure is reported',
    TestTopLevelBinaryModuleFailureReported);
  Test('text module skipped', TestTextModuleSkipped);
  Test('quoted module skipped', TestQuotedModuleSkipped);
  Test('text module inside an assert skipped',
    TestTextModuleInsideAssertSkipped);
  Test('unknown directive skipped', TestUnknownDirectiveSkipped);
  Test('execution commands skipped', TestExecutionCommandsSkipped);
  Test('assert without a module operand skipped',
    TestAssertWithoutModuleOperandSkipped);
  Test('staged SIMD inside an assert', TestStagedSimdInAssert);
  Test('staged SIMD at top level', TestStagedSimdAtTopLevel);
  Test('a failure does not stop the script',
    TestFailureDoesNotStopTheScript);
  Test('tally counts every status', TestTallyCountsEveryStatus);
  Test('prefix match rule', TestPrefixMatchRule);
  Test('script parse error raises', TestScriptParseErrorRaises);

  Test('assert_return passes on a matching result',
    TestAssertReturnPasses);
  Test('assert_return reports a fail on a mismatch',
    TestAssertReturnMismatchFails);
  Test('assert_return matches exact float and NaN classes',
    TestAssertReturnFloatAndNanClasses);
  Test('assert_trap passes on the expected trap', TestAssertTrapPasses);
  Test('assert_trap reports a fail on the wrong message',
    TestAssertTrapWrongMessageFails);
  Test('bare invoke action passes', TestInvokeActionPasses);
  Test('assert_return reads an exported global', TestGetExportedGlobal);
  Test('assert_exhaustion passes on deep recursion',
    TestAssertExhaustion);
  Test('assert_return matches externref identity',
    TestExternRefIdentityMatches);
  Test('assert_return reports a fail on externref mismatch',
    TestExternRefIdentityMismatchFails);
  Test('register binds an instance for cross-module import',
    TestCrossModuleRegisterImport);
end;

begin
  TestRunnerProgram.AddSuite(TWastRunnerTests.Create('Wasm.Wast.Runner'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
