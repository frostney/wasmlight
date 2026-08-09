{ Wasm.Wast.Runner — executes a parsed `.wast` script against the layers
  this project has shipped, and reports what it could not judge.

  Track C's runner (docs/roadmap.md), now with the interpreter tier wired
  in (Track E; interp-spec §6). Wasm.Wast is the front end — lexer,
  s-expression parser, command classifier — and keeps module payloads as
  raw trees. This unit turns those trees into verdicts, and now RUNS the
  action and result assertions rather than skipping them.

  WHAT IS JUDGED. Decode (Wasm.Decoder), validation (Wasm.Validator), and
  execution (Wasm.Interp) are shipped; there is no text-format assembler.
  So the judged command shapes all need the module in `(module binary ...)`
  form:

    - `(module binary ...)` at top level — decode, validate, INSTANTIATE,
      and run any start function
    - `(assert_malformed (module binary ...) "...")` — EWasmDecodeError
    - `(assert_invalid   (module binary ...) "...")` — EWasmValidationError
    - `(register "name" $id?)` — bind an instance's exports under an import
      name, for later modules to import
    - `(invoke "f" args...)` — run an exported function for effect
    - `(assert_return (invoke/get ...) results...)` — run and COMPARE each
      result bitwise / by NaN class / by reference identity (Wasm.Wast.Values)
    - `(assert_trap       (invoke ...) "msg")` — expect an EWasmTrap whose
      message the expected string is a prefix of
    - `(assert_exhaustion (invoke ...) "msg")` — the exhaustion trap

  Everything else is SKIPPED with a reason, never silently counted as a
  pass: text/quoted modules (no assembler), assertions whose current module
  is a text module (no instance), imports the harness cannot satisfy (the
  host `spectest` module is not provided), and the testsuite-local
  directives outside the reference grammar (wcUnknown). A skip is an honest
  "not judged".

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

  STAGED. `$FD` vector work is staged to Track G and exception handling to
  Track H. A validation or execution that trips one of those staged
  messages, or an assertion whose values are `v128`/`(either ...)`, is
  recorded as STAGED — visible, counted apart, never a false pass or fail. }
unit Wasm.Wast.Runner;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Decoder,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator,
  Wasm.Wast,
  Wasm.Wast.Values;

const
  { Skip reasons. Public because they are the honest boundary of what the
    harness can judge, and the tests assert on them rather than on prose
    spelled twice. }
  WAST_REASON_TEXT_FORMAT = 'text format not yet assembled';
  WAST_REASON_NEEDS_TIER = 'needs an execution tier';
  WAST_REASON_UNKNOWN_DIRECTIVE = 'directive not in the reference grammar';
  WAST_REASON_NO_MODULE_OPERAND = 'no module operand';

  { An action or assertion whose current module never instantiated — a text
    module, or one whose imports could not be satisfied. Not a divergence,
    just nothing to run it against. }
  WAST_REASON_NO_INSTANCE = 'no instantiated module';
  WAST_REASON_UNRESOLVED_IMPORT = 'import not provided by the harness';
  WAST_REASON_NO_EXPORT = 'no such export';
  WAST_REASON_EXCEPTIONS = 'exception handling not implemented (Track H)';

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
    load-bearing (AGENTS.md): malformed and invalid are different answers.
    wekOther is anything that is not one of the two — reported as a failure
    rather than allowed to abort the run. }
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
  is malformed. }
function RunWastSource(const ASource: string): TWastRunResult;

{ Read APath and run it. }
function RunWastFile(const APath: string): TWastRunResult;

function WastStatusName(const AStatus: TWastStatus): string;
function WastErrorKindName(const AKind: TWastErrorKind): string;

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

{ True when a message names deliberately staged work — SIMD (validator or
  GC vec storage) or exception handling — so the harness records STAGED
  rather than a false failure. }
function IsStagedMessage(const AMsg: string): Boolean;
begin
  Result := IsStagedFeatureMessage(AMsg)
    or ((Length(AMsg) >= Length('exception handling is not implemented'))
        and (Copy(AMsg, 1, Length('exception handling is not implemented'))
             = 'exception handling is not implemented'));
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
  public
    constructor Create;
    destructor Destroy; override;

    function LookupNamed(const AId: string): TWasmModuleInstance;
    function LookupRegistry(const AName: string): TWasmModuleInstance;
    procedure BindNamed(const AId: string; const AInst: TWasmModuleInstance);
    procedure RegisterName(const AName: string;
      const AInst: TWasmModuleInstance);
    { Mint (once) and return a stable host box carrying identity AId, kept
      alive as a root for the life of the script. }
    function HostRef(const AId: UInt32): TWasmRef;

    property Engine: TWasmEngine read FEngine;
    property Store: TWasmStore read FStore;
    property Model: TWasmModule read FModel;
    property Current: TWasmModuleInstance read FCurrent write FCurrent;
  end;

constructor TWastRunner.Create;
begin
  inherited Create;
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  RegisterInterpreter(FStore);
  FModel := TWasmModule.Create;
  FCurrent := nil;
end;

destructor TWastRunner.Destroy;
var
  I: Integer;
begin
  { The store owns the instances, which borrow the IR, which borrows the
    buffer — so free in that order. }
  FStore.Free;
  FEngine.Free;
  for I := 0 to High(FIrs) do
    FIrs[I].Free;
  FModel.Free;
  inherited Destroy;
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
  TWastActionKind = (wakOk, wakTrap, wakStaged, wakNoExport, wakError,
    wakBadValue);

  { The outcome of running an action: values on wakOk, a message on the
    error kinds. }
  TWastActionResult = record
    Kind: TWastActionKind;
    Values: array of TWasmValue;
    Count: Integer;
    Message: string;
  end;

{ Parse the argument nodes [AFirst .. end) of an action into a runtime param
  buffer, sized to the function's declared parameter count. Reference
  identities are minted via the runner. A v128/either argument stages the
  whole action. }
function MarshalArgs(const ARunner: TWastRunner; const AAction: TWastNode;
  const AFirst: Integer; const AParamCount: Integer;
  var AParams: array of TWasmValue; var AResult: TWastActionResult): Boolean;
var
  I, Slot: Integer;
  Val: TWastVal;
begin
  Result := False;
  for I := 0 to AParamCount - 1 do
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
    if WastValIsStaged(Val) then
    begin
      AResult.Kind := wakStaged;
      AResult.Message := 'SIMD argument';
      Exit;
    end;
    if Slot < AParamCount then
    begin
      case Val.Kind of
        wvcRefExtern, wvcRefHost:
          AParams[Slot] := MakeValueRef(ARunner.HostRef(Val.Id));
        wvcRefFunc:
          AParams[Slot] := MakeValueNullRef;   { rarely an argument }
      else
        AParams[Slot] := WastValToRuntime(Val);
      end;
    end;
    Inc(Slot);
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
  I, ParamCount, ResultCount: Integer;
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
  ParamCount := Length(Func.Params);
  ResultCount := Length(Func.Results);

  SetLength(Params, ParamCount);
  if not MarshalArgs(ARunner, AAction, ANameIndex + 1, ParamCount,
    Params, Result) then
    Exit;   { staged / bad value — Result already set }

  SetLength(Results, ResultCount);
  if ParamCount > 0 then
    ParamPtr := @Params[0]
  else
    ParamPtr := nil;
  if ResultCount > 0 then
    ResultPtr := @Results[0]
  else
    ResultPtr := nil;

  try
    InterpInvoke(ARunner.Store, Addr, ParamPtr, ResultPtr);
    Result.Kind := wakOk;
    Result.Count := ResultCount;
    SetLength(Result.Values, ResultCount);
    for I := 0 to ResultCount - 1 do
      Result.Values[I] := Results[I];
  except
    on E: EWasmTrap do
    begin
      Result.Kind := wakTrap;
      Result.Message := E.Message;
    end;
    on E: EWasmError do
    begin
      if IsStagedMessage(E.Message) then
        Result.Kind := wakStaged
      else
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

{ Decode, validate, instantiate, and run the start function of a top-level
  binary module. The IR and bytes are retained so the instance can borrow
  them for the life of the script. }
procedure RunModuleCommand(const ARunner: TWastRunner;
  const ACommand: TWastCommand; var AResult: TWastCommandResult);
var
  Bytes: TWasmBytes;
  Ir: TWasmIrModule;
  Imports: TWasmImports;
  Inst: TWasmModuleInstance;
  Why, Id: string;
begin
  { A text/quoted module leaves no instance — clear Current so later actions
    skip honestly rather than run against a stale module. }
  ARunner.Current := nil;
  if ACommand.ModuleForm <> wmfBinary then
  begin
    Skipped(AResult, WAST_REASON_TEXT_FORMAT);
    Exit;
  end;

  Bytes := ModuleBinaryBytes(ACommand.Node);
  Ir := nil;
  try
    DecodeModule(Bytes, ARunner.Model);
    Ir := ValidateModule(ARunner.Model, Bytes);
  except
    on E: EWasmDecodeError do
    begin
      AResult.ActualKind := wekDecode;
      AResult.Actual := E.Message;
      AResult.Status := wrsFail;
      Exit;
    end;
    on E: EWasmValidationError do
    begin
      AResult.ActualKind := wekValidation;
      AResult.Actual := E.Message;
      if IsStagedFeatureMessage(E.Message) then
        AResult.Status := wrsStaged
      else
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

  if not ResolveImports(ARunner, ARunner.Model, Imports, Why) then
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
  Bytes := ARunner.FBuffers[High(ARunner.FBuffers)];

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
      if IsStagedMessage(E.Message) then
        AResult.Status := wrsStaged
      else
        AResult.Status := wrsFail;
      Exit;
    end;
  end;

  ARunner.Current := Inst;
  Id := ModuleId(ACommand.Node);
  if Id <> '' then
    ARunner.BindNamed(Id, Inst);
  AResult.Status := wrsPass;
end;

{ `assert_malformed` / `assert_invalid`: the module must fail with the error
  class AWant and a message the script's expected string is a prefix of. }
procedure RunAssertFailure(const ARunner: TWastRunner;
  const ACommand: TWastCommand; const AWant: TWastErrorKind;
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

  Kind := AttemptModule(ModuleBinaryBytes(Operand), ARunner.Model, Msg);
  AResult.ActualKind := Kind;
  if Kind = wekNone then
    AResult.Actual := WAST_NO_ERROR
  else
    AResult.Actual := Msg;

  if (Kind = AWant) and WastMessageMatches(AResult.Expected, Msg) then
    AResult.Status := wrsPass
  else if (Kind = AWant) and IsStagedFeatureMessage(Msg) then
    AResult.Status := wrsStaged
  else
    AResult.Status := wrsFail;
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
  HasInstance, AllMatch: Boolean;
  I, ExpectCount: Integer;
  Expected: TWastVal;
  Expecteds: array of TWastVal;
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
    wakStaged:
      begin
        AResult.Status := wrsStaged;
        AResult.Actual := Act.Message;
        Exit;
      end;
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
    wakError:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected error: ' + Act.Message;
        Exit;
      end;
  end;

  { First pass: parse each expected value ONCE (cached in Expecteds for the
    compare pass below). Any value that stages (v128/either) stages the whole
    assertion — SIMD results are Track G. }
  SetLength(Expecteds, ExpectCount);
  for I := 0 to ExpectCount - 1 do
  begin
    try
      Expecteds[I] := WastParseVal(ACommand.Node[2 + I]);
    except
      on E: EWastValueError do
      begin
        Skipped(AResult, 'unsupported value: ' + E.Message);
        Exit;
      end;
    end;
    if WastValIsStaged(Expecteds[I]) then
    begin
      AResult.Status := wrsStaged;
      AResult.Actual := 'SIMD result';
      Exit;
    end;
  end;

  if Act.Count <> ExpectCount then
  begin
    AResult.Status := wrsFail;
    AResult.Actual := Format('result count %d, expected %d',
      [Act.Count, ExpectCount]);
    Exit;
  end;

  AllMatch := True;
  ActualText := '';
  for I := 0 to ExpectCount - 1 do
  begin
    Expected := Expecteds[I];
    if ActualText <> '' then
      ActualText := ActualText + ' ';
    ActualText := ActualText + RenderActual(Act.Values[I], Expected.Width);
    if not WastValMatches(Expected, Act.Values[I],
      ExpectedRefFor(ARunner, Expected)) then
      AllMatch := False;
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
    { assert_trap over a (module ...) instantiation trap is not in this
      corpus; only the action form is handled. }
    Skipped(AResult, WAST_REASON_NO_MODULE_OPERAND);
    Exit;
  end;
  Action := ACommand.Node[1];
  AResult.Expected := ExpectedFailure(ACommand.Node);

  Act := RunAction(ARunner, Action, HasInstance);
  if not HasInstance then
  begin
    Skipped(AResult, WAST_REASON_NO_INSTANCE);
    Exit;
  end;

  case Act.Kind of
    wakStaged:
      begin
        AResult.Status := wrsStaged;
        AResult.Actual := Act.Message;
      end;
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
    wakStaged:
      begin
        AResult.Status := wrsStaged;
        AResult.Actual := Act.Message;
      end;
    wakNoExport:
      Skipped(AResult, WAST_REASON_NO_EXPORT + ': ' + Act.Message);
    wakBadValue:
      Skipped(AResult, 'unsupported value: ' + Act.Message);
    wakTrap:
      begin
        AResult.Status := wrsFail;
        AResult.Actual := 'unexpected trap: ' + Act.Message;
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
      Skipped(Result, WAST_REASON_EXCEPTIONS);
    wcAssertUnlinkable:
      { The corpus spells these with text modules, which cannot be
        assembled; a binary unlinkable case would need the same import
        plumbing and is out of scope here. }
      Skipped(Result, WAST_REASON_TEXT_FORMAT);
    wcUnknown:
      Skipped(Result, WAST_REASON_UNKNOWN_DIRECTIVE);
  else
    Skipped(Result, WAST_REASON_NEEDS_TIER);
  end;
end;

{ --- entry points -------------------------------------------------------- }

function RunWastScript(const AScript: TWastScript): TWastRunResult;
var
  I: Integer;
  Runner: TWastRunner;
begin
  Result := TWastRunResult.Create;
  try
    Runner := TWastRunner.Create;
    try
      for I := 0 to AScript.Count - 1 do
        Result.AddResult(ExecuteCommand(Runner, AScript[I]));
    finally
      Runner.Free;
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
  Result := RunWastSource(BytesToText(LoadFileBytes(APath)));
end;

end.
