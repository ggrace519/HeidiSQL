unit ai.conversation;

// Conversation of one query tab with the assistant: the turns shown in the panel, and the
// history sent along with the next request. Turns are addressed by an id that is never reused,
// so late data of a cancelled or cleared request cannot end up in a newer turn.
// Not thread-safe: only the main thread uses it; the HTTP worker hands data over through the
// controller. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.types;

type
  TAiTurnState = (tsStreaming, tsDone, tsFailed, tsCancelled);

  TAiTurn = record
    Id: Integer;
    Task: TAiTask;
    Title: String;          // Shown in the panel, e.g. the question or "Explain query"
    UserMessage: String;    // Task message as sent; becomes history
    ContextSent: String;    // System message as sent, for the "Context sent" view
    Answer: String;
    Reasoning: String;
    State: TAiTurnState;
    ErrorKind: TAiErrorKind;
    ErrorMessage: String;
    Usage: TAiUsage;
  end;

  TAiConversation = class
  private
    FTurns: array of TAiTurn;
    FNextId: Integer;
    FMaxHistoryTurns: Integer;
    FMaxHistoryAnswerChars: Integer;
    FLastErrorSql: String;
    FLastErrorMessage: String;
    function GetCount: Integer;
    function GetTurn(Index: Integer): TAiTurn;
  public
    constructor Create;
    // Starts a turn in streaming state, returns its id
    function StartTurn(Task: TAiTask; const Title, UserMessage, ContextSent: String): Integer;
    // Index of a turn id, -1 when the turn no longer exists
    function IndexOfTurn(TurnId: Integer): Integer;
    // These return False and do nothing when the turn no longer exists or is not streaming
    function AppendAnswer(TurnId: Integer; const Text: String): Boolean;
    function AppendReasoning(TurnId: Integer; const Text: String): Boolean;
    function FinishTurn(TurnId: Integer; const Usage: TAiUsage): Boolean;
    function FailTurn(TurnId: Integer; Kind: TAiErrorKind; const Message: String): Boolean;
    function CancelTurn(TurnId: Integer): Boolean;
    // Earlier successful turns as user/assistant messages, oldest first, at most MaxHistoryTurns.
    // Reasoning is never sent back; long answers are shortened.
    function History: TAiChatMessages;
    // Remembers the last failed query of the tab, for "Fix error"
    procedure SetQueryError(const Sql, Message: String);
    procedure Clear;
    property Count: Integer read GetCount;
    property Turns[Index: Integer]: TAiTurn read GetTurn; default;
    property MaxHistoryTurns: Integer read FMaxHistoryTurns write FMaxHistoryTurns;
    property MaxHistoryAnswerChars: Integer read FMaxHistoryAnswerChars write FMaxHistoryAnswerChars;
    property LastErrorSql: String read FLastErrorSql;
    property LastErrorMessage: String read FLastErrorMessage;
  end;

implementation

uses
  ai.text;

constructor TAiConversation.Create;
begin
  inherited;
  FMaxHistoryTurns := 6;
  FMaxHistoryAnswerChars := 4000;
end;

function TAiConversation.GetCount: Integer;
begin
  Result := Length(FTurns);
end;

function TAiConversation.GetTurn(Index: Integer): TAiTurn;
begin
  Result := FTurns[Index];
end;

function TAiConversation.StartTurn(Task: TAiTask; const Title, UserMessage, ContextSent: String): Integer;
var
  i: Integer;
begin
  Inc(FNextId);
  Result := FNextId;
  SetLength(FTurns, Length(FTurns) + 1);
  i := High(FTurns);
  FTurns[i] := Default(TAiTurn);
  FTurns[i].Id := Result;
  FTurns[i].Task := Task;
  FTurns[i].Title := Title;
  FTurns[i].UserMessage := UserMessage;
  FTurns[i].ContextSent := ContextSent;
  FTurns[i].State := tsStreaming;
end;

function TAiConversation.IndexOfTurn(TurnId: Integer): Integer;
var
  i: Integer;
begin
  for i:=High(FTurns) downto 0 do begin
    if FTurns[i].Id = TurnId then
      Exit(i);
  end;
  Result := -1;
end;

function TAiConversation.AppendAnswer(TurnId: Integer; const Text: String): Boolean;
var
  i: Integer;
begin
  i := IndexOfTurn(TurnId);
  Result := (i >= 0) and (FTurns[i].State = tsStreaming);
  if Result then
    FTurns[i].Answer := FTurns[i].Answer + Text;
end;

function TAiConversation.AppendReasoning(TurnId: Integer; const Text: String): Boolean;
var
  i: Integer;
begin
  i := IndexOfTurn(TurnId);
  Result := (i >= 0) and (FTurns[i].State = tsStreaming);
  if Result then
    FTurns[i].Reasoning := FTurns[i].Reasoning + Text;
end;

function TAiConversation.FinishTurn(TurnId: Integer; const Usage: TAiUsage): Boolean;
var
  i: Integer;
begin
  i := IndexOfTurn(TurnId);
  Result := (i >= 0) and (FTurns[i].State = tsStreaming);
  if Result then begin
    FTurns[i].Usage := Usage;
    FTurns[i].State := tsDone;
  end;
end;

function TAiConversation.FailTurn(TurnId: Integer; Kind: TAiErrorKind; const Message: String): Boolean;
var
  i: Integer;
begin
  i := IndexOfTurn(TurnId);
  Result := (i >= 0) and (FTurns[i].State = tsStreaming);
  if Result then begin
    FTurns[i].ErrorKind := Kind;
    FTurns[i].ErrorMessage := Message;
    FTurns[i].State := tsFailed;
  end;
end;

function TAiConversation.CancelTurn(TurnId: Integer): Boolean;
var
  i: Integer;
begin
  i := IndexOfTurn(TurnId);
  Result := (i >= 0) and (FTurns[i].State = tsStreaming);
  if Result then begin
    FTurns[i].ErrorKind := ekCancelled;
    FTurns[i].State := tsCancelled;
  end;
end;

function TAiConversation.History: TAiChatMessages;
var
  i, First, Taken: Integer;
  Answer: String;
begin
  Result := nil;
  // Walk back to find the oldest of the last MaxHistoryTurns successful turns
  First := Length(FTurns);
  Taken := 0;
  for i:=High(FTurns) downto 0 do begin
    if Taken >= FMaxHistoryTurns then
      Break;
    if (FTurns[i].State = tsDone) and (StripThinking(FTurns[i].Answer) <> '') then begin
      First := i;
      Inc(Taken);
    end;
  end;
  for i:=First to High(FTurns) do begin
    if (FTurns[i].State <> tsDone) or (StripThinking(FTurns[i].Answer) = '') then
      Continue;
    // Reasoning written inline is not sent back; long answers are shortened
    Answer := Utf8Truncate(StripThinking(FTurns[i].Answer), FMaxHistoryAnswerChars, #10'[...]');
    SetLength(Result, Length(Result) + 2);
    Result[High(Result)-1] := AiChatMessage(crUser, FTurns[i].UserMessage);
    Result[High(Result)] := AiChatMessage(crAssistant, Answer);
  end;
end;

procedure TAiConversation.SetQueryError(const Sql, Message: String);
begin
  FLastErrorSql := Sql;
  FLastErrorMessage := Message;
end;

procedure TAiConversation.Clear;
begin
  FTurns := nil;
  FLastErrorSql := '';
  FLastErrorMessage := '';
end;

end.
