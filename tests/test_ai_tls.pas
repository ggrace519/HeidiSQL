unit test_ai_tls;

// Certificate and host name verification of ai.http/ai.tls against a local openssl s_server,
// and cancelling an HTTPS request (which used to end the process with SIGPIPE).
// Skipped when the openssl command line tool is missing.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, ai.types, ai.http, aitlsserver;

type
  TAiTlsTest = class(TTestCase)
  private
    FServer: TTlsTestServer;
    function Spec(const Host: String): TAiRequestSpec;
    function RunToEnd(const S: TAiRequestSpec): IAiMailbox;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TrustedWithExtraCa;
    procedure UntrustedCertificateRejected;
    procedure HostNameMismatchRejected;
    procedure UntrustedAllowedOnRequest;
    procedure MissingCaFileReported;
    procedure CancelHttpsKeepsProcessAlive;
  end;

implementation

procedure TAiTlsTest.SetUp;
begin
  if not OpenSslAvailable then
    Ignore('openssl command line tool not installed');
end;

procedure TAiTlsTest.TearDown;
begin
  FreeAndNil(FServer);
end;

function TAiTlsTest.Spec(const Host: String): TAiRequestSpec;
begin
  Result := Default(TAiRequestSpec);
  Result.Method := 'GET';
  Result.Url := 'https://' + Host + ':' + IntToStr(FServer.Port) + '/';
  Result.Mode := rmBuffer;
  Result.ConnectTimeoutMs := 5000;
  Result.IoTimeoutMs := 5000;
end;

function TAiTlsTest.RunToEnd(const S: TAiRequestSpec): IAiMailbox;
var
  Started: QWord;
begin
  Result := NewAiMailbox;
  StartAiRequest(S, Result);
  Started := GetTickCount64;
  while not Result.Finished do begin
    if GetTickCount64 - Started > 10000 then
      Fail('request did not finish');
    Sleep(10);
  end;
  AssertTrue('worker ended', Result.WaitWorkerDone(3000));
end;

procedure TAiTlsTest.TrustedWithExtraCa;
var
  S: TAiRequestSpec;
  M: IAiMailbox;
begin
  FServer := TTlsTestServer.Create(True);
  S := Spec('localhost');
  S.TlsExtraCaFile := TestCaFile;
  M := RunToEnd(S);
  AssertTrue('kind ' + IntToStr(Ord(M.ErrorKind)) + ': ' + M.ErrorMessage, M.ErrorKind = ekNone);
  AssertEquals(200, M.HttpStatus);
end;

procedure TAiTlsTest.UntrustedCertificateRejected;
var
  M: IAiMailbox;
begin
  FServer := TTlsTestServer.Create(True);
  M := RunToEnd(Spec('localhost'));
  AssertTrue(M.ErrorKind = ekConnect);
  AssertTrue(M.ErrorMessage, Pos('Server certificate not accepted', M.ErrorMessage) = 1);
end;

procedure TAiTlsTest.HostNameMismatchRejected;
var
  S: TAiRequestSpec;
  M: IAiMailbox;
begin
  FServer := TTlsTestServer.Create(True);
  // The certificate is for "localhost", not for the IP address
  S := Spec('127.0.0.1');
  S.TlsExtraCaFile := TestCaFile;
  M := RunToEnd(S);
  AssertTrue(M.ErrorKind = ekConnect);
  AssertTrue(M.ErrorMessage, Pos('mismatch', M.ErrorMessage) > 0);
end;

procedure TAiTlsTest.UntrustedAllowedOnRequest;
var
  S: TAiRequestSpec;
  M: IAiMailbox;
begin
  FServer := TTlsTestServer.Create(True);
  S := Spec('127.0.0.1');
  S.TlsAllowUntrusted := True;
  M := RunToEnd(S);
  AssertTrue(M.ErrorMessage, M.ErrorKind = ekNone);
end;

procedure TAiTlsTest.MissingCaFileReported;
var
  S: TAiRequestSpec;
  M: IAiMailbox;
begin
  FServer := TTlsTestServer.Create(True);
  S := Spec('localhost');
  S.TlsExtraCaFile := '/nonexistent/ca.pem';
  M := RunToEnd(S);
  AssertTrue(M.ErrorKind = ekConnect);
  AssertTrue(M.ErrorMessage, Pos('Cannot load the CA file', M.ErrorMessage) = 1);
end;

procedure TAiTlsTest.CancelHttpsKeepsProcessAlive;
var
  S: TAiRequestSpec;
  M: IAiMailbox;
begin
  // Completes the handshake, then never answers: the request waits in SSL_read
  FServer := TTlsTestServer.Create(False);
  S := Spec('localhost');
  S.TlsExtraCaFile := TestCaFile;
  S.IoTimeoutMs := 60000;
  M := NewAiMailbox;
  StartAiRequest(S, M);
  Sleep(700);
  AssertFalse('waiting for an answer, but finished: ' + IntToStr(Ord(M.ErrorKind)) + ' ' + M.ErrorMessage, M.Finished);
  M.Cancel;
  // Before the fix, closing the shut-down TLS connection raised SIGPIPE and ended this process
  AssertTrue('worker ended', M.WaitWorkerDone(3000));
  AssertTrue(M.ErrorKind = ekCancelled);
end;

initialization
  RegisterTest(TAiTlsTest);

end.
