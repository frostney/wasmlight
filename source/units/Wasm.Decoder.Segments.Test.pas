{ Unit suite for Wasm.Decoder.Segments' section decoders.

  The happy paths hand-assemble each section and pin the decoded model
  exactly — all eight element flag encodings with their differing table
  index / offset / elemkind / reftype / init shapes, code entries with
  run-length locals and the body span including its terminating `end`
  byte, all three data flag encodings with byte spans, and the data
  count. Span arithmetic is asserted against nonzero ABase values to
  prove offsets are absolute (ADR-0003).

  Malformed inputs are spelled as literal bytes next to the assertion:
  unassigned segment flags, nonzero elemkind bytes, code entry sizes
  that disagree with their content in both directions, a locals total
  past the grammar's list bound, truncated vectors and payloads, and
  trailing bytes after a section's declared content. }
program Wasm.Decoder.Segments.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Segments,
  Wasm.Module;

type
  TDecoderSegmentsTests = class(TTestSuite)
  private
    { The reader borrows its buffer, so the buffer must outlive every
      reader built over it — hence a suite field. }
    FBuffer: TWasmBytes;

    function ReaderOver(const AValues: array of Byte): TWasmReader;
    { Runs the decoder named by ASection over AValues into AModule with
      the given ABase. }
    procedure Decode(const ASection: string; const AValues: array of Byte;
      const ABase: NativeUInt; const AModule: TWasmModule);
    { Runs the decoder named by ASection over AValues and asserts it
      raises EWasmDecodeError. }
    procedure ExpectRejected(const ASection, ADescription: string;
      const AValues: array of Byte);
    procedure AssertRejected(const ADescription: string;
      const ARejected: Boolean);
    procedure AssertSpan(const AWhat: string; const ASpan: TWasmSpan;
      const AOffset, ASize: NativeUInt);
  public
    procedure SetupTests; override;

    procedure TestElementFlag0;
    procedure TestElementFlags1And2;
    procedure TestElementFlag3;
    procedure TestElementFlag4;
    procedure TestElementFlag5;
    procedure TestElementFlag6WithBase;
    procedure TestElementFlag7;
    procedure TestElementPaddedFlagLeb;
    procedure TestElementRejectsFlag8;
    procedure TestElementRejectsNonzeroElemKind;
    procedure TestElementRejectsBadRefType;
    procedure TestElementRejectsTruncatedVectors;
    procedure TestElementRejectsTrailingBytes;

    procedure TestCodeSectionTwoEntries;
    procedure TestCodeLocalsCountBoundary;
    procedure TestCodeRejectsEntrySizeTooSmall;
    procedure TestCodeRejectsEntrySizeTooLarge;
    procedure TestCodeRejectsEmptyBody;
    procedure TestCodeRejectsTooManyLocals;
    procedure TestCodeRejectsTruncatedEntryVector;
    procedure TestCodeRejectsTrailingBytes;

    procedure TestDataAllThreeFlags;
    procedure TestDataPaddedFlagLeb;
    procedure TestDataRejectsFlag3;
    procedure TestDataRejectsTruncatedBytes;
    procedure TestDataRejectsTruncatedVector;
    procedure TestDataRejectsTrailingBytes;

    procedure TestDataCount;
    procedure TestDataCountZero;
    procedure TestDataCountRejectsTrailingBytes;
    procedure TestDataCountRejectsEmptyBody;
  end;

function TDecoderSegmentsTests.ReaderOver(
  const AValues: array of Byte): TWasmReader;
var
  I: Integer;
begin
  SetLength(FBuffer, Length(AValues));
  for I := 0 to High(AValues) do
    FBuffer[I] := AValues[I];
  Result.InitFromBytes(FBuffer);
end;

procedure TDecoderSegmentsTests.Decode(const ASection: string;
  const AValues: array of Byte; const ABase: NativeUInt;
  const AModule: TWasmModule);
var
  Reader: TWasmReader;
begin
  if (ASection <> 'elem') and (ASection <> 'code')
     and (ASection <> 'data') and (ASection <> 'datacount') then
    Fail('unknown section kind ' + ASection);

  Reader := ReaderOver(AValues);
  if ASection = 'elem' then
    DecodeElementSection(Reader, ABase, AModule)
  else if ASection = 'code' then
    DecodeCodeSection(Reader, ABase, AModule)
  else if ASection = 'data' then
    DecodeDataSection(Reader, ABase, AModule)
  else
    DecodeDataCountSection(Reader, ABase, AModule);
end;

procedure TDecoderSegmentsTests.ExpectRejected(
  const ASection, ADescription: string; const AValues: array of Byte);
var
  Module: TWasmModule;
  Rejected: Boolean;
begin
  Module := TWasmModule.Create;
  try
    Rejected := False;

    { The assertion is made after the try, not inside the handler: a
      Fail() in the try block would be swallowed by the handler, and FPC
      will not parse a generic call as the lone statement of an
      `on ... do`. }
    try
      Decode(ASection, AValues, 0, Module);
    except
      on E: EWasmDecodeError do
        Rejected := True;
    end;

    AssertRejected(ADescription, Rejected);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.AssertRejected(const ADescription: string;
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

procedure TDecoderSegmentsTests.AssertSpan(const AWhat: string;
  const ASpan: TWasmSpan; const AOffset, ASize: NativeUInt);
begin
  { The description is embedded in the compared values, so a failure
    names the case — and the assertion can genuinely fail, unlike a
    bare Expect(AWhat).ToBe(AWhat). }
  Expect<string>(AWhat + ': ' + IntToStr(Int64(ASpan.Offset)) + '+'
      + IntToStr(Int64(ASpan.Size)))
    .ToBe(AWhat + ': ' + IntToStr(Int64(AOffset)) + '+'
      + IntToStr(Int64(ASize)));
end;

{ --- element section ----------------------------------------------------- }

procedure TDecoderSegmentsTests.TestElementFlag0;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    { Flag 0: active, implicit table 0, offset expr, vec(funcidx) — the
      NON-NULLABLE `(ref func)` implied with no type byte at all, because
      the production builds its elements as `(ref.func y) end`
      (binary-elem). Reading `funcref` here wrongly rejects the segment
      against a `(ref func)` table. }
    Decode('elem',
      [$01,                 { count 1 }
       $00,                 { flags 0 }
       $41, $00, $0B,       { offset: i32.const 0; end }
       $02, $03, $04],      { funcidx vec [3, 4] }
      0, Module);

    Expect<Int64>(Int64(Module.ElementCount)).ToBe(1);
    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemActive).ToBe(True);
    Expect<Int64>(Int64(Segment.TableIndex)).ToBe(0);
    AssertSpan('flag 0 offset expr', Segment.Offset, 2, 3);
    Expect<string>(Segment.RefType.Describe).ToBe('(ref func)');
    Expect<Boolean>(Segment.UsesExprs).ToBe(False);
    Expect<Int64>(Int64(Length(Segment.FuncIndices))).ToBe(2);
    Expect<Int64>(Int64(Segment.FuncIndices[0])).ToBe(3);
    Expect<Int64>(Int64(Segment.FuncIndices[1])).ToBe(4);
    Expect<Int64>(Int64(Length(Segment.InitExprs))).ToBe(0);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementFlags1And2;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    Decode('elem',
      [$02,                 { count 2 }
       { Flag 1: passive, elemkind ($00 = ref func), vec(funcidx). }
       $01, $00, $01, $05,
       { Flag 2: active, explicit table index, offset expr, elemkind,
         vec(funcidx). }
       $02, $01, $41, $01, $0B, $00, $02, $07, $08],
      0, Module);

    Expect<Int64>(Int64(Module.ElementCount)).ToBe(2);

    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemPassive).ToBe(True);
    { `elemkind ::= 0x00 => ref func` — non-nullable, as for flag 0. }
    Expect<string>(Segment.RefType.Describe).ToBe('(ref func)');
    Expect<Boolean>(Segment.UsesExprs).ToBe(False);
    Expect<Int64>(Int64(Length(Segment.FuncIndices))).ToBe(1);
    Expect<Int64>(Int64(Segment.FuncIndices[0])).ToBe(5);

    Segment := Module.Elements[1];
    Expect<Boolean>(Segment.Mode = wemActive).ToBe(True);
    Expect<Int64>(Int64(Segment.TableIndex)).ToBe(1);
    AssertSpan('flag 2 offset expr', Segment.Offset, 7, 3);
    Expect<string>(Segment.RefType.Describe).ToBe('(ref func)');
    Expect<Int64>(Int64(Length(Segment.FuncIndices))).ToBe(2);
    Expect<Int64>(Int64(Segment.FuncIndices[0])).ToBe(7);
    Expect<Int64>(Int64(Segment.FuncIndices[1])).ToBe(8);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementFlag3;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    { Flag 3: declarative, elemkind, vec(funcidx) — no table index and
      no offset expression; elemkind again yields `(ref func)`. }
    Decode('elem', [$01, $03, $00, $02, $01, $02], 0, Module);

    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemDeclarative).ToBe(True);
    Expect<string>(Segment.RefType.Describe).ToBe('(ref func)');
    Expect<Boolean>(Segment.UsesExprs).ToBe(False);
    Expect<Int64>(Int64(Length(Segment.FuncIndices))).ToBe(2);
    Expect<Int64>(Int64(Segment.FuncIndices[0])).ToBe(1);
    Expect<Int64>(Int64(Segment.FuncIndices[1])).ToBe(2);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementFlag4;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    { Flag 4: active, implicit table 0, offset expr, vec(expr) — the
      NULLABLE funcref implied, unlike flags 0..3: an element expression
      may be `ref.null func`, so the production is `elem (ref null func)`
      (binary-elem). This arm is the discriminating one. }
    Decode('elem',
      [$01,
       $04,
       $41, $00, $0B,        { offset: i32.const 0; end }
       $01,                  { one init expr }
       $D0, $70, $0B],       { ref.null func; end }
      0, Module);

    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemActive).ToBe(True);
    Expect<Int64>(Int64(Segment.TableIndex)).ToBe(0);
    AssertSpan('flag 4 offset expr', Segment.Offset, 2, 3);
    Expect<string>(Segment.RefType.Describe).ToBe('funcref');
    Expect<Boolean>(Segment.UsesExprs).ToBe(True);
    Expect<Int64>(Int64(Length(Segment.InitExprs))).ToBe(1);
    AssertSpan('flag 4 init expr', Segment.InitExprs[0], 6, 3);
    Expect<Int64>(Int64(Length(Segment.FuncIndices))).ToBe(0);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementFlag5;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    { Flag 5: passive, explicit reftype, vec(expr). }
    Decode('elem',
      [$01,
       $05,
       $6F,                  { externref }
       $01,
       $D0, $6F, $0B],       { ref.null extern; end }
      0, Module);

    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemPassive).ToBe(True);
    Expect<string>(Segment.RefType.Describe).ToBe('externref');
    Expect<Boolean>(Segment.UsesExprs).ToBe(True);
    Expect<Int64>(Int64(Length(Segment.InitExprs))).ToBe(1);
    AssertSpan('flag 5 init expr', Segment.InitExprs[0], 4, 3);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementFlag6WithBase;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    { Flag 6: active, explicit table index, offset expr, reftype,
      vec(expr) — decoded with ABase = 100 to pin that every span is
      ABSOLUTE, not section-relative. }
    Decode('elem',
      [$01,
       $06,
       $02,                  { table index 2 }
       $41, $2A, $0B,        { offset: i32.const 42; end }
       $70,                  { funcref, spelled explicitly }
       $02,                  { two init exprs }
       $D0, $70, $0B,        { ref.null func; end }
       $D2, $05, $0B],       { ref.func 5; end }
      100, Module);

    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemActive).ToBe(True);
    Expect<Int64>(Int64(Segment.TableIndex)).ToBe(2);
    AssertSpan('flag 6 offset expr', Segment.Offset, 103, 3);
    Expect<string>(Segment.RefType.Describe).ToBe('funcref');
    Expect<Boolean>(Segment.UsesExprs).ToBe(True);
    Expect<Int64>(Int64(Length(Segment.InitExprs))).ToBe(2);
    AssertSpan('flag 6 init expr 0', Segment.InitExprs[0], 108, 3);
    AssertSpan('flag 6 init expr 1', Segment.InitExprs[1], 111, 3);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementFlag7;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    { Flag 7: declarative, explicit reftype, vec(expr). }
    Decode('elem',
      [$01, $07, $70, $01, $D0, $70, $0B], 0, Module);

    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemDeclarative).ToBe(True);
    Expect<string>(Segment.RefType.Describe).ToBe('funcref');
    Expect<Boolean>(Segment.UsesExprs).ToBe(True);
    Expect<Int64>(Int64(Length(Segment.InitExprs))).ToBe(1);
    AssertSpan('flag 7 init expr', Segment.InitExprs[0], 4, 3);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementPaddedFlagLeb;
var
  Module: TWasmModule;
  Segment: TWasmElemSegment;
begin
  Module := TWasmModule.Create;
  try
    { The segment flag is an ordinary u32, so the zero-padded spelling
      $80 $00 of flag 0 is well-formed — the flag values select
      productions, but their ENCODING admits everything uN does. }
    Decode('elem',
      [$01,                 { count 1 }
       $80, $00,            { flags 0, padded LEB }
       $41, $00, $0B,       { offset: i32.const 0; end }
       $01, $03],           { funcidx vec [3] }
      0, Module);

    Segment := Module.Elements[0];
    Expect<Boolean>(Segment.Mode = wemActive).ToBe(True);
    AssertSpan('padded elem flag offset expr', Segment.Offset, 3, 3);
    Expect<Int64>(Int64(Length(Segment.FuncIndices))).ToBe(1);
    Expect<Int64>(Int64(Segment.FuncIndices[0])).ToBe(3);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestElementRejectsFlag8;
begin
  { The flag bitfield has exactly eight assigned values. }
  ExpectRejected('elem', 'element flags 8', [$01, $08]);
  ExpectRejected('elem', 'element flags 42', [$01, $2A]);
end;

procedure TDecoderSegmentsTests.TestElementRejectsNonzeroElemKind;
begin
  { elemkind ::= 0x00 is the only assigned production. }
  ExpectRejected('elem', 'elemkind $01 under flag 1',
    [$01, $01, $01, $01, $05]);
  ExpectRejected('elem', 'elemkind $FF under flag 3',
    [$01, $03, $FF, $01, $05]);
end;

procedure TDecoderSegmentsTests.TestElementRejectsBadRefType;
begin
  { Flag 5 carries a reftype; a number type is not one. }
  ExpectRejected('elem', 'numeric reftype under flag 5',
    [$01, $05, $7F, $00]);
end;

procedure TDecoderSegmentsTests.TestElementRejectsTruncatedVectors;
begin
  { funcidx vec declares two entries, carries one. }
  ExpectRejected('elem', 'truncated funcidx vector',
    [$01, $00, $41, $00, $0B, $02, $03]);
  { expr vec declares two exprs, carries one. }
  ExpectRejected('elem', 'truncated init expr vector',
    [$01, $05, $70, $02, $D0, $70, $0B]);
  { Segment vec declares two segments, carries one. }
  ExpectRejected('elem', 'truncated segment vector',
    [$02, $01, $00, $01, $05]);
  ExpectRejected('elem', 'empty body', []);
end;

procedure TDecoderSegmentsTests.TestElementRejectsTrailingBytes;
begin
  { Content decodes fine, but the section body is not exhausted. }
  ExpectRejected('elem', 'trailing bytes after segments',
    [$01, $01, $00, $01, $05, $FF]);
end;

{ --- code section -------------------------------------------------------- }

procedure TDecoderSegmentsTests.TestCodeSectionTwoEntries;
var
  Module: TWasmModule;
  Entry: TWasmCodeEntry;
begin
  Module := TWasmModule.Create;
  try
    { Two entries, decoded with ABase = 50. Entry one: size 7 = locals
      vec (two groups: 2 x i32, 1 x i64) + body `nop; end`. Entry two:
      size 2 = empty locals vec + body `end`. }
    Decode('code',
      [$02,                       { count 2 }
       $07,                       { entry 1 size }
       $02, $02, $7F, $01, $7E,   { locals: 2 i32, 1 i64 }
       $01, $0B,                  { body: nop; end }
       $02,                       { entry 2 size }
       $00,                       { no locals groups }
       $0B],                      { body: end }
      50, Module);

    Expect<Int64>(Int64(Module.CodeEntryCount)).ToBe(2);

    Entry := Module.CodeEntries[0];
    Expect<Int64>(Int64(Length(Entry.Locals))).ToBe(2);
    Expect<Int64>(Int64(Entry.Locals[0].Count)).ToBe(2);
    Expect<string>(Entry.Locals[0].ValueType.Describe).ToBe('i32');
    Expect<Int64>(Int64(Entry.Locals[1].Count)).ToBe(1);
    Expect<string>(Entry.Locals[1].ValueType.Describe).ToBe('i64');
    { The body span runs from after the locals to the end of the entry,
      terminating `end` byte INCLUDED: section bytes 7..8, so absolute
      57 with size 2. }
    AssertSpan('entry 1 body', Entry.Body, 57, 2);

    Entry := Module.CodeEntries[1];
    Expect<Int64>(Int64(Length(Entry.Locals))).ToBe(0);
    { Just the `end` byte: section byte 11, absolute 61, size 1. }
    AssertSpan('entry 2 body', Entry.Body, 61, 1);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestCodeLocalsCountBoundary;
var
  Module: TWasmModule;
begin
  Module := TWasmModule.Create;
  try
    { A single group of 2^32-1 locals sits exactly AT the list bound
      (syntax-list) and must decode; only exceeding it is malformed. }
    Decode('code',
      [$01, $08,
       $01, $FF, $FF, $FF, $FF, $0F, $7F,  { one group: 2^32-1 x i32 }
       $0B],
      0, Module);

    Expect<Int64>(Int64(Module.CodeEntries[0].Locals[0].Count))
      .ToBe(Int64($FFFFFFFF));
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestCodeRejectsEntrySizeTooSmall;
begin
  { The size prefix says 1 byte, but the locals vector inside needs
    more — the entry's content is cut off by its own declared size. }
  ExpectRejected('code', 'entry size smaller than locals',
    [$01, $01, $01]);
end;

procedure TDecoderSegmentsTests.TestCodeRejectsEntrySizeTooLarge;
begin
  { The size prefix says 5 bytes, but only 2 remain in the section. }
  ExpectRejected('code', 'entry size larger than section',
    [$01, $05, $00, $0B]);
end;

procedure TDecoderSegmentsTests.TestCodeRejectsEmptyBody;
begin
  { The size covers exactly the locals vector, leaving zero bytes of
    body — but an expr is at least its `end` byte. }
  ExpectRejected('code', 'entry with no body bytes',
    [$01, $01, $00]);
end;

procedure TDecoderSegmentsTests.TestCodeRejectsTooManyLocals;
begin
  { Two groups of 2^32-1 locals each: the EXPANDED sequence exceeds the
    list bound of 2^32-1 elements, which binary-codesec makes MALFORMED
    — the widely-tested "too many locals" rule is a decode error, not a
    validation one. }
  ExpectRejected('code', 'locals total exceeds 2^32-1',
    [$01, $0E,
     $02,
     $FF, $FF, $FF, $FF, $0F, $7F,
     $FF, $FF, $FF, $FF, $0F, $7E,
     $0B]);
end;

procedure TDecoderSegmentsTests.TestCodeRejectsTruncatedEntryVector;
begin
  { Entry vec declares two entries, carries one. }
  ExpectRejected('code', 'truncated entry vector',
    [$02, $02, $00, $0B]);
  ExpectRejected('code', 'empty body', []);
end;

procedure TDecoderSegmentsTests.TestCodeRejectsTrailingBytes;
begin
  ExpectRejected('code', 'trailing bytes after entries',
    [$01, $02, $00, $0B, $AA]);
end;

{ --- data section -------------------------------------------------------- }

procedure TDecoderSegmentsTests.TestDataAllThreeFlags;
var
  Module: TWasmModule;
  Segment: TWasmDataSegment;
begin
  Module := TWasmModule.Create;
  try
    { All three productions in one section, decoded with ABase = 10. }
    Decode('data',
      [$03,                       { count 3 }
       { Flag 0: active, implicit memory 0, offset expr, bytes. }
       $00, $41, $00, $0B, $03, $AA, $BB, $CC,
       { Flag 1: passive, bytes only. }
       $01, $02, $11, $22,
       { Flag 2: active, explicit memory index, offset expr, bytes. }
       $02, $05, $41, $01, $0B, $00],
      10, Module);

    Expect<Int64>(Int64(Module.DataSegmentCount)).ToBe(3);

    Segment := Module.DataSegments[0];
    Expect<Boolean>(Segment.Mode = wdmActive).ToBe(True);
    Expect<Int64>(Int64(Segment.MemIndex)).ToBe(0);
    AssertSpan('flag 0 offset expr', Segment.Offset, 12, 3);
    AssertSpan('flag 0 bytes', Segment.Bytes, 16, 3);

    Segment := Module.DataSegments[1];
    Expect<Boolean>(Segment.Mode = wdmPassive).ToBe(True);
    AssertSpan('flag 1 bytes', Segment.Bytes, 21, 2);

    Segment := Module.DataSegments[2];
    Expect<Boolean>(Segment.Mode = wdmActive).ToBe(True);
    Expect<Int64>(Int64(Segment.MemIndex)).ToBe(5);
    AssertSpan('flag 2 offset expr', Segment.Offset, 25, 3);
    { An empty payload is a zero-size span, still positioned. }
    AssertSpan('flag 2 bytes', Segment.Bytes, 29, 0);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestDataPaddedFlagLeb;
var
  Module: TWasmModule;
  Segment: TWasmDataSegment;
begin
  Module := TWasmModule.Create;
  try
    { Same rule as the element flag: a u32, so $80 $00 spells flag 0
      and decodes fine. }
    Decode('data',
      [$01,                 { count 1 }
       $80, $00,            { flags 0, padded LEB }
       $41, $00, $0B,       { offset: i32.const 0; end }
       $01, $AA],           { one payload byte }
      0, Module);

    Segment := Module.DataSegments[0];
    Expect<Boolean>(Segment.Mode = wdmActive).ToBe(True);
    AssertSpan('padded data flag offset expr', Segment.Offset, 3, 3);
    AssertSpan('padded data flag bytes', Segment.Bytes, 7, 1);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestDataRejectsFlag3;
begin
  { Bits 0 and 1 together (passive + memory index) match no production,
    and neither does anything higher. }
  ExpectRejected('data', 'data flags 3', [$01, $03]);
  ExpectRejected('data', 'data flags 42', [$01, $2A]);
end;

procedure TDecoderSegmentsTests.TestDataRejectsTruncatedBytes;
begin
  { Payload declares four bytes, carries two. }
  ExpectRejected('data', 'truncated payload',
    [$01, $01, $04, $AA, $BB]);
end;

procedure TDecoderSegmentsTests.TestDataRejectsTruncatedVector;
begin
  { Segment vec declares two segments, carries one. }
  ExpectRejected('data', 'truncated segment vector',
    [$02, $01, $00]);
  ExpectRejected('data', 'empty body', []);
end;

procedure TDecoderSegmentsTests.TestDataRejectsTrailingBytes;
begin
  ExpectRejected('data', 'trailing bytes after segments',
    [$01, $01, $01, $AA, $FF]);
end;

{ --- data count section -------------------------------------------------- }

procedure TDecoderSegmentsTests.TestDataCount;
var
  Module: TWasmModule;
begin
  Module := TWasmModule.Create;
  try
    Decode('datacount', [$05], 0, Module);
    Expect<Boolean>(Module.HasDataCount).ToBe(True);
    Expect<Int64>(Int64(Module.DataCount)).ToBe(5);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestDataCountZero;
var
  Module: TWasmModule;
begin
  Module := TWasmModule.Create;
  try
    { Zero is a value, not an absence: HasDataCount still flips. }
    Decode('datacount', [$00], 0, Module);
    Expect<Boolean>(Module.HasDataCount).ToBe(True);
    Expect<Int64>(Int64(Module.DataCount)).ToBe(0);
  finally
    Module.Free;
  end;
end;

procedure TDecoderSegmentsTests.TestDataCountRejectsTrailingBytes;
begin
  { The section body is a single u32 and nothing else. }
  ExpectRejected('datacount', 'trailing byte after count', [$05, $00]);
end;

procedure TDecoderSegmentsTests.TestDataCountRejectsEmptyBody;
begin
  ExpectRejected('datacount', 'empty body', []);
end;

procedure TDecoderSegmentsTests.SetupTests;
begin
  Test('element flag 0: active, implicit table, funcidx list',
    TestElementFlag0);
  Test('element flags 1 and 2: passive and explicit-table elemkind forms',
    TestElementFlags1And2);
  Test('element flag 3: declarative funcidx list', TestElementFlag3);
  Test('element flag 4: active, implicit table, expr list',
    TestElementFlag4);
  Test('element flag 5: passive reftype expr list', TestElementFlag5);
  Test('element flag 6: explicit table, reftype, absolute spans',
    TestElementFlag6WithBase);
  Test('element flag 7: declarative reftype expr list', TestElementFlag7);
  Test('element flag in padded LEB decodes', TestElementPaddedFlagLeb);
  Test('element rejects flags 8 and above', TestElementRejectsFlag8);
  Test('element rejects nonzero elemkind',
    TestElementRejectsNonzeroElemKind);
  Test('element rejects malformed reftype', TestElementRejectsBadRefType);
  Test('element rejects truncated vectors',
    TestElementRejectsTruncatedVectors);
  Test('element rejects trailing bytes', TestElementRejectsTrailingBytes);

  Test('code section: two entries with exact body spans',
    TestCodeSectionTwoEntries);
  Test('code locals count at the list bound decodes',
    TestCodeLocalsCountBoundary);
  Test('code rejects entry size smaller than content',
    TestCodeRejectsEntrySizeTooSmall);
  Test('code rejects entry size larger than section',
    TestCodeRejectsEntrySizeTooLarge);
  Test('code rejects entries with no body bytes', TestCodeRejectsEmptyBody);
  Test('code rejects too many locals', TestCodeRejectsTooManyLocals);
  Test('code rejects truncated entry vector',
    TestCodeRejectsTruncatedEntryVector);
  Test('code rejects trailing bytes', TestCodeRejectsTrailingBytes);

  Test('data section: all three flag forms', TestDataAllThreeFlags);
  Test('data flag in padded LEB decodes', TestDataPaddedFlagLeb);
  Test('data rejects flags 3 and above', TestDataRejectsFlag3);
  Test('data rejects truncated payload', TestDataRejectsTruncatedBytes);
  Test('data rejects truncated segment vector',
    TestDataRejectsTruncatedVector);
  Test('data rejects trailing bytes', TestDataRejectsTrailingBytes);

  Test('data count section', TestDataCount);
  Test('data count of zero still counts as present', TestDataCountZero);
  Test('data count rejects trailing bytes',
    TestDataCountRejectsTrailingBytes);
  Test('data count rejects an empty body', TestDataCountRejectsEmptyBody);
end;

begin
  TestRunnerProgram.AddSuite(
    TDecoderSegmentsTests.Create('Wasm.Decoder.Segments'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
