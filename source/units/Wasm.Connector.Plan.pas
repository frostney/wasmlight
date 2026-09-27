{ Wasm.Connector.Plan — the versioned, deterministic byte form of a resolved
  connector plan (ADR-0015), carried in the native-executable payload's
  connector-plan section (WNEP_SECTION_CONNECTOR_PLAN).

  PURE FORMAT plus one consistency check. EncodeConnectorPlan writes the
  semantic content of a TWlcConnectorPlan; DecodeConnectorPlan is strict — a
  bad magic or version, a truncated or oversized count, an out-of-range
  enum ordinal, a non-canonical boolean, SizeConst, or SizeParamIndex, a
  non-numeric wasm value type, or a trailing byte rejects the whole section. There is no
  partial plan. Source positions (Line / Column) are not carried: they are
  diagnostics for `.wlc` text, not binding semantics, and leaving them out
  keeps the section independent of source formatting.

  CheckConnectorPlanForModule is the startup re-validation: it re-resolves
  the plan's own (already stripped) connectors against the embedded
  module's imports and requires the re-encoded result to equal the section
  byte for byte. A plan edited to bind a different symbol, library, or
  signature than resolution produces is rejected before any library loads.
  This does not load a library or emit machine code.

  WHY FIXED-WIDTH LE, like Wasm.Native.Payload: the section is an internal
  container, so every count and length is checked against the remaining
  bytes before anything is allocated.

  An empty section is the empty plan; `wasmlight compile` writes an empty
  section when no connector import is bound, so a WASI-only executable is
  byte-identical to one built before connectors were embedded. }
unit Wasm.Connector.Plan;

{$I Shared.inc}

interface

uses
  Wasm.Connector,
  Wasm.Connector.Resolve,
  Wasm.Core,
  Wasm.Module;

const
  { 'WLCP' — Wasmlight Connector Plan. }
  WLCP_MAGIC0 = Byte($57);   { 'W' }
  WLCP_MAGIC1 = Byte($4C);   { 'L' }
  WLCP_MAGIC2 = Byte($43);   { 'C' }
  WLCP_MAGIC3 = Byte($50);   { 'P' }

  { Bumped only for a layout change an older reader must reject. }
  WLCP_FORMAT_VERSION = UInt16(1);

  MSG_WLCP_MALFORMED = 'malformed connector plan';

type
  TWlcPlanDecodeResult = (
    wpdOk,
    wpdBadMagic,
    wpdUnsupportedVersion,
    wpdTruncated,
    wpdBadValue,
    wpdTrailingBytes
  );

{ Serialize APlan. Deterministic: the same plan always yields the same
  bytes. An empty plan (no thunks) is the empty byte array. }
function EncodeConnectorPlan(const APlan: TWlcConnectorPlan): TWasmBytes;

{ Strictly parse ABytes. The empty array is the empty plan. On any result
  other than wpdOk, APlan is empty. }
function DecodeConnectorPlan(const ABytes: TWasmBytes;
  out APlan: TWlcConnectorPlan): TWlcPlanDecodeResult;

function ConnectorPlanDecodeText(const AResult: TWlcPlanDecodeResult): string;

{ Decode ABytes and re-resolve it against AModule's imports, with
  ABuiltInModules skipped exactly as `wasmlight compile` skipped them.
  Raises EWasmLinkError with MSG_WLCP_MALFORMED when the section is not a
  well-formed plan or is not the plan resolution produces for this module.
  Returns the decoded plan. }
function CheckConnectorPlanForModule(const ABytes: TWasmBytes;
  const AModule: TWasmModule;
  const ABuiltInModules: array of string): TWlcConnectorPlan;

implementation

uses
  SysUtils;

{ --- writer --------------------------------------------------------------- }

type
  TPlanWriter = record
    Buf: TWasmBytes;
    Len: Integer;
  end;

procedure WEnsure(var AW: TPlanWriter; const AExtra: Integer);
var
  Cap: Integer;
begin
  if AW.Len + AExtra <= Length(AW.Buf) then
    Exit;
  Cap := Length(AW.Buf);
  if Cap = 0 then
    Cap := 64;
  while Cap < AW.Len + AExtra do
    Cap := Cap * 2;
  SetLength(AW.Buf, Cap);
end;

procedure WU8(var AW: TPlanWriter; const AValue: Byte);
begin
  WEnsure(AW, 1);
  AW.Buf[AW.Len] := AValue;
  Inc(AW.Len);
end;

procedure WU16(var AW: TPlanWriter; const AValue: UInt16);
begin
  WU8(AW, Byte(AValue));
  WU8(AW, Byte(AValue shr 8));
end;

procedure WU32(var AW: TPlanWriter; const AValue: UInt32);
begin
  WU16(AW, UInt16(AValue));
  WU16(AW, UInt16(AValue shr 16));
end;

procedure WU64(var AW: TPlanWriter; const AValue: UInt64);
begin
  WU32(AW, UInt32(AValue));
  WU32(AW, UInt32(AValue shr 32));
end;

procedure WBool(var AW: TPlanWriter; const AValue: Boolean);
begin
  if AValue then
    WU8(AW, 1)
  else
    WU8(AW, 0);
end;

procedure WStr(var AW: TPlanWriter; const AValue: string);
var
  I: Integer;
begin
  WU32(AW, UInt32(Length(AValue)));
  WEnsure(AW, Length(AValue));
  for I := 1 to Length(AValue) do
  begin
    AW.Buf[AW.Len] := Byte(AValue[I]);
    Inc(AW.Len);
  end;
end;

procedure WTypeRef(var AW: TPlanWriter; const ARef: TWlcTypeRef);
begin
  WStr(AW, ARef.Name);
  WBool(AW, ARef.IsArray);
end;

procedure WMarshal(var AW: TPlanWriter; const AMarshal: TWlcMarshal);
begin
  WU8(AW, Ord(AMarshal.Kind));
  WBool(AW, AMarshal.HasSizeConst);
  if AMarshal.HasSizeConst then
    WU32(AW, UInt32(AMarshal.SizeConst))
  else
    WU32(AW, 0);
  WBool(AW, AMarshal.HasSizeParamIndex);
  if AMarshal.HasSizeParamIndex then
    WU32(AW, UInt32(AMarshal.SizeParamIndex))
  else
    WU32(AW, 0);
end;

procedure WParams(var AW: TPlanWriter; const AParams: array of TWlcParam);
var
  I: Integer;
begin
  WU32(AW, UInt32(Length(AParams)));
  for I := 0 to High(AParams) do
  begin
    WStr(AW, AParams[I].Name);
    WTypeRef(AW, AParams[I].TypeRef);
    WU8(AW, Ord(AParams[I].Modifier));
    WU8(AW, Ord(AParams[I].Direction));
    WMarshal(AW, AParams[I].Marshal);
    WBool(AW, AParams[I].IsScoped);
  end;
end;

procedure WMethod(var AW: TPlanWriter; const AMethod: TWlcMethod);
begin
  WStr(AW, AMethod.Name);
  WStr(AW, AMethod.LibraryName);
  WStr(AW, AMethod.EntryPoint);
  WTypeRef(AW, AMethod.ReturnType);
  WMarshal(AW, AMethod.ReturnMarshal);
  WParams(AW, AMethod.Params);
end;

procedure WValueTypes(var AW: TPlanWriter;
  const ATypes: array of TWasmValueType);
var
  I: Integer;
begin
  WU32(AW, UInt32(Length(ATypes)));
  for I := 0 to High(ATypes) do
  begin
    { Resolve lowers every connector value to a numeric type. Anything else
      reaching the writer is a resolve defect, not a plan to serialize. }
    if ATypes[I].Kind <> wvkNum then
      raise EWasmInternal.Create(
        'internal: connector plan signature has a non-numeric value type');
    case ATypes[I].Num of
      wntI32: WU8(AW, $7F);
      wntI64: WU8(AW, $7E);
      wntF32: WU8(AW, $7D);
      wntF64: WU8(AW, $7C);
    end;
  end;
end;

procedure WConnector(var AW: TPlanWriter; const AConnector: TWlcConnector);
var
  I, J: Integer;
begin
  WStr(AW, AConnector.Name);

  WU32(AW, UInt32(Length(AConnector.Structs)));
  for I := 0 to High(AConnector.Structs) do
  begin
    WStr(AW, AConnector.Structs[I].Name);
    WU32(AW, UInt32(Length(AConnector.Structs[I].Fields)));
    for J := 0 to High(AConnector.Structs[I].Fields) do
    begin
      WStr(AW, AConnector.Structs[I].Fields[J].Name);
      WTypeRef(AW, AConnector.Structs[I].Fields[J].TypeRef);
      WMarshal(AW, AConnector.Structs[I].Fields[J].Marshal);
      WBool(AW, AConnector.Structs[I].Fields[J].IsScoped);
    end;
  end;

  WU32(AW, UInt32(Length(AConnector.Enums)));
  for I := 0 to High(AConnector.Enums) do
  begin
    WStr(AW, AConnector.Enums[I].Name);
    WStr(AW, AConnector.Enums[I].UnderlyingType);
    WU32(AW, UInt32(Length(AConnector.Enums[I].Members)));
    for J := 0 to High(AConnector.Enums[I].Members) do
    begin
      WStr(AW, AConnector.Enums[I].Members[J].Name);
      WU64(AW, UInt64(AConnector.Enums[I].Members[J].Value));
      WBool(AW, AConnector.Enums[I].Members[J].HasValue);
    end;
  end;

  WU32(AW, UInt32(Length(AConnector.Delegates)));
  for I := 0 to High(AConnector.Delegates) do
  begin
    WStr(AW, AConnector.Delegates[I].Name);
    WTypeRef(AW, AConnector.Delegates[I].ReturnType);
    WMarshal(AW, AConnector.Delegates[I].ReturnMarshal);
    WParams(AW, AConnector.Delegates[I].Params);
    WU8(AW, Ord(AConnector.Delegates[I].CallbackKind));
  end;

  WU32(AW, UInt32(Length(AConnector.Methods)));
  for I := 0 to High(AConnector.Methods) do
    WMethod(AW, AConnector.Methods[I]);
end;

function EncodeConnectorPlan(const APlan: TWlcConnectorPlan): TWasmBytes;
var
  W: TPlanWriter;
  I: Integer;
begin
  Result := nil;
  if Length(APlan.Thunks) = 0 then
    Exit;
  W.Buf := nil;
  W.Len := 0;
  WU8(W, WLCP_MAGIC0);
  WU8(W, WLCP_MAGIC1);
  WU8(W, WLCP_MAGIC2);
  WU8(W, WLCP_MAGIC3);
  WU16(W, WLCP_FORMAT_VERSION);
  WU16(W, 0);

  WU32(W, UInt32(Length(APlan.Thunks)));
  for I := 0 to High(APlan.Thunks) do
  begin
    WStr(W, APlan.Thunks[I].GuestModule);
    WStr(W, APlan.Thunks[I].GuestName);
    WStr(W, APlan.Thunks[I].LibraryName);
    WStr(W, APlan.Thunks[I].NativeSymbol);
    WStr(W, APlan.Thunks[I].ConnectorName);
    WMethod(W, APlan.Thunks[I].Method);
    WValueTypes(W, APlan.Thunks[I].Func.Params);
    WValueTypes(W, APlan.Thunks[I].Func.Results);
  end;

  WU32(W, UInt32(Length(APlan.Libraries)));
  for I := 0 to High(APlan.Libraries) do
    WStr(W, APlan.Libraries[I]);

  WU32(W, UInt32(Length(APlan.Connectors)));
  for I := 0 to High(APlan.Connectors) do
    WConnector(W, APlan.Connectors[I]);

  SetLength(W.Buf, W.Len);
  Result := W.Buf;
end;

{ --- reader --------------------------------------------------------------- }

type
  { Bounds-checked LE reader. The first failure is sticky: every later read
    is a no-op returning zero, so a caller checks Fail once per record. }
  TPlanReader = record
    Data: TWasmBytes;
    Pos: NativeUInt;
    Fail: TWlcPlanDecodeResult;
  end;

function Remaining(const AR: TPlanReader): NativeUInt;
begin
  Result := NativeUInt(Length(AR.Data)) - AR.Pos;
end;

procedure SetFail(var AR: TPlanReader; const AResult: TWlcPlanDecodeResult);
begin
  if AR.Fail = wpdOk then
    AR.Fail := AResult;
end;

function RU8(var AR: TPlanReader): Byte;
begin
  Result := 0;
  if AR.Fail <> wpdOk then
    Exit;
  if Remaining(AR) < 1 then
  begin
    SetFail(AR, wpdTruncated);
    Exit;
  end;
  Result := AR.Data[AR.Pos];
  Inc(AR.Pos);
end;

function RU16(var AR: TPlanReader): UInt16;
var
  B0, B1: Byte;
begin
  B0 := RU8(AR);
  B1 := RU8(AR);
  Result := UInt16(B0) or (UInt16(B1) shl 8);
end;

function RU32(var AR: TPlanReader): UInt32;
var
  Lo, Hi: UInt16;
begin
  Lo := RU16(AR);
  Hi := RU16(AR);
  Result := UInt32(Lo) or (UInt32(Hi) shl 16);
end;

function RU64(var AR: TPlanReader): UInt64;
var
  Lo, Hi: UInt32;
begin
  Lo := RU32(AR);
  Hi := RU32(AR);
  Result := UInt64(Lo) or (UInt64(Hi) shl 32);
end;

function RBool(var AR: TPlanReader): Boolean;
var
  B: Byte;
begin
  B := RU8(AR);
  if B > 1 then
    SetFail(AR, wpdBadValue);
  Result := B = 1;
end;

function ROrd(var AR: TPlanReader; const AHigh: Integer): Integer;
begin
  Result := RU8(AR);
  if Result > AHigh then
  begin
    SetFail(AR, wpdBadValue);
    Result := 0;
  end;
end;

{ A count of elements each at least AMinSize bytes. A count that cannot fit
  in the remaining bytes is rejected before anything is allocated. }
function RCount(var AR: TPlanReader; const AMinSize: NativeUInt): Integer;
var
  N: UInt32;
begin
  Result := 0;
  N := RU32(AR);
  if AR.Fail <> wpdOk then
    Exit;
  if (AMinSize > 0) and (NativeUInt(N) > Remaining(AR) div AMinSize) then
  begin
    SetFail(AR, wpdTruncated);
    Exit;
  end;
  Result := Integer(N);
end;

function RStr(var AR: TPlanReader): string;
var
  N: Integer;
  I: Integer;
begin
  Result := '';
  N := RCount(AR, 1);
  if AR.Fail <> wpdOk then
    Exit;
  SetLength(Result, N);
  for I := 1 to N do
  begin
    Result[I] := AnsiChar(AR.Data[AR.Pos]);
    Inc(AR.Pos);
  end;
end;

function RTypeRef(var AR: TPlanReader): TWlcTypeRef;
begin
  Result.Name := RStr(AR);
  Result.IsArray := RBool(AR);
end;

function RMarshal(var AR: TPlanReader): TWlcMarshal;
var
  Size: UInt32;
begin
  Result := Default(TWlcMarshal);
  Result.Kind := TWlcMarshalKind(ROrd(AR, Ord(High(TWlcMarshalKind))));
  Result.HasSizeConst := RBool(AR);
  Size := RU32(AR);
  if (not Result.HasSizeConst) and (Size <> 0) then
    SetFail(AR, wpdBadValue);
  Result.SizeConst := Integer(Int32(Size));
  Result.HasSizeParamIndex := RBool(AR);
  Size := RU32(AR);
  if ((not Result.HasSizeParamIndex) and (Size <> 0)) or (Size > $7FFFFFFF) then
    SetFail(AR, wpdBadValue);
  Result.SizeParamIndex := Integer(Size and $7FFFFFFF);
end;

{ Minimum encoded sizes, used to bound counts before allocation. }
const
  MIN_STR = 4;
  MIN_TYPEREF = MIN_STR + 1;
  MIN_MARSHAL = 1 + 1 + 4 + 1 + 4;
  MIN_PARAM = MIN_STR + MIN_TYPEREF + 1 + 1 + MIN_MARSHAL + 1;
  MIN_METHOD = 3 * MIN_STR + MIN_TYPEREF + MIN_MARSHAL + 4;
  MIN_FIELD = MIN_STR + MIN_TYPEREF + MIN_MARSHAL + 1;
  MIN_STRUCT = MIN_STR + 4;
  MIN_MEMBER = MIN_STR + 8 + 1;
  MIN_ENUM = 2 * MIN_STR + 4;
  MIN_DELEGATE = MIN_STR + MIN_TYPEREF + MIN_MARSHAL + 4 + 1;
  MIN_CONNECTOR = MIN_STR + 4 * 4;
  MIN_THUNK = 5 * MIN_STR + MIN_METHOD + 4 + 4;

{ Params are filled in place: the method and delegate records declare their
  own anonymous dynamic-array types, which Delphi mode does not assign
  between. }
procedure RParam(var AR: TPlanReader; out AParam: TWlcParam);
begin
  AParam := Default(TWlcParam);
  AParam.Name := RStr(AR);
  AParam.TypeRef := RTypeRef(AR);
  AParam.Modifier := TWlcParamModifier(ROrd(AR, Ord(High(TWlcParamModifier))));
  AParam.Direction := TWlcDirection(ROrd(AR, Ord(High(TWlcDirection))));
  AParam.Marshal := RMarshal(AR);
  AParam.IsScoped := RBool(AR);
end;

function RMethod(var AR: TPlanReader): TWlcMethod;
var
  I, N: Integer;
begin
  Result := Default(TWlcMethod);
  Result.Name := RStr(AR);
  Result.LibraryName := RStr(AR);
  Result.EntryPoint := RStr(AR);
  Result.ReturnType := RTypeRef(AR);
  Result.ReturnMarshal := RMarshal(AR);
  N := RCount(AR, MIN_PARAM);
  SetLength(Result.Params, N);
  for I := 0 to N - 1 do
  begin
    RParam(AR, Result.Params[I]);
    if AR.Fail <> wpdOk then
      Exit;
  end;
end;

function RValueType(var AR: TPlanReader): TWasmValueType;
begin
  Result := MakeNumValueType(wntI32);
  case RU8(AR) of
    $7F: Result := MakeNumValueType(wntI32);
    $7E: Result := MakeNumValueType(wntI64);
    $7D: Result := MakeNumValueType(wntF32);
    $7C: Result := MakeNumValueType(wntF64);
  else
    SetFail(AR, wpdBadValue);
  end;
end;

procedure RFuncType(var AR: TPlanReader; out AFunc: TWasmFuncType);
var
  I, N: Integer;
begin
  AFunc.Params := nil;
  AFunc.Results := nil;
  N := RCount(AR, 1);
  SetLength(AFunc.Params, N);
  for I := 0 to N - 1 do
    AFunc.Params[I] := RValueType(AR);
  N := RCount(AR, 1);
  SetLength(AFunc.Results, N);
  for I := 0 to N - 1 do
    AFunc.Results[I] := RValueType(AR);
end;

function RConnector(var AR: TPlanReader): TWlcConnector;
var
  I, J, N, M: Integer;
begin
  Result := Default(TWlcConnector);
  Result.Name := RStr(AR);

  N := RCount(AR, MIN_STRUCT);
  SetLength(Result.Structs, N);
  for I := 0 to N - 1 do
  begin
    Result.Structs[I] := Default(TWlcStruct);
    Result.Structs[I].Name := RStr(AR);
    M := RCount(AR, MIN_FIELD);
    SetLength(Result.Structs[I].Fields, M);
    for J := 0 to M - 1 do
    begin
      Result.Structs[I].Fields[J] := Default(TWlcField);
      Result.Structs[I].Fields[J].Name := RStr(AR);
      Result.Structs[I].Fields[J].TypeRef := RTypeRef(AR);
      Result.Structs[I].Fields[J].Marshal := RMarshal(AR);
      Result.Structs[I].Fields[J].IsScoped := RBool(AR);
      if AR.Fail <> wpdOk then
        Exit;
    end;
  end;

  N := RCount(AR, MIN_ENUM);
  SetLength(Result.Enums, N);
  for I := 0 to N - 1 do
  begin
    Result.Enums[I] := Default(TWlcEnum);
    Result.Enums[I].Name := RStr(AR);
    Result.Enums[I].UnderlyingType := RStr(AR);
    M := RCount(AR, MIN_MEMBER);
    SetLength(Result.Enums[I].Members, M);
    for J := 0 to M - 1 do
    begin
      Result.Enums[I].Members[J] := Default(TWlcEnumMember);
      Result.Enums[I].Members[J].Name := RStr(AR);
      Result.Enums[I].Members[J].Value := Int64(RU64(AR));
      Result.Enums[I].Members[J].HasValue := RBool(AR);
      if AR.Fail <> wpdOk then
        Exit;
    end;
  end;

  N := RCount(AR, MIN_DELEGATE);
  SetLength(Result.Delegates, N);
  for I := 0 to N - 1 do
  begin
    Result.Delegates[I] := Default(TWlcDelegate);
    Result.Delegates[I].Name := RStr(AR);
    Result.Delegates[I].ReturnType := RTypeRef(AR);
    Result.Delegates[I].ReturnMarshal := RMarshal(AR);
    M := RCount(AR, MIN_PARAM);
    SetLength(Result.Delegates[I].Params, M);
    for J := 0 to M - 1 do
      RParam(AR, Result.Delegates[I].Params[J]);
    Result.Delegates[I].CallbackKind := TWlcCallbackKind(
      ROrd(AR, Ord(High(TWlcCallbackKind))));
    if AR.Fail <> wpdOk then
      Exit;
  end;

  N := RCount(AR, MIN_METHOD);
  SetLength(Result.Methods, N);
  for I := 0 to N - 1 do
  begin
    Result.Methods[I] := RMethod(AR);
    if AR.Fail <> wpdOk then
      Exit;
  end;
end;

procedure ClearPlan(out APlan: TWlcConnectorPlan);
begin
  APlan.Thunks := nil;
  APlan.Libraries := nil;
  APlan.Connectors := nil;
end;

function DecodeConnectorPlan(const ABytes: TWasmBytes;
  out APlan: TWlcConnectorPlan): TWlcPlanDecodeResult;
var
  R: TPlanReader;
  I, N: Integer;
  Plan: TWlcConnectorPlan;
begin
  ClearPlan(APlan);
  if Length(ABytes) = 0 then
    Exit(wpdOk);
  if Length(ABytes) < 8 then
    Exit(wpdTruncated);
  if (ABytes[0] <> WLCP_MAGIC0) or (ABytes[1] <> WLCP_MAGIC1) or
    (ABytes[2] <> WLCP_MAGIC2) or (ABytes[3] <> WLCP_MAGIC3) then
    Exit(wpdBadMagic);

  R.Data := ABytes;
  R.Pos := 4;
  R.Fail := wpdOk;
  if RU16(R) <> WLCP_FORMAT_VERSION then
    Exit(wpdUnsupportedVersion);
  if RU16(R) <> 0 then
    Exit(wpdBadValue);

  ClearPlan(Plan);
  N := RCount(R, MIN_THUNK);
  { A non-empty section always binds something: the writer emits no bytes
    for an empty plan, so zero thunks here is not the canonical form. }
  if (R.Fail = wpdOk) and (N = 0) then
    SetFail(R, wpdBadValue);
  SetLength(Plan.Thunks, N);
  for I := 0 to N - 1 do
  begin
    Plan.Thunks[I] := Default(TWlcResolvedThunk);
    Plan.Thunks[I].GuestModule := RStr(R);
    Plan.Thunks[I].GuestName := RStr(R);
    Plan.Thunks[I].LibraryName := RStr(R);
    Plan.Thunks[I].NativeSymbol := RStr(R);
    Plan.Thunks[I].ConnectorName := RStr(R);
    Plan.Thunks[I].Method := RMethod(R);
    RFuncType(R, Plan.Thunks[I].Func);
    if R.Fail <> wpdOk then
      Exit(R.Fail);
  end;

  N := RCount(R, MIN_STR);
  SetLength(Plan.Libraries, N);
  for I := 0 to N - 1 do
    Plan.Libraries[I] := RStr(R);

  N := RCount(R, MIN_CONNECTOR);
  SetLength(Plan.Connectors, N);
  for I := 0 to N - 1 do
  begin
    Plan.Connectors[I] := RConnector(R);
    if R.Fail <> wpdOk then
      Exit(R.Fail);
  end;

  if R.Fail <> wpdOk then
    Exit(R.Fail);
  if R.Pos <> NativeUInt(Length(ABytes)) then
    Exit(wpdTrailingBytes);
  APlan := Plan;
  Result := wpdOk;
end;

function ConnectorPlanDecodeText(const AResult: TWlcPlanDecodeResult): string;
begin
  case AResult of
    wpdOk: Result := 'ok';
    wpdBadMagic: Result := 'bad magic';
    wpdUnsupportedVersion: Result := 'unsupported version';
    wpdTruncated: Result := 'truncated';
    wpdBadValue: Result := 'bad value';
    wpdTrailingBytes: Result := 'trailing bytes';
  else
    Result := 'unreadable';
  end;
end;

function SameBytes(const A, B: TWasmBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

function CheckConnectorPlanForModule(const ABytes: TWasmBytes;
  const AModule: TWasmModule;
  const ABuiltInModules: array of string): TWlcConnectorPlan;
var
  Decoded: TWlcPlanDecodeResult;
  Doc: TWlcDocument;
  Again: TWlcConnectorPlan;
begin
  Decoded := DecodeConnectorPlan(ABytes, Result);
  if Decoded <> wpdOk then
    raise EWasmLinkError.Create(MSG_WLCP_MALFORMED + ': ' +
      ConnectorPlanDecodeText(Decoded));
  if Length(Result.Thunks) = 0 then
    Exit;
  Doc.Connectors := Result.Connectors;
  try
    Again := ResolveConnectorModule([Doc], AModule, ABuiltInModules);
  except
    on E: EWasmLinkError do
      raise EWasmLinkError.Create(MSG_WLCP_MALFORMED +
        ': does not resolve against the module: ' + E.Message);
  end;
  if not SameBytes(EncodeConnectorPlan(Again), ABytes) then
    raise EWasmLinkError.Create(MSG_WLCP_MALFORMED +
      ': does not match the module''s resolved plan');
end;

end.
