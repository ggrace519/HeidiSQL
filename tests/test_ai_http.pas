unit test_ai_http;

// ai.http against a scripted local HTTP server: streaming, error bodies, non-streamed answers,
// connection failures, read timeout and cancelling a request that hangs.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, ai.types, ai.http, aimockserver;

type
  TAiHttpTest = class(TTestCase)
  private
    FServer: TMockHttpServer;
    FContent, FReasoning: String;
    FDrainCountBeforeFinish: Integer;
    procedure StartServer(const Response: TMockResponse);
    function Spec(Mode: TAiResponseMode = rmChatStream; IoTimeoutMs: Integer = 5000): TAiRequestSpec;
    // Runs the request, draining like the UI timer does. Returns elapsed milliseconds.
    function Run(const S: TAiRequestSpec; const Mailbox: IAiMailbox; MaxMs: Integer = 10000): QWord;
  protected
    procedure TearDown; override;
  published
    procedure StreamsRecordedAnswer;
    procedure StreamArrivesIncrementally;
    procedure RequestCarriesBodyAndHeaders;
    procedure ErrorBodyOfUnknownModel;
    procedure PlainTextErrorOfWrongPath;
    procedure NonStreamedAnswerAccepted;
    procedure ErrorInsideStream;
    procedure StreamEndingEarlyIsProtocolError;
    procedure BufferModeKeepsBody;
    procedure ConnectionRefused;
    procedure SilentServerTimesOut;
    procedure CancelWakesBlockedRead;
    procedure CancelBeforeStart;
  end;

implementation

uses
  testhelpers;

procedure TAiHttpTest.TearDown;
begin
  FreeAndNil(FServer);
end;

procedure TAiHttpTest.StartServer(const Response: TMockResponse);
begin
  FServer := TMockHttpServer.Create(Response);
end;

function TAiHttpTest.Spec(Mode: TAiResponseMode = rmChatStream; IoTimeoutMs: Integer = 5000): TAiRequestSpec;
var
  Port: Word;
begin
  Result := Default(TAiRequestSpec);
  if Assigned(FServer) then
    Port := FServer.Port
  else
    Port := UnusedPort;
  Result.Method := 'POST';
  Result.Url := 'http://127.0.0.1:' + IntToStr(Port) + '/v1/chat/completions';
  Result.Body := '{"model":"m","stream":true}';
  Result.Headers := ['Content-Type: application/json', 'Authorization: Bearer sk-test-secret'];
  Result.Mode := Mode;
  Result.ConnectTimeoutMs := 3000;
  Result.IoTimeoutMs := IoTimeoutMs;
end;

function TAiHttpTest.Run(const S: TAiRequestSpec; const Mailbox: IAiMailbox; MaxMs: Integer = 10000): QWord;
var
  Started: QWord;
  C, R: String;
begin
  FContent := '';
  FReasoning := '';
  FDrainCountBeforeFinish := 0;
  Started := GetTickCount64;
  StartAiRequest(S, Mailbox);
  while not Mailbox.Finished do begin
    if GetTickCount64 - Started > QWord(MaxMs) then
      Fail('request did not finish within ' + IntToStr(MaxMs) + ' ms');
    if Mailbox.Drain(C, R) then
      Inc(FDrainCountBeforeFinish);
    FContent := FContent + C;
    FReasoning := FReasoning + R;
    Sleep(10);
  end;
  Result := GetTickCount64 - Started;
  Mailbox.Drain(C, R);
  FContent := FContent + C;
  FReasoning := FReasoning + R;
  AssertTrue('worker thread ended', Mailbox.WaitWorkerDone(2000));
end;

procedure TAiHttpTest.StreamsRecordedAnswer;
var
  M: IAiMailbox;
begin
  StartServer(MockResponse([HttpHead(200, 'text/event-stream'), ReadFixture('sse_ollama_qwen35_reasoning.txt')]));
  M := NewAiMailbox;
  Run(Spec, M);
  AssertTrue('no error: ' + M.ErrorMessage, M.ErrorKind = ekNone);
  AssertEquals('```sql'#10'SELECT COUNT(*) FROM orders;'#10'```', FContent);
  AssertEquals(586, Length(FReasoning));
  AssertEquals(189, M.Usage.CompletionTokens);
  AssertEquals(200, M.HttpStatus);
end;

procedure TAiHttpTest.StreamArrivesIncrementally;
var
  M: IAiMailbox;
begin
  StartServer(MockResponse([HttpHead(200, 'text/event-stream; charset=utf-8'),
    'data: {"choices":[{"delta":{"content":"SEL"}}]}'#10#10,
    'data: {"choices":[{"delta":{"content":"ECT"}}]}'#10#10,
    'data: {"choices":[{"delta":{"content":" 1"},"finish_reason":"stop"}]}'#10#10'data: [DONE]'#10#10], 300));
  M := NewAiMailbox;
  Run(Spec, M);
  AssertTrue(M.ErrorKind = ekNone);
  AssertEquals('SELECT 1', FContent);
  AssertTrue('text was drained while streaming, ' + IntToStr(FDrainCountBeforeFinish) + ' times',
    FDrainCountBeforeFinish >= 2);
end;

procedure TAiHttpTest.RequestCarriesBodyAndHeaders;
var
  M: IAiMailbox;
  Request: String;
begin
  StartServer(MockResponse([HttpHead(200, 'text/event-stream'), 'data: [DONE]'#10#10]));
  M := NewAiMailbox;
  Run(Spec, M);
  Request := FServer.LastRequest;
  AssertTrue('method and path', Request.StartsWith('POST /v1/chat/completions HTTP/1.1'));
  AssertTrue('auth header', Pos('Authorization: Bearer sk-test-secret', Request) > 0);
  AssertTrue('body', Request.EndsWith('{"model":"m","stream":true}'));
end;

procedure TAiHttpTest.ErrorBodyOfUnknownModel;
var
  M: IAiMailbox;
  Body: RawByteString;
begin
  Body := ReadFixture('error_ollama_404_model.json');
  StartServer(MockResponse([HttpHead(404, 'application/json', Length(Body)), Body]));
  M := NewAiMailbox;
  Run(Spec, M);
  AssertTrue(M.ErrorKind = ekNotFound);
  AssertEquals(404, M.HttpStatus);
  AssertEquals('model ''nope:1b'' not found', M.ErrorMessage);
end;

procedure TAiHttpTest.PlainTextErrorOfWrongPath;
var
  M: IAiMailbox;
begin
  StartServer(MockResponse([HttpHead(404, 'text/plain', 19), '404 page not found'#10]));
  M := NewAiMailbox;
  Run(Spec, M);
  AssertTrue(M.ErrorKind = ekNotFound);
  AssertEquals('404 page not found', M.ErrorMessage);
  AssertTrue('key not echoed', Pos('sk-test-secret', M.ErrorMessage) = 0);
end;

procedure TAiHttpTest.NonStreamedAnswerAccepted;
var
  M: IAiMailbox;
  Body: RawByteString;
begin
  Body := '{"choices":[{"message":{"content":"SELECT 2;","reasoning":"r"}}],"usage":{"prompt_tokens":3,"completion_tokens":4}}';
  StartServer(MockResponse([HttpHead(200, 'application/json', Length(Body)), Body]));
  M := NewAiMailbox;
  Run(Spec, M);
  AssertTrue(M.ErrorKind = ekNone);
  AssertEquals('SELECT 2;', FContent);
  AssertEquals('r', FReasoning);
  AssertEquals(4, M.Usage.CompletionTokens);
end;

procedure TAiHttpTest.ErrorInsideStream;
var
  M: IAiMailbox;
begin
  StartServer(MockResponse([HttpHead(200, 'text/event-stream'),
    'data: {"choices":[{"delta":{"content":"partial"}}]}'#10#10,
    'data: {"error":{"message":"context length exceeded"}}'#10#10]));
  M := NewAiMailbox;
  Run(Spec, M);
  AssertTrue(M.ErrorKind = ekServer);
  AssertEquals('context length exceeded', M.ErrorMessage);
  AssertEquals('partial text kept', 'partial', FContent);
end;

procedure TAiHttpTest.StreamEndingEarlyIsProtocolError;
var
  M: IAiMailbox;
begin
  StartServer(MockResponse([HttpHead(200, 'text/event-stream'),
    'data: {"choices":[{"delta":{"content":"SELECT"}}]}'#10#10]));
  M := NewAiMailbox;
  Run(Spec, M);
  AssertTrue(M.ErrorKind = ekProtocol);
end;

procedure TAiHttpTest.BufferModeKeepsBody;
var
  M: IAiMailbox;
  Body: RawByteString;
  S: TAiRequestSpec;
begin
  Body := '{"object":"list","data":[{"id":"qwen2.5:7b"}]}';
  StartServer(MockResponse([HttpHead(200, 'application/json', Length(Body)), Body]));
  M := NewAiMailbox;
  S := Spec(rmBuffer);
  S.Method := 'GET';
  S.Body := '';
  Run(S, M);
  AssertTrue(M.ErrorKind = ekNone);
  AssertEquals(Body, M.Body);
  AssertEquals('no chat text in buffer mode', '', FContent);
end;

procedure TAiHttpTest.ConnectionRefused;
var
  M: IAiMailbox;
  Took: QWord;
begin
  M := NewAiMailbox;
  Took := Run(Spec, M);
  AssertTrue('kind', M.ErrorKind = ekConnect);
  AssertTrue('fast: ' + IntToStr(Took) + ' ms', Took < 2000);
end;

procedure TAiHttpTest.SilentServerTimesOut;
var
  M: IAiMailbox;
  R: TMockResponse;
  Took: QWord;
begin
  R := Default(TMockResponse);
  R.Silent := True;
  StartServer(R);
  M := NewAiMailbox;
  Took := Run(Spec(rmChatStream, 700), M);
  AssertTrue('kind ' + IntToStr(Ord(M.ErrorKind)) + ': ' + M.ErrorMessage, M.ErrorKind = ekTimeout);
  AssertTrue('after the timeout: ' + IntToStr(Took) + ' ms', (Took >= 600) and (Took < 3000));
end;

procedure TAiHttpTest.CancelWakesBlockedRead;
var
  M: IAiMailbox;
  R: TMockResponse;
  Started, CancelledAt: QWord;
  C, Re: String;
begin
  R := Default(TMockResponse);
  R.Silent := True;
  StartServer(R);
  M := NewAiMailbox;
  // Long read timeout: only the socket shutdown can end this quickly
  StartAiRequest(Spec(rmChatStream, 60000), M);
  Started := GetTickCount64;
  Sleep(300);
  AssertFalse('still waiting', M.Finished);
  CancelledAt := GetTickCount64;
  M.Cancel;
  while (not M.Finished) and (GetTickCount64 - CancelledAt < 5000) do
    Sleep(5);
  AssertTrue('finished', M.Finished);
  AssertTrue('within 500 ms of cancel: ' + IntToStr(GetTickCount64 - CancelledAt) + ' ms',
    GetTickCount64 - CancelledAt < 500);
  AssertTrue('cancelled', M.ErrorKind = ekCancelled);
  AssertTrue('worker ended', M.WaitWorkerDone(2000));
  M.Drain(C, Re);
  AssertTrue(GetTickCount64 - Started < 5000);
end;

procedure TAiHttpTest.CancelBeforeStart;
var
  M: IAiMailbox;
  R: TMockResponse;
begin
  R := Default(TMockResponse);
  R.Silent := True;
  StartServer(R);
  M := NewAiMailbox;
  M.Cancel;
  Run(Spec(rmChatStream, 60000), M, 3000);
  AssertTrue(M.ErrorKind = ekCancelled);
end;

initialization
  RegisterTest(TAiHttpTest);

end.
