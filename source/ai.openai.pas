unit ai.openai;

// Wire format of the OpenAI-compatible chat completions API, as served by Ollama, LM Studio,
// vLLM, llama.cpp, OpenRouter and OpenAI: request bodies, streamed chunks, error bodies and
// model lists. Pure JSON handling, no networking and no LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.types;

type
  // Decoded content of one streamed event ("data:" payload)
  TAiStreamDelta = record
    Content: String;       // Answer text
    Reasoning: String;     // "Thinking" text of reasoning models, shown separately
    FinishReason: String;  // e.g. "stop", "length"; empty while streaming
    Done: Boolean;         // The "[DONE]" sentinel
    Usage: TAiUsage;
    ErrorMessage: String;  // Error object sent inside the stream
  end;

// URL helpers; BaseUrl is e.g. "http://127.0.0.1:11434/v1", with or without trailing slash
function ChatCompletionsUrl(const BaseUrl: String): String;
function ModelsUrl(const BaseUrl: String): String;

// JSON body for POST /chat/completions. Temperature < 0 leaves it to the server default.
function BuildChatRequest(const Model: String; const Messages: TAiChatMessages;
  Temperature: Double; Stream: Boolean): String;

// Decodes one "data:" payload of a streamed response. Returns False if the payload is not
// valid JSON (the caller should treat that as a protocol error).
function DecodeStreamEvent(const Data: String; out Delta: TAiStreamDelta): Boolean;

// Decodes a complete, non-streamed response. Returns False if it has no choices.
function DecodeCompletion(const Json: String; out Content, Reasoning: String;
  out Usage: TAiUsage): Boolean;

// Error kind for an HTTP status code; ekNone for 2xx
function ErrorKindFromStatus(Status: Integer): TAiErrorKind;

// The server's error message from an error body: {"error":{"message":..}}, {"error":".."},
// {"message":..} or plain text (shortened). Empty if the body is empty.
function ExtractErrorMessage(const Body: String): String;

// Model ids from GET /models, sorted. Empty array for unexpected JSON.
function DecodeModelList(const Json: String): TStringArray;

implementation

uses
  Classes, fpjson, jsonparser, ai.text;

const
  ROLENAMES: array[TAiChatRole] of String = ('system', 'user', 'assistant');
  MAXPLAINERRORLEN = 300;

function JoinUrl(const BaseUrl, Path: String): String;
begin
  Result := BaseUrl.Trim;
  while Result.EndsWith('/') do
    SetLength(Result, Length(Result)-1);
  Result := Result + Path;
end;

function ChatCompletionsUrl(const BaseUrl: String): String;
begin
  Result := JoinUrl(BaseUrl, '/chat/completions');
end;

function ModelsUrl(const BaseUrl: String): String;
begin
  Result := JoinUrl(BaseUrl, '/models');
end;

function TryParseJson(const Text: String): TJSONData;
begin
  try
    Result := GetJSON(Text);
  except
    Result := nil;
  end;
end;

function BuildChatRequest(const Model: String; const Messages: TAiChatMessages;
  Temperature: Double; Stream: Boolean): String;
var
  Root, Msg: TJSONObject;
  List: TJSONArray;
  i: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('model', Model);
    Root.Add('stream', Stream);
    if Stream then
      Root.Add('stream_options', TJSONObject.Create(['include_usage', True]));
    if Temperature >= 0 then
      Root.Add('temperature', Temperature);
    List := TJSONArray.Create;
    for i:=0 to High(Messages) do begin
      Msg := TJSONObject.Create;
      Msg.Add('role', ROLENAMES[Messages[i].Role]);
      Msg.Add('content', Messages[i].Content);
      List.Add(Msg);
    end;
    Root.Add('messages', List);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

procedure ReadUsage(Obj: TJSONObject; var Usage: TAiUsage);
var
  UsageObj: TJSONObject;
begin
  UsageObj := Obj.Find('usage', jtObject) as TJSONObject;
  if UsageObj = nil then
    Exit;
  Usage.Known := True;
  Usage.PromptTokens := UsageObj.Get('prompt_tokens', 0);
  Usage.CompletionTokens := UsageObj.Get('completion_tokens', 0);
end;

function ErrorMessageOf(Obj: TJSONObject): String;
var
  ErrData: TJSONData;
begin
  Result := '';
  ErrData := Obj.Find('error');
  // "error": null is sent by some servers in healthy chunks
  if (ErrData = nil) or (ErrData.JSONType = jtNull) then
    Exit;
  if ErrData is TJSONObject then
    Result := TJSONObject(ErrData).Get('message', '')
  else if ErrData is TJSONString then
    Result := ErrData.AsString;
  if Result = '' then
    Result := ErrData.AsJSON;
end;

// Text of a "content" field: a string, or an array of parts like {"type":"text","text":".."}
function ContentOf(Obj: TJSONObject): String;
var
  Data: TJSONData;
  Parts: TJSONArray;
  i: Integer;
begin
  Result := '';
  Data := Obj.Find('content');
  if Data is TJSONString then
    Result := Data.AsString
  else if Data is TJSONArray then begin
    Parts := TJSONArray(Data);
    for i:=0 to Parts.Count-1 do begin
      if Parts[i] is TJSONString then
        Result := Result + Parts[i].AsString
      else if Parts[i] is TJSONObject then
        Result := Result + TJSONObject(Parts[i]).Get('text', '');
    end;
  end;
end;

// Text of a "reasoning" field: reasoning_content (DeepSeek, vLLM) or reasoning (Ollama, OpenRouter)
function ReasoningOf(Obj: TJSONObject): String;
begin
  Result := Obj.Get('reasoning_content', '');
  if Result = '' then
    Result := Obj.Get('reasoning', '');
end;

function DecodeStreamEvent(const Data: String; out Delta: TAiStreamDelta): Boolean;
var
  Parsed: TJSONData;
  Obj, Choice, DeltaObj: TJSONObject;
  Choices: TJSONArray;
begin
  Delta := Default(TAiStreamDelta);
  if Data.Trim = '[DONE]' then begin
    Delta.Done := True;
    Exit(True);
  end;
  Parsed := TryParseJson(Data);
  if not (Parsed is TJSONObject) then begin
    Parsed.Free;
    Exit(False);
  end;
  try
    Obj := TJSONObject(Parsed);
    Delta.ErrorMessage := ErrorMessageOf(Obj);
    ReadUsage(Obj, Delta.Usage);
    Choices := Obj.Find('choices', jtArray) as TJSONArray;
    if (Choices <> nil) and (Choices.Count > 0) and (Choices[0] is TJSONObject) then begin
      Choice := TJSONObject(Choices[0]);
      Delta.FinishReason := Choice.Get('finish_reason', '');
      DeltaObj := Choice.Find('delta', jtObject) as TJSONObject;
      if DeltaObj <> nil then begin
        Delta.Content := ContentOf(DeltaObj);
        Delta.Reasoning := ReasoningOf(DeltaObj);
      end;
    end;
    Result := True;
  finally
    Parsed.Free;
  end;
end;

function DecodeCompletion(const Json: String; out Content, Reasoning: String;
  out Usage: TAiUsage): Boolean;
var
  Parsed: TJSONData;
  Obj, Choice, Msg: TJSONObject;
  Choices: TJSONArray;
begin
  Content := '';
  Reasoning := '';
  Usage := Default(TAiUsage);
  Result := False;
  Parsed := TryParseJson(Json);
  try
    if not (Parsed is TJSONObject) then
      Exit;
    Obj := TJSONObject(Parsed);
    ReadUsage(Obj, Usage);
    Choices := Obj.Find('choices', jtArray) as TJSONArray;
    if (Choices = nil) or (Choices.Count = 0) or not (Choices[0] is TJSONObject) then
      Exit;
    Choice := TJSONObject(Choices[0]);
    Msg := Choice.Find('message', jtObject) as TJSONObject;
    if Msg <> nil then begin
      Content := ContentOf(Msg);
      Reasoning := ReasoningOf(Msg);
    end;
    Result := True;
  finally
    Parsed.Free;
  end;
end;

function ErrorKindFromStatus(Status: Integer): TAiErrorKind;
begin
  case Status of
    200..299: Result := ekNone;
    401, 402, 403: Result := ekAuth; // 402: billing / quota of the account
    404: Result := ekNotFound;
    408: Result := ekTimeout;
    429: Result := ekRateLimit;
    500..599: Result := ekServer;
    else Result := ekBadRequest;
  end;
end;

function ExtractErrorMessage(const Body: String): String;
var
  Parsed: TJSONData;
begin
  Result := '';
  if Body.Trim = '' then
    Exit;
  Parsed := TryParseJson(Body);
  try
    if Parsed is TJSONObject then begin
      Result := ErrorMessageOf(TJSONObject(Parsed));
      if Result = '' then
        Result := TJSONObject(Parsed).Get('message', '');
    end;
  finally
    Parsed.Free;
  end;
  if Result = '' then begin
    // Not JSON, e.g. "404 page not found" from a wrong path, or an HTML proxy error page
    Result := Utf8Truncate(Body.Trim, MAXPLAINERRORLEN);
  end;
end;

function DecodeModelList(const Json: String): TStringArray;
var
  Parsed: TJSONData;
  Data: TJSONArray;
  Ids: TStringList;
  i: Integer;
begin
  Result := nil;
  Parsed := TryParseJson(Json);
  Ids := TStringList.Create;
  Ids.Sorted := True;
  Ids.CaseSensitive := True;
  Ids.Duplicates := dupIgnore;
  try
    if not (Parsed is TJSONObject) then
      Exit;
    Data := TJSONObject(Parsed).Find('data', jtArray) as TJSONArray;
    if Data = nil then
      Exit;
    for i:=0 to Data.Count-1 do begin
      if Data[i] is TJSONObject then
        Ids.Add(TJSONObject(Data[i]).Get('id', ''));
    end;
    while (Ids.Count > 0) and (Ids[0] = '') do
      Ids.Delete(0);
    Result := Ids.ToStringArray;
  finally
    Ids.Free;
    Parsed.Free;
  end;
end;

end.
