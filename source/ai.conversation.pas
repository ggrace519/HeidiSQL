unit ai.conversation;

// Conversation of one query tab with the assistant: the turns shown in the panel, and the
// history sent along with the next request. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, ai.types, ai.prompts;

type
  TAiTurnState = (tsStreaming, tsDone, tsFailed, tsCancelled);

  TAiTurn = record
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
    FMaxHistoryTurns: Integer;
    FMaxHistoryAnswerChars: Integer;
    FLastErrorSql: String;
    FLastErrorMessage: String;
    function GetCount: Integer;
    function GetTurn(Index: Integer): TAiTurn;
  public
    constructor Create;
    // Starts a turn in streaming state, returns its index
    function StartTurn(Task: TAiTask; const Title, UserMessage, ContextSent: String): Integer;
    procedure AppendAnswer(Index: Integer; const Text: String);
    procedure AppendReasoning(Index: Integer; const Text: String);
    procedure FinishTurn(Index: Integer; const Usage: TAiUsage);
    procedure FailTurn(Index: Integer; Kind: TAiErrorKind; const Message: String);
    procedure CancelTurn(Index: Integer);
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
begin
  SetLength(FTurns, Length(FTurns) + 1);
  Result := High(FTurns);
  FTurns[Result] := Default(TAiTurn);
  FTurns[Result].Task := Task;
  FTurns[Result].Title := Title;
  FTurns[Result].UserMessage := UserMessage;
  FTurns[Result].ContextSent := ContextSent;
  FTurns[Result].State := tsStreaming;
end;

procedure TAiConversation.AppendAnswer(Index: Integer; const Text: String);
begin
  FTurns[Index].Answer := FTurns[Index].Answer + Text;
end;

procedure TAiConversation.AppendReasoning(Index: Integer; const Text: String);
begin
  FTurns[Index].Reasoning := FTurns[Index].Reasoning + Text;
end;

procedure TAiConversation.FinishTurn(Index: Integer; const Usage: TAiUsage);
begin
  FTurns[Index].Usage := Usage;
  FTurns[Index].State := tsDone;
end;

procedure TAiConversation.FailTurn(Index: Integer; Kind: TAiErrorKind; const Message: String);
begin
  FTurns[Index].ErrorKind := Kind;
  FTurns[Index].ErrorMessage := Message;
  FTurns[Index].State := tsFailed;
end;

procedure TAiConversation.CancelTurn(Index: Integer);
begin
  FTurns[Index].ErrorKind := ekCancelled;
  FTurns[Index].State := tsCancelled;
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
    if (FTurns[i].State = tsDone) and (FTurns[i].Answer.Trim <> '') then begin
      First := i;
      Inc(Taken);
    end;
  end;
  for i:=First to High(FTurns) do begin
    if (FTurns[i].State <> tsDone) or (FTurns[i].Answer.Trim = '') then
      Continue;
    Answer := FTurns[i].Answer;
    if Length(Answer) > FMaxHistoryAnswerChars then
      Answer := Copy(Answer, 1, FMaxHistoryAnswerChars) + #10 + '[...]';
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
