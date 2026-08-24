{ Wasm.Compile.Capabilities — the immutable compiled WASI capability set
  ([ADR-0015](docs/adr/0015-strict-native-compiler-and-runtime-shell.md)).

  `wasmlight compile` will embed this set in a generated executable. Generated
  programs expose no Wasmlight runtime flags: every invocation argument belongs
  to the guest, environment values are exactly the compiled KEY=VALUE pairs
  (never the process environment), and preopens are exactly the compiled
  GUEST=HOST mappings. Relative host directories resolve from the executable
  directory at apply time; absolute host paths stay literal.

  Embedded environment values are visible in the executable and are not a
  secret mechanism.

  This unit is the compile-time model and the runtime apply seam. It does not
  own the compile CLI (#39), the native payload container (#35), or the
  interpreter-free shell (#34). Containment, symlink-escape, and rights
  masking stay in Wasm.Wasi — ApplyToConfig only installs the same preopen
  fields `wasmlight run --dir` would.

  DENY-BY-DEFAULT. A default set grants no directories and no environment.
  ApplyToConfig refuses a config that already has preopens or env, so a
  generated startup path cannot widen the compiled set. Clock, random, and
  stdio remain TWasmWasiConfig's existing defaults.

  Layering: host surface, beside Wasm.Run. Depends on Wasm.Wasi and
  Wasm.Wasi.Types only. }
unit Wasm.Compile.Capabilities;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Wasi,
  Wasm.Wasi.Types;

const
  { Directory rights granted to a compiled preopen. Same bundle as
    WASM_RUN_DIR_RIGHTS so a compiled `--dir` is observationally identical
    to `wasmlight run --dir`. }
  WASM_COMPILED_DIR_RIGHTS: TWasmWasiRights = UInt64($1FFFFFFF);

type
  { One compiled preopen, stored as the compile-time GUEST=HOST pair. HostPath
    is unresolved: a relative value is still relative until ApplyToConfig. }
  TWasmCompiledPreopen = record
    GuestPath: string;
    HostPath: string;
  end;
  TWasmCompiledPreopenArray = array of TWasmCompiledPreopen;

  { The immutable compiled capability set. Mutable only until Freeze or the
    first successful ApplyToConfig. }
  TWasmCompiledCapabilities = class
  private
    FPreopens: TWasmCompiledPreopenArray;
    FEnv: TArray<string>;
    FFrozen: Boolean;
    function EnsureMutable(out AError: string): Boolean;
  public
    constructor Create;

    function TryAddDirSpec(const ASpec: string; out AError: string): Boolean;
    function TryAddDir(const AGuest, AHost: string;
      out AError: string): Boolean;
    function TryAddEnvSpec(const ASpec: string; out AError: string): Boolean;

    procedure Freeze;
    property Frozen: Boolean read FFrozen;

    function PreopenCount: Integer;
    function PreopenAt(const AIndex: Integer): TWasmCompiledPreopen;
    function EnvCount: Integer;
    function EnvAt(const AIndex: Integer): string;

    { Install exactly this set on a deny-by-default config. Resolves relative
      host paths against the directory of AExecutablePath. Sets argv to the
      executable basename followed by AInvocationArgs, including flag-shaped
      tokens. Does not read the process environment. }
    function ApplyToConfig(const AConfig: TWasmWasiConfig;
      const AExecutablePath: string; const AInvocationArgs: array of string;
      out AError: string): Boolean;
  end;

{ Split `GUEST=HOST`. Same errors `wasmlight run --dir` already reports. }
function TryParseCompiledDirSpec(const ASpec: string;
  out AGuest, AHost, AError: string): Boolean;

{ Accept `KEY=VALUE` (empty VALUE is allowed; empty KEY is not). The returned
  pair is the original spec so a value may itself contain `=`. }
function TryParseCompiledEnvSpec(const ASpec: string;
  out AKeyValue, AError: string): Boolean;

{ Host-absolute according to THIS process. Runtime apply uses this: a path
  compiled on another OS is classified again on the executable's host. }
function CompiledHostPathIsAbsolute(const APath: string): Boolean;

{ POSIX / Windows classifiers so both families have tests before those
  compiler targets ship. }
function CompiledHostPathIsUnixAbsolute(const APath: string): Boolean;
function CompiledHostPathIsWindowsAbsolute(const APath: string): Boolean;

{ ExtractFilePath of the executable. Empty when AExecutablePath has no
  directory component. }
function CompiledExecutableDir(const AExecutablePath: string): string;

{ Join a relative host path to AExecutableDir. An absolute AHostPath is
  returned unchanged — no ExpandFileName, so CWD never participates. }
function TryResolveCompiledHostPath(const AHostPath, AExecutableDir: string;
  out AResolved, AError: string): Boolean;

{ argv[0] is the executable basename; every remaining token is a guest
  argument. Nothing is reserved for Wasmlight. }
function CompiledGuestArgv(const AExecutablePath: string;
  const AInvocationArgs: array of string): TArray<string>;

implementation

function HasEmbeddedNul(const AValue: string): Boolean;
begin
  Result := Pos(#0, AValue) > 0;
end;

function TryParseCompiledDirSpec(const ASpec: string;
  out AGuest, AHost, AError: string): Boolean;
var
  EqPos: Integer;
begin
  AGuest := '';
  AHost := '';
  AError := '';
  EqPos := Pos('=', ASpec);
  if EqPos <= 1 then
  begin
    AError := 'invalid --dir "' + ASpec + '": expected GUEST=HOST';
    Exit(False);
  end;
  AGuest := Copy(ASpec, 1, EqPos - 1);
  AHost := Copy(ASpec, EqPos + 1, MaxInt);
  if AHost = '' then
  begin
    AError := 'invalid --dir "' + ASpec + '": HOST path is empty';
    Exit(False);
  end;
  if HasEmbeddedNul(AGuest) or HasEmbeddedNul(AHost) then
  begin
    AError := 'invalid --dir "' + ASpec + '": path contains a NUL';
    Exit(False);
  end;
  Result := True;
end;

function TryParseCompiledEnvSpec(const ASpec: string;
  out AKeyValue, AError: string): Boolean;
var
  EqPos: Integer;
begin
  AKeyValue := '';
  AError := '';
  EqPos := Pos('=', ASpec);
  if EqPos <= 1 then
  begin
    AError := 'invalid --env "' + ASpec + '": expected KEY=VALUE';
    Exit(False);
  end;
  if HasEmbeddedNul(ASpec) then
  begin
    AError := 'invalid --env "' + ASpec + '": value contains a NUL';
    Exit(False);
  end;
  AKeyValue := ASpec;
  Result := True;
end;

function CompiledHostPathIsUnixAbsolute(const APath: string): Boolean;
begin
  Result := (Length(APath) > 0) and (APath[1] = '/');
end;

function CompiledHostPathIsWindowsAbsolute(const APath: string): Boolean;
begin
  { Drive-letter form: C:\data or C:/data. }
  if (Length(APath) >= 3) and (APath[1] in ['A'..'Z', 'a'..'z']) and
    (APath[2] = ':') and (APath[3] in ['\', '/']) then
    Exit(True);
  { UNC: \\server\share (either separator). }
  if (Length(APath) >= 2) and (APath[1] in ['\', '/']) and
    (APath[2] in ['\', '/']) then
    Exit(True);
  Result := False;
end;

function CompiledHostPathIsAbsolute(const APath: string): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := CompiledHostPathIsWindowsAbsolute(APath);
  {$ELSE}
  Result := CompiledHostPathIsUnixAbsolute(APath);
  {$ENDIF}
end;

function CompiledExecutableDir(const AExecutablePath: string): string;
begin
  Result := ExtractFilePath(AExecutablePath);
end;

function TryResolveCompiledHostPath(const AHostPath, AExecutableDir: string;
  out AResolved, AError: string): Boolean;
begin
  AResolved := '';
  AError := '';
  if AHostPath = '' then
  begin
    AError := 'HOST path is empty';
    Exit(False);
  end;
  if CompiledHostPathIsAbsolute(AHostPath) then
  begin
    AResolved := AHostPath;
    Exit(True);
  end;
  if AExecutableDir = '' then
  begin
    AError := 'relative host path requires the executable directory';
    Exit(False);
  end;
  { Join only. ExpandFileName would consult CWD, which relocation forbids. }
  AResolved := IncludeTrailingPathDelimiter(AExecutableDir) + AHostPath;
  Result := True;
end;

function CompiledGuestArgv(const AExecutablePath: string;
  const AInvocationArgs: array of string): TArray<string>;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, 1 + Length(AInvocationArgs));
  Result[0] := ExtractFileName(AExecutablePath);
  for Index := 0 to High(AInvocationArgs) do
    Result[Index + 1] := AInvocationArgs[Index];
end;

constructor TWasmCompiledCapabilities.Create;
begin
  inherited Create;
  FPreopens := nil;
  FEnv := nil;
  FFrozen := False;
end;

function TWasmCompiledCapabilities.EnsureMutable(out AError: string): Boolean;
begin
  AError := '';
  if FFrozen then
  begin
    AError := 'compiled capability set is frozen';
    Exit(False);
  end;
  Result := True;
end;

function TWasmCompiledCapabilities.TryAddDir(const AGuest, AHost: string;
  out AError: string): Boolean;
var
  Entry: TWasmCompiledPreopen;
begin
  if not EnsureMutable(AError) then
    Exit(False);
  if AGuest = '' then
  begin
    AError := 'invalid --dir: guest path is empty';
    Exit(False);
  end;
  if AHost = '' then
  begin
    AError := 'invalid --dir: HOST path is empty';
    Exit(False);
  end;
  if HasEmbeddedNul(AGuest) or HasEmbeddedNul(AHost) then
  begin
    AError := 'invalid --dir: path contains a NUL';
    Exit(False);
  end;
  Entry.GuestPath := AGuest;
  Entry.HostPath := AHost;
  SetLength(FPreopens, Length(FPreopens) + 1);
  FPreopens[High(FPreopens)] := Entry;
  Result := True;
end;

function TWasmCompiledCapabilities.TryAddDirSpec(const ASpec: string;
  out AError: string): Boolean;
var
  Guest, Host: string;
begin
  if not TryParseCompiledDirSpec(ASpec, Guest, Host, AError) then
    Exit(False);
  Result := TryAddDir(Guest, Host, AError);
end;

function TWasmCompiledCapabilities.TryAddEnvSpec(const ASpec: string;
  out AError: string): Boolean;
var
  KeyValue: string;
begin
  if not EnsureMutable(AError) then
    Exit(False);
  if not TryParseCompiledEnvSpec(ASpec, KeyValue, AError) then
    Exit(False);
  SetLength(FEnv, Length(FEnv) + 1);
  FEnv[High(FEnv)] := KeyValue;
  Result := True;
end;

procedure TWasmCompiledCapabilities.Freeze;
begin
  FFrozen := True;
end;

function TWasmCompiledCapabilities.PreopenCount: Integer;
begin
  Result := Length(FPreopens);
end;

function TWasmCompiledCapabilities.PreopenAt(const AIndex: Integer):
  TWasmCompiledPreopen;
begin
  Result := FPreopens[AIndex];
end;

function TWasmCompiledCapabilities.EnvCount: Integer;
begin
  Result := Length(FEnv);
end;

function TWasmCompiledCapabilities.EnvAt(const AIndex: Integer): string;
begin
  Result := FEnv[AIndex];
end;

function TWasmCompiledCapabilities.ApplyToConfig(const AConfig: TWasmWasiConfig;
  const AExecutablePath: string; const AInvocationArgs: array of string;
  out AError: string): Boolean;
var
  Index: Integer;
  ExeDir: string;
  ResolvedHosts: TArray<string>;
  Argv: TArray<string>;
begin
  AError := '';
  if AConfig = nil then
  begin
    AError := 'a compiled capability set needs a WASI config';
    Exit(False);
  end;
  { A generated startup path starts from TWasmWasiConfig.Create (stdio +
    clock + random only). Anything already on Preopens/Env would widen the
    compiled set. }
  if Length(AConfig.Preopens) > 0 then
  begin
    AError := 'cannot expand a compiled capability set';
    Exit(False);
  end;
  if Length(AConfig.Env) > 0 then
  begin
    AError := 'cannot expand a compiled capability set';
    Exit(False);
  end;

  { Resolve every host path before mutating the config so a later relative
    path cannot leave a prefix of the set installed. }
  ExeDir := CompiledExecutableDir(AExecutablePath);
  SetLength(ResolvedHosts, Length(FPreopens));
  for Index := 0 to High(FPreopens) do
    if not TryResolveCompiledHostPath(FPreopens[Index].HostPath, ExeDir,
      ResolvedHosts[Index], AError) then
      Exit(False);

  for Index := 0 to High(FPreopens) do
    AConfig.AddPreopenDir(FPreopens[Index].GuestPath, ResolvedHosts[Index],
      WASM_COMPILED_DIR_RIGHTS);
  for Index := 0 to High(FEnv) do
    AConfig.AddEnv(FEnv[Index]);

  Argv := CompiledGuestArgv(AExecutablePath, AInvocationArgs);
  AConfig.SetArgv(Argv);
  FFrozen := True;
  Result := True;
end;

end.
