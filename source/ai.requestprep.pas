unit ai.requestprep;

// Turns the main window's state and the user's question into a ready-to-send chat request:
// checks that AI is enabled for the session, resolves the provider profile and its API key, reads
// the schema and builds the messages. Main thread only (keychain and database access).

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.types, ai.profiles, ai.http, ai.hostcontext;

type
  TAiPrepared = record
    Spec: TAiRequestSpec;
    Profile: TAiProfile;
    Key: String;           // Only kept to remove it from server error texts
    Title: String;         // Shown above the answer
    UserMessage: String;   // Task message as sent
    ContextSent: String;   // System message as sent
    CacheOnly: Boolean;    // Schema was read from the cache, the connection was busy
  end;

// Returns '' and fills Prepared, or returns a message for the user explaining what is missing.
function PrepareAiRequest(const Host: TAiHostState; Task: TAiTask; const UserText: String;
  const History: TAiChatMessages; out Prepared: TAiPrepared): String;

implementation

uses
  apphelpers, ai.session, ai.appprofiles, ai.keystore, ai.prompts, ai.requestbuild, ai.context,
  ai.schemasource, ai.uitext;

function ResolveProfile(const ProfileId: String; out Profile: TAiProfile): String;
var
  Profiles: TAiProfileList;
  Problems: TAiProfileProblems;
begin
  Result := '';
  Profiles := TAiProfileList.Create;
  try
    LoadAppProfiles(Profiles);
    case Profiles.Resolve(ProfileId, Profile) of
      pmNone:
        Exit(_('No AI provider is set up yet. Add one in Preferences, tab "AI providers".'));
      pmMissing:
        Exit(_('The AI provider of this session was removed. Choose another one in the session manager, tab "LLM Settings".'));
    end;
  finally
    Profiles.Free;
  end;
  Problems := ValidateAiProfile(Profile);
  if Problems <> [] then
    Result := f_('The AI provider "%s" is not complete. Fix it in Preferences, tab "AI providers":', [Profile.Name])
      + sLineBreak + ProfileProblemsText(Problems);
end;

function PrepareAiRequest(const Host: TAiHostState; Task: TAiTask; const UserText: String;
  const History: TAiChatMessages; out Prepared: TAiPrepared): String;
var
  Settings: TAiSessionSettings;
  KeyProblem: String;
  KeyResult: TAiKeyResult;
  SchemaInput: TAiSchemaInput;
  Schema: TAiSchemaResult;
  Input: TAiPromptInput;
begin
  Prepared := Default(TAiPrepared);
  if not Host.HasQueryTab then
    Exit(_('Open a query tab first.'));
  if Host.Connection = nil then
    Exit(_('Connect to a database first.'));
  if Host.SessionPath = '' then
    Exit(_('Save the session to use the AI assistant with it.'));
  Settings := LoadAiSessionSettings(Host.SessionPath);
  if not Settings.Enabled then
    Exit(f_('The AI assistant is off for session "%s". Turn it on in the session manager, tab "LLM Settings".',
      [Host.SessionName]));

  Result := ResolveProfile(Settings.ProfileId, Prepared.Profile);
  if Result <> '' then
    Exit;
  KeyResult := ResolveApiKey(Prepared.Profile, Prepared.Key, KeyProblem);
  if not (KeyResult in [krNotNeeded, krFound]) then
    Exit(f_('API key for "%s":', [Prepared.Profile.Name]) + ' '
      + KeyResultText(KeyResult, Prepared.Profile, KeyProblem));

  Input := Default(TAiPromptInput);
  Input.Task := Task;
  Input.Dialect := Host.Dialect;
  Input.DatabaseName := Host.Database;
  Input.ContextNotes := Settings.ContextNotes;
  Input.UserText := UserText;
  if Task <> atGenerate then
    Input.Sql := Host.Sql;
  if not IsTaskInputComplete(Input) then
    Exit(_('Type a question first.'));

  SchemaInput := Default(TAiSchemaInput);
  SchemaInput.Database := Host.Database;
  SchemaInput.Prompt := UserText;
  SchemaInput.Sql := Host.Sql;
  SchemaInput.ActiveObject := Host.ActiveObject;
  SchemaInput.Budget := DefaultContextBudget;
  SchemaInput.Budget.MaxChars := Prepared.Profile.MaxContextChars;
  Schema := GatherSchemaContext(Host.Connection, SchemaInput);
  Input.SchemaContext := Schema.Context;
  Prepared.CacheOnly := Schema.CacheOnly;

  Prepared.Title := UserText.Trim;
  Prepared.ContextSent := SystemPrompt(Input);
  Prepared.UserMessage := TaskPrompt(Input);
  Prepared.Spec := ChatRequestSpec(Prepared.Profile, Prepared.Key, BuildMessages(Input, History));
  Result := '';
end;

end.
