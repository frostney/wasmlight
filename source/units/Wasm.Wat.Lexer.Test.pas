{ Unit suite for Wasm.Wat.Lexer — the STRICT module-text tokenizer (Track C,
  .agent/design/wat-assembler.md §2a, §4, §7).

  Every case here is one a permissive lexer gets wrong, and most are lifted
  from the upstream corpus (token.wast, const.wast, id.wast, annotations.wast)
  whose expected strings are the acceptance criteria. The cases that matter
  most:

  - the reserved-token rule (text-reserved): `0x`, `1x`, `0xg`, `0$x`,
    `$"l"0`, `$"l"$l` are each ONE reserved token, not sub-tokens — this is
    the 555-command `unknown operator` bucket, and it is not an
    unknown-mnemonic check;
  - `$"quoted id"` lexes as one identifier (the script lexer mislexes it),
    while `$l$l` and `$l0` are ordinary symbolic identifiers (they resolve
    as unknown LABELS in the assembler, which proves they are identifiers,
    not reserved tokens — note the design's §7 risk table lists `$l$l` as
    reserved, which token.wast contradicts);
  - control bytes are scanned by length, so a decoded `\00` is a real NUL
    that is an `illegal character`, not end of input;
  - annotations are VALIDATED, not skipped: `empty annotation id`,
    `unclosed annotation`, and the `illegal character` / `malformed UTF-8`
    their bodies carry.

  Framework gotchas already worked around: the runner fails any test that
  records no assertion (so the malformed cases assert the OUTCOME, they do
  not merely call Fail on the bad path), and FPC will not parse a bare
  generic `Expect<T>(...)` as the lone statement of an `on ... do` (so
  error text is captured into a var and asserted after the handler). }
program Wasm.Wat.Lexer.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Wat.Lexer;

type
  TWatLexerTests = class(TTestSuite)
  private
    function BytesHex(const ABytes: TWasmBytes): string;
    function TextToBytes(const AText: string): TWasmBytes;
    { All tokens of ASource as one spaced string. Parens verbatim;
      keyword/reserved/integer/float as `<kind>:<text>`; identifiers as
      `id:<hex-of-name>`; strings as `str:<hex>`; then `eof`. }
    function Signature(const ABytes: TWasmBytes): string;
    function SignatureText(const AText: string): string;
    { 'kind:text' (or 'id:<hex>' / 'str:<hex>') of the single token that
      ASource must lex to before eof. }
    function OneToken(const AText: string): string;
    { The count of tokens (excluding eof) ASource lexes to. }
    function TokenCount(const AText: string): Integer;
    { EWasmTextError message from lexing all of the given bytes, '' if the
      input lexes clean. }
    function LexError(const ABytes: TWasmBytes): string;
    function LexErrorText(const AText: string): string;
    { 'line:column' of the EWasmTextError raised, or '' if none. }
    function LexErrorPos(const AText: string): string;
    { Assert that AMessage begins with APrefix — the corpus match is a
      PREFIX match. Spelled as a value comparison so the assertion is
      recorded either way. }
    procedure ExpectPrefix(const AMessage, APrefix: string);
  public
    procedure SetupTests; override;

    procedure TestParensKeywordsAndStructure;
    procedure TestIntegerAndFloatShapes;
    procedure TestNanAndInfClassification;
    procedure TestReservedTokensAreSingleTokens;
    procedure TestSymbolicIdentifiers;
    procedure TestQuotedIdentifierIsOneToken;
    procedure TestQuotedIdentifierDecodesToName;
    procedure TestEmptyIdentifierRejected;
    procedure TestIdentifierBadUtf8Rejected;
    procedure TestStringPlainAndEscapes;
    procedure TestStringHexEscapesAreRawBytes;
    procedure TestUnclosedStringRejected;
    procedure TestLineComments;
    procedure TestNestedBlockComments;
    procedure TestAnnotationsAreWhiteSpace;
    procedure TestAnnotationNestsParensStringsComments;
    procedure TestEmptyAnnotationIdRejected;
    procedure TestUnclosedAnnotationRejected;
    procedure TestAnnotationBodyControlIsIllegal;
    procedure TestNulByteIsIllegalNotEnd;
    procedure TestIllegalAndMalformedUtf8Source;
    procedure TestLineAndColumnOnErrors;
    procedure TestKeywordVsReservedBoundary;
    procedure TestPeekIsNonConsumingLookahead;
  end;

function TWatLexerTests.BytesHex(const ABytes: TWasmBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
    Result := Result + IntToHex(ABytes[I], 2);
end;

function TWatLexerTests.TextToBytes(const AText: string): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AText));
  for I := 1 to Length(AText) do
    Result[I - 1] := Byte(Ord(AText[I]) and $FF);
end;

function TWatLexerTests.Signature(const ABytes: TWasmBytes): string;
var
  Lexer: TWatLexer;
  Token: TWatToken;
  Part: string;
begin
  Result := '';
  Lexer.Init(ABytes);
  repeat
    Token := Lexer.Next;
    case Token.Kind of
      wttLParen: Part := '(';
      wttRParen: Part := ')';
      wttKeyword: Part := 'kw:' + Token.Text;
      wttReserved: Part := 'rsv:' + Token.Text;
      wttIdentifier: Part := 'id:' + BytesHex(Token.Bytes);
      wttString: Part := 'str:' + BytesHex(Token.Bytes);
      wttInteger: Part := 'int:' + Token.Text;
      wttFloat: Part := 'flt:' + Token.Text;
    else
      Part := 'eof';
    end;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Part;
  until Token.Kind = wttEof;
end;

function TWatLexerTests.SignatureText(const AText: string): string;
begin
  Result := Signature(TextToBytes(AText));
end;

function TWatLexerTests.OneToken(const AText: string): string;
var
  Lexer: TWatLexer;
  Token: TWatToken;
begin
  Lexer.Init(TextToBytes(AText));
  Token := Lexer.Next;
  case Token.Kind of
    wttLParen: Result := '(';
    wttRParen: Result := ')';
    wttKeyword: Result := 'kw:' + Token.Text;
    wttReserved: Result := 'rsv:' + Token.Text;
    wttIdentifier: Result := 'id:' + BytesHex(Token.Bytes);
    wttString: Result := 'str:' + BytesHex(Token.Bytes);
    wttInteger: Result := 'int:' + Token.Text;
    wttFloat: Result := 'flt:' + Token.Text;
  else
    Result := 'eof';
  end;
end;

function TWatLexerTests.TokenCount(const AText: string): Integer;
var
  Lexer: TWatLexer;
  Token: TWatToken;
begin
  Result := 0;
  Lexer.Init(TextToBytes(AText));
  repeat
    Token := Lexer.Next;
    if Token.Kind <> wttEof then
      Inc(Result);
  until Token.Kind = wttEof;
end;

function TWatLexerTests.LexError(const ABytes: TWasmBytes): string;
var
  Lexer: TWatLexer;
  Token: TWatToken;
begin
  Result := '';
  Lexer.Init(ABytes);
  try
    repeat
      Token := Lexer.Next;
    until Token.Kind = wttEof;
  except
    on E: EWasmTextError do
      Result := E.Message;
  end;
end;

function TWatLexerTests.LexErrorText(const AText: string): string;
begin
  Result := LexError(TextToBytes(AText));
end;

function TWatLexerTests.LexErrorPos(const AText: string): string;
var
  Lexer: TWatLexer;
  Token: TWatToken;
begin
  Result := '';
  Lexer.Init(TextToBytes(AText));
  try
    repeat
      Token := Lexer.Next;
    until Token.Kind = wttEof;
  except
    on E: EWasmTextError do
      Result := Format('%d:%d', [E.Line, E.Column]);
  end;
end;

procedure TWatLexerTests.ExpectPrefix(const AMessage, APrefix: string);
var
  Outcome: string;
begin
  if Copy(AMessage, 1, Length(APrefix)) = APrefix then
    Outcome := 'begins "' + APrefix + '"'
  else
    Outcome := 'WRONG PREFIX in "' + AMessage + '"';
  Expect<string>(Outcome).ToBe('begins "' + APrefix + '"');
end;

{ --- structure ---------------------------------------------------------- }

procedure TWatLexerTests.TestParensKeywordsAndStructure;
begin
  Expect<string>(SignatureText('(module)')).ToBe('( kw:module ) eof');
  Expect<string>(SignatureText('(func (param i32) (result i64))'))
    .ToBe('( kw:func ( kw:param kw:i32 ) ( kw:result kw:i64 ) ) eof');
  Expect<string>(SignatureText('')).ToBe('eof');
  { A mnemonic with dots is one keyword; `local.get` is not three tokens. }
  Expect<string>(OneToken('i32.load8_u')).ToBe('kw:i32.load8_u');
end;

procedure TWatLexerTests.TestIntegerAndFloatShapes;
begin
  Expect<string>(OneToken('0')).ToBe('int:0');
  Expect<string>(OneToken('010')).ToBe('int:010');       { decimal, not octal }
  Expect<string>(OneToken('+42')).ToBe('int:+42');
  Expect<string>(OneToken('-0x8000000000000000'))
    .ToBe('int:-0x8000000000000000');
  Expect<string>(OneToken('0xff')).ToBe('int:0xff');
  Expect<string>(OneToken('1_000_000')).ToBe('int:1_000_000');
  Expect<string>(OneToken('18446744073709551616'))
    .ToBe('int:18446744073709551616');   { shape only; range is Numbers' job }
  Expect<string>(OneToken('3.14')).ToBe('flt:3.14');
  Expect<string>(OneToken('1.5e10')).ToBe('flt:1.5e10');
  Expect<string>(OneToken('1.')).ToBe('flt:1.');
  Expect<string>(OneToken('-0x1p+63')).ToBe('flt:-0x1p+63');
  Expect<string>(OneToken('0x1.fffffep+127')).ToBe('flt:0x1.fffffep+127');
end;

procedure TWatLexerTests.TestNanAndInfClassification;
begin
  Expect<string>(OneToken('inf')).ToBe('flt:inf');
  Expect<string>(OneToken('-inf')).ToBe('flt:-inf');
  Expect<string>(OneToken('nan')).ToBe('flt:nan');
  Expect<string>(OneToken('nan:0x400000')).ToBe('flt:nan:0x400000');
  Expect<string>(OneToken('nan:0x7f_ffff')).ToBe('flt:nan:0x7f_ffff');
  Expect<string>(OneToken('+nan:0x304050')).ToBe('flt:+nan:0x304050');
  { nan:1 has a non-hex payload — not a float. It is a lower-case-led idchar
    run, so the lexer calls it a keyword and the ASSEMBLER reports
    `unknown operator nan:1` (const.wast). Either way it is not a float and
    is one token. }
  Expect<string>(OneToken('nan:1')).ToBe('kw:nan:1');
  { nan:canonical / nan:arithmetic are result PATTERNS, never const
    literals — not floats here. }
  Expect<string>(OneToken('nan:canonical')).ToBe('kw:nan:canonical');
  Expect<string>(OneToken('nan:arithmetic')).ToBe('kw:nan:arithmetic');
end;

{ --- the reserved-token rule -------------------------------------------- }

procedure TWatLexerTests.TestReservedTokensAreSingleTokens;
begin
  { Each of these is exactly ONE reserved token by longest match
    (text-reserved). const.wast / token.wast expect the assembler to report
    `unknown operator` for them, which is only reachable if the lexer does
    not split them. }
  Expect<string>(OneToken('0x')).ToBe('rsv:0x');
  Expect<string>(OneToken('1x')).ToBe('rsv:1x');
  Expect<string>(OneToken('0xg')).ToBe('rsv:0xg');
  Expect<string>(OneToken('0$x')).ToBe('rsv:0$x');
  Expect<string>(OneToken('$"l"0')).ToBe('rsv:$"l"0');
  Expect<string>(OneToken('$"l"$l')).ToBe('rsv:$"l"$l');
  Expect<Integer>(TokenCount('0x')).ToBe(1);
  Expect<Integer>(TokenCount('$"l"0')).ToBe(1);
  Expect<Integer>(TokenCount('0$x')).ToBe(1);
  { `@a` (not immediately after '(') is a reserved token — `( @a)` is
    `unknown operator` in annotations.wast. }
  Expect<string>(SignatureText('( @a)')).ToBe('( rsv:@a ) eof');
  { Adjacent strings and a string glued to idchars are single reserved
    tokens (text-token example `"a""b"`). }
  Expect<string>(OneToken('"a""b"')).ToBe('rsv:"a""b"');
  Expect<string>(OneToken('"a"x')).ToBe('rsv:"a"x');
end;

{ --- identifiers -------------------------------------------------------- }

procedure TWatLexerTests.TestSymbolicIdentifiers;
begin
  { Symbolic ids; the name bytes are the idchars after '$'. `$l0` and
    `$l$l` are ordinary identifiers (they become `unknown label` in the
    assembler, not `unknown operator`) — '$' is itself an idchar. }
  Expect<string>(OneToken('$l')).ToBe('id:6C');
  Expect<string>(OneToken('$l0')).ToBe('id:6C30');
  Expect<string>(OneToken('$l$l')).ToBe('id:6C246C');
  Expect<Integer>(TokenCount('$l$l')).ToBe(1);
  Expect<string>(SignatureText('(br_table $l $l)'))
    .ToBe('( kw:br_table id:6C id:6C ) eof');
end;

procedure TWatLexerTests.TestQuotedIdentifierIsOneToken;
begin
  { The '$"..."' form the script lexer mislexes: one identifier token. }
  Expect<string>(OneToken('$"quoted id"')).ToBe('id:' + BytesHex(
    TextToBytes('quoted id')));
  Expect<Integer>(TokenCount('$"quoted id"')).ToBe(1);
  Expect<string>(SignatureText('(func $"a b")'))
    .ToBe('( kw:func id:' + BytesHex(TextToBytes('a b')) + ' ) eof');
end;

procedure TWatLexerTests.TestQuotedIdentifierDecodesToName;
begin
  { id.wast: the hex-escape, brace-\u-escape, and symbolic spellings of the
    name "AB" all decode to the bytes 41 42 — a quoted id carries its
    DECODED name so the assembler compares by name. }
  Expect<string>(OneToken('$"\41B"')).ToBe('id:4142');
  Expect<string>(OneToken('$"\u{41}\u{42}"')).ToBe('id:4142');
  Expect<string>(OneToken('$AB')).ToBe('id:4142');
  { An escaped control is a valid name byte (id.wast `$"\09"` = `$"\t"`);
    only a RAW control is rejected (below). }
  Expect<string>(OneToken('$"\09"')).ToBe('id:09');
end;

procedure TWatLexerTests.TestEmptyIdentifierRejected;
begin
  { id.wast:26-30 — the five `empty identifier` spellings, module source as
    the assembler would see it AFTER quote-escape decoding. }
  ExpectPrefix(LexErrorText('$'), MSG_EMPTY_IDENT);
  ExpectPrefix(LexErrorText('$""'), MSG_EMPTY_IDENT);
  ExpectPrefix(LexErrorText('$ "a"'), MSG_EMPTY_IDENT);
  ExpectPrefix(LexErrorText('$' + #10 + 'x'), MSG_EMPTY_IDENT);   { $ then newline }
  { `$"a\nb"` / `$"a\tb"` — a RAW control inside the quoted name makes the
    name production fail; upstream calls that `empty identifier`. }
  ExpectPrefix(LexErrorText('$"a' + #10 + 'b"'), MSG_EMPTY_IDENT);
  ExpectPrefix(LexErrorText('$"a' + #9 + 'b"'), MSG_EMPTY_IDENT);
  { `$(@a)` — '$' immediately followed by an annotation (annotations.wast). }
  ExpectPrefix(LexErrorText('$(@a)'), MSG_EMPTY_IDENT);
end;

procedure TWatLexerTests.TestIdentifierBadUtf8Rejected;
begin
  { id.wast:31 — `$"\ef"` decodes to the single byte 0xEF, not valid UTF-8,
    so the name is `malformed UTF-8`. }
  ExpectPrefix(LexErrorText('$"\ef"'), MSG_MALFORMED_UTF8);
end;

{ --- strings ------------------------------------------------------------ }

procedure TWatLexerTests.TestStringPlainAndEscapes;
begin
  Expect<string>(OneToken('"abc"')).ToBe('str:616263');
  { The apostrophe escape is `''` at the Pascal level; the wat string is
    "\t\n\r\"\'\\". }
  Expect<string>(OneToken('"\t\n\r\"\''\\"')).ToBe('str:090A0D22275C');
  { `;;` and parens inside a string are content, not comment/structure. }
  Expect<string>(OneToken('";;"')).ToBe('str:3B3B');
  Expect<string>(OneToken('"\u{41}"')).ToBe('str:41');
  Expect<string>(OneToken('"\u{f4a9}"')).ToBe('str:EF92A9');
end;

procedure TWatLexerTests.TestStringHexEscapesAreRawBytes;
begin
  { `\hh` is a RAW byte, so a data string may hold non-UTF-8 content —
    strings are NOT UTF-8-validated (only names are). }
  Expect<string>(OneToken('"\00\ff\80"')).ToBe('str:00FF80');
end;

procedure TWatLexerTests.TestUnclosedStringRejected;
begin
  ExpectPrefix(LexErrorText('"abc'), MSG_UNCLOSED_STRING);
  { annotations.wast:91-92 — an unclosed string inside an annotation body;
    `)` is an ordinary string character, so `"` then `)` is still unclosed. }
  ExpectPrefix(LexErrorText('(@x "'), MSG_UNCLOSED_STRING);
  ExpectPrefix(LexErrorText('(@x ")'), MSG_UNCLOSED_STRING);
end;

{ --- comments ----------------------------------------------------------- }

procedure TWatLexerTests.TestLineComments;
begin
  Expect<string>(SignatureText(';; a comment' + #10 + '(x)'))
    .ToBe('( kw:x ) eof');
  Expect<string>(SignatureText('(a) ;; trailing')).ToBe('( kw:a ) eof');
end;

procedure TWatLexerTests.TestNestedBlockComments;
begin
  { "Block comments can be nested" — a lexer that stops at the first `;)`
    mis-lexes the corpus. }
  Expect<string>(SignatureText('(; outer (; inner ;) still ;)x'))
    .ToBe('kw:x eof');
  Expect<string>(SignatureText('(; a (; b (; c ;) ;) ;) z'))
    .ToBe('kw:z eof');
  { Parens and quotes inside a comment are plain comment bytes. }
  Expect<string>(SignatureText('(; ")" ( ;)w')).ToBe('kw:w eof');
end;

{ --- annotations -------------------------------------------------------- }

procedure TWatLexerTests.TestAnnotationsAreWhiteSpace;
begin
  { A validated annotation contributes no token, exactly like a comment. }
  Expect<string>(SignatureText('(@a x y) (module)'))
    .ToBe('( kw:module ) eof');
  Expect<string>(SignatureText('(func (@name "f") (param i32))'))
    .ToBe('( kw:func ( kw:param kw:i32 ) ) eof');
  { A space between '(' and '@' is NOT an annotation head: `@a` is a
    reserved token. }
  Expect<string>(SignatureText('( @a)')).ToBe('( rsv:@a ) eof');
end;

procedure TWatLexerTests.TestAnnotationNestsParensStringsComments;
begin
  { The body nests parens, strings (whose `)` must not close the
    annotation), block comments, and nested annotations. All are consumed
    as trivia. }
  Expect<string>(SignatureText('(@x (y (z)) ";)" (; c ;) (@n a)) ok'))
    .ToBe('kw:ok eof');
end;

procedure TWatLexerTests.TestEmptyAnnotationIdRejected;
begin
  { annotations.wast:72-78 — the id must be a non-empty idchar run or a
    non-empty, control-free quoted name, immediately after '@'. }
  ExpectPrefix(LexErrorText('(@)'), MSG_EMPTY_ANNOT_ID);
  ExpectPrefix(LexErrorText('(@ )'), MSG_EMPTY_ANNOT_ID);
  ExpectPrefix(LexErrorText('(@ x)'), MSG_EMPTY_ANNOT_ID);
  ExpectPrefix(LexErrorText('(@(@a)x)'), MSG_EMPTY_ANNOT_ID);
  ExpectPrefix(LexErrorText('(@"")'), MSG_EMPTY_ANNOT_ID);
  ExpectPrefix(LexErrorText('(@ "a")'), MSG_EMPTY_ANNOT_ID);
  ExpectPrefix(LexErrorText('(@"' + #10 + '")'), MSG_EMPTY_ANNOT_ID);
end;

procedure TWatLexerTests.TestUnclosedAnnotationRejected;
begin
  { annotations.wast:81-84. }
  ExpectPrefix(LexErrorText('(@x '), MSG_UNCLOSED_ANNOT);
  ExpectPrefix(LexErrorText('(@x ()'), MSG_UNCLOSED_ANNOT);
  ExpectPrefix(LexErrorText('(@x (y (z))'), MSG_UNCLOSED_ANNOT);
  ExpectPrefix(LexErrorText('(@x (@y )'), MSG_UNCLOSED_ANNOT);
end;

procedure TWatLexerTests.TestAnnotationBodyControlIsIllegal;
var
  Bytes: TWasmBytes;
begin
  { annotations.wast:23-56 — a control byte in an annotation body is
    `illegal character`. Built as raw bytes: `(@a ` + 0x00 + `)`, the shape
    a decoded `\00` produces. }
  Bytes := TextToBytes('(@a ' + #0 + ')');
  ExpectPrefix(LexError(Bytes), MSG_ILLEGAL_CHAR);
  { A valid but non-ASCII codepoint in a body is also illegal (ß = C3 9F). }
  SetLength(Bytes, 6);
  Bytes[0] := Ord('('); Bytes[1] := Ord('@'); Bytes[2] := Ord('a');
  Bytes[3] := $C3; Bytes[4] := $9F; Bytes[5] := Ord(')');
  ExpectPrefix(LexError(Bytes), MSG_ILLEGAL_CHAR);
end;

procedure TWatLexerTests.TestNulByteIsIllegalNotEnd;
var
  Bytes: TWasmBytes;
  Lexer: TWatLexer;
  Msg: string;
begin
  { §7: a decoded `\00` is a REAL NUL in module source. A NUL-terminated
    scan would silently accept `(@a \00)`; length-based scanning rejects it
    as `illegal character`. Prove the NUL is not treated as end-of-input by
    placing tokens after it and confirming the error still fires. }
  Bytes := TextToBytes('(@a ' + #0 + ') (module)');
  Msg := '';
  Lexer.Init(Bytes);
  try
    while Lexer.Next.Kind <> wttEof do;
  except
    on E: EWasmTextError do
      Msg := E.Message;
  end;
  ExpectPrefix(Msg, MSG_ILLEGAL_CHAR);
end;

procedure TWatLexerTests.TestIllegalAndMalformedUtf8Source;
var
  Bytes: TWasmBytes;
begin
  { A bare control byte outside any string/comment is `illegal character`. }
  SetLength(Bytes, 1);
  Bytes[0] := $07;
  ExpectPrefix(LexError(Bytes), MSG_ILLEGAL_CHAR);
  { 0x7F (DEL) is not printable ASCII → illegal. }
  SetLength(Bytes, 1);
  Bytes[0] := $7F;
  ExpectPrefix(LexError(Bytes), MSG_ILLEGAL_CHAR);
  { A stray reserved punctuation byte outside an annotation is illegal. }
  ExpectPrefix(LexErrorText(','), MSG_ILLEGAL_CHAR);
  { An invalid UTF-8 lead byte is `malformed UTF-8 encoding`
    (annotations.wast `\80`, `\c0`, `\f0`). }
  SetLength(Bytes, 1);
  Bytes[0] := $80;
  ExpectPrefix(LexError(Bytes), MSG_MALFORMED_UTF8);
  SetLength(Bytes, 2);
  Bytes[0] := $C0; Bytes[1] := $80;
  ExpectPrefix(LexError(Bytes), MSG_MALFORMED_UTF8);
  { A valid but non-ASCII codepoint outside a string is illegal, not
    malformed (ß = C3 9F is well-formed UTF-8 but never an idchar). }
  SetLength(Bytes, 2);
  Bytes[0] := $C3; Bytes[1] := $9F;
  ExpectPrefix(LexError(Bytes), MSG_ILLEGAL_CHAR);
end;

procedure TWatLexerTests.TestLineAndColumnOnErrors;
begin
  { The fault carries a 1-based line and column. The illegal `,` sits on
    line 2, column 3 after `(x)` and a newline. }
  Expect<string>(LexErrorPos('(x)' + #10 + '  ,')).ToBe('2:3');
  { An unterminated string reports its OPENING position. }
  Expect<string>(LexErrorPos('(data "abc')).ToBe('1:7');
end;

procedure TWatLexerTests.TestKeywordVsReservedBoundary;
begin
  { A mnemonic-shaped token is a keyword even when it is not a known
    mnemonic — the assembler owns `unknown operator get_local`
    (obsolete-keywords.wast). A near-number that is not a valid number and
    does not start with a lower-case letter is reserved. }
  Expect<string>(OneToken('get_local')).ToBe('kw:get_local');
  Expect<string>(OneToken('current_memory')).ToBe('kw:current_memory');
  Expect<string>(OneToken('i32.wrap/i64')).ToBe('kw:i32.wrap/i64');
  Expect<string>(OneToken('block')).ToBe('kw:block');
  { Upper-case-led and underscore-led runs are not keywords → reserved. }
  Expect<string>(OneToken('Block')).ToBe('rsv:Block');
  Expect<string>(OneToken('_x')).ToBe('rsv:_x');
end;

procedure TWatLexerTests.TestPeekIsNonConsumingLookahead;
var
  Lexer: TWatLexer;
  P1, N1, P2, N2, N3: TWatToken;
begin
  { Peek returns the next token without consuming it: a following Next yields
    the same token, so Peek then Next then Peek then Next walks the stream and
    each Peek matches the Next that follows it. This is the one-token lookahead
    the assembler's memidx-vs-lane disambiguation needs (§5.5). Input mirrors
    the `v128.load8_lane 1 1 (…)` shape: two integers then a paren. }
  Lexer.Init(TextToBytes('1 1 ('));
  P1 := Lexer.Peek;
  N1 := Lexer.Next;
  Expect<string>(WatTokenKindName(P1.Kind) + ':' + P1.Text)
    .ToBe(WatTokenKindName(N1.Kind) + ':' + N1.Text);
  Expect<string>('int:1').ToBe('int:' + N1.Text);

  { The SECOND token is reachable by peek after the first Next — the lookahead
    that tells `1 1 (` (memidx then lane) from `1 (` (lane only). }
  P2 := Lexer.Peek;
  Expect<string>(WatTokenKindName(P2.Kind)).ToBe('integer');
  N2 := Lexer.Next;
  Expect<string>(WatTokenKindName(N2.Kind) + ':' + N2.Text).ToBe('integer:1');

  { And the paren after it. }
  N3 := Lexer.Next;
  Expect<string>(WatTokenKindName(N3.Kind)).ToBe('lparen');

  { A repeated Peek at end of input keeps returning eof, non-destructively. }
  Expect<string>(WatTokenKindName(Lexer.Peek.Kind)).ToBe('eof');
  Expect<string>(WatTokenKindName(Lexer.Peek.Kind)).ToBe('eof');
  Expect<string>(WatTokenKindName(Lexer.Next.Kind)).ToBe('eof');
end;

procedure TWatLexerTests.SetupTests;
begin
  Test('parens, keywords, and structure', TestParensKeywordsAndStructure);
  Test('integer and float shapes', TestIntegerAndFloatShapes);
  Test('nan and inf classification', TestNanAndInfClassification);
  Test('reserved tokens are single tokens',
    TestReservedTokensAreSingleTokens);
  Test('symbolic identifiers', TestSymbolicIdentifiers);
  Test('quoted identifier is one token', TestQuotedIdentifierIsOneToken);
  Test('quoted identifier decodes to name',
    TestQuotedIdentifierDecodesToName);
  Test('empty identifier rejected', TestEmptyIdentifierRejected);
  Test('identifier bad utf-8 rejected', TestIdentifierBadUtf8Rejected);
  Test('string plain and escapes', TestStringPlainAndEscapes);
  Test('string hex escapes are raw bytes', TestStringHexEscapesAreRawBytes);
  Test('unclosed string rejected', TestUnclosedStringRejected);
  Test('line comments', TestLineComments);
  Test('nested block comments', TestNestedBlockComments);
  Test('annotations are white space', TestAnnotationsAreWhiteSpace);
  Test('annotation nests parens, strings, comments',
    TestAnnotationNestsParensStringsComments);
  Test('empty annotation id rejected', TestEmptyAnnotationIdRejected);
  Test('unclosed annotation rejected', TestUnclosedAnnotationRejected);
  Test('annotation body control is illegal',
    TestAnnotationBodyControlIsIllegal);
  Test('nul byte is illegal, not end of input', TestNulByteIsIllegalNotEnd);
  Test('illegal and malformed utf-8 source',
    TestIllegalAndMalformedUtf8Source);
  Test('line and column on errors', TestLineAndColumnOnErrors);
  Test('keyword vs reserved boundary', TestKeywordVsReservedBoundary);
  Test('peek is non-consuming one-token lookahead',
    TestPeekIsNonConsumingLookahead);
end;

begin
  TestRunnerProgram.AddSuite(TWatLexerTests.Create('Wasm.Wat.Lexer'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
