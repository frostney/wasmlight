{ wasmlight-shell — the prebuilt, interpreter-free runtime-shell template.

  This program is the Pascal executable `wasmlight compile` populates by
  attaching a native-executable payload into an ELF or Mach-O image.
  The unfilled template also keeps the attach seam for tests:

    - no arguments: use the embedded payload (empty in the template);
    - first argument is a `.wshl` payload file when the embed is empty;
      remaining arguments are the guest argv;
    - when a payload is embedded, every argument is guest argv.

  There are no Wasmlight runtime flags (`--dir`, `--env`, `--aot`). Compiled
  `--dir`/`--env` values live in the payload; an empty capability set is
  deny-by-default WASI (stdio + clock + random, no preopens, no environment).

  The program does not use Wasm.Interp dispatch, Wasm.Jit compile, or
  Wasm.Aot compile. Startup always re-decodes and re-validates. }
program wasmlight_shell;

{$I Shared.inc}

(* The build entry passes -dWASM_RUNTIME_SHELL so Wasm.Engine omits
   RegisterInterpreter / InterpInvoke. GNU ld otherwise keeps InterpTierInvoke;
   Darwin already dead-strips it. A program-file DEFINE does not reach units,
   so this file must not declare one. Do not put this define in Shared.inc. *)

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,

  Wasm.Core,
  Wasm.Shell,
  Wasm.Wasi;

{ The packaging path writes a non-empty blob into the ELF trailer or
  Mach-O `__WSHL,__payload` of this executable. The template keeps the
  Pascal embed empty so `lwpt build` produces a reusable shell. }
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
    ExtractPackagedPayloadFromFile(ParamStr(0), Payload);
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
