{ Unit suite for Wasm.Wasi.Types — the transcription guard.

  F0's whole value is a correct transcription of the wasi_snapshot_preview1
  ABI (typenames.witx), and the classic WASI defect is a wrong constant: an
  errno off by one, a struct offset that ignores alignment padding, a flag on
  the wrong bit. So these tests assert the EXACT numbers a wrong keystroke
  would change — the load-bearing errno codes the sandbox leans on, the four
  struct sizes whose padding is easy to miscount, and a few flag/enum values.
  A typo becomes a red test here rather than a silent OOB read or a wrong
  errno in F2/F4, and F5's wasi-testsuite is the external cross-check on top.

  Every test asserts an outcome (never only Fail on a bad path) — a test that
  records no assertion is failed by the runner (AGENTS.md). }
program Wasm.Wasi.Types.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Wasi.Types;

type
  TWasiTypesTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestErrnoLoadBearingValues;
    procedure TestErrnoTableIsContiguous;
    procedure TestErrnoCodeHelper;
    procedure TestFiletypeValues;
    procedure TestClockidValues;
    procedure TestWhenceValues;
    procedure TestOflagsBits;
    procedure TestFdflagsBits;
    procedure TestLookupflagsBit;
    procedure TestRightsBits;
    procedure TestStructSizes;
    procedure TestStructOffsets;
    procedure TestPreopentypeAndAdvice;
  end;

procedure TWasiTypesTests.TestErrnoLoadBearingValues;
begin
  { The security-critical errno codes, asserted by exact ordinal. These are
    the ones embedding-spec.md §3/§9 names: success, the bad-fd/bad-pointer
    pair, missing-path, unimplemented, and the deny-by-default code. }
  Expect<Integer>(Ord(weSuccess)).ToBe(0);
  Expect<Integer>(Ord(weBadf)).ToBe(8);
  Expect<Integer>(Ord(weExist)).ToBe(20);
  Expect<Integer>(Ord(weFault)).ToBe(21);
  Expect<Integer>(Ord(weInval)).ToBe(28);
  Expect<Integer>(Ord(weIo)).ToBe(29);
  Expect<Integer>(Ord(weIsDir)).ToBe(31);
  Expect<Integer>(Ord(weLoop)).ToBe(32);
  Expect<Integer>(Ord(weNoEnt)).ToBe(44);
  Expect<Integer>(Ord(weNoSys)).ToBe(52);
  Expect<Integer>(Ord(weNotDir)).ToBe(54);
  Expect<Integer>(Ord(weNotSup)).ToBe(58);
  Expect<Integer>(Ord(weSpipe)).ToBe(70);
  { The last member, ordinal 76 — the capability-insufficient code. }
  Expect<Integer>(Ord(weNotCapable)).ToBe(76);
end;

procedure TWasiTypesTests.TestErrnoTableIsContiguous;
begin
  { The enum's ordinals ARE the ABI numbers, and the ABI numbers are
    contiguous 0..76 with no gaps. A stray explicit value (or a dropped
    member) would break the run from Low to High spanning exactly 77 codes,
    so a hole or an off-by-one anywhere in the table fails here. }
  Expect<Integer>(Ord(Low(TWasmWasiErrno))).ToBe(0);
  Expect<Integer>(Ord(High(TWasmWasiErrno))).ToBe(76);
  { Ord(High) - Ord(Low) + 1 = member count only when there are no gaps;
    the enum spans 77 contiguous ordinals. }
  Expect<Integer>(Ord(High(TWasmWasiErrno)) - Ord(Low(TWasmWasiErrno)) + 1)
    .ToBe(77);
end;

procedure TWasiTypesTests.TestErrnoCodeHelper;
begin
  { WasiErrnoCode is Ord widened to the u16 the wasm ABI returns. }
  Expect<Integer>(Integer(WasiErrnoCode(weSuccess))).ToBe(0);
  Expect<Integer>(Integer(WasiErrnoCode(weBadf))).ToBe(8);
  Expect<Integer>(Integer(WasiErrnoCode(weNotCapable))).ToBe(76);
end;

procedure TWasiTypesTests.TestFiletypeValues;
begin
  Expect<Integer>(WASI_FILETYPE_UNKNOWN).ToBe(0);
  Expect<Integer>(WASI_FILETYPE_BLOCK_DEVICE).ToBe(1);
  Expect<Integer>(WASI_FILETYPE_CHARACTER_DEVICE).ToBe(2);
  Expect<Integer>(WASI_FILETYPE_DIRECTORY).ToBe(3);
  Expect<Integer>(WASI_FILETYPE_REGULAR_FILE).ToBe(4);
  Expect<Integer>(WASI_FILETYPE_SOCKET_DGRAM).ToBe(5);
  Expect<Integer>(WASI_FILETYPE_SOCKET_STREAM).ToBe(6);
  Expect<Integer>(WASI_FILETYPE_SYMBOLIC_LINK).ToBe(7);
end;

procedure TWasiTypesTests.TestClockidValues;
begin
  Expect<Integer>(Integer(WASI_CLOCKID_REALTIME)).ToBe(0);
  Expect<Integer>(Integer(WASI_CLOCKID_MONOTONIC)).ToBe(1);
  Expect<Integer>(Integer(WASI_CLOCKID_PROCESS_CPUTIME_ID)).ToBe(2);
  Expect<Integer>(Integer(WASI_CLOCKID_THREAD_CPUTIME_ID)).ToBe(3);
end;

procedure TWasiTypesTests.TestWhenceValues;
begin
  { Preview1 whence ordering is set/cur/end (transcribed from witx, NOT from
    any particular libc's SEEK_* macros). }
  Expect<Integer>(WASI_WHENCE_SET).ToBe(0);
  Expect<Integer>(WASI_WHENCE_CUR).ToBe(1);
  Expect<Integer>(WASI_WHENCE_END).ToBe(2);
end;

procedure TWasiTypesTests.TestOflagsBits;
begin
  Expect<Integer>(WASI_OFLAGS_CREAT).ToBe(1);
  Expect<Integer>(WASI_OFLAGS_DIRECTORY).ToBe(2);
  Expect<Integer>(WASI_OFLAGS_EXCL).ToBe(4);
  Expect<Integer>(WASI_OFLAGS_TRUNC).ToBe(8);
end;

procedure TWasiTypesTests.TestFdflagsBits;
begin
  Expect<Integer>(WASI_FDFLAGS_APPEND).ToBe(1);
  Expect<Integer>(WASI_FDFLAGS_DSYNC).ToBe(2);
  Expect<Integer>(WASI_FDFLAGS_NONBLOCK).ToBe(4);
  Expect<Integer>(WASI_FDFLAGS_RSYNC).ToBe(8);
  Expect<Integer>(WASI_FDFLAGS_SYNC).ToBe(16);
end;

procedure TWasiTypesTests.TestLookupflagsBit;
begin
  Expect<Integer>(Integer(WASI_LOOKUPFLAGS_SYMLINK_FOLLOW)).ToBe(1);
end;

procedure TWasiTypesTests.TestRightsBits;
begin
  { A representative spread of the u64 rights table, asserted as the bit's
    numeric value (bit N = 2^N). These are the ones the wave-1/2 functions
    check by name; a shifted bit here mis-grants a capability. }
  Expect<Int64>(Int64(WASI_RIGHTS_FD_DATASYNC)).ToBe(1);          { bit 0 }
  Expect<Int64>(Int64(WASI_RIGHTS_FD_READ)).ToBe(2);             { bit 1 }
  Expect<Int64>(Int64(WASI_RIGHTS_FD_SEEK)).ToBe(4);             { bit 2 }
  Expect<Int64>(Int64(WASI_RIGHTS_FD_WRITE)).ToBe(64);           { bit 6 }
  Expect<Int64>(Int64(WASI_RIGHTS_PATH_CREATE_DIRECTORY)).ToBe(512);  { bit 9 }
  Expect<Int64>(Int64(WASI_RIGHTS_PATH_OPEN)).ToBe(8192);        { bit 13 }
  Expect<Int64>(Int64(WASI_RIGHTS_FD_READDIR)).ToBe(16384);      { bit 14 }
  Expect<Int64>(Int64(WASI_RIGHTS_PATH_UNLINK_FILE)).ToBe(Int64(1) shl 26);
  Expect<Int64>(Int64(WASI_RIGHTS_SOCK_ACCEPT)).ToBe(Int64(1) shl 29);
end;

procedure TWasiTypesTests.TestStructSizes;
begin
  { The four sizes whose alignment padding is easy to miscount, plus the two
    8-byte vec structs. These are the exact byte totals F2/F4 allocate and
    stride by. }
  Expect<Integer>(WASI_CIOVEC_SIZE).ToBe(8);
  Expect<Integer>(WASI_IOVEC_SIZE).ToBe(8);
  Expect<Integer>(WASI_PRESTAT_SIZE).ToBe(8);
  Expect<Integer>(WASI_FDSTAT_SIZE).ToBe(24);
  Expect<Integer>(WASI_FILESTAT_SIZE).ToBe(64);
  Expect<Integer>(WASI_DIRENT_SIZE).ToBe(24);
end;

procedure TWasiTypesTests.TestStructOffsets;
begin
  { ciovec/iovec: buf @0, buf_len @4. }
  Expect<Integer>(WASI_CIOVEC_BUF_OFF).ToBe(0);
  Expect<Integer>(WASI_CIOVEC_BUF_LEN_OFF).ToBe(4);

  { prestat: tag @0, pr_name_len @4 (union 4-aligned). }
  Expect<Integer>(WASI_PRESTAT_TAG_OFF).ToBe(0);
  Expect<Integer>(WASI_PRESTAT_DIR_NAMELEN_OFF).ToBe(4);

  { fdstat: filetype @0, flags @2, rights_base @8, rights_inheriting @16. }
  Expect<Integer>(WASI_FDSTAT_FILETYPE_OFF).ToBe(0);
  Expect<Integer>(WASI_FDSTAT_FLAGS_OFF).ToBe(2);
  Expect<Integer>(WASI_FDSTAT_RIGHTS_BASE_OFF).ToBe(8);
  Expect<Integer>(WASI_FDSTAT_RIGHTS_INHERITING_OFF).ToBe(16);

  { filestat: the 8-byte fields with filetype @16 padded before nlink @24. }
  Expect<Integer>(WASI_FILESTAT_DEV_OFF).ToBe(0);
  Expect<Integer>(WASI_FILESTAT_INO_OFF).ToBe(8);
  Expect<Integer>(WASI_FILESTAT_FILETYPE_OFF).ToBe(16);
  Expect<Integer>(WASI_FILESTAT_NLINK_OFF).ToBe(24);
  Expect<Integer>(WASI_FILESTAT_SIZE_OFF).ToBe(32);
  Expect<Integer>(WASI_FILESTAT_ATIM_OFF).ToBe(40);
  Expect<Integer>(WASI_FILESTAT_MTIM_OFF).ToBe(48);
  Expect<Integer>(WASI_FILESTAT_CTIM_OFF).ToBe(56);

  { dirent header: d_next @0, d_ino @8, d_namlen @16, d_type @20. }
  Expect<Integer>(WASI_DIRENT_NEXT_OFF).ToBe(0);
  Expect<Integer>(WASI_DIRENT_INO_OFF).ToBe(8);
  Expect<Integer>(WASI_DIRENT_NAMLEN_OFF).ToBe(16);
  Expect<Integer>(WASI_DIRENT_TYPE_OFF).ToBe(20);
end;

procedure TWasiTypesTests.TestPreopentypeAndAdvice;
begin
  Expect<Integer>(WASI_PREOPENTYPE_DIR).ToBe(0);
  Expect<Integer>(WASI_ADVICE_NORMAL).ToBe(0);
  Expect<Integer>(WASI_ADVICE_SEQUENTIAL).ToBe(1);
  Expect<Integer>(WASI_ADVICE_NOREUSE).ToBe(5);
end;

procedure TWasiTypesTests.SetupTests;
begin
  Test('errno load-bearing values', TestErrnoLoadBearingValues);
  Test('errno table is contiguous 0..76', TestErrnoTableIsContiguous);
  Test('errno code helper', TestErrnoCodeHelper);
  Test('filetype values', TestFiletypeValues);
  Test('clockid values', TestClockidValues);
  Test('whence values', TestWhenceValues);
  Test('oflags bits', TestOflagsBits);
  Test('fdflags bits', TestFdflagsBits);
  Test('lookupflags bit', TestLookupflagsBit);
  Test('rights bits', TestRightsBits);
  Test('struct sizes', TestStructSizes);
  Test('struct offsets', TestStructOffsets);
  Test('preopentype and advice', TestPreopentypeAndAdvice);
end;

begin
  TestRunnerProgram.AddSuite(TWasiTypesTests.Create('Wasm.Wasi.Types'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
