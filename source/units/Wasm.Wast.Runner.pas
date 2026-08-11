{ Wasm.Wast.Runner — executes a parsed `.wast` script against the layers
  this project has shipped, and reports what it could not judge.

  Track C's runner (docs/roadmap.md), now with the interpreter tier wired
  in (Track E; interp-spec §6). Wasm.Wast is the front end — lexer,
  s-expression parser, command classifier — and keeps module payloads as
  raw trees. This unit turns those trees into verdicts, and now RUNS the
  action and result assertions rather than skipping them.

  WHAT IS JUDGED. Decode (Wasm.Decoder), validation (Wasm.Validator),
  execution (Wasm.Interp), and now the text-format assembler
  (Wasm.Wat.Assembler) are shipped. Text `(module ...)` and `(module quote
  ...)` forms ASSEMBLE to bytes and re-enter the shipped decode -> validate
  -> instantiate path (design §1), so the judged shapes no longer need
  `(module binary ...)`:

    - `(module ...)` / `(module quote ...)` / `(module binary ...)` at top
      level — assemble (text/quote), decode, validate, INSTANTIATE, run any
      start function
    - `(assert_malformed (module ...) "...")` — a BINARY operand expects
      EWasmDecodeError; a TEXT/QUOTE operand expects EWasmTextError from the
      assembler. A decode error on the assembler's OWN output is INV-1
      violated — reported as `internal`, never scored as malformed (§4)
    - `(assert_invalid (module ...) "...")` — the module must ASSEMBLE, then
      EWasmValidationError
    - `(register "name" $id?)`, `(invoke ...)`, `(assert_return ...)`,
      `(assert_trap (invoke ...) ...)`, `(assert_exhaustion ...)` — run and
      compare, now over text modules too (they instantiate like binary ones)
    - `(assert_trap (module ...) "...")` / `(assert_exhaustion (module ...)
      "...")` — the INSTANTIATION-trap form. The module is built and
      instantiated for real: active elem/data segments apply in module
      order, an out-of-bounds one traps (`exec-instantiation`), and the
      earlier in-bounds segments PERSIST in the (imported/shared) store for
      later commands — the rule linking.wast:399-411 documents. A start
      function is run through the tier, so a trapping start is judged too.
      The trap message is prefix-matched like an action trap

  Still SKIPPED, never silently a pass: `assert_unlinkable` (a pre-check
  assembles+validates the operand — a false rejection there is a FAIL, §4 —
  but linkage we cannot yet judge), an `assert_return`/`invoke` whose module
  never instantiated, imports the harness cannot satisfy (no host `spectest`
  module), and the `_custom` directives outside the reference grammar. A
  skip is an honest "not judged".

  THE PER-SCRIPT LIFECYCLE. One engine and one store back a whole script,
  mirroring the reference interpreter's per-script state. Modules
  instantiate lazily at command time into that store, so a later module can
  import an earlier registered one directly (same store, same addresses).
  The store owns the instances; the retained IR modules and byte buffers
  outlive them (ADR-0003) and are freed after the store.

  THE MATCH IS A PREFIX MATCH. The reference interpreter checks that the
  script's expected string is a PREFIX of the implementation's message, for
  both the malformed/invalid classes and the runtime trap messages. Running
  this corpus is what settles those prefixes, so a fail records BOTH strings.

  STAGED. Nothing stages any more. `$FD` vector work assembles, validates,
  and executes (Track G), and exception handling now throws, unwinds, and is
  judged (Track H): `assert_exception` is a real verdict and an uncaught guest
  exception surfaces as EWasmException, so the `wrsStaged` status is retained
  only as the harness's honest "would fail on deliberately staged work" bucket
  and is left unused — the `staged` column reads 0 across the corpus. }
unit Wasm.Wast.Runner;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Aot,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit,
  Wasm.Module,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator,
  Wasm.Wast,
  Wasm.Wast.Values,
  Wasm.Wat.Assembler;

const
  { Skip reasons. Public because they are the honest boundary of what the
    harness can judge, and the tests assert on them rather than on prose
    spelled twice.

    WAST_REASON_TEXT_FORMAT is gone (design §4, wave 6): text and quote
    modules now assemble through Wasm.Wat.Assembler and re-enter the shipped
    decode -> validate -> instantiate path, so a text module is no longer a
    skip — it is judged, exactly like a binary one. What still skips are the
    genuinely-unjudgeable cases below (no instance, unresolved host import,
    linkage we cannot check without more plumbing). }
  WAST_REASON_NEEDS_TIER = 'needs an execution tier';
  WAST_REASON_UNKNOWN_DIRECTIVE = 'directive not in the reference grammar';
  WAST_REASON_NO_MODULE_OPERAND = 'no module operand';

  { An action or assertion whose current module never instantiated — a text
    module, or one whose imports could not be satisfied. Not a divergence,
    just nothing to run it against. }
  WAST_REASON_NO_INSTANCE = 'no instantiated module';
  WAST_REASON_UNRESOLVED_IMPORT = 'import not provided by the harness';
  WAST_REASON_NO_EXPORT = 'no such export';

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

  { Which execution tier a run drives (.agent/design/jit-spec.md §11, §12.3).

    wtmInterp is the DEFAULT and the tier of record (ADR-0001): no JIT is
    registered, every function runs interpreted, and every corpus number is
    exactly what it was before this mode existed — the opt-in JIT changes
    nothing unless asked for.

    wtmJit registers the baseline JIT on the per-script store and FORCE-COMPILES
    every compilable function of each instantiated module (§11.1's force-tier
    control, threshold effectively 1). The compiled functions are then invoked
    transparently through the CompiledEntry seam; anything the compile predicate
    (JitCanCompile) declines stays interpreted, which is correct because it IS
    the interpreter. The corpus's assert_return/assert_trap expecteds — the
    spec's values, which the interpreter already matches — become the JIT's
    conformance net at zero authoring cost (§11.3): a wtmJit run MUST produce a
    tally identical to a wtmInterp run over the same scripts, because the
    compiled functions match the spec and the declined rest ARE the interpreter.
    Any divergence is a JIT bug the corpus surfaces as a fail with file:line +
    expected/actual.

    wtmAot is the third tier (aot-spec §5.1). It does NOT re-run the JIT and
    rename it: per built module it AotCompileModule's every compilable function
    to position-independent bytes, SERIALIZES them into a `.waot` byte buffer,
    then in the SAME per-script store AotLoadAndWire's that buffer — re-checking
    every guard (irVer/arch/abi/checksum/moduleHash), mapping the code
    executable, and wiring each CompiledEntry from the loaded bytes. So the
    assertions that follow route through code that made the full
    serialize -> parse+guard -> map -> execute round-trip, not a live JIT
    compile — a serialization/format bug would surface here. The artifact is
    compiled from and re-validated against the SAME IR the runner already
    decoded+validated (the security boundary is the runner's own decode+validate,
    aot-spec §2.4/§8), so in-process the moduleHash guard passes trivially while
    the CODE PATH is the real one. Like wtmJit, a wtmAot run MUST produce a tally
    identical to wtmInterp, and the loaded-function count MUST equal wtmJit's
    compiled count (the same predicate compiles the same functions); any
    divergence is an AOT serialize/load bug. }
  TWastTierMode = (wtmInterp, wtmJit, wtmAot);

  { Which error class a module attempt produced. The hierarchy is
    load-bearing (AGENTS.md): malformed and invalid are different answers.
    wekText is a TEXT-format syntax error from the assembler — what
    `assert_malformed` over a text/quote module expects, kept apart from
    wekDecode so a decode error on the assembler's OWN output can be flagged
    as an internal bug rather than scored as malformed (INV-1, design §4).
    wekOther is anything else — reported as a failure (kind `internal`)
    rather than allowed to abort the run. }
  TWastErrorKind = (
    wekNone,
    wekDecode,
    wekValidation,
    wekText,
    wekOther
  );

  TWastCommandResult = record
    Kind: TWastCommandKind;
    { 1-based line of the command's opening parenthesis. }
    Line: Integer;
    Status: TWastStatus;
    { The script's expected failure string (or rendered expected results);
      '' when the command is not an assertion. }
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
    FCompiledFuncCount: Integer;

    function GetResult(const AIndex: Integer): TWastCommandResult;
  public
    constructor Create;

    procedure AddResult(const AResult: TWastCommandResult);
    function Count: Integer;

    property Results[const AIndex: Integer]: TWastCommandResult
      read GetResult; default;
    property Tally: TWastTally read FTally;
    { How many wasm functions this script actually JIT-compiled (a distinct
      function counted once). Zero in wtmInterp mode and on a target/op-set the
      backend cannot emit; a positive count is the evidence that the JIT path
      was exercised rather than silently all-interpreted (§11.3, §12.3). }
    property CompiledFuncCount: Integer read FCompiledFuncCount;
  end;

{ Run every command of AScript in order. Never raises for a command
  outcome — a command that cannot be judged is a skip and a command that
  fails is a failure, both recorded. The no-mode overload runs the pure
  interpreter (wtmInterp), so every existing caller is byte-for-byte
  unchanged; the mode overload selects the tier (§11, §12.3). }
function RunWastScript(const AScript: TWastScript): TWastRunResult; overload;
function RunWastScript(const AScript: TWastScript;
  const AMode: TWastTierMode): TWastRunResult; overload;

{ Parse ASource and run it. Raises EWastParseError when the SCRIPT itself
  is malformed. }
function RunWastSource(const ASource: string): TWastRunResult; overload;
function RunWastSource(const ASource: string;
  const AMode: TWastTierMode): TWastRunResult; overload;

{ Read APath and run it. }
function RunWastFile(const APath: string): TWastRunResult; overload;
function RunWastFile(const APath: string;
  const AMode: TWastTierMode): TWastRunResult; overload;

function WastStatusName(const AStatus: TWastStatus): string;
function WastErrorKindName(const AKind: TWastErrorKind): string;
function WastTierModeName(const AMode: TWastTierMode): string;

{ True when AExpected is a prefix of AActual — the reference interpreter's
  rule for failure and trap strings. }
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
  { Growth by doubling — the corpus outliers are 11,676-line SIMD files. }
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
    wekText: Result := 'text';
    wekOther: Result := 'internal';
  else
    Result := '?';
  end;
end;

function WastTierModeName(const AMode: TWastTierMode): string;
begin
  case AMode of
    wtmInterp: Result := 'interp';
    wtmJit: Result := 'jit';
    wtmAot: Result := 'aot';
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

{ The bytes of a string node as text. Expected strings and export names are
  ASCII in the corpus; a byte-per-char copy keeps whatever is there visible. }
function BytesToText(const ABytes: TWasmBytes): string;
var
  I: Integer;
begin
  SetLength(Result, Length(ABytes));
  for I := 0 to High(ABytes) do
    Result[I + 1] := Chr(ABytes[I]);
end;

{ The concatenation of every string literal in a `(module binary ...)`
  form — the module's bytes. }
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

{ Re-render a parsed node back to `.wat` SOURCE BYTES the assembler can lex.

  Wasm.Wast does not retain source spans, so a text `(module ...)` operand is
  reconstructed from its tree. Atoms carry their verbatim source spelling, so
  they copy through; string bytes are re-ESCAPED as `\hh` for every byte that
  is not printable ASCII (and for `"`/`\`), which round-trips exactly and keeps
  the assembler's strict UTF-8 source lexer from tripping over raw data-string
  bytes. Trivia the script lexer already dropped (comments, annotations) does
  not come back — harmless for the well-formed text modules that reach this
  path (top-level and assert_invalid operands). `assert_malformed` never gets
  here: its operands are `(module quote ...)`, whose exact bytes flow straight
  to AssembleQuote. }
procedure RenderNodeInto(const ANode: TWastNode; var ADst: string);
const
  HEX = '0123456789abcdef';
var
  I: Integer;
  B: Byte;
begin
  case ANode.Kind of
    wnkAtom:
      ADst := ADst + ANode.Atom;
    wnkString:
      begin
        ADst := ADst + '"';
        for I := 0 to High(ANode.Bytes) do
        begin
          B := ANode.Bytes[I];
          if (B >= $20) and (B < $7F) and (B <> Ord('"')) and (B <> Ord('\')) then
            ADst := ADst + Chr(B)
          else
            ADst := ADst + '\' + HEX[(B shr 4) + 1] + HEX[(B and $F) + 1];
        end;
        ADst := ADst + '"';
      end;
  else
    begin
      ADst := ADst + '(';
      for I := 0 to ANode.Count - 1 do
      begin
        if I > 0 then
          ADst := ADst + ' ';
        RenderNodeInto(ANode[I], ADst);
      end;
      ADst := ADst + ')';
    end;
  end;
end;

function RenderNodeBytes(const ANode: TWastNode): TWasmBytes;
var
  S: string;
  I: Integer;
begin
  S := '';
  RenderNodeInto(ANode, S);
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Byte(Ord(S[I]));
end;

{ The `(module ...)` operand of an assertion, nil when there is none. }
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
  literal. }
function ExpectedFailure(const ANode: TWastNode): string;
var
  I: Integer;
begin
  Result := '';
  for I := ANode.Count - 1 downto 1 do
    if ANode[I].Kind = wnkString then
      Exit(BytesToText(ANode[I].Bytes));
end;

{ A rough re-render of a node for a report — the s-expr text, enough to see
  which expected value or action diverged. }
function NodeText(const ANode: TWastNode): string;
var
  I: Integer;
begin
  case ANode.Kind of
    wnkAtom: Result := ANode.Atom;
    wnkString: Result := '"' + BytesToText(ANode.Bytes) + '"';
  else
    begin
      Result := '(';
      for I := 0 to ANode.Count - 1 do
      begin
        if I > 0 then
          Result := Result + ' ';
        Result := Result + NodeText(ANode[I]);
      end;
      Result := Result + ')';
    end;
  end;
end;

{ --- module attempts (malformed / invalid; IR discarded) ----------------- }

{ Decode then validate ABytes, reporting which class of error came out. Used
  by the assert_malformed / assert_invalid paths, which never instantiate,
  so the IR is discarded here. }
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

{ Decode then validate ABYTES that the assembler produced. Same shape as
  AttemptModule, but a decode error here is INV-1 violated — the assembler's
  own output must decode — so it is reported as wekOther (`internal`), never
  as wekDecode, so a mis-assembly that happens to trip a decode rule with a
  matching message can never be scored as a malformed pass (design §4). }
function AttemptAssembledModule(const ABytes: TWasmBytes;
  const AModule: TWasmModule; out AMessage: string): TWastErrorKind;
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
        Result := wekOther;
        AMessage := 'internal: assembler output failed to decode: ' + E.Message;
      end;
      on E: EWasmValidationError do
      begin
        Result := wekValidation;
        AMessage := E.Message;
      end;
      on E: Exception do
      begin
        Result := wekOther;
        AMessage := 'internal: ' + E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    Ir.Free;
  end;
end;

type
  { The outcome of assembling a text/quote operand. }
  TWatAssembleStatus = (
    wasOk,         { bytes produced — ABytes filled }
    wasTextError,  { a real EWasmTextError — ABytes is invalid }
    wasInternal    { the assembler raised something other than a text error }
  );

{ Assemble a TEXT or QUOTE module operand to binary bytes. A quote operand's
  payload is the concatenated, escape-decoded string bytes (ModuleBinaryBytes
  gathers them by node kind), fed to AssembleQuote; a text operand is rendered
  back to source (RenderNodeBytes) and fed to AssembleWat. Lazy by
  construction: nothing is assembled until the command executes, and there is
  no caching — the same quoted text may appear in two commands with opposite
  expectations (design §5). }
function AssembleOperand(const ANode: TWastNode; const AForm: TWastModuleForm;
  out ABytes: TWasmBytes; out AMsg: string): TWatAssembleStatus;
begin
  ABytes := nil;
  AMsg := '';
  try
    if AForm = wmfQuote then
      ABytes := AssembleQuote(ModuleBinaryBytes(ANode))
    else
      ABytes := AssembleWat(RenderNodeBytes(ANode));
    Result := wasOk;
  except
    on E: EWasmTextError do
    begin
      AMsg := E.Message;
      Result := wasTextError;
    end;
    on E: Exception do
    begin
      { The assembler contract is that it raises only EWasmTextError; anything
        else is an internal defect, surfaced as such rather than aborting the
        run. }
      AMsg := 'internal: ' + E.ClassName + ': ' + E.Message;
      Result := wasInternal;
    end;
  end;
end;

{ The full module-operand attempt across all three forms, WITHOUT
  instantiating: binary decodes directly; text/quote assemble first (a text
  error becomes wekText), then decode + validate the produced bytes. }
function AttemptOperand(const AModel: TWasmModule; const AOperand: TWastNode;
  const AForm: TWastModuleForm; out AMsg: string): TWastErrorKind;
var
  Bytes: TWasmBytes;
begin
  if AForm = wmfBinary then
  begin
    Result := AttemptModule(ModuleBinaryBytes(AOperand), AModel, AMsg);
    Exit;
  end;

  case AssembleOperand(AOperand, AForm, Bytes, AMsg) of
    wasTextError:
      Exit(wekText);
    wasInternal:
      Exit(wekOther);
  end;

  Result := AttemptAssembledModule(Bytes, AModel, AMsg);
end;

{ --- per-script runner state --------------------------------------------- }

type
  TWastBinding = record
    Name: string;
    Instance: TWasmModuleInstance;
  end;

  TWastHostRef = record
    Id: UInt32;
    Ref: TWasmRef;
  end;

  { One engine/store for a whole script, plus the name registries and the
    retained IR/byte buffers instances borrow. }
  TWastRunner = class
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FModel: TWasmModule;             { reused decode model }
    FCurrent: TWasmModuleInstance;   { last instantiated, nil if none }
    FNamed: array of TWastBinding;   { by $id (with the leading $) }
    FRegistry: array of TWastBinding;{ by register name }
    FHostRefs: array of TWastHostRef;
    { Instances borrow these; they must outlive the store (ADR-0003). }
    FIrs: array of TWasmIrModule;
    FBuffers: array of TWasmBytes;
    { The tier this script runs. wtmInterp leaves FJit nil and touches
      nothing; wtmJit registers the baseline JIT below and force-compiles each
      module's functions after it instantiates; wtmAot AOT-compiles each module,
      serializes it, and loads it back — see FAotJits. }
    FMode: TWastTierMode;
    FJit: TWasmJitContext;           { OWNED, nil unless wtmJit }
    { The AOT load contexts, one per module loaded in wtmAot mode (AotLoadAndWire
      mints a fresh context per load). OWNED — freed before the store, the same
      teardown discipline as FJit; empty in the other modes. }
    FAotJits: array of TWasmJitContext;
    FCompiledCount: Integer;         { distinct functions compiled OR AOT-loaded }
  public
    constructor Create; overload;
    constructor Create(const AMode: TWastTierMode); overload;
    destructor Destroy; override;

    function LookupNamed(const AId: string): TWasmModuleInstance;
    function LookupRegistry(const AName: string): TWasmModuleInstance;
    procedure BindNamed(const AId: string; const AInst: TWasmModuleInstance);
    procedure RegisterName(const AName: string;
      const AInst: TWasmModuleInstance);
    { Mint (once) and return a stable host box carrying identity AId, kept
      alive as a root for the life of the script. }
    function HostRef(const AId: UInt32): TWasmRef;
    { In wtmJit mode, force-compile every compilable wasm function reachable
      through AInst's function index space (§11.1). A no-op in wtmInterp mode or
      when the compile predicate declines every op the function uses — in which
      case the function stays interpreted, which is correct and identical. }
    procedure ForceCompileInstance(const AInst: TWasmModuleInstance);
    { In wtmAot mode, AOT-compile AInst's module (AIr freshly validated, ABytes
      the source it was validated from) to a `.waot` byte buffer, then load that
      buffer back into the store and wire each compiled function's CompiledEntry
      from it (aot-spec §5.1). Every guard is re-checked and the code makes the
      full serialize -> parse -> map round-trip through the real artifact bytes,
      so this is not a JIT compile in disguise. A no-op in the other modes or if
      a guard rejects (the functions then stay interpreted, which is correct and
      shows up as a lower loaded count). }
    procedure AotLoadInstance(const AInst: TWasmModuleInstance;
      const AIr: TWasmIrModule; const ABytes: TWasmBytes);

    property Engine: TWasmEngine read FEngine;
    property Store: TWasmStore read FStore;
    property Model: TWasmModule read FModel;
    property Current: TWasmModuleInstance read FCurrent write FCurrent;
    property CompiledCount: Integer read FCompiledCount;
  end;

constructor TWastRunner.Create;
begin
  Create(wtmInterp);
end;

constructor TWastRunner.Create(const AMode: TWastTierMode);
begin
  inherited Create;
  FMode := AMode;
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  RegisterInterpreter(FStore);
  FModel := TWasmModule.Create;
  FCurrent := nil;
  FJit := nil;
  FCompiledCount := 0;
  { Register the JIT companion on the store (§4.1): it points the store's
    JitInvokeCompiled hook at the compiled-function dispatcher but leaves
    TierInvoke on the interpreter and compiles nothing until a function is
    force-compiled. Off the supported backend leg it still registers cleanly
    and JitCanCompile simply declines everything, so wtmJit degrades to the
    interpreter with the same tallies. }
  if FMode = wtmJit then
    FJit := RegisterJit(FStore);
end;

destructor TWastRunner.Destroy;
var
  I: Integer;
begin
  { The JIT/AOT contexts own the code blocks and point the store's hook at the
    dispatcher; free them BEFORE the store (jit-spec §3.4 ownership) so each can
    clear its CompiledEntry pointers and the hook while the store is still
    whole. Then the store owns the instances, which borrow the IR, which
    borrows the buffer — so free in that order. }
  FJit.Free;
  for I := High(FAotJits) downto 0 do
    FAotJits[I].Free;
  FStore.Free;
  FEngine.Free;
  for I := 0 to High(FIrs) do
    FIrs[I].Free;
  FModel.Free;
  inherited Destroy;
end;

procedure TWastRunner.ForceCompileInstance(const AInst: TWasmModuleInstance);
var
  I: Integer;
  Addr: TWasmFuncAddr;
  WasCompiled: Boolean;
begin
  if (FJit = nil) or (AInst = nil) then
    Exit;
  { Walk the instance's function index space (defined + imported). ForceCompile
    is idempotent per address, so an imported function already compiled when its
    own instance was built is a no-op here, and a distinct function is counted
    once — it was nil before this call and is non-nil after. }
  for I := 0 to High(AInst.FuncAddrs) do
  begin
    Addr := AInst.FuncAddrs[I];
    if Addr > High(FStore.Funcs) then
      Continue;
    if FStore.Funcs[Addr].Kind <> wfkWasm then
      Continue;
    WasCompiled := FStore.Funcs[Addr].CompiledEntry <> nil;
    if FJit.ForceCompile(Addr) and (not WasCompiled)
      and (FStore.Funcs[Addr].CompiledEntry <> nil) then
      Inc(FCompiledCount);
  end;
end;

procedure TWastRunner.AotLoadInstance(const AInst: TWasmModuleInstance;
  const AIr: TWasmIrModule; const ABytes: TWasmBytes);
var
  Artifact: TWasmBytes;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  I, N: Integer;
  Addr: TWasmFuncAddr;
  WasNil: array of Boolean;
  BytesPtr: PByte;
begin
  if (FMode <> wtmAot) or (AInst = nil) then
    Exit;

  { Record which of the instance's wasm functions are not yet compiled, so a
    newly-wired one is counted exactly once — mirroring ForceCompileInstance, so
    the loaded count is comparable to wtmJit's compiled count. An imported
    function already wired when its own module loaded is not nil here and so is
    not double-counted. }
  SetLength(WasNil, Length(AInst.FuncAddrs));
  for I := 0 to High(AInst.FuncAddrs) do
  begin
    Addr := AInst.FuncAddrs[I];
    WasNil[I] := (Addr <= High(FStore.Funcs))
      and (FStore.Funcs[Addr].Kind = wfkWasm)
      and (FStore.Funcs[Addr].CompiledEntry = nil);
  end;

  if Length(ABytes) > 0 then
    BytesPtr := @ABytes[0]
  else
    BytesPtr := nil;

  { SERIALIZE: stage every compilable function to position-independent bytes and
    write the real `.waot` container to memory. LOAD: parse it, re-check every
    guard, map the code executable, and wire each CompiledEntry from the parsed
    bytes — the full round-trip a deployed artifact takes. A guard rejection
    leaves Jit nil and the functions interpreted (still correct); the loaded
    count then drops, which is visible in the tally. }
  Artifact := AotCompileModuleIr(FStore, AIr, BytesPtr, NativeUInt(Length(ABytes)));
  Jit := AotLoadAndWireIr(FStore, AIr, BytesPtr, NativeUInt(Length(ABytes)),
    AInst, Artifact, LoadRes);
  if Jit = nil then
    Exit;

  N := Length(FAotJits);
  SetLength(FAotJits, N + 1);
  FAotJits[N] := Jit;

  for I := 0 to High(AInst.FuncAddrs) do
  begin
    Addr := AInst.FuncAddrs[I];
    if WasNil[I] and (Addr <= High(FStore.Funcs))
      and (FStore.Funcs[Addr].CompiledEntry <> nil) then
      Inc(FCompiledCount);
  end;
end;

function TWastRunner.LookupNamed(const AId: string): TWasmModuleInstance;
var
  I: Integer;
begin
  Result := nil;
  for I := High(FNamed) downto 0 do
    if FNamed[I].Name = AId then
      Exit(FNamed[I].Instance);
end;

function TWastRunner.LookupRegistry(
  const AName: string): TWasmModuleInstance;
var
  I: Integer;
begin
  Result := nil;
  for I := High(FRegistry) downto 0 do
    if FRegistry[I].Name = AName then
      Exit(FRegistry[I].Instance);
end;

procedure TWastRunner.BindNamed(const AId: string;
  const AInst: TWasmModuleInstance);
begin
  SetLength(FNamed, Length(FNamed) + 1);
  FNamed[High(FNamed)].Name := AId;
  FNamed[High(FNamed)].Instance := AInst;
end;

procedure TWastRunner.RegisterName(const AName: string;
  const AInst: TWasmModuleInstance);
begin
  SetLength(FRegistry, Length(FRegistry) + 1);
  FRegistry[High(FRegistry)].Name := AName;
  FRegistry[High(FRegistry)].Instance := AInst;
end;

function TWastRunner.HostRef(const AId: UInt32): TWasmRef;
var
  I: Integer;
  Ref: TWasmRef;
begin
  for I := 0 to High(FHostRefs) do
    if FHostRefs[I].Id = AId then
      Exit(FHostRefs[I].Ref);
  { A boxed host value; the collector is non-moving and the root keeps it
    alive and stable, so raw ref equality is a valid identity check. }
  Ref := FStore.Heap.AllocHostBox(AId, nil);
  RootRegister(FStore, Ref);
  SetLength(FHostRefs, Length(FHostRefs) + 1);
  FHostRefs[High(FHostRefs)].Id := AId;
  FHostRefs[High(FHostRefs)].Ref := Ref;
  Result := Ref;
end;

{ --- value rendering ----------------------------------------------------- }

function HexU(const AValue: UInt64; const ADigits: Integer): string;
const
  DIGITS = '0123456789abcdef';
var
  I: Integer;
  V: UInt64;
begin
  Result := '';
  V := AValue;
  for I := 1 to ADigits do
  begin
    Result := DIGITS[(V and $F) + 1] + Result;
    V := V shr 4;
  end;
  Result := '0x' + Result;
end;

{ Render a produced value against the WIDTH the expected matcher wants, so a
  report shows comparable hex. }
function RenderActual(const AVal: TWasmValue;
  const AWidth: TWastValWidth): string;
begin
  case AWidth of
    wvw32: Result := HexU(AVal.Bits and $FFFFFFFF, 8);
    wvw64: Result := HexU(AVal.Bits, 16);
  else
    Result := HexU(AVal.Bits, 16);
  end;
end;

{ Slots a value type occupies in the flat marshal array: a v128 spans two
  (design §1.6), everything else one. }
function TypeSlots(const AType: TWasmValueType): Integer; inline;
begin
  if AType.Kind = wvkVec then
    Result := 2
  else
    Result := 1;
end;

function SumSlots(const ATypes: array of TWasmValueType): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ATypes) do
    Inc(Result, TypeSlots(ATypes[I]));
end;

{ Render a produced vector actual as `(v128.const <expected shape> lane...)`
  so a failure diff reads in the same notation as the script (design §6.3).
  AActual points at the low slot of the register pair. }
function RenderActualVec(const AActual: PWasmV128;
  const AShape: TWastVecShape): string;
const
  SHAPE_NAME: array[TWastVecShape] of string = (
    'i8x16', 'i16x8', 'i32x4', 'i64x2', 'f32x4', 'f64x2');
var
  I, Count: Integer;
begin
  Result := '(v128.const ' + SHAPE_NAME[AShape];
  Count := VecLaneCount(AShape);
  for I := 0 to Count - 1 do
    case AShape of
      wvsI8x16: Result := Result + ' ' + HexU(AActual^.B[I], 2);
      wvsI16x8: Result := Result + ' ' + HexU(AActual^.U16[I], 4);
      wvsI32x4, wvsF32x4: Result := Result + ' ' + HexU(AActual^.U32[I], 8);
    else
      Result := Result + ' ' + HexU(AActual^.U64[I], 16);   { i64x2 / f64x2 }
    end;
  Result := Result + ')';
end;

{ --- action resolution --------------------------------------------------- }

{ Which instance an action node targets, and the index of its export-name
  string child. An action is `(invoke|get [$id] "name" arg*)`. When a `$id`
  names no instance, Result is nil. }
function ResolveActionInstance(const ARunner: TWastRunner;
  const AAction: TWastNode; out ANameIndex: Integer): TWasmModuleInstance;
var
  Idx: Integer;
begin
  Result := ARunner.Current;
  Idx := 1;
  if (Idx < AAction.Count) and (AAction[Idx].Kind = wnkAtom)
    and (Length(AAction[Idx].Atom) > 0) and (AAction[Idx].Atom[1] = '$') then
  begin
    Result := ARunner.LookupNamed(AAction[Idx].Atom);
    Inc(Idx);
  end;
  ANameIndex := Idx;
end;

type
  { The outcome class of a wasm action. wakException is an UNCAUGHT guest
    exception (`throw`/`throw_ref` with no matching `try_table` clause) — the
    EWasmException that reached the invocation boundary, which `assert_exception`
    judges. It is a SIBLING of wakTrap, never folded into it: a trap must never
    satisfy assert_exception and an exception must never satisfy assert_trap. }
  TWastActionKind = (wakOk, wakTrap, wakException, wakNoExport, wakError,
    wakBadValue);

  { The outcome of running an action. On wakOk, Values holds the raw result
    SLOTS (a v128 spans two, low half first — design §1.6) and Count is the
    declared result VALUE count, so the arity check is against value count
    while the slot walk reads the pair. A message accompanies the error
    kinds. }
  TWastActionResult = record
    Kind: TWastActionKind;
    Values: array of TWasmValue;
    Count: Integer;
    Message: string;
  end;

{ Parse the argument nodes [AFirst .. end) of an action into a runtime param
  buffer whose length is the callee's total SLOT count (a v128 argument
  occupies two consecutive slots, low half first). Reference identities are
  minted via the runner. }
function MarshalArgs(const ARunner: TWastRunner; const AAction: TWastNode;
  const AFirst: Integer; const AParamSlots: Integer;
  var AParams: array of TWasmValue; var AResult: TWastActionResult): Boolean;
var
  I, Slot: Integer;
  Val: TWastVal;
  Vec: TWasmV128;
begin
  Result := False;
  for I := 0 to AParamSlots - 1 do
    AParams[I].Bits := 0;
  Slot := 0;
  for I := AFirst to AAction.Count - 1 do
  begin
    try
      Val := WastParseVal(AAction[I]);
    except
      on E: EWastValueError do
      begin
        AResult.Kind := wakBadValue;
        AResult.Message := E.Message;
        Exit;
      end;
    end;
    if Val.Kind = wvcV128 then
    begin
      if Slot + 1 < AParamSlots then
      begin
        Vec := WastValToVec(Val);
        AParams[Slot].Bits := Vec.U64[0];
        AParams[Slot + 1].Bits := Vec.U64[1];
      end;
      Inc(Slot, 2);
    end
    else
    begin
      if Slot < AParamSlots then
        case Val.Kind of
          wvcRefExtern, wvcRefHost:
            AParams[Slot] := MakeValueRef(ARunner.HostRef(Val.Id));
          wvcRefFunc:
            AParams[Slot] := MakeValueNullRef;   { rarely an argument }
        else
          AParams[Slot] := WastValToRuntime(Val);
        end;
      Inc(Slot);
    end;
  end;
  Result := True;
end;

{ Run `(invoke [$id] "name" args...)` against AInst. }
function RunInvoke(const ARunner: TWastRunner;
  const AInst: TWasmModuleInstance; const AAction: TWastNode;
  const ANameIndex: Integer): TWastActionResult;
var
  ExportName: string;
  Kind: TWasmExternKind;
  Addr: UInt32;
  Func: TWasmFuncType;
  Params, Results: array of TWasmValue;
  ParamPtr, ResultPtr: PWasmValue;
  I, ResultCount, ParamSlots, ResultSlots: Integer;
begin
  Result.Kind := wakOk;
  Result.Count := 0;
  Result.Message := '';
  ExportName := BytesToText(AAction[ANameIndex].Bytes);
  if not AInst.FindExport(ExportName, Kind, Addr) or (Kind <> wxkFunc) then
  begin
    Result.Kind := wakNoExport;
    Result.Message := ExportName;
    Exit;
  end;

  Func := ARunner.Engine.EngineType(ARunner.Store.Funcs[Addr].TypeId).Comp.Func;
  ResultCount := Length(Func.Results);
  { Slot counts, not value counts: a v128 param/result spans two (§1.6). }
  ParamSlots := SumSlots(Func.Params);
  ResultSlots := SumSlots(Func.Results);

  SetLength(Params, ParamSlots);
  if not MarshalArgs(ARunner, AAction, ANameIndex + 1, ParamSlots,
    Params, Result) then
    Exit;   { bad value — Result already set }

  SetLength(Results, ResultSlots);
  if ParamSlots > 0 then
    ParamPtr := @Params[0]
  else
    ParamPtr := nil;
  if ResultSlots > 0 then
    ResultPtr := @Results[0]
  else
    ResultPtr := nil;

  try
    InterpInvoke(ARunner.Store, Addr, ParamPtr, ResultPtr);
    Result.Kind := wakOk;
    Result.Count := ResultCount;   { declared VALUE count for the arity check }
    SetLength(Result.Values, ResultSlots);
    for I := 0 to ResultSlots - 1 do
      Result.Values[I] := Results[I];
  except
    on E: EWasmTrap do
    begin
      Result.Kind := wakTrap;
      Result.Message := E.Message;
    end;
    { EWasmException is a more-derived EWasmError (a SIBLING of EWasmTrap under
      EWasmError), so it MUST be caught before the generic clause below or that
      clause would swallow an uncaught guest exception as wakError. }
    on E: EWasmException do
    begin
      Result.Kind := wakException;
      Result.Message := E.Message;
    end;
    on E: EWasmError do
    begin
      Result.Kind := wakError;
      Result.Message := E.Message;
    end;
  end;
end;

{ Run `(get [$id] "name")` — read an exported global. }
function RunGet(const ARunner: TWastRunner;
  const AInst: TWasmModuleInstance; const AAction: TWastNode;
  const ANameIndex: Integer): TWastActionResult;
var
  ExportName: string;
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  Result.Kind := wakOk;
  Result.Count := 0;
  Result.Message := '';
  ExportName := BytesToText(AAction[ANameIndex].Bytes);
  if not AInst.FindExport(ExportName, Kind, Addr) or (Kind <> wxkGlobal) then
  begin
    Result.Kind := wakNoExport;
    Result.Message := ExportName;
    Exit;
  end;
  SetLength(Result.Values, 1);
  Result.Values[0] := ARunner.Store.Globals[Addr].Value;
  Result.Count := 1;
end;

{ Dispatch an action node (invoke or get) to its runner. Returns nil-target
  as wakNoExport with an empty message, which the caller turns into a skip. }
function RunAction(const ARunner: TWastRunner; const AAction: TWastNode;
  out AHasInstance: Boolean): TWastActionResult;
var
  Inst: TWasmModuleInstance;
  NameIndex: Integer;
  Head: string;
begin
  Result.Kind := wakOk;
  Result.Count := 0;
  Result.Message := '';
  Inst := ResolveActionInstance(ARunner, AAction, NameIndex);
  AHasInstance := Inst <> nil;
  if not AHasInstance then
    Exit;
  Head := AAction.HeadAtom;
  if Head = 'get' then
    Result := RunGet(ARunner, Inst, AAction, NameIndex)
  else
    Result := RunInvoke(ARunner, Inst, AAction, NameIndex);
end;

{ --- import resolution --------------------------------------------------- }

{ Build the import addresses AModel needs from the registry, in index-space
  order per kind. Returns False (with AWhy) when any import cannot be
  satisfied — the harness provides no host `spectest` module, so those
  modules are skipped rather than failed. }
function ResolveImports(const ARunner: TWastRunner; const AModel: TWasmModule;
  out AImports: TWasmImports; out AWhy: string): Boolean;
var
  I: Integer;
  Imp: TWasmImport;
  Exporter: TWasmModuleInstance;
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  Result := False;
  AImports.Funcs := nil;
  AImports.Tables := nil;
  AImports.Mems := nil;
  AImports.Globals := nil;
  AImports.Tags := nil;
  for I := 0 to AModel.ImportCount - 1 do
  begin
    Imp := AModel.Imports[I];
    Exporter := ARunner.LookupRegistry(Imp.ModuleName);
    if Exporter = nil then
    begin
      AWhy := Format('%s: "%s"."%s"', [WAST_REASON_UNRESOLVED_IMPORT,
        Imp.ModuleName, Imp.Name]);
      Exit;
    end;
    if not Exporter.FindExport(Imp.Name, Kind, Addr) or (Kind <> Imp.Kind) then
    begin
      AWhy := Format('%s: "%s"."%s"', [WAST_REASON_UNRESOLVED_IMPORT,
        Imp.ModuleName, Imp.Name]);
      Exit;
    end;
    case Imp.Kind of
      wxkFunc:
        begin
          SetLength(AImports.Funcs, Length(AImports.Funcs) + 1);
          AImports.Funcs[High(AImports.Funcs)] := Addr;
        end;
      wxkTable:
        begin
          SetLength(AImports.Tables, Length(AImports.Tables) + 1);
          AImports.Tables[High(AImports.Tables)] := Addr;
        end;
      wxkMem:
        begin
          SetLength(AImports.Mems, Length(AImports.Mems) + 1);
          AImports.Mems[High(AImports.Mems)] := Addr;
        end;
      wxkGlobal:
        begin
          SetLength(AImports.Globals, Length(AImports.Globals) + 1);
          AImports.Globals[High(AImports.Globals)] := Addr;
        end;
      wxkTag:
        begin
          SetLength(AImports.Tags, Length(AImports.Tags) + 1);
          AImports.Tags[High(AImports.Tags)] := Addr;
        end;
    end;
  end;
  Result := True;
end;

{ The `$id` of a module command, '' when it has none. After `module` (and
  before the `binary`/`quote` marker) an id atom may appear. }
function ModuleId(const ANode: TWastNode): string;
begin
  Result := '';
  if (ANode.Count >= 2) and (ANode[1].Kind = wnkAtom)
    and (Length(ANode[1].Atom) > 0) and (ANode[1].Atom[1] = '$') then
    Result := ANode[1].Atom;
end;

{ --- command execution --------------------------------------------------- }

procedure Skipped(var AResult: TWastCommandResult; const AReason: string);
begin
  AResult.Status := wrsSkip;
  AResult.Actual := AReason;
end;

{ Assemble (text/quote), decode, validate, retain, and resolve the imports of
  a module operand that is expected to BUILD. On success returns True with the
  retained IR and the retained byte buffer (both borrowed by the instance for
  the life of the script) and the resolved imports; the caller then
  instantiates. On any build failure it fills AResult — a fail (text/decode/
  validation error, INV-1 internal), a staged case (staged validator feature
  or vector mnemonic), or a skip (imports the harness cannot satisfy) — and
  returns False. Shared by the top-level `module` command and the
  `assert_trap (module ...)` arm, so both build a module by exactly the same
  rules. Never touches ARunner.Current — the caller owns that. }
function PrepareModule(const ARunner: TWastRunner; const ANode: TWastNode;
  const AForm: TWastModuleForm; var AResult: TWastCommandResult;
  out AIr: TWasmIrModule; out ABytes: TWasmBytes;
  out AImports: TWasmImports): Boolean;
var
  Bytes: TWasmBytes;
  Ir: TWasmIrModule;
  Why, Msg: string;
  Assembled: Boolean;
begin
  Result := False;
  AIr := nil;

  { Text and quote modules ASSEMBLE first (§4); a well-formed one must
    assemble, decode, validate, and instantiate cleanly, so a text error here
    is a real failure — unless it is a staged vector mnemonic. Binary modules
    skip assembly and decode directly. }
  Assembled := AForm <> wmfBinary;
  if Assembled then
  begin
    case AssembleOperand(ANode, AForm, Bytes, Msg) of
      wasTextError:
        begin
          AResult.ActualKind := wekText;
          AResult.Actual := Msg;
          AResult.Status := wrsFail;
          Exit;
        end;
      wasInternal:
        begin
          AResult.ActualKind := wekOther;
          AResult.Actual := Msg;
          AResult.Status := wrsFail;
          Exit;
        end;
    end;
  end
  else
    Bytes := ModuleBinaryBytes(ANode);

  Ir := nil;
  try
    DecodeModule(Bytes, ARunner.Model);
    Ir := ValidateModule(ARunner.Model, Bytes);
  except
    on E: EWasmDecodeError do
    begin
      if Assembled then
      begin
        { INV-1: our own assembler output must decode; a decode error is an
          internal defect, not a conformance verdict. }
        AResult.ActualKind := wekOther;
        AResult.Actual := 'internal: assembler output failed to decode: '
          + E.Message;
      end
      else
      begin
        AResult.ActualKind := wekDecode;
        AResult.Actual := E.Message;
      end;
      AResult.Status := wrsFail;
      Exit;
    end;
    on E: EWasmValidationError do
    begin
      AResult.ActualKind := wekValidation;
      AResult.Actual := E.Message;
      AResult.Status := wrsFail;
      Exit;
    end;
    on E: Exception do
    begin
      AResult.ActualKind := wekOther;
      AResult.Actual := E.ClassName + ': ' + E.Message;
      AResult.Status := wrsFail;
      Exit;
    end;
  end;

  if not ResolveImports(ARunner, ARunner.Model, AImports, Why) then
  begin
    Skipped(AResult, Why);
    Ir.Free;
    Exit;
  end;

  { Retain IR and bytes: the instance borrows both for the whole script. }
  SetLength(ARunner.FIrs, Length(ARunner.FIrs) + 1);
  ARunner.FIrs[High(ARunner.FIrs)] := Ir;
  SetLength(ARunner.FBuffers, Length(ARunner.FBuffers) + 1);
  ARunner.FBuffers[High(ARunner.FBuffers)] := Bytes;
  AIr := Ir;
  ABytes := ARunner.FBuffers[High(ARunner.FBuffers)];
  Result := True;
end;

{ Decode, validate, instantiate, and run the start function of a top-level
  module. The IR and bytes are retained so the instance can borrow them for
  the life of the script. }
procedure RunModuleCommand(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Bytes: TWasmBytes;
  Ir: TWasmIrModule;
  Imports: TWasmImports;
  Inst: TWasmModuleInstance;
  Id: string;
begin
  { A module that fails to build leaves no instance — clear Current so later
    actions skip honestly rather than run against a stale module. }
  ARunner.Current := nil;

  if not PrepareModule(ARunner, ACommand.Node, ACommand.ModuleForm, AResult,
    Ir, Bytes, Imports) then
    Exit;

  try
    Inst := InstantiateModule(ARunner.Store, Ir, @Bytes[0],
      NativeUInt(Length(Bytes)), Imports);
    ARunner.Store.RunPendingStart(Inst);
  except
    on E: EWasmLinkError do
    begin
      Skipped(AResult, WAST_REASON_UNRESOLVED_IMPORT + ': ' + E.Message);
      Exit;
    end;
    on E: EWasmTrap do
    begin
      AResult.Actual := E.Message;
      AResult.Status := wrsFail;
      Exit;
    end;
    on E: EWasmError do
    begin
      AResult.Actual := E.ClassName + ': ' + E.Message;
      AResult.Status := wrsFail;
      Exit;
    end;
  end;

  ARunner.Current := Inst;
  Id := ModuleId(ACommand.Node);
  if Id <> '' then
    ARunner.BindNamed(Id, Inst);
  { In wtmJit mode, tier every compilable function of this instance up NOW, so
    the assert_return/assert_trap invokes that follow route through the compiled
    code via the CompiledEntry seam. A no-op in the default interpreter mode.
    In wtmAot mode, AOT-compile the module, serialize it, and load it back —
    wiring the same functions through the real artifact round-trip instead. Both
    are no-ops in the other mode. }
  ARunner.ForceCompileInstance(Inst);
  ARunner.AotLoadInstance(Inst, Ir, Bytes);
  AResult.Status := wrsPass;
end;

{ `assert_malformed` / `assert_invalid`: the module must fail with the error
  class AWant and a message the script's expected string is a prefix of. }
procedure RunAssertFailure(const ARunner: TWastRunner;
  const ACommand: TWastCommand; const AWant: TWastErrorKind;
  var AResult: TWastCommandResult);
var
  Operand: TWastNode;
  Form: TWastModuleForm;
  Kind, Want: TWastErrorKind;
  Msg: string;
begin
  Operand := FindModuleOperand(ACommand.Node);
  if Operand = nil then
  begin
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;

  AResult.Expected := ExpectedFailure(ACommand.Node);
  Form := DetectWastModuleForm(Operand);

  { The accepted error class depends on the operand form (§4): a `(module
    binary ...)` is malformed via a DECODE error, a `(module ...)` / `(module
    quote ...)` via a TEXT error. assert_invalid always wants a validation
    error — the text module must ASSEMBLE first (a text error there is a real
    fail, an INV-2 false rejection or a message divergence). }
  if AWant = wekDecode then
  begin
    if Form = wmfBinary then
      Want := wekDecode
    else
      Want := wekText;
  end
  else
    Want := wekValidation;

  Kind := AttemptOperand(ARunner.Model, Operand, Form, Msg);
  AResult.ActualKind := Kind;
  if Kind = wekNone then
    AResult.Actual := WAST_NO_ERROR
  else
    AResult.Actual := Msg;

  { A wrong-class rejection is a fail; otherwise the prefix match decides
    pass/fail. Nothing stages any more (Track H retired the last carve-out). }
  if Kind <> Want then
    AResult.Status := wrsFail
  else if WastMessageMatches(AResult.Expected, Msg) then
    AResult.Status := wrsPass
  else
    AResult.Status := wrsFail;
end;

{ `assert_trap (module ...)` / `assert_exhaustion (module ...)`: the module is
  well-formed and valid, and its INSTANTIATION must trap. We build it (through
  the shared PrepareModule) and instantiate it for real: active elem/data
  segments apply in module order, an out-of-bounds one traps
  (`exec-instantiation`), and — the point of this arm — the earlier in-bounds
  segments PERSIST in the (imported/shared) store, which a following
  `assert_return` observes (linking.wast:399-411). A start function is run
  through the tier, so a trapping start is judged the same way.

  A trap PASSES when the expected string is a prefix of its message
  (assert_exhaustion's is `call stack exhausted`); a clean build+start where a
  trap was required FAILS. A well-formed module the harness cannot link is an
  honest SKIP — not the trap we were asked to judge — matching the top-level
  module path. }
procedure RunAssertTrapModule(const ARunner: TWastRunner;
  const AOperand: TWastNode; var AResult: TWastCommandResult);
var
  Ir: TWasmIrModule;
  Bytes: TWasmBytes;
  Imports: TWasmImports;
  Inst: TWasmModuleInstance;
begin
  if not PrepareModule(ARunner, AOperand, DetectWastModuleForm(AOperand),
    AResult, Ir, Bytes, Imports) then
    Exit;

  try
    Inst := InstantiateModule(ARunner.Store, Ir, @Bytes[0],
      NativeUInt(Length(Bytes)), Imports);
    ARunner.Store.RunPendingStart(Inst);
  except
    on E: EWasmLinkError do
    begin
      { A well-formed module the harness could not link — not the
        instantiation trap we were asked to judge. }
      Skipped(AResult, WAST_REASON_UNRESOLVED_IMPORT + ': ' + E.Message);
      Exit;
    end;
    on E: EWasmTrap do
    begin
      { Instantiation trapped, exactly as asserted. Earlier in-bounds
        segments are already written into the store and persist. Re-establish
        the frame chain and context cursors after the unwind, as the invoke
        path does, so a following command runs on clean ground. }
      ARunner.Store.Heap.ResetFrames;
      ResetInterpContext(ARunner.Store);
      AResult.ActualKind := wekNone;
      AResult.Actual := E.Message;
      if WastMessageMatches(AResult.Expected, E.Message) then
        AResult.Status := wrsPass
      else
        AResult.Status := wrsFail;
      Exit;
    end;
    on E: EWasmError do
    begin
      { Not the instantiation TRAP we were asked to judge — an internal defect
        surfaced as a fail rather than aborting the run. }
      ARunner.Store.Heap.ResetFrames;
      ResetInterpContext(ARunner.Store);
      AResult.ActualKind := wekOther;
      AResult.Actual := E.ClassName + ': ' + E.Message;
      AResult.Status := wrsFail;
      Exit;
    end;
  end;

  { Built and started cleanly where a trap was required. }
  AResult.ActualKind := wekNone;
  AResult.Actual := WAST_NO_ERROR;
  AResult.Status := wrsFail;
end;

{ `assert_unlinkable` over a MODULE operand: the module is well-formed and
  valid by construction, so it is assembled, decoded, and validated as a
  PRE-CHECK (a failure there is a false rejection — INV-2 — or a real decoder/
  validator bug on a newly-reachable module, and is reported). When the
  pre-check passes, the command still SKIPS: judging linkage needs plumbing
  this wave does not add, and a skip stays a skip (§4). }
procedure RunModulePrecheck(const ARunner: TWastRunner;
  const AOperand: TWastNode; var AResult: TWastCommandResult);
var
  Kind: TWastErrorKind;
  Msg: string;
begin
  Kind := AttemptOperand(ARunner.Model, AOperand,
    DetectWastModuleForm(AOperand), Msg);
  if Kind = wekNone then
  begin
    { Assembled, decoded, validated — we simply cannot judge the rest. }
    Skipped(AResult, WAST_REASON_NEEDS_TIER);
    Exit;
  end;
  AResult.ActualKind := Kind;
  AResult.Actual := Msg;
  AResult.Status := wrsFail;
end;

procedure RunAssertUnlinkable(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Operand: TWastNode;
begin
  Operand := FindModuleOperand(ACommand.Node);
  if Operand = nil then
  begin
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;
  AResult.Expected := ExpectedFailure(ACommand.Node);
  RunModulePrecheck(ARunner, Operand, AResult);
end;

{ Resolve the expected reference identity a matcher compares against —
  minting the host box for ref.extern/host; funcref specifics are left as
  null (any non-null funcref matches the corpus's bare `(ref.func)`). }
function ExpectedRefFor(const ARunner: TWastRunner;
  const AExpected: TWastVal): TWasmRef;
begin
  case AExpected.Kind of
    wvcRefExtern, wvcRefHost:
      if AExpected.HasId then
        Result := ARunner.HostRef(AExpected.Id)
      else
        Result := WASM_REF_NULL;
  else
    Result := WASM_REF_NULL;
  end;
end;

{ `assert_return (action) results...`: run the action, then compare each
  produced value against its expected matcher. }
procedure RunAssertReturn(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Action: TWastNode;
  Act: TWastActionResult;
  HasInstance, AllMatch, IsVec: Boolean;
  I, ExpectCount, Slot, Need: Integer;
  Expecteds: array of TWastExpected;
  ActualText: string;
begin
  if ACommand.Node.Count < 2 then
  begin
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;
  Action := ACommand.Node[1];
  Act := RunAction(ARunner, Action, HasInstance);
  if not HasInstance then
  begin
    Skipped(AResult, WAST_REASON_NO_INSTANCE);
    Exit;
  end;

  ExpectCount := ACommand.Node.Count - 2;
  AResult.Expected := NodeText(ACommand.Node);

  case Act.Kind of
    wakNoExport:
      begin
        Skipped(AResult, WAST_REASON_NO_EXPORT + ': ' + Act.Message);
        Exit;
      end;
    wakBadValue:
      begin
        Skipped(AResult, 'unsupported value: ' + Act.Message);
        Exit;
      end;
    wakTrap:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected trap: ' + Act.Message;
        Exit;
      end;
    wakException:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected exception: ' + Act.Message;
        Exit;
      end;
    wakError:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected error: ' + Act.Message;
        Exit;
      end;
  end;

  { Parse each expected result matcher ONCE. `(either ...)` yields several
    alternatives; a v128 or scalar yields one. }
  SetLength(Expecteds, ExpectCount);
  for I := 0 to ExpectCount - 1 do
    try
      Expecteds[I] := WastParseExpected(ACommand.Node[2 + I]);
    except
      on E: EWastValueError do
      begin
        Skipped(AResult, 'unsupported value: ' + E.Message);
        Exit;
      end;
    end;

  { Arity is expected count vs the declared result VALUE count (a v128 result
    is one value across two slots — design §6.3). }
  if Act.Count <> ExpectCount then
  begin
    AResult.Status := wrsFail;
    AResult.Actual := Format('result count %d, expected %d',
      [Act.Count, ExpectCount]);
    Exit;
  end;

  { Walk expecteds alongside the produced SLOTS: a v128 result consumes two,
    everything else one. }
  AllMatch := True;
  ActualText := '';
  Slot := 0;
  for I := 0 to ExpectCount - 1 do
  begin
    IsVec := (Length(Expecteds[I].Alts) > 0)
      and (Expecteds[I].Alts[0].Kind = wvcV128);
    if IsVec then
      Need := 2
    else
      Need := 1;

    if Slot + Need > Length(Act.Values) then
    begin
      { Fewer produced slots than the expected shape needs — a divergence,
        not a crash. }
      AllMatch := False;
      Break;
    end;

    if ActualText <> '' then
      ActualText := ActualText + ' ';
    if IsVec then
      ActualText := ActualText + RenderActualVec(
        PWasmV128(@Act.Values[Slot]), Expecteds[I].Alts[0].VecShape)
    else
      ActualText := ActualText
        + RenderActual(Act.Values[Slot], Expecteds[I].Alts[0].Width);

    if not WastExpectedMatches(Expecteds[I], @Act.Values[Slot], IsVec,
      ExpectedRefFor(ARunner, Expecteds[I].Alts[0])) then
      AllMatch := False;

    Inc(Slot, Need);
  end;

  if AllMatch then
    AResult.Status := wrsPass
  else
  begin
    AResult.Status := wrsFail;
    AResult.Actual := ActualText;
  end;
end;

{ `assert_trap` / `assert_exhaustion`: the action must trap, with a message
  the expected string is a prefix of. }
procedure RunAssertTrap(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Action: TWastNode;
  Act: TWastActionResult;
  HasInstance: Boolean;
begin
  if (ACommand.Node.Count < 2) or (ACommand.Node[1].Kind <> wnkList) then
  begin
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;
  Action := ACommand.Node[1];
  AResult.Expected := ExpectedFailure(ACommand.Node);

  { `assert_trap (module ...) "..."` is the instantiation-trap form (active
    elem/data out of bounds, a trapping start): the module is built and
    instantiated for real, and its trap is judged. }
  if Action.HeadAtom = 'module' then
  begin
    RunAssertTrapModule(ARunner, Action, AResult);
    Exit;
  end;

  Act := RunAction(ARunner, Action, HasInstance);
  if not HasInstance then
  begin
    Skipped(AResult, WAST_REASON_NO_INSTANCE);
    Exit;
  end;

  case Act.Kind of
    wakNoExport:
      Skipped(AResult, WAST_REASON_NO_EXPORT + ': ' + Act.Message);
    wakBadValue:
      Skipped(AResult, 'unsupported value: ' + Act.Message);
    wakTrap:
      begin
        AResult.Actual := Act.Message;
        if WastMessageMatches(AResult.Expected, Act.Message) then
          AResult.Status := wrsPass
        else
          AResult.Status := wrsFail;
      end;
    wakException:
      begin
        { A trap and an uncaught exception are separate outcomes: an exception
          never satisfies assert_trap (design §2.1). }
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected exception: ' + Act.Message;
      end;
    wakError:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected error: ' + Act.Message;
      end;
  else
    begin
      { Ran clean where a trap was required. }
      AResult.Status := wrsFail;
      AResult.Actual := WAST_NO_ERROR;
    end;
  end;
end;

{ A bare `(invoke ...)` action at top level: run for effect, expecting
  success. }
procedure RunInvokeCommand(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Act: TWastActionResult;
  HasInstance: Boolean;
begin
  Act := RunAction(ARunner, ACommand.Node, HasInstance);
  if not HasInstance then
  begin
    Skipped(AResult, WAST_REASON_NO_INSTANCE);
    Exit;
  end;
  case Act.Kind of
    wakOk:
      AResult.Status := wrsPass;
    wakNoExport:
      Skipped(AResult, WAST_REASON_NO_EXPORT + ': ' + Act.Message);
    wakBadValue:
      Skipped(AResult, 'unsupported value: ' + Act.Message);
    wakTrap:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected trap: ' + Act.Message;
      end;
    wakException:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected exception: ' + Act.Message;
      end;
  else
    begin
      AResult.Status := wrsFail;
      AResult.Actual := 'unexpected error: ' + Act.Message;
    end;
  end;
end;

{ `(register "name" $id?)`: bind an instance's exports under an import
  module-name, for later modules to import. }
procedure RunRegisterCommand(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Name: string;
  Inst: TWasmModuleInstance;
begin
  if (ACommand.Node.Count < 2) or (ACommand.Node[1].Kind <> wnkString) then
  begin
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;
  Name := BytesToText(ACommand.Node[1].Bytes);
  Inst := ARunner.Current;
  if (ACommand.Node.Count >= 3) and (ACommand.Node[2].Kind = wnkAtom)
    and (Length(ACommand.Node[2].Atom) > 0)
    and (ACommand.Node[2].Atom[1] = '$') then
    Inst := ARunner.LookupNamed(ACommand.Node[2].Atom);
  if Inst = nil then
  begin
    Skipped(AResult, WAST_REASON_NO_INSTANCE);
    Exit;
  end;
  ARunner.RegisterName(Name, Inst);
  AResult.Status := wrsPass;
end;

{ `assert_exception (invoke ...)`: the action must raise an UNCAUGHT wasm
  exception — a `throw`/`throw_ref` that reached the invocation boundary with no
  matching `try_table` clause, delivered as EWasmException (eh-spec §7.1). The
  reference `assert_exception` asserts only THAT an exception escaped; it carries
  no expected tag or payload (verified against throw.wast / throw_ref.wast /
  try_table.wast — every occurrence is a bare `(assert_exception (invoke ...))`),
  so this judges the class alone. It PASSES iff the action's outcome is
  wakException; a returned value, a trap, or any other error FAILS. A trap must
  never satisfy it (they are separate routes, design §2.1). Mirrors
  RunAssertTrap's shape. }
procedure RunAssertException(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Action: TWastNode;
  Act: TWastActionResult;
  HasInstance: Boolean;
begin
  if (ACommand.Node.Count < 2) or (ACommand.Node[1].Kind <> wnkList) then
  begin
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;
  Action := ACommand.Node[1];
  AResult.Expected := 'uncaught exception';

  Act := RunAction(ARunner, Action, HasInstance);
  if not HasInstance then
  begin
    Skipped(AResult, WAST_REASON_NO_INSTANCE);
    Exit;
  end;

  case Act.Kind of
    wakNoExport:
      Skipped(AResult, WAST_REASON_NO_EXPORT + ': ' + Act.Message);
    wakBadValue:
      Skipped(AResult, 'unsupported value: ' + Act.Message);
    wakException:
      begin
        AResult.Actual := Act.Message;
        AResult.Status := wrsPass;
      end;
    wakTrap:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected trap: ' + Act.Message;
      end;
    wakError:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected error: ' + Act.Message;
      end;
  else
    begin
      { Ran clean where an exception was required. }
      AResult.Status := wrsFail;
      AResult.Actual := WAST_NO_ERROR;
    end;
  end;
end;

function ExecuteCommand(const ARunner: TWastRunner;
  const ACommand: TWastCommand): TWastCommandResult;
begin
  Result.Kind := ACommand.Kind;
  Result.Line := ACommand.Node.Line;
  Result.Status := wrsSkip;
  Result.Expected := '';
  Result.Actual := '';
  Result.ActualKind := wekNone;

  case ACommand.Kind of
    wcModule:
      RunModuleCommand(ARunner, ACommand, Result);
    wcAssertMalformed:
      RunAssertFailure(ARunner, ACommand, wekDecode, Result);
    wcAssertInvalid:
      RunAssertFailure(ARunner, ACommand, wekValidation, Result);
    wcAssertReturn:
      RunAssertReturn(ARunner, ACommand, Result);
    wcAssertTrap, wcAssertExhaustion:
      RunAssertTrap(ARunner, ACommand, Result);
    wcInvoke:
      RunInvokeCommand(ARunner, ACommand, Result);
    wcRegister:
      RunRegisterCommand(ARunner, ACommand, Result);
    wcAssertException:
      RunAssertException(ARunner, ACommand, Result);
    wcAssertUnlinkable:
      RunAssertUnlinkable(ARunner, ACommand, Result);
    wcUnknown:
      Skipped(Result, WAST_REASON_UNKNOWN_DIRECTIVE);
  else
    Skipped(Result, WAST_REASON_NEEDS_TIER);
  end;
end;

{ --- entry points -------------------------------------------------------- }

{ Turn an exception that escaped a single command into a FAIL result for
  THAT command, so the rest of the file still runs. This is the runner's
  hard guarantee (Track C Wave 6b): no single command can abort the whole
  corpus file. The interpreter already converts guest faults to the
  EWasmError hierarchy at its boundary; this is the belt for anything the
  layers above it (marshalling, decode, a runner bug) might still leak. }
function CommandCrashResult(const ACommand: TWastCommand;
  const AException: Exception): TWastCommandResult;
begin
  Result.Kind := ACommand.Kind;
  Result.Line := ACommand.Node.Line;
  Result.Status := wrsFail;
  Result.Expected := '';
  Result.Actual := 'command raised ' + AException.ClassName + ': ' +
    AException.Message;
  Result.ActualKind := wekOther;
end;

function RunWastScript(const AScript: TWastScript): TWastRunResult;
begin
  Result := RunWastScript(AScript, wtmInterp);
end;

function RunWastScript(const AScript: TWastScript;
  const AMode: TWastTierMode): TWastRunResult;
var
  I: Integer;
  Runner: TWastRunner;
begin
  Result := TWastRunResult.Create;
  try
    Runner := TWastRunner.Create(AMode);
    try
      for I := 0 to AScript.Count - 1 do
        try
          Result.AddResult(ExecuteCommand(Runner, AScript[I]));
        except
          on E: Exception do
            Result.AddResult(CommandCrashResult(AScript[I], E));
        end;
      { Carry the count of functions actually JIT-compiled out to the caller;
        zero in interpreter mode. Same-unit access to the private field. }
      Result.FCompiledFuncCount := Runner.CompiledCount;
    finally
      Runner.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function RunWastSource(const ASource: string): TWastRunResult;
begin
  Result := RunWastSource(ASource, wtmInterp);
end;

function RunWastSource(const ASource: string;
  const AMode: TWastTierMode): TWastRunResult;
var
  Script: TWastScript;
begin
  Script := ParseWastScript(ASource);
  try
    Result := RunWastScript(Script, AMode);
  finally
    Script.Free;
  end;
end;

function RunWastFile(const APath: string): TWastRunResult;
begin
  Result := RunWastFile(APath, wtmInterp);
end;

function RunWastFile(const APath: string;
  const AMode: TWastTierMode): TWastRunResult;
begin
  Result := RunWastSource(BytesToText(LoadFileBytes(APath)), AMode);
end;

end.
