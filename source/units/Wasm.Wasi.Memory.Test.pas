{ Unit suite for Wasm.Wasi.Memory — the sandbox boundary in isolation.

  This is the security-critical helper layer: every guest pointer the WASI
  surface touches is bounds-checked here. The tests exercise the boundary
  directly against a hand-built one-page memory — no engine instance, no WASI
  functions — so a bounds bug shows here first (embedding-spec.md §7.2):

    - GuestRead/Write round-trips (bytes and the u32/u64 scalars);
    - an out-of-range offset -> weFault, not a crash;
    - a straddling range (offset in bounds, offset+len past the end) -> weFault;
    - the OVERFLOW case: an offset near 2^64 with a small length must NOT wrap
      to a small valid range — it is weFault (this is the one wrong comparison
      that would be an OOB read, embedding-spec.md §9.3);
    - GuestReadIoVec reads the (buf,len) pairs, and a bad array pointer or an
      array straddling the end is weFault.

  Every test asserts an outcome (AGENTS.md: a test that records no assertion is
  failed by the runner). }
program Wasm.Wasi.Memory.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Runtime.Store,
  Wasm.Wasi.Memory,
  Wasm.Wasi.Types;

type
  TWasiMemoryTests = class(TTestSuite)
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FMem: TWasmMemoryRef;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestByteRoundTrip;
    procedure TestScalarRoundTrip;
    procedure TestOutOfRangeOffsetIsFault;
    procedure TestStraddlingRangeIsFault;
    procedure TestOverflowingRangeDoesNotWrap;
    procedure TestRangeValidBoundaries;
    procedure TestReadIoVec;
    procedure TestReadIoVecBadPointerIsFault;
    procedure TestReadIoVecStraddlingArrayIsFault;
    procedure TestIoChunkClampStaysPositive;
  end;

procedure TWasiMemoryTests.BeforeEach;
begin
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  { One 32-bit page = 65536 bytes. }
  FMem.Store := FStore;
  FMem.Addr := FStore.AddMemory(MakeMemType(MakeLimits(watI32, 1)));
end;

procedure TWasiMemoryTests.AfterEach;
begin
  FreeAndNil(FStore);
  FreeAndNil(FEngine);
end;

procedure TWasiMemoryTests.TestByteRoundTrip;
var
  Src, Dst: array[0..3] of Byte;
begin
  Src[0] := $DE;
  Src[1] := $AD;
  Src[2] := $BE;
  Src[3] := $EF;
  Expect<Boolean>(GuestWriteBytes(FMem, 1000, 4, @Src[0]) = weSuccess).ToBe(True);
  Dst[0] := 0;
  Dst[1] := 0;
  Dst[2] := 0;
  Dst[3] := 0;
  Expect<Boolean>(GuestReadBytes(FMem, 1000, 4, @Dst[0]) = weSuccess).ToBe(True);
  Expect<Boolean>((Dst[0] = $DE) and (Dst[1] = $AD) and (Dst[2] = $BE) and
    (Dst[3] = $EF)).ToBe(True);
end;

procedure TWasiMemoryTests.TestScalarRoundTrip;
var
  U32: UInt32;
  U64: UInt64;
begin
  Expect<Boolean>(GuestWriteU32(FMem, 16, UInt32($12345678)) = weSuccess)
    .ToBe(True);
  Expect<Boolean>(GuestReadU32(FMem, 16, U32) = weSuccess).ToBe(True);
  Expect<Boolean>(U32 = UInt32($12345678)).ToBe(True);

  Expect<Boolean>(GuestWriteU64(FMem, 32, UInt64($0123456789ABCDEF)) =
    weSuccess).ToBe(True);
  Expect<Boolean>(GuestReadU64(FMem, 32, U64) = weSuccess).ToBe(True);
  Expect<Boolean>(U64 = UInt64($0123456789ABCDEF)).ToBe(True);
end;

procedure TWasiMemoryTests.TestOutOfRangeOffsetIsFault;
var
  Dst: array[0..3] of Byte;
  U32: UInt32;
begin
  { Offset exactly AT the end with a positive length is out of range. }
  Expect<Boolean>(GuestReadBytes(FMem, 65536, 4, @Dst[0]) = weFault).ToBe(True);
  Expect<Boolean>(GuestWriteBytes(FMem, 70000, 1, @Dst[0]) = weFault).ToBe(True);
  Expect<Boolean>(GuestReadU32(FMem, 65535, U32) = weFault).ToBe(True);
end;

procedure TWasiMemoryTests.TestStraddlingRangeIsFault;
var
  Dst: array[0..15] of Byte;
begin
  { Offset in bounds, but offset+len runs off the end. }
  Expect<Boolean>(GuestReadBytes(FMem, 65530, 10, @Dst[0]) = weFault).ToBe(True);
  { The last fully-in-bounds read succeeds — the boundary is exact. }
  Expect<Boolean>(GuestReadBytes(FMem, 65530, 6, @Dst[0]) = weSuccess)
    .ToBe(True);
end;

procedure TWasiMemoryTests.TestOverflowingRangeDoesNotWrap;
var
  Dst: array[0..31] of Byte;
begin
  { An offset near 2^64 with a small length. A naive offset+len check wraps to
    a small in-range value and reads out of bounds; the overflow-safe check
    returns weFault. This is the single most important test in the unit. }
  Expect<Boolean>(GuestReadBytes(FMem, UInt64($FFFFFFFFFFFFFFF0), 32, @Dst[0]) =
    weFault).ToBe(True);
  Expect<Boolean>(GuestWriteBytes(FMem, UInt64($FFFFFFFFFFFFFFFF), 8, @Dst[0]) =
    weFault).ToBe(True);
end;

procedure TWasiMemoryTests.TestRangeValidBoundaries;
begin
  Expect<Boolean>(GuestRangeValid(FMem, 0, 65536)).ToBe(True);
  Expect<Boolean>(GuestRangeValid(FMem, 65536, 0)).ToBe(True);
  Expect<Boolean>(GuestRangeValid(FMem, 65536, 1)).ToBe(False);
  Expect<Boolean>(GuestRangeValid(FMem, 65530, 6)).ToBe(True);
  Expect<Boolean>(GuestRangeValid(FMem, 65530, 7)).ToBe(False);
  Expect<Boolean>(GuestRangeValid(FMem, UInt64($FFFFFFFFFFFFFFF0), 32))
    .ToBe(False);
end;

procedure TWasiMemoryTests.TestReadIoVec;
var
  Vecs: TWasmWasiIoVecArray;
begin
  { Two ciovec records at offset 0: (buf=100, len=5), (buf=200, len=3). }
  Expect<Boolean>(GuestWriteU32(FMem, 0, 100) = weSuccess).ToBe(True);
  Expect<Boolean>(GuestWriteU32(FMem, 4, 5) = weSuccess).ToBe(True);
  Expect<Boolean>(GuestWriteU32(FMem, 8, 200) = weSuccess).ToBe(True);
  Expect<Boolean>(GuestWriteU32(FMem, 12, 3) = weSuccess).ToBe(True);

  Expect<Boolean>(GuestReadIoVec(FMem, 0, 2, Vecs) = weSuccess).ToBe(True);
  Expect<Integer>(Length(Vecs)).ToBe(2);
  Expect<Boolean>(Vecs[0].Buf = 100).ToBe(True);
  Expect<Boolean>(Vecs[0].Len = 5).ToBe(True);
  Expect<Boolean>(Vecs[1].Buf = 200).ToBe(True);
  Expect<Boolean>(Vecs[1].Len = 3).ToBe(True);

  { A zero-count array is a clean empty success. }
  Expect<Boolean>(GuestReadIoVec(FMem, 0, 0, Vecs) = weSuccess).ToBe(True);
  Expect<Integer>(Length(Vecs)).ToBe(0);
end;

procedure TWasiMemoryTests.TestReadIoVecBadPointerIsFault;
var
  Vecs: TWasmWasiIoVecArray;
begin
  { The iovec array pointer itself is out of bounds. The buffers it might name
    are never even read — the array read faults first. }
  Expect<Boolean>(GuestReadIoVec(FMem, 65536, 2, Vecs) = weFault).ToBe(True);
  Expect<Boolean>(GuestReadIoVec(FMem, UInt64($FFFFFFF0), 2, Vecs) = weFault)
    .ToBe(True);
end;

procedure TWasiMemoryTests.TestReadIoVecStraddlingArrayIsFault;
var
  Vecs: TWasmWasiIoVecArray;
begin
  { The array starts in bounds but its 2*8 = 16 bytes run off the end. }
  Expect<Boolean>(GuestReadIoVec(FMem, 65530, 2, Vecs) = weFault).ToBe(True);
end;

procedure TWasiMemoryTests.TestIoChunkClampStaysPositive;
begin
  { F7/W1: a guest iovec buf_len is a u32 and can be in [2^31, 2^32); casting it
    straight to the signed LongInt FileRead/FileWrite take would wrap NEGATIVE.
    GuestIoChunk clamps every host I/O call to a positive-LongInt bound, so the
    length can never reach the OS as a negative count. }
  { A small length passes through unchanged. }
  Expect<Boolean>(GuestIoChunk(0) = 0).ToBe(True);
  Expect<Boolean>(GuestIoChunk(5) = 5).ToBe(True);
  { The clamp is itself a positive LongInt. }
  Expect<Boolean>(GuestIoChunk(WASI_IO_MAX_CHUNK) = WASI_IO_MAX_CHUNK).ToBe(True);
  Expect<Boolean>(WASI_IO_MAX_CHUNK > 0).ToBe(True);
  { The dangerous inputs: a length at/above 2^31, and the full u32 range. Both
    clamp to the positive bound — never a negative LongInt. }
  Expect<Boolean>(GuestIoChunk(UInt64($80000000)) = WASI_IO_MAX_CHUNK).ToBe(True);
  Expect<Boolean>(GuestIoChunk(UInt64($FFFFFFFF)) = WASI_IO_MAX_CHUNK).ToBe(True);
  Expect<Boolean>(GuestIoChunk(UInt64($80000000)) > 0).ToBe(True);
  Expect<Boolean>(GuestIoChunk(UInt64($FFFFFFFF)) > 0).ToBe(True);
end;

procedure TWasiMemoryTests.SetupTests;
begin
  Test('byte read/write round-trips', TestByteRoundTrip);
  Test('u32/u64 scalar read/write round-trips', TestScalarRoundTrip);
  Test('an out-of-range offset is weFault', TestOutOfRangeOffsetIsFault);
  Test('a straddling range is weFault, the exact boundary succeeds',
    TestStraddlingRangeIsFault);
  Test('an overflowing offset does not wrap and is weFault',
    TestOverflowingRangeDoesNotWrap);
  Test('GuestRangeValid boundaries', TestRangeValidBoundaries);
  Test('GuestReadIoVec reads the (buf,len) pairs', TestReadIoVec);
  Test('GuestReadIoVec with a bad array pointer is weFault',
    TestReadIoVecBadPointerIsFault);
  Test('GuestReadIoVec with a straddling array is weFault',
    TestReadIoVecStraddlingArrayIsFault);
  Test('GuestIoChunk clamps a >=2^31 length to a positive LongInt',
    TestIoChunkClampStaysPositive);
end;

begin
  TestRunnerProgram.AddSuite(TWasiMemoryTests.Create('Wasm.Wasi.Memory'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
