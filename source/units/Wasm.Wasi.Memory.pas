{ Wasm.Wasi.Memory — the WASI guest-memory helper layer, and THE sandbox
  boundary the whole WASI surface is written against (embedding-spec.md §5,
  §9.2).

  Every byte a preview1 function reads or writes in the guest's linear memory
  goes through this unit. The unit itself never touches a memory's Base and
  never does pointer arithmetic on guest memory: it delegates to Wasm.Engine's
  chokepoint accessors (MemRead / MemWrite / MemSize), which route to
  TWasmStore.MemRangeAt with an unsigned, overflow-safe pre-check (ADR-0005,
  ADR-0010, ADR-0013). So a guest-controlled offset/length is bounds-checked
  before any copy, an out-of-range or WRAPPING (offset+len overflowing u64)
  access is a WASI weFault RETURN VALUE, and a malicious pointer can never
  produce a raw host dereference or an out-of-bounds read. That absence is the
  sandbox (embedding-spec.md §9.2).

  Layering (embedding-spec.md §8.1): depends on Wasm.Engine (the chokepoint
  accessors and TWasmMemoryRef) and Wasm.Wasi.Types (the errno codes) and
  nothing lower — it does not reach the store, the memory unit, or Base
  directly.

  SOURCE for the ABI shapes it reads (iovec/ciovec width, little-endian scalar
  order): the frozen wasi_snapshot_preview1 typenames.witx, consumed through
  Wasm.Wasi.Types (embedding-spec.md §0 WASI pin). WASI is not in the wasm MCP.

  Spec pin (core, for the memory-model anchors this rests on): wasm-mcp 0.2.16,
  spec/main d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
unit Wasm.Wasi.Memory;

{$I Shared.inc}

interface

uses
  Wasm.Engine,
  Wasm.Wasi.Types;

type
  { One (buf, len) pair from a guest iovec/ciovec array: a guest offset and a
    byte length, both widened to u64 so a wasm64 memory is handled uniformly
    (embedding-spec.md §5.4). The buffer itself is NOT dereferenced when the
    array is read — each buffer is bounds-checked at the moment fd_read /
    fd_write actually touches it, via GuestReadBytes / GuestWriteBytes. }
  TWasmWasiIoVec = record
    Buf: UInt64;
    Len: UInt64;
  end;

  TWasmWasiIoVecArray = array of TWasmWasiIoVec;

{ True iff [AOffset, AOffset+ALen) lies wholly inside the memory. The check is
  unsigned and overflow-safe — never AOffset + ALen (which wraps) — identical
  to the discipline the chokepoint enforces. A zero-length range at exactly the
  end of memory is in bounds. Used to pre-validate before a host-side
  allocation whose size is guest-controlled (random_get), so an out-of-range
  request is rejected BEFORE any buffer is allocated. }
function GuestRangeValid(const AMem: TWasmMemoryRef;
  const AOffset, ALen: UInt64): Boolean;

{ Copy ALen bytes from guest offset AOffset into ADest. weFault (never a raise,
  never a raw deref) if the range is out of bounds or would wrap. A zero-length
  read is weSuccess and touches nothing. }
function GuestReadBytes(const AMem: TWasmMemoryRef; const AOffset, ALen: UInt64;
  ADest: PByte): TWasmWasiErrno;

{ Copy ALen bytes from ASrc into guest offset AOffset. weFault on OOB/wrap. }
function GuestWriteBytes(const AMem: TWasmMemoryRef; const AOffset, ALen: UInt64;
  ASrc: PByte): TWasmWasiErrno;

{ Little-endian scalar accessors at a guest offset (wasm's byte order). Each is
  a GuestReadBytes / GuestWriteBytes of the right width; weFault on OOB. }
function GuestReadU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt32): TWasmWasiErrno;
function GuestWriteU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt32): TWasmWasiErrno;
function GuestReadU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt64): TWasmWasiErrno;
function GuestWriteU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt64): TWasmWasiErrno;

{ Read a ciovec/iovec array: AIovsLen records of (buf: u32, buf_len: u32) at
  AIovsPtr (WASI_CIOVEC_SIZE = 8 bytes each on wasm32). The array's own extent
  is validated with one overflow-safe range check; each returned buffer is left
  for the caller to bounds-check when it is touched (embedding-spec.md §5).
  weFault if the array is out of bounds. AIovsLen = 0 yields an empty list and
  weSuccess. }
function GuestReadIoVec(const AMem: TWasmMemoryRef; const AIovsPtr: UInt64;
  const AIovsLen: UInt32; out AVecs: TWasmWasiIoVecArray): TWasmWasiErrno;

const
  { The largest host read/write chunk a single FileRead/FileWrite is asked for,
    chosen so it is always a POSITIVE LongInt (F7/W1). A guest iovec buf_len is
    a u32 and can be in [2^31, 2^32); casting that straight to the signed LongInt
    FileRead/FileWrite take would wrap NEGATIVE and either fault or (worse) be
    misinterpreted. fd_read/fd_write instead loop, clamping each host call to
    this bound via GuestIoChunk, so no length can ever reach the OS as a
    negative count. 256 MiB is comfortably below 2^31. }
  WASI_IO_MAX_CHUNK = LongInt($10000000);

{ Clamp a remaining host-I/O length to a positive-LongInt chunk (F7/W1). The
  result is min(ARemaining, WASI_IO_MAX_CHUNK) and is guaranteed to be a
  non-negative LongInt, so casting it into FileRead/FileWrite can never wrap.
  A caller loops until ARemaining is consumed. }
function GuestIoChunk(const ARemaining: UInt64): LongInt;

implementation

function GuestIoChunk(const ARemaining: UInt64): LongInt;
begin
  if ARemaining >= UInt64(WASI_IO_MAX_CHUNK) then
    Result := WASI_IO_MAX_CHUNK
  else
    Result := LongInt(ARemaining);
end;

function GuestRangeValid(const AMem: TWasmMemoryRef;
  const AOffset, ALen: UInt64): Boolean;
var
  Size: UInt64;
begin
  Size := MemSize(AMem);
  { Overflow-safe: never AOffset + ALen, which wraps at 2^64. }
  Result := (AOffset <= Size) and (ALen <= Size - AOffset);
end;

function GuestReadBytes(const AMem: TWasmMemoryRef; const AOffset, ALen: UInt64;
  ADest: PByte): TWasmWasiErrno;
begin
  { MemRead does the overflow-safe bounds pre-check against MemSize and only
    then copies through MemRangeAt — this unit adds no pointer math of its
    own. A False return is an out-of-range guest pointer: weFault. }
  if MemRead(AMem, AOffset, ALen, ADest) then
    Result := weSuccess
  else
    Result := weFault;
end;

function GuestWriteBytes(const AMem: TWasmMemoryRef; const AOffset, ALen: UInt64;
  ASrc: PByte): TWasmWasiErrno;
begin
  if MemWrite(AMem, AOffset, ALen, ASrc) then
    Result := weSuccess
  else
    Result := weFault;
end;

function GuestReadU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt32): TWasmWasiErrno;
begin
  if MemReadU32(AMem, AOffset, AValue) then
    Result := weSuccess
  else
  begin
    AValue := 0;
    Result := weFault;
  end;
end;

function GuestWriteU32(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt32): TWasmWasiErrno;
begin
  if MemWriteU32(AMem, AOffset, AValue) then
    Result := weSuccess
  else
    Result := weFault;
end;

function GuestReadU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  out AValue: UInt64): TWasmWasiErrno;
begin
  if MemReadU64(AMem, AOffset, AValue) then
    Result := weSuccess
  else
  begin
    AValue := 0;
    Result := weFault;
  end;
end;

function GuestWriteU64(const AMem: TWasmMemoryRef; const AOffset: UInt64;
  const AValue: UInt64): TWasmWasiErrno;
begin
  if MemWriteU64(AMem, AOffset, AValue) then
    Result := weSuccess
  else
    Result := weFault;
end;

function GuestReadIoVec(const AMem: TWasmMemoryRef; const AIovsPtr: UInt64;
  const AIovsLen: UInt32; out AVecs: TWasmWasiIoVecArray): TWasmWasiErrno;
var
  ArrayBytes: UInt64;
  Index: UInt32;
  EntryOff: UInt64;
  Buf, Len: UInt32;
begin
  AVecs := nil;
  if AIovsLen = 0 then
    Exit(weSuccess);

  { AIovsLen is a u32 and WASI_CIOVEC_SIZE = 8, so the product fits a u64 with
    no overflow (max 2^32 * 8 = 2^35). Validate the whole array extent once,
    overflow-safe, before reading any entry — a wrapping AIovsPtr is caught
    here rather than silently aliasing a small valid offset. }
  ArrayBytes := UInt64(AIovsLen) * UInt64(WASI_CIOVEC_SIZE);
  if not GuestRangeValid(AMem, AIovsPtr, ArrayBytes) then
    Exit(weFault);

  SetLength(AVecs, AIovsLen);
  for Index := 0 to AIovsLen - 1 do
  begin
    EntryOff := AIovsPtr + UInt64(Index) * UInt64(WASI_CIOVEC_SIZE);
    { Each read is itself bounds-checked; the pre-check above makes these
      succeed, but they stay honest and strategy-independent. }
    Result := GuestReadU32(AMem, EntryOff + UInt64(WASI_CIOVEC_BUF_OFF), Buf);
    if Result <> weSuccess then
      Exit;
    Result := GuestReadU32(AMem, EntryOff + UInt64(WASI_CIOVEC_BUF_LEN_OFF),
      Len);
    if Result <> weSuccess then
      Exit;
    AVecs[Index].Buf := UInt64(Buf);
    AVecs[Index].Len := UInt64(Len);
  end;
  Result := weSuccess;
end;

end.
