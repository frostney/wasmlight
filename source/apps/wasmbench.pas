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

  Wasm.Aot,
  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Engine,
  Wasm.Jit,
  Wasm.Module,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Wat.Assembler;

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
    { The synthetic module fills each section body with arbitrary bytes to give
      the walk bulk; the strict decoder rejects that junk on a deep section-body
      decode. This is a MEASUREMENT tool, never a CI assertion, so a body the
      decoder will not accept is reported as a skip rather than aborting the
      whole run — the other benchmarks (and the startup measurement) still print.
      A faithful decode-throughput corpus is a separate follow-up. }
    try
      { Warm up so the first-iteration allocation does not land in the
        measured window. }
      DecodeModule(Bytes, Module);

      Started := GetTickCount64;
      for I := 1 to AIterations do
        DecodeModule(Bytes, Module);
      Report('decode module', AIterations, Length(Bytes),
        GetTickCount64 - Started);
    except
      on E: EWasmError do
        WriteLn(Format('%-24s (skipped: %s)', ['decode module', E.Message]));
    end;
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

{ --- startup: interpret vs JIT-warmup vs AOT-load (aot-spec §7 Wave 5) ------

  Measurement only, and deliberately a COMPONENT benchmark like the others: it
  times the full "get a module ready and run its _start once" for each tier, so
  the numbers tell the AOT-instant-start vs JIT-warmup vs interpreter-dispatch
  story. Never a CI assertion — a benchmark that gates a merge becomes a number
  people tune. The AOT artifact is compiled ONCE up front (that is the ahead-of-
  time build cost, not a per-startup cost) and only its LOAD is inside the timed
  loop; the JIT compile IS inside its loop, because that is what "warmup" costs
  on every fresh start. }

const
  { A pure-compute command: _start runs a small integer loop and returns. No
    imports and no host calls, so all three tiers set it up identically and only
    the compile/load overhead differs. _start is JIT/AOT-compilable (loop +
    br_if + local + i32 arithmetic are all in the baseline op set). }
  BENCH_STARTUP_WAT =
    '(module' + sLineBreak +
    '  (func (export "_start")' + sLineBreak +
    '    (local $i i32) (local $acc i32)' + sLineBreak +
    '    (loop $l' + sLineBreak +
    '      (local.set $acc (i32.add (local.get $acc) (local.get $i)))' + sLineBreak +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' + sLineBreak +
    '      (br_if $l (i32.lt_u (local.get $i) (i32.const 2000))))))';

{ Run _start of ALoaded once, either purely interpreted (AJit/AArtifact absent),
  JIT-warmed (AForceJit), or AOT-loaded (AArtifact non-empty). A fresh store per
  call, so each timed iteration pays the whole startup. }
procedure StartupOnce(const ABytes: TWasmBytes; const AForceJit: Boolean;
  const AArtifact: TWasmBytes);
var
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Linker: TWasmLinker;
  Instance: TWasmInstance;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  StartFn: TWasmFunc;
  I: Integer;
  NoArgs, NoResults: array of TWasmValue;
begin
  Loaded := nil;
  Engine := nil;
  Store := nil;
  Linker := nil;
  Instance := nil;
  Jit := nil;
  try
    Loaded := LoadModule(ABytes);
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    EnsureInterpreter(Store);
    Linker := TWasmLinker.Create(Store);
    Instance := Instantiate(Store, Linker, Loaded);

    if Length(AArtifact) > 0 then
      Jit := AotLoadAndWire(Store, Loaded, Instance.Raw, AArtifact, LoadRes)
    else if AForceJit then
    begin
      Jit := RegisterJit(Store);
      for I := 0 to High(Instance.Raw.FuncAddrs) do
        Jit.ForceCompile(Instance.Raw.FuncAddrs[I]);
    end;

    if Instance.FindExportFunc('_start', StartFn) then
    begin
      NoArgs := nil;
      NoResults := nil;
      Call(StartFn, NoArgs, NoResults);
    end;
  finally
    Instance.Free;
    Jit.Free;               { before the store (jit-spec §3.4 teardown order) }
    Linker.Free;
    FreeAndNil(Store);
    Engine.Free;
    Loaded.Free;
  end;
end;

procedure ReportStartup(const AName: string; const AIterations: Int64;
  const AElapsedMs: Int64);
var
  NsPerOp: Double;
begin
  if AIterations > 0 then
    NsPerOp := (AElapsedMs * 1000000.0) / AIterations
  else
    NsPerOp := 0;
  WriteLn(Format('%-24s %10d iter %8d ms %12.1f ns/op', [AName, AIterations,
    AElapsedMs, NsPerOp]));
end;

procedure BenchStartup(const AIterations: Integer);
var
  Bytes, Artifact: TWasmBytes;
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Iters, I: Integer;
  Started: Int64;
begin
  Bytes := AssembleWatText(BENCH_STARTUP_WAT);

  { Compile the artifact ONCE (ahead-of-time build cost, outside every timer). }
  Loaded := LoadModule(Bytes);
  Engine := TWasmEngine.Create;
  Store := TWasmStore.Create(Engine);
  try
    Artifact := AotCompileModule(Store, Loaded);
  finally
    FreeAndNil(Store);
    Engine.Free;
    Loaded.Free;
  end;

  { Startup is far heavier than a decode, so fewer iterations than the byte
    benches; still coarse ms over a batch. }
  Iters := AIterations div 8 + 1;

  { Warm up each path once so a first-touch allocation is not in the window. }
  StartupOnce(Bytes, False, nil);
  StartupOnce(Bytes, True, nil);
  StartupOnce(Bytes, False, Artifact);

  Started := GetTickCount64;
  for I := 1 to Iters do
    StartupOnce(Bytes, False, nil);
  ReportStartup('startup interpret', Iters, GetTickCount64 - Started);

  Started := GetTickCount64;
  for I := 1 to Iters do
    StartupOnce(Bytes, True, nil);
  ReportStartup('startup jit-warmup', Iters, GetTickCount64 - Started);

  Started := GetTickCount64;
  for I := 1 to Iters do
    StartupOnce(Bytes, False, Artifact);
  ReportStartup('startup aot-load', Iters, GetTickCount64 - Started);
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
    BenchStartup(Iterations);
  finally
    Options.Free;
  end;
end.
