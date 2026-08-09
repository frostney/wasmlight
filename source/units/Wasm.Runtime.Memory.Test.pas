{ Unit suite for Wasm.Runtime.Memory — the memory-access chokepoint.

  The chokepoint is the surface ADR-0005 says this design is most exposed
  on, so the cases below are the ones that decide whether it is right:
  the off-by-one triple at the bound, the overflow forms that a naive
  comparison lets through, the u64 static offset that falls out of the
  guard region, growth in place versus growth that moves the memory, and
  the registry bookkeeping the fault handler depends on.

  An out-of-bounds access on a guard-page memory is meant to fault, and a
  fault raised in-process would kill the whole test runner if any part of
  the handler were wrong. Most cases therefore probe guard-page memories
  through their strategy record, the reservation registry, and the
  width-aware accesses every strategy checks. The ONE exception is
  TestGuardFaultTrapsInAForkedChild, which drives a genuine SIGSEGV through
  the handler and trampoline inside a forked child and asserts the child
  trapped and exited cleanly — the standing debt both suite headers named,
  now paid on the guard platform. }
program Wasm.Runtime.Memory.Test;

{$I Shared.inc}

uses
  SysUtils,
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  BaseUnix,
  {$ENDIF}

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Traps;

{$IF DEFINED(UNIX) AND DEFINED(CPU64)}
{ _exit: terminate the forked child WITHOUT running FPC finalisation, which
  would double-run the test runner's teardown and flush its buffers twice. }
procedure ChildExit(ACode: cint); cdecl; external 'c' name '_exit';

{ Guest region for the forked-child fault test: a real out-of-bounds store
  one page past the committed region. Offset 0 folds, so no explicit check
  runs — the store lands in the PROT_NONE guard and the MMU faults, which
  is exactly the path the in-process suites cannot exercise. }
procedure GuestOobWrite(const AData: Pointer);
var
  Mem: PWasmMemoryInst;
begin
  Mem := PWasmMemoryInst(AData);
  MemAddress(Mem^, Mem^.ByteSize, 0, 1)^ := 42;
end;
{$ENDIF}

type
  TRuntimeMemoryTests = class(TTestSuite)
  private
    { True when the access traps with the canonical out-of-bounds
      message. Used instead of a bare Fail so that both outcomes record
      an assertion. }
    function AccessTraps(var AMem: TWasmMemoryInst;
      const AIndex, AOffset, ASize: UInt64): Boolean;
    function RangeTraps(var AMem: TWasmMemoryInst;
      const AIndex, ALength: UInt64): Boolean;
    function MemTypeOf(const AAddrType: TWasmAddrType;
      const AMin: UInt64): TWasmMemType;
    function MemTypeWithMax(const AAddrType: TWasmAddrType;
      const AMin, AMax: UInt64): TWasmMemType;
    procedure PokeAndPeek(var AMem: TWasmMemoryInst;
      const AIndex: UInt64; const AValue: Byte);
    function PeekByteAt(var AMem: TWasmMemoryInst;
      const AIndex: UInt64): Byte;
    { Replays one access under every strategy this host can build and
      reports whether they all agreed. }
    function StrategiesAgree(const AAddrType: TWasmAddrType;
      const APages, AIndex, AOffset, ASize: UInt64): Boolean;
    { How many strategies this host can build for AAddrType — so the
      equivalence test can assert it actually compared more than one. }
    function SupportedStrategyCount(const AAddrType: TWasmAddrType): Integer;
  public
    procedure SetupTests; override;

    procedure TestStrategyMatrix;
    procedure TestStrategySupportMatrix;
    procedure TestPageCeilings;
    procedure TestNativeMemoryShape;
    procedure TestZeroPageMemoryHasABaseAndTrapsOnAccess;
    procedure TestBoundIsTheOffByOneTriple;
    procedure TestOffsetAndSizeParticipateInTheBound;
    procedure TestOverflowFormsCannotWrapIntoRange;
    procedure TestRangeChecksTheWholeSpan;
    procedure TestRoundTripThroughTheChokepoint;
    procedure TestLargeStaticOffsetFallsThroughToAFullCheck;
    procedure TestGuardFoldAccountsForAccessWidth;
    procedure TestFoldUsesTheInstanceGuardNotTheConstant;
    procedure TestGuardFaultTrapsInAForkedChild;
    procedure TestStrategiesTrapIdentically;
    procedure TestGuardReservationIsRegistered;
    procedure TestBoundsCheckedMemoryIsNotRegistered;
    procedure TestFreeDeregistersBeforeUnmapping;
    procedure TestGrowInPlacePreservesContents;
    procedure TestGrowZeroesTheNewPages;
    procedure TestGrowThatRemapsPreservesContents;
    procedure TestGrowPastMaxFailsWithoutTrapping;
    procedure TestGrowPastTheAddressTypeCeilingFails;
    procedure TestGrowUpdatesTheBoundTheCheckReads;
    procedure TestMemory64Clamps;
  end;

function TRuntimeMemoryTests.MemTypeOf(const AAddrType: TWasmAddrType;
  const AMin: UInt64): TWasmMemType;
begin
  Result := MakeMemType(MakeLimits(AAddrType, AMin));
end;

function TRuntimeMemoryTests.MemTypeWithMax(const AAddrType: TWasmAddrType;
  const AMin, AMax: UInt64): TWasmMemType;
begin
  Result := MakeMemType(MakeLimitsWithMax(AAddrType, AMin, AMax));
end;

function TRuntimeMemoryTests.AccessTraps(var AMem: TWasmMemoryInst;
  const AIndex, AOffset, ASize: UInt64): Boolean;
var
  Address: PByte;
begin
  Result := False;
  try
    Address := MemAddress(AMem, AIndex, AOffset, ASize);
    { Touch nothing: an accepted access is only proof that the check
      accepted it. }
    if Address = nil then
      Result := False;
  except
    on E: EWasmTrap do
    begin
      Result := E.Message = MSG_TRAP_MEMORY_OUT_OF_BOUNDS;
    end;
  end;
end;

function TRuntimeMemoryTests.RangeTraps(var AMem: TWasmMemoryInst;
  const AIndex, ALength: UInt64): Boolean;
var
  Address: PByte;
begin
  Result := False;
  try
    Address := MemRange(AMem, AIndex, ALength);
    if Address = nil then
      Result := False;
  except
    on E: EWasmTrap do
    begin
      Result := E.Message = MSG_TRAP_MEMORY_OUT_OF_BOUNDS;
    end;
  end;
end;

procedure TRuntimeMemoryTests.PokeAndPeek(var AMem: TWasmMemoryInst;
  const AIndex: UInt64; const AValue: Byte);
begin
  MemAddress(AMem, AIndex, 0, 1)^ := AValue;
end;

function TRuntimeMemoryTests.PeekByteAt(var AMem: TWasmMemoryInst;
  const AIndex: UInt64): Byte;
begin
  Result := MemAddress(AMem, AIndex, 0, 1)^;
end;

function TRuntimeMemoryTests.StrategiesAgree(const AAddrType: TWasmAddrType;
  const APages, AIndex, AOffset, ASize: UInt64): Boolean;
var
  Strategy: TWasmMemStrategy;
  Memory: TWasmMemoryInst;
  Seen: Boolean;
  Expected: Boolean;
  Any: Boolean;
begin
  Result := True;
  Any := False;
  Expected := False;
  for Strategy := Low(TWasmMemStrategy) to High(TWasmMemStrategy) do
  begin
    if not MemStrategySupported(Strategy, AAddrType) then
      Continue;
    MemoryInitForTest(Memory, MemTypeOf(AAddrType, APages), Strategy,
      WASM_GUARD_BYTES);
    try
      Seen := AccessTraps(Memory, AIndex, AOffset, ASize);
    finally
      MemoryFree(Memory);
    end;
    if not Any then
    begin
      Expected := Seen;
      Any := True;
    end
    else if Seen <> Expected then
      Result := False;
  end;
end;

function TRuntimeMemoryTests.SupportedStrategyCount(
  const AAddrType: TWasmAddrType): Integer;
var
  Strategy: TWasmMemStrategy;
begin
  Result := 0;
  for Strategy := Low(TWasmMemStrategy) to High(TWasmMemStrategy) do
    if MemStrategySupported(Strategy, AAddrType) then
      Inc(Result);
end;

procedure TRuntimeMemoryTests.TestStrategyMatrix;
begin
  { ADR-0013's matrix, all four cells, decided from (platform, address
    type) alone — never from runtime state and never per tier. }
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  Expect<Boolean>(SelectMemStrategy(watI32) = wmsGuardPages).ToBe(True);
  Expect<Boolean>(SelectMemStrategy(watI64) = wmsGuardAssisted).ToBe(True);
  {$ELSE}
  { 32-bit hosts cannot reserve the address space; Windows can but has no
    SEH filter to convert the access violation this wave. Both take the
    fallback. }
  Expect<Boolean>(SelectMemStrategy(watI32) = wmsBoundsChecked).ToBe(True);
  Expect<Boolean>(SelectMemStrategy(watI64) = wmsBoundsChecked).ToBe(True);
  {$ENDIF}
end;

procedure TRuntimeMemoryTests.TestStrategySupportMatrix;
begin
  { The fallback is always constructible — that is what makes it the
    fallback. }
  Expect<Boolean>(MemStrategySupported(wmsBoundsChecked, watI32)).ToBe(True);
  Expect<Boolean>(MemStrategySupported(wmsBoundsChecked, watI64)).ToBe(True);
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  Expect<Boolean>(MemStrategySupported(wmsGuardPages, watI32)).ToBe(True);
  { No reservation covers an i64 index, so guard pages are not an option
    for one no matter the host. }
  Expect<Boolean>(MemStrategySupported(wmsGuardPages, watI64)).ToBe(False);
  Expect<Boolean>(MemStrategySupported(wmsGuardAssisted, watI64)).ToBe(True);
  {$ELSE}
  Expect<Boolean>(MemStrategySupported(wmsGuardPages, watI32)).ToBe(False);
  Expect<Boolean>(MemStrategySupported(wmsGuardAssisted, watI64)).ToBe(False);
  {$ENDIF}
end;

procedure TRuntimeMemoryTests.TestPageCeilings;
begin
  { 65536 pages is 4 GiB, the same ceiling the validator enforces on the
    declared limit with MSG_MEMORY_SIZE_LIMIT. }
  Expect<UInt64>(MemoryPageCeiling(watI32)).ToBe(65536);
  { UNCONFIRMED upstream: no i64 page bound is served, and ADR-0013
    rejected inventing an embedder-visible cap. The ceiling is therefore
    only the point at which a byte count stops being representable. }
  Expect<UInt64>(MemoryPageCeiling(watI64))
    .ToBe(UInt64($FFFFFFFFFFFFFFFF) div 65536);
end;

procedure TRuntimeMemoryTests.TestNativeMemoryShape;
var
  Memory: TWasmMemoryInst;
begin
  MemoryInit(Memory, MemTypeOf(watI32, 2));
  try
    Expect<Boolean>(Memory.Base <> nil).ToBe(True);
    Expect<UInt64>(Memory.ByteSize).ToBe(2 * 65536);
    Expect<UInt64>(Memory.Pages).ToBe(2);
    Expect<Boolean>(Memory.Strategy = SelectMemStrategy(watI32)).ToBe(True);
    Expect<UInt64>(Memory.Committed).ToBe(2 * 65536);
    { No declared maximum, so the effective maximum is the ceiling. }
    Expect<UInt64>(Memory.MaxPages).ToBe(65536);
    Expect<Boolean>(Memory.HasMax).ToBe(False);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestZeroPageMemoryHasABaseAndTrapsOnAccess;
var
  Memory: TWasmMemoryInst;
begin
  { mmap of zero bytes fails and GetMem(0) may hand back nil; a zero-page
    memory still gets storage so that Base is never nil, which removes a
    nil test from the chokepoint. Every access traps on the check. }
  MemoryInitForTest(Memory, MemTypeOf(watI32, 0), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<Boolean>(Memory.Base <> nil).ToBe(True);
    Expect<UInt64>(Memory.ByteSize).ToBe(0);
    Expect<Boolean>(AccessTraps(Memory, 0, 0, 1)).ToBe(True);
    { A zero-length range at exactly the bound is still in bounds. }
    Expect<Boolean>(RangeTraps(Memory, 0, 0)).ToBe(False);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestBoundIsTheOffByOneTriple;
var
  Memory: TWasmMemoryInst;
  Size: UInt64;
begin
  MemoryInitForTest(Memory, MemTypeOf(watI32, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Size := Memory.ByteSize;
    { The last byte is in. }
    Expect<Boolean>(AccessTraps(Memory, Size - 1, 0, 1)).ToBe(False);
    { The byte after it is not. }
    Expect<Boolean>(AccessTraps(Memory, Size, 0, 1)).ToBe(True);
    { And neither is anything past it. }
    Expect<Boolean>(AccessTraps(Memory, Size + 1, 0, 1)).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestOffsetAndSizeParticipateInTheBound;
var
  Memory: TWasmMemoryInst;
  Size: UInt64;
begin
  MemoryInitForTest(Memory, MemTypeOf(watI32, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Size := Memory.ByteSize;
    { The bound is on the effective address PLUS the access size
      (i32.load: "effective address + access size is outside the memory
      bounds"), so a wide access at an in-bounds index still traps. }
    Expect<Boolean>(AccessTraps(Memory, Size - 8, 0, 8)).ToBe(False);
    Expect<Boolean>(AccessTraps(Memory, Size - 7, 0, 8)).ToBe(True);
    { And the static offset counts the same way. }
    Expect<Boolean>(AccessTraps(Memory, Size - 8, 4, 4)).ToBe(False);
    Expect<Boolean>(AccessTraps(Memory, Size - 8, 5, 4)).ToBe(True);
    Expect<Boolean>(AccessTraps(Memory, 0, Size, 1)).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestOverflowFormsCannotWrapIntoRange;
var
  Memory: TWasmMemoryInst;
begin
  { An i64 memory is where the naive comparison breaks. Every case below
    passes `AIndex + AOffset + ASize > ByteSize` only because the sum
    wraps; each must trap. }
  MemoryInitForTest(Memory, MemTypeOf(watI64, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    { index + offset + size wraps to a small in-range value. }
    Expect<Boolean>(AccessTraps(Memory, High(UInt64) - 3, 8, 4)).ToBe(True);
    { index alone at the top of the space. }
    Expect<Boolean>(AccessTraps(Memory, High(UInt64), 0, 1)).ToBe(True);
    { A u64 static offset: the encoding allows it and the validator does
      not bound it, so offset + size can overflow on its own. }
    Expect<Boolean>(AccessTraps(Memory, 0, High(UInt64), 1)).ToBe(True);
    Expect<Boolean>(AccessTraps(Memory, 8, High(UInt64) - 4, 8)).ToBe(True);
    { And a range whose length wraps past the end. }
    Expect<Boolean>(RangeTraps(Memory, 16, High(UInt64))).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestRangeChecksTheWholeSpan;
var
  Memory: TWasmMemoryInst;
  Size: UInt64;
begin
  MemoryInitForTest(Memory, MemTypeOf(watI32, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Size := Memory.ByteSize;
    Expect<Boolean>(RangeTraps(Memory, 0, Size)).ToBe(False);
    Expect<Boolean>(RangeTraps(Memory, 1, Size)).ToBe(True);
    { memory.fill and memory.copy accept a zero length at the very end. }
    Expect<Boolean>(RangeTraps(Memory, Size, 0)).ToBe(False);
    Expect<Boolean>(RangeTraps(Memory, Size, 1)).ToBe(True);
    Expect<Boolean>(RangeTraps(Memory, Size + 1, 0)).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestRoundTripThroughTheChokepoint;
var
  Memory: TWasmMemoryInst;
begin
  MemoryInit(Memory, MemTypeOf(watI32, 1));
  try
    { A fresh memory reads as zero. }
    Expect<Integer>(PeekByteAt(Memory, 0)).ToBe(0);
    PokeAndPeek(Memory, 0, 42);
    PokeAndPeek(Memory, Memory.ByteSize - 1, 7);
    Expect<Integer>(PeekByteAt(Memory, 0)).ToBe(42);
    Expect<Integer>(PeekByteAt(Memory, Memory.ByteSize - 1)).ToBe(7);
    { The static offset lands where it should. }
    Expect<Integer>(MemAddress(Memory, 0, Memory.ByteSize - 1, 1)^).ToBe(7);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestLargeStaticOffsetFallsThroughToAFullCheck;
var
  Memory: TWasmMemoryInst;
begin
  { The hole the design found: a memarg offset is u64 in the 3.0
    encoding, so index and offset together can reach past even a 4 + 2
    GiB reservation. An offset above the fold threshold must therefore
    take the full-precision check under EVERY strategy, guard pages
    included — otherwise this access would compute an address outside
    the mapping, where a fault is not ours to claim. }
  MemoryInit(Memory, MemTypeOf(watI32, 1));
  try
    Expect<Boolean>(AccessTraps(Memory, 0, WASM_STATIC_OFFSET_FOLD + 1, 1))
      .ToBe(True);
    Expect<Boolean>(AccessTraps(Memory, 0, High(UInt64), 1)).ToBe(True);
    { Below the threshold the offset folds into the guard and the access
      is taken without a check, so an in-bounds one still works. }
    Expect<Boolean>(AccessTraps(Memory, 0, 8, 4)).ToBe(False);
  finally
    MemoryFree(Memory);
  end;

  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  MemoryInitForTest(Memory, MemTypeOf(watI64, 1), wmsGuardAssisted,
    WASM_GUARD_BYTES);
  try
    Expect<Boolean>(AccessTraps(Memory, 0, WASM_STATIC_OFFSET_FOLD + 1, 1))
      .ToBe(True);
    { Below the threshold the guard absorbs the offset and only the index
      is compared, which is the point of the strategy. }
    Expect<Boolean>(AccessTraps(Memory, Memory.ByteSize, 0, 1)).ToBe(True);
    Expect<Boolean>(AccessTraps(Memory, Memory.ByteSize - 1, 0, 1))
      .ToBe(False);
  finally
    MemoryFree(Memory);
  end;
  {$ENDIF}
end;

procedure TRuntimeMemoryTests.TestGuardFoldAccountsForAccessWidth;
var
  Memory: TWasmMemoryInst;
begin
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  { H1, the escape case. The maximum i32 index (2^32-1) with an offset
    equal to the guard and an 8-byte access reaches the last reserved byte
    and then 7 bytes past it — outside every mapping, where a fault is not
    ours to claim. The fold decision must be WIDTH-aware and CHECK this
    access rather than fold it; the check then traps because the index is
    far outside the 1-page declared memory. Under the old
    `AOffset > WASM_STATIC_OFFSET_FOLD` fold this access was silently
    folded. }
  MemoryInit(Memory, MemTypeOf(watI32, 1));
  try
    Expect<Boolean>(AccessTraps(Memory, UInt64($FFFFFFFF),
      WASM_STATIC_OFFSET_FOLD, 8)).ToBe(True);
    { Exactly one access width below the guard still folds: offset + size
      = guard, so the address stays inside the reservation and is left to
      the MMU — no explicit trap is raised here. }
    Expect<Boolean>(AccessTraps(Memory, 0,
      WASM_STATIC_OFFSET_FOLD - 8, 8)).ToBe(False);
  finally
    MemoryFree(Memory);
  end;

  { The guard-assisted arm shares the same width-aware boundary: an
    in-bounds index with offset == guard must be checked and trap. }
  MemoryInitForTest(Memory, MemTypeOf(watI64, 1), wmsGuardAssisted,
    WASM_GUARD_BYTES);
  try
    Expect<Boolean>(AccessTraps(Memory, Memory.ByteSize - 1,
      WASM_STATIC_OFFSET_FOLD, 8)).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
  {$ELSE}
  { No guard strategy here: the bounds-checked arm already checks the width
    at every access, so the escape never existed. The boundary case still
    traps out of a 1-page memory. }
  MemoryInitForTest(Memory, MemTypeOf(watI32, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<Boolean>(AccessTraps(Memory, UInt64($FFFFFFFF),
      WASM_STATIC_OFFSET_FOLD, 8)).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
  {$ENDIF}
end;

procedure TRuntimeMemoryTests.TestFoldUsesTheInstanceGuardNotTheConstant;
{$IF DEFINED(UNIX) AND DEFINED(CPU64)}
const
  SmallGuard = UInt64(128) * 1024;   { far below WASM_STATIC_OFFSET_FOLD }
var
  Memory: TWasmMemoryInst;
begin
  { Fix 2: the fold decision must read AMem.GuardBytes, not the
    WASM_STATIC_OFFSET_FOLD constant. With the guard shrunk to 128 KiB an
    offset equal to that guard is ABOVE the width-aware fold threshold and
    must take the full-precision check and trap. Folding against the 2 GiB
    constant instead would wrongly fold it and let it pass — this test
    fails against the pre-fix code. }
  MemoryInitForTest(Memory, MemTypeOf(watI64, 1), wmsGuardAssisted,
    SmallGuard);
  try
    Expect<UInt64>(Memory.GuardBytes).ToBe(SmallGuard);
    Expect<Boolean>(AccessTraps(Memory, 0, SmallGuard, 8)).ToBe(True);
    { One access width below the shrunk guard folds: only the index is
      checked, and index 0 is in bounds, so no explicit trap. }
    Expect<Boolean>(AccessTraps(Memory, 0, SmallGuard - 16, 8)).ToBe(False);
  finally
    MemoryFree(Memory);
  end;
end;
{$ELSE}
begin
  { No guard strategy on this platform; nothing folds. }
  Expect<Boolean>(True).ToBe(True);
end;
{$ENDIF}

procedure TRuntimeMemoryTests.TestGuardFaultTrapsInAForkedChild;
{$IF DEFINED(UNIX) AND DEFINED(CPU64)}
var
  Memory: TWasmMemoryInst;
  Pid: TPid;
  Status: cint;
  ExitedNormally: Boolean;
  ExitCode: Integer;
  Trapped: Boolean;
begin
  { The outstanding debt (both suite headers name it): prove the WHOLE
    fault path — a real SIGSEGV inside a WasmInvoke, attributed through the
    reservation registry, converted into one EWasmTrap by the handler and
    trampoline. It cannot run in-process: a wrong handler kills the runner
    with no diagnostic. So it runs in a forked CHILD and the parent asserts
    the child TRAPPED and exited 0, rather than dying by signal. Only on
    the guard platform, which is the only place the fault path exists. }
  MemoryInit(Memory, MemTypeOf(watI32, 1));
  try
    Pid := FpFork;
    if Pid = 0 then
    begin
      { Child. Distinct exit codes make a failure legible; _exit, never
        Halt. }
      Trapped := False;
      try
        WasmInvoke(GuestOobWrite, @Memory);
      except
        on E: EWasmTrap do
          Trapped := E.Message = MSG_TRAP_MEMORY_OUT_OF_BOUNDS;
        on E: Exception do
          ChildExit(3);   { converted, but wrong class or message }
      end;
      if Trapped then
        ChildExit(0)      { faulted and trapped cleanly }
      else
        ChildExit(4);     { WasmInvoke returned without trapping }
    end;

    { Parent. }
    Expect<Boolean>(Pid > 0).ToBe(True);
    if Pid > 0 then
    begin
      Status := 0;
      FpWaitPid(Pid, @Status, 0);
      { Decode the wait status directly rather than via the RTL macros,
        whose spelling and return type vary: the low 7 bits are the
        terminating signal (0 on a normal exit) and the next byte is the
        exit code. A child killed by an unconverted SIGSEGV shows a nonzero
        signal here — which is exactly the regression this guards. }
      ExitedNormally := (Status and $7F) = 0;
      ExitCode := (Status shr 8) and $FF;
      Expect<Boolean>(ExitedNormally).ToBe(True);
      Expect<Integer>(ExitCode).ToBe(0);
    end;
  finally
    MemoryFree(Memory);
  end;
end;
{$ELSE}
begin
  { No guard strategy here: no MMU fault path to exercise. The
    bounds-checked arm's trapping is covered by the off-by-one tests. }
  Expect<Boolean>(True).ToBe(True);
end;
{$ENDIF}

procedure TRuntimeMemoryTests.TestStrategiesTrapIdentically;
begin
  { ADR-0005 and ADR-0010: a module traps at the same access under every
    strategy. Only accesses that every strategy CHECKS can be compared
    here — an out-of-bounds access on a guard-page memory is meant to
    fault, and the fault path is not yet safe to exercise in-process. A
    static offset above the fold threshold is checked by all three, so it
    is the case that covers guard pages too. }
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  { L4: the comparison is only meaningful with more than one strategy. On
    the guard platform an i32 memory has guard-pages plus bounds-checked
    and an i64 memory has guard-assisted plus bounds-checked — assert the
    test is not silently vacuous. (A single-strategy host has nothing to
    compare, which is inherent, not a test defect.) }
  Expect<Boolean>(SupportedStrategyCount(watI32) >= 2).ToBe(True);
  Expect<Boolean>(SupportedStrategyCount(watI64) >= 2).ToBe(True);
  {$ENDIF}
  Expect<Boolean>(StrategiesAgree(watI32, 1, 0,
    WASM_STATIC_OFFSET_FOLD + 1, 1)).ToBe(True);
  Expect<Boolean>(StrategiesAgree(watI32, 1, 0, High(UInt64), 4)).ToBe(True);
  { In-bounds accesses must agree as well: identical means identical in
    both directions. }
  Expect<Boolean>(StrategiesAgree(watI32, 1, 0, 0, 4)).ToBe(True);
  Expect<Boolean>(StrategiesAgree(watI32, 1, 65532, 0, 4)).ToBe(True);
  { i64 memories: guard-assisted and bounds-checked both check the index
    itself, so the bound is comparable directly. }
  Expect<Boolean>(StrategiesAgree(watI64, 1, 65536, 0, 1)).ToBe(True);
  Expect<Boolean>(StrategiesAgree(watI64, 1, 65535, 0, 1)).ToBe(True);
end;

procedure TRuntimeMemoryTests.TestGuardReservationIsRegistered;
var
  Memory: TWasmMemoryInst;
  Base: NativeUInt;
begin
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  MemoryInit(Memory, MemTypeOf(watI32, 1));
  try
    Base := NativeUInt(Memory.Base);
    { 4 GiB for every address an i32 index can name, plus the guard that
      absorbs the static offset. }
    Expect<UInt64>(Memory.ReserveBytes)
      .ToBe(WASM_I32_RESERVE_BYTES + WASM_GUARD_BYTES);
    { Only the live pages are readable and writable. The rest of the
      reservation is PROT_NONE and is deliberately never dereferenced
      here: without a proven handler, touching it would kill the runner
      instead of failing a test. }
    Expect<UInt64>(Memory.Committed).ToBe(65536);
    Expect<Boolean>(Memory.Committed < Memory.ReserveBytes).ToBe(True);

    { The registry is the handler's only way to decide a fault is ours,
      so its ends have to be exact. }
    Expect<Boolean>(ReservationContains(Memory.Base)).ToBe(True);
    Expect<Boolean>(ReservationContains(
      Pointer(Base + NativeUInt(Memory.ByteSize)))).ToBe(True);
    Expect<Boolean>(ReservationContains(
      Pointer(Base + NativeUInt(Memory.ReserveBytes) - 1))).ToBe(True);
    Expect<Boolean>(ReservationContains(
      Pointer(Base + NativeUInt(Memory.ReserveBytes)))).ToBe(False);
    { A guard-strategy memory is what triggers handler installation. }
    Expect<Boolean>(FaultHandlerInstalled).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
  {$ELSE}
  { No guard strategy on this platform, so there is nothing to attribute
    and nothing to register. }
  MemoryInit(Memory, MemTypeOf(watI32, 1));
  try
    Base := NativeUInt(Memory.Base);
    Expect<Boolean>(ReservationContains(Pointer(Base))).ToBe(False);
  finally
    MemoryFree(Memory);
  end;
  {$ENDIF}
end;

procedure TRuntimeMemoryTests.TestBoundsCheckedMemoryIsNotRegistered;
var
  Memory: TWasmMemoryInst;
  Live: Integer;
begin
  { Registering a heap block would claim addresses the host legitimately
    owns, and a bounds-checked memory never faults by design. }
  Live := ReservationLiveCount;
  MemoryInitForTest(Memory, MemTypeOf(watI32, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<Integer>(ReservationLiveCount).ToBe(Live);
    Expect<Boolean>(ReservationContains(Memory.Base)).ToBe(False);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestFreeDeregistersBeforeUnmapping;
var
  Memory: TWasmMemoryInst;
  Base: Pointer;
  Live: Integer;
begin
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  Live := ReservationLiveCount;
  MemoryInit(Memory, MemTypeOf(watI64, 1));
  Base := Memory.ReserveBase;
  Expect<Integer>(ReservationLiveCount).ToBe(Live + 1);
  MemoryFree(Memory);
  { The address may be handed straight back out by the next mmap; a
    lingering entry would attribute an unrelated fault to us. }
  Expect<Boolean>(ReservationContains(Base)).ToBe(False);
  Expect<Integer>(ReservationLiveCount).ToBe(Live);
  Expect<Boolean>(Memory.Base = nil).ToBe(True);
  {$ELSE}
  Live := ReservationLiveCount;
  MemoryInit(Memory, MemTypeOf(watI64, 1));
  Base := Memory.ReserveBase;
  MemoryFree(Memory);
  Expect<Boolean>(ReservationContains(Base)).ToBe(False);
  Expect<Integer>(ReservationLiveCount).ToBe(Live);
  Expect<Boolean>(Memory.Base = nil).ToBe(True);
  {$ENDIF}
end;

procedure TRuntimeMemoryTests.TestGrowInPlacePreservesContents;
var
  Memory: TWasmMemoryInst;
  Strategy: TWasmMemStrategy;
  Grown: Int64;
begin
  for Strategy := Low(TWasmMemStrategy) to High(TWasmMemStrategy) do
  begin
    if not MemStrategySupported(Strategy, watI32) then
      Continue;
    MemoryInitForTest(Memory, MemTypeOf(watI32, 1), Strategy,
      WASM_GUARD_BYTES);
    try
      PokeAndPeek(Memory, 0, 99);
      PokeAndPeek(Memory, 65535, 11);
      Grown := MemoryGrow(Memory, 1);
      { memory.grow returns the PREVIOUS size in pages. }
      Expect<Int64>(Grown).ToBe(1);
      Expect<UInt64>(Memory.Pages).ToBe(2);
      Expect<UInt64>(Memory.ByteSize).ToBe(2 * 65536);
      Expect<Integer>(PeekByteAt(Memory, 0)).ToBe(99);
      Expect<Integer>(PeekByteAt(Memory, 65535)).ToBe(11);
      { The new page is reachable through the chokepoint now. }
      Expect<Boolean>(AccessTraps(Memory, 65536, 0, 1)).ToBe(False);
    finally
      MemoryFree(Memory);
    end;
  end;
end;

procedure TRuntimeMemoryTests.TestGrowZeroesTheNewPages;
var
  Memory: TWasmMemoryInst;
  Strategy: TWasmMemStrategy;
begin
  for Strategy := Low(TWasmMemStrategy) to High(TWasmMemStrategy) do
  begin
    if not MemStrategySupported(Strategy, watI32) then
      Continue;
    MemoryInitForTest(Memory, MemTypeOf(watI32, 1), Strategy,
      WASM_GUARD_BYTES);
    try
      { A kernel mapping arrives zeroed; the heap does not, so the
        bounds-checked path has to do it by hand. }
      MemoryGrow(Memory, 1);
      Expect<Integer>(PeekByteAt(Memory, 65536)).ToBe(0);
      Expect<Integer>(PeekByteAt(Memory, 131071)).ToBe(0);
    finally
      MemoryFree(Memory);
    end;
  end;
end;

procedure TRuntimeMemoryTests.TestGrowThatRemapsPreservesContents;
var
  Memory: TWasmMemoryInst;
  OldBase: Pointer;
  OldReserve: Pointer;
begin
  {$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  { A guard-assisted memory reserves current size plus guard, so growing
    past the guard forces a remap. The guard is shrunk here so the path
    is reachable without committing gigabytes — TEST ONLY, and safe
    because no access below uses a large static offset. }
  MemoryInitForTest(Memory, MemTypeOf(watI64, 1), wmsGuardAssisted,
    128 * 1024);
  try
    PokeAndPeek(Memory, 0, 55);
    PokeAndPeek(Memory, 65535, 66);
    OldBase := Memory.Base;
    OldReserve := Memory.ReserveBase;

    Expect<Int64>(MemoryGrow(Memory, 2)).ToBe(1);
    Expect<UInt64>(Memory.ByteSize).ToBe(3 * 65536);
    { ADR-0013: "the bound is loaded from the instance, so a moved memory
      is transparent to the check". The memory really did move. }
    Expect<Boolean>(Memory.Base <> OldBase).ToBe(True);
    Expect<Integer>(PeekByteAt(Memory, 0)).ToBe(55);
    Expect<Integer>(PeekByteAt(Memory, 65535)).ToBe(66);
    Expect<Integer>(PeekByteAt(Memory, 131072)).ToBe(0);

    { The old reservation must be gone from the registry before it was
      unmapped, and the new one must be in it. }
    Expect<Boolean>(ReservationContains(OldReserve)).ToBe(False);
    Expect<Boolean>(ReservationContains(Memory.ReserveBase)).ToBe(True);
    Expect<UInt64>(Memory.ReserveBytes).ToBe(3 * 65536 + 128 * 1024);
  finally
    MemoryFree(Memory);
  end;
  {$ELSE}
  { The bounds-checked path reallocates, which may equally move the
    block; the observable contract is the same. }
  MemoryInitForTest(Memory, MemTypeOf(watI64, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    PokeAndPeek(Memory, 0, 55);
    PokeAndPeek(Memory, 65535, 66);
    OldBase := Memory.Base;
    OldReserve := Memory.ReserveBase;
    Expect<Int64>(MemoryGrow(Memory, 2)).ToBe(1);
    Expect<UInt64>(Memory.ByteSize).ToBe(3 * 65536);
    Expect<Integer>(PeekByteAt(Memory, 0)).ToBe(55);
    Expect<Integer>(PeekByteAt(Memory, 65535)).ToBe(66);
    Expect<Integer>(PeekByteAt(Memory, 131072)).ToBe(0);
    Expect<Boolean>(OldBase = OldReserve).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
  {$ENDIF}
end;

procedure TRuntimeMemoryTests.TestGrowPastMaxFailsWithoutTrapping;
var
  Memory: TWasmMemoryInst;
begin
  MemoryInitForTest(Memory, MemTypeWithMax(watI32, 1, 2), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<UInt64>(Memory.MaxPages).ToBe(2);
    { exec-memory.grow reports can_trap:false — growth FAILS, it does not
      trap, and a failed grow must leave the memory exactly as it was. }
    Expect<Int64>(MemoryGrow(Memory, 2)).ToBe(-1);
    Expect<UInt64>(Memory.Pages).ToBe(1);
    Expect<UInt64>(Memory.ByteSize).ToBe(65536);
    Expect<Int64>(MemoryGrow(Memory, 1)).ToBe(1);
    Expect<Int64>(MemoryGrow(Memory, 1)).ToBe(-1);
    Expect<UInt64>(Memory.Pages).ToBe(2);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestGrowPastTheAddressTypeCeilingFails;
var
  Memory: TWasmMemoryInst;
begin
  { With no declared maximum the ceiling is the address type's own, and
    an i32 memory stops at 65536 pages. }
  MemoryInitForTest(Memory, MemTypeOf(watI32, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<Int64>(MemoryGrow(Memory, 65536)).ToBe(-1);
    Expect<UInt64>(Memory.Pages).ToBe(1);
    { The delta itself is a u64 and must not wrap the ceiling test. }
    Expect<Int64>(MemoryGrow(Memory, High(UInt64))).ToBe(-1);
    Expect<UInt64>(Memory.Pages).ToBe(1);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestGrowUpdatesTheBoundTheCheckReads;
var
  Memory: TWasmMemoryInst;
begin
  MemoryInitForTest(Memory, MemTypeOf(watI32, 1), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<Boolean>(AccessTraps(Memory, 65536, 0, 1)).ToBe(True);
    MemoryGrow(Memory, 1);
    { Tier contract MEM-1 exists because of exactly this: anything that
      cached the bound across the grow is now wrong. }
    Expect<Boolean>(AccessTraps(Memory, 65536, 0, 1)).ToBe(False);
    Expect<Boolean>(AccessTraps(Memory, 131072, 0, 1)).ToBe(True);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.TestMemory64Clamps;
var
  Memory: TWasmMemoryInst;
begin
  { The effective maximum is min(declared, ceiling), computed once. }
  MemoryInitForTest(Memory, MemTypeWithMax(watI32, 0, 10), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<UInt64>(Memory.MaxPages).ToBe(10);
    Expect<Boolean>(Memory.HasMax).ToBe(True);
  finally
    MemoryFree(Memory);
  end;

  { A declared maximum above the i32 ceiling is clamped to it. }
  MemoryInitForTest(Memory, MemTypeWithMax(watI32, 0, 1000000),
    wmsBoundsChecked, WASM_GUARD_BYTES);
  try
    Expect<UInt64>(Memory.MaxPages).ToBe(65536);
  finally
    MemoryFree(Memory);
  end;

  { An i64 memory with no declared maximum gets no invented cap —
    ADR-0013 rejected an embedder-visible size cap riding in on a
    bounds-check optimisation, so only the representable ceiling and the
    allocator's own failure bound it. }
  MemoryInitForTest(Memory, MemTypeOf(watI64, 0), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<UInt64>(Memory.MaxPages).ToBe(MemoryPageCeiling(watI64));
    Expect<Boolean>(Memory.AddrType = watI64).ToBe(True);
  finally
    MemoryFree(Memory);
  end;

  { A declared i64 maximum is honoured as-is. }
  MemoryInitForTest(Memory, MemTypeWithMax(watI64, 1, 4), wmsBoundsChecked,
    WASM_GUARD_BYTES);
  try
    Expect<UInt64>(Memory.MaxPages).ToBe(4);
    Expect<Int64>(MemoryGrow(Memory, 4)).ToBe(-1);
    Expect<Int64>(MemoryGrow(Memory, 3)).ToBe(1);
  finally
    MemoryFree(Memory);
  end;
end;

procedure TRuntimeMemoryTests.SetupTests;
begin
  Test('the strategy matrix is decided by platform and address type',
    TestStrategyMatrix);
  Test('only the strategies this platform can build are supported',
    TestStrategySupportMatrix);
  Test('page ceilings per address type', TestPageCeilings);
  Test('a native memory has the shape the strategy implies',
    TestNativeMemoryShape);
  Test('a zero-page memory has a base and traps on every access',
    TestZeroPageMemoryHasABaseAndTrapsOnAccess);
  Test('the bound is the off-by-one triple', TestBoundIsTheOffByOneTriple);
  Test('the static offset and access size participate in the bound',
    TestOffsetAndSizeParticipateInTheBound);
  Test('no overflow form wraps an out-of-bounds access into range',
    TestOverflowFormsCannotWrapIntoRange);
  Test('a range check covers the whole span', TestRangeChecksTheWholeSpan);
  Test('bytes round-trip through the chokepoint',
    TestRoundTripThroughTheChokepoint);
  Test('a static offset above the fold takes a full-precision check',
    TestLargeStaticOffsetFallsThroughToAFullCheck);
  Test('the guard fold accounts for the access width at the reservation top',
    TestGuardFoldAccountsForAccessWidth);
  Test('the fold decision reads the instance guard, not the constant',
    TestFoldUsesTheInstanceGuardNotTheConstant);
  Test('a real guard fault traps cleanly in a forked child',
    TestGuardFaultTrapsInAForkedChild);
  Test('every strategy traps at the same access',
    TestStrategiesTrapIdentically);
  Test('a guard reservation is registered for fault attribution',
    TestGuardReservationIsRegistered);
  Test('a bounds-checked memory is never registered',
    TestBoundsCheckedMemoryIsNotRegistered);
  Test('freeing deregisters before unmapping',
    TestFreeDeregistersBeforeUnmapping);
  Test('growth in place preserves contents',
    TestGrowInPlacePreservesContents);
  Test('growth zeroes the new pages', TestGrowZeroesTheNewPages);
  Test('growth that remaps preserves contents',
    TestGrowThatRemapsPreservesContents);
  Test('growth past the maximum fails without trapping',
    TestGrowPastMaxFailsWithoutTrapping);
  Test('growth past the address type ceiling fails',
    TestGrowPastTheAddressTypeCeilingFails);
  Test('growth updates the bound the check reads',
    TestGrowUpdatesTheBoundTheCheckReads);
  Test('memory64 limits are clamped once at creation',
    TestMemory64Clamps);
end;

begin
  TestRunnerProgram.AddSuite(TRuntimeMemoryTests.Create('Wasm.Runtime.Memory'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
