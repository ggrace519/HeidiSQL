unit ai.sessionframe;

// "LLM Settings" tab of the session manager: enables the AI assistant for one session, chooses
// its provider profile and holds the user's notes about the database. Built in code (see
// ai.formrows), so the upstream session manager form file stays untouched.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics,
  ai.profiles, ai.profilechoice, ai.session, ai.formrows;

type
  TAiSessionPanel = class(TPanel)
  private
    FRows: TAiFormRows;
    FProfiles: TAiProfileList;
    FChoices: TAiProfileChoices;   // Parallel to the combo items
    FLoaded: TAiSessionSettings;   // As stored, to detect modifications
    FUpdating: Boolean;
    FOnModified: TNotifyEvent;
    FCheckEnabled: TCheckBox;
    FComboProfile: TComboBox;
    FBtnManage: TButton;
    FLabelProfileState, FLabelSent: TLabel;
    FMemoNotes: TMemo;
    procedure FillProfiles(const SelectId: String);
    function SelectedProfileId: String;
    procedure ControlChanged(Sender: TObject);
    procedure ManageClick(Sender: TObject);
    procedure UpdateState;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Shows the settings of the session at SessionPath
    procedure LoadFrom(const SessionPath: String);
    procedure SaveTo(const SessionPath: String);
    function Current: TAiSessionSettings;
    function Modified: Boolean;
    property OnModified: TNotifyEvent read FOnModified write FOnModified;
  end;

implementation

uses
  apphelpers, main, ai.appprofiles;

constructor TAiSessionPanel.Create(AOwner: TComponent);
var
  Box: TScrollBox;
  Row: TPanel;
begin
  inherited;
  BevelOuter := bvNone;
  Caption := '';
  FProfiles := TAiProfileList.Create;
  Box := TScrollBox.Create(Self);
  Box.Parent := Self;
  Box.Align := alClient;
  Box.BorderStyle := bsNone;
  Box.HorzScrollBar.Visible := False;
  FRows := TAiFormRows.Create(Self, Box);

  FCheckEnabled := TCheckBox.Create(Self);
  FCheckEnabled.Caption := _('Enable AI assistant for this session');
  FRows.AddRow('', FCheckEnabled);
  FComboProfile := TComboBox.Create(Self);
  FComboProfile.Style := csDropDownList;
  Row := FRows.AddRow(_('Provider:'), FComboProfile);
  FBtnManage := FRows.AddButton(Row, _('Manage...'), ManageClick);
  FBtnManage.Align := alRight;
  FBtnManage.Hint := _('Edit AI providers in the preferences');
  FBtnManage.ShowHint := True;
  FLabelProfileState := TLabel.Create(Self);
  FLabelProfileState.Font.Color := clRed;
  FRows.AddMessageRow('', FLabelProfileState);
  FLabelSent := TLabel.Create(Self);
  FLabelSent.Caption := _('Sent to the provider with each request: table and column names, types, keys, '
    + 'comments, approximate row counts, the notes below, and the SQL or question you ask about. '
    + 'No table data.');
  FRows.AddMessageRow(_('Shared data:'), FLabelSent);
  FMemoNotes := TMemo.Create(Self);
  FMemoNotes.ScrollBars := ssAutoVertical;
  FMemoNotes.WordWrap := True;
  FMemoNotes.TextHint := _('What the model cannot see in the schema, e.g. "Amounts are in cents. Soft-deleted rows have deleted_at set."');
  FRows.AddRow(_('Context notes:'), FMemoNotes, FRows.S(140));
  FRows.SizeLabelColumn;

  FCheckEnabled.OnChange := ControlChanged;
  FComboProfile.OnChange := ControlChanged;
  FMemoNotes.OnChange := ControlChanged;
end;

destructor TAiSessionPanel.Destroy;
begin
  FRows.Free;
  FProfiles.Free;
  inherited;
end;

procedure TAiSessionPanel.FillProfiles(const SelectId: String);
var
  Choice: TAiProfileChoice;
  Selected: Integer;
begin
  FChoices := BuildProfileChoices(FProfiles, SelectId, _('Default provider (%s)'),
    _('Default provider (none defined yet)'), _('(removed provider)'), Selected);
  FComboProfile.Items.Clear;
  for Choice in FChoices do
    FComboProfile.Items.Add(Choice.Caption);
  FComboProfile.ItemIndex := Selected;
end;

function TAiSessionPanel.SelectedProfileId: String;
var
  i: Integer;
begin
  i := FComboProfile.ItemIndex;
  if (i >= 0) and (i <= High(FChoices)) then
    Result := FChoices[i].ProfileId
  else
    Result := '';
end;

function TAiSessionPanel.Current: TAiSessionSettings;
begin
  Result.Enabled := FCheckEnabled.Checked;
  Result.ProfileId := SelectedProfileId;
  Result.ContextNotes := FMemoNotes.Text;
end;

function TAiSessionPanel.Modified: Boolean;
begin
  Result := not SameAiSessionSettings(Current, FLoaded);
end;

procedure TAiSessionPanel.UpdateState;
var
  Profile: TAiProfile;
begin
  FComboProfile.Enabled := FCheckEnabled.Checked;
  FMemoNotes.Enabled := FCheckEnabled.Checked;
  FLabelProfileState.Caption := '';
  if not FCheckEnabled.Checked then
    Exit;
  Profile := Default(TAiProfile);
  case FProfiles.Resolve(Current.ProfileId, Profile) of
    pmMissing:
      FLabelProfileState.Caption := _('The provider chosen for this session was removed. Choose another one.');
    pmNone:
      FLabelProfileState.Caption := _('No AI provider is defined yet. Use "Manage..." to add one.');
    else
      if ValidateAiProfile(Profile) <> [] then
        FLabelProfileState.Caption := f_('The provider "%s" is incomplete. Use "Manage..." to fix it.', [Profile.Name]);
  end;
end;

procedure TAiSessionPanel.ControlChanged(Sender: TObject);
begin
  if FUpdating then
    Exit;
  UpdateState;
  if Assigned(FOnModified) then
    FOnModified(Self);
end;

procedure TAiSessionPanel.ManageClick(Sender: TObject);
var
  Keep: String;
begin
  Keep := Current.ProfileId;
  MainForm.actPreferences.Execute;
  // Providers may have been added, renamed or removed
  FUpdating := True;
  try
    LoadAppProfiles(FProfiles);
    FillProfiles(Keep);
  finally
    FUpdating := False;
  end;
  ControlChanged(Sender);
end;

procedure TAiSessionPanel.LoadFrom(const SessionPath: String);
begin
  FLoaded := LoadAiSessionSettings(SessionPath);
  FUpdating := True;
  try
    LoadAppProfiles(FProfiles);
    FCheckEnabled.Checked := FLoaded.Enabled;
    FillProfiles(FLoaded.ProfileId);
    FMemoNotes.Text := FLoaded.ContextNotes;
    // The memo may normalize line endings: compare against what it shows, or every session
    // would count as modified right after loading
    FLoaded.ContextNotes := FMemoNotes.Text;
  finally
    FUpdating := False;
  end;
  UpdateState;
end;

procedure TAiSessionPanel.SaveTo(const SessionPath: String);
begin
  FLoaded := Current;
  SaveAiSessionSettings(SessionPath, FLoaded);
end;

end.
