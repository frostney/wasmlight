{ Unit suite for Wasm.MachO — structural templates, payload placement, and
  ad-hoc signatures for aarch64-darwin and x86_64-darwin.

  The interpreter-free shell (#34) and product payload records (#35) are
  not merged. These tests drive the documented placeholder seam: opaque
  payload bytes in `__WSHL,__payload`, integrity from the CodeDirectory.
  Host `codesign` / launch checks run only on Darwin and only when a thin
  host executable is available; Linux still emits and verifies both
  targets. }
program Wasm.MachO.Test;

{$I Shared.inc}

uses
  SysUtils,
{$IFDEF DARWIN}
  Unix,
{$ENDIF}

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.MachO;

type
  TMachOTests = class(TTestSuite)
  private
    function SamplePayload: TWasmBytes;
    function BytesEqual(const A, B: TWasmBytes): Boolean;
    procedure ExpectTarget(const ATarget: TWasmMachOTarget);
    {$IFDEF DARWIN}
    function ReadWholeFile(const APath: string; out ABytes: TWasmBytes): Boolean;
    function WriteWholeFile(const APath: string; const ABytes: TWasmBytes): Boolean;
    function ThinHostExecutable(out APath: string): Boolean;
    {$ENDIF}
  public
    procedure SetupTests; override;
    procedure TestTemplateAarch64;
    procedure TestTemplateX64;
    procedure TestPackageRoundTripBothTargets;
    procedure TestPackageDeterministic;
    procedure TestRejectAlteredPayload;
    procedure TestRejectNotMachO;
    procedure TestRejectTruncated;
    procedure TestRejectFat;
    procedure TestEmptyPayloadExtractsEmpty;
    procedure TestTargetNames;
    {$IFDEF DARWIN}
    procedure TestCodesignVerifies;
    procedure TestHostBinaryLaunchAndTamper;
    {$ENDIF}
  end;

function TMachOTests.SamplePayload: TWasmBytes;
const
  { Distinct from WAOT/WSH1 so a later #35 parser cannot mistake the
    placeholder bytes for a product record. }
  RAW: array[0..11] of Byte = (
    $57, $50, $4C, $48, $01, $00, $00, $00, $DE, $AD, $BE, $EF
  );
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(RAW));
  for I := 0 to High(RAW) do
    Result[I] := RAW[I];
end;

function TMachOTests.BytesEqual(const A, B: TWasmBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

procedure TMachOTests.ExpectTarget(const ATarget: TWasmMachOTarget);
var
  Tmpl, Packaged, Got: TWasmBytes;
  Info: TWasmMachOInfo;
  Res: TWasmMachOResult;
begin
  Tmpl := WriteMachOShellTemplate(ATarget);
  Expect<Boolean>(Length(Tmpl) > 0).ToBe(True);
  Res := InspectMachO(Tmpl, Info);
  Expect<Integer>(Ord(Res)).ToBe(Ord(mmrOk));
  Expect<Integer>(Ord(Info.Target)).ToBe(Ord(ATarget));
  Expect<Boolean>(Info.HasPayload).ToBe(True);
  Expect<Boolean>(Info.HasSignature).ToBe(True);
  Expect<Integer>(Ord(VerifyMachOAdHocSignature(Tmpl))).ToBe(Ord(mmrOk));
  Res := PackageMachORuntimeShell(Tmpl, SamplePayload, '', Packaged);
  Expect<Integer>(Ord(Res)).ToBe(Ord(mmrOk));
  Res := ExtractMachOPayload(Packaged, Got);
  Expect<Integer>(Ord(Res)).ToBe(Ord(mmrOk));
  Expect<Boolean>(BytesEqual(Got, SamplePayload)).ToBe(True);
  Expect<Integer>(Ord(VerifyMachOAdHocSignature(Packaged))).ToBe(Ord(mmrOk));
  Res := InspectMachO(Packaged, Info);
  Expect<Integer>(Ord(Res)).ToBe(Ord(mmrOk));
  Expect<Integer>(Ord(Info.Target)).ToBe(Ord(ATarget));
end;

procedure TMachOTests.TestTemplateAarch64;
var
  Info: TWasmMachOInfo;
  Tmpl: TWasmBytes;
begin
  Tmpl := WriteMachOShellTemplate(wmtAarch64Darwin);
  Expect<Integer>(Ord(InspectMachO(Tmpl, Info))).ToBe(Ord(mmrOk));
  Expect<UInt32>(Info.CpuType).ToBe(CPU_TYPE_ARM64);
  Expect<string>(MachOTargetName(Info.Target)).ToBe(MACHO_TARGET_AARCH64_DARWIN);
end;

procedure TMachOTests.TestTemplateX64;
var
  Info: TWasmMachOInfo;
  Tmpl: TWasmBytes;
begin
  Tmpl := WriteMachOShellTemplate(wmtX86_64Darwin);
  Expect<Integer>(Ord(InspectMachO(Tmpl, Info))).ToBe(Ord(mmrOk));
  Expect<UInt32>(Info.CpuType).ToBe(CPU_TYPE_X86_64);
  Expect<string>(MachOTargetName(Info.Target)).ToBe(MACHO_TARGET_X86_64_DARWIN);
end;

procedure TMachOTests.TestPackageRoundTripBothTargets;
begin
  ExpectTarget(wmtAarch64Darwin);
  ExpectTarget(wmtX86_64Darwin);
end;

procedure TMachOTests.TestPackageDeterministic;
var
  Tmpl, A, B: TWasmBytes;
begin
  Tmpl := WriteMachOShellTemplate(wmtAarch64Darwin);
  Expect<Integer>(Ord(PackageMachORuntimeShell(Tmpl, SamplePayload,
    'wasmlight-shell', A))).ToBe(Ord(mmrOk));
  Expect<Integer>(Ord(PackageMachORuntimeShell(Tmpl, SamplePayload,
    'wasmlight-shell', B))).ToBe(Ord(mmrOk));
  Expect<Boolean>(BytesEqual(A, B)).ToBe(True);
end;

procedure TMachOTests.TestRejectAlteredPayload;
var
  Tmpl, Packaged, Got: TWasmBytes;
  Info: TWasmMachOInfo;
  Flip: NativeUInt;
begin
  Tmpl := WriteMachOShellTemplate(wmtX86_64Darwin);
  Expect<Integer>(Ord(PackageMachORuntimeShell(Tmpl, SamplePayload, '',
    Packaged))).ToBe(Ord(mmrOk));
  Expect<Integer>(Ord(InspectMachO(Packaged, Info))).ToBe(Ord(mmrOk));
  Expect<Boolean>(Info.HasPayload and (Info.PayloadSize > 0)).ToBe(True);
  Flip := NativeUInt(Info.PayloadOff);
  Packaged[Flip] := Packaged[Flip] xor $FF;
  Expect<Integer>(Ord(VerifyMachOAdHocSignature(Packaged))).ToBe(
    Ord(mmrSignatureInvalid));
  { The bytes are still there — the signature, not a sidecar checksum,
    is what rejects the alteration. }
  Expect<Integer>(Ord(ExtractMachOPayload(Packaged, Got))).ToBe(Ord(mmrOk));
  Expect<Boolean>(Length(Got) = Length(SamplePayload)).ToBe(True);
end;

procedure TMachOTests.TestRejectNotMachO;
var
  Info: TWasmMachOInfo;
  Elf: TWasmBytes;
  Out_: TWasmBytes;
begin
  SetLength(Elf, 4);
  Elf[0] := $7F;
  Elf[1] := Byte(Ord('E'));
  Elf[2] := Byte(Ord('L'));
  Elf[3] := Byte(Ord('F'));
  Expect<Integer>(Ord(InspectMachO(Elf, Info))).ToBe(Ord(mmrNotMachO));
  Expect<Integer>(Ord(PackageMachORuntimeShell(Elf, SamplePayload, '',
    Out_))).ToBe(Ord(mmrNotMachO));
end;

procedure TMachOTests.TestRejectTruncated;
var
  Info: TWasmMachOInfo;
  Short: TWasmBytes;
begin
  SetLength(Short, 6);
  Short[0] := $CF;
  Short[1] := $FA;
  Short[2] := $ED;
  Short[3] := $FE;
  Short[4] := $0C;
  Short[5] := $00;
  Expect<Integer>(Ord(InspectMachO(Short, Info))).ToBe(Ord(mmrTruncated));
end;

procedure TMachOTests.TestRejectFat;
var
  Info: TWasmMachOInfo;
  Fat: TWasmBytes;
begin
  SetLength(Fat, 8);
  { FAT_CIGAM on disk is the big-endian cafe babe as little-endian bytes
    CA FE BA BE. }
  Fat[0] := $CA;
  Fat[1] := $FE;
  Fat[2] := $BA;
  Fat[3] := $BE;
  Fat[4] := 0;
  Fat[5] := 0;
  Fat[6] := 0;
  Fat[7] := 2;
  Expect<Integer>(Ord(InspectMachO(Fat, Info))).ToBe(Ord(mmrUnsupported));
end;

procedure TMachOTests.TestEmptyPayloadExtractsEmpty;
var
  Tmpl, Packaged, Got: TWasmBytes;
begin
  Tmpl := WriteMachOShellTemplate(wmtAarch64Darwin);
  Expect<Integer>(Ord(ExtractMachOPayload(Tmpl, Got))).ToBe(Ord(mmrOk));
  Expect<Integer>(Length(Got)).ToBe(0);
  Expect<Integer>(Ord(PackageMachORuntimeShell(Tmpl, nil, '', Packaged))).ToBe(
    Ord(mmrOk));
  Expect<Integer>(Ord(ExtractMachOPayload(Packaged, Got))).ToBe(Ord(mmrOk));
  Expect<Integer>(Length(Got)).ToBe(0);
  Expect<Integer>(Ord(VerifyMachOAdHocSignature(Packaged))).ToBe(Ord(mmrOk));
end;

procedure TMachOTests.TestTargetNames;
begin
  Expect<string>(MachOTargetName(wmtAarch64Darwin)).ToBe('aarch64-darwin');
  Expect<string>(MachOTargetName(wmtX86_64Darwin)).ToBe('x86_64-darwin');
end;

{$IFDEF DARWIN}
function TMachOTests.ReadWholeFile(const APath: string;
  out ABytes: TWasmBytes): Boolean;
var
  F: file of Byte;
  N: Integer;
begin
  Result := False;
  ABytes := nil;
  AssignFile(F, APath);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then
    Exit;
  N := FileSize(F);
  SetLength(ABytes, N);
  if N > 0 then
    BlockRead(F, ABytes[0], N);
  CloseFile(F);
  Result := True;
end;

function TMachOTests.WriteWholeFile(const APath: string;
  const ABytes: TWasmBytes): Boolean;
var
  F: file of Byte;
begin
  Result := False;
  AssignFile(F, APath);
  {$I-}
  Rewrite(F);
  {$I+}
  if IOResult <> 0 then
    Exit;
  if Length(ABytes) > 0 then
    BlockWrite(F, ABytes[0], Length(ABytes));
  CloseFile(F);
  Result := True;
end;

function TMachOTests.ThinHostExecutable(out APath: string): Boolean;
const
  FAT = '/bin/echo';
var
  Bytes_: TWasmBytes;
  Info: TWasmMachOInfo;
  Slice, Thin: string;
  Status: Integer;
begin
  Result := False;
  APath := '';
  { Released macOS utilities are fat. lipo extracts one slice so the
    packager sees a thin MH_EXECUTE; it is not a linker. }
  {$IFDEF CPUAARCH64}
  Slice := 'arm64';
  {$ELSE}
  Slice := 'x86_64';
  {$ENDIF}
  Thin := GetTempDir + 'wasmlight-macho-thin-' + IntToHex(Random($FFFFFF), 6);
  Status := fpSystem('/usr/bin/lipo -thin ' + Slice + ' ' + FAT + ' -output ' +
    Thin + ' 2>/dev/null');
  if Status <> 0 then
  begin
    {$IFDEF CPUAARCH64}
    Status := fpSystem('/usr/bin/lipo -thin arm64e ' + FAT + ' -output ' +
      Thin + ' 2>/dev/null');
    {$ENDIF}
  end;
  if Status <> 0 then
    Exit;
  if ReadWholeFile(Thin, Bytes_) and (InspectMachO(Bytes_, Info) = mmrOk)
    and (Info.HeaderSlack >= 152) then
  begin
    APath := Thin;
    Exit(True);
  end;
  DeleteFile(Thin);
end;

procedure TMachOTests.TestCodesignVerifies;
var
  Tmpl, Packaged: TWasmBytes;
  Path, Cmd: string;
  Status: Integer;
begin
  Tmpl := WriteMachOShellTemplate(wmtAarch64Darwin);
  {$IFDEF CPUAARCH64}
  Tmpl := WriteMachOShellTemplate(wmtAarch64Darwin);
  {$ELSE}
  Tmpl := WriteMachOShellTemplate(wmtX86_64Darwin);
  {$ENDIF}
  Expect<Integer>(Ord(PackageMachORuntimeShell(Tmpl, SamplePayload,
    'wasmlight-shell', Packaged))).ToBe(Ord(mmrOk));
  Path := GetTempDir + 'wasmlight-macho-codesign-' + IntToHex(Random($FFFFFF), 6);
  Expect<Boolean>(WriteWholeFile(Path, Packaged)).ToBe(True);
  try
    Cmd := '/usr/bin/codesign --verify --strict ' + Path;
    Status := fpSystem(Cmd);
    Expect<Integer>(Status).ToBe(0);
  finally
    DeleteFile(Path);
  end;
end;

procedure TMachOTests.TestHostBinaryLaunchAndTamper;
var
  Host: string;
  Src, Packaged: TWasmBytes;
  Info: TWasmMachOInfo;
  OutPath, BadPath, Quoted: string;
  Status: Integer;
begin
  if not ThinHostExecutable(Host) then
  begin
    { Structural coverage still runs; launch needs a thin MH_EXECUTE with
      header slack. Record that the probe ran. }
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  try
    Expect<Boolean>(ReadWholeFile(Host, Src)).ToBe(True);
    Expect<Integer>(Ord(PackageMachORuntimeShell(Src, SamplePayload,
      'echo', Packaged))).ToBe(Ord(mmrOk));
    Expect<Integer>(Ord(VerifyMachOAdHocSignature(Packaged))).ToBe(Ord(mmrOk));
    OutPath := GetTempDir + 'wasmlight-macho-run-' + IntToHex(Random($FFFFFF), 6);
    Expect<Boolean>(WriteWholeFile(OutPath, Packaged)).ToBe(True);
    try
      fpSystem('/bin/chmod +x ' + OutPath);
      Quoted := OutPath;
      Status := fpSystem(Quoted + ' macho-ok >/dev/null');
      Expect<Integer>(Status).ToBe(0);
      Expect<Integer>(Ord(InspectMachO(Packaged, Info))).ToBe(Ord(mmrOk));
      Packaged[NativeUInt(Info.PayloadOff)] :=
        Packaged[NativeUInt(Info.PayloadOff)] xor $5A;
      BadPath := OutPath + '.bad';
      Expect<Boolean>(WriteWholeFile(BadPath, Packaged)).ToBe(True);
      try
        Status := fpSystem('/usr/bin/codesign --verify --strict ' + BadPath);
        Expect<Boolean>(Status <> 0).ToBe(True);
      finally
        DeleteFile(BadPath);
      end;
    finally
      DeleteFile(OutPath);
    end;
  finally
    if Host <> '' then
      DeleteFile(Host);
  end;
end;
{$ENDIF}

procedure TMachOTests.SetupTests;
begin
  Test('aarch64-darwin template is a thin signed MH_EXECUTE',
    TestTemplateAarch64);
  Test('x86_64-darwin template is a thin signed MH_EXECUTE', TestTemplateX64);
  Test('both macOS targets package and extract the same payload',
    TestPackageRoundTripBothTargets);
  Test('packaging is deterministic for identical inputs',
    TestPackageDeterministic);
  Test('an altered payload fails the ad-hoc signature',
    TestRejectAlteredPayload);
  Test('ELF magic is rejected as not Mach-O', TestRejectNotMachO);
  Test('a truncated header is rejected', TestRejectTruncated);
  Test('a fat binary is unsupported', TestRejectFat);
  Test('an empty payload round-trips on an unfilled template',
    TestEmptyPayloadExtractsEmpty);
  Test('target names match the ADR-0015 spellings', TestTargetNames);
  {$IFDEF DARWIN}
  Test('codesign --verify accepts the packaged native-arch template',
    TestCodesignVerifies);
  Test('a packaged host executable launches and rejects a tampered payload',
    TestHostBinaryLaunchAndTamper);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TMachOTests.Create('Wasm.MachO'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
