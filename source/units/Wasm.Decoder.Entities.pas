{ Wasm.Decoder.Entities — the entity-section decoders: imports,
  functions, tables, memories, globals, exports, start, and tags.

  Each procedure decodes one section BODY (the reader is a SubReader over
  exactly the declared size; ABase is the body's absolute buffer offset)
  into the module model, and must consume it exactly: bytes left over
  after the declared content are malformed — the "section size mismatch"
  family — and running out early fails inside the reader the same way.
  Every decoder deliberately shares the (ABody, ABase, AModule)
  signature, whether or not it needs each parameter, so the section walk
  in Wasm.Decoder can dispatch them uniformly.
  Grammar clauses are in the binary format's Modules chapter
  (https://webassembly.github.io/spec/core/binary/modules.html).

  Everything raised here is EWasmDecodeError, because everything checked
  here is the binary grammar: an unassigned discriminator byte, a
  truncated vector, a stray reserved byte. Rules that need context —
  whether an index is in range, whether an init expression is constant,
  whether two exports share a name — are validation and are deliberately
  NOT checked here; rejecting them early would corrupt the
  malformed/invalid split the conformance suite asserts.

  Init expressions (global initialisers and the 3.0 explicit table
  initialiser) are not interpreted: SkipExpr walks them to their `end`
  and the model stores the span (ADR-0003 — nothing is copied). }
unit Wasm.Decoder.Entities;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Common,
  Wasm.Decoder.Expr,
  Wasm.Module;

{ Import section (id 2): vec(import), each import being two names
  (module, then item — both UTF-8-checked in ReadName, a DECODE rule)
  and an externtype whose discriminator byte selects the description:
  $00 func typeidx, $01 table tabletype, $02 mem memtype, $03 global
  globaltype, $04 tag tagtype. Any other discriminator is malformed.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-importsec
  https://webassembly.github.io/spec/core/binary/types.html#binary-externtype }
procedure DecodeImportSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Function section (id 3): vec(typeidx). Whether each index names a
  function type that exists is validation.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-funcsec }
procedure DecodeFunctionSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Table section (id 4): vec(table), where each table is EITHER a bare
  tabletype (default-initialised) OR the 3.0 explicit-init form
    $40 $00 tt:tabletype e:expr
  — a tabletype cannot start with $40 (it starts with a reftype), so a
  leading $40 unambiguously selects the second form, and the following
  byte is reserved and must be ZERO.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-table }
procedure DecodeTableSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Memory section (id 5): vec(memtype).
  https://webassembly.github.io/spec/core/binary/modules.html#binary-memsec }
procedure DecodeMemorySection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Global section (id 6): vec(global), each a globaltype followed by its
  init expr. The expr is skipped, not interpreted — constness is a
  validation rule.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-globalsec }
procedure DecodeGlobalSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Export section (id 7): vec(export), each a name and an externidx —
  the same $00..$04 discriminator bytes as imports, then an index into
  that kind's space. Duplicate export names decode FINE: the names-are-
  disjoint rule is part of module VALIDITY
  (https://webassembly.github.io/spec/core/valid/modules.html#valid-module),
  not the binary grammar, so rejecting one here would misfile an invalid
  module as malformed.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-exportsec }
procedure DecodeExportSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Start section (id 8): a single funcidx, no vector. Anything after it
  is a size mismatch.
  https://webassembly.github.io/spec/core/binary/modules.html#binary-startsec }
procedure DecodeStartSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

{ Tag section (id 13): vec(tagtype).
  https://webassembly.github.io/spec/core/binary/modules.html#binary-tagsec }
procedure DecodeTagSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);

implementation

const
  { The explicit-init table form's marker. Reserved-for-extensions zero
    byte follows it; see DecodeTableSection's interface comment. }
  TABLE_INIT_MARKER = $40;

{ The import/export discriminator byte. Exactly five assigned values,
  matching TWasmExternKind's ordinals by construction.

  APrefix is the caller's, not a constant here, because upstream names
  the failure after the SECTION the byte appears in — `malformed import
  kind` and `malformed export kind` — even though it is one production.
  https://webassembly.github.io/spec/core/binary/types.html#binary-externtype }
function ReadExternKind(var AReader: TWasmReader;
  const ABase: NativeUInt; const APrefix: string): TWasmExternKind;
var
  Start: NativeUInt;
  Code: Byte;
begin
  Start := AReader.Position;
  Code := AReader.ReadByte;
  if Code > Ord(High(TWasmExternKind)) then
    raise EWasmDecodeError.CreateFmt(
      '%s: $%.2x at offset %u', [APrefix, Code, ABase + Start]);
  Result := TWasmExternKind(Code);
end;

procedure DecodeImportSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
  Import: TWasmImport;
begin
  Count := ReadVecCount(ABody, 'import');
  for I := 1 to Count do
  begin
    { Start from defaults so the fields the Kind leaves inactive are
      zeroed — two imports decoded from the same bytes compare equal
      (see the record's comment in Wasm.Module). }
    Import := Default(TWasmImport);
    Import.ModuleName := ABody.ReadName;
    Import.Name := ABody.ReadName;
    Import.Kind := ReadExternKind(ABody, ABase, MSG_MALFORMED_IMPORT_KIND);
    case Import.Kind of
      wxkFunc:   Import.FuncTypeIndex := ABody.ReadU32;
      wxkTable:  Import.Table := ReadTableType(ABody);
      wxkMem:    Import.Mem := ReadMemType(ABody);
      wxkGlobal: Import.Global := ReadGlobalType(ABody);
      wxkTag:    Import.Tag := ReadTagType(ABody);
    end;
    AModule.AddImport(Import);
  end;
  RequireSectionExhausted(ABody, ABase, 'import');
end;

procedure DecodeFunctionSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
begin
  Count := ReadVecCount(ABody, 'function type index');
  for I := 1 to Count do
    AModule.AddFunctionTypeIndex(ABody.ReadU32);
  RequireSectionExhausted(ABody, ABase, 'function');
end;

procedure DecodeTableSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
  Table: TWasmTable;
  Start: NativeUInt;
  Reserved: Byte;
begin
  Count := ReadVecCount(ABody, 'table');
  for I := 1 to Count do
  begin
    Table := Default(TWasmTable);
    { A tabletype starts with a reftype, which can never be $40 — the
      spec notes decoding is unambiguous on this byte. }
    if ABody.PeekByte = TABLE_INIT_MARKER then
    begin
      ABody.ReadByte;
      Start := ABody.Position;
      Reserved := ABody.ReadByte;
      if Reserved <> $00 then
        raise EWasmDecodeError.CreateFmt(
          'malformed table: reserved byte $%.2x at offset %u '
          + '(must be zero)', [Reserved, ABase + Start]);
      Table.TableType := ReadTableType(ABody);
      Table.HasInit := True;
      Table.Init := SkipExpr(ABody, ABase);
    end
    else
      Table.TableType := ReadTableType(ABody);
    AModule.AddTable(Table);
  end;
  RequireSectionExhausted(ABody, ABase, 'table');
end;

procedure DecodeMemorySection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
begin
  Count := ReadVecCount(ABody, 'memory type');
  for I := 1 to Count do
    AModule.AddMemory(ReadMemType(ABody));
  RequireSectionExhausted(ABody, ABase, 'memory');
end;

procedure DecodeGlobalSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
  Global: TWasmGlobal;
begin
  Count := ReadVecCount(ABody, 'global');
  for I := 1 to Count do
  begin
    { Globaltype first, then the init expr — the expr has no size
      prefix, so SkipExpr walks it to its `end` and returns the span. }
    Global.GlobalType := ReadGlobalType(ABody);
    Global.Init := SkipExpr(ABody, ABase);
    AModule.AddGlobal(Global);
  end;
  RequireSectionExhausted(ABody, ABase, 'global');
end;

procedure DecodeExportSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
  Entry: TWasmExport;
begin
  Count := ReadVecCount(ABody, 'export');
  for I := 1 to Count do
  begin
    { The reference decoder consumes vector entries from the physical stream
      before checking the export section's declared size. If the vector count
      promises another named entry exactly at the section boundary and the
      module continues, it reports the name list as out of bounds rather than
      generic section truncation. Keep this narrow to exports: other entity
      productions have different confirmed prefixes for the same geometry. }
    if ABody.Eof and (ABody.PhysicalRemaining > 0)
      { In binary.wast:737 the next section's one-byte id is consumed as the
        missing export's one-byte name length, but the declared bytes do not
        physically remain. Do not generalize this to `$00` (an empty name) or
        a continued u32; those retain the ordinary section-truncation
        diagnosis. }
      and ((ABody.PeekPhysicalByte and $80) = 0)
      and (ABody.PhysicalRemaining < 1 + ABody.PeekPhysicalByte) then
      raise EWasmDecodeError.CreateFmt(
        '%s: export name starts at section boundary offset %u',
        [MSG_LENGTH_OUT_OF_BOUNDS, ABase + ABody.Position]);
    Entry.Name := ABody.ReadName;
    Entry.Kind := ReadExternKind(ABody, ABase, MSG_MALFORMED_EXPORT_KIND);
    Entry.Index := ABody.ReadU32;
    { No duplicate-name check here on purpose — see the interface
      comment: name disjointness is module validity, not grammar. }
    AModule.AddExport(Entry);
  end;
  RequireSectionExhausted(ABody, ABase, 'export');
end;

procedure DecodeStartSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
begin
  AModule.StartFuncIndex := ABody.ReadU32;
  AModule.HasStart := True;
  RequireSectionExhausted(ABody, ABase, 'start');
end;

procedure DecodeTagSection(var ABody: TWasmReader;
  const ABase: NativeUInt; const AModule: TWasmModule);
var
  Count: UInt32;
  I: UInt32;
begin
  Count := ReadVecCount(ABody, 'tag');
  for I := 1 to Count do
    AModule.AddTag(ReadTagType(ABody));
  RequireSectionExhausted(ABody, ABase, 'tag');
end;

end.
