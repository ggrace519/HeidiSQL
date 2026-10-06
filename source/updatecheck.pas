unit updatecheck;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Forms, StdCtrls, Controls, Graphics,
  apphelpers, ExtCtrls, extra_controls, Dialogs,
  Menus, Clipbrd, generic_types, DateUtils, Buttons;

type

  { TfrmUpdateCheck }

  TfrmUpdateCheck = class(TExtForm)
    btnCancel: TButton;
    groupRelease: TGroupBox;
    LinkLabelRelease: TLabel;
    lblStatus: TLabel;
    memoRelease: TMemo;
    popupDownloadRelease: TPopupMenu;
    CopydownloadURL1: TMenuItem;
    btnDonate: TBitBtn;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure LinkLabelReleaseLinkClick(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure CopydownloadURL1Click(Sender: TObject);
  private
    { Private declarations }
    FReleaseUrl: String;
    procedure Status(txt: String);
  public
    { Public declarations }
    procedure ReadCheckFile;
  end;


implementation

uses main, forkupdate;

{$R *.lfm}

{$I const.inc}



{**
  Set defaults
}
procedure TfrmUpdateCheck.FormCreate(Sender: TObject);
begin
  // Should be false by default. Callers can set this to True after Create()
  btnDonate.OnClick := MainForm.DonateClick;
  btnDonate.Visible := MainForm.HasDonated(False) = nbFalse;
  btnDonate.Caption := f_('Donate to the %s project', [APPNAME]);
  Width := AppSettings.ReadInt(asUpdateCheckWindowWidth);
  Height := AppSettings.ReadInt(asUpdateCheckWindowHeight);
  // The form file anchors the status label's right side to the Cancel button, but without akRight,
  // so long status texts ran underneath the button instead of wrapping.
  lblStatus.Anchors := lblStatus.Anchors + [akRight];
end;

{**
  Update status text
}
procedure TfrmUpdateCheck.Status(txt: String);
begin
  lblStatus.Caption := txt;
  lblStatus.Repaint;
end;


{**
  Fetch release list and show result
}
procedure TfrmUpdateCheck.FormShow(Sender: TObject);
begin
  Caption := f_('Check for %s updates', [APPDISPLAYNAME]) + ' ...';
  Screen.Cursor := crHourglass;
  try
    Status(_('Downloading release list')+' ...');
    ReadCheckFile;
    if groupRelease.Enabled then
      Status(_('Updates available.'))
    else
      Status(f_('Your %s is up-to-date (no update available).', [APPDISPLAYNAME]));
  except
    // Do not popup errors, just display them in the status label
    on E:Exception do
      Status(E.Message);
  end;
  Screen.Cursor := crDefault;
  btnCancel.TrySetFocus;
end;


{**
  Read the AI Edition's releases from GitHub, and enable the release group if a newer one exists
}
procedure TfrmUpdateCheck.ReadCheckFile;
var
  Http: THttpDownload;
  ReleasesJson: String;
  Release: TForkRelease;
begin
  // Init GUI controls
  memoRelease.Clear;
  groupRelease.Caption := _('AI Edition release');
  groupRelease.Enabled := False;
  LinkLabelRelease.Enabled := False;
  FReleaseUrl := '';

  Http := THttpDownload.Create(Self);
  try
    Http.TimeOut := 5;
    Http.AddHeader('Accept', 'application/vnd.github+json');
    // Raises EHTTPClient on any status other than 200
    ReleasesJson := Http.Get(FORKRELEASESAPI);
  finally
    Http.Free;
  end;
  // Remember when we did the updatecheck to enable the automatic interval
  AppSettings.WriteString(asUpdatecheckLastrun, DateTimeToStr(Now));

  Release := FindLatestForkRelease(ReleasesJson, FORKRELEASETAGPREFIX);
  if not Release.Found then begin
    memoRelease.Lines.Add(_('No AI Edition release has been published yet.'));
  end else begin
    FReleaseUrl := Release.Url;
    memoRelease.Lines.Add(f_('Version %s (yours: %s)', [Release.Version, AIEDITIONVERSION]));
    memoRelease.Lines.Add(f_('Released: %s', [Copy(Release.PublishedAt, 1, 10)]));
    if Release.Notes <> '' then
      memoRelease.Lines.Add(_('Notes') + ': ' + Release.Notes);
    LinkLabelRelease.Caption := f_('Download version %s', [Release.Version]);
    LinkLabelRelease.Font.Style := LinkLabelRelease.Font.Style + [fsUnderline];
    groupRelease.Enabled := IsNewerVersion(Release.Version, AIEDITIONVERSION);
    LinkLabelRelease.Enabled := groupRelease.Enabled;
  end;

  memoRelease.Enabled := groupRelease.Enabled;
  if not memoRelease.Enabled then
    memoRelease.Font.Color := GetThemeColor(cl3DDkShadow)
  else
    memoRelease.Font.Color := GetThemeColor(clWindowText);
end;


{**
  Open the release page in the web browser
}
procedure TfrmUpdateCheck.LinkLabelReleaseLinkClick(Sender: TObject);
begin
  if FReleaseUrl <> '' then
    ShellExec(FReleaseUrl);
end;


procedure TfrmUpdateCheck.CopydownloadURL1Click(Sender: TObject);
begin
  Clipboard.TryAsText := FReleaseUrl;
end;

procedure TfrmUpdateCheck.FormDestroy(Sender: TObject);
begin
  AppSettings.WriteInt(asUpdateCheckWindowWidth, ScaleFormToDesign(Width));
  AppSettings.WriteInt(asUpdateCheckWindowHeight, ScaleFormToDesign(Height));
end;


end.
