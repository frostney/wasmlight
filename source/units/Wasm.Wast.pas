{ Wasm.Wast — lexer, s-expression parser, and top-level command
  recognition for the `.wast` conformance script format.

  This is the first slice of Track C (docs/roadmap.md): the harness that
  will run the upstream spec testsuite. What lives here is deliberately
  only the script front end — no execution, no module decoding, no
  assertion evaluation. Track C's hard requirement of LAZY decoding is
  why: `(module quote ...)` and `(module binary ...)` payloads must be
  assembled or decoded at command-EXECUTION time, not script-parse time,
  or `assert_malformed` cannot observe the failure it exists to observe.
  The parser therefore keeps the raw tree (with exact string bytes) and
  classifies commands, nothing more.

  The lexical rules are the text format's
  (https://webassembly.github.io/spec/core/text/lexical.html#text-token,
  pinned spec commit d7b37e4170d8315f2f1283aed4e8076591a9a333): tokens
  are separated by parentheses, white space, or comments, and atoms are
  read by longest match — which is why numbers, keywords, and forms like
  `nan:0x400000` all lex as undifferentiated atom text here. Numeric
  VALUE parsing is a later Track C slice; today's callers only need the
  spelling preserved.

  Annotations (`(@id ...)`) are white space by the same clause that makes
  comments white space, so the lexer skips them whole and they never
  reach the tree — see SkipAnnotation, which is also where the reserved
  characters that are legal only inside one are handled.

  The testsuite also uses directives that are not in the reference
  grammar (`assert_malformed_custom`, `assert_invalid_custom`); those
  classify as wcUnknown with their tree intact rather than failing the
  whole script (docs/roadmap.md, Track C requirements). }
unit Wasm.Wast;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

type
  { Script-text problems (bad escape, unterminated string or comment,
    unbalanced parentheses). Distinct from EWasmDecodeError, which is
    about BINARY bytes not being a module — a .wast script is harness
    input, not a module, so it gets its own class. Local to this unit
    until the harness grows a home of its own. }
  EWastParseError = class(EWasmError);

  TWastTokenKind = (
    wtkLParen,
    wtkRParen,
    wtkAtom,     { keyword, identifier, or number — undifferentiated text }
    wtkString,   { quoted literal; Bytes carries the DECODED byte content }
    wtkEof
  );

  TWastToken = record
    Kind: TWastTokenKind;
    { Verbatim source spelling for wtkAtom. }
    Text: string;
    { Decoded bytes for wtkString. Kept as bytes rather than string
      because `(module binary "...")` needs the exact byte sequence —
      hex escapes can spell bytes that are not valid UTF-8. }
    Bytes: TWasmBytes;
    { 1-based position of the token's first character, counted in bytes
      per line — the corpus is ASCII outside string literals. }
    Line: Integer;
    Column: Integer;
  end;

  TWastLexer = record
  private
    FSource: string;
    FPos: Integer;      { 1-based index into FSource }
    FLine: Integer;
    FColumn: Integer;

    function Eof: Boolean; inline;
    function Cur: Char; inline;
    function Peek: Char; inline;
    procedure Advance;
    procedure Fault(const AWhat: string; const ALine, AColumn: Integer);
    procedure SkipLineComment;
    procedure SkipBlockComment;
    procedure SkipAnnotation;
    procedure SkipTrivia;
    function LexString(const ALine, AColumn: Integer): TWastToken;
    function LexAtom(const ALine, AColumn: Integer): TWastToken;
  public
    procedure Init(const ASource: string);

    { The next token, raising EWastParseError (with line and column) on
      malformed input. Returns wtkEof forever once the input ends. }
    function Next: TWastToken;
  end;

  TWastNodeKind = (
    wnkAtom,
    wnkString,
    wnkList
  );

  { One vertex of the s-expression tree. A node owns its children and
    frees them; whole trees are owned by the TWastScript they came from. }
  TWastNode = class
  private
    FKind: TWastNodeKind;
    FAtom: string;
    FBytes: TWasmBytes;
    FItems: array of TWastNode;
    FLine: Integer;
    FColumn: Integer;

    function GetItem(const AIndex: Integer): TWastNode;
  public
    destructor Destroy; override;

    procedure AddItem(const AItem: TWastNode);
    function Count: Integer;

    { True when this is an atom spelling AText. }
    function IsAtom(const AText: string): Boolean;

    { The head atom's text for a non-empty list headed by an atom,
      '' otherwise. Command classification keys on this. }
    function HeadAtom: string;

    property Kind: TWastNodeKind read FKind;
    property Atom: string read FAtom;
    property Bytes: TWasmBytes read FBytes;
    property Items[const AIndex: Integer]: TWastNode
      read GetItem; default;
    property Line: Integer read FLine;
    property Column: Integer read FColumn;
  end;

  { Top-level command classification. Only the head atom is inspected;
    argument shapes are the executing runner's business, later. }
  TWastCommandKind = (
    wcModule,
    wcRegister,
    wcInvoke,           { bare action at top level }
    wcAssertReturn,
    wcAssertTrap,
    wcAssertInvalid,
    wcAssertMalformed,
    wcAssertUnlinkable,
    wcAssertException,
    wcAssertExhaustion,
    wcUnknown           { anything else — kept, never rejected }
  );

  { Which syntactic form a wcModule command uses. The distinction is
    recorded here but the payload is NOT assembled or decoded — see the
    unit header on lazy decoding. }
  TWastModuleForm = (
    wmfText,     { (module ...) with fields }
    wmfQuote,    { (module quote "..."*) — text to be parsed later }
    wmfBinary    { (module binary "..."*) — bytes to be decoded later }
  );

  TWastCommand = record
    Kind: TWastCommandKind;
    { Meaningful only when Kind = wcModule; wmfText otherwise. }
    ModuleForm: TWastModuleForm;
    { The command's whole s-expression, owned by the script. }
    Node: TWastNode;
  end;

  { A parsed script: the ordered top-level commands, each with its tree.
    Owns every node reachable from its commands. }
  TWastScript = class
  private
    FCommands: array of TWastCommand;

    function GetCommand(const AIndex: Integer): TWastCommand;
  public
    destructor Destroy; override;

    procedure AddCommand(const ACommand: TWastCommand);
    function Count: Integer;

    property Commands[const AIndex: Integer]: TWastCommand
      read GetCommand; default;
  end;

{ Parse a whole .wast script into its top-level commands. Raises
  EWastParseError on lexical or bracketing errors; unknown command heads
  are NOT errors (wcUnknown). The caller owns the returned script. }
function ParseWastScript(const ASource: string): TWastScript;

{ Human-readable name of a command kind, for diagnostics. }
function WastCommandKindName(const AKind: TWastCommandKind): string;

{ Which module form a `(module ...)` list uses. Public because modules
  also appear NESTED inside assert_malformed / assert_invalid and the
  runner classifies those at command-execution time, not parse time. }
function DetectWastModuleForm(const ANode: TWastNode): TWastModuleForm;

implementation

{ --- lexer -------------------------------------------------------------- }

procedure TWastLexer.Init(const ASource: string);
begin
  FSource := ASource;
  FPos := 1;
  FLine := 1;
  FColumn := 1;
end;

function TWastLexer.Eof: Boolean;
begin
  Result := FPos > Length(FSource);
end;

function TWastLexer.Cur: Char;
begin
  Result := FSource[FPos];
end;

function TWastLexer.Peek: Char;
begin
  if FPos + 1 > Length(FSource) then
    Result := #0
  else
    Result := FSource[FPos + 1];
end;

procedure TWastLexer.Advance;
var
  C: Char;
begin
  C := Cur;
  Inc(FPos);
  { The format's newlines are \n, \r\n, and lone \r
    (https://webassembly.github.io/spec/core/text/lexical.html#text-space).
    \r\n must count once, so \r only counts when no \n follows — the \n
    of a \r\n pair does the counting. }
  if (C = #10) or ((C = #13) and (Eof or (Cur <> #10))) then
  begin
    Inc(FLine);
    FColumn := 1;
  end
  else
    Inc(FColumn);
end;

procedure TWastLexer.Fault(const AWhat: string;
  const ALine, AColumn: Integer);
begin
  raise EWastParseError.CreateFmt('%s (line %d, column %d)',
    [AWhat, ALine, AColumn]);
end;

procedure TWastLexer.SkipLineComment;
begin
  { `;;` to end of line or end of input
    (https://webassembly.github.io/spec/core/text/lexical.html#text-comment). }
  while not Eof and (Cur <> #10) and (Cur <> #13) do
    Advance;
end;

procedure TWastLexer.SkipBlockComment;
var
  OpenLine, OpenColumn: Integer;
  Depth: Integer;
begin
  { `(;` ... `;)`, and "Block comments can be nested" — the spec says so
    explicitly, so a depth counter is required, not optional
    (https://webassembly.github.io/spec/core/text/lexical.html#text-comment). }
  OpenLine := FLine;
  OpenColumn := FColumn;
  Advance; { ( }
  Advance; { ; }
  Depth := 1;
  while Depth > 0 do
  begin
    if Eof then
      Fault('unterminated block comment opened at', OpenLine, OpenColumn);
    if (Cur = '(') and (Peek = ';') then
    begin
      Inc(Depth);
      Advance;
      Advance;
    end
    else if (Cur = ';') and (Peek = ')') then
    begin
      Dec(Depth);
      Advance;
      Advance;
    end
    else
      Advance;
  end;
end;

procedure TWastLexer.SkipAnnotation;
var
  OpenLine, OpenColumn: Integer;
  Depth: Integer;
begin
  { An annotation `(@id ...)` is WHITE SPACE as far as the enclosing text
    is concerned — "white space ... is any sequence of literal space
    characters, formatting characters, comments, or annotations"
    (https://webassembly.github.io/spec/core/text/lexical.html#text-space,
    grammar at #text-annot) — and its contents carry no meaning for the
    core format. So it is skipped whole, exactly like a comment, and no
    node reaches the tree.

    What the body may contain is much wider than ordinary text: any
    token, INCLUDING the reserved characters comma, semicolon, square
    brackets and curly brackets, which are illegal outside an
    annotation. That is the whole reason this procedure exists rather
    than the parser simply reading a list —
    upstream's annotations.wast spells a lone `;` inside one, and the
    lexer used to reject the file outright.

    Only four things are structural, and each is handled by the same code
    that handles it anywhere else, so that they nest and interleave
    correctly: parentheses (which must balance), string literals (whose
    `"("`, `")"` and escapes must not be counted), block comments (which
    nest), and line comments (which may contain an unbalanced paren —
    annotations.wast has `;; bla)`). Everything else is opaque. }
  OpenLine := FLine;
  OpenColumn := FColumn;
  Advance; { ( }
  Advance; { @ }
  Depth := 1;
  while Depth > 0 do
  begin
    if Eof then
      Fault('unterminated annotation opened at', OpenLine, OpenColumn);
    if (Cur = '(') and (Peek = ';') then
      SkipBlockComment
    else if (Cur = ';') and (Peek = ';') then
      SkipLineComment
    else if Cur = '"' then
      { The token is discarded; LexString is called for its scanning —
        and for its escape and control-character checks, which hold
        inside an annotation as everywhere else. }
      LexString(FLine, FColumn)
    else if Cur = '(' then
    begin
      Inc(Depth);
      Advance;
    end
    else if Cur = ')' then
    begin
      Dec(Depth);
      Advance;
    end
    else
      Advance;
  end;
end;

procedure TWastLexer.SkipTrivia;
begin
  while not Eof do
  begin
    case Cur of
      ' ', #9, #10, #13:
        Advance;
      ';':
        if Peek = ';' then
          SkipLineComment
        else
          Fault('unexpected ";" outside a comment', FLine, FColumn);
      '(':
        if Peek = ';' then
          SkipBlockComment
        else if Peek = '@' then
          SkipAnnotation
        else
          Break;
    else
      Break;
    end;
  end;
end;

{ Byte-buffer growth by doubling, trimmed by the caller once the literal
  ends. Scripts are parsed once, so nothing fancier is warranted. }
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

{ UTF-8 encoding of a Unicode scalar value, for the \u escape form. The
  caller has already range-checked AValue. }
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

function IsHexDigit(const AChar: Char): Boolean;
begin
  Result := ((AChar >= '0') and (AChar <= '9'))
    or ((AChar >= 'a') and (AChar <= 'f'))
    or ((AChar >= 'A') and (AChar <= 'F'));
end;

function HexDigitValue(const AChar: Char): Byte;
begin
  if (AChar >= '0') and (AChar <= '9') then
    Result := Ord(AChar) - Ord('0')
  else if (AChar >= 'a') and (AChar <= 'f') then
    Result := Ord(AChar) - Ord('a') + 10
  else
    Result := Ord(AChar) - Ord('A') + 10;
end;

function TWastLexer.LexString(const ALine, AColumn: Integer): TWastToken;
var
  Bytes: TWasmBytes;
  Count: Integer;
  C, E: Char;
  EscLine, EscColumn: Integer;
  Scalar: UInt32;
begin
  { String literals per
    https://webassembly.github.io/spec/core/text/values.html#text-string:
    plain characters contribute their UTF-8 bytes (which is exactly the
    source bytes, so they copy through), `\hh` contributes the RAW byte —
    the one escape that can produce non-UTF-8 content — and a \u escape
    (a braced hexnum) contributes the UTF-8 encoding of its scalar
    value. Control
    characters, `"`, and `\` must be escaped. }
  Bytes := nil;
  Count := 0;
  Advance; { opening quote }
  while True do
  begin
    if Eof then
      Fault('unterminated string literal opened at', ALine, AColumn);
    C := Cur;
    if C = '"' then
    begin
      Advance;
      Break;
    end;
    if C = '\' then
    begin
      EscLine := FLine;
      EscColumn := FColumn;
      Advance;
      if Eof then
        Fault('unterminated string literal opened at', ALine, AColumn);
      E := Cur;
      case E of
        't':
          begin
            AppendByte(Bytes, Count, $09);
            Advance;
          end;
        'n':
          begin
            AppendByte(Bytes, Count, $0A);
            Advance;
          end;
        'r':
          begin
            AppendByte(Bytes, Count, $0D);
            Advance;
          end;
        '"':
          begin
            AppendByte(Bytes, Count, $22);
            Advance;
          end;
        '''':
          begin
            AppendByte(Bytes, Count, $27);
            Advance;
          end;
        '\':
          begin
            AppendByte(Bytes, Count, $5C);
            Advance;
          end;
        'u':
          begin
            Advance;
            if Eof or (Cur <> '{') then
              Fault('expected "{" in \u escape', EscLine, EscColumn);
            Advance;
            { hexnum ::= hexdigit ('_'? hexdigit)* — it starts with a
              digit and underscores sit only BETWEEN digits
              (https://webassembly.github.io/spec/core/text/values.html#text-hexnum). }
            if Eof or not IsHexDigit(Cur) then
              Fault('expected hex digits in \u escape', EscLine, EscColumn);
            Scalar := 0;
            while not Eof and (IsHexDigit(Cur) or (Cur = '_')) do
            begin
              if Cur = '_' then
              begin
                Advance;
                if Eof or not IsHexDigit(Cur) then
                  Fault('"_" must sit between hex digits in \u escape',
                    EscLine, EscColumn);
                Continue;
              end;
              if Scalar > $10FFFF then
                Fault('\u escape beyond U+10FFFF', EscLine, EscColumn);
              Scalar := (Scalar shl 4) or HexDigitValue(Cur);
              Advance;
            end;
            if Eof or (Cur <> '}') then
              Fault('expected "}" in \u escape', EscLine, EscColumn);
            Advance;
            { A scalar value: below the surrogate block or above it, and
              within the Unicode range. Surrogates and beyond-range
              values are malformed script text. }
            if (Scalar > $10FFFF)
              or ((Scalar >= $D800) and (Scalar <= $DFFF)) then
              Fault('\u escape is not a Unicode scalar value',
                EscLine, EscColumn);
            AppendUtf8(Bytes, Count, Scalar);
          end;
      else
        if IsHexDigit(E) and IsHexDigit(Peek) then
        begin
          { \hh: a raw byte, NOT a codepoint — this is how binary module
            payloads spell arbitrary bytes. }
          AppendByte(Bytes, Count,
            (HexDigitValue(E) shl 4) or HexDigitValue(Peek));
          Advance;
          Advance;
        end
        else
          Fault('invalid escape sequence "\' + E + '"', EscLine, EscColumn);
      end;
      Continue;
    end;
    if (Ord(C) < $20) or (Ord(C) = $7F) then
      Fault('control character in string literal must be escaped',
        FLine, FColumn);
    AppendByte(Bytes, Count, Ord(C));
    Advance;
  end;
  SetLength(Bytes, Count);
  Result.Kind := wtkString;
  Result.Text := '';
  Result.Bytes := Bytes;
  Result.Line := ALine;
  Result.Column := AColumn;
end;

function TWastLexer.LexAtom(const ALine, AColumn: Integer): TWastToken;
var
  Start: Integer;
begin
  { Longest match: everything up to a delimiter is one token
    (https://webassembly.github.io/spec/core/text/lexical.html#text-token).
    Integers (hex, underscores), floats, `nan:0x...` forms, keywords,
    and `$identifiers` all land here as verbatim text — value parsing is
    a later Track C slice. }
  Start := FPos;
  while not Eof do
  begin
    case Cur of
      ' ', #9, #10, #13, '(', ')', ';':
        Break;
      '"':
        begin
          { A quoted string abutting an idchar run with no separator continues
            the SAME token by longest match — this is how a quoted identifier
            `$"name"` (spaces and escapes live inside the quotes) and reserved
            runs like `foo"x"` are single tokens, not an atom then a string
            (text-token; id.wast quoted-identifier forms). Consume the whole
            string literal, honouring `\` escapes, as part of the atom's raw
            text; the wat lexer re-tokenises and judges it. }
          Advance;   { opening " }
          while not Eof and (Cur <> '"') do
          begin
            if Cur = '\' then
              Advance;   { the escape's backslash; the byte is consumed below }
            if not Eof then
              Advance;
          end;
          if not Eof then
            Advance;   { closing " }
        end;
    else
      if (Ord(Cur) < $20) or (Ord(Cur) = $7F) then
        Fault('control character outside a string or comment',
          FLine, FColumn);
      Advance;
    end;
  end;
  Result.Kind := wtkAtom;
  Result.Text := Copy(FSource, Start, FPos - Start);
  Result.Bytes := nil;
  Result.Line := ALine;
  Result.Column := AColumn;
end;

function TWastLexer.Next: TWastToken;
begin
  SkipTrivia;
  Result.Text := '';
  Result.Bytes := nil;
  Result.Line := FLine;
  Result.Column := FColumn;
  if Eof then
  begin
    Result.Kind := wtkEof;
    Exit;
  end;
  case Cur of
    '(':
      begin
        Result.Kind := wtkLParen;
        Advance;
      end;
    ')':
      begin
        Result.Kind := wtkRParen;
        Advance;
      end;
    '"':
      Result := LexString(FLine, FColumn);
  else
    { LexAtom checks every character, including this first one, for
      stray control characters. }
    Result := LexAtom(FLine, FColumn);
  end;
end;

{ --- tree --------------------------------------------------------------- }

destructor TWastNode.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    FItems[I].Free;
  inherited Destroy;
end;

procedure TWastNode.AddItem(const AItem: TWastNode);
begin
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := AItem;
end;

function TWastNode.Count: Integer;
begin
  Result := Length(FItems);
end;

function TWastNode.GetItem(const AIndex: Integer): TWastNode;
begin
  if (AIndex < 0) or (AIndex >= Length(FItems)) then
    raise ERangeError.CreateFmt('node item index %d out of range 0..%d',
      [AIndex, Length(FItems) - 1]);
  Result := FItems[AIndex];
end;

function TWastNode.IsAtom(const AText: string): Boolean;
begin
  Result := (FKind = wnkAtom) and (FAtom = AText);
end;

function TWastNode.HeadAtom: string;
begin
  if (FKind = wnkList) and (Length(FItems) > 0)
    and (FItems[0].Kind = wnkAtom) then
    Result := FItems[0].Atom
  else
    Result := '';
end;

{ --- parser ------------------------------------------------------------- }

function MakeLeafNode(const AToken: TWastToken): TWastNode;
begin
  Result := TWastNode.Create;
  if AToken.Kind = wtkString then
  begin
    Result.FKind := wnkString;
    Result.FBytes := AToken.Bytes;
  end
  else
  begin
    Result.FKind := wnkAtom;
    Result.FAtom := AToken.Text;
  end;
  Result.FLine := AToken.Line;
  Result.FColumn := AToken.Column;
end;

{ Parse the node whose first token is AToken; recursive over lists. }
function ParseNode(var ALexer: TWastLexer;
  const AToken: TWastToken): TWastNode;
var
  Token: TWastToken;
begin
  if AToken.Kind <> wtkLParen then
    Exit(MakeLeafNode(AToken));

  Result := TWastNode.Create;
  Result.FKind := wnkList;
  Result.FLine := AToken.Line;
  Result.FColumn := AToken.Column;
  try
    while True do
    begin
      Token := ALexer.Next;
      case Token.Kind of
        wtkRParen:
          Break;
        wtkEof:
          raise EWastParseError.CreateFmt(
            'unterminated list (opened at line %d, column %d)',
            [AToken.Line, AToken.Column]);
      else
        Result.AddItem(ParseNode(ALexer, Token));
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function ClassifyHead(const AHead: string): TWastCommandKind;
begin
  if AHead = 'module' then
    Result := wcModule
  else if AHead = 'register' then
    Result := wcRegister
  else if AHead = 'invoke' then
    Result := wcInvoke
  else if AHead = 'assert_return' then
    Result := wcAssertReturn
  else if AHead = 'assert_trap' then
    Result := wcAssertTrap
  else if AHead = 'assert_invalid' then
    Result := wcAssertInvalid
  else if AHead = 'assert_malformed' then
    Result := wcAssertMalformed
  else if AHead = 'assert_unlinkable' then
    Result := wcAssertUnlinkable
  else if AHead = 'assert_exception' then
    Result := wcAssertException
  else if AHead = 'assert_exhaustion' then
    Result := wcAssertExhaustion
  else
    Result := wcUnknown;
end;

{ (module quote "..."*) and (module binary "..."*), each optionally with
  an id: the form marker is the atom right after `module` or after the
  `$id`. A text module's elements there are lists — `(func ...)` and
  friends — so a bare `binary` / `quote` atom is unambiguous. }
function DetectWastModuleForm(const ANode: TWastNode): TWastModuleForm;
var
  Index: Integer;
begin
  Result := wmfText;
  Index := 1;
  if (Index < ANode.Count) and (ANode[Index].Kind = wnkAtom)
    and (Length(ANode[Index].Atom) > 0)
    and (ANode[Index].Atom[1] = '$') then
    Inc(Index);
  if (Index < ANode.Count) and (ANode[Index].Kind = wnkAtom) then
  begin
    if ANode[Index].Atom = 'binary' then
      Result := wmfBinary
    else if ANode[Index].Atom = 'quote' then
      Result := wmfQuote;
  end;
end;

function ParseWastScript(const ASource: string): TWastScript;
var
  Lexer: TWastLexer;
  Token: TWastToken;
  Command: TWastCommand;
begin
  Lexer.Init(ASource);
  Result := TWastScript.Create;
  try
    while True do
    begin
      Token := Lexer.Next;
      case Token.Kind of
        wtkEof:
          Break;
        wtkRParen:
          raise EWastParseError.CreateFmt(
            'unexpected ")" at top level (line %d, column %d)',
            [Token.Line, Token.Column]);
      else
        begin
          Command.Node := ParseNode(Lexer, Token);
          Command.Kind := ClassifyHead(Command.Node.HeadAtom);
          if Command.Kind = wcModule then
            Command.ModuleForm := DetectWastModuleForm(Command.Node)
          else
            Command.ModuleForm := wmfText;
          try
            Result.AddCommand(Command);
          except
            Command.Node.Free;
            raise;
          end;
        end;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function WastCommandKindName(const AKind: TWastCommandKind): string;
begin
  case AKind of
    wcModule: Result := 'module';
    wcRegister: Result := 'register';
    wcInvoke: Result := 'invoke';
    wcAssertReturn: Result := 'assert_return';
    wcAssertTrap: Result := 'assert_trap';
    wcAssertInvalid: Result := 'assert_invalid';
    wcAssertMalformed: Result := 'assert_malformed';
    wcAssertUnlinkable: Result := 'assert_unlinkable';
    wcAssertException: Result := 'assert_exception';
    wcAssertExhaustion: Result := 'assert_exhaustion';
    wcUnknown: Result := 'unknown';
  else
    Result := '?';
  end;
end;

{ --- script ------------------------------------------------------------- }

destructor TWastScript.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FCommands) do
    FCommands[I].Node.Free;
  inherited Destroy;
end;

procedure TWastScript.AddCommand(const ACommand: TWastCommand);
begin
  SetLength(FCommands, Length(FCommands) + 1);
  FCommands[High(FCommands)] := ACommand;
end;

function TWastScript.Count: Integer;
begin
  Result := Length(FCommands);
end;

function TWastScript.GetCommand(const AIndex: Integer): TWastCommand;
begin
  if (AIndex < 0) or (AIndex >= Length(FCommands)) then
    raise ERangeError.CreateFmt('command index %d out of range 0..%d',
      [AIndex, Length(FCommands) - 1]);
  Result := FCommands[AIndex];
end;

end.
