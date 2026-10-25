unit test_ai_conversations;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.types, ai.conversation, ai.conversations;

type
  TAiConversationsTest = class(TTestCase)
  published
    procedure GetCreatesOncePerTab;
    procedure FindDoesNotCreate;
    procedure DropRemovesOnlyThatTab;
    procedure ClearRemovesAll;
    procedure KeySeparatesSessions;
    procedure DropTabRemovesAllSessionsOfTab;
  end;

  TAiRequestTrackerTest = class(TTestCase)
  published
    procedure IdleAtStart;
    procedure StartOwnsNewId;
    procedure NewRequestDisownsOld;
    procedure StopDisownsAll;
    procedure ZeroNeverOwned;
    procedure BusyForTabOnlyMatchesItsTab;
    procedure BusyForTabNumberIgnoresSession;
  end;

implementation

procedure TAiConversationsTest.GetCreatesOncePerTab;
var
  List: TAiConversations;
  A, B: TAiConversation;
begin
  List := TAiConversations.Create;
  try
    A := List.Get('tab1');
    A.StartTurn(atGenerate, 'q', 'q', 'ctx');
    B := List.Get('tab1');
    AssertSame('same tab, same conversation', A, B);
    AssertEquals('turn kept', 1, B.Count);
    AssertNotSame('other tab, own conversation', A, List.Get('tab2'));
    AssertEquals(2, List.Count);
  finally
    List.Free;
  end;
end;

procedure TAiConversationsTest.FindDoesNotCreate;
var
  List: TAiConversations;
begin
  List := TAiConversations.Create;
  try
    AssertNull(List.Find('tab1'));
    AssertEquals(0, List.Count);
    List.Get('tab1');
    AssertNotNull(List.Find('tab1'));
  finally
    List.Free;
  end;
end;

procedure TAiConversationsTest.DropRemovesOnlyThatTab;
var
  List: TAiConversations;
begin
  List := TAiConversations.Create;
  try
    List.Get('tab1');
    List.Get('tab2');
    List.Drop('tab1');
    List.Drop('unknown');
    AssertNull(List.Find('tab1'));
    AssertNotNull(List.Find('tab2'));
  finally
    List.Free;
  end;
end;

procedure TAiConversationsTest.ClearRemovesAll;
var
  List: TAiConversations;
begin
  List := TAiConversations.Create;
  try
    List.Get('tab1');
    List.Get('tab2');
    List.Clear;
    AssertEquals(0, List.Count);
  finally
    List.Free;
  end;
end;

procedure TAiRequestTrackerTest.IdleAtStart;
var
  T: TAiRequestTracker;
begin
  T := TAiRequestTracker.Create;
  try
    AssertFalse(T.Busy);
    AssertEquals(0, T.RequestId);
  finally
    T.Free;
  end;
end;

procedure TAiRequestTrackerTest.StartOwnsNewId;
var
  T: TAiRequestTracker;
  Id: Integer;
begin
  T := TAiRequestTracker.Create;
  try
    Id := T.Start('tab1', 7);
    AssertTrue(T.Busy);
    AssertTrue(T.Owns(Id));
    AssertEquals('tab1', T.TabUid);
    AssertEquals(7, T.TurnId);
  finally
    T.Free;
  end;
end;

procedure TAiRequestTrackerTest.NewRequestDisownsOld;
var
  T: TAiRequestTracker;
  Old, New: Integer;
begin
  T := TAiRequestTracker.Create;
  try
    Old := T.Start('tab1', 1);
    New := T.Start('tab1', 2);
    AssertTrue('ids differ', Old <> New);
    AssertFalse('late data of the old request is dropped', T.Owns(Old));
    AssertTrue(T.Owns(New));
  finally
    T.Free;
  end;
end;

procedure TAiRequestTrackerTest.StopDisownsAll;
var
  T: TAiRequestTracker;
  Id: Integer;
begin
  T := TAiRequestTracker.Create;
  try
    Id := T.Start('tab1', 1);
    T.Stop;
    AssertFalse(T.Busy);
    AssertFalse(T.Owns(Id));
    // A request started after a stop gets a fresh id, never the stopped one
    AssertTrue(T.Start('tab1', 2) <> Id);
  finally
    T.Free;
  end;
end;

procedure TAiRequestTrackerTest.ZeroNeverOwned;
var
  T: TAiRequestTracker;
begin
  T := TAiRequestTracker.Create;
  try
    AssertFalse(T.Owns(0));
    T.Start('tab1', 1);
    AssertFalse(T.Owns(0));
  finally
    T.Free;
  end;
end;

procedure TAiRequestTrackerTest.BusyForTabOnlyMatchesItsTab;
var
  T: TAiRequestTracker;
begin
  T := TAiRequestTracker.Create;
  try
    T.Start('tab1', 1);
    AssertTrue(T.BusyForTab('tab1'));
    AssertFalse(T.BusyForTab('tab2'));
    T.Stop;
    AssertFalse(T.BusyForTab('tab1'));
  finally
    T.Free;
  end;
end;

procedure TAiConversationsTest.KeySeparatesSessions;
begin
  AssertTrue(ConversationKey(2, 'Servers\A') <> ConversationKey(2, 'Servers\B'));
  AssertTrue(ConversationKey(2, 'Servers\A') <> ConversationKey(3, 'Servers\A'));
  AssertEquals(12, TabNumberOfKey(ConversationKey(12, 'Servers\A')));
  AssertEquals(-1, TabNumberOfKey('garbage'));
end;

procedure TAiConversationsTest.DropTabRemovesAllSessionsOfTab;
var
  List: TAiConversations;
begin
  List := TAiConversations.Create;
  try
    List.Get(ConversationKey(1, 'A'));
    List.Get(ConversationKey(1, 'B'));
    List.Get(ConversationKey(11, 'A'));
    List.DropTab(1);
    AssertNull(List.Find(ConversationKey(1, 'A')));
    AssertNull(List.Find(ConversationKey(1, 'B')));
    AssertNotNull('tab 11 is not tab 1', List.Find(ConversationKey(11, 'A')));
  finally
    List.Free;
  end;
end;

procedure TAiRequestTrackerTest.BusyForTabNumberIgnoresSession;
var
  T: TAiRequestTracker;
begin
  T := TAiRequestTracker.Create;
  try
    T.Start(ConversationKey(3, 'A'), 1);
    AssertTrue(T.BusyForTabNumber(3));
    AssertFalse(T.BusyForTabNumber(13));
  finally
    T.Free;
  end;
end;

initialization
  RegisterTest(TAiConversationsTest);
  RegisterTest(TAiRequestTrackerTest);

end.
