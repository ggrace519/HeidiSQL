unit test_forkupdate;

{$mode delphi}{$H+}

interface

uses
  fpcunit, testregistry;

type
  TForkUpdateTest = class(TTestCase)
  published
    procedure CompareVersionsNumericNotLexical;
    procedure CompareVersionsMissingPartsAreZero;
    procedure IsPlainVersionRejectsSuffixesAndGaps;
    procedure LatestSkipsDraftsPrereleasesForeignAndSuffixedTags;
    procedure LatestCopiesReleaseFields;
    procedure LatestNullNameBecomesEmpty;
    procedure EmptyListFindsNothing;
    procedure NonArrayResponseFindsNothing;
    procedure InvalidJsonRaises;
  end;

implementation

uses
  SysUtils, forkupdate, testhelpers;

procedure TForkUpdateTest.CompareVersionsNumericNotLexical;
begin
  AssertTrue('0.10.0 > 0.9.1', CompareVersions('0.10.0', '0.9.1') > 0);
  AssertTrue('0.9.1 < 0.10.0', CompareVersions('0.9.1', '0.10.0') < 0);
  AssertTrue('IsNewerVersion', IsNewerVersion('0.1.1', '0.1.0'));
  AssertFalse('not newer than itself', IsNewerVersion('0.1.0', '0.1.0'));
end;

procedure TForkUpdateTest.CompareVersionsMissingPartsAreZero;
begin
  AssertEquals('0.1 = 0.1.0', 0, CompareVersions('0.1', '0.1.0'));
  AssertTrue('1 > 0.99.99', CompareVersions('1', '0.99.99') > 0);
end;

procedure TForkUpdateTest.IsPlainVersionRejectsSuffixesAndGaps;
begin
  AssertTrue('1.10.3', IsPlainVersion('1.10.3'));
  AssertTrue('0.2', IsPlainVersion('0.2'));
  AssertFalse('rc suffix', IsPlainVersion('1.0.0-rc1'));
  AssertFalse('empty', IsPlainVersion(''));
  AssertFalse('double dot', IsPlainVersion('1..2'));
  AssertFalse('letters', IsPlainVersion('one'));
end;

procedure TForkUpdateTest.LatestSkipsDraftsPrereleasesForeignAndSuffixedTags;
var
  Release: TForkRelease;
begin
  Release := FindLatestForkRelease(ReadFixture('releases_mixed.json'), 'ai-v');
  AssertTrue('found', Release.Found);
  AssertEquals('highest published plain ai-v tag', 'ai-v0.9.1', Release.Tag);
  AssertEquals('version without prefix', '0.9.1', Release.Version);
end;

procedure TForkUpdateTest.LatestCopiesReleaseFields;
var
  Release: TForkRelease;
begin
  Release := FindLatestForkRelease(ReadFixture('releases_mixed.json'), 'ai-v');
  AssertEquals('AI Edition 0.9.1', Release.Name);
  AssertEquals('https://example.invalid/ai-v0.9.1', Release.Url);
  AssertEquals('2026-10-01T12:30:00Z', Release.PublishedAt);
  AssertEquals('Notes 0.9.1', Release.Notes);
end;

procedure TForkUpdateTest.LatestNullNameBecomesEmpty;
var
  Release: TForkRelease;
begin
  Release := FindLatestForkRelease(
    '[{"tag_name":"ai-v0.2.0","name":null,"body":null,"html_url":"u"}]', 'ai-v');
  AssertTrue('found', Release.Found);
  AssertEquals('null name', '', Release.Name);
  AssertEquals('null body', '', Release.Notes);
end;

procedure TForkUpdateTest.EmptyListFindsNothing;
begin
  AssertFalse(FindLatestForkRelease(ReadFixture('releases_empty.json'), 'ai-v').Found);
end;

procedure TForkUpdateTest.NonArrayResponseFindsNothing;
begin
  AssertFalse(FindLatestForkRelease('{"message":"Not Found"}', 'ai-v').Found);
end;

procedure TForkUpdateTest.InvalidJsonRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    FindLatestForkRelease('[{"tag_name": ', 'ai-v');
  except
    on E: Exception do
      Raised := True;
  end;
  AssertTrue('invalid JSON raises', Raised);
end;

initialization
  RegisterTest(TForkUpdateTest);

end.
