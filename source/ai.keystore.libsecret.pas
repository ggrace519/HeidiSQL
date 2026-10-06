unit ai.keystore.libsecret;

// Keychain backend for Linux and other freedesktop systems: the Secret Service (GNOME Keyring,
// KWallet, KeePassXC) through libsecret, loaded at runtime so HeidiSQL still starts without it.
// Entries are stored with the attributes service=heidisql-ai and account=<key name>.
// Registers itself with ai.keystore. No LCL dependencies.

{$mode delphi}{$H+}

interface

implementation

{$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}

uses
  SysUtils, dynlibs, ctypes, ai.keystore;

{$PACKRECORDS C}

type
  TSecretSchemaAttribute = record
    Name: PAnsiChar;
    AttrType: cint;            // SECRET_SCHEMA_ATTRIBUTE_STRING = 0
  end;

  // Layout of libsecret's SecretSchema, including its private reserved fields
  TSecretSchema = record
    Name: PAnsiChar;
    Flags: cint;               // SECRET_SCHEMA_NONE = 0
    Attributes: array[0..31] of TSecretSchemaAttribute;
    Reserved: cint;
    Reserved1, Reserved2, Reserved3, Reserved4, Reserved5, Reserved6, Reserved7: Pointer;
  end;
  PSecretSchema = ^TSecretSchema;

  TGError = record
    Domain: cuint32;
    Code: cint;
    Message: PAnsiChar;
  end;
  PGError = ^TGError;
  PPGError = ^PGError;

  TGHashFunc = function(key: Pointer): cuint; cdecl;
  TGEqualFunc = function(a, b: Pointer): cint; cdecl;

  TGHashTableNew = function(HashFunc: TGHashFunc; EqualFunc: TGEqualFunc): Pointer; cdecl;
  TGHashTableInsert = function(Table, Key, Value: Pointer): cint; cdecl;
  TGHashTableUnref = procedure(Table: Pointer); cdecl;
  TGErrorFree = procedure(Error: PGError); cdecl;
  TSecretPasswordStorev = function(Schema: PSecretSchema; Attributes: Pointer; Collection,
    Label_, Password: PAnsiChar; Cancellable: Pointer; Error: PPGError): cint; cdecl;
  TSecretPasswordLookupv = function(Schema: PSecretSchema; Attributes: Pointer;
    Cancellable: Pointer; Error: PPGError): PAnsiChar; cdecl;
  TSecretPasswordClearv = function(Schema: PSecretSchema; Attributes: Pointer;
    Cancellable: Pointer; Error: PPGError): cint; cdecl;
  TSecretPasswordFree = procedure(Password: PAnsiChar); cdecl;

  TLibSecretKeychain = class(TInterfacedObject, IAiKeychain)
  private
    FLoaded: Boolean;
    FLoadProblem: String;
    FGlib, FSecret: TLibHandle;
    FHashTableNew: TGHashTableNew;
    FHashTableInsert: TGHashTableInsert;
    FHashTableUnref: TGHashTableUnref;
    FStrHash: TGHashFunc;
    FStrEqual: TGEqualFunc;
    FErrorFree: TGErrorFree;
    FStore: TSecretPasswordStorev;
    FLookup: TSecretPasswordLookupv;
    FClear: TSecretPasswordClearv;
    FPasswordFree: TSecretPasswordFree;
    FSchema: TSecretSchema;
    FService: AnsiString; // Lives as long as this object, as hash tables only borrow it
    procedure Load;
    function Attributes(const Account: AnsiString): Pointer;
    function TakeError(Error: PGError): String;
  public
    constructor Create;
    destructor Destroy; override;
    function Available(out Problem: String): Boolean;
    function Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
    function Store(const Account, Secret: String; out Problem: String): Boolean;
    function Remove(const Account: String; out Problem: String): Boolean;
  end;

const
  SCHEMANAME: PAnsiChar = 'org.heidisql.ai.ApiKey';
  ATTRSERVICE: PAnsiChar = 'service';
  ATTRACCOUNT: PAnsiChar = 'account';

constructor TLibSecretKeychain.Create;
begin
  inherited Create;
  FSchema := Default(TSecretSchema);
  FSchema.Name := SCHEMANAME;
  FSchema.Attributes[0].Name := ATTRSERVICE;
  FSchema.Attributes[1].Name := ATTRACCOUNT;
  FService := AnsiString(AIKEYCHAINSERVICE);
end;

destructor TLibSecretKeychain.Destroy;
begin
  // The libraries stay loaded: GLib cannot be unloaded safely once it has started threads
  inherited;
end;

procedure TLibSecretKeychain.Load;
begin
  if FLoaded or (FLoadProblem <> '') then
    Exit;
  FGlib := LoadLibrary('libglib-2.0.so.0');
  FSecret := LoadLibrary('libsecret-1.so.0');
  if (FGlib = NilHandle) or (FSecret = NilHandle) then begin
    FLoadProblem := 'libsecret is not installed (package libsecret-1-0).';
    Exit;
  end;
  FHashTableNew := GetProcedureAddress(FGlib, 'g_hash_table_new');
  FHashTableInsert := GetProcedureAddress(FGlib, 'g_hash_table_insert');
  FHashTableUnref := GetProcedureAddress(FGlib, 'g_hash_table_unref');
  FStrHash := GetProcedureAddress(FGlib, 'g_str_hash');
  FStrEqual := GetProcedureAddress(FGlib, 'g_str_equal');
  FErrorFree := GetProcedureAddress(FGlib, 'g_error_free');
  FStore := GetProcedureAddress(FSecret, 'secret_password_storev_sync');
  FLookup := GetProcedureAddress(FSecret, 'secret_password_lookupv_sync');
  FClear := GetProcedureAddress(FSecret, 'secret_password_clearv_sync');
  FPasswordFree := GetProcedureAddress(FSecret, 'secret_password_free');
  if not (Assigned(FHashTableNew) and Assigned(FHashTableInsert) and Assigned(FHashTableUnref)
    and Assigned(FStrHash) and Assigned(FStrEqual) and Assigned(FErrorFree) and Assigned(FStore)
    and Assigned(FLookup) and Assigned(FClear) and Assigned(FPasswordFree)) then begin
    FLoadProblem := 'The installed libsecret lacks required functions.';
    Exit;
  end;
  FLoaded := True;
end;

function TLibSecretKeychain.Attributes(const Account: AnsiString): Pointer;
begin
  // Keys and values are borrowed: the strings must live until the table is released
  Result := FHashTableNew(FStrHash, FStrEqual);
  FHashTableInsert(Result, ATTRSERVICE, PAnsiChar(FService));
  FHashTableInsert(Result, ATTRACCOUNT, PAnsiChar(Account));
end;

function TLibSecretKeychain.TakeError(Error: PGError): String;
begin
  Result := '';
  if Error = nil then
    Exit;
  if Error^.Message <> nil then
    Result := String(Error^.Message);
  FErrorFree(Error);
end;

function TLibSecretKeychain.Available(out Problem: String): Boolean;
begin
  Load;
  Problem := FLoadProblem;
  Result := FLoaded;
end;

function TLibSecretKeychain.Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
var
  Acc: AnsiString;
  Table: Pointer;
  Error: PGError;
  Value: PAnsiChar;
begin
  Secret := '';
  Problem := '';
  if not Available(Problem) then
    Exit(krKeychainUnavailable);
  Acc := AnsiString(Account);
  Table := Attributes(Acc);
  Error := nil;
  try
    Value := FLookup(@FSchema, Table, nil, @Error);
  finally
    FHashTableUnref(Table);
  end;
  if Error <> nil then begin
    Problem := TakeError(Error);
    if Value <> nil then
      FPasswordFree(Value);
    Exit(krKeychainError);
  end;
  if Value = nil then
    Exit(krKeychainNotFound);
  Secret := String(Value);
  // Overwrites the memory before freeing it
  FPasswordFree(Value);
  Result := krFound;
end;

function TLibSecretKeychain.Store(const Account, Secret: String; out Problem: String): Boolean;
var
  Acc, Lbl, Sec: AnsiString;
  Table: Pointer;
  Error: PGError;
begin
  Problem := '';
  if not Available(Problem) then
    Exit(False);
  Acc := AnsiString(Account);
  Lbl := AnsiString('HeidiSQL AI Edition: ' + Account);
  Sec := AnsiString(Secret);
  Table := Attributes(Acc);
  Error := nil;
  try
    // nil collection: the default keyring
    Result := FStore(@FSchema, Table, nil, PAnsiChar(Lbl), PAnsiChar(Sec), nil, @Error) <> 0;
  finally
    FHashTableUnref(Table);
    // Best effort: other copies of the key may remain in managed strings
    if Length(Sec) > 0 then
      FillChar(Sec[1], Length(Sec), 0);
  end;
  if Error <> nil then begin
    Problem := TakeError(Error);
    Result := False;
  end;
end;

function TLibSecretKeychain.Remove(const Account: String; out Problem: String): Boolean;
var
  Acc: AnsiString;
  Table: Pointer;
  Error: PGError;
begin
  Problem := '';
  if not Available(Problem) then
    Exit(False);
  Acc := AnsiString(Account);
  Table := Attributes(Acc);
  Error := nil;
  try
    // Returns False when there was nothing to remove, which is fine
    FClear(@FSchema, Table, nil, @Error);
  finally
    FHashTableUnref(Table);
  end;
  Result := Error = nil;
  if not Result then
    Problem := TakeError(Error);
end;

initialization
  RegisterKeychain(TLibSecretKeychain.Create);

{$ENDIF}

end.
