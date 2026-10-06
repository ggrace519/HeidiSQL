program heidisql_tests;

// Console test runner for the LCL-free units of HeidiSQL AI Edition.
// Build and run with "make test". Units under test must not use LCL, apphelpers or dbconnection.

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  // Same string environment as the application: LazUTF8 makes UTF-8 the default code page,
  // independent of the system locale. Without it, fpjson turns non-ASCII text into "?".
  LazUTF8,
  Classes, consoletestrunner,
  test_forkpaths, test_forkupdate, test_ai_sse, test_ai_openai, test_ai_sqlextract, test_ai_context, test_ai_prompts, test_ai_profiles;

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
