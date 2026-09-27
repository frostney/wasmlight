{ Unit suite for Wasm.Connector.Plan — the connector-plan section codec.

  Plans come from the shipped parse-then-resolve path over an assembled
  module. Round trips cover every declaration kind the plan can carry;
  malformed sections are spelled as literal bytes next to the assertion;
  the startup re-resolve check rejects a well-formed plan that is not the
  plan resolution produces for the embedded module. }
program Wasm.Connector.Plan.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Connector,
  Wasm.Connector.Plan,
  Wasm.Connector.Resolve,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Ir,
  Wasm.Module,
  Wasm.Validator,
  Wasm.Wat.Assembler;

const
  RICH_WLC =
    'public static class Libc' + sLineBreak +
    '{' + sLineBreak +
    '    public enum Whence : long { Set = 0, Cur, End = -2 }' + sLineBreak +
    '    public struct Pair { public int A; [MarshalAs(UnmanagedType.Int64)] public long B; }' + sLineBreak +
    '    [Queued] public delegate void Notify(int code);' + sLineBreak +
    '    [DllImport("libc")] public static extern int getpid();' + sLineBreak +
    '    [DllImport("libc", EntryPoint = "lseek")]' + sLineBreak +
    '    public static extern long Seek(int fd, long offset, Whence whence);' + sLineBreak +
    '    [DllImport("/opt/app/libpair.so")]' + sLineBreak +
    '    [return: MarshalAs(UnmanagedType.Float64)]' + sLineBreak +
    '    public static extern double Scale(ref Pair p,' + sLineBreak +
    '        [In, Out, MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] byte[] buf,' + sLineBreak +
    '        Notify cb, float f);' + sLineBreak +
    '    [DllImport("libunused")] public static extern void unused();' + sLineBreak +
    '}' + sLineBreak;

  RICH_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))' + sLineBreak +
    '  (import "Libc" "getpid" (func (result i32)))' + sLineBreak +
    '  (import "Libc" "Seek" (func (param i32 i64 i64) (result i64)))' + sLineBreak +
    '  (import "Libc" "Scale" (func (param i32 i32 i32 f32) (result f64))))';

  GETPID_WLC =
    'static class Libc {' + sLineBreak +
    '  [DllImport("libc")] static extern int getpid();' + sLineBreak +
    '}' + sLineBreak;

  GETPID_WAT =
    '(module (import "Libc" "getpid" (func (result i32))))';

type
  TConnectorPlanTests = class(TTestSuite)
  private
    FModule: TWasmModule;
    FBytes: TWasmBytes;

    function LoadWat(const AWat: string): TWasmModule;
    function ResolveWlc(const AWlc, AWat: string): TWlcConnectorPlan;
    function DecodeResult(const ABytes: array of Byte): TWlcPlanDecodeResult;
    function CheckError(const ABytes: TWasmBytes; const AWat: string): string;
    function MinimalThunk(const AValueCode, AScopedByte: Byte): TWasmBytes;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestEmptyPlanIsEmptySection;
    procedure TestRichPlanRoundTrips;
    procedure TestEncodingIsDeterministic;
    procedure TestSourcePositionsAreNotCarried;
    procedure TestEmptySectionDecodesToEmptyPlan;
    procedure TestBadMagicRejected;
    procedure TestUnsupportedVersionRejected;
    procedure TestNonZeroReservedRejected;
    procedure TestTruncatedHeaderRejected;
    procedure TestZeroThunksRejected;
    procedure TestOversizedCountRejected;
    procedure TestMinimalStructureAccepted;
    procedure TestNonNumericValueTypeRejected;
    procedure TestNonCanonicalBooleanRejected;
    procedure TestOutOfRangeMarshalKindRejected;
    procedure TestSizeConstWithoutFlagRejected;
    procedure TestTrailingByteRejected;
    procedure TestEveryTruncationRejected;
    procedure TestCheckAcceptsTheResolvedPlan;
    procedure TestCheckRejectsARetargetedSymbol;
    procedure TestCheckRejectsAPlanForAnotherModule;
    procedure TestCheckRejectsMalformedBytes;
  end;

function Bytes(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function Concat(const A, B: TWasmBytes): TWasmBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A) + Length(B));
  for I := 0 to High(A) do
    Result[I] := A[I];
  for I := 0 to High(B) do
    Result[Length(A) + I] := B[I];
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

procedure TConnectorPlanTests.BeforeEach;
begin
  FModule := nil;
  FBytes := nil;
end;

procedure TConnectorPlanTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

function TConnectorPlanTests.LoadWat(const AWat: string): TWasmModule;
var
  Ir: TWasmIrModule;
begin
  FreeAndNil(FModule);
  FModule := TWasmModule.Create;
  FBytes := AssembleWatText(AWat);
  DecodeModule(FBytes, FModule);
  Ir := ValidateModule(FModule, FBytes);
  Ir.Free;
  Result := FModule;
end;

function TConnectorPlanTests.ResolveWlc(const AWlc, AWat: string):
  TWlcConnectorPlan;
begin
  Result := ResolveConnectorModule([ParseConnector(AWlc)], LoadWat(AWat),
    [WLC_WASI_MODULE]);
end;

function TConnectorPlanTests.DecodeResult(const ABytes: array of Byte):
  TWlcPlanDecodeResult;
var
  Plan: TWlcConnectorPlan;
begin
  Result := DecodeConnectorPlan(Bytes(ABytes), Plan);
end;

function TConnectorPlanTests.CheckError(const ABytes: TWasmBytes;
  const AWat: string): string;
begin
  Result := '';
  try
    CheckConnectorPlanForModule(ABytes, LoadWat(AWat), [WLC_WASI_MODULE]);
  except
    on E: EWasmLinkError do
      Result := E.Message;
  end;
end;

{ Header, one thunk whose strings are all empty, a method with one param
  (IsScoped byte supplied), one wasm param of AValueCode, no results, no
  libraries, no connectors. Structurally well formed; not a resolvable
  plan. }
function TConnectorPlanTests.MinimalThunk(const AValueCode,
  AScopedByte: Byte): TWasmBytes;
begin
  Result := Bytes([
    $57, $4C, $43, $50, $01, $00, $00, $00,   { 'WLCP' v1 reserved 0 }
    $01, $00, $00, $00,                       { 1 thunk }
    $00, $00, $00, $00, $00, $00, $00, $00,   { guest module, guest name }
    $00, $00, $00, $00, $00, $00, $00, $00,   { library, native symbol }
    $00, $00, $00, $00,                       { connector name }
    $00, $00, $00, $00, $00, $00, $00, $00,   { method name, library }
    $00, $00, $00, $00,                       { entry point }
    $00, $00, $00, $00, $00,                  { return type: '' not array }
    $00, $00, $00, $00, $00, $00,             { return marshal }
    $01, $00, $00, $00,                       { 1 param }
    $00, $00, $00, $00, $00, $00, $00, $00,   { name '', type '' }
    $00,                                      { not array }
    $00, $00,                                 { modifier, direction }
    $00, $00, $00, $00, $00, $00,             { marshal }
    AScopedByte,                              { IsScoped }
    $01, $00, $00, $00, AValueCode,           { 1 wasm param }
    $00, $00, $00, $00,                       { 0 wasm results }
    $00, $00, $00, $00,                       { 0 libraries }
    $00, $00, $00, $00]);                     { 0 connectors }
end;

procedure TConnectorPlanTests.TestEmptyPlanIsEmptySection;
var
  Plan: TWlcConnectorPlan;
begin
  Plan := ResolveWlc(GETPID_WLC, '(module)');
  Expect<Integer>(Length(Plan.Thunks)).ToBe(0);
  Expect<Integer>(Length(EncodeConnectorPlan(Plan))).ToBe(0);
end;

procedure TConnectorPlanTests.TestRichPlanRoundTrips;
var
  Plan, Back: TWlcConnectorPlan;
  Encoded: TWasmBytes;
  C: TWlcConnector;
  Scale: TWlcMethod;
begin
  Plan := ResolveWlc(RICH_WLC, RICH_WAT);
  Encoded := EncodeConnectorPlan(Plan);
  Expect<Integer>(Ord(DecodeConnectorPlan(Encoded, Back))).ToBe(Ord(wpdOk));

  Expect<Integer>(Length(Back.Thunks)).ToBe(3);
  Expect<string>(Back.Thunks[1].GuestName).ToBe('Seek');
  Expect<string>(Back.Thunks[1].NativeSymbol).ToBe('lseek');
  Expect<string>(Back.Thunks[1].LibraryName).ToBe('libc');
  Expect<Integer>(Length(Back.Thunks[1].Func.Params)).ToBe(3);
  Expect<Integer>(Ord(Back.Thunks[1].Func.Params[2].Num)).ToBe(Ord(wntI64));
  Expect<Integer>(Ord(Back.Thunks[2].Func.Results[0].Num)).ToBe(Ord(wntF64));
  Expect<Integer>(Length(Back.Libraries)).ToBe(2);
  Expect<string>(Back.Libraries[1]).ToBe('/opt/app/libpair.so');

  Scale := Back.Thunks[2].Method;
  Expect<Integer>(Ord(Scale.ReturnMarshal.Kind)).ToBe(Ord(wlmFloat64));
  Expect<Integer>(Ord(Scale.Params[0].Modifier)).ToBe(Ord(wpmRef));
  Expect<Integer>(Ord(Scale.Params[1].Direction)).ToBe(Ord(wldInOut));
  Expect<Boolean>(Scale.Params[1].TypeRef.IsArray).ToBe(True);
  Expect<Boolean>(Scale.Params[1].Marshal.HasSizeConst).ToBe(True);
  Expect<Integer>(Scale.Params[1].Marshal.SizeConst).ToBe(4);

  Expect<Integer>(Length(Back.Connectors)).ToBe(1);
  C := Back.Connectors[0];
  Expect<Integer>(Length(C.Methods)).ToBe(3);
  Expect<Integer>(Length(C.Enums)).ToBe(1);
  Expect<string>(C.Enums[0].UnderlyingType).ToBe('long');
  Expect<Integer>(Integer(C.Enums[0].Members[2].Value)).ToBe(-2);
  Expect<Boolean>(C.Enums[0].Members[1].HasValue).ToBe(False);
  Expect<Integer>(Length(C.Structs)).ToBe(1);
  Expect<Integer>(Ord(C.Structs[0].Fields[1].Marshal.Kind)).ToBe(Ord(wlmInt64));
  Expect<Integer>(Length(C.Delegates)).ToBe(1);
  Expect<Integer>(Ord(C.Delegates[0].CallbackKind)).ToBe(Ord(wckQueued));

  Expect<Boolean>(SameBytes(EncodeConnectorPlan(Back), Encoded)).ToBe(True);
end;

procedure TConnectorPlanTests.TestEncodingIsDeterministic;
var
  A, B: TWasmBytes;
begin
  A := EncodeConnectorPlan(ResolveWlc(RICH_WLC, RICH_WAT));
  B := EncodeConnectorPlan(ResolveWlc(RICH_WLC, RICH_WAT));
  Expect<Boolean>(Length(A) > 8).ToBe(True);
  Expect<Boolean>(SameBytes(A, B)).ToBe(True);
end;

procedure TConnectorPlanTests.TestSourcePositionsAreNotCarried;
var
  A, B: TWasmBytes;
begin
  { The same declarations, reflowed: identical section bytes. }
  A := EncodeConnectorPlan(ResolveWlc(GETPID_WLC, GETPID_WAT));
  B := EncodeConnectorPlan(ResolveWlc(sLineBreak + sLineBreak +
    '   static class Libc { [DllImport("libc")]' + sLineBreak +
    '        static extern int getpid(); }', GETPID_WAT));
  Expect<Boolean>(SameBytes(A, B)).ToBe(True);
end;

procedure TConnectorPlanTests.TestEmptySectionDecodesToEmptyPlan;
var
  Plan: TWlcConnectorPlan;
begin
  Expect<Integer>(Ord(DecodeConnectorPlan(nil, Plan))).ToBe(Ord(wpdOk));
  Expect<Integer>(Length(Plan.Thunks)).ToBe(0);
  Expect<Integer>(Length(Plan.Libraries)).ToBe(0);
end;

procedure TConnectorPlanTests.TestBadMagicRejected;
begin
  Expect<Integer>(Ord(DecodeResult([$57, $4C, $43, $51, $01, $00, $00, $00,
    $01, $00, $00, $00]))).ToBe(Ord(wpdBadMagic));
end;

procedure TConnectorPlanTests.TestUnsupportedVersionRejected;
begin
  Expect<Integer>(Ord(DecodeResult([$57, $4C, $43, $50, $02, $00, $00, $00,
    $01, $00, $00, $00]))).ToBe(Ord(wpdUnsupportedVersion));
end;

procedure TConnectorPlanTests.TestNonZeroReservedRejected;
begin
  Expect<Integer>(Ord(DecodeResult([$57, $4C, $43, $50, $01, $00, $01, $00,
    $01, $00, $00, $00]))).ToBe(Ord(wpdBadValue));
end;

procedure TConnectorPlanTests.TestTruncatedHeaderRejected;
begin
  Expect<Integer>(Ord(DecodeResult([$57, $4C, $43, $50, $01, $00])))
    .ToBe(Ord(wpdTruncated));
end;

procedure TConnectorPlanTests.TestZeroThunksRejected;
begin
  { The writer emits no bytes for an empty plan, so a header announcing
    zero thunks is not a canonical section. }
  Expect<Integer>(Ord(DecodeResult([$57, $4C, $43, $50, $01, $00, $00, $00,
    $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00])))
    .ToBe(Ord(wpdBadValue));
end;

procedure TConnectorPlanTests.TestOversizedCountRejected;
begin
  Expect<Integer>(Ord(DecodeResult([$57, $4C, $43, $50, $01, $00, $00, $00,
    $FF, $FF, $FF, $FF, $00, $00, $00, $00]))).ToBe(Ord(wpdTruncated));
end;

procedure TConnectorPlanTests.TestMinimalStructureAccepted;
var
  Plan: TWlcConnectorPlan;
begin
  Expect<Integer>(Ord(DecodeConnectorPlan(MinimalThunk($7F, $00), Plan)))
    .ToBe(Ord(wpdOk));
  Expect<Integer>(Length(Plan.Thunks)).ToBe(1);
  Expect<Integer>(Length(Plan.Thunks[0].Method.Params)).ToBe(1);
  Expect<Integer>(Ord(Plan.Thunks[0].Func.Params[0].Num)).ToBe(Ord(wntI32));
end;

procedure TConnectorPlanTests.TestNonNumericValueTypeRejected;
var
  Plan: TWlcConnectorPlan;
begin
  { $7B is v128: a connector signature is numeric only. }
  Expect<Integer>(Ord(DecodeConnectorPlan(MinimalThunk($7B, $00), Plan)))
    .ToBe(Ord(wpdBadValue));
  Expect<Integer>(Length(Plan.Thunks)).ToBe(0);
end;

procedure TConnectorPlanTests.TestNonCanonicalBooleanRejected;
var
  Plan: TWlcConnectorPlan;
begin
  Expect<Integer>(Ord(DecodeConnectorPlan(MinimalThunk($7F, $02), Plan)))
    .ToBe(Ord(wpdBadValue));
end;

procedure TConnectorPlanTests.TestOutOfRangeMarshalKindRejected;
var
  Section: TWasmBytes;
  Plan: TWlcConnectorPlan;
begin
  Section := MinimalThunk($7F, $00);
  { Byte 49 is the return marshal's kind; 99 names no UnmanagedType. }
  Expect<Integer>(Section[49]).ToBe(0);
  Section[49] := 99;
  Expect<Integer>(Ord(DecodeConnectorPlan(Section, Plan)))
    .ToBe(Ord(wpdBadValue));
end;

procedure TConnectorPlanTests.TestSizeConstWithoutFlagRejected;
var
  Section: TWasmBytes;
  Plan: TWlcConnectorPlan;
begin
  Section := MinimalThunk($7F, $00);
  { Bytes 51..54 are the return marshal's SizeConst; HasSizeConst (50)
    is 0. }
  Expect<Integer>(Section[50]).ToBe(0);
  Section[51] := 4;
  Expect<Integer>(Ord(DecodeConnectorPlan(Section, Plan)))
    .ToBe(Ord(wpdBadValue));
end;

procedure TConnectorPlanTests.TestTrailingByteRejected;
begin
  Expect<Integer>(Ord(DecodeResult(Concat(MinimalThunk($7F, $00),
    Bytes([$00]))))).ToBe(Ord(wpdTrailingBytes));
end;

procedure TConnectorPlanTests.TestEveryTruncationRejected;
var
  Full, Cut: TWasmBytes;
  Plan: TWlcConnectorPlan;
  N: Integer;
  AllRejected: Boolean;
begin
  Full := EncodeConnectorPlan(ResolveWlc(RICH_WLC, RICH_WAT));
  AllRejected := True;
  for N := 1 to Length(Full) - 1 do
  begin
    Cut := Copy(Full, 0, N);
    if DecodeConnectorPlan(Cut, Plan) = wpdOk then
      AllRejected := False;
  end;
  Expect<Boolean>(AllRejected).ToBe(True);
end;

procedure TConnectorPlanTests.TestCheckAcceptsTheResolvedPlan;
var
  Encoded: TWasmBytes;
  Plan: TWlcConnectorPlan;
begin
  Encoded := EncodeConnectorPlan(ResolveWlc(RICH_WLC, RICH_WAT));
  Plan := CheckConnectorPlanForModule(Encoded, LoadWat(RICH_WAT),
    [WLC_WASI_MODULE]);
  Expect<Integer>(Length(Plan.Thunks)).ToBe(3);
  Expect<string>(Plan.Thunks[0].NativeSymbol).ToBe('getpid');
end;

procedure TConnectorPlanTests.TestCheckRejectsARetargetedSymbol;
var
  Encoded: TWasmBytes;
  I: Integer;
  Msg: string;
begin
  { Rewrite the thunk's native symbol "getpid" to "getuid" in place: the
    section still decodes, but it is not what resolution produces. }
  Encoded := EncodeConnectorPlan(ResolveWlc(GETPID_WLC, GETPID_WAT));
  I := 0;
  while (I + 5 < Length(Encoded)) and not ((Encoded[I] = Ord('g')) and
    (Encoded[I + 3] = Ord('p')) and (Encoded[I + 4] = Ord('i')) and
    (Encoded[I + 5] = Ord('d'))) do
    Inc(I);
  { First "getpid" is the guest name; the native symbol follows the library. }
  Inc(I, 6);
  while (I + 5 < Length(Encoded)) and not ((Encoded[I] = Ord('g')) and
    (Encoded[I + 3] = Ord('p'))) do
    Inc(I);
  Encoded[I + 3] := Ord('u');
  Encoded[I + 4] := Ord('i');
  Expect<Integer>(Ord(DecodeResult(Encoded))).ToBe(Ord(wpdOk));
  Msg := CheckError(Encoded, GETPID_WAT);
  Expect<Boolean>(Pos(MSG_WLCP_MALFORMED, Msg) = 1).ToBe(True);
end;

procedure TConnectorPlanTests.TestCheckRejectsAPlanForAnotherModule;
var
  Encoded: TWasmBytes;
  Msg: string;
begin
  Encoded := EncodeConnectorPlan(ResolveWlc(GETPID_WLC, GETPID_WAT));
  Msg := CheckError(Encoded,
    '(module (import "Libc" "getpid" (func (result i64))))');
  Expect<Boolean>(Pos(MSG_WLCP_MALFORMED, Msg) = 1).ToBe(True);
end;

procedure TConnectorPlanTests.TestCheckRejectsMalformedBytes;
var
  Msg: string;
begin
  Msg := CheckError(Bytes([$57, $4C, $43, $50, $01, $00]), GETPID_WAT);
  Expect<Boolean>(Pos(MSG_WLCP_MALFORMED + ': truncated', Msg) = 1)
    .ToBe(True);
end;

procedure TConnectorPlanTests.SetupTests;
begin
  Test('an empty plan is an empty section', TestEmptyPlanIsEmptySection);
  Test('a rich plan round-trips every declaration kind',
    TestRichPlanRoundTrips);
  Test('encoding is deterministic', TestEncodingIsDeterministic);
  Test('source positions are not carried', TestSourcePositionsAreNotCarried);
  Test('an empty section decodes to the empty plan',
    TestEmptySectionDecodesToEmptyPlan);
  Test('bad magic is rejected', TestBadMagicRejected);
  Test('an unsupported version is rejected', TestUnsupportedVersionRejected);
  Test('a non-zero reserved field is rejected', TestNonZeroReservedRejected);
  Test('a truncated header is rejected', TestTruncatedHeaderRejected);
  Test('zero thunks is not canonical', TestZeroThunksRejected);
  Test('a count larger than the section is rejected',
    TestOversizedCountRejected);
  Test('a minimal well-formed section decodes', TestMinimalStructureAccepted);
  Test('a non-numeric wasm value type is rejected',
    TestNonNumericValueTypeRejected);
  Test('a non-canonical boolean is rejected', TestNonCanonicalBooleanRejected);
  Test('an out-of-range marshal kind is rejected',
    TestOutOfRangeMarshalKindRejected);
  Test('a SizeConst without its flag is rejected',
    TestSizeConstWithoutFlagRejected);
  Test('a trailing byte is rejected', TestTrailingByteRejected);
  Test('every proper prefix of a plan is rejected',
    TestEveryTruncationRejected);
  Test('the startup check accepts the resolved plan',
    TestCheckAcceptsTheResolvedPlan);
  Test('the startup check rejects a retargeted native symbol',
    TestCheckRejectsARetargetedSymbol);
  Test('the startup check rejects a plan for another module',
    TestCheckRejectsAPlanForAnotherModule);
  Test('the startup check rejects malformed bytes',
    TestCheckRejectsMalformedBytes);
end;

begin
  TestRunnerProgram.AddSuite(TConnectorPlanTests.Create('Wasm.Connector.Plan'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
