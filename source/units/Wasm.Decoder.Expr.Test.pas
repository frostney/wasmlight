{ Unit suite for Wasm.Decoder.Expr's expression skipper.

  The happy paths pin the exact span arithmetic — offset and size,
  including the ABase shift — over hand-assembled instruction sequences
  spanning every immediate-shape family: block nesting, branch tables,
  both memarg forms (with and without the bit-6 memory index), vector
  constants and lanes, GC heap-type immediates, try_table's catch
  vector, and typed select. One case deliberately mixes non-constant
  instructions into an "init expression" to prove the skipper does not
  police constness — that split belongs to the validator.

  Malformed inputs are spelled as literal bytes next to the assertion:
  unassigned opcodes and prefixed subopcodes, misplaced and repeated
  else delimiters, truncated immediates, truncated br_table vectors,
  out-of-range memarg flags, and unterminated expressions. }
program Wasm.Decoder.Expr.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Expr,
  Wasm.Module;

type
  TDecoderExprTests = class(TTestSuite)
  private
    { The reader borrows its buffer, so the buffer must outlive every
      reader built over it — hence a suite field. }
    FBuffer: TWasmBytes;

    function ReaderOver(const AValues: array of Byte): TWasmReader;
    { Skips one expr over AValues with ABase = 0 and asserts the span
      covers all of it and the reader stopped exactly past the end. }
    procedure ExpectSkipsWhole(const ADescription: string;
      const AValues: array of Byte);
    { Runs SkipExpr over AValues and asserts it raises
      EWasmDecodeError. }
    procedure ExpectRejected(const ADescription: string;
      const AValues: array of Byte);
    procedure AssertRejected(const ADescription: string;
      const ARejected: Boolean);
  public
    procedure SetupTests; override;

    procedure TestTrivialConstExpr;
    procedure TestSpanUsesBaseAndStart;
    procedure TestNestedBlocksWithBranchTable;
    procedure TestIfElse;
    procedure TestMemargWithoutMemoryIndex;
    procedure TestMemargWithMemoryIndex;
    procedure TestMemargOffsetIsU64;
    procedure TestVectorConstAndShuffle;
    procedure TestVectorLaneAndLaneMemoryOps;
    procedure TestRelaxedVectorSubopcode;
    procedure TestGcInstructions;
    procedure TestBrOnCast;
    procedure TestTryTable;
    procedure TestSelectWithTypes;
    procedure TestBulkMemoryAndTableOps;
    procedure TestNonConstMixSkipsFine;
    procedure TestRefNullAndFloatConsts;

    procedure TestPaddedBlockTypeIndex;
    procedure TestMemargFlagsAtUpperBound;

    procedure TestRejectsUnknownOpcodes;
    procedure TestRejectsMisplacedElse;
    procedure TestRejectsUnknownMiscSubopcode;
    procedure TestRejectsUnknownVecSubopcodes;
    procedure TestRejectsUnknownAggrSubopcode;
    procedure TestRejectsTruncatedImmediates;
    procedure TestRejectsUnterminatedExpr;
    procedure TestRejectsTruncatedBrTable;
    procedure TestRejectsBadMemargFlags;
    procedure TestRejectsBadCastFlags;
    procedure TestRejectsBadCatchKind;
    procedure TestRejectsBadBlockType;
    procedure TestExprMessagePrefixes;
  end;

function TDecoderExprTests.ReaderOver(
  const AValues: array of Byte): TWasmReader;
var
  I: Integer;
begin
  SetLength(FBuffer, Length(AValues));
  for I := 0 to High(AValues) do
    FBuffer[I] := AValues[I];
  Result.InitFromBytes(FBuffer);
end;

procedure TDecoderExprTests.ExpectSkipsWhole(const ADescription: string;
  const AValues: array of Byte);
var
  Reader: TWasmReader;
  Span: TWasmSpan;
begin
  Reader := ReaderOver(AValues);
  Span := SkipExpr(Reader, 0);
  { The description is embedded in the compared values, so a failure
    names the case — and the assertion can genuinely fail, unlike a
    bare Expect(AWhat).ToBe(AWhat). }
  Expect<string>(ADescription + ': span ' + IntToStr(Int64(Span.Offset))
      + '+' + IntToStr(Int64(Span.Size)))
    .ToBe(ADescription + ': span 0+' + IntToStr(Length(AValues)));
  Expect<Boolean>(Reader.Eof).ToBe(True);
end;

procedure TDecoderExprTests.ExpectRejected(const ADescription: string;
  const AValues: array of Byte);
var
  Reader: TWasmReader;
  Rejected: Boolean;
begin
  Reader := ReaderOver(AValues);
  Rejected := False;

  { The assertion is made after the try, not inside the handler: a
    Fail() in the try block would be swallowed by the handler, and FPC
    will not parse a generic call as the lone statement of an
    `on ... do`. }
  try
    SkipExpr(Reader, 0);
  except
    on E: EWasmDecodeError do
      Rejected := True;
  end;

  AssertRejected(ADescription, Rejected);
end;

procedure TDecoderExprTests.AssertRejected(const ADescription: string;
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

procedure TDecoderExprTests.TestTrivialConstExpr;
begin
  { i32.const 1; end }
  ExpectSkipsWhole('i32.const 1', [$41, $01, $0B]);
end;

procedure TDecoderExprTests.TestSpanUsesBaseAndStart;
var
  Reader: TWasmReader;
  Span: TWasmSpan;
begin
  { The expr starts at reader position 2, and ABase says the reader's
    byte 0 sits at absolute offset 100 — so the span starts at 102.
    The trailing $FF is deliberately NOT part of the expr and must be
    left unread. }
  Reader := ReaderOver([$00, $00, $41, $2A, $0B, $FF]);
  Reader.Skip(2);
  Span := SkipExpr(Reader, 100);
  Expect<Int64>(Int64(Span.Offset)).ToBe(102);
  Expect<Int64>(Int64(Span.Size)).ToBe(3);
  Expect<Int64>(Int64(Reader.Position)).ToBe(5);
end;

procedure TDecoderExprTests.TestNestedBlocksWithBranchTable;
begin
  { block (empty) / block (result i32) / br_table with two targets and
    a default / two ends / end. }
  ExpectSkipsWhole('nested blocks with br_table',
    [$02, $40,                      { block (empty) }
     $02, $7F,                      { block (result i32) }
     $41, $00,                      { i32.const 0 }
     $0E, $02, $00, $01, $01,       { br_table 0 1 default 1 }
     $0B, $0B,                      { end end }
     $0B]);                         { end of expr }
end;

procedure TDecoderExprTests.TestIfElse;
begin
  ExpectSkipsWhole('if/else',
    [$41, $01,                      { i32.const 1 }
     $04, $7F,                      { if (result i32) }
     $41, $02,                      { i32.const 2 }
     $05,                           { else }
     $41, $03,                      { i32.const 3 }
     $0B,                           { end (if) }
     $0B]);                         { end of expr }
end;

procedure TDecoderExprTests.TestMemargWithoutMemoryIndex;
begin
  { Flags below 2^6 carry no memory index: align 2, offset 8. }
  ExpectSkipsWhole('i32.load without memidx',
    [$41, $00, $28, $02, $08, $0B]);
end;

procedure TDecoderExprTests.TestMemargWithMemoryIndex;
begin
  { Bit 6 of the flags ($42 = $40 or align 2) inserts a memidx between
    the align and the offset — the 3.0 multi-memory form. }
  ExpectSkipsWhole('i32.load with memidx',
    [$41, $00, $28, $42, $03, $08, $0B]);
end;

procedure TDecoderExprTests.TestMemargOffsetIsU64;
begin
  { The offset field is a u64: 2^32 (encoded $80 $80 $80 $80 $10) does
    not fit a u32 LEB128 and MUST be accepted here. }
  ExpectSkipsWhole('i64.load with 2^32 offset',
    [$42, $00, $29, $03, $80, $80, $80, $80, $10, $0B]);
end;

procedure TDecoderExprTests.TestVectorConstAndShuffle;
begin
  { v128.const (16 literal bytes) then i8x16.shuffle (16 laneidx
    bytes); shuffle's operands are two v128s. }
  ExpectSkipsWhole('v128.const and i8x16.shuffle',
    [$FD, $0C, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
     $FD, $0C, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
     $FD, $0D, 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26,
     28, 30,
     $0B]);
end;

procedure TDecoderExprTests.TestVectorLaneAndLaneMemoryOps;
begin
  ExpectSkipsWhole('lane ops and lane loads',
    [$FD, $0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     $FD, $15, $07,                 { i8x16.extract_lane_s 7 }
     $41, $00,                      { i32.const 0 }
     $FD, $0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     $FD, $54, $00, $04, $01,       { v128.load8_lane align 0 off 4 lane 1 }
     $0B]);
end;

procedure TDecoderExprTests.TestRelaxedVectorSubopcode;
begin
  { The relaxed operations sit at subopcodes 256..275, so their LEB128
    spelling is genuinely multi-byte: $80 $02 = 256 (i8x16.relaxed_swizzle). }
  ExpectSkipsWhole('relaxed swizzle (subopcode 256)',
    [$FD, $0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     $FD, $0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     $FD, $80, $02,
     $0B]);
end;

procedure TDecoderExprTests.TestGcInstructions;
begin
  ExpectSkipsWhole('aggregate instructions',
    [$FB, $00, $02,                 { struct.new (type 2) }
     $FB, $02, $02, $01,            { struct.get (type 2, field 1) }
     $FB, $14, $6E,                 { ref.test (any) — heap type imm }
     $FB, $17, $6E,                 { ref.cast null (any) }
     $FB, $1C,                      { ref.i31 }
     $0B]);
end;

procedure TDecoderExprTests.TestBrOnCast;
begin
  { br_on_cast: castflags byte, labelidx, and TWO heap types — the
    second here a concrete type index. }
  ExpectSkipsWhole('br_on_cast',
    [$02, $40,
     $D0, $6E,                      { ref.null any }
     $FB, $18, $01, $00, $6E, $05,  { br_on_cast (null1) 0 any (type 5) }
     $1A,                           { drop }
     $0B,
     $0B]);
end;

procedure TDecoderExprTests.TestTryTable;
begin
  { try_table with a two-clause catch vector: catch (tag 0, label 0)
    and catch_all_ref (label 1); its body is closed by its own end. }
  ExpectSkipsWhole('try_table',
    [$1F, $40,                      { try_table (empty) }
     $02,                           { two catch clauses }
     $00, $00, $00,                 { catch tag 0 -> label 0 }
     $03, $01,                      { catch_all_ref -> label 1 }
     $01,                           { nop }
     $0B,                           { end (try_table) }
     $0B]);                         { end of expr }
end;

procedure TDecoderExprTests.TestSelectWithTypes;
begin
  ExpectSkipsWhole('typed select',
    [$41, $01, $41, $02, $41, $00,
     $1C, $01, $7F,                 { select (result i32) }
     $1A,
     $41, $01, $41, $02, $41, $00,
     $1C, $01, $63, $05,            { select (result (ref null 5)) }
     $0B]);
end;

procedure TDecoderExprTests.TestBulkMemoryAndTableOps;
begin
  ExpectSkipsWhole('bulk memory and table instructions',
    [$FC, $08, $01, $00,            { memory.init data 1 mem 0 }
     $FC, $0A, $00, $00,            { memory.copy mem 0 mem 0 }
     $FC, $0B, $00,                 { memory.fill mem 0 }
     $FC, $0C, $02, $00,            { table.init elem 2 table 0 }
     $FC, $11, $00,                 { table.fill table 0 }
     $FC, $00,                      { i32.trunc_sat_f32_s }
     $0B]);
end;

procedure TDecoderExprTests.TestNonConstMixSkipsFine;
begin
  { None of this is constant, and much of it is ill-typed — the skipper
    must not care. Constness and typing are validation rules; only the
    GRAMMAR is checked here. }
  ExpectSkipsWhole('non-constant instruction mix',
    [$01,                           { nop }
     $20, $00,                      { local.get 0 }
     $41, $07, $6A,                 { i32.const 7; i32.add }
     $10, $03,                      { call 3 }
     $11, $01, $00,                 { call_indirect (type 1) (table 0) }
     $40, $00,                      { memory.grow mem 0 }
     $1A,                           { drop }
     $0B]);
end;

procedure TDecoderExprTests.TestRefNullAndFloatConsts;
begin
  ExpectSkipsWhole('ref.null and float constants',
    [$D0, $70,                      { ref.null func }
     $D1,                           { ref.is_null }
     $43, $00, $00, $80, $3F,       { f32.const 1.0 }
     $44, $00, $00, $00, $00, $00, $00, $F0, $3F, { f64.const 1.0 }
     $42, $80, $01,                 { i64.const 128 }
     $0B]);
end;

procedure TDecoderExprTests.TestPaddedBlockTypeIndex;
begin
  { The block type's index arm is a genuine s33, and the uN/sN grammars
    admit zero-padded encodings within the width limit — $80 $00 spells
    type index 0 in two bytes and must skip fine, unlike padded
    spellings of the literal-byte alternatives (see
    TestRejectsBadBlockType). }
  ExpectSkipsWhole('padded s33 block type index',
    [$02, $80, $00, $0B, $0B]);
end;

procedure TDecoderExprTests.TestMemargFlagsAtUpperBound;
begin
  { Flags $7F = 127 is the largest value matching a production: bit 6
    set (a memidx follows) plus align 63. Whether such an alignment is
    ALLOWED is validation; the grammar's own bound is flags < 2^7, and
    128 is rejected in TestRejectsBadMemargFlags. }
  ExpectSkipsWhole('memarg flags 127 with memidx',
    [$41, $00, $28, $7F, $00, $08, $0B]);
end;

procedure TDecoderExprTests.TestRejectsUnknownOpcodes;
begin
  { $06/$07/$09 (legacy exception handling) and $27 are unassigned in
    the pinned 3.0 grammar, as are $16..$19, $1D/$1E, $C5..$CF, and
    $D7 upward. $FE (the threads proposal's prefix) is NOT an assigned
    prefix byte in the 3.0 grammar — only $FB/$FC/$FD are. }
  ExpectRejected('unassigned opcode $06', [$06, $0B]);
  ExpectRejected('unassigned opcode $07', [$07, $0B]);
  ExpectRejected('unassigned opcode $09', [$09, $0B]);
  ExpectRejected('unassigned opcode $16', [$16, $0B]);
  ExpectRejected('unassigned opcode $19', [$19, $0B]);
  ExpectRejected('unassigned opcode $1D', [$1D, $0B]);
  ExpectRejected('unassigned opcode $27', [$27, $0B]);
  ExpectRejected('unassigned opcode $C5', [$C5, $0B]);
  ExpectRejected('unassigned opcode $D7', [$D7, $0B]);
  ExpectRejected('unassigned prefix $FE', [$FE, $00, $0B]);
  ExpectRejected('unassigned opcode $FF', [$FF, $0B]);
end;

procedure TDecoderExprTests.TestRejectsMisplacedElse;
begin
  { The grammar admits $05 in exactly one place: inside an `if`
    production, at most once (binary-if). Anywhere else it matches no
    production — and since init/offset exprs are only ever walked by
    the skipper, nothing downstream would reject these. }
  ExpectRejected('else at expr top level', [$05, $0B]);
  ExpectRejected('else inside a block',
    [$02, $40, $05, $0B, $0B]);
  ExpectRejected('else inside a loop',
    [$03, $40, $05, $0B, $0B]);
  ExpectRejected('else inside try_table',
    [$1F, $40, $00, $05, $0B, $0B]);
  ExpectRejected('second else in one if',
    [$04, $40, $05, $05, $0B, $0B]);
end;

procedure TDecoderExprTests.TestRejectsUnknownMiscSubopcode;
begin
  { The $FC space assigns 0..17. }
  ExpectRejected('unassigned $FC subopcode 18', [$FC, $12, $0B]);
  ExpectRejected('unassigned $FC subopcode 255', [$FC, $FF, $01, $0B]);
end;

procedure TDecoderExprTests.TestRejectsUnknownVecSubopcodes;
begin
  { 154 and 226 are inside the numeric range but unassigned in the
    pinned grammar; 276 is past the relaxed block. }
  ExpectRejected('unassigned $FD subopcode 154',
    [$FD, $9A, $01, $0B]);
  ExpectRejected('unassigned $FD subopcode 226',
    [$FD, $E2, $01, $0B]);
  ExpectRejected('unassigned $FD subopcode 276',
    [$FD, $94, $02, $0B]);
end;

procedure TDecoderExprTests.TestRejectsUnknownAggrSubopcode;
begin
  { The $FB space assigns 0..30. }
  ExpectRejected('unassigned $FB subopcode 31', [$FB, $1F, $0B]);
end;

procedure TDecoderExprTests.TestRejectsTruncatedImmediates;
begin
  ExpectRejected('i32.const missing value', [$41]);
  ExpectRejected('f32.const short by one byte', [$43, $00, $00, $80]);
  ExpectRejected('v128.const short by eight bytes',
    [$FD, $0C, 0, 1, 2, 3, 4, 5, 6, 7]);
  ExpectRejected('call_indirect missing tableidx', [$11, $01]);
  ExpectRejected('memarg missing offset', [$28, $02]);
  ExpectRejected('bare prefix byte', [$FC]);
end;

procedure TDecoderExprTests.TestRejectsUnterminatedExpr;
begin
  ExpectRejected('empty input', []);
  ExpectRejected('no end at depth 0', [$41, $01]);
  { The single end closes the block, leaving the expr itself open. }
  ExpectRejected('block consumed the only end', [$02, $40, $0B]);
end;

procedure TDecoderExprTests.TestRejectsTruncatedBrTable;
begin
  { Declares three targets but supplies two and no default. }
  ExpectRejected('br_table vector cut short', [$0E, $03, $00, $00]);
end;

procedure TDecoderExprTests.TestRejectsBadMemargFlags;
begin
  { The memarg side conditions require flags < 2^7: 128 (here encoded
    $80 $01) matches neither production, whatever bits it carries. }
  ExpectRejected('memarg flags 128', [$28, $80, $01, $00, $0B]);
end;

procedure TDecoderExprTests.TestRejectsBadCastFlags;
begin
  { The castop byte assigns exactly $00..$03. }
  ExpectRejected('br_on_cast flags $04',
    [$FB, $18, $04, $00, $6E, $6E, $0B]);
end;

procedure TDecoderExprTests.TestRejectsBadCatchKind;
begin
  { The catch clause kind byte assigns exactly $00..$03. }
  ExpectRejected('catch clause kind $04',
    [$1F, $40, $01, $04, $00, $0B, $0B]);
end;

procedure TDecoderExprTests.TestRejectsBadBlockType;
begin
  { $76 is -10: an unassigned negative code is no block type... }
  ExpectRejected('unassigned block type code', [$02, $76, $0B, $0B]);
  { ...and the literal-byte productions admit no padded sLEB spellings:
    $C0 $7F spells -64 (empty) in two bytes and matches nothing. }
  ExpectRejected('overlong empty block type', [$02, $C0, $7F, $0B, $0B]);
end;

{ Two prefixes the corpus pins, both raised from this unit and both
  spelled differently from the obvious wording. The opcode byte is part
  of the `illegal opcode` prefix and is lowercase; the memarg flags
  failure is called `memop` upstream, not `memarg`. }
procedure TDecoderExprTests.TestExprMessagePrefixes;
var
  Reader: TWasmReader;
  Actual: string;

  procedure Run(const AValues: array of Byte);
  begin
    Reader := ReaderOver(AValues);
    Actual := '<not rejected>';
    try
      SkipExpr(Reader, 0);
    except
      on E: EWasmDecodeError do
        Actual := E.Message;
    end;
  end;

begin
  { $FF is documented as never being an opcode or a prefix. }
  Run([$FF, $0B]);
  Expect<string>(Copy(Actual, 1, Length(MSG_ILLEGAL_OPCODE) + 3))
    .ToBe(MSG_ILLEGAL_OPCODE + ' ff');

  Run([$28, $80, $01, $00, $0B]);
  Expect<string>(Copy(Actual, 1, Length(MSG_MALFORMED_MEMOP_FLAGS)))
    .ToBe(MSG_MALFORMED_MEMOP_FLAGS);
end;

procedure TDecoderExprTests.SetupTests;
begin
  Test('trivial constant expr', TestTrivialConstExpr);
  Test('span uses base and start position', TestSpanUsesBaseAndStart);
  Test('nested blocks with a branch table',
    TestNestedBlocksWithBranchTable);
  Test('if with else arm', TestIfElse);
  Test('memarg without memory index', TestMemargWithoutMemoryIndex);
  Test('memarg with bit-6 memory index', TestMemargWithMemoryIndex);
  Test('memarg offset is a u64', TestMemargOffsetIsU64);
  Test('v128.const and i8x16.shuffle', TestVectorConstAndShuffle);
  Test('vector lane ops and lane loads', TestVectorLaneAndLaneMemoryOps);
  Test('relaxed vector subopcodes are multi-byte',
    TestRelaxedVectorSubopcode);
  Test('aggregate (GC) instructions', TestGcInstructions);
  Test('br_on_cast carries two heap types', TestBrOnCast);
  Test('try_table with catch clauses', TestTryTable);
  Test('typed select', TestSelectWithTypes);
  Test('bulk memory and table instructions', TestBulkMemoryAndTableOps);
  Test('non-constant instructions skip fine', TestNonConstMixSkipsFine);
  Test('ref.null and float constants', TestRefNullAndFloatConsts);
  Test('padded s33 block type index skips', TestPaddedBlockTypeIndex);
  Test('memarg flags at the grammar bound', TestMemargFlagsAtUpperBound);

  Test('rejects unassigned opcodes', TestRejectsUnknownOpcodes);
  Test('rejects misplaced else delimiters', TestRejectsMisplacedElse);
  Test('rejects unassigned $FC subopcodes',
    TestRejectsUnknownMiscSubopcode);
  Test('rejects unassigned $FD subopcodes',
    TestRejectsUnknownVecSubopcodes);
  Test('rejects unassigned $FB subopcodes',
    TestRejectsUnknownAggrSubopcode);
  Test('rejects truncated immediates', TestRejectsTruncatedImmediates);
  Test('rejects unterminated exprs', TestRejectsUnterminatedExpr);
  Test('rejects truncated br_table vectors', TestRejectsTruncatedBrTable);
  Test('rejects out-of-range memarg flags', TestRejectsBadMemargFlags);
  Test('rejects bad cast flags', TestRejectsBadCastFlags);
  Test('rejects bad catch clause kinds', TestRejectsBadCatchKind);
  Test('rejects bad block types', TestRejectsBadBlockType);
  Test('the skipper raises canonical message prefixes',
    TestExprMessagePrefixes);
end;

begin
  TestRunnerProgram.AddSuite(
    TDecoderExprTests.Create('Wasm.Decoder.Expr'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
