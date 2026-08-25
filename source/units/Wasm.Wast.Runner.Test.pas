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

{ The baseline JIT compiles only on a 64-bit UNIX aarch64 host this wave
  (jit-spec §2.1). Recompute the backend gate here — define symbols do not
  cross unit boundaries — so the JIT-mode cases assert compilation WHERE it is
  possible and assert the interpreter fall-back (compiled count 0) elsewhere,
  keeping the suite green on every CI leg. }
{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  {$DEFINE WASM_JIT_ARM64}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUX86_64)}
  {$DEFINE WASM_JIT_X64}
{$ENDIF}
{ A JIT backend exists for this target; the --tier=jit assertions that a
  function actually compiles gate on this, not on a specific arch. }
{$IF DEFINED(WASM_JIT_ARM64) OR DEFINED(WASM_JIT_X64)}
  {$DEFINE WASM_JIT_BACKEND}
{$ENDIF}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Interp,
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
    It decodes — Wasm.Decoder.Expr knows the $FD immediate shapes — and now
    reaches the vector family in the body walk, which REJECTS it (no memory
    and an unbalanced stack): a real VALIDATION error, no longer staged. }
  MODULE_SIMD_BODY = '"\00asm\01\00\00\00\01\04\01\60\00\00\03\02\01\00'
    + '\0a\08\01\06\00\fd\00\00\00\0b"';

  { A well-formed, self-contained v128 module built as literal bytes so the
    runner/comparator path does not depend on the assembler. One func type
    () -> v128 (0x7b), exported "v", whose body is a single
    `v128.const i8x16 0 1 2 ... 15` (FD 0C + 16 lane bytes) then `end`. It
    validates, instantiates, and — with the interpreter's vector dispatch —
    returns the lanes 0..15. }
  MODULE_V128 =
    '(module binary '
    + '"\00\61\73\6d\01\00\00\00"'
    + '"\01\05\01\60\00\01\7b"'
    + '"\03\02\01\00"'
    + '"\07\05\01\01\76\00\00"'
    + '"\0a\16\01\14\00\fd\0c\00\01\02\03\04\05\06\07\08\09\0a\0b'
    + '\0c\0d\0e\0f\0b"'
    + ')';

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

  { The JIT milestone function as text (jit-spec §12.2): one exported "add"
    whose body is exactly `local.get 0; local.get 1; i32.add`, which lowers to
    iroMove/iroI32Add/iroReturn — the ops the aarch64 backend emits. Under
    --tier=jit it force-compiles and every invoke routes through the machine
    code via the CompiledEntry seam. }
  MODULE_JIT_ADD =
    '(module (func (export "add") (param i32 i32) (result i32)'
    + ' (i32.add (local.get 0) (local.get 1))))';

  { A module with one compilable function ("add") and a second function
    ("seven") the backend may not yet template — so a --tier=jit run tiers the
    first up while the second stays interpreted, and both still return the right
    value: compiled and interpreted code coexisting behind the seam. (As op
    coverage grows the second may also compile; the durable claim is that both
    results are correct and at least one function was compiled.) }
  MODULE_JIT_MIXED =
    '(module'
    + ' (func (export "add") (param i32 i32) (result i32)'
    + '   (i32.add (local.get 0) (local.get 1)))'
    + ' (func (export "seven") (result i32) (i32.const 7)))';

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
    procedure TestSimdModuleWrongClassReportsFail;
    procedure TestTopLevelBinaryModulePasses;
    procedure TestTopLevelBinaryModuleFailureReported;
    procedure TestTextModuleAssembles;
    procedure TestQuotedModuleAssembles;
    procedure TestAssertMalformedTextOperandPasses;
    procedure TestAssertMalformedTextNotMalformedFails;
    procedure TestAssertInvalidTextOperandPasses;
    procedure TestSimdTextModuleValidates;
    procedure TestAssertUnlinkablePasses;
    procedure TestAssertUnlinkableUnknownImportPasses;
    procedure TestAssertUnlinkableWrongKindPasses;
    procedure TestAssertUnlinkableWrongPrefixFails;
    procedure TestAssertUnlinkableLinkableModuleFails;
    procedure TestInlineModuleBodyRunsAsOneModule;
    procedure TestUnknownDirectiveSkipped;
    procedure TestExecutionCommandsSkipped;
    procedure TestAssertWithoutModuleOperandSkipped;
    procedure TestSimdModuleJudgedInvalidNotStaged;
    procedure TestSimdModuleInstantiatesNotStaged;
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
    procedure TestSpectestPrintFunctions;
    procedure TestSpectestGlobals;
    procedure TestSpectestTablesAndMemory;
    procedure TestSpectestMemoryIsShared;
    procedure TestRegisteredSpectestReplacesBuiltinWholeModule;
    procedure TestCrossModuleRegisterImport;
    procedure TestModuleDefinitionDoesNotInstantiate;
    procedure TestModuleInstancesAreGenerative;
    procedure TestAnonymousModuleInstanceBecomesCurrent;
    procedure TestAssertTrapModuleOobSegmentPersists;
    procedure TestAssertTrapModuleTrappingStartPersists;
    procedure TestAssertTrapModuleNoTrapReportsFail;

    { SIMD execution (Track G, needs the interpreter's vector dispatch) }
    procedure TestAssertReturnV128PerLane;
    procedure TestAssertReturnV128WrongLaneFails;
    procedure TestV128ArgResultRoundTrip;
    procedure TestRelaxedEitherResultMatches;

    { exception handling (Track H, assert_exception judging) }
    procedure TestAssertExceptionPassesOnUncaughtThrow;
    procedure TestAssertExceptionFailsWhenCaughtInternally;
    procedure TestAssertExceptionFailsOnTrap;
    procedure TestAssertReturnFailsOnUncaughtException;

    { baseline JIT corpus mode (Track I, jit-spec §11, §12.3) }
    procedure TestTierModeName;
    procedure TestDefaultModeCompilesNothing;
    procedure TestJitModeCompilesAndPasses;
    procedure TestJitModeMixedTiersCoexist;
    procedure TestJitTallyIdenticalToInterp;

    { AOT corpus mode (Track J, aot-spec §5.1) }
    procedure TestAotModeLoadsAndPasses;
    procedure TestAotModeMixedTiersCoexist;
    procedure TestAotTallyIdenticalToInterp;
    procedure TestAotLoadedCountMatchesJit;
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

procedure TWastRunnerTests.TestSimdModuleWrongClassReportsFail;
var
  Item: TWastCommandResult;
begin
  { A malformed-in-body SIMD module under assert_malformed: it is now
    REJECTED by validation (not staged), but the script demanded MALFORMED.
    A wrong-class rejection is a fail — the class hierarchy is load-bearing
    and SIMD no longer has a staged carve-out to hide behind. }
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

procedure TWastRunnerTests.TestTextModuleAssembles;
var
  Item: TWastCommandResult;
begin
  { A well-formed text module now assembles, decodes, validates, and
    instantiates — no longer a skip. A pass carries no message. }
  Item := FirstResult('(module (func $f (result i32) (i32.const 1)))');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(Item.Actual).ToBe('');
end;

procedure TWastRunnerTests.TestQuotedModuleAssembles;
begin
  { `(module quote ...)` is source too; its payload assembles the same way. }
  Expect<string>(StatusSignature('(module quote "(module)")'))
    .ToBe('module:pass');
end;

procedure TWastRunnerTests.TestAssertMalformedTextOperandPasses;
var
  Item: TWastCommandResult;
begin
  { assert_malformed over a QUOTE operand expects a TEXT error, not a decode
    error: `0x` is the reserved-token rule (a malformed integer token is
    `unknown operator`, design §4). The kind is `text`, distinct from
    `malformed`, so INV-1 stays checkable. }
  Item := FirstResult(
    '(assert_malformed (module quote "(func (i32.const 0x))") '
    + '"unknown operator")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('text');
  ExpectStartsWith(Item.Actual, 'unknown operator');
end;

procedure TWastRunnerTests.TestAssertMalformedTextNotMalformedFails;
var
  Item: TWastCommandResult;
begin
  { A QUOTE operand that assembles cleanly is NOT malformed, however the
    script labels it — the assertion fails with `(no error raised)`, never a
    silent pass. }
  Item := FirstResult(
    '(assert_malformed (module quote "(func)") "unexpected token")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('none');
  Expect<string>(Item.Actual).ToBe(WAST_NO_ERROR);
  { The expected string is still recorded. }
  Expect<string>(Item.Expected).ToBe('unexpected token');
end;

procedure TWastRunnerTests.TestAssertInvalidTextOperandPasses;
var
  Item: TWastCommandResult;
begin
  { assert_invalid over a text module: it must ASSEMBLE (a func whose body is
    empty but whose result is i32), then fail VALIDATION as `type mismatch`.
    The kind is `invalid`, so an assembler that wrongly rejected it as a text
    error would be caught. }
  Item := FirstResult('(assert_invalid (module (func (result i32))) '
    + '"type mismatch")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('invalid');
  ExpectStartsWith(Item.Actual, 'type mismatch');
end;

procedure TWastRunnerTests.TestSimdTextModuleValidates;
var
  Item: TWastCommandResult;
begin
  { A text module using a vector mnemonic now assembles, validates, and
    instantiates — the `unknown operator v128.const` staging carve-out is
    gone. A pass carries no message. }
  Item := FirstResult('(module (func (v128.const i32x4 0 0 0 0) drop))');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(Item.Actual).ToBe('');
end;

procedure TWastRunnerTests.TestAssertUnlinkablePasses;
var
  Item: TWastCommandResult;
begin
  Item := ResultAt(
    '(module $m (func (export "f") (param i32)))' + sLineBreak
    + '(register "m" $m)' + sLineBreak
    + '(assert_unlinkable '
    + '  (module (import "m" "f" (func (param i64))))'
    + '  "incompatible import type")', 2);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('unlinkable');
  ExpectStartsWith(Item.Actual, 'incompatible import type');
end;

procedure TWastRunnerTests.TestAssertUnlinkableUnknownImportPasses;
var
  Item: TWastCommandResult;
begin
  { A missing module/name is represented as WASM_NO_ADDR and handed to the
    instantiator, which owns the `unknown import` link-error classification. }
  Item := FirstResult(
    '(assert_unlinkable (module (import "missing" "f" (func))) '
    + '"unknown import")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('unlinkable');
  ExpectStartsWith(Item.Actual, 'unknown import');
end;

procedure TWastRunnerTests.TestAssertUnlinkableWrongKindPasses;
var
  Item: TWastCommandResult;
begin
  { A known export of the wrong external kind is incompatible, not absent. }
  Item := ResultAt(
    '(module $m (memory (export "x") 1))' + sLineBreak
    + '(register "m" $m)' + sLineBreak
    + '(assert_unlinkable (module (import "m" "x" (func))) '
    + '"incompatible import type")', 2);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('unlinkable');
  ExpectStartsWith(Item.Actual, 'incompatible import type');
end;

procedure TWastRunnerTests.TestAssertUnlinkableWrongPrefixFails;
var
  Item: TWastCommandResult;
begin
  Item := FirstResult(
    '(assert_unlinkable (module (import "missing" "f" (func))) '
    + '"incompatible import type")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('unlinkable');
  ExpectStartsWith(Item.Actual, 'unknown import');
end;

procedure TWastRunnerTests.TestAssertUnlinkableLinkableModuleFails;
var
  Item: TWastCommandResult;
begin
  Item := FirstResult(
    '(assert_unlinkable (module) "unknown import")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('none');
  Expect<string>(Item.Actual).ToBe(WAST_NO_ERROR);
end;

procedure TWastRunnerTests.TestInlineModuleBodyRunsAsOneModule;
var
  Run: TWastRunResult;
begin
  Run := RunWastSource('(func) (memory 0) (func (export "f"))');
  try
    Expect<Integer>(Run.Count).ToBe(1);
    Expect<string>(WastCommandKindName(Run[0].Kind)).ToBe('module');
    Expect<string>(WastStatusName(Run[0].Status)).ToBe('pass');
  finally
    Run.Free;
  end;
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
  { With a tier landed but NO module instantiated in the script, actions
    still skip because there is nothing to run against. assert_unlinkable is
    self-contained: this empty operand links, so the assertion is judged and
    fails because it expected an error. }
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
      + 'assert_unlinkable:fail assert_exhaustion:skip assert_exception:skip');

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

procedure TWastRunnerTests.TestSimdModuleJudgedInvalidNotStaged;
var
  Item: TWastCommandResult;
begin
  { The vector body is now VALIDATED for real and rejected as invalid — no
    longer a staged carve-out. An empty expected string is a class-only
    match, so a genuinely invalid module passes assert_invalid; the point of
    the case is that the status is judged (pass), never 'staged'. }
  Item := FirstResult('(assert_invalid (module binary ' + MODULE_SIMD_BODY
    + ') "")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
  Expect<string>(WastErrorKindName(Item.ActualKind)).ToBe('invalid');
end;

procedure TWastRunnerTests.TestSimdModuleInstantiatesNotStaged;
var
  Run: TWastRunResult;
begin
  { A well-formed v128 module now assembles/validates/instantiates and
    passes at top level, and nothing in the script is counted as staged —
    the SIMD staging is gone (Track G). }
  Run := RunWastSource(MODULE_V128);
  try
    Expect<string>(WastStatusName(Run[0].Status)).ToBe('pass');
    Expect<Integer>(Run.Tally.Staged).ToBe(0);
  finally
    Run.Free;
  end;
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
  { Pass, fail, and skip in one run; a register with no current instance is
    the skip. SIMD no longer stages, so Staged is now 0 — the last command,
    a genuinely invalid v128 module under assert_invalid with a class-only
    (empty) expected, is a judged PASS, not a staged carve-out. }
  Run := RunWastSource(
    '(assert_malformed (module binary ' + MODULE_BAD_MAGIC
      + ') "magic header not detected")' + sLineBreak +
    '(assert_malformed (module binary ' + MODULE_BAD_MAGIC
      + ') "unknown binary version")' + sLineBreak +
    '(register "m")' + sLineBreak +
    '(assert_invalid (module binary ' + MODULE_SIMD_BODY + ') "")');
  try
    Tally := Run.Tally;
    Expect<Integer>(Run.Count).ToBe(4);
    Expect<Integer>(Tally.Pass).ToBe(2);
    Expect<Integer>(Tally.Fail).ToBe(1);
    Expect<Integer>(Tally.Skip).ToBe(1);
    { SIMD is no longer staged; only Track H's exception handling remains. }
    Expect<Integer>(Tally.Staged).ToBe(0);
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

procedure TWastRunnerTests.TestSpectestPrintFunctions;
begin
  { The pinned reference host exports seven no-result diagnostic functions.
    wasmlight keeps the harness quiet, but every exact signature must link and
    execute as a no-op rather than causing the module and its actions to skip. }
  Expect<string>(StatusSignature(
    '(module' + sLineBreak
    + '  (import "spectest" "print" (func $p))' + sLineBreak
    + '  (import "spectest" "print_i32" (func $pi32 (param i32)))'
    + sLineBreak
    + '  (import "spectest" "print_i64" (func $pi64 (param i64)))'
    + sLineBreak
    + '  (import "spectest" "print_f32" (func $pf32 (param f32)))'
    + sLineBreak
    + '  (import "spectest" "print_f64" (func $pf64 (param f64)))'
    + sLineBreak
    + '  (import "spectest" "print_i32_f32"'
    + '    (func $pi32f32 (param i32 f32)))' + sLineBreak
    + '  (import "spectest" "print_f64_f64"'
    + '    (func $pf64f64 (param f64 f64)))' + sLineBreak
    + '  (func (export "run")' + sLineBreak
    + '    (call $p)' + sLineBreak
    + '    (call $pi32 (i32.const 1))' + sLineBreak
    + '    (call $pi64 (i64.const 2))' + sLineBreak
    + '    (call $pf32 (f32.const 3))' + sLineBreak
    + '    (call $pf64 (f64.const 4))' + sLineBreak
    + '    (call $pi32f32 (i32.const 5) (f32.const 6))' + sLineBreak
    + '    (call $pf64f64 (f64.const 7) (f64.const 8))))' + sLineBreak
    + '(invoke "run")'))
    .ToBe('module:pass invoke:pass');
end;

procedure TWastRunnerTests.TestSpectestGlobals;
begin
  { Values and const mutability match interpreter/host/spectest.ml: integers
    are 666 and floating-point globals are their nearest 666.6 value. }
  Expect<string>(StatusSignature(
    '(module' + sLineBreak
    + '  (global (export "i32") (import "spectest" "global_i32") i32)'
    + sLineBreak
    + '  (global (export "i64") (import "spectest" "global_i64") i64)'
    + sLineBreak
    + '  (global (export "f32") (import "spectest" "global_f32") f32)'
    + sLineBreak
    + '  (global (export "f64") (import "spectest" "global_f64") f64))'
    + sLineBreak
    + '(assert_return (get "i32") (i32.const 666))' + sLineBreak
    + '(assert_return (get "i64") (i64.const 666))' + sLineBreak
    + '(assert_return (get "f32") (f32.const 666.6))' + sLineBreak
    + '(assert_return (get "f64") (f64.const 666.6))'))
    .ToBe('module:pass assert_return:pass assert_return:pass '
      + 'assert_return:pass assert_return:pass');
end;

procedure TWastRunnerTests.TestSpectestTablesAndMemory;
begin
  { The standard externals preserve their address types and initial sizes:
    i32/i64 tables both start at 10 entries; the i32 memory starts at 1 page. }
  Expect<string>(StatusSignature(
    '(module' + sLineBreak
    + '  (table $t (import "spectest" "table") 10 20 funcref)'
    + sLineBreak
    + '  (table $t64 (import "spectest" "table64")'
    + '    i64 10 20 funcref)' + sLineBreak
    + '  (memory $m (import "spectest" "memory") 1 2)' + sLineBreak
    + '  (func (export "ts") (result i32) (table.size $t))'
    + sLineBreak
    + '  (func (export "ts64") (result i64) (table.size $t64))'
    + sLineBreak
    + '  (func (export "ms") (result i32) (memory.size $m)))'
    + sLineBreak
    + '(assert_return (invoke "ts") (i32.const 10))' + sLineBreak
    + '(assert_return (invoke "ts64") (i64.const 10))' + sLineBreak
    + '(assert_return (invoke "ms") (i32.const 1))'))
    .ToBe('module:pass assert_return:pass assert_return:pass '
      + 'assert_return:pass');
end;

procedure TWastRunnerTests.TestSpectestMemoryIsShared;
begin
  { Per-script host state is shared: a store through one module's imported
    memory is observable through a later module importing the same memory. }
  Expect<string>(StatusSignature(
    '(module' + sLineBreak
    + '  (memory $m (import "spectest" "memory") 1 2)' + sLineBreak
    + '  (func (export "put")'
    + '    (i32.store8 (i32.const 7) (i32.const 42))))' + sLineBreak
    + '(invoke "put")' + sLineBreak
    + '(module' + sLineBreak
    + '  (memory $m (import "spectest" "memory") 1 2)' + sLineBreak
    + '  (func (export "get") (result i32)'
    + '    (i32.load8_u (i32.const 7))))' + sLineBreak
    + '(assert_return (invoke "get") (i32.const 42))'))
    .ToBe('module:pass invoke:pass module:pass assert_return:pass');
end;

procedure TWastRunnerTests.TestRegisteredSpectestReplacesBuiltinWholeModule;
const
  Src =
    '(module $replacement (func (export "print") (result i32) (i32.const 7)))'
    + sLineBreak + '(register "spectest" $replacement)' + sLineBreak
    + '(module (import "spectest" "print" (func $p (result i32)))'
    + ' (func (export "call") (result i32) (call $p)))' + sLineBreak
    + '(assert_return (invoke "call") (i32.const 7))';
var
  Run: TWastRunResult;
begin
  Run := RunWastSource(Src);
  try
    Expect<Integer>(Run.Count).ToBe(4);
    Expect<string>(WastStatusName(Run[2].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[3].Status)).ToBe('pass');
  finally
    Run.Free;
  end;
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

procedure TWastRunnerTests.TestModuleDefinitionDoesNotInstantiate;
begin
  { The maximum valid i32 memory is intentionally impractical to allocate.
    Definition formation validates it but must not create store state. }
  Expect<string>(StatusSignature(
    '(module definition (memory 65536))' + sLineBreak
    + '(module (func (export "ok") (result i32) (i32.const 1)))'
      + sLineBreak
    + '(assert_return (invoke "ok") (i32.const 1))'))
    .ToBe('module:pass module:pass assert_return:pass');
end;

procedure TWastRunnerTests.TestModuleInstancesAreGenerative;
const
  DEFINITION =
    '(module definition $M'
    + ' (global $g (export "g") (mut i32) (i32.const 0))'
    + ' (func (export "set") (global.set $g (i32.const 1))))';
begin
  { Both instances borrow one immutable definition but own distinct globals. }
  Expect<string>(StatusSignature(
    DEFINITION + sLineBreak
    + '(module instance $I1 $M)' + sLineBreak
    + '(module instance $I2 $M)' + sLineBreak
    + '(invoke $I1 "set")' + sLineBreak
    + '(assert_return (get $I1 "g") (i32.const 1))' + sLineBreak
    + '(assert_return (get $I2 "g") (i32.const 0))'))
    .ToBe('module:pass module:pass module:pass invoke:pass '
      + 'assert_return:pass assert_return:pass');
end;

procedure TWastRunnerTests.TestAnonymousModuleInstanceBecomesCurrent;
begin
  Expect<string>(StatusSignature(
    '(module definition $M'
    + ' (func (export "seven") (result i32) (i32.const 7)))'
      + sLineBreak
    + '(module instance $M)' + sLineBreak
    + '(assert_return (invoke "seven") (i32.const 7))'))
    .ToBe('module:pass module:pass assert_return:pass');
end;

procedure TWastRunnerTests.TestAssertTrapModuleOobSegmentPersists;
var
  Run: TWastRunResult;
begin
  { The instantiation-trap form, judged for real (exec-instantiation). An
    importer shares $M's memory; its first active data segment ("abc" at 0)
    is in bounds and is written, its second (offset 0x10000, past a 1-page
    memory) is out of bounds and traps. assert_trap PASSES on the trap, and
    the earlier write PERSISTS: the following assert_return reads 'a' (97)
    back through $M's own export. Mirrors linking.wast:399-411. }
  Run := RunWastSource(
    '(module $M (memory (export "mem") 1)' + sLineBreak
    + '  (func (export "load") (param i32) (result i32)' + sLineBreak
    + '    (i32.load8_u (local.get 0))))' + sLineBreak
    + '(register "M" $M)' + sLineBreak
    + '(assert_trap' + sLineBreak
    + '  (module' + sLineBreak
    + '    (memory (import "M" "mem") 1)' + sLineBreak
    + '    (data (i32.const 0) "abc")' + sLineBreak
    + '    (data (i32.const 0x10000) "z"))' + sLineBreak
    + '  "out of bounds memory access")' + sLineBreak
    + '(assert_return (invoke $M "load" (i32.const 0)) (i32.const 97))');
  try
    Expect<string>(WastStatusName(Run[2].Status)).ToBe('pass');
    ExpectStartsWith(Run[2].Actual, 'out of bounds memory access');
    { The persisted earlier segment is observable afterwards. }
    Expect<string>(WastStatusName(Run[3].Status)).ToBe('pass');
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestAssertTrapModuleTrappingStartPersists;
var
  Run: TWastRunResult;
begin
  { The module instantiates cleanly (its data segment is in bounds and is
    written into the shared memory), then its START function traps on
    `unreachable`. The tier runs the start, so the trap is judged; and the
    data written before the start persists — the store is modified even when
    the start traps (linking.wast:588-609). }
  Run := RunWastSource(
    '(module $S (memory (export "mem") 1)' + sLineBreak
    + '  (func (export "load") (param i32) (result i32)' + sLineBreak
    + '    (i32.load8_u (local.get 0))))' + sLineBreak
    + '(register "S" $S)' + sLineBreak
    + '(assert_trap' + sLineBreak
    + '  (module' + sLineBreak
    + '    (memory (import "S" "mem") 1)' + sLineBreak
    + '    (data (i32.const 0) "hello")' + sLineBreak
    + '    (func $main (unreachable))' + sLineBreak
    + '    (start $main))' + sLineBreak
    + '  "unreachable")' + sLineBreak
    + '(assert_return (invoke $S "load" (i32.const 0)) (i32.const 104))');
  try
    Expect<string>(WastStatusName(Run[2].Status)).ToBe('pass');
    ExpectStartsWith(Run[2].Actual, 'unreachable');
    { 'h' = 104 was written by the data segment before the start trapped. }
    Expect<string>(WastStatusName(Run[3].Status)).ToBe('pass');
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestAssertTrapModuleNoTrapReportsFail;
var
  Item: TWastCommandResult;
begin
  { A module that instantiates cleanly where the script demanded an
    instantiation trap. The absence of a trap is the finding, spelled the
    same way the action-trap path spells it. }
  Item := FirstResult(
    '(assert_trap (module (func)) "out of bounds memory access")');
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(Item.Expected).ToBe('out of bounds memory access');
  Expect<string>(Item.Actual).ToBe(WAST_NO_ERROR);
end;

{ --- SIMD execution (needs the interpreter's vector dispatch) ------------ }

procedure TWastRunnerTests.TestAssertReturnV128PerLane;
var
  Item: TWastCommandResult;
begin
  { The hand-assembled v128 module returns i8x16 lanes 0..15; the expected
    vector is compared lane by lane across the two result slots. }
  Item := ResultAt(MODULE_V128 + sLineBreak
    + '(assert_return (invoke "v")'
    + ' (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestAssertReturnV128WrongLaneFails;
var
  Item: TWastCommandResult;
begin
  { One diverging lane (lane 15 expected 99, produced 15) fails the whole
    result; the produced vector is rendered in v128.const notation. }
  Item := ResultAt(MODULE_V128 + sLineBreak
    + '(assert_return (invoke "v")'
    + ' (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 99))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  ExpectStartsWith(Item.Actual, '(v128.const i8x16');
end;

procedure TWastRunnerTests.TestV128ArgResultRoundTrip;
var
  Item: TWastCommandResult;
begin
  { A v128 argument occupies two marshal slots and a v128 result reads back
    from two slots; an identity function round-trips the exact lanes. }
  Item := ResultAt(
    '(module (func (export "id") (param v128) (result v128) (local.get 0)))'
    + sLineBreak
    + '(assert_return (invoke "id" (v128.const i32x4 10 20 30 40))'
    + ' (v128.const i32x4 10 20 30 40))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestRelaxedEitherResultMatches;
var
  Item: TWastCommandResult;
begin
  { The relaxed-SIMD `(either A B)` result form passes when the produced
    vector matches EITHER alternative — here the first. }
  Item := ResultAt(MODULE_V128 + sLineBreak
    + '(assert_return (invoke "v") (either'
    + ' (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)'
    + ' (v128.const i8x16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0)))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

{ --- exception handling (Track H) ---------------------------------------- }

procedure TWastRunnerTests.TestAssertExceptionPassesOnUncaughtThrow;
var
  Item: TWastCommandResult;
begin
  { `throw $e` with no enclosing try_table escapes the invocation as an
    uncaught exception (EWasmException). assert_exception asserts exactly
    that — the class alone, no expected tag/payload — so it PASSES. }
  Item := ResultAt(
    '(module (tag $e) (func (export "boom") (throw $e)))' + sLineBreak
    + '(assert_exception (invoke "boom"))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('pass');
end;

procedure TWastRunnerTests.TestAssertExceptionFailsWhenCaughtInternally;
var
  Item: TWastCommandResult;
begin
  { The function throws but its own `try_table (catch_all)` catches it and the
    invocation returns normally. No exception escapes, so assert_exception is
    NOT satisfied — a fail reporting that no error was raised. A caught
    exception must never count as an uncaught one. }
  Item := ResultAt(
    '(module (tag $e)' + sLineBreak
    + '  (func (export "safe")' + sLineBreak
    + '    (block $l (try_table (catch_all $l) (throw $e)))))' + sLineBreak
    + '(assert_exception (invoke "safe"))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  Expect<string>(Item.Actual).ToBe(WAST_NO_ERROR);
end;

procedure TWastRunnerTests.TestAssertExceptionFailsOnTrap;
var
  Item: TWastCommandResult;
begin
  { A trap is a SEPARATE outcome from a wasm exception (design §2.1): they
    travel different routes and never satisfy each other's assertion. An
    `unreachable` trap must therefore FAIL assert_exception, not pass it. }
  Item := ResultAt(
    '(module (func (export "t") (unreachable)))' + sLineBreak
    + '(assert_exception (invoke "t"))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  ExpectStartsWith(Item.Actual, 'unexpected trap:');
end;

procedure TWastRunnerTests.TestAssertReturnFailsOnUncaughtException;
var
  Item: TWastCommandResult;
begin
  { The complement of assert_exception: an uncaught exception under
    assert_return is a fail (not a trap, not a value). This pins the handler
    ORDER too — EWasmException is caught as wakException, before the generic
    EWasmError clause could swallow it as wakError. }
  Item := ResultAt(
    '(module (tag $e)' + sLineBreak
    + '  (func (export "boom") (result i32) (throw $e)))' + sLineBreak
    + '(assert_return (invoke "boom") (i32.const 0))', 1);
  Expect<string>(WastStatusName(Item.Status)).ToBe('fail');
  ExpectStartsWith(Item.Actual, 'unexpected exception:');
end;

{ --- baseline JIT corpus mode (Track I) --------------------------------- }

procedure TWastRunnerTests.TestTierModeName;
begin
  { The tier a run reports must be stable and unambiguous — wasmspec prints it
    in the TOTAL line. }
  Expect<string>(WastTierModeName(wtmInterp)).ToBe('interp');
  Expect<string>(WastTierModeName(wtmJit)).ToBe('jit');
  Expect<string>(WastTierModeName(wtmAot)).ToBe('aot');
end;

procedure TWastRunnerTests.TestDefaultModeCompilesNothing;
var
  Run: TWastRunResult;
begin
  { The default entry points are the pure interpreter: no JIT is registered, so
    nothing compiles and the milestone function runs and returns exactly as
    before. This is the zero-behaviour-change guarantee for every existing
    caller. }
  Run := RunWastSource(MODULE_JIT_ADD + sLineBreak
    + '(assert_return (invoke "add" (i32.const 17) (i32.const 25)) '
    + '(i32.const 42))');
  try
    Expect<string>(WastStatusName(Run[0].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[1].Status)).ToBe('pass');
    Expect<Integer>(Run.CompiledFuncCount).ToBe(0);
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestJitModeCompilesAndPasses;
var
  Run: TWastRunResult;
begin
  { Under --tier=jit the single compilable function is force-compiled after
    instantiation, so both invokes route through the compiled machine code via
    the CompiledEntry seam. The assert_returns still judge against the SPEC's
    expecteds: a pass means the JIT matched the spec (i.e. the interpreter). The
    wrap case (-1 + 1 = 0) exercises two's-complement wrap through the compiled
    add. On the aarch64 backend exactly one function is compiled; off it the
    predicate declines and the function runs interpreted (count 0) — still a
    pass, because that IS the interpreter. }
  Run := RunWastSource(MODULE_JIT_ADD + sLineBreak
    + '(assert_return (invoke "add" (i32.const 17) (i32.const 25)) '
    + '(i32.const 42))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const -1) (i32.const 1)) '
    + '(i32.const 0))', wtmJit);
  try
    Expect<string>(WastStatusName(Run[0].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[1].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[2].Status)).ToBe('pass');
    {$IFDEF WASM_JIT_BACKEND}
    { The function was ACTUALLY compiled — CompiledEntry set (§12.2). }
    Expect<Integer>(Run.CompiledFuncCount).ToBe(1);
    {$ELSE}
    Expect<Integer>(Run.CompiledFuncCount).ToBe(0);
    {$ENDIF}
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestJitModeMixedTiersCoexist;
var
  Run: TWastRunResult;
begin
  { A compilable and a (currently) non-compilable function in one module: under
    --tier=jit the compilable one tiers up while the other stays interpreted,
    and BOTH invokes return the correct value — compiled and interpreted code
    coexisting behind the seam within one instance. }
  Run := RunWastSource(MODULE_JIT_MIXED + sLineBreak
    + '(assert_return (invoke "add" (i32.const 40) (i32.const 2)) '
    + '(i32.const 42))' + sLineBreak
    + '(assert_return (invoke "seven") (i32.const 7))', wtmJit);
  try
    Expect<string>(WastStatusName(Run[0].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[1].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[2].Status)).ToBe('pass');
    {$IFDEF WASM_JIT_BACKEND}
    { At least the "add" function compiled; it coexists with the interpreted
      "seven" (or, once coverage grows, both compile — still >= 1). }
    Expect<Boolean>(Run.CompiledFuncCount >= 1).ToBe(True);
    {$ELSE}
    Expect<Integer>(Run.CompiledFuncCount).ToBe(0);
    {$ENDIF}
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestJitTallyIdenticalToInterp;
const
  { A compilable module, one passing assert and one DELIBERATELY-wrong-expected
    assert. The wrong expected is a mismatch of the SCRIPT, not a JIT
    divergence, so both tiers must fail it identically — the whole invariant in
    one script: the JIT tally equals the interpreter tally, verdict for verdict
    (§11.3). If the compiled add ever diverged, the pass would flip to a fail
    here and the tallies would differ. }
  Src =
    '(module (func (export "add") (param i32 i32) (result i32)'
    + ' (i32.add (local.get 0) (local.get 1))))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const 1) (i32.const 2)) '
    + '(i32.const 3))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const 1) (i32.const 2)) '
    + '(i32.const 999))';
var
  InterpRun, JitRun: TWastRunResult;
begin
  InterpRun := RunWastSource(Src, wtmInterp);
  try
    JitRun := RunWastSource(Src, wtmJit);
    try
      { Verdict-for-verdict identity: the JIT changed no outcome. }
      Expect<Integer>(JitRun.Tally.Pass).ToBe(InterpRun.Tally.Pass);
      Expect<Integer>(JitRun.Tally.Fail).ToBe(InterpRun.Tally.Fail);
      Expect<Integer>(JitRun.Tally.Skip).ToBe(InterpRun.Tally.Skip);
      Expect<Integer>(JitRun.Tally.Staged).ToBe(InterpRun.Tally.Staged);
      { And the shape is what we intended: module pass, one assert pass, one
        assert fail — under BOTH tiers. }
      Expect<Integer>(InterpRun.Tally.Pass).ToBe(2);
      Expect<Integer>(InterpRun.Tally.Fail).ToBe(1);
    finally
      JitRun.Free;
    end;
  finally
    InterpRun.Free;
  end;
end;

{ --- AOT corpus mode (Track J, aot-spec §5.1) --------------------------- }

procedure TWastRunnerTests.TestAotModeLoadsAndPasses;
var
  Run: TWastRunResult;
begin
  { Under --tier=aot the compilable function is AOT-compiled, SERIALIZED to a
    `.waot` buffer, and LOADED back — its CompiledEntry wired from the parsed
    artifact bytes, not a live JIT compile — before the invokes run. Both
    assert_returns judge against the SPEC's expecteds, so a pass means the
    AOT-loaded code matched the interpreter through the full round-trip. On the
    backend leg exactly one function is loaded; off it the predicate declines and
    the function interprets (count 0) — still a pass. }
  Run := RunWastSource(MODULE_JIT_ADD + sLineBreak
    + '(assert_return (invoke "add" (i32.const 17) (i32.const 25)) '
    + '(i32.const 42))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const -1) (i32.const 1)) '
    + '(i32.const 0))', wtmAot);
  try
    Expect<string>(WastStatusName(Run[0].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[1].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[2].Status)).ToBe('pass');
    {$IFDEF WASM_JIT_BACKEND}
    { The function was ACTUALLY AOT-loaded — CompiledEntry set from the
      artifact. }
    Expect<Integer>(Run.CompiledFuncCount).ToBe(1);
    {$ELSE}
    Expect<Integer>(Run.CompiledFuncCount).ToBe(0);
    {$ENDIF}
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestAotModeMixedTiersCoexist;
  { Handler tables and wide non-tail calls compile, so the declined fixture
    is a return_call one past WASM_TIER_TAIL_CAP. $wide compiles; "declined"
    stays interpreted. }
  function MixedAotModule: string;
  var
    I: Integer;
    Params, Args: string;
  begin
    Params := '';
    Args := '';
    for I := 1 to WASM_TIER_TAIL_CAP + 1 do
    begin
      Params := Params + ' i32';
      Args := Args + ' (i32.const 0)';
    end;
    Result :=
      '(module'
      + ' (func (export "add") (param i32 i32) (result i32)'
      + '   (i32.add (local.get 0) (local.get 1)))'
      + ' (func $wide (param' + Params + ') (result i32) (i32.const 7))'
      + ' (func (export "declined") (result i32) (return_call $wide' + Args + ')))';
  end;
var
  Run: TWastRunResult;
begin
  { Invoke only compiled exports. The declined return_call is past the
    shared tail/marshal cap, so running it would raise EWasmInternal rather
    than return 7. Coexistence is the compile-count split. }
  Run := RunWastSource(MixedAotModule + sLineBreak
    + '(assert_return (invoke "add" (i32.const 40) (i32.const 2)) '
    + '(i32.const 42))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const 1) (i32.const 6)) '
    + '(i32.const 7))', wtmAot);
  try
    Expect<string>(WastStatusName(Run[0].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[1].Status)).ToBe('pass');
    Expect<string>(WastStatusName(Run[2].Status)).ToBe('pass');
    {$IFDEF WASM_JIT_BACKEND}
    { "add" and $wide AOT-loaded; "declined" stays interpreted. }
    Expect<Integer>(Run.CompiledFuncCount).ToBe(2);
    {$ELSE}
    Expect<Integer>(Run.CompiledFuncCount).ToBe(0);
    {$ENDIF}
  finally
    Run.Free;
  end;
end;

procedure TWastRunnerTests.TestAotTallyIdenticalToInterp;
const
  { The same one-pass/one-deliberately-wrong script the JIT identity test uses:
    the wrong expected is a SCRIPT mismatch, not an AOT divergence, so both tiers
    must fail it identically. If the AOT round-trip ever corrupted the code, the
    pass would flip to a fail here and the tallies would differ. }
  Src =
    '(module (func (export "add") (param i32 i32) (result i32)'
    + ' (i32.add (local.get 0) (local.get 1))))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const 1) (i32.const 2)) '
    + '(i32.const 3))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const 1) (i32.const 2)) '
    + '(i32.const 999))';
var
  InterpRun, AotRun: TWastRunResult;
begin
  InterpRun := RunWastSource(Src, wtmInterp);
  try
    AotRun := RunWastSource(Src, wtmAot);
    try
      { Verdict-for-verdict identity: the AOT round-trip changed no outcome. }
      Expect<Integer>(AotRun.Tally.Pass).ToBe(InterpRun.Tally.Pass);
      Expect<Integer>(AotRun.Tally.Fail).ToBe(InterpRun.Tally.Fail);
      Expect<Integer>(AotRun.Tally.Skip).ToBe(InterpRun.Tally.Skip);
      Expect<Integer>(AotRun.Tally.Staged).ToBe(InterpRun.Tally.Staged);
      Expect<Integer>(InterpRun.Tally.Pass).ToBe(2);
      Expect<Integer>(InterpRun.Tally.Fail).ToBe(1);
    finally
      AotRun.Free;
    end;
  finally
    InterpRun.Free;
  end;
end;

procedure TWastRunnerTests.TestAotLoadedCountMatchesJit;
const
  Src =
    '(module'
    + ' (func (export "add") (param i32 i32) (result i32)'
    + '   (i32.add (local.get 0) (local.get 1)))'
    + ' (func (export "seven") (result i32) (i32.const 7)))' + sLineBreak
    + '(assert_return (invoke "add" (i32.const 40) (i32.const 2)) '
    + '(i32.const 42))' + sLineBreak
    + '(assert_return (invoke "seven") (i32.const 7))';
var
  JitRun, AotRun: TWastRunResult;
begin
  { The same predicate compiles the same functions, so the number AOT LOADS must
    equal the number the JIT COMPILES — the corpus-wide loaded=N == compiled=N
    claim (aot-spec §5.1) at unit scale. }
  JitRun := RunWastSource(Src, wtmJit);
  try
    AotRun := RunWastSource(Src, wtmAot);
    try
      Expect<Integer>(AotRun.CompiledFuncCount).ToBe(JitRun.CompiledFuncCount);
      {$IFDEF WASM_JIT_BACKEND}
      { Both "add" and "seven" are compilable, so the count is a positive 2 on
        the backend leg — not a vacuous 0 = 0. }
      Expect<Integer>(AotRun.CompiledFuncCount).ToBe(2);
      {$ELSE}
      Expect<Integer>(AotRun.CompiledFuncCount).ToBe(0);
      {$ENDIF}
    finally
      AotRun.Free;
    end;
  finally
    JitRun.Free;
  end;
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
  Test('a rejected SIMD module under the wrong class reports a fail',
    TestSimdModuleWrongClassReportsFail);
  Test('top-level binary module passes', TestTopLevelBinaryModulePasses);
  Test('top-level binary module failure is reported',
    TestTopLevelBinaryModuleFailureReported);
  Test('text module assembles and passes', TestTextModuleAssembles);
  Test('quoted module assembles and passes', TestQuotedModuleAssembles);
  Test('assert_malformed over a text operand passes on a text error',
    TestAssertMalformedTextOperandPasses);
  Test('assert_malformed over a well-formed text operand fails',
    TestAssertMalformedTextNotMalformedFails);
  Test('assert_invalid over a text operand passes on validation',
    TestAssertInvalidTextOperandPasses);
  Test('a vector mnemonic in a text module validates and passes',
    TestSimdTextModuleValidates);
  Test('assert_unlinkable passes on an incompatible import',
    TestAssertUnlinkablePasses);
  Test('assert_unlinkable passes on an unknown import',
    TestAssertUnlinkableUnknownImportPasses);
  Test('assert_unlinkable passes on a wrong-kind import',
    TestAssertUnlinkableWrongKindPasses);
  Test('assert_unlinkable reports a fail on a wrong prefix',
    TestAssertUnlinkableWrongPrefixFails);
  Test('assert_unlinkable reports a fail when linkage succeeds',
    TestAssertUnlinkableLinkableModuleFails);
  Test('an inline module body runs as one module',
    TestInlineModuleBodyRunsAsOneModule);
  Test('unknown directive skipped', TestUnknownDirectiveSkipped);
  Test('execution commands skipped', TestExecutionCommandsSkipped);
  Test('assert without a module operand skipped',
    TestAssertWithoutModuleOperandSkipped);
  Test('a SIMD module is judged invalid, not staged',
    TestSimdModuleJudgedInvalidNotStaged);
  Test('a well-formed SIMD module instantiates and nothing stages',
    TestSimdModuleInstantiatesNotStaged);
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
  Test('spectest print functions link and execute',
    TestSpectestPrintFunctions);
  Test('spectest globals carry the pinned values', TestSpectestGlobals);
  Test('spectest tables and memory carry pinned limits',
    TestSpectestTablesAndMemory);
  Test('spectest memory is shared for the whole script',
    TestSpectestMemoryIsShared);
  Test('a registered spectest replaces the built-in whole module',
    TestRegisteredSpectestReplacesBuiltinWholeModule);
  Test('register binds an instance for cross-module import',
    TestCrossModuleRegisterImport);
  Test('module definition validates without instantiating',
    TestModuleDefinitionDoesNotInstantiate);
  Test('module instances are fresh and generative',
    TestModuleInstancesAreGenerative);
  Test('anonymous module instance becomes current',
    TestAnonymousModuleInstanceBecomesCurrent);
  Test('assert_trap over a module judges an OOB segment and persists earlier',
    TestAssertTrapModuleOobSegmentPersists);
  Test('assert_trap over a module judges a trapping start and persists data',
    TestAssertTrapModuleTrappingStartPersists);
  Test('assert_trap over a non-trapping module reports a fail',
    TestAssertTrapModuleNoTrapReportsFail);

  Test('assert_return compares a v128 result per lane',
    TestAssertReturnV128PerLane);
  Test('assert_return fails on a wrong v128 lane',
    TestAssertReturnV128WrongLaneFails);
  Test('a v128 argument and result round-trip across two slots',
    TestV128ArgResultRoundTrip);
  Test('a relaxed (either ...) result matches an alternative',
    TestRelaxedEitherResultMatches);

  Test('assert_exception passes on an uncaught throw',
    TestAssertExceptionPassesOnUncaughtThrow);
  Test('assert_exception fails when the throw is caught internally',
    TestAssertExceptionFailsWhenCaughtInternally);
  Test('assert_exception fails on a trap (separate routes)',
    TestAssertExceptionFailsOnTrap);
  Test('assert_return fails on an uncaught exception',
    TestAssertReturnFailsOnUncaughtException);

  Test('tier mode name is stable', TestTierModeName);
  Test('default mode compiles nothing and is unchanged',
    TestDefaultModeCompilesNothing);
  Test('--tier=jit compiles the function and passes against the spec',
    TestJitModeCompilesAndPasses);
  Test('--tier=jit lets compiled and interpreted functions coexist',
    TestJitModeMixedTiersCoexist);
  Test('the --tier=jit tally is identical to the interpreter tally',
    TestJitTallyIdenticalToInterp);

  Test('--tier=aot serializes, loads, and passes against the spec',
    TestAotModeLoadsAndPasses);
  Test('--tier=aot lets AOT-loaded and interpreted functions coexist',
    TestAotModeMixedTiersCoexist);
  Test('the --tier=aot tally is identical to the interpreter tally',
    TestAotTallyIdenticalToInterp);
  Test('the --tier=aot loaded count equals the --tier=jit compiled count',
    TestAotLoadedCountMatchesJit);
end;

begin
  TestRunnerProgram.AddSuite(TWastRunnerTests.Create('Wasm.Wast.Runner'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
