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

  TWlcLexer = class
  private
    FSource: string;
    FPos: Integer;
    FLine: Integer;
    FColumn: Integer;

    function Eof: Boolean; inline;
    function Cursor: Char; inline;
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
    constructor Create(const ASource: string);
    function Next: TWlcToken;
    function Peek: TWlcToken;
  end;

function WlcTokenKindName(const AKind: TWlcTokenKind): string;

implementation

uses
  TypInfo;

function WlcTokenKindName(const AKind: TWlcTokenKind): string;
var
  Name: string;
begin
  Name := GetEnumName(TypeInfo(TWlcTokenKind), Ord(AKind));
  if Copy(Name, 1, 3) = 'wlk' then
    Delete(Name, 1, 3);
  if Name = '' then
    Result := '?'
  else
    Result := LowerCase(Name);
end;

function TWlcLexer.Eof: Boolean;
begin
  Result := FPos > Length(FSource);
end;

function TWlcLexer.Cursor: Char;
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
  if Ch = #13 then
  begin
    if not Eof and (Cursor = #10) then
      Inc(FPos);
    Inc(FLine);
    FColumn := 1;
  end
  else if Ch = #10 then
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
  while not Eof and (Cursor <> #10) and (Cursor <> #13) do
    Advance;
end;

procedure TWlcLexer.SkipBlockComment(const AOpenLine, AOpenColumn: Integer);
begin
  while not Eof do
  begin
    if (Cursor = '*') and (PeekChar = '/') then
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
    case Cursor of
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
    ((Cursor >= 'A') and (Cursor <= 'Z')) or
    ((Cursor >= 'a') and (Cursor <= 'z')) or
    ((Cursor >= '0') and (Cursor <= '9')) or
    (Cursor = '_')) do
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
    Ch := Cursor;
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
      case Cursor of
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
  Negative := Cursor = '-';
  if Negative then
    Advance;
  Hex := (not Eof) and (Cursor = '0') and ((PeekChar = 'x') or (PeekChar = 'X'));
  if Hex then
  begin
    Advance;
    Advance;
    Acc := 0;
    Digits := 0;
    while not Eof do
    begin
      Ch := Cursor;
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
    while not Eof and (Cursor >= '0') and (Cursor <= '9') do
    begin
      Digit := Ord(Cursor) - Ord('0');
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

constructor TWlcLexer.Create(const ASource: string);
begin
  inherited Create;
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
  Ch := Cursor;
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
