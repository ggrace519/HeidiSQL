unit ai.profilechoice;

// The provider choices of a session: "default provider", each profile, and, when the session
// refers to a profile that was deleted, an explicit "removed provider" entry. That entry keeps the
// stored id until the user picks something else, so a session never switches providers silently,
// while "default" always means default. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.profiles;

type
  TAiProfileChoice = record
    Caption: String;
    ProfileId: String; // Empty for the default provider
  end;
  TAiProfileChoices = array of TAiProfileChoice;

// Choices for a session that stores StoredId; Selected receives the index to show.
// DefaultCaption and RemovedCaption may contain %s for the default profile's name.
function BuildProfileChoices(Profiles: TAiProfileList; const StoredId, DefaultCaption,
  NoDefaultCaption, RemovedCaption: String; out Selected: Integer): TAiProfileChoices;

implementation

procedure Add(var Choices: TAiProfileChoices; const Caption, ProfileId: String);
begin
  SetLength(Choices, Length(Choices) + 1);
  Choices[High(Choices)].Caption := Caption;
  Choices[High(Choices)].ProfileId := ProfileId;
end;

function BuildProfileChoices(Profiles: TAiProfileList; const StoredId, DefaultCaption,
  NoDefaultCaption, RemovedCaption: String; out Selected: Integer): TAiProfileChoices;
var
  DefaultProfile: TAiProfile;
  i: Integer;
begin
  Result := nil;
  if Profiles.Resolve('', DefaultProfile) = pmNone then
    Add(Result, NoDefaultCaption, '')
  else
    Add(Result, Format(DefaultCaption, [DefaultProfile.Name]), '');
  for i:=0 to Profiles.Count-1 do
    Add(Result, Profiles[i].Name, Profiles[i].Id);
  Selected := 0;
  if StoredId = '' then
    Exit;
  i := Profiles.IndexOfId(StoredId);
  if i >= 0 then
    Selected := i + 1
  else begin
    Add(Result, RemovedCaption, StoredId);
    Selected := High(Result);
  end;
end;

end.
