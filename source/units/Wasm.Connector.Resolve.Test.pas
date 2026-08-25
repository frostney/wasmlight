{ Unit suite for Wasm.Connector.Resolve.

  Guest modules are assembled, decoded, and validated through the shipped
  path. Declaration records are built directly to isolate matching from
  the parser, and `.wlc` snippets go through `ParseConnector` for the
  shipped parse-then-resolve path. Cases cover EntryPoint aliasing, unique
  matching, missing/duplicate/incompatible/ambiguous bindings, unused
  stripping, and built-in WASI imports that must not require a connector. }
program Wasm.Connector.Resolve.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Connector,
  Wasm.Connector.Resolve,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator,
  Wasm.Wat.Assembler;

type
  TConnectorResolveTests = class(TTestSuite)
  private
    FModule: TWasmModule;
    FBytes: TWasmBytes;

    function TypeRef(const AName: string;
      const AIsArray: Boolean = False): TWlcTypeRef;
    function IntParam(const AName: string): TWlcParam;
    function ArrayParam(const AName, ATypeName: string): TWlcParam;
    function DelegateParam(const AName, ATypeName: string): TWlcParam;
    function MethodOf(const AName, ALibrary, AEntry, AReturn: string;
      const AParams: array of TWlcParam): TWlcMethod;
    function ConnectorOf(const AName: string;
      const AMethods: array of TWlcMethod): TWlcConnector;
    function DocumentOf(const AConnectors: array of TWlcConnector): TWlcDocument;
    function LoadWat(const AWat: string): TWasmModule;
    function ResolveError(const ADocs: array of TWlcDocument;
      const AModule: TWasmModule;
      const ABuiltIns: array of string): string;
    function HasPrefix(const AMessage, APrefix: string): Boolean;
    function SampleLibc: TWlcDocument;
    function SampleWat: string;
    function WriteWlc(const ALibrary, AEntry: string): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestEntryPointAliasesNativeSymbolOnly;
    procedure TestEntryPointDoesNotMatchGuestName;
    procedure TestMissingImportIsUnknown;
    procedure TestDuplicateBindingRejected;
    procedure TestAmbiguousBindingRejected;
    procedure TestIncompatibleSignatureRejected;
    procedure TestUnusedLibraryStripped;
    procedure TestUnusedTypesAndConnectorStripped;
    procedure TestUsedDelegateRetained;
    procedure TestBuiltInWasiNeedsNoDeclaration;
    procedure TestNonFuncImportIsUnknown;
    procedure TestUnsupportedTypeRejected;
    procedure TestModuleAdapterMatchesAssembler;
    procedure TestNilModuleIsRejected;
    procedure TestParsedSourceResolvesAliasAndStripsUnused;
    procedure TestParsedAmbiguousBindingRejected;
    procedure TestParsedMissingImportIsUnknown;
  end;

function TConnectorResolveTests.TypeRef(const AName: string;
  const AIsArray: Boolean): TWlcTypeRef;
begin
  Result.Name := AName;
  Result.IsArray := AIsArray;
end;

function TConnectorResolveTests.IntParam(const AName: string): TWlcParam;
begin
  Result := Default(TWlcParam);
  Result.Name := AName;
  Result.TypeRef := TypeRef('int');
end;

function TConnectorResolveTests.ArrayParam(const AName, ATypeName: string):
  TWlcParam;
begin
  Result := Default(TWlcParam);
  Result.Name := AName;
  Result.TypeRef := TypeRef(ATypeName, True);
  Result.Direction := wldIn;
  Result.Marshal.Kind := wlmLPArray;
end;

function TConnectorResolveTests.DelegateParam(const AName, ATypeName: string):
  TWlcParam;
begin
  Result := Default(TWlcParam);
  Result.Name := AName;
  Result.TypeRef := TypeRef(ATypeName);
end;

function TConnectorResolveTests.MethodOf(const AName, ALibrary, AEntry,
  AReturn: string; const AParams: array of TWlcParam): TWlcMethod;
var
  Index: Integer;
begin
  Result := Default(TWlcMethod);
  Result.Name := AName;
  Result.LibraryName := ALibrary;
  Result.EntryPoint := AEntry;
  Result.ReturnType := TypeRef(AReturn);
  SetLength(Result.Params, Length(AParams));
  for Index := 0 to High(AParams) do
    Result.Params[Index] := AParams[Index];
end;

function TConnectorResolveTests.ConnectorOf(const AName: string;
  const AMethods: array of TWlcMethod): TWlcConnector;
var
  Index: Integer;
begin
  Result := Default(TWlcConnector);
  Result.Name := AName;
  SetLength(Result.Methods, Length(AMethods));
  for Index := 0 to High(AMethods) do
    Result.Methods[Index] := AMethods[Index];
end;

function TConnectorResolveTests.DocumentOf(
  const AConnectors: array of TWlcConnector): TWlcDocument;
var
  Index: Integer;
begin
  Result.Connectors := nil;
  SetLength(Result.Connectors, Length(AConnectors));
  for Index := 0 to High(AConnectors) do
    Result.Connectors[Index] := AConnectors[Index];
end;

function TConnectorResolveTests.LoadWat(const AWat: string): TWasmModule;
var
  Ir: TWasmIrModule;
begin
  FBytes := AssembleWatText(AWat);
  DecodeModule(FBytes, FModule);
  Ir := ValidateModule(FModule, FBytes);
  Ir.Free;
  Result := FModule;
end;

function TConnectorResolveTests.ResolveError(const ADocs: array of TWlcDocument;
  const AModule: TWasmModule; const ABuiltIns: array of string): string;
var
  Plan: TWlcConnectorPlan;
begin
  Result := '';
  try
    Plan := ResolveConnectorModule(ADocs, AModule, ABuiltIns);
    if Length(Plan.Thunks) = 0 then
      Result := '';
  except
    on E: EWasmLinkError do
      Result := E.Message;
  end;
end;

function TConnectorResolveTests.HasPrefix(const AMessage, APrefix: string):
  Boolean;
begin
  Result := Copy(AMessage, 1, Length(APrefix)) = APrefix;
end;

function TConnectorResolveTests.SampleLibc: TWlcDocument;
var
  Libc: TWlcConnector;
  Unused: TWlcConnector;
  Iovec: TWlcStruct;
  Whence: TWlcEnum;
  Notify: TWlcDelegate;
begin
  Libc := ConnectorOf('Libc', [
    MethodOf('getpid', 'libc', 'getpid', 'int', []),
    MethodOf('Write', 'libc', 'write', 'int',
      [IntParam('fd'), ArrayParam('buf', 'byte'), IntParam('count')]),
    MethodOf('set_notify', 'libcb', 'set_notify', 'void',
      [DelegateParam('cb', 'Notify')]),
    MethodOf('unused_abs', '/abs/lib.so', 'unused_abs', 'void', [])
  ]);

  Iovec := Default(TWlcStruct);
  Iovec.Name := 'Iovec';
  SetLength(Iovec.Fields, 2);
  Iovec.Fields[0].Name := 'Base';
  Iovec.Fields[0].TypeRef := TypeRef('byte', True);
  Iovec.Fields[0].IsScoped := True;
  Iovec.Fields[1].Name := 'Length';
  Iovec.Fields[1].TypeRef := TypeRef('int');
  SetLength(Libc.Structs, 1);
  Libc.Structs[0] := Iovec;

  Whence := Default(TWlcEnum);
  Whence.Name := 'Whence';
  Whence.UnderlyingType := 'int';
  SetLength(Libc.Enums, 1);
  Libc.Enums[0] := Whence;

  Notify := Default(TWlcDelegate);
  Notify.Name := 'Notify';
  Notify.ReturnType := TypeRef('void');
  Notify.CallbackKind := wckQueued;
  SetLength(Notify.Params, 1);
  Notify.Params[0] := IntParam('code');
  SetLength(Libc.Delegates, 1);
  Libc.Delegates[0] := Notify;

  Unused := ConnectorOf('UnusedLib', [
    MethodOf('leftover', 'unused', 'leftover', 'void', [])
  ]);
  Result := DocumentOf([Libc, Unused]);
end;

function TConnectorResolveTests.SampleWat: string;
begin
  Result :=
    '(module' + sLineBreak +
    '  (import "Libc" "Write" (func (param i32 i32 i32) (result i32)))' +
    sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))' +
    sLineBreak +
    '  (func (export "run") (param i32 i32 i32) (result i32)' + sLineBreak +
    '    (call 0 (local.get 0) (local.get 1) (local.get 2))))';
end;

function TConnectorResolveTests.WriteWlc(const ALibrary, AEntry: string): string;
begin
  Result :=
    'public static class Libc' + #10 +
    '{' + #10 +
    '    [DllImport("' + ALibrary + '", EntryPoint = "' + AEntry + '")]' + #10 +
    '    public static extern int Write(int fd, [In, MarshalAs(UnmanagedType.LPArray)] byte[] buf, int count);' + #10 +
    '}' + #10;
end;

procedure TConnectorResolveTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FBytes := nil;
end;

procedure TConnectorResolveTests.AfterEach;
begin
  FreeAndNil(FModule);
  FBytes := nil;
end;

procedure TConnectorResolveTests.TestEntryPointAliasesNativeSymbolOnly;
var
  Plan: TWlcConnectorPlan;
begin
  Plan := ResolveConnectorModule([SampleLibc], LoadWat(SampleWat),
    [WLC_WASI_MODULE]);
  Expect<Integer>(Length(Plan.Thunks)).ToBe(1);
  Expect<string>(Plan.Thunks[0].GuestModule).ToBe('Libc');
  Expect<string>(Plan.Thunks[0].GuestName).ToBe('Write');
  Expect<string>(Plan.Thunks[0].NativeSymbol).ToBe('write');
  Expect<string>(Plan.Thunks[0].LibraryName).ToBe('libc');
  Expect<string>(Plan.Thunks[0].Method.Name).ToBe('Write');
  Expect<Integer>(Length(Plan.Thunks[0].Func.Params)).ToBe(3);
  Expect<Integer>(Length(Plan.Thunks[0].Func.Results)).ToBe(1);
end;

procedure TConnectorResolveTests.TestEntryPointDoesNotMatchGuestName;
var
  Caught: string;
begin
  Caught := ResolveError([SampleLibc],
    LoadWat(
      '(module (import "Libc" "write" (func (param i32 i32 i32) (result i32))))'),
    []);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_UNKNOWN_IMPORT)).ToBe(True);
end;

procedure TConnectorResolveTests.TestMissingImportIsUnknown;
var
  Caught: string;
begin
  Caught := ResolveError([SampleLibc],
    LoadWat('(module (import "Libc" "open" (func (param i32) (result i32))))'),
    []);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_UNKNOWN_IMPORT)).ToBe(True);
end;

procedure TConnectorResolveTests.TestDuplicateBindingRejected;
var
  First: TWlcDocument;
  Second: TWlcDocument;
  Caught: string;
begin
  First := DocumentOf([ConnectorOf('Libc',
    [MethodOf('Write', 'libc', 'write', 'int',
      [IntParam('fd'), ArrayParam('buf', 'byte'), IntParam('count')])])]);
  Second := DocumentOf([ConnectorOf('Libc',
    [MethodOf('Write', 'libc', 'write', 'int',
      [IntParam('fd'), ArrayParam('buf', 'byte'), IntParam('count')])])]);
  Caught := ResolveError([First, Second], LoadWat(SampleWat),
    [WLC_WASI_MODULE]);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_DUPLICATE_BINDING)).ToBe(True);
end;

procedure TConnectorResolveTests.TestAmbiguousBindingRejected;
var
  First: TWlcDocument;
  Second: TWlcDocument;
  Caught: string;
begin
  First := DocumentOf([ConnectorOf('Libc',
    [MethodOf('Write', 'libc', 'write', 'int',
      [IntParam('fd'), ArrayParam('buf', 'byte'), IntParam('count')])])]);
  Second := DocumentOf([ConnectorOf('Libc',
    [MethodOf('Write', 'other', 'write_alt', 'int',
      [IntParam('fd'), ArrayParam('buf', 'byte'), IntParam('count')])])]);
  Caught := ResolveError([First, Second], LoadWat(SampleWat),
    [WLC_WASI_MODULE]);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_AMBIGUOUS_BINDING)).ToBe(True);
end;

procedure TConnectorResolveTests.TestIncompatibleSignatureRejected;
var
  Caught: string;
begin
  Caught := ResolveError([SampleLibc],
    LoadWat('(module (import "Libc" "Write" (func (param i32) (result i32))))'),
    []);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_INCOMPATIBLE_IMPORT)).ToBe(True);
end;

procedure TConnectorResolveTests.TestUnusedLibraryStripped;
var
  Plan: TWlcConnectorPlan;
begin
  Plan := ResolveConnectorModule([SampleLibc], LoadWat(SampleWat),
    [WLC_WASI_MODULE]);
  Expect<Integer>(Length(Plan.Libraries)).ToBe(1);
  Expect<string>(Plan.Libraries[0]).ToBe('libc');
end;

procedure TConnectorResolveTests.TestUnusedTypesAndConnectorStripped;
var
  Plan: TWlcConnectorPlan;
begin
  Plan := ResolveConnectorModule([SampleLibc], LoadWat(SampleWat),
    [WLC_WASI_MODULE]);
  Expect<Integer>(Length(Plan.Connectors)).ToBe(1);
  Expect<string>(Plan.Connectors[0].Name).ToBe('Libc');
  Expect<Integer>(Length(Plan.Connectors[0].Methods)).ToBe(1);
  Expect<string>(Plan.Connectors[0].Methods[0].Name).ToBe('Write');
  Expect<Integer>(Length(Plan.Connectors[0].Structs)).ToBe(0);
  Expect<Integer>(Length(Plan.Connectors[0].Enums)).ToBe(0);
  Expect<Integer>(Length(Plan.Connectors[0].Delegates)).ToBe(0);
end;

procedure TConnectorResolveTests.TestUsedDelegateRetained;
var
  Plan: TWlcConnectorPlan;
begin
  Plan := ResolveConnectorModule([SampleLibc],
    LoadWat('(module (import "Libc" "set_notify" (func (param i32))))'),
    []);
  Expect<Integer>(Length(Plan.Libraries)).ToBe(1);
  Expect<string>(Plan.Libraries[0]).ToBe('libcb');
  Expect<Integer>(Length(Plan.Connectors[0].Delegates)).ToBe(1);
  Expect<string>(Plan.Connectors[0].Delegates[0].Name).ToBe('Notify');
  Expect<Integer>(Length(Plan.Connectors[0].Structs)).ToBe(0);
end;

procedure TConnectorResolveTests.TestBuiltInWasiNeedsNoDeclaration;
var
  Empty: TWlcDocument;
  Plan: TWlcConnectorPlan;
begin
  Empty.Connectors := nil;
  Plan := ResolveConnectorModule([Empty],
    LoadWat(
      '(module (import "wasi_snapshot_preview1" "proc_exit" (func (param i32))))'),
    [WLC_WASI_MODULE]);
  Expect<Integer>(Length(Plan.Thunks)).ToBe(0);
  Expect<Integer>(Length(Plan.Libraries)).ToBe(0);
end;

procedure TConnectorResolveTests.TestNonFuncImportIsUnknown;
var
  Caught: string;
begin
  Caught := ResolveError([SampleLibc],
    LoadWat('(module (import "Libc" "mem" (memory 1)))'),
    []);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_UNKNOWN_IMPORT)).ToBe(True);
end;

procedure TConnectorResolveTests.TestUnsupportedTypeRejected;
var
  Doc: TWlcDocument;
  Caught: string;
begin
  Doc := DocumentOf([ConnectorOf('Libc',
    [MethodOf('Write', 'libc', 'write', 'Widget',
      [IntParam('fd')])])]);
  Caught := ResolveError([Doc],
    LoadWat('(module (import "Libc" "Write" (func (param i32) (result i32))))'),
    []);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_UNSUPPORTED_TYPE)).ToBe(True);
end;

procedure TConnectorResolveTests.TestModuleAdapterMatchesAssembler;
var
  Imports: TWlcGuestImportArray;
begin
  Imports := WlcGuestImportsFromModule(LoadWat(SampleWat));
  Expect<Integer>(Length(Imports)).ToBe(2);
  Expect<string>(Imports[0].ModuleName).ToBe('Libc');
  Expect<string>(Imports[0].Name).ToBe('Write');
  Expect<Boolean>(Imports[0].Kind = wxkFunc).ToBe(True);
  Expect<Integer>(Length(Imports[0].Func.Params)).ToBe(3);
  Expect<string>(Imports[1].ModuleName).ToBe(WLC_WASI_MODULE);
end;

procedure TConnectorResolveTests.TestNilModuleIsRejected;
var
  Caught: string;
begin
  Caught := '';
  try
    WlcGuestImportsFromModule(nil);
  except
    on E: EWasmError do
      Caught := E.Message;
  end;
  Expect<string>(Caught).ToBe('connector resolve needs a module');
end;

procedure TConnectorResolveTests.TestParsedSourceResolvesAliasAndStripsUnused;
var
  Plan: TWlcConnectorPlan;
  Source: string;
begin
  Source :=
    WriteWlc('libc', 'write') +
    'static class UnusedLib' + #10 +
    '{' + #10 +
    '    [DllImport("gone")]' + #10 +
    '    static extern void leftover();' + #10 +
    '}' + #10;
  Plan := ResolveConnectorModule([ParseConnector(Source)],
    LoadWat(SampleWat), [WLC_WASI_MODULE]);
  Expect<Integer>(Length(Plan.Thunks)).ToBe(1);
  Expect<string>(Plan.Thunks[0].GuestName).ToBe('Write');
  Expect<string>(Plan.Thunks[0].NativeSymbol).ToBe('write');
  Expect<string>(Plan.Thunks[0].LibraryName).ToBe('libc');
  Expect<Integer>(Length(Plan.Libraries)).ToBe(1);
  Expect<string>(Plan.Libraries[0]).ToBe('libc');
  Expect<Integer>(Length(Plan.Connectors)).ToBe(1);
  Expect<string>(Plan.Connectors[0].Name).ToBe('Libc');
  Expect<Integer>(Length(Plan.Connectors[0].Methods)).ToBe(1);
  Expect<string>(Plan.Connectors[0].Methods[0].Name).ToBe('Write');
end;

procedure TConnectorResolveTests.TestParsedAmbiguousBindingRejected;
var
  Caught: string;
begin
  Caught := ResolveError(
    [ParseConnector(WriteWlc('libc', 'write')),
     ParseConnector(WriteWlc('other', 'write_alt'))],
    LoadWat(SampleWat), [WLC_WASI_MODULE]);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_AMBIGUOUS_BINDING)).ToBe(True);
end;

procedure TConnectorResolveTests.TestParsedMissingImportIsUnknown;
var
  Caught: string;
begin
  Caught := ResolveError([ParseConnector(WriteWlc('libc', 'write'))],
    LoadWat('(module (import "Libc" "open" (func (param i32) (result i32))))'),
    []);
  Expect<Boolean>(HasPrefix(Caught, MSG_WLC_UNKNOWN_IMPORT)).ToBe(True);
end;

procedure TConnectorResolveTests.SetupTests;
begin
  Test('EntryPoint aliases the native symbol and not the guest name',
    TestEntryPointAliasesNativeSymbolOnly);
  Test('a guest name that equals only EntryPoint is missing',
    TestEntryPointDoesNotMatchGuestName);
  Test('an undeclared import is unknown import',
    TestMissingImportIsUnknown);
  Test('identical declarations of one guest key are duplicate',
    TestDuplicateBindingRejected);
  Test('distinct declarations of one guest key are ambiguous',
    TestAmbiguousBindingRejected);
  Test('a signature mismatch after marshalling is incompatible',
    TestIncompatibleSignatureRejected);
  Test('unused libraries are stripped from the plan',
    TestUnusedLibraryStripped);
  Test('unused types and unused connector classes are stripped',
    TestUnusedTypesAndConnectorStripped);
  Test('a used delegate type is retained with its library',
    TestUsedDelegateRetained);
  Test('a built-in WASI import needs no connector declaration',
    TestBuiltInWasiNeedsNoDeclaration);
  Test('a non-function import has no connector declaration',
    TestNonFuncImportIsUnknown);
  Test('an unlowerable type is unsupported connector type',
    TestUnsupportedTypeRejected);
  Test('WlcGuestImportsFromModule reads a validated assembled module',
    TestModuleAdapterMatchesAssembler);
  Test('a nil module is rejected before import matching',
    TestNilModuleIsRejected);
  Test('ParseConnector output aliases EntryPoint and strips unused',
    TestParsedSourceResolvesAliasAndStripsUnused);
  Test('ParseConnector output rejects ambiguous bindings',
    TestParsedAmbiguousBindingRejected);
  Test('ParseConnector output rejects a missing import',
    TestParsedMissingImportIsUnknown);
end;

begin
  TestRunnerProgram.AddSuite(TConnectorResolveTests.Create(
    'Wasm.Connector.Resolve'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
