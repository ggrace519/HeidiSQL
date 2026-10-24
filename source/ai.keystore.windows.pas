unit ai.keystore.windows;

// Keychain backend for Windows: the Credential Manager (generic credentials named
// "heidisql-ai:<key name>", stored for the current user). Registers itself with ai.keystore.
// No LCL dependencies.

{$mode delphi}{$H+}

interface

implementation

{$IFDEF WINDOWS}

uses
  SysUtils, dynlibs, ai.keystore;

{$PACKRECORDS C}

const
  CRED_TYPE_GENERIC = 1;
  CRED_PERSIST_LOCAL_MACHINE = 2; // Survives logoff, not roamed to other machines
  ERROR_NOT_FOUND = 1168;

type
  TFileTime = record
    Low, High: Cardinal;
  end;

  TCredentialW = record
    Flags: Cardinal;
    CredType: Cardinal;
    TargetName: PWideChar;
    Comment: PWideChar;
    LastWritten: TFileTime;
    CredentialBlobSize: Cardinal;
    CredentialBlob: PByte;
    Persist: Cardinal;
    AttributeCount: Cardinal;
    Attributes: Pointer;
    TargetAlias: PWideChar;
    UserName: PWideChar;
  end;
  PCredentialW = ^TCredentialW;

  TCredWriteW = function(Credential: PCredentialW; Flags: Cardinal): LongBool; stdcall;
  TCredReadW = function(TargetName: PWideChar; CredType, Flags: Cardinal; out Credential: PCredentialW): LongBool; stdcall;
  TCredDeleteW = function(TargetName: PWideChar; CredType, Flags: Cardinal): LongBool; stdcall;
  TCredFree = procedure(Buffer: Pointer); stdcall;
  TGetLastError = function: Cardinal; stdcall;

  TWindowsKeychain = class(TInterfacedObject, IAiKeychain)
  private
    FLoaded: Boolean;
    FLoadProblem: String;
    FCredWrite: TCredWriteW;
    FCredRead: TCredReadW;
    FCredDelete: TCredDeleteW;
    FCredFree: TCredFree;
    FGetLastError: TGetLastError;
    procedure Load;
    function Target(const Account: String): UnicodeString;
    function LastErrorText: String;
  public
    function Available(out Problem: String): Boolean;
    function Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
    function Store(const Account, Secret: String; out Problem: String): Boolean;
    function Remove(const Account: String; out Problem: String): Boolean;
  end;

procedure TWindowsKeychain.Load;
var
  Advapi, Kernel: TLibHandle;
begin
  if FLoaded or (FLoadProblem <> '') then
    Exit;
  Advapi := LoadLibrary('advapi32.dll');
  Kernel := LoadLibrary('kernel32.dll');
  FCredWrite := GetProcedureAddress(Advapi, 'CredWriteW');
  FCredRead := GetProcedureAddress(Advapi, 'CredReadW');
  FCredDelete := GetProcedureAddress(Advapi, 'CredDeleteW');
  FCredFree := GetProcedureAddress(Advapi, 'CredFree');
  FGetLastError := GetProcedureAddress(Kernel, 'GetLastError');
  if not (Assigned(FCredWrite) and Assigned(FCredRead) and Assigned(FCredDelete)
    and Assigned(FCredFree) and Assigned(FGetLastError)) then begin
    FLoadProblem := 'The Windows Credential Manager functions are not available.';
    Exit;
  end;
  FLoaded := True;
end;

function TWindowsKeychain.Target(const Account: String): UnicodeString;
begin
  Result := UnicodeString(AIKEYCHAINSERVICE + ':' + Account);
end;

function TWindowsKeychain.LastErrorText: String;
var
  Code: Cardinal;
begin
  Code := FGetLastError();
  Result := Format('Windows error %d: %s', [Code, SysErrorMessage(Code)]);
end;

function TWindowsKeychain.Available(out Problem: String): Boolean;
begin
  Load;
  Problem := FLoadProblem;
  Result := FLoaded;
end;

// UTF-16LE text of an ASCII key: even length and every second byte zero
function LooksLikeUtf16(const Bytes: RawByteString): Boolean;
var
  i: Integer;
begin
  Result := (Length(Bytes) >= 2) and (Length(Bytes) mod 2 = 0);
  i := 2;
  while Result and (i <= Length(Bytes)) do begin
    Result := Bytes[i] = #0;
    Inc(i, 2);
  end;
end;

function TWindowsKeychain.Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
var
  Name: UnicodeString;
  Cred: PCredentialW;
  Bytes: RawByteString;
  Wide: UnicodeString;
begin
  Secret := '';
  Problem := '';
  if not Available(Problem) then
    Exit(krKeychainUnavailable);
  Name := Target(Account);
  Cred := nil;
  if not FCredRead(PWideChar(Name), CRED_TYPE_GENERIC, 0, Cred) then begin
    if FGetLastError() = ERROR_NOT_FOUND then
      Exit(krKeychainNotFound);
    Problem := LastErrorText;
    Exit(krKeychainError);
  end;
  try
    SetLength(Bytes, Cred^.CredentialBlobSize);
    if Cred^.CredentialBlobSize > 0 then
      Move(Cred^.CredentialBlob^, Bytes[1], Cred^.CredentialBlobSize);
    if LooksLikeUtf16(Bytes) then begin
      // Written by another tool, e.g. cmdkey or the Credential Manager window
      SetLength(Wide, Length(Bytes) div 2);
      Move(Bytes[1], Wide[1], Length(Bytes));
      Secret := String(Wide);
      if Length(Wide) > 0 then
        FillChar(Wide[1], Length(Wide) * SizeOf(WideChar), 0);
    end else begin
      // Stored as UTF-8 by Store
      SetCodePage(Bytes, CP_UTF8, False);
      Secret := String(Bytes);
    end;
    if Length(Bytes) > 0 then
      FillChar(Bytes[1], Length(Bytes), 0);
  finally
    FCredFree(Cred);
  end;
  Result := krFound;
end;

function TWindowsKeychain.Store(const Account, Secret: String; out Problem: String): Boolean;
var
  Name, Comment: UnicodeString;
  Cred: TCredentialW;
  Bytes: RawByteString;
begin
  Problem := '';
  if not Available(Problem) then
    Exit(False);
  Name := Target(Account);
  Comment := 'HeidiSQL AI Edition API key';
  Bytes := UTF8Encode(Secret);
  Cred := Default(TCredentialW);
  Cred.CredType := CRED_TYPE_GENERIC;
  Cred.TargetName := PWideChar(Name);
  Cred.Comment := PWideChar(Comment);
  Cred.CredentialBlobSize := Length(Bytes);
  if Length(Bytes) > 0 then
    Cred.CredentialBlob := @Bytes[1];
  Cred.Persist := CRED_PERSIST_LOCAL_MACHINE;
  Result := FCredWrite(@Cred, 0);
  if not Result then
    Problem := LastErrorText;
  // Best effort: other copies of the key may remain in managed strings
  if Length(Bytes) > 0 then
    FillChar(Bytes[1], Length(Bytes), 0);
end;

function TWindowsKeychain.Remove(const Account: String; out Problem: String): Boolean;
var
  Name: UnicodeString;
begin
  Problem := '';
  if not Available(Problem) then
    Exit(False);
  Name := Target(Account);
  Result := FCredDelete(PWideChar(Name), CRED_TYPE_GENERIC, 0) or (FGetLastError() = ERROR_NOT_FOUND);
  if not Result then
    Problem := LastErrorText;
end;

initialization
  RegisterKeychain(TWindowsKeychain.Create);

{$ENDIF}

end.
