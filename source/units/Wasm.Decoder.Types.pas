{ Wasm.Decoder.Types — the type section decoder: vec(rectype) with the
  full 3.0 recursive-type grammar of rec groups, sub types, and the
  func/struct/array composite forms.

  The grammar nests four levels deep and two of them have shorthands
  (https://webassembly.github.io/spec/core/binary/types.html#binary-rectype):

    rectype  ::= $4E vec(subtype)            — explicit recursion group
               | subtype                     — shorthand: a group of one
    subtype  ::= $50 vec(typeidx) comptype   — non-final
               | $4F vec(typeidx) comptype   — final
               | comptype                    — shorthand: final, no supers
    comptype ::= $60 vec(valtype) vec(valtype)   — func
               | $5F vec(fieldtype)              — struct
               | $5E fieldtype                   — array

  Both shorthands are normalised INTO the model here — every type-section
  entry becomes a TWasmRecType, a bare subtype a group of one, a bare
  comptype a final subtype with no supertypes — so nothing downstream
  ever re-litigates the encoding. NOTE the $4F/$4E pair's trap: $4F is
  the FINAL form and $50 the non-final one — final is the LOWER byte.

  All the form codes above are LITERAL BYTES in the grammar, matched by a
  peek, never by decoding an sLEB — $CE $7F spells the same NUMBER as the
  $4E rec marker but matches no production and lands in the malformed
  arm. Supertype indices are ordinary u32 typeidx values and admit the
  padded encodings every uN does.

  Everything raised here is EWasmDecodeError, for what the grammar itself
  rejects: unassigned form codes, bad mut bytes, truncated vectors, a
  body that does not end where the section header said. What the grammar
  ACCEPTS decodes, even when validation will later reject it — an empty
  rec group, a supertype index pointing nowhere, a struct with a thousand
  fields. Rejecting those here would corrupt the malformed/invalid split
  the conformance suite asserts. }
unit Wasm.Decoder.Types;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Common,
  Wasm.Module;

{ Decodes one complete type section body into AModule.Types. ABody must
  span exactly the section's declared bytes (the section walk hands out a
  SubReader); leftover bytes after the declared vector are as malformed
  as running out early. ABase is the body's absolute buffer offset, used
  for error context.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-typesec }
procedure DecodeTypeSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

implementation

const
  { The recursive/composite form codes as raw bytes, for peeking. The
    signed-space constants TYPE_CODE_REC etc. in Wasm.Core are these same
    numbers; the byte spellings are needed because the codes are literal
    bytes matched BEFORE any LEB decoding happens. }
  BYTE_REC       = $4E;  { TYPE_CODE_REC       = -50 }
  BYTE_SUB_FINAL = $4F;  { TYPE_CODE_SUB_FINAL = -49 }
  BYTE_SUB       = $50;  { TYPE_CODE_SUB       = -48 }
  BYTE_ARRAY     = $5E;  { TYPE_CODE_ARRAY     = -34 }
  BYTE_STRUCT    = $5F;  { TYPE_CODE_STRUCT    = -33 }
  BYTE_FUNC      = $60;  { TYPE_CODE_FUNC      = -32 }

  { Packed storage type codes, also literal bytes. I16 is the LOWER byte
    of the two.
    https://webassembly.github.io/spec/core/binary/types.html#binary-packtype }
  BYTE_I16 = $77;  { TYPE_CODE_I16 = -9 }
  BYTE_I8  = $78;  { TYPE_CODE_I8  = -8 }

{ storagetype ::= valtype | packtype. The packed codes are literal
  single-byte productions matched by peek; anything else must parse as a
  value type, whose reader enforces its own literal-byte rule — so an
  overlong spelling of a packed code ($F8 $7F for -8) falls through and
  is rejected there.
  https://webassembly.github.io/spec/core/binary/types.html#binary-storagetype }
function ReadStorageType(var AReader: TWasmReader): TWasmStorageType;
begin
  case AReader.PeekByte of
    BYTE_I8:
      begin
        AReader.ReadByte;
        Result := MakePackedStorageType(wpkI8);
      end;
    BYTE_I16:
      begin
        AReader.ReadByte;
        Result := MakePackedStorageType(wpkI16);
      end;
  else
    Result := MakeValueStorageType(ReadValueType(AReader));
  end;
end;

{ fieldtype ::= storagetype mut — storage FIRST, then the mutability
  byte, same order as globaltype and the same two assigned values.
  https://webassembly.github.io/spec/core/binary/types.html#binary-fieldtype }
function ReadFieldType(var AReader: TWasmReader): TWasmFieldType;
begin
  Result.Storage := ReadStorageType(AReader);
  Result.Mut := ReadMut(AReader);
end;

{ functype ::= $60 vec(valtype) vec(valtype) — the $60 was consumed by
  the comptype dispatch.
  https://webassembly.github.io/spec/core/binary/types.html#binary-functype }
function ReadFuncType(var AReader: TWasmReader): TWasmFuncType;
var
  Count: UInt32;
  I: UInt32;
begin
  Count := ReadVecCount(AReader, 'parameter');
  SetLength(Result.Params, Count);
  for I := 1 to Count do
    Result.Params[I - 1] := ReadValueType(AReader);

  Count := ReadVecCount(AReader, 'result');
  SetLength(Result.Results, Count);
  for I := 1 to Count do
    Result.Results[I - 1] := ReadValueType(AReader);
end;

{ comptype ::= $60 functype' | $5F structtype | $5E arraytype.
  https://webassembly.github.io/spec/core/binary/types.html#binary-comptype }
function ReadCompType(var AReader: TWasmReader): TWasmCompType;
var
  Start: NativeUInt;
  Form: Byte;
  StructType: TWasmStructType;
  ArrayType: TWasmArrayType;
  Count: UInt32;
  I: UInt32;
begin
  Start := AReader.Position;
  Form := AReader.ReadByte;
  case Form of
    BYTE_FUNC:
      Result := MakeFuncCompType(ReadFuncType(AReader));
    BYTE_STRUCT:
      begin
        Count := ReadVecCount(AReader, 'field');
        SetLength(StructType.Fields, Count);
        for I := 1 to Count do
          StructType.Fields[I - 1] := ReadFieldType(AReader);
        Result := MakeStructCompType(StructType);
      end;
    BYTE_ARRAY:
      begin
        ArrayType.Elem := ReadFieldType(AReader);
        Result := MakeArrayCompType(ArrayType);
      end;
  else
    raise EWasmDecodeError.CreateFmt(
      'malformed composite type $%.2x at offset %u', [Form, Start]);
  end;
end;

{ subtype ::= $50 vec(typeidx) comptype | $4F vec(typeidx) comptype
            | comptype. $4F is the FINAL form; a bare comptype stands
  for a final subtype with no supertypes. Whether the supertype indices
  exist — or exceed the spec's subtyping-depth limit — is validation.
  https://webassembly.github.io/spec/core/binary/types.html#binary-subtype }
function ReadSubType(var AReader: TWasmReader): TWasmSubType;
var
  Marker: Byte;
  Count: UInt32;
  I: UInt32;
begin
  Marker := AReader.PeekByte;
  if (Marker = BYTE_SUB) or (Marker = BYTE_SUB_FINAL) then
  begin
    AReader.ReadByte;
    Result.IsFinal := Marker = BYTE_SUB_FINAL;
    Count := ReadVecCount(AReader, 'supertype');
    SetLength(Result.SuperTypes, Count);
    for I := 1 to Count do
      Result.SuperTypes[I - 1] := AReader.ReadU32;
  end
  else
  begin
    Result.IsFinal := True;
    Result.SuperTypes := nil;
  end;

  Result.Comp := ReadCompType(AReader);
end;

{ rectype ::= $4E vec(subtype) | subtype. Both spellings become a
  TWasmRecType; the shorthand becomes a group of one. An EXPLICIT empty
  group ($4E $00) is grammatically well-formed — vec admits zero — and
  decodes to a group of none; whether that module validates is not this
  unit's question.
  https://webassembly.github.io/spec/core/binary/types.html#binary-rectype }
function ReadRecType(var AReader: TWasmReader): TWasmRecType;
var
  Count: UInt32;
  I: UInt32;
begin
  if AReader.PeekByte = BYTE_REC then
  begin
    AReader.ReadByte;
    Count := ReadVecCount(AReader, 'recursion group');
    SetLength(Result.SubTypes, Count);
    for I := 1 to Count do
      Result.SubTypes[I - 1] := ReadSubType(AReader);
  end
  else
  begin
    SetLength(Result.SubTypes, 1);
    Result.SubTypes[0] := ReadSubType(AReader);
  end;
end;

procedure DecodeTypeSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
begin
  Count := ReadVecCount(ABody, 'recursive type');
  for I := 1 to Count do
    AModule.AddType(ReadRecType(ABody));

  { The declared vector must account for every byte the section header
    claimed. A shortfall already failed above, inside the reader; a
    surplus fails here. }
  RequireSectionExhausted(ABody, ABase, 'type');
end;

end.
