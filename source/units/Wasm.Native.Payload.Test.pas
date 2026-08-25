{ Unit suite for Wasm.Native.Payload — the embedded native-executable payload
  reader/writer, identity hashes, and every structural reject (ADR-0015).

  The payload's whole value is that what the writer laid down the reader reads
  back, and that a corrupt, truncated, overflowing, duplicated, or incomplete
  file is rejected with a DISTINCT reason rather than misread. Malformed cases
  are spelled as literal bytes next to the assertion (AGENTS.md); extent
  boundaries are driven as a table so every directory field is covered.

  Every test asserts an outcome (never only Fail on a bad path) — a test that
  records no assertion is failed by the runner. }
program Wasm.Native.Payload.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Native.Payload;

type
  TExtentCase = record
    Name: string;
    OffsetField: UInt32;
    SizeField: UInt32;
    Expected: TWasmNativePayloadParseResult;
  end;

  TNativePayloadTests = class(TTestSuite)
  private
    function SampleModule: TWasmBytes;
    function SampleCode: TWasmNativeCodeRecord;
    function SampleParams: TWasmNativePayloadWriteParams;
    function WriteSample: TWasmBytes;
    procedure PatchU32(var ABytes: TWasmBytes; const AOffset: Integer;
      const AValue: UInt32);
    procedure PatchU64(var ABytes: TWasmBytes; const AOffset: Integer;
      const AValue: UInt64);
    procedure PatchHash128(var ABytes: TWasmBytes; const AOffset: Integer;
      const AHash: TWasmNativeHash128);
    procedure RecomputeBodyChecksum(var ABytes: TWasmBytes);
    procedure RewriteCodeSection(var AEncoded: TWasmBytes;
      const APayload: TWasmNativePayload; const ANewCode: TWasmBytes);
    procedure ExpectParse(const ABytes: TWasmBytes;
      const AExpected: TWasmNativePayloadParseResult);
  public
    procedure SetupTests; override;

    procedure TestRoundTripHeader;
    procedure TestRoundTripRecords;
    procedure TestEmptyPlanAndCaps;
    procedure TestHash128EmptyIsOffsetBasis;
    procedure TestHash128Deterministic;
    procedure TestHash64Deterministic;
    procedure TestRejectLiteralTruncatedHeader;
    procedure TestRejectLiteralBadMagic;
    procedure TestRejectLiteralIncompatibleVersion;
    procedure TestRejectLiteralOverflowingSectionCount;
    procedure TestRejectLiteralDirectoryAddOverflow;
    procedure TestRejectLiteralShortDirectory;
    procedure TestRejectBadChecksum;
    procedure TestRejectIdentityMismatch;
    procedure TestRejectDuplicateKind;
    procedure TestRejectMissingRequired;
    procedure TestRejectUnknownSection;
    procedure TestRejectBadSectionHash;
    procedure TestRejectEmptyFunctionCode;
    procedure TestRejectOverflowingFuncCount;
    procedure TestRejectOversizedCodeLength;
    procedure TestRejectEntryOffsetPastCode;
    procedure TestExtentBoundaryTable;
    procedure TestWriterRejectsEmptyModule;
    procedure TestWriterRejectsEmptyFunctionCode;
    procedure TestWriterRejectsHashMismatch;
  end;

function BytesOf(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function BytesEqual(const A, B: TWasmBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

function TNativePayloadTests.SampleModule: TWasmBytes;
begin
  { A literal 8-byte stand-in for original module bytes — not a wasm module;
    this suite tests the container, not decode. }
  Result := BytesOf([$00, $61, $73, $6D, $01, $00, $00, $00]);
end;

function TNativePayloadTests.SampleCode: TWasmNativeCodeRecord;
begin
  Result.FuncIrIndex := 0;
  Result.RegisterCount := 5;
  Result.EntryOffset := 0;
  { A non-16-aligned length so the writer's code-region padding is exercised. }
  Result.Code := BytesOf([$90, $91, $92, $93, $94, $95, $96]);
end;

function TNativePayloadTests.SampleParams: TWasmNativePayloadWriteParams;
var
  Funcs: TWasmNativeCodeRecords;
begin
  Result.IrFormatVer := 2;
  Result.TargetArch := WNEP_ARCH_AARCH64;
  Result.TargetOs := WNEP_OS_DARWIN;
  Result.Flags := 0;
  Result.AbiFingerprint := UInt64($0123456789ABCDEF);
  Result.ModuleBytes := SampleModule;
  Result.ModuleHash := WnepHash128Bytes(Result.ModuleBytes);
  Result.ShellHash.Lo := UInt64($1111222233334444);
  Result.ShellHash.Hi := UInt64($5555666677778888);
  SetLength(Funcs, 1);
  Funcs[0] := SampleCode;
  Result.Funcs := Funcs;
  Result.ConnectorPlan := BytesOf([$C0, $DE]);
  Result.CapabilitySet := BytesOf([$CA, $B0]);
end;

function TNativePayloadTests.WriteSample: TWasmBytes;
begin
  Result := WriteNativePayload(SampleParams);
end;

procedure TNativePayloadTests.PatchU32(var ABytes: TWasmBytes;
  const AOffset: Integer; const AValue: UInt32);
begin
  ABytes[AOffset] := Byte(AValue);
  ABytes[AOffset + 1] := Byte(AValue shr 8);
  ABytes[AOffset + 2] := Byte(AValue shr 16);
  ABytes[AOffset + 3] := Byte(AValue shr 24);
end;

procedure TNativePayloadTests.PatchU64(var ABytes: TWasmBytes;
  const AOffset: Integer; const AValue: UInt64);
begin
  PatchU32(ABytes, AOffset, UInt32(AValue));
  PatchU32(ABytes, AOffset + 4, UInt32(AValue shr 32));
end;

procedure TNativePayloadTests.PatchHash128(var ABytes: TWasmBytes;
  const AOffset: Integer; const AHash: TWasmNativeHash128);
begin
  PatchU64(ABytes, AOffset, AHash.Lo);
  PatchU64(ABytes, AOffset + 8, AHash.Hi);
end;

procedure TNativePayloadTests.RecomputeBodyChecksum(var ABytes: TWasmBytes);
var
  Body: TWasmBytes;
  Checksum: UInt64;
  I: Integer;
begin
  SetLength(Body, Length(ABytes) - WNEP_HEADER_SIZE);
  for I := 0 to High(Body) do
    Body[I] := ABytes[WNEP_HEADER_SIZE + I];
  if Length(Body) = 0 then
    Checksum := WnepHash64(nil, 0)
  else
    Checksum := WnepHash64(@Body[0], NativeUInt(Length(Body)));
  PatchU64(ABytes, WNEP_SELFCHECKSUM_OFFSET, Checksum);
end;

procedure TNativePayloadTests.ExpectParse(const ABytes: TWasmBytes;
  const AExpected: TWasmNativePayloadParseResult);
var
  Payload: TWasmNativePayload;
  Res: TWasmNativePayloadParseResult;
begin
  Res := ParseNativePayload(ABytes, Payload);
  Expect<Integer>(Ord(Res)).ToBe(Ord(AExpected));
end;

procedure TNativePayloadTests.TestRoundTripHeader;
var
  Params: TWasmNativePayloadWriteParams;
  Encoded: TWasmBytes;
  Payload: TWasmNativePayload;
  Res: TWasmNativePayloadParseResult;
begin
  Params := SampleParams;
  Encoded := WriteNativePayload(Params);
  Res := ParseNativePayload(Encoded, Payload);
  Expect<Integer>(Ord(Res)).ToBe(Ord(nprOk));
  Expect<Integer>(Integer(Payload.Header.FormatVer)).ToBe(Integer(WNEP_FORMAT_VERSION));
  Expect<Integer>(Integer(Payload.Header.IrFormatVer)).ToBe(2);
  Expect<Integer>(Integer(Payload.Header.TargetArch)).ToBe(Integer(WNEP_ARCH_AARCH64));
  Expect<Integer>(Integer(Payload.Header.TargetOs)).ToBe(Integer(WNEP_OS_DARWIN));
  Expect<UInt64>(Payload.Header.AbiFingerprint).ToBe(UInt64($0123456789ABCDEF));
  Expect<Boolean>(WnepHash128Equal(Payload.Header.ModuleHash, Params.ModuleHash)).ToBe(True);
  Expect<UInt64>(Payload.Header.ShellHash.Lo).ToBe(UInt64($1111222233334444));
  Expect<UInt64>(Payload.Header.ShellHash.Hi).ToBe(UInt64($5555666677778888));
  Expect<Integer>(Integer(Payload.Header.SectionCount)).ToBe(4);
end;

procedure TNativePayloadTests.TestRoundTripRecords;
var
  Params: TWasmNativePayloadWriteParams;
  Encoded: TWasmBytes;
  Payload: TWasmNativePayload;
  Res: TWasmNativePayloadParseResult;
begin
  Params := SampleParams;
  Encoded := WriteNativePayload(Params);
  Res := ParseNativePayload(Encoded, Payload);
  Expect<Integer>(Ord(Res)).ToBe(Ord(nprOk));
  Expect<Boolean>(BytesEqual(Payload.ModuleBytes, Params.ModuleBytes)).ToBe(True);
  Expect<Integer>(Length(Payload.Funcs)).ToBe(1);
  Expect<Integer>(Integer(Payload.Funcs[0].FuncIrIndex)).ToBe(0);
  Expect<Integer>(Integer(Payload.Funcs[0].RegisterCount)).ToBe(5);
  Expect<Integer>(Integer(Payload.Funcs[0].EntryOffset)).ToBe(0);
  Expect<Boolean>(BytesEqual(Payload.Funcs[0].Code, Params.Funcs[0].Code)).ToBe(True);
  Expect<Boolean>(BytesEqual(Payload.ConnectorPlan, Params.ConnectorPlan)).ToBe(True);
  Expect<Boolean>(BytesEqual(Payload.CapabilitySet, Params.CapabilitySet)).ToBe(True);
end;

procedure TNativePayloadTests.TestEmptyPlanAndCaps;
var
  Params: TWasmNativePayloadWriteParams;
  Encoded: TWasmBytes;
  Payload: TWasmNativePayload;
  Res: TWasmNativePayloadParseResult;
begin
  Params := SampleParams;
  Params.ConnectorPlan := nil;
  Params.CapabilitySet := nil;
  Encoded := WriteNativePayload(Params);
  Res := ParseNativePayload(Encoded, Payload);
  Expect<Integer>(Ord(Res)).ToBe(Ord(nprOk));
  Expect<Integer>(Length(Payload.ConnectorPlan)).ToBe(0);
  Expect<Integer>(Length(Payload.CapabilitySet)).ToBe(0);
  Expect<Boolean>(BytesEqual(Payload.ModuleBytes, Params.ModuleBytes)).ToBe(True);
end;

procedure TNativePayloadTests.TestHash128EmptyIsOffsetBasis;
var
  H: TWasmNativeHash128;
begin
  { FNV-1a-128 of the empty input is the RFC 9923 offset basis
    0x6c62272e07bb014262b821756295c58d. }
  H := WnepHash128(nil, 0);
  Expect<UInt64>(H.Hi).ToBe(UInt64($6C62272E07BB0142));
  Expect<UInt64>(H.Lo).ToBe(UInt64($62B821756295C58D));
end;

procedure TNativePayloadTests.TestHash128Deterministic;
var
  A, B, C: TWasmNativeHash128;
  Data1, Data2: TWasmBytes;
begin
  Data1 := BytesOf([$01, $02, $03, $04, $05]);
  Data2 := BytesOf([$01, $02, $03, $04, $06]);
  A := WnepHash128Bytes(Data1);
  B := WnepHash128Bytes(Data1);
  C := WnepHash128Bytes(Data2);
  Expect<Boolean>(WnepHash128Equal(A, B)).ToBe(True);
  Expect<Boolean>(WnepHash128Equal(A, C)).ToBe(False);
end;

procedure TNativePayloadTests.TestHash64Deterministic;
var
  Data: TWasmBytes;
  A, B: UInt64;
begin
  Data := BytesOf([$AA, $BB, $CC, $DD]);
  A := WnepHash64(@Data[0], NativeUInt(Length(Data)));
  B := WnepHash64(@Data[0], NativeUInt(Length(Data)));
  Expect<UInt64>(A).ToBe(B);
  Expect<UInt64>(WnepHash64(nil, 0)).ToBe(UInt64($CBF29CE484222325));
end;

procedure TNativePayloadTests.TestRejectLiteralTruncatedHeader;
var
  Bytes_: TWasmBytes;
begin
  { Ten literal bytes: a WNEP prefix that cannot hold the 64-byte header. }
  Bytes_ := BytesOf([$57, $4E, $45, $50, $01, $00, $00, $00, $00, $00]);
  ExpectParse(Bytes_, nprTruncated);
end;

procedure TNativePayloadTests.TestRejectLiteralBadMagic;
var
  Bytes_: TWasmBytes;
  I: Integer;
begin
  { A header-sized buffer whose first four bytes are wasm magic, not WNEP. }
  SetLength(Bytes_, WNEP_HEADER_SIZE);
  for I := 0 to High(Bytes_) do
    Bytes_[I] := 0;
  Bytes_[0] := $00;
  Bytes_[1] := $61;
  Bytes_[2] := $73;
  Bytes_[3] := $6D;
  Bytes_[4] := $01;
  ExpectParse(Bytes_, nprBadMagic);
end;

procedure TNativePayloadTests.TestRejectLiteralIncompatibleVersion;
var
  Bytes_: TWasmBytes;
  I: Integer;
begin
  { Literal WNEP header, format version 99 at offset 4. }
  SetLength(Bytes_, WNEP_HEADER_SIZE);
  for I := 0 to High(Bytes_) do
    Bytes_[I] := 0;
  Bytes_[0] := $57;
  Bytes_[1] := $4E;
  Bytes_[2] := $45;
  Bytes_[3] := $50;
  Bytes_[4] := 99;
  Bytes_[5] := 0;
  ExpectParse(Bytes_, nprIncompatibleVersion);
end;

procedure TNativePayloadTests.TestRejectLiteralOverflowingSectionCount;
var
  Bytes_: TWasmBytes;
  I: Integer;
begin
  { Literal WNEP v1 header whose sectionCount ($10000000) * 32 overflows u32. }
  SetLength(Bytes_, WNEP_HEADER_SIZE);
  for I := 0 to High(Bytes_) do
    Bytes_[I] := 0;
  Bytes_[0] := $57;
  Bytes_[1] := $4E;
  Bytes_[2] := $45;
  Bytes_[3] := $50;
  Bytes_[4] := $01;
  Bytes_[5] := $00;
  { sectionCount at offset 52: 0x10000000 * 32 = 0x200000000. }
  Bytes_[WNEP_SECTIONCOUNT_OFFSET] := $00;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET + 1] := $00;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET + 2] := $00;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET + 3] := $10;
  ExpectParse(Bytes_, nprOverflow);
end;

procedure TNativePayloadTests.TestRejectLiteralDirectoryAddOverflow;
var
  Bytes_: TWasmBytes;
  I: Integer;
begin
  { Literal WNEP v1 header whose sectionCount ($07FFFFFF) * 32 fits u32 but
    adding the 64-byte header overflows. }
  SetLength(Bytes_, WNEP_HEADER_SIZE);
  for I := 0 to High(Bytes_) do
    Bytes_[I] := 0;
  Bytes_[0] := $57;
  Bytes_[1] := $4E;
  Bytes_[2] := $45;
  Bytes_[3] := $50;
  Bytes_[4] := $01;
  Bytes_[5] := $00;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET] := $FF;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET + 1] := $FF;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET + 2] := $FF;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET + 3] := $07;
  ExpectParse(Bytes_, nprOverflow);
end;

procedure TNativePayloadTests.TestRejectLiteralShortDirectory;
var
  Bytes_: TWasmBytes;
  I: Integer;
begin
  { Literal WNEP v1 header claiming four directory entries but ending at the
    header — the table does not fit. }
  SetLength(Bytes_, WNEP_HEADER_SIZE);
  for I := 0 to High(Bytes_) do
    Bytes_[I] := 0;
  Bytes_[0] := $57;
  Bytes_[1] := $4E;
  Bytes_[2] := $45;
  Bytes_[3] := $50;
  Bytes_[4] := $01;
  Bytes_[5] := $00;
  Bytes_[WNEP_SECTIONCOUNT_OFFSET] := 4;
  ExpectParse(Bytes_, nprTruncated);
end;

procedure TNativePayloadTests.TestRejectBadChecksum;
var
  Bytes_: TWasmBytes;
begin
  Bytes_ := WriteSample;
  { Flip a module-section data byte — past the directory, so kinds and extents
    stay valid and the reject is the body checksum. }
  Bytes_[WNEP_HEADER_SIZE + (4 * WNEP_DIR_ENTRY_SIZE)] :=
    Bytes_[WNEP_HEADER_SIZE + (4 * WNEP_DIR_ENTRY_SIZE)] xor $FF;
  ExpectParse(Bytes_, nprBadChecksum);
end;

procedure TNativePayloadTests.TestRejectIdentityMismatch;
var
  Bytes_: TWasmBytes;
begin
  Bytes_ := WriteSample;
  { Header.moduleHash lives inside the header, which selfChecksum does not
    cover. Flipping it leaves extents and the body hash intact and isolates
    the identity bind. }
  Bytes_[20] := Bytes_[20] xor $FF;
  ExpectParse(Bytes_, nprIdentityMismatch);
end;

procedure TNativePayloadTests.TestRejectDuplicateKind;
var
  Bytes_: TWasmBytes;
begin
  Bytes_ := WriteSample;
  { Directory entry 1 kind is at HEADER + 32; overwrite it with MODULE so
    kind 1 appears twice. Extents stay valid, so the reject is the duplicate. }
  Bytes_[WNEP_HEADER_SIZE + WNEP_DIR_ENTRY_SIZE] := Byte(WNEP_SECTION_MODULE);
  Bytes_[WNEP_HEADER_SIZE + WNEP_DIR_ENTRY_SIZE + 1] := 0;
  ExpectParse(Bytes_, nprDuplicate);
end;

procedure TNativePayloadTests.TestRejectMissingRequired;
var
  Bytes_: TWasmBytes;
begin
  Bytes_ := WriteSample;
  { Replace the capability-set kind (entry 3) with a second code kind, then
    the duplicate check fires first... so instead replace it with kind 0,
    which is unknown. To isolate missing-required, drop sectionCount to 3
    and truncate the fourth directory entry out of the count while leaving
    bytes in place. }
  PatchU32(Bytes_, WNEP_SECTIONCOUNT_OFFSET, 3);
  ExpectParse(Bytes_, nprMissingRequired);
end;

procedure TNativePayloadTests.TestRejectUnknownSection;
var
  Bytes_: TWasmBytes;
begin
  Bytes_ := WriteSample;
  { Entry 3 kind -> 99. }
  Bytes_[WNEP_HEADER_SIZE + (3 * WNEP_DIR_ENTRY_SIZE)] := 99;
  Bytes_[WNEP_HEADER_SIZE + (3 * WNEP_DIR_ENTRY_SIZE) + 1] := 0;
  ExpectParse(Bytes_, nprUnknownSection);
end;

procedure TNativePayloadTests.TestRejectBadSectionHash;
var
  Bytes_: TWasmBytes;
  ZeroHash: TWasmNativeHash128;
begin
  Bytes_ := WriteSample;
  { Zero the module section's content hash (directory entry 0, hash at
    +12) and recompute the body checksum so the reject is the section hash,
    not selfChecksum. }
  ZeroHash.Lo := 0;
  ZeroHash.Hi := 0;
  PatchHash128(Bytes_, WNEP_HEADER_SIZE + 12, ZeroHash);
  RecomputeBodyChecksum(Bytes_);
  ExpectParse(Bytes_, nprBadSectionHash);
end;

procedure TNativePayloadTests.RewriteCodeSection(var AEncoded: TWasmBytes;
  const APayload: TWasmNativePayload; const ANewCode: TWasmBytes);
var
  Found, CodeOff, I: Integer;
  SectionBytes: TWasmBytes;
begin
  Found := -1;
  for I := 0 to High(APayload.Sections) do
    if APayload.Sections[I].Kind = WNEP_SECTION_CODE then
      Found := I;
  Expect<Boolean>(Found >= 0).ToBe(True);
  CodeOff := Integer(APayload.Sections[Found].DataOffset);
  for I := 0 to High(ANewCode) do
    AEncoded[CodeOff + I] := ANewCode[I];
  SetLength(SectionBytes, APayload.Sections[Found].DataSize);
  for I := 0 to High(SectionBytes) do
    SectionBytes[I] := AEncoded[CodeOff + I];
  PatchHash128(AEncoded, WNEP_HEADER_SIZE + (Found * WNEP_DIR_ENTRY_SIZE) + 12,
    WnepHash128Bytes(SectionBytes));
  RecomputeBodyChecksum(AEncoded);
end;

procedure TNativePayloadTests.TestRejectEmptyFunctionCode;
var
  EmptyRec, Encoded: TWasmBytes;
  Payload: TWasmNativePayload;
begin
  { Literal empty function record: funcCount=1 and codeLength=0. }
  EmptyRec := BytesOf([
    $01, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00
  ]);
  Encoded := WriteSample;
  Expect<Integer>(Ord(ParseNativePayload(Encoded, Payload))).ToBe(Ord(nprOk));
  RewriteCodeSection(Encoded, Payload, EmptyRec);
  ExpectParse(Encoded, nprMalformed);
end;

procedure TNativePayloadTests.TestRejectOverflowingFuncCount;
var
  Encoded, Prefix: TWasmBytes;
  Payload: TWasmNativePayload;
begin
  Encoded := WriteSample;
  Expect<Integer>(Ord(ParseNativePayload(Encoded, Payload))).ToBe(Ord(nprOk));
  { Literal funcCount = 0x10000000 in a short code section cannot fit. }
  Prefix := BytesOf([$00, $00, $00, $10]);
  RewriteCodeSection(Encoded, Payload, Prefix);
  ExpectParse(Encoded, nprOverflow);
end;

procedure TNativePayloadTests.TestRejectOversizedCodeLength;
var
  Encoded, Prefix: TWasmBytes;
  Payload: TWasmNativePayload;
begin
  Encoded := WriteSample;
  Expect<Integer>(Ord(ParseNativePayload(Encoded, Payload))).ToBe(Ord(nprOk));
  { Literal one-function record whose codeLength ($FFFFFFFF) cannot fit the
    remaining section; the count must be rejected without wrapping Pos+Count
    on 32-bit NativeUInt. Layout: funcCount, then irIndex/regCount/entry/len. }
  Prefix := BytesOf([
    $01, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $00, $00, $00, $00,
    $FF, $FF, $FF, $FF
  ]);
  RewriteCodeSection(Encoded, Payload, Prefix);
  ExpectParse(Encoded, nprMalformed);
end;

procedure TNativePayloadTests.TestRejectEntryOffsetPastCode;
var
  Encoded, Prefix: TWasmBytes;
  Payload: TWasmNativePayload;
begin
  Encoded := WriteSample;
  Expect<Integer>(Ord(ParseNativePayload(Encoded, Payload))).ToBe(Ord(nprOk));
  { EntryOffset $FFFFFFFF with a 7-byte code body is past the code extent. }
  Prefix := BytesOf([
    $01, $00, $00, $00,
    $00, $00, $00, $00,
    $05, $00, $00, $00,
    $FF, $FF, $FF, $FF,
    $07, $00, $00, $00
  ]);
  RewriteCodeSection(Encoded, Payload, Prefix);
  ExpectParse(Encoded, nprMalformed);
end;

procedure TNativePayloadTests.TestExtentBoundaryTable;
const
  { Directory entry 0 (module) dataOffset at HEADER+4, dataSize at HEADER+8. }
  MOD_OFF = WNEP_HEADER_SIZE + 4;
  MOD_SIZE = WNEP_HEADER_SIZE + 8;
var
  Cases: array[0..5] of TExtentCase;
  Encoded: TWasmBytes;
  Payload: TWasmNativePayload;
  OrigOff, OrigSize: UInt32;
  I: Integer;
begin
  Encoded := WriteSample;
  Expect<Integer>(Ord(ParseNativePayload(Encoded, Payload))).ToBe(Ord(nprOk));
  OrigOff := Payload.Sections[0].DataOffset;
  OrigSize := Payload.Sections[0].DataSize;

  { offset=0 overlaps the header/directory. }
  Cases[0].Name := 'offset into header';
  Cases[0].OffsetField := 0;
  Cases[0].SizeField := OrigSize;
  Cases[0].Expected := nprOverlap;

  { offset just before the data region still overlaps the directory. }
  Cases[1].Name := 'offset into directory';
  Cases[1].OffsetField := WNEP_HEADER_SIZE;
  Cases[1].SizeField := OrigSize;
  Cases[1].Expected := nprOverlap;

  { offset + size wraps u32. }
  Cases[2].Name := 'offset plus size overflow';
  Cases[2].OffsetField := $FFFFFFF0;
  Cases[2].SizeField := $20;
  Cases[2].Expected := nprOverflow;

  { offset past the file. }
  Cases[3].Name := 'offset past end';
  Cases[3].OffsetField := $7FFFFFFF;
  Cases[3].SizeField := OrigSize;
  Cases[3].Expected := nprTruncated;

  { size runs past the file from a valid offset. }
  Cases[4].Name := 'size past end';
  Cases[4].OffsetField := OrigOff;
  Cases[4].SizeField := $00100000;
  Cases[4].Expected := nprTruncated;

  { overlap the next section by stretching size by one full later blob. }
  Cases[5].Name := 'overlap next section';
  Cases[5].OffsetField := OrigOff;
  Cases[5].SizeField := OrigSize + Payload.Sections[1].DataSize;
  Cases[5].Expected := nprOverlap;

  for I := 0 to High(Cases) do
  begin
    Encoded := WriteSample;
    PatchU32(Encoded, MOD_OFF, Cases[I].OffsetField);
    PatchU32(Encoded, MOD_SIZE, Cases[I].SizeField);
    ExpectParse(Encoded, Cases[I].Expected);
  end;
end;

procedure TNativePayloadTests.TestWriterRejectsEmptyModule;
var
  Params: TWasmNativePayloadWriteParams;
  Raised: Boolean;
begin
  Params := SampleParams;
  Params.ModuleBytes := nil;
  Params.ModuleHash := WnepHash128Bytes(nil);
  Raised := False;
  try
    WriteNativePayload(Params);
  except
    on E: EWasmInternal do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TNativePayloadTests.TestWriterRejectsEmptyFunctionCode;
var
  Params: TWasmNativePayloadWriteParams;
  Raised: Boolean;
begin
  Params := SampleParams;
  SetLength(Params.Funcs[0].Code, 0);
  Raised := False;
  try
    WriteNativePayload(Params);
  except
    on E: EWasmInternal do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TNativePayloadTests.TestWriterRejectsHashMismatch;
var
  Params: TWasmNativePayloadWriteParams;
  Raised: Boolean;
begin
  Params := SampleParams;
  Params.ModuleHash.Lo := Params.ModuleHash.Lo xor 1;
  Raised := False;
  try
    WriteNativePayload(Params);
  except
    on E: EWasmInternal do
      Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TNativePayloadTests.SetupTests;
begin
  Test('header identity fields round-trip through write/parse',
    TestRoundTripHeader);
  Test('module, code, connector plan, and capability set round-trip',
    TestRoundTripRecords);
  Test('empty connector plan and capability set are valid required records',
    TestEmptyPlanAndCaps);
  Test('FNV-1a-128 of empty input is the RFC 9923 offset basis',
    TestHash128EmptyIsOffsetBasis);
  Test('FNV-1a-128 is deterministic and avalanches on a one-byte change',
    TestHash128Deterministic);
  Test('FNV-1a-64 is deterministic with the known offset basis',
    TestHash64Deterministic);
  Test('literal truncated header is nprTruncated',
    TestRejectLiteralTruncatedHeader);
  Test('literal wasm-magic header is nprBadMagic', TestRejectLiteralBadMagic);
  Test('literal format version 99 is nprIncompatibleVersion',
    TestRejectLiteralIncompatibleVersion);
  Test('literal overflowing sectionCount is nprOverflow',
    TestRejectLiteralOverflowingSectionCount);
  Test('literal directory size plus header overflow is nprOverflow',
    TestRejectLiteralDirectoryAddOverflow);
  Test('literal header with no directory is nprTruncated',
    TestRejectLiteralShortDirectory);
  Test('a flipped body byte is nprBadChecksum', TestRejectBadChecksum);
  Test('a header moduleHash that is not the module section is nprIdentityMismatch',
    TestRejectIdentityMismatch);
  Test('a duplicated required kind is nprDuplicate', TestRejectDuplicateKind);
  Test('dropping a required kind is nprMissingRequired',
    TestRejectMissingRequired);
  Test('an unknown section kind is nprUnknownSection',
    TestRejectUnknownSection);
  Test('a rewritten section hash is nprBadSectionHash',
    TestRejectBadSectionHash);
  Test('literal empty function code record is nprMalformed',
    TestRejectEmptyFunctionCode);
  Test('literal overflowing funcCount is nprOverflow',
    TestRejectOverflowingFuncCount);
  Test('literal oversized function codeLength is nprMalformed',
    TestRejectOversizedCodeLength);
  Test('an entryOffset past the function code is nprMalformed',
    TestRejectEntryOffsetPastCode);
  Test('directory offset/size boundaries reject with the matching reason',
    TestExtentBoundaryTable);
  Test('writer refuses a payload with no module bytes',
    TestWriterRejectsEmptyModule);
  Test('writer refuses a function record with no code',
    TestWriterRejectsEmptyFunctionCode);
  Test('writer refuses a moduleHash that is not the module bytes',
    TestWriterRejectsHashMismatch);
end;

begin
  TestRunnerProgram.AddSuite(TNativePayloadTests.Create('Wasm.Native.Payload'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
