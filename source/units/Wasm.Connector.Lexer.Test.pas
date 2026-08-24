{ Unit suite for Wasm.Connector.Lexer — tokenizer for the declaration-only
  Connector language. Cases are literal snippets; malformed input asserts
  the diagnostic prefix and position, not merely that a fault occurred. }
program Wasm.Connector.Lexer.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Connector,
  Wasm.Connector.Lexer;

type
  TWlcLexerTests = class(TTestSuite)
  private
    function Signature(const ASource: string): string;
    function LexError(const ASource: string): string;
    function LexErrorPos(const ASource: string): string;
    procedure ExpectPrefix(const AMessage, APrefix: string);
  public
    procedure SetupTests; override;

    procedure TestPunctuationAndIdents;
    procedure TestStringsAndEscapes;
    procedure TestIntegers;
    procedure TestCommentsAreTrivia;
    procedure TestPeekIsNonConsuming;
    procedure TestUnclosedString;
    procedure TestUnclosedComment;
    procedure TestIllegalCharacter;
    procedure TestLineAndColumn;
  end;

function TWlcLexerTests.Signature(const ASource: string): string;
var
  Lexer: TWlcLexer;
  Token: TWlcToken;
  Part: string;
begin
  Result := '';
  Lexer.Init(ASource);
  repeat
    Token := Lexer.Next;
    case Token.Kind of
      wlkIdent: Part := 'id:' + Token.Text;
      wlkString: Part := 'str:' + Token.Text;
      wlkInteger: Part := 'int:' + Token.Text;
      wlkEof: Part := 'eof';
    else
      Part := WlcTokenKindName(Token.Kind);
    end;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Part;
  until Token.Kind = wlkEof;
end;

function TWlcLexerTests.LexError(const ASource: string): string;
var
  Lexer: TWlcLexer;
  Token: TWlcToken;
begin
  Result := '';
  try
    Lexer.Init(ASource);
    repeat
      Token := Lexer.Next;
    until Token.Kind = wlkEof;
  except
    on E: EWasmConnectorError do
      Result := E.Message;
  end;
end;

function TWlcLexerTests.LexErrorPos(const ASource: string): string;
var
  Lexer: TWlcLexer;
  Token: TWlcToken;
begin
  Result := '';
  try
    Lexer.Init(ASource);
    repeat
      Token := Lexer.Next;
    until Token.Kind = wlkEof;
  except
    on E: EWasmConnectorError do
      Result := IntToStr(E.Line) + ':' + IntToStr(E.Column);
  end;
end;

procedure TWlcLexerTests.ExpectPrefix(const AMessage, APrefix: string);
begin
  Expect<Boolean>(Copy(AMessage, 1, Length(APrefix)) = APrefix).ToBe(True);
end;

procedure TWlcLexerTests.TestPunctuationAndIdents;
begin
  Expect<string>(Signature('{ } ( ) [ ] , ; = : . < > *')).ToBe(
    'lbrace rbrace lparen rparen lbracket rbracket comma semicolon ' +
    'equals colon dot less greater star eof');
  Expect<string>(Signature('static extern DllImport getpid')).ToBe(
    'id:static id:extern id:DllImport id:getpid eof');
end;

procedure TWlcLexerTests.TestStringsAndEscapes;
begin
  Expect<string>(Signature('"libc"')).ToBe('str:libc eof');
  Expect<string>(Signature('"a\\b"')).ToBe('str:a\b eof');
  Expect<string>(Signature('"x\ny"')).ToBe('str:x' + #10 + 'y eof');
end;

procedure TWlcLexerTests.TestIntegers;
var
  Lexer: TWlcLexer;
  Token: TWlcToken;
begin
  Expect<string>(Signature('0 12 -3 0x10')).ToBe('int:0 int:12 int:-3 int:0x10 eof');
  Lexer.Init('0x10');
  Token := Lexer.Next;
  Expect<Int64>(Token.IntValue).ToBe(16);
  Lexer.Init('-8');
  Token := Lexer.Next;
  Expect<Int64>(Token.IntValue).ToBe(-8);
end;

procedure TWlcLexerTests.TestCommentsAreTrivia;
begin
  Expect<string>(Signature('a // hide' + #10 + 'b')).ToBe('id:a id:b eof');
  Expect<string>(Signature('a /* hide */ b')).ToBe('id:a id:b eof');
end;

procedure TWlcLexerTests.TestPeekIsNonConsuming;
var
  Lexer: TWlcLexer;
  P1, N1, P2: TWlcToken;
begin
  Lexer.Init('static class');
  P1 := Lexer.Peek;
  N1 := Lexer.Next;
  Expect<string>(P1.Text).ToBe(N1.Text);
  Expect<string>(N1.Text).ToBe('static');
  P2 := Lexer.Peek;
  Expect<string>(P2.Text).ToBe('class');
  Expect<string>(Lexer.Next.Text).ToBe('class');
  Expect<string>(WlcTokenKindName(Lexer.Peek.Kind)).ToBe('eof');
end;

procedure TWlcLexerTests.TestUnclosedString;
var
  Msg: string;
begin
  Msg := LexError('"abc');
  ExpectPrefix(Msg, MSG_WLC_UNCLOSED_STRING);
  Expect<string>(LexErrorPos('"abc')).ToBe('1:1');
end;

procedure TWlcLexerTests.TestUnclosedComment;
var
  Msg: string;
begin
  Msg := LexError('a /* never');
  ExpectPrefix(Msg, MSG_WLC_UNCLOSED_COMMENT);
  Expect<string>(LexErrorPos('a /* never')).ToBe('1:3');
end;

procedure TWlcLexerTests.TestIllegalCharacter;
var
  Msg: string;
begin
  Msg := LexError('a @ b');
  ExpectPrefix(Msg, MSG_WLC_ILLEGAL_CHAR);
  Expect<string>(LexErrorPos('a @ b')).ToBe('1:3');
end;

procedure TWlcLexerTests.TestLineAndColumn;
begin
  Expect<string>(LexErrorPos('ok' + #10 + '  @')).ToBe('2:3');
end;

procedure TWlcLexerTests.SetupTests;
begin
  Test('punctuation and idents', TestPunctuationAndIdents);
  Test('strings and escapes', TestStringsAndEscapes);
  Test('integers', TestIntegers);
  Test('comments are trivia', TestCommentsAreTrivia);
  Test('peek is non-consuming', TestPeekIsNonConsuming);
  Test('unclosed string', TestUnclosedString);
  Test('unclosed comment', TestUnclosedComment);
  Test('illegal character', TestIllegalCharacter);
  Test('line and column', TestLineAndColumn);
end;

begin
  TestRunnerProgram.AddSuite(TWlcLexerTests.Create('Wasm.Connector.Lexer'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
