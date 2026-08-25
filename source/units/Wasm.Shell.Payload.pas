{ Wasm.Shell.Payload — the attach/embed envelope the runtime shell reads
  at startup. This is a TEMPORARY seam for issue #34 so the shell can carry
  a module, complete native code, and stub slots for the connector plan and
  compiled capability set. Issue #35 owns the product payload format
  (versioned header, checksums, target identity, section records) and will
  replace this envelope; ELF/Mach-O placement is #36/#37.

  The native-code slot currently carries a `.waot` blob (Wasm.Aot.Artifact)
  because that is the only complete-code record format the runtime already
  knows how to parse. That reuse is a carrier, not a claim that `.waot` is
  the product payload — `.waot` remains the `run --aot` cache.

  STRUCTURAL ONLY. This unit does not decode wasm, validate, map executable
  memory, or decide capability/connector policy. Those belong to Wasm.Shell. }
unit Wasm.Shell.Payload;

{$I Shared.inc}

interface

uses
  Wasm.Core;

const
  { 'WSH1' — distinct from WAOT so a cache file is never mistaken for a
    shell image. }
  WSHL_MAGIC0 = Byte($57);   { 'W' }
  WSHL_MAGIC1 = Byte($53);   { 'S' }
  WSHL_MAGIC2 = Byte($48);   { 'H' }
  WSHL_MAGIC3 = Byte($31);   { '1' }

  { Envelope version. Bump only for a layout change this reader must reject.
    #35 will introduce the product version space. }
  WSHL_FORMAT_VERSION = UInt16(1);

  { magic(4) + formatVer(2) + flags(2) + four length fields (4*4). }
  WSHL_HEADER_SIZE = 24;

type
  { One parsed shell image. Lengths are authoritative; each section is a
    copy of the corresponding byte range. }
  TWasmShellImage = record
    Module: TWasmBytes;
    Native: TWasmBytes;
    ConnectorPlan: TWasmBytes;
    CapabilitySet: TWasmBytes;
  end;

  TWasmShellParseResult = (
    sprOk,
    sprEmpty,            { no bytes — the unfilled template }
    sprBadMagic,
    sprBadFormatVer,
    sprTruncated,
    sprOverflow
  );

{ Pack the four sections into an envelope. Lengths are stored as 32-bit
  little-endian; a section whose length exceeds High(UInt32) is rejected by
  returning nil (the writer is a test/compile helper, not a guest path). }
function WriteShellPayload(const AModule, ANative, AConnector,
  ACapability: TWasmBytes): TWasmBytes;

{ Bounds-checked reader. On sprOk, AImage holds copies of each section; on
  any other result AImage is empty. }
function ParseShellPayload(const ABytes: TWasmBytes;
  out AImage: TWasmShellImage): TWasmShellParseResult;

implementation

procedure ClearImage(out AImage: TWasmShellImage);
begin
  AImage.Module := nil;
  AImage.Native := nil;
  AImage.ConnectorPlan := nil;
  AImage.CapabilitySet := nil;
end;

function CopyRange(const ABytes: TWasmBytes; const AOff, ALen: NativeUInt): TWasmBytes;
begin
  Result := nil;
  if ALen = 0 then
    Exit;
  SetLength(Result, ALen);
  Move(ABytes[AOff], Result[0], ALen);
end;

procedure WriteU16LE(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AValue: UInt16);
begin
  ABytes[AOff] := Byte(AValue);
  ABytes[AOff + 1] := Byte(AValue shr 8);
end;

procedure WriteU32LE(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AValue: UInt32);
begin
  ABytes[AOff] := Byte(AValue);
  ABytes[AOff + 1] := Byte(AValue shr 8);
  ABytes[AOff + 2] := Byte(AValue shr 16);
  ABytes[AOff + 3] := Byte(AValue shr 24);
end;

function ReadU16LE(const ABytes: TWasmBytes; const AOff: NativeUInt): UInt16;
begin
  Result := UInt16(ABytes[AOff]) or (UInt16(ABytes[AOff + 1]) shl 8);
end;

function ReadU32LE(const ABytes: TWasmBytes; const AOff: NativeUInt): UInt32;
begin
  Result := UInt32(ABytes[AOff])
    or (UInt32(ABytes[AOff + 1]) shl 8)
    or (UInt32(ABytes[AOff + 2]) shl 16)
    or (UInt32(ABytes[AOff + 3]) shl 24);
end;

function WriteShellPayload(const AModule, ANative, AConnector,
  ACapability: TWasmBytes): TWasmBytes;
var
  ModLen, NatLen, ConLen, CapLen, Total: NativeUInt;
  Off: NativeUInt;
begin
  Result := nil;
  ModLen := NativeUInt(Length(AModule));
  NatLen := NativeUInt(Length(ANative));
  ConLen := NativeUInt(Length(AConnector));
  CapLen := NativeUInt(Length(ACapability));
  if (ModLen > High(UInt32)) or (NatLen > High(UInt32)
    ) or (ConLen > High(UInt32)) or (CapLen > High(UInt32)) then
    Exit;
  Total := NativeUInt(WSHL_HEADER_SIZE) + ModLen + NatLen + ConLen + CapLen;
  SetLength(Result, Total);
  Result[0] := WSHL_MAGIC0;
  Result[1] := WSHL_MAGIC1;
  Result[2] := WSHL_MAGIC2;
  Result[3] := WSHL_MAGIC3;
  WriteU16LE(Result, 4, WSHL_FORMAT_VERSION);
  WriteU16LE(Result, 6, 0);
  WriteU32LE(Result, 8, UInt32(ModLen));
  WriteU32LE(Result, 12, UInt32(NatLen));
  WriteU32LE(Result, 16, UInt32(ConLen));
  WriteU32LE(Result, 20, UInt32(CapLen));
  Off := NativeUInt(WSHL_HEADER_SIZE);
  if ModLen > 0 then
    Move(AModule[0], Result[Off], ModLen);
  Off := Off + ModLen;
  if NatLen > 0 then
    Move(ANative[0], Result[Off], NatLen);
  Off := Off + NatLen;
  if ConLen > 0 then
    Move(AConnector[0], Result[Off], ConLen);
  Off := Off + ConLen;
  if CapLen > 0 then
    Move(ACapability[0], Result[Off], CapLen);
end;

function ParseShellPayload(const ABytes: TWasmBytes;
  out AImage: TWasmShellImage): TWasmShellParseResult;
var
  FormatVer: UInt16;
  ModLen, NatLen, ConLen, CapLen, Need, Off: NativeUInt;
begin
  ClearImage(AImage);
  if Length(ABytes) = 0 then
    Exit(sprEmpty);
  if NativeUInt(Length(ABytes)) < NativeUInt(WSHL_HEADER_SIZE) then
    Exit(sprTruncated);
  if (ABytes[0] <> WSHL_MAGIC0) or (ABytes[1] <> WSHL_MAGIC1
    ) or (ABytes[2] <> WSHL_MAGIC2) or (ABytes[3] <> WSHL_MAGIC3) then
    Exit(sprBadMagic);
  FormatVer := ReadU16LE(ABytes, 4);
  if FormatVer <> WSHL_FORMAT_VERSION then
    Exit(sprBadFormatVer);
  ModLen := ReadU32LE(ABytes, 8);
  NatLen := ReadU32LE(ABytes, 12);
  ConLen := ReadU32LE(ABytes, 16);
  CapLen := ReadU32LE(ABytes, 20);
  Need := NativeUInt(WSHL_HEADER_SIZE);
  if Need + ModLen < Need then
    Exit(sprOverflow);
  Need := Need + ModLen;
  if Need + NatLen < Need then
    Exit(sprOverflow);
  Need := Need + NatLen;
  if Need + ConLen < Need then
    Exit(sprOverflow);
  Need := Need + ConLen;
  if Need + CapLen < Need then
    Exit(sprOverflow);
  Need := Need + CapLen;
  if NativeUInt(Length(ABytes)) < Need then
    Exit(sprTruncated);
  if NativeUInt(Length(ABytes)) <> Need then
    Exit(sprTruncated);
  Off := NativeUInt(WSHL_HEADER_SIZE);
  AImage.Module := CopyRange(ABytes, Off, ModLen);
  Off := Off + ModLen;
  AImage.Native := CopyRange(ABytes, Off, NatLen);
  Off := Off + NatLen;
  AImage.ConnectorPlan := CopyRange(ABytes, Off, ConLen);
  Off := Off + ConLen;
  AImage.CapabilitySet := CopyRange(ABytes, Off, CapLen);
  Result := sprOk;
end;

end.
