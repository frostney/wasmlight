{ Unit suite for Wasm.Validator.Body.

  Every module here is hand-assembled as literal bytes and pushed through
  the real decoder before validation, so each case is a module the binary
  grammar accepts and the walk starts exactly where Wasm.Decoder's ends.
  Positive cases assert the emitted IR as DISASSEMBLED TEXT
  (Wasm.Ir.DescribeIrFunction) rather than record internals, so they
  survive an encoding tweak but pin the lowering. Negative cases assert
  the exception CLASS as well as the message prefix: the decode/validation
  boundary is the point of those tests, not a detail of them.

  Seven of the cases below are the Track B design document's worked
  examples reproduced end to end — they are the regression net for
  ADR-0012's three named risk spots (unreachable code, multi-value merges,
  br_table).

  Spec anchors are cited per group, read from wasm-mcp at the pinned
  commit d7b37e4170d8315f2f1283aed4e8076591a9a333. }
program Wasm.Validator.Body.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator.Body,
  Wasm.Validator.Types;

type
  { Every section a case below needs, so that one builder covers the
    whole suite and the section ORDER — which the decoder enforces and
    which is not the id order (tag sits between memory and global, data
    count before code) — is spelled once. }
  TModuleSections = record
    TypeSec: TWasmBytes;
    ImportSec: TWasmBytes;
    FuncSec: TWasmBytes;
    TableSec: TWasmBytes;
    MemorySec: TWasmBytes;
    TagSec: TWasmBytes;
    GlobalSec: TWasmBytes;
    ExportSec: TWasmBytes;
    ElemSec: TWasmBytes;
    DataCountSec: TWasmBytes;
    CodeSec: TWasmBytes;
    DataSec: TWasmBytes;
  end;

  TValidatorBodyTests = class(TTestSuite)
  private
    { The decoded module borrows this buffer (ADR-0003), so it lives as
      long as the suite does. }
    FBytes: TWasmBytes;
    FModule: TWasmModule;
    FContext: TWasmTypeContext;

    procedure BuildAll(const ASections: TModuleSections);
    procedure Build(const ATypeSec, AFuncSec, ATableSec,
      ACodeSec: TWasmBytes);
    function ValidateAt(const AIndex: Integer): TWasmIrFunction;
    procedure ExpectIr(const ADescription, AExpected: string);
    procedure ExpectInvalid(const ADescription, APrefix: string);
    procedure ExpectMalformed(const ADescription, APrefix: string);
    function Outcome(const AMessage, APrefix: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    { worked examples }
    procedure TestBlockWithResult;
    procedure TestLoopBackEdgeSafepoint;
    procedure TestIfElseMergeMoves;
    procedure TestNestedBranchMultiValueMerge;
    procedure TestBrTablePerTargetStubs;
    procedure TestReturnMultiValue;
    procedure TestTailCall;

    { control-flow lowering beyond the worked examples }
    procedure TestBrIfMergeMovesUseInvertedForm;
    procedure TestIfWithoutElseSynthesisesTheArm;
    procedure TestElseInheritsUnresolvedJumpPatches;
    procedure TestUnreachableCodeEmitsNothing;
    procedure TestFunctionEndingInBrStillEndsWithReturn;
    procedure TestCallEmitsAuxArgAndResultLists;
    procedure TestCallIndirectReadsTheTableSpace;
    procedure TestSelectLowering;

    procedure TestVoidCallEmitsEmptyAuxLists;

    { locals and initialization tracking }
    procedure TestNonDefaultableLocalAfterSet;
    procedure TestUninitializedLocalIsRejected;
    procedure TestBlockExitResetsLocalInitialization;
    procedure TestLocalTeeReusesTheOperandRegister;
    procedure TestLocalOfUnknownConcreteTypeIsRejected;
    procedure TestBlockResultOfUnknownConcreteTypeIsRejected;

    { the parallel move, driven directly }
    procedure TestParallelMoveBreaksACycle;
    procedure TestParallelMoveWithDuplicateSources;

    { negatives }
    procedure TestNumericTypeMismatch;
    procedure TestUnreachableStillTypeChecks;
    procedure TestBlockResultTypeMismatch;
    procedure TestSelectOperandMismatch;
    procedure TestDropUnderflow;
    procedure TestUnknownLabel;
    procedure TestUnknownLocal;
    procedure TestUnknownFunction;
    procedure TestBrTableArityMismatch;
    procedure TestTypedSelectArity;
    procedure TestTailCallResultMismatch;
    procedure TestBodyEndBeforeSpanEnd;
    procedure TestMisplacedElse;
    procedure TestUnknownOpcode;
    procedure TestSimdIsStaged;
    procedure TestBrTableCountIsBoundedByTheBytesLeft;
    procedure TestArrayNewFixedCountIsBoundedByTheStack;
    procedure TestArrayNewFixedIsPolymorphicInDeadCode;
    procedure TestTooManyLocalsHitsTheImplementationLimit;
    procedure TestEmptyBodySpanIsRejected;

    { --- globals ----------------------------------------------------- }
    procedure TestGlobalGetSet;
    procedure TestImmutableGlobalSet;
    procedure TestUnknownGlobal;

    { --- tables ------------------------------------------------------ }
    procedure TestTableInit;
    procedure TestTableGetAddressType;
    procedure TestTableGrowAndSize;
    procedure TestUnknownTable;
    procedure TestUnknownElemSegment;

    { --- memory ------------------------------------------------------ }
    procedure TestLoadWithMemidxForm;
    procedure TestMemoryCopy;
    procedure TestMemoryFill;
    procedure TestAlignmentTooLarge;
    procedure TestUnknownMemory;
    procedure TestMemoryInitNeedsDataCount;
    procedure TestMemoryInitWithDataCount;
    procedure TestUnknownDataSegment;

    { --- references -------------------------------------------------- }
    procedure TestRefFuncDeclaredByExport;
    procedure TestRefFuncUndeclared;
    procedure TestBrOnNullRefinement;
    procedure TestBrOnNonNullRefinement;

    { --- GC ---------------------------------------------------------- }
    procedure TestStructNewWithOperands;
    procedure TestStructGetPackedNeedsExtension;
    procedure TestStructGetSOnUnpackedField;
    procedure TestStructSetOnImmutableField;
    procedure TestStructOpOnArrayType;
    procedure TestArrayNewFixedAndLen;
    procedure TestArrayFillAuxOrder;
    procedure TestArrayCopyAuxOrder;
    procedure TestRefI31AndCast;
    procedure TestBrOnCastRefinement;
    procedure TestBrOnCastFailSwapsTheTwoResults;
    procedure TestBrOnCastUnrelatedTypes;
    procedure TestBrOnCastLabelMismatch;

    { --- exception handling ------------------------------------------ }
    procedure TestTryTableTwoCatchKinds;
    procedure TestThrowRefIsStackPolymorphic;
    procedure TestThrowWithNonEmptyResultTag;
    procedure TestUnknownTag;
  end;

{ --- byte assembly -------------------------------------------------------- }

function B(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function Cat(const A, C: TWasmBytes): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A) + Length(C));
  for I := 0 to High(A) do
    Result[I] := A[I];
  for I := 0 to High(C) do
    Result[Length(A) + I] := C[I];
end;

function ULeb(const AValue: UInt32): TWasmBytes;
var
  V: UInt32;
  N: Integer;
begin
  N := 1;
  V := AValue shr 7;
  while V <> 0 do
  begin
    Inc(N);
    V := V shr 7;
  end;
  SetLength(Result, N);
  V := AValue;
  for N := 0 to High(Result) do
  begin
    if N = High(Result) then
      Result[N] := Byte(V and $7F)
    else
      Result[N] := Byte((V and $7F) or $80);
    V := V shr 7;
  end;
end;

function Section(const AId: Byte; const ABody: TWasmBytes): TWasmBytes;
begin
  if Length(ABody) = 0 then
    Exit(nil);
  Result := Cat(Cat(B([AId]), ULeb(UInt32(Length(ABody)))), ABody);
end;

{ One code entry: its size prefix, the locals vector, and the body. }
function Entry(const ALocals, ABody: TWasmBytes): TWasmBytes;
var
  Payload: TWasmBytes;
begin
  Payload := Cat(ALocals, ABody);
  Result := Cat(ULeb(UInt32(Length(Payload))), Payload);
end;

function Code1(const ALocals, ABody: TWasmBytes): TWasmBytes;
begin
  Result := Cat(B([$01]), Entry(ALocals, ABody));
end;

function Code2(const AL1, AB1, AL2, AB2: TWasmBytes): TWasmBytes;
begin
  Result := Cat(Cat(B([$02]), Entry(AL1, AB1)), Entry(AL2, AB2));
end;

{ --- the suite ------------------------------------------------------------ }

procedure TValidatorBodyTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TValidatorBodyTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

{ Section order is the binary format's PRESCRIBED order, which is not the
  id order: the tag section (id 13) sits between memory and global, and
  the data count section (id 12) comes BEFORE the code section — which is
  the whole reason it exists. Wasm.Core.SectionOrderPosition is the
  authority and the decoder enforces it. }
procedure TValidatorBodyTests.BuildAll(const ASections: TModuleSections);
var
  Bytes: TWasmBytes;
begin
  Bytes := B([$00, $61, $73, $6D, $01, $00, $00, $00]);
  Bytes := Cat(Bytes, Section(Ord(wsType), ASections.TypeSec));
  Bytes := Cat(Bytes, Section(Ord(wsImport), ASections.ImportSec));
  Bytes := Cat(Bytes, Section(Ord(wsFunction), ASections.FuncSec));
  Bytes := Cat(Bytes, Section(Ord(wsTable), ASections.TableSec));
  Bytes := Cat(Bytes, Section(Ord(wsMemory), ASections.MemorySec));
  Bytes := Cat(Bytes, Section(Ord(wsTag), ASections.TagSec));
  Bytes := Cat(Bytes, Section(Ord(wsGlobal), ASections.GlobalSec));
  Bytes := Cat(Bytes, Section(Ord(wsExport), ASections.ExportSec));
  Bytes := Cat(Bytes, Section(Ord(wsElement), ASections.ElemSec));
  Bytes := Cat(Bytes, Section(Ord(wsDataCount), ASections.DataCountSec));
  Bytes := Cat(Bytes, Section(Ord(wsCode), ASections.CodeSec));
  Bytes := Cat(Bytes, Section(Ord(wsData), ASections.DataSec));
  FBytes := Bytes;

  DecodeModule(FBytes, FModule);
  FContext.Build(FModule);
end;

procedure TValidatorBodyTests.Build(const ATypeSec, AFuncSec, ATableSec,
  ACodeSec: TWasmBytes);
var
  S: TModuleSections;
begin
  S.TypeSec := ATypeSec;
  S.ImportSec := nil;
  S.FuncSec := AFuncSec;
  S.TableSec := ATableSec;
  S.MemorySec := nil;
  S.TagSec := nil;
  S.GlobalSec := nil;
  S.ExportSec := nil;
  S.ElemSec := nil;
  S.DataCountSec := nil;
  S.CodeSec := ACodeSec;
  S.DataSec := nil;
  BuildAll(S);
end;

{ A zeroed section set, so a case names only the sections it cares
  about. }
function NoSections: TModuleSections;
begin
  Result.TypeSec := nil;
  Result.ImportSec := nil;
  Result.FuncSec := nil;
  Result.TableSec := nil;
  Result.MemorySec := nil;
  Result.TagSec := nil;
  Result.GlobalSec := nil;
  Result.ExportSec := nil;
  Result.ElemSec := nil;
  Result.DataCountSec := nil;
  Result.CodeSec := nil;
  Result.DataSec := nil;
end;

{ Code entries line up one-for-one with the module's own function
  declarations; the imported functions occupy the low indices of the
  function index space and have no code. }
function TValidatorBodyTests.ValidateAt(
  const AIndex: Integer): TWasmIrFunction;
begin
  Result := ValidateFunctionBody(FModule, FContext, FBytes,
    FModule.FunctionTypeIndices[AIndex], FModule.CodeEntries[AIndex],
    BuildFunctionTypeIndexSpace(FModule));
end;

procedure TValidatorBodyTests.ExpectIr(const ADescription,
  AExpected: string);
begin
  Expect<string>(ADescription + #10 + DescribeIrFunction(ValidateAt(0)))
    .ToBe(ADescription + #10 + AExpected);
end;

function TValidatorBodyTests.Outcome(const AMessage,
  APrefix: string): string;
begin
  if Copy(AMessage, 1, Length(APrefix)) = APrefix then
    Result := APrefix
  else
    Result := 'message: ' + AMessage;
end;

procedure TValidatorBodyTests.ExpectInvalid(const ADescription,
  APrefix: string);
var
  Got: string;
begin
  Got := 'ACCEPTED';
  try
    ValidateAt(0);
  except
    on E: EWasmValidationError do
      Got := 'invalid: ' + Outcome(E.Message, APrefix);
    on E: EWasmDecodeError do
      Got := 'malformed: ' + E.Message;
  end;

  Expect<string>(ADescription + ' -> ' + Got)
    .ToBe(ADescription + ' -> invalid: ' + APrefix);
end;

procedure TValidatorBodyTests.ExpectMalformed(const ADescription,
  APrefix: string);
var
  Got: string;
begin
  Got := 'ACCEPTED';
  try
    ValidateAt(0);
  except
    on E: EWasmDecodeError do
      Got := 'malformed: ' + Outcome(E.Message, APrefix);
    on E: EWasmValidationError do
      Got := 'invalid: ' + E.Message;
  end;

  Expect<string>(ADescription + ' -> ' + Got)
    .ToBe(ADescription + ' -> malformed: ' + APrefix);
end;

{ One disassembly line, spelled through the same format Wasm.Ir uses so
  the expectations below stay readable. }
function L(const AIndex: Integer;
  const AMnemonic, AOperands: string): string;
begin
  Result := TrimRight(
    Format('%.4d  %-22s %s', [AIndex, AMnemonic, AOperands]));
end;

{ The handler table, rendered so the try_table case asserts text rather
  than record internals — the same reason the IR cases go through
  DescribeIrFunction. Entries print in TABLE order, which is
  innermost-first by construction (Wasm.Ir's TWasmIrHandlers comment). }
function DescribeHandlers(const AFn: TWasmIrFunction): string;
const
  KIND_NAMES: array[TWasmIrCatchKind] of string = (
    'catch', 'catch_ref', 'catch_all', 'catch_all_ref');
var
  I, J, K: Integer;
  H: TWasmIrHandler;
  C: TWasmIrCatchClause;
  Regs: string;
begin
  Result := '';
  for I := 0 to High(AFn.Handlers) do
  begin
    H := AFn.Handlers[I];
    if Result <> '' then
      Result := Result + #10;
    Result := Result
      + Format('handler [%d, %d)', [H.StartInstr, H.EndInstr]);
    for J := 0 to Integer(H.ClauseCount) - 1 do
    begin
      C := AFn.HandlerClauses[Integer(H.ClauseStart) + J];
      Regs := '';
      for K := 0 to Integer(IrAuxBlockCount(AFn.AuxU32, C.PayloadAux)) - 1 do
      begin
        if Regs <> '' then
          Regs := Regs + ', ';
        Regs := Regs + 'r'
          + IntToStr(IrAuxBlockItem(AFn.AuxU32, C.PayloadAux, UInt32(K)));
      end;
      Result := Result + #10 + '  ' + KIND_NAMES[C.Kind];
      if (C.Kind = wickCatch) or (C.Kind = wickCatchRef) then
        Result := Result + ' tag=' + IntToStr(C.TagIndex);
      Result := Result + ' -> ' + Format('@%.4d', [Integer(C.TargetInstr)])
        + ' payload (' + Regs + ')';
    end;
  end;
end;

{ --- worked examples ------------------------------------------------------ }

{ (func (result i32) (block (result i32) i32.const 7))

  Two chained moves are the honest output of straightforward emission:
  the block's `end` merges into the block's merge register and the
  function's `end` merges that into the return register. Copy coalescing
  is a later pass and is deliberately not done here. }
procedure TValidatorBodyTests.TestBlockWithResult;
begin
  Build(B([$01, $60, $00, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]), B([$02, $7F, $41, $07, $0B, $0B])));

  ExpectIr('block with a result',
    L(0, 'i32.const', 'r2 <- 7') + #10
    + L(1, 'move', 'r1 <- r2') + #10
    + L(2, 'move', 'r0 <- r1') + #10
    + L(3, 'return', ''));
end;

{ A counted loop. Both labels are empty-typed, so every merge vector is
  empty and no merge moves appear — which is what isolates the safepoint
  on the back-edge (ADR-0006, ADR-0011). }
procedure TValidatorBodyTests.TestLoopBackEdgeSafepoint;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$01, $01, $7F]),
      B([$02, $40, $03, $40, $20, $00, $45, $0D, $01, $20, $00, $41,
         $01, $6B, $21, $00, $0C, $00, $0B, $0B, $20, $00, $0B])));

  ExpectIr('loop with a back-edge',
    L(0, 'move', 'r3 <- r0') + #10
    + L(1, 'i32.eqz', 'r4 <- r3') + #10
    + L(2, 'branch_if', 'r4 -> @0008') + #10
    + L(3, 'move', 'r5 <- r0') + #10
    + L(4, 'i32.const', 'r6 <- 1') + #10
    + L(5, 'i32.sub', 'r7 <- r5, r6') + #10
    + L(6, 'move', 'r0 <- r7') + #10
    + L(7, 'jump', '@0000 safepoint') + #10
    + L(8, 'move', 'r8 <- r0') + #10
    + L(9, 'move', 'r2 <- r8') + #10
    + L(10, 'return', ''));
end;

{ (func (param i32) (result i32) local.get 0 if (result i32) 1 else 2) }
procedure TValidatorBodyTests.TestIfElseMergeMoves;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$20, $00, $04, $7F, $41, $01, $05, $41, $02, $0B, $0B])));

  ExpectIr('if/else with merge moves',
    L(0, 'move', 'r2 <- r0') + #10
    + L(1, 'branch_if_not', 'r2 -> @0005') + #10
    + L(2, 'i32.const', 'r4 <- 1') + #10
    + L(3, 'move', 'r3 <- r4') + #10
    + L(4, 'jump', '@0007') + #10
    + L(5, 'i32.const', 'r5 <- 2') + #10
    + L(6, 'move', 'r3 <- r5') + #10
    + L(7, 'move', 'r1 <- r3') + #10
    + L(8, 'return', ''));
end;

{ `br` from nested depth into a two-result label, and the unreachable
  code that follows it: the inner block's `end` runs with the frame
  unreachable, emits nothing, and pops. }
procedure TValidatorBodyTests.TestNestedBranchMultiValueMerge;
begin
  Build(B([$02, $60, $00, $02, $7F, $7E, $60, $00, $02, $7F, $7E]),
    B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $01, $02, $40, $41, $01, $42, $02, $0C, $01, $0B, $41,
         $03, $42, $04, $0B, $0B])));

  ExpectIr('br into a multi-value label',
    L(0, 'i32.const', 'r4 <- 1') + #10
    + L(1, 'i64.const', 'r5 <- 2') + #10
    + L(2, 'move', 'r2 <- r4') + #10
    + L(3, 'move', 'r3 <- r5') + #10
    + L(4, 'jump', '@0009') + #10
    + L(5, 'i32.const', 'r6 <- 3') + #10
    + L(6, 'i64.const', 'r7 <- 4') + #10
    + L(7, 'move', 'r2 <- r6') + #10
    + L(8, 'move', 'r3 <- r7') + #10
    + L(9, 'move', 'r0 <- r2') + #10
    + L(10, 'move', 'r1 <- r3') + #10
    + L(11, 'return', ''));
end;

{ Every br_table entry gets its OWN stub, emitted contiguously after the
  instruction in entry order with the default last, and stubs are not
  deduplicated even when two entries share a label. }
procedure TValidatorBodyTests.TestBrTablePerTargetStubs;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]),
      { Three `end` bytes: block $b, block $a, and the function body's
        own — the design document's byte listing for this example omits
        the last one, though its IR listing is right. }
      B([$02, $7F, $02, $7F, $41, $07, $20, $00, $0E, $02, $00, $01,
         $01, $0B, $0B, $0B])));

  ExpectIr('br_table with per-target stubs',
    L(0, 'i32.const', 'r4 <- 7') + #10
    + L(1, 'move', 'r5 <- r0') + #10
    + L(2, 'br_table', 'r5 -> [@0003, @0005, @0007]') + #10
    + L(3, 'move', 'r3 <- r4') + #10
    + L(4, 'jump', '@0009') + #10
    + L(5, 'move', 'r2 <- r4') + #10
    + L(6, 'jump', '@0010') + #10
    + L(7, 'move', 'r2 <- r4') + #10
    + L(8, 'jump', '@0010') + #10
    + L(9, 'move', 'r2 <- r3') + #10
    + L(10, 'move', 'r1 <- r2') + #10
    + L(11, 'return', ''));
end;

{ `return` is a branch to the outermost label. Instruction 5 is dead; it
  is emitted anyway so an interpreter's fetch loop needs no
  end-of-array check. }
procedure TValidatorBodyTests.TestReturnMultiValue;
begin
  Build(B([$01, $60, $00, $02, $7F, $7F]), B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $01, $41, $02, $0F, $0B])));

  ExpectIr('multi-value return',
    L(0, 'i32.const', 'r2 <- 1') + #10
    + L(1, 'i32.const', 'r3 <- 2') + #10
    + L(2, 'move', 'r0 <- r2') + #10
    + L(3, 'move', 'r1 <- r3') + #10
    + L(4, 'return', '') + #10
    + L(5, 'return', ''));
end;

{ return_call is a distinct op so a tier can implement it as O(1) frame
  replacement; the callee's results become this function's results
  directly, so there are no merge moves into the return block. }
procedure TValidatorBodyTests.TestTailCall;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$02, $00, $00]), nil,
    Code2(B([$00]), B([$20, $00, $12, $01, $0B]),
      B([$00]), B([$20, $00, $0B])));

  ExpectIr('tail call',
    L(0, 'move', 'r2 <- r0') + #10
    + L(1, 'return_call', 'f1 (r2)') + #10
    + L(2, 'return', ''));
end;

{ --- control-flow lowering beyond the worked examples --------------------- }

{ A conditional branch that needs merge moves takes the inverted form,
  with the taken edge laid out inline: one conditional test, no jump on
  the not-taken path. }
procedure TValidatorBodyTests.TestBrIfMergeMovesUseInvertedForm;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $7F, $41, $01, $20, $00, $0D, $00, $1A, $41, $02, $0B,
         $0B])));

  ExpectIr('br_if with merge moves',
    L(0, 'i32.const', 'r3 <- 1') + #10
    + L(1, 'move', 'r4 <- r0') + #10
    + L(2, 'branch_if_not', 'r4 -> @0005') + #10
    + L(3, 'move', 'r2 <- r3') + #10
    + L(4, 'jump', '@0007') + #10
    + L(5, 'i32.const', 'r5 <- 2') + #10
    + L(6, 'move', 'r2 <- r5') + #10
    + L(7, 'move', 'r1 <- r2') + #10
    + L(8, 'return', ''));
end;

{ `if` without `else` requires t1* = t2*, and the missing arm is
  synthesised at `end` out of the frame's ParamRegs — which are still
  live because temporaries are allocated monotonically and never reused. }
procedure TValidatorBodyTests.TestIfWithoutElseSynthesisesTheArm;
begin
  Build(B([$02, $60, $01, $7F, $01, $7F, $60, $01, $7F, $01, $7F]),
    B([$01, $00]), nil,
    Code1(B([$00]),
      B([$20, $00, $20, $00, $04, $01, $41, $01, $6A, $0B, $0B])));

  ExpectIr('if without else',
    L(0, 'move', 'r2 <- r0') + #10
    + L(1, 'move', 'r3 <- r0') + #10
    + L(2, 'branch_if_not', 'r3 -> @0007') + #10
    + L(3, 'i32.const', 'r5 <- 1') + #10
    + L(4, 'i32.add', 'r6 <- r2, r5') + #10
    + L(5, 'move', 'r4 <- r6') + #10
    + L(6, 'jump', '@0008') + #10
    + L(7, 'move', 'r4 <- r2') + #10
    + L(8, 'move', 'r1 <- r4') + #10
    + L(9, 'return', ''));
end;

{ THE CLASSIC BUG. A branch out of the then-arm targets the same `end` as
  the else-arm, so the else frame must inherit the if frame's jump
  patches UNRESOLVED. If they were resolved at `else`, instruction 4
  would point at @0005 instead of @0007 — and every test without a branch
  out of the then-arm would still pass. }
procedure TValidatorBodyTests.TestElseInheritsUnresolvedJumpPatches;
begin
  Build(B([$01, $60, $00, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$41, $01, $04, $7F, $41, $02, $0C, $00, $05, $41, $03, $0B,
         $0B])));

  ExpectIr('else inherits unresolved patches',
    L(0, 'i32.const', 'r1 <- 1') + #10
    + L(1, 'branch_if_not', 'r1 -> @0005') + #10
    + L(2, 'i32.const', 'r3 <- 2') + #10
    + L(3, 'move', 'r2 <- r3') + #10
    + L(4, 'jump', '@0007') + #10
    + L(5, 'i32.const', 'r4 <- 3') + #10
    + L(6, 'move', 'r2 <- r4') + #10
    + L(7, 'move', 'r0 <- r2') + #10
    + L(8, 'return', ''));
end;

{ Nothing between a `br` and the enclosing `end` may emit IR — but the
  walk must still type-check it. Three instructions sit in the dead range
  here and not one of them reaches the Code array. }
procedure TValidatorBodyTests.TestUnreachableCodeEmitsNothing;
begin
  Build(B([$01, $60, $00, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $7F, $41, $01, $0C, $00, $41, $02, $1A, $41, $03, $0B,
         $0B])));

  ExpectIr('unreachable code emits nothing',
    L(0, 'i32.const', 'r2 <- 1') + #10
    + L(1, 'move', 'r1 <- r2') + #10
    + L(2, 'jump', '@0003') + #10
    + L(3, 'move', 'r0 <- r1') + #10
    + L(4, 'return', ''));
end;

{ Every function's Code ends with exactly one iroReturn, emitted at the
  function-body `end` whether or not the frame is reachable. }
procedure TValidatorBodyTests.TestFunctionEndingInBrStillEndsWithReturn;
begin
  Build(B([$01, $60, $00, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $01, $0C, $00, $0B])));

  ExpectIr('function ending in br',
    L(0, 'i32.const', 'r1 <- 1') + #10
    + L(1, 'move', 'r0 <- r1') + #10
    + L(2, 'return', '') + #10
    + L(3, 'return', ''));
end;

{ Calls always use the aux result list, even for the single-result case,
  so a consumer writes one result-copy loop instead of two. }
procedure TValidatorBodyTests.TestCallEmitsAuxArgAndResultLists;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$02, $00, $00]), nil,
    Code2(B([$00]), B([$20, $00, $10, $01, $0B]),
      B([$00]), B([$20, $00, $0B])));

  ExpectIr('call with aux lists',
    L(0, 'move', 'r2 <- r0') + #10
    + L(1, 'call', 'f1 (r2) -> (r3)') + #10
    + L(2, 'move', 'r1 <- r3') + #10
    + L(3, 'return', ''));
end;

{ call_indirect reads the table index space and requires a table of
  function references (AA`valid-call_indirect`). }
procedure TValidatorBodyTests.TestCallIndirectReadsTheTableSpace;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]),
    B([$01, $70, $00, $01]),
    Code1(B([$00]), B([$20, $00, $20, $00, $11, $00, $00, $0B])));

  ExpectIr('call_indirect',
    L(0, 'move', 'r2 <- r0') + #10
    + L(1, 'move', 'r3 <- r0') + #10
    + L(2, 'call_indirect', 'type=0 table=0 [r3] (r2) -> (r4)') + #10
    + L(3, 'move', 'r1 <- r4') + #10
    + L(4, 'return', ''));
end;

{ select's condition rides in Imm — the one op where a register lives
  there — and A is the value chosen when the condition is non-zero, which
  is the deeper stack operand. }
procedure TValidatorBodyTests.TestSelectLowering;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$41, $01, $41, $02, $20, $00, $1B, $0B])));

  ExpectIr('select',
    L(0, 'i32.const', 'r2 <- 1') + #10
    + L(1, 'i32.const', 'r3 <- 2') + #10
    + L(2, 'move', 'r4 <- r0') + #10
    + L(3, 'select', 'r5 <- r2, r3 ? r4') + #10
    + L(4, 'move', 'r1 <- r5') + #10
    + L(5, 'return', ''));
end;

{ A call with NO arguments and NO results still emits both aux blocks —
  empty ones — because iroCall's A and B fields always name blocks and a
  consumer reads them unconditionally. This is the end-to-end shape of
  `(func (call $void))`, walked through the real decoder, and it is here
  because an empty aux append is exactly the case a growth-policy change
  can quietly break. }
procedure TValidatorBodyTests.TestVoidCallEmitsEmptyAuxLists;
begin
  Build(B([$01, $60, $00, $00]), B([$02, $00, $00]), nil,
    Code2(B([$00]), B([$10, $01, $0B]),
      B([$00]), B([$0B])));

  ExpectIr('call of a void function',
    L(0, 'call', 'f1 () -> ()') + #10
    + L(1, 'return', ''));
end;

{ --- locals and initialization tracking ----------------------------------- }

{ A local of a non-defaultable type — a non-nullable reference — is
  readable once it has been set (`appendix/algorithm-stacks`, set_local). }
procedure TValidatorBodyTests.TestNonDefaultableLocalAfterSet;
begin
  Build(B([$01, $60, $01, $64, $70, $01, $64, $70]), B([$01, $00]), nil,
    Code1(B([$01, $01, $64, $70]),
      B([$20, $00, $21, $01, $20, $01, $0B])));

  ExpectIr('non-defaultable local after set',
    L(0, 'move', 'r3 <- r0') + #10
    + L(1, 'move', 'r1 <- r3') + #10
    + L(2, 'move', 'r4 <- r1') + #10
    + L(3, 'move', 'r2 <- r4') + #10
    + L(4, 'return', ''));
end;

procedure TValidatorBodyTests.TestUninitializedLocalIsRejected;
begin
  Build(B([$01, $60, $01, $64, $70, $01, $64, $70]), B([$01, $00]), nil,
    Code1(B([$01, $01, $64, $70]), B([$20, $01, $0B])));

  ExpectInvalid('reading a non-defaultable local before it is set',
    'uninitialized local');
end;

{ pop_ctrl calls reset_locals(frame.init_height), undoing every
  initialization performed inside the block — which is exactly what makes
  `(block (local.set $r ...)) (local.get $r)` invalid. }
procedure TValidatorBodyTests.TestBlockExitResetsLocalInitialization;
begin
  Build(B([$01, $60, $01, $64, $70, $00]), B([$01, $00]), nil,
    Code1(B([$01, $01, $64, $70]),
      B([$02, $40, $20, $00, $21, $01, $0B, $20, $01, $1A, $0B])));

  ExpectInvalid('a local set inside a block is unset after it',
    'uninitialized local');
end;

{ local.tee writes the local and pushes the SAME register back rather
  than allocating a second one: the operand is a temporary, nothing on
  this path writes it again before its next use, and a second move would
  therefore be dead. Instruction 2 reading r2 rather than r0 is the whole
  assertion — an implementation that pushed the LOCAL's register would
  produce `move r1 <- r0` here and be wrong the moment the local is
  written again before the value is used. }
procedure TValidatorBodyTests.TestLocalTeeReusesTheOperandRegister;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]), B([$20, $00, $22, $00, $0B])));

  ExpectIr('local.tee',
    L(0, 'move', 'r2 <- r0') + #10
    + L(1, 'move', 'r0 <- r2') + #10
    + L(2, 'move', 'r1 <- r2') + #10
    + L(3, 'return', ''));
end;

{ `valid-local`: a local is classified by its value type, and a value
  type naming a concrete heap type is valid only when that type is
  defined. The code section decoder READ `(ref null 5)` without a type
  space to bound it against, so nothing before the body walk could reject
  it — this module has one type. A wrong ACCEPTANCE if it is not checked
  here. }
procedure TValidatorBodyTests.TestLocalOfUnknownConcreteTypeIsRejected;
begin
  { (func (local (ref null 5))) — locals vector: one group of one, value
    type $63 $05. }
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$01, $01, $63, $05]), B([$0B])));

  ExpectInvalid('a local of type (ref null 5) in a one-type module',
    MSG_UNKNOWN_TYPE);
end;

{ The same rule on the other unvalidated path, and DELIBERATELY IN DEAD
  CODE: a block type's reference form is read even when the enclosing
  frame is unreachable, so the check has to be on the read and not on the
  emission. `unreachable` first is what makes that the case under test. }
procedure TValidatorBodyTests.TestBlockResultOfUnknownConcreteTypeIsRejected;
begin
  { (func unreachable (block (result (ref null 5))) drop) }
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$00, $02, $63, $05, $0B, $1A, $0B])));

  ExpectInvalid('an unreachable block returning (ref null 5)',
    MSG_UNKNOWN_TYPE);
end;

{ --- the parallel move, driven directly ----------------------------------- }

{ Cycles are believed unreachable for well-formed wasm, but "believed" is
  not a proof: the path exists and is driven here. }
procedure TValidatorBodyTests.TestParallelMoveBreaksACycle;
var
  Fn: TWasmIrFunction;
  Code: TWasmIrCode;
  RegTypes: TWasmIrRegTypes;
  CodeCount, RegCount: Integer;
  Dests, Srcs: array[0..1] of UInt32;
begin
  Code := nil;
  RegTypes := nil;
  CodeCount := 0;
  RegCount := 0;
  IrAllocReg(RegTypes, RegCount, MakeNumValueType(wntI32));
  IrAllocReg(RegTypes, RegCount, MakeNumValueType(wntI32));

  Dests[0] := 0;
  Dests[1] := 1;
  Srcs[0] := 1;
  Srcs[1] := 0;
  EmitParallelMove(Code, CodeCount, RegTypes, RegCount, Dests, Srcs);

  SetLength(Code, CodeCount);
  SetLength(RegTypes, RegCount);
  Fn.Code := Code;
  Fn.RegTypes := RegTypes;

  Expect<string>(DescribeIrFunction(Fn)).ToBe(
    L(0, 'move', 'r2 <- r0') + #10
    + L(1, 'move', 'r0 <- r1') + #10
    + L(2, 'move', 'r1 <- r2'));
end;

{ Sources may repeat — the same register can appear twice on the value
  stack — and the ordering step handles that without a special case. }
procedure TValidatorBodyTests.TestParallelMoveWithDuplicateSources;
var
  Fn: TWasmIrFunction;
  Code: TWasmIrCode;
  RegTypes: TWasmIrRegTypes;
  CodeCount, RegCount: Integer;
  Dests, Srcs: array[0..1] of UInt32;
begin
  Code := nil;
  RegTypes := nil;
  CodeCount := 0;
  RegCount := 0;
  IrAllocReg(RegTypes, RegCount, MakeNumValueType(wntI32));
  IrAllocReg(RegTypes, RegCount, MakeNumValueType(wntI32));
  IrAllocReg(RegTypes, RegCount, MakeNumValueType(wntI32));

  Dests[0] := 0;
  Dests[1] := 1;
  Srcs[0] := 2;
  Srcs[1] := 2;
  EmitParallelMove(Code, CodeCount, RegTypes, RegCount, Dests, Srcs);

  SetLength(Code, CodeCount);
  SetLength(RegTypes, RegCount);
  Fn.Code := Code;
  Fn.RegTypes := RegTypes;

  Expect<string>(DescribeIrFunction(Fn)).ToBe(
    L(0, 'move', 'r0 <- r2') + #10
    + L(1, 'move', 'r1 <- r2'));
end;

{ --- negatives ------------------------------------------------------------ }

{ i32.const, i64.const, i32.add (`valid-binop`). }
procedure TValidatorBodyTests.TestNumericTypeMismatch;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $00, $42, $00, $6A, $1A, $0B])));

  ExpectInvalid('i32.add on an i64 operand', MSG_TYPE_MISMATCH);
end;

{ `(unreachable (i32.const 0) i64.add)` — the appendix names this as the
  reason unreachable code must still be type-checked. }
procedure TValidatorBodyTests.TestUnreachableStillTypeChecks;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$00, $41, $00, $7C, $1A, $0B])));

  ExpectInvalid('unreachable then i32.const then i64.add',
    MSG_TYPE_MISMATCH);
end;

procedure TValidatorBodyTests.TestBlockResultTypeMismatch;
begin
  Build(B([$01, $60, $00, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]), B([$42, $00, $0B])));

  ExpectInvalid('an i64 where the function returns i32',
    MSG_TYPE_MISMATCH);
end;

procedure TValidatorBodyTests.TestSelectOperandMismatch;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $00, $42, $00, $41, $00, $1B, $1A, $0B])));

  ExpectInvalid('select on operands of different types',
    MSG_TYPE_MISMATCH);
end;

procedure TValidatorBodyTests.TestDropUnderflow;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$1A, $0B])));

  ExpectInvalid('drop with an empty operand stack', MSG_TYPE_MISMATCH);
end;

procedure TValidatorBodyTests.TestUnknownLabel;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$0C, $05, $0B])));

  ExpectInvalid('br past the outermost label', MSG_UNKNOWN_LABEL);
end;

procedure TValidatorBodyTests.TestUnknownLocal;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$20, $03, $1A, $0B])));

  ExpectInvalid('local.get past the local space', MSG_UNKNOWN_LOCAL);
end;

procedure TValidatorBodyTests.TestUnknownFunction;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$10, $07, $0B])));

  ExpectInvalid('call past the function space', MSG_UNKNOWN_FUNCTION);
end;

{ Every br_table target's label arity must equal the default's. }
procedure TValidatorBodyTests.TestBrTableArityMismatch;
begin
  Build(B([$01, $60, $01, $7F, $01, $7F]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $40, $02, $7F, $41, $07, $20, $00, $0E, $01, $01, $00,
         $0B, $1A, $0B, $20, $00, $0B])));

  ExpectInvalid('br_table targets of different arity',
    MSG_INVALID_RESULT_ARITY);
end;

{ The binary grammar admits any count of types after $1C;
  `valid-select` requires exactly one. }
procedure TValidatorBodyTests.TestTypedSelectArity;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$41, $00, $41, $00, $41, $00, $1C, $02, $7F, $7F, $1A, $0B])));

  ExpectInvalid('select with two result types',
    MSG_INVALID_RESULT_ARITY);
end;

{ return_call's results must match the CALLER's
  (`appendix/algorithm-validation-of-opcode-sequences`,
  return_call_ref). }
procedure TValidatorBodyTests.TestTailCallResultMismatch;
begin
  Build(B([$02, $60, $01, $7F, $01, $7F, $60, $01, $7F, $01, $7E]),
    B([$02, $00, $01]),
    nil,
    Code2(B([$00]), B([$20, $00, $12, $01, $0B]),
      B([$00]), B([$42, $00, $0B])));

  ExpectInvalid('return_call to a callee with a different result type',
    MSG_TYPE_MISMATCH);
end;

{ The body's `end` must be the span's LAST byte. The code section decoder
  bounds the span but deliberately does not walk it, so this walk is the
  first structural pass over a function body — if the check is not made
  here it is made nowhere. It is binary grammar, hence a decode error. }
procedure TValidatorBodyTests.TestBodyEndBeforeSpanEnd;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$0B, $0B])));

  ExpectMalformed('a trailing byte after the body''s end',
    MSG_BODY_SIZE_MISMATCH);
end;

{ `binary-if` admits $05 in exactly one place and at most once. }
procedure TValidatorBodyTests.TestMisplacedElse;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$05, $0B])));

  ExpectMalformed('else at the top level of a body', 'misplaced else');
end;

procedure TValidatorBodyTests.TestUnknownOpcode;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$06, $0B])));

  { The opcode byte is part of the canonical prefix and is spelled in
    lowercase hex — see IllegalOpcodeMessage in Wasm.Binary. }
  ExpectMalformed('an unassigned opcode', MSG_ILLEGAL_OPCODE + ' 06');
end;

{ SIMD typing is Track G by the roadmap's staging. The subopcode is read
  first so the message can name it, and it is NEVER silently accepted. }
procedure TValidatorBodyTests.TestSimdIsStaged;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$FD, $00, $00, $00, $0B])));

  ExpectInvalid('a $FD vector instruction', MSG_SIMD_NOT_IMPLEMENTED);
end;

{ ALLOCATION BOUNDS, all four of them, because a hostile count is not a
  typing question and none of these is reachable from a well-formed
  module.

  br_table's label vector is a `vec(labelidx)` and every entry costs at
  least a byte, so a count larger than the bytes left belongs to a
  truncated body: MALFORMED, in the shared truncated-vector family, and
  checked BEFORE the array is sized. Nine bytes of body asking for four
  billion targets is the case. }
procedure TValidatorBodyTests.TestBrTableCountIsBoundedByTheBytesLeft;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]),
      { i32.const 0; br_table (count 0xFFFFFFFF) ... }
      B([$41, $00, $0E, $FF, $FF, $FF, $FF, $0F, $0B])));

  ExpectMalformed('br_table with a four-billion label count',
    MSG_UNEXPECTED_END_OF_SECTION + ': truncated br_table target vector');
end;

{ array.new_fixed's n is an OPERAND count, so no byte bound applies to
  it — the bound is the value stack, exactly as in a constant expression
  (Wasm.Validator.&Const's StepArrayNewFixed). Asking for three elements
  with none on the stack is the underflow it would have been anyway, so
  it is a typing failure and not a malformation. }
procedure TValidatorBodyTests.TestArrayNewFixedCountIsBoundedByTheStack;
begin
  Build(B([$02, $60, $00, $00, $5E, $7F, $01]), B([$01, $00]), nil,
    Code1(B([$00]), B([$FB, $08, $01, $03, $1A, $0B])));

  ExpectInvalid('array.new_fixed 3 with an empty stack',
    MSG_TYPE_MISMATCH);
end;

{ …and the clause a constant expression does not need. Under an
  unreachable frame the stack is polymorphic, so the same instruction IS
  well typed — every missing operand pops as Bot
  (`appendix/algorithm-stacks`). This is the case a naive
  `Count > depth` guard rejects, and it must be ACCEPTED. Emission is off
  in dead code, so nothing is sized either. }
procedure TValidatorBodyTests.TestArrayNewFixedIsPolymorphicInDeadCode;
begin
  Build(B([$02, $60, $00, $00, $5E, $7F, $01]), B([$01, $00]), nil,
    Code1(B([$00]), B([$00, $FB, $08, $01, $03, $1A, $0B])));

  ExpectIr('unreachable then array.new_fixed 3',
    L(0, 'unreachable', '') + #10
    + L(1, 'return', ''));
end;

{ The gap between the GRAMMAR bound and what this engine can allocate.
  `syntax-list` caps a list at 2^32-1 and Track A's code section decoder
  enforces exactly that, so a 4294967295-local entry is well formed and
  well typed — and still cannot be compiled, because every local becomes
  a register and the register file is Integer-indexed. The refusal is
  therefore neither `malformed` nor a conformance prefix: it names itself
  an implementation limit. The count is summed in a UInt64 precisely so
  this comparison can be made at all. }
procedure TValidatorBodyTests.TestTooManyLocalsHitsTheImplementationLimit;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    { One locals group of 0xFFFFFFFF i32s. }
    Code1(B([$01, $FF, $FF, $FF, $FF, $0F, $7F]), B([$0B])));

  ExpectInvalid('a code entry declaring 2^32-1 locals',
    'implementation limit: too many locals');
end;

{ ValidateFunctionBody is PUBLIC API, so its span comes from wherever the
  caller got it — not necessarily from this project's decoder, which
  rejects an empty body itself. A zero-size span is the one that used to
  reach `@ABytes[Offset]` with Offset = Length(ABytes), indexing one past
  the array before the reader bounded anything. Driven directly, because
  no module the decoder accepts can produce it. }
procedure TValidatorBodyTests.TestEmptyBodySpanIsRejected;
var
  Entry: TWasmCodeEntry;
  Outcome: string;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$0B])));

  Entry := FModule.CodeEntries[0];
  Entry.Body.Size := 0;

  Outcome := 'ACCEPTED';
  try
    ValidateFunctionBody(FModule, FContext, FBytes,
      FModule.FunctionTypeIndices[0], Entry);
  except
    on E: EWasmDecodeError do
      Outcome := 'malformed';
    on E: EWasmValidationError do
      Outcome := 'invalid: ' + E.Message;
  end;

  Expect<string>('empty body span -> ' + Outcome)
    .ToBe('empty body span -> malformed');
end;

{ --- globals ------------------------------------------------------------- }

{ `valid-global.get` ([] -> [t]) and `valid-global.set` ([t] -> []).
  Unlike a constant expression, a function body sees the WHOLE global
  index space — `valid-constant`'s "only … imported or previously
  defined globals" restriction is a rule about initialisers, not about
  bodies. }
procedure TValidatorBodyTests.TestGlobalGetSet;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.GlobalSec := B([$01, $7F, $01, $41, $00, $0B]);
  S.CodeSec := Code1(B([$00]), B([$23, $00, $24, $00, $0B]));
  BuildAll(S);

  ExpectIr('global get then set',
    L(0, 'global.get', 'r0 <- g0') + #10
    + L(1, 'global.set', 'g0 <- r0') + #10
    + L(2, 'return', ''));
end;

procedure TValidatorBodyTests.TestImmutableGlobalSet;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  { mutability byte $00 — const. }
  S.GlobalSec := B([$01, $7F, $00, $41, $00, $0B]);
  S.CodeSec := Code1(B([$00]), B([$41, $00, $24, $00, $0B]));
  BuildAll(S);

  ExpectInvalid('global.set on a const global', MSG_GLOBAL_IS_IMMUTABLE);
end;

procedure TValidatorBodyTests.TestUnknownGlobal;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$23, $00, $1A, $0B])));

  ExpectInvalid('global.get with no global section', MSG_UNKNOWN_GLOBAL);
end;

{ --- tables -------------------------------------------------------------- }

{ `valid-table.init`: [at i32 i32] -> []. Only the DESTINATION operand is
  address typed; the source offset and the length are always i32. The
  binary form encodes the ELEMENT index first (Track A's
  `binary-instr-table` note), and the IR packs it second — which is why
  Wasm.Ir forbids inferring the packing from the encoding order. }
procedure TValidatorBodyTests.TestTableInit;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.TableSec := B([$01, $70, $00, $01]);
  { one passive segment, elemkind funcref, no items }
  S.ElemSec := B([$01, $01, $00, $00]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $41, $00, $41, $00, $FC, $0C, $00, $00, $0B]));
  BuildAll(S);

  ExpectIr('table.init',
    L(0, 'i32.const', 'r0 <- 0') + #10
    + L(1, 'i32.const', 'r1 <- 0') + #10
    + L(2, 'i32.const', 'r2 <- 0') + #10
    + L(3, 'table.init', 'table=0 elem=0 r0, r1, r2') + #10
    + L(4, 'return', ''));
end;

{ table64 is in the pinned draft, so `valid-table.get`'s `[at] -> [t]` is
  not `[i32] -> [t]`. The limits flag $04 is the i64 address type. }
procedure TValidatorBodyTests.TestTableGetAddressType;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.TableSec := B([$01, $70, $04, $01]);
  S.CodeSec := Code1(B([$00]), B([$42, $00, $25, $00, $1A, $0B]));
  BuildAll(S);

  ExpectIr('table.get on an i64 table',
    L(0, 'i64.const', 'r0 <- 0') + #10
    + L(1, 'table.get', 'r1 <- t0[r0]') + #10
    + L(2, 'return', ''));
end;

{ `valid-table.grow` is [t at] -> [at] and `valid-table.size` [] -> [at]:
  the element value is the DEEPER operand of grow, and both results are
  address typed. }
procedure TValidatorBodyTests.TestTableGrowAndSize;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.TableSec := B([$01, $70, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$D0, $70, $41, $01, $FC, $0F, $00, $1A, $FC, $10, $00, $1A,
       $0B]));
  BuildAll(S);

  ExpectIr('table.grow then table.size',
    L(0, 'ref.null', 'r0 <- funcref') + #10
    + L(1, 'i32.const', 'r1 <- 1') + #10
    + L(2, 'table.grow', 'r2 <- t0 r0, r1') + #10
    + L(3, 'table.size', 'r3 <- t0') + #10
    + L(4, 'return', ''));
end;

procedure TValidatorBodyTests.TestUnknownTable;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $00, $25, $00, $1A, $0B])));

  ExpectInvalid('table.get with no table section', MSG_UNKNOWN_TABLE);
end;

procedure TValidatorBodyTests.TestUnknownElemSegment;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.TableSec := B([$01, $70, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $41, $00, $41, $00, $FC, $0C, $03, $00, $0B]));
  BuildAll(S);

  ExpectInvalid('table.init from a segment that does not exist',
    MSG_UNKNOWN_ELEM_SEGMENT);
end;

{ --- memory -------------------------------------------------------------- }

{ `binary-memarg`: bit 6 of the align flags signals a trailing memidx and
  the offset is a u64. Flags $42 is align 2 WITH the memidx bit, so the
  $00 that follows is the memory index and the last $00 the offset. }
procedure TValidatorBodyTests.TestLoadWithMemidxForm;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $01, $7F]);
  S.FuncSec := B([$01, $00]);
  S.MemorySec := B([$01, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $28, $42, $00, $00, $0B]));
  BuildAll(S);

  ExpectIr('i32.load in the memidx form',
    L(0, 'i32.const', 'r1 <- 0') + #10
    + L(1, 'i32.load', 'r2 <- [r1 + 0] mem=0') + #10
    + L(2, 'move', 'r0 <- r2') + #10
    + L(3, 'return', ''));
end;

{ `valid-memory.copy`: [at1 at2 at] -> []. The count's address type is
  the MINIMUM of the two memories' — UNCONFIRMED and pinned by the Track B
  design document; with one memory the readings coincide. }
procedure TValidatorBodyTests.TestMemoryCopy;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.MemorySec := B([$01, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $41, $00, $41, $00, $FC, $0A, $00, $00, $0B]));
  BuildAll(S);

  ExpectIr('memory.copy',
    L(0, 'i32.const', 'r0 <- 0') + #10
    + L(1, 'i32.const', 'r1 <- 0') + #10
    + L(2, 'i32.const', 'r2 <- 0') + #10
    + L(3, 'memory.copy', 'dst_mem=0 src_mem=0 r0, r1, r2') + #10
    + L(4, 'return', ''));
end;

{ `valid-memory.fill`: [at i32 at] -> []. The BYTE VALUE in the middle is
  i32 whatever the memory's address type is — the one asymmetric operand
  in the bulk-memory family. }
procedure TValidatorBodyTests.TestMemoryFill;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.MemorySec := B([$01, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $41, $01, $41, $02, $FC, $0B, $00, $0B]));
  BuildAll(S);

  ExpectIr('memory.fill',
    L(0, 'i32.const', 'r0 <- 0') + #10
    + L(1, 'i32.const', 'r1 <- 1') + #10
    + L(2, 'i32.const', 'r2 <- 2') + #10
    + L(3, 'memory.fill', 'mem=0 r0, r1, r2') + #10
    + L(4, 'return', ''));
end;

{ `valid-memarg`'s side condition 2^align <= N/8. The flags ENCODING is
  binary grammar (Track A rejects $80 and above); the alignment VALUE is
  validation, so this is invalid rather than malformed. }
procedure TValidatorBodyTests.TestAlignmentTooLarge;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.MemorySec := B([$01, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $28, $03, $00, $1A, $0B]));
  BuildAll(S);

  ExpectInvalid('i32.load with alignment 2^3', MSG_ALIGNMENT_TOO_LARGE);
end;

procedure TValidatorBodyTests.TestUnknownMemory;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $00, $28, $02, $00, $1A, $0B])));

  ExpectInvalid('i32.load with no memory section', MSG_UNKNOWN_MEMORY);
end;

{ `binary-datacntsec`: the data count section exists so that a
  single-pass validator can bound MEMORY.INIT's segment index before the
  data section is read. Its absence is therefore a BINARY grammar
  violation — malformed, not invalid — which is the class Track A pinned
  when it deferred this check to the body walk. }
procedure TValidatorBodyTests.TestMemoryInitNeedsDataCount;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.MemorySec := B([$01, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $41, $00, $41, $00, $FC, $08, $00, $00, $0B]));
  BuildAll(S);

  ExpectMalformed('memory.init with no data count section',
    MSG_DATA_COUNT_REQUIRED);
end;

procedure TValidatorBodyTests.TestMemoryInitWithDataCount;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.MemorySec := B([$01, $00, $01]);
  S.DataCountSec := B([$01]);
  S.CodeSec := Code1(B([$00]),
    B([$41, $00, $41, $00, $41, $00, $FC, $08, $00, $00, $0B]));
  { one passive segment, no bytes }
  S.DataSec := B([$01, $01, $00]);
  BuildAll(S);

  ExpectIr('memory.init with a data count section',
    L(0, 'i32.const', 'r0 <- 0') + #10
    + L(1, 'i32.const', 'r1 <- 0') + #10
    + L(2, 'i32.const', 'r2 <- 0') + #10
    + L(3, 'memory.init', 'mem=0 data=0 r0, r1, r2') + #10
    + L(4, 'return', ''));
end;

procedure TValidatorBodyTests.TestUnknownDataSegment;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.DataCountSec := B([$01]);
  S.CodeSec := Code1(B([$00]), B([$FC, $09, $05, $0B]));
  S.DataSec := B([$01, $01, $00]);
  BuildAll(S);

  ExpectInvalid('data.drop past the data count',
    MSG_UNKNOWN_DATA_SEGMENT);
end;

{ --- references ---------------------------------------------------------- }

{ `valid-ref.func` pushes the CONCRETE function type, non-nullable, and
  requires x in C.REFS — "the list of function indices that occur in the
  module outside functions" (`context`). An export is one such
  occurrence. }
procedure TValidatorBodyTests.TestRefFuncDeclaredByExport;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$01, $60, $00, $00]);
  S.FuncSec := B([$01, $00]);
  S.ExportSec := B([$01, $01, $66, $00, $00]);
  S.CodeSec := Code1(B([$00]), B([$D2, $00, $1A, $0B]));
  BuildAll(S);

  ExpectIr('ref.func on an exported function',
    L(0, 'ref.func', 'r0 <- f0') + #10
    + L(1, 'return', ''));
end;

procedure TValidatorBodyTests.TestRefFuncUndeclared;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$D2, $00, $1A, $0B])));

  ExpectInvalid('ref.func on a function nothing declares',
    MSG_UNDECLARED_FUNCTION_REFERENCE);
end;

{ br_on_null branches when the reference IS null and refines on the
  FALL-THROUGH, which is the one conditional reference branch that can
  take the direct shape: its label receives no value, so there are no
  merge moves to lay out inline. }
procedure TValidatorBodyTests.TestBrOnNullRefinement;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$02, $40, $D0, $70, $D5, $00, $1A, $0B, $0B])));

  ExpectIr('br_on_null',
    L(0, 'ref.null', 'r0 <- funcref') + #10
    + L(1, 'br_on_null', 'r0 -> @0002 else r1 <- (ref func)') + #10
    + L(2, 'return', ''));
end;

{ br_on_non_null is br_on_null's mirror: it branches when the reference is
  NOT null and delivers the refined `(ref ht)` to the label, so its label
  is never empty and the direct shape is therefore unavailable — the taken
  edge is laid out inline behind the inverse op (br_on_null), exactly as
  br_on_cast's is. The fall-through has nothing to refine (the value was
  null and has been consumed), which is what distinguishes the two. }
procedure TValidatorBodyTests.TestBrOnNonNullRefinement;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $64, $70, $D0, $70, $D6, $00, $00, $0B, $1A, $0B])));

  ExpectIr('br_on_non_null',
    L(0, 'ref.null', 'r1 <- funcref') + #10
    + L(1, 'br_on_null', 'r1 -> @0004') + #10
    + L(2, 'move', 'r0 <- r1') + #10
    + L(3, 'jump', '@0005') + #10
    + L(4, 'unreachable', '') + #10
    + L(5, 'return', ''));
end;

{ --- GC ------------------------------------------------------------------ }

{ `appendix/algorithm-validation-of-opcode-sequences`, struct.new: the
  fields pop in reverse through unpack_field, and the result is a
  NON-nullable concrete reference — an allocation cannot yield null. }
procedure TValidatorBodyTests.TestStructNewWithOperands;
begin
  Build(B([$02, $60, $00, $00, $5F, $02, $7F, $01, $7E, $00]),
    B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $01, $42, $02, $FB, $00, $01, $1A, $0B])));

  ExpectIr('struct.new with two fields',
    L(0, 'i32.const', 'r0 <- 1') + #10
    + L(1, 'i64.const', 'r1 <- 2') + #10
    + L(2, 'struct.new', 'r2 <- type=1 (r0, r1)') + #10
    + L(3, 'return', ''));
end;

{ A packed field has no value type, so `struct.get` cannot read it: only
  the `_s`/`_u` forms, which say how to widen it, may. }
procedure TValidatorBodyTests.TestStructGetPackedNeedsExtension;
begin
  Build(B([$02, $60, $00, $00, $5F, $01, $78, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$D0, $01, $FB, $02, $01, $00, $1A, $0B])));

  ExpectInvalid('struct.get on an i8 field', MSG_TYPE_MISMATCH);
end;

{ …and the converse: a sign extension on storage that is already a value
  type is equally meaningless. }
procedure TValidatorBodyTests.TestStructGetSOnUnpackedField;
begin
  Build(B([$02, $60, $00, $00, $5F, $01, $7F, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$D0, $01, $FB, $03, $01, $00, $1A, $0B])));

  ExpectInvalid('struct.get_s on an i32 field', MSG_TYPE_MISMATCH);
end;

procedure TValidatorBodyTests.TestStructSetOnImmutableField;
begin
  Build(B([$02, $60, $00, $00, $5F, $01, $7F, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$D0, $01, $41, $00, $FB, $05, $01, $00, $0B])));

  ExpectInvalid('struct.set on a const field', MSG_TYPE_MISMATCH);
end;

{ `error_if(not is_struct(t))`: the kind check is part of every struct
  rule, and an array type is exactly what it exists to reject. }
procedure TValidatorBodyTests.TestStructOpOnArrayType;
begin
  Build(B([$02, $60, $00, $00, $5E, $7F, $01]), B([$01, $00]), nil,
    Code1(B([$00]), B([$FB, $00, $01, $1A, $0B])));

  ExpectInvalid('struct.new on an array type', MSG_TYPE_MISMATCH);
end;

{ array.new_fixed takes its elements from an aux block; array.len is the
  one $FB arm with no type immediate at all
  (`instruction_get array.len`: [(ref null array)] -> [i32]). }
procedure TValidatorBodyTests.TestArrayNewFixedAndLen;
begin
  Build(B([$02, $60, $00, $00, $5E, $7F, $01]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$41, $01, $41, $02, $FB, $08, $01, $02, $FB, $0F, $1A, $0B])));

  ExpectIr('array.new_fixed then array.len',
    L(0, 'i32.const', 'r0 <- 1') + #10
    + L(1, 'i32.const', 'r1 <- 2') + #10
    + L(2, 'array.new_fixed', 'r2 <- type=1 (r0, r1)') + #10
    + L(3, 'array.len', 'r3 <- r2') + #10
    + L(4, 'return', ''));
end;

{ Four operands do not fit three instruction fields, so array.fill uses an
  aux block — in WASM STACK ORDER, deepest first: [ref, index, value,
  count], confirmed against `valid-array.fill`'s
  [(ref null x) i32 t i32]. }
procedure TValidatorBodyTests.TestArrayFillAuxOrder;
begin
  Build(B([$02, $60, $00, $00, $5E, $7F, $01]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$D0, $01, $41, $00, $41, $01, $41, $02, $FB, $10, $01, $0B])));

  ExpectIr('array.fill operand order',
    L(0, 'ref.null', 'r0 <- (ref null 1)') + #10
    + L(1, 'i32.const', 'r1 <- 0') + #10
    + L(2, 'i32.const', 'r2 <- 1') + #10
    + L(3, 'i32.const', 'r3 <- 2') + #10
    + L(4, 'array.fill', 'type=1 (r0, r1, r2, r3)') + #10
    + L(5, 'return', ''));
end;

{ `appendix/algorithm-validation-of-opcode-sequences`, ref.test:
  `pop_val(Ref(top_heap_type(rt), true))` — the operand is checked against
  the TOP of rt's hierarchy, which for i31 is any. The tested type rides
  in AuxRefTypes, which is what makes $FB 20 and $FB 21 one IR op. }
procedure TValidatorBodyTests.TestRefI31AndCast;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$41, $07, $FB, $1C, $FB, $14, $6C, $1A, $0B])));

  ExpectIr('ref.i31 then ref.test',
    L(0, 'i32.const', 'r0 <- 7') + #10
    + L(1, 'ref.i31', 'r1 <- r0') + #10
    + L(2, 'ref.test', 'r2 <- (ref i31) r1') + #10
    + L(3, 'return', ''));
end;

{ br_on_cast delivers rt2 to the label and keeps `rt1 \ rt2` on the
  fall-through. Its label always has at least one type, so it can never
  take the direct shape: the taken edge is laid out inline behind the
  INVERSE op (br_on_cast_fail), and the fall-through refinement — r2,
  typed (ref 1) because `\` clears nullability — is the move at @0004. }
procedure TValidatorBodyTests.TestBrOnCastRefinement;
begin
  Build(B([$02, $60, $00, $00, $5F, $00]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $63, $01, $D0, $01, $FB, $18, $03, $00, $01, $01, $1A,
         $D0, $01, $0B, $1A, $0B])));

  ExpectIr('br_on_cast with a fall-through refinement',
    L(0, 'ref.null', 'r1 <- (ref null 1)') + #10
    + L(1, 'br_on_cast_fail', 'r1 -> @0004') + #10
    + L(2, 'move', 'r0 <- r1') + #10
    + L(3, 'jump', '@0007') + #10
    + L(4, 'move', 'r2 <- r1') + #10
    + L(5, 'ref.null', 'r3 <- (ref null 1)') + #10
    + L(6, 'move', 'r0 <- r3') + #10
    + L(7, 'return', ''));
end;

{ br_on_cast_fail is the SAME shape with the two result types swapped:
  the label receives `rt1 \ rt2` and the fall-through keeps rt2. The
  bytes below differ from the br_on_cast case by ONE — $FB 25 instead of
  $FB 24 — so the diff between the two expectations is the swap and
  nothing else, which is the property worth pinning. The refinement
  register at @0004 is typed `(ref null 1)` here where br_on_cast's is
  `(ref 1)`. }
procedure TValidatorBodyTests.TestBrOnCastFailSwapsTheTwoResults;
begin
  Build(B([$02, $60, $00, $00, $5F, $00]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $63, $01, $D0, $01, $FB, $19, $03, $00, $01, $01, $1A,
         $D0, $01, $0B, $1A, $0B])));

  ExpectIr('br_on_cast_fail with a fall-through refinement',
    L(0, 'ref.null', 'r1 <- (ref null 1)') + #10
    + L(1, 'br_on_cast', 'r1 -> @0004') + #10
    + L(2, 'move', 'r0 <- r1') + #10
    + L(3, 'jump', '@0007') + #10
    + L(4, 'move', 'r2 <- r1') + #10
    + L(5, 'ref.null', 'r3 <- (ref null 1)') + #10
    + L(6, 'move', 'r0 <- r3') + #10
    + L(7, 'return', ''));
end;

{ UNCONFIRMED rule, deliberately tested so a change is visible: rt2 must
  be a subtype of rt1, or the difference `rt1 \ rt2` describes nothing.
  extern and func are disjoint hierarchies. }
procedure TValidatorBodyTests.TestBrOnCastUnrelatedTypes;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $40, $D0, $70, $FB, $18, $03, $00, $70, $6F, $1A, $0B,
         $0B])));

  ExpectInvalid('br_on_cast from funcref to externref',
    MSG_TYPE_MISMATCH);
end;

{ The label check is `push_val(rt2); pop_vals(label_types)`, so a label
  whose last type is not a supertype of rt2 fails there. }
procedure TValidatorBodyTests.TestBrOnCastLabelMismatch;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$02, $7F, $D0, $70, $FB, $18, $03, $00, $70, $70, $1A, $41,
         $00, $0B, $1A, $0B])));

  ExpectInvalid('br_on_cast into an i32 label', MSG_TYPE_MISMATCH);
end;

{ FIVE operands, so array.copy uses an aux block too — and in the same
  WASM STACK ORDER, deepest first: [dest, dest_index, src, src_index,
  count], read off `valid-array.copy`'s
  [(ref null x) i32 (ref null y) i32 i32]. The two type indices ride
  packed in Imm, destination LOW and source HIGH, which is the order
  IR_OP_INFO fixes and NOT the order the binary encodes them in. }
procedure TValidatorBodyTests.TestArrayCopyAuxOrder;
begin
  Build(B([$02, $60, $00, $00, $5E, $7F, $01]), B([$01, $00]), nil,
    Code1(B([$00]),
      B([$D0, $01, $41, $00, $D0, $01, $41, $00, $41, $01,
         $FB, $11, $01, $01, $0B])));

  ExpectIr('array.copy',
    L(0, 'ref.null', 'r0 <- (ref null 1)') + #10
    + L(1, 'i32.const', 'r1 <- 0') + #10
    + L(2, 'ref.null', 'r2 <- (ref null 1)') + #10
    + L(3, 'i32.const', 'r3 <- 0') + #10
    + L(4, 'i32.const', 'r4 <- 1') + #10
    + L(5, 'array.copy', 'dst_type=1 src_type=1 (r0, r1, r2, r3, r4)')
    + #10
    + L(6, 'return', ''));
end;

{ --- exception handling -------------------------------------------------- }

{ `valid-throw_ref`: [t_1* exnref] -> [t_2*], stack-polymorphic in the
  same way `throw` is — so the frame is dead afterwards and the function's
  trailing return is emitted into dead code, which is why it is there at
  all (an interpreter's fetch loop needs no end-of-array check). }
procedure TValidatorBodyTests.TestThrowRefIsStackPolymorphic;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$D0, $69, $0A, $0B])));

  ExpectIr('throw_ref',
    L(0, 'ref.null', 'r0 <- exnref') + #10
    + L(1, 'throw_ref', 'r0') + #10
    + L(2, 'return', ''));
end;

{ try_table emits no instruction: it contributes a handler-table entry
  covering its body's instruction range plus one clause per catch. The
  clause labels resolve in the PRE-PUSH control stack (the appendix
  evaluates ctrls[handler.label] before push_ctrl(try_table, ...)), so
  here 0 is $h and 1 is $a — off by one if the frame were pushed first.

  Each clause's payload destination IS the target label's merge-register
  vector, which is what the appendix's push_ctrl(catch, [],
  label_types)/pop_ctrl pair asserts: catch delivers the tag's params
  (i32 -> r1, $h's merge register) and catch_all_ref delivers an exnref
  (-> r0, $a's). }
procedure TValidatorBodyTests.TestTryTableTwoCatchKinds;
var
  S: TModuleSections;
  Fn: TWasmIrFunction;
begin
  S := NoSections;
  S.TypeSec := B([$02, $60, $00, $00, $60, $01, $7F, $00]);
  S.FuncSec := B([$01, $00]);
  S.TagSec := B([$01, $00, $01]);
  S.CodeSec := Code1(B([$00]),
    B([$02, $69, $02, $7F, $1F, $7F, $02, $00, $00, $00, $03, $01,
       $41, $01, $0B, $0B, $1A, $D0, $69, $0B, $1A, $0B]));
  BuildAll(S);

  ExpectIr('try_table with catch and catch_all_ref',
    L(0, 'i32.const', 'r3 <- 1') + #10
    + L(1, 'move', 'r2 <- r3') + #10
    + L(2, 'move', 'r1 <- r2') + #10
    + L(3, 'ref.null', 'r4 <- exnref') + #10
    + L(4, 'move', 'r0 <- r4') + #10
    + L(5, 'return', ''));

  Fn := ValidateAt(0);
  Expect<string>(DescribeHandlers(Fn)).ToBe(
    'handler [0, 2)' + #10
    + '  catch tag=0 -> @0003 payload (r1)' + #10
    + '  catch_all_ref -> @0005 payload (r0)');
end;

{ `syntax-tagtype`: "The result type is empty for exception tags". A tag
  whose function type returns something would push a result `throw` never
  produces. }
procedure TValidatorBodyTests.TestThrowWithNonEmptyResultTag;
var
  S: TModuleSections;
begin
  S := NoSections;
  S.TypeSec := B([$02, $60, $00, $00, $60, $01, $7F, $01, $7F]);
  S.FuncSec := B([$01, $00]);
  S.TagSec := B([$01, $00, $01]);
  S.CodeSec := Code1(B([$00]), B([$41, $00, $08, $00, $0B]));
  BuildAll(S);

  ExpectInvalid('throw with a tag that has results', MSG_TYPE_MISMATCH);
end;

procedure TValidatorBodyTests.TestUnknownTag;
begin
  Build(B([$01, $60, $00, $00]), B([$01, $00]), nil,
    Code1(B([$00]), B([$08, $00, $0B])));

  ExpectInvalid('throw with no tag section', MSG_UNKNOWN_TAG);
end;

procedure TValidatorBodyTests.SetupTests;
begin
  Test('block with a result lowers to two chained moves',
    TestBlockWithResult);
  Test('a loop back-edge is the only safepoint-flagged jump',
    TestLoopBackEdgeSafepoint);
  Test('if/else merges both arms into one register',
    TestIfElseMergeMoves);
  Test('br into a multi-value label emits a parallel move',
    TestNestedBranchMultiValueMerge);
  Test('br_table emits one stub per target, default last',
    TestBrTablePerTargetStubs);
  Test('multi-value return writes the return register block',
    TestReturnMultiValue);
  Test('return_call is a distinct op with no return merge',
    TestTailCall);

  Test('br_if with merge moves uses the inverted form',
    TestBrIfMergeMovesUseInvertedForm);
  Test('if without else synthesises the missing arm',
    TestIfWithoutElseSynthesisesTheArm);
  Test('else inherits the if frame''s unresolved jump patches',
    TestElseInheritsUnresolvedJumpPatches);
  Test('unreachable code type-checks but emits nothing',
    TestUnreachableCodeEmitsNothing);
  Test('a function ending in br still ends with a return',
    TestFunctionEndingInBrStillEndsWithReturn);
  Test('call emits aux argument and result lists',
    TestCallEmitsAuxArgAndResultLists);
  Test('call_indirect reads the table index space',
    TestCallIndirectReadsTheTableSpace);
  Test('select carries its condition in Imm', TestSelectLowering);
  Test('a void call still emits both aux lists, empty',
    TestVoidCallEmitsEmptyAuxLists);

  Test('a non-defaultable local is readable after a set',
    TestNonDefaultableLocalAfterSet);
  Test('reading an uninitialized local is rejected',
    TestUninitializedLocalIsRejected);
  Test('block exit resets local initialization',
    TestBlockExitResetsLocalInitialization);
  Test('local.tee pushes back the operand register',
    TestLocalTeeReusesTheOperandRegister);
  Test('a local naming an undefined type is rejected',
    TestLocalOfUnknownConcreteTypeIsRejected);
  Test('a block result naming an undefined type is rejected in dead code',
    TestBlockResultOfUnknownConcreteTypeIsRejected);

  Test('the parallel move breaks a cycle with a temporary',
    TestParallelMoveBreaksACycle);
  Test('the parallel move handles duplicate sources',
    TestParallelMoveWithDuplicateSources);

  Test('numeric operands are checked', TestNumericTypeMismatch);
  Test('unreachable code still type-checks',
    TestUnreachableStillTypeChecks);
  Test('a block result must match its type',
    TestBlockResultTypeMismatch);
  Test('select operands must agree', TestSelectOperandMismatch);
  Test('drop underflows the current block', TestDropUnderflow);
  Test('br past the outermost label is unknown', TestUnknownLabel);
  Test('local.get past the local space is unknown', TestUnknownLocal);
  Test('call past the function space is unknown', TestUnknownFunction);
  Test('br_table target arities must agree', TestBrTableArityMismatch);
  Test('typed select takes exactly one type', TestTypedSelectArity);
  Test('return_call results must match the caller''s',
    TestTailCallResultMismatch);
  Test('a body ending before its span is malformed',
    TestBodyEndBeforeSpanEnd);
  Test('a misplaced else is malformed', TestMisplacedElse);
  Test('an unassigned opcode is malformed', TestUnknownOpcode);
  Test('SIMD validation is staged, never silently accepted',
    TestSimdIsStaged);
  Test('br_table''s label count is bounded by the bytes left',
    TestBrTableCountIsBoundedByTheBytesLeft);
  Test('array.new_fixed''s count is bounded by the value stack',
    TestArrayNewFixedCountIsBoundedByTheStack);
  Test('array.new_fixed stays polymorphic in dead code',
    TestArrayNewFixedIsPolymorphicInDeadCode);
  Test('a locals count past the register file is an implementation limit',
    TestTooManyLocalsHitsTheImplementationLimit);
  Test('an empty function body span is malformed',
    TestEmptyBodySpanIsRejected);

  Test('global.get and global.set lower to one op each',
    TestGlobalGetSet);
  Test('global.set on an immutable global is rejected',
    TestImmutableGlobalSet);
  Test('an out-of-range global index is unknown', TestUnknownGlobal);

  Test('table.init packs the table index low and the elem index high',
    TestTableInit);
  Test('table.get takes the table''s address type',
    TestTableGetAddressType);
  Test('table.grow and table.size yield the address type',
    TestTableGrowAndSize);
  Test('an out-of-range table index is unknown', TestUnknownTable);
  Test('an out-of-range elem segment index is unknown',
    TestUnknownElemSegment);

  Test('a load reads the memidx form of memarg',
    TestLoadWithMemidxForm);
  Test('memory.copy takes three address-typed operands', TestMemoryCopy);
  Test('memory.fill takes an i32 byte value', TestMemoryFill);
  Test('an alignment larger than natural is rejected',
    TestAlignmentTooLarge);
  Test('an out-of-range memory index is unknown', TestUnknownMemory);
  Test('memory.init without a data count section is malformed',
    TestMemoryInitNeedsDataCount);
  Test('memory.init with a data count section validates',
    TestMemoryInitWithDataCount);
  Test('a data index past the data count is unknown',
    TestUnknownDataSegment);

  Test('ref.func on a declared function pushes its concrete type',
    TestRefFuncDeclaredByExport);
  Test('ref.func on an undeclared function is rejected',
    TestRefFuncUndeclared);
  Test('br_on_null refines the reference on the fall-through',
    TestBrOnNullRefinement);
  Test('br_on_non_null delivers the refined reference to the label',
    TestBrOnNonNullRefinement);

  Test('struct.new takes its fields from an aux block',
    TestStructNewWithOperands);
  Test('struct.get on a packed field needs a sign extension',
    TestStructGetPackedNeedsExtension);
  Test('struct.get_s on an unpacked field is rejected',
    TestStructGetSOnUnpackedField);
  Test('struct.set on an immutable field is rejected',
    TestStructSetOnImmutableField);
  Test('a struct instruction on an array type is rejected',
    TestStructOpOnArrayType);
  Test('array.new_fixed and array.len lower as documented',
    TestArrayNewFixedAndLen);
  Test('array.fill puts its operands in stack order in an aux block',
    TestArrayFillAuxOrder);
  Test('array.copy puts five operands in stack order in an aux block',
    TestArrayCopyAuxOrder);
  Test('ref.i31 and ref.test carry the tested type in AuxRefTypes',
    TestRefI31AndCast);
  Test('br_on_cast lays the taken edge out behind the inverse op',
    TestBrOnCastRefinement);
  Test('br_on_cast_fail swaps the label and fall-through types',
    TestBrOnCastFailSwapsTheTwoResults);
  Test('br_on_cast between unrelated hierarchies is rejected',
    TestBrOnCastUnrelatedTypes);
  Test('br_on_cast into a label that cannot take rt2 is rejected',
    TestBrOnCastLabelMismatch);

  Test('try_table records a handler range and its catch clauses',
    TestTryTableTwoCatchKinds);
  Test('throw_ref is stack-polymorphic', TestThrowRefIsStackPolymorphic);
  Test('throw with a non-empty tag result type is rejected',
    TestThrowWithNonEmptyResultTag);
  Test('an out-of-range tag index is unknown', TestUnknownTag);
end;

begin
  TestRunnerProgram.AddSuite(
    TValidatorBodyTests.Create('Wasm.Validator.Body'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
