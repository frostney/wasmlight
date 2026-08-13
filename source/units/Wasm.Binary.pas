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
  { A function-code expression reached its declared entry boundary while the
    code section still contains a following entry. }
  MSG_END_OPCODE_EXPECTED = 'END opcode expected';

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
    { The PHYSICAL bytes reachable from FData, always >= FSize. For a
      top-level reader the two coincide; a section SubReader's FSize is the
      declared section length, but FCapacity spans the rest of the module
      buffer it borrows. The width-limited LEB readers scan against
      FCapacity, never FSize: a uN/sN's byte count is bounded by the type
      width (ceil(N/7)), a condition on the encoding itself and independent
      of any framing — so an overlong or over-wide encoding is malformed
      even when a section boundary falls inside it. Everything else (Need,
      Remaining, Eof, Skip, ReadName, the section-exhaustion check) stays
      on FSize, so framing and truncation reporting are unchanged.
      https://webassembly.github.io/spec/core/binary/values.html#binary-int }
    FCapacity: NativeUInt;

    procedure Need(const ACount: NativeUInt; const AWhat: string);
    function ReadLebByte: Byte;
    procedure RaiseSectionTruncated(const AOffset: NativeUInt);
    function ReadUnsigned(const ABits: Byte; const AWhat: string): UInt64;
    function ReadSigned(const ABits: Byte; const AWhat: string): Int64;
    procedure SetPosition(const AValue: NativeUInt);
  public
    { AData must stay alive and unmoved for the reader's whole lifetime —
      the reader borrows the buffer and never owns it. }
    procedure Init(const AData: PByte; const ASize: NativeUInt);
    procedure InitFromBytes(const ABytes: TWasmBytes);
    { A logically bounded span over a larger physical module buffer. LEB128
      readers may inspect past the span to classify an overlong or over-wide
      integer before the enclosing size mismatch is reported; every other
      read remains bounded by ASize. }
    procedure InitSpanFromBytes(const ABytes: TWasmBytes;
      const AOffset, ASize: NativeUInt);

    function Eof: Boolean; inline;
    function Remaining: NativeUInt; inline;

    function ReadByte: Byte;
    function PeekByte: Byte;
    function PeekPhysicalByte: Byte;

    { LEB128. The `A32`/`A64` suffix is the value's width, not the
      encoding's length. }
    function ReadU32: UInt32;
    function ReadU64: UInt64;
    function ReadS7: Int8;
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
    { Bytes physically present after the reader's logical span. Used only by
      decoders whose reference diagnostic depends on whether the module
      continues beyond an exhausted section. }
    function PhysicalRemaining: NativeUInt;

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
  { A freestanding reader has nothing behind its logical size; SubReader
    widens this for section bodies. }
  FCapacity := ASize;
end;

procedure TWasmReader.InitFromBytes(const ABytes: TWasmBytes);
begin
  if Length(ABytes) = 0 then
    Init(nil, 0)
  else
    Init(@ABytes[0], Length(ABytes));
end;

procedure TWasmReader.InitSpanFromBytes(const ABytes: TWasmBytes;
  const AOffset, ASize: NativeUInt);
var
  BufferSize: NativeUInt;
begin
  BufferSize := NativeUInt(Length(ABytes));
  if (AOffset > BufferSize) or (ASize > BufferSize - AOffset) then
    raise EWasmDecodeError.CreateFmt(
      'reader span [%u, %u) runs past a %u-byte buffer',
      [AOffset, AOffset + ASize, BufferSize]);

  if BufferSize = 0 then
    Init(nil, 0)
  else
    Init(@ABytes[AOffset], ASize);
  FCapacity := BufferSize - AOffset;
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

function TWasmReader.PhysicalRemaining: NativeUInt;
begin
  if FPos >= FCapacity then
    Result := 0
  else
    Result := FCapacity - FPos;
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

function TWasmReader.PeekPhysicalByte: Byte;
begin
  if FPos >= FCapacity then
    raise EWasmDecodeError.CreateFmt(
      '%s: reading byte at offset %u (need 1 byte(s), 0 left)',
      [EndOfInputPrefix, FPos]);
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
  { The sub-reader's declared size is ACount, but the buffer it borrows
    runs to this reader's own physical end — that is what lets a
    width-limited LEB read past a section boundary to decide overlong or
    over-wide, exactly as the reference decoder reads from the whole
    stream and checks the section size afterwards. Need(ACount) above
    guarantees FCapacity - FPos >= ACount, so this never shrinks below the
    logical size. }
  Result.FCapacity := FCapacity - FPos;
  Inc(FPos, ACount);
end;

{ One continuation byte of a width-limited LEB, read against the PHYSICAL
  buffer rather than the logical section size. A uN/sN may be at most
  ceil(N/7) bytes; the reader must be able to inspect up to that many bytes
  to tell an overlong or over-wide encoding apart from a genuine
  truncation, and a section boundary landing inside the encoding must not
  short-circuit that with an `unexpected end`. Only running off the whole
  buffer is a real truncation here. }
function TWasmReader.ReadLebByte: Byte;
begin
  if FPos >= FCapacity then
    raise EWasmDecodeError.CreateFmt(
      '%s: reading byte at offset %u (need 1 byte(s), 0 left)',
      [EndOfInputPrefix, FPos]);
  Result := FData[FPos];
  Inc(FPos);
end;

{ A width-limited LEB completed only by consuming bytes past the section's
  declared size: the section is too small to hold the field, which is the
  same truncation the logical bound would have reported one byte earlier.
  Reported at AOffset (the section end) so the wording matches a plain
  `Need` failure at that point. }
procedure TWasmReader.RaiseSectionTruncated(const AOffset: NativeUInt);
begin
  raise EWasmDecodeError.CreateFmt(
    '%s: reading byte at offset %u (need 1 byte(s), 0 left)',
    [EndOfInputPrefix, AOffset]);
end;

function TWasmReader.ReadUnsigned(const ABits: Byte;
  const AWhat: string): UInt64;
var
  B: Byte;
  Shift: Integer;
  Count, MaxBytes: Integer;
  LastMask: Byte;
  LogicalEnd: NativeUInt;
begin
  { Single-byte values are the overwhelming majority (every index, every
    small count), so take them before entering the loop. This first byte
    reads against the logical size: a field that cannot even begin within
    its section is a plain truncation, not an overlong encoding. }
  B := ReadByte;
  if (B and $80) = 0 then
    Exit(B);

  MaxBytes := MaxLebBytes(ABits);
  LastMask := (Byte(1) shl LastByteBits(ABits)) - 1;
  LogicalEnd := FSize;

  Result := B and $7F;
  Shift := 7;
  Count := 1;

  { Continuation bytes read against the physical buffer, so the width
    checks below fire even when a section boundary falls mid-encoding. }
  repeat
    B := ReadLebByte;
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

  { A within-width encoding that only completed past the section boundary:
    report it as the truncation the logical bound stands for, preserving
    the `unexpected end` wording for a section too small to hold a valid
    field. Overlong/over-wide encodings never reach here — they raised at
    MaxBytes above. }
  if FPos > LogicalEnd then
    RaiseSectionTruncated(LogicalEnd);
end;

function TWasmReader.ReadSigned(const ABits: Byte;
  const AWhat: string): Int64;
var
  B: Byte;
  Shift: Integer;
  Count, MaxBytes: Integer;
  SignMask, UpperMask: Byte;
  LogicalEnd: NativeUInt;
begin
  MaxBytes := MaxLebBytes(ABits);
  SignMask := Byte(1) shl (LastByteBits(ABits) - 1);
  UpperMask := $7F and not ((SignMask shl 1) - 1);

  LogicalEnd := FSize;

  Result := 0;
  Shift := 0;
  Count := 0;

  repeat
    { First byte against the logical size (a field must at least begin
      within its section); continuation bytes against the physical buffer,
      so the width checks fire across a section boundary. }
    if Count = 0 then
      B := ReadByte
    else
      B := ReadLebByte;
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

  { A within-width encoding that only completed past the section boundary
    is the same truncation the logical bound stands for — see the unsigned
    reader. Overlong/over-wide encodings raised at MaxBytes above. }
  if FPos > LogicalEnd then
    RaiseSectionTruncated(LogicalEnd);

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

function TWasmReader.ReadS7: Int8;
begin
  Result := Int8(ReadSigned(7, 's7'));
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
  { A name is a byte list (`binary-name` -> `binary-list`). Distinguish a
    list whose declared byte length runs past the PHYSICAL module buffer
    from one merely cut by its enclosing section: the former is the
    reference decoder's `length out of bounds`, while the latter remains
    the section-context truncation raised by Need below. Sub-readers retain
    the physical capacity specifically so framing does not hide a malformed
    width or length that can already be proved from the whole buffer. }
  if NativeUInt(Len) > FCapacity - FPos then
    raise EWasmDecodeError.CreateFmt(
      '%s: name at offset %u declares %u byte(s) but only %u remain',
      [MSG_LENGTH_OUT_OF_BOUNDS, FPos, Len, FCapacity - FPos]);
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
