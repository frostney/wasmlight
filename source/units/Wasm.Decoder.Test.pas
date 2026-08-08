{ Unit suite for Wasm.Decoder. Modules are assembled byte-by-byte here
  rather than loaded from fixtures: every case is a specific malformation,
  and spelling it in bytes puts the defect next to the assertion. The
  broad well-formed corpus is the spec testsuite (docs/testing.md). }
program Wasm.Decoder.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
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
  for I := 0 to High(PRESCRIBED) - 1 do
  begin
    BuildModule([PRESCRIBED[I + 1], $00, PRESCRIBED[I], $00]);
    Pair := FBytes;
    AssertRejected(Format('id %d before id %d',
      [PRESCRIBED[I + 1], PRESCRIBED[I]]), WasRejected(Pair));
  end;
end;

procedure TDecoderTests.TestCustomSectionsDoNotResetOrdering;
begin
  { A custom section must be exempt from ordering WITHOUT clearing the
    high-water mark. If it reset the watermark, a repeated or descending
    known section on the far side of it would be accepted. }
  ExpectRejected('repeated memory across a custom section',
    [$05, $00, $00, $02, $01, Ord('x'), $05, $00]);
  ExpectRejected('descending known sections across a custom section',
    [$06, $00, $00, $02, $01, Ord('x'), $05, $00]);
end;

procedure TDecoderTests.TestWalksSections;
begin
  { type section, 2 bytes of body; function section, 1 byte of body. }
  DecodeBuilt([$01, $02, $AA, $BB,
               $03, $01, $CC]);

  Expect<Integer>(FModule.SectionCount).ToBe(2);

  Expect<Integer>(FModule[0].Id).ToBe(Ord(wsType));
  Expect<Integer>(Integer(FModule[0].BodyOffset)).ToBe(10);
  Expect<Integer>(Integer(FModule[0].BodySize)).ToBe(2);
  Expect<string>(FModule[0].DisplayName).ToBe('type');

  Expect<Integer>(FModule[1].Id).ToBe(Ord(wsFunction));
  Expect<Integer>(Integer(FModule[1].BodyOffset)).ToBe(14);
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
  ExpectRejected('descending section ids', [$03, $00, $01, $00]);
  { global (6) then memory (5) — adjacent in both id and prescribed
    order, so this fails under either rule. }
  ExpectRejected('global before memory', [$06, $00, $05, $00]);
  { code (10) then data count (12): ascending ids, but the data count
    section is prescribed BEFORE code, so this is out of order. A rule
    written on ids alone accepts this. }
  ExpectRejected('data count after code', [$0A, $00, $0C, $01, $00]);
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
               $0C, $01, $01,         { data count id 12, position 11 }
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
  ExpectRejected('two type sections', [$01, $00, $01, $00]);
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
  DecodeBuilt([$01, $00, $0A, $00]);

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
end;

begin
  TestRunnerProgram.AddSuite(TDecoderTests.Create('Wasm.Decoder'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
