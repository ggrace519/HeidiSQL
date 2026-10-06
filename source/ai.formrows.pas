unit ai.formrows;

// Builds simple "label: control" forms in code, for the AI Edition's settings pages: rows stacked
// from the top of a scroll box, a label column as wide as the longest caption, and message rows
// that grow with their wrapped text. Building in code keeps the upstream form files untouched.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Forms, Graphics;

type
  TAiFormRows = class
  private
    FOwner: TComponent;
    FHost: TWinControl;
    FNextTop: Integer;
    FLabels: array of TLabel;
  public
    // Owner owns the created controls and should be (or be owned by) a form, for DPI scaling.
    // Host receives the rows, usually a scroll box.
    constructor Create(AOwner: TComponent; AHost: TWinControl);
    // DPI-scaled size, also before the controls have a parent form
    function S(Value: Integer): Integer;
    // A labelled row; Control fills the rest of the row. Height 0 is a standard row height.
    function AddRow(const Caption: String; Control: TControl; Height: Integer = 0): TPanel;
    // A row whose height follows the wrapped text of Message
    function AddMessageRow(const Caption: String; Message: TLabel): TPanel;
    // A row with buttons side by side
    function AddButtonRow(const Caption: String): TPanel;
    function AddButton(Bar: TWinControl; const Caption: String; Handler: TNotifyEvent): TButton;
    // Makes all row labels as wide as the longest caption; call after adding all rows
    procedure SizeLabelColumn;
  end;

implementation

uses
  Math;

constructor TAiFormRows.Create(AOwner: TComponent; AHost: TWinControl);
begin
  inherited Create;
  FOwner := AOwner;
  FHost := AHost;
end;

function TAiFormRows.S(Value: Integer): Integer;
var
  Root: TComponent;
begin
  // Controls are often built before their parent chain reaches a form, where Scale96ToForm
  // would raise "Control has no parent form or frame": scale with the owning form instead
  Root := FOwner;
  while Assigned(Root) and not (Root is TCustomDesignControl) do
    Root := Root.Owner;
  if Root is TCustomDesignControl then
    Result := TCustomDesignControl(Root).Scale96ToForm(Value)
  else
    Result := Round(Value * Screen.PixelsPerInch / 96);
end;

function TAiFormRows.AddRow(const Caption: String; Control: TControl; Height: Integer = 0): TPanel;
var
  Lbl: TLabel;
begin
  Result := TPanel.Create(FOwner);
  Result.Parent := FHost;
  Result.BevelOuter := bvNone;
  Result.Caption := '';
  if Height = 0 then
    Height := S(30);
  // Rows are aligned to the top in the order they are added
  Result.SetBounds(0, FNextTop, FHost.ClientWidth, Height);
  Inc(FNextTop, Height);
  Result.Align := alTop;
  Lbl := TLabel.Create(FOwner);
  Lbl.Parent := Result;
  Lbl.Align := alLeft;
  Lbl.AutoSize := False;
  Lbl.Width := S(150);
  Lbl.Layout := tlCenter;
  Lbl.Caption := Caption;
  Lbl.BorderSpacing.Left := S(6);
  SetLength(FLabels, Length(FLabels) + 1);
  FLabels[High(FLabels)] := Lbl;
  if Assigned(Control) then begin
    Control.Parent := Result;
    Control.Align := alClient;
    Control.BorderSpacing.Around := S(3);
    if Control is TWinControl then
      Lbl.FocusControl := TWinControl(Control);
  end;
end;

function TAiFormRows.AddMessageRow(const Caption: String; Message: TLabel): TPanel;
begin
  Message.WordWrap := True;
  Message.AutoSize := True;
  Result := AddRow(Caption, Message, S(8));
  Result.AutoSize := True;
end;

function TAiFormRows.AddButtonRow(const Caption: String): TPanel;
var
  Bar: TPanel;
begin
  Bar := TPanel.Create(FOwner);
  Bar.BevelOuter := bvNone;
  Bar.Caption := '';
  Bar.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
  Bar.ChildSizing.ControlsPerLine := 8;
  AddRow(Caption, Bar, S(34));
  Result := Bar;
end;

function TAiFormRows.AddButton(Bar: TWinControl; const Caption: String; Handler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(FOwner);
  Result.Parent := Bar;
  Result.Caption := Caption;
  Result.AutoSize := True;
  Result.OnClick := Handler;
  Result.BorderSpacing.Around := S(2);
end;

procedure TAiFormRows.SizeLabelColumn;
var
  Lbl: TLabel;
  Widest: Integer;
  Root: TComponent;
begin
  Widest := S(100);
  Root := FOwner;
  while Assigned(Root) and not (Root is TCustomForm) do
    Root := Root.Owner;
  if Root is TCustomForm then begin
    for Lbl in FLabels do
      Widest := Max(Widest, TCustomForm(Root).Canvas.TextWidth(Lbl.Caption));
  end;
  for Lbl in FLabels do
    Lbl.Width := Widest + S(16);
end;

end.
