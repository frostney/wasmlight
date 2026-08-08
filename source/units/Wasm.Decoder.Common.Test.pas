{ Unit suite for Wasm.Decoder.Common's shared type-form readers.

  The cases that matter are the grammar's edges: the type codes are
  literal bytes rather than sLEB values (so overlong spellings of valid
  codes are malformed), limits carry u64 bounds under BOTH address types
  with exactly four assigned flag bytes, and the mut/attribute bytes have
  tiny assigned ranges. Malformed inputs are spelled as literal bytes
  next to their assertions. }
program Wasm.Decoder.Common.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Common;

type
  TDecoderCommonTests = class(TTestSuite)
  private
    { The reader borrows its buffer, so the buffer must outlive every
      reader built over it — hence a suite field. }
    FBuffer: TWasmBytes;

    function ReaderOver(const AValues: array of Byte): TWasmReader;
    { Runs the reader named by AReadKind over AValues and asserts it
      raises EWasmDecodeError. }
    procedure ExpectRejected(const AReadKind, ADescription: string;
      const AValues: array of Byte);
    procedure AssertRejected(const ADescription: string;
      const ARejected: Boolean);
  public
    procedure SetupTests; override;

    procedure TestValueTypeNumAndVec;
    procedure TestValueTypeShortRefForms;
    procedure TestValueTypeLongRefForms;
    procedure TestValueTypeRejectsUnassignedCodes;
    procedure TestValueTypeRejectsOverlongCodes;
    procedure TestHeapTypeAbstractAndConcrete;
    procedure TestHeapTypeAcceptsPaddedIndex;
    procedure TestHeapTypeRejectsMalformed;
    procedure TestRefTypeShortAndLongForms;
    procedure TestRefTypeRejectsMalformed;
    procedure TestLimitsAllFlagForms;
    procedure TestLimitsMinAboveMaxDecodes;
    procedure TestLimitsBoundsAreU64UnderBothAddrTypes;
    procedure TestLimitsRejectsUndefinedFlags;
    procedure TestLimitsRejectsTruncatedForms;
    procedure TestTableType;
    procedure TestTableTypeRejectsMalformed;
    procedure TestMemType;
    procedure TestGlobalType;
    procedure TestGlobalTypeRejectsMalformed;
    procedure TestTagType;
    procedure TestTagTypeRejectsMalformed;
  end;

function TDecoderCommonTests.ReaderOver(
  const AValues: array of Byte): TWasmReader;
var
  I: Integer;
begin
  SetLength(FBuffer, Length(AValues));
  for I := 0 to High(AValues) do
    FBuffer[I] := AValues[I];
  Result.InitFromBytes(FBuffer);
end;

procedure TDecoderCommonTests.ExpectRejected(
  const AReadKind, ADescription: string; const AValues: array of Byte);
var
  Reader: TWasmReader;
  Rejected: Boolean;
begin
  if (AReadKind <> 'heaptype') and (AReadKind <> 'reftype')
     and (AReadKind <> 'valtype') and (AReadKind <> 'limits')
     and (AReadKind <> 'tabletype') and (AReadKind <> 'memtype')
     and (AReadKind <> 'globaltype') and (AReadKind <> 'tagtype') then
    Fail('unknown read kind ' + AReadKind);

  Reader := ReaderOver(AValues);
  Rejected := False;

  { The assertion is made after the try, not inside the handler: a Fail()
    in the try block would be swallowed, and FPC will not parse a generic
    call as the lone statement of an `on ... do`. }
  try
    if AReadKind = 'heaptype' then
      ReadHeapType(Reader)
    else if AReadKind = 'reftype' then
      ReadRefType(Reader)
    else if AReadKind = 'valtype' then
      ReadValueType(Reader)
    else if AReadKind = 'limits' then
      ReadLimits(Reader)
    else if AReadKind = 'tabletype' then
      ReadTableType(Reader)
    else if AReadKind = 'memtype' then
      ReadMemType(Reader)
    else if AReadKind = 'globaltype' then
      ReadGlobalType(Reader)
    else
      ReadTagType(Reader);
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;

  AssertRejected(ADescription, Rejected);
end;

procedure TDecoderCommonTests.AssertRejected(const ADescription: string;
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

procedure TDecoderCommonTests.TestValueTypeNumAndVec;
var
  R: TWasmReader;
begin
  R := ReaderOver([$7F, $7E, $7D, $7C, $7B]);
  Expect<string>(ReadValueType(R).Describe).ToBe('i32');
  Expect<string>(ReadValueType(R).Describe).ToBe('i64');
  Expect<string>(ReadValueType(R).Describe).ToBe('f32');
  Expect<string>(ReadValueType(R).Describe).ToBe('f64');
  Expect<string>(ReadValueType(R).Describe).ToBe('v128');
  Expect<Boolean>(R.Eof).ToBe(True);
end;

procedure TDecoderCommonTests.TestValueTypeShortRefForms;
var
  R: TWasmReader;
begin
  { A bare abstract heap type byte is a NULLABLE reference to it. }
  R := ReaderOver([$70, $6F, $6E, $71]);
  Expect<string>(ReadValueType(R).Describe).ToBe('funcref');
  Expect<string>(ReadValueType(R).Describe).ToBe('externref');
  Expect<string>(ReadValueType(R).Describe).ToBe('anyref');
  Expect<string>(ReadValueType(R).Describe).ToBe('nullref');
end;

procedure TDecoderCommonTests.TestValueTypeLongRefForms;
var
  R: TWasmReader;
begin
  { $63 = ref null ht, $64 = ref ht; the heap type is an s33 that may be
    abstract or a concrete type index. }
  R := ReaderOver([$63, $02, $64, $70, $64, $02]);
  Expect<string>(ReadValueType(R).Describe).ToBe('(ref null 2)');
  Expect<string>(ReadValueType(R).Describe).ToBe('(ref func)');
  Expect<string>(ReadValueType(R).Describe).ToBe('(ref 2)');
end;

procedure TDecoderCommonTests.TestValueTypeRejectsUnassignedCodes;
begin
  { A bare non-negative code is a type INDEX, which is not a value type —
    reference-typed values always carry a $63/$64 marker. }
  ExpectRejected('valtype', 'bare index $00', [$00]);
  ExpectRejected('valtype', 'bare index $2A', [$2A]);
  { Unassigned negative codes: $76 is -10, $61 is -31. }
  ExpectRejected('valtype', 'unassigned code $76', [$76]);
  ExpectRejected('valtype', 'unassigned code $61', [$61]);
  ExpectRejected('valtype', 'empty input', []);
end;

procedure TDecoderCommonTests.TestValueTypeRejectsOverlongCodes;
begin
  { The value type codes are literal bytes in the grammar; $FF $7F spells
    -1 (i32) as a two-byte sLEB but matches no production. }
  ExpectRejected('valtype', 'overlong i32', [$FF, $7F]);
  ExpectRejected('valtype', 'overlong funcref', [$F0, $7F]);
end;

procedure TDecoderCommonTests.TestHeapTypeAbstractAndConcrete;
var
  R: TWasmReader;
  Heap: TWasmHeapType;
begin
  R := ReaderOver([$6E, $70, $00, $2A]);
  Expect<string>(ReadHeapType(R).Describe).ToBe('any');
  Expect<string>(ReadHeapType(R).Describe).ToBe('func');
  Heap := ReadHeapType(R);
  Expect<Boolean>(Heap.IsAbstract).ToBe(False);
  Expect<Int64>(Int64(Heap.TypeIndex)).ToBe(0);
  Expect<Int64>(Int64(ReadHeapType(R).TypeIndex)).ToBe(42);
end;

procedure TDecoderCommonTests.TestHeapTypeAcceptsPaddedIndex;
var
  R: TWasmReader;
begin
  { The uN/sN grammars allow zero-padded encodings within the width
    limit, and a concrete heap type is an s33 — so a padded INDEX is
    well-formed even though a padded abstract CODE is not. }
  R := ReaderOver([$81, $00]);
  Expect<Int64>(Int64(ReadHeapType(R).TypeIndex)).ToBe(1);
  Expect<Boolean>(R.Eof).ToBe(True);
end;

procedure TDecoderCommonTests.TestHeapTypeRejectsMalformed;
begin
  { $60 is -32 (the func comptype code), negative but not a heap type. }
  ExpectRejected('heaptype', 'non-heap negative code $60', [$60]);
  { $E9 $7F spells -23 (exn) as two bytes; the abstract alternatives are
    single-byte literal productions, so this matches nothing. }
  ExpectRejected('heaptype', 'overlong abstract code', [$E9, $7F]);
  ExpectRejected('heaptype', 'empty input', []);
  { s33 encodings wider than 5 bytes fail in the reader itself. }
  ExpectRejected('heaptype', 'over-wide s33',
    [$80, $80, $80, $80, $80, $00]);
end;

procedure TDecoderCommonTests.TestRefTypeShortAndLongForms;
var
  R: TWasmReader;
begin
  R := ReaderOver([$70, $63, $03, $64, $03, $64, $6F]);
  Expect<string>(ReadRefType(R).Describe).ToBe('funcref');
  Expect<string>(ReadRefType(R).Describe).ToBe('(ref null 3)');
  Expect<string>(ReadRefType(R).Describe).ToBe('(ref 3)');
  Expect<string>(ReadRefType(R).Describe).ToBe('(ref extern)');
end;

procedure TDecoderCommonTests.TestRefTypeRejectsMalformed;
begin
  { A number type is not a reference type. }
  ExpectRejected('reftype', 'numeric code $7F', [$7F]);
  { $F0 $7F spells -16 (func) as two bytes — not the short form. }
  ExpectRejected('reftype', 'overlong short form', [$F0, $7F]);
  { $E3 $7F spells -29, the same NUMBER as the $63 marker, but the marker
    is a literal byte and must not match an sLEB spelling of it. }
  ExpectRejected('reftype', 'overlong long-form marker', [$E3, $7F]);
  ExpectRejected('reftype', 'marker with no heap type', [$63]);
  ExpectRejected('reftype', 'marker with bad heap type', [$63, $76]);
  ExpectRejected('reftype', 'empty input', []);
end;

procedure TDecoderCommonTests.TestLimitsAllFlagForms;
var
  R: TWasmReader;
  Limits: TWasmLimits;
begin
  { The four assigned flag bytes: bit 0 = max present, bit 2 = i64. }
  R := ReaderOver([$00, $01]);
  Limits := ReadLimits(R);
  Expect<Boolean>(Limits.AddrType = watI32).ToBe(True);
  Expect<Boolean>(Limits.HasMax).ToBe(False);
  Expect<string>(Limits.Describe).ToBe('1');
  Expect<Boolean>(R.Eof).ToBe(True);

  R := ReaderOver([$01, $01, $02]);
  Expect<string>(ReadLimits(R).Describe).ToBe('1 2');

  R := ReaderOver([$04, $00]);
  Limits := ReadLimits(R);
  Expect<Boolean>(Limits.AddrType = watI64).ToBe(True);
  Expect<string>(Limits.Describe).ToBe('i64 0');

  R := ReaderOver([$05, $01, $02]);
  Expect<string>(ReadLimits(R).Describe).ToBe('i64 1 2');
end;

procedure TDecoderCommonTests.TestLimitsMinAboveMaxDecodes;
var
  R: TWasmReader;
  Limits: TWasmLimits;
begin
  { min 5, max 1: the "n <= m" requirement lives in the VALIDATION
    chapter (valid-limits — "Limits must have meaningful bounds"), not
    the binary grammar, so this DECODES fine and is the validator's
    problem. Rejecting it here would misfile an invalid module as
    malformed. }
  R := ReaderOver([$01, $05, $01]);
  Limits := ReadLimits(R);
  Expect<Boolean>(Limits.HasMax).ToBe(True);
  Expect<Boolean>(Limits.Min = 5).ToBe(True);
  Expect<Boolean>(Limits.Max = 1).ToBe(True);
  Expect<Boolean>(R.Eof).ToBe(True);
end;

procedure TDecoderCommonTests.TestLimitsBoundsAreU64UnderBothAddrTypes;
var
  R: TWasmReader;
  Limits: TWasmLimits;
begin
  { The bounds are u64 in EVERY alternative, including the i32 ones — a
    min of 2^32 under flags $00 decodes fine; rejecting it against the
    address type is validation's job, not the decoder's. }
  R := ReaderOver([$00, $80, $80, $80, $80, $10]);
  Limits := ReadLimits(R);
  Expect<Boolean>(Limits.AddrType = watI32).ToBe(True);
  Expect<Boolean>(Limits.Min = UInt64(1) shl 32).ToBe(True);

  { And a full 10-byte u64 max under i64. }
  R := ReaderOver([$05, $00,
    $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $01]);
  Limits := ReadLimits(R);
  Expect<Boolean>(Limits.Max = High(UInt64)).ToBe(True);
end;

procedure TDecoderCommonTests.TestLimitsRejectsUndefinedFlags;
begin
  { $02/$03 are the threads proposal's shared-memory bit, which is NOT in
    the 3.0 grammar this project pins — as malformed as any other
    unassigned value. }
  ExpectRejected('limits', 'shared bit $02', [$02, $01]);
  ExpectRejected('limits', 'shared bit $03', [$03, $01, $02]);
  ExpectRejected('limits', 'undefined flags $06', [$06, $01]);
  ExpectRejected('limits', 'undefined flags $07', [$07, $01, $02]);
  ExpectRejected('limits', 'undefined flags $08', [$08, $01]);
  ExpectRejected('limits', 'undefined flags $FF', [$FF, $01]);
end;

procedure TDecoderCommonTests.TestLimitsRejectsTruncatedForms;
begin
  ExpectRejected('limits', 'empty input', []);
  ExpectRejected('limits', 'flags without min', [$00]);
  ExpectRejected('limits', 'declared max missing', [$01, $01]);
  ExpectRejected('limits', 'min cut mid-LEB', [$00, $80]);
end;

procedure TDecoderCommonTests.TestTableType;
var
  R: TWasmReader;
  Table: TWasmTableType;
begin
  { Element type FIRST, then limits. }
  R := ReaderOver([$70, $01, $00, $0A]);
  Table := ReadTableType(R);
  Expect<string>(Table.Describe).ToBe('0 10 funcref');
  Expect<Boolean>(R.Eof).ToBe(True);

  { Long-form element type with an i64-addressed table. }
  R := ReaderOver([$63, $05, $04, $01]);
  Expect<string>(ReadTableType(R).Describe).ToBe('i64 1 (ref null 5)');
end;

procedure TDecoderCommonTests.TestTableTypeRejectsMalformed;
begin
  { A number type cannot be a table's element type — and that is a decode
    error, because reftype is a distinct grammar production. }
  ExpectRejected('tabletype', 'numeric element type', [$7F, $00, $00]);
  ExpectRejected('tabletype', 'bad limits flags', [$70, $02, $00]);
  ExpectRejected('tabletype', 'truncated limits', [$70]);
end;

procedure TDecoderCommonTests.TestMemType;
var
  R: TWasmReader;
begin
  R := ReaderOver([$01, $01, $02]);
  Expect<string>(ReadMemType(R).Describe).ToBe('1 2');
  R := ReaderOver([$04, $00]);
  Expect<string>(ReadMemType(R).Describe).ToBe('i64 0');
end;

procedure TDecoderCommonTests.TestGlobalType;
var
  R: TWasmReader;
begin
  { Value type first, then the mutability byte. }
  R := ReaderOver([$7F, $00, $7E, $01, $63, $01, $01]);
  Expect<string>(ReadGlobalType(R).Describe).ToBe('i32');
  Expect<string>(ReadGlobalType(R).Describe).ToBe('(mut i64)');
  Expect<string>(ReadGlobalType(R).Describe).ToBe('(mut (ref null 1))');
  Expect<Boolean>(R.Eof).ToBe(True);
end;

procedure TDecoderCommonTests.TestGlobalTypeRejectsMalformed;
begin
  ExpectRejected('globaltype', 'mutability byte $02', [$7F, $02]);
  ExpectRejected('globaltype', 'mutability byte $FF', [$7F, $FF]);
  ExpectRejected('globaltype', 'missing mutability byte', [$7F]);
  ExpectRejected('globaltype', 'bad value type', [$00, $00]);
end;

procedure TDecoderCommonTests.TestTagType;
var
  R: TWasmReader;
begin
  R := ReaderOver([$00, $05]);
  Expect<Int64>(Int64(ReadTagType(R).TypeIndex)).ToBe(5);
  Expect<Boolean>(R.Eof).ToBe(True);
end;

procedure TDecoderCommonTests.TestTagTypeRejectsMalformed;
begin
  { $00 is the only assigned attribute byte. }
  ExpectRejected('tagtype', 'attribute byte $01', [$01, $05]);
  ExpectRejected('tagtype', 'attribute byte $FF', [$FF, $05]);
  ExpectRejected('tagtype', 'missing type index', [$00]);
  ExpectRejected('tagtype', 'empty input', []);
end;

procedure TDecoderCommonTests.SetupTests;
begin
  Test('value types: numbers and v128', TestValueTypeNumAndVec);
  Test('value types: short reference forms', TestValueTypeShortRefForms);
  Test('value types: long reference forms', TestValueTypeLongRefForms);
  Test('value types reject unassigned codes',
    TestValueTypeRejectsUnassignedCodes);
  Test('value types reject overlong codes',
    TestValueTypeRejectsOverlongCodes);
  Test('heap types: abstract and concrete', TestHeapTypeAbstractAndConcrete);
  Test('heap types accept padded indices', TestHeapTypeAcceptsPaddedIndex);
  Test('heap types reject malformed codes', TestHeapTypeRejectsMalformed);
  Test('reference types: short and long forms',
    TestRefTypeShortAndLongForms);
  Test('reference types reject malformed forms',
    TestRefTypeRejectsMalformed);
  Test('limits: all four flag forms', TestLimitsAllFlagForms);
  Test('limits with min above max decode fine',
    TestLimitsMinAboveMaxDecodes);
  Test('limits bounds are u64 under both address types',
    TestLimitsBoundsAreU64UnderBothAddrTypes);
  Test('limits reject undefined flags', TestLimitsRejectsUndefinedFlags);
  Test('limits reject truncated forms', TestLimitsRejectsTruncatedForms);
  Test('table types', TestTableType);
  Test('table types reject malformed forms', TestTableTypeRejectsMalformed);
  Test('memory types', TestMemType);
  Test('global types', TestGlobalType);
  Test('global types reject malformed forms',
    TestGlobalTypeRejectsMalformed);
  Test('tag types', TestTagType);
  Test('tag types reject malformed forms', TestTagTypeRejectsMalformed);
end;

begin
  TestRunnerProgram.AddSuite(
    TDecoderCommonTests.Create('Wasm.Decoder.Common'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
