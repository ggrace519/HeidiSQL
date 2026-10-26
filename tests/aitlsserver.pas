unit aitlsserver;

// Local TLS server for the ai.tls tests, using the openssl command line tool: a throwaway CA, a
// certificate for "localhost" signed by it, and "openssl s_server" on a free port.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Process;

type
  TTlsTestServer = class
  private
    FPort: Word;
    FProcess: TProcess;
  public
    // WebMode: answers GET requests with a status page (s_server -www). Otherwise the server
    // completes the TLS handshake and then never answers.
    constructor Create(WebMode: Boolean);
    destructor Destroy; override;
    property Port: Word read FPort;
  end;

// False when the openssl tool is not installed; the TLS tests are skipped then
function OpenSslAvailable: Boolean;
function TestCaFile: String;

implementation

uses
  Sockets, aimockserver;

var
  CertDir: String;

function OpenSslAvailable: Boolean;
var
  Output: String;
begin
  Result := RunCommand('openssl', ['version'], Output, [poStderrToOutPut]);
end;

procedure Run(const Args: array of String);
var
  Output: String;
begin
  if not RunCommand('openssl', Args, Output, [poStderrToOutPut]) then
    raise Exception.Create('openssl failed: ' + Output);
end;

// Creates the CA and server certificate once per test run
procedure EnsureCertificates;
var
  Ext: TStringList;
begin
  if CertDir <> '' then
    Exit;
  CertDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'heidisql-tls-' + IntToStr(GetProcessID) + PathDelim;
  ForceDirectories(CertDir);
  Run(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', CertDir + 'ca.key',
    '-out', CertDir + 'ca.pem', '-days', '1', '-subj', '/CN=HeidiSQL Test CA']);
  Run(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', CertDir + 'server.key',
    '-out', CertDir + 'server.csr', '-subj', '/CN=localhost']);
  Ext := TStringList.Create;
  try
    Ext.Add('subjectAltName=DNS:localhost');
    Ext.SaveToFile(CertDir + 'ext.cnf');
  finally
    Ext.Free;
  end;
  Run(['x509', '-req', '-in', CertDir + 'server.csr', '-CA', CertDir + 'ca.pem',
    '-CAkey', CertDir + 'ca.key', '-CAcreateserial', '-out', CertDir + 'server.pem',
    '-days', '1', '-extfile', CertDir + 'ext.cnf']);
end;

function TestCaFile: String;
begin
  EnsureCertificates;
  Result := CertDir + 'ca.pem';
end;

function PortOpen(Port: Word): Boolean;
var
  S: TSocket;
  Addr: TInetSockAddr;
begin
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(Port);
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  Result := fpConnect(S, @Addr, SizeOf(Addr)) = 0;
  CloseSocket(S);
end;

constructor TTlsTestServer.Create(WebMode: Boolean);
var
  Started: QWord;
begin
  EnsureCertificates;
  FPort := UnusedPort;
  FProcess := TProcess.Create(nil);
  FProcess.Executable := 'openssl';
  FProcess.Parameters.AddStrings(['s_server', '-accept', '127.0.0.1:' + IntToStr(FPort),
    '-cert', CertDir + 'server.pem', '-key', CertDir + 'server.key', '-quiet']);
  if WebMode then
    FProcess.Parameters.Add('-www');
  // s_server relays its stdin to the client and closes the connection at stdin's end: an open
  // pipe keeps the connection silent. Its output (the echoed request) is small enough for the pipe.
  FProcess.Options := [poNoConsole, poUsePipes, poStderrToOutPut];
  FProcess.Execute;
  Started := GetTickCount64;
  // A probe connection is accepted and dropped by s_server, which keeps serving
  while not PortOpen(FPort) do begin
    if GetTickCount64 - Started > 5000 then
      raise Exception.Create('openssl s_server did not start');
    Sleep(50);
  end;
end;

destructor TTlsTestServer.Destroy;
begin
  if Assigned(FProcess) then begin
    FProcess.Terminate(0);
    FProcess.WaitOnExit;
    FProcess.Free;
  end;
  inherited;
end;

procedure RemoveCertificates;
var
  Info: TSearchRec;
begin
  if CertDir = '' then
    Exit;
  if FindFirst(CertDir + '*', faAnyFile, Info) = 0 then begin
    repeat
      if (Info.Name <> '.') and (Info.Name <> '..') then
        DeleteFile(CertDir + Info.Name);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  RemoveDir(CertDir);
end;

finalization
  RemoveCertificates;

end.
