unit forkupdate;

// Finds the newest AI Edition release in a GitHub "list releases" API response, and compares
// version numbers. No LCL dependencies, so it can be unit tested.

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpjson, jsonparser;

type
  TForkRelease = record
    Found: Boolean;
    Tag: String;          // e.g. "ai-v0.2.0"
    Version: String;      // Tag without prefix, e.g. "0.2.0"
    Name: String;
    Url: String;          // Release page, html_url
    PublishedAt: String;  // ISO 8601, as delivered by GitHub
    Notes: String;        // Release body, Markdown
  end;

// Returns the highest-versioned published release whose tag starts with TagPrefix.
// Drafts, prereleases and tags with a non-numeric version (e.g. "ai-v1.0.0-rc1") are skipped.
// Raises EJSONParserException / EJSON on invalid JSON.
function FindLatestForkRelease(const ReleasesJson, TagPrefix: String): TForkRelease;
// Compares dotted numeric versions like "0.10.1" and "0.9". Missing parts count as 0,
// non-numeric parts as 0. Result <0, 0 or >0, like CompareStr.
function CompareVersions(const A, B: String): Integer;
function IsNewerVersion(const Candidate, Current: String): Boolean;
// True for dotted numeric versions like "0.2" or "1.10.3"
function IsPlainVersion(const Version: String): Boolean;

implementation

function VersionPart(const Parts: TStringArray; Index: Integer): Int64;
begin
  if Index < Length(Parts) then
    Result := StrToInt64Def(Trim(Parts[Index]), 0)
  else
    Result := 0;
end;

function CompareVersions(const A, B: String): Integer;
var
  PartsA, PartsB: TStringArray;
  i, Count: Integer;
  NumA, NumB: Int64;
begin
  Result := 0;
  PartsA := A.Split(['.']);
  PartsB := B.Split(['.']);
  Count := Length(PartsA);
  if Length(PartsB) > Count then
    Count := Length(PartsB);
  for i:=0 to Count-1 do begin
    NumA := VersionPart(PartsA, i);
    NumB := VersionPart(PartsB, i);
    if NumA < NumB then
      Exit(-1)
    else if NumA > NumB then
      Exit(1);
  end;
end;

function IsNewerVersion(const Candidate, Current: String): Boolean;
begin
  Result := CompareVersions(Candidate, Current) > 0;
end;

function IsPlainVersion(const Version: String): Boolean;
var
  Part: String;
begin
  Result := Version <> '';
  for Part in Version.Split(['.']) do begin
    if (Part = '') or (StrToInt64Def(Part, -1) < 0) then
      Exit(False);
  end;
end;

function FindLatestForkRelease(const ReleasesJson, TagPrefix: String): TForkRelease;
var
  Data: TJSONData;
  Releases: TJSONArray;
  Item: TJSONObject;
  i: Integer;
  Tag, Version: String;
begin
  Result := Default(TForkRelease);
  Data := GetJSON(ReleasesJson);
  try
    if not (Data is TJSONArray) then
      Exit;
    Releases := TJSONArray(Data);
    for i:=0 to Releases.Count-1 do begin
      if not (Releases[i] is TJSONObject) then
        Continue;
      Item := TJSONObject(Releases[i]);
      if Item.Get('draft', False) or Item.Get('prerelease', False) then
        Continue;
      Tag := Item.Get('tag_name', '');
      if (TagPrefix = '') or (not Tag.StartsWith(TagPrefix)) then
        Continue;
      Version := Copy(Tag, Length(TagPrefix)+1, MaxInt);
      if not IsPlainVersion(Version) then
        Continue;
      if Result.Found and (not IsNewerVersion(Version, Result.Version)) then
        Continue;
      Result.Found := True;
      Result.Tag := Tag;
      Result.Version := Version;
      Result.Name := Item.Get('name', '');
      Result.Url := Item.Get('html_url', '');
      Result.PublishedAt := Item.Get('published_at', '');
      Result.Notes := Item.Get('body', '');
    end;
  finally
    Data.Free;
  end;
end;

end.
