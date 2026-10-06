unit test_ai_openai;

{$mode delphi}{$H+}

interface

uses
  Classes, fpcunit, testregistry, ai.types, ai.openai;

type
  // Replays a recorded stream through the SSE parser and the delta decoder
  TStreamCollector = class
    Content, Reasoning, FinishReason: String;
    Usage: TAiUsage;
    Done: Boolean;
    BadEvents: Integer;
    procedure OnEvent(const EventName, Data: String);
  end;

  TOpenAiFormatTest = class(TTestCase)
  published
    procedure UrlsJoinWithAndWithoutTrailingSlash;
    procedure RequestBodyStreaming;
    procedure RequestBodyWithoutTemperature;
    procedure RequestEscapesSpecialCharacters;
    procedure DeltaContent;
    procedure DeltaReasoningFieldNames;
    procedure DeltaNullContentIsEmpty;
    procedure DeltaDoneSentinel;
    procedure DeltaUsageChunkWithoutChoices;
    procedure DeltaErrorInsideStream;
    procedure DeltaInvalidJson;
    procedure RecordedPlainStream;
    procedure RecordedReasoningStream;
    procedure NonStreamedCompletion;
    procedure StatusToErrorKind;
    procedure ErrorMessageFromRecordedOllama404;
    procedure ErrorMessageVariants;
    procedure ModelListSorted;
    procedure ModelListUnexpectedJson;
    procedure NullErrorIsNoError;
    procedure ContentAsArrayOfParts;
    procedure ModelListDeduplicatedCaseSensitive;
    procedure PaymentRequiredIsAuth;
  end;

implementation

uses
  SysUtils, fpjson, jsonparser, ai.sse, testhelpers;

procedure TStreamCollector.OnEvent(const EventName, Data: String);
var
  Delta: TAiStreamDelta;
begin
  if not DecodeStreamEvent(Data, Delta) then begin
    Inc(BadEvents);
    Exit;
  end;
  Content := Content + Delta.Content;
  Reasoning := Reasoning + Delta.Reasoning;
  if Delta.FinishReason <> '' then
    FinishReason := Delta.FinishReason;
  if Delta.Usage.Known then
    Usage := Delta.Usage;
  if Delta.Done then
    Done := True;
end;

function ReplayFixture(const Name: String): TStreamCollector;
var
  Parser: TSseParser;
begin
  Result := TStreamCollector.Create;
  Parser := TSseParser.Create(Result.OnEvent);
  try
    try
      Parser.Feed(ReadFixture(Name));
      Parser.Finish;
    except
      Result.Free;
      raise;
    end;
  finally
    Parser.Free;
  end;
end;

procedure TOpenAiFormatTest.UrlsJoinWithAndWithoutTrailingSlash;
begin
  AssertEquals('http://h:1/v1/chat/completions', ChatCompletionsUrl('http://h:1/v1'));
  AssertEquals('http://h:1/v1/chat/completions', ChatCompletionsUrl(' http://h:1/v1/ '));
  AssertEquals('https://api.example.com/v1/models', ModelsUrl('https://api.example.com/v1//'));
end;

procedure TOpenAiFormatTest.RequestBodyStreaming;
var
  Json: TJSONObject;
  Messages: TAiChatMessages;
  List: TJSONArray;
begin
  Messages := [AiChatMessage(crSystem, 'sys'), AiChatMessage(crUser, 'question')];
  Json := GetJSON(BuildChatRequest('qwen2.5:7b', Messages, 0.2, True)) as TJSONObject;
  try
    AssertEquals('model', 'qwen2.5:7b', Json.Get('model', ''));
    AssertTrue('stream', Json.Get('stream', False));
    AssertTrue('include_usage', Json.Objects['stream_options'].Get('include_usage', False));
    AssertEquals('temperature', 0.2, Json.Get('temperature', 0.0), 1e-9);
    List := Json.Arrays['messages'];
    AssertEquals('message count', 2, List.Count);
    AssertEquals('system', List.Objects[0].Get('role', ''));
    AssertEquals('sys', List.Objects[0].Get('content', ''));
    AssertEquals('user', List.Objects[1].Get('role', ''));
  finally
    Json.Free;
  end;
end;

procedure TOpenAiFormatTest.RequestBodyWithoutTemperature;
var
  Json: TJSONObject;
begin
  Json := GetJSON(BuildChatRequest('m', [AiChatMessage(crUser, 'q')], -1, False)) as TJSONObject;
  try
    AssertNull('no temperature', Json.Find('temperature'));
    AssertNull('no stream_options', Json.Find('stream_options'));
    AssertFalse('stream false', Json.Get('stream', True));
  finally
    Json.Free;
  end;
end;

procedure TOpenAiFormatTest.RequestEscapesSpecialCharacters;
const
  Tricky = 'SELECT "a", ''b'' FROM `t` -- \ ' + #10 + #9 + 'Café ✓';
var
  Json: TJSONObject;
begin
  Json := GetJSON(BuildChatRequest('m', [AiChatMessage(crUser, Tricky)], -1, True)) as TJSONObject;
  try
    AssertEquals('round trip', Tricky, Json.Arrays['messages'].Objects[0].Get('content', ''));
  finally
    Json.Free;
  end;
end;

procedure TOpenAiFormatTest.DeltaContent;
var
  Delta: TAiStreamDelta;
begin
  AssertTrue(DecodeStreamEvent(
    '{"choices":[{"index":0,"delta":{"content":"SELECT"},"finish_reason":null}]}', Delta));
  AssertEquals('SELECT', Delta.Content);
  AssertEquals('', Delta.FinishReason);
  AssertFalse('not done', Delta.Done);
end;

procedure TOpenAiFormatTest.DeltaReasoningFieldNames;
var
  Delta: TAiStreamDelta;
begin
  DecodeStreamEvent('{"choices":[{"delta":{"content":"","reasoning":"think"}}]}', Delta);
  AssertEquals('ollama field', 'think', Delta.Reasoning);
  DecodeStreamEvent('{"choices":[{"delta":{"reasoning_content":"deep"}}]}', Delta);
  AssertEquals('deepseek/vllm field', 'deep', Delta.Reasoning);
end;

procedure TOpenAiFormatTest.DeltaNullContentIsEmpty;
var
  Delta: TAiStreamDelta;
begin
  AssertTrue(DecodeStreamEvent('{"choices":[{"delta":{"content":null},"finish_reason":"stop"}]}', Delta));
  AssertEquals('', Delta.Content);
  AssertEquals('stop', Delta.FinishReason);
end;

procedure TOpenAiFormatTest.DeltaDoneSentinel;
var
  Delta: TAiStreamDelta;
begin
  AssertTrue(DecodeStreamEvent('[DONE]', Delta));
  AssertTrue(Delta.Done);
end;

procedure TOpenAiFormatTest.DeltaUsageChunkWithoutChoices;
var
  Delta: TAiStreamDelta;
begin
  AssertTrue(DecodeStreamEvent(
    '{"choices":[],"usage":{"prompt_tokens":29,"completion_tokens":11,"total_tokens":40}}', Delta));
  AssertTrue('usage known', Delta.Usage.Known);
  AssertEquals(29, Delta.Usage.PromptTokens);
  AssertEquals(11, Delta.Usage.CompletionTokens);
end;

procedure TOpenAiFormatTest.DeltaErrorInsideStream;
var
  Delta: TAiStreamDelta;
begin
  AssertTrue(DecodeStreamEvent('{"error":{"message":"context length exceeded","type":"x"}}', Delta));
  AssertEquals('context length exceeded', Delta.ErrorMessage);
end;

procedure TOpenAiFormatTest.DeltaInvalidJson;
var
  Delta: TAiStreamDelta;
begin
  AssertFalse('broken', DecodeStreamEvent('{"choices":[', Delta));
  AssertFalse('array', DecodeStreamEvent('[1,2]', Delta));
end;

procedure TOpenAiFormatTest.RecordedPlainStream;
var
  C: TStreamCollector;
begin
  C := ReplayFixture('sse_ollama_qwen25.txt');
  try
    AssertEquals('no bad events', 0, C.BadEvents);
    AssertEquals('```sql'#10'SELECT COUNT(*) FROM orders;'#10'```', C.Content);
    AssertEquals('no reasoning', '', C.Reasoning);
    AssertEquals('stop', C.FinishReason);
    AssertTrue('done', C.Done);
    AssertEquals('prompt tokens', 29, C.Usage.PromptTokens);
    AssertEquals('completion tokens', 11, C.Usage.CompletionTokens);
  finally
    C.Free;
  end;
end;

procedure TOpenAiFormatTest.RecordedReasoningStream;
var
  C: TStreamCollector;
begin
  C := ReplayFixture('sse_ollama_qwen35_reasoning.txt');
  try
    AssertEquals('no bad events', 0, C.BadEvents);
    AssertEquals('answer only', '```sql'#10'SELECT COUNT(*) FROM orders;'#10'```', C.Content);
    AssertEquals('reasoning length', 586, Length(C.Reasoning));
    AssertTrue('reasoning text', C.Reasoning.StartsWith('Thinking Process:'));
    AssertEquals('completion tokens', 189, C.Usage.CompletionTokens);
  finally
    C.Free;
  end;
end;

procedure TOpenAiFormatTest.NonStreamedCompletion;
var
  Content, Reasoning: String;
  Usage: TAiUsage;
begin
  AssertTrue(DecodeCompletion('{"choices":[{"index":0,"message":{"role":"assistant",' +
    '"content":"SELECT 1;","reasoning_content":"r"},"finish_reason":"stop"}],' +
    '"usage":{"prompt_tokens":5,"completion_tokens":3}}', Content, Reasoning, Usage));
  AssertEquals('SELECT 1;', Content);
  AssertEquals('r', Reasoning);
  AssertEquals(5, Usage.PromptTokens);
  AssertFalse('no choices', DecodeCompletion('{"choices":[]}', Content, Reasoning, Usage));
  AssertFalse('not json', DecodeCompletion('oops', Content, Reasoning, Usage));
end;

procedure TOpenAiFormatTest.StatusToErrorKind;
begin
  AssertTrue(ErrorKindFromStatus(200) = ekNone);
  AssertTrue(ErrorKindFromStatus(401) = ekAuth);
  AssertTrue(ErrorKindFromStatus(403) = ekAuth);
  AssertTrue(ErrorKindFromStatus(404) = ekNotFound);
  AssertTrue(ErrorKindFromStatus(400) = ekBadRequest);
  AssertTrue(ErrorKindFromStatus(422) = ekBadRequest);
  AssertTrue(ErrorKindFromStatus(429) = ekRateLimit);
  AssertTrue(ErrorKindFromStatus(503) = ekServer);
end;

procedure TOpenAiFormatTest.ErrorMessageFromRecordedOllama404;
begin
  AssertEquals('model ''nope:1b'' not found',
    ExtractErrorMessage(ReadFixture('error_ollama_404_model.json')));
end;

procedure TOpenAiFormatTest.ErrorMessageVariants;
begin
  AssertEquals('string error', 'bad key', ExtractErrorMessage('{"error":"bad key"}'));
  AssertEquals('top-level message', 'nope', ExtractErrorMessage('{"message":"nope"}'));
  AssertEquals('plain text', '404 page not found', ExtractErrorMessage('404 page not found'#10));
  AssertEquals('empty', '', ExtractErrorMessage('  '));
  AssertEquals('long text shortened', 303, Length(ExtractErrorMessage(StringOfChar('x', 1000))));
end;

procedure TOpenAiFormatTest.ModelListSorted;
var
  Ids: TStringArray;
begin
  Ids := DecodeModelList('{"object":"list","data":[{"id":"qwen2.5:7b"},{"id":"tev1:4b"},' +
    '{"id":"qwen3.5:9b"},{"object":"model"}]}');
  AssertEquals('count without empty ids', 3, Length(Ids));
  AssertEquals('qwen2.5:7b', Ids[0]);
  AssertEquals('qwen3.5:9b', Ids[1]);
  AssertEquals('tev1:4b', Ids[2]);
end;

procedure TOpenAiFormatTest.ModelListUnexpectedJson;
begin
  AssertEquals(0, Length(DecodeModelList('[]')));
  AssertEquals(0, Length(DecodeModelList('{"data":"x"}')));
  AssertEquals(0, Length(DecodeModelList('not json')));
end;

procedure TOpenAiFormatTest.NullErrorIsNoError;
var
  Delta: TAiStreamDelta;
begin
  AssertTrue(DecodeStreamEvent('{"error":null,"choices":[{"delta":{"content":"x"}}]}', Delta));
  AssertEquals('no error', '', Delta.ErrorMessage);
  AssertEquals('x', Delta.Content);
  AssertEquals('null error body falls back to raw text', '{"error":null}', ExtractErrorMessage('{"error":null}'));
end;

procedure TOpenAiFormatTest.ContentAsArrayOfParts;
var
  Delta: TAiStreamDelta;
  Content, Reasoning: String;
  Usage: TAiUsage;
begin
  DecodeStreamEvent('{"choices":[{"delta":{"content":[{"type":"text","text":"SEL"},"ECT"]}}]}', Delta);
  AssertEquals('SELECT', Delta.Content);
  DecodeCompletion('{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}',
    Content, Reasoning, Usage);
  AssertEquals('ab', Content);
end;

procedure TOpenAiFormatTest.ModelListDeduplicatedCaseSensitive;
var
  Ids: TStringArray;
begin
  Ids := DecodeModelList('{"data":[{"id":"m"},{"id":"m"},{"id":"M"}]}');
  AssertEquals(2, Length(Ids));
end;

procedure TOpenAiFormatTest.PaymentRequiredIsAuth;
begin
  AssertTrue(ErrorKindFromStatus(402) = ekAuth);
end;

initialization
  RegisterTest(TOpenAiFormatTest);

end.
