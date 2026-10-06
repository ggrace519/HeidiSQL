unit test_ai_requestbuild;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.types, ai.profiles, ai.http, ai.requestbuild;

type
  TAiRequestBuildTest = class(TTestCase)
  private
    function Profile: TAiProfile;
    function HasHeader(const Spec: TAiRequestSpec; const Header: String): Boolean;
  published
    procedure ModelsRequest;
    procedure ChatRequest;
    procedure KeyOnlyWhenGiven;
    procedure TlsSettingsCarriedOver;
  end;

implementation

function TAiRequestBuildTest.Profile: TAiProfile;
begin
  Result := NewAiProfile('p');
  Result.BaseUrl := 'https://api.example.com/v1/';
  Result.Model := 'm1';
  Result.IoTimeoutSec := 120;
end;

function TAiRequestBuildTest.HasHeader(const Spec: TAiRequestSpec; const Header: String): Boolean;
var
  H: String;
begin
  for H in Spec.Headers do begin
    if H = Header then
      Exit(True);
  end;
  Result := False;
end;

procedure TAiRequestBuildTest.ModelsRequest;
var
  S: TAiRequestSpec;
begin
  S := ModelsRequestSpec(Profile, '');
  AssertEquals('GET', S.Method);
  AssertEquals('https://api.example.com/v1/models', S.Url);
  AssertTrue(S.Mode = rmBuffer);
  AssertEquals('short timeout', MODELSTIMEOUTMS, S.IoTimeoutMs);
  AssertEquals('', S.Body);
end;

procedure TAiRequestBuildTest.ChatRequest;
var
  S: TAiRequestSpec;
begin
  S := ChatRequestSpec(Profile, 'k', [AiChatMessage(crUser, 'hi')]);
  AssertEquals('POST', S.Method);
  AssertEquals('https://api.example.com/v1/chat/completions', S.Url);
  AssertTrue(S.Mode = rmChatStream);
  AssertEquals('profile timeout', 120000, S.IoTimeoutMs);
  AssertTrue('model in body', Pos('"model" : "m1"', S.Body) > 0);
  AssertTrue('streams', Pos('"stream" : true', S.Body) > 0);
  AssertTrue(HasHeader(S, 'Content-Type: application/json'));
end;

procedure TAiRequestBuildTest.KeyOnlyWhenGiven;
begin
  AssertTrue(HasHeader(ModelsRequestSpec(Profile, 'sk-1'), 'Authorization: Bearer sk-1'));
  AssertFalse(HasHeader(ModelsRequestSpec(Profile, ''), 'Authorization: Bearer '));
end;

procedure TAiRequestBuildTest.TlsSettingsCarriedOver;
var
  P: TAiProfile;
  S: TAiRequestSpec;
begin
  P := Profile;
  AssertFalse('verified by default', ModelsRequestSpec(P, '').TlsAllowUntrusted);
  P.AllowUntrustedTls := True;
  P.ExtraCaFile := ' /etc/ca.pem ';
  S := ChatRequestSpec(P, '', nil);
  AssertTrue(S.TlsAllowUntrusted);
  AssertEquals('/etc/ca.pem', S.TlsExtraCaFile);
end;

initialization
  RegisterTest(TAiRequestBuildTest);

end.
