unit ai.tls;

// TLS socket handler for AI provider connections that verifies the server certificate and host
// name. FPC's OpenSSL handler (3.2.2) checks neither: without this, anyone on the network path
// could read the API key. Trusted certificates come from the operating system (OpenSSL default
// paths, /etc/ssl/cert.pem on macOS, the ROOT store on Windows), plus an optional extra CA file.
// No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ssockets, opensslsockets;

type
  TAiTlsErrorEvent = procedure(const Message: String) of object;

  TAiTlsSocketHandler = class(TOpenSSLSocketHandler)
  private
    FVerify: Boolean;
    FExtraCaFile: String;
    FOnTlsError: TAiTlsErrorEvent;
    FSetupError: String;
    function SetupVerification: Boolean;
  protected
    function InitContext(NeedCertificate: Boolean): Boolean; override;
  public
    function Connect: Boolean; override;
    // Verify certificate chain and host name. Off only for servers with self-signed certificates.
    property Verify: Boolean read FVerify write FVerify;
    // PEM file with additional trusted certificates, e.g. a company CA. Optional.
    property ExtraCaFile: String read FExtraCaFile write FExtraCaFile;
    // Receives the reason when the TLS connection could not be established, before the socket
    // and this handler are freed
    property OnTlsError: TAiTlsErrorEvent read FOnTlsError write FOnTlsError;
  end;

implementation

uses
  {$IFDEF WINDOWS} Windows, {$ENDIF}
  dynlibs, ctypes, openssl, sockets;

const
  SSL_VERIFY_PEER_FLAG = 1;
  X509_V_OK = 0;

type
  TSslGetSslCtx = function(ssl: Pointer): Pointer; cdecl;
  TSslCtxSetDefaultVerifyPaths = function(ctx: Pointer): cint; cdecl;
  TSslCtxLoadVerifyLocations = function(ctx: Pointer; CAfile, CApath: PAnsiChar): cint; cdecl;
  TSslSetVerify = procedure(ssl: Pointer; mode: cint; callback: Pointer); cdecl;
  TSslSet1Host = function(ssl: Pointer; hostname: PAnsiChar): cint; cdecl;
  TSslGet0Param = function(ssl: Pointer): Pointer; cdecl;
  TX509VerifyParamSet1IpAsc = function(param: Pointer; ipasc: PAnsiChar): cint; cdecl;
  TSslGetVerifyResult = function(ssl: Pointer): clong; cdecl;
  TX509VerifyCertErrorString = function(n: clong): PAnsiChar; cdecl;
  TSslCtxGetCertStore = function(ctx: Pointer): Pointer; cdecl;
  TD2iX509 = function(px: Pointer; var data: PByte; len: clong): Pointer; cdecl;
  TX509StoreAddCert = function(store, x509: Pointer): cint; cdecl;
  TX509Free = procedure(x509: Pointer); cdecl;

var
  SslGetSslCtx: TSslGetSslCtx;
  SslCtxSetDefaultVerifyPaths: TSslCtxSetDefaultVerifyPaths;
  SslCtxLoadVerifyLocations: TSslCtxLoadVerifyLocations;
  SslSetVerify: TSslSetVerify;
  SslSet1Host: TSslSet1Host;
  SslGet0Param: TSslGet0Param;
  X509VerifyParamSet1IpAsc: TX509VerifyParamSet1IpAsc;
  SslGetVerifyResult: TSslGetVerifyResult;
  X509VerifyCertErrorString: TX509VerifyCertErrorString;
  SslCtxGetCertStore: TSslCtxGetCertStore;
  D2iX509: TD2iX509;
  X509StoreAddCert: TX509StoreAddCert;
  X509Free: TX509Free;
  FunctionsLoaded: Boolean;

function LoadFunctions: Boolean;
begin
  if not FunctionsLoaded then begin
    // FPC's openssl unit has already loaded libssl and libcrypto for the base handler
    if not IsSSLloaded then
      InitSSLInterface;
    SslGetSslCtx := GetProcedureAddress(SSLLibHandle, 'SSL_get_SSL_CTX');
    SslCtxSetDefaultVerifyPaths := GetProcedureAddress(SSLLibHandle, 'SSL_CTX_set_default_verify_paths');
    SslCtxLoadVerifyLocations := GetProcedureAddress(SSLLibHandle, 'SSL_CTX_load_verify_locations');
    SslSetVerify := GetProcedureAddress(SSLLibHandle, 'SSL_set_verify');
    SslSet1Host := GetProcedureAddress(SSLLibHandle, 'SSL_set1_host');
    SslGet0Param := GetProcedureAddress(SSLLibHandle, 'SSL_get0_param');
    SslGetVerifyResult := GetProcedureAddress(SSLLibHandle, 'SSL_get_verify_result');
    SslCtxGetCertStore := GetProcedureAddress(SSLLibHandle, 'SSL_CTX_get_cert_store');
    X509VerifyParamSet1IpAsc := GetProcedureAddress(SSLUtilHandle, 'X509_VERIFY_PARAM_set1_ip_asc');
    X509VerifyCertErrorString := GetProcedureAddress(SSLUtilHandle, 'X509_verify_cert_error_string');
    D2iX509 := GetProcedureAddress(SSLUtilHandle, 'd2i_X509');
    X509StoreAddCert := GetProcedureAddress(SSLUtilHandle, 'X509_STORE_add_cert');
    X509Free := GetProcedureAddress(SSLUtilHandle, 'X509_free');
    FunctionsLoaded := True;
  end;
  // SSL_set1_host appeared in OpenSSL 1.1.0; without it the host name cannot be checked
  Result := Assigned(SslGetSslCtx) and Assigned(SslCtxSetDefaultVerifyPaths)
    and Assigned(SslCtxLoadVerifyLocations) and Assigned(SslSetVerify) and Assigned(SslSet1Host)
    and Assigned(SslGet0Param) and Assigned(X509VerifyParamSet1IpAsc)
    and Assigned(SslGetVerifyResult) and Assigned(X509VerifyCertErrorString);
end;

function IsIpAddress(const Host: String): Boolean;
var
  c: Char;
begin
  // IPv4 dotted quad or IPv6 (contains a colon)
  if Pos(':', Host) > 0 then
    Exit(True);
  Result := Host <> '';
  for c in Host do begin
    if not (c in ['0'..'9', '.']) then
      Exit(False);
  end;
end;

{$IFDEF WINDOWS}
// OpenSSL builds on Windows have no default certificate store: import the system ROOT store
function LoadWindowsRootStore(Ctx: Pointer): Integer;
type
  TCertOpenSystemStoreW = function(hProv: THandle; szSubsystemProtocol: PWideChar): THandle; stdcall;
  TCertEnumCertificatesInStore = function(hCertStore: THandle; pPrevCertContext: Pointer): Pointer; stdcall;
  TCertCloseStore = function(hCertStore: THandle; dwFlags: DWORD): BOOL; stdcall;
  TCertContext = record
    dwCertEncodingType: DWORD;
    pbCertEncoded: PByte;
    cbCertEncoded: DWORD;
    pCertInfo: Pointer;
    hCertStore: THandle;
  end;
  PCertContext = ^TCertContext;
var
  Crypt32: TLibHandle;
  OpenStore: TCertOpenSystemStoreW;
  EnumCerts: TCertEnumCertificatesInStore;
  CloseStore: TCertCloseStore;
  Store, CertStore: Pointer;
  Cert: PCertContext;
  Data: PByte;
  X509: Pointer;
begin
  Result := 0;
  if not (Assigned(SslCtxGetCertStore) and Assigned(D2iX509) and Assigned(X509StoreAddCert)
    and Assigned(X509Free)) then
    Exit;
  Crypt32 := LoadLibrary('crypt32.dll');
  if Crypt32 = NilHandle then
    Exit;
  try
    OpenStore := GetProcedureAddress(Crypt32, 'CertOpenSystemStoreW');
    EnumCerts := GetProcedureAddress(Crypt32, 'CertEnumCertificatesInStore');
    CloseStore := GetProcedureAddress(Crypt32, 'CertCloseStore');
    if not (Assigned(OpenStore) and Assigned(EnumCerts) and Assigned(CloseStore)) then
      Exit;
    Store := Pointer(OpenStore(0, 'ROOT'));
    if Store = nil then
      Exit;
    CertStore := SslCtxGetCertStore(Ctx);
    Cert := nil;
    repeat
      Cert := EnumCerts(THandle(Store), Cert);
      if Cert = nil then
        Break;
      Data := Cert^.pbCertEncoded;
      X509 := D2iX509(nil, Data, Cert^.cbCertEncoded);
      if X509 <> nil then begin
        // Fails for duplicates, which is harmless
        if X509StoreAddCert(CertStore, X509) = 1 then
          Inc(Result);
        X509Free(X509);
      end;
    until False;
    CloseStore(THandle(Store), 0);
  finally
    UnloadLibrary(Crypt32);
  end;
end;
{$ENDIF}

{ TAiTlsSocketHandler }

function TAiTlsSocketHandler.SetupVerification: Boolean;
var
  SslPtr, Ctx: Pointer;
  Host: AnsiString;
  TrustLoaded: Boolean;
begin
  Result := False;
  if not LoadFunctions then begin
    FSetupError := 'The installed OpenSSL library is too old to verify certificates (1.1.0 or newer is needed).';
    Exit;
  end;
  SslPtr := SSL.SSL;
  Ctx := SslGetSslCtx(SslPtr);
  TrustLoaded := SslCtxSetDefaultVerifyPaths(Ctx) = 1;
  {$IFDEF DARWIN}
  if FileExists('/etc/ssl/cert.pem') then
    TrustLoaded := (SslCtxLoadVerifyLocations(Ctx, '/etc/ssl/cert.pem', nil) = 1) or TrustLoaded;
  {$ENDIF}
  {$IFDEF WINDOWS}
  TrustLoaded := (LoadWindowsRootStore(Ctx) > 0) or TrustLoaded;
  {$ENDIF}
  if FExtraCaFile <> '' then begin
    if SslCtxLoadVerifyLocations(Ctx, PAnsiChar(AnsiString(FExtraCaFile)), nil) <> 1 then begin
      FSetupError := Format('Cannot load the CA file %s.', [FExtraCaFile]);
      Exit;
    end;
    TrustLoaded := True;
  end;
  if not TrustLoaded then begin
    FSetupError := 'No trusted certificates were found on this system.';
    Exit;
  end;
  SslSetVerify(SslPtr, SSL_VERIFY_PEER_FLAG, nil);
  Host := (Socket as TInetSocket).Host;
  if IsIpAddress(Host) then
    Result := X509VerifyParamSet1IpAsc(SslGet0Param(SslPtr), PAnsiChar(Host)) = 1
  else
    Result := SslSet1Host(SslPtr, PAnsiChar(Host)) = 1;
  if not Result then
    FSetupError := Format('Cannot set up host name verification for %s.', [Host]);
end;

function TAiTlsSocketHandler.InitContext(NeedCertificate: Boolean): Boolean;
begin
  Result := inherited InitContext(NeedCertificate);
  if Result and FVerify then
    Result := SetupVerification;
end;

function TAiTlsSocketHandler.Connect: Boolean;
var
  VerifyResult: clong;
  Message: String;
begin
  FSetupError := '';
  Result := inherited Connect;
  if Result or not Assigned(FOnTlsError) then
    Exit;
  if FSetupError <> '' then
    Message := FSetupError
  else begin
    Message := 'TLS handshake failed';
    if FVerify and Assigned(SSL) and Assigned(SslGetVerifyResult) then begin
      VerifyResult := SslGetVerifyResult(SSL.SSL);
      if (VerifyResult <> X509_V_OK) and Assigned(X509VerifyCertErrorString) then
        Message := 'Server certificate not accepted: ' + String(X509VerifyCertErrorString(VerifyResult));
    end;
    if (Message = 'TLS handshake failed') and (SSLLastErrorString <> '') then
      Message := Message + ': ' + SSLLastErrorString.Trim([#0, ' ']);
  end;
  FOnTlsError(Message);
end;

end.
