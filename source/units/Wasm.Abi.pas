{ Wasm.Abi — 64-bit Unix C-ABI call plans for connector signatures.

  This unit lowers a C type signature to a register-and-stack placement plan
  for the released Unix ABIs (ADR-0015): AAPCS64 (Linux AArch64), Apple's
  AAPCS64 variant (Darwin AArch64), or System V AMD64 (x86-64). Planning is
  host-independent — a plan for the other target is a data structure, not a
  call — so one compiler can emit every released target. Applying a plan is
  a later unit (Wasm.Native.Call) and is host-gated.

  Rejected here, not deferred: TinyCC, libffi, and any other compiler that
  would become a second ABI planner. The plan is the planner.

  Sources (checked, not recalled):
    - AAPCS64 2025Q4, ARM-software/abi-aa@daa7a94, Parameter passing
      Stage A–C and Result return
      (https://github.com/ARM-software/abi-aa/blob/daa7a94ca55973736c0e434a67a6e4bbcd35d7fa/aapcs64/aapcs64.rst)
    - Apple "Writing ARM64 code for Apple platforms": stack slots need
      not be multiples of 8; 16-byte integer arguments may start at an
      odd xN
      (https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms)
    - System V AMD64 ABI 1.0 (2021-09-28 / GitLab x86-64-ABI), §3.2.3
      Classification, Passing, Returning of Values
      (https://gitlab.com/x86-psABIs/x86-64-ABI)

  Layering: depends on Wasm.Core alone. No engine, no tier, no library load.
  An incompatible plan is data (Compatible=False); raising EWasmLinkError
  belongs to the caller that treats the plan as a link step. }
unit Wasm.Abi;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  MSG_LINK_INCOMPATIBLE_PLAN = 'incompatible call plan';

type
  { Released Unix C-ABI targets. wabAapcs64 is the generic AAPCS64
    (Linux). wabAapcs64Apple packs stack arguments at natural alignment
    and does not skip to an even xN for 16-byte types. wabNone is a host
    with no Unix C-ABI gate (Windows, 32-bit): planning it fails closed. }
  TWasmAbiTarget = (
    wabNone,
    wabAapcs64,
    wabAapcs64Apple,
    wabSysvX64
  );

  TWasmCScalar = (
    wcsVoid,
    wcsI8,
    wcsU8,
    wcsI16,
    wcsU16,
    wcsI32,
    wcsU32,
    wcsI64,
    wcsU64,
    wcsF32,
    wcsF64
  );

  TWasmCTypeKind = (
    wckScalar,
    wckPointer,
    wckAggregate,
    wckArray
  );

  { A C type in the connector vocabulary: scalars, an opaque or typed
    pointer-view, a C struct, or a C array. No bitfields, unions, or
    long double — those make the plan incompatible rather than guessed. }
  PWasmCType = ^TWasmCType;
  TWasmCType = record
    Kind: TWasmCTypeKind;
    Scalar: TWasmCScalar;
    Fields: array of TWasmCType;
    Count: UInt32;
  end;

  TWasmCSignature = record
    Params: array of TWasmCType;
    ResultType: TWasmCType;
  end;

  TWasmCLayout = record
    Size: UInt32;
    Align: UInt32;
  end;

  TWasmAbiPlaceKind = (
    wapNone,
    wapIntReg,
    wapFloatReg,
    wapStack,
    wapIndirect,
    wapHiddenReturn
  );

  { One machine placement of a (possibly multi-register) argument or
    result. Offset is the outgoing-stack byte offset for wapStack, or the
    byte offset inside the value for a multi-piece aggregate. }
  TWasmAbiPiece = record
    Kind: TWasmAbiPlaceKind;
    Reg: Byte;
    Offset: UInt32;
    Size: UInt32;
  end;

  TWasmAbiArgPlan = record
    Pieces: array of TWasmAbiPiece;
    Size: UInt32;
    Align: UInt32;
  end;

  TWasmAbiPlan = record
    Target: TWasmAbiTarget;
    Compatible: Boolean;
    Reason: string;
    Args: array of TWasmAbiArgPlan;
    Result: TWasmAbiArgPlan;
    StackSize: UInt32;
    HiddenReturn: Boolean;
  end;

function AbiVoid: TWasmCType;
function AbiI8: TWasmCType;
function AbiU8: TWasmCType;
function AbiI16: TWasmCType;
function AbiU16: TWasmCType;
function AbiI32: TWasmCType;
function AbiU32: TWasmCType;
function AbiI64: TWasmCType;
function AbiU64: TWasmCType;
function AbiF32: TWasmCType;
function AbiF64: TWasmCType;
function AbiPointer: TWasmCType;
function AbiPointerTo(const APointee: TWasmCType): TWasmCType;
function AbiStruct(const AFields: array of TWasmCType): TWasmCType;
function AbiArrayOf(const AElement: TWasmCType; const ACount: UInt32): TWasmCType;
function AbiSignature(const AParams: array of TWasmCType;
  const AResult: TWasmCType): TWasmCSignature;

function AbiLayout(const AType: TWasmCType): TWasmCLayout;
function AbiHostTarget: TWasmAbiTarget;
function PlanCall(const ATarget: TWasmAbiTarget;
  const ASignature: TWasmCSignature): TWasmAbiPlan;

implementation

type
  TLeafList = record
    Kinds: array of TWasmCScalar;
    Count: Integer;
  end;

  TSysvClass = (
    svcNoClass,
    svcInteger,
    svcSse,
    svcSseUp,
    svcMemory
  );

  TSysvClasses = array of TSysvClass;

function AlignUpU32(const AValue, AAlign: UInt32): UInt32;
begin
  if AAlign <= 1 then
  begin
    Result := AValue;
    Exit;
  end;
  Result := (AValue + AAlign - 1) and not (AAlign - 1);
end;

function ScalarType(const AScalar: TWasmCScalar): TWasmCType;
begin
  Result.Kind := wckScalar;
  Result.Scalar := AScalar;
  Result.Fields := nil;
  Result.Count := 0;
end;

function AbiVoid: TWasmCType;
begin
  Result := ScalarType(wcsVoid);
end;

function AbiI8: TWasmCType;
begin
  Result := ScalarType(wcsI8);
end;

function AbiU8: TWasmCType;
begin
  Result := ScalarType(wcsU8);
end;

function AbiI16: TWasmCType;
begin
  Result := ScalarType(wcsI16);
end;

function AbiU16: TWasmCType;
begin
  Result := ScalarType(wcsU16);
end;

function AbiI32: TWasmCType;
begin
  Result := ScalarType(wcsI32);
end;

function AbiU32: TWasmCType;
begin
  Result := ScalarType(wcsU32);
end;

function AbiI64: TWasmCType;
begin
  Result := ScalarType(wcsI64);
end;

function AbiU64: TWasmCType;
begin
  Result := ScalarType(wcsU64);
end;

function AbiF32: TWasmCType;
begin
  Result := ScalarType(wcsF32);
end;

function AbiF64: TWasmCType;
begin
  Result := ScalarType(wcsF64);
end;

function AbiPointer: TWasmCType;
begin
  Result.Kind := wckPointer;
  Result.Scalar := wcsVoid;
  Result.Fields := nil;
  Result.Count := 0;
end;

function AbiPointerTo(const APointee: TWasmCType): TWasmCType;
begin
  Result.Kind := wckPointer;
  Result.Scalar := wcsVoid;
  SetLength(Result.Fields, 1);
  Result.Fields[0] := APointee;
  Result.Count := 0;
end;

function AbiStruct(const AFields: array of TWasmCType): TWasmCType;
var
  I: Integer;
begin
  Result.Kind := wckAggregate;
  Result.Scalar := wcsVoid;
  SetLength(Result.Fields, Length(AFields));
  for I := 0 to High(AFields) do
    Result.Fields[I] := AFields[I];
  Result.Count := 0;
end;

function AbiArrayOf(const AElement: TWasmCType; const ACount: UInt32): TWasmCType;
begin
  Result.Kind := wckArray;
  Result.Scalar := wcsVoid;
  SetLength(Result.Fields, 1);
  Result.Fields[0] := AElement;
  Result.Count := ACount;
end;

function AbiSignature(const AParams: array of TWasmCType;
  const AResult: TWasmCType): TWasmCSignature;
var
  I: Integer;
begin
  Result.Params := nil;
  SetLength(Result.Params, Length(AParams));
  for I := 0 to High(AParams) do
    Result.Params[I] := AParams[I];
  Result.ResultType := AResult;
end;

function ScalarSize(const AScalar: TWasmCScalar): UInt32;
begin
  case AScalar of
    wcsVoid:
      Result := 0;
    wcsI8, wcsU8:
      Result := 1;
    wcsI16, wcsU16:
      Result := 2;
    wcsI32, wcsU32, wcsF32:
      Result := 4;
  else
    Result := 8;
  end;
end;

function IsFloatScalar(const AScalar: TWasmCScalar): Boolean;
begin
  Result := (AScalar = wcsF32) or (AScalar = wcsF64);
end;

function IsVoidType(const AType: TWasmCType): Boolean;
begin
  Result := (AType.Kind = wckScalar) and (AType.Scalar = wcsVoid);
end;

function AbiLayout(const AType: TWasmCType): TWasmCLayout;
var
  I: Integer;
  Field: TWasmCLayout;
  Offset: UInt32;
begin
  Result.Size := 0;
  Result.Align := 1;
  case AType.Kind of
    wckScalar:
      begin
        Result.Size := ScalarSize(AType.Scalar);
        if Result.Size = 0 then
          Result.Align := 1
        else
          Result.Align := Result.Size;
      end;
    wckPointer:
      begin
        Result.Size := 8;
        Result.Align := 8;
      end;
    wckArray:
      begin
        if (AType.Count = 0) or (Length(AType.Fields) <> 1) then
          Exit;
        Field := AbiLayout(AType.Fields[0]);
        Result.Align := Field.Align;
        Result.Size := Field.Size * AType.Count;
      end;
    wckAggregate:
      begin
        Offset := 0;
        Result.Align := 1;
        for I := 0 to High(AType.Fields) do
        begin
          Field := AbiLayout(AType.Fields[I]);
          if Field.Align > Result.Align then
            Result.Align := Field.Align;
          Offset := AlignUpU32(Offset, Field.Align);
          Inc(Offset, Field.Size);
        end;
        Result.Size := AlignUpU32(Offset, Result.Align);
      end;
  end;
end;

function AbiHostTarget: TWasmAbiTarget;
begin
  {$IF DEFINED(UNIX) AND DEFINED(CPUAARCH64) AND DEFINED(DARWIN)}
  Result := wabAapcs64Apple;
  {$ELSEIF DEFINED(UNIX) AND DEFINED(CPUAARCH64)}
  Result := wabAapcs64;
  {$ELSEIF DEFINED(UNIX) AND DEFINED(CPUX86_64)}
  Result := wabSysvX64;
  {$ELSE}
  Result := wabNone;
  {$ENDIF}
end;

function EmptyArg(const ALayout: TWasmCLayout): TWasmAbiArgPlan;
begin
  Result.Pieces := nil;
  Result.Size := ALayout.Size;
  Result.Align := ALayout.Align;
end;

procedure AddPiece(var AArg: TWasmAbiArgPlan; const AKind: TWasmAbiPlaceKind;
  const AReg: Byte; const AOffset, ASize: UInt32);
var
  N: Integer;
begin
  N := Length(AArg.Pieces);
  SetLength(AArg.Pieces, N + 1);
  AArg.Pieces[N].Kind := AKind;
  AArg.Pieces[N].Reg := AReg;
  AArg.Pieces[N].Offset := AOffset;
  AArg.Pieces[N].Size := ASize;
end;

procedure FailPlan(var APlan: TWasmAbiPlan; const AWhy: string);
begin
  APlan.Compatible := False;
  APlan.Reason := AWhy;
end;

procedure CollectLeaves(const AType: TWasmCType; var ALeaves: TLeafList);
var
  I: Integer;
  J: Integer;
begin
  case AType.Kind of
    wckScalar:
      begin
        if AType.Scalar = wcsVoid then
          Exit;
        I := ALeaves.Count;
        Inc(ALeaves.Count);
        if Length(ALeaves.Kinds) < ALeaves.Count then
          SetLength(ALeaves.Kinds, ALeaves.Count);
        ALeaves.Kinds[I] := AType.Scalar;
      end;
    wckPointer:
      begin
        I := ALeaves.Count;
        Inc(ALeaves.Count);
        if Length(ALeaves.Kinds) < ALeaves.Count then
          SetLength(ALeaves.Kinds, ALeaves.Count);
        ALeaves.Kinds[I] := wcsU64;
      end;
    wckArray:
      if (Length(AType.Fields) = 1) and (AType.Count > 0) then
        for J := 1 to Integer(AType.Count) do
          CollectLeaves(AType.Fields[0], ALeaves);
    wckAggregate:
      for I := 0 to High(AType.Fields) do
        CollectLeaves(AType.Fields[I], ALeaves);
  end;
end;

function IsHfa(const AType: TWasmCType; out ALeaf: TWasmCScalar;
  out ACount: Integer): Boolean;
var
  Leaves: TLeafList;
  I: Integer;
begin
  Result := False;
  ACount := 0;
  ALeaf := wcsVoid;
  if (AType.Kind <> wckAggregate) and (AType.Kind <> wckArray) then
    Exit;
  Leaves.Kinds := nil;
  Leaves.Count := 0;
  CollectLeaves(AType, Leaves);
  if (Leaves.Count < 1) or (Leaves.Count > 4) then
    Exit;
  if not IsFloatScalar(Leaves.Kinds[0]) then
    Exit;
  for I := 1 to Leaves.Count - 1 do
    if Leaves.Kinds[I] <> Leaves.Kinds[0] then
      Exit;
  ALeaf := Leaves.Kinds[0];
  ACount := Leaves.Count;
  Result := True;
end;

procedure PlanAapcs64(var APlan: TWasmAbiPlan; const ASignature: TWasmCSignature;
  const AApple: Boolean);

  function StackSlotAlign(const ANatural: UInt32): UInt32;
  begin
    if ANatural = 0 then
      Result := 1
    else
      Result := ANatural;
    if not AApple then
    begin
      if Result < 8 then
        Result := 8;
    end
    else if Result > 16 then
      Result := 16;
  end;

  procedure PlaceOnStack(var AArg: TWasmAbiArgPlan; var ANSAA: UInt32;
    const ASize, AAlign: UInt32);
  var
    Slot: UInt32;
  begin
    ANSAA := AlignUpU32(ANSAA, StackSlotAlign(AAlign));
    if AApple then
      Slot := ASize
    else if ASize < 8 then
      Slot := 8
    else
      Slot := ASize;
    if Slot = 0 then
      Slot := 8;
    AddPiece(AArg, wapStack, 0, ANSAA, Slot);
    Inc(ANSAA, Slot);
  end;

  procedure MaybeEvenNgrn(var ANGRN: Integer; const AAlign: UInt32);
  begin
    { C.10: 16-byte alignment starts at an even xN. Apple drops this. }
    if (not AApple) and (AAlign >= 16) and ((ANGRN and 1) <> 0) then
      Inc(ANGRN);
  end;

  procedure AssignOne(const AType: TWasmCType; var AArg: TWasmAbiArgPlan;
    var ANGRN, ANSRN: Integer; var ANSAA: UInt32; const AForReturn: Boolean);
  var
    Layout: TWasmCLayout;
    HfaLeaf: TWasmCScalar;
    HfaCount: Integer;
    Words: Integer;
    I: Integer;
    CopySize: UInt32;
    IsHfaType: Boolean;
    UseIndirect: Boolean;
  begin
    Layout := AbiLayout(AType);
    AArg := EmptyArg(Layout);
    if IsVoidType(AType) then
      Exit;

    IsHfaType := IsHfa(AType, HfaLeaf, HfaCount);
    UseIndirect := (AType.Kind in [wckAggregate, wckArray]) and
      (not IsHfaType) and (Layout.Size > 16);

    { Result return: a B.4 pointer replacement is not "the value in
      registers", so a large aggregate returns via x8. }
    if AForReturn and UseIndirect then
    begin
      AddPiece(AArg, wapHiddenReturn, 8, 0, Layout.Size);
      APlan.HiddenReturn := True;
      Exit;
    end;

    if UseIndirect then
    begin
      if ANGRN < 8 then
      begin
        AddPiece(AArg, wapIndirect, Byte(ANGRN), 0, Layout.Size);
        Inc(ANGRN);
      end
      else
      begin
        ANSAA := AlignUpU32(ANSAA, 8);
        AddPiece(AArg, wapIndirect, $FF, ANSAA, Layout.Size);
        Inc(ANSAA, 8);
      end;
      Exit;
    end;

    if (AType.Kind = wckScalar) and IsFloatScalar(AType.Scalar) then
    begin
      if ANSRN < 8 then
      begin
        AddPiece(AArg, wapFloatReg, Byte(ANSRN), 0, Layout.Size);
        Inc(ANSRN);
      end
      else
        PlaceOnStack(AArg, ANSAA, Layout.Size, Layout.Align);
      Exit;
    end;

    if IsHfaType then
    begin
      if ANSRN + HfaCount <= 8 then
      begin
        for I := 0 to HfaCount - 1 do
          AddPiece(AArg, wapFloatReg, Byte(ANSRN + I),
            UInt32(I) * ScalarSize(HfaLeaf), ScalarSize(HfaLeaf));
        Inc(ANSRN, HfaCount);
      end
      else
      begin
        ANSRN := 8;
        PlaceOnStack(AArg, ANSAA, Layout.Size, Layout.Align);
      end;
      Exit;
    end;

    if (AType.Kind = wckScalar) or (AType.Kind = wckPointer) then
    begin
      MaybeEvenNgrn(ANGRN, Layout.Align);
      if ANGRN < 8 then
      begin
        AddPiece(AArg, wapIntReg, Byte(ANGRN), 0, Layout.Size);
        Inc(ANGRN);
      end
      else
        PlaceOnStack(AArg, ANSAA, Layout.Size, Layout.Align);
      Exit;
    end;

    { Small composite, B.5: size rounded up to 8. C.10 then C.12 or stack. }
    CopySize := AlignUpU32(Layout.Size, 8);
    Words := Integer(CopySize div 8);
    MaybeEvenNgrn(ANGRN, Layout.Align);
    if Words <= 8 - ANGRN then
    begin
      for I := 0 to Words - 1 do
        AddPiece(AArg, wapIntReg, Byte(ANGRN + I), UInt32(I) * 8, 8);
      Inc(ANGRN, Words);
    end
    else
    begin
      ANGRN := 8;
      PlaceOnStack(AArg, ANSAA, Layout.Size, Layout.Align);
    end;
  end;

var
  NGRN: Integer;
  NSRN: Integer;
  NSAA: UInt32;
  I: Integer;
  ResultNGRN: Integer;
  ResultNSRN: Integer;
  ResultNSAA: UInt32;
begin
  NGRN := 0;
  NSRN := 0;
  NSAA := 0;
  SetLength(APlan.Args, Length(ASignature.Params));
  for I := 0 to High(ASignature.Params) do
    AssignOne(ASignature.Params[I], APlan.Args[I], NGRN, NSRN, NSAA, False);

  ResultNGRN := 0;
  ResultNSRN := 0;
  ResultNSAA := 0;
  AssignOne(ASignature.ResultType, APlan.Result, ResultNGRN, ResultNSRN,
    ResultNSAA, True);

  { A return that spilled to the stack is not "in registers": x8. }
  if (not APlan.HiddenReturn) and (Length(APlan.Result.Pieces) > 0) then
    for I := 0 to High(APlan.Result.Pieces) do
      if APlan.Result.Pieces[I].Kind = wapStack then
      begin
        APlan.Result.Pieces := nil;
        AddPiece(APlan.Result, wapHiddenReturn, 8, 0, APlan.Result.Size);
        APlan.HiddenReturn := True;
        Break;
      end;

  APlan.StackSize := AlignUpU32(NSAA, 16);
end;

function MergeSysv(const A, B: TSysvClass): TSysvClass;
begin
  if A = B then
    Result := A
  else if A = svcNoClass then
    Result := B
  else if B = svcNoClass then
    Result := A
  else if (A = svcMemory) or (B = svcMemory) then
    Result := svcMemory
  else if (A = svcInteger) or (B = svcInteger) then
    Result := svcInteger
  else
    Result := svcSse;
end;

function FieldSysvClass(const AType: TWasmCType): TSysvClass;
begin
  case AType.Kind of
    wckPointer:
      Result := svcInteger;
    wckScalar:
      if IsFloatScalar(AType.Scalar) then
        Result := svcSse
      else if AType.Scalar = wcsVoid then
        Result := svcNoClass
      else
        Result := svcInteger;
  else
    Result := svcNoClass;
  end;
end;

procedure ClassifyEightbytes(const AType: TWasmCType; const ABase: UInt32;
  var AClasses: TSysvClasses);

  procedure Paint(const AOffset, ASize: UInt32; const AClass: TSysvClass);
  var
    First: Integer;
    Last: Integer;
    I: Integer;
  begin
    if ASize = 0 then
      Exit;
    First := Integer(AOffset div 8);
    Last := Integer((AOffset + ASize - 1) div 8);
    for I := First to Last do
      if (I >= 0) and (I <= High(AClasses)) then
        AClasses[I] := MergeSysv(AClasses[I], AClass);
  end;

  procedure Walk(const AInner: TWasmCType; const AOffset: UInt32);
  var
    I: Integer;
    Field: TWasmCLayout;
    Next: UInt32;
    J: Integer;
  begin
    case AInner.Kind of
      wckScalar, wckPointer:
        Paint(AOffset, AbiLayout(AInner).Size, FieldSysvClass(AInner));
      wckArray:
        if (Length(AInner.Fields) = 1) and (AInner.Count > 0) then
        begin
          Field := AbiLayout(AInner.Fields[0]);
          for J := 0 to Integer(AInner.Count) - 1 do
            Walk(AInner.Fields[0], AOffset + UInt32(J) * Field.Size);
        end;
      wckAggregate:
        begin
          Next := AOffset;
          for I := 0 to High(AInner.Fields) do
          begin
            Field := AbiLayout(AInner.Fields[I]);
            Next := AlignUpU32(Next - AOffset, Field.Align) + AOffset;
            Walk(AInner.Fields[I], Next);
            Inc(Next, Field.Size);
          end;
        end;
    end;
  end;

var
  I: Integer;
begin
  for I := 0 to High(AClasses) do
    AClasses[I] := svcNoClass;
  Walk(AType, ABase);
end;

function PostMergeSysv(var AClasses: TSysvClasses; const ASize: UInt32): Boolean;
var
  I: Integer;
  Words: Integer;
begin
  Result := True;
  Words := Length(AClasses);
  for I := 0 to Words - 1 do
    if AClasses[I] = svcMemory then
    begin
      Result := False;
      Exit;
    end;
  { No __m256/__m512 in this vocabulary: > two eightbytes that are not a
    pure SSE/SSEUP vector are MEMORY. }
  if ASize > 16 then
  begin
    if (Words = 0) or (AClasses[0] <> svcSse) then
    begin
      Result := False;
      Exit;
    end;
    for I := 1 to Words - 1 do
      if AClasses[I] <> svcSseUp then
      begin
        Result := False;
        Exit;
      end;
  end;
end;

procedure PlanSysvX64(var APlan: TWasmAbiPlan; const ASignature: TWasmCSignature);
var
  NGRN: Integer;
  NSRN: Integer;
  NSAA: UInt32;

  function AssignClasses(const AClasses: TSysvClasses; const ALayout: TWasmCLayout;
    var AArg: TWasmAbiArgPlan): Boolean;
  var
    SavedNGRN: Integer;
    SavedNSRN: Integer;
    I: Integer;
    NeedInt: Integer;
    NeedSse: Integer;
  begin
    SavedNGRN := NGRN;
    SavedNSRN := NSRN;
    NeedInt := 0;
    NeedSse := 0;
    for I := 0 to High(AClasses) do
      case AClasses[I] of
        svcInteger:
          Inc(NeedInt);
        svcSse:
          Inc(NeedSse);
        svcSseUp:
          ;
      else
        ;
      end;
    if (NGRN + NeedInt > 6) or (NSRN + NeedSse > 8) then
    begin
      NGRN := SavedNGRN;
      NSRN := SavedNSRN;
      Result := False;
      Exit;
    end;
    for I := 0 to High(AClasses) do
      case AClasses[I] of
        svcInteger:
          begin
            AddPiece(AArg, wapIntReg, Byte(NGRN), UInt32(I) * 8, 8);
            Inc(NGRN);
          end;
        svcSse:
          begin
            AddPiece(AArg, wapFloatReg, Byte(NSRN), UInt32(I) * 8, 8);
            Inc(NSRN);
          end;
        svcSseUp:
          if Length(AArg.Pieces) > 0 then
            Inc(AArg.Pieces[High(AArg.Pieces)].Size, 8);
      else
        ;
      end;
    if ALayout.Size > 0 then
    begin
      if (Length(AArg.Pieces) = 1) and (AArg.Pieces[0].Size > ALayout.Size) then
        AArg.Pieces[0].Size := ALayout.Size
      else if (Length(AArg.Pieces) > 0) then
      begin
        I := High(AArg.Pieces);
        if AArg.Pieces[I].Offset + AArg.Pieces[I].Size > ALayout.Size then
          AArg.Pieces[I].Size := ALayout.Size - AArg.Pieces[I].Offset;
      end;
    end;
    Result := True;
  end;

  procedure StackArg(const ALayout: TWasmCLayout; var AArg: TWasmAbiArgPlan);
  var
    Slot: UInt32;
  begin
    Slot := AlignUpU32(ALayout.Size, 8);
    if Slot = 0 then
      Slot := 8;
    NSAA := AlignUpU32(NSAA, AlignUpU32(8, ALayout.Align));
    AddPiece(AArg, wapStack, 0, NSAA, Slot);
    Inc(NSAA, Slot);
  end;

  procedure AssignArg(const AType: TWasmCType; var AArg: TWasmAbiArgPlan);
  var
    Layout: TWasmCLayout;
    Words: Integer;
    Classes: TSysvClasses;
  begin
    Layout := AbiLayout(AType);
    AArg := EmptyArg(Layout);
    if IsVoidType(AType) then
      Exit;
    if (AType.Kind = wckScalar) or (AType.Kind = wckPointer) then
    begin
      if (AType.Kind = wckScalar) and IsFloatScalar(AType.Scalar) then
      begin
        if NSRN < 8 then
        begin
          AddPiece(AArg, wapFloatReg, Byte(NSRN), 0, Layout.Size);
          Inc(NSRN);
        end
        else
          StackArg(Layout, AArg);
      end
      else if NGRN < 6 then
      begin
        AddPiece(AArg, wapIntReg, Byte(NGRN), 0, Layout.Size);
        Inc(NGRN);
      end
      else
        StackArg(Layout, AArg);
      Exit;
    end;

    if (Layout.Size = 0) or (Layout.Size > 64) then
    begin
      StackArg(Layout, AArg);
      if Layout.Size > 64 then
        AArg.Pieces[High(AArg.Pieces)].Kind := wapStack;
      Exit;
    end;

    Words := Integer(AlignUpU32(Layout.Size, 8) div 8);
    SetLength(Classes, Words);
    ClassifyEightbytes(AType, 0, Classes);
    if not PostMergeSysv(Classes, Layout.Size) then
    begin
      StackArg(Layout, AArg);
      Exit;
    end;
    if not AssignClasses(Classes, Layout, AArg) then
      StackArg(Layout, AArg);
  end;

  function ResultIsMemory(const AType: TWasmCType): Boolean;
  var
    Layout: TWasmCLayout;
    Words: Integer;
    Classes: TSysvClasses;
  begin
    Result := False;
    if IsVoidType(AType) then
      Exit;
    if (AType.Kind = wckScalar) or (AType.Kind = wckPointer) then
      Exit;
    Layout := AbiLayout(AType);
    if (Layout.Size = 0) or (Layout.Size > 16) then
    begin
      Result := True;
      Exit;
    end;
    Words := Integer(AlignUpU32(Layout.Size, 8) div 8);
    SetLength(Classes, Words);
    ClassifyEightbytes(AType, 0, Classes);
    Result := not PostMergeSysv(Classes, Layout.Size);
  end;

var
  I: Integer;
  SavedNGRN: Integer;
  SavedNSRN: Integer;
  SavedNSAA: UInt32;
  Dummy: TWasmAbiArgPlan;
begin
  NGRN := 0;
  NSRN := 0;
  NSAA := 0;
  APlan.HiddenReturn := ResultIsMemory(ASignature.ResultType);
  if APlan.HiddenReturn then
  begin
    APlan.Result := EmptyArg(AbiLayout(ASignature.ResultType));
    AddPiece(APlan.Result, wapHiddenReturn, 0, 0, APlan.Result.Size);
    Inc(NGRN); { hidden pointer occupies %rdi }
  end;

  SetLength(APlan.Args, Length(ASignature.Params));
  for I := 0 to High(ASignature.Params) do
    AssignArg(ASignature.Params[I], APlan.Args[I]);

  if not APlan.HiddenReturn then
  begin
    SavedNGRN := NGRN;
    SavedNSRN := NSRN;
    SavedNSAA := NSAA;
    NGRN := 0;
    NSRN := 0;
    NSAA := 0;
    AssignArg(ASignature.ResultType, Dummy);
    APlan.Result := Dummy;
    { Returns use rax/rdx and xmm0/xmm1, not the argument register
      sequence. Rewrite integer pieces onto rax=0, rdx=1. Float pieces
      already start at xmm0 because NSRN was reset. }
    for I := 0 to High(APlan.Result.Pieces) do
      if APlan.Result.Pieces[I].Kind = wapIntReg then
        APlan.Result.Pieces[I].Reg := Byte(I);
    NGRN := SavedNGRN;
    NSRN := SavedNSRN;
    NSAA := SavedNSAA;
  end;

  APlan.StackSize := AlignUpU32(NSAA, 16);
end;

function PlanCall(const ATarget: TWasmAbiTarget;
  const ASignature: TWasmCSignature): TWasmAbiPlan;
begin
  Result.Target := ATarget;
  Result.Compatible := True;
  Result.Reason := '';
  Result.Args := nil;
  Result.Result.Pieces := nil;
  Result.Result.Size := 0;
  Result.Result.Align := 1;
  Result.StackSize := 0;
  Result.HiddenReturn := False;

  case ATarget of
    wabAapcs64:
      PlanAapcs64(Result, ASignature, False);
    wabAapcs64Apple:
      PlanAapcs64(Result, ASignature, True);
    wabSysvX64:
      PlanSysvX64(Result, ASignature);
  else
    FailPlan(Result, string(MSG_LINK_INCOMPATIBLE_PLAN) + ': unsupported ABI');
  end;
end;

end.
