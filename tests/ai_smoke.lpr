program ai_smoke;

// Manual check of ai.http against a real OpenAI-compatible server.
//   ai_smoke <base-url> <model> [--key-env NAME] [--prompt TEXT] [--cancel-after MS]
//   ai_smoke <base-url> --models [--key-env NAME]
// The key is read from the named environment variable and never printed.
// Build: make smoke

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  LazUTF8, Classes, SysUtils, ai.types, ai.openai, ai.http;

const
  KINDNAMES: array[TAiErrorKind] of String = ('none', 'auth', 'not found', 'bad request',
    'rate limit', 'server', 'connect', 'timeout', 'cancelled', 'protocol');

function OptionValue(const Name, Default: String): String;
var
  i: Integer;
begin
  Result := Default;
  for i:=1 to ParamCount-1 do begin
    if ParamStr(i) = Name then
      Exit(ParamStr(i + 1));
  end;
end;

function HasOption(const Name: String): Boolean;
var
  i: Integer;
begin
  for i:=1 to ParamCount do begin
    if ParamStr(i) = Name then
      Exit(True);
  end;
  Result := False;
end;

var
  Spec: TAiRequestSpec;
  Mailbox: IAiMailbox;
  BaseUrl, KeyEnv, Key, Content, Reasoning, Id: String;
  Started, FirstByte: QWord;
  CancelAfter: Integer;
  Usage: TAiUsage;
begin
  if ParamCount < 2 then begin
    WriteLn('Usage: ai_smoke <base-url> <model> [--key-env NAME] [--prompt TEXT] [--cancel-after MS]');
    WriteLn('       ai_smoke <base-url> --models [--key-env NAME]');
    Halt(2);
  end;
  BaseUrl := ParamStr(1);
  Spec := Default(TAiRequestSpec);
  Spec.Headers := ['Content-Type: application/json'];
  KeyEnv := OptionValue('--key-env', '');
  if KeyEnv <> '' then begin
    Key := GetEnvironmentVariable(KeyEnv);
    if Key = '' then begin
      WriteLn('Environment variable ', KeyEnv, ' is empty');
      Halt(2);
    end;
    Spec.Headers := Spec.Headers + ['Authorization: Bearer ' + Key];
  end;
  Spec.ConnectTimeoutMs := 10000;
  Spec.IoTimeoutMs := 300000;
  if HasOption('--models') then begin
    Spec.Method := 'GET';
    Spec.Url := ModelsUrl(BaseUrl);
    Spec.Mode := rmBuffer;
  end else begin
    Spec.Method := 'POST';
    Spec.Url := ChatCompletionsUrl(BaseUrl);
    Spec.Mode := rmChatStream;
    Spec.Body := BuildChatRequest(ParamStr(2), [AiChatMessage(crUser,
      OptionValue('--prompt', 'Write one SQL query that counts rows in table orders.'))], 0.2, True);
  end;
  CancelAfter := StrToIntDef(OptionValue('--cancel-after', ''), 0);

  Mailbox := NewAiMailbox;
  Started := GetTickCount64;
  FirstByte := 0;
  StartAiRequest(Spec, Mailbox);
  repeat
    Sleep(50);
    if Mailbox.Drain(Content, Reasoning) then begin
      if FirstByte = 0 then
        FirstByte := GetTickCount64 - Started;
      if Reasoning <> '' then
        Write(#27'[2m', Reasoning, #27'[0m');
      Write(Content);
    end;
    if (CancelAfter > 0) and (GetTickCount64 - Started >= QWord(CancelAfter)) and not Mailbox.Finished then begin
      WriteLn(LineEnding, '[cancelling]');
      Mailbox.Cancel;
      CancelAfter := 0;
    end;
  until Mailbox.Finished;
  Mailbox.Drain(Content, Reasoning);
  Write(Content);
  WriteLn;
  if Spec.Mode = rmBuffer then
    for Id in DecodeModelList(Mailbox.Body) do
      WriteLn('model: ', Id);
  Usage := Mailbox.Usage;
  WriteLn('--- result: ', KINDNAMES[Mailbox.ErrorKind], ', HTTP ', Mailbox.HttpStatus,
    ', first data after ', FirstByte, ' ms, total ', GetTickCount64 - Started, ' ms');
  if Usage.Known then
    WriteLn('--- tokens: prompt ', Usage.PromptTokens, ', completion ', Usage.CompletionTokens);
  if Mailbox.ErrorMessage <> '' then
    WriteLn('--- message: ', Mailbox.ErrorMessage);
  Mailbox.WaitWorkerDone(3000);
  if Mailbox.ErrorKind <> ekNone then
    Halt(1);
end.
