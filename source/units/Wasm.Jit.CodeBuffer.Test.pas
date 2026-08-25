{ Unit suite for Wasm.Jit.CodeBuffer — the Track I de-risking proof.

  THE POINT of this suite (.agent/design/jit-spec.md §12.2/§12.3 Wave 1): show
  that on this host a JIT-emitted machine-code function can be written, made
  executable, cache-flushed, and CALLED, returning the right value. If the
  executable-memory machinery does not work here the whole track is blocked, so
  the execute tests below are the go/no-go — on aarch64-darwin (the dev host)
  they MUST run and pass.

  The hand-emitted A64 and x86-64 encodings were cross-checked against clang's
  assembler on this host and are cited byte-for-byte at each emission:
    movz w0,#42       = 0x52800540   (verified: clang -arch arm64)
    ret               = 0xD65F03C0   (verified)
    add  w0,w0,w1     = 0x0B010000   (verified)
    mov  eax,42       = B8 2A 00 00 00 (verified: clang -arch x86_64)
    ret               = C3           (verified)
    lea  eax,[rdi+rsi]= 8D 04 37      (verified)

  Emission/label/patch tests are pure Pascal and run on every target; the
  execute tests are gated to the (OS, arch) leg whose bytes they emit, and the
  unsupported-target test asserts MakeExecutable refuses cleanly — so the suite
  is green on all six CI targets while proving execution where it is possible.

  FPC gotchas observed (AGENTS.md testing notes): a generic Expect<T>(...) is
  never the lone statement of an `on ... do` (the exception-catching test sets
  flags in the handler and asserts them afterward), and every test records at
  least one assertion. }
program Wasm.Jit.CodeBuffer.Test;

{$I Shared.inc}

{ Recompute the same support predicate the unit uses (define symbols do not
  cross unit boundaries): a 64-bit UNIX host with a shipped backend. }
{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Jit.CodeBuffer;

type
  { The ABIs the emitted code follows. cdecl selects the platform C
    convention: on aarch64 (AAPCS64) integer args arrive in x0/x1 and the
    result leaves in w0/x0; on x86-64 SysV the first two args are in
    edi/esi and the result in eax — exactly what the hand-emitted code uses. }
  TWasmJitConstFn = function: UInt32; cdecl;
  TWasmJitBinFn = function(const A, B: UInt32): UInt32; cdecl;

  TCodeBufferTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestEmitLittleEndian;
    procedure TestEmitBytesAndByte;
    procedure TestLabelPatchResolution;
    procedure TestInsertU32ShiftsLabelsAndPatches;

    procedure TestSupportedReportsTrueOrFalse;

    procedure TestExecReturnsConst;
    procedure TestExecAddsArgs;
    procedure TestExecPatchThenRun;

    procedure TestExecReturnsConstX64;
    procedure TestExecAddsArgsX64;

    procedure TestUnsupportedRaises;
  end;

{ --- emission primitives (portable) ------------------------------------- }

procedure TCodeBufferTests.TestEmitLittleEndian;
var
  Buf: TWasmCodeBuffer;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitU32($AABBCCDD);
    Expect<Integer>(Buf.Size).ToBe(4);
    { Little-endian: least-significant byte first. }
    Expect<Byte>(Buf.ByteAt(0)).ToBe($DD);
    Expect<Byte>(Buf.ByteAt(1)).ToBe($CC);
    Expect<Byte>(Buf.ByteAt(2)).ToBe($BB);
    Expect<Byte>(Buf.ByteAt(3)).ToBe($AA);

    Buf.EmitU64($0102030405060708);
    Expect<Integer>(Buf.Size).ToBe(12);
    Expect<Byte>(Buf.ByteAt(4)).ToBe($08);
    Expect<Byte>(Buf.ByteAt(5)).ToBe($07);
    Expect<Byte>(Buf.ByteAt(11)).ToBe($01);
  finally
    Buf.Free;
  end;
end;

procedure TCodeBufferTests.TestEmitBytesAndByte;
var
  Buf: TWasmCodeBuffer;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitByte($90);
    Buf.EmitBytes([$DE, $AD, $BE, $EF]);
    Expect<Integer>(Buf.Size).ToBe(5);
    Expect<Byte>(Buf.ByteAt(0)).ToBe($90);
    Expect<Byte>(Buf.ByteAt(1)).ToBe($DE);
    Expect<Byte>(Buf.ByteAt(4)).ToBe($EF);
    { Geometric growth past the initial capacity keeps the bytes intact. }
    Buf.EmitBytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    Expect<Integer>(Buf.Size).ToBe(15);
    Expect<Byte>(Buf.ByteAt(14)).ToBe(10);
  finally
    Buf.Free;
  end;
end;

procedure TCodeBufferTests.TestLabelPatchResolution;
var
  Buf: TWasmCodeBuffer;
  L: TWasmJitLabel;
  Site: Integer;
begin
  { Model a forward branch: a placeholder branch word at Site, then two filler
    words, then the branch target. The label map must resolve the site->target
    displacement to +12 bytes, and PatchU32 must overwrite the placeholder. }
  Buf := TWasmCodeBuffer.Create;
  try
    L := Buf.NewLabel;
    Expect<Boolean>(Buf.LabelBound(L)).ToBe(False);

    Site := Buf.CurrentOffset;
    Expect<Integer>(Site).ToBe(0);
    Buf.EmitU32($14000000);            { A64 'b' with imm26=0 (placeholder) }
    Buf.AddPatch(Site, L, 0);

    Buf.EmitU32($D503201F);            { nop }
    Buf.EmitU32($D503201F);            { nop }

    Buf.BindLabel(L);                  { target lands at offset 12 }
    Expect<Boolean>(Buf.LabelBound(L)).ToBe(True);
    Expect<Integer>(Buf.LabelOffset(L)).ToBe(12);

    Expect<Integer>(Buf.PatchCount).ToBe(1);
    Expect<Integer>(Buf.GetPatch(0).SiteOffset).ToBe(0);
    Expect<Integer>(Buf.GetPatch(0).Target).ToBe(L);
    { The resolved byte displacement the encoder turns into instruction bits. }
    Expect<Integer>(Buf.PatchDelta(0)).ToBe(12);

    { Encoder step (simulated): A64 'b' takes a word displacement, so imm26 =
      12 div 4 = 3, giving 0x14000003. PatchU32 writes it in place. }
    Buf.PatchU32(Site, $14000003);
    Expect<Byte>(Buf.ByteAt(0)).ToBe($03);
    Expect<Byte>(Buf.ByteAt(3)).ToBe($14);
  finally
    Buf.Free;
  end;
end;

procedure TCodeBufferTests.TestInsertU32ShiftsLabelsAndPatches;
var
  Buf: TWasmCodeBuffer;
  L: TWasmJitLabel;
begin
  { A veneer insert at offset 4 must move later labels and later patch sites
    by 4 bytes, leave an earlier patch site in place, and write the word
    little-endian. }
  Buf := TWasmCodeBuffer.Create;
  try
    L := Buf.NewLabel;
    Buf.EmitU32($14000000);
    Buf.AddPatch(0, L, 1);
    Buf.EmitU32($AABBCCDD);
    Buf.AddPatch(4, L, 2);
    Buf.BindLabel(L);
    Expect<Integer>(Buf.Size).ToBe(8);
    Expect<Integer>(Buf.LabelOffset(L)).ToBe(8);
    Expect<Integer>(Buf.GetPatch(1).SiteOffset).ToBe(4);

    Buf.InsertU32(4, $04030201);
    Expect<Integer>(Buf.Size).ToBe(12);
    Expect<Byte>(Buf.ByteAt(4)).ToBe($01);
    Expect<Byte>(Buf.ByteAt(5)).ToBe($02);
    Expect<Byte>(Buf.ByteAt(6)).ToBe($03);
    Expect<Byte>(Buf.ByteAt(7)).ToBe($04);
    Expect<Byte>(Buf.ByteAt(8)).ToBe($DD);
    Expect<Byte>(Buf.ByteAt(11)).ToBe($AA);
    Expect<Integer>(Buf.GetPatch(0).SiteOffset).ToBe(0);
    Expect<Integer>(Buf.GetPatch(1).SiteOffset).ToBe(8);
    Expect<Integer>(Buf.LabelOffset(L)).ToBe(12);
  finally
    Buf.Free;
  end;
end;

procedure TCodeBufferTests.TestSupportedReportsTrueOrFalse;
begin
  { A trivial but real assertion so this always-registered probe records one:
    on this build the predicate matches the compiled leg. }
  {$IFDEF WASM_JIT_EXEC}
  Expect<Boolean>(JitExecMemSupported).ToBe(True);
  {$ELSE}
  Expect<Boolean>(JitExecMemSupported).ToBe(False);
  {$ENDIF}
end;

{ --- the proof: execute JIT'd code (aarch64) ---------------------------- }

procedure TCodeBufferTests.TestExecReturnsConst;
var
  Buf: TWasmCodeBuffer;
  Fn: TWasmJitConstFn;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitU32($52800540);   { movz w0, #42 }
    Buf.EmitU32($D65F03C0);   { ret }
    Buf.MakeExecutable;
    Expect<Boolean>(Buf.IsExecutable).ToBe(True);
    Expect<Boolean>(Buf.EntryPoint <> nil).ToBe(True);
    Fn := TWasmJitConstFn(Buf.EntryPoint);
    Expect<UInt32>(Fn()).ToBe(42);
  finally
    Buf.Free;
  end;
end;

procedure TCodeBufferTests.TestExecAddsArgs;
var
  Buf: TWasmCodeBuffer;
  Fn: TWasmJitBinFn;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitU32($0B010000);   { add w0, w0, w1  (args in w0/w1, AAPCS64) }
    Buf.EmitU32($D65F03C0);   { ret }
    Buf.MakeExecutable;
    Fn := TWasmJitBinFn(Buf.EntryPoint);
    Expect<UInt32>(Fn(17, 25)).ToBe(42);
  finally
    Buf.Free;
  end;
end;

procedure TCodeBufferTests.TestExecPatchThenRun;
var
  Buf: TWasmCodeBuffer;
  Fn: TWasmJitConstFn;
begin
  { Prove the write-while-writable patch path end to end: emit movz w0,#0, then
    PatchU32 the immediate to #42 before finalizing, then run. }
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitU32($52800000);   { movz w0, #0 }
    Buf.EmitU32($D65F03C0);   { ret }
    Buf.PatchU32(0, $52800540); { rewrite to movz w0, #42 }
    Buf.MakeExecutable;
    Fn := TWasmJitConstFn(Buf.EntryPoint);
    Expect<UInt32>(Fn()).ToBe(42);
  finally
    Buf.Free;
  end;
end;

{ --- the proof: execute JIT'd code (x86-64) ----------------------------- }

procedure TCodeBufferTests.TestExecReturnsConstX64;
var
  Buf: TWasmCodeBuffer;
  Fn: TWasmJitConstFn;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitBytes([$B8, $2A, $00, $00, $00]);   { mov eax, 42 }
    Buf.EmitByte($C3);                          { ret }
    Buf.MakeExecutable;
    Fn := TWasmJitConstFn(Buf.EntryPoint);
    Expect<UInt32>(Fn()).ToBe(42);
  finally
    Buf.Free;
  end;
end;

procedure TCodeBufferTests.TestExecAddsArgsX64;
var
  Buf: TWasmCodeBuffer;
  Fn: TWasmJitBinFn;
begin
  Buf := TWasmCodeBuffer.Create;
  try
    Buf.EmitBytes([$8D, $04, $37]);   { lea eax, [rdi+rsi]  (args edi/esi, SysV) }
    Buf.EmitByte($C3);                { ret }
    Buf.MakeExecutable;
    Fn := TWasmJitBinFn(Buf.EntryPoint);
    Expect<UInt32>(Fn(17, 25)).ToBe(42);
  finally
    Buf.Free;
  end;
end;

{ --- unsupported target refuses cleanly --------------------------------- }

procedure TCodeBufferTests.TestUnsupportedRaises;
var
  Buf: TWasmCodeBuffer;
  Raised: Boolean;
  Msg: string;
begin
  Buf := TWasmCodeBuffer.Create;
  Raised := False;
  Msg := '';
  try
    Buf.EmitU32($00000000);   { any bytes; the JIT is unsupported on this leg }
    try
      Buf.MakeExecutable;
    except
      on E: EWasmError do
      begin
        Raised := True;
        Msg := E.Message;
      end;
    end;
  finally
    Buf.Free;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Expect<Boolean>(Pos(MSG_JIT_UNSUPPORTED, Msg) = 1).ToBe(True);
end;

procedure TCodeBufferTests.SetupTests;
begin
  Test('emit words are little-endian', TestEmitLittleEndian);
  Test('emit byte and byte array grow geometrically', TestEmitBytesAndByte);
  Test('label map resolves a forward branch offset', TestLabelPatchResolution);
  Test('InsertU32 shifts later labels and patch sites',
    TestInsertU32ShiftsLabelsAndPatches);
  Test('support predicate matches the compiled leg',
    TestSupportedReportsTrueOrFalse);

  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  Test('executes JIT movz w0,#42; ret -> 42', TestExecReturnsConst);
  Test('executes JIT add w0,w0,w1 with (17,25) -> 42', TestExecAddsArgs);
  Test('executes JIT code patched while writable -> 42', TestExecPatchThenRun);
  {$ENDIF}

  {$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUX86_64)}
  Test('executes JIT mov eax,42; ret -> 42', TestExecReturnsConstX64);
  Test('executes JIT lea eax,[rdi+rsi] with (17,25) -> 42',
    TestExecAddsArgsX64);
  {$ENDIF}

  {$IFNDEF WASM_JIT_EXEC}
  Test('MakeExecutable refuses on an unsupported target',
    TestUnsupportedRaises);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TCodeBufferTests.Create('Wasm.Jit.CodeBuffer'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
