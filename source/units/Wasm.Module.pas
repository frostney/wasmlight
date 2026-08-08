{ Wasm.Module — the decoded module model.

  A module is a passive description of what a `.wasm` file contains. It
  holds no host state, no memory, and no execution tier: instantiating one
  produces the store-side objects, and that boundary is why the same
  decoded module can be handed to any tier (ADR-0001).

  Section bodies are kept as offsets into the original buffer rather than
  copied out. Decoding a module is therefore proportional to its section
  count, not its size, and an execution tier reads a body straight from the
  caller's bytes. The buffer must outlive the module. }
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

  TWasmModule = class
  private
    FVersion: UInt32;
    FSize: NativeUInt;
    FSections: array of TWasmSectionInfo;

    function GetSection(const AIndex: Integer): TWasmSectionInfo;
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

    property Sections[const AIndex: Integer]: TWasmSectionInfo
      read GetSection; default;
    { Binary-format version from the preamble. Always WASM_BINARY_VERSION
      for a module the decoder accepted. }
    property Version: UInt32 read FVersion write FVersion;
    { Size of the buffer this module was decoded from. }
    property Size: NativeUInt read FSize write FSize;
  end;

implementation

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

end.
