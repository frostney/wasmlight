{ Shared memory and GC instruction bodies for the native backends.
  Memory accesses use the store chokepoint; new GC objects are published in
  the traced register file before their fields are filled. Helpers retain only
  unmanaged locals so a trap can unwind to the invocation trampoline. }
unit Wasm.Jit.Runtime;

{$I Shared.inc}

{$POINTERMATH ON}

interface

uses
  Wasm.Core,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

procedure JitDoMem(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);

{ Preserve the backends' existing struct initialization choices: Arm64 batches
  up to eight fields, X64 writes each field. Both use the same GC barriers. }
procedure JitDoGc(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr;
  const ABatchStructFields: Boolean);

implementation

uses
  Wasm.Runtime.Gc,
  Wasm.Runtime.Traps;

{ Little-endian, unaligned-safe loads and stores behind the memory chokepoint. }
function JitMemLoadBytes(const AStore: TWasmStore; const AMemAddr: TWasmMemAddr;
  const AIndex, AOffset: UInt64; const ASize: NativeUInt): UInt64;
var
  P: PByte;
begin
  P := AStore.MemAddressAt(AMemAddr, AIndex, AOffset, ASize);
  Result := 0;
  Move(P^, Result, ASize);
end;

procedure JitMemStoreBytes(const AStore: TWasmStore;
  const AMemAddr: TWasmMemAddr; const AIndex, AOffset: UInt64;
  const ASize: NativeUInt; const AValue: UInt64);
var
  P: PByte;
  V: UInt64;
begin
  P := AStore.MemAddressAt(AMemAddr, AIndex, AOffset, ASize);
  V := AValue;
  Move(V, P^, ASize);
end;

procedure JitDoMem(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr);
var
  Reg: PWasmValue;
  Inst: TWasmModuleInstance;
  MemAddr, DstMemAddr, SrcMemAddr: TWasmMemAddr;
  Raw: UInt64;
  MemIdx, DataIdx, DstMem, SrcMem: UInt32;
  DataAddr: TWasmDataAddr;
  DstIdx, SrcOff, SrcIdx, Count, DataSize: UInt64;
  DstPtr, SrcPtr: PByte;
begin
  Reg := AReg;
  Inst := AAct^.Instance;
  case AIns^.Op of
    { --- loads (B = mem index, A = index reg, Imm = static offset) ------- }
    iroI32Load:
      Reg[AIns^.Dest].Bits := UInt64(UInt32(JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4)));
    iroI64Load:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 8);
    iroF32Load:
      Reg[AIns^.Dest].Bits := UInt64(UInt32(JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4)));
    iroF64Load:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore,
        Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64, UInt64(AIns^.Imm), 8);
    iroI32Load8S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
        Reg[AIns^.Dest].Bits := UInt64(UInt32(Int32(ShortInt(Byte(Raw)))));
      end;
    iroI32Load8U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
    iroI32Load16S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
        Reg[AIns^.Dest].Bits := UInt64(UInt32(Int32(SmallInt(Word(Raw)))));
      end;
    iroI32Load16U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
    iroI64Load8S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
        Reg[AIns^.Dest].Bits := UInt64(Int64(ShortInt(Byte(Raw))));
      end;
    iroI64Load8U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 1);
    iroI64Load16S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
        Reg[AIns^.Dest].Bits := UInt64(Int64(SmallInt(Word(Raw))));
      end;
    iroI64Load16U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 2);
    iroI64Load32S:
      begin
        Raw := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
          Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4);
        Reg[AIns^.Dest].Bits := UInt64(Int64(Int32(UInt32(Raw))));
      end;
    iroI64Load32U:
      Reg[AIns^.Dest].Bits := JitMemLoadBytes(AStore, Inst.MemAddrs[AIns^.B],
        Reg[AIns^.A].U64, UInt64(AIns^.Imm), 4);

    { --- stores (Dest = value reg, A = index reg, B = mem index) --------- }
    iroI32Store, iroF32Store:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 4, Reg[AIns^.Dest].U64);
    iroI64Store, iroF64Store:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 8, Reg[AIns^.Dest].U64);
    iroI32Store8, iroI64Store8:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 1, Reg[AIns^.Dest].U64);
    iroI32Store16, iroI64Store16:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 2, Reg[AIns^.Dest].U64);
    iroI64Store32:
      JitMemStoreBytes(AStore, Inst.MemAddrs[AIns^.B], Reg[AIns^.A].U64,
        UInt64(AIns^.Imm), 4, Reg[AIns^.Dest].U64);

    { --- size / grow (grow never traps, never collects; -1 on failure) -- }
    iroMemorySize:
      Reg[AIns^.Dest].Bits := AStore.MemoryPages(Inst.MemAddrs[UInt32(AIns^.Imm)]);
    iroMemoryGrow:
      begin
        MemAddr := Inst.MemAddrs[UInt32(AIns^.Imm)];
        if AStore.MemoryAddrType(MemAddr) = watI64 then
          Reg[AIns^.Dest].Bits :=
            UInt64(AStore.MemoryGrow(MemAddr, Reg[AIns^.A].U64))
        else
          Reg[AIns^.Dest].Bits :=
            UInt64(UInt32(AStore.MemoryGrow(MemAddr, Reg[AIns^.A].U64)));
      end;

    { --- bulk (range-checked through the chokepoint; write nothing on trap) }
    iroMemoryInit:
      begin
        IrUnpack(AIns^.Imm, MemIdx, DataIdx);
        MemAddr := Inst.MemAddrs[MemIdx];
        DataAddr := Inst.DataAddrs[DataIdx];
        DstIdx := Reg[AIns^.Dest].U64;
        SrcOff := Reg[AIns^.A].U64;
        Count := Reg[AIns^.B].U64;
        DstPtr := AStore.MemRangeAt(MemAddr, DstIdx, Count);
        DataSize := UInt64(AStore.Datas[DataAddr].Size);
        if (SrcOff > DataSize) or (Count > DataSize - SrcOff) then
          TrapNow(wtkMemoryOutOfBounds);
        if Count > 0 then
        begin
          SrcPtr := AStore.Datas[DataAddr].Data;
          Inc(SrcPtr, SrcOff);
          Move(SrcPtr^, DstPtr^, NativeUInt(Count));
        end;
      end;
    iroMemoryCopy:
      begin
        IrUnpack(AIns^.Imm, DstMem, SrcMem);
        DstIdx := Reg[AIns^.Dest].U64;
        SrcIdx := Reg[AIns^.A].U64;
        Count := Reg[AIns^.B].U64;
        DstMemAddr := Inst.MemAddrs[DstMem];
        SrcMemAddr := Inst.MemAddrs[SrcMem];
        DstPtr := AStore.MemRangeAt(DstMemAddr, DstIdx, Count);
        SrcPtr := AStore.MemRangeAt(SrcMemAddr, SrcIdx, Count);
        if Count > 0 then
          Move(SrcPtr^, DstPtr^, NativeUInt(Count));
      end;
    iroMemoryFill:
      begin
        DstIdx := Reg[AIns^.Dest].U64;
        Count := Reg[AIns^.B].U64;
        DstPtr := AStore.MemRangeAt(Inst.MemAddrs[UInt32(AIns^.Imm)],
          DstIdx, Count);
        if Count > 0 then
          FillChar(DstPtr^, NativeUInt(Count), Byte(Reg[AIns^.A].U32 and $FF));
      end;
    iroDataDrop:
      begin
        DataAddr := Inst.DataAddrs[UInt32(AIns^.Imm)];
        AStore.Datas[DataAddr].Dropped := True;
        AStore.Datas[DataAddr].Size := 0;
        AStore.Datas[DataAddr].Data := nil;
      end;
  end;
end;

procedure JitDoGc(const AStore: TWasmStore; const AReg: PWasmValue;
  const AAct: PWasmActivation; const AIns: PWasmIrInstr;
  const ABatchStructFields: Boolean);
var
  Reg: PWasmValue;
  Inst: TWasmModuleInstance;
  Fn: PWasmIrFunction;
  Obj: TWasmRef;
  N, I, U1, U2, TypeIdx, DataIdx, ElemIdx, Aux: UInt32;
  TmpFields: array[0..7] of TWasmValue;
  ElemOffset, Count, SrcLen: UInt32;
  DataAddr: TWasmDataAddr;
  ElemAddr: TWasmElemAddr;
begin
  Reg := AReg;
  Inst := AAct^.Instance;
  Fn := AAct^.Fn;
  case AIns^.Op of
    iroStructNew:
      begin
        Obj := AStore.Heap.AllocStruct(Inst.EngineTypeIds[UInt32(AIns^.Imm)]);
        Reg[AIns^.Dest].Bits := UInt64(Obj);            { publish before fill }
        N := IrAuxBlockCount(Fn^.AuxU32, AIns^.A);
        if ABatchStructFields and (N <= UInt32(Length(TmpFields))) then
        begin
          for I := 0 to Integer(N) - 1 do
            TmpFields[I] := Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)];
          AStore.Heap.StructSetSeq(Obj, @TmpFields[0], N);
        end
        else
        begin
          I := 0;
          while I < N do
          begin
            AStore.Heap.StructSet(Obj, I,
              Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)]);
            Inc(I);
          end;
        end;
      end;
    iroStructNewDefault:
      begin
        Obj := AStore.Heap.AllocStruct(Inst.EngineTypeIds[UInt32(AIns^.Imm)]);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.StructSetDefaults(Obj);
      end;
    iroStructGet:
      begin
        IrUnpack(AIns^.Imm, U1, U2);   { U2 = field index }
        Reg[AIns^.Dest] := AStore.Heap.StructGet(Reg[AIns^.A].Ref, U2);
      end;
    iroStructGetS:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        ValueSetI32(Reg[AIns^.Dest],
          AStore.Heap.StructGetSigned(Reg[AIns^.A].Ref, U2));
      end;
    iroStructGetU:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        ValueSetU32(Reg[AIns^.Dest],
          AStore.Heap.StructGetUnsigned(Reg[AIns^.A].Ref, U2));
      end;
    iroStructSet:
      begin
        IrUnpack(AIns^.Imm, U1, U2);
        AStore.Heap.StructSet(Reg[AIns^.A].Ref, U2, Reg[AIns^.B]);
      end;

    iroArrayNew:
      begin
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[UInt32(AIns^.Imm)],
          Reg[AIns^.B].U32);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.ArrayFill(Obj, Reg[AIns^.A]);
      end;
    iroArrayNewDefault:
      begin
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[UInt32(AIns^.Imm)],
          Reg[AIns^.A].U32);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.ArraySetDefaults(Obj);
      end;
    iroArrayNewFixed:
      begin
        N := IrAuxBlockCount(Fn^.AuxU32, AIns^.A);
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[UInt32(AIns^.Imm)], N);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        I := 0;
        while I < N do
        begin
          AStore.Heap.ArraySet(Obj, I,
            Reg[IrAuxBlockItem(Fn^.AuxU32, AIns^.A, I)]);
          Inc(I);
        end;
      end;
    iroArrayNewData:
      begin
        IrUnpack(AIns^.Imm, TypeIdx, DataIdx);
        DataAddr := Inst.DataAddrs[DataIdx];
        AStore.Heap.CheckArrayDataRange(Inst.EngineTypeIds[TypeIdx],
          AStore.Datas[DataAddr].Size, Reg[AIns^.A].U64, Reg[AIns^.B].U32);
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[TypeIdx],
          Reg[AIns^.B].U32);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.ArrayInitFromData(Obj, 0, AStore.Datas[DataAddr].Data,
          AStore.Datas[DataAddr].Size, Reg[AIns^.A].U64, Reg[AIns^.B].U32);
      end;
    iroArrayNewElem:
      begin
        IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
        ElemAddr := Inst.ElemAddrs[ElemIdx];
        { The element-segment source range is checked BEFORE allocating, so an
          overflowing count traps 'out of bounds table access' rather than
          'out of memory' (interp-spec, corpus array.wast:283). }
        ElemOffset := Reg[AIns^.A].U32;
        Count := Reg[AIns^.B].U32;
        SrcLen := UInt32(Length(AStore.Elems[ElemAddr].Refs));
        if (ElemOffset > SrcLen) or (Count > SrcLen - ElemOffset) then
          TrapNow(wtkTableOutOfBounds);
        Obj := AStore.Heap.AllocArray(Inst.EngineTypeIds[TypeIdx], Count);
        Reg[AIns^.Dest].Bits := UInt64(Obj);
        AStore.Heap.ArrayInitFromElem(Obj, 0, AStore.Elems[ElemAddr].Refs,
          ElemOffset, Count);
      end;
    iroArrayGet:
      Reg[AIns^.Dest] :=
        AStore.Heap.ArrayGet(Reg[AIns^.A].Ref, Reg[AIns^.B].U32);
    iroArrayGetS:
      ValueSetI32(Reg[AIns^.Dest],
        AStore.Heap.ArrayGetSigned(Reg[AIns^.A].Ref, Reg[AIns^.B].U32));
    iroArrayGetU:
      ValueSetU32(Reg[AIns^.Dest],
        AStore.Heap.ArrayGetUnsigned(Reg[AIns^.A].Ref, Reg[AIns^.B].U32));
    iroArraySet:
      AStore.Heap.ArraySet(Reg[AIns^.Dest].Ref, Reg[AIns^.A].U32,
        Reg[AIns^.B]);
    iroArrayLen:
      ValueSetU32(Reg[AIns^.Dest], AStore.Heap.ArrayLength(Reg[AIns^.A].Ref));
    iroArrayFill:
      begin
        Aux := AIns^.A;   { aux [ref, index, value, count] }
        AStore.Heap.ArrayFill(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)]);
      end;
    iroArrayCopy:
      begin
        Aux := AIns^.A;   { aux [dstRef, dstIdx, srcRef, srcIdx, count] }
        AStore.Heap.ArrayCopy(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 4)].U32);
      end;
    iroArrayInitData:
      begin
        Aux := AIns^.A;   { aux [destRef, destIdx, srcByteOffset, count] }
        IrUnpack(AIns^.Imm, TypeIdx, DataIdx);
        DataAddr := Inst.DataAddrs[DataIdx];
        AStore.Heap.ArrayInitFromData(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          AStore.Datas[DataAddr].Data, AStore.Datas[DataAddr].Size,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].U64,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32);
      end;
    iroArrayInitElem:
      begin
        Aux := AIns^.A;   { aux [destRef, destIdx, srcElemOffset, count] }
        IrUnpack(AIns^.Imm, TypeIdx, ElemIdx);
        ElemAddr := Inst.ElemAddrs[ElemIdx];
        AStore.Heap.ArrayInitFromElem(
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 0)].Ref,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 1)].U32,
          AStore.Elems[ElemAddr].Refs,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 2)].U32,
          Reg[IrAuxBlockItem(Fn^.AuxU32, Aux, 3)].U32);
      end;

    { extern.convert_any / any.convert_extern: route through the same GC
      wrapper pair the interpreter uses so a subsequent ref.test/ref.cast
      classifies the value in the right hierarchy (M7). The JIT inherits the
      interpreter's semantics because it calls the identical helpers — the
      differential oracle requires it. }
    iroExternConvertAny:
      ValueSetRef(Reg[AIns^.Dest], AStore.Heap.ExternalizeAny(Reg[AIns^.A].Ref));
    iroAnyConvertExtern:
      ValueSetRef(Reg[AIns^.Dest], AStore.Heap.InternalizeExtern(Reg[AIns^.A].Ref));
    iroRefI31:
      Reg[AIns^.Dest].Bits := UInt64(MakeI31Ref(Reg[AIns^.A].I32));
    iroI31GetS:
      begin
        if RefIsNull(Reg[AIns^.A].Ref) then
          TrapNow(wtkNullI31Reference);
        ValueSetI32(Reg[AIns^.Dest], I31GetSigned(Reg[AIns^.A].Ref));
      end;
    iroI31GetU:
      begin
        if RefIsNull(Reg[AIns^.A].Ref) then
          TrapNow(wtkNullI31Reference);
        ValueSetU32(Reg[AIns^.Dest], I31GetUnsigned(Reg[AIns^.A].Ref));
      end;
  end;
end;

end.
