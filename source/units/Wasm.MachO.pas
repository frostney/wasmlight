{ Wasm.MachO — package a macOS runtime-shell template without a compiler or
  linker.

  The product shell program is issue #34 and the product payload records are
  issue #35; both are still open. This unit owns only the Mach-O placement
  and ad-hoc signature, against that documented placeholder seam:

    - The payload is opaque bytes. #35 will give them a versioned layout.
    - They live in segment `__WSHL`, section `__payload`, so a later shell
      can find them with the Mach-O section table rather than a sidecar
      file (#34 today) or a host linker (rejected by ADR-0015).
    - Integrity is the embedded ad-hoc CodeDirectory (xnu cs_blobs.h,
      CS_ADHOC | CS_LINKER_SIGNED, SHA-256 page hashes). Distribution
      identity and notarization stay an external post-build step; this
      unit never invents a certificate.

  Linux and macOS compiler hosts both emit aarch64-darwin and
  x86_64-darwin images: the bytes are host-independent. A generated
  program is suitable for later `codesign -s <identity>` without a
  rebuild because the payload is ordinary mapped file content, not a
  post-signature trailer.

  Cited layout: apple-oss-distributions/xnu EXTERNAL_HEADERS/mach-o/loader.h
  and osfmk/kern/cs_blobs.h; the SuperBlob field order matches the
  linker-signed form LLVM lld writes for arm64 macOS. }
unit Wasm.MachO;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  MH_MAGIC_64 = UInt32($FEEDFACF);
  MH_CIGAM_64 = UInt32($CFFAEDFE);
  FAT_MAGIC = UInt32($CAFEBABE);
  FAT_CIGAM = UInt32($BEBAFECA);
  FAT_MAGIC_64 = UInt32($CAFEBABF);

  CPU_ARCH_ABI64 = UInt32($01000000);
  CPU_TYPE_X86_64 = CPU_ARCH_ABI64 or UInt32(7);
  CPU_TYPE_ARM64 = CPU_ARCH_ABI64 or UInt32(12);
  CPU_SUBTYPE_X86_64_ALL = UInt32(3);
  CPU_SUBTYPE_ARM64_ALL = UInt32(0);

  MH_EXECUTE = UInt32(2);
  MH_NOUNDEFS = UInt32($1);
  MH_PIE = UInt32($200000);

  LC_SEGMENT_64 = UInt32($19);
  LC_SYMTAB = UInt32($2);
  LC_DYSYMTAB = UInt32($B);
  LC_DYLD_INFO = UInt32($22);
  LC_DYLD_INFO_ONLY = UInt32($80000022);
  LC_CODE_SIGNATURE = UInt32($1D);
  LC_SEGMENT_SPLIT_INFO = UInt32($1E);
  LC_FUNCTION_STARTS = UInt32($26);
  LC_DATA_IN_CODE = UInt32($29);
  LC_DYLIB_CODE_SIGN_DRS = UInt32($2B);
  LC_LINKER_OPTIMIZATION_HINT = UInt32($2E);
  LC_DYLD_EXPORTS_TRIE = UInt32($80000033);
  LC_DYLD_CHAINED_FIXUPS = UInt32($80000034);

  VM_PROT_READ = UInt32(1);

  MACHO_SEGALIGN = UInt64($4000);
  MACHO_SIGALIGN = UInt64(16);
  MACHO_CD_PAGE_SHIFT = 12;
  MACHO_CD_PAGE_SIZE = 1 shl MACHO_CD_PAGE_SHIFT;

  CSMAGIC_CODEDIRECTORY = UInt32($FADE0C02);
  CSMAGIC_EMBEDDED_SIGNATURE = UInt32($FADE0CC0);
  CSSLOT_CODEDIRECTORY = UInt32(0);
  CS_ADHOC = UInt32($00000002);
  CS_LINKER_SIGNED = UInt32($00020000);
  CS_SUPPORTSEXECSEG = UInt32($00020400);
  CS_HASHTYPE_SHA256 = Byte(2);
  CS_EXECSEG_MAIN_BINARY = UInt64(1);
  CS_CD_SIZE_V20400 = 88;
  CS_SUPERBLOB_INDEX_OFF = 24;

  MACHO_SEG_PAGEZERO = '__PAGEZERO';
  MACHO_SEG_TEXT = '__TEXT';
  MACHO_SEG_LINKEDIT = '__LINKEDIT';
  MACHO_SEG_WSHL = '__WSHL';
  MACHO_SECT_PAYLOAD = '__payload';
  MACHO_SECT_TEXT = '__text';

  MACHO_TARGET_AARCH64_DARWIN = 'aarch64-darwin';
  MACHO_TARGET_X86_64_DARWIN = 'x86_64-darwin';
  MACHO_DEFAULT_IDENT = 'wasmlight-shell';

type
  { Released macOS compile targets (ADR-0015). Independent of the compiler
    host: both are emitted from Linux or macOS. }
  TWasmMachOTarget = (
    wmtAarch64Darwin,
    wmtX86_64Darwin
  );

  TWasmMachOResult = (
    mmrOk,
    mmrEmpty,
    mmrNotMachO,
    mmrUnsupported,
    mmrTruncated,
    mmrMalformed,
    mmrNoHeaderSlack,
    mmrPayloadMissing,
    mmrSignatureInvalid
  );

  { Structural view used by tests and by the packager. Offsets are file
    offsets. HasPayload is True when `__WSHL,__payload` exists; an
    unfilled template has that section with PayloadSize 0. }
  TWasmMachOInfo = record
    Target: TWasmMachOTarget;
    CpuType: UInt32;
    Ncmds: UInt32;
    Sizeofcmds: UInt32;
    HasPayload: Boolean;
    PayloadOff: UInt64;
    PayloadSize: UInt64;
    HasSignature: Boolean;
    SignatureOff: UInt32;
    SignatureSize: UInt32;
    HeaderSlack: UInt32;
  end;

{ Human target name (`aarch64-darwin` / `x86_64-darwin`). }
function MachOTargetName(const ATarget: TWasmMachOTarget): string;

{ A signed, empty-payload MH_EXECUTE template for ATarget. No compiler or
  linker is invoked; the bytes are synthesized here. }
function WriteMachOShellTemplate(const ATarget: TWasmMachOTarget): TWasmBytes;

{ Place APayload in `__WSHL,__payload` and write a fresh ad-hoc signature.
  AIdentifier is the CodeDirectory ident (basename only); empty uses
  MACHO_DEFAULT_IDENT. }
function PackageMachORuntimeShell(const ATemplate, APayload: TWasmBytes;
  const AIdentifier: string; out AOutput: TWasmBytes): TWasmMachOResult;

{ Bounds-checked section walk. On mmrOk, AInfo describes a thin 64-bit
  MH_EXECUTE. }
function InspectMachO(const ABytes: TWasmBytes;
  out AInfo: TWasmMachOInfo): TWasmMachOResult;

{ Copy the `__WSHL,__payload` bytes. Empty on a valid unfilled template. }
function ExtractMachOPayload(const ABytes: TWasmBytes;
  out APayload: TWasmBytes): TWasmMachOResult;

{ Recompute the CodeDirectory page hashes and compare them to the blob.
  Does not call `codesign`. }
function VerifyMachOAdHocSignature(const ABytes: TWasmBytes): TWasmMachOResult;

implementation

uses
  Wasm.Sha256;

const
  MH_HEADER_SIZE = 32;
  LC_SEGMENT_64_SIZE = 72;
  SECTION_64_SIZE = 80;
  LC_LINKEDIT_DATA_SIZE = 16;
  PAGEZERO_VMSIZE = UInt64($100000000);
  TEXT_VMADDR = UInt64($100000000);

type
  TSeg64 = record
    CmdOff: NativeUInt;
    Name: string;
    VmAddr: UInt64;
    VmSize: UInt64;
    FileOff: UInt64;
    FileSize: UInt64;
    Nsects: UInt32;
  end;

function MachOTargetName(const ATarget: TWasmMachOTarget): string;
begin
  if ATarget = wmtAarch64Darwin then
    Result := MACHO_TARGET_AARCH64_DARWIN
  else
    Result := MACHO_TARGET_X86_64_DARWIN;
end;

function AlignUp64(const AValue, AAlign: UInt64): UInt64;
begin
  if (AAlign = 0) or (AValue = 0) then
    Exit(AValue);
  Result := (AValue + AAlign - 1) and not (AAlign - 1);
end;

function RU32(const ABytes: TWasmBytes; const AOff: NativeUInt): UInt32;
begin
  Result := UInt32(ABytes[AOff])
    or (UInt32(ABytes[AOff + 1]) shl 8)
    or (UInt32(ABytes[AOff + 2]) shl 16)
    or (UInt32(ABytes[AOff + 3]) shl 24);
end;

function RU64(const ABytes: TWasmBytes; const AOff: NativeUInt): UInt64;
begin
  Result := UInt64(RU32(ABytes, AOff))
    or (UInt64(RU32(ABytes, AOff + 4)) shl 32);
end;

procedure WU32(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AValue: UInt32);
begin
  ABytes[AOff] := Byte(AValue);
  ABytes[AOff + 1] := Byte(AValue shr 8);
  ABytes[AOff + 2] := Byte(AValue shr 16);
  ABytes[AOff + 3] := Byte(AValue shr 24);
end;

procedure WU64(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AValue: UInt64);
begin
  WU32(ABytes, AOff, UInt32(AValue));
  WU32(ABytes, AOff + 4, UInt32(AValue shr 32));
end;

procedure WU32BE(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AValue: UInt32);
begin
  ABytes[AOff] := Byte(AValue shr 24);
  ABytes[AOff + 1] := Byte(AValue shr 16);
  ABytes[AOff + 2] := Byte(AValue shr 8);
  ABytes[AOff + 3] := Byte(AValue);
end;

procedure WU64BE(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AValue: UInt64);
begin
  WU32BE(ABytes, AOff, UInt32(AValue shr 32));
  WU32BE(ABytes, AOff + 4, UInt32(AValue));
end;

function RU32BE(const ABytes: TWasmBytes; const AOff: NativeUInt): UInt32;
begin
  Result := (UInt32(ABytes[AOff]) shl 24)
    or (UInt32(ABytes[AOff + 1]) shl 16)
    or (UInt32(ABytes[AOff + 2]) shl 8)
    or UInt32(ABytes[AOff + 3]);
end;

procedure WriteName(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AName: string);
var
  I, N: Integer;
begin
  for I := 0 to 15 do
    ABytes[AOff + NativeUInt(I)] := 0;
  N := Length(AName);
  if N > 16 then
    N := 16;
  for I := 1 to N do
    ABytes[AOff + NativeUInt(I - 1)] := Byte(Ord(AName[I]));
end;

function NameEq(const ABytes: TWasmBytes; const AOff: NativeUInt;
  const AName: string): Boolean;
var
  Tmp: array[0..15] of Byte;
  I, N: Integer;
begin
  for I := 0 to 15 do
    Tmp[I] := 0;
  N := Length(AName);
  if N > 16 then
    N := 16;
  for I := 1 to N do
    Tmp[I - 1] := Byte(Ord(AName[I]));
  Result := True;
  for I := 0 to 15 do
    if ABytes[AOff + NativeUInt(I)] <> Tmp[I] then
      Exit(False);
end;

function IdentBase(const AIdentifier: string): string;
var
  I: Integer;
begin
  Result := AIdentifier;
  if Result = '' then
    Exit(MACHO_DEFAULT_IDENT);
  for I := Length(Result) downto 1 do
    if (Result[I] = '/') or (Result[I] = '\') then
    begin
      Result := Copy(Result, I + 1, MaxInt);
      Break;
    end;
  if Result = '' then
    Result := MACHO_DEFAULT_IDENT;
end;

procedure ClearInfo(out AInfo: TWasmMachOInfo);
begin
  AInfo.Target := wmtAarch64Darwin;
  AInfo.CpuType := 0;
  AInfo.Ncmds := 0;
  AInfo.Sizeofcmds := 0;
  AInfo.HasPayload := False;
  AInfo.PayloadOff := 0;
  AInfo.PayloadSize := 0;
  AInfo.HasSignature := False;
  AInfo.SignatureOff := 0;
  AInfo.SignatureSize := 0;
  AInfo.HeaderSlack := 0;
end;

function TargetFromCpu(const ACpu: UInt32; out ATarget: TWasmMachOTarget): Boolean;
begin
  Result := True;
  if ACpu = CPU_TYPE_ARM64 then
    ATarget := wmtAarch64Darwin
  else if ACpu = CPU_TYPE_X86_64 then
    ATarget := wmtX86_64Darwin
  else
    Result := False;
end;

function CmdRangeOk(const ALen, AOff, ANeed: NativeUInt): Boolean;
begin
  Result := (AOff <= ALen) and (ANeed <= ALen - AOff);
end;

function WalkHeader(const ABytes: TWasmBytes; out ANcmds, ASizeofcmds: UInt32;
  out ACpu: UInt32): TWasmMachOResult;
var
  Magic, FileType: UInt32;
  CmdEnd: NativeUInt;
begin
  if Length(ABytes) = 0 then
    Exit(mmrEmpty);
  if NativeUInt(Length(ABytes)) < 4 then
    Exit(mmrTruncated);
  Magic := RU32(ABytes, 0);
  if (Magic = FAT_MAGIC) or (Magic = FAT_CIGAM) or (Magic = FAT_MAGIC_64) then
    Exit(mmrUnsupported);
  if NativeUInt(Length(ABytes)) < 8 then
  begin
    if (Magic <> MH_MAGIC_64) and (Magic <> MH_CIGAM_64) then
      Exit(mmrNotMachO);
    Exit(mmrTruncated);
  end;
  if Magic = MH_CIGAM_64 then
    Exit(mmrUnsupported);
  if Magic <> MH_MAGIC_64 then
    Exit(mmrNotMachO);
  if NativeUInt(Length(ABytes)) < MH_HEADER_SIZE then
    Exit(mmrTruncated);
  ACpu := RU32(ABytes, 4);
  FileType := RU32(ABytes, 12);
  ANcmds := RU32(ABytes, 16);
  ASizeofcmds := RU32(ABytes, 20);
  if FileType <> MH_EXECUTE then
    Exit(mmrUnsupported);
  CmdEnd := NativeUInt(MH_HEADER_SIZE) + NativeUInt(ASizeofcmds);
  if CmdEnd < NativeUInt(MH_HEADER_SIZE) then
    Exit(mmrMalformed);
  if NativeUInt(Length(ABytes)) < CmdEnd then
    Exit(mmrTruncated);
  Result := mmrOk;
end;

function InspectMachO(const ABytes: TWasmBytes;
  out AInfo: TWasmMachOInfo): TWasmMachOResult;
var
  Ncmds, Sizeofcmds, Cpu, Cmd, CmdSize: UInt32;
  Off, EndOff, SectOff, FirstFile: NativeUInt;
  I, S, Nsects: Integer;
  Target: TWasmMachOTarget;
begin
  ClearInfo(AInfo);
  Result := WalkHeader(ABytes, Ncmds, Sizeofcmds, Cpu);
  if Result <> mmrOk then
    Exit;
  if not TargetFromCpu(Cpu, Target) then
    Exit(mmrUnsupported);
  AInfo.Target := Target;
  AInfo.CpuType := Cpu;
  AInfo.Ncmds := Ncmds;
  AInfo.Sizeofcmds := Sizeofcmds;
  FirstFile := NativeUInt(Length(ABytes));
  Off := MH_HEADER_SIZE;
  EndOff := NativeUInt(MH_HEADER_SIZE) + NativeUInt(Sizeofcmds);
  for I := 1 to Integer(Ncmds) do
  begin
    if not CmdRangeOk(EndOff, Off, 8) then
      Exit(mmrMalformed);
    Cmd := RU32(ABytes, Off);
    CmdSize := RU32(ABytes, Off + 4);
    if (CmdSize < 8) or not CmdRangeOk(EndOff, Off, CmdSize) then
      Exit(mmrMalformed);
    if Cmd = LC_SEGMENT_64 then
    begin
      if CmdSize < LC_SEGMENT_64_SIZE then
        Exit(mmrMalformed);
      Nsects := Integer(RU32(ABytes, Off + 64));
      if NativeUInt(CmdSize) < NativeUInt(LC_SEGMENT_64_SIZE)
        + NativeUInt(Nsects) * NativeUInt(SECTION_64_SIZE) then
        Exit(mmrMalformed);
      SectOff := Off + LC_SEGMENT_64_SIZE;
      for S := 0 to Nsects - 1 do
      begin
        if (RU32(ABytes, SectOff + 48) <> 0) and
          (NativeUInt(RU32(ABytes, SectOff + 48)) < FirstFile) then
          FirstFile := NativeUInt(RU32(ABytes, SectOff + 48));
        if NameEq(ABytes, Off + 8, MACHO_SEG_WSHL)
          and NameEq(ABytes, SectOff, MACHO_SECT_PAYLOAD) then
        begin
          AInfo.HasPayload := True;
          AInfo.PayloadOff := RU32(ABytes, SectOff + 48);
          AInfo.PayloadSize := RU64(ABytes, SectOff + 40);
        end;
        SectOff := SectOff + SECTION_64_SIZE;
      end;
    end
    else if Cmd = LC_CODE_SIGNATURE then
    begin
      if CmdSize < LC_LINKEDIT_DATA_SIZE then
        Exit(mmrMalformed);
      AInfo.HasSignature := True;
      AInfo.SignatureOff := RU32(ABytes, Off + 8);
      AInfo.SignatureSize := RU32(ABytes, Off + 12);
    end;
    Off := Off + CmdSize;
  end;
  if Off <> EndOff then
    Exit(mmrMalformed);
  if FirstFile < EndOff then
    Exit(mmrMalformed);
  AInfo.HeaderSlack := UInt32(FirstFile - EndOff);
  Result := mmrOk;
end;

function ExtractMachOPayload(const ABytes: TWasmBytes;
  out APayload: TWasmBytes): TWasmMachOResult;
var
  Info: TWasmMachOInfo;
  I: NativeUInt;
begin
  APayload := nil;
  Result := InspectMachO(ABytes, Info);
  if Result <> mmrOk then
    Exit;
  if not Info.HasPayload then
    Exit(mmrPayloadMissing);
  if (Info.PayloadSize > 0) and ((Info.PayloadOff >= UInt64(Length(ABytes)))
    or (Info.PayloadSize > UInt64(Length(ABytes)) - Info.PayloadOff)) then
    Exit(mmrTruncated);
  SetLength(APayload, NativeUInt(Info.PayloadSize));
  if Info.PayloadSize > 0 then
    for I := 0 to NativeUInt(Info.PayloadSize) - 1 do
      APayload[I] := ABytes[NativeUInt(Info.PayloadOff) + I];
  Result := mmrOk;
end;

function FindCmd(const ABytes: TWasmBytes; const AWant: UInt32;
  out AOff: NativeUInt): Boolean;
var
  Ncmds, Sizeofcmds, Cpu, Cmd, CmdSize: UInt32;
  Off, EndOff: NativeUInt;
  I: Integer;
begin
  Result := False;
  AOff := 0;
  if WalkHeader(ABytes, Ncmds, Sizeofcmds, Cpu) <> mmrOk then
    Exit;
  Off := MH_HEADER_SIZE;
  EndOff := NativeUInt(MH_HEADER_SIZE) + NativeUInt(Sizeofcmds);
  for I := 1 to Integer(Ncmds) do
  begin
    if not CmdRangeOk(EndOff, Off, 8) then
      Exit;
    Cmd := RU32(ABytes, Off);
    CmdSize := RU32(ABytes, Off + 4);
    if (CmdSize < 8) or not CmdRangeOk(EndOff, Off, CmdSize) then
      Exit;
    if Cmd = AWant then
    begin
      AOff := Off;
      Exit(True);
    end;
    Off := Off + CmdSize;
  end;
end;

function FindSeg(const ABytes: TWasmBytes; const AName: string;
  out ASeg: TSeg64): Boolean;
var
  Ncmds, Sizeofcmds, Cpu, Cmd, CmdSize: UInt32;
  Off, EndOff: NativeUInt;
  I: Integer;
begin
  Result := False;
  FillChar(ASeg, SizeOf(ASeg), 0);
  if WalkHeader(ABytes, Ncmds, Sizeofcmds, Cpu) <> mmrOk then
    Exit;
  Off := MH_HEADER_SIZE;
  EndOff := NativeUInt(MH_HEADER_SIZE) + NativeUInt(Sizeofcmds);
  for I := 1 to Integer(Ncmds) do
  begin
    if not CmdRangeOk(EndOff, Off, 8) then
      Exit;
    Cmd := RU32(ABytes, Off);
    CmdSize := RU32(ABytes, Off + 4);
    if (CmdSize < 8) or not CmdRangeOk(EndOff, Off, CmdSize) then
      Exit;
    if (Cmd = LC_SEGMENT_64) and (CmdSize >= LC_SEGMENT_64_SIZE)
      and NameEq(ABytes, Off + 8, AName) then
    begin
      ASeg.CmdOff := Off;
      ASeg.Name := AName;
      ASeg.VmAddr := RU64(ABytes, Off + 24);
      ASeg.VmSize := RU64(ABytes, Off + 32);
      ASeg.FileOff := RU64(ABytes, Off + 40);
      ASeg.FileSize := RU64(ABytes, Off + 48);
      ASeg.Nsects := RU32(ABytes, Off + 64);
      Exit(True);
    end;
    Off := Off + CmdSize;
  end;
end;

function FindSection(const ABytes: TWasmBytes; const ASeg, ASect: string;
  out ACmdOff, ASectOff: NativeUInt): Boolean;
var
  Seg: TSeg64;
  S: Integer;
  Off: NativeUInt;
begin
  Result := False;
  ACmdOff := 0;
  ASectOff := 0;
  if not FindSeg(ABytes, ASeg, Seg) then
    Exit;
  Off := Seg.CmdOff + LC_SEGMENT_64_SIZE;
  for S := 0 to Integer(Seg.Nsects) - 1 do
  begin
    if NativeUInt(Length(ABytes)) < Off + SECTION_64_SIZE then
      Exit;
    if NameEq(ABytes, Off, ASect) then
    begin
      ACmdOff := Seg.CmdOff;
      ASectOff := Off;
      Exit(True);
    end;
    Off := Off + SECTION_64_SIZE;
  end;
end;

procedure BumpU32(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AAt: UInt64; const ADelta: Int64);
var
  V: UInt32;
begin
  V := RU32(ABytes, AOff);
  if (V <> 0) and (UInt64(V) >= AAt) then
    WU32(ABytes, AOff, UInt32(Int64(V) + ADelta));
end;

procedure BumpU64(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AAt: UInt64; const ADelta: Int64);
var
  V: UInt64;
begin
  V := RU64(ABytes, AOff);
  if V >= AAt then
    WU64(ABytes, AOff, UInt64(Int64(V) + ADelta));
end;

procedure BumpFileOffsets(var ABytes: TWasmBytes; const AAt: UInt64;
  const ADelta: Int64);
var
  Ncmds, Sizeofcmds, Cpu, Cmd, CmdSize: UInt32;
  Off, EndOff, SectOff: NativeUInt;
  I, S, Nsects: Integer;
begin
  if (ADelta = 0) or (WalkHeader(ABytes, Ncmds, Sizeofcmds, Cpu) <> mmrOk) then
    Exit;
  Off := MH_HEADER_SIZE;
  EndOff := NativeUInt(MH_HEADER_SIZE) + NativeUInt(Sizeofcmds);
  for I := 1 to Integer(Ncmds) do
  begin
    Cmd := RU32(ABytes, Off);
    CmdSize := RU32(ABytes, Off + 4);
    if Cmd = LC_SEGMENT_64 then
    begin
      BumpU64(ABytes, Off + 40, AAt, ADelta);
      SectOff := Off + LC_SEGMENT_64_SIZE;
      Nsects := Integer(RU32(ABytes, Off + 64));
      for S := 0 to Nsects - 1 do
      begin
        BumpU32(ABytes, SectOff + 48, AAt, ADelta);
        BumpU32(ABytes, SectOff + 56, AAt, ADelta);
        SectOff := SectOff + SECTION_64_SIZE;
      end;
    end
    else if (Cmd = LC_CODE_SIGNATURE) or (Cmd = LC_FUNCTION_STARTS)
      or (Cmd = LC_DATA_IN_CODE) or (Cmd = LC_SEGMENT_SPLIT_INFO)
      or (Cmd = LC_DYLIB_CODE_SIGN_DRS)
      or (Cmd = LC_LINKER_OPTIMIZATION_HINT)
      or (Cmd = LC_DYLD_EXPORTS_TRIE)
      or (Cmd = LC_DYLD_CHAINED_FIXUPS) then
      BumpU32(ABytes, Off + 8, AAt, ADelta)
    else if Cmd = LC_SYMTAB then
    begin
      BumpU32(ABytes, Off + 8, AAt, ADelta);
      BumpU32(ABytes, Off + 16, AAt, ADelta);
    end
    else if Cmd = LC_DYSYMTAB then
    begin
      BumpU32(ABytes, Off + 32, AAt, ADelta);
      BumpU32(ABytes, Off + 40, AAt, ADelta);
      BumpU32(ABytes, Off + 48, AAt, ADelta);
      BumpU32(ABytes, Off + 56, AAt, ADelta);
      BumpU32(ABytes, Off + 64, AAt, ADelta);
      BumpU32(ABytes, Off + 72, AAt, ADelta);
    end
    else if (Cmd = LC_DYLD_INFO) or (Cmd = LC_DYLD_INFO_ONLY) then
    begin
      BumpU32(ABytes, Off + 8, AAt, ADelta);
      BumpU32(ABytes, Off + 16, AAt, ADelta);
      BumpU32(ABytes, Off + 24, AAt, ADelta);
      BumpU32(ABytes, Off + 32, AAt, ADelta);
      BumpU32(ABytes, Off + 40, AAt, ADelta);
    end;
    Off := Off + CmdSize;
    if Off > EndOff then
      Break;
  end;
end;

procedure InsertBytes(var ABytes: TWasmBytes; const AAt: NativeUInt;
  const ACount: NativeUInt);
var
  OldLen, I: NativeUInt;
begin
  if ACount = 0 then
    Exit;
  OldLen := NativeUInt(Length(ABytes));
  SetLength(ABytes, OldLen + ACount);
  if AAt < OldLen then
    for I := OldLen downto AAt + 1 do
      ABytes[I + ACount - 1] := ABytes[I - 1];
  for I := 0 to ACount - 1 do
    ABytes[AAt + I] := 0;
end;

procedure DeleteBytes(var ABytes: TWasmBytes; const AAt, ACount: NativeUInt);
var
  OldLen, I: NativeUInt;
begin
  if ACount = 0 then
    Exit;
  OldLen := NativeUInt(Length(ABytes));
  if AAt + ACount < OldLen then
    for I := AAt to OldLen - ACount - 1 do
      ABytes[I] := ABytes[I + ACount];
  SetLength(ABytes, OldLen - ACount);
end;

function SignatureBlobSize(const ACodeLimit: UInt32;
  const AIdent: string): UInt32;
var
  IdentLen, Headers, NPages: UInt32;
begin
  IdentLen := UInt32(Length(AIdent)) + 1;
  Headers := UInt32(AlignUp64(UInt64(CS_SUPERBLOB_INDEX_OFF + CS_CD_SIZE_V20400)
    + UInt64(IdentLen), MACHO_SIGALIGN));
  NPages := (ACodeLimit + UInt32(MACHO_CD_PAGE_SIZE) - 1)
    div UInt32(MACHO_CD_PAGE_SIZE);
  if (ACodeLimit = 0) then
    NPages := 0;
  Result := Headers + NPages * UInt32(SHA256_DIGEST_SIZE);
  Result := UInt32(AlignUp64(Result, MACHO_SIGALIGN));
end;

function WriteAdHocSignature(var ABytes: TWasmBytes; const ASigOff: NativeUInt;
  const ACodeLimit: UInt32; const AIdent: string; const ATextOff,
  ATextSize: UInt64): TWasmMachOResult;
var
  Ident: string;
  IdentLen, Headers, HashOff, NPages, BlobLen, I, Take: UInt32;
  Page: NativeUInt;
  Digest: TSha256Digest;
  B: Integer;
begin
  Ident := IdentBase(AIdent);
  IdentLen := UInt32(Length(Ident)) + 1;
  Headers := UInt32(AlignUp64(UInt64(CS_SUPERBLOB_INDEX_OFF + CS_CD_SIZE_V20400)
    + UInt64(IdentLen), MACHO_SIGALIGN));
  HashOff := Headers - CS_SUPERBLOB_INDEX_OFF;
  NPages := (ACodeLimit + UInt32(MACHO_CD_PAGE_SIZE) - 1)
    div UInt32(MACHO_CD_PAGE_SIZE);
  if ACodeLimit = 0 then
    NPages := 0;
  BlobLen := SignatureBlobSize(ACodeLimit, Ident);
  if NativeUInt(Length(ABytes)) < ASigOff + NativeUInt(BlobLen) then
    SetLength(ABytes, ASigOff + NativeUInt(BlobLen));
  for I := 0 to BlobLen - 1 do
    ABytes[ASigOff + I] := 0;
  WU32BE(ABytes, ASigOff, CSMAGIC_EMBEDDED_SIGNATURE);
  WU32BE(ABytes, ASigOff + 4, BlobLen);
  WU32BE(ABytes, ASigOff + 8, 1);
  WU32BE(ABytes, ASigOff + 12, CSSLOT_CODEDIRECTORY);
  WU32BE(ABytes, ASigOff + 16, CS_SUPERBLOB_INDEX_OFF);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF, CSMAGIC_CODEDIRECTORY);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 4,
    BlobLen - CS_SUPERBLOB_INDEX_OFF);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 8, CS_SUPPORTSEXECSEG);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 12,
    CS_ADHOC or CS_LINKER_SIGNED);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 16, HashOff);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 20, CS_CD_SIZE_V20400);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 24, 0);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 28, NPages);
  WU32BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 32, ACodeLimit);
  ABytes[ASigOff + CS_SUPERBLOB_INDEX_OFF + 36] := SHA256_DIGEST_SIZE;
  ABytes[ASigOff + CS_SUPERBLOB_INDEX_OFF + 37] := CS_HASHTYPE_SHA256;
  ABytes[ASigOff + CS_SUPERBLOB_INDEX_OFF + 38] := 0;
  ABytes[ASigOff + CS_SUPERBLOB_INDEX_OFF + 39] := MACHO_CD_PAGE_SHIFT;
  WU64BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 64, ATextOff);
  WU64BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 72, ATextSize);
  WU64BE(ABytes, ASigOff + CS_SUPERBLOB_INDEX_OFF + 80, CS_EXECSEG_MAIN_BINARY);
  for B := 1 to Length(Ident) do
    ABytes[ASigOff + CS_SUPERBLOB_INDEX_OFF + CS_CD_SIZE_V20400
      + NativeUInt(B - 1)] := Byte(Ord(Ident[B]));
  for I := 0 to NPages - 1 do
  begin
    Page := NativeUInt(I) * NativeUInt(MACHO_CD_PAGE_SIZE);
    Take := UInt32(MACHO_CD_PAGE_SIZE);
    if Page + Take > ACodeLimit then
      Take := ACodeLimit - UInt32(Page);
    if Take = 0 then
      Digest := Sha256Bytes(nil, 0)
    else
      Digest := Sha256Bytes(@ABytes[Page], Take);
    for B := 0 to SHA256_DIGEST_SIZE - 1 do
      ABytes[ASigOff + CS_SUPERBLOB_INDEX_OFF + HashOff + I
        * SHA256_DIGEST_SIZE + NativeUInt(B)] := Digest[B];
  end;
  Result := mmrOk;
end;

function Resign(var ABytes: TWasmBytes; const AIdent: string): TWasmMachOResult;
var
  SigCmd: NativeUInt;
  Link, Text: TSeg64;
  OldOff, OldSize, ContentEnd, SigOff, SigSize: UInt32;
  HaveOld: Boolean;
begin
  if not FindSeg(ABytes, MACHO_SEG_LINKEDIT, Link) then
    Exit(mmrMalformed);
  HaveOld := FindCmd(ABytes, LC_CODE_SIGNATURE, SigCmd);
  if HaveOld then
  begin
    OldOff := RU32(ABytes, SigCmd + 8);
    OldSize := RU32(ABytes, SigCmd + 12);
  end
  else
  begin
    OldOff := 0;
    OldSize := 0;
  end;
  if HaveOld and (OldOff >= UInt32(Link.FileOff)) then
    ContentEnd := OldOff
  else
    ContentEnd := UInt32(Link.FileOff + Link.FileSize);
  SigOff := UInt32(AlignUp64(ContentEnd, MACHO_SIGALIGN));
  SigSize := SignatureBlobSize(SigOff, IdentBase(AIdent));
  if HaveOld and (OldOff + OldSize > ContentEnd) then
    SetLength(ABytes, ContentEnd);
  if NativeUInt(Length(ABytes)) < NativeUInt(SigOff) + NativeUInt(SigSize) then
    SetLength(ABytes, NativeUInt(SigOff) + NativeUInt(SigSize));
  if not HaveOld then
    Exit(mmrNoHeaderSlack);
  { Load-command fields sit in page 0, so they must be final before the
    CodeDirectory hashes run. }
  WU32(ABytes, SigCmd + 8, SigOff);
  WU32(ABytes, SigCmd + 12, SigSize);
  if not FindSeg(ABytes, MACHO_SEG_LINKEDIT, Link) then
    Exit(mmrMalformed);
  WU64(ABytes, Link.CmdOff + 48, UInt64(SigOff) + UInt64(SigSize) - Link.FileOff);
  WU64(ABytes, Link.CmdOff + 32,
    AlignUp64(RU64(ABytes, Link.CmdOff + 48), MACHO_SEGALIGN));
  if not FindSeg(ABytes, MACHO_SEG_TEXT, Text) then
  begin
    Text.FileOff := 0;
    Text.FileSize := 0;
  end;
  Result := WriteAdHocSignature(ABytes, SigOff, SigOff, AIdent, Text.FileOff,
    Text.FileSize);
end;

function VerifyMachOAdHocSignature(const ABytes: TWasmBytes): TWasmMachOResult;
var
  Info: TWasmMachOInfo;
  Off, CdOff, HashOff, NPages, CodeLimit, I, Take: UInt32;
  Count, Slot, SlotOff: UInt32;
  Page: NativeUInt;
  Digest: TSha256Digest;
  B: Integer;
begin
  Result := InspectMachO(ABytes, Info);
  if Result <> mmrOk then
    Exit;
  if not Info.HasSignature then
    Exit(mmrSignatureInvalid);
  Off := Info.SignatureOff;
  if (UInt64(Off) + 12 > UInt64(Length(ABytes)))
    or (UInt64(Off) + Info.SignatureSize > UInt64(Length(ABytes))) then
    Exit(mmrTruncated);
  if RU32BE(ABytes, Off) <> CSMAGIC_EMBEDDED_SIGNATURE then
    Exit(mmrSignatureInvalid);
  Count := RU32BE(ABytes, Off + 8);
  CdOff := 0;
  for I := 0 to Count - 1 do
  begin
    if UInt64(Off) + 12 + UInt64(I) * 8 + 8 > UInt64(Length(ABytes)) then
      Exit(mmrTruncated);
    Slot := RU32BE(ABytes, Off + 12 + I * 8);
    SlotOff := RU32BE(ABytes, Off + 12 + I * 8 + 4);
    if Slot = CSSLOT_CODEDIRECTORY then
      CdOff := Off + SlotOff;
  end;
  if (CdOff = 0) or (UInt64(CdOff) + CS_CD_SIZE_V20400 > UInt64(Length(ABytes))) then
    Exit(mmrSignatureInvalid);
  if RU32BE(ABytes, CdOff) <> CSMAGIC_CODEDIRECTORY then
    Exit(mmrSignatureInvalid);
  if ABytes[CdOff + 37] <> CS_HASHTYPE_SHA256 then
    Exit(mmrSignatureInvalid);
  HashOff := RU32BE(ABytes, CdOff + 16);
  NPages := RU32BE(ABytes, CdOff + 28);
  CodeLimit := RU32BE(ABytes, CdOff + 32);
  if UInt64(CodeLimit) > UInt64(Length(ABytes)) then
    Exit(mmrSignatureInvalid);
  if UInt64(CdOff) + HashOff + UInt64(NPages) * SHA256_DIGEST_SIZE
    > UInt64(Length(ABytes)) then
    Exit(mmrTruncated);
  for I := 0 to NPages - 1 do
  begin
    Page := NativeUInt(I) * NativeUInt(MACHO_CD_PAGE_SIZE);
    Take := UInt32(MACHO_CD_PAGE_SIZE);
    if Page + Take > CodeLimit then
      Take := CodeLimit - UInt32(Page);
    if Take = 0 then
      Digest := Sha256Bytes(nil, 0)
    else
      Digest := Sha256Bytes(@ABytes[Page], Take);
    for B := 0 to SHA256_DIGEST_SIZE - 1 do
      if ABytes[CdOff + HashOff + I * SHA256_DIGEST_SIZE + UInt32(B)]
        <> Digest[B] then
        Exit(mmrSignatureInvalid);
  end;
  Result := mmrOk;
end;

function FirstFileBackedOff(const ABytes: TWasmBytes): NativeUInt;
var
  Ncmds, Sizeofcmds, Cpu, Cmd, CmdSize: UInt32;
  Off, EndOff, SectOff: NativeUInt;
  I, S, Nsects: Integer;
  FileOff: UInt32;
begin
  Result := NativeUInt(Length(ABytes));
  if WalkHeader(ABytes, Ncmds, Sizeofcmds, Cpu) <> mmrOk then
    Exit;
  Off := MH_HEADER_SIZE;
  EndOff := NativeUInt(MH_HEADER_SIZE) + NativeUInt(Sizeofcmds);
  for I := 1 to Integer(Ncmds) do
  begin
    Cmd := RU32(ABytes, Off);
    CmdSize := RU32(ABytes, Off + 4);
    if Cmd = LC_SEGMENT_64 then
    begin
      Nsects := Integer(RU32(ABytes, Off + 64));
      SectOff := Off + LC_SEGMENT_64_SIZE;
      for S := 0 to Nsects - 1 do
      begin
        FileOff := RU32(ABytes, SectOff + 48);
        if (FileOff <> 0) and (NativeUInt(FileOff) < Result) then
          Result := NativeUInt(FileOff);
        SectOff := SectOff + SECTION_64_SIZE;
      end;
    end;
    Off := Off + CmdSize;
    if Off > EndOff then
      Break;
  end;
end;

function InsertPayloadCommand(var ABytes: TWasmBytes): TWasmMachOResult;
const
  NEED = LC_SEGMENT_64_SIZE + SECTION_64_SIZE;
var
  Link: TSeg64;
  InsertAt, CmdEnd, FirstFile, I: NativeUInt;
  Ncmds, Sizeofcmds, Cpu: UInt32;
  Dummy: NativeUInt;
begin
  if FindSection(ABytes, MACHO_SEG_WSHL, MACHO_SECT_PAYLOAD, Dummy, Dummy) then
    Exit(mmrOk);
  if not FindSeg(ABytes, MACHO_SEG_LINKEDIT, Link) then
    Exit(mmrMalformed);
  Result := WalkHeader(ABytes, Ncmds, Sizeofcmds, Cpu);
  if Result <> mmrOk then
    Exit;
  CmdEnd := NativeUInt(MH_HEADER_SIZE) + NativeUInt(Sizeofcmds);
  FirstFile := FirstFileBackedOff(ABytes);
  if FirstFile < CmdEnd + NEED then
    Exit(mmrNoHeaderSlack);
  InsertAt := Link.CmdOff;
  { Grow sizeofcmds into the existing header slack. File sections stay put. }
  if CmdEnd > InsertAt then
    for I := CmdEnd downto InsertAt + 1 do
      ABytes[I + NEED - 1] := ABytes[I - 1];
  for I := 0 to NEED - 1 do
    ABytes[InsertAt + I] := 0;
  WU32(ABytes, InsertAt, LC_SEGMENT_64);
  WU32(ABytes, InsertAt + 4, NEED);
  WriteName(ABytes, InsertAt + 8, MACHO_SEG_WSHL);
  WU64(ABytes, InsertAt + 24, Link.VmAddr);
  WU64(ABytes, InsertAt + 32, 0);
  WU64(ABytes, InsertAt + 40, Link.FileOff);
  WU64(ABytes, InsertAt + 48, 0);
  WU32(ABytes, InsertAt + 56, VM_PROT_READ);
  WU32(ABytes, InsertAt + 60, VM_PROT_READ);
  WU32(ABytes, InsertAt + 64, 1);
  WU32(ABytes, InsertAt + 68, 0);
  WriteName(ABytes, InsertAt + LC_SEGMENT_64_SIZE, MACHO_SECT_PAYLOAD);
  WriteName(ABytes, InsertAt + LC_SEGMENT_64_SIZE + 16, MACHO_SEG_WSHL);
  WU64(ABytes, InsertAt + LC_SEGMENT_64_SIZE + 32, Link.VmAddr);
  WU64(ABytes, InsertAt + LC_SEGMENT_64_SIZE + 40, 0);
  WU32(ABytes, InsertAt + LC_SEGMENT_64_SIZE + 48, UInt32(Link.FileOff));
  WU32(ABytes, InsertAt + LC_SEGMENT_64_SIZE + 52, 0);
  WU32(ABytes, 16, Ncmds + 1);
  WU32(ABytes, 20, Sizeofcmds + NEED);
  Result := mmrOk;
end;

function PlacePayload(var ABytes: TWasmBytes;
  const APayload: TWasmBytes): TWasmMachOResult;
var
  CmdOff, SectOff: NativeUInt;
  Link, Wshl: TSeg64;
  OldFile, NewFile, At: UInt64;
  Delta: Int64;
  I: NativeUInt;
  VmAddr: UInt64;
begin
  if not FindSection(ABytes, MACHO_SEG_WSHL, MACHO_SECT_PAYLOAD, CmdOff,
    SectOff) then
    Exit(mmrPayloadMissing);
  if not FindSeg(ABytes, MACHO_SEG_LINKEDIT, Link) then
    Exit(mmrMalformed);
  OldFile := RU64(ABytes, CmdOff + 48);
  if Length(APayload) = 0 then
    NewFile := 0
  else
    NewFile := AlignUp64(UInt64(Length(APayload)), MACHO_SEGALIGN);
  At := RU64(ABytes, CmdOff + 40);
  if At = 0 then
    At := Link.FileOff;
  Delta := Int64(NewFile) - Int64(OldFile);
  if Delta > 0 then
  begin
    InsertBytes(ABytes, NativeUInt(At + OldFile), NativeUInt(Delta));
    BumpFileOffsets(ABytes, At + OldFile, Delta);
  end
  else if Delta < 0 then
  begin
    DeleteBytes(ABytes, NativeUInt(At + NewFile), NativeUInt(-Delta));
    BumpFileOffsets(ABytes, At + NewFile, Delta);
  end;
  if not FindSection(ABytes, MACHO_SEG_WSHL, MACHO_SECT_PAYLOAD, CmdOff,
    SectOff) then
    Exit(mmrPayloadMissing);
  WU64(ABytes, CmdOff + 40, At);
  WU64(ABytes, CmdOff + 48, NewFile);
  if NewFile = 0 then
    WU64(ABytes, CmdOff + 32, 0)
  else
    WU64(ABytes, CmdOff + 32, NewFile);
  WU64(ABytes, SectOff + 40, UInt64(Length(APayload)));
  WU32(ABytes, SectOff + 48, UInt32(At));
  if NewFile > 0 then
    for I := 0 to NativeUInt(NewFile) - 1 do
      ABytes[NativeUInt(At) + I] := 0;
  if Length(APayload) > 0 then
    for I := 0 to NativeUInt(Length(APayload)) - 1 do
      ABytes[NativeUInt(At) + I] := APayload[I];
  if FindSeg(ABytes, MACHO_SEG_LINKEDIT, Link)
    and FindSeg(ABytes, MACHO_SEG_WSHL, Wshl) then
  begin
    VmAddr := Wshl.VmAddr + RU64(ABytes, CmdOff + 32);
    WU64(ABytes, Link.CmdOff + 24, VmAddr);
  end;
  Result := mmrOk;
end;

function PackageMachORuntimeShell(const ATemplate, APayload: TWasmBytes;
  const AIdentifier: string; out AOutput: TWasmBytes): TWasmMachOResult;
var
  Info: TWasmMachOInfo;
  Working: TWasmBytes;
  I: NativeUInt;
begin
  AOutput := nil;
  Result := InspectMachO(ATemplate, Info);
  if Result <> mmrOk then
    Exit;
  SetLength(Working, Length(ATemplate));
  if Length(ATemplate) > 0 then
    for I := 0 to NativeUInt(Length(ATemplate)) - 1 do
      Working[I] := ATemplate[I];
  if not Info.HasPayload then
  begin
    Result := InsertPayloadCommand(Working);
    if Result <> mmrOk then
      Exit;
  end;
  Result := PlacePayload(Working, APayload);
  if Result <> mmrOk then
    Exit;
  Result := Resign(Working, AIdentifier);
  if Result <> mmrOk then
    Exit;
  Result := VerifyMachOAdHocSignature(Working);
  if Result <> mmrOk then
    Exit;
  AOutput := Working;
end;

procedure WriteSeg(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const AName: string; const AVmAddr, AVmSize, AFileOff, AFileSize: UInt64;
  const ANsects, AProt: UInt32);
begin
  WU32(ABytes, AOff, LC_SEGMENT_64);
  WU32(ABytes, AOff + 4, LC_SEGMENT_64_SIZE + ANsects * SECTION_64_SIZE);
  WriteName(ABytes, AOff + 8, AName);
  WU64(ABytes, AOff + 24, AVmAddr);
  WU64(ABytes, AOff + 32, AVmSize);
  WU64(ABytes, AOff + 40, AFileOff);
  WU64(ABytes, AOff + 48, AFileSize);
  WU32(ABytes, AOff + 56, AProt);
  WU32(ABytes, AOff + 60, AProt);
  WU32(ABytes, AOff + 64, ANsects);
  WU32(ABytes, AOff + 68, 0);
end;

procedure WriteSect(var ABytes: TWasmBytes; const AOff: NativeUInt;
  const ASect, ASeg: string; const AAddr, ASize: UInt64;
  const AFileOff, AAlign: UInt32);
begin
  WriteName(ABytes, AOff, ASect);
  WriteName(ABytes, AOff + 16, ASeg);
  WU64(ABytes, AOff + 32, AAddr);
  WU64(ABytes, AOff + 40, ASize);
  WU32(ABytes, AOff + 48, AFileOff);
  WU32(ABytes, AOff + 52, AAlign);
end;

function WriteMachOShellTemplate(const ATarget: TWasmMachOTarget): TWasmBytes;
const
  TEXT_FILE = UInt64($4000);
  NCMDS = 5;
  SIZEOFCMDS = LC_SEGMENT_64_SIZE
    + (LC_SEGMENT_64_SIZE + SECTION_64_SIZE)
    + (LC_SEGMENT_64_SIZE + SECTION_64_SIZE)
    + LC_SEGMENT_64_SIZE
    + LC_LINKEDIT_DATA_SIZE;
var
  Cpu, Sub: UInt32;
  OffText, OffWshl, OffLink, OffSig: NativeUInt;
  Signed: TWasmBytes;
  Res: TWasmMachOResult;
begin
  Result := nil;
  if ATarget = wmtAarch64Darwin then
  begin
    Cpu := CPU_TYPE_ARM64;
    Sub := CPU_SUBTYPE_ARM64_ALL;
  end
  else
  begin
    Cpu := CPU_TYPE_X86_64;
    Sub := CPU_SUBTYPE_X86_64_ALL;
  end;
  SetLength(Result, TEXT_FILE);
  FillChar(Result[0], Length(Result), 0);
  WU32(Result, 0, MH_MAGIC_64);
  WU32(Result, 4, Cpu);
  WU32(Result, 8, Sub);
  WU32(Result, 12, MH_EXECUTE);
  WU32(Result, 16, NCMDS);
  WU32(Result, 20, SIZEOFCMDS);
  WU32(Result, 24, MH_NOUNDEFS or MH_PIE);
  OffText := MH_HEADER_SIZE + LC_SEGMENT_64_SIZE;
  OffWshl := OffText + LC_SEGMENT_64_SIZE + SECTION_64_SIZE;
  OffLink := OffWshl + LC_SEGMENT_64_SIZE + SECTION_64_SIZE;
  OffSig := OffLink + LC_SEGMENT_64_SIZE;
  WriteSeg(Result, MH_HEADER_SIZE, MACHO_SEG_PAGEZERO, 0, PAGEZERO_VMSIZE,
    0, 0, 0, 0);
  WriteSeg(Result, OffText, MACHO_SEG_TEXT, TEXT_VMADDR, TEXT_FILE, 0,
    TEXT_FILE, 1, VM_PROT_READ or 4);
  WriteSect(Result, OffText + LC_SEGMENT_64_SIZE, MACHO_SECT_TEXT,
    MACHO_SEG_TEXT, TEXT_VMADDR + $1000, 16, $1000, 4);
  WriteSeg(Result, OffWshl, MACHO_SEG_WSHL, TEXT_VMADDR + TEXT_FILE, 0,
    TEXT_FILE, 0, 1, VM_PROT_READ);
  WriteSect(Result, OffWshl + LC_SEGMENT_64_SIZE, MACHO_SECT_PAYLOAD,
    MACHO_SEG_WSHL, TEXT_VMADDR + TEXT_FILE, 0, UInt32(TEXT_FILE), 0);
  WriteSeg(Result, OffLink, MACHO_SEG_LINKEDIT, TEXT_VMADDR + TEXT_FILE, 0,
    TEXT_FILE, 0, 0, VM_PROT_READ);
  WU32(Result, OffSig, LC_CODE_SIGNATURE);
  WU32(Result, OffSig + 4, LC_LINKEDIT_DATA_SIZE);
  WU32(Result, OffSig + 8, UInt32(TEXT_FILE));
  WU32(Result, OffSig + 12, 0);
  Res := Resign(Result, MACHO_DEFAULT_IDENT);
  if Res <> mmrOk then
    Result := nil
  else
  begin
    Signed := Result;
    Result := Signed;
  end;
end;

end.
