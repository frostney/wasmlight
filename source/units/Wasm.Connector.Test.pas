{ Unit suite for Wasm.Connector — parse facade and declaration model.

  Happy-path snippets cover every accepted declaration and fixed attribute.
  Malformed snippets sit next to the assertion and cover every construct
  issue #41 excludes. Unused declarations stay in the model (#42 strips). }
program Wasm.Connector.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Connector;

type
  TWlcParserTests = class(TTestSuite)
  private
    function ParseError(const ASource: string): string;
    function ParseErrorPos(const ASource: string): string;
    procedure ExpectPrefix(const AMessage, APrefix: string);
    function SampleSource: string;
  public
    procedure SetupTests; override;

    procedure TestParsesConnectorDeclarations;
    procedure TestEntryPointAliasAndUnusedStay;
    procedure TestAttributesAndDirections;
    procedure TestCallbackKinds;
    procedure TestInOutAndSizeConst;
    procedure TestEmptyFile;
    procedure TestRejectsMethodBody;
    procedure TestRejectsProperty;
    procedure TestRejectsInheritance;
    procedure TestRejectsGenerics;
    procedure TestRejectsExpressions;
    procedure TestRejectsControlFlow;
    procedure TestRejectsAllocation;
    procedure TestAcceptsBareStaticClass;
    procedure TestRejectsConnectorAttribute;
    procedure TestRejectsNonStaticClass;
    procedure TestRejectsMissingDllImport;
    procedure TestRejectsUnknownAttribute;
    procedure TestDiagnosticsCarryPosition;
  end;

function TWlcParserTests.ParseError(const ASource: string): string;
var
  Doc: TWlcDocument;
begin
  Result := '';
  try
    Doc := ParseConnector(ASource);
    if Length(Doc.Connectors) = 0 then
      Result := '';
  except
    on E: EWasmConnectorError do
      Result := E.Message;
  end;
end;

function TWlcParserTests.ParseErrorPos(const ASource: string): string;
var
  Doc: TWlcDocument;
begin
  Result := '';
  try
    Doc := ParseConnector(ASource);
    if Length(Doc.Connectors) = 0 then
      Result := '';
  except
    on E: EWasmConnectorError do
      Result := IntToStr(E.Line) + ':' + IntToStr(E.Column);
  end;
end;

procedure TWlcParserTests.ExpectPrefix(const AMessage, APrefix: string);
begin
  Expect<Boolean>(Copy(AMessage, 1, Length(APrefix)) = APrefix).ToBe(True);
end;

function TWlcParserTests.SampleSource: string;
begin
  Result :=
    'public static class Libc' + #10 +
    '{' + #10 +
    '    public enum Whence : int' + #10 +
    '    {' + #10 +
    '        Set = 0,' + #10 +
    '        Cur,' + #10 +
    '        End = 2,' + #10 +
    '    }' + #10 +
    '    public struct Iovec' + #10 +
    '    {' + #10 +
    '        [Scoped]' + #10 +
    '        public byte[] Base;' + #10 +
    '        public int Length;' + #10 +
    '    }' + #10 +
    '    public delegate int ReadCallback(int fd, [Out] byte[] buf, int count);' + #10 +
    '    [Queued]' + #10 +
    '    public delegate void Notify(int code);' + #10 +
    '    [Scoped]' + #10 +
    '    public delegate int Compare(int a, int b);' + #10 +
    '    [DllImport("libc")]' + #10 +
    '    public static extern int getpid();' + #10 +
    '    [DllImport("libc", EntryPoint = "write")]' + #10 +
    '    [return: MarshalAs(UnmanagedType.Int32)]' + #10 +
    '    public static extern int Write(int fd, [In, MarshalAs(UnmanagedType.LPArray)] byte[] buf, int count);' + #10 +
    '    [DllImport("libcb")]' + #10 +
    '    public static extern void set_notify(Notify cb);' + #10 +
    '    [DllImport("/abs/lib.so")]' + #10 +
    '    public static extern void unused_abs();' + #10 +
    '}' + #10 +
    'static class UnusedLib' + #10 +
    '{' + #10 +
    '    [DllImport("unused")]' + #10 +
    '    static extern void leftover();' + #10 +
    '}' + #10;
end;

procedure TWlcParserTests.TestParsesConnectorDeclarations;
var
  Doc: TWlcDocument;
  C: TWlcConnector;
begin
  Doc := ParseConnector(SampleSource);
  Expect<Integer>(Length(Doc.Connectors)).ToBe(2);
  C := Doc.Connectors[0];
  Expect<string>(C.Name).ToBe('Libc');
  Expect<Integer>(Length(C.Enums)).ToBe(1);
  Expect<string>(C.Enums[0].Name).ToBe('Whence');
  Expect<string>(C.Enums[0].UnderlyingType).ToBe('int');
  Expect<Integer>(Length(C.Enums[0].Members)).ToBe(3);
  Expect<string>(C.Enums[0].Members[0].Name).ToBe('Set');
  Expect<Int64>(C.Enums[0].Members[0].Value).ToBe(0);
  Expect<Int64>(C.Enums[0].Members[1].Value).ToBe(1);
  Expect<Int64>(C.Enums[0].Members[2].Value).ToBe(2);
  Expect<Integer>(Length(C.Structs)).ToBe(1);
  Expect<string>(C.Structs[0].Name).ToBe('Iovec');
  Expect<Integer>(Length(C.Structs[0].Fields)).ToBe(2);
  Expect<string>(C.Structs[0].Fields[0].Name).ToBe('Base');
  Expect<Boolean>(C.Structs[0].Fields[0].TypeRef.IsArray).ToBe(True);
  Expect<Boolean>(C.Structs[0].Fields[0].IsScoped).ToBe(True);
  Expect<Integer>(Length(C.Delegates)).ToBe(3);
  Expect<Integer>(Length(C.Methods)).ToBe(4);
  Expect<string>(C.Methods[0].Name).ToBe('getpid');
  Expect<string>(C.Methods[0].LibraryName).ToBe('libc');
end;

procedure TWlcParserTests.TestEntryPointAliasAndUnusedStay;
var
  Doc: TWlcDocument;
begin
  Doc := ParseConnector(SampleSource);
  Expect<string>(Doc.Connectors[0].Methods[0].EntryPoint).ToBe('getpid');
  Expect<string>(Doc.Connectors[0].Methods[1].Name).ToBe('Write');
  Expect<string>(Doc.Connectors[0].Methods[1].EntryPoint).ToBe('write');
  Expect<string>(Doc.Connectors[0].Methods[3].LibraryName).ToBe('/abs/lib.so');
  Expect<string>(Doc.Connectors[1].Name).ToBe('UnusedLib');
  Expect<string>(Doc.Connectors[1].Methods[0].Name).ToBe('leftover');
end;

procedure TWlcParserTests.TestAttributesAndDirections;
var
  Doc: TWlcDocument;
  WriteFn: TWlcMethod;
  ReadCb: TWlcDelegate;
begin
  Doc := ParseConnector(SampleSource);
  WriteFn := Doc.Connectors[0].Methods[1];
  Expect<string>(WlcMarshalKindName(WriteFn.ReturnMarshal.Kind)).ToBe('Int32');
  Expect<Integer>(Length(WriteFn.Params)).ToBe(3);
  Expect<string>(WlcDirectionName(WriteFn.Params[1].Direction)).ToBe('in');
  Expect<string>(WlcMarshalKindName(WriteFn.Params[1].Marshal.Kind)).ToBe('LPArray');
  ReadCb := Doc.Connectors[0].Delegates[0];
  Expect<string>(WlcDirectionName(ReadCb.Params[1].Direction)).ToBe('out');
end;

procedure TWlcParserTests.TestCallbackKinds;
var
  Doc: TWlcDocument;
begin
  Doc := ParseConnector(SampleSource);
  Expect<string>(WlcCallbackKindName(Doc.Connectors[0].Delegates[0].CallbackKind))
    .ToBe('retained');
  Expect<string>(WlcCallbackKindName(Doc.Connectors[0].Delegates[1].CallbackKind))
    .ToBe('queued');
  Expect<string>(WlcCallbackKindName(Doc.Connectors[0].Delegates[2].CallbackKind))
    .ToBe('scoped');
end;

procedure TWlcParserTests.TestInOutAndSizeConst;
var
  Doc: TWlcDocument;
  Src: string;
begin
  Src :=
    'static class C {' +
    '  struct S { [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)] int[] Vals; }' +
    '  [DllImport("lib")] static extern void copy([In, Out] byte[] buf);' +
    '  [DllImport("lib")] static extern void borrow(in int x, ref int y, out int z);' +
    '  [DllImport("lib")] [EntryPoint("native_f")] static extern void f();' +
    '}';
  Doc := ParseConnector(Src);
  Expect<Boolean>(Doc.Connectors[0].Structs[0].Fields[0].Marshal.HasSizeConst)
    .ToBe(True);
  Expect<Integer>(Doc.Connectors[0].Structs[0].Fields[0].Marshal.SizeConst)
    .ToBe(4);
  Expect<string>(WlcMarshalKindName(
    Doc.Connectors[0].Structs[0].Fields[0].Marshal.Kind)).ToBe('ByValArray');
  Expect<string>(WlcDirectionName(Doc.Connectors[0].Methods[0].Params[0].Direction))
    .ToBe('inout');
  Expect<Boolean>(Doc.Connectors[0].Methods[1].Params[0].Modifier = wpmIn)
    .ToBe(True);
  Expect<Boolean>(Doc.Connectors[0].Methods[1].Params[1].Modifier = wpmRef)
    .ToBe(True);
  Expect<Boolean>(Doc.Connectors[0].Methods[1].Params[2].Modifier = wpmOut)
    .ToBe(True);
  Expect<string>(Doc.Connectors[0].Methods[2].Name).ToBe('f');
  Expect<string>(Doc.Connectors[0].Methods[2].EntryPoint).ToBe('native_f');
end;

procedure TWlcParserTests.TestEmptyFile;
var
  Doc: TWlcDocument;
begin
  Doc := ParseConnector('');
  Expect<Integer>(Length(Doc.Connectors)).ToBe(0);
  Doc := ParseConnector('// comment only' + #10);
  Expect<Integer>(Length(Doc.Connectors)).ToBe(0);
end;

procedure TWlcParserTests.TestRejectsMethodBody;
var
  Src, Msg: string;
begin
  Src :=
    'static class C { ' +
    '[DllImport("x")] static extern int f() { return 1; } }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, MSG_WLC_METHOD_BODY);
end;

procedure TWlcParserTests.TestRejectsProperty;
var
  Src, Msg: string;
begin
  Src := 'static class C { int X { get; set; } }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, MSG_WLC_PROPERTY);
end;

procedure TWlcParserTests.TestRejectsInheritance;
var
  Src, Msg: string;
begin
  Src := 'static class C : Base { }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, MSG_WLC_INHERITANCE);
end;

procedure TWlcParserTests.TestRejectsGenerics;
var
  Src, Msg: string;
begin
  Src := 'static class C { struct Box<T> { T Value; } }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, MSG_WLC_GENERIC);
end;

procedure TWlcParserTests.TestRejectsExpressions;
var
  Src, Msg: string;
begin
  Src :=
    'static class C { enum E { A = 1 + 2 } }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, MSG_WLC_EXPRESSION);
end;

procedure TWlcParserTests.TestRejectsControlFlow;
var
  Src, Msg: string;
begin
  Src := 'static class C { if (true) { } }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, MSG_WLC_CONTROL);
end;

procedure TWlcParserTests.TestRejectsAllocation;
var
  Src, Msg: string;
begin
  Src := 'static class C { new int[4]; }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, MSG_WLC_ALLOCATION);
end;

procedure TWlcParserTests.TestAcceptsBareStaticClass;
var
  Doc: TWlcDocument;
begin
  Doc := ParseConnector('static class C { }');
  Expect<Integer>(Length(Doc.Connectors)).ToBe(1);
  Expect<string>(Doc.Connectors[0].Name).ToBe('C');
end;

procedure TWlcParserTests.TestRejectsConnectorAttribute;
var
  Src, Msg: string;
begin
  Src := '[Connector] static class C { }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, 'unknown attribute ''Connector''');
end;

procedure TWlcParserTests.TestRejectsNonStaticClass;
var
  Src, Msg: string;
begin
  Src := 'class C { }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, 'connector class must be static');
end;

procedure TWlcParserTests.TestRejectsMissingDllImport;
var
  Src, Msg: string;
begin
  Src := 'static class C { static extern int f(); }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, 'extern method requires [DllImport]');
end;

procedure TWlcParserTests.TestRejectsUnknownAttribute;
var
  Src, Msg: string;
begin
  Src := '[Serializable] static class C { }';
  Msg := ParseError(Src);
  ExpectPrefix(Msg, 'unknown attribute ''Serializable''');
end;

procedure TWlcParserTests.TestDiagnosticsCarryPosition;
begin
  Expect<string>(ParseErrorPos(
    'static class C { int X { get; set; } }')).ToBe('1:24');
end;

procedure TWlcParserTests.SetupTests;
begin
  Test('parses connector declarations', TestParsesConnectorDeclarations);
  Test('entry point alias and unused stay', TestEntryPointAliasAndUnusedStay);
  Test('attributes and directions', TestAttributesAndDirections);
  Test('callback kinds', TestCallbackKinds);
  Test('in-out and SizeConst', TestInOutAndSizeConst);
  Test('empty file', TestEmptyFile);
  Test('rejects method body', TestRejectsMethodBody);
  Test('rejects property', TestRejectsProperty);
  Test('rejects inheritance', TestRejectsInheritance);
  Test('rejects generics', TestRejectsGenerics);
  Test('rejects expressions', TestRejectsExpressions);
  Test('rejects control flow', TestRejectsControlFlow);
  Test('rejects allocation', TestRejectsAllocation);
  Test('accepts bare static class', TestAcceptsBareStaticClass);
  Test('rejects Connector attribute', TestRejectsConnectorAttribute);
  Test('rejects non-static class', TestRejectsNonStaticClass);
  Test('rejects missing DllImport', TestRejectsMissingDllImport);
  Test('rejects unknown attribute', TestRejectsUnknownAttribute);
  Test('diagnostics carry position', TestDiagnosticsCarryPosition);
end;

begin
  TestRunnerProgram.AddSuite(TWlcParserTests.Create('Wasm.Connector'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
