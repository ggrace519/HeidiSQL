unit ai.keystore;

// Finds the API key of a provider profile: in an environment variable, or in the operating
// system's keychain. Keys are never written to HeidiSQL's settings. Keychain access is plugged
// in by platform units through RegisterKeychain; this unit has no LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.profiles;

type
  TAiKeyResult = (
    krNotNeeded,            // Profile uses no key, e.g. a local server
    krFound,
    krEnvNotSet,            // Environment variable missing or empty
    krKeychainNotFound,     // No keychain entry with that name
    krKeychainUnavailable,  // No keychain support on this system, e.g. no Secret Service
    krKeychainError         // Keychain locked, access refused, ...
  );

  // Platform keychain backend. Service is a fixed application name, Account the entry name.
  IAiKeychain = interface
    ['{6E1B6E52-9C1D-4D7E-9D3B-2B7C4E0F5A11}']
    function Available(out Problem: String): Boolean;
    function Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
    function Store(const Account, Secret: String; out Problem: String): Boolean;
    function Remove(const Account: String; out Problem: String): Boolean;
  end;

  TGetEnvFunc = function(const Name: String): String;

const
  AIKEYCHAINSERVICE = 'heidisql-ai';

// Problem receives technical detail from the keychain backend, if any; the UI words the
// message from the result and the profile's key name. It never contains the key.
function ResolveApiKey(const Profile: TAiProfile; out Key: String; out Problem: String): TAiKeyResult;

// Platform units register their backend in their initialization section
procedure RegisterKeychain(const Keychain: IAiKeychain);
function Keychain: IAiKeychain;

var
  // Replaceable for tests
  GetEnvironmentValue: TGetEnvFunc;

implementation

var
  FKeychain: IAiKeychain;

function DefaultGetEnv(const Name: String): String;
begin
  Result := GetEnvironmentVariable(Name);
end;

procedure RegisterKeychain(const Keychain: IAiKeychain);
begin
  FKeychain := Keychain;
end;

function Keychain: IAiKeychain;
begin
  Result := FKeychain;
end;

function ResolveApiKey(const Profile: TAiProfile; out Key: String; out Problem: String): TAiKeyResult;
var
  Name: String;
begin
  Key := '';
  Problem := '';
  Name := Profile.KeyName.Trim;
  case Profile.KeySource of
    ksNone:
      Result := krNotNeeded;
    ksEnvironment: begin
      Key := GetEnvironmentValue(Name).Trim;
      if (Name <> '') and (Key <> '') then
        Result := krFound
      else
        Result := krEnvNotSet;
    end;
    ksKeychain: begin
      if FKeychain = nil then
        Result := krKeychainUnavailable
      else if not FKeychain.Available(Problem) then
        Result := krKeychainUnavailable
      else begin
        Result := FKeychain.Lookup(Name, Key, Problem);
        if (Result = krFound) and (Key.Trim = '') then
          Result := krKeychainNotFound;
        if Result <> krFound then
          Key := '';
      end;
    end;
    else
      Result := krNotNeeded;
  end;
end;

initialization
  GetEnvironmentValue := DefaultGetEnv;

end.
