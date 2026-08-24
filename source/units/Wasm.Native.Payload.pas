{ Wasm.Native.Payload — the embedded native-executable payload: a versioned,
  bounds-checked container for the original module, complete native code, the
  connector plan, and the compiled capability set (ADR-0015).

  PURE FORMAT. This unit lays out and parses payload bytes and nothing else: it
  does not emit machine code, package ELF/Mach-O, decode wasm, or interpret a
  connector plan. Those belong to later compile-path units. Every guarded
  identity field — IR version, target arch/OS, ABI fingerprint, module hash,
  shell hash — is PASSED IN by the writer and READ OUT for the shell to compare
  against the live target. That keeps trust decisions out of the serializer, so
  this unit depends on Wasm.Core alone.

  DISTINCT FROM `.waot`. A `.waot` file is a per-module performance cache that
  may omit declined functions and is never a product contract (ADR-0015). This
  payload is all-or-fail: every function record carries code, the four required
  section kinds must be present exactly once, and a malformed payload is
  rejected before any execution tier sees it.

  WHY FIXED-WIDTH LE, not LEB128: the wasm binary format uses LEB128 for wire
  compactness; a payload is an INTERNAL container indexed by a section
  directory, so fixed-width lets the reader validate every offset and count
  before trusting a byte. Both first-release targets are little-endian.

  THE HASHES use FNV-1a (RFC 9923) with the same parameters as `.waot`, so a
  module hash computed either side is comparable. They are deterministic and
  dependency-free (AGENTS.md: no new dependency). moduleHash is FNV-1a-128 over
  the original module bytes and must match the module section; shellHash is
  FNV-1a-128 over the caller-supplied target-shell identity; each section also
  carries its own content hash; selfChecksum is FNV-1a-64 over the body
  (everything after the header). These are corruption/identity guards, not
  authentication — the payload is not a trust boundary; startup still
  re-validates the embedded module (ADR-0015).

  A malformed payload is NOT an EWasmDecodeError (that vocabulary is for wasm
  MODULES). The reader reports a distinct TWasmNativePayloadParseResult so a
  future shell can reject before execution without collapsing the error
  hierarchy.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Depends on Wasm.Core. }
unit Wasm.Native.Payload;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  { 'WNEP' — Wasmlight Native Executable Payload. }
  WNEP_MAGIC0 = Byte($57);   { 'W' }
  WNEP_MAGIC1 = Byte($4E);   { 'N' }
  WNEP_MAGIC2 = Byte($45);   { 'E' }
  WNEP_MAGIC3 = Byte($50);   { 'P' }

  { Container format version. Starts at 1; bumped only for a layout change the
    reader must reject rather than misread. Distinct from the IR format version,
    which the header ALSO records. }
  WNEP_FORMAT_VERSION = UInt16(1);

  { targetArch ids — same numbering as `.waot` so a compile-path caller can pass
    one arch token to both containers. }
  WNEP_ARCH_UNKNOWN = Byte(0);
  WNEP_ARCH_AARCH64 = Byte(1);
  WNEP_ARCH_X64 = Byte(2);

  { targetOs ids. The first released target set is Linux and Darwin (ADR-0015). }
  WNEP_OS_UNKNOWN = Byte(0);
  WNEP_OS_LINUX = Byte(1);
  WNEP_OS_DARWIN = Byte(2);

  { Required section kinds. Version 1 recognises only these four; any other
    kind is rejected so an older reader cannot skip a record a newer writer
    required. }
  WNEP_SECTION_MODULE = UInt16(1);
  WNEP_SECTION_CODE = UInt16(2);
  WNEP_SECTION_CONNECTOR_PLAN = UInt16(3);
  WNEP_SECTION_CAPABILITY_SET = UInt16(4);

  { Fixed header size: magic(4) + formatVer(2) + irFormatVer(2) + targetArch(1)
    + targetOs(1) + flags(2) + abiFingerprint(8) + moduleHash(16) +
    shellHash(16) + sectionCount(4) + selfChecksum(8) = 64. The body (directory
    then section bytes) begins here, and selfChecksum covers exactly
    [WNEP_HEADER_SIZE .. end). }
  WNEP_HEADER_SIZE = 64;

  { One directory entry: kind(2) + flags(2) + dataOffset(4) + dataSize(4) +
    contentHash(16) + reserved(4) = 32. }
  WNEP_DIR_ENTRY_SIZE = 32;

  { Byte offset of sectionCount and selfChecksum within the header — tests and
    the overflow guard read these without trusting the rest of the body. }
  WNEP_SECTIONCOUNT_OFFSET = 52;
  WNEP_SELFCHECKSUM_OFFSET = 56;

type
  { A 128-bit content hash (FNV-1a-128), stored little-endian as [Lo][Hi]. }
  TWasmNativeHash128 = record
    Lo: UInt64;
    Hi: UInt64;
  end;

  { One compiled function in the native-code section. Unlike `.waot` there is
    no declined flag: a payload that omitted code is incomplete and rejected. }
  TWasmNativeCodeRecord = record
    FuncIrIndex: UInt32;
    RegisterCount: UInt32;
    EntryOffset: UInt32;
    Code: TWasmBytes;
  end;
  TWasmNativeCodeRecords = array of TWasmNativeCodeRecord;

  { One directory entry after its extents and content hash have been checked. }
  TWasmNativeSectionRecord = record
    Kind: UInt16;
    Flags: UInt16;
    DataOffset: UInt32;
    DataSize: UInt32;
    ContentHash: TWasmNativeHash128;
    Bytes: TWasmBytes;
  end;
  TWasmNativeSectionRecords = array of TWasmNativeSectionRecord;

  { The parsed, non-body header fields. The shell compares IrFormatVer,
    TargetArch, TargetOs, AbiFingerprint, ModuleHash, and ShellHash against the
    live target and the embedded module; SelfChecksum and the format version
    the reader already verified. }
  TWasmNativePayloadHeader = record
    FormatVer: UInt16;
    IrFormatVer: UInt16;
    TargetArch: Byte;
    TargetOs: Byte;
    Flags: UInt16;
    AbiFingerprint: UInt64;
    ModuleHash: TWasmNativeHash128;
    ShellHash: TWasmNativeHash128;
    SectionCount: UInt32;
    SelfChecksum: UInt64;
  end;

  { A fully-parsed payload: the header, the directory, and the four required
    records lifted into named fields. }
  TWasmNativePayload = record
    Header: TWasmNativePayloadHeader;
    Sections: TWasmNativeSectionRecords;
    ModuleBytes: TWasmBytes;
    Funcs: TWasmNativeCodeRecords;
    ConnectorPlan: TWasmBytes;
    CapabilitySet: TWasmBytes;
  end;

  { Structural parse outcome. Distinct reasons so a shell can reject before
    execution without collapsing decode/validation/link/trap classes. }
  TWasmNativePayloadParseResult = (
    nprOk,
    nprBadMagic,               { not a native-executable payload }
    nprIncompatibleVersion,    { a container version this reader cannot decode }
    nprTruncated,              { buffer shorter than a declared extent }
    nprOverflow,               { a count or offset+size wrapped }
    nprBadChecksum,            { selfChecksum mismatch — corrupt/partial }
    nprDuplicate,              { a required kind appeared more than once }
    nprMissingRequired,        { a required kind is absent }
    nprOverlap,                { two nonempty extents share a byte, or data
                                 overlaps the header/directory }
    nprBadSectionHash,         { a section's content hash does not match }
    nprIdentityMismatch,       { header.moduleHash is not the module section }
    nprUnknownSection,         { a kind this version does not define }
    nprMalformed               { an inner record was structurally unreadable }
  );

  { The writer's inputs — identity fields the CALLER supplies from the selected
    target and the source module. formatVer, sectionCount, per-section hashes,
    and selfChecksum are the writer's own. }
  TWasmNativePayloadWriteParams = record
    IrFormatVer: UInt16;
    TargetArch: Byte;
    TargetOs: Byte;
    Flags: UInt16;
    AbiFingerprint: UInt64;
    ModuleHash: TWasmNativeHash128;
    ShellHash: TWasmNativeHash128;
    ModuleBytes: TWasmBytes;
    Funcs: TWasmNativeCodeRecords;
    ConnectorPlan: TWasmBytes;
    CapabilitySet: TWasmBytes;
  end;

{ --- content hashes ------------------------------------------------------- }

{ FNV-1a-128 over a raw byte range — moduleHash, shellHash, and per-section
  content hashes. }
function WnepHash128(const AData: PByte; const ALen: NativeUInt): TWasmNativeHash128;
{ Convenience over a byte array. }
function WnepHash128Bytes(const ABytes: TWasmBytes): TWasmNativeHash128;
{ FNV-1a-64 over a raw byte range — the selfChecksum primitive. }
function WnepHash64(const AData: PByte; const ALen: NativeUInt): UInt64;
{ True iff two 128-bit hashes are equal. }
function WnepHash128Equal(const A, B: TWasmNativeHash128): Boolean;

{ --- writer --------------------------------------------------------------- }

{ Serialize a payload: the fixed header, a four-entry directory, then the
  module bytes, complete code records, connector-plan bytes, and capability-set
  bytes. Raises EWasmInternal if the caller omitted the module or a function's
  code — those are compile-path invariant defects, not a well-formed empty
  payload. }
function WriteNativePayload(const AParams: TWasmNativePayloadWriteParams): TWasmBytes;

{ --- reader --------------------------------------------------------------- }

{ Parse and structurally validate a payload: verify the magic and format
  version, reject overflowing counts, validate every directory offset and size
  against the buffer (and against the other extents) BEFORE reading section
  bodies, then check the selfChecksum, required kinds, per-section hashes, and
  the module-hash identity bind. On nprOk, APayload holds the header and the
  four required records; on any other result APayload is undefined. }
function ParseNativePayload(const ABytes: TWasmBytes;
  out APayload: TWasmNativePayload): TWasmNativePayloadParseResult;

implementation

{ --- FNV-1a hashing (RFC 9923; same parameters as Wasm.Aot.Artifact) ------

  FNV wraps modulo 2^n by design, so the multiplies below must run with
  overflow/range checks OFF (they are on project-wide via Shared.inc). }
{$push}{$Q-}{$R-}

const
  FNV64_OFFSET = UInt64($CBF29CE484222325);
  FNV64_PRIME = UInt64($00000100000001B3);

  { FNV-1a-128 offset basis = 0x6c62272e07bb014262b821756295c58d, split LE. }
  FNV128_OFFSET_HI = UInt64($6C62272E07BB0142);
  FNV128_OFFSET_LO = UInt64($62B821756295C58D);
  { FNV-1a-128 prime = 2^88 + 2^8 + 0x3b = 0x0000000001000000_000000000000013B. }
  FNV128_PRIME_HI = UInt64($0000000001000000);
  FNV128_PRIME_LO = UInt64($000000000000013B);

procedure Mul64Full(const A, B: UInt64; out AHi, ALo: UInt64);
var
  A0, A1, B0, B1: UInt64;
  P00, P01, P10, P11, Mid: UInt64;
begin
  A0 := A and $FFFFFFFF;
  A1 := A shr 32;
  B0 := B and $FFFFFFFF;
  B1 := B shr 32;
  P00 := A0 * B0;
  P01 := A0 * B1;
  P10 := A1 * B0;
  P11 := A1 * B1;
  Mid := (P00 shr 32) + (P01 and $FFFFFFFF) + (P10 and $FFFFFFFF);
  ALo := (P00 and $FFFFFFFF) or (Mid shl 32);
  AHi := P11 + (P01 shr 32) + (P10 shr 32) + (Mid shr 32);
end;

procedure Mul128ByPrime(var AHi, ALo: UInt64);
var
  LlHi, LlLo: UInt64;
begin
  Mul64Full(ALo, FNV128_PRIME_LO, LlHi, LlLo);
  AHi := LlHi + (ALo * FNV128_PRIME_HI) + (AHi * FNV128_PRIME_LO);
  ALo := LlLo;
end;

function WnepHash128(const AData: PByte; const ALen: NativeUInt): TWasmNativeHash128;
var
  P: PByte;
  I: NativeUInt;
begin
  Result.Hi := FNV128_OFFSET_HI;
  Result.Lo := FNV128_OFFSET_LO;
  P := AData;
  I := 0;
  while I < ALen do
  begin
    Result.Lo := Result.Lo xor UInt64(P^);
    Mul128ByPrime(Result.Hi, Result.Lo);
    Inc(P);
    Inc(I);
  end;
end;

function WnepHash128Bytes(const ABytes: TWasmBytes): TWasmNativeHash128;
begin
  if Length(ABytes) = 0 then
    Result := WnepHash128(nil, 0)
  else
    Result := WnepHash128(@ABytes[0], NativeUInt(Length(ABytes)));
end;

function WnepHash64(const AData: PByte; const ALen: NativeUInt): UInt64;
var
  P: PByte;
  I: NativeUInt;
begin
  Result := FNV64_OFFSET;
  P := AData;
  I := 0;
  while I < ALen do
  begin
    Result := Result xor UInt64(P^);
    Result := Result * FNV64_PRIME;
    Inc(P);
    Inc(I);
  end;
end;

{$pop}

function WnepHash128Equal(const A, B: TWasmNativeHash128): Boolean;
begin
  Result := (A.Lo = B.Lo) and (A.Hi = B.Hi);
end;

{ --- overflow-safe unsigned arithmetic ------------------------------------

  Shared.inc turns overflow checks on in non-PRODUCTION builds. A wrapping
  add/mul must be detected by a pre-check, never by letting the RTL raise. }

function AddU32(const A, B: UInt32; out ASum: UInt32): Boolean;
begin
  if A > $FFFFFFFF - B then
  begin
    ASum := 0;
    Exit(False);
  end;
  ASum := A + B;
  Result := True;
end;

function MulU32(const A, B: UInt32; out AProd: UInt32): Boolean;
begin
  if (B <> 0) and (A > $FFFFFFFF div B) then
  begin
    AProd := 0;
    Exit(False);
  end;
  AProd := A * B;
  Result := True;
end;

{ --- fixed-width little-endian primitives --------------------------------- }

type
  TWnepWriter = record
    Buf: TWasmBytes;
    Len: Integer;
  end;

procedure WEnsure(var AW: TWnepWriter; const AExtra: Integer);
var
  Cap: Integer;
begin
  if AW.Len + AExtra <= Length(AW.Buf) then
    Exit;
  Cap := Length(AW.Buf);
  if Cap = 0 then
    Cap := 64;
  while Cap < AW.Len + AExtra do
    Cap := Cap * 2;
  SetLength(AW.Buf, Cap);
end;

procedure WU8(var AW: TWnepWriter; const AValue: Byte);
begin
  WEnsure(AW, 1);
  AW.Buf[AW.Len] := AValue;
  Inc(AW.Len);
end;

procedure WU16(var AW: TWnepWriter; const AValue: UInt16);
begin
  WEnsure(AW, 2);
  AW.Buf[AW.Len] := Byte(AValue);
  AW.Buf[AW.Len + 1] := Byte(AValue shr 8);
  Inc(AW.Len, 2);
end;

procedure WU32(var AW: TWnepWriter; const AValue: UInt32);
begin
  WEnsure(AW, 4);
  AW.Buf[AW.Len] := Byte(AValue);
  AW.Buf[AW.Len + 1] := Byte(AValue shr 8);
  AW.Buf[AW.Len + 2] := Byte(AValue shr 16);
  AW.Buf[AW.Len + 3] := Byte(AValue shr 24);
  Inc(AW.Len, 4);
end;

procedure WU64(var AW: TWnepWriter; const AValue: UInt64);
begin
  WEnsure(AW, 8);
  AW.Buf[AW.Len] := Byte(AValue);
  AW.Buf[AW.Len + 1] := Byte(AValue shr 8);
  AW.Buf[AW.Len + 2] := Byte(AValue shr 16);
  AW.Buf[AW.Len + 3] := Byte(AValue shr 24);
  AW.Buf[AW.Len + 4] := Byte(AValue shr 32);
  AW.Buf[AW.Len + 5] := Byte(AValue shr 40);
  AW.Buf[AW.Len + 6] := Byte(AValue shr 48);
  AW.Buf[AW.Len + 7] := Byte(AValue shr 56);
  Inc(AW.Len, 8);
end;

procedure WBytes(var AW: TWnepWriter; const ABytes: TWasmBytes);
var
  I: Integer;
begin
  if Length(ABytes) = 0 then
    Exit;
  WEnsure(AW, Length(ABytes));
  for I := 0 to High(ABytes) do
    AW.Buf[AW.Len + I] := ABytes[I];
  Inc(AW.Len, Length(ABytes));
end;

procedure WPadTo16(var AW: TWnepWriter; const ARegionStart: Integer);
var
  Rem: Integer;
begin
  Rem := (AW.Len - ARegionStart) and 15;
  if Rem <> 0 then
    while Rem < 16 do
    begin
      WU8(AW, 0);
      Inc(Rem);
    end;
end;

procedure WHash128(var AW: TWnepWriter; const AHash: TWasmNativeHash128);
begin
  WU64(AW, AHash.Lo);
  WU64(AW, AHash.Hi);
end;

function WriterBytes(var AW: TWnepWriter): TWasmBytes;
begin
  SetLength(AW.Buf, AW.Len);
  Result := AW.Buf;
end;

type
  { A bounds-checked LE reader. Pos never advances past Len; a would-be
    over-read sets Bad and every subsequent read is a no-op. }
  TWnepReader = record
    Data: PByte;
    Len: NativeUInt;
    Pos: NativeUInt;
    Bad: Boolean;
  end;

function RU8(var AR: TWnepReader): Byte;
begin
  if AR.Bad or (AR.Pos + 1 > AR.Len) then
  begin
    AR.Bad := True;
    Result := 0;
    Exit;
  end;
  Result := (AR.Data + AR.Pos)^;
  Inc(AR.Pos);
end;

function RU16(var AR: TWnepReader): UInt16;
var
  B0, B1: Byte;
begin
  B0 := RU8(AR);
  B1 := RU8(AR);
  Result := UInt16(B0) or (UInt16(B1) shl 8);
end;

function RU32(var AR: TWnepReader): UInt32;
var
  B0, B1, B2, B3: Byte;
begin
  B0 := RU8(AR);
  B1 := RU8(AR);
  B2 := RU8(AR);
  B3 := RU8(AR);
  Result := UInt32(B0) or (UInt32(B1) shl 8) or (UInt32(B2) shl 16)
    or (UInt32(B3) shl 24);
end;

function RU64(var AR: TWnepReader): UInt64;
var
  Lo, Hi: UInt32;
begin
  Lo := RU32(AR);
  Hi := RU32(AR);
  Result := UInt64(Lo) or (UInt64(Hi) shl 32);
end;

function RHash128(var AR: TWnepReader): TWasmNativeHash128;
begin
  Result.Lo := RU64(AR);
  Result.Hi := RU64(AR);
end;

function RBytes(var AR: TWnepReader; const ACount: UInt32): TWasmBytes;
begin
  Result := nil;
  if AR.Bad or (AR.Pos + ACount > AR.Len) then
  begin
    AR.Bad := True;
    Exit;
  end;
  SetLength(Result, ACount);
  if ACount > 0 then
    Move((AR.Data + AR.Pos)^, Result[0], ACount);
  Inc(AR.Pos, ACount);
end;

procedure RSkipPadTo16(var AR: TWnepReader; const ARegionStart: NativeUInt);
var
  Rem: NativeUInt;
begin
  Rem := (AR.Pos - ARegionStart) and 15;
  if Rem <> 0 then
  begin
    Rem := 16 - Rem;
    if AR.Pos + Rem > AR.Len then
      AR.Bad := True
    else
      Inc(AR.Pos, Rem);
  end;
end;

{ --- code-section codec --------------------------------------------------- }

function EncodeCodeSection(const AFuncs: TWasmNativeCodeRecords): TWasmBytes;
var
  W: TWnepWriter;
  I, CodeStart: Integer;
begin
  W.Buf := nil;
  W.Len := 0;
  WU32(W, UInt32(Length(AFuncs)));
  for I := 0 to High(AFuncs) do
  begin
    if Length(AFuncs[I].Code) = 0 then
      raise EWasmInternal.Create(
        'internal: native payload function record has no code');
    WU32(W, AFuncs[I].FuncIrIndex);
    WU32(W, AFuncs[I].RegisterCount);
    WU32(W, AFuncs[I].EntryOffset);
    WU32(W, UInt32(Length(AFuncs[I].Code)));
    CodeStart := W.Len;
    WBytes(W, AFuncs[I].Code);
    WPadTo16(W, CodeStart);
  end;
  Result := WriterBytes(W);
end;

function ParseCodeSection(const ABytes: TWasmBytes;
  out AFuncs: TWasmNativeCodeRecords): TWasmNativePayloadParseResult;
var
  R: TWnepReader;
  FuncCount, CodeLen: UInt32;
  I: Integer;
  CodeStart: NativeUInt;
begin
  AFuncs := nil;
  if Length(ABytes) < 4 then
    Exit(nprMalformed);

  R.Data := @ABytes[0];
  R.Len := NativeUInt(Length(ABytes));
  R.Pos := 0;
  R.Bad := False;

  FuncCount := RU32(R);
  { Every function record is at least four u32s (16 bytes). A count that cannot
    fit is an overflow of the declared extent, not a later over-read. The
    multiply is checked before it is used as a length. }
  if FuncCount > 0 then
  begin
    if not MulU32(FuncCount, 16, CodeLen) then
      Exit(nprOverflow);
    if not AddU32(4, CodeLen, CodeLen) then
      Exit(nprOverflow);
    if R.Len < NativeUInt(CodeLen) then
      Exit(nprOverflow);
  end;

  SetLength(AFuncs, FuncCount);
  for I := 0 to Integer(FuncCount) - 1 do
  begin
    AFuncs[I].FuncIrIndex := RU32(R);
    AFuncs[I].RegisterCount := RU32(R);
    AFuncs[I].EntryOffset := RU32(R);
    CodeLen := RU32(R);
    if CodeLen = 0 then
      Exit(nprMalformed);
    CodeStart := R.Pos;
    AFuncs[I].Code := RBytes(R, CodeLen);
    RSkipPadTo16(R, CodeStart);
    if R.Bad then
      Exit(nprMalformed);
  end;

  if R.Bad then
    Exit(nprMalformed);
  { The code section is exactly the records: leftover bytes would let a writer
    hide a fifth record past the declared funcCount. }
  if R.Pos <> R.Len then
    Exit(nprMalformed);
  Result := nprOk;
end;

{ --- writer --------------------------------------------------------------- }

function WriteNativePayload(const AParams: TWasmNativePayloadWriteParams): TWasmBytes;
var
  CodeSec, Body: TWasmBytes;
  Out_: TWnepWriter;
  Offsets, Sizes: array[0..3] of UInt32;
  Hashes: array[0..3] of TWasmNativeHash128;
  Blobs: array[0..3] of TWasmBytes;
  Kinds: array[0..3] of UInt16;
  Cursor, TableEnd, I: UInt32;
  Checksum: UInt64;
begin
  if Length(AParams.ModuleBytes) = 0 then
    raise EWasmInternal.Create(
      'internal: native payload is missing the original module bytes');
  if not WnepHash128Equal(WnepHash128Bytes(AParams.ModuleBytes), AParams.ModuleHash) then
    raise EWasmInternal.Create(
      'internal: native payload moduleHash does not match module bytes');

  CodeSec := EncodeCodeSection(AParams.Funcs);

  Kinds[0] := WNEP_SECTION_MODULE;
  Kinds[1] := WNEP_SECTION_CODE;
  Kinds[2] := WNEP_SECTION_CONNECTOR_PLAN;
  Kinds[3] := WNEP_SECTION_CAPABILITY_SET;
  Blobs[0] := AParams.ModuleBytes;
  Blobs[1] := CodeSec;
  Blobs[2] := AParams.ConnectorPlan;
  Blobs[3] := AParams.CapabilitySet;

  TableEnd := WNEP_HEADER_SIZE + (4 * WNEP_DIR_ENTRY_SIZE);
  Cursor := TableEnd;
  for I := 0 to 3 do
  begin
    Offsets[I] := Cursor;
    Sizes[I] := UInt32(Length(Blobs[I]));
    Hashes[I] := WnepHash128Bytes(Blobs[I]);
    if not AddU32(Cursor, Sizes[I], Cursor) then
      raise EWasmInternal.Create('internal: native payload section extents overflow');
  end;

  { Body = directory + section bytes, so the checksum can cover it before the
    header is prefixed. }
  Out_.Buf := nil;
  Out_.Len := 0;
  for I := 0 to 3 do
  begin
    WU16(Out_, Kinds[I]);
    WU16(Out_, 0);
    WU32(Out_, Offsets[I]);
    WU32(Out_, Sizes[I]);
    WHash128(Out_, Hashes[I]);
    WU32(Out_, 0);
  end;
  for I := 0 to 3 do
    WBytes(Out_, Blobs[I]);
  Body := WriterBytes(Out_);

  if Length(Body) = 0 then
    Checksum := WnepHash64(nil, 0)
  else
    Checksum := WnepHash64(@Body[0], NativeUInt(Length(Body)));

  Out_.Buf := nil;
  Out_.Len := 0;
  WU8(Out_, WNEP_MAGIC0);
  WU8(Out_, WNEP_MAGIC1);
  WU8(Out_, WNEP_MAGIC2);
  WU8(Out_, WNEP_MAGIC3);
  WU16(Out_, WNEP_FORMAT_VERSION);
  WU16(Out_, AParams.IrFormatVer);
  WU8(Out_, AParams.TargetArch);
  WU8(Out_, AParams.TargetOs);
  WU16(Out_, AParams.Flags);
  WU64(Out_, AParams.AbiFingerprint);
  WHash128(Out_, AParams.ModuleHash);
  WHash128(Out_, AParams.ShellHash);
  WU32(Out_, 4);
  WU64(Out_, Checksum);
  if Out_.Len <> WNEP_HEADER_SIZE then
    raise EWasmInternal.CreateFmt(
      'internal: native payload header is %d bytes, expected %d',
      [Out_.Len, WNEP_HEADER_SIZE]);
  WBytes(Out_, Body);
  Result := WriterBytes(Out_);
end;

{ --- reader --------------------------------------------------------------- }

procedure ClearPayload(out APayload: TWasmNativePayload);
begin
  FillChar(APayload.Header, SizeOf(APayload.Header), 0);
  APayload.Sections := nil;
  APayload.ModuleBytes := nil;
  APayload.Funcs := nil;
  APayload.ConnectorPlan := nil;
  APayload.CapabilitySet := nil;
end;

function InitReader(const ABytes: TWasmBytes; out AR: TWnepReader): Boolean;
begin
  if Length(ABytes) = 0 then
  begin
    AR.Data := nil;
    AR.Len := 0;
    AR.Pos := 0;
    AR.Bad := True;
    Exit(False);
  end;
  AR.Data := @ABytes[0];
  AR.Len := NativeUInt(Length(ABytes));
  AR.Pos := 0;
  AR.Bad := False;
  Result := True;
end;

function ExtentsOverlap(const AOffA, ASizeA, AOffB, ASizeB: UInt32): Boolean;
var
  EndA, EndB: UInt32;
begin
  { Empty extents do not occupy a byte. }
  if (ASizeA = 0) or (ASizeB = 0) then
    Exit(False);
  if not AddU32(AOffA, ASizeA, EndA) then
    Exit(True);
  if not AddU32(AOffB, ASizeB, EndB) then
    Exit(True);
  Result := not ((EndA <= AOffB) or (EndB <= AOffA));
end;

function ParseNativePayload(const ABytes: TWasmBytes;
  out APayload: TWasmNativePayload): TWasmNativePayloadParseResult;
var
  R: TWnepReader;
  TableBytes, TableEnd, FileLen32, EndOff: UInt32;
  I, J: Integer;
  StoredChecksum, ComputedChecksum: UInt64;
  Seen: array[WNEP_SECTION_MODULE..WNEP_SECTION_CAPABILITY_SET] of Boolean;
  Kind: UInt16;
  SectionHash: TWasmNativeHash128;
  CodeRes: TWasmNativePayloadParseResult;
begin
  ClearPayload(APayload);

  if Length(ABytes) < WNEP_HEADER_SIZE then
    Exit(nprTruncated);

  if not InitReader(ABytes, R) then
    Exit(nprTruncated);

  if (RU8(R) <> WNEP_MAGIC0) or (RU8(R) <> WNEP_MAGIC1)
    or (RU8(R) <> WNEP_MAGIC2) or (RU8(R) <> WNEP_MAGIC3) then
    Exit(nprBadMagic);

  APayload.Header.FormatVer := RU16(R);
  if APayload.Header.FormatVer <> WNEP_FORMAT_VERSION then
    Exit(nprIncompatibleVersion);

  APayload.Header.IrFormatVer := RU16(R);
  APayload.Header.TargetArch := RU8(R);
  APayload.Header.TargetOs := RU8(R);
  APayload.Header.Flags := RU16(R);
  APayload.Header.AbiFingerprint := RU64(R);
  APayload.Header.ModuleHash := RHash128(R);
  APayload.Header.ShellHash := RHash128(R);
  APayload.Header.SectionCount := RU32(R);
  StoredChecksum := RU64(R);
  APayload.Header.SelfChecksum := StoredChecksum;
  if R.Bad then
    Exit(nprTruncated);

  { Counts are validated before the directory is allocated or any offset is
    used as an index. }
  if not MulU32(APayload.Header.SectionCount, WNEP_DIR_ENTRY_SIZE, TableBytes) then
    Exit(nprOverflow);
  if not AddU32(WNEP_HEADER_SIZE, TableBytes, TableEnd) then
    Exit(nprOverflow);
  if NativeUInt(TableEnd) > R.Len then
    Exit(nprTruncated);

  SetLength(APayload.Sections, APayload.Header.SectionCount);
  for I := 0 to Integer(APayload.Header.SectionCount) - 1 do
  begin
    APayload.Sections[I].Kind := RU16(R);
    APayload.Sections[I].Flags := RU16(R);
    APayload.Sections[I].DataOffset := RU32(R);
    APayload.Sections[I].DataSize := RU32(R);
    APayload.Sections[I].ContentHash := RHash128(R);
    RU32(R);   { reserved }
    if R.Bad then
      Exit(nprTruncated);
  end;

  { File length fits a u32 on this format: offsets are u32. A buffer longer
    than 4 GiB is rejected rather than silently wrapping a comparison. }
  if R.Len > $FFFFFFFF then
    Exit(nprOverflow);
  FileLen32 := UInt32(R.Len);

  for I := 0 to Integer(APayload.Header.SectionCount) - 1 do
  begin
    if not AddU32(APayload.Sections[I].DataOffset, APayload.Sections[I].DataSize,
      EndOff) then
      Exit(nprOverflow);
    if APayload.Sections[I].DataOffset < TableEnd then
      Exit(nprOverlap);
    if EndOff > FileLen32 then
      Exit(nprTruncated);
    for J := 0 to I - 1 do
      if ExtentsOverlap(
        APayload.Sections[I].DataOffset, APayload.Sections[I].DataSize,
        APayload.Sections[J].DataOffset, APayload.Sections[J].DataSize) then
        Exit(nprOverlap);
  end;

  for Kind := WNEP_SECTION_MODULE to WNEP_SECTION_CAPABILITY_SET do
    Seen[Kind] := False;
  for I := 0 to Integer(APayload.Header.SectionCount) - 1 do
  begin
    Kind := APayload.Sections[I].Kind;
    if (Kind < WNEP_SECTION_MODULE) or (Kind > WNEP_SECTION_CAPABILITY_SET) then
      Exit(nprUnknownSection);
    if Seen[Kind] then
      Exit(nprDuplicate);
    Seen[Kind] := True;
  end;
  if not (Seen[WNEP_SECTION_MODULE] and Seen[WNEP_SECTION_CODE]
    and Seen[WNEP_SECTION_CONNECTOR_PLAN] and Seen[WNEP_SECTION_CAPABILITY_SET]) then
    Exit(nprMissingRequired);

  if R.Len = WNEP_HEADER_SIZE then
    ComputedChecksum := WnepHash64(nil, 0)
  else
    ComputedChecksum := WnepHash64(@ABytes[WNEP_HEADER_SIZE],
      R.Len - WNEP_HEADER_SIZE);
  if ComputedChecksum <> StoredChecksum then
    Exit(nprBadChecksum);

  { Offsets are now known in-bounds and non-overlapping. Copy each body with
    the already-checked size; do not re-trust the directory as a cursor. }
  for I := 0 to Integer(APayload.Header.SectionCount) - 1 do
  begin
    SetLength(APayload.Sections[I].Bytes, APayload.Sections[I].DataSize);
    if APayload.Sections[I].DataSize > 0 then
      Move(ABytes[APayload.Sections[I].DataOffset],
        APayload.Sections[I].Bytes[0], APayload.Sections[I].DataSize);
    SectionHash := WnepHash128Bytes(APayload.Sections[I].Bytes);
    if not WnepHash128Equal(SectionHash, APayload.Sections[I].ContentHash) then
      Exit(nprBadSectionHash);

    case APayload.Sections[I].Kind of
      WNEP_SECTION_MODULE:
        APayload.ModuleBytes := APayload.Sections[I].Bytes;
      WNEP_SECTION_CONNECTOR_PLAN:
        APayload.ConnectorPlan := APayload.Sections[I].Bytes;
      WNEP_SECTION_CAPABILITY_SET:
        APayload.CapabilitySet := APayload.Sections[I].Bytes;
    end;
  end;

  if Length(APayload.ModuleBytes) = 0 then
    Exit(nprMalformed);
  if not WnepHash128Equal(WnepHash128Bytes(APayload.ModuleBytes),
    APayload.Header.ModuleHash) then
    Exit(nprIdentityMismatch);

  for I := 0 to Integer(APayload.Header.SectionCount) - 1 do
    if APayload.Sections[I].Kind = WNEP_SECTION_CODE then
    begin
      CodeRes := ParseCodeSection(APayload.Sections[I].Bytes, APayload.Funcs);
      if CodeRes <> nprOk then
        Exit(CodeRes);
    end;

  Result := nprOk;
end;

end.
