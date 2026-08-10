{ Wasm.Wasi.Types — the wasi_snapshot_preview1 constant surface: the errno
  enum, the filetype/clockid/whence/advice small enumerations, the
  rights/oflags/fdflags/lookupflags bit tables, and the guest-memory struct
  sizes/offsets every WASI preview1 function reads or writes.

  This is the bottom of Track F's WASI layer (embedding-spec.md §8.1): it
  depends on Wasm.Core ONLY and holds numbers, no logic. Wasm.Wasi.Memory
  (F2) reads structs at these offsets; Wasm.Wasi (F2/F4) returns these errno
  values and checks these rights bits; wasmlight run (F3) composes rights
  masks from them.

  SOURCE, and why it is not the `wasm` MCP: WASI preview1 is NOT part of the
  WebAssembly core specification, so the pinned `wasm-mcp` cannot serve it
  (embedding-spec.md §0/WASI pin). Every value below is transcribed from the
  frozen wasi_snapshot_preview1 ABI:

    - the `errno`, `filetype`, `rights`, `fdflags`, `oflags`, `lookupflags`,
      `clockid`, `whence`, `advice`, `preopentype`, `eventtype`, `filestat`,
      `fdstat`, `dirent`, `prestat`, `iovec`/`ciovec` type definitions live
      in WebAssembly/WASI's snapshot/witx/typenames.witx;
    - the function signatures that consume them live in
      snapshot/witx/wasi_snapshot_preview1.witx.

  AGENTS.md's "check the spec; do not recall it" applies to this ABI exactly
  as it applies to the core encoding: the numbers here are load-bearing and a
  wrong constant is the classic WASI defect. The errno numbering and the core
  struct layouts (iovec/ciovec/prestat/fdstat/filestat/dirent) are stable and
  well-established, and are marked CONFIRMED. The poll_oneoff subscription /
  event constants (MAY-scope, embedding-spec.md §3.3 wave 3) are marked
  UNCONFIRMED — F5's wasi-testsuite wave validates the whole surface against
  real modules, and any UNCONFIRMED value must be re-checked there. }
unit Wasm.Wasi.Types;

{$I Shared.inc}

interface

{ Layering (embedding-spec.md §8.1): this unit's permitted dependency ceiling
  is Wasm.Core and nothing else. It holds only numbers, so it references no
  other unit at all — the interface carries no `uses` clause. If a future
  helper needs the shared vocabulary, Wasm.Core (and only Wasm.Core) may be
  added here. }

type
  { --- errno ------------------------------------------------------------

    The wasi `errno` (typenames.witx `(typename $errno (enum (@witx tag u16)`).
    A u16 whose ORDINALS are the ABI numbers, contiguous 0..76 with no gaps.
    A WASI callback computes a TWasmWasiErrno and returns Ord(errno) as the
    i32 result; weSuccess = 0 is the success return (embedding-spec.md §3.4).

    CONFIRMED against typenames.witx: this is the frozen preview1 errno enum.
    The security-critical members the sandbox leans on are weBadf (fabricated
    fd), weFault (bad guest pointer), weNoEnt (missing path), weNoSys
    (unimplemented), and weNotCapable (the deny-by-default "capability
    insufficient" code, and the last member, ordinal 76). }
  TWasmWasiErrno = (
    weSuccess        = 0,   { no error }
    we2Big           = 1,   { E2BIG — argument list too long }
    weAcces          = 2,   { EACCES — permission denied }
    weAddrInUse      = 3,   { EADDRINUSE }
    weAddrNotAvail   = 4,   { EADDRNOTAVAIL }
    weAfNoSupport    = 5,   { EAFNOSUPPORT }
    weAgain          = 6,   { EAGAIN — resource unavailable, try again }
    weAlready        = 7,   { EALREADY }
    weBadf           = 8,   { EBADF — bad file descriptor }
    weBadMsg         = 9,   { EBADMSG }
    weBusy           = 10,  { EBUSY }
    weCanceled       = 11,  { ECANCELED }
    weChild          = 12,  { ECHILD }
    weConnAborted    = 13,  { ECONNABORTED }
    weConnRefused    = 14,  { ECONNREFUSED }
    weConnReset      = 15,  { ECONNRESET }
    weDeadlk         = 16,  { EDEADLK }
    weDestAddrReq    = 17,  { EDESTADDRREQ }
    weDom            = 18,  { EDOM }
    weDquot          = 19,  { EDQUOT }
    weExist          = 20,  { EEXIST — file exists }
    weFault          = 21,  { EFAULT — bad address (a bad guest pointer) }
    weFbig           = 22,  { EFBIG }
    weHostUnreach    = 23,  { EHOSTUNREACH }
    weIdrm           = 24,  { EIDRM }
    weIlseq          = 25,  { EILSEQ }
    weInProgress     = 26,  { EINPROGRESS }
    weIntr           = 27,  { EINTR }
    weInval          = 28,  { EINVAL — invalid argument }
    weIo             = 29,  { EIO }
    weIsConn         = 30,  { EISCONN }
    weIsDir          = 31,  { EISDIR — is a directory }
    weLoop           = 32,  { ELOOP — too many levels of symbolic links }
    weMfile          = 33,  { EMFILE }
    weMlink          = 34,  { EMLINK }
    weMsgSize        = 35,  { EMSGSIZE }
    weMultihop       = 36,  { EMULTIHOP }
    weNameTooLong    = 37,  { ENAMETOOLONG }
    weNetDown        = 38,  { ENETDOWN }
    weNetReset       = 39,  { ENETRESET }
    weNetUnreach     = 40,  { ENETUNREACH }
    weNfile          = 41,  { ENFILE }
    weNoBufs         = 42,  { ENOBUFS }
    weNoDev          = 43,  { ENODEV }
    weNoEnt          = 44,  { ENOENT — no such file or directory }
    weNoExec         = 45,  { ENOEXEC }
    weNoLck          = 46,  { ENOLCK }
    weNoLink         = 47,  { ENOLINK }
    weNoMem          = 48,  { ENOMEM }
    weNoMsg          = 49,  { ENOMSG }
    weNoProtoOpt     = 50,  { ENOPROTOOPT }
    weNoSpc          = 51,  { ENOSPC }
    weNoSys          = 52,  { ENOSYS — function not implemented }
    weNotConn        = 53,  { ENOTCONN }
    weNotDir         = 54,  { ENOTDIR — not a directory }
    weNotEmpty       = 55,  { ENOTEMPTY }
    weNotRecoverable = 56,  { ENOTRECOVERABLE }
    weNotSock        = 57,  { ENOTSOCK }
    weNotSup         = 58,  { ENOTSUP — not supported / operation not supported }
    weNoTty          = 59,  { ENOTTY }
    weNxio           = 60,  { ENXIO }
    weOverflow       = 61,  { EOVERFLOW }
    weOwnerDead      = 62,  { EOWNERDEAD }
    wePerm           = 63,  { EPERM }
    wePipe           = 64,  { EPIPE }
    weProto          = 65,  { EPROTO }
    weProtoNoSupport = 66,  { EPROTONOSUPPORT }
    weProtoType      = 67,  { EPROTOTYPE }
    weRange          = 68,  { ERANGE }
    weRofs           = 69,  { EROFS }
    weSpipe          = 70,  { ESPIPE — invalid seek (a stream, not a file) }
    weSrch           = 71,  { ESRCH }
    weStale          = 72,  { ESTALE }
    weTimedOut       = 73,  { ETIMEDOUT }
    weTxtBsy         = 74,  { ETXTBSY }
    weXdev           = 75,  { EXDEV }
    weNotCapable     = 76   { ENOTCAPABLE — capability insufficient (the
                             deny-by-default code; last member) }
  );

const
  { --- filetype (typenames.witx `$filetype`, u8) ------------------------
    CONFIRMED. Written into fdstat.fs_filetype and filestat.filetype. }
  WASI_FILETYPE_UNKNOWN          = Byte(0);
  WASI_FILETYPE_BLOCK_DEVICE     = Byte(1);
  WASI_FILETYPE_CHARACTER_DEVICE = Byte(2);
  WASI_FILETYPE_DIRECTORY        = Byte(3);
  WASI_FILETYPE_REGULAR_FILE     = Byte(4);
  WASI_FILETYPE_SOCKET_DGRAM     = Byte(5);
  WASI_FILETYPE_SOCKET_STREAM    = Byte(6);
  WASI_FILETYPE_SYMBOLIC_LINK    = Byte(7);

  { --- clockid (typenames.witx `$clockid`, u32) -------------------------
    CONFIRMED. The `id` argument of clock_time_get / clock_res_get. }
  WASI_CLOCKID_REALTIME           = UInt32(0);
  WASI_CLOCKID_MONOTONIC          = UInt32(1);
  WASI_CLOCKID_PROCESS_CPUTIME_ID = UInt32(2);
  WASI_CLOCKID_THREAD_CPUTIME_ID  = UInt32(3);

  { --- whence (typenames.witx `$whence`, u8) ----------------------------
    CONFIRMED. The `whence` argument of fd_seek. Preview1 ordering is
    set/cur/end — NOTE this is NOT the historical POSIX SEEK_* ordering in
    every libc, so it is transcribed from the witx, not from <stdio.h>. }
  WASI_WHENCE_SET = Byte(0);
  WASI_WHENCE_CUR = Byte(1);
  WASI_WHENCE_END = Byte(2);

  { --- preopentype (typenames.witx `$preopentype`, u8) ------------------
    CONFIRMED. fd_prestat_get writes a prestat whose tag is one of these;
    DIR is the only assigned value in preview1. }
  WASI_PREOPENTYPE_DIR = Byte(0);

  { --- advice (typenames.witx `$advice`, u8) ----------------------------
    CONFIRMED. The `advice` argument of fd_advise (wave 2; may no-op). }
  WASI_ADVICE_NORMAL     = Byte(0);
  WASI_ADVICE_SEQUENTIAL = Byte(1);
  WASI_ADVICE_RANDOM     = Byte(2);
  WASI_ADVICE_WILLNEED   = Byte(3);
  WASI_ADVICE_DONTNEED   = Byte(4);
  WASI_ADVICE_NOREUSE    = Byte(5);

  { --- lookupflags (typenames.witx `$lookupflags`, u32 flags) -----------
    CONFIRMED. The `dirflags` argument of path_open / path_filestat_get.
    A single flag: follow symlinks during path resolution. }
  WASI_LOOKUPFLAGS_SYMLINK_FOLLOW = UInt32(1) shl 0;   { = 1 }

  { --- oflags (typenames.witx `$oflags`, u16 flags) ---------------------
    CONFIRMED. The `oflags` argument of path_open. }
  WASI_OFLAGS_CREAT     = Word(1) shl 0;   { = 1  create if nonexistent }
  WASI_OFLAGS_DIRECTORY = Word(1) shl 1;   { = 2  fail if not a directory }
  WASI_OFLAGS_EXCL      = Word(1) shl 2;   { = 4  fail if already exists }
  WASI_OFLAGS_TRUNC     = Word(1) shl 3;   { = 8  truncate to zero length }

  { --- fdflags (typenames.witx `$fdflags`, u16 flags) -------------------
    CONFIRMED. fdstat.fs_flags, and the `fdflags` argument of path_open /
    fd_fdstat_set_flags. }
  WASI_FDFLAGS_APPEND   = Word(1) shl 0;   { = 1  }
  WASI_FDFLAGS_DSYNC    = Word(1) shl 1;   { = 2  }
  WASI_FDFLAGS_NONBLOCK = Word(1) shl 2;   { = 4  }
  WASI_FDFLAGS_RSYNC    = Word(1) shl 3;   { = 8  }
  WASI_FDFLAGS_SYNC     = Word(1) shl 4;   { = 16 }

  { --- eventtype / subscription (typenames.witx, poll_oneoff) -----------
    UNCONFIRMED — poll_oneoff is wave-3 MAY / stubbed ENOSYS in v1
    (embedding-spec.md §3.3, §8.3). Included so F5 has the numbers to check;
    re-verify against typenames.witx before any real poll_oneoff lands. }
  WASI_EVENTTYPE_CLOCK    = Byte(0);   { UNCONFIRMED }
  WASI_EVENTTYPE_FD_READ  = Byte(1);   { UNCONFIRMED }
  WASI_EVENTTYPE_FD_WRITE = Byte(2);   { UNCONFIRMED }

  { subclockflags: absolute vs relative clock subscription. UNCONFIRMED. }
  WASI_SUBCLOCKFLAGS_ABSTIME = Word(1) shl 0;   { = 1  UNCONFIRMED }

  { eventrwflags: the read/write event's hangup bit. UNCONFIRMED. }
  WASI_EVENTRWFLAGS_FD_READWRITE_HANGUP = Word(1) shl 0;   { = 1 UNCONFIRMED }

type
  { --- rights (typenames.witx `$rights`, u64 flags) ---------------------
    CONFIRMED. The capability bitmask carried on every fd and masked
    monotonically as fds are derived (embedding-spec.md §2.4, §9.3). A
    distinct type so a rights value is never silently confused with a plain
    UInt64 in the fd table or the linker. }
  TWasmWasiRights = UInt64;

const
  { Bit positions per typenames.witx, bit 0 = fd_datasync. }
  WASI_RIGHTS_FD_DATASYNC             : TWasmWasiRights = UInt64(1) shl 0;
  WASI_RIGHTS_FD_READ                 : TWasmWasiRights = UInt64(1) shl 1;
  WASI_RIGHTS_FD_SEEK                 : TWasmWasiRights = UInt64(1) shl 2;
  WASI_RIGHTS_FD_FDSTAT_SET_FLAGS     : TWasmWasiRights = UInt64(1) shl 3;
  WASI_RIGHTS_FD_SYNC                 : TWasmWasiRights = UInt64(1) shl 4;
  WASI_RIGHTS_FD_TELL                 : TWasmWasiRights = UInt64(1) shl 5;
  WASI_RIGHTS_FD_WRITE                : TWasmWasiRights = UInt64(1) shl 6;
  WASI_RIGHTS_FD_ADVISE               : TWasmWasiRights = UInt64(1) shl 7;
  WASI_RIGHTS_FD_ALLOCATE             : TWasmWasiRights = UInt64(1) shl 8;
  WASI_RIGHTS_PATH_CREATE_DIRECTORY   : TWasmWasiRights = UInt64(1) shl 9;
  WASI_RIGHTS_PATH_CREATE_FILE        : TWasmWasiRights = UInt64(1) shl 10;
  WASI_RIGHTS_PATH_LINK_SOURCE        : TWasmWasiRights = UInt64(1) shl 11;
  WASI_RIGHTS_PATH_LINK_TARGET        : TWasmWasiRights = UInt64(1) shl 12;
  WASI_RIGHTS_PATH_OPEN               : TWasmWasiRights = UInt64(1) shl 13;
  WASI_RIGHTS_FD_READDIR              : TWasmWasiRights = UInt64(1) shl 14;
  WASI_RIGHTS_PATH_READLINK           : TWasmWasiRights = UInt64(1) shl 15;
  WASI_RIGHTS_PATH_RENAME_SOURCE      : TWasmWasiRights = UInt64(1) shl 16;
  WASI_RIGHTS_PATH_RENAME_TARGET      : TWasmWasiRights = UInt64(1) shl 17;
  WASI_RIGHTS_PATH_FILESTAT_GET       : TWasmWasiRights = UInt64(1) shl 18;
  WASI_RIGHTS_PATH_FILESTAT_SET_SIZE  : TWasmWasiRights = UInt64(1) shl 19;
  WASI_RIGHTS_PATH_FILESTAT_SET_TIMES : TWasmWasiRights = UInt64(1) shl 20;
  WASI_RIGHTS_FD_FILESTAT_GET         : TWasmWasiRights = UInt64(1) shl 21;
  WASI_RIGHTS_FD_FILESTAT_SET_SIZE    : TWasmWasiRights = UInt64(1) shl 22;
  WASI_RIGHTS_FD_FILESTAT_SET_TIMES   : TWasmWasiRights = UInt64(1) shl 23;
  WASI_RIGHTS_PATH_SYMLINK            : TWasmWasiRights = UInt64(1) shl 24;
  WASI_RIGHTS_PATH_REMOVE_DIRECTORY   : TWasmWasiRights = UInt64(1) shl 25;
  WASI_RIGHTS_PATH_UNLINK_FILE        : TWasmWasiRights = UInt64(1) shl 26;
  WASI_RIGHTS_POLL_FD_READWRITE       : TWasmWasiRights = UInt64(1) shl 27;
  WASI_RIGHTS_SOCK_SHUTDOWN           : TWasmWasiRights = UInt64(1) shl 28;
  WASI_RIGHTS_SOCK_ACCEPT             : TWasmWasiRights = UInt64(1) shl 29;

  { --- struct sizes and field offsets (wasm32 widths, little-endian) ----

    Every preview1 struct is read/written in guest linear memory at these
    byte offsets (embedding-spec.md §3.3, §5). Offsets follow the witx
    record layout with C-style natural alignment: a u64 field is 8-aligned,
    which is where the padding gaps come from. All CONFIRMED against
    typenames.witx; struct-layout bugs are the classic WASI defect
    (embedding-spec.md §3.3) so these are asserted exactly in the F0 tests
    and re-checked by F2/F4/F5.

    Offsets are wasm32: pointers/lengths are u32. Under memory64 the runtime
    treats offsets as u64 but these struct widths stay wasm32
    (embedding-spec.md §8.3). }

  { iovec / ciovec — a (buf: pointer, buf_len: size) pair, 8 bytes on
    wasm32. ciovec (const, for fd_write) and iovec (for fd_read) are
    identical. }
  WASI_CIOVEC_BUF_OFF     = 0;
  WASI_CIOVEC_BUF_LEN_OFF = 4;
  WASI_CIOVEC_SIZE        = 8;
  WASI_IOVEC_BUF_OFF      = 0;
  WASI_IOVEC_BUF_LEN_OFF  = 4;
  WASI_IOVEC_SIZE         = 8;

  { prestat — a u8 tag followed by a union whose dir arm is a single u32
    pr_name_len. The union is 4-aligned, so pr_name_len sits at offset 4;
    size 8. }
  WASI_PRESTAT_TAG_OFF          = 0;
  WASI_PRESTAT_DIR_NAMELEN_OFF  = 4;
  WASI_PRESTAT_SIZE             = 8;

  { fdstat — fs_filetype (u8), fs_flags (u16), fs_rights_base (u64),
    fs_rights_inheriting (u64). filetype @0, flags @2, then 8-aligned rights
    at @8 and @16; size 24. }
  WASI_FDSTAT_FILETYPE_OFF           = 0;
  WASI_FDSTAT_FLAGS_OFF              = 2;
  WASI_FDSTAT_RIGHTS_BASE_OFF        = 8;
  WASI_FDSTAT_RIGHTS_INHERITING_OFF  = 16;
  WASI_FDSTAT_SIZE                   = 24;

  { filestat — dev (u64), ino (u64), filetype (u8), nlink (u64), size (u64),
    atim (u64), mtim (u64), ctim (u64). filetype @16 is a u8 padded to the
    8-aligned nlink @24; size 64. }
  WASI_FILESTAT_DEV_OFF      = 0;
  WASI_FILESTAT_INO_OFF      = 8;
  WASI_FILESTAT_FILETYPE_OFF = 16;
  WASI_FILESTAT_NLINK_OFF    = 24;
  WASI_FILESTAT_SIZE_OFF     = 32;
  WASI_FILESTAT_ATIM_OFF     = 40;
  WASI_FILESTAT_MTIM_OFF     = 48;
  WASI_FILESTAT_CTIM_OFF     = 56;
  WASI_FILESTAT_SIZE         = 64;

  { dirent — d_next (u64), d_ino (u64), d_namlen (u32), d_type (u8): the
    fixed header written before each name by fd_readdir; header 24 bytes
    (d_type @20 padded to 24), name bytes follow. }
  WASI_DIRENT_NEXT_OFF   = 0;
  WASI_DIRENT_INO_OFF    = 8;
  WASI_DIRENT_NAMLEN_OFF = 16;
  WASI_DIRENT_TYPE_OFF   = 20;
  WASI_DIRENT_SIZE       = 24;

{ The errno's ABI number: Ord of the enum, widened to the u16 the wasm ABI
  returns as an i32 result. Ordinals equal the ABI numbers by construction,
  so this is Ord() named for intent — a WASI callback writes
  WasiErrnoCode(errno) into AResults[0]. }
function WasiErrnoCode(const AErrno: TWasmWasiErrno): UInt16;

implementation

function WasiErrnoCode(const AErrno: TWasmWasiErrno): UInt16;
begin
  Result := UInt16(Ord(AErrno));
end;

end.
