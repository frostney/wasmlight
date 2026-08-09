{ Wasm.Wat.Lexer — the STRICT tokenizer for the WebAssembly text (module)
  format, the front end of the `wat` assembler (Track C, docs/roadmap.md,
  design in .agent/design/wat-assembler.md §2a).

  This is deliberately NOT `Wasm.Wast`'s lexer. `Wasm.Wast` tokenizes the
  conformance SCRIPT — a command soup that can afford to treat annotations
  as white space, leave atoms undifferentiated, accept any byte >= 0x20
  inside an atom, and mislex `$"quoted id"`. Every one of those shortcuts
  is fatal for the module grammar, which is judged on ~1,278 adversarial
  `assert_malformed` commands whose whole point is that a permissive lexer
  turns a would-be pass into a failure. So this unit is exact where the
  script lexer is loose:

  - It CLASSIFIES tokens (keyword / reserved / identifier / integer /
    float / string / parens), rather than emitting one undifferentiated
    "atom". The classification is what makes the reserved-token rule —
    "unknown operator", the single largest error class in the corpus —
    expressible at all (text-keyword / text-reserved). A maximal run of
    idchars-and-strings that is not a valid keyword, number, identifier,
    or lone string is ONE reserved token: `0x`, `1x`, `0xg`, `0$x`,
    `$"l"0`, `$"l"$l` each lex as exactly one reserved token, and the
    assembler reports `unknown operator <token>` for it.
  - It decodes the source as UTF-8 (the source is BYTES, not a string):
    identifier characters are ASCII-only (text-idchar), so a valid but
    non-ASCII codepoint is an `illegal character`, and a byte sequence
    that is not valid UTF-8 at all is `malformed UTF-8 encoding`.
  - It scans control bytes by LENGTH, never by NUL termination:
    `(module quote "(@a \00)")` delivers a REAL NUL into the module
    source (the escape is decoded before the assembler sees it), and a
    NUL-terminated scan would silently accept what upstream rejects as
    `illegal character` (design §5, §7).
  - It handles both identifier forms — `$` idchar+ and `$"quoted name"`
    (text-id) — and validates annotations (text-annot) instead of
    skipping them: `empty annotation id`, `unclosed annotation`, plus the
    `illegal character` / `malformed UTF-8` cases their bodies carry.

  Spec citations are against the wasm-mcp pinned core spec, commit
  d7b37e4170d8315f2f1283aed4e8076591a9a333:
    - tokens / longest match / reserved:
      https://webassembly.github.io/spec/core/text/lexical.html#text-token
    - identifiers and idchar:
      https://webassembly.github.io/spec/core/text/values.html#text-idchar
    - strings:
      https://webassembly.github.io/spec/core/text/values.html#text-string
    - annotations:
      https://webassembly.github.io/spec/core/text/lexical.html#text-annot
    - comments and white space:
      https://webassembly.github.io/spec/core/text/lexical.html#text-comment

  This unit OWNS six error prefixes outright: `illegal character`,
  `empty annotation id`, `empty identifier`, `unclosed annotation`,
  `unclosed string`, and most of `malformed UTF-8 encoding`. The
  reserved-token rule is SHARED with the assembler: the lexer produces the
  reserved token, the assembler appends the token to `unknown operator`.
  The lexer never computes a numeric VALUE (that is `Wasm.Wat.Numbers`);
  it only classifies a token as integer- or float-shaped and
  captures its text. }
unit Wasm.Wat.Lexer;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

type
  { EWasmTextError (with its Line/Column fields) now lives in Wasm.Core
    (design §1): promoted from the per-unit local copies so every
    Wasm.Wat.* unit and the runner share one type. Reachable here through
    the Wasm.Core in this unit's uses. }

  TWatTokenKind = (
    wttLParen,     { '(' }
    wttRParen,     { ')' }
    wttKeyword,    { mnemonic / section word: an idchar run starting with a
                     lower-case letter that is not a number. Known-vs-
                     unknown is the assembler's call, not the lexer's. }
    wttReserved,   { text-reserved: an idchar/string run that is nothing
                     else. The assembler reports `unknown operator <Text>`. }
    wttIdentifier, { '$' idchar+ or '$"name"'; Bytes is the DECODED name }
    wttString,     { quoted literal; Bytes carries the DECODED bytes }
    wttInteger,    { integer-shaped token; Text is the verbatim spelling }
    wttFloat,      { float-shaped token (incl. inf / nan / nan:0x...) }
    wttEof
  );

  TWatToken = record
    Kind: TWatTokenKind;
    { Verbatim source spelling for the non-string classes. For a paren it
      is '(' or ')'; for a string it is ''. }
    Text: string;
    { Decoded bytes: the content for wttString, the resolved NAME for
      wttIdentifier (so `$a` and `$"a"` compare equal by name). Empty for
      the other kinds. }
    Bytes: TWasmBytes;
    { 1-based position of the token's first byte. }
    Line: Integer;
    Column: Integer;
  end;

  TWatLexer = record
  private
    FSource: TWasmBytes;
    FPos: Integer;      { 0-based index into FSource }
    FLine: Integer;
    FColumn: Integer;

    function Eof: Boolean; inline;
    function CurByte: Byte; inline;
    function PeekByte: Byte; inline;
    procedure Advance;
    procedure FaultAt(const AWhat: string; const ALine, AColumn: Integer);
    procedure Fault(const AWhat: string);
    function SliceText(const AStart, AStop: Integer): string;

    procedure SkipLineComment;
    procedure SkipBlockComment;
    procedure ScanAnnotation;
    procedure ScanAnnotationId;
    procedure ScanAnnotationBody(const AOpenLine, AOpenColumn: Integer);
    procedure SkipTrivia;

    procedure DecodeEscape(var ABytes: TWasmBytes; var ACount: Integer);
    function ReadPlainString: TWasmBytes;
    procedure SkipStringLiteral;
    function ReadQuotedName(const AInAnnotation: Boolean): TWasmBytes;

    procedure ContinueReserved(const AStart, ALine, AColumn: Integer;
      var AResult: TWatToken);
    function LexStringOrReserved: TWatToken;
    function LexIdentifierOrReserved: TWatToken;
    function LexWord: TWatToken;
  public
    procedure Init(const ASource: TWasmBytes);
    procedure InitFromText(const ASource: string);

    { The next token, raising EWasmTextError (with line and column) on
      malformed input. Returns wttEof forever once the input ends. }
    function Next: TWatToken;
  end;

const
  MSG_ILLEGAL_CHAR    = 'illegal character';
  MSG_EMPTY_ANNOT_ID  = 'empty annotation id';
  MSG_EMPTY_IDENT     = 'empty identifier';
  MSG_UNCLOSED_ANNOT  = 'unclosed annotation';
  MSG_UNCLOSED_STRING = 'unclosed string';
  { Emit the LONG spelling: the corpus asks for both `malformed UTF-8` (2)
    and `malformed UTF-8 encoding` (186), and the short one is a prefix of
    the long, so the long form satisfies both (design §4). }
  MSG_MALFORMED_UTF8  = 'malformed UTF-8 encoding';

{ Human-readable name of a token kind, for diagnostics and tests. }
function WatTokenKindName(const AKind: TWatTokenKind): string;

{ True when AByte is a text-format idchar: a printable ASCII character
  other than space, quotation mark, comma, semicolon, or a round/square/
  curly bracket. Note that '@' and '$' ARE idchars — the '@' of an
  annotation head and the '$' of an identifier are recognised by position,
  not by excluding them from the idchar set.
  https://webassembly.github.io/spec/core/text/values.html#text-idchar }
function IsWatIdChar(const AByte: Byte): Boolean;

{ Length in bytes of the VALID UTF-8 sequence starting at AStart, or 0 when
  the bytes there are not a well-formed UTF-8 scalar (stray continuation,
  overlong, surrogate, or beyond U+10FFFF). ASCII returns 1. Shared by the
  source scanner and the name validator. }
function Utf8SequenceLength(const ABytes: TWasmBytes;
  const AStart: Integer): Integer;

{ True when the whole buffer is valid UTF-8 — the rule a NAME (identifier
  or annotation id) must satisfy. }
function IsValidUtf8(const ABytes: TWasmBytes): Boolean;

implementation

function WatTokenKindName(const AKind: TWatTokenKind): string;
begin
  case AKind of
    wttLParen: Result := 'lparen';
    wttRParen: Result := 'rparen';
    wttKeyword: Result := 'keyword';
    wttReserved: Result := 'reserved';
    wttIdentifier: Result := 'identifier';
    wttString: Result := 'string';
    wttInteger: Result := 'integer';
    wttFloat: Result := 'float';
    wttEof: Result := 'eof';
  else
    Result := '?';
  end;
end;

function IsWatIdChar(const AByte: Byte): Boolean;
begin
  if (AByte < $21) or (AByte > $7E) then
    Exit(False);
  case AByte of
    $22, { quotation mark }
    $28, { left paren }
    $29, { right paren }
    $2C, { comma }
    $3B, { semicolon }
    $5B, { left square bracket }
    $5D, { right square bracket }
    $7B, { left curly bracket }
    $7D: { right curly bracket }
      Result := False;
  else
    Result := True;
  end;
end;

function Utf8SequenceLength(const ABytes: TWasmBytes;
  const AStart: Integer): Integer;
var
  B0, B1, B2, B3: Byte;
  N: Integer;
begin
  B0 := ABytes[AStart];
  if B0 < $80 then
    Exit(1);
  { $80..$C1 can never begin a sequence: $80..$BF are stray continuations,
    $C0/$C1 would be overlong two-byte forms. }
  if B0 < $C2 then
    Exit(0);
  if B0 <= $DF then
    N := 2
  else if B0 <= $EF then
    N := 3
  else if B0 <= $F4 then
    N := 4
  else
    Exit(0);            { $F5..$FF exceed U+10FFFF }
  if AStart + N > Length(ABytes) then
    Exit(0);
  B1 := ABytes[AStart + 1];
  { The first continuation byte's legal range is narrowed for the boundary
    lead bytes, which is exactly what excludes overlong forms, surrogates
    (ED A0..BF = U+D800..U+DFFF), and values past U+10FFFF (F4 90..BF). }
  case B0 of
    $E0: if (B1 < $A0) or (B1 > $BF) then Exit(0);
    $ED: if (B1 < $80) or (B1 > $9F) then Exit(0);
    $F0: if (B1 < $90) or (B1 > $BF) then Exit(0);
    $F4: if (B1 < $80) or (B1 > $8F) then Exit(0);
  else
    if (B1 < $80) or (B1 > $BF) then Exit(0);
  end;
  if N >= 3 then
  begin
    B2 := ABytes[AStart + 2];
    if (B2 < $80) or (B2 > $BF) then Exit(0);
  end;
  if N = 4 then
  begin
    B3 := ABytes[AStart + 3];
    if (B3 < $80) or (B3 > $BF) then Exit(0);
  end;
  Result := N;
end;

function IsValidUtf8(const ABytes: TWasmBytes): Boolean;
var
  I, N: Integer;
begin
  I := 0;
  while I < Length(ABytes) do
  begin
    N := Utf8SequenceLength(ABytes, I);
    if N = 0 then
      Exit(False);
    Inc(I, N);
  end;
  Result := True;
end;

{ --- byte-buffer growth (doubling; trimmed by the caller) ---------------- }

procedure AppendByte(var ABytes: TWasmBytes; var ACount: Integer;
  const AValue: Byte);
begin
  if ACount = Length(ABytes) then
  begin
    if ACount = 0 then
      SetLength(ABytes, 16)
    else
      SetLength(ABytes, ACount * 2);
  end;
  ABytes[ACount] := AValue;
  Inc(ACount);
end;

procedure AppendUtf8(var ABytes: TWasmBytes; var ACount: Integer;
  const AValue: UInt32);
begin
  if AValue < $80 then
    AppendByte(ABytes, ACount, Byte(AValue))
  else if AValue < $800 then
  begin
    AppendByte(ABytes, ACount, Byte($C0 or (AValue shr 6)));
    AppendByte(ABytes, ACount, Byte($80 or (AValue and $3F)));
  end
  else if AValue < $10000 then
  begin
    AppendByte(ABytes, ACount, Byte($E0 or (AValue shr 12)));
    AppendByte(ABytes, ACount, Byte($80 or ((AValue shr 6) and $3F)));
    AppendByte(ABytes, ACount, Byte($80 or (AValue and $3F)));
  end
  else
  begin
    AppendByte(ABytes, ACount, Byte($F0 or (AValue shr 18)));
    AppendByte(ABytes, ACount, Byte($80 or ((AValue shr 12) and $3F)));
    AppendByte(ABytes, ACount, Byte($80 or ((AValue shr 6) and $3F)));
    AppendByte(ABytes, ACount, Byte($80 or (AValue and $3F)));
  end;
end;

function IsHexDigit(const AByte: Byte): Boolean;
begin
  Result := ((AByte >= Ord('0')) and (AByte <= Ord('9')))
    or ((AByte >= Ord('a')) and (AByte <= Ord('f')))
    or ((AByte >= Ord('A')) and (AByte <= Ord('F')));
end;

function IsDecDigit(const AByte: Byte): Boolean;
begin
  Result := (AByte >= Ord('0')) and (AByte <= Ord('9'));
end;

function HexDigitValue(const AByte: Byte): Byte;
begin
  if (AByte >= Ord('0')) and (AByte <= Ord('9')) then
    Result := AByte - Ord('0')
  else if (AByte >= Ord('a')) and (AByte <= Ord('f')) then
    Result := AByte - Ord('a') + 10
  else
    Result := AByte - Ord('A') + 10;
end;

{ --- lexer core ---------------------------------------------------------- }

procedure TWatLexer.Init(const ASource: TWasmBytes);
begin
  FSource := ASource;
  FPos := 0;
  FLine := 1;
  FColumn := 1;
end;

procedure TWatLexer.InitFromText(const ASource: string);
var
  Bytes: TWasmBytes;
  I: Integer;
begin
  { A convenience for ASCII/UTF-8 test inputs. Each Char maps to its low
    byte, which is exact for ASCII and for a UTF-8 source already spelled
    byte-by-byte. }
  SetLength(Bytes, Length(ASource));
  for I := 1 to Length(ASource) do
    Bytes[I - 1] := Byte(Ord(ASource[I]) and $FF);
  Init(Bytes);
end;

function TWatLexer.Eof: Boolean;
begin
  Result := FPos >= Length(FSource);
end;

function TWatLexer.CurByte: Byte;
begin
  Result := FSource[FPos];
end;

function TWatLexer.PeekByte: Byte;
begin
  if FPos + 1 >= Length(FSource) then
    Result := 0
  else
    Result := FSource[FPos + 1];
end;

procedure TWatLexer.Advance;
var
  B: Byte;
begin
  B := FSource[FPos];
  Inc(FPos);
  { Newlines are \n, \r\n, and lone \r
    (https://webassembly.github.io/spec/core/text/lexical.html#text-space).
    \r\n counts once — the \r only bumps the line when no \n follows. }
  if (B = $0A) or ((B = $0D) and (Eof or (CurByte <> $0A))) then
  begin
    Inc(FLine);
    FColumn := 1;
  end
  else
    Inc(FColumn);
end;

procedure TWatLexer.FaultAt(const AWhat: string;
  const ALine, AColumn: Integer);
var
  E: EWasmTextError;
begin
  E := EWasmTextError.CreateFmt('%s (line %d, column %d)',
    [AWhat, ALine, AColumn]);
  E.Line := ALine;
  E.Column := AColumn;
  raise E;
end;

procedure TWatLexer.Fault(const AWhat: string);
begin
  FaultAt(AWhat, FLine, FColumn);
end;

function TWatLexer.SliceText(const AStart, AStop: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, AStop - AStart);
  for I := AStart to AStop - 1 do
    Result[I - AStart + 1] := Chr(FSource[I]);
end;

{ --- comments and annotations ------------------------------------------- }

procedure TWatLexer.SkipLineComment;
begin
  { `;;` to end of line or end of input. }
  while not Eof and (CurByte <> $0A) and (CurByte <> $0D) do
    Advance;
end;

procedure TWatLexer.SkipBlockComment;
var
  OpenLine, OpenColumn, Depth: Integer;
begin
  { `(;` ... `;)`, and block comments NEST — the spec says so explicitly,
    so the depth counter is required, not optional. }
  OpenLine := FLine;
  OpenColumn := FColumn;
  Advance; { ( }
  Advance; { ; }
  Depth := 1;
  while Depth > 0 do
  begin
    if Eof then
      FaultAt('unterminated block comment opened at', OpenLine, OpenColumn);
    if (CurByte = Ord('(')) and (PeekByte = Ord(';')) then
    begin
      Inc(Depth);
      Advance;
      Advance;
    end
    else if (CurByte = Ord(';')) and (PeekByte = Ord(')')) then
    begin
      Dec(Depth);
      Advance;
      Advance;
    end
    else
      Advance;
  end;
end;

procedure TWatLexer.ScanAnnotationId;
begin
  { The annotation id follows the '@' with NO intervening space
    (text-annot): idchar+ or a quoted name, and it must be NON-EMPTY. A
    space, a paren, a control byte, or an empty/blank quoted name all make
    it empty. }
  if Eof then
    Fault(MSG_EMPTY_ANNOT_ID);
  if CurByte = Ord('"') then
    ReadQuotedName(True)
  else if IsWatIdChar(CurByte) then
  begin
    while not Eof and IsWatIdChar(CurByte) do
      Advance;
  end
  else
    Fault(MSG_EMPTY_ANNOT_ID);
end;

procedure TWatLexer.ScanAnnotationBody(const AOpenLine, AOpenColumn: Integer);
var
  Depth: Integer;
  B: Byte;
  N: Integer;
begin
  { The '(' of the annotation head is depth 1; its matching ')' closes the
    annotation. Nested annotations are consumed whole by ScanAnnotation, so
    they never touch Depth; nested plain lists do. Strings and comments are
    scanned so their parens are not miscounted. Body characters are still
    validated — annotations.wast asserts `illegal character` and
    `malformed UTF-8 encoding` on bytes appearing INSIDE an annotation. }
  Depth := 1;
  while Depth > 0 do
  begin
    if Eof then
      FaultAt(MSG_UNCLOSED_ANNOT, AOpenLine, AOpenColumn);
    B := CurByte;
    if (B = Ord('(')) and (PeekByte = Ord('@')) then
      ScanAnnotation
    else if (B = Ord('(')) and (PeekByte = Ord(';')) then
      SkipBlockComment
    else if (B = Ord(';')) and (PeekByte = Ord(';')) then
      SkipLineComment
    else if B = Ord('"') then
      SkipStringLiteral
    else if B = Ord('(') then
    begin
      Inc(Depth);
      Advance;
    end
    else if B = Ord(')') then
    begin
      Dec(Depth);
      Advance;
    end
    else if (B = $20) or (B = $09) or (B = $0A) or (B = $0D) then
      Advance
    else if (B < $20) or (B = $7F) then
      Fault(MSG_ILLEGAL_CHAR)
    else if B >= $80 then
    begin
      N := Utf8SequenceLength(FSource, FPos);
      if N = 0 then
        Fault(MSG_MALFORMED_UTF8)
      else
        { Valid UTF-8, but a non-ASCII codepoint is never an idchar —
          annotations.wast: `(@a Heiße Würstchen)` is `illegal character`. }
        Fault(MSG_ILLEGAL_CHAR);
    end
    else
      { A printable idchar or one of the reserved punctuation characters
        (comma, semicolon, or a square or curly bracket) that are legal only
        inside an annotation: opaque, just advance. }
      Advance;
  end;
end;

procedure TWatLexer.ScanAnnotation;
var
  OpenLine, OpenColumn: Integer;
begin
  OpenLine := FLine;
  OpenColumn := FColumn;
  Advance; { ( }
  Advance; { @ }
  ScanAnnotationId;
  ScanAnnotationBody(OpenLine, OpenColumn);
end;

procedure TWatLexer.SkipTrivia;
begin
  while not Eof do
  begin
    case CurByte of
      $20, $09, $0A, $0D:
        Advance;
      Ord(';'):
        if PeekByte = Ord(';') then
          SkipLineComment
        else
          Break;   { a lone ';' is Next's problem: `illegal character` }
      Ord('('):
        if PeekByte = Ord(';') then
          SkipBlockComment
        else if PeekByte = Ord('@') then
          ScanAnnotation
        else
          Break;    { a plain '(' }
    else
      Break;
    end;
  end;
end;

{ --- strings and names -------------------------------------------------- }

procedure TWatLexer.DecodeEscape(var ABytes: TWasmBytes;
  var ACount: Integer);
var
  E: Byte;
  EscLine, EscColumn: Integer;
  Scalar: UInt32;
begin
  { Assumes CurByte = '\'. text-string escapes: \t \n \r \" \' \\, a raw
    byte \hh, and the braced \u form for a Unicode scalar value. }
  EscLine := FLine;
  EscColumn := FColumn;
  Advance; { \ }
  if Eof then
    FaultAt(MSG_UNCLOSED_STRING, EscLine, EscColumn);
  E := CurByte;
  case E of
    Ord('t'): begin AppendByte(ABytes, ACount, $09); Advance; end;
    Ord('n'): begin AppendByte(ABytes, ACount, $0A); Advance; end;
    Ord('r'): begin AppendByte(ABytes, ACount, $0D); Advance; end;
    Ord('"'): begin AppendByte(ABytes, ACount, $22); Advance; end;
    Ord(''''): begin AppendByte(ABytes, ACount, $27); Advance; end;
    Ord('\'): begin AppendByte(ABytes, ACount, $5C); Advance; end;
    Ord('u'):
      begin
        Advance;
        if Eof or (CurByte <> Ord('{')) then
          FaultAt(MSG_ILLEGAL_CHAR, EscLine, EscColumn);
        Advance;
        if Eof or not IsHexDigit(CurByte) then
          FaultAt(MSG_ILLEGAL_CHAR, EscLine, EscColumn);
        Scalar := 0;
        while not Eof and (IsHexDigit(CurByte) or (CurByte = Ord('_'))) do
        begin
          if CurByte = Ord('_') then
          begin
            Advance;
            if Eof or not IsHexDigit(CurByte) then
              FaultAt(MSG_ILLEGAL_CHAR, EscLine, EscColumn);
            Continue;
          end;
          if Scalar > $10FFFF then
            FaultAt(MSG_MALFORMED_UTF8, EscLine, EscColumn);
          Scalar := (Scalar shl 4) or HexDigitValue(CurByte);
          Advance;
        end;
        if Eof or (CurByte <> Ord('}')) then
          FaultAt(MSG_ILLEGAL_CHAR, EscLine, EscColumn);
        Advance;
        { A scalar value: within range and not a surrogate. }
        if (Scalar > $10FFFF)
          or ((Scalar >= $D800) and (Scalar <= $DFFF)) then
          FaultAt(MSG_MALFORMED_UTF8, EscLine, EscColumn);
        AppendUtf8(ABytes, ACount, Scalar);
      end;
  else
    if IsHexDigit(E) and IsHexDigit(PeekByte) then
    begin
      AppendByte(ABytes, ACount,
        (HexDigitValue(E) shl 4) or HexDigitValue(PeekByte));
      Advance;
      Advance;
    end
    else
      { An unrecognised escape. UNCONFIRMED against upstream's exact
        spelling; not in Track C's required corpus set. }
      FaultAt(MSG_ILLEGAL_CHAR, EscLine, EscColumn);
  end;
end;

function TWatLexer.ReadPlainString: TWasmBytes;
var
  Bytes: TWasmBytes;
  Count, OpenLine, OpenColumn: Integer;
  C: Byte;
begin
  { A string TOKEN: raw bytes, no UTF-8 requirement (a `(data ...)` payload
    may be arbitrary bytes). Control bytes must be escaped, so a RAW
    control here is illegal. Assumes CurByte = opening '"'. }
  Bytes := nil;
  Count := 0;
  OpenLine := FLine;
  OpenColumn := FColumn;
  Advance; { " }
  while True do
  begin
    if Eof then
      FaultAt(MSG_UNCLOSED_STRING, OpenLine, OpenColumn);
    C := CurByte;
    if C = Ord('"') then
    begin
      Advance;
      Break;
    end;
    if C = Ord('\') then
      DecodeEscape(Bytes, Count)
    else if (C < $20) or (C = $7F) then
      Fault(MSG_ILLEGAL_CHAR)
    else
    begin
      AppendByte(Bytes, Count, C);
      Advance;
    end;
  end;
  SetLength(Bytes, Count);
  Result := Bytes;
end;

procedure TWatLexer.SkipStringLiteral;
begin
  ReadPlainString;
end;

function TWatLexer.ReadQuotedName(const AInAnnotation: Boolean): TWasmBytes;
var
  Bytes: TWasmBytes;
  Count, OpenLine, OpenColumn: Integer;
  C: Byte;
  EmptyMsg: string;
begin
  { The '$"name"' / '(@ "name"' quoted forms. Unlike a string TOKEN, a name
    must be a valid, non-empty UTF-8 string, so:
      - a RAW control byte makes the name production fail — upstream reports
        this as `empty identifier` / `empty annotation id`, NOT as an
        illegal character (id.wast: `$"a\nb"`, `$"a\tb"`);
      - an empty payload is likewise `empty ...`;
      - decoded bytes that are not valid UTF-8 are `malformed UTF-8`
        (id.wast: `$"\ef"`).
    Assumes CurByte = opening '"'. }
  if AInAnnotation then
    EmptyMsg := MSG_EMPTY_ANNOT_ID
  else
    EmptyMsg := MSG_EMPTY_IDENT;
  Bytes := nil;
  Count := 0;
  OpenLine := FLine;
  OpenColumn := FColumn;
  Advance; { " }
  while True do
  begin
    if Eof then
      FaultAt(MSG_UNCLOSED_STRING, OpenLine, OpenColumn);
    C := CurByte;
    if C = Ord('"') then
    begin
      Advance;
      Break;
    end;
    if C = Ord('\') then
      DecodeEscape(Bytes, Count)
    else if (C < $20) or (C = $7F) then
      Fault(EmptyMsg)
    else
    begin
      AppendByte(Bytes, Count, C);
      Advance;
    end;
  end;
  SetLength(Bytes, Count);
  if Count = 0 then
    FaultAt(EmptyMsg, OpenLine, OpenColumn);
  if not IsValidUtf8(Bytes) then
    FaultAt(MSG_MALFORMED_UTF8, OpenLine, OpenColumn);
  Result := Bytes;
end;

{ --- number-shape recognition ------------------------------------------- }

function ConsumeDigitRun(const S: string; var AIndex: Integer;
  const AHex: Boolean): Boolean;

  function IsDigit(const AByte: Byte): Boolean;
  begin
    if AHex then
      Result := IsHexDigit(AByte)
    else
      Result := IsDecDigit(AByte);
  end;

begin
  { digit ('_'? digit)* — at least one digit, underscores only BETWEEN
    digits (a trailing '_' is left unconsumed and fails the full match). }
  if (AIndex > Length(S)) or not IsDigit(Byte(S[AIndex])) then
    Exit(False);
  Inc(AIndex);
  while AIndex <= Length(S) do
  begin
    if IsDigit(Byte(S[AIndex])) then
      Inc(AIndex)
    else if (S[AIndex] = '_') and (AIndex < Length(S))
      and IsDigit(Byte(S[AIndex + 1])) then
      Inc(AIndex)
    else
      Break;
  end;
  Result := True;
end;

function SubMatch(const S: string; const AIndex: Integer;
  const AWord: string): Boolean;
var
  K: Integer;
begin
  if AIndex + Length(AWord) - 1 > Length(S) then
    Exit(False);
  for K := 1 to Length(AWord) do
    if S[AIndex + K - 1] <> AWord[K] then
      Exit(False);
  Result := True;
end;

{ True when the WHOLE idchar run S is a valid integer or float literal
  (text-int / text-float). AIsFloat then says which. Value and range are
  NOT checked here — a shape-valid but out-of-range `0x1...` is still an
  integer token, and `Wasm.Wat.Numbers` reports `constant out of range`. }
function RecognizeNumber(const S: string; out AIsFloat: Boolean): Boolean;
var
  I, Len: Integer;
begin
  AIsFloat := False;
  Len := Length(S);
  I := 1;
  if I > Len then
    Exit(False);
  if (S[I] = '+') or (S[I] = '-') then
    Inc(I);
  if I > Len then
    Exit(False);

  if SubMatch(S, I, 'inf') then
  begin
    Inc(I, 3);
    AIsFloat := True;
    Exit(I > Len);
  end;

  if SubMatch(S, I, 'nan') then
  begin
    Inc(I, 3);
    if I > Len then
    begin
      AIsFloat := True;
      Exit(True);
    end;
    if S[I] = ':' then
    begin
      Inc(I);
      if not ((I + 1 <= Len) and (S[I] = '0') and (S[I + 1] = 'x')) then
        Exit(False);
      Inc(I, 2);
      if not ConsumeDigitRun(S, I, True) then
        Exit(False);
      AIsFloat := True;
      Exit(I > Len);
    end;
    Exit(False);   { `nan` followed by non-`:` junk, e.g. `nan:1` }
  end;

  if (I + 1 <= Len) and (S[I] = '0') and (S[I + 1] = 'x') then
  begin
    Inc(I, 2);
    if not ConsumeDigitRun(S, I, True) then
      Exit(False);
    if (I <= Len) and (S[I] = '.') then
    begin
      Inc(I);
      AIsFloat := True;
      if (I <= Len) and IsHexDigit(Byte(S[I])) then
        ConsumeDigitRun(S, I, True);
    end;
    if (I <= Len) and ((S[I] = 'p') or (S[I] = 'P')) then
    begin
      Inc(I);
      AIsFloat := True;
      if (I <= Len) and ((S[I] = '+') or (S[I] = '-')) then
        Inc(I);
      if not ConsumeDigitRun(S, I, False) then
        Exit(False);
    end;
    Exit(I > Len);
  end;

  if (I <= Len) and IsDecDigit(Byte(S[I])) then
  begin
    ConsumeDigitRun(S, I, False);
    if (I <= Len) and (S[I] = '.') then
    begin
      Inc(I);
      AIsFloat := True;
      if (I <= Len) and IsDecDigit(Byte(S[I])) then
        ConsumeDigitRun(S, I, False);
    end;
    if (I <= Len) and ((S[I] = 'e') or (S[I] = 'E')) then
    begin
      Inc(I);
      AIsFloat := True;
      if (I <= Len) and ((S[I] = '+') or (S[I] = '-')) then
        Inc(I);
      if not ConsumeDigitRun(S, I, False) then
        Exit(False);
    end;
    Exit(I > Len);
  end;

  Result := False;
end;

{ --- token production --------------------------------------------------- }

procedure TWatLexer.ContinueReserved(const AStart, ALine, AColumn: Integer;
  var AResult: TWatToken);
begin
  { The current run has already turned out not to be a lone string, a valid
    id, a keyword, or a number: a reserved token by longest match. Consume
    the rest of the '(idchar | string)+' run and package it. }
  while not Eof do
  begin
    if IsWatIdChar(CurByte) then
      Advance
    else if CurByte = Ord('"') then
      SkipStringLiteral
    else
      Break;
  end;
  AResult.Kind := wttReserved;
  AResult.Text := SliceText(AStart, FPos);
  AResult.Bytes := nil;
  AResult.Line := ALine;
  AResult.Column := AColumn;
end;

function TWatLexer.LexStringOrReserved: TWatToken;
var
  Start, StartLine, StartColumn: Integer;
  Bytes: TWasmBytes;
begin
  Start := FPos;
  StartLine := FLine;
  StartColumn := FColumn;
  Bytes := ReadPlainString;
  { `"a"b` and `"a""b"` are single reserved tokens, not a string followed
    by more — the run continues without a separator (text-token example
    `"a""b"`). }
  if not Eof and (IsWatIdChar(CurByte) or (CurByte = Ord('"'))) then
  begin
    ContinueReserved(Start, StartLine, StartColumn, Result);
    Exit;
  end;
  Result.Kind := wttString;
  Result.Text := '';
  Result.Bytes := Bytes;
  Result.Line := StartLine;
  Result.Column := StartColumn;
end;

function TWatLexer.LexIdentifierOrReserved: TWatToken;
var
  Start, StartLine, StartColumn, NameStart: Integer;
  NameBytes: TWasmBytes;
  I: Integer;
begin
  Start := FPos;
  StartLine := FLine;
  StartColumn := FColumn;
  Advance; { $ }

  if not Eof and (CurByte = Ord('"')) then
  begin
    { Quoted form '$"name"'. }
    NameBytes := ReadQuotedName(False);
    if not Eof and (IsWatIdChar(CurByte) or (CurByte = Ord('"'))) then
    begin
      { Trailing idchars/strings after the quoted name: one reserved token,
        e.g. `$"l"0`, `$"l"$l` (token.wast). }
      ContinueReserved(Start, StartLine, StartColumn, Result);
      Exit;
    end;
    Result.Kind := wttIdentifier;
    Result.Text := SliceText(Start, FPos);
    Result.Bytes := NameBytes;
    Result.Line := StartLine;
    Result.Column := StartColumn;
    Exit;
  end;

  if not Eof and IsWatIdChar(CurByte) then
  begin
    { Symbolic form '$' idchar+. }
    NameStart := FPos;
    while not Eof and IsWatIdChar(CurByte) do
      Advance;
    if not Eof and (CurByte = Ord('"')) then
    begin
      { An idchar run then a string with no separator, e.g. `$l"x"`: one
        reserved token by longest match. }
      ContinueReserved(Start, StartLine, StartColumn, Result);
      Exit;
    end;
    SetLength(NameBytes, FPos - NameStart);
    for I := NameStart to FPos - 1 do
      NameBytes[I - NameStart] := FSource[I];
    Result.Kind := wttIdentifier;
    Result.Text := SliceText(Start, FPos);
    Result.Bytes := NameBytes;
    Result.Line := StartLine;
    Result.Column := StartColumn;
    Exit;
  end;

  { '$' with nothing that can follow it — `$`, `$ "a"`, `$(@a)`, `$)`. }
  FaultAt(MSG_EMPTY_IDENT, StartLine, StartColumn);
end;

function TWatLexer.LexWord: TWatToken;
var
  Start, StartLine, StartColumn: Integer;
  HasString: Boolean;
  Text: string;
  IsFloat: Boolean;
begin
  { The first byte is an idchar other than '$' (that is routed separately)
    and other than '"'. Collect the maximal '(idchar | string)+' run, then
    classify it. }
  Start := FPos;
  StartLine := FLine;
  StartColumn := FColumn;
  HasString := False;
  while not Eof do
  begin
    if IsWatIdChar(CurByte) then
      Advance
    else if CurByte = Ord('"') then
    begin
      HasString := True;
      SkipStringLiteral;
    end
    else
      Break;
  end;
  Text := SliceText(Start, FPos);

  Result.Text := Text;
  Result.Bytes := nil;
  Result.Line := StartLine;
  Result.Column := StartColumn;

  if HasString then
  begin
    { A run mixing idchars and strings is never a keyword or a number. }
    Result.Kind := wttReserved;
    Exit;
  end;

  if RecognizeNumber(Text, IsFloat) then
  begin
    if IsFloat then
      Result.Kind := wttFloat
    else
      Result.Kind := wttInteger;
    Exit;
  end;

  { Keywords start with a lower-case letter (text-keyword). Whether the
    keyword is a KNOWN mnemonic is the assembler's decision — an unknown
    one becomes `unknown operator`, exactly as a reserved token does. A run
    that starts otherwise and is not a number is reserved (`0x`, `0$x`). }
  if (Text[1] >= 'a') and (Text[1] <= 'z') then
    Result.Kind := wttKeyword
  else
    Result.Kind := wttReserved;
end;

function TWatLexer.Next: TWatToken;
var
  N: Integer;
begin
  SkipTrivia;
  Result.Text := '';
  Result.Bytes := nil;
  Result.Line := FLine;
  Result.Column := FColumn;
  if Eof then
  begin
    Result.Kind := wttEof;
    Exit;
  end;

  case CurByte of
    Ord('('):
      begin
        Result.Kind := wttLParen;
        Result.Text := '(';
        Advance;
      end;
    Ord(')'):
      begin
        Result.Kind := wttRParen;
        Result.Text := ')';
        Advance;
      end;
    Ord('"'):
      Result := LexStringOrReserved;
    Ord('$'):
      Result := LexIdentifierOrReserved;
  else
    if IsWatIdChar(CurByte) then
      Result := LexWord
    else if (CurByte < $20) or (CurByte = $7F) then
      Fault(MSG_ILLEGAL_CHAR)
    else if CurByte >= $80 then
    begin
      N := Utf8SequenceLength(FSource, FPos);
      if N = 0 then
        Fault(MSG_MALFORMED_UTF8)
      else
        Fault(MSG_ILLEGAL_CHAR);
    end
    else
      { A printable but non-idchar byte outside a string/comment/annotation:
        comma, semicolon, or a square or curly bracket. }
      Fault(MSG_ILLEGAL_CHAR);
  end;
end;

end.
