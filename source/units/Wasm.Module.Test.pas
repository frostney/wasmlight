{ Unit suite for Wasm.Module's decoded-content storage.

  The model is a passive bag the decoder fills, so what matters here is
  the storage contract: every entity list round-trips what was added,
  every indexed getter range-checks, Clear really resets everything, and
  the derived index-space counts include imports first — the numbering
  every index in the binary refers to. }
program Wasm.Module.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Module;

type
  TModuleTests = class(TTestSuite)
  private
    FModule: TWasmModule;

    function ImportOfKind(const AKind: TWasmExternKind;
      const AName: string): TWasmImport;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestTypeStorage;
    procedure TestImportStorage;
    procedure TestFunctionTypeIndexStorage;
    procedure TestTableStorage;
    procedure TestMemoryStorage;
    procedure TestGlobalStorage;
    procedure TestExportStorage;
    procedure TestElementStorage;
    procedure TestCodeEntryStorage;
    procedure TestDataSegmentStorage;
    procedure TestTagStorage;
    procedure TestOutOfRangeGetters;
    procedure TestClearResetsEverything;
    procedure TestImportCountOfKind;
    procedure TestTotalCountsIncludeImports;
    procedure TestStartAndDataCountDefaults;
    procedure TestMakeSpan;
  end;

procedure TModuleTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TModuleTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

function TModuleTests.ImportOfKind(const AKind: TWasmExternKind;
  const AName: string): TWasmImport;
begin
  { Every field is assigned so the inactive description arms hold known
    defaults rather than stack garbage. }
  Result.ModuleName := 'env';
  Result.Name := AName;
  Result.Kind := AKind;
  Result.FuncTypeIndex := 0;
  Result.Table := MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)), MakeLimits(watI32, 0));
  Result.Mem := MakeMemType(MakeLimits(watI32, 0));
  Result.Global := MakeGlobalType(False, MakeNumValueType(wntI32));
  Result.Tag := MakeTagType(0);
end;

procedure TModuleTests.TestTypeStorage;
var
  RecType: TWasmRecType;
  SubType: TWasmSubType;
  Func: TWasmFuncType;
begin
  SetLength(Func.Params, 1);
  Func.Params[0] := MakeNumValueType(wntI32);
  SetLength(Func.Results, 1);
  Func.Results[0] := MakeNumValueType(wntI64);
  SubType.IsFinal := True;
  SubType.SuperTypes := nil;
  SubType.Comp := MakeFuncCompType(Func);
  SetLength(RecType.SubTypes, 1);
  RecType.SubTypes[0] := SubType;

  FModule.AddType(RecType);
  FModule.AddType(RecType);

  Expect<Integer>(FModule.TypeCount).ToBe(2);
  Expect<Integer>(Length(FModule.Types[0].SubTypes)).ToBe(1);
  Expect<Boolean>(FModule.Types[0].SubTypes[0].IsFinal).ToBe(True);
  Expect<Boolean>(FModule.Types[1].SubTypes[0].Comp.Kind = wckFunc)
    .ToBe(True);
  Expect<string>(FModule.Types[1].SubTypes[0].Comp.Func.Params[0].Describe)
    .ToBe('i32');
  Expect<string>(FModule.Types[1].SubTypes[0].Comp.Func.Results[0].Describe)
    .ToBe('i64');
end;

procedure TModuleTests.TestImportStorage;
var
  Import: TWasmImport;
begin
  Import := ImportOfKind(wxkFunc, 'f');
  Import.FuncTypeIndex := 7;
  FModule.AddImport(Import);
  FModule.AddImport(ImportOfKind(wxkTable, 't'));

  Expect<Integer>(FModule.ImportCount).ToBe(2);
  Expect<string>(FModule.Imports[0].ModuleName).ToBe('env');
  Expect<string>(FModule.Imports[0].Name).ToBe('f');
  Expect<Boolean>(FModule.Imports[0].Kind = wxkFunc).ToBe(True);
  Expect<Int64>(Int64(FModule.Imports[0].FuncTypeIndex)).ToBe(7);
  Expect<Boolean>(FModule.Imports[1].Kind = wxkTable).ToBe(True);
  Expect<string>(FModule.Imports[1].Table.Describe).ToBe('0 funcref');
end;

procedure TModuleTests.TestFunctionTypeIndexStorage;
begin
  FModule.AddFunctionTypeIndex(0);
  FModule.AddFunctionTypeIndex(41);
  FModule.AddFunctionTypeIndex(High(UInt32));

  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(3);
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[0])).ToBe(0);
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[1])).ToBe(41);
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[2]))
    .ToBe(Int64(High(UInt32)));
end;

procedure TModuleTests.TestTableStorage;
var
  Table: TWasmTable;
begin
  Table.TableType := MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)),
    MakeLimitsWithMax(watI32, 1, 8));
  Table.HasInit := False;
  Table.Init := MakeSpan(0, 0);
  FModule.AddTable(Table);

  { The 3.0 table-with-init form carries an explicit init expression. }
  Table.HasInit := True;
  Table.Init := MakeSpan(100, 3);
  FModule.AddTable(Table);

  Expect<Integer>(FModule.TableCount).ToBe(2);
  Expect<string>(FModule.Tables[0].TableType.Describe).ToBe('1 8 funcref');
  Expect<Boolean>(FModule.Tables[0].HasInit).ToBe(False);
  Expect<Boolean>(FModule.Tables[1].HasInit).ToBe(True);
  Expect<Integer>(Integer(FModule.Tables[1].Init.Offset)).ToBe(100);
  Expect<Integer>(Integer(FModule.Tables[1].Init.Size)).ToBe(3);
end;

procedure TModuleTests.TestMemoryStorage;
begin
  FModule.AddMemory(MakeMemType(MakeLimitsWithMax(watI32, 1, 2)));
  FModule.AddMemory(MakeMemType(MakeLimits(watI64, 0)));

  Expect<Integer>(FModule.MemoryCount).ToBe(2);
  Expect<string>(FModule.Memories[0].Describe).ToBe('1 2');
  Expect<string>(FModule.Memories[1].Describe).ToBe('i64 0');
end;

procedure TModuleTests.TestGlobalStorage;
var
  Global: TWasmGlobal;
begin
  Global.GlobalType := MakeGlobalType(True, MakeNumValueType(wntI64));
  Global.Init := MakeSpan(20, 5);
  FModule.AddGlobal(Global);

  Expect<Integer>(FModule.GlobalCount).ToBe(1);
  Expect<string>(FModule.Globals[0].GlobalType.Describe).ToBe('(mut i64)');
  Expect<Integer>(Integer(FModule.Globals[0].Init.Offset)).ToBe(20);
  Expect<Integer>(Integer(FModule.Globals[0].Init.Size)).ToBe(5);
end;

procedure TModuleTests.TestExportStorage;
var
  ExportEntry: TWasmExport;
begin
  ExportEntry.Name := 'main';
  ExportEntry.Kind := wxkFunc;
  ExportEntry.Index := 4;
  FModule.AddExport(ExportEntry);

  ExportEntry.Name := 'memory';
  ExportEntry.Kind := wxkMem;
  ExportEntry.Index := 0;
  FModule.AddExport(ExportEntry);

  Expect<Integer>(FModule.ExportCount).ToBe(2);
  Expect<string>(FModule.&Exports[0].Name).ToBe('main');
  Expect<Boolean>(FModule.&Exports[0].Kind = wxkFunc).ToBe(True);
  Expect<Int64>(Int64(FModule.&Exports[0].Index)).ToBe(4);
  Expect<string>(FModule.&Exports[1].Name).ToBe('memory');
  Expect<Boolean>(FModule.&Exports[1].Kind = wxkMem).ToBe(True);
end;

procedure TModuleTests.TestElementStorage;
var
  Segment: TWasmElemSegment;
begin
  { Active, function-index form. }
  Segment.Mode := wemActive;
  Segment.TableIndex := 0;
  Segment.Offset := MakeSpan(10, 3);
  Segment.RefType := MakeRefType(True, MakeAbsHeapType(wahFunc));
  Segment.UsesExprs := False;
  SetLength(Segment.FuncIndices, 3);
  Segment.FuncIndices[0] := 1;
  Segment.FuncIndices[1] := 2;
  Segment.FuncIndices[2] := 3;
  Segment.InitExprs := nil;
  FModule.AddElement(Segment);

  { Passive, expression form. }
  Segment.Mode := wemPassive;
  Segment.Offset := MakeSpan(0, 0);
  Segment.RefType := MakeRefType(True, MakeAbsHeapType(wahExtern));
  Segment.UsesExprs := True;
  Segment.FuncIndices := nil;
  SetLength(Segment.InitExprs, 2);
  Segment.InitExprs[0] := MakeSpan(30, 2);
  Segment.InitExprs[1] := MakeSpan(32, 2);
  FModule.AddElement(Segment);

  Expect<Integer>(FModule.ElementCount).ToBe(2);
  Expect<Boolean>(FModule.Elements[0].Mode = wemActive).ToBe(True);
  Expect<Boolean>(FModule.Elements[0].UsesExprs).ToBe(False);
  Expect<Integer>(Length(FModule.Elements[0].FuncIndices)).ToBe(3);
  Expect<Int64>(Int64(FModule.Elements[0].FuncIndices[2])).ToBe(3);
  Expect<Integer>(Integer(FModule.Elements[0].Offset.Offset)).ToBe(10);
  Expect<Boolean>(FModule.Elements[1].Mode = wemPassive).ToBe(True);
  Expect<Boolean>(FModule.Elements[1].UsesExprs).ToBe(True);
  Expect<Integer>(Length(FModule.Elements[1].InitExprs)).ToBe(2);
  Expect<Integer>(Integer(FModule.Elements[1].InitExprs[1].Offset)).ToBe(32);
  Expect<string>(FModule.Elements[1].RefType.Describe).ToBe('externref');
end;

procedure TModuleTests.TestCodeEntryStorage;
var
  Entry: TWasmCodeEntry;
begin
  SetLength(Entry.Locals, 2);
  Entry.Locals[0].Count := 2;
  Entry.Locals[0].ValueType := MakeNumValueType(wntI32);
  Entry.Locals[1].Count := 1;
  Entry.Locals[1].ValueType := MakeVecValueType;
  Entry.Body := MakeSpan(64, 12);
  FModule.AddCodeEntry(Entry);

  Expect<Integer>(FModule.CodeEntryCount).ToBe(1);
  Expect<Integer>(Length(FModule.CodeEntries[0].Locals)).ToBe(2);
  Expect<Int64>(Int64(FModule.CodeEntries[0].Locals[0].Count)).ToBe(2);
  Expect<string>(FModule.CodeEntries[0].Locals[1].ValueType.Describe)
    .ToBe('v128');
  Expect<Integer>(Integer(FModule.CodeEntries[0].Body.Offset)).ToBe(64);
  Expect<Integer>(Integer(FModule.CodeEntries[0].Body.Size)).ToBe(12);
end;

procedure TModuleTests.TestDataSegmentStorage;
var
  Segment: TWasmDataSegment;
begin
  Segment.Mode := wdmActive;
  Segment.MemIndex := 0;
  Segment.Offset := MakeSpan(40, 3);
  Segment.Bytes := MakeSpan(43, 16);
  FModule.AddDataSegment(Segment);

  Segment.Mode := wdmPassive;
  Segment.MemIndex := 0;
  Segment.Offset := MakeSpan(0, 0);
  Segment.Bytes := MakeSpan(60, 4);
  FModule.AddDataSegment(Segment);

  Expect<Integer>(FModule.DataSegmentCount).ToBe(2);
  Expect<Boolean>(FModule.DataSegments[0].Mode = wdmActive).ToBe(True);
  Expect<Integer>(Integer(FModule.DataSegments[0].Offset.Offset)).ToBe(40);
  Expect<Integer>(Integer(FModule.DataSegments[0].Bytes.Size)).ToBe(16);
  Expect<Boolean>(FModule.DataSegments[1].Mode = wdmPassive).ToBe(True);
  Expect<Integer>(Integer(FModule.DataSegments[1].Bytes.Offset)).ToBe(60);
end;

procedure TModuleTests.TestTagStorage;
begin
  FModule.AddTag(MakeTagType(2));
  FModule.AddTag(MakeTagType(5));

  Expect<Integer>(FModule.TagCount).ToBe(2);
  Expect<Int64>(Int64(FModule.Tags[0].TypeIndex)).ToBe(2);
  Expect<Int64>(Int64(FModule.Tags[1].TypeIndex)).ToBe(5);
end;

procedure TModuleTests.TestOutOfRangeGetters;
var
  Raised: Integer;
  Section: TWasmSectionInfo;
  RecType: TWasmRecType;
  Import: TWasmImport;
  TypeIndex: UInt32;
  Table: TWasmTable;
  Mem: TWasmMemType;
  Global: TWasmGlobal;
  ExportEntry: TWasmExport;
  Element: TWasmElemSegment;
  Entry: TWasmCodeEntry;
  Data: TWasmDataSegment;
  Tag: TWasmTagType;
begin
  { Every indexed getter must raise on an empty module rather than read
    out of bounds. The assertion counts the raises after the fact — a
    Fail() inside a try would be swallowed, and FPC will not parse a
    generic call as the lone statement of an `on ... do`. }
  Raised := 0;

  try
    Section := FModule.Sections[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    RecType := FModule.Types[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Import := FModule.Imports[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    TypeIndex := FModule.FunctionTypeIndices[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Table := FModule.Tables[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Mem := FModule.Memories[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Global := FModule.Globals[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    ExportEntry := FModule.&Exports[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Element := FModule.Elements[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Entry := FModule.CodeEntries[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Data := FModule.DataSegments[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;
  try
    Tag := FModule.Tags[0];
  except
    on E: EWasmError do
      Inc(Raised);
  end;

  { Negative indices are out of range too, not a wraparound. }
  FModule.AddTag(MakeTagType(1));
  try
    Tag := FModule.Tags[-1];
  except
    on E: EWasmError do
      Inc(Raised);
  end;

  Expect<Integer>(Raised).ToBe(13);
end;

procedure TModuleTests.TestClearResetsEverything;
var
  Section: TWasmSectionInfo;
begin
  Section.Id := Ord(wsType);
  Section.Name := '';
  Section.BodyOffset := 8;
  Section.BodySize := 4;
  FModule.AddSection(Section);
  FModule.Version := 1;
  FModule.Size := 64;

  FModule.AddType(Default(TWasmRecType));
  FModule.AddImport(ImportOfKind(wxkFunc, 'f'));
  FModule.AddFunctionTypeIndex(0);
  FModule.AddTable(Default(TWasmTable));
  FModule.AddMemory(MakeMemType(MakeLimits(watI32, 0)));
  FModule.AddGlobal(Default(TWasmGlobal));
  FModule.AddExport(Default(TWasmExport));
  FModule.AddElement(Default(TWasmElemSegment));
  FModule.AddCodeEntry(Default(TWasmCodeEntry));
  FModule.AddDataSegment(Default(TWasmDataSegment));
  FModule.AddTag(MakeTagType(0));
  FModule.HasStart := True;
  FModule.StartFuncIndex := 3;
  FModule.HasDataCount := True;
  FModule.DataCount := 1;

  FModule.Clear;

  Expect<Integer>(FModule.SectionCount).ToBe(0);
  Expect<Int64>(Int64(FModule.Version)).ToBe(0);
  Expect<Integer>(Integer(FModule.Size)).ToBe(0);
  Expect<Integer>(FModule.TypeCount).ToBe(0);
  Expect<Integer>(FModule.ImportCount).ToBe(0);
  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(0);
  Expect<Integer>(FModule.TableCount).ToBe(0);
  Expect<Integer>(FModule.MemoryCount).ToBe(0);
  Expect<Integer>(FModule.GlobalCount).ToBe(0);
  Expect<Integer>(FModule.ExportCount).ToBe(0);
  Expect<Integer>(FModule.ElementCount).ToBe(0);
  Expect<Integer>(FModule.CodeEntryCount).ToBe(0);
  Expect<Integer>(FModule.DataSegmentCount).ToBe(0);
  Expect<Integer>(FModule.TagCount).ToBe(0);
  Expect<Boolean>(FModule.HasStart).ToBe(False);
  Expect<Int64>(Int64(FModule.StartFuncIndex)).ToBe(0);
  Expect<Boolean>(FModule.HasDataCount).ToBe(False);
  Expect<Int64>(Int64(FModule.DataCount)).ToBe(0);
end;

procedure TModuleTests.TestImportCountOfKind;
begin
  Expect<Integer>(FModule.ImportCountOfKind(wxkFunc)).ToBe(0);

  FModule.AddImport(ImportOfKind(wxkFunc, 'f1'));
  FModule.AddImport(ImportOfKind(wxkFunc, 'f2'));
  FModule.AddImport(ImportOfKind(wxkTable, 't'));
  FModule.AddImport(ImportOfKind(wxkMem, 'm'));
  FModule.AddImport(ImportOfKind(wxkGlobal, 'g'));
  FModule.AddImport(ImportOfKind(wxkTag, 'e'));

  Expect<Integer>(FModule.ImportCountOfKind(wxkFunc)).ToBe(2);
  Expect<Integer>(FModule.ImportCountOfKind(wxkTable)).ToBe(1);
  Expect<Integer>(FModule.ImportCountOfKind(wxkMem)).ToBe(1);
  Expect<Integer>(FModule.ImportCountOfKind(wxkGlobal)).ToBe(1);
  Expect<Integer>(FModule.ImportCountOfKind(wxkTag)).ToBe(1);
end;

procedure TModuleTests.TestTotalCountsIncludeImports;
begin
  { Index spaces number imports first, then the module's own definitions.
    The totals must therefore be import count + definition count. }
  FModule.AddImport(ImportOfKind(wxkFunc, 'f1'));
  FModule.AddImport(ImportOfKind(wxkFunc, 'f2'));
  FModule.AddImport(ImportOfKind(wxkTable, 't'));
  FModule.AddImport(ImportOfKind(wxkGlobal, 'g'));
  FModule.AddImport(ImportOfKind(wxkTag, 'e'));

  FModule.AddFunctionTypeIndex(0);
  FModule.AddFunctionTypeIndex(0);
  FModule.AddFunctionTypeIndex(0);
  FModule.AddTable(Default(TWasmTable));
  FModule.AddMemory(MakeMemType(MakeLimits(watI32, 1)));
  FModule.AddMemory(MakeMemType(MakeLimits(watI32, 1)));
  FModule.AddGlobal(Default(TWasmGlobal));
  FModule.AddTag(MakeTagType(0));
  FModule.AddTag(MakeTagType(0));

  Expect<Integer>(FModule.TotalFunctionCount).ToBe(5);  { 2 + 3 }
  Expect<Integer>(FModule.TotalTableCount).ToBe(2);     { 1 + 1 }
  Expect<Integer>(FModule.TotalMemoryCount).ToBe(2);    { 0 + 2 }
  Expect<Integer>(FModule.TotalGlobalCount).ToBe(2);    { 1 + 1 }
  Expect<Integer>(FModule.TotalTagCount).ToBe(3);       { 1 + 2 }
end;

procedure TModuleTests.TestStartAndDataCountDefaults;
begin
  { A fresh module declares neither section; the decoder sets the flags. }
  Expect<Boolean>(FModule.HasStart).ToBe(False);
  Expect<Boolean>(FModule.HasDataCount).ToBe(False);

  FModule.HasStart := True;
  FModule.StartFuncIndex := 9;
  FModule.HasDataCount := True;
  FModule.DataCount := 2;

  Expect<Boolean>(FModule.HasStart).ToBe(True);
  Expect<Int64>(Int64(FModule.StartFuncIndex)).ToBe(9);
  Expect<Boolean>(FModule.HasDataCount).ToBe(True);
  Expect<Int64>(Int64(FModule.DataCount)).ToBe(2);
end;

procedure TModuleTests.TestMakeSpan;
var
  Span: TWasmSpan;
begin
  Span := MakeSpan(5, 9);
  Expect<Integer>(Integer(Span.Offset)).ToBe(5);
  Expect<Integer>(Integer(Span.Size)).ToBe(9);
end;

procedure TModuleTests.SetupTests;
begin
  Test('type storage round-trips', TestTypeStorage);
  Test('import storage round-trips', TestImportStorage);
  Test('function type index storage round-trips',
    TestFunctionTypeIndexStorage);
  Test('table storage round-trips', TestTableStorage);
  Test('memory storage round-trips', TestMemoryStorage);
  Test('global storage round-trips', TestGlobalStorage);
  Test('export storage round-trips', TestExportStorage);
  Test('element segment storage round-trips', TestElementStorage);
  Test('code entry storage round-trips', TestCodeEntryStorage);
  Test('data segment storage round-trips', TestDataSegmentStorage);
  Test('tag storage round-trips', TestTagStorage);
  Test('indexed getters range-check', TestOutOfRangeGetters);
  Test('Clear resets everything', TestClearResetsEverything);
  Test('import count by kind', TestImportCountOfKind);
  Test('index-space totals include imports', TestTotalCountsIncludeImports);
  Test('start and data count default to absent',
    TestStartAndDataCountDefaults);
  Test('MakeSpan constructor', TestMakeSpan);
end;

begin
  TestRunnerProgram.AddSuite(TModuleTests.Create('Wasm.Module'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
