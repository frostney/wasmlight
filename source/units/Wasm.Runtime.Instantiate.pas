{ Wasm.Runtime.Instantiate — the constant-expression evaluator and the
  instantiation sequence.

  "Instantiation checks that the module is valid and the provided imports
  match the declared types, and may fail with an error otherwise.
  Instantiation can also result in an exception or trap when initializing
  a table or memory from an active segment or when executing the start
  function" (`exec-module`).

  THE ORDER IS THE SPEC'S, and it is spelled out in `aux-rundata`:

    "In practice, the initialization values can be determined beforehand
    by staging module allocation such that first, the module's own
    function instances are pre-allocated in the store, then the
    initializer expressions are evaluated in order, allocating globals on
    the way, then the rest of the module instance is allocated, and
    finally the new function instances' MODULE fields are set to that
    module instance."

  and

    "All failure conditions are checked before any observable mutation of
    the store takes place."

  So:

    0  re-intern the module's rec groups into the engine
    1  check the import COUNT per kind                     EWasmLinkError
    2  check each import's kind and type                   EWasmLinkError
    3  pre-allocate the module's own function instances
    4  evaluate global initialisers in order, allocating as it goes
    5  evaluate table initialisers
    6  evaluate element-segment item expressions
    7  allocate memories, tables, elem and data instances
    8  build the instance; back-patch step 3's Instance field
    9  apply ELEMENT segments, in module order              may trap
    10 apply DATA segments, in module order                 may trap
    11 record the pending start function

  Steps 1-2 precede every store mutation. Steps 9-10 CAN trap after
  mutation and the resulting partially-initialised store is observable —
  the spec permits that explicitly, so it is behaviour rather than a
  defect, and `assert_trap` on a `(module ...)` command is what asserts
  it. Step 0 mutates the ENGINE, not the store; engine growth is not an
  observable store mutation and the ordering is exactly what `aux-rundata`
  recommends ("implementations will likely allocate or canonicalize types
  beforehand … in a stage before instantiation and before imports are
  checked").

  ACTIVE SEGMENT OUT OF BOUNDS IS A TRAP, NOT A LINK ERROR. 3.0 executes
  active segments as bulk-copy instructions and `exec-module` states
  plainly that instantiation "can also result in an exception or trap when
  initializing a table or memory from an active segment". This is the
  point where earlier spec versions differed — MVP-era implementations
  reported it at link time — and under the pinned draft it traps, after
  earlier segments in the same module have already been written.

  IMPORTS ARE SUPPLIED PER KIND, not as one vector in import-section
  order. The spec hands instantiation a single `externaddr*` in that
  order; TWasmIrModule does not retain it (it keeps per-kind index spaces
  and per-kind import counts, which is all a tier needs), and Track D does
  not extend Track B's record to get it back. The information is the same:
  imports occupy the low indices of each kind's index space, so a per-kind
  vector names exactly the same externals. Resolving imports BY NAME is
  Track F's job — it has the decoded module, which does carry the names.

  Spec pin: wasm-mcp 0.2.16, spec/main
  d7b37e4170d8315f2f1283aed4e8076591a9a333 (ADR-0004).
  Anchors: exec-module / exec-instantiation, aux-rundata / aux-runelem,
  alloc-module, exec-type, aux-default, match-externtype, exec-binop
  (i32.add: can_trap:false), memory.init and table.init (the two segment
  trap messages), syntax-eleminst, syntax-datainst. }
unit Wasm.Runtime.Instantiate;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core,
  Wasm.Ir,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Memory,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values;

type
  { The externals an instantiation is given, per kind, in the order the
    module's index spaces expect. See the unit header for why this is not
    one vector. }
  TWasmImports = record
    Funcs: array of TWasmFuncAddr;
    Tables: array of TWasmTableAddr;
    Mems: array of TWasmMemAddr;
    Globals: array of TWasmGlobalAddr;
    Tags: array of TWasmTagAddr;
  end;

const
  { The evaluator's else branch. `v128.const` IS a constant instruction
    (valid-vconst) and is handled above; the rest of the $FD space is not
    constant and never reaches the evaluator. }
  MSG_UNSUPPORTED_CONST_OP = 'unsupported constant instruction';

{ Evaluate one constant expression against a (possibly partially built)
  module instance.

  "Evaluation of constant expressions does not affect the store"
  (`aux-rundata`) — with one exception the spec makes explicit: the
  aggregate allocations, which go to the GC heap rather than to any store
  category, and which make this function a SAFEPOINT REGION. Its frame
  therefore joins the collector's frame chain for the duration (contract
  GC-1), with the reference bits derived from the expression's RegTypes
  exactly as IrComputeRefRegBits derives them for a function. Without
  that, a struct.new whose result is still only in a frame slot would be
  freed by the collection a later struct.new in the same expression
  triggers.

  The opcode set is closed and small: it is exactly what
  Wasm.Validator.Const emits, and the else branch raises rather than
  producing zero. iroGlobalGet reads through AInstance.GlobalAddrs and
  does NOT re-check the index — the validator's GlobalLimit windows
  already guaranteed it names an import (for table initialisers and
  element offsets) or an earlier global.

  iroRefFunc returns the function instance's stable handle, which is why
  step 3 of the sequence must already have run: "this is possible because
  validation ensures that initialization expressions cannot actually call
  a function, only take their reference" (`aux-rundata`).

  Callable with NO execution tier present. That is what makes the whole of
  waves 3 and 4 testable before Track E exists. }
function EvalInitExpr(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance;
  const AExpr: TWasmIrInitExpr): TWasmValue;

{ The v128 twin: a constant expression whose result is a vector (a
  `v128.const`, or a `global.get` of an imported v128 global) yields 16
  bytes, which do not fit a TWasmValue. Reads the result register PAIR
  (simd-spec §1.7). }
function EvalInitExprV128(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance;
  const AExpr: TWasmIrInitExpr): TWasmV128;

{ Instantiate AIr into AStore.

  ABytes must be the buffer AIr was validated against and must outlive
  every use of the returned instance (ADR-0003; see Wasm.Runtime.Store's
  header for the full lifetime rule). AIr is BORROWED — one IR module may
  back many instances.

  The returned instance is owned by AStore and must not be freed by the
  caller. A module with a start function instantiates SUCCESSFULLY and
  records the start as pending; TWasmStore.RunPendingStart is what runs
  it, and with no tier registered that raises EWasmError.

  Raises EWasmLinkError when the imports do not satisfy the module,
  EWasmTrap when an active element or data segment is out of bounds, and
  EWasmError for a host-resource failure or an internal invariant
  violation. It never raises EWasmDecodeError or EWasmValidationError: a
  runtime unit raising either would mean it re-derived a rule the
  validator owns (ADR-0007). }
function InstantiateModule(const AStore: TWasmStore;
  const AIr: TWasmIrModule; const ABytes: PByte;
  const ABytesLength: NativeUInt;
  const AImports: TWasmImports): TWasmModuleInstance;

implementation

{ --- wrapping integer arithmetic ----------------------------------------- }

{$PUSH}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}
{ wasm integer arithmetic is modulo 2^N — i32.add and friends report
  can_trap:false (`instruction_get`), and there is no overflow condition
  for add/sub/mul to report. Shared.inc turns overflow checks ON outside
  PRODUCTION builds, where a legal wrap would raise EIntOverflow, so these
  four-line helpers are the one place they are off and every extended-
  constant operator goes through them. }

function WrapAdd32(const A, B: UInt32): UInt32;
begin
  Result := A + B;
end;

function WrapSub32(const A, B: UInt32): UInt32;
begin
  Result := A - B;
end;

function WrapMul32(const A, B: UInt32): UInt32;
begin
  Result := A * B;
end;

function WrapAdd64(const A, B: UInt64): UInt64;
begin
  Result := A + B;
end;

function WrapSub64(const A, B: UInt64): UInt64;
begin
  Result := A - B;
end;

function WrapMul64(const A, B: UInt64): UInt64;
begin
  Result := A * B;
end;
{$POP}

{ --- the evaluator ------------------------------------------------------- }

procedure CheckReg(const AReg, ACount: UInt32; const AWhat: string);
begin
  if AReg >= ACount then
    raise EWasmError.CreateFmt(
      'internal: constant expression names register %u of %u (%s)',
      [AReg, ACount, AWhat]);
end;

{ The engine id behind a MODULE type index. Every GC allocation names one,
  and the module-local id an instruction carries is meaningless to the
  heap: "any module-local type indices occurring inside them would not
  generally be meaningful" (`exec-type`). }
function EngineIdOf(const AInstance: TWasmModuleInstance;
  const ATypeIndex: UInt32): TWasmEngineTypeId;
begin
  if ATypeIndex >= UInt32(Length(AInstance.EngineTypeIds)) then
    raise EWasmError.CreateFmt(
      'internal: constant expression names type %u of %u',
      [ATypeIndex, UInt32(Length(AInstance.EngineTypeIds))]);
  Result := AInstance.EngineTypeIds[ATypeIndex];
end;

{ The shared evaluator. AResult points at the caller's TWasmValue (scalar)
  or TWasmV128 (AResultIsVec); the result register is read as 8 or 16 bytes
  accordingly. Splitting scalar/vector at the boundary keeps the frame
  scratch buffer and the collector frame chain in one place. }
procedure EvalInitExprCore(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance;
  const AExpr: TWasmIrInitExpr; const AResult: Pointer;
  const AResultIsVec: Boolean);
var
  Frame: PWasmValue;
  GcFrame: TWasmGcFrame;
  Index: Integer;
  Item: Integer;
  Instr: TWasmIrInstr;
  Count: UInt32;
  FuncIndex: UInt32;
  GlobalIndex: UInt32;
  Addr: UInt32;
  Items: UInt32;
  Reg: UInt32;
  Obj: TWasmRef;

  function Slot(const AReg: UInt32): PWasmValue;
  begin
    Result := PWasmValue(PByte(Frame) + NativeUInt(AReg) *
      SizeOf(TWasmValue));
  end;

begin
  if Length(AExpr.Code) = 0 then
    raise EWasmError.Create(
      'internal: evaluating an absent constant expression');

  Count := AExpr.RegisterCount;
  { The frame comes from the store's scratch buffer, not from a per-call
    dynamic array (TRAP-1 rule 4): a frame that a longjmp skips must leak
    nothing. Constant expressions do not nest, so one buffer suffices. }
  Frame := AStore.ScratchFrame(Count);

  { On the collector's frame chain for the whole evaluation. ScratchFrame
    has already zeroed every slot, which is contract GC-1's first
    obligation and the reason an unwritten reference register reads as
    null rather than as whatever the last expression left. }
  GcFrame.Prev := nil;
  GcFrame.Slots := Frame;
  GcFrame.RefRegBits := AStore.ScratchRefBits(AExpr.RegTypes, Count);
  GcFrame.RegisterCount := Count;
  GcFrame.Instance := Pointer(AInstance);
  AStore.Heap.PushFrame(@GcFrame);
  try

  for Index := 0 to High(AExpr.Code) do
  begin
    Instr := AExpr.Code[Index];
    case Instr.Op of
      iroI32Const:
        begin
          CheckReg(Instr.Dest, Count, 'i32.const');
          Slot(Instr.Dest)^.Bits := UInt64(UInt32(Int32(Instr.Imm)));
        end;
      iroI64Const:
        begin
          CheckReg(Instr.Dest, Count, 'i64.const');
          Slot(Instr.Dest)^.Bits := UInt64(Instr.Imm);
        end;
      iroF32Const:
        begin
          { Floats travel as BIT PATTERNS: a NaN payload is observable and
            a round trip through an FPC float type is not required to
            preserve it. The 32 bits are zero-extended into the slot. }
          CheckReg(Instr.Dest, Count, 'f32.const');
          Slot(Instr.Dest)^.Bits := UInt64(UInt32(Instr.Imm));
        end;
      iroF64Const:
        begin
          CheckReg(Instr.Dest, Count, 'f64.const');
          Slot(Instr.Dest)^.Bits := UInt64(Instr.Imm);
        end;

      iroV128Const:
        begin
          { The 16 immediate bytes travel as an aux block (simd-spec §2.2),
            read verbatim into the result register PAIR. v128.const IS a
            constant instruction (valid-vconst). }
          CheckReg(Instr.Dest, Count, 'v128.const');
          CheckReg(Instr.Dest + 1, Count, 'v128.const high half');
          IrAuxReadV128(AExpr.AuxU32, UInt32(Instr.Imm),
            PWasmV128(Slot(Instr.Dest))^);
        end;

      iroI32Add, iroI32Sub, iroI32Mul:
        begin
          CheckReg(Instr.Dest, Count, 'i32 binop');
          CheckReg(Instr.A, Count, 'i32 binop');
          CheckReg(Instr.B, Count, 'i32 binop');
          case Instr.Op of
            iroI32Add:
              Slot(Instr.Dest)^.Bits := UInt64(WrapAdd32(Slot(Instr.A)^.U32,
                Slot(Instr.B)^.U32));
            iroI32Sub:
              Slot(Instr.Dest)^.Bits := UInt64(WrapSub32(Slot(Instr.A)^.U32,
                Slot(Instr.B)^.U32));
          else
            Slot(Instr.Dest)^.Bits := UInt64(WrapMul32(Slot(Instr.A)^.U32,
              Slot(Instr.B)^.U32));
          end;
        end;

      iroI64Add, iroI64Sub, iroI64Mul:
        begin
          CheckReg(Instr.Dest, Count, 'i64 binop');
          CheckReg(Instr.A, Count, 'i64 binop');
          CheckReg(Instr.B, Count, 'i64 binop');
          case Instr.Op of
            iroI64Add:
              Slot(Instr.Dest)^.Bits := WrapAdd64(Slot(Instr.A)^.U64,
                Slot(Instr.B)^.U64);
            iroI64Sub:
              Slot(Instr.Dest)^.Bits := WrapSub64(Slot(Instr.A)^.U64,
                Slot(Instr.B)^.U64);
          else
            Slot(Instr.Dest)^.Bits := WrapMul64(Slot(Instr.A)^.U64,
              Slot(Instr.B)^.U64);
          end;
        end;

      iroRefNull:
        begin
          { ref.null carries no heap type in the IR: a null value has no
            runtime type and the static one is in RegTypes[Dest]. }
          CheckReg(Instr.Dest, Count, 'ref.null');
          Slot(Instr.Dest)^.Bits := UInt64(WASM_REF_NULL);
        end;

      iroRefFunc:
        begin
          CheckReg(Instr.Dest, Count, 'ref.func');
          FuncIndex := UInt32(Instr.Imm);
          if FuncIndex >= UInt32(Length(AInstance.FuncAddrs)) then
            raise EWasmError.CreateFmt(
              'internal: ref.func names function %u of %u',
              [FuncIndex, UInt32(Length(AInstance.FuncAddrs))]);
          Addr := AInstance.FuncAddrs[FuncIndex];
          Slot(Instr.Dest)^.Bits := UInt64(AStore.Funcs[Addr].RefObject);
        end;

      iroRefI31:
        begin
          { Unboxed, so no allocation and no dependence on the heap: 31
            payload bits plus one tag bit is exactly 32. The IR flags this
            op as a safepoint, which under unboxing is conservative rather
            than wrong. }
          CheckReg(Instr.Dest, Count, 'ref.i31');
          CheckReg(Instr.A, Count, 'ref.i31');
          Slot(Instr.Dest)^.Bits := UInt64(MakeI31Ref(Slot(Instr.A)^.I32));
        end;

      iroGlobalGet:
        begin
          CheckReg(Instr.Dest, Count, 'global.get');
          GlobalIndex := UInt32(Instr.Imm);
          if GlobalIndex >= UInt32(Length(AInstance.GlobalAddrs)) then
            raise EWasmError.CreateFmt(
              'internal: global.get names global %u of %u',
              [GlobalIndex, UInt32(Length(AInstance.GlobalAddrs))]);
          Addr := AInstance.GlobalAddrs[GlobalIndex];
          if AStore.Globals[Addr].GlobalType.ValueType.Kind = wvkVec then
          begin
            { A v128 global's cell is the 16-byte Vec side (simd-spec §1.7);
              copy the pair into the result register pair. }
            CheckReg(Instr.Dest + 1, Count, 'global.get high half');
            PWasmV128(Slot(Instr.Dest))^ := AStore.Globals[Addr].Vec;
          end
          else
            Slot(Instr.Dest)^ := AStore.Globals[Addr].Value;
        end;

      iroExternConvertAny:
        begin
          { Route through the same GC wrapper pair the interpreter uses so a
            later ref.test/ref.cast classifies the value correctly (M7). Every
            const-expr convert in the corpus is on null (where the wrapper is a
            no-op), but keeping the semantics identical to the execution tiers
            avoids a latent divergence. }
          CheckReg(Instr.Dest, Count, 'convert');
          CheckReg(Instr.A, Count, 'convert');
          ValueSetRef(Slot(Instr.Dest)^,
            AStore.Heap.ExternalizeAny(Slot(Instr.A)^.Ref));
        end;
      iroAnyConvertExtern:
        begin
          CheckReg(Instr.Dest, Count, 'convert');
          CheckReg(Instr.A, Count, 'convert');
          ValueSetRef(Slot(Instr.Dest)^,
            AStore.Heap.InternalizeExtern(Slot(Instr.A)^.Ref));
        end;

      iroStructNew:
        begin
          { The operands are the field storage types UNPACKED, in
            declaration order, in the aux block Wasm.Validator.Const
            emitted. }
          CheckReg(Instr.Dest, Count, 'struct.new');
          Obj := AStore.Heap.AllocStruct(
            EngineIdOf(AInstance, UInt32(Instr.Imm)));
          { PUBLISHED INTO THE FRAME SLOT FIRST. The slot is a root and a
            Pascal local is not, so anything that can allocate between
            here and the last field write would otherwise be free to
            collect the object being built. }
          Slot(Instr.Dest)^.Bits := UInt64(Obj);
          Items := IrAuxBlockCount(AExpr.AuxU32, Instr.A);
          for Item := 0 to Integer(Items) - 1 do
          begin
            Reg := IrAuxBlockItem(AExpr.AuxU32, Instr.A, UInt32(Item));
            CheckReg(Reg, Count, 'struct.new field');
            AStore.Heap.StructSet(Obj, UInt32(Item), Slot(Reg)^);
          end;
        end;

      iroStructNewDefault:
        begin
          CheckReg(Instr.Dest, Count, 'struct.new_default');
          Obj := AStore.Heap.AllocStruct(
            EngineIdOf(AInstance, UInt32(Instr.Imm)));
          Slot(Instr.Dest)^.Bits := UInt64(Obj);
          { aux-default per field, and the check that each one HAS a
            default — which the validator already enforced, so a failure
            here is an internal invariant violation. }
          AStore.Heap.StructSetDefaults(Obj);
        end;

      iroArrayNew:
        begin
          { A is the element value, B the length: `valid-array.new` is
            [t i32] -> [(ref x)], with the length on top of the stack. }
          CheckReg(Instr.Dest, Count, 'array.new');
          CheckReg(Instr.A, Count, 'array.new');
          CheckReg(Instr.B, Count, 'array.new');
          Obj := AStore.Heap.AllocArray(
            EngineIdOf(AInstance, UInt32(Instr.Imm)), Slot(Instr.B)^.U32);
          Slot(Instr.Dest)^.Bits := UInt64(Obj);
          AStore.Heap.ArrayFill(Obj, Slot(Instr.A)^);
        end;

      iroArrayNewDefault:
        begin
          CheckReg(Instr.Dest, Count, 'array.new_default');
          CheckReg(Instr.A, Count, 'array.new_default');
          Obj := AStore.Heap.AllocArray(
            EngineIdOf(AInstance, UInt32(Instr.Imm)), Slot(Instr.A)^.U32);
          Slot(Instr.Dest)^.Bits := UInt64(Obj);
          AStore.Heap.ArraySetDefaults(Obj);
        end;

      iroArrayNewFixed:
        begin
          { The elements are an operand list rather than a count plus one
            value, so the length is the aux block's. }
          CheckReg(Instr.Dest, Count, 'array.new_fixed');
          Items := IrAuxBlockCount(AExpr.AuxU32, Instr.A);
          Obj := AStore.Heap.AllocArray(
            EngineIdOf(AInstance, UInt32(Instr.Imm)), Items);
          Slot(Instr.Dest)^.Bits := UInt64(Obj);
          for Item := 0 to Integer(Items) - 1 do
          begin
            Reg := IrAuxBlockItem(AExpr.AuxU32, Instr.A, UInt32(Item));
            CheckReg(Reg, Count, 'array.new_fixed element');
            AStore.Heap.ArraySet(Obj, UInt32(Item), Slot(Reg)^);
          end;
        end;
    else
      raise EWasmError.CreateFmt('%s: %s',
        [MSG_UNSUPPORTED_CONST_OP, IrOpMnemonic(Instr.Op)]);
    end;
  end;

  CheckReg(AExpr.ResultReg, Count, 'result');
  if AResultIsVec then
  begin
    CheckReg(AExpr.ResultReg + 1, Count, 'result high half');
    Move(Slot(AExpr.ResultReg)^, AResult^, 16);
  end
  else
    PWasmValue(AResult)^ := Slot(AExpr.ResultReg)^;

  finally
    AStore.Heap.PopFrame;
  end;
end;

function EvalInitExpr(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance;
  const AExpr: TWasmIrInitExpr): TWasmValue;
begin
  EvalInitExprCore(AStore, AInstance, AExpr, @Result, False);
end;

function EvalInitExprV128(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance;
  const AExpr: TWasmIrInitExpr): TWasmV128;
begin
  EvalInitExprCore(AStore, AInstance, AExpr, @Result, True);
end;

{ --- link errors --------------------------------------------------------- }

function KindName(const AKind: TWasmExternKind): string;
begin
  case AKind of
    wxkFunc: Result := 'function';
    wxkTable: Result := 'table';
    wxkMem: Result := 'memory';
    wxkGlobal: Result := 'global';
  else
    Result := 'tag';
  end;
end;

procedure RaiseCountMismatch(const AKind: TWasmExternKind;
  const ASupplied, ADeclared: UInt32);
begin
  { CONFIRMED prefix, settled against the corpus: a supplied-count
    shortfall means some declared import has no external at all, which the
    testsuite reports as `unknown import` (imports.wast:138, linking.wast:387
    exercise the by-name equivalent). The constant lives in
    Wasm.Runtime.Traps. }
  raise EWasmLinkError.CreateFmt('%s: the module declares %u %s imports '
    + 'but %u were supplied',
    [string(MSG_LINK_UNKNOWN_IMPORT), ADeclared, KindName(AKind),
     ASupplied]);
end;

procedure RaiseIncompatible(const AKind: TWasmExternKind;
  const AIndex: UInt32);
begin
  raise EWasmLinkError.CreateFmt('%s: %s import %u',
    [string(MSG_LINK_INCOMPATIBLE_IMPORT), KindName(AKind), AIndex]);
end;

procedure CheckAddr(const AAddr, ALimit: UInt32;
  const AKind: TWasmExternKind; const AIndex: UInt32);
begin
  { WASM_NO_ADDR is the resolver's "no export of that name" sentinel: an
    import Track F could not satisfy by name is handed to instantiation as
    this address. That is a LINK failure, not host misuse, and the corpus
    spells it `unknown import` (linking.wast:387, imports.wast:138) — so it
    must be an EWasmLinkError carrying MSG_LINK_UNKNOWN_IMPORT, not the bare
    EWasmError the out-of-range branch below raises. }
  if AAddr = WASM_NO_ADDR then
    raise EWasmLinkError.CreateFmt('%s: %s import %u',
      [string(MSG_LINK_UNKNOWN_IMPORT), KindName(AKind), AIndex]);
  { Any OTHER address outside the store is host misuse, not a module
    defect: it is EWasmError rather than EWasmLinkError, because nothing
    about the module failed to link. }
  if AAddr >= ALimit then
    raise EWasmError.CreateFmt(
      '%s import %u names address %u, but the store holds %u',
      [KindName(AKind), AIndex, AAddr, ALimit]);
end;

{ --- offsets ------------------------------------------------------------- }

function OffsetOf(const AValue: TWasmValue;
  const AAddrType: TWasmAddrType): UInt64;
begin
  { The offset expression's type follows the memory's or table's address
    type, which the validator already enforced. An i32 offset is
    ZERO-extended: a negative i32 is a large unsigned index and must trap
    rather than wrap into range. }
  if AAddrType = watI32 then
    Result := UInt64(AValue.U32)
  else
    Result := AValue.U64;
end;

{ --- instantiation ------------------------------------------------------- }

type
  { Element-segment contents, evaluated in step 6 and applied in step 9. }
  TSegmentRefs = array of TWasmRef;
  TSegmentRefsList = array of TSegmentRefs;

procedure CheckImportCounts(const AIr: TWasmIrModule;
  const AImports: TWasmImports);
begin
  if UInt32(Length(AImports.Funcs)) <> AIr.FuncImportCount then
    RaiseCountMismatch(wxkFunc, UInt32(Length(AImports.Funcs)),
      AIr.FuncImportCount);
  if UInt32(Length(AImports.Tables)) <> AIr.TableImportCount then
    RaiseCountMismatch(wxkTable, UInt32(Length(AImports.Tables)),
      AIr.TableImportCount);
  if UInt32(Length(AImports.Mems)) <> AIr.MemoryImportCount then
    RaiseCountMismatch(wxkMem, UInt32(Length(AImports.Mems)),
      AIr.MemoryImportCount);
  if UInt32(Length(AImports.Globals)) <> AIr.GlobalImportCount then
    RaiseCountMismatch(wxkGlobal, UInt32(Length(AImports.Globals)),
      AIr.GlobalImportCount);
  if UInt32(Length(AImports.Tags)) <> AIr.TagImportCount then
    RaiseCountMismatch(wxkTag, UInt32(Length(AImports.Tags)),
      AIr.TagImportCount);
end;

{ Step 2. Nothing here mutates the store, which is what makes
  `aux-rundata`'s "all failure conditions are checked before any
  observable mutation" hold. }
procedure CheckImportTypes(const AStore: TWasmStore;
  const AIr: TWasmIrModule; const AImports: TWasmImports;
  const ACanonIds, ATypeIds: TWasmEngineTypeIds);
var
  Index: Integer;
  Addr: UInt32;
begin
  for Index := 0 to High(AImports.Funcs) do
  begin
    Addr := AImports.Funcs[Index];
    CheckAddr(Addr, UInt32(Length(AStore.Funcs)), wxkFunc, UInt32(Index));
    if not MatchFuncImport(AStore.Engine, AStore.Funcs[Addr],
      ACanonIds[AIr.FuncCanonTypes[Index]]) then
      RaiseIncompatible(wxkFunc, UInt32(Index));
  end;

  for Index := 0 to High(AImports.Tables) do
  begin
    Addr := AImports.Tables[Index];
    CheckAddr(Addr, UInt32(Length(AStore.Tables)), wxkTable, UInt32(Index));
    if not MatchTableImport(AStore.Engine, AStore.Tables[Addr],
      EngineTableType(AIr.Tables[Index], ATypeIds)) then
      RaiseIncompatible(wxkTable, UInt32(Index));
  end;

  for Index := 0 to High(AImports.Mems) do
  begin
    Addr := AImports.Mems[Index];
    CheckAddr(Addr, UInt32(AStore.MemoryCount), wxkMem, UInt32(Index));
    if not AStore.MemMatchesImport(Addr, AIr.Memories[Index]) then
      RaiseIncompatible(wxkMem, UInt32(Index));
  end;

  for Index := 0 to High(AImports.Globals) do
  begin
    Addr := AImports.Globals[Index];
    CheckAddr(Addr, UInt32(Length(AStore.Globals)), wxkGlobal,
      UInt32(Index));
    if not MatchGlobalImport(AStore.Engine, AStore.Globals[Addr],
      EngineGlobalType(AIr.Globals[Index], ATypeIds)) then
      RaiseIncompatible(wxkGlobal, UInt32(Index));
  end;

  for Index := 0 to High(AImports.Tags) do
  begin
    Addr := AImports.Tags[Index];
    CheckAddr(Addr, UInt32(Length(AStore.Tags)), wxkTag, UInt32(Index));
    if not MatchTagImport(AStore.Engine, AStore.Tags[Addr],
      ACanonIds[AIr.Tags[Index]]) then
      RaiseIncompatible(wxkTag, UInt32(Index));
  end;
end;

{ Step 5. A table with no initialiser takes aux-default's value, which is
  null for a nullable element type and does not exist for any other. Track
  B already rejected a non-defaultable table without an initialiser, so an
  empty entry on a non-nullable table is an INTERNAL invariant violation
  rather than a link error — the validator should have caught it. }
function TableInitValue(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance; const AIr: TWasmIrModule;
  const ADefinedIndex: Integer): TWasmRef;
var
  ModuleIndex: UInt32;
begin
  ModuleIndex := AIr.TableImportCount + UInt32(ADefinedIndex);
  if Length(AIr.TableInits[ADefinedIndex].Code) > 0 then
    Exit(EvalInitExpr(AStore, AInstance,
      AIr.TableInits[ADefinedIndex]).Ref);

  if not AIr.Tables[ModuleIndex].RefType.Nullable then
    raise EWasmError.CreateFmt(
      'internal: table %u has a non-nullable element type and no '
      + 'initialiser', [ModuleIndex]);
  Result := WASM_REF_NULL;
end;

procedure ApplyElemSegments(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance; const AIr: TWasmIrModule);
var
  Segment: Integer;
  Offset: UInt64;
  ElemAddr: TWasmElemAddr;
  TableAddr: TWasmTableAddr;
begin
  for Segment := 0 to High(AIr.Elems) do
  begin
    ElemAddr := AInstance.ElemAddrs[Segment];
    { A PASSIVE segment is kept as it is, until table.init reads it or
      elem.drop drops it, so it has no branch here. }
    if AIr.Elems[Segment].Mode = iremActive then
        begin
          TableAddr :=
            AInstance.TableAddrs[AIr.Elems[Segment].TableIndex];
          Offset := OffsetOf(EvalInitExpr(AStore, AInstance,
            AIr.Elems[Segment].Offset),
            AStore.Tables[TableAddr].TableType.Limits.AddrType);
          { table.init semantics through the barriered chokepoint: the
            range check precedes any write, so a trapping segment writes
            nothing and earlier segments stay applied, and every stored
            reference goes through the GC write barrier (A6). }
          AStore.TableInitFromElem(TableAddr, Offset,
            AStore.Elems[ElemAddr].Refs);
          { An applied active segment is dropped by the instantiation
            sequence. }
          AStore.Elems[ElemAddr].Refs := nil;
          AStore.Elems[ElemAddr].Dropped := True;
        end
    else if AIr.Elems[Segment].Mode = iremDeclarative then
    begin
      { A declarative segment exists only so ref.func may name its
        functions during validation; it holds nothing at run time. }
      AStore.Elems[ElemAddr].Refs := nil;
      AStore.Elems[ElemAddr].Dropped := True;
    end;
  end;
end;

procedure ApplyDataSegments(const AStore: TWasmStore;
  const AInstance: TWasmModuleInstance; const AIr: TWasmIrModule);
var
  Segment: Integer;
  Offset: UInt64;
  DataAddr: TWasmDataAddr;
  MemAddr: TWasmMemAddr;
  Target: PByte;
begin
  for Segment := 0 to High(AIr.Datas) do
  begin
    if AIr.Datas[Segment].Mode <> irdmActive then
      Continue;

    DataAddr := AInstance.DataAddrs[Segment];
    MemAddr := AInstance.MemAddrs[AIr.Datas[Segment].MemIndex];
    Offset := OffsetOf(EvalInitExpr(AStore, AInstance,
      AIr.Datas[Segment].Offset), AStore.MemoryAddrType(MemAddr));

    { THE chokepoint. MemRangeAt traps `out of bounds memory access` unless
      the whole range is in bounds, under every strategy — a length is a
      runtime value that no guard region can bound (ADR-0005). }
    Target := AStore.MemRangeAt(MemAddr, Offset,
      UInt64(AStore.Datas[DataAddr].Size));
    if AStore.Datas[DataAddr].Size > 0 then
      Move(AStore.Datas[DataAddr].Data^, Target^,
        AStore.Datas[DataAddr].Size);

    { Dropped by the sequence. Zeroing the span is what lets
      BorrowsBuffer go false once every segment is dropped. }
    AStore.Datas[DataAddr].Data := nil;
    AStore.Datas[DataAddr].Size := 0;
    AStore.Datas[DataAddr].Dropped := True;
  end;
end;

{ L11: an addr array is published on the instance (step 3) BEFORE its later
  entries are filled, and a SetLength zero-fills — so a mid-instantiation
  EWasmError (a failed allocation, a bad const expr) would leave unset
  entries reading 0, which aliases entity 0 of that space. WASM_NO_ADDR is
  the "absent" marker; filling with it means a partial instance names no
  entity rather than the wrong one. }
procedure FillNoAddr(var AAddrs: TWasmAddrs);
var
  I: Integer;
begin
  for I := 0 to High(AAddrs) do
    AAddrs[I] := WASM_NO_ADDR;
end;

function InstantiateModule(const AStore: TWasmStore;
  const AIr: TWasmIrModule; const ABytes: PByte;
  const ABytesLength: NativeUInt;
  const AImports: TWasmImports): TWasmModuleInstance;
var
  CanonIds: TWasmEngineTypeIds;
  TypeIds: TWasmEngineTypeIds;
  Instance: TWasmModuleInstance;
  Index: Integer;
  Item: Integer;
  ModuleIndex: UInt32;
  TypeId: TWasmEngineTypeId;
  Addr: UInt32;
  DefinedFuncs: Integer;
  TableInit: TWasmRef;
  ElemRefs: TSegmentRefsList;
  RootHandles: array of TWasmRootHandle;
  RootHandleCount: Integer;
  Span: TWasmIrSpan;
begin
  if AStore = nil then
    raise EWasmError.Create('instantiation needs a store');
  if AIr = nil then
    raise EWasmError.Create('instantiation needs a validated module');
  AStore.CheckThread;

  { ADR-0007's artifact-rejection rule: an IR whose format stamp is not
    this build's is rejected rather than read. }
  if AIr.FormatVersion <> IR_FORMAT_VERSION then
    raise EWasmError.CreateFmt(
      'IR format version %u, but this build reads %u',
      [AIr.FormatVersion, UInt32(IR_FORMAT_VERSION)]);

  { --- 0 --- }
  AStore.Engine.InternModule(AIr, CanonIds, TypeIds);

  { --- 1 and 2: before any store mutation --- }
  CheckImportCounts(AIr, AImports);
  CheckImportTypes(AStore, AIr, AImports, CanonIds, TypeIds);

  { --- 3: the module's own function instances --- }
  Instance := TWasmModuleInstance.Create;
  Instance.Ir := AIr;
  Instance.Bytes := ABytes;
  Instance.BytesLength := ABytesLength;
  Instance.EngineTypeIds := TypeIds;
  Instance.EngineCanonIds := CanonIds;
  { The store owns the instance from here on, so a trap in a later step
    leaves nothing to leak. }
  AStore.AddInstance(Instance);
  Result := Instance;

  DefinedFuncs := Length(AIr.Functions);
  SetLength(Instance.FuncAddrs,
    Integer(AIr.FuncImportCount) + DefinedFuncs);
  FillNoAddr(Instance.FuncAddrs);
  SetLength(Instance.FuncRefObjects, DefinedFuncs);
  for Index := 0 to Integer(AIr.FuncImportCount) - 1 do
    Instance.FuncAddrs[Index] := AImports.Funcs[Index];
  for Index := 0 to DefinedFuncs - 1 do
  begin
    ModuleIndex := AIr.FuncImportCount + UInt32(Index);
    TypeId := CanonIds[AIr.FuncCanonTypes[ModuleIndex]];
    Addr := AStore.AddWasmFunc(TypeId, UInt32(Index));
    { ref.func must return the SAME pointer every time; AddWasmFunc
      created the handle once and it lives as long as the instance. }
    Instance.FuncAddrs[ModuleIndex] := Addr;
    Instance.FuncRefObjects[Index] := AStore.Funcs[Addr].RefObject;
  end;

  { --- 4: globals, in order, allocating as it goes ---
    GlobalAddrs grows one entry at a time so that a global's initialiser
    can only see the imports and the globals before it — which is exactly
    the window the validator checked it against. }
  SetLength(Instance.GlobalAddrs, Integer(AIr.GlobalImportCount));
  for Index := 0 to Integer(AIr.GlobalImportCount) - 1 do
    Instance.GlobalAddrs[Index] := AImports.Globals[Index];
  for Index := 0 to High(AIr.GlobalInits) do
  begin
    ModuleIndex := AIr.GlobalImportCount + UInt32(Index);
    if AIr.Globals[ModuleIndex].ValueType.Kind = wvkVec then
      { A v128 global stores its 16-byte initial value in the Vec cell
        (simd-spec §1.7). }
      Addr := AStore.AddGlobalVec(
        EngineGlobalType(AIr.Globals[ModuleIndex], TypeIds),
        EvalInitExprV128(AStore, Instance, AIr.GlobalInits[Index]))
    else
      Addr := AStore.AddGlobal(
        EngineGlobalType(AIr.Globals[ModuleIndex], TypeIds),
        EvalInitExpr(AStore, Instance, AIr.GlobalInits[Index]));
    SetLength(Instance.GlobalAddrs, Length(Instance.GlobalAddrs) + 1);
    Instance.GlobalAddrs[High(Instance.GlobalAddrs)] := Addr;
  end;

  { --- 5 and 6: initialisers evaluated before anything is allocated ---
    THE EVALUATED REFERENCES ARE HOST ROOTS UNTIL THE ELEM INSTANCES EXIST.
    An element item may be `struct.new` (its type only has to be a
    subtype of the segment's element type), and a reference sitting in a
    local Pascal array is invisible to the collector — so item k+1's
    allocation would be free to reclaim item k's object. The references are
    held as host roots until they are in the store, where StoreMarkRoots
    sees them.

    M4: this uses an EXPLICIT register/release PAIR per handle rather than
    RootScopeEnter/Leave. A scope leave truncates the root stack to a mark,
    but RootRegister prefers the free list, so a registration inside the
    scope can be handed a slot BELOW the mark — which the truncation then
    never reclaims, a permanent root (and object) leak across repeated
    instantiation. Releasing exactly the handles we took (in reverse, so a
    contiguous run pops cleanly and a reused free slot returns to the free
    list) restores the root arrays to their pre-instantiation state no
    matter how RootRegister chose the slots, and needs no change to Gc. }
  RootHandles := nil;
  RootHandleCount := 0;
  SetLength(ElemRefs, Length(AIr.Elems));
  try
    for Index := 0 to High(AIr.Elems) do
    begin
      SetLength(ElemRefs[Index], Length(AIr.Elems[Index].Items));
      for Item := 0 to High(AIr.Elems[Index].Items) do
      begin
        ElemRefs[Index][Item] :=
          EvalInitExpr(AStore, Instance, AIr.Elems[Index].Items[Item]).Ref;
        if RootHandleCount >= Length(RootHandles) then
          SetLength(RootHandles, (RootHandleCount + 1) * 2);
        RootHandles[RootHandleCount] :=
          RootRegister(AStore, ElemRefs[Index][Item]);
        Inc(RootHandleCount);
      end;
    end;

    { The elem instances are built HERE rather than with the rest of step
      7, so the handover from host roots to store roots has no gap: a
      table initialiser evaluated below can allocate, and by then these
      references are reachable through StoreMarkRoots. }
    SetLength(Instance.ElemAddrs, Length(AIr.Elems));
    FillNoAddr(Instance.ElemAddrs);
    for Index := 0 to High(AIr.Elems) do
    begin
      Addr := AStore.AddElem(
        EngineRefType(AIr.Elems[Index].RefType, TypeIds));
      AStore.Elems[Addr].Refs := ElemRefs[Index];
      Instance.ElemAddrs[Index] := Addr;
    end;
  finally
    for Index := RootHandleCount - 1 downto 0 do
      RootRelease(AStore, RootHandles[Index]);
  end;

  { --- 7: allocate the rest ---
    Each addr array is NO_ADDR-filled right after SetLength (L11): a
    failure mid-loop here — AddTable / AddMemory can raise EWasmError on a
    host-resource failure, and a table initialiser can too — leaves the
    already-published instance with a partial array, and an unset entry
    must name no entity rather than aliasing entity 0. }
  SetLength(Instance.TableAddrs,
    Integer(AIr.TableImportCount) + Length(AIr.TableInits));
  FillNoAddr(Instance.TableAddrs);
  for Index := 0 to Integer(AIr.TableImportCount) - 1 do
    Instance.TableAddrs[Index] := AImports.Tables[Index];
  for Index := 0 to High(AIr.TableInits) do
  begin
    ModuleIndex := AIr.TableImportCount + UInt32(Index);
    TableInit := TableInitValue(AStore, Instance, AIr, Index);
    Instance.TableAddrs[ModuleIndex] := AStore.AddTable(
      EngineTableType(AIr.Tables[ModuleIndex], TypeIds), TableInit);
  end;

  SetLength(Instance.MemAddrs, Length(AIr.Memories));
  FillNoAddr(Instance.MemAddrs);
  for Index := 0 to Integer(AIr.MemoryImportCount) - 1 do
    Instance.MemAddrs[Index] := AImports.Mems[Index];
  for Index := Integer(AIr.MemoryImportCount) to High(AIr.Memories) do
    Instance.MemAddrs[Index] := AStore.AddMemory(AIr.Memories[Index]);

  SetLength(Instance.TagAddrs, Length(AIr.Tags));
  FillNoAddr(Instance.TagAddrs);
  for Index := 0 to Integer(AIr.TagImportCount) - 1 do
    Instance.TagAddrs[Index] := AImports.Tags[Index];
  for Index := Integer(AIr.TagImportCount) to High(AIr.Tags) do
    Instance.TagAddrs[Index] := AStore.AddTag(CanonIds[AIr.Tags[Index]]);

  SetLength(Instance.DataAddrs, Length(AIr.Datas));
  FillNoAddr(Instance.DataAddrs);
  for Index := 0 to High(AIr.Datas) do
  begin
    Span := AIr.Datas[Index].Bytes;
    { L13: SUBTRACTING form. `Span.Offset + Span.Size` is a NativeUInt sum
      that wraps on a 32-bit host, and Shared.inc turns overflow checks on
      outside PRODUCTION builds — so the naive sum raises EIntOverflow,
      which is outside the wasm error hierarchy. Compare without adding, and
      widen to UInt64 in the message so it too cannot overflow. }
    if (Span.Size > 0) and
      ((ABytes = nil) or (Span.Offset > ABytesLength) or
       (Span.Size > ABytesLength - Span.Offset)) then
      raise EWasmError.CreateFmt(
        'internal: data segment %d spans [%u, %u) outside a %u-byte '
        + 'buffer', [Index, UInt64(Span.Offset),
        UInt64(Span.Offset) + UInt64(Span.Size), UInt64(ABytesLength)]);
    if Span.Size = 0 then
      Instance.DataAddrs[Index] := AStore.AddData(nil, 0)
    else
      Instance.DataAddrs[Index] :=
        AStore.AddData(PByte(NativeUInt(ABytes) + Span.Offset), Span.Size);
  end;

  { --- 8: back-patch the MODULE field and publish the exports --- }
  for Index := 0 to DefinedFuncs - 1 do
  begin
    Addr := Instance.FuncAddrs[AIr.FuncImportCount + UInt32(Index)];
    AStore.Funcs[Addr].Instance := Instance;
    AStore.Funcs[Addr].DirectMeta.Fn := @AIr.Functions[Index];
    if Length(AIr.Functions[Index].Code) > 0 then
      AStore.Funcs[Addr].DirectMeta.IrBase := @AIr.Functions[Index].Code[0];
    if Length(Instance.FuncAddrs) > 0 then
      AStore.Funcs[Addr].DirectMeta.FuncAddrs := @Instance.FuncAddrs[0];
    if Length(AIr.Functions[Index].EntryZeroRegs) > 0 then
      AStore.Funcs[Addr].DirectMeta.EntryZeroRegs :=
        @AIr.Functions[Index].EntryZeroRegs[0];
    if AIr.Functions[Index].RegisterCount > 0 then
      AStore.Funcs[Addr].DirectMeta.RefRegBits :=
        @AIr.Functions[Index].RefRegBits[0];
    AStore.Funcs[Addr].DirectMeta.RegisterCount :=
      AIr.Functions[Index].RegisterCount;
    AStore.Funcs[Addr].DirectMeta.EntryZeroCount :=
      UInt32(Length(AIr.Functions[Index].EntryZeroRegs));
    if Length(AIr.Functions[Index].LocalRegs) > 0 then
      AStore.Funcs[Addr].DirectMeta.Param0Reg :=
        AIr.Functions[Index].LocalRegs[0];
    if Length(AIr.Functions[Index].LocalRegs) > 1 then
      AStore.Funcs[Addr].DirectMeta.Param1Reg :=
        AIr.Functions[Index].LocalRegs[1]
    else if (Length(AIr.Functions[Index].LocalRegs) = 1) and
      (AIr.Functions[Index].RegTypes[
        AIr.Functions[Index].LocalRegs[0]].Kind = wvkVec) then
      AStore.Funcs[Addr].DirectMeta.Param1Reg :=
        AIr.Functions[Index].LocalRegs[0] + 1;
    if Length(AIr.Functions[Index].ResultRegs) > 0 then
      AStore.Funcs[Addr].DirectMeta.Result0Reg :=
        AIr.Functions[Index].ResultRegs[0];
  end;

  SetLength(Instance.ExportNames, Length(AIr.ExportList));
  SetLength(Instance.ExportKinds, Length(AIr.ExportList));
  SetLength(Instance.ExportAddrs, Length(AIr.ExportList));
  for Index := 0 to High(AIr.ExportList) do
  begin
    Instance.ExportNames[Index] := AIr.ExportList[Index].Name;
    Instance.ExportKinds[Index] := AIr.ExportList[Index].Kind;
    case AIr.ExportList[Index].Kind of
      wxkFunc:
        Instance.ExportAddrs[Index] :=
          Instance.FuncAddrs[AIr.ExportList[Index].Index];
      wxkTable:
        Instance.ExportAddrs[Index] :=
          Instance.TableAddrs[AIr.ExportList[Index].Index];
      wxkMem:
        Instance.ExportAddrs[Index] :=
          Instance.MemAddrs[AIr.ExportList[Index].Index];
      wxkGlobal:
        Instance.ExportAddrs[Index] :=
          Instance.GlobalAddrs[AIr.ExportList[Index].Index];
    else
      Instance.ExportAddrs[Index] :=
        Instance.TagAddrs[AIr.ExportList[Index].Index];
    end;
  end;

  { --- 9 and 10: elements before data ---
    Elements are applied before data — the order of the instantiation
    steps in `exec-module` and what the reference interpreter's
    `instantiate` does. The only observable difference is WHICH trap fires
    when both an element and a data segment are out of bounds, and this
    order reports the element trap first. (runtime-spec.md §6 carries the
    same claim, still flagged UNCONFIRMED there; that scratchpad note is
    the stale one — the code here is the settled behaviour.) }
  ApplyElemSegments(AStore, Instance, AIr);
  ApplyDataSegments(AStore, Instance, AIr);

  { --- 11 --- }
  Instance.HasPendingStart := AIr.HasStart;
  Instance.PendingStartFuncIndex := AIr.StartFuncIndex;
end;

end.
