unit ai.keystore.macos;

// Keychain backend for macOS, through the "security" command line tool: generic passwords with
// service "heidisql-ai" and the key name as account. Reading works in-app. Storing is left to
// the user in Terminal, where "security add-generic-password ... -w" prompts for the key:
// passing it as an argument would expose it in the process list. Registers itself with
// ai.keystore. No LCL dependencies.

{$mode delphi}{$H+}

interface

// The Terminal command that stores a key for Account; the UI shows it for copying
function MacStoreCommand(const Account: String): String;

implementation

uses
  SysUtils, ai.keystore
  {$IFDEF DARWIN}, Classes, Process{$ENDIF};

const
  SECURITYTOOL = '/usr/bin/security';
  NOTFOUNDEXIT = 44; // errSecItemNotFound, as exit status of security

function ShellQuote(const S: String): String;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function MacStoreCommand(const Account: String): String;
begin
  Result := 'security add-generic-password -U -s ' + AIKEYCHAINSERVICE + ' -a ' + ShellQuote(Account) + ' -w';
end;

{$IFDEF DARWIN}

type
  TMacKeychain = class(TInterfacedObject, IAiKeychain)
  private
    function Run(const Args: array of String; out Output: String): Integer;
  public
    function Available(out Problem: String): Boolean;
    function Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
    function Store(const Account, Secret: String; out Problem: String): Boolean;
    function Remove(const Account: String; out Problem: String): Boolean;
  end;

function TMacKeychain.Run(const Args: array of String; out Output: String): Integer;
var
  Proc: TProcess;
  Arg: String;
  Buffer: TStringStream;
begin
  Proc := TProcess.Create(nil);
  Buffer := TStringStream.Create('');
  try
    Proc.Executable := SECURITYTOOL;
    for Arg in Args do
      Proc.Parameters.Add(Arg);
    // stderr merged into stdout, and read until the process ends, so no pipe can fill up
    Proc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    Proc.Execute;
    repeat
      if Proc.Output.NumBytesAvailable > 0 then
        Buffer.CopyFrom(Proc.Output, Proc.Output.NumBytesAvailable)
      else
        Sleep(5);
    until (not Proc.Running) and (Proc.Output.NumBytesAvailable = 0);
    Output := Buffer.DataString;
    Result := Proc.ExitStatus;
  finally
    Buffer.Free;
    Proc.Free;
  end;
end;

function TMacKeychain.Available(out Problem: String): Boolean;
begin
  Result := FileExists(SECURITYTOOL);
  if Result then
    Problem := ''
  else
    Problem := SECURITYTOOL + ' not found.';
end;

function TMacKeychain.Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
var
  Output: String;
  Status: Integer;
begin
  Secret := '';
  Problem := '';
  if not Available(Problem) then
    Exit(krKeychainUnavailable);
  Status := Run(['find-generic-password', '-s', AIKEYCHAINSERVICE, '-a', Account, '-w'], Output);
  if Status = NOTFOUNDEXIT then
    Exit(krKeychainNotFound);
  if Status <> 0 then begin
    Problem := Format('security exited with status %d', [Status]);
    Exit(krKeychainError);
  end;
  // The password is printed followed by a line break
  Secret := Output.TrimRight([#10, #13]);
  Result := krFound;
end;

function TMacKeychain.Store(const Account, Secret: String; out Problem: String): Boolean;
begin
  // Not done in-app, see the unit comment; the UI offers MacStoreCommand instead
  Problem := 'Run in Terminal: ' + MacStoreCommand(Account);
  Result := False;
end;

function TMacKeychain.Remove(const Account: String; out Problem: String): Boolean;
var
  Output: String;
  Status: Integer;
begin
  Problem := '';
  if not Available(Problem) then
    Exit(False);
  Status := Run(['delete-generic-password', '-s', AIKEYCHAINSERVICE, '-a', Account], Output);
  Result := (Status = 0) or (Status = NOTFOUNDEXIT);
  if not Result then
    Problem := Format('security exited with status %d', [Status]);
end;

initialization
  RegisterKeychain(TMacKeychain.Create);

{$ENDIF}

end.
