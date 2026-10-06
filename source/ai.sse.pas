unit ai.sse;

// Incremental parser for Server-Sent Events (text/event-stream), as used by streaming LLM APIs.
// Bytes are fed in arbitrary chunks, as they arrive from the network; complete events are
// reported through OnEvent. Follows the WHATWG event stream format: lines end with LF, CRLF or
// CR, lines starting with ":" are comments, "data" lines of one event are joined with LF, and an
// empty line dispatches the event. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TSseEventProc = procedure(const EventName, Data: String) of object;

  TSseParser = class
  private
    FOnEvent: TSseEventProc;
    FLine: RawByteString;
    FEventName: String;
    FData: String;
    FHasData: Boolean;
    FSkipNextLF: Boolean;
    procedure ProcessLine(const Line: RawByteString);
    procedure Dispatch;
  public
    constructor Create(OnEvent: TSseEventProc);
    // Feed a chunk of the response body. Chunks may split lines and even CRLF pairs.
    procedure Feed(const Chunk: RawByteString); overload;
    procedure Feed(const Buffer; Count: Integer); overload;
    // End of stream: process an unterminated last line and dispatch a pending event
    procedure Finish;
  end;

implementation

constructor TSseParser.Create(OnEvent: TSseEventProc);
begin
  inherited Create;
  FOnEvent := OnEvent;
end;

procedure TSseParser.Feed(const Buffer; Count: Integer);
var
  Chunk: RawByteString;
begin
  if Count <= 0 then
    Exit;
  SetLength(Chunk, Count);
  Move(Buffer, Chunk[1], Count);
  Feed(Chunk);
end;

procedure TSseParser.Feed(const Chunk: RawByteString);
var
  i, LineStart: Integer;
  c: AnsiChar;
begin
  LineStart := 1;
  i := 1;
  while i <= Length(Chunk) do begin
    c := Chunk[i];
    if FSkipNextLF then begin
      FSkipNextLF := False;
      if c = #10 then begin
        // Second half of a CRLF which was split between two chunks
        Inc(i);
        LineStart := i;
        Continue;
      end;
    end;
    if (c = #10) or (c = #13) then begin
      FLine := FLine + Copy(Chunk, LineStart, i - LineStart);
      ProcessLine(FLine);
      FLine := '';
      if c = #13 then begin
        if (i < Length(Chunk)) and (Chunk[i+1] = #10) then
          Inc(i)
        else if i = Length(Chunk) then
          FSkipNextLF := True;
      end;
      LineStart := i + 1;
    end;
    Inc(i);
  end;
  if LineStart <= Length(Chunk) then
    FLine := FLine + Copy(Chunk, LineStart, MaxInt);
end;

procedure TSseParser.ProcessLine(const Line: RawByteString);
var
  ColonPos: Integer;
  Field, Value: String;
begin
  if Line = '' then begin
    Dispatch;
    Exit;
  end;
  if Line[1] = ':' then
    Exit; // Comment, e.g. a keep-alive
  ColonPos := Pos(':', Line);
  if ColonPos = 0 then begin
    Field := Line;
    Value := '';
  end else begin
    Field := Copy(Line, 1, ColonPos - 1);
    Value := Copy(Line, ColonPos + 1, MaxInt);
    if (Value <> '') and (Value[1] = ' ') then
      Delete(Value, 1, 1);
  end;
  if Field = 'data' then begin
    if FHasData then
      FData := FData + #10 + Value
    else
      FData := Value;
    FHasData := True;
  end else if Field = 'event' then
    FEventName := Value;
  // "id" and "retry" are not needed for one-shot HTTP responses
end;

procedure TSseParser.Dispatch;
begin
  if FHasData and Assigned(FOnEvent) then
    FOnEvent(FEventName, FData);
  FEventName := '';
  FData := '';
  FHasData := False;
end;

procedure TSseParser.Finish;
begin
  if FLine <> '' then begin
    ProcessLine(FLine);
    FLine := '';
  end;
  Dispatch;
end;

end.
