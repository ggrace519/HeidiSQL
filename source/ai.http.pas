unit ai.http;

// Runs one HTTP request to an LLM server on a background thread and hands the results to the
// main thread through a mailbox, which the main thread drains with a timer. The worker only
// touches its immutable request spec and the mailbox, never the UI or a database connection.
//
// Cancel shuts the socket down, which wakes a read that is blocked in recv, so it does not wait
// for the read timeout. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ai.types;

type
  TAiResponseMode = (
    rmChatStream,  // Chat completion: SSE deltas, or a complete JSON answer if the server sends one
    rmBuffer       // Keep the whole body, e.g. GET /models
  );

  // Everything the worker needs, as plain values. Headers may contain the API key: it lives only
  // in memory and is never logged or put into error messages.
  TAiRequestSpec = record
    Method: String;        // 'POST' or 'GET'
    Url: String;
    Body: String;
    Headers: TStringArray; // 'Name: value'
    Mode: TAiResponseMode;
    ConnectTimeoutMs: Integer;
    IoTimeoutMs: Integer;
  end;

  TAiAbortProc = procedure of object;

  // Thread-safe hand-over between the worker (producer) and the main thread (consumer)
  IAiMailbox = interface
    ['{0B9A1A43-3C0F-4E9F-8C1D-6F2C3E5A7B21}']
    // Worker side
    procedure PushContent(const Text: String);
    procedure PushReasoning(const Text: String);
    procedure SetUsage(const Usage: TAiUsage);
    procedure SetBody(const Body: String);
    procedure Finish(Kind: TAiErrorKind; HttpStatus: Integer; const Message: String);
    procedure AttachAbort(Proc: TAiAbortProc);
    procedure DetachAbort;
    function Cancelled: Boolean;
    // Main thread side
    // Takes the text received since the last call. Returns True if anything was new.
    function Drain(out Content, Reasoning: String): Boolean;
    function Finished: Boolean;
    function ErrorKind: TAiErrorKind;
    function HttpStatus: Integer;
    function ErrorMessage: String;
    function Usage: TAiUsage;
    function Body: String;
    // Stops the request: marks it cancelled and shuts the connection down
    procedure Cancel;
    // Waits until the worker thread has finished, at most TimeoutMs. True if it has.
    function WaitWorkerDone(TimeoutMs: Cardinal): Boolean;
    procedure WorkerDone;
  end;

function NewAiMailbox: IAiMailbox;

// Starts a worker thread for Spec. The thread frees itself; Mailbox keeps the results.
procedure StartAiRequest(const Spec: TAiRequestSpec; const Mailbox: IAiMailbox);

implementation

uses
  {$IFDEF UNIX} BaseUnix, {$ENDIF}
  fphttpclient, opensslsockets, ssockets, sockets, ai.sse, ai.openai;

const
  MAXBUFFEREDBODY = 4 * 1024 * 1024;
  SHUTDOWN_BOTH = 2; // SHUT_RDWR / SD_BOTH

type
  TAiMailbox = class(TInterfacedObject, IAiMailbox)
  private
    FLock: TCriticalSection;
    FDoneEvent: TEvent;
    FContent, FReasoning, FBody, FErrorMessage: String;
    FUsage: TAiUsage;
    FFinished, FCancelled: Boolean;
    FErrorKind: TAiErrorKind;
    FHttpStatus: Integer;
    FAbort: TAiAbortProc;
  public
    constructor Create;
    destructor Destroy; override;
    procedure PushContent(const Text: String);
    procedure PushReasoning(const Text: String);
    procedure SetUsage(const Usage: TAiUsage);
    procedure SetBody(const Body: String);
    procedure Finish(Kind: TAiErrorKind; HttpStatus: Integer; const Message: String);
    procedure AttachAbort(Proc: TAiAbortProc);
    procedure DetachAbort;
    function Cancelled: Boolean;
    function Drain(out Content, Reasoning: String): Boolean;
    function Finished: Boolean;
    function ErrorKind: TAiErrorKind;
    function HttpStatus: Integer;
    function ErrorMessage: String;
    function Usage: TAiUsage;
    function Body: String;
    procedure Cancel;
    function WaitWorkerDone(TimeoutMs: Cardinal): Boolean;
    procedure WorkerDone;
  end;

  // HTTP client that remembers its socket handler, so another thread can shut the socket down
  TAiHttpClient = class(TFPHTTPClient)
  private
    FHandlerLock: TCriticalSection;
    FHandler: TSocketHandler;
    procedure ShutdownSocket;
  protected
    function GetSocketHandler(const UseSSL: Boolean): TSocketHandler; override;
    procedure ConnectToServer(const AHost: String; APort: Integer; UseSSL: Boolean = False); override;
    procedure DisconnectFromServer; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Abort;
  end;

  TAiStreamWorker = class;

  // Receives the response body as it arrives and routes it by response type
  TAiResponseSink = class(TStream)
  private
    FWorker: TAiStreamWorker;
  public
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TAiStreamWorker = class(TThread)
  private
    FSpec: TAiRequestSpec;
    FMailbox: IAiMailbox;
    FClient: TAiHttpClient;
    FParser: TSseParser;
    FDecided: Boolean;       // Response mode chosen, on the first body bytes
    FStreaming: Boolean;     // Response is text/event-stream with status 2xx
    FBuffer: String;         // Body of non-streamed responses
    FLastDataTick: QWord;
    FSawDone, FSawFinish: Boolean;
    FStreamError: String;
    procedure HeadersReceived(Sender: TObject);
    procedure SseEvent(const EventName, Data: String);
    procedure DataReceived(const Buffer; Count: Integer);
    procedure FinishResponse;
    function ClassifyException(E: Exception): TAiErrorKind;
  protected
    procedure Execute; override;
  public
    constructor Create(const Spec: TAiRequestSpec; const Mailbox: IAiMailbox);
  end;

{ TAiMailbox }

constructor TAiMailbox.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDoneEvent := TEvent.Create(nil, True, False, '');
end;

destructor TAiMailbox.Destroy;
begin
  FDoneEvent.Free;
  FLock.Free;
  inherited;
end;

procedure TAiMailbox.PushContent(const Text: String);
begin
  FLock.Enter;
  try
    FContent := FContent + Text;
  finally
    FLock.Leave;
  end;
end;

procedure TAiMailbox.PushReasoning(const Text: String);
begin
  FLock.Enter;
  try
    FReasoning := FReasoning + Text;
  finally
    FLock.Leave;
  end;
end;

procedure TAiMailbox.SetUsage(const Usage: TAiUsage);
begin
  FLock.Enter;
  try
    FUsage := Usage;
  finally
    FLock.Leave;
  end;
end;

procedure TAiMailbox.SetBody(const Body: String);
begin
  FLock.Enter;
  try
    FBody := Body;
  finally
    FLock.Leave;
  end;
end;

procedure TAiMailbox.Finish(Kind: TAiErrorKind; HttpStatus: Integer; const Message: String);
begin
  FLock.Enter;
  try
    if FFinished then
      Exit;
    // A cancelled request always ends as cancelled, whatever error the shutdown caused
    if FCancelled then
      FErrorKind := ekCancelled
    else
      FErrorKind := Kind;
    FHttpStatus := HttpStatus;
    FErrorMessage := Message;
    FFinished := True;
  finally
    FLock.Leave;
  end;
end;

procedure TAiMailbox.AttachAbort(Proc: TAiAbortProc);
var
  AbortNow: Boolean;
begin
  FLock.Enter;
  try
    FAbort := Proc;
    AbortNow := FCancelled;
  finally
    FLock.Leave;
  end;
  if AbortNow then
    Proc;
end;

procedure TAiMailbox.DetachAbort;
begin
  FLock.Enter;
  try
    FAbort := nil;
  finally
    FLock.Leave;
  end;
end;

function TAiMailbox.Cancelled: Boolean;
begin
  FLock.Enter;
  try
    Result := FCancelled;
  finally
    FLock.Leave;
  end;
end;

function TAiMailbox.Drain(out Content, Reasoning: String): Boolean;
begin
  FLock.Enter;
  try
    Content := FContent;
    Reasoning := FReasoning;
    FContent := '';
    FReasoning := '';
  finally
    FLock.Leave;
  end;
  Result := (Content <> '') or (Reasoning <> '');
end;

function TAiMailbox.Finished: Boolean;
begin
  FLock.Enter;
  try
    Result := FFinished;
  finally
    FLock.Leave;
  end;
end;

function TAiMailbox.ErrorKind: TAiErrorKind;
begin
  FLock.Enter;
  try
    Result := FErrorKind;
  finally
    FLock.Leave;
  end;
end;

function TAiMailbox.HttpStatus: Integer;
begin
  FLock.Enter;
  try
    Result := FHttpStatus;
  finally
    FLock.Leave;
  end;
end;

function TAiMailbox.ErrorMessage: String;
begin
  FLock.Enter;
  try
    Result := FErrorMessage;
  finally
    FLock.Leave;
  end;
end;

function TAiMailbox.Usage: TAiUsage;
begin
  FLock.Enter;
  try
    Result := FUsage;
  finally
    FLock.Leave;
  end;
end;

function TAiMailbox.Body: String;
begin
  FLock.Enter;
  try
    Result := FBody;
  finally
    FLock.Leave;
  end;
end;

procedure TAiMailbox.Cancel;
var
  Abort: TAiAbortProc;
begin
  FLock.Enter;
  try
    FCancelled := True;
    Abort := FAbort;
  finally
    FLock.Leave;
  end;
  // Called outside the mailbox lock; the client guards its socket with its own lock
  if Assigned(Abort) then
    Abort;
end;

function TAiMailbox.WaitWorkerDone(TimeoutMs: Cardinal): Boolean;
begin
  Result := FDoneEvent.WaitFor(TimeoutMs) = wrSignaled;
end;

procedure TAiMailbox.WorkerDone;
begin
  FDoneEvent.SetEvent;
end;

function NewAiMailbox: IAiMailbox;
begin
  Result := TAiMailbox.Create;
end;

{ TAiHttpClient }

constructor TAiHttpClient.Create(AOwner: TComponent);
begin
  inherited;
  FHandlerLock := TCriticalSection.Create;
end;

destructor TAiHttpClient.Destroy;
begin
  inherited;
  FHandlerLock.Free;
end;

function TAiHttpClient.GetSocketHandler(const UseSSL: Boolean): TSocketHandler;
begin
  Result := inherited GetSocketHandler(UseSSL);
  FHandlerLock.Enter;
  try
    FHandler := Result;
  finally
    FHandlerLock.Leave;
  end;
end;

procedure TAiHttpClient.DisconnectFromServer;
begin
  // The handler is freed together with the socket: forget it first, under the lock, so Abort
  // never uses a freed handler
  FHandlerLock.Enter;
  try
    FHandler := nil;
  finally
    FHandlerLock.Leave;
  end;
  inherited;
end;

procedure TAiHttpClient.ShutdownSocket;
begin
  FHandlerLock.Enter;
  try
    // A raw shutdown of the file descriptor wakes a blocked recv or SSL_read. Not
    // TSocketHandler.Shutdown, which for TLS would call SSL_shutdown concurrently with the
    // worker's SSL_read on the same connection.
    if Assigned(FHandler) and Assigned(FHandler.Socket) then
      fpShutdown(FHandler.Socket.Handle, SHUTDOWN_BOTH);
  finally
    FHandlerLock.Leave;
  end;
end;

procedure TAiHttpClient.ConnectToServer(const AHost: String; APort: Integer; UseSSL: Boolean = False);
begin
  inherited;
  // A cancel that came while connecting found no socket to shut down; the header read that
  // follows would block until the read timeout
  if Terminated then
    ShutdownSocket;
end;

procedure TAiHttpClient.Abort;
begin
  Terminate;
  ShutdownSocket;
end;

{ TAiResponseSink }

function TAiResponseSink.Write(const Buffer; Count: Longint): Longint;
begin
  FWorker.DataReceived(Buffer, Count);
  Result := Count;
end;

function TAiResponseSink.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TAiResponseSink.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  // The HTTP client only writes sequentially; report the position as 0
  Result := 0;
end;

{ TAiStreamWorker }

constructor TAiStreamWorker.Create(const Spec: TAiRequestSpec; const Mailbox: IAiMailbox);
begin
  FSpec := Spec;
  FMailbox := Mailbox;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TAiStreamWorker.HeadersReceived(Sender: TObject);
begin
  // ResponseStatusCode is not set yet at this point; the mode is decided on the first body bytes
  FLastDataTick := GetTickCount64;
end;

procedure TAiStreamWorker.SseEvent(const EventName, Data: String);
var
  Delta: TAiStreamDelta;
begin
  if not DecodeStreamEvent(Data, Delta) then
    Exit; // Unknown payloads are skipped, e.g. vendor keep-alive objects
  if Delta.Done then
    FSawDone := True;
  if Delta.FinishReason <> '' then
    FSawFinish := True;
  if Delta.ErrorMessage <> '' then
    FStreamError := Delta.ErrorMessage;
  if Delta.Content <> '' then
    FMailbox.PushContent(Delta.Content);
  if Delta.Reasoning <> '' then
    FMailbox.PushReasoning(Delta.Reasoning);
  if Delta.Usage.Known then
    FMailbox.SetUsage(Delta.Usage);
end;

procedure TAiStreamWorker.DataReceived(const Buffer; Count: Integer);
var
  Chunk: RawByteString;
  ContentType: String;
begin
  FLastDataTick := GetTickCount64;
  if not FDecided then begin
    FDecided := True;
    ContentType := LowerCase(FClient.GetHeader(FClient.ResponseHeaders, 'Content-Type'));
    FStreaming := (FSpec.Mode = rmChatStream)
      and (FClient.ResponseStatusCode >= 200) and (FClient.ResponseStatusCode < 300)
      and (Pos('text/event-stream', ContentType) > 0);
  end;
  if FStreaming then
    FParser.Feed(Buffer, Count)
  else if Length(FBuffer) < MAXBUFFEREDBODY then begin
    SetLength(Chunk, Count);
    if Count > 0 then
      Move(Buffer, Chunk[1], Count);
    FBuffer := FBuffer + Chunk;
  end;
end;

procedure TAiStreamWorker.FinishResponse;
var
  Status: Integer;
  Kind: TAiErrorKind;
  Content, Reasoning: String;
  Usage: TAiUsage;
begin
  Status := FClient.ResponseStatusCode;
  Kind := ErrorKindFromStatus(Status);
  if Kind <> ekNone then begin
    FMailbox.Finish(Kind, Status, ExtractErrorMessage(FBuffer));
    Exit;
  end;
  if FSpec.Mode = rmBuffer then begin
    FMailbox.SetBody(FBuffer);
    FMailbox.Finish(ekNone, Status, '');
    Exit;
  end;
  if FStreaming then begin
    FParser.Finish;
    if FStreamError <> '' then
      FMailbox.Finish(ekServer, Status, FStreamError)
    else if not (FSawDone or FSawFinish) then
      FMailbox.Finish(ekProtocol, Status, 'The response ended before the answer was complete.')
    else
      FMailbox.Finish(ekNone, Status, '');
    Exit;
  end;
  // 2xx without event stream: the server ignored "stream" and sent the whole answer
  if DecodeCompletion(FBuffer, Content, Reasoning, Usage) then begin
    FMailbox.PushReasoning(Reasoning);
    FMailbox.PushContent(Content);
    FMailbox.SetUsage(Usage);
    FMailbox.Finish(ekNone, Status, '');
  end else
    FMailbox.Finish(ekProtocol, Status, ExtractErrorMessage(FBuffer));
end;

function TAiStreamWorker.ClassifyException(E: Exception): TAiErrorKind;
begin
  if E is ESocketError then begin
    case ESocketError(E).Code of
      seConnectTimeOut, seIOTimeOut: Result := ekTimeout;
      else Result := ekConnect;
    end;
  end else if (E is EHTTPClient) and (FSpec.IoTimeoutMs > 0)
    and (GetTickCount64 - FLastDataTick >= QWord(FSpec.IoTimeoutMs) * 9 div 10) then
    // A read failing after the full timeout of silence is the receive timeout
    Result := ekTimeout
  else if E is EHTTPClient then
    Result := ekConnect
  else
    Result := ekProtocol;
end;

procedure TAiStreamWorker.Execute;
var
  Sink: TAiResponseSink;
  Header: String;
begin
  FParser := TSseParser.Create(SseEvent);
  Sink := TAiResponseSink.Create;
  Sink.FWorker := Self;
  FClient := TAiHttpClient.Create(nil);
  try
    try
      FClient.ConnectTimeout := FSpec.ConnectTimeoutMs;
      FClient.IOTimeout := FSpec.IoTimeoutMs;
      FClient.OnHeaders := HeadersReceived;
      for Header in FSpec.Headers do
        FClient.RequestHeaders.Add(Header);
      if FSpec.Body <> '' then
        FClient.RequestBody := TRawByteStringStream.Create(FSpec.Body);
      FLastDataTick := GetTickCount64;
      FMailbox.AttachAbort(FClient.Abort);
      if FMailbox.Cancelled then
        SysUtils.Abort; // Cancelled before the request started: EAbort, finished as cancelled below
      // An empty list accepts every status, so error bodies reach the sink
      FClient.HTTPMethod(FSpec.Method, FSpec.Url, Sink, []);
      FMailbox.DetachAbort;
      if FMailbox.Cancelled then
        FMailbox.Finish(ekCancelled, 0, '')
      else
        FinishResponse;
    except
      on E: Exception do begin
        FMailbox.DetachAbort;
        FMailbox.Finish(ClassifyException(E), 0, E.Message);
      end;
    end;
  finally
    FClient.RequestBody.Free;
    FClient.RequestBody := nil;
    FClient.Free;
    Sink.Free;
    FParser.Free;
    // Keep this last: after it, the main thread may stop waiting for this thread
    FMailbox.WorkerDone;
    FMailbox := nil;
  end;
end;

procedure StartAiRequest(const Spec: TAiRequestSpec; const Mailbox: IAiMailbox);
begin
  TAiStreamWorker.Create(Spec, Mailbox);
end;

end.
