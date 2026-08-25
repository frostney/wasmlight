{ Wasm.Native.Load — application-local dynamic-library capability.

  A connector library is a deployment dependency resolved beside the
  executable, never through ambient search (ADR-0015). A bare DllImport
  name receives the platform filename convention and is joined to the
  executable directory; a relative path is also joined there; a literal
  absolute path stays literal. The working directory, PATH,
  LD_LIBRARY_PATH, and DYLD_LIBRARY_PATH are not consulted for the named
  library.

  Missing libraries and missing symbols are EWasmLinkError — a link
  failure, not a crash and not a fallback. dlopen is only ever given an
  absolute path this unit already resolved.

  64-bit Unix only in this issue. Other hosts fail closed with the same
  link class. }
unit Wasm.Native.Load;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Core;

const
  MSG_LINK_UNKNOWN_LIBRARY = 'unknown library';
  MSG_LINK_UNKNOWN_SYMBOL = 'unknown symbol';

type
  TWasmNativeLibrary = class
  private
    FHandle: Pointer;
    FPath: string;
  public
    destructor Destroy; override;
    property Handle: Pointer read FHandle;
    property Path: string read FPath;
  end;

function NativeExecutableDirectory: string;
function NativeLibraryFileName(const ABareName: string): string;
function ResolveLocalLibraryPath(const AName, AExecutableDir: string): string;
function LoadLocalLibrary(const AName: string): TWasmNativeLibrary;
function LoadLocalLibraryAt(const AName, AExecutableDir: string): TWasmNativeLibrary;
function LookupLocalSymbol(const ALibrary: TWasmNativeLibrary;
  const ASymbol: string): Pointer;

implementation

{$IFDEF UNIX}
uses
  BaseUnix;
{$ENDIF}

const
  {$IFDEF DARWIN}
  RTLD_NOW = 2;
  RTLD_LOCAL = 4;
  LIB_PREFIX = 'lib';
  LIB_SUFFIX = '.dylib';
  {$ELSE}
  RTLD_NOW = 2;
  RTLD_LOCAL = 0;
  LIB_PREFIX = 'lib';
  LIB_SUFFIX = '.so';
  {$ENDIF}

{$IFDEF WASM_NATIVE_CALL}
function CDlOpen(AName: PAnsiChar; AFlags: LongInt): Pointer; cdecl;
  {$IFDEF DARWIN}
  external 'c' name 'dlopen';
  {$ELSE}
  external 'dl' name 'dlopen';
  {$ENDIF}

function CDlSym(ALib: Pointer; AName: PAnsiChar): Pointer; cdecl;
  {$IFDEF DARWIN}
  external 'c' name 'dlsym';
  {$ELSE}
  external 'dl' name 'dlsym';
  {$ENDIF}

function CDlClose(ALib: Pointer): LongInt; cdecl;
  {$IFDEF DARWIN}
  external 'c' name 'dlclose';
  {$ELSE}
  external 'dl' name 'dlclose';
  {$ENDIF}
{$ENDIF}

{$IFDEF UNIX}
{$IFDEF DARWIN}
function NSGetExecutablePath(ABuf: PAnsiChar; var ABufSize: UInt32): Integer; cdecl;
  external 'c' name '_NSGetExecutablePath';
{$ENDIF}
{$ENDIF}

destructor TWasmNativeLibrary.Destroy;
begin
  {$IFDEF WASM_NATIVE_CALL}
  if FHandle <> nil then
    CDlClose(FHandle);
  {$ENDIF}
  FHandle := nil;
  inherited Destroy;
end;

function NativeExecutableDirectory: string;
{$IFDEF UNIX}
var
  {$IFDEF DARWIN}
  BufSize: UInt32;
  Buf: array[0..4095] of AnsiChar;
  {$ELSE}
  Link: array[0..4095] of AnsiChar;
  N: TSsize;
  {$ENDIF}
{$ENDIF}
begin
  {$IFDEF UNIX}
  {$IFDEF DARWIN}
  BufSize := SizeOf(Buf);
  if NSGetExecutablePath(@Buf[0], BufSize) = 0 then
  begin
    Result := ExpandFileName(string(AnsiString(PAnsiChar(@Buf[0]))));
    Result := ExcludeTrailingPathDelimiter(ExtractFilePath(Result));
    Exit;
  end;
  {$ELSE}
  N := FpReadLink('/proc/self/exe', @Link[0], SizeOf(Link) - 1);
  if N > 0 then
  begin
    Link[N] := #0;
    Result := ExpandFileName(string(AnsiString(PAnsiChar(@Link[0]))));
    Result := ExcludeTrailingPathDelimiter(ExtractFilePath(Result));
    Exit;
  end;
  {$ENDIF}
  {$ENDIF}
  Result := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  if Result <> '' then
    Result := ExcludeTrailingPathDelimiter(ExpandFileName(Result));
  if Result = '' then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) +
      ': no executable directory');
  {$IFDEF UNIX}
  if Result[1] <> '/' then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) +
      ': no executable directory');
  {$ENDIF}
end;

function NativeLibraryFileName(const ABareName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(ABareName));
  if (Ext = '.so') or (Ext = '.dylib') or (Ext = '.dll') then
  begin
    Result := ABareName;
    Exit;
  end;
  Result := LIB_PREFIX + ABareName + LIB_SUFFIX;
end;

function IsAbsolutePath(const AName: string): Boolean;
begin
  Result := (Length(AName) > 0) and (AName[1] = '/');
end;

function LooksRelativePath(const AName: string): Boolean;
begin
  Result := (Pos('/', AName) > 0) or (Copy(AName, 1, 2) = './');
end;

function ResolveLocalLibraryPath(const AName, AExecutableDir: string): string;
var
  Base: string;
  Combined: string;
  Root: string;
begin
  if AName = '' then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) + ': empty name');

  Base := ExcludeTrailingPathDelimiter(AExecutableDir);
  if Base = '' then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) + ': no executable directory');

  if IsAbsolutePath(AName) then
  begin
    Result := ExpandFileName(AName);
    Exit;
  end;

  if LooksRelativePath(AName) then
    Combined := IncludeTrailingPathDelimiter(Base) + AName
  else
    Combined := IncludeTrailingPathDelimiter(Base) + NativeLibraryFileName(AName);

  Result := ExpandFileName(Combined);
  Root := IncludeTrailingPathDelimiter(ExpandFileName(Base));
  if (Length(Result) < Length(Root)) or
    (Copy(Result, 1, Length(Root)) <> Root) then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) +
      ': path escapes executable directory');
end;

function LoadLocalLibraryAt(const AName, AExecutableDir: string): TWasmNativeLibrary;
{$IFDEF WASM_NATIVE_CALL}
var
  Path: string;
  Handle: Pointer;
{$ENDIF}
begin
  {$IFNDEF WASM_NATIVE_CALL}
  Result := nil;
  raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) +
    ': native libraries are 64-bit Unix only');
  {$ELSE}
  Path := ResolveLocalLibraryPath(AName, AExecutableDir);
  if not FileExists(Path) then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) + ': ' + Path);

  Handle := CDlOpen(PAnsiChar(AnsiString(Path)), RTLD_NOW or RTLD_LOCAL);
  if Handle = nil then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_LIBRARY) + ': ' + Path);

  Result := TWasmNativeLibrary.Create;
  Result.FHandle := Handle;
  Result.FPath := Path;
  {$ENDIF}
end;

function LoadLocalLibrary(const AName: string): TWasmNativeLibrary;
begin
  Result := LoadLocalLibraryAt(AName, NativeExecutableDirectory);
end;

function LookupLocalSymbol(const ALibrary: TWasmNativeLibrary;
  const ASymbol: string): Pointer;
begin
  if (ALibrary = nil) or (ALibrary.FHandle = nil) or (ASymbol = '') then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_SYMBOL) + ': ' + ASymbol);
  {$IFDEF WASM_NATIVE_CALL}
  Result := CDlSym(ALibrary.FHandle, PAnsiChar(AnsiString(ASymbol)));
  {$ELSE}
  Result := nil;
  {$ENDIF}
  if Result = nil then
    raise EWasmLinkError.Create(string(MSG_LINK_UNKNOWN_SYMBOL) + ': ' + ASymbol);
end;

end.
