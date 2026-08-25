{ Wasm.Package.Elf — combine a Linux ELF runtime-shell template with an
  opaque payload, without a host linker or compiler (ADR-0015, ADR-0016).

  PURE PACKAGING. This unit copies a well-formed ELF64 LSB template,
  appends caller-supplied payload bytes, and writes a fixed trailer at
  EOF. It does not decode wasm, validate a module, emit machine code, or
  interpret the payload. Issues #34 and #35 own the interpreter-free
  shell and the native-executable payload format; until those land, the
  payload is an opaque blob and PlaceholderElfTemplate is the documented
  stand-in for a released shell.

  WHY APPEND, not a new PT_LOAD / PT_NOTE: the Linux loader maps only the
  program-header extents (gABI ch.5). Extra bytes after the last mapped
  file offset stay on disk, so the template's load addresses, permissions,
  and section table stay valid. Rewriting headers would couple this unit
  to every FPC layout change in the future shell.

  A packaging failure is NOT an EWasmDecodeError (that vocabulary is for
  wasm MODULES). The packager reports a TWasmElfPackageResult so a later
  compile driver can name the reject without collapsing the error
  hierarchy. }
unit Wasm.Package.Elf;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  { 'WLSHELF1' — Wasmlight Shell ELF trailer v1. Lives in the last eight
    bytes so a reader finds it from EOF. }
  WLSHELF_MAGIC0 = Byte($57);   { 'W' }
  WLSHELF_MAGIC1 = Byte($4C);   { 'L' }
  WLSHELF_MAGIC2 = Byte($53);   { 'S' }
  WLSHELF_MAGIC3 = Byte($48);   { 'H' }
  WLSHELF_MAGIC4 = Byte($45);   { 'E' }
  WLSHELF_MAGIC5 = Byte($4C);   { 'L' }
  WLSHELF_MAGIC6 = Byte($46);   { 'F' }
  WLSHELF_MAGIC7 = Byte($31);   { '1' }

  { Trailer layout version. Bump only for a layout the reader must reject. }
  WLSHELF_FORMAT_VERSION = Byte(1);

  { payloadOffset(8) + payloadSize(8) + payloadHash(8) + target(1) +
    version(1) + reserved(2) + magic(8). }
  WLSHELF_TRAILER_SIZE = 36;

  { System V ABI ELF identification and machine numbers.
    e_ident: https://refspecs.linuxbase.org/elf/gabi4+/ch4.eheader.html
    EM_X86_64 = 62, EM_AARCH64 = 183:
    https://github.com/torvalds/linux/blob/master/include/uapi/linux/elf-em.h
    https://gabi.xinuos.com/v42/elf/a-emachine.html }
  ELF_MAG0 = Byte($7F);
  ELF_MAG1 = Byte($45);   { 'E' }
  ELF_MAG2 = Byte($4C);   { 'L' }
  ELF_MAG3 = Byte($46);   { 'F' }
  ELFCLASS64 = Byte(2);
  ELFDATA2LSB = Byte(1);
  EV_CURRENT = Byte(1);
  ET_EXEC = UInt16(2);
  ET_DYN = UInt16(3);
  EM_X86_64 = UInt16(62);
  EM_AARCH64 = UInt16(183);
  PT_LOAD = UInt32(1);
  ELF64_EHDR_SIZE = 64;
  ELF64_PHDR_SIZE = 56;

type
  { The two Linux targets this packager emits. Names match the 0.2.0
    compile spine (`aarch64-linux`, `x86_64-linux`). Numeric ids are this
    unit's placeholder seam until issue #30's ABI descriptors land. }
  TWasmElfPackageTarget = (
    weptAarch64Linux = 1,
    weptX86_64Linux = 2
  );

  { Structural packaging / extract outcome. Distinct reasons so a compile
    driver can report WHY a template or packaged file was refused. }
  TWasmElfPackageResult = (
    eprOk,
    eprBadTemplate,       { not ELF64 LSB, or not ET_EXEC / ET_DYN }
    eprWrongMachine,      { e_machine does not match the requested target }
    eprMalformed,         { header or PHDR extent is out of bounds }
    eprAlreadyPackaged,   { template already ends with a WLSHELF trailer }
    eprBadMagic,          { extract: no trailer magic }
    eprBadVersion,        { extract: unknown trailer version }
    eprBadChecksum,       { extract: payload hash mismatch }
    eprTruncated          { extract: payload extent does not fill to the trailer }
  );

  { Parsed trailer plus the copied payload. Template bytes stay with the
    caller; PayloadOffset is their length in the packaged file. }
  TWasmElfPackageInfo = record
    Target: TWasmElfPackageTarget;
    FormatVersion: Byte;
    PayloadOffset: UInt64;
    PayloadSize: UInt64;
    PayloadHash: UInt64;
    Payload: TWasmBytes;
  end;

{ Canonical target name (`aarch64-linux` / `x86_64-linux`). }
function ElfPackageTargetName(const ATarget: TWasmElfPackageTarget): string;

{ e_machine the template must carry for ATarget. }
function ElfPackageMachine(const ATarget: TWasmElfPackageTarget): UInt16;

{ FNV-1a-64 over a raw range — the trailer payload checksum. Same
  algorithm as the `.waot` self-checksum (corruption guard, not
  authentication); kept here so packaging does not depend on AOT. }
function ElfPackageHash64(const AData: PByte; const ALen: NativeUInt): UInt64;
function ElfPackageHash64Bytes(const ABytes: TWasmBytes): UInt64;

{ A minimal ET_EXEC that exits 0 on Linux for ATarget. This is the
  documented placeholder shell until issue #34 ships the interpreter-free
  Pascal runtime shell. It is not that shell: no validation, WASI, or
  native-code wiring. }
function PlaceholderElfTemplate(const ATarget: TWasmElfPackageTarget): TWasmBytes;

{ eprOk iff ABytes is a well-formed ELF64 LSB ET_EXEC/ET_DYN for ATarget
  with at least one in-bounds PT_LOAD. }
function ValidateElfTemplate(const ABytes: TWasmBytes;
  const ATarget: TWasmElfPackageTarget): TWasmElfPackageResult;

{ Copy ATemplate, append APayload, write the trailer. ATemplate must
  validate for ATarget and must not already be packaged. }
function PackageElfShell(const ATemplate, APayload: TWasmBytes;
  const ATarget: TWasmElfPackageTarget;
  out APackaged: TWasmBytes): TWasmElfPackageResult;

{ Locate the trailer, bounds-check the payload extent, and verify the
  checksum. On eprOk, AInfo.Payload is a copy of the attached bytes. }
function ParseElfPackage(const ABytes: TWasmBytes;
  out AInfo: TWasmElfPackageInfo): TWasmElfPackageResult;

{ Write ABytes and, on UNIX, set owner/group/other execute so the kernel
  will honour the ELF. The bytes themselves are unchanged. }
procedure WriteElfPackageFile(const APath: string; const ABytes: TWasmBytes);

implementation

uses
  Classes
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF}
  ;

{ --- FNV-1a-64 ------------------------------------------------------------ }

{$push}{$Q-}{$R-}

const
  FNV64_OFFSET = UInt64($CBF29CE484222325);
  FNV64_PRIME = UInt64($00000100000001B3);

function ElfPackageHash64(const AData: PByte; const ALen: NativeUInt): UInt64;
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

function ElfPackageHash64Bytes(const ABytes: TWasmBytes): UInt64;
begin
  if Length(ABytes) = 0 then
    Result := ElfPackageHash64(nil, 0)
  else
    Result := ElfPackageHash64(@ABytes[0], NativeUInt(Length(ABytes)));
end;

function ElfPackageTargetName(const ATarget: TWasmElfPackageTarget): string;
begin
  case ATarget of
    weptAarch64Linux: Result := 'aarch64-linux';
    weptX86_64Linux: Result := 'x86_64-linux';
  else
    Result := '';
  end;
end;

function ElfPackageMachine(const ATarget: TWasmElfPackageTarget): UInt16;
begin
  case ATarget of
    weptAarch64Linux: Result := EM_AARCH64;
    weptX86_64Linux: Result := EM_X86_64;
  else
    Result := 0;
  end;
end;

{ --- little-endian helpers ------------------------------------------------ }

function ReadU16(const ABytes: TWasmBytes; const AOff: Integer;
  out AValue: UInt16): Boolean;
begin
  Result := (AOff >= 0) and (AOff <= Length(ABytes) - 2);
  if not Result then
    Exit;
  AValue := UInt16(ABytes[AOff]) or (UInt16(ABytes[AOff + 1]) shl 8);
end;

function ReadU32(const ABytes: TWasmBytes; const AOff: Integer;
  out AValue: UInt32): Boolean;
begin
  Result := (AOff >= 0) and (AOff <= Length(ABytes) - 4);
  if not Result then
    Exit;
  AValue := UInt32(ABytes[AOff])
    or (UInt32(ABytes[AOff + 1]) shl 8)
    or (UInt32(ABytes[AOff + 2]) shl 16)
    or (UInt32(ABytes[AOff + 3]) shl 24);
end;

function ReadU64(const ABytes: TWasmBytes; const AOff: Integer;
  out AValue: UInt64): Boolean;
var
  Lo, Hi: UInt32;
begin
  Result := ReadU32(ABytes, AOff, Lo) and ReadU32(ABytes, AOff + 4, Hi);
  if Result then
    AValue := UInt64(Lo) or (UInt64(Hi) shl 32);
end;

procedure WriteU16At(var ABytes: TWasmBytes; const AOff: Integer;
  const AValue: UInt16);
begin
  ABytes[AOff] := Byte(AValue);
  ABytes[AOff + 1] := Byte(AValue shr 8);
end;

procedure WriteU32At(var ABytes: TWasmBytes; const AOff: Integer;
  const AValue: UInt32);
begin
  ABytes[AOff] := Byte(AValue);
  ABytes[AOff + 1] := Byte(AValue shr 8);
  ABytes[AOff + 2] := Byte(AValue shr 16);
  ABytes[AOff + 3] := Byte(AValue shr 24);
end;

procedure WriteU64At(var ABytes: TWasmBytes; const AOff: Integer;
  const AValue: UInt64);
begin
  WriteU32At(ABytes, AOff, UInt32(AValue));
  WriteU32At(ABytes, AOff + 4, UInt32(AValue shr 32));
end;

function TrailerMagicAt(const ABytes: TWasmBytes;
  const AOff: Integer): Boolean;
begin
  Result := (AOff >= 0) and (AOff <= Length(ABytes) - 8)
    and (ABytes[AOff] = WLSHELF_MAGIC0)
    and (ABytes[AOff + 1] = WLSHELF_MAGIC1)
    and (ABytes[AOff + 2] = WLSHELF_MAGIC2)
    and (ABytes[AOff + 3] = WLSHELF_MAGIC3)
    and (ABytes[AOff + 4] = WLSHELF_MAGIC4)
    and (ABytes[AOff + 5] = WLSHELF_MAGIC5)
    and (ABytes[AOff + 6] = WLSHELF_MAGIC6)
    and (ABytes[AOff + 7] = WLSHELF_MAGIC7);
end;

function HasTrailer(const ABytes: TWasmBytes): Boolean;
begin
  Result := (Length(ABytes) >= WLSHELF_TRAILER_SIZE)
    and TrailerMagicAt(ABytes, Length(ABytes) - 8);
end;

function IsPowerOfTwo(const AValue: UInt64): Boolean;
begin
  Result := (AValue <> 0) and ((AValue and (AValue - 1)) = 0);
end;

{ --- template validation -------------------------------------------------- }

function ValidateElfTemplate(const ABytes: TWasmBytes;
  const ATarget: TWasmElfPackageTarget): TWasmElfPackageResult;
var
  EhType, EhMachine, EhEhsize, EhPhentsize, EhPhnum: UInt16;
  EhVersion: UInt32;
  EhPhoff: UInt64;
  PhOff: Integer;
  I: Integer;
  PType: UInt32;
  POffset, PVaddr, PFilesz, PMemsz, PAlign: UInt64;
  SawLoad: Boolean;
begin
  if HasTrailer(ABytes) then
    Exit(eprAlreadyPackaged);
  if Length(ABytes) < ELF64_EHDR_SIZE then
    Exit(eprBadTemplate);
  if (ABytes[0] <> ELF_MAG0) or (ABytes[1] <> ELF_MAG1)
    or (ABytes[2] <> ELF_MAG2) or (ABytes[3] <> ELF_MAG3) then
    Exit(eprBadTemplate);
  if (ABytes[4] <> ELFCLASS64) or (ABytes[5] <> ELFDATA2LSB)
    or (ABytes[6] <> EV_CURRENT) then
    Exit(eprBadTemplate);
  if not ReadU16(ABytes, 16, EhType) then
    Exit(eprMalformed);
  if (EhType <> ET_EXEC) and (EhType <> ET_DYN) then
    Exit(eprBadTemplate);
  if not ReadU16(ABytes, 18, EhMachine) then
    Exit(eprMalformed);
  if EhMachine <> ElfPackageMachine(ATarget) then
    Exit(eprWrongMachine);
  if not ReadU32(ABytes, 20, EhVersion) then
    Exit(eprMalformed);
  if EhVersion <> EV_CURRENT then
    Exit(eprBadTemplate);
  if not ReadU64(ABytes, 32, EhPhoff) then
    Exit(eprMalformed);
  if not ReadU16(ABytes, 52, EhEhsize) then
    Exit(eprMalformed);
  if not ReadU16(ABytes, 54, EhPhentsize) then
    Exit(eprMalformed);
  if not ReadU16(ABytes, 56, EhPhnum) then
    Exit(eprMalformed);
  if (EhEhsize <> ELF64_EHDR_SIZE) or (EhPhentsize <> ELF64_PHDR_SIZE)
    or (EhPhnum = 0) then
    Exit(eprMalformed);
  if EhPhoff > UInt64(High(Integer)) then
    Exit(eprMalformed);
  if EhPhoff + UInt64(EhPhnum) * ELF64_PHDR_SIZE > UInt64(Length(ABytes)) then
    Exit(eprMalformed);

  SawLoad := False;
  for I := 0 to Integer(EhPhnum) - 1 do
  begin
    PhOff := Integer(EhPhoff) + I * ELF64_PHDR_SIZE;
    if not ReadU32(ABytes, PhOff, PType) then
      Exit(eprMalformed);
    if not ReadU64(ABytes, PhOff + 8, POffset) then
      Exit(eprMalformed);
    if not ReadU64(ABytes, PhOff + 16, PVaddr) then
      Exit(eprMalformed);
    if not ReadU64(ABytes, PhOff + 32, PFilesz) then
      Exit(eprMalformed);
    if not ReadU64(ABytes, PhOff + 40, PMemsz) then
      Exit(eprMalformed);
    if not ReadU64(ABytes, PhOff + 48, PAlign) then
      Exit(eprMalformed);
    if POffset > UInt64(High(Integer)) then
      Exit(eprMalformed);
    if PFilesz > UInt64(High(Integer)) - POffset then
      Exit(eprMalformed);
    if POffset + PFilesz > UInt64(Length(ABytes)) then
      Exit(eprMalformed);
    if PType = PT_LOAD then
    begin
      if PMemsz < PFilesz then
        Exit(eprMalformed);
      if (PAlign > 1) and (not IsPowerOfTwo(PAlign)
        or ((PVaddr mod PAlign) <> (POffset mod PAlign))) then
        Exit(eprMalformed);
      SawLoad := True;
    end;
  end;
  if not SawLoad then
    Exit(eprMalformed);
  Result := eprOk;
end;

{ --- placeholder template ------------------------------------------------- }

function PlaceholderElfTemplate(const ATarget: TWasmElfPackageTarget): TWasmBytes;
const
  { File offset of the first instruction: Ehdr + one Phdr. }
  CODE_OFF = ELF64_EHDR_SIZE + ELF64_PHDR_SIZE;
  VADDR_BASE = UInt64($0000000000400000);
  PAGE = UInt64($1000);
  { x86-64: xor rdi,rdi; mov eax,60; syscall  — exit(0)
    AArch64: mov x0,#0; mov x8,#93; svc #0     — exit(0)
    Encodings from the Intel SDM / ARM ARM; no assembler is invoked. }
  X64_EXIT: array[0..9] of Byte = (
    $48, $31, $FF,
    $B8, $3C, $00, $00, $00,
    $0F, $05
  );
  A64_EXIT: array[0..11] of Byte = (
    $00, $00, $80, $D2,
    $A8, $0B, $80, $D2,
    $01, $00, $00, $D4
  );
var
  Code: array of Byte;
  I: Integer;
  FileSize: Integer;
  Machine: UInt16;
begin
  case ATarget of
    weptX86_64Linux:
    begin
      SetLength(Code, Length(X64_EXIT));
      for I := 0 to High(X64_EXIT) do
        Code[I] := X64_EXIT[I];
      Machine := EM_X86_64;
    end;
  else
    SetLength(Code, Length(A64_EXIT));
    for I := 0 to High(A64_EXIT) do
      Code[I] := A64_EXIT[I];
    Machine := EM_AARCH64;
  end;

  FileSize := CODE_OFF + Length(Code);
  Result := nil;
  SetLength(Result, FileSize);
  FillChar(Result[0], FileSize, 0);

  Result[0] := ELF_MAG0;
  Result[1] := ELF_MAG1;
  Result[2] := ELF_MAG2;
  Result[3] := ELF_MAG3;
  Result[4] := ELFCLASS64;
  Result[5] := ELFDATA2LSB;
  Result[6] := EV_CURRENT;
  WriteU16At(Result, 16, ET_EXEC);
  WriteU16At(Result, 18, Machine);
  WriteU32At(Result, 20, EV_CURRENT);
  WriteU64At(Result, 24, VADDR_BASE + CODE_OFF);
  WriteU64At(Result, 32, ELF64_EHDR_SIZE);
  WriteU64At(Result, 40, 0);
  WriteU32At(Result, 48, 0);
  WriteU16At(Result, 52, ELF64_EHDR_SIZE);
  WriteU16At(Result, 54, ELF64_PHDR_SIZE);
  WriteU16At(Result, 56, 1);
  WriteU16At(Result, 58, 0);
  WriteU16At(Result, 60, 0);
  WriteU16At(Result, 62, 0);

  { One PT_LOAD covering the whole file from offset 0 so the kernel maps
    the headers and the code. PF_R|PF_X = 5. }
  WriteU32At(Result, ELF64_EHDR_SIZE, PT_LOAD);
  WriteU32At(Result, ELF64_EHDR_SIZE + 4, 5);
  WriteU64At(Result, ELF64_EHDR_SIZE + 8, 0);
  WriteU64At(Result, ELF64_EHDR_SIZE + 16, VADDR_BASE);
  WriteU64At(Result, ELF64_EHDR_SIZE + 24, VADDR_BASE);
  WriteU64At(Result, ELF64_EHDR_SIZE + 32, UInt64(FileSize));
  WriteU64At(Result, ELF64_EHDR_SIZE + 40, UInt64(FileSize));
  WriteU64At(Result, ELF64_EHDR_SIZE + 48, PAGE);

  for I := 0 to High(Code) do
    Result[CODE_OFF + I] := Code[I];
end;

{ --- package / parse ------------------------------------------------------ }

function PackageElfShell(const ATemplate, APayload: TWasmBytes;
  const ATarget: TWasmElfPackageTarget;
  out APackaged: TWasmBytes): TWasmElfPackageResult;
var
  Total, Off: Integer;
  Hash: UInt64;
begin
  APackaged := nil;
  Result := ValidateElfTemplate(ATemplate, ATarget);
  if Result <> eprOk then
    Exit;
  if UInt64(Length(ATemplate)) + UInt64(Length(APayload))
    + WLSHELF_TRAILER_SIZE > UInt64(High(Integer)) then
    Exit(eprMalformed);

  Total := Length(ATemplate) + Length(APayload) + WLSHELF_TRAILER_SIZE;
  SetLength(APackaged, Total);
  if Length(ATemplate) > 0 then
    Move(ATemplate[0], APackaged[0], Length(ATemplate));
  if Length(APayload) > 0 then
    Move(APayload[0], APackaged[Length(ATemplate)], Length(APayload));

  Hash := ElfPackageHash64Bytes(APayload);
  Off := Length(ATemplate) + Length(APayload);
  WriteU64At(APackaged, Off, UInt64(Length(ATemplate)));
  WriteU64At(APackaged, Off + 8, UInt64(Length(APayload)));
  WriteU64At(APackaged, Off + 16, Hash);
  APackaged[Off + 24] := Byte(ATarget);
  APackaged[Off + 25] := WLSHELF_FORMAT_VERSION;
  APackaged[Off + 26] := 0;
  APackaged[Off + 27] := 0;
  APackaged[Off + 28] := WLSHELF_MAGIC0;
  APackaged[Off + 29] := WLSHELF_MAGIC1;
  APackaged[Off + 30] := WLSHELF_MAGIC2;
  APackaged[Off + 31] := WLSHELF_MAGIC3;
  APackaged[Off + 32] := WLSHELF_MAGIC4;
  APackaged[Off + 33] := WLSHELF_MAGIC5;
  APackaged[Off + 34] := WLSHELF_MAGIC6;
  APackaged[Off + 35] := WLSHELF_MAGIC7;
  Result := eprOk;
end;

function ParseElfPackage(const ABytes: TWasmBytes;
  out AInfo: TWasmElfPackageInfo): TWasmElfPackageResult;
var
  TrailerOff: Integer;
  TargetByte, Version: Byte;
  Hash: UInt64;
  ExpectedEnd: UInt64;
  Template: TWasmBytes;
begin
  AInfo.Target := weptAarch64Linux;
  AInfo.FormatVersion := 0;
  AInfo.PayloadOffset := 0;
  AInfo.PayloadSize := 0;
  AInfo.PayloadHash := 0;
  AInfo.Payload := nil;
  if Length(ABytes) < WLSHELF_TRAILER_SIZE then
    Exit(eprTruncated);
  TrailerOff := Length(ABytes) - WLSHELF_TRAILER_SIZE;
  if not TrailerMagicAt(ABytes, TrailerOff + 28) then
    Exit(eprBadMagic);
  Version := ABytes[TrailerOff + 25];
  if Version <> WLSHELF_FORMAT_VERSION then
    Exit(eprBadVersion);
  if (ABytes[TrailerOff + 26] <> 0) or (ABytes[TrailerOff + 27] <> 0) then
    Exit(eprMalformed);
  TargetByte := ABytes[TrailerOff + 24];
  if (TargetByte <> Byte(weptAarch64Linux))
    and (TargetByte <> Byte(weptX86_64Linux)) then
    Exit(eprMalformed);
  AInfo.Target := TWasmElfPackageTarget(TargetByte);
  AInfo.FormatVersion := Version;
  if not ReadU64(ABytes, TrailerOff, AInfo.PayloadOffset) then
    Exit(eprTruncated);
  if not ReadU64(ABytes, TrailerOff + 8, AInfo.PayloadSize) then
    Exit(eprTruncated);
  if not ReadU64(ABytes, TrailerOff + 16, AInfo.PayloadHash) then
    Exit(eprTruncated);
  if AInfo.PayloadOffset > UInt64(High(Integer)) then
    Exit(eprTruncated);
  if AInfo.PayloadSize > UInt64(High(Integer)) then
    Exit(eprTruncated);
  ExpectedEnd := AInfo.PayloadOffset + AInfo.PayloadSize
    + UInt64(WLSHELF_TRAILER_SIZE);
  if ExpectedEnd <> UInt64(Length(ABytes)) then
    Exit(eprTruncated);
  if AInfo.PayloadOffset + AInfo.PayloadSize > UInt64(TrailerOff) then
    Exit(eprTruncated);

  Template := Copy(ABytes, 0, Integer(AInfo.PayloadOffset));
  Result := ValidateElfTemplate(Template, AInfo.Target);
  if Result = eprAlreadyPackaged then
    Result := eprMalformed;
  if Result <> eprOk then
    Exit;

  SetLength(AInfo.Payload, Integer(AInfo.PayloadSize));
  if AInfo.PayloadSize > 0 then
    Move(ABytes[Integer(AInfo.PayloadOffset)], AInfo.Payload[0],
      Integer(AInfo.PayloadSize));
  if Length(AInfo.Payload) = 0 then
    Hash := ElfPackageHash64(nil, 0)
  else
    Hash := ElfPackageHash64(@AInfo.Payload[0], NativeUInt(Length(AInfo.Payload)));
  if Hash <> AInfo.PayloadHash then
  begin
    AInfo.Payload := nil;
    Exit(eprBadChecksum);
  end;
  Result := eprOk;
end;

procedure WriteElfPackageFile(const APath: string; const ABytes: TWasmBytes);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
  {$IFDEF UNIX}
  if FpChmod(APath, &755) <> 0 then
    raise EInOutError.CreateFmt('could not mark %s executable', [APath]);
  {$ENDIF}
end;

end.
