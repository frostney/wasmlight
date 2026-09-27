{ Wasm.Jit.X64.Plan — x64-only compile-time planning the shared JIT driver
  (Wasm.Jit) hands off: which v128 values the static cache fixes in xmm
  hosts, and which struct.new sites take the inline allocation fast path.

  Every routine here is a pure function of the validated IR it is given (the
  function, its planned code, and the module's canonical types): no store,
  no code buffer, and no driver state beyond its explicit parameters. The
  driver still decides when each plan applies and feeds the result to the
  backend (Wasm.Jit.X64); nothing here emits code. }
unit Wasm.Jit.X64.Plan;

{$I Shared.inc}

interface

uses
  Wasm.Ir,
  Wasm.Jit.X64;

type
  TX64GcAllocShapeList = array of TX64GcAllocShape;
  { Per-instruction SIB scale (0 = none) of a rewritten pinned access. }
  TX64IndexScaleList = array of Byte;

  { The xmm plan for a static-cache function holding natively emitted v128
    ops (X64EnableVecCache's inputs). }
  TX64VecCachePlan = record
    Enabled: Boolean;
    Statics: array of UInt32;
    Consts: array of UInt32;
    ConstLo: array of UInt64;
    ConstHi: array of UInt64;
  end;

{ Plan the xmm cache of AFn. Fixed hosts go first to the most-used v128
  locals and parameters — never a result slot, because a fixed host is not
  written back at an exit — then to loop-invariant v128.const results: a
  constant defined inside a loop span re-materializes every iteration, so it
  is seeded once at entry instead. A candidate constant must be the only
  writer of a slot no local, result, or exit can observe; a validated
  temporary is written before every read, and a unique writer always writes
  the same bits, so the seeded host equals the slot's value at every read. A
  function without v128 ops (AOr without the static cache) keeps its exact
  previous code: APlan.Enabled is False. }
procedure X64PlanVecCache(const AFn: TWasmIrFunction;
  const APlanned: TWasmIrCode; const ASkip: array of Boolean;
  const AStaticCache: Boolean; out APlan: TX64VecCachePlan);

{ x64 inline struct.new. For a FIXED struct type everything Allocate derives
  except the collection decision is compile-time: layout size, size class,
  cell size, field offsets. The backend emits the free-list hit under the
  live collection trigger and falls back to the unchanged helper for
  everything else. Numeric, packed, and reference fields fill inline (a
  struct.new's stores are initializing stores, which the runtime also writes
  without a barrier); v128 fields, large objects, and field counts past the
  shape capacity decline. Unlike the arm64 path, any class size fits: the
  cell index takes a shift and, for the 3*2^k classes, one exact reciprocal
  multiply, and every qword the fills do not cover is zeroed in the
  template. AShapes gets one entry per instruction of AFn; a native scalar
  core plans none. }
procedure X64PlanGcInlineAlloc(const AIr: TWasmIrModule;
  const AFn: TWasmIrFunction; const ANativeScalarCore: Boolean;
  var AShapes: TX64GcAllocShapeList);

{ Scaled pinned index. In a base-pinned static-cache function (AEnabled),
  the address shape `X := i32.and(Y, m); D := i32.shl(X, k); access [D]`,
  k = count mod 32 in 1..3 with both constants fused immediates, becomes the
  access over [base + X * 2^k]; the shl is skipped (ASkip) and the access
  reads X (APlanned[M].A), with AScales[M] = k.

  Exactness: wasm's i32.shl wraps at 32 bits and a 64-bit scaled index does
  not, so the fusion needs X < 2^(32 - k). The 32-bit `and` writes exactly
  X = Y and m <= m, and m * 2^k < 2^32 is required, so X * 2^k is the
  wasm address, unwrapped, with no assumption about the host's upper half
  (the access zero-extends X first unless that host is known Zx32).
  and, shl, and the access are consecutive emitted instructions with no
  label between them, so the access sees the `and`'s X; a guard-page fault
  or trap then happens at the same access with the same address.

  The skipped shl never writes D, so D must be dead after the access: D is
  no result slot, and every other emitted read of D has, scanning back
  within its own straight line (no label crossed, and not falling off the
  entry), a nearest defining instruction other than the shl. That proves
  no read — lexical or through a back-edge or join, since every block start
  is a label — can observe D's unwritten value. The defining set is an
  under-approximation (moves, constants, and integer ALU/shift/rotate ops),
  and any op outside the static-cache read set counts as reading D. }
procedure X64PlanScaledIndex(const AFn: TWasmIrFunction;
  var APlanned: TWasmIrCode; var ASkip: array of Boolean;
  const ATargets, AImmediate: array of Boolean;
  const AImmValues: array of Int64; const AEnabled: Boolean;
  var AScales: TX64IndexScaleList);

implementation

uses
  Wasm.Core,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Values;

function LoadOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := AOp in [
    iroI32Load, iroI64Load, iroF32Load, iroF64Load,
    iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
    iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
    iroI64Load32S, iroI64Load32U];
end;

function StoreOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := AOp in [
    iroI32Store, iroI64Store, iroF32Store, iroF64Store,
    iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
    iroI64Store32];
end;

function IntAluOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := AOp in [
    iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
    iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
    iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
    iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr];
end;

{ Whether AIns may read ASlot. Every op outside the known read shapes is
  assumed to. A return reads only result slots, which the caller excludes. }
function MayReadSlot(const AIns: TWasmIrInstr; const ASlot: UInt32): Boolean;
begin
  if IntAluOp(AIns.Op) then
    Exit((AIns.A = ASlot) or (AIns.B = ASlot));
  if LoadOp(AIns.Op) then
    Exit(AIns.A = ASlot);
  if StoreOp(AIns.Op) then
    Exit((AIns.A = ASlot) or (AIns.Dest = ASlot));
  case AIns.Op of
    iroJump, iroReturn, iroUnreachable,
    iroI32Const, iroI64Const, iroF32Const, iroF64Const:
      Result := False;
    iroMove, iroBranchIf, iroBranchIfNot, iroI32Eqz, iroI64Eqz:
      Result := AIns.A = ASlot;
    iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
    iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
    iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
    iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU:
      Result := (AIns.A = ASlot) or (AIns.B = ASlot);
  else
    Result := True;
  end;
end;

function IsResultSlot(const AFn: TWasmIrFunction;
  const ASlot: UInt32): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(AFn.ResultRegs) do
    if AFn.ResultRegs[K] = ASlot then
      Exit(True);
  Result := False;
end;

procedure X64PlanScaledIndex(const AFn: TWasmIrFunction;
  var APlanned: TWasmIrCode; var ASkip: array of Boolean;
  const ATargets, AImmediate: array of Boolean;
  const AImmValues: array of Int64; const AEnabled: Boolean;
  var AScales: TX64IndexScaleList);
var
  S, P, M: Integer;
  K: Byte;
  X, D: UInt32;

  { The nearest emitted instruction before AIndex, or -1 when a label or
    the entry comes first. }
  function PrevEmitted(const AIndex: Integer): Integer;
  begin
    Result := AIndex;
    repeat
      if ATargets[Result] then
        Exit(-1);
      Dec(Result);
    until (Result < 0) or not ASkip[Result];
  end;

  { The next emitted instruction after AIndex, or -1 when a label comes
    first or the code ends. }
  function NextEmitted(const AIndex: Integer): Integer;
  begin
    Result := AIndex;
    repeat
      Inc(Result);
      if (Result > High(APlanned)) or ATargets[Result] then
        Exit(-1);
    until not ASkip[Result];
  end;

  { The nearest instruction before AIndex, in its straight line, that
    writes D; -1 when a label or the entry comes first. }
  function ReachingDef(const AIndex: Integer): Integer;
  begin
    Result := AIndex;
    repeat
      if ATargets[Result] then
        Exit(-1);
      Dec(Result);
      if Result < 0 then
        Exit;
    until not ASkip[Result] and (APlanned[Result].Dest = D) and
      ((APlanned[Result].Op in [iroMove, iroI32Const, iroI64Const]) or
      IntAluOp(APlanned[Result].Op));
  end;

  function DeadAfterAccess: Boolean;
  var
    R, W: Integer;
  begin
    if IsResultSlot(AFn, D) then
      Exit(False);
    for R := 0 to High(APlanned) do
      if (R <> M) and not ASkip[R] and MayReadSlot(APlanned[R], D) then
      begin
        W := ReachingDef(R);
        if (W < 0) or (W = S) then
          Exit(False);
      end;
    Result := True;
  end;

begin
  SetLength(AScales, Length(APlanned));
  if not AEnabled then
    Exit;
  for S := 0 to High(APlanned) do
  begin
    if ASkip[S] or (APlanned[S].Op <> iroI32Shl) or not AImmediate[S] then
      Continue;
    K := Byte(AImmValues[S] and 31);
    X := APlanned[S].A;
    D := APlanned[S].Dest;
    P := PrevEmitted(S);
    M := NextEmitted(S);
    if (K < 1) or (K > 3) or (X = D) or (P < 0) or (M < 0) or
      (APlanned[P].Op <> iroI32And) or not AImmediate[P] or
      (APlanned[P].Dest <> X) or
      ((UInt64(UInt32(AImmValues[P] and $FFFFFFFF)) shl K) > $FFFFFFFF) or
      not (LoadOp(APlanned[M].Op) or StoreOp(APlanned[M].Op)) or
      (APlanned[M].A <> D) or (APlanned[M].Imm <> 0) or
      (StoreOp(APlanned[M].Op) and (APlanned[M].Dest = D)) or
      not DeadAfterAccess then
      Continue;
    ASkip[S] := True;
    APlanned[M].A := X;
    AScales[M] := K;
  end;
end;

function IsVisibleFrameReg(const AFn: TWasmIrFunction;
  const AReg: UInt32): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(AFn.LocalRegs) do
    if AFn.LocalRegs[K] = AReg then
      Exit(True);
  for K := 0 to High(AFn.ResultRegs) do
    if AFn.ResultRegs[K] = AReg then
      Exit(True);
  Result := False;
end;

procedure X64PlanVecCache(const AFn: TWasmIrFunction;
  const APlanned: TWasmIrCode; const ASkip: array of Boolean;
  const AStaticCache: Boolean; out APlan: TX64VecCachePlan);
const
  MAX_FIXED = 8;
  MAX_STATIC = 6;
var
  K, M, Best: Integer;
  Scores: array of UInt32;
  Slot: UInt32;
  Ins: TWasmIrInstr;
  HasVec, InLoop, Unique: Boolean;
  VTmp: TWasmV128;

  procedure ScoreVec(const ASlot: UInt32; const AWeight: UInt32);
  begin
    if ASlot < UInt32(Length(Scores)) then
      Inc(Scores[ASlot], AWeight);
  end;

  function Chosen(const ASlot: UInt32): Boolean;
  var
    N: Integer;
  begin
    Result := True;
    for N := 0 to High(APlan.Statics) do
      if APlan.Statics[N] = ASlot then
        Exit;
    for N := 0 to High(APlan.Consts) do
      if APlan.Consts[N] = ASlot then
        Exit;
    Result := False;
  end;

begin
  APlan.Enabled := False;
  SetLength(APlan.Statics, 0);
  SetLength(APlan.Consts, 0);
  SetLength(APlan.ConstLo, 0);
  SetLength(APlan.ConstHi, 0);
  if not AStaticCache then
    Exit;
  HasVec := False;
  SetLength(Scores, AFn.RegisterCount);
  for K := 0 to High(APlanned) do
  begin
    Ins := APlanned[K];
    if ASkip[K] or not X64VecCacheOp(Ins.Op) then
      Continue;
    HasVec := True;
    case Ins.Op of
      iroMoveVec:
        begin
          ScoreVec(Ins.A, 2);
          ScoreVec(Ins.Dest, 2);
        end;
      iroV128Const,
      iroI8x16Splat, iroI16x8Splat, iroI32x4Splat, iroI64x2Splat:
        ScoreVec(Ins.Dest, 1);
      iroI8x16ExtractLaneS, iroI8x16ExtractLaneU,
      iroI16x8ExtractLaneS, iroI16x8ExtractLaneU,
      iroI32x4ExtractLane, iroI64x2ExtractLane:
        ScoreVec(Ins.A, 1);
      iroV128Not:
        begin
          ScoreVec(Ins.A, 1);
          ScoreVec(Ins.Dest, 1);
        end;
    else
      ScoreVec(Ins.A, 1);
      ScoreVec(Ins.B, 1);
      ScoreVec(Ins.Dest, 1);
    end;
  end;
  if not HasVec then
    Exit;
  APlan.Enabled := True;
  repeat
    Best := -1;
    for K := 0 to High(AFn.LocalRegs) do
    begin
      Slot := AFn.LocalRegs[K];
      if (Slot >= UInt32(Length(AFn.RegTypes))) or
        (AFn.RegTypes[Slot].Kind <> wvkVec) or (Scores[Slot] < 2) or
        Chosen(Slot) then
        Continue;
      if (Best < 0) or (Scores[Slot] > Scores[AFn.LocalRegs[Best]]) then
        Best := K;
    end;
    if Best >= 0 then
    begin
      SetLength(APlan.Statics, Length(APlan.Statics) + 1);
      APlan.Statics[High(APlan.Statics)] := AFn.LocalRegs[Best];
    end;
  until (Best < 0) or (Length(APlan.Statics) = MAX_STATIC);
  for K := 0 to High(APlanned) do
  begin
    if Length(APlan.Statics) + Length(APlan.Consts) >= MAX_FIXED then
      Break;
    Ins := APlanned[K];
    if ASkip[K] or (Ins.Op <> iroV128Const) or
      IsVisibleFrameReg(AFn, Ins.Dest) or Chosen(Ins.Dest) then
      Continue;
    InLoop := False;
    for M := K to High(APlanned) do
      if ((APlanned[M].Op = iroJump) and
        (APlanned[M].A <= UInt32(K))) or
        ((APlanned[M].Op in [iroBranchIf, iroBranchIfNot]) and
        (APlanned[M].B <= UInt32(K))) then
      begin
        InLoop := True;
        Break;
      end;
    if not InLoop then
      Continue;
    { Every Dest field counts, including a store's value operand: a
      conservative superset of the slot's writers. }
    Unique := True;
    for M := 0 to High(AFn.Code) do
      if (M <> K) and ((AFn.Code[M].Dest = Ins.Dest) or
        (APlanned[M].Dest = Ins.Dest)) then
      begin
        Unique := False;
        Break;
      end;
    if not Unique then
      Continue;
    IrAuxReadV128(AFn.AuxU32, UInt32(Ins.Imm), VTmp);
    SetLength(APlan.Consts, Length(APlan.Consts) + 1);
    SetLength(APlan.ConstLo, Length(APlan.Consts));
    SetLength(APlan.ConstHi, Length(APlan.Consts));
    APlan.Consts[High(APlan.Consts)] := Ins.Dest;
    APlan.ConstLo[High(APlan.Consts)] := VTmp.U64[0];
    APlan.ConstHi[High(APlan.Consts)] := VTmp.U64[1];
  end;
end;

{ The storage width of one struct field, 16 for a v128 (which declines). }
function FieldWidth(const AStorage: TWasmStorageType): UInt32;
begin
  if AStorage.IsPacked then
  begin
    if AStorage.PackedType = wpkI8 then
      Result := 1
    else
      Result := 2;
    Exit;
  end;
  case AStorage.ValueType.Kind of
    wvkNum:
      if (AStorage.ValueType.Num = wntI32) or
        (AStorage.ValueType.Num = wntF32) then
        Result := 4
      else
        Result := 8;
    wvkRef:
      Result := SizeOf(TWasmRef);
  else
    Result := 16;
  end;
end;

{ Whether every heap offset the inline template bakes fits a disp32. }
function GcOffsetsFitDisp32: Boolean;
begin
  with WasmJitGcHeapOffsets do
    Result := not ((HeapFFree0 + WASM_GC_CLASS_COUNT * 8 > $7FFFFFFF) or
      (HeapMarkState > $7FFFFFFF) or (HeapBytesLive > $7FFFFFFF) or
      (HeapBytesAllocated > $7FFFFFFF) or
      (HeapObjectCount > $7FFFFFFF) or (HeapThreshold > $7FFFFFFF) or
      (BlockBase > $7FFFFFFF) or (BlockAllocated > $7FFFFFFF));
end;

{ The shape of one struct.new of the struct type AComp, or False when the
  inline path declines it. }
function PlanStructShape(const AComp: TWasmCompType;
  var AShape: TX64GcAllocShape): Boolean;
var
  F, C, ClassIndex: Integer;
  Offset, Width, Size, CellSize, Base, Shift: UInt32;
  Covered: UInt64;
  ByteCount: array[0..31] of UInt32;
begin
  Result := False;
  F := Length(AComp.Struct.Fields);
  { Field walk — the arithmetic of TWasmGcTypes.Define: header 8, each field
    aligned up to its storage width, cumulative advance. }
  Offset := 8;
  for C := 0 to F - 1 do
  begin
    Width := FieldWidth(AComp.Struct.Fields[C].Storage);
    if Width > 8 then
      Exit;
    Offset := (Offset + Width - 1) and not (Width - 1);
    AShape.Fields[C].Offset := UInt16(Offset);
    AShape.Fields[C].Width := Byte(Width);
    Offset := Offset + Width;
  end;

  { Size-class math mirrors TWasmGcHeap.Allocate: align the span to 8, bump
    to the first class, take the first class that fits. A size past every
    class is a large object, which the helper owns. }
  Size := (Offset + 7) and not UInt32(7);
  if Size < WASM_GC_SIZE_CLASSES[0] then
    Size := WASM_GC_SIZE_CLASSES[0];
  ClassIndex := -1;
  for C := 0 to WASM_GC_CLASS_COUNT - 1 do
    if Size <= WASM_GC_SIZE_CLASSES[C] then
    begin
      ClassIndex := C;
      Break;
    end;
  if ClassIndex < 0 then
    Exit;
  CellSize := WASM_GC_SIZE_CLASSES[ClassIndex];
  if (CellSize mod 3) = 0 then
    Base := CellSize div 3
  else
    Base := CellSize;
  Shift := 0;
  while (UInt32(1) shl Shift) < Base do
    Inc(Shift);
  if ((UInt32(1) shl Shift) <> Base) or (CellSize > 256) then
    Exit;

  { Qwords after the header the fills write in full (fields never overlap,
    so eight covered bytes means the whole qword). }
  FillChar(ByteCount, SizeOf(ByteCount), 0);
  for C := 0 to F - 1 do
    Inc(ByteCount[AShape.Fields[C].Offset div 8], AShape.Fields[C].Width);
  Covered := 0;
  for C := 1 to Integer(CellSize div 8) - 1 do
    if ByteCount[C] = 8 then
      Covered := Covered or (UInt64(1) shl C);

  AShape.Enabled := True;
  AShape.FieldCount := Byte(F);
  AShape.ClassIndex := Byte(ClassIndex);
  AShape.CellShift := Byte(Shift);
  AShape.CellTimes3 := Base <> CellSize;
  AShape.CellSize := UInt16(CellSize);
  AShape.Covered := Covered;
  Result := True;
end;

procedure X64PlanGcInlineAlloc(const AIr: TWasmIrModule;
  const AFn: TWasmIrFunction; const ANativeScalarCore: Boolean;
  var AShapes: TX64GcAllocShapeList);
var
  K, F, CanonIdx: Integer;
  TypeIdx: UInt32;
  Comp: ^TWasmCompType;
begin
  SetLength(AShapes, Length(AFn.Code));
  for K := 0 to High(AFn.Code) do
    AShapes[K] := Default(TX64GcAllocShape);
  if ANativeScalarCore or not GcOffsetsFitDisp32 then
    Exit;

  for K := 0 to High(AFn.Code) do
  begin
    if AFn.Code[K].Op <> iroStructNew then
      Continue;
    TypeIdx := UInt32(AFn.Code[K].Imm);
    { EngineTypeIds[Imm] is a disp32 load in the template. }
    if (TypeIdx >= UInt32(Length(AIr.TypeIndexToCanon))) or
      (TypeIdx >= $1FFFFFFF) then
      Continue;
    CanonIdx := Integer(AIr.TypeIndexToCanon[TypeIdx]);
    if (CanonIdx < 0) or (CanonIdx >= Length(AIr.CanonTypes)) then
      Continue;
    Comp := @AIr.CanonTypes[CanonIdx].Comp;
    if Comp^.Kind <> wckStruct then
      Continue;
    F := Length(Comp^.Struct.Fields);
    if (F > Length(AShapes[K].Fields)) or
      (UInt32(F) <> IrAuxBlockCount(AFn.AuxU32, AFn.Code[K].A)) then
      Continue;
    { A declined shape may carry partial field offsets, exactly as the
      driver's inline walk left them; Enabled stays False. }
    PlanStructShape(Comp^, AShapes[K]);
  end;
end;

end.
