unit ai.session;

// AI settings of one session (connection): whether the assistant is enabled, which provider
// profile it uses and the user's notes about the database. Stored with the session's other
// settings, so renaming, cloning and deleting a session carry them along.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TAiSessionSettings = record
    Enabled: Boolean;
    ProfileId: String;     // Empty: the default provider profile
    ContextNotes: String;
  end;

// Settings of the session at SessionPath; defaults (disabled) when nothing is stored yet
function LoadAiSessionSettings(const SessionPath: String): TAiSessionSettings;
procedure SaveAiSessionSettings(const SessionPath: String; const Settings: TAiSessionSettings);
function SameAiSessionSettings(const A, B: TAiSessionSettings): Boolean;

implementation

uses
  apphelpers;

function LoadAiSessionSettings(const SessionPath: String): TAiSessionSettings;
begin
  Result := Default(TAiSessionSettings);
  if SessionPath = '' then
    Exit;
  // SessionPath of AppSettings is shared state: restore whatever another caller had set
  AppSettings.StorePath;
  try
    AppSettings.SessionPath := SessionPath;
    Result.Enabled := AppSettings.ReadBool(asAiEnabled);
    Result.ProfileId := AppSettings.ReadString(asAiProfileId);
    Result.ContextNotes := AppSettings.ReadString(asAiContextNotes);
  finally
    AppSettings.RestorePath;
  end;
end;

procedure SaveAiSessionSettings(const SessionPath: String; const Settings: TAiSessionSettings);
begin
  if SessionPath = '' then
    Exit;
  AppSettings.StorePath;
  try
    AppSettings.SessionPath := SessionPath;
    AppSettings.WriteBool(asAiEnabled, Settings.Enabled);
    AppSettings.WriteString(asAiProfileId, Settings.ProfileId);
    AppSettings.WriteString(asAiContextNotes, Settings.ContextNotes);
  finally
    AppSettings.RestorePath;
  end;
end;

function SameAiSessionSettings(const A, B: TAiSessionSettings): Boolean;
begin
  Result := (A.Enabled = B.Enabled) and (A.ProfileId = B.ProfileId)
    and (A.ContextNotes = B.ContextNotes);
end;

end.
