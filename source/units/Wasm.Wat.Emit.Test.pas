{ Unit suite for Wasm.Wat.Emit, the binary emitter — proven DIFFERENTIALLY
  against the shipped decoder, with no grammar in the loop.

  The emitter is the decode layer run backwards, so the decode layer is
  its oracle: emit bytes, read them back, compare. Three levels of that:

    - LEB128 round-trips through Wasm.Binary's reader, across the width
      boundaries (u32/u64/s32/s64/s33, including -2^63, 2^64-1, and the
      s33 extremes), plus explicit length assertions proving the encodings
      are the minimal ones the reader demands — an overlong LEB is
      `integer representation too long` to that same reader.

    - Type/limits/composite encoders round-tripped through
      Wasm.Decoder.Common's and Wasm.Decoder.Types' readers: every value
      type form, both reference forms, all four limits flag combinations,
      and a rec/sub/struct/array/packed type section that mirrors the
      decoder's own type suite but is built by the emitter.

    - A whole hand-built module — types, function, memory, global, export,
      code, data, data count — added to the module emitter in DELIBERATELY
      scrambled field order, then run through DecodeModule. That the model
      comes back correct proves section ordering (the emitter must emit in
      the prescribed order, not insertion order), size backpatching, and
      every encoder at once. }
program Wasm.Wat.Emit.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Decoder.Common,
  Wasm.Decoder.Types,
  Wasm.Module,
  Wasm.Wat.Emit;

type
  TWatEmitTests = class(TTestSuite)
  private
    { Buffers the readers/decoder borrow must outlive them, so they are
      suite fields rather than locals. }
    FBuffer: TWasmBytes;
    FModule: TWasmModule;

    { --- small builders ------------------------------------------------- }
    function I32: TWasmValueType;
    function I64: TWasmValueType;
    function F32: TWasmValueType;
    function FuncRef: TWasmValueType;
    function RefTo(const ANullable: Boolean;
      const AIndex: UInt32): TWasmValueType;

    function EmitValType(const AType: TWasmValueType): TWasmBytes;
    function ReadBackValType(const ABytes: TWasmBytes): string;

    procedure WriteName(var AOut: TWasmWriter; const AName: string);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestUnsignedLebRoundTrip;
    procedure TestSignedLebRoundTrip;
    procedure TestS33RoundTrip;
    procedure TestLebEncodingsAreMinimal;
    procedure TestValueTypeEncoders;
    procedure TestLimitsEncoders;
    procedure TestRefAndGlobalAndTableEncoders;
    procedure TestCompositeTypeSectionRoundTrip;
    procedure TestPreambleAndEmptyModule;
    procedure TestFullModuleRoundTrip;
    procedure TestSectionOrderIsPrescribedNotInsertion;
  end;

{ --- builders ----------------------------------------------------------- }

function TWatEmitTests.I32: TWasmValueType;
begin
  Result := MakeNumValueType(wntI32);
end;

function TWatEmitTests.I64: TWasmValueType;
begin
  Result := MakeNumValueType(wntI64);
end;

function TWatEmitTests.F32: TWasmValueType;
begin
  Result := MakeNumValueType(wntF32);
end;

function TWatEmitTests.FuncRef: TWasmValueType;
begin
  Result := MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahFunc)));
end;

function TWatEmitTests.RefTo(const ANullable: Boolean;
  const AIndex: UInt32): TWasmValueType;
begin
  Result := MakeRefValueType(
    MakeRefType(ANullable, MakeConcreteHeapType(AIndex)));
end;

function TWatEmitTests.EmitValType(const AType: TWasmValueType): TWasmBytes;
var
  W: TWasmWriter;
begin
  W.Init;
  W.WriteValueType(AType);
  Result := W.ToBytes;
end;

function TWatEmitTests.ReadBackValType(const ABytes: TWasmBytes): string;
var
  R: TWasmReader;
begin
  { The reader borrows ABytes; the caller keeps it alive for the call. }
  R.InitFromBytes(ABytes);
  Result := ReadValueType(R).Describe;
end;

procedure TWatEmitTests.WriteName(var AOut: TWasmWriter; const AName: string);
var
  I: Integer;
begin
  AOut.WriteU32(UInt32(Length(AName)));
  for I := 1 to Length(AName) do
    AOut.WriteByte(Ord(AName[I]));
end;

procedure TWatEmitTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
end;

procedure TWatEmitTests.AfterEach;
begin
  FreeAndNil(FModule);
end;

{ --- LEB128 ------------------------------------------------------------- }

procedure TWatEmitTests.TestUnsignedLebRoundTrip;
var
  W: TWasmWriter;
  R: TWasmReader;
  Bytes: TWasmBytes;

  procedure Roundtrip32(const AValue: UInt32);
  begin
    W.Init;
    W.WriteU32(AValue);
    Bytes := W.ToBytes;
    R.InitFromBytes(Bytes);
    Expect<Int64>(Int64(R.ReadU32)).ToBe(Int64(AValue));
  end;

  procedure Roundtrip64(const AValue: UInt64);
  begin
    W.Init;
    W.WriteU64(AValue);
    Bytes := W.ToBytes;
    R.InitFromBytes(Bytes);
    { Both sides carry the same bit pattern, so an Int64 view compares
      equal even where the value's top bit is set. }
    Expect<Int64>(Int64(R.ReadU64)).ToBe(Int64(AValue));
  end;

begin
  Roundtrip32(0);
  Roundtrip32(1);
  Roundtrip32(127);
  Roundtrip32(128);
  Roundtrip32(624485);
  Roundtrip32(High(UInt32));

  Roundtrip64(0);
  Roundtrip64(128);
  Roundtrip64(UInt64($100000000));
  Roundtrip64(High(UInt64));
end;

procedure TWatEmitTests.TestSignedLebRoundTrip;
var
  W: TWasmWriter;
  R: TWasmReader;
  Bytes: TWasmBytes;

  procedure Roundtrip32(const AValue: Int32);
  begin
    W.Init;
    W.WriteS32(AValue);
    Bytes := W.ToBytes;
    R.InitFromBytes(Bytes);
    Expect<Int64>(Int64(R.ReadI32)).ToBe(Int64(AValue));
  end;

  procedure Roundtrip64(const AValue: Int64);
  begin
    W.Init;
    W.WriteS64(AValue);
    Bytes := W.ToBytes;
    R.InitFromBytes(Bytes);
    Expect<Int64>(R.ReadI64).ToBe(AValue);
  end;

begin
  Roundtrip32(0);
  Roundtrip32(-1);
  Roundtrip32(63);
  Roundtrip32(64);
  Roundtrip32(-64);
  Roundtrip32(-65);
  Roundtrip32(High(Int32));
  Roundtrip32(Low(Int32));

  Roundtrip64(0);
  Roundtrip64(-1);
  Roundtrip64(High(Int64));
  { -2^63: the boundary the reader's own sign-extension note is about. }
  Roundtrip64(Low(Int64));
end;

procedure TWatEmitTests.TestS33RoundTrip;
var
  W: TWasmWriter;
  R: TWasmReader;
  Bytes: TWasmBytes;

  procedure Roundtrip(const AValue: Int64);
  begin
    W.Init;
    W.WriteS33(AValue);
    Bytes := W.ToBytes;
    R.InitFromBytes(Bytes);
    Expect<Int64>(R.ReadS33).ToBe(AValue);
  end;

begin
  Roundtrip(0);
  Roundtrip(-1);
  Roundtrip(1);
  { A concrete type index that sets bit 6 needs a trailing zero byte to
    stay positive — the case a naive writer gets wrong. }
  Roundtrip(100);
  { The s33 extremes: max positive is 2^32-1 (every u32 index fits), min
    is -2^32. }
  Roundtrip(Int64($FFFFFFFF));
  Roundtrip(-Int64($100000000));
end;

procedure TWatEmitTests.TestLebEncodingsAreMinimal;
var
  W: TWasmWriter;
begin
  { The decoder rejects overlong LEBs as `integer representation too
    long`, so the writer must emit the shortest form. Length is the
    observable proof. }
  W.Init; W.WriteU32(0);
  Expect<Int64>(Int64(W.Count)).ToBe(1);

  W.Init; W.WriteU32(127);
  Expect<Int64>(Int64(W.Count)).ToBe(1);

  W.Init; W.WriteU32(128);
  Expect<Int64>(Int64(W.Count)).ToBe(2);

  W.Init; W.WriteU32(High(UInt32));
  Expect<Int64>(Int64(W.Count)).ToBe(5);

  W.Init; W.WriteU64(High(UInt64));
  Expect<Int64>(Int64(W.Count)).ToBe(10);

  W.Init; W.WriteS32(0);
  Expect<Int64>(Int64(W.Count)).ToBe(1);

  W.Init; W.WriteS32(-1);
  Expect<Int64>(Int64(W.Count)).ToBe(1);

  { -64 fits a single signed 7-bit byte; -65 needs a second. }
  W.Init; W.WriteS32(-64);
  Expect<Int64>(Int64(W.Count)).ToBe(1);
  W.Init; W.WriteS32(-65);
  Expect<Int64>(Int64(W.Count)).ToBe(2);
end;

{ --- type encoders ------------------------------------------------------ }

procedure TWatEmitTests.TestValueTypeEncoders;
begin
  { Every self-contained value type form, emitted then read back and
    described. The number types and v128 are signed small negatives, not
    raw bytes; the short reference forms have conventional spellings. }
  FBuffer := EmitValType(I32);
  Expect<string>(ReadBackValType(FBuffer)).ToBe('i32');
  FBuffer := EmitValType(I64);
  Expect<string>(ReadBackValType(FBuffer)).ToBe('i64');
  FBuffer := EmitValType(F32);
  Expect<string>(ReadBackValType(FBuffer)).ToBe('f32');
  FBuffer := EmitValType(MakeNumValueType(wntF64));
  Expect<string>(ReadBackValType(FBuffer)).ToBe('f64');
  FBuffer := EmitValType(MakeVecValueType);
  Expect<string>(ReadBackValType(FBuffer)).ToBe('v128');
  FBuffer := EmitValType(FuncRef);
  Expect<string>(ReadBackValType(FBuffer)).ToBe('funcref');
  FBuffer := EmitValType(
    MakeRefValueType(MakeRefType(True, MakeAbsHeapType(wahExtern))));
  Expect<string>(ReadBackValType(FBuffer)).ToBe('externref');
  { Long forms: a nullable concrete ref and a non-null concrete ref. }
  FBuffer := EmitValType(RefTo(True, 5));
  Expect<string>(ReadBackValType(FBuffer)).ToBe('(ref null 5)');
  FBuffer := EmitValType(RefTo(False, 3));
  Expect<string>(ReadBackValType(FBuffer)).ToBe('(ref 3)');
  { A non-null abstract ref also takes the long form. }
  FBuffer := EmitValType(
    MakeRefValueType(MakeRefType(False, MakeAbsHeapType(wahAny))));
  Expect<string>(ReadBackValType(FBuffer)).ToBe('(ref any)');
end;

procedure TWatEmitTests.TestLimitsEncoders;
var
  W: TWasmWriter;
  R: TWasmReader;
  L: TWasmLimits;

  procedure EmitLimits(const ALimits: TWasmLimits);
  begin
    W.Init;
    W.WriteLimits(ALimits);
    FBuffer := W.ToBytes;
    R.InitFromBytes(FBuffer);
    L := ReadLimits(R);
  end;

begin
  { i32, no max. }
  EmitLimits(MakeLimits(watI32, 1));
  Expect<Integer>(Ord(L.AddrType)).ToBe(Ord(watI32));
  Expect<Boolean>(L.HasMax).ToBe(False);
  Expect<Int64>(Int64(L.Min)).ToBe(1);

  { i32, with max. }
  EmitLimits(MakeLimitsWithMax(watI32, 1, 2));
  Expect<Boolean>(L.HasMax).ToBe(True);
  Expect<Int64>(Int64(L.Min)).ToBe(1);
  Expect<Int64>(Int64(L.Max)).ToBe(2);

  { i64, no max — exercises the address-type flag bit. }
  EmitLimits(MakeLimits(watI64, 100));
  Expect<Integer>(Ord(L.AddrType)).ToBe(Ord(watI64));
  Expect<Boolean>(L.HasMax).ToBe(False);
  Expect<Int64>(Int64(L.Min)).ToBe(100);

  { i64, with a large max that exceeds 32 bits — proves min/max stay u64. }
  EmitLimits(MakeLimitsWithMax(watI64, 0, UInt64($100000000)));
  Expect<Integer>(Ord(L.AddrType)).ToBe(Ord(watI64));
  Expect<Boolean>(L.HasMax).ToBe(True);
  Expect<Int64>(Int64(L.Max)).ToBe(Int64($100000000));
end;

procedure TWatEmitTests.TestRefAndGlobalAndTableEncoders;
var
  W: TWasmWriter;
  R: TWasmReader;
  G: TWasmGlobalType;
  T: TWasmTableType;
  M: TWasmMemType;
  Tag: TWasmTagType;
begin
  { globaltype: value type then mut byte. }
  W.Init;
  W.WriteGlobalType(MakeGlobalType(True, I32));
  FBuffer := W.ToBytes;
  R.InitFromBytes(FBuffer);
  G := ReadGlobalType(R);
  Expect<Boolean>(G.Mut).ToBe(True);
  Expect<string>(G.ValueType.Describe).ToBe('i32');

  W.Init;
  W.WriteGlobalType(MakeGlobalType(False, F32));
  FBuffer := W.ToBytes;
  R.InitFromBytes(FBuffer);
  G := ReadGlobalType(R);
  Expect<Boolean>(G.Mut).ToBe(False);

  { tabletype: reftype then limits. }
  W.Init;
  W.WriteTableType(MakeTableType(
    MakeRefType(True, MakeAbsHeapType(wahFunc)),
    MakeLimitsWithMax(watI32, 2, 2)));
  FBuffer := W.ToBytes;
  R.InitFromBytes(FBuffer);
  T := ReadTableType(R);
  Expect<string>(T.RefType.Describe).ToBe('funcref');
  Expect<Int64>(Int64(T.Limits.Min)).ToBe(2);
  Expect<Int64>(Int64(T.Limits.Max)).ToBe(2);

  { memtype. }
  W.Init;
  W.WriteMemType(MakeMemType(MakeLimits(watI32, 3)));
  FBuffer := W.ToBytes;
  R.InitFromBytes(FBuffer);
  M := ReadMemType(R);
  Expect<Int64>(Int64(M.Limits.Min)).ToBe(3);

  { tagtype: attribute byte then function type index. }
  W.Init;
  W.WriteTagType(MakeTagType(7));
  FBuffer := W.ToBytes;
  R.InitFromBytes(FBuffer);
  Tag := ReadTagType(R);
  Expect<Int64>(Int64(Tag.TypeIndex)).ToBe(7);
end;

procedure TWatEmitTests.TestCompositeTypeSectionRoundTrip;
var
  W: TWasmWriter;
  R: TWasmReader;
  RecFunc, RecStruct, RecArray, RecGroup: TWasmRecType;
  Func: TWasmFuncType;
  Struct: TWasmStructType;
  Arr: TWasmArrayType;
  DecStruct: TWasmStructType;
  Group: TWasmRecType;
begin
  { (func (param i32 i64) (result f32)) — a bare final subtype. }
  SetLength(Func.Params, 2);
  Func.Params[0] := I32;
  Func.Params[1] := I64;
  SetLength(Func.Results, 1);
  Func.Results[0] := F32;
  SetLength(RecFunc.SubTypes, 1);
  RecFunc.SubTypes[0].IsFinal := True;
  RecFunc.SubTypes[0].SuperTypes := nil;
  RecFunc.SubTypes[0].Comp := MakeFuncCompType(Func);

  { (struct (field (mut i8)) (field i16) (field i32) (field (mut funcref))). }
  SetLength(Struct.Fields, 4);
  Struct.Fields[0] := MakeFieldType(True, MakePackedStorageType(wpkI8));
  Struct.Fields[1] := MakeFieldType(False, MakePackedStorageType(wpkI16));
  Struct.Fields[2] := MakeFieldType(False, MakeValueStorageType(I32));
  Struct.Fields[3] := MakeFieldType(True, MakeValueStorageType(FuncRef));
  SetLength(RecStruct.SubTypes, 1);
  RecStruct.SubTypes[0].IsFinal := True;
  RecStruct.SubTypes[0].SuperTypes := nil;
  RecStruct.SubTypes[0].Comp := MakeStructCompType(Struct);

  { (array (mut i8)). }
  Arr.Elem := MakeFieldType(True, MakePackedStorageType(wpkI8));
  SetLength(RecArray.SubTypes, 1);
  RecArray.SubTypes[0].IsFinal := True;
  RecArray.SubTypes[0].SuperTypes := nil;
  RecArray.SubTypes[0].Comp := MakeArrayCompType(Arr);

  { (rec (type (sub (struct (field (ref null 1)))))
         (type (sub final 0 (struct (field (mut (ref null 0))))))) — a
    two-member group, so it must be emitted with the explicit $4E marker. }
  SetLength(RecGroup.SubTypes, 2);
  RecGroup.SubTypes[0].IsFinal := False;
  RecGroup.SubTypes[0].SuperTypes := nil;
  SetLength(Struct.Fields, 1);
  Struct.Fields[0] := MakeFieldType(False, MakeValueStorageType(RefTo(True, 1)));
  RecGroup.SubTypes[0].Comp := MakeStructCompType(Struct);
  RecGroup.SubTypes[1].IsFinal := True;
  SetLength(RecGroup.SubTypes[1].SuperTypes, 1);
  RecGroup.SubTypes[1].SuperTypes[0] := 0;
  SetLength(Struct.Fields, 1);
  Struct.Fields[0] := MakeFieldType(True, MakeValueStorageType(RefTo(True, 0)));
  RecGroup.SubTypes[1].Comp := MakeStructCompType(Struct);

  { Type section body: vec(rectype) with the four entries. }
  W.Init;
  W.WriteU32(4);
  W.WriteType(RecFunc);
  W.WriteType(RecStruct);
  W.WriteType(RecArray);
  W.WriteType(RecGroup);
  FBuffer := W.ToBytes;

  R.InitFromBytes(FBuffer);
  DecodeTypeSection(R, 0, FModule);

  Expect<Integer>(FModule.TypeCount).ToBe(4);

  { Entry 0: func. }
  Expect<Boolean>(FModule.Types[0].SubTypes[0].Comp.Kind = wckFunc).ToBe(True);
  Expect<Integer>(Length(FModule.Types[0].SubTypes[0].Comp.Func.Params)).ToBe(2);
  Expect<string>(FModule.Types[0].SubTypes[0].Comp.Func.Params[1].Describe)
    .ToBe('i64');
  Expect<string>(FModule.Types[0].SubTypes[0].Comp.Func.Results[0].Describe)
    .ToBe('f32');

  { Entry 1: struct with mixed packed/value, mutable/immutable fields. }
  Expect<Boolean>(FModule.Types[1].SubTypes[0].Comp.Kind = wckStruct)
    .ToBe(True);
  DecStruct := FModule.Types[1].SubTypes[0].Comp.Struct;
  Expect<Integer>(Length(DecStruct.Fields)).ToBe(4);
  Expect<string>(DecStruct.Fields[0].Describe).ToBe('(mut i8)');
  Expect<string>(DecStruct.Fields[1].Describe).ToBe('i16');
  Expect<string>(DecStruct.Fields[2].Describe).ToBe('i32');
  Expect<string>(DecStruct.Fields[3].Describe).ToBe('(mut funcref)');

  { Entry 2: array. }
  Expect<Boolean>(FModule.Types[2].SubTypes[0].Comp.Kind = wckArray).ToBe(True);
  Expect<string>(FModule.Types[2].SubTypes[0].Comp.Arr.Elem.Describe)
    .ToBe('(mut i8)');

  { Entry 3: the explicit rec group of two, with sub / sub-final. }
  Group := FModule.Types[3];
  Expect<Integer>(Length(Group.SubTypes)).ToBe(2);
  Expect<Boolean>(Group.SubTypes[0].IsFinal).ToBe(False);
  Expect<Integer>(Length(Group.SubTypes[0].SuperTypes)).ToBe(0);
  Expect<string>(Group.SubTypes[0].Comp.Struct.Fields[0].Describe)
    .ToBe('(ref null 1)');
  Expect<Boolean>(Group.SubTypes[1].IsFinal).ToBe(True);
  Expect<Integer>(Length(Group.SubTypes[1].SuperTypes)).ToBe(1);
  Expect<Int64>(Int64(Group.SubTypes[1].SuperTypes[0])).ToBe(0);
  Expect<string>(Group.SubTypes[1].Comp.Struct.Fields[0].Describe)
    .ToBe('(mut (ref null 0))');
end;

{ --- whole-module differential ------------------------------------------ }

procedure TWatEmitTests.TestPreambleAndEmptyModule;
var
  Emitter: TWasmModuleEmitter;
begin
  { A module with no sections is just the preamble, and it must decode to
    an empty model. }
  Emitter := TWasmModuleEmitter.Create;
  try
    FBuffer := Emitter.Finish;
  finally
    Emitter.Free;
  end;

  Expect<Int64>(Int64(Length(FBuffer))).ToBe(8);
  DecodeModule(FBuffer, FModule);
  Expect<Integer>(FModule.SectionCount).ToBe(0);
  Expect<Integer>(Integer(FModule.Version)).ToBe(WASM_BINARY_VERSION);
end;

procedure TWatEmitTests.TestFullModuleRoundTrip;
var
  Emitter: TWasmModuleEmitter;
  TypeBody, FuncBody, MemBody, GlobalBody, ExportBody: TWasmWriter;
  CodeBody, DataBody, DataCountBody, Entry: TWasmWriter;
  Func: TWasmFuncType;
  RecFunc: TWasmRecType;
  EntryBytes: TWasmBytes;
begin
  { One func type (i32 i32) -> i32. }
  SetLength(Func.Params, 2);
  Func.Params[0] := I32;
  Func.Params[1] := I32;
  SetLength(Func.Results, 1);
  Func.Results[0] := I32;
  SetLength(RecFunc.SubTypes, 1);
  RecFunc.SubTypes[0].IsFinal := True;
  RecFunc.SubTypes[0].SuperTypes := nil;
  RecFunc.SubTypes[0].Comp := MakeFuncCompType(Func);

  TypeBody.Init;
  TypeBody.WriteU32(1);
  TypeBody.WriteType(RecFunc);

  { Function section: one function of type 0. }
  FuncBody.Init;
  FuncBody.WriteU32(1);
  FuncBody.WriteU32(0);

  { Memory section: one memory, min 1 max 2. }
  MemBody.Init;
  MemBody.WriteU32(1);
  MemBody.WriteMemType(MakeMemType(MakeLimitsWithMax(watI32, 1, 2)));

  { Global section: one (mut i32) global, init `i32.const 0 end`. }
  GlobalBody.Init;
  GlobalBody.WriteU32(1);
  GlobalBody.WriteGlobalType(MakeGlobalType(True, I32));
  GlobalBody.WriteRawBytes([$41, $00, $0B]);

  { Export section: "add" (func 0) and "mem" (memory 0). }
  ExportBody.Init;
  ExportBody.WriteU32(2);
  WriteName(ExportBody, 'add');
  ExportBody.WriteByte(Ord(wxkFunc));
  ExportBody.WriteU32(0);
  WriteName(ExportBody, 'mem');
  ExportBody.WriteByte(Ord(wxkMem));
  ExportBody.WriteU32(0);

  { Code section: one entry, one local group (2 x i64), body
    `i32.const 0 end`. The entry is size-prefixed — the emitter builds the
    content, then prefixes its byte count. }
  Entry.Init;
  Entry.WriteU32(1);          { one local group }
  Entry.WriteU32(2);          { count 2 }
  Entry.WriteValueType(I64);
  Entry.WriteRawBytes([$41, $00, $0B]);
  EntryBytes := Entry.ToBytes;
  CodeBody.Init;
  CodeBody.WriteU32(1);
  CodeBody.WriteU32(UInt32(Length(EntryBytes)));
  CodeBody.AppendBytes(EntryBytes);

  { Data section: one active segment, memory 0, offset `i32.const 0 end`,
    payload "hi". }
  DataBody.Init;
  DataBody.WriteU32(1);
  DataBody.WriteU32(0);       { flags 0: active, implicit memory 0 }
  DataBody.WriteRawBytes([$41, $00, $0B]);
  DataBody.WriteU32(2);
  DataBody.WriteRawBytes([$68, $69]);

  { Data count section: one segment. }
  DataCountBody.Init;
  DataCountBody.WriteU32(1);

  { Add every section in a DELIBERATELY scrambled order — the emitter must
    still write them in the prescribed order or DecodeModule rejects them
    as out of order. }
  Emitter := TWasmModuleEmitter.Create;
  try
    Emitter.AddSection(wsCode, CodeBody.ToBytes);
    Emitter.AddSection(wsType, TypeBody.ToBytes);
    Emitter.AddSection(wsData, DataBody.ToBytes);
    Emitter.AddSection(wsMemory, MemBody.ToBytes);
    Emitter.AddSection(wsExport, ExportBody.ToBytes);
    Emitter.AddSection(wsFunction, FuncBody.ToBytes);
    Emitter.AddSection(wsGlobal, GlobalBody.ToBytes);
    Emitter.AddSection(wsDataCount, DataCountBody.ToBytes);
    FBuffer := Emitter.Finish;
  finally
    Emitter.Free;
  end;

  DecodeModule(FBuffer, FModule);

  { The model must match what was emitted, section by section. }
  Expect<Integer>(FModule.TypeCount).ToBe(1);
  Expect<Integer>(Length(FModule.Types[0].SubTypes[0].Comp.Func.Params)).ToBe(2);
  Expect<Integer>(Length(FModule.Types[0].SubTypes[0].Comp.Func.Results)).ToBe(1);

  Expect<Integer>(FModule.FunctionTypeIndexCount).ToBe(1);
  Expect<Int64>(Int64(FModule.FunctionTypeIndices[0])).ToBe(0);

  Expect<Integer>(FModule.MemoryCount).ToBe(1);
  Expect<Boolean>(FModule.Memories[0].Limits.HasMax).ToBe(True);
  Expect<Int64>(Int64(FModule.Memories[0].Limits.Min)).ToBe(1);
  Expect<Int64>(Int64(FModule.Memories[0].Limits.Max)).ToBe(2);

  Expect<Integer>(FModule.GlobalCount).ToBe(1);
  Expect<Boolean>(FModule.Globals[0].GlobalType.Mut).ToBe(True);
  Expect<string>(FModule.Globals[0].GlobalType.ValueType.Describe).ToBe('i32');

  Expect<Integer>(FModule.ExportCount).ToBe(2);
  Expect<string>(FModule.&Exports[0].Name).ToBe('add');
  Expect<Integer>(Ord(FModule.&Exports[0].Kind)).ToBe(Ord(wxkFunc));
  Expect<string>(FModule.&Exports[1].Name).ToBe('mem');
  Expect<Integer>(Ord(FModule.&Exports[1].Kind)).ToBe(Ord(wxkMem));

  Expect<Integer>(FModule.CodeEntryCount).ToBe(1);
  Expect<Integer>(Length(FModule.CodeEntries[0].Locals)).ToBe(1);
  Expect<Int64>(Int64(FModule.CodeEntries[0].Locals[0].Count)).ToBe(2);
  Expect<string>(FModule.CodeEntries[0].Locals[0].ValueType.Describe)
    .ToBe('i64');

  Expect<Boolean>(FModule.HasDataCount).ToBe(True);
  Expect<Int64>(Int64(FModule.DataCount)).ToBe(1);
  Expect<Integer>(FModule.DataSegmentCount).ToBe(1);
  Expect<Integer>(Ord(FModule.DataSegments[0].Mode)).ToBe(Ord(wdmActive));
  Expect<Int64>(Int64(FModule.DataSegments[0].MemIndex)).ToBe(0);
  Expect<Int64>(Int64(FModule.DataSegments[0].Bytes.Size)).ToBe(2);
end;

procedure TWatEmitTests.TestSectionOrderIsPrescribedNotInsertion;
var
  DataCountAt, CodeAt, MemAt, GlobalAt: Integer;
begin
  { Re-run the scrambled build and prove the on-the-wire order is the
    grammar's, not the insertion order: data count (id 12) before code
    (id 10), and memory before global. }
  TestFullModuleRoundTrip;

  DataCountAt := FModule.IndexOfSection(wsDataCount);
  CodeAt := FModule.IndexOfSection(wsCode);
  MemAt := FModule.IndexOfSection(wsMemory);
  GlobalAt := FModule.IndexOfSection(wsGlobal);

  Expect<Boolean>(DataCountAt >= 0).ToBe(True);
  Expect<Boolean>(CodeAt >= 0).ToBe(True);
  Expect<Boolean>(DataCountAt < CodeAt).ToBe(True);
  Expect<Boolean>(MemAt < GlobalAt).ToBe(True);
end;

procedure TWatEmitTests.SetupTests;
begin
  Test('unsigned LEB round-trips through the reader',
    TestUnsignedLebRoundTrip);
  Test('signed LEB round-trips including -2^63', TestSignedLebRoundTrip);
  Test('s33 round-trips across its extremes', TestS33RoundTrip);
  Test('LEB encodings are minimal length', TestLebEncodingsAreMinimal);
  Test('value type encoders round-trip through the decoder',
    TestValueTypeEncoders);
  Test('limits encoders cover all four flag forms', TestLimitsEncoders);
  Test('ref/global/table/mem/tag encoders round-trip',
    TestRefAndGlobalAndTableEncoders);
  Test('composite type section round-trips through DecodeTypeSection',
    TestCompositeTypeSectionRoundTrip);
  Test('preamble alone decodes to an empty module',
    TestPreambleAndEmptyModule);
  Test('a full hand-built module round-trips through DecodeModule',
    TestFullModuleRoundTrip);
  Test('sections are emitted in prescribed order, not insertion order',
    TestSectionOrderIsPrescribedNotInsertion);
end;

begin
  TestRunnerProgram.AddSuite(TWatEmitTests.Create('Wasm.Wat.Emit'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
