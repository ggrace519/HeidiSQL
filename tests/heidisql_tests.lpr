program heidisql_tests;

// Console test runner for the LCL-free units of HeidiSQL AI Edition.
// Build and run with "make test". Units under test must not use LCL, apphelpers or dbconnection.

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  // Same string environment as the application: LazUTF8 makes UTF-8 the default code page,
  // independent of the system locale. Without it, fpjson turns non-ASCII text into "?".
  LazUTF8,
  Classes, SysUtils, fpcunit, testregistry, testutils, fpcunitreport, consoletestrunner,
  test_forkpaths, test_forkupdate, test_ai_sse, test_ai_openai, test_ai_sqlextract, test_ai_context, test_ai_prompts, test_ai_profiles,
  test_ai_conversation_keystore, test_ai_http, test_ai_tls, test_ai_keychain,
  test_ai_requestbuild;

type
  // Prints each test's name before it runs, so a hanging test shows up in CI logs
  TTraceListener = class(TNoRefCountObject, ITestListener)
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

  TTracingRunner = class(TTestRunner)
  protected
    procedure DoTestRun(ATest: TTest); override;
  end;

procedure TTraceListener.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
end;

procedure TTraceListener.AddError(ATest: TTest; AError: TTestFailure);
begin
end;

procedure TTraceListener.StartTest(ATest: TTest);
begin
  WriteLn(StdErr, '> ', ATest.TestSuiteName, '.', ATest.TestName);
  Flush(StdErr);
end;

procedure TTraceListener.EndTest(ATest: TTest);
begin
end;

procedure TTraceListener.StartTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TTraceListener.EndTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TTracingRunner.DoTestRun(ATest: TTest);
var
  ResultsWriter: TCustomResultsWriter;
  Trace: TTraceListener;
  TestResult: TTestResult;
begin
  Trace := TTraceListener.Create;
  TestResult := TTestResult.Create;
  ResultsWriter := nil;
  try
    TestResult.AddListener(Trace);
    ResultsWriter := GetResultsWriter;
    ResultsWriter.Filename := FileName;
    TestResult.AddListener(ResultsWriter);
    ATest.Run(TestResult);
    ResultsWriter.WriteResult(TestResult);
    // Same convention as the stock runner: bit 0 failures, bit 1 errors
    ExitCode := Ord(TestResult.NumberOfFailures > 0) or (Ord(TestResult.NumberOfErrors > 0) shl 1);
  finally
    TestResult.Free;
    ResultsWriter.Free;
    Trace.Free;
  end;
end;

var
  App: TTracingRunner;
begin
  DefaultRunAllTests := True;
  DefaultFormat := fPlain;
  App := TTracingRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'HeidiSQL AI Edition tests';
    App.Run;
  finally
    App.Free;
  end;
end.
