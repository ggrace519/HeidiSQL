program heidisql_tests;

// Console test runner for the LCL-free units of HeidiSQL AI Edition.
// Build and run with "make test". Units under test must not use LCL, apphelpers or dbconnection.

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, consoletestrunner,
  test_forkpaths, test_forkupdate;

var
  App: TTestRunner;
begin
  DefaultRunAllTests := True;
  DefaultFormat := fPlain;
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'HeidiSQL AI Edition tests';
    App.Run;
  finally
    App.Free;
  end;
end.
