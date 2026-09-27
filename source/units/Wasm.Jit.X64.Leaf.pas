{ Wasm.Jit.X64.Leaf — x64-only planning for the native leaf ABI: which
  defined functions get the lightweight leaf entry, which direct call sites
  take it, and the operand forwarding around those calls.

  A native leaf takes up to four i32/i64 parameters in r8, r9, rdi, and rdx
  (in parameter order) and returns its one result in r8. A leaf that
  accesses memory does so only through the zero-offset i32 guard-page form
  and reads that memory's Base from rsi, which its caller supplies: a call
  target named by a defined function index is a function of the caller's own
  instance (Store.Funcs[Instance.FuncAddrs[k]] for k past the imports), so
  its memory is the caller instance's memory of the same index. Nothing in a
  leaf can change that Base (no memory.grow, no call), and a guard-page
  fault unwinds to the invocation trampoline, which reads no register-file
  slot, exactly as in a base-pinned static-cache loop.

  Every routine here is a pure function of the validated IR it is given; the
  driver (Wasm.Jit) decides when each plan applies and the backend
  (Wasm.Jit.X64) emits it. Nothing here emits code. }
unit Wasm.Jit.X64.Leaf;

{$I Shared.inc}

interface

uses
  Wasm.Ir,
  Wasm.Jit.X64;

type
  { The native-leaf shape of a function (X64NativeLeafShape). }
  TX64LeafShape = record
    ParamCount: Byte;
    UsesMemory: Boolean;
    MemoryIndex: UInt32;
    HasSelect: Boolean;
  end;

  { One entry per IR instruction of the function being compiled. }
  TX64LeafCallList = array of TX64LeafCall;
  TX64BoolArray = array of Boolean;

{ Whether AFn gets the x64 native leaf entry, and its shape. A superset of
  the shared JitCanNativeScalarLeaf proof: one to four numeric parameters
  and one result, no declared locals, no handlers, at most 32 registers, and
  only helper-free straight-line ops the native core emits from its cache —
  the scalar leaf set, i64.extend_i32_s/u and i32.wrap_i64, and scalar loads
  and stores that are zero-offset accesses through an i32 address to one
  memory. select needs rdx as scratch, so a four-parameter leaf (whose
  fourth parameter lives in rdx) excludes it. }
function X64NativeLeafShape(const AFn: TWasmIrFunction;
  out AShape: TX64LeafShape): Boolean;

{ The x64 native-leaf proof alone (X64NativeLeafShape without the shape). }
function X64CanNativeLeaf(const AFn: TWasmIrFunction): Boolean;

{ Plan every direct call of AFn to a defined function of AIr with the native
  leaf shape: ACalls[K].Enabled, ParamCount, UsesMemory, MemoryIndex, and the
  leaf's clobbers; no argument or result forwarding yet. A nil AIr plans
  none. }
procedure X64PlanLeafCalls(const AIr: TWasmIrModule;
  const AFn: TWasmIrFunction; out ACalls: TX64LeafCallList);

{ Fold the memories the planned leaf calls access into the caller's pinned
  memory analysis (AFound / AMultiple / AIndex, as the caller's own accesses
  set them): the caller pins the leaf's memory and passes its Base. }
procedure X64FoldLeafMemory(const ACalls: TX64LeafCallList;
  var AFound, AMultiple: Boolean; var AIndex: UInt32);

{ Disable every planned call to a leaf that uses memory unless the caller
  pins exactly that memory (APinned, AIndex): the leaf reads its Base from
  rsi, which the caller loads from its pinned instance. A disabled site
  keeps the generic direct call. }
procedure X64RestrictMemoryLeafCalls(var ACalls: TX64LeafCallList;
  const APinned: Boolean; const AIndex: UInt32);

{ Whether any instruction's plan is enabled. }
function X64AnyLeafCall(const ACalls: TX64LeafCallList): Boolean;

{ Forward copies within a basic block: a native leaf body, or a
  static-cache caller of native leaves. A `move T <- S` whose temporary T
  has exactly one read (AUseCounts, the canonical read counts) and is
  neither a local, a parameter, nor a result is skipped and that read
  renamed to S, provided nothing between them writes S or T and no join
  (ATargets), branch, return, safepoint, or call lies between them other
  than a planned leaf call (ACalls), which writes only its result and
  neither reads nor writes anything else of the caller's frame. A read by a
  call argument is left to X64PlanLeafCallOperands. Runs before the
  liveness analyses, so their counts see the renamed code. }
procedure X64PlanBlockAliases(const AFn: TWasmIrFunction;
  var APlanned: TWasmIrCode; var ASkip: array of Boolean;
  const AUseCounts: array of UInt32; const ATargets: array of Boolean;
  const ACalls: TX64LeafCallList);

{ Re-seat a static-cache caller's fixed hosts around its leaf calls
  (AAllocated: the driver's r8, r9, rdi, rdx slots, High(UInt32) unused).
  When every planned call targets one leaf (so the activation caches its
  entry and no inline resolution clobbers rdi/rdx) and that leaf leaves rdi
  or rdx alone, the hottest loop locals (by AScoresInLoop, then AScores,
  then slot order) move to those hosts: a host the leaf preserves needs no
  store before and no reload after each call. The remaining hosts keep the
  previously chosen slots in their order. }
procedure X64PreferLeafPreservedHosts(const AFn: TWasmIrFunction;
  const ACalls: TX64LeafCallList;
  const AScores, AScoresInLoop: array of UInt32;
  var AAllocated: array of UInt32);

{ AWritten[r]: some instruction of AFn writes register r — a Dest the op
  defines (both slots of a v128) or a call's result. Planning only ever
  renames reads or moves a write onto a register the canonical code also
  writes, so this canonical set covers the planned code. }
procedure X64PlanWrittenSlots(const AFn: TWasmIrFunction;
  out AWritten: TX64BoolArray);

{ In a static-cache caller, after the liveness analyses: an argument
  temporary whose only definition is an adjacent-enough `move T <- S` or
  i32/i64 constant is read straight from S (ArgSlots) or materialized in its
  argument register (ArgConst), and a result temporary copied by the next
  instruction into S is written to S directly (ResultSlot). The skipped
  definitions keep the counts the liveness plan assigned them: the call
  consumes S's read in place of the skipped move, and a skipped temporary
  never reaches a host, so its unconsumed count is never consulted. A
  definition qualifies only in the call's basic block (no target, branch,
  call, or safepoint between it and the call) with no intervening write to
  T or S; the temporary is read exactly once (AUseCounts) and is not a
  local or result. The fallback helper path, which marshals from the
  canonical argument slots, writes those slots first. }
procedure X64PlanLeafCallOperands(const AFn: TWasmIrFunction;
  var ACalls: TX64LeafCallList; var ASkip: array of Boolean;
  const APlanned: TWasmIrCode; const ATargets: array of Boolean;
  const AUseCounts: array of UInt32);

implementation

uses
  Wasm.Core;

function IsParamOrResult(const AFn: TWasmIrFunction;
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

function LeafMemoryOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := AOp in [
    iroI32Load, iroI64Load, iroF32Load, iroF64Load,
    iroI32Load8S, iroI32Load8U, iroI32Load16S, iroI32Load16U,
    iroI64Load8S, iroI64Load8U, iroI64Load16S, iroI64Load16U,
    iroI64Load32S, iroI64Load32U,
    iroI32Store, iroI64Store, iroF32Store, iroF64Store,
    iroI32Store8, iroI32Store16, iroI64Store8, iroI64Store16,
    iroI64Store32];
end;

function LeafScalarOp(const AOp: TWasmIrOp): Boolean;
begin
  Result := AOp in [
    iroMove, iroReturn,
    iroI32Const, iroI64Const,
    iroI32Eqz, iroI64Eqz,
    iroI32Eq, iroI32Ne, iroI32LtS, iroI32LtU, iroI32GtS, iroI32GtU,
    iroI32LeS, iroI32LeU, iroI32GeS, iroI32GeU,
    iroI64Eq, iroI64Ne, iroI64LtS, iroI64LtU, iroI64GtS, iroI64GtU,
    iroI64LeS, iroI64LeU, iroI64GeS, iroI64GeU,
    iroI32Add, iroI32Sub, iroI32Mul, iroI32And, iroI32Or, iroI32Xor,
    iroI32Shl, iroI32ShrS, iroI32ShrU, iroI32Rotl, iroI32Rotr,
    iroI64Add, iroI64Sub, iroI64Mul, iroI64And, iroI64Or, iroI64Xor,
    iroI64Shl, iroI64ShrS, iroI64ShrU, iroI64Rotl, iroI64Rotr,
    iroI64ExtendI32S, iroI64ExtendI32U, iroI32WrapI64];
end;

function X64NativeLeafShape(const AFn: TWasmIrFunction;
  out AShape: TX64LeafShape): Boolean;
var
  I: Integer;
  Ins: TWasmIrInstr;
begin
  Result := False;
  AShape.ParamCount := 0;
  AShape.UsesMemory := False;
  AShape.MemoryIndex := 0;
  AShape.HasSelect := False;
  if (AFn.ParamCount < 1) or (AFn.ParamCount > 4) or
    (AFn.ResultCount <> 1) or
    (Length(AFn.LocalRegs) <> Integer(AFn.ParamCount)) or
    (Length(AFn.ResultRegs) <> 1) or
    (Length(AFn.EntryZeroRegs) <> 0) or (Length(AFn.Handlers) <> 0) or
    (AFn.RegisterCount = 0) or (AFn.RegisterCount > 32) then
    Exit;
  for I := 0 to High(AFn.RegTypes) do
    if AFn.RegTypes[I].Kind <> wvkNum then
      Exit;
  for I := 0 to High(AFn.Code) do
  begin
    Ins := AFn.Code[I];
    if Ins.Op = iroSelect then
      AShape.HasSelect := True
    else if LeafMemoryOp(Ins.Op) then
    begin
      { The guard-page form only: a zero static offset through an i32
        address (the memory's address type), the same memory throughout. }
      if (Ins.Imm <> 0) or (Ins.A >= UInt32(Length(AFn.RegTypes))) or
        (AFn.RegTypes[Ins.A].Num <> wntI32) or
        (AShape.UsesMemory and (Ins.B <> AShape.MemoryIndex)) then
        Exit;
      AShape.UsesMemory := True;
      AShape.MemoryIndex := Ins.B;
    end
    else if not LeafScalarOp(Ins.Op) then
      Exit;
  end;
  if AShape.HasSelect and (AFn.ParamCount = 4) then
    Exit;
  AShape.ParamCount := Byte(AFn.ParamCount);
  Result := True;
end;

function X64CanNativeLeaf(const AFn: TWasmIrFunction): Boolean;
var
  Shape: TX64LeafShape;
begin
  Result := X64NativeLeafShape(AFn, Shape);
end;

procedure X64PlanLeafCalls(const AIr: TWasmIrModule;
  const AFn: TWasmIrFunction; out ACalls: TX64LeafCallList);
var
  K, N: Integer;
  Target, Defined: UInt32;
  Shape: TX64LeafShape;
begin
  ACalls := nil;
  SetLength(ACalls, Length(AFn.Code));
  for K := 0 to High(ACalls) do
  begin
    ACalls[K].Enabled := False;
    ACalls[K].ResultSlot := High(UInt32);
    for N := 0 to High(ACalls[K].ArgSlots) do
    begin
      ACalls[K].ArgSlots[N] := High(UInt32);
      ACalls[K].ArgConst[N] := False;
      ACalls[K].ArgValues[N] := 0;
    end;
  end;
  if AIr = nil then
    Exit;
  for K := 0 to High(AFn.Code) do
  begin
    if AFn.Code[K].Op <> iroCall then
      Continue;
    Target := UInt32(AFn.Code[K].Imm);
    if Target < AIr.FuncImportCount then
      Continue;
    Defined := Target - AIr.FuncImportCount;
    if (Defined >= UInt32(Length(AIr.Functions))) or
      not X64NativeLeafShape(AIr.Functions[Defined], Shape) or
      (IrAuxBlockCount(AFn.AuxU32, AFn.Code[K].A) <> Shape.ParamCount) or
      (IrAuxBlockCount(AFn.AuxU32, AFn.Code[K].B) <> 1) then
      Continue;
    ACalls[K].Enabled := True;
    ACalls[K].ParamCount := Shape.ParamCount;
    ACalls[K].UsesMemory := Shape.UsesMemory;
    ACalls[K].MemoryIndex := Shape.MemoryIndex;
    ACalls[K].ClobbersRdi := Shape.ParamCount >= 3;
    ACalls[K].ClobbersRdx := (Shape.ParamCount = 4) or Shape.HasSelect;
  end;
end;

procedure X64RestrictMemoryLeafCalls(var ACalls: TX64LeafCallList;
  const APinned: Boolean; const AIndex: UInt32);
var
  K: Integer;
begin
  for K := 0 to High(ACalls) do
    if ACalls[K].Enabled and ACalls[K].UsesMemory and
      not (APinned and (ACalls[K].MemoryIndex = AIndex)) then
      ACalls[K].Enabled := False;
end;

procedure X64FoldLeafMemory(const ACalls: TX64LeafCallList;
  var AFound, AMultiple: Boolean; var AIndex: UInt32);
var
  K: Integer;
begin
  for K := 0 to High(ACalls) do
    if ACalls[K].Enabled and ACalls[K].UsesMemory then
      if not AFound then
      begin
        AFound := True;
        AIndex := ACalls[K].MemoryIndex;
      end
      else if ACalls[K].MemoryIndex <> AIndex then
        AMultiple := True;
end;

function X64AnyLeafCall(const ACalls: TX64LeafCallList): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(ACalls) do
    if ACalls[K].Enabled then
      Exit(True);
  Result := False;
end;

{ Whether AIns writes AReg: its Dest when the op defines it. Callers apply
  this only to numeric straight-line code, where no other field is
  written. }
function WritesReg(const AIns: TWasmIrInstr; const AReg: UInt32): Boolean;
begin
  Result := (IR_OP_INFO[AIns.Op].DestKind = ifkDestReg) and
    (AIns.Dest = AReg);
end;

{ Rename every register-source operand of AIns equal to AOld to ANew;
  whether any was renamed. }
function RenameSource(var AIns: TWasmIrInstr; const AOld,
  ANew: UInt32): Boolean;
var
  Info: TWasmIrOpInfo;
begin
  Result := False;
  Info := IR_OP_INFO[AIns.Op];
  if (Info.AKind = ifkSrcReg) and (AIns.A = AOld) then
  begin
    AIns.A := ANew;
    Result := True;
  end;
  if (Info.BKind = ifkSrcReg) and (AIns.B = AOld) then
  begin
    AIns.B := ANew;
    Result := True;
  end;
  if (Info.DestKind = ifkSrcReg) and (AIns.Dest = AOld) then
  begin
    AIns.Dest := ANew;
    Result := True;
  end;
  if (Info.ImmKind = ifkSrcReg) and (UInt32(AIns.Imm) = AOld) then
  begin
    AIns.Imm := Int64(ANew);
    Result := True;
  end;
end;

{ Whether AIns reads AReg through a register-source field. }
function ReadsReg(const AIns: TWasmIrInstr; const AReg: UInt32): Boolean;
var
  Probe: TWasmIrInstr;
begin
  Probe := AIns;
  Result := RenameSource(Probe, AReg, AReg);
end;

{ An instruction a forwarded operand may cross: straight-line, not a
  safepoint, no call, and no control transfer. }
function Crossable(const AIns: TWasmIrInstr): Boolean;
begin
  Result := not IrInstrIsSafepoint(AIns) and not (AIns.Op in [iroJump,
    iroBranchIf, iroBranchIfNot, iroBrTable, iroReturn, iroUnreachable,
    iroCall, iroCallIndirect, iroCallRef, iroReturnCall,
    iroReturnCallIndirect, iroReturnCallRef]) and
    (IR_OP_INFO[AIns.Op].DestKind in [ifkDestReg, ifkSrcReg, ifkUnused]);
end;

function AuxHas(const AAux: TWasmIrAuxU32; const ABlock, AReg: UInt32):
  Boolean;
var
  N: Integer;
begin
  for N := 0 to Integer(IrAuxBlockCount(AAux, ABlock)) - 1 do
    if IrAuxBlockItem(AAux, ABlock, UInt32(N)) = AReg then
      Exit(True);
  Result := False;
end;

procedure X64PlanBlockAliases(const AFn: TWasmIrFunction;
  var APlanned: TWasmIrCode; var ASkip: array of Boolean;
  const AUseCounts: array of UInt32; const ATargets: array of Boolean;
  const ACalls: TX64LeafCallList);
var
  K, U: Integer;
  Source, Temp: UInt32;
  Ins: TWasmIrInstr;
begin
  for K := 0 to High(APlanned) - 1 do
  begin
    if ASkip[K] or (APlanned[K].Op <> iroMove) then
      Continue;
    Source := APlanned[K].A;
    Temp := APlanned[K].Dest;
    if (Temp = Source) or IsParamOrResult(AFn, Temp) or
      (Temp >= UInt32(Length(AUseCounts))) or (AUseCounts[Temp] <> 1) then
      Continue;
    for U := K + 1 to High(APlanned) do
    begin
      if ATargets[U] then
        Break;
      if ASkip[U] then
        Continue;
      Ins := APlanned[U];
      if Ins.Op = iroCall then
      begin
        { Cross only a planned leaf call that neither reads the temporary
          nor writes either register. }
        if not ACalls[U].Enabled or AuxHas(AFn.AuxU32, Ins.A, Temp) or
          AuxHas(AFn.AuxU32, Ins.B, Temp) or
          AuxHas(AFn.AuxU32, Ins.B, Source) then
          Break;
        Continue;
      end;
      if ReadsReg(Ins, Temp) then
      begin
        RenameSource(APlanned[U], Temp, Source);
        ASkip[K] := True;
        Break;
      end;
      if WritesReg(Ins, Source) or WritesReg(Ins, Temp) or
        not Crossable(Ins) then
        Break;
    end;
  end;
end;

procedure X64PreferLeafPreservedHosts(const AFn: TWasmIrFunction;
  const ACalls: TX64LeafCallList;
  const AScores, AScoresInLoop: array of UInt32;
  var AAllocated: array of UInt32);
var
  K, P, Count: Integer;
  Target: Int64;
  Preserved: array[0..3] of Boolean;
  Order: array of UInt32;
  Next: array[0..3] of UInt32;
  Slot: UInt32;

  function Beats(const AA, AB: UInt32): Boolean;
  begin
    if AScoresInLoop[AA] <> AScoresInLoop[AB] then
      Result := AScoresInLoop[AA] > AScoresInLoop[AB]
    else if AScores[AA] <> AScores[AB] then
      Result := AScores[AA] > AScores[AB]
    else
      Result := AA < AB;
  end;

  function Listed(const ASlot: UInt32): Boolean;
  var
    N: Integer;
  begin
    for N := 0 to Count - 1 do
      if Order[N] = ASlot then
        Exit(True);
    Result := False;
  end;

  procedure Append(const ASlot: UInt32);
  begin
    if (ASlot = High(UInt32)) or Listed(ASlot) then
      Exit;
    if Count >= Length(Order) then
      SetLength(Order, Count + 8);
    Order[Count] := ASlot;
    Inc(Count);
  end;

  { The best loop local not yet listed, or High(UInt32). }
  function BestLocal: UInt32;
  var
    N: Integer;
    Candidate: UInt32;
  begin
    Result := High(UInt32);
    for N := 0 to High(AFn.LocalRegs) do
    begin
      Candidate := AFn.LocalRegs[N];
      if (Candidate >= UInt32(Length(AScoresInLoop))) or
        (AScoresInLoop[Candidate] = 0) or Listed(Candidate) or
        (AFn.RegTypes[Candidate].Kind <> wvkNum) then
        Continue;
      if (Result = High(UInt32)) or Beats(Candidate, Result) then
        Result := Candidate;
    end;
  end;

begin
  if Length(AAllocated) <> 4 then
    Exit;
  Target := -1;
  Preserved[2] := True;
  Preserved[3] := True;
  for K := 0 to High(ACalls) do
    if ACalls[K].Enabled then
    begin
      if (Target >= 0) and (Target <> Int64(UInt32(AFn.Code[K].Imm))) then
        Exit;
      Target := Int64(UInt32(AFn.Code[K].Imm));
      Preserved[2] := Preserved[2] and not ACalls[K].ClobbersRdi;
      Preserved[3] := Preserved[3] and not ACalls[K].ClobbersRdx;
    end;
  if (Target < 0) or not (Preserved[2] or Preserved[3]) then
    Exit;
  Preserved[0] := False;
  Preserved[1] := False;
  { Preserved hosts first, each taking the best remaining loop local; then
    every previously allocated slot in its order fills the rest. }
  Order := nil;
  Count := 0;
  for P := 2 to 3 do
    if Preserved[P] then
      Append(BestLocal);
  for P := 0 to 3 do
    Append(AAllocated[P]);
  K := 0;
  for P := 2 to 3 do
    if Preserved[P] then
    begin
      if K < Count then
        Next[P] := Order[K]
      else
        Next[P] := High(UInt32);
      Inc(K);
    end;
  for P := 0 to 3 do
    if not Preserved[P] then
    begin
      if K < Count then
        Next[P] := Order[K]
      else
        Next[P] := High(UInt32);
      Inc(K);
    end;
  for P := 0 to 3 do
  begin
    Slot := Next[P];
    AAllocated[P] := Slot;
  end;
end;

procedure X64PlanWrittenSlots(const AFn: TWasmIrFunction;
  out AWritten: TX64BoolArray);

  procedure Mark(const AReg: UInt32);
  begin
    if AReg < UInt32(Length(AWritten)) then
      AWritten[AReg] := True;
  end;

var
  K, N: Integer;
  Ins: TWasmIrInstr;
begin
  AWritten := nil;
  SetLength(AWritten, AFn.RegisterCount);
  for K := 0 to High(AFn.Code) do
  begin
    Ins := AFn.Code[K];
    if IR_OP_INFO[Ins.Op].DestKind = ifkDestReg then
    begin
      Mark(Ins.Dest);
      if (Ins.Dest < UInt32(Length(AFn.RegTypes))) and
        (AFn.RegTypes[Ins.Dest].Kind = wvkVec) then
        Mark(Ins.Dest + 1);
    end;
    if (Ins.Op in [iroCall, iroCallIndirect, iroCallRef]) and
      (IR_OP_INFO[Ins.Op].BKind = ifkAuxIndex) then
      for N := 0 to Integer(IrAuxBlockCount(AFn.AuxU32, Ins.B)) - 1 do
        Mark(IrAuxBlockItem(AFn.AuxU32, Ins.B, UInt32(N)));
  end;
end;

procedure X64PlanLeafCallOperands(const AFn: TWasmIrFunction;
  var ACalls: TX64LeafCallList; var ASkip: array of Boolean;
  const APlanned: TWasmIrCode; const ATargets: array of Boolean;
  const AUseCounts: array of UInt32);

  function SingleUseTemp(const AReg: UInt32): Boolean;
  begin
    Result := (AReg < UInt32(Length(AUseCounts))) and
      (AUseCounts[AReg] = 1) and not IsParamOrResult(AFn, AReg);
  end;

  { The index of Temp's defining instruction in K's block, or -1. }
  function DefinitionOf(const K: Integer; const ATemp: UInt32): Integer;
  var
    J: Integer;
  begin
    Result := -1;
    for J := K - 1 downto 0 do
    begin
      if ATargets[J + 1] then
        Exit;
      if ASkip[J] then
        Continue;
      if WritesReg(APlanned[J], ATemp) then
        Exit(J);
      if not Crossable(APlanned[J]) then
        Exit;
    end;
  end;

  function SourceStable(const AFrom, ATo: Integer;
    const ASource: UInt32): Boolean;
  var
    J: Integer;
  begin
    for J := AFrom to ATo do
      if not ASkip[J] and WritesReg(APlanned[J], ASource) then
        Exit(False);
    Result := True;
  end;

var
  K, N, J: Integer;
  Temp, Source: UInt32;
  Def: TWasmIrInstr;
begin
  for K := 0 to High(APlanned) do
  begin
    if not ACalls[K].Enabled or ASkip[K] then
      Continue;
    for N := 0 to ACalls[K].ParamCount - 1 do
    begin
      Temp := IrAuxBlockItem(AFn.AuxU32, APlanned[K].A, UInt32(N));
      if not SingleUseTemp(Temp) then
        Continue;
      J := DefinitionOf(K, Temp);
      if J < 0 then
        Continue;
      Def := APlanned[J];
      case Def.Op of
        iroI32Const:
          begin
            ACalls[K].ArgConst[N] := True;
            ACalls[K].ArgValues[N] := UInt64(Def.Imm) and $FFFFFFFF;
            ASkip[J] := True;
          end;
        iroI64Const:
          begin
            ACalls[K].ArgConst[N] := True;
            ACalls[K].ArgValues[N] := UInt64(Def.Imm);
            ASkip[J] := True;
          end;
        iroMove:
          begin
            Source := Def.A;
            if (Source <> Temp) and SourceStable(J + 1, K - 1, Source) then
            begin
              ACalls[K].ArgSlots[N] := Source;
              ASkip[J] := True;
            end;
          end;
      end;
    end;
    { The result: copied by the very next instruction and read nowhere
      else. }
    Temp := IrAuxBlockItem(AFn.AuxU32, APlanned[K].B, 0);
    if (K < High(APlanned)) and not ATargets[K + 1] and
      not ASkip[K + 1] and (APlanned[K + 1].Op = iroMove) and
      (APlanned[K + 1].A = Temp) and (APlanned[K + 1].Dest <> Temp) and
      SingleUseTemp(Temp) then
    begin
      ACalls[K].ResultSlot := APlanned[K + 1].Dest;
      ASkip[K + 1] := True;
    end;
  end;
end;

end.
