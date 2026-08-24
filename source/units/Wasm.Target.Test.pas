{ Unit suite for Wasm.Target — host-independent 64-bit Unix triples and
  ABI descriptors (issue #30, ADR-0015).

  These cases pin the constructable target set, the published LP64 layout
  against the live Pascal records on a matching 64-bit Unix host, and the
  rule that fingerprints and baked offsets come from the selected
  descriptor rather than SizeOf or a live store. Executable-memory
  allocation is not exercised here; CanExecute is a predicate only.

  FPC gotchas (AGENTS.md): every test records an assertion; a generic
  Expect<T>(...) is never the lone statement of an `on..do`. }
program Wasm.Target.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Target;

type
  TTargetTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestReleasedSetIsFourUnixTargets;
    procedure TestParseRejectsUnknownTriple;
    procedure TestDescriptorsDoNotNeedAStore;
    procedure TestForeignOsSameArchIsEmittable;
    procedure TestExecuteStaysHostGated;
    procedure TestFingerprintsComeFromTheDescriptor;
    procedure TestOsIdentityChangesTheFingerprint;
    procedure TestHostLayoutMatchesLiveRecords;
    procedure TestHostFingerprintMatchesDescriptor;
  end;

function OtherOs(const AOs: TWasmTargetOs): TWasmTargetOs;
begin
  if AOs = wtoDarwin then
    Result := wtoLinux
  else
    Result := wtoDarwin;
end;

procedure TTargetTests.TestReleasedSetIsFourUnixTargets;
var
  I: Integer;
  Target: TWasmTarget;
  Parsed: TWasmTarget;
  Abi: TWasmTargetAbi;
begin
  Expect<Integer>(WASM_TARGET_COUNT).ToBe(4);
  for I := 0 to WASM_TARGET_COUNT - 1 do
  begin
    Target := WasmTargetByIndex(I);
    Expect<Boolean>(WasmTargetSupported(Target)).ToBe(True);
    Expect<Boolean>(WasmTargetParse(WasmTargetTriple(Target), Parsed))
      .ToBe(True);
    Expect<Boolean>(WasmTargetEqual(Parsed, Target)).ToBe(True);
    Abi := WasmTargetAbi(Target);
    Expect<Boolean>(Abi.Triple <> '').ToBe(True);
    Expect<Integer>(Integer(Abi.PointerSize)).ToBe(8);
    Expect<Boolean>(Abi.Layout.MemByteSize = 8).ToBe(True);
    Expect<Boolean>(Abi.HelperCount = WASM_TARGET_HELPER_COUNT).ToBe(True);
  end;
  Expect<string>(WasmTargetTriple(WasmTargetOf(wtaAArch64, wtoDarwin)))
    .ToBe(WASM_TARGET_TRIPLE_AARCH64_DARWIN);
  Expect<string>(WasmTargetTriple(WasmTargetOf(wtaAArch64, wtoLinux)))
    .ToBe(WASM_TARGET_TRIPLE_AARCH64_LINUX);
  Expect<string>(WasmTargetTriple(WasmTargetOf(wtaX86_64, wtoDarwin)))
    .ToBe(WASM_TARGET_TRIPLE_X86_64_DARWIN);
  Expect<string>(WasmTargetTriple(WasmTargetOf(wtaX86_64, wtoLinux)))
    .ToBe(WASM_TARGET_TRIPLE_X86_64_LINUX);
end;

procedure TTargetTests.TestParseRejectsUnknownTriple;
var
  Target: TWasmTarget;
begin
  Expect<Boolean>(WasmTargetParse('i386-unknown-linux-gnu', Target)).ToBe(False);
  Expect<Boolean>(WasmTargetSupported(Target)).ToBe(False);
  Expect<Boolean>(WasmTargetParse('aarch64-pc-windows-msvc', Target)).ToBe(False);
  Expect<Boolean>(WasmTargetParse('', Target)).ToBe(False);
end;

procedure TTargetTests.TestDescriptorsDoNotNeedAStore;
var
  I: Integer;
  Abi: TWasmTargetAbi;
  Fingerprint: UInt64;
begin
  { Constructing every released descriptor and hashing it must not
    instantiate a store or map executable memory. }
  for I := 0 to WASM_TARGET_COUNT - 1 do
  begin
    Abi := WasmTargetAbi(WasmTargetByIndex(I));
    Fingerprint := WasmTargetAbiFingerprint(Abi);
    Expect<Boolean>(Fingerprint <> 0).ToBe(True);
  end;
  Expect<Integer>(Ord(WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoDarwin))
    .ObjectFormat)).ToBe(Ord(wofMachO));
  Expect<Integer>(Ord(WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoLinux))
    .ObjectFormat)).ToBe(Ord(wofElf));
  Expect<Integer>(Integer(WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoDarwin))
    .PageSize)).ToBe(Integer(WASM_TARGET_PAGE_SIZE_16K));
  Expect<Integer>(Integer(WasmTargetAbi(WasmTargetOf(wtaX86_64, wtoLinux))
    .PageSize)).ToBe(Integer(WASM_TARGET_PAGE_SIZE_4K));
  Expect<Integer>(Ord(WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoDarwin))
    .CallingConvention)).ToBe(Ord(wccAapcs64Apple));
  Expect<Integer>(Ord(WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoLinux))
    .CallingConvention)).ToBe(Ord(wccAapcs64));
  Expect<Integer>(Ord(WasmTargetAbi(WasmTargetOf(wtaX86_64, wtoLinux))
    .CallingConvention)).ToBe(Ord(wccSysVAmd64));
end;

procedure TTargetTests.TestForeignOsSameArchIsEmittable;
var
  Host, Foreign: TWasmTarget;
begin
  Host := WasmTargetHost;
  if not WasmTargetSupported(Host) then
  begin
    Expect<Boolean>(WasmTargetCanEmit(Host)).ToBe(False);
    Exit;
  end;
  Foreign := WasmTargetOf(Host.Arch, OtherOs(Host.Os));
  Expect<Boolean>(WasmTargetCanEmit(Host)).ToBe(True);
  Expect<Boolean>(WasmTargetCanEmit(Foreign)).ToBe(True);
  Expect<Boolean>(WasmTargetCanEmit(WasmTargetOf(
    {$IFDEF CPUAARCH64}wtaX86_64{$ELSE}wtaAArch64{$ENDIF},
    Host.Os))).ToBe(False);
end;

procedure TTargetTests.TestExecuteStaysHostGated;
var
  Host, Foreign: TWasmTarget;
begin
  Host := WasmTargetHost;
  if not WasmTargetSupported(Host) then
  begin
    Expect<Boolean>(WasmTargetCanExecute(Host)).ToBe(False);
    Exit;
  end;
  Foreign := WasmTargetOf(Host.Arch, OtherOs(Host.Os));
  Expect<Boolean>(WasmTargetCanExecute(Host)).ToBe(True);
  Expect<Boolean>(WasmTargetCanExecute(Foreign)).ToBe(False);
end;

procedure TTargetTests.TestFingerprintsComeFromTheDescriptor;
var
  Abi, Mutated: TWasmTargetAbi;
  Original: UInt64;
begin
  Abi := WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoLinux));
  Original := WasmTargetAbiFingerprint(Abi);
  Mutated := Abi;
  Mutated.Layout.StoreEpoch := Abi.Layout.StoreEpoch + 8;
  Expect<Boolean>(WasmTargetAbiFingerprint(Mutated) <> Original).ToBe(True);
  Mutated := Abi;
  Mutated.PageSize := WASM_TARGET_PAGE_SIZE_16K;
  Expect<Boolean>(WasmTargetAbiFingerprint(Mutated) <> Original).ToBe(True);
end;

procedure TTargetTests.TestOsIdentityChangesTheFingerprint;
var
  DarwinFp, LinuxFp: UInt64;
begin
  DarwinFp := WasmTargetAbiFingerprint(
    WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoDarwin)));
  LinuxFp := WasmTargetAbiFingerprint(
    WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoLinux)));
  Expect<Boolean>(DarwinFp <> LinuxFp).ToBe(True);
  Expect<Boolean>(
    WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoDarwin)).Layout.StoreEpoch =
    WasmTargetAbi(WasmTargetOf(wtaAArch64, wtoLinux)).Layout.StoreEpoch)
    .ToBe(True);
end;

procedure TTargetTests.TestHostLayoutMatchesLiveRecords;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  Host: TWasmTarget;
  Abi: TWasmTargetAbi;
  JO: TWasmJitOffsets;
  FO: TWasmJitFrameOffsets;
  GO: TWasmJitGcOffsets;
begin
  Host := WasmTargetHost;
  if not WasmTargetSupported(Host) then
  begin
    Expect<Boolean>(WasmTargetSupported(Host)).ToBe(False);
    Exit;
  end;
  Engine := TWasmEngine.Create;
  try
    Store := TWasmStore.Create(Engine);
    try
      Abi := WasmTargetAbi(Host);
      JO := WasmJitOffsets(Store);
      FO := WasmJitFrameOffsets;
      GO := WasmJitGcHeapOffsets;
      Expect<Boolean>(Abi.Layout.StoreEpoch = JO.StoreEpoch).ToBe(True);
      Expect<Boolean>(Abi.Layout.StoreEpochSnapshot = JO.StoreEpochSnapshot)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.StoreJitHelperTable = JO.StoreJitHelperTable)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.FuncInstStride = JO.FuncInstStride).ToBe(True);
      Expect<Boolean>(Abi.Layout.FuncKind = JO.FuncKind).ToBe(True);
      Expect<Boolean>(Abi.Layout.FuncCompiledEntry = JO.FuncCompiledEntry)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.FuncCompiledDirectEntry =
        JO.FuncCompiledDirectEntry).ToBe(True);
      Expect<Boolean>(Abi.Layout.FuncCompiledNativeScalarEntry =
        JO.FuncCompiledNativeScalarEntry).ToBe(True);
      Expect<Boolean>(Abi.Layout.FuncDirectMeta = JO.FuncDirectMeta).ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaFn = JO.DirectMetaFn).ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaIrBase = JO.DirectMetaIrBase)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaFuncAddrs = JO.DirectMetaFuncAddrs)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaEntryZeroRegs =
        JO.DirectMetaEntryZeroRegs).ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaRefRegBits = JO.DirectMetaRefRegBits)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaRegisterCount =
        JO.DirectMetaRegisterCount).ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaEntryZeroCount =
        JO.DirectMetaEntryZeroCount).ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaParam0Reg = JO.DirectMetaParam0Reg)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaParam1Reg = JO.DirectMetaParam1Reg)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.DirectMetaResult0Reg = JO.DirectMetaResult0Reg)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.FuncCallCount = JO.FuncCallCount).ToBe(True);
      Expect<Boolean>(Abi.Layout.MemInstStride = JO.MemInstStride).ToBe(True);
      Expect<Boolean>(Abi.Layout.MemBase = JO.MemBase).ToBe(True);
      Expect<Boolean>(Abi.Layout.MemByteSize = JO.MemByteSize).ToBe(True);
      Expect<Boolean>(Abi.Layout.StoreFHeap = JO.StoreFHeap).ToBe(True);
      Expect<Boolean>(Abi.Layout.StoreTierContext = JO.StoreTierContext)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.InstEngineTypeIds = JO.InstEngineTypeIds)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.HeapFFree0 = GO.HeapFFree0).ToBe(True);
      Expect<Boolean>(Abi.Layout.HeapMarkState = GO.HeapMarkState).ToBe(True);
      Expect<Boolean>(Abi.Layout.HeapBytesLive = GO.HeapBytesLive).ToBe(True);
      Expect<Boolean>(Abi.Layout.HeapBytesAllocated = GO.HeapBytesAllocated)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.HeapObjectCount = GO.HeapObjectCount)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.BlockBase = GO.BlockBase).ToBe(True);
      Expect<Boolean>(Abi.Layout.BlockAllocated = GO.BlockAllocated).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxValues = FO.CtxValues).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxValueTop = FO.CtxValueTop).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxValueCap = FO.CtxValueCap).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxActs = FO.CtxActs).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxDepthCap = FO.CtxDepthCap).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxDepth = FO.CtxDepth).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxFuncsSlot = FO.CtxFuncsSlot).ToBe(True);
      Expect<Boolean>(Abi.Layout.CtxGcFrameSlot = FO.CtxGcFrameSlot).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActStride = FO.ActStride).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActBase = FO.ActBase).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActFn = FO.ActFn).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActInstance = FO.ActInstance).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActFuncAddrs = FO.ActFuncAddrs).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActIP = FO.ActIP).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActGcFrame = FO.ActGcFrame).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActRetKind = FO.ActRetKind).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActRetDest = FO.ActRetDest).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActRetCount = FO.ActRetCount).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActRetBase = FO.ActRetBase).ToBe(True);
      Expect<Boolean>(Abi.Layout.ActEntryResults = FO.ActEntryResults)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.GcFramePrev = FO.GcFramePrev).ToBe(True);
      Expect<Boolean>(Abi.Layout.GcFrameSlots = FO.GcFrameSlots).ToBe(True);
      Expect<Boolean>(Abi.Layout.GcFrameRefRegBits = FO.GcFrameRefRegBits)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.GcFrameRegisterCount = FO.GcFrameRegisterCount)
        .ToBe(True);
      Expect<Boolean>(Abi.Layout.GcFrameInstance = FO.GcFrameInstance)
        .ToBe(True);
      Expect<Boolean>(Abi.IrInstrSize = SizeOf(TWasmIrInstr)).ToBe(True);
      Expect<Boolean>(Abi.ValueSlotSize = SizeOf(TWasmValue)).ToBe(True);
      Expect<Boolean>(Abi.HelperCount = AOT_HELPER_COUNT).ToBe(True);
      Expect<Boolean>(Abi.AbiRevision = AOT_ABI_REVISION).ToBe(True);
    finally
      Store.Free;
    end;
  finally
    Engine.Free;
  end;
end;

procedure TTargetTests.TestHostFingerprintMatchesDescriptor;
var
  Engine: TWasmEngine;
  Store: TWasmStore;
  Host: TWasmTarget;
begin
  Host := WasmTargetHost;
  if not WasmTargetSupported(Host) then
  begin
    Expect<Boolean>(WasmTargetSupported(Host)).ToBe(False);
    Exit;
  end;
  Engine := TWasmEngine.Create;
  try
    Store := TWasmStore.Create(Engine);
    try
      Expect<UInt64>(WasmAotAbiFingerprint(Store)).ToBe(
        WasmTargetAbiFingerprint(WasmTargetAbi(Host)));
    finally
      Store.Free;
    end;
  finally
    Engine.Free;
  end;
end;

procedure TTargetTests.SetupTests;
begin
  Test('the released set is four aarch64/x86_64 Darwin/Linux triples',
    TestReleasedSetIsFourUnixTargets);
  Test('an unknown triple is rejected', TestParseRejectsUnknownTriple);
  Test('every released descriptor constructs without a store',
    TestDescriptorsDoNotNeedAStore);
  Test('same-arch foreign-OS targets are emittable',
    TestForeignOsSameArchIsEmittable);
  Test('native execution stays host-gated', TestExecuteStaysHostGated);
  Test('the fingerprint is a function of the selected descriptor',
    TestFingerprintsComeFromTheDescriptor);
  Test('OS identity changes the fingerprint without changing layout',
    TestOsIdentityChangesTheFingerprint);
  Test('the host descriptor matches the live Pascal layout',
    TestHostLayoutMatchesLiveRecords);
  Test('the host AOT fingerprint is the host descriptor fingerprint',
    TestHostFingerprintMatchesDescriptor);
end;

begin
  TestRunnerProgram.AddSuite(TTargetTests.Create('Wasm.Target'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
