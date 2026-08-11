{ Wasm.Aot.Artifact — the `.waot` ahead-of-time artifact format: the fixed-width
  little-endian reader and writer, the content hashes, and the reloc-table
  encode/decode (.agent/design/aot-spec.md §2).

  PURE FORMAT. This unit knows how to lay out and parse the bytes of a `.waot`
  file and nothing else: it does not emit machine code, map memory, decode wasm,
  or compute the ABI fingerprint. Those are the loader's job (Wasm.Aot). Every
  value the format guards on — the IR version, the target arch, the ABI
  fingerprint, the module hash — is PASSED IN by the writer's caller and READ OUT
  for the loader's caller to compare against the live runtime. That keeps the
  trust decisions in one place (Wasm.Aot, aot-spec §4) and this unit a mechanical
  serializer, so it depends on Wasm.Core alone.

  WHY FIXED-WIDTH LE, not LEB128 (§2.1): the wasm binary format uses LEB128 for
  wire compactness; an artifact is an INTERNAL cache optimised for load speed, so
  fixed-width lets the loader index the mapped bytes in O(1). Both AOT target
  arches are little-endian, so LE needs no per-load byte-swap.

  THE HASHES (§2.4) are deterministic, in-repo, dependency-free (AGENTS.md: no
  new dependency). moduleHash is FNV-1a-128 over the SOURCE `.wasm` bytes — 128
  bits so an accidental content collision is negligible; it binds an artifact to
  one module so a stale artifact for a since-changed module is rejected.
  selfChecksum is FNV-1a-64 over the artifact BODY (everything after the checksum
  field) — a corruption/truncation guard, not authentication (§2.4 threat model:
  the artifact and the runtime are the same trust domain).

  A malformed artifact is NOT an EWasmDecodeError (that vocabulary is for wasm
  MODULES, reached through Wasm.Binary). The reader reports a distinct
  TWasmAotParseResult so the loader can log WHY it fell back to the interpreter;
  a rejected-but-well-formed artifact (a version/arch/hash mismatch) is a normal
  fall-back outcome the loader decides, not an exception.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Depends on Wasm.Core. }
unit Wasm.Aot.Artifact;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  { 'WAOT' — the file magic (§2.2). }
  WAOT_MAGIC0 = Byte($57);   { 'W' }
  WAOT_MAGIC1 = Byte($41);   { 'A' }
  WAOT_MAGIC2 = Byte($4F);   { 'O' }
  WAOT_MAGIC3 = Byte($54);   { 'T' }

  { Container format version (§2.2). Starts at 1; bumped only for a layout
    change the reader must reject rather than misread. Distinct from the IR
    format version, which the header ALSO records (guard 3, aot-spec §2.3). }
  WAOT_FORMAT_VERSION = UInt16(1);

  { targetArch ids (§2.2). Both AOT arches; anything else means "no artifact for
    this host" and the loader runs the interpreter. }
  WAOT_ARCH_UNKNOWN = Byte(0);
  WAOT_ARCH_AARCH64 = Byte(1);
  WAOT_ARCH_X64 = Byte(2);

  { funcFlags bit 0 (§2.2): the function's machine code is present. Cleared for a
    DECLINED function (the compile predicate refused it) — codeLength = 0, run
    interpreted at load. }
  WAOT_FUNCFLAG_COMPILED = Byte($01);

  { The fixed header size in bytes (§2.2): magic(4) + aotFormatVer(2) +
    irFormatVer(2) + targetArch(1) + flags(1) + abiFingerprint(8) +
    moduleHash(16) + funcCount(4) + selfChecksum(8). The body (function records)
    begins here, and selfChecksum covers exactly [WAOT_HEADER_SIZE .. end). }
  WAOT_HEADER_SIZE = 46;

  { Byte offset of selfChecksum within the header — the body it hashes starts at
    WAOT_HEADER_SIZE, i.e. right after the field. }
  WAOT_SELFCHECKSUM_OFFSET = 38;

type
  { A 128-bit content hash (FNV-1a-128), stored little-endian as [Lo][Hi]. }
  TWasmAotHash128 = record
    Lo: UInt64;
    Hi: UInt64;
  end;

  { A load-time relocation entry (aot-spec §1.5). EMPTY in the unified
    position-independent emitter — no template bakes an absolute host address —
    but the format carries the table so a future op or the fallback emitter is
    forward-compatible. }
  TWasmAotReloc = record
    SiteOffset: UInt32;
    Kind: Byte;
    Symbol: UInt16;
  end;
  TWasmAotRelocs = array of TWasmAotReloc;

  { One per-function record (§2.2). For a DECLINED function Compiled is False,
    Code is empty, and RegisterCount still carries the IR value (the loader's
    cross-check is meaningful only for compiled functions). }
  TWasmAotFuncRecord = record
    FuncIrIndex: UInt32;
    Compiled: Boolean;
    RegisterCount: UInt32;
    EntryOffset: UInt32;
    Code: TWasmBytes;
    Relocs: TWasmAotRelocs;
  end;
  TWasmAotFuncRecords = array of TWasmAotFuncRecord;

  { The parsed, non-code header fields (§2.2). The loader compares IrFormatVer,
    TargetArch, AbiFingerprint, and ModuleHash against the live runtime and the
    freshly-loaded source bytes (aot-spec §2.3 guards 3-7); SelfChecksum and the
    format version the reader already verified. }
  TWasmAotHeader = record
    AotFormatVer: UInt16;
    IrFormatVer: UInt16;
    TargetArch: Byte;
    Flags: Byte;
    AbiFingerprint: UInt64;
    ModuleHash: TWasmAotHash128;
    FuncCount: UInt32;
    SelfChecksum: UInt64;
  end;

  { A fully-parsed artifact: the header plus the function records. }
  TWasmAotArtifact = record
    Header: TWasmAotHeader;
    Funcs: TWasmAotFuncRecords;
  end;

  { The STRUCTURAL parse outcome (§2). Distinct reasons so the loader logs why a
    file could not even be read as an artifact; the SEMANTIC guards (wrong IR
    version / arch / ABI / module) live in Wasm.Aot, applied to a successfully
    parsed header. }
  TWasmAotParseResult = (
    aprOk,
    aprBadMagic,        { not a `.waot` at all }
    aprBadFormatVer,    { a container version this reader cannot decode }
    aprBadChecksum,     { selfChecksum mismatch — corrupt/truncated/partial }
    aprMalformed        { a length ran past the buffer end }
  );

  { The writer's non-code inputs — the guarded header fields the CALLER supplies
    from the live runtime and the source module (aot-spec §3.1 step 3).
    aotFormatVer and selfChecksum are the writer's own; funcCount is derived. }
  TWasmAotWriteParams = record
    IrFormatVer: UInt16;
    TargetArch: Byte;
    Flags: Byte;
    AbiFingerprint: UInt64;
    ModuleHash: TWasmAotHash128;
  end;

{ --- content hashes (§2.4) ------------------------------------------------ }

{ FNV-1a-128 over a raw byte range — the moduleHash over the source `.wasm`
  bytes. }
function WaotHash128(const AData: PByte; const ALen: NativeUInt): TWasmAotHash128;
{ Convenience over a byte array. }
function WaotHash128Bytes(const ABytes: TWasmBytes): TWasmAotHash128;
{ FNV-1a-64 over a raw byte range — the selfChecksum primitive. }
function WaotHash64(const AData: PByte; const ALen: NativeUInt): UInt64;
{ True iff two 128-bit hashes are equal. }
function WaotHash128Equal(const A, B: TWasmAotHash128): Boolean;

{ --- writer (§2.5) -------------------------------------------------------- }

{ Serialize an artifact: the fixed header (with AParams' guarded fields and the
  computed funcCount + selfChecksum) followed by the function records in the
  order given. AFuncs SHOULD be in funcIrIndex order (the loader does not require
  it, but the format documents it, §2.2). Returns the `.waot` byte buffer. }
function WriteAotArtifact(const AParams: TWasmAotWriteParams;
  const AFuncs: TWasmAotFuncRecords): TWasmBytes;

{ --- reader (§2) ---------------------------------------------------------- }

{ Parse and structurally validate a `.waot` buffer: verify the magic, the
  container format version, and the selfChecksum, then read the header and every
  function record with bounds checks. On aprOk, AArtifact holds the header and
  records; on any other result AArtifact is undefined and the loader falls back.
  The SEMANTIC guards (IR version, arch, ABI, module hash) are NOT applied here —
  they need the live runtime and belong to Wasm.Aot. }
function ParseAotArtifact(const ABytes: TWasmBytes;
  out AArtifact: TWasmAotArtifact): TWasmAotParseResult;

implementation

{ --- FNV-1a hashing -------------------------------------------------------

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

{ 64x64 -> 128 unsigned multiply, low and high halves, via 32-bit limbs (FPC has
  no portable 128-bit integer). }
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

{ (AHi:ALo) := (AHi:ALo) * (FNV128 prime), keeping only the low 128 bits. The
  cross term ah*bh*2^128 drops mod 2^128 (§ derivation in the AOT design). }
procedure Mul128ByPrime(var AHi, ALo: UInt64);
var
  LlHi, LlLo: UInt64;
begin
  Mul64Full(ALo, FNV128_PRIME_LO, LlHi, LlLo);
  AHi := LlHi + (ALo * FNV128_PRIME_HI) + (AHi * FNV128_PRIME_LO);
  ALo := LlLo;
end;

function WaotHash128(const AData: PByte; const ALen: NativeUInt): TWasmAotHash128;
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
    Result.Lo := Result.Lo xor UInt64(P^);   { xor affects only the low byte }
    Mul128ByPrime(Result.Hi, Result.Lo);
    Inc(P);
    Inc(I);
  end;
end;

function WaotHash128Bytes(const ABytes: TWasmBytes): TWasmAotHash128;
begin
  if Length(ABytes) = 0 then
    Result := WaotHash128(nil, 0)
  else
    Result := WaotHash128(@ABytes[0], NativeUInt(Length(ABytes)));
end;

function WaotHash64(const AData: PByte; const ALen: NativeUInt): UInt64;
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

function WaotHash128Equal(const A, B: TWasmAotHash128): Boolean;
begin
  Result := (A.Lo = B.Lo) and (A.Hi = B.Hi);
end;

{ --- fixed-width little-endian primitives --------------------------------- }

type
  { A tiny growable LE writer over a TWasmBytes with an explicit cursor. }
  TWaotWriter = record
    Buf: TWasmBytes;
    Len: Integer;
  end;

procedure WEnsure(var AW: TWaotWriter; const AExtra: Integer);
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

procedure WU8(var AW: TWaotWriter; const AValue: Byte);
begin
  WEnsure(AW, 1);
  AW.Buf[AW.Len] := AValue;
  Inc(AW.Len);
end;

procedure WU16(var AW: TWaotWriter; const AValue: UInt16);
begin
  WEnsure(AW, 2);
  AW.Buf[AW.Len] := Byte(AValue);
  AW.Buf[AW.Len + 1] := Byte(AValue shr 8);
  Inc(AW.Len, 2);
end;

procedure WU32(var AW: TWaotWriter; const AValue: UInt32);
begin
  WEnsure(AW, 4);
  AW.Buf[AW.Len] := Byte(AValue);
  AW.Buf[AW.Len + 1] := Byte(AValue shr 8);
  AW.Buf[AW.Len + 2] := Byte(AValue shr 16);
  AW.Buf[AW.Len + 3] := Byte(AValue shr 24);
  Inc(AW.Len, 4);
end;

procedure WU64(var AW: TWaotWriter; const AValue: UInt64);
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

procedure WBytes(var AW: TWaotWriter; const ABytes: TWasmBytes);
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

procedure WPadTo16(var AW: TWaotWriter; const ARegionStart: Integer);
var
  Rem: Integer;
begin
  { Pad the code region so its length is a multiple of 16 (§2.2). The loader
    knows codeLength exactly, so the padding is skipped on read; it only keeps
    records aligned for a mmap-and-index reader. }
  Rem := (AW.Len - ARegionStart) and 15;
  if Rem <> 0 then
    while Rem < 16 do
    begin
      WU8(AW, 0);
      Inc(Rem);
    end;
end;

type
  { A bounds-checked LE reader over the input buffer. Pos never advances past
    Len; a would-be over-read sets Bad and every subsequent read is a no-op. }
  TWaotReader = record
    Data: PByte;
    Len: NativeUInt;
    Pos: NativeUInt;
    Bad: Boolean;
  end;

function RU8(var AR: TWaotReader): Byte;
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

function RU16(var AR: TWaotReader): UInt16;
var
  B0, B1: Byte;
begin
  B0 := RU8(AR);
  B1 := RU8(AR);
  Result := UInt16(B0) or (UInt16(B1) shl 8);
end;

function RU32(var AR: TWaotReader): UInt32;
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

function RU64(var AR: TWaotReader): UInt64;
var
  Lo, Hi: UInt32;
begin
  Lo := RU32(AR);
  Hi := RU32(AR);
  Result := UInt64(Lo) or (UInt64(Hi) shl 32);
end;

function RBytes(var AR: TWaotReader; const ACount: UInt32): TWasmBytes;
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

procedure RSkipPadTo16(var AR: TWaotReader; const ARegionStart: NativeUInt);
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

{ --- writer --------------------------------------------------------------- }

function WriteAotArtifact(const AParams: TWasmAotWriteParams;
  const AFuncs: TWasmAotFuncRecords): TWasmBytes;
var
  Body: TWaotWriter;
  Out_: TWaotWriter;
  I, J, CodeStart: Integer;
  Checksum: UInt64;
begin
  { Pass 1: the body (function records) into its own writer, so the checksum can
    hash it before it is placed after the header. }
  Body.Buf := nil;
  Body.Len := 0;
  for I := 0 to High(AFuncs) do
  begin
    WU32(Body, AFuncs[I].FuncIrIndex);
    if AFuncs[I].Compiled then
      WU8(Body, WAOT_FUNCFLAG_COMPILED)
    else
      WU8(Body, 0);
    WU8(Body, 0);          { pad[0] }
    WU8(Body, 0);          { pad[1] }
    WU8(Body, 0);          { pad[2] }
    WU32(Body, AFuncs[I].RegisterCount);
    WU32(Body, AFuncs[I].EntryOffset);
    WU32(Body, UInt32(Length(AFuncs[I].Code)));
    WU32(Body, UInt32(Length(AFuncs[I].Relocs)));
    for J := 0 to High(AFuncs[I].Relocs) do
    begin
      WU32(Body, AFuncs[I].Relocs[J].SiteOffset);
      WU8(Body, AFuncs[I].Relocs[J].Kind);
      WU16(Body, AFuncs[I].Relocs[J].Symbol);
      WU8(Body, 0);        { pad }
    end;
    CodeStart := Body.Len;
    WBytes(Body, AFuncs[I].Code);
    WPadTo16(Body, CodeStart);
  end;
  SetLength(Body.Buf, Body.Len);

  if Body.Len > 0 then
    Checksum := WaotHash64(@Body.Buf[0], NativeUInt(Body.Len))
  else
    Checksum := WaotHash64(nil, 0);

  { Pass 2: the header (§2.2), then the body. }
  Out_.Buf := nil;
  Out_.Len := 0;
  WU8(Out_, WAOT_MAGIC0);
  WU8(Out_, WAOT_MAGIC1);
  WU8(Out_, WAOT_MAGIC2);
  WU8(Out_, WAOT_MAGIC3);
  WU16(Out_, WAOT_FORMAT_VERSION);
  WU16(Out_, AParams.IrFormatVer);
  WU8(Out_, AParams.TargetArch);
  WU8(Out_, AParams.Flags);
  WU64(Out_, AParams.AbiFingerprint);
  WU64(Out_, AParams.ModuleHash.Lo);
  WU64(Out_, AParams.ModuleHash.Hi);
  WU32(Out_, UInt32(Length(AFuncs)));
  WU64(Out_, Checksum);
  { The header is exactly WAOT_HEADER_SIZE by construction; assert the invariant
    the reader relies on. }
  if Out_.Len <> WAOT_HEADER_SIZE then
    raise EWasmError.CreateFmt(
      'internal: .waot header is %d bytes, expected %d',
      [Out_.Len, WAOT_HEADER_SIZE]);
  WBytes(Out_, Body.Buf);

  SetLength(Out_.Buf, Out_.Len);
  Result := Out_.Buf;
end;

{ --- reader --------------------------------------------------------------- }

function ParseAotArtifact(const ABytes: TWasmBytes;
  out AArtifact: TWasmAotArtifact): TWasmAotParseResult;
var
  R: TWaotReader;
  Flags: Byte;
  StoredChecksum, ComputedChecksum: UInt64;
  I, J: Integer;
  RelocCount, CodeLen, RecStart: UInt32;
  BodyStart: NativeUInt;
begin
  AArtifact.Funcs := nil;
  FillChar(AArtifact.Header, SizeOf(AArtifact.Header), 0);

  if Length(ABytes) < WAOT_HEADER_SIZE then
    Exit(aprMalformed);

  R.Data := @ABytes[0];
  R.Len := NativeUInt(Length(ABytes));
  R.Pos := 0;
  R.Bad := False;

  { Magic. }
  if (RU8(R) <> WAOT_MAGIC0) or (RU8(R) <> WAOT_MAGIC1)
    or (RU8(R) <> WAOT_MAGIC2) or (RU8(R) <> WAOT_MAGIC3) then
    Exit(aprBadMagic);

  AArtifact.Header.AotFormatVer := RU16(R);
  if AArtifact.Header.AotFormatVer <> WAOT_FORMAT_VERSION then
    Exit(aprBadFormatVer);

  AArtifact.Header.IrFormatVer := RU16(R);
  AArtifact.Header.TargetArch := RU8(R);
  Flags := RU8(R);
  AArtifact.Header.Flags := Flags;
  AArtifact.Header.AbiFingerprint := RU64(R);
  AArtifact.Header.ModuleHash.Lo := RU64(R);
  AArtifact.Header.ModuleHash.Hi := RU64(R);
  AArtifact.Header.FuncCount := RU32(R);
  StoredChecksum := RU64(R);
  AArtifact.Header.SelfChecksum := StoredChecksum;

  { selfChecksum covers everything after the header (§2.2/§2.4): a corruption /
    truncation guard applied before the body is trusted to parse. }
  BodyStart := WAOT_HEADER_SIZE;
  if BodyStart > R.Len then
    ComputedChecksum := WaotHash64(nil, 0)
  else if R.Len - BodyStart = 0 then
    ComputedChecksum := WaotHash64(nil, 0)
  else
    ComputedChecksum := WaotHash64(@ABytes[BodyStart], R.Len - BodyStart);
  if ComputedChecksum <> StoredChecksum then
    Exit(aprBadChecksum);

  { funcCount records, each bounds-checked as it is read. A wildly large
    funcCount or a length running past the buffer surfaces as aprMalformed via
    the reader's Bad flag. }
  SetLength(AArtifact.Funcs, AArtifact.Header.FuncCount);
  for I := 0 to Integer(AArtifact.Header.FuncCount) - 1 do
  begin
    AArtifact.Funcs[I].FuncIrIndex := RU32(R);
    Flags := RU8(R);
    AArtifact.Funcs[I].Compiled := (Flags and WAOT_FUNCFLAG_COMPILED) <> 0;
    RU8(R);                { pad[0] }
    RU8(R);                { pad[1] }
    RU8(R);                { pad[2] }
    AArtifact.Funcs[I].RegisterCount := RU32(R);
    AArtifact.Funcs[I].EntryOffset := RU32(R);
    CodeLen := RU32(R);
    RelocCount := RU32(R);
    SetLength(AArtifact.Funcs[I].Relocs, RelocCount);
    for J := 0 to Integer(RelocCount) - 1 do
    begin
      AArtifact.Funcs[I].Relocs[J].SiteOffset := RU32(R);
      AArtifact.Funcs[I].Relocs[J].Kind := RU8(R);
      AArtifact.Funcs[I].Relocs[J].Symbol := RU16(R);
      RU8(R);              { pad }
    end;
    RecStart := UInt32(R.Pos);   { start of the code region for pad accounting }
    AArtifact.Funcs[I].Code := RBytes(R, CodeLen);
    RSkipPadTo16(R, RecStart);
    if R.Bad then
      Exit(aprMalformed);
  end;

  if R.Bad then
    Exit(aprMalformed);
  Result := aprOk;
end;

end.
