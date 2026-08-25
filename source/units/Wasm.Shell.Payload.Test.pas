{ Unit suite for Wasm.Shell.Payload — the temporary #34 envelope.

  Malformed cases are literal bytes beside the assertion. #35 will replace
  the product format; these tests pin the current seam so that replacement
  has a failing suite to rewrite. }
program Wasm.Shell.Payload.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Shell.Payload;

type
  TShellPayloadTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRoundTripEmptySections;
    procedure TestRoundTripNonEmpty;
    procedure TestEmptyIsEmpty;
    procedure TestBadMagic;
    procedure TestTruncatedHeader;
    procedure TestUnsupportedVersion;
    procedure TestTruncatedBody;
    procedure TestTrailingBytesRejected;
  end;

function ByteOf(const AValue: Byte): TWasmBytes;
begin
  SetLength(Result, 1);
  Result[0] := AValue;
end;

procedure TShellPayloadTests.TestRoundTripEmptySections;
var
  Encoded: TWasmBytes;
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  Encoded := WriteShellPayload(nil, nil, nil, nil);
  Parse := ParseShellPayload(Encoded, Image);
  Expect<Boolean>(Parse = sprOk).ToBe(True);
  Expect<Integer>(Length(Image.Module)).ToBe(0);
  Expect<Integer>(Length(Image.Native)).ToBe(0);
  Expect<Integer>(Length(Image.ConnectorPlan)).ToBe(0);
  Expect<Integer>(Length(Image.CapabilitySet)).ToBe(0);
end;

procedure TShellPayloadTests.TestRoundTripNonEmpty;
var
  Encoded: TWasmBytes;
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  Encoded := WriteShellPayload(ByteOf($00), ByteOf($11), ByteOf($22), ByteOf($33));
  Parse := ParseShellPayload(Encoded, Image);
  Expect<Boolean>(Parse = sprOk).ToBe(True);
  Expect<Integer>(Length(Image.Module)).ToBe(1);
  Expect<Integer>(Length(Image.Native)).ToBe(1);
  Expect<Integer>(Length(Image.ConnectorPlan)).ToBe(1);
  Expect<Integer>(Length(Image.CapabilitySet)).ToBe(1);
  Expect<Byte>(Image.Module[0]).ToBe($00);
  Expect<Byte>(Image.Native[0]).ToBe($11);
  Expect<Byte>(Image.ConnectorPlan[0]).ToBe($22);
  Expect<Byte>(Image.CapabilitySet[0]).ToBe($33);
end;

procedure TShellPayloadTests.TestEmptyIsEmpty;
var
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  Parse := ParseShellPayload(nil, Image);
  Expect<Boolean>(Parse = sprEmpty).ToBe(True);
end;

procedure TShellPayloadTests.TestBadMagic;
var
  Bytes: TWasmBytes;
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  { A `.waot`-shaped prefix must not be accepted as a shell image. }
  SetLength(Bytes, WSHL_HEADER_SIZE);
  Bytes[0] := Byte($57);   { 'W' }
  Bytes[1] := Byte($41);   { 'A' }
  Bytes[2] := Byte($4F);   { 'O' }
  Bytes[3] := Byte($54);   { 'T' }
  Parse := ParseShellPayload(Bytes, Image);
  Expect<Boolean>(Parse = sprBadMagic).ToBe(True);
end;

procedure TShellPayloadTests.TestTruncatedHeader;
var
  Bytes: TWasmBytes;
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  SetLength(Bytes, 3);
  Bytes[0] := WSHL_MAGIC0;
  Bytes[1] := WSHL_MAGIC1;
  Bytes[2] := WSHL_MAGIC2;
  Parse := ParseShellPayload(Bytes, Image);
  Expect<Boolean>(Parse = sprTruncated).ToBe(True);
end;

procedure TShellPayloadTests.TestUnsupportedVersion;
var
  Encoded: TWasmBytes;
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  Encoded := WriteShellPayload(nil, nil, nil, nil);
  Encoded[4] := 99;
  Encoded[5] := 0;
  Parse := ParseShellPayload(Encoded, Image);
  Expect<Boolean>(Parse = sprBadFormatVer).ToBe(True);
end;

procedure TShellPayloadTests.TestTruncatedBody;
var
  Encoded: TWasmBytes;
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  Encoded := WriteShellPayload(ByteOf($AA), nil, nil, nil);
  SetLength(Encoded, Length(Encoded) - 1);
  Parse := ParseShellPayload(Encoded, Image);
  Expect<Boolean>(Parse = sprTruncated).ToBe(True);
end;

procedure TShellPayloadTests.TestTrailingBytesRejected;
var
  Encoded: TWasmBytes;
  Image: TWasmShellImage;
  Parse: TWasmShellParseResult;
begin
  Encoded := WriteShellPayload(nil, nil, nil, nil);
  SetLength(Encoded, Length(Encoded) + 1);
  Encoded[High(Encoded)] := $FF;
  Parse := ParseShellPayload(Encoded, Image);
  Expect<Boolean>(Parse = sprTruncated).ToBe(True);
end;

procedure TShellPayloadTests.SetupTests;
begin
  Test('empty sections round-trip', TestRoundTripEmptySections);
  Test('non-empty sections round-trip', TestRoundTripNonEmpty);
  Test('an empty buffer is the unfilled template', TestEmptyIsEmpty);
  Test('WAOT magic is not a shell image', TestBadMagic);
  Test('a header shorter than 24 bytes is truncated', TestTruncatedHeader);
  Test('an unknown format version is rejected', TestUnsupportedVersion);
  Test('a declared section that runs past the buffer is truncated',
    TestTruncatedBody);
  Test('trailing bytes after the declared sections are rejected',
    TestTrailingBytesRejected);
end;

begin
  TestRunnerProgram.AddSuite(TShellPayloadTests.Create('Wasm.Shell.Payload'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
