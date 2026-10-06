unit forksettings;

// One-time offer to copy a stock HeidiSQL's settings into the AI Edition's own settings folder.

{$mode delphi}{$H+}

interface

// True when this fork has no settings file yet, but a stock HeidiSQL on this machine has one.
// Must be called before AppSettings is created, as that creates the fork's settings file.
// Portable mode is checked later in OfferStockSettingsCopy.
function StockSettingsCopyPending: Boolean;

// Ask the user whether to copy the stock settings. On yes, AppSettings is freed, the files are
// copied and AppSettings is recreated from the copy. Returns True when settings were copied.
// Requires Application.Initialize to have run, as it shows a dialog.
function OfferStockSettingsCopy: Boolean;

implementation

uses
  SysUtils, Classes, Controls, Dialogs, FileUtil, apphelpers, forkpaths;

const
  SETTINGSFILE = 'settings.json';
  // Folders with user content, also referenced by absolute paths inside settings.json
  COPYFOLDERS: array[0..1] of String = ('Snippets', 'Highlighters');

function StockSettingsCopyPending: Boolean;
begin
  Result := (not FileExists(ForkConfigDir + SETTINGSFILE))
    and FileExists(StockConfigDir + SETTINGSFILE);
end;

procedure CopyStockSettings(const StockDir, ForkDir: String);
var
  Json: TStringList;
  Folder: String;
begin
  for Folder in COPYFOLDERS do begin
    if DirectoryExists(StockDir + Folder) then
      CopyDirTree(StockDir + Folder, ForkDir + Folder, [cffOverwriteFile, cffCreateDestDirectory]);
  end;
  Json := TStringList.Create;
  try
    Json.LoadFromFile(StockDir + SETTINGSFILE);
    Json.Text := RewriteConfigDirPaths(Json.Text, StockDir, ForkDir);
    Json.SaveToFile(ForkDir + SETTINGSFILE);
  finally
    Json.Free;
  end;
end;

function OfferStockSettingsCopy: Boolean;
var
  StockDir, ForkDir: String;
begin
  Result := False;
  // Portable mode keeps its settings next to the executable, unrelated to any installation
  if AppSettings.PortableMode then
    Exit;
  StockDir := StockConfigDir;
  ForkDir := ForkConfigDir;
  if MessageDlg(
    _('Copy settings from HeidiSQL?'),
    f_('This is the first start of %s. A standard HeidiSQL installation was found on this computer, with settings in:', [APPDISPLAYNAME])
      + sLineBreak + StockDir + sLineBreak + sLineBreak
      + _('Copy its sessions, preferences and snippets into this edition? The original settings are not changed.'),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;

  // Release the settings file of the first start, so the copy can replace it
  FreeAndNil(AppSettings);
  try
    try
      CopyStockSettings(StockDir, ForkDir);
      Result := True;
    except
      on E:Exception do
        MessageDlg(f_('Copying settings failed: %s', [E.Message]), mtError, [mbOK], 0);
    end;
  finally
    AppSettings := TAppSettings.Create;
  end;
end;

end.
