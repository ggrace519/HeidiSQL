unit ai.modelfetch;

// Fetches the model list of a provider profile in the background, for the "Test" button of the
// provider settings. The request runs on an ai.http worker; a timer on the main thread watches
// the mailbox and reports the outcome once.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, ExtCtrls, ai.types, ai.profiles, ai.http;

type
  TAiModelFetchDone = procedure(Success: Boolean; const Models: TStringArray;
    const Message: String) of object;

  TAiModelFetch = class(TComponent)
  private
    FTimer: TTimer;
    FMailbox: IAiMailbox;
    FProfile: TAiProfile;
    FOnDone: TAiModelFetchDone;
    procedure TimerTick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Key may be empty. Cancels a fetch that is still running.
    procedure Start(const Profile: TAiProfile; const Key: String; OnDone: TAiModelFetchDone);
    procedure Cancel;
    function Running: Boolean;
  end;

implementation

uses
  apphelpers, ai.openai, ai.requestbuild, ai.uitext;

constructor TAiModelFetch.Create(AOwner: TComponent);
begin
  inherited;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 100;
  FTimer.OnTimer := TimerTick;
end;

destructor TAiModelFetch.Destroy;
begin
  Cancel;
  inherited;
end;

procedure TAiModelFetch.Start(const Profile: TAiProfile; const Key: String; OnDone: TAiModelFetchDone);
begin
  Cancel;
  FProfile := Profile;
  FOnDone := OnDone;
  FMailbox := NewAiMailbox;
  StartAiRequest(ModelsRequestSpec(Profile, Key), FMailbox);
  FTimer.Enabled := True;
end;

procedure TAiModelFetch.Cancel;
begin
  FTimer.Enabled := False;
  if Assigned(FMailbox) then
    FMailbox.Cancel;
  FMailbox := nil;
  FOnDone := nil;
end;

function TAiModelFetch.Running: Boolean;
begin
  Result := Assigned(FMailbox);
end;

procedure TAiModelFetch.TimerTick(Sender: TObject);
var
  Mailbox: IAiMailbox;
  Done: TAiModelFetchDone;
  Models: TStringArray;
begin
  if (not Assigned(FMailbox)) or (not FMailbox.Finished) then
    Exit;
  FTimer.Enabled := False;
  Mailbox := FMailbox;
  Done := FOnDone;
  FMailbox := nil;
  FOnDone := nil;
  if not Assigned(Done) then
    Exit;
  if Mailbox.ErrorKind <> ekNone then
    Done(False, nil, RequestErrorText(Mailbox.ErrorKind, Mailbox.HttpStatus, Mailbox.ErrorMessage, FProfile))
  else begin
    Models := DecodeModelList(Mailbox.Body);
    if Length(Models) = 0 then
      Done(False, nil, _('Connected, but the server listed no models.'))
    else
      Done(True, Models, f_('Connected: %d models available.', [Length(Models)]));
  end;
end;

end.
