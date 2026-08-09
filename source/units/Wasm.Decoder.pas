{ Wasm.Decoder — binary format to TWasmModule.

  The full structural decode: the preamble, the section sequence, each
  section's declared extent, and every known section's BODY, decoded
  through the per-section decoders (Wasm.Decoder.Types / .Entities /
  .Segments) into the model. The section table (TWasmSectionInfo) is
  still recorded alongside the decoded content, so a host can ask "which
  sections does this module have" and where each body sits in the buffer.
  What deliberately stays out is the instruction grammar INSIDE function
  bodies: those are located as spans and walked by the fused validation
  pass, which emits the IR every tier consumes (ADR-0007).

  Everything rejected here is rejected because the spec says the bytes
  are not a module: wrong preamble, an unknown section id, a section that
  claims more bytes than remain, known sections out of the grammar's
  PRESCRIBED order — which is not id order (see
  Wasm.Core.SectionOrderPosition) — a body the section decoders find
  malformed, or the two cross-section consistency rules the module
  grammar itself imposes (function/code lengths, data count — see
  CheckCrossSectionConsistency). }
unit Wasm.Decoder;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Entities,
  Wasm.Decoder.Segments,
  Wasm.Decoder.Types,
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
  { The magic is checked BEFORE the version field is required, not after
    a single "do we have eight bytes" gate. That ordering is observable:
    a four-byte input whose bytes are not the magic is `magic header not
    detected`, while a four-byte input that IS the magic is `unexpected
    end` — the version is simply missing. Requiring eight bytes up front
    collapses the two, and upstream's binary.wast asserts both. }
  if AReader.Remaining < Length(WASM_MAGIC) then
    raise EWasmDecodeError.CreateFmt(
      '%s: %u byte(s), the 4-byte magic needs more',
      [MSG_UNEXPECTED_END, AReader.Size]);

  for I := 0 to 3 do
    Magic[I] := AReader.ReadByte;

  for I := 0 to 3 do
    if Magic[I] <> WASM_MAGIC[I] then
      raise EWasmDecodeError.CreateFmt(
        '%s: magic is %.2x %.2x %.2x %.2x, expected 00 61 73 6d',
        [MSG_MAGIC_HEADER, Magic[0], Magic[1], Magic[2], Magic[3]]);

  { A short version field fails inside ReadFixedU32, as `unexpected end`. }
  Version := AReader.ReadFixedU32;
  if Version <> WASM_BINARY_VERSION then
    raise EWasmDecodeError.CreateFmt(
      '%s: %u (this build decodes version %d)',
      [MSG_UNKNOWN_BINARY_VERSION, Version, WASM_BINARY_VERSION]);

  AModule.Version := Version;
end;

{ Dispatch one known non-custom section body to its decoder. ABody is a
  SubReader over exactly the declared size and ABase the body's absolute
  buffer offset, so spans stored into the model are absolute (ADR-0003).
  Each decoder consumes the body EXACTLY — leftover bytes and early
  truncation are both malformed, per the section framing
  (https://webassembly.github.io/spec/core/binary/modules.html#binary-section). }
procedure DecodeSectionBody(const AId: TWasmSectionId;
  var ABody: TWasmReader; const ABase: NativeUInt;
  const AModule: TWasmModule);
begin
  case AId of
    wsType:      DecodeTypeSection(ABody, ABase, AModule);
    wsImport:    DecodeImportSection(ABody, ABase, AModule);
    wsFunction:  DecodeFunctionSection(ABody, ABase, AModule);
    wsTable:     DecodeTableSection(ABody, ABase, AModule);
    wsMemory:    DecodeMemorySection(ABody, ABase, AModule);
    wsGlobal:    DecodeGlobalSection(ABody, ABase, AModule);
    wsExport:    DecodeExportSection(ABody, ABase, AModule);
    wsStart:     DecodeStartSection(ABody, ABase, AModule);
    wsElement:   DecodeElementSection(ABody, ABase, AModule);
    wsCode:      DecodeCodeSection(ABody, ABase, AModule);
    wsData:      DecodeDataSection(ABody, ABase, AModule);
    wsDataCount: DecodeDataCountSection(ABody, ABase, AModule);
    wsTag:       DecodeTagSection(ABody, ABase, AModule);
  end;
end;

{ The two consistency rules the MODULE grammar imposes across sections —
  binary-format side conditions, so violating either is MALFORMED, not
  invalid (https://webassembly.github.io/spec/core/binary/modules.html#binary-module):

    "The lengths of lists produced by the (possibly empty) function and
     code section must match up."

    "Similarly, the optional data count must match the length of the data
     segment list." (Also at #binary-datacntsec: "If this count does not
     match the length of the data segment list, the module is malformed.")

  An ABSENT section produces the empty list — "All sections can be
  empty" and every section is optional in the module production — so one
  side present and nonempty while the other is absent fails the same
  comparison. The message prefixes are conformance surface: the spec
  testsuite asserts them (docs/roadmap.md, Track C), so they must start
  with the canonical phrases below.

  The clause's third rule — the data count section "must be present if
  any data index occurs in the code section" (memory.init / data.drop) —
  needs instruction inspection inside function bodies, which is the fused
  validation walk's territory (ADR-0007). It is deliberately deferred to
  that pass (Track B), not checked here. }
procedure CheckCrossSectionConsistency(const AModule: TWasmModule);
begin
  if AModule.FunctionTypeIndexCount <> AModule.CodeEntryCount then
    raise EWasmDecodeError.CreateFmt(
      'function and code section have inconsistent lengths ' +
      '(%d function(s), %d code entries)',
      [AModule.FunctionTypeIndexCount, AModule.CodeEntryCount]);

  if AModule.HasDataCount and
    (AModule.DataCount <> UInt32(AModule.DataSegmentCount)) then
    raise EWasmDecodeError.CreateFmt(
      'data count and data section have inconsistent lengths ' +
      '(declared %u, %d segment(s))',
      [AModule.DataCount, AModule.DataSegmentCount]);
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
        '%s: id %d at offset %u',
        [MSG_MALFORMED_SECTION_ID, RawId, SectionStart]);

    BodySize := Reader.ReadU32;

    if Reader.Remaining < BodySize then
      raise EWasmDecodeError.CreateFmt(
        '%s: %s section at offset %u declares %u byte(s) but only %u remain',
        [MSG_LENGTH_OUT_OF_BOUNDS, SectionIdName(RawId), SectionStart,
         BodySize, Reader.Remaining]);

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
      Body.Context := wrcSection;
      try
        Section.Name := Body.ReadName;
      except
        { The location is APPENDED, never prepended: the message already
          starts with the canonical prefix the harness matches on, and
          wrapping it would hide that prefix behind ours. }
        on E: EWasmDecodeError do
          raise EWasmDecodeError.CreateFmt(
            '%s (in the custom section at offset %u)',
            [E.Message, SectionStart]);
      end;
    end
    else
    begin
      Position := SectionOrderPosition(RawId);
      { Strictly greater, so a repeated known section is caught by the
        same comparison — the spec allows each at most once. }
      if Position <= HighestPosition then
        raise EWasmDecodeError.CreateFmt(
          '%s: %s section at offset %u is out of order or repeated ' +
          '(prescribed position %d, after position %d)',
          [MSG_UNEXPECTED_CONTENT, SectionIdName(RawId), SectionStart,
           Position, HighestPosition]);
      HighestPosition := Position;

      { Decode the body through a SubReader over exactly the declared
        size, so a body can never read past its own extent and every
        span stored into the model is ABase-relative-made-absolute
        (ADR-0003). The SubReader call also advances Reader past the
        body, replacing the skip this walk used to do. }
      Body := Reader.SubReader(BodySize);
      Body.Context := wrcSection;
      DecodeSectionBody(TWasmSectionId(RawId), Body,
        Section.BodyOffset, AModule);
    end;

    AModule.AddSection(Section);
  end;

  CheckCrossSectionConsistency(AModule);
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
