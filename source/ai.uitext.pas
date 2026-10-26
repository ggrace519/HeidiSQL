unit ai.uitext;

// User-facing, translated texts for AI assistant states: key lookup results, request errors and
// profile validation problems. The core units return codes; this unit words them.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.types, ai.profiles, ai.keystore;

// Status of a profile's key, e.g. "Key found in keychain" or why it is missing
function KeyResultText(KeyResult: TAiKeyResult; const Profile: TAiProfile; const Problem: String): String;
// Message for a failed request; Detail is the server's or library's own message
function RequestErrorText(Kind: TAiErrorKind; HttpStatus: Integer; const Detail: String;
  const Profile: TAiProfile): String;
// One line per validation problem
function ProfileProblemsText(Problems: TAiProfileProblems): String;

implementation

uses
  apphelpers;

function WithDetail(const Text, Detail: String): String;
begin
  Result := Text;
  if Detail.Trim <> '' then
    Result := Result + ' (' + Detail.Trim + ')';
end;

function KeyResultText(KeyResult: TAiKeyResult; const Profile: TAiProfile; const Problem: String): String;
begin
  case KeyResult of
    krNotNeeded:
      Result := _('No API key is used');
    krFound:
      if Profile.KeySource = ksEnvironment then
        Result := f_('Key found in environment variable %s', [Profile.KeyName])
      else
        Result := f_('Key found in keychain entry "%s"', [Profile.KeyName]);
    krEnvNotSet:
      Result := f_('Environment variable %s is not set. Programs started from the desktop menu may not see variables from a shell profile.',
        [Profile.KeyName]);
    krKeychainNotFound:
      Result := f_('No keychain entry "%s" yet. Use "Store key".', [Profile.KeyName]);
    krKeychainUnavailable:
      Result := WithDetail(_('The keychain of this system is not available'), Problem);
    krKeychainError:
      Result := WithDetail(_('The keychain refused access'), Problem);
    else
      Result := '';
  end;
end;

function RequestErrorText(Kind: TAiErrorKind; HttpStatus: Integer; const Detail: String;
  const Profile: TAiProfile): String;
begin
  case Kind of
    ekNone:
      Result := '';
    ekAuth:
      Result := WithDetail(_('The server rejected the API key.'), Detail);
    ekNotFound:
      Result := WithDetail(f_('Not found: check that the base URL ends with /v1 and that the model "%s" exists.',
        [Profile.Model]), Detail);
    ekBadRequest:
      Result := WithDetail(_('The server did not accept the request.'), Detail);
    ekRateLimit:
      Result := WithDetail(_('Too many requests: the provider is rate limiting. Try again later.'), Detail);
    ekServer:
      Result := WithDetail(_('The server reported an error.'), Detail);
    ekConnect:
      Result := WithDetail(f_('Cannot connect to %s.', [Profile.BaseUrl]), Detail);
    ekTimeout:
      Result := WithDetail(_('No answer in time. Local models may need a longer timeout for large requests.'), Detail);
    ekCancelled:
      Result := _('Cancelled.');
    ekProtocol:
      Result := WithDetail(_('The answer could not be understood.'), Detail);
    else
      Result := Detail;
  end;
  if (HttpStatus > 0) and (Kind <> ekNone) then
    Result := Result + ' [HTTP ' + IntToStr(HttpStatus) + ']';
end;

function ProfileProblemsText(Problems: TAiProfileProblems): String;
var
  Lines: TStringArray;

  procedure Add(const Line: String);
  begin
    SetLength(Lines, Length(Lines) + 1);
    Lines[High(Lines)] := Line;
  end;

begin
  Lines := nil;
  if ppNoName in Problems then
    Add(_('Enter a name.'));
  if ppBadUrl in Problems then
    Add(_('The base URL must start with http:// or https://.'));
  if ppNoModel in Problems then
    Add(_('Enter or select a model.'));
  if ppNoKeyName in Problems then
    Add(_('Enter the name of the environment variable or keychain entry.'));
  if ppContextSize in Problems then
    Add(_('The context size must be between 1000 and 1000000 characters.'));
  if ppTimeout in Problems then
    Add(_('The timeout must be between 5 and 3600 seconds.'));
  if ppCaFileMissing in Problems then
    Add(_('The CA file does not exist.'));
  Result := String.Join(LineEnding, Lines);
end;

end.
