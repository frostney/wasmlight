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
  DEFAULT_EXECUTION_ITERATIONS = 300000000;
  DEFAULT_FIB_INPUT = 35;
  DEFAULT_MEMORY_ITERATIONS = 10000000;
  DEFAULT_NUMERIC_ITERATIONS = 1000000;
  DEFAULT_SIMD_ITERATIONS = 1000000;
  DEFAULT_SAMPLES = 1;

type
  TExecutionTier = (etInterp, etJit, etAot);
  TExecutionTiers = set of TExecutionTier;
  TBenchmarkWorkload = (bwDecode, bwLeb128, bwStartup, bwLoop, bwFib,
    bwMemory, bwNumeric, bwSimd);
  TBenchmarkWorkloads = set of TBenchmarkWorkload;
  TInt64Samples = array of Int64;

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
  const AElapsedMs: Int64; const ASamples: Integer = 1);
var
  NsPerOp: Double;
  SampleSuffix: string;
begin
  if AIterations > 0 then
    NsPerOp := (AElapsedMs * 1000000.0) / AIterations
  else
    NsPerOp := 0;
  if ASamples > 1 then
    SampleSuffix := Format('  median of %d samples', [ASamples])
  else
    SampleSuffix := '';
  WriteLn(Format('%-24s %10d iter %8d ms %12.1f ns/op%s', [AName,
    AIterations, AElapsedMs, NsPerOp, SampleSuffix]));
end;

function Median(const ASamples: TInt64Samples): Int64;
var
  Sorted: TInt64Samples;
  I, J: Integer;
  Value: Int64;
begin
  if Length(ASamples) = 0 then
    Exit(0);
  Sorted := Copy(ASamples);
  for I := 1 to High(Sorted) do
  begin
    Value := Sorted[I];
    J := I - 1;
    while (J >= 0) and (Sorted[J] > Value) do
    begin
      Sorted[J + 1] := Sorted[J];
      Dec(J);
    end;
    Sorted[J + 1] := Value;
  end;
  if Odd(Length(Sorted)) then
    Result := Sorted[Length(Sorted) div 2]
  else
    Result := (Sorted[Length(Sorted) div 2 - 1] +
      Sorted[Length(Sorted) div 2]) div 2;
end;

function TierName(const ATier: TExecutionTier): string;
begin
  case ATier of
    etInterp:
      Result := 'interpret';
    etJit:
      Result := 'jit';
    etAot:
      Result := 'aot';
  end;
end;

function MeasureStartup(const ABytes, AArtifact: TWasmBytes;
  const ATier: TExecutionTier; const AIterations: Integer): Int64;
var
  I: Integer;
  Started: Int64;
begin
  Started := GetTickCount64;
  for I := 1 to AIterations do
    case ATier of
      etInterp:
        StartupOnce(ABytes, False, nil);
      etJit:
        StartupOnce(ABytes, True, nil);
      etAot:
        StartupOnce(ABytes, False, AArtifact);
    end;
  Result := GetTickCount64 - Started;
end;

procedure BenchStartup(const AIterations, ASampleCount: Integer;
  const ATiers: TExecutionTiers);
var
  Bytes, Artifact: TWasmBytes;
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Iters, Sample: Integer;
  Tier: TExecutionTier;
  Samples: TInt64Samples;
begin
  Bytes := AssembleWatText(BENCH_STARTUP_WAT);

  Artifact := nil;
  if etAot in ATiers then
  begin
    { Compile the artifact ONCE (ahead-of-time build cost, outside every
      timer). }
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
  end;

  { Startup is far heavier than a decode, so fewer iterations than the byte
    benches; still coarse ms over a batch. }
  Iters := AIterations div 8 + 1;

  SetLength(Samples, ASampleCount);
  for Tier := Low(TExecutionTier) to High(TExecutionTier) do
    if Tier in ATiers then
    begin
      { Warm up only the selected path, so profiling JIT or AOT never pays for
        an interpreter run first. }
      case Tier of
        etInterp:
          StartupOnce(Bytes, False, nil);
        etJit:
          StartupOnce(Bytes, True, nil);
        etAot:
          StartupOnce(Bytes, False, Artifact);
      end;
      for Sample := 0 to ASampleCount - 1 do
        Samples[Sample] := MeasureStartup(Bytes, Artifact, Tier, Iters);
      if Tier = etJit then
        ReportStartup('startup jit-warmup', Iters, Median(Samples),
          ASampleCount)
      else if Tier = etAot then
        ReportStartup('startup aot-load', Iters, Median(Samples), ASampleCount)
      else
        ReportStartup('startup interpret', Iters, Median(Samples),
          ASampleCount);
    end;
end;

{ --- steady-state execution: interpreter vs JIT vs AOT -------------------

  Keep load, validation, instantiation, JIT compilation and AOT loading outside
  the timer. This answers a different question from BenchStartup: how quickly
  each tier executes the same already-ready integer loop. ForceCompile and the
  AOT load result are checked so an accidental fallback cannot masquerade as a
  compiled-tier measurement. JIT and AOT intentionally execute byte-identical
  code; their expected steady-state times are therefore equal, while AOT's win
  belongs to the startup benchmark above. }

const
  BENCH_EXECUTION_WAT =
    '(module' + sLineBreak +
    '  (func (export "run") (param $n i32) (result i32)' + sLineBreak +
    '    (local $i i32) (local $acc i32)' + sLineBreak +
    '    (loop $l' + sLineBreak +
    '      (local.set $acc' + sLineBreak +
    '        (i32.add (local.get $acc)' + sLineBreak +
    '          (i32.mul (local.get $i) (i32.const 1664525))))' + sLineBreak +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' + sLineBreak +
    '      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))' + sLineBreak +
    '    (local.get $acc)))';
  BENCH_FIB_WAT =
    '(module' + sLineBreak +
    '  (func $fib (export "run") (param $n i32) (result i32)' + sLineBreak +
    '    (if (result i32)' + sLineBreak +
    '      (i32.lt_u (local.get $n) (i32.const 2))' + sLineBreak +
    '      (then (local.get $n))' + sLineBreak +
    '      (else' + sLineBreak +
    '        (i32.add' + sLineBreak +
    '          (call $fib (i32.sub (local.get $n) (i32.const 1)))' + sLineBreak +
    '          (call $fib (i32.sub (local.get $n) (i32.const 2))))))))';
  BENCH_MEMORY_WAT =
    '(module' + sLineBreak +
    '  (memory 1)' + sLineBreak +
    '  (func (export "run") (param $n i32) (result i32)' + sLineBreak +
    '    (local $i i32) (local $acc i32)' + sLineBreak +
    '    (loop $l' + sLineBreak +
    '      (i32.store (i32.const 0) (local.get $i))' + sLineBreak +
    '      (local.set $acc' + sLineBreak +
    '        (i32.add (local.get $acc) (i32.load (i32.const 0))))' + sLineBreak +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' + sLineBreak +
    '      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))' + sLineBreak +
    '    (local.get $acc)))';
  BENCH_NUMERIC_WAT =
    '(module' + sLineBreak +
    '  (func (export "run") (param $n i32) (result i64)' + sLineBreak +
    '    (local $i i32) (local $acc i64) (local $x f32) (local $y f64)' +
    sLineBreak +
    '    (loop $l' + sLineBreak +
    '      (local.set $x' + sLineBreak +
    '        (f32.div' + sLineBreak +
    '          (f32.mul' + sLineBreak +
    '            (f32.sub' + sLineBreak +
    '              (f32.add (f32.convert_i32_s (local.get $i))' +
    '                (f32.const 1.25))' + sLineBreak +
    '              (f32.const 0.25))' + sLineBreak +
    '            (f32.const 0.5))' + sLineBreak +
    '          (f32.const 0.5)))' + sLineBreak +
    '      (local.set $y' + sLineBreak +
    '        (f64.div' + sLineBreak +
    '          (f64.mul' + sLineBreak +
    '            (f64.sub' + sLineBreak +
    '              (f64.add' + sLineBreak +
    '                (f64.convert_i64_s' + sLineBreak +
    '                  (i64.extend_i32_u (local.get $i)))' + sLineBreak +
    '                (f64.const 1.25))' + sLineBreak +
    '              (f64.const 0.25))' + sLineBreak +
    '            (f64.const 0.5))' + sLineBreak +
    '          (f64.const 0.5)))' + sLineBreak +
    '      (local.set $acc' + sLineBreak +
    '        (i64.add (local.get $acc)' + sLineBreak +
    '          (i64.add' + sLineBreak +
    '            (i64.extend_i32_u' + sLineBreak +
    '              (i32.add' + sLineBreak +
    '                (i32.add' + sLineBreak +
    '                  (i32.mul' + sLineBreak +
    '                    (i32.div_u' + sLineBreak +
    '                      (i32.add (local.get $i) (i32.const 12345))' +
    '                      (i32.const 7))' + sLineBreak +
    '                    (i32.const 7))' + sLineBreak +
    '                  (i32.rem_u' + sLineBreak +
    '                    (i32.add (local.get $i) (i32.const 12345))' +
    '                    (i32.const 7)))' + sLineBreak +
    '                (i32.add' + sLineBreak +
    '                  (i32.mul' + sLineBreak +
    '                    (i32.div_s' + sLineBreak +
    '                      (i32.add (local.get $i) (i32.const 12345))' +
    '                      (i32.const 7))' + sLineBreak +
    '                    (i32.const 7))' + sLineBreak +
    '                  (i32.rem_s' + sLineBreak +
    '                    (i32.add (local.get $i) (i32.const 12345))' +
    '                    (i32.const 7)))))' + sLineBreak +
    '            (i64.add' + sLineBreak +
    '              (i64.add' + sLineBreak +
    '                (i64.mul' + sLineBreak +
    '                  (i64.div_u' + sLineBreak +
    '                    (i64.add (i64.extend_i32_u (local.get $i))' +
    '                      (i64.const 987654321))' + sLineBreak +
    '                    (i64.const 11))' + sLineBreak +
    '                  (i64.const 11))' + sLineBreak +
    '                (i64.rem_u' + sLineBreak +
    '                  (i64.add (i64.extend_i32_u (local.get $i))' +
    '                    (i64.const 987654321))' + sLineBreak +
    '                  (i64.const 11)))' + sLineBreak +
    '              (i64.add' + sLineBreak +
    '                (i64.mul' + sLineBreak +
    '                  (i64.div_s' + sLineBreak +
    '                    (i64.add (i64.extend_i32_u (local.get $i))' +
    '                      (i64.const 987654321))' + sLineBreak +
    '                    (i64.const 11))' + sLineBreak +
    '                  (i64.const 11))' + sLineBreak +
    '                (i64.rem_s' + sLineBreak +
    '                  (i64.add (i64.extend_i32_u (local.get $i))' +
    '                    (i64.const 987654321))' + sLineBreak +
    '                  (i64.const 11)))))))' + sLineBreak +
    '      (local.set $acc' + sLineBreak +
    '        (i64.add (local.get $acc)' + sLineBreak +
    '          (i64.extend_i32_u' + sLineBreak +
    '            (i32.add' + sLineBreak +
    '              (i32.add' + sLineBreak +
    '                (i32.add (f32.eq (local.get $x) (local.get $x))' +
    '                  (f32.ne (local.get $x) (f32.const -1)))' + sLineBreak +
    '                (i32.add (f32.lt (local.get $x)' +
    '                    (f32.add (local.get $x) (f32.const 1)))' +
    '                  (f32.gt (local.get $x) (f32.const -1))))' + sLineBreak +
    '              (i32.add (f32.le (local.get $x) (local.get $x))' +
    '                (f32.ge (local.get $x) (local.get $x)))))))' +
    sLineBreak +
    '      (local.set $acc' + sLineBreak +
    '        (i64.add (local.get $acc)' + sLineBreak +
    '          (i64.extend_i32_u' + sLineBreak +
    '            (i32.add' + sLineBreak +
    '              (i32.add' + sLineBreak +
    '                (i32.add (f64.eq (local.get $y) (local.get $y))' +
    '                  (f64.ne (local.get $y) (f64.const -1)))' + sLineBreak +
    '                (i32.add (f64.lt (local.get $y)' +
    '                    (f64.add (local.get $y) (f64.const 1)))' +
    '                  (f64.gt (local.get $y) (f64.const -1))))' + sLineBreak +
    '              (i32.add (f64.le (local.get $y) (local.get $y))' +
    '                (f64.ge (local.get $y) (local.get $y)))))))' +
    sLineBreak +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' + sLineBreak +
    '      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))' + sLineBreak +
    '    (local.get $acc)))';
  BENCH_SIMD_WAT =
    '(module' + sLineBreak +
    '  (func (export "run") (param $n i32) (result i64)' + sLineBreak +
    '    (local $i i32) (local $v v128) (local $mask v128)' + sLineBreak +
    '    (local $zero v128) (local $ones v128)' + sLineBreak +
    '    (local.set $v (i64x2.splat (i64.const 0)))' + sLineBreak +
    '    (local.set $mask' + sLineBreak +
    '      (v128.const i64x2 81985529216486895 -81985529216486896))' +
    sLineBreak +
    '    (local.set $zero (v128.const i64x2 0 0))' + sLineBreak +
    '    (local.set $ones (v128.const i64x2 -1 -1))' + sLineBreak +
    '    (loop $l' + sLineBreak +
    '      (local.set $v (v128.not (v128.not (local.get $v))))' + sLineBreak +
    '      (local.set $v' + sLineBreak +
    '        (v128.xor (v128.xor (local.get $v) (local.get $mask))' +
    '          (local.get $mask)))' + sLineBreak +
    '      (local.set $v' + sLineBreak +
    '        (v128.and' + sLineBreak +
    '          (v128.or (local.get $v) (local.get $zero))' + sLineBreak +
    '          (local.get $ones)))' + sLineBreak +
    '      (local.set $v' + sLineBreak +
    '        (v128.andnot (local.get $v) (local.get $zero)))' + sLineBreak +
    '      (local.set $v' + sLineBreak +
    '        (i8x16.sub' + sLineBreak +
    '          (i8x16.add (local.get $v) (i8x16.splat (local.get $i)))' +
    '          (i8x16.splat (local.get $i))))' + sLineBreak +
    '      (local.set $v' + sLineBreak +
    '        (i16x8.sub' + sLineBreak +
    '          (i16x8.add (local.get $v) (i16x8.splat (local.get $i)))' +
    '          (i16x8.splat (local.get $i))))' + sLineBreak +
    '      (local.set $v' + sLineBreak +
    '        (i32x4.sub' + sLineBreak +
    '          (i32x4.add (local.get $v) (i32x4.splat (local.get $i)))' +
    '          (i32x4.splat (local.get $i))))' + sLineBreak +
    '      (local.set $v' + sLineBreak +
    '        (i64x2.sub' + sLineBreak +
    '          (i64x2.add (local.get $v)' + sLineBreak +
    '            (i64x2.splat (i64.extend_i32_u (local.get $i))))' +
    sLineBreak +
    '          (i64x2.splat (i64.extend_i32_u (local.get $i)))))' +
    sLineBreak +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' + sLineBreak +
    '      (br_if $l (i32.lt_u (local.get $i) (local.get $n))))' + sLineBreak +
    '    (i64x2.extract_lane 0 (local.get $v))))';

function CompileArtifact(const ABytes: TWasmBytes): TWasmBytes;
var
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
begin
  Loaded := LoadModule(ABytes);
  Engine := TWasmEngine.Create;
  Store := TWasmStore.Create(Engine);
  try
    Result := AotCompileModule(Store, Loaded);
  finally
    FreeAndNil(Store);
    Engine.Free;
    Loaded.Free;
  end;
end;

function MeasureExecution(const ABytes, AArtifact: TWasmBytes;
  const ATier: TExecutionTier; const AInput: Integer;
  out AResultBits: UInt64): Int64;
var
  Loaded: TWasmLoadedModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Linker: TWasmLinker;
  Instance: TWasmInstance;
  Jit: TWasmJitContext;
  LoadRes: TWasmAotLoadResult;
  RunFn: TWasmFunc;
  Params, Results: array[0..0] of TWasmValue;
  Started: Int64;
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
    if not Instance.FindExportFunc('run', RunFn) then
      raise EWasmError.Create('execution benchmark has no run export');

    case ATier of
      etJit:
        begin
          Jit := RegisterJit(Store);
          if not Jit.ForceCompile(RunFn.Addr) then
            raise EWasmError.Create('execution benchmark JIT declined run');
        end;
      etAot:
        begin
          Jit := AotLoadAndWire(Store, Loaded, Instance.Raw, AArtifact, LoadRes);
          if (LoadRes <> alrLoaded) or (Jit = nil) or
            (Store.Funcs[RunFn.Addr].CompiledEntry = nil) then
            raise EWasmError.CreateFmt(
              'execution benchmark AOT did not wire run (load result %d)',
              [Ord(LoadRes)]);
        end;
    end;

    Params[0].Bits := UInt64(UInt32(AInput));
    Results[0].Bits := 0;
    Started := GetTickCount64;
    Call(RunFn, Params, Results);
    Result := GetTickCount64 - Started;
    AResultBits := Results[0].Bits;
  finally
    Instance.Free;
    Jit.Free;
    Linker.Free;
    FreeAndNil(Store);
    Engine.Free;
    Loaded.Free;
  end;
end;

function Triangle64(const ACount: Integer): UInt64;
begin
  Result := (UInt64(UInt32(ACount)) * UInt64(UInt32(ACount - 1))) div 2;
end;

function Triangle32(const ACount: Integer): UInt32;
begin
  Result := UInt32(Triangle64(ACount) and $FFFFFFFF);
end;

function ExpectedLoop(const AIterations: Integer): UInt32;
begin
  Result := UInt32((UInt64(Triangle32(AIterations)) * UInt64(1664525)) and
    $FFFFFFFF);
end;

function ExpectedFib(const AInput: Integer): UInt32;
var
  I: Integer;
  Previous, Current, Next: UInt32;
begin
  if AInput < 2 then
    Exit(UInt32(AInput));
  Previous := 0;
  Current := 1;
  for I := 2 to AInput do
  begin
    Next := Previous + Current;
    Previous := Current;
    Current := Next;
  end;
  Result := Current;
end;

function FibCallCount(const AInput: Integer): Int64;
var
  I: Integer;
  Previous, Current, Next: Int64;
begin
  if AInput < 2 then
    Exit(1);
  Previous := 1;
  Current := 1;
  for I := 2 to AInput do
  begin
    Next := 1 + Previous + Current;
    Previous := Current;
    Current := Next;
  end;
  Result := Current;
end;

procedure BenchExecution(const AName, AWat: string; const AInput: Integer;
  const AOperationCount: Int64; const AExpected: UInt64;
  const ASampleCount: Integer; const ATiers: TExecutionTiers);
var
  Bytes, Artifact: TWasmBytes;
  Tier: TExecutionTier;
  Sample: Integer;
  Samples: TInt64Samples;
  ResultBits: UInt64;
begin
  Bytes := AssembleWatText(AWat);
  Artifact := nil;
  if etAot in ATiers then
    Artifact := CompileArtifact(Bytes);
  SetLength(Samples, ASampleCount);
  for Tier := Low(TExecutionTier) to High(TExecutionTier) do
    if Tier in ATiers then
    begin
      for Sample := 0 to ASampleCount - 1 do
      begin
        Samples[Sample] := MeasureExecution(Bytes, Artifact, Tier, AInput,
          ResultBits);
        if ResultBits <> AExpected then
          raise EWasmError.CreateFmt(
            '%s benchmark %s returned %u, expected %u',
            [AName, TierName(Tier), ResultBits, AExpected]);
      end;
      ReportStartup(AName + ' ' + TierName(Tier), AOperationCount,
        Median(Samples), ASampleCount);
    end;
end;

function ParseWorkload(const AValue: string;
  out AWorkloads: TBenchmarkWorkloads): Boolean;
begin
  Result := True;
  if AValue = 'all' then
    AWorkloads := [Low(TBenchmarkWorkload)..High(TBenchmarkWorkload)]
  else if AValue = 'decode' then
    AWorkloads := [bwDecode]
  else if (AValue = 'leb128') or (AValue = 'leb') then
    AWorkloads := [bwLeb128]
  else if AValue = 'startup' then
    AWorkloads := [bwStartup]
  else if (AValue = 'loop') or (AValue = 'execution') then
    AWorkloads := [bwLoop]
  else if AValue = 'fib' then
    AWorkloads := [bwFib]
  else if AValue = 'memory' then
    AWorkloads := [bwMemory]
  else if AValue = 'numeric' then
    AWorkloads := [bwNumeric]
  else if AValue = 'simd' then
    AWorkloads := [bwSimd]
  else
    Result := False;
end;

function ParseTiers(const AValue: string; out ATiers: TExecutionTiers): Boolean;
begin
  Result := True;
  if AValue = 'all' then
    ATiers := [Low(TExecutionTier)..High(TExecutionTier)]
  else if (AValue = 'interp') or (AValue = 'interpret') then
    ATiers := [etInterp]
  else if AValue = 'jit' then
    ATiers := [etJit]
  else if AValue = 'aot' then
    ATiers := [etAot]
  else
    Result := False;
end;

var
  Options: TOptionList;
  Positionals: TStringList;
  WorkloadOpt, TierOpt: TStringOption;
  IterationsOpt, ExecutionIterationsOpt, FibInputOpt,
    MemoryIterationsOpt, NumericIterationsOpt, SimdIterationsOpt,
    SamplesOpt: TIntegerOption;
  Workloads: TBenchmarkWorkloads;
  Tiers: TExecutionTiers;
  Iterations, ExecutionIterations, FibInput, MemoryIterations,
    NumericIterations, SimdIterations,
    SampleCount: Integer;
  WorkloadValue, TierValue: string;
begin
  Options := TOptionList.Create;
  try
    WorkloadOpt := Options.AddString('workload',
      'all|decode|leb128|startup|loop|fib|memory|numeric|simd (default: all)');
    TierOpt := Options.AddString('tier',
      'all|interp|jit|aot for execution workloads (default: all)');
    IterationsOpt := Options.AddInteger('iterations',
      'Iterations per benchmark (default: ' + IntToStr(DEFAULT_ITERATIONS) + ')');
    ExecutionIterationsOpt := Options.AddInteger('execution-iterations',
      'Loop iterations per tier (default: ' +
      IntToStr(DEFAULT_EXECUTION_ITERATIONS) + ')');
    FibInputOpt := Options.AddInteger('fib-input',
      'Recursive Fibonacci input (default: ' + IntToStr(DEFAULT_FIB_INPUT) + ')');
    MemoryIterationsOpt := Options.AddInteger('memory-iterations',
      'Scalar memory loop iterations per tier (default: ' +
      IntToStr(DEFAULT_MEMORY_ITERATIONS) + ')');
    NumericIterationsOpt := Options.AddInteger('numeric-iterations',
      'Scalar numeric loop iterations per tier (default: ' +
      IntToStr(DEFAULT_NUMERIC_ITERATIONS) + ')');
    SimdIterationsOpt := Options.AddInteger('simd-iterations',
      'SIMD loop iterations per tier (default: ' +
      IntToStr(DEFAULT_SIMD_ITERATIONS) + ')');
    SamplesOpt := Options.AddInteger('samples',
      'Samples per execution workload and tier (default: ' +
      IntToStr(DEFAULT_SAMPLES) + ')');

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
    ExecutionIterations := ExecutionIterationsOpt.ValueOr(
      DEFAULT_EXECUTION_ITERATIONS);
    FibInput := FibInputOpt.ValueOr(DEFAULT_FIB_INPUT);
    MemoryIterations := MemoryIterationsOpt.ValueOr(
      DEFAULT_MEMORY_ITERATIONS);
    NumericIterations := NumericIterationsOpt.ValueOr(
      DEFAULT_NUMERIC_ITERATIONS);
    SimdIterations := SimdIterationsOpt.ValueOr(DEFAULT_SIMD_ITERATIONS);
    SampleCount := SamplesOpt.ValueOr(DEFAULT_SAMPLES);
    WorkloadValue := LowerCase(WorkloadOpt.ValueOr('all'));
    TierValue := LowerCase(TierOpt.ValueOr('all'));
    if not ParseWorkload(WorkloadValue, Workloads) then
    begin
      WriteLn(ErrOutput, 'wasmbench: unknown workload "', WorkloadValue, '"');
      ExitCode := 1;
      Exit;
    end;
    if not ParseTiers(TierValue, Tiers) then
    begin
      WriteLn(ErrOutput, 'wasmbench: unknown tier "', TierValue, '"');
      ExitCode := 1;
      Exit;
    end;
    if Iterations <= 0 then
    begin
      WriteLn(ErrOutput, 'wasmbench: --iterations must be positive');
      ExitCode := 1;
      Exit;
    end;
    if ExecutionIterations <= 0 then
    begin
      WriteLn(ErrOutput, 'wasmbench: --execution-iterations must be positive');
      ExitCode := 1;
      Exit;
    end;
    if (FibInput < 0) or (FibInput > 40) then
    begin
      WriteLn(ErrOutput, 'wasmbench: --fib-input must be between 0 and 40');
      ExitCode := 1;
      Exit;
    end;
    if MemoryIterations <= 0 then
    begin
      WriteLn(ErrOutput, 'wasmbench: --memory-iterations must be positive');
      ExitCode := 1;
      Exit;
    end;
    if NumericIterations <= 0 then
    begin
      WriteLn(ErrOutput, 'wasmbench: --numeric-iterations must be positive');
      ExitCode := 1;
      Exit;
    end;
    if SimdIterations <= 0 then
    begin
      WriteLn(ErrOutput, 'wasmbench: --simd-iterations must be positive');
      ExitCode := 1;
      Exit;
    end;
    if SampleCount <= 0 then
    begin
      WriteLn(ErrOutput, 'wasmbench: --samples must be positive');
      ExitCode := 1;
      Exit;
    end;

    WriteLn('wasmbench ', PROGRAM_VERSION, ' — measurement only, never a CI assertion');
    WriteLn;
    if bwDecode in Workloads then
      BenchDecodeModule(Iterations);
    if bwLeb128 in Workloads then
      BenchReadU32(Iterations div 64 + 1);
    if bwStartup in Workloads then
      BenchStartup(Iterations, SampleCount, Tiers);
    if bwLoop in Workloads then
      BenchExecution('execute', BENCH_EXECUTION_WAT, ExecutionIterations,
        ExecutionIterations, ExpectedLoop(ExecutionIterations), SampleCount,
        Tiers);
    if bwFib in Workloads then
      BenchExecution('fib', BENCH_FIB_WAT, FibInput, FibCallCount(FibInput),
        ExpectedFib(FibInput), SampleCount, Tiers);
    if bwMemory in Workloads then
      BenchExecution('memory', BENCH_MEMORY_WAT, MemoryIterations,
        MemoryIterations, Triangle32(MemoryIterations), SampleCount, Tiers);
    if bwNumeric in Workloads then
      BenchExecution('numeric', BENCH_NUMERIC_WAT, NumericIterations,
        NumericIterations, UInt64(NumericIterations) * UInt64(1975333344) +
        UInt64(4) * Triangle64(NumericIterations), SampleCount, Tiers);
    if bwSimd in Workloads then
      BenchExecution('simd', BENCH_SIMD_WAT, SimdIterations, SimdIterations,
        0, SampleCount, Tiers);
  finally
    Options.Free;
  end;
end.
