{ Unit suite for Wasm.Decoder. Modules are assembled byte-by-byte here
  rather than loaded from fixtures: every case is a specific malformation,
  and spelling it in bytes puts the defect next to the assertion. The
  broad well-formed corpus is the spec testsuite (docs/testing.md). }
program Wasm.Decoder.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Module;

type
  TDecoderTests = class(TTestSuite)
  private
    FBytes: TWasmBytes;
    FModule: TWasmModule;

    { An 8-byte preamble followed by AValues. }
    procedure BuildModule(const AValues: array of Byte);
    procedure DecodeBuilt(const AValues: array of Byte);
    procedure ExpectRejected(const ADescription: string;
      const AValues: array of Byte);
    { Decodes ABytes and reports whether it was rejected. The assertion is
      made by the caller AFTER the try — a Fail() inside the try would be
      swallowed by the handler, and FPC will not parse a generic call as
      the lone statement of an `on ... do`. }
    function WasRejected(const ABytes: TWasmBytes): Boolean;
    { Asserts rejection and names the case in the failure message. Phrased
      as a value comparison rather than a bare Fail() so the test records
      an assertion even on the happy path. }
    procedure AssertRejected(const ADescription: string;
      const ARejected: Boolean);
    { Builds and decodes; returns the EWasmDecodeError message, or '' when
      the module was accepted. For asserting message PREFIXES — which are
      conformance surface (docs/roadmap.md, Track C). }
    function RejectionMessage(const AValues: array of Byte): string;
    { Asserts AMessage starts with APrefix, phrased so a failure prints
      the actual message ('' means the module was wrongly accepted). }
    procedure AssertMessagePrefix(const ADescription, AMessage,
      APrefix: string);
    procedure WriteVersion(var ABytes: TWasmBytes;
      const AB0, AB1, AB2, AB3: Byte);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestEmptyModule;
    procedure TestRejectsShortInput;
    procedure TestRejectsBadMagic;
    procedure TestRejectsUnsupportedVersion;
    procedure TestRejectsShortInputsOfEveryLength;
    procedure TestOrderIsPinnedForEveryAdjacentPair;
    procedure TestCustomSectionsDoNotResetOrdering;
    procedure TestWalksSections;
    procedure TestReadsCustomSectionName;
    procedure TestCustomSectionsAreExemptFromOrdering;
    procedure TestRejectsUnknownSectionId;
    procedure TestRejectsOversizedSection;
    procedure TestRejectsOutOfOrderSections;
    procedure TestAcceptsPrescribedOrderNotIdOrder;
    procedure TestRejectsDuplicateSection;
    procedure TestRejectsCustomNameOverrunningItsSection;
    procedure TestSectionLookup;
    procedure TestDecodesTypeFunctionCode;
    procedure TestDecodesGlobalExportStart;
    procedure TestRejectsFunctionCodeCountMismatch;
    procedure TestRejectsDataCountMismatch;
    procedure TestCustomSectionAmongPopulatedSections;
    procedure TestPreamblePrefixesSplitMagicFromTruncation;
    procedure TestSectionWalkMessagePrefixes;
    procedure TestCustomSectionErrorKeepsItsPrefix;
    procedure TestLebDiagnosticsSurviveCodeEntryFraming;
  end;

procedure TDecoderTests.BuildModule(const AValues: array of Byte);
var
  I: Integer;
begin
  SetLength(FBytes, 8 + Length(AValues));
  for I := 0 to 3 do
    FBytes[I] := WASM_MAGIC[I];
  FBytes[4] := WASM_BINARY_VERSION;
  FBytes[5] := 0;
  FBytes[6] := 0;
  FBytes[7] := 0;
  for I := 0 to High(AValues) do
    FBytes[8 + I] := AValues[I];
end;

procedure TDecoderTests.DecodeBuilt(const AValues: array of Byte);
begin
  BuildModule(AValues);
  DecodeModule(FBytes, FModule);
end;

function TDecoderTests.WasRejected(const ABytes: TWasmBytes): Boolean;
begin
  Result := False;
  try
    DecodeModule(ABytes, FModule);
  except
    on E: EWasmDecodeError do
      Result := True;
  end;
end;

procedure TDecoderTests.AssertRejected(const ADescription: string;
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

procedure TDecoderTests.ExpectRejected(const ADescription: string;
  const AValues: array of Byte);
begin
  BuildModule(AValues);
  AssertRejected(ADescription, WasRejected(FBytes));
end;

function TDecoderTests.RejectionMessage(
  const AValues: array of Byte): string;
begin
  BuildModule(AValues);
  Result := '';
  try
    DecodeModule(FBytes, FModule);
  except
    on E: EWasmDecodeError do
      Result := E.Message;
  end;
end;

procedure TDecoderTests.AssertMessagePrefix(const ADescription, AMessage,
  APrefix: string);
begin
  { The comparison carries the message slice, so a failure shows what was
    actually raised — and '' shows the module was wrongly ACCEPTED. }
  Expect<string>(ADescription + ': ' + Copy(AMessage, 1, Length(APrefix)))
    .ToBe(ADescription + ': ' + APrefix);
end;

procedure TDecoderTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TDecoderTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

procedure TDecoderTests.TestEmptyModule;
begin
  DecodeBuilt([]);
  Expect<Int64>(Int64(FModule.Version)).ToBe(WASM_BINARY_VERSION);
  Expect<Integer>(FModule.SectionCount).ToBe(0);
  Expect<Integer>(Integer(FModule.Size)).ToBe(8);
end;

procedure TDecoderTests.TestRejectsShortInput;
var
  Short: TWasmBytes;
begin
  SetLength(Short, 4);
  Short[0] := WASM_MAGIC[0];
  Short[1] := WASM_MAGIC[1];
  Short[2] := WASM_MAGIC[2];
  Short[3] := WASM_MAGIC[3];
  AssertRejected('input shorter than the preamble', WasRejected(Short));
end;

procedure TDecoderTests.TestRejectsBadMagic;
var
  Wrong: TWasmBytes;
  I: Integer;
begin
  SetLength(Wrong, 8);
  for I := 0 to 7 do
    Wrong[I] := 0;
  AssertRejected('all-zero magic', WasRejected(Wrong));

  { The case above does NOT isolate the magic: its version field is also
    zero, so the version check rejects it independently and this test
    passes even with the magic comparison deleted. Isolate it with a
    module whose version is correct and only the last magic byte wrong. }
  SetLength(Wrong, 8);
  Wrong[0] := WASM_MAGIC[0];
  Wrong[1] := WASM_MAGIC[1];
  Wrong[2] := WASM_MAGIC[2];
  Wrong[3] := $6E;                  { 'n' instead of 'm' }
  Wrong[4] := WASM_BINARY_VERSION;
  Wrong[5] := 0;
  Wrong[6] := 0;
  Wrong[7] := 0;
  AssertRejected('last magic byte wrong, version correct',
    WasRejected(Wrong));
end;

procedure TDecoderTests.WriteVersion(var ABytes: TWasmBytes;
  const AB0, AB1, AB2, AB3: Byte);
var
  I: Integer;
begin
  SetLength(ABytes, 8);
  for I := 0 to 3 do
    ABytes[I] := WASM_MAGIC[I];
  ABytes[4] := AB0;
  ABytes[5] := AB1;
  ABytes[6] := AB2;
  ABytes[7] := AB3;
end;

procedure TDecoderTests.TestRejectsUnsupportedVersion;
var
  Future: TWasmBytes;
begin
  WriteVersion(Future, 2, 0, 0, 0);
  AssertRejected('binary format version 2', WasRejected(Future));

  WriteVersion(Future, 0, 0, 0, 0);
  AssertRejected('binary format version 0', WasRejected(Future));

  { The version field is little-endian. Big-endian 1 is version
    16777216, and a decoder that read it the wrong way round would
    accept this — so it is the case that pins the byte order. }
  WriteVersion(Future, 0, 0, 0, 1);
  AssertRejected('byte-swapped version', WasRejected(Future));
end;

procedure TDecoderTests.TestRejectsShortInputsOfEveryLength;
var
  Short: TWasmBytes;
  Len, I: Integer;
begin
  { Nothing under the 8-byte preamble may decode, at any length. }
  for Len := 0 to 7 do
  begin
    SetLength(Short, Len);
    for I := 0 to Len - 1 do
      if I < 4 then
        Short[I] := WASM_MAGIC[I]
      else
        Short[I] := 0;
    AssertRejected(Format('input of %d byte(s)', [Len]),
      WasRejected(Short));
  end;
end;

procedure TDecoderTests.TestOrderIsPinnedForEveryAdjacentPair;
const
  { The grammar's prescribed order, as section ids. Reversing any
    adjacent pair must be rejected — otherwise the order table is only
    partly pinned, and a "tidy-up" that reorders it passes the suite. }
  PRESCRIBED: array[0..12] of Byte = (
    1, 2, 3, 4, 5, 13, 6, 7, 8, 9, 12, 10, 11);
var
  I: Integer;
  Pair: TWasmBytes;
begin
  { Bodies are decoded now, so each section carries the minimal VALID
    body — a single $00, which reads as the empty vector for the vec
    sections, function index 0 for start, and count 0 for data count. A
    size-0 body would be rejected as truncated before the ordering check
    on the SECOND header ever ran, and the test would pass for the wrong
    reason. }
  for I := 0 to High(PRESCRIBED) - 1 do
  begin
    BuildModule([PRESCRIBED[I + 1], $01, $00, PRESCRIBED[I], $01, $00]);
    Pair := FBytes;
    AssertRejected(Format('id %d before id %d',
      [PRESCRIBED[I + 1], PRESCRIBED[I]]), WasRejected(Pair));
  end;
end;

procedure TDecoderTests.TestCustomSectionsDoNotResetOrdering;
begin
  { A custom section must be exempt from ordering WITHOUT clearing the
    high-water mark. If it reset the watermark, a repeated or descending
    known section on the far side of it would be accepted. The known
    sections carry the minimal valid empty-vector body so the ordering
    check, not a body decode, is what rejects. }
  ExpectRejected('repeated memory across a custom section',
    [$05, $01, $00, $00, $02, $01, Ord('x'), $05, $01, $00]);
  ExpectRejected('descending known sections across a custom section',
    [$06, $01, $00, $00, $02, $01, Ord('x'), $05, $01, $00]);
end;

procedure TDecoderTests.TestWalksSections;
begin
  { type section, 4 bytes of body (one nullary functype); function
    section, 1 byte of body (empty vector). Bodies are decoded now, so
    they must be well-formed — the section-table claims under test are
    the ids, offsets, and sizes. }
  DecodeBuilt([$01, $04, $01, $60, $00, $00,
               $03, $01, $00]);

  Expect<Integer>(FModule.SectionCount).ToBe(2);

  Expect<Integer>(FModule[0].Id).ToBe(Ord(wsType));
  Expect<Integer>(Integer(FModule[0].BodyOffset)).ToBe(10);
  Expect<Integer>(Integer(FModule[0].BodySize)).ToBe(4);
  Expect<string>(FModule[0].DisplayName).ToBe('type');

  Expect<Integer>(FModule[1].Id).ToBe(Ord(wsFunction));
  Expect<Integer>(Integer(FModule[1].BodyOffset)).ToBe(16);
  Expect<Integer>(Integer(FModule[1].BodySize)).ToBe(1);
end;

procedure TDecoderTests.TestReadsCustomSectionName;
begin
  { custom section: size 6 = 1 name-length byte + 4 name bytes + 1 payload. }
  DecodeBuilt([$00, $06, $04, Ord('n'), Ord('a'), Ord('m'), Ord('e'), $FF]);

  Expect<Integer>(FModule.SectionCount).ToBe(1);
  Expect<Boolean>(FModule[0].IsCustom).ToBe(True);
  Expect<string>(FModule[0].Name).ToBe('name');
  Expect<string>(FModule[0].DisplayName).ToBe('custom "name"');
  Expect<Integer>(FModule.CustomSectionCount).ToBe(1);
end;

procedure TDecoderTests.TestCustomSectionsAreExemptFromOrdering;
begin
  { A custom section between two known sections must not disturb the
    ordering check, and must not itself be ordered. }
  DecodeBuilt([$05, $01, $00,                    { memory }
               $00, $02, $01, Ord('x'),          { custom "x" }
               $0B, $01, $00]);                  { data }

  Expect<Integer>(FModule.SectionCount).ToBe(3);
  Expect<Integer>(FModule[1].Id).ToBe(Ord(wsCustom));
  Expect<string>(FModule[1].Name).ToBe('x');
  Expect<Boolean>(FModule.HasSection(wsMemory)).ToBe(True);
  Expect<Boolean>(FModule.HasSection(wsData)).ToBe(True);
end;

procedure TDecoderTests.TestRejectsUnknownSectionId;
begin
  ExpectRejected('section id 14', [$0E, $00]);
  ExpectRejected('section id 255', [$FF, $00]);
end;

procedure TDecoderTests.TestRejectsOversizedSection;
begin
  { Declares 16 body bytes, supplies one. }
  ExpectRejected('section longer than the module', [$01, $10, $AA]);
end;

procedure TDecoderTests.TestRejectsOutOfOrderSections;
begin
  { function (3) then type (1). }
  ExpectRejected('descending section ids', [$03, $01, $00, $01, $01, $00]);
  { global (6) then memory (5) — adjacent in both id and prescribed
    order, so this fails under either rule. }
  ExpectRejected('global before memory', [$06, $01, $00, $05, $01, $00]);
  { code (10) then data count (12): ascending ids, but the data count
    section is prescribed BEFORE code, so this is out of order. A rule
    written on ids alone accepts this. }
  ExpectRejected('data count after code', [$0A, $01, $00, $0C, $01, $00]);
end;

procedure TDecoderTests.TestAcceptsPrescribedOrderNotIdOrder;
begin
  { The regression this suite previously missed. Section ids are not the
    encoding order: the data count section (id 12) is prescribed BEFORE
    the code section (id 10), and the tag section (id 13) between memory
    (id 5) and global (id 6). A decoder that requires increasing ids
    rejects this module, which is valid.
    https://webassembly.github.io/spec/core/binary/modules.html#binary-section }
  DecodeBuilt([$05, $01, $00,         { memory     id  5, position  5 }
               $0D, $01, $00,         { tag        id 13, position  6 }
               $06, $01, $00,         { global     id  6, position  7 }
               $09, $01, $00,         { element    id  9, position 10 }
               $0C, $01, $00,         { data count id 12, position 11 }
               $0A, $01, $00,         { code       id 10, position 12 }
               $0B, $01, $00]);       { data       id 11, position 13 }

  Expect<Integer>(FModule.SectionCount).ToBe(7);
  Expect<Boolean>(FModule.HasSection(wsDataCount)).ToBe(True);
  Expect<Boolean>(FModule.HasSection(wsCode)).ToBe(True);
  Expect<Boolean>(FModule.HasSection(wsTag)).ToBe(True);

  { Recorded in encounter order, which is the encoding order. }
  Expect<Integer>(FModule[4].Id).ToBe(Ord(wsDataCount));
  Expect<Integer>(FModule[5].Id).ToBe(Ord(wsCode));
end;

procedure TDecoderTests.TestRejectsDuplicateSection;
begin
  ExpectRejected('two type sections', [$01, $01, $00, $01, $01, $00]);
end;

procedure TDecoderTests.TestRejectsCustomNameOverrunningItsSection;
begin
  { The section body is 2 bytes but the name claims 9. Without the
    bounded sub-reader this would read into the following section. }
  ExpectRejected('custom name past its section',
    [$00, $02, $09, Ord('a'),
     $01, $00]);
end;

procedure TDecoderTests.TestSectionLookup;
var
  OutOfRange: TWasmSectionInfo;
  Raised: Boolean;
begin
  DecodeBuilt([$01, $01, $00, $0A, $01, $00]);

  Expect<Integer>(FModule.IndexOfSection(wsType)).ToBe(0);
  Expect<Integer>(FModule.IndexOfSection(wsCode)).ToBe(1);
  Expect<Integer>(FModule.IndexOfSection(wsExport)).ToBe(-1);
  Expect<Boolean>(FModule.HasSection(wsExport)).ToBe(False);
  Expect<Integer>(FModule.CustomSectionCount).ToBe(0);

  Raised := False;
  try
    OutOfRange := FModule[2];
    { Referenced so the read cannot be elided; never reached. }
    Fail('out-of-range section index was accepted: ' + OutOfRange.DisplayName);
  except
    on E: EWasmError do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TDecoderTests.TestDecodesTypeFunctionCode;
var
  RecType: TWasmRecType;
  Func: TWasmFuncType;
  Entry: TWasmCodeEntry;
begin
  { type: one functype i32 -> i32; function: one entry of type 0; code:
    one entry with two i64 locals in one group and a 3-byte body
    (local.get 0; end). }
  DecodeBuilt([$01, $06, $01, $60, $01, $7F, $01, $7F,
               $03, $02, $01, $00,
               $0A, $08, $01, $06, $01, $02, $7E, $20, $00, $0B]);

  { The type: the bare-comptype shorthand normalises to a final subtype
    with no supertypes in a rec group of one. }
  Expect<Integer>(FModule.TypeCount).ToBe(1);
  RecType := FModule.Types[0];
  Expect<Integer>(Length(RecType.SubTypes)).ToBe(1);
  Expect<Boolean>(RecType.SubTypes[0].IsFinal).ToBe(True);
  Expect<Integer>(Length(RecType.SubTypes[0].SuperTypes)).ToBe(0);
  Expect<Integer>(Ord(RecType.SubTypes[0].Comp.Kind)).ToBe(Ord(wckFunc));
  Func := RecType.SubTypes[0].Comp.Func;
  Expect<Integer>(Length(Func.Params)).ToBe(1);
  Expect<string>(Func.Params[0].Describe).ToBe('i32');
  Expect<Integer>(Length(Func.Results)).ToBe(1);
  Expect<string>(Func.Results[0].Describe).ToBe('i32');

  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(1);
  Expect<Integer>(Integer(FModule.FunctionTypeIndices[0])).ToBe(0);

  { The code entry. Offsets are absolute into the buffer: preamble 8,
    type section 8..15, function section 16..19, code body at 22 — count
    22, entry size 23, entry content 24.., body span 27..29. }
  Expect<Integer>(FModule.CodeEntryCount).ToBe(1);
  Entry := FModule.CodeEntries[0];
  Expect<Integer>(Length(Entry.Locals)).ToBe(1);
  Expect<Integer>(Integer(Entry.Locals[0].Count)).ToBe(2);
  Expect<string>(Entry.Locals[0].ValueType.Describe).ToBe('i64');
  Expect<Integer>(Integer(Entry.Body.Offset)).ToBe(27);
  Expect<Integer>(Integer(Entry.Body.Size)).ToBe(3);
end;

procedure TDecoderTests.TestDecodesGlobalExportStart;
var
  Global: TWasmGlobal;
  ExportEntry: TWasmExport;
begin
  { global: one (mut i32) with init `i32.const 0; end`; export: "g" as a
    global; start: function index 0. That the start index names no
    function is a VALIDATION defect, so this decodes. }
  DecodeBuilt([$06, $06, $01, $7F, $01, $41, $00, $0B,
               $07, $05, $01, $01, Ord('g'), $03, $00,
               $08, $01, $00]);

  Expect<Integer>(FModule.GlobalCount).ToBe(1);
  Global := FModule.Globals[0];
  Expect<Boolean>(Global.GlobalType.Mut).ToBe(True);
  Expect<string>(Global.GlobalType.ValueType.Describe).ToBe('i32');
  { The init expr span: global body at 10, count 10, valtype 11, mut 12,
    expr 13..15 including its `end`. }
  Expect<Integer>(Integer(Global.Init.Offset)).ToBe(13);
  Expect<Integer>(Integer(Global.Init.Size)).ToBe(3);

  Expect<Integer>(FModule.ExportCount).ToBe(1);
  ExportEntry := FModule.&Exports[0];
  Expect<string>(ExportEntry.Name).ToBe('g');
  Expect<Integer>(Ord(ExportEntry.Kind)).ToBe(Ord(wxkGlobal));
  Expect<Integer>(Integer(ExportEntry.Index)).ToBe(0);

  Expect<Boolean>(FModule.HasStart).ToBe(True);
  Expect<Integer>(Integer(FModule.StartFuncIndex)).ToBe(0);
end;

procedure TDecoderTests.TestRejectsFunctionCodeCountMismatch;
const
  { The upstream testsuite asserts this exact phrase, so it is
    conformance surface, not just a diagnostic (docs/roadmap.md).
    https://webassembly.github.io/spec/core/binary/modules.html#binary-module }
  PREFIX = 'function and code section have inconsistent lengths';
begin
  { One function declared, code section ABSENT — an absent section is
    the empty vector, so the lengths 1 and 0 disagree. }
  AssertMessagePrefix('function without code',
    RejectionMessage([$03, $02, $01, $00]), PREFIX);

  { One code entry, function section absent — the other direction. }
  AssertMessagePrefix('code without function',
    RejectionMessage([$0A, $04, $01, $02, $00, $0B]), PREFIX);

  { Both present, counts 2 vs 1. }
  AssertMessagePrefix('two functions, one code entry',
    RejectionMessage([$03, $03, $02, $00, $00,
                      $0A, $04, $01, $02, $00, $0B]), PREFIX);
end;

procedure TDecoderTests.TestRejectsDataCountMismatch;
const
  { Same status as the function/code phrase: the testsuite asserts it.
    https://webassembly.github.io/spec/core/binary/modules.html#binary-datacntsec }
  PREFIX = 'data count and data section have inconsistent lengths';
begin
  { Data count declares 1, data section absent (= empty vector). }
  AssertMessagePrefix('data count 1, no data section',
    RejectionMessage([$0C, $01, $01]), PREFIX);

  { Data count declares 0, data section holds one passive segment. }
  AssertMessagePrefix('data count 0, one data segment',
    RejectionMessage([$0C, $01, $00,
                      $0B, $04, $01, $01, $01, $AA]), PREFIX);
end;

procedure TDecoderTests.TestCustomSectionAmongPopulatedSections;
begin
  { A custom section sitting between decoded known sections must still be
    name-read and skipped, leaving the known-section content intact. }
  DecodeBuilt([$01, $04, $01, $60, $00, $00,       { type: () -> () }
               $00, $03, $01, Ord('m'), $EE,       { custom "m" + payload }
               $03, $02, $01, $00,                 { function: type 0 }
               $0A, $04, $01, $02, $00, $0B]);     { code: 1 empty body }

  Expect<Integer>(FModule.SectionCount).ToBe(4);
  Expect<Integer>(FModule.CustomSectionCount).ToBe(1);
  Expect<string>(FModule[1].Name).ToBe('m');
  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(1);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(1);
end;

{ --- canonical message prefixes ------------------------------------------ }

{ Four bytes that are not the magic is `magic header not detected`; four
  bytes that ARE the magic is `unexpected end`, because only the version
  is missing. The two are told apart by checking the magic BEFORE
  requiring the version's bytes — a single "do we have eight bytes" gate
  collapses them, and upstream asserts both. }
procedure TDecoderTests.TestPreamblePrefixesSplitMagicFromTruncation;
var
  Buf: TWasmBytes;
  I: Integer;

  function MessageFor(const ABytes: TWasmBytes): string;
  begin
    Result := '';
    try
      DecodeModule(ABytes, FModule);
    except
      on E: EWasmDecodeError do
        Result := E.Message;
    end;
  end;

begin
  { Exactly the magic, nothing after it. }
  SetLength(Buf, 4);
  for I := 0 to 3 do
    Buf[I] := WASM_MAGIC[I];
  AssertMessagePrefix('the magic alone', MessageFor(Buf),
    MSG_UNEXPECTED_END);

  { The same length, one byte off the magic. }
  Buf[3] := $6E;
  AssertMessagePrefix('four bytes that are not the magic', MessageFor(Buf),
    MSG_MAGIC_HEADER);

  { Nothing at all is still truncation, not a bad magic. }
  SetLength(Buf, 0);
  AssertMessagePrefix('no bytes at all', MessageFor(Buf),
    MSG_UNEXPECTED_END);

  { A complete preamble with the wrong version number. }
  SetLength(Buf, 8);
  for I := 0 to 3 do
    Buf[I] := WASM_MAGIC[I];
  Buf[4] := $0D;
  Buf[5] := 0;
  Buf[6] := 0;
  Buf[7] := 0;
  AssertMessagePrefix('version 13', MessageFor(Buf),
    MSG_UNKNOWN_BINARY_VERSION);
end;

procedure TDecoderTests.TestSectionWalkMessagePrefixes;
begin
  { An id no section uses. }
  AssertMessagePrefix('section id 14',
    RejectionMessage([$0E, $01, $00]), MSG_MALFORMED_SECTION_ID);

  { A type section claiming seven bytes with four left. }
  AssertMessagePrefix('a section longer than the bytes left',
    RejectionMessage([$01, $07, $02, $60, $00, $00]),
    MSG_LENGTH_OUT_OF_BOUNDS);

  { Export (prescribed position 8) before global (position 7). Upstream
    words an out-of-order section as content after the last section,
    because its decoder stops at the first section it cannot place. }
  AssertMessagePrefix('global after export',
    RejectionMessage([$07, $01, $00, $06, $01, $00]),
    MSG_UNEXPECTED_CONTENT);

  { The same comparison catches a repeat. }
  AssertMessagePrefix('two type sections',
    RejectionMessage([$01, $01, $00, $01, $01, $00]),
    MSG_UNEXPECTED_CONTENT);

  { A body the grammar finished with bytes to spare. }
  AssertMessagePrefix('a trailing byte inside a type section',
    RejectionMessage([$01, $02, $00, $00]), MSG_SECTION_SIZE_MISMATCH);
end;

{ A failure inside a custom section keeps ITS prefix; the section's
  location is appended. Wrapping it — `custom section at offset 8: ...` —
  hides the very prefix the harness matches on, which is what this case
  exists to prevent. The name here is one byte, $FF, which begins no
  UTF-8 sequence. }
procedure TDecoderTests.TestCustomSectionErrorKeepsItsPrefix;
begin
  AssertMessagePrefix('a custom section name that is not UTF-8',
    RejectionMessage([$00, $02, $01, $FF]), MSG_MALFORMED_UTF8);

  { And a custom section whose declared size runs past the input is the
    same `length out of bounds` as any other section. }
  AssertMessagePrefix('an oversized custom section',
    RejectionMessage([$00, $20, $01, $61]), MSG_LENGTH_OUT_OF_BOUNDS);
end;

procedure TDecoderTests.TestLebDiagnosticsSurviveCodeEntryFraming;
const
  PREFIX: array[0..16] of Byte = (
    $01, $04, $01, $60, $00, $00,       { type: () -> () }
    $03, $02, $01, $00,                   { one function of type 0 }
    $05, $03, $01, $00, $01,              { one i32 memory }
    $0A, $0B);                             { code section, 11-byte body }
var
  Values: TWasmBytes;

  function WithTail(const ATail: array of Byte): TWasmBytes;
  var
    I: Integer;
  begin
    SetLength(Result, Length(PREFIX) + Length(ATail));
    for I := 0 to High(PREFIX) do
      Result[I] := PREFIX[I];
    for I := 0 to High(ATail) do
      Result[Length(PREFIX) + I] := ATail[I];
  end;

begin
  { The code entry declares nine payload bytes. Its memarg u64 begins in
    that span but completes beyond it. `binary-int` still owns the integer's
    width diagnosis; the continuation bytes must not become section ids. }
  Values := WithTail([
    $01, $09,                               { one entry, size 9 }
    $00, $41, $00, $28, $02,                { locals; i32.const; load; align }
    $82, $80, $80, $80,                     { first four u64 bytes in entry }
    $80, $80, $80, $80, $80, $80, $00]);   { overlong continuation }
  AssertMessagePrefix('overlong memarg clipped by code entry',
    RejectionMessage(Values), MSG_INTEGER_TOO_LONG);

  Values := WithTail([
    $01, $09,
    $00, $41, $00, $28, $02,
    $82, $80, $80, $80,
    $80, $80, $80, $80, $80, $10]);        { unused u64 bits set }
  AssertMessagePrefix('over-wide memarg clipped by code entry',
    RejectionMessage(Values), MSG_INTEGER_TOO_LARGE);

  { `binary-comptype` uses the signed seven-bit discriminator space. $E0
    claims a continuation byte, which exceeds s7's one-byte limit before it
    can be treated as an unknown composite form. }
  AssertMessagePrefix('overlong composite-type discriminator',
    RejectionMessage([$01, $05, $01, $E0, $7F, $00, $00]),
    MSG_INTEGER_TOO_LONG);
end;

procedure TDecoderTests.SetupTests;
begin
  Test('decodes a module with no sections', TestEmptyModule);
  Test('rejects input shorter than the preamble', TestRejectsShortInput);
  Test('rejects wrong magic', TestRejectsBadMagic);
  Test('rejects an unsupported binary version', TestRejectsUnsupportedVersion);
  Test('rejects short inputs of every length',
    TestRejectsShortInputsOfEveryLength);
  Test('order is pinned for every adjacent pair',
    TestOrderIsPinnedForEveryAdjacentPair);
  Test('custom sections do not reset ordering',
    TestCustomSectionsDoNotResetOrdering);
  Test('walks the section sequence', TestWalksSections);
  Test('reads a custom section name', TestReadsCustomSectionName);
  Test('custom sections are exempt from ordering',
    TestCustomSectionsAreExemptFromOrdering);
  Test('rejects an unknown section id', TestRejectsUnknownSectionId);
  Test('rejects a section longer than the module', TestRejectsOversizedSection);
  Test('rejects out-of-order sections', TestRejectsOutOfOrderSections);
  Test('accepts prescribed order, which is not id order',
    TestAcceptsPrescribedOrderNotIdOrder);
  Test('rejects a duplicate known section', TestRejectsDuplicateSection);
  Test('rejects a custom name overrunning its section',
    TestRejectsCustomNameOverrunningItsSection);
  Test('looks sections up by id', TestSectionLookup);
  Test('decodes type + function + code end to end',
    TestDecodesTypeFunctionCode);
  Test('decodes global + export + start end to end',
    TestDecodesGlobalExportStart);
  Test('rejects function/code count mismatches',
    TestRejectsFunctionCodeCountMismatch);
  Test('rejects a data count mismatch', TestRejectsDataCountMismatch);
  Test('decodes known sections around a custom section',
    TestCustomSectionAmongPopulatedSections);
  Test('the preamble prefixes split a bad magic from a short input',
    TestPreamblePrefixesSplitMagicFromTruncation);
  Test('the section walk raises canonical message prefixes',
    TestSectionWalkMessagePrefixes);
  Test('a custom section failure keeps its own prefix',
    TestCustomSectionErrorKeepsItsPrefix);
  Test('LEB diagnostics survive code-entry framing',
    TestLebDiagnosticsSurviveCodeEntryFraming);
end;

begin
  TestRunnerProgram.AddSuite(TDecoderTests.Create('Wasm.Decoder'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
