{ Wasm.Module — the decoded module model.

  A module is a passive description of what a `.wasm` file contains. It
  holds no host state, no memory, and no execution tier: instantiating one
  produces the store-side objects, and that boundary is why the same
  decoded module can be handed to any tier (ADR-0001).

  Section bodies are kept as offsets into the original buffer rather than
  copied out (ADR-0003). The model now also carries decoded section
  content — types, imports, tables, globals, exports, segments, code
  entries — but expression bodies, function bodies, and data bytes are
  still referenced as spans into the borrowed buffer, never copied. The
  buffer must outlive the module. }
unit Wasm.Module;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

type
  TWasmSectionInfo = record
    Id: Byte;
    { Custom sections only; empty for every known section id. }
    Name: string;
    { Offset and length of the section BODY within the module buffer —
      the id byte and the size LEB128 are not included. }
    BodyOffset: NativeUInt;
    BodySize: NativeUInt;

    function IsCustom: Boolean;
    { `type`, `code`, ... — or `custom "name"` for custom sections. }
    function DisplayName: string;
  end;

  { A range of the module buffer: ABSOLUTE offset plus size (ADR-0003).
    Everything the model does not decode eagerly — init expressions,
    function bodies, data bytes — is one of these. }
  TWasmSpan = record
    Offset: NativeUInt;
    Size: NativeUInt;
  end;

  { One import. Kind discriminates which description field is meaningful;
    the decoder leaves the inactive ones at their defaults, so two imports
    decoded from the same bytes always compare equal. }
  TWasmImport = record
    ModuleName: string;
    Name: string;
    Kind: TWasmExternKind;
    FuncTypeIndex: UInt32;
    Table: TWasmTableType;
    Mem: TWasmMemType;
    Global: TWasmGlobalType;
    Tag: TWasmTagType;
  end;

  TWasmExport = record
    Name: string;
    Kind: TWasmExternKind;
    { Index into the Kind's index space — which includes imports first. }
    Index: UInt32;
  end;

  { A defined table. Wasm 3.0 lets a table definition carry an explicit
    init expression; HasInit distinguishes that form from the classic
    default-initialised one. }
  TWasmTable = record
    TableType: TWasmTableType;
    HasInit: Boolean;
    Init: TWasmSpan;
  end;

  TWasmGlobal = record
    GlobalType: TWasmGlobalType;
    Init: TWasmSpan;
  end;

  TWasmElemMode = (wemActive, wemPassive, wemDeclarative);

  { An element segment. TableIndex and Offset are meaningful only in
    active mode. The initialiser list is EITHER function indices or
    expression spans — UsesExprs says which array is populated. }
  TWasmElemSegment = record
    Mode: TWasmElemMode;
    TableIndex: UInt32;
    Offset: TWasmSpan;
    RefType: TWasmRefType;
    UsesExprs: Boolean;
    FuncIndices: array of UInt32;
    InitExprs: array of TWasmSpan;
  end;

  TWasmDataMode = (wdmActive, wdmPassive);

  { A data segment. MemIndex and Offset are meaningful only in active
    mode; Bytes spans the payload in the module buffer. }
  TWasmDataSegment = record
    Mode: TWasmDataMode;
    MemIndex: UInt32;
    Offset: TWasmSpan;
    Bytes: TWasmSpan;
  end;

  { A run-length group of locals, exactly as the code section encodes
    them — expanding to one entry per local is the validator's business
    (and where the spec's total-locals limit is enforced). }
  TWasmLocalGroup = record
    Count: UInt32;
    ValueType: TWasmValueType;
  end;

  TWasmCodeEntry = record
    Locals: array of TWasmLocalGroup;
    { The instruction sequence including its terminating `end` byte. }
    Body: TWasmSpan;
  end;

  TWasmModule = class
  private
    FVersion: UInt32;
    FSize: NativeUInt;
    FSections: array of TWasmSectionInfo;

    FTypes: array of TWasmRecType;
    FImports: array of TWasmImport;
    FFunctionTypeIndices: array of UInt32;
    FTables: array of TWasmTable;
    FMemories: array of TWasmMemType;
    FGlobals: array of TWasmGlobal;
    FExports: array of TWasmExport;
    FElements: array of TWasmElemSegment;
    FCodeEntries: array of TWasmCodeEntry;
    FDataSegments: array of TWasmDataSegment;
    FTags: array of TWasmTagType;

    FHasStart: Boolean;
    FStartFuncIndex: UInt32;
    FHasDataCount: Boolean;
    FDataCount: UInt32;

    { Shared range check for every indexed getter. }
    procedure CheckIndex(const AIndex, ACount: Integer;
      const AWhat: string);

    function GetSection(const AIndex: Integer): TWasmSectionInfo;
    function GetType(const AIndex: Integer): TWasmRecType;
    function GetImport(const AIndex: Integer): TWasmImport;
    function GetFunctionTypeIndex(const AIndex: Integer): UInt32;
    function GetTable(const AIndex: Integer): TWasmTable;
    function GetMemory(const AIndex: Integer): TWasmMemType;
    function GetGlobal(const AIndex: Integer): TWasmGlobal;
    function GetExport(const AIndex: Integer): TWasmExport;
    function GetElement(const AIndex: Integer): TWasmElemSegment;
    function GetCodeEntry(const AIndex: Integer): TWasmCodeEntry;
    function GetDataSegment(const AIndex: Integer): TWasmDataSegment;
    function GetTag(const AIndex: Integer): TWasmTagType;
  public
    procedure Clear;
    procedure AddSection(const ASection: TWasmSectionInfo);

    function SectionCount: Integer;
    { Index of the first section with AId, or -1. Known sections are
      unique per module, so for anything but wsCustom this is *the*
      section. }
    function IndexOfSection(const AId: TWasmSectionId): Integer;
    function HasSection(const AId: TWasmSectionId): Boolean;
    function CustomSectionCount: Integer;

    procedure AddType(const AType: TWasmRecType);
    function TypeCount: Integer;
    procedure AddImport(const AImport: TWasmImport);
    function ImportCount: Integer;
    procedure AddFunctionTypeIndex(const ATypeIndex: UInt32);
    function FunctionTypeIndexCount: Integer;
    procedure AddTable(const ATable: TWasmTable);
    function TableCount: Integer;
    procedure AddMemory(const AMemory: TWasmMemType);
    function MemoryCount: Integer;
    procedure AddGlobal(const AGlobal: TWasmGlobal);
    function GlobalCount: Integer;
    procedure AddExport(const AExport: TWasmExport);
    function ExportCount: Integer;
    procedure AddElement(const AElement: TWasmElemSegment);
    function ElementCount: Integer;
    procedure AddCodeEntry(const AEntry: TWasmCodeEntry);
    function CodeEntryCount: Integer;
    procedure AddDataSegment(const ASegment: TWasmDataSegment);
    function DataSegmentCount: Integer;
    procedure AddTag(const ATag: TWasmTagType);
    function TagCount: Integer;

    { Imports of one kind — computed on demand, never cached; the model
      stays a plain bag of what the decoder found. }
    function ImportCountOfKind(const AKind: TWasmExternKind): Integer;

    { Sizes of the index spaces, which count imports FIRST and then the
      module's own definitions — the numbering every index in exports,
      element segments, and instructions refers to. }
    function TotalFunctionCount: Integer;
    function TotalTableCount: Integer;
    function TotalMemoryCount: Integer;
    function TotalGlobalCount: Integer;
    function TotalTagCount: Integer;

    property Sections[const AIndex: Integer]: TWasmSectionInfo
      read GetSection; default;
    property Types[const AIndex: Integer]: TWasmRecType read GetType;
    property Imports[const AIndex: Integer]: TWasmImport read GetImport;
    property FunctionTypeIndices[const AIndex: Integer]: UInt32
      read GetFunctionTypeIndex;
    property Tables[const AIndex: Integer]: TWasmTable read GetTable;
    property Memories[const AIndex: Integer]: TWasmMemType read GetMemory;
    property Globals[const AIndex: Integer]: TWasmGlobal read GetGlobal;
    { `exports` is a reserved word, hence the escape; callers spell it
      `Module.&Exports[I]`. }
    property &Exports[const AIndex: Integer]: TWasmExport read GetExport;
    property Elements[const AIndex: Integer]: TWasmElemSegment
      read GetElement;
    property CodeEntries[const AIndex: Integer]: TWasmCodeEntry
      read GetCodeEntry;
    property DataSegments[const AIndex: Integer]: TWasmDataSegment
      read GetDataSegment;
    property Tags[const AIndex: Integer]: TWasmTagType read GetTag;

    { Binary-format version from the preamble. Always WASM_BINARY_VERSION
      for a module the decoder accepted. }
    property Version: UInt32 read FVersion write FVersion;
    { Size of the buffer this module was decoded from. }
    property Size: NativeUInt read FSize write FSize;

    { The start section, when present. StartFuncIndex is meaningful only
      while HasStart is True. }
    property HasStart: Boolean read FHasStart write FHasStart;
    property StartFuncIndex: UInt32 read FStartFuncIndex
      write FStartFuncIndex;
    { The data count section, when present. The count is what the binary
      DECLARED; whether it matches the data section is checked at the
      section walk, not here. }
    property HasDataCount: Boolean read FHasDataCount write FHasDataCount;
    property DataCount: UInt32 read FDataCount write FDataCount;
  end;

function MakeSpan(const AOffset, ASize: NativeUInt): TWasmSpan;

implementation

function MakeSpan(const AOffset, ASize: NativeUInt): TWasmSpan;
begin
  Result.Offset := AOffset;
  Result.Size := ASize;
end;

function TWasmSectionInfo.IsCustom: Boolean;
begin
  Result := Id = Ord(wsCustom);
end;

function TWasmSectionInfo.DisplayName: string;
begin
  if IsCustom then
    Result := 'custom "' + Name + '"'
  else
    Result := SectionIdName(Id);
end;

procedure TWasmModule.Clear;
begin
  FVersion := 0;
  FSize := 0;
  SetLength(FSections, 0);

  SetLength(FTypes, 0);
  SetLength(FImports, 0);
  SetLength(FFunctionTypeIndices, 0);
  SetLength(FTables, 0);
  SetLength(FMemories, 0);
  SetLength(FGlobals, 0);
  SetLength(FExports, 0);
  SetLength(FElements, 0);
  SetLength(FCodeEntries, 0);
  SetLength(FDataSegments, 0);
  SetLength(FTags, 0);

  FHasStart := False;
  FStartFuncIndex := 0;
  FHasDataCount := False;
  FDataCount := 0;
end;

procedure TWasmModule.CheckIndex(const AIndex, ACount: Integer;
  const AWhat: string);
begin
  if (AIndex < 0) or (AIndex >= ACount) then
    raise EWasmError.CreateFmt('%s index %d out of range (%d entries)',
      [AWhat, AIndex, ACount]);
end;

procedure TWasmModule.AddSection(const ASection: TWasmSectionInfo);
begin
  SetLength(FSections, Length(FSections) + 1);
  FSections[High(FSections)] := ASection;
end;

function TWasmModule.SectionCount: Integer;
begin
  Result := Length(FSections);
end;

function TWasmModule.GetSection(const AIndex: Integer): TWasmSectionInfo;
begin
  if (AIndex < 0) or (AIndex >= Length(FSections)) then
    raise EWasmError.CreateFmt('section index %d out of range (%d section(s))',
      [AIndex, Length(FSections)]);
  Result := FSections[AIndex];
end;

function TWasmModule.IndexOfSection(const AId: TWasmSectionId): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FSections) do
    if FSections[I].Id = Ord(AId) then
      Exit(I);
  Result := -1;
end;

function TWasmModule.HasSection(const AId: TWasmSectionId): Boolean;
begin
  Result := IndexOfSection(AId) >= 0;
end;

function TWasmModule.CustomSectionCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FSections) do
    if FSections[I].IsCustom then
      Inc(Result);
end;

{ --- decoded section content -------------------------------------------- }

procedure TWasmModule.AddType(const AType: TWasmRecType);
begin
  SetLength(FTypes, Length(FTypes) + 1);
  FTypes[High(FTypes)] := AType;
end;

function TWasmModule.TypeCount: Integer;
begin
  Result := Length(FTypes);
end;

function TWasmModule.GetType(const AIndex: Integer): TWasmRecType;
begin
  CheckIndex(AIndex, Length(FTypes), 'type');
  Result := FTypes[AIndex];
end;

procedure TWasmModule.AddImport(const AImport: TWasmImport);
begin
  SetLength(FImports, Length(FImports) + 1);
  FImports[High(FImports)] := AImport;
end;

function TWasmModule.ImportCount: Integer;
begin
  Result := Length(FImports);
end;

function TWasmModule.GetImport(const AIndex: Integer): TWasmImport;
begin
  CheckIndex(AIndex, Length(FImports), 'import');
  Result := FImports[AIndex];
end;

procedure TWasmModule.AddFunctionTypeIndex(const ATypeIndex: UInt32);
begin
  SetLength(FFunctionTypeIndices, Length(FFunctionTypeIndices) + 1);
  FFunctionTypeIndices[High(FFunctionTypeIndices)] := ATypeIndex;
end;

function TWasmModule.FunctionTypeIndexCount: Integer;
begin
  Result := Length(FFunctionTypeIndices);
end;

function TWasmModule.GetFunctionTypeIndex(const AIndex: Integer): UInt32;
begin
  CheckIndex(AIndex, Length(FFunctionTypeIndices), 'function');
  Result := FFunctionTypeIndices[AIndex];
end;

procedure TWasmModule.AddTable(const ATable: TWasmTable);
begin
  SetLength(FTables, Length(FTables) + 1);
  FTables[High(FTables)] := ATable;
end;

function TWasmModule.TableCount: Integer;
begin
  Result := Length(FTables);
end;

function TWasmModule.GetTable(const AIndex: Integer): TWasmTable;
begin
  CheckIndex(AIndex, Length(FTables), 'table');
  Result := FTables[AIndex];
end;

procedure TWasmModule.AddMemory(const AMemory: TWasmMemType);
begin
  SetLength(FMemories, Length(FMemories) + 1);
  FMemories[High(FMemories)] := AMemory;
end;

function TWasmModule.MemoryCount: Integer;
begin
  Result := Length(FMemories);
end;

function TWasmModule.GetMemory(const AIndex: Integer): TWasmMemType;
begin
  CheckIndex(AIndex, Length(FMemories), 'memory');
  Result := FMemories[AIndex];
end;

procedure TWasmModule.AddGlobal(const AGlobal: TWasmGlobal);
begin
  SetLength(FGlobals, Length(FGlobals) + 1);
  FGlobals[High(FGlobals)] := AGlobal;
end;

function TWasmModule.GlobalCount: Integer;
begin
  Result := Length(FGlobals);
end;

function TWasmModule.GetGlobal(const AIndex: Integer): TWasmGlobal;
begin
  CheckIndex(AIndex, Length(FGlobals), 'global');
  Result := FGlobals[AIndex];
end;

procedure TWasmModule.AddExport(const AExport: TWasmExport);
begin
  SetLength(FExports, Length(FExports) + 1);
  FExports[High(FExports)] := AExport;
end;

function TWasmModule.ExportCount: Integer;
begin
  Result := Length(FExports);
end;

function TWasmModule.GetExport(const AIndex: Integer): TWasmExport;
begin
  CheckIndex(AIndex, Length(FExports), 'export');
  Result := FExports[AIndex];
end;

procedure TWasmModule.AddElement(const AElement: TWasmElemSegment);
begin
  SetLength(FElements, Length(FElements) + 1);
  FElements[High(FElements)] := AElement;
end;

function TWasmModule.ElementCount: Integer;
begin
  Result := Length(FElements);
end;

function TWasmModule.GetElement(const AIndex: Integer): TWasmElemSegment;
begin
  CheckIndex(AIndex, Length(FElements), 'element segment');
  Result := FElements[AIndex];
end;

procedure TWasmModule.AddCodeEntry(const AEntry: TWasmCodeEntry);
begin
  SetLength(FCodeEntries, Length(FCodeEntries) + 1);
  FCodeEntries[High(FCodeEntries)] := AEntry;
end;

function TWasmModule.CodeEntryCount: Integer;
begin
  Result := Length(FCodeEntries);
end;

function TWasmModule.GetCodeEntry(const AIndex: Integer): TWasmCodeEntry;
begin
  CheckIndex(AIndex, Length(FCodeEntries), 'code entry');
  Result := FCodeEntries[AIndex];
end;

procedure TWasmModule.AddDataSegment(const ASegment: TWasmDataSegment);
begin
  SetLength(FDataSegments, Length(FDataSegments) + 1);
  FDataSegments[High(FDataSegments)] := ASegment;
end;

function TWasmModule.DataSegmentCount: Integer;
begin
  Result := Length(FDataSegments);
end;

function TWasmModule.GetDataSegment(const AIndex: Integer): TWasmDataSegment;
begin
  CheckIndex(AIndex, Length(FDataSegments), 'data segment');
  Result := FDataSegments[AIndex];
end;

procedure TWasmModule.AddTag(const ATag: TWasmTagType);
begin
  SetLength(FTags, Length(FTags) + 1);
  FTags[High(FTags)] := ATag;
end;

function TWasmModule.TagCount: Integer;
begin
  Result := Length(FTags);
end;

function TWasmModule.GetTag(const AIndex: Integer): TWasmTagType;
begin
  CheckIndex(AIndex, Length(FTags), 'tag');
  Result := FTags[AIndex];
end;

{ --- derived counts ------------------------------------------------------ }

function TWasmModule.ImportCountOfKind(
  const AKind: TWasmExternKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FImports) do
    if FImports[I].Kind = AKind then
      Inc(Result);
end;

function TWasmModule.TotalFunctionCount: Integer;
begin
  Result := ImportCountOfKind(wxkFunc) + Length(FFunctionTypeIndices);
end;

function TWasmModule.TotalTableCount: Integer;
begin
  Result := ImportCountOfKind(wxkTable) + Length(FTables);
end;

function TWasmModule.TotalMemoryCount: Integer;
begin
  Result := ImportCountOfKind(wxkMem) + Length(FMemories);
end;

function TWasmModule.TotalGlobalCount: Integer;
begin
  Result := ImportCountOfKind(wxkGlobal) + Length(FGlobals);
end;

function TWasmModule.TotalTagCount: Integer;
begin
  Result := ImportCountOfKind(wxkTag) + Length(FTags);
end;

end.
