unit ai.prefsframe;

// "AI providers" tab of the preferences dialog: the list of provider profiles, an editor for the
// selected one, key storage in the keychain and a connection test that lists the models.
// Built in code, so the upstream preferences form file stays untouched.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Spin, EditBtn,
  ai.profiles, ai.modelfetch;

type
  TAiProvidersPanel = class(TPanel)
  private
    FProfiles: TAiProfileList;
    FFetch: TAiModelFetch;
    FUpdating: Boolean;
    FModified: Boolean;
    FNextRowTop: Integer;
    FRowLabels: array of TLabel;
    FReadOnlyReason: String;
    FOnModified: TNotifyEvent;
    FList: TListBox;
    FBtnAdd, FBtnRemove, FBtnDefault, FBtnTest, FBtnStoreKey, FBtnRemoveKey: TButton;
    FEditor: TScrollBox;
    FEditName, FEditUrl, FEditKeyName: TEdit;
    FComboModel: TComboBox;
    FRadioKeySource: TRadioGroup;
    FLabelKeyStatus, FLabelTest, FLabelProblems, FLabelFileState: TLabel;
    FSpinTemperature: TFloatSpinEdit;
    FSpinContext, FSpinTimeout: TSpinEdit;
    FCheckUntrusted: TCheckBox;
    FEditCaFile: TFileNameEdit;
    function S(Value: Integer): Integer;
    function AddRow(const Caption: String; Control: TControl; Height: Integer = 0): TPanel;
    function AddMessageRow(const Caption: String; Message: TLabel): TPanel;
    procedure SizeLabelColumn;
    function NewButton(AParent: TWinControl; const Caption: String; Handler: TNotifyEvent): TButton;
    procedure BuildControls;
    function SelectedIndex: Integer;
    procedure FillList;
    procedure ShowProfile;
    procedure EditorChanged(Sender: TObject);
    procedure KeySourceChanged(Sender: TObject);
    procedure ListSelect(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure DefaultClick(Sender: TObject);
    procedure TestClick(Sender: TObject);
    procedure StoreKeyClick(Sender: TObject);
    procedure RemoveKeyClick(Sender: TObject);
    procedure TestDone(Success: Boolean; const Models: TStringArray; const Message: String);
    procedure RefreshKeyStatus;
    procedure SetModified;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadSettings;
    procedure SaveSettings;
    property OnModified: TNotifyEvent read FOnModified write FOnModified;
  end;

implementation

uses
  Math, Dialogs, Clipbrd, apphelpers, ai.keystore, ai.appprofiles, ai.uitext
  // The platform's keychain backend registers itself when its unit is linked
  {$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}, ai.keystore.libsecret{$ENDIF}
  {$IFDEF WINDOWS}, ai.keystore.windows{$ENDIF}
  {$IFDEF DARWIN}, ai.keystore.macos{$ENDIF};

const
  DEFAULTMARK = '★ ';

constructor TAiProvidersPanel.Create(AOwner: TComponent);
begin
  inherited;
  BevelOuter := bvNone;
  Caption := '';
  FProfiles := TAiProfileList.Create;
  FFetch := TAiModelFetch.Create(Self);
  BuildControls;
end;

destructor TAiProvidersPanel.Destroy;
begin
  FFetch.Cancel;
  FProfiles.Free;
  inherited;
end;

function TAiProvidersPanel.S(Value: Integer): Integer;
begin
  // Controls are built in the constructor, before this panel has a parent: scale with the
  // owning form, as Scale96ToForm would raise "Control has no parent form or frame"
  if Owner is TCustomDesignControl then
    Result := TCustomDesignControl(Owner).Scale96ToForm(Value)
  else
    Result := Scale96ToScreen(Value);
end;

function TAiProvidersPanel.NewButton(AParent: TWinControl; const Caption: String; Handler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := Caption;
  Result.AutoSize := True;
  Result.OnClick := Handler;
  Result.BorderSpacing.Around := S(2);
end;

// A labelled row in the editor; rows stack from top to bottom
function TAiProvidersPanel.AddRow(const Caption: String; Control: TControl; Height: Integer = 0): TPanel;
var
  Lbl: TLabel;
begin
  Result := TPanel.Create(Self);
  Result.Parent := FEditor;
  Result.BevelOuter := bvNone;
  Result.Caption := '';
  if Height = 0 then
    Height := S(30);
  // Rows are aligned to the top in the order they are added
  Result.SetBounds(0, FNextRowTop, FEditor.ClientWidth, Height);
  Inc(FNextRowTop, Height);
  Result.Align := alTop;
  Lbl := TLabel.Create(Self);
  Lbl.Parent := Result;
  Lbl.Align := alLeft;
  Lbl.AutoSize := False;
  Lbl.Width := S(150); // Final width set by SizeLabelColumn
  SetLength(FRowLabels, Length(FRowLabels) + 1);
  FRowLabels[High(FRowLabels)] := Lbl;
  Lbl.Layout := tlCenter;
  Lbl.Caption := Caption;
  Lbl.BorderSpacing.Left := S(6);
  if Assigned(Control) then begin
    Control.Parent := Result;
    Control.Align := alClient;
    Control.BorderSpacing.Around := S(3);
    if Control is TWinControl then
      Lbl.FocusControl := TWinControl(Control);
  end;
end;

// A row whose height follows its wrapped message text
function TAiProvidersPanel.AddMessageRow(const Caption: String; Message: TLabel): TPanel;
begin
  Message.WordWrap := True;
  Message.AutoSize := True;
  Result := AddRow(Caption, Message, S(8));
  Result.AutoSize := True;
end;

// All row labels as wide as the longest caption, so translations are not cut off
procedure TAiProvidersPanel.SizeLabelColumn;
var
  Lbl: TLabel;
  Widest: Integer;
begin
  Widest := S(100);
  if Owner is TCustomForm then begin
    for Lbl in FRowLabels do
      Widest := Max(Widest, TCustomForm(Owner).Canvas.TextWidth(Lbl.Caption));
  end;
  for Lbl in FRowLabels do
    Lbl.Width := Widest + S(16);
end;

procedure TAiProvidersPanel.BuildControls;
var
  Left, Buttons, Row, Bar: TPanel;
begin
  Left := TPanel.Create(Self);
  Left.Parent := Self;
  Left.BevelOuter := bvNone;
  Left.Caption := '';
  Left.Align := alLeft;
  Left.Width := S(210);
  Buttons := TPanel.Create(Self);
  Buttons.Parent := Left;
  Buttons.BevelOuter := bvNone;
  Buttons.Caption := '';
  Buttons.Align := alBottom;
  Buttons.AutoSize := True;
  Buttons.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
  Buttons.ChildSizing.ControlsPerLine := 3;
  FBtnAdd := NewButton(Buttons, _('Add'), AddClick);
  FBtnRemove := NewButton(Buttons, _('Remove'), RemoveClick);
  FBtnDefault := NewButton(Buttons, _('Default'), DefaultClick);
  FBtnDefault.Hint := _('Use this profile for sessions that do not choose one');
  FBtnDefault.ShowHint := True;
  FList := TListBox.Create(Self);
  FList.Parent := Left;
  FList.Align := alClient;
  FList.BorderSpacing.Around := S(3);
  FList.OnSelectionChange := nil;
  FList.OnClick := ListSelect;

  FEditor := TScrollBox.Create(Self);
  FEditor.Parent := Self;
  FEditor.Align := alClient;
  FEditor.BorderStyle := bsNone;
  FEditor.HorzScrollBar.Visible := False;

  FLabelFileState := TLabel.Create(Self);
  FLabelFileState.WordWrap := True;
  FLabelFileState.Font.Style := [fsBold];
  AddRow('', FLabelFileState, S(0)).Visible := False;

  FEditName := TEdit.Create(Self);
  AddRow(_('Name:'), FEditName);
  FEditUrl := TEdit.Create(Self);
  FEditUrl.TextHint := 'http://localhost:11434/v1';
  AddRow(_('Base URL:'), FEditUrl);
  FComboModel := TComboBox.Create(Self);
  FComboModel.Style := csDropDown;
  Row := AddRow(_('Model:'), FComboModel);
  FBtnTest := NewButton(Row, _('Test'), TestClick);
  FBtnTest.Align := alRight;
  FBtnTest.Hint := _('Connect to the server and list its models');
  FBtnTest.ShowHint := True;
  FLabelTest := TLabel.Create(Self);
  AddMessageRow('', FLabelTest);

  FRadioKeySource := TRadioGroup.Create(Self);
  FRadioKeySource.Caption := '';
  FRadioKeySource.Columns := 3;
  FRadioKeySource.Items.Add(_('None'));
  FRadioKeySource.Items.Add(_('Environment variable'));
  FRadioKeySource.Items.Add(_('Keychain entry'));
  AddRow(_('API key:'), FRadioKeySource, S(44));
  FEditKeyName := TEdit.Create(Self);
  AddRow(_('Variable or entry name:'), FEditKeyName);
  Bar := TPanel.Create(Self);
  Bar.BevelOuter := bvNone;
  Bar.Caption := '';
  Bar.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
  Bar.ChildSizing.ControlsPerLine := 2;
  AddRow('', Bar, S(34));
  FBtnStoreKey := NewButton(Bar, _('Store key...'), StoreKeyClick);
  FBtnRemoveKey := NewButton(Bar, _('Remove key'), RemoveKeyClick);
  FLabelKeyStatus := TLabel.Create(Self);
  AddMessageRow(_('Key status:'), FLabelKeyStatus);

  FSpinTemperature := TFloatSpinEdit.Create(Self);
  FSpinTemperature.MinValue := 0;
  FSpinTemperature.MaxValue := 2;
  FSpinTemperature.Increment := 0.1;
  FSpinTemperature.DecimalPlaces := 2;
  AddRow(_('Temperature:'), FSpinTemperature);
  FSpinContext := TSpinEdit.Create(Self);
  FSpinContext.MinValue := 1000;
  FSpinContext.MaxValue := 1000000;
  FSpinContext.Increment := 1000;
  AddRow(_('Schema context (characters):'), FSpinContext);
  FSpinTimeout := TSpinEdit.Create(Self);
  FSpinTimeout.MinValue := 5;
  FSpinTimeout.MaxValue := 3600;
  AddRow(_('Read timeout (seconds):'), FSpinTimeout);
  FCheckUntrusted := TCheckBox.Create(Self);
  FCheckUntrusted.Caption := _('Accept untrusted HTTPS certificates (self-signed servers only)');
  AddRow('', FCheckUntrusted);
  FEditCaFile := TFileNameEdit.Create(Self);
  FEditCaFile.Filter := _('Certificates') + ' (*.pem;*.crt)|*.pem;*.crt|' + _('All files') + '|*';
  AddRow(_('Extra CA file:'), FEditCaFile);
  FLabelProblems := TLabel.Create(Self);
  FLabelProblems.Font.Color := clRed;
  AddMessageRow('', FLabelProblems);
  SizeLabelColumn;

  FEditName.OnChange := EditorChanged;
  FEditUrl.OnChange := EditorChanged;
  FComboModel.OnChange := EditorChanged;
  FEditKeyName.OnChange := EditorChanged;
  FEditKeyName.OnExit := KeySourceChanged;
  FRadioKeySource.OnClick := KeySourceChanged;
  FSpinTemperature.OnChange := EditorChanged;
  FSpinContext.OnChange := EditorChanged;
  FSpinTimeout.OnChange := EditorChanged;
  FCheckUntrusted.OnChange := EditorChanged;
  FEditCaFile.OnChange := EditorChanged;
end;

function TAiProvidersPanel.SelectedIndex: Integer;
begin
  Result := FList.ItemIndex;
  if (Result < 0) or (Result >= FProfiles.Count) then
    Result := -1;
end;

procedure TAiProvidersPanel.FillList;
var
  i, Keep: Integer;
  Text: String;
begin
  Keep := FList.ItemIndex;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for i:=0 to FProfiles.Count-1 do begin
      Text := FProfiles[i].Name;
      if Text.Trim = '' then
        Text := _('(unnamed)');
      if SameText(FProfiles[i].Id, FProfiles.DefaultId) then
        Text := DEFAULTMARK + Text;
      FList.Items.Add(Text);
    end;
  finally
    FList.Items.EndUpdate;
  end;
  if (Keep < 0) and (FList.Count > 0) then
    Keep := 0;
  if Keep >= FList.Count then
    Keep := FList.Count - 1;
  FList.ItemIndex := Keep;
end;

procedure TAiProvidersPanel.ShowProfile;
var
  i: Integer;
  P: TAiProfile;
begin
  i := SelectedIndex;
  FEditor.Enabled := (i >= 0) and (FReadOnlyReason = '');
  FBtnRemove.Enabled := FEditor.Enabled;
  FBtnDefault.Enabled := FEditor.Enabled;
  FBtnAdd.Enabled := FReadOnlyReason = '';
  if i < 0 then
    Exit;
  P := FProfiles[i];
  FUpdating := True;
  try
    FEditName.Text := P.Name;
    FEditUrl.Text := P.BaseUrl;
    FComboModel.Items.Clear;
    FComboModel.Text := P.Model;
    FRadioKeySource.ItemIndex := Ord(P.KeySource);
    FEditKeyName.Text := P.KeyName;
    FSpinTemperature.Value := P.Temperature;
    FSpinContext.Value := P.MaxContextChars;
    FSpinTimeout.Value := P.IoTimeoutSec;
    FCheckUntrusted.Checked := P.AllowUntrustedTls;
    FEditCaFile.Text := P.ExtraCaFile;
    FLabelTest.Caption := '';
  finally
    FUpdating := False;
  end;
  FLabelProblems.Caption := ProfileProblemsText(ValidateAiProfile(P));
  RefreshKeyStatus;
end;

procedure TAiProvidersPanel.EditorChanged(Sender: TObject);
var
  i: Integer;
  P: TAiProfile;
begin
  i := SelectedIndex;
  if FUpdating or (i < 0) then
    Exit;
  P := FProfiles[i];
  P.Name := FEditName.Text;
  P.BaseUrl := Trim(FEditUrl.Text);
  P.Model := Trim(FComboModel.Text);
  if FRadioKeySource.ItemIndex >= 0 then
    P.KeySource := TAiKeySource(FRadioKeySource.ItemIndex);
  P.KeyName := Trim(FEditKeyName.Text);
  if FSpinTemperature.Value >= 0 then
    P.Temperature := FSpinTemperature.Value;
  P.MaxContextChars := FSpinContext.Value;
  P.IoTimeoutSec := FSpinTimeout.Value;
  P.AllowUntrustedTls := FCheckUntrusted.Checked;
  P.ExtraCaFile := Trim(FEditCaFile.Text);
  FProfiles.Update(P);
  FLabelProblems.Caption := ProfileProblemsText(ValidateAiProfile(P));
  if Sender = FEditName then begin
    FUpdating := True;
    try
      FillList;
    finally
      FUpdating := False;
    end;
  end;
  SetModified;
end;

procedure TAiProvidersPanel.KeySourceChanged(Sender: TObject);
begin
  EditorChanged(Sender);
  RefreshKeyStatus;
end;

procedure TAiProvidersPanel.RefreshKeyStatus;
var
  i: Integer;
  Key, Problem: String;
  KeyResult: TAiKeyResult;
begin
  i := SelectedIndex;
  FEditKeyName.Enabled := (i >= 0) and (FProfiles[i].KeySource <> ksNone);
  FBtnStoreKey.Enabled := (i >= 0) and (FProfiles[i].KeySource = ksKeychain);
  FBtnRemoveKey.Enabled := FBtnStoreKey.Enabled;
  if i < 0 then begin
    FLabelKeyStatus.Caption := '';
    Exit;
  end;
  if (FProfiles[i].KeySource <> ksNone) and (FProfiles[i].KeyName = '') then begin
    FLabelKeyStatus.Caption := '';
    Exit;
  end;
  KeyResult := ResolveApiKey(FProfiles[i], Key, Problem);
  // Only the status is shown, never the key
  Key := '';
  FLabelKeyStatus.Caption := KeyResultText(KeyResult, FProfiles[i], Problem);
end;

procedure TAiProvidersPanel.ListSelect(Sender: TObject);
begin
  if not FUpdating then
    ShowProfile;
end;

procedure TAiProvidersPanel.AddClick(Sender: TObject);
var
  P: TAiProfile;
begin
  P := NewAiProfile(_('New provider'));
  FProfiles.Add(P);
  FillList;
  FList.ItemIndex := FProfiles.Count - 1;
  ShowProfile;
  SetModified;
  FEditName.SetFocus;
  FEditName.SelectAll;
end;

procedure TAiProvidersPanel.RemoveClick(Sender: TObject);
var
  i: Integer;
begin
  i := SelectedIndex;
  if i < 0 then
    Exit;
  if MessageDlg(f_('Remove the provider "%s"? Sessions using it will ask for another provider.',
    [FProfiles[i].Name]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  FProfiles.Delete(FProfiles[i].Id);
  FillList;
  ShowProfile;
  SetModified;
end;

procedure TAiProvidersPanel.DefaultClick(Sender: TObject);
var
  i: Integer;
begin
  i := SelectedIndex;
  if i < 0 then
    Exit;
  FProfiles.DefaultId := FProfiles[i].Id;
  FillList;
  SetModified;
end;

procedure TAiProvidersPanel.TestClick(Sender: TObject);
var
  i: Integer;
  Key, Problem: String;
  KeyResult: TAiKeyResult;
begin
  i := SelectedIndex;
  if i < 0 then
    Exit;
  KeyResult := ResolveApiKey(FProfiles[i], Key, Problem);
  if not (KeyResult in [krFound, krNotNeeded]) then begin
    FLabelTest.Caption := KeyResultText(KeyResult, FProfiles[i], Problem);
    Exit;
  end;
  FLabelTest.Caption := _('Connecting...');
  FBtnTest.Enabled := False;
  FFetch.Start(FProfiles[i], Key, TestDone);
end;

procedure TAiProvidersPanel.TestDone(Success: Boolean; const Models: TStringArray; const Message: String);
var
  Model, Current: String;
begin
  FBtnTest.Enabled := True;
  FLabelTest.Caption := Message;
  if not Success then
    Exit;
  Current := FComboModel.Text;
  FUpdating := True;
  try
    FComboModel.Items.Clear;
    for Model in Models do
      FComboModel.Items.Add(Model);
    FComboModel.Text := Current;
  finally
    FUpdating := False;
  end;
  if Current = '' then
    FComboModel.DroppedDown := True;
end;

procedure TAiProvidersPanel.StoreKeyClick(Sender: TObject);
var
  i: Integer;
  Key, Problem: String;
begin
  i := SelectedIndex;
  if (i < 0) or (FProfiles[i].KeyName = '') then begin
    MessageDlg(_('Enter a name for the keychain entry first.'), mtInformation, [mbOK], 0);
    Exit;
  end;
  {$IFDEF DARWIN}
  Clipboard.AsText := MacStoreCommand(FProfiles[i].KeyName);
  MessageDlg(_('Run this command in Terminal, which then asks for the key. It was copied to the clipboard:')
    + LineEnding + LineEnding + MacStoreCommand(FProfiles[i].KeyName), mtInformation, [mbOK], 0);
  {$ELSE}
  Key := '';
  if not InputQuery(_('Store key'), f_('API key for "%s":', [FProfiles[i].Name]), True, Key) then
    Exit;
  if Key.Trim = '' then
    Exit;
  if Assigned(Keychain) and Keychain.Store(FProfiles[i].KeyName, Key.Trim, Problem) then
    Key := ''
  else begin
    Key := '';
    MessageDlg(KeyResultText(krKeychainError, FProfiles[i], Problem), mtError, [mbOK], 0);
  end;
  {$ENDIF}
  RefreshKeyStatus;
end;

procedure TAiProvidersPanel.RemoveKeyClick(Sender: TObject);
var
  i: Integer;
  Problem: String;
begin
  i := SelectedIndex;
  if (i < 0) or (FProfiles[i].KeyName = '') or not Assigned(Keychain) then
    Exit;
  if MessageDlg(f_('Remove the keychain entry "%s"?', [FProfiles[i].KeyName]),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  if not Keychain.Remove(FProfiles[i].KeyName, Problem) then
    MessageDlg(KeyResultText(krKeychainError, FProfiles[i], Problem), mtError, [mbOK], 0);
  RefreshKeyStatus;
end;

procedure TAiProvidersPanel.SetModified;
begin
  FModified := True;
  if Assigned(FOnModified) then
    FOnModified(Self);
end;

procedure TAiProvidersPanel.LoadSettings;
var
  State: TAiProfilesLoadResult;
begin
  State := LoadAppProfiles(FProfiles);
  case State of
    plrCorrupt: FReadOnlyReason := f_('%s cannot be read as profiles. Fix or delete the file; it is not overwritten.', [AppProfilesFileName]);
    plrUnreadable: FReadOnlyReason := f_('%s cannot be opened.', [AppProfilesFileName]);
    plrNewerVersion: FReadOnlyReason := f_('%s was written by a newer version and is shown read-only.', [AppProfilesFileName]);
    else FReadOnlyReason := '';
  end;
  FLabelFileState.Caption := FReadOnlyReason;
  FLabelFileState.Parent.Visible := FReadOnlyReason <> '';
  if FLabelFileState.Parent.Visible then
    FLabelFileState.Parent.Height := S(50);
  // A seeded starter profile is new: save it with the next Apply
  FModified := State = plrMissing;
  FillList;
  ShowProfile;
end;

procedure TAiProvidersPanel.SaveSettings;
begin
  if (not FModified) or (FReadOnlyReason <> '') then
    Exit;
  try
    SaveAppProfiles(FProfiles);
    FModified := False;
  except
    on E: Exception do
      MessageDlg(f_('Saving the AI providers failed: %s', [E.Message]), mtError, [mbOK], 0);
  end;
end;

end.
