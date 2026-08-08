{ wasmbench — component benchmarks for the byte-moving layers.

  Measurement only. These numbers inform PR descriptions and the RTL
  policy in docs/code-style.md; they are never wired into a CI assertion
  (VISION.md, "Honest measurement"), because a benchmark that gates a
  merge becomes a number people tune instead of a number people trust.

  Timing is wall clock in milliseconds over a large iteration count —
  deliberately coarse. A benchmark that needs sub-millisecond resolution
  to show a difference is measuring noise. }
program wasmbench;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  CLI.Options,
  CLI.Parser,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Module;

const
  DEFAULT_ITERATIONS = 20000;

{ A module with enough sections to exercise the walk without being
  dominated by any single one: a run of known sections in id order plus
  interleaved custom sections carrying names. }
function BuildSyntheticModule(const ASectionBodyBytes: Integer): TWasmBytes;
var
  Output: TMemoryStream;
  Filler: TWasmBytes;

  procedure Emit(const AValue: Byte);
  begin
    Output.WriteBuffer(AValue, 1);
  end;

  procedure EmitU32(AValue: UInt32);
  var
    B: Byte;
  begin
    repeat
      B := AValue and $7F;
      AValue := AValue shr 7;
      if AValue <> 0 then
        B := B or $80;
      Emit(B);
    until AValue = 0;
  end;

  procedure EmitKnownSection(const AId: TWasmSectionId);
  begin
    Emit(Ord(AId));
    EmitU32(Length(Filler));
    if Length(Filler) > 0 then
      Output.WriteBuffer(Filler[0], Length(Filler));
  end;

  procedure EmitCustomSection(const AName: string);
  begin
    Emit(Ord(wsCustom));
    EmitU32(1 + Length(AName));
    EmitU32(Length(AName));
    if Length(AName) > 0 then
      Output.WriteBuffer(AName[1], Length(AName));
  end;

var
  I: Integer;
begin
  SetLength(Filler, ASectionBodyBytes);
  for I := 0 to High(Filler) do
    Filler[I] := Byte(I);

  Output := TMemoryStream.Create;
  try
    for I := 0 to 3 do
      Emit(WASM_MAGIC[I]);
    Emit(WASM_BINARY_VERSION);
    Emit(0);
    Emit(0);
    Emit(0);

    EmitCustomSection('producers');
    EmitKnownSection(wsType);
    EmitKnownSection(wsImport);
    EmitKnownSection(wsFunction);
    EmitCustomSection('build_id');
    EmitKnownSection(wsMemory);
    EmitKnownSection(wsGlobal);
    EmitKnownSection(wsExport);
    EmitKnownSection(wsCode);
    EmitKnownSection(wsData);
    EmitCustomSection('name');

    SetLength(Result, Output.Size);
    Output.Position := 0;
    if Output.Size > 0 then
      Output.ReadBuffer(Result[0], Output.Size);
  finally
    Output.Free;
  end;
end;

{ A buffer of ACount unsigned LEB128 values spanning all five encoding
  widths, so the benchmark is not just measuring the single-byte path. }
function BuildLebCorpus(const ACount: Integer): TWasmBytes;
const
  WIDTH_SAMPLES: array[0..4] of UInt32 = (
    $0000007F, $00003FFF, $001FFFFF, $0FFFFFFF, $FFFFFFFF);
var
  Output: TMemoryStream;
  I: Integer;
  Value: UInt32;
  B: Byte;
begin
  Output := TMemoryStream.Create;
  try
    for I := 0 to ACount - 1 do
    begin
      Value := WIDTH_SAMPLES[I mod Length(WIDTH_SAMPLES)];
      repeat
        B := Value and $7F;
        Value := Value shr 7;
        if Value <> 0 then
          B := B or $80;
        Output.WriteBuffer(B, 1);
      until Value = 0;
    end;

    SetLength(Result, Output.Size);
    Output.Position := 0;
    if Output.Size > 0 then
      Output.ReadBuffer(Result[0], Output.Size);
  finally
    Output.Free;
  end;
end;

procedure Report(const AName: string; const AIterations: Int64;
  const ABytesEach: Int64; const AElapsedMs: Int64);
var
  TotalBytes: Int64;
  MbPerSec: Double;
  NsPerOp: Double;
begin
  TotalBytes := AIterations * ABytesEach;
  if AElapsedMs > 0 then
  begin
    MbPerSec := (TotalBytes / (1024 * 1024)) / (AElapsedMs / 1000);
    NsPerOp := (AElapsedMs * 1000000.0) / AIterations;
  end
  else
  begin
    MbPerSec := 0;
    NsPerOp := 0;
  end;

  WriteLn(Format('%-24s %10d iter %8d ms %12.1f ns/op %10.1f MiB/s',
    [AName, AIterations, AElapsedMs, NsPerOp, MbPerSec]));
end;

procedure BenchDecodeModule(const AIterations: Integer);
var
  Bytes: TWasmBytes;
  Module: TWasmModule;
  I: Integer;
  Started: Int64;
begin
  Bytes := BuildSyntheticModule(64);
  Module := TWasmModule.Create;
  try
    { Warm up so the first-iteration allocation does not land in the
      measured window. }
    DecodeModule(Bytes, Module);

    Started := GetTickCount64;
    for I := 1 to AIterations do
      DecodeModule(Bytes, Module);
    Report('decode module', AIterations, Length(Bytes),
      GetTickCount64 - Started);
  finally
    Module.Free;
  end;
end;

procedure BenchReadU32(const AIterations: Integer);
const
  VALUES_PER_PASS = 4096;
var
  Corpus: TWasmBytes;
  Reader: TWasmReader;
  I, J: Integer;
  Started: Int64;
  Sink: UInt32;
begin
  Corpus := BuildLebCorpus(VALUES_PER_PASS);
  Sink := 0;

  Started := GetTickCount64;
  for I := 1 to AIterations do
  begin
    Reader.InitFromBytes(Corpus);
    for J := 1 to VALUES_PER_PASS do
      Sink := Sink xor Reader.ReadU32;
  end;
  Report('read u32 (LEB128)', Int64(AIterations) * VALUES_PER_PASS,
    Length(Corpus) div VALUES_PER_PASS, GetTickCount64 - Started);

  { Consume Sink so the loop cannot be optimised away. }
  if Sink = $FFFFFFFF then
    WriteLn(ErrOutput, '(sink ', Sink, ')');
end;

var
  Options: TOptionList;
  Positionals: TStringList;
  IterationsOpt: TIntegerOption;
  Iterations: Integer;
begin
  Options := TOptionList.Create;
  try
    IterationsOpt := Options.AddInteger('iterations',
      'Iterations per benchmark (default: ' + IntToStr(DEFAULT_ITERATIONS) + ')');

    try
      Positionals := ParseCommandLine(Options.Options);
    except
      on E: TParseError do
      begin
        WriteLn(ErrOutput, 'wasmbench: ', E.Message);
        ExitCode := 1;
        Exit;
      end;
    end;
    Positionals.Free;

    Iterations := IterationsOpt.ValueOr(DEFAULT_ITERATIONS);
    if Iterations <= 0 then
    begin
      WriteLn(ErrOutput, 'wasmbench: --iterations must be positive');
      ExitCode := 1;
      Exit;
    end;

    WriteLn('wasmbench ', PROGRAM_VERSION, ' — measurement only, never a CI assertion');
    WriteLn;
    BenchDecodeModule(Iterations);
    BenchReadU32(Iterations div 64 + 1);
  finally
    Options.Free;
  end;
end.
