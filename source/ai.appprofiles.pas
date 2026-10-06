unit ai.appprofiles;

// Where the application keeps its AI provider profiles: ai-providers.json in the settings folder.
// A missing file is seeded with a profile for a local Ollama server.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.profiles;

function AppProfilesFileName: String;

// Loads the profiles. When the file does not exist yet, List gets the starter profile.
function LoadAppProfiles(List: TAiProfileList): TAiProfilesLoadResult;
procedure SaveAppProfiles(List: TAiProfileList);

implementation

uses
  apphelpers; // AppSettings

const
  STARTERMODEL = 'qwen2.5:7b';

function AppProfilesFileName: String;
begin
  Result := AppSettings.DirnameUserAppData + AIPROFILESFILE;
end;

function LoadAppProfiles(List: TAiProfileList): TAiProfilesLoadResult;
var
  Starter: TAiProfile;
begin
  Result := List.LoadFromFile(AppProfilesFileName);
  if Result = plrMissing then begin
    // Not translated: the name is saved, and the language may change later
    Starter := NewAiProfile('Local Ollama');
    Starter.Model := STARTERMODEL;
    List.Add(Starter);
  end;
end;

procedure SaveAppProfiles(List: TAiProfileList);
begin
  List.SaveToFile(AppProfilesFileName);
end;

end.
