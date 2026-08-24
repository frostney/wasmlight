{ Wasm.Connector.Lexer — tokenizer for the Wasmlight Connector Language.

  C# brace/semicolon punctuation, identifiers, decimal/hex integers, and
  quoted strings. `//` and non-nested `/* */` comments are trivia. This
  is not a C# lexer: it classifies only the tokens the declaration grammar
  needs and leaves keyword meaning to the parser. }
unit Wasm.Connector.Lexer;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Connector;

type
  TWlcTokenKind = (
    wlkIdent,
    wlkString,
    wlkInteger,
    wlkLBrace,
    wlkRBrace,
    wlkLParen,
    wlkRParen,
    wlkLBracket,
    wlkRBracket,
    wlkComma,
    wlkSemicolon,
    wlkEquals,
    wlkColon,
    wlkDot,
    wlkLess,
    wlkGreater,
    wlkStar,
    wlkPlus,
    wlkEof
  );

  TWlcToken = record
    Kind: TWlcTokenKind;
    Text: string;
    IntValue: Int64;
    Line: Integer;
    Column: Integer;
  end;

  TWlcLexer = record
  private
    FSource: string;
    FPos: Integer;
    FLine: Integer;
    FColumn: Integer;

    function Eof: Boolean; inline;
    function Cur: Char; inline;
    function PeekChar: Char; inline;
    procedure Advance;
    procedure Fault(const AWhat: string);
    procedure FaultAt(const AWhat: string; const ALine, AColumn: Integer);
    procedure SkipLineComment;
    procedure SkipBlockComment(const AOpenLine, AOpenColumn: Integer);
    procedure SkipTrivia;
    function ScanIdent: TWlcToken;
    function ScanString: TWlcToken;
    function ScanInteger: TWlcToken;
  public
    procedure Init(const ASource: string);
    function Next: TWlcToken;
    function Peek: TWlcToken;
  end;

function WlcTokenKindName(const AKind: TWlcTokenKind): string;

implementation

function WlcTokenKindName(const AKind: TWlcTokenKind): string;
begin
  case AKind of
    wlkIdent: Result := 'ident';
    wlkString: Result := 'string';
    wlkInteger: Result := 'integer';
    wlkLBrace: Result := 'lbrace';
    wlkRBrace: Result := 'rbrace';
    wlkLParen: Result := 'lparen';
    wlkRParen: Result := 'rparen';
    wlkLBracket: Result := 'lbracket';
    wlkRBracket: Result := 'rbracket';
    wlkComma: Result := 'comma';
    wlkSemicolon: Result := 'semicolon';
    wlkEquals: Result := 'equals';
    wlkColon: Result := 'colon';
    wlkDot: Result := 'dot';
    wlkLess: Result := 'less';
    wlkGreater: Result := 'greater';
    wlkStar: Result := 'star';
    wlkPlus: Result := 'plus';
    wlkEof: Result := 'eof';
  else
    Result := '?';
  end;
end;

function TWlcLexer.Eof: Boolean;
begin
  Result := FPos > Length(FSource);
end;

function TWlcLexer.Cur: Char;
begin
  Result := FSource[FPos];
end;

function TWlcLexer.PeekChar: Char;
begin
  if FPos >= Length(FSource) then
    Result := #0
  else
    Result := FSource[FPos + 1];
end;

procedure TWlcLexer.Advance;
var
  Ch: Char;
begin
  Ch := FSource[FPos];
  Inc(FPos);
  if (Ch = #10) or ((Ch = #13) and (Eof or (Cur <> #10))) then
  begin
    Inc(FLine);
    FColumn := 1;
  end
  else
    Inc(FColumn);
end;

procedure TWlcLexer.FaultAt(const AWhat: string;
  const ALine, AColumn: Integer);
begin
  RaiseConnectorError(AWhat, ALine, AColumn);
end;

procedure TWlcLexer.Fault(const AWhat: string);
begin
  FaultAt(AWhat, FLine, FColumn);
end;

procedure TWlcLexer.SkipLineComment;
begin
  while not Eof and (Cur <> #10) and (Cur <> #13) do
    Advance;
end;

procedure TWlcLexer.SkipBlockComment(const AOpenLine, AOpenColumn: Integer);
begin
  while not Eof do
  begin
    if (Cur = '*') and (PeekChar = '/') then
    begin
      Advance;
      Advance;
      Exit;
    end;
    Advance;
  end;
  FaultAt(MSG_WLC_UNCLOSED_COMMENT, AOpenLine, AOpenColumn);
end;

procedure TWlcLexer.SkipTrivia;
var
  OpenLine, OpenColumn: Integer;
begin
  while not Eof do
  begin
    case Cur of
      #9, #10, #13, ' ':
        Advance;
      '/':
        if PeekChar = '/' then
        begin
          Advance;
          Advance;
          SkipLineComment;
        end
        else if PeekChar = '*' then
        begin
          OpenLine := FLine;
          OpenColumn := FColumn;
          Advance;
          Advance;
          SkipBlockComment(OpenLine, OpenColumn);
        end
        else
          Exit;
    else
      Exit;
    end;
  end;
end;

function TWlcLexer.ScanIdent: TWlcToken;
var
  Start: Integer;
begin
  Result.Kind := wlkIdent;
  Result.IntValue := 0;
  Result.Line := FLine;
  Result.Column := FColumn;
  Start := FPos;
  Advance;
  while not Eof and (
    ((Cur >= 'A') and (Cur <= 'Z')) or
    ((Cur >= 'a') and (Cur <= 'z')) or
    ((Cur >= '0') and (Cur <= '9')) or
    (Cur = '_')) do
    Advance;
  Result.Text := Copy(FSource, Start, FPos - Start);
end;

function TWlcLexer.ScanString: TWlcToken;
var
  OpenLine, OpenColumn: Integer;
  Decoded: string;
  Ch: Char;
begin
  OpenLine := FLine;
  OpenColumn := FColumn;
  Advance;
  Decoded := '';
  while not Eof do
  begin
    Ch := Cur;
    if Ch = '"' then
    begin
      Advance;
      Result.Kind := wlkString;
      Result.Text := Decoded;
      Result.IntValue := 0;
      Result.Line := OpenLine;
      Result.Column := OpenColumn;
      Exit;
    end;
    if (Ch = #10) or (Ch = #13) then
      FaultAt(MSG_WLC_UNCLOSED_STRING, OpenLine, OpenColumn);
    Advance;
    if Ch = '\' then
    begin
      if Eof then
        FaultAt(MSG_WLC_UNCLOSED_STRING, OpenLine, OpenColumn);
      case Cur of
        '\': Decoded := Decoded + '\';
        '"': Decoded := Decoded + '"';
        'n': Decoded := Decoded + #10;
        'r': Decoded := Decoded + #13;
        't': Decoded := Decoded + #9;
        '''': Decoded := Decoded + '''';
      else
        Fault('unknown string escape');
      end;
      Advance;
    end
    else
      Decoded := Decoded + Ch;
  end;
  FaultAt(MSG_WLC_UNCLOSED_STRING, OpenLine, OpenColumn);
end;

function TWlcLexer.ScanInteger: TWlcToken;
var
  Start, Digits: Integer;
  Negative, Hex: Boolean;
  Acc: Int64;
  Ch: Char;
  Digit: Integer;
begin
  Result.Kind := wlkInteger;
  Result.Line := FLine;
  Result.Column := FColumn;
  Start := FPos;
  Negative := Cur = '-';
  if Negative then
    Advance;
  Hex := (not Eof) and (Cur = '0') and ((PeekChar = 'x') or (PeekChar = 'X'));
  if Hex then
  begin
    Advance;
    Advance;
    Acc := 0;
    Digits := 0;
    while not Eof do
    begin
      Ch := Cur;
      if (Ch >= '0') and (Ch <= '9') then
        Digit := Ord(Ch) - Ord('0')
      else if (Ch >= 'A') and (Ch <= 'F') then
        Digit := Ord(Ch) - Ord('A') + 10
      else if (Ch >= 'a') and (Ch <= 'f') then
        Digit := Ord(Ch) - Ord('a') + 10
      else
        Break;
      if Acc > (High(Int64) shr 4) then
        Fault(MSG_WLC_EXPRESSION);
      Acc := (Acc shl 4) + Digit;
      Inc(Digits);
      Advance;
    end;
    if Digits = 0 then
      Fault('expected hex digits');
  end
  else
  begin
    Acc := 0;
    Digits := 0;
    while not Eof and (Cur >= '0') and (Cur <= '9') do
    begin
      Digit := Ord(Cur) - Ord('0');
      if Acc > ((High(Int64) - Digit) div 10) then
        Fault(MSG_WLC_EXPRESSION);
      Acc := Acc * 10 + Digit;
      Inc(Digits);
      Advance;
    end;
    if Digits = 0 then
      Fault('expected digits');
  end;
  if Negative then
    Acc := -Acc;
  Result.IntValue := Acc;
  Result.Text := Copy(FSource, Start, FPos - Start);
end;

procedure TWlcLexer.Init(const ASource: string);
begin
  FSource := ASource;
  FPos := 1;
  FLine := 1;
  FColumn := 1;
end;

function TWlcLexer.Next: TWlcToken;
var
  Ch: Char;
  Kind: TWlcTokenKind;
begin
  SkipTrivia;
  if Eof then
  begin
    Result.Kind := wlkEof;
    Result.Text := '';
    Result.IntValue := 0;
    Result.Line := FLine;
    Result.Column := FColumn;
    Exit;
  end;
  Ch := Cur;
  if ((Ch >= 'A') and (Ch <= 'Z')) or
     ((Ch >= 'a') and (Ch <= 'z')) or
     (Ch = '_') then
    Exit(ScanIdent);
  if Ch = '"' then
    Exit(ScanString);
  if ((Ch >= '0') and (Ch <= '9')) or
     ((Ch = '-') and (PeekChar >= '0') and (PeekChar <= '9')) then
    Exit(ScanInteger);
  Kind := wlkEof;
  case Ch of
    '{': Kind := wlkLBrace;
    '}': Kind := wlkRBrace;
    '(': Kind := wlkLParen;
    ')': Kind := wlkRParen;
    '[': Kind := wlkLBracket;
    ']': Kind := wlkRBracket;
    ',': Kind := wlkComma;
    ';': Kind := wlkSemicolon;
    '=': Kind := wlkEquals;
    ':': Kind := wlkColon;
    '.': Kind := wlkDot;
    '<': Kind := wlkLess;
    '>': Kind := wlkGreater;
    '*': Kind := wlkStar;
    '+': Kind := wlkPlus;
  else
    Fault(MSG_WLC_ILLEGAL_CHAR);
  end;
  Result.Kind := Kind;
  Result.Text := Ch;
  Result.IntValue := 0;
  Result.Line := FLine;
  Result.Column := FColumn;
  Advance;
end;

function TWlcLexer.Peek: TWlcToken;
var
  SavedPos, SavedLine, SavedColumn: Integer;
begin
  SavedPos := FPos;
  SavedLine := FLine;
  SavedColumn := FColumn;
  Result := Next;
  FPos := SavedPos;
  FLine := SavedLine;
  FColumn := SavedColumn;
end;

end.
