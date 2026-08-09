{ Wasm.Binary — bounds-checked cursor over module bytes, with the LEB128
  and little-endian primitives the binary format is built from.

  This is a hot path: every byte of every module passes through
  TWasmReader, so it is a record over a raw pointer rather than a class
  over a stream, it copies nothing, and the common single-byte LEB128 case
  is handled before the loop. See the RTL policy in docs/code-style.md.

  Malformed encodings fail here rather than downstream. The spec's width
  limits are part of the format, not a sanity check: a u32 LEB128 is at
  most five bytes and the fifth carries at most four significant bits, so
  an overlong or over-wide encoding is a decode error even when the value
  it spells would fit. Callers therefore never have to re-validate widths. }
unit Wasm.Binary;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  { --- canonical decode message prefixes ---------------------------------

    Every message the decode layer raises STARTS with one of these and
    appends its own context after a colon. The reference interpreter's
    script checker prefix-matches `assert_malformed` strings, so the
    prefix is conformance surface, not decoration: these spellings were
    settled against WebAssembly/testsuite@de54fd27 by `wasmspec`, which is
    why they no longer carry Track B's UNCONFIRMED markers.

    They live in Wasm.Binary because it is the lowest unit of the decode
    layer and every unit above it (Wasm.Decoder and the five
    Wasm.Decoder.* section decoders, plus the body walk in
    Wasm.Validator.Body, which reports binary-grammar failures) already
    uses it. Adding a prefix means adding it here, never re-spelling a
    literal at a raise site.
    https://webassembly.github.io/spec/core/appendix/index-instructions.html }

  { Input ran out. The SAME truncation reports differently depending on
    WHERE the reader sits: upstream distinguishes running off the end of
    the module from running off the end of a section body or a function.
    TWasmReader carries that as its Context, so the distinction is a
    property of the reader, not of each call site. Note the first is a
    PREFIX of the second, so a case that only asserts `unexpected end`
    is satisfied by either. }
  MSG_UNEXPECTED_END = 'unexpected end';
  MSG_UNEXPECTED_END_OF_SECTION = 'unexpected end of section or function';

  { LEB128. `too large` is a value that does not fit the width; `too
    long` is an encoding that spends more bytes than the width allows,
    whatever value it spells. }
  MSG_INTEGER_TOO_LARGE = 'integer too large';
  MSG_INTEGER_TOO_LONG = 'integer representation too long';

  { The `name` production's UTF-8 side condition — a DECODE rule, see
    ReadName below. }
  MSG_MALFORMED_UTF8 = 'malformed UTF-8 encoding';

  { The preamble and the section walk. }
  MSG_MAGIC_HEADER = 'magic header not detected';
  MSG_UNKNOWN_BINARY_VERSION = 'unknown binary version';
  MSG_MALFORMED_SECTION_ID = 'malformed section id';
  { A declared size that runs past the bytes that remain. }
  MSG_LENGTH_OUT_OF_BOUNDS = 'length out of bounds';
  { A known section out of the prescribed order, or repeated. Upstream
    words it as content after the last section because its decoder walks
    the sections in order and stops at the first one it cannot place. }
  MSG_UNEXPECTED_CONTENT = 'unexpected content after last section';
  { A section body the grammar finished with bytes still remaining. }
  MSG_SECTION_SIZE_MISMATCH = 'section size mismatch';

  { The externtype discriminator, which upstream names after the section
    it appears in rather than after the production. }
  MSG_MALFORMED_IMPORT_KIND = 'malformed import kind';
  MSG_MALFORMED_EXPORT_KIND = 'malformed export kind';

  { An unassigned opcode. The hex is part of the prefix upstream asserts
    (`illegal opcode ff`) and is spelled LOWERCASE. }
  MSG_ILLEGAL_OPCODE = 'illegal opcode';
  { The memarg flags field, which upstream calls memop. }
  MSG_MALFORMED_MEMOP_FLAGS = 'malformed memop flags';

type
  { Where a reader sits, which is what decides how running out of input
    is reported — see MSG_UNEXPECTED_END above. Top level is the module
    buffer itself: the preamble and the section headers. A section body,
    a code entry, and a function body span are all `wrcSection`, because
    upstream words those the same way. }
  TWasmReaderContext = (wrcTopLevel, wrcSection);

  TWasmReader = record
  private
    FData: PByte;
    FSize: NativeUInt;
    FPos: NativeUInt;
    FContext: TWasmReaderContext;

    procedure Need(const ACount: NativeUInt; const AWhat: string);
    function ReadUnsigned(const ABits: Byte; const AWhat: string): UInt64;
    function ReadSigned(const ABits: Byte; const AWhat: string): Int64;
    procedure SetPosition(const AValue: NativeUInt);
  public
    { AData must stay alive and unmoved for the reader's whole lifetime —
      the reader borrows the buffer and never owns it. }
    procedure Init(const AData: PByte; const ASize: NativeUInt);
    procedure InitFromBytes(const ABytes: TWasmBytes);

    function Eof: Boolean; inline;
    function Remaining: NativeUInt; inline;

    function ReadByte: Byte;
    function PeekByte: Byte;

    { LEB128. The `A32`/`A64` suffix is the value's width, not the
      encoding's length. }
    function ReadU32: UInt32;
    function ReadU64: UInt64;
    function ReadI32: Int32;
    function ReadI64: Int64;

    { s33, the width the format uses wherever a type code and a type
      index share a position — heap types and block types. Reaching for
      ReadI32 there is the obvious mistake and a wrong one: a concrete
      type index runs to 2^32-1, which ReadI32 rejects. Returned as Int64
      because s33 does not fit Int32. }
    function ReadS33: Int64;

    { Fixed-width little-endian, as used by the module preamble's version
      field and by every immediate the spec spells `uN`. }
    function ReadFixedU32: UInt32;

    { A `name` is a u32 byte-count followed by that many bytes that MUST
      be valid UTF-8. The result is a byte string carrying UTF-8.

      The UTF-8 side condition is part of the BINARY GRAMMAR —
      `name ::= b*:list(byte) => name  if utf8(name) = b*` — so a bad
      name is malformed, not invalid: it raises EWasmDecodeError here and
      never reaches the validator. The distinction is the one Wasm.Core's
      error hierarchy exists to preserve, and it applies to every name in
      the format, not to selected ones.
      https://webassembly.github.io/spec/core/binary/values.html#binary-name }
    function ReadName: string;

    procedure Skip(const ACount: NativeUInt);

    { A sub-reader over ACount bytes starting at the current position,
      which is advanced past them. Section bodies are read this way so a
      body can never run past its declared length. The context is
      INHERITED: a code entry inside a section body is still inside a
      section, so only the caller that opens a section body changes it. }
    function SubReader(const ACount: NativeUInt): TWasmReader;

    { The prefix this reader's truncation failures carry, for the few
      callers that detect exhaustion themselves (a vector count larger
      than the bytes left) rather than by reading past the end. }
    function EndOfInputPrefix: string;

    property Position: NativeUInt read FPos write SetPosition;
    property Size: NativeUInt read FSize;
    property Context: TWasmReaderContext read FContext write FContext;
  end;

{ The canonical message for an unassigned opcode. The opcode byte is part
  of the PREFIX upstream matches (`illegal opcode ff`), not of the context
  after it, and it is spelled in LOWERCASE hex with no `$` or `0x` — a
  detail worth a shared helper rather than two literals, because both the
  expression skipper and the fused body walk raise it and they must agree.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-instr }
function IllegalOpcodeMessage(const AOpcode: Byte;
  const AOffset: NativeUInt): string;

implementation

function IllegalOpcodeMessage(const AOpcode: Byte;
  const AOffset: NativeUInt): string;
begin
  Result := Format('%s %s at offset %u',
    [MSG_ILLEGAL_OPCODE, LowerCase(IntToHex(AOpcode, 2)), AOffset]);
end;

{ Widest LEB128 encoding for a value of ABits bits: ceil(ABits / 7). }
function MaxLebBytes(const ABits: Byte): Integer; inline;
begin
  Result := (ABits + 6) div 7;
end;

{ Significant bits the final byte of a maximal-width encoding may carry. }
function LastByteBits(const ABits: Byte): Byte; inline;
begin
  Result := ABits - 7 * (MaxLebBytes(ABits) - 1);
end;

procedure TWasmReader.Init(const AData: PByte; const ASize: NativeUInt);
begin
  FData := AData;
  FSize := ASize;
  FPos := 0;
  FContext := wrcTopLevel;
end;

procedure TWasmReader.InitFromBytes(const ABytes: TWasmBytes);
begin
  if Length(ABytes) = 0 then
    Init(nil, 0)
  else
    Init(@ABytes[0], Length(ABytes));
end;

function TWasmReader.Eof: Boolean;
begin
  Result := FPos >= FSize;
end;

function TWasmReader.Remaining: NativeUInt;
begin
  if FPos >= FSize then
    Result := 0
  else
    Result := FSize - FPos;
end;

procedure TWasmReader.SetPosition(const AValue: NativeUInt);
begin
  if AValue > FSize then
    raise EWasmDecodeError.CreateFmt(
      'seek past end of input (offset %u, size %u)', [AValue, FSize]);
  FPos := AValue;
end;

function TWasmReader.EndOfInputPrefix: string;
begin
  if FContext = wrcSection then
    Result := MSG_UNEXPECTED_END_OF_SECTION
  else
    Result := MSG_UNEXPECTED_END;
end;

procedure TWasmReader.Need(const ACount: NativeUInt; const AWhat: string);
begin
  if Remaining < ACount then
    raise EWasmDecodeError.CreateFmt(
      '%s: reading %s at offset %u (need %u byte(s), %u left)',
      [EndOfInputPrefix, AWhat, FPos, ACount, Remaining]);
end;

function TWasmReader.ReadByte: Byte;
begin
  Need(1, 'byte');
  Result := FData[FPos];
  Inc(FPos);
end;

function TWasmReader.PeekByte: Byte;
begin
  Need(1, 'byte');
  Result := FData[FPos];
end;

procedure TWasmReader.Skip(const ACount: NativeUInt);
begin
  Need(ACount, 'skipped bytes');
  Inc(FPos, ACount);
end;

function TWasmReader.SubReader(const ACount: NativeUInt): TWasmReader;
begin
  Need(ACount, 'sub-range');
  Result.Init(FData + FPos, ACount);
  Result.FContext := FContext;
  Inc(FPos, ACount);
end;

function TWasmReader.ReadUnsigned(const ABits: Byte;
  const AWhat: string): UInt64;
var
  B: Byte;
  Shift: Integer;
  Count, MaxBytes: Integer;
  LastMask: Byte;
begin
  { Single-byte values are the overwhelming majority (every index, every
    small count), so take them before entering the loop. }
  B := ReadByte;
  if (B and $80) = 0 then
    Exit(B);

  MaxBytes := MaxLebBytes(ABits);
  LastMask := (Byte(1) shl LastByteBits(ABits)) - 1;

  Result := B and $7F;
  Shift := 7;
  Count := 1;

  repeat
    B := ReadByte;
    Inc(Count);

    if Count = MaxBytes then
    begin
      if (B and $80) <> 0 then
        raise EWasmDecodeError.CreateFmt(
          '%s: %s at offset %u is longer than %d bytes',
          [MSG_INTEGER_TOO_LONG, AWhat, FPos - NativeUInt(Count), MaxBytes]);
      if (B and not LastMask) <> 0 then
        raise EWasmDecodeError.CreateFmt(
          '%s: %s at offset %u sets bits above %d',
          [MSG_INTEGER_TOO_LARGE, AWhat, FPos - NativeUInt(Count), ABits]);
    end;

    Result := Result or (UInt64(B and $7F) shl Shift);
    Inc(Shift, 7);
  until (B and $80) = 0;
end;

function TWasmReader.ReadSigned(const ABits: Byte;
  const AWhat: string): Int64;
var
  B: Byte;
  Shift: Integer;
  Count, MaxBytes: Integer;
  SignMask, UpperMask: Byte;
begin
  MaxBytes := MaxLebBytes(ABits);
  SignMask := Byte(1) shl (LastByteBits(ABits) - 1);
  UpperMask := $7F and not ((SignMask shl 1) - 1);

  Result := 0;
  Shift := 0;
  Count := 0;

  repeat
    B := ReadByte;
    Inc(Count);

    if Count = MaxBytes then
    begin
      if (B and $80) <> 0 then
        raise EWasmDecodeError.CreateFmt(
          '%s: %s at offset %u is longer than %d bytes',
          [MSG_INTEGER_TOO_LONG, AWhat, FPos - NativeUInt(Count), MaxBytes]);
      { The bits above the value's width must be a sign extension of its
        top bit; anything else spells a value the width cannot hold —
        which is `integer too large` either way, however it is spelled. }
      if (B and SignMask) <> 0 then
      begin
        if (B and UpperMask) <> UpperMask then
          raise EWasmDecodeError.CreateFmt(
            '%s: %s at offset %u has a sign extension that does not fill '
            + '%d bits',
            [MSG_INTEGER_TOO_LARGE, AWhat, FPos - NativeUInt(Count), ABits]);
      end
      else if (B and UpperMask) <> 0 then
        raise EWasmDecodeError.CreateFmt(
          '%s: %s at offset %u sets bits above %d',
          [MSG_INTEGER_TOO_LARGE, AWhat, FPos - NativeUInt(Count), ABits]);
    end;

    Result := Result or (Int64(B and $7F) shl Shift);
    Inc(Shift, 7);
  until (B and $80) = 0;

  { Sign-extend by OR-ing in all-ones above the bits read, rather than by
    negating a power of two. `-(Int64(1) shl Shift)` is the textbook form
    and is wrong here: a well-formed 9-byte s64 leaves Shift = 63, where
    `Int64(1) shl 63` is Low(Int64) and negating it overflows. Shared.inc
    enables overflow checks in every non-PRODUCTION build, so that raised
    EIntOverflow — outside the EWasmError hierarchy hosts discriminate on —
    and only in the builds CI actually tests.

    Nine bytes is legal: the spec caps sN at ceil(N/7) bytes, 10 for s64,
    and its Note says trailing sign-fill within that bound is allowed.
    https://webassembly.github.io/spec/core/binary/values.html#binary-int }
  if (Shift < 64) and ((B and $40) <> 0) then
    Result := Result or (Int64(-1) shl Shift);
end;

function TWasmReader.ReadU32: UInt32;
begin
  Result := UInt32(ReadUnsigned(32, 'u32'));
end;

function TWasmReader.ReadU64: UInt64;
begin
  Result := ReadUnsigned(64, 'u64');
end;

function TWasmReader.ReadI32: Int32;
begin
  Result := Int32(ReadSigned(32, 's32'));
end;

function TWasmReader.ReadI64: Int64;
begin
  Result := ReadSigned(64, 's64');
end;

function TWasmReader.ReadS33: Int64;
begin
  Result := ReadSigned(33, 's33');
end;

function TWasmReader.ReadFixedU32: UInt32;
begin
  Need(4, 'u32 (fixed)');
  Result := UInt32(FData[FPos])
    or (UInt32(FData[FPos + 1]) shl 8)
    or (UInt32(FData[FPos + 2]) shl 16)
    or (UInt32(FData[FPos + 3]) shl 24);
  Inc(FPos, 4);
end;

{ Strict UTF-8, exactly the spec's `utf8` relation: overlong encodings,
  surrogates (U+D800..U+DFFF), and anything above U+10FFFF are all
  rejected. The leading-byte ranges below encode those exclusions
  directly — $C0/$C1 would only ever be overlong, $ED caps its
  continuation at $9F to exclude surrogates, $F0 floors its first
  continuation at $90 to exclude overlong four-byte forms, and $F4 caps
  at $8F to stop at U+10FFFF. A permissive "is it roughly UTF-8" check
  admits all four families and is not what the spec asks for. }
function IsValidUtf8(const AData: PByte; const ALength: NativeUInt): Boolean;
var
  I: NativeUInt;
  B: Byte;
  Extra: Integer;
  LowBound, HighBound: Byte;
begin
  I := 0;
  while I < ALength do
  begin
    B := AData[I];
    case B of
      $00..$7F: begin Extra := 0; LowBound := $80; HighBound := $BF; end;
      $C2..$DF: begin Extra := 1; LowBound := $80; HighBound := $BF; end;
      $E0:      begin Extra := 2; LowBound := $A0; HighBound := $BF; end;
      $E1..$EC: begin Extra := 2; LowBound := $80; HighBound := $BF; end;
      $ED:      begin Extra := 2; LowBound := $80; HighBound := $9F; end;
      $EE..$EF: begin Extra := 2; LowBound := $80; HighBound := $BF; end;
      $F0:      begin Extra := 3; LowBound := $90; HighBound := $BF; end;
      $F1..$F3: begin Extra := 3; LowBound := $80; HighBound := $BF; end;
      $F4:      begin Extra := 3; LowBound := $80; HighBound := $8F; end;
    else
      { $80..$C1 and $F5..$FF never begin a valid sequence. }
      Exit(False);
    end;

    if ALength - I <= NativeUInt(Extra) then
      Exit(False);

    { The first continuation byte carries the range that rules out
      overlong forms and surrogates; the rest are plain $80..$BF. }
    if Extra >= 1 then
    begin
      if (AData[I + 1] < LowBound) or (AData[I + 1] > HighBound) then
        Exit(False);
      if Extra >= 2 then
        if (AData[I + 2] < $80) or (AData[I + 2] > $BF) then
          Exit(False);
      if Extra >= 3 then
        if (AData[I + 3] < $80) or (AData[I + 3] > $BF) then
          Exit(False);
    end;

    Inc(I, NativeUInt(Extra) + 1);
  end;
  Result := True;
end;

function TWasmReader.ReadName: string;
var
  Len: UInt32;
  Start: NativeUInt;
begin
  Len := ReadU32;
  Need(Len, 'name');
  Start := FPos;

  if (Len > 0) and not IsValidUtf8(FData + Start, Len) then
    raise EWasmDecodeError.CreateFmt(
      '%s: name at offset %u', [MSG_MALFORMED_UTF8, Start]);

  SetLength(Result, Len);
  if Len > 0 then
    Move(FData[Start], Result[1], Len);
  Inc(FPos, Len);
end;

end.
