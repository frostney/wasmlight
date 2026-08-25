{ Wasm.Sha256 — FIPS 180-4 SHA-256.

  Apple's embedded Mach-O CodeDirectory (xnu cs_blobs.h, CS_HASHTYPE_SHA256)
  needs 32-byte page hashes. FPC 3.2.2's hash package ships SHA-1 / MD5 /
  HMAC / CRC only — there is no SHA-256 unit to call. A new dependency is
  forbidden, and host-only libraries (CommonCrypto, OpenSSL) cannot run on
  a Linux compiler host. This unit is the remaining option: the published
  algorithm, proven by the NIST published test vectors in the co-located
  suite. It is a packaging primitive, not a hot path. }
unit Wasm.Sha256;

{$I Shared.inc}

interface

uses
  Wasm.Core;

const
  SHA256_DIGEST_SIZE = 32;
  SHA256_BLOCK_SIZE = 64;

type
  TSha256Digest = array[0..SHA256_DIGEST_SIZE - 1] of Byte;

{ Digest of ALen bytes at AData. AData may be nil when ALen is 0. }
function Sha256Bytes(const AData: PByte; const ALen: NativeUInt): TSha256Digest;

{ Digest of a TWasmBytes value, including the empty array. }
function Sha256WasmBytes(const ABytes: TWasmBytes): TSha256Digest;

implementation

{ SHA-256 addition wraps modulo 2^32. Overflow/range checks are on
  project-wide via Shared.inc and would reject the wrap. }
{$push}{$Q-}{$R-}

type
  TSha256State = array[0..7] of UInt32;

const
  K: array[0..63] of UInt32 = (
    $428A2F98, $71374491, $B5C0FBCF, $E9B5DBA5,
    $3956C25B, $59F111F1, $923F82A4, $AB1C5ED5,
    $D807AA98, $12835B01, $243185BE, $550C7DC3,
    $72BE5D74, $80DEB1FE, $9BDC06A7, $C19BF174,
    $E49B69C1, $EFBE4786, $0FC19DC6, $240CA1CC,
    $2DE92C6F, $4A7484AA, $5CB0A9DC, $76F988DA,
    $983E5152, $A831C66D, $B00327C8, $BF597FC7,
    $C6E00BF3, $D5A79147, $06CA6351, $14292967,
    $27B70A85, $2E1B2138, $4D2C6DFC, $53380D13,
    $650A7354, $766A0ABB, $81C2C92E, $92722C85,
    $A2BFE8A1, $A81A664B, $C24B8B70, $C76C51A3,
    $D192E819, $D6990624, $F40E3585, $106AA070,
    $19A4C116, $1E376C08, $2748774C, $34B0BCB5,
    $391C0CB3, $4ED8AA4A, $5B9CCA4F, $682E6FF3,
    $748F82EE, $78A5636F, $84C87814, $8CC70208,
    $90BEFFFA, $A4506CEB, $BEF9A3F7, $C67178F2
  );

  H0: TSha256State = (
    $6A09E667, $BB67AE85, $3C6EF372, $A54FF53A,
    $510E527F, $9B05688C, $1F83D9AB, $5BE0CD19
  );

function Rotr(const AX: UInt32; const AN: Integer): UInt32;
begin
  Result := (AX shr AN) or (AX shl (32 - AN));
end;

procedure Compress(var AState: TSha256State; const ABlock: PByte);
var
  W: array[0..63] of UInt32;
  A, B, C, D, E, F, G, H, T1, T2, S0, S1, Ch, Maj: UInt32;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (UInt32(ABlock[I * 4]) shl 24)
      or (UInt32(ABlock[I * 4 + 1]) shl 16)
      or (UInt32(ABlock[I * 4 + 2]) shl 8)
      or UInt32(ABlock[I * 4 + 3]);
  for I := 16 to 63 do
  begin
    S0 := Rotr(W[I - 15], 7) xor Rotr(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := Rotr(W[I - 2], 17) xor Rotr(W[I - 2], 19) xor (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;
  A := AState[0];
  B := AState[1];
  C := AState[2];
  D := AState[3];
  E := AState[4];
  F := AState[5];
  G := AState[6];
  H := AState[7];
  for I := 0 to 63 do
  begin
    S1 := Rotr(E, 6) xor Rotr(E, 11) xor Rotr(E, 25);
    Ch := (E and F) xor ((not E) and G);
    T1 := H + S1 + Ch + K[I] + W[I];
    S0 := Rotr(A, 2) xor Rotr(A, 13) xor Rotr(A, 22);
    Maj := (A and B) xor (A and C) xor (B and C);
    T2 := S0 + Maj;
    H := G;
    G := F;
    F := E;
    E := D + T1;
    D := C;
    C := B;
    B := A;
    A := T1 + T2;
  end;
  AState[0] := AState[0] + A;
  AState[1] := AState[1] + B;
  AState[2] := AState[2] + C;
  AState[3] := AState[3] + D;
  AState[4] := AState[4] + E;
  AState[5] := AState[5] + F;
  AState[6] := AState[6] + G;
  AState[7] := AState[7] + H;
end;

function Sha256Bytes(const AData: PByte; const ALen: NativeUInt): TSha256Digest;
var
  State: TSha256State;
  Block: array[0..SHA256_BLOCK_SIZE - 1] of Byte;
  Off, Remain, I: NativeUInt;
  BitLen: UInt64;
begin
  State := H0;
  Off := 0;
  Remain := ALen;
  while Remain >= SHA256_BLOCK_SIZE do
  begin
    Compress(State, @AData[Off]);
    Off := Off + SHA256_BLOCK_SIZE;
    Remain := Remain - SHA256_BLOCK_SIZE;
  end;
  FillChar(Block[0], SizeOf(Block), 0);
  if Remain > 0 then
    Move(AData[Off], Block[0], Remain);
  Block[Remain] := $80;
  BitLen := UInt64(ALen) * 8;
  if Remain >= 56 then
  begin
    Compress(State, @Block[0]);
    FillChar(Block[0], SizeOf(Block), 0);
  end;
  Block[56] := Byte(BitLen shr 56);
  Block[57] := Byte(BitLen shr 48);
  Block[58] := Byte(BitLen shr 40);
  Block[59] := Byte(BitLen shr 32);
  Block[60] := Byte(BitLen shr 24);
  Block[61] := Byte(BitLen shr 16);
  Block[62] := Byte(BitLen shr 8);
  Block[63] := Byte(BitLen);
  Compress(State, @Block[0]);
  for I := 0 to 7 do
  begin
    Result[I * 4] := Byte(State[I] shr 24);
    Result[I * 4 + 1] := Byte(State[I] shr 16);
    Result[I * 4 + 2] := Byte(State[I] shr 8);
    Result[I * 4 + 3] := Byte(State[I]);
  end;
end;

{$pop}

function Sha256WasmBytes(const ABytes: TWasmBytes): TSha256Digest;
begin
  if Length(ABytes) = 0 then
    Result := Sha256Bytes(nil, 0)
  else
    Result := Sha256Bytes(@ABytes[0], NativeUInt(Length(ABytes)));
end;

end.
