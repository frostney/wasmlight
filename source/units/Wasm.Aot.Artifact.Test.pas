{ Unit suite for Wasm.Aot.Artifact — the `.waot` format reader/writer, the
  content hashes, and the structural reject reasons (aot-spec §2).

  The artifact is an INTERNAL cache: its whole value is that what the writer laid
  down the reader reads back byte-for-byte, and that a corrupt or wrong-version
  file is rejected with a DISTINCT reason (so the loader logs why it fell back)
  rather than misread. So these tests write records, parse them, and assert the
  fields survive the round trip; assert the FNV hashes are deterministic and
  match a known vector; and drive each structural reject — bad magic, wrong
  container version, a flipped body byte (checksum), and a truncation.

  Every test asserts an outcome (never only Fail on a bad path) — a test that
  records no assertion is failed by the runner (AGENTS.md). }
program Wasm.Aot.Artifact.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Aot.Artifact,
  Wasm.Core;

type
  TAotArtifactTests = class(TTestSuite)
  private
    function SampleCompiled: TWasmAotFuncRecord;
    function SampleDeclined: TWasmAotFuncRecord;
    function SampleParams: TWasmAotWriteParams;
  public
    procedure SetupTests; override;

    procedure TestRoundTripHeader;
    procedure TestRoundTripRecords;
    procedure TestRelocRoundTrip;
    procedure TestHash128EmptyIsOffsetBasis;
    procedure TestHash128Deterministic;
    procedure TestHash64Deterministic;
    procedure TestRejectBadMagic;
    procedure TestRejectBadFormatVer;
    procedure TestRejectBadChecksum;
    procedure TestRejectTruncated;
  end;

function Bytes(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function TAotArtifactTests.SampleCompiled: TWasmAotFuncRecord;
begin
  Result.FuncIrIndex := 0;
  Result.Compiled := True;
  Result.RegisterCount := 5;
  Result.EntryOffset := 0;
  { A non-16-aligned length so the writer's code-region padding is exercised. }
  Result.Code := Bytes([$00, $11, $22, $33, $44, $55, $66]);
  Result.Relocs := nil;
end;

function TAotArtifactTests.SampleDeclined: TWasmAotFuncRecord;
begin
  Result.FuncIrIndex := 1;
  Result.Compiled := False;
  Result.RegisterCount := 9;
  Result.EntryOffset := 0;
  Result.Code := nil;
  Result.Relocs := nil;
end;

function TAotArtifactTests.SampleParams: TWasmAotWriteParams;
begin
  Result.IrFormatVer := 2;
  Result.TargetArch := WAOT_ARCH_AARCH64;
  Result.Flags := 0;
  Result.AbiFingerprint := UInt64($0123456789ABCDEF);
  Result.ModuleHash.Lo := UInt64($1111222233334444);
  Result.ModuleHash.Hi := UInt64($5555666677778888);
end;

procedure TAotArtifactTests.TestRoundTripHeader;
var
  Funcs: TWasmAotFuncRecords;
  Params: TWasmAotWriteParams;
  Bytes_: TWasmBytes;
  Art: TWasmAotArtifact;
  Res: TWasmAotParseResult;
begin
  Params := SampleParams;
  SetLength(Funcs, 1);
  Funcs[0] := SampleCompiled;
  Bytes_ := WriteAotArtifact(Params, Funcs);

  Res := ParseAotArtifact(Bytes_, Art);
  Expect<Integer>(Ord(Res)).ToBe(Ord(aprOk));
  Expect<Integer>(Integer(Art.Header.AotFormatVer)).ToBe(Integer(WAOT_FORMAT_VERSION));
  Expect<Integer>(Integer(Art.Header.IrFormatVer)).ToBe(2);
  Expect<Integer>(Integer(Art.Header.TargetArch)).ToBe(Integer(WAOT_ARCH_AARCH64));
  Expect<UInt64>(Art.Header.AbiFingerprint).ToBe(UInt64($0123456789ABCDEF));
  Expect<UInt64>(Art.Header.ModuleHash.Lo).ToBe(UInt64($1111222233334444));
  Expect<UInt64>(Art.Header.ModuleHash.Hi).ToBe(UInt64($5555666677778888));
  Expect<Integer>(Integer(Art.Header.FuncCount)).ToBe(1);
end;

procedure TAotArtifactTests.TestRoundTripRecords;
var
  Funcs: TWasmAotFuncRecords;
  Bytes_: TWasmBytes;
  Art: TWasmAotArtifact;
  Res: TWasmAotParseResult;
  I: Integer;
  CodeEqual: Boolean;
begin
  SetLength(Funcs, 2);
  Funcs[0] := SampleCompiled;
  Funcs[1] := SampleDeclined;
  Bytes_ := WriteAotArtifact(SampleParams, Funcs);

  Res := ParseAotArtifact(Bytes_, Art);
  Expect<Integer>(Ord(Res)).ToBe(Ord(aprOk));
  Expect<Integer>(Length(Art.Funcs)).ToBe(2);

  { The compiled record: index, flag, counts, and the exact code bytes. }
  Expect<Integer>(Integer(Art.Funcs[0].FuncIrIndex)).ToBe(0);
  Expect<Boolean>(Art.Funcs[0].Compiled).ToBe(True);
  Expect<Integer>(Integer(Art.Funcs[0].RegisterCount)).ToBe(5);
  Expect<Integer>(Integer(Art.Funcs[0].EntryOffset)).ToBe(0);
  Expect<Integer>(Length(Art.Funcs[0].Code)).ToBe(7);
  CodeEqual := True;
  for I := 0 to High(Art.Funcs[0].Code) do
    if Art.Funcs[0].Code[I] <> Funcs[0].Code[I] then
      CodeEqual := False;
  Expect<Boolean>(CodeEqual).ToBe(True);

  { The declined record: no code, flag clear, register count preserved. }
  Expect<Integer>(Integer(Art.Funcs[1].FuncIrIndex)).ToBe(1);
  Expect<Boolean>(Art.Funcs[1].Compiled).ToBe(False);
  Expect<Integer>(Length(Art.Funcs[1].Code)).ToBe(0);
  Expect<Integer>(Integer(Art.Funcs[1].RegisterCount)).ToBe(9);
end;

procedure TAotArtifactTests.TestRelocRoundTrip;
var
  Funcs: TWasmAotFuncRecords;
  Bytes_: TWasmBytes;
  Art: TWasmAotArtifact;
  Res: TWasmAotParseResult;
begin
  { The reloc table is empty in the shipped emitter, but the FORMAT must carry a
    non-empty one so it is forward-compatible (§1.5). Exercise that path. }
  SetLength(Funcs, 1);
  Funcs[0] := SampleCompiled;
  SetLength(Funcs[0].Relocs, 1);
  Funcs[0].Relocs[0].SiteOffset := 12;
  Funcs[0].Relocs[0].Kind := 1;
  Funcs[0].Relocs[0].Symbol := 7;
  Bytes_ := WriteAotArtifact(SampleParams, Funcs);

  Res := ParseAotArtifact(Bytes_, Art);
  Expect<Integer>(Ord(Res)).ToBe(Ord(aprOk));
  Expect<Integer>(Length(Art.Funcs[0].Relocs)).ToBe(1);
  Expect<Integer>(Integer(Art.Funcs[0].Relocs[0].SiteOffset)).ToBe(12);
  Expect<Integer>(Integer(Art.Funcs[0].Relocs[0].Kind)).ToBe(1);
  Expect<Integer>(Integer(Art.Funcs[0].Relocs[0].Symbol)).ToBe(7);
  { The code after the reloc table still round-trips. }
  Expect<Integer>(Length(Art.Funcs[0].Code)).ToBe(7);
end;

procedure TAotArtifactTests.TestHash128EmptyIsOffsetBasis;
var
  H: TWasmAotHash128;
begin
  { FNV-1a-128 of the empty input is the offset basis
    0x6c62272e07bb014262b821756295c58d — the standard known vector. }
  H := WaotHash128(nil, 0);
  Expect<UInt64>(H.Hi).ToBe(UInt64($6C62272E07BB0142));
  Expect<UInt64>(H.Lo).ToBe(UInt64($62B821756295C58D));
end;

procedure TAotArtifactTests.TestHash128Deterministic;
var
  A, B, C: TWasmAotHash128;
  Data1, Data2: TWasmBytes;
begin
  Data1 := Bytes([$01, $02, $03, $04, $05]);
  Data2 := Bytes([$01, $02, $03, $04, $06]);   { one byte differs }
  A := WaotHash128Bytes(Data1);
  B := WaotHash128Bytes(Data1);
  C := WaotHash128Bytes(Data2);
  { Same input -> identical hash. }
  Expect<Boolean>(WaotHash128Equal(A, B)).ToBe(True);
  { A one-byte change -> a different hash (the avalanche the guard relies on). }
  Expect<Boolean>(WaotHash128Equal(A, C)).ToBe(False);
end;

procedure TAotArtifactTests.TestHash64Deterministic;
var
  Data: TWasmBytes;
  A, B: UInt64;
begin
  Data := Bytes([$AA, $BB, $CC, $DD]);
  A := WaotHash64(@Data[0], NativeUInt(Length(Data)));
  B := WaotHash64(@Data[0], NativeUInt(Length(Data)));
  Expect<UInt64>(A).ToBe(B);
  { An empty range hashes to the FNV-1a-64 offset basis. }
  Expect<UInt64>(WaotHash64(nil, 0)).ToBe(UInt64($CBF29CE484222325));
end;

procedure TAotArtifactTests.TestRejectBadMagic;
var
  Funcs: TWasmAotFuncRecords;
  Bytes_: TWasmBytes;
  Art: TWasmAotArtifact;
  Res: TWasmAotParseResult;
begin
  SetLength(Funcs, 1);
  Funcs[0] := SampleCompiled;
  Bytes_ := WriteAotArtifact(SampleParams, Funcs);
  Bytes_[0] := $00;   { corrupt 'W' }
  Res := ParseAotArtifact(Bytes_, Art);
  Expect<Integer>(Ord(Res)).ToBe(Ord(aprBadMagic));
end;

procedure TAotArtifactTests.TestRejectBadFormatVer;
var
  Funcs: TWasmAotFuncRecords;
  Bytes_: TWasmBytes;
  Art: TWasmAotArtifact;
  Res: TWasmAotParseResult;
begin
  SetLength(Funcs, 1);
  Funcs[0] := SampleCompiled;
  Bytes_ := WriteAotArtifact(SampleParams, Funcs);
  { aotFormatVer is the u16 at offset 4; bump it to an unknown version. }
  Bytes_[4] := $63;
  Res := ParseAotArtifact(Bytes_, Art);
  Expect<Integer>(Ord(Res)).ToBe(Ord(aprBadFormatVer));
end;

procedure TAotArtifactTests.TestRejectBadChecksum;
var
  Funcs: TWasmAotFuncRecords;
  Bytes_: TWasmBytes;
  Art: TWasmAotArtifact;
  Res: TWasmAotParseResult;
begin
  SetLength(Funcs, 1);
  Funcs[0] := SampleCompiled;
  Bytes_ := WriteAotArtifact(SampleParams, Funcs);
  { Flip a byte in the BODY (offset >= header size): the selfChecksum over the
    body no longer matches. }
  Bytes_[WAOT_HEADER_SIZE] := Bytes_[WAOT_HEADER_SIZE] xor $FF;
  Res := ParseAotArtifact(Bytes_, Art);
  Expect<Integer>(Ord(Res)).ToBe(Ord(aprBadChecksum));
end;

procedure TAotArtifactTests.TestRejectTruncated;
var
  Funcs: TWasmAotFuncRecords;
  Bytes_, Short: TWasmBytes;
  Art: TWasmAotArtifact;
  Res: TWasmAotParseResult;
  I: Integer;
begin
  SetLength(Funcs, 1);
  Funcs[0] := SampleCompiled;
  Bytes_ := WriteAotArtifact(SampleParams, Funcs);
  { Cut the file below the fixed header size — nothing structural can be read. }
  SetLength(Short, 30);
  for I := 0 to High(Short) do
    Short[I] := Bytes_[I];
  Res := ParseAotArtifact(Short, Art);
  Expect<Integer>(Ord(Res)).ToBe(Ord(aprMalformed));
end;

procedure TAotArtifactTests.SetupTests;
begin
  Test('header fields round-trip through write/parse', TestRoundTripHeader);
  Test('compiled and declined function records round-trip', TestRoundTripRecords);
  Test('a non-empty reloc table round-trips (format forward-compat)',
    TestRelocRoundTrip);
  Test('FNV-1a-128 of empty input is the offset basis',
    TestHash128EmptyIsOffsetBasis);
  Test('FNV-1a-128 is deterministic and avalanches on a one-byte change',
    TestHash128Deterministic);
  Test('FNV-1a-64 is deterministic with the known offset basis',
    TestHash64Deterministic);
  Test('a bad magic is rejected as aprBadMagic', TestRejectBadMagic);
  Test('an unknown container version is rejected as aprBadFormatVer',
    TestRejectBadFormatVer);
  Test('a flipped body byte is rejected as aprBadChecksum', TestRejectBadChecksum);
  Test('a truncated file is rejected as aprMalformed', TestRejectTruncated);
end;

begin
  TestRunnerProgram.AddSuite(TAotArtifactTests.Create('Wasm.Aot.Artifact'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
