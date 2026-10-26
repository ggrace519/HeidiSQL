unit ai.requestprep;

// Turns the main window's state and the user's question into a ready-to-send chat request:
// checks that AI is enabled for the session, resolves the provider profile and its API key, reads
// the schema and builds the messages. Main thread only (keychain and database access).

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.types, ai.profiles, ai.http, ai.hostcontext;

type
  TAiTaskRequest = record
    Task: TAiTask;
    UserText: String;      // The question (Generate) or an optional remark (other tasks)
    Sql: String;           // SQL for Explain/Optimize/Fix error; empty: the editor's SQL
    ErrorMessage: String;  // Server error, for Fix error
  end;

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
function PrepareAiRequest(const Host: TAiHostState; const Request: TAiTaskRequest;
  const History: TAiChatMessages; out Prepared: TAiPrepared): String;

implementation

uses
  apphelpers, ai.session, ai.appprofiles, ai.keystore, ai.prompts, ai.requestbuild, ai.context,
  ai.schemasource, ai.uitext, ai.text;

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

function TaskTitle(const Request: TAiTaskRequest; const Sql: String): String;
var
  FirstLine, ErrorLine: String;
begin
  FirstLine := Trim(Sql);
  if Pos(#10, FirstLine) > 0 then
    FirstLine := Trim(Copy(FirstLine, 1, Pos(#10, FirstLine)-1)) + ' ...';
  FirstLine := Utf8Truncate(FirstLine, 80);
  ErrorLine := Trim(Request.ErrorMessage);
  if Pos(#10, ErrorLine) > 0 then
    ErrorLine := Trim(Copy(ErrorLine, 1, Pos(#10, ErrorLine)-1)) + ' ...';
  case Request.Task of
    atExplain: Result := f_('Explain: %s', [FirstLine]);
    atOptimize: Result := f_('Optimize: %s', [FirstLine]);
    atFixError: Result := f_('Fix error: %s', [Utf8Truncate(ErrorLine, 80)]);
    else Result := Trim(Request.UserText);
  end;
  if (Request.Task <> atGenerate) and (Trim(Request.UserText) <> '') then
    Result := Result + sLineBreak + '  ' + Trim(Request.UserText);
end;

function PrepareAiRequest(const Host: TAiHostState; const Request: TAiTaskRequest;
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
  // Like creating a table, generating SQL needs a database: its schema is what the model works with
  if Host.Database = '' then
    Exit(_('Select a database in the tree first. Its tables and columns are sent with the question.'));
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
  Input.Task := Request.Task;
  Input.Dialect := Host.Dialect;
  Input.DatabaseName := Host.Database;
  Input.ContextNotes := Settings.ContextNotes;
  Input.UserText := Request.UserText;
  if Request.Task <> atGenerate then begin
    Input.Sql := Request.Sql;
    if Trim(Input.Sql) = '' then begin
      // Sending a cut-off query would make the model explain or rewrite something else
      if Host.SqlTruncated then
        Exit(_('The SQL is too long to send. Select the statement to work on first.'));
      Input.Sql := Host.Sql;
    end;
  end;
  Input.ErrorMessage := Request.ErrorMessage;
  if not IsTaskInputComplete(Input) then begin
    case Request.Task of
      atGenerate: Exit(_('Type a question first.'));
      atFixError: Exit(_('No failed query to fix in this query tab.'));
      else Exit(_('The query editor is empty. Write or select the SQL first.'));
    end;
  end;

  SchemaInput := Default(TAiSchemaInput);
  SchemaInput.Database := Host.Database;
  SchemaInput.Prompt := Request.UserText;
  // Tables of the SQL being worked on; for Generate, those of the editor text
  if Request.Task = atGenerate then
    SchemaInput.Sql := Host.Sql
  else
    SchemaInput.Sql := Input.Sql;
  SchemaInput.ConnectionBusy := Host.ConnectionBusy;
  SchemaInput.ActiveObject := Host.ActiveObject;
  SchemaInput.Budget := DefaultContextBudget;
  SchemaInput.Budget.MaxChars := Prepared.Profile.MaxContextChars;
  Schema := GatherSchemaContext(Host.Connection, SchemaInput);
  Input.SchemaContext := Schema.Context;
  Prepared.CacheOnly := Schema.CacheOnly;

  Prepared.Title := TaskTitle(Request, Input.Sql);
  Prepared.ContextSent := SystemPrompt(Input);
  Prepared.UserMessage := TaskPrompt(Input);
  Prepared.Spec := ChatRequestSpec(Prepared.Profile, Prepared.Key, BuildMessages(Input, History));
  Result := '';
end;

end.
