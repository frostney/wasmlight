{ Wasm.Runtime.Values — the 8-byte untagged runtime value slot and the
  reference encoding every other runtime unit reads.

  Two decisions live here and nothing else in the runtime may relitigate
  them.

  (1) TWasmValue carries NO discriminator. The type of register i is
  TWasmIrFunction.RegTypes[i], statically, and the collector learns
  "slot i is a reference" from RefRegBits — a projection of the same
  table (ADR-0011). A tag field would be the runtime type information
  ADR-0011 exists to avoid.

  (2) `Bits` is the canonical raw view, so every NARROW write zeroes the
  whole slot. This is not cosmetic: the root scan reads `Ref` out of a
  slot, and a stale high half left by an earlier i64 store in the same
  register would be traced as a pointer. The setters below do it with a
  single widening store where the compiler can, and it is unconditional.

  The reference encoding is pointer-or-i31, low-bit tagged:

      value = 0        -> null
      value and 1 = 1  -> unboxed i31, payload in bits 1..31
      otherwise        -> pointer to a GC heap object header

  31 payload bits plus one tag bit is exactly 32, so an i31 reference is
  byte-identical on both bitnesses: the 64-bit form ZERO-extends the
  32-bit word. Sign-extending instead would break ref.eq across the two
  paths, which is why MakeI31Ref goes through UInt32 explicitly.

  The one tag bit is affordable because the GC heap aligns every object
  to 8 bytes, so bit 0 of a real object pointer is always clear. That is
  an allocator invariant, not a preference — MakeObjectRef asserts it in
  non-PRODUCTION builds.

  Reference types are "opaque, meaning that neither their size nor their
  bit pattern can be observed" (syntax-reftype), which is what makes any
  of this the runtime's business rather than the spec's.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004).
  Anchors: syntax-num ("scalar references, containing a 31-bit integer"),
  syntax-reftype, valid-ref.cast, ref.i31 / i31.get_s / i31.get_u
  (instruction_get). }
unit Wasm.Runtime.Values;

{$I Shared.inc}

interface

uses
  Wasm.Core;

type
  { A reference value. NativeUInt because it is a tagged machine word:
    4 bytes on a 32-bit host, 8 on a 64-bit one. The slot holding it
    stays 8 bytes regardless, so the frame layout — and therefore the
    stack-map projection — is bitness-independent. }
  TWasmRef = NativeUInt;

  { The interpreter frame slot. A frame is `array of TWasmValue` of
    length TWasmIrFunction.RegisterCount.

    Exactly 8 bytes. v128 needs 16 and deliberately does NOT live here:
    widening every slot would double frame memory traffic for the
    functions that have no vector register at all. Track G owns that
    decision; what is fixed here is that the record stays 8 bytes and
    that widening it later touches this record plus the frame allocator,
    never the store. }
  TWasmValue = record
    case Integer of
      0: (I32: Int32);
      1: (U32: UInt32);
      2: (I64: Int64);
      3: (U64: UInt64);
      4: (F32: Single);
      5: (F64: Double);
      6: (Ref: TWasmRef);
      7: (Bits: UInt64);
  end;

  PWasmValue = ^TWasmValue;

const
  { Null is nil. Safe despite REF.NULL carrying a heap type because
    valid-ref.cast types the operand at a supertype rt' of the target —
    "the liberty to pick a supertype rt' allows typing the instruction
    with the least precise super type of rt as input, that is, the top
    type in the corresponding heap subtyping hierarchy". Validation has
    therefore already pinned the hierarchy, so casting a null reduces to
    "does the target reftype admit null", a static property of the
    target. ref.eq is restricted to eqref, so nulls from two different
    hierarchies are never comparable.

    UNCONFIRMED — that no 3.0 instruction distinguishes nulls of
    different hierarchies at run time. The argument is complete over the
    instructions Track B emits; Track C's assert_return corpus on
    ref_null / ref_cast / ref_test settles it. If it falls the fix is
    local: widen null into four reserved non-pointer constants, and the
    null test below becomes a range test rather than an equality. }
  WASM_REF_NULL = TWasmRef(0);

  { The i31 tag. Exactly one bit, exactly one hierarchy. A second tag bit
    anywhere in the runtime reopens ADR-0011. }
  WASM_REF_I31_TAG = TWasmRef(1);

  { Every GC heap object is 8-byte aligned, which is what reserves bit 0
    of an object pointer. }
  WASM_GC_ALIGNMENT = 8;

{ --- reference predicates ------------------------------------------- }

function RefIsNull(const ARef: TWasmRef): Boolean; inline;
function RefIsI31(const ARef: TWasmRef): Boolean; inline;

{ True for a reference the collector must trace: non-null and not an
  unboxed i31. This is the only test the mark loop needs. }
function RefIsObject(const ARef: TWasmRef): Boolean; inline;

{ --- i31 ------------------------------------------------------------- }

{ ref.i31: the required wrap to 31 bits is the masking, and the shl
  discards nothing else. Zero-extended into TWasmRef on 64-bit hosts. }
function MakeI31Ref(const AValue: Int32): TWasmRef; inline;

{ i31.get_s — arithmetic, sign bit is bit 30 of the payload. }
function I31GetSigned(const ARef: TWasmRef): Int32; inline;

{ i31.get_u — the 31 payload bits, zero-extended. }
function I31GetUnsigned(const ARef: TWasmRef): UInt32; inline;

{ --- object references ----------------------------------------------- }

{ Wrap a GC heap object pointer. A raw HOST pointer is not a valid
  TWasmRef and must never come through here: its low bit may be set and
  the collector cannot trace it. Host values are boxed in a wokHostBox
  heap object instead. }
function MakeObjectRef(const APointer: Pointer): TWasmRef; inline;
function RefToPointer(const ARef: TWasmRef): Pointer; inline;

{ --- slot constructors ----------------------------------------------- }

function MakeValueI32(const AValue: Int32): TWasmValue; inline;
function MakeValueU32(const AValue: UInt32): TWasmValue; inline;
function MakeValueI64(const AValue: Int64): TWasmValue; inline;
function MakeValueU64(const AValue: UInt64): TWasmValue; inline;
function MakeValueF32(const AValue: Single): TWasmValue; inline;
function MakeValueF64(const AValue: Double): TWasmValue; inline;
function MakeValueRef(const AValue: TWasmRef): TWasmValue; inline;
function MakeValueNullRef: TWasmValue; inline;

{ --- in-place slot writes -------------------------------------------- }

{ The narrow forms zero the slot. Do not bypass them by assigning a
  variant field directly on a slot that may be reused. }
procedure ValueSetI32(var ASlot: TWasmValue; const AValue: Int32); inline;
procedure ValueSetU32(var ASlot: TWasmValue; const AValue: UInt32); inline;
procedure ValueSetF32(var ASlot: TWasmValue; const AValue: Single); inline;
procedure ValueSetRef(var ASlot: TWasmValue; const AValue: TWasmRef); inline;
procedure ValueSetI64(var ASlot: TWasmValue; const AValue: Int64); inline;
procedure ValueSetF64(var ASlot: TWasmValue; const AValue: Double); inline;

{ Zero a run of slots. Contract GC-1 requires a frame to be zeroed at
  entry: an unwritten ref slot must read as null, because an unzeroed
  slot is indistinguishable from a live reference. }
procedure ValueZeroSlots(const ASlots: PWasmValue; const ACount: NativeUInt);

{ The value aux-default gives a defaultable value type: zero for numbers
  and vectors, null for a nullable reference. "For other references, no
  default value is defined" — a non-nullable type has none, which the
  validator has already made unreachable here, so this reports it rather
  than inventing one.
  https://webassembly.github.io/spec/core/exec/runtime.html#aux-default }
function TryDefaultValue(const AType: TWasmValueType;
  out AValue: TWasmValue): Boolean;

implementation

function RefIsNull(const ARef: TWasmRef): Boolean;
begin
  Result := ARef = WASM_REF_NULL;
end;

function RefIsI31(const ARef: TWasmRef): Boolean;
begin
  Result := (ARef and WASM_REF_I31_TAG) <> 0;
end;

function RefIsObject(const ARef: TWasmRef): Boolean;
begin
  Result := (ARef <> WASM_REF_NULL) and ((ARef and WASM_REF_I31_TAG) = 0);
end;

function MakeI31Ref(const AValue: Int32): TWasmRef;
begin
  { Mask to 31 bits FIRST so the shift can never leave the UInt32 range;
    the mask is also ref.i31's required wrap, so it is not defensive. }
  Result := TWasmRef(UInt32(((UInt32(AValue) and $7FFFFFFF) shl 1) or 1));
end;

function I31GetSigned(const ARef: TWasmRef): Int32;
var
  Payload: UInt32;
begin
  Payload := UInt32(ARef) shr 1;
  { Bit 30 is the payload's sign bit; extend it by hand rather than
    relying on an arithmetic-shift intrinsic, which is not spelled the
    same way across FPC targets. }
  if (Payload and $40000000) <> 0 then
    Result := Int32(Payload or $80000000)
  else
    Result := Int32(Payload);
end;

function I31GetUnsigned(const ARef: TWasmRef): UInt32;
begin
  Result := UInt32(ARef) shr 1;
end;

function MakeObjectRef(const APointer: Pointer): TWasmRef;
begin
  {$IFNDEF PRODUCTION}
  { The allocator's 8-byte alignment is what makes the low bit a tag.
    A pointer that violates it would be read back as an i31. }
  Assert((NativeUInt(APointer) and (WASM_GC_ALIGNMENT - 1)) = 0,
    'GC object pointer is not 8-byte aligned');
  {$ENDIF}
  Result := TWasmRef(APointer);
end;

function RefToPointer(const ARef: TWasmRef): Pointer;
begin
  Result := Pointer(ARef);
end;

function MakeValueI32(const AValue: Int32): TWasmValue;
begin
  { One widening store: writing Bits covers the whole slot, so there is
    no separate zeroing step to forget. }
  Result.Bits := UInt64(UInt32(AValue));
end;

function MakeValueU32(const AValue: UInt32): TWasmValue;
begin
  Result.Bits := UInt64(AValue);
end;

function MakeValueI64(const AValue: Int64): TWasmValue;
begin
  Result.I64 := AValue;
end;

function MakeValueU64(const AValue: UInt64): TWasmValue;
begin
  Result.U64 := AValue;
end;

function MakeValueF32(const AValue: Single): TWasmValue;
begin
  Result.Bits := 0;
  Result.F32 := AValue;
end;

function MakeValueF64(const AValue: Double): TWasmValue;
begin
  Result.F64 := AValue;
end;

function MakeValueRef(const AValue: TWasmRef): TWasmValue;
begin
  { UInt64(NativeUInt) zero-extends on a 32-bit host, which is the whole
    point: the high half must be zero, not a sign extension. }
  Result.Bits := UInt64(AValue);
end;

function MakeValueNullRef: TWasmValue;
begin
  Result.Bits := 0;
end;

procedure ValueSetI32(var ASlot: TWasmValue; const AValue: Int32);
begin
  ASlot.Bits := UInt64(UInt32(AValue));
end;

procedure ValueSetU32(var ASlot: TWasmValue; const AValue: UInt32);
begin
  ASlot.Bits := UInt64(AValue);
end;

procedure ValueSetF32(var ASlot: TWasmValue; const AValue: Single);
begin
  ASlot.Bits := 0;
  ASlot.F32 := AValue;
end;

procedure ValueSetRef(var ASlot: TWasmValue; const AValue: TWasmRef);
begin
  ASlot.Bits := UInt64(AValue);
end;

procedure ValueSetI64(var ASlot: TWasmValue; const AValue: Int64);
begin
  ASlot.I64 := AValue;
end;

procedure ValueSetF64(var ASlot: TWasmValue; const AValue: Double);
begin
  ASlot.F64 := AValue;
end;

procedure ValueZeroSlots(const ASlots: PWasmValue; const ACount: NativeUInt);
var
  Index: NativeUInt;
  Slot: PWasmValue;
begin
  Slot := ASlots;
  Index := 0;
  { NativeUInt counter, so the loop is written as a while: `for I := 0 to
    ACount - 1` with an unsigned zero count wraps and runs 2^32 times. }
  while Index < ACount do
  begin
    Slot^.Bits := 0;
    Inc(Slot);
    Inc(Index);
  end;
end;

function TryDefaultValue(const AType: TWasmValueType;
  out AValue: TWasmValue): Boolean;
begin
  AValue.Bits := 0;
  case AType.Kind of
    wvkNum, wvkVec:
      Result := True;
    wvkRef:
      Result := AType.Ref.Nullable;
  else
    Result := False;
  end;
end;

end.
