unit ai.keyactions;

// Interactive keychain actions for a provider profile's API key: look it up, store it (asking
// for the key in a masked prompt), remove it. Each returns the status text to show; the key itself
// is never returned or displayed.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.profiles;

// Current status of the profile's key. Reads the keychain for keychain profiles.
function CheckKeyStatus(const Profile: TAiProfile): String;
// Asks for the key and stores it in the keychain entry named by the profile
function StoreKeyInteractive(const Profile: TAiProfile): String;
// Asks for confirmation and removes the profile's keychain entry
function RemoveKeyInteractive(const Profile: TAiProfile): String;

implementation

uses
  Controls, Dialogs, Clipbrd, apphelpers, ai.keystore, ai.uitext
  // The platform's keychain backend registers itself when its unit is linked
  {$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}, ai.keystore.libsecret{$ENDIF}
  {$IFDEF WINDOWS}, ai.keystore.windows{$ENDIF}
  {$IFDEF DARWIN}, ai.keystore.macos{$ENDIF};

function CheckKeyStatus(const Profile: TAiProfile): String;
var
  Key, Problem: String;
  KeyResult: TAiKeyResult;
begin
  KeyResult := ResolveApiKey(Profile, Key, Problem);
  Key := '';
  Result := KeyResultText(KeyResult, Profile, Problem);
end;

function StoreKeyInteractive(const Profile: TAiProfile): String;
{$IFNDEF DARWIN}
var
  Key, Problem: String;
{$ENDIF}
begin
  if Profile.KeyName = '' then
    Exit('');
  {$IFDEF DARWIN}
  // Storing through the security tool would expose the key in the process list
  Clipboard.AsText := MacStoreCommand(Profile.KeyName);
  MessageDlg(_('Run this command in Terminal, which then asks for the key. It was copied to the clipboard:')
    + LineEnding + LineEnding + MacStoreCommand(Profile.KeyName), mtInformation, [mbOK], 0);
  {$ELSE}
  Key := '';
  if InputQuery(_('Store key'), f_('API key for "%s":', [Profile.Name]), True, Key)
    and (Trim(Key) <> '') then begin
    if not (Assigned(Keychain) and Keychain.Store(Profile.KeyName, Trim(Key), Problem)) then
      MessageDlg(KeyResultText(krKeychainError, Profile, Problem), mtError, [mbOK], 0);
  end;
  Key := '';
  {$ENDIF}
  Result := CheckKeyStatus(Profile);
end;

function RemoveKeyInteractive(const Profile: TAiProfile): String;
var
  Problem: String;
begin
  if (Profile.KeyName <> '') and Assigned(Keychain)
    and (MessageDlg(f_('Remove the keychain entry "%s"?', [Profile.KeyName]),
      mtConfirmation, [mbYes, mbNo], 0) = mrYes) then begin
    if not Keychain.Remove(Profile.KeyName, Problem) then
      MessageDlg(KeyResultText(krKeychainError, Profile, Problem), mtError, [mbOK], 0);
  end;
  Result := CheckKeyStatus(Profile);
end;

end.
