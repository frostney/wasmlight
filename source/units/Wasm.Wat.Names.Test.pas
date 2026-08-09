{ Unit suite for Wasm.Wat.Names — the identifier/symbol resolver.

  The resolver is tested in isolation here; the assembler suite exercises it
  end-to-end against the §7 oracle cases. The pieces proved here are the ones
  whose defects are cheapest to find alone:

    - duplicate detection per space, with the `duplicate <space>` spelling
      (and `memory`, not `mem`);
    - the label STACK with shadowing — innermost-first de Bruijn depth;
    - the implicit-typeuse dedup/insert table: reuse the SMALLEST matching
      singular-final-func, append when none matches, and NEVER reuse a member
      of a multi-member rec group (the §7 risk);
    - per-type field namespaces and the shared param/local namespace. }
program Wasm.Wat.Names.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Wat.Names;

type
  TWatNamesTests = class(TTestSuite)
  private
    FNames: TWatNames;

    function I32: TWasmValueType;
    function F64: TWasmValueType;
    function FuncGroup(const AParams, AResults: array of TWasmValueType):
      TWasmRecType;
    function BindDuplicateOutcome(const ASpace: TWatSpace;
      const AName: string): string;
    function InternDefault: Integer;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestBindAndLookup;
    procedure TestDuplicateSpellings;
    procedure TestLabelShadowing;
    procedure TestInternReuseAppend;
    procedure TestInternDoesNotReuseRecMember;
    procedure TestFieldsAndLocals;
  end;

function TWatNamesTests.I32: TWasmValueType;
begin
  Result := MakeNumValueType(wntI32);
end;

function TWatNamesTests.F64: TWasmValueType;
begin
  Result := MakeNumValueType(wntF64);
end;

function TWatNamesTests.FuncGroup(
  const AParams, AResults: array of TWasmValueType): TWasmRecType;
var
  Func: TWasmFuncType;
  I: Integer;
begin
  SetLength(Func.Params, Length(AParams));
  for I := 0 to High(AParams) do
    Func.Params[I] := AParams[I];
  SetLength(Func.Results, Length(AResults));
  for I := 0 to High(AResults) do
    Func.Results[I] := AResults[I];
  SetLength(Result.SubTypes, 1);
  Result.SubTypes[0].IsFinal := True;
  Result.SubTypes[0].SuperTypes := nil;
  Result.SubTypes[0].Comp := MakeFuncCompType(Func);
end;

procedure TWatNamesTests.BeforeEach;
begin
  FNames := TWatNames.Create;
end;

procedure TWatNamesTests.AfterEach;
begin
  FreeAndNil(FNames);
end;

function TWatNamesTests.BindDuplicateOutcome(const ASpace: TWatSpace;
  const AName: string): string;
begin
  Result := 'no error';
  try
    FNames.Bind(ASpace, AName);
    FNames.Bind(ASpace, AName);
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatNamesTests.InternDefault: Integer;
var
  Empty: array of TWasmValueType;
begin
  Empty := nil;
  Result := FNames.InternFuncType(Empty, Empty);
end;

procedure TWatNamesTests.TestBindAndLookup;
begin
  Expect<Integer>(FNames.Bind(wnsFunc, 'a')).ToBe(0);
  Expect<Integer>(FNames.Bind(wnsFunc, '')).ToBe(1);   { anonymous still counts }
  Expect<Integer>(FNames.Bind(wnsFunc, 'b')).ToBe(2);
  Expect<Integer>(FNames.LookupName(wnsFunc, 'a')).ToBe(0);
  Expect<Integer>(FNames.LookupName(wnsFunc, 'b')).ToBe(2);
  Expect<Integer>(FNames.LookupName(wnsFunc, 'missing')).ToBe(-1);
  Expect<Integer>(FNames.SpaceCount(wnsFunc)).ToBe(3);
  { Spaces are independent. }
  Expect<Integer>(FNames.Bind(wnsGlobal, 'a')).ToBe(0);
end;

procedure TWatNamesTests.TestDuplicateSpellings;
begin
  Expect<string>(BindDuplicateOutcome(wnsFunc, 'x')).ToBe('duplicate func');
  BeforeEach;   { fresh names for each spelling }
  Expect<string>(BindDuplicateOutcome(wnsMem, 'x')).ToBe('duplicate memory');
  BeforeEach;
  Expect<string>(BindDuplicateOutcome(wnsGlobal, 'x')).ToBe('duplicate global');
  BeforeEach;
  Expect<string>(BindDuplicateOutcome(wnsTable, 'x')).ToBe('duplicate table');
end;

procedure TWatNamesTests.TestLabelShadowing;
begin
  { Stack: push $a, $b, $a — the inner $a shadows the outer. }
  FNames.PushLabel('a');   { outermost }
  FNames.PushLabel('b');
  FNames.PushLabel('a');   { innermost, shadows }
  Expect<Integer>(FNames.LabelCount).ToBe(3);
  { $a resolves to the innermost (depth 0), NOT the outer (depth 2). }
  Expect<Integer>(FNames.LabelDepth('a')).ToBe(0);
  Expect<Integer>(FNames.LabelDepth('b')).ToBe(1);
  Expect<string>(FNames.InnermostLabelName).ToBe('a');
  { Pop the inner $a: now $a resolves to the outer, which is below $b. }
  FNames.PopLabel;
  Expect<Integer>(FNames.LabelDepth('a')).ToBe(1);
  Expect<Integer>(FNames.LabelDepth('b')).ToBe(0);
  { An unbound name has no depth. }
  Expect<Integer>(FNames.LabelDepth('c')).ToBe(-1);
end;

procedure TWatNamesTests.TestInternReuseAppend;
var
  Names0: array of string;
  Names1: array of string;
begin
  { Two explicit types: 0 = (i32)->(), 1 = ()->(f64). }
  SetLength(Names0, 1); Names0[0] := 't0';
  FNames.AddTypeGroup(FuncGroup([I32], []), Names0);
  SetLength(Names1, 1); Names1[0] := 't1';
  FNames.AddTypeGroup(FuncGroup([], [F64]), Names1);
  Expect<Integer>(FNames.TypeMemberCount).ToBe(2);

  { Reuse the smallest matching explicit type. }
  Expect<Integer>(FNames.InternFuncType([I32], [])).ToBe(0);
  Expect<Integer>(FNames.InternFuncType([], [F64])).ToBe(1);
  Expect<Integer>(FNames.TypeMemberCount).ToBe(2);   { nothing appended }

  { No match: append at the end, then reuse THAT on the next call. }
  Expect<Integer>(InternDefault).ToBe(2);            { ()->() appended }
  Expect<Integer>(FNames.TypeMemberCount).ToBe(3);
  Expect<Integer>(InternDefault).ToBe(2);            { reused, not re-appended }
  Expect<Integer>(FNames.TypeMemberCount).ToBe(3);
end;

procedure TWatNamesTests.TestInternDoesNotReuseRecMember;
var
  Rec: TWasmRecType;
  Names: array of string;
begin
  { A two-member rec group of ()->() functypes. Neither member is SINGULAR, so
    neither is a reuse candidate — type-rec.wast:45-61. }
  SetLength(Rec.SubTypes, 2);
  Rec.SubTypes[0] := FuncGroup([], []).SubTypes[0];
  Rec.SubTypes[1] := FuncGroup([], []).SubTypes[0];
  SetLength(Names, 2); Names[0] := 'ft0'; Names[1] := 'ft1';
  FNames.AddTypeGroup(Rec, Names);
  Expect<Integer>(FNames.TypeMemberCount).ToBe(2);

  { An implicit ()->() must NOT reuse members 0/1 — it appends index 2. }
  Expect<Integer>(InternDefault).ToBe(2);
  Expect<Integer>(FNames.TypeMemberCount).ToBe(3);
  { The freshly appended one IS singular/final/func, so a second reuses it. }
  Expect<Integer>(InternDefault).ToBe(2);
end;

procedure TWatNamesTests.TestFieldsAndLocals;
var
  Names: array of string;
  DupField, DupLocal: string;
begin
  { A struct type at index 0 with two named fields. }
  SetLength(Names, 1); Names[0] := '';
  FNames.AddTypeGroup(FuncGroup([], []), Names);   { index 0, a func — stands in }
  FNames.BindField(0, 'x');
  FNames.BindField(0, 'y');
  Expect<Integer>(FNames.LookupField(0, 'x')).ToBe(0);
  Expect<Integer>(FNames.LookupField(0, 'y')).ToBe(1);
  Expect<Integer>(FNames.LookupField(0, 'z')).ToBe(-1);

  DupField := 'no error';
  try
    FNames.BindField(0, 'x');
  except
    on E: EWasmTextError do
      DupField := E.Message;
  end;
  Expect<string>(DupField).ToBe('duplicate field');

  { Params and locals share one namespace: a clash is `duplicate local`. }
  FNames.ResetLocals;
  Expect<Integer>(FNames.BindLocal('p')).ToBe(0);   { a param }
  Expect<Integer>(FNames.BindLocal('')).ToBe(1);    { anonymous local }
  Expect<Integer>(FNames.LookupLocal('p')).ToBe(0);
  DupLocal := 'no error';
  try
    FNames.BindLocal('p');
  except
    on E: EWasmTextError do
      DupLocal := E.Message;
  end;
  Expect<string>(DupLocal).ToBe('duplicate local');
end;

procedure TWatNamesTests.SetupTests;
begin
  Test('bind assigns sequential indices and lookup resolves them',
    TestBindAndLookup);
  Test('duplicate ids are spelled `duplicate <space>` (memory, not mem)',
    TestDuplicateSpellings);
  Test('labels are a shadowing stack resolving innermost-first',
    TestLabelShadowing);
  Test('implicit typeuse reuses the smallest match or appends',
    TestInternReuseAppend);
  Test('implicit typeuse never reuses a multi-member rec-group member',
    TestInternDoesNotReuseRecMember);
  Test('field namespaces are per-type and params/locals share one',
    TestFieldsAndLocals);
end;

begin
  TestRunnerProgram.AddSuite(TWatNamesTests.Create('Wasm.Wat.Names'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
