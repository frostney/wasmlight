{ Wasm.Connector.Host — connector host functions from a resolved plan
  (issue #146, ADR-0015).

  This is where the shipped connector pieces meet: a TWlcConnectorPlan
  (Wasm.Connector.Resolve) is lowered to C signatures, planned for a C ABI
  (Wasm.Abi), bound to application-local library symbols
  (Wasm.Native.Load), and exposed as ordinary host functions on the
  deny-by-default TWasmLinker, where each call goes through the precompiled
  gate (Wasm.Native.Call). The runtime shell defines them next to WASI; the
  compiler uses the host-independent half to reject a plan the selected
  target cannot call before it writes an executable.

  Lowering is fixed marshalling, never inference. A parameter or result
  whose declaration has no fixed lowering here is EWasmLinkError
  `unsupported connector type` at compile time and again at startup — the
  plan fails closed rather than guessing a guest-memory or pointer
  contract.

  Libraries load only from the plan's own Libraries list (already stripped
  to used declarations), each at most once, before instantiation. A missing
  library or symbol is EWasmLinkError from Wasm.Native.Load; nothing is
  searched on an ambient loader path.

  64-bit Unix only: on any other host the call plan is incompatible and
  loading fails closed with the same link class. }
unit Wasm.Connector.Host;

{$I Shared.inc}

{ Host functions index the caller's parameter slice. }
{$POINTERMATH ON}

interface

uses
  Wasm.Abi,
  Wasm.Connector,
  Wasm.Connector.Resolve,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Native.Load;

type
  { The host-independent lowering of one resolved thunk: one C scalar per
    guest parameter, in order, and the C result (wcsVoid for none). }
  TWasmConnectorCall = record
    ParamScalars: array of TWasmCScalar;
    { C `bool` (one byte, 0 or 1): the guest's non-zero i32 is passed as 1,
      and a result's non-zero low byte is returned as 1. }
    ParamBools: array of Boolean;
    ResultScalar: TWasmCScalar;
    ResultBool: Boolean;
    Signature: TWasmCSignature;
  end;

  { Owns the loaded libraries and the per-import bindings for one store.
    Free after the instance handles and before the store. }
  TWasmConnectorHost = class
  private
    FLibraries: array of TWasmNativeLibrary;
    FLibraryNames: array of string;
    FBindings: array of TObject;
    FPlan: TWlcConnectorPlan;
    function LibraryFor(const AName, ALibraryDir: string): TWasmNativeLibrary;
  public
    { Lower every thunk, plan it for the host ABI, load every plan library
      from ALibraryDir (the executable directory in a compiled program), and
      look up every native symbol. Raises EWasmLinkError on any failure and
      releases what it loaded. }
    constructor Create(const APlan: TWlcConnectorPlan;
      const ALibraryDir: string);
    destructor Destroy; override;

    { Define one host function per guest import on ALinker. }
    procedure DefineImports(const ALinker: TWasmLinker);
  end;

{ Lower APlan.Thunks[AIndex]. Raises EWasmLinkError
  (MSG_WLC_UNSUPPORTED_TYPE) when a parameter or the result has no fixed
  lowering. }
function LowerConnectorThunk(const APlan: TWlcConnectorPlan;
  const AIndex: Integer): TWasmConnectorCall;

{ Compile-time gate: every thunk lowers and its call plan is compatible with
  ATarget. Loads nothing. }
procedure CheckConnectorPlanTarget(const APlan: TWlcConnectorPlan;
  const ATarget: TWasmAbiTarget);

{ Compile-time linker entries: the plan's guest imports with their resolved
  signatures, so import resolution sees exactly what the shell will define.
  The entries are never called — compile does not instantiate. }
procedure DefineConnectorSignatures(const ALinker: TWasmLinker;
  const APlan: TWlcConnectorPlan);

implementation

uses
  Wasm.Native.Call,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

type
  TConnectorBinding = class
  public
    Fn: Pointer;
    Plan: TWasmAbiPlan;
    Call: TWasmConnectorCall;
  end;

{ --- lowering ------------------------------------------------------------- }

function FindConnector(const APlan: TWlcConnectorPlan; const AName: string;
  out AConnector: TWlcConnector): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(APlan.Connectors) do
    if APlan.Connectors[I].Name = AName then
    begin
      AConnector := APlan.Connectors[I];
      Exit(True);
    end;
  AConnector := Default(TWlcConnector);
  Result := False;
end;

function PrimitiveScalar(const AName: string; out AScalar: TWasmCScalar):
  Boolean;
begin
  Result := True;
  if (AName = 'sbyte') or (AName = 'SByte') then
    AScalar := wcsI8
  else if (AName = 'byte') or (AName = 'Byte') or (AName = 'bool') or
    (AName = 'Boolean') then
    AScalar := wcsU8
  else if (AName = 'short') or (AName = 'Int16') then
    AScalar := wcsI16
  else if (AName = 'ushort') or (AName = 'UInt16') or (AName = 'char') or
    (AName = 'Char') then
    AScalar := wcsU16
  else if (AName = 'int') or (AName = 'Int32') then
    AScalar := wcsI32
  else if (AName = 'uint') or (AName = 'UInt32') then
    AScalar := wcsU32
  else if (AName = 'long') or (AName = 'Int64') then
    AScalar := wcsI64
  else if (AName = 'ulong') or (AName = 'UInt64') then
    AScalar := wcsU64
  else if (AName = 'float') or (AName = 'Single') then
    AScalar := wcsF32
  else if (AName = 'double') or (AName = 'Double') then
    AScalar := wcsF64
  else
    Result := False;
end;

function MarshalScalar(const AKind: TWlcMarshalKind;
  out AScalar: TWasmCScalar): Boolean;
begin
  Result := True;
  case AKind of
    wlmInt8: AScalar := wcsI8;
    wlmUInt8, wlmBool: AScalar := wcsU8;
    wlmInt16: AScalar := wcsI16;
    wlmUInt16: AScalar := wcsU16;
    wlmInt32: AScalar := wcsI32;
    wlmUInt32: AScalar := wcsU32;
    wlmInt64: AScalar := wcsI64;
    wlmUInt64: AScalar := wcsU64;
    wlmFloat32: AScalar := wcsF32;
    wlmFloat64: AScalar := wcsF64;
  else
    Result := False;
  end;
end;

function IsBoolDeclaration(const ARef: TWlcTypeRef;
  const AMarshal: TWlcMarshal): Boolean;
begin
  if AMarshal.Kind <> wlmDefault then
    Result := AMarshal.Kind = wlmBool
  else
    Result := (ARef.Name = 'bool') or (ARef.Name = 'Boolean');
end;

{ The fixed scalar lowering. Arrays, strings, pointer-sized names, structs,
  delegates, and ref/out/in parameters have no lowering here. }
function LowerScalar(const AConnector: TWlcConnector; const ARef: TWlcTypeRef;
  const AMarshal: TWlcMarshal; const AModifier: TWlcParamModifier;
  const AScoped: Boolean; out AScalar: TWasmCScalar): Boolean;
var
  I: Integer;
  Underlying: string;
begin
  AScalar := wcsVoid;
  if ARef.IsArray or (AModifier <> wpmNone) or AScoped then
    Exit(False);
  if AMarshal.Kind <> wlmDefault then
    Exit(MarshalScalar(AMarshal.Kind, AScalar));
  if PrimitiveScalar(ARef.Name, AScalar) then
    Exit(True);
  for I := 0 to High(AConnector.Enums) do
    if AConnector.Enums[I].Name = ARef.Name then
    begin
      Underlying := AConnector.Enums[I].UnderlyingType;
      if Underlying = '' then
        Underlying := 'int';
      Exit(PrimitiveScalar(Underlying, AScalar));
    end;
  Result := False;
end;

procedure RaiseUnsupported(const AThunk: TWlcResolvedThunk;
  const ATypeName: string);
begin
  raise EWasmLinkError.CreateFmt('%s: "%s"."%s": %s',
    [MSG_WLC_UNSUPPORTED_TYPE, AThunk.GuestModule, AThunk.GuestName,
     ATypeName]);
end;

function ScalarCType(const AScalar: TWasmCScalar): TWasmCType;
begin
  case AScalar of
    wcsI8: Result := AbiI8;
    wcsU8: Result := AbiU8;
    wcsI16: Result := AbiI16;
    wcsU16: Result := AbiU16;
    wcsI32: Result := AbiI32;
    wcsU32: Result := AbiU32;
    wcsI64: Result := AbiI64;
    wcsU64: Result := AbiU64;
    wcsF32: Result := AbiF32;
    wcsF64: Result := AbiF64;
  else
    Result := AbiVoid;
  end;
end;

function LowerConnectorThunk(const APlan: TWlcConnectorPlan;
  const AIndex: Integer): TWasmConnectorCall;
var
  Thunk: TWlcResolvedThunk;
  Connector: TWlcConnector;
  I: Integer;
  Param: TWlcParam;
  Params: array of TWasmCType;
begin
  Thunk := APlan.Thunks[AIndex];
  if not FindConnector(APlan, Thunk.ConnectorName, Connector) then
    RaiseUnsupported(Thunk, Thunk.ConnectorName);
  Result.ParamScalars := nil;
  Result.ParamBools := nil;
  SetLength(Result.ParamScalars, Length(Thunk.Method.Params));
  SetLength(Result.ParamBools, Length(Thunk.Method.Params));
  SetLength(Params, Length(Thunk.Method.Params));
  for I := 0 to High(Thunk.Method.Params) do
  begin
    Param := Thunk.Method.Params[I];
    if not LowerScalar(Connector, Param.TypeRef, Param.Marshal,
      Param.Modifier, Param.IsScoped, Result.ParamScalars[I]) then
      RaiseUnsupported(Thunk, Param.TypeRef.Name);
    Result.ParamBools[I] := IsBoolDeclaration(Param.TypeRef, Param.Marshal);
    Params[I] := ScalarCType(Result.ParamScalars[I]);
  end;
  Result.ResultBool := False;
  if Thunk.Method.ReturnType.Name = 'void' then
    Result.ResultScalar := wcsVoid
  else if not LowerScalar(Connector, Thunk.Method.ReturnType,
    Thunk.Method.ReturnMarshal, wpmNone, False, Result.ResultScalar) then
    RaiseUnsupported(Thunk, Thunk.Method.ReturnType.Name)
  else
    Result.ResultBool := IsBoolDeclaration(Thunk.Method.ReturnType,
      Thunk.Method.ReturnMarshal);
  Result.Signature := AbiSignature(Params, ScalarCType(Result.ResultScalar));
end;

function PlanThunk(const APlan: TWlcConnectorPlan; const AIndex: Integer;
  const ATarget: TWasmAbiTarget; out ACall: TWasmConnectorCall): TWasmAbiPlan;
begin
  ACall := LowerConnectorThunk(APlan, AIndex);
  Result := PlanCall(ATarget, ACall.Signature);
  if not Result.Compatible then
    raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
      [MSG_LINK_INCOMPATIBLE_PLAN, APlan.Thunks[AIndex].GuestModule,
       APlan.Thunks[AIndex].GuestName]);
end;

procedure CheckConnectorPlanTarget(const APlan: TWlcConnectorPlan;
  const ATarget: TWasmAbiTarget);
var
  I: Integer;
  Call: TWasmConnectorCall;
begin
  for I := 0 to High(APlan.Thunks) do
    PlanThunk(APlan, I, ATarget, Call);
end;

{ --- the host function ---------------------------------------------------- }

function ScalarArgument(const AScalar: TWasmCScalar;
  const AValue: TWasmValue): TWasmAbiValue;
begin
  { Integers are passed sign- or zero-extended to 64 bits from their C
    width, so a narrow argument reaches the callee extended the way Apple
    AArch64 and SysV callers extend it. A guest i32 for a narrower C type
    is truncated to that type first. }
  case AScalar of
    wcsI8: Result := AbiValueI64(Int8(AValue.I32));
    wcsU8: Result := AbiValueU64(UInt8(AValue.U32));
    wcsI16: Result := AbiValueI64(Int16(AValue.I32));
    wcsU16: Result := AbiValueU64(UInt16(AValue.U32));
    wcsI32: Result := AbiValueI64(AValue.I32);
    wcsU32: Result := AbiValueU64(AValue.U32);
    wcsI64: Result := AbiValueI64(AValue.I64);
    wcsU64: Result := AbiValueU64(AValue.U64);
    wcsF32: Result := AbiValueF32(AValue.F32);
    wcsF64: Result := AbiValueF64(AValue.F64);
  else
    Result := AbiValueU64(0);
  end;
end;

function ScalarResult(const AScalar: TWasmCScalar;
  const AValue: TWasmAbiValue): TWasmValue;
begin
  { A result reads only its C width; the extension to the wasm type is done
    here, never trusted from the callee's upper register bits. }
  case AScalar of
    wcsI8: Result := MakeValueI32(Int8(AbiValueAsI32(AValue)));
    wcsU8: Result := MakeValueI32(UInt8(AbiValueAsI32(AValue)));
    wcsI16: Result := MakeValueI32(Int16(AbiValueAsI32(AValue)));
    wcsU16: Result := MakeValueI32(UInt16(AbiValueAsI32(AValue)));
    wcsI32, wcsU32: Result := MakeValueI32(AbiValueAsI32(AValue));
    wcsI64, wcsU64: Result := MakeValueI64(AbiValueAsI64(AValue));
    wcsF32: Result := MakeValueF32(AbiValueAsF32(AValue));
    wcsF64: Result := MakeValueF64(AbiValueAsF64(AValue));
  else
    Result := MakeValueI32(0);
  end;
end;

procedure ConnectorHostCall(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Binding: TConnectorBinding;
  Args: array of TWasmAbiValue;
  Ret: TWasmAbiValue;
  I: Integer;
begin
  Binding := TConnectorBinding(AData);
  Args := nil;
  SetLength(Args, Length(Binding.Call.ParamScalars));
  for I := 0 to High(Args) do
    if Binding.Call.ParamBools[I] then
      Args[I] := AbiValueU64(Ord(AParams[I].I32 <> 0))
    else
      Args[I] := ScalarArgument(Binding.Call.ParamScalars[I],
        AParams[I]);
  Ret.Data := nil;
  ApplyNativeCall(Binding.Plan, Binding.Fn, Args, Ret);
  if Binding.Call.ResultBool then
    AResults^ := MakeValueI32(Ord(UInt8(AbiValueAsI32(Ret)) <> 0))
  else if Binding.Call.ResultScalar <> wcsVoid then
    AResults^ := ScalarResult(Binding.Call.ResultScalar, Ret);
end;

procedure SignatureOnlyCall(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  raise EWasmInternal.Create(
    'internal: a compile-time connector signature was called');
end;

function DefinedEarlier(const APlan: TWlcConnectorPlan;
  const AIndex: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to AIndex - 1 do
    if (APlan.Thunks[I].GuestModule = APlan.Thunks[AIndex].GuestModule) and
      (APlan.Thunks[I].GuestName = APlan.Thunks[AIndex].GuestName) then
      Exit(True);
  Result := False;
end;

procedure DefineConnectorSignatures(const ALinker: TWasmLinker;
  const APlan: TWlcConnectorPlan);
var
  I: Integer;
begin
  for I := 0 to High(APlan.Thunks) do
    if not DefinedEarlier(APlan, I) then
      ALinker.DefineFunc(APlan.Thunks[I].GuestModule,
        APlan.Thunks[I].GuestName, APlan.Thunks[I].Func.Params,
        APlan.Thunks[I].Func.Results, @SignatureOnlyCall, nil);
end;

{ --- TWasmConnectorHost --------------------------------------------------- }

function TWasmConnectorHost.LibraryFor(const AName, ALibraryDir: string):
  TWasmNativeLibrary;
var
  I: Integer;
begin
  for I := 0 to High(FLibraryNames) do
    if FLibraryNames[I] = AName then
      Exit(FLibraries[I]);
  Result := LoadLocalLibraryAt(AName, ALibraryDir);
  I := Length(FLibraries);
  SetLength(FLibraries, I + 1);
  SetLength(FLibraryNames, I + 1);
  FLibraries[I] := Result;
  FLibraryNames[I] := AName;
end;

constructor TWasmConnectorHost.Create(const APlan: TWlcConnectorPlan;
  const ALibraryDir: string);
var
  I: Integer;
  Binding: TConnectorBinding;
  Calls: array of TWasmConnectorCall;
  Plans: array of TWasmAbiPlan;
begin
  inherited Create;
  FPlan := APlan;
  { Every thunk lowers and plans before any library is opened, so an
    unsupported or incompatible plan loads nothing. }
  SetLength(Calls, Length(APlan.Thunks));
  SetLength(Plans, Length(APlan.Thunks));
  for I := 0 to High(APlan.Thunks) do
    Plans[I] := PlanThunk(APlan, I, AbiHostTarget, Calls[I]);
  for I := 0 to High(APlan.Libraries) do
    LibraryFor(APlan.Libraries[I], ALibraryDir);
  SetLength(FBindings, Length(APlan.Thunks));
  for I := 0 to High(APlan.Thunks) do
  begin
    Binding := TConnectorBinding.Create;
    FBindings[I] := Binding;
    Binding.Call := Calls[I];
    Binding.Plan := Plans[I];
    Binding.Fn := LookupLocalSymbol(
      LibraryFor(APlan.Thunks[I].LibraryName, ALibraryDir),
      APlan.Thunks[I].NativeSymbol);
  end;
end;

destructor TWasmConnectorHost.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FBindings) do
    FBindings[I].Free;
  FBindings := nil;
  for I := 0 to High(FLibraries) do
    FLibraries[I].Free;
  FLibraries := nil;
  inherited Destroy;
end;

procedure TWasmConnectorHost.DefineImports(const ALinker: TWasmLinker);
var
  I: Integer;
begin
  for I := 0 to High(FPlan.Thunks) do
    if not DefinedEarlier(FPlan, I) then
      ALinker.DefineFunc(FPlan.Thunks[I].GuestModule,
        FPlan.Thunks[I].GuestName, FPlan.Thunks[I].Func.Params,
        FPlan.Thunks[I].Func.Results, @ConnectorHostCall,
        Pointer(FBindings[I]));
end;

end.
