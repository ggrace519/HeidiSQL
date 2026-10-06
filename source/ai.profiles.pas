unit ai.profiles;

// AI provider profiles: which server, model and key source to use. Stored in their own JSON file
// (ai-providers.json in the settings folder) and referenced from sessions by a stable id, so
// renaming a profile does not break sessions. API keys are never stored here, only where to find
// them. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TAiProviderFormat = (pfOpenAI);
  TAiKeySource = (ksNone, ksEnvironment, ksKeychain);

  TAiProfile = record
    Id: String;             // GUID, stable across renames
    Name: String;
    Format: TAiProviderFormat;
    BaseUrl: String;        // e.g. "http://localhost:11434/v1"
    Model: String;
    KeySource: TAiKeySource;
    KeyName: String;        // Environment variable or keychain entry name
    Temperature: Double;    // < 0: server default
    MaxContextChars: Integer;
    IoTimeoutSec: Integer;  // Read timeout; local models can be silent for minutes on long prompts
  end;

  TAiProfileProblem = (ppNoName, ppBadUrl, ppNoModel, ppNoKeyName, ppContextSize, ppTimeout);
  TAiProfileProblems = set of TAiProfileProblem;

  TAiProfilesLoadResult = (plrOk, plrMissing, plrUnreadable, plrCorrupt, plrNewerVersion);

  TAiProfileMatch = (
    pmExact,    // The requested profile
    pmDefault,  // No profile requested: the default profile
    pmMissing,  // The requested profile no longer exists. Profile is the default, but the UI must
                // ask before using it, as it may send data to a different provider.
    pmNone      // No profiles at all
  );

  TAiProfileList = class
  private
    FItems: array of TAiProfile;
    FDefaultId: String;
    function GetCount: Integer;
    function GetItem(Index: Integer): TAiProfile;
  public
    function LoadFromJson(const Json: String): TAiProfilesLoadResult;
    function ToJson: String;
    function LoadFromFile(const Filename: String): TAiProfilesLoadResult;
    // Writes and flushes a temporary file first, then replaces the target, so a crash cannot
    // leave a half-written file. Raises EInOutError / EFCreateError on failure.
    procedure SaveToFile(const Filename: String);
    function IndexOfId(const Id: String): Integer;
    // Profile for a session's stored id, see TAiProfileMatch. Does not validate the profile.
    function Resolve(const Id: String; out Profile: TAiProfile): TAiProfileMatch;
    function Add(const Profile: TAiProfile): Integer;
    procedure Update(const Profile: TAiProfile);
    procedure Delete(const Id: String);
    procedure Clear;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TAiProfile read GetItem; default;
    property DefaultId: String read FDefaultId write FDefaultId;
  end;

const
  AIPROFILESFILE = 'ai-providers.json';
  AIPROFILESVERSION = 1;
  DEFAULTLOCALBASEURL = 'http://localhost:11434/v1';

// New profile with a fresh id and sensible defaults
function NewAiProfile(const Name: String): TAiProfile;
function ValidateAiProfile(const Profile: TAiProfile): TAiProfileProblems;

implementation

uses
  {$IFDEF UNIX} Unix, {$ENDIF}
  Classes, fpjson, jsonparser;

const
  FORMATNAMES: array[TAiProviderFormat] of String = ('openai');
  KEYSOURCENAMES: array[TAiKeySource] of String = ('none', 'env', 'keychain');

function NewGuidString: String;
var
  Guid: TGUID;
begin
  CreateGUID(Guid);
  Result := GUIDToString(Guid);
end;

function NewAiProfile(const Name: String): TAiProfile;
begin
  Result := Default(TAiProfile);
  Result.Id := NewGuidString;
  Result.Name := Name;
  Result.Format := pfOpenAI;
  Result.BaseUrl := DEFAULTLOCALBASEURL;
  Result.KeySource := ksNone;
  Result.Temperature := 0.2;
  Result.MaxContextChars := 8000;
  Result.IoTimeoutSec := 300;
end;

function ValidateAiProfile(const Profile: TAiProfile): TAiProfileProblems;
var
  Url: String;
begin
  Result := [];
  if Profile.Name.Trim = '' then
    Include(Result, ppNoName);
  Url := LowerCase(Profile.BaseUrl.Trim);
  if not ((Url.StartsWith('http://') or Url.StartsWith('https://')) and (Length(Url) > 8)) then
    Include(Result, ppBadUrl);
  if Profile.Model.Trim = '' then
    Include(Result, ppNoModel);
  if (Profile.KeySource <> ksNone) and (Profile.KeyName.Trim = '') then
    Include(Result, ppNoKeyName);
  if (Profile.MaxContextChars < 1000) or (Profile.MaxContextChars > 1000000) then
    Include(Result, ppContextSize);
  if (Profile.IoTimeoutSec < 5) or (Profile.IoTimeoutSec > 3600) then
    Include(Result, ppTimeout);
end;

function FormatFromName(const Name: String): TAiProviderFormat;
var
  f: TAiProviderFormat;
begin
  for f:=Low(f) to High(f) do begin
    if SameText(FORMATNAMES[f], Name) then
      Exit(f);
  end;
  Result := pfOpenAI;
end;

function KeySourceFromName(const Name: String): TAiKeySource;
var
  k: TAiKeySource;
begin
  for k:=Low(k) to High(k) do begin
    if SameText(KEYSOURCENAMES[k], Name) then
      Exit(k);
  end;
  Result := ksNone;
end;

{ TAiProfileList }

function TAiProfileList.GetCount: Integer;
begin
  Result := Length(FItems);
end;

function TAiProfileList.GetItem(Index: Integer): TAiProfile;
begin
  Result := FItems[Index];
end;

procedure TAiProfileList.Clear;
begin
  FItems := nil;
  FDefaultId := '';
end;

function TAiProfileList.IndexOfId(const Id: String): Integer;
var
  i: Integer;
begin
  for i:=0 to High(FItems) do begin
    if SameText(FItems[i].Id, Id) then
      Exit(i);
  end;
  Result := -1;
end;

function TAiProfileList.Resolve(const Id: String; out Profile: TAiProfile): TAiProfileMatch;
var
  i: Integer;
begin
  Profile := Default(TAiProfile);
  if Length(FItems) = 0 then
    Exit(pmNone);
  i := IndexOfId(Id);
  if i >= 0 then begin
    Profile := FItems[i];
    Exit(pmExact);
  end;
  i := IndexOfId(FDefaultId);
  if i < 0 then
    i := 0;
  Profile := FItems[i];
  if Id.Trim = '' then
    Result := pmDefault
  else
    Result := pmMissing;
end;

function TAiProfileList.Add(const Profile: TAiProfile): Integer;
begin
  SetLength(FItems, Length(FItems) + 1);
  Result := High(FItems);
  FItems[Result] := Profile;
  if FDefaultId = '' then
    FDefaultId := Profile.Id;
end;

procedure TAiProfileList.Update(const Profile: TAiProfile);
var
  i: Integer;
begin
  i := IndexOfId(Profile.Id);
  if i < 0 then
    Add(Profile)
  else
    FItems[i] := Profile;
end;

procedure TAiProfileList.Delete(const Id: String);
var
  i, j: Integer;
begin
  i := IndexOfId(Id);
  if i < 0 then
    Exit;
  for j:=i to High(FItems)-1 do
    FItems[j] := FItems[j+1];
  SetLength(FItems, Length(FItems) - 1);
  if SameText(FDefaultId, Id) then begin
    if Length(FItems) > 0 then
      FDefaultId := FItems[0].Id
    else
      FDefaultId := '';
  end;
end;

function TAiProfileList.ToJson: String;
var
  Root, Obj: TJSONObject;
  List: TJSONArray;
  P: TAiProfile;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('version', AIPROFILESVERSION);
    Root.Add('defaultId', FDefaultId);
    List := TJSONArray.Create;
    for P in FItems do begin
      Obj := TJSONObject.Create;
      Obj.Add('id', P.Id);
      Obj.Add('name', P.Name);
      Obj.Add('format', FORMATNAMES[P.Format]);
      Obj.Add('baseUrl', P.BaseUrl);
      Obj.Add('model', P.Model);
      Obj.Add('keySource', KEYSOURCENAMES[P.KeySource]);
      Obj.Add('keyName', P.KeyName);
      Obj.Add('temperature', P.Temperature);
      Obj.Add('maxContextChars', P.MaxContextChars);
      Obj.Add('ioTimeoutSec', P.IoTimeoutSec);
      List.Add(Obj);
    end;
    Root.Add('profiles', List);
    Result := Root.FormatJSON;
  finally
    Root.Free;
  end;
end;

function TAiProfileList.LoadFromJson(const Json: String): TAiProfilesLoadResult;
var
  Parsed: TJSONData;
  Root, Obj: TJSONObject;
  List: TJSONArray;
  P, Defaults: TAiProfile;
  i: Integer;
begin
  Clear;
  try
    // A byte order mark from a hand edit is not part of the JSON
    if Json.StartsWith(#$EF#$BB#$BF) then
      Parsed := GetJSON(Copy(Json, 4, MaxInt))
    else
      Parsed := GetJSON(Json);
  except
    Exit(plrCorrupt);
  end;
  try
    if not (Parsed is TJSONObject) then
      Exit(plrCorrupt);
    Root := TJSONObject(Parsed);
    if Root.Get('version', 0) > AIPROFILESVERSION then
      Exit(plrNewerVersion);
    List := Root.Find('profiles', jtArray) as TJSONArray;
    if List = nil then
      Exit(plrCorrupt);
    Defaults := NewAiProfile('');
    for i:=0 to List.Count-1 do begin
      if not (List[i] is TJSONObject) then
        Continue;
      Obj := TJSONObject(List[i]);
      P := Default(TAiProfile);
      P.Id := Obj.Get('id', '');
      if (P.Id = '') or (IndexOfId(P.Id) >= 0) then
        P.Id := NewGuidString;
      P.Name := Obj.Get('name', '');
      P.Format := FormatFromName(Obj.Get('format', ''));
      P.BaseUrl := Obj.Get('baseUrl', '');
      P.Model := Obj.Get('model', '');
      P.KeySource := KeySourceFromName(Obj.Get('keySource', ''));
      P.KeyName := Obj.Get('keyName', '');
      // Numbers may come as integer or float in hand-edited files
      if Obj.Find('temperature') is TJSONNumber then
        P.Temperature := Obj.Find('temperature').AsFloat
      else
        P.Temperature := Defaults.Temperature;
      P.MaxContextChars := Obj.Get('maxContextChars', Defaults.MaxContextChars);
      P.IoTimeoutSec := Obj.Get('ioTimeoutSec', Defaults.IoTimeoutSec);
      // Out-of-range numbers from a hand edit fall back to defaults
      if ppContextSize in ValidateAiProfile(P) then
        P.MaxContextChars := Defaults.MaxContextChars;
      if ppTimeout in ValidateAiProfile(P) then
        P.IoTimeoutSec := Defaults.IoTimeoutSec;
      Add(P);
    end;
    FDefaultId := Root.Get('defaultId', '');
    if (IndexOfId(FDefaultId) < 0) and (Length(FItems) > 0) then
      FDefaultId := FItems[0].Id;
    Result := plrOk;
  finally
    Parsed.Free;
  end;
end;

function ReadFileText(const Filename: String): String;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(Filename, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

function TAiProfileList.LoadFromFile(const Filename: String): TAiProfilesLoadResult;
var
  Json: String;
begin
  Clear;
  if not FileExists(Filename) then
    Exit(plrMissing);
  try
    Json := ReadFileText(Filename);
  except
    on E: EStreamError do
      Exit(plrUnreadable);
  end;
  Result := LoadFromJson(Json);
end;

procedure TAiProfileList.SaveToFile(const Filename: String);
var
  TempName, Json: String;
  Stream: TFileStream;
begin
  Json := ToJson;
  // Unique per process, so two running instances do not write the same temporary file
  TempName := Filename + '.' + IntToStr(GetProcessID) + '.tmp';
  try
    Stream := TFileStream.Create(TempName, fmCreate);
    try
      if Length(Json) > 0 then
        Stream.WriteBuffer(Json[1], Length(Json));
      {$IFDEF UNIX}
      FpFsync(Stream.Handle);
      {$ENDIF}
    finally
      Stream.Free;
    end;
    {$IFDEF WINDOWS}
    // RenameFile does not replace an existing file on Windows
    if FileExists(Filename) and not DeleteFile(Filename) then
      raise EInOutError.CreateFmt('Cannot replace %s', [Filename]);
    {$ENDIF}
    // On Unix, rename replaces the target atomically
    if not RenameFile(TempName, Filename) then
      raise EInOutError.CreateFmt('Cannot rename %s to %s', [TempName, Filename]);
  except
    DeleteFile(TempName);
    raise;
  end;
end;

end.
