{ Unit suite for Wasm.Sha256 — FIPS 180-4 known-answer vectors.

  These are the published NIST examples, not project fixtures: the digest
  has to match the algorithm Apple's CodeDirectory uses, so a one-byte
  drift would silently produce unverifiable Mach-O signatures. }
program Wasm.Sha256.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Sha256;

type
  TSha256Tests = class(TTestSuite)
  private
    function DigestHex(const ADigest: TSha256Digest): string;
    function BytesOfAscii(const AText: string): TWasmBytes;
  public
    procedure SetupTests; override;
    procedure TestEmpty;
    procedure TestAbc;
    procedure Test448Bit;
    procedure TestDeterministic;
  end;

function TSha256Tests.DigestHex(const ADigest: TSha256Digest): string;
const
  HEX = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, SHA256_DIGEST_SIZE * 2);
  for I := 0 to SHA256_DIGEST_SIZE - 1 do
  begin
    Result[I * 2 + 1] := HEX[(ADigest[I] shr 4) + 1];
    Result[I * 2 + 2] := HEX[(ADigest[I] and $0F) + 1];
  end;
end;

function TSha256Tests.BytesOfAscii(const AText: string): TWasmBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  for I := 1 to Length(AText) do
    Result[I - 1] := Byte(Ord(AText[I]));
end;

procedure TSha256Tests.TestEmpty;
begin
  Expect<string>(DigestHex(Sha256Bytes(nil, 0))).ToBe(
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  Expect<string>(DigestHex(Sha256WasmBytes(nil))).ToBe(
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
end;

procedure TSha256Tests.TestAbc;
var
  Data: TWasmBytes;
begin
  Data := BytesOfAscii('abc');
  Expect<string>(DigestHex(Sha256WasmBytes(Data))).ToBe(
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
end;

procedure TSha256Tests.Test448Bit;
var
  Data: TWasmBytes;
begin
  { FIPS 180-4 example: 448-bit (56-byte) message, the block-boundary
    case that forces a second padding block. }
  Data := BytesOfAscii(
    'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq');
  Expect<string>(DigestHex(Sha256WasmBytes(Data))).ToBe(
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
end;

procedure TSha256Tests.TestDeterministic;
var
  Data: TWasmBytes;
  A, B: TSha256Digest;
  I: Integer;
  Same: Boolean;
begin
  Data := BytesOfAscii('wasmlight');
  A := Sha256WasmBytes(Data);
  B := Sha256WasmBytes(Data);
  Same := True;
  for I := 0 to SHA256_DIGEST_SIZE - 1 do
    if A[I] <> B[I] then
      Same := False;
  Expect<Boolean>(Same).ToBe(True);
  Data[0] := Data[0] xor 1;
  B := Sha256WasmBytes(Data);
  Same := True;
  for I := 0 to SHA256_DIGEST_SIZE - 1 do
    if A[I] <> B[I] then
      Same := False;
  Expect<Boolean>(Same).ToBe(False);
end;

procedure TSha256Tests.SetupTests;
begin
  Test('SHA-256 of empty input is the NIST vector', TestEmpty);
  Test('SHA-256 of "abc" is the NIST vector', TestAbc);
  Test('SHA-256 of the 448-bit NIST example matches', Test448Bit);
  Test('SHA-256 is deterministic and avalanches on one byte',
    TestDeterministic);
end;

begin
  TestRunnerProgram.AddSuite(TSha256Tests.Create('Wasm.Sha256'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
