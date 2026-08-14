{ Unit suite for Wasm.Wast — the .wast lexer, s-expression parser, and
  top-level command recognition (Track C, docs/roadmap.md).

  The cases that matter most here are the ones a naive lexer gets wrong:
  block comments NEST (the spec says so explicitly), string literals
  decode to BYTES rather than text because `\hh` escapes can spell
  non-UTF-8 content that `(module binary ...)` needs verbatim,
  annotations are white space whose bodies may spell tokens that are
  illegal anywhere else, and testsuite-local directives outside the
  reference grammar must classify as unknown rather than fail the whole
  script.

  The annotation cases are lifted verbatim from upstream's
  annotations.wast, which is the file that found the gap: it spells a
  lone `;` inside an annotation, and a lexer that reaches its ordinary
  semicolon rule there rejects the whole script. }
program Wasm.Wast.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Wast;

type
  TWastTests = class(TTestSuite)
  private
    function BytesHex(const ABytes: TWasmBytes): string;
    { All tokens of ASource as one spaced string: parens verbatim, atoms
      as their text, strings as `str:<hex>`, then 'eof'. }
    function TokenSignature(const ASource: string): string;
    { 'line:column' of the zero-based AIndex-th token. }
    function TokenPos(const ASource: string; const AIndex: Integer): string;
    { EWastParseError message from lexing all of ASource, '' if none. }
    function LexErrorMessage(const ASource: string): string;
    { EWastParseError message from parsing ASource, '' if none. }
    function ParseErrorMessage(const ASource: string): string;
    { Assert AMessage contains ANeedle, keeping the actual message in the
      failure output. Spelled as a value comparison so the test records
      an assertion either way. }
    procedure ExpectMentions(const AMessage, ANeedle: string);
    function ScriptKinds(const AScript: TWastScript): string;
  public
    procedure SetupTests; override;

    procedure TestParensAndAtoms;
    procedure TestNumericAtomsLexVerbatim;
    procedure TestLineComments;
    procedure TestNestedBlockComments;
    procedure TestStringPlainBytes;
    procedure TestStringNamedEscapes;
    procedure TestStringHexEscapesAreRawBytes;
    procedure TestStringUnicodeEscapes;
    procedure TestLineAndColumnTracking;
    procedure TestUnterminatedStringRejected;
    procedure TestBadEscapeRejected;
    procedure TestBadUnicodeEscapeRejected;
    procedure TestRawNewlineInStringRejected;
    procedure TestUnterminatedBlockCommentRejected;
    procedure TestLoneSemicolonRejected;
    procedure TestAnnotationsAreWhiteSpace;
    procedure TestAnnotationBodyIsOpaque;
    procedure TestAnnotationNestsStringsAndComments;
    procedure TestUnterminatedAnnotationRejected;

    procedure TestRealisticScript;
    procedure TestModuleBinaryFormKeepsExactBytes;
    procedure TestModuleQuoteFormWithId;
    procedure TestModuleDefinitionForms;
    procedure TestNestedModuleFormDetection;
    procedure TestUnknownDirectiveTolerated;
    procedure TestUnbalancedParensRejected;
    procedure TestStrayCloseParenRejected;
  end;

function TWastTests.BytesHex(const ABytes: TWasmBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
    Result := Result + IntToHex(ABytes[I], 2);
end;

function TWastTests.TokenSignature(const ASource: string): string;
var
  Lexer: TWastLexer;
  Token: TWastToken;
  Part: string;
begin
  Result := '';
  Lexer.Init(ASource);
  repeat
    Token := Lexer.Next;
    case Token.Kind of
      wtkLParen: Part := '(';
      wtkRParen: Part := ')';
      wtkAtom: Part := Token.Text;
      wtkString: Part := 'str:' + BytesHex(Token.Bytes);
    else
      Part := 'eof';
    end;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Part;
  until Token.Kind = wtkEof;
end;

function TWastTests.TokenPos(const ASource: string;
  const AIndex: Integer): string;
var
  Lexer: TWastLexer;
  Token: TWastToken;
  I: Integer;
begin
  Lexer.Init(ASource);
  Token := Lexer.Next;
  for I := 1 to AIndex do
    Token := Lexer.Next;
  Result := Format('%d:%d', [Token.Line, Token.Column]);
end;

function TWastTests.LexErrorMessage(const ASource: string): string;
var
  Lexer: TWastLexer;
  Token: TWastToken;
begin
  Result := '';
  Lexer.Init(ASource);
  try
    repeat
      Token := Lexer.Next;
    until Token.Kind = wtkEof;
  except
    on E: EWastParseError do
    begin
      Result := E.Message;
    end;
  end;
end;

function TWastTests.ParseErrorMessage(const ASource: string): string;
var
  Script: TWastScript;
begin
  Result := '';
  try
    Script := ParseWastScript(ASource);
    Script.Free;
  except
    on E: EWastParseError do
    begin
      Result := E.Message;
    end;
  end;
end;

procedure TWastTests.ExpectMentions(const AMessage, ANeedle: string);
var
  Outcome: string;
begin
  if Pos(ANeedle, AMessage) > 0 then
    Outcome := 'mentions "' + ANeedle + '"'
  else
    Outcome := 'MISSING "' + ANeedle + '" in "' + AMessage + '"';
  Expect<string>(Outcome).ToBe('mentions "' + ANeedle + '"');
end;

function TWastTests.ScriptKinds(const AScript: TWastScript): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AScript.Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + WastCommandKindName(AScript[I].Kind);
  end;
end;

{ --- lexer -------------------------------------------------------------- }

procedure TWastTests.TestParensAndAtoms;
begin
  Expect<string>(TokenSignature('(module)')).ToBe('( module ) eof');
  Expect<string>(TokenSignature('(func $add (param i32))'))
    .ToBe('( func $add ( param i32 ) ) eof');
  Expect<string>(TokenSignature('')).ToBe('eof');
end;

procedure TWastTests.TestNumericAtomsLexVerbatim;
begin
  { Numbers are TOKEN TEXT at this stage, not values — hex, underscores,
    signs, floats, and the nan payload forms all pass through verbatim
    by the longest-match rule
    (https://webassembly.github.io/spec/core/text/lexical.html#text-token). }
  Expect<string>(TokenSignature('0x1_000 -42 +7 1_000_000'))
    .ToBe('0x1_000 -42 +7 1_000_000 eof');
  Expect<string>(TokenSignature('nan:canonical nan:arithmetic nan:0x400000'))
    .ToBe('nan:canonical nan:arithmetic nan:0x400000 eof');
  Expect<string>(TokenSignature('-0x1p+63 1.5e10 inf -inf'))
    .ToBe('-0x1p+63 1.5e10 inf -inf eof');
end;

procedure TWastTests.TestLineComments;
begin
  Expect<string>(TokenSignature(';; whole-line comment' + #10 + '(x)'))
    .ToBe('( x ) eof');
  Expect<string>(TokenSignature('(a) ;; trailing, no newline'))
    .ToBe('( a ) eof');
  { `;;` inside a string is content, not a comment. }
  Expect<string>(TokenSignature('";;"')).ToBe('str:3B3B eof');
end;

procedure TWastTests.TestNestedBlockComments;
begin
  { "Block comments can be nested" — spec text, not an implementation
    choice; a lexer that stops at the first `;)` mis-lexes the corpus
    (https://webassembly.github.io/spec/core/text/lexical.html#text-comment,
    pinned commit d7b37e4170d8315f2f1283aed4e8076591a9a333). }
  Expect<string>(TokenSignature('(; outer (; inner ;) still outer ;)x'))
    .ToBe('x eof');
  Expect<string>(TokenSignature('(;;)(y)')).ToBe('( y ) eof');
  Expect<string>(TokenSignature('(; a (; b (; c ;) ;) ;) z'))
    .ToBe('z eof');
  { Parens and quotes inside a comment are plain comment characters. }
  Expect<string>(TokenSignature('(; ")" ( ;)w')).ToBe('w eof');
end;

procedure TWastTests.TestStringPlainBytes;
begin
  Expect<string>(TokenSignature('"abc"')).ToBe('str:616263 eof');
  Expect<string>(TokenSignature('""')).ToBe('str: eof');
  { Two adjacent strings are two tokens, each with its own bytes. }
  Expect<string>(TokenSignature('"a" "b"')).ToBe('str:61 str:62 eof');
end;

procedure TWastTests.TestStringNamedEscapes;
begin
  { \t \n \r \" \' \\ per
    https://webassembly.github.io/spec/core/text/values.html#text-string. }
  Expect<string>(TokenSignature('"\t\n\r\"\''\\"'))
    .ToBe('str:090A0D22275C eof');
end;

procedure TWastTests.TestStringHexEscapesAreRawBytes;
begin
  { \hh is a RAW byte, not a codepoint — the sequence below is not valid
    UTF-8 and must survive exactly, because `(module binary ...)`
    payloads are spelled this way
    (https://webassembly.github.io/spec/core/text/values.html#text-string). }
  Expect<string>(TokenSignature('"\00\ff\9c"')).ToBe('str:00FF9C eof');
  Expect<string>(TokenSignature('"\00asm\01\00\00\00"'))
    .ToBe('str:0061736D01000000 eof');
end;

procedure TWastTests.TestStringUnicodeEscapes;
begin
  { A \u escape (a braced hexnum) contributes the UTF-8 encoding of its
    scalar value, and hexnum permits underscores between digits. }
  Expect<string>(TokenSignature('"\u{41}"')).ToBe('str:41 eof');
  Expect<string>(TokenSignature('"\u{e9}"')).ToBe('str:C3A9 eof');
  Expect<string>(TokenSignature('"\u{2764}"')).ToBe('str:E29DA4 eof');
  Expect<string>(TokenSignature('"\u{1F600}"')).ToBe('str:F09F9880 eof');
  Expect<string>(TokenSignature('"\u{1_F6_00}"')).ToBe('str:F09F9880 eof');
end;

procedure TWastTests.TestLineAndColumnTracking;
const
  SOURCE = '(module' + #10 + '  (func))';
begin
  Expect<string>(TokenPos(SOURCE, 0)).ToBe('1:1');   { ( }
  Expect<string>(TokenPos(SOURCE, 1)).ToBe('1:2');   { module }
  Expect<string>(TokenPos(SOURCE, 2)).ToBe('2:3');   { ( }
  Expect<string>(TokenPos(SOURCE, 3)).ToBe('2:4');   { func }
  Expect<string>(TokenPos(SOURCE, 5)).ToBe('2:9');   { final ) }
  { \r\n counts as ONE newline. }
  Expect<string>(TokenPos('(a)' + #13#10 + 'b', 3)).ToBe('2:1');
end;

procedure TWastTests.TestUnterminatedStringRejected;
begin
  ExpectMentions(LexErrorMessage('"abc'), 'unterminated string');
  ExpectMentions(LexErrorMessage('"abc'), 'line 1, column 1');
  { The reported position is the OPENING quote, on its own line. }
  ExpectMentions(LexErrorMessage('(x)' + #10 + '  "oops'),
    'line 2, column 3');
end;

procedure TWastTests.TestBadEscapeRejected;
begin
  ExpectMentions(LexErrorMessage('"\q"'), 'invalid escape');
  { A lone hex digit is not a \hh escape. }
  ExpectMentions(LexErrorMessage('"\f"'), 'invalid escape');
  ExpectMentions(LexErrorMessage('"a\'), 'unterminated string');
end;

procedure TWastTests.TestBadUnicodeEscapeRejected;
begin
  { Beyond U+10FFFF and surrogates are not Unicode scalar values. }
  ExpectMentions(LexErrorMessage('"\u{110000}"'), 'scalar');
  ExpectMentions(LexErrorMessage('"\u{d800}"'), 'scalar');
  ExpectMentions(LexErrorMessage('"\u{}"'), 'expected hex digits');
  ExpectMentions(LexErrorMessage('"\u{_1}"'), 'expected hex digits');
  ExpectMentions(LexErrorMessage('"\u{1_}"'), 'between hex digits');
  ExpectMentions(LexErrorMessage('"\u41"'), 'expected "{"');
end;

procedure TWastTests.TestRawNewlineInStringRejected;
begin
  ExpectMentions(LexErrorMessage('"a' + #10 + 'b"'), 'control character');
end;

procedure TWastTests.TestUnterminatedBlockCommentRejected;
begin
  ExpectMentions(LexErrorMessage('(; open'), 'unterminated block comment');
  { An inner comment that closes does not close the outer one. }
  ExpectMentions(LexErrorMessage('(; a (; b ;)'),
    'unterminated block comment');
  ExpectMentions(LexErrorMessage('(x)' + #10 + '(; open'),
    'line 2, column 1');
end;

procedure TWastTests.TestLoneSemicolonRejected;
begin
  ExpectMentions(LexErrorMessage('(x) ;'), 'unexpected ";"');
end;

{ --- parser and command recognition ------------------------------------- }

procedure TWastTests.TestRealisticScript;
const
  SOURCE =
    ';; a small script exercising several command forms' + #10 +
    '(module' + #10 +
    '  (func (export "add") (param i32 i32) (result i32)' + #10 +
    '    local.get 0' + #10 +
    '    local.get 1' + #10 +
    '    i32.add))' + #10 +
    '(assert_return (invoke "add" (i32.const 1) (i32.const 2))' + #10 +
    '  (i32.const 3))' + #10 +
    '(assert_trap (invoke "trap") "unreachable")' + #10 +
    '(assert_invalid (module (func (result i32))) "type mismatch")' + #10 +
    '(assert_malformed (module quote "(func") "unexpected end")' + #10 +
    '(register "m1")' + #10 +
    '(invoke "add" (i32.const 1) (i32.const 1))' + #10 +
    '(assert_exhaustion (invoke "loop-forever") "call stack exhausted")';
var
  Script: TWastScript;
begin
  Script := ParseWastScript(SOURCE);
  try
    Expect<Integer>(Script.Count).ToBe(8);
    Expect<string>(ScriptKinds(Script)).ToBe(
      'module assert_return assert_trap assert_invalid assert_malformed'
      + ' register invoke assert_exhaustion');
    { The plain-text module records wmfText. }
    Expect<Boolean>(Script[0].ModuleForm = wmfText).ToBe(True);
    { The tree survives: the assert_return holds its action and its
      expected result as sub-lists. }
    Expect<Integer>(Script[1].Node.Count).ToBe(3);
    Expect<string>(Script[1].Node[1].HeadAtom).ToBe('invoke');
    Expect<string>(Script[1].Node[2].HeadAtom).ToBe('i32.const');
    { The expected trap message survives as decoded bytes:
      "unreachable". }
    Expect<string>(BytesHex(Script[2].Node[2].Bytes))
      .ToBe('756E726561636861626C65');
    { Commands carry their source position for the runner's reporting. }
    Expect<Integer>(Script[0].Node.Line).ToBe(2);
    Expect<Integer>(Script[7].Node.Line).ToBe(14);
  finally
    Script.Free;
  end;
end;

procedure TWastTests.TestModuleBinaryFormKeepsExactBytes;
var
  Script: TWastScript;
begin
  { The binary form is recognized but the payload is NOT decoded — lazy
    decoding is a Track C hard requirement (docs/roadmap.md): decoding
    now would fire malformedness errors at parse time, where
    assert_malformed cannot observe them. }
  Script := ParseWastScript('(module binary "\00asm" "\01\00\00\00")');
  try
    Expect<Integer>(Script.Count).ToBe(1);
    Expect<Boolean>(Script[0].Kind = wcModule).ToBe(True);
    Expect<Boolean>(Script[0].ModuleForm = wmfBinary).ToBe(True);
    Expect<Integer>(Script[0].Node.Count).ToBe(4);
    Expect<string>(BytesHex(Script[0].Node[2].Bytes)).ToBe('0061736D');
    Expect<string>(BytesHex(Script[0].Node[3].Bytes)).ToBe('01000000');
  finally
    Script.Free;
  end;
end;

procedure TWastTests.TestModuleQuoteFormWithId;
var
  Script: TWastScript;
begin
  Script := ParseWastScript('(module $m quote "(module)")');
  try
    Expect<Boolean>(Script[0].Kind = wcModule).ToBe(True);
    Expect<Boolean>(Script[0].ModuleForm = wmfQuote).ToBe(True);
    { The id and the quoted text both survive in the tree. }
    Expect<string>(Script[0].Node[1].Atom).ToBe('$m');
    Expect<string>(BytesHex(Script[0].Node[3].Bytes))
      .ToBe('286D6F64756C6529');
  finally
    Script.Free;
  end;
end;

procedure TWastTests.TestModuleDefinitionForms;
var
  Script: TWastScript;
begin
  Script := ParseWastScript(
    '(module definition $text (func))' + sLineBreak
    + '(module definition $bin binary "\00asm\01\00\00\00")' + sLineBreak
    + '(module definition quote "(module)")');
  try
    Expect<Integer>(Script.Count).ToBe(3);
    Expect<Boolean>(Script[0].Kind = wcModule).ToBe(True);
    Expect<Boolean>(Script[0].ModuleForm = wmfText).ToBe(True);
    Expect<Boolean>(Script[1].ModuleForm = wmfBinary).ToBe(True);
    Expect<Boolean>(Script[2].ModuleForm = wmfQuote).ToBe(True);
    { Classification is lazy: `definition`, its optional id, and the
      payload remain available to the runner. }
    Expect<string>(Script[0].Node[1].Atom).ToBe('definition');
    Expect<string>(Script[0].Node[2].Atom).ToBe('$text');
  finally
    Script.Free;
  end;
end;

procedure TWastTests.TestNestedModuleFormDetection;
var
  Script: TWastScript;
begin
  { assert_malformed wraps a module the runner must classify at
    execution time; DetectWastModuleForm is public for exactly that. }
  Script := ParseWastScript(
    '(assert_malformed (module binary "\00") "unexpected end")');
  try
    Expect<Boolean>(Script[0].Kind = wcAssertMalformed).ToBe(True);
    Expect<Boolean>(DetectWastModuleForm(Script[0].Node[1]) = wmfBinary)
      .ToBe(True);
    { An id does not hide the marker; plain modules stay wmfText. }
    Expect<Boolean>(DetectWastModuleForm(Script[0].Node) = wmfText)
      .ToBe(True);
  finally
    Script.Free;
  end;
end;

procedure TWastTests.TestUnknownDirectiveTolerated;
var
  Script: TWastScript;
begin
  { assert_malformed_custom / assert_invalid_custom are testsuite-local
    directives outside the reference grammar; the parser keeps their
    trees and moves on (docs/roadmap.md, Track C). }
  Script := ParseWastScript(
    '(assert_malformed_custom (module binary "") "custom section")' + #10 +
    '(module)');
  try
    Expect<Integer>(Script.Count).ToBe(2);
    Expect<Boolean>(Script[0].Kind = wcUnknown).ToBe(True);
    Expect<string>(Script[0].Node.HeadAtom)
      .ToBe('assert_malformed_custom');
    Expect<Integer>(Script[0].Node.Count).ToBe(3);
    { The script keeps going: the next command still classifies. }
    Expect<Boolean>(Script[1].Kind = wcModule).ToBe(True);
  finally
    Script.Free;
  end;
end;

procedure TWastTests.TestUnbalancedParensRejected;
begin
  ExpectMentions(ParseErrorMessage('(module (func)'), 'unterminated list');
  ExpectMentions(ParseErrorMessage('(module (func)'), 'line 1, column 1');
  { The unterminated list is the INNER one when that is the open one. }
  ExpectMentions(ParseErrorMessage('(module (func'), 'line 1, column 9');
end;

procedure TWastTests.TestStrayCloseParenRejected;
begin
  ExpectMentions(ParseErrorMessage(')'), 'unexpected ")"');
  ExpectMentions(ParseErrorMessage('(module)' + #10 + ')'),
    'line 2, column 1');
end;

{ --- annotations --------------------------------------------------------- }

{ `(@id ...)` is white space by the same clause that makes comments white
  space (text-space, grammar at text-annot), so it produces NO token and
  leaves no node in the tree. }
procedure TWastTests.TestAnnotationsAreWhiteSpace;
begin
  Expect<string>(TokenSignature('(module (@a) (func))'))
    .ToBe('( module ( func ) ) eof');
  { Between commands, and carrying a body. }
  Expect<string>(TokenSignature('(@a x y z) (module)'))
    .ToBe('( module ) eof');
  { The name may be any run of idchars, including punctuation. }
  Expect<string>(TokenSignature('(@@) (@$) (@+) (@0) (@.) (x)'))
    .ToBe('( x ) eof');
end;

{ The body may spell tokens that are illegal outside an annotation — the
  reserved characters, and a lone semicolon above all, which is what
  upstream's annotations.wast line 14 exercises. Nothing in it is
  interpreted; only parentheses have to balance. }
procedure TWastTests.TestAnnotationBodyIsOpaque;
begin
  Expect<string>(TokenSignature('(@a , ; ] [ }} }x{ ({) ,{{};}] ;) (k)'))
    .ToBe('( k ) eof');
  Expect<string>(TokenSignature('(@a 0x 8q 0xfa #4g0-.@f#^&@#$*0sf -- @#) (k)'))
    .ToBe('( k ) eof');
  { Nested annotations, including empty and name-less ones. }
  Expect<string>(TokenSignature('(@a @ @x (@x) (@x y) (@) (@ x) (@(@(@(@))))) (k)'))
    .ToBe('( k ) eof');
end;

{ Strings and comments inside an annotation are still lexed as strings
  and comments — otherwise a `")"` or a `;; ...)` inside one would end
  the annotation at the wrong place. }
procedure TWastTests.TestAnnotationNestsStringsAndComments;
begin
  { A string holding an unbalanced paren must not close the annotation. }
  Expect<string>(TokenSignature('(@a (bla) () ("aa" a) ")" "(" x")"y) (k)'))
    .ToBe('( k ) eof');
  { A block comment holding a paren, then a line comment holding one. }
  Expect<string>(TokenSignature('(@a (;bla;) (; ) ;)' + sLineBreak
      + '  ;; bla)' + sLineBreak
      + '  ;; bla (@x' + sLineBreak
      + '  ) (k)'))
    .ToBe('( k ) eof');
  { An escaped quote inside an annotation string. }
  Expect<string>(TokenSignature('(@" @ asd\2a 045 \" fdaf") (k)'))
    .ToBe('( k ) eof');
end;

procedure TWastTests.TestUnterminatedAnnotationRejected;
begin
  ExpectMentions(LexErrorMessage('(module (@a x y'),
    'unterminated annotation');
end;

procedure TWastTests.SetupTests;
begin
  Test('parens and atoms', TestParensAndAtoms);
  Test('numeric atoms lex verbatim', TestNumericAtomsLexVerbatim);
  Test('line comments', TestLineComments);
  Test('block comments nest', TestNestedBlockComments);
  Test('string plain bytes', TestStringPlainBytes);
  Test('string named escapes', TestStringNamedEscapes);
  Test('string hex escapes are raw bytes', TestStringHexEscapesAreRawBytes);
  Test('string unicode escapes', TestStringUnicodeEscapes);
  Test('line and column tracking', TestLineAndColumnTracking);
  Test('unterminated string rejected', TestUnterminatedStringRejected);
  Test('bad escape rejected', TestBadEscapeRejected);
  Test('bad unicode escape rejected', TestBadUnicodeEscapeRejected);
  Test('raw newline in string rejected', TestRawNewlineInStringRejected);
  Test('unterminated block comment rejected',
    TestUnterminatedBlockCommentRejected);
  Test('lone semicolon rejected', TestLoneSemicolonRejected);
  Test('annotations lex as white space', TestAnnotationsAreWhiteSpace);
  Test('an annotation body is opaque', TestAnnotationBodyIsOpaque);
  Test('annotations nest strings and comments',
    TestAnnotationNestsStringsAndComments);
  Test('unterminated annotation rejected',
    TestUnterminatedAnnotationRejected);
  Test('realistic script', TestRealisticScript);
  Test('module binary form keeps exact bytes',
    TestModuleBinaryFormKeepsExactBytes);
  Test('module quote form with id', TestModuleQuoteFormWithId);
  Test('module definition forms are detected', TestModuleDefinitionForms);
  Test('nested module form detection', TestNestedModuleFormDetection);
  Test('unknown directive tolerated', TestUnknownDirectiveTolerated);
  Test('unbalanced parens rejected', TestUnbalancedParensRejected);
  Test('stray close paren rejected', TestStrayCloseParenRejected);
end;

begin
  TestRunnerProgram.AddSuite(TWastTests.Create('Wasm.Wast'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
