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

  Lowering is fixed marshalling, never inference (decisions D11–D14 on
  #146):

    - Scalars, C `bool`, and enums pass by value.
    - An array is a guest `i32` offset into the exported `memory` plus an
      element count from `SizeConst` or the `SizeParamIndex` parameter.
      `[In]`, `[Out]`, and `[In, Out]` copy through Wasm.Connector.Memory;
      `[Scoped]` borrows the guest range for the one call. An array with
      none of these is rejected.
    - IntPtr / nint / UIntPtr / nuint / MarshalAs(SysInt|SysUInt) are
      opaque handles: a returned pointer mints a handle (NULL is 0), a
      handle argument resolves back (0 is NULL), a stale one is
      EWasmConnectorError. Handles live for the process.
    - A delegate argument is a guest `i32` index into table 0. A null,
      out-of-range, or wrong-signature entry traps exactly as
      `call_indirect` does. Only void(), void(i32), i32(), and i32(i32)
      delegates are callable; the thunk comes from Wasm.Connector.Callbacks
      with the delegate's retained / [Scoped] / [Queued] lifetime.
    - Strings, structs, and ref / out / in parameters have no lowering.

  Anything without a lowering is EWasmLinkError `unsupported connector
  type` at compile time and again at startup.

  Libraries load only from the plan's own Libraries list (already stripped
  to used declarations), each at most once, before instantiation. A missing
  library or symbol is EWasmLinkError from Wasm.Native.Load; nothing is
  searched on an ambient loader path.

  Guest failures inside a callback never unwind through the native frame:
  the hub retains them, and the host function rethrows once the native
  call has returned, before any copy-out. Queued notifications are
  delivered after every connector call and when `_start` returns.

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
  Wasm.Connector.Callbacks,
  Wasm.Connector.Memory,
  Wasm.Connector.Resolve,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Native.Load,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values;

type
  TWasmConnectorParamKind = (
    wcpScalar,
    wcpBool,
    wcpBuffer,
    wcpBorrow,
    wcpHandle,
    wcpCallback
  );

  TWasmConnectorResultKind = (
    wcrVoid,
    wcrScalar,
    wcrBool,
    wcrHandle
  );

  { One lowered parameter. Scalar is the C type of a scalar or of an array's
    element. SizeConst is the element count, or -1 when parameter SizeParam
    carries it. }
  TWasmConnectorParam = record
    Kind: TWasmConnectorParamKind;
    Scalar: TWasmCScalar;
    Direction: TWlcDirection;
    ElemSize: UInt32;
    SizeConst: Integer;
    SizeParam: Integer;
    Shape: TWasmCallbackShape;
    Lifetime: TWlcCallbackKind;
  end;

  { The host-independent lowering of one resolved thunk. }
  TWasmConnectorCall = record
    Params: array of TWasmConnectorParam;
    ResultKind: TWasmConnectorResultKind;
    ResultScalar: TWasmCScalar;
    NeedsMemory: Boolean;
    Signature: TWasmCSignature;
  end;

  { Host-to-guest entry for callbacks: NativeInvoke in the runtime shell.
    nil means Wasm.Engine.Call (the interpreter trampoline). }
  TWasmConnectorInvoke = procedure(const AStore: TWasmStore;
    const AFuncAddr: TWasmFuncAddr; const AParams: PWasmValue;
    const AResults: PWasmValue);

  { Owns the loaded libraries, the per-import bindings, the memory session
    (copies, borrows, handles), and the callback hub for one store. Free
    after the instance handles and before the store. }
  TWasmConnectorHost = class
  private
    FStore: TWasmStore;
    FLibraries: array of TWasmNativeLibrary;
    FLibraryNames: array of string;
    FBindings: array of TObject;
    FPlan: TWlcConnectorPlan;
    FSession: TWasmConnectorSession;
    FHub: TWasmCallbackHub;
    FInvoke: TWasmConnectorInvoke;
    FInstance: TWasmModuleInstance;
    FMemory: TWasmMemoryRef;
    FHasMemory: Boolean;
    FNeedsMemory: Boolean;
    function LibraryFor(const AName, ALibraryDir: string): TWasmNativeLibrary;
    procedure GuestInvoke(const AFunc: TWasmFunc;
      const AArgs: array of TWasmValue; var AResults: array of TWasmValue);
    function CallbackFor(const AIndex: UInt32;
      const AParam: TWasmConnectorParam): Pointer;
    function Memory: TWasmMemoryRef;
  public
    { Lower every thunk, plan it for the host ABI, load every plan library
      from ALibraryDir (the executable directory in a compiled program), and
      look up every native symbol. Raises EWasmLinkError on any failure and
      loads nothing when a thunk cannot be lowered. }
    constructor Create(const AStore: TWasmStore;
      const APlan: TWlcConnectorPlan; const ALibraryDir: string;
      const AInvoke: TWasmConnectorInvoke);
    destructor Destroy; override;

    { Define one host function per guest import on ALinker. }
    procedure DefineImports(const ALinker: TWasmLinker);

    { Bind the instance whose exported `memory` buffers cross and whose
      table 0 delegates index. Call after instantiation, before the start
      function runs. A plan with array parameters and no exported memory is
      EWasmLinkError. }
    procedure Attach(const AInstance: TWasmInstance);

    { Deliver queued callback notifications, then rethrow a retained guest
      failure. The shell calls this when `_start` returns. }
    procedure DrainQueued;
  end;

const
  MSG_CONNECTOR_NO_MEMORY = 'connector memory is not attached';

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
  SysUtils,

  Wasm.Native.Call,
  Wasm.Runtime.Gc,
  Wasm.Runtime.Traps;

type
  TConnectorBinding = class
  public
    Host: TWasmConnectorHost;
    Fn: Pointer;
    Plan: TWasmAbiPlan;
    Call: TWasmConnectorCall;
  end;

const
  { Wasm.Abi and Wasm.Connector.Callbacks both spell wcsVoid / wcsI32. }
  C_VOID = Wasm.Abi.wcsVoid;
  C_I32 = Wasm.Abi.wcsI32;

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

function FindDelegate(const AConnector: TWlcConnector; const AName: string;
  out ADelegate: TWlcDelegate): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AConnector.Delegates) do
    if AConnector.Delegates[I].Name = AName then
    begin
      ADelegate := AConnector.Delegates[I];
      Exit(True);
    end;
  ADelegate := Default(TWlcDelegate);
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
    AScalar := C_I32
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
    wlmInt32: AScalar := C_I32;
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

function IsHandleDeclaration(const ARef: TWlcTypeRef;
  const AMarshal: TWlcMarshal): Boolean;
begin
  if ARef.IsArray then
    Exit(False);
  if AMarshal.Kind <> wlmDefault then
    Result := AMarshal.Kind in [wlmSysInt, wlmSysUInt]
  else
    Result := (ARef.Name = 'IntPtr') or (ARef.Name = 'nint') or
      (ARef.Name = 'UIntPtr') or (ARef.Name = 'nuint');
end;

{ The by-value scalar lowering of a type name (primitive or enum). }
function NamedScalar(const AConnector: TWlcConnector; const AName: string;
  out AScalar: TWasmCScalar): Boolean;
var
  I: Integer;
  Underlying: string;
begin
  if PrimitiveScalar(AName, AScalar) then
    Exit(True);
  for I := 0 to High(AConnector.Enums) do
    if AConnector.Enums[I].Name = AName then
    begin
      Underlying := AConnector.Enums[I].UnderlyingType;
      if Underlying = '' then
        Underlying := 'int';
      Exit(PrimitiveScalar(Underlying, AScalar));
    end;
  AScalar := C_VOID;
  Result := False;
end;

{ A plain by-value scalar: no array, modifier, or [Scoped]. }
function LowerScalar(const AConnector: TWlcConnector; const ARef: TWlcTypeRef;
  const AMarshal: TWlcMarshal; const AModifier: TWlcParamModifier;
  const AScoped: Boolean; out AScalar: TWasmCScalar): Boolean;
begin
  AScalar := C_VOID;
  if ARef.IsArray or (AModifier <> wpmNone) or AScoped then
    Exit(False);
  if AMarshal.Kind <> wlmDefault then
    Exit(MarshalScalar(AMarshal.Kind, AScalar));
  Result := NamedScalar(AConnector, ARef.Name, AScalar);
end;

function IsIntegerScalar(const AScalar: TWasmCScalar): Boolean;
begin
  Result := AScalar in [wcsI8, wcsU8, wcsI16, wcsU16, C_I32, wcsU32, wcsI64,
    wcsU64];
end;

function ScalarSize(const AScalar: TWasmCScalar): UInt32;
begin
  case AScalar of
    wcsI8, wcsU8: Result := 1;
    wcsI16, wcsU16: Result := 2;
    C_I32, wcsU32, wcsF32: Result := 4;
  else
    Result := 8;
  end;
end;

procedure RaiseUnsupported(const AThunk: TWlcResolvedThunk;
  const ADetail: string);
begin
  raise EWasmLinkError.CreateFmt('%s: "%s"."%s": %s',
    [MSG_WLC_UNSUPPORTED_TYPE, AThunk.GuestModule, AThunk.GuestName,
     ADetail]);
end;

function ScalarCType(const AScalar: TWasmCScalar): TWasmCType;
begin
  case AScalar of
    wcsI8: Result := AbiI8;
    wcsU8: Result := AbiU8;
    wcsI16: Result := AbiI16;
    wcsU16: Result := AbiU16;
    C_I32: Result := AbiI32;
    wcsU32: Result := AbiU32;
    wcsI64: Result := AbiI64;
    wcsU64: Result := AbiU64;
    wcsF32: Result := AbiF32;
    wcsF64: Result := AbiF64;
  else
    Result := AbiVoid;
  end;
end;

{ A delegate's callback shape: at most one i32-sized integer parameter and
  an optional i32-sized integer result. }
function DelegateShape(const AConnector: TWlcConnector;
  const ADelegate: TWlcDelegate; out AShape: TWasmCallbackShape): Boolean;
var
  Scalar: TWasmCScalar;
  HasParam, HasResult: Boolean;
begin
  AShape := Wasm.Connector.Callbacks.wcsVoid;
  if Length(ADelegate.Params) > 1 then
    Exit(False);
  HasParam := Length(ADelegate.Params) = 1;
  if HasParam then
  begin
    if IsBoolDeclaration(ADelegate.Params[0].TypeRef,
      ADelegate.Params[0].Marshal) or
      not LowerScalar(AConnector, ADelegate.Params[0].TypeRef,
      ADelegate.Params[0].Marshal, ADelegate.Params[0].Modifier,
      ADelegate.Params[0].IsScoped, Scalar) or
      not (Scalar in [C_I32, wcsU32]) then
      Exit(False);
  end;
  HasResult := ADelegate.ReturnType.Name <> 'void';
  if HasResult then
  begin
    if IsBoolDeclaration(ADelegate.ReturnType, ADelegate.ReturnMarshal) or
      not LowerScalar(AConnector, ADelegate.ReturnType,
      ADelegate.ReturnMarshal, wpmNone, False, Scalar) or
      not (Scalar in [C_I32, wcsU32]) then
      Exit(False);
  end;
  if HasResult and HasParam then
    AShape := Wasm.Connector.Callbacks.wcsI32I32
  else if HasResult then
    AShape := Wasm.Connector.Callbacks.wcsI32
  else if HasParam then
    AShape := Wasm.Connector.Callbacks.wcsVoidI32
  else
    AShape := Wasm.Connector.Callbacks.wcsVoid;
  Result := True;
end;

procedure LowerArray(const AThunk: TWlcResolvedThunk;
  const AConnector: TWlcConnector; const AIndex: Integer;
  var AParam: TWasmConnectorParam);
var
  Decl, Count: TWlcParam;
  CountScalar: TWasmCScalar;
  Name: string;
begin
  Decl := AThunk.Method.Params[AIndex];
  Name := Decl.TypeRef.Name + '[] ' + Decl.Name;
  if not (Decl.Marshal.Kind in [wlmDefault, wlmLPArray]) or
    not NamedScalar(AConnector, Decl.TypeRef.Name, AParam.Scalar) then
    RaiseUnsupported(AThunk, Name);
  AParam.ElemSize := ScalarSize(AParam.Scalar);
  if Decl.IsScoped then
    AParam.Kind := wcpBorrow
  else if Decl.Direction in [wldIn, wldOut, wldInOut] then
  begin
    AParam.Kind := wcpBuffer;
    AParam.Direction := Decl.Direction;
  end
  else
    RaiseUnsupported(AThunk, Name + ' needs [In], [Out], or [Scoped]');

  if Decl.Marshal.HasSizeConst = Decl.Marshal.HasSizeParamIndex then
    RaiseUnsupported(AThunk, Name +
      ' needs exactly one of SizeConst or SizeParamIndex');
  if Decl.Marshal.HasSizeConst then
  begin
    if Decl.Marshal.SizeConst < 0 then
      RaiseUnsupported(AThunk, Name + ' has a negative SizeConst');
    AParam.SizeConst := Decl.Marshal.SizeConst;
    AParam.SizeParam := -1;
    Exit;
  end;
  AParam.SizeConst := -1;
  AParam.SizeParam := Decl.Marshal.SizeParamIndex;
  if (AParam.SizeParam = AIndex) or
    (AParam.SizeParam > High(AThunk.Method.Params)) then
    RaiseUnsupported(AThunk, Name + ' SizeParamIndex names no count parameter');
  Count := AThunk.Method.Params[AParam.SizeParam];
  if IsBoolDeclaration(Count.TypeRef, Count.Marshal) or
    not LowerScalar(AConnector, Count.TypeRef, Count.Marshal, Count.Modifier,
    Count.IsScoped, CountScalar) or not IsIntegerScalar(CountScalar) then
    RaiseUnsupported(AThunk, Name +
      ' SizeParamIndex names a parameter that is not an integer');
end;

function LowerParam(const AThunk: TWlcResolvedThunk;
  const AConnector: TWlcConnector; const AIndex: Integer):
  TWasmConnectorParam;
var
  Decl: TWlcParam;
  Delegate: TWlcDelegate;
begin
  Decl := AThunk.Method.Params[AIndex];
  Result := Default(TWasmConnectorParam);
  Result.SizeParam := -1;
  if Decl.Modifier <> wpmNone then
    RaiseUnsupported(AThunk, Decl.TypeRef.Name + ' ' + Decl.Name +
      ' passed by reference');
  if Decl.TypeRef.IsArray then
  begin
    LowerArray(AThunk, AConnector, AIndex, Result);
    Exit;
  end;
  if Decl.IsScoped then
    RaiseUnsupported(AThunk, '[Scoped] ' + Decl.TypeRef.Name);
  if IsHandleDeclaration(Decl.TypeRef, Decl.Marshal) then
  begin
    Result.Kind := wcpHandle;
    Exit;
  end;
  if (Decl.Marshal.Kind = wlmDefault) and
    FindDelegate(AConnector, Decl.TypeRef.Name, Delegate) then
  begin
    if not DelegateShape(AConnector, Delegate, Result.Shape) then
      RaiseUnsupported(AThunk, 'delegate ' + Delegate.Name);
    Result.Kind := wcpCallback;
    Result.Lifetime := Delegate.CallbackKind;
    Exit;
  end;
  if not LowerScalar(AConnector, Decl.TypeRef, Decl.Marshal, wpmNone, False,
    Result.Scalar) then
    RaiseUnsupported(AThunk, Decl.TypeRef.Name);
  if IsBoolDeclaration(Decl.TypeRef, Decl.Marshal) then
    Result.Kind := wcpBool
  else
    Result.Kind := wcpScalar;
end;

function LowerConnectorThunk(const APlan: TWlcConnectorPlan;
  const AIndex: Integer): TWasmConnectorCall;
var
  Thunk: TWlcResolvedThunk;
  Connector: TWlcConnector;
  I: Integer;
  Params: array of TWasmCType;
  ResultType: TWasmCType;
begin
  Thunk := APlan.Thunks[AIndex];
  if not FindConnector(APlan, Thunk.ConnectorName, Connector) then
    RaiseUnsupported(Thunk, Thunk.ConnectorName);
  Result.Params := nil;
  Result.NeedsMemory := False;
  SetLength(Result.Params, Length(Thunk.Method.Params));
  SetLength(Params, Length(Thunk.Method.Params));
  for I := 0 to High(Thunk.Method.Params) do
  begin
    Result.Params[I] := LowerParam(Thunk, Connector, I);
    case Result.Params[I].Kind of
      wcpScalar:
        Params[I] := ScalarCType(Result.Params[I].Scalar);
      wcpBool:
        Params[I] := AbiU8;
    else
      Params[I] := AbiPointer;
    end;
    if Result.Params[I].Kind in [wcpBuffer, wcpBorrow] then
      Result.NeedsMemory := True;
  end;

  Result.ResultScalar := C_VOID;
  ResultType := AbiVoid;
  if Thunk.Method.ReturnType.Name = 'void' then
    Result.ResultKind := wcrVoid
  else if IsHandleDeclaration(Thunk.Method.ReturnType,
    Thunk.Method.ReturnMarshal) then
  begin
    Result.ResultKind := wcrHandle;
    ResultType := AbiPointer;
  end
  else if LowerScalar(Connector, Thunk.Method.ReturnType,
    Thunk.Method.ReturnMarshal, wpmNone, False, Result.ResultScalar) then
  begin
    if IsBoolDeclaration(Thunk.Method.ReturnType,
      Thunk.Method.ReturnMarshal) then
      Result.ResultKind := wcrBool
    else
      Result.ResultKind := wcrScalar;
    ResultType := ScalarCType(Result.ResultScalar);
  end
  else
    RaiseUnsupported(Thunk, 'return ' + Thunk.Method.ReturnType.Name);
  Result.Signature := AbiSignature(Params, ResultType);
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

{ --- values --------------------------------------------------------------- }

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
    C_I32: Result := AbiValueI64(AValue.I32);
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
    C_I32, wcsU32: Result := MakeValueI32(AbiValueAsI32(AValue));
    wcsI64, wcsU64: Result := MakeValueI64(AbiValueAsI64(AValue));
    wcsF32: Result := MakeValueF32(AbiValueAsF32(AValue));
    wcsF64: Result := MakeValueF64(AbiValueAsF64(AValue));
  else
    Result := MakeValueI32(0);
  end;
end;

{ An element count as the C callee sees it. A negative signed count names
  no guest range, so it traps like any other out-of-range transfer. }
function CountArgument(const AScalar: TWasmCScalar;
  const AValue: TWasmValue): UInt64;
var
  Signed: Int64;
begin
  case AScalar of
    wcsI8: Signed := Int8(AValue.I32);
    wcsI16: Signed := Int16(AValue.I32);
    C_I32: Signed := AValue.I32;
    wcsI64: Signed := AValue.I64;
    wcsU8: Exit(UInt8(AValue.U32));
    wcsU16: Exit(UInt16(AValue.U32));
    wcsU32: Exit(AValue.U32);
  else
    Exit(AValue.U64);
  end;
  if Signed < 0 then
    raise EWasmTrap.Create(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
  Result := UInt64(Signed);
end;

{ The guest byte range of an array argument, checked against the memory
  before any native code runs. }
function ByteLength(const ACall: TWasmConnectorCall; const AIndex: Integer;
  const AParams: PWasmValue; const AMemory: TWasmMemoryRef;
  const AOffset: UInt64): UInt64;
var
  P: TWasmConnectorParam;
  Count: UInt64;
  CountScalar: TWasmCScalar;
  Size: UInt64;
begin
  P := ACall.Params[AIndex];
  if P.SizeConst >= 0 then
    Count := UInt64(P.SizeConst)
  else
  begin
    CountScalar := ACall.Params[P.SizeParam].Scalar;
    Count := CountArgument(CountScalar, AParams[P.SizeParam]);
  end;
  if (P.ElemSize > 0) and (Count > High(UInt64) div P.ElemSize) then
    raise EWasmTrap.Create(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
  Result := Count * P.ElemSize;
  Size := MemSize(AMemory);
  if (AOffset > Size) or (Result > Size - AOffset) then
    raise EWasmTrap.Create(MSG_TRAP_MEMORY_OUT_OF_BOUNDS);
end;

{ --- the host function ---------------------------------------------------- }

type
  TBorrowArray = array of TWasmConnectorBorrow;
  TBufferArray = array of TBytes;

procedure ReleaseBorrows(var ABorrows: TBorrowArray);
var
  I: Integer;
begin
  for I := 0 to High(ABorrows) do
    FreeAndNil(ABorrows[I]);
end;

procedure ConnectorHostCall(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
var
  Binding: TConnectorBinding;
  Host: TWasmConnectorHost;
  Call: TWasmConnectorCall;
  Args: array of TWasmAbiValue;
  Buffers: TBufferArray;
  Borrows: TBorrowArray;
  Ret: TWasmAbiValue;
  I, Mark: Integer;
  Offset, Len: UInt64;
  Handle: TWasmConnectorHandle;
  Native: Pointer;
begin
  Binding := TConnectorBinding(AData);
  Host := Binding.Host;
  Call := Binding.Call;
  Args := nil;
  Buffers := nil;
  Borrows := nil;
  SetLength(Args, Length(Call.Params));
  SetLength(Buffers, Length(Call.Params));
  SetLength(Borrows, Length(Call.Params));
  Ret.Data := nil;

  Mark := Host.FHub.BeginScope;
  try
    for I := 0 to High(Call.Params) do
      case Call.Params[I].Kind of
        wcpScalar:
          Args[I] := ScalarArgument(Call.Params[I].Scalar, AParams[I]);
        wcpBool:
          Args[I] := AbiValueU64(Ord(AParams[I].I32 <> 0));
        wcpHandle:
          if AParams[I].U32 = 0 then
            Args[I] := AbiValuePointer(nil)
          else
            Args[I] := AbiValuePointer(
              Host.FSession.ResolveHandle(AParams[I].U32));
        wcpCallback:
          Args[I] := AbiValuePointer(Host.CallbackFor(AParams[I].U32,
            Call.Params[I]));
        wcpBuffer:
          begin
            Offset := AParams[I].U32;
            Len := ByteLength(Call, I, AParams, Host.Memory, Offset);
            SetLength(Buffers[I], Len);
            if Len > 0 then
            begin
              if Call.Params[I].Direction in [wldIn, wldInOut] then
                Host.FSession.CopyIn(Host.Memory, Offset, Len, @Buffers[I][0])
              else
                FillChar(Buffers[I][0], Len, 0);
              Args[I] := AbiValuePointer(@Buffers[I][0]);
            end
            else
              Args[I] := AbiValuePointer(nil);
          end;
        wcpBorrow:
          begin
            Offset := AParams[I].U32;
            Len := ByteLength(Call, I, AParams, Host.Memory, Offset);
            Borrows[I] := Host.FSession.Borrow(Host.Memory, Offset, Len);
            Args[I] := AbiValuePointer(Borrows[I].Data);
          end;
      end;
    ApplyNativeCall(Binding.Plan, Binding.Fn, Args, Ret);
  finally
    ReleaseBorrows(Borrows);
    Host.FHub.EndScope(Mark);
  end;

  { A guest failure a callback retained surfaces here, on Pascal ground,
    before anything is written back. }
  Host.FHub.RethrowDeferred;

  for I := 0 to High(Call.Params) do
    if (Call.Params[I].Kind = wcpBuffer) and
      (Call.Params[I].Direction in [wldOut, wldInOut]) and
      (Length(Buffers[I]) > 0) then
      Host.FSession.CopyOut(Host.Memory, AParams[I].U32,
        UInt64(Length(Buffers[I])), @Buffers[I][0]);

  case Call.ResultKind of
    wcrScalar:
      AResults^ := ScalarResult(Call.ResultScalar, Ret);
    wcrBool:
      AResults^ := MakeValueI32(Ord(UInt8(AbiValueAsI32(Ret)) <> 0));
    wcrHandle:
      begin
        Native := AbiValueAsPointer(Ret);
        if Native = nil then
          Handle := 0
        else
          Handle := Host.FSession.AllocHandle(Native);
        AResults^ := MakeValueU32(Handle);
      end;
  end;

  Host.FHub.DrainQueued;
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

constructor TWasmConnectorHost.Create(const AStore: TWasmStore;
  const APlan: TWlcConnectorPlan; const ALibraryDir: string;
  const AInvoke: TWasmConnectorInvoke);
var
  I: Integer;
  Binding: TConnectorBinding;
  Calls: array of TWasmConnectorCall;
  Plans: array of TWasmAbiPlan;
begin
  inherited Create;
  FStore := AStore;
  FPlan := APlan;
  FInvoke := AInvoke;
  { Every thunk lowers and plans before any library is opened, so an
    unsupported or incompatible plan loads nothing. }
  SetLength(Calls, Length(APlan.Thunks));
  SetLength(Plans, Length(APlan.Thunks));
  for I := 0 to High(APlan.Thunks) do
  begin
    Plans[I] := PlanThunk(APlan, I, AbiHostTarget, Calls[I]);
    if Calls[I].NeedsMemory then
      FNeedsMemory := True;
  end;
  FSession := TWasmConnectorSession.Create(AStore);
  FHub := TWasmCallbackHub.Create(AStore);
  FHub.Invoke := GuestInvoke;
  for I := 0 to High(APlan.Libraries) do
    LibraryFor(APlan.Libraries[I], ALibraryDir);
  SetLength(FBindings, Length(APlan.Thunks));
  for I := 0 to High(APlan.Thunks) do
  begin
    Binding := TConnectorBinding.Create;
    FBindings[I] := Binding;
    Binding.Host := Self;
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
  { The hub first: it releases thunk slots and their roots while the store
    is still alive. Libraries last, after nothing can call into them. }
  FreeAndNil(FHub);
  FreeAndNil(FSession);
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

procedure TWasmConnectorHost.Attach(const AInstance: TWasmInstance);
begin
  FInstance := AInstance.Raw;
  FHasMemory := AInstance.FindExportMemory('memory', FMemory);
  if FNeedsMemory and not FHasMemory then
    raise EWasmLinkError.Create(
      'connector buffers need an exported "memory"');
end;

function TWasmConnectorHost.Memory: TWasmMemoryRef;
begin
  if not FHasMemory then
    raise EWasmConnectorError.Create(MSG_CONNECTOR_NO_MEMORY);
  Result := FMemory;
end;

procedure TWasmConnectorHost.DrainQueued;
begin
  FHub.DrainQueued;
end;

{ Resolve table 0 entry AIndex exactly as call_indirect would, then hand out
  the thunk for the delegate's shape and lifetime. }
function TWasmConnectorHost.CallbackFor(const AIndex: UInt32;
  const AParam: TWasmConnectorParam): Pointer;
var
  TableAddr: TWasmTableAddr;
  R: TWasmRef;
  Fn: TWasmFunc;
  FuncType: TWasmFuncType;
  Expected: Integer;
  I: Integer;
begin
  if (FInstance = nil) or (Length(FInstance.TableAddrs) = 0) then
    raise EWasmTrap.Create(MSG_TRAP_UNDEFINED_ELEMENT);
  TableAddr := FInstance.TableAddrs[0];
  if UInt64(AIndex) >= UInt64(Length(FStore.Tables[TableAddr].Elems)) then
    raise EWasmTrap.Create(MSG_TRAP_UNDEFINED_ELEMENT);
  R := FStore.Tables[TableAddr].Elems[AIndex];
  if RefIsNull(R) then
    raise EWasmTrap.Create(MSG_TRAP_UNINITIALIZED_ELEMENT);
  if RefIsI31(R) or (GcRefKind(R) <> wokFuncRef) then
    raise EWasmTrap.Create(MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH);

  Fn.Store := FStore;
  Fn.Addr := FStore.FuncRefAddr(R);
  FuncType := FStore.Engine.EngineType(FStore.Funcs[Fn.Addr].TypeId).Comp.Func;
  Fn.ParamTypes := FuncType.Params;
  Fn.ResultTypes := FuncType.Results;

  case AParam.Shape of
    Wasm.Connector.Callbacks.wcsVoidI32, Wasm.Connector.Callbacks.wcsI32I32:
      Expected := 1;
  else
    Expected := 0;
  end;
  if Length(FuncType.Params) <> Expected then
    raise EWasmTrap.Create(MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH);
  if AParam.Shape in [Wasm.Connector.Callbacks.wcsI32,
    Wasm.Connector.Callbacks.wcsI32I32] then
    Expected := 1
  else
    Expected := 0;
  if Length(FuncType.Results) <> Expected then
    raise EWasmTrap.Create(MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH);
  for I := 0 to High(FuncType.Params) do
    if (FuncType.Params[I].Kind <> wvkNum) or
      (FuncType.Params[I].Num <> wntI32) then
      raise EWasmTrap.Create(MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH);
  for I := 0 to High(FuncType.Results) do
    if (FuncType.Results[I].Kind <> wvkNum) or
      (FuncType.Results[I].Num <> wntI32) then
      raise EWasmTrap.Create(MSG_TRAP_INDIRECT_CALL_TYPE_MISMATCH);

  Result := FHub.Bind(Fn, AParam.Shape, AParam.Lifetime);
end;

{ The hub's re-entry: the borrow fence first (a live scoped borrow cannot
  take part in a callback), then the configured invoke. }
procedure TWasmConnectorHost.GuestInvoke(const AFunc: TWasmFunc;
  const AArgs: array of TWasmValue; var AResults: array of TWasmValue);
var
  Params, Results: array of TWasmValue;
  I: Integer;
  ParamPtr, ResultPtr: PWasmValue;
begin
  FSession.EnsureCallbackAllowed;
  if not Assigned(FInvoke) then
  begin
    Wasm.Engine.Call(AFunc, AArgs, AResults);
    Exit;
  end;
  SetLength(Params, Length(AArgs));
  for I := 0 to High(AArgs) do
    Params[I] := AArgs[I];
  SetLength(Results, Length(AResults));
  ParamPtr := nil;
  ResultPtr := nil;
  if Length(Params) > 0 then
    ParamPtr := @Params[0];
  if Length(Results) > 0 then
    ResultPtr := @Results[0];
  FInvoke(AFunc.Store, AFunc.Addr, ParamPtr, ResultPtr);
  for I := 0 to High(Results) do
    AResults[I] := Results[I];
end;

end.
