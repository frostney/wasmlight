{ Unit suite for Wasm.Wasi — the wave-1 (MUST-tier) preview1 functions, driven
  hermetically through the real embedding path (embedding-spec.md §7.3).

  Every test assembles a real module (via the shipped Wasm.Wat.Assembler) that
  imports the wave-1 wasi_snapshot_preview1 functions and exports a thin
  forwarding wrapper for each plus its own memory. The host sets up the guest
  memory through the chokepoint (Wasm.Engine's MemWrite*), calls the wrapper
  (which invokes the wasi func exactly as a guest would), and asserts the errno,
  the guest-memory writes, and the captured stream. The capability seams are all
  injected, so nothing here touches the real stdout, clock, entropy, fs, or
  network (AGENTS.md).

  Coverage (embedding-spec.md §7.3):
    - fd_write(1, ...) lands in a CAPTURED buffer — the hello-world path, no
      real stdout;
    - args_get/args_sizes_get return the injected argv; environ likewise;
    - clock_time_get returns the injected fixed time; random_get writes the
      injected fixed bytes — determinism proves nothing touched the OS;
    - proc_exit raises EWasmExit with the code;
    - deny-by-default: fd_prestat_get with no preopens -> weBadf for fd 3;
    - the sandbox negatives: a bad guest pointer -> weFault (not a crash), an
      unknown/non-writable fd -> weBadf.

  Every test asserts an outcome (AGENTS.md). Two FPC gotchas are respected: no
  generic Expect<T> as the lone statement of an `on..do`, and every path
  asserts rather than only calling Fail. }
program Wasm.Wasi.Test;

{$I Shared.inc}

uses
  SysUtils,
  Classes,
  {$IFDEF UNIX}
  BaseUnix,   { fpSymlink — to build the escaping-symlink containment negative }
  {$ENDIF}

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Wasi,
  Wasm.Wasi.Types,
  Wasm.Wat.Assembler;

const
  { The injected clock's fixed realtime, and the injected random's fill byte —
    determinism is the proof that the OS clock/CSPRNG were never consulted. }
  FIXED_NANOS = UInt64($0123456789ABCDEF);
  FIXED_RES = UInt64(7);
  FIXED_RANDOM_BYTE = $AB;

type
  { A clock that returns a fixed time regardless of clockid — a hermetic seam. }
  TFixedClock = class(TWasmWasiClock)
  public
    function TimeGet(const AClockId: UInt32;
      out ANanos: UInt64): TWasmWasiErrno; override;
    function ResGet(const AClockId: UInt32;
      out ANanos: UInt64): TWasmWasiErrno; override;
  end;

  { A random source that fills a constant pattern. }
  TFixedRandom = class(TWasmWasiRandom)
  public
    function Fill(const ABuf: PByte;
      const ALen: NativeUInt): TWasmWasiErrno; override;
  end;

function TFixedClock.TimeGet(const AClockId: UInt32;
  out ANanos: UInt64): TWasmWasiErrno;
begin
  ANanos := FIXED_NANOS;
  Result := weSuccess;
end;

function TFixedClock.ResGet(const AClockId: UInt32;
  out ANanos: UInt64): TWasmWasiErrno;
begin
  ANanos := FIXED_RES;
  Result := weSuccess;
end;

function TFixedRandom.Fill(const ABuf: PByte;
  const ALen: NativeUInt): TWasmWasiErrno;
var
  Index: NativeUInt;
  P: PByte;
begin
  P := ABuf;
  Index := 0;
  while Index < ALen do
  begin
    P^ := Byte(FIXED_RANDOM_BYTE);
    Inc(P);
    Inc(Index);
  end;
  Result := weSuccess;
end;

const
  { One module, imports the wave-1 set this suite asserts on, and exports a
    forwarding wrapper for each plus "memory". The wrappers just pass the
    host-supplied guest pointers straight through, so the host can lay out the
    guest memory itself and observe exactly what each wasi func does. }
  WASI_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "args_get"' + sLineBreak +
    '    (func $args_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "args_sizes_get"' + sLineBreak +
    '    (func $args_sizes_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "environ_get"' + sLineBreak +
    '    (func $environ_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "environ_sizes_get"' + sLineBreak +
    '    (func $environ_sizes_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_write"' + sLineBreak +
    '    (func $fd_write (param i32 i32 i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_read"' + sLineBreak +
    '    (func $fd_read (param i32 i32 i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_close"' + sLineBreak +
    '    (func $fd_close (param i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_fdstat_get"' + sLineBreak +
    '    (func $fd_fdstat_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_prestat_get"' + sLineBreak +
    '    (func $fd_prestat_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_prestat_dir_name"' + sLineBreak +
    '    (func $fd_prestat_dir_name (param i32 i32 i32) (result i32)))'
    + sLineBreak +
    '  (import "wasi_snapshot_preview1" "clock_time_get"' + sLineBreak +
    '    (func $clock_time_get (param i32 i64 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "clock_res_get"' + sLineBreak +
    '    (func $clock_res_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "random_get"' + sLineBreak +
    '    (func $random_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit"' + sLineBreak +
    '    (func $proc_exit (param i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "sched_yield"' + sLineBreak +
    '    (func $sched_yield (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "path_open"' + sLineBreak +
    '    (func $path_open' + sLineBreak +
    '      (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))'
    + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_filestat_get"' + sLineBreak +
    '    (func $fd_filestat_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "path_filestat_get"' + sLineBreak +
    '    (func $path_filestat_get (param i32 i32 i32 i32 i32) (result i32)))'
    + sLineBreak +
    '  (import "wasi_snapshot_preview1" "fd_readdir"' + sLineBreak +
    '    (func $fd_readdir (param i32 i32 i32 i64 i32) (result i32)))'
    + sLineBreak +
    '  (import "wasi_snapshot_preview1" "path_create_directory"' + sLineBreak +
    '    (func $path_create_directory (param i32 i32 i32) (result i32)))'
    + sLineBreak +
    '  (import "wasi_snapshot_preview1" "path_unlink_file"' + sLineBreak +
    '    (func $path_unlink_file (param i32 i32 i32) (result i32)))'
    + sLineBreak +
    '  (import "wasi_snapshot_preview1" "path_remove_directory"' + sLineBreak +
    '    (func $path_remove_directory (param i32 i32 i32) (result i32)))'
    + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "w_args_get") (param i32 i32) (result i32)' + sLineBreak +
    '    (call $args_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_args_sizes_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $args_sizes_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_environ_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $environ_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_environ_sizes_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $environ_sizes_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_fd_write") (param i32 i32 i32 i32) (result i32)'
    + sLineBreak +
    '    (call $fd_write (local.get 0) (local.get 1) (local.get 2)'
    + ' (local.get 3)))' + sLineBreak +
    '  (func (export "w_fd_read") (param i32 i32 i32 i32) (result i32)'
    + sLineBreak +
    '    (call $fd_read (local.get 0) (local.get 1) (local.get 2)'
    + ' (local.get 3)))' + sLineBreak +
    '  (func (export "w_fd_close") (param i32) (result i32)' + sLineBreak +
    '    (call $fd_close (local.get 0)))' + sLineBreak +
    '  (func (export "w_fd_fdstat_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $fd_fdstat_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_fd_prestat_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $fd_prestat_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_fd_prestat_dir_name") (param i32 i32 i32) (result i32)'
    + sLineBreak +
    '    (call $fd_prestat_dir_name (local.get 0) (local.get 1)'
    + ' (local.get 2)))' + sLineBreak +
    '  (func (export "w_clock_time_get") (param i32 i64 i32) (result i32)'
    + sLineBreak +
    '    (call $clock_time_get (local.get 0) (local.get 1) (local.get 2)))'
    + sLineBreak +
    '  (func (export "w_clock_res_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $clock_res_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_random_get") (param i32 i32) (result i32)' + sLineBreak +
    '    (call $random_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_proc_exit") (param i32)' + sLineBreak +
    '    (call $proc_exit (local.get 0)))' + sLineBreak +
    '  (func (export "w_sched_yield") (result i32)' + sLineBreak +
    '    (call $sched_yield))' + sLineBreak +
    '  (func (export "w_path_open")' + sLineBreak +
    '    (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)' + sLineBreak +
    '    (call $path_open (local.get 0) (local.get 1) (local.get 2)'
    + ' (local.get 3) (local.get 4) (local.get 5) (local.get 6)'
    + ' (local.get 7) (local.get 8)))' + sLineBreak +
    '  (func (export "w_fd_filestat_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $fd_filestat_get (local.get 0) (local.get 1)))' + sLineBreak +
    '  (func (export "w_path_filestat_get") (param i32 i32 i32 i32 i32)'
    + ' (result i32)' + sLineBreak +
    '    (call $path_filestat_get (local.get 0) (local.get 1) (local.get 2)'
    + ' (local.get 3) (local.get 4)))' + sLineBreak +
    '  (func (export "w_fd_readdir") (param i32 i32 i32 i64 i32) (result i32)'
    + sLineBreak +
    '    (call $fd_readdir (local.get 0) (local.get 1) (local.get 2)'
    + ' (local.get 3) (local.get 4)))' + sLineBreak +
    '  (func (export "w_path_create_directory") (param i32 i32 i32) (result i32)'
    + sLineBreak +
    '    (call $path_create_directory (local.get 0) (local.get 1)'
    + ' (local.get 2)))' + sLineBreak +
    '  (func (export "w_path_unlink_file") (param i32 i32 i32) (result i32)'
    + sLineBreak +
    '    (call $path_unlink_file (local.get 0) (local.get 1) (local.get 2)))'
    + sLineBreak +
    '  (func (export "w_path_remove_directory") (param i32 i32 i32) (result i32)'
    + sLineBreak +
    '    (call $path_remove_directory (local.get 0) (local.get 1)'
    + ' (local.get 2))))';

type
  TWasiTests = class(TTestSuite)
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FLoaded: TWasmLoadedModule;
    FLinker: TWasmLinker;
    FInstance: TWasmInstance;
    FConfig: TWasmWasiConfig;
    FContext: TWasmWasiContext;
    FMem: TWasmMemoryRef;
    FInjected: array of TObject;
    { A per-test host temp directory, created in BeforeEach and removed in
      AfterEach — the ONLY host filesystem a test touches, and only through the
      preopen (embedding-spec.md §7.3). Populated with hello.txt, a subdir, and
      (UNIX) an escaping symlink. }
    FTempDir: string;

    { Build the WASI context from AConfig, define all preview1 funcs,
      instantiate the wat module, and resolve its exported memory into the
      context. Leaves FInstance / FContext / FMem ready. AConfig becomes owned
      by the fixture. }
    procedure BuildRun(const AConfig: TWasmWasiConfig);
    function Wrapper(const AName: string): TWasmFunc;
    { Track a test-created injected object (clock/random) for teardown. }
    function Inject(const AObject: TObject): TObject;
    { Read a single guest byte for assertions. }
    function GuestByte(const AOffset: UInt64): Byte;
    { Write ABytes into guest memory at AOffset (test setup). }
    procedure GuestPut(const AOffset: UInt64; const ABytes: TBytes);
    { Write AStr's bytes into guest memory and return its length. }
    function GuestPutStr(const AOffset: UInt64; const AStr: string): UInt32;
    { A config that preopens FTempDir as "/sandbox" (fd 3) with ARights. }
    function SandboxConfig(const ARights: TWasmWasiRights): TWasmWasiConfig;
    { path_open helper: writes APath at guest 300, calls w_path_open, returns
      the errno; on success AOpenedFd holds the new fd read back from guest. }
    function DoPathOpen(const ADirFd: UInt32; const APath: string;
      const AOFlags, AFdFlags: UInt32; const ARights: TWasmWasiRights;
      out AOpenedFd: UInt32): Int32;
    procedure WriteHostFile(const APath: string; const AContent: string);
    function ReadHostFile(const APath: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestFdWriteToCapturedStdout;
    procedure TestFdWriteUnknownFdIsBadf;
    procedure TestFdWriteBadIoVecPointerIsFault;
    procedure TestArgs;
    procedure TestEnviron;
    procedure TestClockTimeGet;
    procedure TestClockResGet;
    procedure TestRandomGet;
    procedure TestProcExitRaisesExit;
    procedure TestSchedYield;
    procedure TestPrestatNoPreopenIsBadf;
    procedure TestPrestatWithPreopen;
    procedure TestPrestatDirName;
    procedure TestBadPointerIsFault;
    procedure TestFdRead;
    procedure TestFdCloseThenUse;

    { --- wave-2 (F4): filesystem via preopens (embedding-spec.md §7.3) --- }
    procedure TestPathOpenReadFile;
    procedure TestPathOpenCreateFile;
    procedure TestPathOpenEscapeDotDot;
    procedure TestPathOpenEscapeAbsolute;
    procedure TestPathOpenEscapeDeepDotDot;
    {$IFDEF UNIX}
    procedure TestPathOpenEscapeSymlink;
    {$ENDIF}
    procedure TestPathOpenFabricatedDirfdIsBadf;
    procedure TestPathOpenWithoutRightIsNotCapable;
    procedure TestFdFilestatGet;
    procedure TestPathFilestatGet;
    procedure TestFdReaddir;
    procedure TestPathCreateDirectory;
    procedure TestPathUnlinkFile;

    { --- security hardening (F1/F3/F4/F6) ------------------------------- }
    procedure TestPathOpenEmbeddedNulIsInval;
    procedure TestFdFilestatGetWithoutRightIsNotCapable;
    procedure TestPathOpenFdLimitIsMFile;
    {$IFDEF UNIX}
    procedure TestPathOpenCreateThroughDanglingSymlinkRefused;
    procedure TestPathOpenExistingThroughSymlinkRefused;
    {$ENDIF}

    { The CSPRNG DEFAULT (not injected): two random_get calls differ + fill. }
    procedure TestDefaultCsprngFillsAndDiffers;
  end;

{ --- fixture ------------------------------------------------------------- }

{ Recursively delete a host tree (files, symlinks, subdirs). Symlinks are
  removed as links (DeleteFile on the link), never followed. }
procedure RemoveTree(const APath: string);
var
  Sr: TSearchRec;
  Full: string;
begin
  if DirectoryExists(APath) then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, Sr) = 0
    then
    begin
      try
        repeat
          if (Sr.Name = '.') or (Sr.Name = '..') then
            Continue;
          Full := IncludeTrailingPathDelimiter(APath) + Sr.Name;
          { A directory that is NOT a symlink is recursed; everything else
            (files, and symlinks even to dirs) is unlinked directly.
            On UNIX faSymLink cannot be trusted: Darwin's FindFirst stats the
            entry, so a symlinked directory arrives as a plain directory and
            the attr guard would follow `escape -> /etc` and try to unlink
            system files. fpReadLink asks the question lstat does. Windows
            keeps the attr check — its FindFirst reports symlinks directly. }
          {$PUSH}{$WARN SYMBOL_PLATFORM OFF}
          {$IFDEF UNIX}
          if ((Sr.Attr and faDirectory) <> 0) and
            (fpReadLink(RawByteString(Full)) = '') then
          {$ELSE}
          if ((Sr.Attr and faDirectory) <> 0) and
            ((Sr.Attr and faSymLink) = 0) then
          {$ENDIF}
          {$POP}
            RemoveTree(Full)
          else
            DeleteFile(Full);
        until FindNext(Sr) <> 0;
      finally
        FindClose(Sr);
      end;
    end;
    RemoveDir(APath);
  end;
end;

{ A broad rights mask a preopen grants for the fs tests — combined at runtime
  because a WASI_RIGHTS_* is a typed const and FPC will not fold typed consts
  into another typed-const initializer (see Wasm.Wasi). }
function SandboxRights: TWasmWasiRights;
begin
  Result := WASI_RIGHTS_PATH_OPEN or WASI_RIGHTS_FD_READ or
    WASI_RIGHTS_FD_WRITE or WASI_RIGHTS_FD_SEEK or
    WASI_RIGHTS_FD_FILESTAT_GET or WASI_RIGHTS_FD_READDIR or
    WASI_RIGHTS_PATH_FILESTAT_GET or WASI_RIGHTS_PATH_CREATE_DIRECTORY or
    WASI_RIGHTS_PATH_UNLINK_FILE or WASI_RIGHTS_PATH_REMOVE_DIRECTORY;
end;

function MakeTempDir: string;
var
  Base: string;
  Attempt: Integer;
begin
  Base := IncludeTrailingPathDelimiter(GetTempDir);
  for Attempt := 0 to 999 do
  begin
    Result := Base + 'wasmlight_wasi_' + IntToStr(GetTickCount64) + '_' +
      IntToStr(Attempt);
    if not DirectoryExists(Result) and not FileExists(Result) then
      if CreateDir(Result) then
        Exit;
  end;
  raise EWasmError.Create('could not create a unique temp dir for the test');
end;

procedure TWasiTests.BeforeEach;
begin
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  EnsureInterpreter(FStore);
  FLoaded := LoadModule(AssembleWatText(WASI_WAT));
  FLinker := nil;
  FInstance := nil;
  FConfig := nil;
  FContext := nil;
  FInjected := nil;

  { The hermetic sandbox root: a fresh temp dir with a file and a subdir, plus
    (UNIX) a symlink escaping the sandbox for the containment negative. No
    network, no shared state (AGENTS.md, embedding-spec.md §7.3). }
  FTempDir := MakeTempDir;
  WriteHostFile(IncludeTrailingPathDelimiter(FTempDir) + 'hello.txt',
    'sandbox-data');
  CreateDir(IncludeTrailingPathDelimiter(FTempDir) + 'sub');
  {$IFDEF UNIX}
  { 'escape' -> /etc: a symlink INSIDE the preopen resolving OUTSIDE it. The
    containment re-check (realpath + IsPathUnder) must reject a path through
    it with weNotCapable. /etc exists on every POSIX host. }
  fpSymlink(PAnsiChar('/etc'),
    PAnsiChar(AnsiString(IncludeTrailingPathDelimiter(FTempDir) + 'escape')));
  {$ENDIF}
end;

procedure TWasiTests.AfterEach;
var
  Index: Integer;
begin
  { The store owns the instance and borrows the loaded module's bytes, so it is
    freed first; then the context (owns nothing), the linker, the config (frees
    its default streams/clock/random), the loaded module, the injected objects,
    and the engine last. }
  FInstance.Free;
  FContext.Free;
  FLinker.Free;
  FreeAndNil(FStore);
  FConfig.Free;
  FLoaded.Free;
  for Index := 0 to High(FInjected) do
    FInjected[Index].Free;
  FInjected := nil;
  FreeAndNil(FEngine);

  { Remove the whole sandbox tree — the test leaves nothing on the host. }
  if FTempDir <> '' then
    RemoveTree(FTempDir);
  FTempDir := '';
end;

procedure TWasiTests.BuildRun(const AConfig: TWasmWasiConfig);
begin
  FConfig := AConfig;
  FContext := TWasmWasiContext.Create(AConfig);
  FLinker := TWasmLinker.Create(FStore);
  WasiDefineAll(FLinker, FContext);
  FInstance := Instantiate(FStore, FLinker, FLoaded);
  if not FInstance.FindExportMemory('memory', FMem) then
    raise EWasmError.Create('the wasi test module must export memory');
  FContext.SetMemory(FMem);
end;

function TWasiTests.Wrapper(const AName: string): TWasmFunc;
begin
  if not FInstance.FindExportFunc(AName, Result) then
    raise EWasmError.CreateFmt('missing export %s', [AName]);
end;

function TWasiTests.Inject(const AObject: TObject): TObject;
begin
  Result := AObject;
  SetLength(FInjected, Length(FInjected) + 1);
  FInjected[High(FInjected)] := AObject;
end;

function TWasiTests.GuestByte(const AOffset: UInt64): Byte;
var
  B: array[0..0] of Byte;
begin
  B[0] := 0;
  if not MemRead(FMem, AOffset, 1, @B[0]) then
    raise EWasmError.Create('guest read out of bounds in a test assertion');
  Result := B[0];
end;

procedure TWasiTests.GuestPut(const AOffset: UInt64; const ABytes: TBytes);
begin
  if Length(ABytes) = 0 then
    Exit;
  if not MemWrite(FMem, AOffset, UInt64(Length(ABytes)), @ABytes[0]) then
    raise EWasmError.Create('guest write out of bounds in a test setup');
end;

function TWasiTests.GuestPutStr(const AOffset: UInt64;
  const AStr: string): UInt32;
var
  Bytes: TBytes;
  Index: Integer;
begin
  SetLength(Bytes, Length(AStr));
  for Index := 1 to Length(AStr) do
    Bytes[Index - 1] := Byte(AStr[Index]);
  GuestPut(AOffset, Bytes);
  Result := UInt32(Length(Bytes));
end;

function TWasiTests.SandboxConfig(
  const ARights: TWasmWasiRights): TWasmWasiConfig;
begin
  Result := TWasmWasiConfig.Create;
  Result.AddPreopenDir('/sandbox', FTempDir, ARights);
end;

function TWasiTests.DoPathOpen(const ADirFd: UInt32; const APath: string;
  const AOFlags, AFdFlags: UInt32; const ARights: TWasmWasiRights;
  out AOpenedFd: UInt32): Int32;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  PathLen: UInt32;
begin
  AOpenedFd := 0;
  PathLen := GuestPutStr(300, APath);
  Fn := Wrapper('w_path_open');
  SetLength(Args, 9);
  Args[0] := MakeValueI32(Int32(ADirFd));
  Args[1] := MakeValueI32(0);              { dirflags }
  Args[2] := MakeValueI32(300);            { path_ptr }
  Args[3] := MakeValueI32(Int32(PathLen)); { path_len }
  Args[4] := MakeValueI32(Int32(AOFlags));
  Args[5] := MakeValueI64(Int64(ARights)); { fs_rights_base }
  Args[6] := MakeValueI64(Int64(ARights)); { fs_rights_inheriting }
  Args[7] := MakeValueI32(Int32(AFdFlags));
  Args[8] := MakeValueI32(400);            { opened_fd_ptr }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Result := Results[0].I32;
  if Result = Ord(weSuccess) then
    if not MemReadU32(FMem, 400, AOpenedFd) then
      raise EWasmError.Create('opened_fd read out of bounds');
end;

procedure TWasiTests.WriteHostFile(const APath: string; const AContent: string);
var
  Stream: TFileStream;
  Bytes: TBytes;
  Index: Integer;
begin
  SetLength(Bytes, Length(AContent));
  for Index := 1 to Length(AContent) do
    Bytes[Index - 1] := Byte(AContent[Index]);
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

function TWasiTests.ReadHostFile(const APath: string): string;
var
  Stream: TFileStream;
  Bytes: TBytes;
  Index: Integer;
begin
  Result := '';
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Bytes[0], Stream.Size);
  finally
    Stream.Free;
  end;
  SetLength(Result, Length(Bytes));
  for Index := 0 to High(Bytes) do
    Result[Index + 1] := AnsiChar(Bytes[Index]);
end;

{ --- tests --------------------------------------------------------------- }

procedure TWasiTests.TestFdWriteToCapturedStdout;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Data: array[0..1] of Byte;
  NWritten: UInt32;
  Captured: TBytes;
begin
  { The hello-world path: guest fd_write(1, iovs, 1, nwritten) with the bytes
    "hi" — captured by the default in-memory stdout, no real stdout touched. }
  BuildRun(TWasmWasiConfig.Create);

  Data[0] := Byte('h');
  Data[1] := Byte('i');
  Expect<Boolean>(MemWrite(FMem, 100, 2, @Data[0])).ToBe(True);
  { ciovec at offset 0: buf=100, len=2. }
  Expect<Boolean>(MemWriteU32(FMem, 0, 100)).ToBe(True);
  Expect<Boolean>(MemWriteU32(FMem, 4, 2)).ToBe(True);

  Fn := Wrapper('w_fd_write');
  SetLength(Args, 4);
  Args[0] := MakeValueI32(1);   { fd 1 = stdout }
  Args[1] := MakeValueI32(0);   { iovs }
  Args[2] := MakeValueI32(1);   { iovs_len }
  Args[3] := MakeValueI32(8);   { nwritten_ptr }
  SetLength(Results, 1);
  Call(Fn, Args, Results);

  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 8, NWritten)).ToBe(True);
  Expect<Boolean>(NWritten = 2).ToBe(True);

  Captured := TWasmWasiBufferStream(FConfig.Stdout).WrittenBytes;
  Expect<Integer>(Length(Captured)).ToBe(2);
  Expect<Boolean>((Captured[0] = Byte('h')) and (Captured[1] = Byte('i')))
    .ToBe(True);
end;

procedure TWasiTests.TestFdWriteUnknownFdIsBadf;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_fd_write');
  SetLength(Args, 4);
  Args[0] := MakeValueI32(99);  { a fabricated fd }
  Args[1] := MakeValueI32(0);
  Args[2] := MakeValueI32(1);
  Args[3] := MakeValueI32(8);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weBadf));
end;

procedure TWasiTests.TestFdWriteBadIoVecPointerIsFault;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_fd_write');
  SetLength(Args, 4);
  Args[0] := MakeValueI32(1);
  Args[1] := MakeValueI32(Int32($FFFFFFF0));   { iovs array out of bounds }
  Args[2] := MakeValueI32(1);
  Args[3] := MakeValueI32(8);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weFault));
end;

procedure TWasiTests.TestArgs;
var
  Cfg: TWasmWasiConfig;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Argc, BufSize, P0, P1, P2: UInt32;
begin
  Cfg := TWasmWasiConfig.Create;
  Cfg.SetArgv(['prog', 'a', 'bb']);
  BuildRun(Cfg);

  { args_sizes_get -> argc, buf size. }
  Fn := Wrapper('w_args_sizes_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(0);   { argc_ptr }
  Args[1] := MakeValueI32(4);   { buf_size_ptr }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 0, Argc)).ToBe(True);
  Expect<Boolean>(MemReadU32(FMem, 4, BufSize)).ToBe(True);
  Expect<Boolean>(Argc = 3).ToBe(True);
  { 'prog'\0 + 'a'\0 + 'bb'\0 = 5 + 2 + 3 = 10. }
  Expect<Boolean>(BufSize = 10).ToBe(True);

  { args_get -> pointer array at 100, strings at 200. }
  Fn := Wrapper('w_args_get');
  Args[0] := MakeValueI32(100);
  Args[1] := MakeValueI32(200);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 100, P0)).ToBe(True);
  Expect<Boolean>(MemReadU32(FMem, 104, P1)).ToBe(True);
  Expect<Boolean>(MemReadU32(FMem, 108, P2)).ToBe(True);
  Expect<Boolean>(P0 = 200).ToBe(True);
  Expect<Boolean>(P1 = 205).ToBe(True);   { after 'prog'\0 }
  Expect<Boolean>(P2 = 207).ToBe(True);   { after 'a'\0 }
  { The bytes: "prog\0a\0bb\0". }
  Expect<Boolean>(GuestByte(200) = Byte('p')).ToBe(True);
  Expect<Boolean>(GuestByte(203) = Byte('g')).ToBe(True);
  Expect<Boolean>(GuestByte(204) = 0).ToBe(True);
  Expect<Boolean>(GuestByte(205) = Byte('a')).ToBe(True);
  Expect<Boolean>(GuestByte(206) = 0).ToBe(True);
  Expect<Boolean>(GuestByte(207) = Byte('b')).ToBe(True);
  Expect<Boolean>(GuestByte(209) = 0).ToBe(True);
end;

procedure TWasiTests.TestEnviron;
var
  Cfg: TWasmWasiConfig;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Count, BufSize, P0, P1: UInt32;
begin
  Cfg := TWasmWasiConfig.Create;
  Cfg.AddEnv('X=1');
  Cfg.AddEnv('HELLO=world');
  BuildRun(Cfg);

  Fn := Wrapper('w_environ_sizes_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(0);
  Args[1] := MakeValueI32(4);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 0, Count)).ToBe(True);
  Expect<Boolean>(MemReadU32(FMem, 4, BufSize)).ToBe(True);
  Expect<Boolean>(Count = 2).ToBe(True);
  { 'X=1'\0 + 'HELLO=world'\0 = 4 + 12 = 16. }
  Expect<Boolean>(BufSize = 16).ToBe(True);

  Fn := Wrapper('w_environ_get');
  Args[0] := MakeValueI32(100);
  Args[1] := MakeValueI32(200);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 100, P0)).ToBe(True);
  Expect<Boolean>(MemReadU32(FMem, 104, P1)).ToBe(True);
  Expect<Boolean>(P0 = 200).ToBe(True);
  Expect<Boolean>(P1 = 204).ToBe(True);   { after 'X=1'\0 }
  Expect<Boolean>(GuestByte(200) = Byte('X')).ToBe(True);
  Expect<Boolean>(GuestByte(201) = Byte('=')).ToBe(True);
  Expect<Boolean>(GuestByte(203) = 0).ToBe(True);
  Expect<Boolean>(GuestByte(204) = Byte('H')).ToBe(True);
end;

procedure TWasiTests.TestClockTimeGet;
const
  Expected: array[0..7] of Byte = ($EF, $CD, $AB, $89, $67, $45, $23, $01);
var
  Cfg: TWasmWasiConfig;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Nanos: UInt64;
  I: Integer;
begin
  Cfg := TWasmWasiConfig.Create;
  Cfg.Clock := TWasmWasiClock(Inject(TFixedClock.Create));
  BuildRun(Cfg);

  Fn := Wrapper('w_clock_time_get');
  SetLength(Args, 3);
  Args[0] := MakeValueI32(Int32(WASI_CLOCKID_REALTIME));
  Args[1] := MakeValueI64(0);   { precision (ignored) }
  Args[2] := MakeValueI32(0);   { time_ptr }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU64(FMem, 0, Nanos)).ToBe(True);
  Expect<Boolean>(Nanos = FIXED_NANOS).ToBe(True);
  { The WASI result pointer need not be naturally aligned. Judge its bytes
    directly so the u64 read helper cannot mask a matching endian defect. }
  Args[2] := MakeValueI32(3);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  for I := 0 to 7 do
    Expect<Byte>(GuestByte(UInt32(3 + I))).ToBe(Expected[I]);
  Args[2] := MakeValueI32(65528);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Args[2] := MakeValueI32(65529);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weFault));
  for I := 0 to 7 do
    Expect<Byte>(GuestByte(UInt32(65528 + I))).ToBe(Expected[I]);
end;

procedure TWasiTests.TestClockResGet;
var
  Cfg: TWasmWasiConfig;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Nanos: UInt64;
begin
  Cfg := TWasmWasiConfig.Create;
  Cfg.Clock := TWasmWasiClock(Inject(TFixedClock.Create));
  BuildRun(Cfg);

  Fn := Wrapper('w_clock_res_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(Int32(WASI_CLOCKID_MONOTONIC));
  Args[1] := MakeValueI32(0);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU64(FMem, 0, Nanos)).ToBe(True);
  Expect<Boolean>(Nanos = FIXED_RES).ToBe(True);
end;

procedure TWasiTests.TestRandomGet;
var
  Cfg: TWasmWasiConfig;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Index: Integer;
  AllFixed: Boolean;
begin
  Cfg := TWasmWasiConfig.Create;
  Cfg.Random := TWasmWasiRandom(Inject(TFixedRandom.Create));
  BuildRun(Cfg);

  Fn := Wrapper('w_random_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(0);   { buf_ptr }
  Args[1] := MakeValueI32(8);   { buf_len }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));

  AllFixed := True;
  for Index := 0 to 7 do
    if GuestByte(UInt64(Index)) <> Byte(FIXED_RANDOM_BYTE) then
      AllFixed := False;
  Expect<Boolean>(AllFixed).ToBe(True);
end;

procedure TWasiTests.TestProcExitRaisesExit;
var
  Fn: TWasmFunc;
  Args, NoResults: array of TWasmValue;
  Caught: Boolean;
  Code: Int32;
begin
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_proc_exit');
  SetLength(Args, 1);
  Args[0] := MakeValueI32(42);
  NoResults := nil;

  Caught := False;
  Code := -1;
  try
    Call(Fn, Args, NoResults);
  except
    on E: EWasmExit do
    begin
      Caught := True;
      Code := E.ExitCode;
    end;
  end;
  Expect<Boolean>(Caught).ToBe(True);
  Expect<Int32>(Code).ToBe(42);
  { The context also recorded it (embedding-spec.md §6.1). }
  Expect<Int32>(FContext.ExitCode).ToBe(42);
end;

procedure TWasiTests.TestSchedYield;
var
  Fn: TWasmFunc;
  NoArgs, Results: array of TWasmValue;
begin
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_sched_yield');
  NoArgs := nil;
  SetLength(Results, 1);
  Call(Fn, NoArgs, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
end;

procedure TWasiTests.TestPrestatNoPreopenIsBadf;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  { Deny-by-default: no preopens configured, so fd 3 is not in the table and
    fd_prestat_get is weBadf — which is how libc terminates preopen discovery
    (embedding-spec.md §7.3, §9.3). }
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_fd_prestat_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(3);
  Args[1] := MakeValueI32(0);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weBadf));
end;

procedure TWasiTests.TestPrestatWithPreopen;
var
  Cfg: TWasmWasiConfig;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Tag: Byte;
  NameLen: UInt32;
begin
  Cfg := TWasmWasiConfig.Create;
  Cfg.AddPreopenDir('/sandbox', '/tmp/whatever', WASI_RIGHTS_PATH_OPEN);
  BuildRun(Cfg);

  Fn := Wrapper('w_fd_prestat_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(3);   { the first preopen }
  Args[1] := MakeValueI32(0);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));

  Tag := GuestByte(UInt64(WASI_PRESTAT_TAG_OFF));
  Expect<Integer>(Integer(Tag)).ToBe(WASI_PREOPENTYPE_DIR);
  Expect<Boolean>(MemReadU32(FMem, UInt64(WASI_PRESTAT_DIR_NAMELEN_OFF),
    NameLen)).ToBe(True);
  { '/sandbox' is 8 bytes. }
  Expect<Boolean>(NameLen = 8).ToBe(True);
end;

procedure TWasiTests.TestPrestatDirName;
var
  Cfg: TWasmWasiConfig;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  Cfg := TWasmWasiConfig.Create;
  Cfg.AddPreopenDir('/sandbox', '/tmp/whatever', WASI_RIGHTS_PATH_OPEN);
  BuildRun(Cfg);

  Fn := Wrapper('w_fd_prestat_dir_name');
  SetLength(Args, 3);
  Args[0] := MakeValueI32(3);
  Args[1] := MakeValueI32(100);   { path_ptr }
  Args[2] := MakeValueI32(8);     { path_len = exact name length }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(GuestByte(100) = Byte('/')).ToBe(True);
  Expect<Boolean>(GuestByte(101) = Byte('s')).ToBe(True);
  Expect<Boolean>(GuestByte(107) = Byte('x')).ToBe(True);

  { A buffer smaller than the name is weNameTooLong. }
  Args[2] := MakeValueI32(3);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weNameTooLong));
end;

procedure TWasiTests.TestBadPointerIsFault;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  { A result pointer far past the one-page memory: the function computes its
    answer but cannot deliver it, so weFault — never a host OOB write. }
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_args_sizes_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(Int32($FFFFFFF0));   { argc_ptr out of bounds }
  Args[1] := MakeValueI32(0);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weFault));
end;

procedure TWasiTests.TestFdRead;
var
  Cfg: TWasmWasiConfig;
  Stdin: TWasmWasiBufferStream;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Input: TBytes;
  NRead: UInt32;
begin
  { fd_read from an injected stdin buffer into a guest iovec. }
  Cfg := TWasmWasiConfig.Create;
  Stdin := TWasmWasiBufferStream(Cfg.Stdin);
  SetLength(Input, 3);
  Input[0] := Byte('a');
  Input[1] := Byte('b');
  Input[2] := Byte('c');
  Stdin.SetInputBytes(Input);
  BuildRun(Cfg);

  { iovec at 0: buf=100, len=16. }
  Expect<Boolean>(MemWriteU32(FMem, 0, 100)).ToBe(True);
  Expect<Boolean>(MemWriteU32(FMem, 4, 16)).ToBe(True);
  Fn := Wrapper('w_fd_read');
  SetLength(Args, 4);
  Args[0] := MakeValueI32(0);   { fd 0 = stdin }
  Args[1] := MakeValueI32(0);   { iovs }
  Args[2] := MakeValueI32(1);
  Args[3] := MakeValueI32(200); { nread_ptr }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 200, NRead)).ToBe(True);
  Expect<Boolean>(NRead = 3).ToBe(True);
  Expect<Boolean>(GuestByte(100) = Byte('a')).ToBe(True);
  Expect<Boolean>(GuestByte(102) = Byte('c')).ToBe(True);
end;

procedure TWasiTests.TestFdCloseThenUse;
var
  Fn, WriteFn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  { Closing fd 1 frees the slot; a subsequent fd_write to it is weBadf. }
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_fd_close');
  SetLength(Args, 1);
  Args[0] := MakeValueI32(1);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));

  { iovec at 0 so the fault, if any, is not the pointer. }
  Expect<Boolean>(MemWriteU32(FMem, 0, 100)).ToBe(True);
  Expect<Boolean>(MemWriteU32(FMem, 4, 0)).ToBe(True);
  WriteFn := Wrapper('w_fd_write');
  SetLength(Args, 4);
  Args[0] := MakeValueI32(1);
  Args[1] := MakeValueI32(0);
  Args[2] := MakeValueI32(1);
  Args[3] := MakeValueI32(8);
  Call(WriteFn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weBadf));
end;

{ --- wave-2 (F4): filesystem via preopens -------------------------------- }

procedure TWasiTests.TestPathOpenReadFile;
var
  Fd: TWasmFunc;
  Args, Results: array of TWasmValue;
  OpenedFd, NRead: UInt32;
  Contents: string;
  Index: Integer;
begin
  { Open hello.txt under the preopen and read it back — the fs happy path. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, 'hello.txt', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weSuccess));
  { First opened fd sits after stdio (0/1/2) and the preopen (3). }
  Expect<Boolean>(OpenedFd = 4).ToBe(True);

  { iovec at 0: buf=100, len=32. }
  Expect<Boolean>(MemWriteU32(FMem, 0, 100)).ToBe(True);
  Expect<Boolean>(MemWriteU32(FMem, 4, 32)).ToBe(True);
  Fd := Wrapper('w_fd_read');
  SetLength(Args, 4);
  Args[0] := MakeValueI32(Int32(OpenedFd));
  Args[1] := MakeValueI32(0);
  Args[2] := MakeValueI32(1);
  Args[3] := MakeValueI32(200);
  SetLength(Results, 1);
  Call(Fd, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 200, NRead)).ToBe(True);
  Expect<Boolean>(NRead = 12).ToBe(True);
  SetLength(Contents, 12);
  for Index := 0 to 11 do
    Contents[Index + 1] := AnsiChar(GuestByte(UInt64(100 + Index)));
  Expect<Boolean>(Contents = 'sandbox-data').ToBe(True);
end;

procedure TWasiTests.TestPathOpenCreateFile;
var
  Fd: TWasmFunc;
  Args, Results: array of TWasmValue;
  OpenedFd: UInt32;
  HostPath: string;
begin
  { CREAT|TRUNC a new file, write to it, and assert on the HOST side. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, 'new.txt',
    WASI_OFLAGS_CREAT or WASI_OFLAGS_TRUNC, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weSuccess));

  { ciovec at 0: buf=100, len=7 ("created"). }
  GuestPutStr(100, 'created');
  Expect<Boolean>(MemWriteU32(FMem, 0, 100)).ToBe(True);
  Expect<Boolean>(MemWriteU32(FMem, 4, 7)).ToBe(True);
  Fd := Wrapper('w_fd_write');
  SetLength(Args, 4);
  Args[0] := MakeValueI32(Int32(OpenedFd));
  Args[1] := MakeValueI32(0);
  Args[2] := MakeValueI32(1);
  Args[3] := MakeValueI32(200);
  SetLength(Results, 1);
  Call(Fd, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));

  Fd := Wrapper('w_fd_close');
  SetLength(Args, 1);
  Args[0] := MakeValueI32(Int32(OpenedFd));
  Call(Fd, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));

  HostPath := IncludeTrailingPathDelimiter(FTempDir) + 'new.txt';
  Expect<Boolean>(FileExists(HostPath)).ToBe(True);
  Expect<Boolean>(ReadHostFile(HostPath) = 'created').ToBe(True);
end;

procedure TWasiTests.TestPathOpenEscapeDotDot;
var
  OpenedFd: UInt32;
begin
  { THE SANDBOX: a "../escape" path is refused with weNotCapable. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, '../escape.txt', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weNotCapable));
end;

procedure TWasiTests.TestPathOpenEscapeAbsolute;
var
  OpenedFd: UInt32;
begin
  { An absolute path never reaches outside the preopen: weNotCapable. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, '/etc/passwd', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weNotCapable));
end;

procedure TWasiTests.TestPathOpenEscapeDeepDotDot;
var
  OpenedFd: UInt32;
begin
  { A deep escape "sub/../../escape" that nets above the root is rejected. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, 'sub/../../escape', 0, 0, SandboxRights,
    OpenedFd)).ToBe(Ord(weNotCapable));
end;

{$IFDEF UNIX}
procedure TWasiTests.TestPathOpenEscapeSymlink;
var
  OpenedFd: UInt32;
begin
  { A symlink INSIDE the preopen ('escape' -> /etc) resolving OUTSIDE it must
    not escape: the realpath containment re-check rejects it with
    weNotCapable. This is the symlink half of the sandbox proof. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, 'escape', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weNotCapable));
end;
{$ENDIF}

procedure TWasiTests.TestPathOpenFabricatedDirfdIsBadf;
var
  OpenedFd: UInt32;
begin
  { A dirfd the guest never received is weBadf. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(99, 'hello.txt', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weBadf));
end;

procedure TWasiTests.TestPathOpenWithoutRightIsNotCapable;
var
  OpenedFd: UInt32;
begin
  { The preopen lacks rights_path_open, so even a valid contained path is
    weNotCapable — the deny-by-default rights gate. }
  BuildRun(SandboxConfig(WASI_RIGHTS_FD_READ));
  Expect<Int32>(DoPathOpen(3, 'hello.txt', 0, 0, WASI_RIGHTS_FD_READ, OpenedFd))
    .ToBe(Ord(weNotCapable));
end;

procedure TWasiTests.TestFdFilestatGet;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  OpenedFd: UInt32;
  Size: UInt64;
begin
  { fd_filestat_get on the opened file reports REGULAR_FILE and size 12. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, 'hello.txt', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weSuccess));

  Fn := Wrapper('w_fd_filestat_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(Int32(OpenedFd));
  Args[1] := MakeValueI32(500);   { filestat buf }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Integer>(Integer(GuestByte(UInt64(500 + WASI_FILESTAT_FILETYPE_OFF))))
    .ToBe(WASI_FILETYPE_REGULAR_FILE);
  Expect<Boolean>(MemReadU64(FMem, UInt64(500 + WASI_FILESTAT_SIZE_OFF), Size))
    .ToBe(True);
  Expect<Boolean>(Size = 12).ToBe(True);
end;

procedure TWasiTests.TestPathFilestatGet;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  PathLen: UInt32;
  Size: UInt64;
begin
  { path_filestat_get stats a contained path without opening it. }
  BuildRun(SandboxConfig(SandboxRights));
  PathLen := GuestPutStr(300, 'hello.txt');
  Fn := Wrapper('w_path_filestat_get');
  SetLength(Args, 5);
  Args[0] := MakeValueI32(3);
  Args[1] := MakeValueI32(0);              { flags }
  Args[2] := MakeValueI32(300);
  Args[3] := MakeValueI32(Int32(PathLen));
  Args[4] := MakeValueI32(500);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU64(FMem, UInt64(500 + WASI_FILESTAT_SIZE_OFF), Size))
    .ToBe(True);
  Expect<Boolean>(Size = 12).ToBe(True);

  { A contained-but-escaping path is still weNotCapable here too. }
  PathLen := GuestPutStr(300, '../escape');
  Args[3] := MakeValueI32(Int32(PathLen));
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weNotCapable));
end;

procedure TWasiTests.TestFdReaddir;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  BufUsed, NameLen, Off: UInt32;
  Buf: TBytes;
  Name: string;
  Index: Integer;
  SawHello, SawSub: Boolean;
begin
  { fd_readdir on the preopen lists its entries (plus "." / ".."). }
  BuildRun(SandboxConfig(SandboxRights));
  Fn := Wrapper('w_fd_readdir');
  SetLength(Args, 5);
  Args[0] := MakeValueI32(3);      { the preopen dir }
  Args[1] := MakeValueI32(600);    { buf }
  Args[2] := MakeValueI32(400);    { buf_len }
  Args[3] := MakeValueI64(0);      { cookie }
  Args[4] := MakeValueI32(590);    { bufused_ptr }
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(MemReadU32(FMem, 590, BufUsed)).ToBe(True);
  Expect<Boolean>(BufUsed > 0).ToBe(True);

  SetLength(Buf, BufUsed);
  Expect<Boolean>(MemRead(FMem, 600, UInt64(BufUsed), @Buf[0])).ToBe(True);
  { Walk the dirent records: 24-byte header (d_namlen @16) then the name. }
  SawHello := False;
  SawSub := False;
  Off := 0;
  while (Off + UInt32(WASI_DIRENT_SIZE)) <= BufUsed do
  begin
    NameLen := UInt32(Buf[Off + WASI_DIRENT_NAMLEN_OFF]) or
      (UInt32(Buf[Off + WASI_DIRENT_NAMLEN_OFF + 1]) shl 8) or
      (UInt32(Buf[Off + WASI_DIRENT_NAMLEN_OFF + 2]) shl 16) or
      (UInt32(Buf[Off + WASI_DIRENT_NAMLEN_OFF + 3]) shl 24);
    if (Off + UInt32(WASI_DIRENT_SIZE) + NameLen) > BufUsed then
      Break;
    SetLength(Name, NameLen);
    for Index := 0 to Integer(NameLen) - 1 do
      Name[Index + 1] := AnsiChar(Buf[Off + UInt32(WASI_DIRENT_SIZE) +
        UInt32(Index)]);
    if Name = 'hello.txt' then
      SawHello := True;
    if Name = 'sub' then
      SawSub := True;
    Off := Off + UInt32(WASI_DIRENT_SIZE) + NameLen;
  end;
  Expect<Boolean>(SawHello).ToBe(True);
  Expect<Boolean>(SawSub).ToBe(True);
end;

procedure TWasiTests.TestPathCreateDirectory;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  PathLen: UInt32;
begin
  { path_create_directory lands a new dir under the preopen, on the host. }
  BuildRun(SandboxConfig(SandboxRights));
  PathLen := GuestPutStr(300, 'newdir');
  Fn := Wrapper('w_path_create_directory');
  SetLength(Args, 3);
  Args[0] := MakeValueI32(3);
  Args[1] := MakeValueI32(300);
  Args[2] := MakeValueI32(Int32(PathLen));
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(DirectoryExists(IncludeTrailingPathDelimiter(FTempDir) +
    'newdir')).ToBe(True);

  { An escaping create is refused. }
  PathLen := GuestPutStr(300, '../evil');
  Args[2] := MakeValueI32(Int32(PathLen));
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weNotCapable));
end;

procedure TWasiTests.TestPathUnlinkFile;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  PathLen: UInt32;
  HostPath: string;
begin
  { path_unlink_file removes a contained file; the host loses it. }
  HostPath := IncludeTrailingPathDelimiter(FTempDir) + 'todelete.txt';
  WriteHostFile(HostPath, 'x');
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Boolean>(FileExists(HostPath)).ToBe(True);

  PathLen := GuestPutStr(300, 'todelete.txt');
  Fn := Wrapper('w_path_unlink_file');
  SetLength(Args, 3);
  Args[0] := MakeValueI32(3);
  Args[1] := MakeValueI32(300);
  Args[2] := MakeValueI32(Int32(PathLen));
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
  Expect<Boolean>(FileExists(HostPath)).ToBe(False);
end;

procedure TWasiTests.TestPathOpenEmbeddedNulIsInval;
var
  OpenedFd: UInt32;
begin
  { F3: a guest path carrying an embedded NUL ("hello.txt\0evil") must be
    rejected with weInval BEFORE use — otherwise a downstream PAnsiChar cast
    truncates it to "hello.txt" and the guest silently operates on a name it
    never actually asked for. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, 'hello.txt'#0'evil', 0, 0, SandboxRights,
    OpenedFd)).ToBe(Ord(weInval));
end;

procedure TWasiTests.TestFdFilestatGetWithoutRightIsNotCapable;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  OpenedFd: UInt32;
begin
  { F6: an fd opened WITHOUT fd_filestat_get in its rights cannot be statted —
    weNotCapable — even though the preopen could have granted the right. The
    preopen inherits the broad set, but path_open requests only FD_READ, so the
    derived fd's rights lack FD_FILESTAT_GET. }
  BuildRun(SandboxConfig(SandboxRights));
  Expect<Int32>(DoPathOpen(3, 'hello.txt', 0, 0, WASI_RIGHTS_FD_READ, OpenedFd))
    .ToBe(Ord(weSuccess));

  Fn := Wrapper('w_fd_filestat_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(Int32(OpenedFd));
  Args[1] := MakeValueI32(500);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weNotCapable));
end;

procedure TWasiTests.TestPathOpenFdLimitIsMFile;
var
  OpenedFd: UInt32;
begin
  { F4: with the open-fd cap set low, opening past it is weMFile (EMFILE), so a
    guest holding a preopen cannot exhaust host descriptors. Used before any
    open: fds 0/1/2 (stdio) + 3 (preopen) = 4. Cap = 5 allows exactly one more
    open (fd 4); the next is refused. }
  BuildRun(SandboxConfig(SandboxRights));
  FContext.MaxOpenFds := 5;
  Expect<Int32>(DoPathOpen(3, 'hello.txt', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weSuccess));
  Expect<Boolean>(OpenedFd = 4).ToBe(True);
  { The table is now at the cap; a further open is weMFile. }
  Expect<Int32>(DoPathOpen(3, 'hello.txt', 0, 0, SandboxRights, OpenedFd))
    .ToBe(Ord(weMfile));
end;

{$IFDEF UNIX}
procedure TWasiTests.TestPathOpenCreateThroughDanglingSymlinkRefused;
var
  OpenedFd: UInt32;
  Target, LinkPath: string;
begin
  { F1 (the containment hole): a DANGLING symlink inside the preopen naming a
    target OUTSIDE it. realpath cannot resolve a dangling link, so containment
    validated only the parent and O_CREAT would FileCreate through the link,
    writing outside the sandbox. The lstat-the-leaf guard refuses it
    (weNotCapable) and NO file is created at the outside target. }
  BuildRun(SandboxConfig(SandboxRights));
  Target := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight_escape_' + IntToStr(GetTickCount64) + '.txt';
  DeleteFile(Target);   { ensure it is absent to start }
  LinkPath := IncludeTrailingPathDelimiter(FTempDir) + 'evil';
  fpSymlink(PAnsiChar(AnsiString(Target)), PAnsiChar(AnsiString(LinkPath)));
  try
    Expect<Int32>(DoPathOpen(3, 'evil', WASI_OFLAGS_CREAT, 0, SandboxRights,
      OpenedFd)).ToBe(Ord(weNotCapable));
    { The outside target must NOT have been created through the link. }
    Expect<Boolean>(FileExists(Target)).ToBe(False);
  finally
    DeleteFile(Target);
    DeleteFile(LinkPath);
  end;
end;

procedure TWasiTests.TestPathOpenExistingThroughSymlinkRefused;
var
  OpenedFd: UInt32;
  Target, LinkPath: string;
begin
  { F1 companion: a NON-dangling symlink whose final component resolves to an
    EXISTING file OUTSIDE the preopen must not open it either. Here realpath
    resolves the link to the outside target and the containment re-check
    (IsPathUnder) rejects it — weNotCapable — with no create involved. }
  BuildRun(SandboxConfig(SandboxRights));
  Target := IncludeTrailingPathDelimiter(GetTempDir) +
    'wasmlight_target_' + IntToStr(GetTickCount64) + '.txt';
  WriteHostFile(Target, 'outside-secret');
  LinkPath := IncludeTrailingPathDelimiter(FTempDir) + 'linkout';
  fpSymlink(PAnsiChar(AnsiString(Target)), PAnsiChar(AnsiString(LinkPath)));
  try
    Expect<Int32>(DoPathOpen(3, 'linkout', 0, 0, SandboxRights, OpenedFd))
      .ToBe(Ord(weNotCapable));
  finally
    DeleteFile(Target);
    DeleteFile(LinkPath);
  end;
end;
{$ENDIF}

procedure TWasiTests.TestDefaultCsprngFillsAndDiffers;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Index: Integer;
  Differ, AnyNonZero: Boolean;
begin
  { The DEFAULT random source (a real platform CSPRNG, NOT injected): two
    16-byte fills must differ and not be all-zero. Non-deterministic on
    purpose — this is the one test that reads real entropy (embedding-spec.md
    §2.2); the deterministic logic is covered by the injected-seam tests. }
  BuildRun(TWasmWasiConfig.Create);
  Fn := Wrapper('w_random_get');
  SetLength(Args, 2);
  SetLength(Results, 1);

  Args[0] := MakeValueI32(0);
  Args[1] := MakeValueI32(16);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));

  Args[0] := MakeValueI32(16);
  Args[1] := MakeValueI32(16);
  Call(Fn, Args, Results);
  Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));

  Differ := False;
  AnyNonZero := False;
  for Index := 0 to 15 do
  begin
    if GuestByte(UInt64(Index)) <> GuestByte(UInt64(16 + Index)) then
      Differ := True;
    if (GuestByte(UInt64(Index)) <> 0) or (GuestByte(UInt64(16 + Index)) <> 0)
    then
      AnyNonZero := True;
  end;
  Expect<Boolean>(Differ).ToBe(True);
  Expect<Boolean>(AnyNonZero).ToBe(True);
end;

procedure TWasiTests.SetupTests;
begin
  Test('fd_write(1) lands in the captured stdout buffer (hello-world)',
    TestFdWriteToCapturedStdout);
  Test('fd_write to an unknown fd is weBadf', TestFdWriteUnknownFdIsBadf);
  Test('fd_write with a bad iovec pointer is weFault',
    TestFdWriteBadIoVecPointerIsFault);
  Test('args_get / args_sizes_get return the injected argv', TestArgs);
  Test('environ_get / environ_sizes_get return the injected env', TestEnviron);
  Test('clock_time_get returns the injected fixed time', TestClockTimeGet);
  Test('clock_res_get returns the injected fixed resolution', TestClockResGet);
  Test('random_get writes the injected fixed bytes', TestRandomGet);
  Test('proc_exit raises EWasmExit with the code', TestProcExitRaisesExit);
  Test('sched_yield returns weSuccess', TestSchedYield);
  Test('fd_prestat_get with no preopens is weBadf for fd 3',
    TestPrestatNoPreopenIsBadf);
  Test('fd_prestat_get advertises a configured preopen',
    TestPrestatWithPreopen);
  Test('fd_prestat_dir_name writes the guest path', TestPrestatDirName);
  Test('a bad guest result pointer is weFault, not a crash',
    TestBadPointerIsFault);
  Test('fd_read fills a guest iovec from injected stdin', TestFdRead);
  Test('fd_write to a closed fd is weBadf', TestFdCloseThenUse);

  { wave-2 (F4): filesystem via preopens + the containment negatives. }
  Test('path_open + fd_read reads a file under the preopen',
    TestPathOpenReadFile);
  Test('path_open CREAT writes a new file, verified on the host',
    TestPathOpenCreateFile);
  Test('path_open "../escape" is weNotCapable (the sandbox)',
    TestPathOpenEscapeDotDot);
  Test('path_open "/etc/passwd" (absolute) is weNotCapable',
    TestPathOpenEscapeAbsolute);
  Test('path_open "sub/../../escape" (deep ..) is weNotCapable',
    TestPathOpenEscapeDeepDotDot);
  {$IFDEF UNIX}
  Test('path_open through an escaping symlink is weNotCapable',
    TestPathOpenEscapeSymlink);
  {$ENDIF}
  Test('path_open with a fabricated dirfd is weBadf',
    TestPathOpenFabricatedDirfdIsBadf);
  Test('path_open without rights_path_open is weNotCapable',
    TestPathOpenWithoutRightIsNotCapable);
  Test('fd_filestat_get reports the file size and type', TestFdFilestatGet);
  Test('path_filestat_get stats a contained path; escape is weNotCapable',
    TestPathFilestatGet);
  Test('fd_readdir lists the preopen directory entries', TestFdReaddir);
  Test('path_create_directory creates under the preopen; escape refused',
    TestPathCreateDirectory);
  Test('path_unlink_file removes a contained file', TestPathUnlinkFile);

  { security hardening (F1/F3/F4/F6). }
  Test('path_open with an embedded-NUL path is weInval',
    TestPathOpenEmbeddedNulIsInval);
  Test('fd_filestat_get without the right is weNotCapable',
    TestFdFilestatGetWithoutRightIsNotCapable);
  Test('path_open past the open-fd cap is weMFile',
    TestPathOpenFdLimitIsMFile);
  {$IFDEF UNIX}
  Test('path_open CREAT through a dangling escaping symlink is weNotCapable',
    TestPathOpenCreateThroughDanglingSymlinkRefused);
  Test('path_open through a symlink to an existing outside file is weNotCapable',
    TestPathOpenExistingThroughSymlinkRefused);
  {$ENDIF}

  Test('the default CSPRNG fills the buffer and two calls differ',
    TestDefaultCsprngFillsAndDiffers);
end;

begin
  TestRunnerProgram.AddSuite(TWasiTests.Create('Wasm.Wasi'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
