unit ai.controller;

// Runs the AI assistant's requests: one request in flight at a time, streamed into the
// conversation of the query tab it was started from. A 50 ms timer moves text from the worker's
// mailbox to the conversation; data of a cancelled or replaced request is dropped. Owns the
// panel and the per-tab conversations. Main thread only.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, Forms, ai.types, ai.http, ai.profiles, ai.conversations,
  ai.requestprep, ai.panel;

type
  TAiController = class(TComponent)
  private
    FForm: TCustomForm;
    FPanel: TAiPanel;
    FSplitter: TSplitter;
    FTimer: TTimer;
    FConversations: TAiConversations;
    FTracker: TAiRequestTracker;
    FMailbox: IAiMailbox;
    FLastMailbox: IAiMailbox; // Also kept after a cancel, so Shutdown can wait for its worker
    FProfile: TAiProfile;
    FKey: String;
    FShownKey: String;
    FShutDown: Boolean;
    procedure TimerTick(Sender: TObject);
    procedure RunTask(const Request: TAiTaskRequest);
    procedure RunEditorTask(Task: TAiTask);
    procedure PanelSend(const Text: String);
    procedure PanelFixError(Sender: TObject);
    procedure PanelCancel(Sender: TObject);
    procedure PanelClear(Sender: TObject);
    procedure PanelPutSql(const Sql: String; ReplaceAll: Boolean);
    procedure PanelEnter(Sender: TObject);
    procedure EndRequest;
    function Redact(const Text: String): String;
    function GetPanelVisible: Boolean;
    procedure SetPanelVisible(Value: Boolean);
  public
    // Creates the panel on the right side of Host
    constructor Create(AOwner: TComponent; Host: TWinControl); reintroduce;
    destructor Destroy; override;
    // Shows the conversation and status of the active query tab
    procedure Refresh;
    procedure Generate;
    // Explain or optimize the selected SQL, or the whole editor text
    procedure Explain;
    procedure Optimize;
    // Fix the last failed query of the active tab
    procedure FixError;
    function Busy: Boolean;
    function ActiveTabHasQueryError: Boolean;
    // Called after every query run: remembers the failed statement and error, or forgets them
    // after a success. Runs the user cancelled, and errors without a failed statement (e.g. from
    // showing the result), leave the record as it is.
    procedure QueryFinished(TabNumber: Integer; const SessionPath, Database, Sql,
      ErrorMessage: String; Aborted: Boolean);
    procedure Cancel;
    procedure QueryTabClosed(TabNumber: Integer);
    // Cancels a running request and waits briefly for its worker thread
    procedure Shutdown;
    property PanelVisible: Boolean read GetPanelVisible write SetPanelVisible;
  end;

var
  AiController: TAiController;

implementation

uses
  Math, apphelpers, ai.conversation, ai.hostcontext, ai.uitext, ai.text;

const
  DRAININTERVALMS = 50;
  SHUTDOWNWAITMS = 2000;
  MINPANELWIDTH = 200;

constructor TAiController.Create(AOwner: TComponent; Host: TWinControl);
begin
  inherited Create(AOwner);
  FConversations := TAiConversations.Create;
  FTracker := TAiRequestTracker.Create;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := DRAININTERVALMS;
  FTimer.OnTimer := TimerTick;

  FPanel := TAiPanel.Create(AOwner);
  FPanel.Parent := Host;
  FPanel.Align := alRight;
  // Stored unscaled like the other panel sizes, and kept within a usable range
  FForm := AOwner as TCustomForm;
  FPanel.Width := EnsureRange(FForm.ScaleDesignToForm(AppSettings.ReadInt(asAiPanelWidth)),
    FForm.ScaleDesignToForm(MINPANELWIDTH),
    Max(FForm.ScaleDesignToForm(MINPANELWIDTH), Host.ClientWidth div 2));
  FPanel.OnSend := PanelSend;
  FPanel.OnCancel := PanelCancel;
  FPanel.OnClear := PanelClear;
  FPanel.OnPutSql := PanelPutSql;
  FPanel.OnFixError := PanelFixError;
  // The database may have changed since the last tab change
  FPanel.OnEnter := PanelEnter;
  FSplitter := TSplitter.Create(AOwner);
  FSplitter.Parent := Host;
  FSplitter.Align := alRight;
  FSplitter.Left := FPanel.Left - 1;
  FSplitter.ResizeStyle := rsPattern;
  FSplitter.MinSize := FForm.ScaleDesignToForm(MINPANELWIDTH);
  SetPanelVisible(AppSettings.ReadBool(asAiPanelVisible));
end;

destructor TAiController.Destroy;
begin
  if AiController = Self then
    AiController := nil;
  // Shutdown normally ran already, while AppSettings still existed
  if Assigned(FMailbox) then
    FMailbox.Cancel;
  FMailbox := nil;
  FLastMailbox := nil;
  FTracker.Free;
  FConversations.Free;
  inherited;
end;

function TAiController.GetPanelVisible: Boolean;
begin
  Result := FPanel.Visible;
end;

procedure TAiController.SetPanelVisible(Value: Boolean);
begin
  FPanel.Visible := Value;
  FSplitter.Visible := Value;
  if Value then
    FSplitter.Left := FPanel.Left - 1;
  AppSettings.WriteBool(asAiPanelVisible, Value);
  if Value then
    Refresh;
end;

procedure TAiController.Refresh;
var
  Host: TAiHostState;
  Conversation: TAiConversation;
begin
  if not FPanel.Visible then
    Exit;
  Host := CaptureHostState(False);
  FShownKey := Host.ConversationKey;
  FPanel.CanSend := Host.HasQueryTab and Assigned(Host.Connection) and (Host.Database <> '');
  if not Host.HasQueryTab then
    FPanel.SetStatus(_('Open a query tab to use the AI assistant.'), False)
  else if Host.Connection = nil then
    FPanel.SetStatus(_('Connect to a database to use the AI assistant.'), False)
  else if FTracker.Busy and (not FTracker.BusyForTab(Host.ConversationKey)) then
    FPanel.SetStatus(_('Another query tab is waiting for an answer.'), False)
  else if Host.Database = '' then
    FPanel.SetStatus(_('Select a database in the tree first. Its tables and columns are sent with the question.'), True)
  else
    FPanel.SetStatus(f_('Session "%s", database "%s"', [Host.SessionName, Host.Database]), False);
  Conversation := FConversations.Find(Host.ConversationKey);
  FPanel.ShowConversation(Conversation, FTracker.Busy);
  if Assigned(Conversation) then
    FPanel.ShowQueryError(Conversation.LastErrorMessage)
  else
    FPanel.ShowQueryError('');
end;

procedure TAiController.Generate;
begin
  PanelVisible := True;
  FPanel.FocusPrompt;
end;

procedure TAiController.PanelSend(const Text: String);
var
  Request: TAiTaskRequest;
begin
  Request := Default(TAiTaskRequest);
  Request.Task := atGenerate;
  Request.UserText := Text;
  RunTask(Request);
end;

procedure TAiController.RunEditorTask(Task: TAiTask);
var
  Request: TAiTaskRequest;
begin
  PanelVisible := True;
  Request := Default(TAiTaskRequest);
  Request.Task := Task;
  // Text in the prompt box is sent as a remark, e.g. "focus on the joins"
  Request.UserText := FPanel.PromptText;
  RunTask(Request);
end;

procedure TAiController.Explain;
begin
  RunEditorTask(atExplain);
end;

procedure TAiController.Optimize;
begin
  RunEditorTask(atOptimize);
end;

procedure TAiController.FixError;
var
  Host: TAiHostState;
  Conversation: TAiConversation;
  Request: TAiTaskRequest;
begin
  PanelVisible := True;
  if FTracker.Busy then
    Exit;
  Host := CaptureHostState(False);
  Conversation := FConversations.Find(Host.ConversationKey);
  Request := Default(TAiTaskRequest);
  Request.Task := atFixError;
  Request.UserText := FPanel.PromptText;
  if Assigned(Conversation) then begin
    Request.Sql := Conversation.LastErrorSql;
    Request.ErrorMessage := Conversation.LastErrorMessage;
  end;
  // Without a recorded error there is nothing to fix; empty SQL would fall back to the editor
  if (Request.ErrorMessage = '') or (Trim(Request.Sql) = '') then begin
    FPanel.SetStatus(_('No failed query to fix in this query tab.'), True);
    Exit;
  end;
  // The schema sent with the fix must be the one the query ran against
  if (Conversation.LastErrorDatabase <> '') and (Conversation.LastErrorDatabase <> Host.Database) then begin
    FPanel.SetStatus(f_('The query failed in database "%s". Select that database to fix it.',
      [Conversation.LastErrorDatabase]), True);
    Exit;
  end;
  RunTask(Request);
end;

procedure TAiController.PanelFixError(Sender: TObject);
begin
  FixError;
end;

function TAiController.Busy: Boolean;
begin
  Result := FTracker.Busy;
end;

function TAiController.ActiveTabHasQueryError: Boolean;
var
  Conversation: TAiConversation;
begin
  // Runs on every action update, so only the cheap key lookup
  Conversation := FConversations.Find(ActiveConversationKey);
  Result := Assigned(Conversation) and (Conversation.LastErrorMessage <> '');
end;

procedure TAiController.QueryFinished(TabNumber: Integer; const SessionPath, Database, Sql,
  ErrorMessage: String; Aborted: Boolean);
var
  Key: String;
  Conversation: TAiConversation;
begin
  // A cancelled run is no error to fix; a closed tab needs no record
  if Aborted or (not QueryTabExists(TabNumber)) then
    Exit;
  Key := ConversationKey(TabNumber, SessionPath);
  if (ErrorMessage <> '') and (Sql <> '') then
    FConversations.Get(Key).SetQueryError(Sql, ErrorMessage, Database)
  else if ErrorMessage = '' then begin
    // A later successful run makes the old error irrelevant
    Conversation := FConversations.Find(Key);
    if Assigned(Conversation) then
      Conversation.SetQueryError('', '', '');
  end;
  Refresh;
end;

procedure TAiController.RunTask(const Request: TAiTaskRequest);
var
  Host: TAiHostState;
  Conversation: TAiConversation;
  Prepared: TAiPrepared;
  Problem: String;
  TurnId: Integer;
begin
  if FTracker.Busy then
    Exit;
  Host := CaptureHostState(True);
  Conversation := nil;
  if Host.HasQueryTab then
    Conversation := FConversations.Find(Host.ConversationKey);
  try
    if Assigned(Conversation) then
      Problem := PrepareAiRequest(Host, Request, Conversation.History, Prepared)
    else
      Problem := PrepareAiRequest(Host, Request, nil, Prepared);
  except
    // E.g. the server failed while reading the schema: report it here instead of a crash dialog
    on E:Exception do
      Problem := E.Message;
  end;
  if Problem <> '' then begin
    FPanel.SetStatus(Problem, True);
    Exit;
  end;

  Conversation := FConversations.Get(Host.ConversationKey);
  TurnId := Conversation.StartTurn(Request.Task, Prepared.Title, Prepared.UserMessage,
    Prepared.ContextSent);
  FTracker.Start(Host.ConversationKey, TurnId);
  FProfile := Prepared.Profile;
  FKey := Prepared.Key;
  FMailbox := NewAiMailbox;
  FLastMailbox := FMailbox;
  StartAiRequest(Prepared.Spec, FMailbox);
  FTimer.Enabled := True;
  FPanel.ClearPrompt;
  Refresh;
  if Prepared.CacheOnly then
    FPanel.SetStatus(_('A query is running, so only the schema already loaded was sent.'), False)
  else
    FPanel.SetStatus(f_('Asking %s (%s)...', [FProfile.Name, FProfile.Model]), False);
end;

function TAiController.Redact(const Text: String): String;
begin
  // Some providers echo the key in error texts
  Result := RedactSecret(Text, FKey);
end;

procedure TAiController.TimerTick(Sender: TObject);
var
  Conversation: TAiConversation;
  Content, Reasoning: String;
  Finished: Boolean;
  Usage: TAiUsage;
begin
  if not Assigned(FMailbox) then begin
    FTimer.Enabled := False;
    Exit;
  end;
  // Read Finished first: text pushed before the finish is then always drained below
  Finished := FMailbox.Finished;
  Conversation := FConversations.Find(FTracker.TabUid);
  if FMailbox.Drain(Content, Reasoning) and Assigned(Conversation) then begin
    Conversation.AppendAnswer(FTracker.TurnId, Content);
    Conversation.AppendReasoning(FTracker.TurnId, Reasoning);
  end;
  if Finished then begin
    if Assigned(Conversation) then begin
      case FMailbox.ErrorKind of
        ekNone: begin
          Usage := FMailbox.Usage;
          Conversation.FinishTurn(FTracker.TurnId, Usage);
        end;
        ekCancelled:
          Conversation.CancelTurn(FTracker.TurnId);
        else
          Conversation.FailTurn(FTracker.TurnId, FMailbox.ErrorKind,
            RequestErrorText(FMailbox.ErrorKind, FMailbox.HttpStatus, Redact(FMailbox.ErrorMessage), FProfile));
      end;
    end;
    EndRequest;
    Refresh;
  end else if FPanel.Visible and (FShownKey = FTracker.TabUid) then
    FPanel.ShowConversation(Conversation, True);
end;

procedure TAiController.EndRequest;
begin
  FTimer.Enabled := False;
  FMailbox := nil;
  FKey := '';
  FTracker.Stop;
end;

procedure TAiController.Cancel;
var
  Conversation: TAiConversation;
begin
  if not FTracker.Busy then
    Exit;
  if Assigned(FMailbox) then
    FMailbox.Cancel;
  Conversation := FConversations.Find(FTracker.TabUid);
  if Assigned(Conversation) then
    Conversation.CancelTurn(FTracker.TurnId);
  EndRequest;
  Refresh;
end;

procedure TAiController.PanelCancel(Sender: TObject);
begin
  Cancel;
end;

procedure TAiController.PanelClear(Sender: TObject);
var
  Host: TAiHostState;
  Conversation: TAiConversation;
  ErrorSql, ErrorMessage, ErrorDatabase: String;
begin
  Host := CaptureHostState(False);
  if FTracker.BusyForTab(Host.ConversationKey) then
    Exit;
  Conversation := FConversations.Find(Host.ConversationKey);
  if Assigned(Conversation) then begin
    // Starting over keeps the record of a failed query, which still applies
    ErrorSql := Conversation.LastErrorSql;
    ErrorMessage := Conversation.LastErrorMessage;
    ErrorDatabase := Conversation.LastErrorDatabase;
    Conversation.Clear;
    Conversation.SetQueryError(ErrorSql, ErrorMessage, ErrorDatabase);
  end;
  Refresh;
end;

procedure TAiController.PanelPutSql(const Sql: String; ReplaceAll: Boolean);
var
  Host: TAiHostState;
begin
  Host := CaptureHostState(False);
  if (not Host.HasQueryTab) or (not PutSqlIntoQueryTab(Host.TabNumber, Sql, ReplaceAll)) then
    FPanel.SetStatus(_('Open a query tab first.'), True);
end;

procedure TAiController.PanelEnter(Sender: TObject);
begin
  Refresh;
end;

procedure TAiController.QueryTabClosed(TabNumber: Integer);
begin
  if FTracker.BusyForTabNumber(TabNumber) then
    Cancel;
  FConversations.DropTab(TabNumber);
end;

procedure TAiController.Shutdown;
var
  Mailbox: IAiMailbox;
begin
  if FShutDown then
    Exit;
  FShutDown := True;
  Mailbox := FLastMailbox;
  if FTracker.Busy then begin
    if Assigned(Mailbox) then
      Mailbox.Cancel;
    EndRequest;
  end;
  // The worker keeps its own reference to the mailbox; wait so it does not outlive the app
  if Assigned(Mailbox) then
    Mailbox.WaitWorkerDone(SHUTDOWNWAITMS);
  FLastMailbox := nil;
  AppSettings.WriteInt(asAiPanelWidth, FForm.ScaleFormToDesign(FPanel.Width));
end;

end.
