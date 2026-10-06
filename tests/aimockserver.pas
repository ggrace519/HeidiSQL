unit aimockserver;

// Minimal scripted HTTP server for the ai.http tests: listens on 127.0.0.1 on a free port,
// answers each connection with the scripted response, in chunks with delays, or stays silent.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Sockets, SyncObjs;

type
  TMockResponse = record
    Chunks: array of RawByteString; // Written one after another
    DelayMs: Integer;               // Pause before each chunk
    Silent: Boolean;                // Read the request, then never answer
  end;

  TMockHttpServer = class(TThread)
  private
    FListenSocket: TSocket;
    FClientSocket: TSocket; // Connection being served, -1 if none; shut down by Stop
    FPort: Word;
    FResponse: TMockResponse;
    FLastRequest: RawByteString;
    FLock: TCriticalSection;
    FStopEvent: TEvent;
    function ReadRequest(Client: TSocket): RawByteString;
    function GetLastRequest: RawByteString;
  protected
    procedure Execute; override;
  public
    constructor Create(const Response: TMockResponse);
    destructor Destroy; override;
    procedure Stop;
    property Port: Word read FPort;
    property LastRequest: RawByteString read GetLastRequest;
  end;

// Builds a full HTTP/1.1 response head; the body follows in further chunks
function HttpHead(Status: Integer; const ContentType: String; ContentLength: Integer = -1): RawByteString;
function MockResponse(const Chunks: array of RawByteString; DelayMs: Integer = 0): TMockResponse;
// A port with nothing listening on it
function UnusedPort: Word;

implementation

function HttpHead(Status: Integer; const ContentType: String; ContentLength: Integer = -1): RawByteString;
begin
  Result := 'HTTP/1.1 ' + IntToStr(Status) + ' Status' + #13#10
    + 'Content-Type: ' + ContentType + #13#10
    + 'Connection: close' + #13#10;
  if ContentLength >= 0 then
    Result := Result + 'Content-Length: ' + IntToStr(ContentLength) + #13#10;
  Result := Result + #13#10;
end;

function MockResponse(const Chunks: array of RawByteString; DelayMs: Integer = 0): TMockResponse;
var
  i: Integer;
begin
  Result := Default(TMockResponse);
  SetLength(Result.Chunks, Length(Chunks));
  for i:=0 to High(Chunks) do
    Result.Chunks[i] := Chunks[i];
  Result.DelayMs := DelayMs;
end;

function BindLoopback(out Port: Word): TSocket;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  if fpBind(Result, @Addr, SizeOf(Addr)) <> 0 then begin
    CloseSocket(Result);
    raise Exception.Create('bind failed');
  end;
  Len := SizeOf(Addr);
  fpGetSockName(Result, @Addr, @Len);
  Port := NToHs(Addr.sin_port);
end;

function UnusedPort: Word;
var
  S: TSocket;
begin
  // Bound but never listening: connecting to it is refused
  S := BindLoopback(Result);
  CloseSocket(S);
end;

constructor TMockHttpServer.Create(const Response: TMockResponse);
begin
  FResponse := Response;
  FLock := TCriticalSection.Create;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FClientSocket := -1;
  FListenSocket := BindLoopback(FPort);
  if fpListen(FListenSocket, 5) <> 0 then begin
    CloseSocket(FListenSocket);
    raise Exception.Create('listen failed');
  end;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TMockHttpServer.Destroy;
begin
  Stop;
  WaitFor;
  FStopEvent.Free;
  FLock.Free;
  inherited;
end;

procedure TMockHttpServer.Stop;
begin
  if FStopEvent.WaitFor(0) = wrSignaled then
    Exit;
  FStopEvent.SetEvent;
  Terminate;
  // Wakes a blocked accept, and a read on a connection whose client never sends a request
  fpShutdown(FListenSocket, 2);
  FLock.Enter;
  try
    if FClientSocket >= 0 then
      fpShutdown(FClientSocket, 2);
  finally
    FLock.Leave;
  end;
end;

function TMockHttpServer.GetLastRequest: RawByteString;
begin
  FLock.Enter;
  try
    Result := FLastRequest;
  finally
    FLock.Leave;
  end;
end;

function TMockHttpServer.ReadRequest(Client: TSocket): RawByteString;
var
  Buf: array[0..4095] of AnsiChar;
  n, HeadEnd, BodyLen, p: Integer;
  Head: String;
  Part: RawByteString;
begin
  Result := '';
  repeat
    n := fpRecv(Client, @Buf, SizeOf(Buf), 0);
    if n <= 0 then
      Exit;
    SetString(Part, PAnsiChar(@Buf[0]), n);
    Result := Result + Part;
    HeadEnd := Pos(#13#10#13#10, Result);
  until HeadEnd > 0;
  Head := LowerCase(Copy(Result, 1, HeadEnd));
  BodyLen := 0;
  p := Pos('content-length:', Head);
  if p > 0 then
    BodyLen := StrToIntDef(Trim(Copy(Head, p + 15, Pos(#13, Copy(Head, p, MaxInt)) - 16)), 0);
  while Length(Result) < HeadEnd + 3 + BodyLen do begin
    n := fpRecv(Client, @Buf, SizeOf(Buf), 0);
    if n <= 0 then
      Break;
    SetString(Part, PAnsiChar(@Buf[0]), n);
    Result := Result + Part;
  end;
end;

procedure TMockHttpServer.Execute;
var
  Client: TSocket;
  Request: RawByteString;
  Chunk: RawByteString;
begin
  while not Terminated do begin
    Client := fpAccept(FListenSocket, nil, nil);
    if (Client < 0) or Terminated then begin
      if Client >= 0 then
        CloseSocket(Client);
      Break;
    end;
    FLock.Enter;
    try
      FClientSocket := Client;
    finally
      FLock.Leave;
    end;
    try
      Request := ReadRequest(Client);
      FLock.Enter;
      try
        FLastRequest := Request;
      finally
        FLock.Leave;
      end;
      if FResponse.Silent then
        FStopEvent.WaitFor(INFINITE)
      else begin
        for Chunk in FResponse.Chunks do begin
          if FResponse.DelayMs > 0 then begin
            if FStopEvent.WaitFor(FResponse.DelayMs) = wrSignaled then
              Break;
          end;
          if Length(Chunk) > 0 then
            fpSend(Client, @Chunk[1], Length(Chunk), 0);
        end;
      end;
    finally
      FLock.Enter;
      try
        FClientSocket := -1;
      finally
        FLock.Leave;
      end;
      fpShutdown(Client, 2);
      CloseSocket(Client);
    end;
  end;
  CloseSocket(FListenSocket);
end;

end.
