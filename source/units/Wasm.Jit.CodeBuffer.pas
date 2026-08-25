{ Wasm.Jit.CodeBuffer — executable-memory allocation, the W^X transition,
  and the raw byte/word emission primitives the A64/x64 encoders build on
  (.agent/design/jit-spec.md §3, §12.1).

  This is Track I's de-risking unit: it proves that JIT-emitted machine-code
  bytes can be written, made executable, cache-flushed, and CALLED on this
  host. It is the ONE Wasm.Jit.* unit carrying per-OS conditional glue and the
  permitted host-glue OS bindings (the W^X toggle and the cache flush, §0);
  the guest code it will one day hold is DATA these primitives write, never
  inline assembler — that is why "FreePascal only" is not violated (AGENTS.md).

  W^X, by (OS, arch) leg (§3):

  - DARWIN aarch64 / x86-64 (hardened runtime): mmap RWX with MAP_JIT, then
    toggle per-thread write-protection with pthread_jit_write_protect_np —
    (0) makes JIT memory writable for THIS thread, (1) makes it executable
    again (§3.1). The toggle is per-thread and a store is single-threaded
    (ADR-0008), so there is no cross-thread W^X hazard. macOS x86-64 under the
    hardened runtime wants the same MAP_JIT + toggle, so the split here is by
    OS (DARWIN) for the mechanism, not by arch.
  - LINUX aarch64 / x86-64: classic W^X — mmap RW, write, mprotect to RX
    (§3.2). No MAP_JIT, no per-thread toggle.
  - aarch64 (either OS): the I-cache is not coherent with data stores, so the
    written range MUST be flushed before first execution or the CPU may run
    stale bytes (§3.3). Bound to the platform routine (sys_icache_invalidate
    on Darwin, __clear_cache on Linux) rather than a hand-rolled barrier
    sequence, because the cache-line size and barrier flavour are details the
    OS routine already gets right.
  - x86-64 (either OS): the I-cache is coherent with stores on the same core;
    no flush is needed.
  - Everything else (32-bit hosts, Windows): the JIT is 64-bit-only (§2.2);
    the unit still COMPILES (so `lwpt build` stays green on every CI target),
    but MakeExecutable raises a clear EWasmError — those hosts run the
    interpreter, the tier of record, at full conformance.

  Emission stages into a plain writable TWasmBytes with geometric growth and
  copies once into the executable region at MakeExecutable (§12.1 recommends
  stage-then-copy: it avoids holding the write-toggle across the whole
  emission and keeps all forward-branch patching on the still-writable stage,
  §3.2). A minimal, encoder-agnostic label map (id -> offset) and patch list
  (site + encoder-defined kind + target label) let the A64/x64 encoders
  resolve forward branches at finalize; this unit does the bookkeeping and the
  offset arithmetic, the encoder does the instruction-bit patching.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). Depends on Wasm.Core
  and the OS bindings only (§12.1). }
unit Wasm.Jit.CodeBuffer;

{$I Shared.inc}

{ The JIT emits and executes native code only on a 64-bit UNIX host with a
  backend this track ships (aarch64 first, x86-64 second — §2.1/§2.2). Windows
  and every 32-bit target compile the unit but raise from MakeExecutable. The
  W^X host bindings (mmap/mprotect and, on Darwin, the per-thread toggle) live
  behind this one symbol, mirroring how Shared.inc's WASM_GUARD_STRATEGIES
  gates BaseUnix in the memory/trap units. }
{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}

interface

uses
  SysUtils,
  {$IFDEF WASM_JIT_EXEC}
  BaseUnix,
  {$ENDIF}
  Wasm.Core;

const
  { Raised (as EWasmError — no more specific hierarchy kind applies; this is
    neither decode, validation, link, nor a guest trap) when executable memory
    cannot be produced. Kept as named prefixes so a test asserts the outcome
    without pinning the whole message.

    The corpus never sees these — a host on which the JIT is unsupported runs
    the interpreter transparently (§10.3); this is an internal-defect / host-
    capability signal, not a wasm-semantic error. }
  MSG_JIT_UNSUPPORTED = 'JIT not supported on this target';
  MSG_JIT_ALLOC_FAILED = 'cannot allocate executable memory';

type
  { A label is a caller-assigned handle (the index NewLabel returns) that binds
    to a native offset once BindLabel is called at that offset. Forward
    branches record a patch against an as-yet-unbound label and are resolved
    after the whole function's labels are known (§4.3). }
  TWasmJitLabel = Integer;

  { A recorded forward-branch (or other relative-reference) site. Kind is
    OPAQUE to the code buffer — the encoder assigns and interprets it (A64
    b.cond is a 19-bit word displacement, b is 26-bit, an x64 rel32 is a byte
    displacement) — so this unit stays encoder-agnostic. It owns the
    bookkeeping and the offset arithmetic (PatchDelta); the encoder owns the
    instruction-bit patching (via PatchU32/PatchByte). }
  TWasmJitPatch = record
    SiteOffset: Integer;   { where the branch instruction begins in the stage }
    Target: TWasmJitLabel; { the label whose bound offset the site refers to }
    Kind: Integer;         { encoder-defined discriminator }
  end;

  { A load-time relocation entry (aot-spec §1.5): a site in a function's code
    blob whose absolute address the AOT loader must patch. In the unified
    position-independent emitter every helper call is table-indirect and the IR
    base is register-relative, so NO template emits an absolute host address and
    this list is EMPTY for the current op set — SnapshotRelocs returns nothing.
    The record exists so the artifact format is forward-compatible with a future
    op or the fallback emitter that must bake an absolute. SiteOffset is a byte
    offset into the finalized code; Kind is the patch encoding; Symbol names the
    runtime datum. }
  TWasmJitReloc = record
    SiteOffset: UInt32;
    Kind: Byte;
    Symbol: UInt16;
  end;
  TWasmJitRelocs = array of TWasmJitReloc;

  { The executable code buffer for one code block (§3.4). Lifecycle: Create,
    emit bytes while writable, MakeExecutable to flip to executable + flush,
    EntryPoint to get the callable pointer, Free to munmap. Owned by the JIT
    context in a later unit; here it owns exactly its stage and its one
    executable mapping. }
  TWasmCodeBuffer = class
  private
    FStage: TWasmBytes;      { writable staging; the code grows here }
    FLength: Integer;        { bytes used in FStage (the emitted code size) }
    FExec: Pointer;          { the executable mapping, nil until finalized }
    FExecSize: NativeUInt;   { page-rounded byte length of the mapping }
    FFinalized: Boolean;
    FLabelOffsets: array of Integer;   { -1 = declared but unbound }
    FPatches: array of TWasmJitPatch;
    procedure EnsureCapacity(const AExtra: Integer);
    procedure CheckMutable;
  public
    constructor Create;
    destructor Destroy; override;

    { --- byte / word emission (little-endian; aarch64 and x86-64 are LE) --- }
    procedure EmitByte(const AByte: Byte);
    procedure EmitU32(const AValue: UInt32);
    procedure EmitU64(const AValue: UInt64);
    procedure EmitBytes(const ABytes: array of Byte);

    { Current write position = size emitted so far. A label binds here. }
    function CurrentOffset: Integer;

    { Read back an already-emitted stage byte (the encoders inspect their own
      output; tests assert byte layout portably). Valid before and after
      MakeExecutable — the stage is retained. }
    function ByteAt(const AOffset: Integer): Byte;

    { Overwrite 4/1 already-emitted bytes at AOffset (the encoder's branch
      back-patch). Only valid while still mutable (before MakeExecutable). }
    procedure PatchU32(const AOffset: Integer; const AValue: UInt32);
    procedure PatchByte(const AOffset: Integer; const AByte: Byte);
    { Insert 4 little-endian bytes at AOffset, shifting the tail and every
      label/patch at or past that offset. Used to relax an out-of-range
      conditional into invert + B without rebuilding the function. }
    procedure InsertU32(const AOffset: Integer; const AValue: UInt32);
    procedure SetPatchKind(const AIndex, AKind: Integer);

    { --- label map & patch list (encoder-agnostic branch resolution) --- }
    function NewLabel: TWasmJitLabel;
    procedure BindLabel(const ALabel: TWasmJitLabel);
    function LabelBound(const ALabel: TWasmJitLabel): Boolean;
    function LabelOffset(const ALabel: TWasmJitLabel): Integer;
    procedure AddPatch(const ASiteOffset: Integer;
      const ATarget: TWasmJitLabel; const AKind: Integer);
    function PatchCount: Integer;
    function GetPatch(const AIndex: Integer): TWasmJitPatch;
    { The signed byte displacement from a patch site to its (bound) target —
      the raw material the encoder turns into instruction bits. Requires the
      target label to be bound. }
    function PatchDelta(const AIndex: Integer): Integer;

    { --- AOT capture (aot-spec §3.2) --- }
    { The finalized, branch-resolved code bytes WITHOUT mapping them executable
      — the position-independent blob the AOT writer serializes. Call after the
      backend's ResolvePatches (so intra-function branches are settled) and
      INSTEAD of MakeExecutable. Returns a fresh copy of FStage[0..FLength). }
    function SnapshotBytes: TWasmBytes;
    { The relocation table for the snapshot (aot-spec §1.5). Empty in the unified
      position-independent emitter — kept for format forward-compatibility. }
    function SnapshotRelocs: TWasmJitRelocs;

    { --- finalize to executable & call --- }
    { Allocate the page-rounded executable region, copy the stage into it under
      the platform W^X transition, flush the I-cache where required, and mark
      the buffer executable. Raises EWasmError on an unsupported target or an
      allocation failure. Idempotent: a second call is a no-op. }
    procedure MakeExecutable;

    { The callable entry pointer (the base of the executable region), or nil
      before MakeExecutable. Cast this to the function type matching the
      emitted code's ABI. }
    function EntryPoint: Pointer;

    property Size: Integer read FLength;
    property IsExecutable: Boolean read FFinalized;
  end;

{ True when this (OS, arch) can allocate+execute JIT code (a 64-bit UNIX host
  with a shipped backend). Lets a caller or test branch without duplicating
  the conditional. }
function JitExecMemSupported: Boolean;

implementation

{$IFDEF WASM_JIT_EXEC}
const
  { POSIX PROT_EXEC is 4 on every UNIX; declared locally because the guard/trap
    units only ever needed PROT_READ/PROT_WRITE/PROT_NONE, so PROT_EXEC is not
    known to be surfaced by BaseUnix on every target. PROT_READ/PROT_WRITE,
    MAP_PRIVATE, and MAP_ANONYMOUS come from BaseUnix (the same ones
    Wasm.Runtime.Memory uses); MAP_ANONYMOUS in particular has DIFFERENT values
    on Linux ($20) and Darwin ($1000), so it must come from the RTL, never a
    literal. }
  JIT_PROT_EXEC = $4;

  {$IFDEF DARWIN}
  { <sys/mman.h>: #define MAP_JIT 0x0800. Darwin-only; required for a mapping
    that will be executed under the hardened runtime (§3.1). }
  JIT_MAP_JIT = $0800;

  { pthread_jit_write_protect_np argument sense: 0 = writable for this thread,
    1 = executable (write-protected) for this thread. }
  JIT_WP_WRITABLE = 0;
  JIT_WP_EXECUTABLE = 1;
  {$ENDIF}

{ --- host-glue OS bindings (the permitted external declarations, §3.1/§3.3) - }

{ POSIX getpagesize(); universal on Linux and Darwin. Used to page-round the
  mmap length. }
function JitPageSize: LongInt; cdecl; external 'c' name 'getpagesize';

{$IFDEF DARWIN}
{ libSystem: void pthread_jit_write_protect_np(int enabled). Bound directly
  (not surfaced by FPC's RTL on this target), the same direct-binding pattern
  Wasm.Runtime.Traps uses for sigaltstack.
  UNCONFIRMED (O-J4): the minimum macOS version / entitlement story — the
  symbol exists on macOS 11+; a process needs com.apple.security.cs.allow-jit
  only when signed with the hardened runtime, not when run unsigned/ad-hoc in
  development. A build-time probe or a documented minimum settles it; the proof
  test in this unit is the immediate check. }
procedure JitWriteProtect(const AEnabled: LongInt); cdecl;
  external 'c' name 'pthread_jit_write_protect_np';

{ libSystem: void sys_icache_invalidate(void *start, size_t len). Darwin's
  I-cache flush; gets the cache-line size and barrier flavour right (§3.3). }
procedure JitFlushICache(const AStart: Pointer; const ALen: NativeUInt); cdecl;
  external 'c' name 'sys_icache_invalidate';
{$ELSE}
{$IFDEF CPUAARCH64}
{ void __clear_cache(void *begin, void *end). On Linux/aarch64 the symbol is
  supplied by libgcc_s rather than libc; other aarch64 UNIX targets retain the
  libc binding they already used. }
procedure JitClearCache(const ABegin, AEnd: Pointer); cdecl;
  {$IFDEF LINUX}
  external 'gcc_s' name '__clear_cache';
  {$ELSE}
  external 'c' name '__clear_cache';
  {$ENDIF}
{$ENDIF}
{$ENDIF}

function JitRoundUpToPage(const ABytes: NativeUInt): NativeUInt;
var
  Page: NativeUInt;
begin
  Page := NativeUInt(JitPageSize);
  if Page = 0 then
    Page := 4096;
  Result := (ABytes + Page - 1) and not (Page - 1);
end;
{$ENDIF}

function JitExecMemSupported: Boolean;
begin
  {$IFDEF WASM_JIT_EXEC}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

{ TWasmCodeBuffer }

constructor TWasmCodeBuffer.Create;
begin
  inherited Create;
  FStage := nil;
  FLength := 0;
  FExec := nil;
  FExecSize := 0;
  FFinalized := False;
  FLabelOffsets := nil;
  FPatches := nil;
end;

destructor TWasmCodeBuffer.Destroy;
begin
  {$IFDEF WASM_JIT_EXEC}
  if FExec <> nil then
    Fpmunmap(FExec, FExecSize);
  {$ENDIF}
  FExec := nil;
  inherited Destroy;
end;

procedure TWasmCodeBuffer.CheckMutable;
begin
  if FFinalized then
    raise EWasmError.Create('code buffer is already executable');
end;

procedure TWasmCodeBuffer.EnsureCapacity(const AExtra: Integer);
var
  NewCap: Integer;
begin
  if FLength + AExtra <= Length(FStage) then
    Exit;
  NewCap := Length(FStage);
  if NewCap = 0 then
    NewCap := 64;
  while NewCap < FLength + AExtra do
    NewCap := NewCap * 2;
  SetLength(FStage, NewCap);
end;

procedure TWasmCodeBuffer.EmitByte(const AByte: Byte);
begin
  CheckMutable;
  EnsureCapacity(1);
  FStage[FLength] := AByte;
  Inc(FLength);
end;

procedure TWasmCodeBuffer.EmitU32(const AValue: UInt32);
begin
  CheckMutable;
  EnsureCapacity(4);
  FStage[FLength] := Byte(AValue);
  FStage[FLength + 1] := Byte(AValue shr 8);
  FStage[FLength + 2] := Byte(AValue shr 16);
  FStage[FLength + 3] := Byte(AValue shr 24);
  Inc(FLength, 4);
end;

procedure TWasmCodeBuffer.EmitU64(const AValue: UInt64);
begin
  CheckMutable;
  EnsureCapacity(8);
  FStage[FLength] := Byte(AValue);
  FStage[FLength + 1] := Byte(AValue shr 8);
  FStage[FLength + 2] := Byte(AValue shr 16);
  FStage[FLength + 3] := Byte(AValue shr 24);
  FStage[FLength + 4] := Byte(AValue shr 32);
  FStage[FLength + 5] := Byte(AValue shr 40);
  FStage[FLength + 6] := Byte(AValue shr 48);
  FStage[FLength + 7] := Byte(AValue shr 56);
  Inc(FLength, 8);
end;

procedure TWasmCodeBuffer.EmitBytes(const ABytes: array of Byte);
var
  I: Integer;
begin
  CheckMutable;
  if Length(ABytes) = 0 then
    Exit;
  EnsureCapacity(Length(ABytes));
  for I := 0 to High(ABytes) do
    FStage[FLength + I] := ABytes[I];
  Inc(FLength, Length(ABytes));
end;

function TWasmCodeBuffer.CurrentOffset: Integer;
begin
  Result := FLength;
end;

function TWasmCodeBuffer.ByteAt(const AOffset: Integer): Byte;
begin
  if (AOffset < 0) or (AOffset >= FLength) then
    raise EWasmError.Create('byte offset out of range');
  Result := FStage[AOffset];
end;

procedure TWasmCodeBuffer.PatchU32(const AOffset: Integer;
  const AValue: UInt32);
begin
  CheckMutable;
  if (AOffset < 0) or (AOffset + 4 > FLength) then
    raise EWasmError.Create('patch offset out of range');
  FStage[AOffset] := Byte(AValue);
  FStage[AOffset + 1] := Byte(AValue shr 8);
  FStage[AOffset + 2] := Byte(AValue shr 16);
  FStage[AOffset + 3] := Byte(AValue shr 24);
end;

procedure TWasmCodeBuffer.PatchByte(const AOffset: Integer; const AByte: Byte);
begin
  CheckMutable;
  if (AOffset < 0) or (AOffset >= FLength) then
    raise EWasmError.Create('patch offset out of range');
  FStage[AOffset] := AByte;
end;

procedure TWasmCodeBuffer.InsertU32(const AOffset: Integer;
  const AValue: UInt32);
var
  I: Integer;
begin
  CheckMutable;
  if (AOffset < 0) or (AOffset > FLength) then
    raise EWasmError.Create('insert offset out of range');
  EnsureCapacity(4);
  I := FLength - 1;
  while I >= AOffset do
  begin
    FStage[I + 4] := FStage[I];
    Dec(I);
  end;
  FStage[AOffset] := Byte(AValue);
  FStage[AOffset + 1] := Byte(AValue shr 8);
  FStage[AOffset + 2] := Byte(AValue shr 16);
  FStage[AOffset + 3] := Byte(AValue shr 24);
  Inc(FLength, 4);
  for I := 0 to High(FLabelOffsets) do
    if FLabelOffsets[I] >= AOffset then
      Inc(FLabelOffsets[I], 4);
  for I := 0 to High(FPatches) do
    if FPatches[I].SiteOffset >= AOffset then
      Inc(FPatches[I].SiteOffset, 4);
end;

procedure TWasmCodeBuffer.SetPatchKind(const AIndex, AKind: Integer);
begin
  if (AIndex < 0) or (AIndex >= Length(FPatches)) then
    raise EWasmError.Create('patch index out of range');
  FPatches[AIndex].Kind := AKind;
end;

function TWasmCodeBuffer.NewLabel: TWasmJitLabel;
begin
  Result := Length(FLabelOffsets);
  SetLength(FLabelOffsets, Result + 1);
  FLabelOffsets[Result] := -1;   { unbound until BindLabel }
end;

procedure TWasmCodeBuffer.BindLabel(const ALabel: TWasmJitLabel);
begin
  if (ALabel < 0) or (ALabel >= Length(FLabelOffsets)) then
    raise EWasmError.Create('unknown jit label');
  FLabelOffsets[ALabel] := FLength;
end;

function TWasmCodeBuffer.LabelBound(const ALabel: TWasmJitLabel): Boolean;
begin
  Result := (ALabel >= 0) and (ALabel < Length(FLabelOffsets))
    and (FLabelOffsets[ALabel] >= 0);
end;

function TWasmCodeBuffer.LabelOffset(const ALabel: TWasmJitLabel): Integer;
begin
  if not LabelBound(ALabel) then
    raise EWasmError.Create('jit label is not bound');
  Result := FLabelOffsets[ALabel];
end;

procedure TWasmCodeBuffer.AddPatch(const ASiteOffset: Integer;
  const ATarget: TWasmJitLabel; const AKind: Integer);
var
  N: Integer;
begin
  N := Length(FPatches);
  SetLength(FPatches, N + 1);
  FPatches[N].SiteOffset := ASiteOffset;
  FPatches[N].Target := ATarget;
  FPatches[N].Kind := AKind;
end;

function TWasmCodeBuffer.PatchCount: Integer;
begin
  Result := Length(FPatches);
end;

function TWasmCodeBuffer.GetPatch(const AIndex: Integer): TWasmJitPatch;
begin
  if (AIndex < 0) or (AIndex >= Length(FPatches)) then
    raise EWasmError.Create('patch index out of range');
  Result := FPatches[AIndex];
end;

function TWasmCodeBuffer.PatchDelta(const AIndex: Integer): Integer;
begin
  if (AIndex < 0) or (AIndex >= Length(FPatches)) then
    raise EWasmError.Create('patch index out of range');
  Result := LabelOffset(FPatches[AIndex].Target) - FPatches[AIndex].SiteOffset;
end;

function TWasmCodeBuffer.SnapshotBytes: TWasmBytes;
begin
  SetLength(Result, FLength);
  if FLength > 0 then
    Move(FStage[0], Result[0], FLength);
end;

function TWasmCodeBuffer.SnapshotRelocs: TWasmJitRelocs;
begin
  { The unified emitter bakes no absolute host address, so nothing to relocate. }
  Result := nil;
end;

procedure TWasmCodeBuffer.MakeExecutable;
{$IFDEF WASM_JIT_EXEC}
var
  Prot: LongInt;
  Flags: LongInt;
{$ENDIF}
begin
  if FFinalized then
    Exit;
  if FLength = 0 then
    raise EWasmError.Create('cannot make an empty code buffer executable');

  {$IFDEF WASM_JIT_EXEC}
  FExecSize := JitRoundUpToPage(NativeUInt(FLength));

  {$IFDEF DARWIN}
  { Hardened runtime: allocate executable-but-write-protected with MAP_JIT,
    then write under the per-thread toggle (§3.1). }
  Prot := PROT_READ or PROT_WRITE or JIT_PROT_EXEC;
  Flags := MAP_PRIVATE or MAP_ANONYMOUS or JIT_MAP_JIT;
  {$ELSE}
  { Classic W^X: map RW, write, then mprotect to RX below (§3.2). }
  Prot := PROT_READ or PROT_WRITE;
  Flags := MAP_PRIVATE or MAP_ANONYMOUS;
  {$ENDIF}

  FExec := Fpmmap(nil, FExecSize, Prot, Flags, -1, 0);
  if FExec = Pointer(-1) then
  begin
    FExec := nil;
    raise EWasmError.Create(MSG_JIT_ALLOC_FAILED);
  end;

  {$IFDEF DARWIN}
  JitWriteProtect(JIT_WP_WRITABLE);        { make JIT memory writable, this thread }
  Move(FStage[0], FExec^, FLength);
  JitWriteProtect(JIT_WP_EXECUTABLE);      { flip back to executable }
  {$ELSE}
  Move(FStage[0], FExec^, FLength);
  if Fpmprotect(FExec, FExecSize, PROT_READ or JIT_PROT_EXEC) <> 0 then
  begin
    Fpmunmap(FExec, FExecSize);
    FExec := nil;
    raise EWasmError.Create(MSG_JIT_ALLOC_FAILED);
  end;
  {$ENDIF}

  {$IFDEF CPUAARCH64}
  { aarch64 I-cache is not coherent with the stores above: flush before any
    execution or freshly-written code may run stale bytes (§3.3). x86-64 needs
    no flush (I-cache coherent with same-core stores). }
  {$IFDEF DARWIN}
  JitFlushICache(FExec, NativeUInt(FLength));
  {$ELSE}
  JitClearCache(FExec, Pointer(NativeUInt(FExec) + NativeUInt(FLength)));
  {$ENDIF}
  {$ENDIF}

  FFinalized := True;
  {$ELSE}
  { 32-bit or Windows: the JIT is 64-bit-UNIX-only (§2.2). The unit compiles
    so `lwpt build` is green on every CI target; this host runs the
    interpreter. }
  raise EWasmError.Create(MSG_JIT_UNSUPPORTED);
  {$ENDIF}
end;

function TWasmCodeBuffer.EntryPoint: Pointer;
begin
  Result := FExec;
end;

end.
