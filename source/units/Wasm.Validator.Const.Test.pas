{ Unit suite for Wasm.Validator.Const.

  Every case is a real module assembled byte by byte and pushed through
  the real decoder, so the constant expression under test is a span the
  binary grammar accepted and Wasm.Decoder.Expr's skipper already walked
  — which is the premise the unit is written against. The expression
  always sits in a GLOBAL initialiser because that is the call site with
  the most interesting scoping rule (`valid-constant`: global i sees the
  imports plus globals 0..i-1), and because it needs no code section.

  Positives assert the emitted IR as disassembled text (Wasm.Ir's
  Describe), not record internals, so they survive an encoding tweak.
  Negatives assert BOTH the exception class and the canonical message
  prefix: the malformed/invalid boundary and the prefixes are
  conformance surface.

  The fixed module every case is built on:

    type 0  (func)                      $60 00 00
    type 1  (struct (field i32) (field i64))
    type 2  (array (mut i32))
    import 0  "m"."f"  (func (type 0))        -> funcidx 0
    import 1  "m"."g"  (global i32)           -> globalidx 0, immutable
    import 2  "m"."h"  (global (mut i32))     -> globalidx 1, MUTABLE
    import 3  "m"."e"  (global externref)     -> globalidx 2, immutable

  so defined globals start at index 3.

  Spec anchors are cited per group, read from wasm-mcp 0.2.16 at the
  pinned commit d7b37e4170d8315f2f1283aed4e8076591a9a333.

  `const` is a reserved word, so the unit under test is spelled
  `Wasm.Validator.&Const` with FPC's identifier escape — see that unit's
  header. The file names are unaffected. }
program Wasm.Validator.&Const.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator.&Const,
  Wasm.Validator.Types;

const
  { Globals 0..2 come from imports, so the first DEFINED global is 3. }
  IMPORTED_GLOBALS = 3;

type
  { A growable byte buffer, so a section's size prefix is computed rather
    than hand-counted — a miscounted length would fail as a decode error
    and disguise whatever the case was actually about. }
  TByteBuf = record
    Data: TWasmBytes;
    Count: Integer;

    procedure Reset;
    procedure Add(const AValue: Byte);
    procedure AddMany(const AValues: array of Byte);
    procedure AddU32(const AValue: UInt32);
    procedure Section(const AId: TWasmSectionId;
      const ABody: array of Byte);
    function Finish: TWasmBytes;
  end;

  TValidatorConstTests = class(TTestSuite)
  private
    { The decoded module borrows this buffer (ADR-0003), so it must live
      as long as the module does. }
    FBytes: TWasmBytes;
    FModule: TWasmModule;
    FTypes: TWasmTypeContext;
    FConst: TWasmConstContext;
    FFuncRefs: TWasmConstFuncRefs;

    procedure BuildGlobals(const AGlobalSection: array of Byte);
    function ValidateAtLimit(const ADefinedIndex: Integer;
      const ALimit: UInt32): TWasmIrInitExpr;
    function ValidateAt(const ADefinedIndex: Integer): TWasmIrInitExpr;

    function PrefixOutcome(const AMessage, APrefix: string): string;
    procedure ExpectInvalidAtLimit(const ADescription, APrefix: string;
      const AGlobalSection: array of Byte;
      const ADefinedIndex: Integer; const ALimit: UInt32);
    procedure ExpectInvalid(const ADescription, APrefix: string;
      const AGlobalSection: array of Byte);

    function IrLine(const AIndex: Integer;
      const AMnemonic, AOperands: string): string;
    procedure ExpectIr(const ADescription: string;
      const AExpr: TWasmIrInitExpr; const AExpected: string);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestNumericConstants;
    procedure TestDisassemblyLineLayout;
    procedure TestExtendedConstArithmeticChain;
    procedure TestExtendedConstI64;
    procedure TestRefNull;
    procedure TestRefFuncRecordsItsIndex;
    procedure TestRefFuncSubsumesFuncref;
    procedure TestGlobalGetOfImportedGlobal;
    procedure TestGlobalGetOfPrecedingDefinedGlobal;
    procedure TestStructNewWithFieldOperands;
    procedure TestStructNewDefault;
    procedure TestArrayNewAndNewDefault;
    procedure TestArrayNewFixed;
    procedure TestRefI31;
    procedure TestExternConversions;
    procedure TestExternConvertAnyIsNotNullPreserving;

    procedure TestRejectsNop;
    procedure TestRejectsLocalGet;
    procedure TestRejectsI32Eqz;
    procedure TestRejectsMiscPrefixInstruction;
    procedure TestRejectsArrayNewData;
    procedure TestRejectsWrongResultType;
    procedure TestRejectsEmptyExpression;
    procedure TestRejectsUnknownGlobal;
    procedure TestRejectsSelfReferencingGlobal;
    procedure TestRejectsGlobalOutsideImportedOnlyScope;
    procedure TestRejectsMutableGlobalGet;
    procedure TestRejectsUnknownFunction;
    procedure TestRejectsUnknownType;
    procedure TestRejectsNonAggregateTypeIndex;
    procedure TestRejectsSimd;
  end;

{ --- TByteBuf ------------------------------------------------------------ }

procedure TByteBuf.Reset;
begin
  Data := nil;
  Count := 0;
end;

procedure TByteBuf.Add(const AValue: Byte);
begin
  if Count >= Length(Data) then
    SetLength(Data, (Count + 1) * 2);
  Data[Count] := AValue;
  Inc(Count);
end;

procedure TByteBuf.AddMany(const AValues: array of Byte);
var
  I: Integer;
begin
  for I := 0 to High(AValues) do
    Add(AValues[I]);
end;

procedure TByteBuf.AddU32(const AValue: UInt32);
var
  Rest: UInt32;
begin
  Rest := AValue;
  repeat
    if Rest < $80 then
      Add(Byte(Rest))
    else
      Add(Byte((Rest and $7F) or $80));
    Rest := Rest shr 7;
  until Rest = 0;
end;

procedure TByteBuf.Section(const AId: TWasmSectionId;
  const ABody: array of Byte);
begin
  Add(Ord(AId));
  AddU32(UInt32(Length(ABody)));
  AddMany(ABody);
end;

function TByteBuf.Finish: TWasmBytes;
begin
  SetLength(Data, Count);
  Result := Data;
end;

{ --- fixture ------------------------------------------------------------- }

procedure TValidatorConstTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FFuncRefs := nil;
end;

procedure TValidatorConstTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

procedure TValidatorConstTests.BuildGlobals(
  const AGlobalSection: array of Byte);
var
  Buf: TByteBuf;
begin
  Buf.Reset;
  Buf.AddMany([$00, $61, $73, $6D, $01, $00, $00, $00]);

  { type 0 = (func), type 1 = (struct i32 i64), type 2 = (array (mut i32)).
    A field type is a storage type followed by the mutability byte. }
  Buf.Section(wsType, [$03,
    $60, $00, $00,
    $5F, $02, $7F, $00, $7E, $00,
    $5E, $7F, $01]);

  { One function import and three global imports; the third is MUTABLE and
    the fourth is an externref, both needed below. }
  Buf.Section(wsImport, [$04,
    $01, $6D, $01, $66, $00, $00,
    $01, $6D, $01, $67, $03, $7F, $00,
    $01, $6D, $01, $68, $03, $7F, $01,
    $01, $6D, $01, $65, $03, $6F, $00]);

  Buf.Section(wsGlobal, AGlobalSection);

  FBytes := Buf.Finish;
  DecodeModule(FBytes, FModule);
  FTypes.Build(FModule);
  BuildConstContext(FModule, FConst);
end;

function TValidatorConstTests.ValidateAtLimit(const ADefinedIndex: Integer;
  const ALimit: UInt32): TWasmIrInitExpr;
var
  Global: TWasmGlobal;
begin
  Global := FModule.Globals[ADefinedIndex];
  FConst.GlobalLimit := ALimit;
  Result := ValidateConstExpr(FTypes, FConst, FBytes,
    Global.Init, Global.GlobalType.ValueType, FFuncRefs);
end;

function TValidatorConstTests.ValidateAt(
  const ADefinedIndex: Integer): TWasmIrInitExpr;
begin
  { `valid-constant` / `valid-globalseq`: global i's initialiser sees the
    imported globals and the globals defined before it, and nothing
    else. }
  Result := ValidateAtLimit(ADefinedIndex,
    UInt32(IMPORTED_GLOBALS + ADefinedIndex));
end;

function TValidatorConstTests.PrefixOutcome(const AMessage,
  APrefix: string): string;
begin
  if Copy(AMessage, 1, Length(APrefix)) = APrefix then
    Result := 'rejected: ' + APrefix
  else
    Result := 'rejected with message: ' + AMessage;
end;

procedure TValidatorConstTests.ExpectInvalidAtLimit(const ADescription,
  APrefix: string; const AGlobalSection: array of Byte;
  const ADefinedIndex: Integer; const ALimit: UInt32);
var
  Outcome: string;
begin
  Outcome := 'ACCEPTED';

  { The class is asserted as well as the prefix. A decode error here
    would mean the module never reached the validator, which would make
    the case vacuous rather than passing. }
  try
    BuildGlobals(AGlobalSection);
    ValidateAtLimit(ADefinedIndex, ALimit);
  except
    on E: EWasmValidationError do
      Outcome := PrefixOutcome(E.Message, APrefix);
    on E: EWasmDecodeError do
      Outcome := 'decode error: ' + E.Message;
  end;

  Expect<string>(ADescription + ' -> ' + Outcome)
    .ToBe(ADescription + ' -> rejected: ' + APrefix);
end;

procedure TValidatorConstTests.ExpectInvalid(const ADescription,
  APrefix: string; const AGlobalSection: array of Byte);
begin
  ExpectInvalidAtLimit(ADescription, APrefix, AGlobalSection, 0,
    UInt32(IMPORTED_GLOBALS));
end;

function TValidatorConstTests.IrLine(const AIndex: Integer;
  const AMnemonic, AOperands: string): string;
begin
  { Wasm.Ir's pinned line format, so a test states the mnemonic and the
    operands and does not restate the column arithmetic. One case below
    additionally asserts the raw layout. }
  Result := TrimRight(Format('%.4d  %-22s %s',
    [AIndex, AMnemonic, AOperands]));
end;

procedure TValidatorConstTests.ExpectIr(const ADescription: string;
  const AExpr: TWasmIrInitExpr; const AExpected: string);
begin
  Expect<string>(ADescription + #10 + DescribeIrInitExpr(AExpr))
    .ToBe(ADescription + #10 + AExpected);
end;

{ --- positives: numeric constants and extended-const arithmetic ---------- }

procedure TValidatorConstTests.TestNumericConstants;
var
  Expr: TWasmIrInitExpr;
begin
  { `Instr_const/const` — t.const for all four numeric types. Floats
    travel as bit patterns, never through an FPC float type. }
  BuildGlobals([$01, $7F, $00, $41, $07, $0B]);
  Expr := ValidateAt(0);
  ExpectIr('i32.const 7', Expr, IrLine(0, 'i32.const', 'r0 <- 7'));
  Expect<Int64>(Int64(Expr.ResultReg)).ToBe(0);

  BuildGlobals([$01, $7E, $00, $42, $7F, $0B]);
  { $7F as an sLEB128 i64 is -1: the immediate is SIGNED. }
  ExpectIr('i64.const -1', ValidateAt(0),
    IrLine(0, 'i64.const', 'r0 <- -1'));

  BuildGlobals([$01, $7D, $00, $43, $00, $00, $80, $3F, $0B]);
  ExpectIr('f32.const 1.0', ValidateAt(0),
    IrLine(0, 'f32.const', 'r0 <- 0x3F800000'));

  BuildGlobals([$01, $7C, $00, $44,
    $00, $00, $00, $00, $00, $00, $F0, $3F, $0B]);
  ExpectIr('f64.const 1.0', ValidateAt(0),
    IrLine(0, 'f64.const', 'r0 <- 0x3FF0000000000000'));
end;

procedure TValidatorConstTests.TestDisassemblyLineLayout;
begin
  { The one case that spells the disassembler's column layout literally,
    so IrLine above cannot mask a change to it. The mnemonic column is 22
    wide and is followed by one separating space. }
  BuildGlobals([$01, $7F, $00, $41, $07, $0B]);
  Expect<string>(DescribeIrInitExpr(ValidateAt(0)))
    .ToBe('0000  i32.const' + StringOfChar(' ', 14) + 'r0 <- 7');
end;

procedure TValidatorConstTests.TestExtendedConstArithmeticChain;
var
  Expr: TWasmIrInitExpr;
begin
  { `Instr_const/binop`, restricted to add/sub/mul over the integer types
    (`appendix/changes-extended-constant-expressions`):
      (i32.const 1) (i32.const 2) i32.add (i32.const 3) i32.mul }
  BuildGlobals([$01, $7F, $00,
    $41, $01, $41, $02, $6A, $41, $03, $6C, $0B]);
  Expr := ValidateAt(0);

  ExpectIr('extended-const chain', Expr,
    IrLine(0, 'i32.const', 'r0 <- 1') + #10
    + IrLine(1, 'i32.const', 'r1 <- 2') + #10
    + IrLine(2, 'i32.add', 'r2 <- r0, r1') + #10
    + IrLine(3, 'i32.const', 'r3 <- 3') + #10
    + IrLine(4, 'i32.mul', 'r4 <- r2, r3'));

  Expect<Int64>(Int64(Expr.ResultReg)).ToBe(4);
  Expect<Int64>(Int64(Expr.RegisterCount)).ToBe(5);
end;

procedure TValidatorConstTests.TestExtendedConstI64;
begin
  { The i64 half of the same rule, and the operand ORDER: the right
    operand is on top of the stack, so `1 2 i64.sub` is `r0 - r1`. }
  BuildGlobals([$01, $7E, $00, $42, $01, $42, $02, $7D, $0B]);
  ExpectIr('i64.sub operand order', ValidateAt(0),
    IrLine(0, 'i64.const', 'r0 <- 1') + #10
    + IrLine(1, 'i64.const', 'r1 <- 2') + #10
    + IrLine(2, 'i64.sub', 'r2 <- r0, r1'));
end;

{ --- positives: references ----------------------------------------------- }

procedure TValidatorConstTests.TestRefNull;
begin
  { `Instr_const/ref.null`. ref.null carries no heap type in the
    instruction; Describe reads it back from the register table. }
  BuildGlobals([$01, $70, $00, $D0, $70, $0B]);
  ExpectIr('ref.null func', ValidateAt(0),
    IrLine(0, 'ref.null', 'r0 <- funcref'));

  BuildGlobals([$01, $63, $01, $00, $D0, $01, $0B]);
  ExpectIr('ref.null of a concrete type', ValidateAt(0),
    IrLine(0, 'ref.null', 'r0 <- (ref null 1)'));
end;

procedure TValidatorConstTests.TestRefFuncRecordsItsIndex;
var
  Expr: TWasmIrInitExpr;
begin
  { `Instr_const/ref.func` / `valid-ref.func`: the result is a NON-NULL
    reference to the function's CONCRETE type, so a `(ref 0)` global is
    satisfied. The index is reported to the caller because it is what
    puts function 0 into C.REFS (`context`). }
  BuildGlobals([$01, $64, $00, $00, $D2, $00, $0B]);
  Expr := ValidateAt(0);

  ExpectIr('ref.func 0', Expr, IrLine(0, 'ref.func', 'r0 <- f0'));
  Expect<Integer>(Length(FFuncRefs)).ToBe(1);
  Expect<Int64>(Int64(FFuncRefs[0])).ToBe(0);
end;

procedure TValidatorConstTests.TestRefFuncSubsumesFuncref;
begin
  { Result-type SUBSUMPTION (`match-valtype`, `match-reftype`): the
    expression yields `(ref 0)`, the global wants the nullable abstract
    `funcref`, and a non-null concrete reference matches it. Requiring
    equality here would reject a valid module. }
  BuildGlobals([$01, $70, $00, $D2, $00, $0B]);
  ExpectIr('ref.func against funcref', ValidateAt(0),
    IrLine(0, 'ref.func', 'r0 <- f0'));
end;

procedure TValidatorConstTests.TestGlobalGetOfImportedGlobal;
begin
  { `Instr_const/global.get`, immutable global 0 (an import). }
  BuildGlobals([$01, $7F, $00, $23, $00, $0B]);
  ExpectIr('global.get 0', ValidateAt(0),
    IrLine(0, 'global.get', 'r0 <- g0'));
end;

procedure TValidatorConstTests.TestGlobalGetOfPrecedingDefinedGlobal;
begin
  { `valid-constant`: a global's initialiser may name "imported or
    previously defined globals", which the extended-const change narrows
    to immutable ones. Defined global 0 is index 3, so global 1's
    initialiser may read it. }
  BuildGlobals([$02,
    $7F, $00, $41, $07, $0B,
    $7F, $00, $23, $03, $0B]);
  ExpectIr('global.get of the preceding defined global', ValidateAt(1),
    IrLine(0, 'global.get', 'r0 <- g3'));
end;

{ --- positives: the GC allocation set ------------------------------------ }

procedure TValidatorConstTests.TestStructNewWithFieldOperands;
var
  Expr: TWasmIrInitExpr;
begin
  { `Instr_const/struct.new` / `valid-struct.new`: the operands are the
    field types in field order, deepest first, and the result is a
    non-null `(ref 1)`. }
  BuildGlobals([$01, $64, $01, $00,
    $41, $01, $42, $02, $FB, $00, $01, $0B]);
  Expr := ValidateAt(0);

  ExpectIr('struct.new with field operands', Expr,
    IrLine(0, 'i32.const', 'r0 <- 1') + #10
    + IrLine(1, 'i64.const', 'r1 <- 2') + #10
    + IrLine(2, 'struct.new', 'r2 <- type=1 (r0, r1)'));
  Expect<Int64>(Int64(Expr.ResultReg)).ToBe(2);
end;

procedure TValidatorConstTests.TestStructNewDefault;
begin
  { `Instr_const/struct.new_default`: every field of type 1 is a number
    type, so every field has a default (`aux-default`). }
  BuildGlobals([$01, $64, $01, $00, $FB, $01, $01, $0B]);
  ExpectIr('struct.new_default', ValidateAt(0),
    IrLine(0, 'struct.new_default', 'r0 <- type=1'));
end;

procedure TValidatorConstTests.TestArrayNewAndNewDefault;
begin
  { `valid-array.new`: [t i32] -> [(ref x)], length on top. }
  BuildGlobals([$01, $64, $02, $00,
    $41, $09, $41, $03, $FB, $06, $02, $0B]);
  ExpectIr('array.new', ValidateAt(0),
    IrLine(0, 'i32.const', 'r0 <- 9') + #10
    + IrLine(1, 'i32.const', 'r1 <- 3') + #10
    + IrLine(2, 'array.new', 'r2 <- type=2 r0, r1'));

  BuildGlobals([$01, $64, $02, $00, $41, $03, $FB, $07, $02, $0B]);
  ExpectIr('array.new_default', ValidateAt(0),
    IrLine(0, 'i32.const', 'r0 <- 3') + #10
    + IrLine(1, 'array.new_default', 'r1 <- type=2 r0'));
end;

procedure TValidatorConstTests.TestArrayNewFixed;
begin
  { `valid-array.new_fixed`: [t^n] -> [(ref x)]. The immediates are the
    type index THEN the element count (`binary-instr-aggr`). }
  BuildGlobals([$01, $64, $02, $00,
    $41, $01, $41, $02, $FB, $08, $02, $02, $0B]);
  ExpectIr('array.new_fixed 2', ValidateAt(0),
    IrLine(0, 'i32.const', 'r0 <- 1') + #10
    + IrLine(1, 'i32.const', 'r1 <- 2') + #10
    + IrLine(2, 'array.new_fixed', 'r2 <- type=2 (r0, r1)'));
end;

procedure TValidatorConstTests.TestRefI31;
begin
  { `valid-ref.i31`: [i32] -> [(ref i31)] — non-nullable, and `i31ref`
    is the nullable spelling, so the match is a subsumption. }
  BuildGlobals([$01, $6C, $00, $41, $05, $FB, $1C, $0B]);
  ExpectIr('ref.i31', ValidateAt(0),
    IrLine(0, 'i32.const', 'r0 <- 5') + #10
    + IrLine(1, 'ref.i31', 'r1 <- r0'));
end;

procedure TValidatorConstTests.TestExternConversions;
begin
  { `Instr_const/extern.convert_any` and `/any.convert_extern`. }
  BuildGlobals([$01, $6F, $00, $41, $01, $FB, $1C, $FB, $1B, $0B]);
  ExpectIr('extern.convert_any of a ref.i31', ValidateAt(0),
    IrLine(0, 'i32.const', 'r0 <- 1') + #10
    + IrLine(1, 'ref.i31', 'r1 <- r0') + #10
    + IrLine(2, 'extern.convert_any', 'r2 <- r1'));

  { The other direction, from the imported externref global. }
  BuildGlobals([$01, $6E, $00, $23, $02, $FB, $1A, $0B]);
  ExpectIr('any.convert_extern of an externref global', ValidateAt(0),
    IrLine(0, 'global.get', 'r0 <- g2') + #10
    + IrLine(1, 'any.convert_extern', 'r1 <- r0'));
end;

{ THE CASE THAT DISCRIMINATES THE TWO READINGS of the two conversions,
  and the reason it is here rather than in a comment: `extern.convert_any`
  is served with the FLAT signature [(ref null extern)] -> [(ref null any)]
  and the mirror, so its result is nullable whatever the operand was —
  and `ref.i31` yields a NON-null `(ref i31)`. Under the flat reading the
  result is `externref`, which does not match a `(ref extern)` global, so
  this is REJECTED. Under the propagating reading the non-nullability
  would carry through and the same module would be accepted.

  Wasm.Validator.Body's HandleI31Extern takes the same flat reading, so
  the two sites agree. If Track C's runner settles the question the other
  way this test FLIPS to a positive — it does not get deleted, because
  the whole point is that the answer is visible in the suite. }
procedure TValidatorConstTests.TestExternConvertAnyIsNotNullPreserving;
begin
  { (global (ref extern) (extern.convert_any (ref.i31 (i32.const 1)))) }
  ExpectInvalid('extern.convert_any into a non-nullable (ref extern)',
    MSG_TYPE_MISMATCH,
    [$01, $64, $6F, $00, $41, $01, $FB, $1C, $FB, $1B, $0B]);
end;

{ --- negatives: constness ------------------------------------------------ }

procedure TValidatorConstTests.TestRejectsNop;
begin
  ExpectInvalid('nop in a constant expression',
    MSG_CONSTANT_EXPRESSION_REQUIRED,
    [$01, $7F, $00, $01, $41, $07, $0B]);
end;

procedure TValidatorConstTests.TestRejectsLocalGet;
begin
  ExpectInvalid('local.get in a constant expression',
    MSG_CONSTANT_EXPRESSION_REQUIRED,
    [$01, $7F, $00, $20, $00, $0B]);
end;

procedure TValidatorConstTests.TestRejectsI32Eqz;
begin
  { A numeric instruction that is not add/sub/mul: the extended-const set
    is exactly three operators, not "arithmetic". }
  ExpectInvalid('i32.eqz in a constant expression',
    MSG_CONSTANT_EXPRESSION_REQUIRED,
    [$01, $7F, $00, $41, $07, $45, $0B]);
end;

procedure TValidatorConstTests.TestRejectsMiscPrefixInstruction;
begin
  { $FC 0 is i32.trunc_sat_f32_s; nothing in the $FC space is
    constant. }
  ExpectInvalid('a $FC-prefixed instruction',
    MSG_CONSTANT_EXPRESSION_REQUIRED,
    [$01, $7F, $00, $FC, $00, $0B]);
end;

procedure TValidatorConstTests.TestRejectsArrayNewData;
begin
  { array.new_data ($FB 9) allocates, but `valid-constant` does not list
    it — only struct.new/_default, array.new/_default/_fixed, ref.i31 and
    the two extern conversions. Pinning the omission is the point. }
  ExpectInvalid('array.new_data in a constant expression',
    MSG_CONSTANT_EXPRESSION_REQUIRED,
    [$01, $6E, $00, $FB, $09, $02, $00, $0B]);
end;

procedure TValidatorConstTests.TestRejectsMutableGlobalGet;
begin
  { `appendix/changes-extended-constant-expressions` admits GLOBAL.GET
    only "for any previously declared immutable global", so global 1 —
    imported and mutable — makes the INSTRUCTION non-constant rather than
    producing a type error. }
  ExpectInvalid('global.get of a mutable global',
    MSG_CONSTANT_EXPRESSION_REQUIRED,
    [$01, $7F, $00, $23, $01, $0B]);
end;

{ --- negatives: typing and index spaces ---------------------------------- }

procedure TValidatorConstTests.TestRejectsWrongResultType;
begin
  ExpectInvalid('i32 initialiser for an i64 global', MSG_TYPE_MISMATCH,
    [$01, $7E, $00, $41, $07, $0B]);
end;

procedure TValidatorConstTests.TestRejectsEmptyExpression;
begin
  { `Expr_const`: an initialiser yields exactly one value. }
  ExpectInvalid('empty constant expression', MSG_TYPE_MISMATCH,
    [$01, $7F, $00, $0B]);
end;

procedure TValidatorConstTests.TestRejectsUnknownGlobal;
begin
  ExpectInvalid('global.get past the global index space',
    MSG_UNKNOWN_GLOBAL, [$01, $7F, $00, $23, $09, $0B]);
end;

procedure TValidatorConstTests.TestRejectsSelfReferencingGlobal;
begin
  { `valid-constant`: globals "are not recursive but evaluated
    sequentially" (`valid-module`), so defined global 1 — index 4 —
    cannot read itself. Out of the constrained context's range reads as
    `unknown global`, because in that context it does not exist. }
  ExpectInvalidAtLimit('global.get of the global being defined',
    MSG_UNKNOWN_GLOBAL,
    [$02,
     $7F, $00, $41, $07, $0B,
     $7F, $00, $23, $04, $0B],
    1, UInt32(IMPORTED_GLOBALS + 1));
end;

procedure TValidatorConstTests.TestRejectsGlobalOutsideImportedOnlyScope;
begin
  { The table-initialiser scope: "Constant expressions occurring in tables
    may only have GLOBAL.GET instructions that refer to imported globals"
    (`valid-constant`). The caller expresses that as GlobalLimit = the
    import count, and a defined global then reads as unknown. }
  ExpectInvalidAtLimit('global.get of a defined global under the '
    + 'imports-only scope', MSG_UNKNOWN_GLOBAL,
    [$02,
     $7F, $00, $41, $07, $0B,
     $7F, $00, $23, $03, $0B],
    1, UInt32(IMPORTED_GLOBALS));
end;

procedure TValidatorConstTests.TestRejectsUnknownFunction;
begin
  ExpectInvalid('ref.func past the function index space',
    MSG_UNKNOWN_FUNCTION, [$01, $70, $00, $D2, $09, $0B]);
end;

procedure TValidatorConstTests.TestRejectsUnknownType;
begin
  ExpectInvalid('struct.new of a type index past the type space',
    MSG_UNKNOWN_TYPE, [$01, $6E, $00, $FB, $00, $09, $0B]);
end;

procedure TValidatorConstTests.TestRejectsNonAggregateTypeIndex;
begin
  { Type 0 is a function type, so struct.new cannot name it. }
  ExpectInvalid('struct.new of a function type', MSG_TYPE_MISMATCH,
    [$01, $6E, $00, $FB, $00, $00, $0B]);
end;

{ --- negatives: staged SIMD ---------------------------------------------- }

procedure TValidatorConstTests.TestRejectsSimd;
begin
  { v128.const ($FD 12) IS a constant instruction in the spec
    (`Instr_const/vconst`), so this case is not about constness: SIMD
    typing is staged to Track G and must fail visibly rather than being
    silently accepted. }
  ExpectInvalid('v128.const in a constant expression',
    MSG_SIMD_NOT_IMPLEMENTED,
    [$01, $7B, $00, $FD, $0C,
     $00, $00, $00, $00, $00, $00, $00, $00,
     $00, $00, $00, $00, $00, $00, $00, $00, $0B]);
end;

{ --- registration -------------------------------------------------------- }

procedure TValidatorConstTests.SetupTests;
begin
  Test('t.const for all four numeric types', TestNumericConstants);
  Test('the disassembler line layout is unchanged',
    TestDisassemblyLineLayout);
  Test('an extended-const arithmetic chain',
    TestExtendedConstArithmeticChain);
  Test('extended-const i64 and operand order', TestExtendedConstI64);
  Test('ref.null, abstract and concrete', TestRefNull);
  Test('ref.func records its function index',
    TestRefFuncRecordsItsIndex);
  Test('a non-null concrete funcref satisfies a funcref global',
    TestRefFuncSubsumesFuncref);
  Test('global.get of an imported immutable global',
    TestGlobalGetOfImportedGlobal);
  Test('global.get of a previously defined global',
    TestGlobalGetOfPrecedingDefinedGlobal);
  Test('struct.new with field operands',
    TestStructNewWithFieldOperands);
  Test('struct.new_default over defaultable fields',
    TestStructNewDefault);
  Test('array.new and array.new_default', TestArrayNewAndNewDefault);
  Test('array.new_fixed', TestArrayNewFixed);
  Test('ref.i31', TestRefI31);
  Test('any.convert_extern and extern.convert_any',
    TestExternConversions);
  Test('extern.convert_any does not preserve non-nullability',
    TestExternConvertAnyIsNotNullPreserving);

  Test('rejects nop', TestRejectsNop);
  Test('rejects local.get', TestRejectsLocalGet);
  Test('rejects i32.eqz', TestRejectsI32Eqz);
  Test('rejects a $FC-prefixed instruction',
    TestRejectsMiscPrefixInstruction);
  Test('rejects array.new_data', TestRejectsArrayNewData);
  Test('rejects global.get of a mutable global',
    TestRejectsMutableGlobalGet);
  Test('rejects a result type that does not match',
    TestRejectsWrongResultType);
  Test('rejects an expression yielding no value',
    TestRejectsEmptyExpression);
  Test('rejects an unknown global index', TestRejectsUnknownGlobal);
  Test('rejects a global reading itself', TestRejectsSelfReferencingGlobal);
  Test('rejects a defined global under the imports-only scope',
    TestRejectsGlobalOutsideImportedOnlyScope);
  Test('rejects an unknown function index', TestRejectsUnknownFunction);
  Test('rejects an unknown type index', TestRejectsUnknownType);
  Test('rejects an aggregate instruction on a function type',
    TestRejectsNonAggregateTypeIndex);
  Test('rejects the staged SIMD space', TestRejectsSimd);
end;

begin
  TestRunnerProgram.AddSuite(
    TValidatorConstTests.Create('Wasm.Validator.Const'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
