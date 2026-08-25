{ Wasm.Connector.Resolve — unique, deny-by-default connector plans.

  After marshalling, every non-built-in guest import matches exactly one
  declaration by (connector class, method name). EntryPoint is the native
  symbol only: it never participates in guest matching, reorders arguments,
  or adapts types. Missing, duplicate, incompatible, and ambiguous bindings
  are EWasmLinkError. The returned plan keeps only required libraries,
  symbols, types, and thunk identities.

  This unit does not parse `.wlc`, load a library, emit a call thunk, or
  search PATH. Built-in module names are whatever the caller lists. }
unit Wasm.Connector.Resolve;

{$I Shared.inc}

interface

uses
  Wasm.Connector,
  Wasm.Core,
  Wasm.Module;

type
  TWlcGuestImport = record
    ModuleName: string;
    Name: string;
    Kind: TWasmExternKind;
    Func: TWasmFuncType;
  end;

  TWlcGuestImportArray = array of TWlcGuestImport;

  { One resolved host call. NativeSymbol is EntryPoint (or the method name
    when the declaration omitted it). Machine-code thunks are issue #43. }
  TWlcResolvedThunk = record
    GuestModule: string;
    GuestName: string;
    LibraryName: string;
    NativeSymbol: string;
    ConnectorName: string;
    Method: TWlcMethod;
    Func: TWasmFuncType;
  end;

  TWlcConnectorPlan = record
    Thunks: array of TWlcResolvedThunk;
    Libraries: array of string;
    Connectors: array of TWlcConnector;
  end;

const
  { Spec link prefixes, same spelling as Wasm.Runtime.Traps. }
  MSG_WLC_UNKNOWN_IMPORT = 'unknown import';
  MSG_WLC_INCOMPATIBLE_IMPORT = 'incompatible import type';
  MSG_WLC_DUPLICATE_BINDING = 'duplicate connector binding';
  MSG_WLC_AMBIGUOUS_BINDING = 'ambiguous connector binding';
  MSG_WLC_UNSUPPORTED_TYPE = 'unsupported connector type';

  WLC_WASI_MODULE = 'wasi_snapshot_preview1';

function WlcGuestImportsFromModule(const AModule: TWasmModule):
  TWlcGuestImportArray;

function ResolveConnectorPlan(
  const ADocuments: array of TWlcDocument;
  const AImports: array of TWlcGuestImport;
  const ABuiltInModules: array of string): TWlcConnectorPlan;

function ResolveConnectorModule(
  const ADocuments: array of TWlcDocument;
  const AModule: TWasmModule;
  const ABuiltInModules: array of string): TWlcConnectorPlan;

implementation

type
  TCandidate = record
    ConnectorIndex: Integer;
    MethodIndex: Integer;
  end;

  TCandidateArray = array of TCandidate;
  TStringArray = array of string;

  TWorkConnector = record
    Decl: TWlcConnector;
    MethodUsed: array of Boolean;
    StructUsed: array of Boolean;
    EnumUsed: array of Boolean;
    DelegateUsed: array of Boolean;
    AnyUsed: Boolean;
  end;

  TWorkConnectorArray = array of TWorkConnector;

function NativeSymbolOf(const AMethod: TWlcMethod): string;
begin
  if AMethod.EntryPoint <> '' then
    Result := AMethod.EntryPoint
  else
    Result := AMethod.Name;
end;

function SameTypeRef(const A, B: TWlcTypeRef): Boolean;
begin
  Result := (A.Name = B.Name) and (A.IsArray = B.IsArray);
end;

function SameMarshal(const A, B: TWlcMarshal): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.HasSizeConst = B.HasSizeConst) and
    ((not A.HasSizeConst) or (A.SizeConst = B.SizeConst));
end;

function SameParam(const A, B: TWlcParam): Boolean;
begin
  Result := SameTypeRef(A.TypeRef, B.TypeRef) and
    (A.Modifier = B.Modifier) and (A.Direction = B.Direction) and
    SameMarshal(A.Marshal, B.Marshal) and (A.IsScoped = B.IsScoped);
end;

function MethodsDeclarationEqual(const A, B: TWlcMethod): Boolean;
var
  Index: Integer;
begin
  if (A.LibraryName <> B.LibraryName) or
    (NativeSymbolOf(A) <> NativeSymbolOf(B)) or
    (not SameTypeRef(A.ReturnType, B.ReturnType)) or
    (not SameMarshal(A.ReturnMarshal, B.ReturnMarshal)) or
    (Length(A.Params) <> Length(B.Params)) then
    Exit(False);
  for Index := 0 to High(A.Params) do
    if not SameParam(A.Params[Index], B.Params[Index]) then
      Exit(False);
  Result := True;
end;

function ValueTypeEquals(const A, B: TWasmValueType): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    wvkNum:
      Result := A.Num = B.Num;
    wvkVec:
      Result := True;
    wvkRef:
      begin
        if A.Ref.Nullable <> B.Ref.Nullable then
          Exit(False);
        if A.Ref.Heap.IsAbstract <> B.Ref.Heap.IsAbstract then
          Exit(False);
        if A.Ref.Heap.IsAbstract then
          Result := A.Ref.Heap.Abs = B.Ref.Heap.Abs
        else
          Result := A.Ref.Heap.TypeIndex = B.Ref.Heap.TypeIndex;
      end;
  else
    Result := False;
  end;
end;

function FuncSignatureMatches(const A, B: TWasmFuncType): Boolean;
var
  Index: Integer;
begin
  if (Length(A.Params) <> Length(B.Params)) or
    (Length(A.Results) <> Length(B.Results)) then
    Exit(False);
  for Index := 0 to High(A.Params) do
    if not ValueTypeEquals(A.Params[Index], B.Params[Index]) then
      Exit(False);
  for Index := 0 to High(A.Results) do
    if not ValueTypeEquals(A.Results[Index], B.Results[Index]) then
      Exit(False);
  Result := True;
end;

function ModuleFuncType(const AModule: TWasmModule; const ATypeIndex: UInt32;
  out AFunc: TWasmFuncType): Boolean;
var
  Group, Member, Cursor: Integer;
  Sub: TWasmSubType;
begin
  AFunc.Params := nil;
  AFunc.Results := nil;
  Cursor := 0;
  for Group := 0 to AModule.TypeCount - 1 do
    for Member := 0 to High(AModule.Types[Group].SubTypes) do
    begin
      if UInt32(Cursor) = ATypeIndex then
      begin
        Sub := AModule.Types[Group].SubTypes[Member];
        if Sub.Comp.Kind <> wckFunc then
          Exit(False);
        AFunc := Sub.Comp.Func;
        Exit(True);
      end;
      Inc(Cursor);
    end;
  Result := False;
end;

function WlcGuestImportsFromModule(const AModule: TWasmModule):
  TWlcGuestImportArray;
var
  Index: Integer;
  Imp: TWasmImport;
  Guest: TWlcGuestImport;
begin
  if AModule = nil then
    raise EWasmError.Create('connector resolve needs a module');
  Result := nil;
  SetLength(Result, AModule.ImportCount);
  for Index := 0 to AModule.ImportCount - 1 do
  begin
    Imp := AModule.Imports[Index];
    Guest := Default(TWlcGuestImport);
    Guest.ModuleName := Imp.ModuleName;
    Guest.Name := Imp.Name;
    Guest.Kind := Imp.Kind;
    if Imp.Kind = wxkFunc then
      if not ModuleFuncType(AModule, Imp.FuncTypeIndex, Guest.Func) then
        raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
          [MSG_WLC_INCOMPATIBLE_IMPORT, Imp.ModuleName, Imp.Name]);
    Result[Index] := Guest;
  end;
end;

function IsBuiltInModule(const AName: string;
  const ABuiltInModules: array of string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(ABuiltInModules) do
    if ABuiltInModules[Index] = AName then
      Exit(True);
  Result := False;
end;

function FindEnum(const AConnector: TWlcConnector; const AName: string;
  out AEnum: TWlcEnum): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(AConnector.Enums) do
    if AConnector.Enums[Index].Name = AName then
    begin
      AEnum := AConnector.Enums[Index];
      Exit(True);
    end;
  Result := False;
end;

function FindStruct(const AConnector: TWlcConnector; const AName: string;
  out AStruct: TWlcStruct): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(AConnector.Structs) do
    if AConnector.Structs[Index].Name = AName then
    begin
      AStruct := AConnector.Structs[Index];
      Exit(True);
    end;
  Result := False;
end;

function FindDelegate(const AConnector: TWlcConnector; const AName: string;
  out ADelegate: TWlcDelegate): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(AConnector.Delegates) do
    if AConnector.Delegates[Index].Name = AName then
    begin
      ADelegate := AConnector.Delegates[Index];
      Exit(True);
    end;
  Result := False;
end;

function PrimitiveNum(const AName: string; out ANum: TWasmNumType): Boolean;
begin
  Result := True;
  if (AName = 'bool') or (AName = 'Boolean') or (AName = 'sbyte') or
    (AName = 'SByte') or (AName = 'byte') or (AName = 'Byte') or
    (AName = 'short') or (AName = 'Int16') or (AName = 'ushort') or
    (AName = 'UInt16') or (AName = 'char') or (AName = 'Char') or
    (AName = 'int') or (AName = 'Int32') or (AName = 'uint') or
    (AName = 'UInt32') then
    ANum := wntI32
  else if (AName = 'long') or (AName = 'Int64') or (AName = 'ulong') or
    (AName = 'UInt64') then
    ANum := wntI64
  else if (AName = 'float') or (AName = 'Single') then
    ANum := wntF32
  else if (AName = 'double') or (AName = 'Double') then
    ANum := wntF64
  else
    Result := False;
end;

function MarshalToNum(const AKind: TWlcMarshalKind;
  out ANum: TWasmNumType; out AIsPointer: Boolean): Boolean;
begin
  Result := True;
  AIsPointer := False;
  case AKind of
    wlmInt8, wlmUInt8, wlmInt16, wlmUInt16, wlmInt32, wlmUInt32, wlmBool:
      ANum := wntI32;
    wlmInt64, wlmUInt64:
      ANum := wntI64;
    wlmFloat32:
      ANum := wntF32;
    wlmFloat64:
      ANum := wntF64;
    wlmLPStr, wlmLPWStr, wlmLPUTF8Str, wlmLPArray, wlmByValArray,
      wlmSysInt, wlmSysUInt:
      begin
        ANum := wntI32;
        AIsPointer := True;
      end;
  else
    Result := False;
  end;
end;

function IsPointerName(const AName: string): Boolean;
begin
  Result := (AName = 'string') or (AName = 'String') or
    (AName = 'nint') or (AName = 'nuint') or
    (AName = 'IntPtr') or (AName = 'UIntPtr');
end;

function LowerType(const AConnector: TWlcConnector; const ARef: TWlcTypeRef;
  const AMarshal: TWlcMarshal; const AModifier: TWlcParamModifier;
  out AType: TWasmValueType): Boolean;
var
  Num: TWasmNumType;
  IsPointer: Boolean;
  EnumDecl: TWlcEnum;
  StructDecl: TWlcStruct;
  DelegateDecl: TWlcDelegate;
begin
  AType := Default(TWasmValueType);
  if ARef.Name = '' then
    Exit(False);
  if ARef.Name = 'void' then
    Exit(False);

  if AMarshal.Kind <> wlmDefault then
  begin
    if not MarshalToNum(AMarshal.Kind, Num, IsPointer) then
      Exit(False);
    AType := MakeNumValueType(Num);
    Exit(True);
  end;

  if ARef.IsArray or IsPointerName(ARef.Name) or
    FindStruct(AConnector, ARef.Name, StructDecl) or
    FindDelegate(AConnector, ARef.Name, DelegateDecl) or
    (AModifier <> wpmNone) then
  begin
    AType := MakeNumValueType(wntI32);
    Exit(True);
  end;

  if PrimitiveNum(ARef.Name, Num) then
  begin
    AType := MakeNumValueType(Num);
    Exit(True);
  end;

  if FindEnum(AConnector, ARef.Name, EnumDecl) then
  begin
    if (EnumDecl.UnderlyingType = '') or (EnumDecl.UnderlyingType = 'int') or
      (EnumDecl.UnderlyingType = 'Int32') then
      AType := MakeNumValueType(wntI32)
    else if (EnumDecl.UnderlyingType = 'long') or
      (EnumDecl.UnderlyingType = 'Int64') then
      AType := MakeNumValueType(wntI64)
    else if not PrimitiveNum(EnumDecl.UnderlyingType, Num) then
      Exit(False)
    else
      AType := MakeNumValueType(Num);
    Exit(True);
  end;

  Result := False;
end;

function LowerMethod(const AConnector: TWlcConnector; const AMethod: TWlcMethod;
  out AFunc: TWasmFuncType; out AFailName: string): Boolean;
var
  Index: Integer;
  ValueType: TWasmValueType;
begin
  AFunc.Params := nil;
  AFunc.Results := nil;
  AFailName := '';
  SetLength(AFunc.Params, Length(AMethod.Params));
  for Index := 0 to High(AMethod.Params) do
    if not LowerType(AConnector, AMethod.Params[Index].TypeRef,
      AMethod.Params[Index].Marshal, AMethod.Params[Index].Modifier,
      AFunc.Params[Index]) then
    begin
      AFailName := AMethod.Params[Index].TypeRef.Name;
      Exit(False);
    end;
  if AMethod.ReturnType.Name = 'void' then
    Exit(True);
  if not LowerType(AConnector, AMethod.ReturnType, AMethod.ReturnMarshal,
    wpmNone, ValueType) then
  begin
    AFailName := AMethod.ReturnType.Name;
    Exit(False);
  end;
  SetLength(AFunc.Results, 1);
  AFunc.Results[0] := ValueType;
  Result := True;
end;

procedure RaiseLink(const APrefix, AModule, AName: string);
begin
  raise EWasmLinkError.CreateFmt('%s: "%s"."%s"',
    [APrefix, AModule, AName]);
end;

procedure RaiseUnsupported(const AModule, AName, ATypeName: string);
begin
  raise EWasmLinkError.CreateFmt('%s: "%s"."%s": %s',
    [MSG_WLC_UNSUPPORTED_TYPE, AModule, AName, ATypeName]);
end;

procedure CollectConnectors(const ADocuments: array of TWlcDocument;
  out AWork: TWorkConnectorArray);
var
  DocIndex, ConnIndex, Count: Integer;
begin
  Count := 0;
  for DocIndex := 0 to High(ADocuments) do
    Inc(Count, Length(ADocuments[DocIndex].Connectors));
  SetLength(AWork, Count);
  Count := 0;
  for DocIndex := 0 to High(ADocuments) do
    for ConnIndex := 0 to High(ADocuments[DocIndex].Connectors) do
    begin
      AWork[Count].Decl := ADocuments[DocIndex].Connectors[ConnIndex];
      SetLength(AWork[Count].MethodUsed, Length(AWork[Count].Decl.Methods));
      SetLength(AWork[Count].StructUsed, Length(AWork[Count].Decl.Structs));
      SetLength(AWork[Count].EnumUsed, Length(AWork[Count].Decl.Enums));
      SetLength(AWork[Count].DelegateUsed, Length(AWork[Count].Decl.Delegates));
      AWork[Count].AnyUsed := False;
      Inc(Count);
    end;
end;

function FindCandidates(const AWork: TWorkConnectorArray;
  const AModule, AName: string): TCandidateArray;
var
  ConnIndex, MethodIndex: Integer;
begin
  Result := nil;
  for ConnIndex := 0 to High(AWork) do
    if AWork[ConnIndex].Decl.Name = AModule then
      for MethodIndex := 0 to High(AWork[ConnIndex].Decl.Methods) do
        if AWork[ConnIndex].Decl.Methods[MethodIndex].Name = AName then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)].ConnectorIndex := ConnIndex;
          Result[High(Result)].MethodIndex := MethodIndex;
        end;
end;

procedure RejectNonUnique(const AWork: TWorkConnectorArray);
var
  ConnIndex, MethodIndex: Integer;
  Seen: TCandidateArray;
  First: TWlcMethod;
  Other: TWlcMethod;
  AllEqual: Boolean;
  Index: Integer;
  KeyModule, KeyName: string;
begin
  { Every (class, method) group is checked once: walk declarations in
    order and skip a name whose earlier sibling already represented it. }
  for ConnIndex := 0 to High(AWork) do
    for MethodIndex := 0 to High(AWork[ConnIndex].Decl.Methods) do
    begin
      KeyModule := AWork[ConnIndex].Decl.Name;
      KeyName := AWork[ConnIndex].Decl.Methods[MethodIndex].Name;
      Seen := FindCandidates(AWork, KeyModule, KeyName);
      if Length(Seen) < 2 then
        Continue;
      if (Seen[0].ConnectorIndex <> ConnIndex) or
        (Seen[0].MethodIndex <> MethodIndex) then
        Continue;
      First := AWork[Seen[0].ConnectorIndex].Decl.Methods[Seen[0].MethodIndex];
      AllEqual := True;
      for Index := 1 to High(Seen) do
      begin
        Other := AWork[Seen[Index].ConnectorIndex].Decl.Methods[
          Seen[Index].MethodIndex];
        if not MethodsDeclarationEqual(First, Other) then
        begin
          AllEqual := False;
          Break;
        end;
      end;
      if AllEqual then
        RaiseLink(MSG_WLC_DUPLICATE_BINDING, KeyModule, KeyName)
      else
        RaiseLink(MSG_WLC_AMBIGUOUS_BINDING, KeyModule, KeyName);
    end;
end;

procedure MarkTypeUsed(var AWork: TWorkConnector; const ARef: TWlcTypeRef);
  forward;

procedure MarkStructUsed(var AWork: TWorkConnector; const AIndex: Integer);
var
  FieldIndex: Integer;
begin
  if AWork.StructUsed[AIndex] then
    Exit;
  AWork.StructUsed[AIndex] := True;
  for FieldIndex := 0 to High(AWork.Decl.Structs[AIndex].Fields) do
    MarkTypeUsed(AWork, AWork.Decl.Structs[AIndex].Fields[FieldIndex].TypeRef);
end;

procedure MarkDelegateUsed(var AWork: TWorkConnector; const AIndex: Integer);
var
  ParamIndex: Integer;
begin
  if AWork.DelegateUsed[AIndex] then
    Exit;
  AWork.DelegateUsed[AIndex] := True;
  MarkTypeUsed(AWork, AWork.Decl.Delegates[AIndex].ReturnType);
  for ParamIndex := 0 to High(AWork.Decl.Delegates[AIndex].Params) do
    MarkTypeUsed(AWork, AWork.Decl.Delegates[AIndex].Params[ParamIndex].TypeRef);
end;

procedure MarkTypeUsed(var AWork: TWorkConnector; const ARef: TWlcTypeRef);
var
  Index: Integer;
begin
  if ARef.Name = '' then
    Exit;
  for Index := 0 to High(AWork.Decl.Structs) do
    if AWork.Decl.Structs[Index].Name = ARef.Name then
    begin
      MarkStructUsed(AWork, Index);
      Exit;
    end;
  for Index := 0 to High(AWork.Decl.Enums) do
    if AWork.Decl.Enums[Index].Name = ARef.Name then
    begin
      AWork.EnumUsed[Index] := True;
      Exit;
    end;
  for Index := 0 to High(AWork.Decl.Delegates) do
    if AWork.Decl.Delegates[Index].Name = ARef.Name then
    begin
      MarkDelegateUsed(AWork, Index);
      Exit;
    end;
end;

procedure MarkMethodUsed(var AWork: TWorkConnector; const AMethodIndex: Integer);
var
  ParamIndex: Integer;
begin
  if AWork.MethodUsed[AMethodIndex] then
    Exit;
  AWork.MethodUsed[AMethodIndex] := True;
  AWork.AnyUsed := True;
  MarkTypeUsed(AWork, AWork.Decl.Methods[AMethodIndex].ReturnType);
  for ParamIndex := 0 to High(AWork.Decl.Methods[AMethodIndex].Params) do
    MarkTypeUsed(AWork, AWork.Decl.Methods[AMethodIndex].Params[ParamIndex].TypeRef);
end;

procedure AppendStringUnique(var AItems: TStringArray; const AValue: string);
var
  Index: Integer;
begin
  for Index := 0 to High(AItems) do
    if AItems[Index] = AValue then
      Exit;
  SetLength(AItems, Length(AItems) + 1);
  AItems[High(AItems)] := AValue;
end;

function CopyUsedConnector(const AWork: TWorkConnector): TWlcConnector;
var
  Index: Integer;
begin
  Result := Default(TWlcConnector);
  Result.Name := AWork.Decl.Name;
  Result.Line := AWork.Decl.Line;
  Result.Column := AWork.Decl.Column;
  for Index := 0 to High(AWork.Decl.Methods) do
    if AWork.MethodUsed[Index] then
    begin
      SetLength(Result.Methods, Length(Result.Methods) + 1);
      Result.Methods[High(Result.Methods)] := AWork.Decl.Methods[Index];
    end;
  for Index := 0 to High(AWork.Decl.Structs) do
    if AWork.StructUsed[Index] then
    begin
      SetLength(Result.Structs, Length(Result.Structs) + 1);
      Result.Structs[High(Result.Structs)] := AWork.Decl.Structs[Index];
    end;
  for Index := 0 to High(AWork.Decl.Enums) do
    if AWork.EnumUsed[Index] then
    begin
      SetLength(Result.Enums, Length(Result.Enums) + 1);
      Result.Enums[High(Result.Enums)] := AWork.Decl.Enums[Index];
    end;
  for Index := 0 to High(AWork.Decl.Delegates) do
    if AWork.DelegateUsed[Index] then
    begin
      SetLength(Result.Delegates, Length(Result.Delegates) + 1);
      Result.Delegates[High(Result.Delegates)] := AWork.Decl.Delegates[Index];
    end;
end;

function ResolveConnectorPlan(
  const ADocuments: array of TWlcDocument;
  const AImports: array of TWlcGuestImport;
  const ABuiltInModules: array of string): TWlcConnectorPlan;
var
  Work: TWorkConnectorArray;
  ImpIndex: Integer;
  Imp: TWlcGuestImport;
  Found: TCandidateArray;
  ConnIndex, MethodIndex: Integer;
  Method: TWlcMethod;
  Func: TWasmFuncType;
  FailName: string;
  Thunk: TWlcResolvedThunk;
begin
  Result.Thunks := nil;
  Result.Libraries := nil;
  Result.Connectors := nil;
  CollectConnectors(ADocuments, Work);
  RejectNonUnique(Work);

  for ImpIndex := 0 to High(AImports) do
  begin
    Imp := AImports[ImpIndex];
    if IsBuiltInModule(Imp.ModuleName, ABuiltInModules) then
      Continue;
    if Imp.Kind <> wxkFunc then
      RaiseLink(MSG_WLC_UNKNOWN_IMPORT, Imp.ModuleName, Imp.Name);
    Found := FindCandidates(Work, Imp.ModuleName, Imp.Name);
    if Length(Found) = 0 then
      RaiseLink(MSG_WLC_UNKNOWN_IMPORT, Imp.ModuleName, Imp.Name);
    { RejectNonUnique already proved Length(Found) = 1 for every key. }
    ConnIndex := Found[0].ConnectorIndex;
    MethodIndex := Found[0].MethodIndex;
    Method := Work[ConnIndex].Decl.Methods[MethodIndex];
    if not LowerMethod(Work[ConnIndex].Decl, Method, Func, FailName) then
      RaiseUnsupported(Imp.ModuleName, Imp.Name, FailName);
    if not FuncSignatureMatches(Func, Imp.Func) then
      RaiseLink(MSG_WLC_INCOMPATIBLE_IMPORT, Imp.ModuleName, Imp.Name);
    Thunk := Default(TWlcResolvedThunk);
    Thunk.GuestModule := Imp.ModuleName;
    Thunk.GuestName := Imp.Name;
    Thunk.LibraryName := Method.LibraryName;
    Thunk.NativeSymbol := NativeSymbolOf(Method);
    Thunk.ConnectorName := Work[ConnIndex].Decl.Name;
    Thunk.Method := Method;
    Thunk.Func := Func;
    SetLength(Result.Thunks, Length(Result.Thunks) + 1);
    Result.Thunks[High(Result.Thunks)] := Thunk;
    AppendStringUnique(Result.Libraries, Method.LibraryName);
    MarkMethodUsed(Work[ConnIndex], MethodIndex);
  end;

  for ConnIndex := 0 to High(Work) do
    if Work[ConnIndex].AnyUsed then
    begin
      SetLength(Result.Connectors, Length(Result.Connectors) + 1);
      Result.Connectors[High(Result.Connectors)] :=
        CopyUsedConnector(Work[ConnIndex]);
    end;
end;

function ResolveConnectorModule(
  const ADocuments: array of TWlcDocument;
  const AModule: TWasmModule;
  const ABuiltInModules: array of string): TWlcConnectorPlan;
begin
  Result := ResolveConnectorPlan(ADocuments,
    WlcGuestImportsFromModule(AModule), ABuiltInModules);
end;

end.
