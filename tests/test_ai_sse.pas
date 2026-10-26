unit test_ai_sse;

{$mode delphi}{$H+}

interface

uses
  Classes, fpcunit, testregistry, ai.sse;

type
  TSseParserTest = class(TTestCase)
  private
    FEvents: TStringList;
    FNames: TStringList;
    FParser: TSseParser;
    procedure OnEvent(const EventName, Data: String);
    procedure FeedInChunks(const Text: RawByteString; ChunkSize: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SingleEvent;
    procedure CrLfAndCrLineEndings;
    procedure CrLfSplitBetweenChunks;
    procedure CommentsAreIgnored;
    procedure MultipleDataLinesJoinedWithLF;
    procedure EventNameIsReported;
    procedure FieldWithoutSpaceAfterColon;
    procedure EmptyLinesWithoutDataDispatchNothing;
    procedure FinishFlushesUnterminatedEvent;
    procedure Utf8SplitBetweenChunks;
    procedure RealOllamaStreamByteByByte;
    procedure RealOllamaStreamInOddChunks;
  end;

implementation

uses
  SysUtils, testhelpers;

procedure TSseParserTest.SetUp;
begin
  FEvents := TStringList.Create;
  FNames := TStringList.Create;
  FParser := TSseParser.Create(OnEvent);
end;

procedure TSseParserTest.TearDown;
begin
  FParser.Free;
  FNames.Free;
  FEvents.Free;
end;

procedure TSseParserTest.OnEvent(const EventName, Data: String);
begin
  FNames.Add(EventName);
  FEvents.Add(Data);
end;

procedure TSseParserTest.FeedInChunks(const Text: RawByteString; ChunkSize: Integer);
var
  i: Integer;
begin
  i := 1;
  while i <= Length(Text) do begin
    FParser.Feed(Copy(Text, i, ChunkSize));
    Inc(i, ChunkSize);
  end;
end;

procedure TSseParserTest.SingleEvent;
begin
  FParser.Feed('data: {"a":1}'#10#10);
  AssertEquals('count', 1, FEvents.Count);
  AssertEquals('{"a":1}', FEvents[0]);
end;

procedure TSseParserTest.CrLfAndCrLineEndings;
begin
  FParser.Feed('data: one'#13#10#13#10'data: two'#13#13'data: three'#10#10);
  AssertEquals('count', 3, FEvents.Count);
  AssertEquals('one', FEvents[0]);
  AssertEquals('two', FEvents[1]);
  AssertEquals('three', FEvents[2]);
end;

procedure TSseParserTest.CrLfSplitBetweenChunks;
begin
  FParser.Feed('data: one'#13);
  FParser.Feed(#10#13);
  FParser.Feed(#10'data: two'#13#10#13#10);
  AssertEquals('no extra empty-line dispatch', 2, FEvents.Count);
  AssertEquals('one', FEvents[0]);
  AssertEquals('two', FEvents[1]);
end;

procedure TSseParserTest.CommentsAreIgnored;
begin
  FParser.Feed(': keep-alive'#10#10'data: x'#10': inside'#10#10);
  AssertEquals('count', 1, FEvents.Count);
  AssertEquals('x', FEvents[0]);
end;

procedure TSseParserTest.MultipleDataLinesJoinedWithLF;
begin
  FParser.Feed('data: line1'#10'data: line2'#10'data:'#10#10);
  AssertEquals('count', 1, FEvents.Count);
  AssertEquals('line1'#10'line2'#10, FEvents[0]);
end;

procedure TSseParserTest.EventNameIsReported;
begin
  FParser.Feed('event: error'#10'data: boom'#10#10'data: next'#10#10);
  AssertEquals('error', FNames[0]);
  AssertEquals('boom', FEvents[0]);
  AssertEquals('name reset after dispatch', '', FNames[1]);
end;

procedure TSseParserTest.FieldWithoutSpaceAfterColon;
begin
  FParser.Feed('data:no-space'#10'data:  two-spaces'#10#10);
  AssertEquals('no-space'#10' two-spaces', FEvents[0]);
end;

procedure TSseParserTest.EmptyLinesWithoutDataDispatchNothing;
begin
  FParser.Feed(#10#10#10'event: x'#10#10);
  AssertEquals('count', 0, FEvents.Count);
end;

procedure TSseParserTest.FinishFlushesUnterminatedEvent;
begin
  FParser.Feed('data: [DONE]');
  AssertEquals('not yet', 0, FEvents.Count);
  FParser.Finish;
  AssertEquals('count', 1, FEvents.Count);
  AssertEquals('[DONE]', FEvents[0]);
end;

procedure TSseParserTest.Utf8SplitBetweenChunks;
const
  // "Café ✓" in UTF-8; the split falls inside both multi-byte sequences
  Payload: RawByteString = 'data: Caf'#$C3#$A9' '#$E2#$9C#$93#10#10;
begin
  FeedInChunks(Payload, 1);
  AssertEquals('count', 1, FEvents.Count);
  AssertEquals('Caf'#$C3#$A9' '#$E2#$9C#$93, FEvents[0]);
end;

procedure TSseParserTest.RealOllamaStreamByteByByte;
var
  Stream: RawByteString;
begin
  Stream := ReadFixture('sse_ollama_qwen25.txt');
  FeedInChunks(Stream, 1);
  FParser.Finish;
  AssertTrue('several events', FEvents.Count > 5);
  AssertEquals('last event is DONE', '[DONE]', FEvents[FEvents.Count-1]);
  AssertTrue('first is a chunk', Pos('"chat.completion.chunk"', FEvents[0]) > 0);
end;

procedure TSseParserTest.RealOllamaStreamInOddChunks;
var
  Stream: RawByteString;
  Whole: TStringList;
  i: Integer;
begin
  Stream := ReadFixture('sse_ollama_qwen35_reasoning.txt');
  FParser.Feed(Stream);
  FParser.Finish;
  Whole := TStringList.Create;
  try
    Whole.Assign(FEvents);
    FEvents.Clear;
    FParser.Free;
    FParser := TSseParser.Create(OnEvent);
    FeedInChunks(Stream, 7);
    FParser.Finish;
    AssertEquals('same event count', Whole.Count, FEvents.Count);
    for i:=0 to Whole.Count-1 do
      AssertEquals('event '+IntToStr(i), Whole[i], FEvents[i]);
  finally
    Whole.Free;
  end;
end;

initialization
  RegisterTest(TSseParserTest);

end.
