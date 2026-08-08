{ Wasm.Decoder.Common — the shared type-form readers every section decoder
  is built from: heap, reference, and value types, limits, and the
  table/memory/global/tag external types.

  These are the grammars of the binary format's Types chapter
  (https://webassembly.github.io/spec/core/binary/types.html), pulled out
  of the individual section decoders because nearly every section spells
  at least one of them. The unit sits between Wasm.Binary (the byte
  cursor) and the per-section decoders in the layering
  (docs/architecture.md): it interprets type forms but knows nothing
  about sections or the module model.

  Everything raised here is EWasmDecodeError, because everything checked
  here is the binary grammar itself: an unassigned type code, an
  undefined limits flag, a truncated form — all MALFORMED. Rules that
  need context — whether a type index exists, whether limits fit their
  address type — are validation and are deliberately not checked here;
  rejecting them early would corrupt the malformed/invalid split the
  conformance suite asserts.

  One encoding subtlety runs through the whole unit: the NEGATIVE type
  codes are literal bytes in the grammar, not sLEB128 values, even though
  their VALUES live in the signed code space. A heap type position reads
  an s33 because a concrete type index can follow, but the abstract
  alternatives are single-byte productions — so a multi-byte encoding
  that happens to decode to a valid code (say $E9 $7F for -23) matches no
  production and is malformed. The readers below therefore check the
  encoded width, not just the decoded value. }
unit Wasm.Decoder.Common;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Binary,
  Wasm.Core;

const
  { The long-form reference type markers as raw bytes, for peeking. The
    signed-space constants TYPE_CODE_REF_NULL/TYPE_CODE_REF are these
    same numbers; the byte spellings are needed where the marker must be
    matched literally BEFORE any LEB decoding happens — here and in
    every other unit that peeks for a long-form reference (block types,
    storage types).
    https://webassembly.github.io/spec/core/binary/types.html#binary-reftype }
  BYTE_REF_NULL = $63;
  BYTE_REF      = $64;

{ Heap type: an abstract code (single byte, negative code space) or a
  concrete type index (non-negative s33, padded encodings allowed).
  https://webassembly.github.io/spec/core/binary/types.html#binary-heaptype }
function ReadHeapType(var AReader: TWasmReader): TWasmHeapType;

{ Reference type: long forms $63 (nullable) / $64 (non-null) carry a
  following heap type; a bare abstract heap type byte is the short form
  for a nullable reference.
  https://webassembly.github.io/spec/core/binary/types.html#binary-reftype }
function ReadRefType(var AReader: TWasmReader): TWasmRefType;

{ Value type: a number type, the vector type, or a reference type in
  either form.
  https://webassembly.github.io/spec/core/binary/types.html#binary-valtype }
function ReadValueType(var AReader: TWasmReader): TWasmValueType;

{ Limits. The flags byte has exactly four assigned values — $00/$01 for
  i32 and $04/$05 for i64, bit 0 meaning "max present" and bit 2 the
  address type; anything else (including the threads proposal's shared
  bits, which are NOT in the 3.0 grammar) is malformed. Min and max are
  u64 for BOTH address types; range-checking them against the address
  type is validation's job.
  https://webassembly.github.io/spec/core/binary/types.html#binary-limits }
function ReadLimits(var AReader: TWasmReader): TWasmLimits;

{ Table type: element reference type first, then limits.
  https://webassembly.github.io/spec/core/binary/types.html#binary-tabletype }
function ReadTableType(var AReader: TWasmReader): TWasmTableType;

{ https://webassembly.github.io/spec/core/binary/types.html#binary-memtype }
function ReadMemType(var AReader: TWasmReader): TWasmMemType;

{ Global type: value type first, then the mutability byte, of which only
  $00 (const) and $01 (var) are assigned.
  https://webassembly.github.io/spec/core/binary/types.html#binary-globaltype }
function ReadGlobalType(var AReader: TWasmReader): TWasmGlobalType;

{ Tag type: an attribute byte, of which $00 is the only assigned value,
  then the type index of the tag's function type.
  https://webassembly.github.io/spec/core/binary/types.html#binary-tagtype }
function ReadTagType(var AReader: TWasmReader): TWasmTagType;

{ The mutability byte shared by globaltype and fieldtype: $00 (const)
  and $01 (var) are the only assigned values; True means mutable.
  https://webassembly.github.io/spec/core/binary/types.html#binary-mut }
function ReadMut(var AReader: TWasmReader): Boolean;

{ Reads a vector count and rejects one larger than the bytes left in
  the reader. Every element of every vector in the binary format
  occupies at least one byte, so such a count can only belong to a
  truncated body — and checking first keeps a hostile count from sizing
  an allocation. AWhat names the vector in the error message.
  https://webassembly.github.io/spec/core/binary/conventions.html#binary-vec }
function ReadVecCount(var AReader: TWasmReader;
  const AWhat: string): UInt32;

{ Shared section-exhaustion gate: every section body is a SubReader
  over exactly the declared size, so overrun already fails inside the
  reader; what is left to catch is a body the grammar finished with
  bytes still remaining. The message STARTS with the reference
  interpreter's canonical "section size mismatch" — the wast harness
  prefix-matches expected failure strings, so the prefix is load-
  bearing — and appends context: section name, leftover count, and the
  ABSOLUTE offset (ABase + position) where the leftovers begin.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-section }
procedure RequireSectionExhausted(var ABody: TWasmReader;
  const ABase: NativeUInt; const AWhat: string);

implementation

function ReadHeapType(var AReader: TWasmReader): TWasmHeapType;
var
  Start: NativeUInt;
  Code: Int64;
  Abs: TWasmAbsHeapType;
begin
  Start := AReader.Position;
  Code := AReader.ReadS33;

  { Concrete type indices are the non-negative half of the s33 space, and
    the uN/sN grammars allow zero-padded (non-minimal) encodings within
    the width limit — so no width check on this arm. }
  if Code >= 0 then
    Exit(MakeConcreteHeapType(UInt32(Code)));

  { The abstract alternatives are literal single-byte productions, so a
    multi-byte encoding of the same value matches nothing. }
  if (not TryDecodeAbsHeapType(Code, Abs))
     or (AReader.Position - Start <> 1) then
    raise EWasmDecodeError.CreateFmt(
      'malformed heap type (code %d) at offset %u', [Code, Start]);

  Result := MakeAbsHeapType(Abs);
end;

function ReadRefType(var AReader: TWasmReader): TWasmRefType;
var
  Marker: Byte;
  Start: NativeUInt;
  Code: Int64;
  Ref: TWasmRefType;
begin
  { The long-form markers are literal bytes, so they are matched by a
    peek, not by decoding an sLEB — $E3 $7F spells the same NUMBER as
    $63 but is not the marker. }
  Marker := AReader.PeekByte;
  if (Marker = BYTE_REF_NULL) or (Marker = BYTE_REF) then
  begin
    AReader.ReadByte;
    Exit(MakeRefType(Marker = BYTE_REF_NULL, ReadHeapType(AReader)));
  end;

  { Short form: a bare abstract heap type byte, standing for a nullable
    reference to it. Single-byte for the same literal-production reason
    as in ReadHeapType. }
  Start := AReader.Position;
  Code := AReader.ReadS33;
  if (not TryDecodeShortRefType(Code, Ref))
     or (AReader.Position - Start <> 1) then
    raise EWasmDecodeError.CreateFmt(
      'malformed reference type (code %d) at offset %u', [Code, Start]);

  Result := Ref;
end;

function ReadValueType(var AReader: TWasmReader): TWasmValueType;
var
  Marker: Byte;
  Start: NativeUInt;
  Code: Int64;
  Value: TWasmValueType;
begin
  Marker := AReader.PeekByte;
  if (Marker = BYTE_REF_NULL) or (Marker = BYTE_REF) then
    Exit(MakeRefValueType(ReadRefType(AReader)));

  { Every self-contained value type is a literal single-byte production:
    the number types, v128, and the short reference forms. A bare type
    index is NOT a value type — reference-typed values always carry a
    $63/$64 marker — which is why a non-negative code lands in the error
    arm here rather than becoming a concrete reference. }
  Start := AReader.Position;
  Code := AReader.ReadS33;
  if (not TryDecodeValueType(Code, Value))
     or (AReader.Position - Start <> 1) then
    raise EWasmDecodeError.CreateFmt(
      'malformed value type (code %d) at offset %u', [Code, Start]);

  Result := Value;
end;

function ReadLimits(var AReader: TWasmReader): TWasmLimits;
const
  LIMITS_FLAG_HAS_MAX = $01;
  LIMITS_FLAG_ADDR64  = $04;
var
  Start: NativeUInt;
  Flags: Byte;
begin
  Start := AReader.Position;
  Flags := AReader.ReadByte;

  { Exactly four assigned flag values. $02/$03 (the threads proposal's
    shared bit) are NOT part of the 3.0 grammar this project targets, so
    they are as malformed as any other unassigned byte. }
  if (Flags and not (LIMITS_FLAG_HAS_MAX or LIMITS_FLAG_ADDR64)) <> 0 then
    raise EWasmDecodeError.CreateFmt(
      'malformed limits flags $%.2x at offset %u', [Flags, Start]);

  if (Flags and LIMITS_FLAG_ADDR64) <> 0 then
    Result.AddrType := watI64
  else
    Result.AddrType := watI32;

  Result.HasMax := (Flags and LIMITS_FLAG_HAS_MAX) <> 0;

  { u64 regardless of the address type — see the interface comment. }
  Result.Min := AReader.ReadU64;
  if Result.HasMax then
    Result.Max := AReader.ReadU64
  else
    Result.Max := 0;
end;

function ReadTableType(var AReader: TWasmReader): TWasmTableType;
begin
  { Element type FIRST, then limits — the reverse of how the text format
    spells it. }
  Result.RefType := ReadRefType(AReader);
  Result.Limits := ReadLimits(AReader);
end;

function ReadMemType(var AReader: TWasmReader): TWasmMemType;
begin
  Result.Limits := ReadLimits(AReader);
end;

function ReadGlobalType(var AReader: TWasmReader): TWasmGlobalType;
begin
  Result.ValueType := ReadValueType(AReader);
  Result.Mut := ReadMut(AReader);
end;

function ReadMut(var AReader: TWasmReader): Boolean;
var
  Start: NativeUInt;
  MutByte: Byte;
begin
  Start := AReader.Position;
  MutByte := AReader.ReadByte;
  if MutByte > $01 then
    raise EWasmDecodeError.CreateFmt(
      'malformed mutability $%.2x at offset %u', [MutByte, Start]);
  Result := MutByte = $01;
end;

function ReadVecCount(var AReader: TWasmReader;
  const AWhat: string): UInt32;
var
  Start: NativeUInt;
begin
  Start := AReader.Position;
  Result := AReader.ReadU32;
  if Result > AReader.Remaining then
    raise EWasmDecodeError.CreateFmt(
      'truncated %s vector (count %u, %u bytes remain) at offset %u',
      [AWhat, Result, AReader.Remaining, Start]);
end;

procedure RequireSectionExhausted(var ABody: TWasmReader;
  const ABase: NativeUInt; const AWhat: string);
begin
  if not ABody.Eof then
    raise EWasmDecodeError.CreateFmt(
      'section size mismatch: %u byte(s) left over after %s section '
      + 'content at offset %u',
      [ABody.Remaining, AWhat, ABase + ABody.Position]);
end;

function ReadTagType(var AReader: TWasmReader): TWasmTagType;
var
  Start: NativeUInt;
  Attribute: Byte;
begin
  Start := AReader.Position;
  Attribute := AReader.ReadByte;
  if Attribute <> $00 then
    raise EWasmDecodeError.CreateFmt(
      'malformed tag attribute $%.2x at offset %u', [Attribute, Start]);
  Result.TypeIndex := AReader.ReadU32;
end;

end.
