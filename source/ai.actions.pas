unit ai.actions;

// Sets up the AI assistant in the main window: the controller with its panel, the actions in
// category "AI", and their menu items in the Query menu and the query editor's context menu.
// Must run in TMainForm.FormCreate before the shortcuts are loaded and the action captions are
// recorded for Preferences > Shortcuts.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, ActnList, Menus, main;

type
  TAiActions = class(TComponent)
  private
    FGenerate: TAction;
    FTogglePanel: TAction;
    procedure GenerateExecute(Sender: TObject);
    procedure GenerateUpdate(Sender: TObject);
    procedure TogglePanelExecute(Sender: TObject);
    procedure TogglePanelUpdate(Sender: TObject);
    function NewAction(Form: TMainForm; const AName, ACaption, AHint: String;
      OnExecute, OnUpdate: TNotifyEvent): TAction;
    procedure AddMenuItems(Menu: TMenuItem);
  public
    constructor Create(Form: TMainForm); reintroduce;
  end;

procedure InitAiAssistant(Form: TMainForm);

implementation

uses
  LCLType, apphelpers, ai.controller;

const
  ACTIONCATEGORY = 'AI';

constructor TAiActions.Create(Form: TMainForm);
begin
  inherited Create(Form);
  FGenerate := NewAction(Form, 'actAiGenerateSql', _('Generate SQL with AI...'),
    _('Describe a query in your own words and let the AI assistant write the SQL'),
    GenerateExecute, GenerateUpdate);
  FGenerate.ShortCut := KeyToShortCut(VK_G, [ssCtrl, ssShift]);
  FTogglePanel := NewAction(Form, 'actAiTogglePanel', _('AI assistant panel'),
    _('Show or hide the AI assistant panel'), TogglePanelExecute, TogglePanelUpdate);
  AddMenuItems(Form.MainMenuQuery);
  AddMenuItems(Form.popupQuery.Items);
end;

function TAiActions.NewAction(Form: TMainForm; const AName, ACaption, AHint: String;
  OnExecute, OnUpdate: TNotifyEvent): TAction;
begin
  Result := TAction.Create(Form);
  Result.Name := AName;
  Result.Caption := ACaption;
  Result.Hint := AHint;
  Result.Category := ACTIONCATEGORY;
  Result.OnExecute := OnExecute;
  Result.OnUpdate := OnUpdate;
  Result.ActionList := Form.ActionList1;
end;

procedure TAiActions.AddMenuItems(Menu: TMenuItem);
var
  Item: TMenuItem;
begin
  Menu.AddSeparator;
  Item := TMenuItem.Create(Menu);
  Item.Action := FGenerate;
  Menu.Add(Item);
  Item := TMenuItem.Create(Menu);
  Item.Action := FTogglePanel;
  Menu.Add(Item);
end;

procedure TAiActions.GenerateExecute(Sender: TObject);
begin
  if Assigned(AiController) then
    AiController.Generate;
end;

procedure TAiActions.GenerateUpdate(Sender: TObject);
begin
  FGenerate.Enabled := Assigned(AiController);
end;

procedure TAiActions.TogglePanelExecute(Sender: TObject);
begin
  if Assigned(AiController) then
    AiController.PanelVisible := not AiController.PanelVisible;
end;

procedure TAiActions.TogglePanelUpdate(Sender: TObject);
begin
  FTogglePanel.Enabled := Assigned(AiController);
  FTogglePanel.Checked := Assigned(AiController) and AiController.PanelVisible;
end;

procedure InitAiAssistant(Form: TMainForm);
begin
  AiController := TAiController.Create(Form, Form.panelTop);
  TAiActions.Create(Form);
end;

end.
