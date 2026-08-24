{ Wasm.Target — host-independent 64-bit Unix target triples and ABI
  descriptors ([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md)).

  The shipped JIT/AOT used to pick an architecture from host CPU/OS defines
  and to fingerprint artifacts from SizeOf and live record layout. That
  prevents one compiler binary from describing another released target.
  This unit is the seam those later compile/shell issues consume: every
  supported compiler can construct every 64-bit Unix target descriptor
  without executing target code, and artifact fingerprints plus baked
  runtime offsets come from the selected descriptor.

  THE FIRST RELEASED SET (ADR-0015) is AArch64 and x86-64 on Darwin and
  Linux. Win64 and i386 Windows are later releases; ARM32 and i386 Linux
  are out of scope. Triple spellings follow the LLVM/Rust arch-vendor-os
  form (aarch64-apple-darwin, aarch64-unknown-linux-gnu,
  x86_64-apple-darwin, x86_64-unknown-linux-gnu).

  CALLING CONVENTIONS are recorded, not re-derived:
    - AArch64 Linux uses AAPCS64 (ARM IHI 0055 / abi-aa aapcs64).
    - AArch64 Darwin uses Apple's AAPCS64 variant (x18 reserved; Apple
      Developer "Writing ARM64 code for Apple platforms").
    - x86-64 Linux and Darwin use the System V AMD64 ABI.

  OBJECT FORMAT and PAGE SIZE belong to the descriptor so ELF/Mach-O
  shells (#36/#37) do not invent a second target vocabulary. Emission
  may consume a requested target whose OS differs from the compiler
  host; executable-memory allocation and native invocation stay
  host-gated in Wasm.Jit.CodeBuffer.

  The published LP64 Unix layout is a table of the offsets a foreign
  target's emission bakes. Host-native JIT/AOT still read the live
  store so a compiler-profile layout shift cannot crash the running
  binary; host tests pin every field against those live records on
  each 64-bit Unix CI leg. Fingerprint folding lives here so AOT does
  not re-measure SizeOf at compile or load on a supported target.

  Depends on Wasm.Core alone. }
unit Wasm.Target;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  { Canonical LLVM/Rust-style triples for the four released 64-bit Unix
    targets. Parse is an exact match on these strings. }
  WASM_TARGET_TRIPLE_AARCH64_DARWIN = 'aarch64-apple-darwin';
  WASM_TARGET_TRIPLE_AARCH64_LINUX = 'aarch64-unknown-linux-gnu';
  WASM_TARGET_TRIPLE_X86_64_DARWIN = 'x86_64-apple-darwin';
  WASM_TARGET_TRIPLE_X86_64_LINUX = 'x86_64-unknown-linux-gnu';

  { Number of constructable 64-bit Unix targets. }
  WASM_TARGET_COUNT = 4;

  { Matches Wasm.Aot.Artifact's WAOT_ARCH_* so AOT headers stay a single
    numbering. Kept here so this unit does not depend on the AOT format. }
  WASM_TARGET_WAOT_ARCH_UNKNOWN = Byte(0);
  WASM_TARGET_WAOT_ARCH_AARCH64 = Byte(1);
  WASM_TARGET_WAOT_ARCH_X64 = Byte(2);

  { Published LP64 Unix sizes the compiling tiers bake. TWasmIrInstr is
    compile-time pinned at 24 bytes; TWasmValue is the 8-byte slot. }
  WASM_TARGET_IR_INSTR_SIZE = UInt32(24);
  WASM_TARGET_VALUE_SLOT_SIZE = UInt32(8);

  { Must stay equal to AOT_HELPER_COUNT in Wasm.Runtime.Store. }
  WASM_TARGET_HELPER_COUNT = UInt32(17);

  { Must stay equal to AOT_ABI_REVISION in Wasm.Interp. Identity fields
    are folded in addition to this revision, so two OS descriptors of the
    same arch do not share a fingerprint. }
  WASM_TARGET_ABI_REVISION = UInt32(15);

  WASM_TARGET_POINTER_SIZE = Byte(8);
  WASM_TARGET_PAGE_SIZE_4K = UInt32(4096);
  WASM_TARGET_PAGE_SIZE_16K = UInt32(16384);

type
  TWasmTargetArch = (
    wtaUnknown,
    wtaAArch64,
    wtaX86_64
  );

  TWasmTargetOs = (
    wtoUnknown,
    wtoDarwin,
    wtoLinux
  );

  TWasmObjectFormat = (
    wofUnknown,
    wofElf,
    wofMachO
  );

  TWasmCallingConvention = (
    wccUnknown,
    wccAapcs64,
    wccAapcs64Apple,
    wccSysVAmd64
  );

  { Architecture plus OS. The four released combinations are the only
    supported values; anything else is constructable as a query and
    rejected by WasmTargetSupported. }
  TWasmTarget = record
    Arch: TWasmTargetArch;
    Os: TWasmTargetOs;
  end;

  { Runtime-shell field offsets the compiling tiers bake into machine
    code. Values are the published LP64 Unix layout, not a live SizeOf. }
  TWasmTargetLayout = record
    StoreEpoch: UInt64;
    StoreEpochSnapshot: UInt64;
    StoreJitHelperTable: UInt64;
    FuncInstStride: UInt64;
    FuncKind: UInt64;
    FuncCompiledEntry: UInt64;
    FuncCompiledDirectEntry: UInt64;
    FuncCompiledNativeScalarEntry: UInt64;
    FuncDirectMeta: UInt64;
    DirectMetaFn: UInt64;
    DirectMetaIrBase: UInt64;
    DirectMetaFuncAddrs: UInt64;
    DirectMetaEntryZeroRegs: UInt64;
    DirectMetaRefRegBits: UInt64;
    DirectMetaRegisterCount: UInt64;
    DirectMetaEntryZeroCount: UInt64;
    DirectMetaParam0Reg: UInt64;
    DirectMetaParam1Reg: UInt64;
    DirectMetaResult0Reg: UInt64;
    FuncCallCount: UInt64;
    MemInstStride: UInt64;
    MemBase: UInt64;
    MemByteSize: UInt64;
    StoreFHeap: UInt64;
    StoreTierContext: UInt64;
    InstEngineTypeIds: UInt64;
    HeapFFree0: UInt64;
    HeapMarkState: UInt64;
    HeapBytesLive: UInt64;
    HeapBytesAllocated: UInt64;
    HeapObjectCount: UInt64;
    BlockBase: UInt64;
    BlockAllocated: UInt64;
    CtxValues: UInt64;
    CtxValueTop: UInt64;
    CtxValueCap: UInt64;
    CtxActs: UInt64;
    CtxDepthCap: UInt64;
    CtxDepth: UInt64;
    CtxFuncsSlot: UInt64;
    CtxGcFrameSlot: UInt64;
    ActStride: UInt64;
    ActBase: UInt64;
    ActFn: UInt64;
    ActInstance: UInt64;
    ActFuncAddrs: UInt64;
    ActIP: UInt64;
    ActGcFrame: UInt64;
    ActRetKind: UInt64;
    ActRetDest: UInt64;
    ActRetCount: UInt64;
    ActRetBase: UInt64;
    ActEntryResults: UInt64;
    GcFramePrev: UInt64;
    GcFrameSlots: UInt64;
    GcFrameRefRegBits: UInt64;
    GcFrameRegisterCount: UInt64;
    GcFrameInstance: UInt64;
  end;

  { Complete ABI description for one released target. }
  TWasmTargetAbi = record
    Target: TWasmTarget;
    Triple: string;
    ObjectFormat: TWasmObjectFormat;
    CallingConvention: TWasmCallingConvention;
    PointerSize: Byte;
    PageSize: UInt32;
    WaotArch: Byte;
    IrInstrSize: UInt32;
    ValueSlotSize: UInt32;
    HelperCount: UInt32;
    AbiRevision: UInt32;
    Layout: TWasmTargetLayout;
  end;

{ The compiler-host target: CPU and OS defines name the host, they do
  not select which descriptor emission may consume. }
function WasmTargetHost: TWasmTarget;

{ Construct a target from architecture and OS. }
function WasmTargetOf(const AArch: TWasmTargetArch;
  const AOs: TWasmTargetOs): TWasmTarget;

{ True iff ATarget is one of the four released 64-bit Unix combinations. }
function WasmTargetSupported(const ATarget: TWasmTarget): Boolean;

{ Stable index 0 .. WASM_TARGET_COUNT-1 over the released set. }
function WasmTargetByIndex(const AIndex: Integer): TWasmTarget;

{ Exact-match parse of a canonical triple. }
function WasmTargetParse(const ATriple: string;
  out ATarget: TWasmTarget): Boolean;

function WasmTargetTriple(const ATarget: TWasmTarget): string;

function WasmTargetEqual(const A, B: TWasmTarget): Boolean;

{ Full ABI descriptor. Supported targets receive the published LP64 Unix
  layout; an unsupported query is zeroed except for Target and WaotArch. }
function WasmTargetAbi(const ATarget: TWasmTarget): TWasmTargetAbi;

{ FNV-1a-64 over the descriptor — identity plus published layout. Does
  not read SizeOf or a live store. }
function WasmTargetAbiFingerprint(const AAbi: TWasmTargetAbi): UInt64;

{ True when this compiler can emit bytes for ATarget's ISA. Same-arch
  foreign-OS targets are emittable; executable mapping is a separate
  question. }
function WasmTargetCanEmit(const ATarget: TWasmTarget): Boolean;

{ True only when ATarget is this process's host and the process may
  allocate executable memory (64-bit Unix). }
function WasmTargetCanExecute(const ATarget: TWasmTarget): Boolean;

implementation

function WaotArchFor(const AArch: TWasmTargetArch): Byte;
begin
  case AArch of
    wtaAArch64:
      Result := WASM_TARGET_WAOT_ARCH_AARCH64;
    wtaX86_64:
      Result := WASM_TARGET_WAOT_ARCH_X64;
  else
    Result := WASM_TARGET_WAOT_ARCH_UNKNOWN;
  end;
end;

function WasmTargetOf(const AArch: TWasmTargetArch;
  const AOs: TWasmTargetOs): TWasmTarget;
begin
  Result.Arch := AArch;
  Result.Os := AOs;
end;

function WasmTargetHost: TWasmTarget;
begin
  Result.Arch := wtaUnknown;
  Result.Os := wtoUnknown;
  {$IFDEF CPUAARCH64}
  Result.Arch := wtaAArch64;
  {$ENDIF}
  {$IFDEF CPUX86_64}
  Result.Arch := wtaX86_64;
  {$ENDIF}
  {$IFDEF DARWIN}
  Result.Os := wtoDarwin;
  {$ENDIF}
  {$IFDEF LINUX}
  Result.Os := wtoLinux;
  {$ENDIF}
end;

function WasmTargetSupported(const ATarget: TWasmTarget): Boolean;
begin
  Result := (ATarget.Arch in [wtaAArch64, wtaX86_64]) and
    (ATarget.Os in [wtoDarwin, wtoLinux]);
end;

function WasmTargetByIndex(const AIndex: Integer): TWasmTarget;
begin
  case AIndex of
    0:
      Result := WasmTargetOf(wtaAArch64, wtoDarwin);
    1:
      Result := WasmTargetOf(wtaAArch64, wtoLinux);
    2:
      Result := WasmTargetOf(wtaX86_64, wtoDarwin);
    3:
      Result := WasmTargetOf(wtaX86_64, wtoLinux);
  else
    Result := WasmTargetOf(wtaUnknown, wtoUnknown);
  end;
end;

function WasmTargetParse(const ATriple: string;
  out ATarget: TWasmTarget): Boolean;
begin
  Result := True;
  if ATriple = WASM_TARGET_TRIPLE_AARCH64_DARWIN then
    ATarget := WasmTargetOf(wtaAArch64, wtoDarwin)
  else if ATriple = WASM_TARGET_TRIPLE_AARCH64_LINUX then
    ATarget := WasmTargetOf(wtaAArch64, wtoLinux)
  else if ATriple = WASM_TARGET_TRIPLE_X86_64_DARWIN then
    ATarget := WasmTargetOf(wtaX86_64, wtoDarwin)
  else if ATriple = WASM_TARGET_TRIPLE_X86_64_LINUX then
    ATarget := WasmTargetOf(wtaX86_64, wtoLinux)
  else
  begin
    ATarget := WasmTargetOf(wtaUnknown, wtoUnknown);
    Result := False;
  end;
end;

function WasmTargetTriple(const ATarget: TWasmTarget): string;
begin
  if (ATarget.Arch = wtaAArch64) and (ATarget.Os = wtoDarwin) then
    Result := WASM_TARGET_TRIPLE_AARCH64_DARWIN
  else if (ATarget.Arch = wtaAArch64) and (ATarget.Os = wtoLinux) then
    Result := WASM_TARGET_TRIPLE_AARCH64_LINUX
  else if (ATarget.Arch = wtaX86_64) and (ATarget.Os = wtoDarwin) then
    Result := WASM_TARGET_TRIPLE_X86_64_DARWIN
  else if (ATarget.Arch = wtaX86_64) and (ATarget.Os = wtoLinux) then
    Result := WASM_TARGET_TRIPLE_X86_64_LINUX
  else
    Result := '';
end;

function WasmTargetEqual(const A, B: TWasmTarget): Boolean;
begin
  Result := (A.Arch = B.Arch) and (A.Os = B.Os);
end;

function PublishedLp64UnixLayout: TWasmTargetLayout;
begin
  { Measured on FPC 3.2.2 Delphi-mode LP64 Unix (aarch64-darwin) and
    pinned on every 64-bit Unix CI host against the live records. }
  FillChar(Result, SizeOf(Result), 0);
  Result.StoreEpoch := 128;
  Result.StoreEpochSnapshot := 136;
  Result.StoreJitHelperTable := 160;
  Result.FuncInstStride := 144;
  Result.FuncKind := 0;
  Result.FuncCompiledEntry := 32;
  Result.FuncCompiledDirectEntry := 40;
  Result.FuncCompiledNativeScalarEntry := 48;
  Result.FuncDirectMeta := 64;
  Result.DirectMetaFn := 0;
  Result.DirectMetaIrBase := 8;
  Result.DirectMetaFuncAddrs := 16;
  Result.DirectMetaEntryZeroRegs := 24;
  Result.DirectMetaRefRegBits := 32;
  Result.DirectMetaRegisterCount := 40;
  Result.DirectMetaEntryZeroCount := 44;
  Result.DirectMetaParam0Reg := 48;
  Result.DirectMetaParam1Reg := 52;
  Result.DirectMetaResult0Reg := 56;
  Result.FuncCallCount := 56;
  Result.MemInstStride := 80;
  Result.MemBase := 0;
  Result.MemByteSize := 8;
  Result.StoreFHeap := 24;
  Result.StoreTierContext := 168;
  Result.InstEngineTypeIds := 88;
  Result.HeapFFree0 := 48;
  Result.HeapMarkState := 264;
  Result.HeapBytesLive := 280;
  Result.HeapBytesAllocated := 288;
  Result.HeapObjectCount := 312;
  Result.BlockBase := 8;
  Result.BlockAllocated := 32;
  Result.CtxValues := 8;
  Result.CtxValueTop := 32;
  Result.CtxValueCap := 24;
  Result.CtxActs := 40;
  Result.CtxDepthCap := 48;
  Result.CtxDepth := 56;
  Result.CtxFuncsSlot := 64;
  Result.CtxGcFrameSlot := 72;
  Result.ActStride := 120;
  Result.ActBase := 32;
  Result.ActFn := 0;
  Result.ActInstance := 8;
  Result.ActFuncAddrs := 16;
  Result.ActIP := 24;
  Result.ActGcFrame := 40;
  Result.ActRetKind := 80;
  Result.ActRetDest := 88;
  Result.ActRetCount := 96;
  Result.ActRetBase := 104;
  Result.ActEntryResults := 112;
  Result.GcFramePrev := 0;
  Result.GcFrameSlots := 8;
  Result.GcFrameRefRegBits := 16;
  Result.GcFrameRegisterCount := 24;
  Result.GcFrameInstance := 32;
end;

function WasmTargetAbi(const ATarget: TWasmTarget): TWasmTargetAbi;
begin
  Result.Target := ATarget;
  Result.Triple := '';
  Result.ObjectFormat := wofUnknown;
  Result.CallingConvention := wccUnknown;
  Result.PointerSize := WASM_TARGET_POINTER_SIZE;
  Result.PageSize := 0;
  Result.WaotArch := WaotArchFor(ATarget.Arch);
  Result.IrInstrSize := WASM_TARGET_IR_INSTR_SIZE;
  Result.ValueSlotSize := WASM_TARGET_VALUE_SLOT_SIZE;
  Result.HelperCount := WASM_TARGET_HELPER_COUNT;
  Result.AbiRevision := WASM_TARGET_ABI_REVISION;
  FillChar(Result.Layout, SizeOf(Result.Layout), 0);
  if not WasmTargetSupported(ATarget) then
    Exit;

  Result.Triple := WasmTargetTriple(ATarget);
  Result.Layout := PublishedLp64UnixLayout;
  case ATarget.Os of
    wtoDarwin:
      begin
        Result.ObjectFormat := wofMachO;
        if ATarget.Arch = wtaAArch64 then
          Result.PageSize := WASM_TARGET_PAGE_SIZE_16K
        else
          Result.PageSize := WASM_TARGET_PAGE_SIZE_4K;
      end;
    wtoLinux:
      begin
        Result.ObjectFormat := wofElf;
        Result.PageSize := WASM_TARGET_PAGE_SIZE_4K;
      end;
  else
    Result.ObjectFormat := wofUnknown;
  end;
  case ATarget.Arch of
    wtaAArch64:
      if ATarget.Os = wtoDarwin then
        Result.CallingConvention := wccAapcs64Apple
      else
        Result.CallingConvention := wccAapcs64;
    wtaX86_64:
      Result.CallingConvention := wccSysVAmd64;
  else
    Result.CallingConvention := wccUnknown;
  end;
end;

{$push}{$Q-}{$R-}
function WasmTargetAbiFingerprint(const AAbi: TWasmTargetAbi): UInt64;
var
  H: UInt64;

  procedure Fold(const AValue: UInt64);
  var
    I: Integer;
    V: UInt64;
  begin
    V := AValue;
    for I := 0 to 7 do
    begin
      H := H xor (V and $FF);
      H := H * UInt64($00000100000001B3);
      V := V shr 8;
    end;
  end;

begin
  H := UInt64($CBF29CE484222325);
  Fold(UInt64(Ord(AAbi.Target.Arch)));
  Fold(UInt64(Ord(AAbi.Target.Os)));
  Fold(UInt64(Ord(AAbi.ObjectFormat)));
  Fold(UInt64(Ord(AAbi.CallingConvention)));
  Fold(AAbi.PointerSize);
  Fold(AAbi.PageSize);
  Fold(AAbi.WaotArch);

  Fold(AAbi.Layout.StoreEpoch);
  Fold(AAbi.Layout.StoreEpochSnapshot);
  Fold(AAbi.Layout.StoreJitHelperTable);
  Fold(AAbi.Layout.FuncInstStride);
  Fold(AAbi.Layout.FuncKind);
  Fold(AAbi.Layout.FuncCompiledEntry);
  Fold(AAbi.Layout.FuncCompiledDirectEntry);
  Fold(AAbi.Layout.FuncCompiledNativeScalarEntry);
  Fold(AAbi.Layout.FuncDirectMeta);
  Fold(AAbi.Layout.DirectMetaFn);
  Fold(AAbi.Layout.DirectMetaIrBase);
  Fold(AAbi.Layout.DirectMetaFuncAddrs);
  Fold(AAbi.Layout.DirectMetaEntryZeroRegs);
  Fold(AAbi.Layout.DirectMetaRefRegBits);
  Fold(AAbi.Layout.DirectMetaRegisterCount);
  Fold(AAbi.Layout.DirectMetaEntryZeroCount);
  Fold(AAbi.Layout.DirectMetaParam0Reg);
  Fold(AAbi.Layout.DirectMetaParam1Reg);
  Fold(AAbi.Layout.DirectMetaResult0Reg);
  Fold(AAbi.Layout.FuncCallCount);
  Fold(AAbi.Layout.MemInstStride);
  Fold(AAbi.Layout.MemBase);
  Fold(AAbi.Layout.MemByteSize);
  Fold(AAbi.Layout.StoreFHeap);
  Fold(AAbi.Layout.StoreTierContext);
  Fold(AAbi.Layout.InstEngineTypeIds);
  Fold(AAbi.Layout.HeapFFree0);
  Fold(AAbi.Layout.HeapMarkState);
  Fold(AAbi.Layout.HeapBytesLive);
  Fold(AAbi.Layout.HeapBytesAllocated);
  Fold(AAbi.Layout.HeapObjectCount);
  Fold(AAbi.Layout.BlockBase);
  Fold(AAbi.Layout.BlockAllocated);
  Fold(AAbi.ValueSlotSize);
  Fold(AAbi.Layout.CtxValues);
  Fold(AAbi.Layout.CtxValueTop);
  Fold(AAbi.Layout.CtxValueCap);
  Fold(AAbi.Layout.CtxActs);
  Fold(AAbi.Layout.CtxDepthCap);
  Fold(AAbi.Layout.CtxDepth);
  Fold(AAbi.Layout.CtxFuncsSlot);
  Fold(AAbi.Layout.CtxGcFrameSlot);
  Fold(AAbi.Layout.ActStride);
  Fold(AAbi.Layout.ActBase);
  Fold(AAbi.Layout.ActFn);
  Fold(AAbi.Layout.ActInstance);
  Fold(AAbi.Layout.ActFuncAddrs);
  Fold(AAbi.Layout.ActIP);
  Fold(AAbi.Layout.ActGcFrame);
  Fold(AAbi.Layout.ActRetKind);
  Fold(AAbi.Layout.ActRetDest);
  Fold(AAbi.Layout.ActRetCount);
  Fold(AAbi.Layout.ActRetBase);
  Fold(AAbi.Layout.ActEntryResults);
  Fold(AAbi.Layout.GcFramePrev);
  Fold(AAbi.Layout.GcFrameSlots);
  Fold(AAbi.Layout.GcFrameRefRegBits);
  Fold(AAbi.Layout.GcFrameRegisterCount);
  Fold(AAbi.Layout.GcFrameInstance);

  Fold(AAbi.IrInstrSize);
  Fold(AAbi.ValueSlotSize);
  Fold(AAbi.HelperCount);
  Fold(AAbi.AbiRevision);
  Result := H;
end;
{$pop}

function WasmTargetCanEmit(const ATarget: TWasmTarget): Boolean;
begin
  Result := False;
  if not WasmTargetSupported(ATarget) then
    Exit;
  {$IF DEFINED(UNIX) AND DEFINED(CPUAARCH64)}
  Result := ATarget.Arch = wtaAArch64;
  {$ELSEIF DEFINED(UNIX) AND DEFINED(CPUX86_64)}
  Result := ATarget.Arch = wtaX86_64;
  {$ENDIF}
end;

function WasmTargetCanExecute(const ATarget: TWasmTarget): Boolean;
begin
  {$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  Result := WasmTargetEqual(ATarget, WasmTargetHost);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

end.
