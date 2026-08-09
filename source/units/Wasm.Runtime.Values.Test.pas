{ Unit suite for Wasm.Runtime.Values.

  Three properties carry the weight here and each has already been the
  shape of a real bug in some engine: the slot is exactly 8 bytes on both
  bitnesses, a narrow write zeroes the whole slot (a stale high half
  would be traced as a pointer by the root scan), and an i31 reference is
  ZERO-extended rather than sign-extended into a 64-bit word (sign
  extension breaks ref.eq between the 32- and 64-bit paths).

  The i31 cases are spelled as literal boundary values next to the
  assertion rather than generated, so the wrap is readable. }
program Wasm.Runtime.Values.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Runtime.Values;

type
  TRuntimeValuesTests = class(TTestSuite)
  private
    FBlock: Pointer;
    FAligned: Pointer;

    { Round-trip through the i31 encoding, signed. }
    function I31RoundTrip(const AValue: Int32): Int32;
  public
    procedure BeforeAll; override;
    procedure AfterAll; override;
    procedure SetupTests; override;

    procedure TestSlotIsEightBytes;
    procedure TestNullIsZeroAndClassifiesAsNull;
    procedure TestI31RoundTripAtBoundaries;
    procedure TestI31WrapsToThirtyOneBits;
    procedure TestI31Unsigned;
    procedure TestI31IsNeverNullOrObject;
    procedure TestI31EncodingIsBitnessIndependent;
    procedure TestObjectRefKeepsLowBitClear;
    procedure TestNarrowWritesZeroTheSlot;
    procedure TestRefWriteZeroExtends;
    procedure TestWideWritesRoundTrip;
    procedure TestZeroSlotsHandlesEmptyRun;
    procedure TestZeroSlotsClearsEveryByte;
    procedure TestDefaultValues;
  end;

function TRuntimeValuesTests.I31RoundTrip(const AValue: Int32): Int32;
begin
  Result := I31GetSigned(MakeI31Ref(AValue));
end;

procedure TRuntimeValuesTests.BeforeAll;
begin
  { Hand-align to 8: the encoding's low-bit tag is only available because
    the GC allocator guarantees this, and the tests must not lean on the
    heap manager happening to do it. }
  FBlock := GetMem(64);
  FAligned := Pointer((NativeUInt(FBlock) + 7) and not NativeUInt(7));
end;

procedure TRuntimeValuesTests.AfterAll;
begin
  FreeMem(FBlock);
  FBlock := nil;
end;

procedure TRuntimeValuesTests.TestSlotIsEightBytes;
begin
  { The frame layout, and therefore the stack-map projection, must be
    bitness-independent. v128 does not live in the slot precisely so this
    stays 8. }
  Expect<Integer>(SizeOf(TWasmValue)).ToBe(8);
end;

procedure TRuntimeValuesTests.TestNullIsZeroAndClassifiesAsNull;
begin
  Expect<Boolean>(WASM_REF_NULL = 0).ToBe(True);
  Expect<Boolean>(RefIsNull(WASM_REF_NULL)).ToBe(True);
  Expect<Boolean>(RefIsI31(WASM_REF_NULL)).ToBe(False);
  { The mark loop's only question. Null is not traceable. }
  Expect<Boolean>(RefIsObject(WASM_REF_NULL)).ToBe(False);
end;

procedure TRuntimeValuesTests.TestI31RoundTripAtBoundaries;
begin
  Expect<Int32>(I31RoundTrip(0)).ToBe(0);
  Expect<Int32>(I31RoundTrip(1)).ToBe(1);
  Expect<Int32>(I31RoundTrip(-1)).ToBe(-1);
  { The signed payload runs -2^30 .. 2^30-1: 31 bits, one of them the
    payload's own sign. }
  Expect<Int32>(I31RoundTrip(1073741823)).ToBe(1073741823);
  Expect<Int32>(I31RoundTrip(-1073741824)).ToBe(-1073741824);
  Expect<Int32>(I31RoundTrip(-1073741823)).ToBe(-1073741823);
end;

procedure TRuntimeValuesTests.TestI31WrapsToThirtyOneBits;
begin
  { ref.i31 wraps its i32 operand to 31 bits. 2^30 is the first value
    that no longer fits and comes back as -2^30. }
  Expect<Int32>(I31RoundTrip(1073741824)).ToBe(-1073741824);
  { 2^31 (as Int32: the minimum) loses its only set bit to the wrap. }
  Expect<Int32>(I31RoundTrip(Low(Int32))).ToBe(0);
  { MaxInt is all 31 low bits set, which reads back as -1. }
  Expect<Int32>(I31RoundTrip(High(Int32))).ToBe(-1);
end;

procedure TRuntimeValuesTests.TestI31Unsigned;
begin
  Expect<UInt32>(I31GetUnsigned(MakeI31Ref(0))).ToBe(0);
  Expect<UInt32>(I31GetUnsigned(MakeI31Ref(1))).ToBe(1);
  { i31.get_u yields the 31 payload bits, zero-extended: -1 reads as
    2^31-1, not as 2^32-1. }
  Expect<UInt32>(I31GetUnsigned(MakeI31Ref(-1))).ToBe(2147483647);
  Expect<UInt32>(I31GetUnsigned(MakeI31Ref(-1073741824))).ToBe(1073741824);
end;

procedure TRuntimeValuesTests.TestI31IsNeverNullOrObject;
var
  Zero: TWasmRef;
begin
  { The one case that could collide with null if the tag bit were not
    set unconditionally. }
  Zero := MakeI31Ref(0);
  Expect<Boolean>(Zero = WASM_REF_NULL).ToBe(False);
  Expect<Boolean>(RefIsNull(Zero)).ToBe(False);
  Expect<Boolean>(RefIsI31(Zero)).ToBe(True);
  { Never traced: an i31 has no header to read. }
  Expect<Boolean>(RefIsObject(Zero)).ToBe(False);
  Expect<Boolean>(RefIsObject(MakeI31Ref(-1))).ToBe(False);
end;

procedure TRuntimeValuesTests.TestI31EncodingIsBitnessIndependent;
var
  Ref: TWasmRef;
begin
  { The encoded word must be the 32-bit form ZERO-extended. Sign
    extension would make the same i31 compare unequal across a 32- and a
    64-bit host, which is exactly what ref.eq cannot tolerate. }
  Ref := MakeI31Ref(-1);
  Expect<UInt64>(UInt64(Ref)).ToBe(UInt64($FFFFFFFF));
  Ref := MakeI31Ref(-1073741824);
  Expect<UInt64>(UInt64(Ref)).ToBe(UInt64($80000001));
  Ref := MakeI31Ref(1);
  Expect<UInt64>(UInt64(Ref)).ToBe(UInt64($00000003));
end;

procedure TRuntimeValuesTests.TestObjectRefKeepsLowBitClear;
var
  Ref: TWasmRef;
begin
  { The whole encoding rests on this: 8-byte object alignment reserves
    bit 0, so a real object pointer never reads back as an i31. }
  Expect<Boolean>((NativeUInt(FAligned) and 7) = 0).ToBe(True);
  Ref := MakeObjectRef(FAligned);
  Expect<Boolean>(RefIsI31(Ref)).ToBe(False);
  Expect<Boolean>(RefIsNull(Ref)).ToBe(False);
  Expect<Boolean>(RefIsObject(Ref)).ToBe(True);
  Expect<Boolean>(RefToPointer(Ref) = FAligned).ToBe(True);
end;

procedure TRuntimeValuesTests.TestNarrowWritesZeroTheSlot;
var
  Slot: TWasmValue;
begin
  { Poison the whole slot, then write narrow. A surviving high half is
    the bug this rule exists to prevent: the root scan reads Ref out of
    the slot and would see a plausible pointer. }
  Slot.Bits := UInt64($DEADBEEFCAFEF00D);
  ValueSetI32(Slot, 1);
  Expect<UInt64>(Slot.Bits).ToBe(1);

  Slot.Bits := UInt64($DEADBEEFCAFEF00D);
  ValueSetU32(Slot, $FFFFFFFF);
  Expect<UInt64>(Slot.Bits).ToBe(UInt64($FFFFFFFF));

  Slot.Bits := UInt64($DEADBEEFCAFEF00D);
  ValueSetI32(Slot, -1);
  { i32 -1 is 0x00000000FFFFFFFF in the slot, not a sign-extended i64. }
  Expect<UInt64>(Slot.Bits).ToBe(UInt64($FFFFFFFF));

  Slot.Bits := UInt64($DEADBEEFCAFEF00D);
  ValueSetF32(Slot, 0.0);
  Expect<UInt64>(Slot.Bits).ToBe(0);

  Slot.Bits := UInt64($DEADBEEFCAFEF00D);
  ValueSetRef(Slot, WASM_REF_NULL);
  Expect<UInt64>(Slot.Bits).ToBe(0);

  { The same rule through the constructors. }
  Expect<UInt64>(MakeValueI32(-1).Bits).ToBe(UInt64($FFFFFFFF));
  Expect<UInt64>(MakeValueNullRef.Bits).ToBe(0);
end;

procedure TRuntimeValuesTests.TestRefWriteZeroExtends;
var
  Slot: TWasmValue;
  Widest: TWasmRef;
begin
  Slot.Bits := UInt64($DEADBEEFCAFEF00D);
  Widest := High(TWasmRef);
  ValueSetRef(Slot, Widest);
  { On a 32-bit host the high half must be zero, not a sign extension —
    the slot stays 8 bytes on both bitnesses and the collector reads the
    low half back as the reference. }
  Expect<UInt64>(Slot.Bits).ToBe(UInt64(Widest));
  Expect<Boolean>(Slot.Ref = Widest).ToBe(True);
end;

procedure TRuntimeValuesTests.TestWideWritesRoundTrip;
var
  Slot: TWasmValue;
begin
  Slot.Bits := 0;
  ValueSetI64(Slot, -1);
  Expect<UInt64>(Slot.Bits).ToBe(High(UInt64));
  Expect<Int64>(Slot.I64).ToBe(-1);

  ValueSetF64(Slot, 1.5);
  Expect<Boolean>(Slot.F64 = 1.5).ToBe(True);

  Slot := MakeValueF32(2.5);
  Expect<Boolean>(Slot.F32 = 2.5).ToBe(True);
  { A narrow float still clears the upper half. }
  Expect<UInt64>(Slot.Bits shr 32).ToBe(0);

  Slot := MakeValueU64(High(UInt64));
  Expect<UInt64>(Slot.U64).ToBe(High(UInt64));
end;

procedure TRuntimeValuesTests.TestZeroSlotsHandlesEmptyRun;
var
  Slots: array[0 .. 1] of TWasmValue;
begin
  Slots[0].Bits := 7;
  { An unsigned `for I := 0 to ACount - 1` with a zero count wraps and
    runs 2^32 times on FPC — the trap this loop is written as a while to
    avoid. If it were still there, this test would hang rather than
    fail, which is why it is spelled out. }
  ValueZeroSlots(@Slots[0], 0);
  Expect<UInt64>(Slots[0].Bits).ToBe(7);
end;

procedure TRuntimeValuesTests.TestZeroSlotsClearsEveryByte;
var
  Slots: array[0 .. 2] of TWasmValue;
begin
  Slots[0].Bits := UInt64($DEADBEEFCAFEF00D);
  Slots[1].Bits := UInt64($DEADBEEFCAFEF00D);
  Slots[2].Bits := UInt64($DEADBEEFCAFEF00D);
  { Contract GC-1: a frame is zeroed at entry, because an unwritten ref
    slot must read as null. }
  ValueZeroSlots(@Slots[0], 3);
  Expect<UInt64>(Slots[0].Bits).ToBe(0);
  Expect<UInt64>(Slots[1].Bits).ToBe(0);
  Expect<UInt64>(Slots[2].Bits).ToBe(0);
  Expect<Boolean>(RefIsNull(Slots[1].Ref)).ToBe(True);
end;

procedure TRuntimeValuesTests.TestDefaultValues;
var
  Value: TWasmValue;
  RefType: TWasmRefType;
begin
  Value.Bits := UInt64($DEADBEEFCAFEF00D);
  Expect<Boolean>(TryDefaultValue(MakeNumValueType(wntI32), Value)).ToBe(True);
  Expect<UInt64>(Value.Bits).ToBe(0);

  Value.Bits := UInt64($DEADBEEFCAFEF00D);
  Expect<Boolean>(TryDefaultValue(MakeVecValueType, Value)).ToBe(True);
  Expect<UInt64>(Value.Bits).ToBe(0);

  RefType.Nullable := True;
  RefType.Heap := MakeAbsHeapType(wahAny);
  Value.Bits := UInt64($DEADBEEFCAFEF00D);
  Expect<Boolean>(TryDefaultValue(MakeRefValueType(RefType), Value)).ToBe(True);
  Expect<Boolean>(RefIsNull(Value.Ref)).ToBe(True);

  { "For other references, no default value is defined" (aux-default).
    The validator has already made this unreachable at run time; the
    runtime reports it rather than inventing a value. }
  RefType.Nullable := False;
  Expect<Boolean>(TryDefaultValue(MakeRefValueType(RefType), Value)).ToBe(False);
end;

procedure TRuntimeValuesTests.SetupTests;
begin
  Test('the value slot is exactly eight bytes', TestSlotIsEightBytes);
  Test('null is zero and classifies as null',
    TestNullIsZeroAndClassifiesAsNull);
  Test('i31 round-trips at the payload boundaries',
    TestI31RoundTripAtBoundaries);
  Test('ref.i31 wraps its operand to 31 bits',
    TestI31WrapsToThirtyOneBits);
  Test('i31.get_u yields the 31 payload bits', TestI31Unsigned);
  Test('an i31 is never null and never traceable',
    TestI31IsNeverNullOrObject);
  Test('the i31 encoding is zero-extended, not sign-extended',
    TestI31EncodingIsBitnessIndependent);
  Test('an object reference keeps its low bit clear',
    TestObjectRefKeepsLowBitClear);
  Test('narrow writes zero the whole slot', TestNarrowWritesZeroTheSlot);
  Test('a reference write zero-extends into the slot',
    TestRefWriteZeroExtends);
  Test('wide writes round-trip', TestWideWritesRoundTrip);
  Test('zeroing an empty run of slots terminates',
    TestZeroSlotsHandlesEmptyRun);
  Test('zeroing a run clears every byte', TestZeroSlotsClearsEveryByte);
  Test('default values follow aux-default', TestDefaultValues);
end;

begin
  TestRunnerProgram.AddSuite(TRuntimeValuesTests.Create('Wasm.Runtime.Values'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
