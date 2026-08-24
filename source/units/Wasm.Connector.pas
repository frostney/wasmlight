{ Wasm.Connector — declaration model for the Wasmlight Connector Language.

  A connector is a declarative C-ABI binding, not a program. This unit owns
  only the records later ABI planning consumes. Parsing `.wlc` source is
  issue #41; matching guest imports, EntryPoint aliasing, and unused
  stripping are issue #42 (`Wasm.Connector.Resolve`).

  Field names and enumerations are the shared contract with the #41 parser
  so the orchestrator can take that parser unit without reshaping resolve. }
unit Wasm.Connector;

{$I Shared.inc}

interface

type
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

  { One parsed `.wlc` file. Unused declarations stay until resolve strips. }
  TWlcDocument = record
    Connectors: array of TWlcConnector;
  end;

implementation

end.
