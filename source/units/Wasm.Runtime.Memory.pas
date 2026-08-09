{ Wasm.Runtime.Memory — linear memory and THE memory-access chokepoint.

  ADR-0005: "a new caller that bypasses the chokepoint is the failure
  mode this design is most exposed to." Every consumer — the interpreter,
  the JIT's runtime helpers, host byte accessors, memory.init /
  memory.copy / memory.fill, array.new_data, the embedding API, the
  .wast runner — goes through MemAddress / MemRange / MemCheck and
  nothing else.

  The strategy is chosen STATICALLY, per memory, from (platform, address
  type) and nothing else (ADR-0013). Never from runtime state, never per
  tier: an AOT artifact bakes the access sequence in, so it must be
  derivable from the module alone.

                  | 64-bit POSIX             | 32-bit host / Windows
      i32 memory  | guard pages, no check    | explicit checks
      i64 memory  | guard-assisted checks    | explicit checks + index
                  |                          | width reduction

  STAGING DECISION — Windows takes explicit bounds checks in this wave,
  on every memory, regardless of bitness. Windows can reserve the address
  space; what it cannot do without an SEH filter is turn the resulting
  access violation into a trap, and ADR-0009's Windows leg is unbuilt.
  Shipping guard pages there first would crash the process instead of
  trapping. This is deliberate, temporary, and observationally invisible
  — both strategies must trap identically (ADR-0005, ADR-0010), so a
  Windows build differs from a POSIX one only in speed. Revisit when the
  trap path grows its SEH filter: the change is one line in
  SelectMemStrategy.

  Deliberate deviations from the design contract, both recorded rather
  than discovered later:

  - wmsBoundsChecked allocates from the heap (GetMem/ReAllocMem) on every
    platform rather than mmap on POSIX and VirtualAlloc on Windows. The
    checked path never reads past the bound, so the allocation only has
    to be readable, writable, and growable; one portable path is cheaper
    to keep correct than three. ADR-0013 classes reservation policy as a
    tuned implementation constant.
  - Growth of a guard-assisted memory that outgrows its reservation
    remaps by mmap-copy-munmap on every POSIX target, including Linux
    where mremap would avoid the copy. mremap is an optimisation behind
    a wasmbench number, per the RTL policy, not a correctness question.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004).
  Anchors: page-size (memory instances, page size 64Ki), i32.load
  (`out of bounds memory access`), memory.grow (can_trap:false — it
  returns -1, it does not trap), syntax-memtype, syntax-limits,
  syntax-addrtype. }
unit Wasm.Runtime.Memory;

{$I Shared.inc}

{ WASM_GUARD_STRATEGIES is defined centrally in Shared.inc — guard
  strategies exist only on a 64-bit UNIX host; everything else takes
  explicit checks. BaseUnix is needed only for the mmap/mprotect calls
  those strategies make, so it is imported under the same symbol. }

interface

uses
  SysUtils,
  {$IFDEF WASM_GUARD_STRATEGIES}
  BaseUnix,
  {$ENDIF}
  Wasm.Core,
  Wasm.Runtime.Traps;

type
  TWasmMemStrategy = (
    { i32 memory on 64-bit POSIX: the reservation covers every address an
      i32 index can name, so a fixed-width access compiles to the load or
      store and nothing else. }
    wmsGuardPages,
    { i64 memory on 64-bit POSIX: the index is always checked, but a
      static offset no larger than the guard folds into an
      offset-INDEPENDENT compare that many accesses can share. }
    wmsGuardAssisted,
    { 32-bit hosts, and Windows this wave: unconditional full-precision
      check, plus an index-width reduction for i64 memories. }
    wmsBoundsChecked
  );

const
  { "The length of the sequence always is a multiple of the WebAssembly
    page size, which is defined to be the constant 64Ki" (page-size). }
  WASM_PAGE_SIZE = 65536;

  { 4 GiB. The validator already enforces the DECLARED limit with
    MSG_MEMORY_SIZE_LIMIT; this is the runtime re-deriving the ceiling
    memory.grow has to respect. }
  WASM_MAX_I32_PAGES = 65536;

  { UNCONFIRMED — the numeric page ceiling for an i64-addressed memory.
    syntax-memtype says only that "the limits are given in units of page
    size" and syntax-limits that an absent maximum lets storage "grow to
    any valid size"; the served text gives no i64 bound, and
    Wasm.Validator.Types already carries the same item as unconfirmed.
    ADR-0013 explicitly REJECTED an implementation-defined cap ("an
    embedder-visible size cap is a public-contract decision that must not
    ride in on a bounds-check optimisation"), so no policy cap is
    invented here: this is the arithmetic ceiling at which a byte count
    stops being representable, and everything below it is left to the
    declared maximum and to the allocator's own failure. }
  WASM_MAX_I64_PAGES = UInt64($FFFFFFFFFFFFFFFF) div WASM_PAGE_SIZE;

  { Named tunables. ADR-0013: guard size, reservation policy, and the
    offset threshold above which an access gets a full-precision check
    are implementation constants tuned by wasmbench, deliberately not
    pinned by the ADR. }
  WASM_GUARD_BYTES = UInt64(2) * 1024 * 1024 * 1024;
  WASM_I32_RESERVE_BYTES = UInt64(4) * 1024 * 1024 * 1024;

  { The widest single access the runtime performs: a v128 load/store
    (Track G). The fold decision subtracts this from the guard so an
    access whose TOP could reach past the guard region is fully checked
    rather than trusted to the MMU — see MemCheck. }
  WASM_MAX_ACCESS_WIDTH = 16;

  { The nominal fold threshold, DEFINED as the guard size rather than
    written out again so changing the guard cannot leave a second constant
    stale. A memarg offset is u64 in the 3.0 encoding and the validator
    does not bound it, so a large offset falls through to the
    full-precision check under every strategy — including guard pages,
    where index and offset could otherwise reach past the reservation
    together.

    NOTE as of Track C Wave 6b the helper MemCheck no longer folds at all:
    it does a full-precision explicit check on every strategy (see MemCheck
    for why the guard-page fold was deferred to a future JIT tier). This
    constant, the per-instance GuardBytes field, and the guard reservation
    survive as the sizing and latent capability that a JIT-emitted inline
    no-check access will use; it remains the human-readable boundary and
    the value tests use to construct an offset well past a one-page
    memory. The former H1 bug — a wide access at the maximum i32 index and
    an offset equal to the guard reaching past the reservation — cannot
    recur through this helper, because the explicit check now precedes
    every dereference. }
  WASM_STATIC_OFFSET_FOLD = WASM_GUARD_BYTES;

type
  { Base and ByteSize are first and adjacent because every access reads
    both, and ADR-0013 requires the bound to be loaded from the instance
    so that a moved memory is transparent to the check.

    Tier contract MEM-1. Base and ByteSize may be cached only within a
    straight-line region containing no call, no memory.grow, and no
    safepoint. Every such region reloads both on entry. This is the
    single most likely miscompile in Tracks E, I and J. }
  TWasmMemoryInst = record
    { Byte 0 of the accessible region. Never nil, even for a zero-page
      memory — which removes a nil test from the chokepoint. }
    Base: PByte;
    ByteSize: UInt64;

    Strategy: TWasmMemStrategy;
    AddrType: TWasmAddrType;
    Pages: UInt64;
    { Effective maximum: min(declared max when present, ceiling for the
      address type). Computed once at creation and never recomputed. }
    MaxPages: UInt64;
    HasMax: Boolean;

    { What to unmap or free. Equal to Base today, kept separate so a
      future strategy that offsets the accessible region from the
      mapping's start does not have to rediscover the base. }
    ReserveBase: Pointer;
    ReserveBytes: UInt64;
    { Bytes currently readable and writable under a guard strategy. }
    Committed: UInt64;
    { The guard region this memory was reserved with. A field rather than
      the constant so a test can shrink it; production callers always get
      WASM_GUARD_BYTES. }
    GuardBytes: UInt64;
  end;

  PWasmMemoryInst = ^TWasmMemoryInst;

{ The strategy matrix, in one place. }
function SelectMemStrategy(const AAddrType: TWasmAddrType): TWasmMemStrategy;

{ True when this build can construct AStrategy for AAddrType at all.
  Guard strategies need both a 64-bit POSIX host and, for guard pages, an
  i32 address type. }
function MemStrategySupported(const AStrategy: TWasmMemStrategy;
  const AAddrType: TWasmAddrType): Boolean;

{ The ceiling memory.grow enforces for an address type, before the
  declared maximum is applied. }
function MemoryPageCeiling(const AAddrType: TWasmAddrType): UInt64;

{ Allocate a memory for AType, with the strategy the matrix selects.
  Raises EWasmError if the host cannot provide the storage — a resource
  failure is neither a decode, validation, link, nor trap condition. }
procedure MemoryInit(out AMem: TWasmMemoryInst; const AType: TWasmMemType);

{ TEST-ONLY. Forces the strategy and the reservation's guard size, so
  that one access sequence can be replayed under every strategy the host
  supports (ADR-0005's identity requirement, made executable) and so that
  the guard-assisted remap path is reachable without committing gigabytes.

  Because MemCheck folds against AMem.GuardBytes (this argument), not the
  WASM_STATIC_OFFSET_FOLD constant, shrinking AGuardBytes is SOUND: fewer
  offsets fold, but no folded access can reach past the reservation, which
  is always current-reach + GuardBytes. The one hard floor is
  WASM_MAX_ACCESS_WIDTH, so that `GuardBytes - ASize` in the fold decision
  never underflows; MemoryInitForTest asserts it. }
procedure MemoryInitForTest(out AMem: TWasmMemoryInst;
  const AType: TWasmMemType; const AStrategy: TWasmMemStrategy;
  const AGuardBytes: UInt64);

procedure MemoryFree(var AMem: TWasmMemoryInst);

{ memory.grow: returns the previous size in pages, or -1 on failure.
  `exec-memory.grow` reports can_trap:false — growth FAILS, it does not
  trap, and a failed grow leaves the memory exactly as it was.

  Growth must not run the collector. Linear memory is not GC heap. }
function MemoryGrow(var AMem: TWasmMemoryInst; const ADelta: UInt64): Int64;

{ --- the chokepoint --------------------------------------------------

  AIndex arrives already widened to u64: the caller knows the address
  type statically. AOffset is the static offset immediate, u64 in the
  3.0 encoding. ASize is the access width in bytes (1/2/4/8/16).

  The comparison form is mandatory and is NOT the naive one. Writing
  `AIndex + AOffset + ASize > ByteSize` wraps for a large index on an i64
  memory and admits an out-of-bounds access; even the subtracting form
  `AOffset + ASize > ByteSize - AIndex` can overflow its left side,
  because a memarg offset is u64-encoded and the validator does not bound
  it. MemInBounds below subtracts twice and adds nothing, so no
  intermediate can wrap at any index, offset, or size. }

function MemAddress(var AMem: TWasmMemoryInst;
  const AIndex, AOffset: UInt64; const ASize: UInt64): PByte; inline;

{ Range form for the bulk operations. Traps unless the WHOLE range is in
  bounds, and — unlike MemAddress — checks under every strategy: a length
  is a runtime value that no guard region can bound. A zero length at
  exactly ByteSize is in bounds, which is what memory.fill and
  memory.copy require. }
function MemRange(var AMem: TWasmMemoryInst;
  const AIndex, ALength: UInt64): PByte; inline;

{ Check with no pointer, for a caller doing its own address arithmetic
  (the JIT's fold path). Same decision, same trap, no result. }
procedure MemCheck(var AMem: TWasmMemoryInst;
  const AIndex, AOffset, ASize: UInt64); inline;

implementation

function SelectMemStrategy(const AAddrType: TWasmAddrType): TWasmMemStrategy;
begin
  {$IFDEF WASM_GUARD_STRATEGIES}
  if AAddrType = watI32 then
    Result := wmsGuardPages
  else
    Result := wmsGuardAssisted;
  {$ELSE}
  Result := wmsBoundsChecked;
  {$ENDIF}
end;

function MemStrategySupported(const AStrategy: TWasmMemStrategy;
  const AAddrType: TWasmAddrType): Boolean;
begin
  {$IFDEF WASM_GUARD_STRATEGIES}
  { A guard-page memory relies on the reservation covering every address
    its index can name, which only an i32 index can be. }
  Result := (AStrategy <> wmsGuardPages) or (AAddrType = watI32);
  {$ELSE}
  Result := AStrategy = wmsBoundsChecked;
  {$ENDIF}
end;

function MemoryPageCeiling(const AAddrType: TWasmAddrType): UInt64;
begin
  if AAddrType = watI32 then
    Result := WASM_MAX_I32_PAGES
  else
    Result := WASM_MAX_I64_PAGES;
end;

{ --- bounds ---------------------------------------------------------- }

function MemInBounds(const AByteSize, AIndex, AOffset, ASize: UInt64): Boolean;
  inline;
var
  Available: UInt64;
begin
  if AIndex > AByteSize then
    Exit(False);
  Available := AByteSize - AIndex;
  if AOffset > Available then
    Exit(False);
  Result := ASize <= Available - AOffset;
end;

{ ADR-0010/ADR-0013 describe an index-width reduction for i64 memories on
  a 32-bit host — trap if the high 32 bits of the index are nonzero. That
  is not a separate step here: MemInBounds compares AIndex (UInt64)
  against ByteSize (UInt64), and on a 32-bit host ByteSize is at most
  High(NativeUInt) = 2^32-1, so any index with a nonzero high half already
  exceeds it and traps. The former IndexTooWide helper was therefore dead
  (B4) and has been removed. }

function MemPointer(const AMem: TWasmMemoryInst;
  const AIndex, AOffset: UInt64): PByte; inline;
begin
  { Reached only when the sum is known to be representable: either a
    check has passed, or the strategy's reservation covers it. }
  Result := PByte(NativeUInt(AMem.Base) + NativeUInt(AIndex) +
    NativeUInt(AOffset));
end;

procedure MemCheck(var AMem: TWasmMemoryInst;
  const AIndex, AOffset, ASize: UInt64); inline;
begin
  { Track C Wave 6b — the chokepoint's helper path is robust by EXPLICIT
    full-precision CHECK on every strategy and never hands back or
    dereferences an out-of-bounds address. The interpreter (the tier of
    record) reaches memory only through MemAddress / MemRange / MemCheck,
    so an out-of-bounds guest access is a clean TrapNow -> trampoline
    EWasmTrap that never depends on MMU fault delivery.

    Why the guard-page NO-CHECK fold was removed from this helper:
    in-process guard-page fault delivery proved unreliable. The FIRST
    SIGSEGV raised in a fresh process surfaces through the FPC RTL as
    EStackOverflow instead of reaching our handler -> trampoline (it
    aborted a whole corpus file, address.wast, on `i32.load8_u offset=1`
    at index 0xFFFFFFFF); a forked child that INHERITS a warmed process
    traps cleanly, which is why the forked-child test passed while the
    live runner did not. Relying on that path for the interpreter is
    exactly the fragility ADR-0009's trampoline exists to remove, so the
    fold is deferred to a future JIT tier (Track I) that emits inline
    accesses and can first prove signal->trampoline delivery robust
    in-process. The guard-page reservation and the fault handler stay
    mapped and installed as that latent capability; this helper no longer
    uses them.

    Observational identity is preserved and strengthened: every strategy
    now raises the same trap, with the same message, at the same access
    (ADR-0005, ADR-0010). The comparison is unsigned and in UInt64, so an
    i64 index above 2^32-1 on a 32-bit host already exceeds any allocatable
    ByteSize and traps here — the index-width reduction ADR-0013 describes
    is subsumed by this one compare (B4). }
  {$IFNDEF PRODUCTION}
  { The guard-page reservation still assumes an i32-width index the caller
    widened; a wider one would name an address outside it. Kept as a debug
    invariant, though the explicit check below no longer relies on it. }
  if AMem.Strategy = wmsGuardPages then
    Assert(AIndex <= UInt64($FFFFFFFF),
      'guard-page memory reached with a 64-bit index');
  {$ENDIF}
  if not MemInBounds(AMem.ByteSize, AIndex, AOffset, ASize) then
    TrapNow(wtkMemoryOutOfBounds);
end;

function MemAddress(var AMem: TWasmMemoryInst;
  const AIndex, AOffset: UInt64; const ASize: UInt64): PByte; inline;
begin
  MemCheck(AMem, AIndex, AOffset, ASize);
  Result := MemPointer(AMem, AIndex, AOffset);
end;

function MemRange(var AMem: TWasmMemoryInst;
  const AIndex, ALength: UInt64): PByte; inline;
begin
  { Always a full-precision check: a length is a runtime value no guard
    region can bound. The UInt64 compare subsumes the 32-bit index-width
    reduction, as in MemCheck. }
  if not MemInBounds(AMem.ByteSize, AIndex, 0, ALength) then
    TrapNow(wtkMemoryOutOfBounds);
  Result := MemPointer(AMem, AIndex, 0);
end;

{ --- allocation ------------------------------------------------------ }

procedure RaiseAllocFailure;
begin
  raise EWasmError.Create('cannot allocate linear memory');
end;

{$IFDEF WASM_GUARD_STRATEGIES}
function ReserveGuarded(const ABytes: UInt64): Pointer;
begin
  { PROT_NONE for the whole reservation; the accessible prefix is opened
    up by mprotect afterwards. Everything past it faults, which is the
    entire mechanism. macOS has no MAP_NORESERVE and backs the mapping
    lazily anyway, so it is not passed. MAP_JIT is deliberately absent —
    this is data, not code. }
  Result := Fpmmap(nil, ABytes, PROT_NONE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if Result = Pointer(-1) then
    Result := nil;
end;

function CommitGuarded(const ABase: Pointer; const AOffset,
  ABytes: UInt64): Boolean;
begin
  if ABytes = 0 then
    Exit(True);
  Result := Fpmprotect(Pointer(NativeUInt(ABase) + NativeUInt(AOffset)),
    ABytes, PROT_READ or PROT_WRITE) = 0;
end;
{$ENDIF}

procedure MemoryInitForTest(out AMem: TWasmMemoryInst;
  const AType: TWasmMemType; const AStrategy: TWasmMemStrategy;
  const AGuardBytes: UInt64);
var
  Ceiling: UInt64;
  Bytes: UInt64;
  {$IFDEF WASM_GUARD_STRATEGIES}
  Reserve: UInt64;
  {$ENDIF}
begin
  FillChar(AMem, SizeOf(AMem), 0);

  if not MemStrategySupported(AStrategy, AType.Limits.AddrType) then
    raise EWasmError.Create(
      'memory strategy is not available on this platform');

  {$IFNDEF PRODUCTION}
  { The guard must be able to absorb one maximum-width access, or the fold
    decision's `GuardBytes - ASize` underflows (fix 2). Production callers
    pass WASM_GUARD_BYTES (2 GiB); only a test can get this wrong. }
  Assert(AGuardBytes >= WASM_MAX_ACCESS_WIDTH,
    'guard smaller than the maximum access width');
  {$ENDIF}

  AMem.Strategy := AStrategy;
  AMem.AddrType := AType.Limits.AddrType;
  AMem.HasMax := AType.Limits.HasMax;
  AMem.GuardBytes := AGuardBytes;

  Ceiling := MemoryPageCeiling(AType.Limits.AddrType);
  if AType.Limits.HasMax and (AType.Limits.Max < Ceiling) then
    AMem.MaxPages := AType.Limits.Max
  else
    AMem.MaxPages := Ceiling;

  if AType.Limits.Min > AMem.MaxPages then
    RaiseAllocFailure;

  AMem.Pages := AType.Limits.Min;
  Bytes := AMem.Pages * UInt64(WASM_PAGE_SIZE);
  AMem.ByteSize := Bytes;

  case AStrategy of
    {$IFDEF WASM_GUARD_STRATEGIES}
    wmsGuardPages:
      begin
        { The 4 GiB reservation covers every address an i32 index can
          name; the guard on top covers the static offset immediate up to
          the fold threshold. Growth never has to remap. }
        Reserve := WASM_I32_RESERVE_BYTES + AGuardBytes;
        AMem.ReserveBase := ReserveGuarded(Reserve);
        if AMem.ReserveBase = nil then
          RaiseAllocFailure;
        AMem.ReserveBytes := Reserve;
        if not CommitGuarded(AMem.ReserveBase, 0, Bytes) then
        begin
          Fpmunmap(AMem.ReserveBase, Reserve);
          RaiseAllocFailure;
        end;
      end;
    wmsGuardAssisted:
      begin
        { Current size plus guard. The guard exists solely so that static
          offsets fold; the index is always checked. }
        Reserve := Bytes + AGuardBytes;
        AMem.ReserveBase := ReserveGuarded(Reserve);
        if AMem.ReserveBase = nil then
          RaiseAllocFailure;
        AMem.ReserveBytes := Reserve;
        if not CommitGuarded(AMem.ReserveBase, 0, Bytes) then
        begin
          Fpmunmap(AMem.ReserveBase, Reserve);
          RaiseAllocFailure;
        end;
      end;
    {$ENDIF}
    wmsBoundsChecked:
      begin
        { A zero-page memory still gets storage, so Base is never nil and
          Base + 0 is a valid pointer nothing may dereference. Every
          access traps on the check first. }
        {$IFDEF CPU32}
        { A byte count that does not fit an address is not allocatable.
          Vacuously true on a 64-bit host, so it is compiled out there
          rather than left as a comparison the compiler warns about. }
        if Bytes > UInt64(High(NativeUInt)) then
          RaiseAllocFailure;
        {$ENDIF}
        { ReserveBytes tracks the ACTUAL allocation, not ByteSize: a
          zero-page memory still reserves one byte so Base is non-nil, and
          claiming ReserveBytes = 0 while holding a live block would be
          untruthful bookkeeping (B6). }
        if Bytes = 0 then
        begin
          AMem.ReserveBase := GetMem(1);
          AMem.ReserveBytes := 1;
        end
        else
        begin
          AMem.ReserveBase := GetMem(NativeUInt(Bytes));
          AMem.ReserveBytes := Bytes;
        end;
        if AMem.ReserveBase = nil then
          RaiseAllocFailure;
        { New pages read as zero. GetMem does not promise that. }
        if Bytes > 0 then
          FillChar(AMem.ReserveBase^, NativeUInt(Bytes), 0);
      end;
  else
    RaiseAllocFailure;
  end;

  AMem.Base := PByte(AMem.ReserveBase);
  AMem.Committed := Bytes;

  if AStrategy <> wmsBoundsChecked then
  begin
    { The registry is the ONLY way the fault handler can decide a fault
      is ours, and it must be populated before the mapping can fault.
      Bounds-checked memories are deliberately absent: they never fault
      by design, and registering their heap block would claim addresses
      the host legitimately owns. }
    ReservationRegister(AMem.ReserveBase, NativeUInt(AMem.ReserveBytes));
    InstallFaultHandler;
    EnsureAltSignalStack;
  end;
end;

procedure MemoryInit(out AMem: TWasmMemoryInst; const AType: TWasmMemType);
begin
  MemoryInitForTest(AMem, AType, SelectMemStrategy(AType.Limits.AddrType),
    WASM_GUARD_BYTES);
end;

procedure MemoryFree(var AMem: TWasmMemoryInst);
begin
  if AMem.ReserveBase = nil then
    Exit;

  if AMem.Strategy = wmsBoundsChecked then
    FreeMem(AMem.ReserveBase)
  else
  begin
    { Deregistration MUST precede the unmap: a fault at a freshly
      unmapped and reused address would otherwise be attributed to us. }
    ReservationUnregister(AMem.ReserveBase);
    {$IFDEF WASM_GUARD_STRATEGIES}
    { Only a guard strategy ever reaches this branch — a bounds-checked
      memory is freed above. The unmap is therefore under the same symbol
      that gated the mmap. }
    Fpmunmap(AMem.ReserveBase, NativeUInt(AMem.ReserveBytes));
    {$ENDIF}
  end;

  AMem.ReserveBase := nil;
  AMem.ReserveBytes := 0;
  AMem.Base := nil;
  AMem.ByteSize := 0;
  AMem.Pages := 0;
  AMem.Committed := 0;
end;

{$IFDEF WASM_GUARD_STRATEGIES}
{ Outgrew the reservation. Map a bigger one, copy the live bytes, publish
  it, and only then release the old — the registry must never name an
  address that is no longer ours.

  mremap would avoid the copy on Linux and does not exist on macOS. The
  copy is the cost of the strategy and wasmbench is where that trade gets
  settled, per the RTL policy. }
function RemapGuardAssisted(var AMem: TWasmMemoryInst;
  const ANewBytes: UInt64): Boolean;
var
  NewReserve: UInt64;
  NewBase: Pointer;
  OldBase: Pointer;
  OldReserve: UInt64;
begin
  NewReserve := ANewBytes + AMem.GuardBytes;
  NewBase := ReserveGuarded(NewReserve);
  if NewBase = nil then
    Exit(False);
  if not CommitGuarded(NewBase, 0, ANewBytes) then
  begin
    Fpmunmap(NewBase, NewReserve);
    Exit(False);
  end;

  if AMem.ByteSize > 0 then
    Move(AMem.Base^, NewBase^, NativeUInt(AMem.ByteSize));

  OldBase := AMem.ReserveBase;
  OldReserve := AMem.ReserveBytes;

  ReservationRegister(NewBase, NativeUInt(NewReserve));
  AMem.ReserveBase := NewBase;
  AMem.ReserveBytes := NewReserve;
  AMem.Base := PByte(NewBase);

  ReservationUnregister(OldBase);
  Fpmunmap(OldBase, OldReserve);
  Result := True;
end;
{$ENDIF}

function MemoryGrow(var AMem: TWasmMemoryInst; const ADelta: UInt64): Int64;
var
  OldPages: UInt64;
  OldBytes: UInt64;
  NewBytes: UInt64;
  {$IFDEF WASM_GUARD_STRATEGIES}
  Grown: Boolean;
  {$ENDIF}
  Block: Pointer;
begin
  OldPages := AMem.Pages;
  OldBytes := AMem.ByteSize;

  { Subtracting form: MaxPages is never below Pages, so this cannot
    underflow, and OldPages + ADelta is never formed unless it fits. }
  if ADelta > AMem.MaxPages - OldPages then
    Exit(-1);

  NewBytes := (OldPages + ADelta) * UInt64(WASM_PAGE_SIZE);
  {$IFDEF CPU32}
  if NewBytes > UInt64(High(NativeUInt)) then
    Exit(-1);
  {$ENDIF}

  case AMem.Strategy of
    {$IFDEF WASM_GUARD_STRATEGIES}
    wmsGuardPages:
      begin
        { Always in place: the reservation already covers the whole i32
          address space, so a guard-page memory never moves. }
        if not CommitGuarded(AMem.ReserveBase, OldBytes,
          NewBytes - OldBytes) then
          Exit(-1);
        AMem.Committed := NewBytes;
      end;
    wmsGuardAssisted:
      begin
        if NewBytes + AMem.GuardBytes <= AMem.ReserveBytes then
          Grown := CommitGuarded(AMem.ReserveBase, OldBytes,
            NewBytes - OldBytes)
        else
          Grown := RemapGuardAssisted(AMem, NewBytes);
        if not Grown then
          Exit(-1);
        AMem.Committed := NewBytes;
      end;
    {$ENDIF}
    wmsBoundsChecked:
      begin
        Block := AMem.ReserveBase;
        { Never resize to zero: ReAllocMem would free the block and
          leave Base nil, and a zero-page memory still has to hand out a
          valid Base + 0. }
        if NewBytes = 0 then
          ReAllocMem(Block, 1)
        else
          ReAllocMem(Block, NativeUInt(NewBytes));
        if Block = nil then
          Exit(-1);
        { The tail is new address space and must read as zero. }
        if NewBytes > OldBytes then
          FillChar(PByte(NativeUInt(Block) + NativeUInt(OldBytes))^,
            NativeUInt(NewBytes - OldBytes), 0);
        AMem.ReserveBase := Block;
        { Truthful bookkeeping: the block is one byte even at zero pages
          (B6), matching the zero-page allocation in MemoryInitForTest. }
        if NewBytes = 0 then
          AMem.ReserveBytes := 1
        else
          AMem.ReserveBytes := NewBytes;
        AMem.Base := PByte(Block);
        AMem.Committed := NewBytes;
      end;
  else
    Exit(-1);
  end;

  AMem.Pages := OldPages + ADelta;
  { Publish the bound last. Anything holding a cached Base or ByteSize
    across this call has violated MEM-1. }
  AMem.ByteSize := NewBytes;
  Result := Int64(OldPages);
end;

end.
