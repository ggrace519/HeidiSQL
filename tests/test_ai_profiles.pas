unit test_ai_profiles;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.profiles;

type
  TAiProfilesTest = class(TTestCase)
  private
    FList: TAiProfileList;
    FTempDir: String;
    function Ollama: TAiProfile;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure NewProfileDefaults;
    procedure NewProfilesGetDistinctIds;
    procedure ValidateFindsProblems;
    procedure ValidateAcceptsGoodProfile;
    procedure JsonRoundTrip;
    procedure JsonNeverContainsKeyValue;
    procedure ResolveFallsBackToDefault;
    procedure ResolveEmptyList;
    procedure DeleteDefaultPicksAnother;
    procedure UpdateReplacesById;
    procedure LoadCorruptAndForeignJson;
    procedure LoadNewerVersionRefused;
    procedure LoadHandEditedFile;
    procedure LoadDuplicateIdsGetNewIds;
    procedure FileMissing;
    procedure FileSaveAndReload;
  end;

implementation

uses
  Classes;

procedure TAiProfilesTest.SetUp;
begin
  FList := TAiProfileList.Create;
  FTempDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'heidisql-tests-' + IntToStr(GetProcessID) + PathDelim;
  ForceDirectories(FTempDir);
end;

procedure TAiProfilesTest.TearDown;
begin
  FList.Free;
  DeleteFile(FTempDir + AIPROFILESFILE);
  DeleteFile(FTempDir + AIPROFILESFILE + '.tmp');
  RemoveDir(FTempDir);
end;

function TAiProfilesTest.Ollama: TAiProfile;
begin
  Result := NewAiProfile('Local Ollama');
  Result.Model := 'qwen2.5:7b';
end;

procedure TAiProfilesTest.NewProfileDefaults;
var
  P: TAiProfile;
begin
  P := NewAiProfile('x');
  AssertEquals(DEFAULTLOCALBASEURL, P.BaseUrl);
  AssertTrue('no key', P.KeySource = ksNone);
  AssertEquals(0.2, P.Temperature, 1e-9);
  AssertEquals(8000, P.MaxContextChars);
  AssertEquals(300, P.IoTimeoutSec);
  AssertTrue('guid', (Length(P.Id) = 38) and (P.Id[1] = '{'));
end;

procedure TAiProfilesTest.NewProfilesGetDistinctIds;
begin
  AssertFalse(NewAiProfile('a').Id = NewAiProfile('a').Id);
end;

procedure TAiProfilesTest.ValidateFindsProblems;
var
  P: TAiProfile;
begin
  P := NewAiProfile(' ');
  P.BaseUrl := 'localhost:11434';
  P.KeySource := ksEnvironment;
  P.MaxContextChars := 10;
  P.IoTimeoutSec := 0;
  AssertTrue(ValidateAiProfile(P) = [ppNoName, ppBadUrl, ppNoModel, ppNoKeyName, ppContextSize, ppTimeout]);
end;

procedure TAiProfilesTest.ValidateAcceptsGoodProfile;
var
  P: TAiProfile;
begin
  P := Ollama;
  AssertTrue(ValidateAiProfile(P) = []);
  P.BaseUrl := 'HTTPS://api.example.com/v1';
  P.KeySource := ksKeychain;
  P.KeyName := 'example';
  AssertTrue(ValidateAiProfile(P) = []);
end;

procedure TAiProfilesTest.JsonRoundTrip;
var
  A, B: TAiProfile;
  Other: TAiProfileList;
begin
  A := Ollama;
  B := NewAiProfile('Cloud');
  B.BaseUrl := 'https://api.example.com/v1';
  B.Model := 'big-model';
  B.KeySource := ksKeychain;
  B.KeyName := 'heidisql-cloud';
  B.Temperature := -1;
  B.MaxContextChars := 40000;
  B.IoTimeoutSec := 60;
  FList.Add(A);
  FList.Add(B);
  FList.DefaultId := B.Id;
  Other := TAiProfileList.Create;
  try
    AssertTrue(Other.LoadFromJson(FList.ToJson) = plrOk);
    AssertEquals(2, Other.Count);
    AssertEquals('default kept', B.Id, Other.DefaultId);
    AssertEquals(A.Id, Other[0].Id);
    AssertEquals('Cloud', Other[1].Name);
    AssertEquals('https://api.example.com/v1', Other[1].BaseUrl);
    AssertEquals('big-model', Other[1].Model);
    AssertTrue(Other[1].KeySource = ksKeychain);
    AssertEquals('heidisql-cloud', Other[1].KeyName);
    AssertEquals(-1, Other[1].Temperature, 1e-9);
    AssertEquals(40000, Other[1].MaxContextChars);
    AssertEquals(60, Other[1].IoTimeoutSec);
  finally
    Other.Free;
  end;
end;

procedure TAiProfilesTest.JsonNeverContainsKeyValue;
var
  P: TAiProfile;
begin
  P := Ollama;
  P.KeySource := ksEnvironment;
  P.KeyName := 'OPENAI_API_KEY';
  FList.Add(P);
  // Only the variable name is stored, the record has no field for a key value
  AssertTrue(Pos('"keyName" : "OPENAI_API_KEY"', FList.ToJson) > 0);
  AssertTrue(Pos('"keySource" : "env"', FList.ToJson) > 0);
end;

procedure TAiProfilesTest.ResolveFallsBackToDefault;
var
  A, B, R: TAiProfile;
begin
  A := Ollama;
  B := NewAiProfile('B');
  FList.Add(A);
  FList.Add(B);
  FList.DefaultId := B.Id;
  AssertTrue(FList.Resolve(A.Id, R));
  AssertEquals('exact', A.Id, R.Id);
  AssertTrue(FList.Resolve('', R));
  AssertEquals('empty id -> default', B.Id, R.Id);
  AssertTrue(FList.Resolve('{deleted}', R));
  AssertEquals('unknown id -> default', B.Id, R.Id);
end;

procedure TAiProfilesTest.ResolveEmptyList;
var
  R: TAiProfile;
begin
  AssertFalse(FList.Resolve('', R));
end;

procedure TAiProfilesTest.DeleteDefaultPicksAnother;
var
  A, B: TAiProfile;
begin
  A := Ollama;
  B := NewAiProfile('B');
  FList.Add(A);
  FList.Add(B);
  AssertEquals('first added is default', A.Id, FList.DefaultId);
  FList.Delete(A.Id);
  AssertEquals(1, FList.Count);
  AssertEquals(B.Id, FList.DefaultId);
  FList.Delete(B.Id);
  AssertEquals('', FList.DefaultId);
end;

procedure TAiProfilesTest.UpdateReplacesById;
var
  A: TAiProfile;
begin
  A := Ollama;
  FList.Add(A);
  A.Name := 'Renamed';
  FList.Update(A);
  AssertEquals(1, FList.Count);
  AssertEquals('Renamed', FList[0].Name);
end;

procedure TAiProfilesTest.LoadCorruptAndForeignJson;
begin
  AssertTrue(FList.LoadFromJson('{"profiles": [') = plrCorrupt);
  AssertTrue(FList.LoadFromJson('[1,2]') = plrCorrupt);
  AssertTrue(FList.LoadFromJson('{"version":1}') = plrCorrupt);
  AssertEquals(0, FList.Count);
end;

procedure TAiProfilesTest.LoadNewerVersionRefused;
begin
  AssertTrue(FList.LoadFromJson('{"version":99,"profiles":[]}') = plrNewerVersion);
end;

procedure TAiProfilesTest.LoadHandEditedFile;
begin
  AssertTrue(FList.LoadFromJson('{"profiles":[{"id":"x","name":"Hand","baseUrl":"http://h/v1",' +
    '"model":"m","keySource":"bogus","temperature":1,"maxContextChars":12000}]}') = plrOk);
  AssertEquals(1, FList.Count);
  AssertEquals('integer temperature', 1.0, FList[0].Temperature, 1e-9);
  AssertTrue('unknown key source', FList[0].KeySource = ksNone);
  AssertEquals(12000, FList[0].MaxContextChars);
  AssertEquals('missing value gets default', 300, FList[0].IoTimeoutSec);
  AssertEquals('default id repaired', 'x', FList.DefaultId);
end;

procedure TAiProfilesTest.LoadDuplicateIdsGetNewIds;
begin
  FList.LoadFromJson('{"profiles":[{"id":"same","name":"a"},{"id":"same","name":"b"},{"name":"c"}]}');
  AssertEquals(3, FList.Count);
  AssertEquals('same', FList[0].Id);
  AssertFalse('duplicate replaced', FList[1].Id = 'same');
  AssertFalse('missing id generated', FList[2].Id = '');
end;

procedure TAiProfilesTest.FileMissing;
begin
  AssertTrue(FList.LoadFromFile(FTempDir + 'nope.json') = plrMissing);
end;

procedure TAiProfilesTest.FileSaveAndReload;
var
  Other: TAiProfileList;
  P: TAiProfile;
begin
  P := Ollama;
  P.Name := 'Café ✓';
  FList.Add(P);
  FList.SaveToFile(FTempDir + AIPROFILESFILE);
  FList.SaveToFile(FTempDir + AIPROFILESFILE); // replacing an existing file works
  AssertFalse('no temp file left', FileExists(FTempDir + AIPROFILESFILE + '.tmp'));
  Other := TAiProfileList.Create;
  try
    AssertTrue(Other.LoadFromFile(FTempDir + AIPROFILESFILE) = plrOk);
    AssertEquals('Café ✓', Other[0].Name);
  finally
    Other.Free;
  end;
end;

initialization
  RegisterTest(TAiProfilesTest);

end.
