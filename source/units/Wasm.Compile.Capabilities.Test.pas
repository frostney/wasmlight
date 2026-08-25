{ Unit suite for Wasm.Compile.Capabilities — the immutable compiled WASI
  capability set (ADR-0015, issue #40).

  These tests drive the compile-time model and the apply seam, not the
  compile CLI. Relocation, absolute-path, argv, environment, and
  containment are asserted here; preopen containment goes through the
  shipped Wasm.Wasi path_open so symlink-escape and `..` match the host
  module. Nothing inherits the process environment. }
program Wasm.Compile.Capabilities.Test;

{$I Shared.inc}

uses
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}

  TestingPascalLibrary,
  Wasm.Compile.Capabilities,
  Wasm.Core,
  Wasm.Engine,
  Wasm.Run,
  Wasm.Runtime.Store,
  Wasm.Runtime.Values,
  Wasm.Wasi,
  Wasm.Wasi.Types,
  Wasm.Wat.Assembler;

const
  { Minimal guest that forwards the WASI funcs this suite observes. }
  CAPS_WAT =
    '(module' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "args_get"' + sLineBreak +
    '    (func $args_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "args_sizes_get"' + sLineBreak +
    '    (func $args_sizes_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "environ_get"' + sLineBreak +
    '    (func $environ_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "environ_sizes_get"' + sLineBreak +
    '    (func $environ_sizes_get (param i32 i32) (result i32)))' + sLineBreak +
    '  (import "wasi_snapshot_preview1" "path_open"' + sLineBreak +
    '    (func $path_open' + sLineBreak +
    '      (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))'
    + sLineBreak +
    '  (memory (export "memory") 1)' + sLineBreak +
    '  (func (export "w_args_get") (param i32 i32) (result i32)' +
    sLineBreak + '    (call $args_get (local.get 0) (local.get 1)))'
    + sLineBreak +
    '  (func (export "w_args_sizes_get") (param i32 i32) (result i32)' +
    sLineBreak + '    (call $args_sizes_get (local.get 0) (local.get 1)))'
    + sLineBreak +
    '  (func (export "w_environ_get") (param i32 i32) (result i32)' +
    sLineBreak + '    (call $environ_get (local.get 0) (local.get 1)))'
    + sLineBreak +
    '  (func (export "w_environ_sizes_get") (param i32 i32) (result i32)'
    + sLineBreak +
    '    (call $environ_sizes_get (local.get 0) (local.get 1)))' +
    sLineBreak +
    '  (func (export "w_path_open")' + sLineBreak +
    '    (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)' +
    sLineBreak +
    '    (call $path_open (local.get 0) (local.get 1) (local.get 2)' +
    ' (local.get 3) (local.get 4) (local.get 5) (local.get 6)' +
    ' (local.get 7) (local.get 8))))';

type
  { A one-shot WASI instantiation over an applied capability set. }
  TWasiProbe = class
  private
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FLoaded: TWasmLoadedModule;
    FLinker: TWasmLinker;
    FInstance: TWasmInstance;
    FContext: TWasmWasiContext;
    FMem: TWasmMemoryRef;
  public
    destructor Destroy; override;
    procedure Open(const AConfig: TWasmWasiConfig);
    function PathOpen(const ADirFd: UInt32; const APath: string;
      out AOpenedFd: UInt32): Int32;
    function EnvironCount: UInt32;
    function ArgsCount: UInt32;
    function GuestByte(const AOffset: UInt64): Byte;
    procedure GuestPutStr(const AOffset: UInt64; const AStr: string);
    function Wrapper(const AName: string): TWasmFunc;
    property Mem: TWasmMemoryRef read FMem;
  end;

  TCompileCapabilitiesTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestDefaultDeniesFilesystemAndEnv;
    procedure TestApplyEmptySetIsDenyByDefault;
    procedure TestParseDirAndEnv;
    procedure TestParseDirAndEnvRejects;
    procedure TestFrozenCannotGrow;
    procedure TestRelativeHostResolvesFromExecutableDir;
    procedure TestRelativeHostIgnoresCwd;
    procedure TestAbsoluteHostStaysLiteral;
    procedure TestRelocationChangesResolvedHost;
    procedure TestUnixAndWindowsAbsoluteForms;
    procedure TestGuestArgvForwardsEveryToken;
    procedure TestApplyDoesNotInheritProcessEnv;
    procedure TestApplyRefusesExistingCapabilities;
    procedure TestApplyFailureLeavesConfigEmpty;
    procedure TestCompiledRightsMatchRun;
    procedure TestApplyArgvAndEnvReachWasi;
    procedure TestContainmentDotDot;
    {$IFDEF UNIX}
    procedure TestContainmentEscapingSymlink;
    {$ENDIF}
  end;

function MakeTempDir(const APrefix: string): string;
var
  Base: string;
  Attempt: Integer;
begin
  Base := IncludeTrailingPathDelimiter(GetTempDir);
  for Attempt := 0 to 999 do
  begin
    Result := Base + APrefix + IntToStr(GetTickCount64) + '_' +
      IntToStr(Attempt);
    if not DirectoryExists(Result) and not FileExists(Result) then
      if CreateDir(Result) then
        Exit;
  end;
  raise EWasmError.Create('could not create a unique temp dir for the test');
end;

procedure RemoveTree(const APath: string);
var
  Sr: TSearchRec;
  Full: string;
begin
  if not DirectoryExists(APath) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, Sr) = 0
  then
  begin
    try
      repeat
        if (Sr.Name = '.') or (Sr.Name = '..') then
          Continue;
        Full := IncludeTrailingPathDelimiter(APath) + Sr.Name;
        {$PUSH}{$WARN SYMBOL_PLATFORM OFF}
        {$IFDEF UNIX}
        if ((Sr.Attr and faDirectory) <> 0) and
          (fpReadLink(RawByteString(Full)) = '') then
        {$ELSE}
        if ((Sr.Attr and faDirectory) <> 0) and
          ((Sr.Attr and faSymLink) = 0) then
        {$ENDIF}
        {$POP}
          RemoveTree(Full)
        else
          DeleteFile(Full);
      until FindNext(Sr) <> 0;
    finally
      FindClose(Sr);
    end;
  end;
  RemoveDir(APath);
end;

destructor TWasiProbe.Destroy;
begin
  FInstance.Free;
  FContext.Free;
  FLinker.Free;
  FreeAndNil(FStore);
  FLoaded.Free;
  FreeAndNil(FEngine);
  inherited Destroy;
end;

procedure TWasiProbe.Open(const AConfig: TWasmWasiConfig);
begin
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  EnsureInterpreter(FStore);
  FLoaded := LoadModule(AssembleWatText(CAPS_WAT));
  FContext := TWasmWasiContext.Create(AConfig);
  FLinker := TWasmLinker.Create(FStore);
  WasiDefineAll(FLinker, FContext);
  FInstance := Instantiate(FStore, FLinker, FLoaded);
  if not FInstance.FindExportMemory('memory', FMem) then
    raise EWasmError.Create('the capability probe must export memory');
  FContext.SetMemory(FMem);
end;

function TWasiProbe.Wrapper(const AName: string): TWasmFunc;
begin
  if not FInstance.FindExportFunc(AName, Result) then
    raise EWasmError.CreateFmt('missing export %s', [AName]);
end;

procedure TWasiProbe.GuestPutStr(const AOffset: UInt64; const AStr: string);
var
  Bytes: TBytes;
  Index: Integer;
begin
  SetLength(Bytes, Length(AStr));
  for Index := 1 to Length(AStr) do
    Bytes[Index - 1] := Byte(AStr[Index]);
  if Length(Bytes) = 0 then
    Exit;
  if not MemWrite(FMem, AOffset, UInt64(Length(Bytes)), @Bytes[0]) then
    raise EWasmError.Create('guest write out of bounds in a test setup');
end;

function TWasiProbe.GuestByte(const AOffset: UInt64): Byte;
var
  B: array[0..0] of Byte;
begin
  B[0] := 0;
  if not MemRead(FMem, AOffset, 1, @B[0]) then
    raise EWasmError.Create('guest read out of bounds in a test assertion');
  Result := B[0];
end;

function TWasiProbe.PathOpen(const ADirFd: UInt32; const APath: string;
  out AOpenedFd: UInt32): Int32;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
  Rights: TWasmWasiRights;
begin
  AOpenedFd := 0;
  GuestPutStr(300, APath);
  Fn := Wrapper('w_path_open');
  Rights := WASM_COMPILED_DIR_RIGHTS;
  SetLength(Args, 9);
  Args[0] := MakeValueI32(Int32(ADirFd));
  Args[1] := MakeValueI32(0);
  Args[2] := MakeValueI32(300);
  Args[3] := MakeValueI32(Int32(Length(APath)));
  Args[4] := MakeValueI32(0);
  Args[5] := MakeValueI64(Int64(Rights));
  Args[6] := MakeValueI64(Int64(Rights));
  Args[7] := MakeValueI32(0);
  Args[8] := MakeValueI32(400);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  Result := Results[0].I32;
  if Result = Ord(weSuccess) then
    if not MemReadU32(FMem, 400, AOpenedFd) then
      raise EWasmError.Create('opened_fd read out of bounds');
end;

function TWasiProbe.EnvironCount: UInt32;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  Fn := Wrapper('w_environ_sizes_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(0);
  Args[1] := MakeValueI32(4);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  if Results[0].I32 <> Ord(weSuccess) then
    raise EWasmError.Create('environ_sizes_get failed in the probe');
  if not MemReadU32(FMem, 0, Result) then
    raise EWasmError.Create('environ count read out of bounds');
end;

function TWasiProbe.ArgsCount: UInt32;
var
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  Fn := Wrapper('w_args_sizes_get');
  SetLength(Args, 2);
  Args[0] := MakeValueI32(0);
  Args[1] := MakeValueI32(4);
  SetLength(Results, 1);
  Call(Fn, Args, Results);
  if Results[0].I32 <> Ord(weSuccess) then
    raise EWasmError.Create('args_sizes_get failed in the probe');
  if not MemReadU32(FMem, 0, Result) then
    raise EWasmError.Create('argc read out of bounds');
end;

procedure TCompileCapabilitiesTests.TestDefaultDeniesFilesystemAndEnv;
var
  Caps: TWasmCompiledCapabilities;
begin
  Caps := TWasmCompiledCapabilities.Create;
  try
    Expect<Integer>(Caps.PreopenCount).ToBe(0);
    Expect<Integer>(Caps.EnvCount).ToBe(0);
    Expect<Boolean>(Caps.Frozen).ToBe(False);
  finally
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestApplyEmptySetIsDenyByDefault;
var
  Caps: TWasmCompiledCapabilities;
  Config: TWasmWasiConfig;
  Probe: TWasiProbe;
  Err: string;
  OpenedFd: UInt32;
begin
  Caps := TWasmCompiledCapabilities.Create;
  Config := TWasmWasiConfig.Create;
  Probe := TWasiProbe.Create;
  try
    Expect<Integer>(Caps.PreopenCount).ToBe(0);
    Expect<Integer>(Caps.EnvCount).ToBe(0);
    Expect<Boolean>(Caps.ApplyToConfig(Config,
      IncludeTrailingPathDelimiter(GetTempDir) + 'app', [], Err)).ToBe(True);
    Expect<Boolean>(Caps.Frozen).ToBe(True);
    Expect<Integer>(Length(Config.Preopens)).ToBe(0);
    Expect<Integer>(Length(Config.Env)).ToBe(0);
    Expect<Integer>(Length(Config.Argv)).ToBe(1);
    Expect<Boolean>(Config.Argv[0] = 'app').ToBe(True);
    Expect<Boolean>(Config.Stdin <> nil).ToBe(True);
    Expect<Boolean>(Config.Stdout <> nil).ToBe(True);
    Expect<Boolean>(Config.Stderr <> nil).ToBe(True);
    Expect<Boolean>(Config.Clock <> nil).ToBe(True);
    Expect<Boolean>(Config.Random <> nil).ToBe(True);
    Probe.Open(Config);
    Expect<UInt32>(Probe.EnvironCount).ToBe(0);
    Expect<Int32>(Probe.PathOpen(3, 'x', OpenedFd)).ToBe(Ord(weBadf));
  finally
    Probe.Free;
    Config.Free;
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestParseDirAndEnv;
var
  Caps: TWasmCompiledCapabilities;
  Guest, Host, KeyValue, Err: string;
begin
  Expect<Boolean>(TryParseCompiledDirSpec('/data=./out', Guest, Host, Err))
    .ToBe(True);
  Expect<Boolean>(Guest = '/data').ToBe(True);
  Expect<Boolean>(Host = './out').ToBe(True);

  Expect<Boolean>(TryParseCompiledEnvSpec('KEY=a=b', KeyValue, Err)).ToBe(True);
  Expect<Boolean>(KeyValue = 'KEY=a=b').ToBe(True);
  Expect<Boolean>(TryParseCompiledEnvSpec('KEY=', KeyValue, Err)).ToBe(True);
  Expect<Boolean>(KeyValue = 'KEY=').ToBe(True);

  Caps := TWasmCompiledCapabilities.Create;
  try
    Expect<Boolean>(Caps.TryAddDirSpec('/data=./out', Err)).ToBe(True);
    Expect<Boolean>(Caps.TryAddEnvSpec('LANG=C', Err)).ToBe(True);
    Expect<Integer>(Caps.PreopenCount).ToBe(1);
    Expect<Boolean>(Caps.PreopenAt(0).GuestPath = '/data').ToBe(True);
    Expect<Boolean>(Caps.PreopenAt(0).HostPath = './out').ToBe(True);
    Expect<Integer>(Caps.EnvCount).ToBe(1);
    Expect<Boolean>(Caps.EnvAt(0) = 'LANG=C').ToBe(True);
  finally
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestParseDirAndEnvRejects;
var
  Guest, Host, KeyValue, Err: string;
  Caps: TWasmCompiledCapabilities;
  Ok: Boolean;
begin
  Ok := TryParseCompiledDirSpec('nodir', Guest, Host, Err);
  Expect<Boolean>(Ok).ToBe(False);
  Expect<Boolean>(Pos('GUEST=HOST', Err) > 0).ToBe(True);

  Ok := TryParseCompiledDirSpec('/data=', Guest, Host, Err);
  Expect<Boolean>(Ok).ToBe(False);
  Expect<Boolean>(Pos('HOST path is empty', Err) > 0).ToBe(True);

  Ok := TryParseCompiledEnvSpec('NOVALUE', KeyValue, Err);
  Expect<Boolean>(Ok).ToBe(False);
  Expect<Boolean>(Pos('KEY=VALUE', Err) > 0).ToBe(True);

  Ok := TryParseCompiledEnvSpec('=x', KeyValue, Err);
  Expect<Boolean>(Ok).ToBe(False);

  Caps := TWasmCompiledCapabilities.Create;
  try
    Ok := Caps.TryAddDir('', '/tmp', Err);
    Expect<Boolean>(Ok).ToBe(False);
    Ok := Caps.TryAddDir('/g', '', Err);
    Expect<Boolean>(Ok).ToBe(False);
    Ok := Caps.TryAddDirSpec('/g=' + #0 + 'x', Err);
    Expect<Boolean>(Ok).ToBe(False);
  finally
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestFrozenCannotGrow;
var
  Caps: TWasmCompiledCapabilities;
  Err: string;
  Ok: Boolean;
begin
  Caps := TWasmCompiledCapabilities.Create;
  try
    Expect<Boolean>(Caps.TryAddEnvSpec('A=1', Err)).ToBe(True);
    Caps.Freeze;
    Ok := Caps.TryAddEnvSpec('B=2', Err);
    Expect<Boolean>(Ok).ToBe(False);
    Expect<Boolean>(Pos('frozen', Err) > 0).ToBe(True);
    Ok := Caps.TryAddDirSpec('/g=/tmp', Err);
    Expect<Boolean>(Ok).ToBe(False);
    Expect<Integer>(Caps.EnvCount).ToBe(1);
    Expect<Integer>(Caps.PreopenCount).ToBe(0);
  finally
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestRelativeHostResolvesFromExecutableDir;
var
  Resolved, Err: string;
  ExeDir: string;
begin
  ExeDir := IncludeTrailingPathDelimiter(GetTempDir) + 'exe-home';
  Expect<Boolean>(TryResolveCompiledHostPath('data', ExeDir, Resolved, Err))
    .ToBe(True);
  Expect<Boolean>(Resolved = IncludeTrailingPathDelimiter(ExeDir) + 'data')
    .ToBe(True);
  Expect<Boolean>(CompiledHostPathIsAbsolute(Resolved) or
    (Pos(ExeDir, Resolved) > 0)).ToBe(True);
end;

procedure TCompileCapabilitiesTests.TestRelativeHostIgnoresCwd;
var
  Other, ExeDir, Resolved, Err: string;
  Saved: string;
begin
  Saved := GetCurrentDir;
  Other := MakeTempDir('wasmlight_caps_other_');
  ExeDir := MakeTempDir('wasmlight_caps_exe_');
  try
    Expect<Boolean>(SetCurrentDir(Other)).ToBe(True);
    Expect<Boolean>(TryResolveCompiledHostPath('data', ExeDir, Resolved, Err))
      .ToBe(True);
    Expect<Boolean>(Resolved = IncludeTrailingPathDelimiter(ExeDir) + 'data')
      .ToBe(True);
    Expect<Boolean>(Pos(Other, Resolved) = 0).ToBe(True);
  finally
    SetCurrentDir(Saved);
    RemoveTree(Other);
    RemoveTree(ExeDir);
  end;
end;

procedure TCompileCapabilitiesTests.TestAbsoluteHostStaysLiteral;
var
  Resolved, Err: string;
  AbsoluteHost: string;
begin
  AbsoluteHost := IncludeTrailingPathDelimiter(GetTempDir) + 'literal-host';
  Expect<Boolean>(CompiledHostPathIsAbsolute(AbsoluteHost)).ToBe(True);
  Expect<Boolean>(TryResolveCompiledHostPath(AbsoluteHost, '/somewhere/else',
    Resolved, Err)).ToBe(True);
  Expect<Boolean>(Resolved = AbsoluteHost).ToBe(True);
end;

procedure TCompileCapabilitiesTests.TestRelocationChangesResolvedHost;
var
  Caps: TWasmCompiledCapabilities;
  ConfigA, ConfigB: TWasmWasiConfig;
  Err: string;
  ExeA, ExeB: string;
begin
  Caps := TWasmCompiledCapabilities.Create;
  ConfigA := TWasmWasiConfig.Create;
  ConfigB := TWasmWasiConfig.Create;
  try
    Expect<Boolean>(Caps.TryAddDirSpec('/data=rel-data', Err)).ToBe(True);
    ExeA := IncludeTrailingPathDelimiter(GetTempDir) + 'reloc-a' +
      PathDelim + 'app';
    ExeB := IncludeTrailingPathDelimiter(GetTempDir) + 'reloc-b' +
      PathDelim + 'app';
    Expect<Boolean>(Caps.ApplyToConfig(ConfigA, ExeA, [], Err)).ToBe(True);
    { A second apply on a fresh config is allowed; the set is already frozen. }
    Expect<Boolean>(ConfigB.Preopens = nil).ToBe(True);
    { Freeze blocks TryAdd, not a second apply onto a fresh config. }
    Expect<Boolean>(Caps.ApplyToConfig(ConfigB, ExeB, [], Err)).ToBe(True);
    Expect<Integer>(Length(ConfigA.Preopens)).ToBe(1);
    Expect<Integer>(Length(ConfigB.Preopens)).ToBe(1);
    Expect<Boolean>(ConfigA.Preopens[0].HostPath =
      IncludeTrailingPathDelimiter(CompiledExecutableDir(ExeA)) + 'rel-data')
      .ToBe(True);
    Expect<Boolean>(ConfigB.Preopens[0].HostPath =
      IncludeTrailingPathDelimiter(CompiledExecutableDir(ExeB)) + 'rel-data')
      .ToBe(True);
    Expect<Boolean>(ConfigA.Preopens[0].HostPath <>
      ConfigB.Preopens[0].HostPath).ToBe(True);
  finally
    ConfigB.Free;
    ConfigA.Free;
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestUnixAndWindowsAbsoluteForms;
begin
  Expect<Boolean>(CompiledHostPathIsUnixAbsolute('/tmp/data')).ToBe(True);
  Expect<Boolean>(CompiledHostPathIsUnixAbsolute('data')).ToBe(False);
  Expect<Boolean>(CompiledHostPathIsUnixAbsolute('./data')).ToBe(False);
  Expect<Boolean>(CompiledHostPathIsWindowsAbsolute('C:\data')).ToBe(True);
  Expect<Boolean>(CompiledHostPathIsWindowsAbsolute('C:/data')).ToBe(True);
  Expect<Boolean>(CompiledHostPathIsWindowsAbsolute('\\server\share')).ToBe(True);
  Expect<Boolean>(CompiledHostPathIsWindowsAbsolute('data')).ToBe(False);
  Expect<Boolean>(CompiledHostPathIsWindowsAbsolute('./data')).ToBe(False);
  {$IFDEF WINDOWS}
  Expect<Boolean>(CompiledHostPathIsAbsolute('C:\data')).ToBe(True);
  Expect<Boolean>(CompiledHostPathIsAbsolute('data')).ToBe(False);
  {$ELSE}
  Expect<Boolean>(CompiledHostPathIsAbsolute('/tmp/data')).ToBe(True);
  Expect<Boolean>(CompiledHostPathIsAbsolute('data')).ToBe(False);
  {$ENDIF}
end;

procedure TCompileCapabilitiesTests.TestGuestArgvForwardsEveryToken;
var
  Argv: TArray<string>;
begin
  Argv := CompiledGuestArgv('/opt/bin/tool',
    ['--verbose', '--dir=/etc', '--env', 'K=V']);
  Expect<Integer>(Length(Argv)).ToBe(5);
  Expect<Boolean>(Argv[0] = 'tool').ToBe(True);
  Expect<Boolean>(Argv[1] = '--verbose').ToBe(True);
  Expect<Boolean>(Argv[2] = '--dir=/etc').ToBe(True);
  Expect<Boolean>(Argv[3] = '--env').ToBe(True);
  Expect<Boolean>(Argv[4] = 'K=V').ToBe(True);
end;

procedure TCompileCapabilitiesTests.TestApplyDoesNotInheritProcessEnv;
var
  Caps: TWasmCompiledCapabilities;
  Config: TWasmWasiConfig;
  Err: string;
  Index: Integer;
  InheritedPath: Boolean;
begin
  Caps := TWasmCompiledCapabilities.Create;
  Config := TWasmWasiConfig.Create;
  try
    Expect<Boolean>(Caps.TryAddEnvSpec('LANG=C', Err)).ToBe(True);
    Expect<Boolean>(Caps.ApplyToConfig(Config,
      IncludeTrailingPathDelimiter(GetTempDir) + 'app', [], Err)).ToBe(True);
    Expect<Integer>(Length(Config.Env)).ToBe(1);
    Expect<Boolean>(Config.Env[0] = 'LANG=C').ToBe(True);
    InheritedPath := False;
    for Index := 0 to High(Config.Env) do
      if Copy(Config.Env[Index], 1, 5) = 'PATH=' then
        InheritedPath := True;
    Expect<Boolean>(InheritedPath).ToBe(False);
    Expect<Boolean>(GetEnvironmentVariable('PATH') <> Config.Env[0]).ToBe(True);
  finally
    Config.Free;
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestApplyRefusesExistingCapabilities;
var
  Caps: TWasmCompiledCapabilities;
  Config: TWasmWasiConfig;
  Err: string;
  Ok: Boolean;
begin
  Caps := TWasmCompiledCapabilities.Create;
  Config := TWasmWasiConfig.Create;
  try
    Expect<Boolean>(Caps.TryAddDirSpec('/g=/tmp', Err)).ToBe(True);
    Config.AddEnv('LEAK=1');
    Ok := Caps.ApplyToConfig(Config,
      IncludeTrailingPathDelimiter(GetTempDir) + 'app', [], Err);
    Expect<Boolean>(Ok).ToBe(False);
    Expect<Boolean>(Pos('cannot expand', Err) > 0).ToBe(True);
    Expect<Integer>(Length(Config.Preopens)).ToBe(0);
  finally
    Config.Free;
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestApplyFailureLeavesConfigEmpty;
var
  Caps: TWasmCompiledCapabilities;
  Config: TWasmWasiConfig;
  Err: string;
  Ok: Boolean;
  AbsoluteHost: string;
begin
  { An absolute preopen would apply first; a later relative path with no
    executable directory must not leave that prefix installed. }
  AbsoluteHost := IncludeTrailingPathDelimiter(GetTempDir) + 'abs-host';
  Caps := TWasmCompiledCapabilities.Create;
  Config := TWasmWasiConfig.Create;
  try
    Expect<Boolean>(Caps.TryAddDir('/abs', AbsoluteHost, Err)).ToBe(True);
    Expect<Boolean>(Caps.TryAddDirSpec('/rel=rel-data', Err)).ToBe(True);
    Ok := Caps.ApplyToConfig(Config, 'app', [], Err);
    Expect<Boolean>(Ok).ToBe(False);
    Expect<Boolean>(Pos('executable directory', Err) > 0).ToBe(True);
    Expect<Integer>(Length(Config.Preopens)).ToBe(0);
    Expect<Integer>(Length(Config.Env)).ToBe(0);
    Expect<Boolean>(Caps.Frozen).ToBe(False);
  finally
    Config.Free;
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestCompiledRightsMatchRun;
begin
  Expect<UInt64>(WASM_COMPILED_DIR_RIGHTS).ToBe(WASM_RUN_DIR_RIGHTS);
end;

procedure TCompileCapabilitiesTests.TestApplyArgvAndEnvReachWasi;
var
  Caps: TWasmCompiledCapabilities;
  Config: TWasmWasiConfig;
  Probe: TWasiProbe;
  Err: string;
  Count, BufSize, P0, P1: UInt32;
  Fn: TWasmFunc;
  Args, Results: array of TWasmValue;
begin
  Caps := TWasmCompiledCapabilities.Create;
  Config := TWasmWasiConfig.Create;
  Probe := TWasiProbe.Create;
  try
    Expect<Boolean>(Caps.TryAddEnvSpec('HELLO=world', Err)).ToBe(True);
    Expect<Boolean>(Caps.ApplyToConfig(Config,
      IncludeTrailingPathDelimiter(GetTempDir) + 'prog',
      ['--verbose', '--dir=/etc'], Err)).ToBe(True);
    Probe.Open(Config);
    Expect<UInt32>(Probe.ArgsCount).ToBe(3);
    Expect<UInt32>(Probe.EnvironCount).ToBe(1);

    Fn := Probe.Wrapper('w_args_get');
    SetLength(Args, 2);
    Args[0] := MakeValueI32(100);
    Args[1] := MakeValueI32(200);
    SetLength(Results, 1);
    Call(Fn, Args, Results);
    Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
    Expect<Boolean>(MemReadU32(Probe.Mem, 100, P0)).ToBe(True);
    Expect<Boolean>(P0 = 200).ToBe(True);
    Expect<Boolean>(Probe.GuestByte(200) = Byte('p')).ToBe(True);

    Fn := Probe.Wrapper('w_environ_sizes_get');
    Args[0] := MakeValueI32(0);
    Args[1] := MakeValueI32(4);
    Call(Fn, Args, Results);
    Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
    Expect<Boolean>(MemReadU32(Probe.Mem, 4, BufSize)).ToBe(True);
    { 'HELLO=world'\0 = 12. }
    Expect<Boolean>(BufSize = 12).ToBe(True);
    Expect<Boolean>(MemReadU32(Probe.Mem, 0, Count)).ToBe(True);
    Expect<Boolean>(Count = 1).ToBe(True);

    Fn := Probe.Wrapper('w_environ_get');
    Args[0] := MakeValueI32(100);
    Args[1] := MakeValueI32(200);
    Call(Fn, Args, Results);
    Expect<Int32>(Results[0].I32).ToBe(Ord(weSuccess));
    Expect<Boolean>(MemReadU32(Probe.Mem, 100, P1)).ToBe(True);
    Expect<Boolean>(P1 = 200).ToBe(True);
    Expect<Boolean>(Probe.GuestByte(200) = Byte('H')).ToBe(True);
  finally
    Probe.Free;
    Config.Free;
    Caps.Free;
  end;
end;

procedure TCompileCapabilitiesTests.TestContainmentDotDot;
var
  Caps: TWasmCompiledCapabilities;
  Config: TWasmWasiConfig;
  Probe: TWasiProbe;
  Sandbox, Err: string;
  OpenedFd: UInt32;
begin
  Sandbox := MakeTempDir('wasmlight_caps_box_');
  Caps := TWasmCompiledCapabilities.Create;
  Config := TWasmWasiConfig.Create;
  Probe := TWasiProbe.Create;
  try
    Expect<Boolean>(Caps.TryAddDir('/sandbox', Sandbox, Err)).ToBe(True);
    Expect<Boolean>(Caps.ApplyToConfig(Config,
      IncludeTrailingPathDelimiter(GetTempDir) + 'app', [], Err)).ToBe(True);
    Probe.Open(Config);
    Expect<Int32>(Probe.PathOpen(3, '../escape.txt', OpenedFd))
      .ToBe(Ord(weNotCapable));
    Expect<Int32>(Probe.PathOpen(3, '/etc/passwd', OpenedFd))
      .ToBe(Ord(weNotCapable));
  finally
    Probe.Free;
    Config.Free;
    Caps.Free;
    RemoveTree(Sandbox);
  end;
end;

{$IFDEF UNIX}
procedure TCompileCapabilitiesTests.TestContainmentEscapingSymlink;
var
  Caps: TWasmCompiledCapabilities;
  Config: TWasmWasiConfig;
  Probe: TWasiProbe;
  Sandbox, Err: string;
  OpenedFd: UInt32;
begin
  Sandbox := MakeTempDir('wasmlight_caps_link_');
  fpSymlink(PAnsiChar('/etc'),
    PAnsiChar(AnsiString(IncludeTrailingPathDelimiter(Sandbox) + 'escape')));
  Caps := TWasmCompiledCapabilities.Create;
  Config := TWasmWasiConfig.Create;
  Probe := TWasiProbe.Create;
  try
    Expect<Boolean>(Caps.TryAddDir('/sandbox', Sandbox, Err)).ToBe(True);
    Expect<Boolean>(Caps.ApplyToConfig(Config,
      IncludeTrailingPathDelimiter(GetTempDir) + 'app', [], Err)).ToBe(True);
    Probe.Open(Config);
    Expect<Int32>(Probe.PathOpen(3, 'escape', OpenedFd))
      .ToBe(Ord(weNotCapable));
  finally
    Probe.Free;
    Config.Free;
    Caps.Free;
    RemoveTree(Sandbox);
  end;
end;
{$ENDIF}

procedure TCompileCapabilitiesTests.SetupTests;
begin
  Test('a default set grants no directories and no environment',
    TestDefaultDeniesFilesystemAndEnv);
  Test('applying an empty set is deny-by-default WASI with no process env',
    TestApplyEmptySetIsDenyByDefault);
  Test('GUEST=HOST and KEY=VALUE parse into the compiled set',
    TestParseDirAndEnv);
  Test('malformed dir and env specs are rejected',
    TestParseDirAndEnvRejects);
  Test('a frozen set cannot grow', TestFrozenCannotGrow);
  Test('a relative host path resolves from the executable directory',
    TestRelativeHostResolvesFromExecutableDir);
  Test('relative resolution does not consult the process CWD',
    TestRelativeHostIgnoresCwd);
  Test('an absolute host path is preserved literally',
    TestAbsoluteHostStaysLiteral);
  Test('relocating the executable changes a relative host path',
    TestRelocationChangesResolvedHost);
  Test('POSIX and Windows absolute forms classify independently',
    TestUnixAndWindowsAbsoluteForms);
  Test('every invocation argument is a guest argument',
    TestGuestArgvForwardsEveryToken);
  Test('apply installs only compiled env and never inherits PATH',
    TestApplyDoesNotInheritProcessEnv);
  Test('apply refuses a config that already has capabilities',
    TestApplyRefusesExistingCapabilities);
  Test('a failed apply does not install a prefix of the set',
    TestApplyFailureLeavesConfigEmpty);
  Test('compiled directory rights match wasmlight run --dir',
    TestCompiledRightsMatchRun);
  Test('applied argv and env are what the WASI guest observes',
    TestApplyArgvAndEnvReachWasi);
  Test('path_open through an applied preopen refuses .. and absolute paths',
    TestContainmentDotDot);
  {$IFDEF UNIX}
  Test('path_open through an applied preopen refuses an escaping symlink',
    TestContainmentEscapingSymlink);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(
    TCompileCapabilitiesTests.Create('Wasm.Compile.Capabilities'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
