unit ai.panel;

// The AI assistant panel on the right side of the main window: a status line, the conversation
// of the active query tab, the SQL found in the last answer with Insert/Replace/Copy, and the
// prompt box. A passive view: it shows what the controller gives it and reports clicks through
// events. Created in code, so main.lfm stays untouched.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, LCLType,
  ai.conversation;

type
  TAiSendEvent = procedure(const Text: String) of object;
  TAiPutSqlEvent = procedure(const Sql: String; ReplaceAll: Boolean) of object;

  TAiPanel = class(TPanel)
  private
    FLabelStatus: TLabel;
    FMemoTranscript: TMemo;
    FBarSql: TPanel;
    FComboBlocks: TComboBox;
    FLabelBadge: TLabel;
    FBtnInsert, FBtnReplace, FBtnCopy, FBtnContext: TButton;
    FMemoPrompt: TMemo;
    FBtnSend, FBtnCancel, FBtnClear: TButton;
    FBlocks: TStringArray;
    FContextSent: String;
    FTranscriptText: String;
    FCanSend: Boolean;
    FOnSend: TAiSendEvent;
    FOnCancel: TNotifyEvent;
    FOnClear: TNotifyEvent;
    FOnPutSql: TAiPutSqlEvent;
    function S(Value: Integer): Integer;
    function NewButton(AParent: TWinControl; const ACaption: String; Handler: TNotifyEvent): TButton;
    function SelectedSql: String;
    procedure UpdateBadge;
    procedure SendClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure InsertClick(Sender: TObject);
    procedure ReplaceClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure ContextClick(Sender: TObject);
    procedure BlocksChange(Sender: TObject);
    procedure PromptKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetStatus(const Text: String; IsProblem: Boolean);
    // False disables sending, e.g. while no database is selected
    property CanSend: Boolean read FCanSend write FCanSend;
    // Shows a conversation; nil clears the view. Busy disables sending and enables Cancel.
    procedure ShowConversation(Conversation: TAiConversation; Busy: Boolean);
    procedure FocusPrompt;
    procedure ClearPrompt;
    function PromptText: String;
    property OnSend: TAiSendEvent read FOnSend write FOnSend;
    property OnCancel: TNotifyEvent read FOnCancel write FOnCancel;
    property OnClear: TNotifyEvent read FOnClear write FOnClear;
    property OnPutSql: TAiPutSqlEvent read FOnPutSql write FOnPutSql;
  end;

implementation

uses
  Clipbrd, StrUtils, ButtonPanel, apphelpers, ai.sqlextract, ai.text;

function TAiPanel.S(Value: Integer): Integer;
begin
  Result := Scale96ToForm(Value);
end;

function TAiPanel.NewButton(AParent: TWinControl; const ACaption: String; Handler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.AutoSize := True;
  // Left-aligned controls are ordered by Left; place each new button after the existing ones
  Result.Left := AParent.ControlCount * 1000;
  Result.Align := alLeft;
  Result.BorderSpacing.Right := S(4);
  Result.OnClick := Handler;
end;

constructor TAiPanel.Create(AOwner: TComponent);
var
  Bottom, PromptButtons: TPanel;
begin
  inherited;
  BevelOuter := bvNone;
  Caption := '';
  // Scale96ToForm needs a parent form; sizes are applied after the panel is placed on one
  if AOwner is TCustomForm then
    Self.Parent := TWinControl(AOwner);

  FLabelStatus := TLabel.Create(Self);
  FLabelStatus.Parent := Self;
  FLabelStatus.Align := alTop;
  FLabelStatus.WordWrap := True;
  FLabelStatus.AutoSize := True;
  FLabelStatus.BorderSpacing.Around := S(4);

  // Bottom: SQL bar, prompt and its buttons
  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.BevelOuter := bvNone;
  Bottom.Align := alBottom;
  Bottom.AutoSize := True;

  FBarSql := TPanel.Create(Self);
  FBarSql.Parent := Bottom;
  FBarSql.BevelOuter := bvNone;
  FBarSql.Align := alTop;
  FBarSql.AutoSize := True;
  FBarSql.BorderSpacing.Around := S(4);
  FBtnInsert := NewButton(FBarSql, _('Insert'), InsertClick);
  FBtnInsert.Hint := _('Insert the SQL at the cursor of the query editor. It is not executed.');
  FBtnReplace := NewButton(FBarSql, _('Replace'), ReplaceClick);
  FBtnReplace.Hint := _('Replace the whole query editor text with the SQL. It is not executed.');
  FBtnCopy := NewButton(FBarSql, _('Copy'), CopyClick);
  FBtnContext := NewButton(FBarSql, _('Context sent...'), ContextClick);
  FBtnContext.Hint := _('Show exactly what was sent to the AI provider with the last question');
  FBtnContext.Align := alRight;
  FBtnContext.BorderSpacing.Right := 0;
  FComboBlocks := TComboBox.Create(Self);
  FComboBlocks.Parent := Bottom;
  FComboBlocks.Style := csDropDownList;
  FComboBlocks.Align := alTop;
  FComboBlocks.BorderSpacing.Left := S(4);
  FComboBlocks.BorderSpacing.Right := S(4);
  FComboBlocks.Hint := _('The answer contains several SQL blocks. Choose the one to insert or copy.');
  FComboBlocks.OnChange := BlocksChange;
  FComboBlocks.Top := FBarSql.Top + FBarSql.Height + 1;
  FLabelBadge := TLabel.Create(Self);
  FLabelBadge.Parent := Bottom;
  FLabelBadge.Align := alTop;
  FLabelBadge.WordWrap := True;
  FLabelBadge.Font.Color := clRed;
  FLabelBadge.BorderSpacing.Left := S(4);
  FLabelBadge.BorderSpacing.Right := S(4);
  FLabelBadge.Top := FComboBlocks.Top + FComboBlocks.Height + 1;

  FMemoPrompt := TMemo.Create(Self);
  FMemoPrompt.Parent := Bottom;
  FMemoPrompt.Align := alTop;
  FMemoPrompt.Height := S(80);
  FMemoPrompt.WordWrap := True;
  FMemoPrompt.ScrollBars := ssAutoVertical;
  FMemoPrompt.BorderSpacing.Around := S(4);
  FMemoPrompt.TextHint := _('Describe the query you need, e.g. "Customers without orders in 2024"');
  FMemoPrompt.OnKeyDown := PromptKeyDown;
  FMemoPrompt.Top := FLabelBadge.Top + FLabelBadge.Height + 1;

  PromptButtons := TPanel.Create(Self);
  PromptButtons.Parent := Bottom;
  PromptButtons.BevelOuter := bvNone;
  PromptButtons.Align := alTop;
  PromptButtons.AutoSize := True;
  PromptButtons.BorderSpacing.Around := S(4);
  PromptButtons.Top := FMemoPrompt.Top + FMemoPrompt.Height + 1;
  FBtnSend := NewButton(PromptButtons, _('Generate SQL'), SendClick);
  FBtnSend.Hint := _('Send the question to the AI provider (Ctrl+Enter)');
  FBtnCancel := NewButton(PromptButtons, _('Cancel'), CancelClick);
  FBtnClear := NewButton(PromptButtons, _('Clear'), ClearClick);
  FBtnClear.Hint := _('Start a new conversation in this query tab');
  FBtnClear.Align := alRight;
  FBtnClear.BorderSpacing.Right := 0;

  FMemoTranscript := TMemo.Create(Self);
  FMemoTranscript.Parent := Self;
  FMemoTranscript.Align := alClient;
  FMemoTranscript.ReadOnly := True;
  FMemoTranscript.WordWrap := True;
  FMemoTranscript.ScrollBars := ssAutoVertical;
  FMemoTranscript.BorderSpacing.Left := S(4);
  FMemoTranscript.BorderSpacing.Right := S(4);

  ShowHint := True;
  ShowConversation(nil, False);
end;

procedure TAiPanel.SetStatus(const Text: String; IsProblem: Boolean);
begin
  FLabelStatus.Caption := Text;
  if IsProblem then
    FLabelStatus.Font.Color := clRed
  else
    FLabelStatus.Font.Color := clDefault;
end;

function TurnText(const Turn: TAiTurn): String;
var
  Answer: String;
begin
  Result := '> ' + Turn.Title + sLineBreak + sLineBreak;
  Answer := StripThinking(Turn.Answer).Trim;
  case Turn.State of
    tsStreaming: begin
      if Answer <> '' then
        Result := Result + Answer
      else if Turn.Reasoning <> '' then
        Result := Result + _('Thinking...')
      else
        Result := Result + _('Waiting for the answer...');
    end;
    tsDone: begin
      if Answer <> '' then
        Result := Result + Answer
      else
        Result := Result + _('The answer was empty.');
    end;
    tsFailed:
      Result := Result + Answer + IfThen(Answer <> '', sLineBreak + sLineBreak, '')
        + f_('Error: %s', [Turn.ErrorMessage]);
    tsCancelled:
      Result := Result + Answer + IfThen(Answer <> '', sLineBreak + sLineBreak, '')
        + _('Cancelled.');
  end;
end;

function SameBlocks(const A, B: TStringArray): Boolean;
var
  i: Integer;
begin
  Result := Length(A) = Length(B);
  for i:=0 to High(A) do begin
    if not Result then
      Break;
    Result := A[i] = B[i];
  end;
end;

procedure TAiPanel.ShowConversation(Conversation: TAiConversation; Busy: Boolean);
var
  Text, Caption: String;
  i: Integer;
  Last: TAiTurn;
  HasLast: Boolean;
  NewBlocks: TStringArray;
  KeepIndex: Integer;
begin
  Text := '';
  HasLast := Assigned(Conversation) and (Conversation.Count > 0);
  if HasLast then begin
    for i:=0 to Conversation.Count-1 do begin
      if i > 0 then
        Text := Text + sLineBreak + sLineBreak;
      Text := Text + TurnText(Conversation[i]);
    end;
    Last := Conversation[Conversation.Count-1];
  end;
  if Text <> FTranscriptText then begin
    FTranscriptText := Text;
    FMemoTranscript.Lines.BeginUpdate;
    try
      FMemoTranscript.Text := Text;
    finally
      FMemoTranscript.Lines.EndUpdate;
    end;
    FMemoTranscript.SelStart := Length(Text);
  end;

  NewBlocks := nil;
  if HasLast and (Last.State = tsDone) then
    NewBlocks := ExtractSqlBlocks(Last.Answer);
  if HasLast then
    FContextSent := Last.ContextSent
  else
    FContextSent := '';
  // Refreshes happen on every tab or tree change; keep the block the user chose
  KeepIndex := -1;
  if SameBlocks(NewBlocks, FBlocks) then
    KeepIndex := FComboBlocks.ItemIndex;
  FBlocks := NewBlocks;
  FComboBlocks.Items.BeginUpdate;
  try
    FComboBlocks.Items.Clear;
    for i:=0 to High(FBlocks) do begin
      Caption := StringReplace(FBlocks[i], sLineBreak, ' ', [rfReplaceAll]);
      Caption := StringReplace(Caption, #10, ' ', [rfReplaceAll]);
      FComboBlocks.Items.Add(f_('Block %d: %s', [i+1, Utf8Truncate(Caption, 80)]));
    end;
  finally
    FComboBlocks.Items.EndUpdate;
  end;
  if (KeepIndex >= 0) and (KeepIndex <= High(FBlocks)) then
    FComboBlocks.ItemIndex := KeepIndex
  else if Length(FBlocks) > 0 then
    FComboBlocks.ItemIndex := 0;
  FComboBlocks.Visible := Length(FBlocks) > 1;
  FBtnInsert.Enabled := Length(FBlocks) > 0;
  FBtnReplace.Enabled := FBtnInsert.Enabled;
  FBtnCopy.Enabled := FBtnInsert.Enabled;
  FBtnContext.Enabled := FContextSent <> '';
  FBtnSend.Enabled := FCanSend and (not Busy);
  FBtnCancel.Enabled := Busy;
  FBtnClear.Enabled := (not Busy) and HasLast;
  UpdateBadge;
end;

function TAiPanel.SelectedSql: String;
begin
  Result := '';
  if (FComboBlocks.ItemIndex >= 0) and (FComboBlocks.ItemIndex <= High(FBlocks)) then
    Result := FBlocks[FComboBlocks.ItemIndex]
  else if Length(FBlocks) > 0 then
    Result := FBlocks[0];
end;

procedure TAiPanel.UpdateBadge;
var
  Effects: TSqlEffects;
  Text: String;
begin
  Text := '';
  if SelectedSql <> '' then begin
    Effects := SqlEffects(SelectedSql);
    if seModifiesSchema in Effects then
      Text := _('Changes the database structure (DDL). Review it before running.')
    else if seModifiesData in Effects then
      Text := _('Changes data (DML). Review it before running.');
  end;
  FLabelBadge.Caption := Text;
  FLabelBadge.Visible := Text <> '';
end;

procedure TAiPanel.FocusPrompt;
begin
  if FMemoPrompt.CanFocus then
    FMemoPrompt.SetFocus;
end;

procedure TAiPanel.ClearPrompt;
begin
  FMemoPrompt.Clear;
end;

function TAiPanel.PromptText: String;
begin
  Result := Trim(FMemoPrompt.Text);
end;

procedure TAiPanel.SendClick(Sender: TObject);
begin
  if Assigned(FOnSend) and FBtnSend.Enabled then
    FOnSend(PromptText);
end;

procedure TAiPanel.CancelClick(Sender: TObject);
begin
  if Assigned(FOnCancel) then
    FOnCancel(Self);
end;

procedure TAiPanel.ClearClick(Sender: TObject);
begin
  if Assigned(FOnClear) then
    FOnClear(Self);
end;

procedure TAiPanel.InsertClick(Sender: TObject);
begin
  if Assigned(FOnPutSql) and (SelectedSql <> '') then
    FOnPutSql(SelectedSql, False);
end;

procedure TAiPanel.ReplaceClick(Sender: TObject);
begin
  if Assigned(FOnPutSql) and (SelectedSql <> '') then
    FOnPutSql(SelectedSql, True);
end;

procedure TAiPanel.CopyClick(Sender: TObject);
begin
  if SelectedSql <> '' then
    Clipboard.AsText := SelectedSql;
end;

procedure TAiPanel.ContextClick(Sender: TObject);
var
  Dialog: TForm;
  Memo: TMemo;
  Buttons: TButtonPanel;
begin
  if FContextSent = '' then
    Exit;
  Dialog := TForm.CreateNew(nil);
  try
    Dialog.Caption := _('Context sent to the AI provider');
    Dialog.Position := poMainFormCenter;
    Dialog.Width := Dialog.Scale96ToForm(700);
    Dialog.Height := Dialog.Scale96ToForm(500);
    Buttons := TButtonPanel.Create(Dialog);
    Buttons.Parent := Dialog;
    Buttons.ShowButtons := [pbClose];
    Memo := TMemo.Create(Dialog);
    Memo.Parent := Dialog;
    Memo.Align := alClient;
    Memo.ReadOnly := True;
    Memo.ScrollBars := ssAutoBoth;
    Memo.Font.Name := AppSettings.ReadString(asFontName);
    Memo.Text := FContextSent;
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

procedure TAiPanel.BlocksChange(Sender: TObject);
begin
  UpdateBadge;
end;

procedure TAiPanel.PromptKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and (ssCtrl in Shift) then begin
    Key := 0;
    SendClick(Sender);
  end;
end;

end.
