{ Unit suite for Wasm.Decoder.Types, the type section decoder.

  Section bodies are assembled byte-by-byte next to their assertions.
  The cases that matter are the grammar's edges: the rec/sub/comptype
  form codes are literal bytes (so overlong sLEB spellings of the same
  numbers match nothing), $4F is the FINAL sub form and $50 the
  non-final one, both encoding shorthands normalise into one model
  shape, and the body must be consumed exactly — leftover and shortfall
  are both malformed. What the grammar accepts must decode even when
  validation will later object: empty rec groups and dangling supertype
  indices are not this unit's business. }
program Wasm.Decoder.Types.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Types,
  Wasm.Module;

type
  TDecoderTypesTests = class(TTestSuite)
  private
    { The reader borrows its buffer, so the buffer must outlive every
      reader built over it — hence a suite field. }
    FBuffer: TWasmBytes;
    FModule: TWasmModule;

    { Decodes AValues as one complete type section body into FModule. }
    procedure DecodeSection(const AValues: array of Byte);
    procedure ExpectRejected(const ADescription: string;
      const AValues: array of Byte);
    { Asserts rejection and names the case in the failure message.
      Phrased as a value comparison rather than a bare Fail() so the
      test records an assertion even on the happy path. }
    procedure AssertRejected(const ADescription: string;
      const ARejected: Boolean);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestFuncType;
    procedure TestMultipleRecTypes;
    procedure TestStructTypeMixedFields;
    procedure TestArrayType;
    procedure TestExplicitRecGroup;
    procedure TestBareSubTypeMarkersOutsideRecGroup;
    procedure TestEmptyRecGroupIsWellFormed;
    procedure TestEmptySectionVector;
    procedure TestRejectsUnknownCompTypeCode;
    procedure TestRejectsBadStorageCode;
    procedure TestRejectsBadMutByte;
    procedure TestRejectsTruncatedVectors;
    procedure TestRejectsSectionSizeMismatch;
    procedure TestRejectsOverlongFormCodes;
  end;

procedure TDecoderTypesTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TDecoderTypesTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

procedure TDecoderTypesTests.DecodeSection(const AValues: array of Byte);
var
  I: Integer;
  Reader: TWasmReader;
begin
  SetLength(FBuffer, Length(AValues));
  for I := 0 to High(AValues) do
    FBuffer[I] := AValues[I];
  Reader.InitFromBytes(FBuffer);
  DecodeTypeSection(Reader, 0, FModule);
end;

procedure TDecoderTypesTests.ExpectRejected(const ADescription: string;
  const AValues: array of Byte);
var
  Rejected: Boolean;
begin
  Rejected := False;

  { The assertion is made after the try, not inside the handler: a
    Fail() in the try block would be swallowed, and FPC will not parse a
    generic call as the lone statement of an `on ... do`. }
  try
    DecodeSection(AValues);
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;

  AssertRejected(ADescription, Rejected);
end;

procedure TDecoderTypesTests.AssertRejected(const ADescription: string;
  const ARejected: Boolean);
var
  Outcome: string;
begin
  if ARejected then
    Outcome := 'rejected'
  else
    Outcome := 'ACCEPTED';
  Expect<string>(ADescription + ': ' + Outcome)
    .ToBe(ADescription + ': rejected');
end;

procedure TDecoderTypesTests.TestFuncType;
var
  Sub: TWasmSubType;
begin
  { (func (param i32 i64) (result f32)) — a bare comptype, which is
    shorthand for a FINAL subtype with no supertypes in a group of one. }
  DecodeSection([$01,
    $60, $02, $7F, $7E, $01, $7D]);

  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Expect<Integer>(Length(FModule.Types[0].SubTypes)).ToBe(1);

  Sub := FModule.Types[0].SubTypes[0];
  Expect<Boolean>(Sub.IsFinal).ToBe(True);
  Expect<Integer>(Length(Sub.SuperTypes)).ToBe(0);
  Expect<Boolean>(Sub.Comp.Kind = wckFunc).ToBe(True);
  Expect<Integer>(Length(Sub.Comp.Func.Params)).ToBe(2);
  Expect<string>(Sub.Comp.Func.Params[0].Describe).ToBe('i32');
  Expect<string>(Sub.Comp.Func.Params[1].Describe).ToBe('i64');
  Expect<Integer>(Length(Sub.Comp.Func.Results)).ToBe(1);
  Expect<string>(Sub.Comp.Func.Results[0].Describe).ToBe('f32');
end;

procedure TDecoderTypesTests.TestMultipleRecTypes;
begin
  { Two entries: (func) and (array i32) — each its own singleton group. }
  DecodeSection([$02,
    $60, $00, $00,
    $5E, $7F, $00]);

  Expect<Integer>(FModule.TypeCount).ToBe(2);
  Expect<Boolean>(FModule.Types[0].SubTypes[0].Comp.Kind = wckFunc)
    .ToBe(True);
  Expect<Integer>(Length(FModule.Types[0].SubTypes[0].Comp.Func.Params))
    .ToBe(0);
  Expect<Boolean>(FModule.Types[1].SubTypes[0].Comp.Kind = wckArray)
    .ToBe(True);
end;

procedure TDecoderTypesTests.TestStructTypeMixedFields;
var
  Struct: TWasmStructType;
begin
  { (struct (field (mut i8)) (field i16) (field i32) (field (mut
    funcref))) — packed and value storage, mutable and immutable, with
    the storage type FIRST and the mut byte second. }
  DecodeSection([$01,
    $5F, $04,
    $78, $01,
    $77, $00,
    $7F, $00,
    $70, $01]);

  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Struct := FModule.Types[0].SubTypes[0].Comp.Struct;
  Expect<Boolean>(FModule.Types[0].SubTypes[0].Comp.Kind = wckStruct)
    .ToBe(True);
  Expect<Integer>(Length(Struct.Fields)).ToBe(4);

  Expect<Boolean>(Struct.Fields[0].Storage.IsPacked).ToBe(True);
  Expect<Boolean>(Struct.Fields[0].Storage.PackedType = wpkI8).ToBe(True);
  Expect<string>(Struct.Fields[0].Describe).ToBe('(mut i8)');

  Expect<Boolean>(Struct.Fields[1].Storage.PackedType = wpkI16).ToBe(True);
  Expect<string>(Struct.Fields[1].Describe).ToBe('i16');

  Expect<Boolean>(Struct.Fields[2].Storage.IsPacked).ToBe(False);
  Expect<string>(Struct.Fields[2].Describe).ToBe('i32');

  Expect<string>(Struct.Fields[3].Describe).ToBe('(mut funcref)');
end;

procedure TDecoderTypesTests.TestArrayType;
var
  Elem: TWasmFieldType;
begin
  { (array (mut i8)) — one fieldtype, NOT a vector of them. }
  DecodeSection([$01,
    $5E, $78, $01]);

  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Expect<Boolean>(FModule.Types[0].SubTypes[0].Comp.Kind = wckArray)
    .ToBe(True);
  Elem := FModule.Types[0].SubTypes[0].Comp.Arr.Elem;
  Expect<string>(Elem.Describe).ToBe('(mut i8)');
end;

procedure TDecoderTypesTests.TestExplicitRecGroup;
var
  Rec: TWasmRecType;
begin
  { (rec (type (sub (struct (field (ref null 1)))))
         (type (sub final 0 (struct (field (mut (ref null 0))))))) —
    two mutually recursive structs, the first non-final ($50) with no
    supertypes, the second FINAL ($4F) with supertype 0. One rec group
    is ONE type-section entry. }
  DecodeSection([$01,
    $4E, $02,
    $50, $00, $5F, $01, $63, $01, $00,
    $4F, $01, $00, $5F, $01, $63, $00, $01]);

  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Rec := FModule.Types[0];
  Expect<Integer>(Length(Rec.SubTypes)).ToBe(2);

  Expect<Boolean>(Rec.SubTypes[0].IsFinal).ToBe(False);
  Expect<Integer>(Length(Rec.SubTypes[0].SuperTypes)).ToBe(0);
  Expect<Boolean>(Rec.SubTypes[0].Comp.Kind = wckStruct).ToBe(True);
  Expect<string>(Rec.SubTypes[0].Comp.Struct.Fields[0].Describe)
    .ToBe('(ref null 1)');

  Expect<Boolean>(Rec.SubTypes[1].IsFinal).ToBe(True);
  Expect<Integer>(Length(Rec.SubTypes[1].SuperTypes)).ToBe(1);
  Expect<Int64>(Int64(Rec.SubTypes[1].SuperTypes[0])).ToBe(0);
  Expect<string>(Rec.SubTypes[1].Comp.Struct.Fields[0].Describe)
    .ToBe('(mut (ref null 0))');
end;

procedure TDecoderTypesTests.TestBareSubTypeMarkersOutsideRecGroup;
begin
  { A subtype outside a rec group is a singleton group, whichever sub
    form it uses. The supertype index is an ordinary u32 and admits a
    zero-padded encoding ($82 $00 = 2) — unlike the form codes, which
    are literal bytes. }
  DecodeSection([$02,
    $50, $01, $82, $00, $60, $00, $00,
    $4F, $00, $60, $00, $00]);

  Expect<Integer>(FModule.TypeCount).ToBe(2);
  Expect<Integer>(Length(FModule.Types[0].SubTypes)).ToBe(1);
  Expect<Boolean>(FModule.Types[0].SubTypes[0].IsFinal).ToBe(False);
  Expect<Int64>(Int64(FModule.Types[0].SubTypes[0].SuperTypes[0])).ToBe(2);
  Expect<Boolean>(FModule.Types[1].SubTypes[0].IsFinal).ToBe(True);
  Expect<Integer>(Length(FModule.Types[1].SubTypes[0].SuperTypes)).ToBe(0);
end;

procedure TDecoderTypesTests.TestEmptyRecGroupIsWellFormed;
begin
  { $4E $00 — a rec group of none. The vec grammar admits zero, so this
    DECODES; whether it validates is the validator's question, and
    rejecting it here would corrupt the malformed/invalid split. }
  DecodeSection([$01, $4E, $00]);

  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Expect<Integer>(Length(FModule.Types[0].SubTypes)).ToBe(0);
end;

procedure TDecoderTypesTests.TestEmptySectionVector;
begin
  { A type section declaring zero entries is well-formed. }
  DecodeSection([$00]);
  Expect<Integer>(FModule.TypeCount).ToBe(0);
end;

procedure TDecoderTypesTests.TestRejectsUnknownCompTypeCode;
begin
  { $6E is the anyref value-type code — negative code space, but not a
    composite form. }
  ExpectRejected('value-type code as comptype', [$01, $6E]);
  ExpectRejected('index byte as comptype', [$01, $00]);
  ExpectRejected('unassigned code $5D as comptype', [$01, $5D]);
  { Inside an explicit rec group and after a sub prefix, same rule. }
  ExpectRejected('bad comptype inside rec group', [$01, $4E, $01, $6E]);
  ExpectRejected('bad comptype after sub prefix',
    [$01, $4F, $00, $6E]);
end;

procedure TDecoderTypesTests.TestRejectsBadStorageCode;
begin
  { $76 is -10, one below i16 — unassigned in both the packed and the
    value-type space. }
  ExpectRejected('unassigned storage code in struct field',
    [$01, $5F, $01, $76, $00]);
  ExpectRejected('unassigned storage code in array element',
    [$01, $5E, $76, $00]);
  { A bare type index is not a storage type — concrete references always
    carry a $63/$64 marker. }
  ExpectRejected('bare index as storage type', [$01, $5E, $05, $00]);
end;

procedure TDecoderTypesTests.TestRejectsBadMutByte;
begin
  ExpectRejected('mut byte $02 on array element', [$01, $5E, $7F, $02]);
  ExpectRejected('mut byte $FF on struct field',
    [$01, $5F, $01, $78, $FF]);
  ExpectRejected('missing mut byte', [$01, $5E, $7F]);
end;

procedure TDecoderTypesTests.TestRejectsTruncatedVectors;
begin
  ExpectRejected('empty section body', []);
  { Declared counts overrunning the remaining bytes, at every vector in
    the grammar: params, fields, supertypes, and the rec group itself. }
  ExpectRejected('param vector overruns body', [$01, $60, $05, $7F]);
  ExpectRejected('result vector overruns body',
    [$01, $60, $00, $03, $7F]);
  ExpectRejected('field vector overruns body', [$01, $5F, $02, $7F, $00]);
  ExpectRejected('supertype vector overruns body', [$01, $4F, $03, $00]);
  ExpectRejected('rec group overruns body', [$01, $4E, $02, $60, $00]);
  ExpectRejected('rec marker with nothing after it', [$01, $4E]);
end;

procedure TDecoderTypesTests.TestRejectsSectionSizeMismatch;
begin
  { Leftover: the declared vector ends before the body does. }
  ExpectRejected('one trailing byte after last entry',
    [$01, $60, $00, $00, $00]);
  ExpectRejected('whole extra functype after declared count',
    [$01, $60, $00, $00, $60, $00, $00]);
  { Shortfall: the declared vector needs more bytes than the body has. }
  ExpectRejected('declared second entry missing', [$02, $60, $00, $00]);
  ExpectRejected('functype cut mid-params', [$01, $60, $01]);
end;

procedure TDecoderTypesTests.TestRejectsOverlongFormCodes;
begin
  { The form codes are literal bytes, not sLEB values. Each pair below
    spells the right NUMBER in two bytes — $CE $7F is -50 (rec), $D0 $7F
    is -48 (sub), $E0 $7F is -32 (func), $F8 $7F is -8 (i8) — and every
    one of them matches no production. }
  ExpectRejected('overlong rec code', [$01, $CE, $7F, $01, $60, $00, $00]);
  ExpectRejected('overlong sub code',
    [$01, $D0, $7F, $00, $60, $00, $00]);
  ExpectRejected('overlong func code', [$01, $E0, $7F, $00, $00]);
  ExpectRejected('overlong packed code in array element',
    [$01, $5E, $F8, $7F, $00]);
end;

procedure TDecoderTypesTests.SetupTests;
begin
  Test('functype decodes as a final singleton group', TestFuncType);
  Test('multiple entries each form their own group',
    TestMultipleRecTypes);
  Test('struct with mixed packed/value mutable/immutable fields',
    TestStructTypeMixedFields);
  Test('array carries one fieldtype', TestArrayType);
  Test('explicit rec group with sub and sub-final members',
    TestExplicitRecGroup);
  Test('bare subtype markers form singleton groups',
    TestBareSubTypeMarkersOutsideRecGroup);
  Test('empty rec group is well-formed', TestEmptyRecGroupIsWellFormed);
  Test('empty section vector is well-formed', TestEmptySectionVector);
  Test('rejects unknown comptype codes', TestRejectsUnknownCompTypeCode);
  Test('rejects unassigned storage codes', TestRejectsBadStorageCode);
  Test('rejects bad mut bytes', TestRejectsBadMutByte);
  Test('rejects truncated vectors', TestRejectsTruncatedVectors);
  Test('rejects section size mismatch both directions',
    TestRejectsSectionSizeMismatch);
  Test('rejects overlong spellings of literal form codes',
    TestRejectsOverlongFormCodes);
end;

begin
  TestRunnerProgram.AddSuite(
    TDecoderTypesTests.Create('Wasm.Decoder.Types'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
