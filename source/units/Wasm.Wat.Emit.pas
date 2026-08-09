{ Wasm.Wat.Emit — the binary emitter: a growable byte buffer, the LEB128
  writers, the type/limits/composite encoders, and the section builder
  with size backpatching.

  This is the INVERSE of the decode layer. Every encoder here mirrors a
  reader in Wasm.Binary / Wasm.Decoder.Common / Wasm.Decoder.Types, and
  the Track C differential test proves the inversion by feeding this unit's
  output straight back through DecodeModule and comparing the model — no
  grammar required (.agent/design/wat-assembler.md §2(e), §6).

  Two rules run through the whole unit and both come from the decoder
  being our oracle:

    1. Every LEB128 encoding is CANONICAL — the shortest that spells the
       value. Wasm.Binary rejects an overlong uN/sN as `integer
       representation too long`, so emitting a padded LEB would be
       emitting bytes we ourselves reject. The unsigned writer stops at
       the first all-clear high bit; the signed writer stops as soon as
       the remaining value is a pure sign extension.

    2. Type codes are SIGNED LEB128 small negatives, NOT raw bytes — the
       mistake AGENTS.md records as already shipped once. A value type is
       written through WriteSigned of its Wasm.Core code (wntI32 = -1 …),
       which produces the same single byte a hex dump shows ($7F for i32)
       while keeping the encoding honest. The literal form bytes that ARE
       single-byte grammar productions (the $63/$64 reference markers, the
       $4E/$4F/$50 rec/sub markers, the $5E/$5F/$60 composite markers, the
       $77/$78 packed markers) are written as bytes, exactly as the
       decoder peeks them.

  Section framing uses build-then-prefix, never reserve-and-backpatch: a
  section body is built into its own buffer, then emitted as
  [id][u32 length][body] with the length computed from the finished body
  (.agent/design/wat-assembler.md §2(e)). A padded five-byte length LEB
  would again be the over-long encoding the decoder rejects, so the extra
  copy on this cold path is the honest choice. The name section is
  deliberately NOT emitted (§2(e)): it is custom, so no conformance
  verdict depends on it.

  Depends only on Wasm.Core, per the unit layout in §6. }
unit Wasm.Wat.Emit;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

type
  { A growable output buffer, the mirror image of Wasm.Binary's
    TWasmReader. Like the reader it is a record over a raw dynamic array
    with amortised geometric growth and a live count distinct from the
    backing capacity, so appending N bytes is O(N) total rather than
    per-byte reallocation. Methods mutate in place — a record method
    receives Self by reference — so a `var TWasmWriter` threads through
    the section builders the way `var TWasmReader` threads through the
    decoders. }
  TWasmWriter = record
  private
    FData: TWasmBytes;
    FCount: NativeUInt;

    procedure EnsureRoom(const AExtra: NativeUInt);
  public
    { Zeroes the live count and drops any backing storage. A freshly
      declared TWasmWriter must be Init'd before first use, exactly like
      a reader. }
    procedure Init;

    function Count: NativeUInt; inline;

    { --- raw output ------------------------------------------------------ }
    procedure WriteByte(const AValue: Byte);
    { An open-array literal, for the hand-built bytes tests and any caller
      that already has a fixed sequence. }
    procedure WriteRawBytes(const AValues: array of Byte);
    { Appends a whole finished buffer's worth of bytes — the section
      builder uses this to splice a body in after its header. }
    procedure AppendBytes(const ABytes: TWasmBytes);

    { --- LEB128, canonical (shortest) ------------------------------------ }
    procedure WriteU32(const AValue: UInt32);
    procedure WriteU64(const AValue: UInt64);
    procedure WriteS32(const AValue: Int32);
    procedure WriteS64(const AValue: Int64);
    { s33, the width the format uses where a type index and a negative
      type code share a position (heap types, block types). Non-negative
      indices up to 2^32-1 fit and encode as a positive signed integer. }
    procedure WriteS33(const AValue: Int64);

    { Fixed 4-byte little-endian, as the module preamble's version field
      and every spec-`uN` fixed immediate use. }
    procedure WriteFixedU32(const AValue: UInt32);

    { --- type encoders (mirror Wasm.Decoder.Common / .Types) ------------- }
    procedure WriteValueType(const AType: TWasmValueType);
    procedure WriteHeapType(const AHeap: TWasmHeapType);
    procedure WriteRefType(const ARef: TWasmRefType);
    procedure WriteLimits(const ALimits: TWasmLimits);
    procedure WriteGlobalType(const AType: TWasmGlobalType);
    procedure WriteMemType(const AType: TWasmMemType);
    procedure WriteTableType(const AType: TWasmTableType);
    procedure WriteTagType(const AType: TWasmTagType);

    { The empty block type ($40). The value-type and type-index block
      forms are just WriteValueType / WriteS33 — a block type is one of
      those three productions (binary-blocktype). }
    procedure WriteEmptyBlockType;

    { --- composite type forms (mirror Wasm.Decoder.Types) ---------------- }
    procedure WriteStorageType(const AType: TWasmStorageType);
    procedure WriteFieldType(const AType: TWasmFieldType);
    procedure WriteCompType(const AType: TWasmCompType);
    procedure WriteSubType(const AType: TWasmSubType);
    { One type-section entry. A single-member group is written as the bare
      shorthand (no $4E), matching how the decoder normalises a bare
      subtype into a group of one; a group of zero or two-plus members is
      written explicitly as $4E vec(subtype). }
    procedure WriteType(const AType: TWasmRecType);

    { The trimmed live bytes, copied out. }
    function ToBytes: TWasmBytes;
  end;

  { Collects section bodies and emits a whole module: the preamble, then
    the sections in the grammar's PRESCRIBED order regardless of the order
    they were added (Wasm.Core.SectionOrderPosition — which is NOT id
    order). Text field order is free but section order is fixed, so this
    is where the "scramble the fields, assemble, decode, assert the
    section table" invariant is enforced (.agent/design/wat-assembler.md
    §2(e)). }
  TWasmModuleEmitter = class
  private
    FIds: array of Byte;
    FBodies: array of TWasmBytes;
  public
    { Appends a section body under AId. The body is the section CONTENT
      (the id byte and the length prefix are added at Finish); it is
      copied, so the caller's buffer may be reused afterwards. Custom
      sections (id 0) are permitted and keep their relative order. }
    procedure AddSection(const AId: TWasmSectionId; const ABody: TWasmBytes);
    function SectionCount: Integer;
    { The finished module bytes: preamble + framed sections in prescribed
      order. }
    function Finish: TWasmBytes;
  end;

{ Writes the eight-byte preamble: the magic then the fixed little-endian
  version. }
procedure WritePreamble(var AOut: TWasmWriter);

{ Frames one section: the id byte, the body length as a u32 LEB128, then
  the body. The length is the finished body's byte count — build-then-
  prefix, so the length LEB is canonical rather than padded. }
procedure WriteSection(var AOut: TWasmWriter; const AId: TWasmSectionId;
  const ABody: TWasmBytes);

implementation

const
  { The long-form reference markers, the rec/sub form codes, the
    composite form codes, and the packed storage codes — all LITERAL
    single bytes in the grammar, matched by the decoder with a peek before
    any LEB decoding. Their signed-space values live in Wasm.Core
    (TYPE_CODE_REF_NULL = -29 spells $63, and so on); these are the byte
    spellings, needed here for the same reason Wasm.Decoder.Common and
    Wasm.Decoder.Types keep their own BYTE_* copies. }
  BYTE_REF_NULL  = $63;  { TYPE_CODE_REF_NULL  = -29 }
  BYTE_REF       = $64;  { TYPE_CODE_REF       = -28 }
  BYTE_REC       = $4E;  { TYPE_CODE_REC       = -50 }
  BYTE_SUB_FINAL = $4F;  { TYPE_CODE_SUB_FINAL = -49 }
  BYTE_SUB       = $50;  { TYPE_CODE_SUB       = -48 }
  BYTE_ARRAY     = $5E;  { TYPE_CODE_ARRAY     = -34 }
  BYTE_STRUCT    = $5F;  { TYPE_CODE_STRUCT    = -33 }
  BYTE_FUNC      = $60;  { TYPE_CODE_FUNC      = -32 }
  BYTE_I16       = $77;  { TYPE_CODE_I16       = -9  }
  BYTE_I8        = $78;  { TYPE_CODE_I8        = -8  }

  { The empty block type production (binary-blocktype). }
  BYTE_EMPTY_BLOCKTYPE = $40;

  { Limits flag bits, the exact pair Wasm.Decoder.Common.ReadLimits
    assigns meaning to: bit 0 = max present, bit 2 = 64-bit address type.
    No other bit is assigned in the 3.0 grammar. }
  LIMITS_FLAG_HAS_MAX = $01;
  LIMITS_FLAG_ADDR64  = $04;

{ --- TWasmWriter -------------------------------------------------------- }

procedure TWasmWriter.Init;
begin
  FData := nil;
  FCount := 0;
end;

function TWasmWriter.Count: NativeUInt;
begin
  Result := FCount;
end;

procedure TWasmWriter.EnsureRoom(const AExtra: NativeUInt);
var
  NewCap: NativeUInt;
begin
  if FCount + AExtra <= NativeUInt(Length(FData)) then
    Exit;
  NewCap := NativeUInt(Length(FData));
  if NewCap = 0 then
    NewCap := 16;
  while NewCap < FCount + AExtra do
    NewCap := NewCap * 2;
  SetLength(FData, NewCap);
end;

procedure TWasmWriter.WriteByte(const AValue: Byte);
begin
  EnsureRoom(1);
  FData[FCount] := AValue;
  Inc(FCount);
end;

procedure TWasmWriter.WriteRawBytes(const AValues: array of Byte);
begin
  if Length(AValues) = 0 then
    Exit;
  EnsureRoom(NativeUInt(Length(AValues)));
  Move(AValues[0], FData[FCount], Length(AValues));
  Inc(FCount, NativeUInt(Length(AValues)));
end;

procedure TWasmWriter.AppendBytes(const ABytes: TWasmBytes);
begin
  if Length(ABytes) = 0 then
    Exit;
  EnsureRoom(NativeUInt(Length(ABytes)));
  Move(ABytes[0], FData[FCount], Length(ABytes));
  Inc(FCount, NativeUInt(Length(ABytes)));
end;

{ Unsigned LEB128, shortest form: seven bits per byte, low first, the
  high bit set on every byte but the last. Terminating at `Value = 0`
  yields exactly ceil(bits/7)-or-fewer bytes with no trailing padding —
  the encoding Wasm.Binary accepts and its overlong sibling it rejects.
  https://webassembly.github.io/spec/core/binary/values.html#binary-int }
procedure WriteUnsigned(var AOut: TWasmWriter; AValue: UInt64);
var
  B: Byte;
begin
  repeat
    B := Byte(AValue and $7F);
    AValue := AValue shr 7;
    if AValue <> 0 then
      B := B or $80;
    AOut.WriteByte(B);
  until AValue = 0;
end;

{ Signed LEB128, shortest form. The loop stops once the remaining value
  is a pure sign extension of the byte just emitted: 0 with the byte's
  sign bit (bit 6) clear, or -1 with it set. The arithmetic right shift
  by 7 is done as a floor division, because FPC's `shr` on a signed
  operand is logical and would drag zeros into the high bits of a
  negative value; `div` truncates toward zero, so the negative,
  non-exact case is nudged down by one to match a true arithmetic shift.
  https://webassembly.github.io/spec/core/binary/values.html#binary-int }
procedure WriteSigned(var AOut: TWasmWriter; AValue: Int64);
var
  B: Byte;
  Next: Int64;
  More: Boolean;
begin
  repeat
    B := Byte(AValue and $7F);
    Next := AValue div 128;
    if (AValue < 0) and ((AValue mod 128) <> 0) then
      Dec(Next);
    More := not (((Next = 0) and ((B and $40) = 0))
                 or ((Next = -1) and ((B and $40) <> 0)));
    if More then
      B := B or $80;
    AOut.WriteByte(B);
    AValue := Next;
  until not More;
end;

procedure TWasmWriter.WriteU32(const AValue: UInt32);
begin
  WriteUnsigned(Self, AValue);
end;

procedure TWasmWriter.WriteU64(const AValue: UInt64);
begin
  WriteUnsigned(Self, AValue);
end;

procedure TWasmWriter.WriteS32(const AValue: Int32);
begin
  WriteSigned(Self, AValue);
end;

procedure TWasmWriter.WriteS64(const AValue: Int64);
begin
  WriteSigned(Self, AValue);
end;

procedure TWasmWriter.WriteS33(const AValue: Int64);
begin
  WriteSigned(Self, AValue);
end;

procedure TWasmWriter.WriteFixedU32(const AValue: UInt32);
begin
  WriteByte(Byte(AValue));
  WriteByte(Byte(AValue shr 8));
  WriteByte(Byte(AValue shr 16));
  WriteByte(Byte(AValue shr 24));
end;

procedure TWasmWriter.WriteValueType(const AType: TWasmValueType);
begin
  { Number types and v128 are their negative Wasm.Core codes written as
    signed LEB (a single byte for these), never raw bytes. Reference
    types dispatch to their own encoder. }
  case AType.Kind of
    wvkNum: WriteSigned(Self, Ord(AType.Num));
    wvkVec: WriteSigned(Self, TYPE_CODE_V128);
    wvkRef: WriteRefType(AType.Ref);
  end;
end;

procedure TWasmWriter.WriteHeapType(const AHeap: TWasmHeapType);
begin
  { An abstract heap type is its negative code (single-byte sLEB); a
    concrete one is its non-negative type index as an s33. }
  if AHeap.IsAbstract then
    WriteSigned(Self, Ord(AHeap.Abs))
  else
    WriteS33(Int64(AHeap.TypeIndex));
end;

procedure TWasmWriter.WriteRefType(const ARef: TWasmRefType);
begin
  { The short form — a bare abstract heap-type byte — exists only for the
    nullable abstract case, and that is the canonical spelling the decoder
    reads back as (nullable, abstract). Everything else takes a long-form
    $63/$64 marker plus a heap type. }
  if ARef.Nullable and ARef.Heap.IsAbstract then
    WriteSigned(Self, Ord(ARef.Heap.Abs))
  else
  begin
    if ARef.Nullable then
      WriteByte(BYTE_REF_NULL)
    else
      WriteByte(BYTE_REF);
    WriteHeapType(ARef.Heap);
  end;
end;

procedure TWasmWriter.WriteLimits(const ALimits: TWasmLimits);
var
  Flags: Byte;
begin
  { Exactly the four flag values ReadLimits accepts, built from the same
    two bits. Min and Max are u64 for BOTH address types — the encoding
    never narrows to the address width, and neither does this. }
  Flags := 0;
  if ALimits.HasMax then
    Flags := Flags or LIMITS_FLAG_HAS_MAX;
  if ALimits.AddrType = watI64 then
    Flags := Flags or LIMITS_FLAG_ADDR64;
  WriteByte(Flags);
  WriteU64(ALimits.Min);
  if ALimits.HasMax then
    WriteU64(ALimits.Max);
end;

procedure TWasmWriter.WriteGlobalType(const AType: TWasmGlobalType);
begin
  { Value type first, then the mutability byte — the order ReadGlobalType
    reads them in. }
  WriteValueType(AType.ValueType);
  WriteByte(Ord(AType.Mut));
end;

procedure TWasmWriter.WriteMemType(const AType: TWasmMemType);
begin
  WriteLimits(AType.Limits);
end;

procedure TWasmWriter.WriteTableType(const AType: TWasmTableType);
begin
  { Element reference type first, then limits — the reverse of how the
    text format spells it, matching ReadTableType. }
  WriteRefType(AType.RefType);
  WriteLimits(AType.Limits);
end;

procedure TWasmWriter.WriteTagType(const AType: TWasmTagType);
begin
  { The attribute byte ($00 is the only assigned value) then the function
    type index. }
  WriteByte($00);
  WriteU32(AType.TypeIndex);
end;

procedure TWasmWriter.WriteEmptyBlockType;
begin
  WriteByte(BYTE_EMPTY_BLOCKTYPE);
end;

procedure TWasmWriter.WriteStorageType(const AType: TWasmStorageType);
begin
  { A packed storage type is its literal byte ($78 i8 / $77 i16); anything
    else is a value type. I16 is the LOWER byte of the two. }
  if AType.IsPacked then
  begin
    if AType.PackedType = wpkI8 then
      WriteByte(BYTE_I8)
    else
      WriteByte(BYTE_I16);
  end
  else
    WriteValueType(AType.ValueType);
end;

procedure TWasmWriter.WriteFieldType(const AType: TWasmFieldType);
begin
  { Storage first, then the mutability byte — same order as globaltype. }
  WriteStorageType(AType.Storage);
  WriteByte(Ord(AType.Mut));
end;

procedure TWasmWriter.WriteCompType(const AType: TWasmCompType);
var
  I: Integer;
begin
  { The form byte ($60 func / $5F struct / $5E array) then the shape. }
  case AType.Kind of
    wckFunc:
      begin
        WriteByte(BYTE_FUNC);
        WriteU32(UInt32(Length(AType.Func.Params)));
        for I := 0 to High(AType.Func.Params) do
          WriteValueType(AType.Func.Params[I]);
        WriteU32(UInt32(Length(AType.Func.Results)));
        for I := 0 to High(AType.Func.Results) do
          WriteValueType(AType.Func.Results[I]);
      end;
    wckStruct:
      begin
        WriteByte(BYTE_STRUCT);
        WriteU32(UInt32(Length(AType.Struct.Fields)));
        for I := 0 to High(AType.Struct.Fields) do
          WriteFieldType(AType.Struct.Fields[I]);
      end;
    wckArray:
      begin
        WriteByte(BYTE_ARRAY);
        WriteFieldType(AType.Arr.Elem);
      end;
  end;
end;

procedure TWasmWriter.WriteSubType(const AType: TWasmSubType);
var
  I: Integer;
begin
  { A final subtype with no declared supertypes is the bare-comptype
    shorthand ReadSubType normalises from — write it with no marker.
    Otherwise the explicit form: $4F (final) or $50 (non-final), a
    vec(typeidx) of supertypes, then the comptype. $4F is the FINAL
    marker — the lower byte, the easy pair to transpose. }
  if AType.IsFinal and (Length(AType.SuperTypes) = 0) then
    WriteCompType(AType.Comp)
  else
  begin
    if AType.IsFinal then
      WriteByte(BYTE_SUB_FINAL)
    else
      WriteByte(BYTE_SUB);
    WriteU32(UInt32(Length(AType.SuperTypes)));
    for I := 0 to High(AType.SuperTypes) do
      WriteU32(AType.SuperTypes[I]);
    WriteCompType(AType.Comp);
  end;
end;

procedure TWasmWriter.WriteType(const AType: TWasmRecType);
var
  I: Integer;
begin
  { One member → the bare-subtype shorthand (decoded back as a group of
    one). Zero or many → the explicit $4E vec(subtype) group; an empty
    group is $4E $00, which the grammar admits. }
  if Length(AType.SubTypes) = 1 then
    WriteSubType(AType.SubTypes[0])
  else
  begin
    WriteByte(BYTE_REC);
    WriteU32(UInt32(Length(AType.SubTypes)));
    for I := 0 to High(AType.SubTypes) do
      WriteSubType(AType.SubTypes[I]);
  end;
end;

function TWasmWriter.ToBytes: TWasmBytes;
begin
  SetLength(Result, FCount);
  if FCount > 0 then
    Move(FData[0], Result[0], FCount);
end;

{ --- section framing and the module emitter ---------------------------- }

procedure WritePreamble(var AOut: TWasmWriter);
var
  I: Integer;
begin
  for I := 0 to High(WASM_MAGIC) do
    AOut.WriteByte(WASM_MAGIC[I]);
  AOut.WriteFixedU32(WASM_BINARY_VERSION);
end;

procedure WriteSection(var AOut: TWasmWriter; const AId: TWasmSectionId;
  const ABody: TWasmBytes);
begin
  AOut.WriteByte(Ord(AId));
  AOut.WriteU32(UInt32(Length(ABody)));
  AOut.AppendBytes(ABody);
end;

procedure TWasmModuleEmitter.AddSection(const AId: TWasmSectionId;
  const ABody: TWasmBytes);
var
  N: Integer;
begin
  N := Length(FIds);
  SetLength(FIds, N + 1);
  SetLength(FBodies, N + 1);
  FIds[N] := Ord(AId);
  FBodies[N] := Copy(ABody, 0, Length(ABody));
end;

function TWasmModuleEmitter.SectionCount: Integer;
begin
  Result := Length(FIds);
end;

function TWasmModuleEmitter.Finish: TWasmBytes;
var
  Buf: TWasmWriter;
  Pos, I: Integer;
begin
  Buf.Init;
  WritePreamble(Buf);

  { A stable sort by prescribed position: for each position in ascending
    order, emit the added sections at that position in insertion order.
    Custom sections share position 0 and so keep their relative order and
    lead; the decoder places custom sections anywhere, so leading is
    legal. Position 13 (data) is the maximum. }
  for Pos := 0 to 13 do
    for I := 0 to High(FIds) do
      if SectionOrderPosition(FIds[I]) = Pos then
        WriteSection(Buf, TWasmSectionId(FIds[I]), FBodies[I]);

  Result := Buf.ToBytes;
end;

end.
