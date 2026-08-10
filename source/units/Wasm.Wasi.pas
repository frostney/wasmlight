{ Wasm.Wasi — the wasi_snapshot_preview1 host module, and the capability set
  that is the OTHER half of the sandbox boundary (embedding-spec.md §2, §3, §9).

  Every WASI function here is an ordinary host function over Wasm.Engine: it
  reads its guest-pointer arguments through Wasm.Wasi.Memory (never Base, never
  raw pointer math — embedding-spec.md §3.2), performs a deny-by-default
  capability check, and returns a wasi errno as an i32 (embedding-spec.md §6.3).
  proc_exit is the one exception: it raises EWasmExit (a clean, guest-requested
  exit — NOT a trap, NOT a wasm exception; embedding-spec.md §6.1), which
  Wasm.Engine's Call trampoline carries out unchanged.

  THE TWO THINGS THAT MAKE THIS A SANDBOX (embedding-spec.md §9.2):

    1. The memory chokepoint. Every guest offset (iovec pointers, result-struct
       pointers, argv/environ buffers, random_get's target) is touched only
       through Wasm.Wasi.Memory's bounds-checked, overflow-safe accessors. A
       bad pointer is weFault, never a host OOB read.
    2. The capability checks. A fd is a std stream, a preopen, or derived from
       one; a fabricated fd is weBadf. clock/random are present only if the
       embedder granted them, else weNotCapable. There is NO code path from a
       guest call to a host resource that does not pass an embedder-granted
       entry — that absence is the sandbox.

  DENY-BY-DEFAULT (AGENTS.md, ADR-0002 via ADR-0014). A default TWasmWasiConfig
  grants the three std streams (fd 0/1/2, backed by capturable in-memory
  buffers so a test never touches the real process stdio) and an OS clock +
  random; it grants NO filesystem (no preopens), NO environment, and argv only
  as the embedder sets it. Preopened directories are the ONLY route to the
  filesystem, and none exist unless the embedder adds one. The clock and random
  seams are injectable, so a hermetic unit test replaces them with fixed values
  and nothing in a WASI test touches the real clock, entropy, fs, or network.

  WAVE SCOPE (embedding-spec.md §3.3, §8.2). This is F2: the wave-1 MUST tier —
  args/environ, fd_write/read/close/seek/fdstat/prestat, clock, random,
  proc_exit, sched_yield. The wave-2 filesystem functions (path_open and the
  file ops, behind preopen containment) are F4, and the wave-3 long tail is
  stubbed ENOSYS in F5. A module importing only the wave-1 set links and runs
  today; one importing a wave-2 function fails to link until F4 (which is the
  honest deny-by-default posture — an undefined import is an EWasmLinkError, not
  a silent no-op).

  SOURCE for the preview1 ABI (signatures, struct layouts, errno numbering):
  the frozen wasi_snapshot_preview1 witx, consumed through Wasm.Wasi.Types
  (embedding-spec.md §0 WASI pin) — WASI is not in the wasm MCP. Signatures are
  the well-established preview1 shapes; any that F5's wasi-testsuite might still
  correct are marked UNCONFIRMED at their definition.

  Layering (embedding-spec.md §8.1): depends on Wasm.Engine, Wasm.Wasi.Memory,
  Wasm.Wasi.Types, and the store/values it marshals through — nothing else.

  Spec pin (core, for the embedding anchors this rests on): wasm-mcp 0.2.16,
  spec/main d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004). }
unit Wasm.Wasi;

{$I Shared.inc}
{ The host callbacks index the PWasmValue param/result slices directly, the
  same way Wasm.Engine's own host-func tests do. }
{$POINTERMATH ON}

interface

uses
  SysUtils,
  {$IFDEF UNIX}
  { The default clock/CSPRNG and the filesystem functions reach the host OS
    only here, under UNIX, via BaseUnix (/dev/urandom, FpStat, fpSymlink) and a
    handful of libc externals (clock_gettime, realpath) declared in the
    implementation. Every fs access is still containment-checked before it
    touches a real path (embedding-spec.md §5.3, §9.2). }
  BaseUnix,
  {$ENDIF}
  Wasm.Core,
  Wasm.Engine,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Wasi.Memory,
  Wasm.Wasi.Types;

type
  { --- injectable seams (embedding-spec.md §2.1, §2.3) ------------------- }

  { A byte sink/source the host controls — the seam that makes fd_write to
    "stdout" testable without a real stdout. WriteBytes returns the count
    actually written; ReadBytes fills up to AMax and returns the count read (0
    = EOF). }
  TWasmWasiStream = class
  public
    function WriteBytes(const ABuf: PByte;
      const ALen: NativeUInt): NativeUInt; virtual; abstract;
    function ReadBytes(const ABuf: PByte;
      const AMax: NativeUInt): NativeUInt; virtual; abstract;
    { True for a tty; drives fdstat/isatty-style queries. Default: not a tty. }
    function IsTerminal: Boolean; virtual;
  end;

  { An in-memory stream: writes accumulate (a captured stdout/stderr), reads
    consume a preloaded input buffer (an injected stdin). The two are separate
    stores, so one object can serve either role without aliasing. This is the
    default backing for a config's std streams and the capture point every
    hermetic fd_write test asserts against. }
  TWasmWasiBufferStream = class(TWasmWasiStream)
  private
    FWritten: TBytes;
    FInput: TBytes;
    FInputPos: NativeUInt;
  public
    function WriteBytes(const ABuf: PByte;
      const ALen: NativeUInt): NativeUInt; override;
    function ReadBytes(const ABuf: PByte;
      const AMax: NativeUInt): NativeUInt; override;

    { Preload the bytes a subsequent ReadBytes (an injected stdin) hands out. }
    procedure SetInputBytes(const ABytes: TBytes);
    { A copy of everything WriteBytes has accumulated — the captured output. }
    function WrittenBytes: TBytes;
    function WrittenCount: NativeUInt;
    procedure Clear;
  end;

  { The clock seam. TimeGet returns nanoseconds (since the Unix epoch for
    REALTIME, monotonic ns otherwise); ResGet the clock's resolution in ns.
    Both return a wasi errno so a bad clockid is weInval and a denied clock is
    the caller's weNotCapable. }
  TWasmWasiClock = class
  public
    function TimeGet(const AClockId: UInt32;
      out ANanos: UInt64): TWasmWasiErrno; virtual; abstract;
    function ResGet(const AClockId: UInt32;
      out ANanos: UInt64): TWasmWasiErrno; virtual; abstract;
  end;

  { The random seam. Fill writes ALen bytes of entropy into the host buffer;
    the WASI layer then copies them into the checked guest range. }
  TWasmWasiRandom = class
  public
    function Fill(const ABuf: PByte;
      const ALen: NativeUInt): TWasmWasiErrno; virtual; abstract;
  end;

  { The default OS clock. On POSIX (Linux/macOS) this is clock_gettime with
    NANOSECOND precision: REALTIME is wall-clock ns since the Unix epoch in UTC
    (no local-time offset), MONOTONIC/PROCESS/THREAD map to their host
    clockid_t. On non-UNIX it falls back to the RTL at millisecond precision.
    ResGet reports the host clock_getres.

    UNCONFIRMED (precision/timezone, not ABI): the non-UNIX (Windows) fallback
    keeps the RTL millisecond path and its epoch fidelity; a platform-native
    Windows clock is a follow-up. clockid_t values for BSDs other than darwin
    are unmapped. Tests inject a fixed clock and never exercise this path. }
  TWasmWasiOsClock = class(TWasmWasiClock)
  public
    function TimeGet(const AClockId: UInt32;
      out ANanos: UInt64): TWasmWasiErrno; override;
    function ResGet(const AClockId: UInt32;
      out ANanos: UInt64): TWasmWasiErrno; override;
  end;

  { The default random source — the sandbox's entropy source. Fills from the
    platform CSPRNG: /dev/urandom on POSIX (Linux/macOS), RtlGenRandom on
    Windows. NOT a PRNG — a guest using random_get for cryptographic material
    gets unpredictable bytes. A read failure returns weIo and never falls back
    to a weak generator (embedding-spec.md §2.2, §9). The injectable seam stays
    the actual control: every hermetic WASI test injects a fixed generator and
    never reaches this class; only the DEFAULT posture reads real entropy.

    UNCONFIRMED: the Windows advapi32/SystemFunction036 link path across every
    FPC/Windows target (see the implementation note); POSIX /dev/urandom is the
    reliable path and the CI target. }
  TWasmWasiOsRandom = class(TWasmWasiRandom)
  public
    constructor Create;
    function Fill(const ABuf: PByte;
      const ALen: NativeUInt): TWasmWasiErrno; override;
  end;

  { --- capability set (embedding-spec.md §2.1) -------------------------- }

  { A preopened directory: the ONLY route to the filesystem. HostPath is a real
    OS directory the embedder chose; GuestPath is the name the guest sees (and
    the only thing fd_prestat_dir_name reveals — the guest never learns
    HostPath). Rights/InheritRights bound what may be done through it and any fd
    derived from it. Wave-1 advertises the preopen (prestat) but does not yet
    open files under it — that is F4. }
  TWasmWasiPreopen = record
    GuestPath: string;
    HostPath: string;
    Rights: TWasmWasiRights;
    InheritRights: TWasmWasiRights;
  end;

  TWasmWasiPreopenArray = array of TWasmWasiPreopen;

  { The whole capability set the embedder hands over. Default-constructed =
    deny-all except the three std streams (capturable buffers) and an OS
    clock/random. The embedder adds argv, env, and preopens explicitly.

    OWNERSHIP: the config owns and frees the default objects it created in
    Create (the three buffer streams, the OS clock, the OS random). An embedder
    that injects its own stream/clock/random assigns the field and owns that
    object itself — the config only frees what it made, so there is no double
    free. }
  TWasmWasiConfig = class
  private
    FOwned: array of TObject;
    procedure Own(const AObject: TObject);
  public
    Argv: TArray<string>;
    Env: TArray<string>;
    Preopens: TWasmWasiPreopenArray;
    Stdin: TWasmWasiStream;
    Stdout: TWasmWasiStream;
    Stderr: TWasmWasiStream;
    Clock: TWasmWasiClock;
    Random: TWasmWasiRandom;

    constructor Create;
    destructor Destroy; override;

    procedure AddPreopenDir(const AGuest, AHost: string;
      const ARights: TWasmWasiRights);
    procedure AddEnv(const AKeyValue: string);
    procedure SetArgv(const AArgv: array of string);
  end;

  { --- fd table + context (embedding-spec.md §3, §3.1) ------------------ }

  TWasmWasiFdKind = (wfkStream, wfkDir, wfkFile);

  PWasmWasiFdEntry = ^TWasmWasiFdEntry;
  TWasmWasiFdEntry = record
    Used: Boolean;
    Kind: TWasmWasiFdKind;
    Stream: TWasmWasiStream;      { wfkStream: 0/1/2; BORROWED from the config }
    Filetype: Byte;              { WASI_FILETYPE_* }
    Fdflags: Word;               { WASI_FDFLAGS_* }
    Rights: TWasmWasiRights;
    InheritRights: TWasmWasiRights;
    IsPreopen: Boolean;          { fd_prestat_* answers only for these }
    PreopenIndex: Integer;       { index into Config.Preopens, or -1 }
    GuestPath: string;           { the preopen name fd_prestat_dir_name reveals }
    Offset: UInt64;              { fd_seek cursor for regular files (F4) }
    { F4: real filesystem entries (wfkDir / wfkFile). HostPath is the
      canonical (symlink-resolved) OS path this fd descends from — the
      containment root every path_* op under this fd is re-checked against
      (embedding-spec.md §5.3). OsHandle is the open OS file handle for a
      wfkFile (feInvalidHandle otherwise). The guest never learns HostPath. }
    HostPath: string;
    OsHandle: THandle;
  end;

  { Per-run WASI state: the granted config, the fd table, the guest's exported
    memory (resolved AFTER instantiation — embedding-spec.md §3), and the
    proc_exit code. Handed to every WASI callback as its AData pointer, so all
    callbacks share one context and observe the memory once it is set. The
    context does NOT own the config — their lifetimes are separate. }
  TWasmWasiContext = class
  private
    FConfig: TWasmWasiConfig;
    FFds: array of TWasmWasiFdEntry;
    FMemory: TWasmMemoryRef;
    FMemoryResolved: Boolean;
    FExitCode: Int32;
    FMaxOpenFds: Integer;

    procedure AddStdStream(const AStream: TWasmWasiStream;
      const AFiletype: Byte; const ARights: TWasmWasiRights);
  public
    constructor Create(const AConfig: TWasmWasiConfig);

    { Resolve the guest's exported "memory" into the context (embedding-spec.md
      §3 memory-resolution ordering). Called once, after Instantiate, before
      the first guest Call. }
    procedure SetMemory(const AMemory: TWasmMemoryRef);

    { The fd table entry for AFd, or nil if AFd is out of range or closed. A
      pointer INTO the table: valid for the duration of one callback (the table
      is not resized during a guest call). }
    function FdEntry(const AFd: UInt32): PWasmWasiFdEntry;

    { F4: install AEntry in a free slot (a closed fd's slot, else a fresh one)
      and return its fd. path_open uses this for a newly opened file/dir. This
      MAY grow FFds, invalidating any live PWasmWasiFdEntry pointer — a caller
      holding a dirfd entry must copy the fields it needs BEFORE calling this. }
    function AllocFd(const AEntry: TWasmWasiFdEntry): UInt32;

    { F4 (fd exhaustion): True when the number of open (Used) fds has reached
      MaxOpenFds. path_open checks this BEFORE opening any OS handle and returns
      weMFile (EMFILE) if it is at the cap, so a guest holding a preopen cannot
      exhaust host descriptors/memory by opening files it never closes. Closed
      slots (Used = False) do not count, so churn stays bounded, not monotone. }
    function AtFdLimit: Boolean;

    property Config: TWasmWasiConfig read FConfig;
    property MemoryResolved: Boolean read FMemoryResolved;
    property Memory: TWasmMemoryRef read FMemory;
    property ExitCode: Int32 read FExitCode write FExitCode;
    { The open-fd cap (F4). Defaults to WASI_DEFAULT_MAX_FDS; an embedder or a
      test may lower it (a tighter budget) or raise it. }
    property MaxOpenFds: Integer read FMaxOpenFds write FMaxOpenFds;
  end;

{ Register the wave-1 (MUST-tier) AND wave-2 (SHOULD-tier filesystem) preview1
  functions on ALinker for the "wasi_snapshot_preview1" module, each wired to
  AContext (embedding-spec.md §3, §8.2). After this, an Instantiate against
  ALinker links a module that imports the wave-1/2 set; the embedder then
  resolves the guest memory into AContext (AContext.SetMemory) before the first
  Call. Wave-3 long-tail functions (path_link/symlink/readlink/rename,
  fd_advise/allocate/sync, poll_oneoff, sock_*) are intentionally NOT defined
  here — a module importing them fails to link until F5, which is the honest
  deny-by-default posture. The wave-2 filesystem is reachable ONLY through a
  preopen the embedder granted; with no preopen there is no dir fd to open
  under. }
procedure WasiDefineAll(const ALinker: TWasmLinker;
  const AContext: TWasmWasiContext);

implementation

{ --- platform seams for the default clock/CSPRNG and fs (F4) -------------- }

{$IFDEF UNIX}
{ clock_gettime / realpath are libc, but FPC does not surface clock_gettime
  through BaseUnix on every UNIX (darwin in particular), so they are declared
  directly against libc here. realpath canonicalises a path with ALL symlinks
  resolved — the primitive the containment check leans on (embedding-spec.md
  §5.3): a symlink escaping the preopen resolves to an outside real path and is
  rejected. }
type
  { A POSIX struct timespec, sized for the target: on LP64 both fields are
    64-bit (time_t and long); on ILP32 both are 32-bit. UNCONFIRMED for exotic
    32-bit hosts with 64-bit time_t (glibc _TIME_BITS=64), which the shipped
    64-bit CI target does not exercise. }
  TWasiTimespec = record
    tv_sec: {$IFDEF CPU64}Int64{$ELSE}LongInt{$ENDIF};
    tv_nsec: {$IFDEF CPU64}Int64{$ELSE}LongInt{$ENDIF};
  end;

function Sys_clock_gettime(AClk: LongInt; ATp: Pointer): LongInt; cdecl;
  external 'c' name 'clock_gettime';
function Sys_clock_getres(AClk: LongInt; ATp: Pointer): LongInt; cdecl;
  external 'c' name 'clock_getres';
function Sys_realpath(APath: PAnsiChar; AResolved: PAnsiChar): PAnsiChar; cdecl;
  external 'c' name 'realpath';

const
  { clockid_t values are NOT portable across UNIX: REALTIME is 0 everywhere,
    but MONOTONIC and the CPU-time clocks differ. Gated per OS; the darwin set
    is the CI target. UNCONFIRMED for BSDs other than the two mapped here. }
  {$IFDEF DARWIN}
  SYS_CLOCK_REALTIME  = 0;
  SYS_CLOCK_MONOTONIC = 6;   { CLOCK_MONOTONIC on darwin }
  SYS_CLOCK_PROCESS   = 12;  { CLOCK_PROCESS_CPUTIME_ID }
  SYS_CLOCK_THREAD    = 16;  { CLOCK_THREAD_CPUTIME_ID }
  {$ELSE}
  SYS_CLOCK_REALTIME  = 0;
  SYS_CLOCK_MONOTONIC = 1;   { Linux }
  SYS_CLOCK_PROCESS   = 2;
  SYS_CLOCK_THREAD    = 3;
  {$ENDIF}
{$ENDIF}

{$IFDEF WINDOWS}
{ RtlGenRandom (exported from advapi32 as SystemFunction036) is the documented
  no-extra-dependency CSPRNG on Windows. UNCONFIRMED that every FPC/Windows
  target links advapi32 cleanly without a new package; if it does not, the
  POSIX /dev/urandom path is the reliable one and Windows entropy is a
  follow-up. }
function RtlGenRandom(ABuffer: Pointer; ALength: UInt32): ByteBool; stdcall;
  external 'advapi32.dll' name 'SystemFunction036';
{$ENDIF}

const
  { The default open-fd cap (F4). Generous enough that no ordinary program
    notices, small enough that a runaway open-loop is stopped long before it
    exhausts host descriptors. An embedder may override via ctx.MaxOpenFds. }
  WASI_DEFAULT_MAX_FDS = 1024;

{ Std-stream rights (embedding-spec.md §3.1): stdin reads, stdout/stderr write.
  Deliberately minimal — a stream is not seekable (fd_seek returns ESPIPE) and
  carries no path rights. These are plain functions rather than typed consts
  because a WASI_RIGHTS_* value is itself a typed const, which FPC will not
  accept in another typed-const initializer. }
function StdinRights: TWasmWasiRights; inline;
begin
  Result := WASI_RIGHTS_FD_READ;
end;

function StdoutRights: TWasmWasiRights; inline;
begin
  Result := WASI_RIGHTS_FD_WRITE;
end;

{ --- little-endian pokes into a host byte buffer ------------------------- }

procedure PokeU16(var ABuf: TBytes; const AOff: Integer; const AValue: Word);
begin
  ABuf[AOff] := Byte(AValue);
  ABuf[AOff + 1] := Byte(AValue shr 8);
end;

procedure PokeU32(var ABuf: TBytes; const AOff: Integer; const AValue: UInt32);
begin
  ABuf[AOff] := Byte(AValue);
  ABuf[AOff + 1] := Byte(AValue shr 8);
  ABuf[AOff + 2] := Byte(AValue shr 16);
  ABuf[AOff + 3] := Byte(AValue shr 24);
end;

procedure PokeU64(var ABuf: TBytes; const AOff: Integer; const AValue: UInt64);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    ABuf[AOff + Index] := Byte(AValue shr (Index * 8));
end;

{ Raw bytes of a Pascal string. The source treats names/args/env as UTF-8
  already (AGENTS.md), and preview1's argv/env/paths are byte strings, so the
  string's own bytes are what the ABI wants. }
function StrBytes(const AStr: string): TBytes;
var
  Index: Integer;
begin
  SetLength(Result, Length(AStr));
  for Index := 1 to Length(AStr) do
    Result[Index - 1] := Byte(AStr[Index]);
end;

{ --- TWasmWasiStream / TWasmWasiBufferStream ----------------------------- }

function TWasmWasiStream.IsTerminal: Boolean;
begin
  Result := False;
end;

function TWasmWasiBufferStream.WriteBytes(const ABuf: PByte;
  const ALen: NativeUInt): NativeUInt;
var
  Old: NativeUInt;
begin
  if ALen > 0 then
  begin
    Old := NativeUInt(Length(FWritten));
    SetLength(FWritten, Old + ALen);
    Move(ABuf^, FWritten[Old], ALen);
  end;
  Result := ALen;
end;

function TWasmWasiBufferStream.ReadBytes(const ABuf: PByte;
  const AMax: NativeUInt): NativeUInt;
var
  Available: NativeUInt;
begin
  Available := NativeUInt(Length(FInput)) - FInputPos;
  if Available > AMax then
    Result := AMax
  else
    Result := Available;
  if Result > 0 then
  begin
    Move(FInput[FInputPos], ABuf^, Result);
    Inc(FInputPos, Result);
  end;
end;

procedure TWasmWasiBufferStream.SetInputBytes(const ABytes: TBytes);
begin
  FInput := Copy(ABytes, 0, Length(ABytes));
  FInputPos := 0;
end;

function TWasmWasiBufferStream.WrittenBytes: TBytes;
begin
  Result := Copy(FWritten, 0, Length(FWritten));
end;

function TWasmWasiBufferStream.WrittenCount: NativeUInt;
begin
  Result := NativeUInt(Length(FWritten));
end;

procedure TWasmWasiBufferStream.Clear;
begin
  FWritten := nil;
  FInput := nil;
  FInputPos := 0;
end;

{ --- TWasmWasiOsClock ---------------------------------------------------- }

{$IFDEF UNIX}
{ Map a wasi clockid to the host clockid_t, or -1 for an unknown id. }
function WasiClockIdToSys(const AClockId: UInt32; out ASys: LongInt): Boolean;
begin
  Result := True;
  case AClockId of
    WASI_CLOCKID_REALTIME: ASys := SYS_CLOCK_REALTIME;
    WASI_CLOCKID_MONOTONIC: ASys := SYS_CLOCK_MONOTONIC;
    WASI_CLOCKID_PROCESS_CPUTIME_ID: ASys := SYS_CLOCK_PROCESS;
    WASI_CLOCKID_THREAD_CPUTIME_ID: ASys := SYS_CLOCK_THREAD;
  else
    ASys := -1;
    Result := False;
  end;
end;
{$ENDIF}

function TWasmWasiOsClock.TimeGet(const AClockId: UInt32;
  out ANanos: UInt64): TWasmWasiErrno;
{$IFDEF UNIX}
var
  Ts: TWasiTimespec;
  Sys: LongInt;
begin
  ANanos := 0;
  if not WasiClockIdToSys(AClockId, Sys) then
    Exit(weInval);
  { Nanosecond precision from clock_gettime. REALTIME is wall-clock ns since
    the Unix epoch (UTC — no local-time offset, which fixes the RTL `Now`
    timezone concern); MONOTONIC/CPUTIME are their respective host clocks. }
  Ts.tv_sec := 0;
  Ts.tv_nsec := 0;
  if Sys_clock_gettime(Sys, @Ts) <> 0 then
    Exit(weNotSup);
  ANanos := UInt64(Int64(Ts.tv_sec)) * UInt64(1000000000) +
    UInt64(Int64(Ts.tv_nsec));
  Result := weSuccess;
end;
{$ELSE}
var
  Days, Millis: Double;
begin
  { Non-UNIX fallback (Windows this wave): millisecond precision from the RTL.
    UNCONFIRMED epoch/timezone fidelity — a platform QueryPerformanceCounter /
    GetSystemTimePreciseAsFileTime upgrade is a follow-up. }
  ANanos := 0;
  case AClockId of
    WASI_CLOCKID_REALTIME:
      begin
        Days := Now - EncodeDate(1970, 1, 1);
        Millis := Days * 86400000.0;
        if Millis < 0 then
          Millis := 0;
        ANanos := UInt64(Round(Millis)) * UInt64(1000000);
        Result := weSuccess;
      end;
    WASI_CLOCKID_MONOTONIC, WASI_CLOCKID_PROCESS_CPUTIME_ID,
      WASI_CLOCKID_THREAD_CPUTIME_ID:
      begin
        ANanos := GetTickCount64 * UInt64(1000000);
        Result := weSuccess;
      end;
  else
    Result := weInval;
  end;
end;
{$ENDIF}

function TWasmWasiOsClock.ResGet(const AClockId: UInt32;
  out ANanos: UInt64): TWasmWasiErrno;
{$IFDEF UNIX}
var
  Ts: TWasiTimespec;
  Sys: LongInt;
begin
  ANanos := 0;
  if not WasiClockIdToSys(AClockId, Sys) then
    Exit(weInval);
  Ts.tv_sec := 0;
  Ts.tv_nsec := 0;
  if Sys_clock_getres(Sys, @Ts) <> 0 then
  begin
    { A clock that has no resolution query still ticks; report 1 ns. }
    ANanos := 1;
    Exit(weSuccess);
  end;
  ANanos := UInt64(Int64(Ts.tv_sec)) * UInt64(1000000000) +
    UInt64(Int64(Ts.tv_nsec));
  if ANanos = 0 then
    ANanos := 1;
  Result := weSuccess;
end;
{$ELSE}
begin
  ANanos := 0;
  if AClockId > WASI_CLOCKID_THREAD_CPUTIME_ID then
    Exit(weInval);
  ANanos := UInt64(1000000);
  Result := weSuccess;
end;
{$ENDIF}

{ --- TWasmWasiOsRandom --------------------------------------------------- }

constructor TWasmWasiOsRandom.Create;
begin
  inherited Create;
end;

function TWasmWasiOsRandom.Fill(const ABuf: PByte;
  const ALen: NativeUInt): TWasmWasiErrno;
{ THE SANDBOX'S ENTROPY SOURCE. random_get's default fills from the platform
  CSPRNG — /dev/urandom on POSIX, RtlGenRandom on Windows — never from a
  predictable PRNG. A guest using random_get for cryptographic material must
  get unpredictable bytes; a read failure returns weIo (EIO) and NEVER falls
  back to a weak generator. The injectable seam (Config.Random) stays: a
  hermetic test replaces this object with a deterministic one, so this real-
  entropy path runs only when the default is used (embedding-spec.md §2.2). }
{$IFDEF UNIX}
var
  Fd: LongInt;
  P: PByte;
  Remaining: NativeUInt;
  Got: TSSize;
begin
  if ALen = 0 then
    Exit(weSuccess);
  { /dev/urandom is the portable, always-seeded CSPRNG on Linux and macOS. }
  Fd := FpOpen('/dev/urandom', O_RDONLY, 0);
  if Fd < 0 then
    Exit(weIo);
  try
    P := ABuf;
    Remaining := ALen;
    while Remaining > 0 do
    begin
      Got := FpRead(Fd, PChar(P), Remaining);
      { A short read is normal and looped; 0 (EOF, impossible for urandom) or a
        negative (error) is a hard failure — weIo, no weak fallback. }
      if Got <= 0 then
        Exit(weIo);
      Inc(P, NativeUInt(Got));
      Dec(Remaining, NativeUInt(Got));
    end;
  finally
    FpClose(Fd);
  end;
  Result := weSuccess;
end;
{$ELSE}
{$IFDEF WINDOWS}
begin
  if ALen = 0 then
    Exit(weSuccess);
  if RtlGenRandom(ABuf, UInt32(ALen)) then
    Result := weSuccess
  else
    Result := weIo;
end;
{$ELSE}
begin
  { No platform CSPRNG reachable without a new dependency. Rather than emit
    predictable bytes, fail closed: random_get returns weIo. }
  Result := weIo;
end;
{$ENDIF}
{$ENDIF}

{ --- TWasmWasiConfig ----------------------------------------------------- }

constructor TWasmWasiConfig.Create;
var
  BufStdin, BufStdout, BufStderr: TWasmWasiBufferStream;
  OsClock: TWasmWasiOsClock;
  OsRandom: TWasmWasiOsRandom;
begin
  inherited Create;
  Argv := nil;
  Env := nil;
  Preopens := nil;

  { Deny-by-default: only the three std streams and an OS clock/random. The
    default streams are capturable in-memory buffers, so a test observes
    fd_write output without touching the real process stdio (embedding-spec.md
    §2.2, §7). No preopens, no env, no argv. }
  BufStdin := TWasmWasiBufferStream.Create;
  BufStdout := TWasmWasiBufferStream.Create;
  BufStderr := TWasmWasiBufferStream.Create;
  Own(BufStdin);
  Own(BufStdout);
  Own(BufStderr);
  Stdin := BufStdin;
  Stdout := BufStdout;
  Stderr := BufStderr;

  OsClock := TWasmWasiOsClock.Create;
  OsRandom := TWasmWasiOsRandom.Create;
  Own(OsClock);
  Own(OsRandom);
  Clock := OsClock;
  Random := OsRandom;
end;

destructor TWasmWasiConfig.Destroy;
var
  Index: Integer;
begin
  { Free only what the config itself created (embedding-spec.md §2.1 ownership).
    An injected stream/clock/random is the embedder's to free. }
  for Index := 0 to High(FOwned) do
    FOwned[Index].Free;
  FOwned := nil;
  inherited Destroy;
end;

procedure TWasmWasiConfig.Own(const AObject: TObject);
begin
  SetLength(FOwned, Length(FOwned) + 1);
  FOwned[High(FOwned)] := AObject;
end;

procedure TWasmWasiConfig.AddPreopenDir(const AGuest, AHost: string;
  const ARights: TWasmWasiRights);
var
  Preopen: TWasmWasiPreopen;
begin
  Preopen.GuestPath := AGuest;
  Preopen.HostPath := AHost;
  Preopen.Rights := ARights;
  { A preopen's inheriting rights default to its own base rights (F4 refines
    this when path_open masks derived fds). }
  Preopen.InheritRights := ARights;
  SetLength(Preopens, Length(Preopens) + 1);
  Preopens[High(Preopens)] := Preopen;
end;

procedure TWasmWasiConfig.AddEnv(const AKeyValue: string);
begin
  SetLength(Env, Length(Env) + 1);
  Env[High(Env)] := AKeyValue;
end;

procedure TWasmWasiConfig.SetArgv(const AArgv: array of string);
var
  Index: Integer;
begin
  SetLength(Argv, Length(AArgv));
  for Index := 0 to High(AArgv) do
    Argv[Index] := AArgv[Index];
end;

{ --- TWasmWasiContext ---------------------------------------------------- }

constructor TWasmWasiContext.Create(const AConfig: TWasmWasiConfig);
var
  Index: Integer;
  Entry: TWasmWasiFdEntry;
begin
  inherited Create;
  if AConfig = nil then
    raise EWasmError.Create('a WASI context needs a config');
  FConfig := AConfig;
  FFds := nil;
  FMemoryResolved := False;
  FExitCode := 0;
  FMaxOpenFds := WASI_DEFAULT_MAX_FDS;

  { fd 0/1/2 = the std streams (embedding-spec.md §3.1). A CHARACTER_DEVICE
    filetype is what libc expects for a tty-like stream. }
  AddStdStream(AConfig.Stdin, WASI_FILETYPE_CHARACTER_DEVICE, StdinRights);
  AddStdStream(AConfig.Stdout, WASI_FILETYPE_CHARACTER_DEVICE, StdoutRights);
  AddStdStream(AConfig.Stderr, WASI_FILETYPE_CHARACTER_DEVICE, StdoutRights);

  { Preopens occupy 3, 4, ... in config order; fd_prestat_* advertises them,
    and libc's preopen discovery walks fds from 3 until fd_prestat_get returns
    weBadf. Wave-1 records the advertisement; F4 opens files under it. }
  for Index := 0 to High(AConfig.Preopens) do
  begin
    Entry := Default(TWasmWasiFdEntry);
    Entry.Used := True;
    Entry.Kind := wfkDir;
    Entry.Stream := nil;
    Entry.Filetype := WASI_FILETYPE_DIRECTORY;
    Entry.Fdflags := 0;
    Entry.Rights := AConfig.Preopens[Index].Rights;
    Entry.InheritRights := AConfig.Preopens[Index].InheritRights;
    Entry.IsPreopen := True;
    Entry.PreopenIndex := Index;
    Entry.GuestPath := AConfig.Preopens[Index].GuestPath;
    Entry.Offset := 0;
    { The containment root: every path_* op under this preopen fd re-resolves
      the guest path against this host directory and rejects any escape. }
    Entry.HostPath := AConfig.Preopens[Index].HostPath;
    Entry.OsHandle := feInvalidHandle;
    SetLength(FFds, Length(FFds) + 1);
    FFds[High(FFds)] := Entry;
  end;
end;

procedure TWasmWasiContext.AddStdStream(const AStream: TWasmWasiStream;
  const AFiletype: Byte; const ARights: TWasmWasiRights);
var
  Entry: TWasmWasiFdEntry;
begin
  Entry := Default(TWasmWasiFdEntry);
  Entry.Used := True;
  Entry.Kind := wfkStream;
  Entry.Stream := AStream;
  Entry.Filetype := AFiletype;
  Entry.Fdflags := 0;
  Entry.Rights := ARights;
  Entry.InheritRights := 0;
  Entry.IsPreopen := False;
  Entry.PreopenIndex := -1;
  Entry.GuestPath := '';
  Entry.Offset := 0;
  Entry.HostPath := '';
  Entry.OsHandle := feInvalidHandle;
  SetLength(FFds, Length(FFds) + 1);
  FFds[High(FFds)] := Entry;
end;

function TWasmWasiContext.AllocFd(const AEntry: TWasmWasiFdEntry): UInt32;
var
  Index: Integer;
begin
  for Index := 0 to High(FFds) do
    if not FFds[Index].Used then
    begin
      FFds[Index] := AEntry;
      Exit(UInt32(Index));
    end;
  SetLength(FFds, Length(FFds) + 1);
  FFds[High(FFds)] := AEntry;
  Result := UInt32(High(FFds));
end;

function TWasmWasiContext.AtFdLimit: Boolean;
var
  Index, Used: Integer;
begin
  Used := 0;
  for Index := 0 to High(FFds) do
    if FFds[Index].Used then
      Inc(Used);
  Result := Used >= FMaxOpenFds;
end;

procedure TWasmWasiContext.SetMemory(const AMemory: TWasmMemoryRef);
begin
  FMemory := AMemory;
  FMemoryResolved := True;
end;

function TWasmWasiContext.FdEntry(const AFd: UInt32): PWasmWasiFdEntry;
begin
  if (AFd < UInt32(Length(FFds))) and FFds[AFd].Used then
    Result := @FFds[AFd]
  else
    Result := nil;
end;

{ --- callback plumbing --------------------------------------------------- }

{ Write a wasi errno into the i32 result slot (embedding-spec.md §3.4). }
procedure ReturnErrno(const AResults: PWasmValue; const AErrno: TWasmWasiErrno);
begin
  AResults[0] := MakeValueI32(Int32(WasiErrnoCode(AErrno)));
end;

{ The guest's resolved memory, or False if the WASI call somehow ran before
  memory resolution (impossible in practice — _start runs after it). }
function CtxMemory(const ACtx: TWasmWasiContext;
  out AMem: TWasmMemoryRef): Boolean;
begin
  Result := ACtx.MemoryResolved;
  if Result then
    AMem := ACtx.Memory;
end;

{ Write a string vector as preview1's two-buffer ABI (embedding-spec.md §5.2):
  a pointer array at AArrayPtr (one guest u32 offset per item) and the
  NUL-terminated bytes at ABufPtr. Every write is bounds-checked; a guest that
  under-sizes its buffer gets weFault on the first out-of-range write, never a
  host overflow. }
function WriteStringVector(const AMem: TWasmMemoryRef;
  const AArrayPtr, ABufPtr: UInt64; const AItems: TArray<string>): TWasmWasiErrno;
var
  Index: Integer;
  Cursor: UInt64;
  Bytes: TBytes;
  Zero: Byte;
begin
  Zero := 0;
  Cursor := ABufPtr;
  for Index := 0 to High(AItems) do
  begin
    Result := GuestWriteU32(AMem, AArrayPtr + UInt64(Index) * 4,
      UInt32(Cursor));
    if Result <> weSuccess then
      Exit;
    Bytes := StrBytes(AItems[Index]);
    if Length(Bytes) > 0 then
    begin
      Result := GuestWriteBytes(AMem, Cursor, UInt64(Length(Bytes)),
        @Bytes[0]);
      if Result <> weSuccess then
        Exit;
    end;
    Result := GuestWriteBytes(AMem, Cursor + UInt64(Length(Bytes)), 1, @Zero);
    if Result <> weSuccess then
      Exit;
    Cursor := Cursor + UInt64(Length(Bytes)) + 1;
  end;
  Result := weSuccess;
end;

{ count = number of items; bufsize = sum(len(item)+1) — the two values the
  paired *_sizes_get reports so the guest can size its buffers. }
procedure StringVectorSizes(const AItems: TArray<string>;
  out ACount, ABufSize: UInt32);
var
  Index: Integer;
begin
  ACount := UInt32(Length(AItems));
  ABufSize := 0;
  for Index := 0 to High(AItems) do
    ABufSize := ABufSize + UInt32(Length(StrBytes(AItems[Index]))) + 1;
end;

{ --- wave-1 host functions (embedding-spec.md §3.3) ---------------------- }

{ args_sizes_get(argc_ptr, argv_buf_size_ptr) -> errno }
procedure Wasi_args_sizes_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Count, BufSize: UInt32;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  StringVectorSizes(Ctx.Config.Argv, Count, BufSize);
  E := GuestWriteU32(Mem, UInt64(AParams[0].U32), Count);
  if E = weSuccess then
    E := GuestWriteU32(Mem, UInt64(AParams[1].U32), BufSize);
  ReturnErrno(AResults, E);
end;

{ args_get(argv_ptr, argv_buf_ptr) -> errno }
procedure Wasi_args_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  ReturnErrno(AResults, WriteStringVector(Mem, UInt64(AParams[0].U32),
    UInt64(AParams[1].U32), Ctx.Config.Argv));
end;

{ environ_sizes_get(count_ptr, buf_size_ptr) -> errno }
procedure Wasi_environ_sizes_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Count, BufSize: UInt32;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  StringVectorSizes(Ctx.Config.Env, Count, BufSize);
  E := GuestWriteU32(Mem, UInt64(AParams[0].U32), Count);
  if E = weSuccess then
    E := GuestWriteU32(Mem, UInt64(AParams[1].U32), BufSize);
  ReturnErrno(AResults, E);
end;

{ environ_get(environ_ptr, environ_buf_ptr) -> errno }
procedure Wasi_environ_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  ReturnErrno(AResults, WriteStringVector(Mem, UInt64(AParams[0].U32),
    UInt64(AParams[1].U32), Ctx.Config.Env));
end;

{ fd_write(fd, iovs, iovs_len, nwritten_ptr) -> errno }
procedure Wasi_fd_write(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  Vecs: TWasmWasiIoVecArray;
  E: TWasmWasiErrno;
  Index: Integer;
  HostBuf: TBytes;
  Total: UInt64;
  Wrote: NativeUInt;
  Remaining: UInt64;
  Chunk: LongInt;
  IoRes: LongInt;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  if Entry = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  { A stream (stdio, pipe) writes to its sink; a real file (F4) writes at its
    offset. A stream with no write right or no sink is weBadf (wasi-libc's
    reading for a non-writable descriptor); a file missing FD_WRITE is
    weNotCapable — the deny-by-default rights code (embedding-spec.md §9.3).
    A directory is not writable: weBadf. }
  case Entry^.Kind of
    wfkStream:
      if (Entry^.Stream = nil) or
        ((Entry^.Rights and WASI_RIGHTS_FD_WRITE) = 0) then
      begin
        ReturnErrno(AResults, weBadf);
        Exit;
      end;
    wfkFile:
      if (Entry^.Rights and WASI_RIGHTS_FD_WRITE) = 0 then
      begin
        ReturnErrno(AResults, weNotCapable);
        Exit;
      end;
  else
    ReturnErrno(AResults, weBadf);
    Exit;
  end;

  E := GuestReadIoVec(Mem, UInt64(AParams[1].U32), AParams[2].U32, Vecs);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;

  Total := 0;
  for Index := 0 to High(Vecs) do
  begin
    if Vecs[Index].Len = 0 then
      Continue;
    { Bounds-check the buffer BEFORE allocating a host copy of guest-controlled
      length, so a bogus (ptr,len) is weFault rather than a huge allocation. }
    if not GuestRangeValid(Mem, Vecs[Index].Buf, Vecs[Index].Len) then
    begin
      ReturnErrno(AResults, weFault);
      Exit;
    end;
    SetLength(HostBuf, Vecs[Index].Len);
    E := GuestReadBytes(Mem, Vecs[Index].Buf, Vecs[Index].Len, @HostBuf[0]);
    if E <> weSuccess then
    begin
      ReturnErrno(AResults, E);
      Exit;
    end;
    if Entry^.Kind = wfkStream then
      Wrote := Entry^.Stream.WriteBytes(@HostBuf[0], Vecs[Index].Len)
    else
    begin
      { A real file: APPEND seeks to end each write (fdflags), else write at the
        cursor. A negative FileWrite is a host IO error -> weIo. }
      if (Entry^.Fdflags and WASI_FDFLAGS_APPEND) <> 0 then
        Entry^.Offset := UInt64(FileSeek(Entry^.OsHandle, Int64(0), fsFromEnd))
      else
        FileSeek(Entry^.OsHandle, Int64(Entry^.Offset), fsFromBeginning);
      { F7/W1: write in positive-LongInt chunks (GuestIoChunk) so a guest
        buf_len in [2^31, 2^32) can never reach FileWrite as a NEGATIVE count.
        A short host write stops the loop and reports what landed. }
      Wrote := 0;
      Remaining := Vecs[Index].Len;
      while Remaining > 0 do
      begin
        Chunk := GuestIoChunk(Remaining);
        IoRes := FileWrite(Entry^.OsHandle, HostBuf[Wrote], Chunk);
        if IoRes < 0 then
        begin
          ReturnErrno(AResults, weIo);
          Exit;
        end;
        Inc(Wrote, NativeUInt(IoRes));
        Dec(Remaining, UInt64(IoRes));
        if IoRes < Chunk then
          Break;
      end;
      Entry^.Offset := Entry^.Offset + UInt64(Wrote);
    end;
    Total := Total + UInt64(Wrote);
    if Wrote < Vecs[Index].Len then
      Break;   { short write — stop and report what landed }
  end;

  ReturnErrno(AResults, GuestWriteU32(Mem, UInt64(AParams[3].U32),
    UInt32(Total)));
end;

{ fd_read(fd, iovs, iovs_len, nread_ptr) -> errno }
procedure Wasi_fd_read(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  Vecs: TWasmWasiIoVecArray;
  E: TWasmWasiErrno;
  Index: Integer;
  HostBuf: TBytes;
  Total: UInt64;
  Got: NativeUInt;
  Remaining: UInt64;
  Chunk: LongInt;
  IoRes: LongInt;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  if Entry = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  { Stream vs real file, mirroring fd_write: a non-readable stream is weBadf; a
    file missing FD_READ is weNotCapable; a directory is not readable (weBadf —
    the guest must use fd_readdir). }
  case Entry^.Kind of
    wfkStream:
      if (Entry^.Stream = nil) or
        ((Entry^.Rights and WASI_RIGHTS_FD_READ) = 0) then
      begin
        ReturnErrno(AResults, weBadf);
        Exit;
      end;
    wfkFile:
      if (Entry^.Rights and WASI_RIGHTS_FD_READ) = 0 then
      begin
        ReturnErrno(AResults, weNotCapable);
        Exit;
      end;
  else
    ReturnErrno(AResults, weBadf);
    Exit;
  end;

  E := GuestReadIoVec(Mem, UInt64(AParams[1].U32), AParams[2].U32, Vecs);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;

  Total := 0;
  for Index := 0 to High(Vecs) do
  begin
    if Vecs[Index].Len = 0 then
      Continue;
    if not GuestRangeValid(Mem, Vecs[Index].Buf, Vecs[Index].Len) then
    begin
      ReturnErrno(AResults, weFault);
      Exit;
    end;
    SetLength(HostBuf, Vecs[Index].Len);
    if Entry^.Kind = wfkStream then
      Got := Entry^.Stream.ReadBytes(@HostBuf[0], Vecs[Index].Len)
    else
    begin
      { A real file: read at the cursor and advance it. Negative -> weIo. }
      FileSeek(Entry^.OsHandle, Int64(Entry^.Offset), fsFromBeginning);
      { F7/W1: read in positive-LongInt chunks (see fd_write); a short host read
        (EOF) stops the loop. }
      Got := 0;
      Remaining := Vecs[Index].Len;
      while Remaining > 0 do
      begin
        Chunk := GuestIoChunk(Remaining);
        IoRes := FileRead(Entry^.OsHandle, HostBuf[Got], Chunk);
        if IoRes < 0 then
        begin
          ReturnErrno(AResults, weIo);
          Exit;
        end;
        Inc(Got, NativeUInt(IoRes));
        Dec(Remaining, UInt64(IoRes));
        if IoRes < Chunk then
          Break;
      end;
      Entry^.Offset := Entry^.Offset + UInt64(Got);
    end;
    if Got > 0 then
    begin
      E := GuestWriteBytes(Mem, Vecs[Index].Buf, UInt64(Got), @HostBuf[0]);
      if E <> weSuccess then
      begin
        ReturnErrno(AResults, E);
        Exit;
      end;
    end;
    Total := Total + UInt64(Got);
    if Got < Vecs[Index].Len then
      Break;   { short read / EOF }
  end;

  ReturnErrno(AResults, GuestWriteU32(Mem, UInt64(AParams[3].U32),
    UInt32(Total)));
end;

{ fd_close(fd) -> errno }
procedure Wasi_fd_close(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Entry: PWasmWasiFdEntry;
begin
  Ctx := TWasmWasiContext(AData);
  Entry := Ctx.FdEntry(AParams[0].U32);
  if Entry = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  { Closing a preopen is allowed and removes it (embedding-spec.md §3.3). A
    real open file releases its host handle. }
  if (Entry^.Kind = wfkFile) and (Entry^.OsHandle <> feInvalidHandle) then
  begin
    FileClose(Entry^.OsHandle);
    Entry^.OsHandle := feInvalidHandle;
  end;
  Entry^.Used := False;
  ReturnErrno(AResults, weSuccess);
end;

{ fd_seek(fd, offset: i64, whence: i32, newoffset_ptr) -> errno }
procedure Wasi_fd_seek(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  Offset: Int64;
  Whence: UInt32;
  NewOffset: UInt64;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  if Entry = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  { A stream (stdio, a pipe) is not seekable (embedding-spec.md §3.3). }
  if Entry^.Kind <> wfkFile then
  begin
    ReturnErrno(AResults, weSpipe);
    Exit;
  end;
  if (Entry^.Rights and WASI_RIGHTS_FD_SEEK) = 0 then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;

  Offset := AParams[1].I64;
  Whence := AParams[2].U32;
  case Whence of
    WASI_WHENCE_SET:
      NewOffset := UInt64(Offset);
    WASI_WHENCE_CUR:
      NewOffset := Entry^.Offset + UInt64(Offset);
    WASI_WHENCE_END:
      { Seek relative to end-of-file: query the size through the OS handle
        (F4 wires the handle path). }
      NewOffset := UInt64(Int64(FileSeek(Entry^.OsHandle, Int64(0), fsFromEnd))
        + Offset);
  else
    ReturnErrno(AResults, weInval);
    Exit;
  end;

  Entry^.Offset := NewOffset;
  ReturnErrno(AResults, GuestWriteU64(Mem, UInt64(AParams[3].U32), NewOffset));
end;

{ fd_fdstat_get(fd, buf_ptr) -> errno }
procedure Wasi_fd_fdstat_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  Buf: TBytes;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  if Entry = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;

  { Build the 24-byte fdstat in a host buffer, then one bounds-checked write —
    all-or-nothing at the guest pointer (embedding-spec.md §5.1). }
  SetLength(Buf, WASI_FDSTAT_SIZE);
  FillChar(Buf[0], WASI_FDSTAT_SIZE, 0);
  Buf[WASI_FDSTAT_FILETYPE_OFF] := Entry^.Filetype;
  PokeU16(Buf, WASI_FDSTAT_FLAGS_OFF, Entry^.Fdflags);
  PokeU64(Buf, WASI_FDSTAT_RIGHTS_BASE_OFF, Entry^.Rights);
  PokeU64(Buf, WASI_FDSTAT_RIGHTS_INHERITING_OFF, Entry^.InheritRights);

  ReturnErrno(AResults, GuestWriteBytes(Mem, UInt64(AParams[1].U32),
    WASI_FDSTAT_SIZE, @Buf[0]));
end;

{ fd_prestat_get(fd, buf_ptr) -> errno }
procedure Wasi_fd_prestat_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  Buf: TBytes;
  NameLen: UInt32;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  { Only a preopen answers; any other fd is weBadf — this is how libc's preopen
    discovery terminates (embedding-spec.md §3.3). With no preopens configured,
    fd 3 is not in the table, so this is weBadf: deny-by-default made concrete. }
  if (Entry = nil) or (not Entry^.IsPreopen) then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;

  NameLen := UInt32(Length(StrBytes(Entry^.GuestPath)));
  SetLength(Buf, WASI_PRESTAT_SIZE);
  FillChar(Buf[0], WASI_PRESTAT_SIZE, 0);
  Buf[WASI_PRESTAT_TAG_OFF] := WASI_PREOPENTYPE_DIR;
  PokeU32(Buf, WASI_PRESTAT_DIR_NAMELEN_OFF, NameLen);

  ReturnErrno(AResults, GuestWriteBytes(Mem, UInt64(AParams[1].U32),
    WASI_PRESTAT_SIZE, @Buf[0]));
end;

{ fd_prestat_dir_name(fd, path_ptr, path_len) -> errno }
procedure Wasi_fd_prestat_dir_name(const AStore: TWasmStore;
  const AData: Pointer; const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  NameBytes: TBytes;
  PathLen: UInt32;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  if (Entry = nil) or (not Entry^.IsPreopen) then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;

  NameBytes := StrBytes(Entry^.GuestPath);
  PathLen := AParams[2].U32;
  { libc passes exactly pr_name_len; a smaller buffer cannot hold the name. }
  if PathLen < UInt32(Length(NameBytes)) then
  begin
    ReturnErrno(AResults, weNameTooLong);
    Exit;
  end;
  if Length(NameBytes) = 0 then
  begin
    ReturnErrno(AResults, weSuccess);
    Exit;
  end;
  ReturnErrno(AResults, GuestWriteBytes(Mem, UInt64(AParams[1].U32),
    UInt64(Length(NameBytes)), @NameBytes[0]));
end;

{ clock_time_get(id, precision: i64, time_ptr) -> errno }
procedure Wasi_clock_time_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Nanos: UInt64;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  { A denied clock is weNotCapable — deny-by-default at the boundary. }
  if Ctx.Config.Clock = nil then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;
  E := Ctx.Config.Clock.TimeGet(AParams[0].U32, Nanos);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;
  ReturnErrno(AResults, GuestWriteU64(Mem, UInt64(AParams[2].U32), Nanos));
end;

{ clock_res_get(id, res_ptr) -> errno }
procedure Wasi_clock_res_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Nanos: UInt64;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  if Ctx.Config.Clock = nil then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;
  E := Ctx.Config.Clock.ResGet(AParams[0].U32, Nanos);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;
  ReturnErrno(AResults, GuestWriteU64(Mem, UInt64(AParams[1].U32), Nanos));
end;

{ random_get(buf_ptr, buf_len) -> errno }
procedure Wasi_random_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  BufPtr, BufLen: UInt64;
  HostBuf: TBytes;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  if Ctx.Config.Random = nil then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;

  BufPtr := UInt64(AParams[0].U32);
  BufLen := UInt64(AParams[1].U32);
  if BufLen = 0 then
  begin
    ReturnErrno(AResults, weSuccess);
    Exit;
  end;
  { Validate the guest range BEFORE allocating a host buffer of guest-chosen
    length, then fill and copy in (embedding-spec.md §5). }
  if not GuestRangeValid(Mem, BufPtr, BufLen) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  SetLength(HostBuf, BufLen);
  E := Ctx.Config.Random.Fill(@HostBuf[0], BufLen);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;
  ReturnErrno(AResults, GuestWriteBytes(Mem, BufPtr, BufLen, @HostBuf[0]));
end;

{ proc_exit(rval) -> () noreturn (embedding-spec.md §6.1) }
procedure Wasi_proc_exit(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Code: Int32;
begin
  Ctx := TWasmWasiContext(AData);
  Code := AParams[0].I32;
  Ctx.ExitCode := Code;
  { A clean, guest-requested exit: an ORDINARY Pascal raise from a host
    callback, NOT a trap and NOT a wasm exception. Wasm.Engine's InterpInvoke
    trampoline carries EWasmExit out unchanged for the run loop to map to a
    process code (embedding-spec.md §6.1, §6.2). }
  raise EWasmExit.CreateExit(Code);
end;

{ sched_yield() -> errno }
procedure Wasi_sched_yield(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  { Single-threaded store (ADR-0008): nothing to yield to, always succeeds. }
  ReturnErrno(AResults, weSuccess);
end;

{ ======================================================================== }
{ wave-2 (SHOULD tier) — the filesystem, via preopens (embedding-spec.md §3.3) }
{                                                                          }
{ PREOPEN CONTAINMENT IS THE SANDBOX (embedding-spec.md §5.3, §9.2). Every  }
{ path_* op resolves the guest path under the dirfd's host directory and    }
{ rejects any escape — absolute paths, `..` above the root, and symlinks    }
{ that resolve outside — with weNotCapable, BEFORE any real OS call touches  }
{ the path. A final-component symlink on create is refused outright (F1,     }
{ LeafIsSymlink). The guest names paths; the host decides what they mean.    }
{                                                                          }
{ DOCUMENTED RESIDUALS (accepted, not bugs):                                }
{                                                                          }
{   F2 (TOCTOU). Containment resolves the path as a STRING (realpath +      }
{   IsPathUnder) and then hands the resolved host path to a separate OS     }
{   call. Between the check and the use, an EXTERNAL process with write     }
{   access to the preopened tree could swap a component for a symlink and   }
{   race the two. The GUEST itself cannot drive this race: a store is one   }
{   thread's (ADR-0008), the guest is suspended inside the host callback,   }
{   and it never sees a host path — so this is only exploitable by an       }
{   attacker who already has write access to the sandbox directory out of   }
{   band. Closing it fully needs the whole fs layer moved onto a held       }
{   preopen dirfd + openat/*at with O_NOFOLLOW on the leaf (which also      }
{   subsumes the F1 lstat guard); that is the intended follow-up. Until     }
{   then the leaf-symlink refusal above closes the one race the guest could }
{   set up with its own prior calls (planting a dangling link, then         }
{   creating through it).                                                   }
{                                                                          }
{   F5 (host-metadata passthrough). filestat returns the host st_dev,       }
{   st_ino, st_nlink and the real atim/mtim/ctim (HostStatPath). These leak }
{   minor host metadata to the guest — a peer runtime sometimes synthesises }
{   dev/ino instead. It is NOT synthesised here on purpose: real programs   }
{   use st_ino for hardlink/cycle detection (find, du, tar, cp -a), and     }
{   zeroing or faking it silently breaks them for a negligible security     }
{   gain. Documented and accepted for v1.                                   }
{ ======================================================================== }

type
  { The subset of a host stat the filestat struct needs. }
  TWasmHostStat = record
    Dev: UInt64;
    Ino: UInt64;
    Nlink: UInt64;
    Size: UInt64;
    Atim, Mtim, Ctim: UInt64;   { nanoseconds }
    Filetype: Byte;             { WASI_FILETYPE_* }
  end;

  { One directory entry for fd_readdir. }
  TWasmDirItem = record
    Name: string;
    Ino: UInt64;
    Ftype: Byte;
  end;
  TWasmDirItemArray = array of TWasmDirItem;

{ Read a guest path (path_ptr, path_len) into a Pascal byte-string. The path is
  read bounded by path_len — never scanned for a NUL past that length
  (embedding-spec.md §5, §9.3). A bad pointer is weFault; an absurd length is
  weNameTooLong before any allocation. }
function ReadGuestPath(const AMem: TWasmMemoryRef; const APtr, ALen: UInt64;
  out APath: string): TWasmWasiErrno;
var
  Buf: TBytes;
  Index: Integer;
begin
  APath := '';
  if ALen = 0 then
    Exit(weSuccess);
  if ALen > 4096 then
    Exit(weNameTooLong);
  if not GuestRangeValid(AMem, APtr, ALen) then
    Exit(weFault);
  SetLength(Buf, ALen);
  Result := GuestReadBytes(AMem, APtr, ALen, @Buf[0]);
  if Result <> weSuccess then
    Exit;
  { F3: reject an embedded NUL. The path is built as a Pascal string of ALen
    bytes, but every downstream host call casts it to a PAnsiChar, which
    truncates at the first NUL — so "foo\0bar" would silently operate on "foo",
    a name the guest never actually asked for (a containment-relevant confusion).
    A real path component can never contain a NUL, so any NUL in [0, ALen) is
    malformed input: weInval, before the name is used for anything. }
  for Index := 0 to Integer(ALen) - 1 do
    if Buf[Index] = 0 then
      Exit(weInval);
  SetLength(APath, Integer(ALen));
  for Index := 0 to Integer(ALen) - 1 do
    APath[Index + 1] := AnsiChar(Buf[Index]);
  Result := weSuccess;
end;

{ Canonicalise a host path with ALL symlinks resolved. On POSIX this is
  realpath(3) — the primitive the symlink-escape check relies on; it fails if
  the path does not exist. On non-UNIX it degrades to a lexical ExpandFileName
  (symlink containment UNCONFIRMED off-POSIX). }
function HostRealPath(const APath: string; out AReal: string): Boolean;
{$IFDEF UNIX}
var
  Buf: array[0..4095] of AnsiChar;
  R: PAnsiChar;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  R := sys_realpath(PAnsiChar(AnsiString(APath)), @Buf[0]);
  if R = nil then
    Exit(False);
  AReal := string(StrPas(R));
  Result := True;
end;
{$ELSE}
begin
  AReal := ExpandFileName(APath);
  Result := FileExists(APath) or DirectoryExists(APath);
end;
{$ENDIF}

{ F1 (final-component symlink on create): lstat the leaf WITHOUT following it.
  True iff the leaf itself exists and is a symbolic link. Used by path_open to
  refuse creating THROUGH a final-component symlink (O_NOFOLLOW-on-leaf): a
  dangling symlink inside the preopen can name a target outside it, and because
  realpath cannot resolve a dangling link, ResolveContained validated only the
  PARENT and handed back parent_real + '/' + leaf — so a plain FileCreate would
  follow the link and write OUTSIDE the sandbox. lstat sees the link, not its
  target, so we can refuse. A missing leaf (nothing to follow) or a non-link is
  False and the create proceeds normally. }
function LeafIsSymlink(const APath: string): Boolean;
{$IFDEF UNIX}
var
  St: Stat;
begin
  if FpLstat(PAnsiChar(AnsiString(APath)), St) <> 0 then
    Exit(False);
  Result := fpS_ISLNK(St.st_mode);
end;
{$ELSE}
begin
  { Off-POSIX there is no no-follow stat here; the final-component-symlink
    guard on create is UNCONFIRMED off-UNIX (the fs layer is POSIX-first). }
  Result := False;
end;
{$ENDIF}

{ W2 (one OS-error home): translate a captured host errno into the wasi errno,
  so the fs failure paths report the REAL reason instead of a fixed guess
  (FileOpen -> always weAcces, RemoveDir -> always weNotEmpty, ...). The caller
  captures GetLastOSError immediately after the failed OS call and routes it
  here. On UNIX GetLastOSError is the POSIX errno, mapped below. Off-UNIX it is
  a Win32 code, NOT an errno, so the fs layer (POSIX-first) maps it conservatively
  to weIo — UNCONFIRMED, revisited when a Windows fs path is a target. }
function OsErrnoToWasi(const AOsErr: Integer): TWasmWasiErrno;
{$IFDEF UNIX}
begin
  if AOsErr = ESysENOENT then
    Result := weNoEnt
  else if AOsErr = ESysEACCES then
    Result := weAcces
  else if AOsErr = ESysEEXIST then
    Result := weExist
  else if AOsErr = ESysENOTEMPTY then
    Result := weNotEmpty
  else if AOsErr = ESysENOTDIR then
    Result := weNotDir
  else if AOsErr = ESysEISDIR then
    Result := weIsDir
  else if AOsErr = ESysELOOP then
    Result := weLoop
  else if AOsErr = ESysENOSPC then
    Result := weNoSpc
  else if AOsErr = ESysEPERM then
    Result := wePerm
  else if AOsErr = ESysEMFILE then
    Result := weMfile
  else if AOsErr = ESysENFILE then
    Result := weNfile
  else if AOsErr = ESysENAMETOOLONG then
    Result := weNameTooLong
  else if AOsErr = ESysEROFS then
    Result := weRofs
  else if AOsErr = ESysEINVAL then
    Result := weInval
  else
    Result := weIo;
end;
{$ELSE}
begin
  Result := weIo;   { UNCONFIRMED off-POSIX: Win32 code, not an errno }
end;
{$ENDIF}

{ True iff AChild is ARoot itself or lies beneath it — a case-sensitive,
  component-boundary compare (so "/a/bc" is NOT under "/a/b"). Both must already
  be canonical real paths. This is the final containment gate. }
function IsPathUnder(const AChild, ARoot: string): Boolean;
var
  Root: string;
begin
  Root := ExcludeTrailingPathDelimiter(ARoot);
  if AChild = Root then
    Exit(True);
  Result := (Length(AChild) > Length(Root)) and
    (Copy(AChild, 1, Length(Root)) = Root) and
    (AChild[Length(Root) + 1] = PathDelim);
end;

{ Lexically normalise a guest path into a relative host fragment, REJECTING any
  escape at the syntax level: an absolute path (leading '/') or a `..` that
  ascends above the root is weNotCapable — the deny-by-default code. `.` and
  empty components are dropped. This catches "../x", "/etc/passwd", and
  "a/../../x" before any filesystem call; the symlink case is caught after by
  the realpath containment re-check. }
function NormalizeGuestPath(const APath: string;
  out ARel: string): TWasmWasiErrno;
var
  Index, Start, Len: Integer;
  Token: string;
  Stack: array of string;
  Depth: Integer;
begin
  ARel := '';
  Len := Length(APath);
  if Len = 0 then
    Exit(weSuccess);
  { An absolute guest path never reaches outside the preopen — it is refused. }
  if APath[1] = '/' then
    Exit(weNotCapable);
  Stack := nil;
  Depth := 0;
  Index := 1;
  while Index <= Len do
  begin
    Start := Index;
    while (Index <= Len) and (APath[Index] <> '/') do
      Inc(Index);
    Token := Copy(APath, Start, Index - Start);
    Inc(Index);   { skip the '/' }
    if (Token = '') or (Token = '.') then
      Continue;
    if Token = '..' then
    begin
      if Depth = 0 then
        Exit(weNotCapable);   { would ascend above the preopen root }
      Dec(Depth);
      SetLength(Stack, Depth);
      Continue;
    end;
    SetLength(Stack, Depth + 1);
    Stack[Depth] := Token;
    Inc(Depth);
  end;
  for Index := 0 to Depth - 1 do
    if Index = 0 then
      ARel := Stack[Index]
    else
      ARel := ARel + PathDelim + Stack[Index];
  Result := weSuccess;
end;

{ Resolve AGuestPath under ARootHost with strict containment, returning the
  canonical host path in AHostPath (embedding-spec.md §5.3):
    1. lexical normalise + reject absolute / `..`-escape  -> weNotCapable
    2. realpath the candidate; if it exists it must stay under the root
       (symlink escape -> weNotCapable)
    3. if it does not exist: weNoEnt when ARequireExists, else resolve the
       PARENT real path and require IT under the root (so a create lands inside)
  The root itself is realpath'd first so a preopen given as a symlink is handled. }
function ResolveContained(const ARootHost, AGuestPath: string;
  const ARequireExists: Boolean; out AHostPath: string): TWasmWasiErrno;
var
  Rel, RootReal, Candidate, CandReal, Parent, ParentReal: string;
begin
  AHostPath := '';
  Result := NormalizeGuestPath(AGuestPath, Rel);
  if Result <> weSuccess then
    Exit;
  if not HostRealPath(ARootHost, RootReal) then
    Exit(weNoEnt);
  RootReal := ExcludeTrailingPathDelimiter(RootReal);
  if Rel = '' then
  begin
    { The preopen root itself (path "" or "."). }
    AHostPath := RootReal;
    Exit(weSuccess);
  end;
  Candidate := RootReal + PathDelim + Rel;
  if HostRealPath(Candidate, CandReal) then
  begin
    { Exists: the resolved real path (all symlinks followed) must be contained.
      A symlink inside the preopen pointing outside fails here. }
    if not IsPathUnder(CandReal, RootReal) then
      Exit(weNotCapable);
    AHostPath := CandReal;
    Exit(weSuccess);
  end;
  { Does not exist. }
  if ARequireExists then
    Exit(weNoEnt);
  Parent := ExtractFileDir(Candidate);
  if not HostRealPath(Parent, ParentReal) then
    Exit(weNoEnt);
  if not IsPathUnder(ExcludeTrailingPathDelimiter(ParentReal), RootReal) then
    Exit(weNotCapable);
  AHostPath := ExcludeTrailingPathDelimiter(ParentReal) + PathDelim +
    ExtractFileName(Candidate);
  Result := weSuccess;
end;

{ Stat a host path into TWasmHostStat. On POSIX via FpStat (full ino/dev/nlink/
  times); off-POSIX a best-effort size/type only. }
function HostStatPath(const APath: string; out AInfo: TWasmHostStat): Boolean;
{$IFDEF UNIX}
var
  St: Stat;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  if FpStat(PAnsiChar(AnsiString(APath)), St) <> 0 then
    Exit(False);
  AInfo.Dev := UInt64(St.st_dev);
  AInfo.Ino := UInt64(St.st_ino);
  AInfo.Nlink := UInt64(St.st_nlink);
  AInfo.Size := UInt64(St.st_size);
  AInfo.Atim := UInt64(St.st_atime) * UInt64(1000000000);
  AInfo.Mtim := UInt64(St.st_mtime) * UInt64(1000000000);
  AInfo.Ctim := UInt64(St.st_ctime) * UInt64(1000000000);
  if fpS_ISDIR(St.st_mode) then
    AInfo.Filetype := WASI_FILETYPE_DIRECTORY
  else if fpS_ISLNK(St.st_mode) then
    AInfo.Filetype := WASI_FILETYPE_SYMBOLIC_LINK
  else if fpS_ISREG(St.st_mode) then
    AInfo.Filetype := WASI_FILETYPE_REGULAR_FILE
  else
    AInfo.Filetype := WASI_FILETYPE_UNKNOWN;
  Result := True;
end;
{$ELSE}
var
  Sr: TSearchRec;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  AInfo.Nlink := 1;
  if DirectoryExists(APath) then
  begin
    AInfo.Filetype := WASI_FILETYPE_DIRECTORY;
    Exit(True);
  end;
  if FindFirst(APath, faAnyFile, Sr) = 0 then
  begin
    AInfo.Size := UInt64(Sr.Size);
    AInfo.Filetype := WASI_FILETYPE_REGULAR_FILE;
    FindClose(Sr);
    Exit(True);
  end;
  Result := False;
end;
{$ENDIF}

{ Enumerate a host directory into (name, ino, filetype) items, with "." and
  ".." first (real directories have them and wasi-libc expects them). }
function EnumHostDir(const AHostPath: string): TWasmDirItemArray;
var
  Base, Full: string;
  Sr: TSearchRec;
  Info: TWasmHostStat;
  Item: TWasmDirItem;

  procedure Add(const AName: string; const AIno: UInt64; const AFtype: Byte);
  begin
    Item.Name := AName;
    Item.Ino := AIno;
    Item.Ftype := AFtype;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Item;
  end;

begin
  Result := nil;
  Base := IncludeTrailingPathDelimiter(AHostPath);
  if HostStatPath(AHostPath, Info) then
    Add('.', Info.Ino, WASI_FILETYPE_DIRECTORY)
  else
    Add('.', 0, WASI_FILETYPE_DIRECTORY);
  Add('..', 0, WASI_FILETYPE_DIRECTORY);
  if FindFirst(Base + '*', faAnyFile, Sr) = 0 then
  begin
    try
      repeat
        if (Sr.Name = '.') or (Sr.Name = '..') then
          Continue;
        Full := Base + Sr.Name;
        if HostStatPath(Full, Info) then
          Add(Sr.Name, Info.Ino, Info.Filetype)
        else if (Sr.Attr and faDirectory) <> 0 then
          Add(Sr.Name, 0, WASI_FILETYPE_DIRECTORY)
        else
          Add(Sr.Name, 0, WASI_FILETYPE_REGULAR_FILE);
      until FindNext(Sr) <> 0;
    finally
      FindClose(Sr);
    end;
  end;
end;

{ Build a 64-byte filestat in a host buffer and write it, bounds-checked, at the
  guest result pointer (all-or-nothing). }
function WriteFilestat(const AMem: TWasmMemoryRef; const APtr: UInt64;
  const AInfo: TWasmHostStat): TWasmWasiErrno;
var
  Buf: TBytes;
begin
  SetLength(Buf, WASI_FILESTAT_SIZE);
  FillChar(Buf[0], WASI_FILESTAT_SIZE, 0);
  PokeU64(Buf, WASI_FILESTAT_DEV_OFF, AInfo.Dev);
  PokeU64(Buf, WASI_FILESTAT_INO_OFF, AInfo.Ino);
  Buf[WASI_FILESTAT_FILETYPE_OFF] := AInfo.Filetype;
  PokeU64(Buf, WASI_FILESTAT_NLINK_OFF, AInfo.Nlink);
  PokeU64(Buf, WASI_FILESTAT_SIZE_OFF, AInfo.Size);
  PokeU64(Buf, WASI_FILESTAT_ATIM_OFF, AInfo.Atim);
  PokeU64(Buf, WASI_FILESTAT_MTIM_OFF, AInfo.Mtim);
  PokeU64(Buf, WASI_FILESTAT_CTIM_OFF, AInfo.Ctim);
  Result := GuestWriteBytes(AMem, APtr, WASI_FILESTAT_SIZE, @Buf[0]);
end;

{ path_open(dirfd, dirflags, path_ptr, path_len, oflags, rights_base: i64,
            rights_inheriting: i64, fdflags, opened_fd_ptr) -> errno }
procedure Wasi_path_open(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Dir: PWasmWasiFdEntry;
  RootHost, GuestPath, HostPath: string;
  DirInherit, DirRights: TWasmWasiRights;
  DirPreopen: Integer;
  OFlags, FdFlags: UInt32;
  ReqBase, ReqInherit, NewRights, NewInherit: TWasmWasiRights;
  RequireExists, Exists, WantDir: Boolean;
  Handle: THandle;
  Mode: Integer;
  Entry: TWasmWasiFdEntry;
  NewFd: UInt32;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Dir := Ctx.FdEntry(AParams[0].U32);
  if Dir = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  if Dir^.Kind <> wfkDir then
  begin
    ReturnErrno(AResults, weNotDir);
    Exit;
  end;
  if (Dir^.Rights and WASI_RIGHTS_PATH_OPEN) = 0 then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;

  { Copy every dirfd field BEFORE AllocFd (which may reallocate the table and
    dangle Dir). }
  RootHost := Dir^.HostPath;
  DirInherit := Dir^.InheritRights;
  DirRights := Dir^.Rights;
  DirPreopen := Dir^.PreopenIndex;

  E := ReadGuestPath(Mem, UInt64(AParams[2].U32), UInt64(AParams[3].U32),
    GuestPath);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;

  OFlags := AParams[4].U32;
  ReqBase := TWasmWasiRights(AParams[5].I64);
  ReqInherit := TWasmWasiRights(AParams[6].I64);
  FdFlags := AParams[7].U32;
  { Rights masked monotonically by what the dirfd may pass on (embedding-spec.md
    §9.3): a derived fd never gains a right the parent's inheriting set lacked.
    W4 (documented v1 behaviour): an OVER-request — asking for a right the dirfd
    cannot pass on — is silently masked away here, not rejected with an errno.
    This is the intended posture (the mask is the capability; the request is a
    ceiling, not a demand), and it is safe precisely because masking can only
    REMOVE rights, never add them. The guest observes the granted set via
    fd_fdstat_get. }
  NewRights := ReqBase and DirInherit;
  NewInherit := ReqInherit and DirInherit;
  RequireExists := (OFlags and WASI_OFLAGS_CREAT) = 0;

  E := ResolveContained(RootHost, GuestPath, RequireExists, HostPath);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;

  { F4 (fd exhaustion): stop BEFORE opening any OS handle if the table is at its
    cap, so a guest cannot leak host descriptors by opening without closing.
    weMFile is EMFILE ("too many open files", the per-process limit). }
  if Ctx.AtFdLimit then
  begin
    ReturnErrno(AResults, weMfile);
    Exit;
  end;

  Entry := Default(TWasmWasiFdEntry);
  Entry.Used := True;
  Entry.Fdflags := Word(FdFlags);
  Entry.Rights := NewRights;
  Entry.InheritRights := NewInherit;
  Entry.IsPreopen := False;
  Entry.PreopenIndex := DirPreopen;
  Entry.GuestPath := '';
  Entry.Offset := 0;
  Entry.HostPath := HostPath;
  Entry.OsHandle := feInvalidHandle;

  WantDir := (OFlags and WASI_OFLAGS_DIRECTORY) <> 0;
  if DirectoryExists(HostPath) then
  begin
    { Opening a directory: no OS handle, enumerated on demand by fd_readdir. }
    Entry.Kind := wfkDir;
    Entry.Filetype := WASI_FILETYPE_DIRECTORY;
  end
  else
  begin
    if WantDir then
    begin
      { O_DIRECTORY but the target is not a directory (or is missing). }
      ReturnErrno(AResults, weNotDir);
      Exit;
    end;
    Exists := FileExists(HostPath);
    if ((OFlags and WASI_OFLAGS_CREAT) <> 0) and
      ((OFlags and WASI_OFLAGS_EXCL) <> 0) and Exists then
    begin
      ReturnErrno(AResults, weExist);
      Exit;
    end;
    if not Exists then
    begin
      if (OFlags and WASI_OFLAGS_CREAT) = 0 then
      begin
        ReturnErrno(AResults, weNoEnt);
        Exit;
      end;
      { F1 (containment escape): the target does not exist as a regular file, so
        we are about to CREATE it. If the leaf is itself a symlink, it is a
        dangling one (FileExists followed it and found nothing) that may point
        OUTSIDE the preopen — and ResolveContained only validated the parent for
        a non-existent target. Refuse to create THROUGH it (weNotCapable), the
        O_NOFOLLOW-on-leaf / wasmtime-conservative choice. A non-symlink leaf
        (the ordinary new-file case) is unaffected. }
      if LeafIsSymlink(HostPath) then
      begin
        ReturnErrno(AResults, weNotCapable);
        Exit;
      end;
      Handle := FileCreate(HostPath);   { create + open read/write }
    end
    else if ((OFlags and WASI_OFLAGS_TRUNC) <> 0) and
      ((NewRights and WASI_RIGHTS_FD_WRITE) <> 0) then
      { W4 (documented v1 behaviour): O_TRUNC is honoured only when the derived
        fd actually has FD_WRITE. When TRUNC is requested WITHOUT the write
        right, it is silently dropped (the file is opened untruncated in the
        read path below) rather than erroring — truncation needs write access,
        and the rights mask, not the oflag, is the capability. The existing
        HostPath here is the realpath-resolved target (ResolveContained
        followed the leaf), so it is never itself a symlink — the F1 guard is
        not needed on this branch. }
      Handle := FileCreate(HostPath)    { truncate an existing file }
    else
    begin
      if (NewRights and WASI_RIGHTS_FD_WRITE) <> 0 then
        Mode := fmOpenReadWrite
      else
        Mode := fmOpenRead;
      Handle := FileOpen(HostPath, Mode or fmShareDenyNone);
    end;
    if Handle = feInvalidHandle then
    begin
      { W2: report the REAL OS reason (ENOENT/EACCES/EEXIST/...), captured right
        after the failed open, instead of a fixed weAcces guess. }
      ReturnErrno(AResults, OsErrnoToWasi(GetLastOSError));
      Exit;
    end;
    Entry.Kind := wfkFile;
    Entry.Filetype := WASI_FILETYPE_REGULAR_FILE;
    Entry.OsHandle := Handle;
  end;

  NewFd := Ctx.AllocFd(Entry);
  E := GuestWriteU32(Mem, UInt64(AParams[8].U32), NewFd);
  if E <> weSuccess then
  begin
    { Could not hand the fd back: undo the open so no handle leaks. }
    if (Entry.Kind = wfkFile) and (Entry.OsHandle <> feInvalidHandle) then
      FileClose(Entry.OsHandle);
    Dir := Ctx.FdEntry(NewFd);
    if Dir <> nil then
    begin
      Dir^.OsHandle := feInvalidHandle;
      Dir^.Used := False;
    end;
    ReturnErrno(AResults, E);
    Exit;
  end;
  ReturnErrno(AResults, weSuccess);
end;

{ fd_filestat_get(fd, buf_ptr) -> errno }
procedure Wasi_fd_filestat_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  Info: TWasmHostStat;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  if Entry = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  { F6 (rights enforcement): stat is a capability like read/write. An fd that
    was not granted fd_filestat_get cannot be statted — weNotCapable — matching
    how fd_read/fd_write gate FD_READ/FD_WRITE. (fd_fdstat_get has NO rights bit
    in preview1 and is intentionally NOT gated; fd_seek already checks FD_SEEK.) }
  if (Entry^.Rights and WASI_RIGHTS_FD_FILESTAT_GET) = 0 then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;
  FillChar(Info, SizeOf(Info), 0);
  if Entry^.Kind = wfkStream then
  begin
    { A std stream has no host inode; report its filetype and zeros. }
    Info.Filetype := Entry^.Filetype;
    Info.Nlink := 1;
  end
  else if not HostStatPath(Entry^.HostPath, Info) then
  begin
    ReturnErrno(AResults, weIo);
    Exit;
  end;
  ReturnErrno(AResults, WriteFilestat(Mem, UInt64(AParams[1].U32), Info));
end;

{ path_filestat_get(dirfd, flags, path_ptr, path_len, buf_ptr) -> errno }
procedure Wasi_path_filestat_get(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Dir: PWasmWasiFdEntry;
  GuestPath, HostPath: string;
  Info: TWasmHostStat;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Dir := Ctx.FdEntry(AParams[0].U32);
  if Dir = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  if Dir^.Kind <> wfkDir then
  begin
    ReturnErrno(AResults, weNotDir);
    Exit;
  end;
  if (Dir^.Rights and WASI_RIGHTS_PATH_FILESTAT_GET) = 0 then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;
  E := ReadGuestPath(Mem, UInt64(AParams[2].U32), UInt64(AParams[3].U32),
    GuestPath);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;
  E := ResolveContained(Dir^.HostPath, GuestPath, True, HostPath);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;
  if not HostStatPath(HostPath, Info) then
  begin
    ReturnErrno(AResults, weNoEnt);
    Exit;
  end;
  ReturnErrno(AResults, WriteFilestat(Mem, UInt64(AParams[4].U32), Info));
end;

{ fd_readdir(fd, buf_ptr, buf_len, cookie: i64, bufused_ptr) -> errno }
procedure Wasi_fd_readdir(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Ctx: TWasmWasiContext;
  Mem: TWasmMemoryRef;
  Entry: PWasmWasiFdEntry;
  Items: TWasmDirItemArray;
  BufPtr: UInt64;
  BufLen, BufUsed, ToCopy: UInt32;
  Cookie, Index: Int64;
  NameBytes: TBytes;
  Rec: TBytes;
  RecLen: Integer;
  E: TWasmWasiErrno;
begin
  Ctx := TWasmWasiContext(AData);
  if not CtxMemory(Ctx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Entry := Ctx.FdEntry(AParams[0].U32);
  if Entry = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  if Entry^.Kind <> wfkDir then
  begin
    ReturnErrno(AResults, weNotDir);
    Exit;
  end;
  if (Entry^.Rights and WASI_RIGHTS_FD_READDIR) = 0 then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;

  BufPtr := UInt64(AParams[1].U32);
  BufLen := AParams[2].U32;
  Cookie := AParams[3].I64;
  { The whole target buffer must be in bounds before we write records. }
  if not GuestRangeValid(Mem, BufPtr, UInt64(BufLen)) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;

  Items := EnumHostDir(Entry^.HostPath);
  BufUsed := 0;
  Index := Cookie;
  { The cookie is the index of the next entry to emit; each dirent's d_next is
    the cookie that resumes AFTER it. A record that does not fit is written
    truncated and enumeration stops (the guest grows its buffer and retries).
    UNCONFIRMED: cookie stability if the directory mutates between calls — the
    entries are re-enumerated each call. }
  while (Index >= 0) and (Index <= High(Items)) and (BufUsed < BufLen) do
  begin
    NameBytes := StrBytes(Items[Index].Name);
    RecLen := WASI_DIRENT_SIZE + Length(NameBytes);
    SetLength(Rec, RecLen);
    FillChar(Rec[0], RecLen, 0);
    PokeU64(Rec, WASI_DIRENT_NEXT_OFF, UInt64(Index + 1));
    PokeU64(Rec, WASI_DIRENT_INO_OFF, Items[Index].Ino);
    PokeU32(Rec, WASI_DIRENT_NAMLEN_OFF, UInt32(Length(NameBytes)));
    Rec[WASI_DIRENT_TYPE_OFF] := Items[Index].Ftype;
    if Length(NameBytes) > 0 then
      Move(NameBytes[0], Rec[WASI_DIRENT_SIZE], Length(NameBytes));

    if UInt32(RecLen) <= (BufLen - BufUsed) then
      ToCopy := UInt32(RecLen)
    else
      ToCopy := BufLen - BufUsed;
    E := GuestWriteBytes(Mem, BufPtr + UInt64(BufUsed), UInt64(ToCopy),
      @Rec[0]);
    if E <> weSuccess then
    begin
      ReturnErrno(AResults, E);
      Exit;
    end;
    Inc(BufUsed, ToCopy);
    if ToCopy < UInt32(RecLen) then
      Break;   { record truncated — the buffer is full }
    Inc(Index);
  end;

  ReturnErrno(AResults, GuestWriteU32(Mem, UInt64(AParams[4].U32), BufUsed));
end;

{ Shared body for the three path-mutating ops (create dir / unlink / rmdir):
  validate the dirfd + right, read + contain the path, then dispatch. }
procedure PathMutate(const ACtx: TWasmWasiContext; const AParams: PWasmValue;
  const AResults: PWasmValue; const ARight: TWasmWasiRights;
  const ARequireExists: Boolean; const AOp: Integer);
const
  OP_MKDIR = 0;
  OP_UNLINK = 1;
  OP_RMDIR = 2;
var
  Mem: TWasmMemoryRef;
  Dir: PWasmWasiFdEntry;
  GuestPath, HostPath: string;
  E: TWasmWasiErrno;
begin
  if not CtxMemory(ACtx, Mem) then
  begin
    ReturnErrno(AResults, weFault);
    Exit;
  end;
  Dir := ACtx.FdEntry(AParams[0].U32);
  if Dir = nil then
  begin
    ReturnErrno(AResults, weBadf);
    Exit;
  end;
  if Dir^.Kind <> wfkDir then
  begin
    ReturnErrno(AResults, weNotDir);
    Exit;
  end;
  if (Dir^.Rights and ARight) = 0 then
  begin
    ReturnErrno(AResults, weNotCapable);
    Exit;
  end;
  E := ReadGuestPath(Mem, UInt64(AParams[1].U32), UInt64(AParams[2].U32),
    GuestPath);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;
  E := ResolveContained(Dir^.HostPath, GuestPath, ARequireExists, HostPath);
  if E <> weSuccess then
  begin
    ReturnErrno(AResults, E);
    Exit;
  end;

  { W2: the failure arms capture the real OS errno (GetLastOSError immediately
    after the failed syscall) and route it through OsErrnoToWasi, instead of a
    fixed guess — so a permission denial is weAcces, a read-only fs weRofs, a
    non-empty rmdir weNotEmpty, etc., honestly. }
  case AOp of
    OP_MKDIR:
      begin
        if DirectoryExists(HostPath) or FileExists(HostPath) then
          ReturnErrno(AResults, weExist)
        else if CreateDir(HostPath) then
          ReturnErrno(AResults, weSuccess)
        else
          ReturnErrno(AResults, OsErrnoToWasi(GetLastOSError));
      end;
    OP_UNLINK:
      begin
        if DirectoryExists(HostPath) then
          ReturnErrno(AResults, weIsDir)
        else if not FileExists(HostPath) then
          ReturnErrno(AResults, weNoEnt)
        else if DeleteFile(HostPath) then
          ReturnErrno(AResults, weSuccess)
        else
          ReturnErrno(AResults, OsErrnoToWasi(GetLastOSError));
      end;
    OP_RMDIR:
      begin
        if not DirectoryExists(HostPath) then
          ReturnErrno(AResults, weNotDir)
        else if RemoveDir(HostPath) then
          ReturnErrno(AResults, weSuccess)
        else
          ReturnErrno(AResults, OsErrnoToWasi(GetLastOSError));
      end;
  else
    ReturnErrno(AResults, weNoSys);
  end;
end;

{ path_create_directory(dirfd, path_ptr, path_len) -> errno }
procedure Wasi_path_create_directory(const AStore: TWasmStore;
  const AData: Pointer; const AParams: PWasmValue; const AResults: PWasmValue);
begin
  PathMutate(TWasmWasiContext(AData), AParams, AResults,
    WASI_RIGHTS_PATH_CREATE_DIRECTORY, False, 0);
end;

{ path_unlink_file(dirfd, path_ptr, path_len) -> errno }
procedure Wasi_path_unlink_file(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  PathMutate(TWasmWasiContext(AData), AParams, AResults,
    WASI_RIGHTS_PATH_UNLINK_FILE, True, 1);
end;

{ path_remove_directory(dirfd, path_ptr, path_len) -> errno }
procedure Wasi_path_remove_directory(const AStore: TWasmStore;
  const AData: Pointer; const AParams: PWasmValue; const AResults: PWasmValue);
begin
  PathMutate(TWasmWasiContext(AData), AParams, AResults,
    WASI_RIGHTS_PATH_REMOVE_DIRECTORY, True, 2);
end;

{ --- registration -------------------------------------------------------- }

procedure WasiDefineAll(const ALinker: TWasmLinker;
  const AContext: TWasmWasiContext);
var
  Data: Pointer;

  procedure Def(const AName: string;
    const AParams, AResults: array of TWasmValueType;
    const ACallback: TWasmHostFunc);
  begin
    ALinker.DefineFunc('wasi_snapshot_preview1', AName, AParams, AResults,
      ACallback, Data);
  end;

var
  I32, I64: TWasmValueType;
begin
  if (ALinker = nil) or (AContext = nil) then
    raise EWasmError.Create('WasiDefineAll needs a linker and a context');
  Data := Pointer(AContext);
  I32 := MakeNumValueType(wntI32);
  I64 := MakeNumValueType(wntI64);

  Def('args_get', [I32, I32], [I32], @Wasi_args_get);
  Def('args_sizes_get', [I32, I32], [I32], @Wasi_args_sizes_get);
  Def('environ_get', [I32, I32], [I32], @Wasi_environ_get);
  Def('environ_sizes_get', [I32, I32], [I32], @Wasi_environ_sizes_get);
  Def('fd_write', [I32, I32, I32, I32], [I32], @Wasi_fd_write);
  Def('fd_read', [I32, I32, I32, I32], [I32], @Wasi_fd_read);
  Def('fd_close', [I32], [I32], @Wasi_fd_close);
  Def('fd_seek', [I32, I64, I32, I32], [I32], @Wasi_fd_seek);
  Def('fd_fdstat_get', [I32, I32], [I32], @Wasi_fd_fdstat_get);
  Def('fd_prestat_get', [I32, I32], [I32], @Wasi_fd_prestat_get);
  Def('fd_prestat_dir_name', [I32, I32, I32], [I32],
    @Wasi_fd_prestat_dir_name);
  Def('clock_time_get', [I32, I64, I32], [I32], @Wasi_clock_time_get);
  Def('clock_res_get', [I32, I32], [I32], @Wasi_clock_res_get);
  Def('random_get', [I32, I32], [I32], @Wasi_random_get);
  Def('proc_exit', [I32], [], @Wasi_proc_exit);
  Def('sched_yield', [], [I32], @Wasi_sched_yield);

  { wave-2 (SHOULD) — the filesystem, via preopens (embedding-spec.md §3.3).
    Every one resolves guest paths under a preopen's host dir with strict
    containment; a `..`/absolute/escaping-symlink path is weNotCapable. }
  Def('path_open', [I32, I32, I32, I32, I32, I64, I64, I32, I32], [I32],
    @Wasi_path_open);
  Def('fd_filestat_get', [I32, I32], [I32], @Wasi_fd_filestat_get);
  Def('path_filestat_get', [I32, I32, I32, I32, I32], [I32],
    @Wasi_path_filestat_get);
  Def('fd_readdir', [I32, I32, I32, I64, I32], [I32], @Wasi_fd_readdir);
  Def('path_create_directory', [I32, I32, I32], [I32],
    @Wasi_path_create_directory);
  Def('path_unlink_file', [I32, I32, I32], [I32], @Wasi_path_unlink_file);
  Def('path_remove_directory', [I32, I32, I32], [I32],
    @Wasi_path_remove_directory);
end;

end.
