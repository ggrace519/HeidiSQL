unit ai.prefsframe;

// "AI providers" tab of the preferences dialog: the list of provider profiles, an editor for the
// selected one, key storage in the keychain and a connection test that lists the models.
// Built in code (see ai.formrows), so the upstream preferences form file stays untouched.
// The keychain is only accessed on a user action (Check, Store, Remove, Test): a locked keyring
// may prompt or stall, which must not happen just by opening the preferences.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics, Spin, EditBtn,
  ai.profiles, ai.modelfetch, ai.formrows;

type
  TAiProvidersPanel = class(TPanel)
  private
    FProfiles: TAiProfileList;
    FFetch: TAiModelFetch;
    FRows: TAiFormRows;
    FUpdating: Boolean;
    FModified: Boolean;
    FReadOnlyReason: String;
    FOnModified: TNotifyEvent;
    FList: TListBox;
    FBtnAdd, FBtnRemove, FBtnDefault, FBtnTest, FBtnCheckKey, FBtnStoreKey, FBtnRemoveKey: TButton;
    FEditor: TScrollBox;
    FEditName, FEditUrl, FEditKeyName: TEdit;
    FComboModel: TComboBox;
    FRadioKeySource: TRadioGroup;
    FLabelKeyStatus, FLabelTest, FLabelProblems, FLabelFileState: TLabel;
    FSpinTemperature: TFloatSpinEdit;
    FCheckServerTemperature: TCheckBox;
    FSpinContext, FSpinTimeout: TSpinEdit;
    FCheckUntrusted: TCheckBox;
    FEditCaFile: TFileNameEdit;
    procedure BuildList;
    procedure BuildEditor;
    function SelectedIndex: Integer;
    procedure FillList;
    procedure ShowProfile;
    procedure ClearEditor;
    procedure EditorChanged(Sender: TObject);
    procedure KeySourceClicked(Sender: TObject);
    procedure ListSelectionChange(Sender: TObject; User: Boolean);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure DefaultClick(Sender: TObject);
    procedure TestClick(Sender: TObject);
    procedure CheckKeyClick(Sender: TObject);
    procedure StoreKeyClick(Sender: TObject);
    procedure RemoveKeyClick(Sender: TObject);
    procedure TestDone(Success: Boolean; const Models: TStringArray; const Message: String);
    procedure UpdateKeyControls;
    procedure ShowKeyStatus;
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
  Dialogs, apphelpers, ai.keystore, ai.appprofiles, ai.uitext, ai.keyactions;

const
  DEFAULTMARK = '★ ';
  DEFAULTTEMPERATURE = 0.2;

constructor TAiProvidersPanel.Create(AOwner: TComponent);
begin
  inherited;
  BevelOuter := bvNone;
  Caption := '';
  FProfiles := TAiProfileList.Create;
  FFetch := TAiModelFetch.Create(Self);
  BuildList;
  BuildEditor;
end;

destructor TAiProvidersPanel.Destroy;
begin
  FFetch.Cancel;
  FRows.Free;
  FProfiles.Free;
  inherited;
end;

procedure TAiProvidersPanel.BuildList;
var
  Left, Buttons: TPanel;
  Helper: TAiFormRows;
begin
  Helper := TAiFormRows.Create(Self, Self);
  try
    Left := TPanel.Create(Self);
    Left.Parent := Self;
    Left.BevelOuter := bvNone;
    Left.Caption := '';
    Left.Align := alLeft;
    Left.Width := Helper.S(210);
    Buttons := TPanel.Create(Self);
    Buttons.Parent := Left;
    Buttons.BevelOuter := bvNone;
    Buttons.Caption := '';
    Buttons.Align := alBottom;
    Buttons.AutoSize := True;
    Buttons.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
    Buttons.ChildSizing.ControlsPerLine := 3;
    FBtnAdd := Helper.AddButton(Buttons, _('Add'), AddClick);
    FBtnRemove := Helper.AddButton(Buttons, _('Remove'), RemoveClick);
    FBtnDefault := Helper.AddButton(Buttons, _('Default'), DefaultClick);
    FBtnDefault.Hint := _('Use this profile for sessions that do not choose one');
    FBtnDefault.ShowHint := True;
    FList := TListBox.Create(Self);
    FList.Parent := Left;
    FList.Align := alClient;
    FList.BorderSpacing.Around := Helper.S(3);
    FList.OnSelectionChange := ListSelectionChange;
  finally
    Helper.Free;
  end;
end;

procedure TAiProvidersPanel.BuildEditor;
var
  Row: TPanel;
begin
  FEditor := TScrollBox.Create(Self);
  FEditor.Parent := Self;
  FEditor.Align := alClient;
  FEditor.BorderStyle := bsNone;
  FEditor.HorzScrollBar.Visible := False;
  FRows := TAiFormRows.Create(Self, FEditor);

  FLabelFileState := TLabel.Create(Self);
  FLabelFileState.Font.Style := [fsBold];
  FRows.AddMessageRow('', FLabelFileState);
  FEditName := TEdit.Create(Self);
  FRows.AddRow(_('Name:'), FEditName);
  FEditUrl := TEdit.Create(Self);
  FEditUrl.TextHint := DEFAULTLOCALBASEURL;
  FRows.AddRow(_('Base URL:'), FEditUrl);
  FComboModel := TComboBox.Create(Self);
  FComboModel.Style := csDropDown;
  Row := FRows.AddRow(_('Model:'), FComboModel);
  FBtnTest := FRows.AddButton(Row, _('Test'), TestClick);
  FBtnTest.Align := alRight;
  FBtnTest.Hint := _('Connect to the server and list its models');
  FBtnTest.ShowHint := True;
  FLabelTest := TLabel.Create(Self);
  FRows.AddMessageRow('', FLabelTest);

  FRadioKeySource := TRadioGroup.Create(Self);
  FRadioKeySource.Caption := '';
  FRadioKeySource.Columns := 3;
  FRadioKeySource.Items.Add(_('None'));
  FRadioKeySource.Items.Add(_('Environment variable'));
  FRadioKeySource.Items.Add(_('Keychain entry'));
  FRows.AddRow(_('API key:'), FRadioKeySource, FRows.S(44));
  FEditKeyName := TEdit.Create(Self);
  FRows.AddRow(_('Variable or entry name:'), FEditKeyName);
  Row := FRows.AddButtonRow('');
  FBtnCheckKey := FRows.AddButton(Row, _('Check'), CheckKeyClick);
  FBtnCheckKey.Hint := _('Look the key up in the keychain');
  FBtnCheckKey.ShowHint := True;
  FBtnStoreKey := FRows.AddButton(Row, _('Store key...'), StoreKeyClick);
  FBtnRemoveKey := FRows.AddButton(Row, _('Remove key'), RemoveKeyClick);
  FLabelKeyStatus := TLabel.Create(Self);
  FRows.AddMessageRow(_('Key status:'), FLabelKeyStatus);

  FSpinTemperature := TFloatSpinEdit.Create(Self);
  FSpinTemperature.MinValue := 0;
  FSpinTemperature.MaxValue := 2;
  FSpinTemperature.Increment := 0.1;
  FSpinTemperature.DecimalPlaces := 2;
  Row := FRows.AddRow(_('Temperature:'), FSpinTemperature);
  FCheckServerTemperature := TCheckBox.Create(Self);
  FCheckServerTemperature.Parent := Row;
  FCheckServerTemperature.Caption := _('Server default');
  FCheckServerTemperature.Align := alRight;
  FCheckServerTemperature.BorderSpacing.Around := FRows.S(3);
  FSpinContext := TSpinEdit.Create(Self);
  FSpinContext.MinValue := 1000;
  FSpinContext.MaxValue := 1000000;
  FSpinContext.Increment := 1000;
  FRows.AddRow(_('Schema context (characters):'), FSpinContext);
  FSpinTimeout := TSpinEdit.Create(Self);
  FSpinTimeout.MinValue := 5;
  FSpinTimeout.MaxValue := 3600;
  FRows.AddRow(_('Read timeout (seconds):'), FSpinTimeout);
  FCheckUntrusted := TCheckBox.Create(Self);
  FCheckUntrusted.Caption := _('Accept untrusted HTTPS certificates (self-signed servers only)');
  FRows.AddRow('', FCheckUntrusted);
  FEditCaFile := TFileNameEdit.Create(Self);
  FEditCaFile.Filter := _('Certificates') + ' (*.pem;*.crt)|*.pem;*.crt|' + _('All files') + '|*';
  FRows.AddRow(_('Extra CA file:'), FEditCaFile);
  FLabelProblems := TLabel.Create(Self);
  FLabelProblems.Font.Color := clRed;
  FRows.AddMessageRow('', FLabelProblems);
  FRows.SizeLabelColumn;

  FEditName.OnChange := EditorChanged;
  FEditUrl.OnChange := EditorChanged;
  FComboModel.OnChange := EditorChanged;
  FEditKeyName.OnChange := EditorChanged;
  FRadioKeySource.OnClick := KeySourceClicked;
  FSpinTemperature.OnChange := EditorChanged;
  FCheckServerTemperature.OnChange := EditorChanged;
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
      if Trim(Text) = '' then
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

procedure TAiProvidersPanel.ClearEditor;
begin
  FEditName.Text := '';
  FEditUrl.Text := '';
  FComboModel.Items.Clear;
  FComboModel.Text := '';
  FEditKeyName.Text := '';
  FEditCaFile.Text := '';
  FLabelTest.Caption := '';
  FLabelKeyStatus.Caption := '';
  FLabelProblems.Caption := '';
end;

procedure TAiProvidersPanel.ShowProfile;
var
  i: Integer;
  P: TAiProfile;
begin
  // A Test still running belongs to the previously shown profile
  FFetch.Cancel;
  FBtnTest.Enabled := True;
  i := SelectedIndex;
  FEditor.Enabled := (i >= 0) and (FReadOnlyReason = '');
  FBtnRemove.Enabled := FEditor.Enabled;
  FBtnDefault.Enabled := FEditor.Enabled;
  FBtnAdd.Enabled := FReadOnlyReason = '';
  FUpdating := True;
  try
    if i < 0 then
      ClearEditor
    else begin
      P := FProfiles[i];
      FEditName.Text := P.Name;
      FEditUrl.Text := P.BaseUrl;
      FComboModel.Items.Clear;
      FComboModel.Text := P.Model;
      FRadioKeySource.ItemIndex := Ord(P.KeySource);
      FEditKeyName.Text := P.KeyName;
      FCheckServerTemperature.Checked := P.Temperature < 0;
      if P.Temperature >= 0 then
        FSpinTemperature.Value := P.Temperature
      else
        FSpinTemperature.Value := DEFAULTTEMPERATURE;
      FSpinContext.Value := P.MaxContextChars;
      FSpinTimeout.Value := P.IoTimeoutSec;
      FCheckUntrusted.Checked := P.AllowUntrustedTls;
      FEditCaFile.Text := P.ExtraCaFile;
      FLabelTest.Caption := '';
      FLabelProblems.Caption := ProfileProblemsText(ValidateAiProfile(P));
    end;
  finally
    FUpdating := False;
  end;
  UpdateKeyControls;
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
  // Negative means "server default", which the spin edit cannot show
  if FCheckServerTemperature.Checked then
    P.Temperature := -1
  else
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
  if (Sender = FEditKeyName) or (Sender = FRadioKeySource) or (Sender = FCheckServerTemperature) then
    UpdateKeyControls;
  SetModified;
end;

procedure TAiProvidersPanel.KeySourceClicked(Sender: TObject);
begin
  // TRadioGroup has no OnChange; OnClick also fires when the item is set in code
  if not FUpdating then
    EditorChanged(Sender);
end;

// Enables the key controls. The status is shown right away only for environment variables:
// reading the keychain may prompt or stall, so that waits for a click.
procedure TAiProvidersPanel.UpdateKeyControls;
var
  i: Integer;
  Source: TAiKeySource;
begin
  FSpinTemperature.Enabled := not FCheckServerTemperature.Checked;
  i := SelectedIndex;
  if i < 0 then
    Source := ksNone
  else
    Source := FProfiles[i].KeySource;
  FEditKeyName.Enabled := Source <> ksNone;
  FBtnCheckKey.Enabled := (Source = ksKeychain) and (FEditKeyName.Text <> '');
  FBtnStoreKey.Enabled := FBtnCheckKey.Enabled;
  FBtnRemoveKey.Enabled := FBtnCheckKey.Enabled;
  if (i < 0) or ((Source <> ksNone) and (FProfiles[i].KeyName = '')) then
    FLabelKeyStatus.Caption := ''
  else if Source = ksKeychain then
    FLabelKeyStatus.Caption := f_('Keychain entry "%s", not checked yet.', [FProfiles[i].KeyName])
  else
    ShowKeyStatus;
end;

procedure TAiProvidersPanel.ShowKeyStatus;
begin
  if SelectedIndex >= 0 then
    FLabelKeyStatus.Caption := CheckKeyStatus(FProfiles[SelectedIndex]);
end;

procedure TAiProvidersPanel.ListSelectionChange(Sender: TObject; User: Boolean);
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
  FUpdating := True;
  try
    FillList;
    FList.ItemIndex := FProfiles.Count - 1;
  finally
    FUpdating := False;
  end;
  ShowProfile;
  SetModified;
  FEditName.SetFocus;
  FEditName.SelectAll;
end;

procedure TAiProvidersPanel.RemoveClick(Sender: TObject);
var
  i: Integer;
  Text: String;
begin
  i := SelectedIndex;
  if i < 0 then
    Exit;
  Text := f_('Remove the provider "%s"? Sessions using it will ask for another provider.', [FProfiles[i].Name]);
  if FProfiles[i].KeySource = ksKeychain then
    Text := Text + LineEnding + f_('Its keychain entry "%s" is kept; use "Remove key" first to delete it.', [FProfiles[i].KeyName]);
  if MessageDlg(Text, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  FProfiles.Delete(FProfiles[i].Id);
  FUpdating := True;
  try
    FillList;
  finally
    FUpdating := False;
  end;
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
  FUpdating := True;
  try
    FillList;
  finally
    FUpdating := False;
  end;
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
  Key := '';
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
  if (Current = '') and FComboModel.IsVisible then
    FComboModel.DroppedDown := True;
end;

procedure TAiProvidersPanel.CheckKeyClick(Sender: TObject);
begin
  ShowKeyStatus;
end;

procedure TAiProvidersPanel.StoreKeyClick(Sender: TObject);
begin
  if SelectedIndex >= 0 then
    FLabelKeyStatus.Caption := StoreKeyInteractive(FProfiles[SelectedIndex]);
end;

procedure TAiProvidersPanel.RemoveKeyClick(Sender: TObject);
begin
  if SelectedIndex >= 0 then
    FLabelKeyStatus.Caption := RemoveKeyInteractive(FProfiles[SelectedIndex]);
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
  // A seeded starter profile is new: save it with the next Apply
  FModified := State = plrMissing;
  FUpdating := True;
  try
    FillList;
  finally
    FUpdating := False;
  end;
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
