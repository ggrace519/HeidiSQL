unit ai.requestbuild;

// Builds the HTTP request specs for a provider profile: the model list and chat completions.
// No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.types, ai.profiles, ai.http;

const
  CONNECTTIMEOUTMS = 10000;
  // A model list should come back quickly, also from a local server
  MODELSTIMEOUTMS = 20000;

// GET {base}/models. Key may be empty when the profile needs none.
function ModelsRequestSpec(const Profile: TAiProfile; const Key: String): TAiRequestSpec;

// POST {base}/chat/completions, streamed
function ChatRequestSpec(const Profile: TAiProfile; const Key: String;
  const Messages: TAiChatMessages): TAiRequestSpec;

implementation

uses
  ai.openai;

function BaseSpec(const Profile: TAiProfile; const Key: String): TAiRequestSpec;
begin
  Result := Default(TAiRequestSpec);
  Result.Headers := ['Content-Type: application/json', 'Accept: application/json, text/event-stream'];
  if Key <> '' then
    Result.Headers := Result.Headers + ['Authorization: Bearer ' + Key];
  Result.ConnectTimeoutMs := CONNECTTIMEOUTMS;
  Result.IoTimeoutMs := Profile.IoTimeoutSec * 1000;
  Result.TlsAllowUntrusted := Profile.AllowUntrustedTls;
  Result.TlsExtraCaFile := Profile.ExtraCaFile.Trim;
end;

function ModelsRequestSpec(const Profile: TAiProfile; const Key: String): TAiRequestSpec;
begin
  Result := BaseSpec(Profile, Key);
  Result.Method := 'GET';
  Result.Url := ModelsUrl(Profile.BaseUrl);
  Result.Mode := rmBuffer;
  Result.IoTimeoutMs := MODELSTIMEOUTMS;
end;

function ChatRequestSpec(const Profile: TAiProfile; const Key: String;
  const Messages: TAiChatMessages): TAiRequestSpec;
begin
  Result := BaseSpec(Profile, Key);
  Result.Method := 'POST';
  Result.Url := ChatCompletionsUrl(Profile.BaseUrl);
  Result.Mode := rmChatStream;
  Result.Body := BuildChatRequest(Profile.Model, Messages, Profile.Temperature, True);
end;

end.
