{ Wasm.Decoder — binary format to TWasmModule.

  Structural decode only: the preamble, the section sequence, and each
  section's declared extent. Section *bodies* are located, not parsed —
  the per-section decoders and the type checker sit above this unit
  (docs/architecture.md), and keeping the two apart is what lets a host
  ask "which sections does this module have" without paying for a full
  decode.

  Everything rejected here is rejected because the spec says the bytes are
  not a module: wrong preamble, an unknown section id, a section that
  claims more bytes than remain, or known sections out of the grammar's
  PRESCRIBED order — which is not id order (see
  Wasm.Core.SectionOrderPosition). }
unit Wasm.Decoder;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Module;

{ Decode ABytes into AModule. AModule is cleared first. ABytes must
  outlive AModule — section bodies are referenced by offset, not copied. }
procedure DecodeModule(const ABytes: TWasmBytes; const AModule: TWasmModule);

{ Read the whole file and decode it. Raises EWasmDecodeError with the path
  in the message when the file cannot be read. }
procedure DecodeModuleFile(const APath: string; const AModule: TWasmModule;
  out ABytes: TWasmBytes);

function LoadFileBytes(const APath: string): TWasmBytes;

implementation

function LoadFileBytes(const APath: string): TWasmBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  if not FileExists(APath) then
    raise EWasmDecodeError.CreateFmt('no such file: %s', [APath]);
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: EStreamError do
      raise EWasmDecodeError.CreateFmt('cannot read %s: %s',
        [APath, E.Message]);
  end;
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure DecodePreamble(var AReader: TWasmReader; const AModule: TWasmModule);
var
  I: Integer;
  Magic: array[0..3] of Byte;
  Version: UInt32;
begin
  if AReader.Remaining < 8 then
    raise EWasmDecodeError.CreateFmt(
      'not a WebAssembly module: %u byte(s), the 8-byte preamble needs more',
      [AReader.Size]);

  for I := 0 to 3 do
    Magic[I] := AReader.ReadByte;

  for I := 0 to 3 do
    if Magic[I] <> WASM_MAGIC[I] then
      raise EWasmDecodeError.CreateFmt(
        'not a WebAssembly module: magic is %.2x %.2x %.2x %.2x, expected 00 61 73 6d',
        [Magic[0], Magic[1], Magic[2], Magic[3]]);

  Version := AReader.ReadFixedU32;
  if Version <> WASM_BINARY_VERSION then
    raise EWasmDecodeError.CreateFmt(
      'unsupported binary format version %u (this build decodes version %d)',
      [Version, WASM_BINARY_VERSION]);

  AModule.Version := Version;
end;

procedure DecodeModule(const ABytes: TWasmBytes; const AModule: TWasmModule);
var
  Reader: TWasmReader;
  Body: TWasmReader;
  Section: TWasmSectionInfo;
  SectionStart: NativeUInt;
  RawId: Byte;
  BodySize: UInt32;
  Position, HighestPosition: Integer;
begin
  AModule.Clear;
  AModule.Size := Length(ABytes);

  Reader.InitFromBytes(ABytes);
  DecodePreamble(Reader, AModule);

  { Ordering is checked against the grammar's PRESCRIBED ORDER, not
    against section ids — they are not the same sequence (see
    SectionOrderPosition). Positions are 1-based, so 0 is "nothing
    ordered seen yet". }
  HighestPosition := 0;

  while not Reader.Eof do
  begin
    SectionStart := Reader.Position;
    RawId := Reader.ReadByte;

    if not IsKnownSectionId(RawId) then
      raise EWasmDecodeError.CreateFmt(
        'unknown section id %d at offset %u', [RawId, SectionStart]);

    BodySize := Reader.ReadU32;

    if Reader.Remaining < BodySize then
      raise EWasmDecodeError.CreateFmt(
        '%s section at offset %u declares %u byte(s) but only %u remain',
        [SectionIdName(RawId), SectionStart, BodySize, Reader.Remaining]);

    Section.Id := RawId;
    Section.Name := '';
    Section.BodyOffset := Reader.Position;
    Section.BodySize := BodySize;

    if Section.IsCustom then
    begin
      { The name is part of the custom section's own body, so read it
        through a sub-reader bounded by the declared size — a name length
        that overruns the section must not be able to read the next one. }
      Body := Reader.SubReader(BodySize);
      try
        Section.Name := Body.ReadName;
      except
        on E: EWasmDecodeError do
          raise EWasmDecodeError.CreateFmt(
            'custom section at offset %u: %s', [SectionStart, E.Message]);
      end;
    end
    else
    begin
      Position := SectionOrderPosition(RawId);
      { Strictly greater, so a repeated known section is caught by the
        same comparison — the spec allows each at most once. }
      if Position <= HighestPosition then
        raise EWasmDecodeError.CreateFmt(
          '%s section at offset %u is out of order or repeated ' +
          '(prescribed position %d, after position %d)',
          [SectionIdName(RawId), SectionStart, Position, HighestPosition]);
      HighestPosition := Position;
      Reader.Skip(BodySize);
    end;

    AModule.AddSection(Section);
  end;
end;

procedure DecodeModuleFile(const APath: string; const AModule: TWasmModule;
  out ABytes: TWasmBytes);
var
  Loaded: TWasmBytes;
begin
  { Load into a local first. Assigning straight to ABytes would release
    the caller's PREVIOUS buffer while AModule still holds offsets into
    it — a window in which the module points at freed memory. Callers
    that reuse one module and one buffer across a loop of files (the
    `wasmlight inspect` path does exactly that) sit in that window.
    Clearing the module before the old bytes go away restores ADR-0003's
    ordering: the buffer outlives the module that borrows it. }
  Loaded := LoadFileBytes(APath);
  AModule.Clear;
  ABytes := Loaded;
  DecodeModule(ABytes, AModule);
end;

end.
