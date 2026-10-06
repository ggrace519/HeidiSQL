unit test_ai_conversation_keystore;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, ai.types, ai.prompts, ai.conversation, ai.profiles, ai.keystore;

type
  TAiConversationTest = class(TTestCase)
  private
    FConv: TAiConversation;
    procedure AddDone(const Question, Answer: String);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TurnLifecycle;
    procedure HistoryOnlySuccessfulTurns;
    procedure HistoryLimitedToLastTurns;
    procedure HistoryExcludesReasoning;
    procedure HistoryShortensLongAnswers;
    procedure QueryErrorRemembered;
    procedure LateDataAfterCancelIgnored;
    procedure LateDataAfterClearIgnored;
    procedure HistoryStripsInlineThinking;
  end;

  TFakeKeychain = class(TInterfacedObject, IAiKeychain)
    IsAvailable: Boolean;
    Entries: String; // "account=secret;" pairs
    function Available(out Problem: String): Boolean;
    function Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
    function Store(const Account, Secret: String; out Problem: String): Boolean;
    function Remove(const Account: String; out Problem: String): Boolean;
  end;

  TAiKeystoreTest = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    procedure NoKeyNeeded;
    procedure EnvironmentFound;
    procedure EnvironmentMissingOrBlank;
    procedure KeychainNotRegistered;
    procedure KeychainUnavailable;
    procedure KeychainFoundAndMissing;
  end;

implementation

{ TAiConversationTest }

procedure TAiConversationTest.SetUp;
begin
  FConv := TAiConversation.Create;
end;

procedure TAiConversationTest.TearDown;
begin
  FConv.Free;
end;

procedure TAiConversationTest.AddDone(const Question, Answer: String);
var
  i: Integer;
begin
  i := FConv.StartTurn(atGenerate, Question, Question, 'system');
  FConv.AppendAnswer(i, Answer);
  FConv.FinishTurn(i, Default(TAiUsage));
end;

procedure TAiConversationTest.TurnLifecycle;
var
  Id, i: Integer;
  Usage: TAiUsage;
begin
  Id := FConv.StartTurn(atExplain, 'Explain query', 'msg', 'ctx');
  i := FConv.IndexOfTurn(Id);
  AssertEquals('index', 0, i);
  AssertEquals('id stored', Id, FConv[i].Id);
  AssertTrue('streaming', FConv[i].State = tsStreaming);
  FConv.AppendReasoning(Id, 'th');
  FConv.AppendReasoning(Id, 'ink');
  FConv.AppendAnswer(Id, 'An');
  FConv.AppendAnswer(Id, 'swer');
  Usage.Known := True;
  Usage.PromptTokens := 10;
  Usage.CompletionTokens := 2;
  AssertTrue(FConv.FinishTurn(Id, Usage));
  AssertTrue('done', FConv[i].State = tsDone);
  AssertEquals('Answer', FConv[i].Answer);
  AssertEquals('think', FConv[i].Reasoning);
  AssertEquals('ctx', FConv[i].ContextSent);
  AssertEquals(10, FConv[i].Usage.PromptTokens);
end;

procedure TAiConversationTest.HistoryOnlySuccessfulTurns;
var
  i: Integer;
  H: TAiChatMessages;
begin
  AddDone('q1', 'a1');
  i := FConv.StartTurn(atGenerate, 'q2', 'q2', '');
  FConv.FailTurn(i, ekTimeout, 'no data');
  i := FConv.StartTurn(atGenerate, 'q3', 'q3', '');
  FConv.AppendAnswer(i, 'partial');
  FConv.CancelTurn(i);
  i := FConv.StartTurn(atGenerate, 'q4', 'q4', '');
  FConv.FinishTurn(i, Default(TAiUsage)); // empty answer
  H := FConv.History;
  AssertEquals(2, Length(H));
  AssertTrue(H[0].Role = crUser);
  AssertEquals('q1', H[0].Content);
  AssertTrue(H[1].Role = crAssistant);
  AssertEquals('a1', H[1].Content);
  AssertTrue('failed state', FConv[1].State = tsFailed);
  AssertTrue('cancelled kind', FConv[2].ErrorKind = ekCancelled);
end;

procedure TAiConversationTest.HistoryLimitedToLastTurns;
var
  n: Integer;
  H: TAiChatMessages;
begin
  for n:=1 to 9 do
    AddDone('q' + IntToStr(n), 'a' + IntToStr(n));
  H := FConv.History;
  AssertEquals('6 turns, 2 messages each', 12, Length(H));
  AssertEquals('oldest kept', 'q4', H[0].Content);
  AssertEquals('newest', 'a9', H[11].Content);
end;

procedure TAiConversationTest.HistoryExcludesReasoning;
var
  i: Integer;
begin
  i := FConv.StartTurn(atGenerate, 'q', 'q', '');
  FConv.AppendReasoning(i, 'secret thoughts');
  FConv.AppendAnswer(i, 'a');
  FConv.FinishTurn(i, Default(TAiUsage));
  AssertEquals('a', FConv.History[1].Content);
end;

procedure TAiConversationTest.HistoryShortensLongAnswers;
begin
  FConv.MaxHistoryAnswerChars := 10;
  AddDone('q', StringOfChar('x', 50));
  AssertEquals(StringOfChar('x', 10) + #10'[...]', FConv.History[1].Content);
  AssertEquals('turn itself unchanged', 50, Length(FConv[0].Answer));
end;

procedure TAiConversationTest.LateDataAfterCancelIgnored;
var
  Old, New: Integer;
begin
  Old := FConv.StartTurn(atGenerate, 'q1', 'q1', '');
  AssertTrue(FConv.CancelTurn(Old));
  New := FConv.StartTurn(atGenerate, 'q2', 'q2', '');
  AssertFalse('cancelled turn takes no data', FConv.AppendAnswer(Old, 'late'));
  AssertFalse('cannot finish twice', FConv.FinishTurn(Old, Default(TAiUsage)));
  AssertTrue(FConv.AppendAnswer(New, 'mine'));
  AssertEquals('', FConv[0].Answer);
  AssertEquals('mine', FConv[1].Answer);
end;

procedure TAiConversationTest.LateDataAfterClearIgnored;
var
  Old, New: Integer;
begin
  Old := FConv.StartTurn(atGenerate, 'q1', 'q1', '');
  FConv.Clear;
  AssertFalse('no turn, no crash', FConv.AppendAnswer(Old, 'late'));
  New := FConv.StartTurn(atGenerate, 'q2', 'q2', '');
  AssertFalse('ids are not reused', Old = New);
  AssertFalse(FConv.AppendAnswer(Old, 'late'));
  AssertEquals('', FConv[0].Answer);
end;

procedure TAiConversationTest.HistoryStripsInlineThinking;
var
  Id: Integer;
begin
  Id := FConv.StartTurn(atGenerate, 'q', 'q', '');
  FConv.AppendAnswer(Id, '<think>long reasoning</think>SELECT 1;');
  FConv.FinishTurn(Id, Default(TAiUsage));
  AssertEquals('SELECT 1;', FConv.History[1].Content);
end;

procedure TAiConversationTest.QueryErrorRemembered;
begin
  FConv.SetQueryError('SELECT x', 'Unknown column');
  AssertEquals('SELECT x', FConv.LastErrorSql);
  AssertEquals('Unknown column', FConv.LastErrorMessage);
  FConv.Clear;
  AssertEquals('', FConv.LastErrorSql);
  AssertEquals(0, FConv.Count);
end;

{ TFakeKeychain }

function TFakeKeychain.Available(out Problem: String): Boolean;
begin
  Result := IsAvailable;
  if Result then
    Problem := ''
  else
    Problem := 'no secret service';
end;

function TFakeKeychain.Lookup(const Account: String; out Secret: String; out Problem: String): TAiKeyResult;
var
  p: Integer;
begin
  Problem := '';
  Secret := '';
  p := Pos(Account + '=', Entries);
  if p = 0 then
    Exit(krKeychainNotFound);
  Secret := Copy(Entries, p + Length(Account) + 1, MaxInt);
  Secret := Copy(Secret, 1, Pos(';', Secret) - 1);
  Result := krFound;
end;

function TFakeKeychain.Store(const Account, Secret: String; out Problem: String): Boolean;
begin
  Entries := Entries + Account + '=' + Secret + ';';
  Problem := '';
  Result := True;
end;

function TFakeKeychain.Remove(const Account: String; out Problem: String): Boolean;
begin
  Problem := '';
  Result := True;
end;

{ TAiKeystoreTest }

function FakeEnv(const Name: String): String;
begin
  if Name = 'HEIDI_TEST_KEY' then
    Result := ' sk-test-123 '
  else if Name = 'HEIDI_BLANK' then
    Result := '   '
  else
    Result := '';
end;

function KeyProfile(Source: TAiKeySource; const KeyName: String): TAiProfile;
begin
  Result := NewAiProfile('p');
  Result.KeySource := Source;
  Result.KeyName := KeyName;
end;

procedure TAiKeystoreTest.TearDown;
begin
  RegisterKeychain(nil);
end;

procedure TAiKeystoreTest.NoKeyNeeded;
var
  Key, Problem: String;
begin
  AssertTrue(ResolveApiKey(KeyProfile(ksNone, 'ignored'), Key, Problem) = krNotNeeded);
  AssertEquals('', Key);
end;

procedure TAiKeystoreTest.EnvironmentFound;
var
  Old: TGetEnvFunc;
  Key, Problem: String;
begin
  Old := GetEnvironmentValue;
  GetEnvironmentValue := FakeEnv;
  try
    AssertTrue(ResolveApiKey(KeyProfile(ksEnvironment, ' HEIDI_TEST_KEY '), Key, Problem) = krFound);
    AssertEquals('trimmed', 'sk-test-123', Key);
  finally
    GetEnvironmentValue := Old;
  end;
end;

procedure TAiKeystoreTest.EnvironmentMissingOrBlank;
var
  Old: TGetEnvFunc;
  Key, Problem: String;
begin
  Old := GetEnvironmentValue;
  GetEnvironmentValue := FakeEnv;
  try
    AssertTrue('missing', ResolveApiKey(KeyProfile(ksEnvironment, 'NOPE'), Key, Problem) = krEnvNotSet);
    AssertTrue('blank', ResolveApiKey(KeyProfile(ksEnvironment, 'HEIDI_BLANK'), Key, Problem) = krEnvNotSet);
    AssertTrue('no name', ResolveApiKey(KeyProfile(ksEnvironment, ''), Key, Problem) = krEnvNotSet);
    AssertEquals('', Key);
  finally
    GetEnvironmentValue := Old;
  end;
end;

procedure TAiKeystoreTest.KeychainNotRegistered;
var
  Key, Problem: String;
begin
  RegisterKeychain(nil);
  AssertTrue(ResolveApiKey(KeyProfile(ksKeychain, 'x'), Key, Problem) = krKeychainUnavailable);
end;

procedure TAiKeystoreTest.KeychainUnavailable;
var
  Fake: TFakeKeychain;
  Key, Problem: String;
begin
  Fake := TFakeKeychain.Create;
  Fake.IsAvailable := False;
  RegisterKeychain(Fake);
  AssertTrue(ResolveApiKey(KeyProfile(ksKeychain, 'x'), Key, Problem) = krKeychainUnavailable);
  AssertEquals('backend detail passed on', 'no secret service', Problem);
end;

procedure TAiKeystoreTest.KeychainFoundAndMissing;
var
  Fake: TFakeKeychain;
  Key, Problem: String;
begin
  Fake := TFakeKeychain.Create;
  Fake.IsAvailable := True;
  Fake.Entries := 'cloud=sk-abc;empty=;';
  RegisterKeychain(Fake);
  AssertTrue(ResolveApiKey(KeyProfile(ksKeychain, 'cloud'), Key, Problem) = krFound);
  AssertEquals('sk-abc', Key);
  AssertTrue('missing', ResolveApiKey(KeyProfile(ksKeychain, 'other'), Key, Problem) = krKeychainNotFound);
  AssertTrue('empty secret', ResolveApiKey(KeyProfile(ksKeychain, 'empty'), Key, Problem) = krKeychainNotFound);
  AssertEquals('no key on failure', '', Key);
end;

initialization
  RegisterTest(TAiConversationTest);
  RegisterTest(TAiKeystoreTest);

end.
