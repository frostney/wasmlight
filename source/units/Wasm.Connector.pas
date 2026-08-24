{ Wasm.Connector — declaration model and parse facade for the Wasmlight
  Connector Language (`.wlc`).

  A connector is a declarative C-ABI binding, not a program: the parser
  accepts only `[Connector]` static classes, structs, enums, delegates,
  and `extern` methods, plus the fixed attribute vocabulary. Method bodies,
  properties, inheritance, generics, expressions, control flow, and
  allocation are outside the language (issue #41). Resolution, alias
  matching, and unused-declaration stripping belong to issue #42; this
  model keeps every parsed declaration.

  EWasmConnectorError is a sibling of EWasmTextError, never a subclass of
  EWasmDecodeError: connector malformedness is a claim about `.wlc` source,
  not about wasm binary bytes or wat text. }
unit Wasm.Connector;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

type
  EWasmConnectorError = class(EWasmError)
  public
    Line: Integer;
    Column: Integer;
  end;

  TWlcDirection = (
    wldDefault,
    wldIn,
    wldOut,
    wldInOut
  );

  TWlcParamModifier = (
    wpmNone,
    wpmRef,
    wpmOut,
    wpmIn
  );

  { Default means "use the declared type's C ABI mapping". Named members
    match the C# `UnmanagedType` spellings the grammar accepts. }
  TWlcMarshalKind = (
    wlmDefault,
    wlmI1,
    wlmU1,
    wlmI2,
    wlmU2,
    wlmI4,
    wlmU4,
    wlmI8,
    wlmU8,
    wlmR4,
    wlmR8,
    wlmBool,
    wlmLPStr,
    wlmLPWStr,
    wlmLPUTF8Str,
    wlmLPArray,
    wlmByValArray,
    wlmSysInt,
    wlmSysUInt
  );

  { Retained is the connector default (CONTEXT.md). Scoped is a same-call
    callback or a scoped borrow on a parameter. Queued is a foreign-thread
    void notification. }
  TWlcCallbackKind = (
    wckRetained,
    wckScoped,
    wckQueued
  );

  TWlcTypeRef = record
    Name: string;
    IsArray: Boolean;
  end;

  TWlcMarshal = record
    Kind: TWlcMarshalKind;
    SizeConst: Integer;
    HasSizeConst: Boolean;
  end;

  TWlcParam = record
    Name: string;
    TypeRef: TWlcTypeRef;
    Modifier: TWlcParamModifier;
    Direction: TWlcDirection;
    Marshal: TWlcMarshal;
    IsScoped: Boolean;
    Line: Integer;
    Column: Integer;
  end;

  TWlcMethod = record
    Name: string;
    LibraryName: string;
    { Native symbol. Equals Name when DllImport omits EntryPoint. }
    EntryPoint: string;
    ReturnType: TWlcTypeRef;
    ReturnMarshal: TWlcMarshal;
    Params: array of TWlcParam;
    Line: Integer;
    Column: Integer;
  end;

  TWlcField = record
    Name: string;
    TypeRef: TWlcTypeRef;
    Marshal: TWlcMarshal;
    IsScoped: Boolean;
    Line: Integer;
    Column: Integer;
  end;

  TWlcStruct = record
    Name: string;
    Fields: array of TWlcField;
    Line: Integer;
    Column: Integer;
  end;

  TWlcEnumMember = record
    Name: string;
    Value: Int64;
    HasValue: Boolean;
    Line: Integer;
    Column: Integer;
  end;

  TWlcEnum = record
    Name: string;
    UnderlyingType: string;
    Members: array of TWlcEnumMember;
    Line: Integer;
    Column: Integer;
  end;

  TWlcDelegate = record
    Name: string;
    ReturnType: TWlcTypeRef;
    ReturnMarshal: TWlcMarshal;
    Params: array of TWlcParam;
    CallbackKind: TWlcCallbackKind;
    Line: Integer;
    Column: Integer;
  end;

  TWlcConnector = record
    Name: string;
    Structs: array of TWlcStruct;
    Enums: array of TWlcEnum;
    Delegates: array of TWlcDelegate;
    Methods: array of TWlcMethod;
    Line: Integer;
    Column: Integer;
  end;

  { One parsed `.wlc` file. Unused declarations stay; #42 strips. }
  TWlcDocument = record
    Connectors: array of TWlcConnector;
  end;

const
  MSG_WLC_ILLEGAL_CHAR = 'illegal character';
  MSG_WLC_UNCLOSED_STRING = 'unclosed string';
  MSG_WLC_UNCLOSED_COMMENT = 'unclosed comment';
  MSG_WLC_UNEXPECTED = 'unexpected token';
  MSG_WLC_METHOD_BODY = 'method bodies are outside the connector language';
  MSG_WLC_PROPERTY = 'properties are outside the connector language';
  MSG_WLC_INHERITANCE = 'inheritance is outside the connector language';
  MSG_WLC_GENERIC = 'generics are outside the connector language';
  MSG_WLC_EXPRESSION = 'expressions are outside the connector language';
  MSG_WLC_CONTROL = 'control flow is outside the connector language';
  MSG_WLC_ALLOCATION = 'allocation is outside the connector language';

procedure RaiseConnectorError(const AWhat: string;
  const ALine, AColumn: Integer);

function ParseConnector(const ASource: string): TWlcDocument;

function WlcMarshalKindName(const AKind: TWlcMarshalKind): string;
function WlcDirectionName(const ADirection: TWlcDirection): string;
function WlcCallbackKindName(const AKind: TWlcCallbackKind): string;

implementation

uses
  Wasm.Connector.Parser;

procedure RaiseConnectorError(const AWhat: string;
  const ALine, AColumn: Integer);
var
  E: EWasmConnectorError;
begin
  E := EWasmConnectorError.CreateFmt('%s (line %d, column %d)',
    [AWhat, ALine, AColumn]);
  E.Line := ALine;
  E.Column := AColumn;
  raise E;
end;

function ParseConnector(const ASource: string): TWlcDocument;
begin
  Result := ParseConnectorSource(ASource);
end;

function WlcMarshalKindName(const AKind: TWlcMarshalKind): string;
begin
  case AKind of
    wlmDefault: Result := 'Default';
    wlmI1: Result := 'I1';
    wlmU1: Result := 'U1';
    wlmI2: Result := 'I2';
    wlmU2: Result := 'U2';
    wlmI4: Result := 'I4';
    wlmU4: Result := 'U4';
    wlmI8: Result := 'I8';
    wlmU8: Result := 'U8';
    wlmR4: Result := 'R4';
    wlmR8: Result := 'R8';
    wlmBool: Result := 'Bool';
    wlmLPStr: Result := 'LPStr';
    wlmLPWStr: Result := 'LPWStr';
    wlmLPUTF8Str: Result := 'LPUTF8Str';
    wlmLPArray: Result := 'LPArray';
    wlmByValArray: Result := 'ByValArray';
    wlmSysInt: Result := 'SysInt';
    wlmSysUInt: Result := 'SysUInt';
  else
    Result := '?';
  end;
end;

function WlcDirectionName(const ADirection: TWlcDirection): string;
begin
  case ADirection of
    wldDefault: Result := 'default';
    wldIn: Result := 'in';
    wldOut: Result := 'out';
    wldInOut: Result := 'inout';
  else
    Result := '?';
  end;
end;

function WlcCallbackKindName(const AKind: TWlcCallbackKind): string;
begin
  case AKind of
    wckRetained: Result := 'retained';
    wckScoped: Result := 'scoped';
    wckQueued: Result := 'queued';
  else
    Result := '?';
  end;
end;

end.
