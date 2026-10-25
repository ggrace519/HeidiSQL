unit ai.conversations;

// One AI conversation per query tab, keyed by the tab's Uid, plus the bookkeeping of the single
// request in flight: streamed text is only applied while it still belongs to that request and
// tab, so late data after a cancel, a tab close or a new request is dropped. No LCL dependencies.

{$mode delphi}{$H+}

interface

uses
  SysUtils, Generics.Collections, ai.conversation;

type
  TAiConversations = class
  private
    FItems: TObjectDictionary<String, TAiConversation>;
  public
    constructor Create;
    destructor Destroy; override;
    // Conversation of a tab, created on first use
    function Get(const TabUid: String): TAiConversation;
    // Conversation of a tab, or nil
    function Find(const TabUid: String): TAiConversation;
    procedure Drop(const TabUid: String);
    procedure Clear;
    function Count: Integer;
  end;

  TAiRequestTracker = class
  private
    FLastId: Integer;
    FRequestId: Integer;   // 0: nothing in flight
    FTabUid: String;
    FTurnId: Integer;
  public
    // Starts tracking a new request and returns its id; the previous one is forgotten
    function Start(const TabUid: String; TurnId: Integer): Integer;
    function Busy: Boolean;
    // True while RequestId is the request in flight
    function Owns(RequestId: Integer): Boolean;
    function BusyForTab(const TabUid: String): Boolean;
    procedure Stop;
    property RequestId: Integer read FRequestId;
    property TabUid: String read FTabUid;
    property TurnId: Integer read FTurnId;
  end;

implementation

constructor TAiConversations.Create;
begin
  inherited;
  FItems := TObjectDictionary<String, TAiConversation>.Create([doOwnsValues]);
end;

destructor TAiConversations.Destroy;
begin
  FItems.Free;
  inherited;
end;

function TAiConversations.Get(const TabUid: String): TAiConversation;
begin
  if not FItems.TryGetValue(TabUid, Result) then begin
    Result := TAiConversation.Create;
    FItems.Add(TabUid, Result);
  end;
end;

function TAiConversations.Find(const TabUid: String): TAiConversation;
begin
  if not FItems.TryGetValue(TabUid, Result) then
    Result := nil;
end;

procedure TAiConversations.Drop(const TabUid: String);
begin
  FItems.Remove(TabUid);
end;

procedure TAiConversations.Clear;
begin
  FItems.Clear;
end;

function TAiConversations.Count: Integer;
begin
  Result := FItems.Count;
end;

function TAiRequestTracker.Start(const TabUid: String; TurnId: Integer): Integer;
begin
  Inc(FLastId);
  FRequestId := FLastId;
  FTabUid := TabUid;
  FTurnId := TurnId;
  Result := FRequestId;
end;

function TAiRequestTracker.Busy: Boolean;
begin
  Result := FRequestId <> 0;
end;

function TAiRequestTracker.Owns(RequestId: Integer): Boolean;
begin
  Result := (RequestId <> 0) and (RequestId = FRequestId);
end;

function TAiRequestTracker.BusyForTab(const TabUid: String): Boolean;
begin
  Result := Busy and (FTabUid = TabUid);
end;

procedure TAiRequestTracker.Stop;
begin
  FRequestId := 0;
  FTabUid := '';
  FTurnId := 0;
end;

end.
