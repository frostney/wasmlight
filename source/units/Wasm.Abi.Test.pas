{ Unit suite for Wasm.Abi — AAPCS64 and SysV x86-64 placement.

  These tests judge the PLAN, not a live call: both ABIs are asserted on
  every host so a cross-compiling planner cannot drift. Live calls live
  in Wasm.Native.Call.Test.

  Citations:
    AAPCS64 2025Q4 Stage C / Result return (ARM-software/abi-aa@daa7a94)
    System V AMD64 ABI 1.0 §3.2.3 }
program Wasm.Abi.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Abi,
  Wasm.Core;

type
  TAbiTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestHostTargetIsUnixOrNone;
    procedure TestUnsupportedTargetIsIncompatible;
    procedure TestLayoutScalarsAndStruct;
    procedure TestAapcs64ScalarsAndStack;
    procedure TestAapcs64ApplePacksStackNaturally;
    procedure TestAapcs64HfaAndLargeAggregate;
    procedure TestAapcs64ReturnHidden;
    procedure TestSysvScalarsAndSeventhInt;
    procedure TestSysvMixedEightbyteAndMemoryReturn;
    procedure TestPointerViewIsIntegerClass;
  end;

function Piece(const AArg: TWasmAbiArgPlan; const AIndex: Integer): TWasmAbiPiece;
begin
  Expect<Boolean>(Length(AArg.Pieces) > AIndex).ToBe(True);
  Result := AArg.Pieces[AIndex];
end;

procedure TAbiTests.TestHostTargetIsUnixOrNone;
var
  Target: TWasmAbiTarget;
begin
  Target := AbiHostTarget;
  {$IF DEFINED(UNIX) AND DEFINED(CPUAARCH64) AND DEFINED(DARWIN)}
  Expect<TWasmAbiTarget>(Target).ToBe(wabAapcs64Apple);
  {$ELSEIF DEFINED(UNIX) AND DEFINED(CPUAARCH64)}
  Expect<TWasmAbiTarget>(Target).ToBe(wabAapcs64);
  {$ELSEIF DEFINED(UNIX) AND DEFINED(CPUX86_64)}
  Expect<TWasmAbiTarget>(Target).ToBe(wabSysvX64);
  {$ELSE}
  Expect<TWasmAbiTarget>(Target).ToBe(wabNone);
  {$ENDIF}
end;

procedure TAbiTests.TestUnsupportedTargetIsIncompatible;
var
  Plan: TWasmAbiPlan;
begin
  Plan := PlanCall(wabNone, AbiSignature([AbiI32], AbiI32));
  Expect<Boolean>(Plan.Compatible).ToBe(False);
  Expect<Boolean>(Pos(string(MSG_LINK_INCOMPATIBLE_PLAN), Plan.Reason) = 1)
    .ToBe(True);
end;

procedure TAbiTests.TestLayoutScalarsAndStruct;
var
  Pair: TWasmCLayout;
  Big: TWasmCLayout;
begin
  Expect<UInt32>(AbiLayout(AbiI32).Size).ToBe(4);
  Expect<UInt32>(AbiLayout(AbiI32).Align).ToBe(4);
  Expect<UInt32>(AbiLayout(AbiF64).Size).ToBe(8);
  Expect<UInt32>(AbiLayout(AbiPointer).Size).ToBe(8);
  Pair := AbiLayout(AbiStruct([AbiI32, AbiI32]));
  Expect<UInt32>(Pair.Size).ToBe(8);
  Expect<UInt32>(Pair.Align).ToBe(4);
  Big := AbiLayout(AbiStruct([AbiI64, AbiI64, AbiI64]));
  Expect<UInt32>(Big.Size).ToBe(24);
  Expect<UInt32>(Big.Align).ToBe(8);
end;

procedure TAbiTests.TestAapcs64ScalarsAndStack;
var
  Plan: TWasmAbiPlan;
  I: Integer;
  Params: array of TWasmCType;
begin
  Plan := PlanCall(wabAapcs64, AbiSignature([AbiI32, AbiI64, AbiF64], AbiI32));
  Expect<Boolean>(Plan.Compatible).ToBe(True);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapIntReg);
  Expect<Byte>(Piece(Plan.Args[0], 0).Reg).ToBe(0);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[1], 0).Kind).ToBe(wapIntReg);
  Expect<Byte>(Piece(Plan.Args[1], 0).Reg).ToBe(1);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[2], 0).Kind).ToBe(wapFloatReg);
  Expect<Byte>(Piece(Plan.Args[2], 0).Reg).ToBe(0);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Result, 0).Kind).ToBe(wapIntReg);
  Expect<Byte>(Piece(Plan.Result, 0).Reg).ToBe(0);

  SetLength(Params, 9);
  for I := 0 to 8 do
    Params[I] := AbiI32;
  Plan := PlanCall(wabAapcs64, AbiSignature(Params, AbiVoid));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[7], 0).Kind).ToBe(wapIntReg);
  Expect<Byte>(Piece(Plan.Args[7], 0).Reg).ToBe(7);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[8], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[8], 0).Offset).ToBe(0);
  Expect<UInt32>(Plan.StackSize).ToBe(16);

  SetLength(Params, 10);
  for I := 0 to 9 do
    Params[I] := AbiI32;
  Plan := PlanCall(wabAapcs64, AbiSignature(Params, AbiVoid));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[8], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[8], 0).Offset).ToBe(0);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[9], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[9], 0).Offset).ToBe(8);
end;

procedure TAbiTests.TestAapcs64ApplePacksStackNaturally;
var
  Plan: TWasmAbiPlan;
  I: Integer;
  Params: array of TWasmCType;
begin
  SetLength(Params, 10);
  for I := 0 to 9 do
    Params[I] := AbiI32;
  Plan := PlanCall(wabAapcs64Apple, AbiSignature(Params, AbiVoid));
  Expect<Boolean>(Plan.Compatible).ToBe(True);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[8], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[8], 0).Offset).ToBe(0);
  Expect<UInt32>(Piece(Plan.Args[8], 0).Size).ToBe(4);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[9], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[9], 0).Offset).ToBe(4);
  Expect<UInt32>(Piece(Plan.Args[9], 0).Size).ToBe(4);
  Expect<UInt32>(Plan.StackSize).ToBe(16);
end;

procedure TAbiTests.TestAapcs64HfaAndLargeAggregate;
var
  Plan: TWasmAbiPlan;
  Hfa: TWasmCType;
  Big: TWasmCType;
begin
  Hfa := AbiStruct([AbiF32, AbiF32]);
  Plan := PlanCall(wabAapcs64, AbiSignature([Hfa], Hfa));
  Expect<Boolean>(Plan.Compatible).ToBe(True);
  Expect<Integer>(Length(Plan.Args[0].Pieces)).ToBe(2);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapFloatReg);
  Expect<Byte>(Piece(Plan.Args[0], 0).Reg).ToBe(0);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 1).Kind).ToBe(wapFloatReg);
  Expect<Byte>(Piece(Plan.Args[0], 1).Reg).ToBe(1);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Result, 0).Kind).ToBe(wapFloatReg);
  Expect<Boolean>(Plan.HiddenReturn).ToBe(False);

  Big := AbiStruct([AbiI64, AbiI64, AbiI64]);
  Plan := PlanCall(wabAapcs64, AbiSignature([Big], AbiI64));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapIndirect);
  Expect<Byte>(Piece(Plan.Args[0], 0).Reg).ToBe(0);
  Expect<UInt32>(Piece(Plan.Args[0], 0).Size).ToBe(24);
end;

procedure TAbiTests.TestAapcs64ReturnHidden;
var
  Plan: TWasmAbiPlan;
  Big: TWasmCType;
begin
  Big := AbiStruct([AbiI64, AbiI64, AbiI64]);
  Plan := PlanCall(wabAapcs64, AbiSignature([], Big));
  Expect<Boolean>(Plan.HiddenReturn).ToBe(True);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Result, 0).Kind).ToBe(wapHiddenReturn);
  Expect<Byte>(Piece(Plan.Result, 0).Reg).ToBe(8);
end;

procedure TAbiTests.TestSysvScalarsAndSeventhInt;
var
  Plan: TWasmAbiPlan;
  I: Integer;
  Params: array of TWasmCType;
begin
  Plan := PlanCall(wabSysvX64, AbiSignature([AbiI32, AbiF64], AbiI32));
  Expect<Boolean>(Plan.Compatible).ToBe(True);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapIntReg);
  Expect<Byte>(Piece(Plan.Args[0], 0).Reg).ToBe(0);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[1], 0).Kind).ToBe(wapFloatReg);
  Expect<Byte>(Piece(Plan.Args[1], 0).Reg).ToBe(0);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Result, 0).Kind).ToBe(wapIntReg);
  Expect<Byte>(Piece(Plan.Result, 0).Reg).ToBe(0);

  SetLength(Params, 7);
  for I := 0 to 6 do
    Params[I] := AbiI32;
  Plan := PlanCall(wabSysvX64, AbiSignature(Params, AbiVoid));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[5], 0).Kind).ToBe(wapIntReg);
  Expect<Byte>(Piece(Plan.Args[5], 0).Reg).ToBe(5);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[6], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[6], 0).Offset).ToBe(0);
  Expect<UInt32>(Plan.StackSize).ToBe(16);

  SetLength(Params, 8);
  for I := 0 to 7 do
    Params[I] := AbiI32;
  Plan := PlanCall(wabSysvX64, AbiSignature(Params, AbiVoid));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[6], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[6], 0).Offset).ToBe(0);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[7], 0).Kind).ToBe(wapStack);
  Expect<UInt32>(Piece(Plan.Args[7], 0).Offset).ToBe(8);
end;

procedure TAbiTests.TestSysvMixedEightbyteAndMemoryReturn;
var
  Plan: TWasmAbiPlan;
  Mixed: TWasmCType;
  Big: TWasmCType;
begin
  Mixed := AbiStruct([AbiI32, AbiF32]);
  Plan := PlanCall(wabSysvX64, AbiSignature([Mixed], Mixed));
  Expect<Boolean>(Plan.Compatible).ToBe(True);
  Expect<Integer>(Length(Plan.Args[0].Pieces)).ToBe(1);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapIntReg);
  Expect<Boolean>(Plan.HiddenReturn).ToBe(False);

  Big := AbiStruct([AbiI64, AbiI64, AbiI64]);
  Plan := PlanCall(wabSysvX64, AbiSignature([Big], Big));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapStack);
  Expect<Boolean>(Plan.HiddenReturn).ToBe(True);
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Result, 0).Kind).ToBe(wapHiddenReturn);
  { Hidden pointer occupies %rdi, so the MEMORY argument does not. }
end;

procedure TAbiTests.TestPointerViewIsIntegerClass;
var
  Plan: TWasmAbiPlan;
  View: TWasmCType;
begin
  View := AbiPointerTo(AbiI32);
  Plan := PlanCall(wabAapcs64, AbiSignature([View], AbiI32));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapIntReg);
  Plan := PlanCall(wabSysvX64, AbiSignature([View], AbiI32));
  Expect<TWasmAbiPlaceKind>(Piece(Plan.Args[0], 0).Kind).ToBe(wapIntReg);
  Expect<UInt32>(AbiLayout(View).Size).ToBe(8);
end;

procedure TAbiTests.SetupTests;
begin
  Test('host ABI target matches the compiled Unix leg',
    TestHostTargetIsUnixOrNone);
  Test('unsupported target is an incompatible plan',
    TestUnsupportedTargetIsIncompatible);
  Test('LP64 layout for scalars and aggregates', TestLayoutScalarsAndStruct);
  Test('AAPCS64 scalars, float, and 9th integer on the stack',
    TestAapcs64ScalarsAndStack);
  Test('Apple AAPCS64 packs stacked i32s at natural alignment',
    TestAapcs64ApplePacksStackNaturally);
  Test('AAPCS64 HFA registers and B.4 indirect large aggregate',
    TestAapcs64HfaAndLargeAggregate);
  Test('AAPCS64 large result uses x8', TestAapcs64ReturnHidden);
  Test('SysV scalars and 7th integer on the stack',
    TestSysvScalarsAndSeventhInt);
  Test('SysV mixed eightbyte and MEMORY return',
    TestSysvMixedEightbyteAndMemoryReturn);
  Test('pointer-view is an integer/pointer register',
    TestPointerViewIsIntegerClass);
end;

begin
  TestRunnerProgram.AddSuite(TAbiTests.Create('Wasm.Abi'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
