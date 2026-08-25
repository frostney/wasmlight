{ wasmlight-shell — the prebuilt, interpreter-free runtime-shell template.

  This program is the Pascal executable `wasmlight compile` will later
  populate (#39) by attaching a payload (#35) into an ELF or Mach-O
  image (#36/#37). Today it is the template plus the attach seam:

    - no arguments: use the embedded payload (empty in the template);
    - first argument is a `.wshl` payload file when the embed is empty;
      remaining arguments are the guest argv;
    - when a payload is embedded, every argument is guest argv.

  There are no Wasmlight runtime flags (`--dir`, `--env`, `--aot`). The
  compiled capability set is a stub: deny-by-default WASI (stdio + clock
  + random, no preopens, no environment). #40 owns embedding those values.

  The program does not use Wasm.Interp dispatch, Wasm.Jit compile, or
  Wasm.Aot compile. Startup always re-decodes and re-validates. }
program wasmlight_shell;

{$I Shared.inc}

{ The build entry also passes -dWASM_RUNTIME_SHELL. Engine uses that to omit
  RegisterInterpreter / InterpInvoke so GNU ld cannot keep InterpTierInvoke
  (Darwin already dead-strips it). A program-file {$DEFINE} does not reach
  units; do not put the define in Shared.inc. }
{$DEFINE WASM_RUNTIME_SHELL}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,

  Wasm.Core,
  Wasm.Shell,
  Wasm.Wasi;

{ The packaging issues write a non-empty blob here. The template keeps it
  empty so `lwpt build` produces a reusable shell. }
function EmbeddedPayload: TWasmBytes;
begin
  Result := nil;
end;

var
  Payload: TWasmBytes;
  Config: TWasmWasiConfig;
  OsIn: TWasmShellOsInStream;
  OsOut, OsErr: TWasmShellOsOutStream;
  Res: TWasmShellResult;
  Guest: array of string;
  I, GuestStart: Integer;
  AttachPath: string;
begin
  Payload := EmbeddedPayload;
  GuestStart := 1;
  AttachPath := '';
  if Length(Payload) = 0 then
  begin
    if ParamCount < 1 then
    begin
      WriteLn(ErrOutput, PROGRAM_NAME +
        '-shell: runtime shell has no embedded module');
      Halt(WASM_SHELL_EXIT_ERROR);
    end;
    AttachPath := ParamStr(1);
    GuestStart := 2;
  end;

  SetLength(Guest, ParamCount - GuestStart + 1);
  for I := 0 to High(Guest) do
    Guest[I] := ParamStr(GuestStart + I);

  Config := TWasmWasiConfig.Create;
  OsIn := TWasmShellOsInStream.Create(StdInputHandle);
  OsOut := TWasmShellOsOutStream.Create(StdOutputHandle);
  OsErr := TWasmShellOsOutStream.Create(StdErrorHandle);
  try
    Config.Stdin := OsIn;
    Config.Stdout := OsOut;
    Config.Stderr := OsErr;
    Config.SetArgv(Guest);
    if AttachPath <> '' then
      Res := RunShellFile(AttachPath, Config)
    else
      Res := RunShellBytes(Payload, Config);
  finally
    Config.Free;
    OsIn.Free;
    OsOut.Free;
    OsErr.Free;
  end;

  if Res.Diagnostic <> '' then
    WriteLn(ErrOutput, PROGRAM_NAME + '-shell: ' + Res.Diagnostic);
  Halt(Res.ExitCode);
end.
