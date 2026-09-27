{ Unit suite for Wasm.Jit.X64.Plan's scaled pinned index plan
  (X64PlanScaledIndex): which `i32.and` / `i32.shl` / access shapes fold the
  shift into the access's SIB scale, and which must not. The plan is a pure
  function of planned IR, so every case is a hand-built instruction list in
  the shape the driver hands over (constants already fused as immediates,
  lowering moves already skipped) and runs on every host.

  The base shape is the memory-store benchmark loop:
     0  i32.const r5 <- 16383   (fused)
     1  i32.and   r6 <- r0, 16383
     2  i32.const r7 <- 2       (fused)
     3  i32.shl   r2 <- r6, 2
     4  i32.store [r2] <- r0
     5  i32.const r12 <- 1      (fused)
     6  i32.add   r0 <- r0, 1
     7  i32.const r15 <- 1000   (fused)
     8  i32.lt_u  r16 <- r0, 1000
     9  branch_if_not r16 -> 11
    10  jump 0 (safepoint)
    11  move r3 <- r1           (label)
    12  return
  r0..r2 are locals ($i, $acc, $address) and r3 is the result.

  FPC gotchas (AGENTS.md): every test records at least one assertion; a
  generic Expect<T>(...) is never the lone statement of an `on..do`. }
program Wasm.Jit.X64.Plan.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Ir,
  Wasm.Jit.X64.Plan;

type
  TPlanCase = record
    Fn: TWasmIrFunction;
    Code: TWasmIrCode;
    Skip: array of Boolean;
    Targets: array of Boolean;
    Imm: array of Boolean;
    Values: array of Int64;
    Scales: TX64IndexScaleList;
  end;

  TX64PlanTests = class(TTestSuite)
  private
    FCase: TPlanCase;
    procedure Add(const AIns: TWasmIrInstr; const ASkip: Boolean = False;
      const AImm: Boolean = False; const AValue: Int64 = 0);
    procedure AddConst(const ADest: UInt32);
    procedure AddImm(const AOp: TWasmIrOp; const ADest, AA: UInt32;
      const AValue: Int64);
    procedure Insert(const AAt: Integer; const AIns: TWasmIrInstr);
    procedure Label_(const AIndex: Integer);
    { The base loop above with mask AMask and shift count ACount. }
    procedure BuildBase(const AMask: Int64 = 16383;
      const ACount: Int64 = 2);
    procedure Plan(const AEnabled: Boolean = True);
    { Whether the plan fused the shift at AShift into the access at
      AAccess (scale AScale, operand r6), or left both untouched. }
    procedure ExpectFused(const AShift, AAccess: Integer; const AScale: Byte);
    procedure ExpectNone;
  public
    procedure SetupTests; override;

    procedure TestFusesMaskedShift;
    procedure TestDisabledPlansNothing;
    procedure TestMaskBoundary;
    procedure TestShiftCounts;
    procedure TestProofShape;
    procedure TestLabels;
    procedure TestLivenessAfterLoop;
    procedure TestLivenessCarriedAndSameLine;
    procedure TestLivenessOtherPath;
    procedure TestLivenessResultAndValue;
    procedure TestValueBetween;
  end;

procedure TX64PlanTests.Add(const AIns: TWasmIrInstr; const ASkip: Boolean;
  const AImm: Boolean; const AValue: Int64);
var
  N: Integer;
begin
  N := Length(FCase.Code);
  SetLength(FCase.Code, N + 1);
  SetLength(FCase.Skip, N + 1);
  SetLength(FCase.Targets, N + 1);
  SetLength(FCase.Imm, N + 1);
  SetLength(FCase.Values, N + 1);
  FCase.Code[N] := AIns;
  FCase.Skip[N] := ASkip;
  FCase.Targets[N] := False;
  FCase.Imm[N] := AImm;
  FCase.Values[N] := AValue;
end;

procedure TX64PlanTests.AddConst(const ADest: UInt32);
begin
  Add(MakeIrInstr(iroI32Const, ADest, 0, 0, 0), True);
end;

procedure TX64PlanTests.AddImm(const AOp: TWasmIrOp; const ADest, AA: UInt32;
  const AValue: Int64);
begin
  Add(MakeIrInstr(AOp, ADest, AA, ADest + 100, 0), False, True, AValue);
end;

procedure TX64PlanTests.Insert(const AAt: Integer; const AIns: TWasmIrInstr);
var
  K: Integer;
begin
  { Only before the loop's branches, so no branch target moves. }
  Add(AIns);
  for K := High(FCase.Code) downto AAt + 1 do
  begin
    FCase.Code[K] := FCase.Code[K - 1];
    FCase.Skip[K] := FCase.Skip[K - 1];
    FCase.Targets[K] := FCase.Targets[K - 1];
    FCase.Imm[K] := FCase.Imm[K - 1];
    FCase.Values[K] := FCase.Values[K - 1];
  end;
  FCase.Code[AAt] := AIns;
  FCase.Skip[AAt] := False;
  FCase.Targets[AAt] := False;
  FCase.Imm[AAt] := False;
  FCase.Values[AAt] := 0;
  for K := 0 to High(FCase.Code) do
    case FCase.Code[K].Op of
      iroJump:
        if FCase.Code[K].A >= UInt32(AAt) then
          Inc(FCase.Code[K].A);
      iroBranchIfNot:
        if FCase.Code[K].B >= UInt32(AAt) then
          Inc(FCase.Code[K].B);
    end;
end;

procedure TX64PlanTests.Label_(const AIndex: Integer);
begin
  FCase.Targets[AIndex] := True;
end;

procedure TX64PlanTests.BuildBase(const AMask: Int64; const ACount: Int64);
begin
  FCase := Default(TPlanCase);
  SetLength(FCase.Fn.LocalRegs, 3);
  FCase.Fn.LocalRegs[0] := 0;
  FCase.Fn.LocalRegs[1] := 1;
  FCase.Fn.LocalRegs[2] := 2;
  SetLength(FCase.Fn.ResultRegs, 1);
  FCase.Fn.ResultRegs[0] := 3;
  FCase.Fn.RegisterCount := 20;
  AddConst(5);
  Add(MakeIrInstr(iroI32And, 6, 0, 5, 0), False, True, AMask);
  AddConst(7);
  Add(MakeIrInstr(iroI32Shl, 2, 6, 7, 0), False, True, ACount);
  Add(MakeIrInstr(iroI32Store, 0, 2, 0, 0));
  AddConst(12);
  AddImm(iroI32Add, 0, 0, 1);
  AddConst(15);
  AddImm(iroI32LtU, 16, 0, 1000);
  Add(MakeIrInstr(iroBranchIfNot, 0, 16, 11, 0));
  Add(MakeIrInstr(iroJump, 0, 0, 0, IR_JUMP_SAFEPOINT));
  Add(MakeIrInstr(iroMove, 3, 1, 0, 0));
  Add(MakeIrInstr(iroReturn, 0, 0, 0, 0));
  Label_(0);
  Label_(11);
end;

procedure TX64PlanTests.Plan(const AEnabled: Boolean);
begin
  X64PlanScaledIndex(FCase.Fn, FCase.Code, FCase.Skip, FCase.Targets,
    FCase.Imm, FCase.Values, AEnabled, FCase.Scales);
end;

procedure TX64PlanTests.ExpectFused(const AShift, AAccess: Integer;
  const AScale: Byte);
var
  K: Integer;
begin
  Expect<Integer>(Length(FCase.Scales)).ToBe(Length(FCase.Code));
  for K := 0 to High(FCase.Scales) do
    if K = AAccess then
      Expect<Byte>(FCase.Scales[K]).ToBe(AScale)
    else
      Expect<Byte>(FCase.Scales[K]).ToBe(0);
  Expect<Boolean>(FCase.Skip[AShift]).ToBe(True);
  Expect<UInt32>(FCase.Code[AAccess].A).ToBe(6);
end;

procedure TX64PlanTests.ExpectNone;
var
  K: Integer;
begin
  Expect<Integer>(Length(FCase.Scales)).ToBe(Length(FCase.Code));
  for K := 0 to High(FCase.Scales) do
    Expect<Byte>(FCase.Scales[K]).ToBe(0);
  for K := 0 to High(FCase.Code) do
    if FCase.Code[K].Op = iroI32Shl then
      Expect<Boolean>(FCase.Skip[K]).ToBe(False);
end;

procedure TX64PlanTests.TestFusesMaskedShift;
begin
  BuildBase;
  Plan;
  ExpectFused(3, 4, 2);
  { Only the shift and the access changed. }
  Expect<UInt32>(FCase.Code[4].Dest).ToBe(0);
  Expect<Boolean>(FCase.Skip[1]).ToBe(False);
end;

procedure TX64PlanTests.TestDisabledPlansNothing;
begin
  BuildBase;
  Plan(False);
  ExpectNone;
  Expect<UInt32>(FCase.Code[4].A).ToBe(2);
end;

procedure TX64PlanTests.TestMaskBoundary;
type
  TBound = record
    Count: Int64;
    Mask: Int64;
    Fuses: Boolean;
  end;
const
  { m * 2^k < 2^32 fuses; m * 2^k >= 2^32 does not. i32 constants arrive
    sign-extended, as the driver's immediate plan stores them. }
  Bounds: array[0 .. 9] of TBound = (
    (Count: 1; Mask: $7FFFFFFF; Fuses: True),
    (Count: 1; Mask: -2147483648; Fuses: False),
    (Count: 2; Mask: $3FFFFFFF; Fuses: True),
    (Count: 2; Mask: $40000000; Fuses: False),
    (Count: 3; Mask: $1FFFFFFF; Fuses: True),
    (Count: 3; Mask: $20000000; Fuses: False),
    (Count: 2; Mask: -1; Fuses: False),
    (Count: 1; Mask: -2147479553; Fuses: False),
    (Count: 3; Mask: 0; Fuses: True),
    (Count: 2; Mask: $40000FFF; Fuses: False));
var
  I: Integer;
begin
  for I := 0 to High(Bounds) do
  begin
    BuildBase(Bounds[I].Mask, Bounds[I].Count);
    Plan;
    if Bounds[I].Fuses then
      ExpectFused(3, 4, Byte(Bounds[I].Count))
    else
      ExpectNone;
  end;
end;

procedure TX64PlanTests.TestShiftCounts;
const
  Counts: array[0 .. 10] of Int64 = (0, 1, 2, 3, 4, 32, 33, 34, 35, 36, 66);
  Scales: array[0 .. 10] of Byte = (0, 1, 2, 3, 0, 0, 1, 2, 3, 0, 2);
var
  I: Integer;
begin
  { wasm masks an i32 shift count mod 32; only 1..3 is a SIB scale. }
  for I := 0 to High(Counts) do
  begin
    BuildBase($FFF, Counts[I]);
    Plan;
    if Scales[I] = 0 then
      ExpectNone
    else
      ExpectFused(3, 4, Scales[I]);
  end;
end;

procedure TX64PlanTests.TestProofShape;
begin
  { The shift count is not a fused constant. }
  BuildBase;
  FCase.Imm[3] := False;
  Plan;
  ExpectNone;
  { The mask is not a fused constant. }
  BuildBase;
  FCase.Imm[1] := False;
  Plan;
  ExpectNone;
  { or, not and, bounds nothing. }
  BuildBase;
  FCase.Code[1].Op := iroI32Or;
  Plan;
  ExpectNone;
  { The shifted operand is not the and's result. }
  BuildBase;
  FCase.Code[1].Dest := 8;
  Plan;
  ExpectNone;
  { The and is not the emitted instruction right before the shift. }
  BuildBase;
  FCase.Skip[2] := False;
  Plan;
  ExpectNone;
  { A nonzero offset. }
  BuildBase;
  FCase.Code[4].Imm := 4;
  Plan;
  ExpectNone;
  { The access reads another address. }
  BuildBase;
  FCase.Code[4].A := 9;
  Plan;
  ExpectNone;
  { The shift's result is the shifted operand itself. }
  BuildBase;
  FCase.Code[3].Dest := 6;
  FCase.Code[4].A := 6;
  Plan;
  ExpectNone;
  { A load may redefine the address slot it reads. }
  BuildBase;
  FCase.Code[4] := MakeIrInstr(iroI32Load, 2, 2, 0, 0);
  Plan;
  ExpectFused(3, 4, 2);
end;

procedure TX64PlanTests.TestLabels;
var
  I: Integer;
begin
  { A label anywhere from after the and up to the access ends the straight
    line; one on the and itself does not. }
  for I := 2 to 4 do
  begin
    BuildBase;
    Label_(I);
    Plan;
    ExpectNone;
  end;
  BuildBase;
  Label_(1);
  Plan;
  ExpectFused(3, 4, 2);
end;

procedure TX64PlanTests.TestLivenessAfterLoop;
begin
  { The address is read after the loop, where it holds the last address. }
  BuildBase;
  FCase.Code[11].A := 2;
  Plan;
  ExpectNone;
  { ... unless the post-loop code redefines it first. }
  BuildBase;
  FCase.Code[11] := MakeIrInstr(iroI32Const, 2, 0, 0, 5);
  FCase.Code[12] := MakeIrInstr(iroMove, 3, 2, 0, 0);
  Add(MakeIrInstr(iroReturn, 0, 0, 0, 0));
  Plan;
  ExpectFused(3, 4, 2);
  { A redefinition the plan skipped does not count. }
  BuildBase;
  FCase.Code[11] := MakeIrInstr(iroI32Const, 2, 0, 0, 5);
  FCase.Skip[11] := True;
  FCase.Code[12] := MakeIrInstr(iroMove, 3, 2, 0, 0);
  Add(MakeIrInstr(iroReturn, 0, 0, 0, 0));
  Plan;
  ExpectNone;
end;

procedure TX64PlanTests.TestLivenessCarriedAndSameLine;
begin
  { Read at the loop head before its redefinition: the previous
    iteration's address is observable through the back-edge. }
  BuildBase;
  Insert(0, MakeIrInstr(iroI32Add, 1, 1, 2, 0));
  Label_(0);
  Plan;
  ExpectNone;
  { Read after the access in the same straight line. }
  BuildBase;
  Insert(5, MakeIrInstr(iroI32Add, 1, 1, 2, 0));
  Plan;
  ExpectNone;
  { Read before the shift in the same line, after an earlier definition:
    that read sees the earlier value, which is still written. }
  BuildBase;
  Insert(1, MakeIrInstr(iroI32Add, 2, 0, 0, 0));
  Insert(2, MakeIrInstr(iroI32Add, 1, 1, 2, 0));
  Label_(0);
  Plan;
  Expect<Byte>(FCase.Scales[6]).ToBe(2);
  Expect<Boolean>(FCase.Skip[5]).ToBe(True);
end;

procedure TX64PlanTests.TestLivenessOtherPath;
begin
  { One arm of an if after the access reads the address: the arm is the
    branch's fall-through, still in the shift's straight line. }
  BuildBase;
  Insert(5, MakeIrInstr(iroBranchIfNot, 0, 0, 0, 0));
  Insert(6, MakeIrInstr(iroI32Add, 1, 1, 2, 0));
  FCase.Code[5].B := 7;
  Label_(7);
  Plan;
  ExpectNone;
  { A read at a join, even after a definition on the fall-through. }
  BuildBase;
  Insert(5, MakeIrInstr(iroBranchIfNot, 0, 0, 0, 0));
  Insert(6, MakeIrInstr(iroMove, 2, 1, 0, 0));
  Insert(7, MakeIrInstr(iroI32Add, 1, 1, 2, 0));
  FCase.Code[5].B := 7;
  Label_(7);
  Plan;
  ExpectNone;
end;

procedure TX64PlanTests.TestLivenessResultAndValue;
begin
  { A result slot is read by return. }
  BuildBase;
  FCase.Code[3].Dest := 3;
  FCase.Code[4].A := 3;
  FCase.Code[11].Dest := 1;
  Plan;
  ExpectNone;
  { The store's value is the address. }
  BuildBase;
  FCase.Code[4].Dest := 2;
  Plan;
  ExpectNone;
  { An op outside the known read shapes counts as reading the address. }
  BuildBase;
  FCase.Code[11] := MakeIrInstr(iroSelect, 3, 1, 1, 0);
  Plan;
  ExpectNone;
end;

procedure TX64PlanTests.TestValueBetween;
var
  I: Integer;
begin
  { The stored value is computed between the shift and the store. }
  BuildBase;
  Insert(4, MakeIrInstr(iroI32Mul, 9, 0, 0, 0));
  FCase.Code[5].Dest := 9;
  Plan;
  ExpectFused(3, 5, 2);
  { ... across a scalar load, too. }
  BuildBase;
  Insert(4, MakeIrInstr(iroI32Load16U, 9, 0, 0, 0));
  Plan;
  ExpectFused(3, 5, 2);
  { ... and across eight emitted instructions, but not nine. }
  for I := 8 to 9 do
  begin
    BuildBase;
    while Length(FCase.Code) < 13 + I do
      Insert(4, MakeIrInstr(iroI32Xor, 9, 9, 0, 0));
    Plan;
    if I = 8 then
      ExpectFused(3, 4 + I, 2)
    else
      ExpectNone;
  end;
  { Not across a redefinition of the masked operand ... }
  BuildBase;
  Insert(4, MakeIrInstr(iroMove, 6, 1, 0, 0));
  Plan;
  ExpectNone;
  { ... or of the address ... }
  BuildBase;
  Insert(4, MakeIrInstr(iroI32Add, 2, 1, 1, 0));
  Plan;
  ExpectNone;
  { ... or a branch, or an op outside the value set. }
  BuildBase;
  Insert(4, MakeIrInstr(iroBranchIfNot, 0, 0, 12, 0));
  Plan;
  ExpectNone;
  BuildBase;
  Insert(4, MakeIrInstr(iroI32Eqz, 9, 0, 0, 0));
  Plan;
  ExpectNone;
end;

procedure TX64PlanTests.SetupTests;
begin
  Test('a masked i32.shl by 2 folds into the store''s SIB scale',
    TestFusesMaskedShift);
  Test('outside a base-pinned static cache nothing is planned',
    TestDisabledPlansNothing);
  Test('only a mask m with m * 2^k below 2^32 bounds the index',
    TestMaskBoundary);
  Test('shift counts fold modulo 32 and only as 1, 2, or 3',
    TestShiftCounts);
  Test('the and, shift, and access shapes the proof needs', TestProofShape);
  Test('a label between the and and the access ends the proof', TestLabels);
  Test('an address read after the loop keeps its shift unless redefined',
    TestLivenessAfterLoop);
  Test('loop-carried and same-line reads keep the shift',
    TestLivenessCarriedAndSameLine);
  Test('reads on another path keep the shift', TestLivenessOtherPath);
  Test('result slots, stored addresses, and unknown ops keep the shift',
    TestLivenessResultAndValue);
  Test('the access may follow a short straight-line value computation',
    TestValueBetween);
end;

begin
  TestRunnerProgram.AddSuite(TX64PlanTests.Create('Wasm.Jit.X64.Plan'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
