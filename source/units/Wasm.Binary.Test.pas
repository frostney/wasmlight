{ Unit suite for Wasm.Binary. The LEB128 cases are the ones that matter:
  the boundary encodings, and every way a malformed encoding must be
  rejected rather than silently truncated. }
program Wasm.Binary.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core;

type
  TBinaryTests = class(TTestSuite)
  private
    { The reader borrows its buffer and never owns it, so the buffer has
      to outlive every reader built over it — hence a suite field rather
      than a local in the helper. }
    FBuffer: TWasmBytes;

    function ReaderOver(const AValues: array of Byte): TWasmReader;
    { A section-body SubReader of ALogicalSize bytes over AValues, in the
      wrcSection context — the shape a decoded section body takes. The
      logical size is smaller than AValues on purpose: the bytes past it
      stand for whatever follows the section in the module buffer, which a
      width-limited LEB read is allowed to inspect. }
    function SectionSubReaderOver(const AValues: array of Byte;
      const ALogicalSize: NativeUInt): TWasmReader;
    { Runs AReadKind over a section SubReader and asserts the raised
      message STARTS with APrefix — the fix's core distinction lives here,
      between an overlong/over-wide encoding clipped by a section boundary
      (an integer error) and a genuine truncation (unexpected end). }
    procedure ExpectSectionLebPrefix(const AReadKind, ADescription,
      APrefix: string; const AValues: array of Byte;
      const ALogicalSize: NativeUInt);
    { Runs AReadKind over AValues and asserts it raises EWasmDecodeError.
      AReadKind picks the primitive so one helper covers every width. }
    procedure ExpectRejected(const AReadKind, ADescription: string;
      const AValues: array of Byte);
    { Runs AReadKind over AValues in AContext and asserts the raised
      message STARTS with APrefix. Prefixes are conformance surface — the
      .wast harness prefix-matches them — so they are asserted as
      prefixes, never as whole strings: the context after the colon is
      free to change, the prefix is not. }
    procedure ExpectMessagePrefix(const AReadKind, ADescription,
      APrefix: string; const AValues: array of Byte;
      const AContext: TWasmReaderContext);
    { Asserts rejection and names the case in the failure message. Phrased
      as a value comparison rather than a bare Fail() so the test records
      an assertion even on the happy path. }
    procedure AssertRejected(const ADescription: string;
      const ARejected: Boolean);
  public
    procedure SetupTests; override;

    procedure TestReadByteAdvances;
    procedure TestUnsignedSingleByte;
    procedure TestUnsignedMultiByte;
    procedure TestUnsignedU32Max;
    procedure TestUnsignedU64Max;
    procedure TestSignedNegativeOne;
    procedure TestSignedTwoByteNegative;
    procedure TestSignedPositivePadding;
    procedure TestSignedMultiByteNegative;
    procedure TestSignedI32Extremes;
    procedure TestSignedI64Min;
    procedure TestRejectsOverWideU32;
    procedure TestRejectsOverLongU32;
    procedure TestRejectsOverWideI32;
    procedure TestRejectsTruncatedLeb;
    procedure TestFixedU32IsLittleEndian;
    procedure TestReadName;
    procedure TestReadNameRejectsOverrun;
    procedure TestSubReaderIsBounded;
    procedure TestRemainingAndEof;
    procedure TestAcceptsLegalSignFilledEncodings;
    procedure TestAcceptsLegalZeroPaddedEncodings;
    procedure TestReadS33SpansTypeCodesAndIndices;
    procedure TestReadNameRejectsInvalidUtf8;
    procedure TestReadNameAcceptsValidUtf8;
    procedure TestPositionSetter;
    procedure TestCanonicalLebAndNamePrefixes;
    procedure TestTruncationPrefixFollowsContext;
    procedure TestIllegalOpcodeMessageIsLowercaseHex;
    procedure TestOverlongLebClippedBySectionIsTooLong;
    procedure TestOverWideLebClippedBySectionIsTooLarge;
    procedure TestTruncatedLebInSectionStaysUnexpectedEnd;
  end;

function TBinaryTests.ReaderOver(const AValues: array of Byte): TWasmReader;
var
  I: Integer;
begin
  SetLength(FBuffer, Length(AValues));
  for I := 0 to High(AValues) do
    FBuffer[I] := AValues[I];
  Result.InitFromBytes(FBuffer);
end;

function TBinaryTests.SectionSubReaderOver(const AValues: array of Byte;
  const ALogicalSize: NativeUInt): TWasmReader;
var
  Parent: TWasmReader;
begin
  Parent := ReaderOver(AValues);
  Parent.Context := wrcSection;
  Result := Parent.SubReader(ALogicalSize);
end;

procedure TBinaryTests.ExpectSectionLebPrefix(const AReadKind, ADescription,
  APrefix: string; const AValues: array of Byte;
  const ALogicalSize: NativeUInt);
var
  Reader: TWasmReader;
  Actual: string;
begin
  Reader := SectionSubReaderOver(AValues, ALogicalSize);
  Actual := '<not rejected>';

  try
    if AReadKind = 'u32' then
      Reader.ReadU32
    else if AReadKind = 'u64' then
      Reader.ReadU64
    else if AReadKind = 'i32' then
      Reader.ReadI32
    else if AReadKind = 'i64' then
      Reader.ReadI64
    else if AReadKind = 's33' then
      Reader.ReadS33
    else
      Fail('unknown read kind ' + AReadKind);
  except
    on E: EWasmDecodeError do
      Actual := E.Message;
  end;

  if Copy(Actual, 1, Length(APrefix)) = APrefix then
    Expect<string>(ADescription + ': ' + APrefix)
      .ToBe(ADescription + ': ' + APrefix)
  else
    Expect<string>(ADescription + ': ' + Actual)
      .ToBe(ADescription + ': ' + APrefix + '...');
end;

procedure TBinaryTests.ExpectRejected(const AReadKind, ADescription: string;
  const AValues: array of Byte);
var
  Reader: TWasmReader;
  Rejected: Boolean;
begin
  if (AReadKind <> 'u32') and (AReadKind <> 'u64') and (AReadKind <> 'i32')
     and (AReadKind <> 'i64') and (AReadKind <> 's33')
     and (AReadKind <> 'name') then
    Fail('unknown read kind ' + AReadKind);

  Reader := ReaderOver(AValues);
  Rejected := False;

  { The assertion is made after the try, not inside the handler: a Fail()
    in the try block would be swallowed by the handler, and FPC will not
    parse a generic call as the lone statement of an `on ... do`. }
  try
    if AReadKind = 'u32' then
      Reader.ReadU32
    else if AReadKind = 'u64' then
      Reader.ReadU64
    else if AReadKind = 'i32' then
      Reader.ReadI32
    else if AReadKind = 'i64' then
      Reader.ReadI64
    else if AReadKind = 's33' then
      Reader.ReadS33
    else
      Reader.ReadName;
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;

  AssertRejected(ADescription, Rejected);
end;

procedure TBinaryTests.ExpectMessagePrefix(const AReadKind, ADescription,
  APrefix: string; const AValues: array of Byte;
  const AContext: TWasmReaderContext);
var
  Reader: TWasmReader;
  Actual: string;
begin
  Reader := ReaderOver(AValues);
  Reader.Context := AContext;
  Actual := '<not rejected>';

  try
    if AReadKind = 'u32' then
      Reader.ReadU32
    else if AReadKind = 'u64' then
      Reader.ReadU64
    else if AReadKind = 'i32' then
      Reader.ReadI32
    else if AReadKind = 'i64' then
      Reader.ReadI64
    else if AReadKind = 'name' then
      Reader.ReadName
    else
      Fail('unknown read kind ' + AReadKind);
  except
    on E: EWasmDecodeError do
      Actual := E.Message;
  end;

  { Compared as values so a failure prints the whole message, and so the
    test records an assertion on the happy path too. }
  if Copy(Actual, 1, Length(APrefix)) = APrefix then
    Expect<string>(ADescription + ': ' + APrefix)
      .ToBe(ADescription + ': ' + APrefix)
  else
    Expect<string>(ADescription + ': ' + Actual)
      .ToBe(ADescription + ': ' + APrefix + '...');
end;

procedure TBinaryTests.AssertRejected(const ADescription: string;
  const ARejected: Boolean);
var
  Outcome: string;
begin
  if ARejected then
    Outcome := 'rejected'
  else
    Outcome := 'ACCEPTED';
  Expect<string>(ADescription + ': ' + Outcome)
    .ToBe(ADescription + ': rejected');
end;

procedure TBinaryTests.TestReadByteAdvances;
var
  R: TWasmReader;
begin
  R := ReaderOver([$01, $02]);
  Expect<Integer>(R.ReadByte).ToBe(1);
  Expect<Integer>(Integer(R.Position)).ToBe(1);
  Expect<Integer>(R.PeekByte).ToBe(2);
  Expect<Integer>(Integer(R.Position)).ToBe(1);
  Expect<Integer>(R.ReadByte).ToBe(2);
  Expect<Boolean>(R.Eof).ToBe(True);
end;

procedure TBinaryTests.TestUnsignedSingleByte;
var
  R: TWasmReader;
begin
  R := ReaderOver([$00, $7F]);
  Expect<Int64>(Int64(R.ReadU32)).ToBe(0);
  Expect<Int64>(Int64(R.ReadU32)).ToBe(127);
end;

procedure TBinaryTests.TestUnsignedMultiByte;
var
  R: TWasmReader;
begin
  { 624485, the spec's own worked example. }
  R := ReaderOver([$E5, $8E, $26]);
  Expect<Int64>(Int64(R.ReadU32)).ToBe(624485);
  Expect<Boolean>(R.Eof).ToBe(True);
end;

procedure TBinaryTests.TestUnsignedU32Max;
var
  R: TWasmReader;
begin
  R := ReaderOver([$FF, $FF, $FF, $FF, $0F]);
  Expect<Int64>(Int64(R.ReadU32)).ToBe(4294967295);
end;

procedure TBinaryTests.TestUnsignedU64Max;
var
  R: TWasmReader;
begin
  R := ReaderOver([$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $01]);
  { Compared as hex: the assertion helper has no unsigned-64 formatter, so
    a hex string keeps a failure message readable. }
  Expect<string>(IntToHex(Int64(R.ReadU64), 16)).ToBe('FFFFFFFFFFFFFFFF');
end;

procedure TBinaryTests.TestSignedNegativeOne;
var
  R: TWasmReader;
begin
  R := ReaderOver([$7F]);
  Expect<Integer>(R.ReadI32).ToBe(-1);
end;

procedure TBinaryTests.TestSignedTwoByteNegative;
var
  R: TWasmReader;
begin
  R := ReaderOver([$80, $7F]);
  Expect<Integer>(R.ReadI32).ToBe(-128);
end;

procedure TBinaryTests.TestSignedPositivePadding;
var
  R: TWasmReader;
begin
  { 63 fits one byte; 64 does not, because bit 6 is the sign bit. }
  R := ReaderOver([$3F]);
  Expect<Integer>(R.ReadI32).ToBe(63);
  R := ReaderOver([$C0, $00]);
  Expect<Integer>(R.ReadI32).ToBe(64);
end;

procedure TBinaryTests.TestSignedMultiByteNegative;
var
  R: TWasmReader;
begin
  R := ReaderOver([$C0, $BB, $78]);
  Expect<Integer>(R.ReadI32).ToBe(-123456);
end;

procedure TBinaryTests.TestSignedI32Extremes;
var
  R: TWasmReader;
begin
  R := ReaderOver([$FF, $FF, $FF, $FF, $07]);
  Expect<Integer>(R.ReadI32).ToBe(2147483647);
  R := ReaderOver([$80, $80, $80, $80, $78]);
  Expect<Integer>(R.ReadI32).ToBe(Low(Integer));
end;

procedure TBinaryTests.TestSignedI64Min;
var
  R: TWasmReader;
begin
  R := ReaderOver([$80, $80, $80, $80, $80, $80, $80, $80, $80, $7F]);
  Expect<Int64>(R.ReadI64).ToBe(Low(Int64));
end;

procedure TBinaryTests.TestRejectsOverWideU32;
begin
  { The fifth byte of a u32 carries four significant bits; $1F sets a
    fifth, so the encoding spells a value wider than the type. }
  ExpectRejected('u32', 'u32 with bits above 32',
    [$FF, $FF, $FF, $FF, $1F]);
  ExpectRejected('u64', 'u64 with bits above 64',
    [$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $02]);
end;

procedure TBinaryTests.TestRejectsOverLongU32;
begin
  { Six bytes for a u32: the fifth still sets its continuation bit. }
  ExpectRejected('u32', 'u32 longer than five bytes',
    [$80, $80, $80, $80, $80, $00]);
end;

procedure TBinaryTests.TestRejectsOverWideI32;
begin
  { $4F has its sign bit (bit 3) set but does not sign-extend bits 4..6. }
  ExpectRejected('i32', 'i32 without full sign extension',
    [$FF, $FF, $FF, $FF, $4F]);
  ExpectRejected('i32', 'i32 with bits above 32',
    [$FF, $FF, $FF, $FF, $17]);
end;

procedure TBinaryTests.TestRejectsTruncatedLeb;
begin
  { Continuation bit set on the last available byte. }
  ExpectRejected('u32', 'truncated u32', [$80]);
  ExpectRejected('i64', 'truncated i64', [$FF, $FF]);
end;

procedure TBinaryTests.TestFixedU32IsLittleEndian;
var
  R: TWasmReader;
begin
  R := ReaderOver([$01, $00, $00, $00]);
  Expect<Int64>(Int64(R.ReadFixedU32)).ToBe(1);
  R := ReaderOver([$78, $56, $34, $12]);
  Expect<Int64>(Int64(R.ReadFixedU32)).ToBe($12345678);
end;

procedure TBinaryTests.TestReadName;
var
  R: TWasmReader;
begin
  R := ReaderOver([$04, Ord('n'), Ord('a'), Ord('m'), Ord('e')]);
  Expect<string>(R.ReadName).ToBe('name');
  Expect<Boolean>(R.Eof).ToBe(True);

  R := ReaderOver([$00]);
  Expect<string>(R.ReadName).ToBe('');
end;

procedure TBinaryTests.TestReadNameRejectsOverrun;
begin
  { Declares nine bytes, supplies two. }
  ExpectRejected('name', 'name longer than the input',
    [$09, Ord('a'), Ord('b')]);
end;

procedure TBinaryTests.TestSubReaderIsBounded;
var
  R, Sub: TWasmReader;
  Rejected: Boolean;
begin
  R := ReaderOver([$AA, $BB, $CC, $DD]);
  Sub := R.SubReader(2);
  Expect<Integer>(Integer(Sub.Size)).ToBe(2);
  Expect<Integer>(Sub.ReadByte).ToBe($AA);
  Expect<Integer>(Sub.ReadByte).ToBe($BB);
  Expect<Boolean>(Sub.Eof).ToBe(True);

  { The parent advanced past the sub-range, not into it. }
  Expect<Integer>(Integer(R.Position)).ToBe(2);
  Expect<Integer>(R.ReadByte).ToBe($CC);

  Rejected := False;
  try
    Sub.ReadByte;
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;
  AssertRejected('read past a sub-reader bound', Rejected);
end;

procedure TBinaryTests.TestRemainingAndEof;
var
  R: TWasmReader;
  Rejected: Boolean;
begin
  R := ReaderOver([$01, $02, $03]);
  Expect<Integer>(Integer(R.Remaining)).ToBe(3);
  Expect<Boolean>(R.Eof).ToBe(False);
  R.Skip(3);
  Expect<Integer>(Integer(R.Remaining)).ToBe(0);
  Expect<Boolean>(R.Eof).ToBe(True);

  Rejected := False;
  try
    R.Skip(1);
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;
  AssertRejected('skip past end of input', Rejected);
end;

procedure TBinaryTests.TestAcceptsLegalSignFilledEncodings;
var
  R: TWasmReader;
begin
  { The spec caps sN at ceil(N/7) bytes and its Note says trailing
    sign-fill WITHIN that bound is allowed. Every other LEB128 test here
    asserts that something malformed is rejected; this asserts the
    converse, which is the gap a real bug lived in — a 9-byte s64 leaves
    the sign-extension shift at 63, where negating a power of two
    overflows and raised EIntOverflow instead of returning a value.
    https://webassembly.github.io/spec/core/binary/values.html#binary-int }

  { -1 as s64 in 9 bytes (maximal is 10). }
  R := ReaderOver([$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $7F]);
  Expect<Int64>(R.ReadI64).ToBe(-1);

  { -(2^56) in 9 bytes: the same shift, a different value. }
  R := ReaderOver([$80, $80, $80, $80, $80, $80, $80, $80, $7F]);
  Expect<string>(IntToHex(R.ReadI64, 16)).ToBe('FF00000000000000');

  { -1 as s64 in the full 10 bytes, which routes around the shift above
    and so would pass even with the bug present. }
  R := ReaderOver([$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $7F]);
  Expect<Int64>(R.ReadI64).ToBe(-1);

  { -1 as s32, sign-filled to the maximal five bytes. }
  R := ReaderOver([$FF, $FF, $FF, $FF, $7F]);
  Expect<Integer>(R.ReadI32).ToBe(-1);
end;

procedure TBinaryTests.TestAcceptsLegalZeroPaddedEncodings;
var
  R: TWasmReader;
begin
  { The unsigned counterpart: zero padding up to the width limit is
    legal, however redundant. }
  R := ReaderOver([$80, $80, $80, $80, $00]);
  Expect<Int64>(Int64(R.ReadU32)).ToBe(0);

  R := ReaderOver([$80, $80, $80, $80, $80, $80, $80, $80, $80, $00]);
  Expect<string>(IntToHex(Int64(R.ReadU64), 16)).ToBe('0000000000000000');

  { A small value spelled the long way. }
  R := ReaderOver([$81, $80, $80, $80, $00]);
  Expect<Int64>(Int64(R.ReadU32)).ToBe(1);
end;

procedure TBinaryTests.TestReadS33SpansTypeCodesAndIndices;
var
  R: TWasmReader;
begin
  { s33 is the width used wherever a type code and a type index share a
    position. It has to reach both: negative type codes AND indices past
    what an s32 holds. }
  R := ReaderOver([$7F]);
  Expect<Int64>(R.ReadS33).ToBe(-1);        { i32's type code }
  R := ReaderOver([$70]);
  Expect<Int64>(R.ReadS33).ToBe(-16);       { funcref's heap type }
  R := ReaderOver([$00]);
  Expect<Int64>(R.ReadS33).ToBe(0);         { type index 0 }

  { 2^31 — a valid type index that ReadI32 would reject, which is why
    reaching for ReadI32 in a heap-type position is wrong. }
  R := ReaderOver([$80, $80, $80, $80, $08]);
  Expect<Int64>(R.ReadS33).ToBe(Int64(2147483648));

  { Still bounded: six bytes exceeds ceil(33/7) = 5. }
  ExpectRejected('s33', 's33 longer than five bytes',
    [$80, $80, $80, $80, $80, $00]);
end;

procedure TBinaryTests.TestReadNameRejectsInvalidUtf8;
begin
  { The UTF-8 side condition lives in the BINARY grammar, so these are
    malformed modules, not invalid ones — they must fail in the reader.
    Each family below is one the spec's `utf8` relation excludes and a
    permissive check would wave through. }
  ExpectRejected('name', 'lone continuation byte', [$01, $80]);
  ExpectRejected('name', 'byte that never starts a sequence', [$01, $FF]);
  ExpectRejected('name', 'truncated two-byte sequence', [$01, $C2]);
  ExpectRejected('name', 'overlong NUL', [$02, $C0, $80]);
  ExpectRejected('name', 'overlong two-byte form', [$02, $C1, $BF]);
  ExpectRejected('name', 'surrogate U+D800', [$03, $ED, $A0, $80]);
  ExpectRejected('name', 'above U+10FFFF', [$04, $F5, $80, $80, $80]);
  ExpectRejected('name', 'four-byte form past U+10FFFF',
    [$04, $F4, $90, $80, $80]);
  ExpectRejected('name', 'overlong four-byte form',
    [$04, $F0, $8F, $BF, $BF]);
  ExpectRejected('name', 'sequence truncated by the name length',
    [$02, $E2, $82]);
end;

procedure TBinaryTests.TestReadNameAcceptsValidUtf8;
var
  R: TWasmReader;
begin
  { The boundary cases on the accepting side, so the validator cannot be
    tightened into rejecting legal names. }
  R := ReaderOver([$02, $C2, $80]);                 { U+0080, shortest 2-byte }
  Expect<Integer>(Length(R.ReadName)).ToBe(2);
  R := ReaderOver([$03, $E0, $A0, $80]);            { U+0800, shortest 3-byte }
  Expect<Integer>(Length(R.ReadName)).ToBe(3);
  R := ReaderOver([$03, $ED, $9F, $BF]);            { U+D7FF, just below surrogates }
  Expect<Integer>(Length(R.ReadName)).ToBe(3);
  R := ReaderOver([$03, $EE, $80, $80]);            { U+E000, just above them }
  Expect<Integer>(Length(R.ReadName)).ToBe(3);
  R := ReaderOver([$04, $F0, $90, $80, $80]);       { U+10000, shortest 4-byte }
  Expect<Integer>(Length(R.ReadName)).ToBe(4);
  R := ReaderOver([$04, $F4, $8F, $BF, $BF]);       { U+10FFFF, the maximum }
  Expect<Integer>(Length(R.ReadName)).ToBe(4);
  R := ReaderOver([$03, $E2, $82, $AC]);            { U+20AC euro sign }
  Expect<Integer>(Length(R.ReadName)).ToBe(3);
end;

procedure TBinaryTests.TestPositionSetter;
var
  R: TWasmReader;
  Rejected: Boolean;
begin
  R := ReaderOver([$0A, $0B, $0C]);
  R.Position := 2;
  Expect<Integer>(R.ReadByte).ToBe($0C);

  { Seeking to exactly the end is legal; past it is not. }
  R.Position := 3;
  Expect<Boolean>(R.Eof).ToBe(True);

  Rejected := False;
  try
    R.Position := 4;
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;
  AssertRejected('seek past end of input', Rejected);
end;

{ --- canonical message prefixes ------------------------------------------ }

{ These four are the whole reason the LEB and name failures are worded
  the way they are. The distinction the first two draw is upstream's, not
  ours: `too large` is a VALUE the width cannot hold, `too long` is an
  ENCODING that spends more bytes than the width allows — and one input
  can only be one of them, so the two must not be collapsed. }
procedure TBinaryTests.TestCanonicalLebAndNamePrefixes;
begin
  { Fifth byte of a u32 carrying bits above 32. }
  ExpectMessagePrefix('u32', 'over-wide u32', MSG_INTEGER_TOO_LARGE,
    [$80, $80, $80, $80, $10], wrcTopLevel);
  { A sixth byte for a u32, whatever it spells. }
  ExpectMessagePrefix('u32', 'over-long u32', MSG_INTEGER_TOO_LONG,
    [$80, $80, $80, $80, $80, $00], wrcTopLevel);
  { A signed encoding whose top bits are neither a sign extension nor
    zero is `too large` as well, not a family of its own. }
  ExpectMessagePrefix('i32', 'i32 without a full sign extension',
    MSG_INTEGER_TOO_LARGE, [$FF, $FF, $FF, $FF, $4F], wrcTopLevel);
  { $FF never begins a UTF-8 sequence. The side condition is in the
    binary grammar, so this is malformed, not invalid. }
  ExpectMessagePrefix('name', 'a name that is not UTF-8',
    MSG_MALFORMED_UTF8, [$01, $FF], wrcTopLevel);
end;

{ One truncation, two wordings, chosen by WHERE the reader sits — and
  `unexpected end` is deliberately a PREFIX of the section wording, so a
  script that asserts only the short form is satisfied by either. }
procedure TBinaryTests.TestTruncationPrefixFollowsContext;
var
  R, Sub: TWasmReader;
begin
  ExpectMessagePrefix('u32', 'truncation at top level',
    MSG_UNEXPECTED_END, [$80], wrcTopLevel);
  ExpectMessagePrefix('u32', 'truncation inside a section',
    MSG_UNEXPECTED_END_OF_SECTION, [$80], wrcSection);

  Expect<Boolean>(Copy(MSG_UNEXPECTED_END_OF_SECTION, 1,
    Length(MSG_UNEXPECTED_END)) = MSG_UNEXPECTED_END).ToBe(True);

  { A sub-reader INHERITS the context: a code entry cut out of a section
    body is still inside that section. }
  R := ReaderOver([$01, $02, $03]);
  R.Context := wrcSection;
  Sub := R.SubReader(2);
  Expect<Boolean>(Sub.Context = wrcSection).ToBe(True);
  Expect<string>(Sub.EndOfInputPrefix).ToBe(MSG_UNEXPECTED_END_OF_SECTION);
end;

{ The opcode byte is part of the prefix upstream matches, and it is
  spelled in lowercase hex with no `$` — `illegal opcode ff`. }
procedure TBinaryTests.TestIllegalOpcodeMessageIsLowercaseHex;
begin
  Expect<string>(Copy(IllegalOpcodeMessage($FF, 24), 1, 20))
    .ToBe('illegal opcode ff at');
  Expect<string>(Copy(IllegalOpcodeMessage($06, 3), 1, 17))
    .ToBe('illegal opcode 06');
end;

{ The fix's reason for being: a uN/sN's byte count is bounded by the type
  width regardless of framing, so an overlong or over-wide encoding is
  malformed even when a section boundary falls inside it. The reader must
  look past the SubReader's declared size — into the bytes that follow the
  section in the module buffer — to tell that apart from a real truncation,
  exactly as the reference decoder reads LEBs from the whole stream and
  checks the section size separately.
  https://webassembly.github.io/spec/core/binary/values.html#binary-int }
procedure TBinaryTests.TestOverlongLebClippedBySectionIsTooLong;
begin
  { A six-byte u32 whose fifth byte still sets its continuation bit, but a
    two-byte section body: the overlong bytes lie past the boundary, and
    the encoding is `too long` regardless. }
  ExpectSectionLebPrefix('u32', 'overlong u32 clipped by a section',
    MSG_INTEGER_TOO_LONG, [$80, $80, $80, $80, $80, $00, $AA, $BB], 2);
  { The same for a u64 (max ten bytes) and an s33 (max five). }
  ExpectSectionLebPrefix('u64', 'overlong u64 clipped by a section',
    MSG_INTEGER_TOO_LONG,
    [$80, $80, $80, $80, $80, $80, $80, $80, $80, $80, $00, $CC], 3);
  ExpectSectionLebPrefix('s33', 'overlong s33 clipped by a section',
    MSG_INTEGER_TOO_LONG, [$80, $80, $80, $80, $80, $00, $DD], 1);
end;

procedure TBinaryTests.TestOverWideLebClippedBySectionIsTooLarge;
begin
  { A five-byte u32 whose fifth byte carries bits above the 32nd, but a
    one-byte section body: `too large`, read from past the boundary. }
  ExpectSectionLebPrefix('u32', 'over-wide u32 clipped by a section',
    MSG_INTEGER_TOO_LARGE, [$80, $80, $80, $80, $10, $EE], 1);
  { A ten-byte u64 whose final byte sets unused bits — the exact shape of
    binary-leb128.wast's `minimum with unused bits set`. }
  ExpectSectionLebPrefix('u64', 'over-wide u64 clipped by a section',
    MSG_INTEGER_TOO_LARGE,
    [$82, $80, $80, $80, $80, $80, $80, $80, $80, $70, $FF], 4);
  { A signed encoding whose top bits are neither sign extension nor zero
    is `too large` as well, even when the section clips it. }
  ExpectSectionLebPrefix('i32', 'over-wide i32 clipped by a section',
    MSG_INTEGER_TOO_LARGE, [$FF, $FF, $FF, $FF, $4F, $99], 2);
end;

procedure TBinaryTests.TestTruncatedLebInSectionStaysUnexpectedEnd;
begin
  { The distinction that must NOT regress. A continuation runs to the end
    of the WHOLE buffer within the width limit: a genuine truncation, so
    `unexpected end`, not an integer error — the reader has no bytes left
    to prove the encoding overlong. Logical size equals the buffer, so
    there is nothing past the boundary either. }
  ExpectSectionLebPrefix('u32', 'u32 truncated at the buffer end',
    MSG_UNEXPECTED_END_OF_SECTION, [$80, $80], 2);
  { A within-width encoding that only completes by spilling past the
    section boundary is the same truncation the boundary stands for: the
    section is too small to hold it, so `unexpected end`, not an integer
    error — nothing here is overlong or over-wide. }
  ExpectSectionLebPrefix('u32', 'valid u32 straddling the section boundary',
    MSG_UNEXPECTED_END_OF_SECTION, [$81, $00, $AA], 1);
end;

procedure TBinaryTests.SetupTests;
begin
  Test('ReadByte and PeekByte track position', TestReadByteAdvances);
  Test('single-byte unsigned LEB128', TestUnsignedSingleByte);
  Test('multi-byte unsigned LEB128', TestUnsignedMultiByte);
  Test('u32 maximum', TestUnsignedU32Max);
  Test('u64 maximum', TestUnsignedU64Max);
  Test('signed LEB128 -1', TestSignedNegativeOne);
  Test('signed LEB128 -128', TestSignedTwoByteNegative);
  Test('signed LEB128 needs padding past bit 6', TestSignedPositivePadding);
  Test('signed LEB128 -123456', TestSignedMultiByteNegative);
  Test('i32 extremes', TestSignedI32Extremes);
  Test('i64 minimum', TestSignedI64Min);
  Test('rejects over-wide unsigned encodings', TestRejectsOverWideU32);
  Test('rejects over-long unsigned encodings', TestRejectsOverLongU32);
  Test('rejects over-wide signed encodings', TestRejectsOverWideI32);
  Test('rejects truncated encodings', TestRejectsTruncatedLeb);
  Test('fixed-width u32 is little-endian', TestFixedU32IsLittleEndian);
  Test('reads names', TestReadName);
  Test('rejects a name longer than the input', TestReadNameRejectsOverrun);
  Test('sub-readers are bounded', TestSubReaderIsBounded);
  Test('Remaining and Eof', TestRemainingAndEof);
  Test('accepts legal sign-filled encodings',
    TestAcceptsLegalSignFilledEncodings);
  Test('accepts legal zero-padded encodings',
    TestAcceptsLegalZeroPaddedEncodings);
  Test('s33 spans type codes and type indices',
    TestReadS33SpansTypeCodesAndIndices);
  Test('rejects names that are not valid UTF-8',
    TestReadNameRejectsInvalidUtf8);
  Test('accepts valid UTF-8 names at the boundaries',
    TestReadNameAcceptsValidUtf8);
  Test('Position setter seeks and bounds', TestPositionSetter);
  Test('canonical LEB128 and name message prefixes',
    TestCanonicalLebAndNamePrefixes);
  Test('the truncation prefix follows the reader context',
    TestTruncationPrefixFollowsContext);
  Test('the illegal-opcode message spells lowercase hex',
    TestIllegalOpcodeMessageIsLowercaseHex);
  Test('an overlong LEB clipped by a section is too long',
    TestOverlongLebClippedBySectionIsTooLong);
  Test('an over-wide LEB clipped by a section is too large',
    TestOverWideLebClippedBySectionIsTooLarge);
  Test('a truncated LEB inside a section stays unexpected end',
    TestTruncatedLebInSectionStaysUnexpectedEnd);
end;

begin
  TestRunnerProgram.AddSuite(TBinaryTests.Create('Wasm.Binary'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
