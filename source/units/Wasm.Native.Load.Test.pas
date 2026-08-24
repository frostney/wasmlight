{ Unit suite for Wasm.Native.Load — application-local resolution.

  Path rules are judged without dlopen: bare names gain the platform
  filename, relative paths stay beside the executable, absolute paths
  stay literal, and a `..` escape or a missing file is EWasmLinkError. }
program Wasm.Native.Load.Test;

{$I Shared.inc}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Native.Load;

type
  TLibraryTests = class(TTestSuite)
  public
    procedure SetupTests; override;

    procedure TestBareNameGainsPlatformFileName;
    procedure TestRelativeJoinsExecutableDirectory;
    procedure TestAbsolutePathIsLiteral;
    procedure TestDotDotEscapeIsALinkError;
    procedure TestMissingLibraryIsALinkError;
    procedure TestEmptyNameIsALinkError;
  end;

procedure TLibraryTests.TestBareNameGainsPlatformFileName;
var
  Path: string;
begin
  Path := ResolveLocalLibraryPath('wasmlightabi', '/opt/app');
  {$IFDEF DARWIN}
  Expect<string>(Path).ToBe('/opt/app/libwasmlightabi.dylib');
  {$ELSE}
  {$IFDEF UNIX}
  Expect<string>(Path).ToBe('/opt/app/libwasmlightabi.so');
  {$ELSE}
  Expect<string>(ExtractFileName(Path)).ToBe(NativeLibraryFileName('wasmlightabi'));
  {$ENDIF}
  {$ENDIF}
end;

procedure TLibraryTests.TestRelativeJoinsExecutableDirectory;
var
  Path: string;
begin
  Path := ResolveLocalLibraryPath('vendor/libwasmlightabi.dylib', '/opt/app');
  {$IFDEF UNIX}
  Expect<string>(Path).ToBe('/opt/app/vendor/libwasmlightabi.dylib');
  {$ELSE}
  Expect<Boolean>(Pos('vendor', Path) > 0).ToBe(True);
  {$ENDIF}
end;

procedure TLibraryTests.TestAbsolutePathIsLiteral;
var
  Path: string;
begin
  Path := ResolveLocalLibraryPath('/usr/local/lib/libwasmlightabi.dylib',
    '/opt/app');
  {$IFDEF UNIX}
  Expect<string>(Path).ToBe('/usr/local/lib/libwasmlightabi.dylib');
  {$ELSE}
  Expect<Boolean>(Path <> '').ToBe(True);
  {$ENDIF}
end;

procedure TLibraryTests.TestDotDotEscapeIsALinkError;
var
  Caught: string;
  RaisedOk: Boolean;
begin
  Caught := '';
  RaisedOk := False;
  try
    ResolveLocalLibraryPath('../libc', '/opt/app');
  except
    on E: EWasmLinkError do
    begin
      RaisedOk := True;
      Caught := E.Message;
    end;
  end;
  Expect<Boolean>(RaisedOk).ToBe(True);
  Expect<Boolean>(Pos(string(MSG_LINK_UNKNOWN_LIBRARY), Caught) = 1).ToBe(True);
end;

procedure TLibraryTests.TestMissingLibraryIsALinkError;
var
  Caught: string;
  RaisedOk: Boolean;
begin
  Caught := '';
  RaisedOk := False;
  try
    LoadLocalLibraryAt('missing-library', '/opt/app').Free;
  except
    on E: EWasmLinkError do
    begin
      RaisedOk := True;
      Caught := E.Message;
    end;
  end;
  Expect<Boolean>(RaisedOk).ToBe(True);
  Expect<Boolean>(Pos(string(MSG_LINK_UNKNOWN_LIBRARY), Caught) = 1).ToBe(True);
end;

procedure TLibraryTests.TestEmptyNameIsALinkError;
var
  RaisedOk: Boolean;
begin
  RaisedOk := False;
  try
    ResolveLocalLibraryPath('', '/opt/app');
  except
    on E: EWasmLinkError do
      RaisedOk := True;
  end;
  Expect<Boolean>(RaisedOk).ToBe(True);
end;

procedure TLibraryTests.SetupTests;
begin
  Test('bare name receives the platform filename beside the executable',
    TestBareNameGainsPlatformFileName);
  Test('relative path joins the executable directory',
    TestRelativeJoinsExecutableDirectory);
  Test('absolute path stays literal', TestAbsolutePathIsLiteral);
  Test('relative escape is a link error', TestDotDotEscapeIsALinkError);
  Test('missing library is a link error', TestMissingLibraryIsALinkError);
  Test('empty name is a link error', TestEmptyNameIsALinkError);
end;

begin
  TestRunnerProgram.AddSuite(TLibraryTests.Create('Wasm.Native.Load'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
