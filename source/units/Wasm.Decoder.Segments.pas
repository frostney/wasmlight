{ Wasm.Decoder.Segments — the segment-carrying sections: element, code,
  data, and data count.

  These are the sections whose payloads stay in the module buffer as
  spans (ADR-0003): element offset and init expressions, function
  bodies, and data bytes are located but never copied and never
  interpreted. Expressions are delimited by Wasm.Decoder.Expr's skipper;
  function bodies are bounded by the code entry's size prefix and are
  deliberately NOT instruction-walked here — the fused validation walk
  owns the instruction grammar inside them (ADR-0007).

  Everything raised here is EWasmDecodeError, because everything checked
  here is the binary grammar: an unassigned segment flag value, a
  nonzero elemkind byte, a code entry whose size prefix disagrees with
  its content, a locals list past the grammar's bound, trailing bytes
  after a section's declared content. Whether a table/memory/function
  index exists, whether an offset expression is constant — validation,
  deliberately not checked here. Cross-SECTION consistency (code count
  vs function section, data count vs data section) belongs to the
  section walk in Wasm.Decoder, not to these standalone body decoders.

  Each decoder consumes its section body EXACTLY: the callers hand in a
  SubReader over the body, and leftover bytes after the declared
  content are the "section size mismatch" family of malformations.
  https://webassembly.github.io/spec/core/binary/modules.html }
unit Wasm.Decoder.Segments;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Common,
  Wasm.Decoder.Expr,
  Wasm.Module;

{ Element section (id 9): vec(elem), where each segment starts with a
  u32 whose value selects one of EIGHT productions (0..7). The value is
  a bitfield — bit 0: passive/declarative rather than active; bit 1: an
  explicit table index (active) or declarative rather than passive;
  bit 2: element expressions + reftype rather than funcidx list +
  elemkind. Values 8 and above match no production and are malformed.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-elemsec }
procedure DecodeElementSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Code section (id 10): vec(code), each entry a u32 byte size followed
  by exactly that many bytes of locals vector + function body. The size
  side condition is grammar: "The module is malformed if a size does
  not match the length of the respective function code" — and so is the
  locals bound: "Any code for which the length of the resulting
  sequence is out of bounds of the maximum size of a list is
  malformed", a list holding at most 2^32-1 elements (syntax-list). Too
  many locals is therefore MALFORMED here, not invalid later.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-codesec
  https://webassembly.github.io/spec/core/syntax/conventions.html#syntax-list }
procedure DecodeCodeSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Data section (id 11): vec(data), each segment a u32 bitfield — bit 0:
  passive; bit 1: explicit memory index (active only). Three assigned
  values (0..2); 3 and above are malformed. The payload is stored as a
  span into the module buffer, never copied.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-datasec }
procedure DecodeDataSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Data count section (id 12): a single u32. Whether it matches the data
  section's segment count is checked at the section walk, which sees
  both sections — not here.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-datacntsec }
procedure DecodeDataCountSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

implementation

{ elemkind ::= 0x00 (funcref) — the only assigned value; the spec notes
  additional kinds may be added later, so anything else is malformed
  today.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-elemkind }
procedure ReadElemKind(var ABody: TWasmReader; const ABase: NativeUInt);
var
  Start: NativeUInt;
  Kind: Byte;
begin
  Start := ABody.Position;
  Kind := ABody.ReadByte;
  if Kind <> $00 then
    raise EWasmDecodeError.CreateFmt(
      'malformed element kind $%.2x at offset %u', [Kind, ABase + Start]);
end;

{ vec(funcidx) into FuncIndices. }
procedure ReadFuncIndices(var ABody: TWasmReader;
  var ASegment: TWasmElemSegment);
var
  Count: UInt32;
  I: UInt32;
begin
  Count := ReadVecCount(ABody, 'function index');
  SetLength(ASegment.FuncIndices, Count);
  for I := 1 to Count do
    ASegment.FuncIndices[I - 1] := ABody.ReadU32;
end;

{ vec(expr) into InitExprs, each expression delimited by the skipper. }
procedure ReadInitExprs(var ABody: TWasmReader; const ABase: NativeUInt;
  var ASegment: TWasmElemSegment);
var
  Count: UInt32;
  I: UInt32;
begin
  Count := ReadVecCount(ABody, 'element expression');
  SetLength(ASegment.InitExprs, Count);
  for I := 1 to Count do
    ASegment.InitExprs[I - 1] := SkipExpr(ABody, ABase);
end;

procedure DecodeElementSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
  FlagsStart: NativeUInt;
  Flags: UInt32;
  Segment: TWasmElemSegment;
begin
  Count := ReadVecCount(ABody, 'element segment');
  for I := 1 to Count do
  begin
    FlagsStart := ABody.Position;
    Flags := ABody.ReadU32;

    { Start from defaults so the fields a production leaves untouched
      are zeroed — two segments decoded from the same bytes compare
      equal.

      The default element type is the NON-NULLABLE `(ref func)`, not
      `funcref`, and the difference is load-bearing. The four funcidx
      productions (0/1/2/3) build their elements as `(ref.func y) end`,
      which is a non-null reference, and the grammar's element type
      follows: production 0 yields `ref func` outright and `elemkind
      ::= 0x00 => ref func` gives 1/2/3 the same. Only production 4 —
      element EXPRESSIONS with an implied type — yields `ref null func`,
      because an arbitrary element expression may be `ref.null func`;
      that arm overwrites the default below, as 5/6/7 do with their
      explicit reftype.

      Reading `funcref` into the funcidx forms wrongly rejects a
      shorthand segment against a `(ref func)` table, since `funcref`
      does not match a non-nullable element type — upstream elem.wast
      ships exactly that module (flags 0 and 2) as VALID, and ships the
      production-4 counterpart as `assert_invalid "type mismatch"`.
      https://webassembly.github.io/spec/core/binary/modules.html#binary-elem
      https://webassembly.github.io/spec/core/binary/modules.html#binary-elemkind }
    Segment := Default(TWasmElemSegment);
    Segment.RefType := MakeRefType(False, MakeAbsHeapType(wahFunc));

    { The eight productions of binary-elem, each arm labelled with its
      flag value. Bit 0 = passive/declarative, bit 1 = explicit table
      index (active) or declarative (non-active), bit 2 = expressions +
      reftype instead of funcidx list + elemkind. }
    case Flags of
      0: begin
        { 0: active, implicit table 0, offset expr, vec(funcidx). }
        Segment.Mode := wemActive;
        Segment.Offset := SkipExpr(ABody, ABase);
        ReadFuncIndices(ABody, Segment);
      end;
      1: begin
        { 1: passive, elemkind, vec(funcidx). }
        Segment.Mode := wemPassive;
        ReadElemKind(ABody, ABase);
        ReadFuncIndices(ABody, Segment);
      end;
      2: begin
        { 2: active, explicit table index, offset expr, elemkind,
          vec(funcidx). }
        Segment.Mode := wemActive;
        Segment.TableIndex := ABody.ReadU32;
        Segment.Offset := SkipExpr(ABody, ABase);
        ReadElemKind(ABody, ABase);
        ReadFuncIndices(ABody, Segment);
      end;
      3: begin
        { 3: declarative, elemkind, vec(funcidx). }
        Segment.Mode := wemDeclarative;
        ReadElemKind(ABody, ABase);
        ReadFuncIndices(ABody, Segment);
      end;
      4: begin
        { 4: active, implicit table 0, offset expr, vec(expr) with
          implied funcref — NULLABLE, unlike the funcidx forms above:
          the production is `elem (ref null func) e* (active 0 e_o)`. }
        Segment.Mode := wemActive;
        Segment.UsesExprs := True;
        Segment.RefType := MakeRefType(True, MakeAbsHeapType(wahFunc));
        Segment.Offset := SkipExpr(ABody, ABase);
        ReadInitExprs(ABody, ABase, Segment);
      end;
      5: begin
        { 5: passive, reftype, vec(expr). }
        Segment.Mode := wemPassive;
        Segment.UsesExprs := True;
        Segment.RefType := ReadRefType(ABody);
        ReadInitExprs(ABody, ABase, Segment);
      end;
      6: begin
        { 6: active, explicit table index, offset expr, reftype,
          vec(expr). }
        Segment.Mode := wemActive;
        Segment.UsesExprs := True;
        Segment.TableIndex := ABody.ReadU32;
        Segment.Offset := SkipExpr(ABody, ABase);
        Segment.RefType := ReadRefType(ABody);
        ReadInitExprs(ABody, ABase, Segment);
      end;
      7: begin
        { 7: declarative, reftype, vec(expr). }
        Segment.Mode := wemDeclarative;
        Segment.UsesExprs := True;
        Segment.RefType := ReadRefType(ABody);
        ReadInitExprs(ABody, ABase, Segment);
      end;
    else
      raise EWasmDecodeError.CreateFmt(
        'malformed element segment flags %u at offset %u',
        [Flags, ABase + FlagsStart]);
    end;

    AModule.AddElement(Segment);
  end;

  RequireSectionExhausted(ABody, ABase, 'element');
end;

procedure DecodeCodeSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
const
  { A list has at most 2^32-1 elements (syntax-list), and binary-code
    makes exceeding that with the expanded locals sequence MALFORMED. }
  MAX_LOCALS = UInt64($FFFFFFFF);
var
  Count: UInt32;
  I: UInt32;
  EntrySize: UInt32;
  EntryBase: NativeUInt;
  Entry: TWasmReader;
  CodeEntry: TWasmCodeEntry;
  GroupCount: UInt32;
  G: UInt32;
  TotalLocals: UInt64;
begin
  Count := ReadVecCount(ABody, 'code entry');
  for I := 1 to Count do
  begin
    { The size prefix bounds the whole entry: the SubReader makes any
      read past it fail as truncation, and a size that runs past the
      section body fails right here — both directions of the "size does
      not match the length of the respective function code" side
      condition that the entry's extent can show on its own. }
    EntrySize := ABody.ReadU32;
    EntryBase := ABase + ABody.Position;
    Entry := ABody.SubReader(EntrySize);

    { Locals: vec of (count, valtype) run-length groups. The bound is
      on the EXPANDED sequence, so the group counts are summed wide. }
    TotalLocals := 0;
    GroupCount := ReadVecCount(Entry, 'locals group');
    SetLength(CodeEntry.Locals, GroupCount);
    for G := 1 to GroupCount do
    begin
      CodeEntry.Locals[G - 1].Count := Entry.ReadU32;
      CodeEntry.Locals[G - 1].ValueType := ReadValueType(Entry);
      Inc(TotalLocals, CodeEntry.Locals[G - 1].Count);
    end;
    if TotalLocals > MAX_LOCALS then
      raise EWasmDecodeError.CreateFmt(
        'too many locals (%u) in code entry at offset %u',
        [TotalLocals, EntryBase]);

    { The body is everything left in the entry, terminating `end` byte
      included — deliberately not instruction-walked (ADR-0007). An
      expr is at least its `end` byte, so an entry whose size leaves no
      body bytes matches no production. Hand-off contract for the fused
      validation walk that DOES walk this span: if it finds the body's
      terminating `end` before the span's last byte, it must raise
      EWasmDecodeError, not EWasmValidationError — the "size does not
      match the length of the respective function code" side condition
      is binary grammar (binary-code), however late it is discovered.
      https://webassembly.github.io/spec/core/binary/modules.html#binary-code }
    if Entry.Remaining = 0 then
      raise EWasmDecodeError.CreateFmt(
        'code entry at offset %u has no function body',
        [EntryBase]);
    CodeEntry.Body := MakeSpan(EntryBase + Entry.Position, Entry.Remaining);

    AModule.AddCodeEntry(CodeEntry);
  end;

  RequireSectionExhausted(ABody, ABase, 'code');
end;

procedure DecodeDataSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
  FlagsStart: NativeUInt;
  Flags: UInt32;
  Segment: TWasmDataSegment;
  ByteCount: UInt32;
begin
  Count := ReadVecCount(ABody, 'data segment');
  for I := 1 to Count do
  begin
    FlagsStart := ABody.Position;
    Flags := ABody.ReadU32;

    Segment.Mode := wdmActive;
    Segment.MemIndex := 0;
    Segment.Offset := MakeSpan(0, 0);

    { The three productions of binary-data, each arm labelled with its
      flag value. Bit 0 = passive, bit 1 = explicit memory index. }
    case Flags of
      0: begin
        { 0: active, implicit memory 0, offset expr, vec(byte). }
        Segment.Mode := wdmActive;
        Segment.Offset := SkipExpr(ABody, ABase);
      end;
      1: begin
        { 1: passive, vec(byte). }
        Segment.Mode := wdmPassive;
      end;
      2: begin
        { 2: active, explicit memory index, offset expr, vec(byte). }
        Segment.Mode := wdmActive;
        Segment.MemIndex := ABody.ReadU32;
        Segment.Offset := SkipExpr(ABody, ABase);
      end;
    else
      raise EWasmDecodeError.CreateFmt(
        'malformed data segment flags %u at offset %u',
        [Flags, ABase + FlagsStart]);
    end;

    { vec(byte), stored as a span into the module buffer (ADR-0003). }
    ByteCount := ABody.ReadU32;
    Segment.Bytes := MakeSpan(ABase + ABody.Position, ByteCount);
    ABody.Skip(ByteCount);

    AModule.AddDataSegment(Segment);
  end;

  RequireSectionExhausted(ABody, ABase, 'data');
end;

procedure DecodeDataCountSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
begin
  AModule.DataCount := ABody.ReadU32;
  AModule.HasDataCount := True;
  RequireSectionExhausted(ABody, ABase, 'data count');
end;

end.
