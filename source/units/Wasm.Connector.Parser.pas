{ Wasm.Connector.Parser — declaration-only recursive-descent parser for
  the Wasmlight Connector Language.

  Productions are the C# brace/semicolon shapes listed in issue #41. The
  parser records declarations for ABI planning and rejects every excluded
  construct with a stable prefix. It does not resolve imports or strip
  unused declarations (issue #42). }
unit Wasm.Connector.Parser;

{$I Shared.inc}

interface

uses
  Wasm.Connector;

function ParseConnectorSource(const ASource: string): TWlcDocument;

implementation

uses
  SysUtils,

  Wasm.Connector.Lexer;

type
  TWlcAttrArg = record
    Name: string;
    IsString: Boolean;
    IsInt: Boolean;
    IsIdent: Boolean;
    StringValue: string;
    IntValue: Int64;
    IdentValue: string;
  end;

  TWlcAttr = record
    Name: string;
    IsReturn: Boolean;
    Args: array of TWlcAttrArg;
    Line: Integer;
    Column: Integer;
  end;

  TWlcAttrArray = array of TWlcAttr;
  TWlcParamArray = array of TWlcParam;

  TWlcParser = record
  private
    FLexer: TWlcLexer;
    FToken: TWlcToken;

    procedure Advance;
    procedure Fault(const AWhat: string);
    procedure FaultToken(const AWhat: string);
    procedure ExpectKind(const AKind: TWlcTokenKind);
    function TokenIs(const AText: string): Boolean;
    function PeekIs(const AKind: TWlcTokenKind): Boolean;
    procedure RejectExcludedIdent;
    function TrySkipVisibility: Boolean;
    function ParseAttributeLists: TWlcAttrArray;
    function ParseOneAttribute: TWlcAttr;
    function ParseAttrArg: TWlcAttrArg;
    function ParseTypeRef: TWlcTypeRef;
    function ParseParamList: TWlcParamArray;
    function ParseParam: TWlcParam;
    function ParseConnectorClass(const AAttrs: TWlcAttrArray): TWlcConnector;
    procedure ParseMember(var AConnector: TWlcConnector);
    function ParseStruct: TWlcStruct;
    function ParseEnum: TWlcEnum;
    function ParseDelegate(const AAttrs: TWlcAttrArray): TWlcDelegate;
    function ParseMethod(const AAttrs: TWlcAttrArray): TWlcMethod;
    function ParseField(const AAttrs: TWlcAttrArray): TWlcField;
    function HasAttr(const AAttrs: TWlcAttrArray; const AName: string): Boolean;
    function FindAttr(const AAttrs: TWlcAttrArray; const AName: string;
      out AAttr: TWlcAttr): Boolean;
    procedure ApplyDirectionAndMarshal(var ADirection: TWlcDirection;
      var AMarshal: TWlcMarshal; var AIsScoped: Boolean;
      const AAttrs: TWlcAttrArray);
    procedure ApplyReturnAttrs(var AMarshal: TWlcMarshal;
      const AAttrs: TWlcAttrArray);
    function MarshalFromAttr(const AAttr: TWlcAttr): TWlcMarshal;
    function CallbackKindFromAttrs(const AAttrs: TWlcAttrArray): TWlcCallbackKind;
    procedure ApplyDllImport(var AMethod: TWlcMethod;
      const AAttrs: TWlcAttrArray);
    procedure RejectDisallowedAttrs(const AAttrs: TWlcAttrArray;
      const AAllowed: string);
  public
    function ParseDocument: TWlcDocument;
  end;

function IsVisibility(const AText: string): Boolean;
begin
  Result := (AText = 'public') or (AText = 'private') or
    (AText = 'internal') or (AText = 'protected');
end;

function IsControlKeyword(const AText: string): Boolean;
begin
  Result := (AText = 'if') or (AText = 'else') or (AText = 'for') or
    (AText = 'foreach') or (AText = 'while') or (AText = 'do') or
    (AText = 'switch') or (AText = 'case') or (AText = 'break') or
    (AText = 'continue') or (AText = 'goto') or (AText = 'try') or
    (AText = 'catch') or (AText = 'finally') or (AText = 'throw') or
    (AText = 'lock') or (AText = 'return') or (AText = 'yield');
end;

function IsAllowedAttrName(const AName: string): Boolean;
begin
  Result := (AName = 'DllImport') or (AName = 'EntryPoint') or
    (AName = 'MarshalAs') or (AName = 'In') or (AName = 'Out') or
    (AName = 'Scoped') or (AName = 'Queued');
end;

function MarshalKindFromName(const AName: string;
  out AKind: TWlcMarshalKind): Boolean;
begin
  Result := True;
  if AName = 'Int8' then
    AKind := wlmInt8
  else if AName = 'UInt8' then
    AKind := wlmUInt8
  else if AName = 'Int16' then
    AKind := wlmInt16
  else if AName = 'UInt16' then
    AKind := wlmUInt16
  else if AName = 'Int32' then
    AKind := wlmInt32
  else if AName = 'UInt32' then
    AKind := wlmUInt32
  else if AName = 'Int64' then
    AKind := wlmInt64
  else if AName = 'UInt64' then
    AKind := wlmUInt64
  else if AName = 'Float32' then
    AKind := wlmFloat32
  else if AName = 'Float64' then
    AKind := wlmFloat64
  else if AName = 'Bool' then
    AKind := wlmBool
  else if AName = 'LPStr' then
    AKind := wlmLPStr
  else if AName = 'LPWStr' then
    AKind := wlmLPWStr
  else if AName = 'LPUTF8Str' then
    AKind := wlmLPUTF8Str
  else if AName = 'LPArray' then
    AKind := wlmLPArray
  else if AName = 'ByValArray' then
    AKind := wlmByValArray
  else if AName = 'SysInt' then
    AKind := wlmSysInt
  else if AName = 'SysUInt' then
    AKind := wlmSysUInt
  else
    Result := False;
end;

function LastIdent(const ADotted: string): string;
var
  P: Integer;
begin
  P := LastDelimiter('.', ADotted);
  if P = 0 then
    Result := ADotted
  else
    Result := Copy(ADotted, P + 1, MaxInt);
end;

procedure CombineDirection(var ADir: TWlcDirection;
  const AAdd: TWlcDirection);
begin
  if ADir = wldDefault then
    ADir := AAdd
  else if (ADir = wldIn) and (AAdd = wldOut) then
    ADir := wldInOut
  else if (ADir = wldOut) and (AAdd = wldIn) then
    ADir := wldInOut
  else if ADir <> AAdd then
    ADir := wldInOut;
end;

procedure AppendAttr(var AItems: TWlcAttrArray; const AItem: TWlcAttr);
var
  N: Integer;
begin
  N := Length(AItems);
  SetLength(AItems, N + 1);
  AItems[N] := AItem;
end;

procedure AppendParam(var AItems: TWlcParamArray; const AItem: TWlcParam);
var
  N: Integer;
begin
  N := Length(AItems);
  SetLength(AItems, N + 1);
  AItems[N] := AItem;
end;

procedure TWlcParser.Advance;
begin
  FToken := FLexer.Next;
end;

procedure TWlcParser.Fault(const AWhat: string);
begin
  RaiseConnectorError(AWhat, FToken.Line, FToken.Column);
end;

procedure TWlcParser.FaultToken(const AWhat: string);
begin
  if FToken.Text <> '' then
    RaiseConnectorError(AWhat + ' ''' + FToken.Text + '''',
      FToken.Line, FToken.Column)
  else
    Fault(AWhat);
end;

procedure TWlcParser.ExpectKind(const AKind: TWlcTokenKind);
begin
  if FToken.Kind <> AKind then
  begin
    RejectExcludedIdent;
    if FToken.Kind = wlkLess then
      Fault(MSG_WLC_GENERIC);
    if FToken.Kind = wlkPlus then
      Fault(MSG_WLC_EXPRESSION);
    FaultToken(MSG_WLC_UNEXPECTED);
  end;
  Advance;
end;

function TWlcParser.TokenIs(const AText: string): Boolean;
begin
  Result := (FToken.Kind = wlkIdent) and (FToken.Text = AText);
end;

function TWlcParser.PeekIs(const AKind: TWlcTokenKind): Boolean;
begin
  Result := FLexer.Peek.Kind = AKind;
end;

procedure TWlcParser.RejectExcludedIdent;
begin
  if FToken.Kind <> wlkIdent then
    Exit;
  if IsControlKeyword(FToken.Text) then
    Fault(MSG_WLC_CONTROL);
  if FToken.Text = 'new' then
    Fault(MSG_WLC_ALLOCATION);
  if (FToken.Text = 'get') or (FToken.Text = 'set') then
    Fault(MSG_WLC_PROPERTY);
end;

function TWlcParser.TrySkipVisibility: Boolean;
begin
  Result := (FToken.Kind = wlkIdent) and IsVisibility(FToken.Text);
  if Result then
    Advance;
end;

function TWlcParser.ParseAttrArg: TWlcAttrArg;
begin
  Result := Default(TWlcAttrArg);
  if (FToken.Kind = wlkIdent) and PeekIs(wlkEquals) then
  begin
    Result.Name := FToken.Text;
    Advance;
    Advance;
  end;
  if FToken.Kind = wlkString then
  begin
    Result.IsString := True;
    Result.StringValue := FToken.Text;
    Advance;
    Exit;
  end;
  if FToken.Kind = wlkInteger then
  begin
    Result.IsInt := True;
    Result.IntValue := FToken.IntValue;
    Advance;
    Exit;
  end;
  if FToken.Kind = wlkIdent then
  begin
    Result.IsIdent := True;
    Result.IdentValue := FToken.Text;
    Advance;
    while FToken.Kind = wlkDot do
    begin
      Advance;
      if FToken.Kind <> wlkIdent then
        FaultToken(MSG_WLC_UNEXPECTED);
      Result.IdentValue := Result.IdentValue + '.' + FToken.Text;
      Advance;
    end;
    if FToken.Kind = wlkLParen then
      Fault(MSG_WLC_EXPRESSION);
    Exit;
  end;
  if (FToken.Kind = wlkLess) or (FToken.Kind = wlkGreater) then
    Fault(MSG_WLC_GENERIC);
  if FToken.Kind = wlkLParen then
    Fault(MSG_WLC_EXPRESSION);
  RejectExcludedIdent;
  FaultToken(MSG_WLC_UNEXPECTED);
end;

function TWlcParser.ParseOneAttribute: TWlcAttr;
var
  N: Integer;
begin
  Result := Default(TWlcAttr);
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  if TokenIs('return') and PeekIs(wlkColon) then
  begin
    Result.IsReturn := True;
    Advance;
    Advance;
  end;
  if FToken.Kind <> wlkIdent then
  begin
    RejectExcludedIdent;
    FaultToken(MSG_WLC_UNEXPECTED);
  end;
  Result.Name := FToken.Text;
  if not IsAllowedAttrName(Result.Name) then
    Fault('unknown attribute ''' + Result.Name + '''');
  Advance;
  if FToken.Kind = wlkLParen then
  begin
    Advance;
    if FToken.Kind <> wlkRParen then
    begin
      repeat
        N := Length(Result.Args);
        SetLength(Result.Args, N + 1);
        Result.Args[N] := ParseAttrArg;
        if FToken.Kind = wlkComma then
        begin
          Advance;
          if FToken.Kind = wlkRParen then
            FaultToken(MSG_WLC_UNEXPECTED);
        end
        else
          Break;
      until False;
    end;
    ExpectKind(wlkRParen);
  end;
end;

function TWlcParser.ParseAttributeLists: TWlcAttrArray;
begin
  Result := nil;
  SetLength(Result, 0);
  while FToken.Kind = wlkLBracket do
  begin
    Advance;
    repeat
      AppendAttr(Result, ParseOneAttribute);
      if FToken.Kind = wlkComma then
      begin
        Advance;
        if FToken.Kind = wlkRBracket then
          FaultToken(MSG_WLC_UNEXPECTED);
      end
      else
        Break;
    until False;
    ExpectKind(wlkRBracket);
  end;
end;

function TWlcParser.HasAttr(const AAttrs: TWlcAttrArray;
  const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AAttrs) do
    if AAttrs[I].Name = AName then
      Exit(True);
  Result := False;
end;

function TWlcParser.FindAttr(const AAttrs: TWlcAttrArray;
  const AName: string; out AAttr: TWlcAttr): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AAttrs) do
    if AAttrs[I].Name = AName then
    begin
      AAttr := AAttrs[I];
      Exit(True);
    end;
  Result := False;
end;

procedure TWlcParser.RejectDisallowedAttrs(const AAttrs: TWlcAttrArray;
  const AAllowed: string);
var
  I: Integer;
  Name: string;
begin
  for I := 0 to High(AAttrs) do
  begin
    Name := AAttrs[I].Name;
    if Pos(',' + Name + ',', ',' + AAllowed + ',') = 0 then
      RaiseConnectorError('attribute ''' + Name + ''' is not allowed here',
        AAttrs[I].Line, AAttrs[I].Column);
  end;
end;

function TWlcParser.MarshalFromAttr(const AAttr: TWlcAttr): TWlcMarshal;
var
  I: Integer;
  TypeName: string;
  Kind: TWlcMarshalKind;
begin
  Result := Default(TWlcMarshal);
  Result.Kind := wlmDefault;
  if (Length(AAttr.Args) = 0) or (not AAttr.Args[0].IsIdent) then
    RaiseConnectorError('MarshalAs requires an UnmanagedType',
      AAttr.Line, AAttr.Column);
  TypeName := LastIdent(AAttr.Args[0].IdentValue);
  if (AAttr.Args[0].IdentValue <> TypeName) and
     (Copy(AAttr.Args[0].IdentValue, 1, 14) <> 'UnmanagedType.') then
    RaiseConnectorError('unknown MarshalAs unmanaged type ''' +
      AAttr.Args[0].IdentValue + '''', AAttr.Line, AAttr.Column);
  if not MarshalKindFromName(TypeName, Kind) then
    RaiseConnectorError('unknown MarshalAs unmanaged type ''' +
      TypeName + '''', AAttr.Line, AAttr.Column);
  Result.Kind := Kind;
  for I := 1 to High(AAttr.Args) do
  begin
    if (AAttr.Args[I].Name = 'SizeConst') and AAttr.Args[I].IsInt then
    begin
      Result.HasSizeConst := True;
      Result.SizeConst := Integer(AAttr.Args[I].IntValue);
    end
    else
      RaiseConnectorError('unknown MarshalAs argument',
        AAttr.Line, AAttr.Column);
  end;
end;

procedure TWlcParser.ApplyDirectionAndMarshal(var ADirection: TWlcDirection;
  var AMarshal: TWlcMarshal; var AIsScoped: Boolean;
  const AAttrs: TWlcAttrArray);
var
  I: Integer;
begin
  for I := 0 to High(AAttrs) do
  begin
    if AAttrs[I].IsReturn then
      Continue;
    if AAttrs[I].Name = 'In' then
      CombineDirection(ADirection, wldIn)
    else if AAttrs[I].Name = 'Out' then
      CombineDirection(ADirection, wldOut)
    else if AAttrs[I].Name = 'MarshalAs' then
      AMarshal := MarshalFromAttr(AAttrs[I])
    else if AAttrs[I].Name = 'Scoped' then
      AIsScoped := True
    else if (AAttrs[I].Name = 'DllImport') or
            (AAttrs[I].Name = 'EntryPoint') or
            (AAttrs[I].Name = 'Queued') then
      RaiseConnectorError('attribute ''' + AAttrs[I].Name +
        ''' is not allowed here', AAttrs[I].Line, AAttrs[I].Column);
  end;
end;

procedure TWlcParser.ApplyReturnAttrs(var AMarshal: TWlcMarshal;
  const AAttrs: TWlcAttrArray);
var
  I: Integer;
begin
  for I := 0 to High(AAttrs) do
    if AAttrs[I].IsReturn then
    begin
      if AAttrs[I].Name <> 'MarshalAs' then
        RaiseConnectorError('return attribute must be MarshalAs',
          AAttrs[I].Line, AAttrs[I].Column);
      AMarshal := MarshalFromAttr(AAttrs[I]);
    end;
end;

function TWlcParser.CallbackKindFromAttrs(
  const AAttrs: TWlcAttrArray): TWlcCallbackKind;
var
  Queued, Scoped: Boolean;
  I: Integer;
begin
  Queued := HasAttr(AAttrs, 'Queued');
  Scoped := HasAttr(AAttrs, 'Scoped');
  if Queued and Scoped then
  begin
    for I := 0 to High(AAttrs) do
      if (AAttrs[I].Name = 'Queued') or (AAttrs[I].Name = 'Scoped') then
        RaiseConnectorError('Queued and Scoped cannot combine',
          AAttrs[I].Line, AAttrs[I].Column);
  end;
  if Queued then
    Result := wckQueued
  else if Scoped then
    Result := wckScoped
  else
    Result := wckRetained;
end;

procedure TWlcParser.ApplyDllImport(var AMethod: TWlcMethod;
  const AAttrs: TWlcAttrArray);
var
  Attr, Entry: TWlcAttr;
  I: Integer;
begin
  if not FindAttr(AAttrs, 'DllImport', Attr) then
    RaiseConnectorError('extern method requires [DllImport]',
      AMethod.Line, AMethod.Column);
  if (Length(Attr.Args) = 0) or (Attr.Args[0].Name <> '') or
     (not Attr.Args[0].IsString) or (Attr.Args[0].StringValue = '') then
    RaiseConnectorError('DllImport requires a library name',
      Attr.Line, Attr.Column);
  AMethod.LibraryName := Attr.Args[0].StringValue;
  AMethod.EntryPoint := AMethod.Name;
  for I := 1 to High(Attr.Args) do
  begin
    if (Attr.Args[I].Name = 'EntryPoint') and Attr.Args[I].IsString then
    begin
      if Attr.Args[I].StringValue = '' then
        RaiseConnectorError('EntryPoint requires a native symbol',
          Attr.Line, Attr.Column);
      AMethod.EntryPoint := Attr.Args[I].StringValue;
    end
    else
      RaiseConnectorError('unknown DllImport argument',
        Attr.Line, Attr.Column);
  end;
  if FindAttr(AAttrs, 'EntryPoint', Entry) then
  begin
    if (Length(Entry.Args) = 1) and Entry.Args[0].IsString and
       (Entry.Args[0].StringValue <> '') then
      AMethod.EntryPoint := Entry.Args[0].StringValue
    else
      RaiseConnectorError('EntryPoint requires a native symbol',
        Entry.Line, Entry.Column);
  end;
end;

function TWlcParser.ParseTypeRef: TWlcTypeRef;
begin
  Result := Default(TWlcTypeRef);
  RejectExcludedIdent;
  if FToken.Kind = wlkLess then
    Fault(MSG_WLC_GENERIC);
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.IsArray := False;
  Advance;
  if FToken.Kind = wlkDot then
    Fault('qualified type names are outside the connector language');
  if FToken.Kind = wlkLess then
    Fault(MSG_WLC_GENERIC);
  if FToken.Kind = wlkStar then
    FaultToken(MSG_WLC_UNEXPECTED);
  if FToken.Kind = wlkLBracket then
  begin
    Advance;
    if FToken.Kind <> wlkRBracket then
      Fault(MSG_WLC_GENERIC);
    Advance;
    Result.IsArray := True;
  end;
end;

function TWlcParser.ParseParam: TWlcParam;
var
  Attrs: TWlcAttrArray;
begin
  Result := Default(TWlcParam);
  Attrs := ParseAttributeLists;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Result.Modifier := wpmNone;
  Result.Direction := wldDefault;
  if TokenIs('ref') then
  begin
    Result.Modifier := wpmRef;
    CombineDirection(Result.Direction, wldInOut);
    Advance;
  end
  else if TokenIs('out') then
  begin
    Result.Modifier := wpmOut;
    CombineDirection(Result.Direction, wldOut);
    Advance;
  end
  else if TokenIs('in') then
  begin
    Result.Modifier := wpmIn;
    CombineDirection(Result.Direction, wldIn);
    Advance;
  end;
  Result.TypeRef := ParseTypeRef;
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Advance;
  ApplyDirectionAndMarshal(Result.Direction, Result.Marshal,
    Result.IsScoped, Attrs);
end;

function TWlcParser.ParseParamList: TWlcParamArray;
begin
  Result := nil;
  SetLength(Result, 0);
  ExpectKind(wlkLParen);
  if FToken.Kind <> wlkRParen then
  begin
    repeat
      AppendParam(Result, ParseParam);
      if FToken.Kind = wlkComma then
      begin
        Advance;
        if FToken.Kind = wlkRParen then
          FaultToken(MSG_WLC_UNEXPECTED);
      end
      else
        Break;
    until False;
  end;
  ExpectKind(wlkRParen);
end;

function TWlcParser.ParseField(const AAttrs: TWlcAttrArray): TWlcField;
var
  Direction: TWlcDirection;
begin
  Result := Default(TWlcField);
  Result.TypeRef := ParseTypeRef;
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Advance;
  if FToken.Kind = wlkLBrace then
    Fault(MSG_WLC_PROPERTY);
  if FToken.Kind = wlkEquals then
    Fault(MSG_WLC_EXPRESSION);
  if FToken.Kind = wlkLParen then
    Fault(MSG_WLC_METHOD_BODY);
  Direction := wldDefault;
  ApplyDirectionAndMarshal(Direction, Result.Marshal, Result.IsScoped, AAttrs);
  ExpectKind(wlkSemicolon);
end;

function TWlcParser.ParseStruct: TWlcStruct;
var
  FieldAttrs: TWlcAttrArray;
  N: Integer;
begin
  Result := Default(TWlcStruct);
  Advance;
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Advance;
  if FToken.Kind = wlkColon then
    Fault(MSG_WLC_INHERITANCE);
  if FToken.Kind = wlkLess then
    Fault(MSG_WLC_GENERIC);
  ExpectKind(wlkLBrace);
  while FToken.Kind <> wlkRBrace do
  begin
    if FToken.Kind = wlkEof then
      Fault('unclosed ''{''');
    FieldAttrs := ParseAttributeLists;
    TrySkipVisibility;
    RejectExcludedIdent;
    if TokenIs('struct') or TokenIs('enum') or TokenIs('delegate') or
       TokenIs('class') or TokenIs('static') then
      FaultToken(MSG_WLC_UNEXPECTED);
    N := Length(Result.Fields);
    SetLength(Result.Fields, N + 1);
    Result.Fields[N] := ParseField(FieldAttrs);
  end;
  Advance;
end;

function TWlcParser.ParseEnum: TWlcEnum;
var
  Member: TWlcEnumMember;
  NextValue: Int64;
  N: Integer;
begin
  Result := Default(TWlcEnum);
  Advance;
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Advance;
  if FToken.Kind = wlkColon then
  begin
    Advance;
    if FToken.Kind <> wlkIdent then
      FaultToken(MSG_WLC_UNEXPECTED);
    Result.UnderlyingType := FToken.Text;
    Advance;
  end;
  if FToken.Kind = wlkLess then
    Fault(MSG_WLC_GENERIC);
  ExpectKind(wlkLBrace);
  NextValue := 0;
  while FToken.Kind <> wlkRBrace do
  begin
    if FToken.Kind = wlkEof then
      Fault('unclosed ''{''');
    RejectExcludedIdent;
    if FToken.Kind <> wlkIdent then
      FaultToken(MSG_WLC_UNEXPECTED);
    Member := Default(TWlcEnumMember);
    Member.Name := FToken.Text;
    Member.Line := FToken.Line;
    Member.Column := FToken.Column;
    Advance;
    if FToken.Kind = wlkEquals then
    begin
      Advance;
      if FToken.Kind <> wlkInteger then
      begin
        if FToken.Kind = wlkIdent then
          Fault(MSG_WLC_EXPRESSION);
        Fault(MSG_WLC_EXPRESSION);
      end;
      Member.Value := FToken.IntValue;
      Member.HasValue := True;
      NextValue := FToken.IntValue + 1;
      Advance;
    end
    else
    begin
      Member.Value := NextValue;
      Member.HasValue := False;
      Inc(NextValue);
    end;
    N := Length(Result.Members);
    SetLength(Result.Members, N + 1);
    Result.Members[N] := Member;
    if FToken.Kind = wlkComma then
      Advance
    else
      Break;
  end;
  ExpectKind(wlkRBrace);
end;

function TWlcParser.ParseDelegate(const AAttrs: TWlcAttrArray): TWlcDelegate;
begin
  Result := Default(TWlcDelegate);
  RejectDisallowedAttrs(AAttrs, 'Queued,Scoped,MarshalAs');
  Advance;
  Result.ReturnType := ParseTypeRef;
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Advance;
  if FToken.Kind = wlkLess then
    Fault(MSG_WLC_GENERIC);
  Result.Params := ParseParamList;
  ApplyReturnAttrs(Result.ReturnMarshal, AAttrs);
  Result.CallbackKind := CallbackKindFromAttrs(AAttrs);
  if FToken.Kind = wlkLBrace then
    Fault(MSG_WLC_METHOD_BODY);
  ExpectKind(wlkSemicolon);
end;

function TWlcParser.ParseMethod(const AAttrs: TWlcAttrArray): TWlcMethod;
begin
  Result := Default(TWlcMethod);
  RejectDisallowedAttrs(AAttrs, 'DllImport,EntryPoint,MarshalAs');
  Result.ReturnType := ParseTypeRef;
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Advance;
  if FToken.Kind = wlkLess then
    Fault(MSG_WLC_GENERIC);
  Result.Params := ParseParamList;
  ApplyReturnAttrs(Result.ReturnMarshal, AAttrs);
  ApplyDllImport(Result, AAttrs);
  if FToken.Kind = wlkLBrace then
    Fault(MSG_WLC_METHOD_BODY);
  if FToken.Kind = wlkEquals then
    Fault(MSG_WLC_EXPRESSION);
  ExpectKind(wlkSemicolon);
end;

procedure TWlcParser.ParseMember(var AConnector: TWlcConnector);
var
  Attrs: TWlcAttrArray;
  N: Integer;
begin
  Attrs := ParseAttributeLists;
  TrySkipVisibility;
  RejectExcludedIdent;
  if TokenIs('struct') then
  begin
    RejectDisallowedAttrs(Attrs, '');
    N := Length(AConnector.Structs);
    SetLength(AConnector.Structs, N + 1);
    AConnector.Structs[N] := ParseStruct;
    Exit;
  end;
  if TokenIs('enum') then
  begin
    RejectDisallowedAttrs(Attrs, '');
    N := Length(AConnector.Enums);
    SetLength(AConnector.Enums, N + 1);
    AConnector.Enums[N] := ParseEnum;
    Exit;
  end;
  if TokenIs('delegate') then
  begin
    N := Length(AConnector.Delegates);
    SetLength(AConnector.Delegates, N + 1);
    AConnector.Delegates[N] := ParseDelegate(Attrs);
    Exit;
  end;
  if TokenIs('static') then
  begin
    Advance;
    if not TokenIs('extern') then
      Fault('method must be static extern');
    Advance;
    N := Length(AConnector.Methods);
    SetLength(AConnector.Methods, N + 1);
    AConnector.Methods[N] := ParseMethod(Attrs);
    Exit;
  end;
  if TokenIs('extern') then
    Fault('method must be static extern');
  if TokenIs('class') then
    Fault(MSG_WLC_INHERITANCE);
  if TokenIs('new') then
    Fault(MSG_WLC_ALLOCATION);
  if FToken.Kind = wlkIdent then
  begin
    { A leftover type-and-name member is a property or a method body. }
    ParseTypeRef;
    if FToken.Kind = wlkIdent then
      Advance;
    if FToken.Kind = wlkLBrace then
      Fault(MSG_WLC_PROPERTY);
    if FToken.Kind = wlkLParen then
      Fault(MSG_WLC_METHOD_BODY);
    FaultToken(MSG_WLC_UNEXPECTED);
  end;
  FaultToken(MSG_WLC_UNEXPECTED);
end;

function TWlcParser.ParseConnectorClass(
  const AAttrs: TWlcAttrArray): TWlcConnector;
begin
  Result := Default(TWlcConnector);
  RejectDisallowedAttrs(AAttrs, '');
  TrySkipVisibility;
  if not TokenIs('static') then
    Fault('connector class must be static');
  Advance;
  if not TokenIs('class') then
    Fault('connector class must be static');
  Advance;
  if FToken.Kind <> wlkIdent then
    FaultToken(MSG_WLC_UNEXPECTED);
  Result.Name := FToken.Text;
  Result.Line := FToken.Line;
  Result.Column := FToken.Column;
  Advance;
  if FToken.Kind = wlkColon then
    Fault(MSG_WLC_INHERITANCE);
  if FToken.Kind = wlkLess then
    Fault(MSG_WLC_GENERIC);
  ExpectKind(wlkLBrace);
  while FToken.Kind <> wlkRBrace do
  begin
    if FToken.Kind = wlkEof then
      Fault('unclosed ''{''');
    ParseMember(Result);
  end;
  Advance;
end;

function TWlcParser.ParseDocument: TWlcDocument;
var
  Attrs: TWlcAttrArray;
  N: Integer;
begin
  Result := Default(TWlcDocument);
  Advance;
  while FToken.Kind <> wlkEof do
  begin
    Attrs := ParseAttributeLists;
    RejectExcludedIdent;
    if TokenIs('using') or TokenIs('namespace') then
      FaultToken(MSG_WLC_UNEXPECTED);
    TrySkipVisibility;
    if TokenIs('static') then
    begin
      N := Length(Result.Connectors);
      SetLength(Result.Connectors, N + 1);
      Result.Connectors[N] := ParseConnectorClass(Attrs);
    end
    else
    begin
      if TokenIs('class') then
        Fault('connector class must be static');
      FaultToken(MSG_WLC_UNEXPECTED);
    end;
  end;
end;

function ParseConnectorSource(const ASource: string): TWlcDocument;
var
  Parser: TWlcParser;
begin
  Parser := Default(TWlcParser);
  Parser.FLexer := TWlcLexer.Create(ASource);
  try
    Result := Parser.ParseDocument;
  finally
    Parser.FLexer.Free;
  end;
end;

end.
