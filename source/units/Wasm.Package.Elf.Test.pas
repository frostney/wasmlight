{ Unit suite for Wasm.Package.Elf — Linux ELF runtime-shell packaging
  (ADR-0015, ADR-0016).

  Issues #34 and #35 are not required: every template is the documented
  PlaceholderElfTemplate (a minimal ET_EXEC that exits 0), and every
  payload is a literal byte blob. The tests prove the packager, not the
  future shell or payload format.

  Coverage:
    - both Linux targets package on this host without a linker;
    - identical inputs produce byte-identical output;
    - PT_LOAD extents stay inside the original template;
    - the trailer round-trips and names the target;
    - the template prefix is copied unchanged and the trailer layout is
      pinned independently of ParseElfPackage;
    - an empty payload and an ET_DYN template are accepted;
    - damaged, truncated, already-packaged, reserved, unknown-target, and
      malformed-template inputs are rejected with distinct results;
    - a written file is executable on UNIX, and on a matching Linux host
      the placeholder actually exits 0.

  Every test asserts an outcome (AGENTS.md). }
program Wasm.Package.Elf.Test;

{$I Shared.inc}

uses
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Package.Elf;

type
  TElfPackageTests = class(TTestSuite)
  private
    function SamplePayload: TWasmBytes;
    function BytesEqual(const A, B: TWasmBytes): Boolean;
    function TempPackagePath(const ASuffix: string): string;
    procedure ExpectResult(const AGot, AWant: TWasmElfPackageResult;
      const ACase: string);
  public
    procedure SetupTests; override;

    procedure TestPlaceholderValidatesForBothTargets;
    procedure TestHostPackagesBothLinuxTargets;
    procedure TestPackageIsDeterministic;
    procedure TestTemplateCopiedUnchanged;
    procedure TestLoadExtentsStayInTemplate;
    procedure TestTrailerLayoutIsPinned;
    procedure TestRoundTripPayload;
    procedure TestEmptyPayloadRoundTrip;
    procedure TestAcceptEtDynTemplate;
    procedure TestRejectWrongMachine;
    procedure TestRejectMalformedTemplate;
    procedure TestRejectBadMagic;
    procedure TestRejectBadVersion;
    procedure TestRejectDamagedPayload;
    procedure TestRejectTruncated;
    procedure TestRejectAlreadyPackaged;
    procedure TestRejectReservedAndUnknownTarget;
    procedure TestWrittenFileIsExecutable;
    procedure TestLinuxNativePlaceholderExitsZero;
  end;

function Bytes(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function TElfPackageTests.SamplePayload: TWasmBytes;
begin
  { Literal placeholder for the #35 payload format. }
  Result := Bytes([$57, $4C, $50, $41, $59, $4C, $4F, $41, $44]);
end;

function TElfPackageTests.BytesEqual(const A, B: TWasmBytes): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then
    Exit;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
end;

function TElfPackageTests.TempPackagePath(const ASuffix: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir)
    + 'wasmlight-elf-' + IntToStr(GetProcessID) + '-' + ASuffix;
end;

procedure TElfPackageTests.ExpectResult(
  const AGot, AWant: TWasmElfPackageResult; const ACase: string);
begin
  Expect<string>(ACase + ': ' + IntToStr(Ord(AGot)))
    .ToBe(ACase + ': ' + IntToStr(Ord(AWant)));
end;

procedure TElfPackageTests.TestPlaceholderValidatesForBothTargets;
begin
  ExpectResult(ValidateElfTemplate(PlaceholderElfTemplate(weptAarch64Linux),
    weptAarch64Linux), eprOk, 'aarch64 placeholder');
  ExpectResult(ValidateElfTemplate(PlaceholderElfTemplate(weptX86_64Linux),
    weptX86_64Linux), eprOk, 'x86_64 placeholder');
  Expect<string>(ElfPackageTargetName(weptAarch64Linux)).ToBe('aarch64-linux');
  Expect<string>(ElfPackageTargetName(weptX86_64Linux)).ToBe('x86_64-linux');
end;

procedure TElfPackageTests.TestHostPackagesBothLinuxTargets;
var
  Packaged: TWasmBytes;
  Info: TWasmElfPackageInfo;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Packaged), eprOk, 'package aarch64');
  ExpectResult(ParseElfPackage(Packaged, Info), eprOk, 'parse aarch64');
  Expect<Integer>(Ord(Info.Target)).ToBe(Ord(weptAarch64Linux));
  Expect<Integer>(Integer(Packaged[18]) or (Integer(Packaged[19]) shl 8))
    .ToBe(Integer(EM_AARCH64));

  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptX86_64Linux),
    SamplePayload, weptX86_64Linux, Packaged), eprOk, 'package x86_64');
  ExpectResult(ParseElfPackage(Packaged, Info), eprOk, 'parse x86_64');
  Expect<Integer>(Ord(Info.Target)).ToBe(Ord(weptX86_64Linux));
  Expect<Integer>(Integer(Packaged[18]) or (Integer(Packaged[19]) shl 8))
    .ToBe(Integer(EM_X86_64));
end;

procedure TElfPackageTests.TestPackageIsDeterministic;
var
  First, Second: TWasmBytes;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, First), eprOk, 'first');
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Second), eprOk, 'second');
  Expect<Boolean>(BytesEqual(First, Second)).ToBe(True);
  Expect<UInt64>(ElfPackageHash64Bytes(First))
    .ToBe(ElfPackageHash64Bytes(Second));
  Expect<UInt64>(ElfPackageHash64Bytes(nil))
    .ToBe(UInt64($CBF29CE484222325));
end;

procedure TElfPackageTests.TestTemplateCopiedUnchanged;
var
  Template, Packaged: TWasmBytes;
  Prefix: TWasmBytes;
begin
  Template := PlaceholderElfTemplate(weptAarch64Linux);
  ExpectResult(PackageElfShell(Template, SamplePayload, weptAarch64Linux,
    Packaged), eprOk, 'package aarch64');
  Prefix := Copy(Packaged, 0, Length(Template));
  Expect<Boolean>(BytesEqual(Prefix, Template)).ToBe(True);

  Template := PlaceholderElfTemplate(weptX86_64Linux);
  ExpectResult(PackageElfShell(Template, SamplePayload, weptX86_64Linux,
    Packaged), eprOk, 'package x86_64');
  Prefix := Copy(Packaged, 0, Length(Template));
  Expect<Boolean>(BytesEqual(Prefix, Template)).ToBe(True);
end;

procedure TElfPackageTests.TestLoadExtentsStayInTemplate;
var
  Template, Packaged, Payload: TWasmBytes;
  PhOff: Integer;
  POffset, PFilesz: UInt64;
begin
  Payload := SamplePayload;
  Template := PlaceholderElfTemplate(weptX86_64Linux);
  ExpectResult(PackageElfShell(Template, Payload, weptX86_64Linux, Packaged),
    eprOk, 'package');
  Expect<Integer>(Length(Packaged)).ToBe(Length(Template) + Length(Payload)
    + WLSHELF_TRAILER_SIZE);
  { The one PT_LOAD still names the original file size, so the appended
    payload is not mapped. }
  PhOff := ELF64_EHDR_SIZE;
  POffset := UInt64(Packaged[PhOff + 8])
    or (UInt64(Packaged[PhOff + 9]) shl 8)
    or (UInt64(Packaged[PhOff + 10]) shl 16)
    or (UInt64(Packaged[PhOff + 11]) shl 24)
    or (UInt64(Packaged[PhOff + 12]) shl 32)
    or (UInt64(Packaged[PhOff + 13]) shl 40)
    or (UInt64(Packaged[PhOff + 14]) shl 48)
    or (UInt64(Packaged[PhOff + 15]) shl 56);
  PFilesz := UInt64(Packaged[PhOff + 32])
    or (UInt64(Packaged[PhOff + 33]) shl 8)
    or (UInt64(Packaged[PhOff + 34]) shl 16)
    or (UInt64(Packaged[PhOff + 35]) shl 24)
    or (UInt64(Packaged[PhOff + 36]) shl 32)
    or (UInt64(Packaged[PhOff + 37]) shl 40)
    or (UInt64(Packaged[PhOff + 38]) shl 48)
    or (UInt64(Packaged[PhOff + 39]) shl 56);
  Expect<UInt64>(POffset).ToBe(0);
  Expect<UInt64>(PFilesz).ToBe(UInt64(Length(Template)));
  Expect<Boolean>(POffset + PFilesz <= UInt64(Length(Template))).ToBe(True);
  { ELF identification is unchanged. }
  Expect<Integer>(Integer(Packaged[0])).ToBe(Integer(ELF_MAG0));
  Expect<Integer>(Integer(Packaged[4])).ToBe(Integer(ELFCLASS64));
end;

procedure TElfPackageTests.TestTrailerLayoutIsPinned;
var
  Template, Payload, Packaged: TWasmBytes;
  Off: Integer;
begin
  { Field order is the trailer contract. Package and Parse agreeing is not
    enough: the same mis-order would round-trip. Read the bytes. }
  Payload := SamplePayload;
  Template := PlaceholderElfTemplate(weptAarch64Linux);
  ExpectResult(PackageElfShell(Template, Payload, weptAarch64Linux, Packaged),
    eprOk, 'package');
  Off := Length(Packaged) - WLSHELF_TRAILER_SIZE;
  Expect<Integer>(Off).ToBe(Length(Template) + Length(Payload));
  Expect<UInt64>(
    UInt64(Packaged[Off])
    or (UInt64(Packaged[Off + 1]) shl 8)
    or (UInt64(Packaged[Off + 2]) shl 16)
    or (UInt64(Packaged[Off + 3]) shl 24)
    or (UInt64(Packaged[Off + 4]) shl 32)
    or (UInt64(Packaged[Off + 5]) shl 40)
    or (UInt64(Packaged[Off + 6]) shl 48)
    or (UInt64(Packaged[Off + 7]) shl 56)).ToBe(UInt64(Length(Template)));
  Expect<UInt64>(
    UInt64(Packaged[Off + 8])
    or (UInt64(Packaged[Off + 9]) shl 8)
    or (UInt64(Packaged[Off + 10]) shl 16)
    or (UInt64(Packaged[Off + 11]) shl 24)
    or (UInt64(Packaged[Off + 12]) shl 32)
    or (UInt64(Packaged[Off + 13]) shl 40)
    or (UInt64(Packaged[Off + 14]) shl 48)
    or (UInt64(Packaged[Off + 15]) shl 56)).ToBe(UInt64(Length(Payload)));
  Expect<UInt64>(
    UInt64(Packaged[Off + 16])
    or (UInt64(Packaged[Off + 17]) shl 8)
    or (UInt64(Packaged[Off + 18]) shl 16)
    or (UInt64(Packaged[Off + 19]) shl 24)
    or (UInt64(Packaged[Off + 20]) shl 32)
    or (UInt64(Packaged[Off + 21]) shl 40)
    or (UInt64(Packaged[Off + 22]) shl 48)
    or (UInt64(Packaged[Off + 23]) shl 56)).ToBe(ElfPackageHash64Bytes(Payload));
  Expect<Integer>(Integer(Packaged[Off + 24])).ToBe(Integer(weptAarch64Linux));
  Expect<Integer>(Integer(Packaged[Off + 25])).ToBe(Integer(WLSHELF_FORMAT_VERSION));
  Expect<Integer>(Integer(Packaged[Off + 26])).ToBe(0);
  Expect<Integer>(Integer(Packaged[Off + 27])).ToBe(0);
  Expect<Integer>(Integer(Packaged[Off + 28])).ToBe(Integer(WLSHELF_MAGIC0));
  Expect<Integer>(Integer(Packaged[Off + 29])).ToBe(Integer(WLSHELF_MAGIC1));
  Expect<Integer>(Integer(Packaged[Off + 30])).ToBe(Integer(WLSHELF_MAGIC2));
  Expect<Integer>(Integer(Packaged[Off + 31])).ToBe(Integer(WLSHELF_MAGIC3));
  Expect<Integer>(Integer(Packaged[Off + 32])).ToBe(Integer(WLSHELF_MAGIC4));
  Expect<Integer>(Integer(Packaged[Off + 33])).ToBe(Integer(WLSHELF_MAGIC5));
  Expect<Integer>(Integer(Packaged[Off + 34])).ToBe(Integer(WLSHELF_MAGIC6));
  Expect<Integer>(Integer(Packaged[Off + 35])).ToBe(Integer(WLSHELF_MAGIC7));
end;

procedure TElfPackageTests.TestRoundTripPayload;
var
  Packaged, Payload: TWasmBytes;
  Info: TWasmElfPackageInfo;
begin
  Payload := SamplePayload;
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    Payload, weptAarch64Linux, Packaged), eprOk, 'package');
  ExpectResult(ParseElfPackage(Packaged, Info), eprOk, 'parse');
  Expect<Boolean>(BytesEqual(Info.Payload, Payload)).ToBe(True);
  Expect<UInt64>(Info.PayloadHash).ToBe(ElfPackageHash64Bytes(Payload));
  Expect<Integer>(Integer(Info.FormatVersion)).ToBe(Integer(WLSHELF_FORMAT_VERSION));
end;

procedure TElfPackageTests.TestEmptyPayloadRoundTrip;
var
  Packaged, Empty: TWasmBytes;
  Info: TWasmElfPackageInfo;
begin
  Empty := nil;
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptX86_64Linux),
    Empty, weptX86_64Linux, Packaged), eprOk, 'package empty');
  ExpectResult(ParseElfPackage(Packaged, Info), eprOk, 'parse empty');
  Expect<Integer>(Length(Info.Payload)).ToBe(0);
  Expect<UInt64>(Info.PayloadHash).ToBe(UInt64($CBF29CE484222325));
  Expect<UInt64>(Info.PayloadSize).ToBe(0);
end;

procedure TElfPackageTests.TestAcceptEtDynTemplate;
var
  Template, Packaged: TWasmBytes;
  Info: TWasmElfPackageInfo;
begin
  Template := PlaceholderElfTemplate(weptAarch64Linux);
  Template[16] := Byte(ET_DYN);
  Template[17] := 0;
  ExpectResult(ValidateElfTemplate(Template, weptAarch64Linux), eprOk, 'ET_DYN');
  ExpectResult(PackageElfShell(Template, SamplePayload, weptAarch64Linux,
    Packaged), eprOk, 'package ET_DYN');
  ExpectResult(ParseElfPackage(Packaged, Info), eprOk, 'parse ET_DYN');
  Expect<Integer>(Integer(Packaged[16]) or (Integer(Packaged[17]) shl 8))
    .ToBe(Integer(ET_DYN));
end;

procedure TElfPackageTests.TestRejectWrongMachine;
var
  Packaged: TWasmBytes;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptX86_64Linux, Packaged), eprWrongMachine,
    'aarch64 template as x86_64');
  ExpectResult(ValidateElfTemplate(Bytes([$7F, $45, $4C, $46]),
    weptAarch64Linux), eprBadTemplate, 'truncated ident');
end;

procedure TElfPackageTests.TestRejectMalformedTemplate;
var
  Template, Packaged: TWasmBytes;
begin
  Template := PlaceholderElfTemplate(weptAarch64Linux);
  Template[4] := 1;
  ExpectResult(ValidateElfTemplate(Template, weptAarch64Linux), eprBadTemplate,
    'ELF32');

  Template := PlaceholderElfTemplate(weptAarch64Linux);
  Template[5] := 2;
  ExpectResult(ValidateElfTemplate(Template, weptAarch64Linux), eprBadTemplate,
    'big-endian');

  Template := PlaceholderElfTemplate(weptX86_64Linux);
  Template[16] := 1;
  Template[17] := 0;
  ExpectResult(ValidateElfTemplate(Template, weptX86_64Linux), eprBadTemplate,
    'ET_REL');

  Template := PlaceholderElfTemplate(weptX86_64Linux);
  Template[ELF64_EHDR_SIZE] := 0;
  Template[ELF64_EHDR_SIZE + 1] := 0;
  Template[ELF64_EHDR_SIZE + 2] := 0;
  Template[ELF64_EHDR_SIZE + 3] := 0;
  ExpectResult(ValidateElfTemplate(Template, weptX86_64Linux), eprMalformed,
    'no PT_LOAD');

  Template := PlaceholderElfTemplate(weptAarch64Linux);
  Template[56] := 2;
  Template[57] := 0;
  ExpectResult(ValidateElfTemplate(Template, weptAarch64Linux), eprMalformed,
    'phdr overrun');
  ExpectResult(PackageElfShell(Template, SamplePayload, weptAarch64Linux,
    Packaged), eprMalformed, 'package phdr overrun');
end;

procedure TElfPackageTests.TestRejectBadMagic;
var
  Packaged: TWasmBytes;
  Info: TWasmElfPackageInfo;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Packaged), eprOk, 'package');
  Packaged[High(Packaged)] := Packaged[High(Packaged)] xor $FF;
  ExpectResult(ParseElfPackage(Packaged, Info), eprBadMagic, 'flipped magic');
end;

procedure TElfPackageTests.TestRejectBadVersion;
var
  Packaged: TWasmBytes;
  Info: TWasmElfPackageInfo;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Packaged), eprOk, 'package');
  Packaged[Length(Packaged) - WLSHELF_TRAILER_SIZE + 25] := 99;
  ExpectResult(ParseElfPackage(Packaged, Info), eprBadVersion, 'unknown version');
end;

procedure TElfPackageTests.TestRejectDamagedPayload;
var
  Packaged: TWasmBytes;
  Info: TWasmElfPackageInfo;
  PayloadOff: Integer;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Packaged), eprOk, 'package');
  PayloadOff := Length(Packaged) - WLSHELF_TRAILER_SIZE - Length(SamplePayload);
  Packaged[PayloadOff] := Packaged[PayloadOff] xor $FF;
  ExpectResult(ParseElfPackage(Packaged, Info), eprBadChecksum, 'flipped payload');
end;

procedure TElfPackageTests.TestRejectTruncated;
var
  Packaged, Short: TWasmBytes;
  Info: TWasmElfPackageInfo;
  I, Keep: Integer;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptX86_64Linux),
    SamplePayload, weptX86_64Linux, Packaged), eprOk, 'package');
  { Drop payload bytes but keep the original trailer, so the magic still
    matches and the recorded extent no longer equals the file length. }
  Keep := Length(Packaged) - WLSHELF_TRAILER_SIZE - 2;
  SetLength(Short, Keep + WLSHELF_TRAILER_SIZE);
  for I := 0 to Keep - 1 do
    Short[I] := Packaged[I];
  for I := 0 to WLSHELF_TRAILER_SIZE - 1 do
    Short[Keep + I] := Packaged[Length(Packaged) - WLSHELF_TRAILER_SIZE + I];
  ExpectResult(ParseElfPackage(Short, Info), eprTruncated, 'payload hole');
  ExpectResult(ParseElfPackage(Bytes([$00, $01, $02]), Info), eprTruncated,
    'tiny buffer');
end;

procedure TElfPackageTests.TestRejectAlreadyPackaged;
var
  Once, Twice: TWasmBytes;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Once), eprOk, 'first package');
  ExpectResult(PackageElfShell(Once, SamplePayload, weptAarch64Linux, Twice),
    eprAlreadyPackaged, 'repackage');
end;

procedure TElfPackageTests.TestRejectReservedAndUnknownTarget;
var
  Packaged: TWasmBytes;
  Info: TWasmElfPackageInfo;
  Off: Integer;
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Packaged), eprOk, 'package');
  Off := Length(Packaged) - WLSHELF_TRAILER_SIZE;
  Packaged[Off + 26] := 1;
  ExpectResult(ParseElfPackage(Packaged, Info), eprMalformed, 'reserved');

  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Packaged), eprOk, 'package again');
  Off := Length(Packaged) - WLSHELF_TRAILER_SIZE;
  Packaged[Off + 24] := 99;
  ExpectResult(ParseElfPackage(Packaged, Info), eprMalformed, 'unknown target');
end;

procedure TElfPackageTests.TestWrittenFileIsExecutable;
var
  Packaged: TWasmBytes;
  Path: string;
  {$IFDEF UNIX}
  St: BaseUnix.Stat;
  {$ENDIF}
begin
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(weptAarch64Linux),
    SamplePayload, weptAarch64Linux, Packaged), eprOk, 'package');
  Path := TempPackagePath('exec');
  try
    WriteElfPackageFile(Path, Packaged);
    Expect<Boolean>(FileExists(Path)).ToBe(True);
    {$IFDEF UNIX}
    Expect<Integer>(Integer(FpStat(Path, St))).ToBe(0);
    Expect<Boolean>((St.st_mode and S_IXUSR) <> 0).ToBe(True);
    {$ELSE}
    Expect<Boolean>(True).ToBe(True);
    {$ENDIF}
  finally
    if FileExists(Path) then
      DeleteFile(Path);
  end;
end;

procedure TElfPackageTests.TestLinuxNativePlaceholderExitsZero;
var
  Packaged: TWasmBytes;
  Path: string;
  Target: TWasmElfPackageTarget;
  Code: Integer;
  Native: Boolean;
begin
  Native := False;
  Target := weptAarch64Linux;
  {$IF DEFINED(LINUX) AND DEFINED(CPUAARCH64)}
  Native := True;
  Target := weptAarch64Linux;
  {$ELSEIF DEFINED(LINUX) AND DEFINED(CPUX86_64)}
  Native := True;
  Target := weptX86_64Linux;
  {$ENDIF}
  ExpectResult(PackageElfShell(PlaceholderElfTemplate(Target),
    SamplePayload, Target, Packaged), eprOk, 'package');
  if not Native then
  begin
    { Cross-host packaging is already proven; this host cannot exec the
      Linux ELF. Record that the skip is the non-native path. }
    Expect<Boolean>(Native).ToBe(False);
    Exit;
  end;
  Path := TempPackagePath('smoke');
  try
    WriteElfPackageFile(Path, Packaged);
    Code := ExecuteProcess(Path, '');
    Expect<Integer>(Code).ToBe(0);
  finally
    if FileExists(Path) then
      DeleteFile(Path);
  end;
end;

procedure TElfPackageTests.SetupTests;
begin
  Test('placeholder templates validate for both Linux targets',
    TestPlaceholderValidatesForBothTargets);
  Test('this host packages aarch64-linux and x86_64-linux without a linker',
    TestHostPackagesBothLinuxTargets);
  Test('identical inputs produce byte-identical packages',
    TestPackageIsDeterministic);
  Test('the template prefix is copied byte-for-byte',
    TestTemplateCopiedUnchanged);
  Test('PT_LOAD extents stay inside the original template',
    TestLoadExtentsStayInTemplate);
  Test('the trailer field order is the documented layout',
    TestTrailerLayoutIsPinned);
  Test('payload bytes and checksum round-trip through the trailer',
    TestRoundTripPayload);
  Test('an empty payload round-trips with the FNV offset-basis hash',
    TestEmptyPayloadRoundTrip);
  Test('an ET_DYN template packages without rewriting headers',
    TestAcceptEtDynTemplate);
  Test('a machine mismatch is eprWrongMachine', TestRejectWrongMachine);
  Test('ELF32, big-endian, ET_REL, and missing PT_LOAD are rejected',
    TestRejectMalformedTemplate);
  Test('a flipped trailer magic is eprBadMagic', TestRejectBadMagic);
  Test('an unknown trailer version is eprBadVersion', TestRejectBadVersion);
  Test('a flipped payload byte is eprBadChecksum', TestRejectDamagedPayload);
  Test('a truncated package is eprTruncated', TestRejectTruncated);
  Test('re-packaging a packaged file is eprAlreadyPackaged',
    TestRejectAlreadyPackaged);
  Test('nonzero reserved bytes or an unknown target are eprMalformed',
    TestRejectReservedAndUnknownTarget);
  Test('WriteElfPackageFile sets the UNIX execute bit',
    TestWrittenFileIsExecutable);
  Test('a matching Linux host runs the placeholder to exit 0',
    TestLinuxNativePlaceholderExitsZero);
end;

begin
  TestRunnerProgram.AddSuite(TElfPackageTests.Create('Wasm.Package.Elf'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
