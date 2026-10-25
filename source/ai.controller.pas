unit ai.controller;

// Runs the AI assistant's requests: one request in flight at a time, streamed into the
// conversation of the query tab it was started from. A 50 ms timer moves text from the worker's
// mailbox to the conversation; data of a cancelled or replaced request is dropped. Owns the
// panel and the per-tab conversations. Main thread only.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, ai.types, ai.http, ai.profiles, ai.conversations,
  ai.panel;

type
  TAiController = class(TComponent)
  private
    FPanel: TAiPanel;
    FSplitter: TSplitter;
    FTimer: TTimer;
    FConversations: TAiConversations;
    FTracker: TAiRequestTracker;
    FMailbox: IAiMailbox;
    FProfile: TAiProfile;
    FKey: String;
    FShownTabUid: String;
    FShutDown: Boolean;
    procedure TimerTick(Sender: TObject);
    procedure PanelSend(const Text: String);
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
    procedure Cancel;
    procedure QueryTabClosed(const TabUid: String);
    // Cancels a running request and waits briefly for its worker thread
    procedure Shutdown;
    property PanelVisible: Boolean read GetPanelVisible write SetPanelVisible;
  end;

var
  AiController: TAiController;

implementation

uses
  apphelpers, ai.conversation, ai.hostcontext, ai.requestprep, ai.uitext;

const
  DRAININTERVALMS = 50;
  SHUTDOWNWAITMS = 2000;

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
  FPanel.Width := AppSettings.ReadInt(asAiPanelWidth);
  FPanel.OnSend := PanelSend;
  FPanel.OnCancel := PanelCancel;
  FPanel.OnClear := PanelClear;
  FPanel.OnPutSql := PanelPutSql;
  // The database may have changed since the last tab change
  FPanel.OnEnter := PanelEnter;
  FSplitter := TSplitter.Create(AOwner);
  FSplitter.Parent := Host;
  FSplitter.Align := alRight;
  FSplitter.Left := FPanel.Left - 1;
  FSplitter.ResizeStyle := rsPattern;
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
begin
  if not FPanel.Visible then
    Exit;
  Host := CaptureHostState;
  FShownTabUid := Host.TabUid;
  if not Host.HasQueryTab then
    FPanel.SetStatus(_('Open a query tab to use the AI assistant.'), False)
  else if Host.Connection = nil then
    FPanel.SetStatus(_('Connect to a database to use the AI assistant.'), False)
  else if FTracker.Busy and (not FTracker.BusyForTab(Host.TabUid)) then
    FPanel.SetStatus(_('Another query tab is waiting for an answer.'), False)
  else
    FPanel.SetStatus(f_('Session "%s", database "%s"', [Host.SessionName, Host.Database]), False);
  FPanel.ShowConversation(FConversations.Find(Host.TabUid), FTracker.Busy);
end;

procedure TAiController.Generate;
begin
  PanelVisible := True;
  FPanel.FocusPrompt;
end;

procedure TAiController.PanelSend(const Text: String);
var
  Host: TAiHostState;
  Conversation: TAiConversation;
  Prepared: TAiPrepared;
  Problem: String;
  TurnId: Integer;
begin
  if FTracker.Busy then
    Exit;
  Host := CaptureHostState;
  Conversation := nil;
  if Host.HasQueryTab then
    Conversation := FConversations.Find(Host.TabUid);
  if Assigned(Conversation) then
    Problem := PrepareAiRequest(Host, atGenerate, Text, Conversation.History, Prepared)
  else
    Problem := PrepareAiRequest(Host, atGenerate, Text, nil, Prepared);
  if Problem <> '' then begin
    FPanel.SetStatus(Problem, True);
    Exit;
  end;

  Conversation := FConversations.Get(Host.TabUid);
  TurnId := Conversation.StartTurn(atGenerate, Prepared.Title, Prepared.UserMessage,
    Prepared.ContextSent);
  FTracker.Start(Host.TabUid, TurnId);
  FProfile := Prepared.Profile;
  FKey := Prepared.Key;
  FMailbox := NewAiMailbox;
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
  Result := Text;
  // Some providers echo the key in error texts
  if Length(FKey) >= 8 then
    Result := StringReplace(Result, FKey, '***', [rfReplaceAll]);
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
  end else if FPanel.Visible and (FShownTabUid = FTracker.TabUid) then
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
begin
  Host := CaptureHostState;
  if FTracker.BusyForTab(Host.TabUid) then
    Exit;
  FConversations.Drop(Host.TabUid);
  Refresh;
end;

procedure TAiController.PanelPutSql(const Sql: String; ReplaceAll: Boolean);
var
  Host: TAiHostState;
begin
  Host := CaptureHostState;
  if not PutSqlIntoQueryTab(Host.TabUid, Sql, ReplaceAll) then
    FPanel.SetStatus(_('Open a query tab first.'), True);
end;

procedure TAiController.PanelEnter(Sender: TObject);
begin
  Refresh;
end;

procedure TAiController.QueryTabClosed(const TabUid: String);
begin
  if FTracker.BusyForTab(TabUid) then
    Cancel;
  FConversations.Drop(TabUid);
end;

procedure TAiController.Shutdown;
var
  Mailbox: IAiMailbox;
begin
  if FShutDown then
    Exit;
  FShutDown := True;
  Mailbox := FMailbox;
  if FTracker.Busy then begin
    if Assigned(Mailbox) then
      Mailbox.Cancel;
    EndRequest;
  end;
  // The worker keeps its own reference to the mailbox; wait so it does not outlive the app
  if Assigned(Mailbox) then
    Mailbox.WaitWorkerDone(SHUTDOWNWAITMS);
  AppSettings.WriteInt(asAiPanelWidth, FPanel.Width);
end;

end.
