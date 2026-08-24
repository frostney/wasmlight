{ Unit suite for Wasm.Native.Call — live AAPCS64 / SysV calls.

  Direct Pascal `cdecl` function pointers prove the precompiled gate on
  this host. A clang-built C fixture and an FPC-built Pascal library then
  prove that a C symbol and a Pascal `cdecl` export are observationally
  identical, and that a missing symbol is a link error.

  Placement-only cases stay in Wasm.Abi.Test so Windows/32-bit CI still
  judges the planner. }
program Wasm.Native.Call.Test;

{$I Shared.inc}

{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_NATIVE_CALL}
{$ENDIF}

uses
  Process,
  SysUtils,

  TestingPascalLibrary,
  Wasm.Abi,
  Wasm.Core,
  Wasm.Native.Call,
  Wasm.Native.Load;

type
  TPairI32 = record
    A: Int32;
    B: Int32;
  end;

  TPairF32 = record
    A: Single;
    B: Single;
  end;

  TBig24 = record
    A: Int64;
    B: Int64;
    C: Int64;
  end;

function HostAddI32(A, B: Int32): Int32; cdecl;
begin
  Result := A + B;
end;

function HostAddI64(A, B: Int64): Int64; cdecl;
begin
  Result := A + B;
end;

function HostAddF64(A, B: Double): Double; cdecl;
begin
  Result := A + B;
end;

function HostSum9(A, B, C, D, E, F, G, H, I: Int32): Int32; cdecl;
begin
  Result := A + B + C + D + E + F + G + H + I;
end;

function HostSum10(A, B, C, D, E, F, G, H, I, J: Int32): Int32; cdecl;
begin
  Result := A + B + C + D + E + F + G + H + I + J;
end;

function HostAddPair(X, Y: TPairI32): TPairI32; cdecl;
begin
  Result.A := X.A + Y.A;
  Result.B := X.B + Y.B;
end;

function HostAddHfa(X, Y: TPairF32): TPairF32; cdecl;
begin
  Result.A := X.A + Y.A;
  Result.B := X.B + Y.B;
end;

function HostLoadPtr(const P: PInt32): Int32; cdecl;
begin
  Result := P^;
end;

function HostSumBig(S: TBig24): Int64; cdecl;
begin
  Result := S.A + S.B + S.C;
end;

type
  TCallTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestSupportedPredicate;
    procedure TestIncompatiblePlanIsALinkError;
    procedure TestPascalCdeclScalars;
    procedure TestPascalCdeclStackAndAggregates;
    procedure TestPascalCdeclPointerView;
    procedure TestCAndPascalLibrariesMatch;
    procedure TestMissingSymbolIsALinkError;
  end;

function CallI32(const AFn: Pointer; const A, B: Int32): Int32;
var
  Plan: TWasmAbiPlan;
  Ret: TWasmAbiValue;
begin
  Plan := PlanCall(AbiHostTarget, AbiSignature([AbiI32, AbiI32], AbiI32));
  ApplyNativeCall(Plan, AFn, [AbiValueI32(A), AbiValueI32(B)], Ret);
  Result := AbiValueAsI32(Ret);
end;

function QuoteUnix(const APath: string): string;
begin
  Result := '''' + StringReplace(APath, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function SearchFixtureFrom(const AStart: string): string;
var
  Here: string;
  Candidate: string;
begin
  Result := '';
  Here := ExcludeTrailingPathDelimiter(AStart);
  while Here <> '' do
  begin
    Candidate := IncludeTrailingPathDelimiter(Here) + 'tests/fixtures/abi';
    if FileExists(IncludeTrailingPathDelimiter(Candidate) + 'wasmlightabi.c') then
    begin
      Result := Candidate;
      Exit;
    end;
    if ExtractFilePath(Here) = Here then
      Break;
    Here := ExcludeTrailingPathDelimiter(ExtractFilePath(Here));
  end;
end;

function FindFixtureRoot: string;
begin
  Result := SearchFixtureFrom(GetCurrentDir);
  if Result = '' then
    Result := SearchFixtureFrom(ExtractFilePath(ParamStr(0)));
end;

function CompileShared(const ACmd: string): Boolean;
var
  OutText: string;
begin
  Result := False;
  try
    Result := RunCommand('/bin/sh', ['-c', ACmd], OutText);
  except
    Result := False;
  end;
end;

procedure TCallTests.TestSupportedPredicate;
begin
  {$IFDEF WASM_NATIVE_CALL}
  Expect<Boolean>(NativeCallSupported).ToBe(True);
  {$ELSE}
  Expect<Boolean>(NativeCallSupported).ToBe(False);
  {$ENDIF}
end;

procedure TCallTests.TestIncompatiblePlanIsALinkError;
var
  Plan: TWasmAbiPlan;
  Ret: TWasmAbiValue;
  RaisedOk: Boolean;
begin
  RaisedOk := False;
  Plan := PlanCall(wabNone, AbiSignature([AbiI32], AbiI32));
  try
    ApplyNativeCall(Plan, @HostAddI32, [AbiValueI32(1)], Ret);
  except
    on E: EWasmLinkError do
      RaisedOk := Pos(string(MSG_LINK_INCOMPATIBLE_PLAN), E.Message) = 1;
  end;
  Expect<Boolean>(RaisedOk).ToBe(True);
end;

procedure TCallTests.TestPascalCdeclScalars;
{$IFDEF WASM_NATIVE_CALL}
var
  Plan: TWasmAbiPlan;
  Ret: TWasmAbiValue;
{$ENDIF}
begin
  {$IFDEF WASM_NATIVE_CALL}
  Expect<Int32>(CallI32(@HostAddI32, 17, 25)).ToBe(42);
  Plan := PlanCall(AbiHostTarget, AbiSignature([AbiI64, AbiI64], AbiI64));
  ApplyNativeCall(Plan, @HostAddI64, [AbiValueI64(100), AbiValueI64(20)], Ret);
  Expect<Int64>(AbiValueAsI64(Ret)).ToBe(120);
  Plan := PlanCall(AbiHostTarget, AbiSignature([AbiF64, AbiF64], AbiF64));
  ApplyNativeCall(Plan, @HostAddF64, [AbiValueF64(1.5), AbiValueF64(2.25)], Ret);
  Expect<Boolean>(Abs(AbiValueAsF64(Ret) - 3.75) < 0.0001).ToBe(True);
  {$ELSE}
  Expect<Boolean>(NativeCallSupported).ToBe(False);
  {$ENDIF}
end;

procedure TCallTests.TestPascalCdeclStackAndAggregates;
{$IFDEF WASM_NATIVE_CALL}
var
  Plan: TWasmAbiPlan;
  Ret: TWasmAbiValue;
  Params: array of TWasmCType;
  Args: array of TWasmAbiValue;
  I: Integer;
{$ENDIF}
begin
  {$IFDEF WASM_NATIVE_CALL}
  SetLength(Params, 9);
  SetLength(Args, 9);
  for I := 0 to 8 do
  begin
    Params[I] := AbiI32;
    Args[I] := AbiValueI32(I + 1);
  end;
  Plan := PlanCall(AbiHostTarget, AbiSignature(Params, AbiI32));
  ApplyNativeCall(Plan, @HostSum9, Args, Ret);
  Expect<Int32>(AbiValueAsI32(Ret)).ToBe(45);

  { Two (AAPCS64) or four (SysV) stack slots: Offset is the stack
    address, not an index into the argument bytes. }
  SetLength(Params, 10);
  SetLength(Args, 10);
  for I := 0 to 9 do
  begin
    Params[I] := AbiI32;
    Args[I] := AbiValueI32(I + 1);
  end;
  Plan := PlanCall(AbiHostTarget, AbiSignature(Params, AbiI32));
  ApplyNativeCall(Plan, @HostSum10, Args, Ret);
  Expect<Int32>(AbiValueAsI32(Ret)).ToBe(55);

  Plan := PlanCall(AbiHostTarget,
    AbiSignature([AbiStruct([AbiI32, AbiI32]), AbiStruct([AbiI32, AbiI32])],
      AbiStruct([AbiI32, AbiI32])));
  ApplyNativeCall(Plan, @HostAddPair,
    [AbiValueBytes([1, 0, 0, 0, 2, 0, 0, 0]),
     AbiValueBytes([3, 0, 0, 0, 4, 0, 0, 0])], Ret);
  Expect<Int32>(PInteger(@Ret.Data[0])^).ToBe(4);
  Expect<Int32>(PInteger(@Ret.Data[4])^).ToBe(6);

  Plan := PlanCall(AbiHostTarget,
    AbiSignature([AbiStruct([AbiF32, AbiF32]), AbiStruct([AbiF32, AbiF32])],
      AbiStruct([AbiF32, AbiF32])));
  ApplyNativeCall(Plan, @HostAddHfa,
    [AbiValueBytes([0, 0, 128, 63, 0, 0, 0, 64]),
     AbiValueBytes([0, 0, 64, 64, 0, 0, 160, 64])], Ret);
  { 1.0+3.0=4.0, 2.0+5.0=7.0 — IEEE little-endian. }
  Expect<Boolean>(Abs(PSingle(@Ret.Data[0])^ - 4.0) < 0.0001).ToBe(True);
  Expect<Boolean>(Abs(PSingle(@Ret.Data[4])^ - 7.0) < 0.0001).ToBe(True);

  Plan := PlanCall(AbiHostTarget,
    AbiSignature([AbiStruct([AbiI64, AbiI64, AbiI64])], AbiI64));
  ApplyNativeCall(Plan, @HostSumBig,
    [AbiValueBytes([10, 0, 0, 0, 0, 0, 0, 0,
                    20, 0, 0, 0, 0, 0, 0, 0,
                    12, 0, 0, 0, 0, 0, 0, 0])], Ret);
  Expect<Int64>(AbiValueAsI64(Ret)).ToBe(42);
  {$ELSE}
  Expect<Boolean>(NativeCallSupported).ToBe(False);
  {$ENDIF}
end;

procedure TCallTests.TestPascalCdeclPointerView;
{$IFDEF WASM_NATIVE_CALL}
var
  Plan: TWasmAbiPlan;
  Ret: TWasmAbiValue;
  Value: Int32;
{$ENDIF}
begin
  {$IFDEF WASM_NATIVE_CALL}
  Value := 99;
  Plan := PlanCall(AbiHostTarget, AbiSignature([AbiPointerTo(AbiI32)], AbiI32));
  ApplyNativeCall(Plan, @HostLoadPtr, [AbiValuePointer(@Value)], Ret);
  Expect<Int32>(AbiValueAsI32(Ret)).ToBe(99);
  {$ELSE}
  Expect<Boolean>(NativeCallSupported).ToBe(False);
  {$ENDIF}
end;

procedure TCallTests.TestCAndPascalLibrariesMatch;
{$IFDEF WASM_NATIVE_CALL}
var
  Root: string;
  Work: string;
  CLib: string;
  PasLib: string;
  CName: string;
  PasName: string;
  ClangOk: Boolean;
  FpcOk: Boolean;
  CHandle: TWasmNativeLibrary;
  PasHandle: TWasmNativeLibrary;
  CFn: Pointer;
  PasFn: Pointer;
  Plan: TWasmAbiPlan;
  Ret: TWasmAbiValue;
  Params: array of TWasmCType;
  Args: array of TWasmAbiValue;
  I: Integer;
{$ENDIF}
begin
  {$IFDEF WASM_NATIVE_CALL}
  Root := FindFixtureRoot;
  Expect<Boolean>(Root <> '').ToBe(True);
  Work := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight-abi-' + IntToStr(GetProcessID);
  ForceDirectories(Work);
  {$IFDEF DARWIN}
  CName := 'libwasmlightabi.dylib';
  PasName := 'libwasmlightabi_pas.dylib';
  ClangOk := CompileShared('clang -dynamiclib -o ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Work) + CName) + ' ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Root) + 'wasmlightabi.c'));
  FpcOk := CompileShared('fpc -Mdelphi -Cg -fPIC -o' +
    IncludeTrailingPathDelimiter(Work) + PasName + ' ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Root) + 'libwasmlightabi.pas'));
  {$ELSE}
  CName := 'libwasmlightabi.so';
  PasName := 'libwasmlightabi_pas.so';
  ClangOk := CompileShared('clang -shared -fPIC -o ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Work) + CName) + ' ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Root) + 'wasmlightabi.c'));
  FpcOk := CompileShared('fpc -Mdelphi -Cg -fPIC -o' +
    IncludeTrailingPathDelimiter(Work) + PasName + ' ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Root) + 'libwasmlightabi.pas'));
  {$ENDIF}
  Expect<Boolean>(ClangOk).ToBe(True);
  Expect<Boolean>(FpcOk).ToBe(True);
  CLib := CName;
  PasLib := PasName;
  { Load by relative filename so resolution stays beside Work. }
  CHandle := LoadLocalLibraryAt(CLib, Work);
  PasHandle := LoadLocalLibraryAt(PasLib, Work);
  try
    CFn := LookupLocalSymbol(CHandle, 'add_i32');
    PasFn := LookupLocalSymbol(PasHandle, 'add_i32');
    Expect<Int32>(CallI32(CFn, 17, 25)).ToBe(42);
    Expect<Int32>(CallI32(PasFn, 17, 25)).ToBe(42);
    CFn := LookupLocalSymbol(CHandle, 'sum9');
    PasFn := LookupLocalSymbol(PasHandle, 'sum9');
    SetLength(Params, 9);
    SetLength(Args, 9);
    for I := 0 to 8 do
    begin
      Params[I] := AbiI32;
      Args[I] := AbiValueI32(I + 1);
    end;
    Plan := PlanCall(AbiHostTarget, AbiSignature(Params, AbiI32));
    ApplyNativeCall(Plan, CFn, Args, Ret);
    Expect<Int32>(AbiValueAsI32(Ret)).ToBe(45);
    ApplyNativeCall(Plan, PasFn, Args, Ret);
    Expect<Int32>(AbiValueAsI32(Ret)).ToBe(45);
  finally
    CHandle.Free;
    PasHandle.Free;
  end;
  {$ELSE}
  Expect<Boolean>(NativeCallSupported).ToBe(False);
  {$ENDIF}
end;

procedure TCallTests.TestMissingSymbolIsALinkError;
{$IFDEF WASM_NATIVE_CALL}
var
  Root: string;
  Work: string;
  Name: string;
  Ok: Boolean;
  Lib: TWasmNativeLibrary;
  RaisedOk: Boolean;
{$ENDIF}
begin
  {$IFDEF WASM_NATIVE_CALL}
  Root := FindFixtureRoot;
  Work := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight-abi-miss-' + IntToStr(GetProcessID);
  ForceDirectories(Work);
  {$IFDEF DARWIN}
  Name := 'libwasmlightabi.dylib';
  Ok := CompileShared('clang -dynamiclib -o ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Work) + Name) + ' ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Root) + 'wasmlightabi.c'));
  {$ELSE}
  Name := 'libwasmlightabi.so';
  Ok := CompileShared('clang -shared -fPIC -o ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Work) + Name) + ' ' +
    QuoteUnix(IncludeTrailingPathDelimiter(Root) + 'wasmlightabi.c'));
  {$ENDIF}
  Expect<Boolean>(Ok).ToBe(True);
  Lib := LoadLocalLibraryAt(Name, Work);
  RaisedOk := False;
  try
    try
      LookupLocalSymbol(Lib, 'definitely_missing_symbol');
    except
      on E: EWasmLinkError do
        RaisedOk := Pos(string(MSG_LINK_UNKNOWN_SYMBOL), E.Message) = 1;
    end;
  finally
    Lib.Free;
  end;
  Expect<Boolean>(RaisedOk).ToBe(True);
  {$ELSE}
  Expect<Boolean>(NativeCallSupported).ToBe(False);
  {$ENDIF}
end;

procedure TCallTests.SetupTests;
begin
  Test('native-call support predicate matches the compiled leg',
    TestSupportedPredicate);
  Test('incompatible plan is a link error', TestIncompatiblePlanIsALinkError);
  Test('Pascal cdecl scalars through the precompiled gate',
    TestPascalCdeclScalars);
  Test('stack, pair, HFA, and large aggregate through the gate',
    TestPascalCdeclStackAndAggregates);
  Test('pointer-view loads through the gate', TestPascalCdeclPointerView);
  Test('C and Pascal fixture libraries are observationally identical',
    TestCAndPascalLibrariesMatch);
  Test('missing symbol is a link error', TestMissingSymbolIsALinkError);
end;

begin
  TestRunnerProgram.AddSuite(TCallTests.Create('Wasm.Native.Call'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
